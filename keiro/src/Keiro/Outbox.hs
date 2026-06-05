{- | Durable integration-event outbox.

The outbox decouples "this service has decided to publish an integration
event" from "this service has actually published it". Two surfaces use
it:

* The canonical 'IntegrationProducer' helper maps durable private events
  to public 'Keiro.Integration.Event.IntegrationEvent' values and enqueues
  one outbox row per mapped event. It mints @messageId@ as a prefixed
  UUIDv7 (TypeID) so the id is time-ordered, human-readable, and stable
  across publish retries.
* 'enqueueOutboxTx' is the inline escape hatch for sagas and process
  managers that need to emit an integration event without an intermediate
  private domain event. It runs inside the caller's
  'Hasql.Transaction.Transaction'.

The 'publishClaimedOutbox' worker is transport-neutral. It claims rows
with @FOR UPDATE SKIP LOCKED@ plus the configured 'OrderingPolicy',
hands each row to a caller-supplied publish function, and marks the row
sent, retryable, or dead. The Kafka adapter lives in
'Keiro.Outbox.Kafka'.
-}
module Keiro.Outbox (
    -- * Re-exports
    module Keiro.Outbox.Types,

    -- * Storage primitives (transport-neutral)
    enqueueOutboxTx,
    claimOutboxBatch,
    markOutboxSent,
    lookupOutbox,
    listOutbox,
    countOutboxBacklog,

    -- * Inline escape hatch
    freshOutboxId,
    enqueueIntegrationEventTx,

    -- * Canonical producer-subscription helper
    IntegrationProducer (..),
    IntegrationEventDraft (..),
    mintIntegrationEvent,
    draftToEvent,
    enqueueProducerEventTx,

    -- * Publisher worker
    PublishOutcome (..),
    publishClaimedOutbox,
)
where

import Data.ByteString (ByteString)
import Data.TypeID qualified as TypeID
import Data.UUID.V7 qualified as V7
import Effectful (Eff, IOE, (:>))
import Keiro.Integration.Event (
    IntegrationContentType,
    IntegrationEvent (..),
    SchemaReference,
    TraceContext,
 )
import Keiro.Outbox.Kafka (outboxRowToKafkaRecord)
import Keiro.Outbox.Schema
import Keiro.Outbox.Types
import Keiro.Prelude
import Keiro.Telemetry (
    KeiroMetrics,
    recordOutboxBacklog,
    recordOutboxDeadlettered,
    recordOutboxPublished,
    recordOutboxRetried,
    withProducerSpan,
 )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId, GlobalPosition, RecordedEvent)
import OpenTelemetry.Attributes.Key (unkey)
import OpenTelemetry.SemanticConventions (error_type)
import OpenTelemetry.Trace.Core (SpanStatus (..), addAttribute, setStatus)
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- | Mint a fresh time-ordered UUIDv7 for use as an 'OutboxId'.
freshOutboxId :: (IOE :> es) => Eff es OutboxId
freshOutboxId = fmap OutboxId (liftIO V7.genUUID)

{- | Enqueue an 'IntegrationEvent' from a saga or process manager that is
already running inside a 'runCommandWithSqlEvents' transaction. The
caller supplies a stable 'OutboxId' so retried command attempts coalesce
on the @(source, message_id)@ unique constraint.
-}
enqueueIntegrationEventTx ::
    OutboxId ->
    IntegrationEvent ->
    Tx.Transaction ()
enqueueIntegrationEventTx outboxId event =
    enqueueOutboxTx (OutboxMessage{outboxId, event})

-- ---------------------------------------------------------------------------
-- Producer-subscription helper
-- ---------------------------------------------------------------------------

