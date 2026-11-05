module Main (main) where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Jitsurei
import Keiro.Command (RunCommandOptions (..), defaultRunCommandOptions)
import Keiro.Command qualified as Command
import Keiro.Connection (withProjectionSchema)
import Keiro.Ops qualified as Ops
import Keiro.Ops.Aggregate qualified as Aggregate
import Keiro.Ops.Env qualified as Env
import Keiro.Ops.Http
import Keiro.Ops.ProcessManager qualified as PM
import Keiro.Ops.Projection qualified as Projection
import Keiro.Ops.Render qualified as Render
import Keiro.Ops.Snapshot qualified as Snapshot
import Keiro.Test.Postgres
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (StreamName (..), StreamVersion (..))
import Network.HTTP.Client qualified as Client
import Network.HTTP.Types
import Pgmq.Migration qualified as Pgmq
import Test.Hspec

main :: IO ()
main = do
  pgmq <- either (fail . show) pure Pgmq.pgmqMigrations
  withMigratedSuiteWith [pgmq] $ \fixture -> hspec $
    describe "Jitsurei ops HTTP host" $
      around (\action -> withFreshResourceStoreWithConnection fixture (withProjectionSchema jitsureiProjectionSchema) (\url resource -> action (url, resource))) $ do
        it "serves the mounted catalogs and seeded aggregate and manager handler JSON" $ \(url, (store, runner)) -> do
          seed runner
          let hooks = jitsureiOpsHooks Nothing
              env = Env.OpsEnv store Env.Json False [] False
          withHost (options url defaultOpsHttpConfig) hooks $ \host -> do
            manager <- Client.newManager Client.defaultManagerSettings
            let get path = requestJson manager host methodGet path [] status200
            health <- get "/health"
            field "status" health `shouldBe` Aeson.String "ok"
            field "schema_drift" health `shouldBe` Aeson.toJSON ([] :: [Text])
            field "mutations_enabled" health `shouldBe` Aeson.Bool False
            types <- get "/aggregate/types"
            map (field "name") (items types) `shouldBe` map Aeson.String ["credit-limit", "incident", "order"]
            managerTypes <- get "/pm/types"
            map (field "name") (items managerTypes) `shouldBe` [Aeson.String "jitsurei-fulfillment"]
            actualOrder <- get "/aggregate/show?name=order&id=order-100"
            Render.Succeeded order <- Ops.runCommand hooks env (Ops.Aggregate (Aggregate.Show (Aggregate.ShowOptions "order" "order-100")))
            forM_ ["name", "aggregate_id", "stream_name", "stream_version", "state_label", "state"] $ \key ->
              field key actualOrder `shouldBe` field key (Render.jsonValue order)
            listed <- get "/pm/list?name=jitsurei-fulfillment"
            map (field "correlation_id") (items listed) `shouldBe` [Aeson.String "order-100"]
            actualPM <- get "/pm/show?name=jitsurei-fulfillment&correlation=order-100"
            Render.Succeeded shown <- Ops.runCommand hooks env (Ops.ProcessManager (PM.Show (PM.ShowOptions "jitsurei-fulfillment" "order-100" 20)))
            forM_ ["state", "last_reaction", "waiting_for"] $ \key ->
              field key actualPM `shouldBe` field key (Render.jsonValue shown)
            field "items" (field "pending_timers" actualPM) `shouldBe` Aeson.toJSON ([] :: [Aeson.Value])

        it "serves category consumers from the shared hooks on the listening host" $ \(url, (store, _)) -> do
          let hooks = jitsureiOpsHooks Nothing
              env = Env.OpsEnv store Env.Json False [] False
          withHost (options url defaultOpsHttpConfig) hooks $ \host -> do
            manager <- Client.newManager Client.defaultManagerSettings
            forM_ ["order", "creditLimit"] $ \category -> do
              actual <- requestJson manager host methodGet ("/projection/consumers?category=" <> category) [] status200
              Render.Succeeded expected <- Ops.runCommand hooks env (Ops.Projection (Projection.Consumers (Projection.ConsumersOptions (TextEncoding.decodeUtf8 (Char8.pack category)) 100 Nothing)))
              actual `shouldBe` expected.jsonValue

        it "serves current registers, snapshot health and raw stored values from the listening host" $ \(url, (store, StoreRunner runner)) -> do
          Right (Right _) <- runner (Command.runCommand defaultRunCommandOptions creditLimitEventStream (creditLimitStream "registers-100") (AdjustCredit (AdjustCreditData 25)))
          let hooks = jitsureiOpsHooks Nothing
              env = Env.OpsEnv store Env.Json False [] False
              expected = Aeson.object ["state" Aeson..= ("credit_reviewed" :: Text), "registers" Aeson..= Aeson.object ["balance" Aeson..= (25 :: Int), "active" Aeson..= False]]
          withHost (options url defaultOpsHttpConfig) hooks $ \host -> do
            manager <- Client.newManager Client.defaultManagerSettings
            current <- requestJson manager host methodGet "/aggregate/show?name=credit-limit&id=registers-100" [] status200
            field "state" current `shouldBe` expected
            field "state_version" current `shouldBe` Aeson.toJSON (1 :: Int)
            field "stream_version" current `shouldBe` Aeson.toJSON (1 :: Int)
            field "state_label" current `shouldBe` Aeson.String "credit_reviewed"
            Aeson.String streamName <- pure (field "stream_name" current)
            stored <- requestJson manager host methodGet ("/snapshot/show?" <> showQuery [("stream", streamName)]) [] status200
            health <- requestJson manager host methodGet "/aggregate/snapshot?name=credit-limit&id=registers-100" [] status200
            field "state" stored `shouldBe` expected
            field "stream_version" stored `shouldBe` Aeson.toJSON (1 :: Int)
            Render.Succeeded cliCurrent <- Ops.runCommand hooks env (Ops.Aggregate (Aggregate.Show (Aggregate.ShowOptions "credit-limit" "registers-100")))
            Render.Succeeded cliStored <- Ops.runCommand hooks env (Ops.Snapshot (Snapshot.Show streamName))
            Render.Succeeded cliHealth <- Ops.runCommand hooks env (Ops.Aggregate (Aggregate.Snapshot (Aggregate.ShowOptions "credit-limit" "registers-100")))
            forM_ ["state", "stream_version", "state_version", "stream_name", "state_label"] $ \key ->
              field key current `shouldBe` field key (Render.jsonValue cliCurrent)
            forM_ ["state", "stream_version", "state_codec_version", "regfile_shape_hash", "state_shape_hash", "created_at", "updated_at", "state_bytes"] $ \key ->
              field key stored `shouldBe` field key (Render.jsonValue cliStored)
            stableHealth health `shouldBe` stableHealth (Render.jsonValue cliHealth)
            field "compatibility" (field "stored" health) `shouldBe` Aeson.String "compatible"
            field "status" health `shouldBe` Aeson.String "present"
            field "stream_version" health `shouldBe` Aeson.toJSON (1 :: Int)
            field "stream_version" (field "stored" health) `shouldBe` Aeson.toJSON (1 :: Int)

        it "refuses mutations by default" $ \(url, (_, runner)) -> do
          seed runner
          withHost (options url defaultOpsHttpConfig) (jitsureiOpsHooks Nothing) $ \host -> do
            manager <- Client.newManager Client.defaultManagerSettings
            refused <- requestJson manager host methodPost "/stream/soft-delete/order-order-100" [] status403
            field "code" (field "error" refused) `shouldBe` Aeson.String "mutations_disabled"

        it "rejects foreign origins and previews allowed mutations without deleting the stream" $ \(url, (_, runner)) -> do
          seed runner
          let config = defaultOpsHttpConfig {mutations = MutationsEnabled, allowedOrigins = ["http://ui.example"]}
          withHost (options url config) (jitsureiOpsHooks Nothing) $ \host -> do
            manager <- Client.newManager Client.defaultManagerSettings
            let stream = field "stream" <$> requestJson manager host methodGet "/stream/show/order-order-100" [] status200
            originalStream <- stream
            field "exists" originalStream `shouldBe` Aeson.Bool True
            field "deleted_at" originalStream `shouldBe` Aeson.Null
            refused <- requestJson manager host methodPost "/stream/soft-delete/order-order-100" [("Origin", "http://evil.example")] status403
            field "code" (field "error" refused) `shouldBe` Aeson.String "origin_not_allowed"
            stream `shouldReturn` originalStream
            preview <- requestJson manager host methodPost "/stream/soft-delete/order-order-100" [("Origin", "http://ui.example")] status200
            field "outcome" preview `shouldBe` Aeson.String "preview"
            stream `shouldReturn` originalStream

