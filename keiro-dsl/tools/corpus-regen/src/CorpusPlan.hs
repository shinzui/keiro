module CorpusPlan
  ( CorpusEntry (..),
    entryOutDir,
    loadCorpusPlan,
    renderInvocation,
  )
where

import Data.Either (partitionEithers)
import Data.List (isPrefixOf, isSuffixOf, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.ScaffoldRecord (ScaffoldRecord (..), parseRecord)
import Keiro.Dsl.WorkspaceRecord (WorkspaceRecord, parseWorkspaceRecord)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, makeRelative, splitDirectories, takeDirectory, takeFileName, (</>))
import System.Process (readProcessWithExitCode)

data CorpusEntry
  = SingleSpec
      { ceSpecPath :: FilePath,
        ceOutDir :: FilePath,
        ceModuleRoot :: Maybe Text,
        ceCollocate :: Bool,
        ceExtraArgs :: [Text]
      }
  | WorkspaceSpec
      { ceManifestPath :: FilePath,
        ceOutDir :: FilePath
      }
  | SkeletonRun
      { ceKind :: Text,
        ceRoot :: Text,
        ceOutDir :: FilePath
      }
  deriving stock (Eq, Show)

entryOutDir :: CorpusEntry -> FilePath
entryOutDir = ceOutDir

renderInvocation :: CorpusEntry -> [String]
renderInvocation SingleSpec {ceSpecPath, ceOutDir, ceModuleRoot, ceCollocate, ceExtraArgs} =
  ["scaffold", ceSpecPath, "--out", ceOutDir]
    <> maybe [] (\root -> ["--module-root", T.unpack root]) ceModuleRoot
    <> ["--collocate" | ceCollocate]
    <> map T.unpack ceExtraArgs
renderInvocation WorkspaceSpec {ceManifestPath, ceOutDir} =
  ["scaffold", ceManifestPath, "--out", ceOutDir]
renderInvocation SkeletonRun {ceRoot, ceOutDir} =
  ["scaffold", "/dev/stdin", "--out", ceOutDir, "--module-root", T.unpack ceRoot]

data Supplement = Supplement
  { supWorkspaces :: [(FilePath, FilePath)],
    supSkeletons :: [(Text, Text, FilePath)],
    supExtraArgs :: [(FilePath, [Text])],
    supExemptions :: [FilePath]
  }
  deriving stock (Eq, Show)

data RecordHistory
  = SingleHistory FilePath ScaffoldRecord
  | WorkspaceHistory FilePath WorkspaceRecord

loadCorpusPlan :: FilePath -> IO (Either [Text] ([CorpusEntry], [FilePath]))
loadCorpusPlan repoRoot = do
  supplementResult <- loadSupplement (repoRoot </> manifestPath)
  historiesResult <- loadTrackedHistories repoRoot
  pure $ do
    supplement <- supplementResult
    histories <- historiesResult
    buildPlan repoRoot supplement histories

manifestPath :: FilePath
manifestPath = "keiro-dsl/test/conformance-corpus-manifest.txt"

loadSupplement :: FilePath -> IO (Either [Text] Supplement)
loadSupplement path = do
  contents <- TIO.readFile path
  pure (parseSupplement path contents)

parseSupplement :: FilePath -> Text -> Either [Text] Supplement
parseSupplement path contents =
  case meaningfulLines of
    [] -> Left [label <> " is empty"]
    (_, header) : rows
      | header /= "keiro-dsl conformance corpus manifest v1" ->
          Left [label <> " has an unsupported header: " <> header]
      | otherwise ->
          let (rowErrors, parsedRows) = partitionEithers (map parseRow rows)
              supplement = foldr addRow emptySupplement parsedRows
              duplicateErrors = validateSupplement supplement
           in if null rowErrors && null duplicateErrors
                then Right supplement
                else Left (rowErrors <> duplicateErrors)
  where
    label = T.pack path
    meaningfulLines =
      [ (lineNumber, T.strip line)
      | (lineNumber, line) <- zip [1 :: Int ..] (T.lines contents),
        let stripped = T.strip line,
        not (T.null stripped),
        not ("#" `T.isPrefixOf` stripped)
      ]
    parseRow (lineNumber, row) =
      let failure message = Left (label <> ":" <> T.pack (show lineNumber) <> ": " <> message)
          checked paths value =
            case filter (not . safeRelativePath) paths of
              [] -> Right value
              unsafe : _ -> failure ("unsafe repository-relative path: " <> T.pack unsafe)
       in case T.words row of
            ["workspace", manifest, outDir] ->
              checked [T.unpack manifest, T.unpack outDir] (WorkspaceRow (T.unpack manifest) (T.unpack outDir))
            ["skeleton", kind, root, outDir] ->
              checked [T.unpack outDir] (SkeletonRow kind root (T.unpack outDir))
            "extra-args" : outDir : args
              | not (null args) ->
                  checked [T.unpack outDir] (ExtraArgsRow (T.unpack outDir) args)
            ["uncompiled-generated", modulePath] ->
              checked [T.unpack modulePath] (ExemptionRow (T.unpack modulePath))
            _ -> failure ("invalid manifest row: " <> row)

