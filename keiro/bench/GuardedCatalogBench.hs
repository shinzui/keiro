{-# LANGUAGE BlockArguments #-}

module GuardedCatalogBench (runGuardedCatalogEvidence) where

import Control.Concurrent
import Control.Exception (AsyncException (ThreadKilled), finally, fromException)
import Control.Monad
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.List qualified as List
import Data.Text qualified as Text
import GuardedCatalogExample qualified as Example
import GuardedCatalogWorkload
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Keiro
import Keiro.Prelude
import Keiro.Projection
import Keiro.Test.Postgres
import Kiroku.Store qualified as Store
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude

data Mode = Ordinary | EmptyGuard | IndexedGuard | SlowGuard deriving (Eq, Show)

runGuardedCatalogEvidence :: IO Bool
runGuardedCatalogEvidence =
  lookupEnv "KEIRO_GUARDED_CATALOG_EVIDENCE" >>= \case
    Nothing -> pure False
    Just mode -> do
      output <- maybe "bench/results/guarded-catalog/candidate" id <$> lookupEnv "KEIRO_GUARDED_CATALOG_OUTPUT"
      exists <- doesPathExist (output <> "/manifest.json")
      when exists (fail "evidence output already exists; choose a unique output directory")
      createDirectoryIfMissing True output
      -- Fixed budgets are persisted before any candidate sample.
      Lazy.writeFile
        (output <> "/manifest.json")
        ( Aeson.encode
            ( Aeson.object
                [ "mode" Aeson..= mode,
                  "pairs" Aeson..= (5 :: Int),
                  "attempts" Aeson..= (10000 :: Int),
                  "payloadBytes" Aeson..= (1024 :: Int),
                  "tags" Aeson..= (4 :: Int),
                  "poolSize" Aeson..= (10 :: Int),
                  "ordinaryThroughputMinimum" Aeson..= (0.95 :: Double),
                  "ordinaryP95Maximum" Aeson..= (1.10 :: Double),
                  "ordinaryP99Maximum" Aeson..= (1.10 :: Double),
                  "guardedThroughputMinimum" Aeson..= (0.90 :: Double),
                  "guardedP95Maximum" Aeson..= (1.25 :: Double),
                  "guardedP99Maximum" Aeson..= (1.50 :: Double),
                  "requestSeed" Aeson..= (306 :: Int),
                  "deadlineSeconds" Aeson..= (300 :: Int)
                ]
            )
        )
      case mode of
        "ordinary" -> forM_ ordinaryConfigs \config -> do
          result <- sample config Ordinary
          save output (workloadKey config <> "-ordinary") result
        "compare" -> do
          baseline <- requireBaseline
          baselineFolder <- lookupEnv "KEIRO_GUARDED_CATALOG_BASELINE" >>= maybe (fail "baseline directory required") pure
          copyFile (baselineFolder <> "/enhanced-environment.json") (output <> "/baseline-environment.json")
          -- Stop on a failed fixed budget; retain every sample and report. This
          -- prevents continuing large measurements on a known unacceptable path.
          forM_ ordinaryConfigs \config -> comparePairSet output baseline "refactor" Ordinary config
          forM_ ordinaryConfigs \base -> do
            comparePairSet output baseline "empty" EmptyGuard (base {guardPercent = 100})
            comparePairSet output baseline "miss" IndexedGuard (base {guardPercent = 100})
            forM_ [False, True] \spread -> do
              -- Pure-hit pairs report costs, without a numeric acceptance
              -- budget: the candidate rolls back every creation batch.
              comparePairSet output baseline "hit" IndexedGuard (base {guardPercent = 100, duplicatePercent = 100, distributed = spread})
              forM_ [0, 50, 100] \duplicates -> comparePairSet output baseline "mixed" IndexedGuard (base {guardPercent = 20, duplicatePercent = duplicates, distributed = spread})
          -- Offered rates are fixed from controls before these candidate runs.
          forM_ [False, True] \worker -> do
            let base = Workload 1000000 8 4 worker 20 0 True Nothing 10000 300
            capacities <- forM [1 .. 5 :: Int] \iteration -> do
              capacity <- sample base Ordinary
              save output ("capacity-" <> show worker <> "-" <> show iteration) capacity
              pure (fromIntegral (length (samples capacity)) / elapsedSeconds capacity)
            let rate = percentile 0.5 capacities
            Lazy.writeFile (output <> "/capacity-" <> show worker <> "-rates.json") (Aeson.encode (Aeson.object ["samples" Aeson..= capacities, "fixedCapacity" Aeson..= rate]))
            forM_ [0.50, 0.80] \fraction -> forM_ [0, 50, 100] \duplicates ->
              comparePairSet output baseline "fixed-arrival" IndexedGuard (base {duplicatePercent = duplicates, arrivalRate = Just (rate * fraction), deadlineSeconds = max 300 (ceiling (10000 / (rate * fraction)) + 60)})
            -- Paired ten-minute runs preserve normal vacuum and async backlog.
            let sustained = base {duplicatePercent = 100, arrivalRate = Just (rate * 0.8), attempts = max 10000 (ceiling (rate * 0.8 * 600) + 1), deadlineSeconds = 720}
            sustainedResults <- forM [("control", Ordinary, sustained {duplicatePercent = 0}), ("duplicates", IndexedGuard, sustained)] \(label, chosen, config) -> do
              result <- sampleWithStorage output ("sustained-" <> show worker <> "-" <> label) config chosen
              save output ("sustained-" <> show worker <> "-" <> label) result
              pure result
            case sustainedResults of
              [control, candidate] -> do
                let comparison = ratios "mixed" control candidate
                    minuteRatios = [ratios "mixed" (minute n control) (minute n candidate) | n <- [0 .. 9 :: Int]]
                    success = passes "mixed" [comparison] && all (passes "mixed" . (: [])) minuteRatios && all ((>= 600) . elapsedSeconds) sustainedResults
                Lazy.writeFile (output <> "/sustained-" <> show worker <> "-report.json") (Aeson.encode (Aeson.object ["latencyPass" Aeson..= success, "overall" Aeson..= comparison, "minutes" Aeson..= minuteRatios, "storageReviewRequired" Aeson..= True]))
                unless success (fail "sustained ordinary-writer latency budget failed")
              _ -> fail "missing sustained pair"
        "diagnostic" -> do
          let config = Workload 1000000 8 4 False 20 0 True Nothing 1000 300
          control <- sample config Ordinary
          slow <- sample config SlowGuard
          save output "slow-control" control
          save output "slow-guard" slow
          unless (not (passes "mixed" [ratios "mixed" control slow])) (fail "slow guard failed to demonstrate ordinary-writer degradation")
          withMigratedSuite \fixture -> withFreshResourceStore fixture \(_, runner) -> do
            prepareDatabase runner config
            plan <-
              checked
                runner
                ( Store.runTransaction
                    ( Tx.statement
                        (Example.notePayload (Example.exampleNote "explain" "seed-1"))
                        ( preparable
                            "EXPLAIN (ANALYZE, BUFFERS) SELECT note_id FROM app.state_note_identity WHERE anchor_type=$1::jsonb->>'anchorType' AND anchor_id=$1::jsonb->>'anchorId' AND property_id=$1::jsonb->>'propertyId' AND state_id=$1::jsonb->>'stateId'"
                            Example.textParam
                            (D.rowList (D.column (D.nonNullable D.text)))
                        )
                    )
                )
            writeFile (output <> "/identity-query-plan.txt") (unlines (map Text.unpack plan))
            unless (any (Text.isInfixOf "Index") plan) (fail "identity lookup did not use an index")
          diagnosticTransactions output config
        _ -> fail ("unknown evidence mode: " <> mode)
      pure True

ordinaryConfigs :: [Workload]
ordinaryConfigs = [Workload size connections batch worker 0 0 True Nothing 10000 300 | size <- [10000, 1000000], connections <- [1, 8], batch <- [1, 4], worker <- [False, True]]

workloadKey :: Workload -> String
workloadKey config = List.intercalate "-" [show (cardinality config), show (connections config), show (batchSize config), show (activeWorker config), show (guardPercent config), show (duplicatePercent config), show (distributed config), show (arrivalRate config)]

sample :: Workload -> Mode -> IO Measurements
sample config mode = withMigratedSuite \fixture -> withFreshResourceStore fixture \(_, runner) -> do
  prepareDatabase runner config
  measureWorkload runner config (action runner config mode)

action :: StoreRunner -> Workload -> Mode -> Request -> IO Bool
action runner config mode request
  | mode == Ordinary || not (guarded request) = ordinaryAction runner (batchSize config) request
  | otherwise = do
      outcome <-
        checked
          runner
          ( runDomainCommandWithCatalogProjectionsGuarded
              defaultRunCommandOptions
              (Example.handler (batchSize config))
              (stream (Example.noteId (note request)))
              (Example.CreateNote (payload request))
              Example.catalog
              Example.commandSet
              ( \context -> do
                  when (mode == SlowGuard) (Tx.sql "SELECT pg_sleep(0.02)")
                  if mode == EmptyGuard || mode == SlowGuard then pure (Right ()) else Example.noteGuard (note request) context
              )
          )
      case outcome of
        Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted {}})) -> pure True
        Right (PreconditionRefused (Example.ExistingNote _)) -> pure False
        other -> fail ("unexpected guarded outcome: " <> show other)

