{-# LANGUAGE OverloadedRecordDot #-}

{- | The topology machine proof. @keiro-dsl topology@ exports each aggregate's
state machine from the specification alone. This suite compiles the generated
keiki transducers of @keiro-dsl/test/fixtures/topology-machine.keiro@, walks
them with keiki's own accessors ('edgesOut', 'target', 'mode', 'initial',
'isFinal', 'edgeInputName' and each output's wire-constructor name), and fails
unless the result equals the exported @machine@ object for every aggregate,
including the process saga.
-}
module Main (main) where

import Control.Monad (filterM, forM, unless, when)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Generated.TopologyMachine.Order.Transducer (orderTransducer)
import Generated.TopologyMachine.OrderSaga.Transducer (orderSagaTransducer)
import Keiki.Core (Edge (..), EdgeMode (..), HsPred, OutTerm (..), SymTransducer (..))
import Keiki.Render.Mermaid (edgeInputName)
import Keiro.Dsl.Parser (parseSourceDocument, renderParseFailure)
import Keiro.Dsl.SemanticContract (checkedSource)
import Keiro.Dsl.Topology
import Keiro.Dsl.Validate (Diagnostic (..), Severity (..), renderDiagnostic, validateService)
import Keiro.Dsl.Workspace (oneMemberParsedDocumentWorkspace)
import Keiro.Dsl.SourceIndex (ParsedSourceDocument (..))
import System.Directory (doesFileExist)
import System.Exit (exitFailure)

fixturePath :: FilePath
fixturePath = "test/fixtures/topology-machine.keiro"

-- | Walk a real generated keiki transducer into the exported shape. The Text
-- argument is the aggregate name, removed from the front of each shown vertex.
-- An edge whose guard names no command constructor is a conformance failure.
keikiMachine ::
  (Bounded s, Enum s, Show s) =>
  Text ->
  SymTransducer (HsPred rs ci) rs s ci co ->
  Either Text MachineTopology
keikiMachine aggregate transducer = do
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
  where
    vertices = [minBound .. maxBound]
    stateName vertex =
      let shown = T.pack (show vertex)
       in maybe shown id (T.stripPrefix aggregate shown)

main :: IO ()
main = do
  topology <- exportedTopology
  let walked =
        [ ("Order", keikiMachine "Order" orderTransducer),
          ("OrderSaga", keikiMachine "OrderSaga" orderSagaTransducer)
        ]
  results <- forM walked $ \(aggregate, walkResult) -> do
    actual <- either (\message -> failWith (T.unpack message)) pure walkResult
    let exported = exportedMachine topology aggregate
        actualValue = machineValue actual
    when (exported /= Just actualValue) $ do
      putStrLn ("machine " <> T.unpack aggregate <> ": exported machine differs from keiki")
      putStrLn "exported:"
      LBS8.putStrLn (maybe "(none)" Aeson.encode exported)
      putStrLn "keiki:"
      LBS8.putStrLn (Aeson.encode actualValue)
      exitFailure
    putStrLn
      ( "machine "
          <> T.unpack aggregate
          <> ": "
          <> show (length actual.states)
          <> " states, "
          <> show (length actual.edges)
          <> " edges match keiki"
      )
    pure (aggregate, actual)
  -- Guard against a vacuous pass after a fixture edit.
  let machines = map snd results
      allEdges = concatMap (.edges) machines
      replayOnly = any ((== MachineReplayOnly) . (.mode)) allEdges
      twoEvents = any ((>= 2) . length . (.events)) allEdges
      multiEdgeState = or [length [() | e <- m.edges, e.source == s.name] >= 2 | m <- machines, s <- m.states]
      sagas = [toRef.name | topologyEdge <- topology.edges, topologyEdge.relation == Saga, let toRef = topologyEdge.to]
      sagaCompared = not (null sagas) && all (`elem` map fst results) sagas
      everyAggregate = sortOn id [node.name | node <- topology.nodes, node.kind == AggregateKind] == sortOn id (map fst results)
  unless (replayOnly && twoEvents && multiEdgeState && sagaCompared && everyAggregate) $
    failWith
      ( "coverage incomplete: replay-only="
          <> show replayOnly
          <> " two-event="
          <> show twoEvents
          <> " multi-edge-state="
          <> show multiEdgeState
          <> " saga-compared="
          <> show sagaCompared
          <> " every-aggregate="
          <> show everyAggregate
      )
  putStrLn "coverage: replay-only edge, two-event edge, multi-edge state, process saga present"

exportedTopology :: IO ServiceTopology
exportedTopology = do
  path <- locate fixturePath
  bytes <- BS.readFile path
  source <- either (failWith . show) pure (TE.decodeUtf8' bytes)
  document <- either (failWith . T.unpack . renderParseFailure) pure (parseSourceDocument path source)
  let errors = [diagnostic | diagnostic <- validateService (checkedSource document.parsedSource), diagnostic.severity == Error]
  unless (null errors) (failWith (T.unpack (T.unlines (map (renderDiagnostic path) errors))))
  workspace <- either (failWith . show) pure (oneMemberParsedDocumentWorkspace path document)
  either
    (failWith . T.unpack . renderTopologyError)
    pure
    (buildServiceTopology TopologySingleSource path workspace [("topology-machine.keiro", memberDigest bytes)])

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
    [] -> failWith ("cannot locate " <> relative)

failWith :: String -> IO a
failWith message = putStrLn message >> exitFailure