data SupplementRow
  = WorkspaceRow FilePath FilePath
  | SkeletonRow Text Text FilePath
  | ExtraArgsRow FilePath [Text]
  | ExemptionRow FilePath

emptySupplement :: Supplement
emptySupplement = Supplement [] [] [] []

addRow :: SupplementRow -> Supplement -> Supplement
addRow row supplement = case row of
  WorkspaceRow manifest outDir -> supplement {supWorkspaces = (manifest, outDir) : supWorkspaces supplement}
  SkeletonRow kind root outDir -> supplement {supSkeletons = (kind, root, outDir) : supSkeletons supplement}
  ExtraArgsRow outDir args -> supplement {supExtraArgs = (outDir, args) : supExtraArgs supplement}
  ExemptionRow path -> supplement {supExemptions = path : supExemptions supplement}

validateSupplement :: Supplement -> [Text]
validateSupplement supplement =
  duplicateMessages "workspace out-dir" (map snd (supWorkspaces supplement))
    <> duplicateMessages "extra-args out-dir" (map fst (supExtraArgs supplement))
    <> duplicateMessages "uncompiled-generated path" (supExemptions supplement)
  where
    duplicateMessages label values =
      [ "duplicate " <> label <> " in corpus manifest: " <> T.pack value
      | value <- duplicates values
      ]

loadTrackedHistories :: FilePath -> IO (Either [Text] [RecordHistory])
loadTrackedHistories repoRoot = do
  (exitCode, stdoutText, stderrText) <-
    readProcessWithExitCode "git" ["-C", repoRoot, "ls-files", "keiro-dsl/test"] ""
  case exitCode of
    ExitFailure _ -> pure (Left ["git ls-files failed: " <> T.pack (trim stderrText)])
    ExitSuccess -> do
      let recordPaths = filter isRecordPath (lines stdoutText)
      loaded <- traverse (loadHistory repoRoot) recordPaths
      let (errors, histories) = partitionEithers loaded
      pure $ if null errors then Right histories else Left (concat errors)

isRecordPath :: FilePath -> Bool
isRecordPath path =
  let name = takeFileName path
   in "keiro-dsl-scaffold-record." `isPrefixOf` name && ".txt" `isSuffixOf` name

loadHistory :: FilePath -> FilePath -> IO (Either [Text] RecordHistory)
loadHistory repoRoot recordPath = do
  contents <- TIO.readFile (repoRoot </> recordPath)
  pure $ case (parseRecord contents, parseWorkspaceRecord contents) of
    (Just record, Nothing) -> Right (SingleHistory recordPath record)
    (Nothing, Just record) -> Right (WorkspaceHistory recordPath record)
    (Nothing, Nothing) -> Left [T.pack recordPath <> ": record does not parse"]
    (Just _, Just _) -> Left [T.pack recordPath <> ": record ambiguously matches both formats"]

