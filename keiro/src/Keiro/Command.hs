{- | The command side of the framework: hydrate an aggregate, transduce, append.

Running a command against an 'EventStream' follows one pipeline:

1. /Hydrate/ — replay the stream's stored events (optionally fast-forwarding
   from a snapshot) through the keiki transducer to recover the current
   @(state, registers)@ and stream version.
2. /Transduce/ — step the transducer with the command. A rejected transition
   yields 'CommandRejected', while multiple matching transitions yield
   'CommandAmbiguous'; a transition that emits no events yields a no-op
   'CommandResult'.
3. /Append/ — encode the emitted events with the stream's 'Codec' and append
   them at the expected version. An optimistic-concurrency conflict is
   retried up to 'retryLimit' times by rehydrating and replaying; exhausting
   the budget yields 'RetryExhausted'.

Three runners expose this pipeline at increasing levels of integration:

* 'runCommand' — append only.
* 'runCommandWithSql' — run an extra @afterAppend@ action in the /same/
  transaction as the append (e.g. update an inline read model).
* 'runCommandWithSqlEvents' — same, but the callback also receives the
  emitted events paired with their 'RecordedEvent's. This is the primitive
  the projection, process-manager, and router layers build on.

Every successful append is replayed immediately from its pre-command state so
an unreplayable batch is witnessed at the moment it poisons the stream. The
post-commit witness is counted and attached to the command span without
changing the successful result. The same replay fold feeds transparent
snapshot writes when the stream's 'Keiro.EventStream.SnapshotPolicy' fires;
post-commit snapshot failures are likewise swallowed and counted. Every runner
accepts a tracer for optional OpenTelemetry spans.
-}
module Keiro.Command (
    -- * Results and errors
    CommandResult (..),
    CommandError (..),
    HydrationReplayReason (..),
    commandErrorClass,

    -- * Options
    RunCommandOptions (..),
    defaultRunCommandOptions,

    -- * Running commands
    runCommand,
    runCommandWithSql,
    runCommandWithSqlEvents,
)
where

import Control.Concurrent (threadDelay)
import Data.Functor (($>))
import Data.Int (Int32)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stack (HasCallStack)
import Keiki.Core (BoolAlg, RegFile)
import Keiki.Core qualified as Keiki
import Keiro.Codec (Codec, CodecError, decodeRecorded, encodeForAppendWithMetadata)
import Keiro.EventStream (EventStream, Terminality (..))
import Keiro.EventStream.Validate (ValidatedEventStream, unvalidated)
import Keiro.Prelude
import Keiro.Snapshot (
    SnapshotLookup (..),
    SnapshotMissReason (..),
    encodeSnapshotStrict,
    lookupSnapshotSeed,
    writeSnapshotEncoded,
 )
import Keiro.Snapshot.Policy (shouldSnapshotSpan)
import Keiro.Stream (Stream)
import Keiro.Telemetry (
    KeiroMetrics,
    keiro_events_appended,
    keiro_replay_divergence,
    keiro_retry_attempt,
    recordCommandConflicts,
    recordCommandDuplicates,
    recordCommandRetries,
    recordSnapshotApplyDivergence,
    recordSnapshotDecodeFailures,
    recordSnapshotEncodeFailures,
    recordSnapshotReadHits,
    recordSnapshotReadMisses,
    recordSnapshotWriteFailures,
    withCommandSpan,
 )
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, getKirokuStore)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Read (readStreamForwardStream)
import Kiroku.Store.Transaction (
    PreparedEvent,
    appendConflictToStoreError,
    appendToStreamTx,
    enrichEventsIO,
    prepareEventsIO,
    runTransaction,
 )
