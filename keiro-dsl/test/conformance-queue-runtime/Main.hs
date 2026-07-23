{- | EP-5 runtime conformance: the scaffolded pgmq @QueuePolicy@ — the
@RetryPolicy@ and the @JobOutcome@ disposition — compiled against the LIVE
@Keiro.PGMQ.Job@ runtime. Running it pins the dangerous inversions over the
real JobOutcome: storeFailure ⇒ Retry (transient) and decodeFailure ⇒ Dead
(poison), plus the dlq=on ceiling.
-}
module Main (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Generated.HospitalCapacity.Reservation_work.Queue (ReservationWorkItem (..), groupKeyFor)
import Generated.HospitalCapacity.Reservation_work.QueueCodec (reservationWorkJobCodec)
import Generated.HospitalCapacity.Reservation_work.QueuePolicy (jobOrdering, jobOutcomeFor, jobTuningFor, queueProvision, retryPolicy)
import Keiro.Dsl.Validate (derivedQueueTrio)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), JobOutcome (..), JobTuning (..), RetryPolicy (..), defaultJobTuning, queueProvisionConfigs)
import Keiro.PGMQ.Runtime (QueueRef (..), queueRef)
import Pgmq.Config qualified as Config
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
        orderingOk = jobOrdering == FifoThroughput
        tuningOk = ordering (jobTuningFor defaultJobTuning) == FifoThroughput
        job =
            Job
                { jobName = "reservation-work"
                , jobQueue = queueRef "hospital_capacity.reservation_work"
                , jobCodec = reservationWorkJobCodec
                , jobPolicy = retryPolicy
                }
        provisionOk = case queueProvisionConfigs queueProvision job of
            [mainQueue, deadLetterQueue] ->
                Config.fifoIndex mainQueue
                    && not (Config.fifoIndex deadLetterQueue)
                    && isStandard mainQueue
                    && isStandard deadLetterQueue
            _ -> False
        groupKeyOk = groupKeyFor (ReservationWorkItem "rsv-123" "hsp-1" "cmd-1" True) == "rsv-123"
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
    putStrLn ("ordering lowered to FifoThroughput: " <> show orderingOk)
    putStrLn ("provision includes the FIFO index: " <> show provisionOk)
    putStrLn ("groupKeyFor projects the payload field: " <> show groupKeyOk)
    putStrLn ("jobTuningFor overlays deployment tuning: " <> show tuningOk)
    mapM_ (\(logical, matches) -> putStrLn ("derivedQueueTrio " <> show logical <> " == live queueRef: " <> show matches)) parity
    unless (storeOk && decodeOk && ceilingOk && orderingOk && provisionOk && groupKeyOk && tuningOk && all snd parity) exitFailure

liveQueueTrio :: Text -> (Text, Text, Text)
liveQueueTrio logical =
    ( physical
    , queueNameToText (dlqName ref)
    , "pgmq.q_" <> physical
    )
  where
    ref = queueRef logical
    physical = queueNameToText (physicalName ref)

isStandard :: Config.QueueConfig -> Bool
isStandard config = case Config.queueType config of
    Config.StandardQueue -> True
    _ -> False