save :: FilePath -> String -> Measurements -> IO ()
save output name result = do
  let raw = output <> "/" <> name <> ".json"
  Lazy.writeFile raw (Aeson.encode result)
  (code, _, errors) <- readProcessWithExitCode "gzip" ["-n", raw] ""
  unless (code == ExitSuccess) (fail ("raw evidence compression failed: " <> errors))
  Lazy.writeFile (output <> "/" <> name <> "-summary.json") (Aeson.encode (summarize result))
  putStrLn (name <> " " <> show (summarize result))

requireBaseline :: IO FilePath
requireBaseline = do
  folder <- lookupEnv "KEIRO_GUARDED_CATALOG_BASELINE" >>= maybe (fail "baseline directory required") pure
  manifest <- Lazy.readFile (folder <> "/enhanced-environment.json") >>= either fail pure . Aeson.eitherDecode
  (path, digest, workloadDigest, fixtureDigest) <- case manifest of
    Aeson.Object object -> case (KeyMap.lookup "retainedExecutable" object, KeyMap.lookup "sha256" object, KeyMap.lookup "workloadSha256" object, KeyMap.lookup "fixtureSha256" object) of
      (Just (Aeson.String path), Just (Aeson.String digest), Just (Aeson.String workloadDigest), Just (Aeson.String fixtureDigest)) -> pure (Text.unpack path, Text.unpack digest, Text.unpack workloadDigest, Text.unpack fixtureDigest)
      _ -> fail "baseline manifest is incomplete"
    _ -> fail "invalid baseline manifest"
  forM_ [(path, digest), ("bench/GuardedCatalogWorkload.hs", workloadDigest), ("test/GuardedCatalogFixture.hs", fixtureDigest)] \(file, expected) -> do
    (code, actual, errors) <- readProcessWithExitCode "shasum" ["-a", "256", file] ""
    unless (code == ExitSuccess && take 64 actual == expected) (fail ("baseline/build configuration digest mismatch: " <> file <> errors))
  pure path