import Kiroku.Store.Types (
    AppendResult,
    EventData,
    EventId (..),
    ExpectedVersion (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamName (..),
    StreamVersion (..),
 )
import OpenTelemetry.Attributes.Key (unkey)
import OpenTelemetry.SemanticConventions (db_system_name, error_type)
import OpenTelemetry.Trace.Core (Span, SpanStatus (..), Tracer, addAttribute, setStatus)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

{- | The outcome of a successfully handled command.

Reports the target 'Stream', the stream version after the command, the global
log position only when this command appended and the store assigned a real
one, and how many events were appended. A no-op reports @0@ events and
@Nothing@ for its global position because per-stream reads cannot recover a
true global position.
-}
data CommandResult target = CommandResult
    { target :: !(Stream target)
    , streamVersion :: !StreamVersion
    , globalPosition :: !(Maybe GlobalPosition)
    -- ^ 'Just' only when this command appended; 'Nothing' for a no-op.
    , eventsAppended :: !Int
    }
    deriving stock (Generic, Eq, Show)

-- | Why a command did not complete.
data CommandError
    = -- | A stored event could not be decoded while rehydrating the aggregate.
      HydrationDecodeFailed !CodecError
    | {- | Replay of the stored events through the transducer stalled. The
      version identifies the failing stored event; for
      'HydrationTruncatedChain' it identifies the last stored event, after
      which the expected multi-event chain remained incomplete.
      -}
      HydrationReplayFailed !StreamVersion !HydrationReplayReason
    | {- | Hydration observed a non-contiguous stream version. Carries the
      expected version followed by the observed version. The store writes
      contiguous versions, so this indicates that stream truncation hid
      events not covered by the hydration seed. Restore visibility with
      @clearStreamTruncateBefore@ or provide a covering snapshot before
      retrying the command.
      -}
      HydrationGapDetected !StreamVersion !StreamVersion
    | -- | No transducer edge matched the command in the hydrated state.
      CommandRejected
    | {- | Two or more transducer edges matched the command in the hydrated
      state. This is a deterministic aggregate-definition bug rather than a
      business rejection; the list contains the zero-based matched edge
      indices in declaration order.
      -}
      CommandAmbiguous ![Int]
    | -- | An emitted event could not be encoded for append.
      EncodeFailed !CodecError
    | -- | The underlying store rejected the append.
      StoreFailed !StoreError
    | {- | Optimistic-concurrency retries were exhausted (carries the total
      attempts made and the last store error).
      -}
      RetryExhausted !Int !StoreError
    | {- | Retrying after a 'StreamAlreadyExists' conflict re-observed the same
      stream version: the store says the stream exists but reading it shows no
      progress. The typical cause is a soft-deleted stream, where reads return
      nothing but appends still collide. Carries the observed version and the
      conflict.
      -}
      ConflictFixpoint !StreamVersion !StoreError
    deriving stock (Generic, Eq, Show)

{- | Why replay of stored events stalled, projected from keiki's structured
failure types onto a monomorphic vocabulary suitable for 'CommandError'.
-}
data HydrationReplayReason
    = -- | No edge's first output template could have produced the event.
      HydrationNoInvertingEdge
    | -- | More than one edge could have produced the event.
      HydrationAmbiguousInversion
    | -- | An event did not match the next expected event in a chain.
      HydrationQueueMismatch
    | -- | The stream ended in the middle of a multi-event chain.
      HydrationTruncatedChain
    deriving stock (Generic, Eq, Show)

{- | Knobs controlling a single command invocation.

* 'retryLimit' — how many times to rehydrate-and-replay after an
  optimistic-concurrency conflict before giving up with 'RetryExhausted'.
* 'pageSize' — batch size when reading the stream during hydration.
* 'eventIds' — caller-supplied ids assigned to the emitted events in order;
  the basis for deterministic, idempotent appends (see 'Keiro.Router' and
  'Keiro.ProcessManager').
* 'beforeAppend' — a hook run immediately before each append attempt,
  primarily a test seam for injecting concurrent writes.
* 'retryBackoffMicros' — base delay before the k-th OCC retry, capped at
  100 ms and jittered. Set to 0 to disable backoff.
* 'metrics' — optional metrics handle for command and snapshot counters.
* 'verifyReplayOnAppend' — replay every just-appended batch from the
  pre-command state. Divergence is a post-commit advisory: it is counted and
  attached to the command span, but the already-successful command still
  succeeds. Snapshot-enabled streams always run the fold because snapshots
  consume its result.
-}
data RunCommandOptions = RunCommandOptions
    { retryLimit :: !Int
    , pageSize :: !Int32
    , eventIds :: ![EventId]
    , beforeAppend :: !(IO ())
    , retryBackoffMicros :: !Int
    , metrics :: !(Maybe KeiroMetrics)
    , verifyReplayOnAppend :: !Bool
    , tracer :: !(Maybe Tracer)
    {- ^ Optional OpenTelemetry tracer. When 'Just', the command runner
    opens an 'Internal'-kind span around each invocation, named after
    the resolved stream identifier and decorated with the messaging /
    error semantic-conventions attributes audited in
    'docs/research/opentelemetry-semconv-audit.md'. When 'Nothing',
    the runner emits no spans.
    -}
    , metadata :: !(Maybe Value)
    {- ^ Optional JSON merged into every event's metadata for this command
    invocation. Carries ambient context such as actor type, agent id,
    and session id. The codec always adds a @schemaVersion@ key; the
    keys here are merged on top (see 'Keiro.Codec.metadataFor'). When
    'Nothing', events carry only the schema-version marker, exactly as
    before this field existed.
    -}
    }
    deriving stock (Generic)

{- | Sensible defaults: 3 retries, 256-event read pages, no caller-assigned
event ids, a no-op pre-append hook, 5ms retry backoff, no metrics, post-append
replay verification enabled, no tracer, and no extra metadata.
-}
defaultRunCommandOptions :: RunCommandOptions
defaultRunCommandOptions =
    RunCommandOptions
        { retryLimit = 3
        , pageSize = 256
        , eventIds = []
        , beforeAppend = pure ()
        , retryBackoffMicros = 5000
        , metrics = Nothing
        , verifyReplayOnAppend = True
        , tracer = Nothing
        , metadata = Nothing
        }

data Hydrated rs s = Hydrated
    { state :: !s
    , registers :: !(RegFile rs)
    , streamVersion :: !StreamVersion
    }
    deriving stock (Generic)

data CommandPlan target rs s co
    = CommandNoOp !(CommandResult target)
    | CommandAppend !(Hydrated rs s) ![co] ![EventData]
    deriving stock (Generic)

hydrate ::
    forall phi rs s ci co es.
    (HasCallStack, IOE :> es, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    Eff es (Either CommandError (Hydrated rs s))
hydrate options eventStream targetStream =
    snapshotSeed >>= \case
        Nothing -> hydrateFull options eventStream targetStream
        Just seed -> do
            replayed <-
                hydrateSeeded
                    options
                    eventStream
                    targetStream
                    (seed ^. #state)
                    (seed ^. #registers)
                    (seed ^. #streamVersion)
            case replayed of
                Left _ -> hydrateFull options eventStream targetStream
                Right hydrated -> pure (Right hydrated)
  where
    snapshotSeed =
        case eventStream ^. #stateCodec of
            Nothing -> pure Nothing
            Just codec -> do
                lookupSnapshotSeed ((eventStream ^. #resolveStreamName) targetStream) codec >>= \case
                    SnapshotHit seed -> do
                        recordSnapshotReadHits (options ^. #metrics) 1
                        pure (Just seed)
                    SnapshotUnavailable reason -> do
                        recordSnapshotReadMisses (options ^. #metrics) 1
                        case reason of
                            SnapshotDecodeFailed _ -> recordSnapshotDecodeFailures (options ^. #metrics) 1
                            _ -> pure ()
                        pure Nothing

hydrateFull ::
    forall phi rs s ci co es.
    (HasCallStack, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    Eff es (Either CommandError (Hydrated rs s))
hydrateFull options eventStream targetStream =
    hydrateSeeded
        options
        eventStream
        targetStream
        (eventStream ^. #initialState)
        (eventStream ^. #initialRegisters)
        (StreamVersion 0)

{- | Replay a stored stream from an arbitrary snapshot or initial-state seed.

The store stream is grouped into bounded lists and each decoded prefix is
handed to keiki's 'Keiki.replayEvents'. Decoding stops at the first bad event in
a group, but the valid prefix is replayed first so an earlier replay failure
retains precedence over a later codec failure.
-}
hydrateSeeded ::
    forall phi rs s ci co es.
    (HasCallStack, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    s ->
    RegFile rs ->
    StreamVersion ->
    Eff es (Either CommandError (Hydrated rs s))
hydrateSeeded options eventStream targetStream seedState seedRegisters seedVersion = do
    replayed <-
        Streamly.fold
            (Fold.foldlM' replayPage (pure (Right initialReplay)))
            recordedPages
    pure (finishReplay replayed)
  where
    readPageSize = Prelude.max 1 (options ^. #pageSize)
    groupSize = Prelude.fromIntegral readPageSize
    recordedPages =
        Streamly.foldMany
            (Fold.take groupSize Fold.toList)
            (readStreamForwardStream resolvedName seedVersion readPageSize)
    resolvedName = (eventStream ^. #resolveStreamName) targetStream
    initialReplay = (Keiki.Settled seedState, seedRegisters, Nothing)

    replayPage ::
        Either CommandError (Keiki.InFlight s co, RegFile rs, Maybe RecordedEvent) ->
        [RecordedEvent] ->
        Eff es (Either CommandError (Keiki.InFlight s co, RegFile rs, Maybe RecordedEvent))
    replayPage (Left err) _ = pure (Left err)
    replayPage (Right (wrapper, registers, previousRecorded)) page =
        pure $ case Keiki.replayEvents (eventStream ^. #transducer) (wrapper, registers) decodedEvents of
            Left replayFailure ->
                Left (hydrationReplayError previousRecorded decodedRecorded replayFailure)
            Right (nextWrapper, nextRegisters) ->
                case pendingInputFailure of
                    Just err -> Left err
                    Nothing ->
                        Right
                            ( nextWrapper
                            , nextRegisters
                            , latestRecorded decodedRecorded previousRecorded
                            )
      where
        (decodedRecorded, decodedEvents, pendingInputFailure) = decodePrefix previousRecorded page

    decodePrefix :: Maybe RecordedEvent -> [RecordedEvent] -> ([RecordedEvent], [co], Maybe CommandError)
    decodePrefix previousRecorded = go [] [] startingVersion
      where
        startingVersion = maybe seedVersion (^. #streamVersion) previousRecorded

        go recordedAcc eventAcc lastSeen = \case
            [] -> (Prelude.reverse recordedAcc, Prelude.reverse eventAcc, Nothing)
            recorded : rest ->
                let observed = recorded ^. #streamVersion
                    expected = nextStreamVersion lastSeen
                 in if observed /= expected
                        then
                            ( Prelude.reverse recordedAcc
                            , Prelude.reverse eventAcc
                            , Just (HydrationGapDetected expected observed)
                            )
                        else case decodeRecorded (eventStream ^. #eventCodec) recorded of
                            Left err ->
                                ( Prelude.reverse recordedAcc
                                , Prelude.reverse eventAcc
                                , Just (HydrationDecodeFailed err)
                                )
                            Right event ->
                                go (recorded : recordedAcc) (event : eventAcc) observed rest

        nextStreamVersion (StreamVersion version) = StreamVersion (version Prelude.+ 1)

    hydrationReplayError ::
        Maybe RecordedEvent ->
        [RecordedEvent] ->
        Keiki.ReplayFailure s co ->
        CommandError
    hydrationReplayError previousRecorded decodedRecorded replayFailure =
        HydrationReplayFailed failureVersion (toHydrationReason (Keiki.replayFailureReason replayFailure))
      where
        failureVersion =
            maybe seedVersion (^. #streamVersion) failureRecorded
        failureRecorded =
            case Keiki.replayFailureReason replayFailure of
                Keiki.ReplayLogTruncated{} -> latestRecorded decodedRecorded previousRecorded
                Keiki.ReplayEventFailed{} ->
                    case recordedAt (Keiki.replayFailedIndex replayFailure) decodedRecorded of
                        Just recorded -> Just recorded
                        Nothing -> latestRecorded decodedRecorded previousRecorded

    finishReplay = \case
        Left err -> Left err
        Right (wrapper, finalRegisters, lastRecorded) ->
            case wrapper of
                Keiki.Settled finalState ->
                    Right
                        Hydrated
                            { state = finalState
                            , registers = finalRegisters
                            , streamVersion = maybe seedVersion (^. #streamVersion) lastRecorded
                            }
                Keiki.InFlight{} ->
                    Left
                        ( HydrationReplayFailed
                            (maybe seedVersion (^. #streamVersion) lastRecorded)
                            HydrationTruncatedChain
                        )

    toHydrationReason = \case
        Keiki.ReplayEventFailed stepFailure -> case stepFailure of
            Keiki.ReplayNoInvertingEdge{} -> HydrationNoInvertingEdge
            Keiki.ReplayAmbiguousInversions{} -> HydrationAmbiguousInversion
            Keiki.ReplayQueueMismatch{} -> HydrationQueueMismatch
        Keiki.ReplayLogTruncated{} -> HydrationTruncatedChain

    latestRecorded recorded fallback =
        case lastMaybe recorded of
            Just latest -> Just latest
            Nothing -> fallback

    lastMaybe = \case
        [] -> Nothing
        first : rest -> Just (Prelude.foldl (\_ current -> current) first rest)

    recordedAt eventIndex recorded =
        case Prelude.drop eventIndex recorded of
            found : _ -> Just found
            [] -> Nothing

{- | Hydrate the target stream, transduce the command, and append any emitted
events. Retries optimistic-concurrency conflicts up to 'retryLimit'. This
is the plain runner with no in-transaction side effects.
-}
runCommand ::
    forall phi rs s ci co es.
    (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    ValidatedEventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    ci ->
    Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co)))
runCommand options validatedEventStream targetStream command =
    withCommandSpan (options ^. #tracer) (resolvedStreamName eventStream targetStream) Nothing $ \mSpan -> do
        (result, attemptNo) <- attempt mSpan 1 Nothing
        recordCommandOutcome mSpan (^. #eventsAppended) attemptNo result
        pure result
  where
    eventStream = unvalidated validatedEventStream

    attempt mSpan attemptNo lastConflict = do
        hydrated <- hydrate options eventStream targetStream
        either (\err -> pure (Left err, attemptNo)) (runPlan mSpan attemptNo lastConflict) hydrated

    runPlan mSpan attemptNo lastConflict current =
        case conflictFixpoint lastConflict (current ^. #streamVersion) of
            Just err -> pure (Left err, attemptNo)
            Nothing ->
                case prepareCommandPlan options eventStream targetStream current command of
                    Left err -> pure (Left err, attemptNo)
                    Right (CommandNoOp result) -> pure (Right result, attemptNo)
                    Right (CommandAppend current' events encoded) ->
                        appendOnce mSpan attemptNo current' events encoded

    appendOnce mSpan attemptNo current events encoded = do
        liftIO (options ^. #beforeAppend)
        appended <-
            tryError @StoreError
                $ appendToStream
                    ((eventStream ^. #resolveStreamName) targetStream)
                    (expectedVersion (current ^. #streamVersion))
                    encoded
        case appended of
            Right appendResult -> do
                verifyAndSnapshot options mSpan eventStream current events appendResult
                pure (Right (appendedResult targetStream appendResult (Prelude.length encoded)), attemptNo)
            Left (_, storeError) ->
                retryOrFail options (attempt mSpan) attemptNo (current ^. #streamVersion) storeError

{- | Like 'runCommand', but run @afterAppend@ inside the /same/ transaction
as the append, so a read-model write commits atomically with the events.
The callback's result is returned as @Just@ on append (and 'Nothing' for a
no-op command that appended nothing).
-}
runCommandWithSql ::
    forall phi rs s ci co a es.
    (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    ValidatedEventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    ci ->
    (AppendResult -> Tx.Transaction a) ->
    Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co), Maybe a))
runCommandWithSql options eventStream targetStream command afterAppend =
    runCommandWithSqlEvents options eventStream targetStream command (\_ appendResult -> afterAppend appendResult)

-- The ignored first argument now carries @[(co, RecordedEvent)]@; the
-- @\_@ still type-checks unchanged.

{- | The most general runner: like 'runCommandWithSql', but the
in-transaction callback also receives every emitted event paired with the
'RecordedEvent' the store persisted for it, in append order. Inline
projections, process managers, and routers are all built on this.
-}
runCommandWithSqlEvents ::
    forall phi rs s ci co a es.
    (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    ValidatedEventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    ci ->
    ([(co, RecordedEvent)] -> AppendResult -> Tx.Transaction a) ->
    Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co), Maybe a))
runCommandWithSqlEvents options validatedEventStream targetStream command afterAppend =
    withCommandSpan (options ^. #tracer) (resolvedStreamName eventStream targetStream) Nothing $ \mSpan -> do
        (result, attemptNo) <- attempt mSpan 1 Nothing
        recordCommandOutcome mSpan (\(r, _) -> r ^. #eventsAppended) attemptNo result
        pure result
  where
    eventStream = unvalidated validatedEventStream

    attempt mSpan attemptNo lastConflict = do
        hydrated <- hydrate options eventStream targetStream
        either (\err -> pure (Left err, attemptNo)) (runPlan mSpan attemptNo lastConflict) hydrated

    runPlan mSpan attemptNo lastConflict current =
        case conflictFixpoint lastConflict (current ^. #streamVersion) of
            Just err -> pure (Left err, attemptNo)
            Nothing ->
                case prepareCommandPlan options eventStream targetStream current command of
                    Left err -> pure (Left err, attemptNo)
                    Right (CommandNoOp result) -> pure (Right (result, Nothing), attemptNo)
                    Right (CommandAppend current' events encoded) ->
                        appendWithSqlOnce mSpan attemptNo current' events encoded

    appendWithSqlOnce mSpan attemptNo current events encoded = do
        liftIO (options ^. #beforeAppend)
        store <- getKirokuStore
        enriched <- liftIO (enrichEventsIO store encoded)
        prepared <- prepareEventsIO enriched
        now <- liftIO getCurrentTime
        let streamName = (eventStream ^. #resolveStreamName) targetStream
            expected = expectedVersion (current ^. #streamVersion)
            body = do
                appended <- appendToStreamTx streamName expected prepared now
                case appended of
                    Left conflict ->
                        Tx.condemn $> Left (appendConflictToStoreError conflict)
                    Right appendResult -> do
                        let recordeds = reconstructRecorded appendResult now prepared
                        userValue <- afterAppend (Prelude.zip events recordeds) appendResult
                        pure (Right (appendResult, userValue))
        outcome <- tryError @StoreError (runTransaction body)
        case outcome of
            Right (Right (appendResult, userValue)) -> do
                verifyAndSnapshot options mSpan eventStream current events appendResult
                pure (Right (appendedResult targetStream appendResult (Prelude.length encoded), Just userValue), attemptNo)
            Right (Left storeError) ->
                retryOrFail options (attempt mSpan) attemptNo (current ^. #streamVersion) storeError
            Left (_, storeError) ->
                retryOrFail options (attempt mSpan) attemptNo (current ^. #streamVersion) storeError

prepareCommandPlan ::
    (BoolAlg phi (RegFile rs, ci)) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    Hydrated rs s ->
    ci ->
    Either CommandError (CommandPlan (EventStream phi rs s ci co) rs s co)
prepareCommandPlan options eventStream targetStream current command =
    case evaluateCommand eventStream current command of
        Left err -> Left err
        Right events -> toPlan events
  where
    toPlan [] =
        Right (CommandNoOp (noOpResult targetStream current))
    toPlan events =
        CommandAppend current events
            . assignEventIds (options ^. #eventIds)
            <$> encodeEvents (eventStream ^. #eventCodec) (options ^. #metadata) events

{- | Render the stream that the command targets as plain 'Text', for use
as a span name.
-}
resolvedStreamName ::
    EventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    Text
resolvedStreamName eventStream targetStream =
    case (eventStream ^. #resolveStreamName) targetStream of
        StreamName n -> n

{- | Attach the command-span outcome attributes after the runner returns.

On success: 'db.system.name' and 'keiro.events.appended'.
On failure: 'error.type' (low-cardinality classifier) and span status
'Error' (carrying the rendered 'CommandError' as the description).

Pure no-op when no span is active ('Nothing' tracer, etc).
-}
recordCommandOutcome ::
    (IOE :> es) =>
    Maybe Span ->
    (a -> Int) ->
    Int ->
    Either CommandError a ->
    Eff es ()
recordCommandOutcome Nothing _ _ _ = pure ()
recordCommandOutcome (Just sp) eventsOf attemptNo result = do
    addAttribute sp (unkey db_system_name) ("postgresql" :: Text)
    addAttribute sp (unkey keiro_retry_attempt) (Prelude.fromIntegral attemptNo :: Int64)
    case result of
        Right v ->
            addAttribute sp (unkey keiro_events_appended) (Prelude.fromIntegral (eventsOf v) :: Int64)
        Left err -> do
            addAttribute sp (unkey error_type) (commandErrorClass err)
            setStatus sp (Error (Text.take 256 (Text.pack (show err))))

{- | Low-cardinality classifier for a 'CommandError'. Used as the
@error.type@ attribute value on the command span.
-}
commandErrorClass :: CommandError -> Text
commandErrorClass = \case
    HydrationDecodeFailed{} -> "hydration_decode_failed"
    HydrationReplayFailed _ HydrationNoInvertingEdge -> "hydration_replay_no_inverting_edge"
    HydrationReplayFailed _ HydrationAmbiguousInversion -> "hydration_replay_ambiguous_inversion"
    HydrationReplayFailed _ HydrationQueueMismatch -> "hydration_replay_queue_mismatch"
    HydrationReplayFailed _ HydrationTruncatedChain -> "hydration_replay_truncated_chain"
    HydrationGapDetected{} -> "hydration_gap_detected"
    CommandRejected -> "command_rejected"
    CommandAmbiguous{} -> "command_ambiguous"
    EncodeFailed{} -> "encode_failed"
    StoreFailed{} -> "store_failed"
    RetryExhausted{} -> "retry_exhausted"
    ConflictFixpoint{} -> "conflict_fixpoint"

verifyAndSnapshot ::
    forall phi rs s ci co es.
    (BoolAlg phi (RegFile rs, ci), IOE :> es, Store :> es, Error StoreError :> es, Eq co) =>
    RunCommandOptions ->
    Maybe Span ->
    EventStream phi rs s ci co ->
    Hydrated rs s ->
    [co] ->
    AppendResult ->
    Eff es ()
verifyAndSnapshot options mSpan eventStream current events appendResult
    | Prelude.not (options ^. #verifyReplayOnAppend)
    , Nothing <- eventStream ^. #stateCodec =
        pure ()
    | otherwise =
        case Keiki.applyEventsEither (eventStream ^. #transducer) (state current, registers current) events of
            Left failure -> do
                recordSnapshotApplyDivergence (options ^. #metrics) 1
                for_ mSpan $ \sp ->
                    addAttribute
                        sp
                        (unkey keiro_replay_divergence)
                        (Text.take 256 (renderReplayFailure failure))
            Right finalState ->
                case eventStream ^. #stateCodec of
                    Nothing -> pure ()
                    Just codec -> do
                        let finalVersion = appendResult ^. #streamVersion
                            terminality =
                                if Keiki.isFinal (eventStream ^. #transducer) (Prelude.fst finalState)
                                    then Terminal
                                    else NotTerminal
                        when (shouldSnapshotSpan (eventStream ^. #snapshotPolicy) terminality finalState (current ^. #streamVersion) finalVersion)
                            $ do
                                encoded <- liftIO (encodeSnapshotStrict codec finalState)
                                case encoded of
                                    Left _ -> recordSnapshotEncodeFailures (options ^. #metrics) 1
                                    Right value -> do
                                        outcome <- tryError @StoreError (writeSnapshotEncoded (appendResult ^. #streamId) finalVersion codec value)
                                        case outcome of
                                            Right () -> pure ()
                                            Left _ -> recordSnapshotWriteFailures (options ^. #metrics) 1

renderReplayFailure :: Keiki.ReplayFailure s co -> Text
renderReplayFailure failure =
    "event_index="
        <> Text.pack (show (Keiki.replayFailedIndex failure))
        <> ";reason="
        <> case Keiki.replayFailureReason failure of
            Keiki.ReplayEventFailed stepFailure -> case stepFailure of
                Keiki.ReplayNoInvertingEdge{} -> "no_inverting_edge"
                Keiki.ReplayAmbiguousInversions{} -> "ambiguous_inversions"
                Keiki.ReplayQueueMismatch{} -> "queue_mismatch"
            Keiki.ReplayLogTruncated{} -> "log_truncated"

retryOrFail ::
    (IOE :> es) =>
    RunCommandOptions ->
    (Int -> Maybe (StoreError, StreamVersion) -> Eff es (Either CommandError a, Int)) ->
    Int ->
    StreamVersion ->
    StoreError ->
    Eff es (Either CommandError a, Int)
retryOrFail options retry attemptNo observedVersion storeError
    | isRetryableConflict storeError
    , attemptNo <= options ^. #retryLimit = do
        recordCommandConflicts (options ^. #metrics) 1
        backoffDelay options attemptNo
        recordCommandRetries (options ^. #metrics) 1
        retry (attemptNo Prelude.+ 1) (Just (storeError, observedVersion))
    | isRetryableConflict storeError = do
        recordCommandConflicts (options ^. #metrics) 1
        pure (Left (RetryExhausted attemptNo storeError), attemptNo)
    | otherwise = do
        case storeError of
            DuplicateEvent{} -> recordCommandDuplicates (options ^. #metrics) 1
            _ -> pure ()
        pure (Left (StoreFailed storeError), attemptNo)

backoffDelay :: (IOE :> es) => RunCommandOptions -> Int -> Eff es ()
backoffDelay options attemptNo
    | base <= 0 = pure ()
    | otherwise = do
        nanos <- liftIO getMonotonicTimeNSec
        let exponential = min 100000 (base Prelude.* (2 Prelude.^ (attemptNo Prelude.- 1 :: Int)))
            jitter =
                Prelude.fromIntegral (nanos `Prelude.mod` Prelude.fromIntegral exponential)
                    Prelude.- (exponential `Prelude.div` 2)
        liftIO (threadDelay (max 0 (exponential Prelude.+ jitter)))
  where
    base = options ^. #retryBackoffMicros

conflictFixpoint :: Maybe (StoreError, StreamVersion) -> StreamVersion -> Maybe CommandError
conflictFixpoint (Just (previousError@StreamAlreadyExists{}, previousVersion)) currentVersion
    | currentVersion == previousVersion = Just (ConflictFixpoint currentVersion previousError)
conflictFixpoint _ _ = Nothing

evaluateCommand ::
    (BoolAlg phi (RegFile rs, ci)) =>
    EventStream phi rs s ci co ->
    Hydrated rs s ->
    ci ->
    Either CommandError [co]
evaluateCommand eventStream current command =
    case Keiki.stepEither (eventStream ^. #transducer) (state current, registers current) command of
        Left Keiki.NoOutgoingEdges{} -> Left CommandRejected
        Left Keiki.NoMatchingEdge{} -> Left CommandRejected
        Left (Keiki.AmbiguousEdges _ matches) ->
            Left
                ( CommandAmbiguous
                    [ Keiki.edgeIndex (Keiki.matchedEdge matched)
                    | matched <- matches
                    ]
                )
        Right (_, _, events) -> Right events

encodeEvents :: Codec co -> Maybe Value -> [co] -> Either CommandError [EventData]
encodeEvents codec md =
    Prelude.mapM (mapLeft EncodeFailed . encodeForAppendWithMetadata codec md)

assignEventIds :: [EventId] -> [EventData] -> [EventData]
assignEventIds [] events = events
assignEventIds _ [] = []
assignEventIds (supplied : suppliedRest) (event : eventRest) =
    (event & #eventId .~ Just supplied) : assignEventIds suppliedRest eventRest

expectedVersion :: StreamVersion -> ExpectedVersion
expectedVersion (StreamVersion 0) = NoStream
expectedVersion version = ExactVersion version

noOpResult ::
    Stream target ->
    Hydrated rs s ->
    CommandResult target
noOpResult targetStream current =
    CommandResult
        { target = targetStream
        , streamVersion = current ^. #streamVersion
        , globalPosition = Nothing
        , eventsAppended = 0
        }

appendedResult ::
    Stream target ->
    AppendResult ->
    Int ->
    CommandResult target
appendedResult targetStream appendResult count =
    CommandResult
        { target = targetStream
        , streamVersion = appendResult ^. #streamVersion
        , globalPosition = Just (appendResult ^. #globalPosition)
        , eventsAppended = count
        }

{- | Rebuild the per-event 'RecordedEvent' values for a just-appended batch.

The store assigns each event in a batch a contiguous stream version and
global position: event @i@ (1-based) gets @last - count + i@ for both
counters, where @last@ is the position the 'AppendResult' reports for the
final event and @count@ is the batch size. (The kiroku append SQL numbers
events with @WITH ORDINALITY@ and inserts @initial + idx@; see EP-27's
Surprises & Discoveries.) We therefore reconstruct each 'RecordedEvent'
exactly, rather than reading the batch back. The @createdAt@ is the same
timestamp 'prepareEventsIO'/'appendToStreamTx' used for the insert.

This is a source append (events are written to their own stream), so
@streamVersion == originalVersion@ and @originalStreamId@ is the appended
stream's id, per the 'RecordedEvent' contract.
-}
reconstructRecorded :: AppendResult -> UTCTime -> [PreparedEvent] -> [RecordedEvent]
reconstructRecorded appendResult now prepared =
    Prelude.zipWith mk [0 ..] prepared
  where
    count = Prelude.length prepared
    StreamVersion lastSv = appendResult ^. #streamVersion
    GlobalPosition lastGp = appendResult ^. #globalPosition
    firstSv = lastSv Prelude.- Prelude.fromIntegral count Prelude.+ 1
    firstGp = lastGp Prelude.- Prelude.fromIntegral count Prelude.+ 1
    mk :: Int64 -> PreparedEvent -> RecordedEvent
    mk i prepared' =
        RecordedEvent
            { eventId = EventId (prepared' ^. #peEventId)
            , eventType = prepared' ^. #peEventType
            , streamVersion = StreamVersion (firstSv Prelude.+ i)
            , globalPosition = GlobalPosition (firstGp Prelude.+ i)
            , originalStreamId = appendResult ^. #streamId
            , originalVersion = StreamVersion (firstSv Prelude.+ i)
            , payload = prepared' ^. #pePayload
            , metadata = prepared' ^. #peMetadata
            , causationId = prepared' ^. #peCausationId
            , correlationId = prepared' ^. #peCorrelationId
            , createdAt = now
            }

isRetryableConflict :: StoreError -> Bool
isRetryableConflict = \case
    WrongExpectedVersion{} -> True
    StreamAlreadyExists{} -> True
    _ -> False

mapLeft :: (e -> e') -> Either e a -> Either e' a
mapLeft f = \case
    Left err -> Left (f err)
    Right value -> Right value
