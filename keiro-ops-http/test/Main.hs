module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, bracket, finally, try)
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
import Hasql.Pool.Observation qualified as Observation
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Jitsurei.Inspection (jitsureiProcessManagerInspectors)
import Keiro.Ops qualified as Ops
import Keiro.Ops.Env
import Keiro.Ops.Http
import Keiro.Ops.Http.Application
import Keiro.Ops.Http.Budget
import Keiro.Ops.Http.Config qualified
import Keiro.Ops.Http.Config qualified as Config
import Keiro.Ops.Http.Cors qualified as Cors
import Keiro.Ops.Http.Protocol qualified as Protocol
import Keiro.Ops.Http.Route
import Keiro.Ops.Http.Views qualified as Views
import Keiro.Ops.Render
import Keiro.Ops.ReplayAudit qualified as Audit
import Keiro.Ops.Workflow qualified as Workflow
import Keiro.Ops.WorkflowHeaderCache
import Keiro.PGMQ
import Keiro.Projection.Catalog qualified as Catalog
import Keiro.Projection.Catalog.Operations qualified as CatalogOperations
import Keiro.Test.Postgres
import Keiro.Timer qualified as Timer
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry, continueAsNew, runWorkflow)
import Keiro.Workflow.Resume (defaultWorkflowResumeOptions)
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Connection
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Read (getStream)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types hiding (id)
import Network.HTTP.Client qualified as Client
import Network.HTTP.Types
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as Socket
import Network.Wai
import Network.Wai.Test hiding (request)
import Options.Applicative qualified as Options
import Options.Applicative.Common (mapParser)
import Options.Applicative.Types qualified as Types
import Pgmq.Migration qualified as Pgmq
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Test.ComposeSpec qualified as ComposeSpec
import Test.FeedSpec qualified as FeedSpec
import Test.Hspec
import Test.WebSocketSpec qualified as WebSocketSpec

main :: IO ()
main = do
  pgmq <- either (fail . show) pure Pgmq.pgmqMigrations
  withMigratedSuiteWith [pgmq] $ \fixture -> hspec (spec fixture)

