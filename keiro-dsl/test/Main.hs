{- | Test driver for keiro-dsl. EP-1 milestone 1 tests: the @parse . pretty@
round-trip property over generated specs, and a unit test pinning the shape
of the canonical Reservation fixture.
-}
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (filterM, forM_)
import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft)
import Data.List (partition, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Codec (Codec (..), EventType (..), decodeRaw)
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), FamilyDiff (..), NodeFamily, diffSpecs, familyRegistry, isAdvisory, isBreaking)
import Keiro.Dsl.FoldFingerprint (aggregateFoldFingerprint, aggregateFoldSurface)
import Keiro.Dsl.Goldens (GoldenPayload (..), goldenRelativePath, goldensForDiff)
import Keiro.Dsl.Grammar
import Keiro.Dsl.Harness (harnessFor, harnessForWithGoldens, harnessReadModel, harnessRouter, harnessWorkflow)
import Keiro.Dsl.Manifest (manifestDependencies, moduleNameOf, renderManifest)
import Keiro.Dsl.Parser (parseSpec)
import Keiro.Dsl.PrettyPrint (renderSpec, renderTransition)
import Keiro.Dsl.ReadModelShape (canonicalShape, deriveShapeHash, registryNameFor, subscriptionNameFor)
import Keiro.Dsl.Scaffold (Context (..), ModuleKind (..), ScaffoldModule (..), defaultContext, firewallBreaches, genPrefixFor, holePrefixFor, scaffoldAggregate, scaffoldIntake, scaffoldProcess, scaffoldPublisher, scaffoldReadModel, scaffoldRefusals, scaffoldRouter, scaffoldWorkqueue, windowSeconds)
import Keiro.Dsl.ScaffoldRecord (ScaffoldRecord (..), parseRecord, recordFileName)
import Keiro.Dsl.ScaffoldRun (Refusal (..), ScaffoldReport (..), StaleModule (..), executeScaffold, planScaffold, renderScaffoldReport, scaffoldModules)
import Keiro.Dsl.Skeleton (skeletonFor, skeletonKinds)
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode (..), Severity (..), derivedQueueTrio, validateSpec)
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, getTemporaryDirectory, removeFile, removePathForcibly)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, openTempFile)
import Test.Hspec hiding (Spec)
import Test.QuickCheck

