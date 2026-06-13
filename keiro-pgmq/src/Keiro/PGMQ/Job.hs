{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}
-- @enqueue@/@enqueueWithDelay@ carry an @IOE :> es@ constraint that the @Pgmq@
-- send operation does not strictly require. It is kept deliberately: it is part
-- of the published @keiro-pgmq@ contract (mirrored in the MasterPlan's
-- Integration Points and depended on by the two consumer migrations), and it
-- keeps the producer signatures uniform with the processor/runner ones. We
-- therefore silence the otherwise-correct redundant-constraint warning here.
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

{- | Layer 2 of @keiro-pgmq@: the typed-'Job' ergonomics built on top of
'Keiro.PGMQ.Runtime'. This is the payoff layer that absorbs the boilerplate two
real apps wrote by hand.

An application declares a 'Job' value bundling a queue ('Keiro.PGMQ.Runtime.QueueRef'),
a payload codec ('Keiro.PGMQ.Codec.JobCodec'), and a 'RetryPolicy'; then writes
a plain domain handler of type @p -> Eff es 'JobOutcome'@ that never touches
shibuya's @Ingested@/@AckDecision@ or PGMQ's wire types. The package provides:

  * 'enqueue' / 'enqueueWithDelay' — producers.
  * 'ensureJobQueue' — idempotent main-queue + DLQ creation.
  * 'jobProcessor' — build a shibuya processor from a 'Job' plus a handler.
  * 'runJobWorkers' — continuous, multi-processor supervised run (the @rei@ cadence).
  * 'runJobOnce' — one-shot drain of up to @n@ messages (the @hospital-capacity@ cadence).

== Delivery and crash semantics

Delivery is at-least-once. A handler must be idempotent because the same message
can be delivered again after a worker crash, a handler exception, or a visibility
timeout expiry. Crash redelivery cadence is the active visibility timeout, not
the 'RetryPolicy' delay; the policy delay applies only to explicit 'Retry' and
'RetryDefault' outcomes. Every visibility-timeout expiry consumes one PGMQ
@read_ct@ attempt, and messages whose read count exceeds 'maxRetries' are
dead-lettered before the handler sees them.

Dead-lettering sends a DLQ row and then deletes the main-queue row, so a crash
between those two statements can leave the message in both places. 'redriveDlq'
has the same at-least-once window in the other direction: it sends the preserved
payload back to the main queue and then deletes the DLQ row.

Known limitation, pending
docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md:
a transient database error during 'runJobWorkers' polling can terminate the
worker's polling loop permanently and silently. Until that upstream plan lands,
monitor queue depth externally and restart workers on alert.
-}
module Keiro.PGMQ.Job (
    -- * Job declaration
    JobOutcome (..),
    RetryDelay (..),
    RetryPolicy (..),
    RetryPolicyConfigError (..),
    mkRetryPolicy,
    defaultRetryPolicy,
    Job (..),
    JobPolling (..),
    JobOrdering (..),
    JobTuning (..),
    JobTuningConfigError (..),
    mkJobTuning,
    defaultJobTuning,
    withOrdering,

    -- * Message metadata
    MessageHeaders (..),

    -- * Producing work
    enqueue,
    enqueueWithDelay,
    enqueueWithHeaders,
    enqueueWithHeadersAndDelay,
    enqueueBatch,
    enqueueBatchWithDelay,
    enqueueBatchWithHeaders,
    enqueueTraced,
    enqueueTracedWithDelay,
    enqueueToGroup,
    enqueueToGroupWithDelay,

    -- * Queue lifecycle
    QueueKind (..),
    PartitionSpec (..),
    QueueProvision (..),
    standardProvision,
    unloggedProvision,
    partitionedProvision,
    withFifoIndexProvision,
    queueProvisionConfigs,
    ensureJobQueue,
    ensureJobQueueWith,
    ensureFifoIndex,
    ensureOrderedJobQueue,

    -- * Consuming work
    JobContext (..),
    jobProcessorWithContext,
    jobProcessor,
    runJobWorkers,
    runJobOnceWithContext,
    runJobOnce,
) where

