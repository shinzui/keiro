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
  for an unsafe stream and @Right stream@ for a sound one. The bare
  'EventStream' record literal stays available for low-level callers who do not
  want the check.
-}
module Keiro.EventStream.Validate (
    EventStreamWarning (..),
    validateEventStream,
    validateEventStreamWith,
    mkEventStream,
) where

import Data.Text (Text)
import Data.Text qualified as Text
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

{- | Build a validated 'EventStream'. Returns the warnings (@Left@) for an
unsafe stream, or the stream itself (@Right@) when it passes. The bare record
literal @EventStream { … }@ remains available for low-level callers who do not
want the check.
-}
mkEventStream ::
    (Bounded s, Enum s, Ord s, Show s) =>
    -- | caller-supplied stream label
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    Either [EventStreamWarning] (EventStream (HsPred rs ci) rs s ci co)
mkEventStream label es =
    case validateEventStream label es of
        [] -> Right es
        warns -> Left warns

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
