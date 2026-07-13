{- | Pretty-printer for the keiro DSL: renders a 'Spec' back to @.keiro@ text.
The layout need not be byte-identical to the original source (the parser
treats whitespace as insignificant), but it must round-trip:
@parseSpec (renderSpec s) == Right s@ modulo source locations. The only
subtle part is expression printing, which uses a @showsPrec@-style precedence
scheme so left-associative @&&@/@||@ and non-associative comparisons re-parse
to the identical AST.
-}
module Keiro.Dsl.PrettyPrint (
    renderSpec,
)
where

import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Prettyprinter
import Prettyprinter.Render.Text (renderStrict)

-- | Render a whole spec to text.
renderSpec :: Spec -> Text
renderSpec = renderStrict . layoutPretty opts . docSpec
  where
    opts = LayoutOptions{layoutPageWidth = Unbounded}

docSpec :: Spec -> Doc ann
docSpec s =
    vsep $
        ["context" <+> pretty (specContext s)]
            ++ maybe [] (\r -> ["module" <+> pretty r]) (specModuleRoot s)
            ++ maybe [] (\l -> ["layout" <+> docLayout l]) (specLayout s)
            ++ [mempty]
            ++ map docId (specIds s)
            ++ blankAfter (specIds s)
            ++ map docEnum (specEnums s)
            ++ blankAfter (specEnums s)
            ++ map docRule (specRules s)
            ++ blankAfter (specRules s)
            ++ map docNode (specNodes s)
  where
    blankAfter xs = if null xs then [] else [mempty]

docLayout :: Placement -> Doc ann
docLayout GeneratedPrefix = "prefixed"
docLayout CollocatedLeaf = "collocated"

docId :: IdDecl -> Doc ann
docId d = "id" <+> pretty (idName d) <+> ("prefix=" <> pretty (idPrefix d))

docEnum :: EnumDecl -> Doc ann
docEnum d =
    "enum" <+> pretty (enumName d) <+> braced (map ctor (enumCtors d))
  where
    ctor (c, w) = pretty c <> "=" <> pretty w

docRule :: RuleDecl -> Doc ann
docRule d =
    vsep
        [ "rule" <+> pretty (ruleName d) <+> ":" <+> pretty (ruleDomain d) <+> "->" <+> pretty (ruleCodomain d)
        , indent 2 ("ex" <+> hsep (punctuate " ;" (map cas (ruleCases d))))
        ]
  where
    cas (c, e) = pretty c <+> "=>" <+> docExpr 0 e

docNode :: Node -> Doc ann
docNode (NAggregate a) = docAggregate a
docNode (NProcess p) = docProcess p
docNode (NContract c) = docContract c
docNode (NIntake i) = docIntake i
docNode (NEmit e) = docEmit e
docNode (NPublisher p) = docPublisher p
docNode (NWorkqueue w) = docWorkqueue w
docNode (NPgmqDispatch d) = docPgmqDispatch d
docNode (NReadModel r) = docReadModel r
docNode (NWorkflow w) = docWorkflow w
docNode (NOperation o) = docOperation o

docWorkflow :: WorkflowNode -> Doc ann
docWorkflow w =
    vsep $
        [ "workflow" <+> pretty (wfId w)
        , indent 2 ("name" <+> dquoted (wfStable w))
        , indent 2 ("in" <+> pretty (wfInput w) <> inFieldsDoc)
        , indent 2 ("out" <+> pretty (wfOutput w))
        , indent 2 ("id from input" <> maybe mempty (\f -> "." <> pretty f) (wfIdField w) <+> "via" <+> pretty (wfIdVia w))
        , indent 2 "body"
        ]
            ++ map (indent 4 . bodyItem) (wfBody w)
  where
    inFieldsDoc = case wfInputFields w of
        [] -> mempty
        fs -> " " <> braced (map docField fs)
    bodyItem (WfStep l r _) = "step" <+> pretty l <+> "->" <+> pretty r
    bodyItem (WfAwait l r _) = "await" <+> pretty l <+> "->" <+> pretty r
    bodyItem (WfSleep l a _) = "sleep" <+> pretty l <+> "after" <+> pretty a
    bodyItem (WfChild l v r _) = "child" <+> pretty l <+> "id input via" <+> pretty v <+> "->" <+> pretty r

