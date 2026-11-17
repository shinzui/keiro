{-# LANGUAGE OverloadedRecordDot #-}

-- | The shared topology machine proof. @keiro-dsl topology@ exports each
-- aggregate's state machine from the specification alone. A conformance suite
-- that compiles generated keiki transducers walks each one with keiki's own
-- accessors ('edgesOut', 'target', 'mode', 'initial', 'isFinal',
-- 'edgeInputName' and each output's wire-constructor name) through
-- 'walkMachine', and 'proveTopologyMachines' fails unless every walked machine
-- equals the exported @machine@ object of its fixture. It also fails when an
-- aggregate whose exported machine ownership is @generated@ is neither compared
-- nor named as excluded with a reason, so a corpus cannot silently drop one.
module TopologyMachineProof
  ( WalkedMachine,
    walkMachine,
    MachineProof (..),
    proveTopologyMachines,
    topologyMachineProofLine,
  )
where

import Control.Monad (filterM, forM, forM_, unless, when)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Keiki.Core (Edge (..), EdgeMode (..), HsPred, OutTerm (..), SymTransducer (..))
import Keiki.Render.Mermaid (edgeInputName)
import Keiro.Dsl.Parser (parseSourceDocument, renderParseFailure)
import Keiro.Dsl.SemanticContract (checkedSource)
import Keiro.Dsl.SourceIndex (ParsedSourceDocument (..))
import Keiro.Dsl.Topology
import Keiro.Dsl.Validate (Diagnostic (..), Severity (..), renderDiagnostic, validateService)
import Keiro.Dsl.Workspace (oneMemberParsedDocumentWorkspace)
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (takeFileName)
import System.IO (hPutStrLn, stderr)

-- | An aggregate name and its walked keiki machine, or why it could not be
-- walked.
type WalkedMachine = (Text, Either Text MachineTopology)

-- | Walk a real generated keiki transducer into the exported shape. The Text
-- argument is the aggregate name, removed from the front of each shown vertex.
-- An edge whose guard names no command constructor is a conformance failure.
walkMachine ::
  (Bounded s, Enum s, Show s) =>
  Text ->
  SymTransducer (HsPred rs ci) rs s ci co ->
  WalkedMachine
walkMachine aggregate transducer = (aggregate, walked)
  where
    walked = do
      edges <-
        fmap concat . forM vertices $ \vertex ->
          forM (zip [0 ..] (transducer.edgesOut vertex)) $ \(edgeIndex, edge) -> do
            command <- case edgeInputName edge of
              Just name -> Right name
              Nothing -> Left (aggregate <> ": edge " <> stateName vertex <> "#" <> T.pack (show edgeIndex) <> " names no command constructor")
            pure
              MachineEdge
                { source = stateName vertex,
                  edgeIndex = edgeIndex,
                  target = stateName edge.target,
                  mode = case edge.mode of
                    Live -> MachineLive
                    ReplayOnly -> MachineReplayOnly,
                  command = command,
                  events = [T.pack wireCtor.wcName | OPack _ wireCtor _ <- edge.output]
                }
      pure
        MachineTopology
          { ownership = MachineGenerated,
            initial = stateName transducer.initial,
            states = [MachineState {name = stateName vertex, terminal = transducer.isFinal vertex} | vertex <- vertices],
            edges = edges
          }
    vertices = [minBound .. maxBound]
    stateName vertex =
      let shown = T.pack (show vertex)
       in maybe shown id (T.stripPrefix aggregate shown)

-- | The exported document and the machines that matched it, in the order
-- they were given.
data MachineProof = MachineProof
  { topology :: ServiceTopology,
    compared :: [(Text, MachineTopology)]
  }

-- | Export the topology of the fixture (a path relative to the keiro-dsl
-- package, also tried under @keiro-dsl/@), compare every walked machine with
-- the exported @machine@ of its aggregate, and fail on the first difference.
-- The second argument names aggregates deliberately left out, each with its
-- reason; every other aggregate whose exported ownership is @generated@ must be
-- walked. Failures are printed on standard error, so a suite with a
-- machine-readable standard output stays parseable.
proveTopologyMachines :: FilePath -> [(Text, Text)] -> [WalkedMachine] -> IO MachineProof
proveTopologyMachines fixture excluded walked = do
  topology <- exportedTopology fixture
  compared <- forM walked $ \(aggregate, walkResult) -> do
    actual <- either (failWith . T.unpack) pure walkResult
    let exported = exportedMachine topology aggregate
        actualValue = machineValue actual
    when (exported /= Just actualValue) $ do
      hPutStrLn stderr ("topology machine proof: " <> fixture <> ": machine " <> T.unpack aggregate <> ": exported machine differs from keiki")
      hPutStrLn stderr "exported:"
      LBS8.hPutStrLn stderr (maybe "(none)" Aeson.encode exported)
      hPutStrLn stderr "keiki:"
      LBS8.hPutStrLn stderr (Aeson.encode actualValue)
      exitFailure
    pure (aggregate, actual)
  let walkedNames = map fst walked
      excludedNames = map fst excluded
      generated = [node.name | node <- topology.nodes, node.kind == AggregateKind, ownershipOf node == Just (String "generated")]
      unaccounted = [name | name <- generated, name `notElem` walkedNames, name `notElem` excludedNames]
      contradictory = [name | name <- excludedNames, name `elem` walkedNames]
  forM_ excluded $ \(name, reason) ->
    when (T.null (T.strip reason)) (failWith ("topology machine proof: " <> fixture <> ": exclusion of " <> T.unpack name <> " gives no reason"))
  unless (null contradictory) $
    failWith ("topology machine proof: " <> fixture <> ": aggregates both compared and excluded: " <> T.unpack (T.intercalate ", " contradictory))
  unless (null unaccounted) $
    failWith ("topology machine proof: " <> fixture <> ": generated aggregates neither compared nor excluded: " <> T.unpack (T.intercalate ", " unaccounted))
  pure MachineProof {topology = topology, compared = compared}

-- | The line each suite prints after a successful proof.
topologyMachineProofLine :: MachineProof -> String
topologyMachineProofLine proof =
  "topology machine proof: " <> show count <> (if count == 1 then " aggregate matches keiki" else " aggregates match keiki")
  where
    count = length proof.compared

ownershipOf :: TopologyNode -> Maybe Value
ownershipOf node = case KeyMap.lookup (Key.fromText "machine") node.details of
  Just (Object machine) -> KeyMap.lookup (Key.fromText "ownership") machine
  _ -> Nothing

exportedTopology :: FilePath -> IO ServiceTopology
exportedTopology fixture = do
  path <- locate fixture
  bytes <- BS.readFile path
  source <- either (failWith . show) pure (TE.decodeUtf8' bytes)
  document <- either (failWith . T.unpack . renderParseFailure) pure (parseSourceDocument path source)
  let errors = [diagnostic | diagnostic <- validateService (checkedSource document.parsedSource), diagnostic.severity == Error]
  unless (null errors) (failWith (T.unpack (T.unlines (map (renderDiagnostic path) errors))))
  workspace <- either (failWith . show) pure (oneMemberParsedDocumentWorkspace path document)
  either
    (failWith . T.unpack . renderTopologyError)
    pure
    (buildServiceTopology TopologySingleSource path workspace [(takeFileName path, memberDigest bytes)])

exportedMachine :: ServiceTopology -> Text -> Maybe Value
exportedMachine topology aggregate =
  case [node | node <- topology.nodes, node.kind == AggregateKind, node.name == aggregate] of
    node : _ -> KeyMap.lookup (Key.fromText "machine") node.details
    [] -> Nothing

locate :: FilePath -> IO FilePath
locate relative = do
  found <- filterM doesFileExist [relative, "keiro-dsl/" <> relative]
  case found of
    path : _ -> pure path
    [] -> failWith ("topology machine proof: cannot locate " <> relative)

failWith :: String -> IO a
failWith message = hPutStrLn stderr message >> exitFailure
