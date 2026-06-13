{-# LANGUAGE OverloadedStrings #-}

-- HAND-FILLED pgmq dispatch service (EP-5 M5 full-service integration): the
-- declarative Job value (queue + codec + retry policy, all from the scaffolded
-- deterministic layer) paired with the worker handler — the behaviour-bearing
-- hole — filled and type-checked against the live keiro-pgmq runtime.
module HospitalCapacity.ReservationWork.WorkqueueJob (
    reservationWorkJob,
    reservationWorkHandler,
) where

import Effectful (Eff)
import Generated.HospitalCapacity.Reservation_work.Queue (
    ReservationWorkItem,
    encodeReservationWorkItem,
    parseReservationWorkItem,
 )
import Generated.HospitalCapacity.Reservation_work.QueuePolicy (retryPolicy)
import Keiro.PGMQ.Codec (mkJobCodec)
import Keiro.PGMQ.Job (Job (..), JobOutcome (..))
import Keiro.PGMQ.Runtime (queueRef)

-- | The declarative job, assembled entirely from scaffolded deterministic parts.
reservationWorkJob :: Job ReservationWorkItem
reservationWorkJob =
    Job
        { jobName = "reservation-work"
        , jobQueue = queueRef "hospital_capacity.reservation_work"
        , jobCodec =
            mkJobCodec
                encodeReservationWorkItem
                parseReservationWorkItem
        , jobPolicy = retryPolicy
        }

{- | The worker hole, filled: process one work item, decide an outcome. (A real
handler reads downstream state; here it acknowledges, type-checked against the
live @p -> Eff es JobOutcome@ contract.)
-}
reservationWorkHandler :: ReservationWorkItem -> Eff es JobOutcome
reservationWorkHandler _item = pure Done
