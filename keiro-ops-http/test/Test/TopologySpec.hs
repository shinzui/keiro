module Test.TopologySpec (spec) where

import Control.Exception (bracket, try)
import Control.Monad (forM_)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Keiro.Ops qualified as Ops
import Keiro.Ops.Http
import Keiro.Ops.Http.Config qualified as Config
import Keiro.Test.Postgres (Fixture, withFreshDatabase, withFreshStore)
import Network.HTTP.Client qualified as Client
import Network.HTTP.Types
import Network.Wai (Application, requestHeaders, requestMethod)
import Network.Wai.Test
import Options.Applicative qualified as Options
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.IO (hClose, openBinaryTempFile)
import System.Process (readProcessWithExitCode)
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = describe "service topology over HTTP" $ do
  around (withFreshStore fixture) $ do
    it "serves the mounted bytes, a matching summary and the response cap" $ \store -> do
      document <- decoded spacedDocument
      let mounted = Ops.emptyAppHooks {Ops.serviceTopology = Just document}
          limitedTo bytes = defaultOpsHttpConfig {inspectionLimits = defaultInspectionLimits {maxResponseBytes = bytes}}
      app <- opsApplication defaultOpsHttpConfig mounted store
      shown <- call app methodGet "/topology/show" []
      simpleStatus shown `shouldBe` status200
      lookup hContentType (simpleHeaders shown) `shouldBe` Just "application/json; charset=utf-8"
      LazyByteString.toStrict (simpleBody shown) `shouldBe` spacedDocument
      summary <- call app methodGet "/topology/summary" []
      simpleStatus summary `shouldBe` status200
      body summary `shouldBe` Ops.serviceTopologySummary document
      field "document_sha256" (body summary) `shouldBe` Just (String ("sha256:" <> hex (LazyByteString.toStrict (simpleBody shown))))
      field "document_bytes" (body summary) `shouldBe` Just (Aeson.toJSON (LazyByteString.length (simpleBody shown)))
      exact <- opsApplication (limitedTo (ByteString.length spacedDocument)) mounted store
      atLimit <- call exact methodGet "/topology/show" []
      simpleStatus atLimit `shouldBe` status200
      LazyByteString.toStrict (simpleBody atLimit) `shouldBe` spacedDocument
      small <- opsApplication (limitedTo (ByteString.length spacedDocument - 1)) mounted store
      oversized <- call small methodGet "/topology/show" []
      assertError oversized status413 "inspection_result_too_large"

    it "is a read, hook-gated, and carries CORS for an allowed origin" $ \store -> do
      document <- decoded spacedDocument
      let mounted = Ops.emptyAppHooks {Ops.serviceTopology = Just document}
      app <- opsApplication defaultOpsHttpConfig {Config.allowedOrigins = ["http://ui.example"]} mounted store
      forM_ ["/topology/show", "/topology/summary"] $ \path -> do
        refused <- call app methodPost path []
        assertError refused status405 "method_not_allowed"
        lookup hAllow (simpleHeaders refused) `shouldBe` Just "GET"
      cross <- call app methodGet "/topology/show" [("Origin", "http://ui.example")]
      simpleStatus cross `shouldBe` status200
      lookup "Access-Control-Allow-Origin" (simpleHeaders cross) `shouldBe` Just "http://ui.example"
      absent <- opsApplication defaultOpsHttpConfig Ops.emptyAppHooks store
      forM_ ["/topology/show", "/topology/summary", "/aggregate/types"] $ \path -> do
        response <- call absent methodGet path []
        assertError response status400 "invalid_request"

  describe "--topology" $ do
    it "parses as an optional file" $ do
      fmap (.topology) (parseHost ["--topology", "services/orders/topology.json"]) `shouldBe` Just (Just "services/orders/topology.json")
      fmap (.topology) (parseHost []) `shouldBe` Just Nothing

    it "refuses to start the executable on a missing file" $ do
      executable <- hostExecutable
      (exit, _, err) <- readProcessWithExitCode executable ["--topology", "does/not/exist.topology.json"] ""
      exit `shouldBe` ExitFailure 1
      Text.pack err `shouldSatisfy` Text.isInfixOf "--topology does/not/exist.topology.json"

    around (withFreshDatabase fixture) $ do
      it "mounts a file over an in-code document and keeps the other hooks" $ \url -> do
        inCode <- decoded otherDocument
        fromFile <- decoded spacedDocument
        withTopologyFile spacedDocument $ \path -> do
          let hooks = Ops.emptyAppHooks {Ops.serviceTopology = Just inCode, Ops.processManagers = Just Map.empty}
          withHost (options url defaultOpsHttpConfig (Just path)) hooks $ \host -> do
            manager <- Client.newManager Client.defaultManagerSettings
            (status, summary) <- get manager host "/topology/summary"
            status `shouldBe` status200
            Aeson.eitherDecodeStrict summary `shouldBe` Right (Ops.serviceTopologySummary fromFile)
            (_, shown) <- get manager host "/topology/show"
            shown `shouldBe` spacedDocument
            (pmStatus, _) <- get manager host "/pm/types"
            pmStatus `shouldBe` status200
          withHost (options url defaultOpsHttpConfig Nothing) hooks $ \host -> do
            manager <- Client.newManager Client.defaultManagerSettings
            (_, shown) <- get manager host "/topology/show"
            shown `shouldBe` otherDocument

      it "refuses an unusable file before the continuation runs" $ \url -> do
        let unknownSchema = replaceIn "keiro-dsl/service-topology/1" "keiro-dsl/service-topology/9" spacedDocument
            limit = ByteString.length spacedDocument - 1
            cases =
              [ (Nothing, defaultOpsHttpConfig, "does not exist"),
                (Just "{\"schema\":", defaultOpsHttpConfig, "not valid JSON"),
                (Just unknownSchema, defaultOpsHttpConfig, "keiro-dsl/service-topology/9"),
                (Just spacedDocument, defaultOpsHttpConfig {inspectionLimits = defaultInspectionLimits {maxResponseBytes = limit}}, "larger than the response limit of " <> Text.pack (show limit))
              ]
        forM_ cases $ \(contents, config, expected) -> do
          ran <- newIORef False
          let attempt path = withHost (options url config (Just path)) Ops.emptyAppHooks (\_ -> writeIORef ran True)
          result <- case contents of
            Nothing -> attemptStartup (attempt "does/not/exist.topology.json")
            Just bytes -> withTopologyFile bytes (attemptStartup . attempt)
          case result of
            Left (HostStartupError message) -> message `shouldSatisfy` Text.isInfixOf expected
            Right () -> expectationFailure ("host started for " <> Text.unpack expected)
          readIORef ran `shouldReturn` False
  where
    decoded bytes = either (fail . Text.unpack) pure (Ops.decodeServiceTopology bytes)
    parseHost args = case Options.execParserPure Options.defaultPrefs (Options.info hostOptionsParser mempty) args of
      Options.Success parsed -> Just parsed
      _ -> Nothing
    attemptStartup :: IO () -> IO (Either HostStartupError ())
    attemptStartup = try

