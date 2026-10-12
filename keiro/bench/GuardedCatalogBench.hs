{-# LANGUAGE BlockArguments #-}

module GuardedCatalogBench (runGuardedCatalogEvidence) where

import Control.Concurrent
import Control.Exception (finally)
import Control.Monad (forM, forM_, replicateM)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.List qualified as List
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import GHC.Clock (getMonotonicTimeNSec)
import GuardedCatalogExample qualified as Example
import Keiro
import Keiro.Projection
import Keiro.Test.Postgres
import Kiroku.Store qualified as Store
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (exitSuccess)
import System.Timeout (timeout)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude

-- Budgets are fixed before candidate measurements; times are microseconds.
runGuardedCatalogEvidence :: IO Bool
runGuardedCatalogEvidence =
  lookupEnv "KEIRO_GUARDED_CATALOG_EVIDENCE" >>= \case
    Nothing -> pure False
    Just "ordinary" -> do
      output <- maybe "bench/results/guarded-catalog/baseline" id <$> lookupEnv "KEIRO_GUARDED_CATALOG_OUTPUT"
      createDirectoryIfMissing True output
      Lazy.writeFile
        (output <> "/manifest.json")
        ( Aeson.encode
            ( Aeson.object
                [ "mode" Aeson..= ("ordinary" :: String),
                  "attempts" Aeson..= (10000 :: Int),
                  "pairs" Aeson..= (5 :: Int),
                  "cardinalities" Aeson..= ([10000, 1000000] :: [Int]),
                  "connections" Aeson..= ([1, 8] :: [Int]),
                  "batches" Aeson..= ([1, 4] :: [Int]),
                  "payloadBytes" Aeson..= (1024 :: Int),
                  "tags" Aeson..= (4 :: Int),
                  "ordinaryThroughputMinimum" Aeson..= (0.95 :: Double),
                  "ordinaryLatencyMaximum" Aeson..= (1.10 :: Double),
                  "guardedThroughputMinimum" Aeson..= (0.90 :: Double),
                  "guardedP95Maximum" Aeson..= (1.25 :: Double),
                  "guardedP99Maximum" Aeson..= (1.50 :: Double)
                ]
            )
        )
      withMigratedSuite \fixture -> forM_ [10000, 1000000] \size -> forM_ [1, 8] \connections -> forM_ [1, 4] \batch -> forM_ [1 .. 5 :: Int] \pair ->
        withFreshResourceStore fixture \(_, runner) -> do
          Example.setup runner
          checked runner (Store.runTransaction (Tx.sql (Encoding.encodeUtf8 (seedSql size))))
          -- Warm-up is included in the initial size by using disjoint rows.
          _ <- measure runner connections batch 100 (size + pair * 100000)
          values <- measure runner connections batch 10000 (size + pair * 100000 + 100)
          let path = output <> "/ordinary-" <> show size <> "-" <> show connections <> "-" <> show batch <> "-" <> show pair <> ".json"
          Lazy.writeFile path (Aeson.encode values)
          putStrLn (path <> " " <> show (summary values))
      pure True
    Just mode -> fail ("unsupported evidence mode: " <> mode)

seedSql :: Int -> Text.Text
seedSql size = "INSERT INTO app.state_note_identity SELECT 'intention','seed-'||n,'status','ready','seed-note-'||n FROM generate_series(1," <> Text.pack (show size) <> ") n; ANALYZE app.state_note_identity"

measure :: StoreRunner -> Int -> Int -> Int -> Int -> IO [Double]
measure runner connections batch attempts offset = do
  queue <- newMVar [offset .. offset + attempts - 1]
  completions <- replicateM connections newEmptyMVar
  threads <- forM completions \done -> forkFinally (worker queue []) (putMVar done)
  result <- timeout (300 * 1000000) (mapM takeMVar completions) `finally` mapM_ killThread threads
  case result of
    Nothing -> fail "benchmark timed out"
    Just outcomes -> concat <$> mapM (either (fail . show) pure) outcomes
  where
    worker queue samples = do
      next <- modifyMVar queue \case [] -> pure ([], Nothing); n : rest -> pure (rest, Just n)
      case next of
        Nothing -> pure samples
        Just n -> do
          let candidate = "note-" <> Text.pack (show n)
              note = Example.exampleNote candidate candidate
          start <- getMonotonicTimeNSec
          outcome <- checked runner (runDomainCommandWithCatalogProjections defaultRunCommandOptions (Example.handler batch) (stream candidate) (Example.CreateNote (Example.notePayload note)) Example.catalog Example.commandSet)
          case outcome of
            Right DomainProjectionCommandApplied {} -> pure ()
            other -> fail ("unexpected ordinary outcome: " <> show other)
          end <- getMonotonicTimeNSec
          worker queue (fromIntegral (end - start) / 1000 : samples)

checked (StoreRunner run) action = run action >>= either (fail . show) pure

summary :: [Double] -> (Double, Double, Double, Double)
summary values = (percentile 0.5, percentile 0.95, percentile 0.99, maximum values)
  where
    sorted = List.sort values
    percentile fraction = sorted !! min (length sorted - 1) (floor (fraction * fromIntegral (length sorted)))
