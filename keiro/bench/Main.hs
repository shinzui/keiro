{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main
  ( main,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiki.Core
  ( Edge (..),
    HsPred,
    InCtor,
    RegFile (..),
    SymTransducer (..),
    Update (..),
    WireCtor,
    inpCtor,
    lit,
    matchInCtor,
    oNil,
    pack,
    unavailableInCtor,
    unavailableWireCtor,
    (*:),
  )
import Keiki.Core qualified as Keiki
import Keiro
import Keiro.Inbox
  ( InboxDedupePolicy (..),
    InboxPersistence (..),
    InboxResult (..),
    KafkaDeliveryRef (..),
    runInboxTransactionBatch,
    runInboxTransactionWith,
  )
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..))
import Keiro.Outbox
  ( OutboxId (..),
    OutboxRow,
    PublishOutcome (..),
    countOutboxBacklog,
    defaultPublishOptions,
    enqueueIntegrationEventTx,
    publishClaimedOutbox,
  )
import Keiro.Prelude
import Keiro.ProcessManager
  ( DomainProcessManager (..),
    PMCommand (..),
    ProcessManagerAction (..),
    runDomainProcessManagerWorker,
  )
import Keiro.Telemetry qualified as Telemetry
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withMigratedSuite)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Lifecycle qualified as Lifecycle
import Kiroku.Store.Types
  ( EventId (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
  )
import OpenTelemetry.MeterProvider (createMeterProvider, defaultSdkMeterProviderOptions)
import OpenTelemetry.Metric.Core (getMeter)
import OpenTelemetry.Resource (emptyMaterializedResources)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Stream qualified as Streamly
import Test.Tasty.Bench (Benchmark, bcompareWithin, bench, bgroup, defaultMain, nfIO)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude

workloadSize :: Int
workloadSize = 2000

seedChunkSize :: Int
seedChunkSize = 500

payloadSize :: Int
payloadSize = 1024

maxDrainPasses :: Int
maxDrainPasses = 2000

fixedOccurredAt :: UTCTime
fixedOccurredAt = UTCTime (ModifiedJulianDay 61000) (secondsToDiffTime 0)

data BrokerModel = BrokerModel
  { invocationMicros :: !Int,
    perRecordMicros :: !Int
  }
  deriving stock (Eq, Show)

data OutboxScenario = OutboxScenario
  { scenarioName :: !Text,
    brokerModel :: !BrokerModel,
    messages :: ![(OutboxId, IntegrationEvent)]
  }

data InboxScenario = InboxScenario
  { inboxScenarioName :: !Text,
    inboxMetrics :: !(Maybe Telemetry.KeiroMetrics),
    inboxPersistence :: !InboxPersistence,
    inboxBatchSize :: !(Maybe Int),
    inboxMessages :: ![(IntegrationEvent, KafkaDeliveryRef)]
  }

main :: IO ()
main =
  withMigratedSuite \fixture ->
    withFreshResourceStore fixture \(store, runner) -> do
      (provider, _env) <-
        createMeterProvider
          emptyMaterializedResources
          defaultSdkMeterProviderOptions
      meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
      metrics <- Telemetry.newKeiroMetrics meter
      defaultMain (benchmarks store runner metrics)

benchmarks :: Store.KirokuStore -> StoreRunner -> Telemetry.KeiroMetrics -> [Benchmark]
benchmarks store runner metrics =
  [ bgroup
      "outbox"
      [ scenarioBench store hotKey,
        scenarioBench store hotKeyNoLatency,
        scenarioBench store multiKey
      ],
    bgroup
      "inbox"
      [ inboxScenarioBench store (singleFull metrics),
        inboxScenarioBench store singleNoMetrics,
        inboxScenarioBench store batch100,
        inboxScenarioBench store singleSlim
      ],
    bgroup
      "command"
      [ bgroup
          "legacy"
          [ commandScenarioBench store "accepted-1" legacyAcceptedOneStream legacyAcceptedOneTarget EmitOne,
            commandScenarioBench store "accepted-large" legacyAcceptedLargeStream legacyAcceptedLargeTarget EmitLarge,
            commandScenarioBench store "no-op" legacyNoOpStream legacyNoOpTarget SelectNoOp
          ],
        bgroup
          "domain"
          [ bcompareWithin 0 1.25 legacyAcceptedOnePattern $
              domainCommandScenarioBench store "accepted-1" domainAcceptedOneHandler domainAcceptedOneTarget EmitOne,
            bcompareWithin 0 1.25 legacyAcceptedLargePattern $
              domainCommandScenarioBench store "accepted-large" domainAcceptedLargeHandler domainAcceptedLargeTarget EmitLarge,
            bcompareWithin 0 1.25 legacyNoOpPattern $
              domainCommandScenarioBench store "rejected" domainRejectedHandler domainRejectedTarget SelectNoOp,
            bcompareWithin 0 1.25 legacyNoOpPattern $
              domainCommandScenarioBench store "no-op" domainNoOpHandler domainNoOpTarget SelectNoOp,
            bgroup
              "router-fanout"
              [ domainRouterFanoutBench runner fanout
              | fanout <- coordinatorFanouts
              ],
            bgroup
              "process-manager-fanout"
              [ domainProcessManagerFanoutBench runner fanout
              | fanout <- coordinatorFanouts
              ]
          ]
      ]
  ]
  where
    hotKey =
      OutboxScenario
        { scenarioName = "hot-key",
          brokerModel = BrokerModel {invocationMicros = 1000, perRecordMicros = 10},
          messages = scenarioMessages \_ -> Just "aggregate-hot"
        }
    hotKeyNoLatency =
      OutboxScenario
        { scenarioName = "hot-key-nolatency",
          brokerModel = BrokerModel {invocationMicros = 0, perRecordMicros = 0},
          messages = scenarioMessages \_ -> Just "aggregate-hot"
        }
    multiKey =
      OutboxScenario
        { scenarioName = "multi-key",
          brokerModel = BrokerModel {invocationMicros = 1000, perRecordMicros = 10},
          messages = scenarioMessages \i -> Just ("aggregate-" <> Text.pack (show (i `mod` 200)))
        }
    singleFull metrics' =
      InboxScenario
        { inboxScenarioName = "single-full",
          inboxMetrics = Just metrics',
          inboxPersistence = PersistFullEnvelope,
          inboxBatchSize = Nothing,
          inboxMessages = inboxScenarioMessages
        }
    singleNoMetrics =
      InboxScenario
        { inboxScenarioName = "single-nometrics",
          inboxMetrics = Nothing,
          inboxPersistence = PersistFullEnvelope,
          inboxBatchSize = Nothing,
          inboxMessages = inboxScenarioMessages
        }
    batch100 =
      InboxScenario
        { inboxScenarioName = "batch-100",
          inboxMetrics = Nothing,
          inboxPersistence = PersistFullEnvelope,
          inboxBatchSize = Just 100,
          inboxMessages = inboxScenarioMessages
        }
    singleSlim =
      InboxScenario
        { inboxScenarioName = "single-slim",
          inboxMetrics = Nothing,
          inboxPersistence = PersistDedupeOnly,
          inboxBatchSize = Nothing,
          inboxMessages = inboxScenarioMessages
        }

scenarioBench :: Store.KirokuStore -> OutboxScenario -> Benchmark
scenarioBench store scenario =
  bench (Text.unpack scenario.scenarioName) $
    nfIO (runScenario store scenario)

runScenario :: Store.KirokuStore -> OutboxScenario -> IO ()
runScenario store scenario = do
  runStoreChecked store do
    Store.runTransaction (Tx.sql "TRUNCATE keiro_outbox")
  seedOutbox store scenario.messages
  runStoreChecked store (drainOutbox scenario.brokerModel 0)

inboxScenarioBench :: Store.KirokuStore -> InboxScenario -> Benchmark
inboxScenarioBench store scenario =
  bench (Text.unpack scenario.inboxScenarioName) $
    nfIO (runInboxScenario store scenario)

runInboxScenario :: Store.KirokuStore -> InboxScenario -> IO ()
runInboxScenario store scenario = do
  runStoreChecked store do
    Store.runTransaction (Tx.sql "TRUNCATE keiro_inbox")
  runStoreChecked store $
    case scenario.inboxBatchSize of
      Nothing ->
        traverse_
          (processInboxDelivery scenario.inboxMetrics scenario.inboxPersistence)
          scenario.inboxMessages
      Just batchSize ->
        traverse_
          (processInboxBatch scenario.inboxMetrics scenario.inboxPersistence)
          (chunksOf batchSize scenario.inboxMessages)

processInboxDelivery ::
  (IOE :> es, Store :> es) =>
  Maybe Telemetry.KeiroMetrics ->
  InboxPersistence ->
  (IntegrationEvent, KafkaDeliveryRef) ->
  Eff es ()
processInboxDelivery mMetrics persistence (event, kafkaRef) = do
  result <- runInboxTransactionWith mMetrics persistence PreferIntegrationMessageId event (Just kafkaRef) (\_ -> pure ())
  case result of
    Right (InboxProcessed ()) -> pure ()
    other -> liftIO (fail ("unexpected inbox benchmark result: " <> show other))

processInboxBatch ::
  (IOE :> es, Store :> es) =>
  Maybe Telemetry.KeiroMetrics ->
  InboxPersistence ->
  [(IntegrationEvent, KafkaDeliveryRef)] ->
  Eff es ()
processInboxBatch mMetrics persistence chunk = do
  results <-
    runInboxTransactionBatch
      mMetrics
      3
      PreferIntegrationMessageId
      persistence
      [(event, Just kafkaRef) | (event, kafkaRef) <- chunk]
      (\_ -> pure ())
  for_ results \case
    Right (InboxProcessed ()) -> pure ()
    other -> liftIO (fail ("unexpected inbox batch benchmark result: " <> show other))

seedOutbox :: Store.KirokuStore -> [(OutboxId, IntegrationEvent)] -> IO ()
seedOutbox store messages =
  traverse_ seedChunk (chunksOf seedChunkSize messages)
  where
    seedChunk chunk =
      runStoreChecked store $
        Store.runTransaction $
          traverse_ (uncurry enqueueIntegrationEventTx) chunk

drainOutbox :: (IOE :> es, Store :> es) => BrokerModel -> Int -> Eff es ()
drainOutbox broker passes = do
  backlog <- countOutboxBacklog
  if backlog == 0
    then pure ()
    else do
      when (passes >= maxDrainPasses) $
        liftIO (fail ("outbox benchmark exceeded safety cap of " <> show maxDrainPasses <> " passes"))
      void (publishClaimedOutbox (simulatedPublish broker) defaultPublishOptions Nothing)
      drainOutbox broker (passes + 1)

simulatedPublish :: (IOE :> es) => BrokerModel -> [OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]
simulatedPublish broker rows = do
  let totalMicros = broker.invocationMicros + broker.perRecordMicros * length rows
  when (totalMicros > 0) $
    liftIO (threadDelay totalMicros)
  pure [(row ^. #outboxId, PublishSucceeded) | row <- rows]

scenarioMessages :: (Int -> Maybe Text) -> [(OutboxId, IntegrationEvent)]
scenarioMessages keyFor =
  [ (OutboxId (UUID.fromWords64 0x018f0f1800007000 (0x8000000000000000 + fromIntegral i)), integrationEvent i (keyFor i))
  | i <- [1 .. workloadSize]
  ]

integrationEvent :: Int -> Maybe Text -> IntegrationEvent
integrationEvent i key =
  IntegrationEvent
    { messageId = "bench-msg-" <> Text.pack (show i),
      source = "bench.outbox",
      destination = "bench.outbox.events.v1",
      key,
      eventType = "BenchEvent",
      schemaVersion = 1,
      contentType = ApplicationJson,
      schemaReference = Nothing,
      sourceEventId = Nothing,
      sourceGlobalPosition = Nothing,
      payloadBytes = BS.replicate payloadSize 65,
      occurredAt = fixedOccurredAt,
      causationId = Nothing,
      correlationId = Nothing,
      traceContext = Nothing,
      attributes = Nothing
    }

inboxScenarioMessages :: [(IntegrationEvent, KafkaDeliveryRef)]
inboxScenarioMessages =
  [ ( integrationEvent i (Just ("inbox-key-" <> Text.pack (show i)))
        & #messageId
        .~ ("bench-inbox-msg-" <> Text.pack (show i))
        & #source
        .~ "bench.inbox"
        & #destination
        .~ "bench.inbox.events.v1",
      KafkaDeliveryRef "bench.inbox.events.v1" 0 (fromIntegral i)
    )
  | i <- [1 .. workloadSize]
  ]

chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs
  | n <= 0 = error "chunksOf: non-positive chunk size"
  | otherwise =
      case splitAt n xs of
        ([], _) -> []
        (chunk, rest) -> chunk : chunksOf n rest

-- * Command runner benchmark fixture ----------------------------------------

data BenchCommand
  = EmitOne
  | EmitLarge
  | SelectNoOp
  deriving stock (Eq, Show)

data BenchEvent
  = BenchOneEmitted !Text
  | BenchLargeEmitted !Text
  deriving stock (Eq, Show)

data BenchState = BenchReady
  deriving stock (Bounded, Enum, Eq, Ord, Show)

type BenchEventStream = EventStream (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent

type ValidatedBenchEventStream = ValidatedEventStream (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent

largeCommandBatchSize :: Int
largeCommandBatchSize = 100

fixedCommandPayload :: Text
fixedCommandPayload = Text.replicate payloadSize "a"

legacyAcceptedOneTarget :: Stream BenchEventStream
legacyAcceptedOneTarget = stream "bench-command-legacy-accepted-1"

legacyAcceptedLargeTarget :: Stream BenchEventStream
legacyAcceptedLargeTarget = stream "bench-command-legacy-accepted-large"

legacyNoOpTarget :: Stream BenchEventStream
legacyNoOpTarget = stream "bench-command-legacy-no-op"

domainAcceptedOneTarget :: Stream BenchEventStream
domainAcceptedOneTarget = stream "bench-command-domain-accepted-1"

domainAcceptedLargeTarget :: Stream BenchEventStream
domainAcceptedLargeTarget = stream "bench-command-domain-accepted-large"

domainRejectedTarget :: Stream BenchEventStream
domainRejectedTarget = stream "bench-command-domain-rejected"

domainNoOpTarget :: Stream BenchEventStream
domainNoOpTarget = stream "bench-command-domain-no-op"

legacyAcceptedOneStream :: ValidatedBenchEventStream
legacyAcceptedOneStream = mkEventStreamOrThrow "bench-command-legacy-accepted-1" (benchEventStream oneTransducer)

legacyAcceptedLargeStream :: ValidatedBenchEventStream
legacyAcceptedLargeStream = mkEventStreamOrThrow "bench-command-legacy-accepted-large" (benchEventStream largeTransducer)

legacyNoOpStream :: ValidatedBenchEventStream
legacyNoOpStream = mkEventStreamOrThrow "bench-command-legacy-no-op" (benchEventStream noOpTransducer)

domainAcceptedOneHandler :: DomainCommandHandler (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent Text Text
domainAcceptedOneHandler =
  DomainCommandHandler
    { eventStream = legacyAcceptedOneStream,
      classifySilent = \_ -> error "domainAcceptedOneHandler: eventful edge classified as silent"
    }

domainAcceptedLargeHandler :: DomainCommandHandler (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent Text Text
domainAcceptedLargeHandler =
  DomainCommandHandler
    { eventStream = legacyAcceptedLargeStream,
      classifySilent = \_ -> error "domainAcceptedLargeHandler: eventful edge classified as silent"
    }

domainRejectedHandler :: DomainCommandHandler (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent Text Text
domainRejectedHandler =
  DomainCommandHandler
    { eventStream = legacyNoOpStream,
      classifySilent = \_ -> SilentRejected "benchmark rejection"
    }

domainNoOpHandler :: DomainCommandHandler (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent Text Text
domainNoOpHandler =
  DomainCommandHandler
    { eventStream = legacyNoOpStream,
      classifySilent = \_ -> SilentNoOp "benchmark no-op"
    }

legacyAcceptedOnePattern :: String
legacyAcceptedOnePattern = "$NF == \"accepted-1\" && $(NF-1) == \"legacy\" && $(NF-2) == \"command\""

legacyAcceptedLargePattern :: String
legacyAcceptedLargePattern = "$NF == \"accepted-large\" && $(NF-1) == \"legacy\" && $(NF-2) == \"command\""

legacyNoOpPattern :: String
legacyNoOpPattern = "$NF == \"no-op\" && $(NF-1) == \"legacy\" && $(NF-2) == \"command\""

benchEventStream :: SymTransducer (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent -> BenchEventStream
benchEventStream transducer =
  EventStream
    { transducer,
      initialState = BenchReady,
      initialRegisters = RNil,
      eventCodec = benchEventCodec,
      resolveStreamName = streamName,
      snapshotPolicy = Never,
      stateCodec = Nothing
    }

oneTransducer :: SymTransducer (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent
oneTransducer = singleEdgeTransducer emitOneCtor [pack emitOneCtor oneEventCtor (lit fixedCommandPayload *: oNil)]

largeTransducer :: SymTransducer (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent
largeTransducer =
  singleEdgeTransducer
    emitLargeCtor
    (Prelude.replicate largeCommandBatchSize (pack emitLargeCtor largeEventCtor (lit fixedCommandPayload *: oNil)))

noOpTransducer :: SymTransducer (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent
noOpTransducer = singleEdgeTransducer selectNoOpCtor []

singleEdgeTransducer :: InCtor BenchCommand '[] -> [Keiki.OutTerm '[] BenchCommand BenchEvent] -> SymTransducer (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent
singleEdgeTransducer commandCtor emitted =
  SymTransducer
    { edgesOut = \BenchReady ->
        [ Edge
            { guard = matchInCtor commandCtor,
              update = UKeep,
              output = emitted,
              target = BenchReady,
              mode = Keiki.Live
            }
        ],
      initial = BenchReady,
      initialRegs = RNil,
      isFinal = \_ -> False
    }

emitOneCtor :: InCtor BenchCommand '[]
emitOneCtor =
  unavailableInCtor
    "EmitOne"
    (\case EmitOne -> Just RNil; _ -> Nothing)
    (\RNil -> EmitOne)

emitLargeCtor :: InCtor BenchCommand '[]
emitLargeCtor =
  unavailableInCtor
    "EmitLarge"
    (\case EmitLarge -> Just RNil; _ -> Nothing)
    (\RNil -> EmitLarge)

selectNoOpCtor :: InCtor BenchCommand '[]
selectNoOpCtor =
  unavailableInCtor
    "SelectNoOp"
    (\case SelectNoOp -> Just RNil; _ -> Nothing)
    (\RNil -> SelectNoOp)

oneEventCtor :: WireCtor BenchEvent (Text, ())
oneEventCtor =
  unavailableWireCtor
    "BenchOneEmitted"
    (\case BenchOneEmitted value -> Just (value, ()); _ -> Nothing)
    (\(value, ()) -> BenchOneEmitted value)

largeEventCtor :: WireCtor BenchEvent (Text, ())
largeEventCtor =
  unavailableWireCtor
    "BenchLargeEmitted"
    (\case BenchLargeEmitted value -> Just (value, ()); _ -> Nothing)
    (\(value, ()) -> BenchLargeEmitted value)

benchEventCodec :: Codec BenchEvent
benchEventCodec =
  Codec
    { eventTypes = EventType "BenchOneEmitted" :| [EventType "BenchLargeEmitted"],
      eventType = \case
        BenchOneEmitted {} -> EventType "BenchOneEmitted"
        BenchLargeEmitted {} -> EventType "BenchLargeEmitted",
      schemaVersion = 1,
      encode = \case
        BenchOneEmitted value -> toJSON value
        BenchLargeEmitted value -> toJSON value,
      decode = \(EventType eventTypeName) _ ->
        case eventTypeName of
          "BenchOneEmitted" -> Right (BenchOneEmitted fixedCommandPayload)
          "BenchLargeEmitted" -> Right (BenchLargeEmitted fixedCommandPayload)
          other -> Left ("unknown command benchmark event type: " <> other),
      upcasters = []
    }

commandScenarioBench :: Store.KirokuStore -> String -> ValidatedBenchEventStream -> Stream BenchEventStream -> BenchCommand -> Benchmark
commandScenarioBench store benchmarkName validatedStream target command =
  bench benchmarkName $ nfIO $ runStoreChecked store do
    void (Lifecycle.hardDeleteStream (streamName target))
    result <- runCommand defaultRunCommandOptions validatedStream target command
    case result of
      Right _ -> pure ()
      Left err -> liftIO (fail ("unexpected command benchmark result: " <> show err))

domainCommandScenarioBench :: Store.KirokuStore -> String -> DomainCommandHandler (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent Text Text -> Stream BenchEventStream -> BenchCommand -> Benchmark
domainCommandScenarioBench store benchmarkName handler target command =
  bench benchmarkName $ nfIO $ runStoreChecked store do
    void (Lifecycle.hardDeleteStream (streamName target))
    result <- runDomainCommand defaultRunCommandOptions handler target command
    case result of
      Right DomainCommandOutcome {} -> pure ()
      Left err -> liftIO (fail ("unexpected typed command benchmark result: " <> show err))

-- * Domain coordinator worker benchmark fixtures ---------------------------

data FanoutInput = FanoutInput !Text !Int

data FanoutCommand = EmitFanout !Int
  deriving stock (Eq, Show)

data FanoutEvent = FanoutEmitted !Int !Text
  deriving stock (Eq, Show)

data FanoutState = FanoutReady
  deriving stock (Bounded, Enum, Eq, Ord, Show)

type ValidatedFanoutEventStream = ValidatedEventStream (HsPred '[] FanoutCommand) '[] FanoutState FanoutCommand FanoutEvent

type FanoutCommandFields = '[ '("targetIndex", Int)]

fanoutCommandCtor :: InCtor FanoutCommand FanoutCommandFields
fanoutCommandCtor =
  unavailableInCtor
    "EmitFanout"
    (\case EmitFanout targetIndex -> Just (RCons Proxy targetIndex RNil))
    (\(RCons _ targetIndex RNil) -> EmitFanout targetIndex)

fanoutEventCtor :: WireCtor FanoutEvent (Int, ())
fanoutEventCtor =
  unavailableWireCtor
    "FanoutEmitted"
    ( \case
        FanoutEmitted targetIndex payload
          | payload == fanoutPayload targetIndex -> Just (targetIndex, ())
        _ -> Nothing
    )
    (\(targetIndex, ()) -> FanoutEmitted targetIndex (fanoutPayload targetIndex))

fanoutTransducer :: SymTransducer (HsPred '[] FanoutCommand) '[] FanoutState FanoutCommand FanoutEvent
fanoutTransducer =
  SymTransducer
    { edgesOut = \FanoutReady ->
        [ Edge
            { guard = matchInCtor fanoutCommandCtor,
              update = UKeep,
              output = [pack fanoutCommandCtor fanoutEventCtor (inpCtor fanoutCommandCtor #targetIndex *: oNil)],
              target = FanoutReady,
              mode = Keiki.Live
            }
        ],
      initial = FanoutReady,
      initialRegs = RNil,
      isFinal = const False
    }

fanoutEventCodec :: Codec FanoutEvent
fanoutEventCodec =
  Codec
    { eventTypes = EventType "FanoutEmitted" :| [],
      eventType = const (EventType "FanoutEmitted"),
      schemaVersion = 1,
      encode = \(FanoutEmitted targetIndex payload) -> toJSON (targetIndex, payload),
      decode = \(EventType eventTypeName) payload ->
        case eventTypeName of
          "FanoutEmitted" ->
            case Aeson.fromJSON payload of
              Aeson.Success (targetIndex, value) -> Right (FanoutEmitted targetIndex value)
              Aeson.Error err -> Left (Text.pack err)
          other -> Left ("unknown fan-out benchmark event type: " <> other),
      upcasters = []
    }

fanoutEventStream :: ValidatedFanoutEventStream
fanoutEventStream =
  mkEventStreamOrThrow
    "bench-command-domain-fanout"
    EventStream
      { transducer = fanoutTransducer,
        initialState = FanoutReady,
        initialRegisters = RNil,
        eventCodec = fanoutEventCodec,
        resolveStreamName = streamName,
        snapshotPolicy = Never,
        stateCodec = Nothing
      }

fanoutDomainHandler :: DomainCommandHandler (HsPred '[] FanoutCommand) '[] FanoutState FanoutCommand FanoutEvent Text Text
fanoutDomainHandler =
  DomainCommandHandler
    { eventStream = fanoutEventStream,
      classifySilent = \_ -> error "fanoutDomainHandler: eventful edge classified as silent"
    }

fanoutPayload :: Int -> Text
fanoutPayload targetIndex =
  Text.take payloadSize (Text.replicate repetitions seed)
  where
    seed = Text.pack (show targetIndex) <> ":"
    repetitions = payloadSize `div` Text.length seed + 1

coordinatorFanouts :: [Int]
coordinatorFanouts = [10, 100, 1000]

domainRouterFanoutBench :: StoreRunner -> Int -> Benchmark
domainRouterFanoutBench runner fanout =
  bench (show fanout) $ nfIO $ do
    let correlationId = "router-" <> Text.pack (show fanout)
        input = FanoutInput correlationId fanout
    runResourceStoreChecked runner do
      resetFanoutTargets "router" correlationId fanout
      runDomainRouterWorker
        defaultRunCommandOptions
        fanoutDomainRouter
        (fanoutAdapter input)
        (\message -> Just (fanoutSourceEvent, message))

domainProcessManagerFanoutBench :: StoreRunner -> Int -> Benchmark
domainProcessManagerFanoutBench runner fanout =
  bench (show fanout) $ nfIO $ do
    let correlationId = "process-manager-" <> Text.pack (show fanout)
        input = FanoutInput correlationId fanout
    runResourceStoreChecked runner do
      resetFanoutTargets "process-manager" correlationId fanout
      void (Lifecycle.hardDeleteStream (StreamName ("bench-command-domain-process-manager:" <> correlationId)))
      runDomainProcessManagerWorker
        defaultRunCommandOptions
        fanoutDomainProcessManager
        (fanoutAdapter input)
        (\message -> Just (fanoutSourceEvent, message))

fanoutDomainRouter ::
  DomainRouter
    FanoutInput
    (HsPred '[] FanoutCommand)
    '[]
    FanoutState
    FanoutCommand
    FanoutEvent
    Text
    Text
    es
fanoutDomainRouter =
  DomainRouter
    { name = "bench-domain-router",
      key = \(FanoutInput correlationId _) -> correlationId,
      resolve = \(FanoutInput correlationId fanout) -> pure (fanoutCommands "router" correlationId fanout),
      targetHandler = fanoutDomainHandler,
      targetProjections = const []
    }

fanoutDomainProcessManager ::
  DomainProcessManager
    FanoutInput
    (HsPred '[] BenchCommand)
    '[]
    BenchState
    BenchCommand
    BenchEvent
    (HsPred '[] FanoutCommand)
    '[]
    FanoutState
    FanoutCommand
    FanoutEvent
    Text
    Text
fanoutDomainProcessManager =
  DomainProcessManager
    { name = "bench-domain-process-manager",
      correlate = \(FanoutInput correlationId _) -> correlationId,
      eventStream = legacyNoOpStream,
      streamFor = \correlationId -> stream ("bench-command-domain-process-manager:" <> correlationId),
      targetHandler = fanoutDomainHandler,
      targetProjections = const [],
      handle = \(FanoutInput correlationId fanout) ->
        ProcessManagerAction
          { command = SelectNoOp,
            commands = fanoutCommands "process-manager" correlationId fanout,
            timers = []
          }
    }

fanoutCommands :: Text -> Text -> Int -> [PMCommand FanoutCommand]
fanoutCommands coordinator correlationId fanout =
  [ PMCommand
      { target = stream (fanoutTargetName coordinator correlationId targetIndex),
        command = EmitFanout targetIndex
      }
  | targetIndex <- [0 .. fanout - 1]
  ]

fanoutTargetName :: Text -> Text -> Int -> Text
fanoutTargetName coordinator correlationId targetIndex =
  "bench-command-domain-"
    <> coordinator
    <> ":"
    <> correlationId
    <> ":"
    <> Text.pack (show targetIndex)

resetFanoutTargets :: (Store :> es) => Text -> Text -> Int -> Eff es ()
resetFanoutTargets coordinator correlationId fanout =
  traverse_
    (\targetIndex -> void (Lifecycle.hardDeleteStream (StreamName (fanoutTargetName coordinator correlationId targetIndex))))
    [0 .. fanout - 1]

fanoutSourceEvent :: RecordedEvent
fanoutSourceEvent =
  RecordedEvent
    { eventId = EventId (UUID.fromWords64 0x018f0f1800007000 0x8000000000000abc),
      eventType = EventType "BenchFanoutSource",
      streamVersion = StreamVersion 1,
      globalPosition = GlobalPosition 1,
      originalStreamId = StreamId 1,
      originalVersion = StreamVersion 1,
      payload = toJSON ("fanout" :: Text),
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = fixedOccurredAt
    }

fanoutAdapter :: FanoutInput -> Adapter es FanoutInput
fanoutAdapter input =
  Adapter
    { adapterName = "bench-domain-coordinator",
      source =
        Streamly.fromList
          [ Ingested
              { envelope =
                  Envelope
                    { messageId = "bench-domain-fanout",
                      cursor = Nothing,
                      partition = Nothing,
                      enqueuedAt = Nothing,
                      traceContext = Nothing,
                      headers = Nothing,
                      attempt = Nothing,
                      attributes = mempty,
                      payload = input
                    },
                ack = AckHandle (\_ -> pure ()),
                lease = Nothing
              }
          ],
      shutdown = pure ()
    }

runResourceStoreChecked :: StoreRunner -> Eff '[Store, Error Store.StoreError, KirokuStoreResource, IOE] a -> IO a
runResourceStoreChecked (StoreRunner runner) action = do
  result <- runner action
  case result of
    Left err -> fail (show err)
    Right value -> pure value

runStoreChecked :: Store.KirokuStore -> Eff [Store, Error Store.StoreError, IOE] a -> IO a
runStoreChecked store action = do
  result <- Store.runStoreIO store action
  case result of
    Left err -> fail (show err)
    Right value -> pure value
