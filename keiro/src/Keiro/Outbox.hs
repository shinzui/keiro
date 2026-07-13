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
hands claimed batches to a caller-supplied publish function, and marks rows
sent, retryable, or dead. The Kafka adapter lives in
'Keiro.Outbox.Kafka'.

Run 'outboxMaintenancePass' on a separate, slower schedule to reclaim rows
left in @publishing@ by crashed workers and to sample the backlog gauge.

The per-key and per-source ordering policies sort by @created_at@, which
PostgreSQL fills at transaction start. The canonical 'IntegrationProducer'
subscription serializes same-key enqueues, so its ordering is stable. Callers
using the inline 'enqueueIntegrationEventTx' escape hatch concurrently for the
same key must serialize those enqueues themselves or accept best-effort order:
two transactions can commit in the opposite order of their @created_at@ values.
-}
module Keiro.Outbox (
    -- * Re-exports
    module Keiro.Outbox.Types,

    -- * Storage primitives (transport-neutral)
    enqueueOutboxTx,
    claimOutboxBatch,
    requeueStuckOutbox,
    markOutboxSent,
    lookupOutbox,
    listOutbox,
    countOutboxBacklog,
    garbageCollectSent,

    -- * Inline escape hatch
    freshOutboxId,
    enqueueIntegrationEventTx,

    -- * Canonical producer-subscription helper
    IntegrationProducer (..),
    IntegrationProducerConfigError (..),
    IntegrationEventDraft (..),
    mkIntegrationProducer,
    mintIntegrationEvent,
    draftToEvent,
    enqueueProducerEventTx,

    -- * Publisher worker
    PublishOutcome (..),
    publishClaimedOutbox,
    outboxMaintenancePass,
    sampleOutboxBacklog,
)
where

import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.TypeID qualified as TypeID
import Data.UUID.V7 qualified as V7
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (displayException, trySync)
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
    recordOutboxReclaimed,
    recordOutboxRetried,
    withProducerSpan,
 )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId, GlobalPosition, RecordedEvent)
import OpenTelemetry.Attributes.Key (AttributeKey (..), unkey)
import OpenTelemetry.SemanticConventions (error_type)
import OpenTelemetry.Trace.Core (SpanStatus (..), addAttribute, setStatus)
import "hasql-transaction" Hasql.Transaction qualified as Tx

keiro_outbox_batch_size :: AttributeKey Int64
keiro_outbox_batch_size = AttributeKey "keiro.outbox.batch.size"

-- | Mint a fresh time-ordered UUIDv7 for use as an 'OutboxId'.
freshOutboxId :: (IOE :> es) => Eff es OutboxId
freshOutboxId = fmap OutboxId (liftIO V7.genUUID)

