module CategoryConsumersSpec (spec) where

import Control.Exception (finally)
import Control.Monad (forM_, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encoding qualified as Encoding
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Keiro.Inspection.Consumers qualified as C
import Keiro.Inspection.Cursor
import Keiro.Ops qualified as Ops
import Keiro.Ops.Env
import Keiro.Ops.Projection qualified as P
import Keiro.Ops.Render
import Keiro.Ops.WorkflowHeaderCache
import Keiro.Test.Postgres
import Kiroku.Store.Connection (ConnectionSettingsM (..))
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Read (getStream)
import Kiroku.Store.Types (StreamName (..))
import Options.Applicative qualified as Opt
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = describe "category consumers commands" $ do
  it "mounts for either metadata hook and distinguishes empty from missing coverage" $ do
    let empty = registry []
        hooks = Ops.emptyAppHooks {Ops.durableConsumers = Just empty}
        args = ["projection", "consumers", "--category", "order"]
        parses mounted = case Opt.execParserPure Opt.defaultPrefs (Opt.info (Ops.commandParser mounted) mempty) args of Opt.Success _ -> True; _ -> False
    parses Ops.emptyAppHooks `shouldBe` False
    parses hooks `shouldBe` True
    Right (result, _) <- pure (P.prepareConsumers Nothing (Just empty) (options "order"))
    field "items" result.jsonValue `shouldBe` Aeson.toJSON ([] :: [Value])
    field "coverage" result.jsonValue `shouldBe` object ["projection_catalog" .= False, "durable_subscribers" .= True]
    P.isMutation (P.Consumers (options "order")) `shouldBe` False
  it "pages a deterministic sequence without omissions and binds tokens to category and inventory" $ do
    let mounted = registry [description "z" "s-z", description "a" "s-a", description "m" "s-m", description "a" "s-a2"]
        prepare request = P.prepareConsumers Nothing (Just mounted) request
        firstRequest = P.ConsumersOptions "order" 1 Nothing
    Right (first, _) <- pure (prepare firstRequest)
    names first `shouldBe` ["a"]
    let String token = field "next_cursor" first.jsonValue
    Right (second, _) <- pure (prepare firstRequest {P.after = Just (InspectionCursor token)})
    names second `shouldBe` ["m"]
    let String next = field "next_cursor" second.jsonValue
    Right (last, _) <- pure (prepare firstRequest {P.after = Just (InspectionCursor next)})
    names last `shouldBe` ["z"]
    field "next_cursor" last.jsonValue `shouldBe` Null
    forM_ [first, second, last] $ \result -> Text.length (renderHuman result) `shouldSatisfy` (> 0)
    let changed = registry [description "new" "s-new"]
    failureCode (prepare firstRequest {P.category = "invoice", P.after = Just (InspectionCursor token)}) `shouldBe` Just "invalid_cursor"
    failureCode (P.prepareConsumers Nothing (Just changed) firstRequest {P.after = Just (InspectionCursor token)}) `shouldBe` Just "invalid_cursor"
    forM_ [InspectionCursor "bad", InspectionCursor (Text.replicate 4097 "a"), encodeCursor "other-kind" ("x" :: Text)] $ \cursor ->
      P.validateCommand (P.Consumers firstRequest {P.after = Just cursor}) `shouldSatisfy` (\case Left ("invalid_cursor", _) -> True; _ -> False)
    forM_ [0, 501] $ \limit -> failureCode (prepare firstRequest {P.limit = limit}) `shouldBe` Just "invalid_page_size"
    forM_ ["", " order", "order "] $ \category -> failureCode (prepare firstRequest {P.category = category}) `shouldBe` Just "invalid_category"
    let huge = registry [description (Text.replicate 5000 "x") "one", description (Text.replicate 5001 "x") "two"]
    failureCode (P.prepareConsumers Nothing (Just huge) firstRequest) `shouldBe` Just "inspection_result_too_large"
  it "renders and directly encodes afresh without touching the store or header cache" $ do
    armed <- newIORef False
    let observe _ = readIORef armed >>= \active -> when active (fail "category consumers touched the store")
    withFreshResourceStoreWith fixture (\settings -> settings {observationHandler = Just observe}) $ \(unusable, _) ->
      flip finally (writeIORef armed False) $ do
        writeIORef armed True
        let mounted = registry [description "escaped-\"\\\n界" "subscription", C.DurableConsumerDescription C.ProcessManagerConsumer "fulfillment" "orders" (C.ExactCategory "order")]
            hooks = Ops.emptyAppHooks {Ops.durableConsumers = Just mounted}
            env = OpsEnv unusable HumanTable False [] False
            command = Ops.Projection (P.Consumers (options "order"))
        runStoreIO unusable (getStream (StreamName "sentinel")) `shouldThrow` anyIOException
        Succeeded result <- Ops.runCommand hooks env command
        Text.length (renderHuman result) `shouldSatisfy` (> 0)
        Text.length (jsonText result.jsonValue) `shouldSatisfy` (> 0)
        cache <- newWorkflowHeaderCache 1048576 (const (fail "category consumers used the header cache"))
        calls <- newIORef (0 :: Int)
        let encode encoding = modifyIORef' calls (+ 1) >> pure (Just (Lazy.toStrict (Encoding.encodingToLazyByteString encoding)))
        forM_ [1, 2 :: Int] $ \_ -> do
          (Succeeded direct, Just bytes) <- Ops.runCommandWithReadEncoding encode cache hooks env command
          direct `shouldBe` result
          Aeson.eitherDecodeStrict bytes `shouldBe` Right result.jsonValue
        readIORef calls `shouldReturn` 2
        workflowHeaderCacheUsage cache `shouldReturn` (0, 0)
        (refused, bytes) <- Ops.runCommandWithReadEncoding (const (pure Nothing)) cache hooks env command
        refused `shouldSatisfy` (\case InspectionFailed "inspection_result_too_large" _ -> True; _ -> False)
        bytes `shouldBe` Nothing
        forM_ [0, 501] $ \limit -> do
          invalid <- Ops.runCommand hooks env (Ops.Projection (P.Consumers (options "order") {P.limit = limit}))
          invalid `shouldSatisfy` (\case InspectionFailed "invalid_page_size" _ -> True; _ -> False)

options :: Text -> P.ConsumersOptions
options category = P.ConsumersOptions category 100 Nothing

description :: Text -> Text -> C.DurableConsumerDescription
description name subscription = C.DurableConsumerDescription C.DurableSubscriber name subscription (C.ExactCategory "order")

registry :: [C.DurableConsumerDescription] -> C.DurableConsumerRegistry
registry = either (error . show) id . C.durableConsumerRegistry

field :: Aeson.Key -> Value -> Value
field key (Object fields) = maybe Null id (KeyMap.lookup key fields)
field _ _ = Null

names :: OpsResult -> [Text]
names result = case field "items" result.jsonValue of
  Array values -> [name | String name <- map (field "name") (Vector.toList values)]
  _ -> []

failureCode :: Either (Text, Text) a -> Maybe Text
failureCode (Left (code, _)) = Just code
failureCode _ = Nothing
