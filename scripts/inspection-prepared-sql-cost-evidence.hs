{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Measure client allocation for shared prepared statements of different lengths.
import Control.Monad (forM_, replicateM_, unless)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Ops.Http
import Keiro.Test.Postgres
import Keiro.Workflow.Instance qualified as Instance
import Kiroku.Store.Connection
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Transaction (runTransaction)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.Mem (performMajorGC)

main :: IO ()
main = do
  [output] <- getArgs
  enabled <- getRTSStatsEnabled
  unless enabled (fail "run with +RTS -T")
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture -> withFreshDatabase fixture $ \url ->
    withStore (defaultConnectionSettings url) {poolSize = 1} $ \writer -> do
      _ <- runStoreIO writer (runTransaction (Instance.upsertInstanceTx "one" "schema-cost" 0 Instance.WfRunning Nothing)) >>= right
      withOpsInspectionPool defaultInspectionLimits (defaultConnectionSettings url) $ \pool -> do
        let query bytes = Statement.preparable ("SELECT true /*" <> Text.replicate bytes "x" <> "*/") E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))
            small = query 0
            large = query 180000
            execute statement = do
              value <- Pool.use pool (Session.statement () statement) >>= right
              unless value (fail "unexpected diagnostic result")
        forM_ [1 .. (5 :: Int)] $ \trial ->
          forM_ [("small-sql", execute small), ("large-sql", execute large)] $ \(label, action) -> do
            replicateM_ 10 action
            performMajorGC
            before <- getRTSStats
            start <- getMonotonicTimeNSec
            replicateM_ 100 action
            end <- getMonotonicTimeNSec
            performMajorGC
            after <- getRTSStats
            let artifact = object ["trial" .= trial, "case" .= label, "operations" .= (100 :: Int), "allocated_bytes" .= (after.allocated_bytes - before.allocated_bytes), "cpu_ns" .= (after.cpu_ns - before.cpu_ns), "elapsed_ns" .= (end - start)]
                path = output </> (show trial <> "-" <> label <> ".json")
            Lazy.writeFile path (Aeson.encode artifact)
            putStrLn path

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