main :: IO ()
main = hspec $ do
    describe "parse . pretty round-trip" $
        do
            it "re-parses any generated spec to an equal AST (modulo source locations)" $
                checkCoverage $
                    forAll genSpec $ \s ->
                        let families = map nodeTag (specNodes s)
                            roundTrip = parseSpec "<gen>" (renderSpec s) === Right s
                         in foldr (\family -> cover 1 (family `elem` families) family) roundTrip allNodeTags
            it "round-trips an aggregate with no states" $
                parseSpec "<empty-states>" (renderSpec emptyStatesSpec) `shouldBe` Right emptyStatesSpec
            it "separates transition emit clauses from following nodes" $ do
                spec <- parseInlineSpec "<cross-family-boundaries>" crossFamilyBoundarySpec
                case specNodes spec of
                    [NAggregate first, NEmit _, NAggregate second, NPgmqDispatch _] -> do
                        concatMap tEmits (aggTransitions first) `shouldBe` ["Changed"]
                        aggStates second `shouldBe` []
                    nodes -> expectationFailure ("unexpected node sequence: " <> show (map nodeTag nodes))

    describe "string literal integrity" $ do
        it "parses an escaped emit-map value as exactly one row" $ do
            let src =
                    T.unlines
                        [ "context svc"
                        , ""
                        , "emit e {"
                        , "  contract c"
                        , "  topic events"
                        , "  source \"svc\""
                        , "  key thingId"
                        , "  map status {"
                        , "    \"a\\\" => Wat \\\"b\" => ThingAccepted"
                        , "    _ => skip"
                        , "  }"
                        , "  messageId derive hole"
                        , "  idempotencyKey derive hole"
                        , "}"
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
            spec <- parseInlineSpec "<retiring-without-emitter>" (T.replace " ; emit TransferReservationConfirmed" "" source)
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
                [ DuplicateNodeName
                , DuplicateEnumCtor
                , DuplicateEnumWire
                , DuplicateIdPrefix
                , DuplicateCommandName
                , DuplicateEventName
                ]
        it "rejects aggregate-local references that do not resolve" $ do
            codes <- errorCodesOf "test/fixtures/aggregate-bad-refs.keiro"
            codes `shouldContain` [RegisterInitialOutOfScope, UndeclaredCommand, WriteTargetNotRegister]
        it "anchors UnreachableState on the state row" $ do
            let src =
                    T.unlines
                        [ "context repro"
                        , ""
                        , "aggregate Thing"
                        , "  regs"
                        , "  states"
                        , "    Initial"
                        , "    Unreachable"
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
                                [ "    guard " <> renderExprText (complementExpr e)
                                , "    emit  TransferReservationCreated"
                                , "    goto  Held"
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
            parseSpec "<retiring-round-trip>" (renderSpec spec) `shouldBe` Right spec
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
            parseSpec "<snapshot-round-trip>" (renderSpec spec) `shouldBe` Right spec
            case [aggregate | NAggregate aggregate <- specNodes spec] of
                [aggregate] -> aggSnapshot aggregate `shouldBe` Just (SnapshotSpec (SnapEvery 100) 1 "7eb3a94f62f947231375d44083e2a1c8029d91ffe0329107d55092ed3430efcc" noLoc)
                aggregates -> expectationFailure ("expected one snapshot aggregate, got " <> show (length aggregates))
        it "rejects disabled intervals and invalid codec fixtures" $ do
            source <- readTestText "test/fixtures/reservation-snapshot.keiro"
            interval <- parseInlineSpec "<snapshot-zero>" (T.replace "snapshot every 100" "snapshot every 0" source)
            map code (validateSpec interval) `shouldContain` [SnapshotIntervalInvalid]
            version <- parseInlineSpec "<snapshot-version-zero>" (T.replace "state-codec version=1" "state-codec version=0" source)
            map code (validateSpec version) `shouldContain` [SnapshotCodecFixtureInvalid]
            emptyHash <- parseInlineSpec "<snapshot-empty-hash>" (T.replace "shape-hash=\"7eb3a94f62f947231375d44083e2a1c8029d91ffe0329107d55092ed3430efcc\"" "shape-hash=\"\"" source)
            map code (validateSpec emptyHash) `shouldContain` [SnapshotCodecFixtureInvalid]
        it "conditionally lowers JSON instances and the live defaultStateCodec" $ do
            snapshot <- specOf "test/fixtures/reservation-snapshot.keiro"
            ordinary <- specOf "test/fixtures/reservation.keiro"
            case ([aggregate | NAggregate aggregate <- specNodes snapshot], [aggregate | NAggregate aggregate <- specNodes ordinary]) of
                ([snapshotAggregate], [ordinaryAggregate]) -> do
                    let snapshotModules = scaffoldAggregate (defaultContext (specContext snapshot)) snapshot snapshotAggregate
                        ordinaryModules = scaffoldAggregate (defaultContext (specContext ordinary)) ordinary ordinaryAggregate
                        snapshotDomain = generatedTextEndingIn "Domain.hs" snapshotModules
                        snapshotStream = generatedTextEndingIn "EventStream.hs" snapshotModules
                        ordinaryDomain = generatedTextEndingIn "Domain.hs" ordinaryModules
                        ordinaryStream = generatedTextEndingIn "EventStream.hs" ordinaryModules
                    snapshotDomain `shouldSatisfy` T.isInfixOf "deriving anyclass (ToJSON, FromJSON)"
                    snapshotStream `shouldSatisfy` T.isInfixOf "snapshotPolicy = Every 100"
                    snapshotStream `shouldSatisfy` T.isInfixOf "stateCodec = Just (withFoldFingerprint"
                    snapshotStream `shouldSatisfy` T.isInfixOf "Spec-visible fold changes invalidate old"
                    snapshotStream `shouldSatisfy` T.isInfixOf "module are invisible here"
                    snapshotStream `shouldSatisfy` T.isInfixOf "reservationSnapshotFixture = (1, \"7eb3a94f62f947231375d44083e2a1c8029d91ffe0329107d55092ed3430efcc\")"
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
            second <- parseInlineSpec "<second>" ("\n\n" <> renderSpec first <> "\n")
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
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
        it "accepts the hospital-surge spec (no errors; benign-inversion warnings only)" $ do
            codes <- errorCodesOf "test/fixtures/hospital-surge.keiro"
            codes `shouldBe` []
        it "rejects illegal saga categories and no longer parses the raw stream-prefix clause" $ do
            spec <- specOf "test/fixtures/hospital-surge.keiro"
            mapM_
                (\categoryName -> processErrorCodes (\process -> process{procSaga = (procSaga process){sagaCategory = categoryName}}) spec `shouldContain` [SagaCategoryIllegal])
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
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
        it "accepts the incident-paging router with warnings only" $ do
            codes <- errorCodesOf "test/fixtures/incident-paging/incident-paging.keiro"
            codes `shouldBe` []
            diagnostics <- diagnosticCodesOf "test/fixtures/incident-paging/incident-paging.keiro"
            diagnostics `shouldContain` [PolicyDeadLetterUnused, AmbiguousFollowsRejectedPolicy]
        it "rejects unresolved targets, keys, commands, and binding scopes" $ do
            spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
            routerErrorCodes (\router -> router{rtTarget = "Pge"}) spec `shouldContain` [RouterUnresolvedRef]
            routerErrorCodes (\router -> router{rtKey = (rtKey router){corrField = "incidntId"}}) spec `shouldContain` [RouterKeyFieldUnknown]
            routerErrorCodes (\router -> router{rtDispatch = (rtDispatch router){rdCommand = "SendPag"}}) spec `shouldContain` [RouterCommandUnknown]
            routerErrorCodes
                ( \router ->
                    let dispatch = rtDispatch router
                     in router{rtDispatch = dispatch{rdFields = [FieldBinding "responderId" (Just "resolved.responder")]}}
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
                            { rtRejected = PolHalt
                            , rtDispatch = dispatch{rdDisposition = disposition{onFailed = DDeadLetter "page rejected"}}
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
                                     in NProcess process{procTimer = timer{tmFire = fire{fireDisposition = disposition{onAmbiguous = OFired}}}}
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
                        generatedFor choice = [moduleText m | m <- scaffoldRouter ctx router{rtPoison = choice}, kind m == Generated]
                    mapM_
                        ( \(choice, constructor) -> case generatedFor choice of
                            [generatedModule] -> do
                                generatedModule `shouldSatisfy` T.isInfixOf "(Envelope msg -> Eff es ()) -> WorkerOptions es msg"
                                generatedModule `shouldSatisfy` T.isInfixOf (constructor <> " poisonCallback")
                            _ -> expectationFailure "expected one generated router module"
                        )
                        [(PolDeadLetter, "PoisonDeadLetter"), (PolSkip, "PoisonSkip")]
                    case [moduleText m | m <- scaffoldRouter ctx router{rtRejected = PolSkip}, kind m == Generated] of
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
            mods <- scaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
            let gens = [m | m <- mods, kind m == Generated]
                holes = [m | m <- mods, kind m == HoleStub]
            length holes `shouldBe` 1
            firewallBreaches gens `shouldBe` []
            case gens of
                [generatedModule] -> do
                    -- the worker uses the spec's ceiling, never the dangerous default
                    moduleText generatedModule `shouldSatisfy` T.isInfixOf "max-attempts = 5"
                    moduleText generatedModule `shouldSatisfy` T.isInfixOf "hospitalSurgeProcessWorkerOptions"
                    moduleText generatedModule `shouldSatisfy` T.isInfixOf "hospitalSurgeCategory = Stream.categoryUnsafe \"hospitalSurge\""
                    moduleText generatedModule `shouldSatisfy` T.isInfixOf "confirmBenignDuplicate"
                    moduleText generatedModule `shouldSatisfy` T.isInfixOf "StreamName -> EventId -> CommandError -> Eff es Bool"
                    moduleText generatedModule `shouldSatisfy` T.isInfixOf "Left (CommandAmbiguous _)"
                    case holes of
                        [holeModule] -> moduleText holeModule `shouldSatisfy` T.isInfixOf "entityStream hospitalSurgeCategory"
                        _ -> expectationFailure "expected one process hole module"
                _ -> expectationFailure "expected one generated process module"
        it "process scaffold is deterministic" $ do
            a <- scaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
            b <- scaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
            map moduleText a `shouldBe` map moduleText b

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
            map line duplicateDiagnostics `shouldBe` [17]
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
                `shouldBe` ( "hospital_capacity_reservat_757040df00976c33"
                           , "hospital_capacity_reservat_757040df00976c33_dlq"
                           , "pgmq.q_hospital_capacity_reservat_757040df00976c33"
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
                    firewallBreaches modules `shouldBe` []
                [] -> expectationFailure "reservation-work fixture has no workqueue"

    describe "readmodel (EP-107)" $ do
        it "parses and round-trips first-class read models" $ do
            spec <- specOf "test/fixtures/readmodel.keiro"
            case [readModel | NReadModel readModel <- specNodes spec] of
                [subscriptionModel, inlineModel] -> do
                    rmName subscriptionModel `shouldBe` "transfer_decisions"
                    rmColumns subscriptionModel
                        `shouldBe` [ RmColumn "reservation_id" "text" True
                                   , RmColumn "hospital_id" "text" True
                                   , RmColumn "status" "text" True
                                   , RmColumn "decided_at" "timestamptz" False
                                   ]
                    rmScope subscriptionModel `shouldBe` Just (RmCategory "reservation")
                    rmFeed subscriptionModel `shouldBe` RmSubscription
                    rmSubscription subscriptionModel `shouldBe` Just "hospital-capacity-transfer-decisions-sub"
                    rmName inlineModel `shouldBe` "subscriptions"
                    rmScope inlineModel `shouldBe` Nothing
                    rmFeed inlineModel `shouldBe` RmInline
                nodes -> expectationFailure ("expected two readmodel nodes, got " <> show (length nodes))
            parseSpec "in" (renderSpec spec) `shouldBe` Right spec
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
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
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
                    facts `shouldSatisfy` T.isInfixOf "(\"patches\", \"fraud-check-v2\")"
                    runtime `shouldSatisfy` T.isInfixOf "declaredPatches = Set.fromList [PatchId \"fraud-check-v2\"]"
                    runtime `shouldSatisfy` T.isInfixOf "opts{activePatches = declaredPatches}"
                workflows -> expectationFailure ("expected one workflow, got " <> show (length workflows))

    describe "diff (evolution classification)" $ do
        it "covers every node family exactly once and explains exclusions" $ do
            sort (map fst familyRegistry) `shouldBe` ([minBound .. maxBound] :: [NodeFamily])
            [reason | (_, OutOfDiffScope reason) <- familyRegistry, T.null reason] `shouldBe` []
        it "classifies a field added without a version bump as BREAKING" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-fieldadd.keiro"
            any isBreaking cs `shouldBe` True
            [ckCode k | Breaking k <- cs] `shouldContain` [Just EvtFieldAddedWithoutBump]
        it "classifies the same field wrapped as v2 + upcaster as ADDITIVE" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-v2.keiro"
            any isBreaking cs `shouldBe` False
            [ck | Additive ck <- cs] `shouldSatisfy` any ((== "TransferReservationCreated") . ckSubject)
        it "reports no breaking change when the spec is unchanged" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation.keiro"
            any isBreaking cs `shouldBe` False
        it "classifies a direct event field type change as EvtFieldTypeChanged" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-fieldtype.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just EvtFieldTypeChanged]
        it "resolves fields(Command) before comparing event field types" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-cmdfieldtype.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just EvtFieldTypeChanged]
        it "uses EvtFieldRemovedSameVersion for an unchanged-version removal" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-fieldremove.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just EvtFieldRemovedSameVersion]
        it "uses EvtVersionDecreased for a version decrease" $ do
            cs <- diffFixtures "test/fixtures/reservation-v2.keiro" "test/fixtures/reservation.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just EvtVersionDecreased]
        it "rejects a v1 to v3 jump whose only upcaster starts at v2" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-v3-dangling.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just EvtVersionMissingUpcaster]
        it "classifies a vanished historical upcaster rung as UpcasterChainGap" $ do
            cs <- diffFixtures "test/fixtures/reservation-v2.keiro" "test/fixtures/reservation-chain-gap.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just UpcasterChainGap]
        it "classifies an enum constructor removal as EnumCtorRemoved" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-enumdrop.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just EnumCtorRemoved]
        it "classifies an enum wire-spelling change as EnumWireSpellingChanged" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-enumwire.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just EnumWireSpellingChanged]
        it "classifies an enum constructor addition as additive" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-enumadd.keiro"
            any isBreaking cs `shouldBe` False
            [ckSubject k | Additive k <- cs] `shouldContain` ["BlackTag"]
        it "classifies an effective wire convention change as WireSpecChanged" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-wire.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just WireSpecChanged]
        it "advises when the aggregate fold surface changes" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-foldchange.keiro"
            any isBreaking cs `shouldBe` False
            [ckCode k | Advisory k <- cs] `shouldContain` [Just AggFoldSurfaceChanged]
        it "advises on hazardous deprecation and reports un-deprecation" $ do
            deprecated <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-deprecated.keiro"
            any isBreaking deprecated `shouldBe` False
            [ckCode k | Advisory k <- deprecated] `shouldContain` [Just DeprecatedEventReplayHazard]
            restored <- diffFixtures "test/fixtures/reservation-deprecated.keiro" "test/fixtures/reservation.keiro"
            any isAdvisory restored `shouldBe` True
            [ckCode k | Advisory k <- restored] `shouldContain` [Just EventUndeprecated]
        it "recognises replay-only deprecation as a replay-safe retirement cutover" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-deprecated-replay-only.keiro"
            any isBreaking cs `shouldBe` False
            [ckCode k | Advisory k <- cs] `shouldContain` [Just EventRetirementInProgress]
            [ckCode k | Advisory k <- cs] `shouldNotContain` [Just DeprecatedEventReplayHazard]
        it "advises when event retirement starts" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-retiring.keiro"
            any isBreaking cs `shouldBe` False
            [ckCode k | Advisory k <- cs] `shouldContain` [Just EventRetirementInProgress]
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
                                                | event <- aggEvents aggregate
                                                , evName event /= "TransferReservationConfirmed"
                                                ]
                                            }
                                _ -> node
                            | node <- specNodes old
                            ]
                        }
                removals = [change | change@(Breaking kind) <- diffSpecs old new, ckCode kind == Just EvtRemovedNotDeprecated]
            removals `shouldSatisfy` (not . null)
            [ckDetail kind | Breaking kind <- removals]
                `shouldSatisfy` all (not . T.isInfixOf "so old payloads still decode")
        it "prints a paste-ready replay-only twin when a guard tightens (plan 143)" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-guard-tightened.keiro"
            any isBreaking cs `shouldBe` False
            let advisories = [k | Advisory k <- cs, ckCode k == Just AggGuardTightened]
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
                    [k | Advisory k <- diffSpecs base pastedSpec, ckCode k == Just AggGuardTightened]
                        `shouldBe` []
        it "omits the twin advisory when the twin is already present (plan 143)" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-guard-tightened-twin.keiro"
            [k | Advisory k <- cs, ckCode k == Just AggGuardTightened] `shouldBe` []
        it "classifies a removed contract event as ContractEventRemoved" $ do
            cs <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-eventdrop.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just ContractEventRemoved]
        it "classifies contract field type changes and unversioned additions as ContractFieldChanged" $ do
            changed <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-fieldtype.keiro"
            [ckCode k | Breaking k <- changed] `shouldContain` [Just ContractFieldChanged]
            added <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-fieldadd.keiro"
            [ckCode k | Breaking k <- added] `shouldContain` [Just ContractFieldChanged]
        it "reports a field addition with a contract version bump as an advisory" $ do
            cs <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-bump-fieldadd.keiro"
            any isBreaking cs `shouldBe` False
            [ckCode k | Advisory k <- cs] `shouldContain` [Just ContractSchemaVersionBumped]
        it "classifies a contract schema version decrease separately" $ do
            cs <- diffFixtures "test/fixtures/contract-bump-fieldadd.keiro" "test/fixtures/contract.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just ContractSchemaVersionDecreased]
        it "classifies contract topic and discriminator changes separately" $ do
            topic <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-topic.keiro"
            [ckCode k | Breaking k <- topic] `shouldContain` [Just ContractTopicChanged]
            discriminator <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-discriminator.keiro"
            [ckCode k | Breaking k <- discriminator] `shouldContain` [Just ContractDiscriminatorChanged]
        it "classifies a new contract event as additive" $ do
            cs <- diffFixtures "test/fixtures/contract.keiro" "test/fixtures/contract-eventadd.keiro"
            any isBreaking cs `shouldBe` False
            [ckSubject k | Additive k <- cs] `shouldContain` ["IncidentTransferNeedCancelled"]
        it "classifies workqueue wire names, types, and required additions as WqPayloadFieldChanged" $ do
            wire <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-wirename.keiro"
            [ckCode k | Breaking k <- wire] `shouldContain` [Just WqPayloadFieldChanged]
            fieldTypeChange <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-fieldtype.keiro"
            [ckCode k | Breaking k <- fieldTypeChange] `shouldContain` [Just WqPayloadFieldChanged]
            required <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-reqfield.keiro"
            [ckCode k | Breaking k <- required] `shouldContain` [Just WqPayloadFieldChanged]
        it "classifies a new optional workqueue payload field as additive" $ do
            cs <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-optfield.keiro"
            any isBreaking cs `shouldBe` False
            [ckSubject k | Additive k <- cs] `shouldContain` ["note"]
        it "classifies workqueue ordering changes as breaking delivery-contract changes" $ do
            cs <- diffFixtures "test/fixtures/workqueue-policy-base.keiro" "test/fixtures/workqueue-ordering-change.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just WqOrderingChanged]
            [ckDetail k | Breaking k <- cs, ckCode k == Just WqOrderingChanged]
                `shouldSatisfy` any (T.isInfixOf "delivery-order contract")
        it "classifies workqueue provision changes as operational migrations" $ do
            cs <- diffFixtures "test/fixtures/workqueue-policy-base.keiro" "test/fixtures/workqueue-provision-change.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just WqProvisionChanged]
            [ckDetail k | Breaking k <- cs, ckCode k == Just WqProvisionChanged]
                `shouldSatisfy` any (T.isInfixOf "migrate the existing queue operationally")
        it "classifies workqueue group-key changes as breaking repartitioning" $ do
            cs <- diffFixtures "test/fixtures/workqueue-policy-base.keiro" "test/fixtures/workqueue-group-key-change.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just WqGroupKeyChanged]
            [ckDetail k | Breaking k <- cs, ckCode k == Just WqGroupKeyChanged]
                `shouldSatisfy` any (T.isInfixOf "re-partitioned")
        it "classifies a process input type change as ProcessInputChanged" $ do
            cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-inputtype.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just ProcessInputChanged]
        it "classifies workflow input and output changes as WorkflowShapeChanged" $ do
            input <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-inputfield.keiro"
            [ckCode k | Breaking k <- input] `shouldContain` [Just WorkflowShapeChanged]
            output <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-output.keiro"
            [ckCode k | Breaking k <- output] `shouldContain` [Just WorkflowShapeChanged]
        it "classifies workflow relabeling and appends as WorkflowBodyChanged" $ do
            relabeled <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-body.keiro"
            [ckCode k | Breaking k <- relabeled] `shouldContain` [Just WorkflowBodyChanged]
            appended <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-stepadd.keiro"
            [ckCode k | Breaking k <- appended] `shouldContain` [Just WorkflowBodyChanged]
            [ckDetail k | Breaking k <- appended, ckCode k == Just WorkflowBodyChanged]
                `shouldSatisfy` any (T.isInfixOf "new patch guard")
        it "classifies a body addition wholly guarded by a new patch as additive" $ do
            cs <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-evolution-diff.keiro"
            any isBreaking cs `shouldBe` False
            [ckSubject k | Additive k <- cs, ckFacet k == "workflow-patch"] `shouldContain` ["fraud-check-v2"]
            [ckSubject k | Additive k <- cs, ckFacet k == "workflow-continue-as-new"] `shouldContain` ["RolloverSeed"]
        it "classifies removing an existing patch as breaking" $ do
            cs <- diffFixtures "test/fixtures/workflow-evolution-diff.keiro" "test/fixtures/workflow-continue.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just WorkflowPatchRemoved]
            [ckDetail k | Breaking k <- cs, ckCode k == Just WorkflowPatchRemoved]
                `shouldSatisfy` any (T.isInfixOf "cannot prove")
        it "classifies terminal continueAsNew append as additive and seed drift as breaking" $ do
            appended <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-continue.keiro"
            any isBreaking appended `shouldBe` False
            [ckFacet k | Additive k <- appended] `shouldContain` ["workflow-continue-as-new"]
            changed <- diffFixtures "test/fixtures/workflow-continue.keiro" "test/fixtures/workflow-continue-seed-v2.keiro"
            [ckCode k | Breaking k <- changed] `shouldContain` [Just WorkflowContinueSeedChanged]
            [ckDetail k | Breaking k <- changed, ckCode k == Just WorkflowContinueSeedChanged]
                `shouldSatisfy` any (T.isInfixOf "restoreSeed")
        it "classifies a workflow stable-name change as WorkflowStableNameChanged" $ do
            cs <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-rename.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just WorkflowStableNameChanged]
        it "classifies workflow id-derivation changes as DerivedIdentityChanged" $ do
            cs <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-idfield.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just DerivedIdentityChanged]
        it "classifies an id prefix change as IdPrefixChanged" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-idprefix.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just IdPrefixChanged]
        it "classifies intake dedupe key and policy changes as DedupeIdentityChanged" $ do
            policy <- diffFixtures "test/fixtures/intake.keiro" "test/fixtures/intake-dedupepolicy.keiro"
            [ckCode k | Breaking k <- policy] `shouldContain` [Just DedupeIdentityChanged]
            key <- diffFixtures "test/fixtures/intake.keiro" "test/fixtures/intake-dedupekey.keiro"
            [ckCode k | Breaking k <- key] `shouldContain` [Just DedupeIdentityChanged]
        it "reports intake decode-posture changes as warnings" $ do
            cs <- diffFixtures "test/fixtures/intake.keiro" "test/fixtures/intake-decode.keiro"
            any isBreaking cs `shouldBe` False
            [ckCode k | Advisory k <- cs] `shouldContain` [Just DecodePostureChanged]
            [ckCode k | Advisory k <- cs] `shouldContain` [Just IntakePersistenceChanged]
        it "classifies process and timer derivation changes as DerivedIdentityChanged" $ do
            processName <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-procname.keiro"
            [ckCode k | Breaking k <- processName] `shouldContain` [Just DerivedIdentityChanged]
            timerId <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-timerid.keiro"
            [ckCode k | Breaking k <- timerId] `shouldContain` [Just DerivedIdentityChanged]
            base <- specOf "test/fixtures/hospital-surge.keiro"
            let categoryChange = diffSpecs base (modifyProcess "HospitalSurge" (\process -> process{procSaga = (procSaga process){sagaCategory = "hospitalSurgeV2"}}) base)
            [ckCode k | Breaking k <- categoryChange] `shouldContain` [Just DerivedIdentityChanged]
        it "classifies router stable names, keys, and targets as identity-bearing" $ do
            base <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
            let stableName = diffSpecs base (modifyRouter "PagingRouter" (\router -> router{rtName = "paging-v2"}) base)
                keyDerivation = diffSpecs base (modifyRouter "PagingRouter" (\router -> router{rtKey = (rtKey router){corrVia = "otherIdText"}}) base)
                target = diffSpecs base (modifyRouter "PagingRouter" (\router -> router{rtTarget = "OtherPage"}) base)
            [ckCode k | Breaking k <- stableName] `shouldContain` [Just RouterStableNameChanged]
            [ckCode k | Breaking k <- keyDerivation] `shouldContain` [Just DerivedIdentityChanged]
            [ckCode k | Breaking k <- target] `shouldContain` [Just DerivedIdentityChanged]
        it "reports a timer window change as a warning" $ do
            cs <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-window.keiro"
            any isBreaking cs `shouldBe` False
            [ckCode k | Advisory k <- cs] `shouldContain` [Just TimerWindowChanged]
        it "reports emit-map changes as warnings and derive changes as breaking" $ do
            mapping <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-mapchange.keiro"
            any isBreaking mapping `shouldBe` False
            [ckCode k | Advisory k <- mapping] `shouldContain` [Just EmitMappingChanged]
            derive <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-derive.keiro"
            [ckCode k | Breaking k <- derive] `shouldContain` [Just DerivedIdentityChanged]
        it "classifies publisher outbox identity and ordering independently" $ do
            outbox <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-outboxfield.keiro"
            [ckCode k | Breaking k <- outbox] `shouldContain` [Just DerivedIdentityChanged]
            ordering <- diffFixtures "test/fixtures/emit.keiro" "test/fixtures/emit-ordering.keiro"
            any isBreaking ordering `shouldBe` False
            [ckCode k | Advisory k <- ordering] `shouldContain` [Just PublisherPolicyChanged]
        it "classifies workqueue names as QueueIdentityChanged" $ do
            cs <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-rename.keiro"
            [ckCode k | Breaking k <- cs] `shouldContain` [Just QueueIdentityChanged]
        it "classifies pgmq dispatch dedupe and retargeting independently" $ do
            dedupe <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-dedupkey.keiro"
            [ckCode k | Breaking k <- dedupe] `shouldContain` [Just DedupeIdentityChanged]
            retarget <- diffFixtures "test/fixtures/reservation-work.keiro" "test/fixtures/reservation-work-retarget.keiro"
            any isBreaking retarget `shouldBe` False
            [ckCode k | Advisory k <- retarget] `shouldContain` [Just DispatchRetargeted]
        it "reports aggregate projection changes as warnings" $ do
            cs <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-projection.keiro"
            any isBreaking cs `shouldBe` False
            [ckCode k | Advisory k <- cs] `shouldContain` [Just ProjectionChanged]
        it "classifies read-model version and unversioned shape changes" $ do
            base <- specOf "test/fixtures/readmodel-runtime.keiro"
            let versionTwo = modifyReadModel "transfer_decisions" (\readModel -> readModel{rmVersion = 2}) base
                changedShape = modifyReadModel "transfer_decisions" changeReadModelShape base
                bumpedShape = modifyReadModel "transfer_decisions" (\readModel -> (changeReadModelShape readModel){rmVersion = 2}) base
                decreased = diffSpecs versionTwo base
                unversioned = diffSpecs base changedShape
                bumped = diffSpecs base bumpedShape
            [ckCode k | Breaking k <- decreased] `shouldContain` [Just ReadModelVersionDecreased]
            [ckCode k | Breaking k <- unversioned] `shouldContain` [Just ReadModelShapeChangedWithoutBump]
            any isBreaking bumped `shouldBe` False
            [ckFacet k | Additive k <- bumped] `shouldContain` ["read-model-version"]
        it "classifies read-model registry, table, subscription, and removal identities" $ do
            base <- specOf "test/fixtures/readmodel-runtime.keiro"
            let tableChanged = modifyReadModel "transfer_decisions" (\readModel -> readModel{rmTable = "transfer_decisions_v2"}) base
                subscriptionChanged = modifyReadModel "transfer_decisions" (\readModel -> readModel{rmSubscription = Just "transfer-decisions-v2"}) base
                renamed = modifyReadModel "transfer_decisions" (\readModel -> readModel{rmName = "reservation_decisions"}) base
                removed = removeReadModel "transfer_decisions" base
            mapM_
                (\changes -> [ckCode k | Breaking k <- changes] `shouldContain` [Just DerivedIdentityChanged])
                [diffSpecs base tableChanged, diffSpecs base subscriptionChanged, diffSpecs base renamed, diffSpecs base removed]
        it "classifies read-model feed flips and consistency/scope weakening as breaking" $ do
            base <- specOf "test/fixtures/readmodel-runtime.keiro"
            let feedChanged = modifyReadModel "transfer_decisions" (\readModel -> readModel{rmFeed = RmInline}) base
                consistencyWeakened = modifyReadModel "transfer_decisions" (\readModel -> readModel{rmConsistency = Eventual}) base
                entireLog = modifyReadModel "transfer_decisions" (\readModel -> readModel{rmScope = Just RmEntireLog}) base
            [ckCode k | Breaking k <- diffSpecs base feedChanged] `shouldContain` [Just ReadModelFeedChanged]
            [ckCode k | Breaking k <- diffSpecs base consistencyWeakened] `shouldContain` [Just ReadModelConsistencyWeakened]
            [ckCode k | Breaking k <- diffSpecs entireLog base] `shouldContain` [Just ReadModelConsistencyWeakened]
        it "classifies Eventual to Strong read-model consistency as additive" $ do
            strong <- specOf "test/fixtures/readmodel-runtime.keiro"
            let eventual = modifyReadModel "transfer_decisions" (\readModel -> readModel{rmConsistency = Eventual}) strong
                changes = diffSpecs eventual strong
            any isBreaking changes `shouldBe` False
            [ckFacet k | Additive k <- changes] `shouldContain` ["read-model-consistency"]

    describe "module placement (M1)" $ do
        it "GeneratedPrefix is today's namespace (Generated.<Ctx>.<Node>, holes at <Ctx>.<Node>)" $ do
            let ctx = defaultContext "hospital-capacity"
            genPrefixFor ctx "Reservation" `shouldBe` "Generated.HospitalCapacity.Reservation"
            holePrefixFor ctx "Reservation" `shouldBe` "HospitalCapacity.Reservation"
        it "module-root prefixes both layers" $ do
            let ctx = (defaultContext "hospital-capacity"){moduleRoot = "Acme"}
            genPrefixFor ctx "Reservation" `shouldBe` "Acme.Generated.HospitalCapacity.Reservation"
            holePrefixFor ctx "Reservation" `shouldBe` "Acme.HospitalCapacity.Reservation"
        it "CollocatedLeaf places the generated layer under the domain leaf" $ do
            let ctx = (defaultContext "hospital-capacity"){moduleRoot = "Acme", placement = CollocatedLeaf}
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

    describe "manifest (M2)" $ do
        it "lists exactly the modules the scaffolder produced" $ do
            mods <- scaffoldFixture "test/fixtures/reservation.keiro"
            spec <- specOf "test/fixtures/reservation.keiro"
            let manifest = renderManifest "reservation.keiro" mods spec
                expectedNames = sort (map (moduleNameOf . modulePath) mods)
            -- every produced module name appears in the manifest…
            mapM_ (\m -> (m `T.isInfixOf` manifest) `shouldBe` True) expectedNames
            -- …and the module list is exactly the scaffolder's output set.
            expectedNames
                `shouldBe` sort
                    [ "Generated.HospitalCapacity.Reservation.Codec"
                    , "Generated.HospitalCapacity.Reservation.Domain"
                    , "Generated.HospitalCapacity.Reservation.EventStream"
                    , "Generated.HospitalCapacity.Reservation.Harness"
                    , "Generated.HospitalCapacity.Reservation.Projection"
                    , "HospitalCapacity.Reservation.Holes"
                    ]
        it "derives the dependency set from the node kinds present (aggregate)" $ do
            spec <- specOf "test/fixtures/reservation.keiro"
            manifestDependencies spec `shouldBe` ["aeson", "base", "keiki", "keiro", "text"]
        it "derives the process dependency set, including worker-policy runtime imports" $ do
            spec <- specOf "test/fixtures/hospital-surge.keiro"
            let dependencies = manifestDependencies spec
            mapM_ (\dependency -> dependencies `shouldContain` [dependency]) ["time", "uuid", "shibuya-core", "keiki", "keiro"]
        it "uses the registered shibuya-core package name for router scaffolds" $ do
            spec <- specOf "test/fixtures/incident-paging/incident-paging.keiro"
            let dependencies = manifestDependencies spec
            mapM_ (\dependency -> dependencies `shouldContain` [dependency]) ["effectful-core", "keiro", "shibuya-core"]
            dependencies `shouldNotContain` ["shibuya"]

    describe "new <kind> skeletons (M5)" $ do
        it "every skeleton parses and validates with zero error diagnostics" $
            mapM_ assertSkeletonValid skeletonKinds
        it "every skeleton passes the scaffold refusal gates" $
            mapM_ assertSkeletonScaffoldable skeletonKinds
        it "fresh skeleton scaffolds match the committed compiling modules" $
            mapM_ (uncurry assertSkeletonMatchesCommitted) skeletonModuleRoots
        it "rejects an unknown kind with a helpful message" $
            case skeletonFor "bogus" of
                Left msg -> ("Valid kinds:" `T.isInfixOf` msg) `shouldBe` True
                Right _ -> expectationFailure "expected an error for an unknown kind"

    describe "firewall self-check (M3)" $ do
        it "flags a forbidden operator in a Generated module" $ do
            let m = ScaffoldModule{modulePath = "Gen/Foo.hs", moduleText = "x = a ./= b", kind = Generated, origin = "test"}
            firewallBreaches [m] `shouldBe` [("Gen/Foo.hs", "./=", 1)]
        it "ignores forbidden operators in a HoleStub module (holes own them)" $ do
            let m = ScaffoldModule{modulePath = "Foo/Holes.hs", moduleText = "x = lit 1 .== y", kind = HoleStub, origin = "test"}
            firewallBreaches [m] `shouldBe` []
        it "matches `lit` as a word, not a substring of quality/split" $ do
            let clean = ScaffoldModule{modulePath = "Gen/Q.hs", moduleText = "quality = split facility", kind = Generated, origin = "test"}
                dirty = ScaffoldModule{modulePath = "Gen/L.hs", moduleText = "v = lit foo", kind = Generated, origin = "test"}
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
        it "finds no breach in real scaffolder output (aggregate + process fixtures)" $ do
            aggMods <- scaffoldFixture "test/fixtures/reservation.keiro"
            procMods <- scaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
            firewallBreaches (aggMods <> procMods) `shouldBe` []

    describe "scaffold gates" $ do
        it "refuses duplicate and case-folded module paths with both origins" $ do
            spec <- specOf "test/fixtures/reservation.keiro"
            case [aggregate | NAggregate aggregate <- specNodes spec] of
                aggregate : _ -> do
                    let duplicate = spec{specNodes = [NAggregate aggregate, NAggregate aggregate]}
                        caseVariant = spec{specNodes = [NAggregate aggregate, NAggregate aggregate{aggName = T.toUpper (aggName aggregate)}]}
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
                let renamed = spec{specNodes = map renameCounter (specNodes spec)}
                second <- executePlannedScaffold out "counter.keiro" (defaultContext (specContext renamed)) renamed
                let oldDomain = onlyPathEndingIn "Counter/Domain.hs" (map fst (reportDispositions first))
                    oldHoles = onlyPathEndingIn "Counter/Holes.hs" (map fst (reportDispositions first))
                reportStale second `shouldSatisfy` \stale -> StaleModule Generated oldDomain `elem` stale && StaleModule HoleStub oldHoles `elem` stale
                doesFileExist (out </> oldDomain) `shouldReturn` True
                doesFileExist (out </> oldHoles) `shouldReturn` True
        it "reports the entire old tree across a module-root flip" $
            withTempDirectory "keiro-dsl-stale-root" $ \out -> do
                spec <- parseInlineSpec "<stale-root>" loweringAggregateSpec
                let initialCtx = defaultContext (specContext spec)
                    rootedCtx = initialCtx{moduleRoot = "Acme"}
                first <- executePlannedScaffold out "counter.keiro" initialCtx spec
                second <- executePlannedScaffold out "moved-counter.keiro" rootedCtx spec
                reportStale second
                    `shouldMatchList` [StaleModule (kind m) (modulePath m) | (m, _) <- reportDispositions first]
                forM_ (reportStale second) $ \stale -> doesFileExist (out </> stalePath stale) `shouldReturn` True
                renderScaffoldReport second `shouldSatisfy` any (T.isInfixOf "previous scaffold record used spec counter.keiro")
        it "reports moved generated modules across a layout flip" $
            withTempDirectory "keiro-dsl-stale-layout" $ \out -> do
                spec <- parseInlineSpec "<stale-layout>" loweringAggregateSpec
                let initialCtx = defaultContext (specContext spec)
                    collocatedCtx = initialCtx{placement = CollocatedLeaf}
                first <- executePlannedScaffold out "counter.keiro" initialCtx spec
                second <- executePlannedScaffold out "counter.keiro" collocatedCtx spec
                let oldGenerated = [StaleModule Generated (modulePath m) | (m, _) <- reportDispositions first, kind m == Generated]
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
                parseRecord contents
                    `shouldBe` Just
                        ScaffoldRecord
                            { recSpecPath = "counter.keiro"
                            , recModuleRoot = ""
                            , recLayout = "prefixed"
                            , recFiles = [(kind m, modulePath m) | (m, _) <- reportDispositions report]
                            }
                parseRecord (T.replace "spec: " "future-field: retained\nspec: " contents) `shouldBe` parseRecord contents
                parseRecord (T.replace "record v1" "record v2" contents) `shouldBe` Nothing

    describe "faithful scaffold lowering" $ do
        it "escapes a trailing-backslash payload literal exactly once" $ do
            spec <- specOf "test/fixtures/hospital-surge.keiro"
            case [process | NProcess process <- specNodes spec] of
                process : _ -> do
                    let timer = (procTimer process){tmPayload = [FieldBinding "kind" (Just "\"follow-up\\\"")]}
                        modules = scaffoldProcess (defaultContext (specContext spec)) process{procTimer = timer}
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
            unsupported <- parseInlineSpec "<unsupported-field>" (T.replace "count:Int" "count:Time" loweringAggregateSpec)
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
                        `shouldBe` T.unlines
                            [ "{"
                            , "  \"kind\": \"TransferReservationCreated\","
                            , "  \"reservationId\": \"rsv_01hzy3v7q2e8kaw2m5x0d41n9c\","
                            , "  \"hospitalId\": \"hosp_01hzy3v7q2e8kaw2m5x0d41n9c\","
                            , "  \"commandId\": \"cmd_01hzy3v7q2e8kaw2m5x0d41n9c\","
                            , "  \"patientAcuity\": \"red\","
                            , "  \"divertStatus\": \"open\","
                            , "  \"lifeCriticalOverride\": true"
                            , "}"
                            ]
                    let aggregate = onlyAggregate newSpec
                        modules =
                            harnessForWithGoldens
                                [golden]
                                (defaultContext (specContext newSpec))
                                newSpec
                                aggregate
                        harness = generatedTextEndingIn "Harness.hs" modules
                    harness `shouldSatisfy` T.isInfixOf "golden TransferReservationCreated.v1 decodes"
                    harness `shouldSatisfy` T.isInfixOf "\\\"reservationId\\\": \\\"rsv_"
                    harness `shouldSatisfy` (not . T.isInfixOf "current-shape stand-in")
                goldens -> expectationFailure ("expected one synthesized golden, got " <> show goldens)
        it "dispatches shared-version upcasters by wire event type and passes foreign kinds through" $ do
            source <- readTestText "test/fixtures/reservation-dup-upcast-source.keiro"
            spec <- parseInlineSpec "<shared-upcaster-source>" source
            case [aggregate | NAggregate aggregate <- specNodes spec] of
                [aggregate] -> do
                    let modules = scaffoldAggregate (defaultContext (specContext spec)) spec aggregate
                        codec = generatedTextEndingIn "Codec.hs" modules
                        holes = case [moduleText m | m <- modules, "Holes.hs" `T.isSuffixOf` T.pack (modulePath m)] of
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
                        { eventTypes = EventType "AmountScaled" :| [EventType "AmountRenamed", EventType "AmountObserved"]
                        , eventType = const (EventType "AmountObserved")
                        , schemaVersion = 2
                        , encode = id
                        , decode = \_ -> Right
                        , upcasters = [(1, rung)]
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
            let holes = [m | m <- mods, "Holes.hs" `T.isSuffixOf` T.pack (modulePath m)]
            map kind holes `shouldBe` [HoleStub]
            -- Domain, Codec, EventStream, Projection, Harness.
            length [m | m <- mods, kind m == Generated] `shouldBe` 5
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
            spec <- specOf "test/fixtures/transfer-routing.keiro"
            let modules = scaffoldModules (defaultContext (specContext spec)) spec
            forM_ [m | m <- modules, kind m == Generated] $ \m -> do
                committed <- readTestText ("test/conformance-newsurface/" <> modulePath m)
                normalizeGenerated committed `shouldBe` normalizeGenerated (moduleText m)
        it "scaffolds the register-free OrderStream smoke target without error" $ do
            mods <- scaffoldFixture "test/fixtures/order.keiro"
            -- 5 Generated (Domain/Codec/EventStream/Projection/Harness) + 1 Holes.
            length mods `shouldBe` 6
            firewallBreaches mods `shouldBe` []
        it "lowers a replay-only transition to B.replayOnly in the holes skeleton (plan 143)" $ do
            twinMods <- scaffoldFixture "test/fixtures/reservation-guard-tightened-twin.keiro"
            let twinHoles = [moduleText m | m <- twinMods, kind m == HoleStub]
            twinHoles `shouldSatisfy` any (T.isInfixOf "B.replayOnly")
            plainMods <- scaffoldFixture "test/fixtures/reservation.keiro"
            let plainHoles = [moduleText m | m <- plainMods, kind m == HoleStub]
            plainHoles `shouldSatisfy` all (not . T.isInfixOf "B.replayOnly")

syntheticGenerated :: FilePath -> T.Text -> ScaffoldModule
syntheticGenerated path contents =
    ScaffoldModule{modulePath = path, moduleText = contents, kind = Generated, origin = "test"}

generatedTextEndingIn :: T.Text -> [ScaffoldModule] -> T.Text
generatedTextEndingIn suffix modules = case [moduleText m | m <- modules, kind m == Generated, suffix `T.isSuffixOf` T.pack (modulePath m)] of
    contents : _ -> contents
    [] -> ""

onlyAggregate :: Spec -> Aggregate
onlyAggregate spec = case [aggregate | NAggregate aggregate <- specNodes spec] of
    [aggregate] -> aggregate
    aggregates -> error ("expected one aggregate, got " <> show (length aggregates))

loweringAggregateSpec :: T.Text
loweringAggregateSpec =
    T.unlines
        [ "context samples"
        , ""
        , "aggregate Counter"
        , "  regs"
        , "    note Text = \"hello world\""
        , "    count Int = 0"
        , "    state CounterVertex = Pending"
        , "  states Pending Done!"
        , "  command Bump { count:Int }"
        , "  event CountBumped { count:Int }"
        , "  Pending -- Bump --> emit CountBumped ; goto Done"
        ]

exactStatusSpec :: T.Text
exactStatusSpec =
    T.unlines
        [ "context samples"
        , ""
        , "aggregate Reservation"
        , "  regs"
        , "    state ReservationVertex = Open"
        , "  states Open Closed!"
        , "  command Bump { count:Int }"
        , "  event ReservationHeld { count:Int }"
        , "  event ReservationUnHeld { count:Int }"
        , "  event CountBumped { count:Int }"
        , "  Open -- Bump --> emit CountBumped ; goto Closed"
        , "  projection reservation_status consistency=Eventual key=count"
        , "    status-map { ReservationHeld=>held ReservationUnHeld=>available CountBumped=>bumped }"
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
            { aggName = "Widget"
            , aggRegs = [reg{regType = if regType reg == "CounterVertex" then "WidgetVertex" else regType reg} | reg <- aggRegs aggregate]
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

{- | Parse a fixture and return the validator's diagnostic codes (failing the
test on a parse error).
-}
diagnosticCodesOf :: FilePath -> IO [DiagnosticCode]
diagnosticCodesOf path = do
    map code <$> diagnosticsOf path

-- | Parse a fixture and return all validator diagnostics.
diagnosticsOf :: FilePath -> IO [Diagnostic]
diagnosticsOf path = do
    input <- readTestText path
    case parseSpec path input of
        Left err -> expectationFailure (T.unpack err) >> pure []
        Right spec -> pure (validateSpec spec)

{- | Like 'diagnosticCodesOf' but only the Error-severity codes (warnings, e.g.
the benign-inversion notices, are excluded).
-}
errorCodesOf :: FilePath -> IO [DiagnosticCode]
errorCodesOf path = do
    diagnostics <- diagnosticsOf path
    pure [code d | d <- diagnostics, severity d == Error]

{- | Parse two fixtures and diff them (old, new).
| Plan 143: render an Expr in concrete guard syntax by printing a dummy
transition through the real pretty-printer and slicing its guard clause,
so the test exercises the exact printer the diff advisory uses.
-}
renderExprText :: Expr -> T.Text
renderExprText e =
    case [T.strip l | l <- T.lines rendered, "guard " `T.isPrefixOf` T.strip l] of
        [guardLine] -> T.strip (T.drop (T.length "guard ") guardLine)
        _ -> error ("renderExprText: unexpected printer output: " <> T.unpack rendered)
  where
    rendered =
        renderTransition
            Transition
                { tSource = "S"
                , tCommand = "C"
                , tGuard = Just e
                , tWrites = []
                , tEmits = []
                , tGoto = "S"
                , tMode = TmLive
                , tLoc = noLoc
                }

{- | Plan 143: a minimal spec whose only transition is replay-only, with the
supplied clause lines spliced into its body.
-}
replayOnlySpecWith :: [T.Text] -> T.Text
replayOnlySpecWith clauseLines =
    T.unlines $
        [ "context hospital-capacity"
        , ""
        , "id TransferReservationId prefix=rsv"
        , ""
        , "aggregate Reservation"
        , "  regs"
        , "    reservationId    TransferReservationId = placeholder"
        , "    reservationState ReservationVertex     = Unrequested"
        , "  states Unrequested Held"
        , ""
        , "  command RequestTransferReservation { reservationId }"
        , ""
        , "  event TransferReservationCreated = fields(RequestTransferReservation)"
        , ""
        , "  replay-only Unrequested -- RequestTransferReservation -->"
        ]
            ++ clauseLines

diffFixtures :: FilePath -> FilePath -> IO [Change]
diffFixtures oldP newP = do
    old <- readTestText oldP
    new <- readTestText newP
    case (,) <$> parseSpec oldP old <*> parseSpec newP new of
        Left err -> expectationFailure (T.unpack err) >> pure []
        Right (o, n) -> pure (diffSpecs o n)

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

removeReadModel :: Name -> Spec -> Spec
removeReadModel target spec =
    spec{specNodes = [node | node <- specNodes spec, not (isTarget node)]}
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

changeReadModelShape :: ReadModelNode -> ReadModelNode
changeReadModelShape readModel =
    readModel
        { rmColumns = rmColumns readModel <> [RmColumn "reviewed_by" "text" False]
        , rmShape = "fnv1a:0000000000000000"
        }

{- | Assert a @new \<kind\>@ skeleton parses and validates with zero
error-severity diagnostics.
-}
assertSkeletonValid :: T.Text -> IO ()
assertSkeletonValid kind = case skeletonFor kind of
    Left err -> expectationFailure (T.unpack ("skeleton for " <> kind <> ": " <> err))
    Right src -> case parseSpec ("new:" <> T.unpack kind) src of
        Left perr -> expectationFailure (T.unpack ("skeleton for " <> kind <> " failed to parse: " <> perr))
        Right spec ->
            [code d | d <- validateSpec spec, severity d == Error]
                `shouldBe` ([] :: [DiagnosticCode])

assertSkeletonScaffoldable :: T.Text -> IO ()
assertSkeletonScaffoldable kind = case skeletonFor kind of
    Left err -> expectationFailure (T.unpack ("skeleton for " <> kind <> ": " <> err))
    Right src -> case parseSpec ("new:" <> T.unpack kind) src of
        Left perr -> expectationFailure (T.unpack perr)
        Right spec -> planScaffold (defaultContext (specContext spec)) spec `shouldSatisfy` isSuccessfulScaffold

skeletonModuleRoots :: [(T.Text, T.Text)]
skeletonModuleRoots =
    [ ("aggregate", "SkelAggregate")
    , ("process", "SkelProcess")
    , ("router", "SkelRouter")
    , ("contract", "SkelContract")
    , ("intake", "SkelIntake")
    , ("emit", "SkelEmit")
    , ("workqueue", "SkelQueue")
    , ("workflow", "SkelWorkflow")
    ]

assertSkeletonMatchesCommitted :: T.Text -> T.Text -> IO ()
assertSkeletonMatchesCommitted kind root = case skeletonFor kind of
    Left err -> expectationFailure (T.unpack err)
    Right source -> case parseSpec ("new:" <> T.unpack kind) source of
        Left err -> expectationFailure (T.unpack err)
        Right spec -> do
            let ctx = (defaultContext (specContext spec)){moduleRoot = root}
            forM_ [m | m <- scaffoldModules ctx spec, kindOf m == Generated] $ \m -> do
                committed <- readTestText ("test/conformance-skeletons/" <> modulePath m)
                normalizeGenerated committed `shouldBe` normalizeGenerated (moduleText m)
  where
    kindOf = Keiro.Dsl.Scaffold.kind

-- | Parse a fixture into a 'Spec', failing the test on a parse error.
specOf :: FilePath -> IO Spec
specOf path = do
    input <- readTestText path
    case parseSpec path input of
        Left err -> expectationFailure (T.unpack err) >> error "unreachable"
        Right spec -> pure spec

-- | Parse a fixture and scaffold every aggregate in it.
scaffoldFixture :: FilePath -> IO [ScaffoldModule]
scaffoldFixture path = do
    input <- readTestText path
    case parseSpec path input of
        Left err -> expectationFailure (T.unpack err) >> pure []
        Right spec ->
            pure $
                concat
                    [ scaffoldAggregate (ctx spec) spec agg <> harnessFor (ctx spec) spec agg
                    | NAggregate agg <- specNodes spec
                    ]
  where
    ctx spec = defaultContext (specContext spec)

scaffoldProcessFixture :: FilePath -> IO [ScaffoldModule]
scaffoldProcessFixture path = do
    input <- readTestText path
    case parseSpec path input of
        Left err -> expectationFailure (T.unpack err) >> pure []
        Right spec ->
            pure $ concat [scaffoldProcess (ctx spec) p | NProcess p <- specNodes spec]
  where
    ctx spec = defaultContext (specContext spec)

{- | Assert a freshly-scaffolded Generated module matches its committed copy
under test/conformance/ (whitespace-normalized). The committed copies are the
ones the keiro-dsl-conformance suite compiles, so this pins the live scaffolder
to known-compiling output.
-}
assertMatchesCommitted :: ScaffoldModule -> IO ()
assertMatchesCommitted m = do
    let committedPath = "test/conformance/" <> modulePath m
    committed <- readTestText committedPath
    normalizeGenerated committed `shouldBe` normalizeGenerated (moduleText m)

normalizeGenerated :: T.Text -> (T.Text, [T.Text])
normalizeGenerated text =
    let (imports, body) = partition isImport (T.lines text)
     in (normalizeBody body, sort (map normalizeImport imports))
  where
    -- Compare the deterministic body exactly as before and imports as a sorted,
    -- whitespace-normalized list. Sorting tolerates formatter reordering while
    -- additions, removals, and renamed imports now fail the pin.
    normalizeBody =
        T.replace " , )" " )"
            . T.unwords
            . T.words
            . T.replace "}" " } "
            . T.replace "{" " { "
            . T.replace "]" " ] "
            . T.replace "[" " [ "
            . T.replace "," " , "
            . T.unlines
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
                                . map (T.unwords . T.words)
                                . T.splitOn ","
                                . T.dropEnd 1
                                $ T.drop 2 explicit
                     in prefix <> " (" <> T.intercalate "," members <> ")"
    isImport line = case T.words line of
        "import" : _ -> True
        _ -> False

{- | Locate and read a test fixture or committed conformance source regardless
of whether the suite was launched from the package directory or repo root.
-}
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

statusMapSpec :: T.Text -> T.Text
statusMapSpec marker =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "  states Open"
        , ""
        , "  event Created { }"
        , "  event Changed { }"
        , ""
        , "  projection things consistency=Eventual key=thingId"
        , "    status-map" <> marker <> " { Created=>held }"
        ]

parseErrorOf :: FilePath -> T.Text -> IO T.Text
parseErrorOf sourceName src = case parseSpec sourceName src of
    Left err -> pure err
    Right _ -> expectationFailure ("expected parse failure for " <> sourceName) >> error "unreachable"

duplicateGotoSpec :: T.Text
duplicateGotoSpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "  states A B C"
        , ""
        , "  command Go { }"
        , "  A -- Go -->"
        , "    goto B"
        , "    goto C"
        ]

