{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
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
    JobTuning (..),
    JobTuningConfigError (..),
    mkJobTuning,
    defaultJobTuning,

    -- * Producing work
    enqueue,
    enqueueWithDelay,

    -- * Queue lifecycle
    ensureJobQueue,

    -- * Consuming work
    JobContext (..),
    jobProcessorWithContext,
    jobProcessor,
    runJobWorkers,
    runJobOnce,
) where

import Keiro.PGMQ.Codec (JobCodec, JobDecodeError (..), decodeJob, encodeJob)
import Keiro.PGMQ.Runtime (QueueRef (..))
import "aeson" Data.Aeson (Value)
import "base" Control.Monad (when)
import "base" Data.Int (Int32, Int64)
import "effectful-core" Effectful (Eff, IOE, (:>))
import "pgmq-effectful" Pgmq.Effectful (MessageBody (..), MessageId, Pgmq, SendMessage (..))
import "pgmq-effectful" Pgmq.Effectful qualified as Pgmq
import "shibuya-core" Shibuya.Adapter (Adapter (..))
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
import "shibuya-core" Shibuya.Runner.Supervised (runWithMetrics)
import "shibuya-core" Shibuya.Telemetry.Effect (Tracing)
import "shibuya-pgmq-adapter" Shibuya.Adapter.Pgmq (
    PgmqAdapterConfig (..),
    PollingConfig (..),
    defaultConfig,
    directDeadLetter,
    pgmqAdapter,
 )
import "streamly-core" Streamly.Data.Stream qualified as Stream
import "text" Data.Text (Text)
import "time" Data.Time (NominalDiffTime)

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

{- | How a consumer reads the queue.

The raw constructor is exported but not validated. Prefer 'mkJobTuning' so
visibility timeouts, batch sizes, and polling intervals are positive.
-}
data JobTuning = JobTuning
    { visibilityTimeout :: !Int32
    , batchSize :: !Int32
    , polling :: !JobPolling
    }
    deriving stock (Eq, Show)

-- | 30 s visibility timeout, batch of 1, 1 s standard polling.
defaultJobTuning :: JobTuning
defaultJobTuning =
    JobTuning
        { visibilityTimeout = 30
        , batchSize = 1
        , polling = PollEvery 1
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
    | otherwise = Right JobTuning{visibilityTimeout, batchSize, polling}

validPolling :: JobPolling -> Bool
validPolling (PollEvery interval) = interval > 0
validPolling (LongPoll maxPollSeconds pollIntervalMs) =
    maxPollSeconds > 0 && pollIntervalMs > 0

toPollingConfig :: JobPolling -> PollingConfig
toPollingConfig (PollEvery interval) = StandardPolling interval
toPollingConfig (LongPoll maxPollSeconds pollIntervalMs) = LongPolling maxPollSeconds pollIntervalMs

retryDelaySeconds :: RetryDelay -> NominalDiffTime
retryDelaySeconds (RetryDelay seconds) = seconds

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

{- | Idempotent: create the main queue, and the DLQ too when the policy uses
one. @Pgmq.createQueue@ is idempotent in PGMQ, so this is safe to call at every
worker startup.
-}
ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
ensureJobQueue job = do
    Pgmq.createQueue job.jobQueue.physicalName
    when job.jobPolicy.useDeadLetter $
        Pgmq.createQueue job.jobQueue.dlqName

{- | Build the shibuya PGMQ adapter config from a job's queue and policy: route
to the DLQ via the adapter's @directDeadLetter@ path when the policy enables it.
-}
adapterConfigFor :: JobTuning -> Job p -> PgmqAdapterConfig
adapterConfigFor tuning job =
    (defaultConfig job.jobQueue.physicalName)
        { visibilityTimeout = tuning.visibilityTimeout
        , batchSize = tuning.batchSize
        , polling = toPollingConfig tuning.polling
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

{- | One-shot drain of up to @n@ messages (the @hospital-capacity@ cadence):
build the job's adapter, take @n@ messages from its source stream, and run the
wrapped handler over each (auto-acking via the returned 'AckDecision'), then
stop. The inbox size used by the underlying runner is clamped to at least 1.
-}
runJobOnce ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    Int ->
    Job p ->
    (p -> Eff es JobOutcome) ->
    Eff es ()
runJobOnce n job handle = do
    adapter <- pgmqAdapter (adapterConfigFor defaultJobTuning job)
    let limited = adapter{source = Stream.take n adapter.source}
    _ <-
        runWithMetrics
            (fromIntegral (max 1 n))
            (ProcessorId job.jobName)
            limited
            (wrapHandler job (\_context p -> handle p))
    pure ()
