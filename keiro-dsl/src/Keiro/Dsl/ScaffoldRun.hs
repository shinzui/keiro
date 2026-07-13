{- | The filesystem-facing scaffold pipeline. It separates pure planning from
execution so every refusal is known before the first output byte is written.
-}
module Keiro.Dsl.ScaffoldRun (
    Refusal (..),
    WriteDisposition (..),
    ScaffoldReport (..),
    scaffoldModules,
    planScaffold,
    executeScaffold,
    renderRefusals,
    renderScaffoldReport,
) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Grammar (Node (..), Spec (..))
import Keiro.Dsl.Harness (harnessFor, harnessProcess, harnessWorkflow)
import Keiro.Dsl.Manifest (moduleNameOf, renderManifest)
import Keiro.Dsl.Scaffold
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))

data Refusal
    = PathCollision !FilePath ![Text]
    | FirewallBreach ![(FilePath, Text, Int)]
    | LoweringRefusal ![Text]
    | MissingGeneratedBanner ![FilePath]
    deriving stock (Eq, Show)

data WriteDisposition = Overwritten | Created | Skipped
    deriving stock (Eq, Show)

data ScaffoldReport = ScaffoldReport
    { reportSpecPath :: !FilePath
    , reportOutDir :: !FilePath
    , reportContext :: !Context
    , reportDispositions :: ![(ScaffoldModule, WriteDisposition)]
    , reportManifestPath :: !FilePath
    }
    deriving stock (Eq, Show)

{- | Produce the complete in-memory module set for a specification. Keeping
this registry in one place prevents the CLI and tests from drifting apart.
-}
scaffoldModules :: Context -> Spec -> [ScaffoldModule]
scaffoldModules ctx spec =
    concat
        [ case node of
            NAggregate agg -> scaffoldAggregate ctx spec agg <> harnessFor ctx spec agg
            NProcess process -> scaffoldProcess ctx process <> harnessProcess ctx process
            NContract contract -> scaffoldContract ctx contract
            NIntake intake -> scaffoldIntake ctx intake
            NPublisher publisher -> scaffoldPublisher ctx publisher
            NWorkqueue workqueue -> scaffoldWorkqueue ctx workqueue
            NWorkflow workflow -> harnessWorkflow ctx workflow
            NEmit _ -> []
            NPgmqDispatch _ -> []
            NOperation _ -> []
        | node <- specNodes spec
        ]

{- | Run every pure refusal gate. A successful result is the exact write set;
a refusal has no write set and therefore cannot be accidentally executed.
-}
planScaffold :: Context -> Spec -> Either [Refusal] [ScaffoldModule]
planScaffold ctx spec =
    let modules = scaffoldModules ctx spec
        breaches = firewallBreaches modules
        refusals =
            collisionRefusals modules
                <> [FirewallBreach breaches | not (null breaches)]
                <> [LoweringRefusal lowering | let lowering = scaffoldRefusals spec, not (null lowering)]
     in if null refusals then Right modules else Left refusals

collisionRefusals :: [ScaffoldModule] -> [Refusal]
collisionRefusals modules =
    [ PathCollision (modulePath first) (map origin (first : rest))
    | first : rest <- Map.elems grouped
    , not (null rest)
    ]
  where
    grouped =
        Map.fromListWith
            (flip (<>))
            [(T.toCaseFold (T.pack (modulePath m)), [m]) | m <- modules]

{- | Check existing generated paths, then perform the deterministic writes and
manifest rewrite. Banner refusal is evaluated for the complete set before the
output directory is created or any file is changed.
-}
executeScaffold :: FilePath -> Bool -> FilePath -> Context -> Spec -> [ScaffoldModule] -> IO (Either [Refusal] ScaffoldReport)
executeScaffold out forceGeneratedOverwrite specPath ctx spec modules = do
    bannerless <- if forceGeneratedOverwrite then pure [] else missingGeneratedBanners out modules
    if not (null bannerless)
        then pure (Left [MissingGeneratedBanner bannerless])
        else do
            createDirectoryIfMissing True out
            dispositions <- mapM (writeModule out) modules
            let manifestPath = out </> ("keiro-dsl-manifest." <> T.unpack (specContext spec) <> ".txt")
            TIO.writeFile manifestPath (renderManifest (T.pack specPath) modules spec)
            pure $
                Right
                    ScaffoldReport
                        { reportSpecPath = specPath
                        , reportOutDir = out
                        , reportContext = ctx
                        , reportDispositions = dispositions
                        , reportManifestPath = manifestPath
                        }