{- | Configuration for the canonical producer subscription.

A service running 'IntegrationProducer' reads its private event stream,
decodes each event with a 'Keiro.Codec.Codec', calls 'mapEvent', and for
each 'Just' result writes one 'keiro_outbox' row. The helper mints
@messageId@ on each insert so the id is stable across publish retries.

* 'name' — subscription name used to checkpoint the producer's cursor
  in the @subscriptions@ table.
* 'source' — value written into @keiro_outbox.source@; identifies the
  producing bounded context.
* 'messageIdPrefix' — TypeID prefix used when minting @messageId@.
  Must be 1-63 lowercase Latin letters (e.g. @\"msg\"@, @\"order\"@).
* 'mapEvent' — pure mapper from a private 'RecordedEvent' and its
  decoded payload to an 'IntegrationEventDraft'. Returning 'Nothing'
  skips the event without enqueuing a row.
-}
data IntegrationProducer e = IntegrationProducer
    { name :: !Text
    , source :: !Text
    , messageIdPrefix :: !Text
    , mapEvent :: !(RecordedEvent -> e -> Maybe IntegrationEventDraft)
    }
    deriving stock (Generic)

{- | Everything in 'IntegrationEvent' except 'messageId' and 'source' —
those are filled in by 'mintIntegrationEvent' from the producer
configuration and the freshly minted TypeID.

@sourceEventId@ and @sourceGlobalPosition@ default to the values on the
underlying 'RecordedEvent' (see 'mintIntegrationEvent'); a mapper that
needs to override them can replace the draft fields directly.
-}
data IntegrationEventDraft = IntegrationEventDraft
    { destination :: !Text
    , key :: !(Maybe Text)
    , eventType :: !Text
    , schemaVersion :: !Int
    , contentType :: !IntegrationContentType
    , schemaReference :: !(Maybe SchemaReference)
    , sourceEventId :: !(Maybe EventId)
    , sourceGlobalPosition :: !(Maybe GlobalPosition)
    , payloadBytes :: !ByteString
    , occurredAt :: !UTCTime
    , causationId :: !(Maybe EventId)
    , correlationId :: !(Maybe EventId)
    , traceContext :: !(Maybe TraceContext)
    , attributes :: !(Maybe Value)
    }
    deriving stock (Generic, Eq, Show)

{- | Mint a fresh @messageId@ (TypeID with the producer's prefix) and build
the full 'IntegrationEvent' from the draft. Lives in 'IO' because TypeID
generation reads the global UUIDv7 sequence counter.
-}
mintIntegrationEvent ::
    (IOE :> es) =>
    IntegrationProducer e ->
    IntegrationEventDraft ->
    Eff es IntegrationEvent
mintIntegrationEvent producer draft = do
    typeId <- liftIO (TypeID.genTypeID (producer ^. #messageIdPrefix))
    pure (draftToEvent (producer ^. #source) (TypeID.toText typeId) draft)

-- | Build an 'IntegrationEvent' from a source, a minted message id, and a draft.
draftToEvent :: Text -> Text -> IntegrationEventDraft -> IntegrationEvent
draftToEvent source minted draft =
    IntegrationEvent
        { messageId = minted
        , source
        , destination = draft ^. #destination
        , key = draft ^. #key
        , eventType = draft ^. #eventType
        , schemaVersion = draft ^. #schemaVersion
        , contentType = draft ^. #contentType
        , schemaReference = draft ^. #schemaReference
        , sourceEventId = draft ^. #sourceEventId
        , sourceGlobalPosition = draft ^. #sourceGlobalPosition
        , payloadBytes = draft ^. #payloadBytes
        , occurredAt = draft ^. #occurredAt
        , causationId = draft ^. #causationId
        , correlationId = draft ^. #correlationId
        , traceContext = draft ^. #traceContext
        , attributes = draft ^. #attributes
        }

{- | Enqueue one drafted producer event inside an existing transaction.

This is the primitive a subscription worker calls per event. It mints a
fresh @messageId@ (TypeID), constructs the full envelope, and inserts
the row. The caller supplies the 'OutboxId' so retries from a known
subscription cursor coalesce on @(source, message_id)@.

The TypeID is minted before the insert; if the transaction rolls back
the message id is discarded (no observable effect) and the next attempt
mints a different id. Idempotency at the row level relies on a stable
'OutboxId', not the minted message id.
-}
enqueueProducerEventTx ::
    forall e es.
    (IOE :> es) =>
    IntegrationProducer e ->
    OutboxId ->
    IntegrationEventDraft ->
    Eff es (Tx.Transaction ())
enqueueProducerEventTx producer outboxId draft = do
    event <- mintIntegrationEvent producer draft
    pure (enqueueOutboxTx (OutboxMessage{outboxId, event}))

-- ---------------------------------------------------------------------------
-- Publisher worker
-- ---------------------------------------------------------------------------

-- | Result of one publish attempt as reported by the transport-specific publisher.
data PublishOutcome
    = -- | Kafka acknowledged the publish.
      PublishSucceeded
    | -- | Publish failed; will be retried after the configured backoff.
      PublishFailed !Text
    deriving stock (Generic, Eq, Show)

{- | Drain claimed outbox rows by handing each to @publish@ and reflecting
the outcome back into the row's status.

Claims rows in batches of @batchSize@ under the active 'OrderingPolicy',
calls @publish@ for each, and marks every row sent or — using
'markOutboxFailedTx' — failed/dead. On 'StopTheLine' policy, the worker
halts after the first 'PublishFailed' and records the offending
'OutboxId' in 'haltedOn'.

Returns when one of:

* No rows are claimable.
* The active policy is 'StopTheLine' and a publish failed.

The worker does not loop indefinitely; the application is expected to
schedule it repeatedly (e.g. once per process-compose tick).
-}
publishClaimedOutbox ::
    forall es.
    (IOE :> es, Store :> es) =>
    (OutboxRow -> Eff es PublishOutcome) ->
    OutboxPublishOptions ->
    Maybe KeiroMetrics ->
    Eff es OutboxPublishSummary
publishClaimedOutbox publish options mMetrics = do
    now <- liftIO getCurrentTime
    rows <- claimOutboxBatch (options ^. #orderingPolicy) (options ^. #batchSize) now
    -- Backlog gauge, recorded once per pass after the claim has moved this
    -- batch to 'publishing': it counts rows still awaiting a publisher. This is
    -- the synchronous-gauge baseline; a 'Nothing' handle makes it a no-op.
    backlog <- countOutboxBacklog
    recordOutboxBacklog mMetrics (fromIntegral backlog)
    summary <-
        drainBatch rows OutboxPublishSummary{claimed = 0, published = 0, retried = 0, dead = 0, haltedOn = Nothing}
    -- Counters from the aggregated pass summary (each a no-op under 'Nothing';
    -- a zero delta is harmless).
    recordOutboxPublished mMetrics (fromIntegral (summary ^. #published))
    recordOutboxRetried mMetrics (fromIntegral (summary ^. #retried))
    recordOutboxDeadlettered mMetrics (fromIntegral (summary ^. #dead))
    pure summary
  where
    drainBatch ::
        [OutboxRow] ->
        OutboxPublishSummary ->
        Eff es OutboxPublishSummary
    drainBatch [] acc = pure acc
    drainBatch (row : rest) acc = do
        outcome <-
            withProducerSpan
                (options ^. #tracer)
                (row ^. #event)
                (outboxRowToKafkaRecord row)
                $ \mSpan -> do
                    out <- publish row
                    case (mSpan, out) of
                        (Just sp, PublishFailed errMsg) -> do
                            addAttribute sp (unkey error_type) ("publish_failed" :: Text)
                            setStatus sp (Error errMsg)
                        _ -> pure ()
                    pure out
        now <- liftIO getCurrentTime
        case outcome of
            PublishSucceeded -> do
                markOutboxSent (row ^. #outboxId) now
                drainBatch rest (acc & #claimed +~ 1 & #published +~ 1)
            PublishFailed errMsg -> do
                let attempt = row ^. #attemptCount
                    delay = nextDelay (options ^. #backoff) attempt
                resultStatus <-
                    runTransaction $
                        markOutboxFailedTx
                            (row ^. #outboxId)
                            errMsg
                            (options ^. #maxAttempts)
                            delay
                            now
                let bumped = acc & #claimed +~ 1
                    acc' = case resultStatus of
                        OutboxDead -> bumped & #dead +~ 1
                        _ -> bumped & #retried +~ 1
                case options ^. #orderingPolicy of
                    StopTheLine ->
                        pure (acc' & #haltedOn ?~ row ^. #outboxId)
                    _ -> drainBatch rest acc'
