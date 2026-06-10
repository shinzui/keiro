-- HAND-FILLED integration service (EP-4 M5 full-service integration): the
-- inbox transaction runner (wired to the scaffolded dedupe policy) and the
-- outbox IntegrationProducer (its mapEvent the filled emit map/skip hole) —
-- the behaviour-bearing bodies — type-checked against the live keiro runtime.
module HospitalCapacity.IncidentInbox.Integration (
    runIncidentInbox,
    incidentProducer,
) where

import Effectful (Eff, IOE, (:>))
import Generated.HospitalCapacity.IncidentInbox.Inbox (inboxDedupePolicy)
import Hasql.Transaction qualified as Tx
import Keiro.Inbox (InboxError, InboxResult, runInboxTransaction)
import Keiro.Inbox.Types (KafkaDeliveryRef)
import Keiro.Integration.Event (IntegrationEvent)
import Keiro.Outbox (IntegrationProducer (..))
import Kiroku.Store.Effect (Store)

{- | The inbox runner, wired to the scaffolded dedupe policy. The handler (the
in-transaction domain effect) is the filled behaviour-bearing hole.
-}
runIncidentInbox ::
    (IOE :> es, Store :> es) =>
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))
runIncidentInbox event kafka handler =
    runInboxTransaction Nothing inboxDedupePolicy event kafka handler

{- | The outbox producer; @mapEvent@ is the filled emit map (here the total
@_ => skip@ mapping — a valid, exhaustive choice).
-}
incidentProducer :: IntegrationProducer e
incidentProducer =
    IntegrationProducer
        { name = "hospital-capacity-outbox"
        , source = "hospital-capacity"
        , messageIdPrefix = "msg"
        , mapEvent = \_recorded _event -> Nothing
        }
