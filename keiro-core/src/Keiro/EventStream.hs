{- | The complete description of one persistent event stream.

An 'EventStream' marries a pure keiki 'SymTransducer' (the decision logic
of a symbolic-register state machine) with everything keiro needs to run
it against a durable event store: where its initial state and registers
come from, how its emitted events are serialized ('Codec'), which physical
stream name to read and write, when to snapshot, and how to serialize that
snapshot. Command handling ("Keiro.Command") hydrates the machine from
stored events (optionally fast-forwarding from a snapshot), steps it with a
command, encodes the resulting events, and appends them. Public command
runners require a 'Keiro.EventStream.Validate.ValidatedEventStream', obtained
from 'Keiro.EventStream.Validate.mkEventStream' or
'Keiro.EventStream.Validate.mkEventStreamOrThrow', rather than a bare record
literal.

The type parameters thread through from the underlying transducer:

* @phi@ — the guard/predicate alphabet the transducer branches on.
* @rs@ — the register set ('RegFile' @rs@ holds the live values).
* @s@ — the control state.
* @ci@ — the command input the machine consumes.
* @co@ — the event output the machine emits (what 'eventCodec' serializes).
-}
module Keiro.EventStream (
    EventStream (..),
    Terminality (..),
    SnapshotPolicy (..),
    StateCodec (..),
)
where

import Keiki.Core (RegFile, SymTransducer)
import Keiro.Codec (Codec)
import Keiro.Prelude
import Keiro.Stream (Stream)
import Kiroku.Store.Types (StreamName, StreamVersion)

{- | A self-contained, persistable event stream definition.

* 'transducer' — the pure keiki state machine that turns a command into
  emitted events.
* 'initialState' \/ 'initialRegisters' — the machine's starting control
  state and register file, used when hydrating an empty stream.
* 'eventCodec' — serializes and migrates the emitted events (@co@) to and
  from stored payloads.
* 'resolveStreamName' — maps a typed 'Stream' handle to the physical
  'StreamName' read and appended to in the store.
* 'snapshotPolicy' — decides, per append, whether to persist a snapshot of
  the @(state, registers)@ pair.
* 'stateCodec' — how to serialize that snapshot. Set 'snapshotPolicy' and
  'stateCodec' coherently; 'Keiro.EventStream.Validate.mkEventStream' rejects
  a snapshotting policy without a state codec and returns the
  'Keiro.EventStream.Validate.ValidatedEventStream' that command runners accept.
-}
data EventStream phi rs s ci co = EventStream
    { transducer :: !(SymTransducer phi rs s ci co)
    , initialState :: !s
    , initialRegisters :: !(RegFile rs)
    , eventCodec :: !(Codec co)
    , resolveStreamName :: !(Stream (EventStream phi rs s ci co) -> StreamName)
    , snapshotPolicy :: !(SnapshotPolicy (s, RegFile rs))
    , stateCodec :: !(Maybe (StateCodec (s, RegFile rs)))
    }
    deriving stock (Generic)

-- | Whether the append that just happened reached a terminal stream state.
data Terminality = Terminal | NotTerminal
    deriving stock (Eq, Show, Generic)

{- | When to persist a snapshot of a stream's folded state.

* 'Never' — never snapshot; always rehydrate from the full event log.
* 'Every' @n@ — snapshot whenever the stream version is a multiple of @n@
  (a non-positive interval disables snapshotting).
* 'OnTerminal' — snapshot only when the machine has reached a final state.
* 'Custom' — an arbitrary predicate over terminality, folded @state@, and
  the current 'StreamVersion'.

See 'Keiro.Snapshot.Policy.shouldSnapshot' for the evaluation rules.
-}
data SnapshotPolicy state
    = Never
    | Every !Int
    | OnTerminal
    | Custom !(Terminality -> state -> StreamVersion -> Bool)
    deriving stock (Generic)

{- | How to serialize and deserialize a stream's snapshot state.

'stateCodecVersion', 'shapeHash', and 'stateShapeHash' together gate snapshot
reuse: a stored snapshot is only loaded when all three match the current
codec, so incompatible encodings, register layouts, and control-state shapes
invalidate older snapshots and force a clean rehydration from events.

* 'stateCodecVersion' — bumped when the snapshot encoding changes
  incompatibly, and whenever fold logic changes in a way the structural hashes
  and any composed fold fingerprint cannot see.
* 'shapeHash' — a digest of the register-file layout.
* 'stateShapeHash' — a digest of the control-state shape, optionally composed
  with a fold fingerprint.
* 'encode' \/ 'decode' — the JSON serialization of the @(state,
  registers)@ pair.

Hand-written guard and update function bodies are not structurally
inspectable. Changing them without also changing a composed fold fingerprint
MUST bump 'stateCodecVersion'; otherwise an old snapshot can still match and
be served as a stale hydration seed.
-}
data StateCodec state = StateCodec
    { stateCodecVersion :: !Int
    , shapeHash :: !Text
    , stateShapeHash :: !Text
    , encode :: !(state -> Value)
    , decode :: !(Value -> Either Text state)
    }
    deriving stock (Generic)
