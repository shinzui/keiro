-- | The filesystem-facing scaffold pipeline. It separates pure planning from
-- execution so every refusal is known before the first output byte is written.
module Keiro.Dsl.ScaffoldRun
  ( Refusal (..),
    WriteDisposition (..),
    StaleGeneratedEvidence (..),
    StaleModule (..),
    MappingDrift (..),
    SourceLanguageDrift (..),
    ScaffoldReport (..),
    scaffoldServiceModules,
    scaffoldServiceModulesWithGoldens,
    scaffoldModules,
    scaffoldModulesWithGoldens,
    planServiceScaffold,
    planServiceScaffoldWithGoldens,
    planServiceScaffoldWithRuntimePackage,
    planServiceScaffoldWithRuntimePackageAndGoldens,
    planScaffold,
    planScaffoldWithGoldens,
    executeServiceScaffold,
    executeServiceScaffoldWithRuntimePackage,
    executeServiceScaffoldWithRuntimePackageAndNameMigrations,
    executeScaffold,
    executeScaffoldWithLanguage,
    renderRefusals,
    renderScaffoldReport,

    -- * Shared with whole-workspace scaffolding ("Keiro.Dsl.WorkspaceScaffold")

    --
    -- $shared
    planningGatePipeline,
    planningRefusalDiagnostics,
    checkServiceDiagnostics,
    inertNodesOf,
    renderInertNodeSection,
    withSidecarMovesApplied,
    originLine,
    pureRefusals,
    auditGeneratedHaskell,
    missingGeneratedBanners,
    staleAgainst,
    PreparedSourceMove,
    preparedSourceMove,
    preflightSourceMoves,
    applyPreparedSourceMoves,
    constraintPlan,
    mappingDrift,
    behaviorDrift,
    newBindingObligations,
    obligationKindLabel,
    renderMappingIdentity,
  )
where

import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.BehaviorCoverage (BehaviorDerivationError, BehaviorKey (..), BehaviorRecordRow (..), behaviorRecordRows, deriveBehaviorRequirements)
import Keiro.Dsl.BehaviorCoverage qualified as Behavior
import Keiro.Dsl.ConformancePackage
  ( ConformancePackageFailure,
    ConformancePackageReport,
    ConformanceServiceKey (StandaloneConformanceService),
    executePreparedConformancePackage,
    planConformancePackage,
    preflightConformancePackage,
    renderConformancePackageFailure,
    renderConformancePackageReport,
  )
import Keiro.Dsl.ExplainBindings (BindingHole (..), BindingObligationKind (..), bindingHolesForService)
import Keiro.Dsl.FoldFingerprint (FoldSurfaceError, aggregateFoldSurfaceForService, renderFoldSurfaceError)
import Keiro.Dsl.Goldens (GoldenPayload)
import Keiro.Dsl.Grammar (EmitNode (..), Loc (..), Node (..), OperationNode (..), PgmqDispatchNode (..), ProjectionTargetNode (..), ReadModelNode (..), Spec (..))
import Keiro.Dsl.Harness (harnessForServiceWithGoldens, harnessProcess, harnessReadModel, harnessRouter, harnessWorkflow)
import Keiro.Dsl.HaskellName (currentGeneratedHaskellNamingEdition)
import Keiro.Dsl.HaskellName qualified as HaskellName
import Keiro.Dsl.HaskellSourceMove
import Keiro.Dsl.IdDomain (idDomainIdentitiesForService)
import Keiro.Dsl.LanguageVersion (SourceLanguage (..), effectiveLanguageVersion, languageVersionText, sourceFormText)
import Keiro.Dsl.Manifest (moduleNameOf, renderManifestForServiceWithFacade)
import Keiro.Dsl.MappedConsumer (ConsumerPlan (..), MappingIdentity (..), consumerPlan)
import Keiro.Dsl.NominalType (nominalEqualityIdentitiesForService)
import Keiro.Dsl.RuntimePackage (RuntimePackageName)
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRecord (ScaffoldModuleRoleRow (..), ScaffoldRecord (..), parseRecord, projectionCatalogFacts, recordFileName, renderRecord)
import Keiro.Dsl.SemanticContract (CheckedService (..), checkedService, effectiveLanguageContract, legacyCheckedService)
import Keiro.Dsl.ServiceHarness (DuplicateServiceFactKey (..), serviceConformanceModuleName, serviceHarnessModule)
import Keiro.Dsl.SidecarMigration
import Keiro.Dsl.SidecarNames (contextCabalFragmentFileName)
import Keiro.Dsl.StructuralConformance (structuralConformanceModule)
import Keiro.Dsl.TypeGraph (MappedKey (..), TypeGraph (..), UseSite (..), resolveTypeGraph)
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode (..), Severity (..), validateService)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.FilePath (takeDirectory, (</>))
import Text.Read (readMaybe)

-- $shared
-- These are the pieces whole-workspace scaffolding reuses verbatim rather than
-- reimplementing, so a workspace and a single spec can never disagree about what
-- counts as a refusal, what counts as stale, or how an identity renders.
-- "Keiro.Dsl.WorkspaceScaffold" cannot live in this module because
-- "Keiro.Dsl.Workspace" already imports it (its cross-member collision check asks
-- the planner), so the seam is exports rather than shared privates.

data Refusal
  = PathCollision !FilePath ![Text]
  | FirewallBreach ![(FilePath, Text, Int)]
  | LoweringRefusal ![Text]
  | MissingGeneratedBanner ![FilePath]
  | ImportCycle ![Text]
  | BehaviorRefusal ![BehaviorDerivationError]
  | -- | Persisted fold identity could not be resolved canonically.
    FoldSurfaceRefusal !FoldSurfaceError
  | -- | Source provenance and semantic planning selected different contracts.
    --       This is an internal/API misuse refusal and is detected before writes.
    SemanticContractMismatch !Text
  | -- | Golden payload fixtures found beside a workspace member that the one
    --       workspace golden root does not have. Raised only by the workspace path.
    GoldenRootDivergence !FilePath ![FilePath]
  | DuplicateConformanceFactKeys ![DuplicateServiceFactKey]
  | ConformancePackageRefusal !ConformancePackageFailure
  | GeneratedNameInvariantViolation ![Text]
  | NameMigrationRequired ![SourceMove]
  | NameMigrationRefusal ![Text]
  | SidecarMigrationRequired ![SidecarMove]
  | SidecarMigrationRefusal ![Text]
  | -- | Not a refusal on its own: an accompanying note that the run had already
    --       applied its sidecar renames before a later gate refused. Every other
    --       refusal says "nothing was written", which without this note is false.
    --       The renames are idempotent and forward-consistent, so re-running after
    --       fixing the refusal is correct and needs no undo.
    SidecarMovesAlreadyApplied ![SidecarMove]
  deriving stock (Eq, Show)

-- | What one module write did. 'Unchanged' is produced only by the workspace
-- write path, which compares bytes before overwriting a Generated module so that
-- an idempotent re-run is observable in the report; the single-spec 'writeModule'
-- never produces it.
data WriteDisposition = Overwritten | Created | Skipped | Unchanged
  deriving stock (Eq, Show)

data StaleGeneratedEvidence
  = ExactGeneratedBannerPresent
  | ExactGeneratedBannerMissing
  deriving stock (Eq, Show)

data StaleModule = StaleModule
  { staleKind :: !ModuleKind,
    stalePath :: !FilePath,
    staleGeneratedEvidence :: !(Maybe StaleGeneratedEvidence)
  }
  deriving stock (Eq, Show)

data MappingDrift = MappingDrift
  { driftSpecName :: !Text,
    driftPrevious :: !(Maybe MappingIdentity),
    driftCurrent :: !(Maybe MappingIdentity)
  }
  deriving stock (Eq, Show)

data SourceLanguageDrift = SourceLanguageDrift
  { languageDriftPrevious :: !SourceLanguage,
    languageDriftCurrent :: !SourceLanguage
  }
  deriving stock (Eq, Show)

