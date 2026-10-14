module Keiro.Dsl.MappedRegisterConstruction (mappedRegisterConstructionSpec) where

import Control.Exception (bracket)
import Control.Monad (filterM, forM_, unless)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.List (findIndex)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.CanonicalEncoding (canonicalExpr)
import Keiro.Dsl.Diff qualified as Diff
import Keiro.Dsl.ExplainBindings
import Keiro.Dsl.FoldFingerprint
import Keiro.Dsl.Grammar hiding (Spec)
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.MappedConsumer
import Keiro.Dsl.Parser
import Keiro.Dsl.PrettyPrint
import Keiro.Dsl.ReplayImpact
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRecord (ScaffoldRecord (..), parseRecord)
import Keiro.Dsl.ScaffoldRun (ScaffoldReport (..), executeServiceScaffold, scaffoldServiceModules)
import Keiro.Dsl.SemanticContract
import Keiro.Dsl.Validate
import Keiro.Dsl.Workspace qualified as W
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)
import Test.Hspec

mappedRegisterConstructionSpec :: Spec
mappedRegisterConstructionSpec = describe "mapped register construction" $ do
  it "extends only candidate syntax while preserving runtime capabilities" $ do
    languageVersionsSupportingFeature MappedRegisterConstructionSyntax `shouldBe` [currentAuthoringLanguageVersion]
    syntaxProfileIdentifier ((NE.last languageRegistry).syntaxProfile) `shouldBe` "keiro-dsl/syntax-profile/5"
    runtimeProfileIdentifier ((NE.last languageRegistry).runtimeSemanticsProfile) `shouldBe` "keiro-dsl/runtime-semantics/5"
  it "checks and round-trips write-only target initial and a Time lift" $ do
    source <- fixture
    service <- parseChecked source
    errors service `shouldBe` []
    reparsed <- parseChecked ("language keiro-dsl 6\n" <> renderSpec (checkedSpec service))
    renderSpec (checkedSpec reparsed) `shouldBe` renderSpec (checkedSpec service)
    let modules = scaffoldServiceModules (defaultContext "mapped-register-construction") service
        transducer = T.unlines [entry.text | entry <- modules, "Transducer.hs" `T.isSuffixOf` T.pack entry.path]
    transducer `shouldSatisfy` T.isInfixOf "K.opaqueLit"
    transducer `shouldSatisfy` T.isInfixOf "K.TApp1"
    transducer `shouldSatisfy` T.isInfixOf "B.requireGuard"
    transducer `shouldSatisfy` T.isInfixOf "B.slot @\"dormantSince\" =:"
    let skeletons = T.unlines [entry.text | entry <- modules, entry.kind == HoleStub]
    skeletons `shouldSatisfy` T.isInfixOf "atTime :: UTCTime -> MaybeTime"
    skeletons `shouldSatisfy` T.isInfixOf "NonEmpty (Text, UTCTime, MaybeTime)"
    skeletons `shouldSatisfy` (not . T.isInfixOf "NominalBinding")
  it "refuses mapped syntax in Language 5 at its marker" $ do
    source <- fixture
    let old = T.replace "language keiro-dsl 6" "language keiro-dsl 5" source
    case parseSource "language5.keiro" old of
      Left failure -> renderParseFailure failure `shouldSatisfy` T.isInfixOf "LanguageFeatureRequiresVersion"
      Right _ -> expectationFailure "Language 5 accepted candidate syntax"
  it "keeps Language 5 initial roots and Language 6 qualified roots unambiguous" $ do
    let source version rhs = T.unlines ["language keiro-dsl " <> version, "context roots", "aggregate Roots", "  regs initial Int = 0", "  states Empty Done!", "  command Set {}", "  event SetEvent = fields(Set)", "  Empty -- Set -->", "    write initial := " <> rhs, "    emit SetEvent", "    goto Done", "  wire kind=ctorName fields=camelCase schemaVersion=1"]
    old <- parseChecked (source "5" "initial")
    errors old `shouldBe` []
    new <- parseChecked (source "6" "initial")
    codes new `shouldContain` [AggregateExpressionWriteInitialShadowed]
    qualified <- parseChecked (source "6" "reg.initial")
    errors qualified `shouldBe` []
    arithmetic <- parseChecked (T.replace "Int" "Integer" (source "6" "initial + 1"))
    errors arithmetic `shouldBe` []
  it "diagnoses command initial shadowing and preserves continued initial paths" $ do
    let source rhs = T.unlines ["language keiro-dsl 6", "context roots", "aggregate Roots", "  regs value Int = 0", "  states Empty Done!", "  command Set { initial:Int }", "  event SetEvent = fields(Set)", "  Empty -- Set -->", "    write value := " <> rhs, "    emit SetEvent", "    goto Done", "  wire kind=ctorName fields=camelCase schemaVersion=1"]
    shadow <- parseChecked (source "initial")
    codes shadow `shouldContain` [AggregateExpressionWriteInitialShadowed]
    qualified <- parseChecked (source "cmd.initial")
    errors qualified `shouldBe` []
    continued <- parseChecked (source "initial.field")
    codes continued `shouldContain` [AggregateExpressionPathInvalid]
    codes continued `shouldSatisfy` (not . elem AggregateExpressionWriteInitialShadowed)
  it "rejects absent lifts, incomplete blocks, and duplicate declarations at their boundary" $ do
    source <- fixture
    let withoutLift = T.unlines (takeWhile (not . T.isInfixOf "write-lift from") (T.lines source)) <> "}\n" <> snd (T.breakOn "aggregate Lifecycle" source)
    absent <- parseChecked withoutLift
    codes absent `shouldContain` [AggregateExpressionMappedLiftUnsupported]
    forM_ ["    function = \"Conformance.MappedRegisterConstruction.Lift.atTime\"\n", "    version = \"1\"\n", "    fixtures = \"Conformance.MappedRegisterConstruction.Lift.atTimeCases\"\n"] $ \fact -> do
      incomplete <- parseChecked (T.replace fact "" source)
      codes incomplete `shouldContain` [MappedWriteLiftInvalid]
    let extra = "  write-lift from Time { function = \"Example.Lift.construct\" version = \"1\" fixtures = \"Example.Lift.cases\" }\n"
    case parseSource "duplicate.keiro" (T.replace "aggregate Lifecycle" (extra <> "aggregate Lifecycle") source) of
      Left _ -> pure ()
      Right _ -> expectationFailure "misplaced lift parsed as a top-level declaration"
    case parseSource "duplicate.keiro" (T.replace "  write-lift from Time {" (extra <> "  write-lift from Time {") source) of
      Left failure -> renderParseFailure failure `shouldSatisfy` T.isInfixOf "duplicate write-lift"
      Right _ -> expectationFailure "duplicate write-lift was accepted"
  it "rejects invalid initial targets and mapped source types before generation" $ do
    source <- fixture
    forM_
      [ ("write dormantSince := initial", "write automatic := initial", AggregateExpressionWriteInitialUnsupported),
        ("mapped(cmd.markedAt)", "mapped(true)", AggregateExpressionOperandTypeMismatch),
        ("write-lift from Time", "write-lift from Optional Time", MappedWriteLiftInvalid),
        ("version = \"1\"\n    fixtures", "version = \"\"\n    fixtures", MappedWriteLiftInvalid),
        ("Lift.atTime\"", "Lift.Bad\"", MappedInvalidHaskellName),
        ("Lift.atTimeCases\"", "bad.atTimeCases\"", MappedInvalidHaskellName)
      ]
      $ \(before, after, wanted) -> do
        changed <- parseChecked (T.replace before after source)
        codes changed `shouldContain` [wanted]
  it "rejects predicates even with a Bool lift source" $ do
    source <- fixture
    changed <- parseChecked (T.replace "mapped(cmd.markedAt)" "mapped(reg.automatic == true)" (T.replace "write-lift from Time" "write-lift from Bool" source))
    codes changed `shouldContain` [AggregateExpressionOperatorUnsupported]
  it "preserves exclusive generated guard/write ownership" $ do
    source <- fixture
    changed <- parseChecked (T.replace "write dormantSince := mapped(cmd.markedAt)" "implementation hole\n    write dormantSince := mapped(cmd.markedAt)" source)
    codes changed `shouldContain` [AggregateTransitionOwnershipConflict]
  it "records lift provenance and round-trips new obligation kinds" $ do
    service <- fixture >>= parseChecked
    let mappings = (consumerPlanForService service).mappings
    length mappings `shouldBe` 1
    Aeson.eitherDecode (Aeson.encode mappings) `shouldBe` Right mappings
    let obligations = either (error . show) id (bindingObligationsForService service)
    map (.kind) obligations `shouldMatchList` [WriteLiftFunction, WriteLiftCases]
    Aeson.eitherDecode (Aeson.encode obligations) `shouldBe` Right obligations
    (consumerPlanForService service).modules `shouldContain` ["Conformance.MappedRegisterConstruction.Lift"]
  it "decodes mapping ledgers written before the optional lift field existed" $ do
    let bytes = "{\"schema\":1,\"mode\":\"opaque\",\"specName\":\"Legacy\",\"package\":\"domain\",\"module\":\"Domain\",\"type\":\"Legacy\",\"codecIdentity\":\"legacy\",\"codecVersion\":\"1\"}"
    case Aeson.eitherDecode bytes :: Either String MappingIdentity of
      Left message -> expectationFailure message
      Right OpaqueMapping {writeLift} -> writeLift `shouldBe` Nothing
      Right _ -> expectationFailure "wrong mapping mode"
  it "resolves each real revision for lift removal and source replacement" $ do
    source <- fixture
    old <- parseChecked source
    let withoutLift =
          T.unlines (takeWhile (not . T.isInfixOf "write-lift from") (T.lines source))
            <> "}\n"
            <> snd (T.breakOn "aggregate Lifecycle" source)
    removal <- parseChecked (T.replace "mapped(cmd.markedAt)" "initial" withoutLift)
    replacement <- parseChecked (T.replace "mapped(cmd.markedAt)" "mapped(reg.automatic)" (T.replace "write-lift from Time" "write-lift from Bool" source))
    forM_ [removal, replacement] $ \new -> do
      errors new `shouldBe` []
      replayImpactServices old new `shouldBe` Right (ReplayAffected (Map.singleton "Lifecycle" (AggregateImpact (Set.fromList ["Created", "Marked", "Pinged", "Awakened", "ClosedEvent", "Reopened"]) True)))
  it "versions used behavior, excluding evidence and unused lifts from fold identity" $ do
    source <- fixture
    old <- parseChecked source
    new <- parseChecked (T.replace "version = \"1\"\n    fixtures" "version = \"2\"\n    fixtures" source)
    cases <- parseChecked (T.replace "Lift.atTimeCases" "Lift.alternateCases" source)
    fingerprint old `shouldNotBe` fingerprint new
    fingerprint old `shouldBe` fingerprint cases
    replayImpactServices old cases `shouldBe` Right ReplayNeutral
    let copies = T.replace "mapped(cmd.markedAt)" "reg.dormantSince" source
    unused <- parseChecked copies
    unusedNew <- parseChecked (T.replace "version = \"1\"\n    fixtures" "version = \"2\"\n    fixtures" copies)
    fingerprint unused `shouldBe` fingerprint unusedNew
    replayImpactServices unused unusedNew `shouldBe` Right ReplayNeutral
    let changes = either (error . show) id (Diff.diffServices old new)
    map changeCode changes `shouldContain` [MappedWriteLiftChanged, AggFoldSurfaceChanged]
  it "frames used lift provenance as compact JSON, preserving arbitrary version characters" $ do
    source <- fixture
    service <- parseChecked source
    let liftVersion = "λ:\"|\n"
        spec = checkedSpec service
        change declaration@MappedOpaque {moWriteLift = Just lift} = declaration {moWriteLift = Just (MappedWriteLiftDecl lift.source lift.function (Just liftVersion) lift.fixtures lift.loc)}
        change declaration = declaration
        changed = checkedServiceWithSpec spec {mapped = map change spec.mapped} service
        surface = either (error . show) id (aggregateFoldSurfaceForService changed (aggregate changed))
    surface `shouldSatisfy` T.isInfixOf "mapped-write-lifts=[[\"dormantSince\",\"MaybeTime\",\"Time\",\"Conformance.MappedRegisterConstruction.Lift.atTime\",\"λ:\\\"|\\n\"]]"
    canonicalExpr (EWriteInitial noLoc) `shouldBe` "initial"

  it "keeps another aggregate using only whole-value copies unchanged" $ do
    source <- fixture
    let (_, machine) = T.breakOn "aggregate Lifecycle" source
        copy = T.replace "aggregate Lifecycle" "aggregate CopyOnly" (T.replace "mapped(cmd.markedAt)" "reg.dormantSince" (T.replace "write dormantSince := initial" "write dormantSince := reg.dormantSince" machine))
        combined = source <> "\n" <> copy
    old <- parseChecked combined
    new <- parseChecked (T.replace "version = \"1\"\n    fixtures" "version = \"2\"\n    fixtures" combined)
    errors old `shouldBe` []
    errors new `shouldBe` []
    let copyAggregate service = case [value | NAggregate value <- (checkedSpec service).nodes, value.name == "CopyOnly"] of
          value : _ -> value
          [] -> error "copy aggregate missing"
    aggregateFoldFingerprintForService old (copyAggregate old) `shouldBe` aggregateFoldFingerprintForService new (copyAggregate new)
    case replayImpactServices old new of
      Right (ReplayAffected impacts) -> Map.keys impacts `shouldBe` ["Lifecycle"]
      result -> expectationFailure (show result)
  it "pins multiple used-lift tuples and escaped version text in write order" $ do
    source <- fixture
    service <- parseChecked (T.replace "    automatic Bool = False" "    automatic Bool = False\n    secondSince MaybeTime = initial" (T.replace "write dormantSince := mapped(cmd.markedAt)" "write dormantSince := mapped(cmd.markedAt)\n    write secondSince := mapped(cmd.markedAt)" source))
    let spec = checkedSpec service
        change declaration@MappedOpaque {moWriteLift = Just lift} = declaration {moWriteLift = Just (MappedWriteLiftDecl lift.source lift.function (Just "λ:\"|\n") lift.fixtures lift.loc)}
        change declaration = declaration
        changed = checkedServiceWithSpec spec {mapped = map change spec.mapped} service
        surface = either (error . show) id (aggregateFoldSurfaceForService changed (aggregate changed))
        fields = [snd (T.breakOn "mapped-write-lifts=" line) | line <- T.lines surface, "mapped-write-lifts=" `T.isInfixOf` line]
    golden <- T.stripEnd <$> TIO.readFile "test/fixtures/mapped-register-construction-lifts.golden"
    fields `shouldBe` [golden, golden]
  it "keeps historical scaffold records and their mapping drift baseline readable" $ do
    ledger <- TIO.readFile "test/conformance-structural/keiro-dsl-ledger.context.structural-conformance.txt"
    case parseRecord ledger of
      Nothing -> expectationFailure "pre-lift ledger lost its complete scaffold record"
      Just record -> do
        record.mappings `shouldSatisfy` (not . null)
        forM_ record.mappings $ \case
          StructuralMapping {writeLift} -> writeLift `shouldBe` Nothing
          OpaqueMapping {writeLift} -> writeLift `shouldBe` Nothing
          NominalMapping {} -> pure ()
  it "reports both lift metadata codes with the complete build-only vector" $ do
    source <- fixture
    old <- parseChecked source
    forM_
      [ (T.replace "Lift.atTime\"" "Lift.alternate\"" source, MappedWriteLiftChanged),
        (T.replace "Lift.atTimeCases" "Lift.alternateCases" source, MappedWriteLiftFixturesChanged)
      ]
      $ \(newSource, wanted) -> do
        new <- parseChecked newSource
        let changes = either (error . show) id (Diff.diffServices old new)
            findings = [value | change <- changes, value <- case change of Diff.Additive value -> [value]; Diff.Advisory value -> [value]; Diff.Breaking value -> [value], value.code == wanted]
        length findings `shouldBe` 1
        map (.vector) findings `shouldBe` [Diff.CompatibilityVector Diff.VCompatible Diff.VCompatible Diff.VNotApplicable Diff.VNotApplicable Diff.VNotApplicable Diff.VAdvisory Set.empty]
        map (.facet) findings `shouldBe` ["mapped-build"]
  it "keeps event, queue, query, and projection-only lifts build-only and replay-neutral" $ do
    source <- TIO.readFile "test/fixtures/projection-catalog.keiro"
    old <- parseChecked (T.replace "language keiro-dsl 5" "language keiro-dsl 6" source)
    let spec = checkedSpec old
        lift = MappedWriteLiftDecl TTime (Just "Example.Lift.construct") (Just "1") (Just "Example.Lift.cases") noLoc
        add declaration@MappedStructural {} = declaration {msWriteLift = Just lift}
        add declaration@MappedOpaque {} = declaration {moWriteLift = Just lift}
        add declaration@MappedRefined {} = declaration
        new = checkedServiceWithSpec spec {mapped = map add spec.mapped} old
        changes = either (error . show) id (Diff.diffServices old new)
        liftKinds = [kind | change <- changes, kind <- case change of Diff.Additive kind -> [kind]; Diff.Advisory kind -> [kind]; Diff.Breaking kind -> [kind], kind.code `elem` [MappedWriteLiftChanged, MappedWriteLiftFixturesChanged]]
    errors new `shouldBe` []
    liftKinds `shouldSatisfy` (not . null)
    map (.facet) liftKinds `shouldSatisfy` all (== "mapped-build")
    map (.vector) liftKinds `shouldSatisfy` all (== Diff.CompatibilityVector Diff.VCompatible Diff.VCompatible Diff.VNotApplicable Diff.VNotApplicable Diff.VNotApplicable Diff.VAdvisory Set.empty)
    replayImpactServices old new `shouldBe` Right ReplayNeutral
  it "fails invalid actual revisions rather than manufacturing a fold identity" $ do
    source <- fixture
    old <- parseChecked source
    invalid <- parseChecked (T.replace "mapped(cmd.markedAt)" "mapped(true)" source)
    fingerprint invalid `shouldSatisfy` either (const True) (const False)
    replayImpactServices old invalid `shouldSatisfy` either (const True) (const False)
  it "checks structural record, enum, union, bare, and refined initial targets" $ do
    source <- fixture
    let (_, machine) = T.breakOn "aggregate Lifecycle" source
        declaration kind shape withLift =
          T.unlines
            [ "language keiro-dsl 6",
              "context mapped-register-construction",
              "mapped " <> kind <> " MaybeTime {",
              "  haskell package=keiro-dsl module=Conformance.MappedRegisterConstruction.Domain type=MaybeTime",
              "  binding = \"Conformance.MappedRegisterConstruction.Bindings.binding\"",
              "  binding-version = \"1\"",
              "  canonical-type = \"conformance.MaybeTime.v1\"",
              "  fixtures = \"Conformance.MappedRegisterConstruction.Bindings.cases\"",
              "  initial = \"Conformance.MappedRegisterConstruction.Bindings.noTime\"",
              if withLift then "  write-lift from Time { function = \"Conformance.MappedRegisterConstruction.Lift.atTime\" version = \"1\" fixtures = \"Conformance.MappedRegisterConstruction.Lift.atTimeCases\" }" else "",
              "  wire " <> shape,
              "}"
            ]
    forM_
      [ ("structural record", "object constructor=MaybeTime unknown-fields=reject { value as \"value\" : Time required }"),
        ("structural enum", "string { NoTime as \"none\" Present as \"present\" }"),
        ("structural union", "tagged-object tag=\"kind\" contents=\"value\" unknown-fields=reject { NoTime as \"none\" Present as \"present\" : Time }"),
        ("structural value", "Optional Time")
      ]
      $ \(kind, shape) -> do
        service <- parseChecked (declaration kind shape True <> machine)
        errors service `shouldBe` []
        let code = T.unlines [entry.text | entry <- scaffoldServiceModules (defaultContext "mapped-register-construction") service]
        code `shouldSatisfy` T.isInfixOf "K.TApp1"
        code `shouldSatisfy` T.isInfixOf "K.opaqueLit"
    refined <- parseChecked (declaration "refined" "base16-bytes" False <> T.replace "mapped(cmd.markedAt)" "initial" machine)
    errors refined `shouldBe` []
  it "compiles fresh opaque lift skeletons for every admitted scalar with strict imports" $ do
    original <- fixture
    forM_ ["Text", "Int", "Integer", "Bool", "Natural", "Time", "UTCTime"] $ \sourceType -> withScratch $ \out -> do
      service <- parseChecked (T.replace "markedAt:Time" ("markedAt:" <> sourceType) (T.replace "write-lift from Time" ("write-lift from " <> sourceType) original))
      errors service `shouldBe` []
      let skeleton = case [entry | entry <- scaffoldServiceModules (defaultContext "mapped-register-construction") service, "Construction/Lift.hs" `T.isSuffixOf` T.pack entry.path] of
            entry : _ -> entry
            [] -> error "missing opaque lift skeleton"
          target = out </> skeleton.path
      createDirectoryIfMissing True (takeDirectory target)
      TIO.writeFile target skeleton.text
      compileSkeleton out target
  it "qualifies a consumer type that collides with the Time lift source" $ withScratch $ \out -> do
    original <- fixture
    service <- parseChecked (T.replace "type=MaybeTime" "type=UTCTime" original)
    let skeleton = case [entry | entry <- scaffoldServiceModules (defaultContext "mapped-register-construction") service, "Construction/Lift.hs" `T.isSuffixOf` T.pack entry.path] of
          entry : _ -> entry
          [] -> error "missing collision skeleton"
        target = out </> skeleton.path
        domain = out </> "Conformance/MappedRegisterConstruction/Domain.hs"
    createDirectoryIfMissing True (takeDirectory target)
    TIO.writeFile target skeleton.text
    TIO.writeFile domain "module Conformance.MappedRegisterConstruction.Domain (UTCTime (..)) where\nimport Data.Time qualified as Time\nnewtype UTCTime = ConsumerTime Time.UTCTime\n"
    compileSkeleton out target
  it "preserves create-once opaque implementations and reports later missing symbols" $ withScratch $ \out -> do
    source <- fixture
    service <- parseChecked source
    let context = defaultContext "mapped-register-construction"
        run candidate = executeServiceScaffold out False "construction.keiro" (DeclaredLanguage currentAuthoringLanguageVersion (Loc 1)) context candidate (scaffoldServiceModules context candidate)
        target = out </> "Conformance/MappedRegisterConstruction/Lift.hs"
    initialReport <- run service
    initialReport `shouldSatisfy` either (const False) (const True)
    before <- TIO.readFile target
    TIO.writeFile target (before <> "\n-- consumer implementation marker\n")
    let saved = before <> "\n-- consumer implementation marker\n"
    _ <- run service
    TIO.readFile target `shouldReturn` saved
    changed <- parseChecked (T.replace "Lift.atTime\"" "Lift.atTimeV2\"" (T.replace "Lift.atTimeCases" "Lift.atTimeCasesV2" source))
    result <- run changed
    case result of
      Left refusals -> expectationFailure (show refusals)
      Right report -> map (.symbol) report.newHoles `shouldMatchList` ["atTimeV2", "atTimeCasesV2"]
    TIO.readFile target `shouldReturn` saved
  it "retains lift declaration and child locations in a multi-member workspace" $ do
    source <- fixture
    let (declarations, machine) = T.breakOn "aggregate Lifecycle" source
        header = "language keiro-dsl 6\ncontext mapped-register-construction\n"
    forM_
      [ (T.replace "Lift.atTime\"" "Lift.Bad\"" declarations, header <> machine, MappedInvalidHaskellName, "00-types.keiro"),
        (T.replace "write-lift from Time" "write-lift from Optional Time" declarations, header <> machine, MappedWriteLiftInvalid, "00-types.keiro"),
        (declarations, header <> T.replace "mapped(cmd.markedAt)" "mapped(true)" machine, AggregateExpressionOperandTypeMismatch, "10-machine.keiro")
      ]
      $ \(types, transitions, wanted, member) -> do
        let manifest = either (error . show) id (W.parseWorkspaceManifest "service.keiro-workspace" "service construction\nspec 00-types.keiro\nspec 10-machine.keiro\n")
            document path text = either (error . show) id (parseSourceDocument path text)
            workspace = either (error . show) id (W.composeWorkspace "service.keiro-workspace" manifest [("00-types.keiro", types, document "00-types.keiro" types), ("10-machine.keiro", transitions, document "10-machine.keiro" transitions)])
            located = [NE.head diagnostic.locations | diagnostic <- W.checkWorkspace workspace, diagnostic.code == wanted]
        located `shouldSatisfy` (not . null)
        map (.file) located `shouldSatisfy` all (== W.WorkspaceMemberFile member)
        let memberText = if member == "00-types.keiro" then types else transitions
            marker = if member == "00-types.keiro" then "write-lift from" else "mapped(true)"
            row = maybe (error "marker missing") (+ 1) (findIndex (T.isInfixOf marker) (T.lines memberText))
        map (.line) located `shouldContain` [row]

