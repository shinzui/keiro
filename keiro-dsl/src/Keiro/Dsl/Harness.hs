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
    harnessRouterForService,
    harnessReadModel,
    harnessReadModelForService,
    harnessWorkflow,
    processHarnessFactValues,
    routerHarnessFactValues,
    routerHarnessFactValuesForService,
    workflowHarnessFactValues,
  )
where

import Data.List (find, sortOn)
import Data.List.NonEmpty qualified as NE
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
import Keiro.Dsl.HaskellName qualified as HaskellName
import Keiro.Dsl.IdDomain (idDomainContractFor, idDomainSampleText)
import Keiro.Dsl.NominalType
import Keiro.Dsl.ProjectionSupply
import Keiro.Dsl.ReadModelShape (registryNameFor)
import Keiro.Dsl.RouterSelection
import Keiro.Dsl.Scaffold
import Keiro.Dsl.SemanticContract (CheckedService, checkedLanguageContract, checkedProjectionSupplies, checkedSpec, checkedTypeGraph, legacyCheckedService)
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
      { path = T.unpack (T.replace "." "/" ((.genPrefix) a) <> "/Harness.hs"),
        text = emitHarness relevantGoldens a,
        kind = Generated,
        origin = "aggregate " <> (.name) agg <> locSuffix ((.loc) agg)
      }
  ]
  where
    spec = checkedSpec service
    a = resolveAggForService ctx service agg
    relevantGoldens =
      [ golden
      | golden <- goldens,
        (.context) golden == (.context) spec,
        (.aggregate) golden == (.name) agg
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
      { path = T.unpack (T.replace "." "/" genPrefix <> "/ProcessHarness.hs"),
        text = emitProcessHarness genPrefix p,
        kind = Generated,
        origin = "process " <> (.id) p <> locSuffix ((.loc) p)
      }
  ]
  where
    genPrefix = genPrefixFor ctx ((.id) p)

-- | Emit runtime-free facts for a router's identity, resolution, dispatch,
-- and worker-policy decisions. A hand-written conformance driver owns the
-- expected values so a spec mutation turns one focused assertion red.
harnessRouter :: Context -> RouterNode -> [ScaffoldModule]
harnessRouter ctx router =
  [ ScaffoldModule
      { path = T.unpack (T.replace "." "/" genPrefix <> "/RouterHarness.hs"),
        text = emitRouterHarness genPrefix router,
        kind = Generated,
        origin = "router " <> (.id) router <> locSuffix ((.loc) router)
      }
  ]
  where
    genPrefix = genPrefixFor ctx ((.id) router)

-- | Add checked declarative-selection evidence without changing any legacy
-- custom-router harness bytes.
harnessRouterForService :: Context -> CheckedService -> RouterNode -> [ScaffoldModule]
harnessRouterForService ctx service router = case (.source) ((.resolve) router) of
  ResolveDeclarative {} ->
    [ ScaffoldModule
        { path = T.unpack (T.replace "." "/" genPrefix <> "/RouterHarness.hs"),
          text = emitRouterHarnessWithFacts genPrefix (routerHarnessFactValuesForService service router),
          kind = Generated,
          origin = "router " <> (.id) router <> locSuffix ((.loc) router)
        }
    ]
  _ -> harnessRouter ctx router
  where
    genPrefix = genPrefixFor ctx ((.id) router)

emitRouterHarness :: Text -> RouterNode -> Text
emitRouterHarness genPrefix router = emitRouterHarnessWithFacts genPrefix (routerHarnessFactValues router)

emitRouterHarnessWithFacts :: Text -> [(Text, Text)] -> Text
emitRouterHarnessWithFacts genPrefix facts =
  nl $
    [ generatedBanner,
      "module " <> genPrefix <> ".RouterHarness (routerHarnessValues) where",
      "",
      "routerHarnessValues :: [(String, String)]",
      "routerHarnessValues ="
    ]
      <> renderFactValues facts

routerHarnessFactValues :: RouterNode -> [(Text, Text)]
routerHarnessFactValues router =
  [ ("routerName", (.name) router),
    ("keyField", (.field) ((.key) router)),
    ("resolveSource", resolveSource),
    ("resolveRow", T.intercalate "," ((.row) ((.resolve) router))),
    ("dispatchCommand", (.command) dispatch),
    ("dispatchIdInputs", "(name, key, sourceEventId, targetStreamName, occurrence)"),
    ("onDuplicate", showDisp ((.onDuplicate) disposition)),
    ("onFailed", showDisp ((.onFailed) disposition)),
    ("rejectedPolicy", showPolicy ((.rejected) router)),
    ("poisonPolicy", showPolicy ((.poison) router))
  ]
  where
    dispatch = (.dispatch) router
    disposition = (.disposition) dispatch
    resolveSource = case (.source) ((.resolve) router) of
      ResolveReadModel name -> "read-model " <> name
      ResolveHole -> "hole"
      ResolveDeclarative selection -> "declarative " <> (.identity) selection

routerHarnessFactValuesForService :: CheckedService -> RouterNode -> [(Text, Text)]
routerHarnessFactValuesForService service router = case (.source) ((.resolve) router) of
  ResolveDeclarative {} ->
    routerHarnessFactValues router
      <> [ ("resolverOwnership", "generated-declarative"),
           ("queryIdentity", (.name) ((.query) selection)),
           ("selectionIdentity", (.identity) selection),
           ("selectionVersion", T.pack (show ((.version) selection))),
           ("selectionFingerprint", (.fingerprint) selection),
           ("maxRecipients", T.pack (show ((.limit) selection))),
           ("selectionOrder", "target-stream"),
           ("selectionDedupe", "target-stream"),
           ("emptyPolicy", checkedEmptyPolicyText ((.emptyPolicy) selection)),
           ("failurePolicy", checkedFailurePolicyText ((.failurePolicy) selection)),
           ("redeliveryPolicy", "stable-union"),
           ("partialPolicy", "retain-successes")
         ]
  _ -> routerHarnessFactValues router
  where
    graph = case checkedTypeGraph service of
      Left errors -> error ("checked declarative router harness type graph failed: " <> show errors)
      Right value -> value
    selection = case checkRouterSelection (checkedLanguageContract service) graph (checkedSpec service) router of
      Left diagnostics -> error ("checked declarative router harness selection failed: " <> show diagnostics)
      Right value -> value
    checkedEmptyPolicyText CheckedEmptyAck = "ack"
    checkedEmptyPolicyText CheckedEmptyRetry = "retry"
    checkedEmptyPolicyText CheckedEmptyDeadLetter = "deadLetter"
    checkedEmptyPolicyText CheckedEmptyHalt = "halt"
    checkedFailurePolicyText CheckedFailureRetry = "retry"
    checkedFailurePolicyText CheckedFailureDeadLetter = "deadLetter"
    checkedFailurePolicyText CheckedFailureHalt = "halt"

