{-# LANGUAGE OverloadedStrings #-}

{- | EP-4 M5 full-service conformance: a complete integration service — the
scaffolded inbox dedupe/disposition plus a filled inbox transaction runner
and outbox IntegrationProducer — compiled against the live keiro runtime
(Keiro.Inbox / Keiro.Outbox / Kiroku.Store).
-}
module Main (main) where

import Control.Monad (unless)

-- runIncidentInbox (the inbox transaction runner) is compiled as part of the
-- Integration other-module; here we exercise the outbox producer.
import HospitalCapacity.IncidentInbox.Integration (incidentProducer)
import Keiro.Outbox (IntegrationProducer (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    let sourceOk = source incidentProducer == "hospital-capacity"
        prefixOk = messageIdPrefix incidentProducer == "msg"
    putStrLn ("outbox producer source: " <> show sourceOk)
    putStrLn ("outbox messageId prefix: " <> show prefixOk)
    unless (sourceOk && prefixOk) exitFailure
