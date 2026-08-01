module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.List (isInfixOf)
import Data.Text (Text)
import Generated.IdDomainMigration.Nominals (OrderId, orderIdText, parseOrderId)
import Generated.IdDomainMigration.OrderBook.Codec (parseOrderBookEvent)
import Generated.IdDomainMigration.OrderBook.Domain (OrderBookEvent (..), OrderRecordedData (..))
import Keiro.Codec (EventType (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  forM_ assertions $ \(label, ok) ->
    putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
  let failed = [label | (label, ok) <- assertions, not ok]
  unless (null failed) exitFailure

assertions :: [(String, Bool)]
assertions =
  [ ("safe constructor accepts canonical TypeID-v7", accepts validText),
    ("safe constructor rejects the legacy malformed text", rejects legacyInvalidText),
    ("safe constructor rejects a wrong prefix", rejects wrongPrefixText),
    ("historical event replay accepts the legacy malformed text", legacyReplayAccepts),
    ("new admission rejects the identical legacy malformed text", newAdmissionRejects),
    ("new-admission rejection identifies the owning field", newAdmissionLocatesField)
  ]

accepts :: Text -> Bool
accepts = either (const False) (const True) . parseOrderId

rejects :: Text -> Bool
rejects = not . accepts

legacyReplayAccepts :: Bool
legacyReplayAccepts =
  case parseOrderBookEvent (EventType "OrderRecorded") legacyPayload of
    Right (OrderRecorded payload) -> orderIdText (orderId payload) == legacyInvalidText
    Left _ -> False

newAdmissionRejects :: Bool
newAdmissionRejects = either (const True) (const False) (parseNewAdmission legacyPayload)

newAdmissionLocatesField :: Bool
newAdmissionLocatesField =
  case parseNewAdmission legacyPayload of
    Left reason -> "$.orderId" `isInfixOf` reason
    Right _ -> False

parseNewAdmission :: Value -> Either String OrderId
parseNewAdmission = parseEither (withObject "Record" (.: "orderId"))

legacyPayload :: Value
legacyPayload = object ["orderId" .= legacyInvalidText]

validText :: Text
validText = "ord_01h455vb4pex5vsknk084sn02q"

legacyInvalidText :: Text
legacyInvalidText = "ord_LEGACY-NOT-TYPEID"

wrongPrefixText :: Text
wrongPrefixText = "customer_01h455vb4pex5vsknk084sn02q"