fixture :: IO Text
fixture = TIO.readFile "test/fixtures/mapped-register-construction.keiro"

parseChecked :: Text -> IO CheckedService
parseChecked source = case parseSource "construction.keiro" source of
  Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> error "parse failed"
  Right parsed -> pure (checkedSource parsed)

errors :: CheckedService -> [Diagnostic]
errors = filter ((== Error) . (.severity)) . validateService

codes :: CheckedService -> [DiagnosticCode]
codes = map (.code) . errors

aggregate :: CheckedService -> Aggregate
aggregate service = case [value | NAggregate value <- (checkedSpec service).nodes] of
  value : _ -> value
  [] -> error "fixture has no aggregate"

fingerprint :: CheckedService -> Either FoldSurfaceError Text
fingerprint service = aggregateFoldFingerprintForService service (aggregate service)

changeCode :: Diff.Change -> DiagnosticCode
changeCode (Diff.Additive value) = value.code
changeCode (Diff.Advisory value) = value.code
changeCode (Diff.Breaking value) = value.code

withScratch :: (FilePath -> IO a) -> IO a
withScratch = bracket acquire removeDirectoryRecursive
  where
    acquire = do
      root <- getTemporaryDirectory
      (path, handle) <- openTempFile root "keiro-plan267-skeleton"
      hClose handle
      removeFile path
      createDirectory path
      pure path