data ScaffoldReport = ScaffoldReport
  { reportSpecPath :: !FilePath,
    reportOutDir :: !FilePath,
    reportContext :: !Context,
    reportDispositions :: ![(ScaffoldModule, WriteDisposition)],
    reportInertNodes :: ![(Text, Text)],
    reportManifestPath :: !FilePath,
    reportRecordPath :: !FilePath,
    reportPreviousSpecPath :: !(Maybe Text),
    reportStale :: ![StaleModule],
    reportConsumerPlan :: !ConsumerPlan,
    reportConstraintPlan :: ![Text],
    reportMappingDrift :: ![MappingDrift],
    reportSourceLanguageDrift :: !(Maybe SourceLanguageDrift),
    reportNewHoles :: ![BindingHole],
    reportAddedBehavior :: ![BehaviorRecordRow],
    reportRemovedBehavior :: ![BehaviorRecordRow],
    reportObsoleteOutputHooks :: ![(Text, Text)],
    reportConformancePackage :: !(Maybe ConformancePackageReport),
    reportNameMoves :: ![SourceMove],
    reportSidecarMoves :: ![SidecarMove]
  }
  deriving stock (Eq, Show)

-- | Produce the complete in-memory module set under a checked semantic
-- contract. Keeping this registry in one place prevents the CLI and tests from
-- drifting apart.
scaffoldServiceModules :: Context -> CheckedService -> [ScaffoldModule]
scaffoldServiceModules = scaffoldServiceModulesWithGoldens []

scaffoldServiceModulesWithGoldens :: [GoldenPayload] -> Context -> CheckedService -> [ScaffoldModule]
scaffoldServiceModulesWithGoldens goldens ctx service =
  structuralConformanceModules ctx service
    <> scaffoldStructuralForService ctx service
    <> scaffoldReplayAudit ctx spec
    <> scaffoldProjectionCatalog ctx spec
    <> concat
      [ case node of
          NAggregate agg -> scaffoldAggregateForService ctx service agg <> harnessForServiceWithGoldens goldens ctx service agg
          NProcess process -> scaffoldProcess ctx process <> harnessProcess ctx process
          NRouter router -> scaffoldRouter ctx router <> harnessRouter ctx router
          NContract contract -> scaffoldContractForService ctx service contract
          NIntake intake -> scaffoldIntake ctx intake
          NPublisher publisher -> scaffoldPublisher ctx publisher
          NWorkqueue workqueue -> scaffoldWorkqueue ctx workqueue
          NReadModel readModel ->
            let resolved = resolveCatalogReadModel spec readModel
             in scaffoldReadModel ctx resolved <> harnessReadModel ctx resolved
          NProjectionTarget _ -> []
          NRebuildGroup _ -> []
          NProjectionOwner _ -> []
          NWorkflow workflow -> harnessWorkflow ctx workflow
          NEmit _ -> []
          NPgmqDispatch _ -> []
          NOperation _ -> []
      | node <- specNodes spec
      ]
  where
    spec = checkedSpec service

structuralConformanceModules :: Context -> CheckedService -> [ScaffoldModule]
structuralConformanceModules ctx service = case structuralConformanceModule ctx service of
  Left failures -> error ("checked structural conformance planning failed: " <> show failures)
  Right Nothing -> []
  Right (Just moduleValue) -> [moduleValue]

resolveCatalogReadModel :: Spec -> ReadModelNode -> ReadModelNode
resolveCatalogReadModel spec readModel =
  case rmGroup readModel of
    Nothing -> readModel
    Just _ -> case rmObservedTargets readModel of
      targetName : _ -> case [target | NProjectionTarget target <- specNodes spec, ptName target == targetName] of
        target : _ -> readModel {rmSchema = ptSchema target, rmTable = ptTable target}
        [] -> readModel
      [] -> readModel

-- | Compatibility wrapper that explicitly selects legacy/version-1 semantics.
scaffoldModules :: Context -> Spec -> [ScaffoldModule]
scaffoldModules = scaffoldModulesWithGoldens []

scaffoldModulesWithGoldens :: [GoldenPayload] -> Context -> Spec -> [ScaffoldModule]
scaffoldModulesWithGoldens goldens ctx = scaffoldServiceModulesWithGoldens goldens ctx . legacyCheckedService

-- | Run every pure refusal gate under the effective semantic contract.
planServiceScaffold :: Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planServiceScaffold = planServiceScaffoldWithRuntimePackage Nothing

planServiceScaffoldWithGoldens :: [GoldenPayload] -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planServiceScaffoldWithGoldens goldens = planServiceScaffoldWithRuntimePackageAndGoldens goldens Nothing

-- | Add the one service-level conformance facade only when the runtime package
-- is explicitly configured. The package name itself is build metadata; facade
-- naming depends solely on the service context and placement policy.
planServiceScaffoldWithRuntimePackage :: Maybe RuntimePackageName -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planServiceScaffoldWithRuntimePackage = planServiceScaffoldWithRuntimePackageAndGoldens []

planServiceScaffoldWithRuntimePackageAndGoldens :: [GoldenPayload] -> Maybe RuntimePackageName -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planServiceScaffoldWithRuntimePackageAndGoldens goldens runtimePackage ctx service =
  planningGatePipeline ctx service modulePlan (Right ())
  where
    facadeModules = case runtimePackage of
      Nothing -> Right []
      Just _ -> fmap pure (serviceHarnessModule ctx service)
    modulePlan =
      case facadeModules of
        Left duplicates -> Left [DuplicateConformanceFactKeys duplicates]
        Right facades ->
          Right $
            stampGeneratedModules
              (checkedLanguageContract service)
              (scaffoldServiceModulesWithGoldens goldens ctx service <> facades)

-- | The one pure scaffold-planning gate sequence. Both scaffold planners and
-- both check paths consume this function, so the first reported refusal cannot
-- drift by input shape.
planningGatePipeline ::
  Context ->
  CheckedService ->
  Either [Refusal] [ScaffoldModule] ->
  Either [Refusal] () ->
  Either [Refusal] [ScaffoldModule]
planningGatePipeline ctx service modulePlan packagePlan =
  case traverse (aggregateFoldSurfaceForService service) [aggregate | NAggregate aggregate <- specNodes spec] of
    Left surfaceError -> Left [FoldSurfaceRefusal surfaceError]
    Right _ -> case scaffoldRefusals spec of
      lowering@(_ : _) -> Left [LoweringRefusal lowering]
      [] -> case modulePlan of
        Left refusals -> Left refusals
        Right modules -> case packagePlan of
          Left refusals -> Left refusals
          Right () -> case pureRefusals ctx spec modules of
            [] -> Right modules
            refusals -> Left refusals
  where
    spec = checkedSpec service

-- | Validate a checked service, then run the shared planning gates unless an
-- error makes module generation unsound. 'GeneratedOccurrenceCollision' is the
-- deliberate exception: the workspace path already plans through it so the
-- stronger whole-path collision can cite every claimant. Existing diagnostics
-- retain their order and planning diagnostics follow them.
-- | The nodes a spec declares that contribute no generated module.
--
-- They are still parsed, validated, and diff-classified; naming them in the
-- scaffold report is what stops an author from concluding the toolchain lost
-- their declaration. Shared by the single-spec and workspace planners so a
-- workspace — the recommended layout — reports exactly what one spec reports.
inertNodesOf :: Spec -> [(Text, Text)]
inertNodesOf spec =
  [ (kindLabel, nodeName)
  | node <- specNodes spec,
    (kindLabel, nodeName) <- case node of
      NEmit emitNode -> [("emit", emName emitNode)]
      NPgmqDispatch dispatchNode -> [("dispatch", pdName dispatchNode)]
      NOperation operationNode -> [("operation", opName operationNode)]
      _ -> []
  ]

-- | The report line naming 'inertNodesOf', or nothing when every declaration
-- produced a module.
renderInertNodeSection :: [(Text, Text)] -> [Text]
renderInertNodeSection = \case
  [] -> []
  nodes ->
    [ "no-modules: "
        <> T.intercalate ", " [kindLabel <> " " <> nodeName | (kindLabel, nodeName) <- nodes]
        <> " (validated and diff-classified; no generated modules)"
    ]

checkServiceDiagnostics :: Maybe RuntimePackageName -> Context -> CheckedService -> [Diagnostic]
checkServiceDiagnostics runtimePackage ctx service
  | any blocksPlanning validationDiagnostics = validationDiagnostics
  | otherwise =
      validationDiagnostics
        <> case planServiceScaffoldWithRuntimePackage runtimePackage ctx service of
          Right _ -> []
          Left refusals -> planningRefusalDiagnostics refusals
  where
    validationDiagnostics = validateService service
    blocksPlanning diagnostic =
      severity diagnostic == Error
        && code diagnostic /= GeneratedOccurrenceCollision

