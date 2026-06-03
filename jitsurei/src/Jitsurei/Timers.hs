module Jitsurei.Timers
  ( paymentTimeoutRequest
  , runPaymentTimeoutWorker
  , paymentTimeoutTimerId
  , paymentTimeoutEventId
  )
where

import Data.Aeson (object)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Data.TypeID.V7 qualified as TypeID
import Effectful (Eff, IOE, (:>))
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow, runTimerWorker)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (EventId (..))
import Jitsurei.Domain

paymentTimeoutRequest :: OrderId -> UTCTime -> TimerRequest
paymentTimeoutRequest orderId fireAt = TimerRequest
  { timerId = TimerId paymentTimeoutTimerId
  , processManagerName = "jitsurei-fulfillment"
  , correlationId = orderIdText orderId
  , fireAt = fireAt
  , payload =
      object
        [ "kind" Aeson..= ("payment-timeout" :: Text)
        , "orderId" Aeson..= orderIdText orderId
        ]
  }

runPaymentTimeoutWorker :: (IOE :> es, Store :> es) => UTCTime -> Eff es (Maybe TimerRow)
runPaymentTimeoutWorker now =
  runTimerWorker Nothing now (\_ -> pure (Just (EventId paymentTimeoutEventId)))

paymentTimeoutTimerId :: UUID
paymentTimeoutTimerId = uuidFromTypeId "timer_01h455vb4pex5vsknk084sn02q"

paymentTimeoutEventId :: UUID
paymentTimeoutEventId = uuidFromTypeId "event_01h455vb4pex5vsknk084sn02r"

uuidFromTypeId :: Text -> UUID
uuidFromTypeId value =
  case TypeID.parseText value of
    Right typeId -> TypeID.getUUID typeId
    Left err -> error ("invalid TypeID fixture: " <> show err)
