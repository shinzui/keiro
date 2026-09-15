-- HAND-FILLED delegated integration: the generated runner fixes the intake
-- policy while the service supplies the downstream durable outcome handler.
module HospitalCapacity.IncidentInbox.DelegatedIntegration
  ( runIncidentInbox,
  )
where

import Effectful (Eff, IOE, (:>))
import Data.Text (Text)
import Generated.HospitalCapacity.IncidentInbox.Inbox (runInboxIntake)
import Keiro.Inbox.Types (DelegatedOutcome, InboxError, InboxResult, KafkaDeliveryRef)
import Keiro.Integration.Event (IntegrationEvent)

runIncidentInbox ::
  IOE :> es =>
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
  Eff es (Either InboxError (InboxResult a))
runIncidentInbox = runInboxIntake Nothing
