{- | Test driver for keiro-dsl. EP-1 milestone 1 tests: the @parse . pretty@
round-trip property over generated specs, and a unit test pinning the shape
of the canonical Reservation fixture.
-}
module Main (main) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), diffSpecs, isBreaking)
import Keiro.Dsl.Grammar
import Keiro.Dsl.Harness (harnessFor)
import Keiro.Dsl.Parser (parseSpec)
import Keiro.Dsl.PrettyPrint (renderSpec)
import Keiro.Dsl.Scaffold (Context (..), ModuleKind (..), ScaffoldModule (..), scaffoldAggregate, scaffoldProcess)
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode (..), Severity (..), validateSpec)
import Test.Hspec hiding (Spec)
import Test.QuickCheck

main :: IO ()
main = hspec $ do
    describe "parse . pretty round-trip" $
        it "re-parses any generated spec to an equal AST (modulo source locations)" $
            forAll genSpec $ \s ->
                parseSpec "<gen>" (renderSpec s) === Right s

    describe "canonical reservation.kdsl" $
        it "parses into the expected aggregate shape" $ do
            input <- TIO.readFile "test/fixtures/reservation.kdsl"
            case parseSpec "test/fixtures/reservation.kdsl" input of
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
        it "accepts the canonical reservation.kdsl" $ do
            codes <- diagnosticCodesOf "test/fixtures/reservation.kdsl"
            codes `shouldBe` []
        it "rejects a missing status-map as StatusMapNotTotal" $ do
            codes <- diagnosticCodesOf "test/fixtures/reservation-no-statusmap.kdsl"
            codes `shouldContain` [StatusMapNotTotal]
        it "rejects an undeclared command as UndeclaredCommand" $ do
            codes <- diagnosticCodesOf "test/fixtures/reservation-bad-command.kdsl"
            codes `shouldContain` [UndeclaredCommand]
        it "rejects a wall-clock guard atom as ClockSampled" $ do
            codes <- diagnosticCodesOf "test/fixtures/reservation-clock.kdsl"
            codes `shouldContain` [ClockSampled]
        it "accepts a v2 event with a contiguous upcaster hole" $ do
            codes <- diagnosticCodesOf "test/fixtures/reservation-v2.kdsl"
            codes `shouldBe` []
        it "rejects a v2 event with no upcaster as EvtVersionMissingUpcaster" $ do
            codes <- diagnosticCodesOf "test/fixtures/reservation-v2-noupcast.kdsl"
            codes `shouldContain` [EvtVersionMissingUpcaster]

    describe "evolution parsing" $
        it "parses event version and upcaster from reservation-v2.kdsl" $ do
            input <- TIO.readFile "test/fixtures/reservation-v2.kdsl"
            case parseSpec "test/fixtures/reservation-v2.kdsl" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> case [e | NAggregate a <- specNodes spec, e <- aggEvents a, evName e == "TransferReservationCreated"] of
                    (e : _) -> do
                        evVersion e `shouldBe` 2
                        evUpcastFrom e `shouldBe` Just (1, Hole)
                    [] -> expectationFailure "TransferReservationCreated not found"

    describe "process/timer (EP-3)" $ do
        it "parses the hospital-surge process + nested timer" $ do
            input <- TIO.readFile "test/fixtures/hospital-surge.kdsl"
            case parseSpec "test/fixtures/hospital-surge.kdsl" input of
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
            input <- TIO.readFile "test/fixtures/hospital-surge.kdsl"
            case parseSpec "in" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
        it "accepts the hospital-surge spec (no errors; benign-inversion warnings only)" $ do
            codes <- errorCodesOf "test/fixtures/hospital-surge.kdsl"
            codes `shouldBe` []
        it "rejects a wall-clock fireAt as ProcessFireAtNotInjected" $ do
            codes <- errorCodesOf "test/fixtures/hospital-surge-clock.kdsl"
            codes `shouldContain` [ProcessFireAtNotInjected]
        it "rejects a user-supplied dispatch id as ProcessDispatchIdSupplied" $ do
            codes <- errorCodesOf "test/fixtures/hospital-surge-dispatchid.kdsl"
            codes `shouldContain` [ProcessDispatchIdSupplied]
        it "rejects an unresolved saga reference as ProcessUnresolvedRef" $ do
            codes <- errorCodesOf "test/fixtures/hospital-surge-badref.kdsl"
            codes `shouldContain` [ProcessUnresolvedRef]
        it "scaffolds the process: Generated wiring is firewall-clean + a HoleStub" $ do
            mods <- scaffoldProcessFixture "test/fixtures/hospital-surge.kdsl"
            let gens = [m | m <- mods, kind m == Generated]
                holes = [m | m <- mods, kind m == HoleStub]
            length gens `shouldBe` 1
            length holes `shouldBe` 1
            [() | m <- gens, op <- symbolicOperators, op `T.isInfixOf` moduleText m] `shouldBe` []
            -- the worker uses the spec's ceiling, never the dangerous default
            ("max-attempts = 5" `T.isInfixOf` moduleText (head gens)) `shouldBe` True
        it "process scaffold is deterministic" $ do
            a <- scaffoldProcessFixture "test/fixtures/hospital-surge.kdsl"
            b <- scaffoldProcessFixture "test/fixtures/hospital-surge.kdsl"
            map moduleText a `shouldBe` map moduleText b

    describe "contract (EP-4)" $ do
        it "parses the emergency contract (topics + events-on-topic + typed fields)" $ do
            input <- TIO.readFile "test/fixtures/contract.kdsl"
            case parseSpec "test/fixtures/contract.kdsl" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> case [c | NContract c <- specNodes spec] of
                    (c : _) -> do
                        ctrName c `shouldBe` "emergency"
                        ctrDiscriminator c `shouldBe` "messageType"
                        map fst (ctrTopics c) `shouldBe` ["incidentEvents", "hospitalEvents"]
                        map ceName (ctrEvents c) `shouldBe` ["IncidentTransferNeedDeclared", "TransferReservationAccepted"]
                    [] -> expectationFailure "no contract node parsed"
        it "round-trips the contract spec through parse . pretty" $ do
            input <- TIO.readFile "test/fixtures/contract.kdsl"
            case parseSpec "in" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
        it "round-trips the intake (inbox) spec through parse . pretty" $ do
            input <- TIO.readFile "test/fixtures/intake.kdsl"
            case parseSpec "in" input of
                Left err -> expectationFailure (T.unpack err)
                Right spec -> parseSpec "in" (renderSpec spec) `shouldBe` Right spec
        it "accepts the intake spec (complete disposition, no inversions)" $ do
            codes <- errorCodesOf "test/fixtures/intake.kdsl"
            codes `shouldBe` []
        it "rejects duplicate => retry (inversion 1)" $ do
            codes <- errorCodesOf "test/fixtures/intake-dup-retry.kdsl"
            codes `shouldContain` [DispositionDuplicateRetry]
        it "rejects previouslyFailed => retry (inversion 2)" $ do
            codes <- errorCodesOf "test/fixtures/intake-pf-retry.kdsl"
            codes `shouldContain` [DispositionPreviouslyFailedRetry]
        it "rejects an incomplete disposition table" $ do
            codes <- errorCodesOf "test/fixtures/intake-incomplete.kdsl"
            codes `shouldContain` [DispositionIncomplete]

    describe "diff (evolution classification)" $ do
        it "classifies a field added without a version bump as BREAKING" $ do
            cs <- diffFixtures "test/fixtures/reservation.kdsl" "test/fixtures/reservation-fieldadd.kdsl"
            any isBreaking cs `shouldBe` True
            [ckCode k | Breaking k <- cs] `shouldContain` [Just EvtFieldAddedWithoutBump]
        it "classifies the same field wrapped as v2 + upcaster as ADDITIVE" $ do
            cs <- diffFixtures "test/fixtures/reservation.kdsl" "test/fixtures/reservation-v2.kdsl"
            any isBreaking cs `shouldBe` False
            [ck | Additive ck <- cs] `shouldSatisfy` any ((== "TransferReservationCreated") . ckSubject)
        it "reports no breaking change when the spec is unchanged" $ do
            cs <- diffFixtures "test/fixtures/reservation.kdsl" "test/fixtures/reservation.kdsl"
            any isBreaking cs `shouldBe` False

    describe "scaffold" $ do
        it "never emits a keiki symbolic operator into a Generated module (firewall)" $ do
            mods <- scaffoldFixture "test/fixtures/reservation.kdsl"
            let breaches =
                    [ (modulePath m, op)
                    | m <- mods
                    , kind m == Generated
                    , op <- symbolicOperators
                    , op `T.isInfixOf` moduleText m
                    ]
            breaches `shouldBe` []
        it "marks the Holes module HoleStub and the rest Generated" $ do
            mods <- scaffoldFixture "test/fixtures/reservation.kdsl"
            let holes = [m | m <- mods, "Holes.hs" `T.isSuffixOf` T.pack (modulePath m)]
            map kind holes `shouldBe` [HoleStub]
            -- Domain, Codec, EventStream, Projection, Harness.
            length [m | m <- mods, kind m == Generated] `shouldBe` 5
        it "is deterministic (re-scaffolding yields byte-identical text)" $ do
            a <- scaffoldFixture "test/fixtures/reservation.kdsl"
            b <- scaffoldFixture "test/fixtures/reservation.kdsl"
            map moduleText a `shouldBe` map moduleText b
        it "matches the committed compiling Generated conformance modules (modulo whitespace)" $ do
            mods <- scaffoldFixture "test/fixtures/reservation.kdsl"
            mapM_ assertMatchesCommitted [m | m <- mods, kind m == Generated]
        it "scaffolds the register-free OrderStream smoke target without error" $ do
            mods <- scaffoldFixture "test/fixtures/order.kdsl"
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
    ctx spec = Context{contextName = specContext spec, moduleRoot = ""}

scaffoldProcessFixture :: FilePath -> IO [ScaffoldModule]
scaffoldProcessFixture path = do
    input <- TIO.readFile path
    case parseSpec path input of
        Left err -> expectationFailure (T.unpack err) >> pure []
        Right spec ->
            pure $ concat [scaffoldProcess (ctx spec) p | NProcess p <- specNodes spec]
  where
    ctx spec = Context{contextName = specContext spec, moduleRoot = ""}

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
    -- Compare the deterministic body, robust to formatting. Import lines are
    -- dropped because the autoformatter (fourmolu) may reorder import-list items
    -- and move `qualified`; correctness of the imports is already proven by the
    -- keiro-dsl-conformance suite compiling. Everything else (types, codec,
    -- wiring) is whitespace-normalized.
    normalize = T.unwords . T.words . T.unlines . filter (not . isImport) . T.lines
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
genState = StateDecl <$> genName <*> arbitrary

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
        <*> smallList genId
        <*> smallList genEnum
        <*> smallList genRule
        <*> smallList (NAggregate <$> genAggregate)
