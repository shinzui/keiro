{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Retention.Fixture
  ( Signal (..),
    TargetCommand (..),
    TargetEvent (..),
    TargetEventStream,
    retentionTargetStream,
    retentionManager,
    retentionRouter,
    retentionTarget,
    signalStreamName,
    appendSignals,
    decodeSignal,
    ackAdapter,
    sampleOnAck,
  )
where

import Control.Concurrent.STM (atomically, tryPutTMVar)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (FromJSON, Result (..), ToJSON, Value (..), fromJSON, object, toJSON, (.=))
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Keiki.Core
  ( Edge (..),
    HsPred,
    InCtor,
    RegFile (..),
    SymTransducer (..),
    Update (..),
    WireCtor,
    inpCtor,
    matchInCtor,
    oNil,
    pack,
    unavailableInCtor,
    unavailableWireCtor,
    (*:),
  )
import Keiki.Core qualified as Keiki
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.ProcessManager (PMCommand (..), ProcessManager (..), ProcessManagerAction (..))
import Keiro.Router (Router (..))
import Keiro.Stream (Stream, stream)
import Keiro.Stream qualified as Stream
import Keiro.Test.Postgres (StoreRunner (..))
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Subscription.Stream (AckItem (..), subscriptionAckStream)
import Kiroku.Store.Subscription.Types (SubscriptionConfig)
import Kiroku.Store.Subscription.Types qualified as Sub
import Kiroku.Store.Types (EventData (..), EventId (..), EventType (..), ExpectedVersion (..), GlobalPosition (..), RecordedEvent (..), StreamName (..))
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ack qualified as Ack
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), MessageId (..))
import Streamly.Data.Stream qualified as Streamly

