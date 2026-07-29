{- | Adopting pre-workspace scaffold output into workspace history.

The first whole-workspace scaffold into an output directory that already holds
per-context scaffold output has to answer one question honestly: /which of these
files are mine?/ Guessing in either direction is harmful. Claiming everything
would take ownership of hand-written code and then overwrite it on the next run.
Claiming nothing would report the entire existing tree as unrelated and leave a
human to reconcile it by hand.

So adoption claims only what is __attributable__:

  * @record@ evidence — the file is listed in a legacy per-context scaffold
    record for this workspace's effective context, and the workspace still
    produces it.

  * @banner@ evidence — the file sits at a path this workspace produces as
    Generated and carries the @-- \@generated@ banner, but no surviving record
    lists it. This is the orphan case IR-2 describes: two same-context specs
    scaffolded into one directory, the second overwriting the first's record, so
    the first spec's files lost their only attribution.

Everything else is reported and left alone. Hole paths are never claimed — the
create-once rule keeps governing them. Files the plan never mentions are listed
as unclaimed. Files the legacy record lists that this workspace no longer
produces are listed as likely stale, and are deliberately __not__ merged into
the workspace record: the record states what this workspace produces and
adopted, not what an abandoned scaffold once produced.

Nothing is deleted and nothing is renamed. The legacy record gains exactly one
appended @superseded-by:@ line, which its own v1 parser ignores, so an older
keiro-dsl binary keeps reading it unchanged.
-}
module Keiro.Dsl.WorkspaceAdoption (
    ClaimEvidence (..),
    ClaimedFile (..),
    MigrationReport (..),
    adoptionReport,
    adoptedRows,
    renderMigrationReport,
    markLegacyRecordSuperseded,
    outputTreeFiles,
) where

import Data.List (sort)
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Scaffold (ModuleKind (..), ScaffoldModule (..))
import Keiro.Dsl.ScaffoldRecord (ScaffoldRecord (..), parseRecord, recordFileName)
import Keiro.Dsl.ScaffoldRun (StaleModule (..))
import Keiro.Dsl.WorkspaceRecord (AdoptedRow (..), supersededByLine, workspaceMigrationReportFileName)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

-- | Why a file could be claimed. See the module header.
data ClaimEvidence = ClaimedFromRecord | ClaimedFromBanner
    deriving stock (Eq, Show)

data ClaimedFile = ClaimedFile
    { cfPath :: !FilePath
    , cfEvidence :: !ClaimEvidence
    , cfSource :: !(Maybe Text)
    -- ^ The legacy record's file name, for @record@ evidence.
    , cfSpec :: !(Maybe Text)
    -- ^ The legacy record's @spec:@ field, for @record@ evidence.
    }
    deriving stock (Eq, Show)

{- | What one adopting run found. Printed in the scaffold output and persisted
beside the generated tree as the durable review artifact.
-}
data MigrationReport = MigrationReport
    { mrService :: !Text
    , mrLegacyRecord :: !(Maybe (FilePath, Text))
    -- ^ The legacy record consulted, as @(file name, its @spec:@ field)@.
    , mrClaimed :: ![ClaimedFile]
    , mrLikelyStale :: ![StaleModule]
    , mrUnclaimed :: ![FilePath]
    }
    deriving stock (Eq, Show)

{- | Compute the adoption report for an output directory, or 'Nothing' when
there is nothing to adopt or report (the ordinary case: a fresh directory, or
one this workspace already owns).

Only the workspace's __own effective context__ is consulted. A record for a
different context belongs to a different service and is never read, reported,
or marked.
-}
adoptionReport :: FilePath -> Text -> Text -> [ScaffoldModule] -> IO (Maybe MigrationReport)
adoptionReport out context service modules = do
    legacy <- readLegacyRecord (out </> legacyName)
    present <- Set.fromList <$> outputTreeFiles out
    let plannedGenerated = [modulePath m | m <- modules, kind m == Generated]
        plannedAll = Set.fromList (map modulePath modules)
        onDisk path = path `Set.member` present

        recordedFiles = maybe [] recFiles legacy
        recordSpec = fmap recSpecPath legacy

        claimedFromRecord =
            [ ClaimedFile
                { cfPath = path
                , cfEvidence = ClaimedFromRecord
                , cfSource = Just (T.pack legacyName)
                , cfSpec = recordSpec
                }
            | (Generated, path) <- recordedFiles
            , path `Set.member` plannedAll
            , onDisk path
            ]
        recordClaimedPaths = Set.fromList (map cfPath claimedFromRecord)

    -- A banner claim reads the file, so it is filtered before the read.
    bannerCandidates <-
        traverse
            (\path -> (,) path <$> hasGeneratedBanner (out </> path))
            [ path
            | path <- plannedGenerated
            , onDisk path
            , path `Set.notMember` recordClaimedPaths
            ]
    let claimedFromBanner =
            [ ClaimedFile{cfPath = path, cfEvidence = ClaimedFromBanner, cfSource = Nothing, cfSpec = Nothing}
            | (path, True) <- bannerCandidates
            ]
        claimed = claimedFromRecord <> claimedFromBanner

        likelyStale =
            [ StaleModule fileKind path
            | (fileKind, path) <- recordedFiles
            , path `Set.notMember` plannedAll
            , onDisk path
            ]
        staleOrGenerated =
            Set.fromList (map stalePath likelyStale) <> Set.fromList plannedGenerated

        -- Everything left on disk that this run neither produces nor
        -- attributes. Planned Generated paths are excluded because this run
        -- writes them; saying they were "left untouched" would be false.
        unclaimed = sort [path | path <- Set.toList present, path `Set.notMember` staleOrGenerated]

        report =
            MigrationReport
                { mrService = service
                , mrLegacyRecord = (,) legacyName <$> recordSpec
                , mrClaimed = claimed
                , mrLikelyStale = likelyStale
                , mrUnclaimed = unclaimed
                }
    pure $
        if null claimed && null likelyStale && null unclaimed && isNothing legacy
            then Nothing
            else Just report
  where
    legacyName = recordFileName context

