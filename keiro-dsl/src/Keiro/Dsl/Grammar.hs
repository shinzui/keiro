{- | The abstract syntax of the keiro DSL (@.kdsl@) — the shared engine type that
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
    Transition (..),
    WireSpec (..),
    ProjectionSpec (..),
    Consistency (..),
    Aggregate (..),

    -- * Top level
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

-- | @event Name { … }@ or @event Name = fields(Command)@.
data Event = Event
    { evName :: !Name
    , evBody :: !EventBody
    , evLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

data EventBody
    = EventFields ![Field]
    | EventFromCommand !Name
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
    , projStatusMap :: !Mapping
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

{- | A top-level node. Only 'NAggregate' exists in EP-1; EP-3…EP-6 add
@NProcess@, @NTimer@, @NIntake@, @NWorkqueue@, @NWorkflow@, etc.
-}
newtype Node = NAggregate Aggregate
    deriving stock (Eq, Show, Generic)

{- | A whole @.kdsl@ file: one context name, the shared id/enum/rule
declarations, and the list of nodes.
-}
data Spec = Spec
    { specContext :: !Name
    , specIds :: ![IdDecl]
    , specEnums :: ![EnumDecl]
    , specRules :: ![RuleDecl]
    , specNodes :: ![Node]
    }
    deriving stock (Eq, Show, Generic)