missingGotoSpec :: T.Text
missingGotoSpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "  states A B"
        , ""
        , "  command Go { }"
        , "  A -- Go -->"
        , "    emit Changed"
        ]

duplicateWireSpec :: T.Text
duplicateWireSpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "  states Open"
        , ""
        , "  wire kind=ctorName fields=camelCase schemaVersion=1"
        , "  wire kind=typeName fields=snakeCase schemaVersion=2"
        ]

duplicateProjectionSpec :: T.Text
duplicateProjectionSpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "  states Open"
        , ""
        , "  projection first consistency=Strong key=thingId"
        , "    status-map partial { }"
        , "  projection second consistency=Eventual key=thingId"
        ]

projectionWithoutConsistencySpec :: T.Text
projectionWithoutConsistencySpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "  states Open"
        , ""
        , "  projection things key=thingId"
        ]

malformedRegisterSpec :: T.Text
malformedRegisterSpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "    status Status"
        , "  states Open"
        ]

misplacedDispatchIdSpec :: T.Text
misplacedDispatchIdSpec =
    T.replace
        "    schedule timer\n\n  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)\n"
        "    dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)\n    schedule timer\n"
        (renderSpec (Spec "svc" Nothing Nothing [] [] [] [NProcess (processWithLiteral "literal")]))

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
    [ ("event-version", eventVersionDecimalSpec decimalOverflow)
    , ("wire-schema", wireDecimalSpec decimalOverflow)
    , ("contract-schema", contractDecimalSpec decimalOverflow)
    , ("decode-schema", decodeDecimalSpec decimalOverflow)
    , ("publisher-attempts", publisherDecimalSpec decimalOverflow)
    , ("workqueue-retries", workqueueDecimalSpec decimalOverflow)
    , ("timer-attempts", timerDecimalSpec decimalOverflow)
    ]