options :: Text -> OpsHttpConfig -> Maybe FilePath -> HostOptions
options url config topology = HostOptions {databaseUrl = Just url, http = config, server = defaultOpsHttpServerConfig {port = 0}, topology}

-- Whitespace and key order that re-encoding would change, plus a final newline,
-- so byte identity proves the host does not re-encode the document.
spacedDocument :: ByteString
spacedDocument =
  Char8.pack
    ( unlines
        [ "{ \"schema\": \"keiro-dsl/service-topology/1\",",
          "  \"service\": \"orders\",",
          "  \"source\": {\"path\": \"orders.keiro\", \"kind\": \"source\"},",
          "  \"generator\": {\"version\": \"1.2.3\", \"tool\": \"keiro-dsl\"},",
          "  \"members\": [{\"sha256\": \"sha256:00\", \"path\": \"orders.keiro\"}],",
          "  \"nodes\": [{\"name\": \"Order\", \"kind\": \"aggregate\", \"details\": {\"category\": \"order\"}},",
          "            {\"name\": \"order_summary\", \"kind\": \"read-model\", \"details\": {}}],",
          "  \"edges\": [{\"relation\": \"writes\", \"from\": {\"name\": \"Order\", \"kind\": \"aggregate\"}, \"to\": {\"name\": \"order_summary\", \"kind\": \"read-model\"}, \"attributes\": {}}]",
          "}"
        ]
    )

otherDocument :: ByteString
otherDocument = "{\"edges\":[],\"generator\":{\"version\":\"0\"},\"members\":[],\"nodes\":[],\"schema\":\"keiro-dsl/service-topology/2\",\"service\":\"billing\"}\n"

withTopologyFile :: ByteString -> (FilePath -> IO a) -> IO a
withTopologyFile contents action = do
  directory <- getTemporaryDirectory
  bracket (openBinaryTempFile directory "service.topology.json") (\(path, _) -> removeFile path) $ \(path, handle) -> do
    ByteString.hPut handle contents
    hClose handle
    action path

get :: Client.Manager -> OpsHttpServer -> String -> IO (Status, ByteString)
get manager host path = do
  req <- Client.parseRequest ("http://127.0.0.1:" <> show host.serverPort <> path)
  response <- Client.httpLbs req manager
  pure (Client.responseStatus response, LazyByteString.toStrict (Client.responseBody response))

call :: Application -> Method -> Text -> RequestHeaders -> IO SResponse
call app method path headers = runSession (srequest (SRequest ((setPath defaultRequest (Text.Encoding.encodeUtf8 path)) {requestMethod = method, requestHeaders = headers}) "")) app

body :: SResponse -> Value
body response = either error id (Aeson.eitherDecode (simpleBody response))

field :: Aeson.Key -> Value -> Maybe Value
field key (Object value) = KeyMap.lookup key value
field _ _ = Nothing

assertError :: SResponse -> Status -> Text -> Expectation
assertError response expected code = do
  simpleStatus response `shouldBe` expected
  (field "error" (body response) >>= field "code") `shouldBe` Just (String code)

replaceIn :: Text -> Text -> ByteString -> ByteString
replaceIn needle replacement = Text.Encoding.encodeUtf8 . Text.replace needle replacement . Text.Encoding.decodeUtf8

hex :: ByteString -> Text
hex = Text.Encoding.decodeUtf8 . LazyByteString.toStrict . Builder.toLazyByteString . Builder.byteStringHex . SHA256.hash

hostExecutable :: IO FilePath
hostExecutable = do
  (exit, out, err) <- readProcessWithExitCode "cabal" ["list-bin", "exe:keiro-ops-http"] ""
  if exit == ExitSuccess then pure (Text.unpack (Text.strip (Text.pack out))) else fail err