docOperation :: OperationNode -> Doc ann
docOperation o =
    vsep $ ["operation" <+> pretty (opName o)] ++ map (indent 2) (shapeLines (opShape o))
  where
    shapeLines (CommandOp agg sf sv proj) =
        [ "command on" <+> pretty agg
        , indent 2 ("stream from" <+> pretty sf <+> "via" <+> pretty sv)
        ]
            ++ [indent 2 ("project" <+> bracketed (map pretty proj)) | not (null proj)]
    shapeLines (QueryOp rm inp res cons) =
        [ "query" <+> pretty rm
        , indent 2 ("input" <+> pretty inp)
        , indent 2 ("result" <+> pretty res)
        , indent 2 ("consistency" <+> pretty cons)
        ]
    shapeLines (SignalOp lbl wf kf kv val) =
        [ "signal" <+> pretty lbl <+> "of" <+> pretty wf
        , indent 2 ("key from" <+> pretty kf <+> "via" <+> pretty kv)
        , indent 2 ("value" <+> pretty val)
        ]
    shapeLines (RunOp wf inp oc) =
        [ "run" <+> pretty wf
        , indent 2 ("input" <+> pretty inp)
        , indent 2 ("outcome ->" <+> pretty oc)
        ]

docWorkqueue :: WorkqueueNode -> Doc ann
docWorkqueue w =
    vsep $
        [ "workqueue" <+> pretty (wqName w) <+> "{"
        , indent 2 ("queue logical =" <+> dquoted (wqLogical w))
        , indent 2 ("derive physical =" <+> dquoted (wqPhysical w))
        , indent 4 ("dlq =" <+> dquoted (wqDlq w))
        , indent 4 ("table =" <+> dquoted (wqTable w))
        , indent 2 ("payload" <+> pretty (wqPayloadName w) <+> "{")
        ]
            ++ map (indent 4 . field) (wqPayload w)
            ++ [ indent 2 "}"
               , indent 2 ("retry maxRetries =" <+> pretty (wqMaxRetries w) <+> "delay =" <+> pretty (wqDelay w) <+> "dlq =" <+> (if wqDlqOn w then "on" else "off"))
               , indent 2 "disposition {"
               ]
            ++ map (indent 4 . dispRow) (wqDisposition w)
            ++ [indent 2 "}", "}"]
  where
    field f = pretty (wqfName f) <+> "->" <+> dquoted (wqfWire f) <+> pretty (wqfType f) <> (if wqfRequired f then " required" else mempty)
    dispRow r = pretty (wqdOutcome r) <+> "->" <+> act (wqdAction r)
    act IAckOk = "ackOk"
    act (IRetry win) = "retry" <+> pretty win
    act (IDeadLetter Nothing) = "deadLetter"
    act (IDeadLetter (Just reason)) = "deadLetter" <+> dquoted reason

docPgmqDispatch :: PgmqDispatchNode -> Doc ann
docPgmqDispatch d =
    vsep
        [ "dispatch" <+> pretty (pdName d) <+> "{"
        , indent 2 ("source readModel =" <+> pretty (pdSourceReadModel d) <+> "key =" <+> pretty (pdSourceKey d))
        , indent 2 ("fanout body =" <+> pretty (pdFanoutBody d))
        , indent 2 ("dedup key =" <+> pretty (pdDedupKey d))
        , indent 4 ("seenIn readModel =" <+> pretty (pdDedupReadModel d) <+> "field =" <+> pretty (pdDedupReadModelField d))
        , indent 4 ("seenIn queue =" <+> pretty (pdDedupQueue d) <+> "field =" <+> pretty (pdDedupQueueField d))
        , indent 2 ("enqueue to =" <+> pretty (pdEnqueueTo d))
        , "}"
        ]