eventVersionDecimalSpec :: T.Text -> T.Text
eventVersionDecimalSpec value =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "  states Open"
        , ""
        , "  event Changed v" <> value <> " { }"
        ]

wireDecimalSpec :: T.Text -> T.Text
wireDecimalSpec value =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "  states Open"
        , ""
        , "  wire kind=ctorName fields=camelCase schemaVersion=" <> value
        ]

contractDecimalSpec :: T.Text -> T.Text
contractDecimalSpec value =
    T.unlines
        [ "context svc"
        , ""
        , "contract Contract {"
        , "  schemaVersion " <> value
        , "  discriminator kind"
        , "}"
        ]

decodeDecimalSpec :: T.Text -> T.Text
decodeDecimalSpec value =
    T.unlines
        [ "context svc"
        , ""
        , "intake Inbox {"
        , "  contract Contract"
        , "  topic events"
        , "  accept Event"
        , "  dedupe key messageId policy PreferIntegrationMessageId"
        , "  decode { envelope strict-required lenient-optional body strict schemaVersion == " <> value <> " }"
        , "  disposition { }"
        , "}"
        ]

publisherDecimalSpec :: T.Text -> T.Text
publisherDecimalSpec value =
    T.unlines
        [ "context svc"
        , ""
        , "publisher Publisher {"
        , "  emit Emit"
        , "  ordering PerKeyHeadOfLine"
        , "  maxAttempts " <> value
        , "  backoff constant 2s"
        , "  outboxId stable from messageId"
        , "}"
        ]