{- | Enqueue an 'IntegrationEvent' from a saga or process manager that is
already running inside a 'runCommandWithSqlEvents' transaction. The
caller supplies a stable 'OutboxId' so retried command attempts coalesce
on the @(source, message_id)@ unique constraint.

Ordering caveat: under 'PerKeyHeadOfLine' and 'PerSourceStream', the publisher
orders rows by @created_at@, which PostgreSQL sets to transaction-start time.
If two concurrent transactions enqueue the same key/source and commit in the
opposite order, a publisher can observe that order. Serialize same-key enqueues
when strict order matters.
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
  Prefer constructing producers with 'mkIntegrationProducer'; an invalid
  prefix passed directly to 'IntegrationProducer' raises when the first
  message id is minted.
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

data IntegrationProducerConfigError
    = InvalidMessageIdPrefix !Text !Text
    deriving stock (Generic, Eq, Show)

-- | Validate an integration producer before starting its subscription.
mkIntegrationProducer :: IntegrationProducer e -> Either IntegrationProducerConfigError (IntegrationProducer e)
mkIntegrationProducer producer =
    case TypeID.checkPrefix (producer ^. #messageIdPrefix) of
        Nothing -> Right producer
        Just err ->
            Left
                ( InvalidMessageIdPrefix
                    (producer ^. #messageIdPrefix)
                    (Text.pack (show err))
                )

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

Ordering caveat: @created_at@ records transaction-start time. Under
'PerKeyHeadOfLine' or 'PerSourceStream', concurrent transactions for the same
key/source can commit in the opposite order and are therefore best-effort
unless the caller serializes them. The canonical producer subscription does
serialize same-key enqueues.
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

{- | Drain claimed outbox rows by handing the claimed batch to @publish@ and
reflecting the outcomes back into row statuses.

Claims rows in batches of @batchSize@ under the active 'OrderingPolicy',
calls @publish@ with the claimed rows in claim order, and marks every row
sent or — using 'markOutboxFailedTx' — failed/dead. The publish result must
contain one outcome per input row; a missing outcome is treated as
@PublishFailed "publisher returned no outcome"@. If the publisher throws,
every row in that call is treated as failed with the exception text.

For ordered policies, if a row fails then later rows in the same ordered group
are skipped and returned to @failed@ without consuming an attempt; these
skipped rows count as 'OutboxPublishSummary.retried'. A real Kafka transport
must not successfully deliver a later same-key record after reporting an
earlier same-key failure from the same call. On 'StopTheLine', the worker calls
@publish@ with singleton batches and halts after the first failed row, recording
the offending 'OutboxId' in 'haltedOn'.

Returns when one of:

* No rows are claimable.
* The active policy is 'StopTheLine' and a publish failed.

The worker does not loop indefinitely; the application is expected to
schedule it repeatedly (e.g. once per process-compose tick).
-}
publishClaimedOutbox ::
    forall es.
    (IOE :> es, Store :> es) =>
    ([OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]) ->
    OutboxPublishOptions ->
    Maybe KeiroMetrics ->
    Eff es OutboxPublishSummary
publishClaimedOutbox publish options mMetrics = do
    now <- liftIO getCurrentTime
    rows <- claimOutboxBatch (options ^. #orderingPolicy) (options ^. #batchSize) now
    summary <- publishBatch rows
    -- Counters from the aggregated pass summary (each a no-op under 'Nothing';
    -- a zero delta is harmless).
    recordOutboxPublished mMetrics (fromIntegral (summary ^. #published))
    recordOutboxRetried mMetrics (fromIntegral (summary ^. #retried))
    recordOutboxDeadlettered mMetrics (fromIntegral (summary ^. #dead))
    pure summary
  where
    publishBatch :: [OutboxRow] -> Eff es OutboxPublishSummary
    publishBatch [] =
        pure OutboxPublishSummary{claimed = 0, published = 0, retried = 0, dead = 0, haltedOn = Nothing}
    publishBatch batch =
        case options ^. #orderingPolicy of
            StopTheLine -> publishStopTheLine batch batch [] Nothing
            policy -> do
                outcomes <- publishRows batch
                markProcessedOutcomes policy batch outcomes Nothing

    publishStopTheLine ::
        [OutboxRow] ->
        [OutboxRow] ->
        [(OutboxId, PublishOutcome)] ->
        Maybe OutboxId ->
        Eff es OutboxPublishSummary
    publishStopTheLine original [] outcomes halted =
        markProcessedOutcomes StopTheLine original (Map.fromList outcomes) halted
    publishStopTheLine original (row : rest) outcomes _ = do
        result <- publishRows [row]
        let outcome = outcomeFor result row
            outcomes' = outcomes <> [(row ^. #outboxId, outcome)]
        case outcome of
            PublishSucceeded -> publishStopTheLine original rest outcomes' Nothing
            PublishFailed _ -> markProcessedOutcomes StopTheLine original (Map.fromList outcomes') (Just (row ^. #outboxId))

    publishRows :: [OutboxRow] -> Eff es (Map.Map OutboxId PublishOutcome)
    publishRows [] = pure Map.empty
    publishRows batch@(firstRow : _) =
        Map.fromList
            <$> withBatchSpan
                batch
                firstRow
                ( do
                    attempted <- trySync (publish batch)
                    let normalized =
                            case attempted of
                                Left err ->
                                    let errMsg = Text.pack (displayException err)
                                     in [(row ^. #outboxId, PublishFailed errMsg) | row <- batch]
                                Right reported ->
                                    normalizeOutcomes batch reported
                    pure normalized
                )

    withBatchSpan ::
        [OutboxRow] ->
        OutboxRow ->
        Eff es [(OutboxId, PublishOutcome)] ->
        Eff es [(OutboxId, PublishOutcome)]
    withBatchSpan batch firstRow action =
        withProducerSpan
            (options ^. #tracer)
            (firstRow ^. #event)
            (outboxRowToKafkaRecord firstRow)
            $ \mSpan -> do
                for_ mSpan $ \sp ->
                    addAttribute sp (unkey keiro_outbox_batch_size) (fromIntegral (length batch) :: Int64)
                outcomes <- action
                case (mSpan, firstFailure outcomes) of
                    (Just sp, Just errMsg) -> do
                        addAttribute sp (unkey error_type) ("publish_failed" :: Text)
                        setStatus sp (Error errMsg)
                    _ -> pure ()
                pure outcomes

    normalizeOutcomes :: [OutboxRow] -> [(OutboxId, PublishOutcome)] -> [(OutboxId, PublishOutcome)]
    normalizeOutcomes batch reported =
        let reportedMap = Map.fromList reported
         in [ (row ^. #outboxId, outcomeFor reportedMap row)
            | row <- batch
            ]

    outcomeFor :: Map.Map OutboxId PublishOutcome -> OutboxRow -> PublishOutcome
    outcomeFor outcomes row =
        fromMaybe (PublishFailed "publisher returned no outcome") $
            Map.lookup (row ^. #outboxId) outcomes

    firstFailure :: [(OutboxId, PublishOutcome)] -> Maybe Text
    firstFailure [] = Nothing
    firstFailure ((_, PublishSucceeded) : rest) = firstFailure rest
    firstFailure ((_, PublishFailed errMsg) : _) = Just errMsg

    markProcessedOutcomes ::
        OrderingPolicy ->
        [OutboxRow] ->
        Map.Map OutboxId PublishOutcome ->
        Maybe OutboxId ->
        Eff es OutboxPublishSummary
    markProcessedOutcomes policy batch outcomes halted = do
        now <- liftIO getCurrentTime
        let marks = foldMap (groupMarks outcomes) (outcomeGroups policy batch)
            sentIds = marks ^. #sentIds
            failedRows = marks ^. #failedRows
            skippedRows = marks ^. #skippedRows
        failedStatuses <-
            if null failedRows && null skippedRows
                then pure []
                else runTransaction $ do
                    statuses <- traverse (markFailed now) failedRows
                    traverse_ (markSkipped now) skippedRows
                    pure statuses
        _ <- markOutboxSentBatch sentIds now
        let deadCount = length [() | OutboxDead <- failedStatuses]
            retriedFailures = length failedStatuses - deadCount
        pure
            OutboxPublishSummary
                { claimed = length batch
                , published = length sentIds
                , retried = retriedFailures + length skippedRows
                , dead = deadCount
                , haltedOn = halted
                }

    markFailed :: UTCTime -> (OutboxRow, Text) -> Tx.Transaction OutboxStatus
    markFailed now (row, errMsg) =
        markOutboxFailedTx
            (row ^. #outboxId)
            errMsg
            (options ^. #maxAttempts)
            (nextDelay (options ^. #backoff) (row ^. #attemptCount))
            now

    markSkipped :: UTCTime -> OutboxRow -> Tx.Transaction ()
    markSkipped now row =
        markOutboxSkippedTx
            (row ^. #outboxId)
            "skipped: earlier record for the same key failed"
            now

{- | Reclaim crashed publisher rows and record the outbox backlog gauge.

Schedule this pass independently from 'publishClaimedOutbox', typically on a
slower timer. It is the only library worker path that reclaims rows stranded in
@publishing@.
-}
outboxMaintenancePass ::
    (IOE :> es, Store :> es) =>
    OutboxMaintenanceOptions ->
    Maybe KeiroMetrics ->
    Eff es OutboxMaintenanceSummary
outboxMaintenancePass options mMetrics = do
    now <- liftIO getCurrentTime
    (requeued, deadLettered) <-
        requeueStuckOutbox
            (options ^. #maxAttempts)
            (options ^. #publishingTimeout)
            now
    recordOutboxReclaimed mMetrics (fromIntegral requeued)
    recordOutboxDeadlettered mMetrics (fromIntegral deadLettered)
    backlog <- countOutboxBacklog
    recordOutboxBacklog mMetrics (fromIntegral backlog)
    pure OutboxMaintenanceSummary{requeued, deadLettered, backlog}

-- | Count publishable rows and record the outbox backlog gauge when metrics are enabled.
sampleOutboxBacklog :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> Eff es ()
sampleOutboxBacklog Nothing = pure ()
sampleOutboxBacklog (Just metrics) = do
    backlog <- countOutboxBacklog
    recordOutboxBacklog (Just metrics) (fromIntegral backlog)

data OutcomeMarks = OutcomeMarks
    { sentIds :: ![OutboxId]
    , failedRows :: ![(OutboxRow, Text)]
    , skippedRows :: ![OutboxRow]
    }
    deriving stock (Generic)

instance Semigroup OutcomeMarks where
    left <> right =
        OutcomeMarks
            { sentIds = (left ^. #sentIds) <> (right ^. #sentIds)
            , failedRows = (left ^. #failedRows) <> (right ^. #failedRows)
            , skippedRows = (left ^. #skippedRows) <> (right ^. #skippedRows)
            }

instance Monoid OutcomeMarks where
    mempty = OutcomeMarks{sentIds = [], failedRows = [], skippedRows = []}

groupMarks :: Map.Map OutboxId PublishOutcome -> [OutboxRow] -> OutcomeMarks
groupMarks outcomes = go []
  where
    go sent [] = mempty{sentIds = sent}
    go sent (row : rest) =
        case fromMaybe (PublishFailed "publisher returned no outcome") (Map.lookup (row ^. #outboxId) outcomes) of
            PublishSucceeded -> go (sent <> [row ^. #outboxId]) rest
            PublishFailed errMsg ->
                OutcomeMarks
                    { sentIds = sent
                    , failedRows = [(row, errMsg)]
                    , skippedRows = rest
                    }

data OutcomeGroupKey
    = BatchGroup
    | SourceGroup !Text
    | RowGroup !OutboxId
    | KeyGroup !Text !Text
    deriving stock (Generic, Eq)

data OutcomeGroup = OutcomeGroup
    { groupKey :: !OutcomeGroupKey
    , groupRows :: ![OutboxRow]
    }
    deriving stock (Generic)

outcomeGroups :: OrderingPolicy -> [OutboxRow] -> [[OutboxRow]]
outcomeGroups policy =
    fmap (^. #groupRows) . foldl' addGroup []
  where
    addGroup groups row =
        appendGroup (keyFor row) row groups
    keyFor row =
        case policy of
            -- A claimed batch can hold runs from several independent sources;
            -- a failure in one source's run must not skip another source's rows.
            PerSourceStream -> SourceGroup (row ^. #event . #source)
            -- Deliberately one group: any failure halts the worker, and the
            -- entire remaining batch is skipped without consuming attempts.
            StopTheLine -> BatchGroup
            BestEffort -> RowGroup (row ^. #outboxId)
            _ ->
                case row ^. #event . #key of
                    Nothing -> RowGroup (row ^. #outboxId)
                    Just key -> KeyGroup (row ^. #event . #source) key

appendGroup :: OutcomeGroupKey -> OutboxRow -> [OutcomeGroup] -> [OutcomeGroup]
appendGroup key row [] = [OutcomeGroup{groupKey = key, groupRows = [row]}]
appendGroup key row (group : rest)
    | group ^. #groupKey == key =
        (group & #groupRows %~ (<> [row])) : rest
    | otherwise =
        group : appendGroup key row rest