-- | The record rows an adopting run adds to the new workspace record.
adoptedRows :: MigrationReport -> [AdoptedRow]
adoptedRows report =
    [ AdoptedRow
        { adPath = cfPath claimed
        , adEvidence = case cfEvidence claimed of
            ClaimedFromRecord -> "record"
            ClaimedFromBanner -> "banner"
        , adSource = cfSource claimed
        , adSpec = cfSpec claimed
        }
    | claimed <- mrClaimed report
    ]

{- | Append the supersession marker to a legacy record, once. Appending is
idempotent by inspection: a record that already carries the line is left exactly
as it is, so a re-run after an interrupted adoption cannot accumulate markers.
-}
markLegacyRecordSuperseded :: FilePath -> Text -> Text -> IO ()
markLegacyRecordSuperseded out context service = do
    let path = out </> recordFileName context
    exists <- doesFileExist path
    if not exists
        then pure ()
        else do
            contents <- TIO.readFile path
            let marker = supersededByLine service
            if marker `elem` T.lines contents
                then pure ()
                else TIO.writeFile path (ensureNewline contents <> marker <> "\n")
  where
    ensureNewline contents
        | T.null contents || T.isSuffixOf "\n" contents = contents
        | otherwise = contents <> "\n"

-- | Every @.hs@ file under a directory, as sorted paths relative to it.
outputTreeFiles :: FilePath -> IO [FilePath]
outputTreeFiles root = do
    exists <- doesDirectoryExist root
    if not exists then pure [] else sort <$> walk ""
  where
    walk relative = do
        entries <- listDirectory (root </> relative)
        fmap concat . traverse (visit relative) $ sort entries
    visit relative entry = do
        let child = if null relative then entry else relative </> entry
        isDirectory <- doesDirectoryExist (root </> child)
        if isDirectory
            then walk child
            else pure [child | ".hs" `T.isSuffixOf` T.pack child]

readLegacyRecord :: FilePath -> IO (Maybe ScaffoldRecord)
readLegacyRecord path = do
    exists <- doesFileExist path
    if exists then parseRecord <$> TIO.readFile path else pure Nothing

hasGeneratedBanner :: FilePath -> IO Bool
hasGeneratedBanner path = do
    contents <- TIO.readFile path
    pure (any (T.isPrefixOf "-- @generated") (T.lines contents))

{- | Render the report a human reviews. It is printed in the scaffold output and
written to @keiro-dsl-migration-report.workspace.\<service\>.txt@.
-}
renderMigrationReport :: MigrationReport -> [Text]
renderMigrationReport report =
    [ "migration: adopting pre-workspace scaffold output into workspace " <> mrService report
    ]
        <> legacySection
        <> claimedSection
        <> staleSection
        <> unclaimedSection
        <> [ "note: keiro-dsl never deletes files. The legacy record was marked superseded, not removed."
           , "note: the full report is kept at " <> T.pack (workspaceMigrationReportFileName (mrService report))
           ]
  where
    legacySection = case mrLegacyRecord report of
        Nothing -> ["  legacy record: (none for this context)"]
        Just (name, specPath) -> ["  legacy record: " <> T.pack name <> " (spec " <> specPath <> ")"]
    claimedSection = case mrClaimed report of
        [] -> ["  claimed: nothing was attributable to this workspace"]
        claimed ->
            ["  claimed " <> tshow (length claimed) <> " file(s) into workspace history:"]
                <> [ "    " <> evidenceTag (cfEvidence entry) <> "  " <> T.pack (cfPath entry)
                   | entry <- claimed
                   ]
    evidenceTag ClaimedFromRecord = "record"
    evidenceTag ClaimedFromBanner = "banner"
    staleSection = case mrLikelyStale report of
        [] -> []
        stale ->
            [ "  likely stale: "
                <> tshow (length stale)
                <> " file(s) the legacy scaffold recorded that this workspace does not produce:"
            ]
                <> map staleLine stale
    staleLine stale = case staleKind stale of
        Generated -> "    generated " <> T.pack (stalePath stale) <> "  (safe to delete; still on disk)"
        HoleStub -> "    hole      " <> T.pack (stalePath stale) <> "  (hand-owned — review before deleting)"
    unclaimedSection = case mrUnclaimed report of
        [] -> []
        unclaimed ->
            [ "  unclaimed: "
                <> tshow (length unclaimed)
                <> " file(s) this workspace does not own; left untouched:"
            ]
                <> ["    " <> T.pack path | path <- unclaimed]
    tshow :: (Show a) => a -> Text
    tshow = T.pack . show
