{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Preliminary owner-index storage diagnostic, not the complete worker matrix.
-- The named step calls public child/awakeable storage operations, rather than
-- simulating an entire spawned-child worker or external callback delivery.
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, liftIO)
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
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Child.Schema qualified as Child
import Keiro.Workflow.Instance qualified as Instance
import Kiroku.Store.Connection
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.Mem (performMajorGC)

main :: IO ()
main = do
  [output] <- getArgs
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture -> forM_ [1 .. (5 :: Int)] $ \trial ->
    forM_ [False, True] $ \indexed -> withFreshDatabase fixture $ \url -> do
      execute url "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) SELECT 'seed-'||n,'seed','running' FROM generate_series(1,100000) n; INSERT INTO keiro.keiro_workflow_children(child_id,child_name,parent_id,parent_name,await_step) SELECT 'seed-'||n,'seed','seed','seed','await-'||n FROM generate_series(1,100000) n; INSERT INTO keiro.keiro_awakeables(awakeable_id,owner_workflow_name,owner_workflow_id) SELECT ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'seed','seed' FROM generate_series(1,100000) n; ANALYZE keiro.keiro_workflows; ANALYZE keiro.keiro_workflow_children; ANALYZE keiro.keiro_awakeables"
      when indexed (execute url "CREATE INDEX inspection_experiment_child_page ON keiro.keiro_workflow_children(parent_id,parent_name,created_at,child_id,child_name); CREATE INDEX inspection_experiment_awakeable_page ON keiro.keiro_awakeables(owner_workflow_name,owner_workflow_id,created_at,awakeable_id)")
      withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> do
        settings <- use store (Session.statement () (Statement.preparable "SELECT jsonb_build_object('fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'),'server_version',current_setting('server_version'))" E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))))
        durable <- use store (Session.statement () (Statement.preparable "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))
        unless durable (fail "owner-index experiment requires durable settings")
        forM_ [1 .. 50] $ \n -> operation store n >> pure ()
        flush store
        before <- counters store
        performMajorGC
        statsBefore <- getRTSStats
        started <- getMonotonicTimeNSec
        samples <- forM [1 .. 200] $ \n -> do
          now <- getMonotonicTimeNSec
          let due = started + fromIntegral (n - 1) * 20000000
          when (due > now) (threadDelay (fromIntegral ((due - now) `div` 1000)))
          admitted <- getMonotonicTimeNSec
          (schedule, claim, resume) <- operation store (1000 + n)
          pure (if admitted > due then fromIntegral (admitted - due) / 1000 else 0, schedule, claim, resume)
        finished <- getMonotonicTimeNSec
        performMajorGC
        statsAfter <- getRTSStats
        flush store
        after <- counters store
        let durations = sort [q + a + b + c | (q, a, b, c) <- samples]
            percentile p = durations !! min 199 (floor (p * 200))
            elapsed = fromIntegral (finished - started) / 1e9 :: Double
            artifact = object ["trial" .= trial, "experimental_indexes" .= indexed, "settings" .= (settings :: Value), "offered_ops_per_second" .= (50 :: Int), "elapsed_seconds" .= elapsed, "throughput" .= (200 / elapsed), "p50_us" .= percentile 0.5, "p95_us" .= percentile 0.95, "p99_us" .= percentile 0.99, "allocated_bytes" .= (statsAfter.allocated_bytes - statsBefore.allocated_bytes), "before" .= before, "after" .= after, "samples_wait_schedule_claim_resume_us" .= samples]
            path = output </> (show trial <> if indexed then "-candidate.json" else "-baseline.json")
        Lazy.writeFile path (Aeson.encode artifact)
        putStrLn path

operation :: KirokuStore -> Int -> IO (Double, Double, Double)
operation store ident = do
  let wid = "measured-" <> Text.pack (show ident)
      name = WorkflowName "owner-index-evidence"
      identity = WorkflowId wid
      awakeable = UUID.fromWords 0 0 1 (fromIntegral ident)
      checked :: Eff '[Store, Error StoreError, IOE] a -> IO a
      checked action = runStoreIO store action >>= right
  a <- getMonotonicTimeNSec
  checked (runTransaction (Instance.upsertInstanceTx wid "owner-index-evidence" 0 Instance.WfRunning Nothing))
  b <- getMonotonicTimeNSec
  claim <- checked (Instance.claimInstance "index-evidence" 30 name identity)
  unless (claim == Instance.ClaimAcquired) (fail (show claim))
  c <- getMonotonicTimeNSec
  outcome <- checked $ runWorkflow name identity $ step (StepName "relations") $ do
    runTransaction $ do
      Child.registerChildTx wid "child" wid "owner-index-evidence" "result"
      Awakeable.registerAwakeableTx awakeable "owner-index-evidence" wid
    now <- liftIO getCurrentTime
    results <- runTransaction $ (,) <$> Child.markChildResultTx wid "child" (Aeson.toJSON (1 :: Int)) now <*> Awakeable.completeAwakeableTx awakeable (Aeson.toJSON (1 :: Int)) now
    unless (results == (True, True)) (liftIO (fail "expected first relation completion"))
    pure (1 :: Int)
  case outcome of Completed 1 -> pure (); _ -> fail (show outcome)
  checked (Instance.releaseInstance "index-evidence" True name identity)
  d <- getMonotonicTimeNSec
  pure (micros (b - a), micros (c - b), micros (d - c))
  where
    micros ns = fromIntegral ns / 1000

flush :: KirokuStore -> IO ()
flush store = use store (Session.script "SELECT pg_stat_force_next_flush(); SELECT pg_stat_clear_snapshot()")

counters :: KirokuStore -> IO (Text, Value)
counters store = use store (Session.statement () (Statement.preparable "SELECT pg_current_wal_insert_lsn()::text,jsonb_object_agg(relname,jsonb_build_object('updates',n_tup_upd,'hot',n_tup_hot_upd)) FROM pg_stat_user_tables WHERE schemaname='keiro' AND relname IN ('keiro_workflows','keiro_workflow_children','keiro_awakeables')" E.noParams (D.singleRow ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)))))

use :: KirokuStore -> Session.Session a -> IO a
use store session = Pool.use store.pool session >>= right

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

execute :: Text -> Text -> IO ()
execute url sql = bracket (Connection.acquire (Settings.connectionString url) >>= right) Connection.release $ \connection ->
  Connection.use connection (Session.script sql) >>= right