-- | Present pure planning refusals through check's stable located diagnostic
-- vocabulary. Planner-invariant failures retain the detailed scaffold refusal
-- text in their message while receiving one machine code.
planningRefusalDiagnostics :: [Refusal] -> [Diagnostic]
planningRefusalDiagnostics = concatMap diagnosticsFor
  where
    diagnosticsFor (PathCollision path origins) = [pathCollisionDiagnostic path origins]
    diagnosticsFor (ImportCycle path) =
      [ planningError 1 GeneratedImportCycle $
          "generated/consumer import cycle "
            <> T.intercalate " -> " path
            <> "; keep bindings in a leaf module that imports only Structural.Shape.* and Keiro.Codec.Structural"
      ]
    diagnosticsFor (BehaviorRefusal errors) =
      [ planningError (behaviorErrorLine behaviorError) BehaviorDerivationInvalid $
          "behavior obligations cannot be derived soundly: " <> T.pack (show behaviorError)
      | behaviorError <- errors
      ]
    diagnosticsFor (DuplicateConformanceFactKeys duplicates) =
      [ planningError 1 ConformanceFactKeyCollision $
          "normalized service conformance fact key '"
            <> duplicateServiceFactKey duplicate
            <> "' is produced more than once"
      | duplicate <- duplicates
      ]
    diagnosticsFor refusal =
      [ planningError 1 GeneratedPlanningInvariantViolation $
          "validated service failed an internal scaffold-planning invariant: "
            <> T.intercalate " | " (renderRefusals [refusal])
      ]

    pathCollisionDiagnostic path origins =
      Diagnostic
        { line = primaryLine,
          severity = Error,
          code = GeneratedPathCollision,
          relatedLocations =
            [ (claimLine, "claimed here by " <> claimOrigin)
            | (claimLine, claimOrigin) <- remainingClaims
            ],
          message =
            "generated module path '"
              <> T.pack path
              <> "' is claimed more than once; on a case-insensitive filesystem these are one file; claimants: "
              <> T.intercalate "; " origins
        }
      where
        orderedClaims = reverse (sortOn fst [(claimLine, claimOrigin) | claimOrigin <- origins, Just claimLine <- [originLine claimOrigin]])
        (primaryLine, remainingClaims) = case orderedClaims of
          (claimLine, _) : rest -> (claimLine, rest)
          [] -> (1, [])

    behaviorErrorLine (Behavior.DuplicateBehaviorIdentity _ locations) = maximum (1 : map unLoc locations)
    behaviorErrorLine _ = 1

    planningError diagnosticLine diagnosticCode diagnosticMessage =
      Diagnostic
        { line = diagnosticLine,
          severity = Error,
          code = diagnosticCode,
          relatedLocations = [],
          message = diagnosticMessage
        }

-- | Recover the source line embedded in a generated module's origin text,
-- which scaffold formats as @<kind> <name> (line N)@.
originLine :: Text -> Maybe Int
originLine originText = do
  withoutClose <- T.stripSuffix ")" originText
  let (before, after) = T.breakOnEnd " (line " withoutClose
  if T.null before then Nothing else readMaybe (T.unpack after)

-- | Run every pure refusal gate. A successful result is the exact write set;
-- a refusal has no write set and therefore cannot be accidentally executed.
planScaffold :: Context -> Spec -> Either [Refusal] [ScaffoldModule]
planScaffold = planScaffoldWithGoldens []

planScaffoldWithGoldens :: [GoldenPayload] -> Context -> Spec -> Either [Refusal] [ScaffoldModule]
planScaffoldWithGoldens goldens ctx = planServiceScaffoldWithGoldens goldens ctx . legacyCheckedService

-- | Every pure refusal gate, over an already-built module set: case-folded path
-- collisions, generated\/consumer collisions and import cycles, firewall breaches,
-- and lowering refusals. Whole-workspace planning builds its module set from the
-- merged spec and then runs exactly this, so no gate can apply to one input shape
-- and not the other.
pureRefusals :: Context -> Spec -> [ScaffoldModule] -> [Refusal]
pureRefusals ctx spec modules =
  collisionRefusals modules
    <> dependencyRefusals ctx spec modules
    <> [FirewallBreach breaches | not (null breaches)]
    <> [GeneratedNameInvariantViolation namingViolations | not (null namingViolations)]
    <> [LoweringRefusal lowering | let lowering = scaffoldRefusals spec, not (null lowering)]
    <> [BehaviorRefusal errors | Left errors <- [deriveBehaviorRequirements spec]]
  where
    breaches = firewallBreaches modules
    namingViolations = generatedNameInvariantViolations modules

generatedNameInvariantViolations :: [ScaffoldModule] -> [Text]
generatedNameInvariantViolations = concatMap auditGeneratedHaskell

-- | Inventory and check declarations in one generated source file.  The
-- lexical mask keeps comments and literals out of the declaration inventory;
-- this is deliberately a final defense after the typed naming plan, so a
-- literal template declaration cannot bypass the checked constructors.
auditGeneratedHaskell :: ScaffoldModule -> [Text]
auditGeneratedHaskell scaffoldModule = lexicalErrors <> declarationErrors <> duplicateDeclarationErrors <> occurrenceErrors
  where
    expectedModule = moduleNameOf (modulePath scaffoldModule)
    (lexicalErrors, codeSource) = case maskNonCode (moduleText scaffoldModule) of
      Left message -> ([prefix 1 <> message], "")
      Right masked -> ([], masked)
    sourceLines = zip [1 :: Int ..] (T.lines codeSource)
    declarationErrors = moduleDeclarationErrors <> moduleSegmentErrors
    moduleDeclarationErrors = case declaredModuleName codeSource of
      Nothing -> [T.pack (modulePath scaffoldModule) <> ": missing Haskell module declaration"]
      Just declared
        | declared == expectedModule -> []
        | otherwise ->
            [ T.pack (modulePath scaffoldModule)
                <> ": declares "
                <> declared
                <> " but its planned module is "
                <> expectedModule
            ]
    moduleSegmentErrors =
      [ prefix 1 <> "module segment '" <> segment <> "' is not UpperCamelCase"
      | segment <- T.splitOn "." expectedModule,
        isLeftName (HaskellName.checkedModuleSegment (auditSite HaskellName.NodeModuleSite segment 1) segment)
      ]
    occurrenceErrors =
      concat
        [ checkCandidates lineNumber (signatureCandidates sourceLine)
            <> checkCandidates lineNumber (typeCandidates sourceLine)
            <> checkCandidates lineNumber (constructorCandidates sourceLine)
            <> checkCandidates lineNumber (topLevelValueCandidates sourceLine)
        | (lineNumber, sourceLine) <- sourceLines
        ]

    duplicateDeclarationErrors = duplicateErrors "top-level type signature" signatureCandidates <> duplicateErrors "top-level type declaration" typeCandidates
    duplicateErrors label candidates =
      [ prefix laterLine
          <> "repeated "
          <> label
          <> " '"
          <> candidate
          <> "' (first declared at line "
          <> tshow firstLine
          <> ")"
      | (candidate, declarationLines) <- Map.toAscList declarations,
        firstLine : laterLines <- [declarationLines],
        laterLine <- laterLines
      ]
      where
        declarations =
          Map.fromListWith
            (flip (++))
            [ (candidate, [lineNumber])
            | (lineNumber, sourceLine) <- sourceLines,
              sourceLine == T.stripStart sourceLine,
              candidate <- candidates sourceLine
            ]

    checkCandidates lineNumber = concatMap (checkCandidate lineNumber)
    checkCandidate lineNumber candidate
      | T.null candidate = []
      | asciiUpperInitial candidate =
          [prefix lineNumber <> "generated declaration '" <> candidate <> "' is not UpperCamelCase" | isLeftName (HaskellName.checkedUpperOccurrence (auditSite HaskellName.GeneratedTypeSite candidate lineNumber) candidate)]
      | otherwise =
          [prefix lineNumber <> "generated declaration '" <> candidate <> "' is not lowerCamelCase" | isLeftName (HaskellName.checkedLowerOccurrence (auditSite HaskellName.GeneratedValueSite candidate lineNumber) candidate)]

    prefix lineNumber = T.pack (modulePath scaffoldModule) <> ":" <> tshow lineNumber <> ": "

    auditSite kind candidate lineNumber =
      HaskellName.NameSite
        { HaskellName.siteKind = kind,
          HaskellName.siteLogicalName = candidate,
          HaskellName.siteOwner = T.pack (modulePath scaffoldModule),
          HaskellName.siteLine = lineNumber
        }

