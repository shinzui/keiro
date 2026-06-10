-- HAND-OWNED hole module for the process manager's behaviour-bearing bodies.
-- keiro-dsl creates it once and never overwrites it.
module HospitalCapacity.HospitalSurge.ProcessHoles () where

-- HOLE handle: build the ProcessManagerAction (the self-advance 
--   'NoteSurgeThreshold', the dispatch(es), and the timer) from the input.
-- HOLE window: the deadline policy, e.g. surgeWindow :: NominalDiffTime; 
--   surgeDeadline observedAt = addUTCTime surgeWindow observedAt  (TIME INJECTED).
-- HOLE fire command: construct MarkSurgeTimerFired for the timer fire,
--   keyed by correlationId; the fired-event-id is the deterministic uuidv5 of
--   "hospital-surge-fired:" <> correlationId.