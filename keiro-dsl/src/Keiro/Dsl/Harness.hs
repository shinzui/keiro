-- | The harness engine. From an aggregate spec it emits a @-- \@generated@ test
-- module that __pins the filled holes' behaviour__ — the project's actual
-- determinism guarantee, since the scaffolder no longer produces the transducer
-- body by construction. The emitted module exposes @harnessAssertions ::
-- [(String, Bool)]@, a list of labelled checks a driver runs (failing on any
-- @False@, naming the assertion). The checks are:
--
--   1. keiki's @validateTransducer defaultValidationOptions@ on the filled
--      transducer is empty (no hidden inputs / nondeterminism / dead edges);
--   2. a /clock-free/ assertion baked from the spec (TIME IS INJECTED, NOT
--      SAMPLED) — @False@ would mean a guard\/write sampled a wall clock;
--   3. a golden wire round-trip per event (@decode . encode == id@);
--   4. a behavioural /accept/ check per transition out of the initial state:
--      stepping a sample command lands on the declared @goto@ vertex. This is the
--      check a wrong guard fails — flipping @./=@ to @.==@ in the filled body turns
--      it red while leaving the scaffold untouched.
--   5. a forward/replay equality check per live, event-emitting transition out of
--      the initial state: emitted events cross the generated codec boundary, then
--      replay must reconstruct the forward vertex and every declared register.
--
-- @Text@ samples include their field name so same-typed field swaps remain visible
-- to the replay check. Other sample kinds remain uniform until fixture bindings can
-- supply a wider, consumer-owned corpus.
module Keiro.Dsl.Harness
  ( harnessFor,
    harnessForWithGoldens,
    harnessProcess,
    harnessRouter,
    harnessReadModel,
    harnessWorkflow,
  )
where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.AggregateType
import Keiro.Dsl.Goldens (GoldenPayload (..))
import Keiro.Dsl.Grammar
import Keiro.Dsl.NominalType
import Keiro.Dsl.ReadModelShape (deriveShapeHash, registryNameFor, subscriptionNameFor)
import Keiro.Dsl.Scaffold
import Keiro.Dsl.TypeGraph

-- | Emit the harness test module for one aggregate. Like 'scaffoldAggregate',
-- it takes the 'Spec' for the shared id\/enum declarations.
harnessFor :: Context -> Spec -> Aggregate -> [ScaffoldModule]
harnessFor = harnessForWithGoldens []

-- | Emit an aggregate harness with checked-in old-payload fixtures embedded
-- as string literals. Embedding keeps the generated test independent of runtime
-- file paths while retaining the golden file as regeneration source of truth.
harnessForWithGoldens :: [GoldenPayload] -> Context -> Spec -> Aggregate -> [ScaffoldModule]
harnessForWithGoldens goldens ctx spec agg =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" (aGenPrefix a) <> "/Harness.hs"),
        moduleText = emitHarness relevantGoldens a,
        kind = Generated,
        origin = "aggregate " <> aggName agg <> locSuffix (aggLoc agg)
      }
  ]
  where
    a = resolveAgg ctx spec agg
    relevantGoldens =
      [ golden
      | golden <- goldens,
        goldenContext golden == specContext spec,
        goldenAggregate golden == aggName agg
      ]

-- | Emit a self-contained, firewall-clean facts harness for a process manager,
-- pinning the spec's deterministic decisions: the time-injection formula, the
-- deterministic timer-id and fired-event-id derivation strings, the runtime-owned
-- dispatch-id (no user id), and the dispatch\/fire disposition tables (incl. the
-- @on-reject => Fired@ benign inversion). It exposes
-- @processHarnessFacts :: [(String, Bool)]@ over pure values, so it compiles and
-- runs without the effectful\/hasql runtime. (Behavioural conformance of the
-- /filled/ ProcessManager against the live runtime is the M5 step.)
harnessProcess :: Context -> ProcessNode -> [ScaffoldModule]
harnessProcess ctx p =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/ProcessHarness.hs"),
        moduleText = emitProcessHarness genPrefix p,
        kind = Generated,
        origin = "process " <> procId p <> locSuffix (procLoc p)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (procId p)

-- | Emit runtime-free facts for a router's identity, resolution, dispatch,
-- and worker-policy decisions. A hand-written conformance driver owns the
-- expected values so a spec mutation turns one focused assertion red.
harnessRouter :: Context -> RouterNode -> [ScaffoldModule]
harnessRouter ctx router =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/RouterHarness.hs"),
        moduleText = emitRouterHarness genPrefix router,
        kind = Generated,
        origin = "router " <> rtId router <> locSuffix (rtLoc router)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (rtId router)

emitRouterHarness :: Text -> RouterNode -> Text
emitRouterHarness genPrefix router =
  nl
    [ generatedBanner,
      "module " <> genPrefix <> ".RouterHarness (routerHarnessValues) where",
      "",
      "routerHarnessValues :: [(String, String)]",
      "routerHarnessValues =",
      "  [ (\"routerName\", " <> hs (rtName router) <> ")",
      "  , (\"keyField\", " <> hs (corrField (rtKey router)) <> ")",
      "  , (\"resolveSource\", " <> hs resolveSource <> ")",
      "  , (\"resolveRow\", " <> hs (T.intercalate "," (rvRow (rtResolve router))) <> ")",
      "  , (\"dispatchCommand\", " <> hs (rdCommand dispatch) <> ")",
      "  , (\"dispatchIdInputs\", \"(name, key, sourceEventId, targetStreamName, occurrence)\")",
      "  , (\"onDuplicate\", " <> hs (showDisp (onDuplicate disposition)) <> ")",
      "  , (\"onFailed\", " <> hs (showDisp (onFailed disposition)) <> ")",
      "  , (\"rejectedPolicy\", " <> hs (showPolicy (rtRejected router)) <> ")",
      "  , (\"poisonPolicy\", " <> hs (showPolicy (rtPoison router)) <> ")",
      "  ]"
    ]
  where
    hs = tshow
    dispatch = rtDispatch router
    disposition = rdDisposition dispatch
    resolveSource = case rvSource (rtResolve router) of
      ResolveReadModel name -> "read-model " <> name
      ResolveHole -> "hole"

-- | Emit runtime-free facts for a read-model node. Each row records the value
-- expected directly from the notation next to the value produced by the shared
-- derivation helpers. Committed conformance expectations pin the lowered values,
-- while a shape-fixture drift makes the generated harness itself fail.
harnessReadModel :: Context -> ReadModelNode -> [ScaffoldModule]
harnessReadModel ctx readModel =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/ReadModelHarness.hs"),
        moduleText = emitReadModelHarness genPrefix ctx readModel,
        kind = Generated,
        origin = "readmodel " <> rmName readModel <> locSuffix (rmLoc readModel)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (pascal (rmName readModel))

