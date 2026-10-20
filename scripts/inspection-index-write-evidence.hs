{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Index-only experiment on durable, disposable clones. Uses the same runtime
-- binary in alternating legs; it does not replace the cohort's old/new binary
-- interference and allocation experiment. Supply OUTPUT_DIRECTORY.
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import GHC.Clock (getMonotonicTimeNSec)
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

main :: IO ()
main = do
  [output] <- getArgs
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture ->
    forM_ [1 .. (5 :: Int)] $ \trial ->
      forM_ [False, True] $ \creationIndex -> withFreshDatabase fixture $ \url -> do
        execute url "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) SELECT 'seed-'||n,'seed','running' FROM generate_series(1,100000) n; ANALYZE keiro.keiro_workflows"
        unless creationIndex (execute url "DROP INDEX keiro.keiro_workflows_created_idx")
        withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> do
          settings <- use store (Session.statement () (Statement.preparable "SELECT jsonb_build_object('fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'),'server_version',current_setting('server_version'))" E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))))
          durable <- use store (Session.statement () (Statement.preparable "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))
          unless durable (fail "index experiment requires normal durable settings")
          forM_ [1 .. 50] $ \n -> operation store ("warm-" <> number n) >> pure ()
          flush store
          before <- counters store
          started <- getMonotonicTimeNSec
          samples <- forM [1 .. 200] $ \n -> do
            now <- getMonotonicTimeNSec
            let due = started + fromIntegral (n - 1) * 20000000
            if due > now then threadDelay (fromIntegral ((due - now) `div` 1000)) else pure ()
            admitted <- getMonotonicTimeNSec
            (schedule, claim, resume) <- operation store ("measured-" <> number n)
            let waiting = if admitted > due then fromIntegral (admitted - due) / 1000 else 0
            pure (waiting, schedule, claim, resume)
          finished <- getMonotonicTimeNSec
          flush store
          after <- counters store
          let elapsed = fromIntegral (finished - started) / 1e9 :: Double
              durations = map (\(q, a, b, c) -> q + a + b + c) samples
              percentile p = sort durations !! min 199 (floor (p * 200))
              artifact = object ["trial" .= trial, "creation_index" .= creationIndex, "settings" .= (settings :: Value), "offered_ops_per_second" .= (50 :: Int), "elapsed_seconds" .= elapsed, "throughput" .= (200 / elapsed), "p50_us" .= percentile 0.5, "p95_us" .= percentile 0.95, "p99_us" .= percentile 0.99, "before" .= before, "after" .= after, "samples_wait_schedule_claim_resume_us" .= samples]
              path = output </> (show trial <> if creationIndex then "-candidate.json" else "-baseline.json")
          Lazy.writeFile path (Aeson.encode artifact)
          putStrLn path

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
