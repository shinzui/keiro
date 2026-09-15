-- | Compare the pre-plan-164 fresh-ID path with deterministic producer writes.
module ProducerIdentityBench (producerIdentityBenchmarks) where

import Control.Monad (forM, forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef')
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Keiro.Integration.Event
import Keiro.Outbox
import Keiro.Prelude
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))
import Test.Tasty.Bench (Benchmark, bcompareWithin, bench, bgroup, nf, nfIO)
import "hasql-transaction" Hasql.Transaction qualified as Tx

producerIdentityBenchmarks :: Store.KirokuStore -> IORef Int -> [Benchmark]
producerIdentityBenchmarks store sequenceRef =
  [ bgroup
      "producer-identity"
      [ bench "derive-v1" $ nf identityText (ProducerEventKey (EventId (UUID.fromWords 0 0 0 1)) 0),
        bench "legacy-fresh-1000" $ nfIO (run True False False),
        bcompareWithin 0 1.10 "$0 == \"All.producer-identity.legacy-fresh-1000\"" $ bench "deterministic-fresh-1000" $ nfIO (run True True False),
        bench "deterministic-fresh-and-replay-1000" $ nfIO (run True True True),
        bench "legacy-single-tx-per-event-1000" $ nfIO (run False False False),
        bcompareWithin 0 1.10 "$0 == \"All.producer-identity.legacy-single-tx-per-event-1000\"" $ bench "deterministic-single-tx-per-event-1000" $ nfIO (run False True False)
      ]
  ]
  where
    run batch deterministic replay = do
      generation <- atomicModifyIORef' sequenceRef (\n -> (n + 1, n + 1))
      result <- Store.runStoreIO store $ do
        Store.runTransaction (Tx.sql "TRUNCATE keiro.keiro_outbox")
        let recorded = [sourceEvent generation i | i <- [1 .. 1000]]
        if deterministic
          then do
            let actions = fmap (\event -> enqueueProducerEventTx producer event 0 draft) recorded
            if batch
              then do
                first <- Store.runTransaction (sequence actions)
                unless (all isInserted first) (error "producer benchmark failed to insert")
              else forM_ actions $ \action -> do
                outcome <- Store.runTransaction action
                unless (isInserted outcome) (error "producer benchmark failed to insert")
            when replay $ do
              second <- Store.runTransaction (sequence actions)
              unless (all isDuplicate second) (error "producer benchmark failed to replay")
          else do
            -- Match the old helper's preparation boundary: bulk preparation
            -- for bulk SQL, and preparation immediately before each individual
            -- transaction for the normal subscription path.
            let prepare event = do
                  oid <- freshOutboxId
                  envelope <- freshIntegrationEvent producer (draft & #sourceEventId ?~ event ^. #eventId & #sourceGlobalPosition ?~ event ^. #globalPosition)
                  pure (oid, envelope)
            if batch
              then do
                messages <- forM recorded prepare
                Store.runTransaction (traverse_ (uncurry enqueueIntegrationEventTx) messages)
              else forM_ recorded $ \event -> do
                message <- prepare event
                Store.runTransaction (uncurry enqueueIntegrationEventTx message)
      case result of
        Left err -> fail (show err)
        Right () -> pure ()
    isInserted ProducerInserted {} = True
    isInserted _ = False
    isDuplicate ProducerDuplicateIdentical {} = True
    isDuplicate _ = False

producer :: IntegrationProducer ()
producer = IntegrationProducer "bench-producer" "bench.outbox" "msg" (\_ _ -> Just draft)

draft :: IntegrationEventDraft
draft =
  IntegrationEventDraft
    { destination = "bench.outbox.events.v1",
      key = Just "key",
      eventType = "BenchEvent",
      schemaVersion = 1,
      contentType = ApplicationJson,
      schemaReference = Nothing,
      sourceEventId = Nothing,
      sourceGlobalPosition = Nothing,
      payloadBytes = BS.replicate 1024 65,
      occurredAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0),
      causationId = Nothing,
      correlationId = Nothing,
      traceContext = Nothing,
      attributes = Nothing
    }

sourceEvent :: Int -> Int -> RecordedEvent
sourceEvent generation i =
  RecordedEvent
    { eventId = EventId (UUID.fromWords 0 (fromIntegral generation) 0 (fromIntegral i)),
      eventType = EventType "BenchEvent",
      streamVersion = StreamVersion (fromIntegral i),
      globalPosition = GlobalPosition (fromIntegral i),
      originalStreamId = StreamId 1,
      originalVersion = StreamVersion (fromIntegral i),
      payload = Aeson.Null,
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
    }

-- Force both identifiers, including the UUID projection, in the pure benchmark.
identityText :: ProducerEventKey -> (Text, Text)
identityText key =
  let identity = deriveProducerIdentity producer key
   in (UUID.toText (unOutboxId (identity ^. #outboxId)), identity ^. #messageId)
