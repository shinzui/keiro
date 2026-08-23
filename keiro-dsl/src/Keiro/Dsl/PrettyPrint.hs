-- | Pretty-printer for the keiro DSL: renders a 'Spec' back to @.keiro@ text.
-- The layout need not be byte-identical to the original source (the parser
-- treats whitespace as insignificant), but it must round-trip:
-- @parseSpec (renderSpec s) == Right s@ modulo source locations. The only
-- subtle part is expression printing, which uses a @showsPrec@-style precedence
-- scheme so left-associative @&&@/@||@ and non-associative comparisons re-parse
-- to the identical AST.
module Keiro.Dsl.PrettyPrint
  ( renderSource,
    renderSpec,
    renderTransition,
    renderExpr,
    renderTypeExpr,
    renderHandleSurface,
    renderResolveSurface,
    renderRouterDispatchSurface,
    renderTimerPayloadSurface,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Prettyprinter
import Prettyprinter.Render.Text (renderStrict)

-- | Render a whole spec to text.
renderSpec :: Spec -> Text
renderSpec = renderDoc . docSpec

-- | Render a source while preserving whether it explicitly declared a version.
renderSource :: ParsedSource -> Text
renderSource ParsedSource {sourceLanguage = sourceLanguage, spec = spec} =
  case sourceLanguage of
    LegacyUnversioned -> renderSpec spec
    DeclaredLanguage {declaredLanguageVersion = version} ->
      "language keiro-dsl " <> languageVersionText version <> "\n" <> renderSpec spec

renderHandleSurface :: HandleNode -> Text
renderHandleSurface = renderDoc . docHandle

renderResolveSurface :: ResolveDecl -> Text
renderResolveSurface = renderDoc . docResolve

renderRouterDispatchSurface :: RouterDispatchNode -> Text
renderRouterDispatchSurface = renderDoc . docRouterDispatch

renderTimerPayloadSurface :: TimerNode -> Text
renderTimerPayloadSurface timer =
  renderDoc ("payload" <+> braced (map docFieldBinding ((.payload) timer)))

renderTypeExpr :: TypeExpr -> Text
renderTypeExpr = renderDoc . docTypeExpr

renderDoc :: Doc ann -> Text
renderDoc = renderStrict . layoutPretty LayoutOptions {layoutPageWidth = Unbounded}

docSpec :: Spec -> Doc ann
docSpec s =
  vsep $
    ["context" <+> pretty ((.context) s)]
      ++ maybe [] (\r -> ["module" <+> pretty r]) ((.moduleRoot) s)
      ++ maybe [] (\l -> ["layout" <+> docLayout l]) ((.layout) s)
      ++ [mempty]
      ++ map docId ((.ids) s)
      ++ blankAfter ((.ids) s)
      ++ map docEnum ((.enums) s)
      ++ blankAfter ((.enums) s)
      ++ map docRule ((.rules) s)
      ++ blankAfter ((.rules) s)
      ++ map docNominalScalar ((.nominalScalars) s)
      ++ blankAfter ((.nominalScalars) s)
      ++ map docMapped ((.mapped) s)
      ++ blankAfter ((.mapped) s)
      ++ map docNode ((.nodes) s)
  where
    blankAfter xs = if null xs then [] else [mempty]

docLayout :: Placement -> Doc ann
docLayout GeneratedPrefix = "prefixed"
docLayout CollocatedLeaf = "collocated"

docId :: IdDecl -> Doc ann
docId d =
  case (.binding) d of
    Nothing -> "id" <+> pretty ((.name) d) <+> ("prefix=" <> pretty ((.prefix) d))
    Just binding ->
      vsep $
        ["id" <+> pretty ((.name) d) <+> ("prefix=" <> pretty ((.prefix) d)) <+> "using" <+> "{"]
          ++ map (indent 2) (docNominalBindingFacts binding)
          ++ ["}"]

docEnum :: EnumDecl -> Doc ann
docEnum d =
  case (.binding) d of
    Nothing -> enumHeader
    Just binding ->
      vsep $
        [enumHeader <+> "using" <+> "{"]
          ++ map (indent 2) (docNominalBindingFacts binding)
          ++ ["}"]
  where
    enumHeader = "enum" <+> pretty ((.name) d) <+> braced (map ctor ((.ctors) d))
    ctor (c, w) = pretty c <> "=" <> pretty w

docRule :: RuleDecl -> Doc ann
docRule d =
  vsep
    [ "rule" <+> pretty ((.name) d) <+> ":" <+> pretty ((.domain) d) <+> "->" <+> pretty ((.codomain) d),
      indent 2 ("ex" <+> hsep (punctuate " ;" (map cas ((.cases) d))))
    ]
  where
    cas (c, e) = pretty c <+> "=>" <+> docExpr 0 e

docMapped :: MappedDecl -> Doc ann
docMapped MappedStructural {msName = name, msHaskell = haskell, msBinding = binding, msBindingVersion = bindingVersion, msCanonical = canonical, msFixtures = fixtures, msInitial = initial, msShape = shape} =
  vsep $
    ["mapped structural" <+> docShapeKind shape <+> pretty name <+> "{"]
      ++ maybe [] (pure . indent 2 . docHaskellSource) haskell
      ++ maybe [] (pure . indent 2 . docQuotedFact "binding") binding
      ++ maybe [] (pure . indent 2 . docQuotedFact "binding-version") bindingVersion
      ++ maybe [] (pure . indent 2 . docQuotedFact "canonical-type") canonical
      ++ maybe [] (pure . indent 2 . docQuotedFact "fixtures") fixtures
      ++ maybe [] (pure . indent 2 . docQuotedFact "initial") initial
      ++ [indent 2 (docMappedShape shape), "}"]
docMapped MappedOpaque {moName = name, moHaskell = haskell, moCodecId = codec, moCodecVersion = version, moFixtures = fixtures, moInitial = initial} =
  vsep $
    ["mapped opaque" <+> pretty name <+> "{"]
      ++ maybe [] (pure . indent 2 . docHaskellSource) haskell
      ++ maybe [] (pure . indent 2 . docQuotedFact "codec") codec
      ++ maybe [] (pure . indent 2 . docQuotedFact "version") version
      ++ maybe [] (pure . indent 2 . docQuotedFact "fixtures") fixtures
      ++ maybe [] (pure . indent 2 . docQuotedFact "initial") initial
      ++ ["}"]

docNominalScalar :: NominalScalarDecl -> Doc ann
docNominalScalar declaration =
  vsep $
    [ "mapped nominal"
        <+> pretty ((.name) declaration)
        <+> ":"
        <+> pretty ((.representation) declaration)
        <+> "{"
    ]
      ++ map (indent 2) (docNominalBindingFacts ((.binding) declaration))
      ++ ["}"]

docNominalBindingFacts :: NominalBindingDecl -> [Doc ann]
docNominalBindingFacts binding =
  maybe [] (pure . docHaskellSource) ((.haskell) binding)
    ++ maybe [] (pure . docQuotedFact "binding") ((.binding) binding)
    ++ maybe [] (pure . docQuotedFact "binding-version") ((.bindingVersion) binding)
    ++ maybe [] (pure . docQuotedFact "canonical-type") ((.canonicalType) binding)
    ++ maybe [] (pure . docQuotedFact "fixtures") ((.fixtures) binding)
    ++ maybe [] (pure . docQuotedFact "initial") ((.initial) binding)

docShapeKind :: MappedShape -> Doc ann
docShapeKind (ShapeRecord _ _ _) = "record"
docShapeKind (ShapeEnum _) = "enum"
docShapeKind (ShapeUnion _ _) = "union"

docHaskellSource :: HaskellSource -> Doc ann
docHaskellSource source =
  "haskell"
    <+> ("package=" <> pretty ((.package) source))
    <+> ("module=" <> pretty ((.moduleName) source))
    <+> ("type=" <> pretty ((.valueType) source))

docQuotedFact :: Doc ann -> Text -> Doc ann
docQuotedFact label value = label <+> "=" <+> dquoted value

docMappedShape :: MappedShape -> Doc ann
docMappedShape (ShapeRecord constructor unknownFields fields) =
  vsep $
    [ "wire object"
        <+> ("constructor=" <> pretty constructor)
        <+> ("unknown-fields=" <> docUnknownFields unknownFields)
        <+> "{"
    ]
      ++ map (indent 2 . docWireField) fields
      ++ ["}"]
docMappedShape (ShapeEnum entries) =
  vsep $ ["wire string {"] ++ map (indent 2 . docWireEnum) entries ++ ["}"]
docMappedShape (ShapeUnion encoding arms) =
  vsep $
    [ "wire tagged-object"
        <+> ("tag=" <> dquoted ((.tagField) encoding))
        <+> ("contents=" <> dquoted ((.contentsField) encoding))
        <+> ("unknown-fields=" <> docUnknownFields ((.unknownFields) encoding))
        <+> "{"
    ]
      ++ map (indent 2 . docWireArm) arms
      ++ ["}"]

docUnknownFields :: UnknownFields -> Doc ann
docUnknownFields RejectUnknown = "reject"
docUnknownFields IgnoreUnknown = "ignore"

docWireField :: WireField -> Doc ann
docWireField field =
  pretty ((.haskell) field)
    <+> "as"
    <+> dquoted ((.key) field)
    <+> ":"
    <+> docTypeExpr ((.valueType) field)
    <+> docPresence ((.presence) field)
    <> maybe mempty (\value -> " on-missing=" <> docOnMissing value) ((.onMissing) field)

docPresence :: Presence -> Doc ann
docPresence PRequired = "required"
docPresence POptional = "optional"

docOnMissing :: OnMissing -> Doc ann
docOnMissing OmNull = "null"
docOnMissing (OmText value) = dquoted value
docOnMissing (OmInt value) = pretty value
docOnMissing (OmBool True) = "true"
docOnMissing (OmBool False) = "false"
docOnMissing OmEmptyList = "[]"
docOnMissing OmEmptyMap = "{}"
docOnMissing (OmCtor constructor) = pretty constructor

docWireEnum :: WireEnum -> Doc ann
docWireEnum entry = pretty ((.ctor) entry) <+> "as" <+> dquoted ((.tag) entry)

docWireArm :: WireArm -> Doc ann
docWireArm arm =
  pretty ((.ctor) arm)
    <+> "as"
    <+> dquoted ((.tag) arm)
    <> maybe mempty (\payload -> " : " <> docTypeExpr payload) ((.payload) arm)

docTypeExpr :: TypeExpr -> Doc ann
docTypeExpr TText = "Text"
docTypeExpr TInt = "Int"
docTypeExpr TInteger = "Integer"
docTypeExpr TBool = "Bool"
docTypeExpr TNatural = "Natural"
docTypeExpr TTime = "Time"
docTypeExpr TJson = "Json"
docTypeExpr (TOptional value) = "Optional" <+> docTypeArgument value
docTypeExpr (TList value) = "List" <+> docTypeArgument value
docTypeExpr (TMap value) = "Map" <+> docTypeArgument value
docTypeExpr (TRef name) = pretty name

docTypeArgument :: TypeExpr -> Doc ann
docTypeArgument value@TOptional {} = parens (docTypeExpr value)
docTypeArgument value@TList {} = parens (docTypeExpr value)
docTypeArgument value@TMap {} = parens (docTypeExpr value)
docTypeArgument value = docTypeExpr value

docNode :: Node -> Doc ann
docNode (NAggregate a) = docAggregate a
docNode (NProcess p) = docProcess p
docNode (NRouter r) = docRouter r
docNode (NContract c) = docContract c
docNode (NIntake i) = docIntake i
docNode (NEmit e) = docEmit e
docNode (NPublisher p) = docPublisher p
docNode (NWorkqueue w) = docWorkqueue w
docNode (NPgmqDispatch d) = docPgmqDispatch d
docNode (NReadModel r) = docReadModel r
docNode (NProjectionTarget target) = docProjectionTarget target
docNode (NRebuildGroup groupNode) = docRebuildGroup groupNode
docNode (NProjectionRevision revision) = docProjectionRevision revision
docNode (NExternalRead externalRead) = docExternalRead externalRead
docNode (NProjectionOwner owner) = docProjectionOwner owner
docNode (NWorkflow w) = docWorkflow w
docNode (NOperation o) = docOperation o

docWorkflow :: WorkflowNode -> Doc ann
docWorkflow w =
  vsep $
    [ "workflow" <+> pretty ((.id) w),
      indent 2 ("name" <+> dquoted ((.stable) w)),
      indent 2 ("in" <+> pretty ((.input) w) <> inFieldsDoc),
      indent 2 ("out" <+> pretty ((.output) w)),
      indent 2 ("id from input" <> maybe mempty (\f -> "." <> pretty f) ((.idField) w) <+> "via" <+> pretty ((.idVia) w)),
      indent 2 "body"
    ]
      ++ map (indent 4 . bodyItem) ((.body) w)
  where
    inFieldsDoc = case (.inputFields) w of
      [] -> mempty
      fs -> " " <> braced (map docField fs)
    bodyItem (WfStep l r _) = "step" <+> pretty l <+> "->" <+> pretty r
    bodyItem (WfAwait l r _) = "await" <+> pretty l <+> "->" <+> pretty r
    bodyItem (WfSleep l a _) = "sleep" <+> pretty l <+> "after" <+> pretty a
    bodyItem (WfChild l v r _) = "child" <+> pretty l <+> "id input via" <+> pretty v <+> "->" <+> pretty r
    bodyItem (WfPatch patchId items _) =
      vsep $ ["patch" <+> pretty patchId <+> "{"] ++ map (indent 2 . bodyItem) items ++ ["}"]
    bodyItem (WfContinueAsNew seedType _) = "continueAsNew" <+> pretty seedType

docOperation :: OperationNode -> Doc ann
docOperation o =
  vsep $ ["operation" <+> pretty ((.name) o)] ++ map (indent 2) (shapeLines ((.shape) o))
  where
    shapeLines (CommandOp agg sf sv proj) =
      [ "command on" <+> pretty agg,
        indent 2 ("stream from" <+> pretty sf <+> "via" <+> pretty sv)
      ]
        ++ [indent 2 ("project" <+> bracketed (map pretty proj)) | not (null proj)]
    shapeLines (QueryOp rm inp res cons) =
      [ "query" <+> pretty rm,
        indent 2 ("input" <+> pretty inp),
        indent 2 ("result" <+> pretty res),
        indent 2 ("consistency" <+> pretty cons)
      ]
    shapeLines (SignalOp lbl wf kf kv val) =
      [ "signal" <+> pretty lbl <+> "of" <+> pretty wf,
        indent 2 ("key from" <+> pretty kf <+> "via" <+> pretty kv),
        indent 2 ("value" <+> pretty val)
      ]
    shapeLines (RunOp wf inp oc) =
      [ "run" <+> pretty wf,
        indent 2 ("input" <+> pretty inp),
        indent 2 ("outcome ->" <+> pretty oc)
      ]

docWorkqueue :: WorkqueueNode -> Doc ann
docWorkqueue w =
  vsep $
    [ "workqueue" <+> pretty ((.name) w) <+> "{",
      indent 2 ("queue logical =" <+> dquoted ((.logical) w)),
      indent 2 ("derive physical =" <+> dquoted ((.physical) w)),
      indent 4 ("dlq =" <+> dquoted ((.dlq) w)),
      indent 4 ("table =" <+> dquoted ((.table) w))
    ]
      ++ orderingLines
      ++ groupKeyLines
      ++ provisionLines
      ++ [indent 2 ("payload" <+> pretty ((.payloadName) w) <+> "{")]
      ++ map (indent 4 . field) ((.payload) w)
      ++ [ indent 2 "}",
           indent 2 ("retry maxRetries =" <+> pretty ((.maxRetries) w) <+> "delay =" <+> pretty ((.delay) w) <+> "dlq =" <+> (if (.dlqOn) w then "on" else "off")),
           indent 2 "disposition {"
         ]
      ++ map (indent 4 . dispRow) ((.disposition) w)
      ++ [indent 2 "}", "}"]
  where
    orderingLines = case (.ordering) w of
      WqUnordered -> []
      WqFifoThroughput -> [indent 2 "ordering fifo-throughput"]
      WqFifoRoundRobin -> [indent 2 "ordering fifo-roundrobin"]
    groupKeyLines = case (.groupKey) w of
      Nothing -> []
      Just groupKey ->
        [ indent 2 $
            "group key from"
              <+> pretty ((.field) groupKey)
              <+> "via"
              <+> pretty ((.via) groupKey)
              <> maybe mempty (\fixture -> " fixture " <> dquoted fixture) ((.fixture) groupKey)
        ]
    provisionLines = case (.provision) w of
      WqStandard -> []
      WqUnlogged -> [indent 2 "provision unlogged"]
      WqPartitioned interval retention ->
        [indent 2 ("provision partitioned(interval=" <> dquoted interval <> ", retention=" <> dquoted retention <> ")")]
    -- Always rendered: every payload field is required, and stating it keeps
    -- the canonical form self-describing.
    field f = pretty ((.name) f) <+> "->" <+> dquoted ((.wire) f) <+> docQueuePayloadType ((.valueType) f) <> " required"
    docQueuePayloadType (LegacyQueueScalar QueueText) = "text"
    docQueuePayloadType (LegacyQueueScalar QueueInt) = "int"
    docQueuePayloadType (LegacyQueueScalar QueueBool) = "bool"
    docQueuePayloadType (LegacyQueueScalar (QueueOther name)) = pretty name
    docQueuePayloadType (TypedQueueExpression expression) = ":" <+> docTypeExpr expression
    dispRow r = pretty ((.outcome) r) <+> "->" <+> act ((.action) r)
    act IAckOk = "ackOk"
    act (IRetry win) = "retry" <+> pretty win
    act (IDeadLetter Nothing) = "deadLetter"
    act (IDeadLetter (Just reason)) = "deadLetter" <+> dquoted reason

docPgmqDispatch :: PgmqDispatchNode -> Doc ann
docPgmqDispatch d =
  vsep
    [ "dispatch" <+> pretty ((.name) d) <+> "{",
      indent 2 ("source readModel =" <+> pretty ((.sourceReadModel) d) <+> "key =" <+> pretty ((.sourceKey) d)),
      indent 2 ("fanout body =" <+> pretty ((.fanoutBody) d)),
      indent 2 ("dedup key =" <+> pretty ((.dedupKey) d)),
      indent 4 ("seenIn readModel =" <+> pretty ((.dedupReadModel) d) <+> "field =" <+> pretty ((.dedupReadModelField) d)),
      indent 4 ("seenIn queue =" <+> pretty ((.dedupQueue) d) <+> "field =" <+> pretty ((.dedupQueueField) d)),
      indent 2 ("enqueue to =" <+> pretty ((.enqueueTo) d)),
      "}"
    ]

docReadModel :: ReadModelNode -> Doc ann
docReadModel readModel =
  vsep $
    ["readmodel" <+> pretty ((.name) readModel) <+> "{"]
      ++ ( if not (T.null ((.table) readModel)) || not (T.null ((.schema) readModel))
             then
               [ indent 2 ("table =" <+> dquoted ((.table) readModel)),
                 indent 2 ("schema =" <+> dquoted ((.schema) readModel))
               ]
             else []
         )
      ++ [indent 2 "columns {"]
      ++ map (indent 4 . docColumn) ((.columns) readModel)
      ++ [indent 2 "}"]
      ++ maybe [] docQueryTypes ((.queryTypes) readModel)
      ++ [ indent 2 ("version =" <+> pretty ((.version) readModel)),
           indent 2 ("shape =" <+> dquoted ((.shape) readModel))
         ]
      ++ policyLines
      ++ maybe [] (pure . indent 2 . ("group =" <+>) . pretty) ((.group) readModel)
      ++ [indent 2 ("targets =" <+> bracketed (map pretty ((.observedTargets) readModel))) | (.group) readModel /= Nothing]
      ++ maybe [] (pure . indent 2 . ("backing =" <+>) . pretty) ((.backingTarget) readModel)
      ++ ["}"]
  where
    docColumn columnDecl =
      pretty ((.rmcName) columnDecl)
        <+> pretty ((.rmcType) columnDecl)
        <> if (.rmcRequired) columnDecl then " required" else mempty
    docScope RmEntireLog = "entire-log"
    docScope (RmCategory categoryName) = "category" <+> dquoted categoryName
    docFeed RmInline = "inline"
    docFeed RmSubscription = "subscription"
    policyLines = case (.supply) readModel of
      LegacyReadModelSupply {legacyConsistency, legacyScope, legacyFeed, legacySubscription} ->
        [indent 2 ("consistency =" <+> docConsistency legacyConsistency)]
          ++ maybe [] (pure . indent 2 . ("scope =" <+>) . docScope) legacyScope
          ++ [indent 2 ("feed =" <+> docFeed legacyFeed)]
          ++ maybe [] (pure . indent 2 . ("subscription =" <+>) . dquoted) legacySubscription
      OwnerDerivedSupply ->
        [indent 2 ("freshness =" <+> docFreshness ((.freshness) readModel))]
    docFreshness FreshnessImmediate = "immediate"
    docFreshness (FreshnessWaitForHead scope) = "wait-for-head" <+> docScope scope
    docQueryTypes ReadModelQueryTypes {input, result} =
      [ indent 2 ("query input =" <+> docTypeExpr input),
        indent 2 ("query result =" <+> docTypeExpr result)
      ]

docProjectionTarget :: ProjectionTargetNode -> Doc ann
docProjectionTarget target =
  vsep $
    [ "target" <+> pretty ((.name) target) <+> "{",
      indent 2 ("schema =" <+> dquoted ((.schema) target)),
      indent 2 ("table =" <+> dquoted ((.table) target)),
      indent 2 ("reset =" <+> case (.reset) target of TargetClear -> "clear"; TargetPreserve -> "preserve")
    ]
      ++ [indent 2 ("depends-on =" <+> bracketed (map pretty ((.dependsOn) target))) | not (null ((.dependsOn) target))]
      ++ ["}"]

docRebuildGroup :: RebuildGroupNode -> Doc ann
docRebuildGroup groupNode =
  vsep
    [ "rebuild-group" <+> pretty ((.name) groupNode) <+> "{",
      indent 2 ("targets =" <+> bracketed (map pretty ((.targets) groupNode))),
      indent 2 ("order =" <+> bracketed (map pretty ((.order) groupNode))),
      "}"
    ]

docProjectionRevision :: ProjectionRevisionNode -> Doc ann
docProjectionRevision revision =
  vsep $
    [ "projection-revision" <+> pretty ((.name) revision) <+> "{",
      indent 2 ("group =" <+> pretty ((.group) revision))
    ]
      <> concatMap (pure . indent 2 . docRevisionTarget) ((.targets) revision)
      <> ["}"]
  where
    docRevisionTarget target =
      vsep $
        [ "target" <+> pretty ((.target) target) <+> "{",
          indent 2 ("schema-version =" <+> dquoted ((.schemaVersion) target)),
          indent 2 ("provisioner =" <+> dquoted ((.provisioner) target)),
          indent 2 ("provisioner-version =" <+> pretty ((.provisionerVersion) target)),
          indent 2 ("expected-shape =" <+> dquoted ((.expectedShape) target)),
          indent 2 ("validator =" <+> dquoted ((.validator) target)),
          indent 2 ("validator-version =" <+> pretty ((.validatorVersion) target))
        ]
          <> map (indent 2 . docPromotionObject) ((.promotionObjects) target)
          <> ["}"]
    docPromotionObject promotionObject =
      "promotion"
        <+> ( case (.kind) promotionObject of
                PromotionIndexNode -> "index"
                PromotionConstraintNode -> "constraint"
                PromotionOwnedSequenceNode -> "owned-sequence"
            )
        <+> dquoted ((.generationName) promotionObject)
        <+> "->"
        <+> dquoted ((.canonicalName) promotionObject)

docExternalRead :: ExternalReadNode -> Doc ann
docExternalRead externalRead =
  vsep
    [ "external-read" <+> pretty ((.name) externalRead) <+> "{",
      indent 2 ("version =" <+> pretty ((.version) externalRead)),
      indent 2 ("query =" <+> pretty ((.queryModel) externalRead)),
      indent 2 ("result-schema =" <+> dquoted ((.resultSchema) externalRead)),
      indent 2 ("result-type =" <+> dquoted ((.resultType) externalRead)),
      indent 2 ("compatible-revisions =" <+> bracketed (map pretty ((.compatibleRevisions) externalRead))),
      indent 2 ("surface-generation =" <+> pretty ((.surfaceGeneration) externalRead)),
      "}"
    ]

docProjectionOwner :: ProjectionOwnerNode -> Doc ann
docProjectionOwner owner =
  vsep $
    ["projection-owner" <+> pretty ((.name) owner) <+> "{"]
      ++ map (indent 2 . ("source =" <+>) . docSource) ((.sources) owner)
      ++ [ indent 2 ("delivery =" <+> case (.delivery) owner of DeliveryInline -> "inline"; DeliverySubscription -> "subscription"),
           indent 2 ("group =" <+> pretty ((.group) owner)),
           indent 2 ("targets =" <+> bracketed (map pretty ((.targets) owner))),
           indent 2 ("order =" <+> pretty ((.order) owner))
         ]
      ++ maybe [] (pure . indent 2 . ("subscription =" <+>) . dquoted) ((.subscription) owner)
      ++ maybe [] (pure . indent 2 . ("dedup =" <+>) . dquoted) ((.dedup) owner)
      ++ map (indent 2 . ("checkpoint-on-missing =" <+>) . docCheckpointOnMissing) ((.checkpointOnMissing) owner)
      ++ [indent 2 ("replay =" <+> docReplay ((.replay) owner)), "}"]
  where
    docSource (CatalogAggregate aggregateName) = "aggregate" <+> pretty aggregateName
    docSource (CatalogCategory categoryName) = "category" <+> dquoted categoryName
    docSource CatalogAll = "all"
    docCheckpointOnMissing CheckpointFromBeginning = "from-beginning"
    docCheckpointOnMissing CheckpointFromCurrentHead = "from-current-head"
    docCheckpointOnMissing CheckpointFail = "fail"
    docReplay ProjectionReplayExplicit = "explicit"
    docReplay (ProjectionLiveOnly reason) = "live-only" <+> dquoted reason

docEmit :: EmitNode -> Doc ann
docEmit e =
  vsep $
    [ "emit" <+> pretty ((.name) e) <+> "{",
      indent 2 ("contract" <+> pretty ((.contract) e)),
      indent 2 ("topic" <+> pretty ((.topic) e)),
      indent 2 ("source" <+> dquoted ((.source) e)),
      indent 2 ("key" <+> pretty ((.key) e)),
      indent 2 ("map" <+> pretty ((.discriminant) e) <+> "{")
    ]
      ++ map (indent 4 . row) ((.map) e)
      ++ [indent 4 "_ => skip" | (.skip) e]
      ++ [ indent 2 "}",
           indent 2 ("messageId" <+> docDerive ((.messageId) e)),
           indent 2 ("idempotencyKey" <+> docDerive ((.idempotencyKey) e)),
           "}"
         ]
  where
    row r = dquoted ((.value) r) <+> "=>" <+> pretty ((.event) r)
    docDerive d = "derive" <> maybe mempty (\p -> " " <> dquoted p) ((.dsPrefix) d) <+> "hole"

docPublisher :: PublisherNode -> Doc ann
docPublisher p =
  vsep
    [ "publisher" <+> pretty ((.name) p) <+> "{",
      indent 2 ("emit" <+> pretty ((.emit) p)),
      indent 2 ("ordering" <+> pretty ((.ordering) p)),
      indent 2 ("maxAttempts" <+> pretty ((.maxAttempts) p)),
      indent 2 (docBackoff ((.backoff) p)),
      indent 2 ("outboxId stable from" <+> pretty ((.outboxField) p)),
      "}"
    ]

docIntake :: IntakeNode -> Doc ann
docIntake i =
  vsep $
    [ "intake" <+> pretty ((.name) i) <+> "{",
      indent 2 ("contract" <+> pretty ((.contract) i)),
      indent 2 ("topic" <+> pretty ((.topic) i)),
      indent 2 ("accept" <+> hsep (map pretty ((.accept) i)))
    ]
      ++ map (indent 2 . docBind) ((.binds) i)
      ++ [ indent 2 ("dedupe key" <+> pretty ((.dedupeKey) i) <+> "policy" <+> pretty ((.dedupePolicy) i))
         ]
      ++ [indent 2 "persist = dedupe-only" | (.persist) i == InkPersistDedupeOnly]
      ++ [ indent 2 (docDecode ((.decode) i)),
           indent 2 "disposition {"
         ]
      ++ map (indent 4 . docDispRow) ((.disposition) i)
      ++ [indent 2 "}", "}"]
  where
    docBind b =
      "bind"
        <+> pretty ((.field) b)
        <+> "from"
        <+> docSource ((.source) b)
        <> (if (.required) b then " required" else mempty)
        <> (if (.crossCheck) b then " cross-check body" else mempty)
    docSource (SrcHeader h) = "header" <+> dquoted h
    docSource SrcBody = "body"
    docSource SrcKafkaKey = "kafka-key"
    docSource SrcKafkaCursor = "kafka-cursor"
    docDecode d =
      vsep
        [ "decode {",
          indent 2 ("envelope" <+> pretty ((.envelope) d)),
          indent 2 ("body" <+> (if (.bodyStrict) d then "strict" else "lenient") <+> "schemaVersion ==" <+> pretty ((.bodySchemaVersion) d)),
          "}"
        ]
    docDispRow r = pretty ((.outcome) r) <+> "=>" <+> docAction ((.action) r)
    docAction IAckOk = "ackOk"
    docAction (IRetry w) = "retry" <+> pretty w
    docAction (IDeadLetter Nothing) = "deadLetter"
    docAction (IDeadLetter (Just reason)) = "deadLetter" <+> dquoted reason

--------------------------------------------------------------------------------
-- Integration contract (EP-4)
--------------------------------------------------------------------------------

docContract :: ContractNode -> Doc ann
docContract c =
  vsep $
    [ "contract" <+> pretty ((.name) c) <+> "{",
      indent 2 ("schemaVersion" <+> pretty ((.schemaVersion) c)),
      indent 2 ("discriminator" <+> pretty ((.discriminator) c))
    ]
      ++ map (indent 2 . docTopic) ((.topics) c)
      ++ map (indent 2 . docContractEvent) ((.events) c)
      ++ ["}"]
  where
    docTopic (alias, t) = "topic" <+> pretty alias <+> dquoted t
    docContractEvent e =
      vsep $
        ["event" <+> pretty ((.name) e) <+> "on" <+> pretty ((.topic) e) <+> "{"]
          ++ map (indent 2 . docContractField) ((.fields) e)
          ++ ["}"]
    docContractField f =
      hsep
        ( [pretty ((.name) f)]
            ++ maybe [] (\selector -> ["haskell", pretty selector]) ((.selector) f)
            ++ maybe [] (\wireKey -> ["as", dquoted wireKey]) ((.wireKey) f)
        )
        <> ":"
        <+> docContractType ((.valueType) f)
    docContractType (CTypeId p) = "typeid" <+> dquoted p
    docContractType CText = "text"
    docContractType CInt = "int"

--------------------------------------------------------------------------------
-- Process + timer (EP-3)
--------------------------------------------------------------------------------

docProcess :: ProcessNode -> Doc ann
docProcess p =
  vsep
    [ "process" <+> pretty ((.id) p),
      indent 2 ("name" <+> dquoted ((.name) p)),
      indent 2 (docInput ((.input) p)),
      indent 2 (docCorrelate ((.correlate) p)),
      indent 2 (docSaga ((.saga) p)),
      indent 2 ("target" <+> pretty ((.target) p)),
      indent 2 ("projections" <+> bracketed (map pretty ((.projections) p))),
      mempty,
      indent 2 (docHandle ((.handle) p)),
      mempty,
      indent 2 "dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)",
      indent 2 ("rejected =>" <+> docPolicyChoice ((.rejected) p)),
      indent 2 ("poison =>" <+> docPolicyChoice ((.poison) p)),
      mempty,
      indent 2 (docTimer ((.timer) p))
    ]

docRouter :: RouterNode -> Doc ann
docRouter r =
  vsep
    [ "router" <+> pretty ((.id) r),
      indent 2 ("name" <+> dquoted ((.name) r)),
      indent 2 (docInput ((.input) r)),
      indent 2 (docRouterKey (isDeclarativeResolve ((.resolve) r)) ((.key) r)),
      indent 2 (docResolve ((.resolve) r)),
      indent 2 ("target" <+> pretty ((.target) r)),
      indent 2 ("projections" <+> bracketed (map pretty ((.projections) r))),
      indent 2 (docRouterDispatch ((.dispatch) r)),
      indent 2 "dispatch-id strategy=uuidv5 from=(name, key, sourceEventId, targetStreamName, occurrence)",
      indent 2 ("rejected =>" <+> docPolicyChoice ((.rejected) r)),
      indent 2 ("poison =>" <+> docPolicyChoice ((.poison) r))
    ]

docRouterKey :: Bool -> CorrelateDecl -> Doc ann
docRouterKey declarative key
  | declarative = "key" <+> ("input." <> pretty ((.field) key))
  | otherwise = "key" <+> ("input." <> pretty ((.field) key)) <+> "via" <+> pretty ((.via) key)

isDeclarativeResolve :: ResolveDecl -> Bool
isDeclarativeResolve resolve = case (.source) resolve of
  ResolveDeclarative {} -> True
  _ -> False

docResolve :: ResolveDecl -> Doc ann
docResolve resolve = case (.source) resolve of
  ResolveReadModel name -> custom ("read-model" <+> pretty name)
  ResolveHole -> custom "hole"
  ResolveDeclarative selection ->
    vsep
      ( [ "resolve declarative {",
          indent 2 ("identity =" <+> dquoted ((.identity) selection)),
          indent 2 ("version =" <+> pretty ((.version) selection)),
          indent 2 ("query = read-model" <+> pretty ((.query) selection) <+> "with" <+> pretty ((.queryInput) selection)),
          indent 2 ("where =" <+> docExpr 0 ((.predicate) selection)),
          indent 2 ("recipient =" <+> docExpr 0 ((.recipient) selection)),
          indent 2 ("order =" <+> pretty ((.order) selection)),
          indent 2 ("dedupe =" <+> pretty ((.dedupe) selection))
        ]
          ++ maybe [] (\(recipientLimit, _) -> [indent 2 ("max-recipients =" <+> pretty recipientLimit)]) ((.limit) selection)
          ++ [ indent 2 ("empty =>" <+> docSelectionDisposition ((.emptyPolicy) selection)),
               indent 2 ("failure =>" <+> docSelectionDisposition ((.failurePolicy) selection)),
               indent 2 ("redelivery =" <+> pretty ((.redelivery) selection)),
               indent 2 ("partial =" <+> pretty ((.partial) selection)),
               "}"
             ]
      )
  where
    custom source = "resolve stable via" <+> source <+> "row" <+> braced (map pretty ((.row) resolve))

docSelectionDisposition :: SelectionDispositionSyntax -> Doc ann
docSelectionDisposition SelectionAck = "ack"
docSelectionDisposition SelectionRetry = "retry"
docSelectionDisposition SelectionDeadLetter = "deadLetter"
docSelectionDisposition SelectionHalt = "halt"

docRouterDispatch :: RouterDispatchNode -> Doc ann
docRouterDispatch dispatch =
  vsep
    [ "dispatch-each" <+> pretty ((.command) dispatch) <+> braced (map docFieldBinding ((.fields) dispatch)),
      indent 2 (docDispDisposition ((.disposition) dispatch))
    ]

docPolicyChoice :: PolicyChoice -> Doc ann
docPolicyChoice PolHalt = "halt"
docPolicyChoice PolDeadLetter = "deadLetter"
docPolicyChoice PolSkip = "skip"

docInput :: InputDecl -> Doc ann
docInput input = case (.valueType) input of
  Just inputType -> "input" <+> pretty ((.name) input) <+> ":" <+> docTypeExpr inputType
  Nothing -> "input" <+> pretty ((.name) input) <+> braced (map docField ((.fields) input))

docCorrelate :: CorrelateDecl -> Doc ann
docCorrelate c = "correlate" <+> ("input." <> pretty ((.field) c)) <+> "via" <+> pretty ((.via) c)

docSaga :: SagaRef -> Doc ann
docSaga s = "saga" <+> pretty ((.agg) s) <+> "category" <+> dquoted ((.category) s)

docHandle :: HandleNode -> Doc ann
docHandle h =
  vsep $
    ["on" <+> pretty ((.on) h)]
      ++ [indent 2 (docAdvance ((.advance) h))]
      ++ map (indent 2 . docDispatch) ((.dispatch) h)
      ++ [indent 2 ("schedule" <+> pretty ((.schedule) h))]

docAdvance :: AdvanceNode -> Doc ann
docAdvance a = "advance" <+> pretty ((.advCommand) a) <+> braced (map docFieldBinding ((.advFields) a))

docDispatch :: DispatchNode -> Doc ann
docDispatch d =
  vsep
    [ "dispatch" <+> (pretty ((.target) d) <> "@" <> pretty ((.key) d)) <+> pretty ((.command) d) <+> braced (map docFieldBinding ((.fields) d)),
      indent 2 (docDispDisposition ((.disposition) d))
    ]

docDispDisposition :: DispatchDisposition -> Doc ann
docDispDisposition x =
  "on-appended" <+> docDisp ((.onAppended) x) <+> ";" <+> "on-duplicate" <+> docDisp ((.onDuplicate) x) <+> ";" <+> "on-failed" <+> docDisp ((.onFailed) x)

docDisp :: Disp -> Doc ann
docDisp DAckOk = "AckOk"
docDisp DRetry = "Retry"
docDisp (DDeadLetter r) = "DeadLetter" <+> dquoted r

docTimer :: TimerNode -> Doc ann
docTimer t =
  vsep
    [ "timer" <+> pretty ((.name) t),
      indent 2 ("id" <+> docIdExpr ((.id) t)),
      indent 2 ("fireAt" <+> docFireAt ((.fireAt) t)),
      indent 2 ("payload" <+> braced (map docFieldBinding ((.payload) t))),
      indent 2 (docFire ((.fire) t)),
      indent 2 ("decode unknown-status =>" <+> pretty ((.decodeUnknown) t)),
      indent 2 ("max-attempts" <+> pretty ((.maxAttempts) t) <+> "dead-letter" <+> dquoted ((.deadLetter) t))
    ]

docIdExpr :: IdExpr -> Doc ann
docIdExpr e = "uuidv5" <+> dquoted ((.prefix) e) <+> "<>" <+> pretty ((.field) e)

docFireAt :: FireAtExpr -> Doc ann
docFireAt f = ("input." <> pretty ((.field) f)) <+> "+" <+> pretty ((.window) f)

docFire :: FireNode -> Doc ann
docFire f =
  vsep
    [ "fire dispatch" <+> (pretty ((.target) f) <> "@" <> pretty ((.key) f)) <+> pretty ((.command) f) <+> braced (map docFieldBinding ((.fields) f)),
      indent 2 ("fired-event-id" <+> docIdExpr ((.firedEventId) f)),
      indent 2 (docFireDisposition ((.disposition) f))
    ]

docFireDisposition :: FireDisposition -> Doc ann
docFireDisposition x =
  "on-ok"
    <+> docFireOutcome ((.onOk) x)
    <+> ";"
    <+> "on-reject"
    <+> docFireOutcome ((.onReject) x)
    <+> ";"
    <+> "on-ambiguous"
    <+> docFireOutcome ((.onAmbiguous) x)
    <+> ";"
    <+> "on-error"
    <+> docFireOutcome ((.onError) x)
    <+> ";"
    <+> "not-mine"
    <+> docFireOutcome ((.notMine) x)

docFireOutcome :: FireOutcome -> Doc ann
docFireOutcome OFired = "Fired"
docFireOutcome ORetry = "Retry"

docFieldBinding :: FieldBinding -> Doc ann
docFieldBinding b = case (.value) b of
  Nothing -> pretty ((.name) b)
  Just v -> pretty ((.name) b) <> "=" <> docValue v
  where
    docValue v = case T.stripPrefix "\"" v >>= T.stripSuffix "\"" of
      Just rawInner -> dquoted rawInner
      Nothing -> pretty v

dquoted :: Text -> Doc ann
dquoted t = "\"" <> pretty (T.concatMap escapeChar t) <> "\""
  where
    escapeChar '"' = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\t' = "\\t"
    escapeChar '\r' = "\\r"
    escapeChar c = T.singleton c

bracketed :: [Doc ann] -> Doc ann
bracketed [] = "[ ]"
bracketed ds = "[" <+> hsep ds <+> "]"

docAggregate :: Aggregate -> Doc ann
docAggregate a =
  vsep $
    [ "aggregate" <+> pretty ((.name) a),
      maybe mempty (indent 2 . docDomainOutcomeTypes) ((.domainOutcomeTypes) a),
      indent 2 "regs",
      indent 4 (vsep (map docReg ((.regs) a))),
      indent 2 ("states" <+> hsep (map docState ((.states) a))),
      mempty
    ]
      ++ map (indent 2 . docCommand) ((.commands) a)
      ++ blank ((.commands) a)
      ++ map (indent 2 . docEvent) ((.events) a)
      ++ blank ((.events) a)
      ++ map (indent 2 . docTransition) ((.transitions) a)
      ++ blank ((.transitions) a)
      ++ maybe [] (\w -> [indent 2 (docWire w)]) ((.wire) a)
      ++ maybe [] (\p -> [indent 2 (docProjection p)]) ((.projection) a)
      ++ maybe [] (\snapshot -> [indent 2 (docSnapshot snapshot)]) ((.snapshot) a)
  where
    blank xs = if null xs then [] else [mempty]

docDomainOutcomeTypes :: DomainOutcomeTypes -> Doc ann
docDomainOutcomeTypes declaration =
  "domain-outcomes"
    <+> ("rejection=" <> pretty ((.rejectionType) declaration))
    <+> ("no-op=" <> pretty ((.noOpType) declaration))

docSnapshot :: SnapshotSpec -> Doc ann
docSnapshot snapshot =
  vsep
    [ "snapshot" <+> policyDoc ((.policy) snapshot),
      indent 2 ("state-codec version=" <> pretty ((.codecVersion) snapshot) <+> "shape-hash=" <> dquoted ((.shapeHash) snapshot))
    ]
  where
    policyDoc (SnapEvery interval) = "every" <+> pretty interval
    policyDoc SnapOnTerminal = "on-terminal"

docReg :: RegDecl -> Doc ann
docReg r = pretty ((.name) r) <+> docTypeExpr ((.valueType) r) <+> "=" <+> docRegInitial ((.initial) r)

docRegInitial :: RegInitial -> Doc ann
docRegInitial (RegInitBare value) = pretty value
docRegInitial (RegInitText value) = dquoted value

docBackoff :: BackoffSpec -> Doc ann
docBackoff backoff =
  "backoff"
    <+> pretty ((.kind) backoff)
    <+> pretty ((.window) backoff)
    <+> maybe mempty (\window -> "max=" <> pretty window) ((.max) backoff)
    <+> maybe mempty (\multiplier -> "multiplier=" <> pretty multiplier) ((.multiplier) backoff)

docState :: StateDecl -> Doc ann
docState s = pretty ((.name) s) <> (if (.terminal) s then "!" else mempty)

docCommand :: Command -> Doc ann
docCommand c = "command" <+> pretty ((.name) c) <+> braced (map docAggregateField ((.fields) c))

docAggregateField :: AggregateField -> Doc ann
docAggregateField f =
  hsep
    ( [pretty ((.name) f)]
        ++ maybe [] (\selector -> ["haskell", pretty selector]) ((.selector) f)
        ++ maybe [] (\wireKey -> ["as", dquoted wireKey]) ((.wireKey) f)
    )
    <> maybe mempty (\ty -> ":" <> docTypeExpr ty) ((.valueType) f)

docField :: Field -> Doc ann
docField f = case (.valueType) f of
  Nothing -> pretty ((.name) f)
  Just ty -> pretty ((.name) f) <> ":" <> pretty ty

docEvent :: Event -> Doc ann
docEvent e =
  case (.upcastFrom) e of
    Nothing -> line1
    Just (m, _) -> vsep [line1, indent 2 ("upcast from v" <> pretty m <+> "=" <+> "HOLE")]
  where
    kw = case ((.retiring) e, (.deprecated) e) of
      (False, False) -> "event"
      (True, False) -> "retiring event"
      (False, True) -> "deprecated event"
      (True, True) -> "retiring deprecated event"
    nameVer =
      pretty ((.name) e)
        <> (if (.version) e > 1 then " v" <> pretty ((.version) e) else mempty)
    bodyDoc = case (.body) e of
      EventFromCommand cmd -> "=" <+> ("fields(" <> pretty cmd <> ")")
      EventFields fs -> braced (map docAggregateField fs)
    line1 = kw <+> nameVer <+> bodyDoc

-- | Render one transition in concrete @.keiro@ syntax. Exported for @diff@'s
-- guard-tightening advisory, which prints a paste-ready replay-only twin
-- (plan 143).
renderTransition :: Transition -> Text
renderTransition =
  renderStrict
    . layoutPretty LayoutOptions {layoutPageWidth = Unbounded}
    . docTransition

-- | Render one expression in canonical concrete syntax.
renderExpr :: Expr -> Text
renderExpr =
  renderStrict
    . layoutPretty LayoutOptions {layoutPageWidth = Unbounded}
    . docExpr 0

docTransition :: Transition -> Doc ann
docTransition t =
  vsep $
    [modePrefix <> pretty ((.source) t) <+> "--" <+> pretty ((.command) t) <+> "-->"]
      ++ map (indent 2) clauses
  where
    modePrefix = case (.mode) t of
      TmLive -> mempty
      TmReplayOnly -> "replay-only "
    clauses =
      ["implementation hole" | (.implementation) t == HoleImplementation]
        ++ maybe [] (\g -> ["guard" <+> docExpr 0 g]) ((.guard) t)
        ++ map (\(r, e) -> "write" <+> pretty r <+> ":=" <+> docExpr 0 e) ((.writes) t)
        ++ maybe [] (pure . docTransitionOutcome) ((.outcome) t)
        ++ map (\ev -> "emit" <+> pretty ev) ((.emits) t)
        ++ ["goto" <+> pretty ((.goto) t)]

docTransitionOutcome :: TransitionOutcome -> Doc ann
docTransitionOutcome (OutcomeAccepted _) = "outcome accepted"
docTransitionOutcome (OutcomeRejected expression _) = "outcome rejected" <+> docExpr 0 expression
docTransitionOutcome (OutcomeNoOp expression _) = "outcome no-op" <+> docExpr 0 expression

docWire :: WireSpec -> Doc ann
docWire w =
  "wire"
    <+> ("kind=" <> pretty ((.kind) w))
    <+> ("fields=" <> pretty ((.fields) w))
    <+> ("schemaVersion=" <> pretty ((.schemaVersion) w))

docProjection :: ProjectionSpec -> Doc ann
docProjection p =
  vsep $
    [ hsep $
        ["projection", pretty ((.table) p)]
          ++ maybe [] (pure . ("consistency=" <>) . docConsistency) ((.consistency) p)
          ++ ["key=" <> pretty ((.key) p)]
    ]
      ++ maybe [] (\m -> [indent 2 (statusMapHead m <+> braced (map pair ((.pairs) m)))]) ((.statusMap) p)
  where
    statusMapHead m = if (.partial) m then "status-map partial" else "status-map"
    pair (l, r) = pretty l <> "=>" <> pretty r

docConsistency :: Consistency -> Doc ann
docConsistency Strong = "Strong"
docConsistency Eventual = "Eventual"

-- | @showsPrec@-style expression renderer. The 'Int' is the minimum precedence
-- allowed without parentheses in the current context. Precedence levels:
-- @||@ = 1, @&&@ = 2, comparisons = 3, addition/subtraction = 4,
-- multiplication = 5, atoms = 6.
docExpr :: Int -> Expr -> Doc ann
docExpr ctx e = parensIf (precOf e < ctx) (body e)
  where
    body (EOr l r) = docExpr 1 l <+> "||" <+> docExpr 2 r
    body (EAnd l r) = docExpr 2 l <+> "&&" <+> docExpr 3 r
    body (ECmp op l r) = docExpr 4 l <+> docCmp op <+> docExpr 4 r
    body (EAdd _ l r) = docExpr 4 l <+> "+" <+> docExpr 5 r
    body (ESubtract _ l r) = docExpr 4 l <+> "-" <+> docExpr 5 r
    body (EMultiply _ l r) = docExpr 5 l <+> "*" <+> docExpr 6 r
    body (EPath _ root path) = docPath root path
    body (ELiteral _ literal) = docLiteral literal
    body (EAtom a) = docAtom a

precOf :: Expr -> Int
precOf EOr {} = 1
precOf EAnd {} = 2
precOf ECmp {} = 3
precOf EAdd {} = 4
precOf ESubtract {} = 4
precOf EMultiply {} = 5
precOf EPath {} = 6
precOf ELiteral {} = 6
precOf EAtom {} = 6

docRoot :: ExprRoot -> Doc ann
docRoot UnqualifiedRoot = mempty
docRoot RegisterRoot = "reg"
docRoot CommandRoot = "cmd"

docPath :: ExprRoot -> [Name] -> Doc ann
docPath UnqualifiedRoot [] = mempty
docPath UnqualifiedRoot (first : rest) = pretty first <> hcat (map (("." <>) . pretty) rest)
docPath root path = docRoot root <> hcat (map (("." <>) . pretty) path)

docLiteral :: ScalarLiteral -> Doc ann
docLiteral (LiteralText value) = dquoted value
docLiteral (LiteralIntegral value) = pretty value
docLiteral (LiteralBool True) = "true"
docLiteral (LiteralBool False) = "false"
docLiteral (LiteralQualified typeName constructor) = pretty typeName <> "." <> pretty constructor
docLiteral (LiteralId typeName value) = pretty typeName <> "(" <> dquoted value <> ")"

docCmp :: CmpOp -> Doc ann
docCmp OpEq = "=="
docCmp OpNeq = "!="
docCmp OpLt = "<"
docCmp OpLe = "<="
docCmp OpGt = ">"
docCmp OpGe = ">="

docAtom :: Atom -> Doc ann
docAtom (AName n) = pretty n
docAtom (ABool True) = "true"
docAtom (ABool False) = "false"

parensIf :: Bool -> Doc ann -> Doc ann
parensIf True d = "(" <> d <> ")"
parensIf False d = d

-- | @{ a b c }@ with single-space separation, or @{ }@ when empty.
braced :: [Doc ann] -> Doc ann
braced [] = "{ }"
braced ds = "{" <+> hsep ds <+> "}"