isLeftName :: Either left right -> Bool
isLeftName = \case Left _ -> True; Right _ -> False

declaredModuleName :: Text -> Maybe Text
declaredModuleName source =
  case [T.takeWhile moduleCharacter (T.drop 7 sourceLine) | sourceLine <- T.lines source, "module " `T.isPrefixOf` sourceLine] of
    declaration : _ | not (T.null declaration) -> Just declaration
    _ -> Nothing
  where
    moduleCharacter character = identifierCharacter character || character == '.'

signatureCandidates :: Text -> [Text]
signatureCandidates sourceLine
  | T.null suffix || T.any (`elem` ['=', '(', ')', '[', ']']) prefix = []
  | otherwise = filter isIdentifier (map T.strip (T.splitOn "," prefix))
  where
    (prefix, suffix) = T.breakOn "::" (T.strip sourceLine)

typeCandidates :: Text -> [Text]
typeCandidates sourceLine = case T.words (T.strip sourceLine) of
  keyword : candidate : _
    | keyword `elem` ["data", "newtype", "type"], candidate /= "family", candidate /= "instance" -> [cleanIdentifier candidate]
  _ -> []

constructorCandidates :: Text -> [Text]
constructorCandidates sourceLine
  | "|" `T.isPrefixOf` stripped = takeFollowingIdentifier (T.drop 1 stripped)
  | any (`T.isPrefixOf` stripped) ["data ", "newtype "] = takeFollowingIdentifier (T.drop 1 (snd (T.breakOn "=" stripped)))
  | otherwise = []
  where
    stripped = T.strip sourceLine
    takeFollowingIdentifier value = case T.words value of
      candidate : _ | asciiUpperInitial (cleanIdentifier candidate) -> [cleanIdentifier candidate]
      _ -> []

topLevelValueCandidates :: Text -> [Text]
topLevelValueCandidates sourceLine
  | T.null sourceLine || T.head sourceLine == ' ' || T.head sourceLine == '\t' = []
  | T.null suffix = []
  | otherwise = case T.words prefix of
      candidate : _
        | candidate `notElem` declarationKeywords,
          isIdentifier candidate ->
            [candidate]
      _ -> []
  where
    (prefix, suffix) = T.breakOn "=" sourceLine
    declarationKeywords = ["data", "newtype", "type", "class", "instance", "module", "import", "deriving", "infix", "infixl", "infixr"]

cleanIdentifier :: Text -> Text
cleanIdentifier = T.takeWhile identifierCharacter . T.dropWhile (not . identifierCharacter)

isIdentifier :: Text -> Bool
isIdentifier candidate = not (T.null candidate) && T.all identifierCharacter candidate

identifierCharacter :: Char -> Bool
identifierCharacter character =
  (character >= 'A' && character <= 'Z')
    || (character >= 'a' && character <= 'z')
    || (character >= '0' && character <= '9')
    || character == '_'
    || character == '\''

asciiUpperInitial :: Text -> Bool
asciiUpperInitial candidate = case T.uncons candidate of
  Just (first, _) -> first >= 'A' && first <= 'Z'
  Nothing -> False

data AuditLexState = AuditCode | AuditLineComment | AuditBlockComment !Int | AuditString | AuditCharacter

maskNonCode :: Text -> Either Text Text
maskNonCode = fmap T.pack . go AuditCode . T.unpack
  where
    go state input = case (state, input) of
      (AuditCode, []) -> Right []
      (AuditLineComment, []) -> Right []
      (AuditBlockComment _, []) -> Left "unterminated block comment in generated source"
      (AuditString, []) -> Left "unterminated string literal in generated source"
      (AuditCharacter, []) -> Left "unterminated character literal in generated source"
      (AuditCode, '-' : '-' : rest) -> prependSpaces 2 <$> go AuditLineComment rest
      (AuditCode, '{' : '-' : rest) -> prependSpaces 2 <$> go (AuditBlockComment 1) rest
      (AuditCode, '"' : rest) -> (' ' :) <$> go AuditString rest
      (AuditCode, '\'' : rest)
        | looksLikeCharacterLiteral rest -> (' ' :) <$> go AuditCharacter rest
      (AuditCode, character : rest) -> (character :) <$> go AuditCode rest
      (AuditLineComment, '\n' : rest) -> ('\n' :) <$> go AuditCode rest
      (AuditLineComment, _ : rest) -> (' ' :) <$> go AuditLineComment rest
      (AuditBlockComment depth, '{' : '-' : rest) -> prependSpaces 2 <$> go (AuditBlockComment (depth + 1)) rest
      (AuditBlockComment 1, '-' : '}' : rest) -> prependSpaces 2 <$> go AuditCode rest
      (AuditBlockComment depth, '-' : '}' : rest) -> prependSpaces 2 <$> go (AuditBlockComment (depth - 1)) rest
      (AuditBlockComment depth, '\n' : rest) -> ('\n' :) <$> go (AuditBlockComment depth) rest
      (AuditBlockComment depth, _ : rest) -> (' ' :) <$> go (AuditBlockComment depth) rest
      (AuditString, '\\' : _escaped : rest) -> prependSpaces 2 <$> go AuditString rest
      (AuditString, '"' : rest) -> (' ' :) <$> go AuditCode rest
      (AuditString, '\n' : _) -> Left "newline in generated string literal"
      (AuditString, _ : rest) -> (' ' :) <$> go AuditString rest
      (AuditCharacter, '\\' : _escaped : rest) -> prependSpaces 2 <$> go AuditCharacter rest
      (AuditCharacter, '\'' : rest) -> (' ' :) <$> go AuditCode rest
      (AuditCharacter, '\n' : _) -> Left "newline in generated character literal"
      (AuditCharacter, _ : rest) -> (' ' :) <$> go AuditCharacter rest

    prependSpaces count suffix = replicate count ' ' <> suffix
    looksLikeCharacterLiteral = \case
      '\\' : _escaped : '\'' : _ -> True
      _character : '\'' : _ -> True
      _ -> False

dependencyRefusals :: Context -> Spec -> [ScaffoldModule] -> [Refusal]
dependencyRefusals ctx spec modules = collisionWithConsumers <> namespaceCycles
  where
    plan = consumerPlan spec
    generatedByName = Map.fromList [(moduleNameOf (modulePath moduleValue), moduleValue) | moduleValue <- modules, kind moduleValue == Generated]
    collisionWithConsumers =
      [ PathCollision
          (modulePath generated)
          [origin generated, "consumer module " <> consumerModule]
      | consumerModule <- consumerModules plan,
        Just generated <- [Map.lookup consumerModule generatedByName]
      ]
    namespaceCycles =
      [ ImportCycle [importer, consumerModule, importer]
      | consumerModule <- consumerModules plan,
        generatedNamespaceOwned ctx consumerModule,
        importer <- take 1 (importersOf consumerModule modules <> [contextGeneratedRoot ctx])
      ]

generatedNamespaceOwned :: Context -> Text -> Bool
generatedNamespaceOwned ctx consumerModule = case placement ctx of
  GeneratedPrefix -> contextGeneratedRoot ctx `T.isPrefixOf` consumerModule
  CollocatedLeaf ->
    (root <> contextSegment <> ".") `T.isPrefixOf` consumerModule
      && ".Generated" `T.isInfixOf` consumerModule
  where
    root = if T.null (moduleRoot ctx) then "" else moduleRoot ctx <> "."
    contextSegment = pascalFromKebab (contextName ctx)

contextGeneratedRoot :: Context -> Text
contextGeneratedRoot ctx = case placement ctx of
  GeneratedPrefix -> root <> "Generated." <> contextSegment
  CollocatedLeaf -> root <> contextSegment <> ".Generated"
  where
    root = if T.null (moduleRoot ctx) then "" else moduleRoot ctx <> "."
    contextSegment = pascalFromKebab (contextName ctx)

importersOf :: Text -> [ScaffoldModule] -> [Text]
importersOf imported =
  map (moduleNameOf . modulePath)
    . filter (any (importsModule imported) . T.lines . moduleText)

importsModule :: Text -> Text -> Bool
importsModule expected line = case T.words (T.strip line) of
  "import" : rest -> expected `elem` rest
  _ -> False

