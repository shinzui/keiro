{- | EP-5 runtime conformance: the scaffolded pgmq @QueuePolicy@ — the
@RetryPolicy@ and the @JobOutcome@ disposition — compiled against the LIVE
@Keiro.PGMQ.Job@ runtime. Running it pins the dangerous inversions over the
real JobOutcome: storeFailure ⇒ Retry (transient) and decodeFailure ⇒ Dead
(poison), plus the dlq=on ceiling.
-}
module Main (main) where

import Control.Monad (unless)
import Generated.HospitalCapacity.Reservation_work.QueuePolicy (jobOutcomeFor, retryPolicy)
import Keiro.PGMQ.Job (JobOutcome (..), RetryPolicy (..))
import System.Exit (exitFailure)

isRetry :: JobOutcome -> Bool
isRetry (Retry _) = True
isRetry _ = False

isDead :: JobOutcome -> Bool
isDead (Dead _) = True
isDead _ = False

main :: IO ()
main = do
    let storeOk = isRetry (jobOutcomeFor "storeFailure") -- transient: MUST retry
        decodeOk = isDead (jobOutcomeFor "decodeFailure") -- poison: MUST dead-letter
        ceilingOk = maxRetries retryPolicy == 3 && useDeadLetter retryPolicy
    putStrLn ("storeFailure => Retry (transient): " <> show storeOk)
    putStrLn ("decodeFailure => Dead (poison): " <> show decodeOk)
    putStrLn ("retry ceiling + dlq on: " <> show ceilingOk)
    unless (storeOk && decodeOk && ceilingOk) exitFailure
