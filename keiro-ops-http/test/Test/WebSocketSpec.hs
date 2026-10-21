module Test.WebSocketSpec (spec) where

import Control.Monad (forM_, void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.Ops (emptyAppHooks)
import Keiro.Ops.Http hiding (subscribe)
import Keiro.Ops.Projection (projectionGroupStatusJson)
import Keiro.ReadModel (registerReadModel)
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Keiro.Timer qualified as Timer
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry)
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
import Network.Wai (Application, defaultRequest)
import Network.Wai.Test qualified as Wai
import Network.WebSockets qualified as WS
import System.Timeout (timeout)
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = describe "inspection sockets" $ around (withFreshStore fixture) $ do
  it "shares workflow truth, retains a subscription on refusal, and releases each sent frame" $ \store -> do
    now <- getCurrentTime
    void (stored store (appendJournalEntry (WorkflowName "approval") (WorkflowId "one") (StepRecorded "start" Null now)))
    serve store defaultOpsHttpConfig socketConfig {maxViews = 1} $ \handle app port ->
      within $ WS.runClient "127.0.0.1" port "/ws?client=one" $ \one ->
        WS.runClient "127.0.0.1" port "/ws" $ \two -> do
          forM_ [one, two] $ \connection -> send connection (subscribe "workflows") >> receive connection >>= assertType "snapshot"
          feedStats handle `shouldReturn` FeedStats 1 2 True
          -- With two queue slots, five sequential sends detect unreleased
          -- in-flight frames or a writer recursing inside its bracket.
          forM_ [1 .. 5 :: Int] $ \_ -> send one (object ["type" .= ("ping" :: Text)]) >> receive one >>= assertType "pong"
          send one (object ["type" .= ("subscribe" :: Text), "feed" .= ("workflows" :: Text), "workflow_name" .= ("other" :: Text)])
          refused <- receive one
          field "code" refused `shouldBe` Just (String "too_many_views")
          forM_
            [ (object ["type" .= ("subscribe" :: Text), "feed" .= ("unknown" :: Text)], "unknown_feed"),
              (object ["type" .= ("subscribe" :: Text), "feed" .= ("timers" :: Text), "bad_filter" .= True], "invalid_subscription")
            ]
            $ \(frame, code) -> do
              send one frame
              response <- receive one
              field "code" response `shouldBe` Just (String code)
          WS.sendTextData one ("{broken" :: Text)
          malformed <- receive one
          field "code" malformed `shouldBe` Just (String "invalid_frame")

          void (stored store (appendJournalEntry (WorkflowName "approval") (WorkflowId "one") (WorkflowCompleted now)))
          update <- receive one
          receive two `shouldReturn` update
          assertType "update" update
          field "trigger" update `shouldBe` Just (String "notify")
          field "sequence" update `shouldBe` Just (Aeson.toJSON (1 :: Int))
          response <- Wai.runSession (Wai.srequest (Wai.SRequest (Wai.setPath defaultRequest "/wf/inspect/list") "")) app
          field "items" (decode (Wai.simpleBody response)) `shouldBe` field "changed" update
          forM_ [one, two] $ \connection -> do
            send connection (object ["type" .= ("unsubscribe" :: Text), "feed" .= ("workflows" :: Text)])
            receive connection >>= assertType "unsubscribed"
          feedStats handle `shouldReturn` FeedStats 0 2 False
  it "streams timer fallback truth and projection extra-only changes using the poll encoders" $ \store ->
    serve store defaultOpsHttpConfig socketConfig $ \_ _ port -> within $
      WS.runClient "127.0.0.1" port "/ws" $ \connection -> do
        forM_ ["timers", "projection_groups"] $ \feed -> send connection (subscribe feed) >> receive connection >>= assertType "snapshot"
        now <- getCurrentTime
        let timer = Timer.TimerRequest (Timer.TimerId UUID.nil) "manager" "one" (addUTCTime (-60) now) Null
        stored store (runTransaction (Timer.scheduleTimerTx timer))
        added <- receive connection
        field "feed" added `shouldBe` Just (String "timers")
        field "trigger" added `shouldBe` Just (String "timeout")
        Just observed <- pure (field "observed_at" added)
        Aeson.Success stamp <- pure (Aeson.fromJSON observed :: Aeson.Result UTCTime)
        Just inspection <- stored store (Timer.lookupTimerInspection timer.timerId)
        field "changed" added `shouldBe` Just (Aeson.toJSON [Timer.pendingTimerItemJson stamp inspection])
        Just _ <- stored store (Timer.claimDueTimer now)
        stored store (Timer.markTimerFired timer.timerId (EventId UUID.nil)) `shouldReturn` True
        removed <- receive connection
        field "removed" removed `shouldBe` Just (Aeson.toJSON [object ["timer_id" .= UUID.toText UUID.nil]])
        _ <- stored store (registerReadModel "socket-model" 1 "shape")
        projection <- receive connection
        field "feed" projection `shouldBe` Just (String "projection_groups")
        Right page <- stored store (listProjectionGroupStatusesPage (ProjectionStatusPageRequest 100 Nothing))
        field "changed" projection `shouldBe` Just (Aeson.toJSON (map projectionGroupStatusJson page.items))
        void (stored store (appendJournalEntry (WorkflowName "head") (WorkflowId "one") (StepRecorded "head" Null now)))
        headOnly <- receive connection
        field "feed" headOnly `shouldBe` Just (String "projection_groups")
        field "changed" headOnly `shouldBe` Just (Aeson.toJSON ([] :: [Value]))
        field "removed" headOnly `shouldBe` Just (Aeson.toJSON ([] :: [Value]))
        field "visible_store_head" headOnly `shouldSatisfy` (\case Just (Number position) -> position > 0; _ -> False)
  it "checks upgrade origin, capacity and schema policy and closes active sockets" $ \store -> do
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    serve store defaultOpsHttpConfig socketConfig {maxConnections = 1} $ \handle _ port -> do
      forbidden <- upgrade manager port [(hOrigin, "http://evil.test")]
      HTTP.responseStatus forbidden `shouldBe` status403
      let origin = "http://127.0.0.1:" <> show port
      within $ WS.runClientWith "127.0.0.1" port "/ws" WS.defaultConnectionOptions [("Origin", fromStringBytes origin)] $ \connection -> do
        full <- upgrade manager port []
        HTTP.responseStatus full `shouldBe` status503
        closeFeedHandle handle
        receive connection >>= assertType "goodbye"
      feedStats handle `shouldReturn` FeedStats 0 0 False
    result <- Pool.use store.pool (Session.script "ALTER TABLE keiro.keiro_timers ADD COLUMN socket_test_drift text")
    either (fail . show) pure result
    serve store defaultOpsHttpConfig socketConfig $ \_ _ port -> do
      refused <- upgrade manager port []
      HTTP.responseStatus refused `shouldBe` status409
    let allow = defaultOpsHttpConfig {schemaDrift = AllowDrift}
    serve store allow socketConfig $ \_ _ port -> within $ WS.runClient "127.0.0.1" port "/ws" $ \connection -> do
      send connection (subscribe "timers")
      receive connection >>= assertType "snapshot"

