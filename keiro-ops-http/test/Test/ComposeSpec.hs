module Test.ComposeSpec (spec) where

import Control.Monad (forM_, void)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Ops (emptyAppHooks)
import Keiro.Ops.Http
import Keiro.Ops.Http.Application (opsApplicationWithBudget)
import Keiro.Ops.Http.Config qualified as Config
import Keiro.Ops.Http.WebSocket (feedsMiddleware)
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry)
import Kiroku.Metrics qualified as Metrics
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Test qualified as Wai
import Network.WebSockets qualified as WS
import System.Timeout (timeout)
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = describe "Compose" $ do
  it "strips exactly one raw segment and preserves route spelling, queries and streaming bodies" $ do
    let app = composed defaultComposeConfig [MountedSurface keiroPrefix echo]
    forM_
      [ ("/keiro", "/"),
        ("/keiro/", "/"),
        ("/k%65iro/ws?from=3", "/ws"),
        ("/keiro/a%2Fb/%25/%E6%97%A5/", "/a%2Fb/%25/%E6%97%A5/"),
        ("/keiro/x//y/", "/x//y/")
      ]
      $ \(path, relative) -> do
        let req = Wai.setPath defaultRequest path
        Just stripped <- pure (stripSurfacePrefix keiroPrefix req)
        rawPathInfo stripped `shouldBe` relative
        rawQueryString stripped `shouldBe` rawQueryString req
        queryString stripped `shouldBe` queryString req
        response <- get app req
        Wai.simpleStatus response `shouldBe` status200
        Wai.simpleBody response `shouldBe` Lazy.fromStrict relative
    stripSurfacePrefix keiroPrefix ((Wai.setPath defaultRequest "/keiro/one") {rawPathInfo = "/keiro/two"}) `shouldSatisfy` maybe True (const False)
  it "validates mounts, lists them in order, refuses absent surfaces and applies CORS once" $ do
    forM_ ["", "-x", "UPPER", "x/y"] $ \prefix -> mkSurfacePrefix prefix `shouldBe` Left (InvalidPrefix prefix)
    case composeSurfaces defaultComposeConfig [] of Left NoSurfaces -> pure (); _ -> expectationFailure "empty mount accepted"
    case composeSurfaces defaultComposeConfig [MountedSurface keiroPrefix echo, MountedSurface keiroPrefix echo] of
      Left (DuplicatePrefix "keiro") -> pure ()
      _ -> expectationFailure "duplicate mount accepted"
    let app = composed (ComposeConfig ["http://ui.test"]) [MountedSurface keiroPrefix echo, MountedSurface kirokuPrefix existingCors]
    index <- get app (Wai.setPath defaultRequest "/")
    decode (Wai.simpleBody index) `shouldBe` object ["surfaces" .= [object ["prefix" .= ("keiro" :: Text), "path" .= ("/keiro" :: Text)], object ["prefix" .= ("kiroku" :: Text), "path" .= ("/kiroku" :: Text)]]]
    refused <- get app (Wai.setPath defaultRequest "/pgmq/queues")
    Wai.simpleStatus refused `shouldBe` status404
    method <- get app ((Wai.setPath defaultRequest "/") {requestMethod = methodPost})
    lookup hAllow (Wai.simpleHeaders method) `shouldBe` Just "GET"
    forM_ [("/keiro/x", "http://ui.test"), ("/kiroku/x", "http://already.test")] $ \(path, origin) -> do
      response <- get app ((Wai.setPath defaultRequest path) {requestHeaders = [(hOrigin, "http://ui.test")]})
      filter ((== "Access-Control-Allow-Origin") . fst) (Wai.simpleHeaders response) `shouldBe` [("Access-Control-Allow-Origin", origin)]
      lookup "Access-Control-Allow-Credentials" (Wai.simpleHeaders response) `shouldBe` Nothing
    let preflight = (Wai.setPath defaultRequest "/keiro/x") {requestMethod = methodOptions, requestHeaders = [(hOrigin, "http://ui.test"), ("Access-Control-Request-Method", "GET"), ("Access-Control-Request-Headers", "X-Request-Id")]}
    response <- get app preflight
    Wai.simpleStatus response `shouldBe` status204
    lookup "Access-Control-Allow-Headers" (Wai.simpleHeaders response) `shouldBe` Just "X-Request-Id"
    forM_ [composed defaultComposeConfig [MountedSurface keiroPrefix echo], app] $ \candidate -> do
      denied <- get candidate ((Wai.setPath defaultRequest "/keiro/x") {requestHeaders = [(hOrigin, "http://other.test")]})
      lookup "Access-Control-Allow-Origin" (Wai.simpleHeaders denied) `shouldBe` Nothing
  around (withFreshStore fixture) $ it "mounts real Keiro and Kiroku applications and both socket protocols on one port" $ \store -> do
    now <- getCurrentTime
    void (stored store (appendJournalEntry (WorkflowName "compose") (WorkflowId "one") (StepRecorded "start" Null now)))
    let config = defaultOpsHttpConfig {Config.allowedOrigins = ["http://ui.test"]}
        metricsConfig = Metrics.defaultConfig {Metrics.wsPushIntervalUs = 30000000}
    metrics <- Metrics.newKirokuMetrics store
    providers <- Metrics.storeServerProviders metricsConfig metrics store
    let kiroku = Metrics.combinedAppWithProviders metricsConfig metrics [] providers
    withFeedHandle config defaultFeedConfig store $ \handle -> do
      http <- opsApplicationWithBudget config {Config.allowedOrigins = []} (handleBudget handle) emptyAppHooks store
      let keiro = feedsMiddleware config handle http
          app = composed (ComposeConfig config.allowedOrigins) [MountedSurface keiroPrefix keiro, MountedSurface kirokuPrefix kiroku]
      forM_ [(keiro, "/health", "/keiro/health"), (kiroku, "/capabilities", "/kiroku/capabilities")] $ \(standalone, relative, mounted) -> do
        plain <- get standalone (Wai.setPath defaultRequest relative)
        through <- get app ((Wai.setPath defaultRequest mounted) {requestHeaders = [(hOrigin, "http://ui.test")]})
        Wai.simpleStatus through `shouldBe` Wai.simpleStatus plain
        Wai.simpleBody through `shouldBe` Wai.simpleBody plain
        filter ((== "Access-Control-Allow-Origin") . fst) (Wai.simpleHeaders through) `shouldBe` [("Access-Control-Allow-Origin", "http://ui.test")]
      withOpsHttpServer defaultOpsHttpServerConfig {port = 0} app $ \server -> within $ do
        WS.runClient "127.0.0.1" server.serverPort "/kiroku/ws/metrics" $ \connection -> do
          receive connection >>= hasType "snapshot"
          WS.sendTextData connection (encode (object ["type" .= ("ping" :: Text)]))
          receive connection >>= hasType "pong"
        WS.runClient "127.0.0.1" server.serverPort "/keiro/ws?from=3" $ \connection -> do
          WS.sendTextData connection (encode (object ["type" .= ("subscribe" :: Text), "feed" .= ("workflows" :: Text)]))
          receive connection >>= hasType "snapshot"
          void (stored store (appendJournalEntry (WorkflowName "compose") (WorkflowId "one") (WorkflowCompleted now)))
          receive connection >>= hasType "update"
          closeFeedHandle handle
          receive connection >>= hasType "goodbye"
      feedStats handle `shouldReturn` FeedStats 0 0 False

composed :: ComposeConfig -> [MountedSurface] -> Application
composed config = either (error . show) id . composeSurfaces config

echo :: Application
echo req respond = respond (responseStream status200 [] (\write flush -> write (Builder.byteString (rawPathInfo req)) >> flush))

existingCors :: Application
existingCors req respond = echo req (respond . mapResponseHeaders (("Access-Control-Allow-Origin", "http://already.test") :))

get :: Application -> Request -> IO Wai.SResponse
get app req = Wai.runSession (Wai.srequest (Wai.SRequest req "")) app

decode :: Lazy.ByteString -> Value
decode = either error id . Aeson.eitherDecode

receive :: WS.Connection -> IO Value
receive connection = decode <$> (WS.receiveData connection :: IO Lazy.ByteString)

hasType :: Text -> Value -> Expectation
hasType kind = \case Object fields -> KeyMap.lookup "type" fields `shouldBe` Just (String kind); value -> expectationFailure (show value)

within :: IO a -> IO a
within action = timeout 15000000 action >>= maybe (fail "composed socket deadline") pure

stored :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO a
stored store action = runStoreIO store action >>= either (fail . show) pure