workqueueDecimalSpec :: T.Text -> T.Text
workqueueDecimalSpec value =
    T.unlines
        [ "context svc"
        , ""
        , "workqueue Queue {"
        , "  queue logical = \"queue\""
        , "  derive physical = \"queue\""
        , "    dlq = \"queue_dlq\""
        , "    table = \"pgmq.q_queue\""
        , "  payload Job { }"
        , "  retry maxRetries = " <> value <> " delay = 5s dlq = on"
        , "  disposition { }"
        , "}"
        ]

timerDecimalSpec :: T.Text -> T.Text
timerDecimalSpec value =
    T.replace
        "max-attempts 5"
        ("max-attempts " <> value)
        (renderSpec (Spec "svc" Nothing Nothing [] [] [] [NProcess (processWithLiteral "literal")]))

identifierHygieneSpec :: T.Text
identifierHygieneSpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate thing"
        , "  regs"
        , "  states Open"
        , ""
        , "  command DoIt { data }"
        ]

vertexCollisionSpec :: T.Text
vertexCollisionSpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Reservation"
        , "  regs"
        , "  states Created"
        , ""
        , "  event ReservationCreated { }"
        ]

underscoreNodeSpec :: T.Text
underscoreNodeSpec =
    T.unlines
        [ "context svc"
        , ""
        , "contract _contract {"
        , "  schemaVersion 1"
        , "  discriminator kind"
        , "}"
        ]