compileSkeleton :: FilePath -> FilePath -> IO ()
compileSkeleton out target = do
  packageId <- activeKeikiPackageId
  (status, stdout, stderr) <-
    readProcessWithExitCode
      "cabal"
      [ "exec",
        "--enable-tests",
        "--",
        "ghc",
        "-XGHC2024",
        "-XOverloadedStrings",
        "-fno-code",
        "-Wall",
        "-Werror",
        "-package-id",
        packageId,
        "-outputdir",
        out,
        "-i" <> out,
        "-itest/conformance-mapped-register-construction",
        target
      ]
      ""
  unless (status == ExitSuccess) (expectationFailure (stdout <> stderr))

activeKeikiPackageId :: IO String
activeKeikiPackageId = do
  let packageName = "keiki"
  planPaths <- filterM doesFileExist ["dist-newstyle/cache/plan.json", "../dist-newstyle/cache/plan.json"]
  planPath <- case planPaths of
    candidate : _ -> pure candidate
    [] -> expectationFailure "could not find Cabal's dist-newstyle/cache/plan.json" >> fail "unreachable"
  decodedPlan <- Aeson.eitherDecodeFileStrict' planPath :: IO (Either String Aeson.Value)
  let packageIds = case decodedPlan of
        Right (Aeson.Object plan) -> case KeyMap.lookup "install-plan" plan of
          Just (Aeson.Array entries) ->
            [ T.unpack packageId
            | Aeson.Object entry <- toList entries,
              KeyMap.lookup "pkg-name" entry == Just (Aeson.String (T.pack packageName)),
              KeyMap.lookup "component-name" entry == Just (Aeson.String "lib"),
              Just (Aeson.String packageId) <- [KeyMap.lookup "id" entry]
            ]
          _ -> []
        _ -> []
  case packageIds of
    [packageId] -> pure packageId
    resolvedPackageIds ->
      expectationFailure
        ( "could not resolve one active Cabal package ID for "
            <> packageName
            <> ": "
            <> show resolvedPackageIds
            <> either (\decodeError -> " (plan decode failed: " <> decodeError <> ")") (const "") decodedPlan
        )
        >> fail "unreachable"
