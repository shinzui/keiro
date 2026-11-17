{-# LANGUAGE MultilineStrings #-}

module TopologySpec (spec) where

import Control.Exception (bracket, finally)
import Control.Monad (forM_)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Keiro.Ops qualified as Ops
import Keiro.Ops.Render
import Keiro.Ops.Topology qualified as Topology
import Keiro.Test.Postgres (Fixture, withFreshDatabase)
import Options.Applicative qualified as Opt
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = describe "service topology" $ do
  describe "decodeServiceTopology" $ do
    it "accepts a /1 document whose aggregate predates the category field" $ do
      document <- decoded schemaOneDocument
      Topology.serviceTopologySchemaId document `shouldBe` "keiro-dsl/service-topology/1"
      Topology.serviceTopologyBytes document `shouldBe` schemaOneDocument
      Topology.serviceTopologyValue document `shouldBe` json schemaOneDocument
      Topology.serviceTopologySummary document
        `shouldBe` object
          [ "schema_id" .= ("keiro-dsl/service-topology/1" :: Text),
            "service" .= ("orders" :: Text),
            "generator_version" .= ("1.2.3" :: Text),
            "source" .= object ["kind" .= ("source" :: Text), "path" .= ("orders.keiro" :: Text)],
            "members" .= [object ["path" .= ("orders.keiro" :: Text), "sha256" .= ("sha256:00" :: Text)]],
            "node_counts" .= object ["aggregate" .= (1 :: Int), "read-model" .= (2 :: Int)],
            "edge_counts" .= object ["writes" .= (1 :: Int), "consumes" .= (1 :: Int)],
            "document_bytes" .= ByteString.length schemaOneDocument,
            "document_sha256" .= ("sha256:" <> hex schemaOneDocument)
          ]

    it "computes the digest as lowercase hex SHA-256 of the exact bytes" $ do
      -- The known answer from `printf '{"a":1}\n' | shasum -a 256` checks the
      -- test's own digest helper independently of the library under test.
      document <- decoded schemaOneDocument
      Topology.serviceTopologyDigest document `shouldBe` "sha256:" <> hex schemaOneDocument
      hex "{\"a\":1}\n" `shouldBe` "e346432021b04179518d9614f3560ccd71354a4ee101ddcb893d6959a9d6301c"

    it "accepts feeds under /2, additional object fields and omits an unknown source shape" $ do
      document <- decoded schemaTwoDocument
      Topology.serviceTopologySchemaId document `shouldBe` "keiro-dsl/service-topology/2"
      let summary = Topology.serviceTopologySummary document
      field "edge_counts" summary `shouldBe` object ["feeds" .= (1 :: Int)]
      field "node_counts" summary `shouldBe` object ["intake" .= (1 :: Int), "aggregate" .= (1 :: Int)]
      KeyMap.member "source" (objectOf summary) `shouldBe` False
      field "members" summary `shouldBe` Aeson.toJSON ([] :: [Value])

    it "refuses malformed envelopes, unknown ids and unknown vocabulary" $ do
      let refusals =
            [ ("{}", "`schema`"),
              ("[]", "JSON object"),
              ("{\"schema\":", "not valid JSON"),
              (withSchema "keiro-dsl/service-topology/9", "\"keiro-dsl/service-topology/9\""),
              (replaceIn "\"service\":\"orders\"" "\"service\":7" schemaOneDocument, "`service`"),
              (replaceIn "\"version\":\"1.2.3\"" "\"version\":null" schemaOneDocument, "`generator.version`"),
              (replaceIn ",\"sha256\":\"sha256:00\"" "" schemaOneDocument, "`members[0].sha256`"),
              (replaceIn "\"nodes\":[" "\"nodes\":{\"x\":[" (replaceIn "],\"schema\"" "]},\"schema\"" schemaOneDocument), "`nodes`"),
              (replaceIn "\"kind\":\"aggregate\",\"line\"" "\"kind\":\"saga\",\"line\"" schemaOneDocument, "`nodes[0].kind`: unknown node kind \"saga\""),
              (replaceIn "\"from\":{\"kind\":\"aggregate\"" "\"from\":{\"kind\":\"actor\"" schemaOneDocument, "`edges[0].from.kind`: unknown node kind \"actor\""),
              (replaceIn "\"relation\":\"writes\"" "\"relation\":\"pokes\"" schemaOneDocument, "`edges[0].relation`: unknown relation \"pokes\""),
              (replaceIn "\"keiro-dsl/service-topology/2\"" "\"keiro-dsl/service-topology/1\"" schemaTwoDocument, "unknown relation \"feeds\"")
            ]
      forM_ refusals $ \(input, expected) -> case Topology.decodeServiceTopology input of
        Right _ -> expectationFailure ("accepted " <> Char8.unpack input)
        Left message -> message `shouldSatisfy` Text.isInfixOf expected

    it "reports a missing file by path" $ do
      result <- Topology.loadServiceTopology "does/not/exist.topology.json"
      either (Text.isInfixOf "does/not/exist.topology.json") (const False) result `shouldBe` True

  describe "producer goldens" $ do
    it "decodes every committed keiro-dsl golden when KEIRO_TOPOLOGY_FIXTURES is set" $ do
      directory <- lookupEnv "KEIRO_TOPOLOGY_FIXTURES"
      case directory of
        Nothing -> pendingWith "set KEIRO_TOPOLOGY_FIXTURES to keiro-dsl/test/fixtures/topology"
        Just root -> do
          forM_ goldenFiles $ \relative -> do
            result <- Topology.loadServiceTopology (root </> relative)
            either (\err -> expectationFailure (relative <> ": " <> Text.unpack err)) (const (pure ())) result
          schemas <- traverse (fmap (fmap Topology.serviceTopologySchemaId) . Topology.loadServiceTopology . (root </>)) goldenFiles
          schemas `shouldSatisfy` elem (Right "keiro-dsl/service-topology/2")

    it "summarizes the hospital golden from independent counts, size and digest" $ do
      directory <- lookupEnv "KEIRO_TOPOLOGY_FIXTURES"
      case directory of
        Nothing -> pendingWith "set KEIRO_TOPOLOGY_FIXTURES to keiro-dsl/test/fixtures/topology"
        Just root -> do
          bytes <- ByteString.readFile (root </> "hospital-capacity.topology.golden.json")
          document <- decoded bytes
          let summary = Topology.serviceTopologySummary document
              value = json bytes
              countBy collection key = Aeson.toJSON (Map.fromListWith (+) [(textAt key item, 1 :: Int) | item <- arrayAt collection value])
          ByteString.last bytes `shouldBe` 10
          field "document_bytes" summary `shouldBe` Aeson.toJSON (ByteString.length bytes)
          field "document_sha256" summary `shouldBe` String ("sha256:" <> hex bytes)
          field "node_counts" summary `shouldBe` countBy "nodes" "kind"
          field "edge_counts" summary `shouldBe` countBy "edges" "relation"
          field "schema_id" summary `shouldBe` String "keiro-dsl/service-topology/1"
          field "service" summary `shouldBe` String "hospital-capacity"
          field "source" summary `shouldBe` object ["kind" .= ("source" :: Text), "path" .= ("hospital-capacity.keiro" :: Text)]

  describe "topology commands" $ do
    it "mounts show and summary only with the hook, as reads" $ do
      document <- decoded schemaOneDocument
      let mounted = Ops.emptyAppHooks {Ops.serviceTopology = Just document}
      forM_ ["show", "summary"] $ \word -> do
        isJust (parsedCommand Ops.emptyAppHooks ["topology", word]) `shouldBe` False
        fmap Ops.isMutation (parsedCommand mounted ["topology", word]) `shouldBe` Just False
        fmap (either (const False) (const True) . Ops.validateCommand) (parsedCommand mounted ["topology", word]) `shouldBe` Just True
      isJust (parsedCommand mounted ["topology"]) `shouldBe` False
      isJust (parsedCommand mounted ["topology", "graph"]) `shouldBe` False

    it "returns the document and summary as JSON results" $ do
      document <- decoded schemaOneDocument
      jsonOf (Topology.runCommand document Topology.Show) `shouldBe` Just (json schemaOneDocument)
      jsonOf (Topology.runCommand document Topology.Summary) `shouldBe` Just (Topology.serviceTopologySummary document)

    around (withFreshDatabase fixture) $
      it "prints the complete document and summary through the normal CLI runner" $ \connectionString -> do
        document <- decoded schemaOneDocument
        let mounted = Ops.emptyAppHooks {Ops.serviceTopology = Just document}
            run word = do
              invocation <- case Opt.execParserPure Opt.defaultPrefs (Ops.opsCommandTree mounted) ["--database-url", Text.unpack connectionString, "--json", "topology", word] of
                Opt.Success parsed -> pure parsed
                _ -> fail "topology command did not parse"
              captureStdout (Ops.runOpsInvocation mounted invocation)
        (showExit, shown) <- run "show"
        showExit `shouldBe` ExitSuccess
        Aeson.eitherDecodeStrict shown `shouldBe` Right (json schemaOneDocument)
        (summaryExit, summarized) <- run "summary"
        summaryExit `shouldBe` ExitSuccess
        Aeson.eitherDecodeStrict summarized `shouldBe` Right (Topology.serviceTopologySummary document)
  where
    decoded bytes = either (fail . Text.unpack) pure (Topology.decodeServiceTopology bytes)
    jsonOf = \case
      Succeeded result -> Just result.jsonValue
      _ -> Nothing
    parsedCommand hooks args = case Opt.execParserPure Opt.defaultPrefs (Opt.info (Ops.commandParser hooks) mempty) args of
      Opt.Success command -> Just command
      _ -> Nothing
    withSchema schema = replaceIn "\"keiro-dsl/service-topology/1\"" ("\"" <> schema <> "\"") schemaOneDocument

goldenFiles :: [FilePath]
goldenFiles =
  [ "hospital-capacity.topology.golden.json",
    "incident-command.topology.golden.json",
    "incident-command-sourced.topology.golden.json",
    "projection-catalog.topology.golden.json",
    "workspace" </> "service.topology.golden.json"
  ]

schemaOneDocument :: ByteString
schemaOneDocument =
  Char8.pack
    ( filter
        (/= '\n')
        """
        {"edges":[{"attributes":{},"from":{"kind":"aggregate","name":"Order"},"relation":"writes","to":{"kind":"read-model","name":"order_summary"}},
        {"attributes":{},"from":{"kind":"aggregate","name":"Order"},"relation":"consumes","to":{"kind":"read-model","name":"order_lines"}}],
        "effectiveSemanticContract":6,"futureField":{"anything":[1,2]},
        "generator":{"tool":"keiro-dsl","version":"1.2.3"},
        "members":[{"declaredLanguageVersion":6,"effectiveLanguageVersion":6,"path":"orders.keiro","sha256":"sha256:00"}],
        "nodes":[{"context":"orders","details":{"stream":"order"},"kind":"aggregate","line":3,"member":"orders.keiro","name":"Order"},
        {"context":"orders","details":{},"kind":"read-model","line":9,"member":"orders.keiro","name":"order_summary"},
        {"context":"orders","details":{},"kind":"read-model","line":12,"member":"orders.keiro","name":"order_lines"}],
        "schema":"keiro-dsl/service-topology/1","service":"orders","source":{"kind":"source","path":"orders.keiro"}}
        """
    )
    <> "\n"

schemaTwoDocument :: ByteString
schemaTwoDocument =
  Char8.pack
    ( filter
        (/= '\n')
        """
        {"edges":[{"attributes":{"x":1},"from":{"kind":"intake","name":"ingest"},"relation":"feeds","to":{"kind":"aggregate","name":"Order"}}],
        "effectiveSemanticContract":6,"generator":{"tool":"keiro-dsl","version":"<version>"},"members":[],
        "nodes":[{"kind":"intake","name":"ingest","details":{}},{"kind":"aggregate","name":"Order","details":{"category":"order"}}],
        "schema":"keiro-dsl/service-topology/2","service":"orders","source":{"kind":"archive","path":"x"}}
        """
    )

replaceIn :: Text -> Text -> ByteString -> ByteString
replaceIn needle replacement = Text.Encoding.encodeUtf8 . Text.replace needle replacement . Text.Encoding.decodeUtf8

hex :: ByteString -> Text
hex = Text.Encoding.decodeUtf8 . LazyByteString.toStrict . Builder.toLazyByteString . Builder.byteStringHex . SHA256.hash

json :: ByteString -> Value
json bytes = either error id (Aeson.eitherDecodeStrict bytes)

objectOf :: Value -> KeyMap.KeyMap Value
objectOf = \case
  Object fields -> fields
  _ -> KeyMap.empty

field :: KeyMap.Key -> Value -> Value
field key value = maybe Null id (KeyMap.lookup key (objectOf value))

arrayAt :: KeyMap.Key -> Value -> [Value]
arrayAt key value = case field key value of
  Array items -> toList items
  _ -> []

textAt :: KeyMap.Key -> Value -> Text
textAt key value = case field key value of
  String text -> text
  _ -> ""

-- | Run an action with stdout redirected to a temporary file and return it.
captureStdout :: IO a -> IO (a, ByteString)
captureStdout action = do
  directory <- getTemporaryDirectory
  bracket (openBinaryTempFile directory "keiro-ops-topology.out") (\(path, handle) -> hClose handle `finally` removeFile path) $ \(path, handle) -> do
    hFlush stdout
    saved <- hDuplicate stdout
    result <- (hDuplicateTo handle stdout >> action) `finally` (hFlush stdout >> hDuplicateTo saved stdout >> hClose saved)
    hClose handle
    output <- ByteString.readFile path
    pure (result, output)