unicodeIdentifierSpec :: T.Text
unicodeIdentifierSpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate Résumé"
        , "  regs"
        , "  states Open"
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
        [NAggregate (Aggregate "Thing" [] [] [] [] [] Nothing Nothing Nothing noLoc)]

crossFamilyBoundarySpec :: T.Text
crossFamilyBoundarySpec =
    T.unlines
        [ "context svc"
        , ""
        , "aggregate First"
        , "  regs"
        , "  states A B"
        , "  command Go { }"
        , "  A -- Go -->"
        , "    emit Changed"
        , "    goto B"
        , ""
        , "emit Output {"
        , "  contract Contract"
        , "  topic events"
        , "  source \"source\""
        , "  key thingId"
        , "  map status { _ => skip }"
        , "  messageId derive hole"
        , "  idempotencyKey derive hole"
        , "}"
        , ""
        , "aggregate Second"
        , "  regs"
        , "  states"
        , ""
        , "dispatch QueueDispatch {"
        , "  source readModel = source key = thingId"
        , "  fanout body = resolveFanout"
        , "  dedup key = thingId"
        , "    seenIn readModel = seen field = thingId"
        , "    seenIn queue = workQueue field = thingId"
        , "  enqueue to = workQueue"
        , "}"
        ]

--------------------------------------------------------------------------------
-- Generators (bounded; restricted to valid, non-reserved identifiers)
--------------------------------------------------------------------------------