docReadModel :: ReadModelNode -> Doc ann
docReadModel readModel =
    vsep $
        [ "readmodel" <+> pretty (rmName readModel) <+> "{"
        , indent 2 ("table =" <+> dquoted (rmTable readModel))
        , indent 2 ("schema =" <+> dquoted (rmSchema readModel))
        , indent 2 "columns {"
        ]
            ++ map (indent 4 . docColumn) (rmColumns readModel)
            ++ [ indent 2 "}"
               , indent 2 ("version =" <+> pretty (rmVersion readModel))
               , indent 2 ("shape =" <+> dquoted (rmShape readModel))
               , indent 2 ("consistency =" <+> docConsistency (rmConsistency readModel))
               ]
            ++ maybe [] (pure . indent 2 . ("scope =" <+>) . docScope) (rmScope readModel)
            ++ [indent 2 ("feed =" <+> docFeed (rmFeed readModel))]
            ++ maybe [] (pure . indent 2 . ("subscription =" <+>) . dquoted) (rmSubscription readModel)
            ++ ["}"]
  where
    docColumn columnDecl =
        pretty (rmcName columnDecl)
            <+> pretty (rmcType columnDecl)
            <> if rmcRequired columnDecl then " required" else mempty
    docScope RmEntireLog = "entire-log"
    docScope (RmCategory categoryName) = "category" <+> dquoted categoryName
    docFeed RmInline = "inline"
    docFeed RmSubscription = "subscription"

docEmit :: EmitNode -> Doc ann
docEmit e =
    vsep $
        [ "emit" <+> pretty (emName e) <+> "{"
        , indent 2 ("contract" <+> pretty (emContract e))
        , indent 2 ("topic" <+> pretty (emTopic e))
        , indent 2 ("source" <+> dquoted (emSource e))
        , indent 2 ("key" <+> pretty (emKey e))
        , indent 2 ("map" <+> pretty (emDiscriminant e) <+> "{")
        ]
            ++ map (indent 4 . row) (emMap e)
            ++ [indent 4 "_ => skip" | emSkip e]
            ++ [ indent 2 "}"
               , indent 2 ("messageId" <+> docDerive (emMessageId e))
               , indent 2 ("idempotencyKey" <+> docDerive (emIdempotencyKey e))
               , "}"
               ]
  where
    row r = dquoted (emrValue r) <+> "=>" <+> pretty (emrEvent r)
    docDerive d = "derive" <> maybe mempty (\p -> " " <> dquoted p) (dsPrefix d) <+> "hole"

docPublisher :: PublisherNode -> Doc ann
docPublisher p =
    vsep
        [ "publisher" <+> pretty (pubName p) <+> "{"
        , indent 2 ("emit" <+> pretty (pubEmit p))
        , indent 2 ("ordering" <+> pretty (pubOrdering p))
        , indent 2 ("maxAttempts" <+> pretty (pubMaxAttempts p))
        , indent 2 (docBackoff (pubBackoff p))
        , indent 2 ("outboxId stable from" <+> pretty (pubOutboxField p))
        , "}"
        ]

