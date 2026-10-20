module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Exception (bracket, finally)
import Control.Monad (forM_, replicateM)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Ops qualified as Ops
import Keiro.Ops.Env
import Keiro.Ops.Http
import Keiro.Ops.Http.Application
import Keiro.Ops.Http.Budget
import Keiro.Ops.Http.Config qualified
import Keiro.Ops.Http.Route
import Keiro.Ops.Render
import Keiro.Ops.ReplayAudit qualified as Audit
import Keiro.PGMQ
import Keiro.Projection.Catalog qualified as Catalog
import Keiro.Projection.Catalog.Operations qualified as CatalogOperations
import Keiro.Test.Postgres
import Keiro.Timer qualified as Timer
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry)
import Keiro.Workflow.Resume (defaultWorkflowResumeOptions)
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Connection
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Read (getStream)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types hiding (id)
import Network.HTTP.Client qualified as Client
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Test hiding (request)
import Options.Applicative qualified as Options
import Options.Applicative.Common (mapParser)
import Options.Applicative.Types qualified as Types
import Pgmq.Migration qualified as Pgmq
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec

main :: IO ()
main = do
  pgmq <- either (fail . show) pure Pgmq.pgmqMigrations
  withMigratedSuiteWith [pgmq] $ \fixture -> hspec (spec fixture)

