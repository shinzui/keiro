{-# LANGUAGE OverloadedRecordDot #-}

{- | The topology machine proof for its dedicated fixture. @keiro-dsl topology@
exports each aggregate's state machine from the specification alone. This
suite compiles the generated keiki transducers of
@keiro-dsl/test/fixtures/topology-machine.keiro@, walks them with keiki's own
accessors (see "TopologyMachineProof"), and fails unless the result equals the
exported @machine@ object for every aggregate, including the process saga. It
also guards its own coverage, so a fixture edit cannot make the pass vacuous.
-}
module Main (main) where

import Control.Monad (unless)
import Data.List (sort)
import Data.Text qualified as T
import Generated.TopologyMachine.Order.Transducer (orderTransducer)
import Generated.TopologyMachine.OrderSaga.Transducer (orderSagaTransducer)
import Keiro.Dsl.Topology
import System.Exit (exitFailure)
import TopologyMachineProof

main :: IO ()
main = do
  proof <-
    proveTopologyMachines
      "test/fixtures/topology-machine.keiro"
      []
      [ walkMachine "Order" orderTransducer,
        walkMachine "OrderSaga" orderSagaTransducer
      ]
  mapM_
    ( \(aggregate, machine) ->
        putStrLn
          ( "machine "
              <> T.unpack aggregate
              <> ": "
              <> show (length machine.states)
              <> " states, "
              <> show (length machine.edges)
              <> " edges match keiki"
          )
    )
    proof.compared
  putStrLn (topologyMachineProofLine proof)
  -- Guard against a vacuous pass after a fixture edit.
  let machines = map snd proof.compared
      comparedNames = map fst proof.compared
      allEdges = concatMap (.edges) machines
      replayOnly = any ((== MachineReplayOnly) . (.mode)) allEdges
      twoEvents = any ((>= 2) . length . (.events)) allEdges
      multiEdgeState = or [length [() | e <- m.edges, e.source == s.name] >= 2 | m <- machines, s <- m.states]
      sagas = [toRef.name | topologyEdge <- proof.topology.edges, topologyEdge.relation == Saga, let toRef = topologyEdge.to]
      sagaCompared = not (null sagas) && all (`elem` comparedNames) sagas
      everyAggregate = sort [node.name | node <- proof.topology.nodes, node.kind == AggregateKind] == sort comparedNames
  unless (replayOnly && twoEvents && multiEdgeState && sagaCompared && everyAggregate) $ do
    putStrLn
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
    exitFailure
  putStrLn "coverage: replay-only edge, two-event edge, multi-edge state, process saga present"