docIntake :: IntakeNode -> Doc ann
docIntake i =
    vsep $
        [ "intake" <+> pretty (inkName i) <+> "{"
        , indent 2 ("contract" <+> pretty (inkContract i))
        , indent 2 ("topic" <+> pretty (inkTopic i))
        , indent 2 ("accept" <+> hsep (map pretty (inkAccept i)))
        ]
            ++ map (indent 2 . docBind) (inkBinds i)
            ++ [ indent 2 ("dedupe key" <+> pretty (inkDedupeKey i) <+> "policy" <+> pretty (inkDedupePolicy i))
               , indent 2 (docDecode (inkDecode i))
               , indent 2 "disposition {"
               ]
            ++ map (indent 4 . docDispRow) (inkDisposition i)
            ++ [indent 2 "}", "}"]
  where
    docBind b =
        "bind"
            <+> pretty (brField b)
            <+> "from"
            <+> docSource (brSource b)
            <> (if brRequired b then " required" else mempty)
            <> (if brCrossCheck b then " cross-check body" else mempty)
    docSource (SrcHeader h) = "header" <+> dquoted h
    docSource SrcBody = "body"
    docSource SrcKafkaKey = "kafka-key"
    docSource SrcKafkaCursor = "kafka-cursor"
    docDecode d =
        vsep
            [ "decode {"
            , indent 2 ("envelope" <+> pretty (decEnvelope d))
            , indent 2 ("body" <+> (if decBodyStrict d then "strict" else "lenient") <+> "schemaVersion ==" <+> pretty (decBodySchemaVersion d))
            , "}"
            ]
    docDispRow r = pretty (drOutcome r) <+> "=>" <+> docAction (drAction r)
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
        [ "contract" <+> pretty (ctrName c) <+> "{"
        , indent 2 ("schemaVersion" <+> pretty (ctrSchemaVersion c))
        , indent 2 ("discriminator" <+> pretty (ctrDiscriminator c))
        ]
            ++ map (indent 2 . docTopic) (ctrTopics c)
            ++ map (indent 2 . docContractEvent) (ctrEvents c)
            ++ ["}"]
  where
    docTopic (alias, t) = "topic" <+> pretty alias <+> dquoted t
    docContractEvent e =
        vsep $
            ["event" <+> pretty (ceName e) <+> "on" <+> pretty (ceTopic e) <+> "{"]
                ++ map (indent 2 . docContractField) (ceFields e)
                ++ ["}"]
    docContractField f = pretty (cfName f) <> ":" <+> docContractType (cfType f)
    docContractType (CTypeId p) = "typeid" <+> dquoted p
    docContractType CText = "text"
    docContractType CInt = "int"

--------------------------------------------------------------------------------
-- Process + timer (EP-3)
--------------------------------------------------------------------------------

docProcess :: ProcessNode -> Doc ann
docProcess p =
    vsep
        [ "process" <+> pretty (procId p)
        , indent 2 ("name" <+> dquoted (procName p))
        , indent 2 (docInput (procInput p))
        , indent 2 (docCorrelate (procCorrelate p))
        , indent 2 (docSaga (procSaga p))
        , indent 2 ("target" <+> pretty (procTarget p))
        , indent 2 ("projections" <+> bracketed (map pretty (procProjections p)))
        , mempty
        , indent 2 (docHandle (procHandle p))
        , mempty
        , indent 2 "dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)"
        , mempty
        , indent 2 (docTimer (procTimer p))
        ]

docInput :: InputDecl -> Doc ann
docInput i = "input" <+> pretty (inName i) <+> braced (map docField (inFields i))

docCorrelate :: CorrelateDecl -> Doc ann
docCorrelate c = "correlate" <+> ("input." <> pretty (corrField c)) <+> "via" <+> pretty (corrVia c)

docSaga :: SagaRef -> Doc ann
docSaga s = "saga" <+> pretty (sagaAgg s) <+> ("stream=" <> dquoted (sagaStreamPrefix s) <+> "<>" <+> "correlationId")

docHandle :: HandleNode -> Doc ann
docHandle h =
    vsep $
        ["on" <+> pretty (hOn h)]
            ++ [indent 2 (docAdvance (hAdvance h))]
            ++ map (indent 2 . docDispatch) (hDispatch h)
            ++ [indent 2 ("schedule" <+> pretty (hSchedule h))]

docAdvance :: AdvanceNode -> Doc ann
docAdvance a = "advance" <+> pretty (advCommand a) <+> braced (map docFieldBinding (advFields a))

docDispatch :: DispatchNode -> Doc ann
docDispatch d =
    vsep
        [ "dispatch" <+> (pretty (dispTarget d) <> "@" <> pretty (dispKey d)) <+> pretty (dispCommand d) <+> braced (map docFieldBinding (dispFields d))
        , indent 2 (docDispDisposition (dispDisposition d))
        ]

