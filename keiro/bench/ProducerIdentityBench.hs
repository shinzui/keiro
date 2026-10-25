-- | Compare the pre-plan-164 fresh-ID path with deterministic producer writes.
module ProducerIdentityBench (producerIdentityBenchmarks, runProducerIdentityProbe) where

import BenchSetup (selected, setupTrace)
import Control.Exception (evaluate)
import Control.Monad (forM, forM_, replicateM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sort, sortOn)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Keiro.Integration.Event
import Keiro.Outbox
import Keiro.Outbox.Schema qualified as Schema
import Keiro.Prelude
import Keiro.Test.Postgres (checkpointBenchmarkStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))
import Test.Tasty.Bench (Benchmark, bench, bgroup, nf, nfIO)
import "hasql-transaction" Hasql.Transaction qualified as Tx

producerIdentityBenchmarks :: Store.KirokuStore -> IORef Int -> [Benchmark]
producerIdentityBenchmarks store sequenceRef =
  [ bgroup
      "producer-identity"
      [ bench "derive-v1" $ nf identityText (ProducerEventKey (EventId (UUID.fromWords 0 0 0 1)) 0),
        sqlBench "legacy-fresh-1000" (run True False False),
        freshBench True "deterministic-fresh-1000" (run True True False),
        sqlBench "deterministic-fresh-and-replay-1000" (run True True True),
        sqlBench "legacy-single-tx-per-event-1000" (run False False False),
        freshBench False "deterministic-single-tx-per-event-1000" (run False True False)
      ]
  ]
  where
    sqlBench name action = selected (setupTrace "producer-identity" name "checkpoint=before-warm-up warm-up invocations=3 timed_reset=TRUNCATE" >> checkpointBenchmarkStore store >> replicateM_ 3 action) $ \_ -> bench name (nfIO action)
    freshBench batch name action =
      selected (checkFreshRatio store sequenceRef batch) $ \_ -> sqlBench name action
    run = runProducerWorkload store sequenceRef

-- The diagnostic pairs call precisely the normal benchmark workload, including
-- timed reset, preparation, insert-result checks and transaction boundaries.
runProducerWorkload :: Store.KirokuStore -> IORef Int -> Bool -> Bool -> Bool -> IO ()
runProducerWorkload store sequenceRef batch deterministic replay = do
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
  where
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