-- | Emit runtime-free facts for a read-model node. Each row records the value
-- expected directly from the notation next to the value produced by the shared
-- derivation helpers. Committed conformance expectations pin the lowered values,
-- while a shape-fixture drift makes the generated harness itself fail.
harnessReadModel :: Context -> Spec -> ReadModelNode -> [ScaffoldModule]
harnessReadModel ctx spec = harnessReadModelForService ctx (legacyCheckedService spec)

harnessReadModelForService :: Context -> CheckedService -> ReadModelNode -> [ScaffoldModule]
harnessReadModelForService ctx service readModel =
  [ ScaffoldModule
      { path = T.unpack (T.replace "." "/" genPrefix <> "/ReadModelHarness.hs"),
        text = emitReadModelHarness genPrefix ctx (checkedSpec service) (checkedProjectionSupplies service) readModel,
        kind = Generated,
        origin = "readmodel " <> (.name) readModel <> locSuffix ((.loc) readModel)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (pascal ((.name) readModel))

emitReadModelHarness :: Text -> Context -> Spec -> ProjectionSupplyAnalysis -> ReadModelNode -> Text
emitReadModelHarness genPrefix ctx spec supplyAnalysis readModel =
  nl $
    renderGeneratedLanguagePragmas [ExtOverloadedRecordDot]
      <> [ generatedBanner,
           "module " <> genPrefix <> ".ReadModelHarness (" <> T.intercalate ", " moduleExports <> ") where",
           "",
           "import " <> genPrefix <> ".ReadModel (" <> T.intercalate ", " readModelImports <> ")",
           "import Data.Text qualified as T"
         ]
      <> catalogImports
      <> ["import Keiro.ReadModel (" <> runtimeImports <> ")"]
      <> ["import Keiro.Projection (AsyncProjection (..))" | emitsLegacyAsync]
      <> [ "",
           "-- | (fact, expected from notation, actual generated runtime value).",
           "readModelFacts :: [(String, String, String)]",
           "readModelFacts ="
         ]
      <> baseFactRows
      <> [asyncFactRow | not catalogManaged]
      <> policyFactRows
      <> ["  ]"]
      <> ["    <> catalogFactsAgainst ProjectionCatalog.projectionCatalogRegistrations ProjectionCatalog.projectionCatalogAsyncRegistrations ProjectionCatalog.projectionCatalogQuerySupplies" | catalogManaged]
      <> policyHelpers
      <> catalogHelpers
      <> [ "",
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
    stem = lowerFirst (pascal ((.name) readModel))
    readModelName = stem <> "ReadModel"
    asyncProjectionName = stem <> "AsyncProjection"
    readModelImports = readModelName : [asyncProjectionName | emitsLegacyAsync]
    moduleExports = ["readModelFacts", "readModelFactResults", "runReadModelFacts"] <> ["catalogFactsAgainst" | catalogManaged]
    expectedRegistry = registryNameFor ((.name) ctx) readModel
    ownerDerived = (.supply) readModel == OwnerDerivedSupply
    expectedSubscription = case legacyReadModelSubscription readModel of
      Just name -> name
      Nothing -> expectedRegistry <> "-sub"
    expectedAsync = case legacyReadModelFeed readModel of
      Just RmSubscription -> expectedRegistry <> "-async"
      _ -> "none"
    asyncFactRow = case legacyReadModelFeed readModel of
      Just RmSubscription -> "  , (\"asyncProjectionName\", " <> tshow expectedAsync <> ", T.unpack " <> asyncProjectionName <> ".name)"
      _ -> "  , (\"asyncProjectionName\", \"none\", \"none\") -- Definitionally inert: inline feeds have no AsyncProjection value."
    catalogManaged = (.group) readModel /= Nothing
    emitsLegacyAsync = not ownerDerived && not catalogManaged && legacyReadModelFeed readModel == Just RmSubscription
    runtimeImports
      | ownerDerived = "ReadModel (..), readModelCursorAuthority, readModelDefaultFreshness"
      | otherwise = "ReadModel (..), StrongScope (..)"
    baseFactRows
      | ownerDerived =
          [ "  [ (\"registryName\", " <> tshow expectedRegistry <> ", T.unpack " <> readModelName <> ".name)",
            "  , (\"shapeHash\", " <> tshow ((.shape) readModel) <> ", T.unpack " <> readModelName <> ".shapeHash)"
          ]
      | otherwise =
          [ "  [ (\"registryName\", " <> tshow expectedRegistry <> ", T.unpack " <> readModelName <> ".name)",
            "  , (\"subscriptionName\", " <> tshow expectedSubscription <> ", T.unpack " <> readModelName <> ".subscriptionName)",
            "  , (\"shapeHash\", " <> tshow ((.shape) readModel) <> ", T.unpack " <> readModelName <> ".shapeHash)"
          ]
    policyFactRows
      | ownerDerived =
          [ "  , (\"freshness\", " <> tshow expectedFreshness <> ", show (readModelDefaultFreshness " <> readModelName <> "))",
            "  , (\"cursorAuthority\", " <> tshow expectedCursor <> ", show (readModelCursorAuthority " <> readModelName <> "))"
          ]
      | otherwise =
          [ "  , (\"consistency\", " <> tshow consistency <> ", show " <> readModelName <> ".defaultConsistency)",
            "  , (\"strongScope\", " <> tshow scope <> ", renderStrongScope " <> readModelName <> ".strongScope)"
          ]
    policyHelpers
      | ownerDerived = []
      | otherwise =
          [ "",
            "renderStrongScope :: StrongScope -> String",
            "renderStrongScope EntireLog = \"EntireLog\"",
            "renderStrongScope (CategoryHead categoryName) = \"CategoryHead \" <> T.unpack categoryName"
          ]
    catalogImports
      | catalogManaged =
          [ "import Data.List.NonEmpty qualified as NE",
            "import " <> contextGeneratedPrefix ctx <> ".ProjectionCatalog qualified as ProjectionCatalog",
            "import Keiro.Projection.Catalog qualified as Catalog"
          ]
      | otherwise = []
    supply =
      find
        ((== (.name) readModel) . (.queryModel))
        ((.resolvedProjectionSupplies) supplyAnalysis)
    resolvedOwner = do
      resolved <- supply
      find
        ((== (.projectionOwner) resolved) . (.name))
        [owner | NProjectionOwner owner <- (.nodes) spec]
    expectedCursor = case resolvedOwner of
      Just owner
        | (.delivery) owner == DeliverySubscription,
          Just subscription <- (.subscription) owner ->
            "DurableQueryCursor " <> T.pack (show subscription)
      _ -> "NoQueryCursor"
    expectedFreshness = case (.freshness) readModel of
      FreshnessImmediate -> "Immediate"
      FreshnessWaitForHead RmEntireLog -> "WaitForHead EntireVisibleLog"
      FreshnessWaitForHead (RmCategory categoryName) -> "WaitForHead (CategoryVisibleHead " <> T.pack (show categoryName) <> ")"
    feedingOwners =
      sortOn
        (.order)
        [ owner
        | Just resolved <- [supply],
          NProjectionOwner owner <- (.nodes) spec,
          (.name) owner == (.projectionOwner) resolved,
          (.delivery) owner == DeliverySubscription
        ]
    expectedCatalogRegistration =
      T.intercalate
        "|"
        [ expectedRegistry,
          T.pack (show ((.version) readModel)),
          (.shape) readModel,
          fromMaybe "" ((.group) readModel)
        ]
    expectedCatalogSupply = case supply of
      Nothing -> "missing"
      Just resolved ->
        T.intercalate
          "|"
          [ (.projectionOwner) resolved,
            (.rebuildGroup) resolved,
            T.intercalate "," (NE.toList ((.observedTargets) resolved))
          ]
    catalogHelpers
      | not catalogManaged = []
      | otherwise =
          [ "",
            "catalogFactsAgainst :: [Catalog.CatalogRegistration] -> [Catalog.AsyncProjectionRegistration] -> [Catalog.ResolvedQuerySupply] -> [(String, String, String)]",
            "catalogFactsAgainst registrations " <> asyncParameter <> " supplies ="
          ]
            <> catalogFactRows
            <> [ "",
                 "renderRegistration :: [Catalog.CatalogRegistration] -> String",
                 "renderRegistration [entry] = T.unpack entry.registryName <> \"|\" <> show entry.version <> \"|\" <> T.unpack entry.shapeHash <> \"|\" <> T.unpack (Catalog.rebuildGroupIdText entry.rebuildGroupId)",
                 "renderRegistration _ = \"missing\"",
                 "",
                 "renderSupply :: [Catalog.ResolvedQuerySupply] -> String",
                 "renderSupply [entry] = T.unpack (Catalog.projectionIdText entry.resolvedProjectionId) <> \"|\" <> T.unpack (Catalog.rebuildGroupIdText entry.resolvedRebuildGroupId) <> \"|\" <> T.unpack (T.intercalate \",\" (map Catalog.targetIdText (NE.toList entry.resolvedObservedTargets)))",
                 "renderSupply _ = \"missing\"",
                 "",
                 "renderDelivery :: [Catalog.ResolvedQuerySupply] -> String",
                 "renderDelivery [entry] = T.unpack (T.intercalate \",\" (map renderCapability (NE.toList entry.resolvedHandlerCapabilities)))",
                 "renderDelivery _ = \"missing\"",
                 "",
                 "renderCapability :: Catalog.ProjectionHandlerCapability -> T.Text",
                 "renderCapability Catalog.InlineCapability {} = \"inline\"",
                 "renderCapability Catalog.SubscriptionCapability {} = \"subscription\""
               ]
            <> asyncRenderHelper
    asyncRenderHelper
      | null feedingOwners = []
      | otherwise =
          [ "",
            "renderAsync :: [Catalog.AsyncProjectionRegistration] -> String",
            "renderAsync [entry] = T.unpack entry.subscriptionName <> \"|\" <> T.unpack entry.dedupName",
            "renderAsync _ = \"missing\""
          ]
    asyncParameter
      | null feedingOwners = "_asyncRegistrations"
      | otherwise = "asyncRegistrations"
    catalogFactRows =
      [ "  [ (\"catalogRegistration\", "
          <> tshow expectedCatalogRegistration
          <> ", renderRegistration [entry | entry <- registrations, Catalog.queryModelIdText entry.queryModelId == "
          <> tshow ((.name) readModel)
          <> "])",
        "  , (\"querySupply\", "
          <> tshow expectedCatalogSupply
          <> ", renderSupply [entry | entry <- supplies, Catalog.queryModelIdText entry.resolvedQueryModelId == "
          <> tshow ((.name) readModel)
          <> "])",
        "  , (\"projectionDelivery\", "
          <> tshow expectedDelivery
          <> ", renderDelivery [entry | entry <- supplies, Catalog.queryModelIdText entry.resolvedQueryModelId == "
          <> tshow ((.name) readModel)
          <> "])"
      ]
        <> [ "  , (\"asyncRegistration:"
               <> (.name) owner
               <> "\", "
               <> tshow (T.intercalate "|" [fromMaybe "" ((.subscription) owner), fromMaybe "" ((.dedup) owner)])
               <> ", renderAsync [entry | entry <- asyncRegistrations, Catalog.projectionIdText entry.projectionId == "
               <> tshow ((.name) owner)
               <> "])"
           | owner <- feedingOwners
           ]
        <> ["  ]"]
    expectedDelivery = case resolvedOwner of
      Just owner -> case (.delivery) owner of
        DeliveryInline -> "inline"
        DeliverySubscription -> "subscription"
      Nothing -> "missing"
    consistency = case legacyReadModelConsistency readModel of
      Just Strong -> "Strong"
      _ -> "Eventual"
    scope = case legacyReadModelScope readModel of
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
  [ ("fireAtField", (.field) ((.fireAt) timer)),
    ("timerIdPrefix", (.prefix) ((.id) timer)),
    ("firedEventIdPrefix", (.prefix) ((.firedEventId) timer')),
    ("dispatchIdUserField", "none"),
    ("onReject", showFireOutcome ((.onReject) fd)),
    ("onAmbiguous", showFireOutcome ((.onAmbiguous) fd)),
    ("onFailed", showDisp ((.onFailed) (firstDispDisposition p))),
    ("rejectedPolicy", showPolicy ((.rejected) p)),
    ("poisonPolicy", showPolicy ((.poison) p)),
    ("maxAttempts", tInt ((.maxAttempts) timer))
  ]
  where
    timer = (.timer) p
    timer' = (.fire) timer
    fd = (.disposition) timer'

firstDispDisposition :: ProcessNode -> DispatchDisposition
firstDispDisposition p = case (.dispatch) ((.handle) p) of
  (d : _) -> (.disposition) d
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
      { path = T.unpack (T.replace "." "/" genPrefix <> "/WorkflowFacts.hs"),
        text = emitWorkflowFacts genPrefix w,
        kind = Generated,
        origin = "workflow " <> (.id) w <> locSuffix (workflowNodeLoc w)
      },
    ScaffoldModule
      { path = T.unpack (T.replace "." "/" genPrefix <> "/WorkflowRuntime.hs"),
        text = emitWorkflowRuntime genPrefix w,
        kind = Generated,
        origin = "workflow " <> (.id) w <> locSuffix (workflowNodeLoc w)
      }
  ]
  where
    genPrefix = genPrefixFor ctx ((.id) w)

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
      "    { workflowFactName = " <> hs ((.stable) w),
      "    , workflowFactIdVia = " <> hs ((.idVia) w),
      "    , workflowFactIdField = " <> hs (maybe "input" id ((.idField) w)),
      "    , workflowFactBody = " <> stringList (map bodyTag ((.body) w)),
      "    , workflowFactAwaitLabels = " <> stringList (workflowAwaitLabels ((.body) w)),
      "    , workflowFactPatchIds = " <> stringList (workflowPatchIds ((.body) w)),
      "    }",
      "",
      "-- | Base-library projection used by the service-level conformance facade.",
      "workflowFactValues :: [(String, String)]",
      "workflowFactValues =",
      "  [ (\"name\", workflowFacts.workflowFactName)",
      "  , (\"idVia\", workflowFacts.workflowFactIdVia)",
      "  , (\"idField\", workflowFacts.workflowFactIdField)",
      "  , (\"body\", show workflowFacts.workflowFactBody)",
      "  , (\"awaits\", show workflowFacts.workflowFactAwaitLabels)",
      "  , (\"patches\", show workflowFacts.workflowFactPatchIds)",
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
  [ ("name", (.stable) workflow),
    ("idVia", (.idVia) workflow),
    ("idField", maybe "input" id ((.idField) workflow)),
    ("body", T.pack (show (map (T.unpack . bodyTag) ((.body) workflow)))),
    ("awaits", T.pack (show (map T.unpack (workflowAwaitLabels ((.body) workflow))))),
    ("patches", T.pack (show (map T.unpack (workflowPatchIds ((.body) workflow)))))
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

-- | Emit the workflow's live runtime support. Each declared await becomes an
-- opaque binding whose allocation delegates to @awakeableNamed@ and therefore
-- returns the only id that can signal the fresh row.
emitWorkflowRuntime :: Text -> WorkflowNode -> Text
emitWorkflowRuntime genPrefix w =
  nl $
    [ generatedBanner,
      "module " <> genPrefix <> ".WorkflowRuntime",
      "  ( workflowName",
      "  , AwaitBinding",
      "  , allocateDeclaredAwait"
    ]
      ++ ["  , " <> bindingName | (bindingName, _) <- awaitBindings]
      ++ [ "  , awaitLabels",
           "  , declaredPatches",
           "  , declaredPatchStepNames",
           "  , withDeclaredPatches",
           "  ) where",
           "",
           "import Data.Aeson (FromJSON)",
           "import Data.Set (Set)",
           "import Data.Set qualified as Set",
           "import Data.Text (Text)",
           "import Effectful (Eff, IOE, (:>))",
           "import Keiro.Workflow (StepName (..), Workflow, WorkflowRunOptions (..))",
           "import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed)",
           "import Keiro.Workflow.Types (PatchId (..), WorkflowName (..), patchStepName)",
           "import Kiroku.Store.Effect (Store)",
           "",
           "workflowName :: WorkflowName",
           "workflowName = WorkflowName " <> tshow ((.stable) w),
           "",
           "-- | A declared await label. The constructor stays private so consumers",
           "-- can allocate only labels that exist in the source workflow.",
           "data AwaitBinding = AwaitBinding StepName",
           "",
           "allocateDeclaredAwait",
           "  :: (Workflow :> es, Store :> es, IOE :> es, FromJSON a)",
           "  => AwaitBinding",
           "  -> Eff es (AwakeableId, Eff es a)",
           "allocateDeclaredAwait (AwaitBinding label) = awakeableNamed label",
           ""
         ]
      ++ concatMap emitBinding awaitBindings
      ++ [ "awaitLabels :: [Text]",
           "awaitLabels = [" <> T.intercalate ", " (map tshow (workflowAwaitLabels ((.body) w))) <> "]",
           "",
           "declaredPatches :: Set PatchId",
           "declaredPatches = Set.fromList [" <> T.intercalate ", " ["PatchId " <> tshow patchId | patchId <- workflowPatchIds ((.body) w)] <> "]",
           "",
           "-- The journal keys the runtime records patch decisions under.",
           "declaredPatchStepNames :: [Text]",
           "declaredPatchStepNames = map patchStepName (Set.toList declaredPatches)",
           "",
           "-- Activate exactly the patches declared by this spec for a workflow run.",
           "withDeclaredPatches :: WorkflowRunOptions -> WorkflowRunOptions",
           "withDeclaredPatches opts = opts{activePatches = declaredPatches}"
         ]
  where
    awaitBindings =
      [ (workflowAwaitBindingName w label loc, label)
      | (label, loc) <- workflowAwaits ((.body) w)
      ]
    emitBinding (bindingName, label) =
      [ bindingName <> " :: AwaitBinding",
        bindingName <> " = AwaitBinding (StepName " <> tshow label <> ")",
        ""
      ]

workflowAwaitBindingName :: WorkflowNode -> Name -> Loc -> Text
workflowAwaitBindingName workflow label loc =
  case HaskellName.deriveLowerHelperName HaskellName.LogicalWireWord "Await" site of
    Right name -> HaskellName.renderLowerCamelName name
    Left nameError -> error ("keiro-dsl workflow await binding invariant failed: " <> show nameError)
  where
    site =
      HaskellName.NameSite
        { HaskellName.kind = HaskellName.GeneratedValueSite,
          HaskellName.logicalName = label,
          HaskellName.owner = "workflow:" <> (.id) workflow <> ":await:" <> label,
          HaskellName.line = unLoc loc
        }

workflowAwaits :: [WfBodyItem] -> [(Name, Loc)]
workflowAwaits = concatMap go
  where
    go (WfAwait label _ loc) = [(label, loc)]
    go (WfPatch _ items _) = workflowAwaits items
    go _ = []

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
    renderGeneratedLanguagePragmas [ExtOverloadedLabels | not (null replayTransitions) && not (null ((.regs) a))]
      ++ [ generatedBanner,
           "module " <> (.genPrefix) a <> ".Harness (harnessAssertions) where",
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
      ++ [ "  , (\"golden round-trip: " <> (.name) e <> "\", roundTrips sampleEvent" <> (.name) e <> ")"
         | e <- (.events) a
         ]
      ++ [ "  , (\"accepts " <> (.command) t <> " from " <> initialVertex a <> "\", accept" <> (.command) t <> ")"
         | t <- map (.transition) (initialLiveTransitionEntries a)
         ]
      ++ [ "  ]"
         ]
      ++ ["  ++ mappedConformanceAssertions" | hasMappedHarness a]
      ++ ["  ++ nominalConformanceAssertions" | hasNominalHarness a]
      ++ [ "  ++ forwardReplay" <> (.command) t
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
      ++ concatMap (sampleEventDecl a) ((.events) a)
      ++ concatMap (acceptDecl a . (.transition)) (initialLiveTransitionEntries a)
      ++ concatMap (forwardReplayDecl a) replayTransitions
      ++ concatMap (upcastDecl goldens a) upcastEvents
      ++ mappedHarnessDeclarations a
      ++ nominalHarnessDeclarations a
  where
    nm = (.name) a
    clockFreeRows =
      if specIsClockFree a
        then ["  -- clock-free: spec samples no wall clock (verified at scaffold time)"]
        else ["  , (\"clock-free: spec samples no wall clock\", False)"]
    upcastEvents = [e | e <- (.events) a, (.upcastFrom) e /= Nothing]
    replayTransitions =
      [ t
      | entry <- initialLiveTransitionEntries a,
        let t = (.transition) entry,
        not (null ((.emits) t))
      ]
    coreImports =
      ["applyEventsEither" | not (null replayTransitions)]
        ++ ["defaultValidationOptions", "step", "validateTransducer"]
        ++ ["fieldWitnessAgrees" | not (null (nominalScalarHarnessTypes a)) || not (null (enforcedConsumerNominalIdHarnessTypes a))]
        ++ ["(!)" | not (null replayTransitions) && not (null ((.regs) a))]
    upcastAssertions =
      [ "(" <> tshow (upcastLabel e m) <> ", upcasts" <> (.name) e <> ")"
      | e <- upcastEvents,
        Just m <- [(.upcastFrom) e]
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
        [ "import " <> (.genPrefix) a <> ".Domain",
          "import " <> (.genPrefix) a <> ".Codec (encode" <> nm <> "Event, parse" <> nm <> "Event" <> codecValueImport <> mappedCodecHarnessExports a <> ")",
          transducerImport a,
          "import Keiki.Core (" <> T.intercalate ", " coreImports <> ")",
          codecDecodeRawImport
        ]
          ++ generatedNominalTypeImportsForService (aggregateCheckedService a) ((.context) a) (generatedNominalHarnessTypes a)
          ++ mappedHarnessImports a
          ++ nominalHarnessImports a
          ++ aggregateHarnessImports a
          ++ T.lines (renderPlannedImports (harnessImportPlan a))
          ++ goldenImports

    upcastLabel event source =
      case goldenFor goldens event of
        Just _ -> "golden " <> (.name) event <> ".v" <> tInt source <> " decodes"
        Nothing ->
          "upcast "
            <> (.name) event
            <> " chain wired (current-shape stand-in; add a golden payload)"

transducerImport :: Agg -> Text
transducerImport aggregate
  | usesGeneratedTransducer aggregate =
      "import "
        <> (.genPrefix) aggregate
        <> ".Transducer ("
        <> lowerFirst ((.name) aggregate)
        <> "Transducer)"
  | otherwise =
      "import "
        <> (.holePrefix) aggregate
        <> ".Holes ("
        <> lowerFirst ((.name) aggregate)
        <> "Transducer)"

usesGeneratedTransducer :: Agg -> Bool
usesGeneratedTransducer = any ((/= LegacyHoleImplementation) . (.implementation)) . (.transitions)

-- | Decode a genuine embedded old payload when available. Without a golden,
-- retain the weaker current-shape wiring assertion and label it honestly.
upcastDecl :: [GoldenPayload] -> Agg -> ResolvedCtor -> [Text]
upcastDecl goldens a e = case (.upcastFrom) e of
  Nothing -> []
  Just m -> case goldenFor goldens e of
    Just golden ->
      [ "",
        "upcasts" <> (.name) e <> " :: Bool",
        "upcasts" <> (.name) e <> " =",
        "  case eitherDecodeStrict (encodeUtf8 " <> tshow ((.json) golden) <> ") of",
        "    Left _ -> False",
        "    Right payload ->",
        "      either (const False) (const True)",
        "        (decodeRaw " <> lowerFirst ((.name) a) <> "Codec (EventType " <> tshow ((.name) e) <> ") " <> tInt m <> " payload)"
      ]
    Nothing ->
      [ "",
        "upcasts" <> (.name) e <> " :: Bool",
        "upcasts" <> (.name) e <> " =",
        "  either (const False) (const True)",
        "    (decodeRaw " <> lowerFirst ((.name) a) <> "Codec (EventType " <> tshow ((.name) e) <> ") " <> tInt m <> " (encode" <> (.name) a <> "Event sampleEvent" <> (.name) e <> "))"
      ]

hasGolden :: [GoldenPayload] -> ResolvedCtor -> Bool
hasGolden goldens event = case goldenFor goldens event of
  Just _ -> True
  Nothing -> False

goldenFor :: [GoldenPayload] -> ResolvedCtor -> Maybe GoldenPayload
goldenFor goldens event = do
  source <- (.upcastFrom) event
  find
    (\golden -> (.event) golden == (.name) event && (.version) golden == source)
    goldens

tInt :: Int -> Text
tInt = T.pack . show

-- | Render a Text as a Haskell string literal (quoted, escaped).
tshow :: Text -> Text
tshow = T.pack . show

nl :: [Text] -> Text
nl = T.intercalate "\n"

specIsClockFree :: Agg -> Bool
specIsClockFree a = not (any transitionSamplesClock ((.transitions) a))
  where
    clockAtoms = ["now", "currentTime", "wallClock", "today", "utcNow"]
    transitionSamplesClock t =
      let exprs = maybe [] pure ((.guard) t) ++ map snd ((.writes) t)
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
initialLiveTransitionEntries a = case map (.name) ((.states) a) of
  (s0 : _) ->
    [ entry
    | entry <- transitionLayoutForSource s0 (transitionLayout ((.transitions) a)),
      (.mode) ((.transition) entry) == TmLive
    ]
  [] -> []

-- | @sampleEvent<Ctor> :: <Agg>Event@ — a sample built from per-field sample
-- values (enum→first constructor, Bool→False, id→placeholder,
-- Text→\"sample-<fieldName>\").
sampleEventDecl :: Agg -> ResolvedCtor -> [Text]
sampleEventDecl a e =
  [ "",
    "sampleEvent" <> (.name) e <> " :: " <> (.name) a <> "Event",
    "sampleEvent" <> (.name) e <> " = " <> ctorExpr a e
  ]

harnessSampleDeclarations :: Agg -> [Text]
harnessSampleDeclarations aggregate =
  concatMap generatedIdDeclaration generatedIds <> timeDeclaration
  where
    generatedIds =
      [ nominal
      | nominal <- generatedNominalHarnessTypes aggregate,
        IdRepresentation prefix <- [(.representation) nominal],
        idDomainContractFor ((.languageContract) aggregate) prefix /= Nothing
      ]
    generatedIdDeclaration nominal = case (.representation) nominal of
      IdRepresentation prefix -> case idDomainContractFor ((.languageContract) aggregate) prefix of
        Just contract ->
          let typeName = (.name) nominal
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
    "accept" <> (.command) t <> " :: Bool",
    "accept" <> (.command) t <> " =",
    "  case step " <> lowerFirst ((.name) a) <> "Transducer (" <> initialVertex a <> ", initial" <> (.name) a <> "Regs) " <> cmdSample <> " of",
    "    Just (v, _, _) -> v == " <> vertexCtor a ((.goto) t),
    "    Nothing -> False"
  ]
  where
    cmdSample = case [c | c <- (.commands) a, (.name) c == (.command) t] of
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
    ++ [ "              , (prefix <> \"register " <> (.name) reg <> "\", (replayRegs ! #" <> (.name) reg <> ") == (forwardRegs ! #" <> (.name) reg <> "))"
       | reg <- (.regs) a
       ]
    ++ [ "              ]",
         "  where",
         "    prefix = \"forward/replay equality: " <> (.command) t <> " from " <> initial <> " -- \""
       ]
  where
    nm = (.name) a
    helperName = "forwardReplay" <> (.command) t
    transducer = lowerFirst nm <> "Transducer"
    codec = lowerFirst nm <> "Codec"
    initial = initialVertex a
    initialRegs = "initial" <> nm <> "Regs"
    forwardRegsName = if null ((.regs) a) then "_forwardRegs" else "forwardRegs"
    replayRegsName = if null ((.regs) a) then "_replayRegs" else "replayRegs"
    cmdSample = case [c | c <- (.commands) a, (.name) c == (.command) t] of
      (c : _) -> "(" <> commandCtorExpr a t c <> ")"
      [] -> "(error \"no command\")"

-- | @(<Ctor> (<Ctor>Data v1 v2 …))@ with positional sample field values.
ctorExpr :: Agg -> ResolvedCtor -> Text
ctorExpr a rc =
  (.name) rc <> " (" <> (.name) rc <> "Data" <> args <> ")"
  where
    args = T.concat [" " <> sampleValue a ((.dslName) identity) ty | (identity, ty) <- (.fields) rc]

-- | A transition command sample prefers the initial value of a same-named,
-- same-typed register only when the guard explicitly equates those two paths.
-- Inequality guards retain the ordinary sample so an enum such as @Paid@ does
-- not accidentally inherit a forbidden @Free@ register initial value.
commandCtorExpr :: Agg -> Transition -> ResolvedCtor -> Text
commandCtorExpr a transition rc =
  (.name) rc <> " (" <> (.name) rc <> "Data" <> args <> ")"
  where
    args = T.concat [" " <> commandSampleValue a transition ((.dslName) identity) ty | (identity, ty) <- (.fields) rc]

commandSampleValue :: Agg -> Transition -> Text -> ResolvedAggregateType -> Text
commandSampleValue aggregate transition name valueType = case valueType of
  AggregateNominal _
    | guardEquatesCommandAndRegister transition name -> case find matchesRegister ((.regs) aggregate) of
        Just register -> regInitialValueForHarness aggregate register
        Nothing -> fallback
  _ -> fallback
  where
    fallback = sampleValue aggregate name valueType
    matchesRegister register = (.name) register == name && (.valueType) register == valueType
    regInitialValueForHarness owner register = case (.initial) register of
      InitialNominal _ value -> renderHarnessReference owner (harnessQualifiedValueReference value)
      InitialMapped _ value -> renderHarnessReference owner (harnessQualifiedValueReference value)
      _ -> case (.valueType) register of
        AggregateNominal nominal -> case (.ownership) nominal of
          ConsumerNominal {} -> renderRegisterInitial ((.initial) register)
          GeneratedNominal ->
            fromMaybe
              (renderRegisterInitial ((.initial) register))
              (generatedIdSampleName nominal <$ generatedIdSampleHaskell owner nominal)
        _ -> renderRegisterInitial ((.initial) register)

guardEquatesCommandAndRegister :: Transition -> Text -> Bool
guardEquatesCommandAndRegister transition name = maybe False containsEquality ((.guard) transition)
  where
    containsEquality = \case
      EOr left right -> containsEquality left || containsEquality right
      EAnd left right -> containsEquality left || containsEquality right
      ECmp OpEq left right -> matchingPaths left right || matchingPaths right left
      _ -> False
    matchingPaths (EPath _ CommandRoot [commandField]) (EPath _ RegisterRoot [registerField]) =
      commandField == name && registerField == name
    matchingPaths _ _ = False

sampleValue :: Agg -> Text -> ResolvedAggregateType -> Text
sampleValue a name ty = case ty of
  AggregateNominal nominal
    | GeneratedNominal <- (.ownership) nominal,
      Just _ <- generatedIdSampleHaskell a nominal ->
        generatedIdSampleName nominal
  AggregateNominal nominal
    | ConsumerNominal binding <- (.ownership) nominal ->
        "(nominalFixtureDomain (NonEmpty.head (nominalFixtureCases "
          <> renderHarnessReference a (harnessQualifiedValueReference ((.fixtures) binding))
          <> ")))"
  AggregateTime -> harnessTimeSampleName a
  _ -> fallback
  where
    fallback = case fieldCat a ty of
      IdCat -> aggregateSampleHaskell ((.symbols) a) name ty
      EnumCat -> aggregateSampleHaskell ((.symbols) a) name ty
      MappedStructuralCat declaration _ -> fixtureSample a ((.fixtures) declaration)
      MappedOpaqueCat declaration -> fixtureSample a ((.fixtures) declaration)
      OtherCat -> case ty of
        AggregateVertex vertexType
          | vertexType == (.vertexType) a -> initialVertex a
        _ -> aggregateSampleHaskell ((.symbols) a) name ty

generatedIdSampleName :: ResolvedNominalType -> Text
generatedIdSampleName nominal = "sample" <> (.name) nominal

harnessUsesTime :: Agg -> Bool
harnessUsesTime aggregate =
  any ((== AggregateTime) . snd) (concatMap (.fields) ((.commands) aggregate <> (.events) aggregate))

harnessTimeSampleName :: Agg -> Text
harnessTimeSampleName aggregate
  | any isObservedAtTime (concatMap (.fields) ((.commands) aggregate <> (.events) aggregate)) = "sampleObservedAt"
  | otherwise = "sampleTime"
  where
    isObservedAtTime (identity, resolvedType) = (.dslName) identity == "observedAt" && resolvedType == AggregateTime

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
        <> ["import " <> nominalProjectionModule ((.context) aggregate) <> " qualified as NominalProjections" | not (null (nominalScalarHarnessTypes aggregate)) || not (null enforcedIds)]
  where
    nominals = consumerNominalHarnessTypes aggregate
    enforcedIds = enforcedConsumerNominalIdHarnessTypes aggregate

hasNominalHarness :: Agg -> Bool
hasNominalHarness = not . null . consumerNominalHarnessTypes

consumerNominalHarnessTypes :: Agg -> [ResolvedNominalType]
consumerNominalHarnessTypes aggregate =
  Map.elems . Map.fromList $
    [ ((.name) nominal, nominal)
    | resolvedType <- map snd (concatMap (.fields) ((.commands) aggregate <> (.events) aggregate)) <> map (.valueType) ((.regs) aggregate),
      AggregateNominal nominal <- [resolvedType],
      ConsumerNominal {} <- [(.ownership) nominal]
    ]

generatedNominalHarnessTypes :: Agg -> [ResolvedNominalType]
generatedNominalHarnessTypes aggregate =
  generatedNominalsInTypes
    (map snd (concatMap (.fields) ((.commands) aggregate <> (.events) aggregate)))

nominalScalarHarnessTypes :: Agg -> [ResolvedNominalType]
nominalScalarHarnessTypes aggregate =
  [ nominal
  | nominal <- consumerNominalHarnessTypes aggregate,
    ScalarRepresentation {} <- [(.representation) nominal]
  ]

enforcedConsumerNominalIdHarnessTypes :: Agg -> [ResolvedNominalType]
enforcedConsumerNominalIdHarnessTypes aggregate =
  [ nominal
  | nominal <- consumerNominalHarnessTypes aggregate,
    IdRepresentation prefix <- [(.representation) nominal],
    idDomainContractFor ((.languageContract) aggregate) prefix /= Nothing
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
    assertionsFor nominal = case (.ownership) nominal of
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
             | ScalarRepresentation {} <- [(.representation) nominal]
             ]
          <> idDomainAssertions name bindingName fixtures nominal
        where
          name = (.name) nominal
          bindingName = renderHarnessReference aggregate (harnessQualifiedValueReference ((.binding) binding))
          fixtureName = renderHarnessReference aggregate (harnessQualifiedValueReference ((.fixtures) binding))
          fixtures = "(NonEmpty.toList (nominalFixtureCases " <> fixtureName <> "))"
    idDomainAssertions name bindingName fixtures nominal = case (.representation) nominal of
      IdRepresentation prefix
        | Just contract <- idDomainContractFor ((.languageContract) aggregate) prefix ->
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
    [ ", encode" <> (.name) declaration <> "Mapped, decode" <> (.name) declaration <> "Mapped"
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
          { targetModule = (.genPrefix) aggregate <> ".Harness",
            localNames =
              Set.fromList
                [ (.name) aggregate <> "Command",
                  (.name) aggregate <> "Event",
                  (.name) aggregate <> "Regs",
                  (.vertexType) aggregate
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
          ConsumerNominal binding <- [(.ownership) nominal],
          reference <-
            map
              harnessQualifiedValueReference
              ( (.binding) binding
                  : (.fixtures) binding
                  : maybeToListHarness ((.initial) binding)
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
                ((.fixtures) structural : maybeToListHarness ((.initial) structural))
            ResolvedOpaque opaque ->
              map
                harnessQualifiedValueReference
                ((.fixtures) opaque : maybeToListHarness ((.initial) opaque))
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
mappedHarnessDeclarationsResolved aggregate = case (.typeGraph) aggregate of
  Nothing -> []
  Just graph ->
    [ declaration
    | key <- aggregateMappedClosure (semanticImpact graph) ((.name) aggregate),
      Just declaration <- [Map.lookup key ((.declarations) graph)]
    ]

mappedEventFields :: Agg -> [(ResolvedCtor, Text, ResolvedAggregateType, ResolvedMappedDecl)]
mappedEventFields aggregate =
  [ (event, (.dslName) identity, valueType, declaration)
  | event <- (.events) aggregate,
    (identity, valueType) <- (.fields) event,
    declaration <- maybeToListHarness (mappedDeclaration aggregate valueType)
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
      [ mappedEventAssertionName event name <> "Assertions"
      | (event, name, _, _) <- eventFields
      ]
        <> ["structuralWirePolicyAssertions" | not (null structuralWire)]

mappedDeclaration :: Agg -> ResolvedAggregateType -> Maybe ResolvedMappedDecl
mappedDeclaration aggregate resolvedType = do
  key <- case resolvedType of
    AggregateMapped mappedKey -> Just mappedKey
    _ -> Nothing
  graph <- (.typeGraph) aggregate
  Map.lookup key ((.declarations) graph)

mappedEventAssertionDecl :: Agg -> (ResolvedCtor, Text, ResolvedAggregateType, ResolvedMappedDecl) -> [Text]
mappedEventAssertionDecl aggregate (event, name, _fieldType, declaration) =
  [ "",
    valueName <> "Assertions :: [(String, Bool)]",
    valueName <> "Assertions =",
    "  [ (\"mapped codec round-trip: " <> (.name) event <> "/" <> name <> "/\" <> T.unpack label, roundTrips " <> eventExpression <> ")",
    "  | (label, mappedValue) <- NonEmpty.toList (fixtureCases " <> fixtures <> ")",
    "  ]"
  ]
  where
    valueName = mappedEventAssertionName event name
    fixtures = renderHarnessReference aggregate (harnessQualifiedValueReference (mappedFixtures declaration))
    eventExpression = ctorExprWithOverride aggregate event name "mappedValue"

mappedEventAssertionName :: ResolvedCtor -> Text -> Text
mappedEventAssertionName event name = lowerFirst ((.name) event) <> pascal name

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
    concatMap (recordMissingAssertions aggregate declaration) [field | field <- fields, (.presence) field == POptional]
      <> [unknownFieldAssertion aggregate declaration unknownFields]
  REnum entries -> map (enumArmAssertion aggregate declaration) entries <> [enumUnknownAssertion declaration]
  RUnion encoding arms ->
    map (unionArmAssertion aggregate declaration encoding) arms
      <> [unknownFieldAssertion aggregate declaration ((.unknownFields) encoding)]

wirePoliciesUseIsLeft :: [(StructuralDecl, ResolvedMappedShape)] -> Bool
wirePoliciesUseIsLeft = any $ \(_, shape) -> case shape of
  RRecord _ unknownFields fields ->
    unknownFields == RejectUnknown
      || any (\field -> (.presence) field == POptional && not (isOptionalType ((.valueType) field))) fields
  REnum {} -> True
  RUnion encoding _ -> (.unknownFields) encoding == RejectUnknown

wirePoliciesUseIsRight :: [(StructuralDecl, ResolvedMappedShape)] -> Bool
wirePoliciesUseIsRight = any $ \(_, shape) -> case shape of
  RRecord _ unknownFields fields ->
    unknownFields == IgnoreUnknown
      || any (\field -> (.presence) field == POptional && isOptionalType ((.valueType) field)) fields
  REnum {} -> False
  RUnion encoding _ -> (.unknownFields) encoding == IgnoreUnknown

isOptionalType :: ResolvedTypeExpr -> Bool
isOptionalType ROptional {} = True
isOptionalType _ = False

recordMissingAssertions :: Agg -> StructuralDecl -> ResolvedWireField -> [Text]
recordMissingAssertions aggregate declaration field =
  [ "(\"wire policy missing default: "
      <> canonical
      <> "/"
      <> (.key) field
      <> "\", case "
      <> decoder
      <> " (deleteObjectField "
      <> tshow ((.key) field)
      <> " ("
      <> encodedSample
      <> ")) of Left _ -> False; Right decoded -> objectField "
      <> tshow ((.key) field)
      <> " ("
      <> encoder
      <> " decoded) == Just ("
      <> missingExpectedValue aggregate field
      <> "))",
    "(\"wire policy explicit null: "
      <> canonical
      <> "/"
      <> (.key) field
      <> "\", "
      <> nullExpectation
      <> " ("
      <> decoder
      <> " (insertObjectField "
      <> tshow ((.key) field)
      <> " Aeson.Null ("
      <> encodedSample
      <> "))))"
  ]
  where
    canonical = unCanonicalTypeId ((.canonical) declaration)
    encoder = "encode" <> (.name) declaration <> "Mapped"
    decoder = "decode" <> (.name) declaration <> "Mapped"
    fixtures = renderHarnessReference aggregate (harnessQualifiedValueReference ((.fixtures) declaration))
    encodedSample = encoder <> " (snd (NonEmpty.head (fixtureCases " <> fixtures <> ")))"
    nullExpectation = case (.valueType) field of
      ROptional _ -> "isRight"
      _ -> "isLeft"

missingExpectedValue :: Agg -> ResolvedWireField -> Text
missingExpectedValue aggregate field = case (.onMissing) field of
  Just OmNull -> "Aeson.Null"
  Just (OmText value) -> "Aeson.String " <> tshow value
  Just (OmInt value) -> "Aeson.toJSON (" <> T.pack (show value) <> " :: Int)"
  Just (OmBool value) -> if value then "Aeson.Bool True" else "Aeson.Bool False"
  Just OmEmptyList -> "Aeson.toJSON ([] :: [Aeson.Value])"
  Just OmEmptyMap -> "Aeson.Object mempty"
  Just (OmCtor constructor) -> case ((.typeGraph) aggregate, (.valueType) field) of
    (Just graph, RRef key) -> case Map.lookup key ((.declarations) graph) of
      Just (ResolvedStructural _ (REnum entries)) -> case find ((== constructor) . (.ctor)) entries of
        Just entry -> "Aeson.String " <> tshow ((.tag) entry)
        Nothing -> "error \"missing enum default constructor\""
      _ -> "error \"non-enum constructor default\""
    _ -> "error \"non-reference constructor default\""
  Nothing -> "error \"optional field lacks on-missing policy\""

unknownFieldAssertion :: Agg -> StructuralDecl -> UnknownFields -> Text
unknownFieldAssertion aggregate declaration policy =
  "(\"wire policy unknown fields: "
    <> unCanonicalTypeId ((.canonical) declaration)
    <> "\", all (\\(_, value) -> "
    <> expectation
    <> " (decode"
    <> (.name) declaration
    <> "Mapped (insertObjectField \"__keiro_unknown\" (Aeson.Bool True) (encode"
    <> (.name) declaration
    <> "Mapped value)))) (NonEmpty.toList (fixtureCases "
    <> renderHarnessReference aggregate (harnessQualifiedValueReference ((.fixtures) declaration))
    <> ")))"
  where
    expectation = case policy of
      RejectUnknown -> "isLeft"
      IgnoreUnknown -> "isRight"

enumArmAssertion :: Agg -> StructuralDecl -> WireEnum -> Text
enumArmAssertion aggregate declaration entry =
  "(\"wire enum arm: "
    <> unCanonicalTypeId ((.canonical) declaration)
    <> "/"
    <> (.tag) entry
    <> "\", any (\\(_, value) -> encode"
    <> (.name) declaration
    <> "Mapped value == Aeson.String "
    <> tshow ((.tag) entry)
    <> " && decode"
    <> (.name) declaration
    <> "Mapped (Aeson.String "
    <> tshow ((.tag) entry)
    <> ") == Right value) (NonEmpty.toList (fixtureCases "
    <> renderHarnessReference aggregate (harnessQualifiedValueReference ((.fixtures) declaration))
    <> ")))"

enumUnknownAssertion :: StructuralDecl -> Text
enumUnknownAssertion declaration =
  "(\"wire enum unknown tag: "
    <> unCanonicalTypeId ((.canonical) declaration)
    <> "\", isLeft (decode"
    <> (.name) declaration
    <> "Mapped (Aeson.String \"__keiro_unknown\")))"

unionArmAssertion :: Agg -> StructuralDecl -> UnionEncoding -> ResolvedWireArm -> Text
unionArmAssertion aggregate declaration encoding arm =
  "(\"wire union arm: "
    <> unCanonicalTypeId ((.canonical) declaration)
    <> "/"
    <> (.tag) arm
    <> "\", any (\\(_, value) -> objectField "
    <> tshow ((.tagField) encoding)
    <> " (encode"
    <> (.name) declaration
    <> "Mapped value) == Just (Aeson.String "
    <> tshow ((.tag) arm)
    <> ") && decode"
    <> (.name) declaration
    <> "Mapped (encode"
    <> (.name) declaration
    <> "Mapped value) == Right value) (NonEmpty.toList (fixtureCases "
    <> renderHarnessReference aggregate (harnessQualifiedValueReference ((.fixtures) declaration))
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
    hasOptionalRecordField (_, RRecord _ _ fields) = any ((== POptional) . (.presence)) fields
    hasOptionalRecordField _ = False
    isUnion (_, RUnion {}) = True
    isUnion _ = False

mappedFixtures :: ResolvedMappedDecl -> QualifiedValueName
mappedFixtures (ResolvedStructural declaration _) = (.fixtures) declaration
mappedFixtures (ResolvedOpaque declaration) = (.fixtures) declaration

ctorExprWithOverride :: Agg -> ResolvedCtor -> Text -> Text -> Text
ctorExprWithOverride aggregate constructor target replacement =
  "(" <> (.name) constructor <> " (" <> (.name) constructor <> "Data" <> arguments <> "))"
  where
    arguments =
      T.concat
        [ " " <> if (.dslName) identity == target then replacement else sampleValue aggregate ((.dslName) identity) valueType
        | (identity, valueType) <- (.fields) constructor
        ]

maybeToListHarness :: Maybe value -> [value]
maybeToListHarness = maybe [] pure