docDispDisposition :: DispatchDisposition -> Doc ann
docDispDisposition x =
    "on-appended" <+> docDisp (onAppended x) <+> ";" <+> "on-duplicate" <+> docDisp (onDuplicate x) <+> ";" <+> "on-failed" <+> docDisp (onFailed x)

docDisp :: Disp -> Doc ann
docDisp DAckOk = "AckOk"
docDisp DRetry = "Retry"
docDisp (DDeadLetter r) = "DeadLetter" <+> dquoted r

docTimer :: TimerNode -> Doc ann
docTimer t =
    vsep
        [ "timer" <+> pretty (tmName t)
        , indent 2 ("id" <+> docIdExpr (tmId t))
        , indent 2 ("fireAt" <+> docFireAt (tmFireAt t))
        , indent 2 ("payload" <+> braced (map docFieldBinding (tmPayload t)))
        , indent 2 (docFire (tmFire t))
        , indent 2 ("decode unknown-status =>" <+> pretty (tmDecodeUnknown t))
        , indent 2 ("max-attempts" <+> pretty (tmMaxAttempts t) <+> "dead-letter" <+> dquoted (tmDeadLetter t))
        ]

docIdExpr :: IdExpr -> Doc ann
docIdExpr e = "uuidv5" <+> dquoted (idePrefix e) <+> "<>" <+> "correlationId"

docFireAt :: FireAtExpr -> Doc ann
docFireAt f = ("input." <> pretty (faField f)) <+> "+" <+> pretty (faWindow f)

docFire :: FireNode -> Doc ann
docFire f =
    vsep
        [ "fire dispatch" <+> (pretty (fireTarget f) <> "@" <> pretty (fireKey f)) <+> pretty (fireCommand f) <+> braced (map docFieldBinding (fireFields f))
        , indent 2 ("fired-event-id" <+> docIdExpr (fireFiredEventId f))
        , indent 2 (docFireDisposition (fireDisposition f))
        ]

docFireDisposition :: FireDisposition -> Doc ann
docFireDisposition x =
    "on-ok"
        <+> docFireOutcome (onOk x)
        <+> ";"
        <+> "on-reject"
        <+> docFireOutcome (onReject x)
        <+> ";"
        <+> "on-error"
        <+> docFireOutcome (onError x)
        <+> ";"
        <+> "not-mine"
        <+> docFireOutcome (notMine x)

docFireOutcome :: FireOutcome -> Doc ann
docFireOutcome OFired = "Fired"
docFireOutcome ORetry = "Retry"

docFieldBinding :: FieldBinding -> Doc ann
docFieldBinding b = case fbValue b of
    Nothing -> pretty (fbName b)
    Just v -> pretty (fbName b) <> "=" <> docValue v
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
        [ "aggregate" <+> pretty (aggName a)
        , indent 2 "regs"
        , indent 4 (vsep (map docReg (aggRegs a)))
        , indent 2 ("states" <+> hsep (map docState (aggStates a)))
        , mempty
        ]
            ++ map (indent 2 . docCommand) (aggCommands a)
            ++ blank (aggCommands a)
            ++ map (indent 2 . docEvent) (aggEvents a)
            ++ blank (aggEvents a)
            ++ map (indent 2 . docTransition) (aggTransitions a)
            ++ blank (aggTransitions a)
            ++ maybe [] (\w -> [indent 2 (docWire w)]) (aggWire a)
            ++ maybe [] (\p -> [indent 2 (docProjection p)]) (aggProjection a)
  where
    blank xs = if null xs then [] else [mempty]

docReg :: RegDecl -> Doc ann
docReg r = pretty (regName r) <+> pretty (regType r) <+> "=" <+> docRegInitial (regInitial r)

docRegInitial :: RegInitial -> Doc ann
docRegInitial (RegInitBare value) = pretty value
docRegInitial (RegInitText value) = dquoted value

