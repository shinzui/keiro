-- | The filesystem-facing scaffold pipeline. It separates pure planning from
-- execution so every refusal is known before the first output byte is written.
module Keiro.Dsl.ScaffoldRun
  ( Refusal (..),
    WriteDisposition (..),
    GeneratedArtifactCategory (..),
    GeneratedArtifactImpact (..),
    GeneratedHaskellEditionImpact (..),
    GeneratedHaskellEditionUse (..),
    PreparedGeneratedHaskellEditionMigration (..),
    StaleGeneratedEvidence (..),
    StaleModule (..),
    MappingDrift (..),
    QueryContractMigration (..),
    SourceLanguageDrift (..),
    ScaffoldReport (..),
    scaffoldServiceModules,
    scaffoldServiceModulesWithGoldens,
    scaffoldModules,
    scaffoldModulesWithGoldens,
    planIndexedServiceScaffold,
    planIndexedServiceScaffoldWithGoldens,
    planIndexedServiceScaffoldWithRuntimePackage,
    planIndexedServiceScaffoldWithRuntimePackageAndGoldens,
    executeServiceScaffold,
    executeServiceScaffoldWithRuntimePackage,
    executeServiceScaffoldWithRuntimePackageAndNameMigrations,
    executeServiceScaffoldWithRuntimePackageAndMigrations,
    executeScaffold,
    executeScaffoldWithLanguage,
    renderRefusals,
    renderScaffoldReport,
    checkedSemanticImpactSnapshot,
    semanticImpactForMappingDrift,
    generatedArtifactImpact,
    renderSemanticImpactReport,
    renderGeneratedArtifactImpact,
    renderRouterSelectionDrift,

    -- * Shared with whole-workspace scaffolding ("Keiro.Dsl.WorkspaceScaffold")

    --
    -- $shared
    planningGatePipeline,
    planningRefusalDiagnostics,
    checkIndexedServiceDiagnostics,
    inertNodesOf,
    renderInertNodeSection,
    withSidecarMovesApplied,
    originLine,
    pureRefusalsForService,
    auditGeneratedHaskell,
    missingGeneratedBanners,
    staleAgainst,
    PreparedSourceMove,
    preparedSourceMove,
    preflightSourceMoves,
    applyPreparedSourceMoves,
    preflightGeneratedHaskellEditionMigration,
    applyPreparedGeneratedHaskellEditionMigration,
    constraintPlanForService,
    mappingDrift,
    behaviorDrift,
    newBindingObligations,
    queryContractMigrations,
    obligationKindLabel,
    renderMappingIdentity,
  )
where

import Data.ByteString qualified as BS
import Data.List (sort, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.BehaviorCoverage (BehaviorDerivationError, BehaviorKey (..), BehaviorRecordRow (..), behaviorRecordRows, deriveBehaviorRequirementsForService)
import Keiro.Dsl.BehaviorCoverage qualified as Behavior
import Keiro.Dsl.BehaviorSourceMap (BehaviorSourceFailure)
import Keiro.Dsl.BehaviorSourceMap qualified as BehaviorSource
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
import Keiro.Dsl.CoordinationImpact (RouterSelectionDrift, renderRouterSelectionDrift, routerSelectionDrift, routerSelectionSnapshots)
import Keiro.Dsl.ExplainBindings (BindingHole (..), BindingObligationKind (..), bindingHolesForService)
import Keiro.Dsl.FoldFingerprint (FoldSurfaceError, aggregateFoldSurfaceForService, renderFoldSurfaceError)
import Keiro.Dsl.GeneratedHaskellLanguage (idiomaticV2LabelMigrations)
import Keiro.Dsl.Goldens (GoldenPayload)
import Keiro.Dsl.Grammar (EmitNode (..), Loc (..), Node (..), OperationNode (..), PgmqDispatchNode (..), Spec (..))
import Keiro.Dsl.Harness (harnessForServiceWithGoldens, harnessProcess, harnessReadModelForService, harnessRouterForService, harnessWorkflow)
import Keiro.Dsl.HaskellName (currentGeneratedHaskellNamingEdition)
import Keiro.Dsl.HaskellName qualified as HaskellName
import Keiro.Dsl.HaskellSourceMove
import Keiro.Dsl.IdDomain (idDomainIdentitiesForService)
import Keiro.Dsl.LanguageVersion (SourceLanguage (..), effectiveLanguageVersion, languageVersionText, sourceFormText)
import Keiro.Dsl.Manifest (moduleNameOf, renderManifestForServiceWithFacade)
import Keiro.Dsl.MappedConsumer (ConsumerPlan (..), MappingIdentity (..), consumerPlanForService)
import Keiro.Dsl.NominalType (nominalEqualityIdentitiesForService)
import Keiro.Dsl.ProjectionMappedImpact (ProjectionMappedImpact, projectionMappedImpactForService, renderProjectionMappedImpact)
import Keiro.Dsl.ReadModelQueryContract
import Keiro.Dsl.RuntimePackage (RuntimePackageName)
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRecord (ScaffoldModuleRoleRow (..), ScaffoldRecord (..), parseRecord, projectionCatalogFactsForService, recordFileName, renderRecord)
import Keiro.Dsl.SemanticContract (CheckedService, checkedLanguageContract, checkedService, checkedSpec, checkedTypeGraph, effectiveLanguageContract, legacyCheckedService)
import Keiro.Dsl.SemanticImpact
  ( MappedImpactDelta (..),
    MappedRootEvidence (..),
    SemanticImpactReport (..),
    SemanticImpactSnapshot (..),
    diffSemanticImpact,
    mappedConsequenceIdentity,
    mappedConsumerIdentity,
    mappedRootKindIdentity,
    semanticImpactForService,
    semanticImpactReport,
    semanticImpactSnapshot,
  )
import Keiro.Dsl.ServiceHarness (DuplicateServiceFactKey (..), serviceConformanceModuleName, serviceHarnessModule)
import Keiro.Dsl.SidecarMigration
import Keiro.Dsl.SidecarNames (contextCabalFragmentFileName)
import Keiro.Dsl.Source (SourcePoint (..), SourceSpan (..))
import Keiro.Dsl.SourceIndex (SemanticSourceIndex)
import Keiro.Dsl.StructuralConformance (structuralConformanceModule)
import Keiro.Dsl.TypeGraph (MappedKey (..), TypeGraph (..), UseSite (..))
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode (..), Severity (..), validateService)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
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
  | BehaviorSourceRefusal ![BehaviorSourceFailure]
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
  | GeneratedHaskellEditionRequired !GeneratedHaskellEditionImpact
  | GeneratedHaskellEditionRefusal ![Text]
  | -- | Not a refusal on its own: an accompanying note that the run had already
    --       applied its sidecar renames before a later gate refused. Every other
    --       refusal says "nothing was written", which without this note is false.
    --       The renames are idempotent and forward-consistent, so re-running after
    --       fixing the refusal is correct and needs no undo.
    SidecarMovesAlreadyApplied ![SidecarMove]
  deriving stock (Eq, Show)

data GeneratedHaskellEditionUse = GeneratedHaskellEditionUse
  { path :: !FilePath,
    line :: !Int,
    current :: !Text,
    replacement :: !Text
  }
  deriving stock (Eq, Ord, Show)

data GeneratedHaskellEditionImpact = GeneratedHaskellEditionImpact
  { generatedPaths :: ![FilePath],
    sidecarPaths :: ![FilePath],
    handOwnedUses :: ![GeneratedHaskellEditionUse]
  }
  deriving stock (Eq, Show)

data PreparedGeneratedHaskellEditionMigration = PreparedGeneratedHaskellEditionMigration
  { impact :: !GeneratedHaskellEditionImpact,
    backups :: ![(FilePath, FilePath)],
    reportPath :: !FilePath,
    reportText :: !Text
  }
  deriving stock (Eq, Show)

-- | What one module write did. 'Unchanged' means an existing Generated module
-- already had identical bytes, or is reported by the workspace write path under
-- the same rule.
data WriteDisposition = Overwritten | Created | Skipped | Unchanged
  deriving stock (Eq, Show)

data GeneratedArtifactCategory
  = AggregateGeneratedArtifact
  | ServiceStructuralConformanceArtifact
  | BehaviorSourceMapArtifact
  | OtherGeneratedArtifact
  deriving stock (Eq, Ord, Show)

data GeneratedArtifactImpact = GeneratedArtifactImpact
  { category :: !GeneratedArtifactCategory,
    role :: !ModuleRole,
    path :: !FilePath,
    disposition :: !WriteDisposition
  }
  deriving stock (Eq, Show)

