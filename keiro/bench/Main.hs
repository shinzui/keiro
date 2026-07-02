{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main (
    main,
)
where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Inbox (
    InboxDedupePolicy (..),
    InboxPersistence (..),
    InboxResult (..),
    KafkaDeliveryRef (..),
    runInboxTransactionBatch,
    runInboxTransactionWith,
 )
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..))
import Keiro.Outbox (
    OutboxId (..),
    OutboxRow,
    PublishOutcome (..),
    countOutboxBacklog,
    defaultPublishOptions,
    enqueueIntegrationEventTx,
    publishClaimedOutbox,
 )
import Keiro.Prelude
import Keiro.Telemetry qualified as Telemetry
import Keiro.Test.Postgres (withFreshStore, withMigratedSuite)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import OpenTelemetry.MeterProvider (createMeterProvider, defaultSdkMeterProviderOptions)
import OpenTelemetry.Metric.Core (getMeter)
import OpenTelemetry.Resource (emptyMaterializedResources)
import Test.Tasty.Bench (Benchmark, bench, bgroup, defaultMain, nfIO)
import "hasql-transaction" Hasql.Transaction qualified as Tx

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
    { invocationMicros :: !Int
    , perRecordMicros :: !Int
    }
    deriving stock (Eq, Show)

data OutboxScenario = OutboxScenario
    { scenarioName :: !Text
    , brokerModel :: !BrokerModel
    , messages :: ![(OutboxId, IntegrationEvent)]
    }

data InboxScenario = InboxScenario
    { inboxScenarioName :: !Text
    , inboxMetrics :: !(Maybe Telemetry.KeiroMetrics)
    , inboxPersistence :: !InboxPersistence
    , inboxBatchSize :: !(Maybe Int)
    , inboxMessages :: ![(IntegrationEvent, KafkaDeliveryRef)]
    }

main :: IO ()
main =
    withMigratedSuite \fixture ->
        withFreshStore fixture \store -> do
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            metrics <- Telemetry.newKeiroMetrics meter
            defaultMain (benchmarks store metrics)

benchmarks :: Store.KirokuStore -> Telemetry.KeiroMetrics -> [Benchmark]
benchmarks store metrics =
    [ bgroup
        "outbox"
        [ scenarioBench store hotKey
        , scenarioBench store hotKeyNoLatency
        , scenarioBench store multiKey
        ]
    , bgroup
        "inbox"
        [ inboxScenarioBench store (singleFull metrics)
        , inboxScenarioBench store singleNoMetrics
        , inboxScenarioBench store batch100
        , inboxScenarioBench store singleSlim
        ]
    ]
  where
    hotKey =
        OutboxScenario
            { scenarioName = "hot-key"
            , brokerModel = BrokerModel{invocationMicros = 1000, perRecordMicros = 10}
            , messages = scenarioMessages \_ -> Just "aggregate-hot"
            }
    hotKeyNoLatency =
        OutboxScenario
            { scenarioName = "hot-key-nolatency"
            , brokerModel = BrokerModel{invocationMicros = 0, perRecordMicros = 0}
            , messages = scenarioMessages \_ -> Just "aggregate-hot"
            }
    multiKey =
        OutboxScenario
            { scenarioName = "multi-key"
            , brokerModel = BrokerModel{invocationMicros = 1000, perRecordMicros = 10}
            , messages = scenarioMessages \i -> Just ("aggregate-" <> Text.pack (show (i `mod` 200)))
            }
    singleFull metrics' =
        InboxScenario
            { inboxScenarioName = "single-full"
            , inboxMetrics = Just metrics'
            , inboxPersistence = PersistFullEnvelope
            , inboxBatchSize = Nothing
            , inboxMessages = inboxScenarioMessages
            }
    singleNoMetrics =
        InboxScenario
            { inboxScenarioName = "single-nometrics"
            , inboxMetrics = Nothing
            , inboxPersistence = PersistFullEnvelope
            , inboxBatchSize = Nothing
            , inboxMessages = inboxScenarioMessages
            }
    batch100 =
        InboxScenario
            { inboxScenarioName = "batch-100"
            , inboxMetrics = Nothing
            , inboxPersistence = PersistFullEnvelope
            , inboxBatchSize = Just 100
            , inboxMessages = inboxScenarioMessages
            }
    singleSlim =
        InboxScenario
            { inboxScenarioName = "single-slim"
            , inboxMetrics = Nothing
            , inboxPersistence = PersistDedupeOnly
            , inboxBatchSize = Nothing
            , inboxMessages = inboxScenarioMessages
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
        { messageId = "bench-msg-" <> Text.pack (show i)
        , source = "bench.outbox"
        , destination = "bench.outbox.events.v1"
        , key
        , eventType = "BenchEvent"
        , schemaVersion = 1
        , contentType = ApplicationJson
        , schemaReference = Nothing
        , sourceEventId = Nothing
        , sourceGlobalPosition = Nothing
        , payloadBytes = BS.replicate payloadSize 65
        , occurredAt = fixedOccurredAt
        , causationId = Nothing
        , correlationId = Nothing
        , traceContext = Nothing
        , attributes = Nothing
        }

inboxScenarioMessages :: [(IntegrationEvent, KafkaDeliveryRef)]
inboxScenarioMessages =
    [ ( integrationEvent i (Just ("inbox-key-" <> Text.pack (show i)))
            & #messageId
            .~ ("bench-inbox-msg-" <> Text.pack (show i))
            & #source
            .~ "bench.inbox"
            & #destination
            .~ "bench.inbox.events.v1"
      , KafkaDeliveryRef "bench.inbox.events.v1" 0 (fromIntegral i)
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

runStoreChecked :: Store.KirokuStore -> Eff [Store, Error Store.StoreError, IOE] a -> IO a
runStoreChecked store action = do
    result <- Store.runStoreIO store action
    case result of
        Left err -> fail (show err)
        Right value -> pure value
