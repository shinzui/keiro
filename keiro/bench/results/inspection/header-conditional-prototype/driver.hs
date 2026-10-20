{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Attribute header-poll cost to the real schema verifier and point read.
-- This diagnostic never changes production verification or caches its result.
import Control.Monad (forM_, replicateM_, unless)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hasql.Pool qualified as Pool
import Keiro.Migrations.SchemaCheck (verifyExpectedSchemaSession)
import Keiro.Ops qualified as Ops
import Keiro.Ops.Http
import Keiro.Ops.Http.Application (OpsHttpOperations (..), opsApplicationWithOperations)
import Keiro.Ops.Http.Budget (encodeBounded, newInspectionBudget)
import Keiro.Ops.Render (OpsOutcome (Succeeded), OpsResult (..), withEncodedJson)
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
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Mem (performMajorGC)
import System.Process (readProcessWithExitCode)

main :: IO ()
main = do
  (output, realTcp) <-
    getArgs >>= \case
      [path] -> pure (path, False)
      [path, "tcp"] -> pure (path, True)
      _ -> fail "expected OUTPUT_DIRECTORY [tcp]"
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
            pointSession = do
              result <- Pool.use pool (Instance.lookupInstanceSession (WorkflowName "schema-cost") (WorkflowId "one")) >>= right
              case result of Just _ -> pure (); Nothing -> fail "missing diagnostic instance"
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
        firstImage <- Pool.use pool (Instance.lookupInstanceConditionalSession (1024 * 1024) Nothing (WorkflowName "schema-cost") (WorkflowId "one")) >>= right
        imageKey <- case firstImage of
          Just (Instance.HeaderChanged key _) -> pure key
          other -> fail (show other)
        rendered <- readIORef valueRef
        encoded <- encodeBounded (1024 * 1024) rendered >>= maybe (fail "unexpected large initial header") pure
        imageCache <- newIORef (imageKey, withEncodedJson (Lazy.toStrict encoded) (OpsResult [] [] rendered))
        let conditional _ _ = do
              (known, previous) <- readIORef imageCache
              observed <- Pool.use pool (Instance.lookupInstanceConditionalSession (1024 * 1024) (Just known) (WorkflowName "schema-cost") (WorkflowId "one")) >>= right
              case observed of
                Just Instance.HeaderUnchanged -> pure (Succeeded previous)
                Just (Instance.HeaderChanged key current) -> do
                  let result = OpsResult [] [] (Inspection.instanceToJson current)
                  encoded <- encodeBounded (1024 * 1024) result.jsonValue >>= maybe (fail "unexpected large changed header") pure
                  let ready = withEncodedJson (Lazy.toStrict encoded) result
                  writeIORef imageCache (key, ready)
                  pure (Succeeded ready)
                other -> fail (show other)
            unchanged = do
              observed <- Pool.use pool (Instance.lookupInstanceConditionalSession (1024 * 1024) (Just imageKey) (WorkflowName "schema-cost") (WorkflowId "one")) >>= right
              unless (observed == Just Instance.HeaderUnchanged) (fail (show observed))
        conditionalHeader <- mount verification conditional
        let header application = do
              response <- runSession (srequest (SRequest (setPath defaultRequest "/wf/inspect/header/schema-cost/one") "")) application
              unless (simpleStatus response == status200) (fail (show response))
        let applications = [("http-header", app), ("http-no-database", noDatabase), ("http-static-json-no-database", noDatabaseStaticJson), ("http-no-schema", noSchema), ("http-static-json-with-schema", noRead), ("http-conditional-header", conditionalHeader)]
        forM_ [1 .. (5 :: Int)] $ \trial -> do
          forM_ [("point-read", pointRead), ("point-session", pointSession), ("point-conditional-unchanged", unchanged), ("schema-verification", verify)] $ \(label, action) ->
            measure output trial label 100 (replicateM_ 10 action) (replicateM_ 100 action)
          forM_ applications $ \(label, application) ->
            if realTcp
              then withOpsHttpServer defaultOpsHttpServerConfig {port = 0} application $ \server ->
                measure output trial ("tcp-" <> label) 1000 (tcpClient server.serverPort 10) (tcpClient server.serverPort 1000)
              else measure output trial label 100 (replicateM_ 10 (header application)) (replicateM_ 100 (header application))

measure :: FilePath -> Int -> String -> Int -> IO () -> IO () -> IO ()
measure output trial label count warm action = do
  warm
  performMajorGC
  before <- getRTSStats
  start <- getMonotonicTimeNSec
  action
  end <- getMonotonicTimeNSec
  performMajorGC
  after <- getRTSStats
  let artifact = object ["trial" .= trial, "case" .= label, "operations" .= count, "allocated_bytes" .= (after.allocated_bytes - before.allocated_bytes), "cpu_ns" .= (after.cpu_ns - before.cpu_ns), "elapsed_ns" .= (end - start)]
      path = output </> (show trial <> "-" <> label <> ".json")
  Lazy.writeFile path (Aeson.encode artifact)
  putStrLn path

-- Client allocations are outside the RTS counters. A new retained connection
-- per bulk run includes one connection setup across 1,000 requests; this is
-- allocation attribution, not the matched writer latency acceptance profile.
tcpClient :: Int -> Int -> IO ()
tcpClient serverPort count = do
  let program = unlines ["import http.client,sys", "connection=http.client.HTTPConnection('127.0.0.1',int(sys.argv[1]),timeout=10)", "for _ in range(int(sys.argv[2])):", "    connection.request('GET','/wf/inspect/header/schema-cost/one')", "    response=connection.getresponse()", "    response.read()", "    assert response.status==200,response.status", "connection.close()"]
  (exit, _, errors) <- readProcessWithExitCode "python3" ["-c", program, show serverPort, show count] ""
  unless (exit == ExitSuccess) (fail errors)

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
