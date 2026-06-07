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
    RetryPolicy (..),
    defaultRetryPolicy,
    Job (..),

    -- * Producing work
    enqueue,
    enqueueWithDelay,

    -- * Queue lifecycle
    ensureJobQueue,

    -- * Consuming work
    jobProcessor,
    runJobWorkers,
    runJobOnce,
) where

import Keiro.PGMQ.Codec (JobCodec, decodeJob, encodeJob)
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
import "shibuya-core" Shibuya.Core.Types (Envelope (..))
import "shibuya-core" Shibuya.Runner.Supervised (runWithMetrics)
import "shibuya-core" Shibuya.Telemetry.Effect (Tracing)
import "shibuya-pgmq-adapter" Shibuya.Adapter.Pgmq (
    PgmqAdapterConfig (..),
    defaultConfig,
    directDeadLetter,
    pgmqAdapter,
 )
import "streamly-core" Streamly.Data.Stream qualified as Stream
import "text" Data.Text (Text)

-- | What a job handler decides. Never exposes shibuya/PGMQ wire types to the caller.
data JobOutcome
    = -- | Processed successfully; delete the message from the queue.
      Done
    | -- | Leave the message on the queue; redeliver after the delay.
      Retry !RetryDelay
    | -- | Poison message; route to the dead-letter queue with this reason.
      Dead !Text
    deriving stock (Show)

{- | How a queue retries and dead-letters. 'maxRetries' is the number of
deliveries PGMQ allows before auto-dead-lettering; 'defaultRetryDelay' is a
convenience default a handler can reach for; 'useDeadLetter' decides whether a
DLQ is created and routed to at all.
-}
data RetryPolicy = RetryPolicy
    { maxRetries :: !Int64
    , defaultRetryDelay :: !RetryDelay
    , useDeadLetter :: !Bool
    }

-- | Five deliveries, a 60-second default retry delay, and a DLQ enabled.
defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy =
    RetryPolicy
        { maxRetries = 5
        , defaultRetryDelay = RetryDelay 60
        , useDeadLetter = True
        }

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
adapterConfigFor :: Job p -> PgmqAdapterConfig
adapterConfigFor job =
    (defaultConfig job.jobQueue.physicalName)
        { maxRetries = job.jobPolicy.maxRetries
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
    (p -> Eff es JobOutcome) ->
    (Ingested es Value -> Eff es AckDecision)
wrapHandler job handle ingested =
    case decodeJob job.jobCodec ingested.envelope.payload of
        Left err -> pure (AckDeadLetter (InvalidPayload err))
        Right p -> toAck <$> handle p
  where
    toAck Done = AckOk
    toAck (Retry d) = AckRetry d
    toAck (Dead why) = AckDeadLetter (PoisonPill why)

{- | Build a shibuya processor for a job: a PGMQ adapter configured from the
job's policy, paired with the wrapped handler. Pass the result to
'runJobWorkers'.
-}
jobProcessor ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    Job p ->
    (p -> Eff es JobOutcome) ->
    Eff es (ProcessorId, QueueProcessor es)
jobProcessor job handle = do
    adapter <- pgmqAdapter (adapterConfigFor job)
    pure (ProcessorId job.jobName, mkProcessor adapter (wrapHandler job handle))

{- | Continuous, multi-processor run (the @rei@ cadence): run a supervised app
over several processors built with 'jobProcessor'. Returns the app handle; the
caller decides whether to block on it.
-}
runJobWorkers ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    SupervisionStrategy ->
    Int ->
    [Eff es (ProcessorId, QueueProcessor es)] ->
    Eff es (Either AppError (AppHandle es))
runJobWorkers strategy inboxSize procs = do
    ps <- sequence procs
    runApp strategy inboxSize ps

{- | One-shot drain of up to @n@ messages (the @hospital-capacity@ cadence):
build the job's adapter, take @n@ messages from its source stream, and run the
wrapped handler over each (auto-acking via the returned 'AckDecision'), then
stop.
-}
runJobOnce ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    Int ->
    Job p ->
    (p -> Eff es JobOutcome) ->
    Eff es ()
runJobOnce n job handle = do
    adapter <- pgmqAdapter (adapterConfigFor job)
    let limited = adapter{source = Stream.take n adapter.source}
    _ <-
        runWithMetrics
            (fromIntegral (max 1 n))
            (ProcessorId job.jobName)
            limited
            (wrapHandler job handle)
    pure ()
