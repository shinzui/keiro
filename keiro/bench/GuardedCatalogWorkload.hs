{-# LANGUAGE BlockArguments #-}

-- | Identical request preparation, scheduling and measurement for the retained
-- ordinary binary and candidate. No guarded API dependency lives here.
module GuardedCatalogWorkload where

import Control.Concurrent
import Control.Exception (AsyncException (ThreadKilled), finally, fromException)
import Control.Monad
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.ByteString.Lazy qualified as Lazy
import Data.List qualified as List
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Vector qualified as Vector
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import GHC.Clock (getMonotonicTimeNSec)
import GuardedCatalogFixture qualified as Fixture
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Keiro
import Keiro.Prelude
import Keiro.Projection
import Keiro.Test.Postgres
import Kiroku.Store qualified as Store
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (..))
import Kiroku.Store.Types (GlobalPosition (..))
import System.Timeout (timeout)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude

data Workload = Workload
  { cardinality :: Int,
    connections :: Int,
    batchSize :: Int,
    activeWorker :: Bool,
    guardPercent :: Int,
    duplicatePercent :: Int,
    distributed :: Bool,
    arrivalRate :: Maybe Double,
    attempts :: Int,
    deadlineSeconds :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)

data Request = Request
  { requestNumber :: Int,
    guarded :: Bool,
    duplicate :: Bool,
    note :: Fixture.Note,
    payload :: Text
  }

data Sample = Sample
  { number :: Int,
    cohort :: Text,
    accepted :: Bool,
    latencyMicros :: Double,
    occAttempts :: Maybe Int,
    completedSeconds :: Double
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)

data Measurements = Measurements
  { workload :: Workload,
    elapsedSeconds :: Double,
    samples :: [Sample],
    endingCardinality :: Int64,
    committedEvents :: Int64,
    richRows :: Int64,
    headPosition :: Int64,
    workerPosition :: Int64,
    databaseSettings :: Aeson.Value
  }
  deriving stock (Show, Generic)
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)

prepareRequests :: Workload -> [Request]
prepareRequests config = [request n | n <- [0 .. attempts config - 1]]
  where
    request n =
      let isGuard = n `mod` 100 < guardPercent config
          guardOrdinal = (n `div` 100) * guardPercent config + n `mod` 100
          isDuplicate = isGuard && guardOrdinal `mod` 100 < duplicatePercent config
          candidate = "measured-note-" <> Text.pack (show n)
          key = if isDuplicate then "seed-" <> Text.pack (show (if distributed config then 1 + (n * 104729 + 306) `mod` (cardinality config - 100) else 1)) else candidate
          emptyNote = (Fixture.exampleNote candidate key) {Fixture.content = ""}
          overhead = fromIntegral (Lazy.length (Aeson.encode (Aeson.String (Fixture.notePayload emptyNote))))
          note = emptyNote {Fixture.content = Text.replicate (1024 - overhead) "x"}
       in Request n isGuard isDuplicate note (Fixture.notePayload note)

