{- | Shared types for the durable integration-event outbox.

The outbox is the durable handoff between "this service has decided to
publish this integration event" and "this service has actually published
it". The producer subscription writes one outbox row per mapped private
event; the publisher worker drains rows into Kafka and marks each one
sent, retryable, or dead.
-}
module Keiro.Outbox.Types (
    OutboxId (..),
    OutboxStatus (..),
    OrderingPolicy (..),
    BackoffSchedule (..),
    ExponentialBackoffOptions (..),
    OutboxMessage (..),
    OutboxRow (..),
    OutboxPublishOptions (..),
    OutboxPublishConfigError (..),
    OutboxPublishSummary (..),
    OutboxMaintenanceOptions (..),
    OutboxMaintenanceSummary (..),
    defaultPublishOptions,
    defaultMaintenanceOptions,
    mkOutboxPublishOptions,
    statusText,
    parseStatus,
    nextDelay,
)
where

import Data.Time.Clock (NominalDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Keiro.Integration.Event (IntegrationEvent)
import Keiro.Prelude
import OpenTelemetry.Trace.Core (Tracer)

-- | Primary key of a 'keiro_outbox' row. Stable across publish retries.
newtype OutboxId = OutboxId {unOutboxId :: UUID}
    deriving stock (Generic, Eq, Ord, Show)

instance ToJSON OutboxId where
    toJSON = toJSON . UUID.toText . unOutboxId

instance FromJSON OutboxId where
    parseJSON v = do
        text <- parseJSON v
        case UUID.fromText text of
            Nothing -> fail ("OutboxId: not a UUID: " <> show text)
            Just uuid -> pure (OutboxId uuid)

{- | Lifecycle state of an outbox row.

* 'OutboxPending' — never attempted.
* 'OutboxPublishing' — currently held by a publisher worker (between
  claim and the call to mark sent/failed/dead). Rows left in this state
  after a worker crash are reclaimed by 'Keiro.Outbox.outboxMaintenancePass'
  after 'publishingTimeout'.
* 'OutboxSent' — Kafka acknowledged the publish; terminal.
* 'OutboxFailed' — last attempt failed; will be retried after
  'next_attempt_at'.
* 'OutboxDead' — terminal failure after 'maxAttempts' consecutive
  failures. Stays in the table for operator inspection.
-}
data OutboxStatus
    = OutboxPending
    | OutboxPublishing
    | OutboxSent
    | OutboxFailed
    | OutboxDead
    deriving stock (Generic, Eq, Show)

{- | Ordering policy enforced by the publisher worker's claim query.

* 'PerKeyHeadOfLine' (default) — within a @source@, a non-terminal row
  with key @k@ blocks every later row with the same key. Rows with
  'Nothing' key bypass the block (Kafka does not promise cross-key order
  for null-keyed records). One stuck aggregate cannot stall traffic on
  other aggregates. Ordering is based on @created_at@, which PostgreSQL
  sets to transaction-start time; callers that concurrently enqueue the
  same key through escape hatches must serialize those enqueues themselves
  if commit order matters.
* 'PerSourceStream' — within a @source@, any non-terminal row blocks
  every later row. Use when ordering matters across keys (rare). This has
  the same @created_at@ concurrency caveat as 'PerKeyHeadOfLine'.
* 'StopTheLine' — any failure halts the worker until operator
  intervention. Use when correctness requires manual review on every
  failure.
* 'BestEffort' — failed rows do not block; explicit opt-in only. Safe
  only when published events have no per-key/causal relationship.
-}
data OrderingPolicy
    = PerKeyHeadOfLine
    | PerSourceStream
    | StopTheLine
    | BestEffort
    deriving stock (Generic, Eq, Show)

-- | Knobs for 'ExponentialBackoff'. @delay = min maxDelay (initial * multiplier ^ (attempt - 1))@.
data ExponentialBackoffOptions = ExponentialBackoffOptions
    { initial :: !NominalDiffTime
    , maxDelay :: !NominalDiffTime
    , multiplier :: !Double
    }
    deriving stock (Generic, Eq, Show)

{- | Backoff curve used to compute 'next_attempt_at' after a failure.

* 'ConstantBackoff' — fixed delay between retries.
* 'ExponentialBackoff' — exponential growth capped at @maxDelay@.
-}
data BackoffSchedule
    = ConstantBackoff !NominalDiffTime
    | ExponentialBackoff !ExponentialBackoffOptions
    deriving stock (Generic, Eq, Show)

{- | Compute the retry delay for an attempt number (1-based: 1 = first
failure, 2 = second failure, …). Used by 'Keiro.Outbox.Schema.markOutboxFailedTx'
to derive @next_attempt_at@.
-}
nextDelay :: BackoffSchedule -> Int -> NominalDiffTime
nextDelay (ConstantBackoff delay) _ = delay
nextDelay (ExponentialBackoff opts) attempt =
    let raw = (opts ^. #initial) * realToFrac ((opts ^. #multiplier) ** fromIntegral (max 0 (attempt - 1)))
     in min (opts ^. #maxDelay) raw

{- | A request to enqueue one integration event into the outbox. Callers
generate 'outboxId' (use a random UUID for ad-hoc enqueues, a
deterministic UUID for idempotent retries from a saga/process manager).
-}
data OutboxMessage = OutboxMessage
    { outboxId :: !OutboxId
    , event :: !IntegrationEvent
    }
    deriving stock (Generic, Eq, Show)

{- | A row read back from @keiro_outbox@. Worker code consumes these to
publish to Kafka; tests use them to assert state transitions.
-}
data OutboxRow = OutboxRow
    { outboxId :: !OutboxId
    , event :: !IntegrationEvent
    , status :: !OutboxStatus
    , attemptCount :: !Int
    , nextAttemptAt :: !UTCTime
    , lastError :: !(Maybe Text)
    , publishedAt :: !(Maybe UTCTime)
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)

{- | Knobs that govern one invocation of 'Keiro.Outbox.publishClaimedOutbox'.

The optional 'tracer' field opts the publisher into OpenTelemetry
instrumentation: when present, the publisher opens a @Producer@-kind
span around each publish call, attributing the first row's
'IntegrationEvent.destination' (topic), 'IntegrationEvent.messageId',
and Kafka key per the messaging semantic conventions. When 'tracer' is
'Nothing' (the default) the publisher emits no spans.
-}
data OutboxPublishOptions = OutboxPublishOptions
    { batchSize :: !Int
    , maxAttempts :: !Int
    , backoff :: !BackoffSchedule
    , orderingPolicy :: !OrderingPolicy
    , publishingTimeout :: !NominalDiffTime
    , tracer :: !(Maybe Tracer)
    }
    deriving stock (Generic)

data OutboxPublishConfigError
    = InvalidOutboxBatchSize !Int
    | InvalidOutboxMaxAttempts !Int
    | InvalidOutboxPublishingTimeout !NominalDiffTime
    | InvalidConstantBackoff !NominalDiffTime
    | InvalidExponentialBackoffInitial !NominalDiffTime
    | InvalidExponentialBackoffMultiplier !Double
    | InvalidExponentialBackoffMaxDelay !NominalDiffTime !NominalDiffTime
    deriving stock (Generic, Eq, Show)

{- | Aggregate result of one publisher pass.

@published + retried + dead + halted@ equals the number of rows claimed.
'retried' includes rows that were skipped because an earlier row in the same
ordered publish group failed; those rows are returned to @failed@ without
consuming an attempt. 'haltedOn' is populated only by 'StopTheLine' policy.
-}
data OutboxPublishSummary = OutboxPublishSummary
    { claimed :: !Int
    , published :: !Int
    , retried :: !Int
    , dead :: !Int
    , haltedOn :: !(Maybe OutboxId)
    }
    deriving stock (Generic, Eq, Show)

{- | Knobs for 'Keiro.Outbox.outboxMaintenancePass'.

Schedule maintenance less frequently than publish passes; it owns crash
reclamation and backlog gauge sampling.
-}
data OutboxMaintenanceOptions = OutboxMaintenanceOptions
    { maxAttempts :: !Int
    , publishingTimeout :: !NominalDiffTime
    }
    deriving stock (Generic, Eq, Show)

-- | Result of one outbox maintenance pass.
data OutboxMaintenanceSummary = OutboxMaintenanceSummary
    { requeued :: !Int
    , deadLettered :: !Int
    , backlog :: !Int
    }
    deriving stock (Generic, Eq, Show)

{- | Sensible defaults: batch of 32, ten retry attempts, two-second
constant backoff, per-key head-of-line ordering.
-}
defaultPublishOptions :: OutboxPublishOptions
defaultPublishOptions =
    OutboxPublishOptions
        { batchSize = 32
        , maxAttempts = 10
        , backoff = ConstantBackoff 2
        , orderingPolicy = PerKeyHeadOfLine
        , publishingTimeout = 300
        , tracer = Nothing
        }

-- | Maintenance defaults match the publisher's retry ceiling and stale-row timeout.
defaultMaintenanceOptions :: OutboxMaintenanceOptions
defaultMaintenanceOptions =
    OutboxMaintenanceOptions
        { maxAttempts = defaultPublishOptions ^. #maxAttempts
        , publishingTimeout = defaultPublishOptions ^. #publishingTimeout
        }

-- | Validate outbox publisher options before starting a worker.
mkOutboxPublishOptions :: OutboxPublishOptions -> Either OutboxPublishConfigError OutboxPublishOptions
mkOutboxPublishOptions opts
    | opts ^. #batchSize < 1 = Left (InvalidOutboxBatchSize (opts ^. #batchSize))
    | opts ^. #maxAttempts < 1 = Left (InvalidOutboxMaxAttempts (opts ^. #maxAttempts))
    | opts ^. #publishingTimeout <= 0 = Left (InvalidOutboxPublishingTimeout (opts ^. #publishingTimeout))
    | otherwise = opts <$ validateBackoff (opts ^. #backoff)

validateBackoff :: BackoffSchedule -> Either OutboxPublishConfigError ()
validateBackoff = \case
    ConstantBackoff delay
        | delay < 0 -> Left (InvalidConstantBackoff delay)
        | otherwise -> Right ()
    ExponentialBackoff backoff
        | backoff ^. #initial <= 0 -> Left (InvalidExponentialBackoffInitial (backoff ^. #initial))
        | backoff ^. #multiplier < 1 -> Left (InvalidExponentialBackoffMultiplier (backoff ^. #multiplier))
        | backoff ^. #maxDelay < backoff ^. #initial ->
            Left (InvalidExponentialBackoffMaxDelay (backoff ^. #initial) (backoff ^. #maxDelay))
        | otherwise -> Right ()

-- | Wire representation of 'OutboxStatus' used in the @status@ column.
statusText :: OutboxStatus -> Text
statusText = \case
    OutboxPending -> "pending"
    OutboxPublishing -> "publishing"
    OutboxSent -> "sent"
    OutboxFailed -> "failed"
    OutboxDead -> "dead"

-- | Inverse of 'statusText'. Unknown database values are decode failures.
parseStatus :: Text -> Either Text OutboxStatus
parseStatus = \case
    "pending" -> Right OutboxPending
    "publishing" -> Right OutboxPublishing
    "sent" -> Right OutboxSent
    "failed" -> Right OutboxFailed
    "dead" -> Right OutboxDead
    bad -> Left ("unknown keiro_outbox.status: " <> bad)
