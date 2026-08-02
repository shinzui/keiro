-- | Conformance driver for the scaffolded EP-4 contract layer. Compiling this
-- component proves the scaffolded @Generated.…Emergency.Contract@ module (the
-- payload ADT + topic constants + messageType discriminator + strict codec) is
-- real, self-contained Haskell; running it proves every contract event type
-- round-trips through encode/decode and that messageTypeOf agrees.
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Generated.HospitalCapacity.Emergency.Contract
import System.Exit (exitFailure)

samples :: [(String, EmergencyPayload, ByteString)]
samples =
  [ ( "IncidentTransferNeedDeclared",
      IncidentTransferNeedDeclared (IncidentTransferNeedDeclaredData "inc-1" "tri-1" "north" 3),
      "{\"incidentId\":\"inc-1\",\"messageType\":\"IncidentTransferNeedDeclared\",\"redCount\":3,\"region\":\"north\",\"triageRecordId\":\"tri-1\"}"
    ),
    ( "TransferReservationAccepted",
      TransferReservationAccepted (TransferReservationAcceptedData "inc-1" "rsv-1" "hsp-1" "2026-01-01"),
      "{\"expirationDeadline\":\"2026-01-01\",\"hospitalId\":\"hsp-1\",\"incidentId\":\"inc-1\",\"messageType\":\"TransferReservationAccepted\",\"reservationId\":\"rsv-1\"}"
    )
  ]

main :: IO ()
main = do
  let results =
        [ (label, parseEmergencyPayload (encodeEmergencyPayload p) == Right p && messageTypeOf p == T.pack label && encode (encodeEmergencyPayload p) == expectedBytes)
        | (label, p, expectedBytes) <- samples
        ]
      unknownTagRejected = case parseEmergencyPayload (object ["messageType" .= ("UnknownMessage" :: Text)]) of
        Left _ -> True
        Right _ -> False
      missingFieldRejected = case parseEmergencyPayload (object ["messageType" .= ("IncidentTransferNeedDeclared" :: Text)]) of
        Left _ -> True
        Right _ -> False
  forM_ results $ \(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
  let failed = [label | (label, ok) <- results, not ok]
  putStrLn ("unknown discriminator rejected: " <> show unknownTagRejected)
  putStrLn ("missing field rejected: " <> show missingFieldRejected)
  unless (null failed && unknownTagRejected && missingFieldRejected) $ putStrLn ("contract: failed " <> show failed) >> exitFailure
