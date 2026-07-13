{- | EP-5 runtime conformance: the scaffolded pgmq @QueuePolicy@ — the
@RetryPolicy@ and the @JobOutcome@ disposition — compiled against the LIVE
@Keiro.PGMQ.Job@ runtime. Running it pins the dangerous inversions over the
real JobOutcome: storeFailure ⇒ Retry (transient) and decodeFailure ⇒ Dead
(poison), plus the dlq=on ceiling.
-}
module Main (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Generated.HospitalCapacity.Reservation_work.QueuePolicy (jobOutcomeFor, retryPolicy)
import Keiro.Dsl.Validate (derivedQueueTrio)
import Keiro.PGMQ.Job (JobOutcome (..), RetryPolicy (..))
import Keiro.PGMQ.Runtime (QueueRef (..), queueRef)
import Pgmq.Types (queueNameToText)
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
        vectors =
            [ "hospital_capacity.reservation_work"
            , "Repro.Work"
            , "a__b..c"
            , "9lives"
            , "already_dlq"
            , "hospital_capacity.reservation_work.per_hospital_fifo_lane_assignments"
            ]
        parity = [(logical, derivedQueueTrio logical == liveQueueTrio logical) | logical <- vectors]
    putStrLn ("storeFailure => Retry (transient): " <> show storeOk)
    putStrLn ("decodeFailure => Dead (poison): " <> show decodeOk)
    putStrLn ("retry ceiling + dlq on: " <> show ceilingOk)
    mapM_ (\(logical, matches) -> putStrLn ("derivedQueueTrio " <> show logical <> " == live queueRef: " <> show matches)) parity
    unless (storeOk && decodeOk && ceilingOk && all snd parity) exitFailure

liveQueueTrio :: Text -> (Text, Text, Text)
liveQueueTrio logical =
    ( physical
    , queueNameToText (dlqName ref)
    , "pgmq.q_" <> physical
    )
  where
    ref = queueRef logical
    physical = queueNameToText (physicalName ref)