import Keiro.PGMQ.Codec (JobCodec, JobDecodeError (..), decodeJob, encodeJob)
import Keiro.PGMQ.Runtime (QueueRef (..))
import "aeson" Data.Aeson (Value, object, (.=))
import "base" Control.Exception (SomeException)
import "base" Control.Monad (foldM, void)
import "base" Data.Int (Int32, Int64)
import "effectful-core" Effectful (Eff, IOE, liftIO, (:>))
import "effectful-core" Effectful.Exception qualified as EffException
import "hs-opentelemetry-api" OpenTelemetry.Context.ThreadLocal (getContext)
import "hs-opentelemetry-api" OpenTelemetry.Trace.Core (TracerProvider)
import "pgmq-config" Pgmq.Config.Effectful (ensureQueuesEff)
import "pgmq-config" Pgmq.Config.Types qualified as Config
import "pgmq-effectful" Pgmq.Effectful (
    BatchSendMessage (..),
    BatchSendMessageWithHeaders (..),
    Message (..),
    MessageBody (..),
    MessageHeaders (..),
    MessageId,
    MessageQuery (..),
    Pgmq,
    ReadMessage (..),
    SendMessage (..),
    SendMessageWithHeaders (..),
    VisibilityTimeoutQuery (..),
    injectTraceContext,
    mergeTraceHeaders,
 )
import "pgmq-effectful" Pgmq.Effectful qualified as Pgmq
import "pgmq-effectful" Pgmq.Effectful.Effect (readGrouped, readGroupedRoundRobin)
import "pgmq-hasql" Pgmq.Hasql.Statements.Types (ReadGrouped (..))
import "shibuya-core" Shibuya.App (
    AppError,
    AppHandle,
    ProcessorId (..),
    QueueProcessor,
    SupervisionStrategy,
    mkProcessor,
    runApp,
 )
import "shibuya-core" Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import "shibuya-core" Shibuya.Core.Ingested (Ingested (..))
import "shibuya-core" Shibuya.Core.Lease (Lease (..))
import "shibuya-core" Shibuya.Core.Types (Attempt (..), Envelope (..))
import "shibuya-core" Shibuya.Telemetry.Effect (Tracing)
import "shibuya-pgmq-adapter" Shibuya.Adapter.Pgmq (
    FifoConfig (..),
    FifoReadStrategy (..),
    PgmqAdapterConfig (..),
    PollingConfig (..),
    defaultConfig,
    directDeadLetter,
    pgmqAdapter,
 )
import "shibuya-pgmq-adapter" Shibuya.Adapter.Pgmq.Convert (
    mkDlqPayload,
    pgmqMessageToEnvelope,
 )
import "text" Data.Text (Text)
import "time" Data.Time (NominalDiffTime, nominalDiffTimeToSeconds)

-- | What a job handler decides. Never exposes shibuya/PGMQ wire types to the caller.
data JobOutcome
    = -- | Processed successfully; delete the message from the queue.
      Done
    | -- | Leave the message on the queue; redeliver after the delay.
      Retry !RetryDelay
    | -- | Leave the message on the queue; redeliver after the policy's default retry delay.
      RetryDefault
    | -- | Poison message; route to the dead-letter queue when enabled, otherwise archive it, with this reason.
      Dead !Text
    deriving stock (Show)

{- | How a queue retries and dead-letters.

The raw constructor is exported for advanced/manual configuration, but it is
not validated. Prefer 'mkRetryPolicy': @maxRetries <= 0@ dead-letters every
message before the handler runs because PGMQ's @read_ct@ is 1 on first delivery
and the adapter auto-dead-letters when @read_ct > maxRetries@. Negative retry
delays can create immediate redelivery storms.

'maxRetries' is the number of
deliveries PGMQ allows before auto-dead-lettering; 'defaultRetryDelay' is a
convenience default a handler can reach for; 'useDeadLetter' decides whether a
DLQ is created and routed to at all.
-}
data RetryPolicy = RetryPolicy
    { maxRetries :: !Int64
    , defaultRetryDelay :: !RetryDelay
    , useDeadLetter :: !Bool
    }
    deriving stock (Eq, Show)

data RetryPolicyConfigError
    = NonPositiveMaxRetries !Int64
    | NegativeRetryDelay !RetryDelay
    deriving stock (Eq, Show)

mkRetryPolicy :: Int64 -> RetryDelay -> Bool -> Either RetryPolicyConfigError RetryPolicy
mkRetryPolicy maxRetries defaultRetryDelay useDeadLetter
    | maxRetries < 1 = Left (NonPositiveMaxRetries maxRetries)
    | retryDelaySeconds defaultRetryDelay < 0 = Left (NegativeRetryDelay defaultRetryDelay)
    | otherwise =
        Right
            RetryPolicy
                { maxRetries
                , defaultRetryDelay
                , useDeadLetter
                }

-- | Five deliveries, a 60-second default retry delay, and a DLQ enabled.
defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy =
    RetryPolicy
        { maxRetries = 5
        , defaultRetryDelay = RetryDelay 60
        , useDeadLetter = True
        }

