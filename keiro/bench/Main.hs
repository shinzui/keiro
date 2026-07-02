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
import Keiro.Test.Postgres (withFreshStore, withMigratedSuite)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
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

main :: IO ()
main =
    withMigratedSuite \fixture ->
        withFreshStore fixture \store ->
            defaultMain (benchmarks store)

benchmarks :: Store.KirokuStore -> [Benchmark]
benchmarks store =
    [ bgroup
        "outbox"
        [ scenarioBench store hotKey
        , scenarioBench store hotKeyNoLatency
        , scenarioBench store multiKey
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