collisionRefusals :: [ScaffoldModule] -> [Refusal]
collisionRefusals modules =
  [ PathCollision (modulePath first) (map origin (first : rest))
  | first : rest <- Map.elems grouped,
    not (null rest)
  ]
  where
    grouped =
      Map.fromListWith
        (flip (<>))
        [(T.toCaseFold (T.pack (modulePath m)), [m]) | m <- modules]

-- | Check existing generated paths, then perform the deterministic writes and
-- manifest rewrite. Banner refusal is evaluated for the complete set before the
-- output directory is created or any file is changed.
executeScaffold :: FilePath -> Bool -> FilePath -> Context -> Spec -> [ScaffoldModule] -> IO (Either [Refusal] ScaffoldReport)
executeScaffold out forceGeneratedOverwrite specPath ctx spec modules =
  executeScaffoldWithLanguage out forceGeneratedOverwrite specPath LegacyUnversioned ctx spec modules

-- | Source-aware execution used by the CLI; semantic planning still receives only 'Spec'.
executeScaffoldWithLanguage :: FilePath -> Bool -> FilePath -> SourceLanguage -> Context -> Spec -> [ScaffoldModule] -> IO (Either [Refusal] ScaffoldReport)
executeScaffoldWithLanguage out forceGeneratedOverwrite specPath sourceLanguage ctx spec modules =
  executeServiceScaffold out forceGeneratedOverwrite specPath sourceLanguage ctx (checkedService sourceLanguage spec) modules

-- | Execute a module plan while retaining both the effective semantic contract
-- and the source declaration provenance written to history. A mismatch refuses
-- before checking or creating any output path.
executeServiceScaffold :: FilePath -> Bool -> FilePath -> SourceLanguage -> Context -> CheckedService -> [ScaffoldModule] -> IO (Either [Refusal] ScaffoldReport)
executeServiceScaffold = executeServiceScaffoldWithRuntimePackage Nothing

executeServiceScaffoldWithRuntimePackage :: Maybe RuntimePackageName -> FilePath -> Bool -> FilePath -> SourceLanguage -> Context -> CheckedService -> [ScaffoldModule] -> IO (Either [Refusal] ScaffoldReport)
executeServiceScaffoldWithRuntimePackage runtimePackage =
  executeServiceScaffoldWithRuntimePackageAndNameMigrations runtimePackage False

executeServiceScaffoldWithRuntimePackageAndNameMigrations :: Maybe RuntimePackageName -> Bool -> FilePath -> Bool -> FilePath -> SourceLanguage -> Context -> CheckedService -> [ScaffoldModule] -> IO (Either [Refusal] ScaffoldReport)
executeServiceScaffoldWithRuntimePackageAndNameMigrations runtimePackage applyNameMigrations out forceGeneratedOverwrite specPath sourceLanguage ctx service plannedModules
  | effectiveLanguageContract sourceLanguage /= checkedLanguageContract service =
      pure (Left [SemanticContractMismatch "source provenance and checked service selected different effective language contracts"])
  | otherwise = case packagePlan of
      Left failures -> pure (Left (map ConformancePackageRefusal failures))
      Right plannedPackage -> do
        sidecarResult <- planSidecarMigrations out (ContextSidecars (specContext spec)) plannedPackage
        case sidecarResult of
          Left reasons -> pure (Left [SidecarMigrationRefusal reasons])
          Right preparedSidecars
            | not (null preparedSidecars) && not applyNameMigrations ->
                pure (Left [SidecarMigrationRequired (map preparedSidecarMove preparedSidecars)])
            | otherwise -> do
                applyPreparedSidecarMoves out preparedSidecars
                let moves = map preparedSidecarMove preparedSidecars
                    -- Past this point the renames are on disk, so a later
                    -- refusal's "nothing was written" needs qualifying.
                    noteApplied = withSidecarMovesApplied moves
                result <- case plannedPackage of
                  Nothing -> executeCheckedScaffold moves Nothing
                  Just package -> do
                    preparedPackage <- preflightConformancePackage out forceGeneratedOverwrite package
                    case preparedPackage of
                      Left failures -> pure (Left (map ConformancePackageRefusal failures))
                      Right packageReady -> executeCheckedScaffold moves (Just packageReady)
                pure (either (Left . noteApplied) Right result)
  where
    spec = checkedSpec service
    modules = stampGeneratedModules (checkedLanguageContract service) plannedModules
    facadeModule = case runtimePackage of
      Nothing -> Nothing
      Just _ -> Just (serviceConformanceModuleName ctx)
    packagePlan =
      traverse
        (\packageName -> planConformancePackage (StandaloneConformanceService (contextName ctx)) packageName (serviceConformanceModuleName ctx) service)
        runtimePackage
    executeCheckedScaffold sidecarMoves preparedPackage =
      case deriveBehaviorRequirements spec of
        Left errors -> pure (Left [BehaviorRefusal errors])
        Right requirements -> do
          bannerless <- if forceGeneratedOverwrite then pure [] else missingGeneratedBanners out modules
          if not (null bannerless)
            then pure (Left [MissingGeneratedBanner bannerless])
            else do
              let recordPath = out </> recordFileName (specContext spec)
              previousRecord <- readRecord recordPath
              case planRecordedSourceMoves previousRecord modules of
                Left moveErrors -> pure (Left [NameMigrationRefusal [T.pack (show moveError) | moveError <- NE.toList moveErrors]])
                Right moves -> do
                  preparedMoves <- preflightSourceMoves out moves
                  case preparedMoves of
                    Left moveErrors -> pure (Left [NameMigrationRefusal moveErrors])
                    Right prepared
                      | not (null prepared) && not applyNameMigrations ->
                          pure (Left [NameMigrationRequired (map preparedSourceMove prepared)])
                      | otherwise -> do
                          applyPreparedSourceMoves out prepared
                          stale <- maybe (pure []) (existingStale out modules) previousRecord
                          let currentConsumerPlan = consumerPlan spec
                              drift = maybe [] (mappingDrift (consumerMappings currentConsumerPlan) . recMappings) previousRecord
                              languageDrift = do
                                previous <- previousRecord
                                if recSourceLanguage previous == sourceLanguage
                                  then Nothing
                                  else Just (SourceLanguageDrift (recSourceLanguage previous) sourceLanguage)
                              currentObligations = either (const []) id (bindingHolesForService service)
                              newHoles = maybe [] (newBindingObligations currentObligations . recBindingObligations) previousRecord
                              currentBehavior = behaviorRecordRows requirements
                              (addedBehavior, removedBehavior) = maybe (currentBehavior, []) (behaviorDrift currentBehavior . recBehaviorRequirements) previousRecord
                          createDirectoryIfMissing True out
                          dispositions <- mapM (writeModule out) modules
                          let manifestPath = out </> contextCabalFragmentFileName (specContext spec)
                          TIO.writeFile manifestPath (renderManifestForServiceWithFacade facadeModule (T.pack specPath) modules service)
                          TIO.writeFile recordPath (renderRecord (currentRecord specPath sourceLanguage ctx service modules currentBehavior))
                          packageReport <- traverse executePreparedConformancePackage preparedPackage
                          pure $
                            Right
                              ScaffoldReport
                                { reportSpecPath = specPath,
                                  reportOutDir = out,
                                  reportContext = ctx,
                                  reportDispositions = dispositions,
                                  reportInertNodes = inertNodesOf spec,
                                  reportManifestPath = manifestPath,
                                  reportRecordPath = recordPath,
                                  reportPreviousSpecPath = recSpecPath <$> previousRecord,
                                  reportStale = stale,
                                  reportConsumerPlan = currentConsumerPlan,
                                  reportConstraintPlan = constraintPlan spec currentConsumerPlan,
                                  reportMappingDrift = drift,
                                  reportSourceLanguageDrift = languageDrift,
                                  reportNewHoles = newHoles,
                                  reportAddedBehavior = addedBehavior,
                                  reportRemovedBehavior = removedBehavior,
                                  reportObsoleteOutputHooks = obsoleteGeneratedOutputHooks spec,
                                  reportConformancePackage = packageReport,
                                  reportNameMoves = map preparedSourceMove prepared,
                                  reportSidecarMoves = sidecarMoves
                                }

