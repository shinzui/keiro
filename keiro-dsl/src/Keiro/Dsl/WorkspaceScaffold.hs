-- | Whole-__workspace__ scaffolding: one invocation plans and emits the
-- complete generated module set for every member of a service workspace.
--
-- The module exists separately from "Keiro.Dsl.ScaffoldRun" for a structural
-- reason, not a stylistic one: "Keiro.Dsl.Workspace" already imports
-- 'Keiro.Dsl.ScaffoldRun' (its cross-member collision check asks the planner), so
-- workspace-aware scaffolding cannot live there without a module cycle. Everything
-- it needs from the single-spec pipeline is imported, never re-implemented — the
-- refusal gates, the stale comparison, the constraint plan, the drift computation
-- — so a workspace and a single spec can never disagree about what is legal.
--
-- Two properties are true __by construction__ rather than by test:
--
--   * Emission runs once over the workspace's /merged/ 'Spec'
--     ('Keiro.Dsl.Workspace.wsMergedSpec'), so the context-level artifacts — the
--     structural projection facade and the replay-audit assembly — are emitted
--     exactly once from the complete graph. Concatenating per-member scaffolds
--     would emit them N times from N partial graphs, which is the defect this
--     module fixes.
--
--   * A one-member workspace produces exactly the single-file module set, in the
--     same order, with identical bytes and identical metadata, because it calls
--     the same emitters with the same inputs.
--
-- History is workspace-keyed ("Keiro.Dsl.WorkspaceRecord"). Each module remembers
-- which member produced it, so moving an aggregate between member files is an
-- /ownership move/ rather than a stale-plus-new pair.
--
-- Atomicity here means what it means for a single spec: every refusal is computed
-- before the first output byte changes. There are no staged temp-file writes.
module Keiro.Dsl.WorkspaceScaffold
  ( -- * Planning
    ModuleProvenance (..),
    WorkspacePlan (..),
    planWorkspaceScaffold,
    planWorkspaceScaffoldWithGoldens,
    planWorkspaceScaffoldWithRuntimePackageAndGoldens,
    provenanceOwner,

    -- * Golden payload roots
    goldenRootDivergence,

    -- * Execution
    OwnershipMove (..),
    WorkspaceSourceLanguageDrift (..),
    WorkspaceScaffoldReport (..),
    executeWorkspaceScaffold,
    executeWorkspaceScaffoldWithNameMigrations,
    executeWorkspaceScaffoldWithMigrations,
    readWorkspaceRecord,
    renderWorkspaceScaffoldReport,
  )
where

import Data.List (nub, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.BehaviorCoverage (BehaviorKey (..), BehaviorRecordRow (..), attributeBehaviorOwner, behaviorRecordRows, deriveBehaviorRequirementsForService)
import Keiro.Dsl.BehaviorSourceMap qualified as BehaviorSource
import Keiro.Dsl.ConformancePackage
  ( ConformancePackagePlan,
    ConformancePackageReport,
    ConformanceServiceKey (WorkspaceConformanceService),
    executePreparedConformancePackage,
    planConformancePackage,
    preflightConformancePackage,
    renderConformancePackageReport,
  )
import Keiro.Dsl.CoordinationImpact (RouterSelectionDrift, renderRouterSelectionDrift, routerSelectionDrift, routerSelectionSnapshots)
import Keiro.Dsl.ExplainBindings (BindingHole (..), bindingHolesForService)
import Keiro.Dsl.Goldens (GoldenPayload)
import Keiro.Dsl.Grammar
import Keiro.Dsl.Harness (harnessForServiceWithGoldens, harnessProcess, harnessReadModelForService, harnessRouterForService, harnessWorkflow)
import Keiro.Dsl.HaskellName (currentGeneratedHaskellNamingEdition)
import Keiro.Dsl.HaskellSourceMove (SourceMove (..), SourceMoveError, planSourceMoves)
import Keiro.Dsl.IdDomain (idDomainIdentitiesForService)
import Keiro.Dsl.LanguageVersion (SourceLanguage, effectiveLanguageVersion, languageVersionText, sourceFormText)
import Keiro.Dsl.Manifest (moduleNameOf, renderManifestForServiceWithFacade)
import Keiro.Dsl.MappedConsumer (ConsumerPlan (..), consumerPlanForService)
import Keiro.Dsl.NominalType (nominalEqualityIdentitiesForService)
import Keiro.Dsl.ProjectionMappedImpact (ProjectionMappedImpact, projectionMappedImpactForService, renderProjectionMappedImpact)
import Keiro.Dsl.ReadModelQueryContract
  ( QueryContractDrift (..),
    QueryContractIdentity (..),
    QueryContractPosition (..),
    queryContractDrift,
    queryContractIdentitiesForService,
  )
import Keiro.Dsl.RuntimePackage (RuntimePackageName)
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRecord (projectionCatalogFactsForService)
import Keiro.Dsl.ScaffoldRun
  ( GeneratedArtifactImpact,
    LedgerRead (..),
    MappingDrift (..),
    PreparedGeneratedHaskellEditionMigration (..),
    PreparedSourceMove,
    QueryContractMigration (..),
    Refusal (..),
    StaleGeneratedEvidence (..),
    StaleModule (..),
    WriteDisposition (..),
    applyPreparedGeneratedHaskellEditionMigration,
    applyPreparedSourceMoves,
    behaviorDrift,
    checkedSemanticImpactSnapshot,
    constraintPlanForService,
    generatedArtifactImpact,
    inertNodesOf,
    ledgerToMaybe,
    mappingDrift,
    missingGeneratedBanners,
    newBindingObligations,
    obligationKindLabel,
    planningGatePipeline,
    preflightGeneratedHaskellEditionMigration,
    preflightSourceMoves,
    preparedSourceMove,
    queryContractMigrations,
    renderGeneratedArtifactImpact,
    renderInertNodeSection,
    renderMappingIdentity,
    renderSemanticImpactReport,
    semanticImpactForMappingDrift,
    staleAgainst,
    withGeneratedHaskellEditionSourceMoves,
    withSidecarMovesApplied,
  )
import Keiro.Dsl.SemanticContract (CheckedService, checkedLanguageContract, checkedSpec)
import Keiro.Dsl.SemanticImpact (SemanticImpactReport, SemanticImpactSnapshot)
import Keiro.Dsl.ServiceHarness (DuplicateServiceFactKey, serviceConformanceModuleName, serviceHarnessModule)
import Keiro.Dsl.SidecarMigration
import Keiro.Dsl.SidecarNames (legacyWorkspaceRecordFileName)
import Keiro.Dsl.StructuralConformance (structuralConformanceModule)
import Keiro.Dsl.Validate (nodeIdentity)
import Keiro.Dsl.Workspace (WorkspaceMember (..), WorkspaceSpec (..), checkedWorkspace, declarationOwner, nodeOwner)
import Keiro.Dsl.WorkspaceAdoption (MigrationReport (..), adoptedRows, adoptionReport, markLegacyRecordSuperseded, renderMigrationReport)
import Keiro.Dsl.WorkspaceRecord
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, takeFileName, (</>))

