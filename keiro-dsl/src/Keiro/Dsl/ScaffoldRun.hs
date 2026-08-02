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
    planScaffold,
    planScaffoldWithGoldens,
    executeServiceScaffold,
    executeScaffold,
    executeScaffoldWithLanguage,
    renderRefusals,
    renderScaffoldReport,

    -- * Shared with whole-workspace scaffolding ("Keiro.Dsl.WorkspaceScaffold")

    --
    -- $shared
    pureRefusals,
    missingGeneratedBanners,
    staleAgainst,
    constraintPlan,
    mappingDrift,
    behaviorDrift,
    newBindingObligations,
    obligationKindLabel,
    renderMappingIdentity,
  )
where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.BehaviorCoverage (BehaviorDerivationError, BehaviorKey (..), BehaviorRecordRow (..), behaviorRecordRows, deriveBehaviorRequirements)
import Keiro.Dsl.ExplainBindings (BindingHole (..), BindingObligationKind (..), bindingHolesForService)
import Keiro.Dsl.FoldFingerprint (FoldSurfaceError, aggregateFoldSurfaceForService, renderFoldSurfaceError)
import Keiro.Dsl.Goldens (GoldenPayload)
import Keiro.Dsl.Grammar (Node (..), Spec (..))
import Keiro.Dsl.Harness (harnessForServiceWithGoldens, harnessProcess, harnessReadModel, harnessRouter, harnessWorkflow)
import Keiro.Dsl.IdDomain (idDomainIdentitiesForService)
import Keiro.Dsl.LanguageVersion (SourceLanguage (..), effectiveLanguageVersion, languageVersionText, sourceFormText)
import Keiro.Dsl.Manifest (moduleNameOf, renderManifestForService)
import Keiro.Dsl.MappedConsumer (ConsumerPlan (..), MappingIdentity (..), consumerPlan)
import Keiro.Dsl.NominalType (nominalEqualityIdentitiesForService)
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRecord (ScaffoldRecord (..), parseRecord, recordFileName, renderRecord)
import Keiro.Dsl.SemanticContract (CheckedService (..), checkedService, effectiveLanguageContract, legacyCheckedService)
import Keiro.Dsl.TypeGraph (MappedKey (..), TypeGraph (..), UseSite (..), resolveTypeGraph)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))

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
    reportObsoleteOutputHooks :: ![(Text, Text)]
  }
  deriving stock (Eq, Show)

-- | Produce the complete in-memory module set under a checked semantic
-- contract. Keeping this registry in one place prevents the CLI and tests from
-- drifting apart.
scaffoldServiceModules :: Context -> CheckedService -> [ScaffoldModule]
scaffoldServiceModules = scaffoldServiceModulesWithGoldens []

scaffoldServiceModulesWithGoldens :: [GoldenPayload] -> Context -> CheckedService -> [ScaffoldModule]
scaffoldServiceModulesWithGoldens goldens ctx service =
  scaffoldStructuralForService ctx service
    <> scaffoldReplayAudit ctx spec
    <> concat
      [ case node of
          NAggregate agg -> scaffoldAggregateForService ctx service agg <> harnessForServiceWithGoldens goldens ctx service agg
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
      | node <- specNodes spec
      ]
  where
    spec = checkedSpec service

-- | Compatibility wrapper that explicitly selects legacy/version-1 semantics.
scaffoldModules :: Context -> Spec -> [ScaffoldModule]
scaffoldModules = scaffoldModulesWithGoldens []

scaffoldModulesWithGoldens :: [GoldenPayload] -> Context -> Spec -> [ScaffoldModule]
scaffoldModulesWithGoldens goldens ctx = scaffoldServiceModulesWithGoldens goldens ctx . legacyCheckedService

-- | Run every pure refusal gate under the effective semantic contract.
planServiceScaffold :: Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planServiceScaffold = planServiceScaffoldWithGoldens []

planServiceScaffoldWithGoldens :: [GoldenPayload] -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planServiceScaffoldWithGoldens goldens ctx service =
  case traverse (aggregateFoldSurfaceForService service) [aggregate | NAggregate aggregate <- specNodes spec] of
    Left surfaceError -> Left [FoldSurfaceRefusal surfaceError]
    Right _ -> case scaffoldRefusals spec of
      lowering@(_ : _) -> Left [LoweringRefusal lowering]
      [] ->
        let modules = stampGeneratedModules (checkedLanguageContract service) (scaffoldServiceModulesWithGoldens goldens ctx service)
         in case pureRefusals ctx spec modules of
              [] -> Right modules
              refusals -> Left refusals
  where
    spec = checkedSpec service

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
    <> [LoweringRefusal lowering | let lowering = scaffoldRefusals spec, not (null lowering)]
    <> [BehaviorRefusal errors | Left errors <- [deriveBehaviorRequirements spec]]
  where
    breaches = firewallBreaches modules

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
executeServiceScaffold out forceGeneratedOverwrite specPath sourceLanguage ctx service plannedModules
  | effectiveLanguageContract sourceLanguage /= checkedLanguageContract service =
      pure (Left [SemanticContractMismatch "source provenance and checked service selected different effective language contracts"])
  | otherwise = executeCheckedScaffold
  where
    spec = checkedSpec service
    modules = stampGeneratedModules (checkedLanguageContract service) plannedModules
    executeCheckedScaffold =
      case deriveBehaviorRequirements spec of
        Left errors -> pure (Left [BehaviorRefusal errors])
        Right requirements -> do
          bannerless <- if forceGeneratedOverwrite then pure [] else missingGeneratedBanners out modules
          if not (null bannerless)
            then pure (Left [MissingGeneratedBanner bannerless])
            else do
              let recordPath = out </> recordFileName (specContext spec)
              previousRecord <- readRecord recordPath
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
              let manifestPath = out </> ("keiro-dsl-manifest." <> T.unpack (specContext spec) <> ".txt")
              TIO.writeFile manifestPath (renderManifestForService (T.pack specPath) modules service)
              TIO.writeFile recordPath (renderRecord (currentRecord specPath sourceLanguage ctx service modules currentBehavior))
              pure $
                Right
                  ScaffoldReport
                    { reportSpecPath = specPath,
                      reportOutDir = out,
                      reportContext = ctx,
                      reportDispositions = dispositions,
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
                      reportObsoleteOutputHooks = obsoleteGeneratedOutputHooks spec
                    }

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
      recFiles = [(kind m, modulePath m) | m <- modules],
      recMappings = consumerMappings (consumerPlan spec),
      recIdDomains = idDomainIdentitiesForService service,
      recNominalEqualities = nominalEqualityIdentitiesForService service,
      recBindingObligations = either (const []) id (bindingHolesForService service),
      recBehaviorRequirements = currentBehavior
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

renderScaffoldReport :: ScaffoldReport -> [Text]
renderScaffoldReport report =
  [ "scaffold: " <> T.pack (reportSpecPath report) <> " -> " <> T.pack (reportOutDir report) <> " (module-root=" <> rootLabel <> ", layout=" <> layoutLabel <> ")"
  ]
    <> map moduleLine dispositions
    <> [ "firewall: OK (" <> tshow generatedCount <> " generated modules scanned, 0 forbidden operators)",
         harnessLine,
         dependencyLine,
         "manifest: " <> T.pack (reportManifestPath report),
         "record:   " <> T.pack (reportRecordPath report)
       ]
    <> previousSpecNote
    <> constraintSection
    <> newHolesSection
    <> mappingDriftSection
    <> sourceLanguageDriftSection
    <> behaviorDriftSection
    <> obsoleteOutputSection
    <> staleSection
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