buildPlan :: FilePath -> Supplement -> [RecordHistory] -> Either [Text] ([CorpusEntry], [FilePath])
buildPlan repoRoot supplement histories =
  if null errors
    then Right (orderedEntries, supExemptions supplement)
    else Left errors
  where
    extraArgs = Map.fromList (supExtraArgs supplement)
    workspaceRows = Map.fromList [(outDir, manifest) | (manifest, outDir) <- supWorkspaces supplement]
    singleRecords = [(recordOutDir repoRoot path, record) | SingleHistory path record <- histories]
    workspaceRecords = [recordOutDir repoRoot path | WorkspaceHistory path _ <- histories]
    stdinDirs = Set.fromList [outDir | (outDir, record) <- singleRecords, recSpecPath record == "/dev/stdin"]
    ordinaryRecords = [(outDir, record) | (outDir, record) <- singleRecords, recSpecPath record /= "/dev/stdin"]
    ordinaryDirs = Set.fromList (map fst ordinaryRecords)
    workspaceDirs = Set.fromList workspaceRecords
    skeletonDirs = Set.fromList [outDir | (_, _, outDir) <- supSkeletons supplement]
    singleEntries = map makeSingle ordinaryRecords
    workspaceEntries =
      [ WorkspaceSpec manifest outDir
      | outDir <- workspaceRecords,
        Just manifest <- [Map.lookup outDir workspaceRows]
      ]
    skeletonEntries = [SkeletonRun kind root outDir | (kind, root, outDir) <- supSkeletons supplement]
    orderedEntries = sortOn entryOutDir (singleEntries <> workspaceEntries) <> skeletonEntries
    errors =
      ["no tracked scaffold records were found under keiro-dsl/test" | null histories]
        <> duplicateHistoryErrors
        <> unclaimedStdinErrors
        <> unclaimedSkeletonErrors
        <> unclaimedWorkspaceRecordErrors
        <> unclaimedWorkspaceRowErrors
        <> unclaimedExtraArgsErrors
        <> unsafeInputErrors
    duplicateHistoryErrors =
      [ "multiple tracked scaffold records claim output directory " <> T.pack outDir
      | outDir <- duplicates (map (historyOutDir repoRoot) histories)
      ]
    unclaimedStdinErrors =
      [ "stdin scaffold record has no skeleton rows: " <> T.pack outDir
      | outDir <- Set.toList (stdinDirs `Set.difference` skeletonDirs)
      ]
    unclaimedSkeletonErrors =
      [ "skeleton rows have no stdin scaffold record: " <> T.pack outDir
      | outDir <- Set.toList (skeletonDirs `Set.difference` stdinDirs)
      ]
    unclaimedWorkspaceRecordErrors =
      [ "workspace scaffold record has no workspace manifest row: " <> T.pack outDir
      | outDir <- Set.toList (workspaceDirs `Set.difference` Map.keysSet workspaceRows)
      ]
    unclaimedWorkspaceRowErrors =
      [ "workspace manifest row has no tracked workspace record: " <> T.pack outDir
      | outDir <- Set.toList (Map.keysSet workspaceRows `Set.difference` workspaceDirs)
      ]
    unclaimedExtraArgsErrors =
      [ "extra-args row has no ordinary single-spec record: " <> T.pack outDir
      | outDir <- Set.toList (Map.keysSet extraArgs `Set.difference` ordinaryDirs)
      ]
    unsafeInputErrors =
      [ "corpus input is not a safe repository-relative path: " <> T.pack input
      | input <- map ceSpecPath singleEntries <> map ceManifestPath workspaceEntries,
        not (safeRelativePath input)
      ]
    makeSingle (outDir, record) =
      SingleSpec
        { ceSpecPath = T.unpack (recSpecPath record),
          ceOutDir = outDir,
          ceModuleRoot = nonEmpty (recModuleRoot record),
          ceCollocate = recLayout record == "collocated",
          ceExtraArgs = Map.findWithDefault [] outDir extraArgs
        }

recordOutDir :: FilePath -> FilePath -> FilePath
recordOutDir repoRoot recordPath = makeRelative repoRoot (takeDirectory (repoRoot </> recordPath))

historyOutDir :: FilePath -> RecordHistory -> FilePath
historyOutDir repoRoot history = case history of
  SingleHistory path _ -> recordOutDir repoRoot path
  WorkspaceHistory path _ -> recordOutDir repoRoot path

safeRelativePath :: FilePath -> Bool
safeRelativePath path =
  not (null path)
    && not (isAbsolute path)
    && ".." `notElem` splitDirectories path

nonEmpty :: Text -> Maybe Text
nonEmpty value
  | T.null value = Nothing
  | otherwise = Just value

duplicates :: (Ord a) => [a] -> [a]
duplicates values =
  Map.keys (Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(value, 1 :: Int) | value <- values]))

trim :: String -> String
trim = reverse . dropWhile (`elem` ['\n', '\r', ' ', '\t']) . reverse