data Signal = Signal
  { signalId :: !Text,
    account :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data TargetCommand = Credit !Int
  deriving stock (Eq, Show)

data TargetEvent = Credited !Int
  deriving stock (Eq, Show)

data TargetState = TargetReady
  deriving stock (Bounded, Enum, Eq, Ord, Show)

type TargetEventStream = EventStream (HsPred '[] TargetCommand) '[] TargetState TargetCommand TargetEvent

retentionTargetStream :: ValidatedEventStream (HsPred '[] TargetCommand) '[] TargetState TargetCommand TargetEvent
retentionTargetStream = mkEventStreamOrThrow "retention-target" targetStreamDef

targetStreamDef :: TargetEventStream
targetStreamDef =
  EventStream
    { transducer = targetTransducer,
      initialState = TargetReady,
      initialRegisters = RNil,
      eventCodec =
        Codec
          { eventTypes = EventType "Credited" :| [],
            eventType = \_ -> EventType "Credited",
            schemaVersion = 1,
            encode = \(Credited amount) -> toJSON amount,
            decode = \_ value -> case fromJSON value of
              Success amount -> Right (Credited amount)
              Error message -> Left (Text.pack message),
            upcasters = []
          },
      resolveStreamName = Stream.streamName,
      snapshotPolicy = Never,
      stateCodec = Nothing
    }

targetTransducer :: SymTransducer (HsPred '[] TargetCommand) '[] TargetState TargetCommand TargetEvent
targetTransducer =
  SymTransducer
    { edgesOut = \TargetReady ->
        [ Edge
            { guard = matchInCtor creditCtor,
              update = UKeep,
              output = [pack creditCtor creditedCtor (inpCtor creditCtor #amount *: oNil)],
              target = TargetReady,
              mode = Keiki.Live
            }
        ],
      initial = TargetReady,
      initialRegs = RNil,
      isFinal = \_ -> False
    }

creditCtor :: InCtor TargetCommand '[ '("amount", Int)]
creditCtor =
  unavailableInCtor
    "Credit"
    (\(Credit amount) -> Just (RCons Proxy amount RNil))
    (\(RCons _ amount RNil) -> Credit amount)

creditedCtor :: WireCtor TargetEvent (Int, ())
creditedCtor =
  unavailableWireCtor
    "Credited"
    (\(Credited amount) -> Just (amount, ()))
    (\(amount, ()) -> Credited amount)

data ManagerCommand = Seen
  deriving stock (Eq, Show)

data ManagerEvent = SeenRecorded
  deriving stock (Eq, Show)

data ManagerState = ManagerReady
  deriving stock (Bounded, Enum, Eq, Ord, Show)

type ManagerEventStream = EventStream (HsPred '[] ManagerCommand) '[] ManagerState ManagerCommand ManagerEvent

managerEventStream :: ValidatedEventStream (HsPred '[] ManagerCommand) '[] ManagerState ManagerCommand ManagerEvent
managerEventStream = mkEventStreamOrThrow "retention-manager" managerStream

managerStream :: ManagerEventStream
managerStream =
  EventStream
    { transducer =
        SymTransducer
          { edgesOut = \ManagerReady ->
              [ Edge
                  { guard = matchInCtor seenCtor,
                    update = UKeep,
                    output = [pack seenCtor seenRecordedCtor oNil],
                    target = ManagerReady,
                    mode = Keiki.Live
                  }
              ],
            initial = ManagerReady,
            initialRegs = RNil,
            isFinal = \_ -> False
          },
      initialState = ManagerReady,
      initialRegisters = RNil,
      eventCodec =
        Codec
          { eventTypes = EventType "SeenRecorded" :| [],
            eventType = \_ -> EventType "SeenRecorded",
            schemaVersion = 1,
            encode = \_ -> Null,
            decode = \_ _ -> Right SeenRecorded,
            upcasters = []
          },
      resolveStreamName = Stream.streamName,
      snapshotPolicy = Never,
      stateCodec = Nothing
    }

seenCtor :: InCtor ManagerCommand '[]
seenCtor = unavailableInCtor "Seen" (\Seen -> Just RNil) (\RNil -> Seen)

seenRecordedCtor :: WireCtor ManagerEvent ()
seenRecordedCtor = unavailableWireCtor "SeenRecorded" (\SeenRecorded -> Just ()) (\() -> SeenRecorded)

retentionTarget :: Int -> Stream TargetCommand
retentionTarget accountNumber = stream ("retentiontarget-" <> Text.pack (show (accountNumber `mod` 16)))

retentionManager :: ProcessManager Signal (HsPred '[] ManagerCommand) '[] ManagerState ManagerCommand ManagerEvent (HsPred '[] TargetCommand) '[] TargetState TargetCommand TargetEvent
retentionManager =
  ProcessManager
    { name = "retention-manager",
      correlate = signalId,
      eventStream = managerEventStream,
      streamFor = \identifier -> stream ("pm:retention-" <> identifier),
      targetEventStream = retentionTargetStream,
      targetProjections = const [],
      handle = \signal ->
        ProcessManagerAction
          { command = Seen,
            commands = [PMCommand (retentionTarget signal.account) (Credit 1)],
            timers = []
          }
    }

retentionRouter :: Router Signal (HsPred '[] TargetCommand) '[] TargetState TargetCommand TargetEvent '[Store, Error StoreError, KirokuStoreResource, IOE]
retentionRouter =
  Router
    { name = "retention-router",
      key = signalId,
      resolve = \_ -> pure [PMCommand (retentionTarget accountNumber) (Credit 1) | accountNumber <- [0 .. 3]],
      targetEventStream = retentionTargetStream,
      targetProjections = const []
    }

signalStreamName :: Int -> StreamName
signalStreamName index = StreamName ("retentionsource-" <> Text.pack (show index))

appendSignals :: StoreRunner -> Int -> IO ()
appendSignals (StoreRunner runStore) count =
  forM_ [1 .. count] \index -> do
    let signal = Signal (Text.pack (show index)) (index `mod` 16)
        event =
          EventData
            { eventId = Nothing,
              eventType = EventType "RetentionSignal",
              payload = toJSON signal,
              metadata = Nothing,
              causationId = Nothing,
              correlationId = Nothing
            }
    result <- runStore (Store.appendToStream (signalStreamName index) NoStream [event])
    case result of
      Left failure -> fail ("appendSignals: " <> show failure)
      Right _ -> pure ()

decodeSignal :: RecordedEvent -> Maybe (RecordedEvent, Signal)
decodeSignal recorded =
  case fromJSON recorded.payload of
    Success signal -> Just (recorded, signal)
    Error _ -> Nothing

ackAdapter :: (IOE :> es) => Store.KirokuStore -> SubscriptionConfig -> Natural -> IO (Adapter es RecordedEvent, IO ())
ackAdapter store config bufferSize = do
  (source, cancel) <- subscriptionAckStream store config bufferSize
  let ingested = fmap (toIngested cancel) (Streamly.morphInner liftIO source)
  pure
    ( Adapter {adapterName = "retention-ack-bridge", source = ingested, shutdown = liftIO cancel},
      cancel
    )

toIngested :: (IOE :> es) => IO () -> AckItem -> Ingested es RecordedEvent
toIngested cancel (AckItem event attempt reply) =
  Ingested
    { envelope =
        Envelope
          { messageId = case event.eventId of EventId uuid -> MessageId (Text.pack (UUID.toString uuid)),
            cursor = case event.globalPosition of GlobalPosition position -> Just (CursorInt (fromIntegral position)),
            partition = Nothing,
            enqueuedAt = Just event.createdAt,
            traceContext = Nothing,
            headers = Nothing,
            attempt = Just (Attempt attempt),
            attributes = mempty,
            payload = event
          },
      ack = AckHandle \case
        AckHalt _ -> liftIO cancel
        decision -> liftIO $ atomically $ void $ tryPutTMVar reply (toSubscriptionResult attempt decision),
      lease = Nothing
    }

toSubscriptionResult :: Word -> AckDecision -> Sub.SubscriptionResult
toSubscriptionResult attempt = \case
  AckOk -> Sub.Continue
  AckRetry (Ack.RetryDelay delay) -> Sub.Retry (Sub.RetryDelay delay)
  AckDeadLetter reason -> Sub.DeadLetter $ case reason of
    Ack.PoisonPill detail -> Sub.DeadLetterPoison detail
    Ack.InvalidPayload detail -> Sub.DeadLetterInvalid detail
    Ack.MaxRetriesExceeded -> Sub.DeadLetterMaxAttempts (fromIntegral attempt)
    other@(Ack.ApplicationFailure code detail) ->
      Sub.DeadLetterOther
        (Ack.renderDeadLetterReason other)
        (object ["code" .= Ack.deadLetterCodeText code, "detail" .= detail])
  AckHalt _ -> Sub.Continue

sampleOnAck :: (IOE :> es) => Int -> Int -> (Int -> IO ()) -> Adapter es msg -> Eff es (Adapter es msg)
sampleOnAck expected blockSize sample adapter = do
  countRef <- liftIO (newIORef 0)
  pure adapter {source = fmap (wrap countRef) adapter.source}
  where
    wrap countRef ingested =
      ingested
        { ack = AckHandle \decision -> do
            ingested.ack.finalize decision
            unless (decision == AckOk) $ liftIO $ fail ("retention worker ack was " <> show decision)
            count <- liftIO $ atomicModifyIORef' countRef (\previous -> let next = previous + 1 in (next, next))
            when (count == expected) adapter.shutdown
            when (count `mod` blockSize == 0) $ liftIO (sample count)
        }
