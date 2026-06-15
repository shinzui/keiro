{- | The command side of the framework: hydrate an aggregate, transduce, append.

Running a command against an 'EventStream' follows one pipeline:

1. /Hydrate/ — replay the stream's stored events (optionally fast-forwarding
   from a snapshot) through the keiki transducer to recover the current
   @(state, registers)@ and stream version.
2. /Transduce/ — step the transducer with the command. A rejected transition
   yields 'CommandRejected'; a transition that emits no events yields a
   no-op 'CommandResult'.
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

Snapshots are written transparently after a successful append when the
stream's 'Keiro.EventStream.SnapshotPolicy' fires. Because that write
happens after the command's events are already committed, snapshot-write
failures are swallowed and counted instead of being reported as command
failures. Every runner accepts a tracer for optional OpenTelemetry spans.
-}
module Keiro.Command (
    -- * Results and errors
    CommandResult (..),
    CommandError (..),

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
import Keiro.Prelude
import Keiro.Snapshot (hydrateWithSnapshot, writeSnapshot)
import Keiro.Snapshot.Policy (shouldSnapshotSpan)
import Keiro.Stream (Stream)
import Keiro.Telemetry (
    KeiroMetrics,
    keiro_events_appended,
    keiro_retry_attempt,
    recordCommandConflicts,
    recordCommandDuplicates,
    recordCommandRetries,
    recordSnapshotWriteFailures,
    withCommandSpan,
 )
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Read (readStreamForwardStream)
import Kiroku.Store.Transaction (
    PreparedEvent,
    appendConflictToStoreError,
    appendToStreamTx,
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

Reports the target 'Stream', the stream version after the append, the
global log position (when the store assigned one), and how many events were
appended — @0@ for a no-op command that decided to emit nothing.
-}
data CommandResult target = CommandResult
    { target :: !(Stream target)
    , streamVersion :: !StreamVersion
    , globalPosition :: !(Maybe GlobalPosition)
    , eventsAppended :: !Int
    }
    deriving stock (Generic, Eq, Show)

-- | Why a command did not complete.
data CommandError
    = -- | A stored event could not be decoded while rehydrating the aggregate.
      HydrationDecodeFailed !CodecError
    | {- | Replay of the stored events through the transducer stalled at this
      version (the machine rejected an event that was already committed).
      -}
      HydrationReplayFailed !StreamVersion
    | -- | The transducer rejected the command in the hydrated state.
      CommandRejected
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
-}
data RunCommandOptions = RunCommandOptions
    { retryLimit :: !Int
    , pageSize :: !Int32
    , eventIds :: ![EventId]
    , beforeAppend :: !(IO ())
    , retryBackoffMicros :: !Int
    , metrics :: !(Maybe KeiroMetrics)
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
event ids, a no-op pre-append hook, 5ms retry backoff, no metrics, no tracer,
and no extra metadata.
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
        , tracer = Nothing
        , metadata = Nothing
        }

data Hydrated rs s = Hydrated
    { state :: !s
    , registers :: !(RegFile rs)
    , streamVersion :: !StreamVersion
    , globalPosition :: !(Maybe GlobalPosition)
    }
    deriving stock (Generic)

data Replay rs s co = Replay
    { replayHydrated :: !(Hydrated rs s)
    , replayState :: !(Keiki.InFlight s co)
    , lastObservedStreamVersion :: !StreamVersion
    }
    deriving stock (Generic)

data CommandPlan target rs s co
    = CommandNoOp !(CommandResult target)
    | CommandAppend !(Hydrated rs s) ![co] ![EventData]
    deriving stock (Generic)