options :: Text -> OpsHttpConfig -> HostOptions
options url config = HostOptions {databaseUrl = Just url, http = config, server = defaultOpsHttpServerConfig {port = 0}}

seed :: StoreRunner -> IO ()
seed (StoreRunner runner) = do
  let orderId = OrderId "order-100"
      paymentRef = PaymentRef "pay_123"
      placeOrder = PlaceOrder PlaceOrderData {orderId, sku = Sku "SKU-RED-MUG", quantity = Quantity 3}
      approvePayment = ApprovePayment ApprovePaymentData {orderId, paymentRef}
  Right () <- runner initializeJitsureiTables
  Right (Right _) <- runner (Command.runCommand defaultRunCommandOptions orderEventStream (orderStream orderId) placeOrder)
  Right (Right _) <- runner (Command.runCommand defaultRunCommandOptions orderEventStream (orderStream orderId) approvePayment)
  Right recorded <- runner (Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10)
  Right (Right _) <- runner (runFulfillmentOnce defaultRunCommandOptions {inspectionProvenance = Command.CaptureInspectionProvenance} (Vector.toList recorded !! 1) (PaymentApproved PaymentApprovedData {orderId = orderId, paymentRef = paymentRef}))
  pure ()

requestJson :: Client.Manager -> OpsHttpServer -> Method -> String -> RequestHeaders -> Status -> IO Aeson.Value
requestJson manager host method path headers expected = do
  base <- Client.parseRequest ("http://127.0.0.1:" <> show host.serverPort <> path)
  response <- Client.httpLbs base {Client.method = method, Client.requestHeaders = headers, Client.requestBody = Client.RequestBodyLBS Lazy.empty, Client.checkResponse = \_ _ -> pure ()} manager
  Client.responseStatus response `shouldBe` expected
  either fail pure (Aeson.eitherDecode (Client.responseBody response))

field :: Key -> Aeson.Value -> Aeson.Value
field key (Aeson.Object fields) = maybe (error ("missing JSON field " <> show key)) id (KeyMap.lookup key fields)
field key value = error ("expected object for " <> show key <> ", got " <> show value)

items :: Aeson.Value -> [Aeson.Value]
items value = case field "items" value of
  Aeson.Array values -> Vector.toList values
  other -> error ("expected items array, got " <> show other)

showQuery :: [(Text, Text)] -> String
showQuery pairs = Char8.unpack (renderQuery False [(TextEncoding.encodeUtf8 key, Just (TextEncoding.encodeUtf8 value)) | (key, value) <- pairs])

stableHealth :: Aeson.Value -> Aeson.Value
stableHealth (Aeson.Object fields) = Aeson.Object (KeyMap.map stableHealth (foldr KeyMap.delete fields ["observed_at", "age_seconds"]))
stableHealth value = value