data JobPolling
    = -- | Sleep this long between empty polls.
      PollEvery !NominalDiffTime
    | -- | Long-poll inside the database: max seconds to wait, then check interval in milliseconds.
      LongPoll !Int32 !Int32
    deriving stock (Eq, Show)

{- | How a consumer orders deliveries.

'Unordered' is the historical behavior: PGMQ's plain @read@, FIFO only in
selection order (@msg_id@ ascending), with NO per-key delivery-order guarantee
under concurrent workers, retries, or visibility-timeout expiry.

'FifoThroughput' and 'FifoRoundRobin' enable strict per-group ordering via PGMQ
message groups (the reserved @x-pgmq-group@ header). Within one group, messages
are delivered in strict send order; distinct groups proceed in parallel.
'FifoThroughput' fills a batch from the oldest eligible group first (SQS-style,
@read_grouped@); 'FifoRoundRobin' interleaves fairly across groups
(@read_grouped_rr@). Delivery is still at-least-once and there is no
deduplication, so handlers must be idempotent.
-}
data JobOrdering
    = Unordered
    | FifoThroughput
    | FifoRoundRobin
    deriving stock (Eq, Show)

{- | How a consumer reads the queue.

The raw constructor is exported but not validated. Prefer 'mkJobTuning' so
visibility timeouts, batch sizes, and polling intervals are positive.
-}
data JobTuning = JobTuning
    { visibilityTimeout :: !Int32
    , batchSize :: !Int32
    , polling :: !JobPolling
    , ordering :: !JobOrdering
    }
    deriving stock (Eq, Show)

-- | 30 s visibility timeout, batch of 1, 1 s standard polling, unordered reads.
defaultJobTuning :: JobTuning
defaultJobTuning =
    JobTuning
        { visibilityTimeout = 30
        , batchSize = 1
        , polling = PollEvery 1
        , ordering = Unordered
        }

data JobTuningConfigError
    = NonPositiveVisibilityTimeout !Int32
    | NonPositiveBatchSize !Int32
    | NonPositivePollInterval
    deriving stock (Eq, Show)

mkJobTuning :: Int32 -> Int32 -> JobPolling -> Either JobTuningConfigError JobTuning
mkJobTuning visibilityTimeout batchSize polling
    | visibilityTimeout < 1 = Left (NonPositiveVisibilityTimeout visibilityTimeout)
    | batchSize < 1 = Left (NonPositiveBatchSize batchSize)
    | not (validPolling polling) = Left NonPositivePollInterval
    | otherwise = Right JobTuning{visibilityTimeout, batchSize, polling, ordering = Unordered}

{- | Set the FIFO read strategy on an existing tuning, e.g.
@withOrdering FifoThroughput defaultJobTuning@. Every 'JobOrdering' value is
valid, so this is a plain record update rather than a validating constructor.
-}
withOrdering :: JobOrdering -> JobTuning -> JobTuning
withOrdering o tuning = tuning{ordering = o}

validPolling :: JobPolling -> Bool
validPolling (PollEvery interval) = interval > 0
validPolling (LongPoll maxPollSeconds pollIntervalMs) =
    maxPollSeconds > 0 && pollIntervalMs > 0

toPollingConfig :: JobPolling -> PollingConfig
toPollingConfig (PollEvery interval) = StandardPolling interval
toPollingConfig (LongPoll maxPollSeconds pollIntervalMs) = LongPolling maxPollSeconds pollIntervalMs

-- | Map an ordering choice to the shibuya adapter's FIFO read config (worker path).
toFifoConfig :: JobOrdering -> Maybe FifoConfig
toFifoConfig Unordered = Nothing
toFifoConfig FifoThroughput = Just (FifoConfig ThroughputOptimized)
toFifoConfig FifoRoundRobin = Just (FifoConfig RoundRobin)

retryDelaySeconds :: RetryDelay -> NominalDiffTime
retryDelaySeconds (RetryDelay seconds) = seconds

nominalToSeconds :: NominalDiffTime -> Int32
nominalToSeconds dt =
    let seconds :: Double
        seconds = realToFrac (nominalDiffTimeToSeconds dt)
        maxSec :: Double
        maxSec = fromIntegral (maxBound :: Int32)
        minSec :: Double
        minSec = fromIntegral (minBound :: Int32)
        clamped = max minSec (min maxSec seconds)
     in ceiling clamped

{- | A declarative job: a queue, a payload codec, and a retry policy, named for
telemetry. Construct one and pair it with a handler of type
@p -> Eff es 'JobOutcome'@.
-}
data Job p = Job
    { jobName :: !Text
    -- ^ Used as the shibuya 'ProcessorId' and telemetry label.
    , jobQueue :: !QueueRef
    , jobCodec :: !(JobCodec p)
    , jobPolicy :: !RetryPolicy
    }