spec :: Fixture -> Spec
spec fixture = do
  ComposeSpec.spec fixture
  FeedSpec.spec fixture
  WebSocketSpec.spec fixture
  describe "live view parameters" $ do
    it "canonicalizes equivalent status sets and bounds subscription inputs" $ do
      Right one <- pure (Views.workflowsView 500 (object ["status_class" .= (["running", "sleeping", "running"] :: [Text])]))
      Right two <- pure (Views.workflowsView 500 (object ["status_class" .= (["sleeping", "running"] :: [Text])]))
      one.viewId `shouldBe` two.viewId
      either (const True) (const False) (Views.timersView 20 (object ["limit" .= (21 :: Int)])) `shouldBe` True
      case Views.timersView 20 (object ["unexpected_filter" .= True]) of
        Left message -> message `shouldSatisfy` Text.isInfixOf "unexpected_filter"
        Right _ -> expectationFailure "unknown filter was accepted"
    it "compares timer state independently of presentation countdowns" $ do
      let one = Views.Item "timer" (object ["timer_id" .= ("timer" :: Text)]) (object ["status" .= ("scheduled" :: Text), "due_in_seconds" .= (10 :: Int)])
          two = one {Views.body = object ["status" .= ("scheduled" :: Text), "due_in_seconds" .= (9 :: Int)]}
      Views.stableItemBody Protocol.Timers one `shouldBe` Views.stableItemBody Protocol.Timers two
      one.body `shouldNotBe` two.body

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
      forM_ [0, -1, maxBound] $ \seconds ->
        newInspectionBudget defaultInspectionLimits {deliveryDeadlineSeconds = seconds} `shouldThrow` anyIOException
  around (withFreshStore fixture) $ do
    describe "mounted process-manager discovery" $ do
      it "serves Jitsurei metadata without journal instances and agrees with the parsed CLI" $ \store -> do
        let mounted = Ops.emptyAppHooks {Ops.processManagers = Just jitsureiProcessManagerInspectors}
            expected = object ["items" .= [object ["name" .= ("jitsurei-fulfillment" :: Text), "category" .= ("fulfillment" :: Text), "snapshots_configured" .= False, "snapshot_policy" .= ("never" :: Text), "timers_configured" .= Null]]]
        app <- opsApplication defaultOpsHttpConfig mounted store
        response <- call app methodGet "/pm/types" ""
        simpleStatus response `shouldBe` status200
        body response `shouldBe` expected
        case parseArguments mounted ["pm", "types"] of
          Parsed command -> do
            Succeeded result <- Ops.runCommand mounted (OpsEnv store Json False [] False) command
            result.jsonValue `shouldBe` body response
          _ -> expectationFailure "CLI pm types did not parse"
        refused <- call app methodPost "/pm/types" ""
        assertError refused status405 "method_not_allowed"
        named <- call app methodGet "/pm/types?name=jitsurei-fulfillment" ""
        assertError named status400 "invalid_request"
      it "distinguishes absent and empty hooks and bounds large catalogs" $ \store -> do
        absent <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks store
        forM_ ["/pm/types", "/pm/list?name=missing"] $ \path -> do
          response <- call absent methodGet path ""
          assertError response status400 "invalid_request"
        empty <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks {Ops.processManagers = Just Map.empty} store
        response <- call empty methodGet "/pm/types" ""
        simpleStatus response `shouldBe` status200
        body response `shouldBe` object ["items" .= ([] :: [Value])]
        let descriptor = snd (Map.findMin jitsureiProcessManagerInspectors)
            catalog = Map.fromList [("alias-" <> Text.pack (show n), descriptor) | n <- [1 .. 1000 :: Int]]
            mounted = Ops.emptyAppHooks {Ops.processManagers = Just catalog}
            config = defaultOpsHttpConfig {inspectionLimits = defaultInspectionLimits {maxResponseBytes = 1024}}
        bounded <- opsApplication config mounted store
        oversized <- call bounded methodGet "/pm/types" ""
        assertError oversized status413 "inspection_result_too_large"
      it "keeps fresh schema refusal for metadata reads" $ \store -> do
        app <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks {Ops.processManagers = Just jitsureiProcessManagerInspectors} store
        Right () <- Pool.use store.pool (Session.script "ALTER TABLE keiro.keiro_timers ADD COLUMN pm_types_drift text")
        response <- call app methodGet "/pm/types" ""
        assertError response status409 "schema_drift"
    describe "workflow page routes" $ do
      it "rejects an unrepresentable outgoing cursor instead of returning an unusable token" $ \store -> do
        result <- Pool.use store.pool (Session.script "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) VALUES ('a',repeat('界',2000),'running'),('b',repeat('界',2000),'running')")
        either (fail . show) pure result
        app <- opsApplication defaultOpsHttpConfig hooks store
        response <- call app methodGet "/wf/inspect/list?limit=1" ""
        assertError response status413 "inspection_result_too_large"
      it "returns wide workflow keys within the continuation and response caps" $ \store -> do
        result <- Pool.use store.pool (Session.script "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) SELECT 'wide-'||n,repeat('x',2700),'running' FROM generate_series(1,65) n")
        either (fail . show) pure result
        app <- opsApplication defaultOpsHttpConfig hooks store
        response <- call app methodGet "/wf/inspect/list?limit=1" ""
        simpleStatus response `shouldBe` status200
        field "next_cursor" (body response) `shouldSatisfy` isJust
      it "pages supported reads through the same parser and maps typed failures" $ \store -> do
        seedInspection store
        now <- getCurrentTime
        forM_ ["wf-2", "wf-3"] $ \wid ->
          runStoreIO store (appendJournalEntry (WorkflowName "approval") (WorkflowId wid) (StepRecorded "received" Null now)) >>= either (fail . show) pure
        app <- opsApplication defaultOpsHttpConfig hooks store
        let pages cursor = do
              response <- call app methodGet ("/wf/inspect/list?limit=1" <> maybe "" ("&after=" <>) cursor) ""
              simpleStatus response `shouldBe` status200
              field "observed_at" (body response) `shouldSatisfy` maybe False (\case String _ -> True; _ -> False)
              let items = case field "items" (body response) of Just (Array rows) -> foldr (:) [] rows; _ -> []
              length items `shouldBe` 1
              rest <- case field "next_cursor" (body response) of Just (String token) -> pages (Just token); _ -> pure []
              pure (items <> rest)
        rows <- pages Nothing
        map (field "workflow_id") rows `shouldBe` map (Just . String) ["wf-1", "wf-2", "wf-3"]
        header <- call app methodGet "/wf/inspect/header/approval/wf-1" ""
        legacy <- call app methodGet "/wf/show/approval/wf-1" ""
        field "instance" (body legacy) `shouldBe` Just (body header)
        forM_ ["header", "journal", "steps", "children", "awakeables"] $ \command -> do
          response <- call app methodGet ("/wf/inspect/" <> command <> "/approval/wf-1") ""
          simpleStatus response `shouldBe` status200
        malformed <- call app methodGet "/wf/inspect/list?after=not-a-cursor" ""
        assertError malformed status400 "invalid_cursor"
        oversized <- call app methodGet "/wf/inspect/list?limit=501" ""
        assertError oversized status400 "invalid_page_size"
        runStoreIO store (appendJournalEntry (WorkflowName "approval") (WorkflowId "wf-1") (StepRecorded "second" Null now)) >>= either (fail . show) pure
        first <- call app methodGet "/wf/inspect/steps/approval/wf-1?limit=1" ""
        token <- case field "next_cursor" (body first) of Just (String value) -> pure value; _ -> fail "missing step cursor"
        _ <- runStoreIO store (runWorkflow (WorkflowName "approval") (WorkflowId "wf-1") (continueAsNew () >> pure ())) >>= either (fail . show) pure
        rotated <- call app methodGet ("/wf/inspect/steps/approval/wf-1?after=" <> token) ""
        assertError rotated status409 "cursor_generation_mismatch"
        freshHeader <- call app methodGet "/wf/inspect/header/approval/wf-1" ""
        field "generation" (body freshHeader) `shouldBe` Just (Number 1)
    describe "fresh header presentation reuse" $ do
      it "preserves canonical bytes and observes edits, deletion and recreation" $ \store -> do
        seedInspection store
        app <- opsApplication defaultOpsHttpConfig hooks store
        let readHeader = call app methodGet "/wf/inspect/header/approval/wf-1" ""
            sql statement = Pool.use store.pool (Session.script statement) >>= either (fail . show) pure
        first <- readHeader
        second <- readHeader
        shouldBe (simpleBody second) (simpleBody first)
        sql "UPDATE keiro.keiro_workflows SET attempts=7,last_error='changed',leased_by='new-owner' WHERE workflow_name='approval' AND workflow_id='wf-1'"
        changed <- readHeader
        shouldBe (field "attempts" (body changed)) (Just (Number 7))
        shouldBe (field "last_error" (body changed)) (Just (String "changed"))
        shouldBe (field "leased_by" (body changed)) (Just (String "new-owner"))
        legacy <- call app methodGet "/wf/show/approval/wf-1" ""
        shouldBe (field "instance" (body legacy)) (Just (body changed))
        sql "DELETE FROM keiro.keiro_workflows WHERE workflow_name='approval' AND workflow_id='wf-1'"
        missing <- readHeader
        assertError missing status422 "command_failed"
        sql "INSERT INTO keiro.keiro_workflows(workflow_name,workflow_id,status) VALUES ('approval','wf-1','failed')"
        recreated <- readHeader
        shouldBe (field "status" (body recreated)) (Just (String "failed"))
      it "enforces byte and entry limits through churn, oversized changes and misses" $ \store -> do
        let sql statement = Pool.use store.pool (Session.script statement) >>= either (fail . show) pure
            encode value = fmap LazyByteString.toStrict <$> encodeBounded (1024 * 1024) value
        sql "INSERT INTO keiro.keiro_workflows(workflow_name,workflow_id,status) SELECT 'cache','id-'||n,'running' FROM generate_series(1,96) n"
        cache <- newWorkflowHeaderCache (1024 * 1024) encode
        let readHeader wid = Ops.runCommandWithHeaderCache cache hooks (OpsEnv store Json False [] False) (Ops.Workflow (Workflow.Inspect (Workflow.InspectHeader (Workflow.WorkflowRef "cache" wid))))
            bounded = do
              (count, bytes) <- workflowHeaderCacheUsage cache
              shouldSatisfy count (<= 32)
              shouldSatisfy bytes (<= 1024 * 1024)
        forM_ [1 .. (96 :: Int)] $ \n -> do
          (outcome, encoded) <- readHeader ("id-" <> Text.pack (show n))
          shouldSatisfy outcome (\case Succeeded _ -> True; _ -> False)
          shouldSatisfy encoded isJust
          bounded
        shouldReturn (fmap fst (workflowHeaderCacheUsage cache)) 32
        sql "UPDATE keiro.keiro_workflows SET last_error=repeat('x',20000)"
        forM_ [1 .. (96 :: Int)] $ \n -> readHeader ("id-" <> Text.pack (show n)) >> bounded
        (largeCount, _) <- workflowHeaderCacheUsage cache
        shouldSatisfy largeCount (< 32)
        sql "DELETE FROM keiro.keiro_workflows"
        forM_ [1 .. (96 :: Int)] $ \n -> readHeader ("id-" <> Text.pack (show n)) >> bounded
        shouldReturn (workflowHeaderCacheUsage cache) (0, 0)
      it "fails oversized changes explicitly and reapplies schema policy to warm headers" $ \store -> do
        seedInspection store
        let sql statement = Pool.use store.pool (Session.script statement) >>= either (fail . show) pure
            config = defaultOpsHttpConfig {inspectionLimits = defaultInspectionLimits {maxResponseBytes = 1024}}
        app <- opsApplication config hooks store
        let readHeader = call app methodGet "/wf/inspect/header/approval/wf-1" ""
        warm <- readHeader
        shouldBe (simpleStatus warm) status200
        sql "UPDATE keiro.keiro_workflows SET last_error=repeat('x',100000) WHERE workflow_id='wf-1'"
        tooLarge <- readHeader
        assertError tooLarge status413 "inspection_result_too_large"
        sql "UPDATE keiro.keiro_workflows SET last_error=NULL WHERE workflow_id='wf-1'"
        restored <- readHeader
        shouldBe (body restored) (body warm)
        sql "ALTER TABLE keiro.keiro_timers ADD COLUMN header_test_drift text"
        refused <- readHeader
        assertError refused status409 "schema_drift"
        allowed <- opsApplication config {Keiro.Ops.Http.Config.schemaDrift = AllowDrift} hooks store
        first <- call allowed methodGet "/wf/inspect/header/approval/wf-1" ""
        second <- call allowed methodGet "/wf/inspect/header/approval/wf-1" ""
        shouldBe (simpleBody second) (simpleBody first)
        shouldBe (lookup "Keiro-Ops-Schema-Drift" (simpleHeaders second)) (Just "1")
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
      it "normalizes parsed origins and rejects malformed or repeated origins" $ \_ -> do
        let allowed headers = Cors.originAllowed ["https://console.example"] False headers
        forM_ [[], [("Origin", "http://EXAMPLE.test:80"), (hHost, "example.test")], [("Origin", "HTTPS://CONSOLE.EXAMPLE:443")]] $ \headers ->
          allowed headers `shouldBe` True
        forM_ [[("Origin", "null")], [("Origin", "https://console.example/path")], [("Origin", "https://console.example#fragment")], [("Origin", "https://user@console.example")], [("Origin", "https://console.example https://other.example")], [("Origin", "https://console.example"), ("Origin", "https://console.example")], [("Origin", "http://console.example")], [("Origin", "https://console.example:444")], [("Origin", "https://evil.example"), ("X-Forwarded-Host", "evil.example")]] $ \headers ->
          allowed headers `shouldBe` False
      it "rejects foreign mutations before reading their body or verifying schema" $ \store -> do
        count <- newIORef (0 :: Int)
        budget <- newInspectionBudget defaultInspectionLimits
        app <-
          opsApplicationWithOperations
            defaultOpsHttpConfig {mutations = MutationsEnabled}
            budget
            hooks
            store
            (OpsHttpOperations (modifyIORef' count (+ 1) >> pure (Right [])) (\_ _ -> modifyIORef' count (+ 1) >> pure (Succeeded emptyResult)))
        let foreignApp request respond = app (request {requestBody = fail "foreign request body was read"}) respond
            req = (setPath defaultRequest "/stream/soft-delete/order-1") {requestMethod = methodPost, requestHeaders = [("Origin", "https://evil.example"), (hContentType, "application/json")]}
        refused <- runSession (srequest (SRequest req "{\"confirm\":\"execute\"}")) foreignApp
        assertError refused status403 "origin_not_allowed"
        readIORef count `shouldReturn` 0
      it "requires JSON for nonempty bodies including chunked confirmation, and permits empty previews" $ \store -> do
        app <- opsApplication defaultOpsHttpConfig {mutations = MutationsEnabled} hooks store
        let post headers payload chunked =
              let req = (setPath defaultRequest "/stream/soft-delete/order-1") {requestMethod = methodPost, requestHeaders = headers}
                  wrapped request respond = app (if chunked then request {requestBodyLength = ChunkedBody} else request) respond
               in runSession (srequest (SRequest req payload)) wrapped
        forM_ [False, True] $ \chunked -> do
          forM_ [[], [(hContentType, "text/plain")]] $ \headers ->
            post headers "{\"confirm\":\"execute\"}" chunked >>= \response -> assertError response status415 "unsupported_media_type"
          preview <- post [] "" chunked
          simpleStatus preview `shouldBe` status200
        forM_ [[("Origin", "http://example.test:80"), (hHost, "EXAMPLE.test")], [("Origin", "https://console.example")], []] $ \origins -> do
          allowed <- opsApplication defaultOpsHttpConfig {mutations = MutationsEnabled, Config.allowedOrigins = ["https://console.example"]} hooks store
          response <- runSession (srequest (SRequest ((setPath defaultRequest "/outbox/maintenance-pass") {requestMethod = methodPost, requestHeaders = (hContentType, "Application/JSON; charset=utf-8") : origins}) "{\"confirm\":\"execute\"}")) allowed
          simpleStatus response `shouldBe` status200
      it "applies exact-origin CORS without credentials or duplicate headers" $ \store -> do
        app <- opsApplication defaultOpsHttpConfig {Config.allowedOrigins = ["http://ui.example"]} Ops.emptyAppHooks store
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
      it "holds admission during response delivery and releases it when the client cancels" $ \store -> do
        entered <- newEmptyMVar
        gate <- newEmptyMVar
        count <- newIORef (0 :: Int)
        let config = defaultOpsHttpConfig {inspectionLimits = defaultInspectionLimits {maxConcurrentReads = 1}}
            operations = OpsHttpOperations (modifyIORef' count (+ 1) >> pure (Right [])) (\_ _ -> pure (Succeeded emptyResult))
        budget <- newInspectionBudget config.inspectionLimits
        app <- opsApplicationWithOperations config budget Ops.emptyAppHooks store operations
        let slow request respond = app request (\response -> putMVar entered () >> takeMVar gate >> respond response)
        withAsync (call slow methodGet "/health" "") $ \job -> do
          takeMVar entered
          refused <- call app methodGet "/health" ""
          assertError refused status503 "inspection_busy"
          readIORef count `shouldReturn` 1
          cancel job
        recovered <- call app methodGet "/health" ""
        simpleStatus recovered `shouldBe` status200
      it "expires four blocked deliveries once, returns all permits, and recovers health" $ \store -> do
        entered <- newChan
        blocked <- newEmptyMVar
        responses <- newIORef (0 :: Int)
        cancelled <- newIORef (0 :: Int)
        let config = defaultOpsHttpConfig {inspectionLimits = defaultInspectionLimits {maxConcurrentReads = 4, deliveryDeadlineSeconds = 1}}
        budget <- newInspectionBudget config.inspectionLimits
        app <- opsApplicationWithOperations config budget Ops.emptyAppHooks store (OpsHttpOperations (pure (Right [])) (\_ _ -> pure (Succeeded emptyResult)))
        let slow request respond =
              app
                request
                ( \response -> do
                    atomicModifyIORef' responses (\n -> (n + 1, ()))
                    writeChan entered ()
                    (takeMVar blocked >> respond response) `finally` atomicModifyIORef' cancelled (\n -> (n + 1, ()))
                )
        jobs <- replicateM 4 (async (try (call slow methodGet "/health" "") :: IO (Either SomeException SResponse)))
        timeout 1000000 (replicateM 4 (readChan entered)) `shouldReturn` Just [(), (), (), ()]
        refused <- call app methodGet "/health" ""
        assertError refused status503 "inspection_busy"
        finished <- timeout 3000000 (mapM wait jobs)
        case finished of
          Just outcomes -> forM_ outcomes $ \outcome -> outcome `shouldSatisfy` either (const True) (const False)
          Nothing -> mapM_ cancel jobs >> expectationFailure "delivery did not terminate"
        readIORef responses `shouldReturn` 4
        readIORef cancelled `shouldReturn` 4
        call app methodGet "/health" "" >>= \response -> simpleStatus response `shouldBe` status200
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
        _ <- call app methodGet "/wf/inspect/list?after=not-a-cursor" ""
        _ <- call app methodGet "/wf/inspect/list?limit=501" ""
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
      it "refuses foreign origins and non-JSON confirmation over a real HTTP socket" $ \store -> do
        app <- opsApplication defaultOpsHttpConfig {mutations = MutationsEnabled} hooks store
        manager <- Client.newManager Client.defaultManagerSettings
        withOpsHttpServer defaultOpsHttpServerConfig {port = 0} app $ \server -> do
          base <- Client.parseRequest ("http://127.0.0.1:" <> show server.serverPort <> "/outbox/maintenance-pass")
          forM_ [([("Origin", "https://evil.example"), (hContentType, "application/json")], status403), ([(hContentType, "text/plain")], status415)] $ \(headers, status) -> do
            let request = base {Client.method = methodPost, Client.requestHeaders = headers, Client.requestBody = Client.RequestBodyLBS "{\"confirm\":\"execute\"}"}
            response <- Client.httpLbs request manager
            Client.responseStatus response `shouldBe` status
      it "terminates a backpressured Warp delivery and recovers admission" $ \store -> do
        entered <- newEmptyMVar
        delivered <- newEmptyMVar
        let bodyBytes = 32 * 1024 * 1024
            config = defaultOpsHttpConfig {inspectionLimits = defaultInspectionLimits {maxConcurrentReads = 1, deliveryDeadlineSeconds = 1, maxResponseBytes = 64 * 1024 * 1024}}
            large = emptyResult {jsonValue = String (Text.replicate bodyBytes "x")}
        budget <- newInspectionBudget config.inspectionLimits
        app <- opsApplicationWithOperations config budget Ops.emptyAppHooks store (OpsHttpOperations (pure (Right [])) (\_ _ -> pure (Succeeded large)))
        let watched request respond =
              app
                request
                ( \response -> do
                    putMVar entered ()
                    respond response `finally` putMVar delivered ()
                )
        withOpsHttpServer defaultOpsHttpServerConfig {port = 0} watched $ \server ->
          bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \client -> do
            Socket.setSocketOption client Socket.RecvBuffer 4096
            Socket.connect client (Socket.SockAddrInet (fromIntegral server.serverPort) (Socket.tupleToHostAddress (127, 0, 0, 1)))
            Socket.sendAll client "GET /wf/list HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
            timeout 5000000 (takeMVar entered) `shouldReturn` Just ()
            tryTakeMVar delivered `shouldReturn` Nothing
            -- The 32-MiB response exceeds socket buffers; no response bytes
            -- have been read. The callback is still inside actual Warp delivery.
            refused <- call app methodGet "/health" ""
            assertError refused status503 "inspection_busy"
            timeout 3000000 (takeMVar delivered) `shouldReturn` Just ()
            recovered <- call app methodGet "/health" ""
            simpleStatus recovered `shouldBe` status200
            Socket.setSocketOption client Socket.RecvBuffer (1024 * 1024)
            let drain total = do
                  chunk <- Socket.recv client 65536
                  if Char8.null chunk then pure total else drain (total + Char8.length chunk)
            terminated <- timeout 5000000 (try (drain 0) :: IO (Either IOException Int))
            case terminated of
              Just (Right count) -> count `shouldSatisfy` (< bodyBytes)
              Just (Left _) -> pure ()
              Nothing -> expectationFailure "expired Warp connection remained open"
      it "joins idle accepted connections across repeated start/stop churn" $ \store -> do
        app <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks store
        forM_ [1 .. (20 :: Int)] $ \_ ->
          withOpsHttpServer defaultOpsHttpServerConfig {port = 0} app $ \server ->
            bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \client -> do
              Socket.connect client (Socket.SockAddrInet (fromIntegral server.serverPort) (Socket.tupleToHostAddress (127, 0, 0, 1)))
              stopOpsHttpServer server
              result <- timeout 1000000 (try (Socket.recv client 1))
              case result of
                Just (Left (_ :: IOException)) -> pure ()
                Just (Right bytes) | Char8.null bytes -> pure ()
                _ -> expectationFailure "stopped runner retained an idle connection"
  around (withFreshDatabase fixture) $ do
    describe "process-manager discovery database boundary" $ do
      it "performs only aggregate-types verifier work and rejects parsing before borrowing" $ \url ->
        withStore (defaultConnectionSettings url) $ \store -> do
          calls <- newIORef (0 :: Int)
          let observe = \case Observation.ConnectionObservation _ Observation.InUseConnectionStatus -> atomicModifyIORef' calls (\n -> (n + 1, ())); _ -> pure ()
              settings = (defaultConnectionSettings url) {observationHandler = Just observe}
              mounted = Ops.emptyAppHooks {Ops.processManagers = Just jitsureiProcessManagerInspectors, Ops.aggregates = Just Map.empty}
          withOpsInspectionPool defaultInspectionLimits settings $ \pool -> do
            app <- opsApplication defaultOpsHttpConfig mounted store {pool}
            before <- readIORef calls
            invalid <- call app methodGet "/pm/types?name=invalid" ""
            assertError invalid status400 "invalid_request"
            readIORef calls `shouldReturn` before
            aggregate <- call app methodGet "/aggregate/types" ""
            simpleStatus aggregate `shouldBe` status200
            afterAggregate <- readIORef calls
            manager <- call app methodGet "/pm/types" ""
            simpleStatus manager `shouldBe` status200
            afterManager <- readIORef calls
            afterAggregate `shouldSatisfy` (> before)
            afterManager - afterAggregate `shouldBe` afterAggregate - before
    describe "bounded workflow header" $ do
      it "uses one supported instance read even with 100000 children" $ \url ->
        withStore (defaultConnectionSettings url) $ \store -> do
          seedInspection store
          executeSql url "INSERT INTO keiro.keiro_workflow_children(child_id,child_name,parent_id,parent_name,await_step) SELECT 'child-'||n,'child','wf-1','approval','await-'||n FROM generate_series(1,100000) n"
          calls <- newIORef (0 :: Int)
          let observe = \case Observation.ConnectionObservation _ Observation.InUseConnectionStatus -> atomicModifyIORef' calls (\n -> (n + 1, ())); _ -> pure ()
              settings = (defaultConnectionSettings url) {observationHandler = Just observe}
          withOpsInspectionPool defaultInspectionLimits settings $ \pool -> do
            app <- opsApplication defaultOpsHttpConfig hooks store {pool}
            response <- call app methodGet "/wf/inspect/header/approval/wf-1" ""
            simpleStatus response `shouldBe` status200
            field "workflow_id" (body response) `shouldBe` Just (String "wf-1")
            field "children" (body response) `shouldBe` Nothing
            -- One schema-verification session and one instance-read session.
            readIORef calls `shouldReturn` 2
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
            -- These are two observations at different times. Compare stable
            -- fields while retaining the timestamp/age shape checks in ops.
            fmap stableObservation (Aeson.eitherDecode (simpleBody response)) `shouldBe` (fmap stableObservation (Aeson.eitherDecode (LazyByteString.fromStrict (Char8.pack out))) :: Either String Value)
            err `shouldBe` ""

stableObservation :: Value -> Value
stableObservation (Object fields) = Object (KeyMap.map stableObservation (foldr KeyMap.delete fields ["observed_at", "lease_age_seconds", "due_in_seconds"]))
stableObservation (Array items) = Array (fmap stableObservation items)
stableObservation value = value

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
    ("/timer/pending/list?limit=1", ["timer", "pending", "list", "--limit", "1"]),
    ("/shard/list", ["shard", "list"]),
    ("/timer/stuck/list?min_age=0s", ["timer", "stuck", "list", "--min-age", "0s"]),
    ("/outbox/backlog", ["outbox", "backlog"]),
    ("/inbox/backlog", ["inbox", "backlog"]),
    ("/projection/position?subscription=http_test", ["projection", "position", "--subscription", "http_test"]),
    ("/projection/status?limit=1", ["projection", "status", "--limit", "1"]),
    ("/shard/status?subscription=http_test", ["shard", "status", "--subscription", "http_test"]),
    ("/snapshot/show?stream=missing", ["snapshot", "show", "--stream", "missing"]),
    ("/stream/show/order-1", ["stream", "show", "order-1"]),
    ("/stream/subscriptions", ["stream", "subscriptions"])
  ]

call :: Application -> Method -> Text -> LazyByteString.ByteString -> IO SResponse
call app method path payload = runSession (srequest (SRequest ((setPath defaultRequest (Text.encodeUtf8 path)) {requestMethod = method, requestHeaders = [(hContentType, "application/json")]}) payload)) app

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