emitReadModelHarness :: Text -> Context -> ReadModelNode -> Text
emitReadModelHarness genPrefix ctx readModel =
  nl
    [ generatedBanner,
      "module " <> genPrefix <> ".ReadModelHarness (readModelFacts, runReadModelFacts) where",
      "",
      "-- | (fact, expected from notation, actual shared derivation/lowering).",
      "readModelFacts :: [(String, String, String)]",
      "readModelFacts =",
      "  [ (\"registryName\", " <> tshow expectedRegistry <> ", " <> tshow actualRegistry <> ")",
      "  , (\"subscriptionName\", " <> tshow expectedSubscription <> ", " <> tshow actualSubscription <> ")",
      "  , (\"shapeHash\", " <> tshow (rmShape readModel) <> ", " <> tshow (deriveShapeHash readModel) <> ")",
      "  , (\"asyncProjectionName\", " <> tshow expectedAsync <> ", " <> tshow actualAsync <> ")",
      "  , (\"consistency\", " <> tshow consistency <> ", " <> tshow consistency <> ")",
      "  , (\"strongScope\", " <> tshow scope <> ", " <> tshow scope <> ")",
      "  ]",
      "",
      "runReadModelFacts :: IO Bool",
      "runReadModelFacts = do",
      "  let failures = [(fact, expected, actual) | (fact, expected, actual) <- readModelFacts, expected /= actual]",
      "  mapM_ (\\(fact, expected, actual) -> putStrLn (\"FAIL  \" <> fact <> \" expected=\" <> show expected <> \" actual=\" <> show actual)) failures",
      "  pure (null failures)"
    ]
  where
    expectedRegistry = contextName ctx <> "-" <> T.replace "_" "-" (rmName readModel)
    actualRegistry = registryNameFor (contextName ctx) readModel
    expectedSubscription = case rmSubscription readModel of
      Just name -> name
      Nothing -> expectedRegistry <> "-sub"
    actualSubscription = subscriptionNameFor (contextName ctx) readModel
    expectedAsync = case rmFeed readModel of
      RmInline -> "none"
      RmSubscription -> expectedRegistry <> "-async"
    actualAsync = case rmFeed readModel of
      RmInline -> "none"
      RmSubscription -> actualRegistry <> "-async"
    consistency = case rmConsistency readModel of
      Strong -> "Strong"
      Eventual -> "Eventual"
    scope = case rmScope readModel of
      Nothing -> "EntireLog"
      Just RmEntireLog -> "EntireLog"
      Just (RmCategory categoryName) -> "CategoryHead " <> categoryName