data StaleGeneratedEvidence
  = ExactGeneratedBannerPresent
  | ExactGeneratedBannerMissing
  deriving stock (Eq, Show)

data StaleModule = StaleModule
  { kind :: !ModuleKind,
    path :: !FilePath,
    generatedEvidence :: !(Maybe StaleGeneratedEvidence)
  }
  deriving stock (Eq, Show)

data MappingDrift = MappingDrift
  { specName :: !Text,
    previous :: !(Maybe MappingIdentity),
    current :: !(Maybe MappingIdentity)
  }
  deriving stock (Eq, Show)

data SourceLanguageDrift = SourceLanguageDrift
  { previous :: !SourceLanguage,
    current :: !SourceLanguage
  }
  deriving stock (Eq, Show)

data ScaffoldReport = ScaffoldReport
  { specPath :: !FilePath,
    outDir :: !FilePath,
    context :: !Context,
    dispositions :: ![(ScaffoldModule, WriteDisposition)],
    inertNodes :: ![(Text, Text)],
    manifestPath :: !FilePath,
    recordPath :: !FilePath,
    previousSpecPath :: !(Maybe Text),
    stale :: ![StaleModule],
    consumerPlan :: !ConsumerPlan,
    constraintPlan :: ![Text],
    mappingDrift :: ![MappingDrift],
    queryContractBaselineUnavailable :: !Bool,
    queryContractDrift :: ![QueryContractDrift],
    queryContractMigrations :: ![QueryContractMigration],
    semanticImpact :: !SemanticImpactReport,
    routerSelectionDrift :: ![RouterSelectionDrift],
    projectionMappedImpact :: !(Maybe ProjectionMappedImpact),
    generatedArtifactImpact :: ![GeneratedArtifactImpact],
    sourceLanguageDrift :: !(Maybe SourceLanguageDrift),
    newHoles :: ![BindingHole],
    addedBehavior :: ![BehaviorRecordRow],
    removedBehavior :: ![BehaviorRecordRow],
    obsoleteOutputHooks :: ![(Text, Text)],
    conformancePackage :: !(Maybe ConformancePackageReport),
    nameMoves :: ![SourceMove],
    sidecarMoves :: ![SidecarMove]
  }
  deriving stock (Eq, Show)

data QueryContractMigration = QueryContractMigration
  { owner :: !Text,
    path :: !FilePath,
    requiredImport :: !Text
  }
  deriving stock (Eq, Show)

-- | Produce the complete in-memory module set under a checked semantic
-- contract. Keeping this registry in one place prevents the CLI and tests from
-- drifting apart.
scaffoldServiceModules :: Context -> CheckedService -> [ScaffoldModule]
scaffoldServiceModules = scaffoldServiceModulesWithGoldens []

scaffoldServiceModulesWithGoldens :: [GoldenPayload] -> Context -> CheckedService -> [ScaffoldModule]
scaffoldServiceModulesWithGoldens goldens = scaffoldServiceModulesWithBehaviorSource goldens []

scaffoldServiceModulesWithBehaviorSource :: [GoldenPayload] -> [BehaviorSource.BehaviorSourceEntry] -> Context -> CheckedService -> [ScaffoldModule]
scaffoldServiceModulesWithBehaviorSource goldens sourceEntries ctx service =
  map modernizeScaffoldModule $
    structuralConformanceModules ctx service
      <> maybe [] pure (behaviorSourceMapModule ctx sourceEntries)
      <> scaffoldStructuralForService ctx service
      <> scaffoldReplayAudit ctx spec
      <> scaffoldProjectionCatalogForService ctx service
      <> concat
        [ case node of
            NAggregate agg -> scaffoldAggregateForService ctx service agg <> harnessForServiceWithGoldens goldens ctx service agg
            NProcess process -> scaffoldProcess ctx process <> harnessProcess ctx process
            NRouter router -> scaffoldRouterForService ctx service router <> harnessRouterForService ctx service router
            NContract contract -> scaffoldContractForService ctx service contract
            NIntake intake -> scaffoldIntake ctx intake
            NPublisher publisher -> scaffoldPublisher ctx publisher
            NWorkqueue workqueue -> scaffoldWorkqueueForService ctx service workqueue
            NReadModel readModel ->
              let resolved = resolveCatalogReadModel spec readModel
               in scaffoldReadModelForService ctx service resolved <> harnessReadModelForService ctx service resolved
            NProjectionTarget _ -> []
            NRebuildGroup _ -> []
            NProjectionRevision _ -> []
            NExternalRead _ -> []
            NProjectionOwner _ -> []
            NWorkflow workflow -> harnessWorkflow ctx workflow
            NEmit _ -> []
            NPgmqDispatch _ -> []
            NOperation _ -> []
        | node <- (.nodes) spec
        ]
  where
    spec = checkedSpec service

structuralConformanceModules :: Context -> CheckedService -> [ScaffoldModule]
structuralConformanceModules ctx service = case structuralConformanceModule ctx service of
  Left failures -> error ("checked structural conformance planning failed: " <> show failures)
  Right Nothing -> []
  Right (Just moduleValue) -> [moduleValue]

-- | Compatibility wrapper that explicitly selects legacy/version-1 semantics.
scaffoldModules :: Context -> Spec -> [ScaffoldModule]
scaffoldModules = scaffoldModulesWithGoldens []

scaffoldModulesWithGoldens :: [GoldenPayload] -> Context -> Spec -> [ScaffoldModule]
scaffoldModulesWithGoldens goldens ctx = scaffoldServiceModulesWithGoldens goldens ctx . legacyCheckedService

-- | Run every pure refusal gate under the effective semantic contract. A
-- successful result is the exact write set; a refusal has no write set and
-- therefore cannot be accidentally executed.
planIndexedServiceScaffold :: SemanticSourceIndex -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planIndexedServiceScaffold = planIndexedServiceScaffoldWithRuntimePackage Nothing

planIndexedServiceScaffoldWithGoldens :: [GoldenPayload] -> SemanticSourceIndex -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planIndexedServiceScaffoldWithGoldens goldens = planIndexedServiceScaffoldWithRuntimePackageAndGoldens goldens Nothing

-- | Add the one service-level conformance facade only when the runtime package
-- is explicitly configured. The package name itself is build metadata; facade
-- naming depends solely on the service context and placement policy.
planIndexedServiceScaffoldWithRuntimePackage :: Maybe RuntimePackageName -> SemanticSourceIndex -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planIndexedServiceScaffoldWithRuntimePackage = planIndexedServiceScaffoldWithRuntimePackageAndGoldens []

planIndexedServiceScaffoldWithRuntimePackageAndGoldens :: [GoldenPayload] -> Maybe RuntimePackageName -> SemanticSourceIndex -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planIndexedServiceScaffoldWithRuntimePackageAndGoldens goldens runtimePackage sourceIndex ctx service = do
  -- Preserve the established refusal precedence. Structural/path/import and
  -- behavior-derivation defects are decidable without exact provenance and
  -- must not be hidden by a later source-anchor join failure.
  _ <- planningGatePipeline ctx service baseModulePlan (Right ())
  planningGatePipeline ctx service completeModulePlan (Right ())
  where
    facadeModules = case runtimePackage of
      Nothing -> Right []
      Just _ -> fmap pure (serviceHarnessModule ctx service)
    baseModulePlan = case facadeModules of
      Left duplicates -> Left [DuplicateConformanceFactKeys duplicates]
      Right facades ->
        Right $
          stampGeneratedModules
            (checkedLanguageContract service)
            (scaffoldServiceModulesWithGoldens goldens ctx service <> facades)
    completeModulePlan =
      case (behaviorSourcePlan, facadeModules) of
        (Left refusals, _) -> Left refusals
        (_, Left duplicates) -> Left [DuplicateConformanceFactKeys duplicates]
        (Right sourceEntries, Right facades) ->
          Right $
            stampGeneratedModules
              (checkedLanguageContract service)
              (scaffoldServiceModulesWithBehaviorSource goldens sourceEntries ctx service <> facades)
    behaviorSourcePlan = do
      requirements <- either (Left . pure . BehaviorRefusal) Right (deriveBehaviorRequirementsForService service)
      either (Left . pure . BehaviorSourceRefusal) Right (BehaviorSource.planBehaviorSourceMap requirements sourceIndex)

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
  case traverse (aggregateFoldSurfaceForService service) [aggregate | NAggregate aggregate <- (.nodes) spec] of
    Left surfaceError -> Left [FoldSurfaceRefusal surfaceError]
    Right _ -> case scaffoldRefusalsForService service of
      lowering@(_ : _) -> Left [LoweringRefusal lowering]
      [] -> case modulePlan of
        Left refusals -> Left refusals
        Right modules -> case packagePlan of
          Left refusals -> Left refusals
          Right () -> case pureRefusalsForService ctx service modules of
            [] -> Right modules
            refusals -> Left refusals
  where
    spec = checkedSpec service

