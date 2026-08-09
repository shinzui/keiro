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
  ( harnessForService,
    harnessForServiceWithGoldens,
    harnessFor,
    harnessForWithGoldens,
    harnessProcess,
    harnessRouter,
    harnessReadModel,
    harnessWorkflow,
    processHarnessFactValues,
    routerHarnessFactValues,
    workflowHarnessFactValues,
  )
where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.AggregateGenerationPlan
import Keiro.Dsl.AggregateType
import Keiro.Dsl.FieldIdentity
import Keiro.Dsl.GeneratedHaskellLanguage
import Keiro.Dsl.Goldens (GoldenPayload (..))
import Keiro.Dsl.Grammar
import Keiro.Dsl.HaskellImport
import Keiro.Dsl.IdDomain (idDomainContractFor, idDomainSampleText)
import Keiro.Dsl.NominalType
import Keiro.Dsl.Scaffold
import Keiro.Dsl.SemanticContract (CheckedService (..), legacyCheckedService)
import Keiro.Dsl.SemanticImpact (aggregateMappedClosure, semanticImpact)
import Keiro.Dsl.TypeGraph

-- | Emit the aggregate harness after selecting the service's effective
-- semantic contract.
harnessForService :: Context -> CheckedService -> Aggregate -> [ScaffoldModule]
harnessForService = harnessForServiceWithGoldens []

-- | Contract-aware aggregate harness planning with embedded golden payloads.
harnessForServiceWithGoldens :: [GoldenPayload] -> Context -> CheckedService -> Aggregate -> [ScaffoldModule]
harnessForServiceWithGoldens = harnessForCheckedWithGoldens

-- | Emit the harness test module for one aggregate. Like 'scaffoldAggregate',
-- it takes the 'Spec' for the shared id\/enum declarations. This compatibility
-- wrapper selects legacy/version-1 runtime semantics.
harnessFor :: Context -> Spec -> Aggregate -> [ScaffoldModule]
harnessFor = harnessForWithGoldens []

-- | Emit an aggregate harness with checked-in old-payload fixtures embedded
-- as string literals. Embedding keeps the generated test independent of runtime
-- file paths while retaining the golden file as regeneration source of truth.
harnessForWithGoldens :: [GoldenPayload] -> Context -> Spec -> Aggregate -> [ScaffoldModule]
harnessForWithGoldens goldens ctx spec =
  harnessForServiceWithGoldens goldens ctx (legacyCheckedService spec)

harnessForCheckedWithGoldens :: [GoldenPayload] -> Context -> CheckedService -> Aggregate -> [ScaffoldModule]
harnessForCheckedWithGoldens goldens ctx service agg =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" (aGenPrefix a) <> "/Harness.hs"),
        moduleText = emitHarness relevantGoldens a,
        kind = Generated,
        origin = "aggregate " <> aggName agg <> locSuffix (aggLoc agg)
      }
  ]
  where
    spec = checkedSpec service
    a = resolveAggForService ctx service agg
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
  nl $
    [ generatedBanner,
      "module " <> genPrefix <> ".RouterHarness (routerHarnessValues) where",
      "",
      "routerHarnessValues :: [(String, String)]",
      "routerHarnessValues ="
    ]
      <> renderFactValues (routerHarnessFactValues router)

