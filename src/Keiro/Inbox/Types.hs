{- | Shared types for the idempotent integration-event inbox.

The inbox lives in the consuming bounded context. When a Kafka consumer
receives an integration event, the inbox records a stable external
identity for that message and runs the local handler in the same
transaction. Duplicate redeliveries (Kafka offset retry, rebalance,
producer republish) become observable as duplicates instead of
re-running the handler.
-}
module Keiro.Inbox.Types
  ( InboxDedupePolicy (..)
  , InboxStatus (..)
  , InboxResult (..)
  , InboxError (..)
  , InboxRow (..)
  , InboxEnqueueOutcome (..)
  , InboxAckOutcome (..)
  , InboxClaimOptions (..)
  , defaultInboxClaimOptions
  , KafkaDeliveryRef (..)
  , BackoffSchedule (..)
  , inboxStatusText
  , parseInboxStatus
  , dedupeKeyFor
  )
where

import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime)
import Data.UUID qualified as UUID
import Keiro.Integration.Event (IntegrationEvent)
import Keiro.Outbox.Types (BackoffSchedule (..))
import Keiro.Prelude
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))
import Shibuya.Core.Ack (DeadLetterReason)

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
  identity is available.
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

* 'InboxPending' — written, awaiting handler. Set by the worker-side
  'Keiro.Inbox.enqueueInbox' path; the EP-21 inline
  'Keiro.Inbox.runInboxTransaction' path skips this state and writes
  directly to 'InboxProcessing'.
* 'InboxProcessing' — transient: either the EP-21 inline handler is
  running, or a worker has claimed the row from the queue with
  'FOR UPDATE SKIP LOCKED'. After the visibility timeout
  ('InboxClaimOptions.visibilityTimeout') a row stuck here is treated
  as orphaned and is returned to 'InboxPending' by the next claim
  cycle.
* 'InboxCompleted' — handler ran to completion; terminal.
* 'InboxFailed' — handler signaled a transient failure. The worker
  bumps @attempt_count@, sets @next_attempt_at@ from the backoff
  schedule, and re-claims when the delay elapses.
* 'InboxDead' — terminal failure after exhausting
  'InboxClaimOptions.maxAttempts', or an explicit
  'Shibuya.Core.Ack.AckDeadLetter' decision. Operator action is required
  to resurrect or drop the row.
-}
data InboxStatus
  = InboxPending
  | InboxProcessing
  | InboxCompleted
  | InboxFailed
  | InboxDead
  deriving stock (Generic, Eq, Show)

{- | The classified outcome of 'Keiro.Inbox.runInboxTransaction'.

* 'InboxProcessed a' — first delivery; handler ran and returned @a@.
* 'InboxDuplicate' — a previous delivery already completed; handler not
  run.
* 'InboxInProgress' — a previous attempt is currently in-flight (only
  observable from a future async path). Treat as transient.
* 'InboxPreviouslyFailed' — a previous attempt recorded a permanent
  failure. Operator should review before reprocessing.
-}
data InboxResult a
  = InboxProcessed !a
  | InboxDuplicate
  | InboxInProgress
  | InboxPreviouslyFailed !(Maybe Text)
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
  , receivedAt :: !UTCTime
  , completedAt :: !(Maybe UTCTime)
  , failedAt :: !(Maybe UTCTime)
  , lastError :: !(Maybe Text)
  , attemptCount :: !Int
  , nextAttemptAt :: !UTCTime
  , claimedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)

{- | Result of 'Keiro.Inbox.enqueueInbox'.

* 'EnqueuedNew' — a fresh 'InboxPending' row was inserted.
* 'EnqueueDuplicateOf' — a row with the same @(source, dedupe_key)@
  already exists; the caller can inspect its status to decide whether
  to no-op (a duplicate Kafka delivery), surface a duplicate to a
  saga, or trigger an alert.
-}
data InboxEnqueueOutcome
  = EnqueuedNew
  | EnqueueDuplicateOf !InboxRow
  deriving stock (Generic, Eq, Show)

{- | Outcome of one ack decision applied to an inbox row by the
'Keiro.Inbox.Adapter' worker.

* 'InboxAcked' — handler returned 'Shibuya.Core.Ack.AckOk'; the row
  is now 'InboxCompleted'.
* 'InboxRetrying' — handler returned 'Shibuya.Core.Ack.AckRetry'; the
  row is now 'InboxFailed' with @next_attempt_at@ as carried.
* 'InboxDeadLettered' — handler returned 'AckDeadLetter' or the row
  exceeded 'maxAttempts'; status is 'InboxDead' (terminal).
* 'InboxClaimReleased' — handler returned 'AckHalt'; the row was
  returned to 'InboxPending' without bumping @attempt_count@ so the
  next worker can re-claim it.
-}
data InboxAckOutcome
  = InboxAcked
  | InboxRetrying !UTCTime
  | InboxDeadLettered !DeadLetterReason
  | InboxClaimReleased
  deriving stock (Generic, Eq, Show)

{- | Knobs that govern one claim cycle of the inbox worker.

* @batchSize@ — maximum number of rows claimed per poll. Larger
  batches amortize the poll cost but enlarge the rollback window if
  the worker crashes.
* @visibilityTimeout@ — duration after which a row stuck in
  'InboxProcessing' is treated as orphaned and is returned to
  'InboxPending'. Must exceed the slowest handler's P99 latency to
  avoid premature re-claim; too high causes long stalls. Default 60s.
* @maxAttempts@ — number of failure transitions ('AckRetry') before
  the row is moved to 'InboxDead'. Default 10.
* @backoff@ — schedule used to compute @next_attempt_at@ on each
  failure.
-}
data InboxClaimOptions = InboxClaimOptions
  { batchSize :: !Int
  , visibilityTimeout :: !NominalDiffTime
  , maxAttempts :: !Int
  , backoff :: !BackoffSchedule
  }
  deriving stock (Generic, Eq, Show)

-- | Sensible defaults: batch of 32, 60s visibility, ten attempts, two-second constant backoff.
defaultInboxClaimOptions :: InboxClaimOptions
defaultInboxClaimOptions =
  InboxClaimOptions
    { batchSize = 32
    , visibilityTimeout = 60
    , maxAttempts = 10
    , backoff = ConstantBackoff 2
    }

inboxStatusText :: InboxStatus -> Text
inboxStatusText = \case
  InboxPending -> "pending"
  InboxProcessing -> "processing"
  InboxCompleted -> "completed"
  InboxFailed -> "failed"
  InboxDead -> "dead"

parseInboxStatus :: Text -> InboxStatus
parseInboxStatus = \case
  "pending" -> InboxPending
  "processing" -> InboxProcessing
  "completed" -> InboxCompleted
  "failed" -> InboxFailed
  "dead" -> InboxDead
  _ -> InboxFailed

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
