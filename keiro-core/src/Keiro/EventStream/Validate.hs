{- | Replay-safety validation for keiro 'EventStream's.

An 'EventStream' pairs a pure keiki 'SymTransducer' with the durable plumbing
needed to replay it. keiki can prove, with no SMT solver, that a transducer is
/replay-safe/ — every command field an edge consumes is recoverable from the
event(s) it emits — and additionally that its guards are deterministic and that
no edge is statically dead. This module lifts keiki's umbrella check
('Keiki.validateTransducer') to the 'EventStream' boundary so a service can
assert all of its streams are sound before they are ever hydrated.

* 'validateEventStream' \/ 'validateEventStreamWith' run the pure check and
  return labelled warnings (empty when the stream is sound).
* 'mkEventStream' is a fail-fast smart constructor: it returns @Left warnings@
  for an unsafe stream and @Right validatedStream@ for a sound one. The returned
  'ValidatedEventStream' is the value command runners accept; the bare
  'EventStream' record literal remains available only for construction,
  validation, and low-level internals.
-}
module Keiro.EventStream.Validate (
    EventStreamWarning (..),
    ValidatedEventStream,
    unvalidated,
    validateEventStream,
    validateEventStreamWith,
    mkEventStream,
    mkEventStreamWith,
    mkEventStreamOrThrow,
) where

import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Stack (HasCallStack)
import Keiki.Core (
    EdgeRef (..),
    HsPred,
    TransducerValidationWarning (..),
    ValidationOptions,
    defaultValidationOptions,
    validateTransducer,
 )
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))

{- | A validation warning about one event stream, tagged with the
caller-supplied label so a multi-aggregate service can tell which stream is at
fault.
-}
data EventStreamWarning = EventStreamWarning
    { eswStreamLabel :: !Text
    , eswReason :: !Text
    -- ^ rendered from the keiki warning
    }
    deriving stock (Eq, Show)

{- | An 'EventStream' that has passed keiki validation and keiro's stream-level
checks. Command runners require this wrapper instead of a bare 'EventStream'.
The constructor is intentionally not exported; use 'mkEventStream',
'mkEventStreamWith', or 'mkEventStreamOrThrow' to obtain a value.
-}
newtype ValidatedEventStream phi rs s ci co
    = ValidatedEventStream (EventStream phi rs s ci co)

-- | Recover the underlying stream for internal runners and low-level helpers.
unvalidated :: ValidatedEventStream phi rs s ci co -> EventStream phi rs s ci co
unvalidated (ValidatedEventStream es) = es

{- | Run keiki's pure umbrella check (hidden-input + determinism + dead-edge)
over a stream's transducer with the default options. An empty list means the
stream passed every enabled check. Pure; no solver.
-}
validateEventStream ::
    (Bounded s, Enum s, Ord s, Show s) =>
    -- | caller-supplied stream label
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    [EventStreamWarning]
validateEventStream = validateEventStreamWith defaultValidationOptions

{- | As 'validateEventStream', but with caller-chosen 'ValidationOptions' (e.g.
to narrow the checks for a stream with a known-benign warning).
-}
validateEventStreamWith ::
    (Bounded s, Enum s, Ord s, Show s) =>
    ValidationOptions ->
    -- | caller-supplied stream label
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    [EventStreamWarning]
validateEventStreamWith opts label es =
    snapshotWarnings label es
        <> [ EventStreamWarning{eswStreamLabel = label, eswReason = renderWarning w}
           | w <- validateTransducer opts (transducer es)
           ]

{- | Build a validated event stream with the default validation options.
Returns the warnings (@Left@) for an unsafe stream, or a
'ValidatedEventStream' (@Right@) when it passes.
-}
mkEventStream ::
    (Bounded s, Enum s, Ord s, Show s) =>
    -- | caller-supplied stream label
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    Either [EventStreamWarning] (ValidatedEventStream (HsPred rs ci) rs s ci co)
mkEventStream = mkEventStreamWith defaultValidationOptions

{- | Build a validated event stream with caller-chosen validation options.
Only narrow options for documented, benign non-hidden-input warnings; disabling
the hidden-input check weakens replay safety.
-}
mkEventStreamWith ::
    (Bounded s, Enum s, Ord s, Show s) =>
    ValidationOptions ->
    -- | caller-supplied stream label
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    Either [EventStreamWarning] (ValidatedEventStream (HsPred rs ci) rs s ci co)
mkEventStreamWith opts label es =
    case validateEventStreamWith opts label es of
        [] -> Right (ValidatedEventStream es)
        warns -> Left warns

{- | Partial constructor for generated code and test fixtures that have a
sibling validation proof. Hand-authored application wiring should prefer
'mkEventStream' and handle @Left@ explicitly.
-}
mkEventStreamOrThrow ::
    (HasCallStack, Bounded s, Enum s, Ord s, Show s) =>
    -- | caller-supplied stream label
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    ValidatedEventStream (HsPred rs ci) rs s ci co
mkEventStreamOrThrow label es =
    case mkEventStream label es of
        Right validated -> validated
        Left warns ->
            error $
                "Keiro.EventStream.Validate.mkEventStreamOrThrow: "
                    <> Text.unpack label
                    <> " is not replay-safe: "
                    <> show warns

{- | Render a keiki warning to a human-readable reason. All four constructors
carry @tvwDetail@; the source vertex is @edgeSource . tvwEdge@ (or @tvwSource@
for the nondeterministic pair).
-}
renderWarning :: (Show s) => TransducerValidationWarning s -> Text
renderWarning w = case w of
    HiddenInput{tvwEdge = e, tvwDetail = d} ->
        "hidden-input @" <> showT (edgeSource e) <> ": " <> Text.pack d
    NondeterministicPair{tvwSource = s, tvwDetail = d} ->
        "nondeterministic @" <> showT s <> ": " <> Text.pack d
    PossiblyDeadEdge{tvwEdge = e, tvwDetail = d} ->
        "possibly-dead @" <> showT (edgeSource e) <> ": " <> Text.pack d
    OpaqueGuard{tvwEdge = e, tvwDetail = d} ->
        "opaque-guard @" <> showT (edgeSource e) <> ": " <> Text.pack d
  where
    showT = Text.pack . show

snapshotWarnings :: Text -> EventStream phi rs s ci co -> [EventStreamWarning]
snapshotWarnings label es =
    case (snapshotPolicy es, stateCodec es) of
        (Never, _) -> []
        (_, Just _) -> []
        (_, Nothing) ->
            [ EventStreamWarning
                { eswStreamLabel = label
                , eswReason = "snapshotPolicy is set but stateCodec is Nothing; snapshots would never be written"
                }
            ]