comparePairSet :: FilePath -> FilePath -> String -> Mode -> Workload -> IO ()
comparePairSet output baseline label mode config = do
  pairs <- forM [1 .. 5 :: Int] \pair -> do
    let prefix = label <> "-" <> workloadKey config <> "-" <> show pair
        controlConfig = config {duplicatePercent = 0}
        control = if label == "refactor" then originalSample output baseline prefix controlConfig else sample controlConfig Ordinary
        candidate = sample config mode
    (before, after) <- if odd pair then (,) <$> control <*> candidate else do after <- candidate; before <- control; pure (before, after)
    save output (prefix <> "-control") before
    save output (prefix <> "-candidate") after
    pure (ratios label before after)
  let accepted = label == "hit" || passes label pairs
  Lazy.writeFile (output <> "/" <> label <> "-" <> workloadKey config <> "-report.json") (Aeson.encode (Aeson.object ["pass" Aeson..= accepted, "budgetApplicable" Aeson..= (label /= "hit"), "ratios" Aeson..= pairs]))
  unless accepted (fail ("fixed performance budget failed: " <> label <> " " <> workloadKey config <> " " <> show pairs))

originalSample output executable prefix config = do
  let input = output <> "/" <> prefix <> "-workload.json"; result = output <> "/" <> prefix <> "-original.json"
  Lazy.writeFile input (Aeson.encode config)
  (exit, stdout, stderr) <- readProcessWithExitCode executable [input, result, "+RTS", "-N2", "-RTS"] ""
  unless (exit == ExitSuccess) (fail ("original benchmark fault: " <> stdout <> stderr))
  measurements <- Lazy.readFile result >>= either fail pure . Aeson.eitherDecode
  (code, _, errors) <- readProcessWithExitCode "gzip" ["-n", result] ""
  unless (code == ExitSuccess) (fail ("baseline evidence compression failed: " <> errors))
  pure measurements