routerHarnessFactValues :: RouterNode -> [(Text, Text)]
routerHarnessFactValues router =
  [ ("routerName", rtName router),
    ("keyField", corrField (rtKey router)),
    ("resolveSource", resolveSource),
    ("resolveRow", T.intercalate "," (rvRow (rtResolve router))),
    ("dispatchCommand", rdCommand dispatch),
    ("dispatchIdInputs", "(name, key, sourceEventId, targetStreamName, occurrence)"),
    ("onDuplicate", showDisp (onDuplicate disposition)),
    ("onFailed", showDisp (onFailed disposition)),
    ("rejectedPolicy", showPolicy (rtRejected router)),
    ("poisonPolicy", showPolicy (rtPoison router))
  ]
  where
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
  nl $
    renderGeneratedLanguagePragmas [ExtOverloadedRecordDot]
      <> [ generatedBanner,
           "module " <> genPrefix <> ".ReadModelHarness (readModelFacts, readModelFactResults, runReadModelFacts) where",
           "",
           "import " <> genPrefix <> ".ReadModel (" <> T.intercalate ", " readModelImports <> ")",
           "import Data.Text qualified as T",
           "import Keiro.ReadModel (ReadModel (..), StrongScope (..))"
         ]
      <> ["import Keiro.Projection (AsyncProjection (..))" | emitsLegacyAsync]
      <> [ "",
           "-- | (fact, expected from notation, actual generated runtime value).",
           "readModelFacts :: [(String, String, String)]",
           "readModelFacts =",
           "  [ (\"registryName\", " <> tshow expectedRegistry <> ", T.unpack " <> readModelName <> ".name)",
           "  , (\"subscriptionName\", " <> tshow expectedSubscription <> ", T.unpack " <> readModelName <> ".subscriptionName)",
           "  , (\"shapeHash\", " <> tshow (rmShape readModel) <> ", T.unpack " <> readModelName <> ".shapeHash)",
           asyncFactRow,
           "  , (\"consistency\", " <> tshow consistency <> ", show " <> readModelName <> ".defaultConsistency)",
           "  , (\"strongScope\", " <> tshow scope <> ", renderStrongScope " <> readModelName <> ".strongScope)",
           "  ]",
           "",
           "renderStrongScope :: StrongScope -> String",
           "renderStrongScope EntireLog = \"EntireLog\"",
           "renderStrongScope (CategoryHead categoryName) = \"CategoryHead \" <> T.unpack categoryName",
           "",
           "readModelFactResults :: [(String, Bool)]",
           "readModelFactResults =",
           "  [(fact, expected == actual) | (fact, expected, actual) <- readModelFacts]",
           "",
           "runReadModelFacts :: IO Bool",
           "runReadModelFacts = do",
           "  let failures = [(fact, expected, actual) | (fact, expected, actual) <- readModelFacts, expected /= actual]",
           "  mapM_ (\\(fact, expected, actual) -> putStrLn (\"FAIL  \" <> fact <> \" expected=\" <> show expected <> \" actual=\" <> show actual)) failures",
           "  pure (null failures)"
         ]
  where
    stem = lowerFirst (pascal (rmName readModel))
    readModelName = stem <> "ReadModel"
    asyncProjectionName = stem <> "AsyncProjection"
    readModelImports = readModelName : [asyncProjectionName | emitsLegacyAsync]
    expectedRegistry = contextName ctx <> "-" <> T.replace "_" "-" (rmName readModel)
    expectedSubscription = case rmSubscription readModel of
      Just name -> name
      Nothing -> expectedRegistry <> "-sub"
    expectedAsync = case rmFeed readModel of
      RmInline -> "none"
      RmSubscription -> expectedRegistry <> "-async"
    asyncFactRow
      | rmGroup readModel /= Nothing = "  , (\"asyncProjectionName\", \"catalog-managed\", \"catalog-managed\")"
      | otherwise = case rmFeed readModel of
          RmInline -> "  , (\"asyncProjectionName\", \"none\", \"none\") -- Definitionally inert: inline feeds have no AsyncProjection value."
          RmSubscription -> "  , (\"asyncProjectionName\", " <> tshow expectedAsync <> ", T.unpack " <> asyncProjectionName <> ".name)"
    emitsLegacyAsync = rmGroup readModel == Nothing && rmFeed readModel == RmSubscription
    consistency = case rmConsistency readModel of
      Strong -> "Strong"
      Eventual -> "Eventual"
    scope = case rmScope readModel of
      Nothing -> "EntireLog"
      Just RmEntireLog -> "EntireLog"
      Just (RmCategory categoryName) -> "CategoryHead " <> categoryName

emitProcessHarness :: Text -> ProcessNode -> Text
emitProcessHarness genPrefix p =
  nl $
    [ generatedBanner,
      "module " <> genPrefix <> ".ProcessHarness (processHarnessValues) where",
      "",
      "-- | (label, value): the spec's deterministic process/timer decisions,",
      "-- lowered to plain values so a driver can assert them against a committed",
      "-- expectation. The driver's expectation is hand-written (not generated), so a",
      "-- spec change that alters a decision diverges from it and turns a specific",
      "-- assertion red — the spec->behaviour pin. (Live-runtime behavioural",
      "-- conformance of the filled ProcessManager is the M5 step.)",
      "processHarnessValues :: [(String, String)]",
      "processHarnessValues ="
    ]
      <> renderFactValues (processHarnessFactValues p)

