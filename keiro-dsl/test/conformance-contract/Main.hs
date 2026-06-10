{-# LANGUAGE OverloadedStrings #-}

{- | Conformance driver for the scaffolded EP-4 contract layer. Compiling this
component proves the scaffolded @Generated.…Emergency.Contract@ module (the
payload ADT + topic constants + messageType discriminator + strict codec) is
real, self-contained Haskell; running it proves every contract event type
round-trips through encode/decode and that messageTypeOf agrees.
-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Text qualified as T
import Generated.HospitalCapacity.Emergency.Contract
import System.Exit (exitFailure)

samples :: [(String, EmergencyPayload)]
samples =
    [ ("IncidentTransferNeedDeclared", IncidentTransferNeedDeclared (IncidentTransferNeedDeclaredData "inc-1" "tri-1" "north" 3))
    , ("TransferReservationAccepted", TransferReservationAccepted (TransferReservationAcceptedData "inc-1" "rsv-1" "hsp-1" "2026-01-01"))
    ]

main :: IO ()
main = do
    let results =
            [ (label, parseEmergencyPayload (encodeEmergencyPayload p) == Right p && messageTypeOf p == T.pack label)
            | (label, p) <- samples
            ]
    forM_ results $ \(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
    let failed = [label | (label, ok) <- results, not ok]
    unless (null failed) $ putStrLn ("contract: failed " <> show failed) >> exitFailure