planRecordedSourceMoves :: Maybe ScaffoldRecord -> [ScaffoldModule] -> Either (NE.NonEmpty SourceMoveError) [SourceMove]
planRecordedSourceMoves Nothing _ = Right []
planRecordedSourceMoves (Just previous) current =
  planSourceMoves priorArtifacts current
  where
    priorArtifacts = case recModuleRoles previous of
      [] -> [(Nothing, fileKind, path) | (fileKind, path) <- recFiles previous]
      rows -> [(Just (srrRole row), srrKind row, srrPath row) | row <- rows]

data PreparedSourceMove
  = SourceMoveReady !SourceMove !Text
  | SourceMoveAlreadyApplied !SourceMove

preparedSourceMove :: PreparedSourceMove -> SourceMove
preparedSourceMove = \case
  SourceMoveReady move _ -> move
  SourceMoveAlreadyApplied move -> move

preflightSourceMoves :: FilePath -> [SourceMove] -> IO (Either [Text] [PreparedSourceMove])
preflightSourceMoves out moves = do
  prepared <- mapM preflight moves
  let errors = [message | Left message <- prepared]
  pure $ if null errors then Right [value | Right value <- prepared] else Left errors
  where
    replacements = Map.fromList [(moveOldModule move, moveNewModule move) | move <- moves]
    preflight move = do
      let oldPath = out </> moveOldPath move
          newPath = out </> moveNewPath move
          backupPath = out </> moveBackupPath move
          preparedPath = preparedSourcePath out move
          statePath = sourceMoveStatePath out move
      oldExists <- doesFileExist oldPath
      newExists <- doesFileExist newPath
      backupExists <- doesFileExist backupPath
      preparedExists <- doesFileExist preparedPath
      stateExists <- doesFileExist statePath
      case (oldExists, backupExists) of
        (True, True) -> conflict move newExists backupExists preparedExists "both legacy source and backup exist"
        (False, False) ->
          if newExists
            then conflict move newExists backupExists preparedExists "target exists without a recoverable legacy source"
            else pure (Left (T.pack (moveOldPath move) <> ": recorded legacy source is missing"))
        _ -> do
          source <- TIO.readFile (if oldExists then oldPath else backupPath)
          if moveKind move == Generated && not (any isGeneratedBannerLine (T.lines source))
            then pure (Left (T.pack (moveOldPath move) <> ": generated source lacks an exact generated banner"))
            else case rewriteHaskellModuleReferences replacements source of
              Left lexicalError -> pure (Left (T.pack (moveOldPath move) <> ": " <> T.pack (show lexicalError)))
              Right rewritten
                | not (declaresExpectedModule (moveNewModule move) rewritten) ->
                    pure
                      ( Left
                          ( T.pack (moveOldPath move)
                              <> ": transformed source does not declare expected module "
                              <> moveNewModule move
                          )
                      )
                | otherwise -> do
                    let hydrated =
                          move
                            { moveContentDigest = Just (contentDigest source),
                              moveTransformedDigest = Just (contentDigest rewritten)
                            }
                        expectedState = renderSourceMoveState hydrated
                    stateError <- verifyOptionalText stateExists statePath expectedState "migration state"
                    preparedError <- verifyOptionalDigest preparedExists preparedPath (contentDigest rewritten) "prepared source"
                    targetError <- verifyOptionalDigest newExists newPath (contentDigest rewritten) "target source"
                    case [message | Just message <- [stateError, preparedError, targetError]] of
                      message : _ -> pure (Left (T.pack (moveOldPath move) <> ": " <> message))
                      []
                        | newExists && not backupExists && not oldExists -> conflict hydrated newExists backupExists preparedExists "target has no recoverable backup"
                        | newExists && backupExists && not oldExists -> pure (Right (SourceMoveAlreadyApplied hydrated))
                        | otherwise -> pure (Right (SourceMoveReady hydrated rewritten))

    conflict move newExists backupExists preparedExists reason =
      pure
        ( Left
            ( T.pack (moveOldPath move)
                <> ": migration state conflicts ("
                <> reason
                <> "; target="
                <> T.pack (show newExists)
                <> ", backup="
                <> T.pack (show backupExists)
                <> ", prepared="
                <> T.pack (show preparedExists)
                <> ")"
            )
        )

    verifyOptionalText False _ _ _ = pure Nothing
    verifyOptionalText True path expected label = do
      actual <- TIO.readFile path
      pure $ if actual == expected then Nothing else Just (label <> " digest/path evidence does not match")

    verifyOptionalDigest False _ _ _ = pure Nothing
    verifyOptionalDigest True path expected label = do
      actual <- contentDigest <$> TIO.readFile path
      pure $ if actual == expected then Nothing else Just (label <> " digest does not match " <> expected)

    declaresExpectedModule expected source =
      any (T.isPrefixOf ("module " <> expected <> " ")) (T.lines source)
        || any (== ("module " <> expected)) (T.lines source)

applyPreparedSourceMoves :: FilePath -> [PreparedSourceMove] -> IO ()
applyPreparedSourceMoves out prepared = do
  -- Prepare every transformed file and durable digest record before moving a
  -- single active source.  The temporary file lives beside its destination,
  -- so installation is a same-filesystem rename.
  mapM_ prepareMove prepared
  mapM_ backupMove prepared
  mapM_ installMove prepared
  where
    prepareMove preparedMove = do
      let move = preparedSourceMove preparedMove
          statePath = sourceMoveStatePath out move
      createDirectoryIfMissing True (takeDirectory statePath)
      TIO.writeFile statePath (renderSourceMoveState move)
      case preparedMove of
        SourceMoveAlreadyApplied _ -> pure ()
        SourceMoveReady _ rewritten -> do
          let path = preparedSourcePath out move
          createDirectoryIfMissing True (takeDirectory path)
          exists <- doesFileExist path
          if exists then pure () else TIO.writeFile path rewritten

    backupMove (SourceMoveAlreadyApplied _) = pure ()
    backupMove (SourceMoveReady move _) = do
      let oldPath = out </> moveOldPath move
          backupPath = out </> moveBackupPath move
      oldExists <- doesFileExist oldPath
      if oldExists
        then do
          createDirectoryIfMissing True (takeDirectory backupPath)
          renameFile oldPath backupPath
        else pure ()

    installMove preparedMove = do
      let move = preparedSourceMove preparedMove
          preparedPath = preparedSourcePath out move
          newPath = out </> moveNewPath move
      newExists <- doesFileExist newPath
      preparedExists <- doesFileExist preparedPath
      if newExists
        then if preparedExists then removeFile preparedPath else pure ()
        else do
          createDirectoryIfMissing True (takeDirectory newPath)
          renameFile preparedPath newPath

preparedSourcePath :: FilePath -> SourceMove -> FilePath
preparedSourcePath out move = out </> (moveNewPath move <> ".keiro-dsl-name-migration-prepared")

sourceMoveStatePath :: FilePath -> SourceMove -> FilePath
sourceMoveStatePath out move = out </> (moveBackupPath move <> ".keiro-dsl-name-migration-state")

renderSourceMoveState :: SourceMove -> Text
renderSourceMoveState move =
  T.unlines
    [ "keiro-dsl-name-migration-state v1",
      "old-path " <> T.pack (moveOldPath move),
      "new-path " <> T.pack (moveNewPath move),
      "old-module " <> moveOldModule move,
      "new-module " <> moveNewModule move,
      "source-digest " <> maybe "<missing>" id (moveContentDigest move),
      "transformed-digest " <> maybe "<missing>" id (moveTransformedDigest move)
    ]

constraintPlan :: Spec -> ConsumerPlan -> [Text]
constraintPlan spec plan = case resolveTypeGraph spec of
  Left _ -> []
  Right graph ->
    let registerRoots =
          Set.fromList
            [ key
            | RootRegister _ _ key <- tgUseSites graph
            ]
     in map (constraintFor registerRoots) (consumerMappings plan)
  where
    constraintFor registerRoots mapping =
      mappingSpecName mapping
        <> ": "
        <> T.intercalate ", " (baseConstraints mapping <> registerConstraints registerRoots mapping)
    baseConstraints StructuralMapping {} = ["Eq", "Show", "CanonicalTypeName", "StructuralBinding"]
    baseConstraints OpaqueMapping {} = ["Eq", "Show", "ToJSON", "FromJSON"]
    baseConstraints NominalMapping {} = ["Eq", "Show", "NominalBinding"]
    registerConstraints roots mapping
      | MappedKey (mappingSpecName mapping) `Set.member` roots = ["register initial", "snapshot ToJSON", "snapshot FromJSON"]
      | otherwise = []