processHarnessFactValues :: ProcessNode -> [(Text, Text)]
processHarnessFactValues p =
  [ ("fireAtField", faField (tmFireAt timer)),
    ("timerIdPrefix", idePrefix (tmId timer)),
    ("firedEventIdPrefix", idePrefix (fireFiredEventId timer')),
    ("dispatchIdUserField", "none"),
    ("onReject", showFireOutcome (onReject fd)),
    ("onAmbiguous", showFireOutcome (onAmbiguous fd)),
    ("onFailed", showDisp (onFailed (firstDispDisposition p))),
    ("rejectedPolicy", showPolicy (procRejected p)),
    ("poisonPolicy", showPolicy (procPoison p)),
    ("maxAttempts", tInt (tmMaxAttempts timer))
  ]
  where
    timer = procTimer p
    timer' = tmFire timer
    fd = fireDisposition timer'

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
-- a typed @WorkflowFacts@ record so a driver asserts it against a
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
      "module " <> genPrefix <> ".WorkflowFacts (WorkflowFacts (..), workflowFacts, workflowFactValues) where",
      "",
      "-- | The workflow's deterministic decisions, pinned as typed pure facts.",
      "-- A driver asserts them against a hand-written expectation, so a spec",
      "-- change (e.g. renaming an await) reddens a specific assertion.",
      "data WorkflowFacts = WorkflowFacts",
      "  { workflowFactName :: !String",
      "  , workflowFactIdVia :: !String",
      "  , workflowFactIdField :: !String",
      "  , workflowFactBody :: ![String]",
      "  , workflowFactAwaitLabels :: ![String]",
      "  , workflowFactPatchIds :: ![String]",
      "  }",
      "  deriving stock (Eq, Show)",
      "",
      "workflowFacts :: WorkflowFacts",
      "workflowFacts =",
      "  WorkflowFacts",
      "    { workflowFactName = " <> hs (wfStable w),
      "    , workflowFactIdVia = " <> hs (wfIdVia w),
      "    , workflowFactIdField = " <> hs (maybe "input" id (wfIdField w)),
      "    , workflowFactBody = " <> stringList (map bodyTag (wfBody w)),
      "    , workflowFactAwaitLabels = " <> stringList (workflowAwaitLabels (wfBody w)),
      "    , workflowFactPatchIds = " <> stringList (workflowPatchIds (wfBody w)),
      "    }",
      "",
      "-- | Base-library projection used by the service-level conformance facade.",
      "workflowFactValues :: [(String, String)]",
      "workflowFactValues =",
      "  [ (\"name\", workflowFactName workflowFacts)",
      "  , (\"idVia\", workflowFactIdVia workflowFacts)",
      "  , (\"idField\", workflowFactIdField workflowFacts)",
      "  , (\"body\", show (workflowFactBody workflowFacts))",
      "  , (\"awaits\", show (workflowFactAwaitLabels workflowFacts))",
      "  , (\"patches\", show (workflowFactPatchIds workflowFacts))",
      "  ]"
    ]
  where
    hs = tshow
    stringList values = "[" <> T.intercalate ", " (map hs values) <> "]"
    bodyTag (WfStep l _ _) = "step:" <> l
    bodyTag (WfAwait l _ _) = "await:" <> l
    bodyTag (WfSleep l _ _) = "sleep:" <> l
    bodyTag (WfChild l _ _ _) = "child:" <> l
    bodyTag (WfPatch patchId items _) = "patch:" <> patchId <> "(" <> T.intercalate "," (map bodyTag items) <> ")"
    bodyTag (WfContinueAsNew seedType _) = "continueAsNew:" <> seedType

workflowHarnessFactValues :: WorkflowNode -> [(Text, Text)]
workflowHarnessFactValues workflow =
  [ ("name", wfStable workflow),
    ("idVia", wfIdVia workflow),
    ("idField", maybe "input" id (wfIdField workflow)),
    ("body", T.pack (show (map (T.unpack . bodyTag) (wfBody workflow)))),
    ("awaits", T.pack (show (map T.unpack (workflowAwaitLabels (wfBody workflow))))),
    ("patches", T.pack (show (map T.unpack (workflowPatchIds (wfBody workflow)))))
  ]
  where
    bodyTag (WfStep label _ _) = "step:" <> label
    bodyTag (WfAwait label _ _) = "await:" <> label
    bodyTag (WfSleep label _ _) = "sleep:" <> label
    bodyTag (WfChild label _ _ _) = "child:" <> label
    bodyTag (WfPatch patchId items _) = "patch:" <> patchId <> "(" <> T.intercalate "," (map bodyTag items) <> ")"
    bodyTag (WfContinueAsNew seedType _) = "continueAsNew:" <> seedType

renderFactValues :: [(Text, Text)] -> [Text]
renderFactValues facts =
  [ (if index == (0 :: Int) then "  [ " else "  , ") <> "(" <> tshow label <> ", " <> tshow value <> ")"
  | (index, (label, value)) <- zip [0 ..] facts
  ]
    <> ["  ]"]

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
    renderGeneratedLanguagePragmas [ExtOverloadedLabels | not (null replayTransitions) && not (null (aRegs a))]
      ++ [ generatedBanner,
           "module " <> aGenPrefix a <> ".Harness (harnessAssertions) where",
           ""
         ]
      ++ harnessImports
      ++ [ "",
           "-- | (label, passed). A driver runs these and exits non-zero on any False,",
           "-- naming the failing assertion. Filling a hole wrongly turns a specific",
           "-- entry False; the scaffold cannot.",
           "harnessAssertions :: [(String, Bool)]",
           "harnessAssertions =",
           "  [ (\"validateTransducer is empty\", null (validateTransducer defaultValidationOptions " <> lowerFirst nm <> "Transducer))"
         ]
      ++ clockFreeRows
      ++ [ "  , (\"golden round-trip: " <> rcName e <> "\", roundTrips sampleEvent" <> rcName e <> ")"
         | e <- aEvents a
         ]
      ++ [ "  , (\"accepts " <> tCommand t <> " from " <> initialVertex a <> "\", accept" <> tCommand t <> ")"
         | t <- map layoutTransition (initialLiveTransitionEntries a)
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
      ++ harnessSampleDeclarations a
      ++ concatMap (sampleEventDecl a) (aEvents a)
      ++ concatMap (acceptDecl a . layoutTransition) (initialLiveTransitionEntries a)
      ++ concatMap (forwardReplayDecl a) replayTransitions
      ++ concatMap (upcastDecl goldens a) upcastEvents
      ++ mappedHarnessDeclarations a
      ++ nominalHarnessDeclarations a
  where
    nm = aName a
    clockFreeRows =
      if specIsClockFree a
        then ["  -- clock-free: spec samples no wall clock (verified at scaffold time)"]
        else ["  , (\"clock-free: spec samples no wall clock\", False)"]
    upcastEvents = [e | e <- aEvents a, rcUpcastFrom e /= Nothing]
    replayTransitions =
      [ t
      | entry <- initialLiveTransitionEntries a,
        let t = layoutTransition entry,
        not (null (tEmits t))
      ]
    coreImports =
      ["applyEventsEither" | not (null replayTransitions)]
        ++ ["defaultValidationOptions", "step", "validateTransducer"]
        ++ ["fieldWitnessAgrees" | not (null (nominalScalarHarnessTypes a)) || not (null (enforcedConsumerNominalIdHarnessTypes a))]
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
    harnessImports =
      unique $
        [ "import " <> aGenPrefix a <> ".Domain",
          "import " <> aGenPrefix a <> ".Codec (encode" <> nm <> "Event, parse" <> nm <> "Event" <> codecValueImport <> mappedCodecHarnessExports a <> ")",
          transducerImport a,
          "import Keiki.Core (" <> T.intercalate ", " coreImports <> ")",
          codecDecodeRawImport
        ]
          ++ generatedNominalTypeImportsForService (aggregateCheckedService a) (aContext a) (generatedNominalHarnessTypes a)
          ++ mappedHarnessImports a
          ++ nominalHarnessImports a
          ++ aggregateHarnessImports a
          ++ T.lines (renderPlannedImports (harnessImportPlan a))
          ++ goldenImports

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

initialLiveTransitionEntries :: Agg -> [TransitionLayoutEntry]
initialLiveTransitionEntries a = case map stName (aStates a) of
  (s0 : _) ->
    [ entry
    | entry <- transitionLayoutForSource s0 (transitionLayout (aTransitions a)),
      tMode (layoutTransition entry) == TmLive
    ]
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

harnessSampleDeclarations :: Agg -> [Text]
harnessSampleDeclarations aggregate =
  concatMap generatedIdDeclaration generatedIds <> timeDeclaration
  where
    generatedIds =
      [ nominal
      | nominal <- generatedNominalHarnessTypes aggregate,
        IdRepresentation prefix <- [resolvedNominalRepresentation nominal],
        idDomainContractFor (aLanguageContract aggregate) prefix /= Nothing
      ]
    generatedIdDeclaration nominal = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix -> case idDomainContractFor (aLanguageContract aggregate) prefix of
        Just contract ->
          let typeName = resolvedNominalName nominal
              constantName = generatedIdSampleName nominal
           in [ "",
                constantName <> " :: " <> typeName,
                constantName <> " =",
                "  case parse" <> typeName <> " " <> tshow (idDomainSampleText contract) <> " of",
                "    Right parsed -> parsed",
                "    Left problem -> error (show problem)"
              ]
        Nothing -> []
      _ -> []
    timeDeclaration
      | harnessUsesTime aggregate =
          [ "",
            harnessTimeSampleName aggregate <> " :: UTCTime",
            harnessTimeSampleName aggregate <> " = UTCTime (fromGregorian 2026 1 2) (picosecondsToDiffTime 11045123456789012)"
          ]
      | otherwise = []

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
      (c : _) -> "(" <> commandCtorExpr a t c <> ")"
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
      (c : _) -> "(" <> commandCtorExpr a t c <> ")"
      [] -> "(error \"no command\")"

-- | @(<Ctor> (<Ctor>Data v1 v2 …))@ with positional sample field values.
ctorExpr :: Agg -> ResolvedCtor -> Text
ctorExpr a rc =
  rcName rc <> " (" <> rcName rc <> "Data" <> args <> ")"
  where
    args = T.concat [" " <> sampleValue a (fieldDslName identity) ty | (identity, ty) <- rcFields rc]

-- | A transition command sample prefers the initial value of a same-named,
-- same-typed register only when the guard explicitly equates those two paths.
-- Inequality guards retain the ordinary sample so an enum such as @Paid@ does
-- not accidentally inherit a forbidden @Free@ register initial value.
commandCtorExpr :: Agg -> Transition -> ResolvedCtor -> Text
commandCtorExpr a transition rc =
  rcName rc <> " (" <> rcName rc <> "Data" <> args <> ")"
  where
    args = T.concat [" " <> commandSampleValue a transition (fieldDslName identity) ty | (identity, ty) <- rcFields rc]

commandSampleValue :: Agg -> Transition -> Text -> ResolvedAggregateType -> Text
commandSampleValue aggregate transition fieldName fieldType = case fieldType of
  AggregateNominal _
    | guardEquatesCommandAndRegister transition fieldName -> case find matchesRegister (aRegs aggregate) of
        Just register -> regInitialValueForHarness aggregate register
        Nothing -> fallback
  _ -> fallback
  where
    fallback = sampleValue aggregate fieldName fieldType
    matchesRegister register = rrName register == fieldName && rrType register == fieldType
    regInitialValueForHarness owner register = case rrInitial register of
      InitialNominal _ value -> renderHarnessReference owner (harnessQualifiedValueReference value)
      InitialMapped _ value -> renderHarnessReference owner (harnessQualifiedValueReference value)
      _ -> case rrType register of
        AggregateNominal nominal -> case resolvedNominalOwnership nominal of
          ConsumerNominal {} -> renderRegisterInitial (rrInitial register)
          GeneratedNominal ->
            fromMaybe
              (renderRegisterInitial (rrInitial register))
              (generatedIdSampleName nominal <$ generatedIdSampleHaskell owner nominal)
        _ -> renderRegisterInitial (rrInitial register)

guardEquatesCommandAndRegister :: Transition -> Text -> Bool
guardEquatesCommandAndRegister transition fieldName = maybe False containsEquality (tGuard transition)
  where
    containsEquality = \case
      EOr left right -> containsEquality left || containsEquality right
      EAnd left right -> containsEquality left || containsEquality right
      ECmp OpEq left right -> matchingPaths left right || matchingPaths right left
      _ -> False
    matchingPaths (EPath _ CommandRoot [commandField]) (EPath _ RegisterRoot [registerField]) =
      commandField == fieldName && registerField == fieldName
    matchingPaths _ _ = False

sampleValue :: Agg -> Text -> ResolvedAggregateType -> Text
sampleValue a fieldName ty = case ty of
  AggregateNominal nominal
    | GeneratedNominal <- resolvedNominalOwnership nominal,
      Just _ <- generatedIdSampleHaskell a nominal ->
        generatedIdSampleName nominal
  AggregateNominal nominal
    | ConsumerNominal binding <- resolvedNominalOwnership nominal ->
        "(nominalFixtureDomain (NonEmpty.head (nominalFixtureCases "
          <> renderHarnessReference a (harnessQualifiedValueReference (consumerNominalFixtures binding))
          <> ")))"
  AggregateTime -> harnessTimeSampleName a
  _ -> fallback
  where
    fallback = case fieldCat a ty of
      IdCat -> aggregateSampleHaskell (aSymbols a) fieldName ty
      EnumCat -> aggregateSampleHaskell (aSymbols a) fieldName ty
      MappedStructuralCat declaration _ -> fixtureSample a (sdFixtures declaration)
      MappedOpaqueCat declaration -> fixtureSample a (odFixtures declaration)
      OtherCat -> case ty of
        AggregateVertex vertexType
          | vertexType == aVertexType a -> initialVertex a
        _ -> aggregateSampleHaskell (aSymbols a) fieldName ty

generatedIdSampleName :: ResolvedNominalType -> Text
generatedIdSampleName nominal = "sample" <> resolvedNominalName nominal

harnessUsesTime :: Agg -> Bool
harnessUsesTime aggregate =
  any ((== AggregateTime) . snd) (concatMap rcFields (aCommands aggregate <> aEvents aggregate))

harnessTimeSampleName :: Agg -> Text
harnessTimeSampleName aggregate
  | any isObservedAtTime (concatMap rcFields (aCommands aggregate <> aEvents aggregate)) = "sampleObservedAt"
  | otherwise = "sampleTime"
  where
    isObservedAtTime (identity, resolvedType) = fieldDslName identity == "observedAt" && resolvedType == AggregateTime

aggregateHarnessImports :: Agg -> [Text]
aggregateHarnessImports aggregate
  | harnessUsesTime aggregate =
      [ "import Data.Time.Calendar (fromGregorian)",
        "import Data.Time.Clock (UTCTime (..), picosecondsToDiffTime)"
      ]
  | otherwise = []

nominalHarnessImports :: Agg -> [Text]
nominalHarnessImports aggregate
  | null nominals = []
  | otherwise =
      [ "import Data.List.NonEmpty qualified as NonEmpty",
        "import Keiro.Codec.Nominal (nominalDomainRoundTrip, nominalFixtureCases, nominalFixtureDomain, nominalRepresentationRoundTrip, nominalToRepresentation)"
      ]
        <> ( if null enforcedIds
               then []
               else ["import Data.KindID qualified as KindID", "import Data.Text qualified as T", "import Keiro.Codec.IdDomain (typeIdV7Domain, validateIdDomainText)"]
           )
        <> ["import " <> nominalProjectionModule (aContext aggregate) <> " qualified as NominalProjections" | not (null (nominalScalarHarnessTypes aggregate)) || not (null enforcedIds)]
  where
    nominals = consumerNominalHarnessTypes aggregate
    enforcedIds = enforcedConsumerNominalIdHarnessTypes aggregate

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

enforcedConsumerNominalIdHarnessTypes :: Agg -> [ResolvedNominalType]
enforcedConsumerNominalIdHarnessTypes aggregate =
  [ nominal
  | nominal <- consumerNominalHarnessTypes aggregate,
    IdRepresentation prefix <- [resolvedNominalRepresentation nominal],
    idDomainContractFor (aLanguageContract aggregate) prefix /= Nothing
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
          <> idDomainAssertions name bindingName fixtures nominal
        where
          name = resolvedNominalName nominal
          bindingName = renderHarnessReference aggregate (harnessQualifiedValueReference (consumerNominalBinding binding))
          fixtureName = renderHarnessReference aggregate (harnessQualifiedValueReference (consumerNominalFixtures binding))
          fixtures = "(NonEmpty.toList (nominalFixtureCases " <> fixtureName <> "))"
    idDomainAssertions name bindingName fixtures nominal = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix
        | Just contract <- idDomainContractFor (aLanguageContract aggregate) prefix ->
            let firstSample = idDomainSampleText contract
                samples = [firstSample, T.dropEnd 1 firstSample <> "r"]
                wrongPrefix = "wrong_" <> T.drop (T.length prefix + 1) firstSample
             in [ ( "nominal ID projection agreement: " <> name,
                    "all (\\fixture -> fieldWitnessAgrees NominalProjections."
                      <> lowerFirst name
                      <> "EqualityWitness (KindID.toText . nominalToRepresentation "
                      <> bindingName
                      <> ") (nominalFixtureDomain fixture)) "
                      <> fixtures
                  ),
                  ( "nominal ID fixture domain agreement: " <> name,
                    "all (\\fixture -> case validateIdDomainText (typeIdV7Domain "
                      <> tshow prefix
                      <> ") (KindID.toText (nominalToRepresentation "
                      <> bindingName
                      <> " (nominalFixtureDomain fixture))) of Right () -> True; Left _ -> False) "
                      <> fixtures
                  ),
                  ( "nominal ID binding preserves canonical representations: " <> name,
                    "all (nominalRepresentationRoundTrip "
                      <> bindingName
                      <> ") ["
                      <> T.intercalate ", " (map (renderKindId prefix) samples)
                      <> "]"
                  ),
                  ( "nominal ID boundary rejects wrong-prefix and normalized text: " <> name,
                    "case (validateIdDomainText (typeIdV7Domain "
                      <> tshow prefix
                      <> ") "
                      <> tshow wrongPrefix
                      <> ", validateIdDomainText (typeIdV7Domain "
                      <> tshow prefix
                      <> ") (T.toUpper "
                      <> tshow firstSample
                      <> ")) of (Left _, Left _) -> True; _ -> False"
                  )
                ]
      _ -> []
      where
        renderKindId prefix value =
          "(case KindID.parseText @"
            <> tshow prefix
            <> " "
            <> tshow value
            <> " of Right parsed -> parsed; Left _ -> error \"generated canonical ID conformance probe failed to parse\")"
    renderList values =
      [ (if index == (0 :: Int) then "  [ " else "  , ") <> "(" <> tshow labelText <> ", " <> expression <> ")"
      | (index, (labelText, expression)) <- zip [0 ..] values
      ]
        <> ["  ]"]

mappedHarnessImports :: Agg -> [Text]
mappedHarnessImports aggregate
  | null declarations = []
  | otherwise =
      ["import Data.Aeson qualified as Aeson" | not (null structuralWire)]
        ++ (if null structuralWire then [] else ["import Data.Aeson.Key qualified as AesonKey", "import Data.Aeson.KeyMap qualified as AesonKeyMap"])
        ++ [renderImport "Data.Either" eitherImports | not (null eitherImports)]
        ++ ["import Data.List.NonEmpty qualified as NonEmpty"]
        ++ ["import Data.Text qualified as T" | hasMappedConformanceAssertions aggregate]
        ++ [renderImport "Keiro.Codec.Structural" ["FixtureCases (..)"]]
  where
    declarations = mappedHarnessDeclarationsResolved aggregate
    structuralWire = [(declaration, shape) | ResolvedStructural declaration shape <- codecMappedDeclarations aggregate]
    eitherImports =
      ["isLeft" | wirePoliciesUseIsLeft structuralWire]
        <> ["isRight" | wirePoliciesUseIsRight structuralWire]
    renderImport moduleName names = "import " <> moduleName <> " (" <> T.intercalate ", " names <> ")"

mappedCodecHarnessExports :: Agg -> Text
mappedCodecHarnessExports aggregate =
  T.concat
    [ ", encode" <> sdName declaration <> "Mapped, decode" <> sdName declaration <> "Mapped"
    | ResolvedStructural declaration _ <- codecMappedDeclarations aggregate
    ]

fixtureSample :: Agg -> QualifiedValueName -> Text
fixtureSample aggregate qualified =
  "(snd (NonEmpty.head (fixtureCases " <> renderHarnessReference aggregate (harnessQualifiedValueReference qualified) <> ")))"

splitQualifiedHarness :: Text -> (Text, Text)
splitQualifiedHarness value =
  let (prefix, name) = T.breakOnEnd "." value
   in (T.dropEnd 1 prefix, name)

harnessImportPlan :: Agg -> HaskellImportPlan
harnessImportPlan aggregate =
  either
    (error . ("validated harness import planning failed: " <>) . show)
    id
    ( planHaskellImports
        ImportEnvironment
          { targetModule = aGenPrefix aggregate <> ".Harness",
            localNames =
              Set.fromList
                [ aName aggregate <> "Command",
                  aName aggregate <> "Event",
                  aName aggregate <> "Regs",
                  aVertexType aggregate
                ],
            reservedQualifiers = harnessReservedQualifiers
          }
        references
    )
  where
    consumerNominalReferences =
      Set.fromList
        [ reference
        | nominal <- consumerNominalHarnessTypes aggregate,
          ConsumerNominal binding <- [resolvedNominalOwnership nominal],
          reference <-
            map
              harnessQualifiedValueReference
              ( consumerNominalBinding binding
                  : consumerNominalFixtures binding
                  : maybeToListHarness (consumerNominalInitial binding)
              )
        ]
    mappedReferences =
      Set.fromList
        [ reference
        | declaration <- mappedHarnessDeclarationsResolved aggregate,
          reference <- case declaration of
            ResolvedStructural structural _ ->
              map
                harnessQualifiedValueReference
                (sdFixtures structural : maybeToListHarness (sdInitial structural))
            ResolvedOpaque opaque ->
              map
                harnessQualifiedValueReference
                (odFixtures opaque : maybeToListHarness (odInitial opaque))
        ]
    references = consumerNominalReferences <> mappedReferences

harnessQualifiedValueReference :: QualifiedValueName -> HaskellReference
harnessQualifiedValueReference qualified =
  HaskellReference moduleName valueName ValueNamespace RequireQualified
  where
    (moduleName, valueName) = splitQualifiedHarness (unQualifiedValueName qualified)

renderHarnessReference :: Agg -> HaskellReference -> Text
renderHarnessReference aggregate reference =
  either
    (error . ("validated harness reference failed: " <>) . show)
    id
    (renderPlannedReference (harnessImportPlan aggregate) reference)

harnessReservedQualifiers :: Set.Set Text
harnessReservedQualifiers =
  Set.fromList
    [ "Aeson",
      "AesonKey",
      "AesonKeyMap",
      "KindID",
      "Map",
      "NominalProjections",
      "NonEmpty",
      "T"
    ]

unique :: (Eq value) => [value] -> [value]
unique = foldr (\value values -> if value `elem` values then values else value : values) []

hasMappedHarness :: Agg -> Bool
hasMappedHarness = hasMappedConformanceAssertions

hasMappedConformanceAssertions :: Agg -> Bool
hasMappedConformanceAssertions aggregate =
  not (null (mappedEventFields aggregate)) || not (null (structuralWireDeclarations aggregate))

mappedHarnessDeclarationsResolved :: Agg -> [ResolvedMappedDecl]
mappedHarnessDeclarationsResolved aggregate = case aTypeGraph aggregate of
  Nothing -> []
  Just graph ->
    [ declaration
    | key <- aggregateMappedClosure (semanticImpact graph) (aName aggregate),
      Just declaration <- [Map.lookup key (tgDeclarations graph)]
    ]

mappedEventFields :: Agg -> [(ResolvedCtor, Text, ResolvedAggregateType, ResolvedMappedDecl)]
mappedEventFields aggregate =
  [ (event, fieldDslName identity, fieldType, declaration)
  | event <- aEvents aggregate,
    (identity, fieldType) <- rcFields event,
    declaration <- maybeToListHarness (mappedDeclaration aggregate fieldType)
  ]

structuralWireDeclarations :: Agg -> [(StructuralDecl, ResolvedMappedShape)]
structuralWireDeclarations aggregate =
  [(declaration, shape) | ResolvedStructural declaration shape <- codecMappedDeclarations aggregate]

mappedHarnessDeclarations :: Agg -> [Text]
mappedHarnessDeclarations aggregate
  | not (hasMappedConformanceAssertions aggregate) = []
  | otherwise =
      [ "",
        "mappedConformanceAssertions :: [(String, Bool)]",
        "mappedConformanceAssertions =",
        "  concat",
        "    [ " <> T.intercalate "\n    , " assertionLists,
        "    ]"
      ]
        ++ concatMap (mappedEventAssertionDecl aggregate) eventFields
        ++ wirePolicyAssertionDecls aggregate structuralWire
        ++ wirePolicyHelpers structuralWire
  where
    structuralWire = structuralWireDeclarations aggregate
    eventFields = mappedEventFields aggregate
    assertionLists =
      [ mappedEventAssertionName event fieldName <> "Assertions"
      | (event, fieldName, _, _) <- eventFields
      ]
        <> ["structuralWirePolicyAssertions" | not (null structuralWire)]

mappedDeclaration :: Agg -> ResolvedAggregateType -> Maybe ResolvedMappedDecl
mappedDeclaration aggregate resolvedType = do
  key <- case resolvedType of
    AggregateMapped mappedKey -> Just mappedKey
    _ -> Nothing
  graph <- aTypeGraph aggregate
  Map.lookup key (tgDeclarations graph)

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
    fixtures = renderHarnessReference aggregate (harnessQualifiedValueReference (mappedFixtures declaration))
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
      <> [unknownFieldAssertion aggregate declaration unknownFields]
  REnum entries -> map (enumArmAssertion aggregate declaration) entries <> [enumUnknownAssertion declaration]
  RUnion encoding arms ->
    map (unionArmAssertion aggregate declaration encoding) arms
      <> [unknownFieldAssertion aggregate declaration (ueUnknownFields encoding)]

wirePoliciesUseIsLeft :: [(StructuralDecl, ResolvedMappedShape)] -> Bool
wirePoliciesUseIsLeft = any $ \(_, shape) -> case shape of
  RRecord _ unknownFields fields ->
    unknownFields == RejectUnknown
      || any (\field -> rwfPresence field == POptional && not (isOptionalType (rwfType field))) fields
  REnum {} -> True
  RUnion encoding _ -> ueUnknownFields encoding == RejectUnknown

wirePoliciesUseIsRight :: [(StructuralDecl, ResolvedMappedShape)] -> Bool
wirePoliciesUseIsRight = any $ \(_, shape) -> case shape of
  RRecord _ unknownFields fields ->
    unknownFields == IgnoreUnknown
      || any (\field -> rwfPresence field == POptional && isOptionalType (rwfType field)) fields
  REnum {} -> False
  RUnion encoding _ -> ueUnknownFields encoding == IgnoreUnknown

isOptionalType :: ResolvedTypeExpr -> Bool
isOptionalType ROptional {} = True
isOptionalType _ = False

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
    fixtures = renderHarnessReference aggregate (harnessQualifiedValueReference (sdFixtures declaration))
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

unknownFieldAssertion :: Agg -> StructuralDecl -> UnknownFields -> Text
unknownFieldAssertion aggregate declaration policy =
  "(\"wire policy unknown fields: "
    <> unCanonicalTypeId (sdCanonical declaration)
    <> "\", all (\\(_, value) -> "
    <> expectation
    <> " (decode"
    <> sdName declaration
    <> "Mapped (insertObjectField \"__keiro_unknown\" (Aeson.Bool True) (encode"
    <> sdName declaration
    <> "Mapped value)))) (NonEmpty.toList (fixtureCases "
    <> renderHarnessReference aggregate (harnessQualifiedValueReference (sdFixtures declaration))
    <> ")))"
  where
    expectation = case policy of
      RejectUnknown -> "isLeft"
      IgnoreUnknown -> "isRight"

enumArmAssertion :: Agg -> StructuralDecl -> WireEnum -> Text
enumArmAssertion aggregate declaration entry =
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
    <> renderHarnessReference aggregate (harnessQualifiedValueReference (sdFixtures declaration))
    <> ")))"

enumUnknownAssertion :: StructuralDecl -> Text
enumUnknownAssertion declaration =
  "(\"wire enum unknown tag: "
    <> unCanonicalTypeId (sdCanonical declaration)
    <> "\", isLeft (decode"
    <> sdName declaration
    <> "Mapped (Aeson.String \"__keiro_unknown\")))"

unionArmAssertion :: Agg -> StructuralDecl -> UnionEncoding -> ResolvedWireArm -> Text
unionArmAssertion aggregate declaration encoding arm =
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
    <> renderHarnessReference aggregate (harnessQualifiedValueReference (sdFixtures declaration))
    <> ")))"

wirePolicyHelpers :: [(StructuralDecl, ResolvedMappedShape)] -> [Text]
wirePolicyHelpers [] = []
wirePolicyHelpers declarations =
  ( if usesDelete
      then
        [ "",
          "deleteObjectField :: T.Text -> Aeson.Value -> Aeson.Value",
          "deleteObjectField key (Aeson.Object objectValue) = Aeson.Object (AesonKeyMap.delete (AesonKey.fromText key) objectValue)",
          "deleteObjectField _ value = value"
        ]
      else []
  )
    <> [ "",
         "insertObjectField :: T.Text -> Aeson.Value -> Aeson.Value -> Aeson.Value",
         "insertObjectField key inserted (Aeson.Object objectValue) = Aeson.Object (AesonKeyMap.insert (AesonKey.fromText key) inserted objectValue)",
         "insertObjectField _ _ value = value"
       ]
    <> ( if usesObjectField
           then
             [ "",
               "objectField :: T.Text -> Aeson.Value -> Maybe Aeson.Value",
               "objectField key (Aeson.Object objectValue) = AesonKeyMap.lookup (AesonKey.fromText key) objectValue",
               "objectField _ _ = Nothing"
             ]
           else []
       )
  where
    usesDelete = any hasOptionalRecordField declarations
    usesObjectField = usesDelete || any isUnion declarations
    hasOptionalRecordField (_, RRecord _ _ fields) = any ((== POptional) . rwfPresence) fields
    hasOptionalRecordField _ = False
    isUnion (_, RUnion {}) = True
    isUnion _ = False

mappedFixtures :: ResolvedMappedDecl -> QualifiedValueName
mappedFixtures (ResolvedStructural declaration _) = sdFixtures declaration
mappedFixtures (ResolvedOpaque declaration) = odFixtures declaration

ctorExprWithOverride :: Agg -> ResolvedCtor -> Text -> Text -> Text
ctorExprWithOverride aggregate constructor target replacement =
  "(" <> rcName constructor <> " (" <> rcName constructor <> "Data" <> arguments <> "))"
  where
    arguments =
      T.concat
        [ " " <> if fieldDslName identity == target then replacement else sampleValue aggregate (fieldDslName identity) fieldType
        | (identity, fieldType) <- rcFields constructor
        ]

maybeToListHarness :: Maybe value -> [value]
maybeToListHarness = maybe [] pure
