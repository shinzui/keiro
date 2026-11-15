{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module DurableTraceBench (durableTraceBenchmarks) where

import BenchSetup (selected, setupTrace)
import Contravariant.Extras (contrazip3)
import Control.Monad (forM_, replicateM_, unless, void)
import Data.Aeson qualified as Aeson
import Data.Int (Int32, Int64)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (UTCTime (..))
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude (liftIO, (&), (.~), (^.))
import Keiro.Telemetry qualified as Telemetry
import Keiro.Test.Postgres (checkpointBenchmarkStore)
import Keiro.Timer qualified as Timer
import Keiro.Workflow qualified as Workflow
import Keiro.Workflow.Instance qualified as Instance
import Keiro.Workflow.Snapshot (writeWorkflowSnapshot)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (EventId (..), StreamVersion (..))
import OpenTelemetry.Trace.Core (Tracer, defaultSpanArguments, inSpan')
import System.Environment (lookupEnv)
import Test.Tasty.Bench (Benchmark, bench, bgroup, nfIO)
import "hasql-transaction" Hasql.Transaction qualified as Tx

durableTraceBenchmarks :: Store.KirokuStore -> Tracer -> [Benchmark]
durableTraceBenchmarks store tracer =
  [ bgroup "durable-tracing" $
      [timerCell traced | traced <- [False, True]]
        <> [workflowCell size traced | size <- [1 :: Int, 1000], traced <- [False, True]]
  ]
  where
    handle traced = if traced then Just tracer else Nothing
    suffix traced = if traced then "/tracer" else ""
    now = UTCTime (ModifiedJulianDay 60000) 0
    timerCell traced =
      let label = "timer-100" <> suffix traced
          worker = Timer.defaultTimerWorkerOptions & #tracer .~ handle traced & #requeueStuckAfter .~ Nothing
          action = do
            checked store (Store.runTransaction (Tx.sql "TRUNCATE keiro.keiro_timers"))
            Telemetry.withWorkflowSpan (handle traced) (Workflow.WorkflowName "timerBench") (Workflow.WorkflowId "one") Nothing $ \_ -> do
              requests <- traverse (Timer.captureTimerTraceContext (handle traced) . request) [1 .. 100]
              checked store (Store.runTransaction (mapM_ Timer.scheduleTimerTx requests))
            count <- checked store $ Timer.drainDueTimersWith Nothing worker now 101 (const (pure (Just (EventId UUID.nil))))
            unless (count == 100) (fail "timer benchmark did not fire exactly 100 rows")
          request index = Timer.TimerRequest (Timer.TimerId (UUID.fromWords64 0 (fromIntegral index))) "timerBench" "one" now Aeson.Null Nothing
       in selected (warm label action) $ \_ -> bench label (nfIO action)
    workflowCell size traced =
      let label = "resume-snapshot-" <> show size <> suffix traced
          name = Workflow.WorkflowName (Text.pack label)
          wid = Workflow.WorkflowId "one"
          options = Workflow.defaultWorkflowRunOptions & #tracer .~ handle traced
          seed = do
            forM_ [1 .. size] $ \index -> void $ Workflow.step (key index) (pure index)
            void (awaitValue "wake")
          action = replicateM_ 10 do
            checked store (Instance.markInstanceSuspendedAwaitingTraced traced name wid 0 "wake")
            result <- checked store $ Workflow.runWorkflowWith options name wid $ do
              value <- Workflow.step (key 1) (pure (1 :: Int))
              _ <- awaitValue "wake"
              _ <- awaitValue "hold"
              pure value
            unless (result == Workflow.Suspended) (fail "workflow benchmark failed to suspend")
          setup = do
            result <- checked store (Workflow.runWorkflowWith options name wid seed)
            unless (result == Workflow.Suspended) (fail "workflow seed failed to suspend")
            inSpan' tracer "wake" defaultSpanArguments $ \_ ->
              checked store $ Workflow.appendJournalEntryTraced (handle traced) name wid (Workflow.StepRecorded "wake" Aeson.Null now)
            rows <- checked store $ Store.readStreamForward (Workflow.workflowGenerationStreamName name wid 0) (StreamVersion (fromIntegral size)) 1
            unless (Vector.length rows == 1) (fail "workflow seed wake missing")
            let row = Vector.head rows
                state = Map.insert "wake" Aeson.Null (Map.fromList [("step-" <> Text.pack (show index), Aeson.toJSON index) | index <- [1 .. size]])
            checked store (writeWorkflowSnapshot (row ^. #originalStreamId) (row ^. #originalVersion) state)
            diagnostic <- lookupEnv "KEIRO_BENCH_DURABLE_EXPLAIN"
            let explain tag = do
                  plan <- checked store (Store.runTransaction (Tx.statement ((case Workflow.workflowGenerationStreamName name wid 0 of Store.StreamName value -> value), 0, 1) originPlan))
                  putStrLn (label <> " " <> tag)
                  mapM_ TextIO.putStrLn plan
            whenDiagnostic diagnostic (explain "before ANALYZE")
            checked store (Store.runTransaction (Tx.sql "ANALYZE streams; ANALYZE events; ANALYZE stream_events; ANALYZE keiro.keiro_workflows; ANALYZE keiro.keiro_workflow_steps"))
            whenDiagnostic diagnostic (explain "after ANALYZE")
            warm label action
       in selected setup $ \_ -> bench label (nfIO action)
    key index = Workflow.StepName ("step-" <> Text.pack (show index))
    warm label action = do
      checkpointBenchmarkStore store
      setupTrace "durable-tracing" label "warm-up=3; timer rows reset per invocation; resume=10 fixed snapshots"
      replicateM_ 3 action

checked :: Store.KirokuStore -> Eff '[Store.Store, Error Store.StoreError, IOE] a -> IO a
checked store action = Store.runStoreIO store action >>= either (fail . show) pure

awaitValue :: (Workflow.Workflow :> es) => Text.Text -> Eff es Aeson.Value
awaitValue key = Workflow.awaitStep (Workflow.StepName key) (pure ())

whenDiagnostic :: Maybe String -> IO () -> IO ()
whenDiagnostic (Just "1") action = action
whenDiagnostic _ _ = pure ()

-- Same origin query as the registered Kiroku read API, for plan diagnostics.
originPlan :: Statement (Text.Text, Int64, Int32) [Text.Text]
originPlan =
  preparable
    """
    EXPLAIN (ANALYZE, BUFFERS) SELECT e.event_id, e.event_type,
      se.stream_version, 0::bigint AS global_position, se.original_stream_id,
      se.original_stream_version, e.data, e.metadata, e.causation_id, e.correlation_id, e.created_at
    FROM stream_events se JOIN events e ON e.event_id = se.event_id
    JOIN streams s ON s.stream_id = se.stream_id
    WHERE s.stream_name = $1 AND s.deleted_at IS NULL AND se.stream_version > $2
      AND se.stream_version >= s.truncate_before ORDER BY se.stream_version ASC LIMIT $3
    """
    (contrazip3 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int4)))
    (D.rowList (D.column (D.nonNullable D.text)))