emitProcessHarness :: Text -> ProcessNode -> Text
emitProcessHarness genPrefix p =
  nl
    [ generatedBanner,
      "module " <> genPrefix <> ".ProcessHarness (processHarnessValues) where",
      "",
      "{- | (label, value): the spec's deterministic process/timer decisions,",
      "lowered to plain values so a driver can assert them against a committed",
      "expectation. The driver's expectation is hand-written (not generated), so a",
      "spec change that alters a decision diverges from it and turns a specific",
      "assertion red — the spec->behaviour pin. (Live-runtime behavioural",
      "conformance of the filled ProcessManager is the M5 step.)",
      "-}",
      "processHarnessValues :: [(String, String)]",
      "processHarnessValues =",
      "  [ (\"fireAtField\", " <> hs (faField (tmFireAt timer)) <> ")",
      "  , (\"timerIdPrefix\", " <> hs (idePrefix (tmId timer)) <> ")",
      "  , (\"firedEventIdPrefix\", " <> hs (idePrefix (fireFiredEventId timer')) <> ")",
      "  , (\"dispatchIdUserField\", \"none\")",
      "  , (\"onReject\", " <> hs (showFireOutcome (onReject fd)) <> ")",
      "  , (\"onAmbiguous\", " <> hs (showFireOutcome (onAmbiguous fd)) <> ")",
      "  , (\"onFailed\", " <> hs (showDisp (onFailed (firstDispDisposition p))) <> ")",
      "  , (\"rejectedPolicy\", " <> hs (showPolicy (procRejected p)) <> ")",
      "  , (\"poisonPolicy\", " <> hs (showPolicy (procPoison p)) <> ")",
      "  , (\"maxAttempts\", " <> hs (tInt (tmMaxAttempts timer)) <> ")",
      "  ]"
    ]
  where
    timer = procTimer p
    timer' = tmFire timer
    fd = fireDisposition timer'
    hs = tshow

firstDispDisposition :: ProcessNode -> DispatchDisposition
firstDispDisposition p = case hDispatch (procHandle p) of
  (d : _) -> dispDisposition d
  [] -> DispatchDisposition DAckOk DAckOk DRetry

showFireOutcome :: FireOutcome -> Text
showFireOutcome OFired = "Fired"
showFireOutcome ORetry = "Retry"

showDisp :: Disp -> Text
showDisp DAckOk = "AckOk"
showDisp DRetry = "Retry"
showDisp (DDeadLetter _) = "DeadLetter"

showPolicy :: PolicyChoice -> Text
showPolicy PolHalt = "halt"
showPolicy PolDeadLetter = "deadLetter"
showPolicy PolSkip = "skip"

-- | A self-contained, firewall-clean facts harness for a durable workflow,
-- pinning the spec's deterministic decisions: the stable name, the WorkflowId
-- derivation, the ordered body (step/await/sleep/child by label), and the await
-- labels (whose ids the signal operations must match). Exposes
-- @workflowFacts :: [(String, String)]@ so a driver asserts them against a
-- hand-written expectation — a spec change (e.g. renaming an await label) diverges
-- and reddens a specific assertion. Workflows intentionally have no domain scaffold
-- or hole stub: their behaviour-bearing body remains hand-written, while these facts
-- and the live-runtime module pin its declared structure.
harnessWorkflow :: Context -> WorkflowNode -> [ScaffoldModule]
harnessWorkflow ctx w =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/WorkflowFacts.hs"),
        moduleText = emitWorkflowFacts genPrefix w,
        kind = Generated,
        origin = "workflow " <> wfId w <> locSuffix (workflowNodeLoc w)
      },
    ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/WorkflowRuntime.hs"),
        moduleText = emitWorkflowRuntime genPrefix w,
        kind = Generated,
        origin = "workflow " <> wfId w <> locSuffix (workflowNodeLoc w)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (wfId w)

locSuffix :: Loc -> Text
locSuffix loc = case unLoc loc of
  0 -> ""
  line -> " (line " <> tInt line <> ")"

emitWorkflowFacts :: Text -> WorkflowNode -> Text
emitWorkflowFacts genPrefix w =
  nl
    [ generatedBanner,
      "module " <> genPrefix <> ".WorkflowFacts (workflowFacts) where",
      "",
      "{- | (label, value): the workflow's deterministic decisions, pinned as pure",
      "facts. A driver asserts them against a hand-written expectation, so a spec",
      "change (e.g. renaming an await) reddens a specific assertion.",
      "-}",
      "workflowFacts :: [(String, String)]",
      "workflowFacts =",
      "  [ (\"name\", " <> hs (wfStable w) <> ")",
      "  , (\"idVia\", " <> hs (wfIdVia w) <> ")",
      "  , (\"idField\", " <> hs (maybe "input" id (wfIdField w)) <> ")",
      "  , (\"body\", " <> hs (T.intercalate "," (map bodyTag (wfBody w))) <> ")",
      "  , (\"awaits\", " <> hs (T.intercalate "," (workflowAwaitLabels (wfBody w))) <> ")",
      "  , (\"patches\", " <> hs (T.intercalate "," (workflowPatchIds (wfBody w))) <> ")",
      "  ]"
    ]
  where
    hs = tshow
    bodyTag (WfStep l _ _) = "step:" <> l
    bodyTag (WfAwait l _ _) = "await:" <> l
    bodyTag (WfSleep l _ _) = "sleep:" <> l
    bodyTag (WfChild l _ _ _) = "child:" <> l
    bodyTag (WfPatch patchId items _) = "patch:" <> patchId <> "(" <> T.intercalate "," (map bodyTag items) <> ")"
    bodyTag (WfContinueAsNew seedType _) = "continueAsNew:" <> seedType

-- | Emit the workflow's deterministic id derivation compiled against the LIVE
-- @Keiro.Workflow@: the 'WorkflowName' and the awakeable-id function (the actual
-- 'deterministicAwakeableId'). A signal operation deriving the SAME (name, id,
-- label) lands on the same 'AwakeableId' — so this module compiling + the
-- conformance comparing the two sides proves the await↔signal coupling holds over
-- the real runtime function, not just by label-string equality.
emitWorkflowRuntime :: Text -> WorkflowNode -> Text
emitWorkflowRuntime genPrefix w =
  nl $
    [ generatedBanner,
      "module " <> genPrefix <> ".WorkflowRuntime",
      "  ( workflowName",
      "  , awaitAwakeableId",
      "  , awaitLabels",
      "  , declaredPatches",
      "  , declaredPatchStepNames",
      "  , withDeclaredPatches",
      "  ) where",
      "",
      "import Data.Set (Set)",
      "import Data.Set qualified as Set",
      "import Data.Text (Text)",
      "import Keiro.Workflow (WorkflowRunOptions (..))",
      "import Keiro.Workflow.Awakeable (AwakeableId, deterministicAwakeableId)",
      "import Keiro.Workflow.Types (PatchId (..), WorkflowId, WorkflowName (..), patchStepName)",
      "",
      "workflowName :: WorkflowName",
      "workflowName = WorkflowName " <> tshow (wfStable w),
      "",
      "-- The awakeable id an await allocates — the real deterministicAwakeableId.",
      "-- A signal op deriving the same (name, id, label) gets the same id.",
      "awaitAwakeableId :: WorkflowId -> Text -> AwakeableId",
      "awaitAwakeableId wid label = deterministicAwakeableId workflowName wid label",
      "",
      "awaitLabels :: [Text]",
      "awaitLabels = [" <> T.intercalate ", " (map tshow (workflowAwaitLabels (wfBody w))) <> "]",
      "",
      "declaredPatches :: Set PatchId",
      "declaredPatches = Set.fromList [" <> T.intercalate ", " ["PatchId " <> tshow patchId | patchId <- workflowPatchIds (wfBody w)] <> "]",
      "",
      "-- The journal keys the runtime records patch decisions under.",
      "declaredPatchStepNames :: [Text]",
      "declaredPatchStepNames = map patchStepName (Set.toList declaredPatches)",
      "",
      "-- Activate exactly the patches declared by this spec for a workflow run.",
      "withDeclaredPatches :: WorkflowRunOptions -> WorkflowRunOptions",
      "withDeclaredPatches opts = opts{activePatches = declaredPatches}"
    ]

workflowAwaitLabels :: [WfBodyItem] -> [Name]
workflowAwaitLabels = concatMap go
  where
    go (WfAwait label _ _) = [label]
    go (WfPatch _ items _) = workflowAwaitLabels items
    go _ = []

workflowPatchIds :: [WfBodyItem] -> [Name]
workflowPatchIds = concatMap go
  where
    go (WfPatch patchId items _) = patchId : workflowPatchIds items
    go _ = []

emitHarness :: [GoldenPayload] -> Agg -> Text
emitHarness goldens a =
  nl $
    [ "{-# LANGUAGE DataKinds #-}",
      "{-# LANGUAGE OverloadedLabels #-}"
    ]
      ++ ["{-# LANGUAGE TypeApplications #-}" | hasMappedHarness a]
      ++ [ generatedBanner,
           "module " <> aGenPrefix a <> ".Harness (harnessAssertions) where",
           "",
           "import " <> aGenPrefix a <> ".Domain",
           "import " <> aGenPrefix a <> ".Codec (encode" <> nm <> "Event, parse" <> nm <> "Event" <> codecValueImport <> mappedCodecHarnessExports a <> ")",
           transducerImport a,
           "import Keiki.Core (" <> T.intercalate ", " coreImports <> ")",
           codecDecodeRawImport
         ]
      ++ generatedNominalTypeImports (aContext a) (generatedNominalHarnessTypes a)
      ++ mappedHarnessImports a
      ++ nominalHarnessImports a
      ++ aggregateHarnessImports a
      ++ goldenImports
      ++ [ "",
           "{- | (label, passed). A driver runs these and exits non-zero on any False,",
           "naming the failing assertion. Filling a hole wrongly turns a specific",
           "entry False; the scaffold cannot.",
           "-}",
           "harnessAssertions :: [(String, Bool)]",
           "harnessAssertions =",
           "  [ (\"validateTransducer is empty\", null (validateTransducer defaultValidationOptions " <> lowerFirst nm <> "Transducer))",
           "  , (\"clock-free: spec samples no wall clock\", " <> clockFreeLit <> ")"
         ]
      ++ [ "  , (\"golden round-trip: " <> rcName e <> "\", roundTrips sampleEvent" <> rcName e <> ")"
         | e <- aEvents a
         ]
      ++ [ "  , (\"accepts " <> tCommand t <> " from " <> initialVertex a <> "\", accept" <> tCommand t <> ")"
         | t <- initialTransitions a
         ]
      ++ [ "  ]"
         ]
      ++ ["  ++ mappedConformanceAssertions" | hasMappedHarness a]
      ++ ["  ++ nominalConformanceAssertions" | hasNominalHarness a]
      ++ [ "  ++ forwardReplay" <> tCommand t
         | t <- replayTransitions
         ]
      ++ ( if null upcastEvents
             then []
             else
               [ "  ++ [ " <> T.intercalate "\n     , " upcastAssertions,
                 "     ]"
               ]
         )
      ++ [ "",
           "roundTrips :: " <> nm <> "Event -> Bool",
           "roundTrips e = parse" <> nm <> "Event (eventType " <> lowerFirst nm <> "Codec e) (encode" <> nm <> "Event e) == Right e"
         ]
      ++ concatMap (sampleEventDecl a) (aEvents a)
      ++ concatMap (acceptDecl a) (initialTransitions a)
      ++ concatMap (forwardReplayDecl a) replayTransitions
      ++ concatMap (upcastDecl goldens a) upcastEvents
      ++ mappedHarnessDeclarations a
      ++ nominalHarnessDeclarations a
  where
    nm = aName a
    -- Bake the clock-free result computed from the spec at scaffold time.
    clockFreeLit = if specIsClockFree a then "True" else "False"
    upcastEvents = [e | e <- aEvents a, rcUpcastFrom e /= Nothing]
    replayTransitions =
      [ t
      | t <- initialTransitions a,
        tMode t == TmLive,
        not (null (tEmits t))
      ]
    coreImports =
      ["applyEventsEither" | not (null replayTransitions)]
        ++ ["defaultValidationOptions", "step", "validateTransducer"]
        ++ ["fieldWitnessAgrees" | not (null (mappedProjectionSpecs a)) || not (null (nominalScalarHarnessTypes a))]
        ++ ["(!)" | not (null replayTransitions) && not (null (aRegs a))]
    upcastAssertions =
      [ "(" <> tshow (upcastLabel e m) <> ", upcasts" <> rcName e <> ")"
      | e <- upcastEvents,
        Just m <- [rcUpcastFrom e]
      ]
    codecValueImport = ", " <> lowerFirst nm <> "Codec"
    codecDecodeRawImport =
      if null upcastEvents
        then "import Keiro.Codec (eventType)"
        else "import Keiro.Codec (EventType (..), decodeRaw, eventType)"
    goldenImports =
      if any (hasGolden goldens) upcastEvents
        then
          [ "import Data.Aeson (eitherDecodeStrict)",
            "import Data.Text.Encoding (encodeUtf8)"
          ]
        else []

    upcastLabel event source =
      case goldenFor goldens event of
        Just _ -> "golden " <> rcName event <> ".v" <> tInt source <> " decodes"
        Nothing ->
          "upcast "
            <> rcName event
            <> " chain wired (current-shape stand-in; add a golden payload)"

transducerImport :: Agg -> Text
transducerImport aggregate
  | usesGeneratedTransducer aggregate =
      "import "
        <> aGenPrefix aggregate
        <> ".Transducer ("
        <> lowerFirst (aName aggregate)
        <> "Transducer)"
  | otherwise =
      "import "
        <> aHolePrefix aggregate
        <> ".Holes ("
        <> lowerFirst (aName aggregate)
        <> "Transducer)"

usesGeneratedTransducer :: Agg -> Bool
usesGeneratedTransducer = any ((/= LegacyHoleImplementation) . tImplementation) . aTransitions

-- | Decode a genuine embedded old payload when available. Without a golden,
-- retain the weaker current-shape wiring assertion and label it honestly.
upcastDecl :: [GoldenPayload] -> Agg -> ResolvedCtor -> [Text]
upcastDecl goldens a e = case rcUpcastFrom e of
  Nothing -> []
  Just m -> case goldenFor goldens e of
    Just golden ->
      [ "",
        "upcasts" <> rcName e <> " :: Bool",
        "upcasts" <> rcName e <> " =",
        "  case eitherDecodeStrict (encodeUtf8 " <> tshow (goldenJson golden) <> ") of",
        "    Left _ -> False",
        "    Right payload ->",
        "      either (const False) (const True)",
        "        (decodeRaw " <> lowerFirst (aName a) <> "Codec (EventType " <> tshow (rcName e) <> ") " <> tInt m <> " payload)"
      ]
    Nothing ->
      [ "",
        "upcasts" <> rcName e <> " :: Bool",
        "upcasts" <> rcName e <> " =",
        "  either (const False) (const True)",
        "    (decodeRaw " <> lowerFirst (aName a) <> "Codec (EventType " <> tshow (rcName e) <> ") " <> tInt m <> " (encode" <> aName a <> "Event sampleEvent" <> rcName e <> "))"
      ]

hasGolden :: [GoldenPayload] -> ResolvedCtor -> Bool
hasGolden goldens event = case goldenFor goldens event of
  Just _ -> True
  Nothing -> False

goldenFor :: [GoldenPayload] -> ResolvedCtor -> Maybe GoldenPayload
goldenFor goldens event = do
  source <- rcUpcastFrom event
  find
    (\golden -> goldenEvent golden == rcName event && goldenVersion golden == source)
    goldens

tInt :: Int -> Text
tInt = T.pack . show

-- | Render a Text as a Haskell string literal (quoted, escaped).
tshow :: Text -> Text
tshow = T.pack . show

nl :: [Text] -> Text
nl = T.intercalate "\n"

specIsClockFree :: Agg -> Bool
specIsClockFree a = not (any transitionSamplesClock (aTransitions a))
  where
    clockAtoms = ["now", "currentTime", "wallClock", "today", "utcNow"]
    transitionSamplesClock t =
      let exprs = maybe [] pure (tGuard t) ++ map snd (tWrites t)
       in any (\e -> any (`elem` clockAtoms) (exprNames e)) exprs

exprNames :: Expr -> [Text]
exprNames (EOr x y) = exprNames x ++ exprNames y
exprNames (EAnd x y) = exprNames x ++ exprNames y
exprNames (ECmp _ x y) = exprNames x ++ exprNames y
exprNames (EAdd _ x y) = exprNames x ++ exprNames y
exprNames (ESubtract _ x y) = exprNames x ++ exprNames y
exprNames (EMultiply _ x y) = exprNames x ++ exprNames y
exprNames (EPath _ _ (name : _)) = [name]
exprNames (EPath _ _ []) = []
exprNames ELiteral {} = []
exprNames (EAtom (AName n)) = [n]
exprNames (EAtom (ABool _)) = []

initialTransitions :: Agg -> [Transition]
initialTransitions a = case map stName (aStates a) of
  (s0 : _) -> [t | t <- aTransitions a, tSource t == s0]
  [] -> []

-- | @sampleEvent<Ctor> :: <Agg>Event@ — a sample built from per-field sample
-- values (enum→first constructor, Bool→False, id→placeholder,
-- Text→\"sample-<fieldName>\").
sampleEventDecl :: Agg -> ResolvedCtor -> [Text]
sampleEventDecl a e =
  [ "",
    "sampleEvent" <> rcName e <> " :: " <> aName a <> "Event",
    "sampleEvent" <> rcName e <> " = " <> ctorExpr a e
  ]

acceptDecl :: Agg -> Transition -> [Text]
acceptDecl a t =
  [ "",
    "accept" <> tCommand t <> " :: Bool",
    "accept" <> tCommand t <> " =",
    "  case step " <> lowerFirst (aName a) <> "Transducer (" <> initialVertex a <> ", initial" <> aName a <> "Regs) " <> cmdSample <> " of",
    "    Just (v, _, _) -> v == " <> vertexCtor a (tGoto t),
    "    Nothing -> False"
  ]
  where
    cmdSample = case [c | c <- aCommands a, rcName c == tCommand t] of
      (c : _) -> "(" <> ctorExpr a c <> ")"
      [] -> "(error \"no command\")"

forwardReplayDecl :: Agg -> Transition -> [Text]
forwardReplayDecl a t =
  [ "",
    "-- forward/replay equality (plan 147): cross the persisted codec boundary,",
    "-- replay the emitted chain, and compare the final vertex and every register.",
    helperName <> " :: [(String, Bool)]",
    helperName <> " =",
    "  case step " <> transducer <> " (" <> initial <> ", " <> initialRegs <> ") " <> cmdSample <> " of",
    "    Nothing -> [(prefix <> \"forward step accepted\", False)]",
    "    Just (forwardVertex, " <> forwardRegsName <> ", emitted) ->",
    "      case mapM (\\event -> parse" <> nm <> "Event (eventType " <> codec <> " event) (encode" <> nm <> "Event event)) emitted of",
    "        Left _ -> [(prefix <> \"emitted chain decodes\", False)]",
    "        Right decodedEvents ->",
    "          case applyEventsEither " <> transducer <> " (" <> initial <> ", " <> initialRegs <> ") decodedEvents of",
    "            Left _ -> [(prefix <> \"replay succeeds\", False)]",
    "            Right (replayVertex, " <> replayRegsName <> ") ->",
    "              [ (prefix <> \"final vertex\", replayVertex == forwardVertex)"
  ]
    ++ [ "              , (prefix <> \"register " <> rrName reg <> "\", (replayRegs ! #" <> rrName reg <> ") == (forwardRegs ! #" <> rrName reg <> "))"
       | reg <- aRegs a
       ]
    ++ [ "              ]",
         "  where",
         "    prefix = \"forward/replay equality: " <> tCommand t <> " from " <> initial <> " -- \""
       ]
  where
    nm = aName a
    helperName = "forwardReplay" <> tCommand t
    transducer = lowerFirst nm <> "Transducer"
    codec = lowerFirst nm <> "Codec"
    initial = initialVertex a
    initialRegs = "initial" <> nm <> "Regs"
    forwardRegsName = if null (aRegs a) then "_forwardRegs" else "forwardRegs"
    replayRegsName = if null (aRegs a) then "_replayRegs" else "replayRegs"
    cmdSample = case [c | c <- aCommands a, rcName c == tCommand t] of
      (c : _) -> "(" <> ctorExpr a c <> ")"
      [] -> "(error \"no command\")"

-- | @(<Ctor> (<Ctor>Data v1 v2 …))@ with positional sample field values.
ctorExpr :: Agg -> ResolvedCtor -> Text
ctorExpr a rc =
  "(" <> rcName rc <> " (" <> rcName rc <> "Data" <> args <> "))"
  where
    args = T.concat [" " <> sampleValue a fieldName ty | (fieldName, ty) <- rcFields rc]

sampleValue :: Agg -> Text -> ResolvedAggregateType -> Text
sampleValue a fieldName ty = case fieldCat a ty of
  IdCat -> aggregateSampleHaskell (aSymbols a) fieldName ty
  EnumCat -> aggregateSampleHaskell (aSymbols a) fieldName ty
  MappedStructuralCat declaration _ -> fixtureSample (sdFixtures declaration)
  MappedOpaqueCat declaration -> fixtureSample (odFixtures declaration)
  OtherCat -> case ty of
    AggregateVertex vertexType
      | vertexType == aVertexType a -> initialVertex a
    _ -> aggregateSampleHaskell (aSymbols a) fieldName ty

aggregateHarnessImports :: Agg -> [Text]
aggregateHarnessImports aggregate =
  unique
    [ "import " <> imported
    | resolvedType <- map snd (concatMap rcFields (aCommands aggregate <> aEvents aggregate)),
      AggregateTime <- [resolvedType],
      imported <- Set.toAscList (aggregateImports (aSymbols aggregate) resolvedType)
    ]

nominalHarnessImports :: Agg -> [Text]
nominalHarnessImports aggregate
  | null nominals = []
  | otherwise =
      [ "import Data.List.NonEmpty qualified as NonEmpty",
        "import Keiro.Codec.Nominal (nominalDomainRoundTrip, nominalFixtureCases, nominalFixtureDomain, nominalRepresentationRoundTrip, nominalToRepresentation)"
      ]
        <> ["import " <> moduleName <> " qualified" | moduleName <- unique (fixtureModules <> bindingModules)]
        <> ["import " <> nominalProjectionModule (aContext aggregate) <> " qualified as NominalProjections" | not (null (nominalScalarHarnessTypes aggregate))]
  where
    nominals = consumerNominalHarnessTypes aggregate
    bindings = [binding | nominal <- nominals, ConsumerNominal binding <- [resolvedNominalOwnership nominal]]
    fixtureModules =
      [ fst (splitQualifiedHarness (unQualifiedValueName (consumerNominalFixtures binding)))
      | binding <- bindings
      ]
    bindingModules =
      [ fst (splitQualifiedHarness (unQualifiedValueName (consumerNominalBinding binding)))
      | binding <- bindings
      ]

hasNominalHarness :: Agg -> Bool
hasNominalHarness = not . null . consumerNominalHarnessTypes

consumerNominalHarnessTypes :: Agg -> [ResolvedNominalType]
consumerNominalHarnessTypes aggregate =
  Map.elems . Map.fromList $
    [ (resolvedNominalName nominal, nominal)
    | resolvedType <- map snd (concatMap rcFields (aCommands aggregate <> aEvents aggregate)) <> map rrType (aRegs aggregate),
      AggregateNominal nominal <- [resolvedType],
      ConsumerNominal {} <- [resolvedNominalOwnership nominal]
    ]

generatedNominalHarnessTypes :: Agg -> [ResolvedNominalType]
generatedNominalHarnessTypes aggregate =
  generatedNominalsInTypes
    (map snd (concatMap rcFields (aCommands aggregate <> aEvents aggregate)))

nominalScalarHarnessTypes :: Agg -> [ResolvedNominalType]
nominalScalarHarnessTypes aggregate =
  [ nominal
  | nominal <- consumerNominalHarnessTypes aggregate,
    ScalarRepresentation {} <- [resolvedNominalRepresentation nominal]
  ]

nominalHarnessDeclarations :: Agg -> [Text]
nominalHarnessDeclarations aggregate
  | null nominals = []
  | otherwise =
      [ "",
        "nominalConformanceAssertions :: [(String, Bool)]",
        "nominalConformanceAssertions ="
      ]
        <> renderList assertions
  where
    nominals = consumerNominalHarnessTypes aggregate
    assertions = concatMap assertionsFor nominals
    assertionsFor nominal = case resolvedNominalOwnership nominal of
      GeneratedNominal -> []
      ConsumerNominal binding ->
        [ ( "nominal domain law: " <> name,
            "all (\\fixture -> nominalDomainRoundTrip " <> bindingName <> " (nominalFixtureDomain fixture)) " <> fixtures
          ),
          ( "nominal representation law: " <> name,
            "all (\\fixture -> let domainValue = nominalFixtureDomain fixture in nominalRepresentationRoundTrip " <> bindingName <> " (nominalToRepresentation " <> bindingName <> " domainValue)) " <> fixtures
          )
        ]
          <> [ ( "nominal projection agreement: " <> name,
                 "all (\\fixture -> fieldWitnessAgrees NominalProjections."
                   <> lowerFirst name
                   <> "Witness (nominalToRepresentation "
                   <> bindingName
                   <> ") (nominalFixtureDomain fixture)) "
                   <> fixtures
               )
             | ScalarRepresentation {} <- [resolvedNominalRepresentation nominal]
             ]
        where
          name = resolvedNominalName nominal
          bindingName = unQualifiedValueName (consumerNominalBinding binding)
          fixtureName = unQualifiedValueName (consumerNominalFixtures binding)
          fixtures = "(NonEmpty.toList (nominalFixtureCases " <> fixtureName <> "))"
    renderList values =
      [ (if index == (0 :: Int) then "  [ " else "  , ") <> "(" <> tshow labelText <> ", " <> expression <> ")"
      | (index, (labelText, expression)) <- zip [0 ..] values
      ]
        <> ["  ]"]

mappedHarnessImports :: Agg -> [Text]
mappedHarnessImports aggregate
  | null fixtures = []
  | otherwise =
      [ "import Data.Aeson qualified as Aeson",
        "import Data.Aeson.Key qualified as AesonKey",
        "import Data.Aeson.KeyMap qualified as AesonKeyMap",
        "import Data.Either (isLeft, isRight)",
        "import Data.List (nub)",
        "import Data.List.NonEmpty qualified as NonEmpty",
        "import Data.Maybe (isJust, isNothing)",
        "import Data.Proxy (Proxy (..))",
        "import Data.Text qualified as T",
        "import Keiki.Shape (CanonicalTypeName (..))",
        "import Keiro.Codec.Structural (FixtureCases (..), bindingDomainRoundTrip, bindingShapeRoundTrip, bindingToShape)"
      ]
        ++ map (\moduleName -> "import " <> moduleName <> " qualified") (unique (modules <> bindingModules <> shapeModules <> consumerModules))
        ++ ["import " <> structuralProjectionModuleName (aContext aggregate) <> " qualified as StructuralProjections" | not (null (mappedProjectionSpecs aggregate))]
  where
    fixtures = [mappedFixtures declaration | declaration <- mappedHarnessDeclarationsResolved aggregate]
    modules = unique [fst (splitQualifiedHarness (unQualifiedValueName qualified)) | qualified <- fixtures]
    bindingModules =
      [ fst (splitQualifiedHarness (unQualifiedValueName (sdBinding declaration)))
      | ResolvedStructural declaration _ <- mappedHarnessDeclarationsResolved aggregate
      ]
    shapeModules =
      [ structuralShapeModuleName (aContext aggregate) (sdName declaration)
      | ResolvedStructural declaration _ <- mappedHarnessDeclarationsResolved aggregate
      ]
    consumerModules =
      [ hsModule (sdHaskell declaration)
      | ResolvedStructural declaration _ <- mappedHarnessDeclarationsResolved aggregate
      ]

mappedCodecHarnessExports :: Agg -> Text
mappedCodecHarnessExports aggregate =
  T.concat
    [ ", encode" <> sdName declaration <> "Mapped, decode" <> sdName declaration <> "Mapped"
    | ResolvedStructural declaration _ <- codecMappedDeclarations aggregate
    ]

fixtureSample :: QualifiedValueName -> Text
fixtureSample qualified =
  "(snd (NonEmpty.head (fixtureCases " <> unQualifiedValueName qualified <> ")))"

splitQualifiedHarness :: Text -> (Text, Text)
splitQualifiedHarness value =
  let (prefix, name) = T.breakOnEnd "." value
   in (T.dropEnd 1 prefix, name)

unique :: (Eq value) => [value] -> [value]
unique = foldr (\value values -> if value `elem` values then values else value : values) []

hasMappedHarness :: Agg -> Bool
hasMappedHarness = not . null . mappedHarnessDeclarationsResolved

mappedHarnessDeclarationsResolved :: Agg -> [ResolvedMappedDecl]
mappedHarnessDeclarationsResolved aggregate = case aTypeGraph aggregate of
  Nothing -> []
  Just graph -> Map.elems (tgDeclarations graph)

mappedProjectionSpecs :: Agg -> [StructuralProjection]
mappedProjectionSpecs aggregate = case aTypeGraph aggregate of
  Nothing -> []
  Just graph -> map (resolveProjectionModules (aContext aggregate)) (projectionSpecs graph)

structuralShapeModuleName :: Context -> Name -> Text
structuralShapeModuleName context name = case placement context of
  GeneratedPrefix -> root <> "Generated." <> contextSegment <> ".Structural.Shape." <> name
  CollocatedLeaf -> root <> contextSegment <> ".Generated.Structural.Shape." <> name
  where
    root = if T.null (moduleRoot context) then "" else moduleRoot context <> "."
    contextSegment = pascalFromKebab (contextName context)

structuralProjectionModuleName :: Context -> Text
structuralProjectionModuleName context = case placement context of
  GeneratedPrefix -> root <> "Generated." <> contextSegment <> ".StructuralProjections"
  CollocatedLeaf -> root <> contextSegment <> ".Generated.StructuralProjections"
  where
    root = if T.null (moduleRoot context) then "" else moduleRoot context <> "."
    contextSegment = pascalFromKebab (contextName context)

mappedHarnessDeclarations :: Agg -> [Text]
mappedHarnessDeclarations aggregate
  | not (hasMappedHarness aggregate) = []
  | otherwise =
      [ "",
        "mappedConformanceAssertions :: [(String, Bool)]",
        "mappedConformanceAssertions =",
        "  concat",
        "    [ " <> T.intercalate "\n    , " assertionLists,
        "    ]",
        "",
        "validFixtureLabels :: NonEmpty.NonEmpty (T.Text, value) -> Bool",
        "validFixtureLabels cases =",
        "  all (not . T.null) labels && length labels == length (nub labels)",
        "  where",
        "    labels = map fst (NonEmpty.toList cases)"
      ]
        ++ concatMap (bindingAssertionDecl aggregate) structural
        ++ concatMap (opaqueAssertionDecl aggregate) opaque
        ++ concatMap (coverageDecl aggregate) structural
        ++ concatMap (mappedEventAssertionDecl aggregate) mappedEventFields
        ++ wirePolicyAssertionDecls aggregate structuralWire
        ++ projectionAssertionDecls aggregate structural
        ++ wirePolicyHelpers structuralWire
  where
    declarations = mappedHarnessDeclarationsResolved aggregate
    structural = [(declaration, shape) | ResolvedStructural declaration shape <- declarations]
    opaque = [declaration | ResolvedOpaque declaration <- declarations]
    structuralWire = [(declaration, shape) | ResolvedStructural declaration shape <- codecMappedDeclarations aggregate]
    mappedEventFields =
      [ (event, fieldName, fieldType, declaration)
      | event <- aEvents aggregate,
        (fieldName, fieldType) <- rcFields event,
        declaration <- maybeToListHarness (mappedDeclaration aggregate fieldType)
      ]
    assertionLists =
      [lowerFirst (sdName declaration) <> "BindingAssertions" | (declaration, _) <- structural]
        <> [lowerFirst (odName declaration) <> "OpaqueAssertions" | declaration <- opaque]
        <> [ "[(\"fixture coverage: "
               <> unCanonicalTypeId (sdCanonical declaration)
               <> "\", coverage"
               <> sdName declaration
               <> ")]"
           | (declaration, _) <- structural
           ]
        <> [ mappedEventAssertionName event fieldName <> "Assertions"
           | (event, fieldName, _, _) <- mappedEventFields
           ]
        <> ["structuralWirePolicyAssertions" | not (null structuralWire)]
        <> ["structuralProjectionAssertions" | not (null (mappedProjectionSpecs aggregate))]

mappedDeclaration :: Agg -> ResolvedAggregateType -> Maybe ResolvedMappedDecl
mappedDeclaration aggregate resolvedType = do
  key <- case resolvedType of
    AggregateMapped mappedKey -> Just mappedKey
    _ -> Nothing
  graph <- aTypeGraph aggregate
  Map.lookup key (tgDeclarations graph)

bindingAssertionDecl :: Agg -> (StructuralDecl, ResolvedMappedShape) -> [Text]
bindingAssertionDecl _aggregate (declaration, _shape) =
  [ "",
    valueName <> " :: [(String, Bool)]",
    valueName <> " =",
    "  (\"fixture labels: " <> canonical <> "\", validFixtureLabels cases) :",
    "  (\"canonical identity: " <> canonical <> "\", canonicalTypeName (Proxy @" <> consumerType <> ") == " <> tshow canonical <> ") :",
    "  concat",
    "    [ [ (\"binding domain round-trip: " <> canonical <> "/\" <> T.unpack label, bindingDomainRoundTrip " <> binding <> " value)",
    "      , (\"binding shape round-trip: " <> canonical <> "/\" <> T.unpack label, bindingShapeRoundTrip " <> binding <> " (bindingToShape " <> binding <> " value))",
    "      ]",
    "    | (label, value) <- NonEmpty.toList cases",
    "    ]",
    "  where",
    "    cases = fixtureCases " <> fixtures
  ]
  where
    valueName = lowerFirst (sdName declaration) <> "BindingAssertions"
    canonical = unCanonicalTypeId (sdCanonical declaration)
    consumerType = hsModule (sdHaskell declaration) <> "." <> hsType (sdHaskell declaration)
    binding = unQualifiedValueName (sdBinding declaration)
    fixtures = unQualifiedValueName (sdFixtures declaration)

opaqueAssertionDecl :: Agg -> OpaqueDecl -> [Text]
opaqueAssertionDecl _aggregate declaration =
  [ "",
    valueName <> " :: [(String, Bool)]",
    valueName <> " =",
    "  (\"opaque boundary fixtures: " <> label <> "\", validFixtureLabels cases) :",
    "  [ (\"opaque codec round-trip: " <> label <> "/\" <> T.unpack caseLabel, case Aeson.fromJSON (Aeson.toJSON value) of Aeson.Success decoded -> decoded == value; Aeson.Error _ -> False)",
    "  | (caseLabel, value) <- NonEmpty.toList cases",
    "  ]",
    "  where",
    "    cases = fixtureCases " <> fixtures
  ]
  where
    valueName = lowerFirst (odName declaration) <> "OpaqueAssertions"
    label = unCodecIdentity (odCodecIdentity declaration) <> "@" <> unCodecVersion (odCodecVersion declaration)
    fixtures = unQualifiedValueName (odFixtures declaration)

coverageDecl :: Agg -> (StructuralDecl, ResolvedMappedShape) -> [Text]
coverageDecl aggregate (declaration, shape) =
  [ "",
    "coverage" <> sdName declaration <> " :: Bool",
    "coverage" <> sdName declaration <> " = " <> coverageExpression aggregate declaration shape
  ]

coverageExpression :: Agg -> StructuralDecl -> ResolvedMappedShape -> Text
coverageExpression aggregate declaration shape = case obligations of
  [] -> "True"
  _ -> T.intercalate " && " obligations <> "\n  where\n    shapes = map (bindingToShape " <> binding <> " . snd) (NonEmpty.toList (fixtureCases " <> fixtures <> "))"
  where
    shapeModule = structuralShapeModuleName (aContext aggregate) (sdName declaration)
    binding = unQualifiedValueName (sdBinding declaration)
    fixtures = unQualifiedValueName (sdFixtures declaration)
    obligations = case shape of
      RRecord _ _ fields -> concatMap (recordFieldObligation shapeModule) fields
      REnum entries ->
        [ "any (\\case " <> shapeModule <> "." <> weCtor entry <> " -> True; _ -> False) shapes"
        | entry <- entries
        ]
      RUnion _ arms -> concatMap (unionArmObligations shapeModule) arms

recordFieldObligation :: Text -> ResolvedWireField -> [Text]
recordFieldObligation shapeModule field = case rwfType field of
  ROptional _ ->
    [ "any (isNothing . " <> selector <> ") shapes",
      "any (isJust . " <> selector <> ") shapes"
    ]
  _ -> []
  where
    selector = shapeModule <> "." <> rwfHaskell field

unionArmObligations :: Text -> ResolvedWireArm -> [Text]
unionArmObligations shapeModule arm =
  ["any (\\case " <> patternText <> " -> True; _ -> False) shapes"] <> optionalPayload
  where
    constructor = shapeModule <> "." <> rwaCtor arm
    patternText = constructor <> maybe "" (const "{}") (rwaPayload arm)
    optionalPayload = case rwaPayload arm of
      Just (ROptional _) ->
        [ "any (\\case " <> constructor <> " Nothing -> True; _ -> False) shapes",
          "any (\\case " <> constructor <> " (Just _) -> True; _ -> False) shapes"
        ]
      _ -> []

mappedEventAssertionDecl :: Agg -> (ResolvedCtor, Text, ResolvedAggregateType, ResolvedMappedDecl) -> [Text]
mappedEventAssertionDecl aggregate (event, fieldName, _fieldType, declaration) =
  [ "",
    valueName <> "Assertions :: [(String, Bool)]",
    valueName <> "Assertions =",
    "  [ (\"mapped codec round-trip: " <> rcName event <> "/" <> fieldName <> "/\" <> T.unpack label, roundTrips " <> eventExpression <> ")",
    "  | (label, mappedValue) <- NonEmpty.toList (fixtureCases " <> fixtures <> ")",
    "  ]"
  ]
  where
    valueName = mappedEventAssertionName event fieldName
    fixtures = unQualifiedValueName (mappedFixtures declaration)
    eventExpression = ctorExprWithOverride aggregate event fieldName "mappedValue"

mappedEventAssertionName :: ResolvedCtor -> Text -> Text
mappedEventAssertionName event fieldName = lowerFirst (rcName event) <> pascal fieldName

wirePolicyAssertionDecls :: Agg -> [(StructuralDecl, ResolvedMappedShape)] -> [Text]
wirePolicyAssertionDecls _aggregate [] = []
wirePolicyAssertionDecls aggregate declarations =
  [ "",
    "structuralWirePolicyAssertions :: [(String, Bool)]",
    "structuralWirePolicyAssertions =",
    "  [ " <> T.intercalate "\n  , " assertions,
    "  ]"
  ]
  where
    assertions = concatMap (wirePolicyAssertions aggregate) declarations

wirePolicyAssertions :: Agg -> (StructuralDecl, ResolvedMappedShape) -> [Text]
wirePolicyAssertions aggregate (declaration, shape) = case shape of
  RRecord _ unknownFields fields ->
    concatMap (recordMissingAssertions aggregate declaration) [field | field <- fields, rwfPresence field == POptional]
      <> [unknownFieldAssertion declaration unknownFields]
  REnum entries -> map (enumArmAssertion declaration) entries <> [enumUnknownAssertion declaration]
  RUnion encoding arms ->
    map (unionArmAssertion declaration encoding) arms
      <> [unknownFieldAssertion declaration (ueUnknownFields encoding)]

recordMissingAssertions :: Agg -> StructuralDecl -> ResolvedWireField -> [Text]
recordMissingAssertions aggregate declaration field =
  [ "(\"wire policy missing default: "
      <> canonical
      <> "/"
      <> rwfKey field
      <> "\", case "
      <> decoder
      <> " (deleteObjectField "
      <> tshow (rwfKey field)
      <> " ("
      <> encodedSample
      <> ")) of Left _ -> False; Right decoded -> objectField "
      <> tshow (rwfKey field)
      <> " ("
      <> encoder
      <> " decoded) == Just ("
      <> missingExpectedValue aggregate field
      <> "))",
    "(\"wire policy explicit null: "
      <> canonical
      <> "/"
      <> rwfKey field
      <> "\", "
      <> nullExpectation
      <> " ("
      <> decoder
      <> " (insertObjectField "
      <> tshow (rwfKey field)
      <> " Aeson.Null ("
      <> encodedSample
      <> "))))"
  ]
  where
    canonical = unCanonicalTypeId (sdCanonical declaration)
    encoder = "encode" <> sdName declaration <> "Mapped"
    decoder = "decode" <> sdName declaration <> "Mapped"
    fixtures = unQualifiedValueName (sdFixtures declaration)
    encodedSample = encoder <> " (snd (NonEmpty.head (fixtureCases " <> fixtures <> ")))"
    nullExpectation = case rwfType field of
      ROptional _ -> "isRight"
      _ -> "isLeft"

missingExpectedValue :: Agg -> ResolvedWireField -> Text
missingExpectedValue aggregate field = case rwfOnMissing field of
  Just OmNull -> "Aeson.Null"
  Just (OmText value) -> "Aeson.String " <> tshow value
  Just (OmInt value) -> "Aeson.toJSON (" <> T.pack (show value) <> " :: Int)"
  Just (OmBool value) -> if value then "Aeson.Bool True" else "Aeson.Bool False"
  Just OmEmptyList -> "Aeson.toJSON ([] :: [Aeson.Value])"
  Just OmEmptyMap -> "Aeson.Object mempty"
  Just (OmCtor constructor) -> case (aTypeGraph aggregate, rwfType field) of
    (Just graph, RRef key) -> case Map.lookup key (tgDeclarations graph) of
      Just (ResolvedStructural _ (REnum entries)) -> case find ((== constructor) . weCtor) entries of
        Just entry -> "Aeson.String " <> tshow (weTag entry)
        Nothing -> "error \"missing enum default constructor\""
      _ -> "error \"non-enum constructor default\""
    _ -> "error \"non-reference constructor default\""
  Nothing -> "error \"optional field lacks on-missing policy\""

unknownFieldAssertion :: StructuralDecl -> UnknownFields -> Text
unknownFieldAssertion declaration policy =
  "(\"wire policy unknown fields: "
    <> unCanonicalTypeId (sdCanonical declaration)
    <> "\", all (\\(_, value) -> "
    <> expectation
    <> " (decode"
    <> sdName declaration
    <> "Mapped (insertObjectField \"__keiro_unknown\" (Aeson.Bool True) (encode"
    <> sdName declaration
    <> "Mapped value)))) (NonEmpty.toList (fixtureCases "
    <> unQualifiedValueName (sdFixtures declaration)
    <> ")))"
  where
    expectation = case policy of
      RejectUnknown -> "isLeft"
      IgnoreUnknown -> "isRight"

enumArmAssertion :: StructuralDecl -> WireEnum -> Text
enumArmAssertion declaration entry =
  "(\"wire enum arm: "
    <> unCanonicalTypeId (sdCanonical declaration)
    <> "/"
    <> weTag entry
    <> "\", any (\\(_, value) -> encode"
    <> sdName declaration
    <> "Mapped value == Aeson.String "
    <> tshow (weTag entry)
    <> " && decode"
    <> sdName declaration
    <> "Mapped (Aeson.String "
    <> tshow (weTag entry)
    <> ") == Right value) (NonEmpty.toList (fixtureCases "
    <> unQualifiedValueName (sdFixtures declaration)
    <> ")))"

enumUnknownAssertion :: StructuralDecl -> Text
enumUnknownAssertion declaration =
  "(\"wire enum unknown tag: "
    <> unCanonicalTypeId (sdCanonical declaration)
    <> "\", isLeft (decode"
    <> sdName declaration
    <> "Mapped (Aeson.String \"__keiro_unknown\")))"

unionArmAssertion :: StructuralDecl -> UnionEncoding -> ResolvedWireArm -> Text
unionArmAssertion declaration encoding arm =
  "(\"wire union arm: "
    <> unCanonicalTypeId (sdCanonical declaration)
    <> "/"
    <> rwaTag arm
    <> "\", any (\\(_, value) -> objectField "
    <> tshow (ueTagField encoding)
    <> " (encode"
    <> sdName declaration
    <> "Mapped value) == Just (Aeson.String "
    <> tshow (rwaTag arm)
    <> ") && decode"
    <> sdName declaration
    <> "Mapped (encode"
    <> sdName declaration
    <> "Mapped value) == Right value) (NonEmpty.toList (fixtureCases "
    <> unQualifiedValueName (sdFixtures declaration)
    <> ")))"

wirePolicyHelpers :: [(StructuralDecl, ResolvedMappedShape)] -> [Text]
wirePolicyHelpers [] = []
wirePolicyHelpers _ =
  [ "",
    "deleteObjectField :: T.Text -> Aeson.Value -> Aeson.Value",
    "deleteObjectField key (Aeson.Object objectValue) = Aeson.Object (AesonKeyMap.delete (AesonKey.fromText key) objectValue)",
    "deleteObjectField _ value = value",
    "",
    "insertObjectField :: T.Text -> Aeson.Value -> Aeson.Value -> Aeson.Value",
    "insertObjectField key inserted (Aeson.Object objectValue) = Aeson.Object (AesonKeyMap.insert (AesonKey.fromText key) inserted objectValue)",
    "insertObjectField _ _ value = value",
    "",
    "objectField :: T.Text -> Aeson.Value -> Maybe Aeson.Value",
    "objectField key (Aeson.Object objectValue) = AesonKeyMap.lookup (AesonKey.fromText key) objectValue",
    "objectField _ _ = Nothing"
  ]

mappedFixtures :: ResolvedMappedDecl -> QualifiedValueName
mappedFixtures (ResolvedStructural declaration _) = sdFixtures declaration
mappedFixtures (ResolvedOpaque declaration) = odFixtures declaration

ctorExprWithOverride :: Agg -> ResolvedCtor -> Text -> Text -> Text
ctorExprWithOverride aggregate constructor target replacement =
  "(" <> rcName constructor <> " (" <> rcName constructor <> "Data" <> arguments <> "))"
  where
    arguments =
      T.concat
        [ " " <> if fieldName == target then replacement else sampleValue aggregate fieldName fieldType
        | (fieldName, fieldType) <- rcFields constructor
        ]

projectionAssertionDecls :: Agg -> [(StructuralDecl, ResolvedMappedShape)] -> [Text]
projectionAssertionDecls aggregate structural
  | null specs = []
  | otherwise =
      [ "",
        "structuralProjectionAssertions :: [(String, Bool)]",
        "structuralProjectionAssertions =",
        "  [ " <> T.intercalate "\n  , " (map assertion specs),
        "  ]"
      ]
  where
    specs = mappedProjectionSpecs aggregate
    assertion spec =
      "(\"projection witness agreement: "
        <> unCanonicalTypeId (spCanonical spec)
        <> spPointer spec
        <> "\", all (\\(_, owner) -> fieldWitnessAgrees StructuralProjections."
        <> spWitness spec
        <> " (\\referenceOwner -> "
        <> projectionGetter "referenceOwner" spec
        <> ") owner) (NonEmpty.toList (fixtureCases "
        <> ownerFixtures spec
        <> ")))"
    ownerFixtures spec = case find (\(declaration, _) -> sdCanonical declaration == spCanonical spec) structural of
      Just (declaration, _) -> unQualifiedValueName (sdFixtures declaration)
      Nothing -> "error \"projection owner fixtures missing\""

projectionGetter :: Text -> StructuralProjection -> Text
projectionGetter owner spec =
  foldl
    (\value (shapeModule, selector) -> shapeModule <> "." <> selector <> " (" <> value <> ")")
    ("bindingToShape " <> unQualifiedValueName (spBinding spec) <> " " <> owner)
    (spSelectors spec)

maybeToListHarness :: Maybe value -> [value]
maybeToListHarness = maybe [] pure