-- | The nodes a spec declares that contribute no generated module.
--
-- They are still parsed, validated, and diff-classified; naming them in the
-- scaffold report is what stops an author from concluding the toolchain lost
-- their declaration. Shared by the single-spec and workspace planners so a
-- workspace — the recommended layout — reports exactly what one spec reports.
inertNodesOf :: Spec -> [(Text, Text)]
inertNodesOf spec =
  [ (kindLabel, nodeName)
  | node <- (.nodes) spec,
    (kindLabel, nodeName) <- case node of
      NEmit emitNode -> [("emit", (.name) emitNode)]
      NPgmqDispatch dispatchNode -> [("dispatch", (.name) dispatchNode)]
      NOperation operationNode -> [("operation", (.name) operationNode)]
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

-- | Validate a checked service, then run the shared planning gates unless an
-- error makes module generation unsound. 'GeneratedOccurrenceCollision' is the
-- deliberate exception: the workspace path already plans through it so the
-- stronger whole-path collision can cite every claimant. Existing diagnostics
-- retain their order and planning diagnostics follow them.
checkIndexedServiceDiagnostics :: Maybe RuntimePackageName -> SemanticSourceIndex -> Context -> CheckedService -> [Diagnostic]
checkIndexedServiceDiagnostics runtimePackage sourceIndex ctx service
  | any blocksPlanning validationDiagnostics = validationDiagnostics
  | otherwise =
      validationDiagnostics
        <> case planIndexedServiceScaffoldWithRuntimePackage runtimePackage sourceIndex ctx service of
          Right _ -> []
          Left refusals -> planningRefusalDiagnostics refusals
  where
    validationDiagnostics = validateService service
    blocksPlanning diagnostic =
      (.severity) diagnostic == Error
        && (.code) diagnostic /= GeneratedOccurrenceCollision

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
    diagnosticsFor (BehaviorSourceRefusal failures) =
      [ planningError (behaviorSourceFailureLine failure) (behaviorSourceDiagnosticCode failure) $
          "behavior source map cannot be planned for "
            <> Behavior.unBehaviorKey ((.key) failure)
            <> " ("
            <> (.aggregate) failure
            <> ":"
            <> (.state) failure
            <> " -- "
            <> (.command) failure
            <> ", subject="
            <> T.pack (show ((.sourceSubject) failure))
            <> "): "
            <> (.message) failure
      | failure <- failures
      ]
    diagnosticsFor (DuplicateConformanceFactKeys duplicates) =
      [ planningError 1 ConformanceFactKeyCollision $
          "normalized service conformance fact key '"
            <> (.duplicateServiceFactKey) duplicate
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

    behaviorErrorLine (Behavior.DuplicateBehaviorIdentity _ locations) = maximum (1 : map (.unLoc) locations)
    behaviorErrorLine _ = 1

    behaviorSourceFailureLine failure = case (.span) failure of
      Just SourceSpan {start = SourcePoint {line = sourceLine}} -> sourceLine
      Nothing -> 1
    behaviorSourceDiagnosticCode failure = case (.code) failure of
      BehaviorSource.BehaviorSourceAnchorMissing -> BehaviorSourceAnchorMissing
      BehaviorSource.BehaviorSourceAnchorInexact -> BehaviorSourceAnchorInexact
      BehaviorSource.BehaviorSourceAnchorCollision -> BehaviorSourceAnchorCollision

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

-- | Every pure refusal gate, over an already-built module set: case-folded path
-- collisions, generated\/consumer collisions and import cycles, firewall breaches,
-- and lowering refusals. Whole-workspace planning builds its module set from the
-- merged spec and then runs exactly this, so no gate can apply to one input shape
-- and not the other.
pureRefusalsForService :: Context -> CheckedService -> [ScaffoldModule] -> [Refusal]
pureRefusalsForService ctx service modules =
  collisionRefusals modules
    <> dependencyRefusalsForService ctx service modules
    <> [FirewallBreach breaches | not (null breaches)]
    <> [GeneratedNameInvariantViolation namingViolations | not (null namingViolations)]
    <> [LoweringRefusal lowering | let lowering = scaffoldRefusalsForService service, not (null lowering)]
    <> [BehaviorRefusal errors | Left errors <- [deriveBehaviorRequirementsForService service]]
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
    expectedModule = moduleNameOf ((.path) scaffoldModule)
    (lexicalErrors, codeSource) = case maskNonCode ((.text) scaffoldModule) of
      Left message -> ([prefix 1 <> message], "")
      Right masked -> ([], masked)
    sourceLines = zip [1 :: Int ..] (T.lines codeSource)
    declarationErrors = moduleDeclarationErrors <> moduleSegmentErrors
    moduleDeclarationErrors = case declaredModuleName codeSource of
      Nothing -> [T.pack ((.path) scaffoldModule) <> ": missing Haskell module declaration"]
      Just declared
        | declared == expectedModule -> []
        | otherwise ->
            [ T.pack ((.path) scaffoldModule)
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

    prefix lineNumber = T.pack ((.path) scaffoldModule) <> ":" <> tshow lineNumber <> ": "

    auditSite kind candidate lineNumber =
      HaskellName.NameSite
        { HaskellName.kind = kind,
          HaskellName.logicalName = candidate,
          HaskellName.owner = T.pack ((.path) scaffoldModule),
          HaskellName.line = lineNumber
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

dependencyRefusalsForService :: Context -> CheckedService -> [ScaffoldModule] -> [Refusal]
dependencyRefusalsForService ctx service modules = collisionWithConsumers <> namespaceCycles
  where
    plan = consumerPlanForService service
    generatedByName = Map.fromList [(moduleNameOf ((.path) moduleValue), moduleValue) | moduleValue <- modules, (.kind) moduleValue == Generated]
    collisionWithConsumers =
      [ PathCollision
          ((.path) generated)
          [(.origin) generated, "consumer module " <> consumerModule]
      | consumerModule <- (.modules) plan,
        Just generated <- [Map.lookup consumerModule generatedByName]
      ]
    namespaceCycles =
      [ ImportCycle [importer, consumerModule, importer]
      | consumerModule <- (.modules) plan,
        generatedNamespaceOwned ctx consumerModule,
        importer <- take 1 (importersOf consumerModule modules <> [contextGeneratedRoot ctx])
      ]

generatedNamespaceOwned :: Context -> Text -> Bool
generatedNamespaceOwned ctx consumerModule = case (.placement) ctx of
  GeneratedPrefix -> contextGeneratedRoot ctx `T.isPrefixOf` consumerModule
  CollocatedLeaf ->
    (root <> contextSegment <> ".") `T.isPrefixOf` consumerModule
      && ".Generated" `T.isInfixOf` consumerModule
  where
    root = if T.null ((.moduleRoot) ctx) then "" else (.moduleRoot) ctx <> "."
    contextSegment = pascalFromKebab ((.name) ctx)

contextGeneratedRoot :: Context -> Text
contextGeneratedRoot ctx = case (.placement) ctx of
  GeneratedPrefix -> root <> "Generated." <> contextSegment
  CollocatedLeaf -> root <> contextSegment <> ".Generated"
  where
    root = if T.null ((.moduleRoot) ctx) then "" else (.moduleRoot) ctx <> "."
    contextSegment = pascalFromKebab ((.name) ctx)

importersOf :: Text -> [ScaffoldModule] -> [Text]
importersOf imported =
  map (moduleNameOf . (.path))
    . filter (any (importsModule imported) . T.lines . (.text))

importsModule :: Text -> Text -> Bool
importsModule expected line = case T.words (T.strip line) of
  "import" : rest -> expected `elem` rest
  _ -> False

collisionRefusals :: [ScaffoldModule] -> [Refusal]
collisionRefusals modules =
  [ PathCollision ((.path) first) (map (.origin) (first : rest))
  | first : rest <- Map.elems grouped,
    not (null rest)
  ]
  where
    grouped =
      Map.fromListWith
        (flip (<>))
        [(T.toCaseFold (T.pack ((.path) m)), [m]) | m <- modules]

generatedHaskellEditionBackupRoot :: FilePath
generatedHaskellEditionBackupRoot = ".keiro-dsl-generated-haskell-migrations" </> "idiomatic-v1-to-idiomatic-v2"

preflightGeneratedHaskellEditionMigration :: FilePath -> Maybe HaskellName.GeneratedHaskellNamingEdition -> [(ModuleKind, FilePath)] -> [FilePath] -> IO (Either [Text] (Maybe PreparedGeneratedHaskellEditionMigration))
preflightGeneratedHaskellEditionMigration out previousEdition recordedFiles sidecars
  | previousEdition /= Just HaskellName.IdiomaticNamingV1 = pure (Right Nothing)
  | otherwise = do
      let generatedPaths = sort [path | (Generated, path) <- recordedFiles]
          handOwnedPaths = sort [path | (HoleStub, path) <- recordedFiles]
          sidecarPaths = sort sidecars
          sourcePaths = generatedPaths <> sidecarPaths
      existingSources <- fmap (map fst . filter snd) (mapM existing sourcePaths)
      let labels = map fst idiomaticV2LabelMigrations
      uses <- fmap (sort . concat) (mapM (scanFile labels) handOwnedPaths)
      let impact = GeneratedHaskellEditionImpact generatedPaths sidecarPaths uses
          backups = [(path, generatedHaskellEditionBackupRoot </> path) | path <- existingSources]
          reportPath = generatedHaskellEditionBackupRoot </> "remediation-report.txt"
          reportText = renderGeneratedHaskellEditionRemediation impact
      conflicts <- fmap concat (mapM checkBackup backups)
      reportConflicts <- checkReport reportPath reportText
      pure $
        if null (conflicts <> reportConflicts)
          then Right (Just (PreparedGeneratedHaskellEditionMigration impact backups reportPath reportText))
          else Left (conflicts <> reportConflicts)
  where
    relative path = out </> path
    existing path = do
      exists <- doesFileExist (relative path)
      pure (path, exists)
    checkBackup (sourcePath, backupPath) = do
      exists <- doesFileExist (relative backupPath)
      if not exists
        then pure []
        else do
          sourceBytes <- BS.readFile (relative sourcePath)
          backupBytes <- BS.readFile (relative backupPath)
          pure ["edition backup conflict for " <> T.pack sourcePath <> ": " <> T.pack backupPath <> " contains different bytes" | sourceBytes /= backupBytes]
    checkReport path expected = do
      exists <- doesFileExist (relative path)
      if not exists
        then pure []
        else do
          actual <- TIO.readFile (relative path)
          pure ["edition remediation report conflict: " <> T.pack path <> " contains different bytes" | actual /= expected]
    scanFile labels path = do
      exists <- doesFileExist (relative path)
      if not exists
        then pure []
        else do
          contents <- TIO.readFile (relative path)
          pure
            [ GeneratedHaskellEditionUse path lineNumber label (replacementFor label)
            | (lineNumber, sourceLine) <- zip [1 ..] (T.lines contents),
              label <- labels,
              selectorApplication label sourceLine
            ]
    replacementFor label = case lookup label idiomaticV2LabelMigrations of
      Just target -> "record." <> target <> " (or a positional constructor pattern for dual-edition code)"
      Nothing -> "record." <> label

applyPreparedGeneratedHaskellEditionMigration :: FilePath -> Maybe PreparedGeneratedHaskellEditionMigration -> IO ()
applyPreparedGeneratedHaskellEditionMigration _ Nothing = pure ()
applyPreparedGeneratedHaskellEditionMigration out (Just prepared) = do
  mapM_ copyBackup ((.backups) prepared)
  let reportPath = out </> (.reportPath) prepared
  createDirectoryIfMissing True (takeDirectory reportPath)
  reportExists <- doesFileExist reportPath
  if reportExists then pure () else TIO.writeFile reportPath ((.reportText) prepared)
  where
    copyBackup (sourcePath, backupPath) = do
      let source = out </> sourcePath
          backup = out </> backupPath
      backupExists <- doesFileExist backup
      if backupExists
        then pure ()
        else do
          createDirectoryIfMissing True (takeDirectory backup)
          copyFile source backup

renderGeneratedHaskellEditionRemediation :: GeneratedHaskellEditionImpact -> Text
renderGeneratedHaskellEditionRemediation impact =
  T.unlines $
    [ "keiro-dsl generated Haskell edition migration",
      "from: idiomatic-v1",
      "to: idiomatic-v2",
      "generated-files: " <> tshow (length ((.generatedPaths) impact)),
      "sidecars: " <> tshow (length ((.sidecarPaths) impact)),
      "hand-owned-selector-uses: " <> tshow (length ((.handOwnedUses) impact))
    ]
      <> map renderUse ((.handOwnedUses) impact)
  where
    renderUse use = T.pack ((.path) use) <> ":" <> tshow ((.line) use) <> ": " <> (.current) use <> " -> " <> (.replacement) use

selectorApplication :: Text -> Text -> Bool
selectorApplication label = go Nothing
  where
    go _ remaining | T.null remaining = False
    go previous remaining = case T.breakOn label remaining of
      (_, suffix) | T.null suffix -> False
      (prefix, suffix) ->
        let before = if T.null prefix then previous else Just (T.last prefix)
            after = T.drop (T.length label) suffix
            next = T.dropWhile (== ' ') after
            leftBoundary = maybe True (not . isHaskellIdentifier) before
            rightBoundary = maybe True (not . isHaskellIdentifier) (fst <$> T.uncons after)
            application = maybe False (\character -> character == '(' || isHaskellIdentifier character) (fst <$> T.uncons next)
         in (leftBoundary && rightBoundary && before /= Just '.' && application)
              || go (Just (T.head suffix)) (T.drop 1 suffix)
    isHaskellIdentifier character = character == '_' || character == '\'' || character >= 'A' && character <= 'Z' || character >= 'a' && character <= 'z' || character >= '0' && character <= '9'

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
executeServiceScaffoldWithRuntimePackageAndNameMigrations runtimePackage applyNameMigrations =
  executeServiceScaffoldWithRuntimePackageAndMigrations runtimePackage applyNameMigrations False

executeServiceScaffoldWithRuntimePackageAndMigrations :: Maybe RuntimePackageName -> Bool -> Bool -> FilePath -> Bool -> FilePath -> SourceLanguage -> Context -> CheckedService -> [ScaffoldModule] -> IO (Either [Refusal] ScaffoldReport)
executeServiceScaffoldWithRuntimePackageAndMigrations runtimePackage applyNameMigrations applyGeneratedHaskellEdition out forceGeneratedOverwrite specPath sourceLanguage ctx service plannedModules
  | effectiveLanguageContract sourceLanguage /= checkedLanguageContract service =
      pure (Left [SemanticContractMismatch "source provenance and checked service selected different effective language contracts"])
  | otherwise = case packagePlan of
      Left failures -> pure (Left (map ConformancePackageRefusal failures))
      Right plannedPackage -> do
        let recordPath = out </> recordFileName ((.context) spec)
        previousRecord <- readRecord recordPath
        editionPreflight <-
          preflightGeneratedHaskellEditionMigration
            out
            ((.namingEdition) <$> previousRecord)
            (maybe [] (.files) previousRecord)
            [contextCabalFragmentFileName ((.context) spec), recordFileName ((.context) spec)]
        case editionPreflight of
          Left reasons -> pure (Left [GeneratedHaskellEditionRefusal reasons])
          Right preparedEdition
            | Just prepared <- preparedEdition,
              not applyGeneratedHaskellEdition ->
                pure (Left [GeneratedHaskellEditionRequired ((.impact) prepared)])
            | otherwise -> do
                sidecarResult <- planSidecarMigrations out (ContextSidecars ((.context) spec)) plannedPackage
                case sidecarResult of
                  Left reasons -> pure (Left [SidecarMigrationRefusal reasons])
                  Right preparedSidecars
                    | Just _ <- preparedEdition,
                      not (null preparedSidecars) ->
                        pure (Left [SidecarMigrationRequired (map (.sidecarMove) preparedSidecars)])
                    | not (null preparedSidecars) && not applyNameMigrations ->
                        pure (Left [SidecarMigrationRequired (map (.sidecarMove) preparedSidecars)])
                    | otherwise -> do
                        applyPreparedSidecarMoves out preparedSidecars
                        let moves = map (.sidecarMove) preparedSidecars
                            -- Past this point the renames are on disk, so a later
                            -- refusal's "nothing was written" needs qualifying.
                            noteApplied = withSidecarMovesApplied moves
                        result <- case plannedPackage of
                          Nothing -> executeCheckedScaffold preparedEdition moves Nothing
                          Just package -> do
                            preparedPackage <- preflightConformancePackage out forceGeneratedOverwrite package
                            case preparedPackage of
                              Left failures -> pure (Left (map ConformancePackageRefusal failures))
                              Right packageReady -> executeCheckedScaffold preparedEdition moves (Just packageReady)
                        pure (either (Left . noteApplied) Right result)
  where
    spec = checkedSpec service
    modules = stampGeneratedModules (checkedLanguageContract service) plannedModules
    facadeModule = case runtimePackage of
      Nothing -> Nothing
      Just _ -> Just (serviceConformanceModuleName ctx)
    packagePlan =
      traverse
        (\packageName -> planConformancePackage (StandaloneConformanceService ((.name) ctx)) packageName (serviceConformanceModuleName ctx) service)
        runtimePackage
    executeCheckedScaffold editionMigration sidecarMoves preparedPackage =
      case deriveBehaviorRequirementsForService service of
        Left errors -> pure (Left [BehaviorRefusal errors])
        Right requirements -> do
          bannerless <- if forceGeneratedOverwrite then pure [] else missingGeneratedBanners out modules
          if not (null bannerless)
            then pure (Left [MissingGeneratedBanner bannerless])
            else do
              let recordPath = out </> recordFileName ((.context) spec)
              previousRecord <- readRecord recordPath
              case planRecordedSourceMoves previousRecord modules of
                Left moveErrors -> pure (Left [NameMigrationRefusal [T.pack (show moveError) | moveError <- NE.toList moveErrors]])
                Right moves -> do
                  preparedMoves <- preflightSourceMoves out moves
                  case preparedMoves of
                    Left moveErrors -> pure (Left [NameMigrationRefusal moveErrors])
                    Right prepared
                      | Just _ <- editionMigration,
                        not (null prepared) ->
                          pure (Left [NameMigrationRequired (map preparedSourceMove prepared)])
                      | not (null prepared) && not applyNameMigrations ->
                          pure (Left [NameMigrationRequired (map preparedSourceMove prepared)])
                      | otherwise -> do
                          applyPreparedGeneratedHaskellEditionMigration out editionMigration
                          applyPreparedSourceMoves out prepared
                          stale <- maybe (pure []) (existingStale out modules) previousRecord
                          queryMigrations <- queryContractMigrations out modules
                          let currentConsumerPlan = consumerPlanForService service
                              drift = maybe [] (mappingDrift ((.mappings) currentConsumerPlan) . (.mappings)) previousRecord
                              currentQueryContracts = either (const []) id (queryContractIdentitiesForService service)
                              queryHistoryBaseline =
                                not (null currentQueryContracts)
                                  || maybe False (.queryContractBaseline) previousRecord
                              queryBaselineUnavailable =
                                not (null currentQueryContracts)
                                  && maybe False (not . (.queryContractBaseline)) previousRecord
                              queryDrift = case previousRecord of
                                Just previous | (.queryContractBaseline) previous -> queryContractDrift currentQueryContracts ((.queryContracts) previous)
                                _ -> []
                              currentSemanticImpact = checkedSemanticImpactSnapshot service
                              semanticReport = semanticImpactForMappingDrift (previousRecord >>= (.semanticImpact)) currentSemanticImpact drift
                              currentRouterSelections = routerSelectionSnapshots service
                              selectionDrift = maybe [] (\previous -> routerSelectionDrift ((.routerSelections) previous) currentRouterSelections) previousRecord
                              languageDrift = do
                                previous <- previousRecord
                                if (.sourceLanguage) previous == sourceLanguage
                                  then Nothing
                                  else Just (SourceLanguageDrift ((.sourceLanguage) previous) sourceLanguage)
                              currentObligations = either (const []) id (bindingHolesForService service)
                              newHoles = maybe [] (newBindingObligations currentObligations . (.bindingObligations)) previousRecord
                              currentBehavior = behaviorRecordRows requirements
                              (addedBehavior, removedBehavior) = maybe (currentBehavior, []) (behaviorDrift currentBehavior . (.behaviorRequirements)) previousRecord
                          createDirectoryIfMissing True out
                          dispositions <- mapM (writeModule out) modules
                          let manifestPath = out </> contextCabalFragmentFileName ((.context) spec)
                          TIO.writeFile manifestPath (renderManifestForServiceWithFacade facadeModule (T.pack specPath) modules service)
                          TIO.writeFile recordPath (renderRecord (currentRecord specPath sourceLanguage ctx service modules queryHistoryBaseline currentBehavior currentSemanticImpact))
                          packageReport <- traverse executePreparedConformancePackage preparedPackage
                          pure $
                            Right
                              ScaffoldReport
                                { specPath = specPath,
                                  outDir = out,
                                  context = ctx,
                                  dispositions = dispositions,
                                  inertNodes = inertNodesOf spec,
                                  manifestPath = manifestPath,
                                  recordPath = recordPath,
                                  previousSpecPath = (.specPath) <$> previousRecord,
                                  stale = stale,
                                  consumerPlan = currentConsumerPlan,
                                  constraintPlan = constraintPlanForService service currentConsumerPlan,
                                  mappingDrift = drift,
                                  queryContractBaselineUnavailable = queryBaselineUnavailable,
                                  queryContractDrift = queryDrift,
                                  queryContractMigrations = queryMigrations,
                                  semanticImpact = semanticReport,
                                  routerSelectionDrift = selectionDrift,
                                  projectionMappedImpact = projectionMappedImpactForService service,
                                  generatedArtifactImpact = generatedArtifactImpact dispositions,
                                  sourceLanguageDrift = languageDrift,
                                  newHoles = newHoles,
                                  addedBehavior = addedBehavior,
                                  removedBehavior = removedBehavior,
                                  obsoleteOutputHooks = obsoleteGeneratedOutputHooksForService service,
                                  conformancePackage = packageReport,
                                  nameMoves = map preparedSourceMove prepared,
                                  sidecarMoves = sidecarMoves
                                }

planRecordedSourceMoves :: Maybe ScaffoldRecord -> [ScaffoldModule] -> Either (NE.NonEmpty SourceMoveError) [SourceMove]
planRecordedSourceMoves Nothing _ = Right []
planRecordedSourceMoves (Just previous) current =
  planSourceMoves priorArtifacts current
  where
    priorArtifacts = case (.moduleRoles) previous of
      [] -> [(Nothing, fileKind, path) | (fileKind, path) <- (.files) previous]
      rows -> [(Just ((.role) row), (.kind) row, (.path) row) | row <- rows]

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
    replacements = Map.fromList [((.oldModule) move, (.newModule) move) | move <- moves]
    preflight move = do
      let oldPath = out </> (.oldPath) move
          newPath = out </> (.newPath) move
          backupPath = out </> (.backupPath) move
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
            else pure (Left (T.pack ((.oldPath) move) <> ": recorded legacy source is missing"))
        _ -> do
          source <- TIO.readFile (if oldExists then oldPath else backupPath)
          if (.kind) move == Generated && not (any isGeneratedBannerLine (T.lines source))
            then pure (Left (T.pack ((.oldPath) move) <> ": generated source lacks an exact generated banner"))
            else case rewriteHaskellModuleReferences replacements source of
              Left lexicalError -> pure (Left (T.pack ((.oldPath) move) <> ": " <> T.pack (show lexicalError)))
              Right rewritten
                | not (declaresExpectedModule ((.newModule) move) rewritten) ->
                    pure
                      ( Left
                          ( T.pack ((.oldPath) move)
                              <> ": transformed source does not declare expected module "
                              <> (.newModule) move
                          )
                      )
                | otherwise -> do
                    let hydrated =
                          SourceMove
                            { role = move.role,
                              kind = move.kind,
                              oldModule = move.oldModule,
                              newModule = move.newModule,
                              oldPath = move.oldPath,
                              newPath = move.newPath,
                              backupPath = move.backupPath,
                              contentDigest = Just (contentDigest source),
                              transformedDigest = Just (contentDigest rewritten)
                            }
                        expectedState = renderSourceMoveState hydrated
                    stateError <- verifyOptionalText stateExists statePath expectedState "migration state"
                    preparedError <- verifyOptionalDigest preparedExists preparedPath (contentDigest rewritten) "prepared source"
                    targetError <- verifyOptionalDigest newExists newPath (contentDigest rewritten) "target source"
                    case [message | Just message <- [stateError, preparedError, targetError]] of
                      message : _ -> pure (Left (T.pack ((.oldPath) move) <> ": " <> message))
                      []
                        | newExists && not backupExists && not oldExists -> conflict hydrated newExists backupExists preparedExists "target has no recoverable backup"
                        | newExists && backupExists && not oldExists -> pure (Right (SourceMoveAlreadyApplied hydrated))
                        | otherwise -> pure (Right (SourceMoveReady hydrated rewritten))

    conflict move newExists backupExists preparedExists reason =
      pure
        ( Left
            ( T.pack ((.oldPath) move)
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
      let oldPath = out </> (.oldPath) move
          backupPath = out </> (.backupPath) move
      oldExists <- doesFileExist oldPath
      if oldExists
        then do
          createDirectoryIfMissing True (takeDirectory backupPath)
          renameFile oldPath backupPath
        else pure ()

    installMove preparedMove = do
      let move = preparedSourceMove preparedMove
          preparedPath = preparedSourcePath out move
          newPath = out </> (.newPath) move
      newExists <- doesFileExist newPath
      preparedExists <- doesFileExist preparedPath
      if newExists
        then if preparedExists then removeFile preparedPath else pure ()
        else do
          createDirectoryIfMissing True (takeDirectory newPath)
          renameFile preparedPath newPath

preparedSourcePath :: FilePath -> SourceMove -> FilePath
preparedSourcePath out move = out </> ((.newPath) move <> ".keiro-dsl-name-migration-prepared")

sourceMoveStatePath :: FilePath -> SourceMove -> FilePath
sourceMoveStatePath out move = out </> ((.backupPath) move <> ".keiro-dsl-name-migration-state")

renderSourceMoveState :: SourceMove -> Text
renderSourceMoveState move =
  T.unlines
    [ "keiro-dsl-name-migration-state v1",
      "old-path " <> T.pack ((.oldPath) move),
      "new-path " <> T.pack ((.newPath) move),
      "old-module " <> (.oldModule) move,
      "new-module " <> (.newModule) move,
      "source-digest " <> maybe "<missing>" id ((.contentDigest) move),
      "transformed-digest " <> maybe "<missing>" id ((.transformedDigest) move)
    ]

constraintPlanForService :: CheckedService -> ConsumerPlan -> [Text]
constraintPlanForService service plan = case checkedTypeGraph service of
  Left _ -> []
  Right graph ->
    let registerRoots =
          Set.fromList
            [ key
            | RootRegister _ _ key <- (.useSites) graph
            ]
     in map (constraintFor registerRoots) ((.mappings) plan)
  where
    constraintFor registerRoots mapping =
      (.specName) mapping
        <> ": "
        <> T.intercalate ", " (baseConstraints mapping <> registerConstraints registerRoots mapping)
    baseConstraints StructuralMapping {} = ["Eq", "Show", "CanonicalTypeName", "StructuralBinding"]
    baseConstraints OpaqueMapping {} = ["Eq", "Show", "ToJSON", "FromJSON"]
    baseConstraints NominalMapping {} = ["Eq", "Show", "NominalBinding"]
    registerConstraints roots mapping
      | MappedKey ((.specName) mapping) `Set.member` roots = ["register initial", "snapshot ToJSON", "snapshot FromJSON"]
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
    oldByName = Map.fromList [((.specName) mapping, mapping) | mapping <- previous]
    newByName = Map.fromList [((.specName) mapping, mapping) | mapping <- current]

checkedSemanticImpactSnapshot :: CheckedService -> SemanticImpactSnapshot
checkedSemanticImpactSnapshot service = case checkedTypeGraph service of
  Left failures -> error ("validated scaffold type graph did not resolve: " <> show failures)
  Right graph -> semanticImpactSnapshot (semanticImpactForService service graph)

semanticImpactForMappingDrift :: Maybe SemanticImpactSnapshot -> SemanticImpactSnapshot -> [MappingDrift] -> SemanticImpactReport
semanticImpactForMappingDrift previous current drifts =
  semanticImpactReport previous current changedDeclarations
  where
    driftDeclarations = [MappedKey ((.specName) drift) | drift <- drifts]
    snapshotDeclarations = maybe [] (map (.declaration) . (`diffSemanticImpact` current)) previous
    changedDeclarations = driftDeclarations <> snapshotDeclarations

generatedArtifactImpact :: [(ScaffoldModule, WriteDisposition)] -> [GeneratedArtifactImpact]
generatedArtifactImpact dispositions =
  sortOn
    (.path)
    [ GeneratedArtifactImpact
        { category = categoryFor role,
          role = role,
          path = (.path) scaffoldModule,
          disposition = disposition
        }
    | (scaffoldModule, disposition) <- dispositions,
      (.kind) scaffoldModule == Generated,
      disposition `elem` [Overwritten, Created],
      let role = moduleRole scaffoldModule
    ]
  where
    categoryFor role
      | (.family) role == "StructuralConformance" = ServiceStructuralConformanceArtifact
      | (.family) role == "BehaviorSourceMap" = BehaviorSourceMapArtifact
      | (.ownerKind) role == "aggregate"
          || ": aggregate " `T.isInfixOf` (.ownerName) role =
          AggregateGeneratedArtifact
      | otherwise = OtherGeneratedArtifact

newBindingObligations :: [BindingHole] -> [BindingHole] -> [BindingHole]
newBindingObligations current previous =
  [ obligation
  | obligation <- current,
    obligation `Set.notMember` previousSet
  ]
  where
    previousSet = Set.fromList previous

-- | Inspect, but never rewrite, an existing create-once read-model hole. A
-- typed plan is complete only after the application removes its legacy local
-- aliases and imports the generated QueryContract aliases.
queryContractMigrations :: FilePath -> [ScaffoldModule] -> IO [QueryContractMigration]
queryContractMigrations out modules = fmap concat (mapM inspect typedHoles)
  where
    typedHoles =
      [ (hole, requiredImport)
      | hole <- modules,
        (.kind) hole == HoleStub,
        (.family) (moduleRole hole) == "ReadModelHoles",
        requiredImport <- T.lines ((.text) hole),
        "import " `T.isPrefixOf` requiredImport,
        ".QueryContract (" `T.isInfixOf` requiredImport
      ]
    inspect (hole, requiredImport) = do
      let path = out </> (.path) hole
      exists <- doesFileExist path
      if not exists
        then pure []
        else do
          contents <- TIO.readFile path
          let ready = requiredImport `elem` T.lines contents && not (any isLocalQueryAlias (T.lines contents))
          pure
            [ QueryContractMigration
                { owner = queryOwner (moduleRole hole),
                  path = (.path) hole,
                  requiredImport = requiredImport
                }
            | not ready
            ]
    isLocalQueryAlias line = case T.words (T.strip line) of
      "type" : alias : "=" : _ -> "QueryInput" `T.isSuffixOf` alias || "QueryResult" `T.isSuffixOf` alias
      _ -> False
    queryOwner role = case T.words ((.ownerName) role) of
      "readmodel" : owner : _ -> owner
      _ -> (.ownerName) role

behaviorDrift :: [BehaviorRecordRow] -> [BehaviorRecordRow] -> ([BehaviorRecordRow], [BehaviorRecordRow])
behaviorDrift current previous =
  ( [row | row <- sortOn (.key) current, (.key) row `Set.notMember` previousKeys],
    [row | row <- sortOn (.key) previous, (.key) row `Set.notMember` currentKeys]
  )
  where
    currentKeys = Set.fromList (map (.key) current)
    previousKeys = Set.fromList (map (.key) previous)

readRecord :: FilePath -> IO (Maybe ScaffoldRecord)
readRecord path = do
  exists <- doesFileExist path
  if exists then parseRecord <$> TIO.readFile path else pure Nothing

existingStale :: FilePath -> [ScaffoldModule] -> ScaffoldRecord -> IO [StaleModule]
existingStale out modules record = staleAgainst out (map (.path) modules) ((.files) record)

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

currentRecord :: FilePath -> SourceLanguage -> Context -> CheckedService -> [ScaffoldModule] -> Bool -> [BehaviorRecordRow] -> SemanticImpactSnapshot -> ScaffoldRecord
currentRecord specPath sourceLanguage ctx service modules queryHistoryBaseline currentBehavior currentSemanticImpact =
  ScaffoldRecord
    { specPath = T.pack specPath,
      moduleRoot = (.moduleRoot) ctx,
      layout = case (.placement) ctx of GeneratedPrefix -> "prefixed"; CollocatedLeaf -> "collocated",
      sourceLanguage = sourceLanguage,
      languageContract = checkedLanguageContract service,
      namingEdition = currentGeneratedHaskellNamingEdition,
      moduleRoles = [ScaffoldModuleRoleRow (moduleRole m) ((.kind) m) ((.path) m) | m <- modules],
      files = [((.kind) m, (.path) m) | m <- modules],
      mappings = (.mappings) (consumerPlanForService service),
      idDomains = idDomainIdentitiesForService service,
      nominalEqualities = nominalEqualityIdentitiesForService service,
      bindingObligations = either (const []) id (bindingHolesForService service),
      behaviorRequirements = currentBehavior,
      projectionCatalogFacts = projectionCatalogFactsForService service,
      queryContractBaseline = queryHistoryBaseline,
      queryContracts = either (const []) id (queryContractIdentitiesForService service),
      routerSelections = routerSelectionSnapshots service,
      semanticImpact = Just currentSemanticImpact
    }

missingGeneratedBanners :: FilePath -> [ScaffoldModule] -> IO [FilePath]
missingGeneratedBanners out modules = fmap concat $ mapM check generated
  where
    generated = [m | m <- modules, (.kind) m == Generated]
    check m = do
      let path = out </> (.path) m
      exists <- doesFileExist path
      if not exists
        then pure []
        else do
          contents <- TIO.readFile path
          pure [(.path) m | not (any isGeneratedBannerLine (T.lines contents))]

writeModule :: FilePath -> ScaffoldModule -> IO (ScaffoldModule, WriteDisposition)
writeModule out m = do
  let path = out </> (.path) m
  createDirectoryIfMissing True (takeDirectory path)
  case (.kind) m of
    Generated -> do
      exists <- doesFileExist path
      if exists
        then do
          existing <- TIO.readFile path
          if existing == (.text) m
            then pure (m, Unchanged)
            else TIO.writeFile path ((.text) m) >> pure (m, Overwritten)
        else TIO.writeFile path ((.text) m) >> pure (m, Overwritten)
    HoleStub -> do
      exists <- doesFileExist path
      if exists
        then pure (m, Skipped)
        else TIO.writeFile path ((.text) m) >> pure (m, Created)

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
    render (BehaviorSourceRefusal failures) =
      ["error: behavior source map cannot be planned -- refusing to scaffold; nothing was written"]
        <> [ "  "
               <> T.pack (show ((.code) failure))
               <> " "
               <> Behavior.unBehaviorKey ((.key) failure)
               <> ": "
               <> (.message) failure
           | failure <- failures
           ]
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
    render (GeneratedHaskellEditionRequired impact) =
      [ "error: generated Haskell edition migration required: idiomatic-v1 -> idiomatic-v2; nothing was written",
        "re-run scaffold with --apply-generated-haskell-edition after reviewing this impact:",
        "  generated files: " <> tshow (length ((.generatedPaths) impact))
      ]
        <> map (("    " <>) . T.pack) ((.generatedPaths) impact)
        <> ["  sidecars: " <> tshow (length ((.sidecarPaths) impact))]
        <> map (("    " <>) . T.pack) ((.sidecarPaths) impact)
        <> ["  hand-owned selector uses: " <> tshow (length ((.handOwnedUses) impact))]
        <> map renderEditionUse ((.handOwnedUses) impact)
    render (GeneratedHaskellEditionRefusal reasons) =
      ["error: generated Haskell edition migration could not be applied safely; nothing was written"]
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
        <> ["  " <> (.duplicateServiceFactKey) duplicate | duplicate <- duplicates]
    render (ConformancePackageRefusal failure) = renderConformancePackageFailure failure
    renderMove move =
      "  "
        <> (case (.kind) move of Generated -> "generated "; HoleStub -> "hole      ")
        <> (.oldModule) move
        <> " -> "
        <> (.newModule) move
        <> "  backup: "
        <> T.pack ((.backupPath) move)
    renderEditionUse use =
      "    "
        <> T.pack ((.path) use)
        <> ":"
        <> tshow ((.line) use)
        <> ": "
        <> (.current) use
        <> " -> "
        <> (.replacement) use

renderSemanticImpactReport :: SemanticImpactReport -> [Text]
renderSemanticImpactReport report = case (.declarations) report of
  [] -> []
  declarations ->
    ["semantic impact:"]
      <> case (.previous) report of
        Nothing ->
          ["  baseline: unavailable (legacy ledger)"]
            <> concatMap renderCurrent declarations
        Just _ -> concatMap renderDelta ((.deltas) report)
  where
    renderCurrent declaration =
      [ "  " <> (.unMappedKey) declaration,
        "    current aggregate consumers: " <> renderConsumers (Map.findWithDefault Set.empty declaration ((.mappedConsumers) ((.current) report))),
        "    current roots: " <> maybe "baseline unavailable" (renderEvidence . Map.findWithDefault Set.empty declaration) ((.mappedEvidence) ((.current) report)),
        "    current consequences: " <> maybe "baseline unavailable" (renderConsequences . Map.findWithDefault Set.empty declaration) ((.mappedConsequences) ((.current) report)),
        "    service-conformance: impacted"
      ]
    renderDelta delta =
      [ "  " <> (.unMappedKey) ((.declaration) delta),
        "    previous aggregate consumers: " <> renderConsumers ((.previousConsumers) delta),
        "    current aggregate consumers:  " <> renderConsumers ((.currentConsumers) delta),
        "    previous roots: " <> maybe "baseline unavailable" renderEvidence ((.previousEvidence) delta),
        "    current roots:  " <> maybe "baseline unavailable" renderEvidence ((.currentEvidence) delta),
        "    previous consequences: " <> maybe "baseline unavailable" renderConsequences ((.previousConsequences) delta),
        "    current consequences:  " <> maybe "baseline unavailable" renderConsequences ((.currentConsequences) delta),
        "    service-conformance: " <> if (.serviceConformance) delta then "impacted" else "unchanged"
      ]
    renderConsumers aggregateConsumers = case map consumerName (Set.toAscList aggregateConsumers) of
      [] -> "(none)"
      names -> T.intercalate ", " names
    consumerName = mappedConsumerIdentity
    renderEvidence = renderSet renderRoot
    renderRoot evidence =
      T.intercalate "|" [mappedRootKindIdentity ((.rootKind) evidence), mappedConsumerIdentity ((.consumer) evidence), (.path) evidence]
        <> maybe "" ("|" <>) ((.operation) evidence)
    renderConsequences = renderSet mappedConsequenceIdentity
    renderSet render values = case map render (Set.toAscList values) of
      [] -> "(none)"
      rendered -> T.intercalate ", " rendered

renderGeneratedArtifactImpact :: SemanticImpactReport -> [GeneratedArtifactImpact] -> [Text]
renderGeneratedArtifactImpact _ [] = []
renderGeneratedArtifactImpact semanticReport impacts =
  "generated-artifact impact:" : map renderArtifact impacts
  where
    renderArtifact impact =
      "  "
        <> categoryLabel ((.category) impact)
        <> " "
        <> T.pack ((.path) impact)
        <> " ("
        <> dispositionLabel ((.disposition) impact)
        <> ")"
    categoryLabel AggregateGeneratedArtifact
      | null ((.deltas) semanticReport) = "aggregate (generator or non-mapped drift; no mapped semantic impact)"
      | otherwise = "aggregate"
    categoryLabel ServiceStructuralConformanceArtifact = "service-conformance"
    categoryLabel BehaviorSourceMapArtifact = "behavior-source-map"
    categoryLabel OtherGeneratedArtifact = "generated"
    dispositionLabel Overwritten = "overwritten"
    dispositionLabel Created = "created"
    dispositionLabel Skipped = "skipped"
    dispositionLabel Unchanged = "unchanged"

renderScaffoldReport :: ScaffoldReport -> [Text]
renderScaffoldReport report =
  [ "scaffold: " <> T.pack ((.specPath) report) <> " -> " <> T.pack ((.outDir) report) <> " (module-root=" <> rootLabel <> ", layout=" <> layoutLabel <> ")"
  ]
    <> map moduleLine dispositions
    <> inertNodeSection
    <> [ "firewall: OK (" <> tshow generatedCount <> " generated modules scanned, 0 forbidden operators)",
         harnessLine,
         dependencyLine,
         "fragment: " <> T.pack ((.manifestPath) report),
         "ledger:   " <> T.pack ((.recordPath) report)
       ]
    <> previousSpecNote
    <> constraintSection
    <> newHolesSection
    <> queryContractSection
    <> queryContractMigrationSection
    <> mappingDriftSection
    <> renderSemanticImpactReport ((.semanticImpact) report)
    <> renderRouterSelectionDrift ((.routerSelectionDrift) report)
    <> maybe [] renderProjectionMappedImpact ((.projectionMappedImpact) report)
    <> renderGeneratedArtifactImpact ((.semanticImpact) report) ((.generatedArtifactImpact) report)
    <> sourceLanguageDriftSection
    <> behaviorDriftSection
    <> obsoleteOutputSection
    <> sidecarMoveSection
    <> nameMoveSection
    <> staleSection
    <> maybe [] renderConformancePackageReport ((.conformancePackage) report)
  where
    ctx = (.context) report
    dispositions = (.dispositions) report
    rootLabel = if T.null ((.moduleRoot) ctx) then "(none)" else (.moduleRoot) ctx
    layoutLabel = case (.placement) ctx of GeneratedPrefix -> "prefixed"; CollocatedLeaf -> "collocated"
    names = [moduleNameOf ((.path) m) | (m, _) <- dispositions]
    nameWidth = maximum (1 : map T.length names)
    moduleLine (m, disposition) =
      "  " <> kindTag ((.kind) m) <> "  " <> pad (moduleNameOf ((.path) m)) <> "  " <> dispositionTag disposition
    kindTag Generated = "generated"
    kindTag HoleStub = "hole     "
    dispositionTag Overwritten = "(overwritten)"
    dispositionTag Created = "(created)"
    dispositionTag Skipped = "(skipped: already present)"
    dispositionTag Unchanged = "(unchanged)"
    pad name = name <> T.replicate (nameWidth - T.length name) " "
    generatedCount = length [() | (m, _) <- dispositions, (.kind) m == Generated]
    inertNodeSection = renderInertNodeSection ((.inertNodes) report)
    harnesses =
      sortOn
        id
        [ moduleNameOf ((.path) m)
        | (m, _) <- dispositions,
          any (`T.isSuffixOf` moduleNameOf ((.path) m)) [".Harness", ".ProcessHarness", ".WorkflowFacts"]
        ]
    harnessLine = case harnesses of
      [] -> "harness:  (none emitted)"
      _ -> "harness:  run `cabal test <your-component>` over " <> T.unwords harnesses
    dependencyLine =
      "dependency plan: consumer packages "
        <> renderBracketed ((.packages) ((.consumerPlan) report))
        <> ", consumer modules "
        <> renderBracketed ((.modules) ((.consumerPlan) report))
    constraintSection = case (.constraintPlan) report of
      [] -> []
      constraints -> "constraint plan:" : map ("  " <>) constraints
    newHolesSection = case (.newHoles) report of
      [] -> []
      obligations ->
        ["newly required holes since last scaffold: " <> tshow (length obligations)]
          <> concatMap obligationLines obligations
    obligationLines hole =
      [ "  " <> (.moduleName) hole,
        "    " <> (.signature) hole <> " (" <> obligationKindLabel ((.kind) hole) <> ")"
      ]
    queryContractSection =
      [ "query contract history: baseline unavailable in the previous ledger; no legacy `()` API was inferred"
      | (.queryContractBaselineUnavailable) report
      ]
        <> case (.queryContractDrift) report of
          [] -> []
          drifts ->
            ["query contract drift: " <> tshow (length drifts) <> " input/result position(s) changed since the previous scaffold:"]
              <> concatMap queryDriftLines drifts
    queryDriftLines drift =
      [ "  " <> readModel <> " " <> queryPositionLabel position,
        "    previous: " <> maybe "(absent)" renderQueryIdentity ((.previous) drift),
        "    current:  " <> maybe "(absent)" renderQueryIdentity ((.current) drift)
      ]
      where
        (readModel, position) = (.key) drift
    renderQueryIdentity identity =
      (.typeExpression) identity
        <> " mapped=["
        <> T.intercalate ", " ((.mappedDependencies) identity)
        <> "]"
    queryPositionLabel QueryInputConsumer = "input"
    queryPositionLabel QueryResultConsumer = "result"
    queryContractMigrationSection = case (.queryContractMigrations) report of
      [] -> []
      migrations ->
        ["query contract migration required: " <> tshow (length migrations) <> " hand-owned hole module(s)"]
          <> concatMap migrationLines migrations
    migrationLines migration =
      [ "  " <> (.owner) migration,
        "    edit " <> T.pack ((.path) migration),
        "    remove the local QueryInput/QueryResult type aliases",
        "    add " <> (.requiredImport) migration
      ]
    previousSpecNote = case (.previousSpecPath) report of
      Just previous
        | previous /= T.pack ((.specPath) report) ->
            [ "note: the previous scaffold record used spec " <> previous,
              "      specs sharing context " <> (.name) ctx <> " in one --out also share " <> T.pack ((.manifestPath) report)
            ]
      _ -> []
    mappingDriftSection = case (.mappingDrift) report of
      [] -> []
      drifts ->
        ["mapping drift: " <> tshow (length drifts) <> " declaration(s) changed since the previous scaffold:"]
          <> concatMap driftLines drifts
    driftLines drift =
      [ "  " <> (.specName) drift,
        "    previous: " <> maybe "(absent)" renderMappingIdentity ((.previous) drift),
        "    current:  " <> maybe "(absent)" renderMappingIdentity ((.current) drift)
      ]
    sourceLanguageDriftSection = case (.sourceLanguageDrift) report of
      Nothing -> []
      Just drift ->
        [ "source-language drift: "
            <> sourceLanguageLabel ((.previous) drift)
            <> " -> "
            <> sourceLanguageLabel ((.current) drift)
            <> " (generated module bytes are semantic and unaffected)"
        ]
    behaviorDriftSection =
      renderBehaviorRows "new behavior obligations" ((.addedBehavior) report)
        <> renderBehaviorRows "removed behavior obligations (consumer rows become stale)" ((.removedBehavior) report)
    renderBehaviorRows _ [] = []
    renderBehaviorRows label rows =
      [label <> ": " <> tshow (length rows)] <> concatMap behaviorLines rows
    behaviorLines row =
      [ "  "
          <> (.aggregate) row
          <> ":"
          <> (.source) row
          <> " -- "
          <> (.command) row
          <> "  "
          <> (.unBehaviorKey) ((.key) row),
        "    Pending (BehaviorKey " <> tshow ((.unBehaviorKey) ((.key) row)) <> ")"
      ]
    obsoleteOutputSection = case (.obsoleteOutputHooks) report of
      [] -> []
      hooks ->
        ["obsolete identity-copy output hooks (if still present, they are unused and may be removed):"]
          <> ["  " <> aggregate <> ".Holes." <> hook | (aggregate, hook) <- hooks]
    sidecarMoveSection = case (.sidecarMoves) report of
      [] -> []
      moves ->
        ["sidecar migration: applied (" <> tshow (length moves) <> " move(s))"]
          <> map (("  " <>) . renderSidecarMove) moves
    nameMoveSection = case (.nameMoves) report of
      [] -> []
      moves ->
        ["name migration: applied (" <> tshow (length moves) <> " source move(s))"]
          <> ["  backup: " <> T.pack ((.backupPath) move) | move <- moves]
    staleSection = case (.stale) report of
      [] -> []
      stale ->
        [ "stale: " <> tshow (length stale) <> " file(s) from a previous scaffold of context " <> (.name) ctx <> " are no longer produced by this spec:"
        ]
          <> map staleLine stale
          <> ["note: keiro-dsl never deletes files."]
    staleLine stale = case ((.kind) stale, (.generatedEvidence) stale) of
      (Generated, Just ExactGeneratedBannerPresent) ->
        "  generated " <> T.pack ((.path) stale) <> "  (exact generated banner present; verify unchanged bytes before deleting)"
      (Generated, _) ->
        "  generated " <> T.pack ((.path) stale) <> "  (exact generated banner missing; preserve and review)"
      (HoleStub, _) -> "  hole      " <> T.pack ((.path) stale) <> "  (hand-owned — preserve and review)"

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
renderMappingIdentity StructuralMapping {package, moduleName, valueType, bindingSymbol, bindingVersion} =
  "structural "
    <> package
    <> ":"
    <> moduleName
    <> "."
    <> valueType
    <> " binding="
    <> bindingSymbol
    <> " version="
    <> bindingVersion
renderMappingIdentity OpaqueMapping {package, moduleName, valueType, codecIdentity, codecVersion} =
  "opaque "
    <> package
    <> ":"
    <> moduleName
    <> "."
    <> valueType
    <> " codec="
    <> codecIdentity
    <> " version="
    <> codecVersion
renderMappingIdentity NominalMapping {nominalCategory, nominalRepresentation, package, moduleName, valueType, bindingSymbol, bindingVersion} =
  "nominal-"
    <> nominalCategory
    <> " "
    <> package
    <> ":"
    <> moduleName
    <> "."
    <> valueType
    <> " representation="
    <> nominalRepresentation
    <> " binding="
    <> bindingSymbol
    <> " version="
    <> bindingVersion

tshow :: (Show a) => a -> Text
tshow = T.pack . show