mappingDrift :: [MappingIdentity] -> [MappingIdentity] -> [MappingDrift]
mappingDrift current previous =
  [ MappingDrift name old new
  | name <- Set.toAscList (Map.keysSet oldByName <> Map.keysSet newByName),
    let old = Map.lookup name oldByName,
    let new = Map.lookup name newByName,
    old /= new
  ]
  where
    oldByName = Map.fromList [(mappingSpecName mapping, mapping) | mapping <- previous]
    newByName = Map.fromList [(mappingSpecName mapping, mapping) | mapping <- current]

newBindingObligations :: [BindingHole] -> [BindingHole] -> [BindingHole]
newBindingObligations current previous =
  [ obligation
  | obligation <- current,
    obligation `Set.notMember` previousSet
  ]
  where
    previousSet = Set.fromList previous

behaviorDrift :: [BehaviorRecordRow] -> [BehaviorRecordRow] -> ([BehaviorRecordRow], [BehaviorRecordRow])
behaviorDrift current previous =
  ( [row | row <- sortOn behaviorRecordKey current, behaviorRecordKey row `Set.notMember` previousKeys],
    [row | row <- sortOn behaviorRecordKey previous, behaviorRecordKey row `Set.notMember` currentKeys]
  )
  where
    currentKeys = Set.fromList (map behaviorRecordKey current)
    previousKeys = Set.fromList (map behaviorRecordKey previous)

readRecord :: FilePath -> IO (Maybe ScaffoldRecord)
readRecord path = do
  exists <- doesFileExist path
  if exists then parseRecord <$> TIO.readFile path else pure Nothing

existingStale :: FilePath -> [ScaffoldModule] -> ScaffoldRecord -> IO [StaleModule]
existingStale out modules record = staleAgainst out (map modulePath modules) (recFiles record)

-- | The files a previous run recorded that the current plan no longer produces
-- and that are still on disk. keiro-dsl never deletes; this is what the report
-- lists for a human to review.
staleAgainst :: FilePath -> [FilePath] -> [(ModuleKind, FilePath)] -> IO [StaleModule]
staleAgainst out currentPathList previous = fmap concat $ mapM stillExists removed
  where
    currentPaths = Set.fromList currentPathList
    removed = [(fileKind, path) | (fileKind, path) <- previous, path `Set.notMember` currentPaths]
    stillExists (fileKind, path) = do
      let fullPath = out </> path
      exists <- doesFileExist fullPath
      if not exists
        then pure []
        else do
          evidence <- case fileKind of
            HoleStub -> pure Nothing
            Generated -> do
              contents <- TIO.readFile fullPath
              pure . Just $
                if any isGeneratedBannerLine (T.lines contents)
                  then ExactGeneratedBannerPresent
                  else ExactGeneratedBannerMissing
          pure [StaleModule fileKind path evidence]

currentRecord :: FilePath -> SourceLanguage -> Context -> CheckedService -> [ScaffoldModule] -> [BehaviorRecordRow] -> ScaffoldRecord
currentRecord specPath sourceLanguage ctx service modules currentBehavior =
  ScaffoldRecord
    { recSpecPath = T.pack specPath,
      recModuleRoot = moduleRoot ctx,
      recLayout = case placement ctx of GeneratedPrefix -> "prefixed"; CollocatedLeaf -> "collocated",
      recSourceLanguage = sourceLanguage,
      recLanguageContract = checkedLanguageContract service,
      recNamingEdition = currentGeneratedHaskellNamingEdition,
      recModuleRoles = [ScaffoldModuleRoleRow (moduleRole m) (kind m) (modulePath m) | m <- modules],
      recFiles = [(kind m, modulePath m) | m <- modules],
      recMappings = consumerMappings (consumerPlan spec),
      recIdDomains = idDomainIdentitiesForService service,
      recNominalEqualities = nominalEqualityIdentitiesForService service,
      recBindingObligations = either (const []) id (bindingHolesForService service),
      recBehaviorRequirements = currentBehavior,
      recProjectionCatalogFacts = projectionCatalogFacts spec
    }
  where
    spec = checkedSpec service

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
          pure [modulePath m | not (any isGeneratedBannerLine (T.lines contents))]

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

-- | Qualify a refusal set raised after the run's sidecar renames were applied.
--
-- Every refusal message says "nothing was written", which is true of the module
-- tree but not of the renames, so the note is appended rather than the claim
-- being weakened everywhere. A refusal set that is empty stays empty.
withSidecarMovesApplied :: [SidecarMove] -> [Refusal] -> [Refusal]
withSidecarMovesApplied [] refusals = refusals
withSidecarMovesApplied _ [] = []
withSidecarMovesApplied moves refusals = refusals <> [SidecarMovesAlreadyApplied moves]

