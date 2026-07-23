{- | Replay-safety validation for keiro 'EventStream's.

An 'EventStream' pairs a pure keiki 'SymTransducer' with the durable plumbing
needed to replay it. keiki can prove, with no SMT solver, that a transducer is
/replay-safe/ — each emitted chain is recoverable from its first event, observed
events invert to one edge, input reads are guarded by the matching command
constructor, and output-free edges do not change durable state. The umbrella
also checks guard determinism and structural reachability. This module lifts
keiki's umbrella check ('Keiki.validateTransducer') to the 'EventStream'
boundary so a service can assert all of its streams are sound before hydration.
The boundary also validates the event 'Keiro.Codec.Codec' construction
invariants, so malformed schema versions, duplicate event tags or upcaster
sources, out-of-range rungs, and incomplete chains fail before the service
touches stored streams.

Every warning enabled by the selected 'ValidationOptions' makes construction
fail. This is intentionally stricter than a pure keiki use: events are keiro's
only durable state, so accepting an unreplayable shape would lose state or defer
the failure to production. Build custom options by updating
'defaultValidationOptions'. The replay-contract checks for head recoverability
and state-changing output-free edges are always forced on at this durable
boundary; caller-supplied options may only strengthen that contract.

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

    -- * Unchecked escape hatch (tests and emergency forensics only)
    mkEventStreamUnchecked,
) where

import Control.DeepSeq (force)
import Control.Exception (ErrorCall, displayException, evaluate, try)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Stack (HasCallStack)
import Keiki.Core (
    EdgeRef (..),
    HsPred,
    TransducerValidationWarning (..),
    ValidationOptions (..),
    defaultValidationOptions,
    validateTransducer,
 )
import Keiro.Codec qualified as Codec
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..), StateCodec (..))
import System.IO.Unsafe (unsafePerformIO)

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
'mkEventStreamWith', or 'mkEventStreamOrThrow' to obtain a validated value.
'mkEventStreamUnchecked' exists only for tests and emergency forensics.
-}
newtype ValidatedEventStream phi rs s ci co
    = ValidatedEventStream (EventStream phi rs s ci co)

-- | Recover the underlying stream for internal runners and low-level helpers.
unvalidated :: ValidatedEventStream phi rs s ci co -> EventStream phi rs s ci co
unvalidated (ValidatedEventStream es) = es

{- | Run keiki's pure umbrella check over a stream's transducer with the default
options. This includes hidden-input, head recoverability, inversion ambiguity,
guarded input reads, state-changing epsilon edges, determinism, and dead-edge
checks, plus the event codec's schema and upcaster-chain construction
invariants. An empty list means the stream passed every enabled check. Pure;
no solver.
-}
validateEventStream ::
    (Bounded s, Enum s, Ord s, Show s) =>
    -- | caller-supplied stream label
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    [EventStreamWarning]
validateEventStream = validateEventStreamWith defaultValidationOptions

{- | As 'validateEventStream', but with caller-chosen 'ValidationOptions'.
The head-recoverability and state-changing-epsilon checks are always forced on:
events are keiro's only durable state, so callers may narrow only checks with a
documented benign override.
-}
validateEventStreamWith ::
    (Bounded s, Enum s, Ord s, Show s) =>
    ValidationOptions ->
    -- | caller-supplied stream label
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    [EventStreamWarning]
validateEventStreamWith opts label es =
    codecConfigWarnings label es
        <> snapshotWarnings label es
        <> initialSnapshotEncodeWarnings label es
        <> [ EventStreamWarning{eswStreamLabel = label, eswReason = renderWarning w}
           | w <- validateTransducer (forceReplayContract opts) (transducer es)
           ]

-- | Force the replay-contract checks required at keiro's durable boundary.
forceReplayContract :: ValidationOptions -> ValidationOptions
forceReplayContract opts =
    opts
        { checkStateChangingEpsilon = True
        , checkHeadRecoverability = True
        }

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
The replay-contract checks for head recoverability and state-changing epsilon
edges cannot be disabled here: caller options may only strengthen the durable
boundary. Only narrow other checks for a documented benign warning.
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