-- | Per-delivery capabilities handed to context-aware handlers.
data JobContext es = JobContext
    { extendLease :: !(NominalDiffTime -> Eff es ())
    -- ^ Push the message's visibility timeout further into the future.
    , attempt :: !(Maybe Word)
    -- ^ Zero-based delivery attempt; @Just 0@ is the first delivery.
    , headers :: !(Maybe Value)
    {- ^ Drain path: the raw PGMQ message header object (@Just@ when the
    message carried headers, @Nothing@ otherwise). Worker path: always
    @Nothing@, because the shibuya adapter's @Envelope@ does not surface
    arbitrary headers (only the trace context, which shibuya itself uses
    to continue the trace).
    -}
    }

-- | Producer: encode @p@ with the job's codec and send it to the queue, no delay.
enqueue :: (Pgmq :> es, IOE :> es) => Job p -> p -> Eff es MessageId
enqueue job p =
    Pgmq.sendMessage
        SendMessage
            { queueName = job.jobQueue.physicalName
            , messageBody = MessageBody (encodeJob job.jobCodec p)
            , delay = Nothing
            }

{- | Producer with an explicit visibility delay (in seconds, PGMQ's @Delay@ is
@Int32@) before first delivery.
-}
enqueueWithDelay :: (Pgmq :> es, IOE :> es) => Job p -> Int32 -> p -> Eff es MessageId
enqueueWithDelay job d p =
    Pgmq.sendMessage
        SendMessage
            { queueName = job.jobQueue.physicalName
            , messageBody = MessageBody (encodeJob job.jobCodec p)
            , delay = Just d
            }

{- | Producer that attaches caller-supplied message headers (an arbitrary JSON
object) alongside the encoded payload. Headers ride in PGMQ's @headers@ column
and are readable by the consumer (see 'JobContext'\'s @headers@ field on the
drain path).

The headers are passed through verbatim. In particular the reserved FIFO group
key @x-pgmq-group@ is neither reserved, injected, stripped, nor rewritten, so a
caller (or a sibling plan building ordered delivery) may set it freely.
-}
enqueueWithHeaders ::
    (Pgmq :> es, IOE :> es) => Job p -> MessageHeaders -> p -> Eff es MessageId
enqueueWithHeaders job hdrs p =
    Pgmq.sendMessageWithHeaders
        SendMessageWithHeaders
            { queueName = job.jobQueue.physicalName
            , messageBody = MessageBody (encodeJob job.jobCodec p)
            , messageHeaders = hdrs
            , delay = Nothing
            }

{- | 'enqueueWithHeaders' with an explicit visibility delay (in seconds) before
first delivery.
-}
enqueueWithHeadersAndDelay ::
    (Pgmq :> es, IOE :> es) => Job p -> Int32 -> MessageHeaders -> p -> Eff es MessageId
enqueueWithHeadersAndDelay job d hdrs p =
    Pgmq.sendMessageWithHeaders
        SendMessageWithHeaders
            { queueName = job.jobQueue.physicalName
            , messageBody = MessageBody (encodeJob job.jobCodec p)
            , messageHeaders = hdrs
            , delay = Just d
            }

{- | Batch producer: encode and enqueue many payloads in a single database
round-trip, returning one 'MessageId' per payload in order. An empty input
short-circuits to @[]@ and issues no statement.
-}
enqueueBatch :: (Pgmq :> es, IOE :> es) => Job p -> [p] -> Eff es [MessageId]
enqueueBatch _ [] = pure []
enqueueBatch job ps =
    Pgmq.batchSendMessage
        BatchSendMessage
            { queueName = job.jobQueue.physicalName
            , messageBodies = map (MessageBody . encodeJob job.jobCodec) ps
            , delay = Nothing
            }

{- | 'enqueueBatch' with a single visibility delay (in seconds) applied to every
message in the batch.
-}
enqueueBatchWithDelay ::
    (Pgmq :> es, IOE :> es) => Job p -> Int32 -> [p] -> Eff es [MessageId]
enqueueBatchWithDelay _ _ [] = pure []
enqueueBatchWithDelay job d ps =
    Pgmq.batchSendMessage
        BatchSendMessage
            { queueName = job.jobQueue.physicalName
            , messageBodies = map (MessageBody . encodeJob job.jobCodec) ps
            , delay = Just d
            }

{- | Batch producer that attaches a distinct header object to each payload. The
input pairs each payload with its headers so the body and header lists cannot be
desynchronized. An empty input short-circuits to @[]@.
-}
enqueueBatchWithHeaders ::
    (Pgmq :> es, IOE :> es) => Job p -> [(MessageHeaders, p)] -> Eff es [MessageId]
