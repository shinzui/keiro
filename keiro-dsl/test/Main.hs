-- | Test driver for keiro-dsl. EP-1 milestone 1 tests: the @parse . pretty@
-- round-trip property over generated specs, and a unit test pinning the shape
-- of the canonical Reservation fixture.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (filterM, forM, forM_, unless)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft, isRight)
import Data.Foldable (toList)
import Data.KindID qualified as KindID
import Data.List (find, isInfixOf, partition, permutations, sort, (\\))
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as LazyText
import Data.Text.Lazy.Encoding qualified as LazyTextEncoding
import Data.Version (showVersion)
import Keiki.ProjectionDomain (matchesTextPattern)
import Keiro.Codec (Codec (..), EventType (..), decodeRaw)
import Keiro.Codec.IdDomain (IdDomainFailure (..), idDomainSampleText, idDomainTextPattern, parseKindIdV7Text, parseKindIdV7Value, typeIdV7Domain, validateIdDomainText)
import Keiro.Dsl.AggregateType
import Keiro.Dsl.BehaviorCoverage qualified as Behavior
import Keiro.Dsl.BehaviorSourceMap qualified as BehaviorSource
import Keiro.Dsl.CanonicalEncoding (foldFingerprint128)
import Keiro.Dsl.CodecCompare
import Keiro.Dsl.ConformanceBaseline (conformanceBaselineSpec)
import Keiro.Dsl.ConformancePackage
import Keiro.Dsl.ConsumerTypePlan
import Keiro.Dsl.CoordinationImpact
import Keiro.Dsl.Coverage qualified as Coverage
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), CompatibilitySurface (..), CompatibilityVector (..), FamilyDiff (..), Label (..), MappedPersistedImpact (..), MappedPersistedSurface (..), NodeFamily, RolloutConstraint (..), SurfaceVerdict (..), defaultGate, deriveLabel, familyRegistry, gateWith, gatedBreaking, isAdvisory, isBreaking, verdictFor)
import Keiro.Dsl.Diff qualified as CheckedDiff
import Keiro.Dsl.DiffReport (Remedy (..), diffReport, diffReportWithImpacts, diffReportWithSemanticImpact, parseSurfaceName, remediationFor, renderExplainBlock, renderFinding, renderSemanticImpact)
import Keiro.Dsl.EventOutput
import Keiro.Dsl.ExplainBindings (BindingHole (..), BindingObligation (..), BindingObligationKind (..), bindingHoles, bindingObligations, bindingObligationsForService, renderBindingObligations)
import Keiro.Dsl.Expression
import Keiro.Dsl.FoldFingerprint (FoldSurfaceError (..))
import Keiro.Dsl.FoldFingerprint qualified as CheckedFold
import Keiro.Dsl.Frontend (FrontendErrorCode (..), FrontendFailure (..), LoweringFailure (..), LoweringFailureCode (..), lowerSurfaceDocument, parseSurfaceSource)
import Keiro.Dsl.FrontendCompatibility (frontendCompatibilitySpec)
import Keiro.Dsl.FrontendProfiles (frontendProfilesSpec)
import Keiro.Dsl.FrontendSurface (frontendSurfaceSpec)
import Keiro.Dsl.GeneratedHaskellLanguage (RewriteState (..), modernizeGeneratedHaskellSourceWithState)
import Keiro.Dsl.Goldens (GoldenEvidence (..), GoldenPayload (..), emitGoldenPayloads, goldenRelativePath, goldensForDiff)
import Keiro.Dsl.Grammar
import Keiro.Dsl.Grammar qualified as Grammar
import Keiro.Dsl.Harness (harnessFor, harnessForService, harnessForWithGoldens, harnessReadModel, harnessRouter, harnessWorkflow)
import Keiro.Dsl.HaskellImport
import Keiro.Dsl.HaskellSourceMove
import Keiro.Dsl.IdDomain (IdDomainContract (..), contractIdDomainContractFor, idDomainContractFor, idDomainIdentitiesForService)
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Manifest (manifestDependencies, manifestDependenciesForService, moduleNameOf, renderManifest, renderManifestForService, renderManifestForServiceWithFacade)
import Keiro.Dsl.MappedCodecPlan
import Keiro.Dsl.MappedConsumer (ConsumerPlan (..), MappingIdentity (..), consumerPlan)
import Keiro.Dsl.MappedDiff (diffMapped)
import Keiro.Dsl.NominalType hiding (NominalInvalidHaskellSource, NominalInvalidIdPrefix, NominalInvalidIdentity, NominalMissingIngredient)
import Keiro.Dsl.Parser (parseSource, parseSourceDocument, parseSpec)
import Keiro.Dsl.PrettyPrint (renderSource, renderSpec, renderTransition)
import Keiro.Dsl.ProjectionMappedImpact qualified as ProjectionImpact
import Keiro.Dsl.ProjectionSupply
import Keiro.Dsl.ReadModelQueryContract (QueryContractDrift (..), QueryContractIdentity (..), QueryContractPosition (..), queryContractIdentities)
import Keiro.Dsl.ReadModelShape (canonicalShape, deriveShapeHash, registryNameFor, subscriptionNameFor)
import Keiro.Dsl.RecordMigration (recordMigrationSpec)
import Keiro.Dsl.ReplayImpact (AggregateImpact (..), CatalogReplayImpact (..), ReplayImpact (..))
import Keiro.Dsl.ReplayImpact qualified as ReplayImpact
import Keiro.Dsl.RouterSelection qualified as RouterSelection
import Keiro.Dsl.Scaffold (Context (..), ModuleKind (..), ModuleRole (..), NominalGenerationOwner (..), NominalUseSite (..), ScaffoldModule (..), StructuralProjection (..), codecComparisonBanner, codecComparisonModule, defaultContext, firewallBreaches, genPrefixFor, generatedBanner, generatedBannerFor, generatedNominalModule, holePrefixFor, isGeneratedBannerLine, moduleRole, obsoleteGeneratedOutputHooks, planNominalGeneration, projectionSpecs, scaffoldAggregate, scaffoldAggregateForService, scaffoldContract, scaffoldContractForService, scaffoldIntake, scaffoldProcess, scaffoldProjectionCatalog, scaffoldPublisher, scaffoldReadModel, scaffoldReadModelForService, scaffoldRefusals, scaffoldReplayAudit, scaffoldRouter, scaffoldStructural, scaffoldWorkqueue, scaffoldWorkqueueForService, windowSeconds)
import Keiro.Dsl.ScaffoldRecord (GeneratedHaskellNamingEdition (..), ScaffoldModuleRoleRow (..), ScaffoldRecord (..), parseRecord, projectionCatalogFacts, projectionCatalogFactsForService, recordFileName, renderRecord)
import Keiro.Dsl.ScaffoldRun (GeneratedArtifactCategory (..), GeneratedArtifactImpact (..), GeneratedHaskellEditionImpact (..), GeneratedHaskellEditionUse (..), HoleUseForm (..), MappingDrift (..), QueryContractMigration (..), Refusal (..), ScaffoldReport (..), SourceLanguageDrift (..), StaleGeneratedEvidence (..), StaleModule (..), WriteDisposition (..), auditGeneratedHaskell, checkIndexedServiceDiagnostics, executeScaffold, executeScaffoldWithLanguage, executeServiceScaffold, executeServiceScaffoldWithRuntimePackage, executeServiceScaffoldWithRuntimePackageAndMigrations, executeServiceScaffoldWithRuntimePackageAndNameMigrations, planIndexedServiceScaffold, planIndexedServiceScaffoldWithRuntimePackage, planningRefusalDiagnostics, renderRefusals, renderScaffoldReport, renderSemanticImpactReport, scaffoldModules, scaffoldServiceModules)
import Keiro.Dsl.SemanticContract
import Keiro.Dsl.SemanticImpact
import Keiro.Dsl.SemanticImpact qualified as SemanticImpact
import Keiro.Dsl.ServiceHarness
import Keiro.Dsl.SidecarMigration
import Keiro.Dsl.SidecarNames
import Keiro.Dsl.Skeleton (skeletonFor, skeletonKinds)
import Keiro.Dsl.Source (SourcePoint (..), SourceSpan (..))
import Keiro.Dsl.SourceIndex
import Keiro.Dsl.TypeGraph
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode (..), Severity (..), derivedQueueTrio, diagnosticCodeText, parseDiagnosticCode, renderDiagnostic, validateService, validateSpec)
import Keiro.Dsl.Workspace
import Keiro.Dsl.Workspace qualified as Workspace
import Keiro.Dsl.WorkspaceAdoption
import Keiro.Dsl.WorkspaceDiff hiding (diffWorkspaces)
import Keiro.Dsl.WorkspaceDiff qualified as CheckedWorkspaceDiff
import Keiro.Dsl.WorkspaceRecord
import Keiro.Dsl.WorkspaceRecord qualified as WorkspaceRecord
import Keiro.Dsl.WorkspaceScaffold
import Paths_keiro_dsl qualified as Package
import System.Directory (canonicalizePath, createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory, removeFile, removePathForcibly, renameFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)
import Test.Hspec hiding (Spec)
import Test.QuickCheck

resolvedFold :: Either FoldSurfaceError value -> value
resolvedFold = either (error . ("unexpected fold-surface failure in checked fixture: " <>) . show) id

aggregateFoldFingerprintForService :: CheckedService -> Aggregate -> T.Text
aggregateFoldFingerprintForService service aggregate = resolvedFold (CheckedFold.aggregateFoldFingerprintForService service aggregate)

aggregateFoldSurfaceForService :: CheckedService -> Aggregate -> T.Text
aggregateFoldSurfaceForService service aggregate = resolvedFold (CheckedFold.aggregateFoldSurfaceForService service aggregate)

aggregateFoldFingerprint :: Spec -> Aggregate -> T.Text
aggregateFoldFingerprint spec aggregate = aggregateFoldFingerprintForService (stableCheckedService spec) aggregate

aggregateFoldSurface :: Spec -> Aggregate -> T.Text
aggregateFoldSurface spec aggregate = aggregateFoldSurfaceForService (stableCheckedService spec) aggregate

legacyAggregateFoldFingerprint :: Spec -> Aggregate -> T.Text
legacyAggregateFoldFingerprint spec aggregate = aggregateFoldFingerprintForService (legacyCheckedService spec) aggregate

legacyAggregateFoldSurface :: Spec -> Aggregate -> T.Text
legacyAggregateFoldSurface spec aggregate = aggregateFoldSurfaceForService (legacyCheckedService spec) aggregate

diffServices :: CheckedService -> CheckedService -> [Change]
diffServices old new = resolvedFold (CheckedDiff.diffServices old new)

diffSources :: ParsedSource -> ParsedSource -> [Change]
diffSources old new = resolvedFold (CheckedDiff.diffSources old new)

diffSpecs :: Spec -> Spec -> [Change]
diffSpecs old new = diffServices (stableCheckedService old) (stableCheckedService new)

legacyDiffSpecs :: Spec -> Spec -> [Change]
legacyDiffSpecs old new = diffServices (legacyCheckedService old) (legacyCheckedService new)

diffWorkspaces :: WorkspaceSpec -> WorkspaceSpec -> [WorkspaceChange]
diffWorkspaces old new = resolvedFold (CheckedWorkspaceDiff.diffWorkspaces old new)

replayImpactSpecs :: Spec -> Spec -> ReplayImpact
replayImpactSpecs old new =
  resolvedFold (ReplayImpact.replayImpactServices (stableCheckedService old) (stableCheckedService new))

legacyReplayImpactSpecs :: Spec -> Spec -> ReplayImpact
legacyReplayImpactSpecs old new =
  resolvedFold (ReplayImpact.replayImpactServices (legacyCheckedService old) (legacyCheckedService new))

nominalEqualityIdentities :: Spec -> [T.Text]
nominalEqualityIdentities = nominalEqualityIdentitiesForService . stableCheckedService

stableCheckedService :: Spec -> CheckedService
stableCheckedService = checkedService stableSourceLanguage

stableSourceLanguage :: SourceLanguage
stableSourceLanguage =
  DeclaredLanguage
    { declaredLanguageVersion = currentStableLanguageVersion,
      languageVersionLoc = noLoc
    }

main :: IO ()
main = hspec $ do
  conformanceBaselineSpec
  frontendCompatibilitySpec
  frontendSurfaceSpec
  frontendProfilesSpec
  recordMigrationSpec

  describe "mapped consumer surface" $ do
    it "parses and canonically round-trips Language 5 queue and query expressions as atomic forms" $ do
      source <- mappedConsumerSurfaceSource
      parsed <- case parseSource "<mapped-consumer>" source of
        Left failure -> expectationFailure (show failure) >> fail "unreachable"
        Right value -> pure value
      parseSource "<mapped-consumer-roundtrip>" (renderSource parsed) `shouldBe` Right parsed
      let spec = parsed.spec
      case [field | NWorkqueue workqueue <- (.nodes) spec, field <- (.payload) workqueue] of
        [field] -> do
          (.valueType) field `shouldBe` TypedQueueExpression (TList (TOptional (TRef "ArtifactInfo")))
          unLoc ((.loc) field) `shouldSatisfy` (> 0)
        fields -> expectationFailure ("unexpected mapped queue fields: " <> show fields)
      case [types | NReadModel readModel <- (.nodes) spec, Just types <- [(.queryTypes) readModel]] of
        [ReadModelQueryTypes {input, result}] -> do
          input `shouldBe` TRef "ArtifactInfo"
          result `shouldBe` TOptional (TRef "ArtifactLocation")
        queryPairs -> expectationFailure ("unexpected mapped query pairs: " <> show queryPairs)
      let missingInput = T.replace "  query input = ArtifactInfo\n" "" source
          missingResult = T.replace "  query result = Optional ArtifactLocation\n" "" source
      parseSource "<mapped-consumer-missing-input>" missingInput `shouldSatisfy` isLeft
      parseSource "<mapped-consumer-missing-result>" missingResult `shouldSatisfy` isLeft

    it "resolves nested queue and query roots and plans one deterministic consumer-facing Haskell type" $ do
      source <- mappedConsumerSurfaceSource
      spec <- parseInlineSpec "<mapped-consumer-graph>" source
      graph <- shouldResolveTypeGraph spec
      map renderUsePath (usePaths graph "ArtifactLocation")
        `shouldContain` [ "workqueue ArtifactJobs payload .jobData : ArtifactInfo [] optional .location : ArtifactLocation",
                          "readmodel ArtifactLookup query input : ArtifactInfo .location : ArtifactLocation",
                          "readmodel ArtifactLookup query result : ArtifactLocation optional"
                        ]
      planConsumerType graph (RList (ROptional (RRef (MappedKey "ArtifactInfo"))))
        `shouldBe` Right
          ConsumerTypePlan
            { haskellType = HaskellTypeOccurrence "[Maybe ArtifactInfo]",
              imports =
                [ ImportRequirement "artifact-domain" "Example.Artifact.Domain" "ArtifactInfo",
                  ImportRequirement "base" "Data.Maybe" "Maybe"
                ],
              dependencies = Set.fromList [MappedKey "ArtifactInfo", MappedKey "ArtifactKind", MappedKey "ArtifactLocation"]
            }
      unresolved <-
        parseInlineSpec
          "<mapped-consumer-unresolved>"
          (T.replace "List (Optional ArtifactInfo)" "List (Optional MissingPayload)" source)
      case resolveTypeGraph unresolved of
        Left errors ->
          NE.toList errors
            `shouldSatisfy` any
              ( \case
                  TGUnresolvedConsumerRef owner missing loc ->
                    owner == "workqueue 'ArtifactJobs' payload field 'jobData'"
                      && missing == "MissingPayload"
                      && unLoc loc > 0
                  _ -> False
              )
        Right _ -> expectationFailure "unresolved mapped queue reference unexpectedly resolved"

    it "plans one recursive mapped codec algebra for consumer and structural boundaries" $ do
      source <- mappedConsumerSurfaceSource
      spec <- parseInlineSpec "<mapped-codec-plan>" source
      graph <- shouldResolveTypeGraph spec
      let expression = RList (ROptional (RRef (MappedKey "ArtifactInfo")))
      case planMappedCodec graph expression of
        Left failure -> expectationFailure (show failure)
        Right planned -> do
          (.authority) planned `shouldBe` Set.singleton (StructuralAuthority (MappedKey "ArtifactInfo"))
          renderMappedEncode graph ConsumerValueBoundary planned "payload.jobs"
            `shouldBe` "toJSON (map (\\item -> maybe Null (\\item -> encodeArtifactInfoMapped item) (item)) (payload.jobs))"
          renderMappedParse graph ConsumerValueBoundary planned
            `shouldBe` "\\value -> (parseJSON value :: Parser [Value]) >>= traverse (\\value -> case value of Null -> pure Nothing; other -> Just <$> parseArtifactInfoMapped other)"
          let references = consumerTypeReferences ((.consumerType) planned)
          case planHaskellImports (ImportEnvironment "Generated.Test.Queue" (Set.singleton "Payload") Set.empty) references of
            Left failure -> expectationFailure (show failure)
            Right importPlan ->
              renderConsumerType importPlan graph expression
                `shouldBe` Right (HaskellTypeOccurrence "[Maybe ArtifactInfo]")

    it "derives mapped projection impact from aggregate event authority and exposes heterogeneous boundaries" $ do
      source <- mappedConsumerSurfaceSource
      base <- parseInlineSpec "<mapped-consumer-projections>" source
      let projection = ProjectionSpec "artifact_view" (Just Eventual) "key" Nothing noLoc
          withInlineProjection node = case node of
            NAggregate aggregate -> NAggregate (aggregateWithProjection (Just projection) aggregate)
            NReadModel readModel@ReadModelNode {name = "ArtifactLookup"} ->
              NReadModel (readModelWithGroupAndObservedTargets (Just "artifact_group") ["artifact_target"] readModel)
            other -> other
          owner name sourceKind feed groupName targetNames replayPolicy =
            NProjectionOwner
              ProjectionOwnerNode
                { name = name,
                  sources = [sourceKind],
                  delivery = case feed of RmInline -> DeliveryInline; RmSubscription -> DeliverySubscription,
                  group = groupName,
                  targets = targetNames,
                  order = 1,
                  subscription = if feed == RmSubscription then Just (name <> "-subscription") else Nothing,
                  dedup = if feed == RmSubscription then Just (name <> "-dedup") else Nothing,
                  checkpointOnMissing = if feed == RmSubscription then [CheckpointFromBeginning] else [],
                  replay = replayPolicy,
                  loc = noLoc
                }
          target name = NProjectionTarget (ProjectionTargetNode name "public" name TargetClear [] noLoc)
          groupNode name targetName = NRebuildGroup (RebuildGroupNode name [targetName] [targetName] noLoc)
          disjointReadModel =
            NReadModel
              ReadModelNode
                { name = "DisjointLookup",
                  table = "disjoint_lookup",
                  schema = "public",
                  columns = [],
                  version = 1,
                  shape = "fixture",
                  freshness = FreshnessImmediate,
                  supply = LegacyReadModelSupply Eventual Nothing RmSubscription (Just "disjoint-lookup"),
                  group = Just "disjoint_group",
                  observedTargets = ["disjoint_target"],
                  backingTarget = Nothing,
                  queryTypes = Nothing,
                  loc = noLoc
                }
          spec =
            specWithNodes
              ( map withInlineProjection base.nodes
                  <> [ target "artifact_target",
                       target "disjoint_target",
                       groupNode "artifact_group" "artifact_target",
                       groupNode "disjoint_group" "disjoint_target",
                       owner "artifactProjection" (CatalogAggregate "Catalog") RmSubscription "artifact_group" ["artifact_target"] ProjectionReplayExplicit,
                       owner "liveProjection" (CatalogAggregate "Catalog") RmInline "disjoint_group" ["disjoint_target"] (ProjectionLiveOnly "live only"),
                       owner "categoryProjection" (CatalogCategory "artifact") RmSubscription "artifact_group" ["artifact_target"] ProjectionReplayExplicit,
                       owner "allProjection" CatalogAll RmInline "disjoint_group" ["disjoint_target"] (ProjectionLiveOnly "heterogeneous"),
                       disjointReadModel
                     ]
              )
              base
      impact <- semanticImpact <$> shouldResolveTypeGraph spec
      Set.fromList (mappedDeclarationConsumers impact (MappedKey "ArtifactLocation"))
        `shouldBe` Set.fromList
          [ AggregateConsumer "Catalog",
            WorkqueueConsumer "ArtifactJobs",
            ReadModelQueryConsumer "ArtifactLookup" MappedQueryInput,
            ReadModelQueryConsumer "ArtifactLookup" MappedQueryResult,
            DerivedProjectionConsumer (AggregateInlineProjectionConsumer "Catalog" "artifact_view"),
            DerivedProjectionConsumer (CatalogProjectionConsumer "artifactProjection" "Catalog"),
            DerivedProjectionConsumer (CatalogProjectionConsumer "liveProjection" "Catalog")
          ]
      Set.fromList ((.unsupportedProjectionSources) impact)
        `shouldBe` Set.fromList
          [ UnsupportedCatalogCategory "categoryProjection" "artifact",
            UnsupportedCatalogAll "allProjection"
          ]
      let projected = ProjectionImpact.projectionMappedImpact (stableCheckedService spec) impact
          locationConsumers = ProjectionImpact.projectionConsumersFor projected (MappedKey "ArtifactLocation")
      locationConsumers
        `shouldBe` Set.fromList
          [ AggregateInlineProjectionConsumer "Catalog" "artifact_view",
            CatalogProjectionConsumer "artifactProjection" "Catalog",
            CatalogProjectionConsumer "liveProjection" "Catalog"
          ]
      ( [ renderUsePath inheritedPath
        | ProjectionImpact.ProjectionMappedRoot derived declarationKey inheritedPath <- (.roots) projected,
          derived == CatalogProjectionConsumer "artifactProjection" "Catalog",
          declarationKey == MappedKey "ArtifactLocation"
        ]
        )
        `shouldBe` ["Catalog event ArtifactObserved .artifact : ArtifactInfo .location : ArtifactLocation"]
      ProjectionImpact.projectionOperationsFor projected (MappedKey "ArtifactLocation")
        `shouldBe` [ ProjectionImpact.ProjectionOperationalImpact
                       (AggregateInlineProjectionConsumer "Catalog" "artifact_view")
                       Nothing
                       (Set.singleton "artifact_view")
                       Set.empty
                       False
                       (ProjectionImpact.projectionAggregateSourceFingerprint spec "Catalog"),
                     ProjectionImpact.ProjectionOperationalImpact
                       (CatalogProjectionConsumer "artifactProjection" "Catalog")
                       (Just "artifact_group")
                       (Set.singleton "artifact_target")
                       (Set.singleton "ArtifactLookup")
                       True
                       (ProjectionImpact.projectionAggregateSourceFingerprint spec "Catalog"),
                     ProjectionImpact.ProjectionOperationalImpact
                       (CatalogProjectionConsumer "liveProjection" "Catalog")
                       (Just "disjoint_group")
                       (Set.singleton "disjoint_target")
                       (Set.singleton "DisjointLookup")
                       False
                       (ProjectionImpact.projectionAggregateSourceFingerprint spec "Catalog")
                   ]
      (.unsupported) projected
        `shouldBe` [ ProjectionImpact.UnsupportedProjectionImpact
                       (UnsupportedCatalogCategory "categoryProjection" "artifact")
                       "artifact_group"
                       (Set.singleton "artifact_target")
                       (Set.singleton "ArtifactLookup")
                       True,
                     ProjectionImpact.UnsupportedProjectionImpact
                       (UnsupportedCatalogAll "allProjection")
                       "disjoint_group"
                       (Set.singleton "disjoint_target")
                       (Set.singleton "DisjointLookup")
                       False
                   ]
      let baseFingerprint = ProjectionImpact.projectionAggregateSourceFingerprint spec "Catalog"
          wireChanged = mapMappedDeclaration "ArtifactLocation" changeProjectionMappedWire spec
          commandOnly = projectionEventWithoutGeometry spec
          commandOnlyChanged = mapMappedDeclaration "VendorGeometry" changeProjectionMappedWire commandOnly
      ProjectionImpact.projectionAggregateSourceFingerprint wireChanged "Catalog" `shouldNotBe` baseFingerprint
      ProjectionImpact.projectionAggregateSourceFingerprint commandOnlyChanged "Catalog"
        `shouldBe` ProjectionImpact.projectionAggregateSourceFingerprint commandOnly "Catalog"
      let generatedCatalog candidate =
            generatedTextEndingIn "ProjectionCatalog.hs" (scaffoldProjectionCatalog (defaultContext (candidate.context)) candidate)
          baseCatalog = generatedCatalog spec
      baseCatalog `shouldSatisfy` T.isInfixOf (T.pack (show baseFingerprint))
      generatedCatalog wireChanged `shouldNotBe` baseCatalog
      generatedCatalog commandOnlyChanged `shouldBe` generatedCatalog commandOnly
      let projectionChanges =
            [ kindOfChange change
            | change <- diffSpecs spec wireChanged,
              (.facet) (kindOfChange change) == "mapped-projection"
            ]
      map (.node) projectionChanges `shouldBe` ["Catalog", "artifactProjection", "liveProjection"]
      map (.subject) projectionChanges
        `shouldBe` [ "aggregate-projection:Catalog:artifact_view inherits ArtifactLocation",
                     "catalog-projection:artifactProjection:Catalog inherits ArtifactLocation",
                     "catalog-projection:liveProjection:Catalog inherits ArtifactLocation"
                   ]
      map (.paths) projectionChanges
        `shouldBe` replicate 3 ["Catalog event ArtifactObserved .artifact : ArtifactInfo .location : ArtifactLocation"]
      projectionChanges `shouldSatisfy` all ((== VAdvisory) . (.consumerBuild) . (.vector))
      map (.detail) projectionChanges
        `shouldSatisfy` any (T.isInfixOf "group=artifact_group, targets=[artifact_target], read-models=[ArtifactLookup], replayable=yes")
      [kindOfChange change | change <- diffSpecs commandOnly commandOnlyChanged, (.facet) (kindOfChange change) == "mapped-projection"]
        `shouldBe` []
      case ReplayImpact.catalogReplayImpactServices (stableCheckedService spec) (stableCheckedService wireChanged) of
        CatalogReplayAffected groups targets sources adapters invalidates -> do
          groups `shouldBe` Set.singleton "artifact_group"
          targets `shouldBe` Set.singleton "artifact_target"
          sources `shouldBe` Set.singleton "aggregate:Catalog"
          adapters `shouldBe` Set.singleton "artifactProjection"
          invalidates `shouldBe` True
        CatalogReplayNeutral -> expectationFailure "mapped event wire change was catalog replay-neutral"
      ReplayImpact.catalogReplayImpactServices (stableCheckedService commandOnly) (stableCheckedService commandOnlyChanged)
        `shouldBe` CatalogReplayNeutral
      let snapshot = semanticImpactSnapshot impact
      Aeson.decode (Aeson.encode snapshot) `shouldBe` Just snapshot

    it "lowers mapped queues and checked read-model query contracts" $ do
      source <- mappedConsumerSurfaceSource
      parsed <- case parseSource "<mapped-consumer-pending>" source of
        Left failure -> expectationFailure (show failure) >> fail "unreachable"
        Right value -> pure value
      let codes = map (.code) (validateService (checkedSource parsed))
      codes `shouldNotContain` [MappedReadModelLoweringPending]
      codes `shouldNotContain` [MappedQueueLoweringPending]
      case [workqueue | NWorkqueue workqueue <- (.nodes) ((.spec) parsed)] of
        [workqueue] -> do
          let modules = scaffoldWorkqueueForService (defaultContext (parsed.spec.context)) (checkedSource parsed) workqueue
              queue = generatedTextEndingIn "Queue.hs" modules
          queue `shouldSatisfy` T.isInfixOf "jobData :: ![Maybe ArtifactInfo]"
          queue `shouldSatisfy` T.isInfixOf "encodeArtifactInfoMapped"
          queue `shouldSatisfy` T.isInfixOf "explicitParseField (\\value -> (parseJSON value :: Parser [Value])"
          queue `shouldNotSatisfy` T.isInfixOf "Vendor.Geometry"
        workqueues -> expectationFailure ("unexpected workqueues: " <> show workqueues)
      case [readModel | NReadModel readModel <- (.nodes) ((.spec) parsed)] of
        [readModel] -> do
          let ctx = defaultContext (parsed.spec.context)
              modules = scaffoldReadModelForService ctx (checkedSource parsed) readModel
              contract = generatedTextEndingIn "QueryContract.hs" modules
              generatedReadModel = generatedTextEndingIn "ReadModel.hs" modules
              holes = T.intercalate "\n" [(.text) value | value <- modules, (.kind) value == HoleStub]
          contract `shouldSatisfy` T.isInfixOf "type ArtifactLookupQueryInput = ArtifactInfo"
          contract `shouldSatisfy` T.isInfixOf "type ArtifactLookupQueryResult = Maybe ArtifactLocation"
          contract `shouldSatisfy` T.isInfixOf "import Example.Artifact.Domain (ArtifactInfo, ArtifactLocation)"
          contract `shouldNotSatisfy` T.isInfixOf "Vendor.Geometry"
          generatedReadModel `shouldSatisfy` T.isInfixOf ".QueryContract (ArtifactLookupQueryInput, ArtifactLookupQueryResult)"
          generatedReadModel `shouldSatisfy` T.isInfixOf ".ReadModelHoles (artifactLookupQuery)"
          generatedReadModel `shouldNotSatisfy` T.isInfixOf "applyArtifactLookup"
          holes `shouldSatisfy` T.isInfixOf ".QueryContract (ArtifactLookupQueryInput, ArtifactLookupQueryResult)"
          holes `shouldNotSatisfy` T.isInfixOf "type ArtifactLookupQueryInput = ()"
        readModels -> expectationFailure ("unexpected mapped read models: " <> show readModels)
      queryContractIdentities ((.spec) parsed)
        `shouldBe` Right
          [ QueryContractIdentity
              { readModel = "ArtifactLookup",
                position = QueryInputConsumer,
                typeExpression = "ArtifactInfo",
                mappedDependencies = ["ArtifactInfo", "ArtifactKind", "ArtifactLocation"]
              },
            QueryContractIdentity
              { readModel = "ArtifactLookup",
                position = QueryResultConsumer,
                typeExpression = "Optional ArtifactLocation",
                mappedDependencies = ["ArtifactLocation"]
              }
          ]

    it "reports a retained legacy query hole until the application adopts the generated aliases" $
      withTempDirectory "keiro-dsl-query-contract-migration" $ \out -> do
        source <- mappedConsumerSurfaceSource
        parsed <- case parseSource "<mapped-query-migration>" source of
          Left failure -> expectationFailure (show failure) >> fail "unreachable"
          Right value -> pure value
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
        modules <- case planTestServiceScaffold ctx service of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right values -> pure values
        readModel <- case [value | NReadModel value <- (.nodes) spec] of
          [value] -> pure value
          values -> expectationFailure ("unexpected mapped read models: " <> show values) >> fail "unreachable"
        let typedHole = case [value | value <- modules, (.kind) value == HoleStub, "ReadModelHoles.hs" `T.isSuffixOf` T.pack (value.path)] of
              [value] -> value
              values -> error ("expected one query hole, got " <> show (map (.path) values))
            legacyHole = case [value | value <- scaffoldReadModel ctx readModel, (.kind) value == HoleStub] of
              [value] -> value
              values -> error ("expected one legacy query hole, got " <> show (map (.path) values))
            holePath = out </> typedHole.path
            run = executeServiceScaffold out False "mapped-query.keiro" ((.sourceLanguage) parsed) ctx service modules
        createDirectoryIfMissing True (takeDirectory holePath)
        TIO.writeFile holePath ((.text) legacyHole)
        TIO.writeFile
          (out </> recordFileName (spec.context))
          ( renderRecord
              ScaffoldRecord
                { specPath = "mapped-query.keiro",
                  moduleRoot = "",
                  layout = "prefixed",
                  sourceLanguage = (.sourceLanguage) parsed,
                  languageContract = checkedLanguageContract service,
                  namingEdition = IdiomaticNamingV2,
                  moduleRoles = [],
                  files = [],
                  mappings = [],
                  idDomains = [],
                  nominalEqualities = [],
                  bindingObligations = [],
                  behaviorRequirements = [],
                  projectionCatalogFacts = [],
                  queryContractBaseline = False,
                  queryContracts = [],
                  routerSelections = [],
                  semanticImpact = Nothing
                }
          )
        first <- run >>= either (\refusals -> expectationFailure (show refusals) >> fail "unreachable") pure
        (.queryContractBaselineUnavailable) first `shouldBe` True
        (.queryContractMigrations) first
          `shouldBe` [ QueryContractMigration
                         { owner = "ArtifactLookup",
                           path = typedHole.path,
                           requiredImport = "import Generated.ConsumerDemo.ArtifactLookup.QueryContract (ArtifactLookupQueryInput, ArtifactLookupQueryResult)"
                         }
                     ]
        renderScaffoldReport first `shouldSatisfy` any (T.isInfixOf "remove the local QueryInput/QueryResult type aliases")
        renderScaffoldReport first `shouldSatisfy` any (T.isInfixOf "baseline unavailable")
        currentLedger <- TIO.readFile ((.recordPath) first)
        case parseRecord currentLedger of
          Just record -> do
            (.queryContractBaseline) record `shouldBe` True
            length ((.queryContracts) record) `shouldBe` 2
          Nothing -> expectationFailure "standalone query-contract ledger did not parse"
        case filter ("query-contract " `T.isPrefixOf`) (T.lines currentLedger) of
          row : _ -> parseRecord (currentLedger <> row <> "\n") `shouldBe` Nothing
          [] -> expectationFailure "expected standalone query-contract rows"
        TIO.writeFile holePath ((.text) typedHole)
        second <- run >>= either (\refusals -> expectationFailure (show refusals) >> fail "unreachable") pure
        (.queryContractMigrations) second `shouldBe` []
        [disposition | (value, disposition) <- (.dispositions) second, value.path == typedHole.path]
          `shouldBe` [Skipped]

        changedParsed <- case parseSource "<mapped-query-drift>" (T.replace "query result = Optional ArtifactLocation" "query result = ArtifactLocation" source) of
          Left failure -> expectationFailure (show failure) >> fail "unreachable"
          Right value -> pure value
        let changedService = checkedSource changedParsed
        changedModules <- case planTestServiceScaffold ctx changedService of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right values -> pure values
        third <-
          executeServiceScaffold out False "mapped-query.keiro" ((.sourceLanguage) changedParsed) ctx changedService changedModules
            >>= either (\refusals -> expectationFailure (show refusals) >> fail "unreachable") pure
        (.queryContractDrift) third
          `shouldSatisfy` \case
            [QueryContractDrift {key = ("ArtifactLookup", QueryResultConsumer)}] -> True
            _ -> False
        renderScaffoldReport third `shouldSatisfy` any (T.isInfixOf "query contract drift: 1")

        let withoutQuerySource =
              T.unlines
                [ line
                | line <- T.lines source,
                  not ("  query input =" `T.isPrefixOf` line),
                  not ("  query result =" `T.isPrefixOf` line)
                ]
        withoutQueryParsed <- case parseSource "<mapped-query-removed>" withoutQuerySource of
          Left failure -> expectationFailure (show failure) >> fail "unreachable"
          Right value -> pure value
        let withoutQueryService = checkedSource withoutQueryParsed
        withoutQueryModules <- case planTestServiceScaffold ctx withoutQueryService of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right values -> pure values
        fourth <-
          executeServiceScaffold out False "mapped-query.keiro" ((.sourceLanguage) withoutQueryParsed) ctx withoutQueryService withoutQueryModules
            >>= either (\refusals -> expectationFailure (show refusals) >> fail "unreachable") pure
        length ((.queryContractDrift) fourth) `shouldBe` 2
        removedLedger <- TIO.readFile ((.recordPath) fourth)
        case parseRecord removedLedger of
          Just record -> do
            (.queryContractBaseline) record `shouldBe` True
            (.queryContracts) record `shouldBe` []
          Nothing -> expectationFailure "removed query-contract ledger did not parse"

    it "plans and records the same typed query contract across workspace members" $
      withTempDirectory "keiro-dsl-mapped-query-workspace" $ \out -> do
        plan <- shouldPlanWorkspace "test/fixtures/mapped-readmodel-workspace/service.keiro-workspace"
        let contractRows =
              [ (scaffoldModule, provenance)
              | (scaffoldModule, provenance) <- (.modules) plan,
                "QueryContract.hs" `T.isSuffixOf` T.pack ((.path) scaffoldModule)
              ]
        case contractRows of
          [(contract, MemberOwned owner)] -> do
            owner `shouldBe` "readmodel.keiro"
            (.text) contract `shouldSatisfy` T.isInfixOf "type AccountSummaryQueryInput = AccountLookup"
            (.text) contract `shouldSatisfy` T.isInfixOf "type AccountSummaryQueryResult = Maybe AccountSummary"
          values -> expectationFailure ("unexpected workspace query contracts: " <> show values)
        report <- executeWorkspaceScaffold out False plan >>= either (\refusals -> expectationFailure (show refusals) >> fail "unreachable") pure
        (.queryContractMigrations) report `shouldBe` []
        recordText <- TIO.readFile ((.recordPath) report)
        case parseWorkspaceRecord recordText of
          Just record -> do
            (.queryContractBaseline) record `shouldBe` True
            length ((.queryContracts) record) `shouldBe` 2
          Nothing -> expectationFailure "workspace query-contract ledger did not parse"

  describe "complete mapped surfaces" $ do
    it "projects exact queue, query, event, snapshot, and replayable projection consequences" $ do
      aggregateSpec <- specOf "test/fixtures/semantic-impact.keiro"
      queueSpec <- specOf "test/fixtures/mapped-workqueue.keiro"
      querySpec <- specOf "test/fixtures/mapped-readmodel.keiro"
      projectionSpec <- specOf "test/fixtures/projection-catalog.keiro"
      let aggregateImpact = semanticImpactForSpec aggregateSpec
          queueImpact = semanticImpactForSpec queueSpec
          queryImpact = semanticImpactForSpec querySpec
          projectionImpact = semanticImpactForSpec projectionSpec
          consequences impact declaration = Map.findWithDefault Set.empty (MappedKey declaration) ((.declarationConsequences) impact)
      consequences aggregateImpact "CommandPayload"
        `shouldBe` Set.singleton (MappedConsumerBuild (AggregateConsumer "Alpha"))
      consequences aggregateImpact "EventPayload"
        `shouldBe` Set.fromList [MappedConsumerBuild (AggregateConsumer "Alpha"), MappedPrivateEventHistory "Alpha"]
      consequences aggregateImpact "RegisterPayload"
        `shouldBe` Set.fromList [MappedConsumerBuild (AggregateConsumer "Alpha"), MappedSnapshotHydration "Alpha"]
      consequences queueImpact "JobPayload"
        `shouldBe` Set.fromList [MappedConsumerBuild (WorkqueueConsumer "mapped_jobs"), MappedWorkqueueHistory "mapped_jobs"]
      consequences queryImpact "AccountLookup"
        `shouldBe` Set.fromList [MappedConsumerBuild (ReadModelQueryConsumer "account_summary" MappedQueryInput), MappedQueryApi "account_summary" MappedQueryInput]
      consequences queryImpact "AccountSummary"
        `shouldBe` Set.fromList [MappedConsumerBuild (ReadModelQueryConsumer "account_summary" MappedQueryResult), MappedQueryApi "account_summary" MappedQueryResult]
      consequences projectionImpact "OrderPayload"
        `shouldBe` Set.fromList
          [ MappedConsumerBuild (AggregateConsumer "Orders"),
            MappedPrivateEventHistory "Orders",
            MappedConsumerBuild (DerivedProjectionConsumer (CatalogProjectionConsumer "order_summary_writer" "Orders")),
            MappedProjectionHandlerReview (CatalogProjectionConsumer "order_summary_writer" "Orders"),
            MappedProjectionRebuild (CatalogProjectionConsumer "order_summary_writer" "Orders") "reporting"
          ]

    it "reports every surface independently without inventing Json or heterogeneous typed roots" $ do
      queueSpec <- specOf "test/fixtures/mapped-workqueue.keiro"
      querySpec <- specOf "test/fixtures/mapped-readmodel.keiro"
      projectionSpec <- specOf "test/fixtures/projection-catalog.keiro"
      queueCoverage <- shouldResolveCoverage "mapped-workqueue.keiro" queueSpec
      queryCoverage <- shouldResolveCoverage "mapped-readmodel.keiro" querySpec
      projectionCoverage <- shouldResolveCoverage "projection-catalog.keiro" projectionSpec
      (.workqueuePayloads) ((.summary) queueCoverage)
        `shouldBe` Coverage.CoverageCounts 2 2 0 1
      (.readModelQueryInputs) ((.summary) queryCoverage)
        `shouldBe` Coverage.CoverageCounts 1 1 0 0
      (.readModelQueryResults) ((.summary) queryCoverage)
        `shouldBe` Coverage.CoverageCounts 1 1 0 0
      (.projectionTypedConsumers) ((.summary) projectionCoverage)
        `shouldBe` Coverage.CoverageCounts 3 0 3 0
      map (.consumer) [root | root <- (.roots) queryCoverage, (.surface) root `elem` [Coverage.ReadModelQueryInput, Coverage.ReadModelQueryResult]]
        `shouldBe` ["read-model-query:account_summary:input", "read-model-query:account_summary:result"]
      map (.surface) ((.unsupportedSurfaces) projectionCoverage)
        `shouldContain` ["projection-category:audit_writer:audit"]

    it "places one deterministic surface/consumer/root/path fact set behind the service facade" $ do
      services <- mapM checkedServiceOf ["test/fixtures/mapped-workqueue.keiro", "test/fixtures/mapped-readmodel.keiro", "test/fixtures/projection-catalog.keiro"]
      let facts = concatMap serviceConformanceFactValues services
          surfaceFacts = [(key, value) | (key, value) <- facts, "mapped-surface/" `T.isPrefixOf` key]
          keys = map fst surfaceFacts
      length keys `shouldBe` Set.size (Set.fromList keys)
      keys `shouldSatisfy` any (T.isInfixOf "/workqueue-payload/workqueue:mapped_jobs/JobPayload/workqueue mapped_jobs payload .job : JobPayload")
      keys `shouldSatisfy` any (T.isInfixOf "/read-model-query-input/read-model-query:account_summary:input/AccountLookup/readmodel account_summary query input : AccountLookup")
      keys `shouldSatisfy` any (T.isInfixOf "/projection-event-consumer/catalog-projection:order_summary_writer:Orders/OrderPayload/Orders event OrderRecorded .orderPayload : OrderPayload")
      map snd surfaceFacts `shouldSatisfy` any (T.isInfixOf "workqueue-history:mapped_jobs")
      map snd surfaceFacts `shouldSatisfy` any (T.isInfixOf "projection-rebuild:catalog-projection:order_summary_writer:Orders:reporting")

    it "keeps predecessor facades byte-stable while extending the Language 5 facade" $ do
      published <- checkedServiceOf "test/fixtures/semantic-impact.keiro"
      candidate <- checkedServiceOf "test/fixtures/mapped-workqueue.keiro"
      serviceConformanceFactKeys published
        `shouldSatisfy` all (not . T.isPrefixOf "mapped-surface/")
      serviceConformanceFactKeys candidate
        `shouldSatisfy` any (T.isPrefixOf "mapped-surface/")

    it "detects replay policy and observer relation drift without fabricating mapped declaration changes" $ do
      projectionSpec <- specOf "test/fixtures/projection-catalog.keiro"
      let makeLiveOnly node = case node of
            NProjectionOwner owner@ProjectionOwnerNode {name = "order_summary_writer"} ->
              NProjectionOwner (projectionOwnerWithReplay (ProjectionLiveOnly "candidate is intentionally live-only") owner)
            other -> other
          moveObserver node = case node of
            NReadModel readModel@ReadModelNode {name = "catalogAudit"} ->
              NReadModel (readModelWithObservedTargets ["order_summary"] readModel)
            other -> other
          liveOnly = specWithNodes (map makeLiveOnly projectionSpec.nodes) projectionSpec
          observerMoved = specWithNodes (map moveObserver projectionSpec.nodes) projectionSpec
          liveDeltas = CheckedDiff.mappedSemanticImpact projectionSpec liveOnly
          observerDeltas = CheckedDiff.mappedSemanticImpact projectionSpec observerMoved
      map (.declaration) liveDeltas `shouldBe` [MappedKey "OrderPayload", MappedKey "SharedReference"]
      map (.currentConsequences) liveDeltas
        `shouldSatisfy` all (maybe False (not . any (\case MappedProjectionRebuild (CatalogProjectionConsumer "order_summary_writer" "Orders") _ -> True; _ -> False) . Set.toList))
      map (.declaration) observerDeltas `shouldBe` [MappedKey "OrderPayload", MappedKey "SharedReference"]
      map (.currentEvidence) observerDeltas
        `shouldSatisfy` any (maybe False (any (maybe False (T.isInfixOf "catalogAudit") . (.operation)) . Set.toList))
      diffMapped projectionSpec liveOnly `shouldBe` []

  describe "mapped surface ledger" $ do
    it "round-trips complete evidence, treats aggregate-only history as unknown, and rejects corrupt known tags" $ do
      spec <- specOf "test/fixtures/semantic-impact.keiro"
      let snapshot = semanticImpactSnapshotForSpec spec
          legacy = semanticImpactSnapshotWithoutEvidence snapshot
          declaration = MappedKey "EventPayload"
          report = semanticImpactReport (Just legacy) snapshot [declaration]
          encoded = LazyText.toStrict (LazyTextEncoding.decodeUtf8 (Aeson.encode snapshot))
          corrupt = T.replace "\"surface\":\"aggregate-command\"" "\"surface\":\"future-surface\"" encoded
      Aeson.decode (Aeson.encode snapshot) `shouldBe` Just snapshot
      Aeson.decode (Aeson.encode legacy) `shouldBe` Just legacy
      (.deltas) report `shouldSatisfy` \case
        [delta] -> (.previousEvidence) delta == Nothing && (.currentEvidence) delta /= Nothing
        _ -> False
      renderSemanticImpactReport report `shouldSatisfy` any (T.isInfixOf "previous roots: baseline unavailable")
      corrupt `shouldNotBe` encoded
      (Aeson.decode (LazyTextEncoding.encodeUtf8 (LazyText.fromStrict corrupt)) :: Maybe SemanticImpactSnapshot) `shouldBe` Nothing

  describe "mapped compatibility vectors" $ do
    it "keeps queue, query, event, snapshot, and projection consequences orthogonal" $ do
      queueSpec <- specOf "test/fixtures/mapped-workqueue.keiro"
      querySpec <- specOf "test/fixtures/mapped-readmodel.keiro"
      aggregateSpec <- specOf "test/fixtures/semantic-impact.keiro"
      projectionSpec <- specOf "test/fixtures/projection-catalog.keiro"
      let changeQueue node = case node of
            NWorkqueue queue ->
              NWorkqueue (workqueueWithPayload [if field.name == "job" then wqFieldWithValueType (TypedQueueExpression (TRef "JobMetadata")) field else field | field <- queue.payload] queue)
            other -> other
          queueChanged = specWithNodes (map changeQueue queueSpec.nodes) queueSpec
          changeQuery node = case node of
            NReadModel readModel@ReadModelNode {queryTypes = Just queryPair} ->
              NReadModel (readModelWithQueryTypes (Just (ReadModelQueryTypes (TRef "TenantKey") queryPair.result queryPair.inputLoc queryPair.resultLoc)) readModel)
            other -> other
          queryChanged = specWithNodes (map changeQuery querySpec.nodes) querySpec
          findKind predicate changes = case [kindOfChange change | change <- changes, predicate (kindOfChange change)] of
            value : _ -> value
            [] -> error "expected mapped compatibility finding"
          queueKind = findKind ((== WqPayloadFieldChanged) . (.code)) (diffSpecs queueSpec queueChanged)
          queryKind = findKind ((== ReadModelQueryInputChanged) . (.code)) (diffSpecs querySpec queryChanged)
          eventKind = findKind ((== "mapped-event") . (.facet)) [change | mutation <- mappedWireMutations aggregateSpec, change <- diffSpecs aggregateSpec ((.mmCandidate) mutation)]
          snapshotKind = findKind ((== "mapped-register") . (.facet)) [change | mutation <- mappedWireMutations aggregateSpec, change <- diffSpecs aggregateSpec ((.mmCandidate) mutation)]
          projectionChanged = mapMappedDeclaration "OrderPayload" changeProjectionMappedWire projectionSpec
          projectionKind = findKind ((== "mapped-projection") . (.facet)) (diffSpecs projectionSpec projectionChanged)
      (.mappedConsequences) queueKind
        `shouldBe` Set.fromList [MappedConsumerBuild (WorkqueueConsumer "mapped_jobs"), MappedWorkqueueHistory "mapped_jobs"]
      (.privateHistoryRead) (queueKind.vector) `shouldBe` VNotApplicable
      (.consumerBuild) (queueKind.vector) `shouldBe` VBreaking
      (.mappedConsequences) queryKind
        `shouldBe` Set.fromList [MappedConsumerBuild (ReadModelQueryConsumer "account_summary" MappedQueryInput), MappedQueryApi "account_summary" MappedQueryInput]
      (.snapshotHydration) (queryKind.vector) `shouldBe` VNotApplicable
      (.mappedConsequences) eventKind `shouldSatisfy` Set.member (MappedPrivateEventHistory "Alpha")
      (.mappedConsequences) snapshotKind `shouldSatisfy` Set.member (MappedSnapshotHydration "Alpha")
      (.mappedConsequences) projectionKind `shouldSatisfy` Set.member (MappedProjectionHandlerReview (CatalogProjectionConsumer "order_summary_writer" "Orders"))
      (.mappedConsequences) projectionKind
        `shouldSatisfy` Set.member (MappedProjectionRebuild (CatalogProjectionConsumer "order_summary_writer" "Orders") "reporting")

  describe "mapped surface qualification" $ do
    it "selects every explicit and derived surface from one integrated Language 5 authority" $ do
      service <- checkedServiceOf "test/fixtures/projection-catalog.keiro"
      workspace <- shouldComposeWorkspace "test/fixtures/projection-catalog.keiro-workspace"
      coverage <- shouldResolveCoverage "projection-catalog.keiro" (checkedSpec service)
      let impact = semanticImpactForSpec (checkedSpec service)
          qualify name = qualifyMappedSurface impact (MappedKey name)
          orderPayload = qualify "OrderPayload"
          sharedReference = qualify "SharedReference"
          qualificationPayload = qualify "QualificationPayload"
          queueMetadata = qualify "QueueMetadata"
          queryCriteria = qualify "QueryCriteria"
          qualificationResult = qualify "QualificationResult"
          registerState = qualify "RegisterState"
          unused = qualify "UnusedQualification"
          standaloneSnapshot = semanticImpactSnapshot impact
      standaloneSnapshot `shouldBe` semanticImpactSnapshotForSpec ((.mergedSpec) workspace)
      Aeson.decode (Aeson.encode standaloneSnapshot) `shouldBe` Just standaloneSnapshot
      (.consumers) orderPayload
        `shouldBe` Set.fromList
          [ AggregateConsumer "Orders",
            DerivedProjectionConsumer (CatalogProjectionConsumer "order_summary_writer" "Orders")
          ]
      Set.map (.rootKind) ((.evidence) orderPayload)
        `shouldBe` Set.fromList [MappedCommandFieldRoot, MappedEventFieldRoot, MappedProjectionEventRoot]
      (.consequences) orderPayload
        `shouldSatisfy` Set.member (MappedProjectionRebuild (CatalogProjectionConsumer "order_summary_writer" "Orders") "reporting")
      (.consumers) sharedReference
        `shouldBe` Set.fromList
          [ AggregateConsumer "Orders",
            AggregateConsumer "Shipments",
            WorkqueueConsumer "qualification_jobs",
            DerivedProjectionConsumer (CatalogProjectionConsumer "order_summary_writer" "Orders"),
            DerivedProjectionConsumer (CatalogProjectionConsumer "shipment_writer" "Shipments")
          ]
      (.consumers) qualificationPayload `shouldBe` Set.singleton (WorkqueueConsumer "qualification_jobs")
      (.consequences) qualificationPayload
        `shouldBe` Set.fromList [MappedConsumerBuild (WorkqueueConsumer "qualification_jobs"), MappedWorkqueueHistory "qualification_jobs"]
      (.consumers) queueMetadata `shouldBe` Set.singleton (WorkqueueConsumer "qualification_jobs")
      (.consumers) queryCriteria `shouldBe` Set.singleton (ReadModelQueryConsumer "order_inline" MappedQueryInput)
      (.consequences) queryCriteria
        `shouldBe` Set.fromList [MappedConsumerBuild (ReadModelQueryConsumer "order_inline" MappedQueryInput), MappedQueryApi "order_inline" MappedQueryInput]
      (.consumers) qualificationResult `shouldBe` Set.singleton (ReadModelQueryConsumer "order_inline" MappedQueryResult)
      (.consequences) qualificationResult
        `shouldBe` Set.fromList [MappedConsumerBuild (ReadModelQueryConsumer "order_inline" MappedQueryResult), MappedQueryApi "order_inline" MappedQueryResult]
      (.consumers) registerState `shouldBe` Set.singleton (AggregateConsumer "Orders")
      (.consequences) registerState
        `shouldBe` Set.fromList [MappedConsumerBuild (AggregateConsumer "Orders"), MappedSnapshotHydration "Orders"]
      (.consumers) unused `shouldBe` Set.empty
      (.evidence) unused `shouldBe` Set.empty
      (.consequences) unused `shouldBe` Set.empty
      (.workqueuePayloads) ((.summary) coverage) `shouldBe` Coverage.CoverageCounts 4 1 3 1
      (.readModelQueryInputs) ((.summary) coverage) `shouldBe` Coverage.CoverageCounts 1 0 1 0
      (.readModelQueryResults) ((.summary) coverage) `shouldBe` Coverage.CoverageCounts 1 0 1 0
      (.projectionTypedConsumers) ((.summary) coverage) `shouldBe` Coverage.CoverageCounts 3 0 3 0
      map (.surface) ((.unsupportedSurfaces) coverage)
        `shouldContain` ["projection-category:audit_writer:audit"]

    it "aligns every mapping diff with the authority's exact consequence set" $ do
      service <- checkedServiceOf "test/fixtures/projection-catalog.keiro"
      let spec = checkedSpec service
          impact = semanticImpactForSpec spec
          opaqueMutation name = mapMappedDeclaration name changeProjectionMappedWire spec
          mutations =
            [ ("OrderPayload", opaqueMutation "OrderPayload"),
              ("SharedReference", opaqueMutation "SharedReference"),
              ("QualificationPayload", addMappedOptionalTextField "QualificationPayload" "addedNote" spec),
              ("QueueMetadata", opaqueMutation "QueueMetadata"),
              ("QueryCriteria", opaqueMutation "QueryCriteria"),
              ("QualificationResult", opaqueMutation "QualificationResult"),
              ("RegisterState", opaqueMutation "RegisterState"),
              ("UnusedQualification", opaqueMutation "UnusedQualification")
            ]
          actualConsequences candidate =
            Set.unions
              [ (.mappedConsequences) (kindOfChange change)
              | change <- diffServices service (checkedServiceWithSpec candidate service)
              ]
          expectedConsequences name = (.consequences) (qualifyMappedSurface impact (MappedKey name))
      forM_ mutations $ \(name, candidate) ->
        actualConsequences candidate `shouldBe` expectedConsequences name

    it "pins exact generated locality and keeps it constant under unrelated workspace growth" $ do
      service <- checkedServiceOf "test/fixtures/projection-catalog.keiro"
      grown <- shouldComposeWorkspace "test/fixtures/projection-catalog-grown.keiro-workspace"
      let spec = checkedSpec service
          ctx = defaultContext (spec.context)
          baseline = scaffoldServiceModules ctx service
          modulesFor candidate = scaffoldServiceModules ctx (checkedServiceWithSpec candidate service)
          deltaFor candidate = generatedTreeDelta baseline (modulesFor candidate)
          opaqueDelta name = deltaFor (mapMappedDeclaration name changeProjectionMappedWire spec)
          structuralDelta = deltaFor (addMappedOptionalTextField "QualificationPayload" "addedNote" spec)
          structuralPaths =
            Set.fromList
              [ "Generated/CatalogDemo/QualificationJobs/Queue.hs",
                "Generated/CatalogDemo/Structural/Shape/QualificationPayload.hs",
                "Generated/CatalogDemo/StructuralConformance.hs"
              ]
          projectionPaths =
            Set.fromList
              [ "Generated/CatalogDemo/ProjectionCatalog.hs",
                "Generated/CatalogDemo/StructuralConformance.hs"
              ]
          registerPaths =
            Set.fromList
              [ "Generated/CatalogDemo/Orders/Transducer.hs",
                "Generated/CatalogDemo/StructuralConformance.hs"
              ]
          serviceOnly = Set.singleton "Generated/CatalogDemo/StructuralConformance.hs"
          assertExact delta paths = do
            (.changedPaths) delta `shouldBe` paths
            (.addedPaths) delta `shouldBe` Set.empty
            (.removedPaths) delta `shouldBe` Set.empty
      assertExact structuralDelta structuralPaths
      assertExact (opaqueDelta "OrderPayload") projectionPaths
      assertExact (opaqueDelta "SharedReference") projectionPaths
      assertExact (opaqueDelta "RegisterState") registerPaths
      forM_ ["QueueMetadata", "QueryCriteria", "QualificationResult", "UnusedQualification"] $ \name ->
        assertExact (opaqueDelta name) serviceOnly
      let grownCandidate = mapWorkspaceSpec (mapMappedDeclaration "OrderPayload" changeProjectionMappedWire) grown
      grownBaselinePlan <- shouldPlanWorkspaceSpec grown
      grownCandidatePlan <- shouldPlanWorkspaceSpec grownCandidate
      let grownDelta = generatedTreeDelta (map fst ((.modules) grownBaselinePlan)) (map fst ((.modules) grownCandidatePlan))
      (.changedPaths) grownDelta `shouldBe` (.changedPaths) (opaqueDelta "OrderPayload")
      (.addedPaths) grownDelta `shouldBe` Set.empty
      (.removedPaths) grownDelta `shouldBe` Set.empty

    it "keeps Language 5 syntax gated and predecessor service facades unchanged" $ do
      candidate <- checkedServiceOf "test/fixtures/projection-catalog.keiro"
      published <- checkedServiceOf "test/fixtures/consumer-types.keiro"
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      let candidateKeys = serviceConformanceFactKeys candidate
          candidateValues = map snd (serviceConformanceFactValues candidate)
      candidateKeys `shouldSatisfy` any (T.isPrefixOf "mapped-surface/")
      length candidateKeys `shouldBe` Set.size (Set.fromList candidateKeys)
      candidateValues `shouldSatisfy` any (T.isInfixOf "workqueue-history:qualification_jobs")
      candidateValues `shouldSatisfy` any (T.isInfixOf "query-api:order_inline:input")
      candidateValues `shouldSatisfy` any (T.isInfixOf "projection-handler-review:catalog-projection:order_summary_writer:Orders")
      serviceConformanceFactKeys published `shouldSatisfy` all (not . T.isPrefixOf "mapped-surface/")
      parseSource "<published-mapped-surfaces>" (T.replace "language keiro-dsl 5" "language keiro-dsl 4" source)
        `shouldSatisfy` isLeft

  describe "language support" $ do
    it "serializes support from the registered version and decodes older records" $ do
      v1Contract <- maybe (expectationFailure "missing v1 contract" >> fail "unreachable") pure (effectiveLanguageContractForVersion =<< languageVersion 1)
      v4Contract <- maybe (expectationFailure "missing v4 contract" >> fail "unreachable") pure (effectiveLanguageContractForVersion =<< languageVersion 4)
      v5Contract <- maybe (expectationFailure "missing v5 contract" >> fail "unreachable") pure (effectiveLanguageContractForVersion =<< languageVersion 5)
      effectiveLanguageSupport v1Contract `shouldBe` CompatibilityOnly
      effectiveLanguageSupport v4Contract `shouldBe` CompatibilityOnly
      effectiveLanguageSupport v5Contract `shouldBe` Stable
      Aeson.toJSON v5Contract
        `shouldBe` object
          [ "languageVersion" .= (5 :: Int),
            "runtimeSemantics" .= ("keiro-dsl/runtime-semantics/4" :: T.Text),
            "languageSupport" .= ("stable" :: T.Text)
          ]
      Aeson.eitherDecode "{\"languageVersion\":1,\"runtimeSemantics\":\"keiro-dsl/runtime-semantics/1\"}"
        `shouldBe` Right v1Contract

    it "reports stable and compatibility-only support through source inspection" $ do
      (stableCode, stableOut, stableErr) <- runKeiroDsl ["inspect", "test/fixtures/projection-catalog.keiro", "--format=json"]
      stableCode `shouldBe` ExitSuccess
      stableErr `shouldBe` ""
      stableOut `shouldContain` "\"languageVersion\":5"
      stableOut `shouldContain` "\"languageSupport\":\"stable\""
      (predecessorCode, predecessorOut, predecessorErr) <- runKeiroDsl ["inspect", "test/fixtures/contract-v4.keiro", "--format=json"]
      predecessorCode `shouldBe` ExitSuccess
      predecessorErr `shouldBe` ""
      predecessorOut `shouldContain` "\"languageVersion\":4"
      predecessorOut `shouldContain` "\"languageSupport\":\"compatibility-only\""
      (compatibilityCode, compatibilityOut, compatibilityErr) <- runKeiroDsl ["inspect", "test/fixtures/language-v1.keiro", "--format=json"]
      compatibilityCode `shouldBe` ExitSuccess
      compatibilityErr `shouldBe` ""
      compatibilityOut `shouldContain` "\"languageVersion\":1"
      compatibilityOut `shouldContain` "\"languageSupport\":\"compatibility-only\""

    it "surfaces non-stable contracts and enforces a released minimum language" $ do
      let legacyPath = "test/fixtures/language-legacy.keiro"
          stablePath = "test/fixtures/projection-catalog.keiro"
      (legacyCode, legacyOut, legacyErr) <- runKeiroDsl ["check", legacyPath]
      legacyCode `shouldBe` ExitSuccess
      legacyOut `shouldBe` "OK\n"
      legacyErr `shouldContain` "language contract: effective keiro-dsl 1 (legacy-unversioned, compatibility-only, runtime semantics keiro-dsl/runtime-semantics/1)"
      legacyErr `shouldContain` "language-5 strict spec-surface validation is not applied"

      (stableCode, stableOut, stableErr) <- runKeiroDsl ["check", stablePath]
      stableCode `shouldBe` ExitSuccess
      stableOut `shouldBe` "OK\n"
      stableErr `shouldBe` ""

      (floorCode, floorOut, floorErr) <- runKeiroDsl ["check", legacyPath, "--min-language", "4"]
      floorCode `shouldBe` ExitFailure 1
      floorOut `shouldBe` ""
      floorErr `shouldContain` "language-legacy.keiro:1: error[LanguageVersionBelowMinimum]"
      floorErr `shouldContain` "effective language version 1 (legacy-unversioned) is below the required minimum 4"

      (metCode, metOut, _) <- runKeiroDsl ["check", legacyPath, "--min-language", "1"]
      metCode `shouldBe` ExitSuccess
      metOut `shouldBe` "OK\n"

      (unsupportedCode, _, unsupportedErr) <- runKeiroDsl ["check", legacyPath, "--min-language", "9"]
      unsupportedCode `shouldBe` ExitFailure 1
      unsupportedErr `shouldContain` "supported versions: 1, 2, 3, 4, 5"

    it "attributes a workspace language floor to its manifest and every member" $ do
      let v1Member = T.unlines ["language keiro-dsl 1", "context language-floor"]
      withInlineWorkspace
        "keiro-dsl-language-floor"
        ( "language-floor",
          [ ("domain/a.keiro", v1Member),
            ("domain/b.keiro", v1Member)
          ]
        )
        $ \root _ _ -> do
          let manifest = root </> "service.keiro-workspace"
          (floorCode, floorOut, floorErr) <- runKeiroDsl ["check", manifest, "--min-language", "4"]
          floorCode `shouldBe` ExitFailure 1
          floorOut `shouldBe` ""
          floorErr `shouldContain` (manifest <> ":1: error[LanguageVersionBelowMinimum]")
          floorErr `shouldContain` "domain/a.keiro:1: note: member selects effective language version 1"
          floorErr `shouldContain` "domain/b.keiro:1: note: member selects effective language version 1"
          floorErr `shouldContain` "workspace, 0 legacy-unversioned member(s)"

          (metCode, metOut, _) <- runKeiroDsl ["check", manifest, "--min-language", "1"]
          metCode `shouldBe` ExitSuccess
          metOut `shouldBe` "OK\n"

  describe "warning enforcement" $ do
    it "round-trips every stable diagnostic code spelling" $ do
      forM_ [minBound .. maxBound] $ \diagnosticCode ->
        parseDiagnosticCode (diagnosticCodeText diagnosticCode) `shouldBe` Just diagnosticCode

    it "fails only the warnings selected by invocation policy" $ do
      let fixture = "test/fixtures/deny-unlogged.keiro"
          warningText = "warning[WqUnloggedDurability]"
          summaryText = "check: 1 warning(s) escalated to failure (denied: WqUnloggedDurability)"

      (plainCode, plainOut, plainErr) <- runKeiroDsl ["check", fixture]
      plainCode `shouldBe` ExitSuccess
      plainOut `shouldBe` "OK\n"
      plainErr `shouldContain` warningText
      plainErr `shouldNotContain` "escalated to failure"

      (allCode, allOut, allErr) <- runKeiroDsl ["check", fixture, "--deny-warnings"]
      allCode `shouldBe` ExitFailure 1
      allOut `shouldBe` ""
      allErr `shouldContain` warningText
      allErr `shouldContain` summaryText

      (selectedCode, selectedOut, selectedErr) <- runKeiroDsl ["check", fixture, "--deny", "WqUnloggedDurability"]
      selectedCode `shouldBe` ExitFailure 1
      selectedOut `shouldBe` ""
      selectedErr `shouldContain` warningText
      selectedErr `shouldContain` summaryText

      (otherCode, otherOut, otherErr) <- runKeiroDsl ["check", fixture, "--deny", "WireSchemaVersionMismatch"]
      otherCode `shouldBe` ExitSuccess
      otherOut `shouldBe` "OK\n"
      otherErr `shouldContain` warningText
      otherErr `shouldNotContain` "escalated to failure"

      (unionCode, unionOut, unionErr) <-
        runKeiroDsl
          [ "check",
            fixture,
            "--deny-warnings",
            "--deny",
            "WireSchemaVersionMismatch,WqUnloggedDurability"
          ]
      unionCode `shouldBe` ExitFailure 1
      unionOut `shouldBe` ""
      unionErr `shouldContain` warningText
      unionErr `shouldContain` summaryText

      (unknownCode, _, unknownErr) <- runKeiroDsl ["check", fixture, "--deny", "NotACode"]
      unknownCode `shouldBe` ExitFailure 1
      unknownErr `shouldContain` "unknown diagnostic code `NotACode`"
      unknownErr `shouldContain` "warning[Code]"

    -- A denial that can never match reads like a CI gate and is not one. Every
    -- code `check` cannot emit is refused at the point of use instead.
    it "refuses a denial of a code check can never emit" $ do
      let fixture = "test/fixtures/deny-unlogged.keiro"

      (diffCode, _, diffErr) <- runKeiroDsl ["check", fixture, "--deny", "EvtFieldWireKeyChanged"]
      diffCode `shouldBe` ExitFailure 1
      diffErr `shouldContain` "`EvtFieldWireKeyChanged` is emitted by `keiro-dsl diff`"
      diffErr `shouldContain` "would never match"

      -- Rejection survives being hidden inside a comma-separated list.
      (mixedCode, _, mixedErr) <-
        runKeiroDsl ["check", fixture, "--deny", "WqUnloggedDurability,WorkflowShapeChanged"]
      mixedCode `shouldBe` ExitFailure 1
      mixedErr `shouldContain` "`WorkflowShapeChanged` is emitted by `keiro-dsl diff`"

      (codecCode, _, codecErr) <- runKeiroDsl ["check", fixture, "--deny", "CodecCompareDifference"]
      codecCode `shouldBe` ExitFailure 1
      codecErr `shouldContain` "generated codec-comparison path"

      -- A coverage code is emittable, but only by an invocation that asks for
      -- the coverage pass, so the requirement is stated rather than ignored.
      (noPassCode, _, noPassErr) <- runKeiroDsl ["check", fixture, "--deny", "CoverageOpaqueSurface"]
      noPassCode `shouldBe` ExitFailure 1
      noPassErr `shouldContain` "add --coverage-report FILE or drop the code"

      -- CoverageOpaqueGateExceeded is the error --fail-on-opaque itself raises,
      -- never a warning, so denying it is a silent no-op in every invocation —
      -- with or without the coverage pass it is refused with the real spelling.
      withTempDirectory "keiro-dsl-gate-exceeded-deny" $ \out -> do
        (gateCode, _, gateErr) <-
          runKeiroDsl
            ["check", fixture, "--coverage-report", out </> "coverage.json", "--deny", "CoverageOpaqueGateExceeded"]
        gateCode `shouldBe` ExitFailure 1
        gateErr `shouldContain` "pass --fail-on-opaque instead of denying it"
      (gateNoPassCode, _, gateNoPassErr) <- runKeiroDsl ["check", fixture, "--deny", "CoverageOpaqueGateExceeded"]
      gateNoPassCode `shouldBe` ExitFailure 1
      gateNoPassErr `shouldContain` "pass --fail-on-opaque instead of denying it"

    it "applies the warning policy to structural-coverage findings" $ do
      withTempDirectory "keiro-dsl-coverage-deny" $ \out -> do
        let fixture = "test/fixtures/structural-conformance.keiro"
            coveragePath = out </> "coverage.json"
            reportPath = out </> "nested" </> "dir" </> "check.json"
            warningText = "warning[CoverageOpaqueSurface]"

        -- Reporting-only by default: the finding prints and the check passes.
        (plainCode, _, plainErr) <-
          runKeiroDsl ["check", fixture, "--coverage-report", coveragePath]
        plainCode `shouldBe` ExitSuccess
        plainErr `shouldContain` warningText
        plainErr `shouldNotContain` "escalated to failure"

        -- Before ExecPlan 199 this combination exited 0 with the warning printed.
        (deniedCode, _, deniedErr) <-
          runKeiroDsl
            [ "check",
              fixture,
              "--coverage-report",
              coveragePath,
              "--deny-warnings",
              -- The nested path also proves --report-out creates parent dirs.
              "--report-out",
              reportPath
            ]
        deniedCode `shouldBe` ExitFailure 1
        deniedErr `shouldContain` warningText
        deniedErr `shouldContain` "escalated to failure (denied: CoverageOpaqueSurface)"

        report <- decodeJsonValue reportPath
        jsonField "ok" report `shouldBe` Just (Aeson.Bool False)
        (jsonField "summary" report >>= jsonField "deniedWarnings") `shouldBe` Just (Aeson.Number 1)
        case jsonField "diagnostics" report of
          Just (Aeson.Array entries) ->
            [entry | entry <- toList entries, jsonField "code" entry == Just (Aeson.String "CoverageOpaqueSurface")]
              `shouldSatisfy` \matching -> case matching of
                entry : _ ->
                  jsonField "severity" entry == Just (Aeson.String "warning")
                    && jsonField "denied" entry == Just (Aeson.Bool True)
                [] -> False
          other -> expectationFailure ("expected diagnostics array, got " <> show other)

        -- Selecting the code by name gates it just as precisely.
        (selectedCode, _, _) <-
          runKeiroDsl
            ["check", fixture, "--coverage-report", coveragePath, "--deny", "CoverageOpaqueSurface"]
        selectedCode `shouldBe` ExitFailure 1

    it "spells warning severity the same way in both JSON reports" $ do
      withTempDirectory "keiro-dsl-severity-vocabulary" $ \out -> do
        let coveragePath = out </> "coverage.json"
        (exitCode, _, _) <-
          runKeiroDsl
            ["check", "test/fixtures/structural-conformance.keiro", "--coverage-report", coveragePath]
        exitCode `shouldBe` ExitSuccess
        coverage <- decodeJsonValue coveragePath
        case jsonField "findings" coverage of
          Just (Aeson.Array entries) -> case toList entries of
            entry : _ -> jsonField "severity" entry `shouldBe` Just (Aeson.String "warning")
            [] -> expectationFailure "coverage report had no findings"
          other -> expectationFailure ("expected findings array, got " <> show other)

    it "writes the machine report when a workspace is refused during composition" $ do
      withTempDirectory "keiro-dsl-workspace-refusal-report" $ \out -> do
        let reportPath = out </> "made" </> "up" </> "refusal.json"
        (exitCode, stdoutText, _) <-
          runKeiroDsl
            [ "check",
              "test/fixtures/workspace-dup-decl/service.keiro-workspace",
              "--report-out",
              reportPath
            ]
        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldBe` ""
        report <- decodeJsonValue reportPath
        jsonField "schema" report `shouldBe` Just (Aeson.String "keiro-dsl/check-report/1")
        jsonField "kind" report `shouldBe` Just (Aeson.String "workspace")
        jsonField "ok" report `shouldBe` Just (Aeson.Bool False)
        -- No service graph was composed, so there is no language contract.
        jsonField "language" report `shouldBe` Just Aeson.Null
        case jsonField "diagnostics" report of
          Just (Aeson.Array entries) -> case toList entries of
            entry : _ -> do
              jsonField "code" entry `shouldBe` Just (Aeson.String "WorkspaceDuplicateDeclaration")
              jsonField "severity" entry `shouldBe` Just (Aeson.String "error")
            [] -> expectationFailure "workspace refusal report had no diagnostics"
          other -> expectationFailure ("expected diagnostics array, got " <> show other)

    it "applies the same warning policy to a composed workspace" $ do
      warningSource <- readTestText "test/fixtures/deny-unlogged.keiro"
      withInlineWorkspace
        "keiro-dsl-warning-policy"
        ("warning-policy", [("domain/jobs.keiro", warningSource)])
        $ \root _ _ -> do
          let manifest = root </> "service.keiro-workspace"
          (plainCode, plainOut, plainErr) <- runKeiroDsl ["check", manifest]
          plainCode `shouldBe` ExitSuccess
          plainOut `shouldBe` "OK\n"
          plainErr `shouldContain` "domain/jobs.keiro:4: warning[WqUnloggedDurability]"

          (deniedCode, deniedOut, deniedErr) <- runKeiroDsl ["check", manifest, "--deny", "WqUnloggedDurability"]
          deniedCode `shouldBe` ExitFailure 1
          deniedOut `shouldBe` ""
          deniedErr `shouldContain` "domain/jobs.keiro:4: warning[WqUnloggedDurability]"
          deniedErr `shouldContain` "check: 1 warning(s) escalated to failure (denied: WqUnloggedDurability)"

  describe "check report" $ do
    it "writes the source failure report and matches the public-CLI golden" $ do
      withTempDirectory "keiro-dsl-check-report-floor" $ \out -> do
        let reportPath = out </> "report.json"
        (exitCode, stdoutText, _) <-
          runKeiroDsl
            [ "check",
              "test/fixtures/language-legacy.keiro",
              "--min-language",
              "4",
              "--report-out",
              reportPath
            ]
        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldBe` ""
        report <- decodeJsonValue reportPath
        goldenPath <- resolveTestPath "test/fixtures/check-report/legacy-min-language.golden.json"
        golden <- decodeJsonValue goldenPath
        report `shouldBe` golden
        jsonField "schema" report `shouldBe` Just (Aeson.String "keiro-dsl/check-report/1")
        jsonField "kind" report `shouldBe` Just (Aeson.String "source")
        jsonField "ok" report `shouldBe` Just (Aeson.Bool False)
        (jsonField "language" report >>= jsonField "stable") `shouldBe` Just (Aeson.Bool False)
        (jsonField "summary" report >>= jsonField "errors") `shouldBe` Just (Aeson.Number 1)
        case jsonField "diagnostics" report of
          Just (Aeson.Array entries) -> case toList entries of
            entry : _ -> do
              jsonField "code" entry `shouldBe` Just (Aeson.String "LanguageVersionBelowMinimum")
              jsonField "severity" entry `shouldBe` Just (Aeson.String "error")
              jsonField "line" entry `shouldBe` Just (Aeson.Number 1)
            [] -> expectationFailure "check report had no diagnostics"
          other -> expectationFailure ("expected diagnostics array, got " <> show other)

    it "marks denied warnings without changing their severity" $ do
      withTempDirectory "keiro-dsl-check-report-deny" $ \out -> do
        let deniedPath = out </> "denied.json"
            allowedPath = out </> "allowed.json"
            fixture = "test/fixtures/deny-unlogged.keiro"
        (deniedCode, _, _) <- runKeiroDsl ["check", fixture, "--deny-warnings", "--report-out", deniedPath]
        deniedCode `shouldBe` ExitFailure 1
        deniedReport <- decodeJsonValue deniedPath
        jsonField "ok" deniedReport `shouldBe` Just (Aeson.Bool False)
        (jsonField "summary" deniedReport >>= jsonField "deniedWarnings") `shouldBe` Just (Aeson.Number 1)
        case jsonField "diagnostics" deniedReport of
          Just (Aeson.Array entries) -> case toList entries of
            entry : _ -> do
              jsonField "severity" entry `shouldBe` Just (Aeson.String "warning")
              jsonField "denied" entry `shouldBe` Just (Aeson.Bool True)
            [] -> expectationFailure "denied-warning report had no diagnostics"
          other -> expectationFailure ("expected diagnostics array, got " <> show other)

        (allowedCode, _, _) <- runKeiroDsl ["check", fixture, "--report-out", allowedPath]
        allowedCode `shouldBe` ExitSuccess
        allowedReport <- decodeJsonValue allowedPath
        jsonField "ok" allowedReport `shouldBe` Just (Aeson.Bool True)
        (jsonField "summary" allowedReport >>= jsonField "deniedWarnings") `shouldBe` Just (Aeson.Number 0)
        case jsonField "diagnostics" allowedReport of
          Just (Aeson.Array entries) -> case toList entries of
            entry : _ -> jsonField "denied" entry `shouldBe` Just (Aeson.Bool False)
            [] -> expectationFailure "allowed-warning report had no diagnostics"
          other -> expectationFailure ("expected diagnostics array, got " <> show other)

    it "reports canonical workspace members and writes nothing before parse success" $ do
      withTempDirectory "keiro-dsl-check-report-workspace" $ \out -> do
        let workspacePath = out </> "workspace.json"
            parseFailurePath = out </> "parse-failure.json"
            unregisteredPath = out </> "language-unregistered.keiro"
        (workspaceCode, _, _) <- runKeiroDsl ["check", canonicalWorkspacePath, "--report-out", workspacePath]
        workspaceCode `shouldBe` ExitSuccess
        workspaceReport <- decodeJsonValue workspacePath
        jsonField "kind" workspaceReport `shouldBe` Just (Aeson.String "workspace")
        jsonField "ok" workspaceReport `shouldBe` Just (Aeson.Bool True)
        (jsonField "language" workspaceReport >>= jsonField "sourceForm") `shouldBe` Just (Aeson.String "workspace-composed")
        case jsonField "members" workspaceReport of
          Just (Aeson.Array members) -> length members `shouldBe` 3
          other -> expectationFailure ("expected members array, got " <> show other)

        let v1Member = T.unlines ["language keiro-dsl 1", "context report-floor"]
        withInlineWorkspace
          "keiro-dsl-check-report-workspace-floor"
          ( "report-floor",
            [ ("domain/a.keiro", v1Member),
              ("domain/b.keiro", v1Member)
            ]
          )
          $ \root _ _ -> do
            let manifest = root </> "service.keiro-workspace"
                floorReportPath = out </> "workspace-floor.json"
            (floorCode, _, _) <-
              runKeiroDsl ["check", manifest, "--min-language", "4", "--report-out", floorReportPath]
            floorCode `shouldBe` ExitFailure 1
            floorReport <- decodeJsonValue floorReportPath
            case jsonField "diagnostics" floorReport of
              Just (Aeson.Array entries) -> case toList entries of
                entry : _ -> do
                  jsonField "file" entry `shouldBe` Just (Aeson.String (T.pack manifest))
                  jsonField "code" entry `shouldBe` Just (Aeson.String "LanguageVersionBelowMinimum")
                  case jsonField "related" entry of
                    Just (Aeson.Array related) -> length related `shouldBe` 2
                    other -> expectationFailure ("expected related-location array, got " <> show other)
                [] -> expectationFailure "workspace-floor report had no diagnostics"
              other -> expectationFailure ("expected diagnostics array, got " <> show other)

        TIO.writeFile unregisteredPath "language keiro-dsl 999999\nthis is intentionally not valid body syntax\n"
        (parseCode, _, _) <-
          runKeiroDsl
            [ "check",
              unregisteredPath,
              "--report-out",
              parseFailurePath
            ]
        parseCode `shouldBe` ExitFailure 1
        doesFileExist parseFailurePath `shouldReturn` False

  describe "runtime capability and fold identity baseline (plan 181)" $ do
    it "pins the fold-only FNV-1a-128 UTF-8 encoding" $ do
      foldFingerprint128 "" `shouldBe` "6c62272e07bb014262b821756295c58d"
      foldFingerprint128 "雪" `shouldBe` "a68afaae758b5822836dbc787bb233bd"

    it "pins complete fold surfaces and fingerprints across representative aggregates" $ do
      scalar <- checkedServiceOf "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      nominal <- checkedServiceOf "test/fixtures/nominal-scalars.keiro"
      idDomain <- checkedServiceOf "test/fixtures/id-domain-migration-v3.keiro"
      behavior <- checkedServiceOf "test/fixtures/behavior-complete.keiro"
      workspace <- shouldComposeWorkspace "test/fixtures/workspace-nominals/service.keiro-workspace"
      let actual =
            T.intercalate
              "\n\n"
              [ renderFoldBaseline "aggregate-scalar-expressions-v2" scalar,
                renderFoldBaseline "nominal-scalars" nominal,
                renderFoldBaseline "id-domain-migration-v3" idDomain,
                renderFoldBaseline "behavior-complete" behavior,
                renderFoldBaseline "workspace-nominals" (checkedWorkspace workspace)
              ]
      assertMatchesGolden "test/fixtures/fold-identity-baseline.golden" actual

    it "pins all four runtime gates and fingerprint segment projections" $ do
      nominalSpec <- specOf "test/fixtures/id-domain-migration-v3.keiro"
      nominalRegistry <- case resolveNominalTypes nominalSpec of
        Left errors -> expectationFailure (show errors) >> fail "unreachable"
        Right value -> pure value
      nominal <- case lookupNominalType "OrderId" nominalRegistry of
        Nothing -> expectationFailure "missing OrderId nominal" >> fail "unreachable"
        Just value -> pure value
      strictSpec <-
        parseInlineSpec
          "<strict-profile>"
          ( T.unlines
              [ "context strict-profile",
                "aggregate DuplicateRegister",
                "  regs",
                "    value Int = 0",
                "    value Int = 0",
                "  states Open"
              ]
          )
      rows <- forM [1 .. 4 :: Int] $ \number -> do
        contract <- case languageVersion (fromIntegral number) >>= effectiveLanguageContractForVersion of
          Nothing -> expectationFailure ("missing released language contract " <> show number) >> fail "unreachable"
          Just value -> pure value
        let hasAggregateIdDomain = maybe False (const True) (idDomainContractFor contract "ord")
            hasContractIdDomain = maybe False (const True) (contractIdDomainContractFor contract "ord")
            nominalContract = (.contractVersion) <$> nominalEqualityContractForService contract nominal
            strictService = checkedServiceForContract contract strictSpec
            hasStrictValidation = any ((== AggregateDuplicateRegister) . (.code)) (validateService strictService)
        pure
          ( number,
            effectiveRuntimeSemantics contract,
            runtimeSemanticsFingerprintSegments contract,
            hasAggregateIdDomain,
            hasContractIdDomain,
            nominalContract,
            hasStrictValidation
          )
      rows
        `shouldBe` [ (1, "keiro-dsl/runtime-semantics/1", [], False, False, Just "keiro-dsl/nominal-equality/1", False),
                     (2, "keiro-dsl/runtime-semantics/1", [], False, False, Just "keiro-dsl/nominal-equality/1", False),
                     (3, "keiro-dsl/runtime-semantics/2", ["semantic-contract:keiro-dsl/runtime-semantics/2"], True, False, Just "keiro-dsl/nominal-equality/2", False),
                     (4, "keiro-dsl/runtime-semantics/3", ["semantic-contract:keiro-dsl/runtime-semantics/2"], True, True, Just "keiro-dsl/nominal-equality/2", True)
                   ]

    it "explains a serialized runtime-profile mismatch" $ do
      case (Aeson.eitherDecode "{\"languageVersion\":4,\"runtimeSemantics\":\"keiro-dsl/runtime-semantics/2\"}" :: Either String EffectiveLanguageContract) of
        Left message -> do
          message `shouldContain` "runtimeSemantics does not match language version 4"
          message `shouldContain` "keiro-dsl/runtime-semantics/3"
          message `shouldContain` "keiro-dsl/runtime-semantics/2"
        Right _ -> expectationFailure "expected a runtime-profile mismatch"

    it "reports every formerly silent fold-resolution failure and propagates it" $ do
      baseService <- checkedServiceOf "test/fixtures/id-domain-migration-v3.keiro"
      recursiveMapped <- specOf "test/fixtures/mapped-recursive.keiro"
      brokenNominal <- specOf "test/fixtures/nominal-missing-facts.keiro"
      missingInitial <- specOf "test/fixtures/mapped-missing-initial.keiro"
      let contract = checkedLanguageContract baseService
          baseSpec = checkedSpec baseService
          baseAggregate = onlyAggregate baseSpec
          withAggregate transform =
            specWithNodes
              [ NAggregate (transform aggregate)
              | NAggregate aggregate <- baseSpec.nodes
              ]
              baseSpec
          replaceFirstTransition transform aggregate =
            aggregateWithTransitions
              (case aggregate.transitions of transition : rest -> transform transition : rest; [] -> [])
              aggregate
          guardSpec = withAggregate (replaceFirstTransition (transitionWithGuard (Just (EAtom (AName "missingGuardRoot")))))
          outputSpec = withAggregate (replaceFirstTransition (transitionWithEmits ["MissingEvent"]))
          typeGraphSpec = specWithMapped recursiveMapped.mapped baseSpec
          nominalSpec = specWithNominalScalars brokenNominal.nominalScalars baseSpec
          cases =
            [ (checkedServiceForContract contract typeGraphSpec, baseAggregate, \case FoldTypeGraphResolutionFailed {} -> True; _ -> False),
              (checkedServiceForContract contract nominalSpec, baseAggregate, \case FoldNominalResolutionFailed {} -> True; _ -> False),
              (checkedServiceForContract contract missingInitial, onlyAggregate missingInitial, \case FoldRegisterInitialResolutionFailed {} -> True; _ -> False),
              (checkedServiceForContract contract guardSpec, onlyAggregate guardSpec, \case FoldGuardResolutionFailed {} -> True; _ -> False),
              (checkedServiceForContract contract outputSpec, onlyAggregate outputSpec, \case FoldEventOutputResolutionFailed {} -> True; _ -> False)
            ]
      forM_ cases $ \(service, aggregate, matches) -> do
        CheckedFold.aggregateFoldSurfaceForService service aggregate
          `shouldSatisfy` either matches (const False)
        CheckedFold.aggregateFoldFingerprintForService service aggregate
          `shouldSatisfy` either matches (const False)
      let brokenService = checkedServiceForContract contract guardSpec
      CheckedDiff.diffServices brokenService baseService `shouldSatisfy` isLeft
      ReplayImpact.replayImpactServices brokenService baseService `shouldSatisfy` isLeft
      planTestServiceScaffold (defaultContext (guardSpec.context)) brokenService
        `shouldSatisfy` \case
          Left refusals -> any (\case FoldSurfaceRefusal {} -> True; _ -> False) refusals
          Right _ -> False

    it "pins representative diff and replay-impact rendering" $ do
      old <- parsedSourceOf "test/fixtures/reservation.keiro"
      new <- parsedSourceOf "test/fixtures/reservation-guard-tightened.keiro"
      let changes = diffSources old new
          impact = resolvedFold (ReplayImpact.replayImpactServices (checkedSource old) (checkedSource new))
          actual =
            T.intercalate
              "\n"
              ( "diff:"
                  : map renderFinding changes
                    <> ["replay:", ReplayImpact.renderReplayImpact impact]
              )
      assertMatchesGolden "test/fixtures/fold-identity-diff-replay.golden" actual

    it "pins unrelated public 64-bit identities outside the fold digest" $ do
      readModelSpec <- specOf "test/fixtures/readmodel.keiro"
      wireSpec <- specOf "test/fixtures/consumer-types.keiro"
      behaviorSpec <- specOf "test/fixtures/behavior-complete.keiro"
      readModel <- case [value | NReadModel value <- (.nodes) readModelSpec] of
        value : _ -> pure value
        [] -> expectationFailure "missing read-model fixture" >> fail "unreachable"
      graph <- shouldResolveTypeGraph wireSpec
      behaviorKey <- case Behavior.deriveBehaviorRequirements behaviorSpec of
        Right (requirement : _) -> pure (Behavior.unBehaviorKey ((.key) requirement))
        result -> expectationFailure ("missing behavior requirement: " <> show result) >> fail "unreachable"
      deriveShapeHash readModel `shouldBe` "fnv1a:3717f6d9e3c44bd6"
      wireFingerprint graph "ArtifactInfo" `shouldBe` "2bd99b3e57bcde9b"
      behaviorKey `shouldBe` "behavior-v1-0128e858fee6f2b3"

  describe "source language version" $ do
    let legacy = "context hospital-capacity\n"
        declared = "# leading comment\n\nlanguage keiro-dsl 1\ncontext hospital-capacity\n"
        code source = case parseSource "source.keiro" source of
          Left (SourceLanguageFailure diagnostic) -> Just ((.errorCode) diagnostic)
          _ -> Nothing
        parseRight name source = case parseSource name source of
          Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
          Right value -> pure value
        declaredVersionOf DeclaredLanguage {declaredLanguageVersion = version} = Just version
        declaredVersionOf LegacyUnversioned = Nothing
        orderedSubstrings needles haystack = go (map T.pack needles) (T.pack haystack)
          where
            go [] _ = True
            go (needle : rest) remaining =
              let (_, suffix) = T.breakOn needle remaining
               in not (T.null suffix) && go rest (T.drop (T.length needle) suffix)

    it "selects declared v1 after comments while preserving semantic equality" $ do
      legacySource <- parseRight "legacy.keiro" legacy
      declaredSource <- parseRight "declared.keiro" declared
      (.spec) legacySource `shouldBe` (.spec) declaredSource
      (.sourceLanguage) legacySource `shouldBe` LegacyUnversioned
      declaredVersionOf ((.sourceLanguage) declaredSource) `shouldBe` languageVersion 1
      effectiveLanguageVersion ((.sourceLanguage) legacySource)
        `shouldBe` effectiveLanguageVersion ((.sourceLanguage) declaredSource)

    it "threads paired released versions through one checked semantic boundary" $ do
      let body = T.unlines ["context semantic-pair", "aggregate Counter", "  regs", "  states Open"]
          v1Text = "language keiro-dsl 1\n" <> body
          v2Text = "language keiro-dsl 2\n" <> body
      v1Source <- parseRight "reservation-v1.keiro" v1Text
      v2Source <- parseRight "reservation-v2.keiro" v2Text
      let v1Service = checkedSource v1Source
          v2Service = checkedSource v2Source
          v1Spec = checkedSpec v1Service
          v2Spec = checkedSpec v2Service
          ctx = defaultContext (v1Spec.context)
          aggregates spec = [aggregate | NAggregate aggregate <- (.nodes) spec]
      v1Spec `shouldBe` v2Spec
      Just ((.contractLanguageVersion) (checkedLanguageContract v1Service)) `shouldBe` languageVersion 1
      Just ((.contractLanguageVersion) (checkedLanguageContract v2Service)) `shouldBe` languageVersion 2
      effectiveRuntimeSemantics (checkedLanguageContract v1Service)
        `shouldBe` effectiveRuntimeSemantics (checkedLanguageContract v2Service)
      validateService v1Service `shouldBe` validateService v2Service
      scaffoldServiceModules ctx v1Service `shouldBe` scaffoldServiceModules ctx v2Service
      case (aggregates v1Spec, aggregates v2Spec) of
        ([v1Aggregate], [v2Aggregate]) -> do
          aggregateFoldSurfaceForService v1Service v1Aggregate
            `shouldBe` aggregateFoldSurfaceForService v2Service v2Aggregate
          aggregateFoldFingerprintForService v1Service v1Aggregate
            `shouldBe` aggregateFoldFingerprintForService v2Service v2Aggregate
        other -> expectationFailure ("expected one aggregate per paired source, got " <> show (fmap length other))
      diffServices v1Service v2Service `shouldBe` []
      resolvedFold (ReplayImpact.replayImpactServices v1Service v2Service) `shouldBe` ReplayNeutral

    it "retains one effective contract for same-version workspaces and refuses mixed versions" $ do
      let manifest = "service semantic-workspace\nspec domain/a.keiro\nspec domain/b.keiro\n"
          v1Body = "language keiro-dsl 1\ncontext semantic-workspace\n"
          v2Body = "language keiro-dsl 2\ncontext semantic-workspace\n"
          sourceWith b =
            memoryContentSource
              ( Map.fromList
                  [ ("service.keiro-workspace", manifest),
                    ("domain/a.keiro", b),
                    ("domain/b.keiro", b)
                  ]
              )
          mixedSource =
            memoryContentSource
              ( Map.fromList
                  [ ("service.keiro-workspace", manifest),
                    ("domain/a.keiro", v1Body),
                    ("domain/b.keiro", v2Body)
                  ]
              )
      sameVersion <- loadWorkspace (sourceWith v2Body) "service.keiro-workspace"
      case sameVersion of
        Right workspace -> do
          Just ((.contractLanguageVersion) (checkedLanguageContract (checkedWorkspace workspace))) `shouldBe` languageVersion 2
          validateService (checkedWorkspace workspace) `shouldBe` []
        Left failure -> expectationFailure (show failure)
      mixed <- loadWorkspace mixedSource "service.keiro-workspace"
      case mixed of
        Left (WorkspaceRefused diagnostics) ->
          map (.code) (NE.toList diagnostics) `shouldContain` [WorkspaceLanguageVersionMismatch]
        other -> expectationFailure ("expected a mixed-version refusal, got " <> show other)

    it "refuses a source/service contract mismatch before creating the output directory" $ do
      v1Version <- maybe (expectationFailure "version 1 missing" >> fail "unreachable") pure (languageVersion 1)
      parsed <- parseRight "semantic-v2.keiro" "language keiro-dsl 2\ncontext semantic-refusal\n"
      let service = checkedSource parsed
          ctx = defaultContext "semantic-refusal"
      modules <- case planTestServiceScaffold ctx service of
        Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
        Right planned -> pure planned
      withTempDirectory "keiro-dsl-semantic-refusal" $ \root -> do
        let out = root </> "not-created"
        result <- executeServiceScaffold out False "semantic-v2.keiro" (DeclaredLanguage v1Version noLoc) ctx service modules
        result `shouldBe` Left [SemanticContractMismatch "source provenance and checked service selected different effective language contracts"]
        doesDirectoryExist out `shouldReturn` False

    it "retains explicit declarations in source rendering and leaves legacy unversioned" $ do
      legacySource <- parseRight "legacy.keiro" legacy
      declaredSource <- parseRight "declared.keiro" declared
      renderSource legacySource `shouldBe` "context hospital-capacity\n"
      renderSource declaredSource `shouldBe` "language keiro-dsl 1\ncontext hospital-capacity\n"
      parseSpec "declared.keiro" declared `shouldBe` Right ((.spec) declaredSource)

    it "classifies invalid, unsupported, duplicate, and misplaced preambles" $ do
      code "language keiro-dsl 0\ncontext hospital-capacity\n" `shouldBe` Just InvalidLanguageVersion
      code "language keiro-dsl nope\ncontext hospital-capacity\n" `shouldBe` Just InvalidLanguageVersion
      code "language keiro-dsl -1\ncontext hospital-capacity\n" `shouldBe` Just InvalidLanguageVersion
      code "language keiro-dsl 999999\ncontext hospital-capacity\n" `shouldBe` Just UnsupportedLanguageVersion
      code "language keiro-dsl 1\nlanguage keiro-dsl 1\ncontext hospital-capacity\n" `shouldBe` Just DuplicateLanguagePreamble
      code "context hospital-capacity\nlanguage keiro-dsl 1\n" `shouldBe` Just MisplacedLanguagePreamble

    it "treats language and successor spellings as data in nested grammar positions" $ do
      forM_ ["language-identifier-v1.keiro", "language-identifier-v2.keiro"] $ \fixture -> do
        source <- readTestText ("test/fixtures/" <> fixture)
        parsed <- parseRight fixture source
        validateSpec ((.spec) parsed) `shouldBe` []
      v1 <- readTestText "test/fixtures/language-identifier-v1.keiro"
      let manifest = "service language-collisions\nspec domain/collisions.keiro\n"
          workspaceSource = memoryContentSource (Map.fromList [("service.keiro-workspace", manifest), ("domain/collisions.keiro", v1)])
      loaded <- loadWorkspace workspaceSource "service.keiro-workspace"
      loaded `shouldSatisfy` isRight

    it "keeps duplicate and misplaced preamble diagnostics on their grammar lines" $ do
      let sourceFailureAt expectedCode expectedLine source =
            case parseSource "located.keiro" source of
              Left (SourceLanguageFailure diagnostic) -> do
                (.errorCode) diagnostic `shouldBe` expectedCode
                unLoc ((.loc) diagnostic) `shouldBe` expectedLine
              other -> expectationFailure ("expected located source-language failure, got " <> show other)
      sourceFailureAt DuplicateLanguagePreamble 2 "language keiro-dsl 1\nlanguage keiro-dsl 1\ncontext located\n"
      sourceFailureAt MisplacedLanguagePreamble 3 "context located\nid language prefix=lang\nlanguage keiro-dsl 1\n"

    it "rejects a future version before parsing an invalid v1 body" $
      case parseSource "unregistered.keiro" "language keiro-dsl 999999\nthis is not a v2 body\n" of
        Left failure@(SourceLanguageFailure diagnostic) -> do
          (.errorCode) diagnostic `shouldBe` UnsupportedLanguageVersion
          renderParseFailure failure `shouldSatisfy` T.isInfixOf "supported versions: 1, 2, 3, 4, 5"
          renderParseFailure failure `shouldNotSatisfy` T.isInfixOf "expecting `context`"
        other -> expectationFailure ("expected source-language failure, got " <> show other)

    it "accepts and canonically round-trips nominal declarations only in v2" $ do
      let nominalSource =
            T.unlines
              [ "language keiro-dsl 2",
                "context orders",
                "id OrderId prefix=ord using {",
                "  haskell package=orders-domain module=Orders.Id type=OrderId",
                "  binding = \"Orders.KeiroBindings.orderIdBinding\"",
                "  binding-version = \"1\"",
                "  canonical-type = \"orders.OrderId.v1\"",
                "  fixtures = \"Orders.KeiroBindings.orderIdFixtures\"",
                "}",
                "enum OrderStatus { Draft=draft Submitted=submitted } using {",
                "  haskell package=orders-domain module=Orders.Order type=OrderStatus",
                "  binding = \"Orders.KeiroBindings.orderStatusBinding\"",
                "  binding-version = \"1\"",
                "  canonical-type = \"orders.OrderStatus.v1\"",
                "  fixtures = \"Orders.KeiroBindings.orderStatusFixtures\"",
                "}",
                "mapped nominal AccountNumber : Text {",
                "  haskell package=orders-domain module=Orders.Account type=AccountNumber",
                "  binding = \"Orders.KeiroBindings.accountNumberBinding\"",
                "  binding-version = \"1\"",
                "  canonical-type = \"orders.AccountNumber.v1\"",
                "  fixtures = \"Orders.KeiroBindings.accountNumberFixtures\"",
                "  initial = \"Orders.KeiroBindings.initialAccountNumber\"",
                "}"
              ]
      parsed <- parseRight "nominal.keiro" nominalSource
      length ((.ids) ((.spec) parsed)) `shouldBe` 1
      length ((.enums) ((.spec) parsed)) `shouldBe` 1
      length ((.nominalScalars) ((.spec) parsed)) `shouldBe` 1
      parseSource "nominal-round-trip.keiro" (renderSource parsed) `shouldBe` Right parsed

    it "reports successor nominal syntax as one language-version diagnostic under v1 and legacy" $ do
      let body = "context orders\nmapped nominal AccountNumber : Text {}\n"
      code ("language keiro-dsl 1\n" <> body) `shouldBe` Just LanguageFeatureRequiresVersion
      code body `shouldBe` Just LanguageFeatureRequiresVersion

    it "parses and canonically round-trips field aliases only in language 4" $ do
      let v4Source =
            T.unlines
              [ "language keiro-dsl 4",
                "context aliases",
                "aggregate Order",
                "  regs",
                "  states Open",
                "  command Change { type haskell payloadType as \"type\":Text haskell as }",
                "contract publicOrder {",
                "  schemaVersion 1",
                "  discriminator kind",
                "  topic changes \"orders.v1\"",
                "  event Changed on changes {",
                "    region haskell serviceRegion as \"region_code\": text",
                "  }",
                "}"
              ]
          v3Source = T.replace "language keiro-dsl 4" "language keiro-dsl 3" v4Source
      parsed <- parseRight "field-aliases.keiro" v4Source
      parseSource "field-aliases-round-trip.keiro" (renderSource parsed) `shouldBe` Right parsed
      case (.nodes) ((.spec) parsed) of
        [NAggregate aggregate, NContract contract] -> do
          case (.fields) =<< (.commands) aggregate of
            aliased : haskellField : asField : _ -> do
              ((.name) aliased, (.selector) aliased, (.wireKey) aliased)
                `shouldBe` ("type", Just "payloadType", Just "type")
              map (.name) [haskellField, asField] `shouldBe` ["haskell", "as"]
            fields -> expectationFailure ("unexpected aggregate alias fields: " <> show fields)
          case (.fields) =<< (.events) contract of
            [field] ->
              ((.name) field, (.selector) field, (.wireKey) field, (.loc) field)
                `shouldBe` ("region", Just "serviceRegion", Just "region_code", Loc 12)
            fields -> expectationFailure ("unexpected contract alias fields: " <> show fields)
        nodes -> expectationFailure ("unexpected alias nodes: " <> show nodes)
      code v3Source `shouldBe` Just LanguageFeatureRequiresVersion

    it "attributes every successor feature gate to its owning grammar production" $ do
      let featureFailureAt expectedLine source =
            case parseSource "feature.keiro" source of
              Left (SourceLanguageFailure diagnostic) -> do
                (.errorCode) diagnostic `shouldBe` LanguageFeatureRequiresVersion
                unLoc ((.loc) diagnostic) `shouldBe` expectedLine
              other -> expectationFailure ("expected a located feature gate, got " <> show other)
          aggregateWith clause =
            T.unlines
              [ "language keiro-dsl 1",
                "context feature-gates",
                "aggregate Account",
                "  regs",
                "    balance Text = \"0\"",
                "  states Open",
                "  command Adjust { amount:Text }",
                "  event Adjusted = fields(Adjust)",
                "  Open -- Adjust --> " <> clause <> " ; emit Adjusted ; goto Open"
              ]
      featureFailureAt 3 (T.unlines ["language keiro-dsl 1", "context feature-gates", "id AccountId prefix=acct using {"])
      featureFailureAt 3 (T.unlines ["language keiro-dsl 1", "context feature-gates", "mapped nominal AccountNumber : Text {}"])
      featureFailureAt 5 (T.unlines ["language keiro-dsl 1", "context feature-gates", "aggregate Account", "  regs", "    balance Integer = 0", "  states Open"])
      featureFailureAt 9 (aggregateWith "guard reg.balance == cmd.amount")
      featureFailureAt 9 (aggregateWith "implementation hole")

    it "reports a declaration-only rewrite without semantic, generated, fold, or replay impact" $ do
      fixture <- readTestText "test/fixtures/language-v1.keiro"
      let legacyFixture = T.unlines (drop 1 (T.lines fixture))
      legacySource <- parseRight "legacy.keiro" legacyFixture
      declaredSource <- parseRight "declared.keiro" fixture
      let oldSpec = (.spec) legacySource
          newSpec = (.spec) declaredSource
          changes = diffSources legacySource declaredSource
          vectors = [kind.vector | change <- changes, let kind = workspaceChangeKind change]
      map changeCode changes `shouldBe` [SourceLanguageDeclarationChanged]
      legacyDiffSpecs oldSpec newSpec `shouldBe` []
      vectors `shouldSatisfy` all (\compatibility -> all ((== VCompatible) . (`verdictFor` compatibility)) [minBound .. maxBound])
      case changes of
        [change] ->
          remediationFor ((workspaceChangeKind change).context) SourceLanguageDeclarationChanged
            `shouldBe` (RemedyNoSemanticAction :| [])
        _ -> expectationFailure "expected one source-language change"
      let legacyGeneratedSurface spec =
            [ ((.path) scaffoldModule, (.text) scaffoldModule, (.kind) scaffoldModule)
            | scaffoldModule <- scaffoldModules (defaultContext (spec.context)) spec
            ]
          legacyFoldFingerprint spec aggregate = aggregateFoldFingerprintForService (legacyCheckedService spec) aggregate
      legacyGeneratedSurface oldSpec `shouldBe` legacyGeneratedSurface newSpec
      [legacyFoldFingerprint oldSpec aggregate | NAggregate aggregate <- (.nodes) oldSpec]
        `shouldBe` [legacyFoldFingerprint newSpec aggregate | NAggregate aggregate <- (.nodes) newSpec]
      legacyReplayImpactSpecs oldSpec newSpec `shouldBe` ReplayNeutral

    it "exposes published support in source and workspace JSON inspection" $ do
      (sourceCode, sourceOut, sourceErr) <- runKeiroDsl ["inspect", "test/fixtures/reservation.keiro", "--format=json"]
      sourceCode `shouldBe` ExitSuccess
      sourceErr `shouldBe` ""
      sourceOut `shouldContain` "\"schema\":\"keiro-dsl/source-inspection/1\""
      sourceOut `shouldContain` "\"kind\":\"source\""
      sourceOut `shouldContain` "\"sourceForm\":\"declared\""
      sourceOut `shouldContain` "\"declaredLanguageVersion\":4"
      sourceOut `shouldContain` "\"effectiveLanguageVersion\":4"
      sourceOut `shouldContain` "\"effectiveSemanticContract\":{"
      sourceOut `shouldContain` "\"runtimeSemantics\":\"keiro-dsl/runtime-semantics/3\""
      sourceOut `shouldContain` "\"languageSupport\":\"compatibility-only\""
      (workspaceCode, workspaceOut, workspaceErr) <- runKeiroDsl ["inspect", canonicalWorkspacePath, "--format=json"]
      workspaceCode `shouldBe` ExitSuccess
      workspaceErr `shouldBe` ""
      workspaceOut `shouldContain` "\"kind\":\"workspace\""
      workspaceOut `shouldContain` "\"service\":\"demo-project\""
      workspaceOut `shouldContain` "\"effectiveSemanticContract\":{"
      workspaceOut `shouldContain` "\"languageSupport\":\"compatibility-only\""
      workspaceOut `shouldSatisfy` orderedSubstrings ["domain/project-artifact.keiro", "domain/project.keiro", "domain/shared.keiro"]
      (stableCode, stableOut, stableErr) <- runKeiroDsl ["inspect", "test/fixtures/workflow-evolution.keiro", "--format=json"]
      stableCode `shouldBe` ExitSuccess
      stableErr `shouldBe` ""
      stableOut `shouldContain` "\"declaredLanguageVersion\":5"
      stableOut `shouldContain` "\"effectiveLanguageVersion\":5"
      stableOut `shouldContain` "\"languageSupport\":\"stable\""

    it "keeps only the named source-version fixtures outside published Language 4" $ do
      fixtureTree <- treeSnapshot "test/fixtures"
      let outsideStableV4 =
            sort
              [ path
              | (path, contents) <- fixtureTree,
                takeExtension path == ".keiro",
                "language keiro-dsl 4" `notElem` T.lines contents
              ]
      outsideStableV4
        `shouldBe` sort
          [ "aggregate-collection-expressions-v2-rejects.keiro",
            "aggregate-scalar-expressions-v1-rejects.keiro",
            "catalog-readmodel-backing-required.keiro",
            "catalog-readmodel-backing-unobserved.keiro",
            "catalog-readmodel-physical-override.keiro",
            "catalog-readmodel-reorder-a.keiro",
            "catalog-readmodel-reorder-b.keiro",
            "contract-v1-compat.keiro",
            "declarative-router/unbounded.keiro",
            "declarative-router/valid.keiro",
            "domain-command-outcomes.keiro",
            "id-domain-migration-v3.keiro",
            "language-duplicate.keiro",
            "language-identifier-v1.keiro",
            "language-identifier-v2.keiro",
            "language-legacy.keiro",
            "language-malformed.keiro",
            "language-misplaced.keiro",
            "language-v1.keiro",
            "language-zero.keiro",
            "mapped-readmodel-workspace/readmodel.keiro",
            "mapped-readmodel-workspace/types.keiro",
            "mapped-readmodel.keiro",
            "mapped-workqueue.keiro",
            "nominal-v1.keiro",
            "outcome-identifier-legacy.keiro",
            "outcome-identifier-v5.keiro",
            "projection-catalog-unrelated.keiro",
            "projection-catalog.keiro",
            "projection-owner-multi-query.keiro",
            "workflow-evolution.keiro"
          ]

    it "checks v1 and inspects legacy explicitly" $ do
      (v1Code, v1Out, v1Err) <- runKeiroDsl ["check", "test/fixtures/language-v1.keiro"]
      v1Code `shouldBe` ExitSuccess
      v1Out `shouldBe` "OK\n"
      v1Err `shouldContain` "language contract: effective keiro-dsl 1 (declared, compatibility-only, runtime semantics keiro-dsl/runtime-semantics/1)"
      (legacyCode, legacyOut, legacyErr) <- runKeiroDsl ["inspect", "test/fixtures/language-legacy.keiro", "--format=json"]
      legacyCode `shouldBe` ExitSuccess
      legacyErr `shouldBe` ""
      legacyOut `shouldContain` "\"sourceForm\":\"legacy-unversioned\""
      legacyOut `shouldContain` "\"declaredLanguageVersion\":null"
      legacyOut `shouldContain` "\"effectiveLanguageVersion\":1"
      legacyOut `shouldContain` "\"languageSupport\":\"compatibility-only\""

    it "checks and scaffolds contextual language identifiers through the CLI" $ do
      forM_ ["language-identifier-v1.keiro", "language-identifier-v2.keiro"] $ \fixture -> do
        let sourcePath = "test/fixtures/" <> fixture
        (checkCode, checkOut, checkErr) <- runKeiroDsl ["check", sourcePath]
        checkCode `shouldBe` ExitSuccess
        checkOut `shouldBe` "OK\n"
        checkErr `shouldContain` "language contract: effective keiro-dsl"
        withTempDirectory ("keiro-dsl-" <> fixture) $ \out -> do
          (scaffoldCode, _, scaffoldErr) <- runKeiroDsl ["scaffold", sourcePath, "--out", out]
          scaffoldCode `shouldBe` ExitSuccess
          scaffoldErr `shouldContain` "language contract: effective keiro-dsl"
          scaffoldErr `shouldContain` "firewall: OK"

    it "notices only the working-tree contract during diff" $ do
      (diffCode, _, diffErr) <- runKeiroDsl ["diff", "test/fixtures/language-v1.keiro", "--since", "HEAD"]
      diffCode `shouldBe` ExitSuccess
      T.count "language contract:" (T.pack diffErr) `shouldBe` 1
      diffErr `shouldContain` "language contract: effective keiro-dsl 1 (declared, compatibility-only, runtime semantics keiro-dsl/runtime-semantics/1)"

    it "preserves a workspace member's source-selection code beneath outer attribution" $ do
      let manifest = "service demo\nspec domain/future.keiro\n"
          futureSource = "language keiro-dsl 999999\nthis body must not parse\n"
          source = memoryContentSource (Map.fromList [("service.keiro-workspace", manifest), ("domain/future.keiro", futureSource)])
      loaded <- loadWorkspace source "service.keiro-workspace"
      case loaded of
        Left (WorkspaceRefused (diagnostic :| [])) -> do
          diagnostic.code `shouldBe` WorkspaceMemberParseFailed
          (.errorCode) <$> (.sourceLanguageCause) diagnostic
            `shouldBe` Just UnsupportedLanguageVersion
          renderWorkspaceDiagnostic "service.keiro-workspace" diagnostic
            `shouldSatisfy` T.isInfixOf "UnsupportedLanguageVersion"
        other -> expectationFailure ("expected one attributed source-language refusal, got " <> show other)

    it "attributes a workspace provenance-only diff to the changed member" $ do
      workspace <- shouldComposeWorkspace canonicalWorkspacePath
      case (.members) workspace of
        firstMember : remaining -> do
          let changedMember =
                WorkspaceMember
                  { path = firstMember.path,
                    spec = firstMember.spec,
                    sourceLanguage = LegacyUnversioned,
                    sourceIndex = firstMember.sourceIndex,
                    lineBase = firstMember.lineBase,
                    lineCount = firstMember.lineCount
                  }
              changedWorkspace = workspaceWithMembers (changedMember : remaining) workspace
              changes = diffWorkspaces workspace changedWorkspace
          map (changeCode . (.change)) changes `shouldBe` [SourceLanguageDeclarationChanged]
          map (fmap (.file) . (.declarationSite)) changes `shouldBe` [Just ((.path) firstMember)]
          map (.change) changes `shouldSatisfy` all (not . gatedBreaking (gateWith [minBound .. maxBound]))
        _ -> expectationFailure "canonical workspace had no member"

  describe "typed-domain-outcomes" $ do
    it "parses, validates, and canonically round-trips the complete language-5 fixture" $ do
      source <- readTestText "test/fixtures/domain-command-outcomes.keiro"
      parsed <- case parseSource "domain-command-outcomes.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      validateService (checkedSource parsed) `shouldBe` []
      parseSource "domain-command-outcomes-rendered.keiro" (renderSource parsed) `shouldBe` Right parsed
      let outcomeKind :: TransitionOutcome -> T.Text
          outcomeKind outcome = case outcome of
            OutcomeAccepted {} -> "accepted"
            OutcomeRejected {} -> "rejected"
            OutcomeNoOp {} -> "no-op"
      case [aggregate | NAggregate aggregate <- (.nodes) ((.spec) parsed)] of
        [aggregate] -> do
          fmap (\types -> ((.rejectionType) types, (.noOpType) types)) ((.domainOutcomeTypes) aggregate)
            `shouldBe` Just ("ReservationRejection", "ReservationNoOp")
          map (fmap outcomeKind . (.outcome)) ((.transitions) aggregate)
            `shouldBe` map Just ["accepted", "rejected", "no-op"]
        aggregates -> expectationFailure ("unexpected outcome aggregates: " <> show aggregates)

    it "gates the syntax to Language 5" $ do
      source <- readTestText "test/fixtures/domain-command-outcomes.keiro"
      case parseSource "domain-command-outcomes-v4.keiro" (T.replace "language keiro-dsl 5" "language keiro-dsl 4" source) of
        Left (SourceLanguageFailure diagnostic) -> (.errorCode) diagnostic `shouldBe` LanguageFeatureRequiresVersion
        other -> expectationFailure ("expected language feature refusal, got " <> show other)

    it "generates one direct exact-edge classifier arm per silent outcome" $ do
      source <- readTestText "test/fixtures/domain-command-outcomes.keiro"
      parsed <- case parseSource "domain-command-outcomes.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      aggregate <- case [value | NAggregate value <- (.nodes) ((.spec) parsed)] of
        [value] -> pure value
        values -> expectationFailure ("unexpected outcome aggregates: " <> show values) >> fail "unreachable"
      let scaffoldContext = defaultContext (parsed.spec.context)
          modules = scaffoldAggregateForService scaffoldContext (checkedSource parsed) aggregate
          modulesAgain = scaffoldAggregateForService scaffoldContext (checkedSource parsed) aggregate
          eventStream = case [(.text) value | value <- modules, "/EventStream.hs" `T.isSuffixOf` T.pack ((.path) value)] of
            [value] -> value
            values -> error ("unexpected outcome event-stream modules: " <> show values)
          behaviorContract = case [(.text) value | value <- modules, "/BehaviorContract.hs" `T.isSuffixOf` T.pack ((.path) value)] of
            [value] -> value
            values -> error ("unexpected outcome behavior-contract modules: " <> show values)
      map (.text) modulesAgain `shouldBe` map (.text) modules
      firewallBreaches modules `shouldBe` []
      eventStream `shouldSatisfy` T.isInfixOf "reservationDomainCommandHandler"
      eventStream `shouldSatisfy` T.isInfixOf "case edgeSource of"
      eventStream `shouldSatisfy` T.isInfixOf "case edgeIndex of"
      T.count " -> SilentRejected" eventStream `shouldBe` 1
      T.count " -> SilentNoOp" eventStream `shouldBe` 1
      T.count "K.evalTerm" eventStream `shouldBe` 2
      eventStream `shouldSatisfy` T.isInfixOf "0 -> SilentRejected"
      eventStream `shouldSatisfy` T.isInfixOf "1 -> SilentNoOp"
      forM_ ["Data.Map", "lookup", "find", "edgesOut", "Keiro.Command.Domain"] $ \forbidden ->
        eventStream `shouldSatisfy` (not . T.isInfixOf forbidden)
      behaviorContract `shouldSatisfy` T.isInfixOf "RejectedWith ReservationRejection"
      behaviorContract `shouldSatisfy` T.isInfixOf "NoOpWith ReservationNoOp"
      behaviorContract `shouldSatisfy` T.isInfixOf "runSilentDecision"
      behaviorContract `shouldSatisfy` T.isInfixOf "reservationDomainCommandHandler"

    it "reports complete, typed, and state-preserving outcome diagnostics" $ do
      source <- readTestText "test/fixtures/domain-command-outcomes.keiro"
      let codes changed = do
            case parseSource "domain-outcome-mutation.keiro" changed of
              Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> pure []
              Right parsed -> pure (map (.code) (validateService (checkedSource parsed)))
          expectCode expected changed = codes changed >>= (`shouldContain` [expected])
      expectCode
        DomainOutcomeDeclarationDuplicate
        (T.replace "  domain-outcomes rejection=ReservationRejection no-op=ReservationNoOp\n" "  domain-outcomes rejection=ReservationRejection no-op=ReservationNoOp\n  domain-outcomes rejection=ReservationRejection no-op=ReservationNoOp\n" source)
      expectCode
        DomainOutcomeDeclarationMissing
        (T.replace "  domain-outcomes rejection=ReservationRejection no-op=ReservationNoOp\n" "" source)
      expectCode
        DomainOutcomeClauseMissing
        (T.replace "    outcome accepted\n" "" source)
      expectCode
        DomainOutcomeClauseDuplicate
        (T.replace "    outcome accepted\n" "    outcome accepted\n    outcome accepted\n" source)
      expectCode
        DomainOutcomeTypeUnresolved
        (T.replace "rejection=ReservationRejection" "rejection=MissingRejection" source)
      expectCode
        DomainOutcomeReasonTypeMismatch
        (T.replace "ReservationRejection.AlreadyCancelled" "ReservationNoOp.DuplicateRequest" source)
      expectCode
        DomainOutcomeAcceptedWithoutEvents
        (T.replace "    emit Cancelled\n" "" source)
      expectCode
        DomainOutcomeSilentEmits
        (T.replace "    outcome rejected ReservationRejection.AlreadyCancelled\n" "    outcome rejected ReservationRejection.AlreadyCancelled\n    emit Cancelled\n" source)
      expectCode
        DomainOutcomeSilentWrites
        (T.replace "    outcome no-op ReservationNoOp.DuplicateRequest\n" "    outcome no-op ReservationNoOp.DuplicateRequest\n    write lastRequestId := cmd.requestId\n" source)
      expectCode
        DomainOutcomeSilentStateChange
        (T.replace "    outcome no-op ReservationNoOp.DuplicateRequest\n    goto CancelledState\n" "    outcome no-op ReservationNoOp.DuplicateRequest\n    goto Eligible\n" source)
      expectCode
        DomainOutcomeReplayOnlyClause
        (T.replace "  CancelledState -- Cancel -->\n    guard cmd.requestId != reg.lastRequestId" "  replay-only CancelledState -- Cancel -->\n    guard cmd.requestId != reg.lastRequestId" source)

    it "changes behavior identity and semantic diff without moving fold or replay identity" $ do
      source <- readTestText "test/fixtures/domain-command-outcomes.keiro"
      let changedSource = T.replace "ReservationRejection.AlreadyCancelled" "ReservationRejection.CapacityUnavailable" source
      oldParsed <- case parseSource "domain-outcomes-old.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      newParsed <- case parseSource "domain-outcomes-new.keiro" changedSource of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      validateService (checkedSource newParsed) `shouldBe` []
      oldAggregate <- case [aggregate | NAggregate aggregate <- (.nodes) ((.spec) oldParsed)] of
        [aggregate] -> pure aggregate
        aggregates -> expectationFailure ("unexpected old outcome aggregates: " <> show aggregates) >> fail "unreachable"
      newAggregate <- case [aggregate | NAggregate aggregate <- (.nodes) ((.spec) newParsed)] of
        [aggregate] -> pure aggregate
        aggregates -> expectationFailure ("unexpected new outcome aggregates: " <> show aggregates) >> fail "unreachable"
      let changes = diffSources oldParsed newParsed
          oldBehavior = Behavior.deriveAggregateBehaviorRequirements ((.spec) oldParsed) oldAggregate
          newBehavior = Behavior.deriveAggregateBehaviorRequirements ((.spec) newParsed) newAggregate
          changeKind change = case change of
            Additive value -> value
            Advisory value -> value
            Breaking value -> value
      map ((.code) . changeKind) changes `shouldContain` [DomainTransitionOutcomeChanged]
      map ((.code) . changeKind) changes `shouldNotContain` [AggFoldSurfaceChanged]
      aggregateFoldFingerprintForService (checkedSource oldParsed) oldAggregate
        `shouldBe` aggregateFoldFingerprintForService (checkedSource newParsed) newAggregate
      oldBehavior `shouldNotBe` newBehavior
      ReplayImpact.replayImpactServices (checkedSource oldParsed) (checkedSource newParsed)
        `shouldBe` Right ReplayImpact.ReplayNeutral

  describe "outcome identifier compatibility" $ do
    it "parses outcome as an ordinary identifier under legacy and declared language 1" $ do
      source <- readTestText "test/fixtures/outcome-identifier-legacy.keiro"
      case parseSource "outcome-identifier-legacy.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right _ -> pure ()
      case parseSource "outcome-identifier-v1.keiro" ("language keiro-dsl 1\n" <> source) of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right _ -> pure ()

    it "parses outcome as an ordinary identifier under languages 2, 3, and 4" $ do
      source <- readTestText "test/fixtures/outcome-identifier.keiro"
      forM_ ["2", "3", "4"] $ \version ->
        case parseSource
          ("outcome-identifier-v" <> T.unpack version <> ".keiro")
          (T.replace "language keiro-dsl 4" ("language keiro-dsl " <> version) source) of
          Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
          Right parsed
            | version == "4" -> validateService (checkedSource parsed) `shouldBe` []
            | otherwise -> pure ()

    it "parses outcome as an enum constructor, state, and transition source" $ do
      source <- readTestText "test/fixtures/outcome-identifier-positions.keiro"
      case parseSource "outcome-identifier-positions.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right parsed -> validateService (checkedSource parsed) `shouldBe` []

    it "round-trips outcome identifiers through the canonical renderer" $ do
      source <- readTestText "test/fixtures/outcome-identifier.keiro"
      parsed <- case parseSource "outcome-identifier.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      parseSource "outcome-identifier-rendered.keiro" (renderSource parsed) `shouldBe` Right parsed

    it "keeps outcome usable as an identifier alongside language-5 outcome clauses" $ do
      source <- readTestText "test/fixtures/outcome-identifier-v5.keiro"
      case parseSource "outcome-identifier-v5.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right parsed -> validateService (checkedSource parsed) `shouldBe` []

  describe "language-5 projection catalogs" $ do
    it "rejects explicit physical coordinates on a catalog-bound read model" $ do
      errorCodesOf "test/fixtures/catalog-readmodel-physical-override.keiro"
        `shouldReturn` [CatalogReadModelPhysicalOverride]

    it "requires an observed backing target for multi-target read models" $ do
      errorCodesOf "test/fixtures/catalog-readmodel-backing-required.keiro"
        `shouldReturn` [CatalogReadModelBackingRequired]
      errorCodesOf "test/fixtures/catalog-readmodel-backing-unobserved.keiro"
        `shouldReturn` [CatalogReadModelBackingUnobserved]

    it "binds catalog read models by name and ignores observed-target order" $ do
      sourceA <- readTestText "test/fixtures/catalog-readmodel-reorder-a.keiro"
      sourceB <- readTestText "test/fixtures/catalog-readmodel-reorder-b.keiro"
      parsedA <- case parseSource "catalog-readmodel-reorder-a.keiro" sourceA of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      case parseSource "catalog-readmodel-reorder-a-rendered.keiro" (renderSource parsedA) of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right rendered -> (.spec) rendered `shouldBe` (.spec) parsedA
      serviceA <- checkedServiceFromText "catalog-readmodel-reorder-a.keiro" sourceA
      serviceB <- checkedServiceFromText "catalog-readmodel-reorder-b.keiro" sourceB
      validateService serviceA `shouldBe` []
      validateService serviceB `shouldBe` []
      let ctx = defaultContext ((checkedSpec serviceA).context)
          modulesA = scaffoldServiceModules ctx serviceA
          modulesB = scaffoldServiceModules ctx serviceB
          generatedBytes modules = sort [((.path) moduleValue, (.text) moduleValue) | moduleValue <- modules]
          tableA = generatedTextEndingIn "Generated/BindingDemo/LedgerView/ReadModelTable.hs" modulesA
      generatedBytes modulesA `shouldBe` generatedBytes modulesB
      tableA `shouldSatisfy` T.isInfixOf "qualifyTable \"billing\" \"ledger_entries\""
      map ((.code) . kindOfChange) (diffServices serviceA serviceB)
        `shouldNotContain` [CatalogQueryBindingChanged]

    it "emits grouped harness facts against the generated projection catalog" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      service <- checkedServiceFromText "projection-catalog.keiro" source
      let spec = checkedSpec service
          modules = scaffoldServiceModules (defaultContext (spec.context)) service
          auditHarness = generatedTextEndingIn "Generated/CatalogDemo/CatalogAudit/ReadModelHarness.hs" modules
          totalsHarness = generatedTextEndingIn "Generated/CatalogDemo/OrderTotalsLookup/ReadModelHarness.hs" modules
          shipmentHarness = generatedTextEndingIn "Generated/CatalogDemo/ShipmentLookup/ReadModelHarness.hs" modules
      auditHarness `shouldSatisfy` T.isInfixOf "import Generated.CatalogDemo.ProjectionCatalog qualified as ProjectionCatalog"
      auditHarness `shouldSatisfy` T.isInfixOf "ProjectionCatalog.projectionCatalogAsyncRegistrations"
      auditHarness `shouldSatisfy` T.isInfixOf "ProjectionCatalog.projectionCatalogQuerySupplies"
      auditHarness `shouldSatisfy` T.isInfixOf "catalog-demo-catalogAudit|1|fnv1a:9682af3ada04bf50|reporting"
      auditHarness `shouldSatisfy` T.isInfixOf "asyncRegistration:audit_writer"
      auditHarness `shouldSatisfy` T.isInfixOf "querySupply"
      auditHarness `shouldSatisfy` T.isInfixOf "projectionDelivery"
      auditHarness `shouldSatisfy` T.isInfixOf "(\"freshness\", \"Immediate\""
      auditHarness `shouldSatisfy` T.isInfixOf "(\"cursorAuthority\", \"DurableQueryCursor \\\"catalog-demo-audit\\\"\""
      auditHarness `shouldSatisfy` T.isInfixOf "catalog-demo-audit|catalog-demo-audit-v1"
      auditHarness `shouldNotSatisfy` T.isInfixOf "\"catalog-managed\", \"catalog-managed\""
      totalsHarness `shouldSatisfy` T.isInfixOf "order_summary_writer|reporting|order_totals"
      shipmentHarness `shouldSatisfy` T.isInfixOf "catalogRegistration"
      shipmentHarness `shouldNotSatisfy` T.isInfixOf "asyncRegistration:"

    it "parses, validates, and canonically round-trips the closed-world catalog graph" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      parsed <- case parseSource "projection-catalog.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      validateService (checkedSource parsed) `shouldBe` []
      case parseSource "projection-catalog-rendered.keiro" (renderSource parsed) of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right rendered -> (.spec) rendered `shouldBe` (.spec) parsed

      let spec = parsed.spec
          targets = [target | NProjectionTarget target <- (.nodes) spec]
          groups = [groupNode | NRebuildGroup groupNode <- (.nodes) spec]
          externalReads = [externalRead | NExternalRead externalRead <- (.nodes) spec]
          owners = [owner | NProjectionOwner owner <- (.nodes) spec]
      map (.name) targets `shouldBe` ["order_summary", "audit_log", "order_totals", "shipment_summary"]
      map (.name) groups `shouldBe` ["reporting", "shipping"]
      map (\externalRead -> ((.name) externalRead, (.version) externalRead, (.queryModel) externalRead)) externalReads
        `shouldBe` [("order_totals_reader", 1, "order_totals_lookup")]
      map (.name) owners `shouldBe` ["order_summary_writer", "shipment_writer", "audit_writer"]
      map (.checkpointOnMissing) owners `shouldBe` [[], [], [CheckpointFromCurrentHead]]

    it "validates and truthfully lowers every Language 5 delivery/freshness capability" $ do
      entireSource <- readTestText "test/fixtures/mapped-readmodel.keiro"
      categorySource <- readTestText "test/fixtures/declarative-router/valid.keiro"
      immediateSource <- readTestText "test/fixtures/projection-catalog.keiro"
      entireService <- checkedServiceFromText "projection-freshness-entire.keiro" entireSource
      categoryService <- checkedServiceFromText "projection-freshness-category.keiro" categorySource
      immediateService <- checkedServiceFromText "projection-freshness-immediate.keiro" immediateSource
      let errorsOf service = [diagnostic | diagnostic <- validateService service, (.severity) diagnostic == Error]
      errorsOf entireService `shouldBe` []
      errorsOf categoryService `shouldBe` []
      errorsOf immediateService `shouldBe` []
      let generatedReadModel suffix service =
            generatedTextEndingIn suffix (scaffoldServiceModules (defaultContext ((checkedSpec service).context)) service)
          entireReadModel = generatedReadModel "AccountSummary/ReadModel.hs" entireService
          categoryReadModel = generatedReadModel "HospitalLoad/ReadModel.hs" categoryService
          immediateReadModelText = generatedReadModel "CatalogAudit/ReadModel.hs" immediateService
          inlineReadModel = generatedReadModel "OrderInline/ReadModel.hs" immediateService
      entireReadModel `shouldSatisfy` T.isInfixOf "headWaitingReadModel EntireVisibleLog"
      entireReadModel `shouldSatisfy` T.isInfixOf "DurableQueryCursor \"mapped-readmodel-account-summary\""
      categoryReadModel `shouldSatisfy` T.isInfixOf "headWaitingReadModel (CategoryVisibleHead \"hospitalLoad\")"
      categoryReadModel `shouldSatisfy` T.isInfixOf "DurableQueryCursor \"declarative-router-hospital-load\""
      immediateReadModelText `shouldSatisfy` T.isInfixOf "immediateReadModel catalogAuditReadModelBlueprint"
      immediateReadModelText `shouldSatisfy` T.isInfixOf "DurableQueryCursor \"catalog-demo-audit\""
      inlineReadModel `shouldSatisfy` T.isInfixOf "immediateReadModel orderInlineReadModelBlueprint"
      inlineReadModel `shouldSatisfy` T.isInfixOf "cursorAuthority = NoQueryCursor"
      forM_ [entireReadModel, categoryReadModel, immediateReadModelText, inlineReadModel] $ \generated -> do
        generated `shouldNotSatisfy` T.isInfixOf "defaultConsistency"
        generated `shouldNotSatisfy` T.isInfixOf "strongScope"
        generated `shouldNotSatisfy` T.isInfixOf "subscriptionName ="

    it "rejects unavailable or unreachable head waits before generation" $ do
      catalogSource <- readTestText "test/fixtures/projection-catalog.keiro"
      categorySource <- readTestText "test/fixtures/declarative-router/valid.keiro"
      let codesFor name source = do
            service <- checkedServiceFromText name source
            pure [(.code) diagnostic | diagnostic <- validateService service, (.severity) diagnostic == Error]
          inlineWait =
            T.replace
              "shape = \"fnv1a:784e511a19f74c58\"\n  freshness = immediate\n  group = reporting\n  targets = [ order_summary ]"
              "shape = \"fnv1a:784e511a19f74c58\"\n  freshness = wait-for-head category \"orders\"\n  group = reporting\n  targets = [ order_summary ]"
              catalogSource
          mismatchedCategory =
            T.replace
              "freshness = wait-for-head category \"hospitalLoad\""
              "freshness = wait-for-head category \"other\""
              categorySource
          missingCursor = T.replace "  subscription = \"declarative-router-hospital-load\"\n" "" categorySource
      codesFor "projection-freshness-inline-wait.keiro" inlineWait
        `shouldReturn` [CatalogQueryWaitWithoutCompatibleCursor]
      codesFor "projection-freshness-mismatched-category.keiro" mismatchedCategory
        `shouldReturn` [CatalogQueryWaitWithoutCompatibleCursor]
      missingCursorCodes <- codesFor "projection-freshness-missing-cursor.keiro" missingCursor
      missingCursorCodes `shouldContain` [CatalogAsyncIdentityMissing]
      missingCursorCodes `shouldContain` [CatalogQueryWaitWithoutCompatibleCursor]

      mappedSource <- mappedConsumerSurfaceSource
      let implicitOwner =
            T.replace
              "  wire kind=ctorName fields=camelCase schemaVersion=1\n"
              "  wire kind=ctorName fields=camelCase schemaVersion=1\n\n  projection ArtifactLookup key=currentArtifact\n    status-map { ArtifactObserved=>observed }\n"
              ( T.replace
                  "freshness = immediate"
                  "freshness = wait-for-head category \"catalog\""
                  mappedSource
              )
      implicitCodes <- codesFor "projection-freshness-implicit-owner.keiro" implicitOwner
      implicitCodes `shouldContain` [CatalogQueryWaitWithoutCompatibleCursor]

    it "rejects the earlier Language 5 spellings with migration guidance" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      let failureText name candidate = case parseSource name candidate of
            Left failure -> pure (renderParseFailure failure)
            Right _ -> expectationFailure (name <> " unexpectedly parsed") >> fail "unreachable"
      readModelFailure <-
        failureText
          "projection-freshness-legacy-readmodel.keiro"
          ( T.replace
              "  freshness = immediate"
              "  consistency = Strong\n  scope = entire-log\n  feed = subscription\n  subscription = \"catalog-demo-audit\""
              source
          )
      readModelFailure `shouldSatisfy` T.isInfixOf "remove legacy `consistency`"
      ownerFailure <-
        failureText
          "projection-freshness-legacy-owner.keiro"
          (T.replace "  delivery = subscription" "  feed = subscription" source)
      ownerFailure `shouldSatisfy` T.isInfixOf "replace legacy `feed`"

      mappedSource <- mappedConsumerSurfaceSource
      aggregateFailure <-
        failureText
          "projection-freshness-legacy-inner.keiro"
          ( T.replace
              "  wire kind=ctorName fields=camelCase schemaVersion=1\n"
              "  wire kind=ctorName fields=camelCase schemaVersion=1\n\n  projection ArtifactLookup consistency=Eventual key=currentArtifact\n    status-map { ArtifactObserved=>observed }\n"
              mappedSource
          )
      aggregateFailure `shouldSatisfy` T.isInfixOf "put `freshness` on the referenced readmodel"

    it "isolates freshness evolution from delivery, table shape, sources, and aggregate folds" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      baseline <- checkedServiceFromText "projection-freshness-baseline.keiro" source
      changed <-
        checkedServiceFromText
          "projection-freshness-changed.keiro"
          ( T.replace
              "shape = \"fnv1a:9682af3ada04bf50\"\n  freshness = immediate\n  group = reporting\n  targets = [ audit_log ]"
              "shape = \"fnv1a:9682af3ada04bf50\"\n  freshness = wait-for-head category \"audit\"\n  group = reporting\n  targets = [ audit_log ]"
              source
          )
      validateService changed `shouldBe` []
      let changeCodes = map ((.code) . kindOfChange) (diffServices baseline changed)
          foldIdentities service =
            [ ((.name) aggregate, aggregateFoldFingerprintForService service aggregate)
            | NAggregate aggregate <- (.nodes) (checkedSpec service)
            ]
          sourceIdentities service =
            [ ((.name) aggregate, ProjectionImpact.projectionAggregateSourceFingerprintForService service ((.name) aggregate))
            | NAggregate aggregate <- (.nodes) (checkedSpec service)
            ]
          catalogAudit service = case [readModel | NReadModel readModel <- (.nodes) (checkedSpec service), (.name) readModel == "catalogAudit"] of
            [readModel] -> readModel
            values -> error ("expected one catalogAudit read model, got " <> show (length values))
          nonFreshnessFacts = filter (not . T.isPrefixOf "freshness|") . projectionCatalogFactsForService
          freshnessFacts = filter (T.isPrefixOf "freshness|") . projectionCatalogFactsForService
      changeCodes `shouldContain` [QueryFreshnessChanged]
      changeCodes `shouldNotContain` [ProjectionDeliveryChanged, ReadModelShapeChangedWithoutBump, CatalogSourceChanged]
      foldIdentities changed `shouldBe` foldIdentities baseline
      sourceIdentities changed `shouldBe` sourceIdentities baseline
      deriveShapeHash (catalogAudit changed) `shouldBe` deriveShapeHash (catalogAudit baseline)
      nonFreshnessFacts changed `shouldBe` nonFreshnessFacts baseline
      freshnessFacts changed `shouldNotBe` freshnessFacts baseline

    it "resolves one inline owner for several query models without legacy aggregate clauses" $ do
      source <- readTestText "test/fixtures/projection-owner-multi-query.keiro"
      service <- checkedServiceFromText "projection-owner-multi-query.keiro" source
      validateService service `shouldBe` []
      let analysis = analyzeProjectionSupplies (checkedSpec service)
          supplies = (.resolvedProjectionSupplies) analysis
      (.projectionSupplyIssues) analysis `shouldBe` []
      map (.queryModel) supplies
        `shouldBe` ["catalog_administration", "catalog_validation"]
      map (.projectionOwner) supplies
        `shouldBe` ["catalog_writer", "catalog_writer"]
      map (NE.toList . (.observedTargets)) supplies
        `shouldBe` [["catalog_keys"], ["catalog_layouts", "catalog_state"]]

      reordered <-
        checkedServiceFromText
          "projection-owner-multi-query-reordered.keiro"
          ( T.replace
              "targets = [ catalog_state catalog_layouts ]"
              "targets = [ catalog_layouts catalog_state ]"
              ( T.replace
                  "targets = [ catalog_state catalog_layouts catalog_keys ]\n  order = 10"
                  "targets = [ catalog_keys catalog_layouts catalog_state ]\n  order = 10"
                  source
              )
          )
      validateService reordered `shouldBe` []
      (.resolvedProjectionSupplies) (analyzeProjectionSupplies (checkedSpec reordered))
        `shouldBe` supplies

    it "diagnoses invalid query supply and catalog/legacy double ownership deterministically" $ do
      source <- readTestText "test/fixtures/projection-owner-multi-query.keiro"
      let diagnosticsForSource caseName mutated = do
            service <- checkedServiceFromText caseName mutated
            pure (validateService service)
          codesForSource caseName mutated = map (.code) <$> diagnosticsForSource caseName mutated
          splitOwnerMutation =
            T.replace
              "targets = [ catalog_state catalog_layouts ]\n  backing = catalog_state"
              "targets = [ catalog_state catalog_layouts catalog_keys ]\n  backing = catalog_state"
              . T.replace
                "  replay = explicit\n}\n\nreadmodel catalog_validation"
                "  replay = explicit\n}\n\nprojection-owner catalog_keys_writer {\n  source = aggregate Catalog\n  delivery = inline\n  group = catalog_group\n  targets = [ catalog_keys ]\n  order = 20\n  replay = explicit\n}\n\nreadmodel catalog_validation"
              . T.replace
                "targets = [ catalog_state catalog_layouts catalog_keys ]\n  order = 10"
                "targets = [ catalog_state catalog_layouts ]\n  order = 10"
      emptyCodes <- codesForSource "projection-owner-empty-query.keiro" (T.replace "targets = [ catalog_keys ]" "targets = [ ]" source)
      emptyCodes `shouldContain` [CatalogReadModelBindingMissing]
      unknownCodes <- codesForSource "projection-owner-unknown-query-target.keiro" (T.replace "targets = [ catalog_keys ]" "targets = [ missing_target ]" source)
      unknownCodes `shouldContain` [CatalogTargetUnknown]
      missingCodes <- codesForSource "projection-owner-missing-query-owner.keiro" (T.replace "targets = [ catalog_state catalog_layouts catalog_keys ]\n  order = 10" "targets = [ catalog_state catalog_layouts ]\n  order = 10" source)
      missingCodes `shouldContain` [CatalogTargetUnowned]

      splitDiagnostics <- diagnosticsForSource "projection-owner-split-query.keiro" (splitOwnerMutation source)
      map (.code) splitDiagnostics `shouldContain` [CatalogReadModelMultipleSuppliers]
      let splitSupplyDiagnostics = filter ((== CatalogReadModelMultipleSuppliers) . (.code)) splitDiagnostics
      map (map snd . (.relatedLocations)) splitSupplyDiagnostics
        `shouldBe` [ [ "projection owner 'catalog_keys_writer' supplies part of the observed target set",
                       "projection owner 'catalog_writer' supplies part of the observed target set"
                     ]
                   ]
      reorderedSplitDiagnostics <-
        diagnosticsForSource
          "projection-owner-split-query-reordered.keiro"
          ( T.replace
              "targets = [ catalog_state catalog_layouts catalog_keys ]"
              "targets = [ catalog_keys catalog_layouts catalog_state ]"
              (splitOwnerMutation source)
          )
      map (\diagnostic -> ((.code) diagnostic, map snd ((.relatedLocations) diagnostic))) reorderedSplitDiagnostics
        `shouldContain` map (\diagnostic -> ((.code) diagnostic, map snd ((.relatedLocations) diagnostic))) splitSupplyDiagnostics

      groupMismatchCodes <-
        codesForSource
          "projection-owner-group-mismatch.keiro"
          ( T.replace
              "targets = [ catalog_state catalog_layouts catalog_keys ]\n  order = [ catalog_state catalog_layouts catalog_keys ]\n}"
              "targets = [ catalog_state catalog_layouts ]\n  order = [ catalog_state catalog_layouts ]\n}\n\nrebuild-group catalog_keys_group {\n  targets = [ catalog_keys ]\n  order = [ catalog_keys ]\n}"
              source
          )
      groupMismatchCodes `shouldContain` [CatalogReadModelTargetOutsideGroup]
      groupMismatchCodes `shouldContain` [CatalogProjectionTargetOutsideGroup]

      conflictDiagnostics <-
        diagnosticsForSource
          "projection-owner-legacy-conflict.keiro"
          ( T.replace
              "  wire kind=ctorName fields=camelCase schemaVersion=1"
              "  wire kind=ctorName fields=camelCase schemaVersion=1\n\n  projection catalog_validation key=version\n    status-map { Activated=>active }"
              source
          )
      let conflicts = filter ((== CatalogReadModelLegacyProjectionConflict) . (.code)) conflictDiagnostics
      length conflicts `shouldBe` 1
      conflicts `shouldSatisfy` all ((== 1) . length . (.relatedLocations))
      conflicts `shouldSatisfy` all (T.isInfixOf "remove the legacy aggregate projection clause" . (.message))

    it "derives and restores mapped projection impact for the compiled A/B catalog fixture" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      service <- checkedServiceFromText "projection-catalog.keiro" source
      baseImpact <- case ProjectionImpact.projectionMappedImpactForService service of
        Nothing -> expectationFailure "projection fixture type graph did not resolve" >> fail "unreachable"
        Just value -> pure value
      ProjectionImpact.projectionConsumersFor baseImpact (MappedKey "OrderPayload")
        `shouldBe` Set.singleton (CatalogProjectionConsumer "order_summary_writer" "Orders")
      ProjectionImpact.projectionConsumersFor baseImpact (MappedKey "SharedReference")
        `shouldBe` Set.fromList
          [ CatalogProjectionConsumer "order_summary_writer" "Orders",
            CatalogProjectionConsumer "shipment_writer" "Shipments"
          ]
      (.unsupported) baseImpact
        `shouldBe` [ ProjectionImpact.UnsupportedProjectionImpact
                       (UnsupportedCatalogCategory "audit_writer" "audit")
                       "reporting"
                       (Set.singleton "audit_log")
                       (Set.singleton "catalogAudit")
                       True
                   ]
      let rendered = ProjectionImpact.renderProjectionMappedImpact baseImpact
      rendered `shouldContain` ["      inherited event roots: Orders event OrderRecorded .orderPayload : OrderPayload"]
      rendered
        `shouldContain` ["      operation: group=shipping; targets=shipment_summary; read-models=shipmentLookup; replayable=no; source-fingerprint=aggregate:Shipments/generated-codec/v1/mapped-9456a95e380c74b5"]
      rendered `shouldContain` ["    catalog-category:audit_writer:audit"]

      eventChanged <- checkedServiceFromText "projection-catalog-event-changed.keiro" (T.replace "version = \"1\"" "version = \"2\"" source)
      sourceChanged <- checkedServiceFromText "projection-catalog-source-changed.keiro" (T.replace "source = aggregate Orders" "source = aggregate Shipments" source)
      replayChanged <- checkedServiceFromText "projection-catalog-replay-changed.keiro" (T.replace "replay = live-only \"carrier events cannot be replayed\"" "replay = explicit" source)
      observationChanged <- checkedServiceFromText "projection-catalog-observation-changed.keiro" (T.replace "targets = [ order_summary ]" "targets = [ audit_log ]" source)
      categoryChanged <- checkedServiceFromText "projection-catalog-category-changed.keiro" (T.replace "source = category \"audit\"" "source = category \"archive-audit\"" source)
      let requireImpact caseLabel candidate = case ProjectionImpact.projectionMappedImpactForService candidate of
            Nothing -> expectationFailure (caseLabel <> " type graph did not resolve") >> fail "unreachable"
            Just value -> pure value
          findOperation derived impact =
            Map.lookup derived ((.operations) impact)
          operationReplay (ProjectionImpact.ProjectionOperationalImpact _ _ _ _ canReplay _) = canReplay
          operationObservers (ProjectionImpact.ProjectionOperationalImpact _ _ _ observers _ _) = observers
          operationFingerprint (ProjectionImpact.ProjectionOperationalImpact _ _ _ _ _ fingerprint) = fingerprint
      eventImpact <- requireImpact "event mutation" eventChanged
      sourceImpact <- requireImpact "source mutation" sourceChanged
      replayImpact <- requireImpact "replay mutation" replayChanged
      observationImpact <- requireImpact "observation mutation" observationChanged
      categoryImpact <- requireImpact "category mutation" categoryChanged
      operationFingerprint <$> findOperation (CatalogProjectionConsumer "order_summary_writer" "Orders") eventImpact
        `shouldNotBe` operationFingerprint <$> findOperation (CatalogProjectionConsumer "order_summary_writer" "Orders") baseImpact
      ProjectionImpact.projectionConsumersFor sourceImpact (MappedKey "OrderPayload")
        `shouldBe` Set.empty
      operationReplay <$> findOperation (CatalogProjectionConsumer "shipment_writer" "Shipments") replayImpact
        `shouldBe` Just True
      operationObservers <$> findOperation (CatalogProjectionConsumer "order_summary_writer" "Orders") observationImpact
        `shouldBe` Just (Set.singleton "order_totals_lookup")
      map (.source) ((.unsupported) categoryImpact)
        `shouldBe` [UnsupportedCatalogCategory "audit_writer" "archive-audit"]
      restored <- checkedServiceFromText "projection-catalog-restored.keiro" source >>= requireImpact "restored fixture"
      restored `shouldBe` baseImpact

    it "feature-gates catalog declarations before validation in languages 1-4" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      case parseSource "projection-catalog-v4.keiro" (T.replace "language keiro-dsl 5" "language keiro-dsl 4" source) of
        Left failure -> do
          renderParseFailure failure `shouldSatisfy` T.isInfixOf "LanguageFeatureRequiresVersion"
          renderParseFailure failure `shouldSatisfy` T.isInfixOf "requires keiro-dsl language version 5"
        Right _ -> expectationFailure "language 4 accepted projection-catalog syntax"

    it "keeps the catalog structural guards live" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      let mutationCodes mutation = do
            service <- checkedServiceFromText "projection-catalog-mutation.keiro" (mutation source)
            pure (map (.code) (validateService service))
          revisionV2AuditBlock =
            T.unlines
              [ "  target audit_log {",
                "    schema-version = \"v2\"",
                "    provisioner = \"reporting-v2-audit-log\"",
                "    provisioner-version = 1",
                "    expected-shape = \"audit-log-v2\"",
                "    validator = \"reporting-v2-audit-log-validator\"",
                "    validator-version = 1",
                "    promotion owned-sequence \"audit_log_id_seq__v2\" -> \"audit_log_id_seq\"",
                "  }"
              ]
      missingAsyncIdentity <- mutationCodes (T.replace "  subscription = \"catalog-demo-audit\"\n" "")
      missingAsyncIdentity `shouldContain` [CatalogAsyncIdentityMissing]
      missingCheckpointPolicy <- mutationCodes (T.replace "  checkpoint-on-missing = from-current-head\n" "")
      missingCheckpointPolicy `shouldContain` [CatalogCheckpointPolicyMissing]
      duplicateCheckpointPolicy <- mutationCodes (T.replace "  checkpoint-on-missing = from-current-head\n" "  checkpoint-on-missing = from-current-head\n  checkpoint-on-missing = fail\n")
      duplicateCheckpointPolicy `shouldContain` [CatalogCheckpointPolicyDuplicate]
      unexpectedInlineCheckpointPolicy <- mutationCodes (T.replace "  order = 10\n  replay = explicit" "  order = 10\n  checkpoint-on-missing = from-beginning\n  replay = explicit")
      unexpectedInlineCheckpointPolicy `shouldContain` [CatalogCheckpointPolicyUnexpected]
      replayUnsafeCheckpointPolicy <- mutationCodes (T.replace "table = \"audit_log\"\n  reset = preserve" "table = \"audit_log\"\n  reset = clear")
      replayUnsafeCheckpointPolicy `shouldContain` [CatalogCheckpointPolicyReplayUnsafe]
      case parseSource "projection-catalog-unknown-checkpoint-policy.keiro" (T.replace "checkpoint-on-missing = from-current-head" "checkpoint-on-missing = newest" source) of
        Left failure -> do
          let rendered = renderParseFailure failure
          rendered `shouldSatisfy` T.isInfixOf "unknown checkpoint-on-missing policy"
          rendered `shouldSatisfy` T.isInfixOf "from-beginning"
          rendered `shouldSatisfy` T.isInfixOf "from-current-head"
          rendered `shouldSatisfy` T.isInfixOf "fail"
        Right _ -> expectationFailure "unknown checkpoint-on-missing value parsed successfully"
      forM_ ["from-beginning", "fail"] $ \policy -> do
        acceptedPolicy <- mutationCodes (T.replace "checkpoint-on-missing = from-current-head" ("checkpoint-on-missing = " <> policy))
        acceptedPolicy `shouldNotContain` [CatalogCheckpointPolicyMissing, CatalogCheckpointPolicyDuplicate, CatalogCheckpointPolicyUnexpected, CatalogCheckpointPolicyReplayUnsafe]
        acceptedClearPolicy <- mutationCodes (T.replace "table = \"audit_log\"\n  reset = preserve" "table = \"audit_log\"\n  reset = clear" . T.replace "checkpoint-on-missing = from-current-head" ("checkpoint-on-missing = " <> policy))
        acceptedClearPolicy `shouldNotContain` [CatalogCheckpointPolicyReplayUnsafe]
      unsafeLiveOnly <- mutationCodes (T.replace "  replay = explicit\n}" "  replay = live-only \"external side effect\"\n}")
      unsafeLiveOnly `shouldContain` [CatalogClearTargetLiveOnly]
      duplicateOrder <- mutationCodes (T.replace "  order = 20\n" "  order = 10\n")
      duplicateOrder `shouldContain` [CatalogDuplicateHandlerOrder]
      badGroupOrder <- mutationCodes (T.replace "  order = [ order_summary order_totals audit_log ]" "  order = [ order_summary order_summary audit_log ]")
      badGroupOrder `shouldContain` [CatalogGroupOrderMismatch]
      missingOwner <- mutationCodes (T.replace "  targets = [ order_summary order_totals ]\n" "  targets = [ order_summary ]\n")
      missingOwner `shouldContain` [CatalogTargetUnowned]
      unknownDependency <- mutationCodes (T.replace "  depends-on = [ order_summary ]\n" "  depends-on = [ missing_target ]\n")
      unknownDependency `shouldContain` [CatalogTargetDependencyUnknown]
      dependencyCycle <- mutationCodes (T.replace "  reset = clear\n}\n\ntarget audit_log" "  reset = clear\n  depends-on = [ order_totals ]\n}\n\ntarget audit_log")
      dependencyCycle `shouldContain` [CatalogTargetDependencyCycle]
      overlappingSource <- mutationCodes (T.replace "  source = aggregate Orders\n" "  source = aggregate Orders\n  source = category \"orders\"\n")
      overlappingSource `shouldContain` [CatalogSourceOverlap]
      ambiguousSourceOrdering <- mutationCodes (T.replace "  source = category \"audit\"\n" "  source = all\n")
      ambiguousSourceOrdering `shouldContain` [CatalogAmbiguousSourceOrdering]
      missingQueryBinding <- mutationCodes (T.replace "  targets = [ audit_log ]\n}\n\nprojection-owner audit_writer" "  targets = [ order_summary ]\n}\n\nprojection-owner audit_writer")
      missingQueryBinding `shouldContain` [CatalogAsyncQueryBindingMissing]
      missingRevisionTarget <- mutationCodes (T.replace "  target audit_log {\n    schema-version = \"v2\"" "  target missing_target {\n    schema-version = \"v2\"")
      missingRevisionTarget `shouldContain` [CatalogRevisionTargetUnknown, CatalogRevisionTargetSetMismatch]
      incompleteRevision <- mutationCodes (T.replace revisionV2AuditBlock "")
      incompleteRevision `shouldContain` [CatalogRevisionTargetSetMismatch]
      invalidRevisionIdentity <- mutationCodes (T.replace "provisioner-version = 1" "provisioner-version = 0")
      invalidRevisionIdentity `shouldContain` [CatalogRevisionIdentityInvalid]
      invalidContractVersion <- mutationCodes (T.replace "external-read order_totals_reader {\n  version = 1" "external-read order_totals_reader {\n  version = 0")
      invalidContractVersion `shouldContain` [CatalogExternalReadVersionInvalid]
      missingExternalQuery <- mutationCodes (T.replace "query = order_totals_lookup" "query = missing_query")
      missingExternalQuery `shouldContain` [CatalogExternalReadQueryUnknown]
      multiTargetExternalQuery <- mutationCodes (T.replace "  targets = [ order_totals ]\n}\n\nexternal-read" "  targets = [ order_summary order_totals ]\n  backing = order_totals\n}\n\nexternal-read")
      multiTargetExternalQuery `shouldContain` [CatalogExternalReadTargetCardinalityInvalid]
      emptyCompatibility <- mutationCodes (T.replace "compatible-revisions = [ reporting_v1 reporting_v2 ]" "compatible-revisions = [ ]")
      emptyCompatibility `shouldContain` [CatalogExternalReadCompatibilityInvalid]
      unknownCompatibleRevision <- mutationCodes (T.replace "compatible-revisions = [ reporting_v1 reporting_v2 ]" "compatible-revisions = [ missing_revision ]")
      unknownCompatibleRevision `shouldContain` [CatalogExternalReadRevisionUnknown]
      wrongRevisionGroup <- mutationCodes (T.replace "query = order_totals_lookup" "query = shipmentLookup")
      wrongRevisionGroup `shouldContain` [CatalogExternalReadRevisionGroupMismatch]
      invalidResultIdentity <- mutationCodes (T.replace "result-schema = \"app_contract\"" "result-schema = \"app-contract\"")
      invalidResultIdentity `shouldContain` [CatalogExternalReadIdentityInvalid]
      invalidSurfaceGeneration <- mutationCodes (T.replace "surface-generation = 1" "surface-generation = 0")
      invalidSurfaceGeneration `shouldContain` [CatalogExternalReadSurfaceGenerationInvalid]

    it "generates one facade, one create-once behavior surface, and durable ledger facts" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      service <- checkedServiceFromText "projection-catalog.keiro" source
      let spec = checkedSpec service
          modules = scaffoldServiceModules (defaultContext (spec.context)) service
          facade = generatedTextEndingIn "Generated/CatalogDemo/ProjectionCatalog.hs" modules
          holes = case [(.text) m | m <- modules, (.kind) m == HoleStub, "ProjectionCatalog/ProjectionCatalogHoles.hs" `T.isSuffixOf` T.pack ((.path) m)] of
            [value] -> value
            values -> error ("expected one projection catalog hole module, got " <> show (length values))
          facts = projectionCatalogFactsForService service
      facade `shouldSatisfy` T.isInfixOf "Catalog.validateProjectionCatalog projectionCatalog"
      facade `shouldSatisfy` T.isInfixOf "Catalog.ClearBeforeReplay"
      facade `shouldSatisfy` T.isInfixOf "Catalog.PreserveAndReconcile"
      facade `shouldSatisfy` T.isInfixOf "KirokuSubscription.FromCurrentHead"
      facade `shouldSatisfy` T.isInfixOf "Catalog.ProjectionRevision (must (Catalog.mkProjectionRevisionId \"reporting_v1\"))"
      facade `shouldSatisfy` T.isInfixOf "Catalog.TargetSchemaVersion \"v2\""
      facade `shouldSatisfy` T.isInfixOf "Catalog.AllRowsExternalRead (must (Catalog.mkExternalReadContractId \"order_totals_reader\"))"
      facade `shouldSatisfy` T.isInfixOf "Catalog.QualifiedSqlType \"app_contract\" \"order_totals_row_v1\""
      facade `shouldSatisfy` T.isInfixOf "\"fnv1a:768a23d719dcb4d4\""
      facade `shouldSatisfy` T.isInfixOf "projectionCatalogQuerySupplies = Catalog.resolvedQuerySupplies validatedProjectionCatalog"
      facade `shouldSatisfy` T.isInfixOf "ordersInlineProjections = concat [orderSummaryWriterInlineProjections]"
      facade
        `shouldSatisfy` ( \text ->
                            let (_, fromFirst) = T.breakOn "orderSummaryWriterProjectionSet" text
                             in not (T.null fromFirst) && T.isInfixOf "auditWriterProjectionSet" (T.drop 1 fromFirst)
                        )
      holes `shouldSatisfy` T.isInfixOf "fill order_summary_writer live apply"
      holes `shouldSatisfy` T.isInfixOf "fill order_summary_writer replay apply"
      holes `shouldSatisfy` T.isInfixOf "provisionReportingV2OrderSummary :: Catalog.TargetProvisioningContext"
      holes `shouldSatisfy` T.isInfixOf "applyReportingV2OrderSummaryWriterLive :: Catalog.PhysicalTargets"
      holes `shouldSatisfy` T.isInfixOf "applyReportingV2AuditWriterLive :: Catalog.PhysicalTargets"
      holes `shouldSatisfy` T.isInfixOf "orderTotalsReaderV1KeyedExternalRead :: [Catalog.SqlFunctionArgument]"
      holes `shouldSatisfy` T.isInfixOf "application-owned private SQL function"
      facts `shouldBe` sort facts
      facts `shouldSatisfy` any (T.isPrefixOf "target|order_summary|")
      facts `shouldSatisfy` any (T.isPrefixOf "owner|audit_writer|")
      facts `shouldSatisfy` any (T.isPrefixOf "delivery|audit_writer|subscription|")
      facts `shouldSatisfy` any (T.isPrefixOf "revision|reporting_v1|reporting|")
      facts `shouldSatisfy` any (T.isPrefixOf "external-read|order_totals_reader|1|order_totals_lookup|app_contract.order_totals_row_v1|fnv1a:768a23d719dcb4d4|reporting_v1,reporting_v2|1|")
      facts `shouldSatisfy` any (T.isInfixOf "order_summary,v2,reporting-v2-order-summary")
      facts `shouldSatisfy` any (T.isPrefixOf "freshness|catalogAudit|immediate|")
      facts `shouldSatisfy` any (T.isPrefixOf "cursor|catalogAudit|catalog-demo-audit|")
      facts `shouldSatisfy` any (T.isPrefixOf "query|order_totals_lookup|reporting|order_totals|order_totals|")
      facts `shouldSatisfy` any (T.isPrefixOf "supply|order_inline|order_summary_writer|reporting|order_summary|")
      facts `shouldSatisfy` any (T.isPrefixOf "supply|order_totals_lookup|order_summary_writer|reporting|order_totals|")
      facts `shouldSatisfy` any (T.isInfixOf "|from-current-head|explicit|")

    it "distinguishes external-read versioning, retirement, compatibility, and derived result-shape changes" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      baseline <- checkedServiceFromText "projection-catalog-external-read.keiro" source
      let externalReadBlock version resultType =
            T.unlines
              [ "external-read order_totals_reader {",
                "  version = " <> T.pack (show version),
                "  query = order_totals_lookup",
                "  result-schema = \"app_contract\"",
                "  result-type = \"" <> resultType <> "\"",
                "  compatible-revisions = [ reporting_v1 reporting_v2 ]",
                "  surface-generation = 1",
                "}",
                ""
              ]
          v1Block = externalReadBlock (1 :: Int) "order_totals_row_v1"
          codes candidate = map ((.code) . kindOfChange) (diffServices baseline candidate)
      versionAdded <-
        checkedServiceFromText
          "projection-catalog-external-read-v2.keiro"
          (T.replace v1Block (v1Block <> externalReadBlock (2 :: Int) "order_totals_row_v2") source)
      retired <- checkedServiceFromText "projection-catalog-external-read-retired.keiro" (T.replace v1Block "" source)
      compatibilityChanged <-
        checkedServiceFromText
          "projection-catalog-external-read-compatible.keiro"
          (T.replace "compatible-revisions = [ reporting_v1 reporting_v2 ]" "compatible-revisions = [ reporting_v1 ]" source)
      shapeChanged <-
        checkedServiceFromText
          "projection-catalog-external-read-shape.keiro"
          (T.replace "shape = \"fnv1a:768a23d719dcb4d4\"" "shape = \"fnv1a:0000000000000000\"" source)
      validateService versionAdded `shouldBe` []
      codes versionAdded `shouldContain` [CatalogExternalReadVersionAdded]
      codes retired `shouldContain` [CatalogExternalReadRetired]
      codes compatibilityChanged `shouldContain` [CatalogExternalReadCompatibilityChanged]
      codes shapeChanged `shouldContain` [CatalogExternalReadResultShapeChanged]

      reordered <-
        checkedServiceFromText
          "projection-catalog-external-read-reordered.keiro"
          (T.replace "compatible-revisions = [ reporting_v1 reporting_v2 ]" "compatible-revisions = [ reporting_v2 reporting_v1 ]" source)
      projectionCatalogFactsForService reordered `shouldBe` projectionCatalogFactsForService baseline
      codes reordered `shouldNotContain` [CatalogExternalReadCompatibilityChanged]

    it "preserves edited catalog behavior holes on regeneration" $
      withTempDirectory "keiro-dsl-projection-catalog-create-once" $ \out -> do
        parsed <- parsedSourceOf "test/fixtures/projection-catalog.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            holeSuffix = "ProjectionCatalog/ProjectionCatalogHoles.hs"
        modules <- case planTestServiceScaffold ctx service of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right planned -> pure planned
        first <- executeServiceScaffold out False "projection-catalog.keiro" ((.sourceLanguage) parsed) ctx service modules
        first `shouldSatisfy` isSuccessfulScaffold
        let path = out </> onlyPathEndingIn holeSuffix modules
            reviewedBody = "module CatalogDemo.ProjectionCatalog.ProjectionCatalogHoles where\nreviewed = True\n"
        TIO.writeFile path reviewedBody
        second <- executeServiceScaffold out False "projection-catalog.keiro" ((.sourceLanguage) parsed) ctx service modules
        second `shouldSatisfy` isSuccessfulScaffold
        TIO.readFile path `shouldReturn` reviewedBody
        case second of
          Left _ -> fail "unreachable"
          Right report ->
            do
              (.dispositions) report
                `shouldSatisfy` any (\(moduleValue, disposition) -> holeSuffix `isSuffixOfPath` moduleValue && disposition == Skipped)
              renderScaffoldReport report
                `shouldContain` ["      inherited event roots: Orders event OrderRecorded .orderPayload : OrderPayload"]
              renderScaffoldReport report
                `shouldContain` ["      operation: group=shipping; targets=shipment_summary; read-models=shipmentLookup; replayable=no; source-fingerprint=aggregate:Shipments/generated-codec/v1/mapped-9456a95e380c74b5"]
              renderScaffoldReport report `shouldContain` ["    catalog-category:audit_writer:audit"]

    it "classifies every catalog evolution dimension and reports machine-readable replay impact" $ do
      source <- readTestText "test/fixtures/projection-catalog.keiro"
      oldService <- checkedServiceFromText "projection-catalog-old.keiro" source
      let targetBlock = T.unlines ["target audit_log {", "  schema = \"sales\"", "  table = \"audit_log\"", "  reset = preserve", "}", ""]
          ownerBlock =
            T.unlines
              [ "projection-owner audit_writer {",
                "  source = category \"audit\"",
                "  delivery = subscription",
                "  group = reporting",
                "  targets = [ audit_log ]",
                "  order = 20",
                "  subscription = \"catalog-demo-audit\"",
                "  dedup = \"catalog-demo-audit-v1\"",
                "  checkpoint-on-missing = from-current-head",
                "  replay = explicit",
                "}",
                ""
              ]
          mutations =
            [ ("target-added", CatalogTargetAdded, T.replace "rebuild-group reporting" "target archive_log {\n  schema = \"sales\"\n  table = \"archive_log\"\n  reset = preserve\n}\n\nrebuild-group reporting"),
              ("target-removed", CatalogTargetRemoved, T.replace targetBlock ""),
              ("target-location", CatalogTargetLocationChanged, T.replace "table = \"order_summary\"" "table = \"order_summary_v2\""),
              ("target-reset", CatalogTargetResetPolicyChanged, T.replace "reset = preserve" "reset = clear"),
              ("target-dependency", CatalogTargetDependencyChanged, T.replace "depends-on = [ order_summary ]" "depends-on = [ audit_log ]"),
              ("group-membership-order", CatalogGroupChanged, T.replace "order = [ order_summary order_totals audit_log ]" "order = [ audit_log order_summary order_totals ]"),
              ("revision-schema", CatalogTargetSchemaChanged, T.replace "schema-version = \"v2\"" "schema-version = \"v2.1\""),
              ("revision-provider", CatalogProjectionRevisionChanged, T.replace "provisioner = \"reporting-v2-order-summary\"" "provisioner = \"reporting-v2-order-summary-new\""),
              ("owner-binding", CatalogOwnerChanged, T.replace "targets = [ order_summary order_totals ]" "targets = [ order_summary ]"),
              ("owner-removed", CatalogOwnerRemoved, T.replace ownerBlock ""),
              ("handler-order", CatalogHandlerOrderChanged, T.replace "order = 20" "order = 30"),
              ("source", CatalogSourceChanged, T.replace "source = aggregate Orders" "source = category \"archived-orders\""),
              ("delivery", ProjectionDeliveryChanged, T.replace "delivery = subscription" "delivery = inline"),
              ("subscription", CatalogFeedIdentityChanged, T.replace "subscription = \"catalog-demo-audit\"" "subscription = \"catalog-demo-audit-v2\""),
              ("dedup", CatalogFeedIdentityChanged, T.replace "dedup = \"catalog-demo-audit-v1\"" "dedup = \"catalog-demo-audit-v2\""),
              ("checkpoint-policy", CatalogCheckpointPolicyChanged, T.replace "checkpoint-on-missing = from-current-head" "checkpoint-on-missing = fail"),
              ("replay-policy", CatalogReplayPolicyChanged, T.replace "replay = live-only \"carrier events cannot be replayed\"" "replay = explicit"),
              ("query-binding", CatalogQueryBindingChanged, T.replace "targets = [ audit_log ]\n}\n\nprojection-owner audit_writer" "targets = [ order_summary ]\n}\n\nprojection-owner audit_writer")
            ]
      changedServices <-
        forM mutations $ \(caseName, expectedCode, mutate) -> do
          changed <- checkedServiceFromText ("projection-catalog-" <> caseName <> ".keiro") (mutate source)
          map ((.code) . kindOfChange) (diffServices oldService changed) `shouldContain` [expectedCode]
          pure (caseName, changed)
      supplierChanged <-
        checkedServiceFromText
          "projection-catalog-supplier-changed.keiro"
          ( T.replace
              "projection-owner audit_writer"
              ( T.unlines
                  [ "projection-owner order_totals_writer {",
                    "  source = category \"orderTotals\"",
                    "  delivery = inline",
                    "  group = reporting",
                    "  targets = [ order_totals ]",
                    "  order = 15",
                    "  replay = explicit",
                    "}",
                    "",
                    "projection-owner audit_writer"
                  ]
              )
              (T.replace "targets = [ order_summary order_totals ]" "targets = [ order_summary ]" source)
          )
      validateService supplierChanged `shouldBe` []
      map ((.code) . kindOfChange) (diffServices oldService supplierChanged)
        `shouldContain` [CatalogQueryBindingChanged]
      sourceChanged <- case lookup "source" changedServices of
        Just changed -> pure changed
        Nothing -> expectationFailure "source mutation was not exercised" >> fail "unreachable"
      policyChanged <- case lookup "checkpoint-policy" changedServices of
        Just changed -> pure changed
        Nothing -> expectationFailure "checkpoint policy mutation was not exercised" >> fail "unreachable"
      let policyChanges = [change | change <- diffServices oldService policyChanged, (.code) (kindOfChange change) == CatalogCheckpointPolicyChanged]
      case policyChanges of
        [change] -> do
          let finding = kindOfChange change
              rendered = renderFinding change
              encoded = LazyText.toStrict (LazyTextEncoding.decodeUtf8 (Aeson.encode (diffReport defaultGate [change])))
          (.persistedIdentity) (finding.vector) `shouldBe` VCompatible
          (.consumerBuild) (finding.vector) `shouldBe` VBreaking
          (.rollout) (finding.vector) `shouldBe` Set.singleton RolloutStopTheWorld
          (.detail) finding `shouldSatisfy` T.isInfixOf "existing checkpoint rows remain unchanged"
          rendered `shouldSatisfy` T.isInfixOf "from-current-head -> fail"
          rendered `shouldSatisfy` T.isInfixOf "rollout=stop-the-world"
          encoded `shouldSatisfy` T.isInfixOf "CatalogCheckpointPolicyChanged"
          encoded `shouldSatisfy` T.isInfixOf "from-current-head -> fail"
          encoded `shouldSatisfy` T.isInfixOf "\"persisted-identity\":\"compatible\""
          encoded `shouldSatisfy` T.isInfixOf "\"rollout\":[\"stop-the-world\"]"
        changes -> expectationFailure ("expected one checkpoint-policy finding, got " <> show (length changes))
      case ReplayImpact.catalogReplayImpactServices oldService policyChanged of
        CatalogReplayAffected groups targets sources adapters invalidates -> do
          groups `shouldBe` Set.singleton "reporting"
          targets `shouldBe` Set.singleton "audit_log"
          sources `shouldBe` Set.singleton "category:audit"
          adapters `shouldBe` Set.singleton "audit_writer"
          invalidates `shouldBe` True
        CatalogReplayNeutral -> expectationFailure "checkpoint-policy change was replay-neutral"
      case ReplayImpact.catalogReplayImpactServices oldService sourceChanged of
        CatalogReplayAffected groups targets sources adapters invalidates -> do
          groups `shouldBe` Set.singleton "reporting"
          targets `shouldBe` Set.fromList ["order_summary", "order_totals"]
          sources `shouldBe` Set.fromList ["aggregate:Orders", "category:archived-orders"]
          adapters `shouldBe` Set.singleton "order_summary_writer"
          invalidates `shouldBe` True
        CatalogReplayNeutral -> expectationFailure "catalog source change was replay-neutral"

  describe "ID domain" $ do
    let parseRight name source = case parseSource name source of
          Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
          Right value -> pure value

    it "registers language 3 as the first enforced runtime contract" $ do
      parsed <- case parseSource "id-domain-v3.keiro" "language keiro-dsl 3\ncontext id-domain\n" of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let contract = checkedLanguageContract (checkedSource parsed)
      effectiveRuntimeSemantics contract `shouldBe` "keiro-dsl/runtime-semantics/2"
      (.contractLanguageVersion) contract `shouldBe` maybe (error "missing v3") id (languageVersion 3)
      idDomainContractFor contract "req" `shouldSatisfy` (/= Nothing)

    it "registers language 4 as contract admission semantics without changing aggregate ID admission" $ do
      v3 <- parseRight "id-domain-v3.keiro" "language keiro-dsl 3\ncontext id-domain\n"
      v4 <- parseRight "id-domain-v4.keiro" "language keiro-dsl 4\ncontext id-domain\n"
      let v3Contract = checkedLanguageContract (checkedSource v3)
          v4Contract = checkedLanguageContract (checkedSource v4)
      effectiveRuntimeSemantics v4Contract `shouldBe` "keiro-dsl/runtime-semantics/3"
      (.contractLanguageVersion) v4Contract `shouldBe` maybe (error "missing v4") id (languageVersion 4)
      idDomainContractFor v4Contract "req" `shouldBe` idDomainContractFor v3Contract "req"
      contractIdDomainContractFor v3Contract "req" `shouldBe` Nothing
      contractIdDomainContractFor v4Contract "req" `shouldBe` Just (typeIdV7Domain "req")

    it "constructs typed KindIDs only after the frozen four-way admission policy" $ do
      let valid = "req_01h455vb4pex5vsknk084sn02q"
          uppercase = "req_01H455VB4PEX5VSKNK084SN02Q"
          nonV7 = "req_00041061050r3gg28a1c60t3gf"
      (KindID.toText @"req" <$> parseKindIdV7Text @"req" valid) `shouldBe` Right valid
      parseKindIdV7Text @"req" "req-1" `shouldSatisfy` \case
        Left IdDomainMalformed {} -> True
        _ -> False
      parseKindIdV7Text @"req" "other_01h455vb4pex5vsknk084sn02q" `shouldSatisfy` \case
        Left (IdDomainWrongPrefix "req" "other") -> True
        _ -> False
      parseKindIdV7Text @"req" uppercase `shouldBe` Left IdDomainNonCanonical
      parseKindIdV7Text @"req" nonV7 `shouldSatisfy` \case
        Left IdDomainNotUuidV7 {} -> True
        _ -> False
      parseEither (parseKindIdV7Value @"req") (Aeson.String uppercase)
        `shouldSatisfy` \case
          Left problem -> "not canonical lowercase" `T.isInfixOf` T.pack problem
          Right _ -> False

    it "validates contract TypeID prefixes only at the language-4 boundary" $ do
      let source versionNumber =
            T.unlines
              [ "language keiro-dsl " <> T.pack (show versionNumber),
                "context invalid-contract-prefix",
                "contract emergency {",
                "  schemaVersion 1",
                "  discriminator messageType",
                "  topic incidentEvents \"emergency.incident.events\"",
                "  event IncidentDeclared on incidentEvents {",
                "    incidentId: typeid \"Bad\"",
                "  }",
                "}"
              ]
      v3 <- parseRight "contract-prefix-v3.keiro" (source (3 :: Int))
      v4 <- parseRight "contract-prefix-v4.keiro" (source (4 :: Int))
      validateService (checkedSource v3) `shouldBe` []
      case validateService (checkedSource v4) of
        [diagnostic] -> do
          (.code) diagnostic `shouldBe` ContractInvalidTypeIdPrefix
          (.line) diagnostic `shouldBe` 8
          (.message) diagnostic `shouldSatisfy` T.isInfixOf "contract 'emergency' event 'IncidentDeclared' field 'incidentId'"
          (.message) diagnostic `shouldSatisfy` T.isInfixOf "invalid TypeID prefix 'Bad'"
        diagnostics -> expectationFailure ("expected one invalid contract prefix diagnostic, got " <> show diagnostics)

    it "keeps version-3 and version-4 aggregate fold and replay semantics equal" $ do
      v3Text <- readTestText "test/fixtures/id-domain-migration-v3.keiro"
      v3 <- parseRight "fold-v3.keiro" v3Text
      v4 <- parseRight "fold-v4.keiro" (T.replace "language keiro-dsl 3" "language keiro-dsl 4" v3Text)
      let v3Service = checkedSource v3
          v4Service = checkedSource v4
          fingerprints service =
            [ aggregateFoldFingerprintForService service aggregate
            | NAggregate aggregate <- (.nodes) (checkedSpec service)
            ]
      fingerprints v4Service `shouldBe` fingerprints v3Service
      diffServices v3Service v4Service `shouldBe` []
      resolvedFold (ReplayImpact.replayImpactServices v3Service v4Service) `shouldBe` ReplayNeutral

    it "keeps runtime validation and the exact Keiki text image in agreement" $ do
      let contract = typeIdV7Domain "req"
          sampleText = idDomainSampleText contract
          suffix = T.drop (T.length "req_") sampleText
          replaceAt position replacement value =
            T.take position value <> T.singleton replacement <> T.drop (position + 1) value
          accepted =
            [ sampleText,
              replaceAt (T.length "req_" + 10) 'f' sampleText,
              replaceAt (T.length "req_" + 13) 'v' sampleText
            ]
          rejected =
            [ "",
              "req_",
              "other_" <> suffix,
              "req__" <> suffix,
              T.dropEnd 1 sampleText,
              sampleText <> "0",
              T.toUpper sampleText,
              replaceAt (T.length "req_" + 0) '8' sampleText,
              replaceAt (T.length "req_" + 10) 'd' sampleText,
              replaceAt (T.length "req_" + 13) 'c' sampleText
            ]
          patternValue = either (error . show) id (idDomainTextPattern contract)
      idDomainVersion contract `shouldBe` "keiro-dsl/id-domain/typeid-v7/1"
      idDomainSeparator contract `shouldBe` '_'
      idDomainSuffixLength contract `shouldBe` 26
      idDomainMaxLength contract `shouldBe` T.length sampleText
      forM_ accepted $ \value -> do
        validateIdDomainText contract value `shouldBe` Right ()
        matchesTextPattern patternValue value `shouldBe` True
      forM_ rejected $ \value -> do
        validateIdDomainText contract value `shouldSatisfy` isLeft
        matchesTextPattern patternValue value `shouldBe` False

    it "agrees for generated canonical and malformed domain values" $ property $ do
      let crockford = "0123456789abcdefghjkmnpqrstvwxyz"
          segment count = vectorOf count (elements crockford)
      leading <- elements "01234567"
      beforeVersion <- segment 9
      version <- elements "ef"
      beforeVariant <- segment 2
      variantDigit <- elements "89abrstv"
      afterVariant <- segment 12
      let value = T.pack ("req_" <> [leading] <> beforeVersion <> [version] <> beforeVariant <> [variantDigit] <> afterVariant)
          contract = typeIdV7Domain "req"
          patternValue = either (error . show) id (idDomainTextPattern contract)
          invalidValues = [T.toUpper value, "other_" <> T.drop 4 value, T.dropEnd 1 value, value <> "0"]
      pure $
        conjoin
          ( counterexample (T.unpack value) (validateIdDomainText contract value == Right () && matchesTextPattern patternValue value)
              : [counterexample (T.unpack invalid) (isLeft (validateIdDomainText contract invalid) && not (matchesTextPattern patternValue invalid)) | invalid <- invalidValues]
          )

    it "enforces the same contract before consumer binding conversion and explains its version" $ do
      v2Source <- readTestText "test/fixtures/nominal-scalars.keiro"
      let v3Text = T.replace "language keiro-dsl 2" "language keiro-dsl 3" v2Source
      parsed <- case parseSource "nominal-scalars-v3.keiro" v3Text of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let service = checkedSource parsed
          spec = checkedSpec service
          modules = scaffoldServiceModules (defaultContext (spec.context)) service
          generatedText suffix = case [(.text) value | value <- modules, T.pack suffix `T.isSuffixOf` T.pack ((.path) value)] of
            [value] -> value
            values -> error ("expected one generated module ending in " <> suffix <> ", got " <> show (length values))
          codecModule = generatedText "NominalLedger/Codec.hs"
          projectionModule = generatedText "NominalProjections.hs"
          harnessModule = generatedText "NominalLedger/Harness.hs"
      validateService service `shouldBe` []
      codecModule `shouldSatisfy` T.isInfixOf "case validateIdDomainText (typeIdV7Domain \"ord\") input of"
      codecModule `shouldSatisfy` T.isInfixOf "Right () -> case KindID.parseText @\"ord\" input of"
      projectionModule `shouldSatisfy` T.isInfixOf "idDomainTextPattern (typeIdV7Domain \"ord\")"
      projectionModule `shouldSatisfy` T.isInfixOf "validateIdDomainText (typeIdV7Domain \"ord\") value"
      harnessModule `shouldSatisfy` T.isInfixOf "nominal ID binding preserves canonical representations: OrderId"
      harnessModule `shouldSatisfy` T.isInfixOf "nominal ID boundary rejects wrong-prefix and normalized text: OrderId"
      obligations <- either (\errors -> expectationFailure (show errors) >> pure []) pure (bindingObligationsForService service)
      let orderIdBindings = [obligation | obligation <- obligations, (.mappedName) obligation == "OrderId", (.kind) obligation == BindingValue]
      map (.idDomainContract) orderIdBindings `shouldBe` [Just "keiro-dsl/id-domain/typeid-v7/1"]
      renderBindingObligations (spec.context) obligations
        `shouldSatisfy` T.isInfixOf "id-domain-contract: \"keiro-dsl/id-domain/typeid-v7/1\""

    it "reports adoption by boundary, invalidates snapshots, and preserves replay compatibility" $ do
      v2Text <- readTestText "test/fixtures/id-domain-migration-v3.keiro"
      let oldText = T.replace "language keiro-dsl 3" "language keiro-dsl 2" v2Text
      oldSource <- case parseSource "id-domain-migration-v2.keiro" oldText of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      newSource <- case parseSource "id-domain-migration-v3.keiro" v2Text of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let oldService = checkedSource oldSource
          newService = checkedSource newSource
          changes = diffSources oldSource newSource
          findings = [kindOfChange change | change <- changes, changeCode change == IdDomainContractChanged]
      length findings `shouldBe` 1
      forM_ findings $ \finding -> do
        verdictFor PrivateHistoryRead (finding.vector) `shouldBe` VCompatible
        verdictFor OldBinaryReadNewEvents (finding.vector) `shouldBe` VCompatible
        verdictFor SnapshotHydration (finding.vector) `shouldBe` VAdvisory
        verdictFor PublicConsumer (finding.vector) `shouldBe` VBreaking
        verdictFor PersistedIdentity (finding.vector) `shouldBe` VCompatible
        verdictFor ConsumerBuild (finding.vector) `shouldBe` VAdvisory
        (.detail) finding `shouldSatisfy` T.isInfixOf "historical event replay retains its legacy decoder"
        remediationFor (finding.context) ((.code) finding)
          `shouldBe` RemedyDeploymentOrder RolloutProducerLast :| [RemedyStateCodecBump, RemedyRecompileConsumers, RemedyRunConformance]
      [(.detail) finding | change <- changes, changeCode change == SourceLanguageDeclarationChanged, let finding = kindOfChange change]
        `shouldSatisfy` all (T.isInfixOf "effective runtime semantics changed")
      idDomainIdentitiesForService oldService `shouldBe` []
      idDomainIdentitiesForService newService
        `shouldSatisfy` any (T.isInfixOf "contract=keiro-dsl/id-domain/typeid-v7/1")
      resolvedFold (ReplayImpact.replayImpactServices oldService newService) `shouldSatisfy` \case
        ReplayImpact.ReplayAffected impacts ->
          maybe False (.includeSnapshotStreams) (Map.lookup "OrderBook" impacts)
        ReplayImpact.ReplayNeutral -> False

    it "keeps the raw constructor outside the compiled public module surface" $
      withTempDirectory "keiro-dsl-id-domain-hidden-constructor" $ \out -> do
        sourceText <- readTestText "test/fixtures/id-domain-migration-v3.keiro"
        parsed <- case parseSource "id-domain-migration-v3.keiro" sourceText of
          Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
          Right value -> pure value
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            modules = scaffoldServiceModules ctx service
            attempt = out </> "Attempt.hs"
            ghcOutput = out </> ".ghc"
        result <- executeServiceScaffold out False "id-domain-migration-v3.keiro" ((.sourceLanguage) parsed) ctx service modules
        result `shouldSatisfy` isRight
        recordContents <- TIO.readFile (out </> recordFileName (spec.context))
        record <- case parseRecord recordContents of
          Nothing -> expectationFailure "generated ID-domain scaffold record did not parse" >> fail "unreachable"
          Just value -> pure value
        (.idDomains) record `shouldBe` idDomainIdentitiesForService service
        (.nominalEqualities) record
          `shouldSatisfy` any (T.isInfixOf "keiro-dsl/id-domain/typeid-v7/1")
        createDirectoryIfMissing True ghcOutput
        TIO.writeFile
          attempt
          ( T.unlines
              [ "module Attempt where",
                "import Generated.IdDomainMigration.Nominals (OrderId (..))",
                "bad :: OrderId",
                "bad = OrderId \"ord_LEGACY-NOT-TYPEID\""
              ]
          )
        (exitCode, standardOutput, standardError) <-
          readProcessWithExitCode
            "cabal"
            [ "exec",
              "--",
              "ghc",
              "-XGHC2024",
              "-XOverloadedStrings",
              "-fno-code",
              "-fforce-recomp",
              "-package",
              "keiro-core",
              "-outputdir",
              ghcOutput,
              "-i" <> out,
              attempt
            ]
            ""
        exitCode `shouldSatisfy` (/= ExitSuccess)
        (standardOutput <> standardError) `shouldContain` "OrderId"

    it "emits one enforced nominal owner for a version-3 workspace" $ do
      manifest <- readTestText "test/fixtures/workspace-nominals/service.keiro-workspace"
      shared <- readTestText "test/fixtures/workspace-nominals/domain/shared.keiro"
      project <- readTestText "test/fixtures/workspace-nominals/domain/project.keiro"
      artifact <- readTestText "test/fixtures/workspace-nominals/domain/project-artifact.keiro"
      let v3 = T.replace "language keiro-dsl 2" "language keiro-dsl 3"
          source =
            memoryContentSource
              ( Map.fromList
                  [ ("service.keiro-workspace", manifest),
                    ("domain/shared.keiro", v3 shared),
                    ("domain/project.keiro", v3 project),
                    ("domain/project-artifact.keiro", v3 artifact)
                  ]
              )
      loaded <- loadWorkspace source "service.keiro-workspace"
      workspace <- case loaded of
        Left failure -> expectationFailure (show failure) >> fail "unreachable"
        Right value -> pure value
      plan <- case planWorkspaceScaffold "goldens" (workspaceContext workspace) workspace of
        Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
        Right value -> pure value
      let paths = map ((.path) . fst) ((.modules) plan)
      length (filter (== "Generated/WorkspaceNominalProof/Nominals.hs") paths) `shouldBe` 1
      length (filter (== "Generated/WorkspaceNominalProof/Nominals/Internal.hs") paths) `shouldBe` 1
      forM_ [(.text) value | (value, _) <- (.modules) plan, "/Domain.hs" `T.isSuffixOf` T.pack ((.path) value)] $ \domainText ->
        domainText `shouldSatisfy` (not . T.isInfixOf "ProjectId (..)")
      withTempDirectory "keiro-dsl-v3-workspace-record" $ \out -> do
        emitted <- executeWorkspaceScaffold out False plan
        emitted `shouldSatisfy` isRight
        recordContents <- TIO.readFile (out </> workspaceRecordFileName ((.service) workspace))
        record <- case parseWorkspaceRecord recordContents of
          Nothing -> expectationFailure "version-3 workspace record did not parse" >> fail "unreachable"
          Just value -> pure value
        (.idDomains) record `shouldBe` idDomainIdentitiesForService (plan.checkedService)
        (.nominalEqualities) record
          `shouldSatisfy` any (T.isInfixOf "keiro-dsl/id-domain/typeid-v7/1")

    it "emits an abstract public ID, an internal legacy seam, and exact equality" $ do
      v2Source <- readTestText "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      let v3Source = T.replace "language keiro-dsl 2" "language keiro-dsl 3" v2Source
      parsed <- case parseSource "aggregate-scalar-expressions-v3.keiro" v3Source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let service = checkedSource parsed
          spec = checkedSpec service
          modules = scaffoldServiceModules (defaultContext (spec.context)) service
          moduleAt path = case [value | value <- modules, value.path == path] of
            [value] -> pure value
            values -> expectationFailure ("expected one module at " <> path <> ", got " <> show (map (.path) values)) >> fail "unreachable"
      validateService service `shouldBe` []
      publicNominals <- moduleAt "Generated/AggregateScalarExpressions/Nominals.hs"
      internalNominals <- moduleAt "Generated/AggregateScalarExpressions/Nominals/Internal.hs"
      domainModule <- moduleAt "Generated/AggregateScalarExpressions/ScalarAccount/Domain.hs"
      codecModule <- moduleAt "Generated/AggregateScalarExpressions/ScalarAccount/Codec.hs"
      transducerModule <- moduleAt "Generated/AggregateScalarExpressions/ScalarAccount/Transducer.hs"
      (.text) publicNominals `shouldSatisfy` T.isInfixOf "parseRequestId"
      (.text) publicNominals `shouldSatisfy` T.isInfixOf "instance ExactFieldProjection RequestIdEqualityProjection"
      (.text) publicNominals `shouldSatisfy` T.isInfixOf "idDomainTextPattern (typeIdV7Domain \"req\")"
      (.text) publicNominals `shouldSatisfy` (not . T.isInfixOf "unsafeRequestIdFromLegacyText")
      (.text) publicNominals `shouldSatisfy` (not . T.isInfixOf "newtype RequestId")
      (.text) internalNominals `shouldSatisfy` T.isInfixOf "newtype RequestId = RequestId Text"
      (.text) internalNominals `shouldSatisfy` T.isInfixOf "unsafeRequestIdFromLegacyText"
      (.text) domainModule `shouldSatisfy` (not . T.isInfixOf "RequestId (..)")
      (.text) codecModule `shouldSatisfy` T.isInfixOf "unsafeRequestIdFromLegacyText <$>"
      (.text) transducerModule `shouldSatisfy` T.isInfixOf "case parseRequestId"
      firewallBreaches modules `shouldBe` []

  describe "scalar expressions" $ do
    it "parses, validates, and round-trips the authoritative stable scalar fixture" $ do
      source <- readTestText "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      parsed <- case parseSource "aggregate-scalar-expressions-v2.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      validateSpec ((.spec) parsed) `shouldBe` []
      parseSource "round-trip.keiro" (renderSource parsed) `shouldBe` Right parsed
      case [aggregate | NAggregate aggregate <- (.nodes) ((.spec) parsed)] of
        [aggregate] -> case (.transitions) aggregate of
          transition : holeTransition : [] -> do
            (.implementation) transition `shouldBe` GeneratedImplementation
            (.implementation) holeTransition `shouldBe` HoleImplementation
            let environment = expressionEnvironment ((.spec) parsed) aggregate transition
            case lookup "reserved" ((.writes) transition) >>= either (const Nothing) Just . resolveWriteExpr environment "reserved" of
              Just resolved -> do
                (.valueType) resolved `shouldBe` AggregateNatural
                show ((.node) resolved) `shouldContain` "TotalNaturalArithmetic"
              Nothing -> expectationFailure "reserved write did not resolve"
            let service = checkedSource parsed
                modules = scaffoldServiceModules (defaultContext (parsed.spec.context)) service
                transducer = generatedTextEndingIn "Transducer.hs" modules
                holes = holeTextEndingIn "Holes.hs" modules
                surface = aggregateFoldSurfaceForService service aggregate
                manifest = renderManifestForService "aggregate-scalar-expressions-v2.keiro" modules service
                readableTransducer = T.unwords (T.words transducer)
            aggregateFoldFingerprintForService service aggregate `shouldBe` "60f4f059f718b2ee2bca06360ea20221"
            T.lines surface
              `shouldBe` [ "semantic-contract:keiro-dsl/runtime-semantics/2",
                           "state:Open|terminal=false",
                           "state:Reviewed|terminal=false",
                           "state:Closed|terminal=true",
                           "reg:balance:Integer=0",
                           "reg:reserved:Natural=0",
                           "reg:capacity:Natural=5",
                           "reg:machine:Int=0",
                           "reg:label:Text=\"\"",
                           "reg:active:Bool=False",
                           "reg:mode:AccountMode=Normal",
                           "reg:requestId:RequestId=placeholder",
                           "reg:openedAt:Time=(UTCTime (fromGregorian 2026 1 1) (picosecondsToDiffTime 0))",
                           "reg:limits:Limits=initial",
                           "mapped-register:Limits|wire=4463db782a5b9924|canonical=scalar-expressions.Limits.v1|binding=ScalarExpressions.Bindings.limitsBinding|binding-version=1|initial=ScalarExpressions.Bindings.initialLimits",
                           "nominal-equality-use:nominal-equality|name=AccountMode|contract=keiro-dsl/nominal-equality/1|key=Text|domain=finite-text:normal,restricted|owner=generated",
                           "nominal-equality-use:nominal-equality|name=RequestId|contract=keiro-dsl/nominal-equality/2|key=Text|domain=typeid-v7-text:req:keiro-dsl/id-domain/typeid-v7/1|owner=generated",
                           "transition:live|Open|Adjust|implementation=generated|guard=cmd.balance + reg.balance >= -100 && reg.reserved + cmd.requested <= reg.capacity && cmd.observedAt >= reg.openedAt && cmd.limits.minimum >= reg.limits.minimum && cmd.active == false && cmd.mode == reg.mode && cmd.requestId == reg.requestId|writes=balance:=reg.balance + cmd.balance * 2;reserved:=reg.reserved + (cmd.requested - reg.capacity);machine:=-7;label:=\"adjusted\";active:=true;mode:=AccountMode.Restricted;requestId:=RequestId(\"req_01h455vb4pex5vsknk084sn02q\");openedAt:=\"2026-02-03T04:05:06Z\";limits:=cmd.limits|emits=Adjusted|outputs=Adjusted=generated-command-identity:Adjust[balance=balance:Integer,requested=requested:Natural,machine=machine:Int,label=label:Text,active=active:Bool,mode=mode:AccountMode,requestId=requestId:RequestId,observedAt=observedAt:Time,limits=limits:Limits]|goto=Reviewed",
                           "transition:live|Reviewed|Close|implementation=hole|guard=|writes=|emits=ClosedEvent|outputs=ClosedEvent=generated-command-identity:Close[balance=balance:Integer]|goto=Closed"
                         ]
            diffServices service service `shouldBe` []
            resolvedFold (ReplayImpact.replayImpactServices service service) `shouldBe` ReplayNeutral
            manifest `shouldSatisfy` (not . T.isInfixOf "Generated.AggregateScalarExpressions.ScalarAccount.Expressions")
            map (.path) modules `shouldSatisfy` all (not . T.isSuffixOf "Expressions.hs" . T.pack)
            map (.path) modules `shouldSatisfy` any (T.isSuffixOf "Transducer.hs" . T.pack)
            transducer `shouldSatisfy` T.isInfixOf "let commandLimitsMinimum = K.inpProj"
            transducer `shouldSatisfy` T.isInfixOf "registerLimitsMinimum = K.regProj"
            readableTransducer `shouldSatisfy` T.isInfixOf "B.requireGuard $ (((((d.balance .+ B.reg @\"balance\" .>= K.lit (-100 :: Integer) .&& B.reg @\"reserved\" .+ d.requested .<= B.reg @\"capacity\") .&& d.observedAt .>= B.reg @\"openedAt\") .&& commandLimitsMinimum .>= registerLimitsMinimum) .&& d.active .== K.lit False) .&& commandMode .== registerMode) .&& commandRequestId .== registerRequestId"
            transducer `shouldSatisfy` T.isInfixOf "B.slot @\"balance\" =: (B.reg @\"balance\" .+ d.balance .* K.lit (2 :: Integer))"
            transducer `shouldSatisfy` T.isInfixOf "B.slot @\"reserved\" =: (B.reg @\"reserved\" .+ (d.requested .- B.reg @\"capacity\"))"
            transducer `shouldSatisfy` (not . T.isInfixOf "K.PAnd")
            transducer `shouldSatisfy` (not . T.isInfixOf "K.tadd")
            transducer `shouldSatisfy` T.isInfixOf "scalarAccountPredicateVerifications"
            transducer `shouldSatisfy` T.isInfixOf "S.verifyPredicate predicate"
            transducer `shouldSatisfy` T.isInfixOf "B.emit wireAdjusted (AdjustedTermFields"
            transducer `shouldSatisfy` T.isInfixOf "balance = d.balance"
            transducer `shouldSatisfy` (not . T.isInfixOf "transition1OpenAdjustOutput1Adjusted")
            holes `shouldSatisfy` (not . T.isInfixOf "transition1OpenAdjustOutput1Adjusted")
            holes `shouldSatisfy` (not . T.isInfixOf "transition2ReviewedCloseOutput1ClosedEvent")
            holes `shouldSatisfy` T.isInfixOf "transition2ReviewedCloseHoleFoldVersion"
            holes `shouldSatisfy` (not . T.isInfixOf "scalarAccountTransducer")
            firewallBreaches modules `shouldBe` []
          _ -> expectationFailure "expected one generated and one Hole scalar transition"
        _ -> expectationFailure "expected one scalar aggregate"

    it "pins every readable operator, equal-precedence child position, and bare Boolean guard" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context readable-renderer",
                "enum RenderStatus { Ready=ready Waiting=waiting }",
                "aggregate Renderer",
                "  regs",
                "    total Integer = 0",
                "    leftNested Integer = 0",
                "    product Integer = 1",
                "    status RenderStatus = Ready",
                "  states Open Closed!",
                "  command Evaluate { left:Integer right:Integer third:Integer status:RenderStatus }",
                "  event Evaluated = fields(Evaluate)",
                "  Open -- Evaluate -->",
                "    guard ((cmd.left < cmd.right || cmd.left <= cmd.right) || (cmd.left > cmd.right || cmd.left >= cmd.right))",
                "      && (cmd.left == cmd.right && cmd.left != cmd.third)",
                "      && cmd.status == RenderStatus.Waiting",
                "    write total := reg.total + (cmd.left - cmd.right)",
                "    write leftNested := (reg.leftNested + cmd.left) - cmd.right",
                "    write product := cmd.left * (cmd.right * cmd.third)",
                "    write status := RenderStatus.Ready",
                "    emit Evaluated",
                "    goto Closed",
                "aggregate BooleanRenderer",
                "  regs",
                "    enabled Bool = False",
                "  states Open Closed!",
                "  command Enable { enabled:Bool }",
                "  event Enabled = fields(Enable)",
                "  Open -- Enable -->",
                "    guard cmd.enabled",
                "    write enabled := cmd.enabled",
                "    emit Enabled",
                "    goto Closed"
              ]
      spec <- parseInlineSpec "<readable-renderer>" source
      errorCodes spec `shouldBe` []
      let modules = scaffoldModules (defaultContext (spec.context)) spec
          moduleAt suffix = case [(.text) value | value <- modules, T.pack suffix `T.isSuffixOf` T.pack ((.path) value)] of
            [value] -> pure value
            values -> expectationFailure ("expected one generated module ending in " <> suffix <> ", got " <> show (length values)) >> fail "unreachable"
      renderer <- moduleAt "/Renderer/Transducer.hs"
      booleanRenderer <- moduleAt "/BooleanRenderer/Transducer.hs"
      let normalizedRenderer = T.unwords (T.words renderer)
          normalizedBooleanRenderer = T.unwords (T.words booleanRenderer)
      renderer
        `shouldSatisfy` T.isInfixOf "import Keiki.Core (HsPred, SymTransducer, (.*), (.+), (.-), (.==), (./=), (.<), (.<=), (.>), (.>=), (.&&), (.||))"
      normalizedRenderer
        `shouldSatisfy` T.isInfixOf "(d.left .< d.right .|| d.left .<= d.right) .|| d.left .> d.right .|| d.left .>= d.right"
      normalizedRenderer
        `shouldSatisfy` T.isInfixOf ".&& d.left .== d.right .&& d.left ./= d.third"
      normalizedRenderer
        `shouldSatisfy` T.isInfixOf ".&& commandStatus .== K.lit (\"waiting\" :: Text)"
      renderer
        `shouldSatisfy` T.isInfixOf "B.slot @\"total\" =: (B.reg @\"total\" .+ (d.left .- d.right))"
      renderer
        `shouldSatisfy` T.isInfixOf "B.slot @\"leftNested\" =: (B.reg @\"leftNested\" .+ d.left .- d.right)"
      renderer
        `shouldSatisfy` T.isInfixOf "B.slot @\"product\" =: d.left .* (d.right .* d.third)"
      normalizedBooleanRenderer `shouldSatisfy` T.isInfixOf "B.requireGuard $ d.enabled .== K.lit True"
      firewallBreaches modules `shouldBe` []

    it "renders resolved command selectors in scalar and projected expressions" $ do
      source <- readTestText "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      let aliasedSource =
            T.replace "active:Bool" "active haskell commandActive:Bool"
              . T.replace "mode:AccountMode" "mode haskell commandMode:AccountMode"
              . T.replace "requestId:RequestId" "requestId haskell commandRequestId:RequestId"
              . T.replace "limits:Limits" "limits haskell commandLimits:Limits"
              $ source
      service <- checkedServiceFromText "aggregate-scalar-expression-aliases.keiro" aliasedSource
      let spec = checkedSpec service
          transducer = generatedTextEndingIn "Transducer.hs" (scaffoldServiceModules (defaultContext (spec.context)) service)
      validateService service `shouldBe` []
      transducer `shouldSatisfy` T.isInfixOf "d.commandActive"
      transducer `shouldSatisfy` T.isInfixOf "d.commandLimits"
      transducer `shouldSatisfy` T.isInfixOf "(#commandMode :: K.Index"
      transducer `shouldSatisfy` T.isInfixOf "(#commandRequestId :: K.Index"
      transducer `shouldSatisfy` T.isInfixOf "(#commandLimits :: K.Index"
      transducer `shouldSatisfy` (not . T.isInfixOf "d.active")
      transducer `shouldSatisfy` (not . T.isInfixOf "inCtorAdjust (#mode :: K.Index")
      transducer `shouldSatisfy` (not . T.isInfixOf "inCtorAdjust (#requestId :: K.Index")
      transducer `shouldSatisfy` (not . T.isInfixOf "inCtorAdjust (#limits :: K.Index")

    it "suffixes normalized projection-alias collisions deterministically" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context projection-alias-collision",
                "mapped structural record AliasCollision {",
                "  haskell package=keiro-dsl module=Renderer.Domain type=AliasCollision",
                "  binding = \"Renderer.Bindings.aliasCollisionBinding\"",
                "  binding-version = \"1\"",
                "  canonical-type = \"renderer.AliasCollision.v1\"",
                "  fixtures = \"Renderer.Bindings.aliasCollisionCases\"",
                "  initial = \"Renderer.Bindings.initialAliasCollision\"",
                "  wire object constructor=AliasCollision unknown-fields=reject {",
                "    dash as \"foo-bar\" : Integer required",
                "    underscore as \"foo_bar\" : Integer required",
                "  }",
                "}",
                "aggregate AliasRenderer",
                "  regs",
                "    values AliasCollision = initial",
                "  states Open Closed!",
                "  command Compare { values:AliasCollision }",
                "  event Compared = fields(Compare)",
                "  Open -- Compare -->",
                "    guard cmd.values.dash == reg.values.dash",
                "      && cmd.values.underscore == reg.values.underscore",
                "    emit Compared",
                "    goto Closed"
              ]
      spec <- parseInlineSpec "<projection-alias-collision>" source
      errorCodes spec `shouldBe` []
      let transducer = generatedTextEndingIn "Transducer.hs" (scaffoldModules (defaultContext (spec.context)) spec)
      transducer `shouldSatisfy` T.isInfixOf "let commandValuesFooBar = K.inpProj"
      transducer `shouldSatisfy` T.isInfixOf "registerValuesFooBar = K.regProj"
      transducer `shouldSatisfy` T.isInfixOf "commandValuesFooBar2 = K.inpProj"
      transducer `shouldSatisfy` T.isInfixOf "registerValuesFooBar2 = K.regProj"

    it "keeps evolution identity independent of module layout but sensitive to checked behavior" $ do
      source <- readTestText "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      original <- case parseSource "aggregate-scalar-expressions-v2.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      changed <- case parseSource "aggregate-scalar-expressions-changed.keiro" (T.replace "cmd.active == false" "cmd.active == true" source) of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      case ( [aggregate | NAggregate aggregate <- (.nodes) ((.spec) original)],
             [aggregate | NAggregate aggregate <- (.nodes) ((.spec) changed)]
           ) of
        ([originalAggregate], [changedAggregate]) -> do
          let service = checkedSource original
              changedService = checkedSource changed
              prefixed = defaultContext (original.spec.context)
              collocated = prefixed {moduleRoot = "Acme", placement = CollocatedLeaf}
              prefixedModules = scaffoldServiceModules prefixed service
              collocatedModules = scaffoldServiceModules collocated service
              originalSurface = aggregateFoldSurfaceForService service originalAggregate
              originalFingerprint = aggregateFoldFingerprintForService service originalAggregate
          map (.path) prefixedModules `shouldNotBe` map (.path) collocatedModules
          sum (map (T.length . (.text)) prefixedModules) `shouldSatisfy` (> 0)
          sum (map (T.length . (.text)) collocatedModules) `shouldSatisfy` (> 0)
          aggregateFoldSurfaceForService service originalAggregate `shouldBe` originalSurface
          aggregateFoldFingerprintForService service originalAggregate `shouldBe` originalFingerprint
          aggregateFoldSurfaceForService changedService changedAggregate `shouldNotBe` originalSurface
          aggregateFoldFingerprintForService changedService changedAggregate `shouldNotBe` originalFingerprint
        found -> expectationFailure ("expected one aggregate before and after behavior mutation, got " <> show (length (fst found), length (snd found)))

    it "rejects cross-command fields(Command) output before scaffolding" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context output-command-mismatch",
                "aggregate Account",
                "  regs",
                "  states Open Closed!",
                "  command OpenAccount { accountId:Text }",
                "  command CloseAccount { accountId:Text }",
                "  event AccountOpened = fields(OpenAccount)",
                "  Open -- CloseAccount --> emit AccountOpened ; goto Closed"
              ]
      spec <- parseInlineSpec "<output-command-mismatch>" source
      errorCodes spec `shouldContain` [EventOutputCommandMismatch]
      case [aggregate | NAggregate aggregate <- (.nodes) spec] of
        [aggregate] -> case (.transitions) aggregate of
          [transition] ->
            eventOutputMapping spec aggregate transition 1 "AccountOpened"
              `shouldBe` Left (OutputCommandMismatch "OpenAccount" "CloseAccount" "AccountOpened")
          _ -> expectationFailure "expected one transition"
        _ -> expectationFailure "expected one aggregate"

    it "rejects Int arithmetic and mixed numeric operands before scaffolding" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context scalar-errors",
                "aggregate Counter",
                "  regs",
                "    machine Int = 0",
                "    exact Integer = 0",
                "  states Open Closed!",
                "  command Add { machine:Int exact:Integer }",
                "  event Added = fields(Add)",
                "  Open -- Add -->",
                "    guard cmd.machine + 1 >= 0 && cmd.exact == cmd.machine",
                "    emit Added",
                "    goto Closed"
              ]
      spec <- parseInlineSpec "<scalar-errors>" source
      errorCodes spec `shouldContain` [AggregateExpressionOperatorUnsupported, AggregateExpressionOperandTypeMismatch]

    it "rejects nominal type confusion and unqualified enum values at source checking" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context nominal-type-confusion",
                "id OrderId prefix=ord",
                "id UserId prefix=usr",
                "enum OrderStatus { Draft=draft Submitted=submitted }",
                "enum UserStatus { Active=active Disabled=disabled }",
                "aggregate Account",
                "  regs",
                "    orderId OrderId = placeholder",
                "    status OrderStatus = Draft",
                "  states Open Closed!",
                "  command Compare { orderId:OrderId userId:UserId status:OrderStatus userStatus:UserStatus label:Text }",
                "  event Compared = fields(Compare)",
                "  Open -- Compare -->",
                "    guard cmd.orderId == cmd.userId",
                "      && cmd.status == cmd.userStatus",
                "      && cmd.orderId == cmd.label",
                "      && cmd.status == Draft",
                "    emit Compared",
                "    goto Closed"
              ]
      spec <- parseInlineSpec "<nominal-type-confusion>" source
      let diagnostics = validateSpec spec
      length [() | diagnostic <- diagnostics, (.code) diagnostic == AggregateExpressionOperandTypeMismatch]
        `shouldBe` 3
      errorCodes spec `shouldContain` [AggregateExpressionRootUnknown]
      T.unlines (map (.message) diagnostics) `shouldSatisfy` T.isInfixOf "qualify"

    it "rejects machine-Int arithmetic at both platform bounds" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context scalar-int-bounds",
                "aggregate Counter",
                "  regs",
                "    machine Int = 0",
                "  states Open Closed!",
                "  command Set { machine:Int }",
                "  event SetEvent = fields(Set)",
                "  Open -- Set -->",
                "    guard cmd.machine + 1 >= " <> T.pack (show (minBound :: Int)),
                "      && cmd.machine - 1 <= " <> T.pack (show (maxBound :: Int)),
                "    emit SetEvent",
                "    goto Closed"
              ]
      spec <- parseInlineSpec "<scalar-int-bounds>" source
      length [() | diagnostic <- validateSpec spec, (.code) diagnostic == AggregateExpressionOperatorUnsupported]
        `shouldBe` 2

    it "rejects predicate-valued Bool writes that Keiki cannot represent as scalar terms" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context scalar-bool-write",
                "aggregate Flag",
                "  regs",
                "    active Bool = False",
                "  states Open Closed!",
                "  command Set { active:Bool }",
                "  event SetEvent = fields(Set)",
                "  Open -- Set -->",
                "    write active := cmd.active == true",
                "    emit SetEvent",
                "    goto Closed"
              ]
      spec <- parseInlineSpec "<scalar-bool-write>" source
      errorCodes spec `shouldContain` [AggregateExpressionOperatorUnsupported]

    it "requires explicit roots for a same-named register and command field" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context scalar-ambiguity",
                "aggregate Counter",
                "  regs",
                "    amount Integer = 0",
                "  states Open Closed!",
                "  command Set { amount:Integer }",
                "  event SetEvent = fields(Set)",
                "  Open -- Set -->",
                "    guard amount == 0",
                "    emit SetEvent",
                "    goto Closed"
              ]
      spec <- parseInlineSpec "<scalar-ambiguity>" source
      errorCodes spec `shouldContain` [AggregateExpressionRootAmbiguous]

    it "enforces exclusive Hole ownership and preserves its canonical spelling" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context scalar-hole",
                "aggregate Counter",
                "  regs",
                "    amount Integer = 0",
                "  states Open Closed!",
                "  command Set { amount:Integer }",
                "  event SetEvent = fields(Set)",
                "  Open -- Set -->",
                "    implementation hole",
                "    guard cmd.amount >= 0",
                "    emit SetEvent",
                "    goto Closed"
              ]
      parsed <- case parseSource "<scalar-hole>" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      errorCodes ((.spec) parsed) `shouldContain` [AggregateTransitionOwnershipConflict]
      renderSource parsed `shouldSatisfy` T.isInfixOf "implementation hole"

    it "generates a stable per-transition Hole boundary and fold token" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context scalar-hole",
                "aggregate Counter",
                "  regs",
                "    amount Integer = 0",
                "  states Open Closed!",
                "  command Set { amount:Integer }",
                "  event SetEvent = fields(Set)",
                "  Open -- Set -->",
                "    implementation hole",
                "    emit SetEvent",
                "    goto Closed"
              ]
      spec <- parseInlineSpec "<scalar-hole-valid>" source
      aggregate <- case [value | NAggregate value <- (.nodes) spec] of
        [value] -> pure value
        _ -> expectationFailure "expected one Hole aggregate" >> fail "unreachable"
      let modules = scaffoldAggregate (defaultContext (spec.context)) spec aggregate
          transducer = generatedTextEndingIn "Transducer.hs" modules
          holes = holeTextEndingIn "Holes.hs" modules
      errorCodes spec `shouldBe` []
      map (.path) modules `shouldSatisfy` all (not . T.isSuffixOf "Expressions.hs" . T.pack)
      transducer `shouldSatisfy` T.isInfixOf "Holes.transition1OpenSetHole d"
      transducer `shouldSatisfy` T.isInfixOf "foldToken Holes.transition1OpenSetHoleFoldVersion"
      holes `shouldSatisfy` T.isInfixOf "transition1OpenSetHole _d = B.requireGuard K.PTop"
      holes `shouldSatisfy` T.isInfixOf "transition1OpenSetHoleFoldVersion = FoldVersion"
      holes `shouldSatisfy` (not . T.isInfixOf "counterTransducer")

    it "pins v1 and collection rejection at their stable boundaries" $ do
      v1Source <- readTestText "test/fixtures/aggregate-scalar-expressions-v1-rejects.keiro"
      case parseSource "v1.keiro" v1Source of
        Left (SourceLanguageFailure diagnostic) -> (.errorCode) diagnostic `shouldBe` LanguageFeatureRequiresVersion
        other -> expectationFailure ("expected v1 source-language refusal, got " <> show other)
      collectionSource <- readTestText "test/fixtures/aggregate-collection-expressions-v2-rejects.keiro"
      case parseSource "collections.keiro" collectionSource of
        Left failure -> renderParseFailure failure `shouldSatisfy` T.isInfixOf "CollectionExpressionUnsupported"
        Right _ -> expectationFailure "collection syntax unexpectedly parsed"

    it "keeps arithmetic operands intact when complementing a scalar comparison" $ do
      let left = EAdd noLoc (EPath noLoc CommandRoot ["balance"]) (ELiteral noLoc (LiteralIntegral 2))
          right = ESubtract noLoc (EPath noLoc RegisterRoot ["balance"]) (ELiteral noLoc (LiteralIntegral 3))
          predicate = ECmp OpLt left right
      complementExpr predicate `shouldBe` ECmp OpGe left right
      complementExpr (complementExpr predicate) `shouldBe` predicate

    it "keeps the committed scalar-expression conformance tree fresh" $ do
      modules <- scaffoldFixture "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      forM_ [generatedModule | generatedModule <- modules, (.kind) generatedModule == Generated] $ \generatedModule -> do
        committed <- readTestText ("test/conformance-scalar-expressions/" <> (.path) generatedModule)
        normalizeGenerated committed `shouldBe` normalizeGenerated ((.text) generatedModule)

  describe "behavior obligations" $ do
    it "joins every source-stable behavior origin to one exact source position" $ do
      source <- readTestText "test/fixtures/behavior-complete.keiro"
      document <- case parseSourceDocument "test/fixtures/behavior-complete.keiro" source of
        Left failure -> expectationFailure (show failure) >> fail "unreachable"
        Right value -> pure value
      let ParsedSourceDocument {parsedSource = parsedSource, sourceIndex = sourceIndex} = document
          spec = checkedSpec (checkedSource parsedSource)
      requirements <- either (\errors -> expectationFailure (show errors) >> fail "unreachable") pure (Behavior.deriveBehaviorRequirements spec)
      entries <- either (\errors -> expectationFailure (show errors) >> fail "unreachable") pure (BehaviorSource.planBehaviorSourceMap requirements sourceIndex)
      map (.key) entries `shouldBe` map (.key) requirements
      entries `shouldSatisfy` all ((== "test/fixtures/behavior-complete.keiro") . (.file))
      entries `shouldSatisfy` all ((>= 1) . (.line))
      entries `shouldSatisfy` all ((>= 1) . (.column))
      let exactJson =
            Behavior.encodeBehaviorObligationsJson
              (Behavior.BehaviorObligationsReport "test/fixtures/behavior-complete.keiro" Nothing (BehaviorSource.attachBehaviorSourceLocations entries requirements))
          exactText =
            Behavior.renderBehaviorObligationsText
              (Behavior.BehaviorObligationsReport "test/fixtures/behavior-complete.keiro" Nothing (BehaviorSource.attachBehaviorSourceLocations entries requirements))
      exactJson `shouldSatisfy` T.isInfixOf "\"quality\":\"exact\""
      exactJson `shouldSatisfy` T.isInfixOf "\"column\":"
      exactJson `shouldSatisfy` T.isInfixOf "\"file\":\"test/fixtures/behavior-complete.keiro\""
      exactText `shouldSatisfy` T.isInfixOf "test/fixtures/behavior-complete.keiro:"
      exactText `shouldSatisfy` T.isInfixOf "[location-quality=exact]"
      [(.origin) requirement | requirement <- requirements, (.kind) requirement == Behavior.RequiredRejection]
        `shouldSatisfy` all (\case Behavior.RejectionRequirementOrigin "Journey" _ -> True; _ -> False)

    it "refuses line-only, missing, and duplicate behavior source anchors before writes" $
      withTempDirectory "keiro-dsl-source-anchor-refusal" $ \out -> do
        baselineTree <- treeSnapshot out
        spec <- specOf "test/fixtures/behavior-complete.keiro"
        requirements <- either (\errors -> expectationFailure (show errors) >> fail "unreachable") pure (Behavior.deriveBehaviorRequirements spec)
        compatibility <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (compatibilitySemanticSourceIndex "behavior-complete.keiro" spec)
        let failureCodes result = case result of
              Left failures -> map (.code) failures
              Right _ -> []
        failureCodes (BehaviorSource.planBehaviorSourceMap requirements compatibility)
          `shouldSatisfy` all (== BehaviorSource.BehaviorSourceAnchorInexact)
        failureCodes (BehaviorSource.planBehaviorSourceMap requirements emptySemanticSourceIndex)
          `shouldSatisfy` all (== BehaviorSource.BehaviorSourceAnchorMissing)
        case BehaviorSource.planBehaviorSourceMap requirements emptySemanticSourceIndex of
          Left (failure : _) -> do
            let diagnostics = planningRefusalDiagnostics [BehaviorSourceRefusal [failure]]
            map (.code) diagnostics `shouldBe` [BehaviorSourceAnchorMissing]
            map (.message) diagnostics `shouldSatisfy` all (T.isInfixOf "behavior-v1-")
            map (.message) diagnostics `shouldSatisfy` all (T.isInfixOf "Journey:")
            map (.message) diagnostics `shouldSatisfy` all (T.isInfixOf "subject=Aggregate")
          result -> expectationFailure ("expected missing-anchor diagnostics, got " <> show result)
        case requirements of
          first : _ ->
            failureCodes (BehaviorSource.planBehaviorSourceMap (first : requirements) compatibility)
              `shouldContain` [BehaviorSource.BehaviorSourceAnchorCollision]
          [] -> expectationFailure "behavior fixture unexpectedly has no requirements"
        treeSnapshot out `shouldReturn` baselineTree

    it "plans one exact context source map and removes line-derived contract and witness bytes" $ do
      source <- readTestText "test/fixtures/behavior-complete.keiro"
      document <- case parseSourceDocument "test/fixtures/behavior-complete.keiro" source of
        Left failure -> expectationFailure (show failure) >> fail "unreachable"
        Right value -> pure value
      let ParsedSourceDocument {parsedSource = parsedSource, sourceIndex = sourceIndex} = document
          service = checkedSource parsedSource
          ctx = defaultContext ((checkedSpec service).context)
      modules <- either (\refusals -> expectationFailure (show refusals) >> fail "unreachable") pure (planIndexedServiceScaffold sourceIndex ctx service)
      let sourceMaps = [(.text) value | value <- modules, T.isSuffixOf "/BehaviorSourceMap.hs" (T.pack ((.path) value))]
          contracts = [(.text) value | value <- modules, T.isSuffixOf "/BehaviorContract.hs" (T.pack ((.path) value))]
          witnesses = [(.text) value | value <- modules, T.isSuffixOf "/BehaviorHoles.hs" (T.pack ((.path) value))]
      case sourceMaps of
        [sourceMapText] -> sourceMapText `shouldSatisfy` T.isInfixOf "test/fixtures/behavior-complete.keiro"
        values -> expectationFailure ("expected one behavior source map, got " <> show (length values))
      contracts `shouldSatisfy` all (T.isInfixOf ".BehaviorSourceMap qualified as BehaviorSourceMap")
      contracts `shouldSatisfy` all (not . T.isInfixOf "requirementLine")
      contracts `shouldSatisfy` all (not . T.isInfixOf "spec line")
      witnesses `shouldSatisfy` all (not . T.isInfixOf "spec line")
      compatibility <-
        either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure $
          compatibilitySemanticSourceIndex "<semantic-only>" (checkedSpec service)
      requirements <-
        either (\errors -> expectationFailure (show errors) >> fail "unreachable") pure $
          Behavior.deriveBehaviorRequirements (checkedSpec service)
      case BehaviorSource.planBehaviorSourceMap requirements compatibility of
        Left failures ->
          failures `shouldSatisfy` all ((== BehaviorSource.BehaviorSourceAnchorInexact) . (.code))
        Right _ -> expectationFailure "compatibility line-only provenance fabricated exact behavior columns"

    it "omits the context source map when no behavior contract can import it" $ do
      spec <- parseInlineSpec "<no-behavior>" "language keiro-dsl 4\ncontext no-behavior\n"
      modules <- either (\refusals -> expectationFailure (show refusals) >> fail "unreachable") pure (planTestScaffold (defaultContext "no-behavior") spec)
      map (.path) modules `shouldSatisfy` all (not . T.isSuffixOf "BehaviorSourceMap.hs" . T.pack)
      map (.path) modules `shouldSatisfy` all (not . T.isSuffixOf "BehaviorContract.hs" . T.pack)

    it "uses one source-wide layout and excludes replay-only initial edges from live harness probes" $ do
      spec <-
        parseInlineSpec "<transition-layout>" $
          T.unlines
            [ "language keiro-dsl 4",
              "context transition-layout",
              "aggregate Journey",
              "  regs",
              "  states Empty Active",
              "  command Start { current:Bool }",
              "  command Legacy { current:Bool }",
              "  event Started = fields(Start)",
              "  event LegacyStarted = fields(Legacy)",
              "  Empty -- Start --> guard cmd.current == true ; emit Started ; goto Active",
              "  Active -- Start --> emit Started ; goto Active",
              "  replay-only Empty -- Start --> guard cmd.current == false ; emit Started ; goto Active",
              "  Active -- Legacy --> emit LegacyStarted ; goto Active",
              "  replay-only Empty -- Legacy --> emit LegacyStarted ; goto Active"
            ]
      aggregate <- case [value | NAggregate value <- (.nodes) spec] of
        [value] -> pure value
        _ -> expectationFailure "expected one transition-layout aggregate" >> fail "unreachable"
      let ctx = defaultContext (spec.context)
          modules = scaffoldAggregate ctx spec aggregate <> harnessFor ctx spec aggregate
          transducer = generatedTextEndingIn "Transducer.hs" modules
          harness = generatedTextEndingIn "Harness.hs" modules
          contract = generatedTextEndingIn "BehaviorContract.hs" modules
      T.count "B.from JourneyEmpty do" transducer `shouldBe` 1
      transducer `shouldSatisfy` T.isInfixOf "transition3EmptyStart"
      transducer `shouldSatisfy` T.isInfixOf "transition5EmptyLegacy"
      T.count "acceptStart :: Bool" harness `shouldBe` 1
      harness `shouldSatisfy` (not . T.isInfixOf "acceptLegacy")
      contract `shouldSatisfy` T.isInfixOf "K.EdgeRef JourneyEmpty 1"
      contract `shouldSatisfy` T.isInfixOf "K.EdgeRef JourneyEmpty 2"

    it "refuses duplicate live initial harness helpers with both source locations" $ do
      spec <-
        parseInlineSpec "<initial-helper-collision>" $
          T.unlines
            [ "language keiro-dsl 4",
              "context helper-collision",
              "aggregate Journey",
              "  regs",
              "  states Empty Active",
              "  command Start { current:Bool }",
              "  event Started = fields(Start)",
              "  Empty -- Start --> guard cmd.current == true ; emit Started ; goto Active",
              "  Empty -- Start --> guard cmd.current == false ; emit Started ; goto Active"
            ]
      let collisions = [diagnostic | diagnostic <- validateSpec spec, (.code) diagnostic == GeneratedOccurrenceCollision]
      map (.line) collisions `shouldBe` [9, 9]
      collisions `shouldSatisfy` all (elem (8, "'Start' also normalizes here") . (.relatedLocations))

    it "inventories generated harness sample constants before rendering" $ do
      service <-
        checkedServiceFromText
          "<sample-helper-collision>"
          ( T.unlines
              [ "language keiro-dsl 4",
                "context helper-collision",
                "id ObservedAt prefix=obs",
                "aggregate Journey",
                "  regs",
                "  states Empty",
                "  command Start {",
                "    request:ObservedAt",
                "    observedAt:Time",
                "  }"
              ]
          )
      let collisions = [diagnostic | diagnostic <- validateService service, (.code) diagnostic == GeneratedOccurrenceCollision]
      map (.line) collisions `shouldBe` [9]
      collisions `shouldSatisfy` all (elem (3, "'ObservedAt' also normalizes here") . (.relatedLocations))

    it "inventories every live-reachable cell, guarded edge, terminal rejection, and replay edge" $ do
      spec <- specOf "test/fixtures/behavior-complete.keiro"
      requirements <- either (\errors -> expectationFailure (show errors) >> pure []) pure (Behavior.deriveBehaviorRequirements spec)
      length requirements `shouldBe` 19
      length [() | requirement <- requirements, (.kind) requirement == Behavior.LiveTransition] `shouldBe` 5
      length [() | requirement <- requirements, (.kind) requirement == Behavior.RequiredRejection] `shouldBe` 11
      length [() | requirement <- requirements, (.kind) requirement == Behavior.ReplayTransition] `shouldBe` 3
      [(.source) requirement | requirement <- requirements, (.kind) requirement == Behavior.RequiredRejection]
        `shouldContain` ["Active", "Closed"]
      length [() | requirement <- requirements, (.guardCoverage) requirement == Behavior.GuardTotal] `shouldBe` 3
      length [() | requirement <- requirements, (.guardCoverage) requirement == Behavior.GuardUnknown] `shouldBe` 2
      let report = Behavior.BehaviorObligationsReport "behavior-complete.keiro" Nothing requirements
          encoded = Behavior.encodeBehaviorObligationsJson report
          rendered = Behavior.renderBehaviorObligationsText report
      encoded `shouldSatisfy` T.isInfixOf "\"schema\":\"keiro-dsl/behavior-obligations/1\""
      encoded `shouldSatisfy` T.isInfixOf "\"source\":\"Closed\""
      encoded `shouldSatisfy` T.isInfixOf "\"kind\":\"replay-transition\""
      encoded `shouldSatisfy` T.isInfixOf "\"quality\":\"line-only\""
      rendered `shouldSatisfy` T.isInfixOf "[location-quality=line-only]"
      encoded `shouldSatisfy` (not . T.isInfixOf "\"filled\"")
      encoded `shouldSatisfy` (not . T.isInfixOf "\"missing\"")

    it "keeps semantic keys stable across line movement and canonical pretty printing" $ do
      source <- readTestText "test/fixtures/behavior-complete.keiro"
      parsed <- case parseSource "behavior-complete.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let original = (.spec) parsed
      moved <- parseInlineSpec "behavior-complete-moved.keiro" ("# line movement must not rename witnesses\n\n" <> source)
      pretty <- parseInlineSpec "behavior-complete-pretty.keiro" (renderSource parsed)
      let keys spec = fmap (map (.key)) (Behavior.deriveBehaviorRequirements spec)
      keys moved `shouldBe` keys original
      keys pretty `shouldBe` keys original

    it "generates direct fields(Command) output and separate create-once pending witnesses" $ do
      service <- checkedServiceOf "test/fixtures/behavior-complete.keiro"
      let spec = checkedSpec service
      aggregate <- case [value | NAggregate value <- (.nodes) spec] of
        [value] -> pure value
        _ -> expectationFailure "expected one behavior-complete aggregate" >> fail "unreachable"
      let ctx = defaultContext (spec.context)
          modules = scaffoldAggregate ctx spec aggregate
          harness = generatedTextEndingIn "Harness.hs" (harnessForService ctx service aggregate)
          transducer = generatedTextEndingIn "Transducer.hs" modules
          codec = generatedTextEndingIn "Codec.hs" modules
          contract = generatedTextEndingIn "BehaviorContract.hs" modules
          projection = generatedTextEndingIn "Projection.hs" modules
          behaviorHoles = case [(.text) value | value <- modules, T.isSuffixOf "BehaviorHoles.hs" (T.pack ((.path) value))] of
            [value] -> value
            values -> error ("expected one BehaviorHoles module, got " <> show (length values))
          ordinaryHoles = [value | value <- modules, T.isSuffixOf "/Holes.hs" (T.pack ((.path) value)), not (T.isSuffixOf "BehaviorHoles.hs" (T.pack ((.path) value)))]
      transducer `shouldSatisfy` T.isInfixOf "requestId = d.requestId"
      transducer `shouldSatisfy` T.isInfixOf "observedAt = d.observedAt"
      transducer `shouldSatisfy` T.isInfixOf "amount = d.amount"
      transducer `shouldSatisfy` T.isInfixOf "details = d.details"
      codec `shouldSatisfy` T.isInfixOf "display_label"
      codec `shouldSatisfy` T.isInfixOf "optional_note"
      transducer `shouldSatisfy` (not . T.isInfixOf "Output")
      ordinaryHoles `shouldBe` []
      obsoleteGeneratedOutputHooks spec `shouldContain` [("Journey", "transition1EmptyStartOutput1Started")]
      T.count "B.from JourneyEmpty do" transducer `shouldBe` 1
      transducer `shouldSatisfy` T.isInfixOf "verifyTransition \"transition3EmptyStart\" GeneratedOwned JourneyEmpty 1"
      transducer `shouldSatisfy` T.isInfixOf "verifyTransition \"transition5EmptyLegacyStart\" GeneratedOwned JourneyEmpty 2"
      T.count "acceptStart :: Bool" harness `shouldBe` 1
      harness `shouldSatisfy` (not . T.isInfixOf "acceptLegacyStart")
      contract `shouldSatisfy` T.isInfixOf "keiro/behavior-conformance/1"
      contract `shouldSatisfy` T.isInfixOf "commandKind command == requirement.requirementCommandName"
      contract `shouldSatisfy` (not . T.isInfixOf "OPTIONS_GHC")
      contract `shouldSatisfy` T.isInfixOf "module Generated.BehaviorComplete.Journey.BehaviorContract\n  ( BehaviorKey (..)"
      contract `shouldSatisfy` T.isInfixOf "runRejection :: BehaviorRequirement"
      contract `shouldSatisfy` T.isInfixOf "failureSubject :: !Text"
      contract `shouldSatisfy` T.isInfixOf "\"subject\" .= behaviorFailure.failureSubject"
      contract `shouldSatisfy` T.isInfixOf "-- JourneyEmpty x Start: live transition"
      contract `shouldSatisfy` (not . T.isInfixOf "spec line")
      contract `shouldSatisfy` T.isInfixOf "requirementKey = BehaviorKey \"behavior-v1-"
      contract `shouldSatisfy` T.isInfixOf "requirementCommandName = \"Start\""
      contract `shouldSatisfy` T.isInfixOf "requirementExpectedEdge = (Just (K.EdgeRef JourneyEmpty 1))"
      contract `shouldSatisfy` T.isInfixOf "requirementCommandName = \"LegacyStart\""
      contract `shouldSatisfy` T.isInfixOf "requirementExpectedEdge = (Just (K.EdgeRef JourneyEmpty 2))"
      contract `shouldSatisfy` T.isInfixOf "runtime event values differ from the exact witness expectation; actual="
      T.count "Pending (BehaviorKey " behaviorHoles `shouldBe` 19
      behaviorHoles `shouldSatisfy` T.isInfixOf "-- JourneyEmpty x Start: live transition"
      behaviorHoles `shouldSatisfy` (not . T.isInfixOf "spec line")
      behaviorHoles `shouldSatisfy` (not . T.isInfixOf "undefined")
      behaviorHoles `shouldSatisfy` (not . T.isInfixOf "error")
      T.count "sampleRequestId :: RequestId" harness `shouldBe` 1
      T.count "sampleObservedAt :: UTCTime" harness `shouldBe` 1
      harness `shouldSatisfy` T.isInfixOf "Left problem -> error (show problem)"
      harness `shouldSatisfy` T.isInfixOf "sampleEventStarted = Started (StartedData sampleRequestId sampleObservedAt"
      harness `shouldSatisfy` T.isInfixOf "case step journeyTransducer (JourneyEmpty, initialJourneyRegs) (Start (StartData"
      harness `shouldSatisfy` T.isInfixOf "-- clock-free: spec samples no wall clock (verified at scaffold time)"
      harness `shouldSatisfy` (not . T.isInfixOf "(\"clock-free: spec samples no wall clock\", True)")
      codec `shouldSatisfy` T.isInfixOf "parseOptionalField (pure Nothing) (\\value -> case value of Null -> pure Nothing; other -> Just <$> parseJSON other) objectValue \"optional_note\""
      T.count "parseOptionalField ::" codec `shouldBe` 1
      projection `shouldSatisfy` T.isInfixOf "-- No projection declarations are present; this module keeps the generated manifest inventory total."

    it "rejects eventless state or register changes while accepting a true no-op" $ do
      invalid <-
        parseInlineSpec "<eventless-change>" $
          T.unlines
            [ "language keiro-dsl 2",
              "context eventless-change",
              "aggregate Counter",
              "  regs",
              "    count Natural = 0",
              "  states Open Closed!",
              "  command Tick { count:Natural }",
              "  Open -- Tick --> write count := cmd.count ; goto Closed"
            ]
      errorCodes invalid `shouldContain` [AggregateEventlessStateChange]
      valid <-
        parseInlineSpec "<eventless-noop>" $
          T.unlines
            [ "language keiro-dsl 2",
              "context eventless-noop",
              "aggregate Counter",
              "  regs",
              "    count Natural = 0",
              "  states Open",
              "  command Tick { count:Natural }",
              "  event Ticked = fields(Tick)",
              "  Open -- Tick --> goto Open"
            ]
      errorCodes valid `shouldBe` []

    it "refuses duplicate semantic behavior identities before scaffolding" $ do
      duplicate <-
        parseInlineSpec "<duplicate-behavior>" $
          T.unlines
            [ "language keiro-dsl 2",
              "context duplicate-behavior",
              "aggregate Counter",
              "  regs",
              "  states Open",
              "  command Tick { amount:Natural }",
              "  event Ticked = fields(Tick)",
              "  Open -- Tick --> emit Ticked ; goto Open",
              "  Open -- Tick --> emit Ticked ; goto Open"
            ]
      let isBehaviorRefusal (BehaviorRefusal _) = True
          isBehaviorRefusal _ = False
      case planTestScaffold (defaultContext (duplicate.context)) duplicate of
        Left refusals -> refusals `shouldSatisfy` any isBehaviorRefusal
        Right _ -> expectationFailure "duplicate behavior identity reached a scaffold write set"

    it "round-trips additive single-file and workspace behavior rows with member ownership" $ do
      spec <- specOf "test/fixtures/behavior-complete.keiro"
      requirements <- either (\errors -> expectationFailure (show errors) >> pure []) pure (Behavior.deriveBehaviorRequirements spec)
      version <- maybe (expectationFailure "language version 2 was not constructible" >> fail "unreachable") pure (languageVersion 2)
      let rows = Behavior.behaviorRecordRows requirements
          singleRecord =
            ScaffoldRecord
              { specPath = "behavior-complete.keiro",
                moduleRoot = "",
                layout = "prefixed",
                sourceLanguage = DeclaredLanguage version noLoc,
                languageContract = effectiveLanguageContract (DeclaredLanguage version noLoc),
                namingEdition = IdiomaticNamingV1,
                moduleRoles = [],
                files = [],
                mappings = [],
                idDomains = [],
                nominalEqualities = [],
                bindingObligations = [],
                behaviorRequirements = rows,
                projectionCatalogFacts = [],
                queryContractBaseline = True,
                queryContracts = [],
                routerSelections = [],
                semanticImpact = Nothing
              }
      T.count "behavior " (renderRecord singleRecord) `shouldBe` 19
      parseRecord (renderRecord singleRecord) `shouldBe` Just singleRecord

      workspace <- shouldComposeWorkspace "test/fixtures/behavior-complete-workspace/service.keiro-workspace"
      workspaceRequirements <- either (\errors -> expectationFailure (show errors) >> pure []) pure (Behavior.deriveBehaviorRequirements ((.mergedSpec) workspace))
      let ownedRequirements =
            map
              (Behavior.attributeBehaviorOwner (fmap fst . nodeOwner ((.ownership) workspace) "aggregate"))
              workspaceRequirements
          ownedRows = Behavior.behaviorRecordRows ownedRequirements
          workspaceRecord =
            WorkspaceRecord
              { service = (.service) workspace,
                manifest = "service.keiro-workspace",
                context = workspace.context,
                moduleRoot = "",
                layout = "prefixed",
                members = map (.path) ((.members) workspace),
                sourceLanguages = [WorkspaceSourceLanguageRow ((.path) member) ((.sourceLanguage) member) | member <- (.members) workspace],
                languageContract = (.languageContract) workspace,
                namingEdition = IdiomaticNamingV1,
                modules = [],
                mappings = [],
                idDomains = [],
                nominalEqualities = [],
                bindingObligations = [],
                requirements = ownedRows,
                projectionCatalogFacts = [],
                queryContractBaseline = True,
                queryContracts = [],
                routerSelections = [],
                adopted = [],
                semanticImpact = Nothing
              }
      map (.owner) ownedRows `shouldSatisfy` all (== Just "journey.keiro")
      T.count "behavior " (renderWorkspaceRecord workspaceRecord) `shouldBe` 19
      parseWorkspaceRecord (renderWorkspaceRecord workspaceRecord) `shouldBe` Just workspaceRecord

    it "keeps the initial replay fixture byte-identical across single, workspace, and repeat scaffolds" $ do
      withTempDirectory "keiro-dsl-initial-replay-layout" $ \base -> do
        let singleOut = base </> "single"
            workspaceOut = base </> "workspace"
            singleSource = "test/fixtures/behavior-complete.keiro"
            workspaceSource = "test/fixtures/behavior-complete-workspace/service.keiro-workspace"
            journeyModules = filter (T.isPrefixOf "Generated/BehaviorComplete/Journey/" . T.pack . fst)
            behaviorContractPath = "Generated/BehaviorComplete/Journey/BehaviorContract.hs"
            withoutBehaviorContract = filter ((/= behaviorContractPath) . fst)
            present = maybe False (const True)
            normalizeRequirementLines =
              T.unlines
                . map
                  ( \sourceLine ->
                      if "requirementLine =" `T.isInfixOf` sourceLine
                        then fst (T.breakOn "=" sourceLine) <> "= <source-line>"
                        else case T.breakOn "(spec line " sourceLine of
                          (prefix, suffix)
                            | T.null suffix -> sourceLine
                            | otherwise -> prefix <> "(spec line <source-line>)"
                  )
                . T.lines
        (singleCode, singleStdout, singleStderr) <- runKeiroDsl ["scaffold", singleSource, "--out", singleOut]
        unless (singleCode == ExitSuccess) (expectationFailure (singleStdout <> singleStderr))
        singleTree <- treeSnapshot singleOut
        (singleRepeatCode, singleRepeatStdout, singleRepeatStderr) <- runKeiroDsl ["scaffold", singleSource, "--out", singleOut]
        unless (singleRepeatCode == ExitSuccess) (expectationFailure (singleRepeatStdout <> singleRepeatStderr))
        treeSnapshot singleOut `shouldReturn` singleTree
        (workspaceCode, workspaceStdout, workspaceStderr) <- runKeiroDsl ["scaffold", workspaceSource, "--out", workspaceOut]
        unless (workspaceCode == ExitSuccess) (expectationFailure (workspaceStdout <> workspaceStderr))
        workspaceTree <- treeSnapshot workspaceOut
        let singleJourney = journeyModules singleTree
            workspaceJourney = journeyModules workspaceTree
        withoutBehaviorContract workspaceJourney `shouldBe` withoutBehaviorContract singleJourney
        case (lookup behaviorContractPath workspaceJourney, lookup behaviorContractPath singleJourney) of
          (Just workspaceContract, Just singleContract) ->
            normalizeRequirementLines workspaceContract `shouldBe` normalizeRequirementLines singleContract
          (workspaceContract, singleContract) ->
            expectationFailure
              ( "expected both generated behavior contracts, got "
                  <> show (present workspaceContract, present singleContract)
              )
        (workspaceRepeatCode, workspaceRepeatStdout, workspaceRepeatStderr) <- runKeiroDsl ["scaffold", workspaceSource, "--out", workspaceOut]
        unless (workspaceRepeatCode == ExitSuccess) (expectationFailure (workspaceRepeatStdout <> workspaceRepeatStderr))
        treeSnapshot workspaceOut `shouldReturn` workspaceTree

  describe "nominal consumer types" $ do
    it "resolves every category through one checked registry and explains exact obligations" $ do
      spec <- specOf "test/fixtures/nominal-scalars.keiro"
      errorCodes spec `shouldBe` []
      registry <- case resolveNominalTypes spec of
        Left errors -> expectationFailure (show errors) >> fail "unreachable"
        Right value -> pure value
      Map.keys ((.nominalTypes) registry)
        `shouldBe` ["AccountNumber", "FeatureFlag", "ObservedAt", "OrderId", "OrderStatus", "RiskScore", "SequenceNumber"]
      obligations <- either (\errors -> expectationFailure (show errors) >> pure []) pure (bindingObligations spec)
      length obligations `shouldBe` 21
      map (.category) obligations `shouldSatisfy` all (`elem` ["nominal-id", "nominal-enum", "nominal-scalar"])
      length [() | obligation <- obligations, (.equalityContract) obligation /= Nothing] `shouldBe` 2
      renderBindingObligations (spec.context) obligations `shouldSatisfy` T.isInfixOf "equality-contract:"
      let signatures = map (.signature) obligations
      forM_
        [ "orderIdBinding :: NominalBinding NominalConformance.Domain.OrderId (KindID \"ord\")",
          "orderStatusBinding :: NominalBinding NominalConformance.Domain.OrderStatus Generated.NominalScalars.Nominal.Shape.OrderStatus.OrderStatusRepresentation",
          "accountNumberBinding :: NominalBinding NominalConformance.Domain.AccountNumber Text",
          "orderIdFixtures :: NominalFixtureCases NominalConformance.Domain.OrderId",
          "initialAccountNumber :: NominalConformance.Domain.AccountNumber"
        ]
        (`shouldSatisfy` (`elem` signatures))
      map (.canonicalType) obligations `shouldSatisfy` all (/= Nothing)
      let rendered = renderBindingObligations (spec.context) obligations
      rendered `shouldSatisfy` T.isInfixOf "nominal-id type OrderId"
      rendered `shouldSatisfy` T.isInfixOf "canonical-type: \"nominal.OrderId.v1\""
      case obligations of
        firstObligation : _ ->
          (Aeson.eitherDecode (Aeson.encode firstObligation) :: Either String BindingObligation)
            `shouldBe` Right firstObligation
        [] -> expectationFailure "expected nominal binding obligations"

    it "allocates distinct stable diagnostics for incomplete or incompatible nominal declarations" $ do
      missing <- errorCodesOf "test/fixtures/nominal-missing-facts.keiro"
      missing `shouldBe` replicate 5 NominalMissingIngredient
      errorCodesOf "test/fixtures/nominal-bad-qualified.keiro" `shouldReturn` [NominalInvalidQualifiedName]
      errorCodesOf "test/fixtures/nominal-invalid-prefix.keiro" `shouldReturn` replicate 2 NominalInvalidIdPrefix
      errorCodesOf "test/fixtures/nominal-unsupported-representation.keiro" `shouldReturn` [NominalUnsupportedRepresentation]
      errorCodesOf "test/fixtures/nominal-missing-initial.keiro" `shouldReturn` [NominalMissingInitialValue]
      errorCodesOf "test/fixtures/nominal-name-collision.keiro"
        `shouldReturn` [NominalNameCollision, GeneratedOccurrenceCollision, NominalNameCollision]

    it "keeps v1 rejection at the source-language boundary" $ do
      source <- readTestText "test/fixtures/nominal-v1.keiro"
      case parseSource "nominal-v1.keiro" source of
        Left (SourceLanguageFailure diagnostic) -> (.errorCode) diagnostic `shouldBe` LanguageFeatureRequiresVersion
        other -> expectationFailure ("expected source-language refusal, got " <> show other)

    it "scaffolds consumer types, checked codecs, enum representation, projections, and deterministic manifests" $ do
      spec <- specOf "test/fixtures/nominal-scalars.keiro"
      let ctx = defaultContext (spec.context)
          modules = scaffoldModules ctx spec
          moduleAt path = case [value | value <- modules, value.path == path] of
            [value] -> pure value
            values -> expectationFailure ("expected one module at " <> path <> ", got " <> show (map (.path) values)) >> fail "unreachable"
      domainModule <- moduleAt "Generated/NominalScalars/NominalLedger/Domain.hs"
      codecModule <- moduleAt "Generated/NominalScalars/NominalLedger/Codec.hs"
      enumModule <- moduleAt "Generated/NominalScalars/Nominal/Shape/OrderStatus.hs"
      projectionModule <- moduleAt "Generated/NominalScalars/NominalProjections.hs"
      bindingModule <- moduleAt "NominalConformance/Bindings.hs"
      map (.path) modules `shouldNotContain` ["NominalScalars/NominalLedger/Holes.hs"]
      (.text) domainModule `shouldSatisfy` T.isInfixOf "import NominalConformance.Domain (AccountNumber, FeatureFlag, ObservedAt, OrderId, OrderStatus, RiskScore, SequenceNumber)"
      (.text) domainModule `shouldSatisfy` T.isInfixOf "orderId :: !OrderId"
      (.text) domainModule `shouldSatisfy` (not . T.isInfixOf "NominalConformance.Domain.OrderId")
      (.text) domainModule `shouldSatisfy` (not . T.isInfixOf "newtype OrderId")
      (.text) domainModule `shouldSatisfy` (not . T.isInfixOf "data OrderStatus =")
      (.text) codecModule `shouldSatisfy` T.isInfixOf "KindID.parseText @\"ord\""
      (.text) codecModule `shouldSatisfy` T.isInfixOf "KindID.toText (nominalToRepresentation"
      (.text) codecModule `shouldSatisfy` T.isInfixOf "nominalFromRepresentation"
      forM_ ["coerce", "unsafe", "read ", "error "] $ \forbidden ->
        (.text) codecModule `shouldSatisfy` (not . T.isInfixOf forbidden)
      (.text) enumModule `shouldSatisfy` T.isInfixOf "data OrderStatusRepresentation = Draft | Submitted"
      (.text) enumModule `shouldSatisfy` (not . T.isInfixOf "NominalConformance")
      (.text) projectionModule `shouldSatisfy` T.isInfixOf "type FieldOwner AccountNumberNominalProjection = AccountNumber"
      (.text) projectionModule `shouldSatisfy` T.isInfixOf "projectFieldValue _ = nominalToRepresentation Bindings.accountNumberBinding"
      (.text) projectionModule `shouldSatisfy` T.isInfixOf "instance ExactFieldProjection OrderIdEqualityProjection"
      (.text) projectionModule `shouldSatisfy` T.isInfixOf "textProjectionDomain orderIdEqualityPattern"
      (.text) projectionModule `shouldSatisfy` T.isInfixOf "instance ExactFieldProjection OrderStatusEqualityProjection"
      (.text) projectionModule `shouldSatisfy` T.isInfixOf "finiteProjectionDomain (\"draft\" :| [\"submitted\"])"
      (.kind) bindingModule `shouldBe` HoleStub
      (.text) bindingModule `shouldSatisfy` T.isInfixOf "import NominalConformance.Domain (AccountNumber, FeatureFlag, ObservedAt, OrderId, OrderStatus, RiskScore, SequenceNumber)"
      (.text) bindingModule `shouldSatisfy` T.isInfixOf "orderIdBinding :: NominalBinding OrderId (KindID \"ord\")"
      (.text) bindingModule `shouldSatisfy` T.isInfixOf "orderStatusBinding :: NominalBinding OrderStatus ShapeOrderStatus.OrderStatusRepresentation"
      firewallBreaches modules `shouldBe` []
      scaffoldModules ctx spec `shouldBe` modules
      manifestDependencies spec `shouldContain` ["mmzk-typeid", "nominal-conformance"]

    it "persists nominal provenance in a separate forward-compatible row kind" $ do
      spec <- specOf "test/fixtures/nominal-scalars.keiro"
      workspace <- shouldComposeWorkspace canonicalWorkspacePath
      let plan = consumerPlan spec
          record =
            ScaffoldRecord
              { specPath = "nominal-scalars.keiro",
                moduleRoot = "",
                layout = "prefixed",
                sourceLanguage = LegacyUnversioned,
                languageContract = effectiveLanguageContract LegacyUnversioned,
                namingEdition = IdiomaticNamingV1,
                moduleRoles = [],
                files = [],
                mappings = (.mappings) plan,
                idDomains = [],
                nominalEqualities = nominalEqualityIdentities spec,
                bindingObligations = [],
                behaviorRequirements = [],
                projectionCatalogFacts = [],
                queryContractBaseline = True,
                queryContracts = [],
                routerSelections = [],
                semanticImpact = Nothing
              }
          encoded = renderRecord record
          workspaceRecord =
            (sampleWorkspaceRecord workspace)
              { WorkspaceRecord.mappings = plan.mappings
              }
          workspaceEncoded = renderWorkspaceRecord workspaceRecord
      (.packages) plan `shouldBe` ["nominal-conformance"]
      length [() | NominalMapping {} <- (.mappings) plan] `shouldBe` 7
      T.count "nominal-mapping " encoded `shouldBe` 7
      T.count "nominal-equality " encoded `shouldBe` 2
      T.count "\nmapping " encoded `shouldBe` 0
      parseRecord encoded `shouldBe` Just record
      T.count "nominal-mapping " workspaceEncoded `shouldBe` 7
      T.count "nominal-equality " workspaceEncoded `shouldSatisfy` (>= 2)
      T.count "\nmapping " workspaceEncoded `shouldBe` 0
      parseWorkspaceRecord workspaceEncoded `shouldBe` Just workspaceRecord

    it "reports bound-ID decoder tightening and makes binding provenance replay-visible" $ do
      current <- specOf "test/fixtures/nominal-scalars.keiro"
      let useGeneratedIdInitial (NAggregate aggregate) =
            NAggregate
              ( aggregateWithRegs
                  [ if register.name == "orderId"
                      then regDeclWithInitial (RegInitBare "placeholder") register
                      else register
                  | register <- aggregate.regs
                  ]
                  aggregate
              )
          useGeneratedIdInitial node = node
          unbound =
            specWithIdsAndNodes
              [idDeclWithBinding Nothing declaration | declaration <- current.ids]
              (map useGeneratedIdInitial current.nodes)
              current
          adoption = diffSpecs unbound current
          decoderFindings = [kindOfChange change | change <- adoption, changeCode change == NominalIdDecoderTightened]
      map (.subject) decoderFindings `shouldContain` ["NominalLedger event NominalsRecorded .orderId"]
      decoderFindings `shouldSatisfy` all ((== VAdvisory) . verdictFor PrivateHistoryRead . (.vector))
      let bumped =
            specWithIds
              [ idDeclWithBinding (fmap (nominalBindingWithVersion (Just "2")) declaration.binding) declaration
              | declaration <- current.ids
              ]
              current
          bindingChanges = diffSpecs current bumped
      map changeCode bindingChanges `shouldContain` [NominalBindingChanged]
      replayImpactSpecs current bumped `shouldSatisfy` \case
        ReplayImpact.ReplayAffected impacts ->
          maybe False (\impact -> Set.member "NominalsRecorded" ((.eventTypes) impact) && (.includeSnapshotStreams) impact) (Map.lookup "NominalLedger" impacts)
        ReplayImpact.ReplayNeutral -> False
      case [aggregate | NAggregate aggregate <- (.nodes) current] of
        aggregate : _ -> do
          aggregateFoldSurface current aggregate `shouldSatisfy` T.isInfixOf "nominal-equality-use:"
          aggregateFoldSurface current aggregate `shouldNotBe` aggregateFoldSurface bumped aggregate
        [] -> expectationFailure "expected nominal aggregate"

  describe "historical codec comparison" $ do
    it "treats object-key order as RFC 8785 parity" $ do
      let historical = object ["z" .= (1 :: Int), "a" .= (2 :: Int)]
          generated = object ["a" .= (2 :: Int), "z" .= (1 :: Int)]
      classifyObservation (EncodeObservation "ordered-object" historical generated)
        `shouldBe` Right JsonParity
    it "classifies an omitted key versus explicit null as version work at that pointer" $ do
      let historical = object []
          generated = object ["description" .= Aeson.Null]
      classifyObservation (EncodeObservation "absent-description" historical generated)
        `shouldBe` Right (RequiresVersionWork (EncodedValueDifference (JsonPointer "/description") historical generated))
    it "classifies generated rejection of a historical value as version work" $
      classifyObservation
        ( DecodeObservation
            "legacy.json"
            (object ["tag" .= ("legacy" :: T.Text)])
            (DecodedShape (object ["tag" .= ("legacy" :: T.Text)]))
            (DecodeFailed "unknown tag")
        )
        `shouldBe` Right (RequiresVersionWork (GeneratedDecodeRejected "unknown tag"))
    it "treats historical-codec rejection as invalid input rather than parity" $
      classifyObservation
        ( DecodeObservation
            "corrupt.json"
            Aeson.Null
            (DecodeFailed "not historical data")
            (DecodeFailed "not generated data")
        )
        `shouldBe` Left (HistoricalCodecRejected "corrupt.json" "not historical data")
    it "reports uncovered union arms separately by corpus origin" $ do
      let canonical = DeclaredBranch HistoricalGolden (JsonPointer "/location") (UnionArm "canonical")
          local = DeclaredBranch HistoricalGolden (JsonPointer "/location") (UnionArm "local_file")
          report = compareReport comparisonProvenance [] [] [canonical, local] [ObservedBranch HistoricalGolden (JsonPointer "/location") (UnionArm "local_file")]
      (.coverageGaps) report
        `shouldBe` [CoverageGap HistoricalGolden (JsonPointer "/location") (UnionArm "canonical")]
      reportSucceeded report `shouldBe` False
    it "derives optional, null, and union-arm observations from a generated branch schema" $ do
      let schema =
            BranchRecord
              [ BranchField "description" True (BranchOptional BranchScalar),
                BranchField "location" False (BranchUnion "tag" "contents" [BranchArm "local" (Just BranchScalar), BranchArm "canonical" Nothing])
              ]
          historical = object ["location" .= object ["tag" .= ("canonical" :: T.Text)]]
      observedBranchesFor HistoricalGolden schema historical
        `shouldBe` [ ObservedBranch HistoricalGolden (JsonPointer "/description") OptionalMissing,
                     ObservedBranch HistoricalGolden (JsonPointer "/location") (UnionArm "canonical")
                   ]
      let declared = declaredBranchesFor HistoricalGolden schema
      forM_
        [ DeclaredBranch HistoricalGolden (JsonPointer "/description") OptionalMissing,
          DeclaredBranch HistoricalGolden (JsonPointer "/description") OptionalPresent,
          DeclaredBranch HistoricalGolden (JsonPointer "/description") ExplicitNull,
          DeclaredBranch HistoricalGolden (JsonPointer "/location") (UnionArm "local"),
          DeclaredBranch HistoricalGolden (JsonPointer "/location") (UnionArm "canonical")
        ]
        (\branch -> declared `shouldContain` [branch])
    it "round-trips the stable machine report" $ do
      let observation = EncodeObservation "parity" (object ["a" .= (1 :: Int)]) (object ["a" .= (1 :: Int)])
          report = compareReport comparisonProvenance [] [observation] [] []
      Aeson.eitherDecode (Aeson.encode report) `shouldBe` Right report
    it "atomically writes and replaces the machine report" $
      withTempDirectory "keiro-dsl-codec-compare" $ \out -> do
        let path = out </> "report.json"
            firstReport = compareReport comparisonProvenance [] [] [] []
            secondReport = compareReport comparisonProvenance [HistoricalGoldenUnreadable "bad.json" "bad JSON"] [] [] []
        writeCompareReportAtomic path firstReport `shouldReturn` Right ()
        Aeson.eitherDecodeFileStrict path `shouldReturn` Right firstReport
        writeCompareReportAtomic path secondReport `shouldReturn` Right ()
        Aeson.eitherDecodeFileStrict path `shouldReturn` Right secondReport

  describe "historical codec comparison scaffold" $ do
    it "emits an opt-in non-production runner without entering the ordinary module registry" $ do
      spec <- specOf "test/fixtures/structural-conformance.keiro"
      let ctx = defaultContext (spec.context)
          planned = codecComparisonModule ctx spec "ArtifactInfo"
          ordinary = scaffoldModules ctx spec
      case planned of
        Left err -> expectationFailure (T.unpack err)
        Right comparisonModule -> do
          (.path) comparisonModule
            `shouldBe` "Generated/StructuralConformance/Structural/CodecCompare/ArtifactInfo.hs"
          (.text) comparisonModule `shouldSatisfy` T.isInfixOf codecComparisonBanner
          (.text) comparisonModule `shouldSatisfy` T.isInfixOf "Generated.StructuralConformance.ArtifactCatalog.Codec qualified as GeneratedCodec"
          (.text) comparisonModule `shouldSatisfy` T.isInfixOf "branchSchema = BranchRecord"
          map (.path) ordinary `shouldNotContain` [(.path) comparisonModule]
    it "refuses opaque selections rather than upgrading their claim" $ do
      spec <- specOf "test/fixtures/structural-conformance.keiro"
      codecComparisonModule (defaultContext (spec.context)) spec "VendorGeometry"
        `shouldSatisfy` either (T.isInfixOf "is opaque") (const False)

  describe "structural/opaque coverage reporting" $ do
    it "reports mapped private-event roots and consumer-json register boundaries without a percentage" $ do
      spec <- specOf "test/fixtures/structural-conformance.keiro"
      report <- shouldResolveCoverage "structural-conformance.keiro" spec
      (.privateEventPayloads) ((.summary) report)
        `shouldBe` Coverage.CoverageCounts 2 1 1 0
      (.snapshotRegisters) ((.summary) report)
        `shouldBe` Coverage.CoverageCounts 2 1 1 0
      map (.mappedType) ((.opaqueBoundaries) report)
        `shouldBe` ["VendorGeometry"]
      map (.encoding) ((.snapshotBoundaries) report)
        `shouldBe` ["consumer-json-cache", "consumer-json-cache"]
      map (.invalidation) ((.snapshotBoundaries) report)
        `shouldBe` ["tracked-by-mapped-wire-fingerprint", "tracked-by-mapped-wire-fingerprint"]
      map (.code) ((.findings) report)
        `shouldBe` [CoverageOpaqueSurface]
      map (.severity) ((.findings) report)
        `shouldBe` [Warning]
      case Aeson.toJSON report of
        Aeson.Object values ->
          forM_ ["spec", "roots", "opaqueBoundaries", "snapshotBoundaries", "unsupportedSurfaces"] $
            \key -> KeyMap.member key values `shouldBe` True
        value -> expectationFailure ("coverage report was not an object: " <> show value)
    it "reports queue structural and Json boundaries as a separate persisted surface" $ do
      source <- mappedConsumerSurfaceSource
      spec <- parseInlineSpec "<mapped-queue-coverage>" source
      report <- shouldResolveCoverage "mapped-queue.keiro" spec
      (.workqueuePayloads) ((.summary) report)
        `shouldBe` Coverage.CoverageCounts 1 1 0 1
      map (.path) [root | root <- (.roots) report, (.surface) root == Coverage.WorkqueuePayload]
        `shouldBe` ["workqueue ArtifactJobs payload .jobData : ArtifactInfo [] optional"]
      map (.path) [boundary | boundary <- (.jsonBoundaries) report, (.surface) boundary == Coverage.WorkqueuePayload]
        `shouldContain` ["workqueue ArtifactJobs payload .jobData : ArtifactInfo [] optional .extra"]
      map (.surface) ((.unsupportedSurfaces) report)
        `shouldNotContain` ["queue-payloads"]
    it "reports a built-in-only queue Json expression without fabricating a mapped declaration" $ do
      source <- mappedConsumerSurfaceSource
      spec <-
        parseInlineSpec
          "<explicit-queue-json-coverage>"
          (T.replace "jobData -> \"payload\" : List (Optional ArtifactInfo)" "jobData -> \"payload\" : Optional Json" source)
      report <- shouldResolveCoverage "explicit-queue-json.keiro" spec
      (.workqueuePayloads) ((.summary) report)
        `shouldBe` Coverage.CoverageCounts 0 0 0 1
      map (.path) [boundary | boundary <- (.jsonBoundaries) report, (.surface) boundary == Coverage.WorkqueuePayload]
        `shouldBe` ["workqueue ArtifactJobs payload .jobData optional"]
    it "reports explicit Json leaves by their complete persisted path" $ do
      spec <- withMetadataJson <$> specOf "test/fixtures/structural-conformance.keiro"
      report <- shouldResolveCoverage "structural-conformance-json.keiro" spec
      (.jsonBoundaries) ((.privateEventPayloads) ((.summary) report))
        `shouldBe` 1
      map (.path) ((.jsonBoundaries) report)
        `shouldBe` ["ArtifactCatalog event ArtifactRecorded .artifact : ArtifactInfo .metadata : ArtifactMetadata .note"]
    it "keeps a zero-opaque spec advisory-free and makes rejection explicitly opt-in" $ do
      original <- specOf "test/fixtures/structural-conformance.keiro"
      clear <- shouldResolveCoverage "structural-only.keiro" (withoutVendorGeometry original)
      (.opaqueRoots) ((.privateEventPayloads) ((.summary) clear)) `shouldBe` 0
      (.opaqueBoundaries) clear `shouldBe` []
      (.findings) clear `shouldBe` []
      opaque <- shouldResolveCoverage "structural-conformance.keiro" original
      Coverage.coverageSucceeded opaque `shouldBe` True
      let gated = Coverage.failOnOpaque opaque
      Coverage.coverageSucceeded gated `shouldBe` False
      map (.code) ((.findings) gated)
        `shouldBe` [CoverageOpaqueSurface, CoverageOpaqueGateExceeded]
      map (.severity) ((.findings) gated)
        `shouldBe` [Warning, Error]
    it "diffs named opaque boundaries and fails only an explicitly gated increase" $ do
      newSpec <- specOf "test/fixtures/structural-conformance.keiro"
      report <- case Coverage.coverageDiffReport "structural-conformance.keiro" "HEAD" (withoutVendorGeometry newSpec) newSpec of
        Left err -> expectationFailure (show err) >> fail "unreachable"
        Right value -> pure value
      fmap (.opaqueBoundaryDelta) ((.delta) report) `shouldBe` Just 1
      fmap (map (.mappedType) . (.addedOpaqueBoundaries)) ((.delta) report)
        `shouldBe` Just ["VendorGeometry"]
      map (.code) ((.findings) report)
        `shouldBe` [CoverageOpaqueSurface, CoverageOpaqueBoundaryAdded]
      Coverage.coverageSucceeded report `shouldBe` True
      let gated = Coverage.failOnOpaqueIncrease report
      Coverage.coverageSucceeded gated `shouldBe` False
      map (.code) ((.findings) gated)
        `shouldBe` [CoverageOpaqueSurface, CoverageOpaqueBoundaryAdded, CoverageOpaqueGateExceeded]
    it "appends the six stable coverage and comparison registry codes" $
      map
        show
        [ CoverageOpaqueSurface,
          CoverageOpaqueBoundaryAdded,
          CoverageOpaqueGateExceeded,
          CodecCompareDifference,
          CodecCompareCoverageGap,
          CodecCompareInvalidInput
        ]
        `shouldBe` [ "CoverageOpaqueSurface",
                     "CoverageOpaqueBoundaryAdded",
                     "CoverageOpaqueGateExceeded",
                     "CodecCompareDifference",
                     "CodecCompareCoverageGap",
                     "CodecCompareInvalidInput"
                   ]

  describe "parse . pretty round-trip" $
    do
      it "re-parses any generated spec to an equal AST (modulo source locations)" $
        checkCoverage $
          forAll genSpec $ \s ->
            let families = map nodeTag ((.nodes) s)
                roundTrip = parseSpec "<gen>" (renderSpec s) === Right s
             in cover 5 (not (null ((.mapped) s))) "mapped" $
                  foldr (\family -> cover 1 (family `elem` families) family) roundTrip allNodeTags
      it "round-trips an aggregate with no states" $
        parseSpec "<empty-states>" (renderSpec emptyStatesSpec) `shouldBe` Right emptyStatesSpec
      it "separates transition emit clauses from following nodes" $ do
        spec <- parseInlineSpec "<cross-family-boundaries>" crossFamilyBoundarySpec
        case (.nodes) spec of
          [NAggregate first, NEmit _, NAggregate second, NPgmqDispatch _] -> do
            concatMap (.emits) ((.transitions) first) `shouldBe` ["Changed"]
            (.states) second `shouldBe` []
          nodes -> expectationFailure ("unexpected node sequence: " <> show (map nodeTag nodes))

  describe "mapped types (EP-149)" $ do
    it "round-trips the canonical structural and opaque consumer fixture" $ do
      source <- TIO.readFile "test/fixtures/consumer-types.keiro"
      spec <- parseInlineSpec "test/fixtures/consumer-types.keiro" source
      parseStableRenderedSpec "<consumer-types-round-trip>" spec `shouldBe` Right spec
      length ((.mapped) spec) `shouldBe` 4
    it "preserves every missing-value policy, nested type expression, and unit union arm" $ do
      source <- TIO.readFile "test/fixtures/consumer-types.keiro"
      spec <- parseInlineSpec "test/fixtures/consumer-types.keiro" source
      let fields = [field | MappedStructural {msShape = ShapeRecord _ _ recordFields} <- (.mapped) spec, field <- recordFields]
          arms = [arm | MappedStructural {msShape = ShapeUnion _ unionArms} <- (.mapped) spec, arm <- unionArms]
      [value | field <- fields, Just value <- [(.onMissing) field]]
        `shouldBe` [OmCtor "Guide", OmNull, OmInt 0, OmBool False, OmEmptyList, OmEmptyMap]
      [(.valueType) field | field <- fields, (.haskell) field == "labels"]
        `shouldBe` [TList (TOptional TText)]
      [(.ctor) arm | arm <- arms, (.payload) arm == Nothing]
        `shouldBe` ["Unknown"]
    it "rejects every mapped validation fixture with its stable diagnostic code" $ do
      let cases =
            [ ("mapped-unresolved.keiro", MappedUnresolvedName),
              ("mapped-ambiguous.keiro", MappedAmbiguousName),
              ("mapped-dup-fieldname.keiro", MappedDuplicateFieldName),
              ("mapped-dup-wirekey.keiro", MappedDuplicateWireKey),
              ("mapped-dup-armname.keiro", MappedDuplicateArmName),
              ("mapped-dup-tag.keiro", MappedDuplicateWireTag),
              ("mapped-recursive.keiro", MappedRecursiveType),
              ("mapped-recursive-mutual.keiro", MappedRecursiveType),
              ("mapped-bad-encoding.keiro", MappedUnsupportedEncoding),
              ("mapped-union-key-collision.keiro", MappedUnsupportedEncoding),
              ("mapped-optional-json.keiro", MappedNonInjectiveNullability),
              ("mapped-optional-optional.keiro", MappedNonInjectiveNullability),
              ("mapped-optional-opaque.keiro", MappedNonInjectiveNullability),
              ("mapped-missing-binding.keiro", MappedMissingIngredient),
              ("mapped-missing-binding-version.keiro", MappedMissingIngredient),
              ("mapped-missing-canonical.keiro", MappedMissingIngredient),
              ("mapped-missing-fixture.keiro", MappedMissingIngredient),
              ("mapped-missing-initial.keiro", MappedMissingInitialValue),
              ("mapped-bad-haskell-name.keiro", MappedInvalidHaskellName),
              ("mapped-empty-identity.keiro", MappedInvalidIdentity),
              ("mapped-import-conflict.keiro", MappedImportConflict),
              ("mapped-illtyped-default.keiro", MappedDefaultIllTyped),
              ("mapped-guard.keiro", AggregateExpressionOperatorUnsupported)
            ]
      forM_ cases $ \(fixture, expected) ->
        errorCodesOf ("test/fixtures/" <> fixture) `shouldReturn` [expected]
    it "keeps Time and Natural in Keiki's curated comparison set" $ do
      errorCodesOf "test/fixtures/mapped-guard-time.keiro" `shouldReturn` []
      errorCodesOf "test/fixtures/mapped-guard-natural.keiro" `shouldReturn` []
    it "rejects required defaults, missing optional policies, Int overflow, and negative Natural defaults" $ do
      let invalidFields =
            [ WireField "requiredDefault" "requiredDefault" TText PRequired (Just (OmText "x")) noLoc,
              WireField "missingPolicy" "missingPolicy" TText POptional Nothing noLoc,
              WireField "overflow" "overflow" TInt POptional (Just (OmInt (toInteger (maxBound :: Int) + 1))) noLoc,
              WireField "negativeNatural" "negativeNatural" TNatural POptional (Just (OmInt (-1))) noLoc
            ]
          declaration = completeStructural "Defaults" (ShapeRecord "Defaults" RejectUnknown invalidFields)
      errorCodes (mappedSpec [declaration])
        `shouldBe` [MappedDefaultIllTyped, MappedMissingIngredient, MappedDefaultIllTyped, MappedDefaultIllTyped]

  describe "aggregate type capabilities" $ do
    it "enumerates the policy for every resolved type and use site" $ do
      let resolvedTypes =
            [ AggregateText,
              AggregateInt,
              AggregateBool,
              AggregateTime,
              AggregateNatural,
              AggregateNominal (ResolvedNominalType "EntityId" (IdRepresentation "ent") GeneratedNominal noLoc),
              AggregateNominal (ResolvedNominalType "Status" (EnumRepresentation (("Active", "active") :| [])) GeneratedNominal noLoc),
              AggregateNominal (ResolvedNominalType "Amount" (ScalarRepresentation NominalInt) (consumerNominalFor "Amount") noLoc),
              AggregateNominal (ResolvedNominalType "Label" (ScalarRepresentation NominalText) (consumerNominalFor "Label") noLoc),
              AggregateVertex "EntityVertex",
              AggregateMapped (MappedKey "ConsumerValue")
            ]
          useSites = [minBound .. maxBound]
          expected useSite resolvedType = case useSite of
            OrderingGuardUse -> case resolvedType of
              AggregateInt -> SolverVisible
              AggregateTime -> SolverVisible
              AggregateNatural -> SolverVisible
              AggregateNominal nominal -> case (.representation) nominal of
                ScalarRepresentation NominalInt -> SolverVisible
                ScalarRepresentation NominalNatural -> SolverVisible
                ScalarRepresentation NominalTime -> SolverVisible
                _ -> Unsupported
              _ -> Unsupported
            EqualityGuardUse -> case resolvedType of
              AggregateMapped {} -> Unsupported
              AggregateNominal {} -> SolverVisible
              AggregateVertex {} -> OpaqueOnly
              _ -> SolverVisible
            _ -> case resolvedType of
              AggregateNominal nominal -> case (.representation) nominal of
                ScalarRepresentation {} -> SolverVisible
                _ -> OpaqueOnly
              AggregateVertex {} -> OpaqueOnly
              AggregateMapped {} -> OpaqueOnly
              _ -> SolverVisible
          actual =
            [ (useSite, resolvedType, aggregateCapability useSite resolvedType)
            | useSite <- useSites,
              resolvedType <- resolvedTypes
            ]
          wanted =
            [ (useSite, resolvedType, expected useSite resolvedType)
            | useSite <- useSites,
              resolvedType <- resolvedTypes
            ]
      actual `shouldBe` wanted
    it "lowers direct Time and Natural through every generated aggregate boundary" $ do
      spec <- specOf "test/fixtures/aggregate-scalars.keiro"
      errorCodes spec `shouldBe` []
      let aggregate = onlyAggregate spec
          modules = scaffoldAggregate (defaultContext (spec.context)) spec aggregate
          generated =
            [ (.text) generatedModule
            | generatedModule <- modules,
              (.kind) generatedModule == Generated
            ]
          domain = generatedTextEndingIn "Domain.hs" modules
          codec = generatedTextEndingIn "Codec.hs" modules
      domain `shouldSatisfy` T.isInfixOf "observedAt :: !UTCTime"
      domain `shouldSatisfy` T.isInfixOf "revision :: !Natural"
      domain `shouldSatisfy` T.isInfixOf "UTCTime (fromGregorian 2026 1 2) (picosecondsToDiffTime 11045123456789012)"
      domain `shouldSatisfy` T.isInfixOf "import Data.Time.Calendar (fromGregorian)"
      domain `shouldSatisfy` T.isInfixOf "import Data.Time.Clock (UTCTime (..), picosecondsToDiffTime)"
      domain `shouldSatisfy` T.isInfixOf "import Numeric.Natural (Natural)"
      manifestDependencies spec `shouldContain` ["time"]
      manifestDependencies spec `shouldNotContain` ["keiki-codec-json"]
      codec `shouldSatisfy` T.isInfixOf "scalarLedgerEventTypes :: NonEmpty EventType"
      codec `shouldSatisfy` T.isInfixOf "eventTypes = scalarLedgerEventTypes"
      codec `shouldSatisfy` T.isInfixOf "renderExpectedEventTypes scalarLedgerEventTypes"
      codec `shouldSatisfy` (not . T.isInfixOf "; expected one of: ScalarsRecorded\"")
      generated `shouldSatisfy` all (not . T.isInfixOf "error")
      generated `shouldSatisfy` all (not . T.isInfixOf "getCurrentTime")
      generated `shouldSatisfy` all (not . T.isInfixOf "iso8601ParseM")
    it "keeps the event-list binding disjoint from the private formatter" $ do
      source <- readTestText "test/fixtures/aggregate-scalars.keiro"
      spec <- parseInlineSpec "<render-aggregate>" (T.replace "aggregate ScalarLedger" "aggregate Render" source)
      let aggregate = onlyAggregate spec
          modules = scaffoldAggregate (defaultContext (spec.context)) spec aggregate
          codec = generatedTextEndingIn "Codec.hs" modules
          codecLines = T.lines codec
      codecLines `shouldContain` ["renderEventTypes :: NonEmpty EventType"]
      codecLines `shouldContain` ["renderExpectedEventTypes :: NonEmpty EventType -> String"]
      codec `shouldSatisfy` T.isInfixOf "eventTypes = renderEventTypes"
      codec `shouldSatisfy` T.isInfixOf "renderExpectedEventTypes renderEventTypes"
    it "canonicalizes Time and UTCTime across pretty, diff, and fold identity" $ do
      source <- readTestText "test/fixtures/aggregate-scalars.keiro"
      canonical <- parseInlineSpec "<time>" source
      alias <- parseInlineSpec "<utctime>" (T.replace ":Time" ":UTCTime" (T.replace " Time =" " UTCTime =" source))
      renderSpec alias `shouldBe` renderSpec canonical
      legacyDiffSpecs canonical alias `shouldBe` []
      legacyAggregateFoldFingerprint canonical (onlyAggregate canonical)
        `shouldBe` legacyAggregateFoldFingerprint alias (onlyAggregate alias)
      legacyAggregateFoldSurface canonical (onlyAggregate canonical)
        `shouldBe` legacyAggregateFoldSurface alias (onlyAggregate alias)
    it "keeps the committed scalar conformance generated tree fresh" $ do
      modules <- scaffoldFixture "test/fixtures/aggregate-scalars.keiro"
      forM_ [generatedModule | generatedModule <- modules, (.kind) generatedModule == Generated] $ \generatedModule -> do
        committed <- readTestText ("test/conformance-aggregate-scalars/" <> (.path) generatedModule)
        normalizeGenerated committed `shouldBe` normalizeGenerated ((.text) generatedModule)
    it "never sends a clean scalar aggregate to a type scaffold refusal" $
      property $
        forAll (elements scalarRegisterCases) $ \(typeName, initialValue) ->
          case parseSpec "<clean-scalar>" (cleanScalarAggregateSpec typeName initialValue) of
            Left parseError -> counterexample (T.unpack parseError) False
            Right spec ->
              let diagnostics = [diagnostic | diagnostic <- validateSpec spec, (.severity) diagnostic == Error]
                  modules = scaffoldModules (defaultContext (spec.context)) spec
               in counterexample
                    (show diagnostics <> "\n" <> show (scaffoldRefusals spec))
                    ( null diagnostics
                        && null (scaffoldRefusals spec)
                        && all (not . T.null . (.text)) modules
                    )

  describe "aggregate scalar diagnostics" $ do
    it "reports unsupported shapes, invalid initials, and mismatched guards at stable lines" $ do
      diagnostics <- diagnosticsOf "test/fixtures/aggregate-scalars-unsupported.keiro"
      [((.code) diagnostic, (.line) diagnostic) | diagnostic <- diagnostics, (.severity) diagnostic == Error]
        `shouldBe` [ (AggregateRegisterInitialInvalid, 6),
                     (AggregateRegisterInitialInvalid, 7),
                     (AggregateTypeUnsupportedAtUse, 10),
                     (AggregateExpressionOperandTypeMismatch, 14)
                   ]
      map (.message) diagnostics `shouldSatisfy` any (T.isInfixOf "non-negative integral literals")
      map (.message) diagnostics `shouldSatisfy` any (T.isInfixOf "ISO-8601 UTC timestamps")
      map (.message) diagnostics `shouldSatisfy` any (T.isInfixOf "mapped structural declaration")
    it "accepts Natural aggregate arithmetic in the stable language" $ do
      diagnostics <- diagnosticsOf "test/fixtures/aggregate-scalars-arithmetic.keiro"
      [((.code) diagnostic, (.line) diagnostic) | diagnostic <- diagnostics, (.severity) diagnostic == Error]
        `shouldBe` []
    it "covers unknown, container, fractional, out-of-range, and ordering failures" $ do
      diagnostics <- diagnosticsOf "test/fixtures/aggregate-scalars-invalid-capabilities.keiro"
      [((.code) diagnostic, (.line) diagnostic) | diagnostic <- diagnostics, (.severity) diagnostic == Error]
        `shouldBe` [ (AggregateRegisterInitialInvalid, 6),
                     (AggregateRegisterInitialInvalid, 7),
                     (AggregateTypeUnknown, 10),
                     (AggregateTypeUnsupportedAtUse, 10),
                     (AggregateTypeUnsupportedAtUse, 10),
                     (AggregateTypeUnsupportedAtUse, 10),
                     (AggregateExpressionOperatorUnsupported, 13)
                   ]
    it "keeps one-member workspace diagnostics identical to the single file" $ do
      direct <- diagnosticsOf "test/fixtures/aggregate-scalars-unsupported.keiro"
      composed <- shouldComposeWorkspace "test/fixtures/aggregate-scalars-workspace/service.keiro-workspace"
      let directErrors =
            [((.code) diagnostic, (.line) diagnostic, (.message) diagnostic) | diagnostic <- direct, (.severity) diagnostic == Error]
          workspaceErrors =
            [ ((.code) diagnostic, (.line) (NE.head ((.locations) diagnostic)), (.message) diagnostic)
            | diagnostic <- checkWorkspace composed,
              (.severity) diagnostic == Error
            ]
      workspaceErrors `shouldBe` directErrors

  describe "mapped type graph (EP-149)" $ do
    it "resolves checked declarations, transitive reachability, and every aggregate root path" $ do
      source <- TIO.readFile "test/fixtures/consumer-types.keiro"
      spec <- parseInlineSpec "test/fixtures/consumer-types.keiro" source
      graph <- shouldResolveTypeGraph spec
      Map.size ((.declarations) graph) `shouldBe` 4
      Map.lookup (MappedKey "ArtifactInfo") ((.reachability) graph)
        `shouldBe` Just (Set.fromList [MappedKey "ArtifactKind", MappedKey "ArtifactLocation"])
      map renderUsePath (usePaths graph "ArtifactLocation")
        `shouldBe` [ "Catalog command ObserveArtifact .artifact : ArtifactInfo .location : ArtifactLocation",
                     "Catalog event ArtifactObserved .artifact : ArtifactInfo .location : ArtifactLocation",
                     "Catalog register currentArtifact : ArtifactInfo .location : ArtifactLocation"
                   ]
    it "resolves every builtin through the complete expression algebra" $ do
      source <- TIO.readFile "test/fixtures/consumer-types.keiro"
      spec <- parseInlineSpec "test/fixtures/consumer-types.keiro" source
      graph <- shouldResolveTypeGraph spec
      case Map.lookup (MappedKey "ArtifactInfo") ((.declarations) graph) of
        Just (ResolvedStructural _ (RRecord _ _ fields)) ->
          Set.fromList (concatMap (foldTypeExpr expressionTags . (.valueType)) fields)
            `shouldBe` Set.fromList ["text", "int", "bool", "natural", "time", "json", "optional", "list", "map", "ref:ArtifactKind", "ref:ArtifactLocation"]
        declaration -> expectationFailure ("unexpected ArtifactInfo declaration: " <> show declaration)
    it "rejects direct, mutual, wrapped, and union-arm recursion" $ do
      let direct = mappedSpec [completeStructural "A" (recordShape [TRef "A"])]
          mutual = mappedSpec [completeStructural "A" (recordShape [TRef "B"]), completeStructural "B" (recordShape [TRef "A"])]
          wrapped = mappedSpec [completeStructural "A" (recordShape [TList (TOptional (TRef "A"))])]
          throughArm = mappedSpec [completeStructural "A" (ShapeUnion (TaggedObject "tag" "contents" RejectUnknown) [WireArm "Again" "again" (Just (TRef "A")) noLoc])]
      map (hasTypeGraphError isRecursive . resolveTypeGraph) [direct, mutual, wrapped, throughArm]
        `shouldBe` replicate 4 True
    it "keeps existing ids and enums outside the mapped-reference namespace" $ do
      let spec =
            (mappedSpec [completeStructural "A" (recordShape [TRef "ExistingId"])])
              { ids = [IdDecl "ExistingId" "id" Nothing noLoc]
              }
      resolveTypeGraph spec `shouldSatisfy` hasTypeGraphError isUnresolved
    it "fingerprints wire identity while ignoring Haskell selector names" $ do
      source <- TIO.readFile "test/fixtures/consumer-types.keiro"
      base <- parseInlineSpec "test/fixtures/consumer-types.keiro" source
      baseGraph <- shouldResolveTypeGraph base
      haskellRenameGraph <- shouldResolveTypeGraph (mapArtifactField (wireFieldWithHaskell "renamedKey") base)
      wireRenameGraph <- shouldResolveTypeGraph (mapArtifactField (wireFieldWithKey "renamed_key") base)
      wireFingerprint haskellRenameGraph "ArtifactInfo" `shouldBe` wireFingerprint baseGraph "ArtifactInfo"
      wireFingerprint wireRenameGraph "ArtifactInfo" `shouldNotBe` wireFingerprint baseGraph "ArtifactInfo"

  describe "semantic impact" $ do
    it "derives local aggregate closures and a complete service inventory" $ do
      source <- readTestText "test/fixtures/semantic-impact.keiro"
      spec <- parseInlineSpec "test/fixtures/semantic-impact.keiro" source
      graph <- shouldResolveTypeGraph spec
      let impact = semanticImpact graph
      aggregateMappedClosure impact "Alpha"
        `shouldBe` map MappedKey ["CommandPayload", "EventPayload", "NestedPayload", "RegisterPayload", "SharedPayload"]
      aggregateMappedClosure impact "Beta"
        `shouldBe` [MappedKey "SharedPayload"]
      mappedDeclarationConsumers impact (MappedKey "NestedPayload")
        `shouldBe` [AggregateConsumer "Alpha"]
      mappedDeclarationConsumers impact (MappedKey "SharedPayload")
        `shouldBe` [AggregateConsumer "Alpha", AggregateConsumer "Beta"]
      mappedDeclarationConsumers impact (MappedKey "UnusedPayload")
        `shouldBe` []
      Map.lookup (MappedKey "UnusedPayload") ((.declarationConsumers) impact)
        `shouldBe` Just Set.empty
      serviceMappedInventory impact
        `shouldBe` map MappedKey ["CommandPayload", "EventPayload", "NestedPayload", "RegisterPayload", "SharedPayload", "UnusedPayload"]
    it "folds command, private-event, and register roots explicitly" $ do
      source <- readTestText "test/fixtures/semantic-impact.keiro"
      spec <- parseInlineSpec "test/fixtures/semantic-impact.keiro" source
      impact <- semanticImpact <$> shouldResolveTypeGraph spec
      map (.kind) (aggregateMappedRoots impact "Alpha")
        `shouldBe` [MappedCommandFieldRoot, MappedCommandFieldRoot, MappedEventFieldRoot, MappedRegisterRoot]
      map (.kind) (aggregateMappedRoots impact "Beta")
        `shouldBe` [MappedRegisterRoot]
    it "is independent of declaration and aggregate traversal order" $ do
      source <- readTestText "test/fixtures/semantic-impact.keiro"
      spec <- parseInlineSpec "test/fixtures/semantic-impact.keiro" source
      baseline <- semanticImpact <$> shouldResolveTypeGraph spec
      reordered <-
        semanticImpact
          <$> shouldResolveTypeGraph
            spec
              { mapped = reverse ((.mapped) spec),
                nodes = reverse ((.nodes) spec)
              }
      reordered `shouldBe` baseline
    it "keeps future UseSite roots behind an exhaustive compile-time fold" $ do
      source <- readTestText "src/Keiro/Dsl/SemanticImpact.hs"
      source `shouldSatisfy` T.isInfixOf "{-# OPTIONS_GHC -Werror=incomplete-patterns #-}"
      map
        (`T.isInfixOf` source)
        [ "mappedRootFromUseSite site@(RootCommandField",
          "mappedRootFromUseSite site@(RootEventField",
          "mappedRootFromUseSite site@(RootRegister",
          "mappedRootFromUseSite site@(RootWorkqueueField",
          "mappedRootFromUseSite site@(RootReadModelQueryInput",
          "mappedRootFromUseSite site@(RootReadModelQueryResult"
        ]
        `shouldBe` replicate 6 True
      source `shouldSatisfy` (not . T.isInfixOf "mappedRootFromUseSite _")
    it "round-trips canonical snapshots and reports only checked consumer membership changes" $ do
      spec <- specOf "test/fixtures/semantic-impact.keiro"
      snapshot <- semanticImpactSnapshot . semanticImpact <$> shouldResolveTypeGraph spec
      Aeson.decode (Aeson.encode snapshot) `shouldBe` Just snapshot
      let shared = MappedKey "SharedPayload"
          changed =
            snapshot
              { mappedConsumers =
                  Map.adjust (Set.delete (AggregateConsumer "Beta")) shared ((.mappedConsumers) snapshot)
              }
      case diffSemanticImpact snapshot changed of
        [delta] -> do
          (.declaration) delta `shouldBe` shared
          (.previousConsumers) delta `shouldBe` Set.fromList [AggregateConsumer "Alpha", AggregateConsumer "Beta"]
          (.currentConsumers) delta `shouldBe` Set.singleton (AggregateConsumer "Alpha")
          (.serviceConformance) delta `shouldBe` True
        deltas -> expectationFailure ("expected one semantic-impact delta, got " <> show deltas)
      case mappedImpactForDeclarations [MappedKey "NestedPayload"] snapshot snapshot of
        [delta] -> do
          (.declaration) delta `shouldBe` MappedKey "NestedPayload"
          (.previousConsumers) delta `shouldBe` Set.singleton (AggregateConsumer "Alpha")
          (.currentConsumers) delta `shouldBe` Set.singleton (AggregateConsumer "Alpha")
          (.previousEvidence) delta `shouldSatisfy` maybe False (not . Set.null)
          (.currentConsequences) delta `shouldSatisfy` maybe False (not . Set.null)
        deltas -> expectationFailure ("expected one nested semantic-impact delta, got " <> show deltas)
    it "round-trips additive semantic impact ledger rows and rejects known-row corruption" $ do
      spec <- specOf "test/fixtures/semantic-impact.keiro"
      let snapshot = semanticImpactSnapshotForSpec spec
          singleRecord =
            ScaffoldRecord
              { specPath = "semantic-impact.keiro",
                moduleRoot = "",
                layout = "prefixed",
                sourceLanguage = LegacyUnversioned,
                languageContract = effectiveLanguageContract LegacyUnversioned,
                namingEdition = IdiomaticNamingV1,
                moduleRoles = [],
                files = [],
                mappings = [],
                idDomains = [],
                nominalEqualities = [],
                bindingObligations = [],
                behaviorRequirements = [],
                projectionCatalogFacts = [],
                queryContractBaseline = True,
                queryContracts = either (const []) id (queryContractIdentities spec),
                routerSelections = [],
                semanticImpact = Just snapshot
              }
          encoded = renderRecord singleRecord
          semanticRows = filter ("semantic-impact " `T.isPrefixOf`) (T.lines encoded)
          legacyEncoded = T.unlines (filter (not . T.isPrefixOf "semantic-impact ") (T.lines encoded))
          futureEncoded = T.replace "semantic-impact {" "semantic-impact {\"future\":true," encoded
          emptyIdentitySnapshot =
            SemanticImpactSnapshot
              { mappedConsumers = snapshot.mappedConsumers,
                mappedEvidence = snapshot.mappedEvidence,
                mappedConsequences = snapshot.mappedConsequences,
                serviceInventory = snapshot.serviceInventory,
                declarationIdentities = Map.adjust (const "") (MappedKey "CommandPayload") snapshot.declarationIdentities
              }
      length semanticRows `shouldBe` 1
      parseRecord encoded `shouldBe` Just singleRecord
      (.semanticImpact) <$> parseRecord legacyEncoded `shouldBe` Just Nothing
      parseRecord futureEncoded `shouldBe` Just singleRecord
      (Aeson.decode (Aeson.encode emptyIdentitySnapshot) :: Maybe SemanticImpactSnapshot) `shouldBe` Nothing
      case semanticRows of
        [row] -> do
          parseRecord (encoded <> row <> "\n") `shouldBe` Nothing
          let duplicateConsumer = T.replace "\"consumers\":[\"Alpha\",\"Beta\"]" "\"consumers\":[\"Alpha\",\"Alpha\"]" encoded
          duplicateConsumer `shouldNotBe` encoded
          parseRecord duplicateConsumer `shouldBe` Nothing
        _ -> expectationFailure "expected exactly one semantic-impact row"
      workspace <- shouldComposeWorkspace canonicalWorkspacePath
      let workspaceRecord = (sampleWorkspaceRecord workspace) {WorkspaceRecord.semanticImpact = Just snapshot}
          workspaceEncoded = renderWorkspaceRecord workspaceRecord
      T.count "semantic-impact " workspaceEncoded `shouldBe` 1
      parseWorkspaceRecord workspaceEncoded `shouldBe` Just workspaceRecord
      parseWorkspaceRecord (workspaceEncoded <> "future-row ignored\n") `shouldBe` Just workspaceRecord

  describe "string literal integrity" $ do
    it "parses an escaped emit-map value as exactly one row" $ do
      let src =
            T.unlines
              [ "context svc",
                "",
                "emit e {",
                "  contract c",
                "  topic events",
                "  source \"svc\"",
                "  key thingId",
                "  map status {",
                "    \"a\\\" => Wat \\\"b\" => ThingAccepted",
                "    _ => skip",
                "  }",
                "  messageId derive hole",
                "  idempotencyKey derive hole",
                "}"
              ]
      case parseSpec "<escaped-map>" src of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> case [row | NEmit e <- (.nodes) spec, row <- e.map] of
          [row] -> do
            (.value) row `shouldBe` "a\" => Wat \"b"
            (.event) row `shouldBe` "ThingAccepted"
          rows -> expectationFailure ("expected one emit-map row, got " <> show (length rows))
    it "rejects a raw newline inside a quoted string" $ do
      let src = "context svc\n\ncontract c {\n  schemaVersion 1\n  discriminator kind\n  topic events \"first\nsecond\"\n}\n"
      parseSpec "<raw-newline>" src `shouldSatisfy` leftContains "unescaped newline"
    it "rejects an unknown escape sequence" $ do
      let src = "context svc\n\ncontract c {\n  schemaVersion 1\n  discriminator kind\n  topic events \"bad\\q\"\n}\n"
      parseSpec "<unknown-escape>" src `shouldSatisfy` leftContains "unknown escape"
    it "round-trips adversarial text through topics, emit maps, and quoted bindings" $
      property $
        forAll genAdversarialText $ \t ->
          let spec = escapedSpec t
              rendered = renderSpec spec
           in counterexample (T.unpack rendered) (parseSpec "<escaped-round-trip>" rendered === Right spec)

  describe "partial status maps" $ do
    it "suppresses totality only when the partial marker is present" $ do
      partial <- parseInlineSpec "<partial-status-map>" (statusMapSpec " partial")
      totalSpec <- parseInlineSpec "<total-status-map>" (statusMapSpec "")
      map (.code) (validateSpec partial) `shouldNotContain` [StatusMapNotTotal]
      map (.code) (validateSpec totalSpec) `shouldContain` [StatusMapNotTotal]
      parseSpec "<partial-round-trip>" (renderSpec partial) `shouldBe` Right partial

  describe "positioned parser diagnostics" $ do
    it "rejects a duplicate goto at the second clause" $ do
      err <- parseErrorOf "<duplicate-goto>" duplicateGotoSpec
      err `shouldSatisfy` T.isInfixOf "duplicate goto"
      err `shouldSatisfy` T.isInfixOf "<duplicate-goto>:10:"
    it "rejects duplicate wire and projection blocks at their second occurrences" $ do
      wireErr <- parseErrorOf "<duplicate-wire>" duplicateWireSpec
      wireErr `shouldSatisfy` T.isInfixOf "duplicate wire block"
      wireErr `shouldSatisfy` T.isInfixOf "<duplicate-wire>:8:"
      projectionErr <- parseErrorOf "<duplicate-projection>" duplicateProjectionSpec
      projectionErr `shouldSatisfy` T.isInfixOf "duplicate projection block"
      projectionErr `shouldSatisfy` T.isInfixOf "<duplicate-projection>:9:"
    it "anchors a missing goto on the transition line" $ do
      err <- parseErrorOf "<missing-goto>" missingGotoSpec
      err `shouldSatisfy` T.isInfixOf "missing a goto clause"
      err `shouldSatisfy` T.isInfixOf "<missing-goto>:8:"
    it "stops before a misplaced dispatch-id and expects schedule at its start" $ do
      let src = misplacedDispatchIdSpec
          expectedPosition =
            "<misplaced-dispatch-id>:"
              <> T.pack (show (lineNumberContaining "dispatch-id" src))
              <> ":5:"
      err <- parseErrorOf "<misplaced-dispatch-id>" src
      err `shouldSatisfy` T.isInfixOf "schedule"
      err `shouldSatisfy` T.isInfixOf expectedPosition
    it "keeps a malformed register declaration's equals error" $ do
      err <- parseErrorOf "<malformed-register>" malformedRegisterSpec
      err `shouldSatisfy` T.isInfixOf "expecting '='"

  describe "bounded decimal literals" $ do
    forM_ decimalOverflowSpecs $ \(site, src) ->
      it ("rejects overflow at " <> site) $ do
        err <- parseErrorOf ("<overflow-" <> site <> ">") src
        err `shouldSatisfy` T.isInfixOf ("decimal literal " <> decimalOverflow <> " is out of range")
    it "accepts maxBound without changing its value" $ do
      spec <- parseInlineSpec "<max-bound>" (wireDecimalSpec (T.pack (show (maxBound :: Int))))
      [wire.schemaVersion | NAggregate aggregate <- (.nodes) spec, Just wire <- [(.wire) aggregate]]
        `shouldBe` [maxBound]

  describe "identifier hygiene" $ do
    it "normalizes lowercase logical type names and reports generated Haskell keywords at their owning declarations" $ do
      spec <- parseInlineSpec "<identifier-hygiene>" identifierHygieneSpec
      [((.code) diagnostic, (.line) diagnostic) | diagnostic <- validateSpec spec, (.code) diagnostic `elem` [IdentUnsafeNormalization, GeneratedOccurrenceReserved]]
        `shouldBe` [(GeneratedOccurrenceReserved, 7)]
    it "rejects generated vertex constructors that collide with event constructors" $ do
      spec <- parseInlineSpec "<vertex-collision>" vertexCollisionSpec
      [((.code) diagnostic, (.line) diagnostic) | diagnostic <- validateSpec spec, (.code) diagnostic == VertexCtorCollision]
        `shouldBe` [(VertexCtorCollision, 3)]
    it "rejects underscore-leading names whose normalization would erase a word boundary" $ do
      spec <- parseInlineSpec "<underscore-node>" underscoreNodeSpec
      [((.code) diagnostic, (.line) diagnostic) | diagnostic <- validateSpec spec, (.code) diagnostic == IdentUnsafeNormalization]
        `shouldBe` [(IdentUnsafeNormalization, 3)]
    it "rejects normalized module collisions with both source locations" $ do
      spec <- parseInlineSpec "<normalized-collision>" normalizedCollisionSpec
      case [diagnostic | diagnostic <- validateSpec spec, (.code) diagnostic == GeneratedOccurrenceCollision] of
        [diagnostic] -> do
          (.line) diagnostic `shouldBe` 8
          (.relatedLocations) diagnostic `shouldBe` [(3, "'fooBar' also normalizes here")]
          renderDiagnostic "<normalized-collision>" diagnostic `shouldSatisfy` T.isInfixOf "fooBar"
        diagnostics -> expectationFailure ("expected one normalized collision, got " <> show diagnostics)
    it "validates explicit selectors and detects selector collisions in aggregate and contract records" $ do
      service <-
        checkedServiceFromText
          "<field-selector-validation>"
          ( T.unlines
              [ "language keiro-dsl 4",
                "context aliases",
                "aggregate Order",
                "  regs",
                "  states Open",
                "  command Change {",
                "    first haskell shared:Text",
                "    second haskell shared:Text",
                "    reserved haskell type:Text",
                "    invalid haskell Bad:Text",
                "  }",
                "contract publicOrder {",
                "  schemaVersion 1",
                "  discriminator kind",
                "  topic changes \"orders.v1\"",
                "  event Changed on changes {",
                "    first haskell duplicate: text",
                "    second haskell duplicate: text",
                "  }",
                "}"
              ]
          )
      let diagnostics = validateService service
          selectorCollisions = [diagnostic | diagnostic <- diagnostics, (.code) diagnostic == GeneratedOccurrenceCollision]
      [((.code) diagnostic, (.line) diagnostic) | diagnostic <- diagnostics, (.code) diagnostic `elem` [GeneratedOccurrenceReserved, IdentUnsafeNormalization]]
        `shouldBe` [(GeneratedOccurrenceReserved, 9), (IdentUnsafeNormalization, 10)]
      map (.line) selectorCollisions `shouldBe` [8, 18]
      map (.relatedLocations) selectorCollisions
        `shouldBe` [ [(7, "'first' also normalizes here")],
                     [(17, "'first' also normalizes here")]
                   ]
    it "rejects empty, duplicate, and envelope-colliding resolved wire keys with field-local evidence" $ do
      service <-
        checkedServiceFromText
          "<field-wire-validation>"
          ( T.unlines
              [ "language keiro-dsl 4",
                "context aliases",
                "aggregate Order",
                "  regs",
                "  states Open",
                "  command Change {",
                "    first as \"same\":Text",
                "    second as \"same\":Text",
                "    empty as \"\":Text",
                "  }",
                "  event Changed { value as \"kind\":Text }",
                "contract publicOrder {",
                "  schemaVersion 1",
                "  discriminator kind",
                "  topic changes \"orders.v1\"",
                "  event Published on changes { value as \"kind\": text }",
                "}"
              ]
          )
      let diagnostics = validateService service
          wireDiagnostics = [diagnostic | diagnostic <- diagnostics, (.code) diagnostic `elem` [FieldWireKeyCollision, FieldWireKeyInvalid]]
      map (\diagnostic -> ((.code) diagnostic, (.line) diagnostic)) wireDiagnostics
        `shouldBe` [ (FieldWireKeyCollision, 8),
                     (FieldWireKeyInvalid, 9),
                     (FieldWireKeyCollision, 11),
                     (FieldWireKeyCollision, 16)
                   ]
      case wireDiagnostics of
        firstDiagnostic : _ -> (.relatedLocations) firstDiagnostic `shouldBe` [(7, "wire key 'same' is first declared here")]
        [] -> expectationFailure "expected resolved wire-key diagnostics"
    -- `family` is a contextual keyword GHC accepts as a term under the
    -- advertised GHC2024 contract, and it is the field mori's project signals
    -- are keyed by. This fixture pins that scenario end to end; before ExecPlan
    -- 199 no test referenced it, so the guarantee was untested.
    it "keeps a reserved-word-adjacent contract field intact from check to codec" $
      withTempDirectory "keiro-dsl-reserved-family" $ \out -> do
        let fixture = "test/fixtures/contract-reserved-family.keiro"
        (checkCode, checkOut, checkErr) <- runKeiroDsl ["check", fixture, "--min-language", "4", "--deny-warnings"]
        unless (checkCode == ExitSuccess) (expectationFailure (checkOut <> checkErr))
        checkOut `shouldBe` "OK\n"
        checkErr `shouldNotContain` "warning["

        (scaffoldCode, scaffoldOut, scaffoldErr) <- runKeiroDsl ["scaffold", fixture, "--out", out]
        unless (scaffoldCode == ExitSuccess) (expectationFailure (scaffoldOut <> scaffoldErr))
        tree <- treeSnapshot out
        case [text | (path, text) <- tree, "Contract.hs" `T.isSuffixOf` T.pack path] of
          codec : _ -> do
            -- The DSL name is the record selector …
            codec `shouldSatisfy` T.isInfixOf "family ::"
            -- … and, unaliased, the wire key is the same bytes.
            codec `shouldSatisfy` T.isInfixOf "\"family\""
            codec `shouldNotSatisfy` T.isInfixOf "family_"
          [] -> expectationFailure ("no generated contract module in " <> show (map fst tree))

    -- An alias exists to preserve a brownfield key the current convention would
    -- reject, so its *style* is deliberately not checked (ADR 0021). What is
    -- checked is that the key can be a key: a trailing space or a control
    -- character ships a permanently mis-keyed public field. See ExecPlan 199.
    it "refuses structurally unusable wire-key aliases without opinionating on style" $ do
      let aliasSpec alias =
            T.unlines
              [ "language keiro-dsl 4",
                "context aliases",
                "aggregate Order",
                "  regs",
                "  states Open",
                "  command Change {",
                "    region as \"" <> alias <> "\":Text",
                "  }"
              ]
          keyDiagnostics source = do
            service <- checkedServiceFromText "<alias-content>" source
            pure [diagnostic | diagnostic <- validateService service, (.code) diagnostic == FieldWireKeyInvalid]

      -- Refused: the wire key is the exact bytes on the wire. Written as the
      -- DSL spells them, so `\\n` here is the source's escape, not Haskell's.
      forM_ ["family ", " family", "family\\n", "fam\\tily", "fam\\rily"] $ \bad -> do
        refused <- keyDiagnostics (aliasSpec bad)
        map (.code) refused `shouldBe` [FieldWireKeyInvalid]
        map (.line) refused `shouldBe` [7]

      -- Accepted: these violate `fields=camelCase` and that is exactly the point
      -- of an alias — the brownfield key is preserved, not corrected.
      forM_ ["region_code", "Region-Code", "REGION.CODE", "r\233gion"] $ \brownfield -> do
        accepted <- keyDiagnostics (aliasSpec brownfield)
        accepted `shouldBe` []

    -- The collision planner must register the selector generation actually
    -- emits. Registering a camelized rendering of the raw name made it claim
    -- `foo_bar` "normalizes to" `fooBar`, which generation never does.
    it "plans field collisions against the emitted selector, not a camelized rendering" $ do
      let recordSpec fields =
            T.unlines
              [ "language keiro-dsl 4",
                "context aliases",
                "aggregate Order",
                "  regs",
                "  states Open",
                "  command Change { " <> fields <> " }"
              ]
          collisionsIn source = do
            service <- checkedServiceFromText "<selector-collision>" source
            pure [diagnostic | diagnostic <- validateService service, (.code) diagnostic == GeneratedOccurrenceCollision]

      -- Distinct emitted selectors: `foo_bar` generates `foo_bar`. It is still
      -- refused, but by the generated-name audit that owns lowerCamelCase — not
      -- by a collision claim naming an unrelated sibling.
      falseCollision <- collisionsIn (recordSpec "foo_bar fooBar")
      falseCollision `shouldBe` []

      -- Two declarations that really do emit one selector still collide.
      realCollision <- collisionsIn (recordSpec "fooBar other haskell fooBar")
      map (.code) realCollision `shouldSatisfy` \codes -> GeneratedOccurrenceCollision `elem` codes

    it "checks copied command selectors in both generated record scopes" $ do
      service <-
        checkedServiceFromText
          "<copied-selector-collision>"
          ( T.unlines
              [ "language keiro-dsl 4",
                "context aliases",
                "aggregate Order",
                "  regs",
                "  states Open",
                "  command Change { first haskell shared:Text second haskell shared:Text }",
                "  event Changed = fields(Change)"
              ]
          )
      [(.line) diagnostic | diagnostic <- validateService service, (.code) diagnostic == GeneratedOccurrenceCollision]
        `shouldBe` [6, 6]
    it "anchors repeated reserved contract fields at their own lines and maps them through workspaces" $ do
      service <-
        checkedServiceFromText
          "domain/member.keiro"
          ( T.unlines
              [ "language keiro-dsl 4",
                "context aliases",
                "contract publicOrder {",
                "  schemaVersion 1",
                "  discriminator kind",
                "  topic changes \"orders.v1\"",
                "  event First on changes { where: text }",
                "  event Second on changes { where: text }",
                "}"
              ]
          )
      [(.line) diagnostic | diagnostic <- validateService service, (.code) diagnostic == GeneratedOccurrenceReserved]
        `shouldBe` [7, 8]
      let workspaceDiagnostics =
            [ diagnostic
            | diagnostic <- checkWorkspace (oneMemberWorkspace "domain/member.keiro" (checkedSpec service)),
              (.code) diagnostic == GeneratedOccurrenceReserved
            ]
          workspaceLocations =
            [ ((.file) location, (.line) location)
            | diagnostic <- workspaceDiagnostics,
              location <- NE.toList ((.locations) diagnostic)
            ]
      workspaceLocations
        `shouldBe` [ (WorkspaceMemberFile "member.keiro", 7),
                     (WorkspaceMemberFile "member.keiro", 8)
                   ]
    it "rejects non-ASCII identifier characters in the parser" $
      parseSpec "<unicode-identifier>" unicodeIdentifierSpec `shouldSatisfy` leftContains "unexpected"

  describe "Haskell.name-audit" $ do
    it "inventories every declaration in a fresh compound-name scaffold" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      let service = legacyCheckedService spec
          ctx = defaultContext (spec.context)
          modules = scaffoldServiceModules ctx service
      concatMap auditGeneratedHaskell modules `shouldBe` []
    it "rejects underscore module and declaration mutations but ignores literals and comments" $ do
      let mutated =
            ScaffoldModule
              { path = "Generated/IncidentPaging/Service_oncall/Mutation.hs",
                text =
                  T.unlines
                    [ "module Generated.IncidentPaging.Service_oncall.Mutation where",
                      "-- comment_value :: Text",
                      "literalValue = \"string_value\"",
                      "render_eventTypes :: Int",
                      "render_eventTypes = 1"
                    ],
                kind = Generated,
                origin = "test name-audit mutation"
              }
          violations = auditGeneratedHaskell mutated
      violations `shouldSatisfy` any (T.isInfixOf "Service_oncall")
      violations `shouldSatisfy` any (T.isInfixOf "render_eventTypes")
      violations `shouldSatisfy` all (not . T.isInfixOf "comment_value")
      violations `shouldSatisfy` all (not . T.isInfixOf "string_value")
    it "rejects repeated generated signatures before writing" $ do
      let mutated =
            ScaffoldModule
              { path = "Generated/Repeated.hs",
                text =
                  T.unlines
                    [ "module Generated.Repeated where",
                      "sameValue :: Bool",
                      "sameValue = True",
                      "sameValue :: Bool",
                      "sameValue = False"
                    ],
                kind = Generated,
                origin = "test repeated declaration"
              }
      auditGeneratedHaskell mutated `shouldSatisfy` any (T.isInfixOf "repeated top-level type signature 'sameValue'")

  describe "Haskell.name-migration" $ do
    it "pairs a legacy module path with its stable idiomatic artifact" $ do
      let currentModule =
            ScaffoldModule
              { path = "Generated/IncidentPaging/ServiceOncall/ReadModel.hs",
                text = "module Generated.IncidentPaging.ServiceOncall.ReadModel where\n",
                kind = Generated,
                origin = "readmodel service_oncall ReadModel"
              }
      planSourceMoves [(Nothing, Generated, "Generated/IncidentPaging/Service_oncall/ReadModel.hs")] [currentModule]
        `shouldBe` Right
          [ SourceMove
              { role = moduleRole currentModule,
                kind = Generated,
                oldModule = "Generated.IncidentPaging.Service_oncall.ReadModel",
                newModule = "Generated.IncidentPaging.ServiceOncall.ReadModel",
                oldPath = "Generated/IncidentPaging/Service_oncall/ReadModel.hs",
                newPath = "Generated/IncidentPaging/ServiceOncall/ReadModel.hs",
                backupPath = ".keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/Generated/IncidentPaging/Service_oncall/ReadModel.hs",
                contentDigest = Nothing,
                transformedDigest = Nothing
              }
          ]
    it "rewrites code-token module references while preserving comments and literals" $ do
      let old = "Generated.IncidentPaging.Service_oncall.ReadModel"
          new = "Generated.IncidentPaging.ServiceOncall.ReadModel"
          source =
            T.unlines
              [ "module IncidentPaging.Service_oncall.ReadModelHoles where",
                "import Generated.IncidentPaging.Service_oncall.ReadModel",
                "value = Generated.IncidentPaging.Service_oncall.ReadModel.constructor",
                "-- Generated.IncidentPaging.Service_oncall.ReadModel in a comment",
                "literal = \"Generated.IncidentPaging.Service_oncall.ReadModel\"",
                "character = 'x'",
                "{- outer {- Generated.IncidentPaging.Service_oncall.ReadModel -} comment -}"
              ]
      case rewriteHaskellModuleReferences (Map.singleton old new) source of
        Left err -> expectationFailure (show err)
        Right rewritten -> do
          rewritten `shouldSatisfy` T.isInfixOf "import Generated.IncidentPaging.ServiceOncall.ReadModel"
          rewritten `shouldSatisfy` T.isInfixOf "value = Generated.IncidentPaging.ServiceOncall.ReadModel.constructor"
          rewritten `shouldSatisfy` T.isInfixOf "-- Generated.IncidentPaging.Service_oncall.ReadModel in a comment"
          rewritten `shouldSatisfy` T.isInfixOf "literal = \"Generated.IncidentPaging.Service_oncall.ReadModel\""
          rewritten `shouldSatisfy` T.isInfixOf "{- outer {- Generated.IncidentPaging.Service_oncall.ReadModel -} comment -}"
    it "requires both flags when a legacy ledger needs only sidecar renames" $ do
      withTempDirectory "keiro-dsl-sidecar-only-name-migration" $ \out -> do
        spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
        let service = legacyCheckedService spec
            ctx = defaultContext (spec.context)
        modules <- case planTestServiceScaffold ctx service of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right planned -> pure planned
        initial <- executeServiceScaffoldWithRuntimePackageAndMigrations Nothing False False out False "incident-paging.keiro" LegacyUnversioned ctx service modules
        case initial of
          Left refusals -> expectationFailure (show refusals)
          Right _ -> pure ()
        let recordPath = out </> recordFileName (spec.context)
            fragmentPath = out </> contextCabalFragmentFileName (spec.context)
        currentRecord <-
          TIO.readFile recordPath >>= \contents ->
            maybe (expectationFailure "fresh scaffold record did not parse" >> fail "unreachable") pure (parseRecord contents)
        TIO.writeFile recordPath (renderRecord (scaffoldRecordWithEdition LegacyNamingV1 currentRecord))
        renameFile recordPath (out </> legacyContextRecordFileName (spec.context))
        renameFile fragmentPath (out </> legacyContextManifestFileName (spec.context))
        nameOnly <- executeServiceScaffoldWithRuntimePackageAndMigrations Nothing True False out False "incident-paging.keiro" LegacyUnversioned ctx service modules
        nameOnly `shouldSatisfy` \case
          Left [NameMigrationRequired [], GeneratedHaskellEditionRequired impact, SidecarMovesAlreadyApplied sidecars] ->
            (.fromEdition) impact == LegacyNamingV1 && length sidecars == 2
          _ -> False

      withTempDirectory "keiro-dsl-workspace-sidecar-only-name-migration" $ \out -> do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        plan <- shouldPlanWorkspaceSpec workspace
        initial <- executeWorkspaceScaffold out False plan
        case initial of
          Left refusals -> expectationFailure (show refusals)
          Right _ -> pure ()
        let service = (.service) workspace
            recordPath = out </> workspaceRecordFileName service
            fragmentPath = out </> workspaceManifestFileName service
        currentRecord <-
          TIO.readFile recordPath >>= \contents ->
            maybe (expectationFailure "fresh workspace record did not parse" >> fail "unreachable") pure (parseWorkspaceRecord contents)
        TIO.writeFile recordPath (renderWorkspaceRecord (workspaceRecordWithEditionAndModules LegacyNamingV1 currentRecord.modules currentRecord))
        renameFile recordPath (out </> legacyWorkspaceRecordFileName service)
        renameFile fragmentPath (out </> legacyWorkspaceManifestFileName service)
        nameOnly <- executeWorkspaceScaffoldWithMigrations out False True False plan
        nameOnly `shouldSatisfy` \case
          Left [NameMigrationRequired [], GeneratedHaskellEditionRequired impact, SidecarMovesAlreadyApplied sidecars] ->
            (.fromEdition) impact == LegacyNamingV1 && length sidecars == 2
          _ -> False
    it "refuses without mutation, then applies recoverable generated and hole moves" $
      withTempDirectory "keiro-dsl-name-migration" $ \out -> do
        spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
        let service = legacyCheckedService spec
            ctx = defaultContext (spec.context)
        modules <- case planTestServiceScaffold ctx service of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right planned -> pure planned
        let selected =
              [ scaffoldModule
              | scaffoldModule <- modules,
                any (`T.isSuffixOf` T.pack ((.path) scaffoldModule)) ["ServiceOncall/ReadModel.hs", "ServiceOncall/ReadModelHoles.hs"]
              ]
            legacyPath = T.unpack . T.replace "ServiceOncall" "Service_oncall" . T.pack
            reverseModules =
              Map.fromList
                [ (moduleNameFromPath ((.path) scaffoldModule), moduleNameFromPath (legacyPath ((.path) scaffoldModule)))
                | scaffoldModule <- selected
                ]
        forM_ selected $ \scaffoldModule -> do
          legacyText <- case rewriteHaskellModuleReferences reverseModules ((.text) scaffoldModule) of
            Left err -> expectationFailure (show err) >> fail "unreachable"
            Right source -> pure source
          let oldPath = out </> legacyPath ((.path) scaffoldModule)
              withEvidence
                | (.kind) scaffoldModule == HoleStub =
                    legacyText
                      <> "\n-- Generated.IncidentPaging.Service_oncall.ReadModel remains in this comment\n"
                      <> "migrationLiteral = \"Generated.IncidentPaging.Service_oncall.ReadModel\"\n"
                | otherwise = legacyText
          createDirectoryIfMissing True (takeDirectory oldPath)
          TIO.writeFile oldPath withEvidence
        let legacyRecord =
              ScaffoldRecord
                { specPath = "incident-paging.keiro",
                  moduleRoot = "",
                  layout = "prefixed",
                  sourceLanguage = LegacyUnversioned,
                  languageContract = effectiveLanguageContract LegacyUnversioned,
                  namingEdition = LegacyNamingV1,
                  moduleRoles = [],
                  files = [((.kind) scaffoldModule, legacyPath ((.path) scaffoldModule)) | scaffoldModule <- selected],
                  mappings = [],
                  idDomains = [],
                  nominalEqualities = [],
                  bindingObligations = [],
                  behaviorRequirements = [],
                  projectionCatalogFacts = [],
                  queryContractBaseline = False,
                  queryContracts = [],
                  routerSelections = [],
                  semanticImpact = Nothing
                }
            recordPath = out </> recordFileName (spec.context)
        TIO.writeFile recordPath (renderRecord legacyRecord)
        let currentFragment = out </> contextCabalFragmentFileName (spec.context)
            legacyRecordPath = out </> legacyContextRecordFileName (spec.context)
            legacyFragmentPath = out </> legacyContextManifestFileName (spec.context)
        TIO.writeFile currentFragment "legacy cabal fragment\n"
        renameFile recordPath legacyRecordPath
        renameFile currentFragment legacyFragmentPath
        beforeMigration <- treeSnapshot out
        refused <- executeServiceScaffoldWithRuntimePackageAndNameMigrations Nothing False out False "incident-paging.keiro" LegacyUnversioned ctx service modules
        refused `shouldSatisfy` \case
          Left [SidecarMigrationRequired sidecars, GeneratedHaskellEditionRequired impact] ->
            length sidecars == 2 && (.fromEdition) impact == LegacyNamingV1
          _ -> False
        renderRefusals (either id (const []) refused)
          `shouldSatisfy` any (T.isInfixOf "needs both --apply-name-migrations and --apply-generated-haskell-edition")
        treeSnapshot out `shouldReturn` beforeMigration

        nameOnly <- executeServiceScaffoldWithRuntimePackageAndMigrations Nothing True False out False "incident-paging.keiro" LegacyUnversioned ctx service modules
        nameOnly `shouldSatisfy` \case
          Left [NameMigrationRequired moves, GeneratedHaskellEditionRequired impact, SidecarMovesAlreadyApplied sidecars] ->
            length moves == 2
              && all ((/= Nothing) . (.contentDigest)) moves
              && all ((/= Nothing) . (.transformedDigest)) moves
              && (.fromEdition) impact == LegacyNamingV1
              && length sidecars == 2
          _ -> False
        applied <- executeServiceScaffoldWithRuntimePackageAndMigrations Nothing True True out False "incident-paging.keiro" LegacyUnversioned ctx service modules
        report <- case applied of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right value -> pure value
        length ((.nameMoves) report) `shouldBe` 2
        let editionBackupRoot = out </> ".keiro-dsl-generated-haskell-migrations/legacy-v1-to-idiomatic-v2"
        doesFileExist (editionBackupRoot </> recordFileName (spec.context)) `shouldReturn` True
        doesFileExist (editionBackupRoot </> contextCabalFragmentFileName (spec.context)) `shouldReturn` True
        remediation <- TIO.readFile (editionBackupRoot </> "remediation-report.txt")
        remediation `shouldSatisfy` T.isInfixOf "source-moves: 2"
        remediation `shouldSatisfy` T.isInfixOf "Service_oncall/ReadModel.hs -> Generated/IncidentPaging/ServiceOncall/ReadModel.hs"
        let newHole = out </> "IncidentPaging/ServiceOncall/ReadModelHoles.hs"
            oldHole = out </> "IncidentPaging/Service_oncall/ReadModelHoles.hs"
            backupHole = out </> ".keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/IncidentPaging/Service_oncall/ReadModelHoles.hs"
        doesFileExist oldHole `shouldReturn` False
        doesFileExist newHole `shouldReturn` True
        doesFileExist backupHole `shouldReturn` True
        migratedHole <- TIO.readFile newHole
        migratedHole `shouldSatisfy` T.isInfixOf "module IncidentPaging.ServiceOncall.ReadModelHoles"
        migratedHole `shouldSatisfy` T.isInfixOf "-- Generated.IncidentPaging.Service_oncall.ReadModel remains in this comment"
        migratedHole `shouldSatisfy` T.isInfixOf "migrationLiteral = \"Generated.IncidentPaging.Service_oncall.ReadModel\""
        backupBefore <- TIO.readFile backupHole
        rerun <- executeServiceScaffoldWithRuntimePackageAndMigrations Nothing True True out False "incident-paging.keiro" LegacyUnversioned ctx service modules
        case rerun of
          Left refusals -> expectationFailure (show refusals)
          Right rerunReport -> (.nameMoves) rerunReport `shouldBe` []
        TIO.readFile backupHole `shouldReturn` backupBefore
        -- Recreate the exact crash state after every backup and prepared file
        -- exists but before any destination is installed. A corrupted prepared
        -- file refuses; restoring its digest lets the next run resume.
        preparedSnapshots <- forM selected $ \scaffoldModule -> do
          let newPath = out </> (.path) scaffoldModule
              preparedPath = newPath <> ".keiro-dsl-name-migration-prepared"
          bytes <- TIO.readFile newPath
          renameFile newPath preparedPath
          pure (preparedPath, bytes)
        -- This is specifically the name-move crash state. Keep the ledger at
        -- the current presentation edition so the independent edition-backup
        -- conflict gate does not mask the prepared-source digest check.
        TIO.writeFile recordPath (renderRecord (scaffoldRecordWithEdition IdiomaticNamingV2 legacyRecord))
        case preparedSnapshots of
          (firstPrepared, firstBytes) : _ -> TIO.writeFile firstPrepared (firstBytes <> "\ncorrupt")
          [] -> expectationFailure "expected prepared migration sources"
        conflicted <- executeServiceScaffoldWithRuntimePackageAndMigrations Nothing True True out False "incident-paging.keiro" LegacyUnversioned ctx service modules
        conflicted `shouldSatisfy` \case Left [NameMigrationRefusal messages] -> any (T.isInfixOf "prepared source digest") messages; _ -> False
        forM_ preparedSnapshots (uncurry TIO.writeFile)
        resumed <- executeServiceScaffoldWithRuntimePackageAndMigrations Nothing True True out False "incident-paging.keiro" LegacyUnversioned ctx service modules
        case resumed of
          Left refusals -> expectationFailure (show refusals)
          Right resumedReport -> length ((.nameMoves) resumedReport) `shouldBe` 2
        doesFileExist newHole `shouldReturn` True
        TIO.readFile backupHole `shouldReturn` backupBefore
    it "applies the same move protocol to a two-member workspace without changing ownership" $
      withTempDirectory "keiro-dsl-workspace-name-migration" $ \out -> do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        plan <- shouldPlanWorkspaceSpec workspace
        initial <- executeWorkspaceScaffold out False plan
        case initial of
          Left refusals -> expectationFailure (show refusals)
          Right _ -> pure ()
        let recordPath = out </> workspaceRecordFileName ((.service) workspace)
        currentRecord <-
          TIO.readFile recordPath >>= \contents ->
            maybe (expectationFailure "fresh workspace record did not parse" >> fail "unreachable") pure (parseWorkspaceRecord contents)
        let selectedRows = [row | row <- (.modules) currentRecord, "ProjectActivity" `T.isInfixOf` T.pack ((.path) row)]
            legacyPath = T.unpack . T.replace "ProjectActivity" "Project_activity" . T.pack
            reverseModules =
              Map.fromList
                [ (moduleNameFromPath ((.path) row), moduleNameFromPath (legacyPath ((.path) row)))
                | row <- selectedRows
                ]
        selectedRows `shouldSatisfy` (not . null)
        forM_ selectedRows $ \row -> do
          currentSource <- TIO.readFile (out </> (.path) row)
          legacySource <- case rewriteHaskellModuleReferences reverseModules currentSource of
            Left err -> expectationFailure (show err) >> fail "unreachable"
            Right source -> pure source
          writeFileWithParents (out </> legacyPath ((.path) row)) legacySource
          removeFile (out </> (.path) row)
        let legacyRecord =
              workspaceRecordWithEditionAndModules
                LegacyNamingV1
                [ if row `elem` selectedRows then workspaceModuleRowWithPath (legacyPath row.path) row else row
                | row <- currentRecord.modules
                ]
                currentRecord
            ownersBefore = Map.fromList [((.role) row, (.owner) row) | row <- selectedRows]
        TIO.writeFile recordPath (renderWorkspaceRecord legacyRecord)
        let currentFragment = out </> workspaceManifestFileName ((.service) workspace)
            legacyRecordPath = out </> legacyWorkspaceRecordFileName ((.service) workspace)
            legacyFragmentPath = out </> legacyWorkspaceManifestFileName ((.service) workspace)
        renameFile recordPath legacyRecordPath
        renameFile currentFragment legacyFragmentPath
        beforeMigration <- treeSnapshot out
        refused <- executeWorkspaceScaffoldWithNameMigrations out False False plan
        refused `shouldSatisfy` \case
          Left [SidecarMigrationRequired sidecars, GeneratedHaskellEditionRequired impact] ->
            length sidecars == 2 && (.fromEdition) impact == LegacyNamingV1
          _ -> False
        treeSnapshot out `shouldReturn` beforeMigration
        nameOnly <- executeWorkspaceScaffoldWithMigrations out False True False plan
        nameOnly `shouldSatisfy` \case
          Left [NameMigrationRequired moves, GeneratedHaskellEditionRequired impact, SidecarMovesAlreadyApplied sidecars] ->
            length moves == length selectedRows
              && (.fromEdition) impact == LegacyNamingV1
              && length sidecars == 2
          _ -> False
        applied <- executeWorkspaceScaffoldWithMigrations out False True True plan
        report <- case applied of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right value -> pure value
        length ((.nameMoves) report) `shouldBe` length selectedRows
        let editionBackupRoot = out </> ".keiro-dsl-generated-haskell-migrations/legacy-v1-to-idiomatic-v2"
        doesFileExist (editionBackupRoot </> workspaceRecordFileName ((.service) workspace)) `shouldReturn` True
        doesFileExist (editionBackupRoot </> workspaceManifestFileName ((.service) workspace)) `shouldReturn` True
        remediation <- TIO.readFile (editionBackupRoot </> "remediation-report.txt")
        remediation `shouldSatisfy` T.isInfixOf ("source-moves: " <> T.pack (show (length selectedRows)))
        migratedRecord <-
          TIO.readFile recordPath >>= \contents ->
            maybe (expectationFailure "migrated workspace record did not parse" >> fail "unreachable") pure (parseWorkspaceRecord contents)
        (.namingEdition) migratedRecord `shouldBe` IdiomaticNamingV2
        let migratedRows = [row | row <- (.modules) migratedRecord, (.role) row `Map.member` ownersBefore]
        Map.fromList [((.role) row, (.owner) row) | row <- migratedRows] `shouldBe` ownersBefore
        map (.path) migratedRows `shouldSatisfy` all (not . T.isInfixOf "Project_activity" . T.pack)
        forM_ selectedRows $ \row -> do
          doesFileExist (out </> legacyPath ((.path) row)) `shouldReturn` False
          doesFileExist (out </> (.path) row) `shouldReturn` True
          doesFileExist (out </> ".keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1" </> legacyPath ((.path) row)) `shouldReturn` True

  describe "generated Haskell edition migration" $ do
    it "refuses without mutation and adopts idiomatic-v2 with durable backups while preserving Hole bytes" $
      withTempDirectory "keiro-dsl-generated-haskell-edition" $ \out -> do
        parsed <- parsedSourceOf "test/fixtures/behavior-complete.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            sourceLanguage = (.sourceLanguage) parsed
        modules <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffold ctx service)
        let runAt applyEdition =
              executeServiceScaffoldWithRuntimePackageAndMigrations
                Nothing
                False
                applyEdition
                out
                False
                "behavior-complete.keiro"
                sourceLanguage
                ctx
                service
                modules
        _ <- runAt False >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        let recordPath = out </> recordFileName (spec.context)
            backupRoot = out </> ".keiro-dsl-generated-haskell-migrations/legacy-v1-to-idiomatic-v2"
        currentRecord <-
          TIO.readFile recordPath >>= \contents ->
            maybe (expectationFailure "fresh scaffold record did not parse" >> fail "unreachable") pure (parseRecord contents)
        let legacyRecord = scaffoldRecordWithEdition LegacyNamingV1 currentRecord
            behaviorHole =
              head
                [ out </> (.path) scaffoldModule
                | scaffoldModule <- modules,
                  (.kind) scaffoldModule == HoleStub,
                  "BehaviorHoles.hs" `T.isSuffixOf` T.pack ((.path) scaffoldModule)
                ]
        TIO.writeFile recordPath (renderRecord legacyRecord)
        originalHole <- TIO.readFile behaviorHole
        let legacyHole =
              originalHole
                <> T.unlines
                  [ "",
                    "editionMigrationPrefix f = failureCode f",
                    "editionMigrationQualified f = BC.failureCode f",
                    "editionMigrationDot f = f.failureCode",
                    "editionMigrationField f = f {failureCode = \"x\"}",
                    "editionMigrationOperator fs = failureCode <$> fs",
                    "-- failureCode f",
                    "editionMigrationCurrent f = f.code"
                  ]
        TIO.writeFile behaviorHole legacyHole
        beforeRefusal <- treeSnapshot out
        refused <- runAt False
        refused `shouldSatisfy` \case
          Left [GeneratedHaskellEditionRequired impact] ->
            (.fromEdition) impact == LegacyNamingV1
              && not (null ((.generatedPaths) impact))
              && length ((.sidecarPaths) impact) == 2
              && Set.fromList [((.current) use, (.form) use) | use <- (.handOwnedUses) impact]
                == Set.fromList
                  [ ("failureCode", PrefixApplication),
                    ("failureCode", QualifiedApplication),
                    ("failureCode", RecordDotRenamed),
                    ("failureCode", RecordFieldBinding),
                    ("failureCode", OperatorOperand)
                  ]
          _ -> False
        renderRefusals (either id (const []) refused)
          `shouldSatisfy` \lines' ->
            any (T.isInfixOf "--apply-generated-haskell-edition") lines'
              && any (T.isInfixOf "legacy-v1 -> idiomatic-v2") lines'
        treeSnapshot out `shouldReturn` beforeRefusal

        _ <- runAt True >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        TIO.readFile behaviorHole `shouldReturn` legacyHole
        backupRecord <- TIO.readFile (backupRoot </> recordFileName (spec.context))
        backupRecord `shouldSatisfy` T.isInfixOf "naming-edition legacy-v1"
        adoptedRecord <- TIO.readFile recordPath
        adoptedRecord `shouldSatisfy` T.isInfixOf "naming-edition idiomatic-v2"
        remediation <- TIO.readFile (backupRoot </> "remediation-report.txt")
        remediation `shouldSatisfy` T.isInfixOf "failureCode (PrefixApplication) -> record.code"
        remediation `shouldSatisfy` T.isInfixOf "attributable uses only"

        backedUpFiles <- treeSnapshot backupRoot
        forM_ backedUpFiles $ \(path, contents) ->
          unless (path == "remediation-report.txt") (writeFileWithParents (out </> path) contents)
        TIO.writeFile behaviorHole originalHole
        _ <- runAt True >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        refreshedRemediation <- TIO.readFile (backupRoot </> "remediation-report.txt")
        refreshedRemediation `shouldSatisfy` T.isInfixOf "hand-owned-selector-uses: 0"
        rerun <- runAt False
        case rerun of
          Left failures -> expectationFailure (show failures)
          Right _ -> pure ()
    it "uses the same refusal and backup protocol for a workspace ledger" $
      withTempDirectory "keiro-dsl-workspace-generated-haskell-edition" $ \out -> do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        plan <- shouldPlanWorkspaceSpec workspace
        _ <- executeWorkspaceScaffold out False plan >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        let recordPath = out </> workspaceRecordFileName ((.service) workspace)
            backupRecord =
              out
                </> ".keiro-dsl-generated-haskell-migrations/legacy-v1-to-idiomatic-v2"
                </> workspaceRecordFileName ((.service) workspace)
        currentRecord <- TIO.readFile recordPath
        TIO.writeFile recordPath (T.unlines (filter (not . T.isPrefixOf "naming-edition ") (T.lines currentRecord)))
        beforeRefusal <- treeSnapshot out
        refused <- executeWorkspaceScaffoldWithMigrations out False False False plan
        refused `shouldSatisfy` \case
          Left [GeneratedHaskellEditionRequired impact] ->
            (.fromEdition) impact == LegacyNamingV1 && not (null ((.generatedPaths) impact))
          _ -> False
        treeSnapshot out `shouldReturn` beforeRefusal
        _ <- executeWorkspaceScaffoldWithMigrations out False False True plan >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        backedUp <- TIO.readFile backupRecord
        backedUp `shouldSatisfy` (not . T.isInfixOf "naming-edition ")
        adopted <- TIO.readFile recordPath
        adopted `shouldSatisfy` T.isInfixOf "naming-edition idiomatic-v2"
    it "refuses an unreadable single-spec ledger without changing the tree" $
      withTempDirectory "keiro-dsl-unreadable-ledger" $ \out -> do
        parsed <- parsedSourceOf "test/fixtures/behavior-complete.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            sourceLanguage = (.sourceLanguage) parsed
        modules <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffold ctx service)
        let run =
              executeServiceScaffoldWithRuntimePackageAndMigrations
                Nothing
                False
                False
                out
                False
                "behavior-complete.keiro"
                sourceLanguage
                ctx
                service
                modules
            recordPath = out </> recordFileName (spec.context)
        _ <- run >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        TIO.appendFile recordPath "spec: duplicate.keiro\n"
        before <- treeSnapshot out
        run `shouldReturn` Left [LedgerUnreadable recordPath]
        treeSnapshot out `shouldReturn` before
    it "refuses an unreadable workspace ledger without changing the tree" $
      withTempDirectory "keiro-dsl-workspace-unreadable-ledger" $ \out -> do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        plan <- shouldPlanWorkspaceSpec workspace
        _ <- executeWorkspaceScaffold out False plan >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        let recordPath = out </> workspaceRecordFileName ((.service) workspace)
        TIO.appendFile recordPath "service: duplicate\n"
        before <- treeSnapshot out
        executeWorkspaceScaffoldWithMigrations out False False False plan
          `shouldReturn` Left [LedgerUnreadable recordPath]
        treeSnapshot out `shouldReturn` before
    it "refuses a tampered edition backup without changing the tree" $
      withTempDirectory "keiro-dsl-tampered-edition-backup" $ \out -> do
        parsed <- parsedSourceOf "test/fixtures/behavior-complete.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            sourceLanguage = (.sourceLanguage) parsed
        modules <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffold ctx service)
        let runAt applyEdition =
              executeServiceScaffoldWithRuntimePackageAndMigrations Nothing False applyEdition out False "behavior-complete.keiro" sourceLanguage ctx service modules
            recordPath = out </> recordFileName (spec.context)
            backupRoot = out </> ".keiro-dsl-generated-haskell-migrations/idiomatic-v1-to-idiomatic-v2"
        _ <- runAt False >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        currentRecord <- TIO.readFile recordPath >>= maybe (fail "fresh record did not parse") pure . parseRecord
        TIO.writeFile recordPath (renderRecord (scaffoldRecordWithEdition IdiomaticNamingV1 currentRecord))
        _ <- runAt True >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        backedUpFiles <- treeSnapshot backupRoot
        forM_ backedUpFiles $ \(path, contents) ->
          unless (path == "remediation-report.txt") (writeFileWithParents (out </> path) contents)
        let generatedBackup =
              head [path | (path, _) <- backedUpFiles, takeExtension path == ".hs"]
        TIO.appendFile (backupRoot </> generatedBackup) "\n-- tampered\n"
        beforeRefusal <- treeSnapshot out
        refused <- runAt True
        refused `shouldSatisfy` \case
          Left [GeneratedHaskellEditionRefusal [reason]] -> T.pack generatedBackup `T.isInfixOf` reason
          _ -> False
        treeSnapshot out `shouldReturn` beforeRefusal
    it "detects an interrupted apply while the ledger is pre-current and recovers after restoring backups" $
      withTempDirectory "keiro-dsl-interrupted-edition-apply" $ \out -> do
        parsed <- parsedSourceOf "test/fixtures/behavior-complete.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            sourceLanguage = (.sourceLanguage) parsed
        modules <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffold ctx service)
        let runAt applyEdition =
              executeServiceScaffoldWithRuntimePackageAndMigrations Nothing False applyEdition out False "behavior-complete.keiro" sourceLanguage ctx service modules
            recordRelative = recordFileName (spec.context)
            recordPath = out </> recordRelative
            backupRoot = out </> ".keiro-dsl-generated-haskell-migrations/idiomatic-v1-to-idiomatic-v2"
        _ <- runAt False >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        currentRecord <- TIO.readFile recordPath >>= maybe (fail "fresh record did not parse") pure . parseRecord
        TIO.writeFile recordPath (renderRecord (scaffoldRecordWithEdition IdiomaticNamingV1 currentRecord))
        forM_ [out </> path | (Generated, path) <- (.files) currentRecord] $ \path ->
          TIO.appendFile path "\n-- pre-adoption edition bytes\n"
        initialRefusal <- runAt False
        generatedCount <- case initialRefusal of
          Left [GeneratedHaskellEditionRequired impact] -> pure (length ((.generatedPaths) impact))
          other -> expectationFailure (show other) >> fail "unreachable"
        _ <- runAt True >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        cleanApply <- treeSnapshot out
        -- Conflict detection is active only while the ledger records a
        -- pre-current edition; restoring just that ledger models interruption.
        TIO.readFile (backupRoot </> recordRelative) >>= TIO.writeFile recordPath
        interrupted <- runAt True
        interrupted `shouldSatisfy` \case
          Left [GeneratedHaskellEditionRefusal reasons] ->
            length reasons == generatedCount && all (T.isInfixOf "edition backup conflict") reasons
          _ -> False
        backedUpFiles <- treeSnapshot backupRoot
        forM_ backedUpFiles $ \(path, contents) ->
          unless (path == "remediation-report.txt") (writeFileWithParents (out </> path) contents)
        _ <- runAt True >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        treeSnapshot out `shouldReturn` cleanApply
    it "drives the built CLI through refusal, apply, and idempotent rerun" $
      withTempDirectory "keiro-dsl-edition-cli" $ \out -> do
        let fixture = "test/fixtures/behavior-complete.keiro"
        (initialCode, _, _) <- runKeiroDsl ["scaffold", fixture, "--out", out]
        initialCode `shouldBe` ExitSuccess
        spec <- specOf fixture
        let recordPath = out </> recordFileName (spec.context)
        currentRecord <- TIO.readFile recordPath
        TIO.writeFile recordPath (T.replace "naming-edition idiomatic-v2" "naming-edition idiomatic-v1" currentRecord)
        beforeRefusal <- treeSnapshot out
        (refusalCode, _, refusalError) <- runKeiroDsl ["scaffold", fixture, "--out", out]
        refusalCode `shouldBe` ExitFailure 1
        refusalError `shouldSatisfy` isInfixOf "generated Haskell edition migration required: idiomatic-v1 -> idiomatic-v2"
        treeSnapshot out `shouldReturn` beforeRefusal
        (applyCode, _, _) <- runKeiroDsl ["scaffold", fixture, "--out", out, "--apply-generated-haskell-edition"]
        applyCode `shouldBe` ExitSuccess
        afterApply <- treeSnapshot out
        (rerunCode, _, _) <- runKeiroDsl ["scaffold", fixture, "--out", out, "--apply-generated-haskell-edition"]
        rerunCode `shouldBe` ExitSuccess
        treeSnapshot out `shouldReturn` afterApply

  describe "generated Haskell presentation rewrite" $ do
    it "keeps Template Haskell quotes and promoted ticks in Code" $ do
      modernizeGeneratedHaskellSourceWithState "x = ''Foo\ny = sourceFile r\n"
        `shouldBe` ("x = ''Foo\ny = file r\n", Code)
      modernizeGeneratedHaskellSourceWithState "x = '[]\ny = sourceFile r\n"
        `shouldBe` ("x = '[]\ny = file r\n", Code)
      modernizeGeneratedHaskellSourceWithState "x = a --> sourceFile r\n"
        `shouldBe` ("x = a --> file r\n", Code)
    it "finishes every tracked Generated module in Code" $ do
      (rootCode, repositoryRootOutput, rootError) <- readProcessWithExitCode "git" ["rev-parse", "--show-toplevel"] ""
      rootCode `shouldBe` ExitSuccess
      rootError `shouldBe` ""
      let repositoryRoot = takeWhile (/= '\n') repositoryRootOutput
      (filesCode, trackedOutput, filesError) <- readProcessWithExitCode "git" ["-C", repositoryRoot, "ls-files", "keiro-dsl/test"] ""
      filesCode `shouldBe` ExitSuccess
      filesError `shouldBe` ""
      let generatedPaths = [path | path <- lines trackedOutput, "/Generated/" `isInfixOf` path]
      generatedPaths `shouldSatisfy` (not . null)
      forM_ generatedPaths $ \path -> do
        source <- TIO.readFile (repositoryRoot </> path)
        let (_, finalState) = modernizeGeneratedHaskellSourceWithState source
        unless (finalState == Code) (expectationFailure (path <> " ended in " <> show finalState))

  describe "sidecar migration (EP-198)" $ do
    it "refuses old context names, applies lossless moves, preserves stale history, and is idempotent" $
      withTempDirectory "keiro-dsl-sidecar-migration" $ \base -> do
        parsed <- parsedSourceOf "test/fixtures/reservation.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            sourceLanguage = (.sourceLanguage) parsed
            plain = base </> "plain"
            migrated = base </> "migrated"
            runAt out apply specPath selected =
              executeServiceScaffoldWithRuntimePackageAndNameMigrations
                Nothing
                apply
                out
                False
                specPath
                sourceLanguage
                ctx
                service
                selected
        modules <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffold ctx service)
        _ <- runAt plain False "reservation.keiro" modules >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        _ <- runAt migrated False "reservation.keiro" modules >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        let reduced = drop 1 modules
            currentLedger = contextLedgerFileName (spec.context)
            currentFragment = contextCabalFragmentFileName (spec.context)
            oldLedger = legacyContextRecordFileName (spec.context)
            oldFragment = legacyContextManifestFileName (spec.context)
        renameFile (migrated </> currentLedger) (migrated </> oldLedger)
        renameFile (migrated </> currentFragment) (migrated </> oldFragment)
        treeBefore <- treeSnapshot migrated
        refused <- runAt migrated False "reservation-reduced.keiro" reduced
        refused `shouldSatisfy` \case
          Left [SidecarMigrationRequired moves] ->
            length moves == 2
              && all ((== RenameSidecar) . (.moveDisposition)) moves
          _ -> False
        renderRefusals (either id (const []) refused)
          `shouldSatisfy` any (T.isInfixOf "--apply-name-migrations")
        treeSnapshot migrated `shouldReturn` treeBefore

        baseline <- runAt plain False "reservation-reduced.keiro" reduced >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        applied <- runAt migrated True "reservation-reduced.keiro" reduced >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        map (.moveDisposition) ((.sidecarMoves) applied) `shouldBe` [RenameSidecar, RenameSidecar]
        (.stale) applied `shouldBe` (.stale) baseline
        (.previousSpecPath) applied `shouldBe` Just "reservation.keiro"
        doesFileExist (migrated </> oldLedger) `shouldReturn` False
        doesFileExist (migrated </> oldFragment) `shouldReturn` False
        doesFileExist (migrated </> currentLedger) `shouldReturn` True
        doesFileExist (migrated </> currentFragment) `shouldReturn` True

        rerun <- runAt migrated True "reservation-reduced.keiro" reduced >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        (.sidecarMoves) rerun `shouldBe` []

        let duplicateBytes = "legacy duplicate cabal fragment\n"
            backup = migrated </> ".keiro-dsl-name-migrations/sidecar-v1" </> oldFragment
        TIO.writeFile (migrated </> oldFragment) duplicateBytes
        duplicateRefusal <- runAt migrated False "reservation-reduced.keiro" reduced
        duplicateRefusal `shouldSatisfy` \case
          Left [SidecarMigrationRequired [move]] -> (.moveDisposition) move == RetireLegacySidecar
          _ -> False
        retired <- runAt migrated True "reservation-reduced.keiro" reduced >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        map (.moveDisposition) ((.sidecarMoves) retired) `shouldBe` [RetireLegacySidecar]
        doesFileExist (migrated </> oldFragment) `shouldReturn` False
        TIO.readFile backup `shouldReturn` duplicateBytes

  describe "Haskell.name-diff" $ do
    it "classifies a workqueue payload type rename only on consumer-build" $ do
      base <- specOf "test/fixtures/reservation-work.keiro"
      let renamed = mapWorkqueue (workqueueWithPayloadName "ReservationJob") base
          findings = generatedHaskellNameFindings (diffSpecs base renamed)
      case findings of
        [finding] -> assertGeneratedHaskellNameFinding finding
        values -> expectationFailure ("expected one payload-name finding, got " <> show (length values))
      let workspaceFindings =
            generatedHaskellNameFindings
              (map (.change) (diffWorkspaces (oneMemberWorkspace "queue.keiro" base) (oneMemberWorkspace "queue.keiro" renamed)))
      workspaceFindings `shouldSatisfy` \case [finding] -> isAdvisory finding; _ -> False
      replayImpactSpecs base renamed `shouldBe` ReplayNeutral
    it "pairs a mapped selector rename by unchanged wire key and keeps fold identity stable" $ do
      source <- readTestText "test/fixtures/consumer-types.keiro"
      base <- parseInlineSpec "<mapped-selector-old>" source
      renamed <-
        parseInlineSpec
          "<mapped-selector-new>"
          (T.replace "key         as \"key\"" "artifactKey as \"key\"" source)
      let findings = generatedHaskellNameFindings (diffSpecs base renamed)
      case findings of
        [finding] -> do
          assertGeneratedHaskellNameFinding finding
          (.subject) (kindOfChange finding) `shouldSatisfy` T.isInfixOf "artifactKey"
        values -> expectationFailure ("expected one selector-name finding, got " <> show (length values))
      replayImpactSpecs base renamed `shouldBe` ReplayNeutral
      legacyAggregateFoldFingerprint base (onlyAggregate base)
        `shouldBe` legacyAggregateFoldFingerprint renamed (onlyAggregate renamed)
    it "pairs a workqueue module rename by unchanged explicit runtime facts" $ do
      base <- specOf "test/fixtures/reservation-work.keiro"
      let queueOnly = specWithNodes [node | node@NWorkqueue {} <- base.nodes] base
          renamed = mapWorkqueue (workqueueWithName "reservation_jobs") queueOnly
          findings = generatedHaskellNameFindings (diffSpecs queueOnly renamed)
      case findings of
        [finding] -> do
          assertGeneratedHaskellNameFinding finding
          (.facet) (kindOfChange finding) `shouldBe` "workqueue-module"
        values -> expectationFailure ("expected one module-name finding, got " <> show (length values))
      map ((.code) . kindOfChange) (diffSpecs queueOnly renamed) `shouldNotContain` [QueueIdentityChanged]
      replayImpactSpecs queueOnly renamed `shouldBe` ReplayNeutral
    it "emits no finding when edited logical spellings normalize identically" $ do
      base <- specOf "test/fixtures/reservation-work.keiro"
      let queueOnly = specWithNodes [node | node@NWorkqueue {} <- base.nodes] base
          recased = mapWorkqueue (workqueueWithName "reservationWork") queueOnly
      generatedHaskellNameFindings (diffSpecs queueOnly recased) `shouldBe` []

  describe "canonical reservation.keiro" $
    it "parses into the expected aggregate shape" $ do
      input <- readTestText "test/fixtures/reservation.keiro"
      case parseSpec "test/fixtures/reservation.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> do
          spec.context `shouldBe` "hospital-capacity"
          length ((.ids) spec) `shouldBe` 3
          length ((.enums) spec) `shouldBe` 3
          length ((.rules) spec) `shouldBe` 1
          case (.nodes) spec of
            [NAggregate a] -> do
              (.name) a `shouldBe` "Reservation"
              length ((.states) a) `shouldBe` 6
              length ((.commands) a) `shouldBe` 2
              length ((.events) a) `shouldBe` 2
              length ((.transitions) a) `shouldBe` 2
              map (.terminal) ((.states) a) `shouldBe` [False, False, False, True, True, True]
            other -> expectationFailure ("expected one aggregate node, got " <> show (length other))

  describe "validator" $ do
    it "accepts the canonical reservation.keiro" $ do
      codes <- errorCodesOf "test/fixtures/reservation.keiro"
      codes `shouldBe` []
    it "keeps unrelated aggregate-only specs free of inert-surface warnings" $ do
      codes <- diagnosticCodesOf "test/fixtures/reservation.keiro"
      codes
        `shouldNotContain` [ IntakeBindFlagUnenforced,
                             RmInlineSubscriptionIgnored
                           ]
    it "reports empty aggregates at their declaration under legacy and stable contracts" $ do
      spec <- specOf "test/fixtures/reservation.keiro"
      case [aggregate | NAggregate aggregate <- (.nodes) spec] of
        aggregate : _ -> do
          let emptyAggregate = aggregateWithCommandsEventsTransitions [] [] [] aggregate
              emptySpec = specWithNodes [NAggregate emptyAggregate] spec
              expectedLine = unLoc ((.loc) aggregate)
              planningCodes = [GeneratedPathCollision, GeneratedImportCycle, BehaviorDerivationInvalid, ConformanceFactKeyCollision, GeneratedPlanningInvariantViolation]
              expectedMessage =
                "aggregate 'Reservation' declares no commands, no events, and no transitions; scaffold cannot lower an empty aggregate -- declare at least one command, one event, and one transition"
          forM_ [legacyCheckedService emptySpec, stableCheckedService emptySpec] $ \service -> do
            let diagnostics = checkTestServiceDiagnostics Nothing (defaultContext (emptySpec.context)) service
            [ ((.severity) diagnostic, (.line) diagnostic, (.message) diagnostic)
              | diagnostic <- diagnostics,
                (.code) diagnostic == AggregateEmpty
              ]
              `shouldBe` [(Error, expectedLine, expectedMessage)]
            filter (`elem` planningCodes) (map (.code) diagnostics) `shouldBe` []
          scaffoldRefusals emptySpec `shouldSatisfy` any (T.isPrefixOf "AggregateEmpty:")
        [] -> expectationFailure "reservation fixture has no aggregate"
    it "reports empty contracts at their declaration under legacy and stable contracts" $ do
      spec <- specOf "test/fixtures/contract-v4.keiro"
      case [contract | NContract contract <- (.nodes) spec] of
        contract : _ -> do
          let emptyContract = contractNodeWithEvents [] contract
              emptySpec = specWithNodes [NContract emptyContract] spec
              expectedLine = unLoc ((.loc) contract)
              planningCodes = [GeneratedPathCollision, GeneratedImportCycle, BehaviorDerivationInvalid, ConformanceFactKeyCollision, GeneratedPlanningInvariantViolation]
              expectedMessage =
                "contract 'emergency' declares no events; scaffold cannot lower an empty contract -- declare at least one event"
          forM_ [legacyCheckedService emptySpec, stableCheckedService emptySpec] $ \service -> do
            let diagnostics = checkTestServiceDiagnostics Nothing (defaultContext (emptySpec.context)) service
            [ ((.severity) diagnostic, (.line) diagnostic, (.message) diagnostic)
              | diagnostic <- diagnostics,
                (.code) diagnostic == ContractEmpty
              ]
              `shouldBe` [(Error, expectedLine, expectedMessage)]
            filter (`elem` planningCodes) (map (.code) diagnostics) `shouldBe` []
          scaffoldRefusals emptySpec `shouldSatisfy` any (T.isPrefixOf "ContractEmpty:")
        [] -> expectationFailure "contract fixture has no contract"
    it "keeps a check-time error counterpart for every sampled lowering refusal class" $ do
      emitSource <- readTestText "test/fixtures/emit.keiro"
      incompleteBackoff <- parseInlineSpec "<incomplete-backoff-parity>" (T.replace "backoff constant 2s" "backoff exponential 2s" emitSource)
      baseAggregate <- parseInlineSpec "<lowering-parity>" loweringAggregateSpec
      bareTextInitial <- parseInlineSpec "<bare-text-initial-parity>" (T.replace "\"hello world\"" "hello" loweringAggregateSpec)
      unsupportedField <- parseInlineSpec "<unsupported-field-parity>" (T.replace "count:Int" "count:Json" loweringAggregateSpec)
      mappedInitial <- specOf "test/fixtures/mapped-missing-initial.keiro"
      let candidates =
            [ ("incomplete publisher backoff", incompleteBackoff),
              ("invalid register initial", bareTextInitial),
              ("unrepresentable aggregate field", unsupportedField),
              ("missing mapped register initial", mappedInitial)
            ]
      scaffoldRefusals baseAggregate `shouldBe` []
      forM_ candidates $ \(caseLabel, candidate) ->
        unless
          (not (null (scaffoldRefusals candidate)) && any ((== Error) . (.severity)) (validateSpec candidate))
          (expectationFailure (caseLabel <> " did not fail at both check and scaffold planning"))
    it "rejects policy words that generated Haskell cannot lower" $ do
      emitSpec <- specOf "test/fixtures/emit.keiro"
      intakeSpec <- specOf "test/fixtures/intake.keiro"
      let unknownOrdering = mapPublisher (publisherWithOrdering "banana") emitSpec
          unknownBackoff =
            mapPublisher
              (\publisher -> publisherWithBackoff (backoffWithKind "banana" publisher.backoff) publisher)
              emitSpec
          incompleteBackoff =
            mapPublisher
              (publisherWithBackoff (BackoffSpec "exponential" "2s" Nothing Nothing))
              emitSpec
          unknownDedupe = mapIntake (intakeWithDedupePolicy "Banana") intakeSpec
      errorCodes unknownOrdering `shouldContain` [PublisherOrderingUnknown]
      errorCodes unknownBackoff `shouldContain` [PublisherBackoffInvalid]
      errorCodes incompleteBackoff `shouldContain` [PublisherBackoffInvalid]
      errorCodes unknownDedupe `shouldContain` [IntakeDedupePolicyUnknown]
    it "gates numeric floors on the published stable language-4 contract" $ do
      emitSpec <- specOf "test/fixtures/emit.keiro"
      intakeSpec <- specOf "test/fixtures/intake.keiro"
      readModelSpec <- specOf "test/fixtures/workflow.keiro"
      let zeroContract = mapContract (contractWithSchemaVersion 0) emitSpec
          zeroAttempts = mapPublisher (publisherWithMaxAttempts 0) emitSpec
          zeroDecode = mapIntake (\intake -> intakeWithDecode (decodeWithBodySchemaVersion 0 intake.decode) intake) intakeSpec
          zeroReadModel = modifyReadModel "transferDecision" (readModelWithVersion 0) readModelSpec
          floors =
            [ (zeroContract, ContractSchemaVersionBelowMinimum),
              (zeroAttempts, PublisherMaxAttemptsBelowMinimum),
              (zeroDecode, IntakeDecodeSchemaVersionBelowMinimum),
              (zeroReadModel, ReadModelVersionBelowMinimum)
            ]
      forM_ floors $ \(candidate, expected) -> do
        serviceErrorCodes 3 candidate `shouldNotContain` [expected]
        serviceErrorCodes 4 candidate `shouldContain` [expected]
    it "rejects duplicate declarations whose generated behavior cannot work" $ do
      reservation <- specOf "test/fixtures/reservation.keiro"
      integration <- specOf "test/fixtures/emit.keiro"
      let duplicateCommandField =
            modifyAggregate
              "Reservation"
              (\aggregate -> aggregateWithCommands (updateFirst (\command -> commandWithFields (duplicateFirst command.fields) command) aggregate.commands) aggregate)
              reservation
          duplicateState = modifyAggregate "Reservation" (\aggregate -> aggregateWithStates (duplicateFirst aggregate.states) aggregate) reservation
          duplicateTransition =
            modifyAggregate
              "Reservation"
              (\aggregate -> aggregateWithTransitions (aggregate.transitions <> take 1 (reverse aggregate.transitions)) aggregate)
              reservation
          duplicateContractField =
            mapContract
              (\contract -> contractNodeWithEvents (updateFirst (\event -> contractEventWithFields (duplicateFirst event.fields) event) contract.events) contract)
              integration
          duplicateContractEvent = mapContract (\contract -> contractNodeWithEvents (duplicateFirst contract.events) contract) integration
          duplicateTopicAlias = mapContract (\contract -> contractWithTopics (duplicateFirst contract.topics) contract) integration
          cases =
            [ (duplicateCommandField, AggregateDuplicateFieldName),
              (duplicateState, AggregateDuplicateState),
              (duplicateTransition, TransitionDuplicateUnguarded),
              (duplicateContractField, ContractDuplicateFieldName),
              (duplicateContractEvent, ContractDuplicateEvent),
              (duplicateTopicAlias, ContractDuplicateTopicAlias)
            ]
      forM_ cases $ \(candidate, expected) -> errorCodes candidate `shouldContain` [expected]
    it "gates ambiguous and silently shadowed duplicate surfaces on language 4" $ do
      reservation <- specOf "test/fixtures/reservation.keiro"
      integration <- specOf "test/fixtures/emit.keiro"
      let duplicateRegister = modifyAggregate "Reservation" (\aggregate -> aggregateWithRegs (duplicateFirst aggregate.regs) aggregate) reservation
          duplicateNominal = specWithIds (duplicateFirst reservation.ids) reservation
          duplicateMap = mapEmit (\emitNode -> emitNodeWithMap (duplicateFirst emitNode.map) emitNode) integration
          shadowDiscriminator =
            mapContract
              ( \contract ->
                  contractNodeWithEvents
                    ( updateFirst
                        (\event -> contractEventWithFields (updateFirst (contractFieldWithName contract.discriminator) event.fields) event)
                        contract.events
                    )
                    contract
              )
              integration
          guardedSibling =
            modifyAggregate
              "Reservation"
              ( \aggregate ->
                  aggregateWithTransitions
                    (aggregate.transitions <> [transitionWithGuard (Just (EAtom (ABool True))) transition | transition <- take 1 (reverse aggregate.transitions)])
                    aggregate
              )
              reservation
          cases =
            [ (duplicateRegister, AggregateDuplicateRegister),
              (duplicateNominal, NominalDuplicateDeclaration),
              (duplicateMap, EmitMapDuplicateCase),
              (shadowDiscriminator, ContractFieldShadowsDiscriminator),
              (guardedSibling, TransitionUnguardedSibling)
            ]
      forM_ cases $ \(candidate, expected) -> do
        serviceErrorCodes 3 candidate `shouldNotContain` [expected]
        serviceErrorCodes 4 candidate `shouldContain` [expected]
    it "gates stable identities and external names on language 4" $ do
      workflowSpec <- specOf "test/fixtures/workflow.keiro"
      processSpec <- specOf "test/fixtures/surge-service.keiro"
      routerSpec <- specOf "test/fixtures/transfer-routing.keiro"
      integration <- specOf "test/fixtures/emit.keiro"
      let invalidIdentity = mapWorkflow (workflowWithStable "") workflowSpec
          duplicateIdentity =
            specWithNodes
              ( processSpec.nodes
                  <> [NRouter (routerWithName "surge-demo" router) | NRouter router <- routerSpec.nodes]
              )
              processSpec
          invalidTopic = mapContract (\contract -> contractWithTopics [(alias, "bad topic") | (alias, _) <- contract.topics] contract) integration
          emptyTopic = mapContract (\contract -> contractWithTopics [(alias, "") | (alias, _) <- contract.topics] contract) integration
          invalidReadModel = modifyReadModel "transferDecision" (readModelWithTable "Bad-Table") workflowSpec
          duplicateColumn = modifyReadModel "transferDecision" (\readModel -> readModelWithColumns (duplicateFirst readModel.columns) readModel) workflowSpec
          gatedCases =
            [ (invalidIdentity, RuntimeIdentityInvalid),
              (duplicateIdentity, RuntimeIdentityDuplicate),
              (invalidTopic, ContractTopicNameInvalid),
              (invalidReadModel, ReadModelIdentifierInvalid),
              (duplicateColumn, ReadModelDuplicateColumn)
            ]
      forM_ gatedCases $ \(candidate, expected) -> do
        serviceErrorCodes 3 candidate `shouldNotContain` [expected]
        serviceErrorCodes 4 candidate `shouldContain` [expected]
      serviceErrorCodes 3 emptyTopic `shouldContain` [ContractTopicNameInvalid]
      serviceErrorCodes 4 emptyTopic `shouldContain` [ContractTopicNameInvalid]
    it "gates declared integration and wire couplings on language 4" $ do
      intakeSpec <- specOf "test/fixtures/intake.keiro"
      reservation <- specOf "test/fixtures/reservation.keiro"
      let unresolvedBind =
            mapIntake
              (\intake -> intakeWithBinds (updateFirst (bindRowWithField "ghost") intake.binds) intake)
              intakeSpec
          acceptedEventBind =
            mapIntake
              (\intake -> intakeWithBinds (updateFirst (bindRowWithField "region") intake.binds) intake)
              intakeSpec
          unresolvedDedupe = mapIntake (intakeWithDedupeKey "ghost") intakeSpec
          unknownEnvelope = mapIntake (\intake -> intakeWithDecode (decodeWithEnvelope "banana policy" intake.decode) intake) intakeSpec
          mismatchedSchema = mapIntake (\intake -> intakeWithDecode (decodeWithBodySchemaVersion 2 intake.decode) intake) intakeSpec
          unresolvedAlias =
            mapContract
              (\contract -> contractNodeWithEvents (updateFirst (contractEventWithTopic "ghost") contract.events) contract)
              intakeSpec
          unsupportedWire =
            modifyAggregate
              "Reservation"
              (\aggregate -> aggregateWithWire (fmap (wireSpecWithKind "banana") aggregate.wire) aggregate)
              reservation
          cases =
            [ (unresolvedBind, IntakeBindUnresolved),
              (unresolvedDedupe, IntakeDedupeKeyUnresolved),
              (unknownEnvelope, IntakeEnvelopePolicyUnknown),
              (mismatchedSchema, IntakeDecodeSchemaVersionMismatch),
              (unresolvedAlias, ContractTopicAliasUnresolved),
              (unsupportedWire, WireClauseUnsupported)
            ]
      forM_ cases $ \(candidate, expected) -> do
        serviceErrorCodes 3 candidate `shouldNotContain` [expected]
        serviceErrorCodes 4 candidate `shouldContain` [expected]
      serviceErrorCodes 4 acceptedEventBind `shouldNotContain` [IntakeBindUnresolved]
    it "gates closed workqueue vocabularies and bounded windows on language 4" $ do
      queueSpec <- specOf "test/fixtures/reservation-work.keiro"
      intakeSpec <- specOf "test/fixtures/intake.keiro"
      emitSpec <- specOf "test/fixtures/emit.keiro"
      processSpec <- specOf "test/fixtures/hospital-surge.keiro"
      let huge = "18446744073709551618s"
          unknownPayload =
            mapWorkqueue
              (\queue -> workqueueWithPayload [if field.name == "hospitalId" then wqFieldWithValueType (LegacyQueueScalar (QueueOther "numeric")) field else field | field <- queue.payload] queue)
              queueSpec
          queueDelay = mapWorkqueue (workqueueWithDelay huge) queueSpec
          queueRetry = mapWorkqueue (\queue -> workqueueWithDisposition (updateFirst (wqDispRowWithAction (IRetry huge)) queue.disposition) queue) queueSpec
          intakeRetry = mapIntake (\intake -> intakeWithDisposition (updateFirst (dispositionRowWithAction (IRetry huge)) intake.disposition) intake) intakeSpec
          publisherBackoff = mapPublisher (\publisher -> publisherWithBackoff (backoffWithWindow huge publisher.backoff) publisher) emitSpec
          publisherMaximum =
            mapPublisher
              (\publisher -> publisherWithBackoff (BackoffSpec "exponential" publisher.backoff.window (Just huge) (Just "2")) publisher)
              emitSpec
          processFireAt =
            modifyProcess
              "HospitalSurge"
              (\process -> processWithTimer (timerWithFireAt (fireAtWithWindow huge process.timer.fireAt) process.timer) process)
              processSpec
          cases =
            [ (unknownPayload, WqPayloadTypeUnknown),
              (queueDelay, WindowOutOfRange),
              (queueRetry, WindowOutOfRange),
              (intakeRetry, WindowOutOfRange),
              (publisherBackoff, WindowOutOfRange),
              (publisherMaximum, WindowOutOfRange),
              (processFireAt, WindowOutOfRange)
            ]
      forM_ cases $ \(candidate, expected) -> do
        serviceErrorCodes 3 candidate `shouldBe` []
        serviceErrorCodes 4 candidate `shouldContain` [expected]
    -- ExecPlan 199: spellings the grammar accepted that no runtime implements.
    -- Each pair asserts both halves of the contract — the divergent spelling
    -- warns at 3 and errors at 4, and the spelling that matches the runtime
    -- stays completely silent, so these are refusals and not blanket noise.
    it "refuses spec surfaces that contradict the runtime, and stays silent on the ones that describe it" $ do
      intakeSpec <- specOf "test/fixtures/intake.keiro"
      processSpec <- specOf "test/fixtures/hospital-surge.keiro"
      routerSpec <- specOf "test/fixtures/transfer-routing.keiro"
      let lenientBody =
            mapIntake (\intake -> intakeWithDecode (decodeWithBodyStrict False intake.decode) intake) intakeSpec
          unknownHeader =
            mapIntake
              (\intake -> intakeWithBinds (updateFirst (bindRowWithSource (SrcHeader "x-custom")) intake.binds) intake)
              intakeSpec
          retryOnAppended =
            modifyProcess
              "HospitalSurge"
              ( \process ->
                  processWithHandle
                    ( handleWithDispatch
                        ( updateFirst
                            (\d -> dispatchNodeWithDisposition (dispatchDispositionWithOnAppended DRetry d.disposition) d)
                            process.handle.dispatch
                        )
                        process.handle
                    )
                    process
              )
              processSpec
          firedNotMine =
            modifyProcess
              "HospitalSurge"
              ( \process ->
                  let timer = process.timer
                      fire = timer.fire
                   in processWithTimer
                        ( timerWithFire
                            (fireNodeWithDisposition (fireDispositionWithNotMine OFired fire.disposition) fire)
                            timer
                        )
                        process
              )
              processSpec
          routerRetryOnAppended =
            mapRouter
              ( \router ->
                  routerWithDispatch
                    (routerDispatchWithDisposition (dispatchDispositionWithOnAppended DRetry router.dispatch.disposition) router.dispatch)
                    router
              )
              routerSpec
          cases =
            [ (lenientBody, DecodeBodyPostureUnsupported),
              (unknownHeader, IntakeBindHeaderUnknown),
              (retryOnAppended, DispatchOnAppendedUnsupported),
              (firedNotMine, TimerNotMineUnsupported),
              (routerRetryOnAppended, DispatchOnAppendedUnsupported)
            ]
      forM_ cases $ \(candidate, expected) -> do
        serviceErrorCodes 3 candidate `shouldNotContain` [expected]
        serviceWarningCodes 3 candidate `shouldContain` [expected]
        serviceErrorCodes 4 candidate `shouldContain` [expected]

      -- The unmutated fixtures spell every one of these the way the runtime
      -- behaves, so language 4 has nothing to say about them.
      let closedCodes =
            [ DecodeBodyPostureUnsupported,
              IntakeBindHeaderUnknown,
              DispatchOnAppendedUnsupported,
              TimerNotMineUnsupported
            ]
      forM_ [intakeSpec, processSpec, routerSpec] $ \accepted -> do
        serviceErrorCodes 4 accepted `shouldNotContain` closedCodes
        serviceWarningCodes 4 accepted `shouldNotContain` closedCodes

    -- ExecPlan 197 parked these three as "explicitly descriptive-only"; ExecPlan
    -- 199 re-adjudicated each against the path it purports to describe and found
    -- a checkable referent in every one.
    it "checks the references the formerly descriptive-only surfaces name" $ do
      processSpec <- specOf "test/fixtures/hospital-surge.keiro"
      dispatchSpec <- specOf "test/fixtures/reservation-work.keiro"
      let unknownStatus =
            modifyProcess
              "HospitalSurge"
              (\process -> processWithTimer (timerWithDecodeUnknown "Abandoned" process.timer) process)
              processSpec
          blankDeadLetter =
            modifyProcess
              "HospitalSurge"
              (\process -> processWithTimer (timerWithDeadLetter "   " process.timer) process)
              processSpec
          phantomDedupeKey =
            mapPgmqDispatch (pgmqDispatchWithDedupKey "ghostKey") dispatchSpec
          uppercaseFanout =
            mapPgmqDispatch (pgmqDispatchWithFanoutBody "ResolveTransferCandidates") dispatchSpec
          cases =
            [ (unknownStatus, TimerDecodeStatusUnknown),
              (blankDeadLetter, TimerDeadLetterTextInvalid),
              (phantomDedupeKey, DispatchReadModelFieldUnknown),
              (uppercaseFanout, PgmqFanoutFunctionInvalid)
            ]
      forM_ cases $ \(candidate, expected) -> do
        serviceErrorCodes 3 candidate `shouldNotContain` [expected]
        serviceWarningCodes 3 candidate `shouldContain` [expected]
        serviceErrorCodes 4 candidate `shouldContain` [expected]

      -- Every timer status the runtime actually stores is accepted.
      forM_ ["Scheduled", "Firing", "Fired", "Cancelled", "Dead"] $ \status ->
        serviceErrorCodes
          4
          (modifyProcess "HospitalSurge" (\p -> processWithTimer (timerWithDecodeUnknown status p.timer) p) processSpec)
          `shouldNotContain` [TimerDecodeStatusUnknown]

      serviceErrorCodes 4 processSpec `shouldNotContain` [TimerDecodeStatusUnknown, TimerDeadLetterTextInvalid]
      serviceErrorCodes 4 dispatchSpec `shouldNotContain` [PgmqFanoutFunctionInvalid]

    it "holds a process dispatch-id line to the same strictness as a router's" $ do
      -- Both lines document a derivation the spec cannot change, but the two
      -- runtimes key on different tuples: Keiro.ProcessManager on
      -- (name, correlationId, sourceEventId, emitIndex) and Keiro.Router on
      -- (name, key, sourceEventId, targetStreamName, occurrence). Before
      -- ExecPlan 199 the process line accepted any strategy and any tuple.
      processSource <- readTestText "test/fixtures/hospital-surge.keiro"
      let processLine = "dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)"
          rejected =
            [ "dispatch-id strategy=md5 from=(name, correlationId, sourceEventId, emitIndex)",
              "dispatch-id strategy=uuidv5 from=(banana)",
              "dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId)",
              -- The router's tuple is not the process's tuple.
              "dispatch-id strategy=uuidv5 from=(name, key, sourceEventId, targetStreamName, occurrence)"
            ]
      processSource `shouldSatisfy` T.isInfixOf processLine
      parseSpec "accepted" processSource `shouldSatisfy` isRight
      forM_ rejected $ \badLine ->
        parseSpec "mutated" (T.replace processLine badLine processSource)
          `shouldSatisfy` isLeft

    it "gates the remaining locally resolvable identity and field surfaces on language 4" $ do
      reservation <- specOf "test/fixtures/reservation.keiro"
      emitSpec <- specOf "test/fixtures/emit.keiro"
      processSpec <- specOf "test/fixtures/hospital-surge.keiro"
      dispatchSpec <- specOf "test/fixtures/reservation-work.keiro"
      readModelSpec <- specOf "test/fixtures/readmodel.keiro"
      let projectionKey = modifyAggregate "Reservation" (\aggregate -> aggregateWithProjection (fmap (projectionSpecWithKey "ghost") aggregate.projection) aggregate) reservation
          outboxField = mapPublisher (publisherWithOutboxField "ghost") emitSpec
          timerIds =
            modifyProcess
              "HospitalSurge"
              ( \process ->
                  let timer = process.timer
                      fire = timer.fire
                   in processWithTimer
                        ( timerWithIdAndFire
                            (idExprWithField "ghostTimerKey" timer.id)
                            (fireNodeWithFiredEventId (idExprWithField "ghostEventKey" fire.firedEventId) fire)
                            timer
                        )
                        process
              )
              processSpec
          sourceKey = mapDispatch (pgmqDispatchWithSourceKey "ghost") dispatchSpec
          subscriptionIdentity = modifyReadModel "transfer_decisions" (\readModel -> readModelWithSupply (setLegacySubscription (Just "bad subscription") readModel.supply) readModel) readModelSpec
          scopeIdentity = modifyReadModel "transfer_decisions" (\readModel -> readModelWithSupply (setLegacyScope (Just (RmCategory "bad-category")) readModel.supply) readModel) readModelSpec
          cases =
            [ (projectionKey, AggProjectionKeyUnresolved),
              (outboxField, PublisherOutboxFieldUnresolved),
              (timerIds, TimerIdFieldNotCorrelation),
              (sourceKey, DispatchReadModelFieldUnknown),
              (subscriptionIdentity, RuntimeIdentityInvalid),
              (scopeIdentity, RuntimeIdentityInvalid)
            ]
      forM_ cases $ \(candidate, expected) -> do
        serviceErrorCodes 3 candidate `shouldBe` []
        serviceErrorCodes 4 candidate `shouldContain` [expected]
      length (filter (== TimerIdFieldNotCorrelation) (serviceErrorCodes 4 timerIds)) `shouldBe` 2
      parseStableRenderedSpec "<timer-id-fields>" timerIds `shouldBe` Right timerIds
    it "uses a router-specific code for a confirmed duplicate inversion" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      let changed =
            modifyRouter
              "PagingRouter"
              ( \router ->
                  let dispatch = router.dispatch
                      disposition = dispatch.disposition
                   in routerWithDispatch
                        (routerDispatchWithDisposition (dispatchDispositionWithOnDuplicate DAckOk disposition) dispatch)
                        router
              )
              spec
          warningCodes = [(.code) diagnostic | diagnostic <- validateSpec changed, (.severity) diagnostic == Warning]
      warningCodes `shouldContain` [RouterBenignInversion]
      warningCodes `shouldNotContain` [ProcessBenignInversion]
    it "pins every emitted legacy single-spec diagnostic that lacked a direct negative test" $ do
      reservation <- specOf "test/fixtures/reservation.keiro"
      intakeSpec <- specOf "test/fixtures/intake.keiro"
      emitSpec <- specOf "test/fixtures/emit.keiro"
      processSpec <- specOf "test/fixtures/surge-service.keiro"
      queueSpec <- specOf "test/fixtures/reservation-work.keiro"
      workflowSpec <- specOf "test/fixtures/workflow.keiro"
      let updateFirstTransition update aggregate = aggregateWithTransitions (updateFirst update aggregate.transitions) aggregate
          undeclaredEvent = modifyAggregate "Reservation" (updateFirstTransition (transitionWithEmits ["GhostEvent"])) reservation
          undeclaredState = modifyAggregate "Reservation" (updateFirstTransition (transitionWithGoto "GhostState")) reservation
          terminalOutgoing = modifyAggregate "Reservation" (updateFirstTransition (transitionWithSource "Expired")) reservation
          deprecatedEmitted = modifyAggregate "Reservation" (\aggregate -> aggregateWithEvents (updateFirst (eventWithDeprecated True) aggregate.events) aggregate) reservation
          wireVersionMismatch = modifyAggregate "Reservation" (\aggregate -> aggregateWithWire (fmap (wireSpecWithSchemaVersion 2) aggregate.wire) aggregate) reservation
          decodeRetry =
            mapIntake
              ( \intake ->
                  intakeWithDisposition
                    [ if row.outcome == "decodeFailed" then dispositionRowWithAction (IRetry "5s") row else row
                    | row <- intake.disposition
                    ]
                    intake
              )
              intakeSpec
          unresolvedPublisher = mapPublisher (publisherWithEmit "ghost") emitSpec
          unresolvedIntake = mapIntake (intakeWithContract "ghost") intakeSpec
          unboundedQueue = mapWorkqueue (workqueueWithMaxRetries 0) queueSpec
          unresolvedEnqueue = mapDispatch (pgmqDispatchWithEnqueueTo "ghost") queueSpec
          unresolvedWorkflow =
            mapOperation
              ( \operation -> case (.shape) operation of
                  RunOp _ input outcome -> operationWithShape (RunOp "GhostWorkflow" input outcome) operation
                  _ -> operation
              )
              workflowSpec
          cases =
            [ (undeclaredEvent, UndeclaredEvent),
              (undeclaredState, UndeclaredState),
              (terminalOutgoing, TerminalHasOutgoing),
              (deprecatedEmitted, DeprecatedEventStillEmitted),
              (wireVersionMismatch, WireSchemaVersionMismatch),
              (processSpec, ProcessBenignInversion),
              (decodeRetry, DispositionDecodeUnboundedRetry),
              (unresolvedPublisher, PublisherUnresolvedEmit),
              (unresolvedIntake, IntakeUnresolvedContract),
              (unboundedQueue, WqDlqWithoutCeiling),
              (unresolvedEnqueue, DispatchEnqueueUnresolved),
              (unresolvedWorkflow, RunWorkflowUnresolved)
            ]
      forM_ cases $ \(candidate, expected) -> diagnosticCodes candidate `shouldContain` [expected]
    it "rejects a missing status-map as StatusMapNotTotal" $ do
      codes <- diagnosticCodesOf "test/fixtures/reservation-no-statusmap.keiro"
      codes `shouldContain` [StatusMapNotTotal]
    it "rejects an undeclared command as UndeclaredCommand" $ do
      codes <- diagnosticCodesOf "test/fixtures/reservation-bad-command.keiro"
      codes `shouldContain` [UndeclaredCommand]
    it "rejects a wall-clock guard atom as ClockSampled" $ do
      codes <- diagnosticCodesOf "test/fixtures/reservation-clock.keiro"
      codes `shouldContain` [ClockSampled]
    it "accepts a v2 event with a contiguous upcaster hole" $ do
      codes <- errorCodesOf "test/fixtures/reservation-v2.keiro"
      codes `shouldBe` []
    it "rejects a v2 event with no upcaster as EvtVersionMissingUpcaster" $ do
      codes <- diagnosticCodesOf "test/fixtures/reservation-v2-noupcast.keiro"
      codes `shouldContain` [EvtVersionMissingUpcaster]
    it "accepts shared upcaster sources for different event kinds" $ do
      codes <- errorCodesOf "test/fixtures/reservation-dup-upcast-source.keiro"
      codes `shouldBe` []
    it "rejects a gap in the aggregate-global upcaster chain" $ do
      codes <- errorCodesOf "test/fixtures/reservation-chain-gap.keiro"
      codes `shouldContain` [UpcasterChainGap]
    it "warns while a retiring event keeps its live emitting transition" $ do
      diagnostics <- diagnosticsOf "test/fixtures/reservation-retiring.keiro"
      [(.code) d | d <- diagnostics, (.severity) d == Error] `shouldBe` []
      [(.code) d | d <- diagnostics, (.severity) d == Warning]
        `shouldContain` [EventRetirementInProgress]
    it "rejects a retiring event after its live emitting transition disappears" $ do
      source <- readTestText "test/fixtures/reservation-retiring.keiro"
      spec <- parseInlineSpec "<retiring-without-emitter>" (T.replace "emit TransferReservationConfirmed ; " "" source)
      [(.code) d | d <- validateSpec spec, (.severity) d == Error]
        `shouldContain` [EventRetirementInProgress]
    it "warns when a deprecated event has no replay-only emitting transition" $ do
      diagnostics <- diagnosticsOf "test/fixtures/reservation-deprecated.keiro"
      [(.code) d | d <- diagnostics, (.severity) d == Error] `shouldBe` []
      [(.code) d | d <- diagnostics, (.severity) d == Warning]
        `shouldContain` [DeprecatedEventReplayHazard]
    it "recognises deprecated plus replay-only as the replay-safe cutover" $ do
      diagnostics <- diagnosticsOf "test/fixtures/reservation-deprecated-replay-only.keiro"
      [(.code) d | d <- diagnostics, (.severity) d == Error] `shouldBe` []
      [(.code) d | d <- diagnostics, (.severity) d == Warning]
        `shouldContain` [EventRetirementInProgress]
      [(.code) d | d <- diagnostics] `shouldNotContain` [DeprecatedEventReplayHazard]
    it "requires exact, unique status-map event keys" $ do
      dangling <- errorCodesOf "test/fixtures/statusmap-dangling.keiro"
      mapM_ (\expected -> dangling `shouldContain` [expected]) [StatusMapDanglingKey, StatusMapNotTotal]
      duplicate <- errorCodesOf "test/fixtures/statusmap-dup-key.keiro"
      duplicate `shouldContain` [StatusMapDuplicateKey]
    it "rejects duplicate aggregate source subjects before semantic duplicate-name validation" $ do
      source <- readTestText "test/fixtures/duplicate-names.keiro"
      surface <- case parseSurfaceSource "test/fixtures/duplicate-names.keiro" source of
        Left frontendFailure -> expectationFailure (show frontendFailure) >> fail "unreachable"
        Right value -> pure value
      case lowerSurfaceDocument surface of
        Left LoweringFailure {code = SemanticSourceIndexInvalid DuplicateSourceSubject} -> pure ()
        other -> expectationFailure ("expected duplicate source-subject lowering refusal, got " <> show other)

      let withoutDuplicateAggregate = T.unlines (reverse (drop 3 (reverse (T.lines source))))
      parsed <- case parseSource "test/fixtures/duplicate-names.keiro" withoutDuplicateAggregate of
        Left parseFailure -> expectationFailure (show parseFailure) >> fail "unreachable"
        Right value -> pure value
      let spec = parsed.spec
          codes = [(.code) diagnostic | diagnostic <- validateSpec spec, (.severity) diagnostic == Error]
      mapM_
        (\expected -> codes `shouldContain` [expected])
        [ DuplicateEnumCtor,
          DuplicateEnumWire,
          DuplicateIdPrefix,
          DuplicateCommandName,
          DuplicateEventName
        ]
      case [node | node@NAggregate {} <- (.nodes) spec] of
        aggregateNode : _ ->
          [(.code) diagnostic | diagnostic <- validateSpec (specWithNodes (spec.nodes <> [aggregateNode]) spec), (.severity) diagnostic == Error]
            `shouldContain` [DuplicateNodeName]
        [] -> expectationFailure "duplicate-name fixture lost its aggregate"
    it "rejects aggregate-local references that do not resolve" $ do
      codes <- errorCodesOf "test/fixtures/aggregate-bad-refs.keiro"
      mapM_ (\expected -> codes `shouldContain` [expected]) [RegisterInitialOutOfScope, UndeclaredCommand, WriteTargetNotRegister]
    it "anchors UnreachableState on the state row" $ do
      let src =
            T.unlines
              [ "context repro",
                "",
                "aggregate Thing",
                "  regs",
                "  states",
                "    Initial",
                "    Unreachable"
              ]
      case parseSpec "<unreachable-row>" src of
        Left err -> expectationFailure (T.unpack err)
        Right spec ->
          [(.line) d | d <- validateSpec spec, (.code) d == UnreachableState]
            `shouldBe` [7]
    it "accepts a replay-only twin with a live sibling (plan 143)" $ do
      codes <- errorCodesOf "test/fixtures/reservation-guard-tightened-twin.keiro"
      codes `shouldBe` []
    it "rejects a replay-only transition that emits nothing" $ do
      case parseSpec "<replay-only-no-emit>" (replayOnlySpecWith ["    write reservationState := Held", "    goto  Held"]) of
        Left err -> expectationFailure (T.unpack err)
        Right spec ->
          [(.code) d | d <- validateSpec spec, (.severity) d == Error]
            `shouldContain` [ReplayOnlyEmitsNothing]
    it "warns when a replay-only transition has no live sibling" $ do
      case parseSpec "<replay-only-orphan>" (replayOnlySpecWith ["    emit  TransferReservationCreated", "    goto  Held"]) of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> do
          [(.code) d | d <- validateSpec spec, (.severity) d == Warning]
            `shouldContain` [ReplayOnlyCommandStillLive]
          [(.code) d | d <- validateSpec spec, (.severity) d == Error]
            `shouldNotContain` [ReplayOnlyCommandStillLive]

  describe "complementExpr (plan 143)" $ do
    it "applies De Morgan over and/or and flips comparison operators" $ do
      let a = EAtom (AName "a")
          b = EAtom (AName "b")
      complementExpr (EAnd a b)
        `shouldBe` EOr (ECmp OpEq a (EAtom (ABool False))) (ECmp OpEq b (EAtom (ABool False)))
      complementExpr (ECmp OpLt a b) `shouldBe` ECmp OpGe a b
      complementExpr (ECmp OpEq a b) `shouldBe` ECmp OpNeq a b
      complementExpr (ECmp OpLe a b) `shouldBe` ECmp OpGt a b
      complementExpr (ECmp OpGt a b) `shouldBe` ECmp OpLe a b
      complementExpr (ECmp OpGe a b) `shouldBe` ECmp OpLt a b
      complementExpr (ECmp OpNeq a b) `shouldBe` ECmp OpEq a b
    it "flips boolean literals and grounds bare names as == false" $ do
      complementExpr (EAtom (ABool True)) `shouldBe` EAtom (ABool False)
      complementExpr (EAtom (AName "open"))
        `shouldBe` ECmp OpEq (EAtom (AName "open")) (EAtom (ABool False))
    it "stays inside the grammar: the complement of any guard re-parses" $
      property $
        forAll genExpr $ \e ->
          let twin =
                replayOnlySpecWith
                  [ "    guard " <> renderExprText (complementExpr e),
                    "    emit  TransferReservationCreated",
                    "    goto  Held"
                  ]
           in case parseSpec "<complement>" twin of
                Left err -> counterexample (T.unpack err) False
                Right spec ->
                  [(.guard) t | NAggregate a <- (.nodes) spec, t <- (.transitions) a]
                    === [Just (complementExpr e)]

  describe "evolution parsing" $ do
    it "parses event version and upcaster from reservation-v2.keiro" $ do
      input <- readTestText "test/fixtures/reservation-v2.keiro"
      case parseSpec "test/fixtures/reservation-v2.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> case [e | NAggregate a <- (.nodes) spec, e <- (.events) a, (.name) e == "TransferReservationCreated"] of
          (e : _) -> do
            (.version) e `shouldBe` 2
            (.upcastFrom) e `shouldBe` Just (1, Hole)
          [] -> expectationFailure "TransferReservationCreated not found"
    it "round-trips the retiring marker" $ do
      spec <- specOf "test/fixtures/reservation-retiring.keiro"
      parseStableRenderedSpec "<retiring-round-trip>" spec `shouldBe` Right spec
      [(.retiring) event | NAggregate aggregate <- (.nodes) spec, event <- (.events) aggregate, (.name) event == "TransferReservationConfirmed"]
        `shouldBe` [True]
    it "rejects an event marked both retiring and deprecated" $ do
      source <- readTestText "test/fixtures/reservation-retiring.keiro"
      let conflicting = T.replace "retiring event TransferReservationConfirmed" "retiring deprecated event TransferReservationConfirmed" source
      parseSpec "<conflicting-retirement-markers>" conflicting `shouldSatisfy` isLeft

  describe "aggregate snapshots (EP-109)" $ do
    it "parses, validates, and round-trips a snapshot policy with codec fixture" $ do
      spec <- specOf "test/fixtures/reservation-snapshot.keiro"
      errorCodesOf "test/fixtures/reservation-snapshot.keiro" `shouldReturn` []
      parseStableRenderedSpec "<snapshot-round-trip>" spec `shouldBe` Right spec
      case [aggregate | NAggregate aggregate <- (.nodes) spec] of
        [aggregate] -> (.snapshot) aggregate `shouldBe` Just (SnapshotSpec (SnapEvery 100) 1 "7a181ceb7d798d883d28c85201c5c1692bd314a7b489da9128bff91e0f38cd28" noLoc)
        aggregates -> expectationFailure ("expected one snapshot aggregate, got " <> show (length aggregates))
    it "rejects disabled intervals and invalid codec fixtures" $ do
      source <- readTestText "test/fixtures/reservation-snapshot.keiro"
      interval <- parseInlineSpec "<snapshot-zero>" (T.replace "snapshot every 100" "snapshot every 0" source)
      map (.code) (validateSpec interval) `shouldContain` [SnapshotIntervalInvalid]
      version <- parseInlineSpec "<snapshot-version-zero>" (T.replace "state-codec version=1" "state-codec version=0" source)
      map (.code) (validateSpec version) `shouldContain` [SnapshotCodecFixtureInvalid]
      emptyHash <- parseInlineSpec "<snapshot-empty-hash>" (T.replace "shape-hash=\"7a181ceb7d798d883d28c85201c5c1692bd314a7b489da9128bff91e0f38cd28\"" "shape-hash=\"\"" source)
      map (.code) (validateSpec emptyHash) `shouldContain` [SnapshotCodecFixtureInvalid]
    it "conditionally lowers JSON instances and the live defaultStateCodec" $ do
      snapshotService <- checkedServiceOf "test/fixtures/reservation-snapshot.keiro"
      ordinaryService <- checkedServiceOf "test/fixtures/reservation.keiro"
      let snapshot = checkedSpec snapshotService
          ordinary = checkedSpec ordinaryService
      case ([aggregate | NAggregate aggregate <- (.nodes) snapshot], [aggregate | NAggregate aggregate <- (.nodes) ordinary]) of
        ([_], [_]) -> do
          let snapshotModules = scaffoldServiceModules (defaultContext (snapshot.context)) snapshotService
              ordinaryModules = scaffoldServiceModules (defaultContext (ordinary.context)) ordinaryService
              snapshotDomain = generatedTextEndingIn "Domain.hs" snapshotModules
              snapshotStream = generatedTextEndingIn "EventStream.hs" snapshotModules
              ordinaryDomain = generatedTextEndingIn "Domain.hs" ordinaryModules
              ordinaryStream = generatedTextEndingIn "EventStream.hs" ordinaryModules
          snapshotDomain `shouldSatisfy` T.isInfixOf "deriving anyclass (ToJSON, FromJSON)"
          snapshotStream `shouldSatisfy` T.isInfixOf "snapshotPolicy = Every 100"
          snapshotStream `shouldSatisfy` T.isInfixOf "stateCodec = Just (withFoldFingerprint"
          snapshotStream `shouldSatisfy` T.isInfixOf "Spec-visible fold changes invalidate old"
          snapshotStream `shouldSatisfy` T.isInfixOf "reservationSnapshotFixture = (1, \"7a181ceb7d798d883d28c85201c5c1692bd314a7b489da9128bff91e0f38cd28\")"
          ordinaryDomain `shouldNotSatisfy` T.isInfixOf "DeriveAnyClass"
          ordinaryStream `shouldSatisfy` T.isInfixOf "snapshotPolicy = Never"
          ordinaryStream `shouldSatisfy` T.isInfixOf "stateCodec = Nothing"
          ordinaryStream `shouldSatisfy` T.isInfixOf "reservationCategory = Stream.categoryUnsafe \"reservation\""
          firewallBreaches snapshotModules `shouldBe` []
        _ -> expectationFailure "expected one aggregate in each snapshot test spec"

  describe "aggregate fold fingerprints (plan 138)" $ do
    it "is deterministic across repeated parses and formatting-only changes" $ do
      source <- readTestText "test/fixtures/reservation.keiro"
      first <- parseInlineSpec "<first>" source
      second <- shouldParseStableRenderedSpec "<second>" first
      aggregateFoldFingerprint first (onlyAggregate first)
        `shouldBe` aggregateFoldFingerprint second (onlyAggregate second)
    it "changes for transition writes, guards, and referenced rule bodies" $ do
      base <- specOf "test/fixtures/reservation.keiro"
      writeChanged <- specOf "test/fixtures/reservation-foldchange.keiro"
      guardChanged <- specOf "test/fixtures/reservation-guard-tightened.keiro"
      source <- readTestText "test/fixtures/reservation.keiro"
      ruleChanged <- parseInlineSpec "<rule-change>" (T.replace "RedTag => true" "RedTag => false" source)
      let baseFingerprint = aggregateFoldFingerprint base (onlyAggregate base)
      aggregateFoldFingerprint writeChanged (onlyAggregate writeChanged) `shouldNotBe` baseFingerprint
      aggregateFoldFingerprint guardChanged (onlyAggregate guardChanged) `shouldNotBe` baseFingerprint
      aggregateFoldFingerprint ruleChanged (onlyAggregate ruleChanged) `shouldNotBe` baseFingerprint
    it "ignores wire and projection changes" $ do
      base <- specOf "test/fixtures/reservation.keiro"
      wireChanged <- specOf "test/fixtures/reservation-wire.keiro"
      source <- readTestText "test/fixtures/reservation.keiro"
      projectionChanged <- parseInlineSpec "<projection-change>" (T.replace "projection transfer_decisions" "projection renamed_projection" source)
      let surface = aggregateFoldSurface base (onlyAggregate base)
      aggregateFoldSurface wireChanged (onlyAggregate wireChanged) `shouldBe` surface
      aggregateFoldSurface projectionChanged (onlyAggregate projectionChanged) `shouldBe` surface
    it "invalidates mapped-register snapshots when binding or wire identity changes" $ do
      base <- specOf "test/fixtures/consumer-types.keiro"
      bindingChanged <- specOf "test/fixtures/consumer-types-binding-change.keiro"
      wireChanged <- specOf "test/fixtures/consumer-types-wirekey.keiro"
      let baseFingerprint = aggregateFoldFingerprint base (onlyAggregate base)
      aggregateFoldFingerprint bindingChanged (onlyAggregate bindingChanged) `shouldNotBe` baseFingerprint
      aggregateFoldFingerprint wireChanged (onlyAggregate wireChanged) `shouldNotBe` baseFingerprint

  describe "process/timer (EP-3)" $ do
    it "parses the hospital-surge process + nested timer" $ do
      input <- readTestText "test/fixtures/hospital-surge.keiro"
      case parseSpec "test/fixtures/hospital-surge.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> case [p | NProcess p <- (.nodes) spec] of
          (p : _) -> do
            p.id `shouldBe` "HospitalSurge"
            (.name) p `shouldBe` "hospital-surge"
            (.rejected) p `shouldBe` PolHalt
            (.poison) p `shouldBe` PolHalt
            (.category) ((.saga) p) `shouldBe` "hospitalSurge"
            (.name) ((.timer) p) `shouldBe` "surgeFollowUp"
            (.onReject) ((.disposition) ((.fire) ((.timer) p))) `shouldBe` OFired
            (.onAmbiguous) ((.disposition) ((.fire) ((.timer) p))) `shouldBe` ORetry
            (.maxAttempts) ((.timer) p) `shouldBe` 5
          [] -> expectationFailure "no process node parsed"
    it "round-trips the hospital-surge spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/hospital-surge.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseLanguage4RenderedSpec "in" spec `shouldBe` Right spec
    it "accepts the hospital-surge spec (no errors; benign-inversion warnings only)" $ do
      codes <- errorCodesOf "test/fixtures/hospital-surge.keiro"
      codes `shouldBe` []
    it "rejects illegal saga categories and no longer parses the raw stream-prefix clause" $ do
      spec <- specOf "test/fixtures/hospital-surge.keiro"
      mapM_
        (\categoryName -> processErrorCodes (\process -> processWithSaga (sagaRefWithCategory categoryName process.saga) process) spec `shouldContain` [SagaCategoryIllegal])
        ["", "$all", "hospital-surge", "hospital surge", "wf:surge"]
      source <- readTestText "test/fixtures/hospital-surge.keiro"
      parseSpec "<legacy-saga>" (T.replace "saga Surge category \"hospitalSurge\"" "saga Surge stream=\"hospital-surge-\" <> correlationId" source)
        `shouldSatisfy` isLeft
    it "rejects a wall-clock fireAt as ProcessFireAtNotInjected" $ do
      codes <- errorCodesOf "test/fixtures/hospital-surge-clock.keiro"
      codes `shouldContain` [ProcessFireAtNotInjected]
    it "reports one ProcessFireAtNotInjected for a wholly unknown fireAt field" $ do
      codes <- errorCodesOf "test/fixtures/hospital-surge-clock.keiro"
      length (filter (== ProcessFireAtNotInjected) codes) `shouldBe` 1
    it "rejects a user-supplied dispatch id as ProcessDispatchIdSupplied" $ do
      codes <- errorCodesOf "test/fixtures/hospital-surge-dispatchid.keiro"
      codes `shouldContain` [ProcessDispatchIdSupplied]
    it "rejects an unresolved saga reference as ProcessUnresolvedRef" $ do
      codes <- errorCodesOf "test/fixtures/hospital-surge-badref.keiro"
      codes `shouldContain` [ProcessUnresolvedRef]
    it "rejects unresolved process commands, projections, schedules, and advance ids" $ do
      codes <- errorCodesOf "test/fixtures/process-ghost-refs.keiro"
      length (filter (== ProcessUnresolvedRef) codes) `shouldBe` 5
      codes `shouldContain` [ProcessDispatchIdSupplied]
    it "gates process correlate, dispatch-key, and binding scopes on language 4" $ do
      spec <- specOf "test/fixtures/hospital-surge.keiro"
      let badCorrelate =
            modifyProcess
              "HospitalSurge"
              (\process -> processWithCorrelate (correlateDeclWithField "ghost" process.correlate) process)
              spec
          badDispatchKey =
            modifyProcess
              "HospitalSurge"
              ( \process ->
                  let handle = process.handle
                   in processWithHandle (handleWithDispatch (updateFirst (dispatchNodeWithKey "input.ghost") handle.dispatch) handle) process
              )
              spec
          badBinding =
            modifyProcess
              "HospitalSurge"
              ( \process ->
                  let handle = process.handle
                      advance = handle.advance
                   in processWithHandle
                        (handleWithAdvance (advanceNodeWithFields (updateFirst (fieldBindingWithValue (Just "ghost.value")) advance.advFields) advance) handle)
                        process
              )
              spec
          cases =
            [ (badCorrelate, ProcessKeyFieldUnknown),
              (badDispatchKey, ProcessDispatchKeyUnresolved),
              (badBinding, ProcessBindingUnscoped)
            ]
      forM_ cases $ \(candidate, expected) -> do
        serviceErrorCodes 3 candidate `shouldNotContain` [expected]
        serviceErrorCodes 4 candidate `shouldContain` [expected]
      serviceErrorCodes 4 spec
        `shouldNotContain` [ProcessKeyFieldUnknown, ProcessDispatchKeyUnresolved, ProcessBindingUnscoped]

  describe "router (EP-108)" $ do
    it "RouterSelection parses, checks, fingerprints, and round-trips bounded declarative selection" $ do
      source <- readTestText "test/fixtures/declarative-router/valid.keiro"
      parsed <- case parseSource "declarative-router.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let service = checkedSource parsed
          spec = checkedSpec service
      [(.code) diagnostic | diagnostic <- validateService service, (.severity) diagnostic == Error] `shouldBe` []
      parseSource "declarative-router-roundtrip.keiro" (renderSource parsed) `shouldBe` Right parsed
      graph <- shouldResolveTypeGraph spec
      case [router | NRouter router <- (.nodes) spec] of
        [router] -> case RouterSelection.checkRouterSelection (checkedLanguageContract service) graph spec router of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right selection -> do
            (.identity) selection `shouldBe` "hospital-transfer-selection"
            (.version) selection `shouldBe` 1
            (.limit) selection `shouldBe` 64
            (.useSites) selection `shouldSatisfy` (not . null)
            T.length ((.fingerprint) selection) `shouldBe` 64
            (.fingerprint) selection
              `shouldSatisfy` T.all (`elem` ("0123456789abcdef" :: String))
        routers -> expectationFailure ("expected one declarative router, got " <> show (length routers))

    it "generates the checked declarative selection without a selection-owned RouterHoles module" $ do
      service <- checkedServiceOf "test/fixtures/declarative-router/valid.keiro"
      let spec = checkedSpec service
          modules = scaffoldServiceModules (defaultContext (spec.context)) service
          routerModule = generatedTextEndingIn "HospitalTransferRouter/Router.hs" modules
          routerHarness = generatedTextEndingIn "HospitalTransferRouter/RouterHarness.hs" modules
      [(.path) generatedModule | generatedModule <- modules, "HospitalTransferRouter/Router.hs" `T.isSuffixOf` T.pack ((.path) generatedModule)]
        `shouldBe` ["Generated/TransferRouting/HospitalTransferRouter/Router.hs"]
      [(.path) hole | hole <- modules, "HospitalTransferRouter/RouterHoles.hs" `T.isSuffixOf` T.pack ((.path) hole)]
        `shouldBe` []
      routerModule `shouldSatisfy` T.isInfixOf "DeclarativeRouter"
      routerModule `shouldSatisfy` T.isInfixOf "runQuery Nothing SelectionQuery.hospitalLoadReadModel input"
      routerModule `shouldSatisfy` T.isInfixOf "fieldWitnessGet StructuralProjections.hospitalLoadRowHospitalIdWitness row"
      routerModule `shouldSatisfy` T.isInfixOf "hospitalTransferRouterSelectionContract"
      routerModule `shouldSatisfy` T.isInfixOf "hospitalTransferRouterSelectionFingerprint"
      routerHarness `shouldSatisfy` T.isInfixOf "(\"resolverOwnership\", \"generated-declarative\")"
      routerHarness `shouldSatisfy` T.isInfixOf "(\"maxRecipients\", \"64\")"
      firewallBreaches modules `shouldBe` []

    it "classifies every declarative selection coordination transition" $ do
      source <- readTestText "test/fixtures/declarative-router/valid.keiro"
      baseline <- checkedServiceFromText "selection-baseline.keiro" source
      identityChanged <- checkedServiceFromText "selection-identity.keiro" (T.replace "identity = \"hospital-transfer-selection\"" "identity = \"hospital-transfer-selection-v2\"" source)
      versionTwo <- checkedServiceFromText "selection-version-two.keiro" (T.replace "version = 1" "version = 2" source)
      fingerprintChanged <- checkedServiceFromText "selection-fingerprint.keiro" (T.replace "max-recipients = 64" "max-recipients = 32" source)
      versionedFingerprintChanged <- checkedServiceFromText "selection-versioned-fingerprint.keiro" (T.replace "version = 1" "version = 2" (T.replace "max-recipients = 64" "max-recipients = 32" source))
      let custom =
            checkedServiceWithSpec
              ( modifyRouter
                  "HospitalTransferRouter"
                  ( \router ->
                      router
                        { input = ((.input) router) {valueType = Nothing, fields = [Field "transferNeedId" Nothing, Field "region" Nothing]},
                          resolve = ResolveDecl ResolveHole ["hospitalId"] ((.loc) ((.resolve) router))
                        }
                  )
                  (checkedSpec baseline)
              )
              baseline
          classifyCoordination old new = [(impact.reason, (.severity) impact) | impact <- coordinationImpact old new []]
      case routerSelectionSnapshots baseline of
        [snapshot] -> do
          (.verification) snapshot `shouldBe` DeclarativeVerified
          (.identity) snapshot `shouldBe` Just "hospital-transfer-selection"
          (.version) snapshot `shouldBe` Just 1
          fmap T.length ((.fingerprint) snapshot) `shouldBe` Just 64
          Aeson.decode (Aeson.encode snapshot) `shouldBe` Just snapshot
        snapshots -> expectationFailure ("expected one router selection ledger snapshot, got " <> show snapshots)
      classifyCoordination baseline identityChanged `shouldBe` [(SelectionIdentityChanged, CoordinationBreaking)]
      classifyCoordination versionTwo baseline `shouldBe` [(SelectionVersionDecreased, CoordinationBreaking)]
      classifyCoordination baseline fingerprintChanged `shouldBe` [(SelectionFingerprintChangedWithoutVersionBump, CoordinationBreaking)]
      classifyCoordination baseline versionedFingerprintChanged `shouldBe` [(SelectionFingerprintChangedWithVersionBump, CoordinationAdvisory)]
      classifyCoordination baseline versionTwo `shouldBe` [(SelectionVersionMetadataOnly, CoordinationAdvisory)]
      classifyCoordination baseline custom `shouldBe` [(SelectionVerificationBoundaryChanged, CoordinationAdvisory)]
      let breakingReport = LazyText.toStrict (LazyTextEncoding.decodeUtf8 (Aeson.encode (diffReportWithImpacts defaultGate [] [] (coordinationImpact baseline fingerprintChanged []))))
      breakingReport `shouldSatisfy` T.isInfixOf "\"breaking\":true"

    it "keeps formatting out of the fingerprint and reports mapped selection dependencies in both sections" $ do
      source <- readTestText "test/fixtures/declarative-router/valid.keiro"
      baseline <- checkedServiceFromText "selection-semantic-baseline.keiro" source
      formatted <- checkedServiceFromText "selection-semantic-formatted.keiro" (T.replace "context transfer-routing\n" "context transfer-routing\n\n" source)
      coordinationImpact baseline formatted [] `shouldBe` []
      let changed = checkedServiceWithSpec (mapMappedStructural "HospitalLoadRow" changeMappedCanonical (checkedSpec baseline)) baseline
          semantic = CheckedDiff.mappedSemanticImpactForServices baseline changed
          coordination = coordinationImpact baseline changed semantic
          rowDelta = find ((== MappedKey "HospitalLoadRow") . (.declaration)) semantic
          rendered = T.unlines (renderCoordinationImpact coordination)
          encoded = LazyText.toStrict (LazyTextEncoding.decodeUtf8 (Aeson.encode (diffReportWithImpacts defaultGate [] semantic coordination)))
          isSelectionConsumer = \case RouterSelectionConsumer {} -> True; _ -> False
      rowDelta `shouldSatisfy` maybe False (any isSelectionConsumer . Set.toList . (.currentConsumers))
      map (.reason) coordination `shouldContain` [SelectionMappedDependencyChanged]
      rendered `shouldSatisfy` T.isInfixOf "selection-mapped-dependency-changed"
      encoded `shouldSatisfy` T.isInfixOf "\"coordinationImpact\""
      encoded `shouldSatisfy` T.isInfixOf "router-selection:HospitalTransferRouter:recipient"
      LazyText.toStrict (LazyTextEncoding.decodeUtf8 (Aeson.encode (diffReport defaultGate [])))
        `shouldNotSatisfy` T.isInfixOf "coordinationImpact"

    it "RouterSelection gates declarative selection at the version-5 marker" $ do
      source <- readTestText "test/fixtures/declarative-router/valid.keiro"
      let version4 = "language keiro-dsl 4\ncontext transfer-routing\n\n" <> snd (T.breakOn "router HospitalTransferRouter" source)
      case parseSurfaceSource "declarative-router-v4.keiro" version4 of
        Left FrontendFailure {code = SourceLanguageError LanguageFeatureRequiresVersion, span = SourceSpan {start = SourcePoint {offset = startOffset}, end = SourcePoint {offset = endOffset}}} ->
          T.take (endOffset - startOffset) (T.drop startOffset version4) `shouldBe` "declarative"
        Left failure -> expectationFailure (show failure)
        Right _ -> expectationFailure "language 4 unexpectedly accepted declarative selection"

    it "RouterSelection rejects unbounded selection at its declaration" $ do
      diagnostics <- diagnosticsOf "test/fixtures/declarative-router/unbounded.keiro"
      [((.line) diagnostic, (.code) diagnostic) | diagnostic <- diagnostics, (.severity) diagnostic == Error]
        `shouldBe` [(79, RouterSelectionRecipientLimitMissing)]

    it "RouterSelection assigns a dedicated diagnostic to every declarative selection rejection class" $ do
      source <- readTestText "test/fixtures/declarative-router/valid.keiro"
      let mutationCases =
            [ ("empty-identity", T.replace "identity = \"hospital-transfer-selection\"" "identity = \"\"", RouterSelectionIdentityEmpty),
              ("zero-version", T.replace "version = 1" "version = 0", RouterSelectionVersionInvalid),
              ("unknown-query", T.replace "read-model hospital_load" "read-model missing_load", RouterSelectionQueryUnknown),
              ("missing-query-contract", T.replace "  query input = TransferRouteInput\n  query result = List HospitalLoadRow\n" "", RouterSelectionQueryContractMissing),
              ("input-mismatch", T.replace "input AcceptedHospitalTransferNeed : TransferRouteInput" "input AcceptedHospitalTransferNeed : HospitalLoadRow", RouterSelectionQueryInputTypeMismatch),
              ("non-list-result", T.replace "query result = List HospitalLoadRow" "query result = HospitalLoadRow", RouterSelectionQueryResultNotList),
              ("unknown-root", T.replace "recipient = row.hospitalId" "recipient = resolved.hospitalId", RouterSelectionExpressionRootUnknown),
              ("unknown-field", T.replace "recipient = row.hospitalId" "recipient = row.missingHospitalId", RouterSelectionExpressionFieldUnknown),
              ("nullable-recipient", T.replace ": Text required\n    region" ": Optional Text required\n    region", RouterSelectionExpressionFieldOptional),
              ("predicate-type", T.replace "where = row.region == input.region && row.availableBeds > 0" "where = row.region", RouterSelectionPredicateNotBool),
              ("recipient-type", T.replace "recipient = row.hospitalId" "recipient = row.availableBeds", RouterSelectionRecipientNotText),
              ("operator", T.replace "recipient = row.hospitalId" "recipient = row.availableBeds + 1", RouterSelectionOperatorUnsupported),
              ("zero-limit", T.replace "max-recipients = 64" "max-recipients = 0", RouterSelectionRecipientLimitInvalid),
              ("order", T.replace "order = target-stream" "order = query-order", RouterSelectionOrderUnsupported),
              ("dedupe", T.replace "dedupe = target-stream" "dedupe = none", RouterSelectionDedupeUnsupported),
              ("failure-ack", T.replace "failure => retry" "failure => ack", RouterSelectionFailureAckForbidden),
              ("redelivery", T.replace "redelivery = stable-union" "redelivery = replace", RouterSelectionRedeliveryUnsupported),
              ("partial", T.replace "partial = retain-successes" "partial = rollback", RouterSelectionPartialDispatchUnsupported),
              ("target", T.replace "target Hospital\n" "target MissingHospital\n", RouterSelectionTargetAmbiguous),
              ("command", T.replace "dispatch-each RouteAcceptedTransferNeed" "dispatch-each MissingCommand", RouterSelectionCommandUnknown),
              ("duplicate-field", T.replace "    hospitalId=row.hospitalId\n" "    hospitalId=row.hospitalId\n    hospitalId=row.hospitalId\n", RouterSelectionCommandMappingDuplicate),
              ("incomplete-field", T.replace "    hospitalId=row.hospitalId\n" "", RouterSelectionCommandMappingIncomplete),
              ("field-type", T.replace "hospitalId:Text" "hospitalId:Int", RouterSelectionCommandMappingTypeMismatch)
            ]
      forM_ mutationCases $ \(caseLabel, mutate, expected) -> do
        service <- checkedServiceFromText ("declarative-router-" <> caseLabel <> ".keiro") (mutate source)
        [(.code) diagnostic | diagnostic <- validateService service, (.severity) diagnostic == Error]
          `shouldContain` [expected]

    it "parses the incident-paging router shape" $ do
      input <- readTestText "test/fixtures/incident-paging/incident-paging.keiro"
      case parseSpec "test/fixtures/incident-paging/incident-paging.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> case [router | NRouter router <- (.nodes) spec] of
          [router] -> do
            router.id `shouldBe` "PagingRouter"
            (.name) router `shouldBe` "jitsurei-paging"
            (.field) ((.key) router) `shouldBe` "incidentId"
            (.source) ((.resolve) router) `shouldBe` ResolveReadModel "service_oncall"
            (.row) ((.resolve) router) `shouldBe` ["responderId"]
            (.command) ((.dispatch) router) `shouldBe` "SendPage"
            (.rejected) router `shouldBe` PolDeadLetter
            (.poison) router `shouldBe` PolHalt
          routers -> expectationFailure ("expected one router, got " <> show (length routers))
    it "round-trips the incident-paging spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/incident-paging/incident-paging.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseLanguage4RenderedSpec "in" spec `shouldBe` Right spec
    it "accepts the incident-paging router with warnings only" $ do
      codes <- errorCodesOf "test/fixtures/incident-paging/incident-paging.keiro"
      codes `shouldBe` []
      diagnostics <- diagnosticCodesOf "test/fixtures/incident-paging/incident-paging.keiro"
      diagnostics `shouldContain` [PolicyDeadLetterUnused, AmbiguousFollowsRejectedPolicy]
    it "rejects unresolved targets, keys, commands, and binding scopes" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      routerErrorCodes (routerWithTarget "Pge") spec `shouldContain` [RouterUnresolvedRef]
      routerErrorCodes (\router -> routerWithKey (correlateDeclWithField "incidntId" router.key) router) spec `shouldContain` [RouterKeyFieldUnknown]
      routerErrorCodes (\router -> routerWithDispatch (routerDispatchWithCommand "SendPag" router.dispatch) router) spec `shouldContain` [RouterCommandUnknown]
      routerErrorCodes
        ( \router ->
            let dispatch = router.dispatch
             in routerWithDispatch (routerDispatchWithFields [FieldBinding "responderId" (Just "resolved.responder")] dispatch) router
        )
        spec
        `shouldContain` [RouterBindingUnscoped]
    it "rejects unresolved read models and contradictory rejection policies" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      let withoutReadModel = removeReadModel "service_oncall" spec
      errorCodes withoutReadModel `shouldContain` [RouterUnresolvedRef]
      routerErrorCodes
        ( \router ->
            let dispatch = router.dispatch
                disposition = dispatch.disposition
             in routerWithRejectedAndDispatch
                  PolHalt
                  (routerDispatchWithDisposition (dispatchDispositionWithOnFailed (DDeadLetter "page rejected") disposition) dispatch)
                  router
        )
        spec
        `shouldContain` [PolicyContradiction]
    it "gates resolve-row column verification on language 4" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      let unresolved =
            modifyRouter
              "PagingRouter"
              (\router -> routerWithResolve (resolveDeclWithRow ["ghostColumn"] router.resolve) router)
              spec
      serviceErrorCodes 3 unresolved `shouldNotContain` [RouterReadModelUnverified]
      serviceErrorCodes 4 unresolved `shouldContain` [RouterReadModelUnverified]
      serviceErrorCodes 4 spec `shouldNotContain` [RouterReadModelUnverified]
    it "rejects on-ambiguous Fired for process timers" $ do
      spec <- specOf "test/fixtures/hospital-surge.keiro"
      let changed =
            specWithNodes
              [ case node of
                  NProcess process ->
                    let timer = process.timer
                        fire = timer.fire
                        disposition = fire.disposition
                     in NProcess
                          ( processWithTimer
                              (timerWithFire (fireNodeWithDisposition (fireDispositionWithOnAmbiguous OFired disposition) fire) timer)
                              process
                          )
                  _ -> node
              | node <- spec.nodes
              ]
              spec
      errorCodes changed `shouldContain` [AmbiguousMarkedBenign]
    it "requires explicit policy and ambiguity clauses in the grammar" $ do
      source <- readTestText "test/fixtures/hospital-surge.keiro"
      parseSpec "<missing-poison>" (T.replace "  poison => halt\n" "" source) `shouldSatisfy` isLeft
      parseSpec "<missing-ambiguous>" (T.replace " ; on-ambiguous Retry" "" source) `shouldSatisfy` isLeft
    it "scaffolds firewall-clean router wiring, policies, and typed-hole guidance" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      case [router | NRouter router <- (.nodes) spec] of
        [router] -> do
          let ctx = defaultContext (spec.context)
              modules = scaffoldRouter ctx router
              generated = [m | m <- modules, (.kind) m == Generated]
              holes = [m | m <- modules, (.kind) m == HoleStub]
          firewallBreaches generated `shouldBe` []
          case (generated, holes) of
            ([generatedModule], [moduleName]) -> do
              (.text) generatedModule `shouldSatisfy` T.isInfixOf "pagingRouterWorkerOptions"
              (.text) generatedModule `shouldSatisfy` T.isInfixOf "rejectedCommandPolicy = RejectedDeadLetter"
              (.text) moduleName `shouldSatisfy` T.isInfixOf "UNION of resolved target identities"
              (.text) moduleName `shouldSatisfy` T.isInfixOf "confirmBenignDuplicate"
            _ -> expectationFailure "expected one generated router module and one router hole module"
        routers -> expectationFailure ("expected one router, got " <> show (length routers))
    it "requires a caller callback for non-halting poison policies" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      case [router | NRouter router <- (.nodes) spec] of
        [router] -> do
          let ctx = defaultContext (spec.context)
              generatedFor choice = [(.text) m | m <- scaffoldRouter ctx (routerWithPoison choice router), (.kind) m == Generated]
          mapM_
            ( \(choice, constructor) -> case generatedFor choice of
                [generatedModule] -> do
                  generatedModule `shouldSatisfy` T.isInfixOf "(Envelope msg -> Eff es ()) -> WorkerOptions es msg"
                  generatedModule `shouldSatisfy` T.isInfixOf (constructor <> " poisonCallback")
                _ -> expectationFailure "expected one generated router module"
            )
            [(PolDeadLetter, "PoisonDeadLetter"), (PolSkip, "PoisonSkip")]
          case [(.text) m | m <- scaffoldRouter ctx (routerWithRejected PolSkip router), (.kind) m == Generated] of
            [generatedModule] -> generatedModule `shouldSatisfy` T.isInfixOf "rejectedCommandPolicy = RejectedSkip"
            _ -> expectationFailure "expected one generated router module"
        routers -> expectationFailure ("expected one router, got " <> show (length routers))
    it "emits router harness facts that pin policy and target-keyed identity" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      case [router | NRouter router <- (.nodes) spec] of
        [router] -> case harnessRouter (defaultContext (spec.context)) router of
          [facts] -> do
            (.text) facts `shouldSatisfy` T.isInfixOf "(\"rejectedPolicy\", \"deadLetter\")"
            (.text) facts `shouldSatisfy` T.isInfixOf "targetStreamName, occurrence"
          modules -> expectationFailure ("expected one router harness, got " <> show (length modules))
        routers -> expectationFailure ("expected one router, got " <> show (length routers))
    it "rejects invalid timer ceilings and target field bindings" $ do
      codes <- errorCodesOf "test/fixtures/process-bad-timer.keiro"
      mapM_
        (\expected -> codes `shouldContain` [expected])
        [ProcessTimerCeilingInvalid, ProcessFieldBindingUnresolved]
    it "accepts resolved process projection references" $ do
      codes <- errorCodesOf "test/fixtures/surge-service.keiro"
      codes `shouldBe` []
    it "scaffolds the process: Generated wiring is firewall-clean + a HoleStub" $ do
      mods <- legacyScaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
      let gens = [m | m <- mods, (.kind) m == Generated]
          holes = [m | m <- mods, (.kind) m == HoleStub]
      length holes `shouldBe` 1
      firewallBreaches gens `shouldBe` []
      case gens of
        [generatedModule] -> do
          -- the worker uses the spec's ceiling, never the dangerous default
          (.text) generatedModule `shouldSatisfy` T.isInfixOf "max-attempts = 5"
          (.text) generatedModule `shouldSatisfy` T.isInfixOf "hospitalSurgeProcessWorkerOptions"
          (.text) generatedModule `shouldSatisfy` T.isInfixOf "import Generated.HospitalCapacity.Surge.EventStream (SurgeEventStreamDef)"
          (.text) generatedModule `shouldSatisfy` T.isInfixOf "hospitalSurgeCategory :: Stream.StreamCategory SurgeEventStreamDef"
          (.text) generatedModule `shouldSatisfy` T.isInfixOf "hospitalSurgeCategory = Stream.categoryUnsafe \"hospitalSurge\""
          (.text) generatedModule `shouldSatisfy` T.isInfixOf "confirmBenignDuplicate"
          (.text) generatedModule `shouldSatisfy` T.isInfixOf "StreamName -> EventId -> CommandError -> Eff es Bool"
          (.text) generatedModule `shouldSatisfy` T.isInfixOf "Left (CommandAmbiguous _)"
          case holes of
            [moduleName] -> (.text) moduleName `shouldSatisfy` T.isInfixOf "entityStream hospitalSurgeCategory"
            _ -> expectationFailure "expected one process hole module"
        _ -> expectationFailure "expected one generated process module"
    it "process scaffold is deterministic" $ do
      a <- legacyScaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
      b <- legacyScaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
      map (.text) a `shouldBe` map (.text) b
    it "separates aggregate event-stream and command-target categories and emits stable typed sums" $ do
      spec <- specOf "test/fixtures/hospital-surge.keiro"
      let ctx = defaultContext (spec.context)
          modules = concat [scaffoldAggregate ctx spec aggregate | NAggregate aggregate <- (.nodes) spec]
          surgeStream = generatedTextEndingIn "Surge/EventStream.hs" modules
          surgeDomain = generatedTextEndingIn "Surge/Domain.hs" modules
      surgeStream `shouldSatisfy` T.isInfixOf "surgeCategory :: Stream.StreamCategory SurgeEventStreamDef"
      surgeStream `shouldSatisfy` T.isInfixOf "surgeCommandCategory :: Stream.StreamCategory SurgeCommand"
      surgeDomain `shouldNotSatisfy` T.isInfixOf "{-# LANGUAGE EmptyDataDecls #-}"
      surgeDomain `shouldSatisfy` T.isInfixOf "data SurgeEvent = SurgeThresholdNoted"
      surgeDomain `shouldSatisfy` (not . T.isInfixOf "data SurgeEvent = ()")

  describe "contract (EP-4)" $ do
    it "parses the emergency contract (topics + events-on-topic + typed fields)" $ do
      input <- readTestText "test/fixtures/contract.keiro"
      case parseSpec "test/fixtures/contract.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> case [c | NContract c <- (.nodes) spec] of
          (c : _) -> do
            (.name) c `shouldBe` "emergency"
            (.discriminator) c `shouldBe` "messageType"
            map fst ((.topics) c) `shouldBe` ["incidentEvents", "hospitalEvents"]
            map (.name) ((.events) c) `shouldBe` ["IncidentTransferNeedDeclared", "TransferReservationAccepted"]
          [] -> expectationFailure "no contract node parsed"

    it "branches contract scaffolding, manifests, and durable identities only for language 4" $ do
      sourceText <- readTestText "test/fixtures/contract-v4.keiro"
      parsed <- case parseSource "contract-v4.keiro" sourceText of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let service = checkedSource parsed
          spec = checkedSpec service
          ctx = defaultContext (spec.context)
      contract <- case [value | NContract value <- (.nodes) spec] of
        [value] -> pure value
        values -> expectationFailure ("expected one contract, got " <> show (length values)) >> fail "unreachable"
      legacyModule <- case scaffoldContract ctx contract of
        [value] -> pure value
        values -> expectationFailure ("expected one legacy module, got " <> show (length values)) >> fail "unreachable"
      typedModule <- case scaffoldContractForService ctx service contract of
        [value] -> pure value
        values -> expectationFailure ("expected one typed module, got " <> show (length values)) >> fail "unreachable"
      let dependencies = manifestDependenciesForService service
          identities = idDomainIdentitiesForService service
          manifestText = renderManifestForService "contract-v4.keiro" [typedModule] service
      assertGeneratedHaskellContract "contract-v4.keiro" manifestText
      committed <- readTestText "test/conformance-contract/Generated/HospitalCapacity/Emergency/Contract.hs"
      normalizeGenerated ((.text) typedModule) `shouldBe` normalizeGenerated committed
      (.text) legacyModule `shouldSatisfy` T.isInfixOf "incidentId :: !Text"
      (.text) legacyModule `shouldSatisfy` (not . T.isInfixOf "KindID")
      (.text) typedModule `shouldSatisfy` T.isInfixOf "incidentId :: !(KindID \"inc\")"
      (.text) typedModule `shouldSatisfy` T.isInfixOf "KindID.toText payload.incidentId"
      (.text) typedModule `shouldSatisfy` T.isInfixOf "explicitParseField (parseKindIdV7Value @\"inc\") o \"incidentId\""
      (.text) typedModule `shouldSatisfy` T.isInfixOf "  , incidentEventsTopic"
      (.text) typedModule `shouldSatisfy` T.isInfixOf "  , hospitalEventsTopic"
      (.text) typedModule `shouldSatisfy` (not . T.isInfixOf "Wno-unused-top-binds")
      dependencies `shouldBe` ["aeson", "base", "keiro-core", "mmzk-typeid", "text"]
      manifestDependencies spec `shouldBe` ["aeson", "base", "text"]
      forM_ dependencies $ \dependency -> manifestText `shouldSatisfy` T.isInfixOf ("    , " <> dependency)
      identities
        `shouldBe` [ "id-domain|name=contract:emergency.IncidentTransferNeedDeclared.incidentId|contract=keiro-dsl/id-domain/typeid-v7/1|prefix=inc|separator=_|json=canonical-json-text",
                     "id-domain|name=contract:emergency.TransferReservationAccepted.incidentId|contract=keiro-dsl/id-domain/typeid-v7/1|prefix=inc|separator=_|json=canonical-json-text",
                     "id-domain|name=contract:emergency.TransferReservationAccepted.reservationId|contract=keiro-dsl/id-domain/typeid-v7/1|prefix=rsv|separator=_|json=canonical-json-text",
                     "id-domain|name=contract:emergency.TransferReservationAccepted.hospitalId|contract=keiro-dsl/id-domain/typeid-v7/1|prefix=hsp|separator=_|json=canonical-json-text"
                   ]

    it "persists contract ID domains in single-file and workspace records with owner attribution" $ do
      sourceText <- readTestText "test/fixtures/contract-v4.keiro"
      parsed <- case parseSource "contract-v4.keiro" sourceText of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let service = checkedSource parsed
          spec = checkedSpec service
          ctx = defaultContext (spec.context)
          modules = scaffoldServiceModules ctx service
          identities = idDomainIdentitiesForService service
      duplicateIdentity <- case identities of
        value : _ -> pure value
        [] -> expectationFailure "typed contract service did not expose ID-domain identities" >> fail "unreachable"
      withTempDirectory "keiro-dsl-v4-contract-record" $ \out -> do
        result <- executeServiceScaffold out False "contract-v4.keiro" ((.sourceLanguage) parsed) ctx service modules
        result `shouldSatisfy` isRight
        contents <- TIO.readFile (out </> recordFileName (spec.context))
        record <- maybe (expectationFailure "typed contract scaffold record did not parse" >> fail "unreachable") pure (parseRecord contents)
        (.idDomains) record `shouldBe` identities
        parseRecord (contents <> "id-domain " <> duplicateIdentity <> "\n") `shouldBe` Nothing

      let manifest = "service hospital-capacity\nspec domain/contract.keiro\n"
          source = memoryContentSource (Map.fromList [("service.keiro-workspace", manifest), ("domain/contract.keiro", sourceText)])
      loaded <- loadWorkspace source "service.keiro-workspace"
      workspace <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure loaded
      workspacePlan <- either (\refusals -> expectationFailure (show refusals) >> fail "unreachable") pure (planWorkspaceScaffold "goldens" ctx workspace)
      case [provenance | (scaffoldModule, provenance) <- workspacePlan.modules, (.path) scaffoldModule == "Generated/HospitalCapacity/Emergency/Contract.hs"] of
        [MemberOwned owner] -> owner `shouldBe` "domain/contract.keiro"
        values -> expectationFailure ("expected one member-owned contract module, got " <> show values)
      withTempDirectory "keiro-dsl-v4-contract-workspace-record" $ \out -> do
        result <- executeWorkspaceScaffold out False workspacePlan
        result `shouldSatisfy` isRight
        contents <- TIO.readFile (out </> workspaceRecordFileName (workspace.service))
        record <- maybe (expectationFailure "typed contract workspace record did not parse" >> fail "unreachable") pure (parseWorkspaceRecord contents)
        (.idDomains) record `shouldBe` identities
        [((.path) row, (.owner) row) | row <- record.modules, (.path) row == "Generated/HospitalCapacity/Emergency/Contract.hs"]
          `shouldBe` [("Generated/HospitalCapacity/Emergency/Contract.hs", Just "domain/contract.keiro")]
        parseWorkspaceRecord (contents <> "id-domain " <> duplicateIdentity <> "\n") `shouldBe` Nothing
    it "round-trips the contract spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/contract.keiro"
      case parseSource "in" input of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right source -> parseSource "in" (renderSource source) `shouldBe` Right source
    it "round-trips the intake (inbox) spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/intake.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
    it "accepts the intake spec (complete disposition, no inversions)" $ do
      codes <- errorCodesOf "test/fixtures/intake.keiro"
      codes `shouldBe` []
    it "warns when intake bind flags describe unenforced generated behavior" $ do
      codes <- diagnosticCodesOf "test/fixtures/intake.keiro"
      codes `shouldContain` [IntakeBindFlagUnenforced]
    it "lowers explicit dedupe-only persistence and defaults omission to full-envelope" $ do
      spec <- specOf "test/fixtures/intake.keiro"
      ordinary <- specOf "test/fixtures/intake-decode.keiro"
      case ([intake | NIntake intake <- (.nodes) spec], [intake | NIntake intake <- (.nodes) ordinary]) of
        ([intake], [defaultIntake]) -> do
          (.persist) intake `shouldBe` InkPersistDedupeOnly
          (.persist) defaultIntake `shouldBe` InkPersistFull
          renderSpec spec `shouldSatisfy` T.isInfixOf "persist = dedupe-only"
          renderSpec ordinary `shouldNotSatisfy` T.isInfixOf "persist ="
          let inbox = generatedTextEndingIn "Inbox.hs" (scaffoldIntake (defaultContext (spec.context)) intake)
          inbox `shouldSatisfy` T.isInfixOf "inboxPersistence = PersistDedupeOnly"
          inbox `shouldSatisfy` T.isInfixOf "data IncidentInboxOutcome"
          inbox `shouldSatisfy` T.isInfixOf "data IncidentInboxDisposition"
          inbox `shouldSatisfy` T.isInfixOf "InboxRetryAfter !RetryDelay !(Maybe InboxFailure)"
          inbox `shouldSatisfy` T.isInfixOf "InboxDeadLetter !(Maybe Text) !(Maybe InboxFailure)"
          inbox `shouldSatisfy` T.isInfixOf "InboxHandlerFailed reason attempts ->"
          inbox `shouldNotSatisfy` T.isInfixOf "Nothing -> InboxRetry"
        (intakes, defaultIntakes) ->
          expectationFailure ("expected one intake in each fixture, got " <> show (length intakes, length defaultIntakes))
    it "rejects duplicate => retry (inversion 1)" $ do
      codes <- errorCodesOf "test/fixtures/intake-dup-retry.keiro"
      codes `shouldContain` [DispositionDuplicateRetry]
    it "rejects previouslyFailed => retry (inversion 2)" $ do
      codes <- errorCodesOf "test/fixtures/intake-pf-retry.keiro"
      codes `shouldContain` [DispositionPreviouslyFailedRetry]
    it "rejects an incomplete disposition table" $ do
      codes <- errorCodesOf "test/fixtures/intake-incomplete.keiro"
      codes `shouldContain` [DispositionIncomplete]
    it "rejects a shadowing duplicate intake disposition row" $ do
      codes <- errorCodesOf "test/fixtures/intake-dup-row.keiro"
      codes `shouldContain` [DispositionDuplicateOutcome]
    it "rejects intake events declared on another topic" $ do
      codes <- errorCodesOf "test/fixtures/intake-topic-mismatch.keiro"
      codes `shouldContain` [TopicAffinityMismatch]
    it "round-trips the emit/publisher spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/emit.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
    it "accepts the emit/publisher spec (skip present, coupling resolves)" $ do
      codes <- errorCodesOf "test/fixtures/emit.keiro"
      codes `shouldBe` []
    -- `derive … hole` is mandatory emit grammar, so a diagnostic saying it
    -- generates nothing would fire on every emit node in every spec and could
    -- never be resolved. It is the scaffold report's inert-node line (asserted
    -- immediately below) that carries the fact, once per run. See ExecPlan 199.
    it "leaves an emit-bearing spec clean enough for --deny-warnings" $ do
      (exitCode, out, err) <- runKeiroDsl ["check", "test/fixtures/emit.keiro", "--deny-warnings"]
      unless (exitCode == ExitSuccess) (expectationFailure (out <> err))
      err `shouldNotContain` "escalated to failure"
    it "reports emit nodes that contribute no generated modules" $
      withTempDirectory "keiro-dsl-inert-report" $ \out -> do
        spec <- specOf "test/fixtures/emit.keiro"
        report <- executePlannedScaffold out "test/fixtures/emit.keiro" (defaultContext (spec.context)) spec
        (.inertNodes) report `shouldBe` [("emit", "reservationResponse")]
        renderScaffoldReport report
          `shouldSatisfy` any
            ( T.isInfixOf
                "no-modules: emit reservationResponse (validated and diff-classified; no generated modules)"
            )
    it "rejects a missing _ => skip catch-all as EmitSkipMissing" $ do
      codes <- errorCodesOf "test/fixtures/emit-noskip.keiro"
      codes `shouldContain` [EmitSkipMissing]
    it "rejects mapping to an undeclared contract event as EmitUnresolvedContract" $ do
      codes <- errorCodesOf "test/fixtures/emit-badevent.keiro"
      codes `shouldContain` [EmitUnresolvedContract]
    it "rejects emit events declared on another topic" $ do
      codes <- errorCodesOf "test/fixtures/emit-topic-mismatch.keiro"
      codes `shouldContain` [TopicAffinityMismatch]

  describe "pgmq workqueue/dispatch (EP-5)" $ do
    it "round-trips the reservation-work spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/reservation-work.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
    it "accepts the reservation-work spec (physical matches, no inversions)" $ do
      codes <- errorCodesOf "test/fixtures/reservation-work.keiro"
      codes `shouldBe` []
    it "rejects a divergent captured physical name as WqPhysicalDivergence" $ do
      codes <- errorCodesOf "test/fixtures/reservation-work-divergent.keiro"
      codes `shouldContain` [WqPhysicalDivergence]
    it "rejects storeFailure => deadLetter as WqStoreFailureNotRetry" $ do
      codes <- errorCodesOf "test/fixtures/reservation-work-sf-deadletter.keiro"
      codes `shouldContain` [WqStoreFailureNotRetry]
    it "rejects decodeFailure => retry as WqDecodeFailureNotDeadLetter" $ do
      codes <- errorCodesOf "test/fixtures/reservation-work-df-retry.keiro"
      codes `shouldContain` [WqDecodeFailureNotDeadLetter]
    it "requires complete, unique workqueue disposition rows" $ do
      incomplete <- errorCodesOf "test/fixtures/workqueue-incomplete.keiro"
      incomplete `shouldContain` [WqDispositionIncomplete]
      duplicateSpec <- specOf "test/fixtures/workqueue-dup-row.keiro"
      let duplicateDiagnostics = [d | d <- validateSpec duplicateSpec, (.code) d == DispositionDuplicateOutcome]
      map (.line) duplicateDiagnostics `shouldBe` [18]
    it "checks the captured queueRef dlq and table fixtures" $ do
      dlqCodes <- errorCodesOf "test/fixtures/workqueue-dlq-divergent.keiro"
      dlqCodes `shouldContain` [WqDlqDivergence]
      tableCodes <- errorCodesOf "test/fixtures/workqueue-table-divergent.keiro"
      tableCodes `shouldContain` [WqTableDivergence]
    it "matches queueRef for upper-case, punctuation, and hashed logical names" $ do
      upper <- errorCodesOf "test/fixtures/workqueue-uppercase-logical.keiro"
      upper `shouldBe` []
      hashed <- errorCodesOf "test/fixtures/workqueue-hashed-logical.keiro"
      hashed `shouldBe` []
      derivedQueueTrio "hospital_capacity.reservation_work.per_hospital_fifo_lane_assignments"
        `shouldBe` ( "hospital_capacity_reservat_757040df00976c33",
                     "hospital_capacity_reservat_757040df00976c33_dlq",
                     "pgmq.q_hospital_capacity_reservat_757040df00976c33"
                   )
    it "resolves dispatch dedup queues and payload wire fields" $ do
      ghost <- errorCodesOf "test/fixtures/dispatch-dedup-ghost-queue.keiro"
      ghost `shouldContain` [DispatchDedupQueueUnresolved]
      field <- errorCodesOf "test/fixtures/dispatch-dedup-bad-field.keiro"
      field `shouldContain` [DispatchDedupFieldUnresolved]
    it "requires a resolvable group key exactly when ordering is FIFO" $ do
      noKey <- errorCodesOf "test/fixtures/reservation-work-fifo-nokey.keiro"
      noKey `shouldContain` [WqGroupKeyMissing]
      unordered <- errorCodesOf "test/fixtures/reservation-work-key-unordered.keiro"
      unordered `shouldContain` [WqGroupKeyWithoutFifo]
      source <- readTestText "test/fixtures/reservation-work.keiro"
      unresolved <- parseInlineSpec "<unresolved-group-key>" (T.replace "group key from reservationId" "group key from missingId" source)
      map (.code) (validateSpec unresolved) `shouldContain` [WqGroupKeyUnresolved]
    it "warns on unlogged storage and rejects empty partition settings" $ do
      warningCodes <- diagnosticCodesOf "test/fixtures/reservation-work-unlogged.keiro"
      warningCodes `shouldContain` [WqUnloggedDurability]
      partitionCodes <- errorCodesOf "test/fixtures/reservation-work-partitioned-empty.keiro"
      partitionCodes `shouldContain` [WqPartitionSpecEmpty]
    -- Every payload field is required — generated decoders use `o .:` for all of
    -- them — so the marker no longer selects anything. A source that omits it and
    -- a source that writes it describe the same queue and produce identical
    -- output. See ExecPlan 199.
    it "treats a payload field as required whether or not the marker is written" $ do
      unmarkedSource <- readTestText "test/fixtures/reservation-work-optfield.keiro"
      let bare = "    note -> \"note\" text"
          markedSource = T.replace bare (bare <> " required") unmarkedSource
      unmarkedSource `shouldSatisfy` T.isInfixOf bare
      parseSpec "unmarked" unmarkedSource `shouldBe` parseSpec "marked" markedSource
      errorCodesOf "test/fixtures/reservation-work-optfield.keiro" >>= (`shouldBe` [])
    it "lowers ordering, provisioning, and raw group-key projection" $ do
      spec <- specOf "test/fixtures/reservation-work.keiro"
      case [workqueue | NWorkqueue workqueue <- (.nodes) spec] of
        workqueue : _ -> do
          let modules = scaffoldWorkqueue (defaultContext (spec.context)) workqueue
              queue = generatedTextEndingIn "Queue.hs" modules
              policy = generatedTextEndingIn "QueuePolicy.hs" modules
          queue `shouldSatisfy` T.isInfixOf "groupKeyFor payload = payload.reservationId"
          policy `shouldSatisfy` T.isInfixOf "jobOrdering = FifoThroughput"
          policy `shouldSatisfy` T.isInfixOf "withFifoIndexProvision (standardProvision)"
          policy `shouldSatisfy` T.isInfixOf "data ReservationWorkOutcome"
          policy `shouldSatisfy` T.isInfixOf "jobOutcomeFor :: ReservationWorkOutcome -> JobOutcome"
          policy `shouldNotSatisfy` T.isInfixOf "jobOutcomeFor :: Text -> JobOutcome"
          policy `shouldNotSatisfy` T.isInfixOf "  _ -> Retry"
          firewallBreaches modules `shouldBe` []
        [] -> expectationFailure "reservation-work fixture has no workqueue"

  describe "readmodel (EP-107)" $ do
    it "parses and round-trips first-class read models" $ do
      spec <- specOf "test/fixtures/readmodel.keiro"
      case [readModel | NReadModel readModel <- (.nodes) spec] of
        [subscriptionModel, inlineModel] -> do
          (.name) subscriptionModel `shouldBe` "transfer_decisions"
          (.columns) subscriptionModel
            `shouldBe` [ RmColumn "reservation_id" "text" True,
                         RmColumn "hospital_id" "text" True,
                         RmColumn "status" "text" True,
                         RmColumn "decided_at" "timestamptz" False
                       ]
          legacyReadModelScope subscriptionModel `shouldBe` Just (RmCategory "reservation")
          legacyReadModelFeed subscriptionModel `shouldBe` Just RmSubscription
          legacyReadModelSubscription subscriptionModel `shouldBe` Just "hospital-capacity-transfer-decisions-sub"
          (.name) inlineModel `shouldBe` "subscriptions"
          legacyReadModelScope inlineModel `shouldBe` Nothing
          legacyReadModelFeed inlineModel `shouldBe` Just RmInline
        nodes -> expectationFailure ("expected two readmodel nodes, got " <> show (length nodes))
      parseLanguage4RenderedSpec "in" spec `shouldBe` Right spec
    it "accepts an aggregate projection without a consistency clause" $ do
      spec <- parseInlineSpec "<projection-without-consistency>" projectionWithoutConsistencySpec
      case [projection | NAggregate aggregate <- (.nodes) spec, Just projection <- [(.projection) aggregate]] of
        [projection] -> (.consistency) projection `shouldBe` Nothing
        projections -> expectationFailure ("expected one projection, got " <> show (length projections))
    it "pins the canonical UTF-8 shape digest and runtime identities" $ do
      spec <- specOf "test/fixtures/readmodel.keiro"
      case [readModel | NReadModel readModel <- (.nodes) spec] of
        (subscriptionModel : inlineModel : _) -> do
          canonicalShape subscriptionModel
            `shouldBe` "transfer_decisions|reservation_id:text:req|hospital_id:text:req|status:text:req|decided_at:timestamptz:null"
          deriveShapeHash subscriptionModel `shouldBe` "fnv1a:3717f6d9e3c44bd6"
          deriveShapeHash inlineModel `shouldBe` "fnv1a:f54d9bb2f40a6738"
          registryNameFor (spec.context) subscriptionModel `shouldBe` "hospital-capacity-transfer-decisions"
          subscriptionNameFor (spec.context) subscriptionModel `shouldBe` "hospital-capacity-transfer-decisions-sub"
          subscriptionNameFor "billing" inlineModel `shouldBe` "billing-subscriptions-sub"
        nodes -> expectationFailure ("expected readmodel nodes, got " <> show (length nodes))
    it "accepts the positive readmodel fixture with all references resolved" $ do
      spec <- specOf "test/fixtures/readmodel.keiro"
      validateSpec spec `shouldBe` []
    it "rejects shape drift and unknown SQL column types" $ do
      codes <- errorCodesOf "test/fixtures/readmodel-shape-drift.keiro"
      codes `shouldContain` [RmShapeHashDrift, RmUnknownColumnType]
    it "rejects Strong on inline and standalone projections" $ do
      inlineCodes <- errorCodesOf "test/fixtures/readmodel-strong-inline.keiro"
      inlineCodes `shouldContain` [RmStrongInlineOnly]
      standalone <- specOf "test/fixtures/readmodel-strong-standalone.keiro"
      let diagnostics = validateSpec standalone
      map (.code) diagnostics `shouldContain` [RmStrongInlineOnly, RmProjectionWithoutNode]
      [(.severity) diagnostic | diagnostic <- diagnostics, (.code) diagnostic == RmProjectionWithoutNode]
        `shouldBe` [Warning]
    it "rejects scope without Strong and an unreferenced inline feed" $ do
      scopeCodes <- errorCodesOf "test/fixtures/readmodel-scope-eventual.keiro"
      scopeCodes `shouldContain` [RmScopeWithoutStrong]
      inlineCodes <- errorCodesOf "test/fixtures/readmodel-inline-unreferenced.keiro"
      inlineCodes `shouldContain` [RmInlineFeedUnreferenced]
    it "warns when an inline feed carries an ignored subscription override" $ do
      source <- readTestText "test/fixtures/readmodel.keiro"
      spec <-
        parseInlineSpec
          "<inline-subscription>"
          (T.replace "  feed = inline\n" "  feed = inline\n  subscription = \"ignored-subscription\"\n" source)
      diagnosticCodes spec `shouldContain` [RmInlineSubscriptionIgnored]
    it "rejects projection consistency conflicts" $ do
      codes <- errorCodesOf "test/fixtures/readmodel-consistency-conflict.keiro"
      codes `shouldContain` [RmConsistencyConflict]
    it "resolves query read models and validates query consistency" $ do
      codes <- errorCodesOf "test/fixtures/readmodel-query-unresolved.keiro"
      codes `shouldContain` [QueryUnresolvedReadModel, QueryConsistencyInvalid]
    it "resolves dispatch read models and declared dedup columns" $ do
      codes <- errorCodesOf "test/fixtures/readmodel-dispatch-unresolved.keiro"
      codes `shouldContain` [DispatchReadModelUnresolved, DispatchReadModelFieldUnknown]
    it "scaffolds runtime records, rebuild helpers, async wiring, and typed holes" $ do
      spec <- specOf "test/fixtures/readmodel.keiro"
      let ctx = defaultContext (spec.context)
          readModels = [readModel | NReadModel readModel <- (.nodes) spec]
          modules = concatMap (scaffoldReadModel ctx) readModels
          transfer = generatedTextEndingIn "TransferDecisions/ReadModel.hs" modules
          inline = generatedTextEndingIn "Subscriptions/ReadModel.hs" modules
          transferHoles = [(.text) m | m <- modules, "TransferDecisions/ReadModelHoles.hs" `T.isSuffixOf` T.pack ((.path) m)]
      length modules `shouldBe` 6
      length [m | m <- modules, (.kind) m == Generated] `shouldBe` 4
      length [m | m <- modules, (.kind) m == HoleStub] `shouldBe` 2
      firewallBreaches modules `shouldBe` []
      transfer `shouldSatisfy` T.isInfixOf "registerTransferDecisions"
      transfer `shouldSatisfy` T.isInfixOf "Rebuild.startRebuild transferDecisionsReadModel [\"hospital-capacity-transfer-decisions-async\"]"
      transfer `shouldSatisfy` T.isInfixOf "strongScope = CategoryHead \"reservation\""
      transfer `shouldSatisfy` T.isInfixOf "transferDecisionsAsyncProjection"
      inline `shouldSatisfy` T.isInfixOf "Rebuild.startRebuild subscriptionsReadModel []"
      inline `shouldNotSatisfy` T.isInfixOf "AsyncProjection"
      transferHoles `shouldSatisfy` any (T.isInfixOf "RecordedEvent -> Tx.Transaction ()")
    it "threads qualified table and column guidance into aggregate projection holes" $ do
      spec <- specOf "test/fixtures/readmodel.keiro"
      case [aggregate | NAggregate aggregate <- (.nodes) spec] of
        [aggregate] -> do
          let modules = scaffoldAggregate (defaultContext (spec.context)) spec aggregate
              holes = [(.text) m | m <- modules, (.kind) m == HoleStub]
              projection = generatedTextEndingIn "Projection.hs" modules
          holes `shouldSatisfy` any (T.isInfixOf "subscriptionsQualifiedTable")
          holes `shouldSatisfy` any (T.isInfixOf "Table: \"billing\".\"subscriptions\"")
          projection `shouldSatisfy` T.isInfixOf "ReadModelTable.subscriptionsQualifiedTable"
        aggregates -> expectationFailure ("expected one aggregate, got " <> show (length aggregates))
    it "emits runtime-free derivation facts for each read model" $ do
      spec <- specOf "test/fixtures/readmodel.keiro"
      case [readModel | NReadModel readModel <- (.nodes) spec] of
        (subscriptionModel : _) -> do
          let modules = harnessReadModel (defaultContext (spec.context)) spec subscriptionModel
              harnessText = generatedTextEndingIn "ReadModelHarness.hs" modules
          length modules `shouldBe` 1
          firewallBreaches modules `shouldBe` []
          harnessText `shouldNotSatisfy` T.isInfixOf "{-# LANGUAGE OverloadedRecordDot #-}"
          harnessText `shouldSatisfy` T.isInfixOf "import Generated.HospitalCapacity.TransferDecisions.ReadModel (transferDecisionsReadModel, transferDecisionsAsyncProjection)"
          harnessText `shouldSatisfy` T.isInfixOf "(\"shapeHash\", \"fnv1a:3717f6d9e3c44bd6\", T.unpack transferDecisionsReadModel.shapeHash)"
          harnessText `shouldSatisfy` T.isInfixOf "(\"strongScope\", \"CategoryHead reservation\", renderStrongScope transferDecisionsReadModel.strongScope)"
          harnessText `shouldSatisfy` T.isInfixOf "T.unpack transferDecisionsAsyncProjection.name"
          harnessText `shouldSatisfy` T.isInfixOf "runReadModelFacts"
        nodes -> expectationFailure ("expected readmodel nodes, got " <> show (length nodes))

  describe "workflow/operation (EP-6)" $ do
    it "round-trips the workflow spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/workflow.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseLanguage4RenderedSpec "in" spec `shouldBe` Right spec
    it "accepts the workflow spec (await<->signal matches, run resolves)" $ do
      codes <- errorCodesOf "test/fixtures/workflow.keiro"
      codes `shouldBe` []
    it "rejects a signal label with no matching await as AwaitSignalMismatch" $ do
      codes <- errorCodesOf "test/fixtures/workflow-signal-mismatch.keiro"
      codes `shouldContain` [AwaitSignalMismatch]
    it "rejects duplicate workflow labels" $ do
      codes <- errorCodesOf "test/fixtures/workflow-dup-label.keiro"
      codes `shouldContain` [WorkflowDuplicateLabel]
    it "rejects unresolved workflow id and sleep fields" $ do
      codes <- errorCodesOf "test/fixtures/workflow-unresolved-fields.keiro"
      codes `shouldContain` [WorkflowIdFieldUnresolved, WorkflowSleepDelayUnresolved]
    it "validates rule domains, totality, case constructors, and bodies" $ do
      unresolved <- errorCodesOf "test/fixtures/rule-bad-domain.keiro"
      unresolved `shouldBe` [RuleDomainUnresolved]
      codes <- errorCodesOf "test/fixtures/rule-not-total.keiro"
      mapM_
        (\expected -> codes `shouldContain` [expected])
        [RuleNotTotal, RuleCaseUnknownCtor, ClockSampled, GuardAtomOutOfScope]
    it "rejects unresolved command operation references" $ do
      codes <- errorCodesOf "test/fixtures/operation-ghost-aggregate.keiro"
      codes `shouldContain` [OperationUnresolvedRef]
    it "rejects a signal value type that differs from its await" $ do
      codes <- errorCodesOf "test/fixtures/operation-signal-value.keiro"
      codes `shouldContain` [AwaitSignalValueMismatch]
    it "round-trips guarded patches and terminal continueAsNew" $ do
      input <- readTestText "test/fixtures/workflow-evolution.keiro"
      case parseSpec "workflow-evolution" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> do
          parseSpec "workflow-evolution" (renderSpec spec) `shouldBe` Right spec
          errorCodes spec `shouldBe` []
    it "rejects duplicate patch ids anywhere in the workflow body" $ do
      codes <- errorCodesOf "test/fixtures/workflow-patch-dup.keiro"
      codes `shouldBe` [WorkflowPatchDuplicate]
    it "rejects non-terminal and nested continueAsNew" $ do
      codes <- errorCodesOf "test/fixtures/workflow-can-mid.keiro"
      codes `shouldBe` [WorkflowContinueAsNewNotTerminal, WorkflowContinueAsNewNotTerminal]
    it "rejects a colon in a patch id with a workflow diagnostic" $ do
      codes <- errorCodesOf "test/fixtures/workflow-patch-colon.keiro"
      codes `shouldBe` [WorkflowPatchIdInvalid]
    it "lowers patch facts and live runtime declarations" $ do
      spec <- specOf "test/fixtures/workflow-evolution.keiro"
      case [workflow | NWorkflow workflow <- (.nodes) spec] of
        [workflow] -> do
          let modules = harnessWorkflow (defaultContext (spec.context)) workflow
              facts = generatedTextEndingIn "WorkflowFacts.hs" modules
              runtime = generatedTextEndingIn "WorkflowRuntime.hs" modules
          facts `shouldSatisfy` T.isInfixOf "patch:fraud-check-v2(step:fraud-check)"
          facts `shouldSatisfy` T.isInfixOf "continueAsNew:RolloverSeed"
          facts `shouldSatisfy` T.isInfixOf "data WorkflowFacts = WorkflowFacts"
          facts `shouldSatisfy` T.isInfixOf "workflowFactBody = [\"step:create-transfer-hold\", \"patch:fraud-check-v2(step:fraud-check)\""
          facts `shouldSatisfy` T.isInfixOf "workflowFactAwaitLabels = [\"reservation-confirmation\"]"
          facts `shouldSatisfy` T.isInfixOf "workflowFactPatchIds = [\"fraud-check-v2\"]"
          runtime `shouldSatisfy` T.isInfixOf "data AwaitBinding = AwaitBinding StepName"
          runtime `shouldSatisfy` T.isInfixOf "reservationConfirmationAwait :: AwaitBinding"
          runtime `shouldSatisfy` T.isInfixOf "reservationConfirmationAwait = AwaitBinding (StepName \"reservation-confirmation\")"
          runtime `shouldSatisfy` T.isInfixOf "allocateDeclaredAwait (AwaitBinding label) = awakeableNamed label"
          runtime `shouldSatisfy` (not . T.isInfixOf "awaitAwakeableId")
          runtime `shouldSatisfy` (not . T.isInfixOf "generation0AwakeableId")
          runtime `shouldSatisfy` (not . T.isInfixOf "Awakeable.Compatibility")
          runtime `shouldSatisfy` T.isInfixOf "declaredPatches = Set.fromList [PatchId \"fraud-check-v2\"]"
          runtime `shouldSatisfy` T.isInfixOf "opts{activePatches = declaredPatches}"
        workflows -> expectationFailure ("expected one workflow, got " <> show (length workflows))
    it "rejects colliding await binding names, including an await nested under a patch" $ do
      spec <-
        parseInlineSpec "<workflow-await-binding-collision>" $
          T.unlines
            [ "language keiro-dsl 4",
              "context await-binding-collision",
              "workflow CollisionWorkflow",
              "  name \"collision-workflow\"",
              "  in Input",
              "  out Output",
              "  id from input via idText",
              "  body",
              "    patch nested-proof {",
              "      await foo-bar -> Text",
              "    }",
              "    await foo_bar -> Text"
            ]
      let collisions = [diagnostic | diagnostic <- validateSpec spec, (.code) diagnostic == GeneratedOccurrenceCollision]
      length collisions `shouldBe` 1
      map (.message) collisions `shouldSatisfy` any (T.isInfixOf "fooBarAwait")
      collisions `shouldSatisfy` all (not . null . (.relatedLocations))

  describe "replay impact" $ do
    it "treats new events and transitions as replay-neutral" $ do
      old <- specOf "test/fixtures/reservation.keiro"
      let aggregate = onlyAggregate old
      case ((.events) aggregate, (.transitions) aggregate) of
        (event : _, transition : _) -> do
          let newEvent = eventWithNameAndLoc "ReservationReviewed" noLoc event
              newTransition =
                transition
                  { emits = ["ReservationReviewed"],
                    loc = noLoc
                  }
              new =
                modifyAggregate
                  "Reservation"
                  ( \candidate ->
                      candidate
                        { events = (.events) candidate <> [newEvent],
                          transitions = (.transitions) candidate <> [newTransition]
                        }
                  )
                  old
          replayImpactSpecs old new `shouldBe` ReplayNeutral
        _ -> expectationFailure "reservation fixture must contain an event and transition"

    it "narrows a guard edit to that transition's event types" $ do
      impact <- replayImpactFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-guard-tightened.keiro"
      impact
        `shouldBe` ReplayAffected
          ( Map.singleton
              "Reservation"
              AggregateImpact
                { eventTypes = Set.singleton "TransferReservationCreated",
                  includeSnapshotStreams = True
                }
          )

    it "proves a syntactic guard loosening replay-neutral" $ do
      old <- specOf "test/fixtures/reservation.keiro"
      let loosened =
            modifyAggregate
              "Reservation"
              ( \aggregate ->
                  aggregate
                    { transitions =
                        [ transition {guard = Nothing}
                        | transition <- (.transitions) aggregate
                        ]
                    }
              )
              old
      replayImpactSpecs old loosened `shouldBe` ReplayNeutral

    it "pairs guard-disambiguated siblings independently of both declaration orders" $ do
      base <- specOf "test/fixtures/reservation.keiro"
      let aggregate = onlyAggregate base
      case ((.transitions) aggregate, (.events) aggregate) of
        (prototype : _, firstEvent : secondEvent : _) -> do
          let sibling guardExpression eventName =
                prototype
                  { guard = guardExpression,
                    emits = [eventName],
                    loc = noLoc
                  }
              commandOverride = EPath noLoc CommandRoot ["lifeCriticalOverride"]
              exact = sibling (Just (EAtom (ABool True))) ((.name) firstEvent)
              loosenedOld = sibling (Just commandOverride) ((.name) firstEvent)
              loosenedNew = sibling Nothing ((.name) firstEvent)
              changedOld = sibling (Just (ECmp OpEq commandOverride (ELiteral noLoc (LiteralBool False)))) ((.name) secondEvent)
              changedNew = sibling (Just (ECmp OpEq commandOverride (ELiteral noLoc (LiteralBool True)))) ((.name) firstEvent)
              oldSiblings = [exact, loosenedOld, changedOld]
              newSiblings = [exact, loosenedNew, changedNew]
              withTransitions transitions =
                modifyAggregate
                  ((.name) aggregate)
                  (\candidate -> candidate {transitions = transitions})
                  base
              impacts =
                [ replayImpactSpecs (withTransitions oldOrder) (withTransitions newOrder)
                | oldOrder <- permutations oldSiblings,
                  newOrder <- permutations newSiblings
                ]
          case impacts of
            firstImpact : remainingImpacts -> do
              remainingImpacts `shouldSatisfy` all (== firstImpact)
              firstImpact `shouldSatisfy` (/= ReplayNeutral)
            [] -> expectationFailure "permutations unexpectedly produced no replay comparisons"
        _ -> expectationFailure "reservation fixture must contain one transition and two events"

    it "marks every existing event when the aggregate wire convention changes" $ do
      impact <- replayImpactFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-wire.keiro"
      case impact of
        ReplayAffected aggregates ->
          (.eventTypes) <$> Map.lookup "Reservation" aggregates
            `shouldBe` Just (Set.fromList ["TransferReservationCreated", "TransferReservationConfirmed"])
        ReplayNeutral -> expectationFailure "expected a wire-clause replay impact"

    it "includes snapshot streams when a write expression changes" $ do
      impact <- replayImpactFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-foldchange.keiro"
      case impact of
        ReplayAffected aggregates ->
          (.includeSnapshotStreams) <$> Map.lookup "Reservation" aggregates
            `shouldBe` Just True
        ReplayNeutral -> expectationFailure "expected a fold replay impact"

    it "detects codec evolution and ignores formatting-only rewrites" $ do
      changed <- replayImpactFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-v2.keiro"
      changed `shouldSatisfy` (/= ReplayNeutral)
      old <- specOf "test/fixtures/reservation.keiro"
      formatted <- shouldParseStableRenderedSpec "<formatted>" old
      replayImpactSpecs old formatted `shouldBe` ReplayNeutral

    it "names mapped nested event and snapshot roots while ignoring Haskell-only changes" $ do
      nested <- replayImpactFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-nested-propagation.keiro"
      case nested of
        ReplayAffected aggregates ->
          Map.lookup "Catalog" aggregates
            `shouldBe` Just AggregateImpact {eventTypes = Set.singleton "ArtifactObserved", includeSnapshotStreams = True}
        ReplayNeutral -> expectationFailure "expected nested mapped wire change to affect replay"
      sourceOnly <- replayImpactFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-haskell-rename.keiro"
      sourceOnly `shouldBe` ReplayNeutral

    it "generates one context target for every aggregate, including the process saga" $ do
      spec <- specOf "test/fixtures/surge-service.keiro"
      case scaffoldReplayAudit (defaultContext (spec.context)) spec of
        [assembly] -> do
          (.path) assembly `shouldBe` "Generated/SurgeDemo/ReplayAudit.hs"
          (.text) assembly `shouldSatisfy` T.isInfixOf "Hospital.hospitalEventStream"
          (.text) assembly `shouldSatisfy` T.isInfixOf "Surge.surgeEventStream"
          T.count "      AuditTarget" ((.text) assembly) `shouldBe` 2
        assemblies -> expectationFailure ("expected one replay-audit assembly, got " <> show (length assemblies))

  describe "diff (evolution classification)" $ do
    it "covers every node family exactly once and explains exclusions" $ do
      sort (map fst familyRegistry) `shouldBe` ([minBound .. maxBound] :: [NodeFamily])
      [reason | (_, OutOfDiffScope reason) <- familyRegistry, T.null reason] `shouldBe` []
    it "reports checked mapped consumers separately from compatibility findings" $ do
      old <- specOf "test/fixtures/semantic-impact.keiro"
      let new = mapMappedStructural "NestedPayload" changeMappedCanonical old
          changes = diffSpecs old new
          impact = CheckedDiff.mappedSemanticImpact old new
          rendered = T.unlines (renderSemanticImpact impact)
          encoded = LazyText.toStrict (LazyTextEncoding.decodeUtf8 (Aeson.encode (diffReportWithSemanticImpact defaultGate changes impact)))
      map (.declaration) impact `shouldBe` [MappedKey "NestedPayload"]
      rendered `shouldSatisfy` T.isInfixOf "previous aggregate consumers: Alpha"
      rendered `shouldSatisfy` T.isInfixOf "current aggregate consumers:  Alpha"
      rendered `shouldSatisfy` T.isInfixOf "service-conformance: impacted"
      rendered `shouldSatisfy` (not . T.isInfixOf "Beta")
      encoded `shouldSatisfy` T.isInfixOf "\"semanticImpact\""
      encoded `shouldSatisfy` T.isInfixOf "\"previousConsumers\":[\"Alpha\"]"
      let reordered = old {mapped = reverse ((.mapped) old), nodes = reverse ((.nodes) old)}
      CheckedDiff.mappedSemanticImpact old reordered `shouldBe` []
    it "reports added, removed, and unused mapped declarations without inventing aggregate consumers" $ do
      let declarationA = completeStructural "A" (recordShape [TText])
          declarationB = completeStructural "B" (recordShape [TInt])
          onlyA = mappedSpec [declarationA]
          withB = mappedSpec [declarationA, declarationB]
          added = CheckedDiff.mappedSemanticImpact onlyA withB
          removed = CheckedDiff.mappedSemanticImpact withB onlyA
          expectedB = MappedKey "B"
      map (.declaration) added `shouldBe` [expectedB]
      map (.previousConsumers) added `shouldBe` [Set.empty]
      map (.currentConsumers) added `shouldBe` [Set.empty]
      map (.serviceConformance) added `shouldBe` [True]
      map (.declaration) removed `shouldBe` [expectedB]
      map (.previousConsumers) removed `shouldBe` [Set.empty]
      map (.currentConsumers) removed `shouldBe` [Set.empty]
      map (.serviceConformance) removed `shouldBe` [True]

      old <- specOf "test/fixtures/semantic-impact.keiro"
      let changed = mapMappedStructural "UnusedPayload" changeMappedCanonical old
          unusedImpact = CheckedDiff.mappedSemanticImpact old changed
      map (.declaration) unusedImpact `shouldBe` [MappedKey "UnusedPayload"]
      map (.previousConsumers) unusedImpact `shouldBe` [Set.empty]
      map (.currentConsumers) unusedImpact `shouldBe` [Set.empty]
      map (.serviceConformance) unusedImpact `shouldBe` [True]
    it "derives every exercised headline from its vector under the default gate" $ do
      changes <-
        concat
          <$> mapM
            (uncurry diffFixtures)
            [ ("test/fixtures/reservation.keiro", "test/fixtures/reservation-fieldadd.keiro"),
              ("test/fixtures/reservation.keiro", "test/fixtures/reservation-v2.keiro"),
              ("test/fixtures/reservation.keiro", "test/fixtures/reservation-enumadd.keiro"),
              ("test/fixtures/contract.keiro", "test/fixtures/contract-fieldadd.keiro"),
              ("test/fixtures/reservation-work.keiro", "test/fixtures/reservation-work-rename.keiro")
            ]
      forM_ changes $ \change ->
        do
          deriveLabel defaultGate ((kindOfChange change).vector)
            `shouldBe` labelOfChange change
          gatedBreaking defaultGate change `shouldBe` isBreaking change
    it "never removes a breaking result when the gate grows" $
      property $
        forAll genCompatibilityVector $ \compatibility ->
          forAll genSurfaceSet $ \gate ->
            forAll genSurfaceSet $ \extra ->
              deriveLabel gate compatibility
                == LabelBreaking
                  ==> deriveLabel (gate <> extra) compatibility
                == LabelBreaking
    it "renders the consumer-neutral matrix with separate private, snapshot, and public surfaces" $ do
      changes <- diffFixtures "test/fixtures/compatibility-vector-old.keiro" "test/fixtures/compatibility-vector-new.keiro"
      let rendered = T.intercalate "\n" (map renderFinding changes)
          explained = T.intercalate "\n" (map renderExplainBlock changes)
          reportJson = T.pack (show (Aeson.toJSON (diffReport defaultGate changes)))
      assertMatchesGolden "test/fixtures/compatibility-vector.diff.golden" rendered
      rendered `shouldSatisfy` T.isInfixOf "Reservation.event.TransferReservationCreated.patientAcuity"
      rendered `shouldSatisfy` T.isInfixOf "old-binary-read-new-events=breaking"
      rendered `shouldSatisfy` T.isInfixOf "snapshot-hydration=advisory"
      rendered `shouldSatisfy` T.isInfixOf "public-consumer=breaking"
      explained `shouldSatisfy` T.isInfixOf "invalidate and rebuild snapshots"
      reportJson `shouldSatisfy` T.isInfixOf "keiro-dsl/diff-report/1"
      reportJson `shouldSatisfy` T.isInfixOf "Reservation.event.TransferReservationCreated.patientAcuity"
      let eventEnumFindings =
            [ change
            | change@(Advisory kind) <- changes,
              (.code) kind == EnumCtorAdded,
              verdictFor OldBinaryReadNewEvents (kind.vector) == VBreaking
            ]
      eventEnumFindings `shouldSatisfy` all (not . gatedBreaking defaultGate)
      eventEnumFindings `shouldSatisfy` all (gatedBreaking (gateWith [OldBinaryReadNewEvents]))
      forM_ changes $ \change ->
        remediationFor ((kindOfChange change).context) ((.code) (kindOfChange change))
          `shouldSatisfy` (not . null)
    it "rejects unknown --gate values with the valid surface list" $ do
      parseSurfaceName "mystery-surface"
        `shouldSatisfy` either (T.isInfixOf "old-binary-read-new-events" . T.pack) (const False)
    it "covers the mapped evolution matrix with stable codes and non-empty remedies" $ do
      let cases =
            [ ("consumer-types-fieldadd-default.keiro", MappedFieldAddedWithDefault),
              ("consumer-types-fieldadd-nodefault.keiro", MappedFieldAddedNoDefault),
              ("consumer-types-fieldremove.keiro", MappedFieldRemoved),
              ("consumer-types-wirekey.keiro", MappedWireKeyChanged),
              ("consumer-types-haskell-rename.keiro", MappedHaskellSourceChanged),
              ("consumer-types-binding-change.keiro", MappedBindingChanged),
              ("consumer-types-fixtures-change.keiro", MappedFixturesChanged),
              ("consumer-types-initial-change.keiro", MappedInitialChanged),
              ("consumer-types-armadd.keiro", MappedArmAdded),
              ("consumer-types-tagchange.keiro", MappedArmTagChanged),
              ("consumer-types-enumadd.keiro", MappedEnumValueAdded),
              ("consumer-types-enumremove.keiro", MappedEnumValueRemoved),
              ("consumer-types-enumspelling.keiro", MappedEnumSpellingChanged),
              ("consumer-types-encoding.keiro", MappedUnionEncodingChanged),
              ("consumer-types-opaque-version.keiro", MappedOpaqueCodecChanged),
              ("consumer-types-mode-cross.keiro", MappedModeCrossed),
              ("consumer-types-nested-propagation.keiro", MappedArmTagChanged)
            ]
      forM_ cases $ \(fixture, expectedCode) -> do
        changes <- diffFixtures "test/fixtures/consumer-types.keiro" ("test/fixtures/" <> fixture)
        map ((.code) . kindOfChange) changes `shouldContain` [expectedCode]
        forM_ changes $ \change ->
          remediationFor ((kindOfChange change).context) ((.code) (kindOfChange change))
            `shouldSatisfy` (not . null)
    it "separates mapped event migration, snapshot invalidation, and directional rollout" $ do
      breakingAdd <- diffFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-fieldadd-nodefault.keiro"
      let noDefault = [change | change <- breakingAdd, (.code) (kindOfChange change) == MappedFieldAddedNoDefault]
      [(.facet) kind | Breaking kind <- noDefault] `shouldContain` ["mapped-event"]
      [(.facet) kind | Advisory kind <- noDefault] `shouldContain` ["mapped-register"]
      defaulted <- diffFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-fieldadd-default.keiro"
      [change | change <- defaulted, isBreaking change] `shouldBe` []
      let eventDefaults = [kind | Advisory kind <- defaulted, (.code) kind == MappedFieldAddedWithDefault, (.facet) kind == "mapped-event"]
      eventDefaults `shouldSatisfy` any ((== VBreaking) . verdictFor OldBinaryReadNewEvents . (.vector))
      armAdded <- diffFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-armadd.keiro"
      [change | change <- armAdded, isBreaking change] `shouldBe` []
      [kind | Advisory kind <- armAdded, (.code) kind == MappedArmAdded, (.facet) kind == "mapped-event"]
        `shouldSatisfy` any ((== VBreaking) . verdictFor OldBinaryReadNewEvents . (.vector))
    it "classifies mapped queue history without borrowing event or snapshot surfaces" $ do
      source <- mappedConsumerSurfaceSource
      base <- parseInlineSpec "<mapped-queue-diff-old>" source
      let candidate = mapArtifactNamedField "key" (wireFieldWithKey "artifact_key_v2") base
          queueFindings =
            [ kind
            | change <- diffSpecs base candidate,
              let kind = kindOfChange change,
              (.facet) kind == "mapped-workqueue"
            ]
      queueFindings `shouldSatisfy` (not . null)
      forM_ queueFindings $ \kind -> do
        verdictFor PrivateHistoryRead (kind.vector) `shouldBe` VNotApplicable
        verdictFor OldBinaryReadNewEvents (kind.vector) `shouldBe` VNotApplicable
        verdictFor SnapshotHydration (kind.vector) `shouldBe` VNotApplicable
        verdictFor ConsumerBuild (kind.vector) `shouldBe` VBreaking
        (.rollout) (kind.vector) `shouldBe` Set.fromList [RolloutWorkersFirst, RolloutDrainRequired]
        (.mappedPersistedImpact) kind
          `shouldBe` Just (MappedPersistedImpact (WorkqueueHistory "ArtifactJobs") VBreaking)
        (.detail) kind `shouldSatisfy` T.isInfixOf "schema-version-1 history"
        remediationFor (kind.context) ((.code) kind)
          `shouldSatisfy` all (`elem` [RemedyDeploymentOrder RolloutWorkersFirst, RemedyDrainWorkqueue, RemedyTransitionalQueueCodec, RemedyRecompileConsumers, RemedyRunConformance])
    it "propagates a nested mapped leaf to complete command, event, and register paths" $ do
      changes <- diffFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-nested-propagation.keiro"
      let subjects =
            [ (.subject) kind
            | change <- changes,
              let kind = kindOfChange change,
              (.code) kind == MappedArmTagChanged
            ]
      subjects
        `shouldContain` [ "Catalog command ObserveArtifact .artifact : ArtifactInfo .location : ArtifactLocation .arm RepoPath[\"repository_path\"]",
                          "Catalog event ArtifactObserved .artifact : ArtifactInfo .location : ArtifactLocation .arm RepoPath[\"repository_path\"]",
                          "Catalog register currentArtifact : ArtifactInfo .location : ArtifactLocation .arm RepoPath[\"repository_path\"]"
                        ]
    it "classifies every remaining mapped field and declaration evolution row" $ do
      base <- specOf "test/fixtures/consumer-types.keiro"
      let mutationCodes =
            [ (mapArtifactNamedField "key" (wireFieldWithValueType TInt) base, MappedFieldTypeChanged),
              (mapArtifactNamedField "key" (wireFieldWithPresenceAndDefault POptional (Just (OmText ""))) base, MappedPresenceChanged),
              (mapArtifactNamedField "key" (wireFieldWithValueType (TOptional TText)) base, MappedNullabilityChanged),
              (mapArtifactNamedField "description" (wireFieldWithOnMissing Nothing) base, MappedDefaultRemoved),
              (mapArtifactNamedField "count" (wireFieldWithOnMissing (Just (OmInt 1))) base, MappedDefaultChanged),
              (mapMappedStructural "ArtifactInfo" renameMappedRecordConstructor base, MappedRecordConstructorChanged),
              (mapMappedStructural "ArtifactInfo" changeMappedCanonical base, MappedCanonicalTypeChanged)
            ]
      forM_ mutationCodes $ \(candidate, expectedCode) ->
        map ((.code) . kindOfChange) (diffSpecs base candidate) `shouldContain` [expectedCode]
      let declarationA = completeStructural "A" (recordShape [TText])
          declarationB = completeStructural "B" (recordShape [TInt])
          onlyA = mappedSpec [declarationA]
          withB = mappedSpec [declarationA, declarationB]
      map ((.code) . kindOfChange) (diffSpecs onlyA withB) `shouldContain` [MappedDeclAdded]
      map ((.code) . kindOfChange) (diffSpecs withB onlyA) `shouldContain` [MappedDeclRemoved]
      diffSpecs base (mapArtifactNamedField "key" (wireFieldWithHaskell "renamedKey") base)
        `shouldSatisfy` \case
          [Advisory change] -> (.code) change == GeneratedHaskellNameChanged
          _ -> False
    it "visits every mapped wire mutation and reports every complete root path" $ do
      base <- specOf "test/fixtures/consumer-types.keiro"
      let mutations = mappedWireMutations base
      mutations `shouldSatisfy` (not . null)
      visited <- fmap Set.unions . forM mutations $ \mutation -> do
        let changes =
              [ change
              | change <- diffSpecs base ((.mmCandidate) mutation),
                (.code) (kindOfChange change) == (.mmCode) mutation
              ]
            actualSubjects = Set.fromList (map ((.subject) . kindOfChange) changes)
        changes `shouldSatisfy` any (not . isAdditiveChange)
        actualSubjects `shouldBe` (.mmExpectedSubjects) mutation
        pure actualSubjects
      visited `shouldBe` Set.unions (map (.mmExpectedSubjects) mutations)
    it "reports the exact ingredient code when every required mapped fact is deleted" $ do
      base <- specOf "test/fixtures/consumer-types.keiro"
      forM_ (mappedIngredientMutations base) $ \(candidate, expectedCode) ->
        errorCodes candidate `shouldContain` [expectedCode]
    it "classifies a field added without a version bump as BREAKING" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-fieldadd.keiro"
      any isBreaking cs `shouldBe` True
      [(.code) k | Breaking k <- cs] `shouldContain` [EvtFieldAddedWithoutBump]
    it "classifies the same field wrapped as v2 + upcaster as ADDITIVE" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-v2.keiro"
      any isBreaking cs `shouldBe` False
      [ck | Additive ck <- cs] `shouldSatisfy` any ((== "TransferReservationCreated") . (.subject))
    it "reports no breaking change when the spec is unchanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation.keiro"
      any isBreaking cs `shouldBe` False
    it "classifies a direct event field type change as EvtFieldTypeChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-fieldtype.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [EvtFieldTypeChanged]
    it "resolves fields(Command) before comparing event field types" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-cmdfieldtype.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [EvtFieldTypeChanged]
    it "uses EvtFieldRemovedSameVersion for an unchanged-version removal" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-fieldremove.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [EvtFieldRemovedSameVersion]
    it "classifies selector aliases as build-only and wire aliases as replay-affecting" $ do
      let sourceFor field =
            T.unlines
              [ "language keiro-dsl 4",
                "context field-alias-diff",
                "aggregate AliasDiff",
                "  regs",
                "  states Open",
                "  command Observe { " <> field <> " }",
                "  event Observed = fields(Observe)",
                "  wire kind=ctorName fields=camelCase schemaVersion=1"
              ]
      base <- checkedServiceFromText "field-alias-diff-base.keiro" (sourceFor "region:Text")
      selectorAlias <- checkedServiceFromText "field-alias-diff-selector.keiro" (sourceFor "region haskell serviceRegion:Text")
      wireAlias <- checkedServiceFromText "field-alias-diff-wire.keiro" (sourceFor "region as \"region_code\":Text")
      let selectorChanges = diffServices base selectorAlias
          wireChanges = diffServices base wireAlias
          selectorFindings = [finding | Advisory finding <- selectorChanges, (.code) finding == GeneratedHaskellNameChanged]
          wireFindings = [finding | Breaking finding <- wireChanges, (.code) finding == EvtFieldWireKeyChanged]
      selectorChanges `shouldSatisfy` all (not . isBreaking)
      map (.facet) selectorFindings `shouldContain` ["command-field-selector", "event-field-selector"]
      map (verdictFor ConsumerBuild . (.vector)) selectorFindings `shouldSatisfy` all (== VAdvisory)
      resolvedFold (ReplayImpact.replayImpactServices base selectorAlias) `shouldBe` ReplayNeutral
      case wireFindings of
        [finding] -> do
          (.subject) finding `shouldBe` "Observed.region"
          verdictFor PrivateHistoryRead (finding.vector) `shouldBe` VBreaking
          verdictFor OldBinaryReadNewEvents (finding.vector) `shouldBe` VBreaking
          (.detail) finding `shouldSatisfy` T.isInfixOf "'region' -> 'region_code'"
        findings -> expectationFailure ("expected one event wire-key finding, got " <> show findings)
      resolvedFold (ReplayImpact.replayImpactServices base wireAlias)
        `shouldSatisfy` \case
          ReplayAffected impacts ->
            maybe False ((== Set.singleton "Observed") . (.eventTypes)) (Map.lookup "AliasDiff" impacts)
          ReplayNeutral -> False
    it "retains event selector advisories across a legal version bump" $ do
      let sourceFor eventDeclaration =
            T.unlines
              [ "language keiro-dsl 4",
                "context field-alias-version-diff",
                "aggregate AliasVersionDiff",
                "  regs",
                "  states Open",
                "  command Observe {}",
                eventDeclaration
              ]
      base <- checkedServiceFromText "field-alias-version-base.keiro" (sourceFor "  event Observed { region:Text }")
      bumped <-
        checkedServiceFromText
          "field-alias-version-bumped.keiro"
          (sourceFor "  event Observed v2 { region haskell serviceRegion:Text }\n    upcast from v1 = HOLE")
      let changes = diffServices base bumped
          selectorFindings = [finding | Advisory finding <- changes, (.code) finding == GeneratedHaskellNameChanged]
      [(.code) finding | Additive finding <- changes] `shouldContain` [VersionBumped]
      map (.facet) selectorFindings `shouldBe` ["event-field-selector"]
      map (verdictFor ConsumerBuild . (.vector)) selectorFindings `shouldBe` [VAdvisory]
    it "classifies contract selector aliases separately from public wire changes" $ do
      let sourceFor field =
            T.unlines
              [ "language keiro-dsl 4",
                "context contract-field-alias-diff",
                "contract emergency {",
                "  schemaVersion 1",
                "  discriminator messageType",
                "  topic events \"emergency.events\"",
                "  event IncidentDeclared on events {",
                "    " <> field,
                "  }",
                "}"
              ]
      base <- checkedServiceFromText "contract-field-alias-base.keiro" (sourceFor "region: text")
      selectorAlias <- checkedServiceFromText "contract-field-alias-selector.keiro" (sourceFor "region haskell serviceRegion: text")
      wireAlias <- checkedServiceFromText "contract-field-alias-wire.keiro" (sourceFor "region as \"region_code\": text")
      let selectorChanges = diffServices base selectorAlias
          wireChanges = diffServices base wireAlias
      selectorChanges `shouldSatisfy` \case
        [Advisory finding] ->
          (.code) finding == GeneratedHaskellNameChanged
            && (.facet) finding == "contract-field-selector"
            && verdictFor ConsumerBuild (finding.vector) == VAdvisory
        _ -> False
      case [finding | Breaking finding <- wireChanges, (.code) finding == ContractFieldChanged] of
        [finding] -> do
          verdictFor PublicConsumer (finding.vector) `shouldBe` VBreaking
          (.rollout) (finding.vector) `shouldBe` Set.singleton RolloutProducerLast
          (.detail) finding `shouldSatisfy` T.isInfixOf "consumer-first rollout"
        findings -> expectationFailure ("expected one contract wire-key finding, got " <> show findings)
    it "keeps an alias-free field rename on the existing add/remove path" $ do
      let sourceFor field =
            T.unlines
              [ "language keiro-dsl 4",
                "context field-rename-diff",
                "aggregate RenameDiff",
                "  regs",
                "  states Open",
                "  event Renamed { " <> field <> ":Text }",
                "  wire kind=ctorName fields=camelCase schemaVersion=1"
              ]
      old <- checkedServiceFromText "field-rename-old.keiro" (sourceFor "region")
      new <- checkedServiceFromText "field-rename-new.keiro" (sourceFor "zone")
      let changes = diffServices old new
      [(.code) finding | Breaking finding <- changes]
        `shouldContain` [EvtFieldAddedWithoutBump, EvtFieldRemovedSameVersion]
      [finding | Advisory finding <- changes, (.code) finding == GeneratedHaskellNameChanged]
        `shouldBe` []
    it "uses EvtVersionDecreased for a version decrease" $ do
      cs <- diffFixtures "test/fixtures/reservation-v2.keiro" "test/fixtures/reservation.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [EvtVersionDecreased]
    it "rejects a v1 to v3 jump whose only upcaster starts at v2" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-v3-dangling.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [EvtVersionMissingUpcaster]
    it "classifies a vanished historical upcaster rung as UpcasterChainGap" $ do
      cs <- diffFixtures "test/fixtures/reservation-v2.keiro" "test/fixtures/reservation-chain-gap.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [UpcasterChainGap]
    it "classifies an enum constructor removal as EnumCtorRemoved" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-enumdrop.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [EnumCtorRemoved]
    it "classifies an enum wire-spelling change as EnumWireSpellingChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-enumwire.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [EnumWireSpellingChanged]
    it "classifies an enum constructor addition per use site as advisory" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-enumadd.keiro"
      any isBreaking cs `shouldBe` False
      let enumFindings = [k | Advisory k <- cs, (.code) k == EnumCtorAdded]
      [(.subject) k | k <- enumFindings] `shouldContain` ["BlackTag"]
      [verdictFor SnapshotHydration (k.vector) | k <- enumFindings]
        `shouldContain` [VAdvisory]
    it "classifies an effective wire convention change as WireSpecChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-wire.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [WireSpecChanged]
    it "advises when the aggregate fold surface changes" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-foldchange.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldContain` [AggFoldSurfaceChanged]
    it "advises on hazardous deprecation and reports un-deprecation" $ do
      deprecated <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-deprecated.keiro"
      any isBreaking deprecated `shouldBe` False
      [(.code) k | Advisory k <- deprecated] `shouldContain` [DeprecatedEventReplayHazard]
      restored <- diffFixtures "test/fixtures/reservation-deprecated.keiro" "test/fixtures/reservation.keiro"
      any isAdvisory restored `shouldBe` True
      [(.code) k | Advisory k <- restored] `shouldContain` [EventUndeprecated]
    it "recognises replay-only deprecation as a replay-safe retirement cutover" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-deprecated-replay-only.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldContain` [EventRetirementInProgress]
      [(.code) k | Advisory k <- cs] `shouldNotContain` [DeprecatedEventReplayHazard]
    it "advises when event retirement starts" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-retiring.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldContain` [EventRetirementInProgress]
    it "does not recommend decode-only deprecation for an event removal" $ do
      old <- specOf "test/fixtures/reservation.keiro"
      let new =
            specWithNodes
              [ case node of
                  NAggregate aggregate ->
                    NAggregate
                      aggregate
                        { events =
                            [ event
                            | event <- (.events) aggregate,
                              (.name) event /= "TransferReservationConfirmed"
                            ],
                          transitions =
                            [ transition {emits = filter (/= "TransferReservationConfirmed") ((.emits) transition)}
                            | transition <- (.transitions) aggregate
                            ]
                        }
                  _ -> node
              | node <- old.nodes
              ]
              old
          removals = [change | change@(Breaking kind) <- diffSpecs old new, (.code) kind == EvtRemovedNotDeprecated]
      removals `shouldSatisfy` (not . null)
      [(.detail) kind | Breaking kind <- removals]
        `shouldSatisfy` all (not . T.isInfixOf "so old payloads still decode")
    it "prints a paste-ready replay-only twin when a guard tightens (plan 143)" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-guard-tightened.keiro"
      any isBreaking cs `shouldBe` False
      let advisories = [k | Advisory k <- cs, (.code) k == AggGuardTightened]
      map (.subject) advisories `shouldBe` ["Unrequested -- RequestTransferReservation"]
      advisoryDetail <- case advisories of
        [k] -> pure ((.detail) k)
        other -> expectationFailure ("expected one advisory, got " <> show other) >> pure ""
      advisoryDetail `shouldSatisfy` T.isInfixOf "replay-only Unrequested -- RequestTransferReservation"
      -- The printed twin is paste-ready: appended to the new spec it
      -- parses, validates without errors, and silences the advisory.
      tightened <- readTestText "test/fixtures/reservation-guard-tightened.keiro"
      let twinText = snd (T.breakOnEnd "\n\n" advisoryDetail)
          pasted = tightened <> "\n" <> twinText <> "\n"
      case parseSpec "<pasted-twin>" pasted of
        Left err -> expectationFailure (T.unpack err)
        Right pastedSpec -> do
          [(.code) d | d <- validateSpec pastedSpec, (.severity) d == Error] `shouldBe` []
          base <- specOf "test/fixtures/reservation.keiro"
          [k | Advisory k <- diffSpecs base pastedSpec, (.code) k == AggGuardTightened]
            `shouldBe` []
    it "omits the twin advisory when the twin is already present (plan 143)" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-guard-tightened-twin.keiro"
      [k | Advisory k <- cs, (.code) k == AggGuardTightened] `shouldBe` []
    it "classifies a removed contract event as ContractEventRemoved" $ do
      cs <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-eventdrop.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [ContractEventRemoved]
    it "classifies contract field type changes and unversioned additions as ContractFieldChanged" $ do
      changed <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-fieldtype.keiro"
      [(.code) k | Breaking k <- changed] `shouldContain` [ContractFieldChanged]
      added <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-fieldadd.keiro"
      [(.code) k | Breaking k <- added] `shouldContain` [ContractFieldChanged]
    it "goldens language-3 to language-4 contract TypeID admission and rollout" $ do
      let source versionNumber prefix =
            T.unlines
              [ "language keiro-dsl " <> T.pack (show versionNumber),
                "context hospital-capacity",
                "contract emergency {",
                "  schemaVersion 1",
                "  discriminator messageType",
                "  topic incidentEvents \"emergency.incident.events\"",
                "  event IncidentTransferNeedDeclared on incidentEvents {",
                "    incidentId: typeid \"" <> prefix <> "\"",
                "  }",
                "}"
              ]
          checked name input = case parseSource name input of
            Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
            Right parsed -> pure (checkedSource parsed)
      v1 <- checked "contract-typeid-v1.keiro" (source (1 :: Int) "inc")
      v3 <- checked "contract-typeid-v3.keiro" (source (3 :: Int) "inc")
      v4 <- checked "contract-typeid-v4.keiro" (source (4 :: Int) "inc")
      v4Edited <- checked "contract-typeid-v4-edited.keiro" (source (4 :: Int) "rsv")
      let changes = diffServices v3 v4
          textGolden = T.intercalate "\n" (map renderFinding changes)
          jsonGolden = LazyText.toStrict (LazyTextEncoding.decodeUtf8 (Aeson.encode (diffReport defaultGate changes)))
          findings = [kind | Breaking kind <- changes, (.code) kind == ContractTypeIdDomainChanged]
      assertMatchesGolden "test/fixtures/contract-typeid-domain.diff.golden" textGolden
      assertMatchesGolden "test/fixtures/contract-typeid-domain.diff.json.golden" jsonGolden
      case findings of
        [finding] -> do
          verdictFor PublicConsumer (finding.vector) `shouldBe` VBreaking
          verdictFor ConsumerBuild (finding.vector) `shouldBe` VBreaking
          [verdictFor surface (finding.vector) | surface <- [PrivateHistoryRead, OldBinaryReadNewEvents, SnapshotHydration, PersistedIdentity]]
            `shouldBe` replicate 4 VNotApplicable
          (.rollout) (finding.vector) `shouldBe` Set.fromList [RolloutDrainRequired, RolloutProducerFirst]
          deriveLabel (Set.singleton PublicConsumer) (finding.vector) `shouldBe` LabelBreaking
          deriveLabel (Set.singleton ConsumerBuild) (finding.vector) `shouldBe` LabelBreaking
          remediationFor (finding.context) ((.code) finding)
            `shouldBe` RemedyEmitContractTypeIdDomain :| [RemedyDrainLegacyInvalidContractMessages, RemedyRescaffoldContractConsumers, RemedyRunContractConformance]
        values -> expectationFailure ("expected one contract TypeID-domain finding, got " <> show (length values))
      [kind | change <- diffServices v1 v3, let { kind = kindOfChange change }, (.code) kind == ContractTypeIdDomainChanged] `shouldBe` []
      [kind | change <- diffServices v4 v4, let { kind = kindOfChange change }, (.code) kind == ContractTypeIdDomainChanged] `shouldBe` []
      let edited = diffServices v3 v4Edited
      map ((.code) . kindOfChange) edited `shouldContain` [ContractFieldChanged]
      [kind | change <- edited, let { kind = kindOfChange change }, (.code) kind == ContractTypeIdDomainChanged] `shouldBe` []
    it "reports a field addition with a contract version bump as an advisory" $ do
      cs <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-bump-fieldadd.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldContain` [ContractSchemaVersionBumped]
    it "classifies a contract schema version decrease separately" $ do
      cs <- diffFixtures "test/fixtures/contract-bump-fieldadd.keiro" "test/fixtures/contract.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [ContractSchemaVersionDecreased]
    it "classifies contract topic and discriminator changes separately" $ do
      topic <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-topic.keiro"
      [(.code) k | Breaking k <- topic] `shouldContain` [ContractTopicChanged]
      discriminatorChanges <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-discriminator.keiro"
      [(.code) k | Breaking k <- discriminatorChanges] `shouldContain` [ContractDiscriminatorChanged]
    it "classifies a new contract event as additive" $ do
      cs <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-eventadd.keiro"
      any isBreaking cs `shouldBe` False
      [(.subject) k | Additive k <- cs] `shouldContain` ["IncidentTransferNeedCancelled"]
    it "classifies workqueue wire names, types, and required additions as WqPayloadFieldChanged" $ do
      wire <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-wirename.keiro"
      [(.code) k | Breaking k <- wire] `shouldContain` [WqPayloadFieldChanged]
      fieldTypeChange <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-fieldtype.keiro"
      [(.code) k | Breaking k <- fieldTypeChange] `shouldContain` [WqPayloadFieldChanged]
      required <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-reqfield.keiro"
      [(.code) k | Breaking k <- required] `shouldContain` [WqPayloadFieldChanged]
    -- Adding a payload field is breaking however it is spelled. Generated
    -- decoders read every field with `o .:`, so a job already queued under the
    -- old shape fails to decode against the new one — the "additive, optional
    -- field" classification this test previously asserted described a decoder
    -- that was never generated. See ExecPlan 199.
    it "classifies any new workqueue payload field as breaking for queued jobs" $ do
      cs <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-optfield.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [WqPayloadFieldChanged]
      [(.subject) k | Breaking k <- cs] `shouldContain` ["note"]
      [(.detail) k | Breaking k <- cs, (.subject) k == "note"]
        `shouldSatisfy` any (T.isInfixOf "queued jobs do not contain it")
    it "classifies workqueue ordering changes as breaking delivery-contract changes" $ do
      cs <- diffFixtures "test/fixtures/workqueue-policy-base.keiro" "test/fixtures/workqueue-ordering-change.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [WqOrderingChanged]
      [(.detail) k | Breaking k <- cs, (.code) k == WqOrderingChanged]
        `shouldSatisfy` any (T.isInfixOf "delivery-order contract")
    it "classifies workqueue provision changes as operational migrations" $ do
      cs <- diffFixtures "test/fixtures/workqueue-policy-base.keiro" "test/fixtures/workqueue-provision-change.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [WqProvisionChanged]
      [(.detail) k | Breaking k <- cs, (.code) k == WqProvisionChanged]
        `shouldSatisfy` any (T.isInfixOf "migrate the existing queue operationally")
    it "classifies workqueue group-key changes as breaking repartitioning" $ do
      cs <- diffFixtures "test/fixtures/workqueue-policy-base.keiro" "test/fixtures/workqueue-group-key-change.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [WqGroupKeyChanged]
      [(.detail) k | Breaking k <- cs, (.code) k == WqGroupKeyChanged]
        `shouldSatisfy` any (T.isInfixOf "re-partitioned")
    it "classifies a process input type change as ProcessInputChanged" $ do
      cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-inputtype.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [ProcessInputChanged]
    it "classifies workflow input and output changes as WorkflowShapeChanged" $ do
      input <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-inputfield.keiro"
      [(.code) k | Breaking k <- input] `shouldContain` [WorkflowShapeChanged]
      output <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-output.keiro"
      [(.code) k | Breaking k <- output] `shouldContain` [WorkflowShapeChanged]
    it "classifies workflow relabeling and appends as WorkflowBodyChanged" $ do
      relabeled <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-body.keiro"
      [(.code) k | Breaking k <- relabeled] `shouldContain` [WorkflowBodyChanged]
      appended <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-stepadd.keiro"
      [(.code) k | Breaking k <- appended] `shouldContain` [WorkflowBodyChanged]
      [(.detail) k | Breaking k <- appended, (.code) k == WorkflowBodyChanged]
        `shouldSatisfy` any (T.isInfixOf "new patch guard")
    it "classifies a body addition wholly guarded by a new patch as additive" $ do
      cs <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-evolution-diff.keiro"
      any isBreaking cs `shouldBe` False
      [(.subject) k | Additive k <- cs, (.facet) k == "workflow-patch"] `shouldContain` ["fraud-check-v2"]
      [(.subject) k | Additive k <- cs, (.facet) k == "workflow-continue-as-new"] `shouldContain` ["RolloverSeed"]
    it "classifies removing an existing patch as breaking" $ do
      cs <- diffFixtures "test/fixtures/workflow-evolution-diff.keiro" "test/fixtures/workflow-continue.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [WorkflowPatchRemoved]
      [(.detail) k | Breaking k <- cs, (.code) k == WorkflowPatchRemoved]
        `shouldSatisfy` any (T.isInfixOf "cannot prove")
    it "classifies terminal continueAsNew append as additive and seed drift as breaking" $ do
      appended <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-continue.keiro"
      any isBreaking appended `shouldBe` False
      [(.facet) k | Additive k <- appended] `shouldContain` ["workflow-continue-as-new"]
      changed <- diffFixtures "test/fixtures/workflow-continue.keiro" "test/fixtures/workflow-continue-seed-v2.keiro"
      [(.code) k | Breaking k <- changed] `shouldContain` [WorkflowContinueSeedChanged]
      [(.detail) k | Breaking k <- changed, (.code) k == WorkflowContinueSeedChanged]
        `shouldSatisfy` any (T.isInfixOf "restoreSeed")
    it "classifies a workflow stable-name change as WorkflowStableNameChanged" $ do
      cs <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-rename.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [WorkflowStableNameChanged]
    it "classifies workflow id-derivation changes as DerivedIdentityChanged" $ do
      cs <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-idfield.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [DerivedIdentityChanged]
    it "classifies an id prefix change as IdPrefixChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-idprefix.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [IdPrefixChanged]
    it "classifies intake dedupe key and policy changes as DedupeIdentityChanged" $ do
      policy <- diffFixtures "test/fixtures/intake.keiro" "test/fixtures/intake-dedupepolicy.keiro"
      [(.code) k | Breaking k <- policy] `shouldContain` [DedupeIdentityChanged]
      key <- diffFixtures "test/fixtures/intake.keiro" "test/fixtures/intake-dedupekey.keiro"
      [(.code) k | Breaking k <- key] `shouldContain` [DedupeIdentityChanged]
    it "reports intake decode-posture changes as warnings" $ do
      cs <- diffFixtures "test/fixtures/intake.keiro" "test/fixtures/intake-decode.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldContain` [DecodePostureChanged]
      [(.code) k | Advisory k <- cs] `shouldContain` [IntakePersistenceChanged]
    it "classifies process and timer derivation changes as DerivedIdentityChanged" $ do
      processName <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-procname.keiro"
      [(.code) k | Breaking k <- processName] `shouldContain` [DerivedIdentityChanged]
      timerId <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-timerid.keiro"
      [(.code) k | Breaking k <- timerId] `shouldContain` [DerivedIdentityChanged]
      base <- specOf "test/fixtures/hospital-surge.keiro"
      let categoryChange = diffSpecs base (modifyProcess "HospitalSurge" (\process -> processWithSaga (sagaRefWithCategory "hospitalSurgeV2" process.saga) process) base)
      [(.code) k | Breaking k <- categoryChange] `shouldContain` [DerivedIdentityChanged]
    it "classifies router stable names, keys, and targets as identity-bearing" $ do
      base <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      let stableName = diffSpecs base (modifyRouter "PagingRouter" (routerWithName "paging-v2") base)
          keyDerivation = diffSpecs base (modifyRouter "PagingRouter" (\router -> routerWithKey (correlateDeclWithVia "otherIdText" router.key) router) base)
          target = diffSpecs base (modifyRouter "PagingRouter" (routerWithTarget "OtherPage") base)
      [(.code) k | Breaking k <- stableName] `shouldContain` [RouterStableNameChanged]
      [(.code) k | Breaking k <- keyDerivation] `shouldContain` [DerivedIdentityChanged]
      [(.code) k | Breaking k <- target] `shouldContain` [DerivedIdentityChanged]
    it "advises on router dispatch-surface changes without making them breaking" $ do
      cs <- diffFixtures "test/fixtures/incident-paging/incident-paging.keiro" "test/fixtures/incident-paging/incident-paging-dispatch.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldBe` [RouterDecideSurfaceChanged]
    it "advises on process dispatch-surface changes without making them breaking" $ do
      cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-handle.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldBe` [ProcessDecideSurfaceChanged]
    it "advises on unversioned timer payload changes without making them breaking" $ do
      cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-payload.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldBe` [ProcessTimerPayloadChanged]
    it "ignores formatting-only process and timer surface rewrites" $ do
      original <- specOf "test/fixtures/hospital-surge.keiro"
      formatted <- shouldParseStableRenderedSpec "<formatted-process>" original
      diffSpecs original formatted `shouldBe` []
    it "reports a timer window change as a warning" $ do
      cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-window.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldContain` [TimerWindowChanged]
    it "reports emit-map changes as warnings and derive changes as breaking" $ do
      mapping <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-mapchange.keiro"
      any isBreaking mapping `shouldBe` False
      [(.code) k | Advisory k <- mapping] `shouldContain` [EmitMappingChanged]
      derive <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-derive.keiro"
      [(.code) k | Breaking k <- derive] `shouldContain` [DerivedIdentityChanged]
    it "classifies publisher outbox identity and ordering independently" $ do
      outbox <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-outboxfield.keiro"
      [(.code) k | Breaking k <- outbox] `shouldContain` [DerivedIdentityChanged]
      ordering <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-ordering.keiro"
      any isBreaking ordering `shouldBe` False
      [(.code) k | Advisory k <- ordering] `shouldContain` [PublisherPolicyChanged]
    it "classifies workqueue names as QueueIdentityChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-rename.keiro"
      [(.code) k | Breaking k <- cs] `shouldContain` [QueueIdentityChanged]
    it "classifies pgmq dispatch dedupe and retargeting independently" $ do
      dedupe <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-dedupkey.keiro"
      [(.code) k | Breaking k <- dedupe] `shouldContain` [DedupeIdentityChanged]
      retarget <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-retarget.keiro"
      any isBreaking retarget `shouldBe` False
      [(.code) k | Advisory k <- retarget] `shouldContain` [DispatchRetargeted]
    it "reports aggregate projection changes as warnings" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-projection.keiro"
      any isBreaking cs `shouldBe` False
      [(.code) k | Advisory k <- cs] `shouldContain` [ProjectionChanged]
    it "classifies read-model version and unversioned shape changes" $ do
      base <- specOf "test/fixtures/readmodel-runtime.keiro"
      let versionTwo = modifyReadModel "transfer_decisions" (readModelWithVersion 2) base
          changedShape = modifyReadModel "transfer_decisions" changeReadModelShape base
          bumpedShape = modifyReadModel "transfer_decisions" (readModelWithVersion 2 . changeReadModelShape) base
          decreased = diffSpecs versionTwo base
          unversioned = diffSpecs base changedShape
          bumped = diffSpecs base bumpedShape
      [(.code) k | Breaking k <- decreased] `shouldContain` [ReadModelVersionDecreased]
      [(.code) k | Breaking k <- unversioned] `shouldContain` [ReadModelShapeChangedWithoutBump]
      any isBreaking bumped `shouldBe` False
      [(.facet) k | Additive k <- bumped] `shouldContain` ["read-model-version"]
    it "classifies query input and result changes only on the consumer-build surface" $ do
      source <- mappedConsumerSurfaceSource
      base <- parseInlineSpec "<mapped-query-diff-old>" source
      let changeQuery update =
            modifyReadModel
              "ArtifactLookup"
              ( \readModel ->
                  readModelWithQueryTypes (fmap update readModel.queryTypes) readModel
              )
              base
          inputChanged = changeQuery (\queryPair -> readModelQueryTypesWithInput (TList queryPair.input) queryPair)
          resultChanged = changeQuery (readModelQueryTypesWithResult (TRef "ArtifactInfo"))
          assertBuildOnly expectedCode changes = case [kind | Advisory kind <- changes, (.code) kind == expectedCode] of
            [kind] -> do
              (.consumerBuild) (kind.vector) `shouldBe` VBreaking
              (.privateHistoryRead) (kind.vector) `shouldBe` VCompatible
              (.oldBinaryReadNewEvents) (kind.vector) `shouldBe` VCompatible
              (.snapshotHydration) (kind.vector) `shouldBe` VNotApplicable
              (.publicConsumer) (kind.vector) `shouldBe` VNotApplicable
              (.persistedIdentity) (kind.vector) `shouldBe` VNotApplicable
              (.mappedPersistedImpact) kind `shouldBe` Nothing
              remediationFor (kind.context) ((.code) kind)
                `shouldBe` RemedyRecompileConsumers :| [RemedyRunConformance]
            values -> expectationFailure ("expected one query build finding, got " <> show values)
          onlyReadModel spec = case [readModel | NReadModel readModel <- (.nodes) spec, (.name) readModel == "ArtifactLookup"] of
            [readModel] -> readModel
            values -> error ("expected one ArtifactLookup read model, got " <> show values)
      assertBuildOnly ReadModelQueryInputChanged (diffSpecs base inputChanged)
      assertBuildOnly ReadModelQueryResultChanged (diffSpecs base resultChanged)
      canonicalShape (onlyReadModel inputChanged) `shouldBe` canonicalShape (onlyReadModel base)
      deriveShapeHash (onlyReadModel resultChanged) `shouldBe` deriveShapeHash (onlyReadModel base)
      projectionCatalogFacts inputChanged `shouldBe` projectionCatalogFacts base
      registryNameFor (inputChanged.context) (onlyReadModel inputChanged)
        `shouldBe` registryNameFor (base.context) (onlyReadModel base)
      replayImpactSpecs base inputChanged `shouldBe` ReplayNeutral
    it "classifies read-model registry, table, subscription, and removal identities" $ do
      base <- specOf "test/fixtures/readmodel-runtime.keiro"
      let tableChanged = modifyReadModel "transfer_decisions" (readModelWithTable "transfer_decisions_v2") base
          subscriptionChanged = modifyReadModel "transfer_decisions" (\readModel -> readModelWithSupply (setLegacySubscription (Just "transfer-decisions-v2") readModel.supply) readModel) base
          renamed = modifyReadModel "transfer_decisions" (readModelWithName "reservation_decisions") base
          removed = removeReadModel "transfer_decisions" base
      mapM_
        (\changes -> [(.code) k | Breaking k <- changes] `shouldContain` [DerivedIdentityChanged])
        [diffSpecs base tableChanged, diffSpecs base subscriptionChanged, diffSpecs base renamed, diffSpecs base removed]
    it "classifies read-model feed flips and consistency/scope weakening as breaking" $ do
      base <- specOf "test/fixtures/readmodel-runtime.keiro"
      let feedChanged = modifyReadModel "transfer_decisions" (\readModel -> readModel {supply = setLegacyFeed RmInline ((.supply) readModel)}) base
          consistencyWeakened = modifyReadModel "transfer_decisions" (\readModel -> readModel {supply = setLegacyConsistency Eventual ((.supply) readModel), freshness = FreshnessImmediate}) base
          entireLog = modifyReadModel "transfer_decisions" (\readModel -> readModel {supply = setLegacyScope (Just RmEntireLog) ((.supply) readModel), freshness = FreshnessWaitForHead RmEntireLog}) base
      [(.code) k | Breaking k <- diffSpecs base feedChanged] `shouldContain` [ReadModelFeedChanged]
      [(.code) k | Breaking k <- diffSpecs base consistencyWeakened] `shouldContain` [ReadModelConsistencyWeakened]
      [(.code) k | Breaking k <- diffSpecs entireLog base] `shouldContain` [ReadModelConsistencyWeakened]
    it "classifies Eventual to Strong read-model consistency as additive" $ do
      strong <- specOf "test/fixtures/readmodel-runtime.keiro"
      let eventual = modifyReadModel "transfer_decisions" (\readModel -> readModel {supply = setLegacyConsistency Eventual ((.supply) readModel), freshness = FreshnessImmediate}) strong
          changes = diffSpecs eventual strong
      any isBreaking changes `shouldBe` False
      [(.facet) k | Additive k <- changes] `shouldContain` ["read-model-consistency"]
    it "classifies the legacy Strong to language-5 immediate freshness migration as breaking" $ do
      source <- readTestText "test/fixtures/readmodel-migration-l4.keiro"
      let legacyStrongPolicy =
            "  consistency = Strong\n  scope = category \"reservation\"\n  feed = subscription\n  subscription = \"hospital-capacity-transfer-decisions-sub\"\n"
          toLanguage5 policy =
            T.replace "language keiro-dsl 4" "language keiro-dsl 5"
              . T.replace legacyStrongPolicy policy
      legacyStrong <- checkedServiceFromText "readmodel-migration-legacy-strong.keiro" source
      immediate <- checkedServiceFromText "readmodel-migration-immediate.keiro" (toLanguage5 "  freshness = immediate\n" source)
      let changes = diffServices legacyStrong immediate
      [(.code) k | Breaking k <- changes] `shouldContain` [QueryFreshnessChanged]
      [(.facet) k | Breaking k <- changes] `shouldContain` ["query-freshness"]
      [(.facet) k | Additive k <- changes] `shouldNotContain` ["read-model-scope"]
      [(.detail) k | Breaking k <- changes, (.code) k == QueryFreshnessChanged]
        `shouldSatisfy` any (T.isInfixOf "wait-for-head category 'reservation' -> immediate")
    it "keeps equivalent and strengthened freshness migrations non-breaking" $ do
      source <- readTestText "test/fixtures/readmodel-migration-l4.keiro"
      let legacyStrongPolicy =
            "  consistency = Strong\n  scope = category \"reservation\"\n  feed = subscription\n  subscription = \"hospital-capacity-transfer-decisions-sub\"\n"
          legacyEventualPolicy =
            "  consistency = Eventual\n  feed = subscription\n  subscription = \"hospital-capacity-transfer-decisions-sub\"\n"
          toLanguage5 policy =
            T.replace "language keiro-dsl 4" "language keiro-dsl 5"
              . T.replace legacyStrongPolicy policy
          readModelFacets = filter (\facet -> facet == "query-freshness" || "read-model-" `T.isPrefixOf` facet) . map ((.facet) . kindOfChange)
          assertEquivalent changes = do
            any isBreaking changes `shouldBe` False
            readModelFacets changes `shouldBe` []
      legacyStrong <- checkedServiceFromText "readmodel-migration-equivalent-legacy-strong.keiro" source
      strongEquivalent <- checkedServiceFromText "readmodel-migration-equivalent-wait.keiro" (toLanguage5 "  freshness = wait-for-head category \"reservation\"\n" source)
      assertEquivalent (diffServices legacyStrong strongEquivalent)
      let eventualSource = T.replace legacyStrongPolicy legacyEventualPolicy source
      legacyEventual <- checkedServiceFromText "readmodel-migration-equivalent-legacy-eventual.keiro" eventualSource
      immediate <- checkedServiceFromText "readmodel-migration-equivalent-immediate.keiro" (toLanguage5 "  freshness = immediate\n" source)
      assertEquivalent (diffServices legacyEventual immediate)
      strengthened <- checkedServiceFromText "readmodel-migration-strengthened.keiro" (toLanguage5 "  freshness = wait-for-head entire-log\n" source)
      let strengthenedChanges = diffServices legacyEventual strengthened
      any isBreaking strengthenedChanges `shouldBe` False
      [(.code) k | Additive k <- strengthenedChanges] `shouldContain` [CompatibilityStrengthened]
      [(.facet) k | Additive k <- strengthenedChanges] `shouldContain` ["query-freshness"]
    it "classifies scope changes and reverse downgrades in the freshness migration by the normalized pair" $ do
      source <- readTestText "test/fixtures/readmodel-migration-l4.keiro"
      let legacyStrongPolicy =
            "  consistency = Strong\n  scope = category \"reservation\"\n  feed = subscription\n  subscription = \"hospital-capacity-transfer-decisions-sub\"\n"
          legacyEventualPolicy =
            "  consistency = Eventual\n  feed = subscription\n  subscription = \"hospital-capacity-transfer-decisions-sub\"\n"
          toLanguage5 policy =
            T.replace "language keiro-dsl 4" "language keiro-dsl 5"
              . T.replace legacyStrongPolicy policy
      legacyStrong <- checkedServiceFromText "readmodel-migration-scope-legacy-strong.keiro" source
      widened <- checkedServiceFromText "readmodel-migration-scope-widened.keiro" (toLanguage5 "  freshness = wait-for-head entire-log\n" source)
      let widenedChanges = diffServices legacyStrong widened
      any isBreaking widenedChanges `shouldBe` False
      [(.code) k | Additive k <- widenedChanges] `shouldContain` [CompatibilityStrengthened]
      [(.facet) k | Additive k <- widenedChanges] `shouldContain` ["query-freshness"]
      categoryChanged <- checkedServiceFromText "readmodel-migration-scope-category-changed.keiro" (toLanguage5 "  freshness = wait-for-head category \"other\"\n" source)
      [(.code) k | Breaking k <- diffServices legacyStrong categoryChanged] `shouldContain` [QueryFreshnessChanged]
      immediate <- checkedServiceFromText "readmodel-migration-reverse-immediate.keiro" (toLanguage5 "  freshness = immediate\n" source)
      let reverseStrengthened = diffServices immediate legacyStrong
      any isBreaking reverseStrengthened `shouldBe` False
      [(.code) k | Additive k <- reverseStrengthened] `shouldContain` [CompatibilityStrengthened]
      legacyEventual <- checkedServiceFromText "readmodel-migration-reverse-legacy-eventual.keiro" (T.replace legacyStrongPolicy legacyEventualPolicy source)
      waitCategory <- checkedServiceFromText "readmodel-migration-reverse-wait.keiro" (toLanguage5 "  freshness = wait-for-head category \"reservation\"\n" source)
      [(.code) k | Breaking k <- diffServices waitCategory legacyEventual] `shouldContain` [QueryFreshnessChanged]
    it "keeps identical same-language freshness migration pairs free of policy findings" $ do
      source <- readTestText "test/fixtures/readmodel-migration-l4.keiro"
      let legacyStrongPolicy =
            "  consistency = Strong\n  scope = category \"reservation\"\n  feed = subscription\n  subscription = \"hospital-capacity-transfer-decisions-sub\"\n"
          language5Source =
            T.replace "language keiro-dsl 4" "language keiro-dsl 5"
              . T.replace legacyStrongPolicy "  freshness = immediate\n"
              $ source
          policyFacets = filter (\facet -> facet == "query-freshness" || "read-model-" `T.isPrefixOf` facet) . map ((.facet) . kindOfChange)
      language4 <- checkedServiceFromText "readmodel-migration-identical-language-4.keiro" source
      language5 <- checkedServiceFromText "readmodel-migration-identical-language-5.keiro" language5Source
      policyFacets (diffServices language4 language4) `shouldBe` []
      policyFacets (diffServices language5 language5) `shouldBe` []

  describe "module placement (M1)" $ do
    it "GeneratedPrefix is today's namespace (Generated.<Ctx>.<Node>, holes at <Ctx>.<Node>)" $ do
      let ctx = defaultContext "hospital-capacity"
      genPrefixFor ctx "Reservation" `shouldBe` "Generated.HospitalCapacity.Reservation"
      holePrefixFor ctx "Reservation" `shouldBe` "HospitalCapacity.Reservation"
    it "module-root prefixes both layers" $ do
      let ctx = contextWithModuleRoot "Acme" (defaultContext "hospital-capacity")
      genPrefixFor ctx "Reservation" `shouldBe` "Acme.Generated.HospitalCapacity.Reservation"
      holePrefixFor ctx "Reservation" `shouldBe` "Acme.HospitalCapacity.Reservation"
    it "CollocatedLeaf places the generated layer under the domain leaf" $ do
      let ctx = (defaultContext "hospital-capacity") {moduleRoot = "Acme", placement = CollocatedLeaf}
      genPrefixFor ctx "Reservation" `shouldBe` "Acme.HospitalCapacity.Reservation.Generated"
      holePrefixFor ctx "Reservation" `shouldBe` "Acme.HospitalCapacity.Reservation"
    it "parses and preserves the module/layout clauses through parse . pretty" $ do
      let src = "context hospital-capacity\nmodule Acme.Services\nlayout collocated\n\naggregate Reservation\n  regs\n  states Open\n"
      case parseSpec "<m1>" src of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> do
          (.moduleRoot) spec `shouldBe` Just "Acme.Services"
          (.layout) spec `shouldBe` Just CollocatedLeaf
          parseSpec "<m1>" (renderSpec spec) `shouldBe` Right spec
    it "a spec without the clauses leaves placement at the default" $ do
      input <- readTestText "test/fixtures/reservation.keiro"
      case parseSpec "test/fixtures/reservation.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> do
          (.moduleRoot) spec `shouldBe` Nothing
          (.layout) spec `shouldBe` Nothing

  describe "structural scaffold" $ do
    it "emits one private shape module per structural declaration and one context facade" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let modules = scaffoldModules (defaultContext (spec.context)) spec
          paths = map (.path) modules
      paths
        `shouldContain` [ "Generated/ConsumerDemo/Structural/Shape/ArtifactInfo.hs",
                          "Generated/ConsumerDemo/Structural/Shape/ArtifactKind.hs",
                          "Generated/ConsumerDemo/Structural/Shape/ArtifactLocation.hs",
                          "Generated/ConsumerDemo/StructuralProjections.hs"
                        ]
      paths `shouldNotContain` ["Generated/ConsumerDemo/Structural/Shape/VendorGeometry.hs"]
      firewallBreaches modules `shouldBe` []
    it "emits one create-once binding skeleton per owning module and derives Generic for private shapes" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let modules = scaffoldModules (defaultContext (spec.context)) spec
          skeletons = [moduleValue | moduleValue <- modules, (.kind) moduleValue == HoleStub, (.path) moduleValue == "Example/Artifact/KeiroBindings.hs"]
          shape = generatedTextEndingIn "Structural/Shape/ArtifactInfo.hs" modules
      case skeletons of
        [skeleton] -> do
          (.text) skeleton `shouldSatisfy` T.isInfixOf "artifactInfoBinding :: StructuralBinding"
          (.text) skeleton `shouldSatisfy` T.isInfixOf "artifactKindBinding :: StructuralBinding"
          (.text) skeleton `shouldSatisfy` T.isInfixOf "artifactLocationBinding :: StructuralBinding"
          (.text) skeleton `shouldSatisfy` T.isInfixOf "HOLE: fill ArtifactInfo bindingToShape.key"
        _ -> expectationFailure ("expected exactly one shared binding skeleton, got " <> show (map (.path) skeletons))
      shape `shouldSatisfy` T.isInfixOf "deriving stock (Eq, Generic, Show)"
      shape `shouldSatisfy` T.isInfixOf "import GHC.Generics (Generic)"
    it "never overwrites an existing binding skeleton" $
      withTempDirectory "keiro-dsl-binding-create-once" $ \out -> do
        spec <- specOf "test/fixtures/consumer-types.keiro"
        let ctx = defaultContext (spec.context)
            bindingPath = out </> "Example/Artifact/KeiroBindings.hs"
        _ <- executePlannedScaffold out "consumer-types.keiro" ctx spec
        TIO.writeFile bindingPath "hand-owned binding\n"
        second <- executePlannedScaffold out "consumer-types.keiro" ctx spec
        TIO.readFile bindingPath `shouldReturn` "hand-owned binding\n"
        (.dispositions) second
          `shouldSatisfy` any (\(moduleValue, disposition) -> (.path) moduleValue == "Example/Artifact/KeiroBindings.hs" && disposition == Skipped)
    it "fresh binding skeletons compile at the application boundary" $
      withTempDirectory "keiro-dsl-binding-compiles" $ \out -> do
        spec <- specOf "test/fixtures/structural-conformance.keiro"
        let ctx = defaultContext (spec.context)
            bindingSource = out </> "Conformance/Structural/Bindings.hs"
            ghcOutput = out </> ".ghc"
        _ <- executePlannedScaffold out "structural-conformance.keiro" ctx spec
        createDirectoryIfMissing True ghcOutput
        (exitCode, standardOutput, standardError) <-
          readProcessWithExitCode
            "cabal"
            [ "exec",
              "--",
              "ghc",
              "-XGHC2024",
              "-XOverloadedStrings",
              "-fno-code",
              "-fforce-recomp",
              "-outputdir",
              ghcOutput,
              "-i" <> out,
              "-itest/conformance-structural",
              "-i../keiro-core/src",
              bindingSource
            ]
            ""
        unless (exitCode == ExitSuccess) $
          expectationFailure (standardOutput <> standardError)
    it "keeps consumer types in Domain while the generated Codec owns keys, tags, and defaults" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let modules = scaffoldModules (defaultContext (spec.context)) spec
          domain = generatedTextEndingIn "Catalog/Domain.hs" modules
          codec = generatedTextEndingIn "Catalog/Codec.hs" modules
      domain `shouldSatisfy` T.isInfixOf "import Example.Artifact.Domain (ArtifactInfo)"
      domain `shouldSatisfy` T.isInfixOf "import Vendor.Geometry (Geometry)"
      domain `shouldSatisfy` T.isInfixOf "artifact :: !ArtifactInfo"
      domain `shouldSatisfy` T.isInfixOf "RCons (Proxy @\"currentArtifact\") ArtifactKeiroBindings.emptyArtifactInfo"
      domain `shouldSatisfy` (not . T.isInfixOf "Example.Artifact.Domain.ArtifactInfo")
      codec `shouldSatisfy` T.isInfixOf "\"location\" .= encodeArtifactLocationShape"
      codec `shouldSatisfy` T.isInfixOf "\"local_file\""
      codec `shouldSatisfy` T.isInfixOf "parseOptionalField (pure ShapeArtifactKind.Guide)"
      codec `shouldSatisfy` T.isInfixOf "rejectUnknownFields \"ArtifactInfo\""
      codec `shouldSatisfy` T.isInfixOf "toJSON payload.geometry"
      codec `shouldSatisfy` (not . T.isInfixOf "vendor.geometry.json")
    it "generates shape-only nested types and schema-derived Keiki witnesses" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let modules = scaffoldModules (defaultContext (spec.context)) spec
          shape = generatedTextEndingIn "Structural/Shape/ArtifactInfo.hs" modules
          facade = generatedTextEndingIn "StructuralProjections.hs" modules
      shape `shouldSatisfy` T.isInfixOf "data ArtifactInfoShape = ArtifactInfo"
      shape `shouldSatisfy` T.isInfixOf "ArtifactKind.ArtifactKindShape"
      mapM_
        (shape `shouldSatisfy`)
        [ T.isInfixOf "description :: !(Maybe Text)",
          T.isInfixOf "tags :: ![Text]",
          T.isInfixOf "labels :: ![Maybe Text]",
          T.isInfixOf "attributes :: !(Map Text Text)"
        ]
      mapM_
        (shape `shouldNotSatisfy`)
        [ T.isInfixOf "description :: !(Maybe (Text))",
          T.isInfixOf "tags :: !([Text])",
          T.isInfixOf "labels :: !([(Maybe (Text))])",
          T.isInfixOf "attributes :: !(Map Text (Text))"
        ]
      shape `shouldSatisfy` (not . T.isInfixOf "KeiroBindings")
      facade `shouldSatisfy` T.isInfixOf "type FieldName"
      facade `shouldSatisfy` T.isInfixOf "= \"/key\""
      facade `shouldSatisfy` T.isInfixOf "fieldShapeId _ = \"example.artifact.ArtifactInfo.v1\""
      facade `shouldSatisfy` T.isInfixOf "type FieldOwner ArtifactInfoKeyProjection = ArtifactInfo"
      facade `shouldSatisfy` T.isInfixOf "bindingToShape KeiroBindings.artifactInfoBinding owner"
      facade `shouldSatisfy` (not . T.isInfixOf "Example.Artifact.Domain.ArtifactInfo")
      facade `shouldSatisfy` T.isInfixOf "artifactInfoKeyWitness"
      facade `shouldNotSatisfy` T.isInfixOf "structuralProjectionC"
    it "suffixes only structural witness names that collide after normalization" $ do
      source <- readTestText "test/fixtures/consumer-types.keiro"
      collisionSpec <-
        parseInlineSpec
          "<projection-name-collision>"
          ( T.replace
              "    key         as \"key\"         : Text                 required"
              ( T.unlines
                  [ "    key         as \"key\"         : Text                 required",
                    "    fooDash     as \"foo-bar\"     : Text                 required",
                    "    fooUnder    as \"foo_bar\"     : Text                 required"
                  ]
              )
              source
          )
      graph <- shouldResolveTypeGraph collisionSpec
      let specs = projectionSpecs graph
          keyWitnesses = [spec.witness | spec <- specs, (.pointer) spec == "/key"]
          collidedWitnesses = [spec.witness | spec <- specs, (.pointer) spec `elem` ["/foo-bar", "/foo_bar"]]
      keyWitnesses `shouldBe` ["artifactInfoKeyWitness"]
      length collidedWitnesses `shouldBe` 2
      Set.size (Set.fromList collidedWitnesses) `shouldBe` 2
      collidedWitnesses `shouldSatisfy` all (T.isPrefixOf "artifactInfoFooBar")
      collidedWitnesses `shouldSatisfy` all (T.isSuffixOf "Witness")
      collidedWitnesses `shouldSatisfy` all ((== 8) . T.length . T.dropEnd (T.length ("Witness" :: T.Text)) . T.drop (T.length ("artifactInfoFooBar" :: T.Text)))
    it "uses only precedence-required parentheses in nested record field types" $ do
      let spec =
            mappedSpec
              [ completeStructural
                  "Nested"
                  ( recordShape
                      [ TMap (TOptional TText),
                        TOptional (TList TText),
                        TOptional (TMap TText)
                      ]
                  )
              ]
          shape = generatedTextEndingIn "Structural/Shape/Nested.hs" (scaffoldStructural (defaultContext (spec.context)) spec)
      mapM_
        (shape `shouldSatisfy`)
        [ T.isInfixOf "field1 :: !(Map Text (Maybe Text))",
          T.isInfixOf "field2 :: !(Maybe [Text])",
          T.isInfixOf "field3 :: !(Maybe (Map Text Text))"
        ]
    it "uses the same precedence rules for strict union payloads" $ do
      let spec =
            mappedSpec
              [ completeStructural
                  "Payload"
                  ( ShapeUnion
                      (TaggedObject "tag" "contents" RejectUnknown)
                      [ WireArm "OptionalPayload" "optional" (Just (TOptional TText)) noLoc,
                        WireArm "ListPayload" "list" (Just (TList (TOptional TText))) noLoc,
                        WireArm "MapPayload" "map" (Just (TMap (TOptional TText))) noLoc
                      ]
                  )
              ]
          shape = generatedTextEndingIn "Structural/Shape/Payload.hs" (scaffoldStructural (defaultContext (spec.context)) spec)
      mapM_
        (shape `shouldSatisfy`)
        [ T.isInfixOf "OptionalPayload !(Maybe Text)",
          T.isInfixOf "ListPayload ![Maybe Text]",
          T.isInfixOf "MapPayload !(Map Text (Maybe Text))"
        ]

  describe "structural manifest" $ do
    it "lists consumer packages and every domain, binding, fixture, and initial module" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let modules = scaffoldModules (defaultContext (spec.context)) spec
          manifest = renderManifest "consumer-types.keiro" modules spec
      assertGeneratedHaskellContract "consumer-types.keiro" manifest
      mapM_ (\packageName -> manifestDependencies spec `shouldContain` [packageName]) ["artifact-domain", "vendor-geometry"]
      manifest `shouldSatisfy` T.isInfixOf "consumer-packages:\n    artifact-domain\n    vendor-geometry"
      mapM_
        (\moduleName -> manifest `shouldSatisfy` T.isInfixOf moduleName)
        [ "Example.Artifact.Domain",
          "Example.Artifact.KeiroBindings",
          "Vendor.Geometry",
          "Vendor.Geometry.KeiroBindings"
        ]

  describe "structural scaffold record" $ do
    it "round-trips canonical mapping rows and reports binding drift on the next run" $
      withTempDirectory "keiro-dsl-mapping-record" $ \out -> do
        spec <- specOf "test/fixtures/consumer-types.keiro"
        let ctx = defaultContext (spec.context)
        first <- executePlannedScaffold out "consumer-types.keiro" ctx spec
        length first.consumerPlan.mappings `shouldBe` 4
        recordText <- TIO.readFile (out </> recordFileName (spec.context))
        let mappingRows = filter (T.isPrefixOf "mapping ") (T.lines recordText)
            bindingRows = filter (T.isPrefixOf "binding ") (T.lines recordText)
        length mappingRows `shouldBe` 4
        bindingRows `shouldSatisfy` (not . null)
        fmap (.mappings) (parseRecord recordText) `shouldSatisfy` maybe False ((== 4) . length)
        fmap (.bindingObligations) (parseRecord recordText) `shouldSatisfy` maybe False ((== length bindingRows) . length)
        let bumped = spec {mapped = map bumpArtifactBindingVersion ((.mapped) spec)}
        second <- executePlannedScaffold out "consumer-types.keiro" ctx bumped
        (.mappingDrift) second
          `shouldSatisfy` any (\drift -> (.specName) drift == "ArtifactInfo" && (.previous) drift /= (.current) drift)
        renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "mapping drift:")
        case mappingRows of
          row : _ -> parseRecord (recordText <> row <> "\n") `shouldBe` Nothing
          [] -> expectationFailure "expected mapping rows"
        case bindingRows of
          row : _ -> parseRecord (recordText <> row <> "\n") `shouldBe` Nothing
          [] -> expectationFailure "expected binding rows"
    it "reports exactly the newly added binding field without rewriting the shared skeleton" $
      withTempDirectory "keiro-dsl-binding-drift" $ \out -> do
        spec <- specOf "test/fixtures/consumer-types.keiro"
        let ctx = defaultContext (spec.context)
        _ <- executePlannedScaffold out "consumer-types.keiro" ctx spec
        let extended = spec {mapped = map addArtifactSummaryField ((.mapped) spec)}
        second <- executePlannedScaffold out "consumer-types.keiro" ctx extended
        (.newHoles) second
          `shouldBe` [ BindingHole
                         { mappedName = "ArtifactInfo",
                           moduleName = "Example.Artifact.KeiroBindings",
                           symbol = "artifactInfoBinding",
                           kind = BindingValue,
                           path = Just "summary",
                           signature = "artifactInfoBinding.summary :: Text"
                         }
                     ]
        renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "artifactInfoBinding.summary :: Text")
    it "rejects malformed known mapping JSON while ignoring unrelated future rows" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      withTempDirectory "keiro-dsl-mapping-malformed" $ \out -> do
        report <- executePlannedScaffold out "consumer-types.keiro" (defaultContext (spec.context)) spec
        recordText <- TIO.readFile ((.recordPath) report)
        parseRecord (recordText <> "mapping {not-json}\n") `shouldBe` Nothing
        parseRecord (recordText <> "future-row retained\n") `shouldBe` parseRecord recordText
    it "reports current and legacy semantic impact without globalizing aggregate artifacts" $
      withTempDirectory "keiro-dsl-semantic-impact-report" $ \root -> do
        old <- specOf "test/fixtures/structural-locality.keiro"
        let new = addAlphaPayloadOptionalField old
            legacyNew = mapMappedStructural "AlphaPayload" changeMappedCanonical old
            ctx = defaultContext (old.context)
            currentOut = root </> "current"
            legacyOut = root </> "legacy"
            assertAlphaOnly report = do
              map (.declaration) ((.deltas) (report.semanticImpact))
                `shouldBe` [MappedKey "AlphaPayload"]
              map (.previousConsumers) ((.deltas) (report.semanticImpact))
                `shouldBe` [Set.singleton (AggregateConsumer "Alpha")]
              map (.currentConsumers) ((.deltas) (report.semanticImpact))
                `shouldBe` [Set.singleton (AggregateConsumer "Alpha")]
              let semanticLines = renderSemanticImpactReport (report.semanticImpact)
              semanticLines `shouldSatisfy` any (T.isInfixOf "current aggregate consumers:  Alpha")
              semanticLines `shouldSatisfy` all (not . T.isInfixOf "Beta")
              map (.category) ((.generatedArtifactImpact) report)
                `shouldContain` [ServiceStructuralConformanceArtifact]
              map (.path) ((.generatedArtifactImpact) report)
                `shouldSatisfy` all (not . T.isInfixOf "/Beta/" . T.pack)
        _ <- executePlannedScaffold currentOut "semantic-impact.keiro" ctx old
        current <- executePlannedScaffold currentOut "semantic-impact.keiro" ctx new
        assertAlphaOnly current

        firstLegacy <- executePlannedScaffold legacyOut "semantic-impact.keiro" ctx old
        legacyText <- TIO.readFile ((.recordPath) firstLegacy)
        TIO.writeFile
          ((.recordPath) firstLegacy)
          (T.unlines (filter (not . T.isPrefixOf "semantic-impact ") (T.lines legacyText)))
        legacy <- executePlannedScaffold legacyOut "semantic-impact.keiro" ctx legacyNew
        let legacyLines = renderSemanticImpactReport (legacy.semanticImpact)
        legacyLines `shouldSatisfy` any (T.isInfixOf "baseline: unavailable (legacy ledger)")
        legacyLines `shouldSatisfy` any (T.isInfixOf "current aggregate consumers: Alpha")
        legacyLines `shouldSatisfy` all (not . T.isInfixOf "Beta")
        currentLedger <- TIO.readFile ((.recordPath) legacy)
        (parseRecord currentLedger >>= (.semanticImpact)) `shouldSatisfy` maybe False (const True)
        third <- executePlannedScaffold legacyOut "semantic-impact.keiro" ctx legacyNew
        (.declarations) (third.semanticImpact) `shouldBe` []

  describe "structural import plan" $ do
    it "reports the successful dependency plan in the scaffold report" $
      withTempDirectory "keiro-dsl-dependency-plan" $ \out -> do
        spec <- specOf "test/fixtures/consumer-types.keiro"
        report <- executePlannedScaffold out "consumer-types.keiro" (defaultContext (spec.context)) spec
        renderScaffoldReport report
          `shouldSatisfy` any (T.isInfixOf "dependency plan: consumer packages [artifact-domain, vendor-geometry]")
    it "refuses a binding module inside the generated namespace with the exact cycle" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let cyclic = spec {mapped = map moveArtifactBindingIntoGenerated ((.mapped) spec)}
      case planTestScaffold (defaultContext (cyclic.context)) cyclic of
        Left refusals -> do
          refusals `shouldSatisfy` any isImportCycle
          renderRefusals refusals `shouldSatisfy` any (T.isInfixOf "Generated.ConsumerDemo.Bindings")
        Right _ -> expectationFailure "expected an import-cycle refusal"
    it "refuses missing mapped register initials but permits command/event-only use" $ do
      missing <- specOf "test/fixtures/mapped-missing-initial.keiro"
      planTestScaffold (defaultContext (missing.context)) missing `shouldSatisfy` isFoldSurfaceRefusal
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let commandOnly = removeMappedRegisterRequirements spec
      planTestScaffold (defaultContext (commandOnly.context)) commandOnly `shouldSatisfy` isRight

  describe "binding explanations" $ do
    it "lists binding, fixture, and use-site-scoped initial obligations deterministically" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      obligations <- either (\errors -> expectationFailure (show errors) >> pure []) pure (bindingObligations spec)
      length obligations `shouldBe` 7
      obligations
        `shouldSatisfy` any
          ( \obligation ->
              (.kind) obligation == BindingValue
                && (.symbol) obligation == "artifactInfoBinding"
                && (.bindingVersion) obligation == Just "1"
          )
      obligations
        `shouldSatisfy` any
          ( \obligation ->
              (.kind) obligation == InitialValue
                && (.symbol) obligation == "emptyArtifactInfo"
                && any (T.isInfixOf "Catalog register currentArtifact") ((.useSites) obligation)
          )
      let rendered = renderBindingObligations (spec.context) obligations
      rendered `shouldSatisfy` T.isInfixOf "binding obligations for context consumer-demo"
      rendered `shouldSatisfy` T.isInfixOf "artifactInfoBinding :: StructuralBinding Example.Artifact.Domain.ArtifactInfo ArtifactInfoShape"
      rendered `shouldSatisfy` T.isInfixOf "provenance: binding-version \"1\""
    it "states explicitly when a spec has no structural obligations" $ do
      spec <- specOf "test/fixtures/reservation.keiro"
      obligations <- either (\errors -> expectationFailure (show errors) >> pure []) pure (bindingObligations spec)
      renderBindingObligations (spec.context) obligations
        `shouldBe` "no binding obligations for context hospital-capacity"

  describe "exact generic structural bindings" $ do
    forM_
      [ ("renamed-field", "selector mismatch"),
        ("reordered-field", "selector mismatch"),
        ("arity-mismatch", "no exact nominal correspondence"),
        ("incompatible-type", "no exact nominal correspondence")
      ]
      $ \(fixture, diagnostic) ->
        it ("rejects " <> fixture <> " and directs the author to the scaffolded module") $
          expectGenericCompileFailure fixture diagnostic

  describe "structural conformance ownership" $ do
    it "emits declaration laws once at context scope and keeps aggregate-use evidence local" $ do
      service <- checkedServiceOf "test/fixtures/consumer-types.keiro"
      let spec = checkedSpec service
          ctx = defaultContext (spec.context)
          modules = scaffoldServiceModules ctx service
          structural = generatedTextEndingIn "StructuralConformance.hs" modules
          harness = generatedTextEndingIn "Harness.hs" modules
      mapM_
        (\needle -> structural `shouldSatisfy` T.isInfixOf needle)
        [ "binding domain round-trip: example.artifact.ArtifactInfo.v1/",
          "binding shape round-trip: example.artifact.ArtifactInfo.v1/",
          "fixture coverage: example.artifact.ArtifactLocation.v1",
          "canonical identity: example.artifact.ArtifactInfo.v1",
          "projection witness agreement: example.artifact.ArtifactInfo.v1/key",
          "opaque codec round-trip: vendor.geometry.json@3/"
        ]
      mapM_
        (\needle -> harness `shouldSatisfy` T.isInfixOf needle)
        [ "mapped codec round-trip: ArtifactObserved/artifact/",
          "wire policy missing default: example.artifact.ArtifactInfo.v1/description",
          "wire policy explicit null: example.artifact.ArtifactInfo.v1/description",
          "wire policy unknown fields: example.artifact.ArtifactInfo.v1",
          "wire union arm: example.artifact.ArtifactLocation.v1/local_file",
          "forward/replay equality: ObserveArtifact from CatalogEmpty -- ",
          "register currentArtifact"
        ]
      harness `shouldNotSatisfy` T.isInfixOf "binding domain round-trip:"
      harness `shouldNotSatisfy` T.isInfixOf "fixture coverage:"
      harness `shouldNotSatisfy` T.isInfixOf "projection witness agreement:"
      structural `shouldNotSatisfy` T.isInfixOf "mapped codec round-trip:"
      structural `shouldNotSatisfy` T.isInfixOf "wire policy missing default:"
    it "keeps opaque declaration checks at service scope without inventing structural wire policy" $ do
      service <- checkedServiceOf "test/fixtures/consumer-types.keiro"
      let spec = checkedSpec service
          modules = scaffoldServiceModules (defaultContext (spec.context)) service
          structural = generatedTextEndingIn "StructuralConformance.hs" modules
          harness = generatedTextEndingIn "Harness.hs" modules
          codec = generatedTextEndingIn "Codec.hs" modules
      structural `shouldSatisfy` T.isInfixOf "opaque codec round-trip: vendor.geometry.json@3/"
      harness `shouldNotSatisfy` T.isInfixOf "opaque codec round-trip: vendor.geometry.json@3/"
      structural `shouldNotSatisfy` T.isInfixOf "wire policy unknown fields: vendor.geometry.json"
      structural `shouldNotSatisfy` T.isInfixOf "fixture coverage: vendor.geometry"
      codec `shouldNotSatisfy` T.isInfixOf "encodeVendorGeometryShape"
    it "keeps an opaque-only context self-contained" $ do
      service <- checkedServiceOf "test/fixtures/consumer-types.keiro"
      let spec = checkedSpec service
          opaqueOnly =
            checkedServiceWithSpec
              ( spec
                  { mapped = [declaration | declaration@MappedOpaque {} <- (.mapped) spec],
                    nodes = []
                  }
              )
              service
          structural = generatedTextEndingIn "StructuralConformance.hs" (scaffoldServiceModules (defaultContext (spec.context)) opaqueOnly)
      structural `shouldSatisfy` T.isInfixOf "import Keiro.Codec.Structural (FixtureCases (..))"
      structural `shouldSatisfy` T.isInfixOf "opaque codec round-trip: vendor.geometry.json@3/"
      structural `shouldNotSatisfy` T.isInfixOf "bindingDomainRoundTrip"
    it "imports the context structural gate once through the service facade" $ do
      service <- checkedServiceOf "test/fixtures/consumer-types.keiro"
      let ctx = defaultContext ((checkedSpec service).context)
      case serviceHarnessModule ctx service of
        Left duplicates -> expectationFailure ("unexpected duplicate fact keys: " <> show duplicates)
        Right facade -> do
          T.count "import Generated.ConsumerDemo.StructuralConformance qualified as StructuralConformance" ((.text) facade) `shouldBe` 1
          T.count "StructuralConformance.structuralConformanceAssertions" ((.text) facade) `shouldBe` 1
          (.text) facade `shouldSatisfy` T.isInfixOf "\"structural/\" <> fact"
          (.text) facade `shouldNotSatisfy` T.isInfixOf "structuralConformanceAssertions] |"
    it "keeps every Beta artifact byte-identical when an Alpha-only mapped declaration changes" $ do
      workspace <- shouldComposeWorkspace "test/fixtures/structural-locality.keiro-workspace"
      let changedSpec = addAlphaPayloadOptionalField ((.mergedSpec) workspace)
          changedMember member = workspaceMemberWithSpec (addAlphaPayloadOptionalField member.spec) member
          changedWorkspace = workspaceWithMembersAndMergedSpec (map changedMember workspace.members) changedSpec workspace
          ctx = workspaceContext workspace
          plan value = planWorkspaceScaffold "goldens" ctx value
          moduleBytes owner planValue =
            Map.fromList
              [ ((.path) moduleValue, ((.text) moduleValue, (.kind) moduleValue, provenance))
              | (moduleValue, provenance) <- (.modules) planValue,
                ("/" <> owner <> "/") `T.isInfixOf` T.pack ((.path) moduleValue)
              ]
          moduleWith suffix planValue = generatedTextEndingIn suffix (map fst ((.modules) planValue))
      baseline <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (plan workspace)
      changed <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (plan changedWorkspace)
      moduleBytes "Beta" changed `shouldBe` moduleBytes "Beta" baseline
      moduleWith "Alpha/Harness.hs" changed `shouldNotBe` moduleWith "Alpha/Harness.hs" baseline
      moduleWith "StructuralConformance.hs" changed `shouldNotBe` moduleWith "StructuralConformance.hs" baseline
      let alphaHarness = moduleWith "Alpha/Harness.hs" changed
          betaHarness = moduleWith "Beta/Harness.hs" changed
          structural = moduleWith "StructuralConformance.hs" changed
      alphaHarness `shouldSatisfy` T.isInfixOf "mapped codec round-trip: AlphaSubmitted/item/"
      betaHarness `shouldNotSatisfy` T.isInfixOf "AlphaPayload"
      T.count "binding domain round-trip: example.locality.AlphaPayload.v1/" structural `shouldBe` 1
      alphaHarness `shouldNotSatisfy` T.isInfixOf "binding domain round-trip: example.locality.AlphaPayload.v1/"
      betaHarness `shouldNotSatisfy` T.isInfixOf "binding domain round-trip: example.locality.AlphaPayload.v1/"
      structural `shouldSatisfy` T.isInfixOf "fixture coverage: example.locality.UnusedPayload.v1"
    it "refuses a missing fixture before the CLI writes any scaffold output" $
      withTempDirectory "keiro-dsl-structural-no-write" $ \out -> do
        baselineTree <- treeSnapshot out
        (exitCode, _, standardError) <- runKeiroDsl ["scaffold", "test/fixtures/mapped-missing-fixture.keiro", "--out", out]
        exitCode `shouldSatisfy` (/= ExitSuccess)
        standardError `shouldContain` "missing fixtures ingredient"
        treeSnapshot out `shouldReturn` baselineTree

  describe "semantic locality qualification" $ do
    it "pins the exact A-only generated delta and semantic report" $
      withSemanticLocalityFixture "keiro-dsl-locality-a-only" id 0 $ \_ out workspace -> do
        baselinePlan <- shouldPlanWorkspaceSpec workspace
        let changedWorkspace = mapWorkspaceSpec addAlphaPayloadOptionalField workspace
        changedPlan <- shouldPlanWorkspaceSpec changedWorkspace
        let baselineModules = map fst ((.modules) baselinePlan)
            changedModules = map fst ((.modules) changedPlan)
            delta = generatedTreeDelta baselineModules changedModules
            expectedPaths =
              Set.fromList
                [ "Generated/SemanticLocality/Alpha/Codec.hs",
                  "Generated/SemanticLocality/Alpha/Harness.hs",
                  "Generated/SemanticLocality/Structural/Shape/AlphaPayload.hs",
                  "Generated/SemanticLocality/StructuralConformance.hs"
                ]
            allowedRoles =
              Set.fromList
                [ moduleRole generatedModule
                | generatedModule <- changedModules,
                  (.path) generatedModule `Set.member` expectedPaths
                ]
            impact = CheckedDiff.mappedSemanticImpact ((.mergedSpec) workspace) ((.mergedSpec) changedWorkspace)
            renderedImpact = T.unlines (renderSemanticImpact impact)
            encodedReport = LazyText.toStrict (LazyTextEncoding.decodeUtf8 (Aeson.encode (diffReportWithSemanticImpact defaultGate (diffSpecs ((.mergedSpec) workspace) ((.mergedSpec) changedWorkspace)) impact)))
        (.changedPaths) delta `shouldBe` expectedPaths
        (.addedPaths) delta `shouldBe` Set.empty
        (.removedPaths) delta `shouldBe` Set.empty
        assertAllowedGeneratedDelta allowedRoles baselineModules changedModules delta
        map (.declaration) impact `shouldBe` [MappedKey "AlphaPayload"]
        map (.previousConsumers) impact `shouldBe` [Set.singleton (AggregateConsumer "Alpha")]
        map (.currentConsumers) impact `shouldBe` [Set.singleton (AggregateConsumer "Alpha")]
        renderedImpact `shouldSatisfy` T.isInfixOf "previous aggregate consumers: Alpha"
        renderedImpact `shouldSatisfy` T.isInfixOf "service-conformance: impacted"
        renderedImpact `shouldSatisfy` (not . T.isInfixOf "Beta")
        encodedReport `shouldSatisfy` T.isInfixOf "\"semanticImpact\""
        encodedReport `shouldSatisfy` T.isInfixOf "\"currentConsumers\":[\"Alpha\"]"
        encodedReport `shouldSatisfy` (not . T.isInfixOf "Beta")

        _ <- executePlannedWorkspaceScaffold out workspace
        report <- executePlannedWorkspaceScaffold out changedWorkspace
        (.declarations) (report.semanticImpact) `shouldBe` [MappedKey "AlphaPayload"]
        map (.path) ((.generatedArtifactImpact) report) `shouldBe` Set.toAscList expectedPaths
        map (.category) ((.generatedArtifactImpact) report)
          `shouldSatisfy` \categories ->
            AggregateGeneratedArtifact `elem` categories
              && ServiceStructuralConformanceArtifact `elem` categories
        map (.category) ((.generatedArtifactImpact) report)
          `shouldNotContain` [BehaviorSourceMapArtifact]
        ledger <- TIO.readFile ((.recordPath) report)
        case parseWorkspaceRecord ledger of
          Just record -> record.semanticImpact `shouldSatisfy` (/= Nothing)
          Nothing -> expectationFailure "semantic-locality workspace ledger did not parse"

    it "keeps the A-only delta constant with ten unrelated aggregates" $ do
      let deltaFor count =
            withSemanticLocalityFixture ("keiro-dsl-locality-scale-" <> show count) id count $ \_ _ workspace -> do
              baseline <- shouldPlanWorkspaceSpec workspace
              changed <- shouldPlanWorkspaceSpec (mapWorkspaceSpec addAlphaPayloadOptionalField workspace)
              pure (generatedTreeDelta (map fst ((.modules) baseline)) (map fst ((.modules) changed)))
      twoAggregateDelta <- deltaFor 0
      twelveAggregateDelta <- deltaFor 10
      twelveAggregateDelta `shouldBe` twoAggregateDelta

    it "keeps nested and fixture-symbol changes local while shared and unused laws remain service-owned" $
      withSemanticLocalityFixture "keiro-dsl-locality-closure" id 0 $ \_ _ workspace -> do
        baseline <- shouldPlanWorkspaceSpec workspace
        nested <- shouldPlanWorkspaceSpec (mapWorkspaceSpec addNestedPayloadOptionalField workspace)
        fixtureChanged <- shouldPlanWorkspaceSpec (mapWorkspaceSpec changeAlphaPayloadFixtureSymbol workspace)
        let baselineModules = map fst ((.modules) baseline)
            nestedModules = map fst ((.modules) nested)
            fixtureModules = map fst ((.modules) fixtureChanged)
            nestedDelta = generatedTreeDelta baselineModules nestedModules
            fixtureDelta = generatedTreeDelta baselineModules fixtureModules
            betaPaths = Set.fromList [(.path) value | value <- baselineModules, "/Beta/" `T.isInfixOf` T.pack ((.path) value)]
            structural = generatedTextEndingIn "StructuralConformance.hs" baselineModules
            alphaHarness = generatedTextEndingIn "Alpha/Harness.hs" baselineModules
            betaHarness = generatedTextEndingIn "Beta/Harness.hs" baselineModules
            snapshot = semanticImpactSnapshotForSpec ((.mergedSpec) workspace)
        (.changedPaths) nestedDelta `shouldSatisfy` Set.null . Set.intersection betaPaths
        (.changedPaths) fixtureDelta `shouldSatisfy` Set.null . Set.intersection betaPaths
        map (.declaration) (CheckedDiff.mappedSemanticImpact ((.mergedSpec) workspace) (addNestedPayloadOptionalField ((.mergedSpec) workspace)))
          `shouldBe` [MappedKey "AlphaPayload", MappedKey "NestedPayload"]
        mappedDeclarationConsumers (semanticImpactForSpec ((.mergedSpec) workspace)) (MappedKey "SharedPayload")
          `shouldBe` [AggregateConsumer "Alpha", AggregateConsumer "Beta"]
        mappedDeclarationConsumers (semanticImpactForSpec ((.mergedSpec) workspace)) (MappedKey "UnusedPayload")
          `shouldBe` []
        (.serviceInventory) snapshot `shouldSatisfy` Set.member (MappedKey "UnusedPayload")
        T.count "fixture coverage: example.semantic-locality.SharedPayload.v1" structural `shouldBe` 1
        T.count "fixture coverage: example.semantic-locality.UnusedPayload.v1" structural `shouldBe` 1
        alphaHarness `shouldSatisfy` T.isInfixOf "SharedPayload"
        betaHarness `shouldSatisfy` T.isInfixOf "SharedPayload"
        alphaHarness `shouldNotSatisfy` T.isInfixOf "fixture coverage:"
        betaHarness `shouldNotSatisfy` T.isInfixOf "fixture coverage:"

    it "isolates comments, blank lines, and an unrelated rule to BehaviorSourceMap" $ do
      let mutations =
            [ ("comment", ("# source-only movement\n" <>)),
              ("blank-line", ("\n" <>)),
              ( "unrelated-rule",
                T.replace
                  "aggregate Alpha\n"
                  "rule unusedIsUnused : UnusedPayload -> Bool\n  ex Unused => true\n\naggregate Alpha\n"
              )
            ]
      forM_ mutations $ \(variantName, mutateSource) ->
        withSemanticLocalityFixture ("keiro-dsl-locality-source-" <> variantName) id 0 $ \root out workspace -> do
          _ <- executePlannedWorkspaceScaffold out workspace
          treeBefore <- treeSnapshot out
          let path = root </> "domain/alpha.keiro"
          original <- TIO.readFile path
          TIO.writeFile path (mutateSource original)
          moved <- loadTempWorkspace root
          report <- executePlannedWorkspaceScaffold out moved
          let overwritten = [value.path | (value, _, Overwritten) <- (.dispositions) report]
              sourceMapPath path = T.isSuffixOf "/BehaviorSourceMap.hs" (T.pack path)
          overwritten `shouldSatisfy` \case
            [path] -> sourceMapPath path
            _ -> False
          (.declarations) (report.semanticImpact) `shouldBe` []
          map (.category) ((.generatedArtifactImpact) report) `shouldBe` [BehaviorSourceMapArtifact]
          treeAfter <- treeSnapshot out
          let treeDelta = generatedTreeDeltaFromSnapshot treeBefore treeAfter
              ledgerPath path = T.isPrefixOf "keiro-dsl-ledger.workspace." (T.pack path)
          (.changedPaths) treeDelta `shouldSatisfy` \paths ->
            Set.size paths == 2
              && any sourceMapPath paths
              && any ledgerPath paths
          filter (\(path, _) -> not (sourceMapPath path || ledgerPath path)) treeAfter
            `shouldBe` filter (\(path, _) -> not (sourceMapPath path || ledgerPath path)) treeBefore

    it "keeps complete scaffold bytes deterministic under member reordering" $
      withSemanticLocalityFixture "keiro-dsl-locality-order-a" id 0 $ \_ outA workspaceA ->
        withSemanticLocalityFixture "keiro-dsl-locality-order-b" reverse 0 $ \_ outB workspaceB -> do
          _ <- executePlannedWorkspaceScaffold outA workspaceA
          _ <- executePlannedWorkspaceScaffold outB workspaceB
          expected <- treeSnapshot outA
          treeSnapshot outB `shouldReturn` expected

  describe "generated Haskell language contract" $ do
    it "limits every representative generated module to the closed local extension set" $ do
      let allowed =
            Set.fromList
              [ "BlockArguments",
                "DeriveAnyClass",
                "DuplicateRecordFields",
                "OverloadedLabels",
                "OverloadedRecordDot",
                "QualifiedDo",
                "TemplateHaskell",
                "TypeFamilies"
              ]
          fixtures =
            [ "test/fixtures/aggregate-scalar-expressions-v2.keiro",
              "test/fixtures/nominal-scalars.keiro",
              "test/fixtures/structural-conformance.keiro",
              "test/fixtures/reservation.keiro",
              "test/fixtures/contract-v4.keiro",
              "test/fixtures/intake.keiro",
              "test/fixtures/reservation-work.keiro",
              "test/fixtures/readmodel-runtime.keiro"
            ]
      forM_ fixtures $ \fixture -> do
        modules <- scaffoldFixture fixture
        forM_ [generatedModule | generatedModule <- modules, (.kind) generatedModule == Generated] $ \generatedModule -> do
          let actual = Set.fromList (generatedLocalExtensions generatedModule)
          unless (actual `Set.isSubsetOf` allowed) $
            expectationFailure (fixture <> ":" <> (.path) generatedModule <> ": disallowed local extensions " <> show (Set.toList (actual `Set.difference` allowed)))

    it "retains specialized syntax extensions and removes GHC2024-covered pragmas" $ do
      scalar <- scaffoldFixture "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      structural <- scaffoldFixture "test/fixtures/structural-conformance.keiro"
      reservation <- scaffoldFixture "test/fixtures/reservation.keiro"
      contract <- scaffoldFixture "test/fixtures/contract-v4.keiro"
      intake <- scaffoldFixture "test/fixtures/intake.keiro"
      queue <- scaffoldFixture "test/fixtures/reservation-work.keiro"
      readModel <- scaffoldFixture "test/fixtures/readmodel-runtime.keiro"
      generatedExtensionsEndingIn "ScalarAccount/Domain.hs" scalar
        `shouldBe` ["DeriveAnyClass", "TemplateHaskell"]
      generatedExtensionsEndingIn "ScalarAccount/Transducer.hs" scalar
        `shouldBe` ["BlockArguments", "OverloadedLabels", "QualifiedDo"]
      generatedExtensionsEndingIn "Nominals.hs" scalar `shouldContain` ["DeriveAnyClass", "TypeFamilies"]
      generatedExtensionsEndingIn "Nominals/Internal.hs" scalar `shouldBe` []
      generatedExtensionsEndingIn "StructuralProjections.hs" structural `shouldBe` ["TypeFamilies"]
      let structuralShapeExtensions =
            [ generatedLocalExtensions generatedModule
            | generatedModule <- structural,
              "/Structural/Shape/" `T.isInfixOf` T.pack ((.path) generatedModule)
            ]
      structuralShapeExtensions `shouldSatisfy` all null
      generatedExtensionsEndingIn "Projection.hs" reservation `shouldBe` []
      generatedExtensionsEndingIn "ReplayAudit.hs" reservation `shouldBe` []
      generatedExtensionsEndingIn "Contract.hs" contract `shouldBe` []
      generatedExtensionsEndingIn "Inbox.hs" intake `shouldBe` []
      generatedExtensionsEndingIn "Queue.hs" queue `shouldBe` []
      generatedExtensionsEndingIn "ReadModel.hs" readModel `shouldBe` []

    it "conditions label and derivation extensions on emitted syntax while record defaults stay manifest-owned" $ do
      mappedGuardSource <- readTestText "test/fixtures/mapped-guard.keiro"
      mappedGuardParsed <- case parseSource "mapped-guard-no-expression.keiro" (T.replace "guard current == current ; " "" mappedGuardSource) of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right parsed -> pure parsed
      let mappedGuardService = checkedSource mappedGuardParsed
          mappedGuard = scaffoldServiceModules (defaultContext ((checkedSpec mappedGuardService).context)) mappedGuardService
      registerFree <- scaffoldFixture "test/fixtures/order.keiro"
      readModels <- scaffoldFixture "test/fixtures/readmodel.keiro"
      snapshot <- scaffoldFixture "test/fixtures/reservation-snapshot.keiro"
      ordinary <- scaffoldFixture "test/fixtures/reservation.keiro"
      generatedExtensionsEndingIn "Holder/Domain.hs" mappedGuard `shouldBe` ["TemplateHaskell"]
      generatedExtensionsEndingIn "Holder/Codec.hs" mappedGuard `shouldBe` []
      generatedExtensionsEndingIn "Holder/Transducer.hs" mappedGuard
        `shouldBe` ["BlockArguments", "QualifiedDo"]
      generatedExtensionsEndingIn "Holder/Harness.hs" mappedGuard `shouldBe` ["OverloadedLabels"]
      generatedExtensionsEndingIn "Order/Harness.hs" registerFree `shouldBe` []
      generatedExtensionsEndingIn "TransferDecisions/ReadModel.hs" readModels `shouldBe` []
      generatedExtensionsEndingIn "Subscriptions/ReadModel.hs" readModels `shouldBe` []
      generatedExtensionsEndingIn "Reservation/Domain.hs" snapshot `shouldContain` ["DeriveAnyClass"]
      generatedExtensionsEndingIn "Reservation/Domain.hs" ordinary `shouldNotContain` ["DeriveAnyClass"]

      disjoint <-
        parseInlineSpec "<disjoint-contract>" $
          T.unlines
            [ "language keiro-dsl 4",
              "context language-contract",
              "contract disjoint {",
              "  schemaVersion 1",
              "  discriminator kind",
              "  topic events \"events\"",
              "  event First on events { first: text }",
              "  event Second on events { second: text }",
              "}"
            ]
      emptyPayload <-
        parseInlineSpec "<empty-contract>" $
          T.unlines
            [ "language keiro-dsl 4",
              "context language-contract",
              "contract empty {",
              "  schemaVersion 1",
              "  discriminator kind",
              "  topic events \"events\"",
              "  event Empty on events { }",
              "}"
            ]
      let contractExtensions spec =
            generatedExtensionsEndingIn
              "Contract.hs"
              [ generatedModule
              | contractNode <- [contractNode | NContract contractNode <- (.nodes) spec],
                generatedModule <- scaffoldContract (defaultContext (spec.context)) contractNode
              ]
      contractExtensions disjoint `shouldBe` []
      contractExtensions emptyPayload `shouldBe` []

  describe "manifest (M2)" $ do
    it "lists exactly the modules the scaffolder produced" $ do
      mods <- scaffoldFixture "test/fixtures/reservation.keiro"
      service <- checkedServiceOf "test/fixtures/reservation.keiro"
      let manifest = renderManifestForService "reservation.keiro" mods service
          expectedNames = sort (map (moduleNameOf . (.path)) mods)
      assertGeneratedHaskellContract "reservation.keiro" manifest
      -- every produced module name appears in the manifest…
      mapM_ (\m -> (m `T.isInfixOf` manifest) `shouldBe` True) expectedNames
      -- …and the module list is exactly the scaffolder's output set.
      expectedNames
        `shouldBe` sort
          [ "Generated.HospitalCapacity.Reservation.Codec",
            "Generated.HospitalCapacity.Reservation.BehaviorContract",
            "Generated.HospitalCapacity.Reservation.Domain",
            "Generated.HospitalCapacity.Reservation.EventStream",
            "Generated.HospitalCapacity.Reservation.Harness",
            "Generated.HospitalCapacity.Reservation.Projection",
            "Generated.HospitalCapacity.Reservation.Transducer",
            "Generated.HospitalCapacity.Nominals",
            "Generated.HospitalCapacity.Nominals.Internal",
            "Generated.HospitalCapacity.ReplayAudit",
            "HospitalCapacity.Reservation.BehaviorHoles",
            "HospitalCapacity.Reservation.Holes"
          ]
    it "derives the dependency set from the node kinds present (aggregate)" $ do
      service <- checkedServiceOf "test/fixtures/reservation.keiro"
      manifestDependenciesForService service `shouldBe` ["aeson", "base", "keiki", "keiro", "text"]
    it "derives the process dependency set, including worker-policy runtime imports" $ do
      service <- checkedServiceOf "test/fixtures/hospital-surge.keiro"
      let dependencies = manifestDependenciesForService service
      mapM_ (\dependency -> dependencies `shouldContain` [dependency]) ["time", "uuid", "shibuya-core", "keiki", "keiro"]
    it "uses the registered shibuya-core package name for router scaffolds" $ do
      service <- checkedServiceOf "test/fixtures/incident-paging/incident-paging.keiro"
      let dependencies = manifestDependenciesForService service
      mapM_ (\dependency -> dependencies `shouldContain` [dependency]) ["effectful-core", "keiro", "shibuya-core"]
      dependencies `shouldNotContain` ["shibuya"]

  describe "service conformance facade (plan 188 M2)" $ do
    it "normalizes aggregate and read-model checks behind one base-only API" $ do
      service <- checkedServiceOf "test/fixtures/transfer-routing.keiro"
      let ctx = defaultContext ((checkedSpec service).context)
      case serviceHarnessModule ctx service of
        Left duplicates -> expectationFailure ("unexpected duplicate fact keys: " <> show duplicates)
        Right facade -> do
          committed <- readTestText ("test/conformance-newsurface/" <> (.path) facade)
          normalizeGenerated committed `shouldBe` normalizeGenerated ((.text) facade)
          moduleNameOf ((.path) facade) `shouldBe` "Generated.TransferRouting.Conformance"
          (.text) facade `shouldSatisfy` T.isInfixOf ".harnessAssertions"
          (.text) facade `shouldSatisfy` T.isInfixOf ".readModelFactResults"
          (.text) facade `shouldSatisfy` T.isInfixOf "aggregate/Hospital/"
          (.text) facade `shouldSatisfy` T.isInfixOf "readmodel/hospital_load/"
          (.text) facade `shouldSatisfy` T.isInfixOf "qualified as Hospital"
          (.text) facade `shouldSatisfy` T.isInfixOf "qualified as HospitalLoad"
          (.text) facade `shouldNotSatisfy` T.isInfixOf "qualified as Harness"
          (.text) facade `shouldNotSatisfy` T.isInfixOf "TransferRouting.Hospital.Holes"
    it "projects process, router, and workflow facts with qualified stable keys" $ do
      processService <- checkedServiceOf "test/fixtures/hospital-surge.keiro"
      routerService <- checkedServiceOf "test/fixtures/incident-paging/incident-paging.keiro"
      workflowService <- checkedServiceOf "test/fixtures/workflow-evolution.keiro"
      let select predicate = filter predicate . (.nodes) . checkedSpec
          factNodes =
            select (\case NProcess {} -> True; _ -> False) processService
              <> select (\case NRouter {} -> True; _ -> False) routerService
              <> select (\case NWorkflow {} -> True; _ -> False) workflowService
          baseSpec = checkedSpec processService
          service = checkedServiceWithSpec (specWithNodes factNodes baseSpec) processService
          ctx = defaultContext (baseSpec.context)
      forM_
        [ "process/HospitalSurge/maxAttempts",
          "router/PagingRouter/dispatchCommand",
          "workflow/HospitalTransferReservation/body"
        ]
        (\key -> serviceConformanceFactKeys service `shouldSatisfy` elem key)
      case serviceHarnessModule ctx service of
        Left duplicates -> expectationFailure ("unexpected duplicate fact keys: " <> show duplicates)
        Right facade -> do
          (.text) facade `shouldSatisfy` T.isInfixOf ".processHarnessValues"
          (.text) facade `shouldSatisfy` T.isInfixOf ".routerHarnessValues"
          (.text) facade `shouldSatisfy` T.isInfixOf ".workflowFactValues"
    it "uses the shared context-level placement policy" $ do
      service <- checkedServiceOf "test/fixtures/contract-v4.keiro"
      let ctx = Context {name = "modules", moduleRoot = "Mori", placement = CollocatedLeaf}
      serviceConformanceModuleName ctx `shouldBe` "Mori.Modules.Generated.Conformance"
      case serviceHarnessModule ctx service of
        Left duplicates -> expectationFailure ("unexpected duplicate fact keys: " <> show duplicates)
        Right facade -> do
          (.text) facade `shouldSatisfy` T.isInfixOf "runServiceConformanceChecks = pure []"
          (.text) facade `shouldSatisfy` T.isInfixOf "serviceConformanceFacts = []"
    it "adds one facade only to configured single-file plans and exposes only it" $ do
      service <- checkedServiceOf "test/fixtures/reservation.keiro"
      let ctx = defaultContext ((checkedSpec service).context)
          runtimePackage = RuntimePackageName "reservation-runtime"
      unconfigured <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffold ctx service)
      configured <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffoldWithRuntimePackage (Just runtimePackage) ctx service)
      let facadeName = serviceConformanceModuleName ctx
          facades = [moduleValue | moduleValue <- configured, moduleNameOf ((.path) moduleValue) == facadeName]
          manifest = renderManifestForServiceWithFacade (Just facadeName) "reservation.keiro" configured service
      length configured `shouldBe` length unconfigured + 1
      length facades `shouldBe` 1
      manifest `shouldSatisfy` T.isInfixOf ("exposed-modules:\n    " <> facadeName)
      T.count facadeName manifest `shouldBe` 1
    it "emits one context-level facade for a multi-member workspace regardless of member order" $ do
      canonical <- shouldComposeWorkspace canonicalWorkspacePath
      reordered <- shouldComposeWorkspace "test/fixtures/workspace/service-reordered.keiro-workspace"
      let runtimePackage = Just (RuntimePackageName "demo-runtime")
          plan workspace =
            planWorkspaceScaffoldWithRuntimePackageAndGoldens [] runtimePackage "goldens" (workspaceContext workspace) workspace
          facades workspacePlan =
            [ ((.text) moduleValue, provenance)
            | (moduleValue, provenance) <- (.modules) workspacePlan,
              ".Conformance" `T.isSuffixOf` moduleNameOf ((.path) moduleValue)
            ]
      canonicalPlan <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (plan canonical)
      reorderedPlan <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (plan reordered)
      facades canonicalPlan `shouldBe` facades reorderedPlan
      map snd (facades canonicalPlan) `shouldBe` [ContextLevel]
    it "refuses duplicate normalized fact keys before planning writes" $ do
      service <- checkedServiceOf "test/fixtures/hospital-surge.keiro"
      let spec = checkedSpec service
          processes = [node | node@NProcess {} <- (.nodes) spec]
          duplicated = checkedServiceWithSpec (specWithNodes (processes <> processes) spec) service
      serviceHarnessModule (defaultContext (spec.context)) duplicated `shouldSatisfy` isLeft

  describe "runnable service conformance package (plan 188 M3)" $ do
    it "uses readable ordinary names and collision-safe punctuation encoding" $ do
      cabaliseConformanceService "mori" `shouldBe` "mori"
      cabaliseConformanceService "mori_core" `shouldNotBe` cabaliseConformanceService "mori-core"
      cabaliseConformanceService "Mori" `shouldNotBe` cabaliseConformanceService "mori"
      conformancePackageDirectory (WorkspaceConformanceService "mori") `shouldBe` "keiro-dsl-conformance.workspace.mori"
      conformancePackageDirectory (StandaloneConformanceService "mori") `shouldBe` "keiro-dsl-conformance.mori"
    it "plans one base-only package and round-trips its complete generated record" $ do
      service <- checkedServiceOf "test/fixtures/hospital-surge.keiro"
      let runtimePackage = RuntimePackageName "hospital-runtime"
          facade = "Generated.HospitalSurge.Conformance"
      plan <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planConformancePackage (StandaloneConformanceService "hospital-surge") runtimePackage facade service)
      (.packageName) plan `shouldBe` "keiro-hospital-surge-conformance"
      length [file | file <- (.files) plan, takeExtension ((.path) file) == ".cabal"] `shouldBe` 1
      cabalFile <- case [file | file <- (.files) plan, takeExtension ((.path) file) == ".cabal"] of
        [file] -> pure file
        files -> expectationFailure ("expected one Cabal file, got " <> show (map (.path) files)) >> fail "unreachable"
      let cabalText = (.text) cabalFile
      cabalText `shouldSatisfy` T.isInfixOf "base >=4.18 && <5"
      T.lines cabalText `shouldSatisfy` (\lines' -> case lines' of first : _ -> first == "cabal-version: 3.0"; [] -> False)
      cabalText `shouldSatisfy` T.isInfixOf "hospital-runtime"
      cabalText `shouldSatisfy` T.isInfixOf "ghc-options: -Wall"
      cabalText `shouldNotSatisfy` T.isInfixOf "    , keiro-dsl\n"
      recordFile <- case [file | file <- (.files) plan, (.path) file == conformanceRecordFileName] of
        [file] -> pure file
        files -> expectationFailure ("expected one package record, got " <> show (map (.path) files)) >> fail "unreachable"
      let recordText = (.text) recordFile
      parseConformancePackageRecord recordText
        `shouldBe` Just
          ConformancePackageRecord
            { schema = 1,
              serviceKey = (.serviceKey) plan,
              runtimePackage = runtimePackage,
              facadeModule = facade,
              files = [((.kind) file, (.path) file) | file <- (.files) plan]
            }
    it "tolerates future rows and JSON keys while round-tripping awkward safe paths" $ do
      let recordText =
            T.unlines
              [ "keiro-dsl conformance ledger v1",
                "service-key standalone hospital-surge",
                "runtime-package hospital-runtime",
                "facade-module Generated.HospitalSurge.Conformance",
                "file {\"kind\":\"generated\",\"path\":\"generated/file with space.hs\",\"future-key\":true}",
                "future-row {\"value\":1}"
              ]
          expected =
            ConformancePackageRecord
              { schema = 1,
                serviceKey = StandaloneConformanceService "hospital-surge",
                runtimePackage = RuntimePackageName "hospital-runtime",
                facadeModule = "Generated.HospitalSurge.Conformance",
                files = [(Generated, "generated/file with space.hs")]
              }
      parseConformancePackageRecord recordText `shouldBe` Just expected
      parseConformancePackageRecord (renderConformancePackageRecord expected) `shouldBe` Just expected
      parseConformancePackageRecord (T.replace "generated/file with space.hs" "../escape.hs" recordText)
        `shouldBe` Nothing
      parseConformancePackageRecord (T.replace "future-row {\"value\":1}" "file {\"kind\":\"generated\",\"path\":\"GENERATED/FILE WITH SPACE.HS\"}" recordText)
        `shouldBe` Nothing
    it "compares unique facts by key and distinguishes mismatch, missing, and unexpected" $ do
      compareConformanceFacts [("a", "1"), ("b", "2"), ("d", "4")] [("c", "3"), ("a", "1"), ("b", "9")]
        `shouldBe` Right
          [ ConformanceFactMatch "a" "1",
            ConformanceFactMismatch "b" "2" "9",
            ConformanceFactUnexpected "c" "3",
            ConformanceFactMissing "d" "4"
          ]
      compareConformanceFacts [("a", "1"), ("a", "2")] []
        `shouldBe` Left [DuplicateFactKey ExpectedFact "a"]
    it "creates once, reports generated files unchanged, and preserves accepted expectations" $ do
      withTempDirectory "keiro-dsl-conformance-package" $ \out -> do
        parsed <- parsedSourceOf "test/fixtures/hospital-surge.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            runtimePackage = RuntimePackageName "hospital-runtime"
        modules <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffoldWithRuntimePackage (Just runtimePackage) ctx service)
        first <- executeServiceScaffoldWithRuntimePackage (Just runtimePackage) out False "hospital-surge.keiro" ((.sourceLanguage) parsed) ctx service modules
        firstReport <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure first
        firstPackage <- maybe (expectationFailure "expected conformance package report" >> fail "unreachable") pure ((.conformancePackage) firstReport)
        let packageRoot = out </> conformancePackageDirectory (StandaloneConformanceService ((.name) ctx))
            expectationsPath = packageRoot </> "src/KeiroConformance/Expectations.hs"
            accepted = "module KeiroConformance.Expectations where\n-- accepted by the application\n"
        map snd ((.dispositions) firstPackage) `shouldContain` [ConformanceCreated]
        TIO.writeFile expectationsPath accepted
        second <- executeServiceScaffoldWithRuntimePackage (Just runtimePackage) out True "hospital-surge.keiro" ((.sourceLanguage) parsed) ctx service modules
        secondReport <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure second
        secondPackage <- maybe (expectationFailure "expected conformance package report" >> fail "unreachable") pure ((.conformancePackage) secondReport)
        TIO.readFile expectationsPath `shouldReturn` accepted
        [ disposition
          | (file, disposition) <- (.dispositions) secondPackage,
            (.kind) file == Generated
          ]
          `shouldSatisfy` all (== ConformanceUnchanged)
        [ disposition
          | (file, disposition) <- (.dispositions) secondPackage,
            (.kind) file == HoleStub
          ]
          `shouldBe` [ConformanceSkipped]
    -- Migration used to be planned only when the run also planned a conformance
    -- package, so a spec that stopped generating one left its legacy record
    -- behind — and unreadable, since the current reader has no legacy parser.
    -- See ExecPlan 199.
    it "migrates an orphaned legacy conformance record even with no package planned" $
      withTempDirectory "keiro-dsl-orphan-conformance-ledger" $ \out -> do
        parsed <- parsedSourceOf "test/fixtures/hospital-surge.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            orphanDirectory = out </> "keiro-dsl-conformance.standalone.retired-service"
            orphanPath = orphanDirectory </> legacyConformanceRecordFileName
            -- No --runtime-package, so this run plans no conformance package at
            -- all: the record below belongs to a package that no longer exists.
            run apply = do
              modules <-
                either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure $
                  planTestServiceScaffoldWithRuntimePackage Nothing ctx service
              executeServiceScaffoldWithRuntimePackageAndNameMigrations
                Nothing
                apply
                out
                False
                "hospital-surge.keiro"
                ((.sourceLanguage) parsed)
                ctx
                service
                modules
        -- Build the orphan from a record the current writer produced, so the
        -- test exercises the discovery change and not a hand-typed format.
        withTempDirectory "keiro-dsl-orphan-source" $ \source -> do
          let sourceRuntime = RuntimePackageName "retired-runtime"
              sourcePackageRoot = source </> conformancePackageDirectory (StandaloneConformanceService ((.name) ctx))
          sourceModules <-
            either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure $
              planTestServiceScaffoldWithRuntimePackage (Just sourceRuntime) ctx service
          _ <-
            executeServiceScaffoldWithRuntimePackageAndNameMigrations
              (Just sourceRuntime)
              False
              source
              False
              "hospital-surge.keiro"
              ((.sourceLanguage) parsed)
              ctx
              service
              sourceModules
              >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
          ledger <- TIO.readFile (sourcePackageRoot </> conformanceLedgerFileName)
          record <-
            maybe (expectationFailure "conformance ledger did not parse" >> fail "unreachable") pure $
              parseConformancePackageRecord ledger
          createDirectoryIfMissing True orphanDirectory
          TIO.writeFile
            orphanPath
            ( T.unlines $
                [line | line <- T.lines ledger, isGeneratedBannerLine line]
                  <> [ "schema 1",
                       "service-key standalone " <> (.name) ctx,
                       "runtime-package " <> (.unRuntimePackageName) ((.runtimePackage) record),
                       "facade-module " <> (.facadeModule) record
                     ]
                  <> [ "file "
                         <> (case fileKind of Generated -> "generated"; HoleStub -> "create-once")
                         <> " "
                         <> T.pack path
                     | (fileKind, path) <- (.files) record
                     ]
            )
        refused <- run False
        refused `shouldSatisfy` \case
          Left [SidecarMigrationRequired [move]] ->
            (.moveDisposition) move == ConvertLegacyConformanceLedger
          _ -> False

        applied <- run True >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        map (.moveDisposition) ((.sidecarMoves) applied) `shouldBe` [ConvertLegacyConformanceLedger]
        doesFileExist orphanPath `shouldReturn` False
        doesFileExist (orphanDirectory </> conformanceLedgerFileName) `shouldReturn` True

    it "converts a legacy conformance record losslessly and keeps service-key mismatch refusal" $
      withTempDirectory "keiro-dsl-conformance-ledger-migration" $ \out -> do
        parsed <- parsedSourceOf "test/fixtures/hospital-surge.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            runtimePackage = RuntimePackageName "hospital-runtime"
            packageRoot = out </> conformancePackageDirectory (StandaloneConformanceService ((.name) ctx))
            currentPath = packageRoot </> conformanceLedgerFileName
            legacyPath = packageRoot </> legacyConformanceRecordFileName
            backupPath = out </> ".keiro-dsl-name-migrations/sidecar-v1" </> conformancePackageDirectory (StandaloneConformanceService ((.name) ctx)) </> legacyConformanceRecordFileName
        modules <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffoldWithRuntimePackage (Just runtimePackage) ctx service)
        let run apply =
              executeServiceScaffoldWithRuntimePackageAndNameMigrations
                (Just runtimePackage)
                apply
                out
                False
                "hospital-surge.keiro"
                ((.sourceLanguage) parsed)
                ctx
                service
                modules
            renderLegacyKey (WorkspaceConformanceService value) = "workspace " <> value
            renderLegacyKey (StandaloneConformanceService value) = "standalone " <> value
            renderLegacyKind Generated = "generated"
            renderLegacyKind HoleStub = "create-once"
        _ <- run False >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        currentContents <- TIO.readFile currentPath
        record <- maybe (expectationFailure "fresh conformance ledger did not parse" >> fail "unreachable") pure (parseConformancePackageRecord currentContents)
        let legacyRecord =
              conformanceRecordWithFiles
                [ (fileKind, if path == conformanceLedgerFileName then legacyConformanceRecordFileName else path)
                | (fileKind, path) <- record.files
                ]
                record
            legacyContents =
              T.unlines $
                [line | line <- T.lines currentContents, isGeneratedBannerLine line]
                  <> [ "schema 1",
                       "service-key " <> renderLegacyKey ((.serviceKey) legacyRecord),
                       "runtime-package " <> (.unRuntimePackageName) legacyRecord.runtimePackage,
                       "facade-module " <> (.facadeModule) legacyRecord
                     ]
                  <> ["file " <> renderLegacyKind fileKind <> " " <> T.pack path | (fileKind, path) <- (.files) legacyRecord]
        renameFile currentPath legacyPath
        TIO.writeFile legacyPath legacyContents
        migrationTreeBefore <- treeSnapshot out
        refused <- run False
        refused `shouldSatisfy` \case
          Left [SidecarMigrationRequired [move]] -> (.moveDisposition) move == ConvertLegacyConformanceLedger
          _ -> False
        treeSnapshot out `shouldReturn` migrationTreeBefore
        applied <- run True >>= either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure
        map (.moveDisposition) ((.sidecarMoves) applied) `shouldBe` [ConvertLegacyConformanceLedger]
        doesFileExist legacyPath `shouldReturn` False
        TIO.readFile backupPath `shouldReturn` legacyContents
        migrated <- TIO.readFile currentPath
        (.serviceKey) <$> parseConformancePackageRecord migrated
          `shouldBe` Just (StandaloneConformanceService ((.name) ctx))

        TIO.writeFile
          currentPath
          ( T.replace
              ("service-key standalone " <> (.name) ctx)
              "service-key standalone another-service"
              migrated
          )
        mismatchBefore <- treeSnapshot out
        mismatch <- run False
        mismatch `shouldSatisfy` \case
          Left [ConformancePackageRefusal ConformancePackageRecordMismatch {}] -> True
          _ -> False
        treeSnapshot out `shouldReturn` mismatchBefore
    it "refuses a bannerless package file before changing any runtime byte" $ do
      withTempDirectory "keiro-dsl-conformance-atomic" $ \out -> do
        parsed <- parsedSourceOf "test/fixtures/hospital-surge.keiro"
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (spec.context)
            runtimePackage = RuntimePackageName "hospital-runtime"
        modules <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planTestServiceScaffoldWithRuntimePackage (Just runtimePackage) ctx service)
        executeServiceScaffoldWithRuntimePackage (Just runtimePackage) out False "hospital-surge.keiro" ((.sourceLanguage) parsed) ctx service modules
          >>= either (\failure -> expectationFailure (show failure)) (const (pure ()))
        facade <- case [moduleValue | moduleValue <- modules, ".Conformance" `T.isSuffixOf` moduleNameOf ((.path) moduleValue)] of
          [moduleValue] -> pure moduleValue
          values -> expectationFailure ("expected one facade, got " <> show (map (.path) values)) >> fail "unreachable"
        let facadePath = out </> (.path) facade
            serviceKey = (.name) ctx
            cabalPath = out </> conformancePackageDirectory (StandaloneConformanceService serviceKey) </> T.unpack ("keiro-" <> cabaliseConformanceService serviceKey <> "-conformance.cabal")
        TIO.appendFile facadePath "-- would be overwritten if runtime execution began\n"
        TIO.writeFile cabalPath "hand-owned cabal file\n"
        packageTree <- treeSnapshot out
        refused <- executeServiceScaffoldWithRuntimePackage (Just runtimePackage) out False "hospital-surge.keiro" ((.sourceLanguage) parsed) ctx service modules
        refused `shouldSatisfy` isLeft
        treeSnapshot out `shouldReturn` packageTree
    it "keeps a two-aggregate workspace at exactly one Cabal package" $ do
      withTempDirectory "keiro-dsl-conformance-workspace" $ \out -> do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let runtimePackage = Just (RuntimePackageName "workspace-runtime")
        plan <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure (planWorkspaceScaffoldWithRuntimePackageAndGoldens [] runtimePackage "goldens" (workspaceContext workspace) workspace)
        length [() | NAggregate {} <- (.nodes) (checkedSpec (checkedWorkspace workspace))] `shouldBe` 2
        executeWorkspaceScaffold out False plan >>= either (\failure -> expectationFailure (show failure)) (const (pure ()))
        packageDirectories <- filter (T.isPrefixOf "keiro-dsl-conformance.workspace." . T.pack) <$> listDirectory out
        packageDirectories `shouldBe` ["keiro-dsl-conformance.workspace.demo-project"]
        case packageDirectories of
          [packageDirectory] -> do
            cabalFiles <- filter ((== ".cabal") . takeExtension) <$> listDirectory (out </> packageDirectory)
            length cabalFiles `shouldBe` 1
          _ -> expectationFailure "expected one package directory"
    it "scaffolds the multi-member proof idempotently through the public CLI" $ do
      withTempDirectory "keiro-dsl-conformance-proof-cli" $ \base -> do
        let fixture = "test/conformance-service-package"
            copied = base </> "fixture"
            out = copied </> "runtime/src"
            sourcePaths =
              [ "service.keiro-workspace",
                "domain/alpha.keiro",
                "domain/beta.keiro",
                "domain/evidence.keiro",
                "domain/shared.keiro"
              ]
        fixtureManifest <- resolveTestPath (fixture </> "service.keiro-workspace") >>= canonicalizePath
        let fixtureRoot = takeDirectory fixtureManifest
        forM_ sourcePaths $ \relative -> TIO.readFile (fixtureRoot </> relative) >>= writeFileWithParents (copied </> relative)
        (firstCode, firstOut, firstErr) <- runKeiroDsl ["scaffold", copied </> "service.keiro-workspace", "--out", out]
        unless (firstCode == ExitSuccess) (expectationFailure (firstOut <> firstErr))
        firstTree <- treeSnapshot out
        length [path | (path, _) <- firstTree, takeExtension path == ".cabal"] `shouldBe` 1
        length [path | (path, _) <- firstTree, "Generated/Conformance.hs" `T.isSuffixOf` T.pack path] `shouldBe` 1
        let recordPath = out </> conformancePackageDirectory (WorkspaceConformanceService "workspace-proof") </> conformanceRecordFileName
        record <- parseConformancePackageRecord <$> TIO.readFile recordPath
        (.serviceKey) <$> record `shouldBe` Just (WorkspaceConformanceService "workspace-proof")
        (secondCode, secondOut, secondErr) <- runKeiroDsl ["scaffold", copied </> "service.keiro-workspace", "--out", out]
        unless (secondCode == ExitSuccess) (expectationFailure (secondOut <> secondErr))
        secondErr `shouldSatisfy` isInfixOfString "keiro-workspace-proof-conformance.cabal (unchanged)"
        secondErr `shouldSatisfy` isInfixOfString "Expectations.hs (skipped: already present)"
        secondErr `shouldSatisfy` isInfixOfString "Generated.Conformance"
        treeSnapshot out `shouldReturn` firstTree
    it "keeps Expectations fixed and turns the generated target red for a changed workflow fact" $ do
      withTempDirectory "keiro-dsl-conformance-proof-mutation" $ \base -> do
        fixtureManifest <- resolveTestPath "test/conformance-service-package/service.keiro-workspace" >>= canonicalizePath
        let fixtureRoot = takeDirectory fixtureManifest
        let copied = base </> "fixture"
            out = copied </> "runtime/src"
            path = copied </> "domain/evidence.keiro"
            expectationsPath = out </> "keiro-dsl-conformance.workspace.workspace-proof/src/KeiroConformance/Expectations.hs"
        copyTextTree fixtureRoot copied
        acceptedExpectations <- TIO.readFile expectationsPath
        TIO.readFile path
          >>= TIO.writeFile path . T.replace "name \"workspace-proof-workflow\"" "name \"workspace-proof-workflow-v2\""
        (scaffoldCode, scaffoldOut, scaffoldErr) <- runKeiroDsl ["scaffold", copied </> "service.keiro-workspace", "--out", out]
        unless (scaffoldCode == ExitSuccess) (expectationFailure (scaffoldOut <> scaffoldErr))
        TIO.readFile expectationsPath `shouldReturn` acceptedExpectations
        let repositoryRoot = takeDirectory (takeDirectory (takeDirectory fixtureRoot))
            projectPath = base </> "mutation.project"
            buildDirectory = base </> "dist-newstyle"
            packageRoot = out </> "keiro-dsl-conformance.workspace.workspace-proof"
        TIO.writeFile
          projectPath
          ( T.unlines
              [ "packages:",
                "  " <> T.pack (repositoryRoot </> "keiro"),
                "  " <> T.pack (repositoryRoot </> "keiro-core"),
                "  " <> T.pack (copied </> "runtime"),
                "  " <> T.pack packageRoot,
                "",
                "allow-newer:",
                "  haxl:time"
              ]
          )
        (testCode, testOut, testErr) <-
          readProcessWithExitCode
            "cabal"
            [ "test",
              "--project-file=" <> projectPath,
              "--builddir=" <> buildDirectory,
              "keiro-workspace-proof-conformance"
            ]
            ""
        testCode `shouldNotBe` ExitSuccess
        (testOut <> testErr)
          `shouldSatisfy` isInfixOfString "FAIL  workflow/WorkspaceProofWorkflow/name expected=\"workspace-proof-workflow\" actual=\"workspace-proof-workflow-v2\""

  describe "new <kind> skeletons (M5)" $ do
    forM_ skeletonKinds $ \skeletonKind ->
      it ("the " <> T.unpack skeletonKind <> " skeleton selects and preserves the active authoring language") $
        assertSkeletonUsesAuthoringLanguage skeletonKind
    it "every skeleton parses and validates with zero error diagnostics" $
      mapM_ assertSkeletonValid skeletonKinds
    it "every skeleton passes the scaffold refusal gates" $
      mapM_ assertSkeletonScaffoldable skeletonKinds
    -- `derive … hole` is mandatory emit grammar. While it carried a warning, a
    -- freshly generated emit service could never satisfy the documented CI
    -- recipe, no matter what its author did. See ExecPlan 199.
    it "every skeleton without a confirmed benign inversion satisfies the documented --deny-warnings CI gate" $
      withTempDirectory "keiro-dsl-skeleton-deny" $ \out ->
        -- router and process are deliberately absent: their idiomatic
        -- on-duplicate/on-reject spellings are confirmed benign inversions
        -- (RouterBenignInversion/ProcessBenignInversion), so those services
        -- gate CI with a selective --deny list rather than --deny-warnings.
        forM_ ["emit", "intake", "aggregate", "contract", "workqueue", "workflow"] $ \kind ->
          case skeletonFor kind of
            Left err -> expectationFailure (T.unpack err)
            Right source -> do
              let specPath = out </> T.unpack kind <> ".keiro"
              TIO.writeFile specPath source
              (exitCode, stdoutText, stderrText) <-
                runKeiroDsl ["check", specPath, "--min-language", "4", "--deny-warnings"]
              unless (exitCode == ExitSuccess) $
                expectationFailure (T.unpack kind <> " skeleton failed the gate:\n" <> stdoutText <> stderrText)
              stderrText `shouldNotContain` "escalated to failure"
    it "rejects an unknown kind with a helpful message" $
      case skeletonFor "bogus" of
        Left msg -> ("Valid kinds:" `T.isInfixOf` msg) `shouldBe` True
        Right _ -> expectationFailure "expected an error for an unknown kind"

  describe "firewall self-check (M3)" $ do
    it "flags a forbidden operator in a Generated module" $ do
      let m = ScaffoldModule {path = "Gen/Foo.hs", text = "x = a ./= b", kind = Generated, origin = "test"}
      firewallBreaches [m] `shouldBe` [("Gen/Foo.hs", "./=", 1)]
    it "ignores forbidden operators in a HoleStub module (holes own them)" $ do
      let m = ScaffoldModule {path = "Foo/Holes.hs", text = "x = lit 1 .== y", kind = HoleStub, origin = "test"}
      firewallBreaches [m] `shouldBe` []
    it "matches `lit` as a word, not a substring of quality/split" $ do
      let clean = ScaffoldModule {path = "Gen/Q.hs", text = "quality = split facility", kind = Generated, origin = "test"}
          dirty = ScaffoldModule {path = "Gen/L.hs", text = "v = lit foo", kind = Generated, origin = "test"}
      firewallBreaches [clean] `shouldBe` []
      firewallBreaches [dirty] `shouldBe` [("Gen/L.hs", "lit", 1)]
    it "skips strings and comments and maximal-munches symbolic tokens" $ do
      let clean = syntheticGenerated "Gen/Clean.hs" "wire = \"lit .== B.slot\"\n-- x =: y\nx = a .<= b"
          dirty = syntheticGenerated "Gen/Dirty.hs" "x = a .< b\ny = c =: d"
      firewallBreaches [clean] `shouldBe` [("Gen/Clean.hs", ".<=", 3)]
      firewallBreaches [dirty] `shouldBe` [("Gen/Dirty.hs", ".<", 1), ("Gen/Dirty.hs", "=:", 2)]
    it "guards keiki imports while allowing the generated Core allowlist" $ do
      let forbidden = syntheticGenerated "Gen/Builder.hs" "import Keiki.Builder"
          restricted = syntheticGenerated "Gen/CoreBad.hs" "import Keiki.Core (lit)"
          allowed = syntheticGenerated "Gen/CoreGood.hs" "import Keiki.Core (RegFile (..), HsPred, step)"
      firewallBreaches [forbidden] `shouldBe` [("Gen/Builder.hs", "import:Keiki.Builder", 1)]
      firewallBreaches [restricted] `shouldBe` [("Gen/CoreBad.hs", "import:Keiki.Core", 1)]
      firewallBreaches [allowed] `shouldBe` []
    it "exempts only the authoritative generated transducer module path" $ do
      let expressions = syntheticGenerated "Gen/Aggregate/Expressions.hs" "import Keiki.Core qualified as K\nx = K.lit 1"
          transducer = syntheticGenerated "Gen/Aggregate/Transducer.hs" "import Keiki.Builder qualified as B\nx = B.slot"
          ordinary = syntheticGenerated "Gen/Aggregate/Projection.hs" "import Keiki.Builder qualified as B"
      firewallBreaches [expressions, transducer]
        `shouldBe` [("Gen/Aggregate/Expressions.hs", "import:Keiki.Core", 1)]
      firewallBreaches [ordinary] `shouldBe` [("Gen/Aggregate/Projection.hs", "import:Keiki.Builder", 1)]
    it "finds no breach in real scaffolder output (aggregate + process fixtures)" $ do
      aggMods <- scaffoldFixture "test/fixtures/reservation.keiro"
      procMods <- legacyScaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
      firewallBreaches (aggMods <> procMods) `shouldBe` []

  describe "generated provenance banners (plan 182 M4)" $ do
    it "stamps the running package version, effective language, and module origin" $ do
      service <- checkedServiceOf "test/fixtures/contract-v4.keiro"
      let ctx = defaultContext ((checkedSpec service).context)
      case planTestServiceScaffold ctx service of
        Left refusals -> expectationFailure (show refusals)
        Right modules -> do
          let generated = [moduleValue | moduleValue <- modules, (.kind) moduleValue == Generated]
          generated `shouldSatisfy` (not . null)
          forM_ generated $ \moduleValue -> do
            let recognized = filter isGeneratedBannerLine (T.lines ((.text) moduleValue))
                expected = generatedBannerFor (checkedLanguageContract service) ((.origin) moduleValue)
            recognized `shouldBe` [expected]
            expected
              `shouldSatisfy` T.isInfixOf
                ( "keiro-dsl "
                    <> T.pack (showVersion Package.version)
                    <> " (language keiro-dsl 4) from contract emergency"
                )
      workspace <- shouldComposeWorkspace canonicalWorkspacePath
      workspacePlan <- shouldPlanWorkspaceSpec workspace
      forM_ [moduleValue | (moduleValue, _) <- (.modules) workspacePlan, (.kind) moduleValue == Generated] $ \moduleValue ->
        filter isGeneratedBannerLine (T.lines ((.text) moduleValue))
          `shouldBe` [generatedBannerFor (checkedLanguageContract (checkedWorkspace workspace)) ((.origin) moduleValue)]
    it "recognizes only the historical banner and the stamped format" $ do
      let contract = effectiveLanguageContract LegacyUnversioned
      isGeneratedBannerLine generatedBanner `shouldBe` True
      isGeneratedBannerLine (generatedBannerFor contract "aggregate Counter (line 2)") `shouldBe` True
      isGeneratedBannerLine "-- @generated by another tool" `shouldBe` False
      isGeneratedBannerLine codecComparisonBanner `shouldBe` False
    it "migrates a legacy-banner file and keeps repeated scaffold bytes stable" $
      withTempDirectory "keiro-dsl-stamped-banner" $ \out -> do
        spec <- parseInlineSpec "<stamped-banner>" loweringAggregateSpec
        let ctx = defaultContext (spec.context)
        modules <- case planTestScaffold ctx spec of
          Left refusals -> expectationFailure (show refusals) >> pure []
          Right planned -> pure planned
        case [moduleValue | moduleValue <- modules, (.kind) moduleValue == Generated] of
          target : _ -> do
            let path = out </> target.path
                stamped = generatedBannerFor (effectiveLanguageContract LegacyUnversioned) ((.origin) target)
                legacyText = T.replace stamped generatedBanner ((.text) target)
            createDirectoryIfMissing True (takeDirectory path)
            TIO.writeFile path legacyText
            first <- executeScaffold out False "counter.keiro" ctx spec modules
            first `shouldSatisfy` isSuccessfulScaffold
            firstTree <- treeSnapshot out
            second <- executeScaffold out False "counter.keiro" ctx spec modules
            second `shouldSatisfy` isSuccessfulScaffold
            treeSnapshot out `shouldReturn` firstTree
            TIO.readFile path `shouldReturn` (.text) target
          [] -> expectationFailure "counter scaffold has no Generated module"

  describe "service-aware fixture helpers" $ do
    it "retains version-4 contract TypeIDs and their durable admission identities" $ do
      service <- checkedServiceOf "test/fixtures/contract-v4.keiro"
      modules <- scaffoldFixture "test/fixtures/contract-v4.keiro"
      let contractModule = generatedTextEndingIn "Contract.hs" modules
          identities = idDomainIdentitiesForService service
      contractModule `shouldSatisfy` T.isInfixOf "incidentId :: !(KindID \"inc\")"
      contractModule `shouldSatisfy` T.isInfixOf "reservationId :: !(KindID \"rsv\")"
      identities
        `shouldContain` ["id-domain|name=contract:emergency.IncidentTransferNeedDeclared.incidentId|contract=keiro-dsl/id-domain/typeid-v7/1|prefix=inc|separator=_|json=canonical-json-text"]

  describe "scaffold gates" $ do
    it "reports case-folded generated paths through the complete check diagnostics" $ do
      spec <- specOf "test/fixtures/reservation.keiro"
      case [aggregate | NAggregate aggregate <- (.nodes) spec] of
        aggregate : _ -> do
          let caseVariant =
                specWithNodes
                  [ NAggregate aggregate,
                    NAggregate (aggregateWithName (T.toUpper aggregate.name) aggregate)
                  ]
                  spec
              diagnostics =
                checkTestServiceDiagnostics
                  Nothing
                  (defaultContext (caseVariant.context))
                  (legacyCheckedService caseVariant)
          map (.code) diagnostics `shouldContain` [GeneratedPathCollision]
          case [ diagnostic
               | diagnostic <- diagnostics,
                 (.code) diagnostic == GeneratedPathCollision,
                 "Domain.hs" `T.isInfixOf` (.message) diagnostic
               ] of
            [diagnostic] -> do
              (.line) diagnostic `shouldBe` unLoc ((.loc) aggregate)
              (.relatedLocations) diagnostic `shouldSatisfy` (not . null)
              (.message) diagnostic `shouldSatisfy` T.isInfixOf "case-insensitive filesystem"
            found -> expectationFailure ("expected one generated-path diagnostic, got " <> show found)
          withTempDirectory "keiro-dsl-check-path-collision" $ \root -> do
            let sourcePath = root </> "collision.keiro"
            version <- maybe (expectationFailure "language version 4 missing" >> fail "unreachable") pure (languageVersion 4)
            TIO.writeFile sourcePath (renderSource (ParsedSource (DeclaredLanguage version noLoc) caseVariant))
            (exitCode, out, err) <- runKeiroDsl ["check", sourcePath]
            exitCode `shouldBe` ExitFailure 1
            out `shouldBe` ""
            err `shouldContain` "error[GeneratedPathCollision]"
        [] -> expectationFailure "reservation fixture has no aggregate"
    it "uses lowering before module planning in both scaffold planners" $ do
      spec <- specOf "test/fixtures/emit.keiro"
      case [contract | NContract contract <- (.nodes) spec] of
        contract : _ -> do
          let defective =
                mapPublisher
                  (publisherWithBackoff (BackoffSpec "exponential" "2s" Nothing Nothing))
                  (specWithNodes (NContract contract : spec.nodes) spec)
              ctx = defaultContext (defective.context)
              workspace = oneMemberWorkspace "emit.keiro" defective
          case (planTestScaffold ctx defective, planWorkspaceScaffold "goldens" ctx workspace) of
            (Left (LoweringRefusal singleReasons : _), Left (LoweringRefusal workspaceReasons : _)) ->
              workspaceReasons `shouldBe` singleReasons
            results -> expectationFailure ("expected lowering first from both planners, got " <> show results)
        [] -> expectationFailure "emit fixture has no contract"
    it "maps import cycles and planner invariants into stable check codes" $ do
      planningRefusalDiagnostics [ImportCycle ["A", "B", "A"]]
        `shouldSatisfy` any ((== GeneratedImportCycle) . (.code))
      planningRefusalDiagnostics [BehaviorRefusal [Behavior.DuplicateBehaviorIdentity "duplicate" [Loc 9]]]
        `shouldSatisfy` any (\diagnostic -> (.code) diagnostic == BehaviorDerivationInvalid && (.line) diagnostic == 9)
      planningRefusalDiagnostics [DuplicateConformanceFactKeys [DuplicateServiceFactKey "duplicate"]]
        `shouldSatisfy` any ((== ConformanceFactKeyCollision) . (.code))
      planningRefusalDiagnostics [SemanticContractMismatch "test mismatch"]
        `shouldSatisfy` any ((== GeneratedPlanningInvariantViolation) . (.code))
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let cyclic = spec {mapped = map moveArtifactBindingIntoGenerated ((.mapped) spec)}
      checkTestServiceDiagnostics Nothing (defaultContext (cyclic.context)) (stableCheckedService cyclic)
        `shouldSatisfy` any ((== GeneratedImportCycle) . (.code))
    it "refuses duplicate and case-folded module paths with both origins" $ do
      spec <- specOf "test/fixtures/reservation.keiro"
      case [aggregate | NAggregate aggregate <- (.nodes) spec] of
        aggregate : _ -> do
          let duplicate = specWithNodes [NAggregate aggregate, NAggregate aggregate] spec
              caseVariant = specWithNodes [NAggregate aggregate, NAggregate (aggregateWithName (T.toUpper aggregate.name) aggregate)] spec
          planTestScaffold (defaultContext (spec.context)) duplicate `shouldSatisfy` hasPathCollisionWithTwoOrigins
          planTestScaffold (defaultContext (spec.context)) caseVariant `shouldSatisfy` hasPathCollisionWithTwoOrigins
        [] -> expectationFailure "reservation fixture has no aggregate"
    it "refuses a bannerless Generated target without changing its bytes" $
      withTempDirectory "keiro-dsl-banner" $ \out -> do
        spec <- specOf "test/fixtures/reservation.keiro"
        let ctx = defaultContext (spec.context)
        case planTestScaffold ctx spec of
          Left refusals -> expectationFailure ("unexpected planning refusal: " <> show refusals)
          Right modules -> case [m | m <- modules, (.kind) m == Generated] of
            generated : _ -> do
              let target = out </> (.path) generated
              createDirectoryIfMissing True (takeDirectory target)
              TIO.writeFile target "hand owned\n"
              result <- executeScaffold out False "test/fixtures/reservation.keiro" ctx spec modules
              result `shouldSatisfy` isMissingBannerRefusal
              TIO.readFile target `shouldReturn` "hand owned\n"
              forced <- executeScaffold out True "test/fixtures/reservation.keiro" ctx spec modules
              forced `shouldSatisfy` isSuccessfulScaffold
              TIO.readFile target `shouldReturn` (.text) generated
            [] -> expectationFailure "reservation scaffold has no Generated module"
    it "reports renamed-node modules as stale without deleting them" $
      withTempDirectory "keiro-dsl-stale-rename" $ \out -> do
        spec <- parseInlineSpec "<stale-rename>" loweringAggregateSpec
        first <- executePlannedScaffold out "counter.keiro" (defaultContext (spec.context)) spec
        let renamed = specWithNodes (map renameCounter spec.nodes) spec
        second <- executePlannedScaffold out "counter.keiro" (defaultContext (renamed.context)) renamed
        let oldDomain = onlyPathEndingIn "Counter/Domain.hs" (map fst ((.dispositions) first))
            oldHoles = onlyPathEndingIn "Counter/Holes.hs" (map fst ((.dispositions) first))
        (.stale) second `shouldSatisfy` \stale ->
          StaleModule Generated oldDomain (Just ExactGeneratedBannerPresent) `elem` stale
            && StaleModule HoleStub oldHoles Nothing `elem` stale
        doesFileExist (out </> oldDomain) `shouldReturn` True
        doesFileExist (out </> oldHoles) `shouldReturn` True
        renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "exact generated banner present; verify unchanged bytes before deleting")
        renderScaffoldReport second `shouldSatisfy` all (not . T.isInfixOf "safe to delete")
    it "preserves a stale generated path whose exact banner is missing" $
      withTempDirectory "keiro-dsl-stale-banner" $ \out -> do
        spec <- parseInlineSpec "<stale-banner>" loweringAggregateSpec
        first <- executePlannedScaffold out "counter.keiro" (defaultContext (spec.context)) spec
        let oldDomain = onlyPathEndingIn "Counter/Domain.hs" (map fst ((.dispositions) first))
            renamed = specWithNodes (map renameCounter spec.nodes) spec
        TIO.writeFile (out </> oldDomain) "-- generated by something else\n"
        second <- executePlannedScaffold out "counter.keiro" (defaultContext (renamed.context)) renamed
        (.stale) second `shouldSatisfy` elem (StaleModule Generated oldDomain (Just ExactGeneratedBannerMissing))
        renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "exact generated banner missing; preserve and review")
        TIO.readFile (out </> oldDomain) `shouldReturn` "-- generated by something else\n"
    it "reports the entire old tree across a module-root flip" $
      withTempDirectory "keiro-dsl-stale-root" $ \out -> do
        spec <- parseInlineSpec "<stale-root>" loweringAggregateSpec
        let initialCtx = defaultContext (spec.context)
            rootedCtx = contextWithModuleRoot "Acme" initialCtx
        first <- executePlannedScaffold out "counter.keiro" initialCtx spec
        second <- executePlannedScaffold out "moved-counter.keiro" rootedCtx spec
        (.stale) second
          `shouldMatchList` [ StaleModule ((.kind) m) ((.path) m) (if (.kind) m == Generated then Just ExactGeneratedBannerPresent else Nothing)
                            | (m, _) <- (.dispositions) first
                            ]
        forM_ ((.stale) second) $ \stale -> doesFileExist (out </> (.path) stale) `shouldReturn` True
        renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "previous scaffold record used spec counter.keiro")
    it "reports moved generated modules across a layout flip" $
      withTempDirectory "keiro-dsl-stale-layout" $ \out -> do
        spec <- parseInlineSpec "<stale-layout>" loweringAggregateSpec
        let initialCtx = defaultContext (spec.context)
            collocatedCtx = initialCtx {placement = CollocatedLeaf}
        first <- executePlannedScaffold out "counter.keiro" initialCtx spec
        second <- executePlannedScaffold out "counter.keiro" collocatedCtx spec
        let oldGenerated = [StaleModule Generated ((.path) m) (Just ExactGeneratedBannerPresent) | (m, _) <- (.dispositions) first, (.kind) m == Generated]
        (.stale) second `shouldSatisfy` all (`elem` oldGenerated)
        length ((.stale) second) `shouldBe` length oldGenerated
    it "writes a parseable record and no stale section for a fresh output" $
      withTempDirectory "keiro-dsl-record" $ \out -> do
        spec <- parseInlineSpec "<fresh-record>" loweringAggregateSpec
        let ctx = defaultContext (spec.context)
        report <- executePlannedScaffold out "counter.keiro" ctx spec
        (.stale) report `shouldBe` []
        renderScaffoldReport report `shouldSatisfy` all (not . T.isPrefixOf "stale:")
        contents <- TIO.readFile (out </> recordFileName (spec.context))
        requirements <- either (\errors -> expectationFailure (show errors) >> pure []) pure (Behavior.deriveBehaviorRequirements spec)
        let expected =
              ScaffoldRecord
                { specPath = "counter.keiro",
                  moduleRoot = "",
                  layout = "prefixed",
                  sourceLanguage = LegacyUnversioned,
                  languageContract = effectiveLanguageContract LegacyUnversioned,
                  namingEdition = IdiomaticNamingV2,
                  moduleRoles = [ScaffoldModuleRoleRow (moduleRole m) ((.kind) m) ((.path) m) | (m, _) <- (.dispositions) report],
                  files = [((.kind) m, (.path) m) | (m, _) <- (.dispositions) report],
                  mappings = [],
                  idDomains = [],
                  nominalEqualities = [],
                  bindingObligations = [],
                  behaviorRequirements = Behavior.behaviorRecordRows requirements,
                  projectionCatalogFacts = [],
                  queryContractBaseline = False,
                  queryContracts = either (const []) id (queryContractIdentities spec),
                  routerSelections = [],
                  semanticImpact = Just (semanticImpactSnapshotForSpec spec)
                }
            sourceRows = filter ("source-language " `T.isPrefixOf`) (T.lines contents)
            withoutSourceRows = T.unlines (filter (not . T.isPrefixOf "source-language ") (T.lines contents))
            semanticRows = filter ("semantic-contract " `T.isPrefixOf`) (T.lines contents)
            withoutSemanticRows = T.unlines (filter (not . T.isPrefixOf "semantic-contract ") (T.lines contents))
        parseRecord contents `shouldBe` Just expected
        contents `shouldNotSatisfy` T.isInfixOf "query-contract-baseline"
        parseRecord withoutSourceRows `shouldBe` Just expected
        parseRecord withoutSemanticRows `shouldBe` Just expected
        case sourceRows of
          [sourceRow] -> do
            parseRecord (T.replace sourceRow (sourceRow <> "\n" <> sourceRow) contents) `shouldBe` Nothing
            parseRecord (T.replace sourceRow "source-language {malformed}" contents) `shouldBe` Nothing
          _ -> expectationFailure "expected exactly one source-language row"
        case semanticRows of
          [semanticRow] -> do
            parseRecord (T.replace semanticRow (semanticRow <> "\n" <> semanticRow) contents) `shouldBe` Nothing
            parseRecord (T.replace semanticRow "semantic-contract {malformed}" contents) `shouldBe` Nothing
            parseRecord (T.replace "\"languageVersion\":1" "\"languageVersion\":2" contents) `shouldBe` Nothing
          _ -> expectationFailure "expected exactly one semantic-contract row"
        parseRecord (T.replace "spec: " "future-field: retained\nspec: " contents) `shouldBe` parseRecord contents
        parseRecord (T.replace "record v1" "record v2" contents) `shouldBe` Nothing
    it "records declared provenance and reports a header-only scaffold drift" $
      withTempDirectory "keiro-dsl-language-drift" $ \out -> do
        spec <- parseInlineSpec "<language-drift>" loweringAggregateSpec
        let ctx = defaultContext (spec.context)
        modules <- case planTestScaffold ctx spec of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right planned -> pure planned
        _ <- executePlannedScaffold out "counter.keiro" ctx spec
        case languageVersion 1 of
          Nothing -> expectationFailure "version 1 was not constructible"
          Just version -> do
            let declared = DeclaredLanguage version noLoc
            result <- executeScaffoldWithLanguage out False "counter.keiro" declared ctx spec modules
            case result of
              Left refusals -> expectationFailure (show refusals)
              Right report -> do
                (.sourceLanguageDrift) report
                  `shouldBe` Just (SourceLanguageDrift LegacyUnversioned declared)
                contents <- TIO.readFile ((.recordPath) report)
                (.sourceLanguage) <$> parseRecord contents `shouldBe` Just declared

  describe "faithful scaffold lowering" $ do
    it "escapes a trailing-backslash payload literal exactly once" $ do
      spec <- specOf "test/fixtures/hospital-surge.keiro"
      case [process | NProcess process <- (.nodes) spec] of
        process : _ -> do
          let timer = timerNodeWithPayload [FieldBinding "kind" (Just "\"follow-up\\\"")] process.timer
              modules = scaffoldProcess (defaultContext (spec.context)) process {timer = timer}
          generatedTextEndingIn "Process.hs" modules
            `shouldSatisfy` T.isInfixOf "\"kind\" .= (\"follow-up\\\\\" :: Value)"
        [] -> expectationFailure "hospital-surge fixture has no process"
    it "preserves quoted Text register initials and refuses unsafe register shapes" $ do
      spec <- parseInlineSpec "<register-initials>" loweringAggregateSpec
      let modules = scaffoldAggregate (defaultContext (spec.context)) spec =<< [aggregate | NAggregate aggregate <- (.nodes) spec]
          domain = generatedTextEndingIn "Domain.hs" modules
      domain `shouldSatisfy` T.isInfixOf "RCons (Proxy @\"note\") \"hello world\""
      scaffoldRefusals spec `shouldBe` []
      bare <- parseInlineSpec "<bare-text-initial>" (T.replace "\"hello world\"" "hello" loweringAggregateSpec)
      scaffoldRefusals bare `shouldSatisfy` any (T.isInfixOf "RegTextInitialNotQuoted")
      unsupported <- parseInlineSpec "<unsupported-field>" (T.replace "count:Int" "count:Json" loweringAggregateSpec)
      scaffoldRefusals unsupported `shouldSatisfy` any (T.isInfixOf "FieldTypeUnrepresentable")
    it "lowers seconds, minutes, hours, and both backoff constructors faithfully" $ do
      windowSeconds "90s" `shouldBe` Right 90
      windowSeconds "5m" `shouldBe` Right 300
      windowSeconds "2h" `shouldBe` Right 7200
      emitSource <- readTestText "test/fixtures/emit.keiro"
      let exponentialSource = T.replace "backoff constant 2s" "backoff exponential 2s max=60s multiplier=2.0" emitSource
      exponential <- parseInlineSpec "<exponential-backoff>" exponentialSource
      case [publisher | NPublisher publisher <- (.nodes) exponential] of
        publisher : _ -> do
          let generated = generatedTextEndingIn "Publisher.hs" (scaffoldPublisher (defaultContext (exponential.context)) publisher)
          generated `shouldSatisfy` T.isInfixOf "ExponentialBackoff ExponentialBackoffOptions { initial = 2, maxDelay = 60, multiplier = 2.0 }"
          parseSpec "<exponential-round-trip>" (renderSpec exponential) `shouldBe` Right exponential
        [] -> expectationFailure "emit fixture has no publisher"
      constant <- parseInlineSpec "<constant-backoff>" (T.replace "backoff constant 2s" "backoff constant 2m" emitSource)
      case [publisher | NPublisher publisher <- (.nodes) constant] of
        publisher : _ -> generatedTextEndingIn "Publisher.hs" (scaffoldPublisher (defaultContext (constant.context)) publisher) `shouldSatisfy` T.isInfixOf "ConstantBackoff 120"
        [] -> expectationFailure "emit fixture has no publisher"
    it "refuses incomplete exponential backoff and rejects unknown window units" $ do
      emitSource <- readTestText "test/fixtures/emit.keiro"
      incomplete <- parseInlineSpec "<incomplete-backoff>" (T.replace "backoff constant 2s" "backoff exponential 2s" emitSource)
      scaffoldRefusals incomplete `shouldSatisfy` any (T.isInfixOf "BackoffExponentialIncomplete")
      parseSpec "<bad-window>" (T.replace "backoff constant 2s" "backoff constant 2x" emitSource)
        `shouldSatisfy` leftContains "time unit: s, m, or h"
    it "lowers workqueue retry windows in minutes to seconds" $ do
      queueSource <- readTestText "test/fixtures/reservation-work.keiro"
      queueSpec <- parseInlineSpec "<minute-queue>" (T.replace "5s" "5m" queueSource)
      case [workqueue | NWorkqueue workqueue <- (.nodes) queueSpec] of
        workqueue : _ -> do
          let policy = generatedTextEndingIn "QueuePolicy.hs" (scaffoldWorkqueue (defaultContext (queueSpec.context)) workqueue)
          policy `shouldSatisfy` T.isInfixOf "defaultRetryDelay = RetryDelay 300"
          policy `shouldSatisfy` T.isInfixOf "Retry (RetryDelay 300)"
        [] -> expectationFailure "queue fixture has no workqueue"
    it "uses exact status-map keys and emits total Int harness samples" $ do
      statusSpec <- parseInlineSpec "<exact-status>" exactStatusSpec
      case [aggregate | NAggregate aggregate <- (.nodes) statusSpec] of
        aggregate : _ -> do
          let ctx = defaultContext (statusSpec.context)
              projection = generatedTextEndingIn "Projection.hs" (scaffoldAggregate ctx statusSpec aggregate)
              harness = generatedTextEndingIn "Harness.hs" (harnessFor ctx statusSpec aggregate)
          projection `shouldSatisfy` T.isInfixOf "ReservationUnHeld {} -> Just \"available\""
          harness `shouldSatisfy` T.isInfixOf "CountBumpedData 0"
          harness `shouldNotSatisfy` T.isInfixOf "sample: unsupported"
        [] -> expectationFailure "exact-status spec has no aggregate"

  describe "scaffold" $ do
    it "keeps field DSL names, generated selectors, and wire keys independent" $ do
      source <- readTestText "test/fixtures/aggregate-field-alias.keiro"
      document <- case parseSourceDocument "aggregate-field-alias.keiro" source of
        Left failure -> expectationFailure (show failure) >> fail "unreachable"
        Right value -> pure value
      let ParsedSourceDocument {parsedSource = parsedSource, sourceIndex = sourceIndex} = document
          service = checkedSource parsedSource
          spec = checkedSpec service
          ctx = defaultContext (spec.context)
          modules = scaffoldServiceModules ctx service
          domain = generatedTextEndingIn "Domain.hs" modules
          codec = generatedTextEndingIn "Codec.hs" modules
      workspace <-
        either
          (\failure -> expectationFailure (show failure) >> fail "unreachable")
          pure
          (oneMemberParsedDocumentWorkspace "aggregate-field-alias.keiro" document)
      validateService service `shouldBe` []
      domain `shouldSatisfy` ((== 2) . T.count "payloadType :: !Text")
      domain `shouldSatisfy` ((== 2) . T.count "serviceRegion :: !Text")
      domain `shouldSatisfy` ((== 2) . T.count "family :: !Text")
      codec `shouldSatisfy` T.isInfixOf "\"type\" .= payload.payloadType"
      codec `shouldSatisfy` T.isInfixOf "\"region_code\" .= payload.serviceRegion"
      codec `shouldSatisfy` T.isInfixOf "o .: \"region_code\""
      scaffoldServiceModules ctx service `shouldBe` modules
      fmap (map fst . (.modules)) (planWorkspaceScaffold "goldens" ctx workspace)
        `shouldBe` planIndexedServiceScaffold sourceIndex ctx service

      newSpec <- parseInlineSpec "aggregate-field-alias-v2.keiro" (T.replace "event FieldsCopied =" "event FieldsCopied v2 =" source)
      case goldensForDiff spec newSpec of
        [golden] -> do
          (.json) golden `shouldSatisfy` T.isInfixOf "\"family\":\"sample\""
          (.json) golden `shouldSatisfy` T.isInfixOf "\"type\":\"sample\""
          (.json) golden `shouldSatisfy` T.isInfixOf "\"region_code\":\"sample\""
          (.json) golden `shouldSatisfy` (not . T.isInfixOf "payloadType")
          (.json) golden `shouldSatisfy` (not . T.isInfixOf "serviceRegion")
        goldens -> expectationFailure ("expected one field-alias golden, got " <> show goldens)

    it "keeps aggregate fold identity neutral across field aliases" $ do
      let sourceFor field =
            T.unlines
              [ "language keiro-dsl 4",
                "context field-alias-neutrality",
                "aggregate AliasNeutrality",
                "  regs",
                "  states Open",
                "  command Observe { " <> field <> " }",
                "  event Observed = fields(Observe)",
                "  wire kind=ctorName fields=camelCase schemaVersion=1"
              ]
      base <- checkedServiceFromText "field-alias-base.keiro" (sourceFor "region:Text")
      selectorAlias <- checkedServiceFromText "field-alias-selector.keiro" (sourceFor "region haskell serviceRegion:Text")
      wireAlias <- checkedServiceFromText "field-alias-wire.keiro" (sourceFor "region as \"region_code\":Text")
      let fingerprint service = aggregateFoldFingerprintForService service (onlyAggregate (checkedSpec service))
          codecFor service =
            generatedTextEndingIn
              "Codec.hs"
              (scaffoldServiceModules (defaultContext ((checkedSpec service).context)) service)
      fingerprint selectorAlias `shouldBe` fingerprint base
      fingerprint wireAlias `shouldBe` fingerprint base
      codecFor base `shouldSatisfy` T.isInfixOf "\"region\" .= payload.region"
      codecFor selectorAlias `shouldSatisfy` T.isInfixOf "\"region\" .= payload.serviceRegion"
      codecFor selectorAlias `shouldSatisfy` (not . T.isInfixOf "region_code")
      codecFor wireAlias `shouldSatisfy` T.isInfixOf "\"region_code\" .= payload.region"

    it "synthesizes the exact old wire shape and embeds it in the harness" $ do
      oldSpec <- specOf "test/fixtures/reservation.keiro"
      newSpec <- specOf "test/fixtures/reservation-v2.keiro"
      case goldensForDiff oldSpec newSpec of
        [golden] -> do
          goldenRelativePath golden
            `shouldBe` "hospital-capacity/Reservation/TransferReservationCreated.v1.json"
          (.json) golden
            `shouldBe` "{\"commandId\":\"cmd_01hzy3v7q2e8kaw2m5x0d41n9c\",\"divertStatus\":\"open\",\"hospitalId\":\"hosp_01hzy3v7q2e8kaw2m5x0d41n9c\",\"kind\":\"TransferReservationCreated\",\"lifeCriticalOverride\":true,\"patientAcuity\":\"red\",\"reservationId\":\"rsv_01hzy3v7q2e8kaw2m5x0d41n9c\"}\n"
          (.evidence) golden `shouldBe` SynthesizedWeakStandIn
          let aggregate = onlyAggregate newSpec
              modules =
                harnessForWithGoldens
                  [golden]
                  (defaultContext (newSpec.context))
                  newSpec
                  aggregate
              harness = generatedTextEndingIn "Harness.hs" modules
          harness `shouldSatisfy` T.isInfixOf "golden TransferReservationCreated.v1 decodes"
          harness `shouldSatisfy` T.isInfixOf "\\\"reservationId\\\":\\\"rsv_"
          harness `shouldSatisfy` (not . T.isInfixOf "current-shape stand-in")
        goldens -> expectationFailure ("expected one synthesized golden, got " <> show goldens)
    it "synthesizes complete nested mapped old shapes deterministically and never overwrites captured evidence" $ do
      oldSpec <- specOf "test/fixtures/consumer-types.keiro"
      newSpec <- specOf "test/fixtures/consumer-types-v2.keiro"
      case goldensForDiff oldSpec newSpec of
        [golden] -> do
          (.evidence) golden `shouldBe` SynthesizedWeakStandIn
          (.json) golden `shouldSatisfy` T.isInfixOf "\"artifact\":{"
          (.json) golden `shouldSatisfy` T.isInfixOf "\"location\":{\"contents\":\"sample\",\"tag\":\"local_file\"}"
          (.json) golden `shouldSatisfy` T.isInfixOf "\"labels\":[\"sample\"]"
          (.json) golden `shouldSatisfy` T.isInfixOf "\"revision\":1"
          (.json) golden `shouldSatisfy` T.isInfixOf "\"observedAt\":\"2026-01-01T00:00:00Z\""
          goldensForDiff oldSpec newSpec `shouldBe` [golden]
          withTempDirectory "keiro-golden-preserve" $ \root -> do
            let target = root </> goldenRelativePath golden
            createDirectoryIfMissing True (takeDirectory target)
            TIO.writeFile target "hand captured\n"
            emitGoldenPayloads root oldSpec newSpec `shouldReturn` []
            TIO.readFile target `shouldReturn` "hand captured\n"
          withTempDirectory "keiro-golden-write" $ \root -> do
            let target = root </> goldenRelativePath golden
            emitGoldenPayloads root oldSpec newSpec `shouldReturn` [target]
            TIO.readFile target `shouldReturn` (.json) golden
        goldens -> expectationFailure ("expected one nested synthesized golden, got " <> show goldens)
    it "dispatches shared-version upcasters by wire event type and passes foreign kinds through" $ do
      parsed <- parsedSourceOf "test/fixtures/reservation-dup-upcast-source.keiro"
      let spec = parsed.spec
      case [aggregate | NAggregate aggregate <- (.nodes) spec] of
        [_] -> do
          let modules = scaffoldServiceModules (defaultContext (spec.context)) (checkedSource parsed)
              codec = generatedTextEndingIn "Codec.hs" modules
              holes = case [(.text) m | m <- modules, "/Holes.hs" `T.isSuffixOf` T.pack ((.path) m)] of
                [text] -> text
                _ -> ""
          codec `shouldSatisfy` T.isInfixOf "upcasters = [(1, upcastRungV1)]"
          codec `shouldSatisfy` T.isInfixOf "upcastRungV1 (EventType \"TransferReservationCreated\") value = upcastTransferReservationCreatedV1 value"
          codec `shouldSatisfy` T.isInfixOf "upcastRungV1 (EventType \"TransferReservationConfirmed\") value = upcastTransferReservationConfirmedV1 value"
          codec `shouldSatisfy` T.isInfixOf "upcastRungV1 _ value = Right value"
          holes `shouldSatisfy` T.isInfixOf "receives ONLY TransferReservationCreated payloads"
        _ -> expectationFailure "expected exactly one aggregate"
    it "keeps foreign payloads byte-for-byte and invokes both same-rung event upcasters" $ do
      let payloadA = object ["kind" .= ("AmountScaled" :: T.Text), "amount" .= (2 :: Int)]
          payloadB = object ["kind" .= ("AmountRenamed" :: T.Text), "amount" .= (3 :: Int)]
          foreignPayload = object ["kind" .= ("AmountObserved" :: T.Text), "amount" .= (7 :: Int)]
          upcastA _ = Right (object ["kind" .= ("AmountScaled" :: T.Text), "amount" .= (200 :: Int)])
          upcastB _ = Right (object ["kind" .= ("AmountRenamed" :: T.Text), "amountInCents" .= (300 :: Int)])
          rung (EventType "AmountScaled") = upcastA
          rung (EventType "AmountRenamed") = upcastB
          rung _ = Right
          codec =
            Codec
              { eventTypes = EventType "AmountScaled" :| [EventType "AmountRenamed", EventType "AmountObserved"],
                eventType = const (EventType "AmountObserved"),
                schemaVersion = 2,
                encode = id,
                decode = \_ -> Right,
                upcasters = [(1, rung)]
              } ::
              Codec Value
      decodeRaw codec (EventType "AmountObserved") 1 foreignPayload `shouldBe` Right foreignPayload
      decodeRaw codec (EventType "AmountScaled") 1 payloadA
        `shouldBe` Right (object ["kind" .= ("AmountScaled" :: T.Text), "amount" .= (200 :: Int)])
      decodeRaw codec (EventType "AmountRenamed") 1 payloadB
        `shouldBe` Right (object ["kind" .= ("AmountRenamed" :: T.Text), "amountInCents" .= (300 :: Int)])
    it "never emits a keiki symbolic operator into a Generated module (firewall)" $ do
      mods <- scaffoldFixture "test/fixtures/reservation.keiro"
      firewallBreaches mods `shouldBe` []
    it "marks the Holes module HoleStub and the rest Generated" $ do
      mods <- scaffoldFixture "test/fixtures/reservation.keiro"
      let holes = [m | m <- mods, (.kind) m == HoleStub]
      map (takeFileName . (.path)) holes `shouldBe` ["BehaviorHoles.hs", "Holes.hs"]
      -- Context nominals/internal/replay plus the stable aggregate surface.
      length [m | m <- mods, (.kind) m == Generated] `shouldBe` 10
    it "is deterministic (re-scaffolding yields byte-identical text)" $ do
      a <- scaffoldFixture "test/fixtures/reservation.keiro"
      b <- scaffoldFixture "test/fixtures/reservation.keiro"
      map (.text) a `shouldBe` map (.text) b
    it "keeps retiring as validator-only metadata in generated modules" $ do
      ordinary <- scaffoldFixture "test/fixtures/reservation.keiro"
      retiring <- scaffoldFixture "test/fixtures/reservation-retiring.keiro"
      map (\m -> ((.path) m, (.kind) m, (.text) m)) retiring
        `shouldBe` map (\m -> ((.path) m, (.kind) m, (.text) m)) ordinary
    it "matches the committed compiling Generated conformance modules (modulo whitespace)" $ do
      mods <- scaffoldFixture "test/fixtures/reservation.keiro"
      mapM_ assertMatchesCommitted [m | m <- mods, (.kind) m == Generated]
    it "matches every committed new-surface Generated module (modulo formatting)" $ do
      modules <- scaffoldFixture "test/fixtures/transfer-routing.keiro"
      forM_ [m | m <- modules, (.kind) m == Generated] $ \m -> do
        committed <- readTestText ("test/conformance-newsurface/" <> (.path) m)
        normalizeGenerated committed `shouldBe` normalizeGenerated ((.text) m)
    it "scaffolds the register-free OrderStream smoke target without error" $ do
      mods <- scaffoldFixture "test/fixtures/order.keiro"
      -- Stable and.aggregate.modules.context plus both hand-owned hole surfaces.
      length mods `shouldBe` 12
      firewallBreaches mods `shouldBe` []
      let harness = generatedTextEndingIn "Harness.hs" mods
      harness `shouldSatisfy` T.isInfixOf "prefix = \"forward/replay equality: PlaceOrder from OrderNotStarted -- \""
      harness `shouldSatisfy` T.isInfixOf "prefix <> \"final vertex\""
      harness `shouldNotSatisfy` T.isInfixOf "prefix <> \"register "
    it "emits forward/replay checks with field-distinct Text samples" $ do
      spec <- parseInlineSpec "<forward-replay-samples>" (T.replace "command Bump { count:Int }" "command Bump { count:Int noteText:Text echo:Text }" loweringAggregateSpec)
      case [aggregate | NAggregate aggregate <- (.nodes) spec] of
        aggregate : _ -> do
          let ctx = defaultContext (spec.context)
              harness = generatedTextEndingIn "Harness.hs" (harnessFor ctx spec aggregate)
          harness `shouldSatisfy` T.isInfixOf "\"sample-noteText\" \"sample-echo\""
          harness `shouldSatisfy` T.isInfixOf "prefix = \"forward/replay equality: Bump from CounterPending -- \""
          harness `shouldSatisfy` T.isInfixOf "prefix <> \"register note\""
        [] -> expectationFailure "forward/replay sample spec has no aggregate"
    it "keeps inequality-guard samples distinct from register initials" $ do
      mods <- scaffoldFixture "test/fixtures/subscription.keiro"
      let harness = generatedTextEndingIn "Harness.hs" mods
      harness `shouldSatisfy` T.isInfixOf "ActivateSubscriptionData"
      harness `shouldSatisfy` T.isInfixOf "Paid"
      harness `shouldNotSatisfy` T.isInfixOf "ActivateSubscriptionData (case parseSubscriptionId \"sub_01h455vb4pex5vsknk084sn02q\" of Right parsed -> parsed; Left _ -> error \"generated valid ID sample failed to parse\") (case parseCustomerId \"cust_01h455vb4pex5vsknk084sn02q\" of Right parsed -> parsed; Left _ -> error \"generated valid ID sample failed to parse\") Free"
    it "uses consumer-owned nominal initials for equality-guard samples" $ do
      mods <- scaffoldFixture "test/fixtures/nominal-scalars.keiro"
      let harness = generatedTextEndingIn "Harness.hs" mods
      harness `shouldSatisfy` T.isInfixOf "Bindings.initialOrderId"
      harness `shouldSatisfy` (not . T.isInfixOf "NominalConformance.Bindings.initialOrderId")
      harness `shouldNotSatisfy` T.isInfixOf "case parseOrderId"
    it "emits the canonical reservation register checks" $ do
      mods <- scaffoldFixture "test/fixtures/reservation.keiro"
      let harness = generatedTextEndingIn "Harness.hs" mods
      harness `shouldSatisfy` T.isInfixOf "prefix = \"forward/replay equality: RequestTransferReservation from ReservationUnrequested -- \""
      harness `shouldSatisfy` T.isInfixOf "prefix <> \"register reservationId\""
      harness `shouldSatisfy` T.isInfixOf "prefix <> \"register hospitalId\""
      harness `shouldSatisfy` T.isInfixOf "prefix <> \"register patientAcuity\""
      harness `shouldNotSatisfy` T.isInfixOf "prefix <> \"register reservationState\""
    it "lowers a replay-only transition to B.replayOnly in the holes skeleton (plan 143)" $ do
      twinMods <- scaffoldFixture "test/fixtures/reservation-guard-tightened-twin.keiro"
      map (.text) twinMods `shouldSatisfy` any (T.isInfixOf "B.replayOnly")
      let twinHarness = generatedTextEndingIn "Harness.hs" twinMods
      T.count "forwardReplayRequestTransferReservation ::" twinHarness `shouldBe` 1
      plainMods <- scaffoldFixture "test/fixtures/reservation.keiro"
      map (.text) plainMods `shouldSatisfy` all (not . T.isInfixOf "B.replayOnly")

  describe "service workspace (EP-153)" $ do
    describe "manifest grammar" $ do
      it "round-trips the canonical fixture manifest byte-for-byte" $ do
        source <- readTestText canonicalWorkspacePath
        manifest <- shouldParseManifest canonicalWorkspacePath source
        (.service) manifest `shouldBe` "demo-project"
        (.runtimePackage) manifest `shouldBe` Nothing
        (.moduleRoot) manifest `shouldBe` Just "Demo.Modules.Project"
        (.layout) manifest `shouldBe` Just CollocatedLeaf
        map (.path) (NE.toList ((.members) manifest))
          `shouldBe` [ "domain/project-artifact.keiro",
                       "domain/project.keiro",
                       "domain/shared.keiro"
                     ]
        renderWorkspaceManifest manifest
          `shouldBe` T.intercalate
            "\n"
            [ "service demo-project",
              "module Demo.Modules.Project",
              "layout collocated",
              "spec domain/project-artifact.keiro",
              "spec domain/project.keiro",
              "spec domain/shared.keiro"
            ]
      it "round-trips runtime-package canonically immediately after service" $ do
        manifest <-
          shouldParseManifest "<runtime-package>" $
            T.unlines
              [ "service mori",
                "module Mori.Modules",
                "spec domain/mori.keiro",
                "runtime-package mori-core",
                "layout collocated"
              ]
        (.runtimePackage) manifest `shouldBe` Just (RuntimePackageName "mori-core")
        effectiveRuntimePackage Nothing manifest `shouldBe` Just (RuntimePackageName "mori-core")
        effectiveRuntimePackage (Just (RuntimePackageName "mori-dev")) manifest
          `shouldBe` Just (RuntimePackageName "mori-dev")
        renderWorkspaceManifest manifest
          `shouldBe` T.intercalate
            "\n"
            [ "service mori",
              "runtime-package mori-core",
              "module Mori.Modules",
              "layout collocated",
              "spec domain/mori.keiro"
            ]
      it "validates runtime package names with the mapped-source Cabal grammar" $ do
        mkRuntimePackageName "mori-core" `shouldBe` Right (RuntimePackageName "mori-core")
        mkRuntimePackageName "mori_core" `shouldBe` Left "runtime package 'mori_core' does not follow Cabal package-name grammar"
      it "treats membership as a set: source order changes neither the AST nor the bytes" $ do
        canonical <- readTestText canonicalWorkspacePath >>= shouldParseManifest canonicalWorkspacePath
        reordered <-
          shouldParseManifest "<reordered>" $
            T.unlines
              [ "service demo-project",
                "layout collocated",
                "spec domain/shared.keiro",
                "module Demo.Modules.Project",
                "spec domain/project.keiro",
                "spec ./domain/project-artifact.keiro"
              ]
        reordered `shouldBe` canonical
        renderWorkspaceManifest reordered `shouldBe` renderWorkspaceManifest canonical
      it "satisfies parse . render == id and render . parse . render == render" $
        property $
          forAll genWorkspaceManifest $ \manifest ->
            let rendered = renderWorkspaceManifest manifest
             in case parseWorkspaceManifest "<generated>" rendered of
                  Left err -> counterexample (T.unpack err) False
                  Right reparsed ->
                    counterexample (T.unpack rendered) $
                      reparsed == manifest && renderWorkspaceManifest reparsed == rendered
      it "recognizes a workspace manifest by extension, case-insensitively" $ do
        map
          isWorkspacePath
          [ "service.keiro-workspace",
            "a/b/Service.KEIRO-Workspace",
            "service.keiro",
            ".keiro-workspace",
            "keiro-workspace"
          ]
          `shouldBe` [True, True, False, False, False]
    describe "manifest refusals" $ do
      let rejects description source expected =
            it description $ case parseWorkspaceManifest "<manifest>" source of
              Right _ -> expectationFailure ("expected a refusal, got a manifest for:\n" <> T.unpack source)
              Left err -> T.unpack err `shouldContain` expected
      rejects
        "an empty manifest"
        "# only a comment\n"
        "must begin with a 'service <name>' clause"
      rejects
        "a manifest with no service clause"
        "spec domain/a.keiro\n"
        "first clause of a workspace manifest must be 'service <name>'"
      rejects
        "a manifest whose first clause is not service"
        "module Demo\nservice demo\nspec domain/a.keiro\n"
        "first clause of a workspace manifest must be 'service <name>'"
      rejects
        "a duplicate service clause"
        "service demo\nservice demo\nspec domain/a.keiro\n"
        "duplicate 'service' clause"
      rejects
        "a duplicate module clause"
        "service demo\nmodule Demo\nmodule Demo\nspec domain/a.keiro\n"
        "duplicate 'module' clause"
      rejects
        "a duplicate runtime-package clause"
        "service demo\nruntime-package demo-core\nruntime-package demo-api\nspec domain/a.keiro\n"
        "duplicate 'runtime-package' clause"
      it "locates a malformed runtime-package at its manifest line" $ case parseWorkspaceManifest "<manifest>" "service demo\nspec domain/a.keiro\nruntime-package demo_core\n" of
        Right _ -> expectationFailure "expected a malformed runtime package refusal"
        Left err -> do
          T.unpack err `shouldContain` "<manifest>:3:1"
          T.unpack err `shouldContain` "does not follow Cabal package-name grammar"
      rejects
        "a duplicate layout clause"
        "service demo\nlayout prefixed\nlayout prefixed\nspec domain/a.keiro\n"
        "duplicate 'layout' clause"
      rejects
        "a manifest with no members"
        "service demo\nmodule Demo\n"
        "must list at least one 'spec <path>.keiro' member"
      rejects
        "the same member listed twice"
        "service demo\nspec domain/a.keiro\nspec ./domain/a.keiro\n"
        "duplicate workspace member 'domain/a.keiro'"
      rejects
        "two members that differ only by case"
        "service demo\nspec domain/a.keiro\nspec domain/A.keiro\n"
        "differ only by case"
      rejects
        "an absolute member path"
        "service demo\nspec /etc/a.keiro\n"
        "must be relative, not absolute"
      rejects
        "a member path escaping the manifest directory"
        "service demo\nspec ../escape.keiro\n"
        "must not contain '..' segments"
      rejects
        "a member that is not a .keiro spec"
        "service demo\nspec domain/a.txt\n"
        "must name a .keiro spec"
      rejects
        "a manifest listing another manifest"
        "service demo\nspec domain/other.keiro-workspace\n"
        "must name a .keiro spec"
    describe "line relocation" $ do
      it "shifts every location the AST carries, and only the locations" $ do
        spec <- specOf "test/fixtures/reservation.keiro"
        let shifted = relocateLocs (+ 1000) spec
        collectLocs spec `shouldSatisfy` (not . null)
        collectLocs shifted `shouldBe` map (+ 1000) (collectLocs spec)
        -- Loc's Eq deliberately ignores the line, so relocation cannot
        -- change any equality-based behavior anywhere downstream.
        shifted `shouldBe` spec
      it "leaves the placeholder location alone so it never lands inside a member range" $ do
        spec <- specOf "test/fixtures/reservation.keiro"
        let blanked = relocateLocs (const 0) spec
            reshifted = relocateLocs (\n -> if n <= 0 then n else n + 500) blanked
        collectLocs reshifted `shouldBe` map (const 0) (collectLocs spec)
    describe "composition" $ do
      it "resolves cross-file ids, enums, mapped types, and read-model feeds" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        (.service) workspace `shouldBe` "demo-project"
        workspace.context `shouldBe` "demo-project"
        (.moduleRoot) workspace `shouldBe` Just "Demo.Modules.Project"
        (.layout) workspace `shouldBe` Just CollocatedLeaf
        map (.path) ((.members) workspace)
          `shouldBe` [ "domain/project-artifact.keiro",
                       "domain/project.keiro",
                       "domain/shared.keiro"
                     ]
        -- Every member is individually incomplete; together they check.
        checkWorkspace workspace `shouldBe` []
      it "records which member owns each shared declaration and node" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let ownershipIndex = workspace.ownership
        fmap fst (declarationOwner ownershipIndex "id" "ProjectId")
          `shouldBe` Just "domain/shared.keiro"
        fmap fst (declarationOwner ownershipIndex "enum" "ProjectPhase")
          `shouldBe` Just "domain/shared.keiro"
        fmap fst (declarationOwner ownershipIndex "rule" "phaseIsTerminal")
          `shouldBe` Just "domain/shared.keiro"
        fmap fst (declarationOwner ownershipIndex "mapped" "ProjectSummary")
          `shouldBe` Just "domain/shared.keiro"
        fmap fst (nodeOwner ownershipIndex "aggregate" "Project")
          `shouldBe` Just "domain/project.keiro"
        fmap fst (nodeOwner ownershipIndex "aggregate" "ProjectArtifact")
          `shouldBe` Just "domain/project-artifact.keiro"
        fmap fst (nodeOwner ownershipIndex "readmodel" "project_activity")
          `shouldBe` Just "domain/project-artifact.keiro"
      it "maps every merged line back to the member that wrote it" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let bases = [((.path) m, (.lineBase) m, (.lineCount) m) | m <- (.members) workspace]
        -- Ranges are disjoint and contiguous from zero.
        map (\(_, base, _) -> base) bases `shouldBe` scanl (+) 0 (init [c | (_, _, c) <- bases])
        sequence_
          [ resolveWorkspaceLine workspace (base + offset) `shouldBe` Just (path, offset)
          | (path, base, memberLines) <- bases,
            offset <- [1, memberLines]
          ]
        resolveWorkspaceLine workspace 0 `shouldBe` Nothing
      it "is insensitive to the order members are listed in" $ do
        canonical <- shouldComposeWorkspace canonicalWorkspacePath
        reordered <- shouldComposeWorkspace reorderedWorkspacePath
        workspaceWithManifestPath canonical.manifestPath reordered `shouldBe` canonical
      describe "workspace source provenance" $ do
        it "keeps a later member's exact points stable when an earlier member gains source lines" $ do
          let manifestText = T.unlines ["service provenance", "spec a.keiro", "spec b.keiro"]
              aSource =
                T.unlines
                  [ "context provenance",
                    "aggregate Alpha",
                    "  regs",
                    "  states Empty",
                    "  command Ping {}",
                    "  event Pinged {}",
                    "  Empty -- Ping --> emit Pinged; goto Empty"
                  ]
              bSource =
                T.unlines
                  [ "context provenance",
                    "aggregate Beta",
                    "  regs",
                    "  states Empty",
                    "  command Ping {}",
                    "  event Pinged {}",
                    "  Empty -- Ping --> emit Pinged; goto Empty"
                  ]
              sourceWith alpha =
                ContentSource
                  { csRead = \case
                      "service.keiro-workspace" -> pure (Right manifestText)
                      "a.keiro" -> pure (Right alpha)
                      "b.keiro" -> pure (Right bSource)
                      path -> pure (Left ("unexpected path " <> T.pack path))
                  }
              loadWith alpha = do
                loaded <- loadWorkspace (sourceWith alpha) "service.keiro-workspace"
                case loaded of
                  Left workspaceFailure -> expectationFailure (show workspaceFailure) >> fail "unreachable"
                  Right value -> pure value
              betaLocation workspace =
                lookupSourceSpan
                  (AggregateTransitionSubject "Beta" (TransitionOrdinal 0))
                  ((.sourceIndex) workspace)
              betaBase workspace = (.lineBase) <$> find ((== "b.keiro") . (.path)) ((.members) workspace)
          originalWorkspace <- loadWith aSource
          shiftedWorkspace <- loadWith ("# inserted before Alpha\n" <> aSource)
          betaLocation shiftedWorkspace `shouldBe` betaLocation originalWorkspace
          betaBase shiftedWorkspace `shouldBe` ((+ 1) <$> betaBase originalWorkspace)
          case betaLocation originalWorkspace of
            Just (ExactSourcePosition, SourceSpan {source, start = SourcePoint {line, column}}) ->
              (source, line, column) `shouldBe` ("b.keiro", 7, 3)
            other -> expectationFailure ("expected exact Beta transition location, got " <> show other)

          document <- case parseSourceDocument "b.keiro" bSource of
            Left parseFailure -> expectationFailure (show parseFailure) >> fail "unreachable"
            Right value -> pure value
          exactOneMember <- case oneMemberParsedDocumentWorkspace "b.keiro" document of
            Left sourceIndexFailure -> expectationFailure (show sourceIndexFailure) >> fail "unreachable"
            Right value -> pure value
          betaLocation exactOneMember `shouldBe` betaLocation originalWorkspace
          let ParsedSourceDocument {parsedSource} = document
              compatibility = oneMemberParsedWorkspace "b.keiro" parsedSource
          fmap fst (betaLocation compatibility) `shouldBe` Just CompatibilityLineOnly
      it "checks a single .keiro file as a one-member workspace, diagnostic for diagnostic" $ do
        let fixtures =
              [ "test/fixtures/reservation.keiro",
                "test/fixtures/consumer-types.keiro",
                "test/fixtures/aggregate-bad-refs.keiro",
                "test/fixtures/readmodel.keiro"
              ]
        forM_ fixtures $ \path -> do
          spec <- specOf path
          let workspace = oneMemberWorkspace path spec
              viaWorkspace = map (renderWorkspaceDiagnostic path) (checkWorkspace workspace)
              direct = map (renderDiagnostic path) (validateSpec spec)
          viaWorkspace `shouldBe` direct
        -- At least one of those fixtures must actually produce errors,
        -- or the equivalence claim is vacuous.
        badRefs <- specOf "test/fixtures/aggregate-bad-refs.keiro"
        checkWorkspace (oneMemberWorkspace "test/fixtures/aggregate-bad-refs.keiro" badRefs)
          `shouldSatisfy` any ((== Error) . (.severity))
    describe "composition refusals" $ do
      let refusesWith path expectedCode expectedFiles = do
            diagnostics <- shouldRefuseWorkspace path
            map (.code) (NE.toList diagnostics) `shouldContain` [expectedCode]
            let cited =
                  [ (.file) location
                  | diagnostic <- NE.toList diagnostics,
                    (.code) diagnostic == expectedCode,
                    location <- NE.toList ((.locations) diagnostic)
                  ]
            sort (nubOrd cited) `shouldBe` sort expectedFiles
      it "refuses members that declare different contexts, citing every context clause" $
        refusesWith
          "test/fixtures/workspace-context-mismatch/service.keiro-workspace"
          WorkspaceContextMismatch
          [WorkspaceMemberFile "domain/a.keiro", WorkspaceMemberFile "domain/b.keiro"]
      it "refuses a member layout clause that contradicts the manifest authority" $
        refusesWith
          "test/fixtures/workspace-authority-conflict/service.keiro-workspace"
          WorkspaceAuthorityConflict
          [WorkspaceManifestFile, WorkspaceMemberFile "domain/b.keiro"]
      it "refuses a textually identical shared declaration owned by two members" $
        refusesWith
          "test/fixtures/workspace-dup-decl/service.keiro-workspace"
          WorkspaceDuplicateDeclaration
          [WorkspaceMemberFile "domain/project.keiro", WorkspaceMemberFile "domain/shared.keiro"]
      it "refuses one aggregate defined in two members" $
        refusesWith
          "test/fixtures/workspace-dup-node/service.keiro-workspace"
          WorkspaceDuplicateNodeName
          [WorkspaceMemberFile "domain/a.keiro", WorkspaceMemberFile "domain/b.keiro"]
      it "refuses generated paths that collide across members under case folding" $
        refusesWith
          "test/fixtures/workspace-path-collision/service.keiro-workspace"
          WorkspacePathCollision
          [WorkspaceMemberFile "domain/a.keiro", WorkspaceMemberFile "domain/b.keiro"]
      it "reports a listed member that is missing from disk" $
        refusesWith
          "test/fixtures/workspace-missing-member/service.keiro-workspace"
          WorkspaceMemberUnreadable
          [WorkspaceManifestFile]
      it "reports a member that does not parse" $
        refusesWith
          "test/fixtures/workspace-member-parse-failed/service.keiro-workspace"
          WorkspaceMemberParseFailed
          [WorkspaceManifestFile]
      it "surfaces a cross-file unresolved reference through the merged validator" $ do
        workspace <- shouldComposeWorkspace "test/fixtures/workspace-unresolved/service.keiro-workspace"
        let errors = [d | d <- checkWorkspace workspace, (.severity) d == Error]
        map (.code) errors `shouldContain` [GuardAtomOutOfScope]
        [(.file) location | d <- errors, location <- NE.toList ((.locations) d)]
          `shouldContain` [WorkspaceMemberFile "domain/project.keiro"]
    describe "multi-file diagnostic rendering" $ do
      it "puts the primary location in the established shape and every other file on a note line" $ do
        diagnostics <- shouldRefuseWorkspace "test/fixtures/workspace-dup-decl/service.keiro-workspace"
        let manifest = "keiro-dsl/test/fixtures/workspace-dup-decl/service.keiro-workspace"
        map (renderWorkspaceDiagnostic manifest) (NE.toList diagnostics)
          `shouldBe` [ T.intercalate
                         "\n"
                         [ "keiro-dsl/test/fixtures/workspace-dup-decl/domain/project.keiro:4: error[WorkspaceDuplicateDeclaration]: duplicate declaration 'ProjectId': a shared declaration has exactly one owning member (identical duplicates do not merge)",
                           "  keiro-dsl/test/fixtures/workspace-dup-decl/domain/shared.keiro:4: note: also declared here, as id 'ProjectId'"
                         ]
                     ]
    describe "whole-service check through the CLI" $ do
      it "prints OK and exits zero for the composed fixture workspace" $ do
        (exitCode, out, err) <- runKeiroDsl ["check", canonicalWorkspacePath]
        unless (exitCode == ExitSuccess) (expectationFailure (out <> err))
        lines out `shouldBe` ["OK"]
      it "exits non-zero and names every involved file for a cross-file refusal" $ do
        (exitCode, _, err) <-
          runKeiroDsl ["check", "test/fixtures/workspace-dup-decl/service.keiro-workspace"]
        exitCode `shouldBe` ExitFailure 1
        err `shouldContain` "error[WorkspaceDuplicateDeclaration]"
        err `shouldContain` "workspace-dup-decl/domain/project.keiro:4"
        err `shouldContain` "workspace-dup-decl/domain/shared.keiro:4"
      it "attributes a merged-graph validation error to the member that wrote it" $ do
        (exitCode, _, err) <-
          runKeiroDsl ["check", "test/fixtures/workspace-unresolved/service.keiro-workspace"]
        exitCode `shouldBe` ExitFailure 1
        err `shouldContain` "workspace-unresolved/domain/project.keiro:12: error[GuardAtomOutOfScope]"
      it "produces byte-identical output for a manifest whose members are listed in reverse" $ do
        (canonicalCode, canonicalOut, _) <- runKeiroDsl ["check", canonicalWorkspacePath, "--emit"]
        (reorderedCode, reorderedOut, _) <- runKeiroDsl ["check", reorderedWorkspacePath, "--emit"]
        canonicalCode `shouldBe` ExitSuccess
        reorderedCode `shouldBe` ExitSuccess
        reorderedOut `shouldBe` canonicalOut
        (_, canonicalParse, _) <- runKeiroDsl ["parse", canonicalWorkspacePath]
        (_, reorderedParse, _) <- runKeiroDsl ["parse", reorderedWorkspacePath]
        reorderedParse `shouldBe` canonicalParse
      it "keeps the single-file path working, byte for byte" $ do
        (exitCode, out, err) <- runKeiroDsl ["check", "test/fixtures/reservation.keiro"]
        unless (exitCode == ExitSuccess) (expectationFailure (out <> err))
        lines out `shouldBe` ["OK"]
      it "explains bindings and reports coverage against the merged graph" $ do
        (bindingsCode, bindingsOut, _) <-
          runKeiroDsl ["check", canonicalWorkspacePath, "--explain-bindings"]
        bindingsCode `shouldBe` ExitSuccess
        bindingsOut `shouldContain` "binding obligations for context demo-project"
        -- The obligation's use sites span both aggregate members, which
        -- is only possible because the graph was resolved once, merged.
        bindingsOut `shouldContain` "Project register summary : ProjectSummary"
        bindingsOut `shouldContain` "ProjectArtifact command RecordArtifact .artifactSummary : ProjectSummary"
        withTempDirectory "keiro-dsl-workspace-coverage" $ \out -> do
          let reportPath = out </> "coverage.json"
          (coverageCode, coverageOut, _) <-
            runKeiroDsl ["check", canonicalWorkspacePath, "--coverage-report", reportPath]
          coverageCode `shouldBe` ExitSuccess
          coverageOut `shouldContain` "structural/opaque boundaries (reporting only)"
          report <- Aeson.eitherDecodeFileStrict reportPath
          case report of
            Left err -> expectationFailure err
            Right value -> coverageSpecPath value `shouldBe` Just (T.pack canonicalWorkspacePath)

  describe "workspace diff revision loading (EP-155 M1)" $ do
    it "composes added, removed, and renamed members through an in-memory content source" $ do
      project <- readTestText "test/fixtures/workspace/domain/project.keiro"
      artifact <- readTestText "test/fixtures/workspace/domain/project-artifact.keiro"
      shared <- readTestText "test/fixtures/workspace/domain/shared.keiro"
      let extra = "language keiro-dsl 4\ncontext demo-project\n\nid ExtraId prefix=extra\n"
          manifest members =
            T.unlines
              ( ["service demo-project", "module Demo.Modules.Project", "layout collocated"]
                  <> ["spec " <> T.pack member | member <- members]
              )
          baseFiles =
            Map.fromList
              [ ("domain/project.keiro", project),
                ("domain/project-artifact.keiro", artifact),
                ("domain/shared.keiro", shared)
              ]
          loadFrom members files =
            loadWorkspace
              (memoryContentSource (Map.insert "service.keiro-workspace" (manifest members) files))
              "service.keiro-workspace"
          baseMembers = ["domain/project.keiro", "domain/project-artifact.keiro", "domain/shared.keiro"]
          expectLoaded result = case result of
            Left failure -> expectationFailure (show failure) >> error "unreachable"
            Right workspace -> pure workspace

      oldAdded <- loadFrom baseMembers baseFiles >>= expectLoaded
      newAdded <-
        loadFrom
          (baseMembers <> ["domain/extra.keiro"])
          (Map.insert "domain/extra.keiro" extra baseFiles)
          >>= expectLoaded
      map changeCode (diffSpecs ((.mergedSpec) oldAdded) ((.mergedSpec) newAdded))
        `shouldContain` [DeclarationAdded]

      oldRemoved <- loadFrom baseMembers baseFiles >>= expectLoaded
      newRemoved <-
        loadFrom
          ["domain/project.keiro", "domain/shared.keiro"]
          (Map.delete "domain/project-artifact.keiro" baseFiles)
          >>= expectLoaded
      map changeCode (diffSpecs ((.mergedSpec) oldRemoved) ((.mergedSpec) newRemoved))
        `shouldContain` [EvtRemovedNotDeprecated]

      oldRenamed <- loadFrom baseMembers baseFiles >>= expectLoaded
      let renamedMembers = ["domain/project-renamed.keiro", "domain/project-artifact.keiro", "domain/shared.keiro"]
          renamedFiles = Map.insert "domain/project-renamed.keiro" project (Map.delete "domain/project.keiro" baseFiles)
      newRenamed <- loadFrom renamedMembers renamedFiles >>= expectLoaded
      diffSpecs ((.mergedSpec) oldRenamed) ((.mergedSpec) newRenamed) `shouldBe` []

  describe "workspace diff ownership and unified reports (EP-155 M2)" $ do
    it "classifies shared declarations at use sites across every member with owned citations" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      new <- shouldComposeWorkspace "test/fixtures/workspace-diff-new/service.keiro-workspace"
      let changes = diffWorkspaces old new
          enumChanges = filter ((== EnumCtorAdded) . changeCode . (.change)) changes
          mappedChanges = filter ((== MappedFieldTypeChanged) . changeCode . (.change)) changes
          citedFiles workspaceChanges =
            [ (.file) site
            | change <- workspaceChanges,
              (_, Just site) <- (.useSites) change
            ]
      enumChanges `shouldSatisfy` (not . null)
      mappedChanges `shouldSatisfy` (not . null)
      let enumWireChanges =
            [ underlyingChange
            | workspaceChange <- enumChanges,
              let underlyingChange = workspaceChange.change,
              OldBinaryReadNewEvents `elem` breakingSurfaces underlyingChange
            ]
      enumWireChanges `shouldSatisfy` (not . null)
      enumWireChanges `shouldSatisfy` all (not . gatedBreaking defaultGate)
      enumWireChanges `shouldSatisfy` all (gatedBreaking (gateWith [OldBinaryReadNewEvents]))
      map (fmap (.file) . (.declarationSite)) (enumChanges <> mappedChanges)
        `shouldSatisfy` all (== Just "domain/shared.keiro")
      citedFiles enumChanges `shouldContain` ["domain/order.keiro", "domain/shipment.keiro"]
      citedFiles mappedChanges `shouldContain` ["domain/order.keiro", "domain/shipment.keiro"]
      let rendered = T.intercalate "\n" (map renderWorkspaceFinding (enumChanges <> mappedChanges))
      rendered `shouldSatisfy` T.isInfixOf "    declared: domain/shared.keiro:4"
      rendered `shouldSatisfy` T.isInfixOf "    use-site: Order"
      rendered `shouldSatisfy` T.isInfixOf "(domain/order.keiro:"
      rendered `shouldSatisfy` T.isInfixOf "(domain/shipment.keiro:"
      assertMatchesGolden "test/fixtures/workspace-diff-new/workspace.diff.golden" (T.unlines (map renderWorkspaceFinding changes))

    it "emits one additive version-1 report with workspace provenance" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      new <- shouldComposeWorkspace "test/fixtures/workspace-diff-new/service.keiro-workspace"
      let changes = diffWorkspaces old new
          meta =
            WorkspaceMeta
              { identity = (.service) new,
                manifest = "service.keiro-workspace",
                since = "HEAD",
                membersOld = map (.path) ((.members) old),
                membersNew = map (.path) ((.members) new),
                adoptionBaseline = False
              }
      case Aeson.toJSON (workspaceDiffReport meta defaultGate changes) of
        Aeson.Object report -> do
          KeyMap.lookup "schema" report `shouldBe` Just (Aeson.String "keiro-dsl/diff-report/1")
          case KeyMap.lookup "workspace" report of
            Just (Aeson.Object workspace) -> do
              KeyMap.lookup "identity" workspace `shouldBe` Just (Aeson.String "workspace-diff")
              KeyMap.lookup "adoptionBaseline" workspace `shouldBe` Just (Aeson.Bool False)
            other -> expectationFailure ("missing workspace report metadata: " <> show other)
          case KeyMap.lookup "findings" report of
            Just (Aeson.Array findings) -> do
              findings `shouldSatisfy` (not . null)
              let objects = [finding | Aeson.Object finding <- toList findings]
              objects `shouldSatisfy` any (KeyMap.member "declaration")
              objects `shouldSatisfy` any (KeyMap.member "useSites")
            other -> expectationFailure ("missing workspace findings: " <> show other)
        other -> expectationFailure ("workspace report was not an object: " <> show other)

    it "computes one replay-impact value over both aggregates" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      new <- shouldComposeWorkspace "test/fixtures/workspace-diff-new/service.keiro-workspace"
      case replayImpactSpecs ((.mergedSpec) old) ((.mergedSpec) new) of
        ReplayAffected affected -> Map.keysSet affected `shouldBe` Set.fromList ["Order", "Shipment"]
        ReplayNeutral -> expectationFailure "shared mapped evolution unexpectedly reported replay-neutral"

  describe "workspace ownership and authority changes (EP-155 M3)" $ do
    it "reports an unchanged aggregate move once without wire evolution" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      moved <- shouldComposeWorkspace "test/fixtures/workspace-diff-moved/service.keiro-workspace"
      let changes = diffWorkspaces old moved
      map (changeCode . (.change)) changes `shouldBe` [OwnershipMoved]
      forM_ changes $ \workspaceMove -> do
        let move = (.change) workspaceMove
        move `shouldSatisfy` isAdvisory
        move `shouldSatisfy` (not . gatedBreaking defaultGate)
        move `shouldSatisfy` (not . gatedBreaking (gateWith [minBound .. maxBound]))
        deriveLabel defaultGate ((workspaceChangeKind move).vector) `shouldBe` LabelAdvisory
        remediationFor ((workspaceChangeKind move).context) OwnershipMoved
          `shouldBe` (RemedyRescaffoldWorkspace :| [])
        renderWorkspaceFinding workspaceMove
          `shouldSatisfy` T.isInfixOf "declaration moved domain/shipment.keiro -> domain/order.keiro"

    it "treats a member rename as the same owner-map change" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      let ownershipIndex = old.ownership
          renamed =
            workspaceWithOwnership
              (OwnershipIndex ownershipIndex.declarations (Map.adjust (\(_, loc) -> ("domain/shipping.keiro", loc)) ("aggregate", "Shipment") ownershipIndex.nodes))
              old
          moves = filter ((== OwnershipMoved) . changeCode . (.change)) (diffWorkspaces old renamed)
      length moves `shouldBe` 1
      forM_ moves $ \move ->
        renderWorkspaceFinding move `shouldSatisfy` T.isInfixOf "domain/shipment.keiro -> domain/shipping.keiro"

    it "reports ownership motion beside an independently classified wire edit" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      edited <- shouldComposeWorkspace "test/fixtures/workspace-diff-new/service.keiro-workspace"
      let ownershipIndex = edited.ownership
          movedAndEdited =
            workspaceWithOwnership
              (OwnershipIndex ownershipIndex.declarations (Map.adjust (\(_, loc) -> ("domain/order.keiro", loc)) ("aggregate", "Shipment") ownershipIndex.nodes))
              edited
          codes = map (changeCode . (.change)) (diffWorkspaces old movedAndEdited)
      codes `shouldContain` [OwnershipMoved]
      codes `shouldContain` [MappedFieldTypeChanged]

    it "reports context authority separately from derived read-model identity breaks" $ do
      old <- shouldComposeWorkspace canonicalWorkspacePath
      let newContext = "demo-project-renamed"
          renamed =
            workspaceWithContextAndMergedSpec newContext (specWithContext newContext old.mergedSpec) old
          changes = diffWorkspaces old renamed
          codes = map (changeCode . (.change)) changes
      codes `shouldContain` [WorkspaceAuthorityChanged]
      codes `shouldContain` [DerivedIdentityChanged]
      map (.change) changes `shouldSatisfy` any (gatedBreaking defaultGate)

    it "keeps service, module-root, and layout authority advisories non-blocking" $ do
      old <- shouldComposeWorkspace canonicalWorkspacePath
      let changed = workspaceWithAuthority "demo-project-renamed" (Just "Demo.Modules.Renamed") (Just GeneratedPrefix) old
          authority = filter ((== WorkspaceAuthorityChanged) . changeCode . (.change)) (diffWorkspaces old changed)
      length authority `shouldBe` 3
      forM_ (map (.change) authority) $ \change -> do
        deriveLabel defaultGate ((workspaceChangeKind change).vector) `shouldBe` LabelAdvisory
        change `shouldSatisfy` (not . gatedBreaking (gateWith [minBound .. maxBound]))
        remediationFor ((workspaceChangeKind change).context) WorkspaceAuthorityChanged
          `shouldBe` (RemedyRescaffoldWorkspace :| [RemedyRecompileConsumers])

  describe "workspace scaffold (EP-154)" $ do
    describe "workspace record" $ do
      it "round-trips modules, owners, members, mappings, obligations, and adoptions" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let record = sampleWorkspaceRecord workspace
            rendered = renderWorkspaceRecord record
        parseWorkspaceRecord rendered `shouldBe` Just record
        -- The header pins the schema: a v1 context-keyed record and a
        -- workspace record can never be read as each other.
        T.lines rendered `shouldSatisfy` \case
          header : _ -> header == "keiro-dsl workspace scaffold record v1"
          [] -> False
        parseRecord rendered `shouldBe` Nothing
        parseWorkspaceRecord (T.replace "record v1" "record v2" rendered) `shouldBe` Nothing
      it "ignores unknown rows and unknown JSON keys, and keeps context-level rows ownerless" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let record = sampleWorkspaceRecord workspace
            rendered = renderWorkspaceRecord record
        parseWorkspaceRecord (T.replace "service: " "future-row: retained\nservice: " rendered)
          `shouldBe` Just record
        parseWorkspaceRecord (T.replace "\"kind\":\"generated\"" "\"kind\":\"generated\",\"future\":1" rendered)
          `shouldBe` Just record
        [row | row <- (.modules) record, (.owner) row == Nothing]
          `shouldSatisfy` (not . null)
      it "rejects absent stable language rows and partial, duplicate, malformed, or inconsistent contracts" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let record = sampleWorkspaceRecord workspace
            rendered = renderWorkspaceRecord record
            sourceRows = filter ("source-language " `T.isPrefixOf`) (T.lines rendered)
            withoutSourceRows = T.unlines (filter (not . T.isPrefixOf "source-language ") (T.lines rendered))
            semanticRows = filter ("semantic-contract " `T.isPrefixOf`) (T.lines rendered)
            withoutSemanticRows = T.unlines (filter (not . T.isPrefixOf "semantic-contract ") (T.lines rendered))
        parseWorkspaceRecord withoutSourceRows `shouldBe` Nothing
        case sourceRows of
          firstRow : secondRow : _ -> do
            parseWorkspaceRecord (T.unlines (filter (/= secondRow) (T.lines rendered))) `shouldBe` Nothing
            parseWorkspaceRecord (T.replace firstRow (firstRow <> "\n" <> firstRow) rendered) `shouldBe` Nothing
            parseWorkspaceRecord (T.replace firstRow "source-language {malformed}" rendered) `shouldBe` Nothing
          _ -> expectationFailure "expected multiple workspace source-language rows"
        parseWorkspaceRecord withoutSemanticRows `shouldBe` Just record
        case semanticRows of
          [semanticRow] -> do
            parseWorkspaceRecord (T.replace semanticRow (semanticRow <> "\n" <> semanticRow) rendered) `shouldBe` Nothing
            parseWorkspaceRecord (T.replace semanticRow "semantic-contract {malformed}" rendered) `shouldBe` Nothing
            parseWorkspaceRecord (T.replace "\"languageVersion\":4" "\"languageVersion\":3" rendered) `shouldBe` Nothing
          _ -> expectationFailure "expected one workspace semantic-contract row"
      it "rejects unsafe module, owner, member, and adoption paths" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let rendered = renderWorkspaceRecord (sampleWorkspaceRecord workspace)
            corrupt from to = parseWorkspaceRecord (T.replace from to rendered)
        corrupt "member domain/shared.keiro" "member /etc/passwd" `shouldBe` Nothing
        corrupt "member domain/shared.keiro" "member ../escape.keiro" `shouldBe` Nothing
        corrupt "\"owner\":\"domain/shared.keiro\"" "\"owner\":\"../shared.keiro\"" `shouldBe` Nothing
        corrupt "\"path\":\"claimed/One.hs\"" "\"path\":\"/tmp/One.hs\"" `shouldBe` Nothing
      it "keys context and workspace history in structurally distinct explicit slots" $ do
        workspaceRecordFileName "demo-project"
          `shouldBe` workspaceLedgerFileName "demo-project"
        workspaceManifestFileName "demo-project"
          `shouldBe` workspaceCabalFragmentFileName "demo-project"
        workspaceRecordFileName "demo-project" `shouldNotBe` recordFileName "demo-project"
        contextLedgerFileName "workspace"
          `shouldNotBe` workspaceLedgerFileName "workspace"
        supersededByLine "demo-project"
          `shouldBe` "superseded-by: keiro-dsl-ledger.workspace.demo-project.txt"

    describe "workspace plan" $ do
      it "emits the context-level facade and replay-audit exactly once from the merged graph" $ do
        plan <- shouldPlanWorkspace canonicalWorkspacePath
        let modules = map fst (plan.modules)
            facades = [m | m <- modules, "StructuralProjections.hs" `isSuffixOfPath` m]
            audits = [m | m <- modules, "ReplayAudit.hs" `isSuffixOfPath` m]
            sourceMaps = [m | m <- modules, "BehaviorSourceMap.hs" `isSuffixOfPath` m]
            shapes = [m | m <- modules, "Structural/Shape/ProjectSummary.hs" `isSuffixOfPath` m]
        length facades `shouldBe` 1
        length audits `shouldBe` 1
        length sourceMaps `shouldBe` 1
        length shapes `shouldBe` 1
        -- The audit assembles aggregates owned by two different member
        -- files, which is only possible from one merged graph.
        forM_ audits $ \audit -> do
          (.text) audit `shouldSatisfy` T.isInfixOf "Project.projectEventStream"
          (.text) audit `shouldSatisfy` T.isInfixOf "ProjectArtifact.projectArtifactEventStream"
      it "gives every generated ID and enum one context owner and imports only aggregate uses" $ do
        plan <- shouldPlanWorkspace canonicalWorkspacePath
        let ctx = plan.context
            modules = map fst (plan.modules)
            nominalModules = [m | m <- modules, (.path) m == T.unpack (T.replace "." "/" (generatedNominalModule ctx) <> ".hs")]
            internalNominalModules = [m | m <- modules, (.path) m == T.unpack (T.replace "." "/" (generatedNominalModule ctx) <> "/Internal.hs")]
            domainFor suffix = case [m | m <- modules, suffix `isSuffixOfPath` m] of
              [m] -> pure m
              found -> expectationFailure ("expected one domain ending in " <> suffix <> ", got " <> show (map (.path) found)) >> fail "unreachable"
        ownerModule <- case nominalModules of
          [m] -> pure m
          found -> expectationFailure ("expected one generated nominal owner, got " <> show (map (.path) found)) >> fail "unreachable"
        internalOwnerModule <- case internalNominalModules of
          [m] -> pure m
          found -> expectationFailure ("expected one generated internal nominal owner, got " <> show (map (.path) found)) >> fail "unreachable"
        let nominalText = (.text) ownerModule
            internalNominalText = (.text) internalOwnerModule
        T.count "newtype ProjectId" nominalText `shouldBe` 0
        T.count "newtype ProjectId" internalNominalText `shouldBe` 1
        T.count "data ProjectPhase =" nominalText `shouldBe` 1
        T.count "data WorkspaceVisibility =" nominalText `shouldBe` 1
        projectDomain <- domainFor "Project/Generated/Domain.hs"
        artifactDomain <- domainFor "ProjectArtifact/Generated/Domain.hs"
        forM_ [projectDomain, artifactDomain] $ \domain -> do
          (.text) domain `shouldSatisfy` (not . T.isInfixOf "newtype ProjectId")
          (.text) domain `shouldSatisfy` (not . T.isInfixOf "data ProjectPhase")
          (.text) domain `shouldSatisfy` T.isInfixOf (generatedNominalModule ctx <> " (ProjectId, parseProjectId, ProjectPhase (..))")
          (.text) domain `shouldSatisfy` (not . T.isInfixOf "WorkspaceVisibility")
        -- Preserve the members' declared language contract. The active language-5
        -- candidate must not silently restamp an existing language-4 workspace.
        singleFileModules <- case planIndexedServiceScaffold ((.sourceIndex) ((.workspace) plan)) ctx (plan.checkedService) of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right values -> pure values
        let withoutOrigin m = ((.path) m, (.text) m, (.kind) m)
        map withoutOrigin singleFileModules `shouldBe` map withoutOrigin modules
        owners <- case planNominalGeneration ctx ((.mergedSpec) ((.workspace) plan)) of
          Left errors -> expectationFailure (show errors) >> fail "unreachable"
          Right values -> pure values
        map ((.name) . (.declaration)) owners
          `shouldBe` ["ProjectId", "ProjectPhase", "WorkspaceVisibility"]
        case [owner | owner <- owners, (.name) ((.declaration) owner) == "ProjectId"] of
          [owner] -> do
            (.moduleName) owner `shouldBe` generatedNominalModule ctx
            Set.fromList [NominalUseSite "Project" RegisterUse, NominalUseSite "ProjectArtifact" EventFieldUse]
              `shouldSatisfy` (`Set.isSubsetOf` (.useSites) owner)
          found -> expectationFailure ("expected one ProjectId owner, got " <> show (length found))
      it "attributes every module to its owning member and leaves shared ones context-level" $ do
        plan <- shouldPlanWorkspace canonicalWorkspacePath
        let memberPaths = map (.path) ((.members) ((.workspace) plan))
            ownerOf suffix =
              case [provenance | (m, provenance) <- (.modules) plan, suffix `isSuffixOfPath` m] of
                [provenance] -> Just provenance
                _ -> Nothing
        ownerOf "StructuralProjections.hs" `shouldBe` Just ContextLevel
        ownerOf "Generated/Nominals.hs" `shouldBe` Just ContextLevel
        ownerOf "ReplayAudit.hs" `shouldBe` Just ContextLevel
        ownerOf "Structural/Shape/ProjectSummary.hs"
          `shouldBe` Just (MemberOwned "domain/shared.keiro")
        ownerOf "Project/Generated/Domain.hs"
          `shouldBe` Just (MemberOwned "domain/project.keiro")
        ownerOf "ProjectArtifact/Generated/Domain.hs"
          `shouldBe` Just (MemberOwned "domain/project-artifact.keiro")
        ownerOf "ProjectActivity/Generated/ReadModel.hs"
          `shouldBe` Just (MemberOwned "domain/project-artifact.keiro")
        -- No module may claim an owner that is not a member of the
        -- workspace: the record's owner column has to stay resolvable.
        map (provenanceOwner . snd) ((.modules) plan)
          `shouldSatisfy` all (maybe True (`elem` memberPaths))
      it "keeps the compiled workspace nominal conformance tree byte-current" $ do
        workspace <- shouldComposeWorkspace "test/fixtures/workspace-nominals/service.keiro-workspace"
        plan <- shouldPlanWorkspaceSpec workspace
        let compiledPaths =
              [ "Generated/WorkspaceNominalProof/BehaviorSourceMap.hs",
                "Generated/WorkspaceNominalProof/Nominals.hs",
                "Generated/WorkspaceNominalProof/Project/Domain.hs",
                "Generated/WorkspaceNominalProof/Project/Codec.hs",
                "Generated/WorkspaceNominalProof/Project/Transducer.hs",
                "Generated/WorkspaceNominalProof/Project/BehaviorContract.hs",
                "Generated/WorkspaceNominalProof/Project/EventStream.hs",
                "Generated/WorkspaceNominalProof/Project/Harness.hs",
                "Generated/WorkspaceNominalProof/Project/Projection.hs",
                "Generated/WorkspaceNominalProof/ProjectArtifact/Domain.hs",
                "Generated/WorkspaceNominalProof/ProjectArtifact/Codec.hs",
                "Generated/WorkspaceNominalProof/ProjectArtifact/Transducer.hs",
                "Generated/WorkspaceNominalProof/ProjectArtifact/BehaviorContract.hs",
                "Generated/WorkspaceNominalProof/ProjectArtifact/EventStream.hs",
                "Generated/WorkspaceNominalProof/ProjectArtifact/Harness.hs",
                "Generated/WorkspaceNominalProof/ProjectArtifact/Projection.hs",
                "Generated/WorkspaceNominalProof/ReplayAudit.hs"
              ]
        map fst ((.modules) plan) `shouldSatisfy` all (not . isSuffixOfPath "/Holes.hs")
        forM_ compiledPaths $ \path ->
          case [m | (m, _) <- (.modules) plan, m.path == path] of
            [generated] -> do
              committed <- readTestText ("test/conformance-workspace-nominals/" <> path)
              normalizeGenerated committed `shouldBe` normalizeGenerated ((.text) generated)
            found -> expectationFailure ("expected one generated module at " <> path <> ", got " <> show (map (.path) found))
      it "plans a one-member workspace byte-identically to the single-file path" $ do
        let fixtures =
              [ "test/fixtures/reservation.keiro",
                "test/fixtures/consumer-types.keiro",
                "test/fixtures/readmodel.keiro",
                "test/fixtures/hospital-surge.keiro"
              ]
        -- Modules and refusals both: hospital-surge refuses on both
        -- paths, which proves the gates agree as well as the emitters.
        forM_ fixtures $ \path -> do
          (workspace, document) <- exactOneMemberWorkspaceOf path
          let ParsedSourceDocument {parsedSource = parsedSource, sourceIndex = sourceIndex} = document
              service = checkedSource parsedSource
              spec = checkedSpec service
              ctx = defaultContext (spec.context)
              isSourceMap moduleValue = "BehaviorSourceMap.hs" `isSuffixOfPath` moduleValue
          case (planWorkspaceScaffold "goldens" ctx workspace, planIndexedServiceScaffold sourceIndex ctx service) of
            (Left workspaceRefusals, Left singleSourceRefusals) ->
              workspaceRefusals `shouldBe` singleSourceRefusals
            (Right workspacePlan, Right singleSourceModules) -> do
              let workspaceModules = map fst ((.modules) workspacePlan)
                  workspaceStable = filter (not . isSourceMap) workspaceModules
                  singleSourceStable = filter (not . isSourceMap) singleSourceModules
                  workspaceSourceMaps = filter isSourceMap workspaceModules
                  singleSourceMaps = filter isSourceMap singleSourceModules
              workspaceStable `shouldBe` singleSourceStable
              case (workspaceSourceMaps, singleSourceMaps) of
                ([workspaceSourceMap], [singleSourceMap]) -> do
                  workspaceSourceMap.path `shouldBe` singleSourceMap.path
                  (.text) workspaceSourceMap
                    `shouldBe` T.replace (T.pack path) (T.pack (takeFileName path)) ((.text) singleSourceMap)
                found -> expectationFailure ("expected one source map per planning path, got " <> show (map (.path) (fst found), map (.path) (snd found)))
            (Left _, Right _) -> expectationFailure "workspace planning refused while single-source planning succeeded"
            (Right _, Left _) -> expectationFailure "workspace planning succeeded while single-source planning refused"
        -- The equality is not vacuous: at least one fixture plans, and
        -- its per-node modules are attributed to the single member.
        (workspace, document) <- exactOneMemberWorkspaceOf "test/fixtures/reservation.keiro"
        let ParsedSourceDocument {parsedSource = parsedSource} = document
            spec = checkedSpec (checkedSource parsedSource)
        case planWorkspaceScaffold "goldens" (defaultContext (spec.context)) workspace of
          Left refusals -> expectationFailure ("reservation should plan: " <> show refusals)
          Right plan -> do
            (.modules) plan `shouldSatisfy` (not . null)
            map snd ((.modules) plan)
              `shouldSatisfy` all (`elem` [ContextLevel, MemberOwned "reservation.keiro"])
            map snd ((.modules) plan)
              `shouldSatisfy` elem (MemberOwned "reservation.keiro")
      it "computes obligations from the complete merged graph, spanning members" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        case bindingObligations ((.mergedSpec) workspace) of
          Left graphErrors -> expectationFailure ("merged graph did not resolve: " <> show graphErrors)
          Right obligations ->
            case [o | o <- obligations, (.mappedName) o == "ProjectSummary", (.kind) o == BindingValue] of
              [obligation] -> do
                (.useSites) obligation
                  `shouldSatisfy` any (T.isInfixOf "Project register summary")
                (.useSites) obligation
                  `shouldSatisfy` any (T.isInfixOf "ProjectArtifact command RecordArtifact")
              found -> expectationFailure ("expected one ProjectSummary binding obligation, got " <> show (length found))
      it "refuses a case-folded path collision across members, naming both files" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let collided = withCaseVariantAggregate workspace
        case planWorkspaceScaffold "goldens" (workspaceContext collided) collided of
          Right _ -> expectationFailure "expected a cross-member path collision refusal"
          Left refusals -> do
            let origins = concat [os | PathCollision _ os <- refusals]
            origins `shouldSatisfy` any (T.isInfixOf "domain/project.keiro: ")
            origins `shouldSatisfy` any (T.isInfixOf "domain/project-artifact.keiro: ")
      it "refuses golden fixtures stranded beside a member instead of under the workspace root" $
        withTempDirectory "keiro-dsl-workspace-goldens" $ \root -> do
          workspace <- writeGoldenWorkspace root
          let workspaceGoldens = root </> "golden-payloads"
              fixture = "hospital-capacity/Reservation/TransferReservationCreated.v1.json"
              beside = root </> "domain/golden-payloads" </> fixture
          goldenRootDivergence workspaceGoldens workspace `shouldReturn` []
          createDirectoryIfMissing True (takeDirectory beside)
          TIO.writeFile beside "{}\n"
          refusals <- goldenRootDivergence workspaceGoldens workspace
          refusals `shouldBe` [GoldenRootDivergence workspaceGoldens [beside]]
          renderRefusals refusals
            `shouldSatisfy` any (T.isInfixOf "one golden root per workspace")
          -- The same fixture under the workspace root is no divergence.
          let atRoot = workspaceGoldens </> fixture
          createDirectoryIfMissing True (takeDirectory atRoot)
          TIO.writeFile atRoot "{}\n"
          goldenRootDivergence workspaceGoldens workspace `shouldReturn` []

    describe "workspace scaffold" $ do
      it "writes workspace-keyed history and no context-keyed file at all" $
        withWorkspaceFixture "keiro-dsl-workspace-history" id $ \_ out workspace -> do
          report <- executePlannedWorkspaceScaffold out workspace
          (.recordPath) report
            `shouldBe` out </> workspaceLedgerFileName "demo-project"
          (.buildManifestPath) report
            `shouldBe` out </> workspaceCabalFragmentFileName "demo-project"
          doesFileExist (out </> recordFileName "demo-project") `shouldReturn` False
          doesFileExist (out </> contextCabalFragmentFileName "demo-project") `shouldReturn` False
          contents <- TIO.readFile ((.recordPath) report)
          buildManifest <- TIO.readFile ((.buildManifestPath) report)
          assertGeneratedHaskellContract "service.keiro-workspace" buildManifest
          case parseWorkspaceRecord contents of
            Nothing -> expectationFailure ("workspace record did not parse:\n" <> T.unpack contents)
            Just record -> do
              (.service) record `shouldBe` "demo-project"
              (.manifest) record `shouldBe` "service.keiro-workspace"
              (.queryContractBaseline) record `shouldBe` False
              contents `shouldNotSatisfy` T.isInfixOf "query-contract-baseline"
              (.members) record
                `shouldBe` [ "domain/project-artifact.keiro",
                             "domain/project.keiro",
                             "domain/shared.keiro"
                           ]
              -- Context-level modules are ownerless; everything
              -- else names the member that produced it.
              [(.path) row | row <- (.modules) record, (.owner) row == Nothing]
                `shouldSatisfy` \ownerless ->
                  length ownerless == 6
                    && any (T.isSuffixOf "StructuralConformance.hs" . T.pack) ownerless
                    && any (T.isSuffixOf "BehaviorSourceMap.hs" . T.pack) ownerless
                    && any (T.isSuffixOf "StructuralProjections.hs" . T.pack) ownerless
                    && any (T.isSuffixOf "Nominals.hs" . T.pack) ownerless
                    && any (T.isSuffixOf "Nominals/Internal.hs" . T.pack) ownerless
                    && any (T.isSuffixOf "ReplayAudit.hs" . T.pack) ownerless
              [ (.owner) row
                | row <- (.modules) record,
                  "Project/Generated/Domain.hs" `T.isSuffixOf` T.pack ((.path) row)
                ]
                `shouldBe` [Just "domain/project.keiro"]
      it "refuses and then applies old workspace sidecar names before reading history" $
        withWorkspaceFixture "keiro-dsl-workspace-sidecar-migration" id $ \_ out workspace -> do
          plan <- shouldPlanWorkspaceSpec workspace
          first <- executeWorkspaceScaffold out False plan
          either (\failure -> expectationFailure (show failure)) (const (pure ())) first
          let service = workspace.service
              currentLedger = workspaceLedgerFileName service
              currentFragment = workspaceCabalFragmentFileName service
              oldLedger = legacyWorkspaceRecordFileName service
              oldFragment = legacyWorkspaceManifestFileName service
          renameFile (out </> currentLedger) (out </> oldLedger)
          renameFile (out </> currentFragment) (out </> oldFragment)
          migrationTreeBefore <- treeSnapshot out
          refused <- executeWorkspaceScaffoldWithNameMigrations out False False plan
          refused `shouldSatisfy` \case
            Left [SidecarMigrationRequired moves] ->
              length moves == 2 && all ((== RenameSidecar) . (.moveDisposition)) moves
            _ -> False
          treeSnapshot out `shouldReturn` migrationTreeBefore
          applied <- executeWorkspaceScaffoldWithNameMigrations out False True plan
          report <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure applied
          map (.moveDisposition) ((.sidecarMoves) report) `shouldBe` [RenameSidecar, RenameSidecar]
          (.stale) report `shouldBe` []
          doesFileExist (out </> oldLedger) `shouldReturn` False
          doesFileExist (out </> oldFragment) `shouldReturn` False
          doesFileExist (out </> currentLedger) `shouldReturn` True
          doesFileExist (out </> currentFragment) `shouldReturn` True
          rerun <- executeWorkspaceScaffoldWithNameMigrations out False True plan
          either (\failure -> expectationFailure (show failure)) (\value -> (.sidecarMoves) value `shouldBe` []) rerun
      it "is idempotent: an unchanged second run rewrites nothing and reports nothing" $
        withWorkspaceFixture "keiro-dsl-workspace-idempotent" id $ \_ out workspace -> do
          first <- executePlannedWorkspaceScaffold out workspace
          treeBefore <- treeSnapshot out
          second <- executePlannedWorkspaceScaffold out workspace
          treeAfter <- treeSnapshot out
          treeAfter `shouldBe` treeBefore
          map thd3 ((.dispositions) second)
            `shouldSatisfy` all (`elem` [Unchanged, Skipped])
          (.stale) second `shouldBe` []
          (.ownershipMoves) second `shouldBe` []
          (.mappingDrift) second `shouldBe` []
          (.newHoles) second `shouldBe` []
          -- The first run had to write; the claim is not vacuous.
          map thd3 ((.dispositions) first) `shouldSatisfy` any (== Overwritten)
          renderWorkspaceScaffoldReport second
            `shouldSatisfy` all (not . T.isPrefixOf "stale:")
      it "isolates member-local source movement to the one context behavior source map" $
        withWorkspaceFixture "keiro-dsl-workspace-source-movement" id $ \root out workspace -> do
          _ <- executePlannedWorkspaceScaffold out workspace
          treeBefore <- treeSnapshot out
          let member = root </> "domain/project-artifact.keiro"
          original <- TIO.readFile member
          TIO.writeFile member ("# move exact positions without changing semantics\n\n" <> original)
          moved <- loadTempWorkspace root
          second <- executePlannedWorkspaceScaffold out moved
          let overwrittenPaths =
                [(.path) generatedModule | (generatedModule, _, Overwritten) <- (.dispositions) second]
          overwrittenPaths `shouldSatisfy` \case
            [path] -> T.isSuffixOf "/BehaviorSourceMap.hs" (T.pack path)
            _ -> False
          (.declarations) (second.semanticImpact) `shouldBe` []
          map (.category) ((.generatedArtifactImpact) second)
            `shouldBe` [BehaviorSourceMapArtifact]
          treeAfter <- treeSnapshot out
          let isPositionBearingSidecar (path, _) =
                T.isSuffixOf "/BehaviorSourceMap.hs" (T.pack path)
                  || takeFileName path == workspaceLedgerFileName "demo-project"
          filter (not . isPositionBearingSidecar) treeAfter
            `shouldBe` filter (not . isPositionBearingSidecar) treeBefore
      it "produces byte-identical output for members listed in reverse order" $
        withWorkspaceFixture "keiro-dsl-workspace-order-a" id $ \_ outA workspaceA ->
          withWorkspaceFixture "keiro-dsl-workspace-order-b" reverse $ \_ outB workspaceB -> do
            _ <- executePlannedWorkspaceScaffold outA workspaceA
            _ <- executePlannedWorkspaceScaffold outB workspaceB
            treeB <- treeSnapshot outB
            treeA <- treeSnapshot outA
            treeB `shouldBe` treeA
            map fst treeA `shouldSatisfy` elem (workspaceLedgerFileName "demo-project")
      it "reports stale files only for the member that changed" $
        withWorkspaceFixture "keiro-dsl-workspace-stale" id $ \root out workspace -> do
          first <- executePlannedWorkspaceScaffold out workspace
          let siblingPaths =
                [ (.path) m
                | (m, provenance, _) <- (.dispositions) first,
                  provenance == MemberOwned "domain/project-artifact.keiro"
                ]
          siblingsBefore <- traverse (TIO.readFile . (out </>)) siblingPaths
          renamed <- renameMemberAggregate root "domain/project.keiro" "Project" "Ledger"
          second <- executePlannedWorkspaceScaffold out renamed
          let stalePaths = map (.path) ((.stale) second)
          stalePaths `shouldSatisfy` (not . null)
          stalePaths `shouldSatisfy` all (T.isInfixOf "/Project/" . T.pack)
          -- Nothing the sibling member owns is stale, and nothing it
          -- owns changed on disk: no cross-member false positives.
          stalePaths `shouldSatisfy` all (`notElem` siblingPaths)
          siblingsAfter <- traverse (TIO.readFile . (out </>)) siblingPaths
          siblingsAfter `shouldBe` siblingsBefore
          forM_ stalePaths $ \path -> doesFileExist (out </> path) `shouldReturn` True
          (.stale) second
            `shouldSatisfy` all
              ( \stale -> case (.kind) stale of
                  Generated -> (.generatedEvidence) stale == Just ExactGeneratedBannerPresent
                  HoleStub -> (.generatedEvidence) stale == Nothing
              )
          renderWorkspaceScaffoldReport second
            `shouldSatisfy` any (T.isInfixOf "keiro-dsl never deletes files.")
          renderWorkspaceScaffoldReport second
            `shouldSatisfy` any (T.isInfixOf "exact generated banner present; verify unchanged bytes before deleting")
          renderWorkspaceScaffoldReport second
            `shouldSatisfy` all (not . T.isInfixOf "safe to delete")
      it "reports an aggregate moved between members as an ownership move, not stale churn" $
        withWorkspaceFixture "keiro-dsl-workspace-move" id $ \root out workspace -> do
          _ <- executePlannedWorkspaceScaffold out workspace
          treeBefore <- treeSnapshot out
          moved <- moveArtifactAggregate root
          second <- executePlannedWorkspaceScaffold out moved
          (.stale) second `shouldBe` []
          let moves = (.ownershipMoves) second
          moves `shouldSatisfy` (not . null)
          moves
            `shouldSatisfy` all
              ( \move ->
                  (.previous) move == Just "domain/project-artifact.keiro"
                    && (.current) move == Just "domain/project.keiro"
              )
          map (.path) moves
            `shouldSatisfy` any (T.isInfixOf "ProjectArtifact" . T.pack)
          -- Behavior contracts contain only semantic identity. Moving a
          -- declaration rewrites the one source.map.context, while the ledger
          -- independently records module ownership moves.
          map thd3 ((.dispositions) second)
            `shouldSatisfy` all (`elem` [Unchanged, Skipped, Overwritten])
          let overwrittenPaths =
                [(.path) generatedModule | (generatedModule, _, Overwritten) <- (.dispositions) second]
          overwrittenPaths `shouldSatisfy` \case
            [path] -> T.isSuffixOf "/BehaviorSourceMap.hs" (T.pack path)
            _ -> False
          treeAfter <- treeSnapshot out
          map fst treeAfter `shouldBe` map fst treeBefore
          let unaffected (path, _) =
                path /= workspaceLedgerFileName "demo-project"
                  && path `notElem` overwrittenPaths
          filter unaffected treeAfter `shouldBe` filter unaffected treeBefore
          renderWorkspaceScaffoldReport second
            `shouldSatisfy` any (T.isInfixOf "changed owning member")
      it "leaves the tree, record, and manifest untouched when any member refuses" $
        withWorkspaceFixture "keiro-dsl-workspace-atomic" id $ \_ out workspace -> do
          _ <- executePlannedWorkspaceScaffold out workspace
          treeBefore <- treeSnapshot out
          let broken = withCaseVariantAggregate workspace
          case planWorkspaceScaffold "goldens" (workspaceContext broken) broken of
            Right _ -> expectationFailure "expected the broken workspace to refuse"
            Left refusals -> refusals `shouldSatisfy` any isPathCollision
          treeSnapshot out `shouldReturn` treeBefore
          -- A fresh output directory is never even created.
          withTempDirectory "keiro-dsl-workspace-atomic-fresh" $ \fresh -> do
            let target = fresh </> "out"
            case planWorkspaceScaffold "goldens" (workspaceContext broken) broken of
              Right _ -> expectationFailure "expected the broken workspace to refuse"
              Left _ -> doesDirectoryExist target `shouldReturn` False
      it "leaves prior workspace output byte-identical for parse, validation, and collision failures" $
        withWorkspaceFixture "keiro-dsl-workspace-atomic-cli" id $ \root out workspace -> do
          _ <- executePlannedWorkspaceScaffold out workspace
          treeBefore <- treeSnapshot out
          let member = root </> "domain/project-artifact.keiro"
              manifest = root </> "service.keiro-workspace"
          original <- TIO.readFile member
          let failures =
                [ ("parse", "context demo-project\naggregate !!!\n"),
                  ("validation", T.replace "ProjectId" "MissingProjectId" original),
                  ("collision", T.replace "aggregate ProjectArtifact" "aggregate PROJECT" original)
                ]
          forM_ failures $ \(failureKind, brokenSource) -> do
            TIO.writeFile member brokenSource
            (exitCode, stdoutText, stderrText) <-
              runKeiroDsl ["scaffold", manifest, "--out", out]
            unless (exitCode == ExitFailure 1) $
              expectationFailure
                (failureKind <> " failure unexpectedly scaffolded:\n" <> stdoutText <> stderrText)
            treeSnapshot out `shouldReturn` treeBefore
            TIO.writeFile member original
      it "refuses the whole workspace for one bannerless Generated target, changing nothing" $
        withWorkspaceFixture "keiro-dsl-workspace-banner" id $ \_ out workspace -> do
          plan <- shouldPlanWorkspaceSpec workspace
          let generated = [m | (m, _) <- (.modules) plan, (.kind) m == Generated]
          case generated of
            [] -> expectationFailure "workspace fixture has no Generated module"
            target : _ -> do
              let path = out </> target.path
              createDirectoryIfMissing True (takeDirectory path)
              TIO.writeFile path "hand owned\n"
              treeBefore <- treeSnapshot out
              refused <- executeWorkspaceScaffold out False plan
              refused `shouldSatisfy` isMissingBannerRefusal
              treeSnapshot out `shouldReturn` treeBefore
              forced <- executeWorkspaceScaffold out True plan
              forced `shouldSatisfy` isSuccessfulScaffold
              TIO.readFile path `shouldReturn` (.text) target
      it "scaffolds a whole workspace through the CLI" $
        withTempDirectory "keiro-dsl-workspace-cli" $ \out -> do
          (exitCode, stdoutText, stderrText) <-
            runKeiroDsl ["scaffold", canonicalWorkspacePath, "--out", out]
          unless (exitCode == ExitSuccess) (expectationFailure (stdoutText <> stderrText))
          stderrText `shouldContain` "workspace: demo-project"
          doesFileExist (out </> workspaceLedgerFileName "demo-project")
            `shouldReturn` True
          tree <- treeSnapshot out
          length [path | (path, _) <- tree, "StructuralProjections.hs" `T.isSuffixOf` T.pack path]
            `shouldBe` 1
          length [path | (path, _) <- tree, "ReplayAudit.hs" `T.isSuffixOf` T.pack path]
            `shouldBe` 1
          (secondCode, _, secondErr) <-
            runKeiroDsl ["scaffold", canonicalWorkspacePath, "--out", out]
          secondCode `shouldBe` ExitSuccess
          secondErr `shouldSatisfy` (not . isInfixOfString "(overwritten)")
          treeSnapshot out `shouldReturn` tree
      it "accepts a validated runtime-package override and generates exactly one service package" $
        withTempDirectory "keiro-dsl-workspace-runtime-package-cli" $ \out -> do
          (exitCode, stdoutText, stderrText) <-
            runKeiroDsl ["scaffold", canonicalWorkspacePath, "--out", out, "--runtime-package", "demo-runtime"]
          unless (exitCode == ExitSuccess) (expectationFailure (stdoutText <> stderrText))
          tree <- treeSnapshot out
          length [path | (path, _) <- tree, takeExtension path == ".cabal", "keiro-dsl-conformance.workspace.demo-project" `isInfixOfString` path]
            `shouldBe` 1
          stderrText `shouldSatisfy` isInfixOfString "conformance-target: cabal test keiro-demo-project-conformance"

    describe "workspace adoption" $ do
      it "replaces embedded 0.6 nominal declarations only in generated files" $
        withWorkspaceFixture "keiro-dsl-workspace-nominal-adopt" id $ \_ out workspace -> do
          plan <- shouldPlanWorkspaceSpec workspace
          let pathEndingIn suffix selectedKind =
                case [(.path) m | (m, _) <- (.modules) plan, (.kind) m == selectedKind, suffix `isSuffixOfPath` m] of
                  [path] -> pure path
                  found -> expectationFailure ("expected one path ending in " <> suffix <> ", got " <> show found) >> fail "unreachable"
          domainPath <- pathEndingIn "Project/Generated/Domain.hs" Generated
          nominalPath <- pathEndingIn "Generated/Nominals.hs" Generated
          internalNominalPath <- pathEndingIn "Generated/Nominals/Internal.hs" Generated
          path <- pathEndingIn "Project/Holes.hs" HoleStub
          writeFileWithParents
            (out </> domainPath)
            (generatedBanner <> "\n-- legacy 0.6 fixture\nmodule LegacyDomain where\nnewtype ProjectId = ProjectId String\ndata ProjectPhase = Draft | Active\n")
          writeFileWithParents (out </> path) "-- hand-owned 0.6 implementation\n"

          report <- executePlannedWorkspaceScaffold out workspace
          (.stale) report `shouldBe` []
          [disposition | (m, _, disposition) <- (.dispositions) report, m.path == domainPath]
            `shouldBe` [Overwritten]
          [disposition | (m, _, disposition) <- (.dispositions) report, m.path == nominalPath]
            `shouldBe` [Overwritten]
          newDomain <- TIO.readFile (out </> domainPath)
          newDomain `shouldSatisfy` (not . T.isInfixOf "newtype ProjectId")
          newDomain `shouldSatisfy` T.isInfixOf "Generated.Nominals (ProjectId, parseProjectId, ProjectPhase (..))"
          newNominals <- TIO.readFile (out </> nominalPath)
          T.count "newtype ProjectId" newNominals `shouldBe` 0
          T.count "data ProjectPhase =" newNominals `shouldBe` 1
          newInternalNominals <- TIO.readFile (out </> internalNominalPath)
          T.count "newtype ProjectId" newInternalNominals `shouldBe` 1
          TIO.readFile (out </> path) `shouldReturn` "-- hand-owned 0.6 implementation\n"
      it "adopts an overwritten same-context record pair by record and by banner" $
        withInlineWorkspace "keiro-dsl-workspace-adopt" adoptionMembers $ \_ out workspace -> do
          -- Reproduce today's defect first: two same-specs.context
          -- scaffolded independently into one directory, the second
          -- replacing the first's record and calling its files stale.
          specA <- parseInlineSpec "domain/a.keiro" adoptionMemberA
          specB <- parseInlineSpec "domain/b.keiro" adoptionMemberB
          let ctx = defaultContext "adoption-demo"
          legacyA <- executePlannedScaffold out "domain/a.keiro" ctx specA
          legacyB <- executePlannedScaffold out "domain/b.keiro" ctx specB
          (.stale) legacyB `shouldSatisfy` (not . null)
          legacyBefore <- TIO.readFile (out </> recordFileName "adoption-demo")

          report <- executePlannedWorkspaceScaffold out workspace
          (.stale) report `shouldBe` []
          case (.migration) report of
            Nothing -> expectationFailure "expected the first workspace run to adopt"
            Just migration -> do
              let generatedOf run = sort [(.path) m | (m, _) <- (.dispositions) run, (.kind) m == Generated]
                  claimedBy evidence = sort [entry.path | entry <- migration.claimed, entry.evidence == evidence]
              -- The surviving record attributes B's files; A's
              -- files survived only as banners, which is exactly
              -- the orphan case the overwrite created.
              claimedBy ClaimedFromRecord `shouldBe` generatedOf legacyB
              claimedBy ClaimedFromBanner `shouldBe` sort (generatedOf legacyA \\ generatedOf legacyB)
              claimedBy ClaimedFromBanner `shouldSatisfy` (not . null)
              (.likelyStale) migration `shouldBe` []
              (.legacyRecord) migration
                `shouldBe` Just (recordFileName "adoption-demo", "domain/b.keiro")
              -- Provenance is persisted, not merely printed.
              recorded <- parseWorkspaceRecord <$> TIO.readFile ((.recordPath) report)
              fmap (sort . map (.path) . (.adopted)) recorded
                `shouldBe` Just (sort (map (.path) ((.claimed) migration)))
              fmap (sort . nubOrd . map (.evidence) . (.adopted)) recorded
                `shouldBe` Just ["banner", "record"]
              persisted <- TIO.readFile (out </> "keiro-dsl-migration-report.workspace.adoption-demo.txt")
              persisted `shouldBe` T.unlines (renderMigrationReport migration)
              renderWorkspaceScaffoldReport report
                `shouldSatisfy` any (T.isInfixOf "adopting pre-workspace scaffold output")

          -- The legacy record gained one line and nothing else: it
          -- still parses to the same value for an old binary.
          legacyAfter <- TIO.readFile (out </> recordFileName "adoption-demo")
          T.lines legacyAfter `shouldSatisfy` elem (supersededByLine "adoption-demo")
          parseRecord legacyAfter `shouldBe` parseRecord legacyBefore
          T.lines legacyAfter
            `shouldBe` T.lines legacyBefore <> [supersededByLine "adoption-demo"]

          -- Adoption is not a content change: the generated tree is
          -- what a fresh workspace scaffold of the same members emits.
          withInlineWorkspace "keiro-dsl-workspace-adopt-fresh" adoptionMembers $ \_ fresh freshWorkspace -> do
            freshReport <- executePlannedWorkspaceScaffold fresh freshWorkspace
            (.migration) freshReport `shouldBe` Nothing
            adoptedTree <- treeSnapshot out
            freshTree <- treeSnapshot fresh
            haskellOnly adoptedTree `shouldBe` haskellOnly freshTree
      it "adopts and marks context history under the legacy record name" $
        withInlineWorkspace "keiro-dsl-workspace-adopt-legacy-name" adoptionMembers $ \_ out workspace -> do
          specA <- parseInlineSpec "domain/a.keiro" adoptionMemberA
          _ <- executePlannedScaffold out "domain/a.keiro" (defaultContext "adoption-demo") specA
          let current = contextLedgerFileName "adoption-demo"
              legacy = legacyContextRecordFileName "adoption-demo"
          renameFile (out </> current) (out </> legacy)
          ledgerBefore <- TIO.readFile (out </> legacy)
          report <- executePlannedWorkspaceScaffold out workspace
          case (.migration) report of
            Nothing -> expectationFailure "expected legacy-name context history to be adopted"
            Just migration -> (.legacyRecord) migration `shouldBe` Just (legacy, "domain/a.keiro")
          doesFileExist (out </> current) `shouldReturn` False
          ledgerAfter <- TIO.readFile (out </> legacy)
          T.lines ledgerAfter `shouldBe` T.lines ledgerBefore <> [supersededByLine "adoption-demo"]
          parseRecord ledgerAfter `shouldBe` parseRecord ledgerBefore
      it "lists hand-written files as unclaimed and leaves their bytes alone" $
        withInlineWorkspace "keiro-dsl-workspace-unclaimed" adoptionMembers $ \_ out workspace -> do
          plan <- shouldPlanWorkspaceSpec workspace
          case [(.path) m | (m, _) <- (.modules) plan, (.kind) m == HoleStub] of
            [] -> expectationFailure "adoption fixture emits no hole module"
            path : _ -> do
              writeFileWithParents (out </> path) "-- hand filled\n"
              writeFileWithParents (out </> "Notes.hs") "module Notes where\n"
              report <- executePlannedWorkspaceScaffold out workspace
              case (.migration) report of
                Nothing -> expectationFailure "expected a report for a directory holding hand-written files"
                Just migration -> do
                  (.legacyRecord) migration `shouldBe` Nothing
                  (.claimed) migration `shouldBe` []
                  (.unclaimed) migration `shouldBe` sort [path, "Notes.hs"]
              TIO.readFile (out </> path) `shouldReturn` "-- hand filled\n"
              TIO.readFile (out </> "Notes.hs") `shouldReturn` "module Notes where\n"
      it "never claims a bannerless file at a planned Generated path" $
        withInlineWorkspace "keiro-dsl-workspace-unattributable" adoptionMembers $ \_ out workspace -> do
          plan <- shouldPlanWorkspaceSpec workspace
          case [(.path) m | (m, _) <- (.modules) plan, (.kind) m == Generated] of
            [] -> expectationFailure "adoption fixture emits no Generated module"
            target : _ -> do
              writeFileWithParents (out </> target) "hand owned\n"
              refused <- executeWorkspaceScaffold out False plan
              refused `shouldSatisfy` isMissingBannerRefusal
              TIO.readFile (out </> target) `shouldReturn` "hand owned\n"
              doesFileExist (out </> "keiro-dsl-migration-report.workspace.adoption-demo.txt")
                `shouldReturn` False
      it "adopts at most once, and the second run is an ordinary idempotent run" $
        withInlineWorkspace "keiro-dsl-workspace-adopt-once" adoptionMembers $ \_ out workspace -> do
          specA <- parseInlineSpec "domain/a.keiro" adoptionMemberA
          _ <- executePlannedScaffold out "domain/a.keiro" (defaultContext "adoption-demo") specA
          first <- executePlannedWorkspaceScaffold out workspace
          (.migration) first `shouldSatisfy` \case Just _ -> True; Nothing -> False
          treeBefore <- treeSnapshot out
          reportBefore <- TIO.readFile (out </> "keiro-dsl-migration-report.workspace.adoption-demo.txt")
          legacyBefore <- TIO.readFile (out </> recordFileName "adoption-demo")

          second <- executePlannedWorkspaceScaffold out workspace
          (.migration) second `shouldBe` Nothing
          (.stale) second `shouldBe` []
          map thd3 ((.dispositions) second) `shouldSatisfy` all (`elem` [Unchanged, Skipped])
          treeSnapshot out `shouldReturn` treeBefore
          TIO.readFile (out </> "keiro-dsl-migration-report.workspace.adoption-demo.txt")
            `shouldReturn` reportBefore
          legacyAfter <- TIO.readFile (out </> recordFileName "adoption-demo")
          legacyAfter `shouldBe` legacyBefore
          length (filter (== supersededByLine "adoption-demo") (T.lines legacyAfter))
            `shouldBe` 1

comparisonProvenance :: CompareProvenance
comparisonProvenance =
  CompareProvenance
    { historicalCodecIdentity = "example.historical",
      historicalCodecVersion = "legacy-v1",
      canonicalType = CanonicalTypeId "example.Artifact.v1",
      bindingSymbol = QualifiedValueName "Example.Bindings.artifactBinding",
      bindingVersion = BindingVersion "1",
      wireFingerprint = "deadbeef"
    }

syntheticGenerated :: FilePath -> T.Text -> ScaffoldModule
syntheticGenerated path contents =
  ScaffoldModule {path = path, text = contents, kind = Generated, origin = "test"}

data GeneratedTreeDelta = GeneratedTreeDelta
  { changedPaths :: !(Set.Set FilePath),
    addedPaths :: !(Set.Set FilePath),
    removedPaths :: !(Set.Set FilePath),
    changedLineCounts :: !(Map.Map FilePath Int)
  }
  deriving stock (Eq, Show)

generatedTreeDelta :: [ScaffoldModule] -> [ScaffoldModule] -> GeneratedTreeDelta
generatedTreeDelta previous current =
  GeneratedTreeDelta
    { changedPaths = changed,
      addedPaths = added,
      removedPaths = removed,
      changedLineCounts = Map.fromSet changedLineCount impacted
    }
  where
    previousByPath = generatedByPath previous
    currentByPath = generatedByPath current
    previousPaths = Map.keysSet previousByPath
    currentPaths = Map.keysSet currentByPath
    added = currentPaths Set.\\ previousPaths
    removed = previousPaths Set.\\ currentPaths
    shared = previousPaths `Set.intersection` currentPaths
    changed = Set.filter (\path -> Map.lookup path previousByPath /= Map.lookup path currentByPath) shared
    impacted = changed <> added <> removed
    changedLineCount path = case (Map.lookup path previousByPath, Map.lookup path currentByPath) of
      (Just old, Just new) -> differingLineCount ((.text) old) ((.text) new)
      (Just old, Nothing) -> length (T.lines ((.text) old))
      (Nothing, Just new) -> length (T.lines ((.text) new))
      (Nothing, Nothing) -> 0
    generatedByPath modules = Map.fromList [((.path) value, value) | value <- modules, (.kind) value == Generated]

generatedTreeDeltaFromSnapshot :: [(FilePath, T.Text)] -> [(FilePath, T.Text)] -> GeneratedTreeDelta
generatedTreeDeltaFromSnapshot previous current =
  generatedTreeDelta
    [syntheticGenerated path contents | (path, contents) <- previous]
    [syntheticGenerated path contents | (path, contents) <- current]

differingLineCount :: T.Text -> T.Text -> Int
differingLineCount previous current =
  unequalShared + abs (length previousLines - length currentLines)
  where
    previousLines = T.lines previous
    currentLines = T.lines current
    unequalShared = length [() | (old, new) <- zip previousLines currentLines, old /= new]

assertAllowedGeneratedDelta :: Set.Set ModuleRole -> [ScaffoldModule] -> [ScaffoldModule] -> GeneratedTreeDelta -> Expectation
assertAllowedGeneratedDelta allowed previous current delta = do
  (.removedPaths) delta `shouldBe` Set.empty
  actualRoles `shouldSatisfy` (`Set.isSubsetOf` allowed)
  where
    modulesByPath = Map.fromList [((.path) value, value) | value <- previous <> current, (.kind) value == Generated]
    impacted = (.changedPaths) delta <> (.addedPaths) delta <> (.removedPaths) delta
    actualRoles = Set.fromList [moduleRole value | path <- Set.toList impacted, Just value <- [Map.lookup path modulesByPath]]

generatedTextEndingIn :: T.Text -> [ScaffoldModule] -> T.Text
generatedTextEndingIn suffix modules = case [(.text) m | m <- modules, (.kind) m == Generated, suffix `T.isSuffixOf` T.pack ((.path) m)] of
  contents : _ -> contents
  [] -> ""

generatedExtensionsEndingIn :: T.Text -> [ScaffoldModule] -> [T.Text]
generatedExtensionsEndingIn suffix modules = case [generatedModule | generatedModule <- modules, (.kind) generatedModule == Generated, suffix `T.isSuffixOf` T.pack ((.path) generatedModule)] of
  [generatedModule] -> generatedLocalExtensions generatedModule
  matches -> error ("expected one generated module ending in " <> T.unpack suffix <> ", got " <> show (map (.path) matches))

generatedLocalExtensions :: ScaffoldModule -> [T.Text]
generatedLocalExtensions generatedModule =
  [ extension
  | line <- takeWhile (T.isPrefixOf languagePrefix) (T.lines ((.text) generatedModule)),
    Just extensionWithSuffix <- [T.stripPrefix languagePrefix line],
    Just extension <- [T.stripSuffix languageSuffix extensionWithSuffix]
  ]
  where
    languagePrefix = "{-# LANGUAGE "
    languageSuffix = " #-}"

holeTextEndingIn :: T.Text -> [ScaffoldModule] -> T.Text
holeTextEndingIn suffix modules = case [(.text) m | m <- modules, (.kind) m == HoleStub, suffix `T.isSuffixOf` T.pack ((.path) m), not ("BehaviorHoles.hs" `T.isSuffixOf` T.pack ((.path) m))] of
  contents : _ -> contents
  [] -> ""

onlyAggregate :: Spec -> Aggregate
onlyAggregate spec = case [aggregate | NAggregate aggregate <- (.nodes) spec] of
  [aggregate] -> aggregate
  aggregates -> error ("expected one aggregate, got " <> show (length aggregates))

loweringAggregateSpec :: T.Text
loweringAggregateSpec =
  T.unlines
    [ "context samples",
      "",
      "aggregate Counter",
      "  regs",
      "    note Text = \"hello world\"",
      "    count Int = 0",
      "    state CounterVertex = Pending",
      "  states Pending Done!",
      "  command Bump { count:Int }",
      "  event CountBumped { count:Int }",
      "  Pending -- Bump --> emit CountBumped ; goto Done"
    ]

scalarRegisterCases :: [(T.Text, T.Text)]
scalarRegisterCases =
  [ ("Text", "\"sample\""),
    ("Int", "0"),
    ("Bool", "False"),
    ("Time", "\"2026-01-02T03:04:05.123456789012Z\""),
    ("Natural", "0")
  ]

cleanScalarAggregateSpec :: T.Text -> T.Text -> T.Text
cleanScalarAggregateSpec typeName initialValue =
  T.unlines
    [ "context clean-scalar",
      "",
      "aggregate Scalar",
      "  regs",
      "    value " <> typeName <> " = " <> initialValue,
      "  states Empty Done!",
      "  command Set { value:" <> typeName <> " }",
      "  event SetDone { value:" <> typeName <> " }",
      "  Empty -- Set --> write value := value ; emit SetDone ; goto Done"
    ]

exactStatusSpec :: T.Text
exactStatusSpec =
  T.unlines
    [ "context samples",
      "",
      "aggregate Reservation",
      "  regs",
      "    state ReservationVertex = Open",
      "  states Open Closed!",
      "  command Bump { count:Int }",
      "  event ReservationHeld { count:Int }",
      "  event ReservationUnHeld { count:Int }",
      "  event CountBumped { count:Int }",
      "  Open -- Bump --> emit CountBumped ; goto Closed",
      "  projection reservation_status consistency=Eventual key=count",
      "    status-map { ReservationHeld=>held ReservationUnHeld=>available CountBumped=>bumped }"
    ]

hasPathCollisionWithTwoOrigins :: Either [Refusal] [ScaffoldModule] -> Bool
hasPathCollisionWithTwoOrigins = \case
  Left refusals -> any hasTwo refusals
  Right _ -> False
  where
    hasTwo (PathCollision _ origins) = length origins == 2
    hasTwo _ = False

isMissingBannerRefusal :: Either [Refusal] a -> Bool
isMissingBannerRefusal = \case
  Left [MissingGeneratedBanner paths] -> not (null paths)
  _ -> False

isSuccessfulScaffold :: Either [Refusal] a -> Bool
isSuccessfulScaffold = \case
  Right _ -> True
  Left _ -> False

-- Unit tests that construct semantic values directly still need to exercise
-- the production planner's exact-source path. Promote the compatibility spans
-- into an explicitly exact, complete index here; production code never
-- fabricates this provenance.
syntheticExactSourceIndex :: Spec -> SemanticSourceIndex
syntheticExactSourceIndex spec =
  case compatibilitySemanticSourceIndex sourceName spec of
    Left failure -> error ("failed to construct the test source index: " <> show failure)
    Right compatibilityIndex ->
      case exactSemanticSourceIndex sourceName (semanticSourceSubjects spec) entries of
        Left failure -> error ("failed to promote the test source index: " <> show failure)
        Right exactIndex -> exactIndex
      where
        entries = [(subject, sourceSpan) | (subject, _, sourceSpan) <- semanticSourceEntries compatibilityIndex]
  where
    sourceName = "<test-exact>"

planTestServiceScaffold :: Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planTestServiceScaffold ctx service =
  planIndexedServiceScaffold (syntheticExactSourceIndex (checkedSpec service)) ctx service

planTestServiceScaffoldWithRuntimePackage :: Maybe RuntimePackageName -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planTestServiceScaffoldWithRuntimePackage runtimePackage ctx service =
  planIndexedServiceScaffoldWithRuntimePackage runtimePackage (syntheticExactSourceIndex (checkedSpec service)) ctx service

planTestScaffold :: Context -> Spec -> Either [Refusal] [ScaffoldModule]
planTestScaffold ctx spec = planTestServiceScaffold ctx (legacyCheckedService spec)

checkTestServiceDiagnostics :: Maybe RuntimePackageName -> Context -> CheckedService -> [Diagnostic]
checkTestServiceDiagnostics runtimePackage ctx service =
  checkIndexedServiceDiagnostics runtimePackage (syntheticExactSourceIndex (checkedSpec service)) ctx service

executePlannedScaffold :: FilePath -> FilePath -> Context -> Spec -> IO ScaffoldReport
executePlannedScaffold out specPath ctx spec = case planTestScaffold ctx spec of
  Left refusals -> expectationFailure ("unexpected scaffold refusal: " <> show refusals) >> error "unreachable"
  Right modules -> do
    result <- executeScaffold out False specPath ctx spec modules
    case result of
      Left refusals -> expectationFailure ("unexpected execution refusal: " <> show refusals) >> error "unreachable"
      Right report -> pure report

renameCounter :: Node -> Node
renameCounter (NAggregate aggregate) =
  NAggregate
    ( aggregateWithNameAndRegs
        "Widget"
        [regDeclWithValueType (if reg.valueType == TRef "CounterVertex" then TRef "WidgetVertex" else reg.valueType) reg | reg <- aggregate.regs]
        aggregate
    )
renameCounter node = node

onlyPathEndingIn :: FilePath -> [ScaffoldModule] -> FilePath
onlyPathEndingIn suffix modules = case [(.path) m | m <- modules, T.pack suffix `T.isSuffixOf` T.pack ((.path) m)] of
  [path] -> path
  paths -> error ("expected one path ending in " <> suffix <> ", got " <> show paths)

withTempDirectory :: String -> (FilePath -> IO a) -> IO a
withTempDirectory template = bracket acquire removePathForcibly
  where
    acquire = do
      base <- getTemporaryDirectory
      (path, handle) <- openTempFile base template
      hClose handle
      removeFile path
      createDirectory path
      pure path

-- | Parse a fixture and return the validator's diagnostic codes (failing the
-- test on a parse error).
diagnosticCodesOf :: FilePath -> IO [DiagnosticCode]
diagnosticCodesOf path = do
  map (.code) <$> diagnosticsOf path

-- | Parse a fixture and return all validator diagnostics.
diagnosticsOf :: FilePath -> IO [Diagnostic]
diagnosticsOf path = do
  service <- checkedServiceOf path
  pure (validateService service)

-- | Like 'diagnosticCodesOf' but only the Error-severity codes (warnings, e.g.
-- the benign-inversion notices, are excluded).
errorCodesOf :: FilePath -> IO [DiagnosticCode]
errorCodesOf path = do
  diagnostics <- diagnosticsOf path
  pure [(.code) d | d <- diagnostics, (.severity) d == Error]

-- | Parse two fixtures and diff them (old, new).
-- | Plan 143: render an Expr in concrete guard syntax by printing a dummy
-- transition through the real pretty-printer and slicing its guard clause,
-- so the test exercises the exact printer the diff advisory uses.
renderExprText :: Expr -> T.Text
renderExprText e =
  case [T.strip l | l <- T.lines rendered, "guard " `T.isPrefixOf` T.strip l] of
    [guardLine] -> T.strip (T.drop (T.length "guard ") guardLine)
    _ -> error ("renderExprText: unexpected printer output: " <> T.unpack rendered)
  where
    rendered =
      renderTransition
        Transition
          { source = "S",
            command = "C",
            implementation = LegacyHoleImplementation,
            guard = Just e,
            writes = [],
            emits = [],
            outcome = Nothing,
            outcomeDuplicateLocs = [],
            goto = "S",
            mode = TmLive,
            loc = noLoc
          }

-- | Plan 143: a minimal spec whose only transition is replay-only, with the
-- supplied clause lines spliced into its body.
replayOnlySpecWith :: [T.Text] -> T.Text
replayOnlySpecWith clauseLines =
  T.unlines $
    [ "context hospital-capacity",
      "",
      "id TransferReservationId prefix=rsv",
      "",
      "aggregate Reservation",
      "  regs",
      "    reservationId    TransferReservationId = placeholder",
      "    reservationState ReservationVertex     = Unrequested",
      "  states Unrequested Held",
      "",
      "  command RequestTransferReservation { reservationId }",
      "",
      "  event TransferReservationCreated = fields(RequestTransferReservation)",
      "",
      "  replay-only Unrequested -- RequestTransferReservation -->"
    ]
      ++ clauseLines

diffFixtures :: FilePath -> FilePath -> IO [Change]
diffFixtures oldP newP = do
  old <- parsedSourceOf oldP
  new <- parsedSourceOf newP
  pure (diffSources old new)

kindOfChange :: Change -> ChangeKind
kindOfChange (Additive kind) = kind
kindOfChange (Advisory kind) = kind
kindOfChange (Breaking kind) = kind

generatedHaskellNameFindings :: [Change] -> [Change]
generatedHaskellNameFindings = filter ((== GeneratedHaskellNameChanged) . (.code) . kindOfChange)

assertGeneratedHaskellNameFinding :: Change -> Expectation
assertGeneratedHaskellNameFinding change = do
  change `shouldSatisfy` isAdvisory
  let kind = kindOfChange change
      compatibility = kind.vector
      nonBuildVerdicts =
        [ verdictFor surface compatibility
        | surface <- [PrivateHistoryRead, OldBinaryReadNewEvents, SnapshotHydration, PublicConsumer, PersistedIdentity]
        ]
  nonBuildVerdicts `shouldBe` replicate 5 VCompatible
  verdictFor ConsumerBuild compatibility `shouldBe` VAdvisory
  (.rollout) compatibility `shouldBe` Set.empty
  renderFinding change `shouldSatisfy` T.isInfixOf "consumer-build=advisory"
  remediationFor (kind.context) ((.code) kind)
    `shouldBe` RemedyRescaffoldGenerated :| [RemedyRecompileConsumers, RemedyRunConformance]

labelOfChange :: Change -> Label
labelOfChange Additive {} = LabelAdditive
labelOfChange Advisory {} = LabelAdvisory
labelOfChange Breaking {} = LabelBreaking

genSurfaceSet :: Gen (Set.Set CompatibilitySurface)
genSurfaceSet = Set.fromList <$> listOf (elements [minBound .. maxBound])

genCompatibilityVector :: Gen CompatibilityVector
genCompatibilityVector =
  CompatibilityVector
    <$> genVerdict
    <*> genVerdict
    <*> genVerdict
    <*> genVerdict
    <*> genVerdict
    <*> genVerdict
    <*> (Set.fromList <$> listOf (elements rolloutConstraints))
  where
    genVerdict = elements [VCompatible, VAdvisory, VBreaking, VNotApplicable]
    rolloutConstraints =
      [ RolloutStopTheWorld,
        RolloutWorkersFirst,
        RolloutDrainRequired,
        RolloutProducerLast,
        RolloutProducerFirst
      ]

replayImpactFixtures :: FilePath -> FilePath -> IO ReplayImpact
replayImpactFixtures oldPath newPath = do
  old <- checkedServiceOf oldPath
  new <- checkedServiceOf newPath
  pure (resolvedFold (ReplayImpact.replayImpactServices old new))

modifyAggregate :: Name -> (Aggregate -> Aggregate) -> Spec -> Spec
modifyAggregate target update spec =
  specWithNodes
    [ case node of
        NAggregate aggregate | aggregate.name == target -> NAggregate (update aggregate)
        _ -> node
    | node <- spec.nodes
    ]
    spec

modifyReadModel :: Name -> (ReadModelNode -> ReadModelNode) -> Spec -> Spec
modifyReadModel target update spec =
  specWithNodes
    [ case node of
        NReadModel readModel | readModel.name == target -> NReadModel (update readModel)
        _ -> node
    | node <- spec.nodes
    ]
    spec

setLegacySubscription :: Maybe T.Text -> ReadModelSupply -> ReadModelSupply
setLegacySubscription subscription supply = case supply of
  legacy@LegacyReadModelSupply {} -> legacy {legacySubscription = subscription}
  OwnerDerivedSupply -> OwnerDerivedSupply

setLegacyScope :: Maybe RmScope -> ReadModelSupply -> ReadModelSupply
setLegacyScope scope supply = case supply of
  legacy@LegacyReadModelSupply {} -> legacy {legacyScope = scope}
  OwnerDerivedSupply -> OwnerDerivedSupply

setLegacyFeed :: RmFeed -> ReadModelSupply -> ReadModelSupply
setLegacyFeed feed supply = case supply of
  legacy@LegacyReadModelSupply {} -> legacy {legacyFeed = feed}
  OwnerDerivedSupply -> OwnerDerivedSupply

setLegacyConsistency :: Consistency -> ReadModelSupply -> ReadModelSupply
setLegacyConsistency consistency supply = case supply of
  legacy@LegacyReadModelSupply {} -> legacy {legacyConsistency = consistency}
  OwnerDerivedSupply -> OwnerDerivedSupply

mapContract :: (ContractNode -> ContractNode) -> Spec -> Spec
mapContract update spec =
  specWithNodes [case node of { NContract contract -> NContract (update contract); _ -> node } | node <- spec.nodes] spec

mapIntake :: (IntakeNode -> IntakeNode) -> Spec -> Spec
mapIntake update spec =
  specWithNodes [case node of { NIntake intake -> NIntake (update intake); _ -> node } | node <- spec.nodes] spec

mapPgmqDispatch :: (PgmqDispatchNode -> PgmqDispatchNode) -> Spec -> Spec
mapPgmqDispatch update spec =
  specWithNodes [case node of { NPgmqDispatch dispatch -> NPgmqDispatch (update dispatch); _ -> node } | node <- spec.nodes] spec

mapRouter :: (RouterNode -> RouterNode) -> Spec -> Spec
mapRouter update spec =
  specWithNodes [case node of { NRouter router -> NRouter (update router); _ -> node } | node <- spec.nodes] spec

mapEmit :: (EmitNode -> EmitNode) -> Spec -> Spec
mapEmit update spec =
  specWithNodes [case node of { NEmit emitNode -> NEmit (update emitNode); _ -> node } | node <- spec.nodes] spec

mapWorkflow :: (WorkflowNode -> WorkflowNode) -> Spec -> Spec
mapWorkflow update spec =
  specWithNodes [case node of { NWorkflow workflow -> NWorkflow (update workflow); _ -> node } | node <- spec.nodes] spec

mapWorkqueue :: (WorkqueueNode -> WorkqueueNode) -> Spec -> Spec
mapWorkqueue update spec =
  specWithNodes [case node of { NWorkqueue queue -> NWorkqueue (update queue); _ -> node } | node <- spec.nodes] spec

mapDispatch :: (PgmqDispatchNode -> PgmqDispatchNode) -> Spec -> Spec
mapDispatch update spec =
  mapPgmqDispatch update spec

mapOperation :: (OperationNode -> OperationNode) -> Spec -> Spec
mapOperation update spec =
  specWithNodes [case node of { NOperation operation -> NOperation (update operation); _ -> node } | node <- spec.nodes] spec

mapPublisher :: (PublisherNode -> PublisherNode) -> Spec -> Spec
mapPublisher update spec =
  specWithNodes [case node of { NPublisher publisher -> NPublisher (update publisher); _ -> node } | node <- spec.nodes] spec

serviceErrorCodes :: Int -> Spec -> [DiagnosticCode]
serviceErrorCodes versionNumber spec =
  [(.code) diagnostic | diagnostic <- validateService service, (.severity) diagnostic == Error]
  where
    service = case languageVersion (fromIntegral versionNumber) >>= effectiveLanguageContractForVersion of
      Nothing -> error ("unsupported test language version " <> show versionNumber)
      Just languageContract -> checkedServiceForContract languageContract spec

-- | Codes emitted at 'Warning' severity under the given released language.
-- Pairs with 'serviceErrorCodes' to assert a surface's warn-then-error tiering
-- from both sides, rather than only proving it is not an error.
serviceWarningCodes :: Int -> Spec -> [DiagnosticCode]
serviceWarningCodes versionNumber spec =
  [(.code) diagnostic | diagnostic <- validateService service, (.severity) diagnostic == Warning]
  where
    service = case languageVersion (fromIntegral versionNumber) >>= effectiveLanguageContractForVersion of
      Nothing -> error ("unsupported test language version " <> show versionNumber)
      Just languageContract -> checkedServiceForContract languageContract spec

duplicateFirst :: [a] -> [a]
duplicateFirst = \case
  [] -> []
  first : rest -> first : first : rest

updateFirst :: (a -> a) -> [a] -> [a]
updateFirst update = \case
  [] -> []
  first : rest -> update first : rest

removeReadModel :: Name -> Spec -> Spec
removeReadModel target spec =
  specWithNodes [node | node <- spec.nodes, not (isTarget node)] spec
  where
    isTarget (NReadModel readModel) = (.name) readModel == target
    isTarget _ = False

modifyRouter :: Name -> (RouterNode -> RouterNode) -> Spec -> Spec
modifyRouter target update spec =
  specWithNodes
    [ case node of
        NRouter router | router.id == target -> NRouter (update router)
        _ -> node
    | node <- spec.nodes
    ]
    spec

routerErrorCodes :: (RouterNode -> RouterNode) -> Spec -> [DiagnosticCode]
routerErrorCodes update = errorCodes . modifyRouter "PagingRouter" update

modifyProcess :: Name -> (ProcessNode -> ProcessNode) -> Spec -> Spec
modifyProcess target update spec =
  specWithNodes
    [ case node of
        NProcess process | process.id == target -> NProcess (update process)
        _ -> node
    | node <- spec.nodes
    ]
    spec

processErrorCodes :: (ProcessNode -> ProcessNode) -> Spec -> [DiagnosticCode]
processErrorCodes update = errorCodes . modifyProcess "HospitalSurge" update

errorCodes :: Spec -> [DiagnosticCode]
errorCodes spec = [(.code) diagnostic | diagnostic <- validateSpec spec, (.severity) diagnostic == Error]

diagnosticCodes :: Spec -> [DiagnosticCode]
diagnosticCodes = map (.code) . validateSpec

changeReadModelShape :: ReadModelNode -> ReadModelNode
changeReadModelShape readModel =
  readModel
    { columns = (.columns) readModel <> [RmColumn "reviewed_by" "text" False],
      shape = "fnv1a:0000000000000000"
    }

-- | Assert a @new \<kind\>@ skeleton parses and validates with zero
-- error-severity diagnostics.
assertSkeletonValid :: T.Text -> IO ()
assertSkeletonValid kind = case skeletonFor kind of
  Left err -> expectationFailure (T.unpack ("skeleton for " <> kind <> ": " <> err))
  Right src -> case parseSpec ("new:" <> T.unpack kind) src of
    Left perr -> expectationFailure (T.unpack ("skeleton for " <> kind <> " failed to parse: " <> perr))
    Right spec ->
      [(.code) d | d <- validateSpec spec, (.severity) d == Error]
        `shouldBe` ([] :: [DiagnosticCode])

assertSkeletonUsesAuthoringLanguage :: T.Text -> IO ()
assertSkeletonUsesAuthoringLanguage kind = case skeletonFor kind of
  Left err -> expectationFailure (T.unpack ("skeleton for " <> kind <> ": " <> err))
  Right source -> case parseSource ("new:" <> T.unpack kind) source of
    Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
    Right parsed -> do
      let service = checkedSource parsed
      (.contractLanguageVersion) (checkedLanguageContract service) `shouldBe` currentAuthoringLanguageVersion
      effectiveLanguageSupport (checkedLanguageContract service) `shouldBe` Stable
      [(.code) diagnostic | diagnostic <- validateService service, (.severity) diagnostic == Error]
        `shouldBe` ([] :: [DiagnosticCode])
      scaffoldServiceModules (defaultContext ((checkedSpec service).context)) service
        `shouldSatisfy` (not . null)

assertSkeletonScaffoldable :: T.Text -> IO ()
assertSkeletonScaffoldable kind = case skeletonFor kind of
  Left err -> expectationFailure (T.unpack ("skeleton for " <> kind <> ": " <> err))
  Right src -> case parseSpec ("new:" <> T.unpack kind) src of
    Left perr -> expectationFailure (T.unpack perr)
    Right spec -> planTestScaffold (defaultContext (spec.context)) spec `shouldSatisfy` isSuccessfulScaffold

bumpArtifactBindingVersion :: MappedDecl -> MappedDecl
bumpArtifactBindingVersion declaration@MappedStructural {msName = "ArtifactInfo"} =
  declaration {msBindingVersion = Just "2"}
bumpArtifactBindingVersion declaration = declaration

addArtifactSummaryField :: MappedDecl -> MappedDecl
addArtifactSummaryField declaration@MappedStructural {msName = "ArtifactInfo", msShape = ShapeRecord constructor unknownFields fields} =
  declaration
    { msShape =
        ShapeRecord
          constructor
          unknownFields
          ( fields
              <> [ WireField
                     { haskell = "summary",
                       key = "summary",
                       valueType = TText,
                       presence = PRequired,
                       onMissing = Nothing,
                       loc = Loc 0
                     }
                 ]
          )
    }
addArtifactSummaryField declaration = declaration

addAlphaPayloadOptionalField :: Spec -> Spec
addAlphaPayloadOptionalField = addMappedOptionalTextField "AlphaPayload" "note"

addNestedPayloadOptionalField :: Spec -> Spec
addNestedPayloadOptionalField = addMappedOptionalTextField "NestedPayload" "detail"

addMappedOptionalTextField :: Name -> Name -> Spec -> Spec
addMappedOptionalTextField target name spec = spec {mapped = map addField ((.mapped) spec)}
  where
    addField declaration@MappedStructural {msName = declarationName, msShape = ShapeRecord constructor unknownFields fields}
      | declarationName == target =
          declaration
            { msShape =
                ShapeRecord
                  constructor
                  unknownFields
                  ( fields
                      <> [ WireField
                             { haskell = name,
                               key = name,
                               valueType = TOptional TText,
                               presence = POptional,
                               onMissing = Just OmNull,
                               loc = Loc 0
                             }
                         ]
                  )
            }
    addField declaration = declaration

changeAlphaPayloadFixtureSymbol :: Spec -> Spec
changeAlphaPayloadFixtureSymbol spec = spec {mapped = map changeFixture ((.mapped) spec)}
  where
    changeFixture declaration@MappedStructural {msName = "AlphaPayload"} =
      declaration {msFixtures = Just "Example.SemanticLocality.Bindings.alphaPayloadV2Cases"}
    changeFixture declaration = declaration

mapWorkspaceSpec :: (Spec -> Spec) -> WorkspaceSpec -> WorkspaceSpec
mapWorkspaceSpec transform workspace =
  workspaceWithMembersAndMergedSpec
    [workspaceMemberWithSpec (transform member.spec) member | member <- workspace.members]
    (transform workspace.mergedSpec)
    workspace

expectGenericCompileFailure :: FilePath -> String -> Expectation
expectGenericCompileFailure fixture expectedDiagnostic = do
  let fixtureDir = "../keiro-core/test/compile-fail" </> fixture
      fixtureSource = fixtureDir </> "Fixture.hs"
  (exitCode, standardOutput, standardError) <-
    readProcessWithExitCode
      "cabal"
      [ "exec",
        "--",
        "ghc",
        "-XGHC2024",
        "-fno-code",
        "-fforce-recomp",
        "-i../keiro-core/src",
        "-i" <> fixtureDir,
        fixtureSource
      ]
      ""
  exitCode `shouldSatisfy` (/= ExitSuccess)
  let compilerOutput = standardOutput <> standardError
  compilerOutput `shouldContain` expectedDiagnostic
  compilerOutput `shouldContain` "Run keiro-dsl scaffold and fill the binding by hand at this error location in the scaffolded module."
  compilerOutput `shouldContain` fixtureSource

moveArtifactBindingIntoGenerated :: MappedDecl -> MappedDecl
moveArtifactBindingIntoGenerated declaration@MappedStructural {msName = "ArtifactInfo"} =
  declaration {msBinding = Just "Generated.ConsumerDemo.Bindings.artifactInfoBinding"}
moveArtifactBindingIntoGenerated declaration = declaration

removeMappedRegisterRequirements :: Spec -> Spec
removeMappedRegisterRequirements spec =
  spec
    { mapped = map removeInitial ((.mapped) spec),
      nodes = map removeRegisters ((.nodes) spec)
    }
  where
    removeInitial declaration@MappedStructural {} = declaration {msInitial = Nothing}
    removeInitial declaration@MappedOpaque {} = declaration {moInitial = Nothing}
    removeRegisters (NAggregate aggregate) =
      NAggregate
        aggregate
          { regs = [],
            transitions = [transition {writes = []} | transition <- (.transitions) aggregate]
          }
    removeRegisters node = node

isImportCycle :: Refusal -> Bool
isImportCycle ImportCycle {} = True
isImportCycle _ = False

isFoldSurfaceRefusal :: Either [Refusal] modules -> Bool
isFoldSurfaceRefusal (Left refusals) = any isFold refusals
  where
    isFold FoldSurfaceRefusal {} = True
    isFold _ = False
isFoldSurfaceRefusal (Right _) = False

-- | The canonical positive workspace fixture: three members under one context.
canonicalWorkspacePath :: FilePath
canonicalWorkspacePath = "test/fixtures/workspace/service.keiro-workspace"

-- | Deterministic workspace source used to model git blobs without invoking git.
memoryContentSource :: Map.Map FilePath T.Text -> ContentSource
memoryContentSource files =
  ContentSource
    { csRead = \path ->
        pure $ maybe (Left ("missing in-memory content: " <> T.pack path)) Right (Map.lookup path files)
    }

changeCode :: Change -> DiagnosticCode
changeCode (Additive kind) = (.code) kind
changeCode (Advisory kind) = (.code) kind
changeCode (Breaking kind) = (.code) kind

breakingSurfaces :: Change -> [CompatibilitySurface]
breakingSurfaces change =
  [ surface
  | surface <- [minBound .. maxBound],
    verdictFor surface (kind.vector) == VBreaking
  ]
  where
    kind = case change of
      Additive value -> value
      Advisory value -> value
      Breaking value -> value

workspaceChangeKind :: Change -> ChangeKind
workspaceChangeKind (Additive kind) = kind
workspaceChangeKind (Advisory kind) = kind
workspaceChangeKind (Breaking kind) = kind

-- | The same members as 'canonicalWorkspacePath', listed in reverse order.
reorderedWorkspacePath :: FilePath
reorderedWorkspacePath = "test/fixtures/workspace/service-reordered.keiro-workspace"

-- | Load and compose a workspace fixture, failing the test on a refusal. The
-- fixture path is package-relative; the loader is rooted at the manifest's own
-- directory, exactly as the CLI roots it.
shouldComposeWorkspace :: FilePath -> IO WorkspaceSpec
shouldComposeWorkspace path = do
  resolved <- resolveTestPath path
  loaded <- loadWorkspace (fileContentSource (takeDirectory resolved)) resolved
  case loaded of
    Left failure ->
      expectationFailure (T.unpack (T.intercalate "\n" (renderWorkspaceFailure resolved failure)))
        >> error "unreachable"
    Right workspace -> pure (workspaceWithManifestPath path workspace)

-- | The 'Context' a workspace scaffolds under, with no CLI overrides: the
-- members' unanimous name.context, the manifest's module-root and layout
-- authority, and the built-in defaults where the manifest is silent.
workspaceContext :: WorkspaceSpec -> Context
workspaceContext workspace =
  Context
    { name = workspace.context,
      moduleRoot = maybe "" id ((.moduleRoot) workspace),
      placement = maybe GeneratedPrefix id ((.layout) workspace)
    }

-- | Compose and plan a workspace fixture, failing the test on any refusal.
shouldPlanWorkspace :: FilePath -> IO WorkspacePlan
shouldPlanWorkspace path = do
  workspace <- shouldComposeWorkspace path
  case planWorkspaceScaffold "goldens" (workspaceContext workspace) workspace of
    Left refusals -> expectationFailure ("unexpected workspace plan refusal: " <> show refusals) >> error "unreachable"
    Right plan -> pure plan

-- | Does a scaffolded module's path end in this suffix?
isSuffixOfPath :: FilePath -> ScaffoldModule -> Bool
isSuffixOfPath suffix m = T.pack suffix `T.isSuffixOf` T.pack ((.path) m)

-- | A workspace record built from real composed data plus two synthetic
-- adoption rows, so the round-trip test exercises every row kind including the
-- JSON encodings shared with the v1 record.
sampleWorkspaceRecord :: WorkspaceSpec -> WorkspaceRecord
sampleWorkspaceRecord workspace =
  WorkspaceRecord
    { service = (.service) workspace,
      manifest = "service.keiro-workspace",
      context = workspace.context,
      moduleRoot = maybe "" id ((.moduleRoot) workspace),
      layout = "collocated",
      members = map (.path) ((.members) workspace),
      sourceLanguages =
        [ WorkspaceSourceLanguageRow ((.path) member) ((.sourceLanguage) member)
        | member <- (.members) workspace
        ],
      languageContract = (.languageContract) workspace,
      namingEdition = IdiomaticNamingV1,
      modules =
        [ WorkspaceModuleRow Generated "Demo/Generated/StructuralProjections.hs" Nothing Nothing,
          WorkspaceModuleRow Generated "Demo/Project/Generated/Domain.hs" (Just "domain/project.keiro") Nothing,
          WorkspaceModuleRow HoleStub "Demo/Project/Holes.hs" (Just "domain/shared.keiro") Nothing
        ],
      mappings = (.mappings) (consumerPlan ((.mergedSpec) workspace)),
      idDomains = [],
      nominalEqualities = nominalEqualityIdentities ((.mergedSpec) workspace),
      bindingObligations = either (const []) id (bindingHoles ((.mergedSpec) workspace)),
      requirements = [],
      projectionCatalogFacts = [],
      queryContractBaseline = True,
      queryContracts = either (const []) id (queryContractIdentities ((.mergedSpec) workspace)),
      routerSelections = [],
      adopted =
        [ AdoptedRow "claimed/One.hs" "record" (Just "keiro-dsl-ledger.context.demo-project.txt") (Just "project.keiro"),
          AdoptedRow "claimed/Two.hs" "banner" Nothing Nothing
        ],
      semanticImpact = Just (semanticImpactSnapshotForSpec ((.mergedSpec) workspace))
    }

semanticImpactSnapshotForSpec :: Spec -> SemanticImpactSnapshot
semanticImpactSnapshotForSpec = semanticImpactSnapshot . semanticImpactForSpec

semanticImpactForSpec :: Spec -> SemanticImpact
semanticImpactForSpec spec = case resolveTypeGraph spec of
  Left failures -> error ("test fixture type graph did not resolve: " <> show failures)
  Right graph -> semanticImpact graph

-- | Test-facing selection from the production semantic authority. This does
-- not walk the raw 'Spec' or reconstruct dependency edges.
data MappedSurfaceQualification = MappedSurfaceQualification
  { declaration :: !MappedKey,
    evidence :: !(Set.Set MappedRootEvidence),
    consumers :: !(Set.Set MappedConsumer),
    consequences :: !(Set.Set MappedConsequence)
  }
  deriving stock (Eq, Show)

qualifyMappedSurface :: SemanticImpact -> MappedKey -> MappedSurfaceQualification
qualifyMappedSurface impact key =
  MappedSurfaceQualification
    { declaration = key,
      evidence = Map.findWithDefault Set.empty key ((.declarationEvidence) impact),
      consumers = Map.findWithDefault Set.empty key ((.declarationConsumers) impact),
      consequences = Map.findWithDefault Set.empty key ((.declarationConsequences) impact)
    }

-- | The canonical workspace with a case-variant copy of one member's aggregate
-- grafted onto another member. Composition refuses this shape (EP-153 catches it
-- at the earliest boundary), so the planner's own cross-member collision gate can
-- only be exercised by constructing the graph directly — which is exactly what
-- this does, mirroring the single-file @caseVariant@ construction.
withCaseVariantAggregate :: WorkspaceSpec -> WorkspaceSpec
withCaseVariantAggregate workspace = case [aggregate | NAggregate aggregate <- (.nodes) merged, (.name) aggregate == "Project"] of
  [] -> error "canonical workspace fixture has no Project aggregate"
  aggregate : _ ->
    let shouted = aggregateWithName (T.toUpper aggregate.name) aggregate
        ownershipIndex = workspace.ownership
        mergedWithVariant = specWithNodes (merged.nodes <> [NAggregate shouted]) merged
        ownershipWithVariant =
          OwnershipIndex
            { declarations = ownershipIndex.declarations,
              nodes = Map.insert ("aggregate", shouted.name) ("domain/project-artifact.keiro", Loc 1) ownershipIndex.nodes
            }
     in workspaceWithMergedSpecAndOwnership mergedWithVariant ownershipWithVariant workspace
  where
    merged = (.mergedSpec) workspace

-- | Write a one-member workspace whose member declares an upcaster, so its
-- golden payload fixture has a canonical location. Returns the composed
-- workspace; the caller decides where the fixture lives.
writeGoldenWorkspace :: FilePath -> IO WorkspaceSpec
writeGoldenWorkspace root = do
  source <- readTestText "test/fixtures/reservation-v2.keiro"
  createDirectoryIfMissing True (root </> "domain")
  TIO.writeFile (root </> "domain/reservation.keiro") source
  let manifestPath = root </> "service.keiro-workspace"
  TIO.writeFile manifestPath "service gold-demo\nspec domain/reservation.keiro\n"
  loaded <- loadWorkspace (fileContentSource root) manifestPath
  case loaded of
    Left failure ->
      expectationFailure (T.unpack (T.intercalate "\n" (renderWorkspaceFailure manifestPath failure)))
        >> error "unreachable"
    Right workspace -> pure workspace

-- | Materialize the canonical fixture workspace in a fresh temporary directory
-- and hand the callback its root, a sibling output directory, and the composed
-- workspace. Working on a copy is what lets a test edit a member and re-scaffold.
--
-- The manifest's @spec@ lines are passed through the given function first, so a
-- caller can list the same members in a different order; the manifest __file
-- name__ stays the same, which is what makes two runs comparable byte for byte.
withWorkspaceFixture ::
  String ->
  ([FilePath] -> [FilePath]) ->
  (FilePath -> FilePath -> WorkspaceSpec -> IO a) ->
  IO a
withWorkspaceFixture template orderMembers act =
  withTempDirectory template $ \base -> do
    let root = base </> "workspace"
        out = base </> "out"
        members =
          [ "domain/project-artifact.keiro",
            "domain/project.keiro",
            "domain/shared.keiro"
          ]
    createDirectoryIfMissing True (root </> "domain")
    forM_ members $ \relative -> do
      source <- readTestText ("test/fixtures/workspace" </> relative)
      TIO.writeFile (root </> relative) source
    TIO.writeFile
      (root </> "service.keiro-workspace")
      ( T.unlines
          ( ["service demo-project", "module Demo.Modules.Project", "layout collocated"]
              <> ["spec " <> T.pack relative | relative <- orderMembers members]
          )
      )
    workspace <- loadTempWorkspace root
    act root out workspace

withSemanticLocalityFixture ::
  String ->
  ([FilePath] -> [FilePath]) ->
  Int ->
  (FilePath -> FilePath -> WorkspaceSpec -> IO a) ->
  IO a
withSemanticLocalityFixture template orderMembers unrelatedCount act =
  withTempDirectory template $ \base -> do
    let root = base </> "workspace"
        out = base </> "out"
        members = ["domain/alpha.keiro", "domain/beta.keiro"]
    forM_ members $ \relative -> do
      source <- readTestText ("test/fixtures/semantic-locality" </> relative)
      let withUnrelated
            | relative == "domain/beta.keiro" = source <> unrelatedAggregatesSource unrelatedCount
            | otherwise = source
      writeFileWithParents (root </> relative) withUnrelated
    TIO.writeFile
      (root </> "service.keiro-workspace")
      (T.unlines ("service semantic-locality" : ["spec " <> T.pack relative | relative <- orderMembers members]))
    workspace <- loadTempWorkspace root
    act root out workspace

unrelatedAggregatesSource :: Int -> T.Text
unrelatedAggregatesSource count =
  T.unlines
    ( concat
        [ [ "",
            "aggregate Unrelated" <> suffix,
            "  regs",
            "    marker Bool = False",
            "  states Ready Done!",
            "  command SubmitUnrelated" <> suffix <> " { accepted:Bool }",
            "  event Unrelated" <> suffix <> "Submitted = fields(SubmitUnrelated" <> suffix <> ")",
            "  Ready -- SubmitUnrelated" <> suffix <> " --> guard cmd.accepted ; write marker := true ; emit Unrelated" <> suffix <> "Submitted ; goto Done"
          ]
        | index <- [1 .. count],
          let suffix = T.pack (show index)
        ]
    )

-- | Materialize an inline workspace — a manifest plus literal member sources —
-- in a fresh temporary directory, and hand the callback its root, a sibling output
-- directory, and the composed workspace.
withInlineWorkspace ::
  String ->
  (T.Text, [(FilePath, T.Text)]) ->
  (FilePath -> FilePath -> WorkspaceSpec -> IO a) ->
  IO a
withInlineWorkspace template (service, members) act =
  withTempDirectory template $ \base -> do
    let root = base </> "workspace"
        out = base </> "out"
    forM_ members $ \(relative, source) -> writeFileWithParents (root </> relative) source
    TIO.writeFile
      (root </> "service.keiro-workspace")
      ( T.unlines
          (("service " <> service) : ["spec " <> T.pack relative | (relative, _) <- members])
      )
    workspace <- loadTempWorkspace root
    act root out workspace

-- | Two independently valid members under one context. Each is a complete spec
-- that the pre-workspace single-file scaffolder accepts, which is what lets a test
-- reproduce the overwritten-record defect before adopting.
adoptionMembers :: (T.Text, [(FilePath, T.Text)])
adoptionMembers = ("adoption-demo", [("domain/a.keiro", adoptionMemberA), ("domain/b.keiro", adoptionMemberB)])

adoptionMemberA :: T.Text
adoptionMemberA =
  T.unlines
    [ "context adoption-demo",
      "",
      "aggregate Counter",
      "  regs",
      "    count Int = 0",
      "    state CounterVertex = Pending",
      "  states Pending Done!",
      "  command Bump { count:Int }",
      "  event CountBumped { count:Int }",
      "  Pending -- Bump --> emit CountBumped ; goto Done"
    ]

adoptionMemberB :: T.Text
adoptionMemberB =
  T.unlines
    [ "context adoption-demo",
      "",
      "aggregate Widget",
      "  regs",
      "    size Int = 0",
      "    state WidgetVertex = Draft",
      "  states Draft Shipped!",
      "  command Ship { size:Int }",
      "  event WidgetShipped { size:Int }",
      "  Draft -- Ship --> emit WidgetShipped ; goto Shipped"
    ]

writeFileWithParents :: FilePath -> T.Text -> IO ()
writeFileWithParents path contents = do
  createDirectoryIfMissing True (takeDirectory path)
  TIO.writeFile path contents

-- | Only the Haskell sources of a tree snapshot, dropping bookkeeping files.
haskellOnly :: [(FilePath, T.Text)] -> [(FilePath, T.Text)]
haskellOnly entries = [entry | entry@(path, _) <- entries, ".hs" `T.isSuffixOf` T.pack path]

-- | Compose a workspace that a test just wrote to disk.
loadTempWorkspace :: FilePath -> IO WorkspaceSpec
loadTempWorkspace root = do
  let manifestPath = root </> "service.keiro-workspace"
  loaded <- loadWorkspace (fileContentSource root) manifestPath
  case loaded of
    Left failure ->
      expectationFailure (T.unpack (T.intercalate "\n" (renderWorkspaceFailure manifestPath failure)))
        >> error "unreachable"
    Right workspace -> pure workspace

-- | Plan an already-composed workspace, failing the test on a refusal.
shouldPlanWorkspaceSpec :: WorkspaceSpec -> IO WorkspacePlan
shouldPlanWorkspaceSpec workspace =
  case planWorkspaceScaffold "goldens" (workspaceContext workspace) workspace of
    Left refusals -> expectationFailure ("unexpected workspace plan refusal: " <> show refusals) >> error "unreachable"
    Right plan -> pure plan

-- | Plan then execute a whole-workspace scaffold, failing loudly on either.
executePlannedWorkspaceScaffold :: FilePath -> WorkspaceSpec -> IO WorkspaceScaffoldReport
executePlannedWorkspaceScaffold out workspace = do
  plan <- shouldPlanWorkspaceSpec workspace
  result <- executeWorkspaceScaffold out False plan
  case result of
    Left refusals -> expectationFailure ("unexpected workspace execution refusal: " <> show refusals) >> error "unreachable"
    Right report -> pure report

-- | Rename one member's aggregate in place and recompose. Only the
-- @aggregate \<Name\>@ header is rewritten, so declarations that merely share the
-- prefix (@ProjectId@, @ProjectSummary@) are untouched.
renameMemberAggregate :: FilePath -> FilePath -> T.Text -> T.Text -> IO WorkspaceSpec
renameMemberAggregate root member from to = do
  source <- TIO.readFile (root </> member)
  TIO.writeFile (root </> member) (T.replace ("aggregate " <> from <> "\n") ("aggregate " <> to <> "\n") source)
  loadTempWorkspace root

-- | Move the @ProjectArtifact@ aggregate from the artifact member into the
-- project member, and recompose.
--
-- It is prepended, so the merged spec's node order — and therefore every emitted
-- byte, including the replay-audit assembly's aggregate list — is exactly what it
-- was. That isolates the change to ownership, which is the point of the test.
moveArtifactAggregate :: FilePath -> IO WorkspaceSpec
moveArtifactAggregate root = do
  artifact <- TIO.readFile (root </> "domain/project-artifact.keiro")
  project <- TIO.readFile (root </> "domain/project.keiro")
  case T.breakOn "aggregate ProjectArtifact" artifact of
    (kept, moved) | not (T.null moved) -> do
      TIO.writeFile (root </> "domain/project-artifact.keiro") kept
      TIO.writeFile
        (root </> "domain/project.keiro")
        (T.replace "aggregate Project\n" (moved <> "\naggregate Project\n") project)
      loadTempWorkspace root
    _ -> expectationFailure "artifact member has no ProjectArtifact aggregate" >> error "unreachable"

-- | Every regular file under a directory, as @(relative path, contents)@ sorted
-- by path — the comparison unit for "byte-identical output".
treeSnapshot :: FilePath -> IO [(FilePath, T.Text)]
treeSnapshot root = do
  exists <- doesDirectoryExist root
  if not exists then pure [] else sort <$> walk ""
  where
    walk relative = do
      entries <- listDirectory (root </> relative)
      fmap concat . forM (sort entries) $ \entry -> do
        let child = if null relative then entry else relative </> entry
        isDirectory <- doesDirectoryExist (root </> child)
        if isDirectory
          then walk child
          else do
            contents <- TIO.readFile (root </> child)
            pure [(child, contents)]

scaffoldRecordWithEdition :: GeneratedHaskellNamingEdition -> ScaffoldRecord -> ScaffoldRecord
scaffoldRecordWithEdition edition record = case record of
  ScaffoldRecord
    recordSpecPath
    recordModuleRoot
    recordLayout
    recordSourceLanguage
    recordLanguageContract
    _recordNamingEdition
    recordModuleRoles
    recordFiles
    recordMappings
    recordIdDomains
    recordNominalEqualities
    recordBindingObligations
    recordBehaviorRequirements
    recordProjectionCatalogFacts
    recordQueryContractBaseline
    recordQueryContracts
    recordRouterSelections
    recordSemanticImpact ->
      ScaffoldRecord
        recordSpecPath
        recordModuleRoot
        recordLayout
        recordSourceLanguage
        recordLanguageContract
        edition
        recordModuleRoles
        recordFiles
        recordMappings
        recordIdDomains
        recordNominalEqualities
        recordBindingObligations
        recordBehaviorRequirements
        recordProjectionCatalogFacts
        recordQueryContractBaseline
        recordQueryContracts
        recordRouterSelections
        recordSemanticImpact

copyTextTree :: FilePath -> FilePath -> IO ()
copyTextTree source destination =
  treeSnapshot source >>= mapM_ (\(relative, contents) -> writeFileWithParents (destination </> relative) contents)

thd3 :: (a, b, c) -> c
thd3 (_, _, value) = value

isPathCollision :: Refusal -> Bool
isPathCollision PathCollision {} = True
isPathCollision _ = False

isInfixOfString :: String -> String -> Bool
isInfixOfString needle haystack = T.isInfixOf (T.pack needle) (T.pack haystack)

-- | Load a workspace fixture expecting a compose refusal, and return it.
shouldRefuseWorkspace :: FilePath -> IO (NonEmpty WorkspaceDiagnostic)
shouldRefuseWorkspace path = do
  resolved <- resolveTestPath path
  loaded <- loadWorkspace (fileContentSource (takeDirectory resolved)) resolved
  case loaded of
    Left (WorkspaceRefused diagnostics) -> pure diagnostics
    Left other ->
      expectationFailure
        ("expected compose refusals, got:\n" <> T.unpack (T.intercalate "\n" (renderWorkspaceFailure resolved other)))
        >> error "unreachable"
    Right _ -> expectationFailure ("expected " <> path <> " to be refused") >> error "unreachable"

-- | Invoke the built @keiro-dsl@ executable. Fixture paths are resolved first,
-- so the test works whether it runs from the package directory or the repository
-- root.
runKeiroDsl :: [String] -> IO (ExitCode, String, String)
runKeiroDsl arguments = do
  resolved <- traverse resolveArgument arguments
  -- Cabal places build-tool dependencies on PATH for the test process. Invoke the
  -- exact packaged CLI directly so each example retains its process/stdio/exit-code
  -- boundary without paying for a fresh `cabal run` planning pass.
  readProcessWithExitCode "keiro-dsl" resolved ""
  where
    resolveArgument argument
      | "test/fixtures/" `isPrefixOfString` argument = resolveTestPath argument
      | otherwise = pure argument
    isPrefixOfString prefix value = take (length prefix) value == prefix

-- | The @spec@ field of a coverage report, i.e. what the report says it covers.
coverageSpecPath :: Value -> Maybe T.Text
coverageSpecPath value = case value of
  Aeson.Object fields -> case KeyMap.lookup "spec" fields of
    Just (Aeson.String path) -> Just path
    _ -> Nothing
  _ -> Nothing

decodeJsonValue :: FilePath -> IO Value
decodeJsonValue path = do
  decoded <- Aeson.eitherDecodeFileStrict path
  case decoded of
    Left err -> expectationFailure (path <> ": " <> err) >> fail "unreachable"
    Right value -> pure value

jsonField :: T.Text -> Value -> Maybe Value
jsonField name = \case
  Aeson.Object fields -> KeyMap.lookup (Key.fromText name) fields
  _ -> Nothing

-- | Order-preserving deduplication for comparing cited file sets.
nubOrd :: (Eq a) => [a] -> [a]
nubOrd = go []
  where
    go seen [] = reverse seen
    go seen (x : xs) = if x `elem` seen then go seen xs else go (x : seen) xs

-- | Parse a workspace manifest, failing the test on a refusal.
shouldParseManifest :: FilePath -> T.Text -> IO WorkspaceManifest
shouldParseManifest path source = case parseWorkspaceManifest path source of
  Left err -> expectationFailure (T.unpack err) >> error "unreachable"
  Right manifest -> pure manifest

-- | Generate a canonical workspace manifest. Members are drawn from a pool of
-- paths that are distinct even under case folding and are held sorted, which is
-- the invariant every parsed manifest satisfies.
genWorkspaceManifest :: Gen WorkspaceManifest
genWorkspaceManifest = do
  service <- elements ["demo-project", "mori", "kotei", "a1", "svc-2"]
  runtimePackage <- elements [Nothing, Just (RuntimePackageName "demo-core"), Just (RuntimePackageName "mori2")]
  moduleRoot <- elements [Nothing, Just "Demo", Just "Demo.Modules.Project"]
  layout <- elements [Nothing, Just GeneratedPrefix, Just CollocatedLeaf]
  chosen <-
    sublistOf
      [ "a.keiro",
        "d-e_f.keiro",
        "domain/b.keiro",
        "domain/sub/c.keiro",
        "x1.keiro"
      ]
      `suchThat` (not . null)
  pure
    WorkspaceManifest
      { service = service,
        serviceLoc = Loc 1,
        runtimePackage = runtimePackage,
        runtimePackageLoc = Loc 2,
        moduleRoot = moduleRoot,
        moduleRootLoc = Loc 2,
        layout = layout,
        layoutLoc = Loc 3,
        members = NE.fromList [WorkspaceMemberRef path (Loc 4) | path <- sort chosen]
      }

-- | Parse a fixture while retaining its released language contract.
parsedSourceOf :: FilePath -> IO ParsedSource
parsedSourceOf path = do
  input <- readTestText path
  case parseSource path input of
    Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
    Right parsed -> pure parsed

checkedServiceOf :: FilePath -> IO CheckedService
checkedServiceOf = fmap checkedSource . parsedSourceOf

renderFoldBaseline :: T.Text -> CheckedService -> T.Text
renderFoldBaseline fixture service =
  T.intercalate
    "\n\n"
    [ T.unlines
        ( [ "fixture=" <> fixture,
            "aggregate=" <> (.name) aggregate,
            "fingerprint=" <> aggregateFoldFingerprintForService service aggregate,
            "surface-begin"
          ]
            <> T.lines (aggregateFoldSurfaceForService service aggregate)
            <> ["surface-end"]
        )
    | NAggregate aggregate <- (.nodes) (checkedSpec service)
    ]

-- | Parse a fixture through the source-aware boundary and return its graph.
specOf :: FilePath -> IO Spec
specOf = fmap checkedSpec . checkedServiceOf

-- | Parse one fixture through the exact source-aware boundary and adapt it to
-- one-member workspace semantics without falling back to line-only provenance.
exactOneMemberWorkspaceOf :: FilePath -> IO (WorkspaceSpec, ParsedSourceDocument)
exactOneMemberWorkspaceOf path = do
  source <- readTestText path
  document <- case parseSourceDocument path source of
    Left failure -> expectationFailure (show failure) >> fail "unreachable"
    Right value -> pure value
  workspace <-
    either
      (\failure -> expectationFailure (show failure) >> fail "unreachable")
      pure
      (oneMemberParsedDocumentWorkspace path document)
  pure (workspace, document)

-- | Parse a fixture and scaffold its checked semantic service.
scaffoldFixture :: FilePath -> IO [ScaffoldModule]
scaffoldFixture path = do
  service <- checkedServiceOf path
  pure (scaffoldServiceModules (defaultContext ((checkedSpec service).context)) service)

legacyScaffoldProcessFixture :: FilePath -> IO [ScaffoldModule]
legacyScaffoldProcessFixture path = do
  spec <- specOf path
  pure $ concat [scaffoldProcess (ctx spec) process | NProcess process <- (.nodes) spec]
  where
    ctx spec = defaultContext (spec.context)

-- | Assert a freshly-scaffolded Generated module matches its committed copy
-- under test/conformance/ (whitespace-normalized). The committed copies are the
-- ones the keiro-dsl-conformance suite compiles, so this pins the live scaffolder
-- to known-compiling output.
assertMatchesCommitted :: ScaffoldModule -> IO ()
assertMatchesCommitted m = do
  let committedPath = "test/conformance/" <> (.path) m
  committed <- readTestText committedPath
  normalizeGenerated committed `shouldBe` normalizeGenerated ((.text) m)

normalizeGenerated :: T.Text -> (T.Text, [T.Text])
normalizeGenerated text =
  let (orderInsensitiveLines, body) = partition isOrderInsensitive (T.lines text)
   in (normalizeBody body, sort (map normalizeImport orderInsensitiveLines))
  where
    -- Compare the deterministic body exactly as before and imports/language
    -- pragmas as a sorted, whitespace-normalized list. Sorting tolerates
    -- formatter reordering while additions, removals, and renamed entries still
    -- fail the pin.
    isOrderInsensitive line = isImport line || "{-# LANGUAGE " `T.isPrefixOf` line
    normalizeBody =
      -- Fourmolu parenthesizes a single class constraint while the emitter's
      -- compact spelling remains valid Haskell.  Treat that formatter-only
      -- rewrite like the whitespace and comma placement normalized below.
      T.replace "(Show value) =>" "Show value =>"
        . T.replace "( " "("
        . T.replace " )" ")"
        . T.replace " , )" " )"
        . T.unwords
        . T.words
        . T.replace "}" " } "
        . T.replace "{" " { "
        . T.replace "]" " ] "
        . T.replace "[" " [ "
        . T.replace "," " , "
        . T.unlines
        . map normalizeBanner
    normalizeBanner line
      | isGeneratedBannerLine line = generatedBanner
      | otherwise = line
    normalizeImport line =
      let reordered = case T.words line of
            "import" : "qualified" : moduleName : rest -> T.unwords ("import" : moduleName : "qualified" : rest)
            wordsInImport -> T.unwords wordsInImport
          (prefix, explicit) = T.breakOn " (" reordered
       in if T.null explicit
            then prefix
            else
              let members =
                    sort
                      . map (T.replace " (" "(" . T.unwords . T.words)
                      . T.splitOn ","
                      . T.dropEnd 1
                      $ T.drop 2 explicit
               in prefix <> " (" <> T.intercalate "," members <> ")"
    isImport line = case T.words line of
      "import" : _ -> True
      _ -> False

-- | Locate and read a test fixture or committed conformance source regardless
-- of whether the suite was launched from the package directory or repo root.
readTestText :: FilePath -> IO T.Text
readTestText path = resolveTestPath path >>= TIO.readFile

assertMatchesGolden :: FilePath -> T.Text -> IO ()
assertMatchesGolden path actual = do
  resolved <- resolveTestPath path
  update <- lookupEnv "KEIRO_DSL_UPDATE_GOLDENS"
  if update == Just "1"
    then TIO.writeFile resolved (T.stripEnd actual <> "\n")
    else do
      golden <- TIO.readFile resolved
      T.stripEnd actual `shouldBe` T.stripEnd golden

-- | Locate a repo file regardless of the test process's current directory.
resolveTestPath :: FilePath -> IO FilePath
resolveTestPath rel = do
  override <- lookupEnv "KEIRO_DSL_TEST_ROOT"
  let candidates = [rel, "keiro-dsl" </> rel] <> maybe [] (\root -> [root </> rel]) override
  existing <- filterM doesFileExist candidates
  case existing of
    path : _ -> pure path
    [] ->
      fail $
        "unable to locate keiro-dsl test file "
          <> show rel
          <> "; tried "
          <> show candidates

leftContains :: T.Text -> Either T.Text a -> Bool
leftContains needle = \case
  Left err -> needle `T.isInfixOf` err
  Right _ -> False

mappedConsumerSurfaceSource :: IO T.Text
mappedConsumerSurfaceSource = do
  base <- readTestText "test/fixtures/consumer-types.keiro"
  pure $
    T.replace "language keiro-dsl 4" "language keiro-dsl 5" base
      <> T.unlines
        [ "",
          "workqueue ArtifactJobs {",
          "  queue logical = \"artifact-jobs\"",
          "  derive physical = \"artifact-jobs\"",
          "    dlq = \"artifact-jobs_dlq\"",
          "    table = \"q_artifact-jobs\"",
          "  payload ArtifactJob {",
          "    jobData -> \"payload\" : List (Optional ArtifactInfo)",
          "  }",
          "  retry maxRetries = 3 delay = 1s dlq = on",
          "  disposition {",
          "    storeFailure -> retry 1s",
          "    commandRejected -> ackOk",
          "    decodeFailure -> deadLetter",
          "    onCodecReject -> deadLetter",
          "  }",
          "}",
          "",
          "readmodel ArtifactLookup {",
          "  table = \"artifact_lookup\"",
          "  schema = \"public\"",
          "  columns {}",
          "  query input = ArtifactInfo",
          "  query result = Optional ArtifactLocation",
          "  version = 1",
          "  shape = \"fixture\"",
          "  freshness = immediate",
          "}"
        ]

changeProjectionMappedWire :: MappedDecl -> MappedDecl
changeProjectionMappedWire declaration@MappedOpaque {moCodecVersion = version} =
  declaration {moCodecVersion = fmap (<> "-changed") version}
changeProjectionMappedWire declaration@MappedStructural {msShape = ShapeUnion encoding arms} =
  declaration
    { msShape =
        ShapeUnion
          encoding
          ( case arms of
              [] -> []
              arm : remaining -> wireArmWithTag (arm.tag <> "-changed") arm : remaining
          )
    }
changeProjectionMappedWire declaration = declaration

projectionEventWithoutGeometry :: Spec -> Spec
projectionEventWithoutGeometry candidate =
  specWithNodes (map stripGeometry candidate.nodes) candidate
  where
    stripGeometry (NAggregate aggregate) =
      let artifactFields =
            [ field
            | command <- (.commands) aggregate,
              (.name) command == "ObserveArtifact",
              field <- (.fields) command,
              (.name) field == "artifact"
            ]
       in NAggregate
            aggregate
              { regs = filter ((/= "currentGeometry") . (.name)) ((.regs) aggregate),
                events = map (explicitArtifactEvent artifactFields) ((.events) aggregate),
                transitions = map stripGeometryWrite ((.transitions) aggregate)
              }
    stripGeometry node = node
    explicitArtifactEvent artifactFields event@Event {body = EventFromCommand commandName}
      | commandName == "ObserveArtifact" =
          eventWithBody (EventFields artifactFields) event
    explicitArtifactEvent _ event = event
    stripGeometryWrite transition = transition {writes = filter ((/= "currentGeometry") . fst) ((.writes) transition)}

parseInlineSpec :: FilePath -> T.Text -> IO Spec
parseInlineSpec sourceName src = case parseSpec sourceName src of
  Left err -> expectationFailure (T.unpack err) >> error "unreachable"
  Right spec -> pure spec

checkedServiceFromText :: FilePath -> T.Text -> IO CheckedService
checkedServiceFromText sourceName src = case parseSource sourceName src of
  Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> error "unreachable"
  Right parsed -> pure (checkedSource parsed)

parseStableRenderedSpec :: FilePath -> Spec -> Either T.Text Spec
parseStableRenderedSpec sourceName spec =
  case parseSource sourceName stableSource of
    Left failure -> Left (renderParseFailure failure)
    Right parsed -> Right (parsed.spec)
  where
    stableSource =
      "language keiro-dsl "
        <> T.pack (show (languageVersionNumber currentStableLanguageVersion))
        <> "\n"
        <> renderSpec spec

parseLanguage4RenderedSpec :: FilePath -> Spec -> Either T.Text Spec
parseLanguage4RenderedSpec sourceName spec =
  case parseSource sourceName language4Source of
    Left failure -> Left (renderParseFailure failure)
    Right parsed -> Right (parsed.spec)
  where
    language4Source = "language keiro-dsl 4\n" <> renderSpec spec

shouldParseStableRenderedSpec :: FilePath -> Spec -> IO Spec
shouldParseStableRenderedSpec sourceName spec =
  case parseStableRenderedSpec sourceName spec of
    Left failure -> expectationFailure (T.unpack failure) >> fail "unreachable"
    Right reparsed -> pure reparsed

shouldResolveTypeGraph :: Spec -> IO TypeGraph
shouldResolveTypeGraph spec = case resolveTypeGraph spec of
  Left errors -> expectationFailure ("type graph failed: " <> show errors) >> error "unreachable"
  Right graph -> pure graph

shouldResolveCoverage :: FilePath -> Spec -> IO Coverage.CoverageReport
shouldResolveCoverage path spec = case Coverage.coverageReport path spec of
  Left errors -> expectationFailure ("coverage graph failed: " <> show errors) >> error "unreachable"
  Right report -> pure report

withoutVendorGeometry :: Spec -> Spec
withoutVendorGeometry spec =
  spec
    { mapped = filter (not . isVendorGeometry) ((.mapped) spec),
      nodes = map stripNode ((.nodes) spec)
    }
  where
    isVendorGeometry MappedOpaque {moName = "VendorGeometry"} = True
    isVendorGeometry _ = False
    stripNode (NAggregate aggregate) =
      NAggregate
        aggregate
          { regs = filter ((/= TRef "VendorGeometry") . (.valueType)) ((.regs) aggregate),
            commands = map stripCommand ((.commands) aggregate),
            events = map stripEvent ((.events) aggregate)
          }
    stripNode node = node
    stripCommand command = commandWithFields (filter ((/= Just (TRef "VendorGeometry")) . (.valueType)) command.fields) command
    stripEvent event = eventWithBody (case event.body of EventFields fields -> EventFields (filter ((/= Just (TRef "VendorGeometry")) . (.valueType)) fields); body -> body) event

withMetadataJson :: Spec -> Spec
withMetadataJson spec = spec {mapped = map updateDeclaration ((.mapped) spec)}
  where
    updateDeclaration declaration@MappedStructural {msName = "ArtifactMetadata", msShape = ShapeRecord constructor unknownFields fields} =
      declaration
        { msShape =
            ShapeRecord
              constructor
              unknownFields
              [if field.haskell == "note" then wireFieldWithValueType TJson field else field | field <- fields]
        }
    updateDeclaration declaration = declaration

expressionTags :: TypeExprAlgebra [T.Text]
expressionTags =
  TypeExprAlgebra
    { onText = ["text"],
      onInt = ["int"],
      onInteger = ["integer"],
      onBool = ["bool"],
      onNatural = ["natural"],
      onTime = ["time"],
      onJson = ["json"],
      onOptional = ("optional" :),
      onList = ("list" :),
      onMap = ("map" :),
      onRef = \key -> ["ref:" <> unMappedKey key]
    }

hasTypeGraphError :: (TypeGraphError -> Bool) -> Either (NonEmpty TypeGraphError) TypeGraph -> Bool
hasTypeGraphError predicate = \case
  Left errors -> any predicate errors
  Right _ -> False

isRecursive :: TypeGraphError -> Bool
isRecursive TGRecursive {} = True
isRecursive _ = False

isUnresolved :: TypeGraphError -> Bool
isUnresolved TGUnresolvedRef {} = True
isUnresolved _ = False

mappedSpec :: [MappedDecl] -> Spec
mappedSpec declarations = Spec "mapped-test" Nothing Nothing [] [] [] [] declarations []

completeStructural :: Name -> MappedShape -> MappedDecl
completeStructural name shape =
  MappedStructural
    { msName = name,
      msHaskell = Just (HaskellSource "mapped-test" "Example.Mapped" name),
      msBinding = Just ("Example.Mapped." <> T.toLower name <> "Binding"),
      msBindingVersion = Just "1",
      msCanonical = Just ("example.mapped." <> name),
      msFixtures = Just ("Example.Mapped." <> T.toLower name <> "Cases"),
      msInitial = Nothing,
      msShape = shape,
      msLoc = noLoc
    }

recordShape :: [TypeExpr] -> MappedShape
recordShape types =
  ShapeRecord
    "MappedRecord"
    RejectUnknown
    [ WireField
        { haskell = "field" <> T.pack (show index),
          key = "field" <> T.pack (show index),
          valueType = valueType,
          presence = PRequired,
          onMissing = Nothing,
          loc = noLoc
        }
    | (index, valueType) <- zip [(1 :: Int) ..] types
    ]

mapArtifactField :: (WireField -> WireField) -> Spec -> Spec
mapArtifactField = mapArtifactNamedField "key"

mapArtifactNamedField :: Name -> (WireField -> WireField) -> Spec -> Spec
mapArtifactNamedField target transform spec = spec {mapped = map updateDeclaration ((.mapped) spec)}
  where
    updateDeclaration declaration@MappedStructural {msName = "ArtifactInfo", msShape = ShapeRecord constructor unknownFields fields} =
      declaration
        { msShape =
            ShapeRecord
              constructor
              unknownFields
              [if (.haskell) field == target then transform field else field | field <- fields]
        }
    updateDeclaration declaration = declaration

mapMappedStructural :: Name -> (MappedDecl -> MappedDecl) -> Spec -> Spec
mapMappedStructural target transform spec =
  spec
    { mapped =
        [ case declaration of
            MappedStructural {msName = name}
              | name == target -> transform declaration
            _ -> declaration
        | declaration <- (.mapped) spec
        ]
    }

renameRecordConstructor :: MappedShape -> MappedShape
renameRecordConstructor (ShapeRecord _ unknownFields fields) = ShapeRecord "ArtifactInfoV2" unknownFields fields
renameRecordConstructor shape = shape

renameMappedRecordConstructor :: MappedDecl -> MappedDecl
renameMappedRecordConstructor declaration@MappedStructural {msShape = shape} =
  declaration {msShape = renameRecordConstructor shape}
renameMappedRecordConstructor declaration = declaration

changeMappedCanonical :: MappedDecl -> MappedDecl
changeMappedCanonical declaration@MappedStructural {} =
  declaration {msCanonical = Just "example.artifact.ArtifactInfo.v2"}
changeMappedCanonical declaration = declaration

data MappedMutation = MappedMutation
  { mmCandidate :: !Spec,
    mmCode :: !DiagnosticCode,
    mmExpectedSubjects :: !(Set.Set T.Text)
  }
  deriving stock (Show)

mappedWireMutations :: Spec -> [MappedMutation]
mappedWireMutations spec = case resolveTypeGraph spec of
  Left _ -> []
  Right graph -> concatMap (uncurry (declarationMutations graph)) (zip [0 :: Int ..] ((.mapped) spec))
  where
    declarationMutations graph declarationIndex declaration = case declaration of
      MappedStructural {msName = declarationName, msShape = shape} -> case shape of
        ShapeRecord _ _ fields ->
          concat
            [ [ mutation
                  graph
                  declarationName
                  MappedWireKeyChanged
                  (fieldSubject (wireFieldWithKey (field.key <> "__mutated") field))
                  (mutateRecordField declarationIndex fieldIndex (\value -> wireFieldWithKey (value.key <> "__mutated") value) spec),
                mutation
                  graph
                  declarationName
                  MappedPresenceChanged
                  (fieldSubject field)
                  (mutateRecordField declarationIndex fieldIndex (\value -> wireFieldWithPresence (flipPresence value.presence) value) spec)
              ]
                <> [ mutation
                       graph
                       declarationName
                       defaultCode
                       (fieldSubject field)
                       (mutateRecordField declarationIndex fieldIndex (wireFieldWithOnMissing changedDefault) spec)
                   | oldDefault <- maybeToListTest ((.onMissing) field),
                     let (changedDefault, defaultCode) = mutateDefault oldDefault
                   ]
            | (fieldIndex, field) <- zip [0 :: Int ..] fields
            ]
        ShapeEnum entries ->
          [ mutation
              graph
              declarationName
              MappedEnumSpellingChanged
              (enumSubject (wireEnumWithTag (entry.tag <> "__mutated") entry))
              (mutateEnumEntry declarationIndex entryIndex (\value -> wireEnumWithTag (value.tag <> "__mutated") value) spec)
          | (entryIndex, entry) <- zip [0 :: Int ..] entries
          ]
        ShapeUnion _ arms ->
          [ mutation
              graph
              declarationName
              MappedArmTagChanged
              (armSubject (wireArmWithTag (arm.tag <> "__mutated") arm))
              (mutateUnionArm declarationIndex armIndex (\value -> wireArmWithTag (value.tag <> "__mutated") value) spec)
          | (armIndex, arm) <- zip [0 :: Int ..] arms
          ]
      MappedOpaque {moName = declarationName, moCodecVersion = version} ->
        [ mutation
            graph
            declarationName
            MappedOpaqueCodecChanged
            "codec"
            ( updateMappedAt
                declarationIndex
                ( \case
                    value@MappedOpaque {} -> value {moCodecVersion = fmap (<> "__mutated") version}
                    value -> value
                )
                spec
            )
        ]

    mutation graph declarationName diagnosticCode leaf candidate =
      MappedMutation
        { mmCandidate = candidate,
          mmCode = diagnosticCode,
          mmExpectedSubjects =
            Set.fromList
              [ renderUsePath path <> " " <> leaf
              | path <- usePaths graph declarationName
              ]
        }

fieldSubject :: WireField -> T.Text
fieldSubject field = ".field " <> (.haskell) field <> "[\"" <> (.key) field <> "\"]"

enumSubject :: WireEnum -> T.Text
enumSubject entry = ".enum " <> (.ctor) entry <> "[\"" <> (.tag) entry <> "\"]"

armSubject :: WireArm -> T.Text
armSubject arm = ".arm " <> (.ctor) arm <> "[\"" <> (.tag) arm <> "\"]"

flipPresence :: Presence -> Presence
flipPresence PRequired = POptional
flipPresence POptional = PRequired

mutateDefault :: OnMissing -> (Maybe OnMissing, DiagnosticCode)
mutateDefault = \case
  OmNull -> (Nothing, MappedDefaultRemoved)
  OmText value -> (Just (OmText (value <> "__mutated")), MappedDefaultChanged)
  OmInt value -> (Just (OmInt (value + 1)), MappedDefaultChanged)
  OmBool value -> (Just (OmBool (not value)), MappedDefaultChanged)
  OmEmptyList -> (Nothing, MappedDefaultRemoved)
  OmEmptyMap -> (Nothing, MappedDefaultRemoved)
  OmCtor constructor -> (Just (OmCtor (constructor <> "Mutated")), MappedDefaultChanged)

mutateRecordField :: Int -> Int -> (WireField -> WireField) -> Spec -> Spec
mutateRecordField declarationIndex fieldIndex transform =
  updateMappedAt declarationIndex $ \case
    declaration@MappedStructural {msShape = ShapeRecord constructor unknownFields fields} ->
      declaration {msShape = ShapeRecord constructor unknownFields (updateAt fieldIndex transform fields)}
    declaration -> declaration

mutateEnumEntry :: Int -> Int -> (WireEnum -> WireEnum) -> Spec -> Spec
mutateEnumEntry declarationIndex entryIndex transform =
  updateMappedAt declarationIndex $ \case
    declaration@MappedStructural {msShape = ShapeEnum entries} ->
      declaration {msShape = ShapeEnum (updateAt entryIndex transform entries)}
    declaration -> declaration

mutateUnionArm :: Int -> Int -> (WireArm -> WireArm) -> Spec -> Spec
mutateUnionArm declarationIndex armIndex transform =
  updateMappedAt declarationIndex $ \case
    declaration@MappedStructural {msShape = ShapeUnion encoding arms} ->
      declaration {msShape = ShapeUnion encoding (updateAt armIndex transform arms)}
    declaration -> declaration

updateMappedAt :: Int -> (MappedDecl -> MappedDecl) -> Spec -> Spec
updateMappedAt declarationIndex transform spec =
  spec {mapped = updateAt declarationIndex transform ((.mapped) spec)}

updateAt :: Int -> (a -> a) -> [a] -> [a]
updateAt target transform values =
  [if index == target then transform value else value | (index, value) <- zip [0 :: Int ..] values]

maybeToListTest :: Maybe a -> [a]
maybeToListTest = maybe [] pure

isAdditiveChange :: Change -> Bool
isAdditiveChange Additive {} = True
isAdditiveChange Advisory {} = False
isAdditiveChange Breaking {} = False

mappedIngredientMutations :: Spec -> [(Spec, DiagnosticCode)]
mappedIngredientMutations spec =
  [ (mapMappedStructural "ArtifactInfo" clearStructuralHaskell spec, MappedMissingIngredient),
    (mapMappedStructural "ArtifactInfo" clearStructuralBinding spec, MappedMissingIngredient),
    (mapMappedStructural "ArtifactInfo" clearStructuralBindingVersion spec, MappedMissingIngredient),
    (mapMappedStructural "ArtifactInfo" clearStructuralCanonical spec, MappedMissingIngredient),
    (mapMappedStructural "ArtifactInfo" clearStructuralFixtures spec, MappedMissingIngredient),
    (mapMappedStructural "ArtifactInfo" clearStructuralInitial spec, MappedMissingInitialValue),
    (mapMappedDeclaration "VendorGeometry" clearOpaqueHaskell spec, MappedMissingIngredient),
    (mapMappedDeclaration "VendorGeometry" clearOpaqueCodec spec, MappedMissingIngredient),
    (mapMappedDeclaration "VendorGeometry" clearOpaqueCodecVersion spec, MappedMissingIngredient),
    (mapMappedDeclaration "VendorGeometry" clearOpaqueFixtures spec, MappedMissingIngredient)
  ]
  where
    clearStructuralHaskell declaration@MappedStructural {} = declaration {msHaskell = Nothing}
    clearStructuralHaskell declaration = declaration
    clearStructuralBinding declaration@MappedStructural {} = declaration {msBinding = Nothing}
    clearStructuralBinding declaration = declaration
    clearStructuralBindingVersion declaration@MappedStructural {} = declaration {msBindingVersion = Nothing}
    clearStructuralBindingVersion declaration = declaration
    clearStructuralCanonical declaration@MappedStructural {} = declaration {msCanonical = Nothing}
    clearStructuralCanonical declaration = declaration
    clearStructuralFixtures declaration@MappedStructural {} = declaration {msFixtures = Nothing}
    clearStructuralFixtures declaration = declaration
    clearStructuralInitial declaration@MappedStructural {} = declaration {msInitial = Nothing}
    clearStructuralInitial declaration = declaration
    clearOpaqueHaskell declaration@MappedOpaque {} = declaration {moHaskell = Nothing}
    clearOpaqueHaskell declaration = declaration
    clearOpaqueCodec declaration@MappedOpaque {} = declaration {moCodecId = Nothing}
    clearOpaqueCodec declaration = declaration
    clearOpaqueCodecVersion declaration@MappedOpaque {} = declaration {moCodecVersion = Nothing}
    clearOpaqueCodecVersion declaration = declaration
    clearOpaqueFixtures declaration@MappedOpaque {} = declaration {moFixtures = Nothing}
    clearOpaqueFixtures declaration = declaration

mapMappedDeclaration :: Name -> (MappedDecl -> MappedDecl) -> Spec -> Spec
mapMappedDeclaration target transform spec =
  spec
    { mapped =
        [ if mappedDeclarationName declaration == target then transform declaration else declaration
        | declaration <- (.mapped) spec
        ]
    }

mappedDeclarationName :: MappedDecl -> Name
mappedDeclarationName MappedStructural {msName = name} = name
mappedDeclarationName MappedOpaque {moName = name} = name

statusMapSpec :: T.Text -> T.Text
statusMapSpec marker =
  T.unlines
    [ "context svc",
      "",
      "aggregate Thing",
      "  regs",
      "  states Open",
      "",
      "  event Created { }",
      "  event Changed { }",
      "",
      "  projection things consistency=Eventual key=thingId",
      "    status-map" <> marker <> " { Created=>held }"
    ]

parseErrorOf :: FilePath -> T.Text -> IO T.Text
parseErrorOf sourceName src = case parseSpec sourceName src of
  Left err -> pure err
  Right _ -> expectationFailure ("expected parse failure for " <> sourceName) >> error "unreachable"

duplicateGotoSpec :: T.Text
duplicateGotoSpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate Thing",
      "  regs",
      "  states A B C",
      "",
      "  command Go { }",
      "  A -- Go -->",
      "    goto B",
      "    goto C"
    ]

missingGotoSpec :: T.Text
missingGotoSpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate Thing",
      "  regs",
      "  states A B",
      "",
      "  command Go { }",
      "  A -- Go -->",
      "    emit Changed"
    ]

duplicateWireSpec :: T.Text
duplicateWireSpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate Thing",
      "  regs",
      "  states Open",
      "",
      "  wire kind=ctorName fields=camelCase schemaVersion=1",
      "  wire kind=typeName fields=snakeCase schemaVersion=2"
    ]

duplicateProjectionSpec :: T.Text
duplicateProjectionSpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate Thing",
      "  regs",
      "  states Open",
      "",
      "  projection first consistency=Strong key=thingId",
      "    status-map partial { }",
      "  projection second consistency=Eventual key=thingId"
    ]

projectionWithoutConsistencySpec :: T.Text
projectionWithoutConsistencySpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate Thing",
      "  regs",
      "  states Open",
      "",
      "  projection things key=thingId"
    ]

malformedRegisterSpec :: T.Text
malformedRegisterSpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate Thing",
      "  regs",
      "    status Status",
      "  states Open"
    ]

misplacedDispatchIdSpec :: T.Text
misplacedDispatchIdSpec =
  T.replace
    "    schedule timer\n\n  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)\n"
    "    dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)\n    schedule timer\n"
    (renderSpec (Spec "svc" Nothing Nothing [] [] [] [] [] [NProcess (processWithLiteral "literal")]))

lineNumberContaining :: T.Text -> T.Text -> Int
lineNumberContaining needle = go 1 . T.lines
  where
    go current = \case
      [] -> current
      lineText : rest
        | needle `T.isInfixOf` lineText -> current
        | otherwise -> go (current + 1) rest

decimalOverflow :: T.Text
decimalOverflow = "18446744073709551617"

decimalOverflowSpecs :: [(String, T.Text)]
decimalOverflowSpecs =
  [ ("event-version", eventVersionDecimalSpec decimalOverflow),
    ("wire-schema", wireDecimalSpec decimalOverflow),
    ("contract-schema", contractDecimalSpec decimalOverflow),
    ("decode-schema", decodeDecimalSpec decimalOverflow),
    ("publisher-attempts", publisherDecimalSpec decimalOverflow),
    ("workqueue-retries", workqueueDecimalSpec decimalOverflow),
    ("timer-attempts", timerDecimalSpec decimalOverflow)
  ]

eventVersionDecimalSpec :: T.Text -> T.Text
eventVersionDecimalSpec value =
  T.unlines
    [ "context svc",
      "",
      "aggregate Thing",
      "  regs",
      "  states Open",
      "",
      "  event Changed v" <> value <> " { }"
    ]

wireDecimalSpec :: T.Text -> T.Text
wireDecimalSpec value =
  T.unlines
    [ "context svc",
      "",
      "aggregate Thing",
      "  regs",
      "  states Open",
      "",
      "  wire kind=ctorName fields=camelCase schemaVersion=" <> value
    ]

contractDecimalSpec :: T.Text -> T.Text
contractDecimalSpec value =
  T.unlines
    [ "context svc",
      "",
      "contract Contract {",
      "  schemaVersion " <> value,
      "  discriminator kind",
      "}"
    ]

decodeDecimalSpec :: T.Text -> T.Text
decodeDecimalSpec value =
  T.unlines
    [ "context svc",
      "",
      "intake Inbox {",
      "  contract Contract",
      "  topic events",
      "  accept Event",
      "  dedupe key messageId policy PreferIntegrationMessageId",
      "  decode { envelope strict-required lenient-optional body strict schemaVersion == " <> value <> " }",
      "  disposition { }",
      "}"
    ]

publisherDecimalSpec :: T.Text -> T.Text
publisherDecimalSpec value =
  T.unlines
    [ "context svc",
      "",
      "publisher Publisher {",
      "  emit Emit",
      "  ordering PerKeyHeadOfLine",
      "  maxAttempts " <> value,
      "  backoff constant 2s",
      "  outboxId stable from messageId",
      "}"
    ]

workqueueDecimalSpec :: T.Text -> T.Text
workqueueDecimalSpec value =
  T.unlines
    [ "context svc",
      "",
      "workqueue Queue {",
      "  queue logical = \"queue\"",
      "  derive physical = \"queue\"",
      "    dlq = \"queue_dlq\"",
      "    table = \"pgmq.q_queue\"",
      "  payload Job { }",
      "  retry maxRetries = " <> value <> " delay = 5s dlq = on",
      "  disposition { }",
      "}"
    ]

timerDecimalSpec :: T.Text -> T.Text
timerDecimalSpec value =
  T.replace
    "max-attempts 5"
    ("max-attempts " <> value)
    (renderSpec (Spec "svc" Nothing Nothing [] [] [] [] [] [NProcess (processWithLiteral "literal")]))

identifierHygieneSpec :: T.Text
identifierHygieneSpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate thing",
      "  regs",
      "  states Open",
      "",
      "  command DoIt { data }"
    ]

vertexCollisionSpec :: T.Text
vertexCollisionSpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate Reservation",
      "  regs",
      "  states Created",
      "",
      "  event ReservationCreated { }"
    ]

underscoreNodeSpec :: T.Text
underscoreNodeSpec =
  T.unlines
    [ "context svc",
      "",
      "contract _contract {",
      "  schemaVersion 1",
      "  discriminator kind",
      "}"
    ]

normalizedCollisionSpec :: T.Text
normalizedCollisionSpec =
  T.unlines
    [ "context svc",
      "",
      "contract fooBar {",
      "  schemaVersion 1",
      "  discriminator kind",
      "}",
      "",
      "contract foo_bar {",
      "  schemaVersion 1",
      "  discriminator kind",
      "}"
    ]

unicodeIdentifierSpec :: T.Text
unicodeIdentifierSpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate Résumé",
      "  regs",
      "  states Open"
    ]

emptyStatesSpec :: Spec
emptyStatesSpec =
  Spec
    "svc"
    Nothing
    Nothing
    []
    []
    []
    []
    []
    [NAggregate (Aggregate "Thing" [] [] [] [] [] Nothing [] Nothing Nothing Nothing noLoc)]

crossFamilyBoundarySpec :: T.Text
crossFamilyBoundarySpec =
  T.unlines
    [ "context svc",
      "",
      "aggregate First",
      "  regs",
      "  states A B",
      "  command Go { }",
      "  A -- Go -->",
      "    emit Changed",
      "    goto B",
      "",
      "emit Output {",
      "  contract Contract",
      "  topic events",
      "  source \"source\"",
      "  key thingId",
      "  map status { _ => skip }",
      "  messageId derive hole",
      "  idempotencyKey derive hole",
      "}",
      "",
      "aggregate Second",
      "  regs",
      "  states",
      "",
      "dispatch QueueDispatch {",
      "  source readModel = source key = thingId",
      "  fanout body = resolveFanout",
      "  dedup key = thingId",
      "    seenIn readModel = seen field = thingId",
      "    seenIn queue = workQueue field = thingId",
      "  enqueue to = workQueue",
      "}"
    ]

--------------------------------------------------------------------------------
-- Generators (bounded; restricted to valid, non-reserved identifiers)
--------------------------------------------------------------------------------

-- | Text that exercises every supported escape plus notation punctuation that
-- used to be able to split one emit-map row into several rows.
genAdversarialText :: Gen T.Text
genAdversarialText =
  T.concat
    <$> resize
      20
      (listOf (elements ["a", "Z", "\"", "\\", "\n", "\t", "\r", "=>", "#", "{", "}", " "]))

-- | One spec carrying the same adversarial value through three distinct
-- printer paths: a contract topic, an emit-map value, and a quote-wrapped
-- field-binding literal.
escapedSpec :: T.Text -> Spec
escapedSpec value =
  Spec
    "escape"
    Nothing
    Nothing
    []
    []
    []
    []
    []
    [ NContract
        ContractNode
          { name = "Contract",
            schemaVersion = 1,
            discriminator = "kind",
            topics = [("events", value)],
            events = [],
            loc = noLoc
          },
      NEmit
        EmitNode
          { name = "Emit",
            contract = "Contract",
            topic = "events",
            source = "source",
            key = "key",
            discriminant = "status",
            map = [EmitMapRow value "Event" noLoc],
            skip = True,
            messageId = DeriveSpec Nothing,
            idempotencyKey = DeriveSpec Nothing,
            loc = noLoc
          },
      NProcess (processWithLiteral value)
    ]

processWithLiteral :: T.Text -> ProcessNode
processWithLiteral value =
  ProcessNode
    { id = "Process",
      name = "process",
      input = InputDecl "Input" [] Nothing noLoc,
      correlate = CorrelateDecl "key" "idText",
      saga = SagaRef "Saga" "saga",
      target = "Target",
      projections = [],
      handle =
        HandleNode
          { on = "Input",
            advance = AdvanceNode "Advance" [FieldBinding "literal" (Just ("\"" <> value <> "\""))],
            dispatch = [],
            schedule = "timer"
          },
      rejected = PolHalt,
      poison = PolHalt,
      timer =
        TimerNode
          { name = "timer",
            id = IdExpr UuidV5Id "timer:" "correlationId",
            fireAt = FireAtExpr "observedAt" "5m",
            payload = [],
            fire =
              FireNode
                { target = "Target",
                  key = "correlationId",
                  command = "Fire",
                  fields = [],
                  firedEventId = IdExpr UuidV5Id "fired:" "correlationId",
                  disposition = FireDisposition OFired OFired ORetry ORetry ORetry
                },
            decodeUnknown = "Cancelled",
            maxAttempts = 5,
            deadLetter = "exhausted",
            loc = noLoc
          },
      loc = noLoc
    }

genName :: Gen Name
genName =
  frequency
    [ ( 3,
        do
          base <- elements ["Aa", "Bb", "Cc", "Dd", "St", "Cmd", "Ev", "Reg", "Fld", "Foo", "Bar", "Qux"]
          n <- choose (0, 9 :: Int)
          pure (T.pack (base <> show n))
      ),
      (1, elements ["data1", "typeA", "whereX", "gotoX", "guardY", "emitZ", "_lead"])
    ]

genWire :: Gen T.Text
genWire = do
  base <- elements ["red", "blue", "green", "ctorName", "camelCase", "rsv", "hosp", "held", "partial-divert", "1st"]
  n <- choose (0, 9 :: Int)
  pure (T.pack (base <> show n))

genWireWord :: Gen T.Text
genWireWord = genWire

smallList :: Gen a -> Gen [a]
smallList g = choose (0, 3 :: Int) >>= \n -> vectorOf n g

nonEmptyList :: Gen a -> Gen [a]
nonEmptyList g = choose (1, 3 :: Int) >>= \n -> vectorOf n g

genMaybe :: Gen a -> Gen (Maybe a)
genMaybe g = oneof [pure Nothing, Just <$> g]

genCmp :: Gen CmpOp
genCmp = elements [OpEq, OpNeq, OpLt, OpLe, OpGt, OpGe]

genAtom :: Gen Expr
genAtom = EAtom <$> oneof [AName <$> genName, ABool <$> arbitrary]

genExpr :: Gen Expr
genExpr = go (3 :: Int)
  where
    go 0 = genAtom
    go d =
      oneof
        [ genAtom,
          EOr <$> go (d - 1) <*> go (d - 1),
          EAnd <$> go (d - 1) <*> go (d - 1),
          ECmp <$> genCmp <*> go (d - 1) <*> go (d - 1)
        ]

genField :: Gen Field
genField = Field <$> genName <*> oneof [pure Nothing, Just <$> genName]

genAggregateField :: Gen AggregateField
genAggregateField = AggregateField <$> genName <*> pure Nothing <*> pure Nothing <*> genMaybe (genTypeExpr []) <*> pure noLoc

genReg :: Gen RegDecl
genReg = RegDecl <$> genName <*> genTypeExpr [] <*> genRegInitial <*> pure noLoc

genRegInitial :: Gen RegInitial
genRegInitial = oneof [RegInitBare <$> genName, RegInitText <$> genAdversarialText]

genState :: Gen StateDecl
genState = StateDecl <$> genName <*> arbitrary <*> pure noLoc

genCommand :: Gen Command
genCommand = Command <$> genName <*> smallList genAggregateField <*> pure noLoc

genEvent :: Gen Event
genEvent = do
  name <- genName
  eventBody <- body
  version <- choose (1, 3)
  upcast <- genMaybe ((,) <$> choose (0, 3) <*> pure Hole)
  (retiring, deprecated) <- elements [(False, False), (True, False), (False, True)]
  pure
    Event
      { name = name,
        body = eventBody,
        version = version,
        upcastFrom = upcast,
        retiring = retiring,
        deprecated = deprecated,
        loc = noLoc
      }
  where
    body = oneof [EventFromCommand <$> genName, EventFields <$> smallList genAggregateField]

genTransition :: Gen Transition
genTransition =
  Transition
    <$> genName
    <*> genName
    <*> pure LegacyHoleImplementation
    <*> genMaybe genExpr
    <*> smallList ((,) <$> genName <*> genExpr)
    <*> smallList genName
    <*> pure Nothing
    <*> pure []
    <*> genName
    <*> elements [TmLive, TmReplayOnly]
    <*> pure noLoc

genWireSpec :: Gen WireSpec
genWireSpec = WireSpec <$> genWire <*> genWire <*> (getNonNegative <$> arbitrary)

genProjection :: Gen ProjectionSpec
genProjection =
  ProjectionSpec
    <$> genName
    <*> genMaybe (elements [Strong, Eventual])
    <*> genName
    <*> genMaybe (Mapping <$> smallList ((,) <$> genName <*> genWire) <*> arbitrary)
    <*> pure noLoc

genAggregate :: Gen Aggregate
genAggregate =
  Aggregate
    <$> genName
    <*> smallList genReg
    <*> smallList genState
    <*> smallList genCommand
    <*> smallList genEvent
    <*> smallList genTransition
    <*> pure Nothing
    <*> pure []
    <*> genMaybe genWireSpec
    <*> genMaybe genProjection
    <*> genMaybe (SnapshotSpec <$> oneof [SnapEvery <$> choose (0, 5), pure SnapOnTerminal] <*> choose (0, 5) <*> genAdversarialText <*> pure noLoc)
    <*> pure noLoc

genDottedRef :: Gen T.Text
genDottedRef = elements ["input.id", "input.hospitalId", "timer.id", "correlationId", "payload.messageId"]

genWindow :: Gen T.Text
genWindow = elements ["0s", "5s", "2m", "1h"]

genFieldBinding :: Gen FieldBinding
genFieldBinding =
  FieldBinding
    <$> genName
    <*> oneof
      [ pure Nothing,
        Just <$> genDottedRef,
        Just . (\raw -> "\"" <> raw <> "\"") <$> genAdversarialText
      ]

genDispatchDisposition :: Gen DispatchDisposition
genDispatchDisposition = DispatchDisposition <$> genDisp <*> genDisp <*> genDisp
  where
    genDisp = oneof [pure DAckOk, pure DRetry, DDeadLetter <$> genAdversarialText]

genDispatchNode :: Gen DispatchNode
genDispatchNode =
  DispatchNode
    <$> genName
    <*> genDottedRef
    <*> genName
    <*> smallList genFieldBinding
    <*> genDispatchDisposition
    <*> pure noLoc

genFireDisposition :: Gen FireDisposition
genFireDisposition =
  FireDisposition
    <$> elements [OFired, ORetry]
    <*> elements [OFired, ORetry]
    <*> elements [OFired, ORetry]
    <*> elements [OFired, ORetry]
    <*> elements [OFired, ORetry]

genIdExpr :: Gen IdExpr
genIdExpr = IdExpr UuidV5Id <$> genAdversarialText <*> pure "correlationId"

genFireNode :: Gen FireNode
genFireNode =
  FireNode
    <$> genName
    <*> genDottedRef
    <*> genName
    <*> smallList genFieldBinding
    <*> genIdExpr
    <*> genFireDisposition

genTimerNode :: Gen TimerNode
genTimerNode =
  TimerNode
    <$> genName
    <*> genIdExpr
    <*> (FireAtExpr <$> genName <*> genWindow)
    <*> smallList genFieldBinding
    <*> genFireNode
    <*> genName
    <*> choose (0, 5)
    <*> genAdversarialText
    <*> pure noLoc

genProcess :: Gen ProcessNode
genProcess =
  ProcessNode
    <$> genName
    <*> genAdversarialText
    <*> (InputDecl <$> genName <*> smallList genField <*> pure Nothing <*> pure noLoc)
    <*> (CorrelateDecl <$> genName <*> genName)
    <*> (SagaRef <$> genName <*> genAdversarialText)
    <*> genName
    <*> smallList genName
    <*> (HandleNode <$> genName <*> (AdvanceNode <$> genName <*> smallList genFieldBinding) <*> smallList genDispatchNode <*> genName)
    <*> elements [PolHalt, PolDeadLetter, PolSkip]
    <*> elements [PolHalt, PolDeadLetter, PolSkip]
    <*> genTimerNode
    <*> pure noLoc

genResolveSource :: Gen ResolveSource
genResolveSource = oneof [ResolveReadModel <$> genName, pure ResolveHole]

genRouter :: Gen RouterNode
genRouter =
  RouterNode
    <$> genName
    <*> genAdversarialText
    <*> (InputDecl <$> genName <*> smallList genField <*> pure Nothing <*> pure noLoc)
    <*> (CorrelateDecl <$> genName <*> genName)
    <*> (ResolveDecl <$> genResolveSource <*> smallList genName <*> pure noLoc)
    <*> genName
    <*> smallList genName
    <*> (RouterDispatchNode <$> genName <*> smallList genFieldBinding <*> genDispatchDisposition <*> pure noLoc)
    <*> elements [PolHalt, PolDeadLetter, PolSkip]
    <*> elements [PolHalt, PolDeadLetter, PolSkip]
    <*> pure noLoc

genContractField :: Gen ContractField
genContractField = ContractField <$> genName <*> pure Nothing <*> pure Nothing <*> oneof [CTypeId <$> genAdversarialText, pure CText, pure CInt] <*> pure noLoc

genContractEvent :: Gen ContractEvent
genContractEvent = ContractEvent <$> genName <*> genName <*> smallList genContractField

genContract :: Gen ContractNode
genContract =
  ContractNode
    <$> genName
    <*> choose (0, 5)
    <*> genName
    <*> smallList ((,) <$> genName <*> genAdversarialText)
    <*> smallList genContractEvent
    <*> pure noLoc

genWireSource :: Gen WireSource
genWireSource = oneof [SrcHeader <$> genAdversarialText, pure SrcBody, pure SrcKafkaKey, pure SrcKafkaCursor]

genInboxAction :: Gen InboxAction
genInboxAction = oneof [pure IAckOk, IRetry <$> genWindow, IDeadLetter <$> genMaybe genAdversarialText]

genDispositionRow :: Gen DispositionRow
genDispositionRow = DispositionRow <$> genName <*> genInboxAction <*> pure noLoc

genDecodeSpec :: Gen DecodeSpec
genDecodeSpec =
  DecodeSpec
    <$> ((\first second -> first <> " " <> second) <$> genWireWord <*> genWireWord)
    <*> arbitrary
    <*> choose (0, 5)

genIntake :: Gen IntakeNode
genIntake =
  IntakeNode
    <$> genName
    <*> genName
    <*> genName
    <*> nonEmptyList genName
    <*> smallList (BindRow <$> genName <*> genWireSource <*> arbitrary <*> arbitrary)
    <*> genName
    <*> genName
    <*> elements [InkPersistFull, InkPersistDedupeOnly]
    <*> genDecodeSpec
    <*> smallList genDispositionRow
    <*> pure noLoc

genDeriveSpec :: Gen DeriveSpec
genDeriveSpec = DeriveSpec <$> genMaybe genAdversarialText

genEmit :: Gen EmitNode
genEmit =
  EmitNode
    <$> genName
    <*> genName
    <*> genName
    <*> genAdversarialText
    <*> genName
    <*> genName
    <*> smallList (EmitMapRow <$> genAdversarialText <*> genName <*> pure noLoc)
    <*> arbitrary
    <*> genDeriveSpec
    <*> genDeriveSpec
    <*> pure noLoc

genPublisher :: Gen PublisherNode
genPublisher =
  PublisherNode
    <$> genName
    <*> genName
    <*> genName
    <*> choose (0, 5)
    <*> (BackoffSpec <$> genName <*> genWindow <*> genMaybe genWindow <*> genMaybe (elements ["1.0", "2.0", "3"]))
    <*> genName
    <*> pure noLoc

genWqField :: Gen WqField
genWqField = WqField <$> genName <*> genAdversarialText <*> (LegacyQueueScalar . QueueOther <$> genName) <*> pure noLoc

genWqDispRow :: Gen WqDispRow
genWqDispRow = WqDispRow <$> genName <*> genInboxAction <*> pure noLoc

genWorkqueue :: Gen WorkqueueNode
genWorkqueue =
  WorkqueueNode
    <$> genName
    <*> genAdversarialText
    <*> genAdversarialText
    <*> genAdversarialText
    <*> genAdversarialText
    <*> elements [WqUnordered, WqFifoThroughput, WqFifoRoundRobin]
    <*> genMaybe (WqGroupKey <$> genName <*> genName <*> genMaybe genAdversarialText)
    <*> oneof [pure WqStandard, pure WqUnlogged, WqPartitioned <$> genAdversarialText <*> genAdversarialText]
    <*> genName
    <*> smallList genWqField
    <*> choose (0, 5)
    <*> genWindow
    <*> arbitrary
    <*> smallList genWqDispRow
    <*> pure noLoc

genReadModel :: Gen ReadModelNode
genReadModel = do
  consistency <- elements [Strong, Eventual]
  scope <- genMaybe (oneof [pure RmEntireLog, RmCategory <$> genAdversarialText])
  feed <- elements [RmInline, RmSubscription]
  subscription <- genMaybe genAdversarialText
  ReadModelNode
    <$> genName
    <*> nonEmptyText
    <*> nonEmptyText
    <*> smallList (RmColumn <$> genWireWord <*> genName <*> arbitrary)
    <*> choose (0, 5)
    <*> genAdversarialText
    <*> pure (case consistency of Eventual -> FreshnessImmediate; Strong -> FreshnessWaitForHead (maybe RmEntireLog id scope))
    <*> pure (LegacyReadModelSupply consistency scope feed subscription)
    <*> pure Nothing
    <*> pure []
    <*> pure Nothing
    <*> pure Nothing
    <*> pure noLoc
  where
    nonEmptyText = genAdversarialText `suchThat` (not . T.null)

genPgmqDispatch :: Gen PgmqDispatchNode
genPgmqDispatch =
  PgmqDispatchNode
    <$> genName
    <*> genName
    <*> genName
    <*> genName
    <*> genName
    <*> genName
    <*> genName
    <*> genName
    <*> genName
    <*> genName
    <*> pure noLoc

genWfBodyItem :: Gen WfBodyItem
genWfBodyItem = sized go
  where
    go size =
      oneof $
        [ WfStep <$> genWireWord <*> genName <*> pure noLoc,
          WfAwait <$> genWireWord <*> genName <*> pure noLoc,
          WfSleep <$> genWireWord <*> genName <*> pure noLoc,
          WfChild <$> genWireWord <*> genName <*> genName <*> pure noLoc,
          WfContinueAsNew <$> genName <*> pure noLoc
        ]
          ++ [ WfPatch <$> genWireWord <*> resize (size `div` 2) (smallList genWfBodyItem) <*> pure noLoc
             | size > 0
             ]

genWorkflow :: Gen WorkflowNode
genWorkflow =
  WorkflowNode
    <$> genName
    <*> genAdversarialText
    <*> genName
    <*> smallList genField
    <*> genName
    <*> genMaybe genName
    <*> genName
    <*> smallList genWfBodyItem
    <*> pure noLoc

genOperationShape :: Gen OperationShape
genOperationShape =
  oneof
    [ CommandOp <$> genName <*> genName <*> genName <*> smallList genName,
      QueryOp <$> genName <*> genName <*> ((\parts -> T.unwords parts) <$> nonEmptyList genName) <*> genName,
      SignalOp <$> genWireWord <*> genName <*> genName <*> genName <*> genName,
      RunOp <$> genName <*> genName <*> genName
    ]

genOperation :: Gen OperationNode
genOperation = OperationNode <$> genName <*> genOperationShape <*> pure noLoc

allNodeTags :: [String]
allNodeTags = ["aggregate", "process", "router", "contract", "intake", "emit", "publisher", "workqueue", "pgmq-dispatch", "readmodel", "workflow", "operation"]

nodeTag :: Node -> String
nodeTag = \case
  NAggregate _ -> "aggregate"
  NProcess _ -> "process"
  NRouter _ -> "router"
  NContract _ -> "contract"
  NIntake _ -> "intake"
  NEmit _ -> "emit"
  NPublisher _ -> "publisher"
  NWorkqueue _ -> "workqueue"
  NPgmqDispatch _ -> "pgmq-dispatch"
  NReadModel _ -> "readmodel"
  NProjectionTarget _ -> "projection-target"
  NRebuildGroup _ -> "rebuild-group"
  NProjectionRevision _ -> "projection-revision"
  NExternalRead _ -> "external-read"
  NProjectionOwner _ -> "projection-owner"
  NWorkflow _ -> "workflow"
  NOperation _ -> "operation"

consumerNominalFor :: Name -> NominalOwnership
consumerNominalFor name =
  ConsumerNominal
    ConsumerNominalBinding
      { haskell = HaskellSource "domain" "Domain.Types" name,
        binding = QualifiedValueName "Domain.Bindings.binding",
        bindingVersion = BindingVersion "1",
        canonical = CanonicalTypeId ("domain." <> name <> ".v1"),
        fixtures = QualifiedValueName "Domain.Bindings.fixtures",
        initial = Just (QualifiedValueName "Domain.Bindings.initialValue")
      }

genId :: Gen IdDecl
genId = IdDecl <$> genName <*> genWire <*> pure Nothing <*> pure noLoc

genEnum :: Gen EnumDecl
genEnum = EnumDecl <$> genName <*> smallList ((,) <$> genName <*> genWire) <*> pure Nothing <*> pure noLoc

genRule :: Gen RuleDecl
genRule =
  RuleDecl
    <$> genName
    <*> genName
    <*> genName
    <*> nonEmptyList ((,) <$> genName <*> genExpr)
    <*> pure noLoc

genMappedDecls :: Gen [MappedDecl]
genMappedDecls = do
  count <- choose (0, 4 :: Int)
  let names = take count ["MappedA", "MappedB", "MappedC", "MappedD"]
  traverse (genMappedDecl names) names

genMappedDecl :: [Name] -> Name -> Gen MappedDecl
genMappedDecl names name =
  oneof
    [ MappedStructural name
        <$> genMaybe genHaskellSource
        <*> genMaybe genAdversarialText
        <*> genMaybe genAdversarialText
        <*> genMaybe genAdversarialText
        <*> genMaybe genAdversarialText
        <*> genMaybe genAdversarialText
        <*> genMappedShape names
        <*> pure noLoc,
      MappedOpaque name
        <$> genMaybe genHaskellSource
        <*> genMaybe genAdversarialText
        <*> genMaybe genAdversarialText
        <*> genMaybe genAdversarialText
        <*> genMaybe genAdversarialText
        <*> pure noLoc
    ]

genHaskellSource :: Gen HaskellSource
genHaskellSource =
  HaskellSource
    <$> genWire
    <*> genModuleRoot
    <*> genName

genMappedShape :: [Name] -> Gen MappedShape
genMappedShape names =
  oneof
    [ ShapeRecord
        <$> genName
        <*> elements [RejectUnknown, IgnoreUnknown]
        <*> smallList (genWireField names),
      ShapeEnum <$> smallList (WireEnum <$> genName <*> genAdversarialText <*> pure noLoc),
      ShapeUnion
        <$> (TaggedObject <$> genAdversarialText <*> genAdversarialText <*> elements [RejectUnknown, IgnoreUnknown])
        <*> smallList (WireArm <$> genName <*> genAdversarialText <*> genMaybe (genTypeExpr names) <*> pure noLoc)
    ]

genWireField :: [Name] -> Gen WireField
genWireField names =
  WireField
    <$> genName
    <*> genAdversarialText
    <*> genTypeExpr names
    <*> elements [PRequired, POptional]
    <*> genMaybe genOnMissing
    <*> pure noLoc

genTypeExpr :: [Name] -> Gen TypeExpr
genTypeExpr names = sized (go . min 3)
  where
    go 0 = base
    go depth =
      frequency
        [ (4, base),
          (1, TOptional <$> go (depth - 1)),
          (1, TList <$> go (depth - 1)),
          (1, TMap <$> go (depth - 1))
        ]
    -- This generator renders through the unversioned/version-1 grammar. Keep
    -- successor-only Integer coverage in the dedicated version-2 properties.
    base = elements ([TText, TInt, TBool, TNatural, TTime, TJson] ++ map TRef names)

genOnMissing :: Gen OnMissing
genOnMissing =
  oneof
    [ pure OmNull,
      OmText <$> genAdversarialText,
      OmInt <$> choose (-10, 10),
      OmBool <$> arbitrary,
      pure OmEmptyList,
      pure OmEmptyMap,
      OmCtor <$> genName
    ]

genSpec :: Gen Spec
genSpec = do
  name <- genWire
  moduleRoot <- genMaybe genModuleRoot
  layout <- genMaybe (elements [GeneratedPrefix, CollocatedLeaf])
  ids <- smallList genId
  enums <- smallList genEnum
  rules <- smallList genRule
  mapped <- genMappedDecls
  nodes <- smallList genNode
  pure (Spec name moduleRoot layout ids enums rules [] mapped nodes)
  where
    genNode =
      oneof
        [ NAggregate <$> genAggregate,
          NProcess <$> genProcess,
          NRouter <$> genRouter,
          NContract <$> genContract,
          NIntake <$> genIntake,
          NEmit <$> genEmit,
          NPublisher <$> genPublisher,
          NWorkqueue <$> genWorkqueue,
          NPgmqDispatch <$> genPgmqDispatch,
          NReadModel <$> genReadModel,
          NWorkflow <$> genWorkflow,
          NOperation <$> genOperation
        ]

-- | A dotted PascalCase module prefix, e.g. @Acme@ or @Acme.Services@.
genModuleRoot :: Gen T.Text
genModuleRoot = do
  n <- choose (1, 3 :: Int)
  segs <- vectorOf n (elements ["Acme", "Services", "Hospital", "Domain", "Core"])
  pure (T.intercalate "." segs)

assertGeneratedHaskellContract :: T.Text -> T.Text -> Expectation
assertGeneratedHaskellContract sourceName manifest =
  take 13 (T.lines manifest)
    `shouldBe` [ "-- keiro-dsl build manifest for " <> sourceName,
                 "-- Paste the complete fragment below into the consuming Cabal stanza.",
                 "-- The generated layer is overwritten on every scaffold; hole modules are",
                 "-- create-if-absent (filled by hand).",
                 "",
                 "default-language: GHC2024",
                 "default-extensions:",
                 "    DuplicateRecordFields",
                 "    NoFieldSelectors",
                 "    OverloadedRecordDot",
                 "    OverloadedStrings",
                 "",
                 "other-modules:"
               ]

workspaceWithMembers :: [WorkspaceMember] -> WorkspaceSpec -> WorkspaceSpec
workspaceWithMembers members workspace =
  WorkspaceSpec
    { service = workspace.service,
      manifestPath = workspace.manifestPath,
      languageContract = workspace.languageContract,
      context = workspace.context,
      runtimePackage = workspace.runtimePackage,
      moduleRoot = workspace.moduleRoot,
      layout = workspace.layout,
      members = members,
      mergedSpec = workspace.mergedSpec,
      sourceIndex = workspace.sourceIndex,
      lineMap = workspace.lineMap,
      ownership = workspace.ownership
    }

specWithNodes :: [Node] -> Spec -> Spec
specWithNodes nodes (Spec contextName moduleRoot layout ids enums rules nominalScalars mapped _) =
  Spec contextName moduleRoot layout ids enums rules nominalScalars mapped nodes

specWithContext :: Name -> Spec -> Spec
specWithContext contextName (Spec _ moduleRoot layout ids enums rules nominalScalars mapped nodes) =
  Spec contextName moduleRoot layout ids enums rules nominalScalars mapped nodes

specWithMapped :: [MappedDecl] -> Spec -> Spec
specWithMapped mapped (Spec contextName moduleRoot layout ids enums rules nominalScalars _ nodes) =
  Spec contextName moduleRoot layout ids enums rules nominalScalars mapped nodes

specWithNominalScalars :: [NominalScalarDecl] -> Spec -> Spec
specWithNominalScalars nominalScalars (Spec contextName moduleRoot layout ids enums rules _ mapped nodes) =
  Spec contextName moduleRoot layout ids enums rules nominalScalars mapped nodes

specWithIds :: [IdDecl] -> Spec -> Spec
specWithIds ids (Spec contextName moduleRoot layout _ enums rules nominalScalars mapped nodes) =
  Spec contextName moduleRoot layout ids enums rules nominalScalars mapped nodes

specWithIdsAndNodes :: [IdDecl] -> [Node] -> Spec -> Spec
specWithIdsAndNodes ids nodes (Spec contextName moduleRoot layout _ enums rules nominalScalars mapped _) =
  Spec contextName moduleRoot layout ids enums rules nominalScalars mapped nodes

contractNodeWithEvents :: [ContractEvent] -> ContractNode -> ContractNode
contractNodeWithEvents events (ContractNode name schemaVersion discriminator topics _ loc) =
  ContractNode name schemaVersion discriminator topics events loc

commandWithFields :: [AggregateField] -> Command -> Command
commandWithFields fields (Command name _ loc) = Command name fields loc

contractEventWithFields :: [ContractField] -> ContractEvent -> ContractEvent
contractEventWithFields fields (ContractEvent name topic _) = ContractEvent name topic fields

contractEventWithTopic :: Name -> ContractEvent -> ContractEvent
contractEventWithTopic topic (ContractEvent name _ fields) = ContractEvent name topic fields

contractFieldWithName :: Name -> ContractField -> ContractField
contractFieldWithName name (ContractField _ selector wireKey valueType loc) =
  ContractField name selector wireKey valueType loc

bindRowWithField :: Name -> BindRow -> BindRow
bindRowWithField field (BindRow _ source required crossCheck) = BindRow field source required crossCheck

wireSpecWithKind :: T.Text -> WireSpec -> WireSpec
wireSpecWithKind kind (WireSpec _ fields schemaVersion) = WireSpec kind fields schemaVersion

wireSpecWithSchemaVersion :: Int -> WireSpec -> WireSpec
wireSpecWithSchemaVersion schemaVersion (WireSpec kind fields _) = WireSpec kind fields schemaVersion

wqDispRowWithAction :: InboxAction -> WqDispRow -> WqDispRow
wqDispRowWithAction action (WqDispRow outcome _ loc) = WqDispRow outcome action loc

dispositionRowWithAction :: InboxAction -> DispositionRow -> DispositionRow
dispositionRowWithAction action (DispositionRow outcome _ loc) = DispositionRow outcome action loc

bindRowWithSource :: WireSource -> BindRow -> BindRow
bindRowWithSource source (BindRow field _ required crossCheck) = BindRow field source required crossCheck

dispatchDispositionWithOnAppended :: Disp -> DispatchDisposition -> DispatchDisposition
dispatchDispositionWithOnAppended onAppended (DispatchDisposition _ onDuplicate onFailed) =
  DispatchDisposition onAppended onDuplicate onFailed

dispatchNodeWithDisposition :: DispatchDisposition -> DispatchNode -> DispatchNode
dispatchNodeWithDisposition disposition (DispatchNode target key command fields _ loc) =
  DispatchNode target key command fields disposition loc

dispatchNodeWithKey :: T.Text -> DispatchNode -> DispatchNode
dispatchNodeWithKey key (DispatchNode target _ command fields disposition loc) =
  DispatchNode target key command fields disposition loc

fieldBindingWithValue :: Maybe T.Text -> FieldBinding -> FieldBinding
fieldBindingWithValue value (FieldBinding name _) = FieldBinding name value

projectionSpecWithKey :: Name -> ProjectionSpec -> ProjectionSpec
projectionSpecWithKey key (ProjectionSpec table consistency _ statusMap loc) =
  ProjectionSpec table consistency key statusMap loc

eventWithNameAndLoc :: Name -> Loc -> Event -> Event
eventWithNameAndLoc name loc (Event _ body version upcastFrom retiring deprecated _) =
  Event name body version upcastFrom retiring deprecated loc

eventWithBody :: EventBody -> Event -> Event
eventWithBody body (Event name _ version upcastFrom retiring deprecated loc) =
  Event name body version upcastFrom retiring deprecated loc

contextWithModuleRoot :: T.Text -> Context -> Context
contextWithModuleRoot moduleRoot (Context name _ placement) = Context name moduleRoot placement

workspaceMemberWithSpec :: Spec -> WorkspaceMember -> WorkspaceMember
workspaceMemberWithSpec spec (WorkspaceMember path _ sourceLanguage sourceIndex lineBase lineCount) =
  WorkspaceMember path spec sourceLanguage sourceIndex lineBase lineCount

workspaceWithMembersAndMergedSpec :: [WorkspaceMember] -> Spec -> WorkspaceSpec -> WorkspaceSpec
workspaceWithMembersAndMergedSpec members mergedSpec workspace =
  WorkspaceSpec
    workspace.service
    workspace.manifestPath
    workspace.languageContract
    workspace.context
    workspace.runtimePackage
    workspace.moduleRoot
    workspace.layout
    members
    mergedSpec
    workspace.sourceIndex
    workspace.lineMap
    workspace.ownership

workspaceWithMergedSpecAndOwnership :: Spec -> OwnershipIndex -> WorkspaceSpec -> WorkspaceSpec
workspaceWithMergedSpecAndOwnership mergedSpec ownership workspace =
  WorkspaceSpec
    workspace.service
    workspace.manifestPath
    workspace.languageContract
    workspace.context
    workspace.runtimePackage
    workspace.moduleRoot
    workspace.layout
    workspace.members
    mergedSpec
    workspace.sourceIndex
    workspace.lineMap
    ownership

workspaceWithOwnership :: OwnershipIndex -> WorkspaceSpec -> WorkspaceSpec
workspaceWithOwnership ownership workspace =
  workspaceWithMergedSpecAndOwnership workspace.mergedSpec ownership workspace

workspaceWithAuthority :: T.Text -> Maybe T.Text -> Maybe Placement -> WorkspaceSpec -> WorkspaceSpec
workspaceWithAuthority service moduleRoot layout workspace =
  WorkspaceSpec
    service
    workspace.manifestPath
    workspace.languageContract
    workspace.context
    workspace.runtimePackage
    moduleRoot
    layout
    workspace.members
    workspace.mergedSpec
    workspace.sourceIndex
    workspace.lineMap
    workspace.ownership

workspaceWithContextAndMergedSpec :: Name -> Spec -> WorkspaceSpec -> WorkspaceSpec
workspaceWithContextAndMergedSpec contextName mergedSpec workspace =
  WorkspaceSpec
    workspace.service
    workspace.manifestPath
    workspace.languageContract
    contextName
    workspace.runtimePackage
    workspace.moduleRoot
    workspace.layout
    workspace.members
    mergedSpec
    workspace.sourceIndex
    workspace.lineMap
    workspace.ownership

workspaceWithManifestPath :: FilePath -> WorkspaceSpec -> WorkspaceSpec
workspaceWithManifestPath manifestPath workspace =
  WorkspaceSpec
    workspace.service
    manifestPath
    workspace.languageContract
    workspace.context
    workspace.runtimePackage
    workspace.moduleRoot
    workspace.layout
    workspace.members
    workspace.mergedSpec
    workspace.sourceIndex
    workspace.lineMap
    workspace.ownership

aggregateWithName :: Name -> Aggregate -> Aggregate
aggregateWithName name (Aggregate _ regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

aggregateWithProjection :: Maybe ProjectionSpec -> Aggregate -> Aggregate
aggregateWithProjection projection (Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire _ snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

aggregateWithTransitions :: [Transition] -> Aggregate -> Aggregate
aggregateWithTransitions transitions (Aggregate name regs states commands events _ domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

aggregateWithRegs :: [RegDecl] -> Aggregate -> Aggregate
aggregateWithRegs regs (Aggregate name _ states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

aggregateWithNameAndRegs :: Name -> [RegDecl] -> Aggregate -> Aggregate
aggregateWithNameAndRegs name regs (Aggregate _ _ states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

aggregateWithCommands :: [Command] -> Aggregate -> Aggregate
aggregateWithCommands commands (Aggregate name regs states _ events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

aggregateWithStates :: [StateDecl] -> Aggregate -> Aggregate
aggregateWithStates states (Aggregate name regs _ commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

aggregateWithCommandsEventsTransitions :: [Command] -> [Event] -> [Transition] -> Aggregate -> Aggregate
aggregateWithCommandsEventsTransitions commands events transitions (Aggregate name regs states _ _ _ domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

aggregateWithWire :: Maybe WireSpec -> Aggregate -> Aggregate
aggregateWithWire wire (Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs _ projection snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

regDeclWithInitial :: RegInitial -> RegDecl -> RegDecl
regDeclWithInitial initial (RegDecl name valueType _ loc) = RegDecl name valueType initial loc

regDeclWithValueType :: TypeExpr -> RegDecl -> RegDecl
regDeclWithValueType valueType (RegDecl name _ initial loc) = RegDecl name valueType initial loc

idDeclWithBinding :: Maybe NominalBindingDecl -> IdDecl -> IdDecl
idDeclWithBinding binding (IdDecl name prefix _ loc) = IdDecl name prefix binding loc

nominalBindingWithVersion :: Maybe T.Text -> NominalBindingDecl -> NominalBindingDecl
nominalBindingWithVersion bindingVersion (NominalBindingDecl haskell binding _ canonicalType fixtures initial loc) =
  NominalBindingDecl haskell binding bindingVersion canonicalType fixtures initial loc

transitionWithGuard :: Maybe Expr -> Transition -> Transition
transitionWithGuard guard (Transition source command implementation _ writes emits outcome outcomeDuplicateLocs goto mode loc) =
  Transition source command implementation guard writes emits outcome outcomeDuplicateLocs goto mode loc

transitionWithEmits :: [Name] -> Transition -> Transition
transitionWithEmits emits (Transition source command implementation guard writes _ outcome outcomeDuplicateLocs goto mode loc) =
  Transition source command implementation guard writes emits outcome outcomeDuplicateLocs goto mode loc

projectionOwnerWithReplay :: ProjectionReplayPolicy -> ProjectionOwnerNode -> ProjectionOwnerNode
projectionOwnerWithReplay replay (ProjectionOwnerNode name sources delivery group targets order subscription dedup checkpointOnMissing _ loc) =
  ProjectionOwnerNode name sources delivery group targets order subscription dedup checkpointOnMissing replay loc

readModelWithObservedTargets :: [Name] -> ReadModelNode -> ReadModelNode
readModelWithObservedTargets observedTargets (ReadModelNode name table schema columns version shape freshness supply group _ backingTarget queryTypes loc) =
  ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc

readModelWithGroupAndObservedTargets :: Maybe Name -> [Name] -> ReadModelNode -> ReadModelNode
readModelWithGroupAndObservedTargets group observedTargets (ReadModelNode name table schema columns version shape freshness supply _ _ backingTarget queryTypes loc) =
  ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc

readModelWithQueryTypes :: Maybe ReadModelQueryTypes -> ReadModelNode -> ReadModelNode
readModelWithQueryTypes queryTypes (ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget _ loc) =
  ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc

workqueueWithPayload :: [WqField] -> WorkqueueNode -> WorkqueueNode
workqueueWithPayload payload (WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName _ maxRetries delay dlqOn disposition loc) =
  WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn disposition loc

workqueueWithName :: Name -> WorkqueueNode -> WorkqueueNode
workqueueWithName name (WorkqueueNode _ logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn disposition loc) =
  WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn disposition loc

workqueueWithPayloadName :: Name -> WorkqueueNode -> WorkqueueNode
workqueueWithPayloadName payloadName (WorkqueueNode name logical physical dlq table ordering groupKey provision _ payload maxRetries delay dlqOn disposition loc) =
  WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn disposition loc

workqueueWithDelay :: T.Text -> WorkqueueNode -> WorkqueueNode
workqueueWithDelay delay (WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries _ dlqOn disposition loc) =
  WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn disposition loc

workqueueWithDisposition :: [WqDispRow] -> WorkqueueNode -> WorkqueueNode
workqueueWithDisposition disposition (WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn _ loc) =
  WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn disposition loc

wqFieldWithValueType :: QueuePayloadType -> WqField -> WqField
wqFieldWithValueType valueType (WqField name wire _ loc) = WqField name wire valueType loc

wireFieldWithHaskell :: Name -> WireField -> WireField
wireFieldWithHaskell haskell (WireField _ key valueType presence onMissing loc) =
  WireField haskell key valueType presence onMissing loc

wireFieldWithKey :: T.Text -> WireField -> WireField
wireFieldWithKey key (WireField haskell _ valueType presence onMissing loc) =
  WireField haskell key valueType presence onMissing loc

wireFieldWithValueType :: TypeExpr -> WireField -> WireField
wireFieldWithValueType valueType (WireField haskell key _ presence onMissing loc) =
  WireField haskell key valueType presence onMissing loc

wireFieldWithPresenceAndDefault :: Presence -> Maybe OnMissing -> WireField -> WireField
wireFieldWithPresenceAndDefault presence onMissing (WireField haskell key valueType _ _ loc) =
  WireField haskell key valueType presence onMissing loc

wireFieldWithOnMissing :: Maybe OnMissing -> WireField -> WireField
wireFieldWithOnMissing onMissing (WireField haskell key valueType presence _ loc) =
  WireField haskell key valueType presence onMissing loc

wireFieldWithPresence :: Presence -> WireField -> WireField
wireFieldWithPresence presence (WireField haskell key valueType _ onMissing loc) =
  WireField haskell key valueType presence onMissing loc

contractWithSchemaVersion :: Int -> ContractNode -> ContractNode
contractWithSchemaVersion schemaVersion (ContractNode name _ discriminator topics events loc) =
  ContractNode name schemaVersion discriminator topics events loc

contractWithTopics :: [(Name, T.Text)] -> ContractNode -> ContractNode
contractWithTopics topics (ContractNode name schemaVersion discriminator _ events loc) =
  ContractNode name schemaVersion discriminator topics events loc

publisherWithOrdering :: Name -> PublisherNode -> PublisherNode
publisherWithOrdering ordering (PublisherNode name emit _ maxAttempts backoff outboxField loc) =
  PublisherNode name emit ordering maxAttempts backoff outboxField loc

publisherWithBackoff :: BackoffSpec -> PublisherNode -> PublisherNode
publisherWithBackoff backoff (PublisherNode name emit ordering maxAttempts _ outboxField loc) =
  PublisherNode name emit ordering maxAttempts backoff outboxField loc

publisherWithMaxAttempts :: Int -> PublisherNode -> PublisherNode
publisherWithMaxAttempts maxAttempts (PublisherNode name emit ordering _ backoff outboxField loc) =
  PublisherNode name emit ordering maxAttempts backoff outboxField loc

publisherWithEmit :: Name -> PublisherNode -> PublisherNode
publisherWithEmit emit (PublisherNode name _ ordering maxAttempts backoff outboxField loc) =
  PublisherNode name emit ordering maxAttempts backoff outboxField loc

publisherWithOutboxField :: Name -> PublisherNode -> PublisherNode
publisherWithOutboxField outboxField (PublisherNode name emit ordering maxAttempts backoff _ loc) =
  PublisherNode name emit ordering maxAttempts backoff outboxField loc

backoffWithKind :: Name -> BackoffSpec -> BackoffSpec
backoffWithKind kind (BackoffSpec _ window maximumValue multiplier) = BackoffSpec kind window maximumValue multiplier

backoffWithWindow :: T.Text -> BackoffSpec -> BackoffSpec
backoffWithWindow window (BackoffSpec kind _ maximumValue multiplier) = BackoffSpec kind window maximumValue multiplier

intakeWithDedupePolicy :: Name -> IntakeNode -> IntakeNode
intakeWithDedupePolicy dedupePolicy (IntakeNode name contract topic accept binds dedupeKey _ persist decode disposition loc) =
  IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist decode disposition loc

intakeWithDedupeKey :: Name -> IntakeNode -> IntakeNode
intakeWithDedupeKey dedupeKey (IntakeNode name contract topic accept binds _ dedupePolicy persist decode disposition loc) =
  IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist decode disposition loc

intakeWithDecode :: DecodeSpec -> IntakeNode -> IntakeNode
intakeWithDecode decode (IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist _ disposition loc) =
  IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist decode disposition loc

intakeWithBinds :: [BindRow] -> IntakeNode -> IntakeNode
intakeWithBinds binds (IntakeNode name contract topic accept _ dedupeKey dedupePolicy persist decode disposition loc) =
  IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist decode disposition loc

intakeWithDisposition :: [DispositionRow] -> IntakeNode -> IntakeNode
intakeWithDisposition disposition (IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist decode _ loc) =
  IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist decode disposition loc

intakeWithContract :: Name -> IntakeNode -> IntakeNode
intakeWithContract contract (IntakeNode name _ topic accept binds dedupeKey dedupePolicy persist decode disposition loc) =
  IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist decode disposition loc

decodeWithEnvelope :: T.Text -> DecodeSpec -> DecodeSpec
decodeWithEnvelope envelope (DecodeSpec _ bodyStrict bodySchemaVersion) = DecodeSpec envelope bodyStrict bodySchemaVersion

decodeWithBodyStrict :: Bool -> DecodeSpec -> DecodeSpec
decodeWithBodyStrict bodyStrict (DecodeSpec envelope _ bodySchemaVersion) = DecodeSpec envelope bodyStrict bodySchemaVersion

decodeWithBodySchemaVersion :: Int -> DecodeSpec -> DecodeSpec
decodeWithBodySchemaVersion bodySchemaVersion (DecodeSpec envelope bodyStrict _) = DecodeSpec envelope bodyStrict bodySchemaVersion

emitNodeWithMap :: [EmitMapRow] -> EmitNode -> EmitNode
emitNodeWithMap mapping (EmitNode name contract topic source key discriminant _ skip messageId idempotencyKey loc) =
  EmitNode name contract topic source key discriminant mapping skip messageId idempotencyKey loc

workflowWithStable :: T.Text -> WorkflowNode -> WorkflowNode
workflowWithStable stable (WorkflowNode nodeId _ input inputFields output idField idVia body loc) =
  WorkflowNode nodeId stable input inputFields output idField idVia body loc

routerWithName :: T.Text -> RouterNode -> RouterNode
routerWithName name (RouterNode nodeId _ input key resolve target projections dispatch rejected poison loc) =
  RouterNode nodeId name input key resolve target projections dispatch rejected poison loc

readModelWithVersion :: Int -> ReadModelNode -> ReadModelNode
readModelWithVersion version (ReadModelNode name table schema columns _ shape freshness supply group observedTargets backingTarget queryTypes loc) =
  ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc

readModelWithName :: Name -> ReadModelNode -> ReadModelNode
readModelWithName name (ReadModelNode _ table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc) =
  ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc

readModelWithTable :: T.Text -> ReadModelNode -> ReadModelNode
readModelWithTable table (ReadModelNode name _ schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc) =
  ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc

readModelWithColumns :: [RmColumn] -> ReadModelNode -> ReadModelNode
readModelWithColumns columns (ReadModelNode name table schema _ version shape freshness supply group observedTargets backingTarget queryTypes loc) =
  ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc

readModelQueryTypesWithInput :: TypeExpr -> ReadModelQueryTypes -> ReadModelQueryTypes
readModelQueryTypesWithInput input (ReadModelQueryTypes _ result inputLoc resultLoc) =
  ReadModelQueryTypes input result inputLoc resultLoc

readModelQueryTypesWithResult :: TypeExpr -> ReadModelQueryTypes -> ReadModelQueryTypes
readModelQueryTypesWithResult result (ReadModelQueryTypes input _ inputLoc resultLoc) =
  ReadModelQueryTypes input result inputLoc resultLoc

processWithTimer :: TimerNode -> ProcessNode -> ProcessNode
processWithTimer timer (ProcessNode nodeId name input correlate saga target projections handle rejected poison _ loc) =
  ProcessNode nodeId name input correlate saga target projections handle rejected poison timer loc

processWithHandle :: HandleNode -> ProcessNode -> ProcessNode
processWithHandle handle (ProcessNode nodeId name input correlate saga target projections _ rejected poison timer loc) =
  ProcessNode nodeId name input correlate saga target projections handle rejected poison timer loc

processWithSaga :: SagaRef -> ProcessNode -> ProcessNode
processWithSaga saga (ProcessNode nodeId name input correlate _ target projections handle rejected poison timer loc) =
  ProcessNode nodeId name input correlate saga target projections handle rejected poison timer loc

processWithCorrelate :: CorrelateDecl -> ProcessNode -> ProcessNode
processWithCorrelate correlate (ProcessNode nodeId name input _ saga target projections handle rejected poison timer loc) =
  ProcessNode nodeId name input correlate saga target projections handle rejected poison timer loc

sagaRefWithCategory :: T.Text -> SagaRef -> SagaRef
sagaRefWithCategory category (SagaRef agg _) = SagaRef agg category

correlateDeclWithField :: Name -> CorrelateDecl -> CorrelateDecl
correlateDeclWithField field (CorrelateDecl _ via) = CorrelateDecl field via

correlateDeclWithVia :: Name -> CorrelateDecl -> CorrelateDecl
correlateDeclWithVia via (CorrelateDecl field _) = CorrelateDecl field via

handleWithDispatch :: [DispatchNode] -> HandleNode -> HandleNode
handleWithDispatch dispatch (HandleNode on advance _ schedule) = HandleNode on advance dispatch schedule

handleWithAdvance :: AdvanceNode -> HandleNode -> HandleNode
handleWithAdvance advance (HandleNode on _ dispatch schedule) = HandleNode on advance dispatch schedule

advanceNodeWithFields :: [FieldBinding] -> AdvanceNode -> AdvanceNode
advanceNodeWithFields fields (AdvanceNode command _) = AdvanceNode command fields

timerWithFireAt :: FireAtExpr -> TimerNode -> TimerNode
timerWithFireAt fireAt (TimerNode name timerId _ payload fire decodeUnknown maxAttempts deadLetter loc) =
  TimerNode name timerId fireAt payload fire decodeUnknown maxAttempts deadLetter loc

timerWithFire :: FireNode -> TimerNode -> TimerNode
timerWithFire fire (TimerNode name timerId fireAt payload _ decodeUnknown maxAttempts deadLetter loc) =
  TimerNode name timerId fireAt payload fire decodeUnknown maxAttempts deadLetter loc

timerWithIdAndFire :: IdExpr -> FireNode -> TimerNode -> TimerNode
timerWithIdAndFire timerId fire (TimerNode name _ fireAt payload _ decodeUnknown maxAttempts deadLetter loc) =
  TimerNode name timerId fireAt payload fire decodeUnknown maxAttempts deadLetter loc

timerWithDecodeUnknown :: Name -> TimerNode -> TimerNode
timerWithDecodeUnknown decodeUnknown (TimerNode name timerId fireAt payload fire _ maxAttempts deadLetter loc) =
  TimerNode name timerId fireAt payload fire decodeUnknown maxAttempts deadLetter loc

timerWithDeadLetter :: T.Text -> TimerNode -> TimerNode
timerWithDeadLetter deadLetter (TimerNode name timerId fireAt payload fire decodeUnknown maxAttempts _ loc) =
  TimerNode name timerId fireAt payload fire decodeUnknown maxAttempts deadLetter loc

idExprWithField :: Name -> IdExpr -> IdExpr
idExprWithField field (IdExpr strategy prefix _) = IdExpr strategy prefix field

fireNodeWithDisposition :: FireDisposition -> FireNode -> FireNode
fireNodeWithDisposition disposition (FireNode target key command fields firedEventId _) =
  FireNode target key command fields firedEventId disposition

fireNodeWithFiredEventId :: IdExpr -> FireNode -> FireNode
fireNodeWithFiredEventId firedEventId (FireNode target key command fields _ disposition) =
  FireNode target key command fields firedEventId disposition

fireDispositionWithNotMine :: FireOutcome -> FireDisposition -> FireDisposition
fireDispositionWithNotMine notMine (FireDisposition onOk onReject onAmbiguous onError _) =
  FireDisposition onOk onReject onAmbiguous onError notMine

fireDispositionWithOnAmbiguous :: FireOutcome -> FireDisposition -> FireDisposition
fireDispositionWithOnAmbiguous onAmbiguous (FireDisposition onOk onReject _ onError notMine) =
  FireDisposition onOk onReject onAmbiguous onError notMine

routerWithDispatch :: RouterDispatchNode -> RouterNode -> RouterNode
routerWithDispatch dispatch (RouterNode nodeId name input key resolve target projections _ rejected poison loc) =
  RouterNode nodeId name input key resolve target projections dispatch rejected poison loc

routerWithTarget :: Name -> RouterNode -> RouterNode
routerWithTarget target (RouterNode nodeId name input key resolve _ projections dispatch rejected poison loc) =
  RouterNode nodeId name input key resolve target projections dispatch rejected poison loc

routerWithKey :: CorrelateDecl -> RouterNode -> RouterNode
routerWithKey key (RouterNode nodeId name input _ resolve target projections dispatch rejected poison loc) =
  RouterNode nodeId name input key resolve target projections dispatch rejected poison loc

routerWithResolve :: ResolveDecl -> RouterNode -> RouterNode
routerWithResolve resolve (RouterNode nodeId name input key _ target projections dispatch rejected poison loc) =
  RouterNode nodeId name input key resolve target projections dispatch rejected poison loc

routerWithPoison :: PolicyChoice -> RouterNode -> RouterNode
routerWithPoison poison (RouterNode nodeId name input key resolve target projections dispatch rejected _ loc) =
  RouterNode nodeId name input key resolve target projections dispatch rejected poison loc

routerWithRejected :: PolicyChoice -> RouterNode -> RouterNode
routerWithRejected rejected (RouterNode nodeId name input key resolve target projections dispatch _ poison loc) =
  RouterNode nodeId name input key resolve target projections dispatch rejected poison loc

routerWithRejectedAndDispatch :: PolicyChoice -> RouterDispatchNode -> RouterNode -> RouterNode
routerWithRejectedAndDispatch rejected dispatch (RouterNode nodeId name input key resolve target projections _ _ poison loc) =
  RouterNode nodeId name input key resolve target projections dispatch rejected poison loc

resolveDeclWithRow :: [Name] -> ResolveDecl -> ResolveDecl
resolveDeclWithRow row (ResolveDecl source _ loc) = ResolveDecl source row loc

routerDispatchWithDisposition :: DispatchDisposition -> RouterDispatchNode -> RouterDispatchNode
routerDispatchWithDisposition disposition (RouterDispatchNode command fields _ loc) =
  RouterDispatchNode command fields disposition loc

routerDispatchWithCommand :: Name -> RouterDispatchNode -> RouterDispatchNode
routerDispatchWithCommand command (RouterDispatchNode _ fields disposition loc) =
  RouterDispatchNode command fields disposition loc

routerDispatchWithFields :: [FieldBinding] -> RouterDispatchNode -> RouterDispatchNode
routerDispatchWithFields fields (RouterDispatchNode command _ disposition loc) =
  RouterDispatchNode command fields disposition loc

dispatchDispositionWithOnDuplicate :: Disp -> DispatchDisposition -> DispatchDisposition
dispatchDispositionWithOnDuplicate onDuplicate (DispatchDisposition onAppended _ onFailed) =
  DispatchDisposition onAppended onDuplicate onFailed

dispatchDispositionWithOnFailed :: Disp -> DispatchDisposition -> DispatchDisposition
dispatchDispositionWithOnFailed onFailed (DispatchDisposition onAppended onDuplicate _) =
  DispatchDisposition onAppended onDuplicate onFailed

fireAtWithWindow :: T.Text -> FireAtExpr -> FireAtExpr
fireAtWithWindow window (FireAtExpr field _) = FireAtExpr field window

transitionWithSource :: Name -> Transition -> Transition
transitionWithSource source (Transition _ command implementation guard writes emits outcome outcomeDuplicateLocs goto mode loc) =
  Transition source command implementation guard writes emits outcome outcomeDuplicateLocs goto mode loc

transitionWithGoto :: Name -> Transition -> Transition
transitionWithGoto goto (Transition source command implementation guard writes emits outcome outcomeDuplicateLocs _ mode loc) =
  Transition source command implementation guard writes emits outcome outcomeDuplicateLocs goto mode loc

eventWithDeprecated :: Bool -> Event -> Event
eventWithDeprecated deprecated (Event name body version upcastFrom retiring _ loc) =
  Event name body version upcastFrom retiring deprecated loc

aggregateWithEvents :: [Event] -> Aggregate -> Aggregate
aggregateWithEvents events (Aggregate name regs states commands _ transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc) =
  Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc

workqueueWithMaxRetries :: Int -> WorkqueueNode -> WorkqueueNode
workqueueWithMaxRetries maxRetries (WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload _ delay dlqOn disposition loc) =
  WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn disposition loc

pgmqDispatchWithSourceKey :: Name -> PgmqDispatchNode -> PgmqDispatchNode
pgmqDispatchWithSourceKey sourceKey (PgmqDispatchNode name sourceReadModel _ fanoutBody dedupKey dedupReadModel dedupReadModelField dedupQueue dedupQueueField enqueueTo loc) =
  PgmqDispatchNode name sourceReadModel sourceKey fanoutBody dedupKey dedupReadModel dedupReadModelField dedupQueue dedupQueueField enqueueTo loc

pgmqDispatchWithFanoutBody :: Name -> PgmqDispatchNode -> PgmqDispatchNode
pgmqDispatchWithFanoutBody fanoutBody (PgmqDispatchNode name sourceReadModel sourceKey _ dedupKey dedupReadModel dedupReadModelField dedupQueue dedupQueueField enqueueTo loc) =
  PgmqDispatchNode name sourceReadModel sourceKey fanoutBody dedupKey dedupReadModel dedupReadModelField dedupQueue dedupQueueField enqueueTo loc

pgmqDispatchWithDedupKey :: Name -> PgmqDispatchNode -> PgmqDispatchNode
pgmqDispatchWithDedupKey dedupKey (PgmqDispatchNode name sourceReadModel sourceKey fanoutBody _ dedupReadModel dedupReadModelField dedupQueue dedupQueueField enqueueTo loc) =
  PgmqDispatchNode name sourceReadModel sourceKey fanoutBody dedupKey dedupReadModel dedupReadModelField dedupQueue dedupQueueField enqueueTo loc

pgmqDispatchWithEnqueueTo :: Name -> PgmqDispatchNode -> PgmqDispatchNode
pgmqDispatchWithEnqueueTo enqueueTo (PgmqDispatchNode name sourceReadModel sourceKey fanoutBody dedupKey dedupReadModel dedupReadModelField dedupQueue dedupQueueField _ loc) =
  PgmqDispatchNode name sourceReadModel sourceKey fanoutBody dedupKey dedupReadModel dedupReadModelField dedupQueue dedupQueueField enqueueTo loc

readModelWithSupply :: ReadModelSupply -> ReadModelNode -> ReadModelNode
readModelWithSupply supply (ReadModelNode name table schema columns version shape freshness _ group observedTargets backingTarget queryTypes loc) =
  ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc

operationWithShape :: OperationShape -> OperationNode -> OperationNode
operationWithShape shape (OperationNode name _ loc) = OperationNode name shape loc

semanticImpactSnapshotWithoutEvidence :: SemanticImpactSnapshot -> SemanticImpactSnapshot
semanticImpactSnapshotWithoutEvidence (SemanticImpactSnapshot mappedConsumers _ _ serviceInventory declarationIdentities) =
  SemanticImpactSnapshot mappedConsumers Nothing Nothing serviceInventory declarationIdentities

workspaceModuleRowWithPath :: FilePath -> WorkspaceModuleRow -> WorkspaceModuleRow
workspaceModuleRowWithPath path (WorkspaceModuleRow kind _ owner role) =
  WorkspaceModuleRow kind path owner role

workspaceRecordWithEditionAndModules :: GeneratedHaskellNamingEdition -> [WorkspaceModuleRow] -> WorkspaceRecord -> WorkspaceRecord
workspaceRecordWithEditionAndModules namingEdition modules (WorkspaceRecord service manifest contextName moduleRoot layout members sourceLanguages languageContract _ _ mappings idDomains nominalEqualities bindingObligations requirements projectionCatalogFacts queryContractBaseline queryContracts routerSelections adopted semanticImpact) =
  WorkspaceRecord service manifest contextName moduleRoot layout members sourceLanguages languageContract namingEdition modules mappings idDomains nominalEqualities bindingObligations requirements projectionCatalogFacts queryContractBaseline queryContracts routerSelections adopted semanticImpact

timerNodeWithPayload :: [FieldBinding] -> TimerNode -> TimerNode
timerNodeWithPayload payload (TimerNode name identity fireAt _ fire decodeUnknown maxAttempts deadLetter loc) =
  TimerNode name identity fireAt payload fire decodeUnknown maxAttempts deadLetter loc

wireArmWithTag :: T.Text -> WireArm -> WireArm
wireArmWithTag tag (WireArm ctor _ payload loc) = WireArm ctor tag payload loc

wireEnumWithTag :: T.Text -> WireEnum -> WireEnum
wireEnumWithTag tag (WireEnum ctor _ loc) = WireEnum ctor tag loc

conformanceRecordWithFiles :: [(ModuleKind, FilePath)] -> ConformancePackageRecord -> ConformancePackageRecord
conformanceRecordWithFiles files (ConformancePackageRecord schema serviceKey runtimePackage facadeModule _) =
  ConformancePackageRecord schema serviceKey runtimePackage facadeModule files
