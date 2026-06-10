-- | Conformance driver for the hospital-surge process manager's spec-derived
-- facts harness (EP-3 M4/M5). The scaffolded @ProcessHarness@ module exports the
-- spec's deterministic process/timer decisions as plain values; this driver
-- asserts them against a HAND-WRITTEN expectation. Because the expectation is
-- not generated, a spec change that alters a decision (e.g. flipping the timer
-- @on-reject@ disposition from @Fired@ to @Retry@) diverges from it and turns a
-- specific assertion red — the spec->behaviour pin. (Behavioural conformance of
-- the /filled/ ProcessManager against the live effectful/hasql runtime is the
-- heavier remaining M5 step.)
module Main (main) where

import Control.Monad (forM_, unless)
import Generated.HospitalCapacity.HospitalSurge.ProcessHarness (processHarnessValues)
import System.Exit (exitFailure)

-- | The expected lowering of hospital-surge.keiro's process/timer decisions.
expected :: [(String, String)]
expected =
  [ ("fireAtField", "observedAt") -- time is injected (deadline = window + observedAt)
  , ("timerIdPrefix", "hospital-surge-timer:") -- deterministic timer id
  , ("firedEventIdPrefix", "hospital-surge-fired:") -- deterministic fired-event id
  , ("dispatchIdUserField", "none") -- dispatch id is runtime-owned
  , ("onReject", "Fired") -- the benign inversion
  , ("onFailed", "Retry") -- a real failure retries the source event
  , ("maxAttempts", "5") -- the ceiling is forced on
  ]

main :: IO ()
main = do
  results <- pure
    [ (label, lookup label processHarnessValues == Just want)
    | (label, want) <- expected
    ]
  forM_ results $ \(label, ok) ->
    putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
  let failed = [label | (label, ok) <- results, not ok]
  unless (null failed) $ do
    putStrLn ("process harness: " <> show (length failed) <> " assertion(s) failed: " <> show failed)
    exitFailure
