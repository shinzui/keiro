{- | Test driver for keiro-dsl. EP-1 milestone 1 tests: the @parse . pretty@
round-trip property over generated specs, and a unit test pinning the shape
of the canonical Reservation fixture.
-}
module Main (main) where

import Data.List (sort)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), FamilyDiff (..), NodeFamily, diffSpecs, familyRegistry, isAdvisory, isBreaking)
import Keiro.Dsl.Grammar
import Keiro.Dsl.Harness (harnessFor)
import Keiro.Dsl.Manifest (manifestDependencies, moduleNameOf, renderManifest)
import Keiro.Dsl.Parser (parseSpec)
import Keiro.Dsl.PrettyPrint (renderSpec)
import Keiro.Dsl.Scaffold (Context (..), ModuleKind (..), Placement (..), ScaffoldModule (..), defaultContext, firewallBreaches, genPrefixFor, holePrefixFor, scaffoldAggregate, scaffoldProcess)
import Keiro.Dsl.Skeleton (skeletonFor, skeletonKinds)
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode (..), Severity (..), validateSpec)
import Test.Hspec hiding (Spec)
import Test.QuickCheck

main :: IO ()
main = hspec $ do
    describe "parse . pretty round-trip" $
        it "re-parses any generated spec to an equal AST (modulo source locations)" $
            forAll genSpec $ \s ->
                parseSpec "<gen>" (renderSpec s) === Right s

    describe "canonical reservation.keiro" $
        it "parses into the expected aggregate shape" $ do
            input <- TIO.readFile "test/fixtures/reservation.keiro"
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
            codes <- diagnosticCodesOf "test/fixtures/reservation.keiro"
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
            codes <- diagnosticCodesOf "test/fixtures/reservation-v2.keiro"
            codes `shouldBe` []
        it "rejects a v2 event with no upcaster as EvtVersionMissingUpcaster" $ do
            codes <- diagnosticCodesOf "test/fixtures/reservation-v2-noupcast.keiro"
            codes `shouldContain` [EvtVersionMissingUpcaster]
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

    describe "evolution parsing" $
        it "parses event version and upcaster from reservation-v2.keiro" $ do
            input <- TIO.readFile "test/fixtures/reservation-v2.keiro"
            case parseSpec "test/fixtures/reservation-v2.keiro" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> case [e | NAggregate a <- specNodes spec, e <- aggEvents a, evName e == "TransferReservationCreated"] of
                    (e : _) -> do
                        evVersion e `shouldBe` 2
                        evUpcastFrom e `shouldBe` Just (1, Hole)
                    [] -> expectationFailure "TransferReservationCreated not found"

    describe "process/timer (EP-3)" $ do
        it "parses the hospital-surge process + nested timer" $ do
            input <- TIO.readFile "test/fixtures/hospital-surge.keiro"
            case parseSpec "test/fixtures/hospital-surge.keiro" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> case [p | NProcess p <- specNodes spec] of
                    (p : _) -> do
                        procId p `shouldBe` "HospitalSurge"
                        procName p `shouldBe` "hospital-surge"
                        tmName (procTimer p) `shouldBe` "surgeFollowUp"
                        onReject (fireDisposition (tmFire (procTimer p))) `shouldBe` OFired
                        tmMaxAttempts (procTimer p) `shouldBe` 5
                    [] -> expectationFailure "no process node parsed"
        it "round-trips the hospital-surge spec through parse . pretty" $ do
            input <- TIO.readFile "test/fixtures/hospital-surge.keiro"
            case parseSpec "in" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
        it "accepts the hospital-surge spec (no errors; benign-inversion warnings only)" $ do
            codes <- errorCodesOf "test/fixtures/hospital-surge.keiro"
            codes `shouldBe` []
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
        it "scaffolds the process: Generated wiring is firewall-clean + a HoleStub" $ do
            mods <- scaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
            let gens = [m | m <- mods, kind m == Generated]
                holes = [m | m <- mods, kind m == HoleStub]
            length gens `shouldBe` 1
            length holes `shouldBe` 1
            [() | m <- gens, op <- symbolicOperators, op `T.isInfixOf` moduleText m] `shouldBe` []
            -- the worker uses the spec's ceiling, never the dangerous default
            ("max-attempts = 5" `T.isInfixOf` moduleText (head gens)) `shouldBe` True
        it "process scaffold is deterministic" $ do
            a <- scaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
            b <- scaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
            map moduleText a `shouldBe` map moduleText b

    describe "contract (EP-4)" $ do
        it "parses the emergency contract (topics + events-on-topic + typed fields)" $ do
            input <- TIO.readFile "test/fixtures/contract.keiro"
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
            input <- TIO.readFile "test/fixtures/contract.keiro"
            case parseSpec "in" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
        it "round-trips the intake (inbox) spec through parse . pretty" $ do
            input <- TIO.readFile "test/fixtures/intake.keiro"
            case parseSpec "in" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
        it "accepts the intake spec (complete disposition, no inversions)" $ do
            codes <- errorCodesOf "test/fixtures/intake.keiro"
            codes `shouldBe` []
        it "rejects duplicate => retry (inversion 1)" $ do
            codes <- errorCodesOf "test/fixtures/intake-dup-retry.keiro"
            codes `shouldContain` [DispositionDuplicateRetry]
        it "rejects previouslyFailed => retry (inversion 2)" $ do
            codes <- errorCodesOf "test/fixtures/intake-pf-retry.keiro"
            codes `shouldContain` [DispositionPreviouslyFailedRetry]
        it "rejects an incomplete disposition table" $ do
            codes <- errorCodesOf "test/fixtures/intake-incomplete.keiro"
            codes `shouldContain` [DispositionIncomplete]
        it "round-trips the emit/publisher spec through parse . pretty" $ do
            input <- TIO.readFile "test/fixtures/emit.keiro"
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

    describe "pgmq workqueue/dispatch (EP-5)" $ do
        it "round-trips the reservation-work spec through parse . pretty" $ do
            input <- TIO.readFile "test/fixtures/reservation-work.keiro"
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

    describe "workflow/operation (EP-6)" $ do
        it "round-trips the workflow spec through parse . pretty" $ do
            input <- TIO.readFile "test/fixtures/workflow.keiro"
            case parseSpec "in" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
        it "accepts the workflow spec (await<->signal matches, run resolves)" $ do
            codes <- errorCodesOf "test/fixtures/workflow.keiro"
            codes `shouldBe` []
        it "rejects a signal label with no matching await as AwaitSignalMismatch" $ do
            codes <- errorCodesOf "test/fixtures/workflow-signal-mismatch.keiro"
            codes `shouldContain` [AwaitSignalMismatch]

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
        it "keeps deprecation additive and reports un-deprecation as EventUndeprecated" $ do
            deprecated <- diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-deprecated.keiro"
            any isBreaking deprecated `shouldBe` False
            restored <- diffFixtures "test/fixtures/reservation-deprecated.keiro" "test/fixtures/reservation.keiro"
            any isAdvisory restored `shouldBe` True
            [ckCode k | Advisory k <- restored] `shouldContain` [Just EventUndeprecated]
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
        it "classifies process and timer derivation changes as DerivedIdentityChanged" $ do
            processName <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-procname.keiro"
            [ckCode k | Breaking k <- processName] `shouldContain` [Just DerivedIdentityChanged]
            timerId <- diffFixtures "test/fixtures/hospital-surge.keiro" "test/fixtures/hospital-surge-timerid.keiro"
            [ckCode k | Breaking k <- timerId] `shouldContain` [Just DerivedIdentityChanged]
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
            input <- TIO.readFile "test/fixtures/reservation.keiro"
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
        it "derives the process dependency set (aeson/keiki/keiro/text/time/uuid)" $ do
            spec <- specOf "test/fixtures/hospital-surge.keiro"
            manifestDependencies spec `shouldContain` ["time", "uuid"]
            manifestDependencies spec `shouldContain` ["keiki", "keiro"]

    describe "new <kind> skeletons (M5)" $ do
        it "every skeleton parses and validates with zero error diagnostics" $
            mapM_ assertSkeletonValid skeletonKinds
        it "rejects an unknown kind with a helpful message" $
            case skeletonFor "bogus" of
                Left msg -> ("Valid kinds:" `T.isInfixOf` msg) `shouldBe` True
                Right _ -> expectationFailure "expected an error for an unknown kind"

    describe "firewall self-check (M3)" $ do
        it "flags a forbidden operator in a Generated module" $ do
            let m = ScaffoldModule{modulePath = "Gen/Foo.hs", moduleText = "x = a ./= b", kind = Generated}
            firewallBreaches [m] `shouldBe` [("Gen/Foo.hs", "./=", 1)]
        it "ignores forbidden operators in a HoleStub module (holes own them)" $ do
            let m = ScaffoldModule{modulePath = "Foo/Holes.hs", moduleText = "x = lit 1 .== y", kind = HoleStub}
            firewallBreaches [m] `shouldBe` []
        it "matches `lit` as a word, not a substring of quality/split" $ do
            let clean = ScaffoldModule{modulePath = "Gen/Q.hs", moduleText = "quality = split facility", kind = Generated}
                dirty = ScaffoldModule{modulePath = "Gen/L.hs", moduleText = "v = lit foo", kind = Generated}
            firewallBreaches [clean] `shouldBe` []
            firewallBreaches [dirty] `shouldBe` [("Gen/L.hs", "lit", 1)]
        it "finds no breach in real scaffolder output (aggregate + process fixtures)" $ do
            aggMods <- scaffoldFixture "test/fixtures/reservation.keiro"
            procMods <- scaffoldProcessFixture "test/fixtures/hospital-surge.keiro"
            firewallBreaches (aggMods <> procMods) `shouldBe` []

    describe "scaffold" $ do
        it "never emits a keiki symbolic operator into a Generated module (firewall)" $ do
            mods <- scaffoldFixture "test/fixtures/reservation.keiro"
            let breaches =
                    [ (modulePath m, op)
                    | m <- mods
                    , kind m == Generated
                    , op <- symbolicOperators
                    , op `T.isInfixOf` moduleText m
                    ]
            breaches `shouldBe` []
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
        it "matches the committed compiling Generated conformance modules (modulo whitespace)" $ do
            mods <- scaffoldFixture "test/fixtures/reservation.keiro"
            mapM_ assertMatchesCommitted [m | m <- mods, kind m == Generated]
        it "scaffolds the register-free OrderStream smoke target without error" $ do
            mods <- scaffoldFixture "test/fixtures/order.keiro"
            -- 5 Generated (Domain/Codec/EventStream/Projection/Harness) + 1 Holes.
            length mods `shouldBe` 6
            let breaches = [() | m <- mods, kind m == Generated, op <- symbolicOperators, op `T.isInfixOf` moduleText m]
            breaches `shouldBe` []