prepareDatabase :: StoreRunner -> Workload -> IO ()
prepareDatabase runner config = do
  durable <- checked runner (Store.runTransaction (Tx.statement () (preparable "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool))))))
  unless durable (fail "benchmark requires fsync, synchronous_commit, full_page_writes and autovacuum enabled")
  Fixture.setup runner
  checked
    runner
    ( Store.runTransaction
        ( Tx.sql
            ( Encoding.encodeUtf8
                ("INSERT INTO app.state_note_identity SELECT 'intention','seed-'||n,'status','ready','seed-note-'||n FROM generate_series(2," <> Text.pack (show (cardinality config - 99)) <> ") n; ANALYZE app.state_note_identity")
            )
        )
    )
  _ <- checked runner (Store.initializeSubscriptionCheckpoint (Store.SubscriptionName "note-rich-worker") 0 FromBeginning)
  -- Exactly 100 accepted ordinary warm-up rows are included in initial size.
  forM_ [1 .. 100 :: Int] \n -> do
    let candidate = "warm-" <> Text.pack (show n)
        -- The repeated shared identity has an explicit committed setup
        -- creator; distributed hits use the declared bootstrap identities.
        note = Fixture.exampleNote candidate (if n == 1 then "seed-1" else candidate)
    ordinaryAction runner (batchSize config) (Request n False False note (Fixture.notePayload note)) >>= \accepted -> unless accepted (fail "warm-up refused")
  checked runner (Store.runTransaction (Tx.sql "ANALYZE app.state_note_identity"))
  when (activeWorker config) (drainWarmup runner (GlobalPosition 0))

ordinaryAction :: StoreRunner -> Int -> Request -> IO Bool
ordinaryAction runner batch request = do
  outcome <- checked runner (runDomainCommandWithCatalogProjections defaultRunCommandOptions (Fixture.handler batch) (stream (Fixture.noteId (note request))) (Fixture.CreateNote (payload request)) Fixture.catalog Fixture.commandSet)
  case outcome of
    Right (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted {}}) -> pure True
    other -> fail ("unexpected ordinary outcome: " <> show other)

measureWorkload :: StoreRunner -> Workload -> (Request -> IO Bool) -> IO Measurements
measureWorkload runner config action = do
  let requests = prepareRequests config
  -- Force all payload preparation outside timing.
  _ <- evaluateRequests requests
  queue <- newMVar requests
  completions <- replicateM (connections config) newEmptyMVar
  asyncDone <- newEmptyMVar
  (_, _, _, _, initialCursor) <- facts runner
  worker <- if activeWorker config then Just <$> forkFinally (drainWorker runner (GlobalPosition initialCursor)) (putMVar asyncDone) else pure Nothing
  start <- getMonotonicTimeNSec
  threads <- forM completions \done -> forkFinally (commandWorker start queue []) (putMVar done)
  result <-
    timeout (deadlineSeconds config * 1000000) (mapM takeMVar completions)
      `finally` mapM_ killThread threads
  end <- getMonotonicTimeNSec
  forM_ worker killThread
  forM_ worker \_ -> do
    outcome <- takeMVar asyncDone
    case outcome of
      Left err -> case fromException err of
        Just ThreadKilled -> pure ()
        _ -> fail ("async worker failed: " <> show err)
      Right () -> fail "async worker exited unexpectedly"
  values <- case result of Nothing -> fail "scheduled work exceeded workload deadline"; Just outcomes -> concat <$> mapM (either (fail . show) pure) outcomes
  unless (length values == attempts config) (fail "missing workload attempts")
  (identityRows, events, richRows, head, cursor) <- facts runner
  settings <- checked runner (Store.runTransaction (Tx.statement () (preparable "SELECT jsonb_object_agg(name, setting)::text FROM pg_settings WHERE name IN ('server_version','fsync','synchronous_commit','full_page_writes','autovacuum','shared_buffers','wal_level','checkpoint_timeout','max_wal_size')" E.noParams (D.singleRow (D.column (D.nonNullable D.text))))))
  databaseSettings <- either fail pure (Aeson.eitherDecodeStrict' (Encoding.encodeUtf8 settings))
  pure (Measurements config (fromIntegral (end - start) / 1e9) values identityRows events richRows head cursor databaseSettings)
  where
    commandWorker start queue samples = do
      request <- modifyMVar queue \case [] -> pure ([], Nothing); x : xs -> pure (xs, Just x)
      case request of
        Nothing -> pure samples
        Just request -> do
          let scheduled = case arrivalRate config of
                Nothing -> Nothing
                Just rate -> Just (start + floor (fromIntegral (requestNumber request) / rate * 1e9))
          forM_ scheduled \arrival -> do
            now <- getMonotonicTimeNSec
            when (arrival > now) (threadDelay (fromIntegral ((arrival - now) `div` 1000)))
          submitted <- getMonotonicTimeNSec
          accepted <- action request
          unless (accepted == not (duplicate request)) (fail "unexpected accepted/refused schedule outcome")
          completed <- getMonotonicTimeNSec
          let origin = fromMaybe submitted scheduled
              cohort = if guarded request then if accepted then "guarded-accepted" else "guarded-refused" else "ordinary"
          commandWorker start queue (Sample (requestNumber request) cohort accepted (fromIntegral (completed - origin) / 1000) Nothing (fromIntegral (completed - start) / 1e9) : samples)

evaluateRequests :: [Request] -> IO Int
evaluateRequests requests = do
  forM_ requests \request -> unless (Lazy.length (Aeson.encode (Aeson.String (payload request))) == 1024 && length (Fixture.tags (note request)) == 4) (fail "creation payload is not exactly 1 KiB with four tags")
  pure $! sum [Text.length (payload request) | request <- requests]

checked :: StoreRunner -> Eff '[Store.Store, Error Store.StoreError, Store.KirokuStoreResource, IOE] a -> IO a
checked (StoreRunner run) action = run action >>= either (fail . show) pure

drainWorker :: StoreRunner -> GlobalPosition -> IO ()
drainWorker runner cursor = do
  events <- checked runner (Store.readAllForward cursor 500)
  if Vector.null events
    then threadDelay 1000 >> drainWorker runner cursor
    else do
      forM_ events \recorded -> do
        outcome <- checked runner (Store.runTransaction (applyAsyncProjectionFromCatalog Fixture.catalog Fixture.richOwner Fixture.richProjection recorded))
        unless (outcome == CatalogAsyncApplied || outcome == CatalogAsyncDuplicate) (fail ("async delivery fault: " <> show outcome))
      let next = Vector.last events ^. #globalPosition
      checked runner (Store.runTransaction (Store.resetSubscriptionCheckpointsTx (Store.SubscriptionName "note-rich-worker" :| []) next))
      drainWorker runner next

drainWarmup :: StoreRunner -> GlobalPosition -> IO ()
drainWarmup runner cursor = do
  events <- checked runner (Store.readAllForward cursor 500)
  unless (Vector.null events) do
    forM_ events \recorded -> do
      outcome <- checked runner (Store.runTransaction (applyAsyncProjectionFromCatalog Fixture.catalog Fixture.richOwner Fixture.richProjection recorded))
      unless (outcome == CatalogAsyncApplied || outcome == CatalogAsyncDuplicate) (fail ("warm-up delivery fault: " <> show outcome))
    let next = Vector.last events ^. #globalPosition
    checked runner (Store.runTransaction (Store.resetSubscriptionCheckpointsTx (Store.SubscriptionName "note-rich-worker" :| []) next))
    drainWarmup runner next

facts runner =
  checked
    runner
    ( Store.runTransaction
        ( Tx.statement
            ()
            ( preparable
                "SELECT (SELECT count(*) FROM app.state_note_identity), (SELECT count(*) FROM stream_events WHERE stream_id = 0), (SELECT count(*) FROM app.state_notes), (SELECT stream_version FROM streams WHERE stream_id = 0), COALESCE((SELECT min(last_seen) FROM subscriptions WHERE subscription_name = 'note-rich-worker'),0)"
                E.noParams
                (D.singleRow ((,,,,) <$> col <*> col <*> col <*> col <*> col))
            )
        )
    )
  where
    col = D.column (D.nonNullable D.int8)

summarize :: Measurements -> Aeson.Value
summarize result =
  Aeson.object
    [ "attempts" Aeson..= length (samples result),
      "accepted" Aeson..= length (filter accepted (samples result)),
      "refused" Aeson..= length (filter (not . accepted) (samples result)),
      "attemptThroughput" Aeson..= (fromIntegral (length (samples result)) / elapsedSeconds result),
      "cohorts" Aeson..= Aeson.object [AesonKey.fromText name Aeson..= latencySummary [latencyMicros sample | sample <- samples result, cohort sample == name] | name <- ["ordinary", "guarded-accepted", "guarded-refused"]]
    ]

latencySummary :: [Double] -> Aeson.Value
latencySummary [] = Aeson.Null
latencySummary values = Aeson.object ["count" Aeson..= length values, "p50" Aeson..= percentile 0.50 values, "p95" Aeson..= percentile 0.95 values, "p99" Aeson..= percentile 0.99 values, "maximum" Aeson..= maximum values]

percentile :: Double -> [Double] -> Double
percentile fraction values = List.sort values !! min (length values - 1) (floor (fraction * fromIntegral (length values)))
