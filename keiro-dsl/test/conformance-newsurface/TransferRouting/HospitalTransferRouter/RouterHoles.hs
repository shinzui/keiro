-- HAND-OWNED hole module for the router's behaviour-bearing bodies.
-- keiro-dsl creates it once and never overwrites it.
module TransferRouting.HospitalTransferRouter.RouterHoles () where

-- HOLE resolve :: AcceptedHospitalTransferNeed -> Eff es [PMCommand targetCommand]
--   Spec source: read-model hospital_load (typically Keiro.ReadModel.runQuery).
--   The spec's 'stable' keyword acknowledges that retry attempts accumulate
--   the UNION of resolved target identities. Keep the recipient set stable
--   for a source event whenever an exact recipient set matters.
-- HOLE router value: assemble Keiro.Router.Router with name = hospitalTransferRouterName,
--   key, resolve, targetEventStream, and targetProjections; run it with
--   runRouterWorkerWith hospitalTransferRouterWorkerOptions.
-- HOLE targetProjections: spec projections = [].
-- NOTE on-duplicate AckOk is sound because Keiro.Router confirms a duplicate
--   event id against the TARGET stream via confirmBenignDuplicate before
--   returning PMCommandDuplicate. Hand-rolled dispatch paths must do likewise.
