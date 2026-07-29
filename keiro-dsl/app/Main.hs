{- | The @keiro-dsl@ command-line tool. EP-1 ships the @parse@ and @check@
subcommands; a later milestone adds @scaffold@ to the same
optparse-applicative command tree.
-}
module Main (main) where

import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Coverage qualified as Coverage
import Keiro.Dsl.Diff (Change (..), CompatibilitySurface, diffSpecs, gateWith, gatedBreaking)
import Keiro.Dsl.DiffReport (diffReport, parseSurfaceName, renderExplainBlock, renderFinding)
import Keiro.Dsl.ExplainBindings (bindingObligations, renderBindingObligations)
import Keiro.Dsl.Goldens (emitGoldenPayloads, loadGoldenPayloads)
import Keiro.Dsl.Grammar (Placement (..), Spec (..))
import Keiro.Dsl.Parser (parseSpec)
import Keiro.Dsl.PrettyPrint (renderSpec)
import Keiro.Dsl.ReplayImpact (renderReplayImpact, replayImpact)
import Keiro.Dsl.Scaffold (Context (..), ScaffoldModule (..), codecComparisonBanner, codecComparisonModule)
import Keiro.Dsl.ScaffoldRun (executeScaffold, planScaffoldWithGoldens, renderRefusals, renderScaffoldReport)
import Keiro.Dsl.Skeleton (skeletonFor)
import Keiro.Dsl.Validate (Diagnostic (..), Severity (..), renderDiagnostic, validateSpec)
import Keiro.Dsl.Workspace (isWorkspacePath, parseWorkspaceManifest, renderWorkspaceManifest)
import Options.Applicative
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (makeRelative, normalise, takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

data Command
    = Parse FilePath
    | Check FilePath Bool Bool (Maybe CheckCoverageOptions)
    | Scaffold FilePath FilePath (Maybe String) Bool Bool (Maybe FilePath) (Maybe (String, FilePath))
    | Diff FilePath String (Maybe FilePath) (Maybe FilePath) [CompatibilitySurface] Bool (Maybe FilePath) (Maybe DiffCoverageOptions)
    | New String

data CheckCoverageOptions = CheckCoverageOptions
    { checkCoveragePath :: !FilePath
    , checkFailOnOpaque :: !Bool
    }

data DiffCoverageOptions = DiffCoverageOptions
    { diffCoveragePath :: !FilePath
    , diffFailOnOpaqueIncrease :: !Bool
    }

main :: IO ()
main = run =<< execParser opts
  where
    opts =
        info
            (commands <**> helper)
            (fullDesc <> progDesc "keiro-dsl: a typed-specification toolchain for keiro services")

commands :: Parser Command
commands =
    subparser
        ( command
            "parse"
            (info (Parse <$> fileArg <**> helper) (progDesc "Parse a .keiro file and pretty-print it back"))
            <> command
                "check"
                (info (Check <$> fileArg <*> emitSwitch <*> explainBindingsSwitch <*> checkCoverageOptions <**> helper) (progDesc "Validate a .keiro file; print diagnostics and exit non-zero on any error"))
            <> command
                "scaffold"
                (info (Scaffold <$> fileArg <*> outOpt <*> optional moduleRootOpt <*> collocateSwitch <*> forceGeneratedOverwriteSwitch <*> optional goldensOpt <*> codecComparisonOpts <**> helper) (progDesc "Emit the generated layer + typed holes from a .keiro file"))
            <> command
                "diff"
                (info (Diff <$> fileArg <*> sinceOpt <*> optional emitGoldensOpt <*> optional replayImpactOutOpt <*> many gateOpt <*> explainSwitch <*> optional reportOutOpt <*> diffCoverageOptions <**> helper) (progDesc "Classify spec changes since a git ref as per-surface compatibility vectors; exit non-zero on any gated BREAKING surface"))
            <> command
                "new"
                (info (New <$> kindArg <**> helper) (progDesc "Print a minimal valid .keiro skeleton for a node kind (aggregate, process, router, contract, intake, emit, publisher, workqueue, dispatch, workflow, operation)"))
        )

outOpt :: Parser FilePath
outOpt = strOption (long "out" <> metavar "DIR" <> help "Output directory for the scaffolded modules")

moduleRootOpt :: Parser String
moduleRootOpt = strOption (long "module-root" <> metavar "PREFIX" <> help "Namespace prefix for emitted modules, e.g. Acme or Acme.Services (overrides the spec's module clause)")

collocateSwitch :: Parser Bool
collocateSwitch = switch (long "collocate" <> help "Place the generated layer as a leaf under the domain (<Ctx>.<Node>.Generated) instead of a parallel Generated.* tree")

forceGeneratedOverwriteSwitch :: Parser Bool
forceGeneratedOverwriteSwitch = switch (long "force-generated-overwrite" <> help "Overwrite a Generated path even when the existing file lacks the @generated banner")

goldensOpt :: Parser FilePath
goldensOpt = strOption (long "goldens" <> metavar "DIR" <> help "Golden-payload root to embed in generated aggregate harnesses")

codecComparisonOpts :: Parser (Maybe (String, FilePath))
codecComparisonOpts =
    optional
        ( (,)
            <$> strOption (long "codec-comparison" <> metavar "MAPPED-NAME" <> help "Emit a non-production historical-codec comparison module for one structural mapped type (requires --comparison-out)")
            <*> strOption (long "comparison-out" <> metavar "FILE" <> help "Exact generated comparison-module path under --out (requires --codec-comparison)")
        )

emitGoldensOpt :: Parser FilePath
emitGoldensOpt = strOption (long "emit-goldens" <> metavar "DIR" <> help "Write old-shape payload fixtures for event version bumps without overwriting existing files")

replayImpactOutOpt :: Parser FilePath
replayImpactOutOpt = strOption (long "replay-impact-out" <> metavar "FILE" <> help "Write the replay-neutral or affected audit input as JSON")

gateOpt :: Parser CompatibilitySurface
gateOpt = option (eitherReader parseSurfaceName) (long "gate" <> metavar "SURFACE" <> help "Also fail on a breaking verdict for this compatibility surface (repeatable)")

explainSwitch :: Parser Bool
explainSwitch = switch (long "explain" <> help "Print containing paths, failing directions, and remediation choices")

reportOutOpt :: Parser FilePath
reportOutOpt = strOption (long "report-out" <> metavar "FILE" <> help "Write the full keiro-dsl/diff-report/1 compatibility report as JSON")

coverageReportOpt :: Parser FilePath
coverageReportOpt = strOption (long "coverage-report" <> metavar "FILE" <> help "Write reporting-only structural/opaque mapped-root coverage as JSON")

checkCoverageOptions :: Parser (Maybe CheckCoverageOptions)
checkCoverageOptions =
    optional
        ( CheckCoverageOptions
            <$> coverageReportOpt
            <*> switch (long "fail-on-opaque" <> help "Fail when a private persisted root contains an opaque boundary (requires --coverage-report)")
        )

diffCoverageOptions :: Parser (Maybe DiffCoverageOptions)
diffCoverageOptions =
    optional
        ( DiffCoverageOptions
            <$> coverageReportOpt
            <*> switch (long "fail-on-opaque-increase" <> help "Fail when diff adds a named opaque boundary (requires --coverage-report)")
        )

emitSwitch :: Parser Bool
emitSwitch = switch (long "emit" <> help "On success, pretty-print the parsed spec to stdout (folds parse + check into one call)")

explainBindingsSwitch :: Parser Bool
explainBindingsSwitch = switch (long "explain-bindings" <> help "On success, list the consumer-owned binding, fixture, and register-initial symbols required by structural mapped types")

sinceOpt :: Parser String
sinceOpt = strOption (long "since" <> metavar "GIT-REF" <> help "Git ref to diff the spec against (e.g. HEAD, a tag, a branch)")

fileArg :: Parser FilePath
fileArg = argument str (metavar "FILE" <> help "Path to a .keiro spec or .keiro-workspace manifest (use /dev/stdin for stdin)")

kindArg :: Parser String
kindArg = argument str (metavar "KIND" <> help "Node kind to scaffold a starter spec for")

run :: Command -> IO ()
-- Workspace dispatch. A @FILE@ ending in @.keiro-workspace@ is a workspace
-- manifest; everything else takes the untouched single-file path below.
run (Parse fp) | isWorkspacePath fp = runWorkspaceParse fp
run (Check fp _ _ _) | isWorkspacePath fp = stagedWorkspaceRefusal "whole-service check lands in a later milestone of docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md"
run (Scaffold fp _ _ _ _ _ _) | isWorkspacePath fp = stagedWorkspaceRefusal "workspace scaffolding is not yet supported; it lands with docs/plans/154-scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records.md"
run (Diff fp _ _ _ _ _ _ _) | isWorkspacePath fp = stagedWorkspaceRefusal "workspace diff is not yet supported; it lands with docs/plans/155-diff-whole-workspaces-with-shared-declaration-impact-classification-and-unified-compatibility-reports.md"
run (Parse fp) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> TIO.putStrLn (renderSpec spec)
run (Check fp emit explainBindings coverageOptions) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> do
            let diags = validateSpec spec
            mapM_ (TIO.hPutStrLn stderr . renderDiagnostic fp) diags
            if any ((== Error) . severity) diags
                then exitFailure
                else do
                    when emit (TIO.putStrLn (renderSpec spec))
                    if explainBindings
                        then case bindingObligations spec of
                            Left graphErrors -> do
                                hPutStrLn stderr ("validated spec did not resolve its mapped type graph: " <> show graphErrors)
                                exitFailure
                            Right obligations -> TIO.putStrLn (renderBindingObligations (specContext spec) obligations)
                        else pure ()
                    coverageOk <- runCheckCoverage fp spec coverageOptions
                    when (coverageOk && not emit && not explainBindings) (putStrLn "OK")
                    when (not coverageOk) exitFailure
run (Scaffold fp out cliRoot cliCollocate forceGeneratedOverwrite cliGoldens comparisonRequest) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> do
            -- Validation gate: never scaffold an invalid spec. Abort on any
            -- error-severity diagnostic before writing a single module.
            let diags = validateSpec spec
            mapM_ (TIO.hPutStrLn stderr . renderDiagnostic fp) diags
            when (any ((== Error) . severity) diags) exitFailure
            let ctx = mkContext cliRoot cliCollocate spec
                goldenRoot = fromMaybe (takeDirectory fp </> "golden-payloads") cliGoldens
            goldens <- loadGoldenPayloads goldenRoot spec
            case (planScaffoldWithGoldens goldens ctx spec, traverse (\(name, _) -> codecComparisonModule ctx spec (T.pack name)) comparisonRequest) of
                (Left refusals, _) -> do
                    mapM_ (TIO.hPutStrLn stderr) (renderRefusals refusals)
                    exitFailure
                (_, Left comparisonError) -> TIO.hPutStrLn stderr comparisonError >> exitFailure
                (Right modules, Right comparisonModule) -> do
                    comparisonReady <- preflightComparison out comparisonRequest comparisonModule
                    case comparisonReady of
                        Left comparisonError -> TIO.hPutStrLn stderr comparisonError >> exitFailure
                        Right () -> do
                            result <- executeScaffold out forceGeneratedOverwrite fp ctx spec modules
                            case result of
                                Left refusals -> do
                                    mapM_ (TIO.hPutStrLn stderr) (renderRefusals refusals)
                                    exitFailure
                                Right report -> do
                                    mapM_ (TIO.hPutStrLn stderr) (renderScaffoldReport report)
                                    writeComparison comparisonRequest comparisonModule
run (New kind) =
    case skeletonFor (T.pack kind) of
        Left err -> hPutStrLn stderr (T.unpack err) >> exitFailure
        Right skel -> TIO.putStr skel
run (Diff fp ref emitGoldensRoot replayImpactOut gatedSurfaces explain reportOut coverageOptions) = do
    -- Resolve the spec to a repo-relative path so `git show <ref>:<relpath>` works.
    let dir = takeDirectory fp
    rootRes <- git dir ["rev-parse", "--show-toplevel"]
    case rootRes of
        Left err -> hPutStrLn stderr err >> exitFailure
        Right rootRaw -> do
            let repoRoot = trim rootRaw
            absFp <- canonicalizePath fp
            let relPath = makeRelative repoRoot absFp
            oldRes <- git repoRoot ["show", ref <> ":" <> relPath]
            case oldRes of
                Left err -> hPutStrLn stderr ("git show " <> ref <> ":" <> relPath <> " failed:\n" <> err) >> exitFailure
                Right oldText -> do
                    newText <- TIO.readFile fp
                    case (,) <$> parseSpec (ref <> ":" <> relPath) (T.pack oldText) <*> parseSpec fp newText of
                        Left perr -> hPutStrLn stderr (T.unpack perr) >> exitFailure
                        Right (oldSpec, newSpec) -> do
                            written <- maybe (pure []) (\root -> emitGoldenPayloads root oldSpec newSpec) emitGoldensRoot
                            mapM_ (putStrLn . ("golden: wrote synthesized weak stand-in " <>)) written
                            let changes = diffSpecs oldSpec newSpec
                                impact = replayImpact oldSpec newSpec
                                effectiveGate = gateWith gatedSurfaces
                            mapM_ (TIO.putStrLn . renderFinding) changes
                            when explain $
                                mapM_ (TIO.putStrLn . renderExplainBlock) (filter shouldExplain changes)
                            TIO.putStrLn (renderReplayImpact impact)
                            mapM_ (`Aeson.encodeFile` impact) replayImpactOut
                            mapM_ (\path -> Aeson.encodeFile path (diffReport effectiveGate changes)) reportOut
                            coverageOk <- runDiffCoverage fp (T.pack ref) oldSpec newSpec coverageOptions
                            if any (gatedBreaking effectiveGate) changes || not coverageOk then exitFailure else pure ()

{- | @parse@ on a workspace manifest: read it, parse it, and print it back in
canonical form (clauses in order, members codepoint-sorted).
-}
runWorkspaceParse :: FilePath -> IO ()
runWorkspaceParse fp = do
    input <- TIO.readFile fp
    case parseWorkspaceManifest fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right manifest -> TIO.putStrLn (renderWorkspaceManifest manifest)

{- | A command that recognizes a workspace manifest but whose whole-workspace
implementation lands in a named later plan. Naming the owning plan keeps the
refusal honest while the MasterPlan is only partly delivered, and prevents the
misleading megaparsec error a manifest would otherwise produce if it were
handed to the @.keiro@ parser.
-}
stagedWorkspaceRefusal :: String -> IO ()
stagedWorkspaceRefusal message = hPutStrLn stderr message >> exitFailure

shouldExplain :: Change -> Bool
shouldExplain Additive{} = False
shouldExplain Advisory{} = True
shouldExplain Breaking{} = True

-- | Run git in a directory, returning trimmed stdout or stderr.
git :: FilePath -> [String] -> IO (Either String String)
git dir args = do
    (ec, out, err) <- readProcessWithExitCode "git" (["-C", dir] <> args) ""
    pure $ case ec of
        ExitSuccess -> Right out
        ExitFailure _ -> Left (if null err then out else err)

trim :: String -> String
trim = f . f where f = reverse . dropWhile (`elem` (" \t\r\n" :: String))

preflightComparison :: FilePath -> Maybe (String, FilePath) -> Maybe ScaffoldModule -> IO (Either T.Text ())
preflightComparison _ Nothing Nothing = pure (Right ())
preflightComparison out (Just (_, requestedPath)) (Just comparisonModule) = do
    let expectedPath = normalise (out </> modulePath comparisonModule)
        actualPath = normalise requestedPath
    if actualPath /= expectedPath
        then
            pure
                ( Left
                    ( "--comparison-out must match the generated module path under --out: expected "
                        <> T.pack expectedPath
                    )
                )
        else do
            exists <- doesFileExist actualPath
            if not exists
                then pure (Right ())
                else do
                    existing <- TIO.readFile actualPath
                    pure
                        ( if codecComparisonBanner `elem` T.lines existing
                            then Right ()
                            else Left ("refusing to overwrite non-comparison output: " <> T.pack actualPath)
                        )
preflightComparison _ _ _ = pure (Left "internal error: incomplete codec-comparison option pair")

writeComparison :: Maybe (String, FilePath) -> Maybe ScaffoldModule -> IO ()
writeComparison Nothing Nothing = pure ()
writeComparison (Just (_, path)) (Just comparisonModule) = do
    createDirectoryIfMissing True (takeDirectory path)
    TIO.writeFile path (moduleText comparisonModule)
    TIO.hPutStrLn stderr ("comparison generated " <> T.pack path <> " (migration evidence only)")
writeComparison _ _ = hPutStrLn stderr "internal error: incomplete codec-comparison output" >> exitFailure

runCheckCoverage :: FilePath -> Spec -> Maybe CheckCoverageOptions -> IO Bool
runCheckCoverage _ _ Nothing = pure True
runCheckCoverage specPath spec (Just options) =
    case Coverage.coverageReport specPath spec of
        Left graphErrors -> do
            hPutStrLn stderr ("validated spec did not resolve its mapped type graph for coverage: " <> show graphErrors)
            pure False
        Right baseReport -> do
            let report = if checkFailOnOpaque options then Coverage.failOnOpaque baseReport else baseReport
            emitCoverageReport (checkCoveragePath options) report

runDiffCoverage :: FilePath -> T.Text -> Spec -> Spec -> Maybe DiffCoverageOptions -> IO Bool
runDiffCoverage _ _ _ _ Nothing = pure True
runDiffCoverage specPath reference oldSpec newSpec (Just options) =
    case Coverage.coverageDiffReport specPath reference oldSpec newSpec of
        Left graphErrors -> do
            hPutStrLn stderr ("diff specs did not resolve their mapped type graph for coverage: " <> show graphErrors)
            pure False
        Right baseReport -> do
            let report = if diffFailOnOpaqueIncrease options then Coverage.failOnOpaqueIncrease baseReport else baseReport
            emitCoverageReport (diffCoveragePath options) report

emitCoverageReport :: FilePath -> Coverage.CoverageReport -> IO Bool
emitCoverageReport path report = do
    mapM_ (TIO.hPutStrLn stderr . Coverage.renderCoverageFinding (Coverage.coverageSpec report)) (Coverage.coverageFindings report)
    TIO.putStr (Coverage.renderCoverageSummary report)
    Coverage.writeCoverageReport path report
    putStrLn ("coverage report written to " <> path)
    pure (Coverage.coverageSucceeded report)

{- | Fold the spec's @module@/@layout@ clauses with the CLI overrides to a
'Context'. Precedence is CLI flag > spec clause > built-in default.
-}
mkContext :: Maybe String -> Bool -> Spec -> Context
mkContext cliRoot cliCollocate spec =
    Context
        { contextName = specContext spec
        , moduleRoot = maybe (fromMaybe "" (specModuleRoot spec)) T.pack cliRoot
        , placement =
            if cliCollocate
                then CollocatedLeaf
                else fromMaybe GeneratedPrefix (specLayout spec)
        }
