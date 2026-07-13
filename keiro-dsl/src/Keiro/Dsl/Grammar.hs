{- | The abstract syntax of the keiro DSL (@.keiro@) — the shared engine type that
every later vertical (EP-2…EP-6) extends additively. EP-1 defines the shared
declarations, the 'Expr' sublanguage, the eight hole-kind types, and the
'Aggregate' node. New node families add a 'Node' constructor here in lockstep
with their parser, validator, and scaffold cases.
-}
module Keiro.Dsl.Grammar (
    -- * Names and source locations
    Name,
    Loc (..),
    noLoc,

    -- * Shared declarations
    IdDecl (..),
    EnumDecl (..),
    RuleDecl (..),

    -- * The eight hole-kind types
    Derivation (..),
    DerivStrategy (..),
    Disposition (..),
    DispAction (..),
    Mapping (..),
    EnvelopeBinding (..),
    EnvelopeLayer (..),

    -- * The Expr sublanguage
    Expr (..),
    CmpOp (..),
    Atom (..),

    -- * The aggregate node
    RegDecl (..),
    StateDecl (..),
    Field (..),
    Command (..),
    Event (..),
    EventBody (..),
    Hole (..),
    Transition (..),
    WireSpec (..),
    ProjectionSpec (..),
    Consistency (..),
    Aggregate (..),

    -- * The process + timer nodes (EP-3)
    FieldBinding (..),
    InputDecl (..),
    CorrelateDecl (..),
    SagaRef (..),
    Disp (..),
    DispatchDisposition (..),
    AdvanceNode (..),
    DispatchNode (..),
    HandleNode (..),
    IdExpr (..),
    IdStrategy (..),
    FireAtExpr (..),
    FireOutcome (..),
    FireDisposition (..),
    FireNode (..),
    TimerNode (..),
    ProcessNode (..),

    -- * The integration contract node (EP-4)
    ContractType (..),
    ContractField (..),
    ContractEvent (..),
    ContractNode (..),

    -- * The integration intake (inbox) node (EP-4)
    WireSource (..),
    BindRow (..),
    InboxAction (..),
    DispositionRow (..),
    DecodeSpec (..),
    IntakeNode (..),

    -- * The integration emit/publisher nodes (EP-4)
    DeriveSpec (..),
    EmitMapRow (..),
    EmitNode (..),
    BackoffSpec (..),
    PublisherNode (..),

    -- * The pgmq workqueue/dispatch nodes (EP-5)
    WqField (..),
    WqDispRow (..),
    WorkqueueNode (..),
    PgmqDispatchNode (..),

    -- * The workflow/operation nodes (EP-6)
    WfBodyItem (..),
    WorkflowNode (..),
    OperationShape (..),
    OperationNode (..),

    -- * Top level
    Placement (..),
    Node (..),
    Spec (..),
)
where

import Data.Text (Text)
import GHC.Generics (Generic)

{- | An identifier in the notation: a type name, register name, command/event
name, state name, enum constructor, etc. Always a non-empty 'Text'.
-}
type Name = Text

{- | A source line number, attached to declarations so the validator can emit
line-numbered diagnostics. Its 'Eq' instance deliberately ignores the line
value: two ASTs that differ only in source position are considered equal, so
the @parse . pretty == id@ round-trip property holds without the
pretty-printer having to reproduce exact line numbers.
-}
newtype Loc = Loc {unLoc :: Int}
    deriving stock (Show)

instance Eq Loc where
    _ == _ = True

-- | A placeholder location used by generators and pretty-print round-trips.
noLoc :: Loc
noLoc = Loc 0

