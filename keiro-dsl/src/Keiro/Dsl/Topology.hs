-- | The versioned service topology document (@keiro-dsl/service-topology/1@,
-- or @/2@ for a service that declares an input source).
--
-- A topology is computed from a checked service alone. It lists every
-- declaration of the exported node kinds and every relation between them, plus
-- a sha256 digest of each source member so a reader can tell when a committed
-- copy is older than its sources.
--
-- Compatibility policy: within one schema id keiro may add object fields and
-- consumers must ignore fields they do not know. A new node kind, a new
-- relation, or a change in the meaning of an existing field requires a new
-- schema id.
--
-- Encoding rules. Nodes are sorted by (@kind@, @name@); edges by
-- (@from.kind@, @from.name@, @relation@, @to.kind@, @to.name@, canonical bytes
-- of @attributes@); identical edges are emitted once; members are sorted by
-- path. Lists inside @details@ keep declaration order. Enumerations are spelled
-- as the specification language spells them (the pretty printer in
-- "Keiro.Dsl.PrettyPrint" is the reference). The document is written with the
-- RFC 8785 JSON canonicalization scheme and followed by exactly one newline.
module Keiro.Dsl.Topology
  ( -- * The document
    ServiceTopology (..),
    TopologySource (..),
    TopologySourceKind (..),
    TopologyMember (..),
    TopologyNode (..),
    TopologyEdge (..),
    NodeRef (..),
    NodeKind (..),
    Relation (..),
    allNodeKinds,
    allRelations,
    nodeKindText,
    relationText,
    topologySchemaId,

    -- * Aggregate machines
    MachineTopology (..),
    MachineOwnership (..),
    MachineState (..),
    MachineEdge (..),
    MachineEdgeMode (..),
    aggregateMachine,
    machineValue,

    -- * Building and encoding
    TopologyError (..),
    renderTopologyError,
    buildServiceTopology,
    memberDigest,
    serviceTopologyValue,
    encodeServiceTopology,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.RFC8785 qualified as RFC8785
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (showVersion)
import Keiro.Dsl.AggregateGenerationPlan (TransitionLayoutEntry (..), transitionLayout)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (declaredLanguageVersionMaybe, effectiveLanguageVersion, languageVersionNumber)
import Keiro.Dsl.SemanticContract (EffectiveLanguageContract)
import Keiro.Dsl.Validate (nodeIdentity)
import Keiro.Dsl.Workspace (WorkspaceMember (..), WorkspaceSpec (..), nodeOwner)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Paths_keiro_dsl qualified as Package
import System.FilePath (takeFileName)

-- | The closed set of exported node kinds.
data NodeKind
  = AggregateKind
  | ProcessKind
  | WorkflowKind
  | RouterKind
  | ContractKind
  | IntakeKind
  | EmitKind
  | PublisherKind
  | WorkqueueKind
  | DispatchKind
  | ReadModelKind
  | OperationKind
  | ProjectionTargetKind
  | RebuildGroupKind
  | ProjectionOwnerKind
  | ProjectionRevisionKind
  | ExternalReadKind
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The closed set of relations an edge may carry.
data Relation
  = Dispatches
  | Saga
  | Reads
  | Projects
  | Publishes
  | Subscribes
  | Delivers
  | Enqueues
  | Commands
  | Queries
  | Signals
  | Runs
  | DependsOn
  | Groups
  | Consumes
  | Writes
  | MemberOf
  | Revises
  | Observes
  | BackedBy
  | Exposes
  | CompatibleWith
  | -- | Schema id @/2@ only: an intake feeds a process or router input.
    Feeds
  deriving stock (Eq, Ord, Show, Enum, Bounded)

allNodeKinds :: [NodeKind]
allNodeKinds = [minBound .. maxBound]

allRelations :: [Relation]
allRelations = [minBound .. maxBound]

nodeKindText :: NodeKind -> Text
nodeKindText = \case
  AggregateKind -> "aggregate"
  ProcessKind -> "process"
  WorkflowKind -> "workflow"
  RouterKind -> "router"
  ContractKind -> "contract"
  IntakeKind -> "intake"
  EmitKind -> "emit"
  PublisherKind -> "publisher"
  WorkqueueKind -> "workqueue"
  DispatchKind -> "dispatch"
  ReadModelKind -> "read-model"
  OperationKind -> "operation"
  ProjectionTargetKind -> "projection-target"
  RebuildGroupKind -> "rebuild-group"
  ProjectionOwnerKind -> "projection-owner"
  ProjectionRevisionKind -> "projection-revision"
  ExternalReadKind -> "external-read"

relationText :: Relation -> Text
relationText = \case
  Dispatches -> "dispatches"
  Saga -> "saga"
  Reads -> "reads"
  Projects -> "projects"
  Publishes -> "publishes"
  Subscribes -> "subscribes"
  Delivers -> "delivers"
  Enqueues -> "enqueues"
  Commands -> "commands"
  Queries -> "queries"
  Signals -> "signals"
  Runs -> "runs"
  DependsOn -> "depends-on"
  Groups -> "groups"
  Consumes -> "consumes"
  Writes -> "writes"
  MemberOf -> "member-of"
  Revises -> "revises"
  Observes -> "observes"
  BackedBy -> "backed-by"
  Exposes -> "exposes"
  CompatibleWith -> "compatible-with"
  Feeds -> "feeds"

-- | Whether keiro generates the aggregate's keiki transducer from the
-- specification ('MachineGenerated', including per-transition Hole bodies,
-- whose edges are still generated) or the frozen Language 1 form leaves the
-- whole transducer hand-written ('MachineLegacyHole').
data MachineOwnership = MachineGenerated | MachineLegacyHole
  deriving stock (Eq, Show)

data MachineState = MachineState
  { name :: !Text,
    terminal :: !Bool
  }
  deriving stock (Eq, Show)

-- | Spelled as keiki's 'Keiki.Core.EdgeMode' constructors.
data MachineEdgeMode = MachineLive | MachineReplayOnly
  deriving stock (Eq, Show)

-- | One keiki edge. Its identity is (@source@, @edgeIndex@): the position of
-- the edge in keiki's @edgesOut source@. The index is local to one source
-- state and changes when transitions are reordered.
data MachineEdge = MachineEdge
  { source :: !Text,
    edgeIndex :: !Int,
    target :: !Text,
    mode :: !MachineEdgeMode,
    command :: !Text,
    events :: ![Text]
  }
  deriving stock (Eq, Show)

-- | An aggregate's state machine in keiki vocabulary. States are in
-- declaration order (the generated vertex type's constructor order); edges are
-- ordered by their source state's position, then by edge index.
data MachineTopology = MachineTopology
  { ownership :: !MachineOwnership,
    initial :: !Text,
    states :: ![MachineState],
    edges :: ![MachineEdge]
  }
  deriving stock (Eq, Show)

-- | The machine the specification declares. The conformance suite
-- @keiro-dsl-conformance-topology-machine@ proves it equal to the generated
-- keiki transducer for generated machines.
aggregateMachine :: Aggregate -> MachineTopology
aggregateMachine aggregate =
  MachineTopology
    { ownership =
        if any ((== LegacyHoleImplementation) . (.implementation)) aggregate.transitions
          then MachineLegacyHole
          else MachineGenerated,
      initial = case aggregate.states of
        first : _ -> first.name
        [] -> "",
      states = [MachineState {name = state.name, terminal = state.terminal} | state <- aggregate.states],
      edges =
        [ MachineEdge
            { source = entry.transition.source,
              edgeIndex = entry.outgoingIndex,
              target = entry.transition.goto,
              mode = case entry.transition.mode of
                TmLive -> MachineLive
                TmReplayOnly -> MachineReplayOnly,
              command = entry.transition.command,
              events = entry.transition.emits
            }
        | state <- aggregate.states,
          entry <- layout,
          entry.transition.source == state.name
        ]
    }
  where
    layout = transitionLayout aggregate.transitions

machineValue :: MachineTopology -> Value
machineValue machine =
  object
    [ "ownership" .= (case machine.ownership of MachineGenerated -> "generated" :: Text; MachineLegacyHole -> "legacy-hole"),
      "initial" .= machine.initial,
      "states" .= [object ["name" .= state.name, "terminal" .= state.terminal] | state <- machine.states],
      "edges"
        .= [ object
               [ "source" .= machineEdge.source,
                 "edgeIndex" .= machineEdge.edgeIndex,
                 "target" .= machineEdge.target,
                 "mode" .= (case machineEdge.mode of MachineLive -> "Live" :: Text; MachineReplayOnly -> "ReplayOnly"),
                 "command" .= machineEdge.command,
                 "events" .= machineEdge.events
               ]
           | machineEdge <- machine.edges
           ]
    ]

-- | Whether the document came from one source file or a workspace manifest.
data TopologySourceKind = TopologySingleSource | TopologyWorkspace
  deriving stock (Eq, Show)

data TopologySource = TopologySource
  { kind :: !TopologySourceKind,
    -- | The file name of the source or manifest, never a directory path.
    path :: !FilePath
  }
  deriving stock (Eq, Show)

data TopologyMember = TopologyMember
  { -- | Relative to the manifest directory, forward slashes.
    path :: !FilePath,
    -- | @sha256:@ followed by the lowercase hex digest of the file's bytes.
    sha256 :: !Text,
    declaredLanguageVersion :: !(Maybe Natural),
    effectiveLanguageVersion :: !Natural
  }
  deriving stock (Eq, Show)

data NodeRef = NodeRef
  { kind :: !NodeKind,
    name :: !Name
  }
  deriving stock (Eq, Ord, Show)

data TopologyNode = TopologyNode
  { kind :: !NodeKind,
    name :: !Name,
    context :: !Name,
    member :: !FilePath,
    line :: !Int,
    -- | A JSON object whose fields depend on the kind.
    details :: !Aeson.Object
  }
  deriving stock (Eq, Show)

data TopologyEdge = TopologyEdge
  { from :: !NodeRef,
    to :: !NodeRef,
    relation :: !Relation,
    attributes :: !Aeson.Object
  }
  deriving stock (Eq, Show)

data ServiceTopology = ServiceTopology
  { service :: !Text,
    source :: !TopologySource,
    languageContract :: !EffectiveLanguageContract,
    generatorVersion :: !Text,
    members :: ![TopologyMember],
    nodes :: ![TopologyNode],
    edges :: ![TopologyEdge]
  }
  deriving stock (Eq, Show)

-- | The schema id a document is emitted under: the lowest id able to represent
-- it. A document with a @feeds@ edge needs @/2@; every other document is @/1@,
-- byte-for-byte what it was before @/2@ existed.
topologySchemaId :: ServiceTopology -> Text
topologySchemaId topology
  | any ((== Feeds) . (.relation)) topology.edges = "keiro-dsl/service-topology/2"
  | otherwise = "keiro-dsl/service-topology/1"

-- | An internal inconsistency. A checked service never produces one.
data TopologyError
  = TopologyDuplicateNode !NodeRef
  | TopologyDanglingEdge !NodeRef !Relation !NodeRef
  | TopologyMissingOwner !Text !Name
  | TopologyMissingDigest !FilePath
  deriving stock (Eq, Show)

renderTopologyError :: TopologyError -> Text
renderTopologyError = \case
  TopologyDuplicateNode ref ->
    "internal error: topology node " <> renderRef ref <> " is declared more than once"
  TopologyDanglingEdge fromRef relation toRef ->
    "internal error: topology edge "
      <> renderRef fromRef
      <> " -"
      <> relationText relation
      <> "-> "
      <> renderRef toRef
      <> " names no node in the document"
  TopologyMissingOwner kind name ->
    "internal error: no workspace member owns " <> kind <> " '" <> name <> "'"
  TopologyMissingDigest path ->
    "internal error: no digest was supplied for member " <> T.pack path
  where
    renderRef ref = nodeKindText ref.kind <> " '" <> ref.name <> "'"

-- | @sha256:<lowercase hex>@ of a member file's exact bytes.
memberDigest :: ByteString -> Text
memberDigest bytes = "sha256:" <> T.pack (concatMap twoHex (ByteString.unpack (SHA256.hash bytes)))
  where
    twoHex byte = case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits

-- | Build the document. The 'FilePath' is the source or manifest path as given;
-- only its file name is recorded. The list pairs each member path with its
-- digest. Fails only on an internal inconsistency (duplicate node identity, a
-- dangling edge endpoint, or a member without an owner or digest).
buildServiceTopology ::
  TopologySourceKind ->
  FilePath ->
  WorkspaceSpec ->
  [(FilePath, Text)] ->
  Either TopologyError ServiceTopology
buildServiceTopology sourceKind sourcePath workspace digests = do
  members <- traverse topologyMember workspace.members
  nodes <- traverse (topologyNode workspace spec) spec.nodes
  let sortedNodes = sortOn nodeSortKey nodes
      nodeRefs = Set.fromList [NodeRef node.kind node.name | node <- nodes]
  case duplicates [NodeRef node.kind node.name | node <- nodes] of
    ref : _ -> Left (TopologyDuplicateNode ref)
    [] -> pure ()
  let edgeList = sortOn edgeSortKey (nub (concatMap (nodeEdges spec) spec.nodes))
  case [candidate | candidate <- edgeList, not (Set.member candidate.from nodeRefs && Set.member candidate.to nodeRefs)] of
    dangling : _ -> Left (TopologyDanglingEdge dangling.from dangling.relation dangling.to)
    [] -> pure ()
  pure
    ServiceTopology
      { service = workspace.service,
        source = TopologySource {kind = sourceKind, path = takeFileName sourcePath},
        languageContract = workspace.languageContract,
        generatorVersion = T.pack (showVersion Package.version),
        members = sortOn (.path) members,
        nodes = sortedNodes,
        edges = edgeList
      }
  where
    spec = workspace.mergedSpec
    digestMap = Map.fromList digests
    topologyMember member = case Map.lookup member.path digestMap of
      Nothing -> Left (TopologyMissingDigest member.path)
      Just digest ->
        Right
          TopologyMember
            { path = member.path,
              sha256 = digest,
              declaredLanguageVersion = fmap languageVersionNumber (declaredLanguageVersionMaybe member.sourceLanguage),
              effectiveLanguageVersion = languageVersionNumber (effectiveLanguageVersion member.sourceLanguage)
            }
    -- Sort keys use the spelled kind and relation, so the order a reader sees
    -- in the document is the plain codepoint order of its own strings.
    nodeSortKey node = (nodeKindText node.kind, node.name)
    edgeSortKey topologyEdge =
      ( nodeKindText topologyEdge.from.kind,
        topologyEdge.from.name,
        relationText topologyEdge.relation,
        nodeKindText topologyEdge.to.kind,
        topologyEdge.to.name,
        canonicalBytes (Object topologyEdge.attributes)
      )

duplicates :: (Ord a) => [a] -> [a]
duplicates values = [value | (value, count) <- Map.toList (Map.fromListWith (+) [(value, 1 :: Int) | value <- values]), count > 1]

--------------------------------------------------------------------------------
-- Nodes
--------------------------------------------------------------------------------

topologyNode :: WorkspaceSpec -> Spec -> Node -> Either TopologyError TopologyNode
topologyNode workspace spec node = do
  let (ownerKind, ownerName, _) = nodeIdentity node
  (memberPath, Loc lineNumber) <-
    maybe (Left (TopologyMissingOwner ownerKind ownerName)) Right (nodeOwner workspace.ownership ownerKind ownerName)
  let (kind, name, details) = nodeSummary spec node
  pure
    TopologyNode
      { kind = kind,
        name = name,
        context = workspace.context,
        member = memberPath,
        line = lineNumber,
        details = details
      }

fields :: [(Text, Value)] -> Aeson.Object
fields = KeyMap.fromList . map (\(key, value) -> (Key.fromText key, value))

nullableText :: Text -> Value
nullableText value
  | T.null value = Null
  | otherwise = String value

names :: [Name] -> Value
names = Aeson.toJSON

nodeSummary :: Spec -> Node -> (NodeKind, Name, Aeson.Object)
nodeSummary spec = \case
  NAggregate aggregate ->
    ( AggregateKind,
      aggregate.name,
      fields
        [ ("states", names (map (.name) aggregate.states)),
          ("commands", names (map (.name) aggregate.commands)),
          ("events", names (map (.name) aggregate.events)),
          ("machine", machineValue (aggregateMachine aggregate))
        ]
    )
  NProcess process ->
    ( ProcessKind,
      process.id,
      fields
        [ ("stableName", String process.name),
          ("saga", object ["aggregate" .= process.saga.agg, "category" .= process.saga.category]),
          ("correlate", object ["field" .= process.correlate.field, "via" .= process.correlate.via]),
          ("inputs", names (processInputs process.body)),
          ("target", String process.target),
          ("projections", names process.projections),
          ("timers", names (processTimers process.body)),
          ("rejected", String (policyText process.rejected)),
          ("poison", String (policyText process.poison))
        ]
    )
  NWorkflow workflow ->
    ( WorkflowKind,
      workflow.id,
      fields
        [ ("stableName", String workflow.stable),
          ("input", String workflow.input),
          ("output", String workflow.output),
          ("steps", Aeson.toJSON (concatMap workflowSteps workflow.body))
        ]
    )
  NRouter router ->
    ( RouterKind,
      router.id,
      fields
        [ ("stableName", String router.name),
          ("input", String router.input.name),
          ("target", String router.target),
          ("resolvesFrom", maybe Null String (routerReadModel router)),
          ("projections", names router.projections)
        ]
    )
  NContract contract ->
    ( ContractKind,
      contract.name,
      fields
        [ ("schemaVersion", Aeson.toJSON contract.schemaVersion),
          ("discriminator", String contract.discriminator),
          ("topics", Aeson.toJSON [object ["alias" .= alias, "topic" .= topic] | (alias, topic) <- contract.topics]),
          ("events", names (map (.name) contract.events))
        ]
    )
  NIntake intake ->
    ( IntakeKind,
      intake.name,
      fields
        [ ("contract", String intake.contract),
          ("topicAlias", String intake.topic),
          ("topic", maybe Null String (contractTopic spec intake.contract intake.topic)),
          ("accepts", names intake.accept),
          ("dedupe", object ["key" .= intake.dedupeKey, "policy" .= intake.dedupePolicy]),
          ("idempotence", String (case intake.idempotence of IdemInboxTable -> "inbox-table"; IdemDelegated -> "delegated"))
        ]
    )
  NEmit emit ->
    ( EmitKind,
      emit.name,
      fields
        [ ("contract", String emit.contract),
          ("topicAlias", String emit.topic),
          ("topic", maybe Null String (contractTopic spec emit.contract emit.topic)),
          ("source", String emit.source),
          ("key", String emit.key),
          ("events", names (emitEvents emit))
        ]
    )
  NPublisher publisher ->
    ( PublisherKind,
      publisher.name,
      fields
        [ ("emit", String publisher.emit),
          ("ordering", String publisher.ordering),
          ("maxAttempts", Aeson.toJSON publisher.maxAttempts),
          ( "backoff",
            object
              [ "kind" .= publisher.backoff.kind,
                "window" .= publisher.backoff.window,
                "max" .= publisher.backoff.max,
                "multiplier" .= publisher.backoff.multiplier
              ]
          ),
          ("outboxField", String publisher.outboxField)
        ]
    )
  NWorkqueue queue ->
    ( WorkqueueKind,
      queue.name,
      fields
        [ ("logical", String queue.logical),
          ("physical", String queue.physical),
          ("dlq", String queue.dlq),
          ("table", String queue.table),
          ("ordering", String (orderingText queue.ordering)),
          ("maxRetries", Aeson.toJSON queue.maxRetries),
          ("dlqOn", Bool queue.dlqOn)
        ]
    )
  NPgmqDispatch dispatch ->
    ( DispatchKind,
      dispatch.name,
      fields
        [ ("sourceReadModel", String dispatch.sourceReadModel),
          ("enqueueTo", String dispatch.enqueueTo)
        ]
    )
  NReadModel readModel ->
    ( ReadModelKind,
      readModel.name,
      fields
        [ ("table", nullableText readModel.table),
          ("schema", nullableText readModel.schema),
          ("version", Aeson.toJSON readModel.version),
          ("group", maybe Null String readModel.group),
          ("observedTargets", names readModel.observedTargets),
          ("backingTarget", maybe Null String readModel.backingTarget)
        ]
    )
  NOperation operation ->
    ( OperationKind,
      operation.name,
      fields $ case operation.shape of
        CommandOp aggregate _ _ _ -> [("form", String "command"), ("subject", String aggregate)]
        QueryOp readModel _ _ _ -> [("form", String "query"), ("subject", String readModel)]
        SignalOp label workflow _ _ _ -> [("form", String "signal"), ("subject", String workflow), ("label", String label)]
        RunOp workflow _ _ -> [("form", String "run"), ("subject", String workflow)]
    )
  NProjectionTarget target ->
    ( ProjectionTargetKind,
      target.name,
      fields
        [ ("schema", String target.schema),
          ("table", String target.table),
          ("reset", String (case target.reset of TargetClear -> "clear"; TargetPreserve -> "preserve")),
          ("dependsOn", names target.dependsOn)
        ]
    )
  NRebuildGroup groupNode ->
    ( RebuildGroupKind,
      groupNode.name,
      fields
        [ ("targets", names groupNode.targets),
          ("order", names groupNode.order)
        ]
    )
  NProjectionOwner owner ->
    ( ProjectionOwnerKind,
      owner.name,
      fields
        [ ("sources", Aeson.toJSON (map catalogSourceValue owner.sources)),
          ("delivery", String (case owner.delivery of DeliveryInline -> "inline"; DeliverySubscription -> "subscription")),
          ("group", String owner.group),
          ("targets", names owner.targets),
          ("order", Aeson.toJSON owner.order),
          ("subscription", maybe Null String owner.subscription),
          ("dedup", maybe Null String owner.dedup),
          ( "replay",
            case owner.replay of
              ProjectionReplayExplicit -> object ["mode" .= ("explicit" :: Text), "reason" .= Null]
              ProjectionLiveOnly reason -> object ["mode" .= ("live-only" :: Text), "reason" .= reason]
          )
        ]
    )
  NProjectionRevision revision ->
    ( ProjectionRevisionKind,
      revision.name,
      fields
        [ ("group", String revision.group),
          ( "targets",
            Aeson.toJSON
              [ object ["target" .= revisionTarget.target, "schemaVersion" .= revisionTarget.schemaVersion]
              | revisionTarget <- revision.targets
              ]
          )
        ]
    )
  NExternalRead externalRead ->
    ( ExternalReadKind,
      externalReadNodeIdentity externalRead,
      fields
        [ ("contract", String externalRead.name),
          ("version", Aeson.toJSON externalRead.version),
          ("queryModel", String externalRead.queryModel),
          ("resultSchema", String externalRead.resultSchema),
          ("resultType", String externalRead.resultType),
          ("compatibleRevisions", names externalRead.compatibleRevisions),
          ("surfaceGeneration", Aeson.toJSON externalRead.surfaceGeneration)
        ]
    )

-- | The physical topic a contract assigns to an alias.
contractTopic :: Spec -> Name -> Name -> Maybe Text
contractTopic spec contractName alias =
  case [contract | NContract contract <- spec.nodes, contract.name == contractName] of
    contract : _ -> lookup alias contract.topics
    [] -> Nothing

catalogSourceValue :: CatalogSource -> Value
catalogSourceValue = \case
  CatalogAggregate name -> object ["kind" .= ("aggregate" :: Text), "name" .= name]
  CatalogCategory name -> object ["kind" .= ("category" :: Text), "name" .= name]
  CatalogAll -> object ["kind" .= ("all" :: Text)]

policyText :: PolicyChoice -> Text
policyText = \case
  PolHalt -> "halt"
  PolDeadLetter -> "deadLetter"
  PolSkip -> "skip"

orderingText :: WqOrdering -> Text
orderingText = \case
  WqUnordered -> "unordered"
  WqFifoThroughput -> "fifo-throughput"
  WqFifoRoundRobin -> "fifo-roundrobin"
  WqFifoHeads -> "fifo-heads"

processInputs :: ProcessBody -> [Name]
processInputs = map (.name) . processBodyInputs

processBodyInputs :: ProcessBody -> [InputDecl]
processBodyInputs = \case
  LegacyProcessBody input _ _ -> [input]
  ReactionProcessBody body -> NE.toList body.inputs

processTimers :: ProcessBody -> [Name]
processTimers = \case
  LegacyProcessBody _ _ timer -> [timer.name]
  ReactionProcessBody body -> map (.name) body.timers

workflowSteps :: WfBodyItem -> [Value]
workflowSteps = \case
  WfStep label _ _ -> [step "step" (Just label)]
  WfAwait label _ _ -> [step "await" (Just label)]
  WfSleep label _ _ -> [step "sleep" (Just label)]
  WfChild label _ _ _ -> [step "child" (Just label)]
  WfPatch patchId items _ -> step "patch" (Just patchId) : concatMap workflowSteps items
  WfContinueAsNew _ _ -> [step "continue-as-new" Nothing]
  where
    step :: Text -> Maybe Name -> Value
    step form label = object (("form" .= form) : maybe [] (\value -> ["label" .= value]) label)

-- | The read model a router resolves from, when it resolves from one.
routerReadModel :: RouterNode -> Maybe Name
routerReadModel router = case router.resolve.source of
  ResolveReadModel name -> Just name
  ResolveDeclarative selection -> Just selection.query
  ResolveHole -> Nothing

emitEvents :: EmitNode -> [Name]
emitEvents emit = nub (map (.event) emit.map)

--------------------------------------------------------------------------------
-- Edges
--------------------------------------------------------------------------------

mkEdge :: NodeKind -> Name -> Relation -> NodeKind -> Name -> [(Text, Value)] -> TopologyEdge
mkEdge fromKind fromName relation toKind toName attributes =
  TopologyEdge
    { from = NodeRef fromKind fromName,
      to = NodeRef toKind toName,
      relation = relation,
      attributes = fields attributes
    }

nodeEdges :: Spec -> Node -> [TopologyEdge]
nodeEdges spec = \case
  NAggregate _ -> []
  NProcess process ->
    [ mkEdge ProcessKind process.id Dispatches AggregateKind target [("command", String command)]
    | (target, command) <- processDispatches process.body
    ]
      <> [mkEdge ProcessKind process.id Saga AggregateKind process.saga.agg [("category", String process.saga.category)]]
      <> projectsEdges ProcessKind process.id process.projections
      <> concatMap (feedsEdges ProcessKind process.id) (processBodyInputs process.body)
  NWorkflow _ -> []
  NRouter router ->
    [mkEdge RouterKind router.id Dispatches AggregateKind router.target [("command", String router.dispatch.command)]]
      <> [mkEdge RouterKind router.id Reads ReadModelKind readModel [("role", String "resolve")] | Just readModel <- [routerReadModel router]]
      <> projectsEdges RouterKind router.id router.projections
      <> feedsEdges RouterKind router.id router.input
  NContract _ -> []
  NIntake intake ->
    [ mkEdge
        IntakeKind
        intake.name
        Subscribes
        ContractKind
        intake.contract
        [ ("topicAlias", String intake.topic),
          ("topic", maybe Null String (contractTopic spec intake.contract intake.topic)),
          ("events", names intake.accept)
        ]
    ]
  NEmit emit ->
    [ mkEdge
        EmitKind
        emit.name
        Publishes
        ContractKind
        emit.contract
        [ ("topicAlias", String emit.topic),
          ("topic", maybe Null String (contractTopic spec emit.contract emit.topic)),
          ("events", names (emitEvents emit))
        ]
    ]
  NPublisher publisher -> [mkEdge PublisherKind publisher.name Delivers EmitKind publisher.emit []]
  NWorkqueue _ -> []
  NPgmqDispatch dispatch ->
    [ mkEdge DispatchKind dispatch.name Reads ReadModelKind dispatch.sourceReadModel [("role", String "source")],
      mkEdge DispatchKind dispatch.name Reads ReadModelKind dispatch.dedupReadModel [("role", String "dedupe")],
      mkEdge DispatchKind dispatch.name Enqueues WorkqueueKind dispatch.enqueueTo []
    ]
  NReadModel readModel ->
    [mkEdge ReadModelKind readModel.name MemberOf RebuildGroupKind groupName [] | Just groupName <- [readModel.group]]
      <> [mkEdge ReadModelKind readModel.name Observes ProjectionTargetKind target [] | target <- readModel.observedTargets]
      <> [mkEdge ReadModelKind readModel.name BackedBy ProjectionTargetKind target [] | Just target <- [readModel.backingTarget]]
  NOperation operation -> case operation.shape of
    CommandOp aggregate _ _ _ -> [mkEdge OperationKind operation.name Commands AggregateKind aggregate []]
    QueryOp readModel _ _ _ -> [mkEdge OperationKind operation.name Queries ReadModelKind readModel []]
    SignalOp label workflow _ _ _ -> [mkEdge OperationKind operation.name Signals WorkflowKind workflow [("label", String label)]]
    RunOp workflow _ _ -> [mkEdge OperationKind operation.name Runs WorkflowKind workflow []]
  NProjectionTarget target ->
    [mkEdge ProjectionTargetKind target.name DependsOn ProjectionTargetKind dependency [] | dependency <- target.dependsOn]
  NRebuildGroup groupNode ->
    [mkEdge RebuildGroupKind groupNode.name Groups ProjectionTargetKind target [] | target <- groupNode.targets]
  NProjectionOwner owner ->
    [mkEdge ProjectionOwnerKind owner.name Consumes AggregateKind aggregate [] | CatalogAggregate aggregate <- owner.sources]
      <> [mkEdge ProjectionOwnerKind owner.name Writes ProjectionTargetKind target [] | target <- owner.targets]
      <> [mkEdge ProjectionOwnerKind owner.name MemberOf RebuildGroupKind owner.group []]
  NProjectionRevision revision ->
    mkEdge ProjectionRevisionKind revision.name Revises RebuildGroupKind revision.group []
      : [ mkEdge ProjectionRevisionKind revision.name Revises ProjectionTargetKind revisionTarget.target [("schemaVersion", String revisionTarget.schemaVersion)]
        | revisionTarget <- revision.targets
        ]
  NExternalRead externalRead ->
    let identity = externalReadNodeIdentity externalRead
     in mkEdge ExternalReadKind identity Exposes ReadModelKind externalRead.queryModel []
          : [mkEdge ExternalReadKind identity CompatibleWith ProjectionRevisionKind revision [] | revision <- externalRead.compatibleRevisions]
  where
    projectionOwners =
      Map.fromListWith
        (flip (<>))
        [ (projection.table, [aggregate.name])
        | NAggregate aggregate <- spec.nodes,
          Just projection <- [aggregate.projection]
        ]
    feedsEdges kind name input =
      [ mkEdge IntakeKind source.intake Feeds kind name [("input", String input.name), ("events", names (NE.toList source.events))]
      | Just source <- [input.source]
      ]
    projectsEdges kind name tables =
      [ mkEdge kind name Projects AggregateKind aggregate [("table", String table)]
      | table <- tables,
        aggregate <- Map.findWithDefault [] table projectionOwners
      ]

-- | Every (target aggregate, command) a process body dispatches, in order.
processDispatches :: ProcessBody -> [(Name, Name)]
processDispatches = \case
  LegacyProcessBody _ handle timer ->
    [(dispatch.target, dispatch.command) | dispatch <- handle.dispatch]
      <> [(timer.fire.target, timer.fire.command)]
  ReactionProcessBody body ->
    concatMap reactionDispatches (NE.toList body.reactions)
      <> [(timer.fire.target, timer.fire.command) | timer <- body.timers]
  where
    reactionDispatches reaction = concatMap armDispatches (NE.toList reaction.arms)
    armDispatches arm = case arm.body of
      NoAction -> []
      ArmActions {advance, followUps} ->
        followUpDispatches followUps
          <> maybe [] (\advanceReaction -> maybe [] followUpDispatches advanceReaction.accepted) advance
    followUpDispatches followUps = mapMaybe followUpDispatch followUps
    followUpDispatch = \case
      FollowDispatch dispatch -> Just (dispatch.target, dispatch.command)
      _ -> Nothing

--------------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------------

canonicalBytes :: Value -> ByteString
canonicalBytes = LazyByteString.toStrict . RFC8785.encodeCanonical

nodeRefValue :: NodeRef -> Value
nodeRefValue ref = object ["kind" .= nodeKindText ref.kind, "name" .= ref.name]

-- | The document as a JSON value, before canonical encoding.
serviceTopologyValue :: ServiceTopology -> Value
serviceTopologyValue topology =
  object
    [ "schema" .= topologySchemaId topology,
      "service" .= topology.service,
      "source"
        .= object
          [ "kind" .= (case topology.source.kind of TopologySingleSource -> "source" :: Text; TopologyWorkspace -> "workspace"),
            "path" .= topology.source.path
          ],
      "effectiveSemanticContract" .= topology.languageContract,
      "generator" .= object ["tool" .= ("keiro-dsl" :: Text), "version" .= topology.generatorVersion],
      "members"
        .= [ object
               [ "path" .= member.path,
                 "sha256" .= member.sha256,
                 "declaredLanguageVersion" .= member.declaredLanguageVersion,
                 "effectiveLanguageVersion" .= member.effectiveLanguageVersion
               ]
           | member <- topology.members
           ],
      "nodes"
        .= [ object
               [ "kind" .= nodeKindText node.kind,
                 "name" .= node.name,
                 "context" .= node.context,
                 "member" .= node.member,
                 "line" .= node.line,
                 "details" .= Object node.details
               ]
           | node <- topology.nodes
           ],
      "edges"
        .= [ object
               [ "from" .= nodeRefValue topologyEdge.from,
                 "to" .= nodeRefValue topologyEdge.to,
                 "relation" .= relationText topologyEdge.relation,
                 "attributes" .= Object topologyEdge.attributes
               ]
           | topologyEdge <- topology.edges
           ]
    ]

-- | Canonical bytes: RFC 8785 JSON followed by one newline.
encodeServiceTopology :: ServiceTopology -> ByteString
encodeServiceTopology topology = canonicalBytes (serviceTopologyValue topology) <> ByteString.singleton 10
