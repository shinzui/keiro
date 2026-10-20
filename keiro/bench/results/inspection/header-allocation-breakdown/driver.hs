{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Attribute header-poll cost to the real schema verifier and point read.
-- This diagnostic never changes production verification or caches its result.
import Control.Monad (forM_, replicateM_, unless)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hasql.Pool qualified as Pool
import Keiro.Migrations.SchemaCheck (verifyExpectedSchemaSession)
import Keiro.Ops qualified as Ops
import Keiro.Ops.Http
import Keiro.Ops.Http.Application (OpsHttpOperations (..), opsApplicationWithOperations)
import Keiro.Ops.Http.Budget (newInspectionBudget)
import Keiro.Ops.Render (OpsOutcome (Succeeded), OpsResult (..))
import Keiro.Test.Postgres
import Keiro.Workflow.Inspection qualified as Inspection
import Keiro.Workflow.Instance qualified as Instance
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Kiroku.Store.Connection
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Transaction (runTransaction)
import Network.HTTP.Types (status200)
import Network.Wai (defaultRequest)
import Network.Wai.Test (SRequest (..), runSession, setPath, simpleStatus, srequest)
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
        let store = writer {pool = pool}
            pointRead = do
              result <- runStoreIO store (Instance.lookupInstance (WorkflowName "schema-cost") (WorkflowId "one")) >>= right
              case result of Just _ -> pure (); Nothing -> fail "missing diagnostic instance"
            verify = do
              result <- Pool.use pool verifyExpectedSchemaSession >>= right >>= right
              unless (null result) (fail (show result))
        app <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks store
        row <- runStoreIO store (Instance.lookupInstance (WorkflowName "schema-cost") (WorkflowId "one")) >>= right >>= maybe (fail "missing diagnostic instance") pure
        rowRef <- newIORef row
        valueRef <- newIORef (Inspection.instanceToJson row)
        let renderRow _ _ = do
              current <- readIORef rowRef
              pure (Succeeded (OpsResult [] [] (Inspection.instanceToJson current)))
            staticJson _ _ = do
              value <- readIORef valueRef
              pure (Succeeded (OpsResult [] [] value))
            verification = verify >> pure (Right [])
            mount verification execute = do
              budget <- newInspectionBudget defaultInspectionLimits
              opsApplicationWithOperations defaultOpsHttpConfig budget Ops.emptyAppHooks store (OpsHttpOperations verification execute)
        noDatabase <- mount (pure (Right [])) renderRow
        noDatabaseStaticJson <- mount (pure (Right [])) staticJson
        noSchema <- mount (pure (Right [])) (Ops.runCommand Ops.emptyAppHooks)
        noRead <- mount verification staticJson
        let header application = do
              response <- runSession (srequest (SRequest (setPath defaultRequest "/wf/inspect/header/schema-cost/one") "")) application
              unless (simpleStatus response == status200) (fail (show response))
        forM_ [1 .. (5 :: Int)] $ \trial ->
          forM_ [("point-read", pointRead), ("schema-verification", verify), ("http-header", header app), ("http-no-database", header noDatabase), ("http-static-json-no-database", header noDatabaseStaticJson), ("http-no-schema", header noSchema), ("http-static-json-with-schema", header noRead)] $ \(label, action) -> do
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