renderRefusals :: [Refusal] -> [Text]
renderRefusals = concatMap render
  where
    render (PathCollision path origins) =
      [ "error: module path collision -- refusing to scaffold; nothing was written",
        "  " <> T.pack path
      ]
        <> ["    from " <> source | source <- origins]
    render (FirewallBreach breaches) =
      [ "error: firewall breach -- refusing to scaffold; nothing was written",
        "firewall: BREACH (" <> tshow (length breaches) <> " forbidden token occurrence(s)):"
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
    render (ImportCycle path) =
      [ "error: generated/consumer import cycle -- refusing to scaffold; nothing was written",
        "  " <> T.intercalate " -> " path,
        "  keep bindings in a leaf module that imports only Structural.Shape.* and Keiro.Codec.Structural"
      ]
    render (BehaviorRefusal errors) =
      ["error: behavior obligations cannot be derived soundly -- refusing to scaffold; nothing was written"]
        <> ["  " <> T.pack (show behaviorError) | behaviorError <- errors]
    render (GeneratedNameInvariantViolation violations) =
      ["error: generated Haskell name invariant violated -- refusing to scaffold; nothing was written"]
        <> map ("  " <>) violations
    render (NameMigrationRequired moves) =
      [ "error: name migration required: legacy-v1 -> idiomatic-v1; nothing was written",
        "re-run scaffold with --apply-name-migrations after reviewing these source moves:"
      ]
        <> map renderMove moves
    render (NameMigrationRefusal reasons) =
      ["error: name migration could not be applied safely; nothing was written"]
        <> map ("  " <>) reasons
    render (SidecarMigrationRequired moves) =
      [ "error: sidecar migration required; nothing was written",
        "re-run scaffold with --apply-name-migrations after reviewing these sidecar renames:"
      ]
        <> map (("  " <>) . renderSidecarMove) moves
    render (SidecarMigrationRefusal reasons) =
      ["error: sidecar migration could not be applied safely; nothing was written"]
        <> map ("  " <>) reasons
    render (SidecarMovesAlreadyApplied moves) =
      [ "note: this run had already applied "
          <> tshow (length moves)
          <> " sidecar rename(s) before the refusal above, so \"nothing was written\" excludes them:"
      ]
        <> map (("  " <>) . renderSidecarMove) moves
        <> [ "The renames are idempotent and carry no spec content, so re-running scaffold",
             "after fixing the refusal is correct; nothing needs to be undone."
           ]
    render (FoldSurfaceRefusal surfaceError) =
      [ "error: aggregate fold identity could not be resolved -- refusing to scaffold; nothing was written",
        "  " <> renderFoldSurfaceError surfaceError
      ]
    render (SemanticContractMismatch detail) =
      [ "error: semantic language contract mismatch -- refusing to scaffold; nothing was written",
        "  " <> detail
      ]
    render (GoldenRootDivergence root paths) =
      [ "error: golden payload fixtures live beside a workspace member instead of under the workspace golden root -- refusing to scaffold"
      ]
        <> ["  " <> T.pack path | path <- paths]
        <> [ "  move these files under " <> T.pack root <> "; keiro-dsl reads one golden root per workspace",
             "  (a fixture the root lacks would be silently replaced by a synthesized stand-in)",
             "nothing was written"
           ]
    render (DuplicateConformanceFactKeys duplicates) =
      ["error: duplicate normalized service conformance fact keys -- refusing to scaffold; nothing was written"]
        <> ["  " <> duplicateServiceFactKey duplicate | duplicate <- duplicates]
    render (ConformancePackageRefusal failure) = renderConformancePackageFailure failure
    renderMove move =
      "  "
        <> (case moveKind move of Generated -> "generated "; HoleStub -> "hole      ")
        <> moveOldModule move
        <> " -> "
        <> moveNewModule move
        <> "  backup: "
        <> T.pack (moveBackupPath move)

renderScaffoldReport :: ScaffoldReport -> [Text]
renderScaffoldReport report =
  [ "scaffold: " <> T.pack (reportSpecPath report) <> " -> " <> T.pack (reportOutDir report) <> " (module-root=" <> rootLabel <> ", layout=" <> layoutLabel <> ")"
  ]
    <> map moduleLine dispositions
    <> inertNodeSection
    <> [ "firewall: OK (" <> tshow generatedCount <> " generated modules scanned, 0 forbidden operators)",
         harnessLine,
         dependencyLine,
         "fragment: " <> T.pack (reportManifestPath report),
         "ledger:   " <> T.pack (reportRecordPath report)
       ]
    <> previousSpecNote
    <> constraintSection
    <> newHolesSection
    <> mappingDriftSection
    <> sourceLanguageDriftSection
    <> behaviorDriftSection
    <> obsoleteOutputSection
    <> sidecarMoveSection
    <> nameMoveSection
    <> staleSection
    <> maybe [] renderConformancePackageReport (reportConformancePackage report)
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
    dispositionTag Unchanged = "(unchanged)"
    pad name = name <> T.replicate (nameWidth - T.length name) " "
    generatedCount = length [() | (m, _) <- dispositions, kind m == Generated]
    inertNodeSection = renderInertNodeSection (reportInertNodes report)
    harnesses =
      sortOn
        id
        [ moduleNameOf (modulePath m)
        | (m, _) <- dispositions,
          any (`T.isSuffixOf` moduleNameOf (modulePath m)) [".Harness", ".ProcessHarness", ".WorkflowFacts"]
        ]
    harnessLine = case harnesses of
      [] -> "harness:  (none emitted)"
      _ -> "harness:  run `cabal test <your-component>` over " <> T.unwords harnesses
    dependencyLine =
      "dependency plan: consumer packages "
        <> renderBracketed (consumerPackages (reportConsumerPlan report))
        <> ", consumer modules "
        <> renderBracketed (consumerModules (reportConsumerPlan report))
    constraintSection = case reportConstraintPlan report of
      [] -> []
      constraints -> "constraint plan:" : map ("  " <>) constraints
    newHolesSection = case reportNewHoles report of
      [] -> []
      obligations ->
        ["newly required holes since last scaffold: " <> tshow (length obligations)]
          <> concatMap obligationLines obligations
    obligationLines hole =
      [ "  " <> holeModule hole,
        "    " <> holeSignature hole <> " (" <> obligationKindLabel (holeKind hole) <> ")"
      ]
    previousSpecNote = case reportPreviousSpecPath report of
      Just previous
        | previous /= T.pack (reportSpecPath report) ->
            [ "note: the previous scaffold record used spec " <> previous,
              "      specs sharing context " <> contextName ctx <> " in one --out also share " <> T.pack (reportManifestPath report)
            ]
      _ -> []
    mappingDriftSection = case reportMappingDrift report of
      [] -> []
      drifts ->
        ["mapping drift: " <> tshow (length drifts) <> " declaration(s) changed since the previous scaffold:"]
          <> concatMap driftLines drifts
    driftLines drift =
      [ "  " <> driftSpecName drift,
        "    previous: " <> maybe "(absent)" renderMappingIdentity (driftPrevious drift),
        "    current:  " <> maybe "(absent)" renderMappingIdentity (driftCurrent drift)
      ]
    sourceLanguageDriftSection = case reportSourceLanguageDrift report of
      Nothing -> []
      Just drift ->
        [ "source-language drift: "
            <> sourceLanguageLabel (languageDriftPrevious drift)
            <> " -> "
            <> sourceLanguageLabel (languageDriftCurrent drift)
            <> " (generated module bytes are semantic and unaffected)"
        ]
    behaviorDriftSection =
      renderBehaviorRows "new behavior obligations" (reportAddedBehavior report)
        <> renderBehaviorRows "removed behavior obligations (consumer rows become stale)" (reportRemovedBehavior report)
    renderBehaviorRows _ [] = []
    renderBehaviorRows label rows =
      [label <> ": " <> tshow (length rows)] <> concatMap behaviorLines rows
    behaviorLines row =
      [ "  "
          <> behaviorRecordAggregate row
          <> ":"
          <> behaviorRecordSource row
          <> " -- "
          <> behaviorRecordCommand row
          <> "  "
          <> unBehaviorKey (behaviorRecordKey row),
        "    Pending (BehaviorKey " <> tshow (unBehaviorKey (behaviorRecordKey row)) <> ")"
      ]
    obsoleteOutputSection = case reportObsoleteOutputHooks report of
      [] -> []
      hooks ->
        ["obsolete identity-copy output hooks (if still present, they are unused and may be removed):"]
          <> ["  " <> aggregate <> ".Holes." <> hook | (aggregate, hook) <- hooks]
    sidecarMoveSection = case reportSidecarMoves report of
      [] -> []
      moves ->
        ["sidecar migration: applied (" <> tshow (length moves) <> " move(s))"]
          <> map (("  " <>) . renderSidecarMove) moves
    nameMoveSection = case reportNameMoves report of
      [] -> []
      moves ->
        ["name migration: applied (" <> tshow (length moves) <> " source move(s))"]
          <> ["  backup: " <> T.pack (moveBackupPath move) | move <- moves]
    staleSection = case reportStale report of
      [] -> []
      stale ->
        [ "stale: " <> tshow (length stale) <> " file(s) from a previous scaffold of context " <> contextName ctx <> " are no longer produced by this spec:"
        ]
          <> map staleLine stale
          <> ["note: keiro-dsl never deletes files."]
    staleLine stale = case (staleKind stale, staleGeneratedEvidence stale) of
      (Generated, Just ExactGeneratedBannerPresent) ->
        "  generated " <> T.pack (stalePath stale) <> "  (exact generated banner present; verify unchanged bytes before deleting)"
      (Generated, _) ->
        "  generated " <> T.pack (stalePath stale) <> "  (exact generated banner missing; preserve and review)"
      (HoleStub, _) -> "  hole      " <> T.pack (stalePath stale) <> "  (hand-owned — preserve and review)"

sourceLanguageLabel :: SourceLanguage -> Text
sourceLanguageLabel sourceLanguage =
  sourceFormText sourceLanguage
    <> "/effective-v"
    <> languageVersionText (effectiveLanguageVersion sourceLanguage)

obligationKindLabel :: BindingObligationKind -> Text
obligationKindLabel BindingValue = "binding"
obligationKindLabel FixtureValue = "fixtures"
obligationKindLabel InitialValue = "initial-value"

renderBracketed :: [Text] -> Text
renderBracketed values = "[" <> T.intercalate ", " values <> "]"

renderMappingIdentity :: MappingIdentity -> Text
renderMappingIdentity StructuralMapping {mappingPackage, mappingModule, mappingType, mappingBindingSymbol, mappingBindingVersion} =
  "structural "
    <> mappingPackage
    <> ":"
    <> mappingModule
    <> "."
    <> mappingType
    <> " binding="
    <> mappingBindingSymbol
    <> " version="
    <> mappingBindingVersion
renderMappingIdentity OpaqueMapping {mappingPackage, mappingModule, mappingType, mappingCodecIdentity, mappingCodecVersion} =
  "opaque "
    <> mappingPackage
    <> ":"
    <> mappingModule
    <> "."
    <> mappingType
    <> " codec="
    <> mappingCodecIdentity
    <> " version="
    <> mappingCodecVersion
renderMappingIdentity NominalMapping {mappingNominalCategory, mappingNominalRepresentation, mappingPackage, mappingModule, mappingType, mappingBindingSymbol, mappingBindingVersion} =
  "nominal-"
    <> mappingNominalCategory
    <> " "
    <> mappingPackage
    <> ":"
    <> mappingModule
    <> "."
    <> mappingType
    <> " representation="
    <> mappingNominalRepresentation
    <> " binding="
    <> mappingBindingSymbol
    <> " version="
    <> mappingBindingVersion

tshow :: (Show a) => a -> Text
tshow = T.pack . show
