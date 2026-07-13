module Jitsurei.Timers (
    paymentTimeoutRequest,
    runPaymentTimeoutWorker,
    jitsureiTimerWorkerOptions,
    paymentTimeoutTimerId,
    paymentTimeoutEventId,
)
where

import Data.Aeson (object)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.TypeID.V7 qualified as TypeID
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Jitsurei.Domain
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Timer (
    TimerId (..),
    TimerRequest (..),
    TimerRow,
    TimerWorkerOptions (..),
    mkTimerWorkerOptions,
    runTimerWorkerWith,
 )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (EventId (..))

paymentTimeoutRequest :: OrderId -> UTCTime -> TimerRequest
paymentTimeoutRequest orderId fireAt =
    TimerRequest
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

runPaymentTimeoutWorker ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    UTCTime ->
    Eff es (Maybe TimerRow)
runPaymentTimeoutWorker metrics now =
    runTimerWorkerWith metrics jitsureiTimerWorkerOptions now (\_ -> pure (Just (EventId paymentTimeoutEventId)))

{- | The example's production-shaped timer policy. Five failed claims are
enough to surface a poison timer without retrying forever, while a five-minute
stale-claim timeout automatically returns work stranded by a crashed worker to
@Scheduled@. The smart constructor keeps invalid policy values out of the
worker loop.
-}
jitsureiTimerWorkerOptions :: TimerWorkerOptions
jitsureiTimerWorkerOptions =
    case mkTimerWorkerOptions
        TimerWorkerOptions
            { maxAttempts = Just 5
            , requeueStuckAfter = Just 300
            } of
        Right options -> options
        Left err -> error ("invalid jitsurei timer worker options: " <> show err)

paymentTimeoutTimerId :: UUID
paymentTimeoutTimerId = uuidFromTypeId "timer_01h455vb4pex5vsknk084sn02q"

paymentTimeoutEventId :: UUID
paymentTimeoutEventId = uuidFromTypeId "event_01h455vb4pex5vsknk084sn02r"

uuidFromTypeId :: Text -> UUID
uuidFromTypeId value =
    case TypeID.parseText value of
        Right typeId -> TypeID.getUUID typeId
        Left err -> error ("invalid TypeID fixture: " <> show err)