enqueueBatchWithHeaders _ [] = pure []
enqueueBatchWithHeaders job pairs =
    Pgmq.batchSendMessageWithHeaders
        BatchSendMessageWithHeaders
            { queueName = job.jobQueue.physicalName
            , messageBodies = map (MessageBody . encodeJob job.jobCodec . snd) pairs
            , messageHeaders = map fst pairs
            , delay = Nothing
            }

{- | Producer that propagates the current OpenTelemetry trace context onto the
enqueued message so the handler runs inside the same trace. The current
thread-local context is injected to carrier headers via the provider's
configured propagator (W3C @traceparent@ by default) and additively merged onto
@extraHeaders@ — any key already present in @extraHeaders@ wins, so a
caller-set @x-pgmq-group@ survives. Pass @MessageHeaders (object [])@ to inject
only the trace.
-}
enqueueTraced ::
    (Pgmq :> es, IOE :> es) =>
    TracerProvider -> Job p -> MessageHeaders -> p -> Eff es MessageId
enqueueTraced provider job extraHeaders p = do
    ctx <- liftIO getContext
    traceHeaders <- injectTraceContext provider ctx
    let merged = MessageHeaders (mergeTraceHeaders traceHeaders (Just extraHeaders.unMessageHeaders))
    enqueueWithHeaders job merged p

{- | 'enqueueTraced' with an explicit visibility delay (in seconds) before first
delivery.
-}
enqueueTracedWithDelay ::
    (Pgmq :> es, IOE :> es) =>
    TracerProvider -> Job p -> Int32 -> MessageHeaders -> p -> Eff es MessageId
enqueueTracedWithDelay provider job d extraHeaders p = do
    ctx <- liftIO getContext
    traceHeaders <- injectTraceContext provider ctx
    let merged = MessageHeaders (mergeTraceHeaders traceHeaders (Just extraHeaders.unMessageHeaders))
    enqueueWithHeadersAndDelay job d merged p

{- | Enqueue a payload into the FIFO group named by @groupKey@. The group key is
written under the reserved @x-pgmq-group@ JSONB header, which PGMQ's grouped
reads and the shibuya adapter use to order deliveries per group. Consume with an
ordered 'JobTuning' (see 'withOrdering') to honor the order; within one group,
messages are handled in strict send order while distinct groups proceed in
parallel.
-}
enqueueToGroup ::
    (Pgmq :> es, IOE :> es) => Job p -> Text -> p -> Eff es MessageId
enqueueToGroup job groupKey p =
    enqueueWithHeaders job (groupHeader groupKey) p

-- | 'enqueueToGroup' with an explicit first-delivery delay (in seconds).
enqueueToGroupWithDelay ::
    (Pgmq :> es, IOE :> es) => Job p -> Int32 -> Text -> p -> Eff es MessageId
enqueueToGroupWithDelay job d groupKey p =
    enqueueWithHeadersAndDelay job d (groupHeader groupKey) p

-- | The reserved FIFO group header for a group key.
groupHeader :: Text -> MessageHeaders
groupHeader k = MessageHeaders (object ["x-pgmq-group" .= k])

