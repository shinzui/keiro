{-# LANGUAGE OverloadedStrings #-}

{- | EP-5 M5 full-service conformance: a complete pgmq dispatch service — the
scaffolded Job codec + retry policy plus a filled worker handler, assembled
into a live @Keiro.PGMQ.Job.Job@ value — compiled against keiro-pgmq.
-}
module Main (main) where

import Control.Monad (unless)
import HospitalCapacity.ReservationWork.WorkqueueJob (reservationWorkHandler, reservationWorkJob)
import Keiro.PGMQ.Job (Job (..), RetryPolicy (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    -- reference the handler so its (filled) definition is part of the build.
    let _handler = reservationWorkHandler
        nameOk = jobName reservationWorkJob == "reservation-work"
        policyOk = maxRetries (jobPolicy reservationWorkJob) == 3 && useDeadLetter (jobPolicy reservationWorkJob)
    putStrLn ("job name: " <> show nameOk)
    putStrLn ("retry policy (maxRetries=3, dlq on): " <> show policyOk)
    unless (nameOk && policyOk) exitFailure
