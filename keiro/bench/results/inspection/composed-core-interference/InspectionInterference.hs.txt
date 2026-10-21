{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Durable writer profile. KEIRO_INSPECTION_BASELINE compiles the same writer
-- against pre-inspection packages without requiring the new HTTP package.
-- Supply OUTPUT_DIRECTORY [saturation|OPS_PER_SECOND] [TRIALS] [MODE].
-- Run with +RTS -N2 -T -RTS; this is not the full domain workload matrix.
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as LazyChar8Portable
#ifndef KEIRO_INSPECTION_BASELINE
import InspectionClients (runClients)
#endif
import Data.ByteString qualified as Bytes
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUIDv5
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (ThreadStatus (..), getAllocationCounter, listThreads, threadStatus)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
#ifndef KEIRO_INSPECTION_BASELINE
import Keiro.Ops qualified as Ops
import Keiro.Ops.Http
#endif
import Keiro.ReadModel (registerReadModel)
import Keiro.Test.Postgres
import Keiro.Timer qualified as Timer
import Keiro.Workflow
import Keiro.Workflow.Instance qualified as Instance
import Kiroku.Store.Connection
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getExecutablePath, lookupEnv, withArgs)
import System.IO (IOMode (WriteMode), hFlush, withFile)
#ifndef KEIRO_INSPECTION_BASELINE
import System.Exit (ExitCode (..))
import System.IO (hClose, hGetLine, hPutStrLn)
#endif
import System.FilePath ((</>))
import System.Mem (performMajorGC)
#ifndef KEIRO_INSPECTION_BASELINE
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, readProcessWithExitCode, terminateProcess, waitForProcess)
#endif
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
#ifndef KEIRO_INSPECTION_BASELINE
  case args of
    "--clients" : rest -> runClients rest
    _ -> withArgs (translate args) benchmark
#else
  withArgs (translate args) benchmark
#endif

-- Named options for cabal bench, retaining positional arguments for matched runs.
translate :: [String] -> [String]
translate args
  | "--mode" `elem` args = [option "--output" "inspection-results", option "--rate" "100", option "--trials" "1", option "--mode" "disabled"]
  | otherwise = args
  where
    option key fallback = case dropWhile (/= key) args of _ : value : _ -> value; _ -> fallback