{- | Parse a fixture and return the validator's diagnostic codes (failing the
test on a parse error).
-}
diagnosticCodesOf :: FilePath -> IO [DiagnosticCode]
diagnosticCodesOf path = do
    input <- TIO.readFile path
    case parseSpec path input of
        Left err -> expectationFailure (T.unpack err) >> pure []
        Right spec -> pure (map code (validateSpec spec))

{- | Like 'diagnosticCodesOf' but only the Error-severity codes (warnings, e.g.
the benign-inversion notices, are excluded).
-}
errorCodesOf :: FilePath -> IO [DiagnosticCode]
errorCodesOf path = do
    input <- TIO.readFile path
    case parseSpec path input of
        Left err -> expectationFailure (T.unpack err) >> pure []
        Right spec -> pure [code d | d <- validateSpec spec, severity d == Error]

-- | Parse two fixtures and diff them (old, new).
diffFixtures :: FilePath -> FilePath -> IO [Change]
diffFixtures oldP newP = do
    old <- TIO.readFile oldP
    new <- TIO.readFile newP
    case (,) <$> parseSpec oldP old <*> parseSpec newP new of
        Left err -> expectationFailure (T.unpack err) >> pure []
        Right (o, n) -> pure (diffSpecs o n)

-- | The keiki symbolic operators that must never appear in a Generated module.
symbolicOperators :: [T.Text]
symbolicOperators = ["./=", ".==", ".||", ".&&", "lit ", "B.slot", "B.requireGuard"]

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