-- | Opt-in attribution on the existing isolated producer fixture. Normal
-- full workload and the 1.10 ceiling are shared with the paired guard.
runProducerIdentityProbe :: Store.KirokuStore -> IO ()
runProducerIdentityProbe store = do
  checkpointBenchmarkStore store
  let recorded = [sourceEvent 9001 i | i <- [1 .. 1000]]
      factory = traverse (\event -> enqueueProducerEventTx producer event 0 draft) recorded
      reset = probeTx store (Tx.sql "TRUNCATE keiro.keiro_outbox")
      emit label value = Lazy.putStrLn (Aeson.encode (Aeson.object ["phase" Aeson..= (label :: Text), "data" Aeson..= value]))
      countPhase label expected action = do
        observed <- probeTx store $ do
          before <- producerStatementCounts
          action
          after <- producerStatementCounts
          rows <- producerRows
          unless (rows == 1000) (error "producer probe row count differs")
          pure (subtractCounts after before)
        unless (observed == expected) (fail ("producer statement-count mismatch: " <> show observed))
        emit label (Aeson.toJSON observed)
  reset
  countPhase "fresh-factory-statements-legacy-producer-lookup" (0, 1000, 0) $ do
    outcomes <- factory
    unless (all inserted outcomes) (error "producer probe fresh insert failed")
  stored <- Store.runStoreIO store (Schema.listOutbox "bench.outbox") >>= either (fail . show) pure
  let ordered = sortOn (\row -> (row ^. #event) ^. #sourceGlobalPosition) stored
  template <- case ordered of
    row : _ -> pure (row ^. #event)
    [] -> fail "producer probe has no stored envelope"
  let prepare event =
        let identity = deriveProducerIdentity producer (ProducerEventKey (event ^. #eventId) 0)
            envelope = normalizeProducerEvent (template & #messageId .~ (identity ^. #messageId) & #sourceEventId ?~ (event ^. #eventId) & #sourceGlobalPosition ?~ (event ^. #globalPosition))
         in (identity, envelope)
      prepared = map prepare recorded
  unless (length ordered == 1000 && and [identity ^. #outboxId == row ^. #outboxId && envelope == row ^. #event | ((identity, envelope), row) <- zip prepared ordered]) $
    fail "producer probe equivalent preparation differs from the actual factory"
  _ <- evaluate (forceProducerInputs [(identity ^. #outboxId, event) | (identity, event) <- prepared])
  nativeLegacy <- probeLegacyInputs store recorded
  _ <- evaluate (forceProducerInputs nativeLegacy)
  countPhase "replay-factory-statements-legacy-producer-lookup" (0, 1000, 1000) $ do
    outcomes <- factory
    unless (all duplicate outcomes) (error "producer probe replay failed")
  reset
  countPhase "legacy-same-envelope-statements-legacy-producer-lookup" (1000, 0, 0) $
    traverse_ (\(identity, event) -> Schema.enqueueOutboxTx (OutboxMessage (identity ^. #outboxId) event)) prepared
  for_ [1 .. 5 :: Int] $ \sample -> do
    let inputs = [sourceEvent (9100 + sample) i | i <- [1 .. 1000]]
        deterministicPreparation = evaluate (forceProducerInputs [(identity ^. #outboxId, event) | (identity, event) <- map prepare inputs])
        legacyPreparation = do
          messages <- probeLegacyInputs store inputs
          evaluate (forceProducerInputs messages)
    for_ (if even sample then [("deterministic-equivalent-preparation", deterministicPreparation), ("legacy-actual-preparation", legacyPreparation)] else [("legacy-actual-preparation", legacyPreparation), ("deterministic-equivalent-preparation", deterministicPreparation)]) $ \(label, action) -> do
      started <- getMonotonicTimeNSec
      checksum <- action
      ended <- getMonotonicTimeNSec
      emit label (Aeson.object ["sample" Aeson..= sample, "events" Aeson..= (1000 :: Int), "elapsed_ns" Aeson..= (ended - started), "checksum" Aeson..= checksum])
    for_ [True, False] $ \identicalEnvelopes ->
      for_ [True, False] $ \batch ->
        for_ (if even sample then [True, False] else [False, True]) $ \deterministic -> do
          reset
          let actions
                | deterministic =
                    [ do
                        outcome <- Schema.enqueueProducerOutboxTx identity event
                        unless (inserted outcome) (error "prepared producer probe did not insert")
                    | (identity, event) <- prepared
                    ]
                | identicalEnvelopes = [Schema.enqueueOutboxTx (OutboxMessage (identity ^. #outboxId) event) | (identity, event) <- prepared]
                | otherwise = [Schema.enqueueOutboxTx (OutboxMessage oid event) | (oid, event) <- nativeLegacy]
          started <- getMonotonicTimeNSec
          if batch then probeTx store (sequence_ actions) else traverse_ (probeTx store) actions
          ended <- getMonotonicTimeNSec
          rows <- probeTx store producerRows
          unless (rows == 1000) (fail "prepared producer probe retained wrong rows")
          emit "prepared-enqueue" (Aeson.object ["sample" Aeson..= sample, "identical_envelopes" Aeson..= identicalEnvelopes, "batch" Aeson..= batch, "deterministic" Aeson..= deterministic, "events" Aeson..= rows, "elapsed_ns" Aeson..= (ended - started)])
  counter <- newIORef 0
  for_ [True, False] $ \batch -> do
    pairs <- measureFreshPairs store counter batch
    for_ (zip [1 .. freshPairSamples] pairs) $ \(sample, (legacy, deterministic)) ->
      for_ [(False, legacy), (True, deterministic)] $ \(flag, elapsed) ->
        emit "full-factory" (Aeson.object ["sample" Aeson..= sample, "batch" Aeson..= batch, "deterministic" Aeson..= flag, "events" Aeson..= (1000 :: Int), "elapsed_ns" Aeson..= elapsed])
  where
    inserted ProducerInserted {} = True
    inserted _ = False
    duplicate ProducerDuplicateIdentical {} = True
    duplicate _ = False

-- Compare adjacent full actions in alternating order. Both include their normal
-- reset/preparation/transaction boundaries; all fixed samples remain in the log.
measureFreshPairs :: Store.KirokuStore -> IORef Int -> Bool -> IO [(Double, Double)]
measureFreshPairs store counter batch = do
  checkpointBenchmarkStore store
  for_ [False, True] $ \deterministic ->
    replicateM_ 3 (runProducerWorkload store counter batch deterministic False)
  forM [1 .. freshPairSamples] $ \sample -> do
    values <- forM (if even sample then [True, False] else [False, True]) $ \deterministic -> do
      started <- getMonotonicTimeNSec
      runProducerWorkload store counter batch deterministic False
      ended <- getMonotonicTimeNSec
      rows <- probeTx store producerRows
      unless (rows == 1000 && ended > started) (fail "paired producer workload/count mismatch")
      pure (deterministic, fromIntegral (ended - started))
    case (lookup False values, lookup True values) of
      (Just legacy, Just deterministic) -> pure (legacy, deterministic)
      _ -> fail "paired producer measurement is incomplete"

checkFreshRatio :: Store.KirokuStore -> IORef Int -> Bool -> IO ()
checkFreshRatio store counter batch = do
  pairs <- measureFreshPairs store counter batch
  let ratios = [deterministic / legacy | (legacy, deterministic) <- pairs]
      medianRatio = sort ratios !! (freshPairSamples `div` 2)
  Lazy.putStrLn (Aeson.encode (Aeson.object ["phase" Aeson..= ("producer-fresh-ratio" :: Text), "batch" Aeson..= batch, "pairs_ns_legacy_deterministic" Aeson..= pairs, "median_ratio" Aeson..= medianRatio, "ceiling" Aeson..= freshRatioCeiling]))
  unless (medianRatio <= freshRatioCeiling) $
    fail ("producer fresh median paired ratio " <> show medianRatio <> " exceeds " <> show freshRatioCeiling)

freshPairSamples :: Int
freshPairSamples = 15

freshRatioCeiling :: Double
freshRatioCeiling = 1.10

probeLegacyInputs :: Store.KirokuStore -> [RecordedEvent] -> IO [(OutboxId, IntegrationEvent)]
probeLegacyInputs store inputs =
  Store.runStoreIO
    store
    ( forM inputs $ \event -> do
        oid <- freshOutboxId
        envelope <- freshIntegrationEvent producer (draft & #sourceEventId ?~ (event ^. #eventId) & #sourceGlobalPosition ?~ (event ^. #globalPosition))
        pure (oid, envelope)
    )
    >>= either (fail . show) pure

probeTx :: Store.KirokuStore -> Tx.Transaction a -> IO a
probeTx store action = Store.runStoreIO store (Store.runTransaction action) >>= either (fail . show) pure

producerRows :: Tx.Transaction Int64
producerRows = Tx.statement () (preparable "SELECT count(*) FROM keiro.keiro_outbox" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))

producerStatementCounts :: Tx.Transaction (Int64, Int64, Int64)
producerStatementCounts = do
  rows <- Tx.statement () (preparable "SELECT statement, generic_plans + custom_plans FROM pg_prepared_statements" E.noParams (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.int8))))
  let inserts = [(sql, n) | (sql, n) <- rows, "INSERT INTO keiro.keiro_outbox" `Text.isInfixOf` sql]
      count fragment = sum [n | (sql, n) <- inserts, fragment `Text.isInfixOf` sql]
      lookupCount = sum [n | (sql, n) <- rows, "WHERE outbox_id = $1 OR" `Text.isInfixOf` sql, "FOR UPDATE" `Text.isInfixOf` sql]
  pure (count "ON CONFLICT (source, message_id) DO NOTHING", count "ON CONFLICT DO NOTHING", lookupCount)

subtractCounts :: (Int64, Int64, Int64) -> (Int64, Int64, Int64) -> (Int64, Int64, Int64)
subtractCounts (a, b, c) (x, y, z) = (a - x, b - y, c - z)

-- Force the dynamic identity, provenance and timestamp fields without adding
-- envelope serialization to the preparation estimate.
{-# NOINLINE forceProducerInputs #-}
forceProducerInputs :: [(OutboxId, IntegrationEvent)] -> Int
forceProducerInputs = foldl' step 0
  where
    step total (oid, event) = case event ^. #occurredAt of
      UTCTime day time ->
        day `seq`
          time `seq`
            forceProvenance event `seq`
              (total + Text.length (UUID.toText (unOutboxId oid)) + Text.length (event ^. #messageId) + BS.length (event ^. #payloadBytes))

forceProvenance :: IntegrationEvent -> ()
forceProvenance event =
  (case event ^. #sourceEventId of Nothing -> (); Just (EventId uuid) -> uuid `seq` ()) `seq`
    (case event ^. #sourceGlobalPosition of Nothing -> (); Just (GlobalPosition position) -> position `seq` ())