-- Ratios retain throughput and the relevant end-to-end latency cohort. Refused
-- and accepted counts are separately reported in each sample summary.
ratios :: String -> Measurements -> Measurements -> (Double, Double, Double)
ratios label before after = (throughput after / throughput before, percentile 0.95 (latencies after) / percentile 0.95 (latencies before), percentile 0.99 (latencies after) / percentile 0.99 (latencies before))
  where
    throughput value = fromIntegral (length (samples value)) / elapsedSeconds value
    latencies value = [latencyMicros sample | sample <- samples value, if label == "mixed" || label == "fixed-arrival" then cohort sample == "ordinary" else True]

passes :: String -> [(Double, Double, Double)] -> Bool
passes label values = median [x | (x, _, _) <- values] >= (if label == "refactor" then 0.95 else 0.90) && median [x | (_, x, _) <- values] <= (if label == "refactor" then 1.10 else 1.25) && median [x | (_, _, x) <- values] <= (if label == "refactor" then 1.10 else 1.50)
  where
    median = percentile 0.5

sampleWithStorage output name config mode = withMigratedSuite \fixture -> withFreshResourceStore fixture \(_, runner) -> do
  prepareDatabase runner config
  let path = output <> "/" <> name <> "-storage.jsonl"
      snapshot = do
        snapshot <-
          checked
            runner
            ( Store.runTransaction
                ( Tx.statement
                    ()
                    ( preparable
                        "SELECT jsonb_build_object('at',clock_timestamp(),'wal',(SELECT row_to_json(w) FROM pg_stat_wal w),'databaseBytes',pg_database_size(current_database()),'tables',(SELECT jsonb_agg(jsonb_build_object('schema',schemaname,'table',relname,'bytes',pg_total_relation_size(relid),'relationBytes',pg_relation_size(relid),'indexBytes',pg_indexes_size(relid),'live',n_live_tup,'dead',n_dead_tup,'autovacuumCount',autovacuum_count,'lastAutovacuum',last_autovacuum)) FROM pg_stat_user_tables),'head',(SELECT stream_version FROM streams WHERE stream_id=0),'worker',(SELECT min(last_seen) FROM subscriptions WHERE subscription_name='note-rich-worker'))::text"
                        E.noParams
                        (D.singleRow (D.column (D.nonNullable D.text)))
                    )
                )
            )
        appendFile path (Text.unpack snapshot <> "\n")
      collect = do
        threadDelay (60 * 1000000)
        snapshot
        collect
  snapshot
  done <- newEmptyMVar
  observer <- forkFinally collect (putMVar done)
  result <- measureWorkload runner config (action runner config mode) `finally` killThread observer
  takeMVar done >>= \case
    Left err -> case fromException err of
      Just ThreadKilled -> pure ()
      _ -> fail ("storage observer failed: " <> show err)
    Right () -> fail "storage observer exited unexpectedly"
  snapshot
  pure result