{- | @id TransferReservationId prefix=rsv@ — declares an id newtype over 'Text'
and its prefix tag.
-}
data IdDecl = IdDecl
    { idName :: !Name
    , idPrefix :: !Text
    , idLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | @enum PatientAcuity { RedTag=red … }@ — a closed enumeration; each
constructor carries its wire spelling (the right-hand side of @=@).
-}
data EnumDecl = EnumDecl
    { enumName :: !Name
    , enumCtors :: ![(Name, Text)]
    , enumLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | @rule lifeCriticalOverride : PatientAcuity -> Bool@ with an @ex@ line of
@Ctor => bool ; …@ — a total function from an enum to a value, used as a
derived atom inside guards.
-}
data RuleDecl = RuleDecl
    { ruleName :: !Name
    , ruleDomain :: !Name
    , ruleCodomain :: !Name
    , ruleCases :: ![(Name, Expr)]
    , ruleLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- The eight hole-kind types. EP-1 only exercises hole-kinds 1–3 against the
-- aggregate vertical; the rest exist so EP-3…EP-6 reuse the same types.

{- | Hole-kind 1: a deterministic id/string derivation. Opaque strategies must
carry a captured @fixture@ (not a prose rule) so two agents re-derive them
identically.
-}
data Derivation = Derivation
    { derivStrategy :: !DerivStrategy
    , derivFixture :: !(Maybe Text)
    }
    deriving stock (Eq, Show, Generic)

data DerivStrategy = UuidV5 | SuffixSplice
    deriving stock (Eq, Show, Generic)

{- | Hole-kind 2: a failure→action table. Carries the two dangerous inversions a
@duplicate@/@rejected replay@ being treated as success and a
@previously-failed@ being dead-lettered rather than retried (enforced by
EP-4's validator rules).
-}
newtype Disposition = Disposition
    { dispCases :: [(Name, DispAction)]
    }
    deriving stock (Eq, Show, Generic)

data DispAction = AckOk | Retry !Int | DeadLetter !Text
    deriving stock (Eq, Show, Generic)

{- | Hole-kind 3: an explicit value→value table that is not an identity echo
(e.g. an event name → projection status). @mapPartial@ records whether the
spec author explicitly marked the table partial over its domain.
-}
data Mapping = Mapping
    { mapPairs :: ![(Name, Name)]
    , mapPartial :: !Bool
    }
    deriving stock (Eq, Show, Generic)

{- | Hole-kind 4: which layer carries each envelope field, and whether the two
are cross-checked. Defined here for reuse; exercised by EP-4.
-}
data EnvelopeBinding = EnvelopeBinding
    { envField :: !Name
    , envLayer :: !EnvelopeLayer
    , envCrossChecked :: !Bool
    }
    deriving stock (Eq, Show, Generic)

data EnvelopeLayer = KafkaHeader | JsonBody
    deriving stock (Eq, Show, Generic)

{- | The @Expr@ sublanguage used by @guard@ clauses and the right-hand side of
@write@ clauses. An infix expression over 'Atom's; operators in precedence
order are @||@ (lowest), @&&@, then the relational comparisons.
-}
data Expr
    = EOr !Expr !Expr
    | EAnd !Expr !Expr
    | ECmp !CmpOp !Expr !Expr
    | EAtom !Atom
    deriving stock (Eq, Show, Generic)

data CmpOp = OpEq | OpNeq | OpLt | OpLe | OpGt | OpGe
    deriving stock (Eq, Show, Generic)

{- | An atom is either a bare boolean literal (@true@/@false@) or a name. Names
are kept syntactically neutral: at parse time an identifier is
indistinguishable between a register, a command field, an enum constructor,
and a rule, so the validator's scope-check (M2) resolves which one each
'AName' is against the declared sets. This keeps the parser honest and the
round-trip exact.
-}
data Atom
    = AName !Name
    | ABool !Bool
    deriving stock (Eq, Show, Generic)

{- | @name Type = initial@ — a named register with its declared type and the
initial value (an identifier: a literal like @placeholder@, an enum
constructor, or a state name).
-}
data RegDecl = RegDecl
    { regName :: !Name
    , regType :: !Name
    , regInitial :: !Name
    , regLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | One entry in a @states@ list. @stTerminal@ is set when the name carries a
trailing @!@ (no outgoing transitions allowed). The first 'StateDecl' in an
aggregate's list is its initial state.
-}
data StateDecl = StateDecl
    { stName :: !Name
    , stTerminal :: !Bool
    , stLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | A command/event field. A bare name (@fieldType = Nothing@) reuses the
field's declared type elsewhere; @name:Type@ gives an explicit type.
-}
data Field = Field
    { fieldName :: !Name
    , fieldType :: !(Maybe Name)
    }
    deriving stock (Eq, Show, Generic)

-- | @command Name { field … }@ — a command constructor.
data Command = Command
    { cmdName :: !Name
    , cmdFields :: ![Field]
    , cmdLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | @event Name { … }@ or @event Name = fields(Command)@. EP-2 (evolution) adds
the version/upcaster/deprecation fields: an unversioned event is @evVersion = 1@,
@evUpcastFrom = Nothing@, @evDeprecated = False@, reproducing the EP-1 surface.
These fields live on the shared 'Event' so every node family's events inherit
schema-versioning for free.
-}
data Event = Event
    { evName :: !Name
    , evBody :: !EventBody
    , evVersion :: !Int
    -- ^ The schema version of this event shape. Default 1; written @vN@ for N>1.
    , evUpcastFrom :: !(Maybe (Int, Hole))
    {- ^ The source version this shape migrates /from/, paired with the upcaster
    hole. @Just (n-1, …)@ for a @vN@ shape; 'Nothing' for v1.
    -}
    , evDeprecated :: !Bool
    {- ^ Retired from the write path (no transition may @emit@ it) but still
    decodable from the log.
    -}
    , evLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

data EventBody
    = EventFields ![Field]
    | EventFromCommand !Name
    deriving stock (Eq, Show, Generic)

{- | A spec hole: an unfilled placeholder ('Hole', written @HOLE@ in the
notation) or a value the author supplied inline ('Filled').
-}
data Hole = Hole | Filled !Text
    deriving stock (Eq, Show, Generic)

{- | A transition @Src -- Command --> clauses@. Clauses may be written
indentation-stacked or @;@-separated on one line.
-}
data Transition = Transition
    { tSource :: !Name
    , tCommand :: !Name
    , tGuard :: !(Maybe Expr)
    , tWrites :: ![(Name, Expr)]
    , tEmits :: ![Name]
    , tGoto :: !Name
    , tLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | @wire kind=ctorName fields=camelCase schemaVersion=1@ — how events
serialize.
-}
data WireSpec = WireSpec
    { wireKind :: !Text
    , wireFields :: !Text
    , wireSchemaVersion :: !Int
    }
    deriving stock (Eq, Show, Generic)

{- | @projection table consistency=… key=… status-map { … }@ — the read-model
projection and its event→status 'Mapping' (hole-kind 3).
-}
data ProjectionSpec = ProjectionSpec
    { projTable :: !Name
    , projConsistency :: !Consistency
    , projKey :: !Name
    , projStatusMap :: !(Maybe Mapping)
    , projLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

data Consistency = Strong | Eventual
    deriving stock (Eq, Show, Generic)

{- | An @aggregate@ node: a consistency boundary whose state is rebuilt by
replaying events.
-}
data Aggregate = Aggregate
    { aggName :: !Name
    , aggRegs :: ![RegDecl]
    , aggStates :: ![StateDecl]
    , aggCommands :: ![Command]
    , aggEvents :: ![Event]
    , aggTransitions :: ![Transition]
    , aggWire :: !(Maybe WireSpec)
    , aggProjection :: !(Maybe ProjectionSpec)
    , aggLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- EP-3: process manager + durable timer nodes.

{- | A @field@ or @field=value@ binding inside a command\/payload field list.
A bare field reuses the input field of the same name; @name=value@ binds it to
an expression (kept as raw text, e.g. @timerId=timer.id@).
-}
data FieldBinding = FieldBinding
    { fbName :: !Name
    , fbValue :: !(Maybe Text)
    }
    deriving stock (Eq, Show, Generic)

{- | @input SurgeInput { hospitalId … observedAt:Time }@ — the process's incoming
event shape (one field must be a @:Time@ field used by the timer deadline).
-}
data InputDecl = InputDecl
    { inName :: !Name
    , inFields :: ![Field]
    }
    deriving stock (Eq, Show, Generic)

{- | @correlate input.hospitalId via idText@ — the correlation key (hole-kind 1
derivation + hole-kind 4 field-source).
-}
data CorrelateDecl = CorrelateDecl
    { corrField :: !Name
    , corrVia :: !Name
    }
    deriving stock (Eq, Show, Generic)

{- | @saga Surge stream=\"hospital-surge-\" <> correlationId@ — the saga's own
aggregate plus the @streamFor@ suffix-splice prefix.
-}
data SagaRef = SagaRef
    { sagaAgg :: !Name
    , sagaStreamPrefix :: !Text
    }
    deriving stock (Eq, Show, Generic)

-- | A command dispatch outcome action.
data Disp = DAckOk | DRetry | DDeadLetter !Text
    deriving stock (Eq, Show, Generic)

{- | The complete dispatch disposition table (every arm mandatory; the
@on-duplicate AckOk@ benign inversion is explicit). Named to avoid clashing
with the hole-kind 'Disposition'.
-}
data DispatchDisposition = DispatchDisposition
    { onAppended :: !Disp
    , onDuplicate :: !Disp
    , onFailed :: !Disp
    }
    deriving stock (Eq, Show, Generic)

-- | @advance NoteSurgeThreshold { … }@ — the self-command that advances the saga.
data AdvanceNode = AdvanceNode
    { advCommand :: !Name
    , advFields :: ![FieldBinding]
    }
    deriving stock (Eq, Show, Generic)

-- | @dispatch Hospital\@input.hospitalId ActivateSurge { … } on-appended … on-duplicate … on-failed …@.
data DispatchNode = DispatchNode
    { dispTarget :: !Name
    , dispKey :: !Text
    , dispCommand :: !Name
    , dispFields :: ![FieldBinding]
    , dispDisposition :: !DispatchDisposition
    , dispLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | The @on <Input>@ reaction: a self-advance, zero or more dispatches, and a
@schedule@ of the timer.
-}
data HandleNode = HandleNode
    { hOn :: !Name
    , hAdvance :: !AdvanceNode
    , hDispatch :: ![DispatchNode]
    , hSchedule :: !Name
    }
    deriving stock (Eq, Show, Generic)

-- | A deterministic id derivation: @uuidv5 \"prefix:\" <> correlationId@.
data IdExpr = IdExpr
    { ideStrategy :: !IdStrategy
    , idePrefix :: !Text
    }
    deriving stock (Eq, Show, Generic)

data IdStrategy = UuidV5Id
    deriving stock (Eq, Show, Generic)

{- | @fireAt input.observedAt + 5m@ — an injected timestamp field plus a window.
There is no clock-sampling constructor, so the no-wall-clock rule holds by
construction.
-}
data FireAtExpr = FireAtExpr
    { faField :: !Name
    , faWindow :: !Text
    }
    deriving stock (Eq, Show, Generic)

data FireOutcome = OFired | ORetry
    deriving stock (Eq, Show, Generic)

{- | The complete timer-fire disposition table; @on-reject OFired@ is the benign
inversion (a CommandRejected means \"already applied\" = success).
-}
data FireDisposition = FireDisposition
    { onOk :: !FireOutcome
    , onReject :: !FireOutcome
    , onError :: !FireOutcome
    , notMine :: !FireOutcome
    }
    deriving stock (Eq, Show, Generic)

-- | @fire dispatch Surge\@correlationId MarkSurgeTimerFired { … } fired-event-id … on-ok …@.
data FireNode = FireNode
    { fireTarget :: !Name
    , fireKey :: !Text
    , fireCommand :: !Name
    , fireFields :: ![FieldBinding]
    , fireFiredEventId :: !IdExpr
    , fireDisposition :: !FireDisposition
    }
    deriving stock (Eq, Show, Generic)

-- | A nested @timer@ sub-node of a process.
data TimerNode = TimerNode
    { tmName :: !Name
    , tmId :: !IdExpr
    , tmFireAt :: !FireAtExpr
    , tmPayload :: ![FieldBinding]
    , tmFire :: !FireNode
    , tmDecodeUnknown :: !Name
    , tmMaxAttempts :: !Int
    , tmDeadLetter :: !Text
    , tmLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | A @process@ (process manager / saga) node. The dispatch-id strategy is fixed
(runtime-owned uuidv5), so it is implicit in the AST and always rendered.
-}
data ProcessNode = ProcessNode
    { procId :: !Name
    -- ^ The block identifier (@process HospitalSurge@), used for module names.
    , procName :: !Text
    -- ^ The define-once ProcessManager @name@ (@name \"hospital-surge\"@).
    , procInput :: !InputDecl
    , procCorrelate :: !CorrelateDecl
    , procSaga :: !SagaRef
    , procTarget :: !Name
    , procProjections :: ![Name]
    , procHandle :: !HandleNode
    , procTimer :: !TimerNode
    , procLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- EP-4: the cross-service @contract@ (shared Kafka message schema, define-once).

-- | A contract field type: @typeid \"inc\"@, @text@, or @int@.
data ContractType = CTypeId !Text | CText | CInt
    deriving stock (Eq, Show, Generic)

data ContractField = ContractField
    { cfName :: !Name
    , cfType :: !ContractType
    }
    deriving stock (Eq, Show, Generic)

-- | @event <Name> on <topicAlias> { field: type … }@ within a contract.
data ContractEvent = ContractEvent
    { ceName :: !Name
    , ceTopic :: !Name
    , ceFields :: ![ContractField]
    }
    deriving stock (Eq, Show, Generic)

{- | A @contract@ node: the shared cross-service message schema, declared once
and referenced by both producer (@emit@) and consumer (@intake@). EP-5's
pgmq @dispatch@ also couples to it.
-}
data ContractNode = ContractNode
    { ctrName :: !Name
    , ctrSchemaVersion :: !Int
    , ctrDiscriminator :: !Name
    , ctrTopics :: ![(Name, Text)]
    -- ^ (topic alias, real Kafka topic string)
    , ctrEvents :: ![ContractEvent]
    , ctrLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- EP-4: the @intake@ (Kafka consumer / inbox) node.

-- | Where an envelope field is read from on the wire.
data WireSource
    = SrcHeader !Text
    | SrcBody
    | SrcKafkaKey
    | SrcKafkaCursor
    deriving stock (Eq, Show, Generic)

-- | One envelope-binding row: @bind <field> from <source> [required] [cross-check body]@.
data BindRow = BindRow
    { brField :: !Name
    , brSource :: !WireSource
    , brRequired :: !Bool
    , brCrossCheck :: !Bool
    }
    deriving stock (Eq, Show, Generic)

{- | An inbox outcome action. The dangerous defaults the validator guards: a
@duplicate@\/@previouslyFailed@ must not be 'IRetry'; @decodeFailed@ must not
be an unbounded 'IRetry'.
-}
data InboxAction
    = IAckOk
    | -- | @retry <window>@, e.g. @retry 5s@
      IRetry !Text
    | IDeadLetter !(Maybe Text)
    deriving stock (Eq, Show, Generic)

-- | One row of the mandatory, complete inbox disposition table.
data DispositionRow = DispositionRow
    { drOutcome :: !Name
    , drAction :: !InboxAction
    , drLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- | The body decode-strictness decision (hole-kind 6).
data DecodeSpec = DecodeSpec
    { decEnvelope :: !Text
    -- ^ the envelope policy text, e.g. @strict-required lenient-optional@
    , decBodyStrict :: !Bool
    , decBodySchemaVersion :: !Int
    }
    deriving stock (Eq, Show, Generic)

{- | An @intake@ (Kafka consumer / inbox) node. The runtime-config @consumer@
block (brokers/groupId/offsetReset) is hole-kind 8, delegated to deployment
and not modelled here.
-}
data IntakeNode = IntakeNode
    { inkName :: !Name
    , inkContract :: !Name
    , inkTopic :: !Name
    , inkAccept :: ![Name]
    , inkBinds :: ![BindRow]
    , inkDedupeKey :: !Name
    , inkDedupePolicy :: !Name
    , inkDecode :: !DecodeSpec
    , inkDisposition :: ![DispositionRow]
    , inkLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- EP-4: the @emit@ (outbox mapping) and @publisher@ nodes.

-- | A deterministic id derivation hole: @derive [\"prefix\"] hole@.
newtype DeriveSpec = DeriveSpec {dsPrefix :: Maybe Text}
    deriving stock (Eq, Show, Generic)

-- | One @\"value\" => EventType@ row of an emit's status mapping.
data EmitMapRow = EmitMapRow
    { emrValue :: !Text
    , emrEvent :: !Name
    , emrLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | An @emit@ (outbox) node: maps a private status discriminant to contract
event types, with a mandatory explicit @_ => skip@ catch-all.
-}
data EmitNode = EmitNode
    { emName :: !Name
    , emContract :: !Name
    , emTopic :: !Name
    , emSource :: !Text
    , emKey :: !Name
    , emDiscriminant :: !Name
    , emMap :: ![EmitMapRow]
    , emSkip :: !Bool
    -- ^ whether the explicit @_ => skip@ catch-all is present
    , emMessageId :: !DeriveSpec
    , emIdempotencyKey :: !DeriveSpec
    , emLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- | @backoff <kind> <window>@, e.g. @backoff constant 2s@.
data BackoffSpec = BackoffSpec
    { boKind :: !Name
    , boWindow :: !Text
    }
    deriving stock (Eq, Show, Generic)

-- | A @publisher@ node: the at-least-once publishing policy for an emit's topic.
data PublisherNode = PublisherNode
    { pubName :: !Name
    , pubEmit :: !Name
    , pubOrdering :: !Name
    , pubMaxAttempts :: !Int
    , pubBackoff :: !BackoffSpec
    , pubOutboxField :: !Name
    -- ^ @outboxId stable from <field>@: retries coalesce on (source, this field)
    , pubLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- EP-5: the pgmq @workqueue@ + @dispatch@ nodes.

-- | One @field -> \"wire_name\" type required@ row of a workqueue payload.
data WqField = WqField
    { wqfName :: !Name
    , wqfWire :: !Text
    , wqfType :: !Name
    , wqfRequired :: !Bool
    }
    deriving stock (Eq, Show, Generic)

{- | One row of a workqueue's consumer @JobOutcome@ disposition (reusing
'InboxAction': @retry <window>@ \/ @deadLetter@).
-}
data WqDispRow = WqDispRow
    { wqdOutcome :: !Name
    , wqdAction :: !InboxAction
    , wqdLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | A pgmq @workqueue@ node. The @derive@ trio (physical\/dlq\/table) is a
/captured fixture/ (hole-kind 1): the validator re-derives the physical name
from @logical@ and flags any divergence (the drift hazard at the dedup site).
-}
data WorkqueueNode = WorkqueueNode
    { wqName :: !Name
    , wqLogical :: !Text
    , wqPhysical :: !Text
    , wqDlq :: !Text
    , wqTable :: !Text
    , wqPayloadName :: !Name
    , wqPayload :: ![WqField]
    , wqMaxRetries :: !Int
    , wqDelay :: !Text
    , wqDlqOn :: !Bool
    , wqDisposition :: ![WqDispRow]
    , wqLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | A pgmq @dispatch@ node: a read-model→enqueue coupling with a fan-out hole
and a dedup check (one arm of which is a raw-SQL hole).
-}
data PgmqDispatchNode = PgmqDispatchNode
    { pdName :: !Name
    , pdSourceReadModel :: !Name
    , pdSourceKey :: !Name
    , pdFanoutBody :: !Name
    , pdDedupKey :: !Name
    , pdDedupReadModel :: !Name
    , pdDedupReadModelField :: !Text
    , pdDedupQueue :: !Name
    , pdDedupQueueField :: !Text
    , pdEnqueueTo :: !Name
    , pdLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- EP-6: the durable @workflow@ + @operation@ nodes.

{- | One ordered item of a workflow body. Replay matches on the label, not the
position. (Positional constructors avoid partial record fields.)
-}
data WfBodyItem
    = -- | @step <label> -> <ResultType>@
      WfStep !Name !Name !Loc
    | -- | @await <label> -> <ResultType>@
      WfAwait !Name !Name !Loc
    | -- | @sleep <label> after <injected-delay-field>@ (TIME INJECTED)
      WfSleep !Name !Name !Loc
    | -- | @child <label> id input via <childIdFn> -> <ResultType>@
      WfChild !Name !Name !Name !Loc
    deriving stock (Eq, Show, Generic)

-- | A durable @workflow@ node.
data WorkflowNode = WorkflowNode
    { wfId :: !Name
    -- ^ block identifier (e.g. @HospitalTransferReservation@)
    , wfStable :: !Text
    -- ^ the stable @name "…"@ (journal stream + every deterministic id)
    , wfInput :: !Name
    , wfInputFields :: ![Field]
    , wfOutput :: !Name
    , wfIdField :: !(Maybe Name)
    -- ^ @id from input.<field>@; 'Nothing' for @id from input@
    , wfIdVia :: !Name
    , wfBody :: ![WfBodyItem]
    , wfLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- | The four operation shapes.
data OperationShape
    = -- | @command on <Agg> stream from <field> via <fn> project [ … ]@
      CommandOp !Name !Name !Name ![Name]
    | -- | @query <ReadModel> input <T> result <Type> consistency <C>@
      QueryOp !Name !Name !Text !Name
    | -- | @signal <label> of <Workflow> key from <field> via <fn> value <T>@
      SignalOp !Name !Name !Name !Name !Name
    | -- | @run <Workflow> input <T> outcome -> <Result>@
      RunOp !Name !Name !Name
    deriving stock (Eq, Show, Generic)

data OperationNode = OperationNode
    { opName :: !Name
    , opShape :: !OperationShape
    , opLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

{- | A top-level node. EP-1 defines 'NAggregate'; EP-3 adds 'NProcess'; EP-4 adds
'NContract'\/'NIntake'\/'NEmit'\/'NPublisher'; EP-5 adds 'NWorkqueue'\/
'NPgmqDispatch'; EP-6 adds 'NWorkflow'\/'NOperation'.
-}
data Node
    = NAggregate Aggregate
    | NProcess ProcessNode
    | NContract ContractNode
    | NIntake IntakeNode
    | NEmit EmitNode
    | NPublisher PublisherNode
    | NWorkqueue WorkqueueNode
    | NPgmqDispatch PgmqDispatchNode
    | NWorkflow WorkflowNode
    | NOperation OperationNode
    deriving stock (Eq, Show, Generic)

{- | The module-placement style for a scaffolded service. 'GeneratedPrefix' is
the historical default — @\<root\>.Generated.\<Ctx\>.\<Node\>@ for the generated
layer, holes at @\<root\>.\<Ctx\>.\<Node\>@. 'CollocatedLeaf' places the
generated layer as a leaf under the domain — @\<root\>.\<Ctx\>.\<Node\>.Generated@
— so it sits next to hand-written domain code (holes still at
@\<root\>.\<Ctx\>.\<Node\>@). Defined here (not in "Keiro.Dsl.Scaffold") so the
'Spec' AST can carry an author's standing choice; 'Keiro.Dsl.Scaffold'
re-exports it.
-}
data Placement
    = GeneratedPrefix
    | CollocatedLeaf
    deriving stock (Eq, Show, Generic)

{- | A whole @.keiro@ file: one context name, an optional module-placement
override (the @module@/@layout@ clauses), the shared id/enum/rule declarations,
and the list of nodes. 'specModuleRoot' and 'specLayout' are 'Nothing' when the
spec omits the clauses, reproducing the historical default.
-}
data Spec = Spec
    { specContext :: !Name
    , specModuleRoot :: !(Maybe Text)
    , specLayout :: !(Maybe Placement)
    , specIds :: ![IdDecl]
    , specEnums :: ![EnumDecl]
    , specRules :: ![RuleDecl]
    , specNodes :: ![Node]
    }
    deriving stock (Eq, Show, Generic)
