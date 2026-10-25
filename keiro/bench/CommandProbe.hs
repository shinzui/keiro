{-# LANGUAGE OverloadedStrings #-}

-- | Inspect the actual stream-read prepared plan on a disposable benchmark store.
module CommandProbe (commandPlanProbe, delegatedPlanProbe, tableResetProbe, workCountProbe, rebuildCountProbe, maintenanceProbe) where

import Control.Monad (replicateM)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.UUID qualified as UUID
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Keiro.Prelude
import Kiroku.Store qualified as Store
import Kiroku.Store.SQL qualified as SQL
import System.Environment (lookupEnv)
import System.IO (stderr)
import "hasql-transaction" Hasql.Transaction qualified as Tx

commandPlanProbe :: Store.KirokuStore -> Text -> IO ()
commandPlanProbe store label = do
  outcome <- Store.runStoreIO store $ Store.runTransaction $ do
    _ <- Tx.statement ("bench-probe-absent", 0, 100) SQL.readStreamForwardStmt
    entries <-
      Tx.statement () $
        preparable
          "SELECT name FROM pg_prepared_statements WHERE statement LIKE 'SELECT e.event_id,%' AND statement LIKE '%FROM stream_events se%' AND statement LIKE '%s.stream_name = $1%' AND statement LIKE '%se.stream_version > $2%'"
          E.noParams
          (D.rowList (D.column (D.nonNullable D.text)))
    name <- case entries of
      [name] -> pure name
      _ -> error ("expected actual stream read statement: " <> show entries)
    plan <-
      Tx.statement () $
        preparable
          ("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) EXECUTE \"" <> Text.replace "\"" "\"\"" name <> "\"('bench-probe-absent',0,100)")
          E.noParams
          (D.singleRow (D.column (D.nonNullable D.json)))
    counts <-
      Tx.statement () $
        preparable
          "SELECT jsonb_build_object('streams',(SELECT count(*) FROM streams),'events',(SELECT count(*) FROM events),'stream_events',(SELECT count(*) FROM stream_events),'relation_bytes',pg_total_relation_size('stream_events'),'server_version',current_setting('server_version'),'fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'))"
          E.noParams
          (D.singleRow (D.column (D.nonNullable D.jsonb)))
    pure (Aeson.object ["label" Aeson..= label, "counts" Aeson..= (counts :: Aeson.Value), "plan" Aeson..= (plan :: Aeson.Value)])
  either (fail . show) (Lazy.putStrLn . Aeson.encode) outcome

-- Reset alternatives use the same populated row count on isolated group stores.
tableResetProbe :: Store.KirokuStore -> Text -> Int -> IO () -> IO ()
tableResetProbe store table expected seed = do
  for_ ["TRUNCATE", "DELETE FROM"] $ \verb -> do
    samples <- replicateM 5 $ do
      seed
      before <- info
      unless (fst before == fromIntegral expected) (fail "reset probe seed count differs")
      started <- getMonotonicTimeNSec
      checked (Tx.sql (Text.encodeUtf8 (verb <> " " <> table)))
      ended <- getMonotonicTimeNSec
      after <- info
      unless (fst after == 0) (fail "reset probe retained rows")
      pure (Aeson.object ["elapsed_ns" Aeson..= (ended - started), "rows_before" Aeson..= fst before, "bytes_before" Aeson..= snd before, "rows_after" Aeson..= fst after, "bytes_after" Aeson..= snd after])
    Lazy.putStrLn (Aeson.encode (Aeson.object ["table" Aeson..= table, "reset" Aeson..= verb, "samples" Aeson..= samples]))
  where
    checked :: Tx.Transaction a -> IO a
    checked action = Store.runStoreIO store (Store.runTransaction action) >>= either (fail . show) pure
    info =
      checked
        ( Tx.statement
            ()
            ( preparable
                ("SELECT count(*), pg_total_relation_size('" <> table <> "') FROM " <> table)
                E.noParams
                (D.singleRow ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))
            )
        )

delegatedPlanProbe :: Store.KirokuStore -> Text -> IO ()
delegatedPlanProbe store label = do
  result <- Store.runStoreIO store $ Store.runTransaction $ do
    _ <- Tx.statement ("bench-probe-absent", UUID.nil) SQL.eventExistsInStreamStmt
    names <-
      Tx.statement () $
        preparable
          "SELECT name FROM pg_prepared_statements WHERE statement LIKE 'SELECT EXISTS (%' AND statement LIKE '%FROM stream_events se%' AND statement LIKE '%stream_name = $1%'"
          E.noParams
          (D.rowList (D.column (D.nonNullable D.text)))
    name <- case names of [name] -> pure name; _ -> error ("expected delegated prepared statement: " <> show names)
    plan <-
      Tx.statement () $
        preparable
          ("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) EXECUTE \"" <> Text.replace "\"" "\"\"" name <> "\"('bench-probe-absent','00000000-0000-0000-0000-000000000000'::uuid)")
          E.noParams
          (D.singleRow (D.column (D.nonNullable D.json)))
    pure (Aeson.object ["label" Aeson..= label, "plan" Aeson..= (plan :: Aeson.Value)])
  either (fail . show) (Lazy.hPutStrLn stderr . Aeson.encode) result

