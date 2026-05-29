module Keiro.Command
  ( CommandResult (..)
  , CommandError (..)
  , RunCommandOptions (..)
  , defaultRunCommandOptions
  , runCommand
  , runCommandWithSql
  , runCommandWithSqlEvents
  )
where

import Data.Functor (($>))
import Data.Int (Int32)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import GHC.Stack (HasCallStack)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import OpenTelemetry.Attributes.Key (unkey)
import OpenTelemetry.SemanticConventions (error_type)
import OpenTelemetry.Trace.Core (Span, Tracer, addAttribute, setStatus, SpanStatus (..))
import Keiki.Core (BoolAlg, RegFile)
import Keiki.Core qualified as Keiki
import Keiro.Codec (Codec, CodecError, decodeRecorded, encodeForAppendWithMetadata)
import Keiro.EventStream (EventStream)
import Keiro.Prelude
import Keiro.Snapshot (hydrateWithSnapshot, writeSnapshot)
import Keiro.Snapshot.Policy (shouldSnapshot)
import Keiro.Stream (Stream)
import Keiro.Telemetry (keiro_events_appended, db_system_name, withCommandSpan)
import Prelude qualified
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Read (readStreamForwardStream)
import Kiroku.Store.Transaction
  ( PreparedEvent
  , appendConflictToStoreError
  , appendToStreamTx
  , prepareEventsIO
  , runTransaction
  )
import Kiroku.Store.Types
  ( AppendResult
  , EventData
  , EventId (..)
  , ExpectedVersion (..)
  , GlobalPosition (..)
  , RecordedEvent (..)
  , StreamName (..)
  , StreamVersion (..)
  )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly

data CommandResult target = CommandResult
  { target :: !(Stream target)
  , streamVersion :: !StreamVersion
  , globalPosition :: !(Maybe GlobalPosition)
  , eventsAppended :: !Int
  }
  deriving stock (Generic, Eq, Show)

data CommandError
  = HydrationDecodeFailed !CodecError
  | HydrationReplayFailed !StreamVersion
  | CommandRejected
  | EncodeFailed !CodecError
  | StoreFailed !StoreError
  | RetryExhausted !Int !StoreError
  deriving stock (Generic, Eq, Show)

data RunCommandOptions = RunCommandOptions
  { retryLimit :: !Int
  , pageSize :: !Int32
  , eventIds :: ![EventId]
  , beforeAppend :: !(IO ())
  , tracer :: !(Maybe Tracer)
  -- ^ Optional OpenTelemetry tracer. When 'Just', the command runner
  -- opens an 'Internal'-kind span around each invocation, named after
  -- the resolved stream identifier and decorated with the messaging /
  -- error semantic-conventions attributes audited in
  -- 'docs/research/opentelemetry-semconv-audit.md'. When 'Nothing',
  -- the runner emits no spans.
  , metadata :: !(Maybe Value)
  -- ^ Optional JSON merged into every event's metadata for this command
  --   invocation. Carries ambient context such as actor type, agent id,
  --   and session id. The codec always adds a @schemaVersion@ key; the
  --   keys here are merged on top (see 'Keiro.Codec.metadataFor'). When
  --   'Nothing', events carry only the schema-version marker, exactly as
  --   before this field existed.
  }
  deriving stock (Generic)

