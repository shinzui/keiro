{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | Conformance driver for language-4 prefix-indexed integration contracts.
-- Compiling this component proves distinct contract fields carry distinct
-- @KindID@ types; running it proves canonical JSON remains text and every frozen
-- admission failure is attributed to the owning field path.
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value, object, (.=))
import Data.KindID (KindID)
import Data.Text (Text)
import qualified Data.Text as T
import Generated.HospitalCapacity.Emergency.Contract
import Keiro.Codec.IdDomain (parseKindIdV7Text)
import System.Exit (exitFailure)

canonicalSuffix :: Text
canonicalSuffix = "01h455vb4pex5vsknk084sn02q"

incidentIdValue :: KindID "inc"
incidentIdValue = either (error . show) id (parseKindIdV7Text @"inc" ("inc_" <> canonicalSuffix))

reservationIdValue :: KindID "rsv"
reservationIdValue = either (error . show) id (parseKindIdV7Text @"rsv" ("rsv_" <> canonicalSuffix))

hospitalIdValue :: KindID "hsp"
hospitalIdValue = either (error . show) id (parseKindIdV7Text @"hsp" ("hsp_" <> canonicalSuffix))

incidentPayload :: EmergencyPayload
incidentPayload =
  IncidentTransferNeedDeclared
    (IncidentTransferNeedDeclaredData incidentIdValue "tri-1" "north" 3)

reservationPayload :: EmergencyPayload
reservationPayload =
  TransferReservationAccepted
    (TransferReservationAcceptedData incidentIdValue reservationIdValue hospitalIdValue "2026-01-01")

incidentJson :: Text -> Value
incidentJson rawIncidentId =
  object
    [ "messageType" .= ("IncidentTransferNeedDeclared" :: Text),
      "incidentId" .= rawIncidentId,
      "triageRecordId" .= ("tri-1" :: Text),
      "region" .= ("north" :: Text),
      "redCount" .= (3 :: Int)
    ]

main :: IO ()
main = do
  let validIncidentJson = incidentJson ("inc_" <> canonicalSuffix)
      validReservationJson =
        object
          [ "messageType" .= ("TransferReservationAccepted" :: Text),
            "incidentId" .= ("inc_" <> canonicalSuffix),
            "reservationId" .= ("rsv_" <> canonicalSuffix),
            "hospitalId" .= ("hsp_" <> canonicalSuffix),
            "expirationDeadline" .= ("2026-01-01" :: Text)
          ]
      checks =
        [ ( "IncidentTransferNeedDeclared round-trip",
            encodeEmergencyPayload incidentPayload == validIncidentJson
              && parseEmergencyPayload validIncidentJson == Right incidentPayload
          ),
          ( "TransferReservationAccepted round-trip",
            encodeEmergencyPayload reservationPayload == validReservationJson
              && parseEmergencyPayload validReservationJson == Right reservationPayload
          ),
          rejection "malformed $.incidentId" "inc-1" "malformed TypeID text",
          rejection "wrong-prefix $.incidentId" ("rsv_" <> canonicalSuffix) "prefix mismatch",
          rejection "non-canonical $.incidentId" "inc_01H455VB4PEX5VSKNK084SN02Q" "not canonical lowercase",
          rejection "non-v7 $.incidentId" "inc_00041061050r3gg28a1c60t3gf" "not UUIDv7"
        ]
  forM_ checks $ \(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
  let failed = [label | (label, ok) <- checks, not ok]
  unless (null failed) $ putStrLn ("typed contract: failed " <> show failed) >> exitFailure
  where
    rejection label raw expected =
      ( label,
        case parseEmergencyPayload (incidentJson raw) of
          Left problem -> "$.incidentId" `T.isInfixOf` problem && expected `T.isInfixOf` problem
          Right _ -> False
      )