--------------------------------------------------------------------------------
-- Planning
--------------------------------------------------------------------------------

-- | Which member file produced an emitted module. 'ContextLevel' means the
-- module belongs to the whole service rather than to any one member: the
-- structural projection facade, the replay-audit assembly, and any binding
-- skeleton shared by declarations owned by different members.
data ModuleProvenance
  = ContextLevel
  | MemberOwned !FilePath
  deriving stock (Eq, Ord, Show)

-- | The owning member path, or 'Nothing' for a context-level module.
provenanceOwner :: ModuleProvenance -> Maybe FilePath
provenanceOwner ContextLevel = Nothing
provenanceOwner (MemberOwned path) = Just path

-- | The complete, refusal-free write set for one whole-workspace scaffold, with
-- each module's producing member attached.
data WorkspacePlan = WorkspacePlan
  { workspace :: !WorkspaceSpec,
    checkedService :: !CheckedService,
    context :: !Context,
    runtimePackage :: !(Maybe RuntimePackageName),
    conformancePackage :: !(Maybe ConformancePackagePlan),
    -- | The one golden-payload root for the whole workspace. Carried here so
    --     execution can refuse a member-adjacent fixture the root lacks before it
    --     writes anything.
    goldenRoot :: !FilePath,
    modules :: ![(ScaffoldModule, ModuleProvenance)]
  }
  deriving stock (Eq, Show)

-- | 'planWorkspaceScaffoldWithGoldens' with no golden payload fixtures.
planWorkspaceScaffold :: FilePath -> Context -> WorkspaceSpec -> Either [Refusal] WorkspacePlan
planWorkspaceScaffold = planWorkspaceScaffoldWithGoldens []

-- | Plan the whole workspace: build the merged module set once, attribute each
-- module to its owning member, then run every pure refusal gate over the complete
-- set. A refusal carries no write set, so it cannot be executed by accident.
--
-- Because the gates see the whole workspace, a case-folded module-path collision
-- between two members is caught here, with both member files named in the
-- collision's origins.
planWorkspaceScaffoldWithGoldens ::
  [GoldenPayload] ->
  FilePath ->
  Context ->
  WorkspaceSpec ->
  Either [Refusal] WorkspacePlan
planWorkspaceScaffoldWithGoldens goldens goldenRoot ctx workspace =
  planWorkspaceScaffoldWithRuntimePackageAndGoldens goldens ((.runtimePackage) workspace) goldenRoot ctx workspace

planWorkspaceScaffoldWithRuntimePackageAndGoldens ::
  [GoldenPayload] ->
  Maybe RuntimePackageName ->
  FilePath ->
  Context ->
  WorkspaceSpec ->
  Either [Refusal] WorkspacePlan
planWorkspaceScaffoldWithRuntimePackageAndGoldens goldens runtimePackage goldenRoot ctx workspace =
  do
    _ <- planningGatePipeline ctx service baseModulePlan packageGate
    _ <- planningGatePipeline ctx service completeModulePlan packageGate
    tagged <- taggedModules
    plannedPackage <- either (Left . map ConformancePackageRefusal) Right packagePlan
    Right
      WorkspacePlan
        { workspace = workspace,
          checkedService = service,
          context = ctx,
          runtimePackage = runtimePackage,
          conformancePackage = plannedPackage,
          goldenRoot = goldenRoot,
          modules = tagged
        }
  where
    service = checkedWorkspace workspace
    sourceEntries = do
      requirements <- either (Left . pure . BehaviorRefusal) Right (deriveBehaviorRequirementsForService service)
      either (Left . pure . BehaviorSourceRefusal) Right (BehaviorSource.planBehaviorSourceMap requirements ((.sourceIndex) workspace))
    taggedModules = do
      entries <- sourceEntries
      either (Left . pure . DuplicateConformanceFactKeys) Right (workspaceModules goldens runtimePackage entries ctx workspace service)
    baseTaggedModules = either (Left . pure . DuplicateConformanceFactKeys) Right (workspaceModules goldens runtimePackage [] ctx workspace service)
    baseModulePlan = case baseTaggedModules of
      Left refusals -> Left refusals
      Right tagged -> Right (map fst tagged)
    completeModulePlan = case taggedModules of
      Left refusals -> Left refusals
      Right tagged -> Right (map fst tagged)
    packagePlan =
      traverse
        (\packageName -> planConformancePackage (WorkspaceConformanceService ((.service) workspace)) packageName (serviceConformanceModuleName ctx) service)
        runtimePackage
    packageGate = case packagePlan of
      Left failures -> Left (map ConformancePackageRefusal failures)
      Right _ -> Right ()