{- | The three PostgreSQL storage shapes a job's main queue can take.

  * 'StandardKind' — a normal write-ahead-logged queue table (today's default).
  * 'UnloggedKind' — an /unlogged/ table: writes skip the WAL (faster) but the
    table is truncated to empty on a database crash. For transient, regenerable
    work.
  * 'PartitionedKind' — storage split across child tables by time or message-id
    range, managed by the PostgreSQL extension @pg_partman@. Requires a
    @pg_partman@-enabled server (see 'partitionedProvision').
-}
data QueueKind
    = StandardKind
    | UnloggedKind
    | PartitionedKind !PartitionSpec
    deriving stock (Eq, Show)

{- | Partition interval + retention interval for a partitioned queue. Both are
PostgreSQL/@pg_partman@ duration or integer strings — e.g. @"daily"@ or
@"10000"@ for the interval, @"7 days"@ or @"100000"@ for the retention.
-}
data PartitionSpec = PartitionSpec
    { partitionInterval :: !Text
    , retentionInterval :: !Text
    }
    deriving stock (Eq, Show)

{- | The provisioning choice for a job's /main/ queue: which storage shape, and
whether to create the FIFO GIN index. The DLQ (when the policy enables one) is
always a plain standard queue with no FIFO index.
-}
data QueueProvision = QueueProvision
    { provisionKind :: !QueueKind
    , provisionFifoIndex :: !Bool
    }
    deriving stock (Eq, Show)

-- | A standard main queue with no FIFO index — exactly today's behavior.
standardProvision :: QueueProvision
standardProvision = QueueProvision{provisionKind = StandardKind, provisionFifoIndex = False}

-- | An unlogged main queue with no FIFO index.
unloggedProvision :: QueueProvision
unloggedProvision = QueueProvision{provisionKind = UnloggedKind, provisionFifoIndex = False}

-- | A partitioned main queue (no FIFO index) with the given interval/retention.
partitionedProvision :: PartitionSpec -> QueueProvision
partitionedProvision spec =
    QueueProvision{provisionKind = PartitionedKind spec, provisionFifoIndex = False}

-- | Turn on FIFO-index creation for a provisioning choice.
withFifoIndexProvision :: QueueProvision -> QueueProvision
withFifoIndexProvision provision = provision{provisionFifoIndex = True}

{- | Pure: the list of @pgmq-config@ 'Config.QueueConfig's that
'ensureJobQueueWith' will reconcile — the main queue first (with its chosen kind
and optional FIFO index), then the DLQ (always a standard queue) when the policy
enables one. Exposed so the partitioned path is testable without a
@pg_partman@-enabled database.
-}
queueProvisionConfigs :: QueueProvision -> Job p -> [Config.QueueConfig]
queueProvisionConfigs provision job =
    mainConfig : dlqConfigs
  where
    mainBase =
        case provision.provisionKind of
            StandardKind -> Config.standardQueue job.jobQueue.physicalName
            UnloggedKind -> Config.unloggedQueue job.jobQueue.physicalName
            PartitionedKind spec ->
                Config.partitionedQueue
                    job.jobQueue.physicalName
                    Config.PartitionConfig
                        { Config.partitionInterval = spec.partitionInterval
                        , Config.retentionInterval = spec.retentionInterval
                        }
    mainConfig
        | provision.provisionFifoIndex = Config.withFifoIndex mainBase
        | otherwise = mainBase
    dlqConfigs
        | job.jobPolicy.useDeadLetter = [Config.standardQueue job.jobQueue.dlqName]
        | otherwise = []

{- | Idempotent: create the job's main queue with the chosen storage kind and
(optionally) its FIFO index, plus the DLQ (always a standard queue) when the
policy uses one. Routes through @pgmq-config@'s additive reconciler, which lists
existing queues first and only creates what is missing, so this is safe to call
at every worker startup.
-}
ensureJobQueueWith :: (Pgmq :> es) => QueueProvision -> Job p -> Eff es ()
ensureJobQueueWith provision job =
    ensureQueuesEff (queueProvisionConfigs provision job)

{- | Idempotent: create the main queue, and the DLQ too when the policy uses
one. Unchanged behavior: @ensureJobQueueWith standardProvision@. Safe to call at
every worker startup.
-}
ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
ensureJobQueue = ensureJobQueueWith standardProvision

{- | Create the FIFO GIN index on the job's /main/ queue's @headers@ column —
the index PGMQ's grouped/ordered reads (@read_grouped@/@read_grouped_rr@) match
against. Idempotent: the index step is always re-applied and the underlying SQL
is @CREATE INDEX IF NOT EXISTS@, so a second call is a harmless no-op. Routing
through @pgmq-config@'s reconciler (which lists existing queues first) means
calling this on an already-provisioned queue does not recreate the queue. This
is the artifact the FIFO ordered-delivery plan
(@docs/plans/77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md@)
consumes for ordered jobs.
-}
ensureFifoIndex :: (Pgmq :> es) => Job p -> Eff es ()
ensureFifoIndex job =
    ensureQueuesEff
        [Config.withFifoIndex (Config.standardQueue job.jobQueue.physicalName)]

{- | Provision an ordered job's queue: create the main queue (and the DLQ when
the policy uses one) plus the FIFO GIN index that grouped reads need. Composes
'ensureJobQueue' and 'ensureFifoIndex'; both are idempotent, so this is safe to
call at every startup.
-}
ensureOrderedJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
ensureOrderedJobQueue job = do
    ensureJobQueue job
    ensureFifoIndex job

{- | Build the shibuya PGMQ adapter config from a job's queue and policy: route
to the DLQ via the adapter's @directDeadLetter@ path when the policy enables it.
-}
adapterConfigFor :: JobTuning -> Job p -> PgmqAdapterConfig
adapterConfigFor tuning job =
    (defaultConfig job.jobQueue.physicalName)
        { visibilityTimeout = tuning.visibilityTimeout
        , batchSize = tuning.batchSize
        , polling = toPollingConfig tuning.polling
        , fifoConfig = toFifoConfig tuning.ordering
        , maxRetries = job.jobPolicy.maxRetries
        , deadLetterConfig =
            if job.jobPolicy.useDeadLetter
                then Just (directDeadLetter job.jobQueue.dlqName True)
                else Nothing
        }

