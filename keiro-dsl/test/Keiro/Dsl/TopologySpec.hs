-- | Tests for the service topology export (@keiro-dsl topology@,
-- @keiro-dsl/service-topology/1@).
module Keiro.Dsl.TopologySpec (topologySpec) where

import Control.Exception (bracket)
import Control.Monad (filterM, forM_)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.List (isPrefixOf, sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Version (showVersion)
import Keiro.Dsl.Parser (parseSourceDocument, renderParseFailure)
import Keiro.Dsl.Topology
import Keiro.Dsl.Workspace (WorkspaceSpec, oneMemberParsedDocumentWorkspace)
import Paths_keiro_dsl qualified as Package
import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory, makeAbsolute, removeFile, removePathForcibly)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (hClose, openTempFile)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec

topologySpec :: Spec
topologySpec = describe "service topology" $ do
  libraryTests
  commandTests
  catalogTests
  stabilityTests

--------------------------------------------------------------------------------
-- Milestone 1: the library
--------------------------------------------------------------------------------

libraryTests :: Spec
libraryTests = do
  it "spells the closed node-kind and relation sets" $ do
    map nodeKindText allNodeKinds
      `shouldBe` [ "aggregate",
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
    map relationText allRelations
      `shouldBe` [ "dispatches",
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

  it "digests the exact member bytes" $
    memberDigest "abc" `shouldBe` "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  it "records each node's owning member, line and context" $ do
    topology <- inlineTopology "reaction.keiro" reactionSource
    [(nodeKindText node.kind, node.name, node.member, node.line, node.context) | node <- topology.nodes]
      `shouldBe` [ ("aggregate", "Incident", "reaction.keiro", 31, "topology-reaction"),
                   ("aggregate", "IncidentSaga", "reaction.keiro", 24, "topology-reaction"),
                   ("process", "IncidentReaction", "reaction.keiro", 6, "topology-reaction")
                 ]
    topologySchemaId topology `shouldBe` "keiro-dsl/service-topology/1"
    topology.service `shouldBe` "reaction"
    topology.source `shouldBe` TopologySource {kind = TopologySingleSource, path = "reaction.keiro"}

  it "collects dispatches from reaction arms and accepted follow-ups, once each" $ do
    topology <- inlineTopology "reaction.keiro" reactionSource
    edgeSummaries topology
      `shouldBe` [ ("process", "IncidentReaction", "dispatches", "aggregate", "Incident", [("command", String "EscalateIncident")]),
                   ("process", "IncidentReaction", "saga", "aggregate", "IncidentSaga", [("category", String "incidentSaga")])
                 ]

  it "resolves projections to the aggregate owning the projection table" $ do
    topology <- inlineTopology "projects.keiro" projectsSource
    [summary | summary@(_, _, "projects", _, _, _) <- edgeSummaries topology]
      `shouldBe` [("process", "IncidentReaction", "projects", "aggregate", "Incident", [("table", String "incident_board")])]

  it "emits one edge per operation form" $ do
    topology <- inlineTopology "operations.keiro" operationsSource
    [(fromName, relation, toKind, toName, attributes) | ("operation", fromName, relation, toKind, toName, attributes) <- edgeSummaries topology]
      `shouldBe` [ ("OpenTicket", "commands", "aggregate", "Ticket", []),
                   ("QueryTickets", "queries", "read-model", "ticket_board", []),
                   ("RunTriage", "runs", "workflow", "TicketTriage", []),
                   ("SignalTriage", "signals", "workflow", "TicketTriage", [("label", String "triage-decision")])
                 ]

  it "sorts nodes by kind and name and edges by their identity" $ do
    topology <- inlineTopology "operations.keiro" operationsSource
    let nodeKeys = [(nodeKindText node.kind, node.name) | node <- topology.nodes]
        edgeKeys = [(fromKind, fromName, relation, toKind, toName) | (fromKind, fromName, relation, toKind, toName, _) <- edgeSummaries topology]
    nodeKeys `shouldBe` sort nodeKeys
    edgeKeys `shouldBe` sort edgeKeys

  it "refuses an edge whose endpoint names no node" $ do
    case parseInline "dangling.keiro" danglingSource of
      Left message -> expectationFailure (T.unpack message)
      Right workspace ->
        buildServiceTopology TopologySingleSource "dangling.keiro" workspace [("dangling.keiro", memberDigest "")]
          `shouldSatisfy` \case
            Left (TopologyDanglingEdge _ Dispatches (NodeRef AggregateKind "Missing")) -> True
            _ -> False

  it "refuses a member without a digest" $
    case parseInline "reaction.keiro" reactionSource of
      Left message -> expectationFailure (T.unpack message)
      Right workspace ->
        buildServiceTopology TopologySingleSource "reaction.keiro" workspace []
          `shouldBe` Left (TopologyMissingDigest "reaction.keiro")

  it "encodes canonical bytes followed by exactly one newline" $ do
    topology <- inlineTopology "reaction.keiro" reactionSource
    let bytes = encodeServiceTopology topology
    BS8.last bytes `shouldBe` '\n'
    BS8.count '\n' bytes `shouldBe` 1
    BS.isPrefixOf "{\"edges\":[" bytes `shouldBe` True

--------------------------------------------------------------------------------
-- Milestone 2: the command and golden documents
--------------------------------------------------------------------------------

goldenCases :: [(FilePath, FilePath)]
goldenCases =
  [ ("test/fixtures/topology/hospital-capacity.keiro", "test/fixtures/topology/hospital-capacity.topology.golden.json"),
    ("test/fixtures/topology/incident-command.keiro", "test/fixtures/topology/incident-command.topology.golden.json"),
    ("test/fixtures/topology/workspace/service.keiro-workspace", "test/fixtures/topology/workspace/service.topology.golden.json"),
    ("test/fixtures/topology/projection-catalog.keiro", "test/fixtures/topology/projection-catalog.topology.golden.json")
  ]

commandTests :: Spec
commandTests = do
  forM_ goldenCases $ \(source, golden) ->
    it ("exports " <> takeFileName source <> " byte-for-byte as its golden document") $ do
      (exitCode, stdoutBytes, stderrText) <- runTopology [source, "--format", "json"]
      stderrText `shouldBe` ""
      exitCode `shouldBe` ExitSuccess
      assertMatchesByteGolden golden (withVersionPlaceholder stdoutBytes)

  it "golden documents are closed: unique node identities and resolvable edge endpoints" $
    forM_ goldenCases $ \(_, golden) -> do
      document <- readGolden golden
      let identities = nodeIdentities document
      length identities `shouldBe` Set.size (Set.fromList identities)
      forM_ (edgeObjects document) $ \edgeObject -> do
        endpoint "from" edgeObject `shouldSatisfy` (`elem` identities)
        endpoint "to" edgeObject `shouldSatisfy` (`elem` identities)

  it "hospital-capacity declares every non-catalog node kind" $ do
    document <- readGolden "test/fixtures/topology/hospital-capacity.topology.golden.json"
    let kinds = Set.fromList (map fst (nodeIdentities document))
    forM_ (take 12 (map nodeKindText allNodeKinds)) $ \kind ->
      kinds `shouldSatisfy` Set.member kind

  it "hospital-capacity carries an edge of every relation its declarations support" $ do
    document <- readGolden "test/fixtures/topology/hospital-capacity.topology.golden.json"
    Set.fromList (map relationOf (edgeObjects document))
      `shouldBe` Set.fromList
        [ "dispatches",
          "saga",
          "reads",
          "projects",
          "publishes",
          "subscribes",
          "delivers",
          "enqueues",
          "signals",
          "runs",
          "groups",
          "consumes",
          "writes",
          "member-of",
          "observes"
        ]

  it "the two services publish and subscribe the same physical topics" $ do
    hospital <- readGolden "test/fixtures/topology/hospital-capacity.topology.golden.json"
    incident <- readGolden "test/fixtures/topology/incident-command.topology.golden.json"
    let topics relation document = Set.fromList [topic | edgeObject <- edgeObjects document, relationOf edgeObject == relation, Just (String topic) <- [attribute "topic" edgeObject]]
    topics "publishes" hospital `shouldBe` Set.fromList ["emergency.hospital.events"]
    topics "subscribes" hospital `shouldBe` Set.fromList ["emergency.incident.events"]
    topics "publishes" incident `shouldBe` Set.fromList ["emergency.incident.events"]
    topics "subscribes" incident `shouldBe` Set.fromList ["emergency.hospital.events"]

  it "refuses a source with a validation error and prints nothing on stdout" $ do
    (exitCode, stdoutBytes, stderrText) <- runTopology ["test/fixtures/readmodel-query-unresolved.keiro"]
    exitCode `shouldSatisfy` (/= ExitSuccess)
    stdoutBytes `shouldBe` ""
    stderrText `shouldSatisfy` T.isInfixOf "error["

--------------------------------------------------------------------------------
-- Milestone 3: the projection catalog
--------------------------------------------------------------------------------

catalogTests :: Spec
catalogTests = do
  it "the projection-catalog document carries every catalog kind and relation" $ do
    document <- readGolden "test/fixtures/topology/projection-catalog.topology.golden.json"
    let kinds = Set.fromList (map fst (nodeIdentities document))
        relations = Set.fromList (map relationOf (edgeObjects document))
    forM_ ["projection-target", "rebuild-group", "projection-owner", "projection-revision", "external-read"] $ \kind ->
      kinds `shouldSatisfy` Set.member kind
    forM_ ["depends-on", "groups", "consumes", "writes", "member-of", "revises", "observes", "backed-by", "exposes", "compatible-with"] $ \relation ->
      relations `shouldSatisfy` Set.member relation

  it "traces an aggregate through its projection owner and target to a read model" $ do
    document <- readGolden "test/fixtures/topology/projection-catalog.topology.golden.json"
    let edgesOf relation = [(endpoint "from" e, endpoint "to" e) | e <- edgeObjects document, relationOf e == relation]
        traces =
          [ (aggregate, readModel)
          | (owner, aggregate) <- edgesOf "consumes",
            (owner', target) <- edgesOf "writes",
            owner == owner',
            (readModel, target') <- edgesOf "observes" <> edgesOf "backed-by",
            target == target'
          ]
    traces `shouldSatisfy` elem (("aggregate", "Orders"), ("read-model", "order_inline"))

--------------------------------------------------------------------------------
-- Milestone 4: byte stability
--------------------------------------------------------------------------------

stabilityTests :: Spec
stabilityTests = do
  it "two runs produce identical bytes" $
    forM_ goldenCases $ \(source, _) -> do
      (_, first, _) <- runTopology [source]
      (_, second, _) <- runTopology [source]
      first `shouldBe` second

  it "the output does not depend on the working directory or path spelling" $ do
    source <- resolveTestPath "test/fixtures/topology/hospital-capacity.keiro" >>= makeAbsolute
    (exitAbsolute, fromAbsolute, _) <- runTopologyIn Nothing [source]
    (exitRelative, fromRelative, _) <- runTopologyIn (Just (takeDirectory source)) [takeFileName source]
    exitAbsolute `shouldBe` ExitSuccess
    exitRelative `shouldBe` ExitSuccess
    fromAbsolute `shouldBe` fromRelative

  it "reordering top-level declarations changes only member digests and node lines" $ do
    source <- resolveTestPath "test/fixtures/topology/hospital-capacity.keiro"
    original <- BS.readFile source
    let reordered = reverseNodeDeclarations original
    reordered `shouldNotBe` original
    withTempDirectory "keiro-dsl-topology-reorder" $ \directory -> do
      let copy = directory </> takeFileName source
      BS.writeFile copy reordered
      (exitOriginal, fromOriginal, _) <- runTopology [source]
      (exitReordered, fromReordered, stderrReordered) <- runTopology [copy]
      exitOriginal `shouldBe` ExitSuccess
      stderrReordered `shouldBe` ""
      exitReordered `shouldBe` ExitSuccess
      fromReordered `shouldNotBe` fromOriginal
      fmap withoutPositions (decodeDocument fromReordered) `shouldBe` fmap withoutPositions (decodeDocument fromOriginal)

-- | Reverse the order of top-level node declarations, keeping the preamble
-- (language, context, layout, ids and enums) in place. Only whole
-- declarations move; nothing inside one is reordered.
reverseNodeDeclarations :: BS.ByteString -> BS.ByteString
reverseNodeDeclarations bytes =
  BS8.unlines (preamble <> concatMap terminate (reverse blocks))
  where
    sourceLines = BS8.lines bytes
    (preamble, rest) = break startsNode sourceLines
    blocks = splitBlocks rest
    splitBlocks [] = []
    splitBlocks (header : remaining) =
      let (body, next) = break startsNode remaining
       in (header : body) : splitBlocks next
    terminate block = reverse (dropWhile (BS8.all isSpace) (reverse block)) <> [""]
    startsNode line = any (\keyword -> (keyword <> " ") `BS.isPrefixOf` line) nodeKeywords
    nodeKeywords =
      [ "aggregate",
        "process",
        "router",
        "workflow",
        "operation",
        "contract",
        "intake",
        "emit",
        "publisher",
        "workqueue",
        "dispatch",
        "readmodel",
        "target",
        "rebuild-group",
        "projection-owner",
        "projection-revision",
        "external-read"
      ]

withoutPositions :: Value -> Value
withoutPositions = \case
  Object document -> Object (KeyMap.mapWithKey strip document)
  other -> other
  where
    strip key value = case (Key.toText key, value) of
      ("members", Array members) -> Array (fmap (dropField "sha256") members)
      ("nodes", Array nodes) -> Array (fmap (dropField "line") nodes)
      _ -> value
    dropField name = \case
      Object fields -> Object (KeyMap.delete (Key.fromText name) fields)
      other -> other

--------------------------------------------------------------------------------
-- Inline sources
--------------------------------------------------------------------------------

reactionSource :: Text
reactionSource =
  T.unlines
    [ "language keiro-dsl 6",
      "context topology-reaction",
      "",
      "id IncidentId prefix=inc",
      "",
      "process IncidentReaction",
      "  name \"incident-reaction\"",
      "  reactions version 1",
      "  input IncidentReported { incidentId:IncidentId }",
      "  correlate input.incidentId via idText",
      "  saga IncidentSaga category \"incidentSaga\"",
      "  target Incident",
      "  projections [ ]",
      "  on IncidentReported",
      "    advance RecordIncident { incidentId }",
      "      accepted",
      "        dispatch Incident@input.incidentId EscalateIncident { incidentId }",
      "          on-appended AckOk ; on-duplicate AckOk ; on-failed Retry",
      "      silent no-action",
      "  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, targetStreamName, occurrence)",
      "  rejected => halt",
      "  poison => halt",
      "",
      "aggregate IncidentSaga",
      "  regs",
      "  states Open",
      "  command RecordIncident { incidentId }",
      "  event IncidentRecorded = fields(RecordIncident)",
      "  Open -- RecordIncident --> emit IncidentRecorded ; goto Open",
      "",
      "aggregate Incident",
      "  regs",
      "  states Open",
      "  command EscalateIncident { incidentId }",
      "  event IncidentEscalated = fields(EscalateIncident)",
      "  Open -- EscalateIncident --> emit IncidentEscalated ; goto Open"
    ]

projectsSource :: Text
projectsSource =
  T.replace
    "  projections [ ]"
    "  projections [ incident_board ]"
    ( T.replace
        "  Open -- EscalateIncident --> emit IncidentEscalated ; goto Open"
        "  Open -- EscalateIncident --> emit IncidentEscalated ; goto Open\n  projection incident_board key=incidentId"
        reactionSource
    )

danglingSource :: Text
danglingSource =
  T.replace "dispatch Incident@input.incidentId" "dispatch Missing@input.incidentId" reactionSource

operationsSource :: Text
operationsSource =
  T.unlines
    [ "language keiro-dsl 6",
      "context topology-operations",
      "",
      "id TicketId prefix=tkt",
      "",
      "readmodel ticket_board {",
      "  table = \"ticket_board\"",
      "  schema = \"tickets\"",
      "  columns {",
      "    ticket_id text required",
      "  }",
      "  version = 1",
      "  shape = \"fnv1a:0000000000000000\"",
      "  freshness = immediate",
      "}",
      "",
      "aggregate Ticket",
      "  regs",
      "  states Open",
      "  command OpenTicketCommand { ticketId }",
      "  event TicketOpened = fields(OpenTicketCommand)",
      "  Open -- OpenTicketCommand --> emit TicketOpened ; goto Open",
      "",
      "workflow TicketTriage",
      "  name \"ticket-triage\"",
      "  in TriageInput { ticketId:Id }",
      "  out TriageSummary",
      "  id from input.ticketId via idText",
      "  body",
      "    await triage-decision -> TriageDecision",
      "",
      "operation OpenTicket",
      "  command on Ticket",
      "    stream from ticketId via ticketStream",
      "    project [ ticket_board ]",
      "",
      "operation QueryTickets",
      "  query ticket_board",
      "    input TicketId",
      "    result Maybe TicketRow",
      "",
      "operation SignalTriage",
      "  signal triage-decision of TicketTriage",
      "    key from ticketId via triageWorkflowId",
      "    value TriageDecision",
      "",
      "operation RunTriage",
      "  run TicketTriage",
      "    input TriageInput",
      "    outcome -> TriageRun"
    ]

parseInline :: FilePath -> Text -> Either Text WorkspaceSpec
parseInline path source = case parseSourceDocument path source of
  Left failure -> Left (renderParseFailure failure)
  Right document -> either (Left . T.pack . show) Right (oneMemberParsedDocumentWorkspace path document)

inlineTopology :: FilePath -> Text -> IO ServiceTopology
inlineTopology path source = case parseInline path source of
  Left message -> fail (T.unpack message)
  Right workspace ->
    case buildServiceTopology TopologySingleSource path workspace [(path, memberDigest (TE.encodeUtf8 source))] of
      Left topologyError -> fail (T.unpack (renderTopologyError topologyError))
      Right topology -> pure topology

edgeSummaries :: ServiceTopology -> [(Text, Text, Text, Text, Text, [(Text, Value)])]
edgeSummaries topology =
  [ ( nodeKindText topologyEdge.from.kind,
      topologyEdge.from.name,
      relationText topologyEdge.relation,
      nodeKindText topologyEdge.to.kind,
      topologyEdge.to.name,
      [(Key.toText key, value) | (key, value) <- KeyMap.toList topologyEdge.attributes]
    )
  | topologyEdge <- topology.edges
  ]

--------------------------------------------------------------------------------
-- Decoded documents
--------------------------------------------------------------------------------

decodeDocument :: BS.ByteString -> Maybe Value
decodeDocument = Aeson.decodeStrict

readGolden :: FilePath -> IO Value
readGolden path = do
  resolved <- resolveTestPath path
  bytes <- BS.readFile resolved
  maybe (fail ("golden is not JSON: " <> path)) pure (decodeDocument bytes)

field :: Text -> Value -> Maybe Value
field name = \case
  Object fields -> KeyMap.lookup (Key.fromText name) fields
  _ -> Nothing

textField :: Text -> Value -> Text
textField name value = case field name value of
  Just (String text) -> text
  _ -> ""

listField :: Text -> Value -> [Value]
listField name value = case field name value of
  Just (Array values) -> toList values
  _ -> []

nodeIdentities :: Value -> [(Text, Text)]
nodeIdentities document = [(textField "kind" node, textField "name" node) | node <- listField "nodes" document]

edgeObjects :: Value -> [Value]
edgeObjects = listField "edges"

endpoint :: Text -> Value -> (Text, Text)
endpoint side edgeObject = case field side edgeObject of
  Just ref -> (textField "kind" ref, textField "name" ref)
  Nothing -> ("", "")

relationOf :: Value -> Text
relationOf = textField "relation"

attribute :: Text -> Value -> Maybe Value
attribute name edgeObject = field "attributes" edgeObject >>= field name

--------------------------------------------------------------------------------
-- Running the executable
--------------------------------------------------------------------------------

runTopology :: [FilePath] -> IO (ExitCode, BS.ByteString, Text)
runTopology = runTopologyIn Nothing

-- | Run @keiro-dsl topology@ with the raw stdout bytes. Fixture arguments are
-- resolved against the package or repository root unless a working directory
-- is given.
runTopologyIn :: Maybe FilePath -> [FilePath] -> IO (ExitCode, BS.ByteString, Text)
runTopologyIn workingDirectory arguments = do
  resolved <- case workingDirectory of
    Just _ -> pure arguments
    Nothing -> traverse resolveArgument arguments
  (exitCode, stdoutText, stderrText) <-
    readCreateProcessWithExitCode ((proc "keiro-dsl" ("topology" : resolved)) {cwd = workingDirectory}) ""
  pure (exitCode, TE.encodeUtf8 (T.pack stdoutText), T.pack stderrText)
  where
    resolveArgument argument
      | "test/fixtures/" `isPrefixOf` argument = resolveTestPath argument
      | otherwise = pure argument

-- | The generator version changes on every release; goldens store a
-- placeholder so a version bump does not rewrite every document.
withVersionPlaceholder :: BS.ByteString -> BS.ByteString
withVersionPlaceholder bytes =
  let (prefix, suffix) = BS.breakSubstring needle bytes
   in if BS.null suffix then bytes else prefix <> placeholder <> BS.drop (BS.length needle) suffix
  where
    needle = "\"generator\":{\"tool\":\"keiro-dsl\",\"version\":\"" <> BS8.pack (showVersion Package.version) <> "\"}"
    placeholder = "\"generator\":{\"tool\":\"keiro-dsl\",\"version\":\"<version>\"}"

assertMatchesByteGolden :: FilePath -> BS.ByteString -> IO ()
assertMatchesByteGolden path actual = do
  update <- lookupEnv "KEIRO_DSL_UPDATE_GOLDENS"
  if update == Just "1"
    then do
      resolved <- resolveGoldenWritePath path
      BS.writeFile resolved actual
    else do
      resolved <- resolveTestPath path
      BS.readFile resolved >>= (`shouldBe` actual)

-- | Where a golden should be written when it may not exist yet: beside the
-- fixture directory that does exist.
resolveGoldenWritePath :: FilePath -> IO FilePath
resolveGoldenWritePath path = do
  existing <- filterM doesFileExist [path, "keiro-dsl" </> path]
  case existing of
    found : _ -> pure found
    [] -> do
      fixtureDirectories <- filterM (doesFileExist . (</> "hospital-capacity.keiro")) ["test/fixtures/topology", "keiro-dsl/test/fixtures/topology"]
      case fixtureDirectories of
        directory : _ -> pure (takeDirectory directory </> dropPrefix "test/fixtures/" path)
        [] -> fail ("cannot locate the topology fixture directory for " <> path)
  where
    dropPrefix prefix value = if prefix `isPrefixOf` value then drop (length prefix) value else value

-- | Locate a repo file regardless of the test process's current directory.
resolveTestPath :: FilePath -> IO FilePath
resolveTestPath rel = do
  override <- lookupEnv "KEIRO_DSL_TEST_ROOT"
  let candidates = [rel, "keiro-dsl" </> rel] <> maybe [] (\root -> [root </> rel]) override
  existing <- filterM doesFileExist candidates
  case existing of
    path : _ -> pure path
    [] -> fail ("unable to locate keiro-dsl test file " <> show rel <> "; tried " <> show candidates)

withTempDirectory :: String -> (FilePath -> IO a) -> IO a
withTempDirectory template = bracket acquire removePathForcibly
  where
    acquire = do
      base <- getTemporaryDirectory
      (path, handle) <- openTempFile base template
      hClose handle
      removeFile path
      createDirectory path
      pure path
