-- | The abstract syntax of the keiro DSL (@.keiro@) — the shared engine type that
-- every later vertical (EP-2…EP-6) extends additively. EP-1 defines the shared
-- declarations, the 'Expr' sublanguage, the eight hole-kind types, and the
-- 'Aggregate' node. New node families add a 'Node' constructor here in lockstep
-- with their parser, validator, and scaffold cases.
module Keiro.Dsl.Grammar
  ( -- * Names and source locations
    Name,
    Loc (..),
    unLoc,
    noLoc,

    -- * Shared declarations
    IdDecl (..),
    EnumDecl (..),
    RuleDecl (..),

    -- * Consumer-owned mapped types (EP-149)
    TypeExpr (..),
    Presence (..),
    UnknownFields (..),
    OnMissing (..),
    WireField (..),
    wireFieldLoc,
    UnionEncoding (..),
    WireEnum (..),
    WireArm (..),
    MappedShape (..),
    HaskellSource (..),
    NominalBindingDecl (..),
    NominalScalarDecl (..),
    MappedDecl (..),

    -- * Shared mapping type
    Mapping (..),

    -- * The Expr sublanguage
    Expr (..),
    ExprRoot (..),
    ScalarLiteral (..),
    exprLoc,
    CmpOp (..),
    Atom (..),
    complementExpr,

    -- * The aggregate node
    RegInitial (..),
    RegDecl (..),
    StateDecl (..),
    AggregateField (..),
    Field (..),
    Command (..),
    Event (..),
    EventBody (..),
    Hole (..),
    DomainOutcomeTypes (..),
    TransitionOutcome (..),
    transitionOutcomeLoc,
    Transition (..),
    TransitionImplementation (..),
    TransitionMode (..),
    WireSpec (..),
    ProjectionSpec (..),
    Consistency (..),
    SnapPolicy (..),
    SnapshotSpec (..),
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
    PolicyChoice (..),
    ProcessNode (..),

    -- * The router node (EP-108)
    RouterSelectionDecl (..),
    SelectionDispositionSyntax (..),
    ResolveSource (..),
    ResolveDecl (..),
    RouterDispatchNode (..),
    RouterNode (..),

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
    InkPersist (..),
    IntakeNode (..),

    -- * The integration emit/publisher nodes (EP-4)
    DeriveSpec (..),
    EmitMapRow (..),
    EmitNode (..),
    BackoffSpec (..),
    PublisherNode (..),

    -- * The pgmq workqueue/dispatch nodes (EP-5)
    QueueScalar (..),
    queueScalarName,
    QueuePayloadType (..),
    WqField (..),
    WqDispRow (..),
    WqOrdering (..),
    WqGroupKey (..),
    WqProvision (..),
    WorkqueueNode (..),
    PgmqDispatchNode (..),

    -- * Read-model nodes (EP-107)
    RmColumn (..),
    RmFeed (..),
    RmScope (..),
    ProjectionDelivery (..),
    QueryFreshnessNode (..),
    ReadModelSupply (..),
    legacyReadModelConsistency,
    legacyReadModelScope,
    legacyReadModelFeed,
    legacyReadModelSubscription,
    ReadModelQueryTypes (..),
    ReadModelNode (..),

    -- * Projection catalog nodes (language 5)
    TargetResetPolicy (..),
    ProjectionTargetNode (..),
    RebuildGroupNode (..),
    PromotionObjectKindNode (..),
    PromotionObjectNode (..),
    RevisionTargetNode (..),
    ProjectionRevisionNode (..),
    ExternalReadNode (..),
    externalReadNodeIdentity,
    CatalogSource (..),
    CheckpointOnMissingNode (..),
    ProjectionReplayPolicy (..),
    ProjectionOwnerNode (..),

    -- * The workflow/operation nodes (EP-6)
    WfBodyItem (..),
    WorkflowNode (..),
    workflowNodeLoc,
    OperationShape (..),
    OperationNode (..),

    -- * Top level
    Placement (..),
    Node (..),
    Spec (..),
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | An identifier in the notation: a type name, register name, command/event
-- name, state name, enum constructor, etc. Always a non-empty 'Text'.
type Name = Text

-- | A source line number, attached to declarations so the validator can emit
-- line-numbered diagnostics. Its 'Eq' instance deliberately ignores the line
-- value: two ASTs that differ only in source position are considered equal, so
-- the @parse . pretty == id@ round-trip property holds without the
-- pretty-printer having to reproduce exact line numbers.
newtype Loc = Loc {unLoc :: Int}
  deriving stock (Show)

unLoc :: Loc -> Int
unLoc (Loc value) = value

instance Eq Loc where
  _ == _ = True

-- | A placeholder location used by generators and pretty-print round-trips.
noLoc :: Loc
noLoc = Loc 0

-- | @id TransferReservationId prefix=rsv@ — declares an id newtype over 'Text'
-- and its prefix tag.
data IdDecl = IdDecl
  { name :: !Name,
    prefix :: !Text,
    binding :: !(Maybe NominalBindingDecl),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @enum PatientAcuity { RedTag=red … }@ — a closed enumeration; each
-- constructor carries its wire spelling (the right-hand side of @=@).
data EnumDecl = EnumDecl
  { name :: !Name,
    ctors :: ![(Name, Text)],
    binding :: !(Maybe NominalBindingDecl),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @rule lifeCriticalOverride : PatientAcuity -> Bool@ with an @ex@ line of
-- @Ctor => bool ; …@ — a total function from an enum to a value, used as a
-- derived atom inside guards.
data RuleDecl = RuleDecl
  { name :: !Name,
    domain :: !Name,
    codomain :: !Name,
    cases :: ![(Name, Expr)],
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- Consumer-owned mapped types (EP-149). The parser-facing declarations keep
-- required facts optional so `keiro-dsl check` can report stable, located
-- diagnostics for omissions. Keiro.Dsl.TypeGraph turns valid values into a
-- checked representation before downstream consumers inspect them.

data TypeExpr
  = TText
  | TInt
  | TInteger
  | TBool
  | TNatural
  | TTime
  | TJson
  | TOptional !TypeExpr
  | TList !TypeExpr
  | TMap !TypeExpr
  | TRef !Name
  deriving stock (Eq, Show, Generic)

data Presence = PRequired | POptional
  deriving stock (Eq, Show, Generic)

data UnknownFields = RejectUnknown | IgnoreUnknown
  deriving stock (Eq, Show, Generic)

data OnMissing
  = OmNull
  | OmText !Text
  | OmInt !Integer
  | OmBool !Bool
  | OmEmptyList
  | OmEmptyMap
  | OmCtor !Name
  deriving stock (Eq, Show, Generic)

data WireField = WireField
  { haskell :: !Name,
    key :: !Text,
    valueType :: !TypeExpr,
    presence :: !Presence,
    onMissing :: !(Maybe OnMissing),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

wireFieldLoc :: WireField -> Loc
wireFieldLoc WireField {loc} = loc

data UnionEncoding = TaggedObject
  { tagField :: !Text,
    contentsField :: !Text,
    unknownFields :: !UnknownFields
  }
  deriving stock (Eq, Show, Generic)

data WireEnum = WireEnum
  { ctor :: !Name,
    tag :: !Text,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data WireArm = WireArm
  { ctor :: !Name,
    tag :: !Text,
    payload :: !(Maybe TypeExpr),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data MappedShape
  = ShapeRecord !Name !UnknownFields ![WireField]
  | ShapeEnum ![WireEnum]
  | ShapeUnion !UnionEncoding ![WireArm]
  deriving stock (Eq, Show, Generic)

data HaskellSource = HaskellSource
  { package :: !Text,
    moduleName :: !Text,
    valueType :: !Name
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Parser-facing facts for a total consumer-owned nominal binding.
--
-- The fields remain optional only so validation can report every missing fact at
-- the owning declaration. Downstream code consumes the checked nominal registry.
data NominalBindingDecl = NominalBindingDecl
  { haskell :: !(Maybe HaskellSource),
    binding :: !(Maybe Text),
    bindingVersion :: !(Maybe Text),
    canonicalType :: !(Maybe Text),
    fixtures :: !(Maybe Text),
    initial :: !(Maybe Text),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A consumer-owned nominal scalar over one declared representation name.
--
-- The raw representation name is retained so @keiro-dsl check@ owns the stable
-- unsupported-representation diagnostic instead of the low-level parser.
data NominalScalarDecl = NominalScalarDecl
  { name :: !Name,
    representation :: !Name,
    binding :: !NominalBindingDecl,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data MappedDecl
  = MappedStructural
      { msName :: !Name,
        msHaskell :: !(Maybe HaskellSource),
        msBinding :: !(Maybe Text),
        msBindingVersion :: !(Maybe Text),
        msCanonical :: !(Maybe Text),
        msFixtures :: !(Maybe Text),
        msInitial :: !(Maybe Text),
        msShape :: !MappedShape,
        msLoc :: !Loc
      }
  | MappedOpaque
      { moName :: !Name,
        moHaskell :: !(Maybe HaskellSource),
        moCodecId :: !(Maybe Text),
        moCodecVersion :: !(Maybe Text),
        moFixtures :: !(Maybe Text),
        moInitial :: !(Maybe Text),
        moLoc :: !Loc
      }
  deriving stock (Eq, Show, Generic)

-- | Hole-kind 3: an explicit value→value table that is not an identity echo
-- (e.g. an event name → projection status). @mapPartial@ records whether the
-- spec author explicitly marked the table partial over its domain.
data Mapping = Mapping
  { pairs :: ![(Name, Name)],
    partial :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | The @Expr@ sublanguage used by @guard@ clauses and the right-hand side of
-- @write@ clauses. An infix expression over 'Atom's; operators in precedence
-- order are @||@ (lowest), @&&@, then the relational comparisons.
data Expr
  = EOr !Expr !Expr
  | EAnd !Expr !Expr
  | ECmp !CmpOp !Expr !Expr
  | EAdd !Loc !Expr !Expr
  | ESubtract !Loc !Expr !Expr
  | EMultiply !Loc !Expr !Expr
  | EPath !Loc !ExprRoot ![Name]
  | ELiteral !Loc !ScalarLiteral
  | EAtom !Atom
  deriving stock (Eq, Show, Generic)

-- | The provenance of a version-2 scalar path. The first path segment is the
-- register or active command-field name; remaining segments are required
-- structural record fields.
data ExprRoot
  = UnqualifiedRoot
  | RegisterRoot
  | CommandRoot
  deriving stock (Eq, Ord, Show, Generic)

-- | Surface scalar literals whose final type is selected by the resolver.
-- Quoted literals deliberately share one syntax for Text and Time; integral
-- literals share one syntax for Int, Integer, and Natural. No numeric coercion
-- follows from that syntactic sharing.
data ScalarLiteral
  = LiteralText !Text
  | LiteralIntegral !Integer
  | LiteralBool !Bool
  | LiteralQualified !Name !Name
  | LiteralId !Name !Text
  deriving stock (Eq, Show, Generic)

-- | Best available source row for an expression node. Version-2 atoms and
-- arithmetic retain their exact row; legacy nodes fall back through children
-- and ultimately to 'noLoc'.
exprLoc :: Expr -> Loc
exprLoc = \case
  EOr left right -> firstLocated left right
  EAnd left right -> firstLocated left right
  ECmp _ left right -> firstLocated left right
  EAdd loc _ _ -> loc
  ESubtract loc _ _ -> loc
  EMultiply loc _ _ -> loc
  EPath loc _ _ -> loc
  ELiteral loc _ -> loc
  EAtom {} -> noLoc
  where
    firstLocated left right = case exprLoc left of
      Loc 0 -> exprLoc right
      loc -> loc

data CmpOp = OpEq | OpNeq | OpLt | OpLe | OpGt | OpGe
  deriving stock (Eq, Show, Generic)

-- | An atom is either a bare boolean literal (@true@/@false@) or a name. Names
-- are kept syntactically neutral: at parse time an identifier is
-- indistinguishable between a register, a command field, an enum constructor,
-- and a rule, so the validator's scope-check (M2) resolves which one each
-- 'AName' is against the declared sets. This keeps the parser honest and the
-- round-trip exact.
data Atom
  = AName !Name
  | ABool !Bool
  deriving stock (Eq, Show, Generic)

-- | The logical complement of a guard, expressed inside the existing grammar —
-- 'Expr' has no negation constructor, but negation is eliminable: De Morgan over
-- 'EOr'\/'EAnd', comparison-operator flipping, boolean-literal flip, and
-- @x == false@ for a bare name atom (guards are boolean-valued, so a bare name
-- in guard position is a boolean read). Used by @diff@ to compute the
-- replay-only twin of a tightened guard (@old ∧ ¬new@, plan 143): the printed
-- complement re-parses as a valid guard today.
--
-- Caveat: comparison flipping is classical — @¬(a < b) = a >= b@ — which is
-- correct over the DSL's total ordered domains.
complementExpr :: Expr -> Expr
complementExpr = \case
  EOr l r -> EAnd (complementExpr l) (complementExpr r)
  EAnd l r -> EOr (complementExpr l) (complementExpr r)
  ECmp op l r -> ECmp (complementCmp op) l r
  ELiteral loc (LiteralBool value) -> ELiteral loc (LiteralBool (not value))
  EAtom (ABool b) -> EAtom (ABool (not b))
  e@(EAtom _) -> ECmp OpEq e (EAtom (ABool False))
  e -> ECmp OpEq e (ELiteral (exprLoc e) (LiteralBool False))
  where
    complementCmp = \case
      OpEq -> OpNeq
      OpNeq -> OpEq
      OpLt -> OpGe
      OpLe -> OpGt
      OpGt -> OpLe
      OpGe -> OpLt

-- | @name Type = initial@ — a named register with its declared type and the
-- initial value (an identifier: a literal like @placeholder@, an enum
-- constructor, or a state name).
data RegInitial
  = RegInitBare !Text
  | RegInitText !Text
  deriving stock (Eq, Show, Generic)

data RegDecl = RegDecl
  { name :: !Name,
    valueType :: !TypeExpr,
    initial :: !RegInitial,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | One entry in a @states@ list. @stTerminal@ is set when the name carries a
-- trailing @!@ (no outgoing transitions allowed). The first 'StateDecl' in an
-- aggregate's list is its initial state.
data StateDecl = StateDecl
  { name :: !Name,
    terminal :: !Bool,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | An aggregate command/event field. The logical DSL name remains the identity
-- used by expressions and evolution pairing. Optional aliases independently
-- select the generated Haskell record selector and serialized wire key.
-- A bare name reuses the field's inferred aggregate type; @name:Type@ accepts
-- the complete 'TypeExpr' grammar so semantic validation can reject unsupported
-- direct shapes with a located diagnostic.
data AggregateField = AggregateField
  { name :: !Name,
    selector :: !(Maybe Name),
    wireKey :: !(Maybe Text),
    valueType :: !(Maybe TypeExpr),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A generic field used by process and router nodes. Aggregate fields are
-- kept separate so widening aggregate syntax does not widen those node families.
data Field = Field
  { name :: !Name,
    valueType :: !(Maybe Name)
  }
  deriving stock (Eq, Show, Generic)

-- | @command Name { field … }@ — a command constructor.
data Command = Command
  { name :: !Name,
    fields :: ![AggregateField],
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @event Name { … }@ or @event Name = fields(Command)@. EP-2 (evolution) adds
-- the version/upcaster/retirement fields: an unversioned event is @evVersion = 1@,
-- @evUpcastFrom = Nothing@, @evRetiring = False@, and @evDeprecated = False@,
-- reproducing the EP-1 surface. These fields live on the shared 'Event' so every
-- node family's events inherit schema-versioning for free.
data Event = Event
  { name :: !Name,
    body :: !EventBody,
    -- | The schema version of this event shape. Default 1; written @vN@ for N>1.
    version :: !Int,
    -- | The source version this shape migrates /from/, paired with the upcaster
    --     hole. @Just (n-1, …)@ for a @vN@ shape; 'Nothing' for v1.
    upcastFrom :: !(Maybe (Int, Hole)),
    -- | Retirement is in progress. The event must keep at least one live
    --     emitting transition while operators terminalize or truncate affected
    --     streams; cut over to @deprecated@ plus a replay-only emitting transition
    --     afterwards.
    retiring :: !Bool,
    -- | Retired from the write path (no live transition may @emit@ it) but
    --     still decodable from the log. A replay-only emitting transition must remain
    --     while live streams can still contain the event.
    deprecated :: !Bool,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data EventBody
  = EventFields ![AggregateField]
  | EventFromCommand !Name
  deriving stock (Eq, Show, Generic)

-- | A spec hole: an unfilled placeholder ('Hole', written @HOLE@ in the
-- notation) or a value the author supplied inline ('Filled').
data Hole = Hole | Filled !Text
  deriving stock (Eq, Show, Generic)

-- | The aggregate-wide result types used by typed domain decisions. The
-- declaration is opt-in so published sources without it retain their existing
-- command surface.
data DomainOutcomeTypes = DomainOutcomeTypes
  { rejectionType :: !Name,
    noOpType :: !Name,
    outcomeTypesLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | The result attached to one live transition. Rejection and no-op reasons
-- use the same typed scalar expression language as guards and register writes.
data TransitionOutcome
  = OutcomeAccepted !Loc
  | OutcomeRejected !Expr !Loc
  | OutcomeNoOp !Expr !Loc
  deriving stock (Eq, Show, Generic)

transitionOutcomeLoc :: TransitionOutcome -> Loc
transitionOutcomeLoc (OutcomeAccepted loc) = loc
transitionOutcomeLoc (OutcomeRejected _ loc) = loc
transitionOutcomeLoc (OutcomeNoOp _ loc) = loc

-- | A transition @Src -- Command --> clauses@. Clauses may be written
-- indentation-stacked or @;@-separated on one line.
data Transition = Transition
  { source :: !Name,
    command :: !Name,
    implementation :: !TransitionImplementation,
    guard :: !(Maybe Expr),
    writes :: ![(Name, Expr)],
    emits :: ![Name],
    outcome :: !(Maybe TransitionOutcome),
    -- | Locations of clauses after the first. Invalid syntax is retained long
    -- enough for semantic validation to emit stable located diagnostics.
    outcomeDuplicateLocs :: ![Loc],
    goto :: !Name,
    mode :: !TransitionMode,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | Exclusive behavior ownership. 'LegacyHoleImplementation' exists only for
-- the frozen version-1 parser and preserves its create-once aggregate-wide
-- transducer. Version 2 produces either generated ownership (the default) or
-- an explicit per-transition Hole implementation.
data TransitionImplementation
  = LegacyHoleImplementation
  | GeneratedImplementation
  | HoleImplementation
  deriving stock (Eq, Ord, Show, Generic)

-- | Whether a transition serves forward execution or replay only (plan 143).
-- A @replay-only@ transition lowers to a keiki 'ReplayOnly' edge: it is never
-- taken by a new command and exists so events emitted under a retired rule keep
-- an inverting edge. Spelled as a @replay-only@ prefix on the transition line:
--
-- @
-- replay-only Held -- ConfirmReservation --> guard … ; emit … ; goto …
-- @
data TransitionMode = TmLive | TmReplayOnly
  deriving stock (Eq, Show, Generic)

-- | @wire kind=ctorName fields=camelCase schemaVersion=1@ — how events
-- serialize.
data WireSpec = WireSpec
  { kind :: !Text,
    fields :: !Text,
    schemaVersion :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | @projection table consistency=… key=… status-map { … }@ — the read-model
-- projection and its event→status 'Mapping' (hole-kind 3).
data ProjectionSpec = ProjectionSpec
  { table :: !Name,
    consistency :: !(Maybe Consistency),
    key :: !Name,
    statusMap :: !(Maybe Mapping),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data Consistency = Strong | Eventual
  deriving stock (Eq, Show, Generic)

-- | A generated aggregate snapshot policy supported by the notation.
data SnapPolicy = SnapEvery !Int | SnapOnTerminal
  deriving stock (Eq, Show, Generic)

-- | Snapshot policy plus the captured live state-codec identity.
data SnapshotSpec = SnapshotSpec
  { policy :: !SnapPolicy,
    codecVersion :: !Int,
    shapeHash :: !Text,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | An @aggregate@ node: a consistency boundary whose state is rebuilt by
-- replaying events.
data Aggregate = Aggregate
  { name :: !Name,
    regs :: ![RegDecl],
    states :: ![StateDecl],
    commands :: ![Command],
    events :: ![Event],
    transitions :: ![Transition],
    domainOutcomeTypes :: !(Maybe DomainOutcomeTypes),
    -- | Locations of declarations after the first; see
    -- 'tOutcomeDuplicateLocs'.
    domainOutcomeDuplicateLocs :: ![Loc],
    wire :: !(Maybe WireSpec),
    projection :: !(Maybe ProjectionSpec),
    snapshot :: !(Maybe SnapshotSpec),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-3: process manager + durable timer nodes.

-- | A @field@ or @field=value@ binding inside a command\/payload field list.
-- A bare field reuses the input field of the same name; @name=value@ binds it to
-- an expression (kept as raw text, e.g. @timerId=timer.id@).
data FieldBinding = FieldBinding
  { name :: !Name,
    value :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | @input SurgeInput { hospitalId … observedAt:Time }@ — the process's incoming
-- event shape (one field must be a @:Time@ field used by the timer deadline).
data InputDecl = InputDecl
  { name :: !Name,
    fields :: ![Field],
    valueType :: !(Maybe TypeExpr),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @correlate input.hospitalId via idText@ — the correlation key (hole-kind 1
-- derivation + hole-kind 4 field-source).
data CorrelateDecl = CorrelateDecl
  { field :: !Name,
    via :: !Name
  }
  deriving stock (Eq, Show, Generic)

-- | @saga Surge category \"hospitalSurge\"@ — the saga's own aggregate plus
-- the validated stream category used with @Keiro.Stream.entityStream@.  For a
-- correlation id @c@, the saga stream is @<category>-<c>@.
data SagaRef = SagaRef
  { agg :: !Name,
    category :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | A command dispatch outcome action.
data Disp = DAckOk | DRetry | DDeadLetter !Text
  deriving stock (Eq, Show, Generic)

-- | The complete dispatch disposition table (every arm mandatory; the
-- @on-duplicate AckOk@ benign inversion is explicit).
data DispatchDisposition = DispatchDisposition
  { onAppended :: !Disp,
    onDuplicate :: !Disp,
    onFailed :: !Disp
  }
  deriving stock (Eq, Show, Generic)

-- | @advance NoteSurgeThreshold { … }@ — the self-command that advances the saga.
data AdvanceNode = AdvanceNode
  { advCommand :: !Name,
    advFields :: ![FieldBinding]
  }
  deriving stock (Eq, Show, Generic)

-- | @dispatch Hospital\@input.hospitalId ActivateSurge { … } on-appended … on-duplicate … on-failed …@.
data DispatchNode = DispatchNode
  { target :: !Name,
    key :: !Text,
    command :: !Name,
    fields :: ![FieldBinding],
    disposition :: !DispatchDisposition,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | The @on <Input>@ reaction: a self-advance, zero or more dispatches, and a
-- @schedule@ of the timer.
data HandleNode = HandleNode
  { on :: !Name,
    advance :: !AdvanceNode,
    dispatch :: ![DispatchNode],
    schedule :: !Name
  }
  deriving stock (Eq, Show, Generic)

-- | A deterministic id derivation: @uuidv5 \"prefix:\" <> correlationId@.
data IdExpr = IdExpr
  { strategy :: !IdStrategy,
    prefix :: !Text,
    field :: !Name
  }
  deriving stock (Eq, Show, Generic)

data IdStrategy = UuidV5Id
  deriving stock (Eq, Show, Generic)

-- | @fireAt input.observedAt + 5m@ — an injected timestamp field plus a window.
-- There is no clock-sampling constructor, so the no-wall-clock rule holds by
-- construction.
data FireAtExpr = FireAtExpr
  { field :: !Name,
    window :: !Text
  }
  deriving stock (Eq, Show, Generic)

data FireOutcome = OFired | ORetry
  deriving stock (Eq, Show, Generic)

-- | The complete timer-fire disposition table; @on-reject OFired@ is the benign
-- inversion (a CommandRejected means \"already applied\" = success).
data FireDisposition = FireDisposition
  { onOk :: !FireOutcome,
    onReject :: !FireOutcome,
    onAmbiguous :: !FireOutcome,
    onError :: !FireOutcome,
    notMine :: !FireOutcome
  }
  deriving stock (Eq, Show, Generic)

-- | @fire dispatch Surge\@correlationId MarkSurgeTimerFired { … } fired-event-id … on-ok …@.
data FireNode = FireNode
  { target :: !Name,
    key :: !Text,
    command :: !Name,
    fields :: ![FieldBinding],
    firedEventId :: !IdExpr,
    disposition :: !FireDisposition
  }
  deriving stock (Eq, Show, Generic)

-- | A nested @timer@ sub-node of a process.
data TimerNode = TimerNode
  { name :: !Name,
    id :: !IdExpr,
    fireAt :: !FireAtExpr,
    payload :: ![FieldBinding],
    fire :: !FireNode,
    decodeUnknown :: !Name,
    maxAttempts :: !Int,
    deadLetter :: !Text,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A node-level worker policy lowered to the runtime worker options.
data PolicyChoice = PolHalt | PolDeadLetter | PolSkip
  deriving stock (Eq, Show, Generic)

-- | A @process@ (process manager / saga) node. The dispatch-id strategy is fixed
-- (runtime-owned uuidv5), so it is implicit in the AST and always rendered.
data ProcessNode = ProcessNode
  { -- | The block identifier (@process HospitalSurge@), used for module names.
    id :: !Name,
    -- | The define-once ProcessManager @name@ (@name \"hospital-surge\"@).
    name :: !Text,
    input :: !InputDecl,
    correlate :: !CorrelateDecl,
    saga :: !SagaRef,
    target :: !Name,
    projections :: ![Name],
    handle :: !HandleNode,
    rejected :: !PolicyChoice,
    poison :: !PolicyChoice,
    timer :: !TimerNode,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-108: stateless, effectful content-based routing.

data SelectionDispositionSyntax
  = SelectionAck
  | SelectionRetry
  | SelectionDeadLetter
  | SelectionHalt
  deriving stock (Eq, Ord, Show, Generic)

-- | Candidate language-5 syntax for a bounded, generated router selection.
-- Policy spellings that are not yet admitted remain raw names so validation,
-- rather than parsing, owns stable diagnostics for future-looking values.
data RouterSelectionDecl = RouterSelectionDecl
  { identity :: !Text,
    identityLoc :: !Loc,
    version :: !Natural,
    versionLoc :: !Loc,
    query :: !Name,
    queryLoc :: !Loc,
    queryInput :: !Name,
    queryInputLoc :: !Loc,
    predicate :: !Expr,
    recipient :: !Expr,
    limit :: !(Maybe (Natural, Loc)),
    order :: !Name,
    orderLoc :: !Loc,
    dedupe :: !Name,
    dedupeLoc :: !Loc,
    emptyPolicy :: !SelectionDispositionSyntax,
    emptyPolicyLoc :: !Loc,
    failurePolicy :: !SelectionDispositionSyntax,
    failurePolicyLoc :: !Loc,
    redelivery :: !Name,
    redeliveryLoc :: !Loc,
    partial :: !Name,
    partialLoc :: !Loc,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data ResolveSource
  = ResolveReadModel !Name
  | ResolveHole
  | ResolveDeclarative !RouterSelectionDecl
  deriving stock (Eq, Show, Generic)

data ResolveDecl = ResolveDecl
  { source :: !ResolveSource,
    row :: ![Name],
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data RouterDispatchNode = RouterDispatchNode
  { command :: !Name,
    fields :: ![FieldBinding],
    disposition :: !DispatchDisposition,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A stateless router. Its fixed dispatch-id strategy is runtime-owned, and
-- the mandatory @stable@ token on the resolve clause is an author acknowledgement
-- that retry attempts accumulate the union of resolved target identities.
data RouterNode = RouterNode
  { id :: !Name,
    name :: !Text,
    input :: !InputDecl,
    key :: !CorrelateDecl,
    resolve :: !ResolveDecl,
    target :: !Name,
    projections :: ![Name],
    dispatch :: !RouterDispatchNode,
    rejected :: !PolicyChoice,
    poison :: !PolicyChoice,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-4: the cross-service @contract@ (shared Kafka message schema, define-once).

-- | A contract field type: @typeid \"inc\"@, @text@, or @int@.
data ContractType = CTypeId !Text | CText | CInt
  deriving stock (Eq, Show, Generic)

data ContractField = ContractField
  { name :: !Name,
    selector :: !(Maybe Name),
    wireKey :: !(Maybe Text),
    valueType :: !ContractType,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @event <Name> on <topicAlias> { field: type … }@ within a contract.
data ContractEvent = ContractEvent
  { name :: !Name,
    topic :: !Name,
    fields :: ![ContractField]
  }
  deriving stock (Eq, Show, Generic)

-- | A @contract@ node: the shared cross-service message schema, declared once
-- and referenced by both producer (@emit@) and consumer (@intake@). EP-5's
-- pgmq @dispatch@ also couples to it.
data ContractNode = ContractNode
  { name :: !Name,
    schemaVersion :: !Int,
    discriminator :: !Name,
    -- | (topic alias, real Kafka topic string)
    topics :: ![(Name, Text)],
    events :: ![ContractEvent],
    loc :: !Loc
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
  { field :: !Name,
    source :: !WireSource,
    required :: !Bool,
    crossCheck :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | An inbox outcome action. The dangerous defaults the validator guards: a
-- @duplicate@\/@previouslyFailed@ must not be 'IRetry'; @decodeFailed@ must not
-- be an unbounded 'IRetry'.
data InboxAction
  = IAckOk
  | -- | @retry <window>@, e.g. @retry 5s@
    IRetry !Text
  | IDeadLetter !(Maybe Text)
  deriving stock (Eq, Show, Generic)

-- | One row of the mandatory, complete inbox disposition table.
data DispositionRow = DispositionRow
  { outcome :: !Name,
    action :: !InboxAction,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | The body decode-strictness decision (hole-kind 6).
data DecodeSpec = DecodeSpec
  { -- | the envelope policy text, e.g. @strict-required lenient-optional@
    envelope :: !Text,
    bodyStrict :: !Bool,
    bodySchemaVersion :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | How much of a successfully processed envelope the inbox retains.
data InkPersist = InkPersistFull | InkPersistDedupeOnly
  deriving stock (Eq, Show, Generic)

-- | An @intake@ (Kafka consumer / inbox) node. The runtime-config @consumer@
-- block (brokers/groupId/offsetReset) is hole-kind 8, delegated to deployment
-- and not modelled here.
data IntakeNode = IntakeNode
  { name :: !Name,
    contract :: !Name,
    topic :: !Name,
    accept :: ![Name],
    binds :: ![BindRow],
    dedupeKey :: !Name,
    dedupePolicy :: !Name,
    persist :: !InkPersist,
    decode :: !DecodeSpec,
    disposition :: ![DispositionRow],
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-4: the @emit@ (outbox mapping) and @publisher@ nodes.

-- | A deterministic id derivation hole: @derive [\"prefix\"] hole@.
newtype DeriveSpec = DeriveSpec {dsPrefix :: Maybe Text}
  deriving stock (Eq, Show, Generic)

-- | One @\"value\" => EventType@ row of an emit's status mapping.
data EmitMapRow = EmitMapRow
  { value :: !Text,
    event :: !Name,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | An @emit@ (outbox) node: maps a private status discriminant to contract
-- event types, with a mandatory explicit @_ => skip@ catch-all.
data EmitNode = EmitNode
  { name :: !Name,
    contract :: !Name,
    topic :: !Name,
    source :: !Text,
    key :: !Name,
    discriminant :: !Name,
    map :: ![EmitMapRow],
    -- | whether the explicit @_ => skip@ catch-all is present
    skip :: !Bool,
    messageId :: !DeriveSpec,
    idempotencyKey :: !DeriveSpec,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @backoff <kind> <window>@, e.g. @backoff constant 2s@.
data BackoffSpec = BackoffSpec
  { kind :: !Name,
    window :: !Text,
    max :: !(Maybe Text),
    multiplier :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | A @publisher@ node: the at-least-once publishing policy for an emit's topic.
data PublisherNode = PublisherNode
  { name :: !Name,
    emit :: !Name,
    ordering :: !Name,
    maxAttempts :: !Int,
    backoff :: !BackoffSpec,
    -- | @outboxId stable from <field>@: retries coalesce on (source, this field)
    outboxField :: !Name,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-5: the pgmq @workqueue@ + @dispatch@ nodes.

-- | The legacy lower-case workqueue scalar vocabulary. These constructors
-- retain the released generated JSON meaning of @text@, @int@, and @bool@.
data QueueScalar
  = QueueText
  | QueueInt
  | QueueBool
  | QueueOther !Name
  deriving stock (Eq, Show, Generic)

queueScalarName :: QueueScalar -> Name
queueScalarName QueueText = "text"
queueScalarName QueueInt = "int"
queueScalarName QueueBool = "bool"
queueScalarName (QueueOther name) = name

-- | A workqueue field either retains its released scalar spelling or owns a
-- complete candidate-language mapped type expression.
data QueuePayloadType
  = LegacyQueueScalar !QueueScalar
  | TypedQueueExpression !TypeExpr
  deriving stock (Eq, Show, Generic)

-- | One @field -> \"wire_name\" type required@ row of a workqueue payload.
data WqField = WqField
  { name :: !Name,
    wire :: !Text,
    valueType :: !QueuePayloadType,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | One row of a workqueue's consumer @JobOutcome@ disposition (reusing
-- 'InboxAction': @retry <window>@ \/ @deadLetter@).
data WqDispRow = WqDispRow
  { outcome :: !Name,
    action :: !InboxAction,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | The queue's semantic delivery-order contract.
data WqOrdering = WqUnordered | WqFifoThroughput | WqFifoRoundRobin
  deriving stock (Eq, Show, Generic)

-- | A FIFO message-group key derived from one payload field.
data WqGroupKey = WqGroupKey
  { field :: !Name,
    via :: !Name,
    fixture :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The PostgreSQL storage shape provisioned for a queue.
data WqProvision
  = WqStandard
  | WqUnlogged
  | WqPartitioned !Text !Text
  deriving stock (Eq, Show, Generic)

-- | A pgmq @workqueue@ node. The @derive@ trio (physical\/dlq\/table) is a
-- /captured fixture/ (hole-kind 1): the validator re-derives the physical name
-- from @logical@ and flags any divergence (the drift hazard at the dedup site).
data WorkqueueNode = WorkqueueNode
  { name :: !Name,
    logical :: !Text,
    physical :: !Text,
    dlq :: !Text,
    table :: !Text,
    ordering :: !WqOrdering,
    groupKey :: !(Maybe WqGroupKey),
    provision :: !WqProvision,
    payloadName :: !Name,
    payload :: ![WqField],
    maxRetries :: !Int,
    delay :: !Text,
    dlqOn :: !Bool,
    disposition :: ![WqDispRow],
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A pgmq @dispatch@ node: a read-model→enqueue coupling with a fan-out hole
-- and a dedup check (one arm of which is a raw-SQL hole).
data PgmqDispatchNode = PgmqDispatchNode
  { name :: !Name,
    sourceReadModel :: !Name,
    sourceKey :: !Name,
    fanoutBody :: !Name,
    dedupKey :: !Name,
    dedupReadModel :: !Name,
    dedupReadModelField :: !Text,
    dedupQueue :: !Name,
    dedupQueueField :: !Text,
    enqueueTo :: !Name,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-107: first-class read-model declarations.

-- | One declared SQL column. The validator owns the closed type vocabulary.
data RmColumn = RmColumn
  { rmcName :: !Text,
    rmcType :: !Text,
    rmcRequired :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | Whether the model is fed in a command transaction or by a subscription.
data RmFeed = RmInline | RmSubscription
  deriving stock (Eq, Show, Generic)

-- | Which event-log head a strong read waits for.
data RmScope = RmEntireLog | RmCategory !Text
  deriving stock (Eq, Show, Generic)

-- | When a projection owner applies events to its targets.
data ProjectionDelivery
  = DeliveryInline
  | DeliverySubscription
  deriving stock (Eq, Ord, Show, Generic)

-- | What, if anything, a query waits for before reading its target.
data QueryFreshnessNode
  = FreshnessImmediate
  | FreshnessWaitForHead !RmScope
  deriving stock (Eq, Show, Generic)

-- | How a read model finds its projection supply. Released Languages 1-4 keep
-- their original clauses here as source provenance; candidate Language 5
-- derives delivery and cursor identity from the validated projection owner.
data ReadModelSupply
  = LegacyReadModelSupply
      { legacyConsistency :: !Consistency,
        legacyScope :: !(Maybe RmScope),
        legacyFeed :: !RmFeed,
        legacySubscription :: !(Maybe Text)
      }
  | OwnerDerivedSupply
  deriving stock (Eq, Show, Generic)

-- | The two type parameters of the generated @ReadModel q r@ API. The pair is
-- atomic because accepting only one side could not be lowered completely.
data ReadModelQueryTypes = ReadModelQueryTypes
  { input :: !TypeExpr,
    result :: !TypeExpr,
    inputLoc :: !Loc,
    resultLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A registered, versioned SQL read model. Columns define its shape identity;
-- the runtime table remains owned by codd migrations rather than the DSL.
data ReadModelNode = ReadModelNode
  { name :: !Name,
    table :: !Text,
    schema :: !Text,
    columns :: ![RmColumn],
    version :: !Int,
    shape :: !Text,
    freshness :: !QueryFreshnessNode,
    supply :: !ReadModelSupply,
    group :: !(Maybe Name),
    observedTargets :: ![Name],
    backingTarget :: !(Maybe Name),
    queryTypes :: !(Maybe ReadModelQueryTypes),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

legacyReadModelConsistency :: ReadModelNode -> Maybe Consistency
legacyReadModelConsistency readModel = case (.supply) readModel of
  LegacyReadModelSupply {legacyConsistency} -> Just legacyConsistency
  OwnerDerivedSupply -> Nothing

legacyReadModelScope :: ReadModelNode -> Maybe RmScope
legacyReadModelScope readModel = case (.supply) readModel of
  LegacyReadModelSupply {legacyScope} -> legacyScope
  OwnerDerivedSupply -> Nothing

legacyReadModelFeed :: ReadModelNode -> Maybe RmFeed
legacyReadModelFeed readModel = case (.supply) readModel of
  LegacyReadModelSupply {legacyFeed} -> Just legacyFeed
  OwnerDerivedSupply -> Nothing

legacyReadModelSubscription :: ReadModelNode -> Maybe Text
legacyReadModelSubscription readModel = case (.supply) readModel of
  LegacyReadModelSupply {legacySubscription} -> legacySubscription
  OwnerDerivedSupply -> Nothing

-- | Destructive preparation clears a target; preserve retains brownfield rows
-- for an application-owned reconciliation adapter.
data TargetResetPolicy = TargetClear | TargetPreserve
  deriving stock (Eq, Show, Generic)

-- | One physical PostgreSQL target owned by exactly one catalog group.
data ProjectionTargetNode = ProjectionTargetNode
  { name :: !Name,
    schema :: !Text,
    table :: !Text,
    reset :: !TargetResetPolicy,
    dependsOn :: ![Name],
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | One atomic lifecycle group and its deterministic target preparation order.
data RebuildGroupNode = RebuildGroupNode
  { name :: !Name,
    targets :: ![Name],
    order :: ![Name],
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data PromotionObjectKindNode
  = PromotionIndexNode
  | PromotionConstraintNode
  | PromotionOwnedSequenceNode
  deriving stock (Eq, Ord, Show, Generic)

data PromotionObjectNode = PromotionObjectNode
  { kind :: !PromotionObjectKindNode,
    generationName :: !Text,
    canonicalName :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Application-owned schema contract for one target in a projection
-- revision. The DSL carries stable identities, never raw DDL.
data RevisionTargetNode = RevisionTargetNode
  { target :: !Name,
    schemaVersion :: !Text,
    provisioner :: !Text,
    provisionerVersion :: !Int,
    expectedShape :: !Text,
    validator :: !Text,
    validatorVersion :: !Int,
    promotionObjects :: ![PromotionObjectNode]
  }
  deriving stock (Eq, Show, Generic)

data ProjectionRevisionNode = ProjectionRevisionNode
  { name :: !Name,
    group :: !Name,
    targets :: ![RevisionTargetNode],
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | Candidate language-5 declaration for one bounded all-row external SQL
-- contract. The result shape is deliberately absent: lowering obtains it from
-- the checked read-model binding so source and runtime identity cannot drift.
data ExternalReadNode = ExternalReadNode
  { name :: !Name,
    version :: !Int,
    queryModel :: !Name,
    resultSchema :: !Text,
    resultType :: !Text,
    compatibleRevisions :: ![Name],
    surfaceGeneration :: !Int,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | Top-level declaration identity. Several contract versions may coexist,
-- so source-level duplicate detection keys by contract and version together.
externalReadNodeIdentity :: ExternalReadNode -> Name
externalReadNodeIdentity externalRead =
  (.name) externalRead <> "_v" <> T.pack (show ((.version) externalRead))

-- | A replay source selected by a projection owner.
data CatalogSource
  = CatalogAggregate !Name
  | CatalogCategory !Text
  | CatalogAll
  deriving stock (Eq, Show, Generic)

-- | What a subscription feed does when its exact durable checkpoint is absent.
-- The parser retains a list so validation can diagnose omission and duplication
-- precisely; a validated subscription owner has exactly one value.
data CheckpointOnMissingNode
  = CheckpointFromBeginning
  | CheckpointFromCurrentHead
  | CheckpointFail
  deriving stock (Eq, Show, Generic)

-- | Whether a projection has an application-owned replay adapter or is
-- intentionally live-only for the recorded reason.
data ProjectionReplayPolicy
  = ProjectionReplayExplicit
  | ProjectionLiveOnly !Text
  deriving stock (Eq, Show, Generic)

-- | One ordered live/replay handler declaration in the service catalog.
data ProjectionOwnerNode = ProjectionOwnerNode
  { name :: !Name,
    sources :: ![CatalogSource],
    delivery :: !ProjectionDelivery,
    group :: !Name,
    targets :: ![Name],
    order :: !Int,
    subscription :: !(Maybe Text),
    dedup :: !(Maybe Text),
    checkpointOnMissing :: ![CheckpointOnMissingNode],
    replay :: !ProjectionReplayPolicy,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-6: the durable @workflow@ + @operation@ nodes.

-- | One ordered item of a workflow body. Replay matches on the label, not the
-- position. (Positional constructors avoid partial record fields.)
data WfBodyItem
  = -- | @step <label> -> <ResultType>@
    WfStep !Name !Name !Loc
  | -- | @await <label> -> <ResultType>@
    WfAwait !Name !Name !Loc
  | -- | @sleep <label> after <injected-delay-field>@ (TIME INJECTED)
    WfSleep !Name !Name !Loc
  | -- | @child <label> id input via <childIdFn> -> <ResultType>@
    WfChild !Name !Name !Name !Loc
  | -- | @patch <patch-id> { <items> }@ — guard items behind a durable patch.
    WfPatch !Name ![WfBodyItem] !Loc
  | -- | @continueAsNew <SeedType>@ — rotate after the terminal top-level item.
    WfContinueAsNew !Name !Loc
  deriving stock (Eq, Show, Generic)

-- | A durable @workflow@ node.
data WorkflowNode = WorkflowNode
  { -- | block identifier (e.g. @HospitalTransferReservation@)
    id :: !Name,
    -- | the stable @name "…"@ (journal stream + every deterministic id)
    stable :: !Text,
    input :: !Name,
    inputFields :: ![Field],
    output :: !Name,
    -- | @id from input.<field>@; 'Nothing' for @id from input@
    idField :: !(Maybe Name),
    idVia :: !Name,
    body :: ![WfBodyItem],
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

workflowNodeLoc :: WorkflowNode -> Loc
workflowNodeLoc WorkflowNode {loc = loc} = loc

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
  { name :: !Name,
    shape :: !OperationShape,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A top-level node. EP-1 defines 'NAggregate'; EP-3 adds 'NProcess'; EP-4 adds
-- 'NContract'\/'NIntake'\/'NEmit'\/'NPublisher'; EP-5 adds 'NWorkqueue'\/
-- 'NPgmqDispatch'; EP-6 adds 'NWorkflow'\/'NOperation'; EP-107 adds
-- 'NReadModel'.
data Node
  = NAggregate Aggregate
  | NProcess ProcessNode
  | NRouter RouterNode
  | NContract ContractNode
  | NIntake IntakeNode
  | NEmit EmitNode
  | NPublisher PublisherNode
  | NWorkqueue WorkqueueNode
  | NPgmqDispatch PgmqDispatchNode
  | NReadModel ReadModelNode
  | NProjectionTarget ProjectionTargetNode
  | NRebuildGroup RebuildGroupNode
  | NProjectionRevision ProjectionRevisionNode
  | NExternalRead ExternalReadNode
  | NProjectionOwner ProjectionOwnerNode
  | NWorkflow WorkflowNode
  | NOperation OperationNode
  deriving stock (Eq, Show, Generic)

-- | The module-placement style for a scaffolded service. 'GeneratedPrefix' is
-- the historical default — @\<root\>.Generated.\<Ctx\>.\<Node\>@ for the generated
-- layer, holes at @\<root\>.\<Ctx\>.\<Node\>@. 'CollocatedLeaf' places the
-- generated layer as a leaf under the domain — @\<root\>.\<Ctx\>.\<Node\>.Generated@
-- — so it sits next to hand-written domain code (holes still at
-- @\<root\>.\<Ctx\>.\<Node\>@). Defined here (not in "Keiro.Dsl.Scaffold") so the
-- 'Spec' AST can carry an author's standing choice; 'Keiro.Dsl.Scaffold'
-- re-exports it.
data Placement
  = GeneratedPrefix
  | CollocatedLeaf
  deriving stock (Eq, Show, Generic)

-- | A whole @.keiro@ file: one context name, an optional module-placement
-- override (the @module@/@layout@ clauses), the shared id/enum/rule/mapped declarations,
-- and the list of nodes. 'specModuleRoot' and 'specLayout' are 'Nothing' when the
-- spec omits the clauses, reproducing the historical default.
data Spec = Spec
  { context :: !Name,
    moduleRoot :: !(Maybe Text),
    layout :: !(Maybe Placement),
    ids :: ![IdDecl],
    enums :: ![EnumDecl],
    rules :: ![RuleDecl],
    nominalScalars :: ![NominalScalarDecl],
    mapped :: ![MappedDecl],
    nodes :: ![Node]
  }
  deriving stock (Eq, Show, Generic)
