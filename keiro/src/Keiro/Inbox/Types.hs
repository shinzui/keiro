{- | Shared types for the idempotent integration-event inbox.

The inbox lives in the consuming bounded context. When a Kafka consumer
receives an integration event, the inbox records a stable external
identity for that message and runs the local handler in the same
transaction. Duplicate redeliveries (Kafka offset retry, rebalance,
producer republish) become observable as duplicates instead of
re-running the handler.
-}
module Keiro.Inbox.Types (
    InboxDedupePolicy (..),
    InboxStatus (..),
    InboxResult (..),
    InboxError (..),
    InboxRow (..),
    KafkaDeliveryRef (..),
    inboxStatusText,
    parseInboxStatus,
    dedupeKeyFor,
)
where

import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Keiro.Integration.Event (IntegrationEvent)
import Keiro.Prelude
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))

{- | Which identity is used as the inbox primary key for an
'IntegrationEvent'.

* 'PreferIntegrationMessageId' (default) — use the application-level
  @messageId@ minted at the producer's outbox enqueue. EP-19 / EP-20
  keep this id stable across publish retries, so it is the natural
  primary dedupe key for Kafka-delivered events.
* 'PreferSourceEventIdentity' — use the @sourceEventId@ of the private
  event that produced this integration event. Useful when a producer
  may emit the same logical fact under different @messageId@s (e.g.
  schema-upgrade republish), and the consumer wants those republishes
  collapsed to a single handler run.
* 'KafkaDeliveryIdentity' — use the Kafka topic-partition-offset triple
  as the dedupe key. Fallback only when neither @messageId@ nor source
  identity is available. This identifies one broker delivery, not one
  logical producer message: if a producer republishes the same logical
  message, Kafka assigns a new offset and this policy will not collapse
  the republish.
* 'CustomDedupeKey' — caller supplies the key. Use only when the other
  policies cannot represent the identity scheme; the consuming service
  owns key collision resistance.
-}
data InboxDedupePolicy
    = PreferIntegrationMessageId
    | PreferSourceEventIdentity
    | KafkaDeliveryIdentity
    | CustomDedupeKey !Text
    deriving stock (Generic, Eq, Show)

{- | Lifecycle state of an inbox row.

* 'InboxProcessing' — legacy on-disk state from older wrappers and
  reserved for future async paths. Current single-transaction intake
  inserts fresh successful rows directly as 'InboxCompleted'.
* 'InboxCompleted' — handler ran to completion; terminal.
* 'InboxFailed' — handler signaled a permanent failure; terminal. The
  caller is responsible for operator action (dead-letter, manual
  retry).
-}
data InboxStatus
    = InboxProcessing
    | InboxCompleted
    | InboxFailed
    deriving stock (Generic, Eq, Show)

{- | The classified outcome of 'Keiro.Inbox.runInboxTransaction'.

* 'InboxProcessed a' — first delivery; handler ran and returned @a@.
* 'InboxDuplicate' — a previous delivery already completed; handler not
  run.
* 'InboxInProgress' — a previous attempt is currently in-flight, or a
  legacy @processing@ row was read. Current single-transaction intake
  does not commit @processing@ rows. Treat as transient.
* 'InboxPreviouslyFailed' — a previous attempt recorded a permanent
  failure. Operator should review before reprocessing.
-}
data InboxResult a
    = InboxProcessed !a
    | InboxDuplicate
    | InboxInProgress
    | InboxPreviouslyFailed !(Maybe Text)
    | InboxHandlerFailed !Text !Int
    deriving stock (Generic, Eq, Show)

{- | Errors surfaced by the inbox wrapper that originate from the inbox
itself rather than from the supplied handler.
-}
data InboxError
    = -- | The integration event lacked the field required by the chosen policy.
      DedupePolicyUnsatisfied !InboxDedupePolicy
    deriving stock (Generic, Eq, Show)

{- | Optional Kafka-delivery metadata recorded alongside an inbox row.

Used by 'KafkaDeliveryIdentity' to compute the dedupe key, and stored on
the row regardless of policy so operators can correlate the inbox
record with Kafka logs. Not part of the EP-19 envelope.
-}
data KafkaDeliveryRef = KafkaDeliveryRef
    { topic :: !Text
    , partition :: !Int64
    , offset :: !Int64
    }
    deriving stock (Generic, Eq, Show)

-- | One row read back from @keiro_inbox@. Used by tests and inspection tooling.
data InboxRow = InboxRow
    { source :: !Text
    , dedupeKey :: !Text
    , event :: !IntegrationEvent
    , kafka :: !(Maybe KafkaDeliveryRef)
    , status :: !InboxStatus
    , attemptCount :: !Int
    , receivedAt :: !UTCTime
    , completedAt :: !(Maybe UTCTime)
    , failedAt :: !(Maybe UTCTime)
    , lastError :: !(Maybe Text)
    }
    deriving stock (Generic, Eq, Show)

inboxStatusText :: InboxStatus -> Text
inboxStatusText = \case
    InboxProcessing -> "processing"
    InboxCompleted -> "completed"
    InboxFailed -> "failed"

parseInboxStatus :: Text -> Either Text InboxStatus
parseInboxStatus = \case
    "processing" -> Right InboxProcessing
    "completed" -> Right InboxCompleted
    "failed" -> Right InboxFailed
    other -> Left ("unknown keiro_inbox.status: " <> other)

{- | Compute the inbox dedupe key for an integration event under the
given policy plus optional Kafka delivery context. Returns 'Left' when
the policy demands a field the envelope does not carry (for example,
'PreferSourceEventIdentity' on an envelope with no
@sourceEventId@).
-}
dedupeKeyFor ::
    InboxDedupePolicy ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    Either InboxError Text
dedupeKeyFor policy event kafka = case policy of
    PreferIntegrationMessageId ->
        let mid = event ^. #messageId
         in if Text.null mid
                then Left (DedupePolicyUnsatisfied policy)
                else Right mid
    PreferSourceEventIdentity ->
        case event ^. #sourceEventId of
            Just (EventId u) -> Right (UUID.toText u)
            Nothing ->
                case event ^. #sourceGlobalPosition of
                    Just (GlobalPosition p) -> Right (Text.pack (show p))
                    Nothing -> Left (DedupePolicyUnsatisfied policy)
    KafkaDeliveryIdentity ->
        case kafka of
            Just ref ->
                Right
                    ( (ref ^. #topic)
                        <> ":"
                        <> Text.pack (show (ref ^. #partition))
                        <> ":"
                        <> Text.pack (show (ref ^. #offset))
                    )
            Nothing -> Left (DedupePolicyUnsatisfied policy)
    CustomDedupeKey k ->
        if Text.null k
            then Left (DedupePolicyUnsatisfied policy)
            else Right k
