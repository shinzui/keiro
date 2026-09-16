-- | EP-5 runtime conformance: the scaffolded pgmq @QueuePolicy@ — the
-- @RetryPolicy@ and the @JobOutcome@ disposition — compiled against the LIVE
-- @Keiro.PGMQ.Job@ runtime. Running it pins the dangerous inversions over the
-- real JobOutcome: storeFailure ⇒ Retry (transient) and decodeFailure ⇒ Dead
-- (poison), plus the dlq=on ceiling.
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Generated.HospitalCapacity.ReservationWork.Queue (ReservationWorkItem (..), encodeReservationWorkItem, groupKeyFor, parseReservationWorkItem)
import Generated.HospitalCapacity.ReservationWork.QueueCodec (reservationWorkJobCodec)
import Generated.HospitalCapacity.ReservationWork.QueuePolicy (ReservationWorkOutcome (..))
import Generated.HospitalCapacity.ReservationWork.QueuePolicy qualified as QueuePolicy
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
  let sample = ReservationWorkItem "rsv-123" "hsp-1" "cmd-1" True
      expectedBytes :: ByteString
      expectedBytes = "{\"command_id\":\"cmd-1\",\"hospital_id\":\"hsp-1\",\"life_critical_override\":true,\"reservation_id\":\"rsv-123\"}"
      wireBytesOk = encode (encodeReservationWorkItem sample) == expectedBytes
      decodeAcceptanceOk = parseReservationWorkItem (encodeReservationWorkItem sample) == Right sample
      decodeRejectionOk = case parseReservationWorkItem (object ["reservation_id" .= ("rsv-123" :: Text)]) of
        Left _ -> True
        Right _ -> False
      storeOk = isRetry (QueuePolicy.jobOutcomeFor StoreFailure) -- transient: MUST retry
      decodeOk = isDead (QueuePolicy.jobOutcomeFor DecodeFailure) -- poison: MUST dead-letter
      ceilingOk = maxRetries QueuePolicy.retryPolicy == 3 && useDeadLetter QueuePolicy.retryPolicy
      orderingOk = QueuePolicy.jobOrdering == FifoThroughput
      tuningOk = ordering (QueuePolicy.jobTuningFor defaultJobTuning) == FifoThroughput
      job =
        Job
          { jobName = "reservation-work",
            jobQueue = queueRef "hospital_capacity.reservation_work",
            jobCodec = reservationWorkJobCodec,
            jobOrdering = QueuePolicy.jobOrdering,
            jobPolicy = QueuePolicy.retryPolicy
          }
      provisionOk = case queueProvisionConfigs QueuePolicy.queueProvision job of
        [mainQueue, deadLetterQueue] ->
          Config.fifoIndex mainQueue
            && not (Config.fifoIndex deadLetterQueue)
            && isStandard mainQueue
            && isStandard deadLetterQueue
        _ -> False
      groupKeyOk = groupKeyFor sample == "rsv-123"
      vectors =
        [ "hospital_capacity.reservation_work",
          "Repro.Work",
          "a__b..c",
          "9lives",
          "already_dlq",
          "hospital_capacity.reservation_work.per_hospital_fifo_lane_assignments"
        ]
      parity = [(logical, derivedQueueTrio logical == liveQueueTrio logical) | logical <- vectors]
  putStrLn ("storeFailure => Retry (transient): " <> show storeOk)
  putStrLn ("decodeFailure => Dead (poison): " <> show decodeOk)
  putStrLn ("retry ceiling + dlq on: " <> show ceilingOk)
  putStrLn ("ordering lowered to FifoThroughput: " <> show orderingOk)
  putStrLn ("provision includes the FIFO index: " <> show provisionOk)
  putStrLn ("groupKeyFor projects the payload field: " <> show groupKeyOk)
  putStrLn ("jobTuningFor overlays deployment tuning: " <> show tuningOk)
  putStrLn ("queue payload bytes pinned: " <> show wireBytesOk)
  putStrLn ("queue decoder acceptance/rejection pinned: " <> show (decodeAcceptanceOk && decodeRejectionOk))
  mapM_ (\(logical, matches) -> putStrLn ("derivedQueueTrio " <> show logical <> " == live queueRef: " <> show matches)) parity
  unless (wireBytesOk && decodeAcceptanceOk && decodeRejectionOk && storeOk && decodeOk && ceilingOk && orderingOk && provisionOk && groupKeyOk && tuningOk && all snd parity) exitFailure

liveQueueTrio :: Text -> (Text, Text, Text)
liveQueueTrio logical =
  ( physical,
    queueNameToText (dlqName ref),
    "pgmq.q_" <> physical
  )
  where
    ref = queueRef logical
    physical = queueNameToText (physicalName ref)

isStandard :: Config.QueueConfig -> Bool
isStandard config = case Config.queueType config of
  Config.StandardQueue -> True
  _ -> False
