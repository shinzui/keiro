-- | The @keiro-dsl@ command-line tool. EP-1 ships the @parse@ and @check@
-- subcommands; a later milestone adds @scaffold@ to the same
-- optparse-applicative command tree.
module Main (main) where

import Control.Monad (when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Text qualified as AesonText
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy.IO qualified as TLIO
import Keiro.Dsl.BehaviorCoverage qualified as Behavior
import Keiro.Dsl.CheckReport qualified as CheckReport
import Keiro.Dsl.Coverage qualified as Coverage
import Keiro.Dsl.Diff (Change (..), CompatibilitySurface, diffSources, gateWith, gatedBreaking)
import Keiro.Dsl.DiffReport (diffReport, parseSurfaceName, renderExplainBlock, renderFinding)
import Keiro.Dsl.ExplainBindings (bindingObligationsForService, renderBindingObligations)
import Keiro.Dsl.FoldFingerprint (renderFoldSurfaceError)
import Keiro.Dsl.Goldens (emitGoldenPayloads, loadGoldenPayloads)
import Keiro.Dsl.Grammar (Loc (..), Placement (..), Spec (..))
import Keiro.Dsl.LanguageVersion (LanguageVersion, ParsedSource (..), SourceLanguage (..), declaredLanguageVersionMaybe, effectiveLanguageVersion, languageVersion, languageVersionText, lookupLanguageDefinition, sourceFormText, supportedLanguageVersions)
import Keiro.Dsl.Parser (parseSource, renderParseFailure)
import Keiro.Dsl.PrettyPrint (renderSource, renderSpec)
import Keiro.Dsl.ReplayImpact (renderReplayImpact, replayImpactServices)
import Keiro.Dsl.RuntimePackage (RuntimePackageName, mkRuntimePackageName)
import Keiro.Dsl.Scaffold (Context (..), ScaffoldModule (..), codecComparisonBanner, codecComparisonModule)
import Keiro.Dsl.ScaffoldRun (checkServiceDiagnostics, executeServiceScaffoldWithRuntimePackageAndNameMigrations, planServiceScaffoldWithRuntimePackageAndGoldens, renderRefusals, renderScaffoldReport)
import Keiro.Dsl.SemanticContract (CheckedService (..), checkedSource, effectiveContractLanguageVersion, languageContractNotice)
import Keiro.Dsl.Skeleton (skeletonFor)
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode (..), DiagnosticOrigin (..), Severity (..), diagnosticCodeText, diagnosticOrigin, minimumLanguageDiagnostics, parseDiagnosticCode, renderDiagnostic, validateService)
import Keiro.Dsl.Workspace (ContentSource (..), LineMap (..), OwnershipIndex (..), WorkspaceDiagnostic (..), WorkspaceFailure (..), WorkspaceFile (..), WorkspaceLocation (..), WorkspaceManifest (..), WorkspaceMember (..), WorkspaceMemberRef (..), WorkspaceSpec (..), checkWorkspace, checkedWorkspace, fileContentSource, isWorkspacePath, loadWorkspace, nodeOwner, parseWorkspaceManifest, renderWorkspaceDiagnostic, renderWorkspaceFailure, renderWorkspaceManifest)
import Keiro.Dsl.WorkspaceDiff (WorkspaceChange (..), WorkspaceMeta (..), diffWorkspaces, renderWorkspaceFinding, workspaceDiffReport)
import Keiro.Dsl.WorkspaceScaffold (executeWorkspaceScaffoldWithNameMigrations, planWorkspaceScaffoldWithRuntimePackageAndGoldens, renderWorkspaceScaffoldReport)
import Numeric.Natural (Natural)
import Options.Applicative
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (isAbsolute, makeRelative, normalise, takeDirectory, takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

data Command
  = Parse FilePath
  | Pretty FilePath
  | Check FilePath CheckOptions
  | Inspect FilePath InspectionFormat
  | BehaviorObligations FilePath BehaviorFormat
  | Scaffold FilePath FilePath (Maybe String) (Maybe RuntimePackageName) Bool Bool Bool (Maybe FilePath) (Maybe (String, FilePath))
  | Diff FilePath String (Maybe FilePath) (Maybe FilePath) [CompatibilitySurface] Bool (Maybe FilePath) (Maybe DiffCoverageOptions)
  | New String

data InspectionFormat = InspectionJson

data BehaviorFormat = BehaviorText | BehaviorJson

data CheckCoverageOptions = CheckCoverageOptions
  { checkCoveragePath :: !FilePath,
    checkFailOnOpaque :: !Bool
  }

data CheckOptions = CheckOptions
  { checkEmit :: !Bool,
    checkExplainBindings :: !Bool,
    checkCoverage :: !(Maybe CheckCoverageOptions),
    checkMinLanguage :: !(Maybe LanguageVersion),
    checkDenyWarnings :: !Bool,
    checkDenyCodes :: ![DiagnosticCode],
    checkReportOut :: !(Maybe FilePath)
  }

data DiffCoverageOptions = DiffCoverageOptions
  { diffCoveragePath :: !FilePath,
    diffFailOnOpaqueIncrease :: !Bool
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
          "pretty"
          (info (Pretty <$> fileArg <**> helper) (progDesc "Parse a .keiro file and print its canonical source form"))
        <> command
          "check"
          (info (Check <$> fileArg <*> checkOptions <**> helper) (progDesc "Validate a .keiro file; print diagnostics and exit non-zero on any error"))
        <> command
          "inspect"
          (info (Inspect <$> fileArg <*> inspectionFormatOpt <**> helper) (progDesc "Inspect source-language provenance for a .keiro file or workspace as JSON"))
        <> command
          "behavior-obligations"
          (info (BehaviorObligations <$> fileArg <*> behaviorFormatOpt <**> helper) (progDesc "List static aggregate behavior obligations for a .keiro file or workspace"))
        <> command
          "scaffold"
          (info (Scaffold <$> fileArg <*> outOpt <*> optional moduleRootOpt <*> optional runtimePackageOpt <*> collocateSwitch <*> forceGeneratedOverwriteSwitch <*> applyNameMigrationsSwitch <*> optional goldensOpt <*> codecComparisonOpts <**> helper) (progDesc "Emit the generated layer + typed holes from a .keiro file"))
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

runtimePackageOpt :: Parser RuntimePackageName
runtimePackageOpt =
  option
    ( eitherReader $ \raw -> case mkRuntimePackageName (T.pack raw) of
        Left message -> Left (T.unpack message)
        Right packageName -> Right packageName
    )
    (long "runtime-package" <> metavar "PACKAGE" <> help "Cabal package that compiles the generated service runtime (overrides the workspace manifest)")

collocateSwitch :: Parser Bool
collocateSwitch = switch (long "collocate" <> help "Place the generated layer as a leaf under the domain (<Ctx>.<Node>.Generated) instead of a parallel Generated.* tree")

forceGeneratedOverwriteSwitch :: Parser Bool
forceGeneratedOverwriteSwitch = switch (long "force-generated-overwrite" <> help "Overwrite a Generated path even when the existing file lacks the @generated banner")

applyNameMigrationsSwitch :: Parser Bool
applyNameMigrationsSwitch = switch (long "apply-name-migrations" <> help "Apply reviewed generated-Haskell source and sidecar moves with recoverable backups")

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

checkOptions :: Parser CheckOptions
checkOptions =
  CheckOptions
    <$> emitSwitch
    <*> explainBindingsSwitch
    <*> checkCoverageOptions
    <*> optional minLanguageOpt
    <*> switch (long "deny-warnings" <> help "Exit non-zero when any warning-severity diagnostic fires")
    <*> denyCodesOptions
    <*> optional checkReportOutOpt

minLanguageOpt :: Parser LanguageVersion
minLanguageOpt =
  option
    (eitherReader parseMinimumLanguage)
    (long "min-language" <> metavar "N" <> help "Require at least released keiro-dsl language version N")

parseMinimumLanguage :: String -> Either String LanguageVersion
parseMinimumLanguage raw =
  case (readMaybe raw :: Maybe Natural) >>= languageVersion of
    Just version
      | Just _ <- lookupLanguageDefinition version -> Right version
    _ ->
      Left
        ( "minimum keiro-dsl language version "
            <> raw
            <> " is unsupported; supported versions: "
            <> T.unpack (T.intercalate ", " (map languageVersionText (NE.toList supportedLanguageVersions)))
        )

denyCodesOptions :: Parser [DiagnosticCode]
denyCodesOptions =
  concat
    <$> many
      ( option
          (eitherReader parseDenyCodes)
          (long "deny" <> metavar "CODE[,CODE...]" <> help "Exit non-zero for warning diagnostics with these stable codes (repeatable)")
      )

-- | Parse a @--deny@ argument, refusing codes @check@ can never emit.
--
-- A denial that can never match is worse than no denial: it reads like a gate in
-- a CI file and silently is not one. Diff-side and codec-comparison codes are
-- therefore rejected outright here. Coverage codes are accepted at this stage
-- and validated against @--coverage-report@ once the whole invocation is known,
-- because an option reader cannot see its sibling options.
parseDenyCodes :: String -> Either String [DiagnosticCode]
parseDenyCodes raw = traverse parseOne (T.splitOn "," (T.pack raw))
  where
    parseOne token
      | T.null token = Left "--deny requires one or more comma-separated diagnostic codes"
      | otherwise = case parseDiagnosticCode token of
          Just diagnosticCode -> classify token diagnosticCode
          Nothing ->
            Left
              ( "unknown diagnostic code `"
                  <> T.unpack token
                  <> "`; copy the spelling exactly from warning[Code] output"
              )
    classify token diagnosticCode = case diagnosticOrigin diagnosticCode of
      CheckDiagnostic -> Right diagnosticCode
      CoverageDiagnostic -> Right diagnosticCode
      DiffDiagnostic ->
        Left
          ( "diagnostic code `"
              <> T.unpack token
              <> "` is emitted by `keiro-dsl diff`, which compares two revisions; `check` can never emit it, so denying it here would never match"
          )
      CodecCompareDiagnostic ->
        Left
          ( "diagnostic code `"
              <> T.unpack token
              <> "` is emitted only by the generated codec-comparison path; `check` can never emit it, so denying it here would never match"
          )

-- | Reject a @--deny@ selection of a coverage code when this invocation never
-- runs the coverage pass, for the same reason 'parseDenyCodes' rejects
-- diff-side codes: the denial could not fire.
--
-- 'CoverageOpaqueGateExceeded' is refused outright: it is the error
-- @--fail-on-opaque@ itself raises, never a warning, so the deny scan can never
-- match it — without the flag the code does not fire at all, and with the flag
-- the run already fails. A denial in CI must be either effective or an
-- immediate error, and this one could only ever be a silent no-op.
validateCheckDenyCodes :: CheckOptions -> IO ()
validateCheckDenyCodes options = do
  when (CoverageOpaqueGateExceeded `elem` checkDenyCodes options) $ do
    TIO.hPutStrLn
      stderr
      "check: --deny CoverageOpaqueGateExceeded can never match; the code is the error --fail-on-opaque itself raises, so pass --fail-on-opaque instead of denying it"
    exitFailure
  case [diagnosticCode | diagnosticCode <- checkDenyCodes options, diagnosticOrigin diagnosticCode == CoverageDiagnostic, diagnosticCode /= CoverageOpaqueGateExceeded] of
    [] -> pure ()
    unreachable
      | Just _ <- checkCoverage options -> pure ()
      | otherwise -> do
          TIO.hPutStrLn
            stderr
            ( "check: --deny "
                <> T.intercalate ", " (map diagnosticCodeText unreachable)
                <> " selects a structural-coverage code, which only the coverage pass emits; add --coverage-report FILE or drop the code"
            )
          exitFailure

checkReportOutOpt :: Parser FilePath
checkReportOutOpt =
  strOption
    (long "report-out" <> metavar "FILE" <> help "Write the full keiro-dsl/check-report/1 validation report as JSON")

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

inspectionFormatOpt :: Parser InspectionFormat
inspectionFormatOpt =
  option
    (eitherReader parseFormat)
    (long "format" <> metavar "json" <> value InspectionJson <> help "Inspection output format (json)")
  where
    parseFormat "json" = Right InspectionJson
    parseFormat other = Left ("unsupported inspection format: " <> other <> " (expected json)")

behaviorFormatOpt :: Parser BehaviorFormat
behaviorFormatOpt =
  option
    (eitherReader parseFormat)
    (long "format" <> metavar "text|json" <> value BehaviorText <> help "Behavior obligation output format (text or json)")
  where
    parseFormat "text" = Right BehaviorText
    parseFormat "json" = Right BehaviorJson
    parseFormat other = Left ("unsupported behavior obligation format: " <> other <> " (expected text or json)")

emitLanguageContractNotice :: FilePath -> T.Text -> CheckedService -> IO ()
emitLanguageContractNotice subject sourceFormSummary service =
  mapM_
    (TIO.hPutStrLn stderr)
    (languageContractNotice subject sourceFormSummary (checkedLanguageContract service))

emitWorkspaceLanguageContractNotice :: FilePath -> WorkspaceSpec -> IO ()
emitWorkspaceLanguageContractNotice subject workspace =
  emitLanguageContractNotice subject (workspaceSourceFormSummary workspace) (checkedWorkspace workspace)

workspaceSourceFormSummary :: WorkspaceSpec -> T.Text
workspaceSourceFormSummary workspace =
  "workspace, "
    <> T.pack (show legacyCount)
    <> " legacy-unversioned member(s)"
  where
    legacyCount = length [() | member <- wsMembers workspace, LegacyUnversioned <- [wmSourceLanguage member]]

minimumWorkspaceLanguageDiagnostics :: LanguageVersion -> WorkspaceSpec -> [WorkspaceDiagnostic]
minimumWorkspaceLanguageDiagnostics floorVersion workspace
  | effectiveVersion >= floorVersion = []
  | otherwise =
      [ WorkspaceDiagnostic
          { wdLocations =
              NE.fromList
                ( WorkspaceLocation WorkspaceManifestFile 1 ""
                    : [ WorkspaceLocation
                          (WorkspaceMemberFile (wmPath member))
                          (sourceLanguageLine (wmSourceLanguage member))
                          ( "member selects effective language version "
                              <> languageVersionText (effectiveLanguageVersion (wmSourceLanguage member))
                          )
                      | member <- wsMembers workspace
                      ]
                ),
            wdSeverity = Error,
            wdCode = LanguageVersionBelowMinimum,
            wdSourceLanguageCause = Nothing,
            wdMessage =
              "effective language version "
                <> languageVersionText effectiveVersion
                <> " (workspace-composed) is below the required minimum "
                <> languageVersionText floorVersion
                <> "; declare `language keiro-dsl "
                <> languageVersionText floorVersion
                <> "` in every member"
          }
      ]
  where
    effectiveVersion = effectiveContractLanguageVersion (checkedLanguageContract (checkedWorkspace workspace))
    sourceLanguageLine LegacyUnversioned = 1
    sourceLanguageLine DeclaredLanguage {languageVersionLoc = Loc lineNumber} = lineNumber

deniesWarningCode :: CheckOptions -> DiagnosticCode -> Bool
deniesWarningCode options diagnosticCode =
  checkDenyWarnings options || diagnosticCode `elem` checkDenyCodes options

deniedSourceWarningCodes :: CheckOptions -> [Diagnostic] -> [DiagnosticCode]
deniedSourceWarningCodes options diagnostics =
  [ code diagnostic
  | diagnostic <- diagnostics,
    severity diagnostic == Warning,
    deniesWarningCode options (code diagnostic)
  ]

deniedWorkspaceWarningCodes :: CheckOptions -> [WorkspaceDiagnostic] -> [DiagnosticCode]
deniedWorkspaceWarningCodes options diagnostics =
  [ wdCode diagnostic
  | diagnostic <- diagnostics,
    wdSeverity diagnostic == Warning,
    deniesWarningCode options (wdCode diagnostic)
  ]

emitDeniedWarningSummary :: [DiagnosticCode] -> IO ()
emitDeniedWarningSummary deniedCodes =
  when (not (null deniedCodes)) $
    TIO.hPutStrLn stderr $
      "check: "
        <> T.pack (show (length deniedCodes))
        <> " warning(s) escalated to failure (denied: "
        <> T.intercalate ", " [diagnosticCodeText diagnosticCode | diagnosticCode <- [minBound .. maxBound], diagnosticCode `elem` deniedCodes]
        <> ")"

checkReportEnforcement :: CheckOptions -> CheckReport.CheckReportEnforcement
checkReportEnforcement options =
  CheckReport.CheckReportEnforcement
    { CheckReport.reportMinLanguage = checkMinLanguage options,
      CheckReport.reportDenyWarnings = checkDenyWarnings options,
      CheckReport.reportDenyCodes = checkDenyCodes options
    }

-- | Write a check report to @--report-out@, creating any missing parent
-- directories first. CI recipes routinely point this at a not-yet-created
-- artifact directory; the coverage writer has always done this.
writeCheckReportFile :: CheckOptions -> CheckReport.CheckReport -> IO ()
writeCheckReportFile options report =
  mapM_
    ( \path -> do
        createDirectoryIfMissing True (takeDirectory path)
        Aeson.encodeFile path report
    )
    (checkReportOut options)

writeSourceCheckReport :: FilePath -> ParsedSource -> CheckedService -> CheckOptions -> [Diagnostic] -> IO ()
writeSourceCheckReport subject parsedSource service options diagnostics =
  writeCheckReportFile
    options
    ( CheckReport.checkReport
        subject
        (parsedSourceLanguage parsedSource)
        (checkedLanguageContract service)
        enforcement
        diagnostics
        (CheckReport.effectiveDenyCodes enforcement)
    )
  where
    enforcement = checkReportEnforcement options

writeWorkspaceCheckReport :: FilePath -> WorkspaceSpec -> CheckedService -> CheckOptions -> [WorkspaceDiagnostic] -> IO ()
writeWorkspaceCheckReport subject workspace service options diagnostics =
  writeCheckReportFile
    options
    ( CheckReport.workspaceCheckReport
        subject
        workspace
        (checkedLanguageContract service)
        enforcement
        diagnostics
        (CheckReport.effectiveDenyCodes enforcement)
    )
  where
    enforcement = checkReportEnforcement options

-- | Write the machine report for a workspace refused during composition. The
-- single-spec path already reports the equivalent failure, so a CI job that
-- consumes @--report-out@ must not lose the workspace one.
writeWorkspaceRefusalReport :: FilePath -> CheckOptions -> WorkspaceFailure -> IO ()
writeWorkspaceRefusalReport subject options failure = case failure of
  WorkspaceRefused diagnostics ->
    writeCheckReportFile
      options
      ( CheckReport.workspaceRefusalReport
          subject
          enforcement
          diagnostics
          (CheckReport.effectiveDenyCodes enforcement)
      )
  -- An unreadable or unparseable manifest has no coded diagnostic, exactly as a
  -- `.keiro` parse error has none on the single-spec path. Both write no report.
  _ -> pure ()
  where
    enforcement = checkReportEnforcement options

run :: Command -> IO ()
run (Pretty fp) = run (Parse fp)
-- Workspace dispatch. A @FILE@ ending in @.keiro-workspace@ is a workspace
-- manifest; everything else takes the untouched single-file path below.
run (Parse fp) | isWorkspacePath fp = runWorkspaceParse fp
run (Check fp checkOptionsValue)
  | isWorkspacePath fp = runWorkspaceCheck fp checkOptionsValue
run (Inspect fp format)
  | isWorkspacePath fp = runWorkspaceInspect fp format
run (BehaviorObligations fp format)
  | isWorkspacePath fp = runWorkspaceBehaviorObligations fp format
run (Scaffold fp out cliRoot cliRuntimePackage cliCollocate forceGeneratedOverwrite applyNameMigrations cliGoldens comparisonRequest)
  | isWorkspacePath fp = runWorkspaceScaffold fp out cliRoot cliRuntimePackage cliCollocate forceGeneratedOverwrite applyNameMigrations cliGoldens comparisonRequest
run (Diff fp ref emitGoldensRoot replayImpactOut gatedSurfaces explain reportOut coverageOptions)
  | isWorkspacePath fp = runWorkspaceDiff fp ref emitGoldensRoot replayImpactOut gatedSurfaces explain reportOut coverageOptions
run (Parse fp) = do
  input <- TIO.readFile fp
  case parseSource fp input of
    Left failure -> do
      hPutStrLn stderr (T.unpack (renderParseFailure failure))
      exitFailure
    Right parsedSource -> TIO.putStrLn (renderSource parsedSource)
run (Check fp options) = do
  input <- TIO.readFile fp
  case parseSource fp input of
    Left failure -> do
      hPutStrLn stderr (T.unpack (renderParseFailure failure))
      exitFailure
    Right parsedSource -> do
      validateCheckDenyCodes options
      let service = checkedSource parsedSource
          spec = checkedSpec service
          floorDiags = maybe [] (\floorVersion -> minimumLanguageDiagnostics floorVersion (parsedSourceLanguage parsedSource)) (checkMinLanguage options)
          semanticDiags = floorDiags <> checkServiceDiagnostics Nothing (mkContext Nothing False spec) service
          semanticFailed = any ((== Error) . severity) semanticDiags
      emitLanguageContractNotice fp (sourceFormText (parsedSourceLanguage parsedSource)) service
      mapM_ (TIO.hPutStrLn stderr . renderDiagnostic fp) semanticDiags
      -- Coverage is part of this invocation's diagnostic surface, not a
      -- success-path artifact: its findings must reach the deny policy, the exit
      -- code, and the check report. It still runs only after semantic validation
      -- passes, because an unresolvable graph has nothing to cover.
      coveragePlan <- planCheckCoverage fp spec (if semanticFailed then Nothing else checkCoverage options)
      coverageOk <- emitPlannedCoverage coveragePlan
      let diags = semanticDiags <> plannedCoverageDiagnostics coveragePlan
          deniedWarningCodes = deniedSourceWarningCodes options diags
      emitDeniedWarningSummary deniedWarningCodes
      writeSourceCheckReport fp parsedSource service options diags
      if semanticFailed || not coverageOk || not (null deniedWarningCodes)
        then exitFailure
        else do
          when (checkEmit options) (TIO.putStrLn (renderSource parsedSource))
          if checkExplainBindings options
            then case bindingObligationsForService service of
              Left graphErrors -> do
                hPutStrLn stderr ("validated spec did not resolve its mapped type graph: " <> show graphErrors)
                exitFailure
              Right obligations -> TIO.putStrLn (renderBindingObligations (specContext spec) obligations)
            else pure ()
          when (not (checkEmit options) && not (checkExplainBindings options)) (putStrLn "OK")
run (Scaffold fp out cliRoot cliRuntimePackage cliCollocate forceGeneratedOverwrite applyNameMigrations cliGoldens comparisonRequest) = do
  input <- TIO.readFile fp
  case parseSource fp input of
    Left failure -> do
      hPutStrLn stderr (T.unpack (renderParseFailure failure))
      exitFailure
    Right parsedSource -> do
      let service = checkedSource parsedSource
          spec = checkedSpec service
      emitLanguageContractNotice fp (sourceFormText (parsedSourceLanguage parsedSource)) service
      -- Validation gate: never scaffold an invalid spec. Abort on any
      -- error-severity diagnostic before writing a single module.
      let diags = validateService service
      mapM_ (TIO.hPutStrLn stderr . renderDiagnostic fp) diags
      when (any ((== Error) . severity) diags) exitFailure
      let ctx = mkContext cliRoot cliCollocate spec
          goldenRoot = fromMaybe (takeDirectory fp </> "golden-payloads") cliGoldens
      goldens <- loadGoldenPayloads goldenRoot spec
      case (planServiceScaffoldWithRuntimePackageAndGoldens goldens cliRuntimePackage ctx service, traverse (\(name, _) -> codecComparisonModule ctx spec (T.pack name)) comparisonRequest) of
        (Left refusals, _) -> do
          mapM_ (TIO.hPutStrLn stderr) (renderRefusals refusals)
          exitFailure
        (_, Left comparisonError) -> TIO.hPutStrLn stderr comparisonError >> exitFailure
        (Right modules, Right comparisonModule) -> do
          comparisonReady <- preflightComparison out comparisonRequest comparisonModule
          case comparisonReady of
            Left comparisonError -> TIO.hPutStrLn stderr comparisonError >> exitFailure
            Right () -> do
              result <- executeServiceScaffoldWithRuntimePackageAndNameMigrations cliRuntimePackage applyNameMigrations out forceGeneratedOverwrite fp (parsedSourceLanguage parsedSource) ctx service modules
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
run (Inspect fp InspectionJson) = do
  input <- TIO.readFile fp
  case parseSource fp input of
    Left failure -> hPutStrLn stderr (T.unpack (renderParseFailure failure)) >> exitFailure
    Right parsedSource ->
      TLIO.putStrLn
        (AesonText.encodeToLazyText (sourceInspection fp (parsedSourceLanguage parsedSource) (checkedSource parsedSource)))
run (BehaviorObligations fp format) = do
  input <- TIO.readFile fp
  case parseSource fp input of
    Left failure -> hPutStrLn stderr (T.unpack (renderParseFailure failure)) >> exitFailure
    Right parsedSource -> do
      let service = checkedSource parsedSource
          spec = checkedSpec service
          diagnostics = validateService service
      mapM_ (TIO.hPutStrLn stderr . renderDiagnostic fp) diagnostics
      if any ((== Error) . severity) diagnostics
        then exitFailure
        else case Behavior.behaviorObligationsReport fp spec of
          Left errors -> renderBehaviorErrors errors
          Right report -> writeBehaviorReport format report
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
          case (,) <$> parseSource (ref <> ":" <> relPath) (T.pack oldText) <*> parseSource fp newText of
            Left failure -> hPutStrLn stderr (T.unpack (renderParseFailure failure)) >> exitFailure
            Right (oldSource, newSource) -> do
              let oldService = checkedSource oldSource
                  newService = checkedSource newSource
                  oldSpec = checkedSpec oldService
                  newSpec = checkedSpec newService
              emitLanguageContractNotice fp (sourceFormText (parsedSourceLanguage newSource)) newService
              case (,) <$> diffSources oldSource newSource <*> replayImpactServices oldService newService of
                Left surfaceError -> TIO.hPutStrLn stderr (renderFoldSurfaceError surfaceError) >> exitFailure
                Right (changes, impact) -> do
                  written <- maybe (pure []) (\root -> emitGoldenPayloads root oldSpec newSpec) emitGoldensRoot
                  mapM_ (putStrLn . ("golden: wrote synthesized weak stand-in " <>)) written
                  let effectiveGate = gateWith gatedSurfaces
                  mapM_ (TIO.putStrLn . renderFinding) changes
                  when explain $
                    mapM_ (TIO.putStrLn . renderExplainBlock) (filter shouldExplain changes)
                  TIO.putStrLn (renderReplayImpact impact)
                  mapM_ (`Aeson.encodeFile` impact) replayImpactOut
                  mapM_ (\path -> Aeson.encodeFile path (diffReport effectiveGate changes)) reportOut
                  coverageOk <- runDiffCoverage fp (T.pack ref) oldSpec newSpec coverageOptions
                  if any (gatedBreaking effectiveGate) changes || not coverageOk then exitFailure else pure ()

-- | @parse@ on a workspace manifest: read it, parse it, and print it back in
-- canonical form (clauses in order, members codepoint-sorted).
runWorkspaceParse :: FilePath -> IO ()
runWorkspaceParse fp = do
  input <- TIO.readFile fp
  case parseWorkspaceManifest fp input of
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
    Right manifest -> TIO.putStrLn (renderWorkspaceManifest manifest)

sourceInspection :: FilePath -> SourceLanguage -> CheckedService -> Aeson.Value
sourceInspection path sourceLanguage service =
  Aeson.object
    [ "schema" .= ("keiro-dsl/source-inspection/1" :: T.Text),
      "kind" .= ("source" :: T.Text),
      "path" .= path,
      "sourceForm" .= sourceFormText sourceLanguage,
      "declaredLanguageVersion" .= declaredLanguageVersionMaybe sourceLanguage,
      "effectiveLanguageVersion" .= effectiveLanguageVersion sourceLanguage,
      "effectiveSemanticContract" .= checkedLanguageContract service
    ]

runWorkspaceInspect :: FilePath -> InspectionFormat -> IO ()
runWorkspaceInspect fp InspectionJson = do
  loaded <- loadWorkspace (fileContentSource (takeDirectory fp)) fp
  case loaded of
    Left failure -> do
      mapM_ (TIO.hPutStrLn stderr) (renderWorkspaceFailure fp failure)
      exitFailure
    Right workspace ->
      TLIO.putStrLn
        ( AesonText.encodeToLazyText
            ( Aeson.object
                [ "schema" .= ("keiro-dsl/source-inspection/1" :: T.Text),
                  "kind" .= ("workspace" :: T.Text),
                  "path" .= fp,
                  "service" .= wsService workspace,
                  "effectiveSemanticContract" .= checkedLanguageContract (checkedWorkspace workspace),
                  "members" .= map memberInspection (wsMembers workspace)
                ]
            )
        )
  where
    memberInspection member =
      Aeson.object
        [ "path" .= wmPath member,
          "sourceForm" .= sourceFormText sourceLanguage,
          "declaredLanguageVersion" .= declaredLanguageVersionMaybe sourceLanguage,
          "effectiveLanguageVersion" .= effectiveLanguageVersion sourceLanguage
        ]
      where
        sourceLanguage = wmSourceLanguage member

runWorkspaceBehaviorObligations :: FilePath -> BehaviorFormat -> IO ()
runWorkspaceBehaviorObligations fp format = do
  loaded <- loadWorkspace (fileContentSource (takeDirectory fp)) fp
  case loaded of
    Left failure -> mapM_ (TIO.hPutStrLn stderr) (renderWorkspaceFailure fp failure) >> exitFailure
    Right workspace -> do
      let diagnostics = checkWorkspace workspace
      mapM_ (TIO.hPutStrLn stderr . renderWorkspaceDiagnostic fp) diagnostics
      if any ((== Error) . wdSeverity) diagnostics
        then exitFailure
        else case workspaceBehaviorReport workspace of
          Left errors -> renderBehaviorErrors errors
          Right report -> writeBehaviorReport format report

workspaceBehaviorReport :: WorkspaceSpec -> Either [Behavior.BehaviorDerivationError] Behavior.BehaviorObligationsReport
workspaceBehaviorReport workspace = do
  requirements <- Behavior.deriveBehaviorRequirements (checkedSpec (checkedWorkspace workspace))
  pure
    Behavior.BehaviorObligationsReport
      { Behavior.behaviorSubject = wsManifestPath workspace,
        Behavior.behaviorWorkspaceService = Just (wsService workspace),
        Behavior.behaviorRequirements =
          map
            (Behavior.attributeBehaviorOwner (fmap fst . nodeOwner (wsOwnership workspace) "aggregate"))
            requirements
      }

writeBehaviorReport :: BehaviorFormat -> Behavior.BehaviorObligationsReport -> IO ()
writeBehaviorReport format report = case format of
  BehaviorText -> TIO.putStr (Behavior.renderBehaviorObligationsText report)
  BehaviorJson -> TIO.putStrLn (Behavior.encodeBehaviorObligationsJson report)

renderBehaviorErrors :: [Behavior.BehaviorDerivationError] -> IO ()
renderBehaviorErrors errors = do
  mapM_ (hPutStrLn stderr . ("behavior obligation derivation failed: " <>) . show) errors
  exitFailure

-- | @check@ on a workspace manifest: compose the whole service from its member
-- @.keiro@ files and validate it as one contract. Diagnostics are rendered
-- against the member file and line that produced them, and a single diagnostic
-- may cite several files at once.
--
-- The success options work against the merged graph, which is an ordinary 'Spec':
-- @--emit@ prints the canonical whole-service view, @--explain-bindings@ lists the
-- service's binding obligations, and the coverage options report on the merged
-- mapped-type graph with the manifest as the report's subject.
runWorkspaceCheck :: FilePath -> CheckOptions -> IO ()
runWorkspaceCheck fp options = do
  validateCheckDenyCodes options
  loaded <- loadWorkspace (fileContentSource (takeDirectory fp)) fp
  case loaded of
    Left failure -> do
      mapM_ (TIO.hPutStrLn stderr) (renderWorkspaceFailure fp failure)
      writeWorkspaceRefusalReport fp options failure
      exitFailure
    Right workspace -> do
      let service = checkedWorkspace workspace
          floorDiags = maybe [] (\floorVersion -> minimumWorkspaceLanguageDiagnostics floorVersion workspace) (checkMinLanguage options)
          semanticDiags = floorDiags <> checkWorkspace workspace
          spec = checkedSpec service
          semanticFailed = any ((== Error) . wdSeverity) semanticDiags
      emitWorkspaceLanguageContractNotice fp workspace
      mapM_ (TIO.hPutStrLn stderr . renderWorkspaceDiagnostic fp) semanticDiags
      -- Same contract as the single-spec path: coverage findings are gated
      -- diagnostics, not success-path output. See `run (Check …)` above.
      coveragePlan <- planCheckCoverage fp spec (if semanticFailed then Nothing else checkCoverage options)
      coverageOk <- emitPlannedCoverage coveragePlan
      let diags = semanticDiags <> map (workspaceCoverageDiagnostic fp) (plannedCoverageFindings coveragePlan)
          deniedWarningCodes = deniedWorkspaceWarningCodes options diags
      emitDeniedWarningSummary deniedWarningCodes
      writeWorkspaceCheckReport fp workspace service options diags
      if semanticFailed || not coverageOk || not (null deniedWarningCodes)
        then exitFailure
        else do
          when (checkEmit options) (TIO.putStrLn (renderSpec spec))
          if checkExplainBindings options
            then case bindingObligationsForService service of
              Left graphErrors -> do
                hPutStrLn stderr ("validated workspace did not resolve its mapped type graph: " <> show graphErrors)
                exitFailure
              Right obligations -> TIO.putStrLn (renderBindingObligations (wsContext workspace) obligations)
            else pure ()
          when (not (checkEmit options) && not (checkExplainBindings options)) (putStrLn "OK")

-- | @scaffold@ on a workspace manifest: compose the whole service, then plan
-- and emit the complete module set for every member in one invocation.
--
-- Every refusal — a member that will not parse, a cross-member conflict, a
-- validation error anywhere in the merged graph, a module-path collision, a golden
-- fixture stranded beside a member, a Generated target without the banner — is
-- raised before the first output byte changes, exactly as on the single-file path.
--
-- The context is folded with the same precedence the single-file path uses: a CLI
-- flag beats the workspace authority, which (per EP-153) beats a member clause.
-- The single-file branch below is not touched, so existing users' bytes are
-- unchanged by construction.
runWorkspaceScaffold ::
  FilePath ->
  FilePath ->
  Maybe String ->
  Maybe RuntimePackageName ->
  Bool ->
  Bool ->
  Bool ->
  Maybe FilePath ->
  Maybe (String, FilePath) ->
  IO ()
runWorkspaceScaffold fp out cliRoot cliRuntimePackage cliCollocate forceGeneratedOverwrite applyNameMigrations cliGoldens comparisonRequest = do
  loaded <- loadWorkspace (fileContentSource (takeDirectory fp)) fp
  case loaded of
    Left failure -> do
      mapM_ (TIO.hPutStrLn stderr) (renderWorkspaceFailure fp failure)
      exitFailure
    Right workspace -> do
      emitWorkspaceLanguageContractNotice fp workspace
      -- Validation gate: never scaffold an invalid service. Abort on any
      -- error-severity diagnostic before writing a single module.
      let diags = checkWorkspace workspace
      mapM_ (TIO.hPutStrLn stderr . renderWorkspaceDiagnostic fp) diags
      when (any ((== Error) . wdSeverity) diags) exitFailure
      let spec = checkedSpec (checkedWorkspace workspace)
          ctx = workspaceContext cliRoot cliCollocate workspace
          effectiveRuntimePackage = case cliRuntimePackage of
            Just packageName -> Just packageName
            Nothing -> wsRuntimePackage workspace
          goldenRoot = fromMaybe (takeDirectory fp </> "golden-payloads") cliGoldens
      goldens <- loadGoldenPayloads goldenRoot spec
      case ( planWorkspaceScaffoldWithRuntimePackageAndGoldens goldens effectiveRuntimePackage goldenRoot ctx workspace,
             traverse (\(name, _) -> codecComparisonModule ctx spec (T.pack name)) comparisonRequest
           ) of
        (Left refusals, _) -> do
          mapM_ (TIO.hPutStrLn stderr) (renderRefusals refusals)
          exitFailure
        (_, Left comparisonError) -> TIO.hPutStrLn stderr comparisonError >> exitFailure
        (Right plan, Right comparisonModule) -> do
          comparisonReady <- preflightComparison out comparisonRequest comparisonModule
          case comparisonReady of
            Left comparisonError -> TIO.hPutStrLn stderr comparisonError >> exitFailure
            Right () -> do
              result <- executeWorkspaceScaffoldWithNameMigrations out forceGeneratedOverwrite applyNameMigrations plan
              case result of
                Left refusals -> do
                  mapM_ (TIO.hPutStrLn stderr) (renderRefusals refusals)
                  exitFailure
                Right report -> do
                  mapM_ (TIO.hPutStrLn stderr) (renderWorkspaceScaffoldReport report)
                  writeComparison comparisonRequest comparisonModule

-- | @diff@ on a workspace manifest: compose the working-tree service and the
-- service described by the manifest and member blobs at @--since@, then feed both
-- merged specs through the existing differ, replay-impact analysis, coverage
-- report, golden emission, and gates.
--
-- The historical side is read exclusively through 'ContentSource'.  In
-- particular, member paths are joined textually beneath the manifest's
-- repository-relative directory; they are never canonicalized because an old
-- member may no longer exist in the working tree.
runWorkspaceDiff ::
  FilePath ->
  String ->
  Maybe FilePath ->
  Maybe FilePath ->
  [CompatibilitySurface] ->
  Bool ->
  Maybe FilePath ->
  Maybe DiffCoverageOptions ->
  IO ()
runWorkspaceDiff fp ref emitGoldensRoot replayImpactOut gatedSurfaces explain reportOut coverageOptions = do
  let dir = takeDirectory fp
  rootRes <- git dir ["rev-parse", "--show-toplevel"]
  case rootRes of
    Left err -> hPutStrLn stderr err >> exitFailure
    Right rootRaw -> do
      let repoRoot = trim rootRaw
      absFp <- canonicalizePath fp
      let relManifestPath = makeRelative repoRoot absFp
          relManifestDir = takeDirectory relManifestPath
          oldSource = gitContentSource repoRoot ref relManifestDir
      refRes <- git repoRoot ["cat-file", "-e", ref <> "^{commit}"]
      case refRes of
        Left err -> hPutStrLn stderr err >> exitFailure
        Right _ -> do
          newLoaded <- loadWorkspace (fileContentSource dir) fp
          case newLoaded of
            Left failure -> printWorkspaceFailure fp failure
            Right newWorkspace -> do
              emitWorkspaceLanguageContractNotice fp newWorkspace
              currentManifestText <- TIO.readFile fp
              case parseWorkspaceManifest fp currentManifestText of
                Left err -> hPutStrLn stderr (T.unpack err) >> exitFailure
                Right currentManifest -> do
                  oldManifestRes <- git repoRoot ["show", ref <> ":" <> relManifestPath]
                  (adoptionBaseline, oldLoaded) <- case oldManifestRes of
                    Right _ -> do
                      loaded <- loadWorkspace oldSource fp
                      pure (False, loaded)
                    Left _ -> do
                      loaded <- loadAdoptionBaseline oldSource fp currentManifest newWorkspace
                      pure (True, loaded)
                  case oldLoaded of
                    Left failure -> do
                      printWorkspaceFailureLines fp failure
                      when adoptionBaseline $
                        hPutStrLn stderr "workspace adoption baseline could not be composed; commit the workspace manifest before diffing across it, or fix the member files at the old revision"
                      exitFailure
                    Right oldWorkspace -> do
                      when adoptionBaseline $
                        putStrLn
                          ( "workspace adoption baseline: "
                              <> fp
                              <> " does not exist at "
                              <> ref
                              <> "; composing the old service from the current members' blobs at "
                              <> ref
                          )
                      let oldService = checkedWorkspace oldWorkspace
                          newService = checkedWorkspace newWorkspace
                          oldSpec = checkedSpec oldService
                          newSpec = checkedSpec newService
                          goldenRoot = fmap (workspaceGoldenRoot fp) emitGoldensRoot
                      case (,) <$> diffWorkspaces oldWorkspace newWorkspace <*> replayImpactServices oldService newService of
                        Left surfaceError -> TIO.hPutStrLn stderr (renderFoldSurfaceError surfaceError) >> exitFailure
                        Right (workspaceChanges, impact) -> do
                          written <- maybe (pure []) (\root -> emitGoldenPayloads root oldSpec newSpec) goldenRoot
                          mapM_ (putStrLn . ("golden: wrote synthesized weak stand-in " <>)) written
                          let changes = map wcChange workspaceChanges
                              effectiveGate = gateWith gatedSurfaces
                              reportMeta =
                                WorkspaceMeta
                                  { wmIdentity = wsService newWorkspace,
                                    wmManifest = fp,
                                    wmSince = T.pack ref,
                                    wmMembersOld = map wmPath (wsMembers oldWorkspace),
                                    wmMembersNew = map wmPath (wsMembers newWorkspace),
                                    wmAdoptionBaseline = adoptionBaseline
                                  }
                          mapM_ (TIO.putStrLn . renderWorkspaceFinding) workspaceChanges
                          when explain $
                            mapM_ (TIO.putStrLn . renderExplainBlock) (filter shouldExplain changes)
                          TIO.putStrLn (renderReplayImpact impact)
                          mapM_ (`Aeson.encodeFile` impact) replayImpactOut
                          mapM_ (\path -> Aeson.encodeFile path (workspaceDiffReport reportMeta effectiveGate workspaceChanges)) reportOut
                          coverageOk <- runDiffCoverage fp (T.pack ref) oldSpec newSpec coverageOptions
                          if any (gatedBreaking effectiveGate) changes || not coverageOk then exitFailure else pure ()

-- | A @git show@ backed source rooted at a workspace manifest directory.
gitContentSource :: FilePath -> String -> FilePath -> ContentSource
gitContentSource repoRoot ref relManifestDir =
  ContentSource
    { csRead = \relative -> do
        let relPath = normalise (relManifestDir </> relative)
        result <- git repoRoot ["show", ref <> ":" <> relPath]
        pure $ case result of
          Left err -> Left (T.pack ("git show " <> ref <> ":" <> relPath <> " failed: " <> trim err))
          Right contents -> Right (T.pack contents)
    }

-- | Build the historical side for the commit that introduces a workspace
-- manifest.  Current members absent from the old revision contribute no nodes;
-- members that do exist are still parsed and composed by the ordinary workspace
-- loader, so malformed or mutually inconsistent old specs remain hard refusals.
loadAdoptionBaseline ::
  ContentSource ->
  FilePath ->
  WorkspaceManifest ->
  WorkspaceSpec ->
  IO (Either WorkspaceFailure WorkspaceSpec)
loadAdoptionBaseline oldSource manifestPath currentManifest newWorkspace = do
  present <- traverse presentAtRevision (NE.toList (wmfMembers currentManifest))
  case NE.nonEmpty [member | (member, True) <- present] of
    Nothing -> pure (Right (emptyWorkspaceBaseline newWorkspace))
    Just members ->
      let oldManifest = currentManifest {wmfMembers = members}
          manifestName = takeFileName manifestPath
          baselineSource =
            ContentSource
              { csRead = \relative ->
                  if relative == manifestName
                    then pure (Right (renderWorkspaceManifest oldManifest))
                    else csRead oldSource relative
              }
       in loadWorkspace baselineSource manifestPath
  where
    presentAtRevision member = do
      result <- csRead oldSource (wmrPath member)
      pure (member, either (const False) (const True) result)

-- | The sound old side when every current member is new at the adoption ref.
emptyWorkspaceBaseline :: WorkspaceSpec -> WorkspaceSpec
emptyWorkspaceBaseline workspace =
  workspace
    { wsMembers = [],
      wsMergedSpec =
        (wsMergedSpec workspace)
          { specIds = [],
            specEnums = [],
            specRules = [],
            specMapped = [],
            specNodes = []
          },
      wsLineMap = LineMap [],
      wsOwnership = OwnershipIndex mempty mempty
    }

workspaceGoldenRoot :: FilePath -> FilePath -> FilePath
workspaceGoldenRoot manifestPath requested
  | isAbsolute requested = requested
  | otherwise = normalise (takeDirectory manifestPath </> requested)

printWorkspaceFailure :: FilePath -> WorkspaceFailure -> IO a
printWorkspaceFailure fp failure = printWorkspaceFailureLines fp failure >> exitFailure

printWorkspaceFailureLines :: FilePath -> WorkspaceFailure -> IO ()
printWorkspaceFailureLines fp = mapM_ (TIO.hPutStrLn stderr) . renderWorkspaceFailure fp

-- | Fold the workspace's module-root and layout authority with the CLI
-- overrides to a 'Context'. Precedence is CLI flag > workspace authority >
-- built-in default; EP-153 already resolved the manifest-versus-member question
-- into 'wsModuleRoot' and 'wsLayout', so this mirrors 'mkContext' exactly one
-- level up.
workspaceContext :: Maybe String -> Bool -> WorkspaceSpec -> Context
workspaceContext cliRoot cliCollocate workspace =
  Context
    { contextName = wsContext workspace,
      moduleRoot = maybe (fromMaybe "" (wsModuleRoot workspace)) T.pack cliRoot,
      placement =
        if cliCollocate
          then CollocatedLeaf
          else fromMaybe GeneratedPrefix (wsLayout workspace)
    }

shouldExplain :: Change -> Bool
shouldExplain Additive {} = False
shouldExplain Advisory {} = True
shouldExplain Breaking {} = True

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

-- | What this @check@ invocation's coverage pass will do, decided before the
-- warning policy is applied so the findings can take part in it.
data PlannedCoverage
  = -- | @--coverage-report@ was not supplied, or semantic validation already failed.
    NoCoverage
  | -- | The report to render, and the path to write it to.
    PlannedCoverage !FilePath !Coverage.CoverageReport
  | -- | The mapped-type graph did not resolve; the pass cannot run.
    CoverageUnresolved !String

planCheckCoverage :: FilePath -> Spec -> Maybe CheckCoverageOptions -> IO PlannedCoverage
planCheckCoverage _ _ Nothing = pure NoCoverage
planCheckCoverage specPath spec (Just options) =
  pure $ case Coverage.coverageReport specPath spec of
    Left graphErrors -> CoverageUnresolved (show graphErrors)
    Right baseReport ->
      PlannedCoverage
        (checkCoveragePath options)
        (if checkFailOnOpaque options then Coverage.failOnOpaque baseReport else baseReport)

plannedCoverageFindings :: PlannedCoverage -> [Coverage.CoverageFinding]
plannedCoverageFindings (PlannedCoverage _ report) = Coverage.coverageFindings report
plannedCoverageFindings _ = []

-- | Coverage findings as ordinary source diagnostics. They carry no line, which
-- the rendered form has always shown as @:0:@.
plannedCoverageDiagnostics :: PlannedCoverage -> [Diagnostic]
plannedCoverageDiagnostics plan =
  [ Diagnostic
      { line = 0,
        severity = Coverage.findingSeverity finding,
        code = Coverage.findingCode finding,
        relatedLocations = [],
        message = Coverage.coverageFindingMessage finding
      }
  | finding <- plannedCoverageFindings plan
  ]

-- | The workspace twin: coverage runs on the merged graph, so every finding is
-- attributed to the manifest rather than to one member.
workspaceCoverageDiagnostic :: FilePath -> Coverage.CoverageFinding -> WorkspaceDiagnostic
workspaceCoverageDiagnostic _ finding =
  WorkspaceDiagnostic
    { wdLocations = NE.fromList [WorkspaceLocation WorkspaceManifestFile 0 ""],
      wdSeverity = Coverage.findingSeverity finding,
      wdCode = Coverage.findingCode finding,
      wdSourceLanguageCause = Nothing,
      wdMessage = Coverage.coverageFindingMessage finding
    }

emitPlannedCoverage :: PlannedCoverage -> IO Bool
emitPlannedCoverage NoCoverage = pure True
emitPlannedCoverage (CoverageUnresolved graphErrors) = do
  hPutStrLn stderr ("validated spec did not resolve its mapped type graph for coverage: " <> graphErrors)
  pure False
emitPlannedCoverage (PlannedCoverage path report) = emitCoverageReport path report

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

-- | Fold the spec's @module@/@layout@ clauses with the CLI overrides to a
-- 'Context'. Precedence is CLI flag > spec clause > built-in default.
mkContext :: Maybe String -> Bool -> Spec -> Context
mkContext cliRoot cliCollocate spec =
  Context
    { contextName = specContext spec,
      moduleRoot = maybe (fromMaybe "" (specModuleRoot spec)) T.pack cliRoot,
      placement =
        if cliCollocate
          then CollocatedLeaf
          else fromMaybe GeneratedPrefix (specLayout spec)
    }
