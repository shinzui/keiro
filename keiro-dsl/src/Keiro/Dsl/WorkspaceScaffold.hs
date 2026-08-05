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
    renderWorkspaceScaffoldReport,
  )
where

import Data.List (nub, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.BehaviorCoverage (BehaviorKey (..), BehaviorRecordRow (..), attributeBehaviorOwner, behaviorRecordRows, deriveBehaviorRequirements)
import Keiro.Dsl.ConformancePackage
  ( ConformancePackagePlan,
    ConformancePackageReport,
    ConformanceServiceKey (WorkspaceConformanceService),
    executePreparedConformancePackage,
    planConformancePackage,
    preflightConformancePackage,
    renderConformancePackageReport,
  )
import Keiro.Dsl.ExplainBindings (BindingHole (..), bindingHolesForService)
import Keiro.Dsl.Goldens (GoldenPayload)
import Keiro.Dsl.Grammar
import Keiro.Dsl.Harness (harnessForServiceWithGoldens, harnessProcess, harnessReadModel, harnessRouter, harnessWorkflow)
import Keiro.Dsl.HaskellName (currentGeneratedHaskellNamingEdition)
import Keiro.Dsl.HaskellSourceMove (SourceMove (..), SourceMoveError, planSourceMoves)
import Keiro.Dsl.IdDomain (idDomainIdentitiesForService)
import Keiro.Dsl.LanguageVersion (SourceLanguage, effectiveLanguageVersion, languageVersionText, sourceFormText)
import Keiro.Dsl.Manifest (moduleNameOf, renderManifestForServiceWithFacade)
import Keiro.Dsl.MappedConsumer (ConsumerPlan (..), consumerPlan)
import Keiro.Dsl.NominalType (nominalEqualityIdentitiesForService)
import Keiro.Dsl.RuntimePackage (RuntimePackageName)
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRun
  ( MappingDrift (..),
    PreparedSourceMove,
    Refusal (..),
    StaleGeneratedEvidence (..),
    StaleModule (..),
    WriteDisposition (..),
    applyPreparedSourceMoves,
    behaviorDrift,
    constraintPlan,
    mappingDrift,
    missingGeneratedBanners,
    newBindingObligations,
    obligationKindLabel,
    planningGatePipeline,
    preflightSourceMoves,
    preparedSourceMove,
    renderMappingIdentity,
    staleAgainst,
  )
import Keiro.Dsl.SemanticContract (CheckedService (..))
import Keiro.Dsl.ServiceHarness (DuplicateServiceFactKey, serviceConformanceModuleName, serviceHarnessModule)
import Keiro.Dsl.SidecarMigration
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
  { wpWorkspace :: !WorkspaceSpec,
    wpCheckedService :: !CheckedService,
    wpContext :: !Context,
    wpRuntimePackage :: !(Maybe RuntimePackageName),
    wpConformancePackage :: !(Maybe ConformancePackagePlan),
    -- | The one golden-payload root for the whole workspace. Carried here so
    --     execution can refuse a member-adjacent fixture the root lacks before it
    --     writes anything.
    wpGoldenRoot :: !FilePath,
    wpModules :: ![(ScaffoldModule, ModuleProvenance)]
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
  planWorkspaceScaffoldWithRuntimePackageAndGoldens goldens (wsRuntimePackage workspace) goldenRoot ctx workspace

planWorkspaceScaffoldWithRuntimePackageAndGoldens ::
  [GoldenPayload] ->
  Maybe RuntimePackageName ->
  FilePath ->
  Context ->
  WorkspaceSpec ->
  Either [Refusal] WorkspacePlan
planWorkspaceScaffoldWithRuntimePackageAndGoldens goldens runtimePackage goldenRoot ctx workspace =
  case planningGatePipeline ctx service modulePlan packageGate of
    Left refusals -> Left refusals
    Right _ -> case taggedModules of
      Left duplicates -> Left [DuplicateConformanceFactKeys duplicates]
      Right tagged -> case packagePlan of
        Left failures -> Left (map ConformancePackageRefusal failures)
        Right plannedPackage ->
          Right
            WorkspacePlan
              { wpWorkspace = workspace,
                wpCheckedService = service,
                wpContext = ctx,
                wpRuntimePackage = runtimePackage,
                wpConformancePackage = plannedPackage,
                wpGoldenRoot = goldenRoot,
                wpModules = tagged
              }
  where
    service = checkedWorkspace workspace
    taggedModules = workspaceModules goldens runtimePackage ctx workspace
    modulePlan = case taggedModules of
      Left duplicates -> Left [DuplicateConformanceFactKeys duplicates]
      Right tagged -> Right (map fst tagged)
    packagePlan =
      traverse
        (\packageName -> planConformancePackage (WorkspaceConformanceService (wsService workspace)) packageName (serviceConformanceModuleName ctx) service)
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
workspaceModules :: [GoldenPayload] -> Maybe RuntimePackageName -> Context -> WorkspaceSpec -> Either [DuplicateServiceFactKey] [(ScaffoldModule, ModuleProvenance)]
workspaceModules goldens runtimePackage ctx workspace = do
  facade <- case runtimePackage of
    Nothing -> Right []
    Just _ -> fmap (\moduleValue -> [(stamp moduleValue, ContextLevel)]) (serviceHarnessModule ctx service)
  pure $
    [attributedStamped (declarationProvenance names) m | (m, names) <- scaffoldStructuralOwnersForService ctx service]
      <> [attributedStamped ContextLevel m | m <- scaffoldReplayAudit ctx merged]
      <> concat
        [ map (attributedStamped (nodeProvenance node)) (emittersFor node)
        | node <- specNodes merged
        ]
      <> facade
  where
    service = checkedWorkspace workspace
    merged = checkedSpec service
    ownership = wsOwnership workspace
    stamp = stampGeneratedModule (checkedLanguageContract service)
    attributedStamped provenance moduleValue =
      let (annotated, attribution) = attributed provenance moduleValue
       in (stamp annotated, attribution)

    emittersFor node = case node of
      NAggregate aggregate -> scaffoldAggregateForService ctx service aggregate <> harnessForServiceWithGoldens goldens ctx service aggregate
      NProcess process -> scaffoldProcess ctx process <> harnessProcess ctx process
      NRouter router -> scaffoldRouter ctx router <> harnessRouter ctx router
      NContract contract -> scaffoldContractForService ctx service contract
      NIntake intake -> scaffoldIntake ctx intake
      NPublisher publisher -> scaffoldPublisher ctx publisher
      NWorkqueue workqueue -> scaffoldWorkqueue ctx workqueue
      NReadModel readModel -> scaffoldReadModel ctx readModel <> harnessReadModel ctx readModel
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
      | length (wsMembers workspace) > 1 = m {origin = T.pack path <> ": " <> origin m}
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
  stranded <- concat <$> traverse strandedFor (wsMembers workspace)
  pure [GoldenRootDivergence workspaceRoot stranded | not (null stranded)]
  where
    manifestDir = takeDirectory (wsManifestPath workspace)
    strandedFor member = concat <$> traverse (check member) (upcastFixtures (wmSpec member))
    check member relative = do
      let memberRoot = manifestDir </> takeDirectory (wmPath member) </> "golden-payloads"
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
  [ T.unpack (specContext spec) </> T.unpack (aggName aggregate) </> fixtureName event sourceVersion
  | NAggregate aggregate <- specNodes spec,
    event <- aggEvents aggregate,
    Just (sourceVersion, _) <- [evUpcastFrom event]
  ]
  where
    fixtureName event sourceVersion = T.unpack (evName event) <> ".v" <> show sourceVersion <> ".json"

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
  { omPath :: !FilePath,
    omPrevious :: !(Maybe FilePath),
    omCurrent :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show)

data WorkspaceSourceLanguageDrift = WorkspaceSourceLanguageDrift
  { wsldPath :: !FilePath,
    wsldPrevious :: !SourceLanguage,
    wsldCurrent :: !SourceLanguage
  }
  deriving stock (Eq, Show)

-- | What one successful whole-workspace scaffold did.
data WorkspaceScaffoldReport = WorkspaceScaffoldReport
  { wsrManifestPath :: !FilePath,
    wsrOutDir :: !FilePath,
    wsrService :: !Text,
    wsrContext :: !Context,
    wsrMembers :: ![FilePath],
    wsrDispositions :: ![(ScaffoldModule, ModuleProvenance, WriteDisposition)],
    wsrBuildManifestPath :: !FilePath,
    wsrRecordPath :: !FilePath,
    -- | The manifest file name the previous workspace record was written from,
    --     when it differs from this run's.
    wsrPreviousManifest :: !(Maybe Text),
    wsrStale :: ![StaleModule],
    wsrOwnershipMoves :: ![OwnershipMove],
    wsrConsumerPlan :: !ConsumerPlan,
    wsrConstraintPlan :: ![Text],
    wsrMappingDrift :: ![MappingDrift],
    wsrSourceLanguageDrift :: ![WorkspaceSourceLanguageDrift],
    wsrNewHoles :: ![BindingHole],
    wsrAddedBehavior :: ![BehaviorRecordRow],
    wsrRemovedBehavior :: ![BehaviorRecordRow],
    wsrObsoleteOutputHooks :: ![(Text, Text)],
    wsrConformancePackage :: !(Maybe ConformancePackageReport),
    wsrNameMoves :: ![SourceMove],
    wsrSidecarMoves :: ![SidecarMove],
    -- | Present only on the run that adopted pre-workspace scaffold output.
    wsrMigration :: !(Maybe MigrationReport)
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
executeWorkspaceScaffoldWithNameMigrations out forceGeneratedOverwrite applyNameMigrations plan = do
  sidecarResult <- planSidecarMigrations out (WorkspaceSidecars (wsService (wpWorkspace plan))) (wpConformancePackage plan)
  case sidecarResult of
    Left reasons -> pure (Left [SidecarMigrationRefusal reasons])
    Right preparedSidecars
      | not (null preparedSidecars) && not applyNameMigrations ->
          pure (Left [SidecarMigrationRequired (map preparedSidecarMove preparedSidecars)])
      | otherwise -> do
          applyPreparedSidecarMoves out preparedSidecars
          previous <- readWorkspaceRecord recordPath
          case planWorkspaceSourceMoves previous modules of
            Left moveErrors -> pure (Left [NameMigrationRefusal [T.pack (show moveError) | moveError <- NE.toList moveErrors]])
            Right moves -> do
              preparedMoves <- preflightSourceMoves out moves
              case preparedMoves of
                Left moveErrors -> pure (Left [NameMigrationRefusal moveErrors])
                Right prepared
                  | not (null prepared) && not applyNameMigrations -> pure (Left [NameMigrationRequired (map preparedSourceMove prepared)])
                  | otherwise ->
                      executeWorkspaceScaffoldBase
                        out
                        forceGeneratedOverwrite
                        (map preparedSidecarMove preparedSidecars)
                        (map preparedSourceMove prepared)
                        prepared
                        plan
  where
    modules = map fst (wpModules plan)
    recordPath = out </> workspaceRecordFileName (wsService (wpWorkspace plan))

planWorkspaceSourceMoves :: Maybe WorkspaceRecord -> [ScaffoldModule] -> Either (NE.NonEmpty SourceMoveError) [SourceMove]
planWorkspaceSourceMoves previous current =
  case previous of
    Nothing -> Right []
    Just record ->
      planSourceMoves
        [(wrmRole row, wrmKind row, wrmPath row) | row <- wrModules record]
        current

executeWorkspaceScaffoldBase :: FilePath -> Bool -> [SidecarMove] -> [SourceMove] -> [PreparedSourceMove] -> WorkspacePlan -> IO (Either [Refusal] WorkspaceScaffoldReport)
executeWorkspaceScaffoldBase out forceGeneratedOverwrite sidecarMoves nameMoves preparedNameMoves plan = do
  stranded <- goldenRootDivergence (wpGoldenRoot plan) workspace
  bannerless <- if forceGeneratedOverwrite then pure [] else missingGeneratedBanners out modules
  packagePreflight <- case wpConformancePackage plan of
    Nothing -> pure (Right Nothing)
    Just packagePlan -> fmap (fmap Just) (preflightConformancePackage out forceGeneratedOverwrite packagePlan)
  let packageRefusals = either (map ConformancePackageRefusal) (const []) packagePreflight
  case stranded <> [MissingGeneratedBanner bannerless | not (null bannerless)] <> packageRefusals of
    refusals@(_ : _) -> pure (Left refusals)
    [] -> do
      applyPreparedSourceMoves out preparedNameMoves
      previous <- readWorkspaceRecord recordPath
      stale <- staleAgainst out (map modulePath modules) (previousFiles previous)
      -- Adoption is a one-shot, guarded by the absence of workspace
      -- history: once this workspace owns the directory there is nothing
      -- left to import, and the migration report stays as written.
      migration <- case previous of
        Just _ -> pure Nothing
        Nothing -> adoptionReport out (wsContext workspace) service modules
      let currentPlan = consumerPlan merged
          drift = maybe [] (mappingDrift (consumerMappings currentPlan) . wrMappings) previous
          languageDrift = workspaceSourceLanguageDrift workspace previous
          currentObligations = either (const []) id (bindingHolesForService (wpCheckedService plan))
          newHoles = maybe [] (newBindingObligations currentObligations . wrBindingObligations) previous
          currentBehavior = workspaceBehaviorRows workspace
          (addedBehavior, removedBehavior) = maybe (currentBehavior, []) (behaviorDrift currentBehavior . wrBehaviorRequirements) previous
      createDirectoryIfMissing True out
      dispositions <- traverse (writeWorkspaceModule out) (wpModules plan)
      TIO.writeFile buildManifestPath (renderManifestForServiceWithFacade facadeModule (T.pack manifestName) modules (wpCheckedService plan))
      -- Adoption provenance is durable history, not a one-run note: a
      -- later run that adopts nothing carries the previous rows forward,
      -- or the record would silently forget where its files came from.
      let adopted = case migration of
            Just report -> adoptedRows report
            Nothing -> maybe [] wrAdopted previous
      TIO.writeFile recordPath (renderWorkspaceRecord (currentWorkspaceRecord plan adopted))
      packageReport <- case packagePreflight of
        Right prepared -> traverse executePreparedConformancePackage prepared
        Left _ -> pure Nothing
      case migration of
        Nothing -> pure ()
        Just report -> do
          TIO.writeFile
            (out </> workspaceMigrationReportFileName service)
            (T.unlines (renderMigrationReport report))
          markLegacyRecordSuperseded out (wsContext workspace) service
      pure $
        Right
          WorkspaceScaffoldReport
            { wsrManifestPath = wsManifestPath workspace,
              wsrOutDir = out,
              wsrService = wsService workspace,
              wsrContext = wpContext plan,
              wsrMembers = map wmPath (wsMembers workspace),
              wsrDispositions = dispositions,
              wsrBuildManifestPath = buildManifestPath,
              wsrRecordPath = recordPath,
              wsrPreviousManifest = do
                record <- previous
                if wrManifest record == T.pack manifestName then Nothing else Just (wrManifest record),
              wsrStale = stale,
              wsrOwnershipMoves = ownershipMoves previous (wpModules plan),
              wsrConsumerPlan = currentPlan,
              wsrConstraintPlan = constraintPlan merged currentPlan,
              wsrMappingDrift = drift,
              wsrSourceLanguageDrift = languageDrift,
              wsrNewHoles = newHoles,
              wsrAddedBehavior = addedBehavior,
              wsrRemovedBehavior = removedBehavior,
              wsrObsoleteOutputHooks = obsoleteGeneratedOutputHooks merged,
              wsrConformancePackage = packageReport,
              wsrNameMoves = nameMoves,
              wsrSidecarMoves = sidecarMoves,
              wsrMigration = migration
            }
  where
    workspace = wpWorkspace plan
    merged = checkedSpec (wpCheckedService plan)
    modules = map fst (wpModules plan)
    service = wsService workspace
    manifestName = takeFileName (wsManifestPath workspace)
    recordPath = out </> workspaceRecordFileName service
    buildManifestPath = out </> workspaceManifestFileName service
    facadeModule = case wpRuntimePackage plan of
      Nothing -> Nothing
      Just _ -> Just (serviceConformanceModuleName (wpContext plan))
    previousFiles previous = [(wrmKind row, wrmPath row) | row <- maybe [] wrModules previous]

readWorkspaceRecord :: FilePath -> IO (Maybe WorkspaceRecord)
readWorkspaceRecord path = do
  exists <- doesFileExist path
  if exists then parseWorkspaceRecord <$> TIO.readFile path else pure Nothing

-- | The record this run writes: the plan's modules with their owners, the
-- canonical member list, the merged graph's mappings and obligations, and any
-- files adopted from pre-workspace scaffold output.
currentWorkspaceRecord :: WorkspacePlan -> [AdoptedRow] -> WorkspaceRecord
currentWorkspaceRecord plan adopted =
  WorkspaceRecord
    { wrService = wsService workspace,
      wrManifest = T.pack (takeFileName (wsManifestPath workspace)),
      wrContext = wsContext workspace,
      wrModuleRoot = moduleRoot ctx,
      wrLayout = layoutLabel ctx,
      wrMembers = map wmPath (wsMembers workspace),
      wrSourceLanguages =
        [ WorkspaceSourceLanguageRow (wmPath member) (wmSourceLanguage member)
        | member <- wsMembers workspace
        ],
      wrLanguageContract = checkedLanguageContract (wpCheckedService plan),
      wrNamingEdition = currentGeneratedHaskellNamingEdition,
      wrModules =
        [ WorkspaceModuleRow
            { wrmKind = kind m,
              wrmPath = modulePath m,
              wrmOwner = provenanceOwner provenance,
              wrmRole = Just (moduleRole m)
            }
        | (m, provenance) <- wpModules plan
        ],
      wrMappings = consumerMappings (consumerPlan merged),
      wrIdDomains = idDomainIdentitiesForService checkedService,
      wrNominalEqualities = nominalEqualityIdentitiesForService checkedService,
      wrBindingObligations = either (const []) id (bindingHolesForService checkedService),
      wrBehaviorRequirements = workspaceBehaviorRows workspace,
      wrAdopted = adopted
    }
  where
    workspace = wpWorkspace plan
    checkedService = wpCheckedService plan
    merged = checkedSpec checkedService
    ctx = wpContext plan

workspaceBehaviorRows :: WorkspaceSpec -> [BehaviorRecordRow]
workspaceBehaviorRows workspace =
  either (const []) (behaviorRecordRows . map attribute) (deriveBehaviorRequirements (checkedSpec (checkedWorkspace workspace)))
  where
    attribute = attributeBehaviorOwner (fmap fst . nodeOwner (wsOwnership workspace) "aggregate")

workspaceSourceLanguageDrift :: WorkspaceSpec -> Maybe WorkspaceRecord -> [WorkspaceSourceLanguageDrift]
workspaceSourceLanguageDrift workspace previous =
  [ WorkspaceSourceLanguageDrift path oldLanguage newLanguage
  | member <- wsMembers workspace,
    let path = wmPath member
        newLanguage = wmSourceLanguage member,
    Just oldLanguage <- [Map.lookup path previousByPath],
    oldLanguage /= newLanguage
  ]
  where
    previousByPath =
      Map.fromList
        [ (wrslPath row, wrslSourceLanguage row)
        | row <- maybe [] wrSourceLanguages previous
        ]

layoutLabel :: Context -> Text
layoutLabel ctx = case placement ctx of GeneratedPrefix -> "prefixed"; CollocatedLeaf -> "collocated"

-- | Paths this run still produces whose owning member changed. Computed against
-- the previous record before stale detection, and never overlapping it: a moved
-- module's path is still in the current plan, so it was never a removal.
ownershipMoves :: Maybe WorkspaceRecord -> [(ScaffoldModule, ModuleProvenance)] -> [OwnershipMove]
ownershipMoves previous current =
  [ OwnershipMove
      { omPath = modulePath m,
        omPrevious = wrmOwner row,
        omCurrent = provenanceOwner provenance
      }
  | (m, provenance) <- current,
    Just row <- [Map.lookup (modulePath m) previousByPath],
    wrmOwner row /= provenanceOwner provenance
  ]
  where
    previousByPath = Map.fromList [(wrmPath row, row) | row <- maybe [] wrModules previous]

-- | Write one module. Generated modules whose bytes already match are left
-- alone and reported 'Unchanged'; hole modules keep the create-once rule. The
-- single-spec 'Keiro.Dsl.ScaffoldRun.executeScaffold' is untouched, so its report
-- bytes are unaffected.
writeWorkspaceModule ::
  FilePath ->
  (ScaffoldModule, ModuleProvenance) ->
  IO (ScaffoldModule, ModuleProvenance, WriteDisposition)
writeWorkspaceModule out (m, provenance) = do
  let path = out </> modulePath m
  exists <- doesFileExist path
  case kind m of
    HoleStub
      | exists -> pure (m, provenance, Skipped)
      | otherwise -> write path Created
    Generated
      | exists -> do
          existing <- TIO.readFile path
          if existing == moduleText m
            then pure (m, provenance, Unchanged)
            else write path Overwritten
      | otherwise -> write path Overwritten
  where
    write path disposition = do
      createDirectoryIfMissing True (takeDirectory path)
      TIO.writeFile path (moduleText m)
      pure (m, provenance, disposition)

-- | The report a successful whole-workspace scaffold prints, following the
-- single-spec report's shape so the two stay readable side by side: the header
-- names the service instead of a spec, each module line carries its owning member,
-- and the stale section keeps the exact "keiro-dsl never deletes files." sentence.
renderWorkspaceScaffoldReport :: WorkspaceScaffoldReport -> [Text]
renderWorkspaceScaffoldReport report =
  [ "workspace: "
      <> wsrService report
      <> " ("
      <> T.pack (wsrManifestPath report)
      <> ") -> "
      <> T.pack (wsrOutDir report)
      <> " (module-root="
      <> rootLabel
      <> ", layout="
      <> layoutLabel ctx
      <> ")",
    "members:  " <> T.intercalate ", " (map T.pack (wsrMembers report))
  ]
    <> map moduleLine dispositions
    <> [ "firewall: OK (" <> tshow generatedCount <> " generated modules scanned, 0 forbidden operators)",
         harnessLine,
         dependencyLine,
         "manifest: " <> T.pack (wsrBuildManifestPath report),
         "record:   " <> T.pack (wsrRecordPath report)
       ]
    <> previousManifestNote
    <> migrationSection
    <> sidecarMoveSection
    <> nameMoveSection
    <> constraintSection
    <> newHolesSection
    <> mappingDriftSection
    <> sourceLanguageDriftSection
    <> behaviorDriftSection
    <> obsoleteOutputSection
    <> ownershipSection
    <> staleSection
    <> maybe [] renderConformancePackageReport (wsrConformancePackage report)
  where
    ctx = wsrContext report
    dispositions = wsrDispositions report
    rootLabel = if T.null (moduleRoot ctx) then "(none)" else moduleRoot ctx
    names = [moduleNameOf (modulePath m) | (m, _, _) <- dispositions]
    nameWidth = maximum (1 : map T.length names)
    moduleLine (m, provenance, disposition) =
      "  "
        <> kindTag (kind m)
        <> "  "
        <> pad (moduleNameOf (modulePath m))
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
    generatedCount = length [() | (m, _, _) <- dispositions, kind m == Generated]
    harnesses =
      sortOn
        id
        [ moduleNameOf (modulePath m)
        | (m, _, _) <- dispositions,
          any (`T.isSuffixOf` moduleNameOf (modulePath m)) [".Harness", ".ProcessHarness", ".WorkflowFacts"]
        ]
    harnessLine = case harnesses of
      [] -> "harness:  (none emitted)"
      _ -> "harness:  run `cabal test <your-component>` over " <> T.unwords harnesses
    dependencyLine =
      "dependency plan: consumer packages "
        <> renderBracketed (consumerPackages (wsrConsumerPlan report))
        <> ", consumer modules "
        <> renderBracketed (consumerModules (wsrConsumerPlan report))
    previousManifestNote = case wsrPreviousManifest report of
      Just previous -> ["note: the previous workspace record was written from manifest " <> previous]
      Nothing -> []
    migrationSection = maybe [] renderMigrationReport (wsrMigration report)
    sidecarMoveSection = case wsrSidecarMoves report of
      [] -> []
      moves ->
        ["sidecar migration: applied (" <> tshow (length moves) <> " move(s))"]
          <> map (("  " <>) . renderSidecarMove) moves
    nameMoveSection = case wsrNameMoves report of
      [] -> []
      moves ->
        ["name migration: applied (" <> tshow (length moves) <> " source move(s))"]
          <> [ "  "
                 <> T.pack (moveOldPath move)
                 <> " -> "
                 <> T.pack (moveNewPath move)
                 <> "  backup="
                 <> T.pack (moveBackupPath move)
             | move <- moves
             ]
    constraintSection = case wsrConstraintPlan report of
      [] -> []
      constraints -> "constraint plan:" : map ("  " <>) constraints
    newHolesSection = case wsrNewHoles report of
      [] -> []
      obligations ->
        ["newly required holes since last scaffold: " <> tshow (length obligations)]
          <> concatMap obligationLines obligations
    obligationLines hole =
      [ "  " <> holeModule hole,
        "    " <> holeSignature hole <> " (" <> obligationKindLabel (holeKind hole) <> ")"
      ]
    mappingDriftSection = case wsrMappingDrift report of
      [] -> []
      drifts ->
        ["mapping drift: " <> tshow (length drifts) <> " declaration(s) changed since the previous scaffold:"]
          <> concatMap driftLines drifts
    driftLines drift =
      [ "  " <> driftSpecName drift,
        "    previous: " <> maybe "(absent)" renderMappingIdentity (driftPrevious drift),
        "    current:  " <> maybe "(absent)" renderMappingIdentity (driftCurrent drift)
      ]
    sourceLanguageDriftSection = case wsrSourceLanguageDrift report of
      [] -> []
      drifts ->
        ["source-language drift: " <> tshow (length drifts) <> " member(s) changed provenance (generated module bytes are semantic and unaffected):"]
          <> [ "  "
                 <> T.pack (wsldPath drift)
                 <> "  "
                 <> workspaceSourceLanguageLabel (wsldPrevious drift)
                 <> " -> "
                 <> workspaceSourceLanguageLabel (wsldCurrent drift)
             | drift <- drifts
             ]
    behaviorDriftSection =
      renderBehaviorRows "new behavior obligations" (wsrAddedBehavior report)
        <> renderBehaviorRows "removed behavior obligations (consumer rows become stale)" (wsrRemovedBehavior report)
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
          <> unBehaviorKey (behaviorRecordKey row)
          <> maybe "" (("  owner=" <>) . T.pack) (behaviorRecordOwner row),
        "    Pending (BehaviorKey " <> tshow (unBehaviorKey (behaviorRecordKey row)) <> ")"
      ]
    obsoleteOutputSection = case wsrObsoleteOutputHooks report of
      [] -> []
      hooks ->
        ["obsolete identity-copy output hooks (if still present, they are unused and may be removed):"]
          <> ["  " <> aggregate <> ".Holes." <> hook | (aggregate, hook) <- hooks]
    ownershipSection = case wsrOwnershipMoves report of
      [] -> []
      moves ->
        ["ownership moves: " <> tshow (length moves) <> " module(s) changed owning member (content unaffected):"]
          <> [ "  " <> T.pack (omPath move) <> "  " <> ownerName (omPrevious move) <> " -> " <> ownerName (omCurrent move)
             | move <- moves
             ]
    ownerName = maybe "(context-level)" T.pack
    staleSection = case wsrStale report of
      [] -> []
      stale ->
        [ "stale: "
            <> tshow (length stale)
            <> " file(s) from a previous scaffold of workspace "
            <> wsrService report
            <> " are no longer produced by this workspace:"
        ]
          <> map staleLine stale
          <> ["note: keiro-dsl never deletes files."]
    staleLine stale = case (staleKind stale, staleGeneratedEvidence stale) of
      (Generated, Just ExactGeneratedBannerPresent) ->
        "  generated " <> T.pack (stalePath stale) <> "  (exact generated banner present; verify unchanged bytes before deleting)"
      (Generated, _) ->
        "  generated " <> T.pack (stalePath stale) <> "  (exact generated banner missing; preserve and review)"
      (HoleStub, _) -> "  hole      " <> T.pack (stalePath stale) <> "  (hand-owned — preserve and review)"

workspaceSourceLanguageLabel :: SourceLanguage -> Text
workspaceSourceLanguageLabel sourceLanguage =
  sourceFormText sourceLanguage
    <> "/effective-v"
    <> languageVersionText (effectiveLanguageVersion sourceLanguage)

renderBracketed :: [Text] -> Text
renderBracketed values = "[" <> T.intercalate ", " values <> "]"

tshow :: (Show a) => a -> Text
tshow = T.pack . show