-- | Parse a fixture into a 'Spec', failing the test on a parse error.
specOf :: FilePath -> IO Spec
specOf path = do
    input <- TIO.readFile path
    case parseSpec path input of
        Left err -> expectationFailure (T.unpack err) >> error "unreachable"
        Right spec -> pure spec

-- | Parse a fixture and scaffold every aggregate in it.
scaffoldFixture :: FilePath -> IO [ScaffoldModule]
scaffoldFixture path = do
    input <- TIO.readFile path
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
    input <- TIO.readFile path
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
    committed <- TIO.readFile committedPath
    normalize committed `shouldBe` normalize (moduleText m)
  where
    -- Compare the deterministic body, robust to formatter-only changes. Import
    -- lines are dropped because fourmolu may reorder import-list items and move
    -- `qualified`; correctness of the imports is already proven by the
    -- keiro-dsl-conformance suite compiling. Commas are spaced before word
    -- normalization so leading-comma and trailing-comma export lists compare the
    -- same, while missing or reordered exported names still fail.
    normalize =
        T.replace " , )" " )"
            . T.unwords
            . T.words
            . T.replace "," " , "
            . T.unlines
            . filter (not . isImport)
            . T.lines
    isImport l = case T.words l of
        ("import" : _) -> True
        _ -> False