hydrate ::
    forall phi rs s ci co es.
    (HasCallStack, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    Eff es (Either CommandError (Hydrated rs s))
hydrate options eventStream targetStream =
    snapshotSeed >>= \case
        Nothing -> hydrateFull options eventStream targetStream
        Just seed -> do
            replayed <- replayFrom seed
            case replayed of
                Left _ -> hydrateFull options eventStream targetStream
                Right hydrated -> pure (Right hydrated)
  where
    snapshotSeed =
        case eventStream ^. #stateCodec of
            Nothing -> pure Nothing
            Just codec ->
                hydrateWithSnapshot ((eventStream ^. #resolveStreamName) targetStream) codec

    replayFrom seed =
        finishReplay
            <$> replay
                Replay
                    { replayHydrated =
                        Hydrated
                            { state = seed ^. #state
                            , registers = seed ^. #registers
                            , streamVersion = seed ^. #streamVersion
                            , globalPosition = Nothing
                            }
                    , replayState = Keiki.Settled (seed ^. #state)
                    , lastObservedStreamVersion = seed ^. #streamVersion
                    }
                (seed ^. #streamVersion)

    finishReplay = \case
        Left err -> Left err
        Right replayed ->
            case replayState replayed of
                Keiki.Settled{} -> Right (replayHydrated replayed)
                Keiki.InFlight{} -> Left (HydrationReplayFailed (lastObservedStreamVersion replayed))

    replay start cursor =
        Streamly.fold
            (Fold.foldlM' applyRecorded (pure (Right start)))
            (readStreamForwardStream ((eventStream ^. #resolveStreamName) targetStream) cursor (options ^. #pageSize))

    applyRecorded ::
        Either CommandError (Replay rs s co) ->
        RecordedEvent ->
        Eff es (Either CommandError (Replay rs s co))
    applyRecorded (Left err) _ = pure (Left err)
    applyRecorded (Right current) recorded =
        case decodeRecorded (eventStream ^. #eventCodec) recorded of
            Left err -> pure (Left (HydrationDecodeFailed err))
            Right event -> pure (applyEvent current recorded event)

    applyEvent current recorded event =
        case Keiki.applyEventStreaming
            (eventStream ^. #transducer)
            (replayState current)
            (registers (replayHydrated current))
            event of
            Nothing -> Left (HydrationReplayFailed (recorded ^. #streamVersion))
            Just (nextReplayState, nextRegisters) ->
                Right
                    current
                        { replayHydrated = updateHydrated nextReplayState nextRegisters
                        , replayState = nextReplayState
                        , lastObservedStreamVersion = recorded ^. #streamVersion
                        }
      where
        updateHydrated nextReplayState nextRegisters =
            case nextReplayState of
                Keiki.Settled nextState ->
                    Hydrated
                        { state = nextState
                        , registers = nextRegisters
                        , streamVersion = recorded ^. #streamVersion
                        , globalPosition = Just (recorded ^. #globalPosition)
                        }
                Keiki.InFlight{} ->
                    (replayHydrated current){registers = nextRegisters}

hydrateFull ::
    forall phi rs s ci co es.
    (HasCallStack, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    Eff es (Either CommandError (Hydrated rs s))
hydrateFull options eventStream targetStream =
    finishReplay
        <$> Streamly.fold
            (Fold.foldlM' applyRecorded (pure (Right initialReplay)))
            (readStreamForwardStream ((eventStream ^. #resolveStreamName) targetStream) (StreamVersion 0) (options ^. #pageSize))
  where
    initialHydrated =
        Hydrated
            { state = eventStream ^. #initialState
            , registers = eventStream ^. #initialRegisters
            , streamVersion = StreamVersion 0
            , globalPosition = Nothing
            }

    initialReplay =
        Replay
            { replayHydrated = initialHydrated
            , replayState = Keiki.Settled (eventStream ^. #initialState)
            , lastObservedStreamVersion = StreamVersion 0
            }

    finishReplay = \case
        Left err -> Left err
        Right replayed ->
            case replayState replayed of
                Keiki.Settled{} -> Right (replayHydrated replayed)
                Keiki.InFlight{} -> Left (HydrationReplayFailed (lastObservedStreamVersion replayed))

    applyRecorded ::
        Either CommandError (Replay rs s co) ->
        RecordedEvent ->
        Eff es (Either CommandError (Replay rs s co))
    applyRecorded (Left err) _ = pure (Left err)
    applyRecorded (Right current) recorded =
        case decodeRecorded (eventStream ^. #eventCodec) recorded of
            Left err -> pure (Left (HydrationDecodeFailed err))
            Right event -> pure (applyEvent current recorded event)

    applyEvent current recorded event =
        case Keiki.applyEventStreaming
            (eventStream ^. #transducer)
            (replayState current)
            (registers (replayHydrated current))
            event of
            Nothing -> Left (HydrationReplayFailed (recorded ^. #streamVersion))
            Just (nextReplayState, nextRegisters) ->
                Right
                    current
                        { replayHydrated = updateHydrated nextReplayState nextRegisters
                        , replayState = nextReplayState
                        , lastObservedStreamVersion = recorded ^. #streamVersion
                        }
      where
        updateHydrated nextReplayState nextRegisters =
            case nextReplayState of
                Keiki.Settled nextState ->
                    Hydrated
                        { state = nextState
                        , registers = nextRegisters
                        , streamVersion = recorded ^. #streamVersion
                        , globalPosition = Just (recorded ^. #globalPosition)
                        }
                Keiki.InFlight{} ->
                    (replayHydrated current){registers = nextRegisters}

{- | Hydrate the target stream, transduce the command, and append any emitted
events. Retries optimistic-concurrency conflicts up to 'retryLimit'. This
is the plain runner with no in-transaction side effects.
-}
runCommand ::
    forall phi rs s ci co es.
    (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    ci ->
    Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co)))
runCommand options eventStream targetStream command =
    withCommandSpan (options ^. #tracer) (resolvedStreamName eventStream targetStream) Nothing $ \mSpan -> do
        (result, attemptNo) <- attempt 1 Nothing
        recordCommandOutcome mSpan (^. #eventsAppended) attemptNo result
        pure result
  where
    attempt attemptNo lastConflict = do
        hydrated <- hydrate options eventStream targetStream
        either (\err -> pure (Left err, attemptNo)) (runPlan attemptNo lastConflict) hydrated

    runPlan attemptNo lastConflict current =
        case conflictFixpoint lastConflict (current ^. #streamVersion) of
            Just err -> pure (Left err, attemptNo)
            Nothing ->
                case prepareCommandPlan options eventStream targetStream current command of
                    Left err -> pure (Left err, attemptNo)
                    Right (CommandNoOp result) -> pure (Right result, attemptNo)
                    Right (CommandAppend current' events encoded) ->
                        appendOnce attemptNo current' events encoded

    appendOnce attemptNo current events encoded = do
        liftIO (options ^. #beforeAppend)
        appended <-
            tryError @StoreError
                $ appendToStream
                    ((eventStream ^. #resolveStreamName) targetStream)
                    (expectedVersion (current ^. #streamVersion))
                    encoded
        case appended of
            Right appendResult -> do
                writeSnapshotIfNeeded options eventStream current events appendResult
                pure (Right (appendedResult targetStream appendResult (Prelude.length encoded)), attemptNo)
            Left (_, storeError) ->
                retryOrFail options attempt attemptNo (current ^. #streamVersion) storeError

{- | Like 'runCommand', but run @afterAppend@ inside the /same/ transaction
as the append, so a read-model write commits atomically with the events.
The callback's result is returned as @Just@ on append (and 'Nothing' for a
no-op command that appended nothing).
-}
runCommandWithSql ::
    forall phi rs s ci co a es.
    (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
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
    (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    ci ->
    ([(co, RecordedEvent)] -> AppendResult -> Tx.Transaction a) ->
    Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co), Maybe a))
runCommandWithSqlEvents options eventStream targetStream command afterAppend =
    withCommandSpan (options ^. #tracer) (resolvedStreamName eventStream targetStream) Nothing $ \mSpan -> do
        (result, attemptNo) <- attempt 1 Nothing
        recordCommandOutcome mSpan (\(r, _) -> r ^. #eventsAppended) attemptNo result
        pure result
  where
    attempt attemptNo lastConflict = do
        hydrated <- hydrate options eventStream targetStream
        either (\err -> pure (Left err, attemptNo)) (runPlan attemptNo lastConflict) hydrated

    runPlan attemptNo lastConflict current =
        case conflictFixpoint lastConflict (current ^. #streamVersion) of
            Just err -> pure (Left err, attemptNo)
            Nothing ->
                case prepareCommandPlan options eventStream targetStream current command of
                    Left err -> pure (Left err, attemptNo)
                    Right (CommandNoOp result) -> pure (Right (result, Nothing), attemptNo)
                    Right (CommandAppend current' events encoded) ->
                        appendWithSqlOnce attemptNo current' events encoded

    appendWithSqlOnce attemptNo current events encoded = do
        liftIO (options ^. #beforeAppend)
        prepared <- prepareEventsIO encoded
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
                writeSnapshotIfNeeded options eventStream current events appendResult
                pure (Right (appendedResult targetStream appendResult (Prelude.length encoded), Just userValue), attemptNo)
            Right (Left storeError) ->
                retryOrFail options attempt attemptNo (current ^. #streamVersion) storeError
            Left (_, storeError) ->
                retryOrFail options attempt attemptNo (current ^. #streamVersion) storeError

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
    HydrationReplayFailed{} -> "hydration_replay_failed"
    CommandRejected -> "command_rejected"
    EncodeFailed{} -> "encode_failed"
    StoreFailed{} -> "store_failed"
    RetryExhausted{} -> "retry_exhausted"
    ConflictFixpoint{} -> "conflict_fixpoint"

writeSnapshotIfNeeded ::
    forall phi rs s ci co es.
    (BoolAlg phi (RegFile rs, ci), IOE :> es, Store :> es, Error StoreError :> es, Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Hydrated rs s ->
    [co] ->
    AppendResult ->
    Eff es ()
writeSnapshotIfNeeded options eventStream current events appendResult =
    case eventStream ^. #stateCodec of
        Nothing -> pure ()
        Just codec ->
            case Keiki.applyEvents (eventStream ^. #transducer) (state current, registers current) events of
                Nothing -> pure ()
                Just finalState -> do
                    let finalVersion = appendResult ^. #streamVersion
                        terminality =
                            if Keiki.isFinal (eventStream ^. #transducer) (Prelude.fst finalState)
                                then Terminal
                                else NotTerminal
                    when (shouldSnapshotSpan (eventStream ^. #snapshotPolicy) terminality finalState (current ^. #streamVersion) finalVersion)
                        $ do
                            outcome <- tryError @StoreError (writeSnapshot (appendResult ^. #streamId) finalVersion codec finalState)
                            case outcome of
                                Right () -> pure ()
                                Left _ -> recordSnapshotWriteFailures (options ^. #metrics) 1

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
    case Keiki.step (eventStream ^. #transducer) (state current, registers current) command of
        Nothing -> Left CommandRejected
        Just (_, _, events) -> Right events

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
        , globalPosition = current ^. #globalPosition
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
