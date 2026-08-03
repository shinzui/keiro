-- | Test driver for keiro-dsl. EP-1 milestone 1 tests: the @parse . pretty@
-- round-trip property over generated specs, and a unit test pinning the shape
-- of the canonical Reservation fixture.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (filterM, forM, forM_, unless)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft, isRight)
import Data.Foldable (toList)
import Data.KindID qualified as KindID
import Data.List (partition, permutations, sort, (\\))
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
import Keiro.Dsl.CanonicalEncoding (foldFingerprint128)
import Keiro.Dsl.CodecCompare
import Keiro.Dsl.ConformanceBaseline (conformanceBaselineSpec)
import Keiro.Dsl.Coverage qualified as Coverage
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), CompatibilitySurface (..), CompatibilityVector (..), FamilyDiff (..), Label (..), NodeFamily, RolloutConstraint (..), SurfaceVerdict (..), defaultGate, deriveLabel, familyRegistry, gateWith, gatedBreaking, isAdvisory, isBreaking, verdictFor)
import Keiro.Dsl.Diff qualified as CheckedDiff
import Keiro.Dsl.DiffReport (Remedy (..), diffReport, parseSurfaceName, remediationFor, renderExplainBlock, renderFinding)
import Keiro.Dsl.EventOutput
import Keiro.Dsl.ExplainBindings (BindingHole (..), BindingObligation (..), BindingObligationKind (..), bindingHoles, bindingObligations, bindingObligationsForService, renderBindingObligations)
import Keiro.Dsl.Expression
import Keiro.Dsl.FoldFingerprint (FoldSurfaceError (..))
import Keiro.Dsl.FoldFingerprint qualified as CheckedFold
import Keiro.Dsl.FrontendCompatibility (frontendCompatibilitySpec)
import Keiro.Dsl.FrontendProfiles (frontendProfilesSpec)
import Keiro.Dsl.FrontendSurface (frontendSurfaceSpec)
import Keiro.Dsl.Goldens (GoldenEvidence (..), GoldenPayload (..), emitGoldenPayloads, goldenRelativePath, goldensForDiff)
import Keiro.Dsl.Grammar
import Keiro.Dsl.Harness (harnessFor, harnessForWithGoldens, harnessReadModel, harnessRouter, harnessWorkflow)
import Keiro.Dsl.IdDomain (IdDomainContract (..), contractIdDomainContractFor, idDomainContractFor, idDomainIdentitiesForService)
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Manifest (manifestDependencies, manifestDependenciesForService, moduleNameOf, renderManifest, renderManifestForService)
import Keiro.Dsl.MappedConsumer (ConsumerPlan (..), MappingIdentity (..), consumerPlan)
import Keiro.Dsl.NominalType hiding (NominalInvalidHaskellSource, NominalInvalidIdPrefix, NominalInvalidIdentity, NominalMissingIngredient)
import Keiro.Dsl.Parser (parseSource, parseSpec)
import Keiro.Dsl.PrettyPrint (renderSource, renderSpec, renderTransition)
import Keiro.Dsl.ReadModelShape (canonicalShape, deriveShapeHash, registryNameFor, subscriptionNameFor)
import Keiro.Dsl.ReplayImpact (AggregateImpact (..), ReplayImpact (..))
import Keiro.Dsl.ReplayImpact qualified as ReplayImpact
import Keiro.Dsl.Scaffold (Context (..), ModuleKind (..), NominalGenerationOwner (..), NominalUseSite (..), ScaffoldModule (..), StructuralProjection (..), codecComparisonBanner, codecComparisonModule, defaultContext, firewallBreaches, genPrefixFor, generatedBanner, generatedBannerFor, generatedNominalModule, holePrefixFor, isGeneratedBannerLine, obsoleteGeneratedOutputHooks, planNominalGeneration, projectionSpecs, scaffoldAggregate, scaffoldContract, scaffoldContractForService, scaffoldIntake, scaffoldProcess, scaffoldPublisher, scaffoldReadModel, scaffoldRefusals, scaffoldReplayAudit, scaffoldRouter, scaffoldStructural, scaffoldWorkqueue, windowSeconds)
import Keiro.Dsl.ScaffoldRecord (ScaffoldRecord (..), parseRecord, recordFileName, renderRecord)
import Keiro.Dsl.ScaffoldRun (MappingDrift (..), Refusal (..), ScaffoldReport (..), SourceLanguageDrift (..), StaleGeneratedEvidence (..), StaleModule (..), WriteDisposition (..), executeScaffold, executeScaffoldWithLanguage, executeServiceScaffold, planScaffold, planServiceScaffold, renderRefusals, renderScaffoldReport, scaffoldModules, scaffoldServiceModules)
import Keiro.Dsl.SemanticContract
import Keiro.Dsl.Skeleton (skeletonFor, skeletonKinds)
import Keiro.Dsl.TypeGraph
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode (..), Severity (..), derivedQueueTrio, renderDiagnostic, validateService, validateSpec)
import Keiro.Dsl.Workspace
import Keiro.Dsl.WorkspaceAdoption
import Keiro.Dsl.WorkspaceDiff hiding (diffWorkspaces)
import Keiro.Dsl.WorkspaceDiff qualified as CheckedWorkspaceDiff
import Keiro.Dsl.WorkspaceRecord
import Keiro.Dsl.WorkspaceScaffold
import Paths_keiro_dsl qualified as Package
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory, removeFile, removePathForcibly)
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

  describe "language support" $ do
    it "serializes support from the registered version and decodes older records" $ do
      v1Contract <- maybe (expectationFailure "missing v1 contract" >> fail "unreachable") pure (effectiveLanguageContractForVersion =<< languageVersion 1)
      v4Contract <- maybe (expectationFailure "missing v4 contract" >> fail "unreachable") pure (effectiveLanguageContractForVersion =<< languageVersion 4)
      effectiveLanguageSupport v1Contract `shouldBe` CompatibilityOnly
      effectiveLanguageSupport v4Contract `shouldBe` Stable
      Aeson.toJSON v4Contract
        `shouldBe` object
          [ "languageVersion" .= (4 :: Int),
            "runtimeSemantics" .= ("keiro-dsl/runtime-semantics/3" :: T.Text),
            "languageSupport" .= ("stable" :: T.Text)
          ]
      Aeson.eitherDecode "{\"languageVersion\":1,\"runtimeSemantics\":\"keiro-dsl/runtime-semantics/1\"}"
        `shouldBe` Right v1Contract

    it "reports stable and compatibility-only support through source inspection" $ do
      (stableCode, stableOut, stableErr) <- runKeiroDsl ["inspect", "test/fixtures/contract-v4.keiro", "--format=json"]
      stableCode `shouldBe` ExitSuccess
      stableErr `shouldBe` ""
      stableOut `shouldContain` "\"languageVersion\":4"
      stableOut `shouldContain` "\"languageSupport\":\"stable\""
      (compatibilityCode, compatibilityOut, compatibilityErr) <- runKeiroDsl ["inspect", "test/fixtures/language-v1.keiro", "--format=json"]
      compatibilityCode `shouldBe` ExitSuccess
      compatibilityErr `shouldBe` ""
      compatibilityOut `shouldContain` "\"languageVersion\":1"
      compatibilityOut `shouldContain` "\"languageSupport\":\"compatibility-only\""

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
      golden <- readTestText "test/fixtures/fold-identity-baseline.golden"
      T.stripEnd actual `shouldBe` T.stripEnd golden

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
            nominalContract = equalityContractVersion <$> nominalEqualityContractForService contract nominal
            strictService = CheckedService contract strictSpec
            hasStrictValidation = any ((== AggregateDuplicateRegister) . code) (validateService strictService)
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
            baseSpec
              { specNodes =
                  [ NAggregate (transform aggregate)
                  | NAggregate aggregate <- specNodes baseSpec
                  ]
              }
          replaceFirstTransition transform aggregate =
            aggregate
              { aggTransitions = case aggTransitions aggregate of
                  transition : rest -> transform transition : rest
                  [] -> []
              }
          guardSpec = withAggregate (replaceFirstTransition (\transition -> transition {tGuard = Just (EAtom (AName "missingGuardRoot"))}))
          outputSpec = withAggregate (replaceFirstTransition (\transition -> transition {tEmits = ["MissingEvent"]}))
          typeGraphSpec = baseSpec {specMapped = specMapped recursiveMapped}
          nominalSpec = baseSpec {specNominalScalars = specNominalScalars brokenNominal}
          cases =
            [ (CheckedService contract typeGraphSpec, baseAggregate, \case FoldTypeGraphResolutionFailed {} -> True; _ -> False),
              (CheckedService contract nominalSpec, baseAggregate, \case FoldNominalResolutionFailed {} -> True; _ -> False),
              (CheckedService contract missingInitial, onlyAggregate missingInitial, \case FoldRegisterInitialResolutionFailed {} -> True; _ -> False),
              (CheckedService contract guardSpec, onlyAggregate guardSpec, \case FoldGuardResolutionFailed {} -> True; _ -> False),
              (CheckedService contract outputSpec, onlyAggregate outputSpec, \case FoldEventOutputResolutionFailed {} -> True; _ -> False)
            ]
      forM_ cases $ \(service, aggregate, matches) -> do
        CheckedFold.aggregateFoldSurfaceForService service aggregate
          `shouldSatisfy` either matches (const False)
        CheckedFold.aggregateFoldFingerprintForService service aggregate
          `shouldSatisfy` either matches (const False)
      let brokenService = CheckedService contract guardSpec
      CheckedDiff.diffServices brokenService baseService `shouldSatisfy` isLeft
      ReplayImpact.replayImpactServices brokenService baseService `shouldSatisfy` isLeft
      planServiceScaffold (defaultContext (specContext guardSpec)) brokenService
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
      golden <- readTestText "test/fixtures/fold-identity-diff-replay.golden"
      T.stripEnd actual `shouldBe` T.stripEnd golden

    it "pins unrelated public 64-bit identities outside the fold digest" $ do
      readModelSpec <- specOf "test/fixtures/readmodel.keiro"
      wireSpec <- specOf "test/fixtures/consumer-types.keiro"
      behaviorSpec <- specOf "test/fixtures/behavior-complete.keiro"
      readModel <- case [value | NReadModel value <- specNodes readModelSpec] of
        value : _ -> pure value
        [] -> expectationFailure "missing read-model fixture" >> fail "unreachable"
      graph <- shouldResolveTypeGraph wireSpec
      behaviorKey <- case Behavior.deriveBehaviorRequirements behaviorSpec of
        Right (requirement : _) -> pure (Behavior.unBehaviorKey (Behavior.requirementKey requirement))
        result -> expectationFailure ("missing behavior requirement: " <> show result) >> fail "unreachable"
      deriveShapeHash readModel `shouldBe` "fnv1a:3717f6d9e3c44bd6"
      wireFingerprint graph "ArtifactInfo" `shouldBe` "2bd99b3e57bcde9b"
      behaviorKey `shouldBe` "behavior-v1-2e1fd6b9580e1a3d"

  describe "source language version" $ do
    let legacy = "context hospital-capacity\n"
        declared = "# leading comment\n\nlanguage keiro-dsl 1\ncontext hospital-capacity\n"
        failureCode source = case parseSource "source.keiro" source of
          Left (SourceLanguageFailure diagnostic) -> Just (sourceLanguageErrorCode diagnostic)
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
      parsedSpec legacySource `shouldBe` parsedSpec declaredSource
      parsedSourceLanguage legacySource `shouldBe` LegacyUnversioned
      declaredVersionOf (parsedSourceLanguage declaredSource) `shouldBe` languageVersion 1
      effectiveLanguageVersion (parsedSourceLanguage legacySource)
        `shouldBe` effectiveLanguageVersion (parsedSourceLanguage declaredSource)

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
          ctx = defaultContext (specContext v1Spec)
          aggregates spec = [aggregate | NAggregate aggregate <- specNodes spec]
      v1Spec `shouldBe` v2Spec
      Just (effectiveContractLanguageVersion (checkedLanguageContract v1Service)) `shouldBe` languageVersion 1
      Just (effectiveContractLanguageVersion (checkedLanguageContract v2Service)) `shouldBe` languageVersion 2
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
          Just (effectiveContractLanguageVersion (checkedLanguageContract (checkedWorkspace workspace))) `shouldBe` languageVersion 2
          validateService (checkedWorkspace workspace) `shouldBe` []
        Left failure -> expectationFailure (show failure)
      mixed <- loadWorkspace mixedSource "service.keiro-workspace"
      case mixed of
        Left (WorkspaceRefused diagnostics) ->
          map wdCode (NE.toList diagnostics) `shouldContain` [WorkspaceLanguageVersionMismatch]
        other -> expectationFailure ("expected a mixed-version refusal, got " <> show other)

    it "refuses a source/service contract mismatch before creating the output directory" $ do
      v1Version <- maybe (expectationFailure "version 1 missing" >> fail "unreachable") pure (languageVersion 1)
      parsed <- parseRight "semantic-v2.keiro" "language keiro-dsl 2\ncontext semantic-refusal\n"
      let service = checkedSource parsed
          ctx = defaultContext "semantic-refusal"
      modules <- case planServiceScaffold ctx service of
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
      parseSpec "declared.keiro" declared `shouldBe` Right (parsedSpec declaredSource)

    it "classifies invalid, unsupported, duplicate, and misplaced preambles" $ do
      failureCode "language keiro-dsl 0\ncontext hospital-capacity\n" `shouldBe` Just InvalidLanguageVersion
      failureCode "language keiro-dsl nope\ncontext hospital-capacity\n" `shouldBe` Just InvalidLanguageVersion
      failureCode "language keiro-dsl -1\ncontext hospital-capacity\n" `shouldBe` Just InvalidLanguageVersion
      failureCode "language keiro-dsl 5\ncontext hospital-capacity\n" `shouldBe` Just UnsupportedLanguageVersion
      failureCode "language keiro-dsl 1\nlanguage keiro-dsl 1\ncontext hospital-capacity\n" `shouldBe` Just DuplicateLanguagePreamble
      failureCode "context hospital-capacity\nlanguage keiro-dsl 1\n" `shouldBe` Just MisplacedLanguagePreamble

    it "treats language and successor spellings as data in nested grammar positions" $ do
      forM_ ["language-identifier-v1.keiro", "language-identifier-v2.keiro"] $ \fixture -> do
        source <- readTestText ("test/fixtures/" <> fixture)
        parsed <- parseRight fixture source
        validateSpec (parsedSpec parsed) `shouldBe` []
      v1 <- readTestText "test/fixtures/language-identifier-v1.keiro"
      let manifest = "service language-collisions\nspec domain/collisions.keiro\n"
          workspaceSource = memoryContentSource (Map.fromList [("service.keiro-workspace", manifest), ("domain/collisions.keiro", v1)])
      loaded <- loadWorkspace workspaceSource "service.keiro-workspace"
      loaded `shouldSatisfy` isRight

    it "keeps duplicate and misplaced preamble diagnostics on their grammar lines" $ do
      let sourceFailureAt expectedCode expectedLine source =
            case parseSource "located.keiro" source of
              Left (SourceLanguageFailure diagnostic) -> do
                sourceLanguageErrorCode diagnostic `shouldBe` expectedCode
                unLoc (sourceLanguageLoc diagnostic) `shouldBe` expectedLine
              other -> expectationFailure ("expected located source-language failure, got " <> show other)
      sourceFailureAt DuplicateLanguagePreamble 2 "language keiro-dsl 1\nlanguage keiro-dsl 1\ncontext located\n"
      sourceFailureAt MisplacedLanguagePreamble 3 "context located\nid language prefix=lang\nlanguage keiro-dsl 1\n"

    it "rejects a future version before parsing an invalid v1 body" $
      case parseSource "future.keiro" "language keiro-dsl 5\nthis is not a v2 body\n" of
        Left failure@(SourceLanguageFailure diagnostic) -> do
          sourceLanguageErrorCode diagnostic `shouldBe` UnsupportedLanguageVersion
          renderParseFailure failure `shouldSatisfy` T.isInfixOf "supported versions: 1, 2, 3, 4"
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
      length (specIds (parsedSpec parsed)) `shouldBe` 1
      length (specEnums (parsedSpec parsed)) `shouldBe` 1
      length (specNominalScalars (parsedSpec parsed)) `shouldBe` 1
      parseSource "nominal-round-trip.keiro" (renderSource parsed) `shouldBe` Right parsed

    it "reports successor nominal syntax as one language-version diagnostic under v1 and legacy" $ do
      let body = "context orders\nmapped nominal AccountNumber : Text {}\n"
      failureCode ("language keiro-dsl 1\n" <> body) `shouldBe` Just LanguageFeatureRequiresVersion
      failureCode body `shouldBe` Just LanguageFeatureRequiresVersion

    it "attributes every successor feature gate to its owning grammar production" $ do
      let featureFailureAt expectedLine source =
            case parseSource "feature.keiro" source of
              Left (SourceLanguageFailure diagnostic) -> do
                sourceLanguageErrorCode diagnostic `shouldBe` LanguageFeatureRequiresVersion
                unLoc (sourceLanguageLoc diagnostic) `shouldBe` expectedLine
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
      let oldSpec = parsedSpec legacySource
          newSpec = parsedSpec declaredSource
          changes = diffSources legacySource declaredSource
          vectors = [ckVector kind | change <- changes, let kind = workspaceChangeKind change]
      map changeCode changes `shouldBe` [SourceLanguageDeclarationChanged]
      legacyDiffSpecs oldSpec newSpec `shouldBe` []
      vectors `shouldSatisfy` all (\compatibility -> all ((== VCompatible) . (`verdictFor` compatibility)) [minBound .. maxBound])
      case changes of
        [change] ->
          remediationFor (ckContext (workspaceChangeKind change)) SourceLanguageDeclarationChanged
            `shouldBe` (RemedyNoSemanticAction :| [])
        _ -> expectationFailure "expected one source-language change"
      let legacyGeneratedSurface spec =
            [ (modulePath scaffoldModule, moduleText scaffoldModule, kind scaffoldModule)
            | scaffoldModule <- scaffoldModules (defaultContext (specContext spec)) spec
            ]
          legacyFoldFingerprint spec aggregate = aggregateFoldFingerprintForService (legacyCheckedService spec) aggregate
      legacyGeneratedSurface oldSpec `shouldBe` legacyGeneratedSurface newSpec
      [legacyFoldFingerprint oldSpec aggregate | NAggregate aggregate <- specNodes oldSpec]
        `shouldBe` [legacyFoldFingerprint newSpec aggregate | NAggregate aggregate <- specNodes newSpec]
      legacyReplayImpactSpecs oldSpec newSpec `shouldBe` ReplayNeutral

    it "exposes stable JSON inspection for a source and canonically ordered workspace members" $ do
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
      sourceOut `shouldContain` "\"languageSupport\":\"stable\""
      (workspaceCode, workspaceOut, workspaceErr) <- runKeiroDsl ["inspect", canonicalWorkspacePath, "--format=json"]
      workspaceCode `shouldBe` ExitSuccess
      workspaceErr `shouldBe` ""
      workspaceOut `shouldContain` "\"kind\":\"workspace\""
      workspaceOut `shouldContain` "\"service\":\"demo-project\""
      workspaceOut `shouldContain` "\"effectiveSemanticContract\":{"
      workspaceOut `shouldContain` "\"languageSupport\":\"stable\""
      workspaceOut `shouldSatisfy` orderedSubstrings ["domain/project-artifact.keiro", "domain/project.keiro", "domain/shared.keiro"]

    it "keeps only the named source-version compatibility fixtures outside stable v4" $ do
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
            "contract-v1-compat.keiro",
            "id-domain-migration-v3.keiro",
            "language-duplicate.keiro",
            "language-future.keiro",
            "language-identifier-v1.keiro",
            "language-identifier-v2.keiro",
            "language-legacy.keiro",
            "language-malformed.keiro",
            "language-misplaced.keiro",
            "language-v1.keiro",
            "language-zero.keiro",
            "nominal-v1.keiro"
          ]

    it "checks v1, rejects a future contract once, and inspects legacy explicitly" $ do
      (v1Code, v1Out, v1Err) <- runKeiroDsl ["check", "test/fixtures/language-v1.keiro"]
      v1Code `shouldBe` ExitSuccess
      v1Out `shouldBe` "OK\n"
      v1Err `shouldBe` ""
      (futureCode, _, futureErr) <- runKeiroDsl ["check", "test/fixtures/language-future.keiro"]
      futureCode `shouldBe` ExitFailure 1
      T.count "UnsupportedLanguageVersion" (T.pack futureErr) `shouldBe` 1
      futureErr `shouldContain` "supported versions: 1, 2, 3, 4"
      futureErr `shouldNotContain` "expecting `context`"
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
        checkErr `shouldBe` ""
        withTempDirectory ("keiro-dsl-" <> fixture) $ \out -> do
          (scaffoldCode, _, scaffoldErr) <- runKeiroDsl ["scaffold", sourcePath, "--out", out]
          scaffoldCode `shouldBe` ExitSuccess
          scaffoldErr `shouldContain` "firewall: OK"

    it "preserves a workspace member's source-selection code beneath outer attribution" $ do
      let manifest = "service demo\nspec domain/future.keiro\n"
          futureSource = "language keiro-dsl 5\nthis body must not parse\n"
          source = memoryContentSource (Map.fromList [("service.keiro-workspace", manifest), ("domain/future.keiro", futureSource)])
      loaded <- loadWorkspace source "service.keiro-workspace"
      case loaded of
        Left (WorkspaceRefused (diagnostic :| [])) -> do
          wdCode diagnostic `shouldBe` WorkspaceMemberParseFailed
          sourceLanguageErrorCode <$> wdSourceLanguageCause diagnostic
            `shouldBe` Just UnsupportedLanguageVersion
          renderWorkspaceDiagnostic "service.keiro-workspace" diagnostic
            `shouldSatisfy` T.isInfixOf "UnsupportedLanguageVersion"
        other -> expectationFailure ("expected one attributed source-language refusal, got " <> show other)

    it "attributes a workspace provenance-only diff to the changed member" $ do
      workspace <- shouldComposeWorkspace canonicalWorkspacePath
      case wsMembers workspace of
        firstMember : remaining -> do
          let changedMember = firstMember {wmSourceLanguage = LegacyUnversioned}
              changedWorkspace = workspace {wsMembers = changedMember : remaining}
              changes = diffWorkspaces workspace changedWorkspace
          map (changeCode . wcChange) changes `shouldBe` [SourceLanguageDeclarationChanged]
          map (fmap osFile . wcDeclarationSite) changes `shouldBe` [Just (wmPath firstMember)]
          map wcChange changes `shouldSatisfy` all (not . gatedBreaking (gateWith [minBound .. maxBound]))
        _ -> expectationFailure "canonical workspace had no member"

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
      effectiveContractLanguageVersion contract `shouldBe` maybe (error "missing v3") id (languageVersion 3)
      idDomainContractFor contract "req" `shouldSatisfy` (/= Nothing)

    it "registers language 4 as contract admission semantics without changing aggregate ID admission" $ do
      v3 <- parseRight "id-domain-v3.keiro" "language keiro-dsl 3\ncontext id-domain\n"
      v4 <- parseRight "id-domain-v4.keiro" "language keiro-dsl 4\ncontext id-domain\n"
      let v3Contract = checkedLanguageContract (checkedSource v3)
          v4Contract = checkedLanguageContract (checkedSource v4)
      effectiveRuntimeSemantics v4Contract `shouldBe` "keiro-dsl/runtime-semantics/3"
      effectiveContractLanguageVersion v4Contract `shouldBe` maybe (error "missing v4") id (languageVersion 4)
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
          code diagnostic `shouldBe` ContractInvalidTypeIdPrefix
          line diagnostic `shouldBe` 3
          message diagnostic `shouldSatisfy` T.isInfixOf "contract 'emergency' event 'IncidentDeclared' field 'incidentId'"
          message diagnostic `shouldSatisfy` T.isInfixOf "invalid TypeID prefix 'Bad'"
        diagnostics -> expectationFailure ("expected one invalid contract prefix diagnostic, got " <> show diagnostics)

    it "keeps version-3 and version-4 aggregate fold and replay semantics equal" $ do
      v3Text <- readTestText "test/fixtures/id-domain-migration-v3.keiro"
      v3 <- parseRight "fold-v3.keiro" v3Text
      v4 <- parseRight "fold-v4.keiro" (T.replace "language keiro-dsl 3" "language keiro-dsl 4" v3Text)
      let v3Service = checkedSource v3
          v4Service = checkedSource v4
          fingerprints service =
            [ aggregateFoldFingerprintForService service aggregate
            | NAggregate aggregate <- specNodes (checkedSpec service)
            ]
      fingerprints v4Service `shouldBe` fingerprints v3Service
      diffServices v3Service v4Service `shouldBe` []
      resolvedFold (ReplayImpact.replayImpactServices v3Service v4Service) `shouldBe` ReplayNeutral

    it "keeps runtime validation and the exact Keiki text image in agreement" $ do
      let contract = typeIdV7Domain "req"
          sample = idDomainSampleText contract
          suffix = T.drop (T.length "req_") sample
          replaceAt position replacement value =
            T.take position value <> T.singleton replacement <> T.drop (position + 1) value
          accepted =
            [ sample,
              replaceAt (T.length "req_" + 10) 'f' sample,
              replaceAt (T.length "req_" + 13) 'v' sample
            ]
          rejected =
            [ "",
              "req_",
              "other_" <> suffix,
              "req__" <> suffix,
              T.dropEnd 1 sample,
              sample <> "0",
              T.toUpper sample,
              replaceAt (T.length "req_" + 0) '8' sample,
              replaceAt (T.length "req_" + 10) 'd' sample,
              replaceAt (T.length "req_" + 13) 'c' sample
            ]
          patternValue = either (error . show) id (idDomainTextPattern contract)
      idDomainVersion contract `shouldBe` "keiro-dsl/id-domain/typeid-v7/1"
      idDomainSeparator contract `shouldBe` '_'
      idDomainSuffixLength contract `shouldBe` 26
      idDomainMaxLength contract `shouldBe` T.length sample
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
      variant <- elements "89abrstv"
      afterVariant <- segment 12
      let value = T.pack ("req_" <> [leading] <> beforeVersion <> [version] <> beforeVariant <> [variant] <> afterVariant)
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
          modules = scaffoldServiceModules (defaultContext (specContext spec)) service
          generatedText suffix = case [moduleText value | value <- modules, T.pack suffix `T.isSuffixOf` T.pack (modulePath value)] of
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
      let orderIdBindings = [obligation | obligation <- obligations, obligationMappedName obligation == "OrderId", obligationKind obligation == BindingValue]
      map obligationIdDomainContract orderIdBindings `shouldBe` [Just "keiro-dsl/id-domain/typeid-v7/1"]
      renderBindingObligations (specContext spec) obligations
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
        verdictFor PrivateHistoryRead (ckVector finding) `shouldBe` VCompatible
        verdictFor OldBinaryReadNewEvents (ckVector finding) `shouldBe` VCompatible
        verdictFor SnapshotHydration (ckVector finding) `shouldBe` VAdvisory
        verdictFor PublicConsumer (ckVector finding) `shouldBe` VBreaking
        verdictFor PersistedIdentity (ckVector finding) `shouldBe` VCompatible
        verdictFor ConsumerBuild (ckVector finding) `shouldBe` VAdvisory
        ckDetail finding `shouldSatisfy` T.isInfixOf "historical event replay retains its legacy decoder"
        remediationFor (ckContext finding) (ckCode finding)
          `shouldBe` RemedyDeploymentOrder RolloutProducerLast :| [RemedyStateCodecBump, RemedyRecompileConsumers, RemedyRunConformance]
      [ckDetail finding | change <- changes, changeCode change == SourceLanguageDeclarationChanged, let finding = kindOfChange change]
        `shouldSatisfy` all (T.isInfixOf "effective runtime semantics changed")
      idDomainIdentitiesForService oldService `shouldBe` []
      idDomainIdentitiesForService newService
        `shouldSatisfy` any (T.isInfixOf "contract=keiro-dsl/id-domain/typeid-v7/1")
      resolvedFold (ReplayImpact.replayImpactServices oldService newService) `shouldSatisfy` \case
        ReplayImpact.ReplayAffected impacts ->
          maybe False includeSnapshotStreams (Map.lookup "OrderBook" impacts)
        ReplayImpact.ReplayNeutral -> False

    it "keeps the raw constructor outside the compiled public module surface" $
      withTempDirectory "keiro-dsl-id-domain-hidden-constructor" $ \out -> do
        sourceText <- readTestText "test/fixtures/id-domain-migration-v3.keiro"
        parsed <- case parseSource "id-domain-migration-v3.keiro" sourceText of
          Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
          Right value -> pure value
        let service = checkedSource parsed
            spec = checkedSpec service
            ctx = defaultContext (specContext spec)
            modules = scaffoldServiceModules ctx service
            attempt = out </> "Attempt.hs"
            ghcOutput = out </> ".ghc"
        result <- executeServiceScaffold out False "id-domain-migration-v3.keiro" (parsedSourceLanguage parsed) ctx service modules
        result `shouldSatisfy` isRight
        recordContents <- TIO.readFile (out </> recordFileName (specContext spec))
        record <- case parseRecord recordContents of
          Nothing -> expectationFailure "generated ID-domain scaffold record did not parse" >> fail "unreachable"
          Just value -> pure value
        recIdDomains record `shouldBe` idDomainIdentitiesForService service
        recNominalEqualities record
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
      let paths = map (modulePath . fst) (wpModules plan)
      length (filter (== "Generated/WorkspaceNominalProof/Nominals.hs") paths) `shouldBe` 1
      length (filter (== "Generated/WorkspaceNominalProof/Nominals/Internal.hs") paths) `shouldBe` 1
      forM_ [moduleText value | (value, _) <- wpModules plan, "/Domain.hs" `T.isSuffixOf` T.pack (modulePath value)] $ \domainText ->
        domainText `shouldSatisfy` (not . T.isInfixOf "ProjectId (..)")
      withTempDirectory "keiro-dsl-v3-workspace-record" $ \out -> do
        emitted <- executeWorkspaceScaffold out False plan
        emitted `shouldSatisfy` isRight
        recordContents <- TIO.readFile (out </> workspaceRecordFileName (wsService workspace))
        record <- case parseWorkspaceRecord recordContents of
          Nothing -> expectationFailure "version-3 workspace record did not parse" >> fail "unreachable"
          Just value -> pure value
        wrIdDomains record `shouldBe` idDomainIdentitiesForService (wpCheckedService plan)
        wrNominalEqualities record
          `shouldSatisfy` any (T.isInfixOf "keiro-dsl/id-domain/typeid-v7/1")

    it "emits an abstract public ID, an internal legacy seam, and exact equality" $ do
      v2Source <- readTestText "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      let v3Source = T.replace "language keiro-dsl 2" "language keiro-dsl 3" v2Source
      parsed <- case parseSource "aggregate-scalar-expressions-v3.keiro" v3Source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let service = checkedSource parsed
          spec = checkedSpec service
          modules = scaffoldServiceModules (defaultContext (specContext spec)) service
          moduleAt path = case [value | value <- modules, modulePath value == path] of
            [value] -> pure value
            values -> expectationFailure ("expected one module at " <> path <> ", got " <> show (map modulePath values)) >> fail "unreachable"
      validateService service `shouldBe` []
      publicNominals <- moduleAt "Generated/AggregateScalarExpressions/Nominals.hs"
      internalNominals <- moduleAt "Generated/AggregateScalarExpressions/Nominals/Internal.hs"
      domainModule <- moduleAt "Generated/AggregateScalarExpressions/ScalarAccount/Domain.hs"
      codecModule <- moduleAt "Generated/AggregateScalarExpressions/ScalarAccount/Codec.hs"
      transducerModule <- moduleAt "Generated/AggregateScalarExpressions/ScalarAccount/Transducer.hs"
      moduleText publicNominals `shouldSatisfy` T.isInfixOf "parseRequestId"
      moduleText publicNominals `shouldSatisfy` T.isInfixOf "instance ExactFieldProjection RequestIdEqualityProjection"
      moduleText publicNominals `shouldSatisfy` T.isInfixOf "idDomainTextPattern (typeIdV7Domain \"req\")"
      moduleText publicNominals `shouldSatisfy` (not . T.isInfixOf "unsafeRequestIdFromLegacyText")
      moduleText publicNominals `shouldSatisfy` (not . T.isInfixOf "newtype RequestId")
      moduleText internalNominals `shouldSatisfy` T.isInfixOf "newtype RequestId = RequestId Text"
      moduleText internalNominals `shouldSatisfy` T.isInfixOf "unsafeRequestIdFromLegacyText"
      moduleText domainModule `shouldSatisfy` (not . T.isInfixOf "RequestId (..)")
      moduleText codecModule `shouldSatisfy` T.isInfixOf "unsafeRequestIdFromLegacyText <$>"
      moduleText transducerModule `shouldSatisfy` T.isInfixOf "case parseRequestId"
      firewallBreaches modules `shouldBe` []

  describe "scalar expressions" $ do
    it "parses, validates, and round-trips the authoritative stable scalar fixture" $ do
      source <- readTestText "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      parsed <- case parseSource "aggregate-scalar-expressions-v2.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      validateSpec (parsedSpec parsed) `shouldBe` []
      parseSource "round-trip.keiro" (renderSource parsed) `shouldBe` Right parsed
      case [aggregate | NAggregate aggregate <- specNodes (parsedSpec parsed)] of
        [aggregate] -> case aggTransitions aggregate of
          transition : holeTransition : [] -> do
            tImplementation transition `shouldBe` GeneratedImplementation
            tImplementation holeTransition `shouldBe` HoleImplementation
            let environment = expressionEnvironment (parsedSpec parsed) aggregate transition
            case lookup "reserved" (tWrites transition) >>= either (const Nothing) Just . resolveWriteExpr environment "reserved" of
              Just resolved -> do
                typedScalarType resolved `shouldBe` AggregateNatural
                show (typedScalarNode resolved) `shouldContain` "TotalNaturalArithmetic"
              Nothing -> expectationFailure "reserved write did not resolve"
            let service = checkedSource parsed
                modules = scaffoldServiceModules (defaultContext (specContext (parsedSpec parsed))) service
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
            map modulePath modules `shouldSatisfy` all (not . T.isSuffixOf "Expressions.hs" . T.pack)
            map modulePath modules `shouldSatisfy` any (T.isSuffixOf "Transducer.hs" . T.pack)
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
      let modules = scaffoldModules (defaultContext (specContext spec)) spec
          moduleAt suffix = case [moduleText value | value <- modules, T.pack suffix `T.isSuffixOf` T.pack (modulePath value)] of
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
      let transducer = generatedTextEndingIn "Transducer.hs" (scaffoldModules (defaultContext (specContext spec)) spec)
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
      case ( [aggregate | NAggregate aggregate <- specNodes (parsedSpec original)],
             [aggregate | NAggregate aggregate <- specNodes (parsedSpec changed)]
           ) of
        ([originalAggregate], [changedAggregate]) -> do
          let service = checkedSource original
              changedService = checkedSource changed
              prefixed = defaultContext (specContext (parsedSpec original))
              collocated = prefixed {moduleRoot = "Acme", placement = CollocatedLeaf}
              prefixedModules = scaffoldServiceModules prefixed service
              collocatedModules = scaffoldServiceModules collocated service
              originalSurface = aggregateFoldSurfaceForService service originalAggregate
              originalFingerprint = aggregateFoldFingerprintForService service originalAggregate
          map modulePath prefixedModules `shouldNotBe` map modulePath collocatedModules
          sum (map (T.length . moduleText) prefixedModules) `shouldSatisfy` (> 0)
          sum (map (T.length . moduleText) collocatedModules) `shouldSatisfy` (> 0)
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
      case [aggregate | NAggregate aggregate <- specNodes spec] of
        [aggregate] -> case aggTransitions aggregate of
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
      length [() | diagnostic <- diagnostics, code diagnostic == AggregateExpressionOperandTypeMismatch]
        `shouldBe` 3
      errorCodes spec `shouldContain` [AggregateExpressionRootUnknown]
      T.unlines (map message diagnostics) `shouldSatisfy` T.isInfixOf "qualify"

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
      length [() | diagnostic <- validateSpec spec, code diagnostic == AggregateExpressionOperatorUnsupported]
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
      errorCodes (parsedSpec parsed) `shouldContain` [AggregateTransitionOwnershipConflict]
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
      aggregate <- case [value | NAggregate value <- specNodes spec] of
        [value] -> pure value
        _ -> expectationFailure "expected one Hole aggregate" >> fail "unreachable"
      let modules = scaffoldAggregate (defaultContext (specContext spec)) spec aggregate
          transducer = generatedTextEndingIn "Transducer.hs" modules
          holes = holeTextEndingIn "Holes.hs" modules
      errorCodes spec `shouldBe` []
      map modulePath modules `shouldSatisfy` all (not . T.isSuffixOf "Expressions.hs" . T.pack)
      transducer `shouldSatisfy` T.isInfixOf "Holes.transition1OpenSetHole d"
      transducer `shouldSatisfy` T.isInfixOf "foldToken Holes.transition1OpenSetHoleFoldVersion"
      holes `shouldSatisfy` T.isInfixOf "transition1OpenSetHole _d = B.requireGuard K.PTop"
      holes `shouldSatisfy` T.isInfixOf "transition1OpenSetHoleFoldVersion = FoldVersion"
      holes `shouldSatisfy` (not . T.isInfixOf "counterTransducer")

    it "pins v1 and collection rejection at their stable boundaries" $ do
      v1Source <- readTestText "test/fixtures/aggregate-scalar-expressions-v1-rejects.keiro"
      case parseSource "v1.keiro" v1Source of
        Left (SourceLanguageFailure diagnostic) -> sourceLanguageErrorCode diagnostic `shouldBe` LanguageFeatureRequiresVersion
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
      forM_ [generatedModule | generatedModule <- modules, kind generatedModule == Generated] $ \generatedModule -> do
        committed <- readTestText ("test/conformance-scalar-expressions/" <> modulePath generatedModule)
        normalizeGenerated committed `shouldBe` normalizeGenerated (moduleText generatedModule)

  describe "behavior obligations" $ do
    it "inventories every live-reachable cell, guarded edge, terminal rejection, and replay edge" $ do
      spec <- specOf "test/fixtures/behavior-complete.keiro"
      requirements <- either (\errors -> expectationFailure (show errors) >> pure []) pure (Behavior.deriveBehaviorRequirements spec)
      length requirements `shouldBe` 14
      length [() | requirement <- requirements, Behavior.requirementKind requirement == Behavior.LiveTransition] `shouldBe` 5
      length [() | requirement <- requirements, Behavior.requirementKind requirement == Behavior.RequiredRejection] `shouldBe` 8
      length [() | requirement <- requirements, Behavior.requirementKind requirement == Behavior.ReplayTransition] `shouldBe` 1
      [Behavior.requirementSource requirement | requirement <- requirements, Behavior.requirementKind requirement == Behavior.RequiredRejection]
        `shouldContain` ["Active", "Closed"]
      length [() | requirement <- requirements, Behavior.requirementGuardCoverage requirement == Behavior.GuardTotal] `shouldBe` 4
      length [() | requirement <- requirements, Behavior.requirementGuardCoverage requirement == Behavior.GuardUnknown] `shouldBe` 1
      let report = Behavior.BehaviorObligationsReport "behavior-complete.keiro" Nothing requirements
          encoded = Behavior.encodeBehaviorObligationsJson report
      encoded `shouldSatisfy` T.isInfixOf "\"schema\":\"keiro-dsl/behavior-obligations/1\""
      encoded `shouldSatisfy` T.isInfixOf "\"source\":\"Closed\""
      encoded `shouldSatisfy` T.isInfixOf "\"kind\":\"replay-transition\""
      encoded `shouldSatisfy` (not . T.isInfixOf "\"filled\"")
      encoded `shouldSatisfy` (not . T.isInfixOf "\"missing\"")

    it "keeps semantic keys stable across line movement and canonical pretty printing" $ do
      source <- readTestText "test/fixtures/behavior-complete.keiro"
      parsed <- case parseSource "behavior-complete.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let original = parsedSpec parsed
      moved <- parseInlineSpec "behavior-complete-moved.keiro" ("# line movement must not rename witnesses\n\n" <> source)
      pretty <- parseInlineSpec "behavior-complete-pretty.keiro" (renderSource parsed)
      let keys spec = fmap (map Behavior.requirementKey) (Behavior.deriveBehaviorRequirements spec)
      keys moved `shouldBe` keys original
      keys pretty `shouldBe` keys original

    it "generates direct fields(Command) output and separate create-once pending witnesses" $ do
      spec <- specOf "test/fixtures/behavior-complete.keiro"
      aggregate <- case [value | NAggregate value <- specNodes spec] of
        [value] -> pure value
        _ -> expectationFailure "expected one behavior-complete aggregate" >> fail "unreachable"
      let modules = scaffoldAggregate (defaultContext (specContext spec)) spec aggregate
          transducer = generatedTextEndingIn "Transducer.hs" modules
          codec = generatedTextEndingIn "Codec.hs" modules
          contract = generatedTextEndingIn "BehaviorContract.hs" modules
          behaviorHoles = case [moduleText value | value <- modules, T.isSuffixOf "BehaviorHoles.hs" (T.pack (modulePath value))] of
            [value] -> value
            values -> error ("expected one BehaviorHoles module, got " <> show (length values))
          ordinaryHoles = [value | value <- modules, T.isSuffixOf "/Holes.hs" (T.pack (modulePath value)), not (T.isSuffixOf "BehaviorHoles.hs" (T.pack (modulePath value)))]
      transducer `shouldSatisfy` T.isInfixOf "requestId = d.requestId"
      transducer `shouldSatisfy` T.isInfixOf "observedAt = d.observedAt"
      transducer `shouldSatisfy` T.isInfixOf "amount = d.amount"
      transducer `shouldSatisfy` T.isInfixOf "details = d.details"
      codec `shouldSatisfy` T.isInfixOf "display_label"
      codec `shouldSatisfy` T.isInfixOf "optional_note"
      transducer `shouldSatisfy` (not . T.isInfixOf "Output")
      ordinaryHoles `shouldBe` []
      obsoleteGeneratedOutputHooks spec `shouldContain` [("Journey", "transition1EmptyStartOutput1Started")]
      contract `shouldSatisfy` T.isInfixOf "keiro/behavior-conformance/1"
      contract `shouldSatisfy` T.isInfixOf "commandKind command == requirementCommandName requirement"
      T.count "Pending (BehaviorKey " behaviorHoles `shouldBe` 14
      behaviorHoles `shouldSatisfy` (not . T.isInfixOf "undefined")
      behaviorHoles `shouldSatisfy` (not . T.isInfixOf "error")

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
      case planScaffold (defaultContext (specContext duplicate)) duplicate of
        Left refusals -> refusals `shouldSatisfy` any isBehaviorRefusal
        Right _ -> expectationFailure "duplicate behavior identity reached a scaffold write set"

    it "round-trips additive single-file and workspace behavior rows with member ownership" $ do
      spec <- specOf "test/fixtures/behavior-complete.keiro"
      requirements <- either (\errors -> expectationFailure (show errors) >> pure []) pure (Behavior.deriveBehaviorRequirements spec)
      version <- maybe (expectationFailure "language version 2 was not constructible" >> fail "unreachable") pure (languageVersion 2)
      let rows = Behavior.behaviorRecordRows requirements
          singleRecord =
            ScaffoldRecord
              { recSpecPath = "behavior-complete.keiro",
                recModuleRoot = "",
                recLayout = "prefixed",
                recSourceLanguage = DeclaredLanguage version noLoc,
                recLanguageContract = effectiveLanguageContract (DeclaredLanguage version noLoc),
                recFiles = [],
                recMappings = [],
                recIdDomains = [],
                recNominalEqualities = [],
                recBindingObligations = [],
                recBehaviorRequirements = rows
              }
      T.count "behavior " (renderRecord singleRecord) `shouldBe` 14
      parseRecord (renderRecord singleRecord) `shouldBe` Just singleRecord

      workspace <- shouldComposeWorkspace "test/fixtures/behavior-complete-workspace/service.keiro-workspace"
      workspaceRequirements <- either (\errors -> expectationFailure (show errors) >> pure []) pure (Behavior.deriveBehaviorRequirements (wsMergedSpec workspace))
      let ownedRequirements =
            map
              (Behavior.attributeBehaviorOwner (fmap fst . nodeOwner (wsOwnership workspace) "aggregate"))
              workspaceRequirements
          ownedRows = Behavior.behaviorRecordRows ownedRequirements
          workspaceRecord =
            WorkspaceRecord
              { wrService = wsService workspace,
                wrManifest = "service.keiro-workspace",
                wrContext = wsContext workspace,
                wrModuleRoot = "",
                wrLayout = "prefixed",
                wrMembers = map wmPath (wsMembers workspace),
                wrSourceLanguages = [WorkspaceSourceLanguageRow (wmPath member) (wmSourceLanguage member) | member <- wsMembers workspace],
                wrLanguageContract = wsLanguageContract workspace,
                wrModules = [],
                wrMappings = [],
                wrIdDomains = [],
                wrNominalEqualities = [],
                wrBindingObligations = [],
                wrBehaviorRequirements = ownedRows,
                wrAdopted = []
              }
      map Behavior.behaviorRecordOwner ownedRows `shouldSatisfy` all (== Just "journey.keiro")
      T.count "behavior " (renderWorkspaceRecord workspaceRecord) `shouldBe` 14
      parseWorkspaceRecord (renderWorkspaceRecord workspaceRecord) `shouldBe` Just workspaceRecord

  describe "nominal consumer types" $ do
    it "resolves every category through one checked registry and explains exact obligations" $ do
      spec <- specOf "test/fixtures/nominal-scalars.keiro"
      errorCodes spec `shouldBe` []
      registry <- case resolveNominalTypes spec of
        Left errors -> expectationFailure (show errors) >> fail "unreachable"
        Right value -> pure value
      Map.keys (nominalTypes registry)
        `shouldBe` ["AccountNumber", "FeatureFlag", "ObservedAt", "OrderId", "OrderStatus", "RiskScore", "SequenceNumber"]
      obligations <- either (\errors -> expectationFailure (show errors) >> pure []) pure (bindingObligations spec)
      length obligations `shouldBe` 21
      map obligationCategory obligations `shouldSatisfy` all (`elem` ["nominal-id", "nominal-enum", "nominal-scalar"])
      length [() | obligation <- obligations, obligationEqualityContract obligation /= Nothing] `shouldBe` 2
      renderBindingObligations (specContext spec) obligations `shouldSatisfy` T.isInfixOf "equality-contract:"
      let signatures = map obligationSignature obligations
      forM_
        [ "orderIdBinding :: NominalBinding NominalConformance.Domain.OrderId (KindID \"ord\")",
          "orderStatusBinding :: NominalBinding NominalConformance.Domain.OrderStatus Generated.NominalScalars.Nominal.Shape.OrderStatus.OrderStatusRepresentation",
          "accountNumberBinding :: NominalBinding NominalConformance.Domain.AccountNumber Text",
          "orderIdFixtures :: NominalFixtureCases NominalConformance.Domain.OrderId",
          "initialAccountNumber :: NominalConformance.Domain.AccountNumber"
        ]
        (`shouldSatisfy` (`elem` signatures))
      map obligationCanonicalType obligations `shouldSatisfy` all (/= Nothing)
      let rendered = renderBindingObligations (specContext spec) obligations
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
      errorCodesOf "test/fixtures/nominal-name-collision.keiro" `shouldReturn` [NominalNameCollision, NominalNameCollision]

    it "keeps v1 rejection at the source-language boundary" $ do
      source <- readTestText "test/fixtures/nominal-v1.keiro"
      case parseSource "nominal-v1.keiro" source of
        Left (SourceLanguageFailure diagnostic) -> sourceLanguageErrorCode diagnostic `shouldBe` LanguageFeatureRequiresVersion
        other -> expectationFailure ("expected source-language refusal, got " <> show other)

    it "scaffolds consumer types, checked codecs, enum representation, projections, and deterministic manifests" $ do
      spec <- specOf "test/fixtures/nominal-scalars.keiro"
      let ctx = defaultContext (specContext spec)
          modules = scaffoldModules ctx spec
          moduleAt path = case [value | value <- modules, modulePath value == path] of
            [value] -> pure value
            values -> expectationFailure ("expected one module at " <> path <> ", got " <> show (map modulePath values)) >> fail "unreachable"
      domainModule <- moduleAt "Generated/NominalScalars/NominalLedger/Domain.hs"
      codecModule <- moduleAt "Generated/NominalScalars/NominalLedger/Codec.hs"
      enumModule <- moduleAt "Generated/NominalScalars/Nominal/Shape/OrderStatus.hs"
      projectionModule <- moduleAt "Generated/NominalScalars/NominalProjections.hs"
      bindingModule <- moduleAt "NominalConformance/Bindings.hs"
      map modulePath modules `shouldNotContain` ["NominalScalars/NominalLedger/Holes.hs"]
      moduleText domainModule `shouldSatisfy` T.isInfixOf "import NominalConformance.Domain (AccountNumber, FeatureFlag, ObservedAt, OrderId, OrderStatus, RiskScore, SequenceNumber)"
      moduleText domainModule `shouldSatisfy` T.isInfixOf "orderId :: !OrderId"
      moduleText domainModule `shouldSatisfy` (not . T.isInfixOf "NominalConformance.Domain.OrderId")
      moduleText domainModule `shouldSatisfy` (not . T.isInfixOf "newtype OrderId")
      moduleText domainModule `shouldSatisfy` (not . T.isInfixOf "data OrderStatus =")
      moduleText codecModule `shouldSatisfy` T.isInfixOf "KindID.parseText @\"ord\""
      moduleText codecModule `shouldSatisfy` T.isInfixOf "KindID.toText (nominalToRepresentation"
      moduleText codecModule `shouldSatisfy` T.isInfixOf "nominalFromRepresentation"
      forM_ ["coerce", "unsafe", "read ", "error "] $ \forbidden ->
        moduleText codecModule `shouldSatisfy` (not . T.isInfixOf forbidden)
      moduleText enumModule `shouldSatisfy` T.isInfixOf "data OrderStatusRepresentation = Draft | Submitted"
      moduleText enumModule `shouldSatisfy` (not . T.isInfixOf "NominalConformance")
      moduleText projectionModule `shouldSatisfy` T.isInfixOf "type FieldOwner AccountNumberNominalProjection = AccountNumber"
      moduleText projectionModule `shouldSatisfy` T.isInfixOf "projectFieldValue _ = nominalToRepresentation Bindings.accountNumberBinding"
      moduleText projectionModule `shouldSatisfy` T.isInfixOf "instance ExactFieldProjection OrderIdEqualityProjection"
      moduleText projectionModule `shouldSatisfy` T.isInfixOf "textProjectionDomain orderIdEqualityPattern"
      moduleText projectionModule `shouldSatisfy` T.isInfixOf "instance ExactFieldProjection OrderStatusEqualityProjection"
      moduleText projectionModule `shouldSatisfy` T.isInfixOf "finiteProjectionDomain (\"draft\" :| [\"submitted\"])"
      kind bindingModule `shouldBe` HoleStub
      moduleText bindingModule `shouldSatisfy` T.isInfixOf "import NominalConformance.Domain (AccountNumber, FeatureFlag, ObservedAt, OrderId, OrderStatus, RiskScore, SequenceNumber)"
      moduleText bindingModule `shouldSatisfy` T.isInfixOf "orderIdBinding :: NominalBinding OrderId (KindID \"ord\")"
      moduleText bindingModule `shouldSatisfy` T.isInfixOf "orderStatusBinding :: NominalBinding OrderStatus ShapeOrderStatus.OrderStatusRepresentation"
      firewallBreaches modules `shouldBe` []
      scaffoldModules ctx spec `shouldBe` modules
      manifestDependencies spec `shouldContain` ["mmzk-typeid", "nominal-conformance"]

    it "persists nominal provenance in a separate forward-compatible row kind" $ do
      spec <- specOf "test/fixtures/nominal-scalars.keiro"
      workspace <- shouldComposeWorkspace canonicalWorkspacePath
      let plan = consumerPlan spec
          record =
            ScaffoldRecord
              { recSpecPath = "nominal-scalars.keiro",
                recModuleRoot = "",
                recLayout = "prefixed",
                recSourceLanguage = LegacyUnversioned,
                recLanguageContract = effectiveLanguageContract LegacyUnversioned,
                recFiles = [],
                recMappings = consumerMappings plan,
                recIdDomains = [],
                recNominalEqualities = nominalEqualityIdentities spec,
                recBindingObligations = [],
                recBehaviorRequirements = []
              }
          encoded = renderRecord record
          workspaceRecord =
            (sampleWorkspaceRecord workspace)
              { wrMappings = consumerMappings plan
              }
          workspaceEncoded = renderWorkspaceRecord workspaceRecord
      consumerPackages plan `shouldBe` ["nominal-conformance"]
      length [() | NominalMapping {} <- consumerMappings plan] `shouldBe` 7
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
              aggregate
                { aggRegs =
                    [ if regName register == "orderId"
                        then register {regInitial = RegInitBare "placeholder"}
                        else register
                    | register <- aggRegs aggregate
                    ]
                }
          useGeneratedIdInitial node = node
          unbound =
            current
              { specIds = [declaration {idBinding = Nothing} | declaration <- specIds current],
                specNodes = map useGeneratedIdInitial (specNodes current)
              }
          adoption = diffSpecs unbound current
          decoderFindings = [kindOfChange change | change <- adoption, changeCode change == NominalIdDecoderTightened]
      map ckSubject decoderFindings `shouldContain` ["NominalLedger event NominalsRecorded .orderId"]
      decoderFindings `shouldSatisfy` all ((== VAdvisory) . verdictFor PrivateHistoryRead . ckVector)
      let bumped =
            current
              { specIds =
                  [ declaration
                      { idBinding = fmap (\binding -> binding {nominalBindingVersion = Just "2"}) (idBinding declaration)
                      }
                  | declaration <- specIds current
                  ]
              }
          bindingChanges = diffSpecs current bumped
      map changeCode bindingChanges `shouldContain` [NominalBindingChanged]
      replayImpactSpecs current bumped `shouldSatisfy` \case
        ReplayImpact.ReplayAffected impacts ->
          maybe False (\impact -> Set.member "NominalsRecorded" (ReplayImpact.eventTypes impact) && includeSnapshotStreams impact) (Map.lookup "NominalLedger" impacts)
        ReplayImpact.ReplayNeutral -> False
      case [aggregate | NAggregate aggregate <- specNodes current] of
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
      crCoverageGaps report
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
      let ctx = defaultContext (specContext spec)
          planned = codecComparisonModule ctx spec "ArtifactInfo"
          ordinary = scaffoldModules ctx spec
      case planned of
        Left err -> expectationFailure (T.unpack err)
        Right comparisonModule -> do
          modulePath comparisonModule
            `shouldBe` "Generated/StructuralConformance/Structural/CodecCompare/ArtifactInfo.hs"
          moduleText comparisonModule `shouldSatisfy` T.isInfixOf codecComparisonBanner
          moduleText comparisonModule `shouldSatisfy` T.isInfixOf "Generated.StructuralConformance.ArtifactCatalog.Codec qualified as GeneratedCodec"
          moduleText comparisonModule `shouldSatisfy` T.isInfixOf "branchSchema = BranchRecord"
          map modulePath ordinary `shouldNotContain` [modulePath comparisonModule]
    it "refuses opaque selections rather than upgrading their claim" $ do
      spec <- specOf "test/fixtures/structural-conformance.keiro"
      codecComparisonModule (defaultContext (specContext spec)) spec "VendorGeometry"
        `shouldSatisfy` either (T.isInfixOf "is opaque") (const False)

  describe "structural/opaque coverage reporting" $ do
    it "reports mapped private-event roots and consumer-json register boundaries without a percentage" $ do
      spec <- specOf "test/fixtures/structural-conformance.keiro"
      report <- shouldResolveCoverage "structural-conformance.keiro" spec
      Coverage.privateEventPayloads (Coverage.coverageSummary report)
        `shouldBe` Coverage.CoverageCounts 2 1 1 0
      Coverage.snapshotRegisters (Coverage.coverageSummary report)
        `shouldBe` Coverage.CoverageCounts 2 1 1 0
      map Coverage.opaqueMappedType (Coverage.coverageOpaqueBoundaries report)
        `shouldBe` ["VendorGeometry"]
      map Coverage.snapshotEncoding (Coverage.coverageSnapshotBoundaries report)
        `shouldBe` ["consumer-json-cache", "consumer-json-cache"]
      map Coverage.snapshotInvalidation (Coverage.coverageSnapshotBoundaries report)
        `shouldBe` ["tracked-by-mapped-wire-fingerprint", "tracked-by-mapped-wire-fingerprint"]
      map Coverage.findingCode (Coverage.coverageFindings report)
        `shouldBe` [CoverageOpaqueSurface]
      map Coverage.findingSeverity (Coverage.coverageFindings report)
        `shouldBe` [Warning]
      case Aeson.toJSON report of
        Aeson.Object values ->
          forM_ ["spec", "roots", "opaqueBoundaries", "snapshotBoundaries", "unsupportedSurfaces"] $
            \key -> KeyMap.member key values `shouldBe` True
        value -> expectationFailure ("coverage report was not an object: " <> show value)
    it "reports explicit Json leaves by their complete persisted path" $ do
      spec <- withMetadataJson <$> specOf "test/fixtures/structural-conformance.keiro"
      report <- shouldResolveCoverage "structural-conformance-json.keiro" spec
      Coverage.jsonBoundaries (Coverage.privateEventPayloads (Coverage.coverageSummary report))
        `shouldBe` 1
      map Coverage.jsonPath (Coverage.coverageJsonBoundaries report)
        `shouldBe` ["ArtifactCatalog event ArtifactRecorded .artifact : ArtifactInfo .metadata : ArtifactMetadata .note"]
    it "keeps a zero-opaque spec advisory-free and makes rejection explicitly opt-in" $ do
      original <- specOf "test/fixtures/structural-conformance.keiro"
      clear <- shouldResolveCoverage "structural-only.keiro" (withoutVendorGeometry original)
      Coverage.opaqueRoots (Coverage.privateEventPayloads (Coverage.coverageSummary clear)) `shouldBe` 0
      Coverage.coverageOpaqueBoundaries clear `shouldBe` []
      Coverage.coverageFindings clear `shouldBe` []
      opaque <- shouldResolveCoverage "structural-conformance.keiro" original
      Coverage.coverageSucceeded opaque `shouldBe` True
      let gated = Coverage.failOnOpaque opaque
      Coverage.coverageSucceeded gated `shouldBe` False
      map Coverage.findingCode (Coverage.coverageFindings gated)
        `shouldBe` [CoverageOpaqueSurface, CoverageOpaqueGateExceeded]
      map Coverage.findingSeverity (Coverage.coverageFindings gated)
        `shouldBe` [Warning, Error]
    it "diffs named opaque boundaries and fails only an explicitly gated increase" $ do
      newSpec <- specOf "test/fixtures/structural-conformance.keiro"
      report <- case Coverage.coverageDiffReport "structural-conformance.keiro" "HEAD" (withoutVendorGeometry newSpec) newSpec of
        Left err -> expectationFailure (show err) >> fail "unreachable"
        Right value -> pure value
      fmap Coverage.opaqueBoundaryDelta (Coverage.coverageDelta report) `shouldBe` Just 1
      fmap (map Coverage.opaqueMappedType . Coverage.addedOpaqueBoundaries) (Coverage.coverageDelta report)
        `shouldBe` Just ["VendorGeometry"]
      map Coverage.findingCode (Coverage.coverageFindings report)
        `shouldBe` [CoverageOpaqueSurface, CoverageOpaqueBoundaryAdded]
      Coverage.coverageSucceeded report `shouldBe` True
      let gated = Coverage.failOnOpaqueIncrease report
      Coverage.coverageSucceeded gated `shouldBe` False
      map Coverage.findingCode (Coverage.coverageFindings gated)
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
            let families = map nodeTag (specNodes s)
                roundTrip = parseSpec "<gen>" (renderSpec s) === Right s
             in cover 5 (not (null (specMapped s))) "mapped" $
                  foldr (\family -> cover 1 (family `elem` families) family) roundTrip allNodeTags
      it "round-trips an aggregate with no states" $
        parseSpec "<empty-states>" (renderSpec emptyStatesSpec) `shouldBe` Right emptyStatesSpec
      it "separates transition emit clauses from following nodes" $ do
        spec <- parseInlineSpec "<cross-family-boundaries>" crossFamilyBoundarySpec
        case specNodes spec of
          [NAggregate first, NEmit _, NAggregate second, NPgmqDispatch _] -> do
            concatMap tEmits (aggTransitions first) `shouldBe` ["Changed"]
            aggStates second `shouldBe` []
          nodes -> expectationFailure ("unexpected node sequence: " <> show (map nodeTag nodes))

  describe "mapped types (EP-149)" $ do
    it "round-trips the canonical structural and opaque consumer fixture" $ do
      source <- TIO.readFile "test/fixtures/consumer-types.keiro"
      spec <- parseInlineSpec "test/fixtures/consumer-types.keiro" source
      parseStableRenderedSpec "<consumer-types-round-trip>" spec `shouldBe` Right spec
      length (specMapped spec) `shouldBe` 4
    it "preserves every missing-value policy, nested type expression, and unit union arm" $ do
      source <- TIO.readFile "test/fixtures/consumer-types.keiro"
      spec <- parseInlineSpec "test/fixtures/consumer-types.keiro" source
      let fields = [field | MappedStructural {msShape = ShapeRecord _ _ recordFields} <- specMapped spec, field <- recordFields]
          arms = [arm | MappedStructural {msShape = ShapeUnion _ unionArms} <- specMapped spec, arm <- unionArms]
      [value | field <- fields, Just value <- [wfOnMissing field]]
        `shouldBe` [OmCtor "Guide", OmNull, OmInt 0, OmBool False, OmEmptyList, OmEmptyMap]
      [wfType field | field <- fields, wfHaskell field == "labels"]
        `shouldBe` [TList (TOptional TText)]
      [waCtor arm | arm <- arms, waPayload arm == Nothing]
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
              AggregateNominal nominal -> case resolvedNominalRepresentation nominal of
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
              AggregateNominal nominal -> case resolvedNominalRepresentation nominal of
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
          generated =
            [ moduleText generatedModule
            | generatedModule <- scaffoldAggregate (defaultContext (specContext spec)) spec aggregate,
              Keiro.Dsl.Scaffold.kind generatedModule == Generated
            ]
          domain = generatedTextEndingIn "Domain.hs" (scaffoldAggregate (defaultContext (specContext spec)) spec aggregate)
      domain `shouldSatisfy` T.isInfixOf "observedAt :: !UTCTime"
      domain `shouldSatisfy` T.isInfixOf "revision :: !Natural"
      domain `shouldSatisfy` T.isInfixOf "UTCTime (fromGregorian 2026 1 2) (picosecondsToDiffTime 11045123456789012)"
      domain `shouldSatisfy` T.isInfixOf "import Data.Time.Calendar (fromGregorian)"
      domain `shouldSatisfy` T.isInfixOf "import Data.Time.Clock (UTCTime(..), picosecondsToDiffTime)"
      domain `shouldSatisfy` T.isInfixOf "import Numeric.Natural (Natural)"
      manifestDependencies spec `shouldContain` ["time"]
      manifestDependencies spec `shouldNotContain` ["keiki-codec-json"]
      generated `shouldSatisfy` all (not . T.isInfixOf "error")
      generated `shouldSatisfy` all (not . T.isInfixOf "getCurrentTime")
      generated `shouldSatisfy` all (not . T.isInfixOf "iso8601ParseM")
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
      forM_ [generatedModule | generatedModule <- modules, Keiro.Dsl.Scaffold.kind generatedModule == Generated] $ \generatedModule -> do
        committed <- readTestText ("test/conformance-aggregate-scalars/" <> modulePath generatedModule)
        normalizeGenerated committed `shouldBe` normalizeGenerated (moduleText generatedModule)
    it "never sends a clean scalar aggregate to a type scaffold refusal" $
      property $
        forAll (elements scalarRegisterCases) $ \(typeName, initialValue) ->
          case parseSpec "<clean-scalar>" (cleanScalarAggregateSpec typeName initialValue) of
            Left parseError -> counterexample (T.unpack parseError) False
            Right spec ->
              let diagnostics = [diagnostic | diagnostic <- validateSpec spec, severity diagnostic == Error]
                  modules = scaffoldModules (defaultContext (specContext spec)) spec
               in counterexample
                    (show diagnostics <> "\n" <> show (scaffoldRefusals spec))
                    ( null diagnostics
                        && null (scaffoldRefusals spec)
                        && all (not . T.null . moduleText) modules
                    )

  describe "aggregate scalar diagnostics" $ do
    it "reports unsupported shapes, invalid initials, and mismatched guards at stable lines" $ do
      diagnostics <- diagnosticsOf "test/fixtures/aggregate-scalars-unsupported.keiro"
      [(code diagnostic, line diagnostic) | diagnostic <- diagnostics, severity diagnostic == Error]
        `shouldBe` [ (AggregateRegisterInitialInvalid, 6),
                     (AggregateRegisterInitialInvalid, 7),
                     (AggregateTypeUnsupportedAtUse, 10),
                     (AggregateExpressionOperandTypeMismatch, 14)
                   ]
      map message diagnostics `shouldSatisfy` any (T.isInfixOf "non-negative integral literals")
      map message diagnostics `shouldSatisfy` any (T.isInfixOf "ISO-8601 UTC timestamps")
      map message diagnostics `shouldSatisfy` any (T.isInfixOf "mapped structural declaration")
    it "accepts Natural aggregate arithmetic in the stable language" $ do
      diagnostics <- diagnosticsOf "test/fixtures/aggregate-scalars-arithmetic.keiro"
      [(code diagnostic, line diagnostic) | diagnostic <- diagnostics, severity diagnostic == Error]
        `shouldBe` []
    it "covers unknown, container, fractional, out-of-range, and ordering failures" $ do
      diagnostics <- diagnosticsOf "test/fixtures/aggregate-scalars-invalid-capabilities.keiro"
      [(code diagnostic, line diagnostic) | diagnostic <- diagnostics, severity diagnostic == Error]
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
            [(code diagnostic, line diagnostic, message diagnostic) | diagnostic <- direct, severity diagnostic == Error]
          workspaceErrors =
            [ (wdCode diagnostic, wlLine (NE.head (wdLocations diagnostic)), wdMessage diagnostic)
            | diagnostic <- checkWorkspace composed,
              wdSeverity diagnostic == Error
            ]
      workspaceErrors `shouldBe` directErrors

  describe "mapped type graph (EP-149)" $ do
    it "resolves checked declarations, transitive reachability, and every aggregate root path" $ do
      source <- TIO.readFile "test/fixtures/consumer-types.keiro"
      spec <- parseInlineSpec "test/fixtures/consumer-types.keiro" source
      graph <- shouldResolveTypeGraph spec
      Map.size (tgDeclarations graph) `shouldBe` 4
      Map.lookup (MappedKey "ArtifactInfo") (tgReachability graph)
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
      case Map.lookup (MappedKey "ArtifactInfo") (tgDeclarations graph) of
        Just (ResolvedStructural _ (RRecord _ _ fields)) ->
          Set.fromList (concatMap (foldTypeExpr expressionTags . rwfType) fields)
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
              { specIds = [IdDecl "ExistingId" "id" Nothing noLoc]
              }
      resolveTypeGraph spec `shouldSatisfy` hasTypeGraphError isUnresolved
    it "fingerprints wire identity while ignoring Haskell selector names" $ do
      source <- TIO.readFile "test/fixtures/consumer-types.keiro"
      base <- parseInlineSpec "test/fixtures/consumer-types.keiro" source
      baseGraph <- shouldResolveTypeGraph base
      haskellRenameGraph <- shouldResolveTypeGraph (mapArtifactField (\field -> field {wfHaskell = "renamedKey"}) base)
      wireRenameGraph <- shouldResolveTypeGraph (mapArtifactField (\field -> field {wfKey = "renamed_key"}) base)
      wireFingerprint haskellRenameGraph "ArtifactInfo" `shouldBe` wireFingerprint baseGraph "ArtifactInfo"
      wireFingerprint wireRenameGraph "ArtifactInfo" `shouldNotBe` wireFingerprint baseGraph "ArtifactInfo"

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
        Right spec -> case [row | NEmit e <- specNodes spec, row <- emMap e] of
          [row] -> do
            emrValue row `shouldBe` "a\" => Wat \"b"
            emrEvent row `shouldBe` "ThingAccepted"
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
      map code (validateSpec partial) `shouldNotContain` [StatusMapNotTotal]
      map code (validateSpec totalSpec) `shouldContain` [StatusMapNotTotal]
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
      [wireSchemaVersion wire | NAggregate aggregate <- specNodes spec, Just wire <- [aggWire aggregate]]
        `shouldBe` [maxBound]

  describe "identifier hygiene" $ do
    it "reports constructor shape and Haskell keywords at their owning declarations" $ do
      spec <- parseInlineSpec "<identifier-hygiene>" identifierHygieneSpec
      [(code diagnostic, line diagnostic) | diagnostic <- validateSpec spec, code diagnostic `elem` [IdentNotConstructorSafe, IdentHaskellKeyword]]
        `shouldContain` [(IdentNotConstructorSafe, 3), (IdentHaskellKeyword, 7)]
    it "rejects generated vertex constructors that collide with event constructors" $ do
      spec <- parseInlineSpec "<vertex-collision>" vertexCollisionSpec
      [(code diagnostic, line diagnostic) | diagnostic <- validateSpec spec, code diagnostic == VertexCtorCollision]
        `shouldBe` [(VertexCtorCollision, 3)]
    it "rejects underscore-leading names whose title-casing cannot make a module segment" $ do
      spec <- parseInlineSpec "<underscore-node>" underscoreNodeSpec
      [(code diagnostic, line diagnostic) | diagnostic <- validateSpec spec, code diagnostic == IdentNotConstructorSafe]
        `shouldBe` [(IdentNotConstructorSafe, 3)]
    it "rejects non-ASCII identifier characters in the parser" $
      parseSpec "<unicode-identifier>" unicodeIdentifierSpec `shouldSatisfy` leftContains "unexpected"

  describe "canonical reservation.keiro" $
    it "parses into the expected aggregate shape" $ do
      input <- readTestText "test/fixtures/reservation.keiro"
      case parseSpec "test/fixtures/reservation.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> do
          specContext spec `shouldBe` "hospital-capacity"
          length (specIds spec) `shouldBe` 3
          length (specEnums spec) `shouldBe` 3
          length (specRules spec) `shouldBe` 1
          case specNodes spec of
            [NAggregate a] -> do
              aggName a `shouldBe` "Reservation"
              length (aggStates a) `shouldBe` 6
              length (aggCommands a) `shouldBe` 2
              length (aggEvents a) `shouldBe` 2
              length (aggTransitions a) `shouldBe` 2
              map stTerminal (aggStates a) `shouldBe` [False, False, False, True, True, True]
            other -> expectationFailure ("expected one aggregate node, got " <> show (length other))

  describe "validator" $ do
    it "accepts the canonical reservation.keiro" $ do
      codes <- errorCodesOf "test/fixtures/reservation.keiro"
      codes `shouldBe` []
    it "rejects policy words that generated Haskell cannot lower" $ do
      emitSpec <- specOf "test/fixtures/emit.keiro"
      intakeSpec <- specOf "test/fixtures/intake.keiro"
      let unknownOrdering = mapPublisher (\publisher -> publisher {pubOrdering = "banana"}) emitSpec
          unknownBackoff =
            mapPublisher
              (\publisher -> publisher {pubBackoff = (pubBackoff publisher) {boKind = "banana"}})
              emitSpec
          incompleteBackoff =
            mapPublisher
              (\publisher -> publisher {pubBackoff = BackoffSpec "exponential" "2s" Nothing Nothing})
              emitSpec
          unknownDedupe = mapIntake (\intake -> intake {inkDedupePolicy = "Banana"}) intakeSpec
      errorCodes unknownOrdering `shouldContain` [PublisherOrderingUnknown]
      errorCodes unknownBackoff `shouldContain` [PublisherBackoffInvalid]
      errorCodes incompleteBackoff `shouldContain` [PublisherBackoffInvalid]
      errorCodes unknownDedupe `shouldContain` [IntakeDedupePolicyUnknown]
    it "gates numeric floors on the unreleased language-4 contract" $ do
      emitSpec <- specOf "test/fixtures/emit.keiro"
      intakeSpec <- specOf "test/fixtures/intake.keiro"
      readModelSpec <- specOf "test/fixtures/workflow.keiro"
      let zeroContract = mapContract (\contract -> contract {ctrSchemaVersion = 0}) emitSpec
          zeroAttempts = mapPublisher (\publisher -> publisher {pubMaxAttempts = 0}) emitSpec
          zeroDecode = mapIntake (\intake -> intake {inkDecode = (inkDecode intake) {decBodySchemaVersion = 0}}) intakeSpec
          zeroReadModel = modifyReadModel "transferDecision" (\readModel -> readModel {rmVersion = 0}) readModelSpec
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
              (\aggregate -> aggregate {aggCommands = updateFirst (\command -> command {cmdFields = duplicateFirst (cmdFields command)}) (aggCommands aggregate)})
              reservation
          duplicateState = modifyAggregate "Reservation" (\aggregate -> aggregate {aggStates = duplicateFirst (aggStates aggregate)}) reservation
          duplicateTransition =
            modifyAggregate
              "Reservation"
              (\aggregate -> aggregate {aggTransitions = aggTransitions aggregate <> take 1 (reverse (aggTransitions aggregate))})
              reservation
          duplicateContractField =
            mapContract
              (\contract -> contract {ctrEvents = updateFirst (\event -> event {ceFields = duplicateFirst (ceFields event)}) (ctrEvents contract)})
              integration
          duplicateContractEvent = mapContract (\contract -> contract {ctrEvents = duplicateFirst (ctrEvents contract)}) integration
          duplicateTopicAlias = mapContract (\contract -> contract {ctrTopics = duplicateFirst (ctrTopics contract)}) integration
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
      let duplicateRegister = modifyAggregate "Reservation" (\aggregate -> aggregate {aggRegs = duplicateFirst (aggRegs aggregate)}) reservation
          duplicateNominal = reservation {specIds = duplicateFirst (specIds reservation)}
          duplicateMap = mapEmit (\emitNode -> emitNode {emMap = duplicateFirst (emMap emitNode)}) integration
          shadowDiscriminator =
            mapContract
              ( \contract ->
                  contract
                    { ctrEvents =
                        updateFirst
                          (\event -> event {ceFields = updateFirst (\field -> field {cfName = ctrDiscriminator contract}) (ceFields event)})
                          (ctrEvents contract)
                    }
              )
              integration
          guardedSibling =
            modifyAggregate
              "Reservation"
              ( \aggregate ->
                  aggregate
                    { aggTransitions =
                        aggTransitions aggregate
                          <> [transition {tGuard = Just (EAtom (ABool True))} | transition <- take 1 (reverse (aggTransitions aggregate))]
                    }
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
      let invalidIdentity = mapWorkflow (\workflow -> workflow {wfStable = ""}) workflowSpec
          duplicateIdentity =
            processSpec
              { specNodes =
                  specNodes processSpec
                    <> [NRouter (router {rtName = "surge-demo"}) | NRouter router <- specNodes routerSpec]
              }
          invalidTopic = mapContract (\contract -> contract {ctrTopics = [(alias, "bad topic") | (alias, _) <- ctrTopics contract]}) integration
          emptyTopic = mapContract (\contract -> contract {ctrTopics = [(alias, "") | (alias, _) <- ctrTopics contract]}) integration
          invalidReadModel = modifyReadModel "transferDecision" (\readModel -> readModel {rmTable = "Bad-Table"}) workflowSpec
          duplicateColumn = modifyReadModel "transferDecision" (\readModel -> readModel {rmColumns = duplicateFirst (rmColumns readModel)}) workflowSpec
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
              (\intake -> intake {inkBinds = updateFirst (\binding -> binding {brField = "ghost"}) (inkBinds intake)})
              intakeSpec
          acceptedEventBind =
            mapIntake
              (\intake -> intake {inkBinds = updateFirst (\binding -> binding {brField = "region"}) (inkBinds intake)})
              intakeSpec
          unresolvedDedupe = mapIntake (\intake -> intake {inkDedupeKey = "ghost"}) intakeSpec
          unknownEnvelope = mapIntake (\intake -> intake {inkDecode = (inkDecode intake) {decEnvelope = "banana policy"}}) intakeSpec
          mismatchedSchema = mapIntake (\intake -> intake {inkDecode = (inkDecode intake) {decBodySchemaVersion = 2}}) intakeSpec
          unresolvedAlias =
            mapContract
              (\contract -> contract {ctrEvents = updateFirst (\event -> event {ceTopic = "ghost"}) (ctrEvents contract)})
              intakeSpec
          unsupportedWire =
            modifyAggregate
              "Reservation"
              (\aggregate -> aggregate {aggWire = fmap (\wire -> wire {wireKind = "banana"}) (aggWire aggregate)})
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
    it "pins every emitted legacy single-spec diagnostic that lacked a direct negative test" $ do
      reservation <- specOf "test/fixtures/reservation.keiro"
      intakeSpec <- specOf "test/fixtures/intake.keiro"
      emitSpec <- specOf "test/fixtures/emit.keiro"
      processSpec <- specOf "test/fixtures/surge-service.keiro"
      queueSpec <- specOf "test/fixtures/reservation-work.keiro"
      workflowSpec <- specOf "test/fixtures/workflow.keiro"
      let updateFirstTransition update aggregate = aggregate {aggTransitions = updateFirst update (aggTransitions aggregate)}
          undeclaredEvent = modifyAggregate "Reservation" (updateFirstTransition (\transition -> transition {tEmits = ["GhostEvent"]})) reservation
          undeclaredState = modifyAggregate "Reservation" (updateFirstTransition (\transition -> transition {tGoto = "GhostState"})) reservation
          terminalOutgoing = modifyAggregate "Reservation" (updateFirstTransition (\transition -> transition {tSource = "Expired"})) reservation
          deprecatedEmitted = modifyAggregate "Reservation" (\aggregate -> aggregate {aggEvents = updateFirst (\event -> event {evDeprecated = True}) (aggEvents aggregate)}) reservation
          wireVersionMismatch = modifyAggregate "Reservation" (\aggregate -> aggregate {aggWire = fmap (\wire -> wire {wireSchemaVersion = 2}) (aggWire aggregate)}) reservation
          decodeRetry =
            mapIntake
              ( \intake ->
                  intake
                    { inkDisposition =
                        [ if drOutcome row == "decodeFailed" then row {drAction = IRetry "5s"} else row
                        | row <- inkDisposition intake
                        ]
                    }
              )
              intakeSpec
          unresolvedPublisher = mapPublisher (\publisher -> publisher {pubEmit = "ghost"}) emitSpec
          unresolvedIntake = mapIntake (\intake -> intake {inkContract = "ghost"}) intakeSpec
          unboundedQueue = mapWorkqueue (\queue -> queue {wqMaxRetries = 0}) queueSpec
          unresolvedEnqueue = mapDispatch (\dispatch -> dispatch {pdEnqueueTo = "ghost"}) queueSpec
          unresolvedWorkflow =
            mapOperation
              ( \operation -> case opShape operation of
                  RunOp _ input outcome -> operation {opShape = RunOp "GhostWorkflow" input outcome}
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
      codes `shouldNotContain` [DuplicateUpcasterSource]
    it "rejects a gap in the aggregate-global upcaster chain" $ do
      codes <- errorCodesOf "test/fixtures/reservation-chain-gap.keiro"
      codes `shouldContain` [UpcasterChainGap]
    it "warns while a retiring event keeps its live emitting transition" $ do
      diagnostics <- diagnosticsOf "test/fixtures/reservation-retiring.keiro"
      [code d | d <- diagnostics, severity d == Error] `shouldBe` []
      [code d | d <- diagnostics, severity d == Warning]
        `shouldContain` [EventRetirementInProgress]
    it "rejects a retiring event after its live emitting transition disappears" $ do
      source <- readTestText "test/fixtures/reservation-retiring.keiro"
      spec <- parseInlineSpec "<retiring-without-emitter>" (T.replace "emit TransferReservationConfirmed ; " "" source)
      [code d | d <- validateSpec spec, severity d == Error]
        `shouldContain` [EventRetirementInProgress]
    it "warns when a deprecated event has no replay-only emitting transition" $ do
      diagnostics <- diagnosticsOf "test/fixtures/reservation-deprecated.keiro"
      [code d | d <- diagnostics, severity d == Error] `shouldBe` []
      [code d | d <- diagnostics, severity d == Warning]
        `shouldContain` [DeprecatedEventReplayHazard]
    it "recognises deprecated plus replay-only as the replay-safe cutover" $ do
      diagnostics <- diagnosticsOf "test/fixtures/reservation-deprecated-replay-only.keiro"
      [code d | d <- diagnostics, severity d == Error] `shouldBe` []
      [code d | d <- diagnostics, severity d == Warning]
        `shouldContain` [EventRetirementInProgress]
      [code d | d <- diagnostics] `shouldNotContain` [DeprecatedEventReplayHazard]
    it "requires exact, unique status-map event keys" $ do
      dangling <- errorCodesOf "test/fixtures/statusmap-dangling.keiro"
      mapM_ (\expected -> dangling `shouldContain` [expected]) [StatusMapDanglingKey, StatusMapNotTotal]
      duplicate <- errorCodesOf "test/fixtures/statusmap-dup-key.keiro"
      duplicate `shouldContain` [StatusMapDuplicateKey]
    it "rejects duplicate spec and aggregate names" $ do
      codes <- errorCodesOf "test/fixtures/duplicate-names.keiro"
      mapM_
        (\expected -> codes `shouldContain` [expected])
        [ DuplicateNodeName,
          DuplicateEnumCtor,
          DuplicateEnumWire,
          DuplicateIdPrefix,
          DuplicateCommandName,
          DuplicateEventName
        ]
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
          [line d | d <- validateSpec spec, code d == UnreachableState]
            `shouldBe` [7]
    it "accepts a replay-only twin with a live sibling (plan 143)" $ do
      codes <- errorCodesOf "test/fixtures/reservation-guard-tightened-twin.keiro"
      codes `shouldBe` []
    it "rejects a replay-only transition that emits nothing" $ do
      case parseSpec "<replay-only-no-emit>" (replayOnlySpecWith ["    write reservationState := Held", "    goto  Held"]) of
        Left err -> expectationFailure (T.unpack err)
        Right spec ->
          [code d | d <- validateSpec spec, severity d == Error]
            `shouldContain` [ReplayOnlyEmitsNothing]
    it "warns when a replay-only transition has no live sibling" $ do
      case parseSpec "<replay-only-orphan>" (replayOnlySpecWith ["    emit  TransferReservationCreated", "    goto  Held"]) of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> do
          [code d | d <- validateSpec spec, severity d == Warning]
            `shouldContain` [ReplayOnlyCommandStillLive]
          [code d | d <- validateSpec spec, severity d == Error]
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
                  [tGuard t | NAggregate a <- specNodes spec, t <- aggTransitions a]
                    === [Just (complementExpr e)]

  describe "evolution parsing" $ do
    it "parses event version and upcaster from reservation-v2.keiro" $ do
      input <- readTestText "test/fixtures/reservation-v2.keiro"
      case parseSpec "test/fixtures/reservation-v2.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> case [e | NAggregate a <- specNodes spec, e <- aggEvents a, evName e == "TransferReservationCreated"] of
          (e : _) -> do
            evVersion e `shouldBe` 2
            evUpcastFrom e `shouldBe` Just (1, Hole)
          [] -> expectationFailure "TransferReservationCreated not found"
    it "round-trips the retiring marker" $ do
      spec <- specOf "test/fixtures/reservation-retiring.keiro"
      parseStableRenderedSpec "<retiring-round-trip>" spec `shouldBe` Right spec
      [evRetiring event | NAggregate aggregate <- specNodes spec, event <- aggEvents aggregate, evName event == "TransferReservationConfirmed"]
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
      case [aggregate | NAggregate aggregate <- specNodes spec] of
        [aggregate] -> aggSnapshot aggregate `shouldBe` Just (SnapshotSpec (SnapEvery 100) 1 "7a181ceb7d798d883d28c85201c5c1692bd314a7b489da9128bff91e0f38cd28" noLoc)
        aggregates -> expectationFailure ("expected one snapshot aggregate, got " <> show (length aggregates))
    it "rejects disabled intervals and invalid codec fixtures" $ do
      source <- readTestText "test/fixtures/reservation-snapshot.keiro"
      interval <- parseInlineSpec "<snapshot-zero>" (T.replace "snapshot every 100" "snapshot every 0" source)
      map code (validateSpec interval) `shouldContain` [SnapshotIntervalInvalid]
      version <- parseInlineSpec "<snapshot-version-zero>" (T.replace "state-codec version=1" "state-codec version=0" source)
      map code (validateSpec version) `shouldContain` [SnapshotCodecFixtureInvalid]
      emptyHash <- parseInlineSpec "<snapshot-empty-hash>" (T.replace "shape-hash=\"7a181ceb7d798d883d28c85201c5c1692bd314a7b489da9128bff91e0f38cd28\"" "shape-hash=\"\"" source)
      map code (validateSpec emptyHash) `shouldContain` [SnapshotCodecFixtureInvalid]
    it "conditionally lowers JSON instances and the live defaultStateCodec" $ do
      snapshotService <- checkedServiceOf "test/fixtures/reservation-snapshot.keiro"
      ordinaryService <- checkedServiceOf "test/fixtures/reservation.keiro"
      let snapshot = checkedSpec snapshotService
          ordinary = checkedSpec ordinaryService
      case ([aggregate | NAggregate aggregate <- specNodes snapshot], [aggregate | NAggregate aggregate <- specNodes ordinary]) of
        ([snapshotAggregate], [ordinaryAggregate]) -> do
          let snapshotModules = scaffoldServiceModules (defaultContext (specContext snapshot)) snapshotService
              ordinaryModules = scaffoldServiceModules (defaultContext (specContext ordinary)) ordinaryService
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
        Right spec -> case [p | NProcess p <- specNodes spec] of
          (p : _) -> do
            procId p `shouldBe` "HospitalSurge"
            procName p `shouldBe` "hospital-surge"
            procRejected p `shouldBe` PolHalt
            procPoison p `shouldBe` PolHalt
            sagaCategory (procSaga p) `shouldBe` "hospitalSurge"
            tmName (procTimer p) `shouldBe` "surgeFollowUp"
            onReject (fireDisposition (tmFire (procTimer p))) `shouldBe` OFired
            onAmbiguous (fireDisposition (tmFire (procTimer p))) `shouldBe` ORetry
            tmMaxAttempts (procTimer p) `shouldBe` 5
          [] -> expectationFailure "no process node parsed"
    it "round-trips the hospital-surge spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/hospital-surge.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseStableRenderedSpec "in" spec `shouldBe` Right spec
    it "accepts the hospital-surge spec (no errors; benign-inversion warnings only)" $ do
      codes <- errorCodesOf "test/fixtures/hospital-surge.keiro"
      codes `shouldBe` []
    it "rejects illegal saga categories and no longer parses the raw stream-prefix clause" $ do
      spec <- specOf "test/fixtures/hospital-surge.keiro"
      mapM_
        (\categoryName -> processErrorCodes (\process -> process {procSaga = (procSaga process) {sagaCategory = categoryName}}) spec `shouldContain` [SagaCategoryIllegal])
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

  describe "router (EP-108)" $ do
    it "parses the incident-paging router shape" $ do
      input <- readTestText "test/fixtures/incident-paging/incident-paging.keiro"
      case parseSpec "test/fixtures/incident-paging/incident-paging.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> case [router | NRouter router <- specNodes spec] of
          [router] -> do
            rtId router `shouldBe` "PagingRouter"
            rtName router `shouldBe` "jitsurei-paging"
            corrField (rtKey router) `shouldBe` "incidentId"
            rvSource (rtResolve router) `shouldBe` ResolveReadModel "service_oncall"
            rvRow (rtResolve router) `shouldBe` ["responderId"]
            rdCommand (rtDispatch router) `shouldBe` "SendPage"
            rtRejected router `shouldBe` PolDeadLetter
            rtPoison router `shouldBe` PolHalt
          routers -> expectationFailure ("expected one router, got " <> show (length routers))
    it "round-trips the incident-paging spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/incident-paging/incident-paging.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseStableRenderedSpec "in" spec `shouldBe` Right spec
    it "accepts the incident-paging router with warnings only" $ do
      codes <- errorCodesOf "test/fixtures/incident-paging/incident-paging.keiro"
      codes `shouldBe` []
      diagnostics <- diagnosticCodesOf "test/fixtures/incident-paging/incident-paging.keiro"
      diagnostics `shouldContain` [PolicyDeadLetterUnused, AmbiguousFollowsRejectedPolicy]
    it "rejects unresolved targets, keys, commands, and binding scopes" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      routerErrorCodes (\router -> router {rtTarget = "Pge"}) spec `shouldContain` [RouterUnresolvedRef]
      routerErrorCodes (\router -> router {rtKey = (rtKey router) {corrField = "incidntId"}}) spec `shouldContain` [RouterKeyFieldUnknown]
      routerErrorCodes (\router -> router {rtDispatch = (rtDispatch router) {rdCommand = "SendPag"}}) spec `shouldContain` [RouterCommandUnknown]
      routerErrorCodes
        ( \router ->
            let dispatch = rtDispatch router
             in router {rtDispatch = dispatch {rdFields = [FieldBinding "responderId" (Just "resolved.responder")]}}
        )
        spec
        `shouldContain` [RouterBindingUnscoped]
    it "rejects unresolved read models and contradictory rejection policies" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      let withoutReadModel = removeReadModel "service_oncall" spec
      errorCodes withoutReadModel `shouldContain` [RouterUnresolvedRef]
      routerErrorCodes
        ( \router ->
            let dispatch = rtDispatch router
                disposition = rdDisposition dispatch
             in router
                  { rtRejected = PolHalt,
                    rtDispatch = dispatch {rdDisposition = disposition {onFailed = DDeadLetter "page rejected"}}
                  }
        )
        spec
        `shouldContain` [PolicyContradiction]
    it "rejects on-ambiguous Fired for process timers" $ do
      spec <- specOf "test/fixtures/hospital-surge.keiro"
      let changed =
            spec
              { specNodes =
                  [ case node of
                      NProcess process ->
                        let timer = procTimer process
                            fire = tmFire timer
                            disposition = fireDisposition fire
                         in NProcess process {procTimer = timer {tmFire = fire {fireDisposition = disposition {onAmbiguous = OFired}}}}
                      _ -> node
                  | node <- specNodes spec
                  ]
              }
      errorCodes changed `shouldContain` [AmbiguousMarkedBenign]
    it "requires explicit policy and ambiguity clauses in the grammar" $ do
      source <- readTestText "test/fixtures/hospital-surge.keiro"
      parseSpec "<missing-poison>" (T.replace "  poison => halt\n" "" source) `shouldSatisfy` isLeft
      parseSpec "<missing-ambiguous>" (T.replace " ; on-ambiguous Retry" "" source) `shouldSatisfy` isLeft
    it "scaffolds firewall-clean router wiring, policies, and typed-hole guidance" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      case [router | NRouter router <- specNodes spec] of
        [router] -> do
          let ctx = defaultContext (specContext spec)
              modules = scaffoldRouter ctx router
              generated = [m | m <- modules, kind m == Generated]
              holes = [m | m <- modules, kind m == HoleStub]
          firewallBreaches generated `shouldBe` []
          case (generated, holes) of
            ([generatedModule], [holeModule]) -> do
              moduleText generatedModule `shouldSatisfy` T.isInfixOf "pagingRouterWorkerOptions"
              moduleText generatedModule `shouldSatisfy` T.isInfixOf "rejectedCommandPolicy = RejectedDeadLetter"
              moduleText holeModule `shouldSatisfy` T.isInfixOf "UNION of resolved target identities"
              moduleText holeModule `shouldSatisfy` T.isInfixOf "confirmBenignDuplicate"
            _ -> expectationFailure "expected one generated router module and one router hole module"
        routers -> expectationFailure ("expected one router, got " <> show (length routers))
    it "requires a caller callback for non-halting poison policies" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      case [router | NRouter router <- specNodes spec] of
        [router] -> do
          let ctx = defaultContext (specContext spec)
              generatedFor choice = [moduleText m | m <- scaffoldRouter ctx router {rtPoison = choice}, kind m == Generated]
          mapM_
            ( \(choice, constructor) -> case generatedFor choice of
                [generatedModule] -> do
                  generatedModule `shouldSatisfy` T.isInfixOf "(Envelope msg -> Eff es ()) -> WorkerOptions es msg"
                  generatedModule `shouldSatisfy` T.isInfixOf (constructor <> " poisonCallback")
                _ -> expectationFailure "expected one generated router module"
            )
            [(PolDeadLetter, "PoisonDeadLetter"), (PolSkip, "PoisonSkip")]
          case [moduleText m | m <- scaffoldRouter ctx router {rtRejected = PolSkip}, kind m == Generated] of
            [generatedModule] -> generatedModule `shouldSatisfy` T.isInfixOf "rejectedCommandPolicy = RejectedSkip"
            _ -> expectationFailure "expected one generated router module"
        routers -> expectationFailure ("expected one router, got " <> show (length routers))
    it "emits router harness facts that pin policy and target-keyed identity" $ do
      spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      case [router | NRouter router <- specNodes spec] of
        [router] -> case harnessRouter (defaultContext (specContext spec)) router of
          [facts] -> do
            moduleText facts `shouldSatisfy` T.isInfixOf "(\"rejectedPolicy\", \"deadLetter\")"
            moduleText facts `shouldSatisfy` T.isInfixOf "targetStreamName, occurrence"
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
      let gens = [m | m <- mods, kind m == Generated]
          holes = [m | m <- mods, kind m == HoleStub]
      length holes `shouldBe` 1
      firewallBreaches gens `shouldBe` []
      case gens of
        [generatedModule] -> do
          -- the worker uses the spec's ceiling, never the dangerous default
          moduleText generatedModule `shouldSatisfy` T.isInfixOf "max-attempts = 5"
          moduleText generatedModule `shouldSatisfy` T.isInfixOf "hospitalSurgeProcessWorkerOptions"
          moduleText generatedModule `shouldSatisfy` T.isInfixOf "import Generated.HospitalCapacity.Surge.EventStream (SurgeEventStreamDef)"
          moduleText generatedModule `shouldSatisfy` T.isInfixOf "hospitalSurgeCategory :: Stream.StreamCategory SurgeEventStreamDef"
          moduleText generatedModule `shouldSatisfy` T.isInfixOf "hospitalSurgeCategory = Stream.categoryUnsafe \"hospitalSurge\""
          moduleText generatedModule `shouldSatisfy` T.isInfixOf "confirmBenignDuplicate"
          moduleText generatedModule `shouldSatisfy` T.isInfixOf "StreamName -> EventId -> CommandError -> Eff es Bool"
          moduleText generatedModule `shouldSatisfy` T.isInfixOf "Left (CommandAmbiguous _)"
          case holes of
            [holeModule] -> moduleText holeModule `shouldSatisfy` T.isInfixOf "entityStream hospitalSurgeCategory"
            _ -> expectationFailure "expected one process hole module"
        _ -> expectationFailure "expected one generated process module"
    it "process scaffold is deterministic" $ do
      a <- legacyScaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
      b <- legacyScaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
      map moduleText a `shouldBe` map moduleText b
    it "separates aggregate event-stream and command-target categories and emits stable typed sums" $ do
      spec <- specOf "test/fixtures/hospital-surge.keiro"
      let ctx = defaultContext (specContext spec)
          modules = concat [scaffoldAggregate ctx spec aggregate | NAggregate aggregate <- specNodes spec]
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
        Right spec -> case [c | NContract c <- specNodes spec] of
          (c : _) -> do
            ctrName c `shouldBe` "emergency"
            ctrDiscriminator c `shouldBe` "messageType"
            map fst (ctrTopics c) `shouldBe` ["incidentEvents", "hospitalEvents"]
            map ceName (ctrEvents c) `shouldBe` ["IncidentTransferNeedDeclared", "TransferReservationAccepted"]
          [] -> expectationFailure "no contract node parsed"

    it "branches contract scaffolding, manifests, and durable identities only for language 4" $ do
      sourceText <- readTestText "test/fixtures/contract-v4.keiro"
      parsed <- case parseSource "contract-v4.keiro" sourceText of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      let service = checkedSource parsed
          spec = checkedSpec service
          ctx = defaultContext (specContext spec)
      contract <- case [value | NContract value <- specNodes spec] of
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
      normalizeGenerated (moduleText typedModule) `shouldBe` normalizeGenerated committed
      moduleText legacyModule `shouldSatisfy` T.isInfixOf "incidentId :: !Text"
      moduleText legacyModule `shouldSatisfy` (not . T.isInfixOf "KindID")
      moduleText typedModule `shouldSatisfy` T.isInfixOf "incidentId :: !(KindID \"inc\")"
      moduleText typedModule `shouldSatisfy` T.isInfixOf "KindID.toText payload.incidentId"
      moduleText typedModule `shouldSatisfy` T.isInfixOf "explicitParseField (parseKindIdV7Value @\"inc\") o \"incidentId\""
      moduleText typedModule `shouldSatisfy` T.isInfixOf "  , incidentEventsTopic"
      moduleText typedModule `shouldSatisfy` T.isInfixOf "  , hospitalEventsTopic"
      moduleText typedModule `shouldSatisfy` (not . T.isInfixOf "Wno-unused-top-binds")
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
          ctx = defaultContext (specContext spec)
          modules = scaffoldServiceModules ctx service
          identities = idDomainIdentitiesForService service
      duplicateIdentity <- case identities of
        value : _ -> pure value
        [] -> expectationFailure "typed contract service did not expose ID-domain identities" >> fail "unreachable"
      withTempDirectory "keiro-dsl-v4-contract-record" $ \out -> do
        result <- executeServiceScaffold out False "contract-v4.keiro" (parsedSourceLanguage parsed) ctx service modules
        result `shouldSatisfy` isRight
        contents <- TIO.readFile (out </> recordFileName (specContext spec))
        record <- maybe (expectationFailure "typed contract scaffold record did not parse" >> fail "unreachable") pure (parseRecord contents)
        recIdDomains record `shouldBe` identities
        parseRecord (contents <> "id-domain " <> duplicateIdentity <> "\n") `shouldBe` Nothing

      let manifest = "service hospital-capacity\nspec domain/contract.keiro\n"
          source = memoryContentSource (Map.fromList [("service.keiro-workspace", manifest), ("domain/contract.keiro", sourceText)])
      loaded <- loadWorkspace source "service.keiro-workspace"
      workspace <- either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure loaded
      workspacePlan <- either (\refusals -> expectationFailure (show refusals) >> fail "unreachable") pure (planWorkspaceScaffold "goldens" ctx workspace)
      case [provenance | (scaffoldModule, provenance) <- wpModules workspacePlan, modulePath scaffoldModule == "Generated/HospitalCapacity/Emergency/Contract.hs"] of
        [MemberOwned owner] -> owner `shouldBe` "domain/contract.keiro"
        values -> expectationFailure ("expected one member-owned contract module, got " <> show values)
      withTempDirectory "keiro-dsl-v4-contract-workspace-record" $ \out -> do
        result <- executeWorkspaceScaffold out False workspacePlan
        result `shouldSatisfy` isRight
        contents <- TIO.readFile (out </> workspaceRecordFileName (wsService workspace))
        record <- maybe (expectationFailure "typed contract workspace record did not parse" >> fail "unreachable") pure (parseWorkspaceRecord contents)
        wrIdDomains record `shouldBe` identities
        [(wrmPath row, wrmOwner row) | row <- wrModules record, wrmPath row == "Generated/HospitalCapacity/Emergency/Contract.hs"]
          `shouldBe` [("Generated/HospitalCapacity/Emergency/Contract.hs", Just "domain/contract.keiro")]
        parseWorkspaceRecord (contents <> "id-domain " <> duplicateIdentity <> "\n") `shouldBe` Nothing
    it "round-trips the contract spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/contract.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
    it "round-trips the intake (inbox) spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/intake.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
    it "accepts the intake spec (complete disposition, no inversions)" $ do
      codes <- errorCodesOf "test/fixtures/intake.keiro"
      codes `shouldBe` []
    it "lowers explicit dedupe-only persistence and defaults omission to full-envelope" $ do
      spec <- specOf "test/fixtures/intake.keiro"
      ordinary <- specOf "test/fixtures/intake-decode.keiro"
      case ([intake | NIntake intake <- specNodes spec], [intake | NIntake intake <- specNodes ordinary]) of
        ([intake], [defaultIntake]) -> do
          inkPersist intake `shouldBe` InkPersistDedupeOnly
          inkPersist defaultIntake `shouldBe` InkPersistFull
          renderSpec spec `shouldSatisfy` T.isInfixOf "persist = dedupe-only"
          renderSpec ordinary `shouldNotSatisfy` T.isInfixOf "persist ="
          let inbox = generatedTextEndingIn "Inbox.hs" (scaffoldIntake (defaultContext (specContext spec)) intake)
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
      let duplicateDiagnostics = [d | d <- validateSpec duplicateSpec, code d == DispositionDuplicateOutcome]
      map line duplicateDiagnostics `shouldBe` [18]
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
      map code (validateSpec unresolved) `shouldContain` [WqGroupKeyUnresolved]
    it "warns on unlogged storage and rejects empty partition settings" $ do
      warningCodes <- diagnosticCodesOf "test/fixtures/reservation-work-unlogged.keiro"
      warningCodes `shouldContain` [WqUnloggedDurability]
      partitionCodes <- errorCodesOf "test/fixtures/reservation-work-partitioned-empty.keiro"
      partitionCodes `shouldContain` [WqPartitionSpecEmpty]
    it "lowers ordering, provisioning, and raw group-key projection" $ do
      spec <- specOf "test/fixtures/reservation-work.keiro"
      case [workqueue | NWorkqueue workqueue <- specNodes spec] of
        workqueue : _ -> do
          let modules = scaffoldWorkqueue (defaultContext (specContext spec)) workqueue
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
      case [readModel | NReadModel readModel <- specNodes spec] of
        [subscriptionModel, inlineModel] -> do
          rmName subscriptionModel `shouldBe` "transfer_decisions"
          rmColumns subscriptionModel
            `shouldBe` [ RmColumn "reservation_id" "text" True,
                         RmColumn "hospital_id" "text" True,
                         RmColumn "status" "text" True,
                         RmColumn "decided_at" "timestamptz" False
                       ]
          rmScope subscriptionModel `shouldBe` Just (RmCategory "reservation")
          rmFeed subscriptionModel `shouldBe` RmSubscription
          rmSubscription subscriptionModel `shouldBe` Just "hospital-capacity-transfer-decisions-sub"
          rmName inlineModel `shouldBe` "subscriptions"
          rmScope inlineModel `shouldBe` Nothing
          rmFeed inlineModel `shouldBe` RmInline
        nodes -> expectationFailure ("expected two readmodel nodes, got " <> show (length nodes))
      parseStableRenderedSpec "in" spec `shouldBe` Right spec
    it "accepts an aggregate projection without a consistency clause" $ do
      spec <- parseInlineSpec "<projection-without-consistency>" projectionWithoutConsistencySpec
      case [projection | NAggregate aggregate <- specNodes spec, Just projection <- [aggProjection aggregate]] of
        [projection] -> projConsistency projection `shouldBe` Nothing
        projections -> expectationFailure ("expected one projection, got " <> show (length projections))
    it "pins the canonical UTF-8 shape digest and runtime identities" $ do
      spec <- specOf "test/fixtures/readmodel.keiro"
      case [readModel | NReadModel readModel <- specNodes spec] of
        (subscriptionModel : inlineModel : _) -> do
          canonicalShape subscriptionModel
            `shouldBe` "transfer_decisions|reservation_id:text:req|hospital_id:text:req|status:text:req|decided_at:timestamptz:null"
          deriveShapeHash subscriptionModel `shouldBe` "fnv1a:3717f6d9e3c44bd6"
          deriveShapeHash inlineModel `shouldBe` "fnv1a:f54d9bb2f40a6738"
          registryNameFor (specContext spec) subscriptionModel `shouldBe` "hospital-capacity-transfer-decisions"
          subscriptionNameFor (specContext spec) subscriptionModel `shouldBe` "hospital-capacity-transfer-decisions-sub"
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
      map code diagnostics `shouldContain` [RmStrongInlineOnly, RmProjectionWithoutNode]
      [severity diagnostic | diagnostic <- diagnostics, code diagnostic == RmProjectionWithoutNode]
        `shouldBe` [Warning]
    it "rejects scope without Strong and an unreferenced inline feed" $ do
      scopeCodes <- errorCodesOf "test/fixtures/readmodel-scope-eventual.keiro"
      scopeCodes `shouldContain` [RmScopeWithoutStrong]
      inlineCodes <- errorCodesOf "test/fixtures/readmodel-inline-unreferenced.keiro"
      inlineCodes `shouldContain` [RmInlineFeedUnreferenced]
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
      let ctx = defaultContext (specContext spec)
          readModels = [readModel | NReadModel readModel <- specNodes spec]
          modules = concatMap (scaffoldReadModel ctx) readModels
          transfer = generatedTextEndingIn "Transfer_decisions/ReadModel.hs" modules
          inline = generatedTextEndingIn "Subscriptions/ReadModel.hs" modules
          transferHoles = [moduleText m | m <- modules, "Transfer_decisions/ReadModelHoles.hs" `T.isSuffixOf` T.pack (modulePath m)]
      length modules `shouldBe` 6
      length [m | m <- modules, kind m == Generated] `shouldBe` 4
      length [m | m <- modules, kind m == HoleStub] `shouldBe` 2
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
      case [aggregate | NAggregate aggregate <- specNodes spec] of
        [aggregate] -> do
          let modules = scaffoldAggregate (defaultContext (specContext spec)) spec aggregate
              holes = [moduleText m | m <- modules, kind m == HoleStub]
              projection = generatedTextEndingIn "Projection.hs" modules
          holes `shouldSatisfy` any (T.isInfixOf "subscriptionsQualifiedTable")
          holes `shouldSatisfy` any (T.isInfixOf "Table: \"billing\".\"subscriptions\"")
          projection `shouldSatisfy` T.isInfixOf "ReadModelTable.subscriptionsQualifiedTable"
        aggregates -> expectationFailure ("expected one aggregate, got " <> show (length aggregates))
    it "emits runtime-free derivation facts for each read model" $ do
      spec <- specOf "test/fixtures/readmodel.keiro"
      case [readModel | NReadModel readModel <- specNodes spec] of
        (subscriptionModel : _) -> do
          let modules = harnessReadModel (defaultContext (specContext spec)) subscriptionModel
              harnessText = generatedTextEndingIn "ReadModelHarness.hs" modules
          length modules `shouldBe` 1
          firewallBreaches modules `shouldBe` []
          harnessText `shouldSatisfy` T.isInfixOf "(\"shapeHash\", \"fnv1a:3717f6d9e3c44bd6\", \"fnv1a:3717f6d9e3c44bd6\")"
          harnessText `shouldSatisfy` T.isInfixOf "(\"strongScope\", \"CategoryHead reservation\", \"CategoryHead reservation\")"
          harnessText `shouldSatisfy` T.isInfixOf "runReadModelFacts"
        nodes -> expectationFailure ("expected readmodel nodes, got " <> show (length nodes))

  describe "workflow/operation (EP-6)" $ do
    it "round-trips the workflow spec through parse . pretty" $ do
      input <- readTestText "test/fixtures/workflow.keiro"
      case parseSpec "in" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> parseStableRenderedSpec "in" spec `shouldBe` Right spec
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
      case [workflow | NWorkflow workflow <- specNodes spec] of
        [workflow] -> do
          let modules = harnessWorkflow (defaultContext (specContext spec)) workflow
              facts = generatedTextEndingIn "WorkflowFacts.hs" modules
              runtime = generatedTextEndingIn "WorkflowRuntime.hs" modules
          facts `shouldSatisfy` T.isInfixOf "patch:fraud-check-v2(step:fraud-check)"
          facts `shouldSatisfy` T.isInfixOf "continueAsNew:RolloverSeed"
          facts `shouldSatisfy` T.isInfixOf "data WorkflowFacts = WorkflowFacts"
          facts `shouldSatisfy` T.isInfixOf "workflowFactBody = [\"step:create-transfer-hold\", \"patch:fraud-check-v2(step:fraud-check)\""
          facts `shouldSatisfy` T.isInfixOf "workflowFactAwaitLabels = [\"reservation-confirmation\"]"
          facts `shouldSatisfy` T.isInfixOf "workflowFactPatchIds = [\"fraud-check-v2\"]"
          runtime `shouldSatisfy` T.isInfixOf "declaredPatches = Set.fromList [PatchId \"fraud-check-v2\"]"
          runtime `shouldSatisfy` T.isInfixOf "opts{activePatches = declaredPatches}"
        workflows -> expectationFailure ("expected one workflow, got " <> show (length workflows))

  describe "replay impact" $ do
    it "treats new events and transitions as replay-neutral" $ do
      old <- specOf "test/fixtures/reservation.keiro"
      let aggregate = onlyAggregate old
      case (aggEvents aggregate, aggTransitions aggregate) of
        (event : _, transition : _) -> do
          let newEvent =
                event
                  { evName = "ReservationReviewed",
                    evLoc = noLoc
                  }
              newTransition =
                transition
                  { tEmits = ["ReservationReviewed"],
                    tLoc = noLoc
                  }
              new =
                modifyAggregate
                  "Reservation"
                  ( \candidate ->
                      candidate
                        { aggEvents = aggEvents candidate <> [newEvent],
                          aggTransitions = aggTransitions candidate <> [newTransition]
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
                    { aggTransitions =
                        [ transition {tGuard = Nothing}
                        | transition <- aggTransitions aggregate
                        ]
                    }
              )
              old
      replayImpactSpecs old loosened `shouldBe` ReplayNeutral

    it "pairs guard-disambiguated siblings independently of both declaration orders" $ do
      base <- specOf "test/fixtures/reservation.keiro"
      let aggregate = onlyAggregate base
      case (aggTransitions aggregate, aggEvents aggregate) of
        (prototype : _, firstEvent : secondEvent : _) -> do
          let sibling guardExpression eventName =
                prototype
                  { tGuard = guardExpression,
                    tEmits = [eventName],
                    tLoc = noLoc
                  }
              commandOverride = EPath noLoc CommandRoot ["lifeCriticalOverride"]
              exact = sibling (Just (EAtom (ABool True))) (evName firstEvent)
              loosenedOld = sibling (Just commandOverride) (evName firstEvent)
              loosenedNew = sibling Nothing (evName firstEvent)
              changedOld = sibling (Just (ECmp OpEq commandOverride (ELiteral noLoc (LiteralBool False)))) (evName secondEvent)
              changedNew = sibling (Just (ECmp OpEq commandOverride (ELiteral noLoc (LiteralBool True)))) (evName firstEvent)
              oldSiblings = [exact, loosenedOld, changedOld]
              newSiblings = [exact, loosenedNew, changedNew]
              withTransitions transitions =
                modifyAggregate
                  (aggName aggregate)
                  (\candidate -> candidate {aggTransitions = transitions})
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
          ReplayImpact.eventTypes <$> Map.lookup "Reservation" aggregates
            `shouldBe` Just (Set.fromList ["TransferReservationCreated", "TransferReservationConfirmed"])
        ReplayNeutral -> expectationFailure "expected a wire-clause replay impact"

    it "includes snapshot streams when a write expression changes" $ do
      impact <- replayImpactFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-foldchange.keiro"
      case impact of
        ReplayAffected aggregates ->
          includeSnapshotStreams <$> Map.lookup "Reservation" aggregates
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
      case scaffoldReplayAudit (defaultContext (specContext spec)) spec of
        [assembly] -> do
          modulePath assembly `shouldBe` "Generated/SurgeDemo/ReplayAudit.hs"
          moduleText assembly `shouldSatisfy` T.isInfixOf "Hospital.hospitalEventStream"
          moduleText assembly `shouldSatisfy` T.isInfixOf "Surge.surgeEventStream"
          T.count "      AuditTarget" (moduleText assembly) `shouldBe` 2
        assemblies -> expectationFailure ("expected one replay-audit assembly, got " <> show (length assemblies))

  describe "diff (evolution classification)" $ do
    it "covers every node family exactly once and explains exclusions" $ do
      sort (map fst familyRegistry) `shouldBe` ([minBound .. maxBound] :: [NodeFamily])
      [reason | (_, OutOfDiffScope reason) <- familyRegistry, T.null reason] `shouldBe` []
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
          deriveLabel defaultGate (ckVector (kindOfChange change))
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
      golden <- readTestText "test/fixtures/compatibility-vector.diff.golden"
      let rendered = T.intercalate "\n" (map renderFinding changes)
          explained = T.intercalate "\n" (map renderExplainBlock changes)
          reportJson = T.pack (show (Aeson.toJSON (diffReport defaultGate changes)))
      T.stripEnd rendered `shouldBe` T.stripEnd golden
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
              ckCode kind == EnumCtorAdded,
              verdictFor OldBinaryReadNewEvents (ckVector kind) == VBreaking
            ]
      eventEnumFindings `shouldSatisfy` all (not . gatedBreaking defaultGate)
      eventEnumFindings `shouldSatisfy` all (gatedBreaking (gateWith [OldBinaryReadNewEvents]))
      forM_ changes $ \change ->
        remediationFor (ckContext (kindOfChange change)) (ckCode (kindOfChange change))
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
        map (ckCode . kindOfChange) changes `shouldContain` [expectedCode]
        forM_ changes $ \change ->
          remediationFor (ckContext (kindOfChange change)) (ckCode (kindOfChange change))
            `shouldSatisfy` (not . null)
    it "separates mapped event migration, snapshot invalidation, and directional rollout" $ do
      breakingAdd <- diffFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-fieldadd-nodefault.keiro"
      let noDefault = [change | change <- breakingAdd, ckCode (kindOfChange change) == MappedFieldAddedNoDefault]
      [ckFacet kind | Breaking kind <- noDefault] `shouldContain` ["mapped-event"]
      [ckFacet kind | Advisory kind <- noDefault] `shouldContain` ["mapped-register"]
      defaulted <- diffFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-fieldadd-default.keiro"
      [change | change <- defaulted, isBreaking change] `shouldBe` []
      let eventDefaults = [kind | Advisory kind <- defaulted, ckCode kind == MappedFieldAddedWithDefault, ckFacet kind == "mapped-event"]
      eventDefaults `shouldSatisfy` any ((== VBreaking) . verdictFor OldBinaryReadNewEvents . ckVector)
      armAdded <- diffFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-armadd.keiro"
      [change | change <- armAdded, isBreaking change] `shouldBe` []
      [kind | Advisory kind <- armAdded, ckCode kind == MappedArmAdded, ckFacet kind == "mapped-event"]
        `shouldSatisfy` any ((== VBreaking) . verdictFor OldBinaryReadNewEvents . ckVector)
    it "propagates a nested mapped leaf to complete command, event, and register paths" $ do
      changes <- diffFixtures "test/fixtures/consumer-types.keiro" "test/fixtures/consumer-types-nested-propagation.keiro"
      let subjects =
            [ ckSubject kind
            | change <- changes,
              let kind = kindOfChange change,
              ckCode kind == MappedArmTagChanged
            ]
      subjects
        `shouldContain` [ "Catalog command ObserveArtifact .artifact : ArtifactInfo .location : ArtifactLocation .arm RepoPath[\"repository_path\"]",
                          "Catalog event ArtifactObserved .artifact : ArtifactInfo .location : ArtifactLocation .arm RepoPath[\"repository_path\"]",
                          "Catalog register currentArtifact : ArtifactInfo .location : ArtifactLocation .arm RepoPath[\"repository_path\"]"
                        ]
    it "classifies every remaining mapped field and declaration evolution row" $ do
      base <- specOf "test/fixtures/consumer-types.keiro"
      let mutationCodes =
            [ (mapArtifactNamedField "key" (\field -> field {wfType = TInt}) base, MappedFieldTypeChanged),
              (mapArtifactNamedField "key" (\field -> field {wfPresence = POptional, wfOnMissing = Just (OmText "")}) base, MappedPresenceChanged),
              (mapArtifactNamedField "key" (\field -> field {wfType = TOptional TText}) base, MappedNullabilityChanged),
              (mapArtifactNamedField "description" (\field -> field {wfOnMissing = Nothing}) base, MappedDefaultRemoved),
              (mapArtifactNamedField "count" (\field -> field {wfOnMissing = Just (OmInt 1)}) base, MappedDefaultChanged),
              (mapMappedStructural "ArtifactInfo" renameMappedRecordConstructor base, MappedRecordConstructorChanged),
              (mapMappedStructural "ArtifactInfo" changeMappedCanonical base, MappedCanonicalTypeChanged)
            ]
      forM_ mutationCodes $ \(candidate, expectedCode) ->
        map (ckCode . kindOfChange) (diffSpecs base candidate) `shouldContain` [expectedCode]
      let declarationA = completeStructural "A" (recordShape [TText])
          declarationB = completeStructural "B" (recordShape [TInt])
          onlyA = mappedSpec [declarationA]
          withB = mappedSpec [declarationA, declarationB]
      map (ckCode . kindOfChange) (diffSpecs onlyA withB) `shouldContain` [MappedDeclAdded]
      map (ckCode . kindOfChange) (diffSpecs withB onlyA) `shouldContain` [MappedDeclRemoved]
      diffSpecs base (mapArtifactNamedField "key" (\field -> field {wfHaskell = "renamedKey"}) base)
        `shouldBe` []
    it "visits every mapped wire mutation and reports every complete root path" $ do
      base <- specOf "test/fixtures/consumer-types.keiro"
      let mutations = mappedWireMutations base
      mutations `shouldSatisfy` (not . null)
      visited <- fmap Set.unions . forM mutations $ \mutation -> do
        let changes =
              [ change
              | change <- diffSpecs base (mmCandidate mutation),
                ckCode (kindOfChange change) == mmCode mutation
              ]
            actualSubjects = Set.fromList (map (ckSubject . kindOfChange) changes)
        changes `shouldSatisfy` any (not . isAdditiveChange)
        actualSubjects `shouldBe` mmExpectedSubjects mutation
        pure actualSubjects
      visited `shouldBe` Set.unions (map mmExpectedSubjects mutations)
    it "reports the exact ingredient code when every required mapped fact is deleted" $ do
      base <- specOf "test/fixtures/consumer-types.keiro"
      forM_ (mappedIngredientMutations base) $ \(candidate, expectedCode) ->
        errorCodes candidate `shouldContain` [expectedCode]
    it "classifies a field added without a version bump as BREAKING" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-fieldadd.keiro"
      any isBreaking cs `shouldBe` True
      [ckCode k | Breaking k <- cs] `shouldContain` [EvtFieldAddedWithoutBump]
    it "classifies the same field wrapped as v2 + upcaster as ADDITIVE" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-v2.keiro"
      any isBreaking cs `shouldBe` False
      [ck | Additive ck <- cs] `shouldSatisfy` any ((== "TransferReservationCreated") . ckSubject)
    it "reports no breaking change when the spec is unchanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation.keiro"
      any isBreaking cs `shouldBe` False
    it "classifies a direct event field type change as EvtFieldTypeChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-fieldtype.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [EvtFieldTypeChanged]
    it "resolves fields(Command) before comparing event field types" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-cmdfieldtype.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [EvtFieldTypeChanged]
    it "uses EvtFieldRemovedSameVersion for an unchanged-version removal" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-fieldremove.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [EvtFieldRemovedSameVersion]
    it "uses EvtVersionDecreased for a version decrease" $ do
      cs <- diffFixtures "test/fixtures/reservation-v2.keiro" "test/fixtures/reservation.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [EvtVersionDecreased]
    it "rejects a v1 to v3 jump whose only upcaster starts at v2" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-v3-dangling.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [EvtVersionMissingUpcaster]
    it "classifies a vanished historical upcaster rung as UpcasterChainGap" $ do
      cs <- diffFixtures "test/fixtures/reservation-v2.keiro" "test/fixtures/reservation-chain-gap.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [UpcasterChainGap]
    it "classifies an enum constructor removal as EnumCtorRemoved" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-enumdrop.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [EnumCtorRemoved]
    it "classifies an enum wire-spelling change as EnumWireSpellingChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-enumwire.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [EnumWireSpellingChanged]
    it "classifies an enum constructor addition per use site as advisory" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-enumadd.keiro"
      any isBreaking cs `shouldBe` False
      let enumFindings = [k | Advisory k <- cs, ckCode k == EnumCtorAdded]
      [ckSubject k | k <- enumFindings] `shouldContain` ["BlackTag"]
      [verdictFor SnapshotHydration (ckVector k) | k <- enumFindings]
        `shouldContain` [VAdvisory]
    it "classifies an effective wire convention change as WireSpecChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-wire.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [WireSpecChanged]
    it "advises when the aggregate fold surface changes" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-foldchange.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldContain` [AggFoldSurfaceChanged]
    it "advises on hazardous deprecation and reports un-deprecation" $ do
      deprecated <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-deprecated.keiro"
      any isBreaking deprecated `shouldBe` False
      [ckCode k | Advisory k <- deprecated] `shouldContain` [DeprecatedEventReplayHazard]
      restored <- diffFixtures "test/fixtures/reservation-deprecated.keiro" "test/fixtures/reservation.keiro"
      any isAdvisory restored `shouldBe` True
      [ckCode k | Advisory k <- restored] `shouldContain` [EventUndeprecated]
    it "recognises replay-only deprecation as a replay-safe retirement cutover" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-deprecated-replay-only.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldContain` [EventRetirementInProgress]
      [ckCode k | Advisory k <- cs] `shouldNotContain` [DeprecatedEventReplayHazard]
    it "advises when event retirement starts" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-retiring.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldContain` [EventRetirementInProgress]
    it "does not recommend decode-only deprecation for an event removal" $ do
      old <- specOf "test/fixtures/reservation.keiro"
      let new =
            old
              { specNodes =
                  [ case node of
                      NAggregate aggregate ->
                        NAggregate
                          aggregate
                            { aggEvents =
                                [ event
                                | event <- aggEvents aggregate,
                                  evName event /= "TransferReservationConfirmed"
                                ],
                              aggTransitions =
                                [ transition {tEmits = filter (/= "TransferReservationConfirmed") (tEmits transition)}
                                | transition <- aggTransitions aggregate
                                ]
                            }
                      _ -> node
                  | node <- specNodes old
                  ]
              }
          removals = [change | change@(Breaking kind) <- diffSpecs old new, ckCode kind == EvtRemovedNotDeprecated]
      removals `shouldSatisfy` (not . null)
      [ckDetail kind | Breaking kind <- removals]
        `shouldSatisfy` all (not . T.isInfixOf "so old payloads still decode")
    it "prints a paste-ready replay-only twin when a guard tightens (plan 143)" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-guard-tightened.keiro"
      any isBreaking cs `shouldBe` False
      let advisories = [k | Advisory k <- cs, ckCode k == AggGuardTightened]
      map ckSubject advisories `shouldBe` ["Unrequested -- RequestTransferReservation"]
      detail <- case advisories of
        [k] -> pure (ckDetail k)
        other -> expectationFailure ("expected one advisory, got " <> show other) >> pure ""
      detail `shouldSatisfy` T.isInfixOf "replay-only Unrequested -- RequestTransferReservation"
      -- The printed twin is paste-ready: appended to the new spec it
      -- parses, validates without errors, and silences the advisory.
      tightened <- readTestText "test/fixtures/reservation-guard-tightened.keiro"
      let twinText = snd (T.breakOnEnd "\n\n" detail)
          pasted = tightened <> "\n" <> twinText <> "\n"
      case parseSpec "<pasted-twin>" pasted of
        Left err -> expectationFailure (T.unpack err)
        Right pastedSpec -> do
          [code d | d <- validateSpec pastedSpec, severity d == Error] `shouldBe` []
          base <- specOf "test/fixtures/reservation.keiro"
          [k | Advisory k <- diffSpecs base pastedSpec, ckCode k == AggGuardTightened]
            `shouldBe` []
    it "omits the twin advisory when the twin is already present (plan 143)" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-guard-tightened-twin.keiro"
      [k | Advisory k <- cs, ckCode k == AggGuardTightened] `shouldBe` []
    it "classifies a removed contract event as ContractEventRemoved" $ do
      cs <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-eventdrop.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [ContractEventRemoved]
    it "classifies contract field type changes and unversioned additions as ContractFieldChanged" $ do
      changed <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-fieldtype.keiro"
      [ckCode k | Breaking k <- changed] `shouldContain` [ContractFieldChanged]
      added <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-fieldadd.keiro"
      [ckCode k | Breaking k <- added] `shouldContain` [ContractFieldChanged]
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
          findings = [kind | Breaking kind <- changes, ckCode kind == ContractTypeIdDomainChanged]
      expectedText <- readTestText "test/fixtures/contract-typeid-domain.diff.golden"
      expectedJson <- readTestText "test/fixtures/contract-typeid-domain.diff.json.golden"
      T.stripEnd textGolden `shouldBe` T.stripEnd expectedText
      T.stripEnd jsonGolden `shouldBe` T.stripEnd expectedJson
      case findings of
        [finding] -> do
          verdictFor PublicConsumer (ckVector finding) `shouldBe` VBreaking
          verdictFor ConsumerBuild (ckVector finding) `shouldBe` VBreaking
          [verdictFor surface (ckVector finding) | surface <- [PrivateHistoryRead, OldBinaryReadNewEvents, SnapshotHydration, PersistedIdentity]]
            `shouldBe` replicate 4 VNotApplicable
          cvRollout (ckVector finding) `shouldBe` Set.fromList [RolloutDrainRequired, RolloutProducerFirst]
          deriveLabel (Set.singleton PublicConsumer) (ckVector finding) `shouldBe` LabelBreaking
          deriveLabel (Set.singleton ConsumerBuild) (ckVector finding) `shouldBe` LabelBreaking
          remediationFor (ckContext finding) (ckCode finding)
            `shouldBe` RemedyEmitContractTypeIdDomain :| [RemedyDrainLegacyInvalidContractMessages, RemedyRescaffoldContractConsumers, RemedyRunContractConformance]
        values -> expectationFailure ("expected one contract TypeID-domain finding, got " <> show (length values))
      [kind | change <- diffServices v1 v3, let { kind = kindOfChange change }, ckCode kind == ContractTypeIdDomainChanged] `shouldBe` []
      [kind | change <- diffServices v4 v4, let { kind = kindOfChange change }, ckCode kind == ContractTypeIdDomainChanged] `shouldBe` []
      let edited = diffServices v3 v4Edited
      map (ckCode . kindOfChange) edited `shouldContain` [ContractFieldChanged]
      [kind | change <- edited, let { kind = kindOfChange change }, ckCode kind == ContractTypeIdDomainChanged] `shouldBe` []
    it "reports a field addition with a contract version bump as an advisory" $ do
      cs <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-bump-fieldadd.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldContain` [ContractSchemaVersionBumped]
    it "classifies a contract schema version decrease separately" $ do
      cs <- diffFixtures "test/fixtures/contract-bump-fieldadd.keiro" "test/fixtures/contract.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [ContractSchemaVersionDecreased]
    it "classifies contract topic and discriminator changes separately" $ do
      topic <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-topic.keiro"
      [ckCode k | Breaking k <- topic] `shouldContain` [ContractTopicChanged]
      discriminator <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-discriminator.keiro"
      [ckCode k | Breaking k <- discriminator] `shouldContain` [ContractDiscriminatorChanged]
    it "classifies a new contract event as additive" $ do
      cs <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-eventadd.keiro"
      any isBreaking cs `shouldBe` False
      [ckSubject k | Additive k <- cs] `shouldContain` ["IncidentTransferNeedCancelled"]
    it "classifies workqueue wire names, types, and required additions as WqPayloadFieldChanged" $ do
      wire <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-wirename.keiro"
      [ckCode k | Breaking k <- wire] `shouldContain` [WqPayloadFieldChanged]
      fieldTypeChange <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-fieldtype.keiro"
      [ckCode k | Breaking k <- fieldTypeChange] `shouldContain` [WqPayloadFieldChanged]
      required <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-reqfield.keiro"
      [ckCode k | Breaking k <- required] `shouldContain` [WqPayloadFieldChanged]
    it "classifies a new optional workqueue payload field as additive" $ do
      cs <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-optfield.keiro"
      any isBreaking cs `shouldBe` False
      [ckSubject k | Additive k <- cs] `shouldContain` ["note"]
    it "classifies workqueue ordering changes as breaking delivery-contract changes" $ do
      cs <- diffFixtures "test/fixtures/workqueue-policy-base.keiro" "test/fixtures/workqueue-ordering-change.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [WqOrderingChanged]
      [ckDetail k | Breaking k <- cs, ckCode k == WqOrderingChanged]
        `shouldSatisfy` any (T.isInfixOf "delivery-order contract")
    it "classifies workqueue provision changes as operational migrations" $ do
      cs <- diffFixtures "test/fixtures/workqueue-policy-base.keiro" "test/fixtures/workqueue-provision-change.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [WqProvisionChanged]
      [ckDetail k | Breaking k <- cs, ckCode k == WqProvisionChanged]
        `shouldSatisfy` any (T.isInfixOf "migrate the existing queue operationally")
    it "classifies workqueue group-key changes as breaking repartitioning" $ do
      cs <- diffFixtures "test/fixtures/workqueue-policy-base.keiro" "test/fixtures/workqueue-group-key-change.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [WqGroupKeyChanged]
      [ckDetail k | Breaking k <- cs, ckCode k == WqGroupKeyChanged]
        `shouldSatisfy` any (T.isInfixOf "re-partitioned")
    it "classifies a process input type change as ProcessInputChanged" $ do
      cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-inputtype.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [ProcessInputChanged]
    it "classifies workflow input and output changes as WorkflowShapeChanged" $ do
      input <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-inputfield.keiro"
      [ckCode k | Breaking k <- input] `shouldContain` [WorkflowShapeChanged]
      output <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-output.keiro"
      [ckCode k | Breaking k <- output] `shouldContain` [WorkflowShapeChanged]
    it "classifies workflow relabeling and appends as WorkflowBodyChanged" $ do
      relabeled <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-body.keiro"
      [ckCode k | Breaking k <- relabeled] `shouldContain` [WorkflowBodyChanged]
      appended <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-stepadd.keiro"
      [ckCode k | Breaking k <- appended] `shouldContain` [WorkflowBodyChanged]
      [ckDetail k | Breaking k <- appended, ckCode k == WorkflowBodyChanged]
        `shouldSatisfy` any (T.isInfixOf "new patch guard")
    it "classifies a body addition wholly guarded by a new patch as additive" $ do
      cs <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-evolution-diff.keiro"
      any isBreaking cs `shouldBe` False
      [ckSubject k | Additive k <- cs, ckFacet k == "workflow-patch"] `shouldContain` ["fraud-check-v2"]
      [ckSubject k | Additive k <- cs, ckFacet k == "workflow-continue-as-new"] `shouldContain` ["RolloverSeed"]
    it "classifies removing an existing patch as breaking" $ do
      cs <- diffFixtures "test/fixtures/workflow-evolution-diff.keiro" "test/fixtures/workflow-continue.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [WorkflowPatchRemoved]
      [ckDetail k | Breaking k <- cs, ckCode k == WorkflowPatchRemoved]
        `shouldSatisfy` any (T.isInfixOf "cannot prove")
    it "classifies terminal continueAsNew append as additive and seed drift as breaking" $ do
      appended <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-continue.keiro"
      any isBreaking appended `shouldBe` False
      [ckFacet k | Additive k <- appended] `shouldContain` ["workflow-continue-as-new"]
      changed <- diffFixtures "test/fixtures/workflow-continue.keiro" "test/fixtures/workflow-continue-seed-v2.keiro"
      [ckCode k | Breaking k <- changed] `shouldContain` [WorkflowContinueSeedChanged]
      [ckDetail k | Breaking k <- changed, ckCode k == WorkflowContinueSeedChanged]
        `shouldSatisfy` any (T.isInfixOf "restoreSeed")
    it "classifies a workflow stable-name change as WorkflowStableNameChanged" $ do
      cs <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-rename.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [WorkflowStableNameChanged]
    it "classifies workflow id-derivation changes as DerivedIdentityChanged" $ do
      cs <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-idfield.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [DerivedIdentityChanged]
    it "classifies an id prefix change as IdPrefixChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-idprefix.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [IdPrefixChanged]
    it "classifies intake dedupe key and policy changes as DedupeIdentityChanged" $ do
      policy <- diffFixtures "test/fixtures/intake.keiro" "test/fixtures/intake-dedupepolicy.keiro"
      [ckCode k | Breaking k <- policy] `shouldContain` [DedupeIdentityChanged]
      key <- diffFixtures "test/fixtures/intake.keiro" "test/fixtures/intake-dedupekey.keiro"
      [ckCode k | Breaking k <- key] `shouldContain` [DedupeIdentityChanged]
    it "reports intake decode-posture changes as warnings" $ do
      cs <- diffFixtures "test/fixtures/intake.keiro" "test/fixtures/intake-decode.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldContain` [DecodePostureChanged]
      [ckCode k | Advisory k <- cs] `shouldContain` [IntakePersistenceChanged]
    it "classifies process and timer derivation changes as DerivedIdentityChanged" $ do
      processName <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-procname.keiro"
      [ckCode k | Breaking k <- processName] `shouldContain` [DerivedIdentityChanged]
      timerId <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-timerid.keiro"
      [ckCode k | Breaking k <- timerId] `shouldContain` [DerivedIdentityChanged]
      base <- specOf "test/fixtures/hospital-surge.keiro"
      let categoryChange = diffSpecs base (modifyProcess "HospitalSurge" (\process -> process {procSaga = (procSaga process) {sagaCategory = "hospitalSurgeV2"}}) base)
      [ckCode k | Breaking k <- categoryChange] `shouldContain` [DerivedIdentityChanged]
    it "classifies router stable names, keys, and targets as identity-bearing" $ do
      base <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
      let stableName = diffSpecs base (modifyRouter "PagingRouter" (\router -> router {rtName = "paging-v2"}) base)
          keyDerivation = diffSpecs base (modifyRouter "PagingRouter" (\router -> router {rtKey = (rtKey router) {corrVia = "otherIdText"}}) base)
          target = diffSpecs base (modifyRouter "PagingRouter" (\router -> router {rtTarget = "OtherPage"}) base)
      [ckCode k | Breaking k <- stableName] `shouldContain` [RouterStableNameChanged]
      [ckCode k | Breaking k <- keyDerivation] `shouldContain` [DerivedIdentityChanged]
      [ckCode k | Breaking k <- target] `shouldContain` [DerivedIdentityChanged]
    it "advises on router dispatch-surface changes without making them breaking" $ do
      cs <- diffFixtures "test/fixtures/incident-paging/incident-paging.keiro" "test/fixtures/incident-paging/incident-paging-dispatch.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldBe` [RouterDecideSurfaceChanged]
    it "advises on process dispatch-surface changes without making them breaking" $ do
      cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-handle.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldBe` [ProcessDecideSurfaceChanged]
    it "advises on unversioned timer payload changes without making them breaking" $ do
      cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-payload.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldBe` [ProcessTimerPayloadChanged]
    it "ignores formatting-only process and timer surface rewrites" $ do
      original <- specOf "test/fixtures/hospital-surge.keiro"
      formatted <- shouldParseStableRenderedSpec "<formatted-process>" original
      diffSpecs original formatted `shouldBe` []
    it "reports a timer window change as a warning" $ do
      cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-window.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldContain` [TimerWindowChanged]
    it "reports emit-map changes as warnings and derive changes as breaking" $ do
      mapping <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-mapchange.keiro"
      any isBreaking mapping `shouldBe` False
      [ckCode k | Advisory k <- mapping] `shouldContain` [EmitMappingChanged]
      derive <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-derive.keiro"
      [ckCode k | Breaking k <- derive] `shouldContain` [DerivedIdentityChanged]
    it "classifies publisher outbox identity and ordering independently" $ do
      outbox <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-outboxfield.keiro"
      [ckCode k | Breaking k <- outbox] `shouldContain` [DerivedIdentityChanged]
      ordering <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-ordering.keiro"
      any isBreaking ordering `shouldBe` False
      [ckCode k | Advisory k <- ordering] `shouldContain` [PublisherPolicyChanged]
    it "classifies workqueue names as QueueIdentityChanged" $ do
      cs <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-rename.keiro"
      [ckCode k | Breaking k <- cs] `shouldContain` [QueueIdentityChanged]
    it "classifies pgmq dispatch dedupe and retargeting independently" $ do
      dedupe <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-dedupkey.keiro"
      [ckCode k | Breaking k <- dedupe] `shouldContain` [DedupeIdentityChanged]
      retarget <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-retarget.keiro"
      any isBreaking retarget `shouldBe` False
      [ckCode k | Advisory k <- retarget] `shouldContain` [DispatchRetargeted]
    it "reports aggregate projection changes as warnings" $ do
      cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-projection.keiro"
      any isBreaking cs `shouldBe` False
      [ckCode k | Advisory k <- cs] `shouldContain` [ProjectionChanged]
    it "classifies read-model version and unversioned shape changes" $ do
      base <- specOf "test/fixtures/readmodel-runtime.keiro"
      let versionTwo = modifyReadModel "transfer_decisions" (\readModel -> readModel {rmVersion = 2}) base
          changedShape = modifyReadModel "transfer_decisions" changeReadModelShape base
          bumpedShape = modifyReadModel "transfer_decisions" (\readModel -> (changeReadModelShape readModel) {rmVersion = 2}) base
          decreased = diffSpecs versionTwo base
          unversioned = diffSpecs base changedShape
          bumped = diffSpecs base bumpedShape
      [ckCode k | Breaking k <- decreased] `shouldContain` [ReadModelVersionDecreased]
      [ckCode k | Breaking k <- unversioned] `shouldContain` [ReadModelShapeChangedWithoutBump]
      any isBreaking bumped `shouldBe` False
      [ckFacet k | Additive k <- bumped] `shouldContain` ["read-model-version"]
    it "classifies read-model registry, table, subscription, and removal identities" $ do
      base <- specOf "test/fixtures/readmodel-runtime.keiro"
      let tableChanged = modifyReadModel "transfer_decisions" (\readModel -> readModel {rmTable = "transfer_decisions_v2"}) base
          subscriptionChanged = modifyReadModel "transfer_decisions" (\readModel -> readModel {rmSubscription = Just "transfer-decisions-v2"}) base
          renamed = modifyReadModel "transfer_decisions" (\readModel -> readModel {rmName = "reservation_decisions"}) base
          removed = removeReadModel "transfer_decisions" base
      mapM_
        (\changes -> [ckCode k | Breaking k <- changes] `shouldContain` [DerivedIdentityChanged])
        [diffSpecs base tableChanged, diffSpecs base subscriptionChanged, diffSpecs base renamed, diffSpecs base removed]
    it "classifies read-model feed flips and consistency/scope weakening as breaking" $ do
      base <- specOf "test/fixtures/readmodel-runtime.keiro"
      let feedChanged = modifyReadModel "transfer_decisions" (\readModel -> readModel {rmFeed = RmInline}) base
          consistencyWeakened = modifyReadModel "transfer_decisions" (\readModel -> readModel {rmConsistency = Eventual}) base
          entireLog = modifyReadModel "transfer_decisions" (\readModel -> readModel {rmScope = Just RmEntireLog}) base
      [ckCode k | Breaking k <- diffSpecs base feedChanged] `shouldContain` [ReadModelFeedChanged]
      [ckCode k | Breaking k <- diffSpecs base consistencyWeakened] `shouldContain` [ReadModelConsistencyWeakened]
      [ckCode k | Breaking k <- diffSpecs entireLog base] `shouldContain` [ReadModelConsistencyWeakened]
    it "classifies Eventual to Strong read-model consistency as additive" $ do
      strong <- specOf "test/fixtures/readmodel-runtime.keiro"
      let eventual = modifyReadModel "transfer_decisions" (\readModel -> readModel {rmConsistency = Eventual}) strong
          changes = diffSpecs eventual strong
      any isBreaking changes `shouldBe` False
      [ckFacet k | Additive k <- changes] `shouldContain` ["read-model-consistency"]

  describe "module placement (M1)" $ do
    it "GeneratedPrefix is today's namespace (Generated.<Ctx>.<Node>, holes at <Ctx>.<Node>)" $ do
      let ctx = defaultContext "hospital-capacity"
      genPrefixFor ctx "Reservation" `shouldBe` "Generated.HospitalCapacity.Reservation"
      holePrefixFor ctx "Reservation" `shouldBe` "HospitalCapacity.Reservation"
    it "module-root prefixes both layers" $ do
      let ctx = (defaultContext "hospital-capacity") {moduleRoot = "Acme"}
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
          specModuleRoot spec `shouldBe` Just "Acme.Services"
          specLayout spec `shouldBe` Just CollocatedLeaf
          parseSpec "<m1>" (renderSpec spec) `shouldBe` Right spec
    it "a spec without the clauses leaves placement at the default" $ do
      input <- readTestText "test/fixtures/reservation.keiro"
      case parseSpec "test/fixtures/reservation.keiro" input of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> do
          specModuleRoot spec `shouldBe` Nothing
          specLayout spec `shouldBe` Nothing

  describe "structural scaffold" $ do
    it "emits one private shape module per structural declaration and one context facade" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let modules = scaffoldModules (defaultContext (specContext spec)) spec
          paths = map modulePath modules
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
      let modules = scaffoldModules (defaultContext (specContext spec)) spec
          skeletons = [moduleValue | moduleValue <- modules, kind moduleValue == HoleStub, modulePath moduleValue == "Example/Artifact/KeiroBindings.hs"]
          shape = generatedTextEndingIn "Structural/Shape/ArtifactInfo.hs" modules
      case skeletons of
        [skeleton] -> do
          moduleText skeleton `shouldSatisfy` T.isInfixOf "artifactInfoBinding :: StructuralBinding"
          moduleText skeleton `shouldSatisfy` T.isInfixOf "artifactKindBinding :: StructuralBinding"
          moduleText skeleton `shouldSatisfy` T.isInfixOf "artifactLocationBinding :: StructuralBinding"
          moduleText skeleton `shouldSatisfy` T.isInfixOf "HOLE: fill ArtifactInfo bindingToShape.key"
        _ -> expectationFailure ("expected exactly one shared binding skeleton, got " <> show (map modulePath skeletons))
      shape `shouldSatisfy` T.isInfixOf "deriving stock (Eq, Generic, Show)"
      shape `shouldSatisfy` T.isInfixOf "import GHC.Generics (Generic)"
    it "never overwrites an existing binding skeleton" $
      withTempDirectory "keiro-dsl-binding-create-once" $ \out -> do
        spec <- specOf "test/fixtures/consumer-types.keiro"
        let ctx = defaultContext (specContext spec)
            bindingPath = out </> "Example/Artifact/KeiroBindings.hs"
        _ <- executePlannedScaffold out "consumer-types.keiro" ctx spec
        TIO.writeFile bindingPath "hand-owned binding\n"
        second <- executePlannedScaffold out "consumer-types.keiro" ctx spec
        TIO.readFile bindingPath `shouldReturn` "hand-owned binding\n"
        reportDispositions second
          `shouldSatisfy` any (\(moduleValue, disposition) -> modulePath moduleValue == "Example/Artifact/KeiroBindings.hs" && disposition == Skipped)
    it "fresh binding skeletons compile at the application boundary" $
      withTempDirectory "keiro-dsl-binding-compiles" $ \out -> do
        spec <- specOf "test/fixtures/structural-conformance.keiro"
        let ctx = defaultContext (specContext spec)
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
      let modules = scaffoldModules (defaultContext (specContext spec)) spec
          domain = generatedTextEndingIn "Catalog/Domain.hs" modules
          codec = generatedTextEndingIn "Catalog/Codec.hs" modules
      domain `shouldSatisfy` T.isInfixOf "import Example.Artifact.Domain (ArtifactInfo)"
      domain `shouldSatisfy` T.isInfixOf "import Vendor.Geometry (Geometry)"
      domain `shouldSatisfy` T.isInfixOf "artifact :: !ArtifactInfo"
      domain `shouldSatisfy` T.isInfixOf "RCons (Proxy @\"currentArtifact\") ArtifactKeiroBindings.emptyArtifactInfo"
      domain `shouldSatisfy` (not . T.isInfixOf "Example.Artifact.Domain.ArtifactInfo")
      codec `shouldSatisfy` T.isInfixOf "\"location\" .= encodeArtifactLocationShape"
      codec `shouldSatisfy` T.isInfixOf "\"local_file\""
      codec `shouldSatisfy` T.isInfixOf "Nothing -> pure ShapeArtifactKind.Guide"
      codec `shouldSatisfy` T.isInfixOf "rejectUnknownFields \"ArtifactInfo\""
      codec `shouldSatisfy` T.isInfixOf "toJSON payload.geometry"
      codec `shouldSatisfy` (not . T.isInfixOf "vendor.geometry.json")
    it "generates shape-only nested types and schema-derived Keiki witnesses" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let modules = scaffoldModules (defaultContext (specContext spec)) spec
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
          keyWitnesses = [spWitness spec | spec <- specs, spPointer spec == "/key"]
          collidedWitnesses = [spWitness spec | spec <- specs, spPointer spec `elem` ["/foo-bar", "/foo_bar"]]
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
          shape = generatedTextEndingIn "Structural/Shape/Nested.hs" (scaffoldStructural (defaultContext (specContext spec)) spec)
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
          shape = generatedTextEndingIn "Structural/Shape/Payload.hs" (scaffoldStructural (defaultContext (specContext spec)) spec)
      mapM_
        (shape `shouldSatisfy`)
        [ T.isInfixOf "OptionalPayload !(Maybe Text)",
          T.isInfixOf "ListPayload ![Maybe Text]",
          T.isInfixOf "MapPayload !(Map Text (Maybe Text))"
        ]

  describe "structural manifest" $ do
    it "lists consumer packages and every domain, binding, fixture, and initial module" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let modules = scaffoldModules (defaultContext (specContext spec)) spec
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
        let ctx = defaultContext (specContext spec)
        first <- executePlannedScaffold out "consumer-types.keiro" ctx spec
        length (consumerMappings (reportConsumerPlan first)) `shouldBe` 4
        recordText <- TIO.readFile (out </> recordFileName (specContext spec))
        let mappingRows = filter (T.isPrefixOf "mapping ") (T.lines recordText)
            bindingRows = filter (T.isPrefixOf "binding ") (T.lines recordText)
        length mappingRows `shouldBe` 4
        bindingRows `shouldSatisfy` (not . null)
        fmap recMappings (parseRecord recordText) `shouldSatisfy` maybe False ((== 4) . length)
        fmap recBindingObligations (parseRecord recordText) `shouldSatisfy` maybe False ((== length bindingRows) . length)
        let bumped = spec {specMapped = map bumpArtifactBindingVersion (specMapped spec)}
        second <- executePlannedScaffold out "consumer-types.keiro" ctx bumped
        reportMappingDrift second
          `shouldSatisfy` any (\drift -> driftSpecName drift == "ArtifactInfo" && driftPrevious drift /= driftCurrent drift)
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
        let ctx = defaultContext (specContext spec)
        _ <- executePlannedScaffold out "consumer-types.keiro" ctx spec
        let extended = spec {specMapped = map addArtifactSummaryField (specMapped spec)}
        second <- executePlannedScaffold out "consumer-types.keiro" ctx extended
        reportNewHoles second
          `shouldBe` [ BindingHole
                         { holeMappedName = "ArtifactInfo",
                           holeModule = "Example.Artifact.KeiroBindings",
                           holeSymbol = "artifactInfoBinding",
                           holeKind = BindingValue,
                           holePath = Just "summary",
                           holeSignature = "artifactInfoBinding.summary :: Text"
                         }
                     ]
        renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "artifactInfoBinding.summary :: Text")
    it "rejects malformed known mapping JSON while ignoring unrelated future rows" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      withTempDirectory "keiro-dsl-mapping-malformed" $ \out -> do
        report <- executePlannedScaffold out "consumer-types.keiro" (defaultContext (specContext spec)) spec
        recordText <- TIO.readFile (reportRecordPath report)
        parseRecord (recordText <> "mapping {not-json}\n") `shouldBe` Nothing
        parseRecord (recordText <> "future-row retained\n") `shouldBe` parseRecord recordText

  describe "structural import plan" $ do
    it "reports the successful dependency plan in the scaffold report" $
      withTempDirectory "keiro-dsl-dependency-plan" $ \out -> do
        spec <- specOf "test/fixtures/consumer-types.keiro"
        report <- executePlannedScaffold out "consumer-types.keiro" (defaultContext (specContext spec)) spec
        renderScaffoldReport report
          `shouldSatisfy` any (T.isInfixOf "dependency plan: consumer packages [artifact-domain, vendor-geometry]")
    it "refuses a binding module inside the generated namespace with the exact cycle" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let cyclic = spec {specMapped = map moveArtifactBindingIntoGenerated (specMapped spec)}
      case planScaffold (defaultContext (specContext cyclic)) cyclic of
        Left refusals -> do
          refusals `shouldSatisfy` any isImportCycle
          renderRefusals refusals `shouldSatisfy` any (T.isInfixOf "Generated.ConsumerDemo.Bindings")
        Right _ -> expectationFailure "expected an import-cycle refusal"
    it "refuses missing mapped register initials but permits command/event-only use" $ do
      missing <- specOf "test/fixtures/mapped-missing-initial.keiro"
      planScaffold (defaultContext (specContext missing)) missing `shouldSatisfy` isFoldSurfaceRefusal
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let commandOnly = removeMappedRegisterRequirements spec
      planScaffold (defaultContext (specContext commandOnly)) commandOnly `shouldSatisfy` isRight

  describe "binding explanations" $ do
    it "lists binding, fixture, and use-site-scoped initial obligations deterministically" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      obligations <- either (\errors -> expectationFailure (show errors) >> pure []) pure (bindingObligations spec)
      length obligations `shouldBe` 7
      obligations
        `shouldSatisfy` any
          ( \obligation ->
              obligationKind obligation == BindingValue
                && obligationSymbol obligation == "artifactInfoBinding"
                && obligationBindingVersion obligation == Just "1"
          )
      obligations
        `shouldSatisfy` any
          ( \obligation ->
              obligationKind obligation == InitialValue
                && obligationSymbol obligation == "emptyArtifactInfo"
                && any (T.isInfixOf "Catalog register currentArtifact") (obligationUseSites obligation)
          )
      let rendered = renderBindingObligations (specContext spec) obligations
      rendered `shouldSatisfy` T.isInfixOf "binding obligations for context consumer-demo"
      rendered `shouldSatisfy` T.isInfixOf "artifactInfoBinding :: StructuralBinding Example.Artifact.Domain.ArtifactInfo ArtifactInfoShape"
      rendered `shouldSatisfy` T.isInfixOf "provenance: binding-version \"1\""
    it "states explicitly when a spec has no structural obligations" $ do
      spec <- specOf "test/fixtures/reservation.keiro"
      obligations <- either (\errors -> expectationFailure (show errors) >> pure []) pure (bindingObligations spec)
      renderBindingObligations (specContext spec) obligations
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

  describe "structural harness" $ do
    it "emits every structural, wire-policy, projection, and replay assertion family" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let aggregate = onlyAggregate spec
          ctx = defaultContext (specContext spec)
          harness = generatedTextEndingIn "Harness.hs" (harnessFor ctx spec aggregate)
      mapM_
        (\needle -> harness `shouldSatisfy` T.isInfixOf needle)
        [ "binding domain round-trip: example.artifact.ArtifactInfo.v1/",
          "binding shape round-trip: example.artifact.ArtifactInfo.v1/",
          "mapped codec round-trip: ArtifactObserved/artifact/",
          "fixture coverage: example.artifact.ArtifactLocation.v1",
          "wire policy missing default: example.artifact.ArtifactInfo.v1/description",
          "wire policy explicit null: example.artifact.ArtifactInfo.v1/description",
          "wire policy unknown fields: example.artifact.ArtifactInfo.v1",
          "wire union arm: example.artifact.ArtifactLocation.v1/local_file",
          "canonical identity: example.artifact.ArtifactInfo.v1",
          "projection witness agreement: example.artifact.ArtifactInfo.v1/key",
          "forward/replay equality: ObserveArtifact from CatalogEmpty -- ",
          "register currentArtifact"
        ]
    it "keeps opaque assertions at the declared codec boundary" $ do
      spec <- specOf "test/fixtures/consumer-types.keiro"
      let aggregate = onlyAggregate spec
          ctx = defaultContext (specContext spec)
          modules = scaffoldAggregate ctx spec aggregate <> harnessFor ctx spec aggregate
          harness = generatedTextEndingIn "Harness.hs" modules
          codec = generatedTextEndingIn "Codec.hs" modules
      harness `shouldSatisfy` T.isInfixOf "opaque codec round-trip: vendor.geometry.json@3/"
      harness `shouldNotSatisfy` T.isInfixOf "wire policy unknown fields: vendor.geometry.json"
      harness `shouldNotSatisfy` T.isInfixOf "fixture coverage: vendor.geometry"
      codec `shouldNotSatisfy` T.isInfixOf "encodeVendorGeometryShape"

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
        forM_ [generatedModule | generatedModule <- modules, kind generatedModule == Generated] $ \generatedModule -> do
          let actual = Set.fromList (generatedLocalExtensions generatedModule)
          unless (actual `Set.isSubsetOf` allowed) $
            expectationFailure (fixture <> ":" <> modulePath generatedModule <> ": disallowed local extensions " <> show (Set.toList (actual `Set.difference` allowed)))

    it "retains specialized syntax extensions and removes GHC2024-covered pragmas" $ do
      scalar <- scaffoldFixture "test/fixtures/aggregate-scalar-expressions-v2.keiro"
      structural <- scaffoldFixture "test/fixtures/structural-conformance.keiro"
      reservation <- scaffoldFixture "test/fixtures/reservation.keiro"
      contract <- scaffoldFixture "test/fixtures/contract-v4.keiro"
      intake <- scaffoldFixture "test/fixtures/intake.keiro"
      queue <- scaffoldFixture "test/fixtures/reservation-work.keiro"
      readModel <- scaffoldFixture "test/fixtures/readmodel-runtime.keiro"
      generatedExtensionsEndingIn "ScalarAccount/Domain.hs" scalar
        `shouldBe` ["DeriveAnyClass", "DuplicateRecordFields", "TemplateHaskell"]
      generatedExtensionsEndingIn "ScalarAccount/Transducer.hs" scalar
        `shouldBe` ["BlockArguments", "OverloadedLabels", "OverloadedRecordDot", "QualifiedDo"]
      generatedExtensionsEndingIn "Nominals.hs" scalar `shouldContain` ["DeriveAnyClass", "TypeFamilies"]
      generatedExtensionsEndingIn "Nominals/Internal.hs" scalar `shouldBe` []
      generatedExtensionsEndingIn "StructuralProjections.hs" structural `shouldBe` ["TypeFamilies"]
      let structuralShapeExtensions =
            [ generatedLocalExtensions generatedModule
            | generatedModule <- structural,
              "/Structural/Shape/" `T.isInfixOf` T.pack (modulePath generatedModule)
            ]
      structuralShapeExtensions `shouldSatisfy` all null
      generatedExtensionsEndingIn "Projection.hs" reservation `shouldBe` []
      generatedExtensionsEndingIn "ReplayAudit.hs" reservation `shouldBe` []
      generatedExtensionsEndingIn "Contract.hs" contract `shouldBe` ["DuplicateRecordFields", "OverloadedRecordDot"]
      generatedExtensionsEndingIn "Inbox.hs" intake `shouldBe` []
      generatedExtensionsEndingIn "Queue.hs" queue `shouldBe` ["OverloadedRecordDot"]
      generatedExtensionsEndingIn "ReadModel.hs" readModel `shouldBe` ["OverloadedRecordDot"]

    it "conditions record, label, derivation, and duplicate-selector extensions on emitted syntax" $ do
      mappedGuardSource <- readTestText "test/fixtures/mapped-guard.keiro"
      mappedGuardParsed <- case parseSource "mapped-guard-no-expression.keiro" (T.replace "guard current == current ; " "" mappedGuardSource) of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right parsed -> pure parsed
      let mappedGuardService = checkedSource mappedGuardParsed
          mappedGuard = scaffoldServiceModules (defaultContext (specContext (checkedSpec mappedGuardService))) mappedGuardService
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
      generatedExtensionsEndingIn "Transfer_decisions/ReadModel.hs" readModels `shouldBe` ["OverloadedRecordDot"]
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
              | contractNode <- [contractNode | NContract contractNode <- specNodes spec],
                generatedModule <- scaffoldContract (defaultContext (specContext spec)) contractNode
              ]
      contractExtensions disjoint `shouldBe` ["OverloadedRecordDot"]
      contractExtensions emptyPayload `shouldBe` []

  describe "manifest (M2)" $ do
    it "lists exactly the modules the scaffolder produced" $ do
      mods <- scaffoldFixture "test/fixtures/reservation.keiro"
      service <- checkedServiceOf "test/fixtures/reservation.keiro"
      let manifest = renderManifestForService "reservation.keiro" mods service
          expectedNames = sort (map (moduleNameOf . modulePath) mods)
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

  describe "new <kind> skeletons (M5)" $ do
    forM_ skeletonKinds $ \skeletonKind ->
      it ("the " <> T.unpack skeletonKind <> " skeleton selects and preserves the registered stable language") $
        assertSkeletonUsesStableLanguage skeletonKind
    it "every skeleton parses and validates with zero error diagnostics" $
      mapM_ assertSkeletonValid skeletonKinds
    it "every skeleton passes the scaffold refusal gates" $
      mapM_ assertSkeletonScaffoldable skeletonKinds
    it "stable skeleton scaffolds match the committed compiling modules" $
      mapM_ (uncurry assertStableSkeletonMatchesCommitted) skeletonModuleRoots
    it "rejects an unknown kind with a helpful message" $
      case skeletonFor "bogus" of
        Left msg -> ("Valid kinds:" `T.isInfixOf` msg) `shouldBe` True
        Right _ -> expectationFailure "expected an error for an unknown kind"

  describe "firewall self-check (M3)" $ do
    it "flags a forbidden operator in a Generated module" $ do
      let m = ScaffoldModule {modulePath = "Gen/Foo.hs", moduleText = "x = a ./= b", kind = Generated, origin = "test"}
      firewallBreaches [m] `shouldBe` [("Gen/Foo.hs", "./=", 1)]
    it "ignores forbidden operators in a HoleStub module (holes own them)" $ do
      let m = ScaffoldModule {modulePath = "Foo/Holes.hs", moduleText = "x = lit 1 .== y", kind = HoleStub, origin = "test"}
      firewallBreaches [m] `shouldBe` []
    it "matches `lit` as a word, not a substring of quality/split" $ do
      let clean = ScaffoldModule {modulePath = "Gen/Q.hs", moduleText = "quality = split facility", kind = Generated, origin = "test"}
          dirty = ScaffoldModule {modulePath = "Gen/L.hs", moduleText = "v = lit foo", kind = Generated, origin = "test"}
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
      let ctx = defaultContext (specContext (checkedSpec service))
      case planServiceScaffold ctx service of
        Left refusals -> expectationFailure (show refusals)
        Right modules -> do
          let generated = [moduleValue | moduleValue <- modules, kind moduleValue == Generated]
          generated `shouldSatisfy` (not . null)
          forM_ generated $ \moduleValue -> do
            let recognized = filter isGeneratedBannerLine (T.lines (moduleText moduleValue))
                expected = generatedBannerFor (checkedLanguageContract service) (origin moduleValue)
            recognized `shouldBe` [expected]
            expected
              `shouldSatisfy` T.isInfixOf
                ( "keiro-dsl "
                    <> T.pack (showVersion Package.version)
                    <> " (language keiro-dsl 4) from contract emergency"
                )
      workspace <- shouldComposeWorkspace canonicalWorkspacePath
      workspacePlan <- shouldPlanWorkspaceSpec workspace
      forM_ [moduleValue | (moduleValue, _) <- wpModules workspacePlan, kind moduleValue == Generated] $ \moduleValue ->
        filter isGeneratedBannerLine (T.lines (moduleText moduleValue))
          `shouldBe` [generatedBannerFor (checkedLanguageContract (checkedWorkspace workspace)) (origin moduleValue)]
    it "recognizes only the historical banner and the stamped format" $ do
      let contract = effectiveLanguageContract LegacyUnversioned
      isGeneratedBannerLine generatedBanner `shouldBe` True
      isGeneratedBannerLine (generatedBannerFor contract "aggregate Counter (line 2)") `shouldBe` True
      isGeneratedBannerLine "-- @generated by another tool" `shouldBe` False
      isGeneratedBannerLine codecComparisonBanner `shouldBe` False
    it "migrates a legacy-banner file and keeps repeated scaffold bytes stable" $
      withTempDirectory "keiro-dsl-stamped-banner" $ \out -> do
        spec <- parseInlineSpec "<stamped-banner>" loweringAggregateSpec
        let ctx = defaultContext (specContext spec)
        modules <- case planScaffold ctx spec of
          Left refusals -> expectationFailure (show refusals) >> pure []
          Right planned -> pure planned
        case [moduleValue | moduleValue <- modules, kind moduleValue == Generated] of
          target : _ -> do
            let path = out </> modulePath target
                stamped = generatedBannerFor (effectiveLanguageContract LegacyUnversioned) (origin target)
                legacyText = T.replace stamped generatedBanner (moduleText target)
            createDirectoryIfMissing True (takeDirectory path)
            TIO.writeFile path legacyText
            first <- executeScaffold out False "counter.keiro" ctx spec modules
            first `shouldSatisfy` isSuccessfulScaffold
            firstTree <- treeSnapshot out
            second <- executeScaffold out False "counter.keiro" ctx spec modules
            second `shouldSatisfy` isSuccessfulScaffold
            treeSnapshot out `shouldReturn` firstTree
            TIO.readFile path `shouldReturn` moduleText target
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
    it "refuses duplicate and case-folded module paths with both origins" $ do
      spec <- specOf "test/fixtures/reservation.keiro"
      case [aggregate | NAggregate aggregate <- specNodes spec] of
        aggregate : _ -> do
          let duplicate = spec {specNodes = [NAggregate aggregate, NAggregate aggregate]}
              caseVariant = spec {specNodes = [NAggregate aggregate, NAggregate aggregate {aggName = T.toUpper (aggName aggregate)}]}
          planScaffold (defaultContext (specContext spec)) duplicate `shouldSatisfy` hasPathCollisionWithTwoOrigins
          planScaffold (defaultContext (specContext spec)) caseVariant `shouldSatisfy` hasPathCollisionWithTwoOrigins
        [] -> expectationFailure "reservation fixture has no aggregate"
    it "refuses a bannerless Generated target without changing its bytes" $
      withTempDirectory "keiro-dsl-banner" $ \out -> do
        spec <- specOf "test/fixtures/reservation.keiro"
        let ctx = defaultContext (specContext spec)
        case planScaffold ctx spec of
          Left refusals -> expectationFailure ("unexpected planning refusal: " <> show refusals)
          Right modules -> case [m | m <- modules, kind m == Generated] of
            generated : _ -> do
              let target = out </> modulePath generated
              createDirectoryIfMissing True (takeDirectory target)
              TIO.writeFile target "hand owned\n"
              result <- executeScaffold out False "test/fixtures/reservation.keiro" ctx spec modules
              result `shouldSatisfy` isMissingBannerRefusal
              TIO.readFile target `shouldReturn` "hand owned\n"
              forced <- executeScaffold out True "test/fixtures/reservation.keiro" ctx spec modules
              forced `shouldSatisfy` isSuccessfulScaffold
              TIO.readFile target `shouldReturn` moduleText generated
            [] -> expectationFailure "reservation scaffold has no Generated module"
    it "reports renamed-node modules as stale without deleting them" $
      withTempDirectory "keiro-dsl-stale-rename" $ \out -> do
        spec <- parseInlineSpec "<stale-rename>" loweringAggregateSpec
        first <- executePlannedScaffold out "counter.keiro" (defaultContext (specContext spec)) spec
        let renamed = spec {specNodes = map renameCounter (specNodes spec)}
        second <- executePlannedScaffold out "counter.keiro" (defaultContext (specContext renamed)) renamed
        let oldDomain = onlyPathEndingIn "Counter/Domain.hs" (map fst (reportDispositions first))
            oldHoles = onlyPathEndingIn "Counter/Holes.hs" (map fst (reportDispositions first))
        reportStale second `shouldSatisfy` \stale ->
          StaleModule Generated oldDomain (Just ExactGeneratedBannerPresent) `elem` stale
            && StaleModule HoleStub oldHoles Nothing `elem` stale
        doesFileExist (out </> oldDomain) `shouldReturn` True
        doesFileExist (out </> oldHoles) `shouldReturn` True
        renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "exact generated banner present; verify unchanged bytes before deleting")
        renderScaffoldReport second `shouldSatisfy` all (not . T.isInfixOf "safe to delete")
    it "preserves a stale generated path whose exact banner is missing" $
      withTempDirectory "keiro-dsl-stale-banner" $ \out -> do
        spec <- parseInlineSpec "<stale-banner>" loweringAggregateSpec
        first <- executePlannedScaffold out "counter.keiro" (defaultContext (specContext spec)) spec
        let oldDomain = onlyPathEndingIn "Counter/Domain.hs" (map fst (reportDispositions first))
            renamed = spec {specNodes = map renameCounter (specNodes spec)}
        TIO.writeFile (out </> oldDomain) "-- generated by something else\n"
        second <- executePlannedScaffold out "counter.keiro" (defaultContext (specContext renamed)) renamed
        reportStale second `shouldSatisfy` elem (StaleModule Generated oldDomain (Just ExactGeneratedBannerMissing))
        renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "exact generated banner missing; preserve and review")
        TIO.readFile (out </> oldDomain) `shouldReturn` "-- generated by something else\n"
    it "reports the entire old tree across a module-root flip" $
      withTempDirectory "keiro-dsl-stale-root" $ \out -> do
        spec <- parseInlineSpec "<stale-root>" loweringAggregateSpec
        let initialCtx = defaultContext (specContext spec)
            rootedCtx = initialCtx {moduleRoot = "Acme"}
        first <- executePlannedScaffold out "counter.keiro" initialCtx spec
        second <- executePlannedScaffold out "moved-counter.keiro" rootedCtx spec
        reportStale second
          `shouldMatchList` [ StaleModule (kind m) (modulePath m) (if kind m == Generated then Just ExactGeneratedBannerPresent else Nothing)
                            | (m, _) <- reportDispositions first
                            ]
        forM_ (reportStale second) $ \stale -> doesFileExist (out </> stalePath stale) `shouldReturn` True
        renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "previous scaffold record used spec counter.keiro")
    it "reports moved generated modules across a layout flip" $
      withTempDirectory "keiro-dsl-stale-layout" $ \out -> do
        spec <- parseInlineSpec "<stale-layout>" loweringAggregateSpec
        let initialCtx = defaultContext (specContext spec)
            collocatedCtx = initialCtx {placement = CollocatedLeaf}
        first <- executePlannedScaffold out "counter.keiro" initialCtx spec
        second <- executePlannedScaffold out "counter.keiro" collocatedCtx spec
        let oldGenerated = [StaleModule Generated (modulePath m) (Just ExactGeneratedBannerPresent) | (m, _) <- reportDispositions first, kind m == Generated]
        reportStale second `shouldSatisfy` all (`elem` oldGenerated)
        length (reportStale second) `shouldBe` length oldGenerated
    it "writes a parseable record and no stale section for a fresh output" $
      withTempDirectory "keiro-dsl-record" $ \out -> do
        spec <- parseInlineSpec "<fresh-record>" loweringAggregateSpec
        let ctx = defaultContext (specContext spec)
        report <- executePlannedScaffold out "counter.keiro" ctx spec
        reportStale report `shouldBe` []
        renderScaffoldReport report `shouldSatisfy` all (not . T.isPrefixOf "stale:")
        contents <- TIO.readFile (out </> recordFileName (specContext spec))
        requirements <- either (\errors -> expectationFailure (show errors) >> pure []) pure (Behavior.deriveBehaviorRequirements spec)
        let expected =
              ScaffoldRecord
                { recSpecPath = "counter.keiro",
                  recModuleRoot = "",
                  recLayout = "prefixed",
                  recSourceLanguage = LegacyUnversioned,
                  recLanguageContract = effectiveLanguageContract LegacyUnversioned,
                  recFiles = [(kind m, modulePath m) | (m, _) <- reportDispositions report],
                  recMappings = [],
                  recIdDomains = [],
                  recNominalEqualities = [],
                  recBindingObligations = [],
                  recBehaviorRequirements = Behavior.behaviorRecordRows requirements
                }
            sourceRows = filter ("source-language " `T.isPrefixOf`) (T.lines contents)
            withoutSourceRows = T.unlines (filter (not . T.isPrefixOf "source-language ") (T.lines contents))
            semanticRows = filter ("semantic-contract " `T.isPrefixOf`) (T.lines contents)
            withoutSemanticRows = T.unlines (filter (not . T.isPrefixOf "semantic-contract ") (T.lines contents))
        parseRecord contents `shouldBe` Just expected
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
        let ctx = defaultContext (specContext spec)
        modules <- case planScaffold ctx spec of
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
                reportSourceLanguageDrift report
                  `shouldBe` Just (SourceLanguageDrift LegacyUnversioned declared)
                contents <- TIO.readFile (reportRecordPath report)
                recSourceLanguage <$> parseRecord contents `shouldBe` Just declared

  describe "faithful scaffold lowering" $ do
    it "escapes a trailing-backslash payload literal exactly once" $ do
      spec <- specOf "test/fixtures/hospital-surge.keiro"
      case [process | NProcess process <- specNodes spec] of
        process : _ -> do
          let timer = (procTimer process) {tmPayload = [FieldBinding "kind" (Just "\"follow-up\\\"")]}
              modules = scaffoldProcess (defaultContext (specContext spec)) process {procTimer = timer}
          generatedTextEndingIn "Process.hs" modules
            `shouldSatisfy` T.isInfixOf "\"kind\" .= (\"follow-up\\\\\" :: Value)"
        [] -> expectationFailure "hospital-surge fixture has no process"
    it "preserves quoted Text register initials and refuses unsafe register shapes" $ do
      spec <- parseInlineSpec "<register-initials>" loweringAggregateSpec
      let modules = scaffoldAggregate (defaultContext (specContext spec)) spec =<< [aggregate | NAggregate aggregate <- specNodes spec]
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
      case [publisher | NPublisher publisher <- specNodes exponential] of
        publisher : _ -> do
          let generated = generatedTextEndingIn "Publisher.hs" (scaffoldPublisher (defaultContext (specContext exponential)) publisher)
          generated `shouldSatisfy` T.isInfixOf "ExponentialBackoff ExponentialBackoffOptions { initial = 2, maxDelay = 60, multiplier = 2.0 }"
          parseSpec "<exponential-round-trip>" (renderSpec exponential) `shouldBe` Right exponential
        [] -> expectationFailure "emit fixture has no publisher"
      constant <- parseInlineSpec "<constant-backoff>" (T.replace "backoff constant 2s" "backoff constant 2m" emitSource)
      case [publisher | NPublisher publisher <- specNodes constant] of
        publisher : _ -> generatedTextEndingIn "Publisher.hs" (scaffoldPublisher (defaultContext (specContext constant)) publisher) `shouldSatisfy` T.isInfixOf "ConstantBackoff 120"
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
      case [workqueue | NWorkqueue workqueue <- specNodes queueSpec] of
        workqueue : _ -> do
          let policy = generatedTextEndingIn "QueuePolicy.hs" (scaffoldWorkqueue (defaultContext (specContext queueSpec)) workqueue)
          policy `shouldSatisfy` T.isInfixOf "defaultRetryDelay = RetryDelay 300"
          policy `shouldSatisfy` T.isInfixOf "Retry (RetryDelay 300)"
        [] -> expectationFailure "queue fixture has no workqueue"
    it "uses exact status-map keys and emits total Int harness samples" $ do
      statusSpec <- parseInlineSpec "<exact-status>" exactStatusSpec
      case [aggregate | NAggregate aggregate <- specNodes statusSpec] of
        aggregate : _ -> do
          let ctx = defaultContext (specContext statusSpec)
              projection = generatedTextEndingIn "Projection.hs" (scaffoldAggregate ctx statusSpec aggregate)
              harness = generatedTextEndingIn "Harness.hs" (harnessFor ctx statusSpec aggregate)
          projection `shouldSatisfy` T.isInfixOf "ReservationUnHeld {} -> Just \"available\""
          harness `shouldSatisfy` T.isInfixOf "CountBumpedData 0"
          harness `shouldNotSatisfy` T.isInfixOf "sample: unsupported"
        [] -> expectationFailure "exact-status spec has no aggregate"

  describe "scaffold" $ do
    it "synthesizes the exact old wire shape and embeds it in the harness" $ do
      oldSpec <- specOf "test/fixtures/reservation.keiro"
      newSpec <- specOf "test/fixtures/reservation-v2.keiro"
      case goldensForDiff oldSpec newSpec of
        [golden] -> do
          goldenRelativePath golden
            `shouldBe` "hospital-capacity/Reservation/TransferReservationCreated.v1.json"
          goldenJson golden
            `shouldBe` "{\"commandId\":\"cmd_01hzy3v7q2e8kaw2m5x0d41n9c\",\"divertStatus\":\"open\",\"hospitalId\":\"hosp_01hzy3v7q2e8kaw2m5x0d41n9c\",\"kind\":\"TransferReservationCreated\",\"lifeCriticalOverride\":true,\"patientAcuity\":\"red\",\"reservationId\":\"rsv_01hzy3v7q2e8kaw2m5x0d41n9c\"}\n"
          goldenEvidence golden `shouldBe` SynthesizedWeakStandIn
          let aggregate = onlyAggregate newSpec
              modules =
                harnessForWithGoldens
                  [golden]
                  (defaultContext (specContext newSpec))
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
          goldenEvidence golden `shouldBe` SynthesizedWeakStandIn
          goldenJson golden `shouldSatisfy` T.isInfixOf "\"artifact\":{"
          goldenJson golden `shouldSatisfy` T.isInfixOf "\"location\":{\"contents\":\"sample\",\"tag\":\"local_file\"}"
          goldenJson golden `shouldSatisfy` T.isInfixOf "\"labels\":[\"sample\"]"
          goldenJson golden `shouldSatisfy` T.isInfixOf "\"revision\":1"
          goldenJson golden `shouldSatisfy` T.isInfixOf "\"observedAt\":\"2026-01-01T00:00:00Z\""
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
            TIO.readFile target `shouldReturn` goldenJson golden
        goldens -> expectationFailure ("expected one nested synthesized golden, got " <> show goldens)
    it "dispatches shared-version upcasters by wire event type and passes foreign kinds through" $ do
      parsed <- parsedSourceOf "test/fixtures/reservation-dup-upcast-source.keiro"
      let spec = parsedSpec parsed
      case [aggregate | NAggregate aggregate <- specNodes spec] of
        [aggregate] -> do
          let modules = scaffoldServiceModules (defaultContext (specContext spec)) (checkedSource parsed)
              codec = generatedTextEndingIn "Codec.hs" modules
              holes = case [moduleText m | m <- modules, "/Holes.hs" `T.isSuffixOf` T.pack (modulePath m)] of
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
      let holes = [m | m <- mods, kind m == HoleStub]
      map (takeFileName . modulePath) holes `shouldBe` ["BehaviorHoles.hs", "Holes.hs"]
      -- Context nominals/internal/replay plus the stable aggregate surface.
      length [m | m <- mods, kind m == Generated] `shouldBe` 10
    it "is deterministic (re-scaffolding yields byte-identical text)" $ do
      a <- scaffoldFixture "test/fixtures/reservation.keiro"
      b <- scaffoldFixture "test/fixtures/reservation.keiro"
      map moduleText a `shouldBe` map moduleText b
    it "keeps retiring as validator-only metadata in generated modules" $ do
      ordinary <- scaffoldFixture "test/fixtures/reservation.keiro"
      retiring <- scaffoldFixture "test/fixtures/reservation-retiring.keiro"
      map (\m -> (modulePath m, kind m, moduleText m)) retiring
        `shouldBe` map (\m -> (modulePath m, kind m, moduleText m)) ordinary
    it "matches the committed compiling Generated conformance modules (modulo whitespace)" $ do
      mods <- scaffoldFixture "test/fixtures/reservation.keiro"
      mapM_ assertMatchesCommitted [m | m <- mods, kind m == Generated]
    it "matches every committed new-surface Generated module (modulo formatting)" $ do
      modules <- scaffoldFixture "test/fixtures/transfer-routing.keiro"
      forM_ [m | m <- modules, kind m == Generated] $ \m -> do
        committed <- readTestText ("test/conformance-newsurface/" <> modulePath m)
        normalizeGenerated committed `shouldBe` normalizeGenerated (moduleText m)
    it "scaffolds the register-free OrderStream smoke target without error" $ do
      mods <- scaffoldFixture "test/fixtures/order.keiro"
      -- Stable context and aggregate modules plus both hand-owned hole surfaces.
      length mods `shouldBe` 12
      firewallBreaches mods `shouldBe` []
      let harness = generatedTextEndingIn "Harness.hs" mods
      harness `shouldSatisfy` T.isInfixOf "prefix = \"forward/replay equality: PlaceOrder from OrderNotStarted -- \""
      harness `shouldSatisfy` T.isInfixOf "prefix <> \"final vertex\""
      harness `shouldNotSatisfy` T.isInfixOf "prefix <> \"register "
    it "emits forward/replay checks with field-distinct Text samples" $ do
      spec <- parseInlineSpec "<forward-replay-samples>" (T.replace "command Bump { count:Int }" "command Bump { count:Int noteText:Text echo:Text }" loweringAggregateSpec)
      case [aggregate | NAggregate aggregate <- specNodes spec] of
        aggregate : _ -> do
          let ctx = defaultContext (specContext spec)
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
      map moduleText twinMods `shouldSatisfy` any (T.isInfixOf "B.replayOnly")
      let twinHarness = generatedTextEndingIn "Harness.hs" twinMods
      T.count "forwardReplayRequestTransferReservation ::" twinHarness `shouldBe` 1
      plainMods <- scaffoldFixture "test/fixtures/reservation.keiro"
      map moduleText plainMods `shouldSatisfy` all (not . T.isInfixOf "B.replayOnly")

  describe "service workspace (EP-153)" $ do
    describe "manifest grammar" $ do
      it "round-trips the canonical fixture manifest byte-for-byte" $ do
        source <- readTestText canonicalWorkspacePath
        manifest <- shouldParseManifest canonicalWorkspacePath source
        wmfService manifest `shouldBe` "demo-project"
        wmfModuleRoot manifest `shouldBe` Just "Demo.Modules.Project"
        wmfLayout manifest `shouldBe` Just CollocatedLeaf
        map wmrPath (NE.toList (wmfMembers manifest))
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
        wsService workspace `shouldBe` "demo-project"
        wsContext workspace `shouldBe` "demo-project"
        wsModuleRoot workspace `shouldBe` Just "Demo.Modules.Project"
        wsLayout workspace `shouldBe` Just CollocatedLeaf
        map wmPath (wsMembers workspace)
          `shouldBe` [ "domain/project-artifact.keiro",
                       "domain/project.keiro",
                       "domain/shared.keiro"
                     ]
        -- Every member is individually incomplete; together they check.
        checkWorkspace workspace `shouldBe` []
      it "records which member owns each shared declaration and node" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let ownership = wsOwnership workspace
        fmap fst (declarationOwner ownership "id" "ProjectId")
          `shouldBe` Just "domain/shared.keiro"
        fmap fst (declarationOwner ownership "enum" "ProjectPhase")
          `shouldBe` Just "domain/shared.keiro"
        fmap fst (declarationOwner ownership "rule" "phaseIsTerminal")
          `shouldBe` Just "domain/shared.keiro"
        fmap fst (declarationOwner ownership "mapped" "ProjectSummary")
          `shouldBe` Just "domain/shared.keiro"
        fmap fst (nodeOwner ownership "aggregate" "Project")
          `shouldBe` Just "domain/project.keiro"
        fmap fst (nodeOwner ownership "aggregate" "ProjectArtifact")
          `shouldBe` Just "domain/project-artifact.keiro"
        fmap fst (nodeOwner ownership "readmodel" "project_activity")
          `shouldBe` Just "domain/project-artifact.keiro"
      it "maps every merged line back to the member that wrote it" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        let bases = [(wmPath m, wmLineBase m, wmLineCount m) | m <- wsMembers workspace]
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
        reordered {wsManifestPath = wsManifestPath canonical} `shouldBe` canonical
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
          `shouldSatisfy` any ((== Error) . wdSeverity)
    describe "composition refusals" $ do
      let refusesWith path expectedCode expectedFiles = do
            diagnostics <- shouldRefuseWorkspace path
            map wdCode (NE.toList diagnostics) `shouldContain` [expectedCode]
            let cited =
                  [ wlFile location
                  | diagnostic <- NE.toList diagnostics,
                    wdCode diagnostic == expectedCode,
                    location <- NE.toList (wdLocations diagnostic)
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
        let errors = [d | d <- checkWorkspace workspace, wdSeverity d == Error]
        map wdCode errors `shouldContain` [GuardAtomOutOfScope]
        [wlFile location | d <- errors, location <- NE.toList (wdLocations d)]
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
      map changeCode (diffSpecs (wsMergedSpec oldAdded) (wsMergedSpec newAdded))
        `shouldContain` [DeclarationAdded]

      oldRemoved <- loadFrom baseMembers baseFiles >>= expectLoaded
      newRemoved <-
        loadFrom
          ["domain/project.keiro", "domain/shared.keiro"]
          (Map.delete "domain/project-artifact.keiro" baseFiles)
          >>= expectLoaded
      map changeCode (diffSpecs (wsMergedSpec oldRemoved) (wsMergedSpec newRemoved))
        `shouldContain` [EvtRemovedNotDeprecated]

      oldRenamed <- loadFrom baseMembers baseFiles >>= expectLoaded
      let renamedMembers = ["domain/project-renamed.keiro", "domain/project-artifact.keiro", "domain/shared.keiro"]
          renamedFiles = Map.insert "domain/project-renamed.keiro" project (Map.delete "domain/project.keiro" baseFiles)
      newRenamed <- loadFrom renamedMembers renamedFiles >>= expectLoaded
      diffSpecs (wsMergedSpec oldRenamed) (wsMergedSpec newRenamed) `shouldBe` []

  describe "workspace diff ownership and unified reports (EP-155 M2)" $ do
    it "classifies shared declarations at use sites across every member with owned citations" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      new <- shouldComposeWorkspace "test/fixtures/workspace-diff-new/service.keiro-workspace"
      let changes = diffWorkspaces old new
          enumChanges = filter ((== EnumCtorAdded) . changeCode . wcChange) changes
          mappedChanges = filter ((== MappedFieldTypeChanged) . changeCode . wcChange) changes
          citedFiles workspaceChanges =
            [ osFile site
            | change <- workspaceChanges,
              (_, Just site) <- wcUseSites change
            ]
      enumChanges `shouldSatisfy` (not . null)
      mappedChanges `shouldSatisfy` (not . null)
      let enumWireChanges =
            [ change
            | workspaceChange <- enumChanges,
              let change = wcChange workspaceChange,
              OldBinaryReadNewEvents `elem` breakingSurfaces change
            ]
      enumWireChanges `shouldSatisfy` (not . null)
      enumWireChanges `shouldSatisfy` all (not . gatedBreaking defaultGate)
      enumWireChanges `shouldSatisfy` all (gatedBreaking (gateWith [OldBinaryReadNewEvents]))
      map (fmap osFile . wcDeclarationSite) (enumChanges <> mappedChanges)
        `shouldSatisfy` all (== Just "domain/shared.keiro")
      citedFiles enumChanges `shouldContain` ["domain/order.keiro", "domain/shipment.keiro"]
      citedFiles mappedChanges `shouldContain` ["domain/order.keiro", "domain/shipment.keiro"]
      let rendered = T.intercalate "\n" (map renderWorkspaceFinding (enumChanges <> mappedChanges))
      rendered `shouldSatisfy` T.isInfixOf "    declared: domain/shared.keiro:4"
      rendered `shouldSatisfy` T.isInfixOf "    use-site: Order"
      rendered `shouldSatisfy` T.isInfixOf "(domain/order.keiro:"
      rendered `shouldSatisfy` T.isInfixOf "(domain/shipment.keiro:"
      golden <- readTestText "test/fixtures/workspace-diff-new/workspace.diff.golden"
      T.unlines (map renderWorkspaceFinding changes) `shouldBe` golden

    it "emits one additive version-1 report with workspace provenance" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      new <- shouldComposeWorkspace "test/fixtures/workspace-diff-new/service.keiro-workspace"
      let changes = diffWorkspaces old new
          meta =
            WorkspaceMeta
              { wmIdentity = wsService new,
                wmManifest = "service.keiro-workspace",
                wmSince = "HEAD",
                wmMembersOld = map wmPath (wsMembers old),
                wmMembersNew = map wmPath (wsMembers new),
                wmAdoptionBaseline = False
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
      case replayImpactSpecs (wsMergedSpec old) (wsMergedSpec new) of
        ReplayAffected affected -> Map.keysSet affected `shouldBe` Set.fromList ["Order", "Shipment"]
        ReplayNeutral -> expectationFailure "shared mapped evolution unexpectedly reported replay-neutral"

  describe "workspace ownership and authority changes (EP-155 M3)" $ do
    it "reports an unchanged aggregate move once without wire evolution" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      moved <- shouldComposeWorkspace "test/fixtures/workspace-diff-moved/service.keiro-workspace"
      let changes = diffWorkspaces old moved
      map (changeCode . wcChange) changes `shouldBe` [OwnershipMoved]
      forM_ changes $ \workspaceMove -> do
        let move = wcChange workspaceMove
        move `shouldSatisfy` isAdvisory
        move `shouldSatisfy` (not . gatedBreaking defaultGate)
        move `shouldSatisfy` (not . gatedBreaking (gateWith [minBound .. maxBound]))
        deriveLabel defaultGate (ckVector (workspaceChangeKind move)) `shouldBe` LabelAdvisory
        remediationFor (ckContext (workspaceChangeKind move)) OwnershipMoved
          `shouldBe` (RemedyRescaffoldWorkspace :| [])
        renderWorkspaceFinding workspaceMove
          `shouldSatisfy` T.isInfixOf "declaration moved domain/shipment.keiro -> domain/order.keiro"

    it "treats a member rename as the same owner-map change" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      let ownership = wsOwnership old
          renamed =
            old
              { wsOwnership =
                  ownership
                    { oiNodes =
                        Map.adjust
                          (\(_, loc) -> ("domain/shipping.keiro", loc))
                          ("aggregate", "Shipment")
                          (oiNodes ownership)
                    }
              }
          moves = filter ((== OwnershipMoved) . changeCode . wcChange) (diffWorkspaces old renamed)
      length moves `shouldBe` 1
      forM_ moves $ \move ->
        renderWorkspaceFinding move `shouldSatisfy` T.isInfixOf "domain/shipment.keiro -> domain/shipping.keiro"

    it "reports ownership motion beside an independently classified wire edit" $ do
      old <- shouldComposeWorkspace "test/fixtures/workspace-diff-old/service.keiro-workspace"
      edited <- shouldComposeWorkspace "test/fixtures/workspace-diff-new/service.keiro-workspace"
      let ownership = wsOwnership edited
          movedAndEdited =
            edited
              { wsOwnership =
                  ownership
                    { oiNodes =
                        Map.adjust
                          (\(_, loc) -> ("domain/order.keiro", loc))
                          ("aggregate", "Shipment")
                          (oiNodes ownership)
                    }
              }
          codes = map (changeCode . wcChange) (diffWorkspaces old movedAndEdited)
      codes `shouldContain` [OwnershipMoved]
      codes `shouldContain` [MappedFieldTypeChanged]

    it "reports context authority separately from derived read-model identity breaks" $ do
      old <- shouldComposeWorkspace canonicalWorkspacePath
      let newContext = "demo-project-renamed"
          renamed =
            old
              { wsContext = newContext,
                wsMergedSpec = (wsMergedSpec old) {specContext = newContext}
              }
          changes = diffWorkspaces old renamed
          codes = map (changeCode . wcChange) changes
      codes `shouldContain` [WorkspaceAuthorityChanged]
      codes `shouldContain` [DerivedIdentityChanged]
      map wcChange changes `shouldSatisfy` any (gatedBreaking defaultGate)

    it "keeps service, module-root, and layout authority advisories non-blocking" $ do
      old <- shouldComposeWorkspace canonicalWorkspacePath
      let changed =
            old
              { wsService = "demo-project-renamed",
                wsModuleRoot = Just "Demo.Modules.Renamed",
                wsLayout = Just GeneratedPrefix
              }
          authority = filter ((== WorkspaceAuthorityChanged) . changeCode . wcChange) (diffWorkspaces old changed)
      length authority `shouldBe` 3
      forM_ (map wcChange authority) $ \change -> do
        deriveLabel defaultGate (ckVector (workspaceChangeKind change)) `shouldBe` LabelAdvisory
        change `shouldSatisfy` (not . gatedBreaking (gateWith [minBound .. maxBound]))
        remediationFor (ckContext (workspaceChangeKind change)) WorkspaceAuthorityChanged
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
        [row | row <- wrModules record, wrmOwner row == Nothing]
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
      it "keys history by service in a slot no context name can reach" $ do
        -- A context name is lexed as letters/digits/_/- and can never
        -- contain a dot, so the workspace slot cannot alias a legacy
        -- record even when the service is named after its context.
        workspaceRecordFileName "demo-project"
          `shouldBe` "keiro-dsl-scaffold-record.workspace.demo-project.txt"
        workspaceManifestFileName "demo-project"
          `shouldBe` "keiro-dsl-manifest.workspace.demo-project.txt"
        workspaceRecordFileName "demo-project" `shouldNotBe` recordFileName "demo-project"
        map
          (T.isInfixOf "." . T.pack)
          [ workspaceRecordFileName "demo-project",
            recordFileName "demo-project"
          ]
          `shouldBe` [True, True]
        supersededByLine "demo-project"
          `shouldBe` "superseded-by: keiro-dsl-scaffold-record.workspace.demo-project.txt"

    describe "workspace plan" $ do
      it "emits the context-level facade and replay-audit exactly once from the merged graph" $ do
        plan <- shouldPlanWorkspace canonicalWorkspacePath
        let modules = map fst (wpModules plan)
            facades = [m | m <- modules, "StructuralProjections.hs" `isSuffixOfPath` m]
            audits = [m | m <- modules, "ReplayAudit.hs" `isSuffixOfPath` m]
            shapes = [m | m <- modules, "Structural/Shape/ProjectSummary.hs" `isSuffixOfPath` m]
        length facades `shouldBe` 1
        length audits `shouldBe` 1
        length shapes `shouldBe` 1
        -- The audit assembles aggregates owned by two different member
        -- files, which is only possible from one merged graph.
        forM_ audits $ \audit -> do
          moduleText audit `shouldSatisfy` T.isInfixOf "Project.projectEventStream"
          moduleText audit `shouldSatisfy` T.isInfixOf "ProjectArtifact.projectArtifactEventStream"
      it "gives every generated ID and enum one context owner and imports only aggregate uses" $ do
        plan <- shouldPlanWorkspace canonicalWorkspacePath
        let ctx = wpContext plan
            modules = map fst (wpModules plan)
            nominalModules = [m | m <- modules, modulePath m == T.unpack (T.replace "." "/" (generatedNominalModule ctx) <> ".hs")]
            internalNominalModules = [m | m <- modules, modulePath m == T.unpack (T.replace "." "/" (generatedNominalModule ctx) <> "/Internal.hs")]
            domainFor suffix = case [m | m <- modules, suffix `isSuffixOfPath` m] of
              [m] -> pure m
              found -> expectationFailure ("expected one domain ending in " <> suffix <> ", got " <> show (map modulePath found)) >> fail "unreachable"
        ownerModule <- case nominalModules of
          [m] -> pure m
          found -> expectationFailure ("expected one generated nominal owner, got " <> show (map modulePath found)) >> fail "unreachable"
        internalOwnerModule <- case internalNominalModules of
          [m] -> pure m
          found -> expectationFailure ("expected one generated internal nominal owner, got " <> show (map modulePath found)) >> fail "unreachable"
        let nominalText = moduleText ownerModule
            internalNominalText = moduleText internalOwnerModule
        T.count "newtype ProjectId" nominalText `shouldBe` 0
        T.count "newtype ProjectId" internalNominalText `shouldBe` 1
        T.count "data ProjectPhase =" nominalText `shouldBe` 1
        T.count "data WorkspaceVisibility =" nominalText `shouldBe` 1
        projectDomain <- domainFor "Project/Generated/Domain.hs"
        artifactDomain <- domainFor "ProjectArtifact/Generated/Domain.hs"
        forM_ [projectDomain, artifactDomain] $ \domain -> do
          moduleText domain `shouldSatisfy` (not . T.isInfixOf "newtype ProjectId")
          moduleText domain `shouldSatisfy` (not . T.isInfixOf "data ProjectPhase")
          moduleText domain `shouldSatisfy` T.isInfixOf (generatedNominalModule ctx <> " (ProjectId, parseProjectId, ProjectPhase (..))")
          moduleText domain `shouldSatisfy` (not . T.isInfixOf "WorkspaceVisibility")
        singleFileModules <- case planServiceScaffold ctx (stableCheckedService (wsMergedSpec (wpWorkspace plan))) of
          Left refusals -> expectationFailure (show refusals) >> fail "unreachable"
          Right values -> pure values
        let withoutOrigin m = (modulePath m, moduleText m, kind m)
        map withoutOrigin singleFileModules `shouldBe` map withoutOrigin modules
        owners <- case planNominalGeneration ctx (wsMergedSpec (wpWorkspace plan)) of
          Left errors -> expectationFailure (show errors) >> fail "unreachable"
          Right values -> pure values
        map (resolvedNominalName . nominalDeclaration) owners
          `shouldBe` ["ProjectId", "ProjectPhase", "WorkspaceVisibility"]
        case [owner | owner <- owners, resolvedNominalName (nominalDeclaration owner) == "ProjectId"] of
          [owner] -> do
            nominalModule owner `shouldBe` generatedNominalModule ctx
            Set.fromList [NominalUseSite "Project" RegisterUse, NominalUseSite "ProjectArtifact" EventFieldUse]
              `shouldSatisfy` (`Set.isSubsetOf` nominalUseSites owner)
          found -> expectationFailure ("expected one ProjectId owner, got " <> show (length found))
      it "attributes every module to its owning member and leaves shared ones context-level" $ do
        plan <- shouldPlanWorkspace canonicalWorkspacePath
        let memberPaths = map wmPath (wsMembers (wpWorkspace plan))
            ownerOf suffix =
              case [provenance | (m, provenance) <- wpModules plan, suffix `isSuffixOfPath` m] of
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
        ownerOf "Project_activity/Generated/ReadModel.hs"
          `shouldBe` Just (MemberOwned "domain/project-artifact.keiro")
        -- No module may claim an owner that is not a member of the
        -- workspace: the record's owner column has to stay resolvable.
        map (provenanceOwner . snd) (wpModules plan)
          `shouldSatisfy` all (maybe True (`elem` memberPaths))
      it "keeps the compiled workspace nominal conformance tree byte-current" $ do
        workspace <- shouldComposeWorkspace "test/fixtures/workspace-nominals/service.keiro-workspace"
        plan <- shouldPlanWorkspaceSpec workspace
        let compiledPaths =
              [ "Generated/WorkspaceNominalProof/Nominals.hs",
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
        map fst (wpModules plan) `shouldSatisfy` all (not . isSuffixOfPath "/Holes.hs")
        forM_ compiledPaths $ \path ->
          case [m | (m, _) <- wpModules plan, modulePath m == path] of
            [generated] -> do
              committed <- readTestText ("test/conformance-workspace-nominals/" <> path)
              normalizeGenerated committed `shouldBe` normalizeGenerated (moduleText generated)
            found -> expectationFailure ("expected one generated module at " <> path <> ", got " <> show (map modulePath found))
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
          spec <- specOf path
          let ctx = defaultContext (specContext spec)
              workspace = oneMemberWorkspace path spec
          fmap (map fst . wpModules) (planWorkspaceScaffold "goldens" ctx workspace)
            `shouldBe` planScaffold ctx spec
        -- The equality is not vacuous: at least one fixture plans, and
        -- its per-node modules are attributed to the single member.
        spec <- specOf "test/fixtures/reservation.keiro"
        let workspace = oneMemberWorkspace "test/fixtures/reservation.keiro" spec
        case planWorkspaceScaffold "goldens" (defaultContext (specContext spec)) workspace of
          Left refusals -> expectationFailure ("reservation should plan: " <> show refusals)
          Right plan -> do
            wpModules plan `shouldSatisfy` (not . null)
            map snd (wpModules plan)
              `shouldSatisfy` all (`elem` [ContextLevel, MemberOwned "reservation.keiro"])
            map snd (wpModules plan)
              `shouldSatisfy` elem (MemberOwned "reservation.keiro")
      it "computes obligations from the complete merged graph, spanning members" $ do
        workspace <- shouldComposeWorkspace canonicalWorkspacePath
        case bindingObligations (wsMergedSpec workspace) of
          Left graphErrors -> expectationFailure ("merged graph did not resolve: " <> show graphErrors)
          Right obligations ->
            case [o | o <- obligations, obligationMappedName o == "ProjectSummary", obligationKind o == BindingValue] of
              [obligation] -> do
                obligationUseSites obligation
                  `shouldSatisfy` any (T.isInfixOf "Project register summary")
                obligationUseSites obligation
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
          wsrRecordPath report
            `shouldBe` out </> "keiro-dsl-scaffold-record.workspace.demo-project.txt"
          wsrBuildManifestPath report
            `shouldBe` out </> "keiro-dsl-manifest.workspace.demo-project.txt"
          doesFileExist (out </> recordFileName "demo-project") `shouldReturn` False
          doesFileExist (out </> "keiro-dsl-manifest.demo-project.txt") `shouldReturn` False
          contents <- TIO.readFile (wsrRecordPath report)
          buildManifest <- TIO.readFile (wsrBuildManifestPath report)
          assertGeneratedHaskellContract "service.keiro-workspace" buildManifest
          case parseWorkspaceRecord contents of
            Nothing -> expectationFailure ("workspace record did not parse:\n" <> T.unpack contents)
            Just record -> do
              wrService record `shouldBe` "demo-project"
              wrManifest record `shouldBe` "service.keiro-workspace"
              wrMembers record
                `shouldBe` [ "domain/project-artifact.keiro",
                             "domain/project.keiro",
                             "domain/shared.keiro"
                           ]
              -- Context-level modules are ownerless; everything
              -- else names the member that produced it.
              [wrmPath row | row <- wrModules record, wrmOwner row == Nothing]
                `shouldSatisfy` \ownerless ->
                  length ownerless == 4
                    && any (T.isSuffixOf "StructuralProjections.hs" . T.pack) ownerless
                    && any (T.isSuffixOf "Nominals.hs" . T.pack) ownerless
                    && any (T.isSuffixOf "Nominals/Internal.hs" . T.pack) ownerless
                    && any (T.isSuffixOf "ReplayAudit.hs" . T.pack) ownerless
              [ wrmOwner row
                | row <- wrModules record,
                  "Project/Generated/Domain.hs" `T.isSuffixOf` T.pack (wrmPath row)
                ]
                `shouldBe` [Just "domain/project.keiro"]
      it "is idempotent: an unchanged second run rewrites nothing and reports nothing" $
        withWorkspaceFixture "keiro-dsl-workspace-idempotent" id $ \_ out workspace -> do
          first <- executePlannedWorkspaceScaffold out workspace
          before <- treeSnapshot out
          second <- executePlannedWorkspaceScaffold out workspace
          after <- treeSnapshot out
          after `shouldBe` before
          map thd3 (wsrDispositions second)
            `shouldSatisfy` all (`elem` [Unchanged, Skipped])
          wsrStale second `shouldBe` []
          wsrOwnershipMoves second `shouldBe` []
          wsrMappingDrift second `shouldBe` []
          wsrNewHoles second `shouldBe` []
          -- The first run had to write; the claim is not vacuous.
          map thd3 (wsrDispositions first) `shouldSatisfy` any (== Overwritten)
          renderWorkspaceScaffoldReport second
            `shouldSatisfy` all (not . T.isPrefixOf "stale:")
      it "produces byte-identical output for members listed in reverse order" $
        withWorkspaceFixture "keiro-dsl-workspace-order-a" id $ \_ outA workspaceA ->
          withWorkspaceFixture "keiro-dsl-workspace-order-b" reverse $ \_ outB workspaceB -> do
            _ <- executePlannedWorkspaceScaffold outA workspaceA
            _ <- executePlannedWorkspaceScaffold outB workspaceB
            treeB <- treeSnapshot outB
            treeA <- treeSnapshot outA
            treeB `shouldBe` treeA
            map fst treeA `shouldSatisfy` elem "keiro-dsl-scaffold-record.workspace.demo-project.txt"
      it "reports stale files only for the member that changed" $
        withWorkspaceFixture "keiro-dsl-workspace-stale" id $ \root out workspace -> do
          first <- executePlannedWorkspaceScaffold out workspace
          let siblingPaths =
                [ modulePath m
                | (m, provenance, _) <- wsrDispositions first,
                  provenance == MemberOwned "domain/project-artifact.keiro"
                ]
          siblingsBefore <- traverse (TIO.readFile . (out </>)) siblingPaths
          renamed <- renameMemberAggregate root "domain/project.keiro" "Project" "Ledger"
          second <- executePlannedWorkspaceScaffold out renamed
          let stalePaths = map stalePath (wsrStale second)
          stalePaths `shouldSatisfy` (not . null)
          stalePaths `shouldSatisfy` all (T.isInfixOf "/Project/" . T.pack)
          -- Nothing the sibling member owns is stale, and nothing it
          -- owns changed on disk: no cross-member false positives.
          stalePaths `shouldSatisfy` all (`notElem` siblingPaths)
          siblingsAfter <- traverse (TIO.readFile . (out </>)) siblingPaths
          siblingsAfter `shouldBe` siblingsBefore
          forM_ stalePaths $ \path -> doesFileExist (out </> path) `shouldReturn` True
          wsrStale second
            `shouldSatisfy` all
              ( \stale -> case staleKind stale of
                  Generated -> staleGeneratedEvidence stale == Just ExactGeneratedBannerPresent
                  HoleStub -> staleGeneratedEvidence stale == Nothing
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
          before <- treeSnapshot out
          moved <- moveArtifactAggregate root
          second <- executePlannedWorkspaceScaffold out moved
          wsrStale second `shouldBe` []
          let moves = wsrOwnershipMoves second
          moves `shouldSatisfy` (not . null)
          moves
            `shouldSatisfy` all
              ( \move ->
                  omPrevious move == Just "domain/project-artifact.keiro"
                    && omCurrent move == Just "domain/project.keiro"
              )
          map omPath moves
            `shouldSatisfy` any (T.isInfixOf "ProjectArtifact" . T.pack)
          -- Stable behavior contracts retain source-line attribution, so
          -- moving a declaration may rewrite only those attributed modules.
          -- Every unaffected module and the build manifest remain untouched.
          map thd3 (wsrDispositions second)
            `shouldSatisfy` all (`elem` [Unchanged, Skipped, Overwritten])
          let overwrittenPaths =
                [modulePath generatedModule | (generatedModule, _, Overwritten) <- wsrDispositions second]
          length overwrittenPaths `shouldBe` 2
          overwrittenPaths `shouldSatisfy` all (T.isSuffixOf "/Generated/BehaviorContract.hs" . T.pack)
          after <- treeSnapshot out
          map fst after `shouldBe` map fst before
          let unaffected (path, _) =
                not ("scaffold-record" `T.isInfixOf` T.pack path)
                  && path `notElem` overwrittenPaths
          filter unaffected after `shouldBe` filter unaffected before
          renderWorkspaceScaffoldReport second
            `shouldSatisfy` any (T.isInfixOf "changed owning member")
      it "leaves the tree, record, and manifest untouched when any member refuses" $
        withWorkspaceFixture "keiro-dsl-workspace-atomic" id $ \_ out workspace -> do
          _ <- executePlannedWorkspaceScaffold out workspace
          before <- treeSnapshot out
          let broken = withCaseVariantAggregate workspace
          case planWorkspaceScaffold "goldens" (workspaceContext broken) broken of
            Right _ -> expectationFailure "expected the broken workspace to refuse"
            Left refusals -> refusals `shouldSatisfy` any isPathCollision
          treeSnapshot out `shouldReturn` before
          -- A fresh output directory is never even created.
          withTempDirectory "keiro-dsl-workspace-atomic-fresh" $ \fresh -> do
            let target = fresh </> "out"
            case planWorkspaceScaffold "goldens" (workspaceContext broken) broken of
              Right _ -> expectationFailure "expected the broken workspace to refuse"
              Left _ -> doesDirectoryExist target `shouldReturn` False
      it "leaves prior workspace output byte-identical for parse, validation, and collision failures" $
        withWorkspaceFixture "keiro-dsl-workspace-atomic-cli" id $ \root out workspace -> do
          _ <- executePlannedWorkspaceScaffold out workspace
          before <- treeSnapshot out
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
            treeSnapshot out `shouldReturn` before
            TIO.writeFile member original
      it "refuses the whole workspace for one bannerless Generated target, changing nothing" $
        withWorkspaceFixture "keiro-dsl-workspace-banner" id $ \_ out workspace -> do
          plan <- shouldPlanWorkspaceSpec workspace
          let generated = [m | (m, _) <- wpModules plan, kind m == Generated]
          case generated of
            [] -> expectationFailure "workspace fixture has no Generated module"
            target : _ -> do
              let path = out </> modulePath target
              createDirectoryIfMissing True (takeDirectory path)
              TIO.writeFile path "hand owned\n"
              before <- treeSnapshot out
              refused <- executeWorkspaceScaffold out False plan
              refused `shouldSatisfy` isMissingBannerRefusal
              treeSnapshot out `shouldReturn` before
              forced <- executeWorkspaceScaffold out True plan
              forced `shouldSatisfy` isSuccessfulScaffold
              TIO.readFile path `shouldReturn` moduleText target
      it "scaffolds a whole workspace through the CLI" $
        withTempDirectory "keiro-dsl-workspace-cli" $ \out -> do
          (exitCode, stdoutText, stderrText) <-
            runKeiroDsl ["scaffold", canonicalWorkspacePath, "--out", out]
          unless (exitCode == ExitSuccess) (expectationFailure (stdoutText <> stderrText))
          stderrText `shouldContain` "workspace: demo-project"
          doesFileExist (out </> "keiro-dsl-scaffold-record.workspace.demo-project.txt")
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

    describe "workspace adoption" $ do
      it "replaces embedded 0.6 nominal declarations only in generated files" $
        withWorkspaceFixture "keiro-dsl-workspace-nominal-adopt" id $ \_ out workspace -> do
          plan <- shouldPlanWorkspaceSpec workspace
          let pathEndingIn suffix selectedKind =
                case [modulePath m | (m, _) <- wpModules plan, kind m == selectedKind, suffix `isSuffixOfPath` m] of
                  [path] -> pure path
                  found -> expectationFailure ("expected one path ending in " <> suffix <> ", got " <> show found) >> fail "unreachable"
          domainPath <- pathEndingIn "Project/Generated/Domain.hs" Generated
          nominalPath <- pathEndingIn "Generated/Nominals.hs" Generated
          internalNominalPath <- pathEndingIn "Generated/Nominals/Internal.hs" Generated
          holePath <- pathEndingIn "Project/Holes.hs" HoleStub
          writeFileWithParents
            (out </> domainPath)
            (generatedBanner <> "\n-- legacy 0.6 fixture\nmodule LegacyDomain where\nnewtype ProjectId = ProjectId String\ndata ProjectPhase = Draft | Active\n")
          writeFileWithParents (out </> holePath) "-- hand-owned 0.6 implementation\n"

          report <- executePlannedWorkspaceScaffold out workspace
          wsrStale report `shouldBe` []
          [disposition | (m, _, disposition) <- wsrDispositions report, modulePath m == domainPath]
            `shouldBe` [Overwritten]
          [disposition | (m, _, disposition) <- wsrDispositions report, modulePath m == nominalPath]
            `shouldBe` [Overwritten]
          newDomain <- TIO.readFile (out </> domainPath)
          newDomain `shouldSatisfy` (not . T.isInfixOf "newtype ProjectId")
          newDomain `shouldSatisfy` T.isInfixOf "Generated.Nominals (ProjectId, parseProjectId, ProjectPhase (..))"
          newNominals <- TIO.readFile (out </> nominalPath)
          T.count "newtype ProjectId" newNominals `shouldBe` 0
          T.count "data ProjectPhase =" newNominals `shouldBe` 1
          newInternalNominals <- TIO.readFile (out </> internalNominalPath)
          T.count "newtype ProjectId" newInternalNominals `shouldBe` 1
          TIO.readFile (out </> holePath) `shouldReturn` "-- hand-owned 0.6 implementation\n"
      it "adopts an overwritten same-context record pair by record and by banner" $
        withInlineWorkspace "keiro-dsl-workspace-adopt" adoptionMembers $ \_ out workspace -> do
          -- Reproduce today's defect first: two same-context specs
          -- scaffolded independently into one directory, the second
          -- replacing the first's record and calling its files stale.
          specA <- parseInlineSpec "domain/a.keiro" adoptionMemberA
          specB <- parseInlineSpec "domain/b.keiro" adoptionMemberB
          let ctx = defaultContext "adoption-demo"
          legacyA <- executePlannedScaffold out "domain/a.keiro" ctx specA
          legacyB <- executePlannedScaffold out "domain/b.keiro" ctx specB
          reportStale legacyB `shouldSatisfy` (not . null)
          legacyBefore <- TIO.readFile (out </> recordFileName "adoption-demo")

          report <- executePlannedWorkspaceScaffold out workspace
          wsrStale report `shouldBe` []
          case wsrMigration report of
            Nothing -> expectationFailure "expected the first workspace run to adopt"
            Just migration -> do
              let generatedOf run = sort [modulePath m | (m, _) <- reportDispositions run, kind m == Generated]
                  claimedBy evidence = sort [cfPath entry | entry <- mrClaimed migration, cfEvidence entry == evidence]
              -- The surviving record attributes B's files; A's
              -- files survived only as banners, which is exactly
              -- the orphan case the overwrite created.
              claimedBy ClaimedFromRecord `shouldBe` generatedOf legacyB
              claimedBy ClaimedFromBanner `shouldBe` sort (generatedOf legacyA \\ generatedOf legacyB)
              claimedBy ClaimedFromBanner `shouldSatisfy` (not . null)
              mrLikelyStale migration `shouldBe` []
              mrLegacyRecord migration
                `shouldBe` Just (recordFileName "adoption-demo", "domain/b.keiro")
              -- Provenance is persisted, not merely printed.
              recorded <- parseWorkspaceRecord <$> TIO.readFile (wsrRecordPath report)
              fmap (sort . map adPath . wrAdopted) recorded
                `shouldBe` Just (sort (map cfPath (mrClaimed migration)))
              fmap (sort . nubOrd . map adEvidence . wrAdopted) recorded
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
            wsrMigration freshReport `shouldBe` Nothing
            adoptedTree <- treeSnapshot out
            freshTree <- treeSnapshot fresh
            haskellOnly adoptedTree `shouldBe` haskellOnly freshTree
      it "lists hand-written files as unclaimed and leaves their bytes alone" $
        withInlineWorkspace "keiro-dsl-workspace-unclaimed" adoptionMembers $ \_ out workspace -> do
          plan <- shouldPlanWorkspaceSpec workspace
          case [modulePath m | (m, _) <- wpModules plan, kind m == HoleStub] of
            [] -> expectationFailure "adoption fixture emits no hole module"
            holePath : _ -> do
              writeFileWithParents (out </> holePath) "-- hand filled\n"
              writeFileWithParents (out </> "Notes.hs") "module Notes where\n"
              report <- executePlannedWorkspaceScaffold out workspace
              case wsrMigration report of
                Nothing -> expectationFailure "expected a report for a directory holding hand-written files"
                Just migration -> do
                  mrLegacyRecord migration `shouldBe` Nothing
                  mrClaimed migration `shouldBe` []
                  mrUnclaimed migration `shouldBe` sort [holePath, "Notes.hs"]
              TIO.readFile (out </> holePath) `shouldReturn` "-- hand filled\n"
              TIO.readFile (out </> "Notes.hs") `shouldReturn` "module Notes where\n"
      it "never claims a bannerless file at a planned Generated path" $
        withInlineWorkspace "keiro-dsl-workspace-unattributable" adoptionMembers $ \_ out workspace -> do
          plan <- shouldPlanWorkspaceSpec workspace
          case [modulePath m | (m, _) <- wpModules plan, kind m == Generated] of
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
          wsrMigration first `shouldSatisfy` \case Just _ -> True; Nothing -> False
          before <- treeSnapshot out
          reportBefore <- TIO.readFile (out </> "keiro-dsl-migration-report.workspace.adoption-demo.txt")
          legacyBefore <- TIO.readFile (out </> recordFileName "adoption-demo")

          second <- executePlannedWorkspaceScaffold out workspace
          wsrMigration second `shouldBe` Nothing
          wsrStale second `shouldBe` []
          map thd3 (wsrDispositions second) `shouldSatisfy` all (`elem` [Unchanged, Skipped])
          treeSnapshot out `shouldReturn` before
          TIO.readFile (out </> "keiro-dsl-migration-report.workspace.adoption-demo.txt")
            `shouldReturn` reportBefore
          legacyAfter <- TIO.readFile (out </> recordFileName "adoption-demo")
          legacyAfter `shouldBe` legacyBefore
          length (filter (== supersededByLine "adoption-demo") (T.lines legacyAfter))
            `shouldBe` 1

comparisonProvenance :: CompareProvenance
comparisonProvenance =
  CompareProvenance
    { cpHistoricalCodecIdentity = "example.historical",
      cpHistoricalCodecVersion = "legacy-v1",
      cpCanonicalType = CanonicalTypeId "example.Artifact.v1",
      cpBindingSymbol = QualifiedValueName "Example.Bindings.artifactBinding",
      cpBindingVersion = BindingVersion "1",
      cpWireFingerprint = "deadbeef"
    }

syntheticGenerated :: FilePath -> T.Text -> ScaffoldModule
syntheticGenerated path contents =
  ScaffoldModule {modulePath = path, moduleText = contents, kind = Generated, origin = "test"}

generatedTextEndingIn :: T.Text -> [ScaffoldModule] -> T.Text
generatedTextEndingIn suffix modules = case [moduleText m | m <- modules, kind m == Generated, suffix `T.isSuffixOf` T.pack (modulePath m)] of
  contents : _ -> contents
  [] -> ""

generatedExtensionsEndingIn :: T.Text -> [ScaffoldModule] -> [T.Text]
generatedExtensionsEndingIn suffix modules = case [generatedModule | generatedModule <- modules, kind generatedModule == Generated, suffix `T.isSuffixOf` T.pack (modulePath generatedModule)] of
  [generatedModule] -> generatedLocalExtensions generatedModule
  matches -> error ("expected one generated module ending in " <> T.unpack suffix <> ", got " <> show (map modulePath matches))

generatedLocalExtensions :: ScaffoldModule -> [T.Text]
generatedLocalExtensions generatedModule =
  [ extension
  | line <- takeWhile (T.isPrefixOf languagePrefix) (T.lines (moduleText generatedModule)),
    Just extensionWithSuffix <- [T.stripPrefix languagePrefix line],
    Just extension <- [T.stripSuffix languageSuffix extensionWithSuffix]
  ]
  where
    languagePrefix = "{-# LANGUAGE "
    languageSuffix = " #-}"

holeTextEndingIn :: T.Text -> [ScaffoldModule] -> T.Text
holeTextEndingIn suffix modules = case [moduleText m | m <- modules, kind m == HoleStub, suffix `T.isSuffixOf` T.pack (modulePath m), not ("BehaviorHoles.hs" `T.isSuffixOf` T.pack (modulePath m))] of
  contents : _ -> contents
  [] -> ""

onlyAggregate :: Spec -> Aggregate
onlyAggregate spec = case [aggregate | NAggregate aggregate <- specNodes spec] of
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

executePlannedScaffold :: FilePath -> FilePath -> Context -> Spec -> IO ScaffoldReport
executePlannedScaffold out specPath ctx spec = case planScaffold ctx spec of
  Left refusals -> expectationFailure ("unexpected scaffold refusal: " <> show refusals) >> error "unreachable"
  Right modules -> do
    result <- executeScaffold out False specPath ctx spec modules
    case result of
      Left refusals -> expectationFailure ("unexpected execution refusal: " <> show refusals) >> error "unreachable"
      Right report -> pure report

renameCounter :: Node -> Node
renameCounter (NAggregate aggregate) =
  NAggregate
    aggregate
      { aggName = "Widget",
        aggRegs = [reg {regType = if regType reg == TRef "CounterVertex" then TRef "WidgetVertex" else regType reg} | reg <- aggRegs aggregate]
      }
renameCounter node = node

onlyPathEndingIn :: FilePath -> [ScaffoldModule] -> FilePath
onlyPathEndingIn suffix modules = case [modulePath m | m <- modules, T.pack suffix `T.isSuffixOf` T.pack (modulePath m)] of
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
  map code <$> diagnosticsOf path

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
  pure [code d | d <- diagnostics, severity d == Error]

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
          { tSource = "S",
            tCommand = "C",
            tImplementation = LegacyHoleImplementation,
            tGuard = Just e,
            tWrites = [],
            tEmits = [],
            tGoto = "S",
            tMode = TmLive,
            tLoc = noLoc
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
  spec
    { specNodes =
        [ case node of
            NAggregate aggregate | aggName aggregate == target -> NAggregate (update aggregate)
            _ -> node
        | node <- specNodes spec
        ]
    }

modifyReadModel :: Name -> (ReadModelNode -> ReadModelNode) -> Spec -> Spec
modifyReadModel target update spec =
  spec
    { specNodes =
        [ case node of
            NReadModel readModel | rmName readModel == target -> NReadModel (update readModel)
            _ -> node
        | node <- specNodes spec
        ]
    }

mapContract :: (ContractNode -> ContractNode) -> Spec -> Spec
mapContract update spec =
  spec
    { specNodes =
        [ case node of
            NContract contract -> NContract (update contract)
            _ -> node
        | node <- specNodes spec
        ]
    }

mapIntake :: (IntakeNode -> IntakeNode) -> Spec -> Spec
mapIntake update spec =
  spec
    { specNodes =
        [ case node of
            NIntake intake -> NIntake (update intake)
            _ -> node
        | node <- specNodes spec
        ]
    }

mapEmit :: (EmitNode -> EmitNode) -> Spec -> Spec
mapEmit update spec =
  spec
    { specNodes =
        [ case node of
            NEmit emitNode -> NEmit (update emitNode)
            _ -> node
        | node <- specNodes spec
        ]
    }

mapWorkflow :: (WorkflowNode -> WorkflowNode) -> Spec -> Spec
mapWorkflow update spec =
  spec
    { specNodes =
        [ case node of
            NWorkflow workflow -> NWorkflow (update workflow)
            _ -> node
        | node <- specNodes spec
        ]
    }

mapWorkqueue :: (WorkqueueNode -> WorkqueueNode) -> Spec -> Spec
mapWorkqueue update spec =
  spec
    { specNodes =
        [ case node of
            NWorkqueue queue -> NWorkqueue (update queue)
            _ -> node
        | node <- specNodes spec
        ]
    }

mapDispatch :: (PgmqDispatchNode -> PgmqDispatchNode) -> Spec -> Spec
mapDispatch update spec =
  spec
    { specNodes =
        [ case node of
            NPgmqDispatch dispatch -> NPgmqDispatch (update dispatch)
            _ -> node
        | node <- specNodes spec
        ]
    }

mapOperation :: (OperationNode -> OperationNode) -> Spec -> Spec
mapOperation update spec =
  spec
    { specNodes =
        [ case node of
            NOperation operation -> NOperation (update operation)
            _ -> node
        | node <- specNodes spec
        ]
    }

mapPublisher :: (PublisherNode -> PublisherNode) -> Spec -> Spec
mapPublisher update spec =
  spec
    { specNodes =
        [ case node of
            NPublisher publisher -> NPublisher (update publisher)
            _ -> node
        | node <- specNodes spec
        ]
    }

serviceErrorCodes :: Int -> Spec -> [DiagnosticCode]
serviceErrorCodes versionNumber spec =
  [code diagnostic | diagnostic <- validateService service, severity diagnostic == Error]
  where
    service = case languageVersion (fromIntegral versionNumber) >>= effectiveLanguageContractForVersion of
      Nothing -> error ("unsupported test language version " <> show versionNumber)
      Just languageContract -> CheckedService languageContract spec

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
  spec {specNodes = [node | node <- specNodes spec, not (isTarget node)]}
  where
    isTarget (NReadModel readModel) = rmName readModel == target
    isTarget _ = False

modifyRouter :: Name -> (RouterNode -> RouterNode) -> Spec -> Spec
modifyRouter target update spec =
  spec
    { specNodes =
        [ case node of
            NRouter router | rtId router == target -> NRouter (update router)
            _ -> node
        | node <- specNodes spec
        ]
    }

routerErrorCodes :: (RouterNode -> RouterNode) -> Spec -> [DiagnosticCode]
routerErrorCodes update = errorCodes . modifyRouter "PagingRouter" update

modifyProcess :: Name -> (ProcessNode -> ProcessNode) -> Spec -> Spec
modifyProcess target update spec =
  spec
    { specNodes =
        [ case node of
            NProcess process | procId process == target -> NProcess (update process)
            _ -> node
        | node <- specNodes spec
        ]
    }

processErrorCodes :: (ProcessNode -> ProcessNode) -> Spec -> [DiagnosticCode]
processErrorCodes update = errorCodes . modifyProcess "HospitalSurge" update

errorCodes :: Spec -> [DiagnosticCode]
errorCodes spec = [code diagnostic | diagnostic <- validateSpec spec, severity diagnostic == Error]

diagnosticCodes :: Spec -> [DiagnosticCode]
diagnosticCodes = map code . validateSpec

changeReadModelShape :: ReadModelNode -> ReadModelNode
changeReadModelShape readModel =
  readModel
    { rmColumns = rmColumns readModel <> [RmColumn "reviewed_by" "text" False],
      rmShape = "fnv1a:0000000000000000"
    }

-- | Assert a @new \<kind\>@ skeleton parses and validates with zero
-- error-severity diagnostics.
assertSkeletonValid :: T.Text -> IO ()
assertSkeletonValid kind = case skeletonFor kind of
  Left err -> expectationFailure (T.unpack ("skeleton for " <> kind <> ": " <> err))
  Right src -> case parseSpec ("new:" <> T.unpack kind) src of
    Left perr -> expectationFailure (T.unpack ("skeleton for " <> kind <> " failed to parse: " <> perr))
    Right spec ->
      [code d | d <- validateSpec spec, severity d == Error]
        `shouldBe` ([] :: [DiagnosticCode])

assertSkeletonUsesStableLanguage :: T.Text -> IO ()
assertSkeletonUsesStableLanguage kind = case skeletonFor kind of
  Left err -> expectationFailure (T.unpack ("skeleton for " <> kind <> ": " <> err))
  Right source -> case parseSource ("new:" <> T.unpack kind) source of
    Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
    Right parsed -> do
      let service = checkedSource parsed
      effectiveContractLanguageVersion (checkedLanguageContract service) `shouldBe` currentStableLanguageVersion
      effectiveLanguageSupport (checkedLanguageContract service) `shouldBe` Stable
      [code diagnostic | diagnostic <- validateService service, severity diagnostic == Error]
        `shouldBe` ([] :: [DiagnosticCode])
      scaffoldServiceModules (defaultContext (specContext (checkedSpec service))) service
        `shouldSatisfy` (not . null)

assertSkeletonScaffoldable :: T.Text -> IO ()
assertSkeletonScaffoldable kind = case skeletonFor kind of
  Left err -> expectationFailure (T.unpack ("skeleton for " <> kind <> ": " <> err))
  Right src -> case parseSpec ("new:" <> T.unpack kind) src of
    Left perr -> expectationFailure (T.unpack perr)
    Right spec -> planScaffold (defaultContext (specContext spec)) spec `shouldSatisfy` isSuccessfulScaffold

skeletonModuleRoots :: [(T.Text, T.Text)]
skeletonModuleRoots =
  [ ("aggregate", "SkelAggregate"),
    ("process", "SkelProcess"),
    ("router", "SkelRouter"),
    ("contract", "SkelContract"),
    ("intake", "SkelIntake"),
    ("emit", "SkelEmit"),
    ("workqueue", "SkelQueue"),
    ("workflow", "SkelWorkflow")
  ]

assertStableSkeletonMatchesCommitted :: T.Text -> T.Text -> IO ()
assertStableSkeletonMatchesCommitted kind root = case skeletonFor kind of
  Left err -> expectationFailure (T.unpack err)
  Right source -> case parseSource ("new:" <> T.unpack kind) source of
    Left err -> expectationFailure (T.unpack (renderParseFailure err))
    Right parsed -> do
      let service = checkedSource parsed
          spec = checkedSpec service
      let ctx = (defaultContext (specContext spec)) {moduleRoot = root}
      forM_ [m | m <- scaffoldServiceModules ctx service, kindOf m == Generated] $ \m -> do
        committed <- readTestText ("test/conformance-skeletons/" <> modulePath m)
        normalizeGenerated committed `shouldBe` normalizeGenerated (moduleText m)
  where
    kindOf = Keiro.Dsl.Scaffold.kind

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
                     { wfHaskell = "summary",
                       wfKey = "summary",
                       wfType = TText,
                       wfPresence = PRequired,
                       wfOnMissing = Nothing,
                       wfLoc = Loc 0
                     }
                 ]
          )
    }
addArtifactSummaryField declaration = declaration

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
    { specMapped = map removeInitial (specMapped spec),
      specNodes = map removeRegisters (specNodes spec)
    }
  where
    removeInitial declaration@MappedStructural {} = declaration {msInitial = Nothing}
    removeInitial declaration@MappedOpaque {} = declaration {moInitial = Nothing}
    removeRegisters (NAggregate aggregate) =
      NAggregate
        aggregate
          { aggRegs = [],
            aggTransitions = [transition {tWrites = []} | transition <- aggTransitions aggregate]
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
changeCode (Additive kind) = ckCode kind
changeCode (Advisory kind) = ckCode kind
changeCode (Breaking kind) = ckCode kind

breakingSurfaces :: Change -> [CompatibilitySurface]
breakingSurfaces change =
  [ surface
  | surface <- [minBound .. maxBound],
    verdictFor surface (ckVector kind) == VBreaking
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
    Right workspace -> pure workspace {wsManifestPath = path}

-- | The 'Context' a workspace scaffolds under, with no CLI overrides: the
-- members' unanimous context name, the manifest's module-root and layout
-- authority, and the built-in defaults where the manifest is silent.
workspaceContext :: WorkspaceSpec -> Context
workspaceContext workspace =
  Context
    { contextName = wsContext workspace,
      moduleRoot = maybe "" id (wsModuleRoot workspace),
      placement = maybe GeneratedPrefix id (wsLayout workspace)
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
isSuffixOfPath suffix m = T.pack suffix `T.isSuffixOf` T.pack (modulePath m)

-- | A workspace record built from real composed data plus two synthetic
-- adoption rows, so the round-trip test exercises every row kind including the
-- JSON encodings shared with the v1 record.
sampleWorkspaceRecord :: WorkspaceSpec -> WorkspaceRecord
sampleWorkspaceRecord workspace =
  WorkspaceRecord
    { wrService = wsService workspace,
      wrManifest = "service.keiro-workspace",
      wrContext = wsContext workspace,
      wrModuleRoot = maybe "" id (wsModuleRoot workspace),
      wrLayout = "collocated",
      wrMembers = map wmPath (wsMembers workspace),
      wrSourceLanguages =
        [ WorkspaceSourceLanguageRow (wmPath member) (wmSourceLanguage member)
        | member <- wsMembers workspace
        ],
      wrLanguageContract = wsLanguageContract workspace,
      wrModules =
        [ WorkspaceModuleRow Generated "Demo/Generated/StructuralProjections.hs" Nothing,
          WorkspaceModuleRow Generated "Demo/Project/Generated/Domain.hs" (Just "domain/project.keiro"),
          WorkspaceModuleRow HoleStub "Demo/Project/Holes.hs" (Just "domain/shared.keiro")
        ],
      wrMappings = consumerMappings (consumerPlan (wsMergedSpec workspace)),
      wrIdDomains = [],
      wrNominalEqualities = nominalEqualityIdentities (wsMergedSpec workspace),
      wrBindingObligations = either (const []) id (bindingHoles (wsMergedSpec workspace)),
      wrBehaviorRequirements = [],
      wrAdopted =
        [ AdoptedRow "claimed/One.hs" "record" (Just "keiro-dsl-scaffold-record.demo-project.txt") (Just "project.keiro"),
          AdoptedRow "claimed/Two.hs" "banner" Nothing Nothing
        ]
    }

-- | The canonical workspace with a case-variant copy of one member's aggregate
-- grafted onto another member. Composition refuses this shape (EP-153 catches it
-- at the earliest boundary), so the planner's own cross-member collision gate can
-- only be exercised by constructing the graph directly — which is exactly what
-- this does, mirroring the single-file @caseVariant@ construction.
withCaseVariantAggregate :: WorkspaceSpec -> WorkspaceSpec
withCaseVariantAggregate workspace = case [aggregate | NAggregate aggregate <- specNodes merged, aggName aggregate == "Project"] of
  [] -> error "canonical workspace fixture has no Project aggregate"
  aggregate : _ ->
    let shouted = aggregate {aggName = T.toUpper (aggName aggregate)}
        ownership = wsOwnership workspace
     in workspace
          { wsMergedSpec = merged {specNodes = specNodes merged <> [NAggregate shouted]},
            wsOwnership =
              ownership
                { oiNodes =
                    Map.insert
                      ("aggregate", aggName shouted)
                      ("domain/project-artifact.keiro", Loc 1)
                      (oiNodes ownership)
                }
          }
  where
    merged = wsMergedSpec workspace

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
  readProcessWithExitCode "cabal" (["run", "-v0", "keiro-dsl", "--"] <> resolved) ""
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
      { wmfService = service,
        wmfServiceLoc = Loc 1,
        wmfModuleRoot = moduleRoot,
        wmfModuleRootLoc = Loc 2,
        wmfLayout = layout,
        wmfLayoutLoc = Loc 3,
        wmfMembers = NE.fromList [WorkspaceMemberRef path (Loc 4) | path <- sort chosen]
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
            "aggregate=" <> aggName aggregate,
            "fingerprint=" <> aggregateFoldFingerprintForService service aggregate,
            "surface-begin"
          ]
            <> T.lines (aggregateFoldSurfaceForService service aggregate)
            <> ["surface-end"]
        )
    | NAggregate aggregate <- specNodes (checkedSpec service)
    ]

-- | Parse a fixture through the source-aware boundary and return its graph.
specOf :: FilePath -> IO Spec
specOf = fmap checkedSpec . checkedServiceOf

-- | Parse a fixture and scaffold its checked semantic service.
scaffoldFixture :: FilePath -> IO [ScaffoldModule]
scaffoldFixture path = do
  service <- checkedServiceOf path
  pure (scaffoldServiceModules (defaultContext (specContext (checkedSpec service))) service)

legacyScaffoldProcessFixture :: FilePath -> IO [ScaffoldModule]
legacyScaffoldProcessFixture path = do
  spec <- specOf path
  pure $ concat [scaffoldProcess (ctx spec) process | NProcess process <- specNodes spec]
  where
    ctx spec = defaultContext (specContext spec)

-- | Assert a freshly-scaffolded Generated module matches its committed copy
-- under test/conformance/ (whitespace-normalized). The committed copies are the
-- ones the keiro-dsl-conformance suite compiles, so this pins the live scaffolder
-- to known-compiling output.
assertMatchesCommitted :: ScaffoldModule -> IO ()
assertMatchesCommitted m = do
  let committedPath = "test/conformance/" <> modulePath m
  committed <- readTestText committedPath
  normalizeGenerated committed `shouldBe` normalizeGenerated (moduleText m)

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

parseInlineSpec :: FilePath -> T.Text -> IO Spec
parseInlineSpec sourceName src = case parseSpec sourceName src of
  Left err -> expectationFailure (T.unpack err) >> error "unreachable"
  Right spec -> pure spec

parseStableRenderedSpec :: FilePath -> Spec -> Either T.Text Spec
parseStableRenderedSpec sourceName spec =
  case parseSource sourceName stableSource of
    Left failure -> Left (renderParseFailure failure)
    Right parsed -> Right (parsedSpec parsed)
  where
    stableSource =
      "language keiro-dsl "
        <> T.pack (show (languageVersionNumber currentStableLanguageVersion))
        <> "\n"
        <> renderSpec spec

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
    { specMapped = filter (not . isVendorGeometry) (specMapped spec),
      specNodes = map stripNode (specNodes spec)
    }
  where
    isVendorGeometry MappedOpaque {moName = "VendorGeometry"} = True
    isVendorGeometry _ = False
    stripNode (NAggregate aggregate) =
      NAggregate
        aggregate
          { aggRegs = filter ((/= TRef "VendorGeometry") . regType) (aggRegs aggregate),
            aggCommands = map stripCommand (aggCommands aggregate),
            aggEvents = map stripEvent (aggEvents aggregate)
          }
    stripNode node = node
    stripCommand command = command {cmdFields = filter ((/= Just (TRef "VendorGeometry")) . aggregateFieldType) (cmdFields command)}
    stripEvent event = event {evBody = case evBody event of EventFields fields -> EventFields (filter ((/= Just (TRef "VendorGeometry")) . aggregateFieldType) fields); body -> body}

withMetadataJson :: Spec -> Spec
withMetadataJson spec = spec {specMapped = map updateDeclaration (specMapped spec)}
  where
    updateDeclaration declaration@MappedStructural {msName = "ArtifactMetadata", msShape = ShapeRecord constructor unknownFields fields} =
      declaration
        { msShape =
            ShapeRecord
              constructor
              unknownFields
              [if wfHaskell field == "note" then field {wfType = TJson} else field | field <- fields]
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
        { wfHaskell = "field" <> T.pack (show index),
          wfKey = "field" <> T.pack (show index),
          wfType = fieldType,
          wfPresence = PRequired,
          wfOnMissing = Nothing,
          wfLoc = noLoc
        }
    | (index, fieldType) <- zip [(1 :: Int) ..] types
    ]

mapArtifactField :: (WireField -> WireField) -> Spec -> Spec
mapArtifactField = mapArtifactNamedField "key"

mapArtifactNamedField :: Name -> (WireField -> WireField) -> Spec -> Spec
mapArtifactNamedField target transform spec = spec {specMapped = map updateDeclaration (specMapped spec)}
  where
    updateDeclaration declaration@MappedStructural {msName = "ArtifactInfo", msShape = ShapeRecord constructor unknownFields fields} =
      declaration
        { msShape =
            ShapeRecord
              constructor
              unknownFields
              [if wfHaskell field == target then transform field else field | field <- fields]
        }
    updateDeclaration declaration = declaration

mapMappedStructural :: Name -> (MappedDecl -> MappedDecl) -> Spec -> Spec
mapMappedStructural target transform spec =
  spec
    { specMapped =
        [ case declaration of
            MappedStructural {msName = name}
              | name == target -> transform declaration
            _ -> declaration
        | declaration <- specMapped spec
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
  Right graph -> concatMap (uncurry (declarationMutations graph)) (zip [0 :: Int ..] (specMapped spec))
  where
    declarationMutations graph declarationIndex declaration = case declaration of
      MappedStructural {msName = declarationName, msShape = shape} -> case shape of
        ShapeRecord _ _ fields ->
          concat
            [ [ mutation
                  graph
                  declarationName
                  MappedWireKeyChanged
                  (fieldSubject field {wfKey = wfKey field <> "__mutated"})
                  (mutateRecordField declarationIndex fieldIndex (\value -> value {wfKey = wfKey value <> "__mutated"}) spec),
                mutation
                  graph
                  declarationName
                  MappedPresenceChanged
                  (fieldSubject field)
                  (mutateRecordField declarationIndex fieldIndex (\value -> value {wfPresence = flipPresence (wfPresence value)}) spec)
              ]
                <> [ mutation
                       graph
                       declarationName
                       defaultCode
                       (fieldSubject field)
                       (mutateRecordField declarationIndex fieldIndex (\value -> value {wfOnMissing = changedDefault}) spec)
                   | oldDefault <- maybeToListTest (wfOnMissing field),
                     let (changedDefault, defaultCode) = mutateDefault oldDefault
                   ]
            | (fieldIndex, field) <- zip [0 :: Int ..] fields
            ]
        ShapeEnum entries ->
          [ mutation
              graph
              declarationName
              MappedEnumSpellingChanged
              (enumSubject entry {weTag = weTag entry <> "__mutated"})
              (mutateEnumEntry declarationIndex entryIndex (\value -> value {weTag = weTag value <> "__mutated"}) spec)
          | (entryIndex, entry) <- zip [0 :: Int ..] entries
          ]
        ShapeUnion _ arms ->
          [ mutation
              graph
              declarationName
              MappedArmTagChanged
              (armSubject arm {waTag = waTag arm <> "__mutated"})
              (mutateUnionArm declarationIndex armIndex (\value -> value {waTag = waTag value <> "__mutated"}) spec)
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
fieldSubject field = ".field " <> wfHaskell field <> "[\"" <> wfKey field <> "\"]"

enumSubject :: WireEnum -> T.Text
enumSubject entry = ".enum " <> weCtor entry <> "[\"" <> weTag entry <> "\"]"

armSubject :: WireArm -> T.Text
armSubject arm = ".arm " <> waCtor arm <> "[\"" <> waTag arm <> "\"]"

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
  spec {specMapped = updateAt declarationIndex transform (specMapped spec)}

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
    { specMapped =
        [ if mappedDeclarationName declaration == target then transform declaration else declaration
        | declaration <- specMapped spec
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
    [NAggregate (Aggregate "Thing" [] [] [] [] [] Nothing Nothing Nothing noLoc)]

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
          { ctrName = "Contract",
            ctrSchemaVersion = 1,
            ctrDiscriminator = "kind",
            ctrTopics = [("events", value)],
            ctrEvents = [],
            ctrLoc = noLoc
          },
      NEmit
        EmitNode
          { emName = "Emit",
            emContract = "Contract",
            emTopic = "events",
            emSource = "source",
            emKey = "key",
            emDiscriminant = "status",
            emMap = [EmitMapRow value "Event" noLoc],
            emSkip = True,
            emMessageId = DeriveSpec Nothing,
            emIdempotencyKey = DeriveSpec Nothing,
            emLoc = noLoc
          },
      NProcess (processWithLiteral value)
    ]

processWithLiteral :: T.Text -> ProcessNode
processWithLiteral value =
  ProcessNode
    { procId = "Process",
      procName = "process",
      procInput = InputDecl "Input" [],
      procCorrelate = CorrelateDecl "key" "idText",
      procSaga = SagaRef "Saga" "saga",
      procTarget = "Target",
      procProjections = [],
      procHandle =
        HandleNode
          { hOn = "Input",
            hAdvance = AdvanceNode "Advance" [FieldBinding "literal" (Just ("\"" <> value <> "\""))],
            hDispatch = [],
            hSchedule = "timer"
          },
      procRejected = PolHalt,
      procPoison = PolHalt,
      procTimer =
        TimerNode
          { tmName = "timer",
            tmId = IdExpr UuidV5Id "timer:",
            tmFireAt = FireAtExpr "observedAt" "5m",
            tmPayload = [],
            tmFire =
              FireNode
                { fireTarget = "Target",
                  fireKey = "correlationId",
                  fireCommand = "Fire",
                  fireFields = [],
                  fireFiredEventId = IdExpr UuidV5Id "fired:",
                  fireDisposition = FireDisposition OFired OFired ORetry ORetry ORetry
                },
            tmDecodeUnknown = "Cancelled",
            tmMaxAttempts = 5,
            tmDeadLetter = "exhausted",
            tmLoc = noLoc
          },
      procLoc = noLoc
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
genAggregateField = AggregateField <$> genName <*> genMaybe (genTypeExpr []) <*> pure noLoc

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
      { evName = name,
        evBody = eventBody,
        evVersion = version,
        evUpcastFrom = upcast,
        evRetiring = retiring,
        evDeprecated = deprecated,
        evLoc = noLoc
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
genIdExpr = IdExpr UuidV5Id <$> genAdversarialText

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
    <*> (InputDecl <$> genName <*> smallList genField)
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
    <*> (InputDecl <$> genName <*> smallList genField)
    <*> (CorrelateDecl <$> genName <*> genName)
    <*> (ResolveDecl <$> genResolveSource <*> smallList genName <*> pure noLoc)
    <*> genName
    <*> smallList genName
    <*> (RouterDispatchNode <$> genName <*> smallList genFieldBinding <*> genDispatchDisposition <*> pure noLoc)
    <*> elements [PolHalt, PolDeadLetter, PolSkip]
    <*> elements [PolHalt, PolDeadLetter, PolSkip]
    <*> pure noLoc

genContractField :: Gen ContractField
genContractField = ContractField <$> genName <*> oneof [CTypeId <$> genAdversarialText, pure CText, pure CInt]

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
genWqField = WqField <$> genName <*> genAdversarialText <*> genName <*> arbitrary

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
genReadModel =
  ReadModelNode
    <$> genName
    <*> genAdversarialText
    <*> genAdversarialText
    <*> smallList (RmColumn <$> genWireWord <*> genName <*> arbitrary)
    <*> choose (0, 5)
    <*> genAdversarialText
    <*> elements [Strong, Eventual]
    <*> genMaybe (oneof [pure RmEntireLog, RmCategory <$> genAdversarialText])
    <*> elements [RmInline, RmSubscription]
    <*> genMaybe genAdversarialText
    <*> pure noLoc

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
  NWorkflow _ -> "workflow"
  NOperation _ -> "operation"

consumerNominalFor :: Name -> NominalOwnership
consumerNominalFor name =
  ConsumerNominal
    ConsumerNominalBinding
      { consumerNominalHaskell = HaskellSource "domain" "Domain.Types" name,
        consumerNominalBinding = QualifiedValueName "Domain.Bindings.binding",
        consumerNominalBindingVersion = BindingVersion "1",
        consumerNominalCanonical = CanonicalTypeId ("domain." <> name <> ".v1"),
        consumerNominalFixtures = QualifiedValueName "Domain.Bindings.fixtures",
        consumerNominalInitial = Just (QualifiedValueName "Domain.Bindings.initialValue")
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
  contextName <- genWire
  moduleRoot <- genMaybe genModuleRoot
  layout <- genMaybe (elements [GeneratedPrefix, CollocatedLeaf])
  ids <- smallList genId
  enums <- smallList genEnum
  rules <- smallList genRule
  mapped <- genMappedDecls
  nodes <- smallList genNode
  pure (Spec contextName moduleRoot layout ids enums rules [] mapped nodes)
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
  take 10 (T.lines manifest)
    `shouldBe` [ "-- keiro-dsl build manifest for " <> sourceName,
                 "-- Paste the complete fragment below into the consuming Cabal stanza.",
                 "-- The generated layer is overwritten on every scaffold; hole modules are",
                 "-- create-if-absent (filled by hand).",
                 "",
                 "default-language: GHC2024",
                 "default-extensions:",
                 "    OverloadedStrings",
                 "",
                 "other-modules:"
               ]