docBackoff :: BackoffSpec -> Doc ann
docBackoff backoff =
    "backoff"
        <+> pretty (boKind backoff)
        <+> pretty (boWindow backoff)
        <+> maybe mempty (\window -> "max=" <> pretty window) (boMax backoff)
        <+> maybe mempty (\multiplier -> "multiplier=" <> pretty multiplier) (boMultiplier backoff)

docState :: StateDecl -> Doc ann
docState s = pretty (stName s) <> (if stTerminal s then "!" else mempty)

docCommand :: Command -> Doc ann
docCommand c = "command" <+> pretty (cmdName c) <+> braced (map docField (cmdFields c))

docField :: Field -> Doc ann
docField f = case fieldType f of
    Nothing -> pretty (fieldName f)
    Just ty -> pretty (fieldName f) <> ":" <> pretty ty

docEvent :: Event -> Doc ann
docEvent e =
    case evUpcastFrom e of
        Nothing -> line1
        Just (m, _) -> vsep [line1, indent 2 ("upcast from v" <> pretty m <+> "=" <+> "HOLE")]
  where
    kw = if evDeprecated e then "deprecated event" else "event"
    nameVer =
        pretty (evName e)
            <> (if evVersion e > 1 then " v" <> pretty (evVersion e) else mempty)
    bodyDoc = case evBody e of
        EventFromCommand cmd -> "=" <+> ("fields(" <> pretty cmd <> ")")
        EventFields fs -> braced (map docField fs)
    line1 = kw <+> nameVer <+> bodyDoc

docTransition :: Transition -> Doc ann
docTransition t =
    vsep $
        [pretty (tSource t) <+> "--" <+> pretty (tCommand t) <+> "-->"]
            ++ map (indent 2) clauses
  where
    clauses =
        maybe [] (\g -> ["guard" <+> docExpr 0 g]) (tGuard t)
            ++ map (\(r, e) -> "write" <+> pretty r <+> ":=" <+> docExpr 0 e) (tWrites t)
            ++ map (\ev -> "emit" <+> pretty ev) (tEmits t)
            ++ ["goto" <+> pretty (tGoto t)]

docWire :: WireSpec -> Doc ann
docWire w =
    "wire"
        <+> ("kind=" <> pretty (wireKind w))
        <+> ("fields=" <> pretty (wireFields w))
        <+> ("schemaVersion=" <> pretty (wireSchemaVersion w))

docProjection :: ProjectionSpec -> Doc ann
docProjection p =
    vsep $
        [ hsep $
            ["projection", pretty (projTable p)]
                ++ maybe [] (pure . ("consistency=" <>) . docConsistency) (projConsistency p)
                ++ ["key=" <> pretty (projKey p)]
        ]
            ++ maybe [] (\m -> [indent 2 (statusMapHead m <+> braced (map pair (mapPairs m)))]) (projStatusMap p)
  where
    statusMapHead m = if mapPartial m then "status-map partial" else "status-map"
    pair (l, r) = pretty l <> "=>" <> pretty r

docConsistency :: Consistency -> Doc ann
docConsistency Strong = "Strong"
docConsistency Eventual = "Eventual"

{- | @showsPrec@-style expression renderer. The 'Int' is the minimum precedence
allowed without parentheses in the current context. Precedence levels:
@||@ = 1, @&&@ = 2, comparisons = 3, atoms = 4.
-}
docExpr :: Int -> Expr -> Doc ann
docExpr ctx e = parensIf (precOf e < ctx) (body e)
  where
    body (EOr l r) = docExpr 1 l <+> "||" <+> docExpr 2 r
    body (EAnd l r) = docExpr 2 l <+> "&&" <+> docExpr 3 r
    body (ECmp op l r) = docExpr 4 l <+> docCmp op <+> docExpr 4 r
    body (EAtom a) = docAtom a

precOf :: Expr -> Int
precOf EOr{} = 1
precOf EAnd{} = 2
precOf ECmp{} = 3
precOf EAtom{} = 4

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