{- | The boilerplate this package absorbs once: decode the raw JSON payload with
the job's codec, run the domain handler, and translate its 'JobOutcome' into a
shibuya 'AckDecision'. A payload the codec rejects is dead-lettered.
-}
wrapHandler ::
    Job p ->
    (JobContext es -> p -> Eff es JobOutcome) ->
    (Ingested es Value -> Eff es AckDecision)
wrapHandler job handle ingested =
    case decodeJob job.jobCodec ingested.envelope.payload of
        Left (JobPayloadFromFuture _payloadVersion _workerVersion) ->
            pure (AckRetry job.jobPolicy.defaultRetryDelay)
        Left (JobPayloadMalformed err) ->
            pure (AckDeadLetter (InvalidPayload err))
        Right p -> toAck <$> handle (contextFor ingested) p
  where
    contextFor message =
        JobContext
            { extendLease = maybe (\_ -> pure ()) (.leaseExtend) message.lease
            , attempt = fmap (.unAttempt) message.envelope.attempt
            , headers = Nothing
            }

    toAck Done = AckOk
    toAck (Retry d) = AckRetry d
    toAck RetryDefault = AckRetry job.jobPolicy.defaultRetryDelay
    toAck (Dead why) = AckDeadLetter (PoisonPill why)

{- | Build a shibuya processor for a job with explicit tuning and a context-aware
handler. The handler must finish, or call 'extendLease', before
'visibilityTimeout' expires; otherwise PGMQ may redeliver the message
concurrently and each redelivery consumes one retry attempt. After a worker
crash, redelivery happens when the visibility timeout expires; the 'RetryPolicy'
delay only governs explicit 'Retry' and 'RetryDefault' outcomes.
-}
jobProcessorWithContext ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    JobTuning ->
    Job p ->
    (JobContext es -> p -> Eff es JobOutcome) ->
    Eff es (ProcessorId, QueueProcessor es)
jobProcessorWithContext tuning job handle = do
    adapter <- pgmqAdapter (adapterConfigFor tuning job)
    pure (ProcessorId job.jobName, mkProcessor adapter (wrapHandler job handle))

{- | Build a shibuya processor for a job using 'defaultJobTuning': a PGMQ adapter
configured from the job's policy, paired with the wrapped handler. Pass the
result to 'runJobWorkers'. The same visibility-timeout and crash-redelivery
rules documented on 'jobProcessorWithContext' apply here.
-}
jobProcessor ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    Job p ->
    (p -> Eff es JobOutcome) ->
    Eff es (ProcessorId, QueueProcessor es)
jobProcessor job handle =
    jobProcessorWithContext defaultJobTuning job (\_context p -> handle p)

{- | Continuous, multi-processor run (the @rei@ cadence): run a supervised app
over several processors built with 'jobProcessor'. Returns the app handle; the
caller decides whether to block on it. The inbox size is clamped to at least 1.
-}
runJobWorkers ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    SupervisionStrategy ->
    Int ->
    [Eff es (ProcessorId, QueueProcessor es)] ->
    Eff es (Either AppError (AppHandle es))
runJobWorkers strategy inboxSize procs = do
    ps <- sequence procs
    runApp strategy (max 1 inboxSize) ps

{- | One-shot drain of up to @n@ messages with explicit tuning and a
context-aware handler. This reads directly from PGMQ and returns when the queue
is empty or @n@ messages have been acknowledged/retried/dead-lettered,
whichever comes first.

If a handler throws, the message is left on the main queue and remains invisible
until the active visibility timeout expires; the drain keeps processing the rest
of the batch and does not count that message in the returned total.
-}
runJobOnceWithContext ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    JobTuning ->
    Int ->
    Job p ->
    (JobContext es -> p -> Eff es JobOutcome) ->
    Eff es Int