socketConfig :: FeedConfig
socketConfig = defaultFeedConfig {fallbackInterval = 5, minRefreshInterval = 0.01, readTimeout = 2, queueCapacity = 2}

serve :: KirokuStore -> OpsHttpConfig -> FeedConfig -> (FeedHandle -> Application -> Int -> IO a) -> IO a
serve store config feeds action = withFeedHandle config feeds store $ \handle -> do
  app <- opsApplicationWithFeeds config handle emptyAppHooks store
  withOpsHttpServer defaultOpsHttpServerConfig {port = 0} app (\server -> action handle app server.serverPort)

subscribe :: Text -> Value
subscribe feed = object ["type" .= ("subscribe" :: Text), "feed" .= feed]

send :: WS.Connection -> Value -> IO ()
send connection = WS.sendTextData connection . Aeson.encode

receive :: WS.Connection -> IO Value
receive connection = timeout 7000000 (WS.receiveData connection :: IO Lazy.ByteString) >>= maybe (fail "socket frame deadline exceeded") (pure . decode)

decode :: Lazy.ByteString -> Value
decode = either error id . Aeson.eitherDecode

field :: Aeson.Key -> Value -> Maybe Value
field key = \case Object fields -> KeyMap.lookup key fields; _ -> Nothing

assertType :: Text -> Value -> IO ()
assertType expected value = field "type" value `shouldBe` Just (String expected)

stored :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO a
stored store action = runStoreIO store action >>= either (fail . show) pure

within :: IO a -> IO a
within action = timeout 25000000 action >>= maybe (fail "socket client deadline exceeded") pure

upgrade :: HTTP.Manager -> Int -> RequestHeaders -> IO (HTTP.Response Lazy.ByteString)
upgrade manager port headers = do
  request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/ws")
  HTTP.httpLbs request {HTTP.requestHeaders = headers <> [(hConnection, "Upgrade"), (hUpgrade, "websocket"), ("Sec-WebSocket-Version", "13"), ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")]} manager

fromStringBytes :: String -> Bytes.ByteString
fromStringBytes = Char8.pack
