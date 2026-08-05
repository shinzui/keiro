-- | The abstract syntax of the keiro DSL (@.keiro@) — the shared engine type that
-- every later vertical (EP-2…EP-6) extends additively. EP-1 defines the shared
-- declarations, the 'Expr' sublanguage, the eight hole-kind types, and the
-- 'Aggregate' node. New node families add a 'Node' constructor here in lockstep
-- with their parser, validator, and scaffold cases.
module Keiro.Dsl.Grammar
  ( -- * Names and source locations
    Name,
    Loc (..),
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
    ReadModelNode (..),

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
import GHC.Generics (Generic)

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

instance Eq Loc where
  _ == _ = True

-- | A placeholder location used by generators and pretty-print round-trips.
noLoc :: Loc
noLoc = Loc 0

-- | @id TransferReservationId prefix=rsv@ — declares an id newtype over 'Text'
-- and its prefix tag.
data IdDecl = IdDecl
  { idName :: !Name,
    idPrefix :: !Text,
    idBinding :: !(Maybe NominalBindingDecl),
    idLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @enum PatientAcuity { RedTag=red … }@ — a closed enumeration; each
-- constructor carries its wire spelling (the right-hand side of @=@).
data EnumDecl = EnumDecl
  { enumName :: !Name,
    enumCtors :: ![(Name, Text)],
    enumBinding :: !(Maybe NominalBindingDecl),
    enumLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @rule lifeCriticalOverride : PatientAcuity -> Bool@ with an @ex@ line of
-- @Ctor => bool ; …@ — a total function from an enum to a value, used as a
-- derived atom inside guards.
data RuleDecl = RuleDecl
  { ruleName :: !Name,
    ruleDomain :: !Name,
    ruleCodomain :: !Name,
    ruleCases :: ![(Name, Expr)],
    ruleLoc :: !Loc
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
  { wfHaskell :: !Name,
    wfKey :: !Text,
    wfType :: !TypeExpr,
    wfPresence :: !Presence,
    wfOnMissing :: !(Maybe OnMissing),
    wfLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

wireFieldLoc :: WireField -> Loc
wireFieldLoc WireField {wfLoc = loc} = loc

data UnionEncoding = TaggedObject
  { ueTagField :: !Text,
    ueContentsField :: !Text,
    ueUnknownFields :: !UnknownFields
  }
  deriving stock (Eq, Show, Generic)

data WireEnum = WireEnum
  { weCtor :: !Name,
    weTag :: !Text,
    weLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data WireArm = WireArm
  { waCtor :: !Name,
    waTag :: !Text,
    waPayload :: !(Maybe TypeExpr),
    waLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data MappedShape
  = ShapeRecord !Name !UnknownFields ![WireField]
  | ShapeEnum ![WireEnum]
  | ShapeUnion !UnionEncoding ![WireArm]
  deriving stock (Eq, Show, Generic)

data HaskellSource = HaskellSource
  { hsPackage :: !Text,
    hsModule :: !Text,
    hsType :: !Name
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Parser-facing facts for a total consumer-owned nominal binding.
--
-- The fields remain optional only so validation can report every missing fact at
-- the owning declaration. Downstream code consumes the checked nominal registry.
data NominalBindingDecl = NominalBindingDecl
  { nominalHaskell :: !(Maybe HaskellSource),
    nominalBinding :: !(Maybe Text),
    nominalBindingVersion :: !(Maybe Text),
    nominalCanonicalType :: !(Maybe Text),
    nominalFixtures :: !(Maybe Text),
    nominalInitial :: !(Maybe Text),
    nominalLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A consumer-owned nominal scalar over one declared representation name.
--
-- The raw representation name is retained so @keiro-dsl check@ owns the stable
-- unsupported-representation diagnostic instead of the low-level parser.
data NominalScalarDecl = NominalScalarDecl
  { nominalScalarName :: !Name,
    nominalScalarRepresentation :: !Name,
    nominalScalarBinding :: !NominalBindingDecl,
    nominalScalarLoc :: !Loc
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
  { mapPairs :: ![(Name, Name)],
    mapPartial :: !Bool
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
  { regName :: !Name,
    regType :: !TypeExpr,
    regInitial :: !RegInitial,
    regLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | One entry in a @states@ list. @stTerminal@ is set when the name carries a
-- trailing @!@ (no outgoing transitions allowed). The first 'StateDecl' in an
-- aggregate's list is its initial state.
data StateDecl = StateDecl
  { stName :: !Name,
    stTerminal :: !Bool,
    stLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | An aggregate command/event field. The logical DSL name remains the identity
-- used by expressions and evolution pairing. Optional aliases independently
-- select the generated Haskell record selector and serialized wire key.
-- A bare name reuses the field's inferred aggregate type; @name:Type@ accepts
-- the complete 'TypeExpr' grammar so semantic validation can reject unsupported
-- direct shapes with a located diagnostic.
data AggregateField = AggregateField
  { aggregateFieldName :: !Name,
    aggregateFieldSelector :: !(Maybe Name),
    aggregateFieldWireKey :: !(Maybe Text),
    aggregateFieldType :: !(Maybe TypeExpr),
    aggregateFieldLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A generic field used by process and router nodes. Aggregate fields are
-- kept separate so widening aggregate syntax does not widen those node families.
data Field = Field
  { fieldName :: !Name,
    fieldType :: !(Maybe Name)
  }
  deriving stock (Eq, Show, Generic)

-- | @command Name { field … }@ — a command constructor.
data Command = Command
  { cmdName :: !Name,
    cmdFields :: ![AggregateField],
    cmdLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @event Name { … }@ or @event Name = fields(Command)@. EP-2 (evolution) adds
-- the version/upcaster/retirement fields: an unversioned event is @evVersion = 1@,
-- @evUpcastFrom = Nothing@, @evRetiring = False@, and @evDeprecated = False@,
-- reproducing the EP-1 surface. These fields live on the shared 'Event' so every
-- node family's events inherit schema-versioning for free.
data Event = Event
  { evName :: !Name,
    evBody :: !EventBody,
    -- | The schema version of this event shape. Default 1; written @vN@ for N>1.
    evVersion :: !Int,
    -- | The source version this shape migrates /from/, paired with the upcaster
    --     hole. @Just (n-1, …)@ for a @vN@ shape; 'Nothing' for v1.
    evUpcastFrom :: !(Maybe (Int, Hole)),
    -- | Retirement is in progress. The event must keep at least one live
    --     emitting transition while operators terminalize or truncate affected
    --     streams; cut over to @deprecated@ plus a replay-only emitting transition
    --     afterwards.
    evRetiring :: !Bool,
    -- | Retired from the write path (no live transition may @emit@ it) but
    --     still decodable from the log. A replay-only emitting transition must remain
    --     while live streams can still contain the event.
    evDeprecated :: !Bool,
    evLoc :: !Loc
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

-- | A transition @Src -- Command --> clauses@. Clauses may be written
-- indentation-stacked or @;@-separated on one line.
data Transition = Transition
  { tSource :: !Name,
    tCommand :: !Name,
    tImplementation :: !TransitionImplementation,
    tGuard :: !(Maybe Expr),
    tWrites :: ![(Name, Expr)],
    tEmits :: ![Name],
    tGoto :: !Name,
    tMode :: !TransitionMode,
    tLoc :: !Loc
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
  { wireKind :: !Text,
    wireFields :: !Text,
    wireSchemaVersion :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | @projection table consistency=… key=… status-map { … }@ — the read-model
-- projection and its event→status 'Mapping' (hole-kind 3).
data ProjectionSpec = ProjectionSpec
  { projTable :: !Name,
    projConsistency :: !(Maybe Consistency),
    projKey :: !Name,
    projStatusMap :: !(Maybe Mapping),
    projLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data Consistency = Strong | Eventual
  deriving stock (Eq, Show, Generic)

-- | A generated aggregate snapshot policy supported by the notation.
data SnapPolicy = SnapEvery !Int | SnapOnTerminal
  deriving stock (Eq, Show, Generic)

-- | Snapshot policy plus the captured live state-codec identity.
data SnapshotSpec = SnapshotSpec
  { snapPolicy :: !SnapPolicy,
    snapCodecVersion :: !Int,
    snapShapeHash :: !Text,
    snapLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | An @aggregate@ node: a consistency boundary whose state is rebuilt by
-- replaying events.
data Aggregate = Aggregate
  { aggName :: !Name,
    aggRegs :: ![RegDecl],
    aggStates :: ![StateDecl],
    aggCommands :: ![Command],
    aggEvents :: ![Event],
    aggTransitions :: ![Transition],
    aggWire :: !(Maybe WireSpec),
    aggProjection :: !(Maybe ProjectionSpec),
    aggSnapshot :: !(Maybe SnapshotSpec),
    aggLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-3: process manager + durable timer nodes.

-- | A @field@ or @field=value@ binding inside a command\/payload field list.
-- A bare field reuses the input field of the same name; @name=value@ binds it to
-- an expression (kept as raw text, e.g. @timerId=timer.id@).
data FieldBinding = FieldBinding
  { fbName :: !Name,
    fbValue :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | @input SurgeInput { hospitalId … observedAt:Time }@ — the process's incoming
-- event shape (one field must be a @:Time@ field used by the timer deadline).
data InputDecl = InputDecl
  { inName :: !Name,
    inFields :: ![Field]
  }
  deriving stock (Eq, Show, Generic)

-- | @correlate input.hospitalId via idText@ — the correlation key (hole-kind 1
-- derivation + hole-kind 4 field-source).
data CorrelateDecl = CorrelateDecl
  { corrField :: !Name,
    corrVia :: !Name
  }
  deriving stock (Eq, Show, Generic)

-- | @saga Surge category \"hospitalSurge\"@ — the saga's own aggregate plus
-- the validated stream category used with @Keiro.Stream.entityStream@.  For a
-- correlation id @c@, the saga stream is @<category>-<c>@.
data SagaRef = SagaRef
  { sagaAgg :: !Name,
    sagaCategory :: !Text
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
  { dispTarget :: !Name,
    dispKey :: !Text,
    dispCommand :: !Name,
    dispFields :: ![FieldBinding],
    dispDisposition :: !DispatchDisposition,
    dispLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | The @on <Input>@ reaction: a self-advance, zero or more dispatches, and a
-- @schedule@ of the timer.
data HandleNode = HandleNode
  { hOn :: !Name,
    hAdvance :: !AdvanceNode,
    hDispatch :: ![DispatchNode],
    hSchedule :: !Name
  }
  deriving stock (Eq, Show, Generic)

-- | A deterministic id derivation: @uuidv5 \"prefix:\" <> correlationId@.
data IdExpr = IdExpr
  { ideStrategy :: !IdStrategy,
    idePrefix :: !Text
  }
  deriving stock (Eq, Show, Generic)

data IdStrategy = UuidV5Id
  deriving stock (Eq, Show, Generic)

-- | @fireAt input.observedAt + 5m@ — an injected timestamp field plus a window.
-- There is no clock-sampling constructor, so the no-wall-clock rule holds by
-- construction.
data FireAtExpr = FireAtExpr
  { faField :: !Name,
    faWindow :: !Text
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
  { fireTarget :: !Name,
    fireKey :: !Text,
    fireCommand :: !Name,
    fireFields :: ![FieldBinding],
    fireFiredEventId :: !IdExpr,
    fireDisposition :: !FireDisposition
  }
  deriving stock (Eq, Show, Generic)

-- | A nested @timer@ sub-node of a process.
data TimerNode = TimerNode
  { tmName :: !Name,
    tmId :: !IdExpr,
    tmFireAt :: !FireAtExpr,
    tmPayload :: ![FieldBinding],
    tmFire :: !FireNode,
    tmDecodeUnknown :: !Name,
    tmMaxAttempts :: !Int,
    tmDeadLetter :: !Text,
    tmLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A node-level worker policy lowered to the runtime worker options.
data PolicyChoice = PolHalt | PolDeadLetter | PolSkip
  deriving stock (Eq, Show, Generic)

-- | A @process@ (process manager / saga) node. The dispatch-id strategy is fixed
-- (runtime-owned uuidv5), so it is implicit in the AST and always rendered.
data ProcessNode = ProcessNode
  { -- | The block identifier (@process HospitalSurge@), used for module names.
    procId :: !Name,
    -- | The define-once ProcessManager @name@ (@name \"hospital-surge\"@).
    procName :: !Text,
    procInput :: !InputDecl,
    procCorrelate :: !CorrelateDecl,
    procSaga :: !SagaRef,
    procTarget :: !Name,
    procProjections :: ![Name],
    procHandle :: !HandleNode,
    procRejected :: !PolicyChoice,
    procPoison :: !PolicyChoice,
    procTimer :: !TimerNode,
    procLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-108: stateless, effectful content-based routing.

data ResolveSource = ResolveReadModel !Name | ResolveHole
  deriving stock (Eq, Show, Generic)

data ResolveDecl = ResolveDecl
  { rvSource :: !ResolveSource,
    rvRow :: ![Name],
    rvLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data RouterDispatchNode = RouterDispatchNode
  { rdCommand :: !Name,
    rdFields :: ![FieldBinding],
    rdDisposition :: !DispatchDisposition,
    rdLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A stateless router. Its fixed dispatch-id strategy is runtime-owned, and
-- the mandatory @stable@ token on the resolve clause is an author acknowledgement
-- that retry attempts accumulate the union of resolved target identities.
data RouterNode = RouterNode
  { rtId :: !Name,
    rtName :: !Text,
    rtInput :: !InputDecl,
    rtKey :: !CorrelateDecl,
    rtResolve :: !ResolveDecl,
    rtTarget :: !Name,
    rtProjections :: ![Name],
    rtDispatch :: !RouterDispatchNode,
    rtRejected :: !PolicyChoice,
    rtPoison :: !PolicyChoice,
    rtLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-4: the cross-service @contract@ (shared Kafka message schema, define-once).

-- | A contract field type: @typeid \"inc\"@, @text@, or @int@.
data ContractType = CTypeId !Text | CText | CInt
  deriving stock (Eq, Show, Generic)

data ContractField = ContractField
  { cfName :: !Name,
    cfSelector :: !(Maybe Name),
    cfWireKey :: !(Maybe Text),
    cfType :: !ContractType,
    cfLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @event <Name> on <topicAlias> { field: type … }@ within a contract.
data ContractEvent = ContractEvent
  { ceName :: !Name,
    ceTopic :: !Name,
    ceFields :: ![ContractField]
  }
  deriving stock (Eq, Show, Generic)

-- | A @contract@ node: the shared cross-service message schema, declared once
-- and referenced by both producer (@emit@) and consumer (@intake@). EP-5's
-- pgmq @dispatch@ also couples to it.
data ContractNode = ContractNode
  { ctrName :: !Name,
    ctrSchemaVersion :: !Int,
    ctrDiscriminator :: !Name,
    -- | (topic alias, real Kafka topic string)
    ctrTopics :: ![(Name, Text)],
    ctrEvents :: ![ContractEvent],
    ctrLoc :: !Loc
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
  { brField :: !Name,
    brSource :: !WireSource,
    brRequired :: !Bool,
    brCrossCheck :: !Bool
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
  { drOutcome :: !Name,
    drAction :: !InboxAction,
    drLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | The body decode-strictness decision (hole-kind 6).
data DecodeSpec = DecodeSpec
  { -- | the envelope policy text, e.g. @strict-required lenient-optional@
    decEnvelope :: !Text,
    decBodyStrict :: !Bool,
    decBodySchemaVersion :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | How much of a successfully processed envelope the inbox retains.
data InkPersist = InkPersistFull | InkPersistDedupeOnly
  deriving stock (Eq, Show, Generic)

-- | An @intake@ (Kafka consumer / inbox) node. The runtime-config @consumer@
-- block (brokers/groupId/offsetReset) is hole-kind 8, delegated to deployment
-- and not modelled here.
data IntakeNode = IntakeNode
  { inkName :: !Name,
    inkContract :: !Name,
    inkTopic :: !Name,
    inkAccept :: ![Name],
    inkBinds :: ![BindRow],
    inkDedupeKey :: !Name,
    inkDedupePolicy :: !Name,
    inkPersist :: !InkPersist,
    inkDecode :: !DecodeSpec,
    inkDisposition :: ![DispositionRow],
    inkLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-4: the @emit@ (outbox mapping) and @publisher@ nodes.

-- | A deterministic id derivation hole: @derive [\"prefix\"] hole@.
newtype DeriveSpec = DeriveSpec {dsPrefix :: Maybe Text}
  deriving stock (Eq, Show, Generic)

-- | One @\"value\" => EventType@ row of an emit's status mapping.
data EmitMapRow = EmitMapRow
  { emrValue :: !Text,
    emrEvent :: !Name,
    emrLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | An @emit@ (outbox) node: maps a private status discriminant to contract
-- event types, with a mandatory explicit @_ => skip@ catch-all.
data EmitNode = EmitNode
  { emName :: !Name,
    emContract :: !Name,
    emTopic :: !Name,
    emSource :: !Text,
    emKey :: !Name,
    emDiscriminant :: !Name,
    emMap :: ![EmitMapRow],
    -- | whether the explicit @_ => skip@ catch-all is present
    emSkip :: !Bool,
    emMessageId :: !DeriveSpec,
    emIdempotencyKey :: !DeriveSpec,
    emLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | @backoff <kind> <window>@, e.g. @backoff constant 2s@.
data BackoffSpec = BackoffSpec
  { boKind :: !Name,
    boWindow :: !Text,
    boMax :: !(Maybe Text),
    boMultiplier :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | A @publisher@ node: the at-least-once publishing policy for an emit's topic.
data PublisherNode = PublisherNode
  { pubName :: !Name,
    pubEmit :: !Name,
    pubOrdering :: !Name,
    pubMaxAttempts :: !Int,
    pubBackoff :: !BackoffSpec,
    -- | @outboxId stable from <field>@: retries coalesce on (source, this field)
    pubOutboxField :: !Name,
    pubLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- EP-5: the pgmq @workqueue@ + @dispatch@ nodes.

-- | One @field -> \"wire_name\" type required@ row of a workqueue payload.
data WqField = WqField
  { wqfName :: !Name,
    wqfWire :: !Text,
    wqfType :: !Name,
    wqfRequired :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | One row of a workqueue's consumer @JobOutcome@ disposition (reusing
-- 'InboxAction': @retry <window>@ \/ @deadLetter@).
data WqDispRow = WqDispRow
  { wqdOutcome :: !Name,
    wqdAction :: !InboxAction,
    wqdLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | The queue's semantic delivery-order contract.
data WqOrdering = WqUnordered | WqFifoThroughput | WqFifoRoundRobin
  deriving stock (Eq, Show, Generic)

-- | A FIFO message-group key derived from one payload field.
data WqGroupKey = WqGroupKey
  { gkField :: !Name,
    gkVia :: !Name,
    gkFixture :: !(Maybe Text)
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
  { wqName :: !Name,
    wqLogical :: !Text,
    wqPhysical :: !Text,
    wqDlq :: !Text,
    wqTable :: !Text,
    wqOrdering :: !WqOrdering,
    wqGroupKey :: !(Maybe WqGroupKey),
    wqProvision :: !WqProvision,
    wqPayloadName :: !Name,
    wqPayload :: ![WqField],
    wqMaxRetries :: !Int,
    wqDelay :: !Text,
    wqDlqOn :: !Bool,
    wqDisposition :: ![WqDispRow],
    wqLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

-- | A pgmq @dispatch@ node: a read-model→enqueue coupling with a fan-out hole
-- and a dedup check (one arm of which is a raw-SQL hole).
data PgmqDispatchNode = PgmqDispatchNode
  { pdName :: !Name,
    pdSourceReadModel :: !Name,
    pdSourceKey :: !Name,
    pdFanoutBody :: !Name,
    pdDedupKey :: !Name,
    pdDedupReadModel :: !Name,
    pdDedupReadModelField :: !Text,
    pdDedupQueue :: !Name,
    pdDedupQueueField :: !Text,
    pdEnqueueTo :: !Name,
    pdLoc :: !Loc
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

-- | A registered, versioned SQL read model. Columns define its shape identity;
-- the runtime table remains owned by codd migrations rather than the DSL.
data ReadModelNode = ReadModelNode
  { rmName :: !Name,
    rmTable :: !Text,
    rmSchema :: !Text,
    rmColumns :: ![RmColumn],
    rmVersion :: !Int,
    rmShape :: !Text,
    rmConsistency :: !Consistency,
    rmScope :: !(Maybe RmScope),
    rmFeed :: !RmFeed,
    rmSubscription :: !(Maybe Text),
    rmLoc :: !Loc
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
    wfId :: !Name,
    -- | the stable @name "…"@ (journal stream + every deterministic id)
    wfStable :: !Text,
    wfInput :: !Name,
    wfInputFields :: ![Field],
    wfOutput :: !Name,
    -- | @id from input.<field>@; 'Nothing' for @id from input@
    wfIdField :: !(Maybe Name),
    wfIdVia :: !Name,
    wfBody :: ![WfBodyItem],
    wfLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

workflowNodeLoc :: WorkflowNode -> Loc
workflowNodeLoc WorkflowNode {wfLoc = loc} = loc

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
  { opName :: !Name,
    opShape :: !OperationShape,
    opLoc :: !Loc
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
  { specContext :: !Name,
    specModuleRoot :: !(Maybe Text),
    specLayout :: !(Maybe Placement),
    specIds :: ![IdDecl],
    specEnums :: ![EnumDecl],
    specRules :: ![RuleDecl],
    specNominalScalars :: ![NominalScalarDecl],
    specMapped :: ![MappedDecl],
    specNodes :: ![Node]
  }
  deriving stock (Eq, Show, Generic)