runJobOnceWithContext tuning n job handle
    | n <= 0 = pure 0
    | otherwise = drain 0
  where
    drain handled
        | handled >= n = pure handled
        | otherwise = do
            let qty = nextBatchSize (n - handled)
            messages <- case tuning.ordering of
                Unordered ->
                    Pgmq.readMessage
                        ReadMessage
                            { queueName = job.jobQueue.physicalName
                            , delay = tuning.visibilityTimeout
                            , batchSize = Just qty
                            , conditional = Nothing
                            }
                FifoThroughput ->
                    readGrouped
                        ReadGrouped
                            { queueName = job.jobQueue.physicalName
                            , visibilityTimeout = tuning.visibilityTimeout
                            , qty = qty
                            }
                FifoRoundRobin ->
                    readGroupedRoundRobin
                        ReadGrouped
                            { queueName = job.jobQueue.physicalName
                            , visibilityTimeout = tuning.visibilityTimeout
                            , qty = qty
                            }
            if null messages
                then pure handled
                else do
                    handledInBatch <- foldM step 0 messages
                    drain (handled + handledInBatch)

    nextBatchSize remaining =
        fromIntegral (min remaining (fromIntegral tuning.batchSize :: Int))

    step count message = do
        disposed <- processMessage message
        pure $
            if disposed
                then count + 1
                else count

    processMessage message
        | message.readCount > job.jobPolicy.maxRetries = do
            ackMessage message (AckDeadLetter MaxRetriesExceeded)
            pure True
        | otherwise =
            case decodeJob job.jobCodec (messagePayload message) of
                Left (JobPayloadFromFuture _payloadVersion _workerVersion) -> do
                    ackMessage message (AckRetry job.jobPolicy.defaultRetryDelay)
                    pure True
                Left (JobPayloadMalformed err) -> do
                    ackMessage message (AckDeadLetter (InvalidPayload err))
                    pure True
                Right p -> do
                    outcome <- EffException.try @SomeException (handle (contextFor message) p)
                    case outcome of
                        Left _handlerException ->
                            pure False
                        Right jobOutcome -> do
                            ackMessage message (outcomeToAck jobOutcome)
                            pure True

    messagePayload = (.payload) . pgmqMessageToEnvelope

    contextFor message =
        let envelope = pgmqMessageToEnvelope message
         in JobContext
                { extendLease = \duration ->
                    void $
                        Pgmq.changeVisibilityTimeout
                            VisibilityTimeoutQuery
                                { queueName = job.jobQueue.physicalName
                                , messageId = message.messageId
                                , visibilityTimeoutOffset = nominalToSeconds duration
                                }
                , attempt = fmap (.unAttempt) envelope.attempt
                , headers = message.headers
                }

    outcomeToAck Done = AckOk
    outcomeToAck (Retry d) = AckRetry d
    outcomeToAck RetryDefault = AckRetry job.jobPolicy.defaultRetryDelay
    outcomeToAck (Dead why) = AckDeadLetter (PoisonPill why)

    ackMessage message AckOk =
        void $
            Pgmq.deleteMessage
                MessageQuery
                    { queueName = job.jobQueue.physicalName
                    , messageId = message.messageId
                    }
    ackMessage message (AckRetry delay) =
        void $
            Pgmq.changeVisibilityTimeout
                VisibilityTimeoutQuery
                    { queueName = job.jobQueue.physicalName
                    , messageId = message.messageId
                    , visibilityTimeoutOffset = nominalToSeconds (retryDelaySeconds delay)
                    }
    ackMessage message (AckDeadLetter reason)
        | job.jobPolicy.useDeadLetter = do
            sendDlq message reason
            void $
                Pgmq.deleteMessage
                    MessageQuery
                        { queueName = job.jobQueue.physicalName
                        , messageId = message.messageId
                        }
        | otherwise =
            void $
                Pgmq.archiveMessage
                    MessageQuery
                        { queueName = job.jobQueue.physicalName
                        , messageId = message.messageId
                        }
    ackMessage message (AckHalt _reason) =
        void $
            Pgmq.changeVisibilityTimeout
                VisibilityTimeoutQuery
                    { queueName = job.jobQueue.physicalName
                    , messageId = message.messageId
                    , visibilityTimeoutOffset = 3600
                    }

    sendDlq message reason =
        case message.headers of
            Just headers ->
                void $
                    Pgmq.sendMessageWithHeaders
                        SendMessageWithHeaders
                            { queueName = job.jobQueue.dlqName
                            , messageBody = mkDlqPayload message reason True
                            , messageHeaders = MessageHeaders headers
                            , delay = Nothing
                            }
            Nothing ->
                void $
                    Pgmq.sendMessage
                        SendMessage
                            { queueName = job.jobQueue.dlqName
                            , messageBody = mkDlqPayload message reason True
                            , delay = Nothing
                            }

{- | One-shot drain of up to @n@ messages (the @hospital-capacity@ cadence):
read directly from PGMQ with 'defaultJobTuning', run the handler on each
available message, and return promptly when the queue is empty.
-}
runJobOnce ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    Int ->
    Job p ->
    (p -> Eff es JobOutcome) ->
    Eff es ()
runJobOnce n job handle =
    void $
        runJobOnceWithContext
            defaultJobTuning
            n
            job
            (\_context p -> handle p)