minute :: Int -> Measurements -> Measurements
minute n result = result {elapsedSeconds = 60, samples = [sample | sample <- samples result, completedSeconds sample >= fromIntegral (n * 60), completedSeconds sample < fromIntegral ((n + 1) * 60)]}

-- These extra statements/triggers run only in diagnostic mode. The clock
-- interval starts after the global row update and ends before commit, so it is
-- a lower bound on that row's lock lifetime, not a production hold-time sample.
diagnosticTransactions :: FilePath -> Workload -> IO ()
diagnosticTransactions output config = withMigratedSuite \fixture ->
  withFreshResourceStoresSameDatabase fixture \((_, runner), (_, observerRunner)) -> do
    prepareDatabase runner config
    checked
      runner
      ( Store.runTransaction
          ( Tx.sql
              """
              CREATE SEQUENCE app.diag_all_attempts;
              CREATE SEQUENCE app.diag_guard_attempts;
              CREATE TABLE app.diag_marks(txid bigint, stage text, at timestamptz);
              CREATE FUNCTION app.diag_all() RETURNS trigger LANGUAGE plpgsql AS $$
              BEGIN
                PERFORM nextval('app.diag_all_attempts');
                INSERT INTO app.diag_marks VALUES (txid_current(), 'all-updated', clock_timestamp());
                RETURN NEW;
              END $$;
              CREATE TRIGGER diag_all AFTER UPDATE ON streams FOR EACH ROW WHEN (NEW.stream_id = 0) EXECUTE FUNCTION app.diag_all();
              CREATE FUNCTION app.diag_identity() RETURNS trigger LANGUAGE plpgsql AS $$
              BEGIN
                INSERT INTO app.diag_marks VALUES (txid_current(), 'identity-delivered', clock_timestamp());
                RETURN NEW;
              END $$;
              CREATE TRIGGER diag_identity AFTER INSERT ON app.state_note_identity FOR EACH ROW EXECUTE FUNCTION app.diag_identity();
              """
          )
      )
    occ <- newIORef (0 :: Int)
    done <- newEmptyMVar
    let observe = do
          waits <- checked observerRunner (Store.runTransaction (Tx.statement () (preparable "SELECT COALESCE(jsonb_agg(jsonb_build_object('at',clock_timestamp(),'pid',pid,'waitType',wait_event_type,'waitEvent',wait_event,'blockers',pg_blocking_pids(pid),'query',query)),'[]'::jsonb)::text FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock'" E.noParams (D.singleRow (D.column (D.nonNullable D.text))))))
          appendFile (output <> "/lock-waits.jsonl") (Text.unpack waits <> "\n")
          threadDelay 20000
          observe
        options = defaultRunCommandOptions & #beforeAppend .~ atomicModifyIORef' occ (\n -> (n + 1, ()))
        execute request = do
          let target = stream (Example.noteId (note request)); command = Example.CreateNote (payload request)
          if guarded request
            then do
              result <-
                checked
                  runner
                  ( runDomainCommandWithCatalogProjectionsGuarded
                      options
                      (Example.handler (batchSize config))
                      target
                      command
                      Example.catalog
                      Example.commandSet
                      ( \context -> do
                          attempt <- Tx.statement () (preparable "SELECT nextval('app.diag_guard_attempts')" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))
                          -- One known driver retry makes surviving attempt counters a
                          -- positive control instead of assuming each body ran once.
                          when (attempt == 1) (Tx.sql "DO $$ BEGIN RAISE EXCEPTION 'diagnostic retry' USING ERRCODE='40001'; END $$")
                          Tx.sql "INSERT INTO app.diag_marks VALUES (txid_current(),'guard-start',clock_timestamp())"
                          Tx.sql "SELECT pg_sleep(0.02)"
                          refusal <- Example.noteGuard (note request) context
                          Tx.sql "INSERT INTO app.diag_marks VALUES (txid_current(),'guard-end',clock_timestamp())"
                          pure refusal
                      )
                  )
              case result of
                Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted {}})) -> pure True
                other -> fail ("diagnostic guarded fault: " <> show other)
            else do
              result <- checked runner (runDomainCommandWithCatalogProjections options (Example.handler (batchSize config)) target command Example.catalog Example.commandSet)
              case result of
                Right (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted {}}) -> pure True
                other -> fail ("diagnostic ordinary fault: " <> show other)
    observer <- forkFinally observe (putMVar done)
    result <- measureWorkload runner config execute `finally` killThread observer
    takeMVar done >>= \case
      Left err -> case fromException err of Just ThreadKilled -> pure (); _ -> fail ("lock observer failed: " <> show err)
      Right () -> fail "lock observer exited unexpectedly"
    save output "instrumented-slow-guard" result
    attemptsObserved <- readIORef occ
    (allUpdates, guardEvaluations) <- checked runner (Store.runTransaction (Tx.statement () (preparable "SELECT (SELECT last_value FROM app.diag_all_attempts), (SELECT last_value FROM app.diag_guard_attempts)" E.noParams (D.singleRow ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8))))))
    unless (allUpdates == fromIntegral (attempts config + 1) && guardEvaluations == fromIntegral (length (filter guarded (prepareRequests config)) + 1)) (fail "diagnostic driver retry count differs from injected retry")
    waits <- lines <$> readFile (output <> "/lock-waits.jsonl")
    unless (any (/= "[]") waits) (fail "slow-guard diagnostic observed no lock wait")
    statistics <- checked runner (Store.runTransaction (Tx.statement () (preparable "SELECT jsonb_build_object('appendAllUpdates',(SELECT last_value FROM app.diag_all_attempts),'guardEvaluations',(SELECT last_value FROM app.diag_guard_attempts),'timings',(SELECT jsonb_agg(row_to_json(t)) FROM (SELECT txid, EXTRACT(EPOCH FROM (max(at) FILTER (WHERE stage='guard-end')-max(at) FILTER (WHERE stage='guard-start')))*1000000 AS guard_microseconds, EXTRACT(EPOCH FROM (max(at) FILTER (WHERE stage='identity-delivered')-min(at) FILTER (WHERE stage='all-updated')))*1000000 AS all_lock_lower_bound_microseconds FROM app.diag_marks GROUP BY txid) t))::text" E.noParams (D.singleRow (D.column (D.nonNullable D.text))))))
    writeFile (output <> "/transaction-timings.json") (Text.unpack statistics)
    Lazy.writeFile (output <> "/attempt-counts.json") (Aeson.encode (Aeson.object ["outerAppendAttempts" Aeson..= attemptsObserved, "commands" Aeson..= attempts config, "injectedDriverRetries" Aeson..= (1 :: Int), "scope" Aeson..= ("diagnostic unique streams; global update/guard sequences count attempts surviving rollback; lock clocks exclude pre-update wait and commit" :: Text)]))
    unless (attemptsObserved == attempts config) (fail "unexpected OCC churn in unique-stream diagnostic")