-- | The tagged module set, in exactly the order
-- 'Keiro.Dsl.ScaffoldRun.scaffoldModulesWithGoldens' produces for the merged spec.
--
-- Attribution is structural, never a re-parse of the human-readable @origin@
-- string: structural modules carry the mapped declarations they were emitted for
-- ('scaffoldStructuralOwners') and nodes carry their own identity
-- ('nodeIdentity'), both of which the workspace's ownership index resolves to a
-- member file.
workspaceModules :: [GoldenPayload] -> Maybe RuntimePackageName -> [BehaviorSource.BehaviorSourceEntry] -> Context -> WorkspaceSpec -> CheckedService -> Either [DuplicateServiceFactKey] [(ScaffoldModule, ModuleProvenance)]
workspaceModules goldens runtimePackage sourceEntries ctx workspace service = do
  structuralConformance <- case structuralConformanceModule ctx service of
    Left failures -> error ("checked workspace structural conformance planning failed: " <> show failures)
    Right Nothing -> Right []
    Right (Just moduleValue) -> Right [(stamp moduleValue, ContextLevel)]
  facade <- case runtimePackage of
    Nothing -> Right []
    Just _ -> fmap (\moduleValue -> [(stamp moduleValue, ContextLevel)]) (serviceHarnessModule ctx service)
  pure $
    structuralConformance
      <> [attributedStamped ContextLevel moduleValue | moduleValue <- maybe [] pure (behaviorSourceMapModule ctx sourceEntries)]
      <> [attributedStamped (declarationProvenance names) m | (m, names) <- scaffoldStructuralOwnersForService ctx service]
      <> [attributedStamped ContextLevel m | m <- scaffoldReplayAudit ctx merged]
      <> [attributedStamped ContextLevel m | m <- scaffoldProjectionCatalogForService ctx service]
      <> concat
        [ map (attributedStamped (nodeProvenance node)) (emittersFor node)
        | node <- (.nodes) merged
        ]
      <> facade
  where
    merged = checkedSpec service
    ownership = (.ownership) workspace
    stamp = stampGeneratedModule (checkedLanguageContract service)
    attributedStamped provenance moduleValue =
      let (annotated, attribution) = attributed provenance moduleValue
       in (stamp annotated, attribution)

    emittersFor node = case node of
      NAggregate aggregate -> scaffoldAggregateForService ctx service aggregate <> harnessForServiceWithGoldens goldens ctx service aggregate
      NProcess process -> scaffoldProcess ctx process <> harnessProcess ctx process
      NRouter router -> scaffoldRouterForService ctx service router <> harnessRouterForService ctx service router
      NContract contract -> scaffoldContractForService ctx service contract
      NIntake intake -> scaffoldIntake ctx intake
      NPublisher publisher -> scaffoldPublisher ctx publisher
      NWorkqueue workqueue -> scaffoldWorkqueueForService ctx service workqueue
      NReadModel readModel ->
        let resolved = resolveCatalogReadModel merged readModel
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

    nodeProvenance node =
      let (kind', name, _) = nodeIdentity node
       in maybe ContextLevel (MemberOwned . fst) (nodeOwner ownership kind' name)

    -- A structural module belongs to a member only when every declaration it
    -- was emitted for has the same owner. A binding skeleton shared by
    -- declarations from two members belongs to neither: attributing it to one
    -- would make the other member's obligations look like they moved whenever
    -- the map iteration order changed.
    declarationProvenance names = case nub owners of
      [owner] | length owners == length names -> MemberOwned owner
      _ -> ContextLevel
      where
        owners = [owner | name <- names, Just (owner, _) <- [declarationOwner ownership "mapped" name]]

    -- Name the producing member in refusal messages, so a cross-member path
    -- collision says which files claimed the path. `origin` is metadata read
    -- only by refusal rendering: it never reaches the module text, the record,
    -- or the build manifest. A single-member workspace adds no prefix, which is
    -- what keeps it identical to the single-file path down to this field.
    attributed provenance m = (annotate provenance m, provenance)
    annotate (MemberOwned path) m
      | length workspace.members > 1 =
          ScaffoldModule
            { path = m.path,
              text = m.text,
              kind = m.kind,
              origin = T.pack path <> ": " <> m.origin
            }
    annotate _ m = m

--------------------------------------------------------------------------------
-- Golden payload roots
--------------------------------------------------------------------------------

-- | Refuse when a member has golden payload fixtures beside it that the
-- workspace's single golden root does not have.
--
-- Golden fixtures are keyed @\<context\>\/\<Aggregate\>\/\<Event\>.v\<N\>.json@ —
-- by aggregate, and an aggregate has exactly one owner across a workspace — so one
-- root per workspace cannot collide, while a per-member root would make a
-- fixture's location depend on which file currently owns the aggregate and break
-- the rule that an ownership move is not a content change.
--
-- Without this check the failure would be silent: a member-adjacent fixture the
-- workspace root lacks is simply not found, the harness embeds a synthesized weak
-- stand-in instead of the file-owned payload, and generated bytes change with no
-- diagnostic at all.
goldenRootDivergence :: FilePath -> WorkspaceSpec -> IO [Refusal]
goldenRootDivergence workspaceRoot workspace = do
  stranded <- concat <$> traverse strandedFor ((.members) workspace)
  pure [GoldenRootDivergence workspaceRoot stranded | not (null stranded)]
  where
    manifestDir = takeDirectory ((.manifestPath) workspace)
    strandedFor member = concat <$> traverse (check member) (upcastFixtures ((.spec) member))
    check member relative = do
      let memberRoot = manifestDir </> takeDirectory ((.path) member) </> "golden-payloads"
      besideMember <- firstExisting memberRoot relative
      case besideMember of
        Nothing -> pure []
        Just found -> do
          atRoot <- firstExisting workspaceRoot relative
          pure (case atRoot of Nothing -> [found]; Just _ -> [])
    -- Mirror the two shapes `loadGoldenPayloads` accepts: a root holding
    -- context directories, or a root that already is the context directory.
    firstExisting root relative = firstJustM [root </> relative, root </> dropContext relative]
    dropContext relative = case break (== '/') relative of
      (_, '/' : rest) -> rest
      _ -> relative
    firstJustM [] = pure Nothing
    firstJustM (path : rest) = do
      exists <- doesFileExist path
      if exists then pure (Just path) else firstJustM rest

-- | The @\<context\>\/\<Aggregate\>\/\<Event\>.v\<N\>.json@ fixture paths a
-- spec's declared upcasters would load, in spec order.
upcastFixtures :: Spec -> [FilePath]
upcastFixtures spec =
  [ T.unpack ((.context) spec) </> T.unpack ((.name) aggregate) </> fixtureName event sourceVersion
  | NAggregate aggregate <- (.nodes) spec,
    event <- (.events) aggregate,
    Just (sourceVersion, _) <- [(.upcastFrom) event]
  ]
  where
    fixtureName event sourceVersion = T.unpack ((.name) event) <> ".v" <> show sourceVersion <> ".json"

--------------------------------------------------------------------------------
-- Execution
--------------------------------------------------------------------------------

-- | A module the workspace still produces, but from a different member file
-- than last time. 'Nothing' on either side means context-level.
--
-- An ownership move is deliberately __not__ a stale entry and __not__ a new file:
-- the path is still produced, so nothing is orphaned. Reporting it separately is
-- what stops "I moved this aggregate to another file" from looking like "another
-- spec's leftovers". Whole-workspace diffing must classify it identically.
data OwnershipMove = OwnershipMove
  { path :: !FilePath,
    previous :: !(Maybe FilePath),
    current :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show)

data WorkspaceSourceLanguageDrift = WorkspaceSourceLanguageDrift
  { path :: !FilePath,
    previous :: !SourceLanguage,
    current :: !SourceLanguage
  }
  deriving stock (Eq, Show)

-- | What one successful whole-workspace scaffold did.
data WorkspaceScaffoldReport = WorkspaceScaffoldReport
  { manifestPath :: !FilePath,
    outDir :: !FilePath,
    service :: !Text,
    context :: !Context,
    members :: ![FilePath],
    dispositions :: ![(ScaffoldModule, ModuleProvenance, WriteDisposition)],
    buildManifestPath :: !FilePath,
    recordPath :: !FilePath,
    -- | The manifest file name the previous workspace record was written from,
    --     when it differs from this run's.
    previousManifest :: !(Maybe Text),
    stale :: ![StaleModule],
    ownershipMoves :: ![OwnershipMove],
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
    sourceLanguageDrift :: ![WorkspaceSourceLanguageDrift],
    newHoles :: ![BindingHole],
    addedBehavior :: ![BehaviorRecordRow],
    removedBehavior :: ![BehaviorRecordRow],
    obsoleteOutputHooks :: ![(Text, Text)],
    -- | Declarations in the merged service that produce no generated module.
    --     Same content, same rendering as the single-spec
    --     'Keiro.Dsl.ScaffoldRun.reportInertNodes'.
    inertNodes :: ![(Text, Text)],
    conformancePackage :: !(Maybe ConformancePackageReport),
    nameMoves :: ![SourceMove],
    sidecarMoves :: ![SidecarMove],
    -- | Present only on the run that adopted pre-workspace scaffold output.
    migration :: !(Maybe MigrationReport)
  }
  deriving stock (Eq, Show)

-- | Execute a planned whole-workspace scaffold.
--
-- The shape mirrors 'Keiro.Dsl.ScaffoldRun.executeScaffold' step for step, with
-- three differences that matter:
--
--   * Both preflights — stranded golden fixtures and Generated paths lacking the
--     @-- \@generated@ banner — are evaluated over the __complete__ workspace set
--     before the output directory is created or any file is touched. A bannerless
--     file under any member's subtree therefore refuses the whole run, and a
--     refused run leaves the tree, the record, and the build manifest untouched.
--
--   * History is read from and written to the workspace-keyed record, so stale
--     detection compares whole workspaces. A module produced by a sibling member
--     is in the current set and can no longer be a false positive — the defect
--     that made two same-context specs report each other's files as stale.
--
--   * A Generated module whose bytes already match is reported 'Unchanged' and
--     not rewritten, which is what makes idempotence observable rather than
--     merely claimed.
executeWorkspaceScaffold :: FilePath -> Bool -> WorkspacePlan -> IO (Either [Refusal] WorkspaceScaffoldReport)
executeWorkspaceScaffold out forceGeneratedOverwrite =
  executeWorkspaceScaffoldWithNameMigrations out forceGeneratedOverwrite False

executeWorkspaceScaffoldWithNameMigrations :: FilePath -> Bool -> Bool -> WorkspacePlan -> IO (Either [Refusal] WorkspaceScaffoldReport)
executeWorkspaceScaffoldWithNameMigrations out forceGeneratedOverwrite applyNameMigrations =
  executeWorkspaceScaffoldWithMigrations out forceGeneratedOverwrite applyNameMigrations False

executeWorkspaceScaffoldWithMigrations :: FilePath -> Bool -> Bool -> Bool -> WorkspacePlan -> IO (Either [Refusal] WorkspaceScaffoldReport)
executeWorkspaceScaffoldWithMigrations out forceGeneratedOverwrite applyNameMigrations applyGeneratedHaskellEdition plan = do
  sidecarResult <- planSidecarMigrations out (WorkspaceSidecars service) ((.conformancePackage) plan)
  case sidecarResult of
    Left reasons -> pure (Left [SidecarMigrationRefusal reasons])
    Right preparedSidecars -> do
      previousBefore <- readMigrationRecord
      editionBefore <- preflightEdition previousBefore
      case editionBefore of
        Left refusals -> pure (Left refusals)
        Right preparedBefore
          | not (null preparedSidecars) && not applyNameMigrations ->
              pure . Left $
                [SidecarMigrationRequired (map (.sidecarMove) preparedSidecars)]
                  <> [GeneratedHaskellEditionRequired ((.impact) prepared) | Just prepared <- [preparedBefore]]
          | otherwise -> do
              applyPreparedSidecarMoves out preparedSidecars
              -- Past this point the renames are on disk, so a later
              -- refusal's "nothing was written" needs qualifying. Mirrors the single-spec path.
              let sidecarMoves = map (.sidecarMove) preparedSidecars
                  noteApplied = withSidecarMovesApplied sidecarMoves
              previousAfter <- if null preparedSidecars then pure previousBefore else readWorkspaceRecord recordPath
              editionAfter <- preflightEdition previousAfter
              result <- case editionAfter of
                Left refusals -> pure (Left refusals)
                Right preparedEdition -> case planWorkspaceSourceMoves (ledgerToMaybe previousAfter) modules of
                  Left moveErrors -> pure (Left [NameMigrationRefusal [T.pack (show moveError) | moveError <- NE.toList moveErrors]])
                  Right moves -> do
                    preparedMoves <- preflightSourceMoves out moves
                    case preparedMoves of
                      Left moveErrors -> pure (Left [NameMigrationRefusal moveErrors])
                      Right prepared
                        | Just edition <- editionWithMoves,
                          (not (null prepared) || not (null sidecarMoves)),
                          not (applyNameMigrations && applyGeneratedHaskellEdition) ->
                            pure (Left [NameMigrationRequired sourceMoves, GeneratedHaskellEditionRequired ((.impact) edition)])
                        | Just edition <- editionWithMoves,
                          not applyGeneratedHaskellEdition ->
                            pure (Left [GeneratedHaskellEditionRequired ((.impact) edition)])
                        | not (null prepared) && not applyNameMigrations -> pure (Left [NameMigrationRequired sourceMoves])
                        | otherwise ->
                            executeWorkspaceScaffoldBase
                              out
                              forceGeneratedOverwrite
                              editionWithMoves
                              sidecarMoves
                              sourceMoves
                              prepared
                              plan
                        where
                          sourceMoves = map preparedSourceMove prepared
                          editionWithMoves = withGeneratedHaskellEditionSourceMoves sourceMoves preparedEdition
              pure (either (Left . noteApplied) Right result)
  where
    modules = map fst ((.modules) plan)
    service = (.service) ((.workspace) plan)
    recordPath = out </> workspaceRecordFileName service
    legacyRecordPath = out </> legacyWorkspaceRecordFileName service
    readMigrationRecord = do
      current <- readWorkspaceRecord recordPath
      case current of
        LedgerAbsent -> readWorkspaceRecord legacyRecordPath
        _ -> pure current
    preflightEdition previousRead = case previousRead of
      LedgerReadUnreadable path -> pure (Left [LedgerUnreadable path])
      _ -> do
        let previous = ledgerToMaybe previousRead
        prepared <-
          preflightGeneratedHaskellEditionMigration
            out
            ((.namingEdition) <$> previous)
            [((.kind) row, (.path) row) | row <- maybe [] (.modules) previous]
            [workspaceManifestFileName service, workspaceRecordFileName service]
        pure (either (Left . pure . GeneratedHaskellEditionRefusal) Right prepared)

planWorkspaceSourceMoves :: Maybe WorkspaceRecord -> [ScaffoldModule] -> Either (NE.NonEmpty SourceMoveError) [SourceMove]
planWorkspaceSourceMoves previous current =
  case previous of
    Nothing -> Right []
    Just record ->
      planSourceMoves
        [((.role) row, (.kind) row, (.path) row) | row <- (.modules) record]
        current

executeWorkspaceScaffoldBase :: FilePath -> Bool -> Maybe PreparedGeneratedHaskellEditionMigration -> [SidecarMove] -> [SourceMove] -> [PreparedSourceMove] -> WorkspacePlan -> IO (Either [Refusal] WorkspaceScaffoldReport)
executeWorkspaceScaffoldBase out forceGeneratedOverwrite editionMigration sidecarMoves nameMoves preparedNameMoves plan = do
  previousRead <- readWorkspaceRecord recordPath
  stranded <- goldenRootDivergence ((.goldenRoot) plan) workspace
  bannerless <- if forceGeneratedOverwrite then pure [] else missingGeneratedBanners out modules
  packagePreflight <- case (.conformancePackage) plan of
    Nothing -> pure (Right Nothing)
    Just packagePlan -> fmap (fmap Just) (preflightConformancePackage out forceGeneratedOverwrite packagePlan)
  let previous = ledgerToMaybe previousRead
      ledgerRefusals = case previousRead of
        LedgerReadUnreadable path -> [LedgerUnreadable path]
        _ -> []
      packageRefusals = either (map ConformancePackageRefusal) (const []) packagePreflight
  case ledgerRefusals <> stranded <> [MissingGeneratedBanner bannerless | not (null bannerless)] <> packageRefusals of
    refusals@(_ : _) -> pure (Left refusals)
    [] -> do
      applyPreparedGeneratedHaskellEditionMigration out editionMigration
      applyPreparedSourceMoves out preparedNameMoves
      stale <- staleAgainst out (map (.path) modules) (previousFiles previous)
      queryMigrations <- queryContractMigrations out modules
      -- Adoption is a one-shot, guarded by the absence of workspace
      -- history: once this workspace owns the directory there is nothing
      -- left to import, and the migration report stays as written.
      migration <- case previous of
        Just _ -> pure Nothing
        Nothing -> adoptionReport out ((.context) workspace) service modules
      let currentPlan = consumerPlanForService ((.checkedService) plan)
          drift = maybe [] (mappingDrift ((.mappings) currentPlan) . (.mappings)) previous
          currentSemanticImpact = checkedSemanticImpactSnapshot ((.checkedService) plan)
          semanticReport = semanticImpactForMappingDrift (previous >>= (.semanticImpact)) currentSemanticImpact drift
          currentRouterSelections = routerSelectionSnapshots ((.checkedService) plan)
          selectionDrift = maybe [] (\record -> routerSelectionDrift ((.routerSelections) record) currentRouterSelections) previous
          languageDrift = workspaceSourceLanguageDrift workspace previous
          currentQueryContracts = either (const []) id (queryContractIdentitiesForService ((.checkedService) plan))
          queryHistoryBaseline =
            not (null currentQueryContracts)
              || maybe False (.queryContractBaseline) previous
          queryBaselineUnavailable =
            not (null currentQueryContracts)
              && maybe False (not . (.queryContractBaseline)) previous
          queryDrift = case previous of
            Just record | (.queryContractBaseline) record -> queryContractDrift currentQueryContracts ((.queryContracts) record)
            _ -> []
          currentObligations = either (const []) id (bindingHolesForService ((.checkedService) plan))
          newHoles = maybe [] (newBindingObligations currentObligations . (.bindingObligations)) previous
          currentBehavior = workspaceBehaviorRows ((.checkedService) plan) workspace
          (addedBehavior, removedBehavior) = maybe (currentBehavior, []) (behaviorDrift currentBehavior . (.requirements)) previous
      createDirectoryIfMissing True out
      dispositions <- traverse (writeWorkspaceModule out) ((.modules) plan)
      TIO.writeFile buildManifestPath (renderManifestForServiceWithFacade facadeModule (T.pack manifestName) modules ((.checkedService) plan))
      -- Adoption provenance is durable history, not a one-run note: a
      -- later run that adopts nothing carries the previous rows forward,
      -- or the record would silently forget where its files came from.
      let adopted = case migration of
            Just report -> adoptedRows report
            Nothing -> maybe [] (.adopted) previous
      TIO.writeFile recordPath (renderWorkspaceRecord (currentWorkspaceRecord plan adopted queryHistoryBaseline currentSemanticImpact))
      packageReport <- case packagePreflight of
        Right prepared -> traverse executePreparedConformancePackage prepared
        Left _ -> pure Nothing
      case migration of
        Nothing -> pure ()
        Just report -> do
          TIO.writeFile
            (out </> workspaceMigrationReportFileName service)
            (T.unlines (renderMigrationReport report))
          markLegacyRecordSuperseded out ((.context) workspace) service
      pure $
        Right
          WorkspaceScaffoldReport
            { manifestPath = (.manifestPath) workspace,
              outDir = out,
              service = (.service) workspace,
              context = (.context) plan,
              members = map (.path) ((.members) workspace),
              dispositions = dispositions,
              buildManifestPath = buildManifestPath,
              recordPath = recordPath,
              previousManifest = do
                record <- previous
                if (.manifest) record == T.pack manifestName then Nothing else Just ((.manifest) record),
              stale = stale,
              ownershipMoves = ownershipMoves previous ((.modules) plan),
              consumerPlan = currentPlan,
              constraintPlan = constraintPlanForService ((.checkedService) plan) currentPlan,
              mappingDrift = drift,
              queryContractBaselineUnavailable = queryBaselineUnavailable,
              queryContractDrift = queryDrift,
              queryContractMigrations = queryMigrations,
              semanticImpact = semanticReport,
              routerSelectionDrift = selectionDrift,
              projectionMappedImpact = projectionMappedImpactForService ((.checkedService) plan),
              generatedArtifactImpact = generatedArtifactImpact [(scaffoldModule, disposition) | (scaffoldModule, _, disposition) <- dispositions],
              sourceLanguageDrift = languageDrift,
              newHoles = newHoles,
              addedBehavior = addedBehavior,
              removedBehavior = removedBehavior,
              obsoleteOutputHooks = obsoleteGeneratedOutputHooksForService ((.checkedService) plan),
              inertNodes = inertNodesOf merged,
              conformancePackage = packageReport,
              nameMoves = nameMoves,
              sidecarMoves = sidecarMoves,
              migration = migration
            }
  where
    workspace = (.workspace) plan
    merged = checkedSpec ((.checkedService) plan)
    modules = map fst ((.modules) plan)
    service = (.service) workspace
    manifestName = takeFileName ((.manifestPath) workspace)
    recordPath = out </> workspaceRecordFileName service
    buildManifestPath = out </> workspaceManifestFileName service
    facadeModule = case (.runtimePackage) plan of
      Nothing -> Nothing
      Just _ -> Just (serviceConformanceModuleName ((.context) plan))
    previousFiles previous = [((.kind) row, (.path) row) | row <- maybe [] (.modules) previous]

readWorkspaceRecord :: FilePath -> IO (LedgerRead WorkspaceRecord)
readWorkspaceRecord path = do
  exists <- doesFileExist path
  if not exists
    then pure LedgerAbsent
    else do
      parsed <- parseWorkspaceRecord <$> TIO.readFile path
      pure (maybe (LedgerReadUnreadable path) LedgerParsed parsed)

-- | The record this run writes: the plan's modules with their owners, the
-- canonical member list, the merged graph's mappings and obligations, and any
-- files adopted from pre-workspace scaffold output.
currentWorkspaceRecord :: WorkspacePlan -> [AdoptedRow] -> Bool -> SemanticImpactSnapshot -> WorkspaceRecord
currentWorkspaceRecord plan adopted queryHistoryBaseline currentSemanticImpact =
  WorkspaceRecord
    { service = (.service) workspace,
      manifest = T.pack (takeFileName ((.manifestPath) workspace)),
      context = (.context) workspace,
      moduleRoot = (.moduleRoot) ctx,
      layout = layoutLabel ctx,
      members = map (.path) ((.members) workspace),
      sourceLanguages =
        [ WorkspaceSourceLanguageRow ((.path) member) ((.sourceLanguage) member)
        | member <- (.members) workspace
        ],
      languageContract = checkedLanguageContract ((.checkedService) plan),
      namingEdition = currentGeneratedHaskellNamingEdition,
      modules =
        [ WorkspaceModuleRow
            { kind = (.kind) m,
              path = (.path) m,
              owner = provenanceOwner provenance,
              role = Just (moduleRole m)
            }
        | (m, provenance) <- (.modules) plan
        ],
      mappings = (.mappings) (consumerPlanForService checkedService),
      idDomains = idDomainIdentitiesForService checkedService,
      nominalEqualities = nominalEqualityIdentitiesForService checkedService,
      bindingObligations = either (const []) id (bindingHolesForService checkedService),
      requirements = workspaceBehaviorRows checkedService workspace,
      projectionCatalogFacts = projectionCatalogFactsForService checkedService,
      queryContractBaseline = queryHistoryBaseline,
      queryContracts = either (const []) id (queryContractIdentitiesForService checkedService),
      routerSelections = routerSelectionSnapshots checkedService,
      adopted = adopted,
      semanticImpact = Just currentSemanticImpact
    }
  where
    workspace = (.workspace) plan
    checkedService = (.checkedService) plan
    ctx = (.context) plan

workspaceBehaviorRows :: CheckedService -> WorkspaceSpec -> [BehaviorRecordRow]
workspaceBehaviorRows service workspace =
  either (const []) (behaviorRecordRows . map attribute) (deriveBehaviorRequirementsForService service)
  where
    attribute = attributeBehaviorOwner (fmap fst . nodeOwner ((.ownership) workspace) "aggregate")

workspaceSourceLanguageDrift :: WorkspaceSpec -> Maybe WorkspaceRecord -> [WorkspaceSourceLanguageDrift]
workspaceSourceLanguageDrift workspace previous =
  [ WorkspaceSourceLanguageDrift path oldLanguage newLanguage
  | member <- (.members) workspace,
    let path = (.path) member
        newLanguage = (.sourceLanguage) member,
    Just oldLanguage <- [Map.lookup path previousByPath],
    oldLanguage /= newLanguage
  ]
  where
    previousByPath =
      Map.fromList
        [ ((.path) row, (.sourceLanguage) row)
        | row <- maybe [] (.sourceLanguages) previous
        ]

layoutLabel :: Context -> Text
layoutLabel ctx = case (.placement) ctx of GeneratedPrefix -> "prefixed"; CollocatedLeaf -> "collocated"

-- | Paths this run still produces whose owning member changed. Computed against
-- the previous record before stale detection, and never overlapping it: a moved
-- module's path is still in the current plan, so it was never a removal.
ownershipMoves :: Maybe WorkspaceRecord -> [(ScaffoldModule, ModuleProvenance)] -> [OwnershipMove]
ownershipMoves previous current =
  [ OwnershipMove
      { path = (.path) m,
        previous = (.owner) row,
        current = provenanceOwner provenance
      }
  | (m, provenance) <- current,
    Just row <- [Map.lookup ((.path) m) previousByPath],
    (.owner) row /= provenanceOwner provenance
  ]
  where
    previousByPath = Map.fromList [((.path) row, row) | row <- maybe [] (.modules) previous]

-- | Write one module. Generated modules whose bytes already match are left
-- alone and reported 'Unchanged'; hole modules keep the create-once rule. The
-- single-spec 'Keiro.Dsl.ScaffoldRun.executeScaffold' is untouched, so its report
-- bytes are unaffected.
writeWorkspaceModule ::
  FilePath ->
  (ScaffoldModule, ModuleProvenance) ->
  IO (ScaffoldModule, ModuleProvenance, WriteDisposition)
writeWorkspaceModule out (m, provenance) = do
  let path = out </> (.path) m
  exists <- doesFileExist path
  case (.kind) m of
    HoleStub
      | exists -> pure (m, provenance, Skipped)
      | otherwise -> write path Created
    Generated
      | exists -> do
          existing <- TIO.readFile path
          if existing == (.text) m
            then pure (m, provenance, Unchanged)
            else write path Overwritten
      | otherwise -> write path Overwritten
  where
    write path disposition = do
      createDirectoryIfMissing True (takeDirectory path)
      TIO.writeFile path ((.text) m)
      pure (m, provenance, disposition)

-- | The report a successful whole-workspace scaffold prints, following the
-- single-spec report's shape so the two stay readable side by side: the header
-- names the service instead of a spec, each module line carries its owning member,
-- and the stale section keeps the exact "keiro-dsl never deletes files." sentence.
renderWorkspaceScaffoldReport :: WorkspaceScaffoldReport -> [Text]
renderWorkspaceScaffoldReport report =
  [ "workspace: "
      <> (.service) report
      <> " ("
      <> T.pack ((.manifestPath) report)
      <> ") -> "
      <> T.pack ((.outDir) report)
      <> " (module-root="
      <> rootLabel
      <> ", layout="
      <> layoutLabel ctx
      <> ")",
    "members:  " <> T.intercalate ", " (map T.pack ((.members) report))
  ]
    <> map moduleLine dispositions
    <> [ "firewall: OK (" <> tshow generatedCount <> " generated modules scanned, 0 forbidden operators)",
         harnessLine,
         dependencyLine,
         "fragment: " <> T.pack ((.buildManifestPath) report),
         "ledger:   " <> T.pack ((.recordPath) report)
       ]
    <> previousManifestNote
    <> migrationSection
    <> sidecarMoveSection
    <> nameMoveSection
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
    <> renderInertNodeSection ((.inertNodes) report)
    <> ownershipSection
    <> staleSection
    <> maybe [] renderConformancePackageReport ((.conformancePackage) report)
  where
    ctx = (.context) report
    dispositions = (.dispositions) report
    rootLabel = if T.null ((.moduleRoot) ctx) then "(none)" else (.moduleRoot) ctx
    names = [moduleNameOf ((.path) m) | (m, _, _) <- dispositions]
    nameWidth = maximum (1 : map T.length names)
    moduleLine (m, provenance, disposition) =
      "  "
        <> kindTag ((.kind) m)
        <> "  "
        <> pad (moduleNameOf ((.path) m))
        <> "  "
        <> dispositionTag disposition
        <> "  "
        <> ownerTag provenance
    kindTag Generated = "generated"
    kindTag HoleStub = "hole     "
    dispositionTag Overwritten = "(overwritten)"
    dispositionTag Created = "(created)"
    dispositionTag Skipped = "(skipped: already present)"
    dispositionTag Unchanged = "(unchanged)"
    ownerTag ContextLevel = "(context-level)"
    ownerTag (MemberOwned path) = T.pack path
    pad name = name <> T.replicate (nameWidth - T.length name) " "
    generatedCount = length [() | (m, _, _) <- dispositions, (.kind) m == Generated]
    harnesses =
      sortOn
        id
        [ moduleNameOf ((.path) m)
        | (m, _, _) <- dispositions,
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
    previousManifestNote = case (.previousManifest) report of
      Just previous -> ["note: the previous workspace record was written from manifest " <> previous]
      Nothing -> []
    migrationSection = maybe [] renderMigrationReport ((.migration) report)
    sidecarMoveSection = case (.sidecarMoves) report of
      [] -> []
      moves ->
        ["sidecar migration: applied (" <> tshow (length moves) <> " move(s))"]
          <> map (("  " <>) . renderSidecarMove) moves
    nameMoveSection = case (.nameMoves) report of
      [] -> []
      moves ->
        ["name migration: applied (" <> tshow (length moves) <> " source move(s))"]
          <> [ "  "
                 <> T.pack ((.oldPath) move)
                 <> " -> "
                 <> T.pack ((.newPath) move)
                 <> "  backup="
                 <> T.pack ((.backupPath) move)
             | move <- moves
             ]
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
          <> concatMap queryMigrationLines migrations
    queryMigrationLines migration =
      [ "  " <> (.owner) migration,
        "    edit " <> T.pack ((.path) migration),
        "    remove the local QueryInput/QueryResult type aliases",
        "    add " <> (.requiredImport) migration
      ]
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
      [] -> []
      drifts ->
        ["source-language drift: " <> tshow (length drifts) <> " member(s) changed provenance (generated module bytes are semantic and unaffected):"]
          <> [ "  "
                 <> T.pack ((.path) drift)
                 <> "  "
                 <> workspaceSourceLanguageLabel ((.previous) drift)
                 <> " -> "
                 <> workspaceSourceLanguageLabel ((.current) drift)
             | drift <- drifts
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
          <> (.unBehaviorKey) ((.key) row)
          <> maybe "" (("  owner=" <>) . T.pack) ((.owner) row),
        "    Pending (BehaviorKey " <> tshow ((.unBehaviorKey) ((.key) row)) <> ")"
      ]
    obsoleteOutputSection = case (.obsoleteOutputHooks) report of
      [] -> []
      hooks ->
        ["obsolete identity-copy output hooks (if still present, they are unused and may be removed):"]
          <> ["  " <> aggregate <> ".Holes." <> hook | (aggregate, hook) <- hooks]
    ownershipSection = case (.ownershipMoves) report of
      [] -> []
      moves ->
        ["ownership moves: " <> tshow (length moves) <> " module(s) changed owning member (content unaffected):"]
          <> [ "  " <> T.pack ((.path) move) <> "  " <> ownerName ((.previous) move) <> " -> " <> ownerName ((.current) move)
             | move <- moves
             ]
    ownerName = maybe "(context-level)" T.pack
    staleSection = case (.stale) report of
      [] -> []
      stale ->
        [ "stale: "
            <> tshow (length stale)
            <> " file(s) from a previous scaffold of workspace "
            <> (.service) report
            <> " are no longer produced by this workspace:"
        ]
          <> map staleLine stale
          <> ["note: keiro-dsl never deletes files."]
    staleLine stale = case ((.kind) stale, (.generatedEvidence) stale) of
      (Generated, Just ExactGeneratedBannerPresent) ->
        "  generated " <> T.pack ((.path) stale) <> "  (exact generated banner present; verify unchanged bytes before deleting)"
      (Generated, _) ->
        "  generated " <> T.pack ((.path) stale) <> "  (exact generated banner missing; preserve and review)"
      (HoleStub, _) -> "  hole      " <> T.pack ((.path) stale) <> "  (hand-owned — preserve and review)"

workspaceSourceLanguageLabel :: SourceLanguage -> Text
workspaceSourceLanguageLabel sourceLanguage =
  sourceFormText sourceLanguage
    <> "/effective-v"
    <> languageVersionText (effectiveLanguageVersion sourceLanguage)

renderBracketed :: [Text] -> Text
renderBracketed values = "[" <> T.intercalate ", " values <> "]"

tshow :: (Show a) => a -> Text
tshow = T.pack . show
