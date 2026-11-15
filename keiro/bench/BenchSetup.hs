-- | Selection-aware fixture diagnostics shared by the benchmark groups.
module BenchSetup (selectedBracket, withRecordingTracer, selected, selectedWithCleanup, memoSetup, setupTrace, freshCounter, nextIteration, nextBoundedIteration, selectedCounter, selectedCounterWithCleanup) where

import Control.Concurrent.Async (async, cancel, link, wait)
import Control.Concurrent.MVar (modifyMVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import Control.DeepSeq (NFData (..))
import Control.Exception (bracket, mask, onException)
import Control.Monad (unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Processor.Span (SpanProcessor (..))
import OpenTelemetry.Trace.Core
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Test.Tasty.Bench (Benchmark, envWithCleanup)
import Prelude

-- Fixture handles contain mutable state; force the handle, never its contents.
data Handle a = Handle !a

instance NFData (Handle a) where
  rnf (Handle value) = value `seq` ()

selected :: IO a -> (a -> Benchmark) -> Benchmark
selected acquire = selectedWithCleanup acquire (const (pure ()))

selectedWithCleanup :: IO a -> (a -> IO ()) -> (a -> Benchmark) -> Benchmark
selectedWithCleanup acquire cleanup build =
  envWithCleanup (Handle <$> acquire) (\(Handle value) -> cleanup value) $ \handle ->
    build (case handle of Handle value -> value)

-- Adapt bracket-only resources to Tasty's selected environment lifecycle. The
-- worker holds the bracket open; cleanup joins it after every resource closes.
selectedBracket :: ((a -> IO ()) -> IO ()) -> (a -> Benchmark) -> Benchmark
selectedBracket scope build = selectedWithCleanup acquire cleanup $ \ ~(value, _, _) -> build value
  where
    acquire = mask $ \restore -> do
      ready <- newEmptyMVar
      release <- newEmptyMVar
      worker <- async $ restore $ scope $ \value -> putMVar ready value >> takeMVar release
      value <- (link worker >> restore (takeMVar ready)) `onException` cancel worker
      pure (value, release, worker)
    cleanup (_, release, worker) = putMVar release () >> wait worker

memoSetup :: IO a -> IO (IO a)
memoSetup acquire = do
  cell <- newMVar Nothing
  pure $ modifyMVar cell $ \current -> case current of
    Just value -> pure (current, value)
    Nothing -> do
      value <- acquire
      pure (Just value, value)

setupTrace :: String -> String -> String -> IO ()
setupTrace group scenario detail = do
  enabled <- lookupEnv "KEIRO_BENCH_SETUP_TRACE"
  if enabled == Just "1"
    then hPutStrLn stderr ("BENCH_SETUP group=" <> group <> " scenario=" <> scenario <> " " <> detail)
    else pure ()

freshCounter :: String -> Int -> IO (IORef Int)
freshCounter label units = do
  setupTrace "command" label ("counter budget_iterations=" <> show (iterationBudget units) <> " units_per_iteration=" <> show units)
  newIORef 0

iterationBudget :: Int -> Int
iterationBudget units = 100000 `div` max 1 units

nextIteration :: String -> Int -> IORef Int -> IO Int
nextIteration label units = nextBoundedIteration label (iterationBudget units)

nextBoundedIteration :: String -> Int -> IORef Int -> IO Int
nextBoundedIteration label budget counter = do
  next <- atomicModifyIORef' counter (\current -> let n = current + 1 in (n, n))
  if next > budget
    then fail ("benchmark fixture growth budget exceeded: " <> label <> " iterations=" <> show next)
    else pure next

selectedCounter :: String -> Int -> IO (IORef Int) -> (IORef Int -> Benchmark) -> Benchmark
selectedCounter label units acquire = selectedCounterWithCleanup label units acquire (const (pure ()))

selectedCounterWithCleanup :: String -> Int -> IO (IORef Int) -> (Int -> IO ()) -> (IORef Int -> Benchmark) -> Benchmark
selectedCounterWithCleanup label units acquire cleanup build =
  envWithCleanup
    acquire
    ( \counter -> do
        n <- readIORef counter
        setupTrace "counts" label ("iterations=" <> show n <> " units=" <> show (n * units))
        cleanup n
    )
    build

-- Benchmark SDK work without exporting I/O or accumulating completed spans.
-- Check recording explicitly: processor-free providers can be non-recording.
withRecordingTracer :: (Tracer -> IO a) -> IO a
withRecordingTracer action = bracket acquire (\(provider, _) -> shutdownTracerProvider provider Nothing) (action . snd)
  where
    acquire = do
      (processor, _) <- inMemoryListExporter
      -- Keep the SDK's recording path but discard completed spans immediately.
      let discard = processor {spanProcessorOnEnd = const (pure ())}
      provider <- createTracerProvider [discard] emptyTracerProviderOptions
      let tracer = makeTracer provider "keiro-bench" tracerOptions
      inSpan' tracer "recording-check" defaultSpanArguments $ \span -> do
        recording <- isRecording span
        unless recording (fail "benchmark tracer is not recording")
      pure (provider, tracer)
