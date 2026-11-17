-- | Serve an application's committed keiro-dsl service-topology document.
--
-- The document is a published, versioned contract owned by keiro-dsl
-- (@docs/adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md@).
-- This module does not depend on keiro-dsl. It checks the envelope fields the
-- summary needs and each schema id's node-kind and edge-relation vocabulary,
-- keeps kind-specific details opaque, and retains the exact mounted bytes so
-- HTTP hosts can return them unchanged.
module Keiro.Ops.Topology
  ( ServiceTopologyDocument,
    decodeServiceTopology,
    loadServiceTopology,
    serviceTopologySchemaId,
    serviceTopologyBytes,
    serviceTopologyValue,
    serviceTopologyDigest,
    serviceTopologySummary,
    supportedServiceTopologySchemaIds,
    Command (..),
    commandParser,
    isMutation,
    runCommand,
  )
where

import Control.Exception (IOException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Keiro.Ops.Render
import Options.Applicative hiding (command, info, value)
import Options.Applicative qualified as Opt

-- | A mounted keiro-dsl service-topology document: the exact bytes and their
-- decoded value. Construct only with 'decodeServiceTopology'.
data ServiceTopologyDocument = ServiceTopologyDocument
  { bytes :: !ByteString,
    value :: !Value,
    schemaId :: !Text,
    service :: !Text,
    digest :: !Text,
    nodeCount :: !Int,
    edgeCount :: !Int,
    summary :: !Value
  }

instance Eq ServiceTopologyDocument where
  left == right = left.bytes == right.bytes

instance Show ServiceTopologyDocument where
  show document = "ServiceTopologyDocument " <> show document.schemaId <> " " <> show document.service <> " " <> show document.digest

serviceTopologySchemaId :: ServiceTopologyDocument -> Text
serviceTopologySchemaId document = document.schemaId

-- | The exact bytes that were mounted, including any final newline.
serviceTopologyBytes :: ServiceTopologyDocument -> ByteString
serviceTopologyBytes document = document.bytes

serviceTopologyValue :: ServiceTopologyDocument -> Value
serviceTopologyValue document = document.value

-- | @sha256:@ and the lowercase hex digest of the mounted bytes.
serviceTopologyDigest :: ServiceTopologyDocument -> Text
serviceTopologyDigest document = document.digest

-- | The snake_case summary served by @topology summary@, computed at decode.
serviceTopologySummary :: ServiceTopologyDocument -> Value
serviceTopologySummary document = document.summary

-- | Schema ids this reader can mount, oldest first.
supportedServiceTopologySchemaIds :: [Text]
supportedServiceTopologySchemaIds = Map.keys vocabularies

data Vocabulary = Vocabulary {nodeKinds :: !(Set Text), relations :: !(Set Text)}

-- Copied from @$defs.nodeKind.enum@ and @$defs.relation.enum@ in
-- @docs/user/schemas/keiro-dsl-service-topology-{1,2}.schema.json@ so a host
-- needs only the document. A new schema id or vocabulary requires a change here.
vocabularies :: Map.Map Text Vocabulary
vocabularies =
  Map.fromList
    [ ("keiro-dsl/service-topology/1", Vocabulary kinds relationsOne),
      ("keiro-dsl/service-topology/2", Vocabulary kinds (Set.insert "feeds" relationsOne))
    ]
  where
    kinds =
      Set.fromList
        [ "aggregate",
          "process",
          "workflow",
          "router",
          "contract",
          "intake",
          "emit",
          "publisher",
          "workqueue",
          "dispatch",
          "read-model",
          "operation",
          "projection-target",
          "rebuild-group",
          "projection-owner",
          "projection-revision",
          "external-read"
        ]
    relationsOne =
      Set.fromList
        [ "dispatches",
          "saga",
          "reads",
          "projects",
          "publishes",
          "subscribes",
          "delivers",
          "enqueues",
          "commands",
          "queries",
          "signals",
          "runs",
          "depends-on",
          "groups",
          "consumes",
          "writes",
          "member-of",
          "revises",
          "observes",
          "backed-by",
          "exposes",
          "compatible-with"
        ]

-- | Decode and check a document for mounting. The diagnostic names the
-- offending field and value. Additional object fields are ignored.
decodeServiceTopology :: ByteString -> Either Text ServiceTopologyDocument
decodeServiceTopology input = do
  value <- either (\err -> Left ("service topology is not valid JSON: " <> Text.pack err)) Right (Aeson.eitherDecodeStrict input)
  root <- case value of
    Object fields -> Right fields
    other -> Left ("service topology must be a JSON object, found " <> typeName other)
  schemaId <- textField "schema" root
  vocabulary <- case Map.lookup schemaId vocabularies of
    Just known -> Right known
    Nothing ->
      Left
        ( "unsupported service topology schema id "
            <> quoted schemaId
            <> " in field `schema`; supported: "
            <> Text.intercalate ", " supportedServiceTopologySchemaIds
        )
  service <- textField "service" root
  generator <- objectField "generator" root
  generatorVersion <- prefixed "generator" (textField "version" generator)
  members <- arrayField "members" root
  projectedMembers <- traverse member (zip [0 :: Int ..] members)
  nodes <- arrayField "nodes" root
  observedKinds <- traverse (node vocabulary) (zip [0 :: Int ..] nodes)
  edges <- arrayField "edges" root
  observedRelations <- traverse (edge vocabulary) (zip [0 :: Int ..] edges)
  let digest = "sha256:" <> hexDigest input
      sourceField = case KeyMap.lookup "source" root of
        Just (Object source)
          | Just (String kind) <- KeyMap.lookup "kind" source,
            kind `elem` ["source", "workspace"],
            Just (String path) <- KeyMap.lookup "path" source ->
              ["source" .= object ["kind" .= kind, "path" .= path]]
        _ -> []
      summary =
        object
          ( [ "schema_id" .= schemaId,
              "service" .= service,
              "generator_version" .= generatorVersion,
              "members" .= projectedMembers,
              "node_counts" .= counts observedKinds,
              "edge_counts" .= counts observedRelations,
              "document_bytes" .= ByteString.length input,
              "document_sha256" .= digest
            ]
              <> sourceField
          )
  Right
    ServiceTopologyDocument
      { bytes = input,
        value,
        schemaId,
        service,
        digest,
        nodeCount = length nodes,
        edgeCount = length edges,
        summary
      }
  where
    member (index, entry) = prefixed (indexed "members" index) $ do
      fields <- asObject entry
      path <- textField "path" fields
      sha256 <- textField "sha256" fields
      Right (object ["path" .= path, "sha256" .= sha256])
    node vocabulary (index, entry) = prefixed (indexed "nodes" index) $ do
      fields <- asObject entry
      kindOf vocabulary fields
    edge vocabulary (index, entry) = prefixed (indexed "edges" index) $ do
      fields <- asObject entry
      _ <- objectField "from" fields >>= prefixed "from" . kindOf vocabulary
      _ <- objectField "to" fields >>= prefixed "to" . kindOf vocabulary
      relation <- textField "relation" fields
      if Set.member relation vocabulary.relations
        then Right relation
        else Left ("field `relation`: unknown relation " <> quoted relation <> " for this schema id")
    kindOf vocabulary fields = do
      kind <- textField "kind" fields
      if Set.member kind vocabulary.nodeKinds
        then Right kind
        else Left ("field `kind`: unknown node kind " <> quoted kind <> " for this schema id")
    indexed name index = name <> "[" <> Text.pack (show index) <> "]"
    -- Diagnostics from nested fields carry their path, e.g. @edges[3].relation@.
    prefixed prefix = either (Left . addPrefix prefix) Right
    addPrefix prefix message = case Text.stripPrefix "field `" message of
      Just rest
        | "`" `Text.isPrefixOf` rest -> "field `" <> prefix <> rest
        | otherwise -> "field `" <> prefix <> "." <> rest
      Nothing -> message
    asObject = \case
      Object fields -> Right fields
      other -> Left ("field ``: expected an object, found " <> typeName other)
    counts = Map.fromListWith (+) . map (,1 :: Int)

-- | Read and decode a document from disk. I/O and decode failures are both
-- returned as 'Left' so callers can report the failing path.
loadServiceTopology :: FilePath -> IO (Either Text ServiceTopologyDocument)
loadServiceTopology path = do
  result <- try (ByteString.readFile path)
  pure $ case result of
    Left (err :: IOException) -> Left (Text.pack path <> ": " <> Text.pack (show err))
    Right input -> either (Left . ((Text.pack path <> ": ") <>)) Right (decodeServiceTopology input)

textField :: Text -> KeyMap Value -> Either Text Text
textField name fields = case KeyMap.lookup (Key.fromText name) fields of
  Just (String text) -> Right text
  Just other -> Left ("field `" <> name <> "`: expected a string, found " <> typeName other)
  Nothing -> Left ("field `" <> name <> "`: missing")

objectField :: Text -> KeyMap Value -> Either Text (KeyMap Value)
objectField name fields = case KeyMap.lookup (Key.fromText name) fields of
  Just (Object inner) -> Right inner
  Just other -> Left ("field `" <> name <> "`: expected an object, found " <> typeName other)
  Nothing -> Left ("field `" <> name <> "`: missing")

arrayField :: Text -> KeyMap Value -> Either Text [Value]
arrayField name fields = case KeyMap.lookup (Key.fromText name) fields of
  Just (Array items) -> Right (toList items)
  Just other -> Left ("field `" <> name <> "`: expected an array, found " <> typeName other)
  Nothing -> Left ("field `" <> name <> "`: missing")

typeName :: Value -> Text
typeName = \case
  Object _ -> "an object"
  Array _ -> "an array"
  String text -> "the string " <> quoted text
  Number _ -> "a number"
  Bool _ -> "a boolean"
  Null -> "null"

quoted :: Text -> Text
quoted text = Text.pack (show (Text.unpack (Text.take 120 text)))

hexDigest :: ByteString -> Text
hexDigest = Text.Encoding.decodeUtf8 . LazyByteString.toStrict . Builder.toLazyByteString . Builder.byteStringHex . SHA256.hash

data Command = Show | Summary
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( Opt.command "show" (Opt.info (pure Show) (progDesc "Print the mounted service-topology document"))
        <> Opt.command "summary" (Opt.info (pure Summary) (progDesc "Summarize the mounted service-topology document"))
    )

isMutation :: Command -> Bool
isMutation = const False

-- | Both reads are pure: the document is fixed for the life of the process.
-- HTTP hosts serve @show@ from 'serviceTopologyBytes' instead of re-encoding.
runCommand :: ServiceTopologyDocument -> Command -> OpsOutcome
runCommand document = \case
  Show ->
    Succeeded
      ( OpsResult
          ["schema", "service", "nodes", "edges"]
          [[document.schemaId, document.service, Text.pack (show document.nodeCount), Text.pack (show document.edgeCount)]]
          document.value
      )
  Summary ->
    Succeeded
      ( OpsResult
          ["schema_id", "service", "nodes", "edges", "document_bytes", "document_sha256"]
          [ [ document.schemaId,
              document.service,
              Text.pack (show document.nodeCount),
              Text.pack (show document.edgeCount),
              Text.pack (show (ByteString.length document.bytes)),
              document.digest
            ]
          ]
          document.summary
      )