benchmark :: IO ()
benchmark = do
  (output, loadArgument, trialsArgument, modeArgument) <-
    getArgs >>= \case
      [path] -> pure (path, "50", "5", "all")
      [path, load] -> pure (path, load, "5", "all")
      [path, load, trials] -> pure (path, load, trials, "all")
      [path, load, trials, mode] -> pure (path, load, trials, mode)
      _ -> fail "expected OUTPUT_DIRECTORY [saturation|OPS_PER_SECOND] [TRIALS] [MODE]"
  offeredRate <- case loadArgument of
    "saturation" -> pure Nothing
    raw | Just rate <- readMaybe raw, rate > 0, rate <= (1000 :: Int) -> pure (Just rate)
    _ -> fail "offered rate must be 1..1000 or saturation"
  trialCount <- case readMaybe trialsArgument of
    Just count | count > 0, count <= (100 :: Int) -> pure count
    _ -> fail "trials must be 1..100"
  selectedModes <- case modeArgument of
    "all" -> pure inspectionModes
    mode | Text.pack mode `elem` inspectionModes -> pure [Text.pack mode]
    _ -> fail "mode is unavailable in this binary"
  retentionSeconds <-
    lookupEnv "KEIRO_INSPECTION_RETENTION_SECONDS" >>= \case
      Nothing -> pure Nothing
      Just raw | Just seconds <- readMaybe raw, seconds >= 60, seconds <= (3600 :: Int), mod seconds 5 == 0 -> pure (Just seconds)
      _ -> fail "KEIRO_INSPECTION_RETENTION_SECONDS must be 60..3600 and divisible by 5"
  unless (retentionSeconds == Nothing || offeredRate /= Nothing) (fail "retention mode requires a paced offered rate")
  configuredSeconds <- lookupEnv "KEIRO_INSPECTION_SECONDS"
  let duration = maybe (maybe 20 id (configuredSeconds >>= readMaybe)) id retentionSeconds
      sampleCount = maybe 1000 (* duration) offeredRate
      modes = maybe ["disabled"] (const selectedModes) offeredRate
  enabled <- getRTSStatsEnabled
  unless enabled (fail "run with +RTS -T")
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture ->
    forM_ [1 .. trialCount] $ \trial ->
      forM_ modes $ \mode -> withFreshDatabase fixture $ \url -> do
        execute url "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) SELECT 'seed-'||n,'seed-'||(n%31),'running' FROM generate_series(1,100000) n; ANALYZE keiro.keiro_workflows"
        execute url "UPDATE keiro.keiro_workflows SET last_error=repeat('x',65536) WHERE workflow_id=(SELECT workflow_id FROM keiro.keiro_workflows WHERE workflow_name='seed-0' ORDER BY workflow_id LIMIT 1)"
        execute url "INSERT INTO keiro.keiro_timers(timer_id,process_manager_name,correlation_id,fire_at,payload,status) SELECT ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'seed-timer','corr-'||(n%100),'2100-01-01'::timestamptz+n*interval '1 second',CASE WHEN n=2 THEN to_jsonb(repeat('x',65536)) ELSE jsonb_build_object('n',n) END,CASE WHEN n%4=0 THEN 'fired' WHEN n%8=1 THEN 'firing' ELSE 'scheduled' END FROM generate_series(1,100000) n; ANALYZE keiro.keiro_timers"
        withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> withMount store url mode $ \app -> do
          _ <- runStoreIO store (registerReadModel "inspection-benchmark" 1 "shape") >>= right
          settings <- use store (Session.statement () (Statement.preparable "SELECT jsonb_build_object('fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'),'server_version',current_setting('server_version'))" E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))))
          durable <- use store (Session.statement () (Statement.preparable "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))
          unless durable (fail "index experiment requires normal durable settings")
          -- Finish the 100k-row setup's dirty-page writes before warm-up.
          -- Both package sets execute this same explicit checkpoint; normal
          -- durable settings and autovacuum stay enabled during measurement.
          use store (Session.script "CHECKPOINT")
          forM_ [1 .. 50] $ \n -> operation store ("warm-" <> number n) >> pure ()
          lifecycleBefore <- if retentionSeconds /= Nothing then Just <$> heapSample "mounted-before-pollers" 0 else pure Nothing
          ((samples, statsBefore, started, before), pollSuccess, pollFailure) <- withPollers app mode duration $ \startPolling -> do
            -- Let warm writer notifications settle in every mode, including
            -- the baseline, before capturing counters and the measurement clock.
            threadDelay 1000000
            flush store
            before <- counters store
            performMajorGC
            statsBefore <- getRTSStats
            started <- getMonotonicTimeNSec
            startPolling
            let measured n = do
                  now <- getMonotonicTimeNSec
                  let due = maybe now (\rate -> started + fromIntegral (n - 1) * div 1000000000 (fromIntegral rate)) offeredRate
                  when (due > now) (threadDelay (fromIntegral (div (due - now) 1000)))
                  admitted <- getMonotonicTimeNSec
                  (schedule, claim, resume, timer, allocation) <- operation store ("measured-" <> Text.justifyRight 9 '0' (number (sampleCount - n)))
                  let waiting = if offeredRate /= Nothing && admitted > due then fromIntegral (admitted - due) / 1000 else 0
                  pure (waiting, schedule, claim, resume, timer, allocation)
            samples <- case retentionSeconds of
              Nothing -> forM [1 .. sampleCount] measured
              Just _ -> withFile (output </> (show trial <> "-" <> Text.unpack mode <> "-heap.jsonl")) WriteMode $ \handle -> do
                let emit phase n = do
                      value <- heapSample phase n
                      LazyChar8Portable.hPutStrLn handle (Aeson.encode value)
                      hFlush handle
                emit "before-running" 0
                -- Discard every per-operation timing. Retaining a latency list
                -- would itself create a false positive live-heap trend.
                forM_ [1 .. sampleCount] $ \n -> do
                  void (measured n)
                  when (mod n (maybe 1 (* 5) offeredRate) == 0) (emit "running" n)
                pure []
            pure (samples, statsBefore, started, before)
          finished <- getMonotonicTimeNSec
          performMajorGC
          statsAfter <- getRTSStats
          flush store
          after <- counters store
          resourcesAfter <- traverse (\(_, sample) -> sample True) app
          lifecycleAfter <- case retentionSeconds of
            Nothing -> pure Nothing
            Just _ -> do
              threadDelay 12000000
              Just <$> heapSample "mounted-after-poller-cleanup-and-drain" sampleCount
          let elapsed = fromIntegral (finished - started) / 1e9 :: Double
              durations = map (\(q, a, b, c, d, _) -> q + a + b + c + d) samples
              percentile p = if null durations then Nothing else Just (sort durations !! min (sampleCount - 1) (floor (p * fromIntegral sampleCount)))
              (views, clients) = pollingShape mode
              artifact = object ["resources_after_clients" .= resourcesAfter, "trial" .= trial, "retention_seconds" .= retentionSeconds, "lifecycle_before" .= lifecycleBefore, "lifecycle_after" .= lifecycleAfter, "mode" .= mode, "views" .= views, "clients" .= clients, "poll_success" .= pollSuccess, "poll_failure" .= pollFailure, "writer_thread_allocated_bytes_per_operation" .= (if null samples then Nothing else Just (sum [allocated | (_, _, _, _, _, allocated) <- samples] / fromIntegral sampleCount)), "allocated_bytes" .= (statsAfter.allocated_bytes - statsBefore.allocated_bytes), "cpu_ns" .= (statsAfter.cpu_ns - statsBefore.cpu_ns), "settings" .= (settings :: Value), "offered_ops_per_second" .= offeredRate, "elapsed_seconds" .= elapsed, "throughput" .= (fromIntegral sampleCount / elapsed), "p50_us" .= percentile 0.5, "p95_us" .= percentile 0.95, "p99_us" .= percentile 0.99, "before" .= before, "after" .= after, "samples_wait_schedule_claim_resume_timer_us_writer_bytes" .= samples]
              path = output </> (show trial <> "-" <> Text.unpack mode <> ".json")
          Lazy.writeFile path (Aeson.encode artifact)
          putStrLn path

-- Equal operation-block samples after major GC, including active threads and
-- large objects. The JSONL output is streamed and never retained in a list.
heapSample :: Text -> Int -> IO Value
heapSample phase completed = do
  performMajorGC
  stats <- getRTSStats
  statuses <- listThreads >>= traverse threadStatus
  let active ThreadFinished = False
      active ThreadDied = False
      active _ = True
  pure (object ["phase" .= phase, "operations" .= completed, "live_bytes" .= stats.gc.gcdetails_live_bytes, "large_object_bytes" .= stats.gc.gcdetails_large_objects_bytes, "active_threads" .= length (filter active statuses)])

-- Returns schedule/claim/resume phase durations. The resume performs a real
-- named step and completion, then releases its advance lease.
operation :: KirokuStore -> Text -> IO (Double, Double, Double, Double, Double)
operation store wid = do
  let name = WorkflowName "index-evidence"
      identity = WorkflowId wid
      checked :: Eff '[Store, Error StoreError, IOE] a -> IO a
      checked action = runStoreIO store action >>= right
  allocationBefore <- getAllocationCounter
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
  now <- getCurrentTime
  let timerId = Timer.TimerId (UUIDv5.generateNamed UUIDv5.namespaceURL (Bytes.unpack (Text.encodeUtf8 wid)))
  checked (runTransaction (Timer.scheduleTimerTx (Timer.TimerRequest timerId "index-evidence" wid now Aeson.Null)))
  claimed <- checked (Timer.claimDueTimer now)
  unless (maybe False (\row -> row.timerId == timerId) claimed) (fail "timer was not claimed")
  fired <- checked (Timer.markTimerFired timerId (EventId UUID.nil))
  unless fired (fail "timer was not fired")
  e <- getMonotonicTimeNSec
  allocationAfter <- getAllocationCounter
  pure (micros (b - a), micros (c - b), micros (d - c), micros (e - d), fromIntegral (allocationBefore - allocationAfter))
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

withMount :: KirokuStore -> Text -> Text -> (Maybe (Int, Bool -> IO Value) -> IO a) -> IO a
#ifdef KEIRO_INSPECTION_BASELINE
withMount _ _ _ action = action Nothing

inspectionModes :: [Text]
inspectionModes = ["disabled"]

withPollers :: Maybe (Int, Bool -> IO Value) -> Text -> Int -> (IO () -> IO a) -> IO (a, Int, Int)
withPollers _ _ _ action = do
  result <- action (pure ())
  pure (result, 0, 0)
#else
withMount store url mode action
  | mode == "disabled" = action Nothing
  | otherwise = withOpsInspectionPool defaultInspectionLimits (defaultConnectionSettings url) $ \pool -> do
      let inspected = store {pool = pool}
      withFeedHandle defaultOpsHttpConfig defaultFeedConfig inspected $ \feeds -> do
        child <- opsApplicationWithFeeds defaultOpsHttpConfig feeds Ops.emptyAppHooks inspected
        app <- either (fail . show) pure (composeSurfaces defaultComposeConfig [MountedSurface keiroPrefix child])
        withOpsHttpServer defaultOpsHttpServerConfig {port = 0} app $ \server -> action (Just (server.serverPort, resourceSample feeds))

resourceSample :: FeedHandle -> Bool -> IO Value
resourceSample handle awaitCleanup = loop (if awaitCleanup then 200 else 0 :: Int)
  where
    loop attempts = do
      stats <- feedStats handle
      if awaitCleanup && (stats.activeViews /= 0 || stats.activeConnections /= 0 || stats.wakePumpRunning) && attempts > 0
        then threadDelay 10000 >> loop (attempts - 1)
        else do
          when (awaitCleanup && (stats.activeViews /= 0 || stats.activeConnections /= 0 || stats.wakePumpRunning)) (fail "feed resources did not return to idle")
          pure (object ["views" .= stats.activeViews, "connections" .= stats.activeConnections, "wake_pump" .= stats.wakePumpRunning])

withPollers :: Maybe (Int, Bool -> IO Value) -> Text -> Int -> (IO () -> IO a) -> IO (a, Int, Int)
withPollers mount mode seconds action = case mount of
  Just (serverPort, _) | clients > 0 -> do
    executable <- getExecutablePath
    let child = (proc executable ["--clients", show serverPort, show clients, show views, show seconds, Text.unpack mode]) {std_in = CreatePipe, std_out = CreatePipe}
        cleanup (input, output, errors, process) = do
          terminateProcess process
          _ <- waitForProcess process
          mapM_ (maybe (pure ()) hClose) [input, output, errors]
    bracket (createProcess child) cleanup $ \case
      (Just input, Just output, _, process) -> do
        ready <- hGetLine output
        unless (ready == "ready") (fail "poll client did not finish warming its views")
        result <- action (hPutStrLn input "go" >> hFlush input)
        counts <- hGetLine output
        exit <- waitForProcess process
        unless (exit == ExitSuccess) (fail "poll client failed")
        (good, bad) <- right (Aeson.eitherDecode (LazyChar8Portable.pack counts))
        pure (result, good, bad)
      _ -> fail "missing poll client control pipes"
  _ -> do
    result <- action (pure ())
    pure (result, 0, 0)
  where
    (views, clients) = pollingShape mode

inspectionModes :: [Text]
inspectionModes = ["disabled", "idle", "active-shared", "active-distinct", "slow-reader", "churn"]

#endif

-- Distinct views and connection counts are independent: a single client can
-- poll all views, while many clients can share one view's authoritative route.
pollingShape :: Text -> (Int, Int)
pollingShape = \case
  "active-shared" -> (1, 1)
  "active-distinct" -> (32, 256)
  "slow-reader" -> (32, 256)
  "churn" -> (32, 32)
  _ -> (0, 0)
