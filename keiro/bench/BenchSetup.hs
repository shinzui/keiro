-- | Selection-aware fixture diagnostics shared by the benchmark groups.
module BenchSetup (selected, memoSetup, setupTrace, freshCounter, nextIteration, selectedCounter) where

import Control.Concurrent.MVar (modifyMVar, newMVar)
import Control.DeepSeq (NFData (..))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Test.Tasty.Bench (Benchmark, envWithCleanup)
import Prelude

-- Fixture handles contain mutable state; force the handle, never its contents.
data Handle a = Handle !a

instance NFData (Handle a) where
  rnf (Handle value) = value `seq` ()

selected :: IO a -> (a -> Benchmark) -> Benchmark
selected acquire build = envWithCleanup (Handle <$> acquire) (const (pure ())) $ \handle ->
  build (case handle of Handle value -> value)

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
nextIteration label units counter = do
  next <- atomicModifyIORef' counter (\current -> let n = current + 1 in (n, n))
  if next > iterationBudget units
    then fail ("benchmark fixture growth budget exceeded: " <> label <> " iterations=" <> show next)
    else pure next

selectedCounter :: String -> Int -> IO (IORef Int) -> (IORef Int -> Benchmark) -> Benchmark
selectedCounter label units acquire build =
  envWithCleanup
    acquire
    ( \counter -> do
        n <- readIORef counter
        setupTrace "counts" label ("iterations=" <> show n <> " units=" <> show (n * units))
    )
    build