--------------------------------------------------------------------------------
-- Generators (bounded; restricted to valid, non-reserved identifiers)
--------------------------------------------------------------------------------

genName :: Gen Name
genName = do
    base <- elements ["Aa", "Bb", "Cc", "Dd", "St", "Cmd", "Ev", "Reg", "Fld", "Foo", "Bar", "Qux"]
    n <- choose (0, 9 :: Int)
    pure (T.pack (base <> show n))

genWire :: Gen T.Text
genWire = do
    base <- elements ["red", "blue", "green", "ctorName", "camelCase", "rsv", "hosp", "held"]
    n <- choose (0, 9 :: Int)
    pure (T.pack (base <> show n))

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
genReg = RegDecl <$> genName <*> genName <*> genName <*> pure noLoc

genState :: Gen StateDecl
genState = StateDecl <$> genName <*> arbitrary <*> pure noLoc

genCommand :: Gen Command
genCommand = Command <$> genName <*> smallList genField <*> pure noLoc

genEvent :: Gen Event
genEvent =
    Event
        <$> genName
        <*> body
        <*> choose (1, 3)
        <*> genMaybe ((,) <$> choose (0, 3) <*> pure Hole)
        <*> arbitrary
        <*> pure noLoc
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
        <*> pure noLoc

genWireSpec :: Gen WireSpec
genWireSpec = WireSpec <$> genWire <*> genWire <*> (getNonNegative <$> arbitrary)

genProjection :: Gen ProjectionSpec
genProjection =
    ProjectionSpec
        <$> genName
        <*> elements [Strong, Eventual]
        <*> genName
        <*> genMaybe (Mapping <$> smallList ((,) <$> genName <*> genWire) <*> pure False)
        <*> pure noLoc

genAggregate :: Gen Aggregate
genAggregate =
    Aggregate
        <$> genName
        <*> smallList genReg
        <*> nonEmptyList genState
        <*> smallList genCommand
        <*> smallList genEvent
        <*> smallList genTransition
        <*> genMaybe genWireSpec
        <*> genMaybe genProjection
        <*> pure noLoc

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
        <*> smallList (NAggregate <$> genAggregate)

-- | A dotted PascalCase module prefix, e.g. @Acme@ or @Acme.Services@.
genModuleRoot :: Gen T.Text
genModuleRoot = do
    n <- choose (1, 3 :: Int)
    segs <- vectorOf n (elements ["Acme", "Services", "Hospital", "Domain", "Core"])
    pure (T.intercalate "." segs)