{- | Wrap an 'EventStream' /without validation/. This skips every keiki and
keiro check, including event-codec construction validation and the
replay-contract checks that 'mkEventStream' force-enables. A stream admitted
through this function can silently lose state changes, select the wrong
upcaster, or fail hydration. Tests and emergency forensics only; never use it
for production streams. Prefer 'mkEventStream'.
-}
mkEventStreamUnchecked ::
    EventStream phi rs s ci co ->
    ValidatedEventStream phi rs s ci co
mkEventStreamUnchecked = ValidatedEventStream

codecConfigWarnings :: Text -> EventStream phi rs s ci co -> [EventStreamWarning]
codecConfigWarnings label es =
    case Codec.mkCodec (eventCodec es) of
        Right _ -> []
        Left err ->
            [ EventStreamWarning
                { eswStreamLabel = label
                , eswReason = "event codec misconfigured: " <> renderCodecConfigError err
                }
            ]

renderCodecConfigError :: Codec.CodecConfigError -> Text
renderCodecConfigError = \case
    Codec.CodecSchemaVersionInvalid version ->
        "schema version must be at least 1, got " <> showT version
    Codec.CodecDuplicateEventTypes eventTypes ->
        "duplicate event type tag(s): "
            <> Text.intercalate ", " [tag | Codec.EventType tag <- eventTypes]
    Codec.CodecDuplicateUpcasterSources versions ->
        "duplicate upcaster source version(s): "
            <> renderVersions versions
            <> "; only one rung may own each source version"
    Codec.CodecUpcasterSourceOutOfRange source target ->
        "upcaster source version "
            <> showT source
            <> " is outside the valid range 1.."
            <> showT (target - 1)
            <> " for target schema version "
            <> showT target
    Codec.CodecUpcasterChainIncomplete missing target ->
        "missing upcaster source version(s): "
            <> renderVersions missing
            <> "; stored payloads cannot reach target schema version "
            <> showT target
  where
    showT = Text.pack . show
    renderVersions = Text.intercalate ", " . map showT

{- | Render a keiki warning to a human-readable reason. All eight constructors
carry @tvwDetail@; the source vertex is @edgeSource . tvwEdge@ (or @tvwSource@
for pair warnings).
-}
renderWarning :: (Show s) => TransducerValidationWarning s -> Text
renderWarning w = case w of
    HiddenInput{tvwEdge = e, tvwDetail = d} ->
        "hidden-input @" <> showT (edgeSource e) <> ": " <> Text.pack d
    HeadUnrecoverable{tvwEdge = e, tvwDetail = d} ->
        "head-unrecoverable @" <> showT (edgeSource e) <> ": " <> Text.pack d
    InversionAmbiguity{tvwSource = s, tvwDetail = d} ->
        "inversion-ambiguity @" <> showT s <> ": " <> Text.pack d
    UnguardedInputRead{tvwEdge = e, tvwDetail = d} ->
        "unguarded-input-read @" <> showT (edgeSource e) <> ": " <> Text.pack d
    StateChangingEpsilon{tvwEdge = e, tvwDetail = d} ->
        "state-changing-epsilon @" <> showT (edgeSource e) <> ": " <> Text.pack d
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

{- | Force the configured codec over the initial aggregate state while the
stream is being validated. This catches the labelled @uninit: <slot>@
'ErrorCall' thunks installed by 'Keiki.Generics.emptyRegFile' before a service
can accept commands for a snapshot-enabled stream.

The public validation API remains pure; this narrowly scoped exception spoon
observes only 'ErrorCall'. Any other exception remains a programmer-visible
failure instead of being converted into a warning.
-}
initialSnapshotEncodeWarnings :: Text -> EventStream phi rs s ci co -> [EventStreamWarning]
initialSnapshotEncodeWarnings label es =
    case stateCodec es of
        Nothing -> []
        Just codec -> unsafePerformIO $ do
            encoded <- try @ErrorCall (evaluate (force (encode codec (initialState es, initialRegisters es))))
            pure $ case encoded of
                Right _ -> []
                Left err ->
                    [ EventStreamWarning
                        { eswStreamLabel = label
                        , eswReason =
                            "stateCodec cannot encode the initial state/registers: "
                                <> Text.pack (displayException err)
                        }
                    ]
