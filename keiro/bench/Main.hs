{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main
  ( main,
  )
where

import BenchSetup (freshCounter, memoSetup, nextIteration, selected, selectedCounter, setupTrace)
import CommandProbe (commandPlanProbe, tableResetProbe)
import Control.Concurrent (threadDelay)
import Control.Monad (replicateM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef)
import Data.Int (Int32)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Clock (getMonotonicTimeNSec)
import GuardedCatalogBench (runGuardedCatalogEvidence)
import InboxDelegatedBench (inboxDelegatedBenchmarks, runInboxDelegatedExplainIfRequested)
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
import Keiro.Projection (InlineProjection (..))
import Keiro.ReadModel.Rebuild
  ( RebuildOptions (..),
    RebuildRequest (..),
    RebuildRunId,
    RebuildRunStatus (..),
    defaultRebuildOptions,
    mkRebuildRunId,
    registerProjectionCatalog,
    startCatalogRebuild,
  )
import Keiro.Telemetry qualified as Telemetry
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withMigratedBenchmarkSuite)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Types
  ( CategoryName (..),
    EventData (..),
    EventId (..),
    ExpectedVersion (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
  )
import OpenTelemetry.MeterProvider (createMeterProvider, defaultSdkMeterProviderOptions)
import OpenTelemetry.Metric.Core (getMeter)
import OpenTelemetry.Resource (emptyMaterializedResources)
import ProducerIdentityBench (producerIdentityBenchmarks)
import ReadModelBench
  ( readModelBenchmarks,
    runReadModelExplainEvidenceIfRequested,
    runReadModelLatencyEvidenceIfRequested,
    setupReadModelBench,
  )
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Stream qualified as Streamly
import System.Environment (lookupEnv)
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
main = do
  evidence <- runGuardedCatalogEvidence
  unless evidence ordinaryMain

ordinaryMain :: IO ()
ordinaryMain =
  withMigratedBenchmarkSuite \fixture ->
    withFreshResourceStore fixture \(store, runner) ->
      withFreshResourceStore fixture \(outboxStore, _) ->
        withFreshResourceStore fixture \(inboxStore, _) ->
          withFreshResourceStore fixture \(delegatedStore, _) ->
            withFreshResourceStore fixture \(producerStore, _) ->
              withFreshResourceStore fixture \(rebuildStore, _) ->
                withFreshResourceStore fixture \(readModelStore, readModelRunner) -> do
                  (provider, _env) <- createMeterProvider emptyMaterializedResources defaultSdkMeterProviderOptions
                  meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
                  metrics <- Telemetry.newKeiroMetrics meter
                  producerCounter <- newIORef 0
                  readModelSetup <- memoSetup do
                    setupTrace "read-model" "shared" "schema history=25000"
                    model <- setupReadModelBench readModelStore readModelRunner
                    runReadModelExplainEvidenceIfRequested model
                    runReadModelLatencyEvidenceIfRequested model
                    pure model
                  runInboxDelegatedExplainIfRequested delegatedStore
                  resetProbe <- lookupEnv "KEIRO_BENCH_RESET_PROBE"
                  probe <- lookupEnv "KEIRO_BENCH_COMMAND_PROBE"
                  if probe == Just "1"
                    then runCommandGrowthProbe store
                    else
                      if resetProbe == Just "1"
                        then runResetProbes outboxStore inboxStore producerStore
                        else
                          defaultMain
                            ( benchmarks store runner outboxStore inboxStore rebuildStore metrics (inboxDelegatedBenchmarks delegatedStore metrics)
                                <> [selected readModelSetup (\model -> readModelBenchmarks model !! groupIndex) | groupIndex <- [0 .. 2]]
                                <> producerIdentityBenchmarks producerStore producerCounter
                            )

benchmarks :: Store.KirokuStore -> StoreRunner -> Store.KirokuStore -> Store.KirokuStore -> Store.KirokuStore -> Telemetry.KeiroMetrics -> [Benchmark] -> [Benchmark]
benchmarks store runner outboxStore inboxStore rebuildStore metrics delegatedInboxBenchmarks =
  [ bgroup
      "outbox"
      [ scenarioBench outboxStore hotKey,
        scenarioBench outboxStore hotKeyNoLatency,
        scenarioBench outboxStore multiKey
      ],
    bgroup
      "inbox"
      [ inboxScenarioBench inboxStore (singleFull metrics),
        inboxScenarioBench inboxStore singleNoMetrics,
        inboxScenarioBench inboxStore batch100,
        inboxScenarioBench inboxStore singleSlim,
        bgroup "downstream" delegatedInboxBenchmarks
      ],
    selected (prepareCommandStore store) $ \_ ->
      bgroup
        "command"
        [ bgroup
            "legacy"
            [commandScenarioBench store "accepted-1" legacyAcceptedOneStream legacyAcceptedOneTarget EmitOne],
          bgroup
            "control"
            [commandScenarioBench store "accepted-1" legacyAcceptedOneStream (stream "bench-command-control") EmitOne],
          bgroup
            "domain-warmup"
            [domainCommandScenarioBench store "accepted-1" domainAcceptedOneHandler (stream "bench-command-domain-warmup") EmitOne],
          bgroup
            "domain"
            [ bcompareWithin 0 1.25 acceptedOneControlPattern $
                domainCommandScenarioBench store "accepted-1" domainAcceptedOneHandler domainAcceptedOneTarget EmitOne
            ],
          bgroup
            "legacy"
            [commandScenarioBench store "accepted-large" legacyAcceptedLargeStream legacyAcceptedLargeTarget EmitLarge],
          bgroup
            "domain"
            [ bcompareWithin 0 1.25 legacyAcceptedLargePattern $
                domainCommandScenarioBench store "accepted-large" domainAcceptedLargeHandler domainAcceptedLargeTarget EmitLarge
            ],
          bgroup
            "legacy"
            [commandScenarioBench store "no-op" legacyNoOpStream legacyNoOpTarget SelectNoOp],
          bgroup
            "domain"
            [ bcompareWithin 0 1.25 legacyNoOpPattern $
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
        ],
    bgroup
      "rebuild"
      [rebuildScenarioBench rebuildStore]
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
  selected (warmAction "outbox" (Text.unpack scenario.scenarioName) (runScenario store scenario)) $ \_ ->
    bench (Text.unpack scenario.scenarioName) $ nfIO (runScenario store scenario)

warmAction :: String -> String -> IO () -> IO ()
warmAction group name action = do
  setupTrace group name "warm-up invocations=3 timed_reset=TRUNCATE"
  replicateM_ 3 action

runScenario :: Store.KirokuStore -> OutboxScenario -> IO ()
runScenario store scenario = do
  runStoreChecked store do
    Store.runTransaction (Tx.sql "TRUNCATE keiro.keiro_outbox")
  seedOutbox store scenario.messages
  runStoreChecked store (drainOutbox scenario.brokerModel 0)

inboxScenarioBench :: Store.KirokuStore -> InboxScenario -> Benchmark
inboxScenarioBench store scenario =
  selected (warmAction "inbox" (Text.unpack scenario.inboxScenarioName) (runInboxScenario store scenario)) $ \_ ->
    bench (Text.unpack scenario.inboxScenarioName) $ nfIO (runInboxScenario store scenario)

runInboxScenario :: Store.KirokuStore -> InboxScenario -> IO ()
runInboxScenario store scenario = do
  runStoreChecked store do
    Store.runTransaction (Tx.sql "TRUNCATE keiro.keiro_inbox")
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
domainAcceptedOneTarget = legacyAcceptedOneTarget

domainAcceptedLargeTarget :: Stream BenchEventStream
domainAcceptedLargeTarget = legacyAcceptedLargeTarget

domainRejectedTarget :: Stream BenchEventStream
domainRejectedTarget = legacyNoOpTarget

domainNoOpTarget :: Stream BenchEventStream
domainNoOpTarget = legacyNoOpTarget

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

acceptedOneControlPattern :: String
acceptedOneControlPattern = "$NF == \"accepted-1\" && $(NF-1) == \"control\" && $(NF-2) == \"command\""

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

-- Seed a representative stream population before any prepared lookup is planned.
-- Empty-table statistics otherwise keep sequential scans as fresh samples grow.
prepareCommandStore :: Store.KirokuStore -> IO ()
prepareCommandStore store = do
  setupTrace "command" "shared" "schema seed_streams=5000 seed_events=5000 analyze=once-before-warm-up"
  for_ [1 .. 5000 :: Int] $ \n -> runStoreChecked store $ do
    void
      ( Store.appendToStream
          (StreamName ("benchseed-" <> Text.pack (show n)))
          NoStream
          [EventData Nothing (EventType "BenchSeed") Aeson.Null Nothing Nothing Nothing]
      )
  runStoreChecked store (Store.runTransaction (Tx.sql "ANALYZE streams; ANALYZE stream_events; ANALYZE events"))

commandScenarioBench :: Store.KirokuStore -> String -> ValidatedBenchEventStream -> Stream BenchEventStream -> BenchCommand -> Benchmark
commandScenarioBench store benchmarkName validatedStream target command =
  selectedCounter label units (prepareCommand label units action) $ \counter ->
    bench benchmarkName $ nfIO (action counter)
  where
    label = show (streamName target) <> "/legacy/" <> benchmarkName
    units = commandUnits command
    action counter = do
      n <- nextIteration label units counter
      let fresh = iterationTarget (tagTarget target "legacy") n
      runStoreChecked store do
        result <- runCommand defaultRunCommandOptions validatedStream fresh command
        case result of
          Right value | value ^. #eventsAppended == eventCount command -> pure ()
          other -> liftIO (fail ("unexpected command benchmark result: " <> show other))

domainCommandScenarioBench :: Store.KirokuStore -> String -> DomainCommandHandler (HsPred '[] BenchCommand) '[] BenchState BenchCommand BenchEvent Text Text -> Stream BenchEventStream -> BenchCommand -> Benchmark
domainCommandScenarioBench store benchmarkName handler target command =
  selectedCounter label units (prepareCommand label units action) $ \counter ->
    bench benchmarkName $ nfIO (action counter)
  where
    label = show (streamName target) <> "/domain/" <> benchmarkName
    units = commandUnits command
    action counter = do
      n <- nextIteration label units counter
      let fresh = iterationTarget (tagTarget target ("domain-" <> Text.pack benchmarkName)) n
      runStoreChecked store do
        result <- runDomainCommand defaultRunCommandOptions handler fresh command
        case result of
          Right value | value ^. #result . #eventsAppended == eventCount command -> pure ()
          other -> liftIO (fail ("unexpected typed command benchmark result: " <> show other))

commandUnits :: BenchCommand -> Int
commandUnits = max 1 . eventCount

eventCount :: BenchCommand -> Int
eventCount EmitOne = 1
eventCount EmitLarge = largeCommandBatchSize
eventCount SelectNoOp = 0

tagTarget :: Stream eventStream -> Text -> Stream eventStream
tagTarget target tag =
  let StreamName name = streamName target
   in stream (name <> "-" <> tag)

iterationTarget :: Stream eventStream -> Int -> Stream eventStream
iterationTarget target n =
  let StreamName name = streamName target
   in stream (name <> "-iteration-" <> Text.pack (show n))

prepareCommand :: String -> Int -> (IORef Int -> IO ()) -> IO (IORef Int)
prepareCommand label units action = do
  counter <- freshCounter label units
  setupTrace "command" label "warm-up invocations=3"
  replicateM_ 3 (action counter)
  pure counter

-- * Projection rebuild benchmark fixtures ---------------------------------

rebuildEventsPerCategory :: Int
rebuildEventsPerCategory = 200

rebuildPageSize :: Int32
rebuildPageSize = 16

rebuildScenarioBench :: Store.KirokuStore -> Benchmark
rebuildScenarioBench store =
  selectedCounter "rebuild" 600 setup $ \runCounter -> bench "three-categories-200" $ nfIO (runRebuild False runCounter)
  where
    setup = do
      setupTrace "rebuild" "three-categories-200" "schema source_events=600"
      runStoreChecked store do
        Store.runTransaction (Tx.sql rebuildBenchSql)
        traverse_ seedRebuildStream rebuildStreams
        registerProjectionCatalog rebuildCatalog >>= \case
          Left err -> liftIO (fail (show err))
          Right _ -> pure ()
      counter <- newIORef 0
      setupTrace "rebuild" "three-categories-200" "warm-up invocations=3 source_events_per_invocation=600"
      replicateM_ 3 (runRebuild True counter)
      probe <- lookupEnv "KEIRO_BENCH_REBUILD_PROBE"
      when (probe == Just "1") (replicateM_ 3 (runRebuild True counter))
      pure counter
    runRebuild probe runCounter = do
      runNumber <- nextIteration "rebuild" 600 runCounter
      runStoreChecked store do
        let request =
              RebuildRequest
                { rebuildRunId = benchmarkRebuildRunId runNumber,
                  requestedBy = "keiro-bench",
                  requestReason = "measure buffered projection replay",
                  replayFrom = GlobalPosition 0
                }
            options = (defaultRebuildOptions request) {replayPageSize = rebuildPageSize}
        startCatalogRebuild rebuildCatalog benchmarkRebuildGroupId options >>= \case
          Left err -> liftIO (fail ("unexpected rebuild benchmark result: " <> show err))
          Right report
            | report ^. #runStatus == RebuildRunPromoted -> do
                let sourceEvents = sum [sourceProgress ^. #eventCount | sourceProgress <- report ^. #sources]
                unless (sourceEvents == 600) (liftIO (fail ("rebuild source count changed: " <> show sourceEvents)))
                when probe (liftIO (setupTrace "rebuild" (show runNumber) ("source_events=" <> show sourceEvents)))
            | otherwise -> liftIO (fail ("rebuild benchmark did not promote: " <> show (report ^. #runStatus)))

seedRebuildStream :: (Store :> es) => StreamName -> Eff es ()
seedRebuildStream streamName' =
  void $
    Store.appendToStream
      streamName'
      NoStream
      [ EventData
          { eventId = Nothing,
            eventType = EventType "BenchRebuildEvent",
            payload = Aeson.toJSON eventNumber,
            metadata = Nothing,
            causationId = Nothing,
            correlationId = Nothing
          }
      | eventNumber <- [1 .. rebuildEventsPerCategory]
      ]

rebuildStreams :: [StreamName]
rebuildStreams =
  [ StreamName "orders-bench-rebuild",
    StreamName "customers-bench-rebuild",
    StreamName "billing-bench-rebuild"
  ]

rebuildCatalog :: ValidatedProjectionCatalog
rebuildCatalog =
  case validateProjectionCatalog rebuildCatalogDeclaration of
    Success catalog -> catalog
    Failure diagnostics -> error ("invalid rebuild benchmark catalog: " <> show diagnostics)

rebuildCatalogDeclaration :: ProjectionCatalog
rebuildCatalogDeclaration =
  ProjectionCatalog
    { sources =
        [ source "orders" ordersRebuildSourceId,
          source "customers" customersRebuildSourceId,
          source "billing" billingRebuildSourceId
        ],
      targets =
        [ target ordersRebuildTargetId "bench_rebuild_orders",
          target customersRebuildTargetId "bench_rebuild_customers",
          target billingRebuildTargetId "bench_rebuild_billing"
        ],
      rebuildGroups =
        [ RebuildGroupDeclaration
            { rebuildGroupId = benchmarkRebuildGroupId,
              orderedTargets = [ordersRebuildTargetId, customersRebuildTargetId, billingRebuildTargetId],
              verificationHooks = [],
              claimSite = rebuildSite "bench:rebuild-group"
            }
        ],
      projectionRevisions = [],
      externalReadContracts = [],
      subscriptions = [],
      dedupKeys = [],
      queryModels = [],
      projectionSets =
        [ projectionSet "orders" ordersRebuildSourceId ordersRebuildProjectionId ordersRebuildTargetId,
          projectionSet "customers" customersRebuildSourceId customersRebuildProjectionId customersRebuildTargetId,
          projectionSet "billing" billingRebuildSourceId billingRebuildProjectionId billingRebuildTargetId
        ]
    }
  where
    source sourceCategory sourceId =
      SourceDeclaration
        { sourceId,
          sourceScope = CategorySource (CategoryName sourceCategory),
          codecFingerprint = "bench-rebuild-v1",
          claimSite = rebuildSite ("bench:rebuild-source:" <> sourceCategory)
        }
    target targetId tableName =
      TargetDeclaration
        { targetId,
          qualifiedTable = QualifiedTable "app" tableName,
          resetPolicy = ClearBeforeReplay,
          dependsOn = [],
          claimSite = rebuildSite ("bench:rebuild-target:" <> tableName)
        }
    projectionSet label sourceId projectionId targetId =
      SomeProjectionSet
        ProjectionSet
          { projectionSource = sourceId,
            projectionDefinitions =
              ProjectionDefinition
                { projectionId,
                  rebuildGroup = benchmarkRebuildGroupId,
                  ownedTargets = targetId :| [],
                  replayPolicy =
                    Replayable
                      ReplayAdapter
                        { decodeForReplay = const ReplayIrrelevant,
                          applyForReplay = \() _ -> pure ()
                        },
                  handlers =
                    InlineHandler
                      InlineProjection
                        { name = "bench-rebuild-live-" <> label,
                          apply = \_ _ -> pure ()
                        }
                      (rebuildSite ("bench:rebuild-handler:" <> label))
                      :| [],
                  claimSite = rebuildSite ("bench:rebuild-projection:" <> label)
                }
                :| [],
            claimSite = rebuildSite ("bench:rebuild-set:" <> label)
          }

benchmarkRebuildRunId :: Int -> RebuildRunId
benchmarkRebuildRunId runNumber =
  either (error . Text.unpack) id (mkRebuildRunId ("bench-rebuild-" <> Text.pack (show runNumber)))

rebuildSite :: Text -> ClaimSite
rebuildSite raw = either (error . show) id (mkClaimSite raw)

rebuildIdentity :: (Text -> Either CatalogIdentityError value) -> Text -> value
rebuildIdentity constructor raw = either (error . show) id (constructor raw)

ordersRebuildSourceId, customersRebuildSourceId, billingRebuildSourceId :: SourceId
ordersRebuildSourceId = rebuildIdentity mkSourceId "bench-orders-source"
customersRebuildSourceId = rebuildIdentity mkSourceId "bench-customers-source"
billingRebuildSourceId = rebuildIdentity mkSourceId "bench-billing-source"

ordersRebuildTargetId, customersRebuildTargetId, billingRebuildTargetId :: TargetId
ordersRebuildTargetId = rebuildIdentity mkTargetId "bench-orders-target"
customersRebuildTargetId = rebuildIdentity mkTargetId "bench-customers-target"
billingRebuildTargetId = rebuildIdentity mkTargetId "bench-billing-target"

ordersRebuildProjectionId, customersRebuildProjectionId, billingRebuildProjectionId :: ProjectionId
ordersRebuildProjectionId = rebuildIdentity mkProjectionId "bench-orders-projection"
customersRebuildProjectionId = rebuildIdentity mkProjectionId "bench-customers-projection"
billingRebuildProjectionId = rebuildIdentity mkProjectionId "bench-billing-projection"

benchmarkRebuildGroupId :: RebuildGroupId
benchmarkRebuildGroupId = rebuildIdentity mkRebuildGroupId "bench-rebuild-group"

rebuildBenchSql :: BS.ByteString
rebuildBenchSql =
  "CREATE SCHEMA IF NOT EXISTS app; \
  \CREATE TABLE IF NOT EXISTS app.bench_rebuild_orders (marker bigint); \
  \CREATE TABLE IF NOT EXISTS app.bench_rebuild_customers (marker bigint); \
  \CREATE TABLE IF NOT EXISTS app.bench_rebuild_billing (marker bigint)"

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
  selectedCounter label fanout (prepareCommand label fanout action) $ \counter -> bench (show fanout) $ nfIO (action counter)
  where
    label = "router-" <> show fanout
    action counter = do
      n <- nextIteration label fanout counter
      let correlationId = Text.pack label <> "-" <> Text.pack (show n)
          input = FanoutInput correlationId fanout
      runResourceStoreChecked runner do
        runDomainRouterWorker
          defaultRunCommandOptions
          fanoutDomainRouter
          (fanoutAdapter input)
          (\message -> Just (iterationSourceEvent n, message))
        when (n <= 3) (verifyFanout "router" correlationId fanout)

domainProcessManagerFanoutBench :: StoreRunner -> Int -> Benchmark
domainProcessManagerFanoutBench runner fanout =
  selectedCounter label fanout (prepareCommand label fanout action) $ \counter -> bench (show fanout) $ nfIO (action counter)
  where
    label = "process-manager-" <> show fanout
    action counter = do
      n <- nextIteration label fanout counter
      let correlationId = Text.pack label <> "-" <> Text.pack (show n)
          input = FanoutInput correlationId fanout
      runResourceStoreChecked runner do
        runDomainProcessManagerWorker
          defaultRunCommandOptions
          fanoutDomainProcessManager
          (fanoutAdapter input)
          (\message -> Just (iterationSourceEvent n, message))
        when (n <= 3) (verifyFanout "process-manager" correlationId fanout)

verifyFanout :: (IOE :> es, Store :> es) => Text -> Text -> Int -> Eff es ()
verifyFanout coordinator correlationId fanout =
  for_ [0 .. fanout - 1] \targetIndex -> do
    rows <- Store.readStreamForward (StreamName (fanoutTargetName coordinator correlationId targetIndex)) (StreamVersion 0) 2
    unless (Vector.length rows == 1) (liftIO (fail "fan-out benchmark did not append exactly one event per fresh target"))

iterationSourceEvent :: Int -> RecordedEvent
iterationSourceEvent n = fanoutSourceEvent & #eventId .~ EventId (UUID.fromWords 0 0 1 (fromIntegral n))

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

-- A plain-IO diagnostic: it never contributes a tasty-bench timing or baseline.
runCommandGrowthProbe :: Store.KirokuStore -> IO ()
runCommandGrowthProbe store = do
  sample "empty" 0
  for_ [1 .. 5000 :: Int] $ \n -> append n
  sample "grown-5000-before-analyze" 5000
  runStoreChecked store (Store.runTransaction (Tx.sql "ANALYZE streams; ANALYZE stream_events; ANALYZE events"))
  sample "grown-5000-after-analyze" 5000
  for_ [5001 .. 10000 :: Int] $ \n -> append n
  sample "grown-10000" 10000
  for_ [10001 .. 100000 :: Int] $ \n -> append n
  sample "grown-100000" 100000
  for_ [100001 .. 1205000 :: Int] $ \n -> append n
  sample "grown-1205000" 1205000
  where
    append n = runStoreChecked store $ do
      result <- runDomainCommand defaultRunCommandOptions domainAcceptedOneHandler (stream ("bench-probe-" <> Text.pack (show n))) EmitOne
      case result of
        Right value | value ^. #result . #eventsAppended == 1 -> pure ()
        other -> liftIO (fail (show other))
    sample :: Text -> Int -> IO ()
    sample label n = do
      commandPlanProbe store label
      started <- getMonotonicTimeNSec
      replicateM_ 100 $ runStoreChecked store $ do
        result <- runDomainCommand defaultRunCommandOptions domainNoOpHandler (stream "bench-probe-absent") SelectNoOp
        case result of
          Right value | value ^. #result . #eventsAppended == 0 -> pure ()
          other -> liftIO (fail (show other))
      stopped <- getMonotonicTimeNSec
      freshStarted <- getMonotonicTimeNSec
      for_ [1 .. 100 :: Int] $ \sampleIndex -> append (10000000 + n * 100 + (if label == "grown-5000-after-analyze" then 100 else 0) + sampleIndex)
      freshStopped <- getMonotonicTimeNSec
      putStrLn ("FRESH_PROBE label=" <> Text.unpack label <> " mean_ns=" <> show ((freshStopped - freshStarted) `div` 100))
      putStrLn ("NOOP_PROBE label=" <> Text.unpack label <> " events=" <> show n <> " mean_ns=" <> show ((stopped - started) `div` 100))

runResetProbes :: Store.KirokuStore -> Store.KirokuStore -> Store.KirokuStore -> IO ()
runResetProbes outboxStore inboxStore producerStore = do
  let outboxSeed store count = do
        runStoreChecked store (Store.runTransaction (Tx.sql "TRUNCATE keiro.keiro_outbox"))
        seedOutbox store (take count (scenarioMessages (const Nothing)))
      inboxSeed = runInboxScenario inboxStore (InboxScenario "probe" Nothing PersistFullEnvelope Nothing inboxScenarioMessages)
  tableResetProbe outboxStore "keiro.keiro_outbox" 2000 (outboxSeed outboxStore 2000)
  tableResetProbe inboxStore "keiro.keiro_inbox" 2000 inboxSeed
  tableResetProbe producerStore "keiro.keiro_outbox" 1000 (outboxSeed producerStore 1000)
