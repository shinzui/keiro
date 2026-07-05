{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

{- | End-to-end integration test for @keiro-pgmq@.

Uses @keiro-test-support@ to start one suite-level PostgreSQL server, installs
the PGMQ schema into the migrated template database, then gives every example a
fresh cloned database. The tests drive the package's public API against that
isolated database: 'enqueue' puts work on a queue, 'runJobOnce' drains it, and
we read the queue back through @pgmq-effectful@'s 'queueMetrics' to prove that a
@Done@ handler deletes the message, a @Retry@ handler leaves it, and a @Dead@
handler (or an undecodable payload) routes it to the dead-letter queue.
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, throwIO)
import Data.Aeson (FromJSON, ToJSON, Value (..), object, parseJSON, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Either (isRight)
import Data.Foldable (toList, traverse_)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Effectful.Reader.Static (Reader)
import GHC.Generics (Generic)
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Codec (EventType (..))
import Keiro.Codec qualified as CoreCodec
import Keiro.PGMQ
import Keiro.Test.Postgres qualified as Postgres
import OpenTelemetry.Context qualified as Ctxt
import OpenTelemetry.Context.ThreadLocal qualified as CtxtLocal
import OpenTelemetry.Propagator.W3CTraceContext qualified as W3C
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id.Generator.Default (defaultIdGenerator)
import Pgmq.Config.Types qualified as Config
import Pgmq.Effectful (Message (..), MessageBody (..), Pgmq, QueueMetrics (..), ReadMessage (..), SendMessage (..))
import Pgmq.Effectful qualified as Pgmq
import Pgmq.Migration qualified as Migration
import Pgmq.Types (QueueName, parseQueueName, queueNameToText)
import Shibuya.Adapter.Pgmq (PgmqAdapterEnv)
import Shibuya.App (AppHandle, ShutdownConfig (..), SupervisionStrategy (IgnoreFailures), stopAppGracefully)
import Shibuya.Telemetry.Effect (Tracing)
import System.Timeout (timeout)
import Test.Hspec

-- | A sample job payload defined entirely in the test.
data Ping = Ping
    { message :: Text
    , count :: Int
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

-- | The effect stack 'runJobEff' interprets.
type Stack = '[Reader PgmqAdapterEnv, Pgmq, Tracing, Error PgmqRuntimeError, IOE]

main :: IO ()
main =
    Postgres.withMigratedSuiteWith installPgmq \fixture ->
        hspec $
            describe "Keiro.PGMQ" $
                around (Postgres.withFreshDatabase fixture) spec

-- | Install the PGMQ schema into the ephemeral database via @pgmq-migration@.
installPgmq :: Text -> IO ()
installPgmq connStr =
    withPool connStr $ \pool -> do
        result <- Pool.use pool Migration.migrate
        case result of
            Left usageErr -> fail ("pgmq pool error during migration: " <> show usageErr)
            Right (Left migErr) -> fail ("pgmq migration error: " <> show migErr)
            Right (Right ()) -> pure ()

withPool :: Text -> (Pool -> IO a) -> IO a
withPool connStr =
    bracket
        ( Pool.acquire $
            Pool.Config.settings
                [Pool.Config.staticConnectionSettings (Conn.connectionString connStr)]
        )
        Pool.release

{- | Count the rows currently in a DLQ's archive table @pgmq.a_<dlqPhysical>@ via a
raw @hasql@ session. PGMQ exposes no "read the archive" function, so retention is
proven with plain SQL. The queue name is sanitized to @[a-z0-9_]@ by 'queueRef',
so interpolating it into the table identifier is safe here.
-}
archiveCount :: Text -> Text -> IO Int64
archiveCount connStr dlqPhysical =
    withPool connStr $ \pool -> do
        let sql = "SELECT count(*) FROM pgmq.a_" <> dlqPhysical
            session =
                Session.statement () $
                    Statement.preparable
                        sql
                        Encoders.noParams
                        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
        result <- Pool.use pool session
        either (\e -> fail ("archive count failed: " <> show e)) pure result

{- | Run a @Stack@ action against a fresh 'JobRuntime' (no tracer), failing the
test on any PGMQ runtime error.
-}
runDb :: Text -> Eff Stack a -> IO a
runDb connStr act =
    withJobRuntime connStr Nothing $ \rt -> do
        res <- runJobEff rt act
        either (\e -> fail ("PGMQ runtime error: " <> show e)) pure res

-- | A job over 'Ping' with a distinct queue name per test (avoids collisions).
mkJob :: Text -> Job Ping
mkJob name =
    Job
        { jobName = name
        , jobQueue = queueRef name
        , jobCodec = aesonJobCodec
        , jobPolicy = defaultRetryPolicy
        }

versionedPingCodec :: CoreCodec.Codec Ping
versionedPingCodec =
    CoreCodec.Codec
        { eventTypes = EventType "ping" :| []
        , eventType = \_ -> EventType "ping"
        , schemaVersion = 2
        , encode = toJSON
        , decode = \_ value ->
            case parseEither parseJSON value of
                Left err -> Left (Text.pack err)
                Right ping -> Right ping
        , upcasters =
            [
                ( 1
                , \_ value ->
                    case value of
                        String msg ->
                            Right $
                                object
                                    [ "message" .= msg
                                    , "count" .= (1 :: Int)
                                    ]
                        _ -> Left "expected v1 string payload"
                )
            ]
        }

-- | Total number of messages currently on a queue (visible or not).
queueLen :: QueueName -> Eff Stack Int64
queueLen q = do
    metrics <- Pgmq.queueMetrics q
    pure metrics.queueLength

{- | Look up a queue by physical name in a 'Pgmq.listQueues' result and report
whether it is unlogged. 'Nothing' means the queue was not found.
-}
queueIsUnlogged :: QueueName -> [Pgmq.Queue] -> Maybe Bool
queueIsUnlogged qn queues =
    fmap (.isUnlogged) (find (\q -> q.name == qn) queues)

readOneIsEmpty :: QueueName -> Eff Stack Bool
readOneIsEmpty q = do
    messages <-
        Pgmq.readMessage
            ReadMessage
                { queueName = q
                , delay = 30
                , batchSize = Just 1
                , conditional = Nothing
                }
    pure (null messages)

-- | Read up to @n@ messages back off a queue (making them invisible for 30 s).
readMessages :: QueueName -> Int32 -> Eff Stack [Message]
readMessages q n = do
    messages <-
        Pgmq.readMessage
            ReadMessage
                { queueName = q
                , delay = 30
                , batchSize = Just n
                , conditional = Nothing
                }
    pure (toList messages)

-- | Look up a single key in a @Maybe Value@ header object.
headerKey :: Text -> Maybe Value -> Maybe Value
headerKey k = \case
    Just (Object o) -> KeyMap.lookup (Key.fromText k) o
    _ -> Nothing

{- | A real tracer provider with the W3C Trace Context propagator and a
non-dummy id generator, so an active span produces a @traceparent@ on injection.
No span processors are needed — the test inspects propagated headers, not
exported spans.
-}
setupW3CProvider :: IO OTel.TracerProvider
setupW3CProvider =
    OTel.createTracerProvider
        []
        OTel.emptyTracerProviderOptions
            { OTel.tracerProviderOptionsIdGenerator = defaultIdGenerator
            , OTel.tracerProviderOptionsPropagators = W3C.w3cTraceContextPropagator
            }

stopAppQuickly :: (IOE :> es) => AppHandle es -> Eff es ()
stopAppQuickly app = do
    _ <- stopAppGracefully ShutdownConfig{drainTimeout = 1} app
    pure ()

waitUntil :: IO Bool -> IO Bool
waitUntil predicate =
    maybe False id <$> timeout 10_000_000 loop
  where
    loop = do
        ok <- predicate
        if ok
            then pure True
            else threadDelay 100_000 >> loop

spec :: SpecWith Text
spec = do
    it "round-trips a payload through aesonJobCodec" $ \_connStr -> do
        let codec = aesonJobCodec :: JobCodec Ping
            sample = Ping "hello" 7
        decodeJob codec (encodeJob codec sample) `shouldBe` Right sample

    it "round-trips a payload through keiroJobCodec's versioned envelope" $ \_connStr -> do
        let codec = keiroJobCodec versionedPingCodec
            sample = Ping "hello" 7
        decodeJob codec (encodeJob codec sample) `shouldBe` Right sample

    it "decodes old keiroJobCodec payloads through the upcaster chain" $ \_connStr -> do
        let codec = keiroJobCodec versionedPingCodec
            v1Envelope =
                object
                    [ "v" .= (1 :: Int)
                    , "data" .= String "legacy"
                    ]
        decodeJob codec v1Envelope `shouldBe` Right (Ping "legacy" 1)

    it "classifies future keiroJobCodec payloads as retryable" $ \_connStr -> do
        let codec = keiroJobCodec versionedPingCodec
            futureEnvelope =
                object
                    [ "v" .= (99 :: Int)
                    , "data" .= object []
                    ]
        decodeJob codec futureEnvelope `shouldBe` Left (JobPayloadFromFuture 99 2)

    it "classifies malformed keiroJobCodec envelopes as malformed payloads" $ \_connStr -> do
        let codec = keiroJobCodec versionedPingCodec
        decodeJob codec (String "not an envelope") `shouldSatisfy` \case
            Left (JobPayloadMalformed _) -> True
            _ -> False

    it "validates retry policies" $ \_connStr -> do
        mkRetryPolicy 0 (RetryDelay 60) True
            `shouldBe` Left (NonPositiveMaxRetries 0)
        mkRetryPolicy 1 (RetryDelay (-1)) True
            `shouldBe` Left (NegativeRetryDelay (RetryDelay (-1)))
        mkRetryPolicy 1 (RetryDelay 0) True
            `shouldBe` Right (RetryPolicy 1 (RetryDelay 0) True)

    it "validates job tuning" $ \_connStr -> do
        mkJobTuning 0 1 (PollEvery 1)
            `shouldBe` Left (NonPositiveVisibilityTimeout 0)
        mkJobTuning 30 0 (PollEvery 1)
            `shouldBe` Left (NonPositiveBatchSize 0)
        mkJobTuning 30 1 (PollEvery 0)
            `shouldBe` Left NonPositivePollInterval
        mkJobTuning 30 1 (LongPoll 0 100)
            `shouldBe` Left NonPositivePollInterval
        mkJobTuning 30 1 (PollEvery 1)
            `shouldBe` Right defaultJobTuning

    it "derives distinct physical names for long logical queue names" $ \_connStr -> do
        let commonPrefix = Text.replicate 43 "a"
            first = queueRef (commonPrefix <> "x")
            second = queueRef (commonPrefix <> "y")
        first.physicalName `shouldNotBe` second.physicalName
        Text.length (queueNameToText first.physicalName) `shouldBe` 43
        Text.length (queueNameToText second.physicalName) `shouldBe` 43

    it "disambiguates logical names ending in _dlq from derived DLQ names" $ \_connStr -> do
        let foo = queueRef "foo"
            masquerading = queueRef "foo_dlq"
            masqueradingPhysical = queueNameToText masquerading.physicalName
        masquerading.physicalName `shouldNotBe` foo.dlqName
        masqueradingPhysical `shouldNotSatisfy` Text.isSuffixOf "_dlq"

    it "keeps short physical queue names unchanged" $ \_connStr -> do
        queueNameToText (queueRef "hospital_capacity.reservation_work").physicalName
            `shouldBe` "hospital_capacity_reservation_work"

    it "always derives PGMQ-parseable queue names" $ \_connStr -> do
        let logicalNames =
                [ ""
                , "!!!"
                , Text.replicate 100 "x"
                , "___trailing___"
                , "foo_dlq"
                , "9starts.with.digit"
                ]
        traverse_
            ( \logical -> do
                let ref = queueRef logical
                    physical = queueNameToText ref.physicalName
                    dlq = queueNameToText ref.dlqName
                parseQueueName physical `shouldSatisfy` isRight
                parseQueueName dlq `shouldSatisfy` isRight
                physical `shouldNotSatisfy` Text.isSuffixOf "_dlq"
            )
            logicalNames

    it "Done deletes the message" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.done"
        runDb connStr $ do
            ensureJobQueue job
            _ <- enqueue job (Ping "do" 1)
            runJobOnce 1 job (\_ -> pure Done)
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 0

    it "Retry redelivers the message" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.retry"
        runDb connStr $ do
            ensureJobQueue job
            _ <- enqueue job (Ping "again" 2)
            runJobOnce 1 job (\_ -> pure (Retry (RetryDelay 0)))
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 1

    it "RetryDefault redelivers after the policy default delay" $ \connStr -> do
        let job =
                (mkJob "keiro_pgmq_test.retry_default")
                    { jobPolicy = RetryPolicy 5 (RetryDelay 5) True
                    }
        runDb connStr $ do
            ensureJobQueue job
            _ <- enqueue job (Ping "again by default" 2)
            runJobOnce 1 job (\_ -> pure RetryDefault)
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        emptyImmediateRead <- runDb connStr (readOneIsEmpty job.jobQueue.physicalName)
        len `shouldBe` 1
        emptyImmediateRead `shouldBe` True

    it "runJobOnceWithContext returns promptly when n exceeds the queue length" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.once_short_queue"
        result <-
            timeout 2_000_000 $
                runDb connStr $ do
                    ensureJobQueue job
                    _ <- enqueue job (Ping "only" 1)
                    runJobOnceWithContext defaultJobTuning 5 job \_ctx _payload ->
                        pure Done
        result `shouldBe` Just 1
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 0

    it "runJobOnceWithContext drains messages in batches greater than one" $ \connStr -> do
        handled <- newIORef (0 :: Int)
        let job = mkJob "keiro_pgmq_test.once_batch"
            tuning =
                either (error . show) id $
                    mkJobTuning 30 2 (PollEvery 1)
        drained <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "first" 1)
                _ <- enqueue job (Ping "second" 2)
                _ <- enqueue job (Ping "third" 3)
                runJobOnceWithContext tuning 3 job \_ctx _payload -> do
                    liftIO $ modifyIORef' handled (+ 1)
                    pure Done
        drained `shouldBe` 3
        readIORef handled `shouldReturn` 3
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 0

    it "runJobOnceWithContext Retry delay hides the message until the delay expires" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.once_retry_delay"
        drained <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "later" 1)
                runJobOnceWithContext defaultJobTuning 1 job \_ctx _payload ->
                    pure (Retry (RetryDelay 5))
        drained `shouldBe` 1
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        emptyImmediateRead <- runDb connStr (readOneIsEmpty job.jobQueue.physicalName)
        len `shouldBe` 1
        emptyImmediateRead `shouldBe` True

    it "runJobOnceWithContext leaves thrown-handler messages invisible and continues" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.once_throw"
            tuning =
                either (error . show) id $
                    mkJobTuning 2 2 (PollEvery 1)
        drained <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "throw" 1)
                _ <- enqueue job (Ping "ok" 2)
                runJobOnceWithContext tuning 2 job \_ctx payload ->
                    if payload.message == "throw"
                        then liftIO $ throwIO (userError "handler failed")
                        else pure Done
        drained `shouldBe` 1
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        emptyImmediateRead <- runDb connStr (readOneIsEmpty job.jobQueue.physicalName)
        len `shouldBe` 1
        emptyImmediateRead `shouldBe` True
        threadDelay 2_200_000
        drainedAfterVisibilityTimeout <-
            runDb connStr $
                runJobOnceWithContext tuning 1 job \_ctx _payload ->
                    pure Done
        drainedAfterVisibilityTimeout `shouldBe` 1

    it "runJobOnceWithContext auto-routes max-retry messages to the DLQ before rerunning the handler" $ \connStr -> do
        callCount <- newIORef (0 :: Int)
        let job =
                (mkJob "keiro_pgmq_test.once_max_retries")
                    { jobPolicy = RetryPolicy 1 (RetryDelay 0) True
                    }
        firstDrain <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "retry-limit" 1)
                runJobOnceWithContext defaultJobTuning 1 job \_ctx _payload -> do
                    liftIO $ modifyIORef' callCount (+ 1)
                    pure (Retry (RetryDelay 0))
        secondDrain <-
            runDb connStr $
                runJobOnceWithContext defaultJobTuning 1 job \_ctx _payload -> do
                    liftIO $ modifyIORef' callCount (+ 1)
                    pure Done
        firstDrain `shouldBe` 1
        secondDrain `shouldBe` 1
        readIORef callCount `shouldReturn` 1
        mainLen <- runDb connStr (queueLen job.jobQueue.physicalName)
        dlqLen <- runDb connStr (queueLen job.jobQueue.dlqName)
        mainLen `shouldBe` 0
        dlqLen `shouldBe` 1

    it "worker-path lease extension prevents redelivery" $ \connStr -> do
        callCount <- newIORef (0 :: Int)
        handlerDone <- newIORef False
        let job = mkJob "keiro_pgmq_test.worker_lease"
            tuning =
                either (error . show) id $
                    mkJobTuning 2 1 (PollEvery 0.2)
        processed <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "slow" 4)
                result <-
                    runJobWorkers
                        IgnoreFailures
                        16
                        [ jobProcessorWithContext tuning job \ctx _payload -> do
                            liftIO $ modifyIORef' callCount (+ 1)
                            ctx.extendLease 30
                            liftIO $ threadDelay 4_000_000
                            liftIO $ writeIORef handlerDone True
                            pure Done
                        ]
                case result of
                    Left err -> liftIO $ fail ("runJobWorkers failed: " <> show err)
                    Right app -> do
                        ok <- liftIO $ waitUntil (readIORef handlerDone)
                        stopAppQuickly app
                        pure ok
        processed `shouldBe` True
        readIORef callCount `shouldReturn` 1
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 0

    it "worker-path context exposes the first attempt number" $ \connStr -> do
        seenAttempt <- newIORef Nothing
        let job = mkJob "keiro_pgmq_test.worker_attempt"
        processed <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "attempt" 1)
                result <-
                    runJobWorkers
                        IgnoreFailures
                        16
                        [ jobProcessorWithContext defaultJobTuning job \ctx _payload -> do
                            liftIO $ writeIORef seenAttempt (Just ctx.attempt)
                            pure Done
                        ]
                case result of
                    Left err -> liftIO $ fail ("runJobWorkers failed: " <> show err)
                    Right app -> do
                        ok <- liftIO $ waitUntil ((/= Nothing) <$> readIORef seenAttempt)
                        stopAppQuickly app
                        pure ok
        processed `shouldBe` True
        readIORef seenAttempt `shouldReturn` Just (Just 0)

    it "runJobWorkers processes an enqueued message" $ \connStr -> do
        processedRef <- newIORef False
        let job = mkJob "keiro_pgmq_test.worker_smoke"
        processed <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "worker" 1)
                result <-
                    runJobWorkers
                        IgnoreFailures
                        16
                        [ jobProcessor job \_payload -> do
                            liftIO $ writeIORef processedRef True
                            pure Done
                        ]
                case result of
                    Left err -> liftIO $ fail ("runJobWorkers failed: " <> show err)
                    Right app -> do
                        ok <- liftIO $ waitUntil (readIORef processedRef)
                        stopAppQuickly app
                        pure ok
        processed `shouldBe` True
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 0

    it "runJobWorkers survives a transient database error during polling" $ \_connStr ->
        pendingWith "needs a deterministic keiro-pgmq-level transient polling fault injector; EP-1 covers this in upstream shibuya and shibuya-pgmq-adapter tests"

    it "worker-path retry limit auto-routes to the DLQ before the handler reruns" $ \connStr -> do
        callCount <- newIORef (0 :: Int)
        let job =
                (mkJob "keiro_pgmq_test.worker_max_retries")
                    { jobPolicy = RetryPolicy 1 (RetryDelay 0) True
                    }
            tuning =
                either (error . show) id $
                    mkJobTuning 30 1 (PollEvery 0.1)
        dlqReached <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "retry-limit" 1)
                result <-
                    runJobWorkers
                        IgnoreFailures
                        16
                        [ jobProcessorWithContext tuning job \_ctx _payload -> do
                            liftIO $ modifyIORef' callCount (+ 1)
                            pure (Retry (RetryDelay 0))
                        ]
                case result of
                    Left err -> liftIO $ fail ("runJobWorkers failed: " <> show err)
                    Right app -> do
                        ok <- liftIO $ waitUntil do
                            dlqLen <- runDb connStr (queueLen job.jobQueue.dlqName)
                            pure (dlqLen == 1)
                        stopAppQuickly app
                        pure ok
        dlqReached `shouldBe` True
        readIORef callCount `shouldReturn` 1

    it "enqueueWithDelay delays first delivery" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.enqueue_delay"
        runDb connStr $ do
            ensureJobQueue job
            _ <- enqueueWithDelay job 5 (Ping "later" 1)
            pure ()
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        emptyImmediateRead <- runDb connStr (readOneIsEmpty job.jobQueue.physicalName)
        len `shouldBe` 1
        emptyImmediateRead `shouldBe` True

    it "Dead routes the message to the DLQ" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.dead"
        runDb connStr $ do
            ensureJobQueue job
            _ <- enqueue job (Ping "poison" 3)
            runJobOnce 1 job (\_ -> pure (Dead "bad"))
        mainLen <- runDb connStr (queueLen job.jobQueue.physicalName)
        dlqLen <- runDb connStr (queueLen job.jobQueue.dlqName)
        mainLen `shouldBe` 0
        dlqLen `shouldBe` 1

    it "readDlq decodes the original dead-lettered payload" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.dlq_read"
            payload = Ping "poison" 3
        entries <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job payload
                runJobOnce 1 job (\_ -> pure (Dead "bad"))
                readDlq job 1
        case entries of
            [entry] -> do
                entry.reason `shouldSatisfy` Text.isPrefixOf "poison_pill"
                entry.originalPayload `shouldBe` Right payload
                entry.originalMessageId `shouldSatisfy` (/= Nothing)
                entry.readCount `shouldBe` Just 1
            _ -> expectationFailure ("expected one DLQ entry, got " <> show (length entries))

    it "redriveDlq moves dead-lettered payloads back to the main queue" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.dlq_redrive"
        redriven <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "redrive" 1)
                runJobOnce 1 job (\_ -> pure (Dead "bad"))
                redriveDlq job 10
        redriven `shouldBe` 1
        dlqLen <- runDb connStr (queueLen job.jobQueue.dlqName)
        mainLen <- runDb connStr (queueLen job.jobQueue.physicalName)
        dlqLen `shouldBe` 0
        mainLen `shouldBe` 1
        runDb connStr $
            runJobOnce 1 job (\_ -> pure Done)
        finalMainLen <- runDb connStr (queueLen job.jobQueue.physicalName)
        finalMainLen `shouldBe` 0

    it "purgeDlq empties the DLQ" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.dlq_purge"
        runDb connStr $ do
            ensureJobQueue job
            _ <- enqueue job (Ping "purge" 1)
            runJobOnce 1 job (\_ -> pure (Dead "bad"))
            purgeDlq job
        dlqLen <- runDb connStr (queueLen job.jobQueue.dlqName)
        dlqLen `shouldBe` 0

    it "readDlq preserves malformed DLQ wrappers as malformed entries" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.dlq_malformed"
        entries <-
            runDb connStr $ do
                ensureJobQueue job
                _ <-
                    Pgmq.sendMessage
                        SendMessage
                            { queueName = job.jobQueue.dlqName
                            , messageBody = MessageBody (String "not a dlq wrapper")
                            , delay = Nothing
                            }
                readDlq job 1
        case entries of
            [entry] -> do
                entry.reason `shouldSatisfy` Text.isPrefixOf "malformed_dlq_payload"
                entry.originalPayload `shouldSatisfy` \case
                    Left (JobPayloadMalformed _) -> True
                    _ -> False
            _ -> expectationFailure ("expected one malformed DLQ entry, got " <> show (length entries))

    it "undecodable payload routes to the DLQ" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.bad"
        runDb connStr $ do
            ensureJobQueue job
            -- Send raw JSON the Ping codec cannot decode, bypassing enqueue.
            _ <-
                Pgmq.sendMessage
                    SendMessage
                        { queueName = job.jobQueue.physicalName
                        , messageBody = MessageBody (String "not a ping")
                        , delay = Nothing
                        }
            runJobOnce 1 job (\_ -> pure Done)
        mainLen <- runDb connStr (queueLen job.jobQueue.physicalName)
        dlqLen <- runDb connStr (queueLen job.jobQueue.dlqName)
        mainLen `shouldBe` 0
        dlqLen `shouldBe` 1

    -- EP-1 M1: header-carrying enqueue and the reserved-key contract.
    it "enqueueWithHeaders attaches a header readable on the raw PGMQ message" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.hdr_attach"
        msgs <-
            runDb connStr $ do
                ensureJobQueue job
                _ <-
                    enqueueWithHeaders
                        job
                        (MessageHeaders (object ["tenant" .= ("acme" :: Text)]))
                        (Ping "hdr" 1)
                readMessages job.jobQueue.physicalName 1
        case msgs of
            [m] -> headerKey "tenant" m.headers `shouldBe` Just (String "acme")
            _ -> expectationFailure ("expected one message, got " <> show (length msgs))

    it "enqueueWithHeaders leaves the x-pgmq-group key untouched" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.hdr_group"
        msgs <-
            runDb connStr $ do
                ensureJobQueue job
                _ <-
                    enqueueWithHeaders
                        job
                        (MessageHeaders (object ["x-pgmq-group" .= ("g1" :: Text)]))
                        (Ping "g" 1)
                readMessages job.jobQueue.physicalName 1
        case msgs of
            [m] -> headerKey "x-pgmq-group" m.headers `shouldBe` Just (String "g1")
            _ -> expectationFailure ("expected one message, got " <> show (length msgs))

    -- EP-1 M2: batch enqueue.
    it "enqueueBatch of three payloads yields three ids and queue depth three" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.batch"
        ids <-
            runDb connStr $ do
                ensureJobQueue job
                enqueueBatch job [Ping "a" 1, Ping "b" 2, Ping "c" 3]
        length ids `shouldBe` 3
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 3

    it "enqueueBatchWithHeaders attaches per-message headers" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.batch_headers"
        msgs <-
            runDb connStr $ do
                ensureJobQueue job
                _ <-
                    enqueueBatchWithHeaders
                        job
                        [ (MessageHeaders (object ["i" .= (1 :: Int)]), Ping "a" 1)
                        , (MessageHeaders (object ["i" .= (2 :: Int)]), Ping "b" 2)
                        ]
                readMessages job.jobQueue.physicalName 2
        length msgs `shouldBe` 2
        map (headerKey "i" . (.headers)) msgs
            `shouldMatchList` [Just (Number 1), Just (Number 2)]

    -- EP-1 M3: handler-visible headers and trace propagation.
    it "drain-path JobContext exposes the enqueued headers" $ \connStr -> do
        seen <- newIORef Nothing
        let job = mkJob "keiro_pgmq_test.ctx_headers"
        runDb connStr $ do
            ensureJobQueue job
            _ <-
                enqueueWithHeaders
                    job
                    (MessageHeaders (object ["tenant" .= ("acme" :: Text)]))
                    (Ping "h" 1)
            _ <-
                runJobOnceWithContext defaultJobTuning 1 job \ctx _payload -> do
                    liftIO (writeIORef seen ctx.headers)
                    pure Done
            pure ()
        captured <- readIORef seen
        headerKey "tenant" captured `shouldBe` Just (String "acme")

    it "a traceparent set at enqueue is visible to the drain-path handler" $ \connStr -> do
        seen <- newIORef Nothing
        provider <- setupW3CProvider
        let tracer = OTel.makeTracer provider "keiro-pgmq-test" OTel.tracerOptions
            job = mkJob "keiro_pgmq_test.traceparent"
        parentSpan <- OTel.createSpan tracer Ctxt.empty "enqueue" OTel.defaultSpanArguments
        _ <- CtxtLocal.attachContext (Ctxt.insertSpan parentSpan Ctxt.empty)
        runDb connStr $ do
            ensureJobQueue job
            _ <- enqueueTraced provider job (MessageHeaders (object [])) (Ping "t" 1)
            _ <-
                runJobOnceWithContext defaultJobTuning 1 job \ctx _payload -> do
                    liftIO (writeIORef seen ctx.headers)
                    pure Done
            pure ()
        OTel.endSpan parentSpan Nothing
        captured <- readIORef seen
        headerKey "traceparent" captured `shouldSatisfy` \case
            Just (String _) -> True
            _ -> False

    -- EP-2 M1: unlogged vs standard provisioning.
    it "ensureJobQueueWith unlogged creates an unlogged queue" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.unlogged"
        unlogged <-
            runDb connStr $ do
                ensureJobQueueWith unloggedProvision job
                queues <- Pgmq.listQueues
                pure (queueIsUnlogged job.jobQueue.physicalName queues)
        unlogged `shouldBe` Just True

    it "ensureJobQueue (standard) creates a logged queue" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.standard_logged"
        unlogged <-
            runDb connStr $ do
                ensureJobQueue job
                queues <- Pgmq.listQueues
                pure (queueIsUnlogged job.jobQueue.physicalName queues)
        unlogged `shouldBe` Just False

    -- EP-2 M2: partitioned config shape (pure) + pending live test.
    it "ensureJobQueueWith partitioned builds a partitioned QueueConfig" $ \_connStr -> do
        let job = mkJob "keiro_pgmq_test.partitioned"
            spec = PartitionSpec{partitionInterval = "daily", retentionInterval = "7 days"}
        case queueProvisionConfigs (partitionedProvision spec) job of
            (mainCfg : _) ->
                case mainCfg.queueType of
                    Config.PartitionedQueue pc -> do
                        pc.partitionInterval `shouldBe` "daily"
                        pc.retentionInterval `shouldBe` "7 days"
                        mainCfg.queueName `shouldBe` job.jobQueue.physicalName
                    other ->
                        expectationFailure
                            ("expected PartitionedQueue, got " <> show other)
            [] -> expectationFailure "expected at least the main queue config"

    it "ensureJobQueueWith partitioned creates a partitioned queue (live)" $ \_connStr ->
        pendingWith
            "requires a pg_partman-enabled PostgreSQL; the keiro test database installs only \
            \the PGMQ schema via pgmq-migration, which does not load pg_partman"

    -- EP-2 M3: FIFO index idempotence.
    it "ensureFifoIndex is idempotent and the queue still accepts reads" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.fifo_index"
        roundTripped <-
            runDb connStr $ do
                ensureJobQueue job
                ensureFifoIndex job
                ensureFifoIndex job -- second call must not error
                _ <- enqueue job (Ping "after-index" 1)
                runJobOnce 1 job (\_ -> pure Done)
                queueLen job.jobQueue.physicalName
        roundTripped `shouldBe` 0

    -- EP-3 M3: group-keyed producer + ordered queue setup.
    it "enqueueToGroup writes the x-pgmq-group header" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.group_header"
        msgs <-
            runDb connStr $ do
                ensureOrderedJobQueue job
                _ <- enqueueToGroup job "g1" (Ping "grouped" 1)
                readMessages job.jobQueue.physicalName 1
        case msgs of
            [m] -> headerKey "x-pgmq-group" m.headers `shouldBe` Just (String "g1")
            _ -> expectationFailure ("expected one message, got " <> show (length msgs))

    it "ensureOrderedJobQueue is idempotent and the queue accepts grouped work" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.ordered_setup"
        len <-
            runDb connStr $ do
                ensureOrderedJobQueue job
                ensureOrderedJobQueue job -- second call must not error
                _ <- enqueueToGroup job "g1" (Ping "x" 1)
                _ <-
                    runJobOnceWithContext (withOrdering FifoThroughput defaultJobTuning) 1 job \_ctx _p ->
                        pure Done
                queueLen job.jobQueue.physicalName
        len `shouldBe` 0

    -- EP-3 M4: end-to-end ordering proof.
    it "FifoThroughput drain preserves strict within-group order and fully drains" $ \connStr -> do
        observed <- newIORef ([] :: [Text])
        let job = mkJob "keiro_pgmq_test.fifo_order"
        drained <-
            runDb connStr $ do
                ensureOrderedJobQueue job
                _ <- enqueueToGroup job "a" (Ping "a1" 1)
                _ <- enqueueToGroup job "b" (Ping "b1" 1)
                _ <- enqueueToGroup job "a" (Ping "a2" 2)
                _ <- enqueueToGroup job "a" (Ping "a3" 3)
                _ <- enqueueToGroup job "b" (Ping "b2" 2)
                runJobOnceWithContext (withOrdering FifoThroughput defaultJobTuning) 5 job \_ctx payload -> do
                    liftIO $ modifyIORef' observed (<> [payload.message])
                    pure Done
        log' <- readIORef observed
        drained `shouldBe` 5
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 0
        filter (Text.isPrefixOf "a") log' `shouldBe` ["a1", "a2", "a3"]
        filter (Text.isPrefixOf "b") log' `shouldBe` ["b1", "b2"]

    it "FifoThroughput worker path preserves within-group order" $ \connStr -> do
        observed <- newIORef ([] :: [Text])
        let job = mkJob "keiro_pgmq_test.fifo_worker"
            tuning =
                withOrdering FifoThroughput $
                    either (error . show) id $
                        mkJobTuning 30 1 (PollEvery 0.1)
        processed <-
            runDb connStr $ do
                ensureOrderedJobQueue job
                _ <- enqueueToGroup job "a" (Ping "a1" 1)
                _ <- enqueueToGroup job "a" (Ping "a2" 2)
                _ <- enqueueToGroup job "a" (Ping "a3" 3)
                result <-
                    runJobWorkers
                        IgnoreFailures
                        16
                        [ jobProcessorWithContext tuning job \_ctx payload -> do
                            liftIO $ modifyIORef' observed (<> [payload.message])
                            pure Done
                        ]
                case result of
                    Left err -> liftIO $ fail ("runJobWorkers failed: " <> show err)
                    Right app -> do
                        ok <- liftIO $ waitUntil ((>= 3) . length <$> readIORef observed)
                        stopAppQuickly app
                        pure ok
        processed `shouldBe` True
        log' <- readIORef observed
        filter (Text.isPrefixOf "a") log' `shouldBe` ["a1", "a2", "a3"]
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 0

    -- EP-4 M1: typed metrics surface (main + DLQ).
    it "jobQueueMetrics reports main-queue depth after enqueue" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.metrics_depth"
        (mainMetrics, dlqMetrics) <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "a" 1)
                _ <- enqueue job (Ping "b" 2)
                _ <- enqueue job (Ping "c" 3)
                mainMetrics <- jobQueueMetrics job
                dlqMetrics <- jobDlqMetrics job
                pure (mainMetrics, dlqMetrics)
        mainMetrics.queueLength `shouldBe` 3
        mainMetrics.queueVisibleLength `shouldBe` 3
        dlqMetrics.queueLength `shouldBe` 0

    it "jobDlqMetrics reports DLQ depth after a Dead outcome" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.metrics_dlq"
        (mainMetrics, dlqMetrics) <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "poison" 1)
                runJobOnce 1 job (\_ -> pure (Dead "bad"))
                mainMetrics <- jobQueueMetrics job
                dlqMetrics <- jobDlqMetrics job
                pure (mainMetrics, dlqMetrics)
        mainMetrics.queueLength `shouldBe` 0
        dlqMetrics.queueLength `shouldBe` 1

    -- EP-4 M2: archive/retention API.
    it "archiveDlq retains dead-lettered rows in the archive table" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.dlq_archive"
        (archived, dlqLen) <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "poison" 1)
                runJobOnce 1 job (\_ -> pure (Dead "bad"))
                archived <- archiveDlq job 10
                dlqMetrics <- jobDlqMetrics job
                pure (archived, dlqMetrics.queueLength)
        archived `shouldBe` 1
        dlqLen `shouldBe` 0
        retained <- archiveCount connStr (queueNameToText job.jobQueue.dlqName)
        retained `shouldBe` 1

    -- EP-4 M3: end-to-end retention lifecycle.
    it "archived DLQ rows survive a purge" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.dlq_archive_purge"
        archived <-
            runDb connStr $ do
                ensureJobQueue job
                _ <- enqueue job (Ping "poison" 1)
                runJobOnce 1 job (\_ -> pure (Dead "bad"))
                archived <- archiveDlq job 10
                purgeDlq job
                pure archived
        archived `shouldBe` 1
        dlqLen <- runDb connStr (queueLen job.jobQueue.dlqName)
        dlqLen `shouldBe` 0
        retained <- archiveCount connStr (queueNameToText job.jobQueue.dlqName)
        retained `shouldBe` 1