-- Run only in diagnostic invocations: these reads must not change timed plans.
workCountProbe :: Store.KirokuStore -> Text -> Text -> Int -> Int -> IO ()
workCountProbe store label prefix expectedStreams expectedEvents = do
  enabled <- lookupEnv "KEIRO_BENCH_WORK_COUNTS"
  when (enabled == Just "1") $ do
    result <-
      Store.runStoreIO store $
        Store.runTransaction $
          Tx.statement prefix $
            preparable
              "SELECT count(DISTINCT s.stream_id), count(se.event_id), pg_total_relation_size('streams'), pg_total_relation_size('events'), pg_total_relation_size('stream_events') FROM streams s LEFT JOIN stream_events se USING (stream_id) WHERE left(s.stream_name, length($1)) = $1"
              (E.param (E.nonNullable E.text))
              (D.singleRow ((,,,,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))
    (streams, events, streamBytes, eventBytes, linkBytes) <- either (fail . show) pure result
    unless (streams == fromIntegral expectedStreams && events == fromIntegral expectedEvents) $
      fail ("benchmark work-count mismatch: " <> Text.unpack label <> " expected=" <> show (expectedStreams, expectedEvents) <> " actual=" <> show (streams, events))
    Lazy.hPutStrLn stderr (Aeson.encode (Aeson.object ["label" Aeson..= label, "prefix" Aeson..= prefix, "streams" Aeson..= streams, "events" Aeson..= events, "streams_bytes" Aeson..= streamBytes, "events_bytes" Aeson..= eventBytes, "stream_events_bytes" Aeson..= linkBytes]))

rebuildCountProbe :: Store.KirokuStore -> Int -> IO ()
rebuildCountProbe store expectedRuns = do
  enabled <- lookupEnv "KEIRO_BENCH_WORK_COUNTS"
  when (enabled == Just "1") $ do
    result <-
      Store.runStoreIO store $
        Store.runTransaction $
          Tx.statement () $
            preparable
              "SELECT (SELECT count(*) FROM keiro.keiro_projection_rebuild_runs), (SELECT count(*) FROM keiro.keiro_projection_rebuild_sources), (SELECT count(*) FROM events), jsonb_build_object('runs_bytes',pg_total_relation_size('keiro.keiro_projection_rebuild_runs'),'sources_bytes',pg_total_relation_size('keiro.keiro_projection_rebuild_sources'),'targets',(SELECT count(*) FROM keiro.keiro_projection_rebuild_run_targets),'adapters',(SELECT count(*) FROM keiro.keiro_projection_rebuild_adapters),'verifications',(SELECT count(*) FROM keiro.keiro_projection_rebuild_verifications))"
              E.noParams
              (D.singleRow ((,,,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.jsonb)))
    (runs, sources, events, bookkeeping) <- either (fail . show) pure result
    unless (runs == fromIntegral expectedRuns && sources == fromIntegral (3 * expectedRuns) && events == 600) $
      fail ("rebuild work-count mismatch: " <> show (runs, sources, events))
    Lazy.hPutStrLn stderr (Aeson.encode (Aeson.object ["label" Aeson..= ("rebuild" :: Text), "runs" Aeson..= runs, "sources" Aeson..= sources, "events" Aeson..= events, "bookkeeping" Aeson..= (bookkeeping :: Aeson.Value)]))

-- Cluster maintenance is shared across database clones. Record it outside timing.
maintenanceProbe :: Store.KirokuStore -> Text -> IO ()
maintenanceProbe store label = do
  enabled <- lookupEnv "KEIRO_BENCH_MAINTENANCE_PROBE"
  when (enabled == Just "1") $ do
    result <-
      Store.runStoreIO store $
        Store.runTransaction $
          Tx.statement () $
            preparable
              "SELECT jsonb_build_object('at',clock_timestamp(),'checkpoint',(SELECT to_jsonb(c) FROM pg_stat_checkpointer c),'wal',(SELECT to_jsonb(w) FROM pg_stat_wal w),'lsn',pg_current_wal_lsn(),'max_wal_size',current_setting('max_wal_size'),'checkpoint_timeout',current_setting('checkpoint_timeout'),'shared_buffers',current_setting('shared_buffers'),'activity',(SELECT jsonb_agg(jsonb_build_object('type',backend_type,'database',datname,'state',state,'wait_type',wait_event_type,'wait',wait_event)) FROM pg_stat_activity WHERE backend_type IN ('checkpointer','autovacuum worker','background writer','walwriter','io worker')),'tables',(SELECT jsonb_agg(jsonb_build_object('table',relname,'live',n_live_tup,'dead',n_dead_tup,'vacuum',vacuum_count,'autovacuum',autovacuum_count,'last_autovacuum',last_autovacuum,'analyze',analyze_count,'last_autoanalyze',last_autoanalyze)) FROM pg_stat_user_tables WHERE relname IN ('streams','stream_events','events','keiro_inbox','keiro_inbox_delegated_bench_effect')))"
              E.noParams
              (D.singleRow (D.column (D.nonNullable D.jsonb)))
    snapshot <- either (fail . show) pure result
    Lazy.hPutStrLn stderr (Aeson.encode (Aeson.object ["maintenance" Aeson..= label, "snapshot" Aeson..= (snapshot :: Aeson.Value)]))