{- | Text that exercises every supported escape plus notation punctuation that
used to be able to split one emit-map row into several rows.
-}
genAdversarialText :: Gen T.Text
genAdversarialText =
    T.concat
        <$> resize
            20
            (listOf (elements ["a", "Z", "\"", "\\", "\n", "\t", "\r", "=>", "#", "{", "}", " "]))

{- | One spec carrying the same adversarial value through three distinct
printer paths: a contract topic, an emit-map value, and a quote-wrapped
field-binding literal.
-}
escapedSpec :: T.Text -> Spec
escapedSpec value =
    Spec
        "escape"
        Nothing
        Nothing
        []
        []
        []
        [ NContract
            ContractNode
                { ctrName = "Contract"
                , ctrSchemaVersion = 1
                , ctrDiscriminator = "kind"
                , ctrTopics = [("events", value)]
                , ctrEvents = []
                , ctrLoc = noLoc
                }
        , NEmit
            EmitNode
                { emName = "Emit"
                , emContract = "Contract"
                , emTopic = "events"
                , emSource = "source"
                , emKey = "key"
                , emDiscriminant = "status"
                , emMap = [EmitMapRow value "Event" noLoc]
                , emSkip = True
                , emMessageId = DeriveSpec Nothing
                , emIdempotencyKey = DeriveSpec Nothing
                , emLoc = noLoc
                }
        , NProcess (processWithLiteral value)
        ]

