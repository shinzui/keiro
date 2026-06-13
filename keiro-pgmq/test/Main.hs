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

import Control.Exception (bracket)
import Data.Aeson (FromJSON, ToJSON, Value (String), object, parseJSON, toJSON, (.=))
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Hasql.Connection.Settings qualified as Conn
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Keiro.Codec qualified as CoreCodec
import Keiro.PGMQ
import Keiro.Test.Postgres qualified as Postgres
import Pgmq.Effectful (MessageBody (..), Pgmq, QueueMetrics (..), SendMessage (..))
import Pgmq.Effectful qualified as Pgmq
import Pgmq.Migration qualified as Migration
import Pgmq.Types (QueueName)
import Shibuya.Telemetry.Effect (Tracing)
import Test.Hspec

-- | A sample job payload defined entirely in the test.
data Ping = Ping
    { message :: Text
    , count :: Int
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

-- | The effect stack 'runJobEff' interprets.
type Stack = '[Pgmq, Tracing, Error PgmqRuntimeError, IOE]

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
        { eventTypes = "ping" :| []
        , eventType = \_ -> "ping"
        , schemaVersion = 2
        , encode = toJSON
        , decode = \value ->
            case parseEither parseJSON value of
                Left err -> Left (Text.pack err)
                Right ping -> Right ping
        , upcasters =
            [
                ( 1
                , \value ->
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
