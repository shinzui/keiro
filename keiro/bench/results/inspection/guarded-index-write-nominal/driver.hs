{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Final workflow inspection schema-only write diagnostic on disposable clones.
-- Supply OUTPUT [nominal|wide-nominal|crash-counter] [SAMPLES], default 1000.
-- Run with +RTS -N2 -T -RTS. This is not an old/new runtime cohort comparison.
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (RTSStats (..), getRTSStats)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Test.Postgres
import Keiro.Workflow
import Keiro.Workflow.Instance qualified as Instance
import Kiroku.Store.Connection
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.Mem (performMajorGC)
import Text.Read (readMaybe)

main :: IO ()
main = do
  (output, profile, sampleCount) <-
    getArgs >>= \case
      [path, workload] | workload `elem` profiles -> pure (path, workload, 1000)
      [path, workload, raw] | workload `elem` profiles, Just count <- readMaybe raw, count > 0 -> pure (path, workload, count)
      _ -> fail "expected OUTPUT [nominal|wide-nominal|crash-counter] [SAMPLES]"
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture ->
    forM_ [1 .. (5 :: Int)] $ \trial ->
      forM_ [False, True] $ \candidate -> withFreshDatabase fixture $ \url -> do
        execute url "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) SELECT 'seed-'||n,'seed','running' FROM generate_series(1,100000) n; ANALYZE keiro.keiro_workflows"
        unless candidate (execute url "DROP INDEX keiro.keiro_workflows_created_idx; ALTER TABLE keiro.keiro_workflows DROP COLUMN inspection_status_class CASCADE")
        -- Rewrite both legs after schema selection. The baseline removes only
        -- unreleased inspection objects; it still uses the same runtime binary.
        execute url "VACUUM FULL keiro.keiro_workflows"
        execute url "ANALYZE keiro.keiro_workflows"
        when (profile == "crash-counter") (execute url "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) VALUES ('counter','index-evidence','running')")
        withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> do
          settings <- use store (Session.statement () (Statement.preparable "SELECT jsonb_build_object('fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'),'server_version',current_setting('server_version'),'block_size',current_setting('block_size'))" E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))))
          durable <- use store (Session.statement () (Statement.preparable "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))
          unless durable (fail "index experiment requires normal durable settings")
          let run prefix n = if profile == "crash-counter" then crashCounterOperation store n else operation store ((if profile == "wide-nominal" then Text.replicate 2700 "x" else "") <> prefix <> number n)
          forM_ [1 .. 50] $ \n -> run "warm-" n >> pure ()
          when (profile == "crash-counter") (runStoreIO store (Instance.resetInstanceAttempts (WorkflowName "index-evidence") (WorkflowId "counter")) >>= right)
          flush store
          before <- counters store
          performMajorGC
          statsBefore <- getRTSStats
          started <- getMonotonicTimeNSec
          samples <- forM [1 .. sampleCount] $ \n -> do
            now <- getMonotonicTimeNSec
            let due = started + fromIntegral (n - 1) * 20000000
            if due > now then threadDelay (fromIntegral ((due - now) `div` 1000)) else pure ()
            admitted <- getMonotonicTimeNSec
            (schedule, claim, resume) <- run "measured-" n
            let waiting = if admitted > due then fromIntegral (admitted - due) / 1000 else 0
            pure (waiting, schedule, claim, resume)
          finished <- getMonotonicTimeNSec
          performMajorGC
          statsAfter <- getRTSStats
          flush store
          after <- counters store
          let elapsed = fromIntegral (finished - started) / 1e9 :: Double
              durations = map (\(q, a, b, c) -> q + a + b + c) samples
              percentile p = sort durations !! min (sampleCount - 1) (floor (p * fromIntegral sampleCount))
              artifact = object ["trial" .= trial, "candidate" .= candidate, "schema_only" .= True, "sample_count" .= sampleCount, "profile" .= profile, "settings" .= (settings :: Value), "offered_ops_per_second" .= (50 :: Int), "elapsed_seconds" .= elapsed, "throughput" .= (fromIntegral sampleCount / elapsed), "p50_us" .= percentile 0.5, "p95_us" .= percentile 0.95, "p99_us" .= percentile 0.99, "allocated_bytes" .= (statsAfter.allocated_bytes - statsBefore.allocated_bytes), "cpu_ns" .= (statsAfter.cpu_ns - statsBefore.cpu_ns), "before" .= before, "after" .= after, "samples_wait_schedule_claim_resume_us" .= samples]
              path = output </> (show trial <> if candidate then "-candidate.json" else "-baseline.json")
          Lazy.writeFile path (Aeson.encode artifact)
          putStrLn path

crashCounterOperation :: KirokuStore -> Int -> IO (Double, Double, Double)
crashCounterOperation store iteration = do
  started <- getMonotonicTimeNSec
  count <- runStoreIO store (runTransaction (Instance.recordCrashTx "counter" "index-evidence" "same failure")) >>= right
  case count of Just _ -> pure (); Nothing -> fail "crash diagnostic row became terminal"
  when (iteration `mod` 20 == 0) (runStoreIO store (Instance.resetInstanceAttempts (WorkflowName "index-evidence") (WorkflowId "counter")) >>= right)
  finished <- getMonotonicTimeNSec
  pure (0, 0, fromIntegral (finished - started) / 1000)

-- Returns schedule/claim/resume phase durations. The resume performs a real
-- named step and completion, then releases its advance lease.
operation :: KirokuStore -> Text -> IO (Double, Double, Double)
operation store wid = do
  let name = WorkflowName "index-evidence"
      identity = WorkflowId wid
      checked :: Eff '[Store, Error StoreError, IOE] a -> IO a
      checked action = runStoreIO store action >>= right
  a <- getMonotonicTimeNSec
  checked (runTransaction (Instance.upsertInstanceTx wid "index-evidence" 0 Instance.WfRunning Nothing))
  b <- getMonotonicTimeNSec
  claim <- checked (Instance.claimInstance "index-evidence" 30 name identity)
  unless (claim == Instance.ClaimAcquired) (fail (show claim))
  c <- getMonotonicTimeNSec
  outcome <- checked (runWorkflow name identity (step (StepName "work") (pure (1 :: Int))))
  case outcome of Completed 1 -> pure (); _ -> fail (show outcome)
  checked (Instance.releaseInstance "index-evidence" True name identity)
  d <- getMonotonicTimeNSec
  pure (micros (b - a), micros (c - b), micros (d - c))
  where
    micros ns = fromIntegral ns / 1000

flush :: KirokuStore -> IO ()
flush store = use store (Session.script "SELECT pg_stat_force_next_flush(); SELECT pg_stat_clear_snapshot()")

counters :: KirokuStore -> IO (Text, Int, Int)
counters store = use store (Session.statement () (Statement.preparable "SELECT pg_current_wal_insert_lsn()::text,n_tup_upd,n_tup_hot_upd FROM pg_stat_user_tables WHERE schemaname='keiro' AND relname='keiro_workflows'" E.noParams (D.singleRow ((,,) <$> D.column (D.nonNullable D.text) <*> (fromIntegral <$> D.column (D.nonNullable D.int8)) <*> (fromIntegral <$> D.column (D.nonNullable D.int8))))))

number :: Int -> Text
number = Text.pack . show

use :: KirokuStore -> Session.Session a -> IO a
use store session = Pool.use store.pool session >>= right

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

execute :: Text -> Text -> IO ()
execute url sql = bracket (Connection.acquire (Settings.connectionString url) >>= right) Connection.release $ \connection ->
  Connection.use connection (Session.script sql) >>= right

profiles :: [String]
profiles = ["nominal", "wide-nominal", "crash-counter"]