processWithLiteral :: T.Text -> ProcessNode
processWithLiteral value =
    ProcessNode
        { procId = "Process"
        , procName = "process"
        , procInput = InputDecl "Input" []
        , procCorrelate = CorrelateDecl "key" "idText"
        , procSaga = SagaRef "Saga" "saga"
        , procTarget = "Target"
        , procProjections = []
        , procHandle =
            HandleNode
                { hOn = "Input"
                , hAdvance = AdvanceNode "Advance" [FieldBinding "literal" (Just ("\"" <> value <> "\""))]
                , hDispatch = []
                , hSchedule = "timer"
                }
        , procRejected = PolHalt
        , procPoison = PolHalt
        , procTimer =
            TimerNode
                { tmName = "timer"
                , tmId = IdExpr UuidV5Id "timer:"
                , tmFireAt = FireAtExpr "observedAt" "5m"
                , tmPayload = []
                , tmFire =
                    FireNode
                        { fireTarget = "Target"
                        , fireKey = "correlationId"
                        , fireCommand = "Fire"
                        , fireFields = []
                        , fireFiredEventId = IdExpr UuidV5Id "fired:"
                        , fireDisposition = FireDisposition OFired OFired ORetry ORetry ORetry
                        }
                , tmDecodeUnknown = "Cancelled"
                , tmMaxAttempts = 5
                , tmDeadLetter = "exhausted"
                , tmLoc = noLoc
                }
        , procLoc = noLoc
        }

genName :: Gen Name
genName =
    frequency
        [
            ( 3
            , do
                base <- elements ["Aa", "Bb", "Cc", "Dd", "St", "Cmd", "Ev", "Reg", "Fld", "Foo", "Bar", "Qux"]
                n <- choose (0, 9 :: Int)
                pure (T.pack (base <> show n))
            )
        , (1, elements ["data1", "typeA", "whereX", "gotoX", "guardY", "emitZ", "_lead"])
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
            [ genAtom
            , EOr <$> go (d - 1) <*> go (d - 1)
            , EAnd <$> go (d - 1) <*> go (d - 1)
            , ECmp <$> genCmp <*> go (d - 1) <*> go (d - 1)
            ]

genField :: Gen Field
genField = Field <$> genName <*> oneof [pure Nothing, Just <$> genName]

genReg :: Gen RegDecl
genReg = RegDecl <$> genName <*> genName <*> genRegInitial <*> pure noLoc

genRegInitial :: Gen RegInitial
genRegInitial = oneof [RegInitBare <$> genName, RegInitText <$> genAdversarialText]

genState :: Gen StateDecl
genState = StateDecl <$> genName <*> arbitrary <*> pure noLoc

genCommand :: Gen Command
genCommand = Command <$> genName <*> smallList genField <*> pure noLoc

genEvent :: Gen Event
genEvent = do
    name <- genName
    eventBody <- body
    version <- choose (1, 3)
    upcast <- genMaybe ((,) <$> choose (0, 3) <*> pure Hole)
    (retiring, deprecated) <- elements [(False, False), (True, False), (False, True)]
    pure
        Event
            { evName = name
            , evBody = eventBody
            , evVersion = version
            , evUpcastFrom = upcast
            , evRetiring = retiring
            , evDeprecated = deprecated
            , evLoc = noLoc
            }
  where
    body = oneof [EventFromCommand <$> genName, EventFields <$> smallList genField]

genTransition :: Gen Transition
genTransition =
    Transition
        <$> genName
        <*> genName
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
            [ pure Nothing
            , Just <$> genDottedRef
            , Just . (\raw -> "\"" <> raw <> "\"") <$> genAdversarialText
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
            [ WfStep <$> genWireWord <*> genName <*> pure noLoc
            , WfAwait <$> genWireWord <*> genName <*> pure noLoc
            , WfSleep <$> genWireWord <*> genName <*> pure noLoc
            , WfChild <$> genWireWord <*> genName <*> genName <*> pure noLoc
            , WfContinueAsNew <$> genName <*> pure noLoc
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
        [ CommandOp <$> genName <*> genName <*> genName <*> smallList genName
        , QueryOp <$> genName <*> genName <*> ((\parts -> T.unwords parts) <$> nonEmptyList genName) <*> genName
        , SignalOp <$> genWireWord <*> genName <*> genName <*> genName <*> genName
        , RunOp <$> genName <*> genName <*> genName
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

genId :: Gen IdDecl
genId = IdDecl <$> genName <*> genWire <*> pure noLoc

genEnum :: Gen EnumDecl
genEnum = EnumDecl <$> genName <*> smallList ((,) <$> genName <*> genWire) <*> pure noLoc

genRule :: Gen RuleDecl
genRule =
    RuleDecl
        <$> genName
        <*> genName
        <*> genName
        <*> nonEmptyList ((,) <$> genName <*> genExpr)
        <*> pure noLoc

genSpec :: Gen Spec
genSpec =
    Spec
        <$> genWire
        <*> genMaybe genModuleRoot
        <*> genMaybe (elements [GeneratedPrefix, CollocatedLeaf])
        <*> smallList genId
        <*> smallList genEnum
        <*> smallList genRule
        <*> smallList genNode
  where
    genNode =
        oneof
            [ NAggregate <$> genAggregate
            , NProcess <$> genProcess
            , NRouter <$> genRouter
            , NContract <$> genContract
            , NIntake <$> genIntake
            , NEmit <$> genEmit
            , NPublisher <$> genPublisher
            , NWorkqueue <$> genWorkqueue
            , NPgmqDispatch <$> genPgmqDispatch
            , NReadModel <$> genReadModel
            , NWorkflow <$> genWorkflow
            , NOperation <$> genOperation
            ]

-- | A dotted PascalCase module prefix, e.g. @Acme@ or @Acme.Services@.
genModuleRoot :: Gen T.Text
genModuleRoot = do
    n <- choose (1, 3 :: Int)
    segs <- vectorOf n (elements ["Acme", "Services", "Hospital", "Domain", "Core"])
    pure (T.intercalate "." segs)
