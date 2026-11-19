-- HAND-FILLED delegated integration: the generated runner fixes the intake
-- policy, and this module supplies the downstream handler. A delivery status
-- never moves backwards, so recording an outcome on a delivered stream is a
-- replay-stable typed no-op. 'delegatedDomainCommand' acknowledges that no-op
-- with a completed inbox row; an accepted outcome is acknowledged by its
-- marker event. Any adapter failure leaves 'DelegatedOutcome' through the
-- outer 'Error' effect, so it is never acknowledged.
module DeliveryOutcomes.DeliveryOutcomeInbox.DelegatedIntegration
  ( DeliveryIntakeFailure (..),
    DeliveryResult,
    consumerName,
    recordOutcomeOperation,
    deliveryTarget,
    runDeliveryOutcomeInbox,
    typedDeliveryHandler,
    untypedDeliveryHandler,
  )
where

import Data.Aeson (eitherDecodeStrict)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, throwError)
import Generated.DeliveryOutcomes.Courier.Contract (CourierPayload (..), DeliveryOutcomeReportedData (..), parseCourierPayload)
import Generated.DeliveryOutcomes.DeliveryOutcomeInbox.Inbox (runInboxIntake)
import Generated.DeliveryOutcomes.DeliveryStatus.Domain (DeliveryStatusCommand (..), DeliveryStatusEvent, RecordOutcomeData (..))
import Generated.DeliveryOutcomes.DeliveryStatus.EventStream
  ( DeliveryStatusEventStreamDef,
    deliveryStatusCategory,
    deliveryStatusDomainCommandHandler,
  )
import Generated.DeliveryOutcomes.Nominals (DeliveryNoOp, DeliveryRejection)
import Keiro.Command (CommandResult, defaultRunCommandOptions, forgetDomainDecision, runDomainCommand)
import Keiro.Inbox.Delegated
  ( DelegatedCommandError,
    DelegatedDomainCommandError,
    DelegatedDomainResult,
    DelegatedNoOpReceipt (..),
    delegatedCommand,
    delegatedDomainCommand,
    delegatedEventId,
  )
import Keiro.Inbox.Types (DelegatedOutcome, InboxError, InboxPersistence (..), InboxResult, KafkaDeliveryRef)
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Stream (Stream, entityStream, streamName)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)

-- | Why the handler refused to acknowledge a delivery. The typed rejection
-- payload stays inside this value and is never rendered into logs.
data DeliveryIntakeFailure
  = UndecodablePayload !Text
  | TypedAdapterFailed !(DelegatedDomainCommandError DeliveryRejection)
  | UntypedAdapterFailed !DelegatedCommandError
  deriving stock (Eq, Show)

type DeliveryResult = DelegatedDomainResult DeliveryStatusEventStreamDef DeliveryStatusEvent DeliveryNoOp

consumerName :: Text
consumerName = "delivery-reputation"

recordOutcomeOperation :: Text
recordOutcomeOperation = "record-outcome"

deliveryTarget :: Text -> Stream DeliveryStatusEventStreamDef
deliveryTarget = entityStream deliveryStatusCategory

runDeliveryOutcomeInbox ::
  (IOE :> es) =>
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
  Eff es (Either InboxError (InboxResult a))
runDeliveryOutcomeInbox = runInboxIntake Nothing

-- | The production handler: decode the payload and run the typed command
-- through 'delegatedDomainCommand'. @beforeDispatch@ lets the test count
-- downstream dispatches.
typedDeliveryHandler ::
  (IOE :> es, Store :> es, Error StoreError :> es, Error DeliveryIntakeFailure :> es) =>
  Eff es () ->
  Maybe KafkaDeliveryRef ->
  Text ->
  IntegrationEvent ->
  Eff es (DelegatedOutcome DeliveryResult)
typedDeliveryHandler beforeDispatch kafka dedupe event = do
  report <- decodeReport event
  let target = deliveryTarget report.deliveryId
      receipt =
        DelegatedNoOpReceipt
          { consumer = consumerName,
            operation = recordOutcomeOperation,
            dedupeKey = dedupe,
            event,
            kafka,
            persistence = PersistFullEnvelope
          }
  outcome <-
    delegatedDomainCommand receipt defaultRunCommandOptions (streamName target) $ \prepared -> do
      beforeDispatch
      runDomainCommand prepared deliveryStatusDomainCommandHandler target (RecordOutcome (RecordOutcomeData report.outcome))
  either (throwError . TypedAdapterFailed) pure outcome

-- | The historical adapter with the typed decision erased. A silent edge is
-- indistinguishable from an unexplained zero-event success, so it is refused.
untypedDeliveryHandler ::
  (IOE :> es, Store :> es, Error StoreError :> es, Error DeliveryIntakeFailure :> es) =>
  Text ->
  IntegrationEvent ->
  Eff es (DelegatedOutcome (CommandResult DeliveryStatusEventStreamDef))
untypedDeliveryHandler dedupe event = do
  report <- decodeReport event
  let target = deliveryTarget report.deliveryId
      marker = delegatedEventId consumerName event.source dedupe (streamName target) recordOutcomeOperation
  outcome <-
    delegatedCommand defaultRunCommandOptions (streamName target) marker $ \prepared ->
      fmap forgetDomainDecision
        <$> runDomainCommand prepared deliveryStatusDomainCommandHandler target (RecordOutcome (RecordOutcomeData report.outcome))
  either (throwError . UntypedAdapterFailed) pure outcome

decodeReport :: (Error DeliveryIntakeFailure :> es) => IntegrationEvent -> Eff es DeliveryOutcomeReportedData
decodeReport event =
  case eitherDecodeStrict event.payloadBytes of
    Left err -> throwError (UndecodablePayload (Text.pack err))
    Right value -> case parseCourierPayload value of
      Left err -> throwError (UndecodablePayload err)
      Right (DeliveryOutcomeReported report) -> pure report