spec :: Fixture -> Spec
spec fixture = do
  describe "request translation" $ do
    it "preserves path and repeated option order, converting snake_case" $ do
      translateRequest Set.empty ["wf", "show", "approval", "wf-1"] [] `shouldBe` Right ["wf", "show", "approval", "wf-1"]
      translateRequest Set.empty ["wf", "list"] [("status", Just "running"), ("status", Just "failed"), ("min_age", Just "5m")]
        `shouldBe` Right ["wf", "list", "--status=running", "--status=failed", "--min-age=5m"]
    it "translates flags using only the selected command grammar" $ do
      let parser =
            Options.hsubparser
              ( Options.command "flag" (Options.info (Options.switch (Options.long "shared")) mempty)
                  <> Options.command "option" (Options.info ((== ("yes" :: String)) <$> Options.strOption (Options.long "shared")) mempty)
              )
          flags = flagNames parser
      flags ["flag"] `shouldBe` Set.singleton "shared"
      flags ["option"] `shouldBe` Set.empty
      translateRequest (flags ["flag"]) ["flag"] [("shared", Just "true")] `shouldBe` Right ["flag", "--shared"]
      translateRequest (flags ["flag"]) ["flag"] [("shared", Just "false")] `shouldBe` Right ["flag"]
      translateRequest (flags ["option"]) ["option"] [("shared", Just "yes")] `shouldBe` Right ["option", "--shared=yes"]
      translateRequest (flags ["flag"]) ["flag"] [("shared", Just "yes")] `shouldBe` Left (InvalidFlagValue "shared" "yes")
    it "rejects global options, malformed keys, empty and option-like segments" $ do
      forM_ ["json", "force", "database_url", "allow_schema_drift", "help"] $ \key ->
        translateRequest Set.empty ["wf"] [(key, Nothing)] `shouldBe` Left (ReservedQueryKey key)
      forM_ ["Bad", "with-hyphen", "", "x y"] $ \key ->
        translateRequest Set.empty ["wf"] [(key, Nothing)] `shouldBe` Left (InvalidQueryKey key)
      translateRequest Set.empty [""] [] `shouldBe` Left EmptyPathSegment
      translateRequest Set.empty ["--force"] [] `shouldBe` Left (OptionLikePathSegment "--force")
    it "uses the real parser including the legacy two-value after option" $ do
      let parsed path query = either (const False) parses (translateRequest (flagNames (Ops.commandParser Ops.emptyAppHooks) path) path query)
          parses args = case parseArguments Ops.emptyAppHooks args of Parsed _ -> True; Rejected _ -> False
      parsed ["wf", "list", "instance-1"] [("after", Just "approval")] `shouldBe` True
      parsed ["wf", "list"] [("limit", Just "abc")] `shouldBe` False
      case parseArguments Ops.emptyAppHooks ["wf", "list"] of
        Parsed command -> Ops.isMutation command `shouldBe` False
        _ -> expectationFailure "read did not parse"
      case parseArguments Ops.emptyAppHooks ["outbox", "maintenance-pass"] of
        Parsed command -> Ops.isMutation command `shouldBe` True
        _ -> expectationFailure "mutation did not parse"
  describe "budget" $ do
    it "rejects excess work immediately and releases a cancelled permit after cleanup" $ do
      budget <- newInspectionBudget defaultInspectionLimits
      entered <- newChanCounter
      gate <- newEmptyMVar
      let blocked = withInspectionBudget budget 10 (signalCounter entered >> takeMVar gate)
      bracket (replicateM 4 (async blocked)) (mapM_ cancel) $ \jobs -> do
        awaitCounter entered 4
        withInspectionBudget budget 1 (pure ()) `shouldReturn` Left InspectionBusy
        case jobs of first : _ -> cancel first; [] -> expectationFailure "missing jobs"
        withInspectionBudget budget 1 (pure ()) `shouldReturn` Right ()
    it "joins timed-out work and keeps the permit reusable" $ do
      budget <- newInspectionBudget defaultInspectionLimits
      cleaned <- newEmptyMVar
      withInspectionBudget budget 1 (threadDelay 3000000 `finally` putMVar cleaned ()) `shouldReturn` Left InspectionTimedOut
      tryTakeMVar cleaned `shouldReturn` Just ()
      withInspectionBudget budget 1 (pure ()) `shouldReturn` Right ()
    it "bounds encoding and rejects invalid host limits" $ do
      encodeBounded 10 (String (Text.replicate 10000 "x")) `shouldReturn` Nothing
      encodeBounded 4 (String "hi") `shouldReturn` Just "\"hi\""
      newInspectionBudget defaultInspectionLimits {maxConcurrentReads = 0} `shouldThrow` anyIOException
  around (withFreshStore fixture) $ do
    describe "HTTP boundary" $ do
      it "shares the supported read/write classification across every mounted domain" $ \store -> do
        seedInspection store
        app <- opsApplication defaultOpsHttpConfig hooks store
        let domainWords = Set.fromList (concat (mapParser (\_ option -> case Types.optMain option of Types.CmdReader _ commands -> map (Text.pack . fst) commands; _ -> []) (Ops.commandParser hooks)))
        domainWords `shouldBe` Set.fromList ("pgmq" : "replay-audit" : map (Text.takeWhile (/= '/') . Text.drop 1 . fst) commandPairs)
        forM_ commandPairs $ \(readPath, mutationPath) -> do
          response <- call app methodGet readPath ""
          (readPath, simpleStatus response, body response) `shouldSatisfy` (\(_, status, _) -> status == status200)
          readPost <- call app methodPost readPath ""
          simpleStatus readPost `shouldBe` status405
          lookup hAllow (simpleHeaders readPost) `shouldBe` Just methodGet
          mutationGet <- call app methodGet mutationPath ""
          simpleStatus mutationGet `shouldBe` status405
          lookup hAllow (simpleHeaders mutationGet) `shouldBe` Just methodPost
          disabled <- call app methodPost mutationPath "{\"confirm\":\"execute\"}"
          assertError disabled status403 "mutations_disabled"
      it "renders a real preview and applies the confirmed operation only" $ \store -> do
        seedInspection store
        app <- opsApplication defaultOpsHttpConfig {mutations = MutationsEnabled} hooks store
        preview <- call app methodPost "/stream/soft-delete/order-1" ""
        simpleStatus preview `shouldBe` status200
        field "outcome" (body preview) `shouldBe` Just (String "preview")
        beforeStream <- runStoreIO store (getStream (StreamName "order-1")) >>= either (fail . show) pure
        fmap (isJust . (.deletedAt)) beforeStream `shouldBe` Just False
        direct <- case parseArguments hooks ["stream", "soft-delete", "order-1"] of
          Parsed command -> Ops.runCommand hooks (OpsEnv store Json False [] False) command
          Rejected err -> fail (Text.unpack err)
        case direct of
          PreviewRequired result invocation -> do
            field "result" (body preview) `shouldBe` Just result.jsonValue
            field "cli_reinvocation" (body preview) `shouldBe` Just (String invocation)
          _ -> expectationFailure "expected supported preview"
        confirmed <- call app methodPost "/stream/soft-delete/order-1" "{\"confirm\":\"execute\"}"
        simpleStatus confirmed `shouldBe` status200
        field "outcome" (body confirmed) `shouldBe` Just (String "executed")
        afterStream <- runStoreIO store (getStream (StreamName "order-1")) >>= either (fail . show) pure
        fmap (isJust . (.deletedAt)) afterStream `shouldBe` Just True
        forM_ ["{\"confirm\":true}", "{\"confirm\":\"yes\"}", "{\"confirm\":\"execute\",\"extra\":1}", "[]"] $ \bad -> do
          response <- call app methodPost "/stream/soft-delete/order-1" bad
          assertError response status400 "invalid_confirmation"
      it "requires preview and confirmation for DLQ reads that reserve messages" $ \store -> do
        seedInspection store
        readOnly <- opsApplication defaultOpsHttpConfig hooks store
        denied <- call readOnly methodPost "/pgmq/dlq/read?queue=http_test" ""
        assertError denied status403 "mutations_disabled"
        getResponse <- call readOnly methodGet "/pgmq/dlq/read?queue=http_test" ""
        assertError getResponse status405 "method_not_allowed"
        app <- opsApplication defaultOpsHttpConfig {mutations = MutationsEnabled} hooks store
        preview <- call app methodPost "/pgmq/dlq/read?queue=http_test" ""
        field "outcome" (body preview) `shouldBe` Just (String "preview")
        response <- call app methodPost "/pgmq/dlq/read?queue=http_test" "{\"confirm\":\"execute\"}"
        field "outcome" (body response) `shouldBe` Just (String "executed")
        field "result" (body response) `shouldSatisfy` maybe False (\case Array items -> not (null items); _ -> False)
        next <- call app methodPost "/pgmq/dlq/read?queue=http_test" "{\"confirm\":\"execute\"}"
        field "result" (body next) `shouldBe` Just (Array mempty)
      it "rejects invalid requests and has structured errors" $ \store -> do
        app <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks store
        forM_ ["/wf/list?limit=abc", "/wf", "/nope", "/wf/list?force=true", "/wf/list?%FF=x", "/wf/list?name=%FF", "/wf/--force"] $ \path -> do
          response <- call app methodGet path ""
          assertError response status400 "invalid_request"
        response <- call app methodGet "/" ""
        assertError response status404 "not_found"
      it "applies exact-origin CORS without credentials or duplicate headers" $ \store -> do
        app <- opsApplication defaultOpsHttpConfig {allowedOrigins = ["http://ui.example"]} Ops.emptyAppHooks store
        let request origin method = (setPath defaultRequest "/wf/list") {requestMethod = method, requestHeaders = [("Origin", origin), ("Access-Control-Request-Method", "GET")]}
        allowed <- runSession (srequest (SRequest (request "http://ui.example" methodGet) "")) app
        lookup "Access-Control-Allow-Origin" (simpleHeaders allowed) `shouldBe` Just "http://ui.example"
        lookup "Access-Control-Allow-Credentials" (simpleHeaders allowed) `shouldBe` Nothing
        preflight <- runSession (srequest (SRequest (request "http://ui.example" methodOptions) "")) app
        simpleStatus preflight `shouldBe` status204
        denied <- runSession (srequest (SRequest (request "http://other.example" methodGet) "")) app
        lookup "Access-Control-Allow-Origin" (simpleHeaders denied) `shouldBe` Nothing
        disabledApp <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks store
        disabled <- runSession (srequest (SRequest (request "http://ui.example" methodGet) "")) disabledApp
        lookup "Access-Control-Allow-Origin" (simpleHeaders disabled) `shouldBe` Nothing
      it "bounds requests and results before responding" $ \store -> do
        let config = defaultOpsHttpConfig {inspectionLimits = defaultInspectionLimits {maxRequestBytes = 30, maxResponseBytes = 2}}
        app <- opsApplication config Ops.emptyAppHooks store
        tooLarge <- call app methodGet ("/wf/list?name=" <> Text.replicate 100 "x") ""
        assertError tooLarge status413 "inspection_request_too_large"
        health <- call app methodGet "/health" ""
        assertError health status413 "inspection_result_too_large"
        enabled <- opsApplication defaultOpsHttpConfig {mutations = MutationsEnabled} hooks store
        oversized <- call enabled methodPost "/outbox/maintenance-pass" (LazyByteString.replicate 1025 32)
        assertError oversized status413 "inspection_request_too_large"
      it "keeps hook-dependent commands absent unless mounted and preserves supported failures" $ \store -> do
        standalone <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks store
        absent <- call standalone methodGet "/rebuild/list" ""
        assertError absent status400 "invalid_request"
        app <- opsApplication defaultOpsHttpConfig hooks store
        audited <- call app methodGet "/replay-audit?full=true" ""
        assertError audited status422 "command_failed"
        listed <- call app methodGet "/rebuild/list" ""
        direct <- case parseArguments hooks ["rebuild", "list"] of
          Parsed command -> Ops.runCommand hooks (OpsEnv store Json False [] False) command
          Rejected err -> fail (Text.unpack err)
        case direct of
          Succeeded result -> body listed `shouldBe` result.jsonValue
          _ -> expectationFailure "expected supported catalog read"
      it "refuses excess requests before verification and cancels schema work on deadline" $ \store -> do
        count <- newIORef (0 :: Int)
        entered <- newEmptyMVar
        let config = defaultOpsHttpConfig {inspectionLimits = defaultInspectionLimits {maxConcurrentReads = 1, readDeadlineSeconds = 1}}
            operations = OpsHttpOperations (modifyIORef' count (+ 1) >> putMVar entered () >> threadDelay 3000000 >> pure (Right [])) (\_ _ -> pure (Succeeded emptyResult))
        budget <- newInspectionBudget config.inspectionLimits
        app <- opsApplicationWithOperations config budget Ops.emptyAppHooks store operations
        withAsync (call app methodGet "/wf/list" "") $ \job -> do
          takeMVar entered
          refused <- call app methodGet "/wf/list" ""
          assertError refused status503 "inspection_busy"
          readIORef count `shouldReturn` 1
          response <- wait job
          assertError response status504 "inspection_timeout"
      it "mounts idly without recurring verification and skips SQL for disabled/invalid requests" $ \store -> do
        count <- newIORef (0 :: Int)
        budget <- newInspectionBudget defaultInspectionLimits
        app <-
          opsApplicationWithOperations
            defaultOpsHttpConfig
            budget
            Ops.emptyAppHooks
            store
            (OpsHttpOperations (modifyIORef' count (+ 1) >> pure (Right [])) (\_ _ -> pure (Succeeded emptyResult)))
        threadDelay 100000
        _ <- call app methodGet "/wf/list?force=true" ""
        _ <- call app methodPost "/outbox/maintenance-pass" ""
        readIORef count `shouldReturn` 0
      it "serves through a loopback socket and releases its port" $ \store -> do
        app <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks store
        manager <- Client.newManager Client.defaultManagerSettings
        port <- withOpsHttpServer defaultOpsHttpServerConfig {port = 0} app $ \server -> do
          request <- Client.parseRequest ("http://127.0.0.1:" <> show server.serverPort <> "/health")
          response <- Client.httpLbs request manager
          Client.responseStatus response `shouldBe` status200
          pure server.serverPort
        request <- Client.parseRequest ("http://127.0.0.1:" <> show port <> "/health")
        freshManager <- Client.newManager Client.defaultManagerSettings
        Client.httpLbs request manager `shouldThrow` (\(_ :: Client.HttpException) -> True)
        Client.httpLbs request freshManager `shouldThrow` (\(_ :: Client.HttpException) -> True)
  around (withFreshDatabase fixture) $ do
    describe "schema handshake" $ do
      it "bounds SQL on every inspection connection and releases pool capacity on cancellation" $ \url -> do
        let limits = defaultInspectionLimits {statementTimeoutMillis = 100, maxConcurrentReads = 1}
        withOpsInspectionPool limits (defaultConnectionSettings url) $ \pool -> do
          slow <- Pool.use pool (Session.script "SELECT pg_sleep(1)")
          slow `shouldSatisfy` either (const True) (const False)
          result <- timeout 1000000 (Pool.use pool (Session.script "SELECT 1"))
          result `shouldBe` Just (Right ())
        withOpsInspectionPool defaultInspectionLimits {maxConcurrentReads = 1} (defaultConnectionSettings url) $ \pool ->
          bracket (Connection.acquire (Settings.connectionString url) >>= either (fail . show) pure) Connection.release $ \control ->
            withAsync (Pool.use pool (Session.script "SELECT pg_sleep(10)")) $ \job -> do
              let active = do
                    result <- Connection.use control (Session.statement () (Statement.preparable "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND query='SELECT pg_sleep(10)' AND state='active')" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))
                    case result of Right True -> pure (); Right False -> threadDelay 1000 >> active; Left err -> fail (show err)
              timeout 1000000 active `shouldReturn` Just ()
              cancel job
              timeout 1000000 (Pool.use pool (Session.script "SELECT 1")) `shouldReturn` Just (Right ())
        -- The host's ordinary connection was never configured by the pool.
        executeSql url "DO $$ BEGIN IF current_setting('statement_timeout') <> '0' THEN RAISE EXCEPTION 'writer timeout changed'; END IF; END $$"
      it "detects drift after construction, refuses previews/confirmation, and supports explicit policy" $ \url ->
        withStore (defaultConnectionSettings url) $ \store -> do
          app <- opsApplication defaultOpsHttpConfig {mutations = MutationsEnabled} Ops.emptyAppHooks store
          healthy <- call app methodGet "/health" ""
          simpleStatus healthy `shouldBe` status200
          executeSql url "ALTER TABLE keiro.keiro_timers ADD COLUMN http_test_drift text"
          forM_ [(methodGet, "/wf/list", ""), (methodPost, "/outbox/maintenance-pass", ""), (methodPost, "/outbox/maintenance-pass", "{\"confirm\":\"execute\"}")] $ \(method, path, payload) -> do
            response <- call app method path payload
            assertError response status409 "schema_drift"
          health <- call app methodGet "/health" ""
          simpleStatus health `shouldBe` status503
          allowed <- opsApplication defaultOpsHttpConfig {Keiro.Ops.Http.Config.schemaDrift = AllowDrift} Ops.emptyAppHooks store
          response <- call allowed methodGet "/wf/list" ""
          simpleStatus response `shouldBe` status200
          lookup "Keiro-Ops-Schema-Drift" (simpleHeaders response) `shouldBe` Just "1"
    describe "CLI agreement" $ do
      it "agrees with executable JSON across the database-only command domains" $ \url ->
        withStore (defaultConnectionSettings url) $ \store -> do
          seedInspection store
          executable <- opsExecutable
          app <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks store
          forM_ cliReads $ \(path, args) -> do
            (exit, out, err) <- readProcessWithExitCode executable (["--database-url", Text.unpack url] <> args <> ["--json"]) ""
            (path, exit, out, err) `shouldSatisfy` (\(_, code, _, _) -> code == ExitSuccess)
            response <- call app methodGet path ""
            simpleStatus response `shouldBe` status200
            Aeson.eitherDecode (simpleBody response) `shouldBe` (Aeson.eitherDecode (LazyByteString.fromStrict (Char8.pack out)) :: Either String Value)
            err `shouldBe` ""

hooks :: Ops.AppHooks
hooks =
  Ops.emptyAppHooks
    { Ops.workflowResume = Just (Map.empty, defaultWorkflowResumeOptions),
      Ops.timerFire = Just (\_ -> pure Nothing),
      Ops.replayAudit = Just (Audit.OpsAuditConfig []),
      Ops.projectionCatalog =
        Just
          ( case Catalog.validateProjectionCatalog Catalog.emptyProjectionCatalog of
              Catalog.Success catalog -> CatalogOperations.projectionCatalogOperations catalog
              Catalog.Failure errors -> error (show errors)
          )
    }

commandPairs :: [(Text, Text)]
commandPairs =
  [ ("/wf/list", "/wf/cancel/missing/missing"),
    ("/timer/stuck/list", "/timer/cancel/00000000-0000-0000-0000-000000000001"),
    ("/outbox/backlog", "/outbox/maintenance-pass"),
    ("/inbox/backlog", "/inbox/gc"),
    ("/projection/position?subscription=http_test", "/projection/prune-dedup?projection=http_test&before=2026-01-01T00%3A00%3A00Z"),
    ("/shard/status?subscription=http_test", "/shard/relinquish?subscription=http_test&worker=00000000-0000-0000-0000-000000000001"),
    ("/snapshot/show?stream=missing", "/snapshot/delete?stream=missing"),
    ("/stream/subscriptions", "/stream/soft-delete/missing"),
    ("/rebuild/list", "/rebuild/start/missing?run_id=test&requested_by=test&reason=test")
  ]

cliReads :: [(Text, [String])]
cliReads =
  [ ("/wf/list", ["wf", "list"]),
    ("/timer/stuck/list?min_age=0s", ["timer", "stuck", "list", "--min-age", "0s"]),
    ("/outbox/backlog", ["outbox", "backlog"]),
    ("/inbox/backlog", ["inbox", "backlog"]),
    ("/projection/position?subscription=http_test", ["projection", "position", "--subscription", "http_test"]),
    ("/shard/status?subscription=http_test", ["shard", "status", "--subscription", "http_test"]),
    ("/snapshot/show?stream=missing", ["snapshot", "show", "--stream", "missing"]),
    ("/stream/show/order-1", ["stream", "show", "order-1"]),
    ("/stream/subscriptions", ["stream", "subscriptions"])
  ]

call :: Application -> Method -> Text -> LazyByteString.ByteString -> IO SResponse
call app method path payload = runSession (srequest (SRequest ((setPath defaultRequest (Text.encodeUtf8 path)) {requestMethod = method}) payload)) app

body :: SResponse -> Value
body response = either error id (Aeson.eitherDecode (simpleBody response))

field :: Aeson.Key -> Value -> Maybe Value
field key (Object value) = KeyMap.lookup key value
field _ _ = Nothing

assertError :: SResponse -> Status -> Text -> Expectation
assertError response expected code = do
  simpleStatus response `shouldBe` expected
  (field "error" (body response) >>= field "code") `shouldBe` Just (String code)

executeSql :: Text -> Text -> IO ()
executeSql url sql = bracket acquire Connection.release $ \connection -> do
  result <- Connection.use connection (Session.script sql)
  either (fail . show) pure result
  where
    acquire = Connection.acquire (Settings.connectionString url) >>= either (fail . show) pure

opsExecutable :: IO FilePath
opsExecutable = do
  (exit, out, err) <- readProcessWithExitCode "cabal" ["list-bin", "exe:keiro-ops"] ""
  if exit == ExitSuccess then pure (Text.unpack (Text.strip (Text.pack out))) else fail err

newChanCounter :: IO (MVar Int)
newChanCounter = newMVar 0

signalCounter :: MVar Int -> IO ()
signalCounter counter = modifyMVar_ counter (pure . (+ 1))

awaitCounter :: MVar Int -> Int -> IO ()
awaitCounter counter expected = do
  result <- timeout 2000000 loop
  result `shouldBe` Just ()
  where
    loop = do count <- readMVar counter; if count == expected then pure () else threadDelay 1000 >> loop

seedInspection :: KirokuStore -> IO ()
seedInspection store = do
  now <- getCurrentTime
  _ <-
    runStoreIO
      store
      ( appendToStream
          (StreamName "order-1")
          AnyVersion
          [ EventData Nothing (EventType "order.created") (object ["order" .= (1 :: Int)]) Nothing Nothing Nothing,
            EventData Nothing (EventType "order.confirmed") (object ["order" .= (1 :: Int)]) Nothing Nothing Nothing
          ]
      )
      >>= either (fail . show) pure
  runStoreIO store (appendJournalEntry (WorkflowName "approval") (WorkflowId "wf-1") (StepRecorded "received" Null now)) >>= either (fail . show) pure
  let timer = Timer.TimerRequest (Timer.TimerId UUID.nil) "billing" "invoice-1" (addUTCTime (-60) now) Null
  runStoreIO store (runTransaction (Timer.scheduleTimerTx timer)) >>= either (fail . show) pure
  let job = Job {jobName = "http_test", jobQueue = queueRef "http_test", jobCodec = aesonJobCodec, jobOrdering = Unordered, jobPolicy = defaultRetryPolicy} :: Job Value
  result <- runJobEff (JobRuntime store.pool Nothing) $ do
    ensureJobQueue job
    _ <- enqueue job (object ["poison" .= True])
    _ <- runJobOnce 1 job (\_ -> pure (Dead "test poison"))
    pure ()
  either (fail . show) pure result