missingGeneratedBanners :: FilePath -> [ScaffoldModule] -> IO [FilePath]
missingGeneratedBanners out modules = fmap concat $ mapM check generated
  where
    generated = [m | m <- modules, kind m == Generated]
    check m = do
        let path = out </> modulePath m
        exists <- doesFileExist path
        if not exists
            then pure []
            else do
                contents <- TIO.readFile path
                pure [modulePath m | not (any (T.isPrefixOf "-- @generated") (T.lines contents))]

writeModule :: FilePath -> ScaffoldModule -> IO (ScaffoldModule, WriteDisposition)
writeModule out m = do
    let path = out </> modulePath m
    createDirectoryIfMissing True (takeDirectory path)
    case kind m of
        Generated -> do
            TIO.writeFile path (moduleText m)
            pure (m, Overwritten)
        HoleStub -> do
            exists <- doesFileExist path
            if exists
                then pure (m, Skipped)
                else TIO.writeFile path (moduleText m) >> pure (m, Created)

renderRefusals :: [Refusal] -> [Text]
renderRefusals = concatMap render
  where
    render (PathCollision path origins) =
        [ "error: module path collision -- refusing to scaffold; nothing was written"
        , "  " <> T.pack path
        ]
            <> ["    from " <> source | source <- origins]
    render (FirewallBreach breaches) =
        [ "error: firewall breach -- refusing to scaffold; nothing was written"
        , "firewall: BREACH (" <> tshow (length breaches) <> " forbidden token occurrence(s)):"
        ]
            <> ["  " <> T.pack path <> ":" <> tshow line <> " contains " <> token | (path, token, line) <- breaches]
    render (LoweringRefusal refusals) =
        ["error: scaffold cannot lower this spec faithfully -- refusing; nothing was written"]
            <> map ("  " <>) refusals
    render (MissingGeneratedBanner paths) =
        [ "error: refusing to overwrite " <> tshow (length paths) <> " file(s) at Generated paths that lack the '-- @generated' banner"
        ]
            <> map ("  " <>) (map T.pack paths)
            <> ["  (adopted as hand code? move it, or re-run with --force-generated-overwrite)", "nothing was written"]

renderScaffoldReport :: ScaffoldReport -> [Text]
renderScaffoldReport report =
    [ "scaffold: " <> T.pack (reportSpecPath report) <> " -> " <> T.pack (reportOutDir report) <> " (module-root=" <> rootLabel <> ", layout=" <> layoutLabel <> ")"
    ]
        <> map moduleLine dispositions
        <> [ "firewall: OK (" <> tshow generatedCount <> " generated modules scanned, 0 forbidden operators)"
           , harnessLine
           , "manifest: " <> T.pack (reportManifestPath report)
           ]
  where
    ctx = reportContext report
    dispositions = reportDispositions report
    rootLabel = if T.null (moduleRoot ctx) then "(none)" else moduleRoot ctx
    layoutLabel = case placement ctx of GeneratedPrefix -> "prefixed"; CollocatedLeaf -> "collocated"
    names = [moduleNameOf (modulePath m) | (m, _) <- dispositions]
    nameWidth = maximum (1 : map T.length names)
    moduleLine (m, disposition) =
        "  " <> kindTag (kind m) <> "  " <> pad (moduleNameOf (modulePath m)) <> "  " <> dispositionTag disposition
    kindTag Generated = "generated"
    kindTag HoleStub = "hole     "
    dispositionTag Overwritten = "(overwritten)"
    dispositionTag Created = "(created)"
    dispositionTag Skipped = "(skipped: already present)"
    pad name = name <> T.replicate (nameWidth - T.length name) " "
    generatedCount = length [() | (m, _) <- dispositions, kind m == Generated]
    harnesses =
        sortOn
            id
            [ moduleNameOf (modulePath m)
            | (m, _) <- dispositions
            , any (`T.isSuffixOf` moduleNameOf (modulePath m)) [".Harness", ".ProcessHarness", ".WorkflowFacts"]
            ]
    harnessLine = case harnesses of
        [] -> "harness:  (none emitted)"
        _ -> "harness:  run `cabal test <your-component>` over " <> T.unwords harnesses

tshow :: (Show a) => a -> Text
tshow = T.pack . show
