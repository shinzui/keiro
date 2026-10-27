module Keiro.Dsl.MappedStructuralEnumEquality (mappedStructuralEnumEqualitySpec) where

import Control.Monad (forM_)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.AggregateType
import Keiro.Dsl.Diff qualified as Diff
import Keiro.Dsl.ExplainBindings
import Keiro.Dsl.Expression
import Keiro.Dsl.FoldFingerprint
import Keiro.Dsl.Grammar hiding (Spec)
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser
import Keiro.Dsl.ReplayImpact
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRecord
import Keiro.Dsl.ScaffoldRun (scaffoldServiceModules)
import Keiro.Dsl.SemanticContract
import Keiro.Dsl.TypeGraph (MappedKey (..))
import Keiro.Dsl.Validate
import Keiro.Dsl.WorkspaceRecord qualified as WR
import Test.Hspec

mappedStructuralEnumEqualitySpec :: Spec
mappedStructuralEnumEqualitySpec = describe "mapped structural enum equality" $ do
  it "admits only Language 6 and adds no global fold segment" $ do
    let definitions = NE.toList languageRegistry
    [definition.version | definition <- definitions, runtimeProfileHasCapability definition.runtimeSemanticsProfile StructuralEnumEqualityGuards] `shouldBe` [currentAuthoringLanguageVersion]
    capabilityFoldSegment StructuralEnumEqualityGuards `shouldBe` Nothing
    source <- fixture
    forM_ ["4", "5"] $ \version -> do
      service <- parseChecked (T.replace "language keiro-dsl 6" ("language keiro-dsl " <> version) source)
      codes service `shouldContain` [AggregateGuardCapabilityUnsupported]
      wrapped <- parseChecked (T.replace "language keiro-dsl 6" ("language keiro-dsl " <> version) (replaceGuard "(cmd.requiredScope == reg.requiredScope) == true" source))
      codes wrapped `shouldContain` [AggregateGuardCapabilityUnsupported]
      literalWrite <- parseChecked (T.replace "language keiro-dsl 6" ("language keiro-dsl " <> version) (T.unlines (filter (not . T.isPrefixOf "    guard ") (T.lines source))))
      codes literalWrite `shouldContain` [AggregateGuardCapabilityUnsupported]
  it "checks both operators with roots, qualified constructors on either side, and self comparisons" $ do
    source <- fixture
    forM_ [left <> " " <> operator <> " " <> right | operator <- ["==", "!="], (left, right) <- [("cmd.requiredScope", "reg.requiredScope"), ("cmd.requiredScope", "RequiredScope.PipelineScope"), ("RequiredScope.DiagnosticScope", "reg.requiredScope"), ("cmd.requiredScope", "cmd.requiredScope"), ("RequiredScope.PipelineScope", "RequiredScope.DiagnosticScope")]] $ \guardText -> do
      service <- parseChecked (replaceGuard guardText source)
      errors service `shouldBe` []
      let modules = scaffoldServiceModules (defaultContext "mapped-structural-enum-equality") service
      firewallBreaches modules `shouldBe` []
  it "rejects invalid operands and operations at the expression" $ do
    source <- fixture
    forM_
      [ ("cmd.requiredScope == \"pipeline\"", AggregateExpressionOperandTypeMismatch),
        ("cmd.requiredScope < reg.requiredScope", AggregateExpressionOperatorUnsupported),
        ("cmd.requiredScope + reg.requiredScope == cmd.requiredScope", AggregateExpressionOperatorUnsupported),
        ("cmd.requiredScope == RequiredScope.Unknown", AggregateExpressionLiteralInvalid),
        ("cmd.requiredScope == PipelineScope", AggregateExpressionRootUnknown),
        ("cmd.request == cmd.request", AggregateExpressionOperatorUnsupported)
      ]
      $ \(guardText, code) -> do
        service <- parseChecked (replaceGuard guardText source)
        codes service `shouldContain` [code]
  it "separates structural and nominal enums despite identical strings" $ do
    source <- fixture
    service <- parseChecked (replaceGuard "cmd.requiredScope == NominalScope.Pipeline" (T.replace "context mapped-structural-enum-equality" "context mapped-structural-enum-equality\nenum NominalScope { Pipeline=pipeline Diagnostic=diagnostic }" source))
    codes service `shouldContain` [AggregateGuardTypeMismatch]
  it "keeps declaration identity even when two enums share their Haskell owner" $ do
    source <- fixture
    let (_, enumAndRest) = T.breakOn "mapped structural enum RequiredScope" source
        (enumSource, _) = T.breakOn "mapped structural record Request" enumAndRest
        second sameOwner = T.replace "type=OtherScope" (if sameOwner then "type=RequiredScope" else "type=OtherScope") (T.replace "RequiredScope" "OtherScope" enumSource)
    forM_ [False, True] $ \sameOwner -> do
      service <- parseChecked (replaceGuard "cmd.requiredScope == cmd.otherScope" (T.replace "mapped structural record Request" (second sameOwner <> "mapped structural record Request") (T.replace "command Match {" "command Match { otherScope:OtherScope" source)))
      let spec = checkedSpec service
          owner = aggregate service
          transition = head owner.transitions
          Just syntax = transition.guard
      case resolveGuardExpr (expressionEnvironment spec owner transition) syntax of
        Left diagnostics -> map (.code) (NE.toList diagnostics) `shouldContain` [ScalarOperandTypeMismatch]
        Right _ -> expectationFailure "cross-declaration equality was accepted"
  it "retains mapped codecs, samples, initials and writes while rejecting other mapped shapes" $ do
    source <- fixture
    service <- parseChecked source
    let symbols = aggregateSymbols (checkedSpec service)
    case resolveAggregateType symbols noLoc CommandFieldUse (TRef "RequiredScope") of
      Right resolved@(AggregateStructuralEnum _) -> do
        case resolved of AggregateMapped key -> key `shouldBe` MappedKey "RequiredScope"; _ -> expectationFailure "lost mapped-value view"
        aggregateCapability EqualityGuardUse resolved `shouldBe` SolverVisible
        aggregateCapability OrderingGuardUse resolved `shouldBe` Unsupported
        aggregateCapability CommandFieldUse resolved `shouldBe` OpaqueOnly
      other -> expectationFailure (show other)
    forM_
      [ T.replace "mapped structural enum RequiredScope" "mapped structural union RequiredScope" . T.replace "wire string { PipelineScope as \"pipeline\" DiagnosticScope as \"diagnostic\" }" "wire tagged-object tag=\"tag\" contents=\"contents\" unknown-fields=reject { PipelineScope as \"pipeline\" DiagnosticScope as \"diagnostic\" }",
        T.replace "mapped structural enum RequiredScope" "mapped opaque RequiredScope" . T.replace "  wire string { PipelineScope as \"pipeline\" DiagnosticScope as \"diagnostic\" }" "  codec = \"scope.json\"\n  version = \"1\"" . T.replace "  binding = \"Conformance.MappedStructuralEnumEquality.Bindings.requiredScopeBinding\"\n" "" . T.replace "  binding-version = \"1\"\n" "" . T.replace "  canonical-type = \"conformance.RequiredScope.v1\"\n" ""
      ]
      $ \transform -> do
        other <- parseChecked (transform source)
        codes other `shouldContain` [AggregateExpressionOperatorUnsupported]
  it "rejects incomplete binding metadata statically" $ do
    source <- fixture
    incomplete <- parseChecked (T.replace "  binding = \"Conformance.MappedStructuralEnumEquality.Bindings.requiredScopeBinding\"\n" "" source)
    codes incomplete `shouldContain` [MappedMissingIngredient]
  it "emits finite root witnesses and exhaustive binding laws without fixture-selected reconstruction" $ do
    source <- fixture
    service <- parseChecked source
    let modules = scaffoldServiceModules (defaultContext "mapped-structural-enum-equality") service
        projections = moduleText "StructuralProjections.hs" modules
        conformance = moduleText "StructuralConformance.hs" modules
    projections `shouldSatisfy` T.isInfixOf "finiteProjectionDomain"
    projections `shouldSatisfy` T.isInfixOf "bindingFromShape"
    projections `shouldSatisfy` (not . T.isInfixOf "NonEmpty.head")
    conformance `shouldSatisfy` T.isInfixOf "exhaustive enum shape round-trip"
    conformance `shouldSatisfy` T.isInfixOf "checkFieldProjectionOwner"
    conformance `shouldSatisfy` T.isInfixOf "checkFieldProjectionKey"
  it "records a distinct equality row and explains its total binding obligation" $ do
    source <- fixture
    service <- parseChecked source
    let identities = structuralEnumEqualityIdentitiesForService service
    identities `shouldSatisfy` (not . null)
    case bindingObligationsForService service of
      Left failure -> expectationFailure (show failure)
      Right obligations -> do
        let contracts = [identity | obligation <- obligations, Just identity <- [obligation.equalityContract]]
        contracts `shouldSatisfy` (not . null)
        contracts `shouldSatisfy` all (`elem` identities)
    contents <- TIO.readFile "test/conformance-mapped-structural-enum-equality/keiro-dsl-ledger.context.mapped-structural-enum-equality.txt"
    case parseRecord contents of
      Nothing -> expectationFailure "scaffold record did not parse"
      Just record -> do
        let updated = record {structuralEnumEqualities = identities}
        parseRecord (renderRecord updated) `shouldBe` Just updated
        parseRecord (renderRecord updated <> "structural-enum-equality " <> NE.head (NE.fromList identities) <> "\n") `shouldBe` Nothing
        renderRecord updated `shouldSatisfy` T.isInfixOf "structural-enum-equality keiro-dsl/structural-enum-equality/1:"
    workspaceContents <- TIO.readFile "test/conformance-workspace-nominals/keiro-dsl-ledger.workspace.workspace-nominal-proof.txt"
    case WR.parseWorkspaceRecord workspaceContents of
      Nothing -> expectationFailure "workspace ledger did not parse"
      Just record -> do
        let updated = record {WR.structuralEnumEqualities = identities}
        WR.parseWorkspaceRecord (WR.renderWorkspaceRecord updated) `shouldBe` Just updated
  it "scopes fold identity to equality use and keeps fixture names and order out of it" $ do
    source <- fixture
    service <- parseChecked source
    let fingerprint value = either (error . show) id (aggregateFoldFingerprintForService value (aggregate value))
        surface value = either (error . show) id (aggregateFoldSurfaceForService value (aggregate value))
    surface service `shouldSatisfy` T.isInfixOf "structural-enum-equality-use:keiro-dsl/structural-enum-equality/1:"
    forM_ [T.replace "Bindings.requiredScopeFixtures" "Bindings.changedFixtures", T.replace "PipelineScope as \"pipeline\" DiagnosticScope as \"diagnostic\"" "DiagnosticScope as \"diagnostic\" PipelineScope as \"pipeline\""] $ \transform -> do
      same <- parseChecked (transform source)
      fingerprint same `shouldBe` fingerprint service
      replayImpactServices service same `shouldBe` Right ReplayNeutral
    forM_ [T.replace "binding-version = \"1\"" "binding-version = \"2\"", T.replace "\"pipeline\"" "\"pipeline-v2\"", replaceGuard "cmd.requiredScope != reg.requiredScope", T.replace "Bindings.requiredScopeBinding" "Bindings.changedBinding", T.replace "conformance.RequiredScope.v1" "conformance.RequiredScope.v2"] $ \transform -> do
      changed <- parseChecked (transform source)
      fingerprint changed `shouldNotBe` fingerprint service
      replayImpactServices service changed `shouldSatisfy` (/= Right ReplayNeutral)
      Diff.diffServices service changed `shouldSatisfy` either (const False) (not . null)
    noEquality <- parseChecked (stripGuards source)
    surface noEquality `shouldSatisfy` (not . T.isInfixOf "structural-enum-equality-use:")
    oldLanguage <- parseChecked (T.replace "language keiro-dsl 6" "language keiro-dsl 5" (stripGuards source))
    errors oldLanguage `shouldBe` []
    fingerprint noEquality `shouldBe` fingerprint oldLanguage
    surface noEquality `shouldBe` surface oldLanguage
    noGuardDiff <- pure (Diff.diffServices noEquality service)
    noGuardDiff `shouldSatisfy` either (const False) (not . null)
    replayImpactServices noEquality service `shouldSatisfy` (/= Right ReplayNeutral)

  it "compares each supported-history revision against its own graph and preserves unrelated controls" $ do
    let load name = TIO.readFile ("test/fixtures/mapped-structural-enum-equality-history/" <> name <> ".keiro") >>= parseChecked
        fingerprints service = [(owner.name, either (error . show) id (aggregateFoldFingerprintForService service owner)) | NAggregate owner <- (checkedSpec service).nodes]
    old <- load "guarded"
    forM_ [("data-only", False), ("binding-v2", False), ("wire-v2", False), ("fixture-only", True), ("reordered", True)] $ \(name, neutral) -> do
      new <- load name
      errors new `shouldBe` []
      lookup "ScopeControl" (fingerprints new) `shouldBe` lookup "ScopeControl" (fingerprints old)
      (lookup "ScopeGate" (fingerprints new) == lookup "ScopeGate" (fingerprints old)) `shouldBe` neutral
      result <- either (\failure -> expectationFailure (show failure) >> fail "replay comparison failed") pure (replayImpactServices old new)
      (result == ReplayNeutral) `shouldBe` neutral
    dataOnly <- load "data-only"
    let surface = either (error . show) id (aggregateFoldSurfaceForService dataOnly (aggregate dataOnly))
        fingerprint = either (error . show) id (aggregateFoldFingerprintForService dataOnly (aggregate dataOnly))
    expected <- TIO.readFile "test/fixtures/mapped-structural-enum-data-only-fold.golden"
    fingerprint <> "\n" <> surface <> "\n" `shouldBe` expected
  it "samples literal-guarded commands by projected wire key instead of fixture order" $ do
    source <- fixture
    let harnessFor checked = do
          errors checked `shouldBe` []
          let modules = scaffoldServiceModules (defaultContext "mapped-structural-enum-equality") checked
          firewallBreaches modules `shouldBe` []
          pure (moduleText "ScopeGate/Harness.hs" modules)
        sampled filters = "(case [value | (_, value) <- NonEmpty.toList (fixtureCases Bindings.requiredScopeFixtures), " <> filters <> "] of value : _ -> value; [] -> error \"enum guard requires a matching supplied fixture\")"
    harness <- parseChecked source >>= harnessFor
    harness `shouldSatisfy` T.isInfixOf "import Generated.MappedStructuralEnumEquality.StructuralProjections qualified as StructuralProjections"
    harness `shouldSatisfy` T.isInfixOf "(Match (MatchData Bindings.initialScope "
    harness `shouldSatisfy` T.isInfixOf ("(Differ (DifferData " <> sampled "value /= Bindings.initialScope")
    harness `shouldSatisfy` T.isInfixOf ("(EqRight (EqRightData " <> sampled "fieldWitnessGet StructuralProjections.requiredScopeWitness value == \"pipeline\"")
    harness `shouldSatisfy` T.isInfixOf ("(EqLeft (EqLeftData " <> sampled "fieldWitnessGet StructuralProjections.requiredScopeWitness value == \"pipeline\"")
    harness `shouldSatisfy` T.isInfixOf ("(NeRight (NeRightData " <> sampled "fieldWitnessGet StructuralProjections.requiredScopeWitness value /= \"diagnostic\"")
    harness `shouldSatisfy` T.isInfixOf ("(NeLeft (NeLeftData " <> sampled "fieldWitnessGet StructuralProjections.requiredScopeWitness value /= \"diagnostic\"")
    combined <- parseChecked (replaceGuard "cmd.requiredScope != reg.requiredScope && cmd.requiredScope != RequiredScope.DiagnosticScope" source) >>= harnessFor
    combined `shouldSatisfy` T.isInfixOf ("(Match (MatchData " <> sampled "value /= Bindings.initialScope, fieldWitnessGet StructuralProjections.requiredScopeWitness value /= \"diagnostic\"")
    alternative <- parseChecked (replaceGuard "cmd.requiredScope == RequiredScope.DiagnosticScope || cmd.requiredScope == RequiredScope.PipelineScope" source) >>= harnessFor
    alternative `shouldSatisfy` T.isInfixOf ("(Match (MatchData " <> sampled "fieldWitnessGet StructuralProjections.requiredScopeWitness value == \"diagnostic\"")
    unguarded <- parseChecked (stripGuards source) >>= harnessFor
    unguarded `shouldSatisfy` (not . T.isInfixOf "StructuralProjections")
    unguarded `shouldSatisfy` (not . T.isInfixOf "fieldWitnessGet")

fixture :: IO Text
fixture = TIO.readFile "test/fixtures/mapped-structural-enum-equality.keiro"

parseChecked :: Text -> IO CheckedService
parseChecked source = case parseSource "mapped-structural-enum-equality.keiro" source of
  Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "parse failed"
  Right parsed -> pure (checkedSource parsed)

aggregate :: CheckedService -> Aggregate
aggregate service = head [value | NAggregate value <- (checkedSpec service).nodes]

errors :: CheckedService -> [Diagnostic]
errors = filter ((== Error) . (.severity)) . validateService

codes :: CheckedService -> [DiagnosticCode]
codes = map (.code) . errors

replaceGuard :: Text -> Text -> Text
replaceGuard = T.replace "cmd.requiredScope == reg.requiredScope"

stripGuards :: Text -> Text
stripGuards = T.replace "write requiredScope := RequiredScope.PipelineScope" "write requiredScope := cmd.requiredScope" . T.unlines . filter (not . T.isPrefixOf "    guard ") . T.lines

moduleText :: Text -> [ScaffoldModule] -> Text
moduleText suffix modules = T.unlines [value.text | value <- modules, suffix `T.isSuffixOf` T.pack value.path]