defaultRunCommandOptions :: RunCommandOptions
defaultRunCommandOptions = RunCommandOptions
  { retryLimit = 3
  , pageSize = 256
  , eventIds = []
  , beforeAppend = pure ()
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
            { replayHydrated = Hydrated
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
          Right current
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
              (replayHydrated current) { registers = nextRegisters }

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
    initialHydrated = Hydrated
      { state = eventStream ^. #initialState
      , registers = eventStream ^. #initialRegisters
      , streamVersion = StreamVersion 0
      , globalPosition = Nothing
      }

    initialReplay = Replay
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
          Right current
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
              (replayHydrated current) { registers = nextRegisters }

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
    result <- attempt (options ^. #retryLimit)
    recordCommandOutcome mSpan (^. #eventsAppended) result
    pure result
  where
    attempt remaining = do
      hydrated <- hydrate options eventStream targetStream
      either (pure . Left) (runPlan remaining) hydrated

    runPlan remaining current =
      case prepareCommandPlan options eventStream targetStream current command of
        Left err -> pure (Left err)
        Right (CommandNoOp result) -> pure (Right result)
        Right (CommandAppend current' events encoded) ->
          appendOnce remaining current' events encoded

    appendOnce remaining current events encoded = do
      liftIO (options ^. #beforeAppend)
      appended <- tryError @StoreError $
        appendToStream
          ((eventStream ^. #resolveStreamName) targetStream)
          (expectedVersion (current ^. #streamVersion))
          encoded
      case appended of
        Right appendResult -> do
          writeSnapshotIfNeeded eventStream current events appendResult
          pure (Right (appendedResult targetStream appendResult (Prelude.length encoded)))
        Left (_, storeError) ->
          retryOrFail options attempt remaining storeError

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
    result <- attempt (options ^. #retryLimit)
    recordCommandOutcome mSpan (\(r, _) -> r ^. #eventsAppended) result
    pure result
  where
    attempt remaining = do
      hydrated <- hydrate options eventStream targetStream
      either (pure . Left) (runPlan remaining) hydrated

    runPlan remaining current =
      case prepareCommandPlan options eventStream targetStream current command of
        Left err -> pure (Left err)
        Right (CommandNoOp result) -> pure (Right (result, Nothing))
        Right (CommandAppend current' events encoded) ->
          appendWithSqlOnce remaining current' events encoded

    appendWithSqlOnce remaining current events encoded = do
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
          writeSnapshotIfNeeded eventStream current events appendResult
          pure (Right (appendedResult targetStream appendResult (Prelude.length encoded), Just userValue))
        Right (Left storeError) ->
          retryOrFail options attempt remaining storeError
        Left (_, storeError) ->
          retryOrFail options attempt remaining storeError

prepareCommandPlan ::
  BoolAlg phi (RegFile rs, ci) =>
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
resolvedStreamName
  :: EventStream phi rs s ci co
  -> Stream (EventStream phi rs s ci co)
  -> Text
resolvedStreamName eventStream targetStream =
  case (eventStream ^. #resolveStreamName) targetStream of
    StreamName n -> n

{- | Attach the command-span outcome attributes after the runner returns.

On success: 'db.system.name' and 'keiro.events.appended'.
On failure: 'error.type' (low-cardinality classifier) and span status
'Error' (carrying the rendered 'CommandError' as the description).

Pure no-op when no span is active ('Nothing' tracer, etc).
-}
recordCommandOutcome
  :: (IOE :> es)
  => Maybe Span
  -> (a -> Int)
  -> Either CommandError a
  -> Eff es ()
recordCommandOutcome Nothing _ _ = pure ()
recordCommandOutcome (Just sp) eventsOf result = do
  addAttribute sp (unkey db_system_name) ("postgresql" :: Text)
  case result of
    Right v ->
      addAttribute sp (unkey keiro_events_appended) (Prelude.fromIntegral (eventsOf v) :: Int64)
    Left err -> do
      addAttribute sp (unkey error_type) (commandErrorClass err)
      setStatus sp (Error (Text.pack (show err)))

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

writeSnapshotIfNeeded ::
  forall phi rs s ci co es.
  (BoolAlg phi (RegFile rs, ci), Store :> es, Eq co) =>
  EventStream phi rs s ci co ->
  Hydrated rs s ->
  [co] ->
  AppendResult ->
  Eff es ()
writeSnapshotIfNeeded eventStream current events appendResult =
  case eventStream ^. #stateCodec of
    Nothing -> pure ()
    Just codec ->
      case Keiki.applyEvents (eventStream ^. #transducer) (state current, registers current) events of
        Nothing -> pure ()
        Just finalState -> do
          let finalVersion = appendResult ^. #streamVersion
              terminal = Keiki.isFinal (eventStream ^. #transducer) (Prelude.fst finalState)
          when (shouldSnapshot (eventStream ^. #snapshotPolicy) terminal finalState finalVersion) $
            writeSnapshot (appendResult ^. #streamId) finalVersion codec finalState

retryOrFail ::
  RunCommandOptions ->
  (Int -> Eff es (Either CommandError a)) ->
  Int ->
  StoreError ->
  Eff es (Either CommandError a)
retryOrFail options retry remaining storeError
  | isRetryableConflict storeError
  , remaining > 0 =
      retry (remaining Prelude.- 1)
  | isRetryableConflict storeError =
      pure (Left (RetryExhausted (options ^. #retryLimit) storeError))
  | otherwise =
      pure (Left (StoreFailed storeError))

evaluateCommand ::
  BoolAlg phi (RegFile rs, ci) =>
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
noOpResult targetStream current = CommandResult
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
appendedResult targetStream appendResult count = CommandResult
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
    mk i prepared' = RecordedEvent
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
