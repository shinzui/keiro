{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

{- | Layer 1 of @keiro-pgmq@: transport-agnostic plumbing shared by every PGMQ
integration (and, in the future, by case B — PGMQ as an integration-event
transport). This layer owns the two things every PGMQ user repeats:

  1. Turning an arbitrary logical queue name into a PGMQ-legal physical name
     plus a matching dead-letter-queue name ('QueueRef' / 'queueRef').
  2. Running the @Pgmq : Tracing : Error PgmqRuntimeError : IOE@ effect stack
     against a connection pool with an optional OpenTelemetry tracer
     ('JobRuntime' / 'withJobRuntime' / 'runJobEff').

Nothing here knows about jobs, codecs, or retry policies — that is layer 2
('Keiro.PGMQ.Job').
-}
module Keiro.PGMQ.Runtime (
    -- * Queue-name derivation
    QueueRef (..),
    queueRef,

    -- * Runtime handle and runners
    JobRuntime (..),
    withJobRuntime,
    runJobEff,

    -- * Re-exports
    PgmqRuntimeError,
) where

import "base" Control.Exception (bracket)
import "effectful-core" Effectful (Eff, IOE, runEff)
import "effectful-core" Effectful.Error.Static (Error, runErrorNoCallStack)
import "hasql" Hasql.Connection.Settings qualified as Conn
import "hasql-pool" Hasql.Pool (Pool)
import "hasql-pool" Hasql.Pool qualified as Pool
import "hasql-pool" Hasql.Pool.Config qualified as Pool.Config
import "pgmq-core" Pgmq.Types (QueueName)
import "pgmq-core" Pgmq.Types qualified as Pgmq
import "pgmq-effectful" Pgmq.Effectful (Pgmq, PgmqRuntimeError, runPgmq, runPgmqTraced)
import "shibuya-core" Shibuya.Telemetry.Effect (Tracer, Tracing, runTracing, runTracingNoop)
import "text" Data.Text (Text)
import "text" Data.Text qualified as Text

{- | A logical queue identity plus the PGMQ-legal physical names derived from
it. PGMQ caps queue names at 47 characters and rejects dots and other
non-@[a-z0-9_]@ characters, so a caller-facing logical name (which may contain
dots, e.g. @"hospital_capacity.reservation_work"@) must be sanitized once,
centrally, into a valid physical name plus a @"_dlq"@-suffixed dead-letter name.
-}
data QueueRef = QueueRef
    { logicalName :: !Text
    -- ^ Caller-facing name; may contain dots or otherwise-illegal characters.
    , physicalName :: !QueueName
    -- ^ Derived, PGMQ-valid name used for the main queue.
    , dlqName :: !QueueName
    -- ^ Derived @"<physical>_dlq"@ name used for the dead-letter queue.
    }
    deriving stock (Eq, Show)

{- | Derive a 'QueueRef' from a logical name. Total: it sanitizes rather than
failing. It lower-cases, replaces every character that is not @[a-z0-9_]@ with
@'_'@, collapses repeated underscores (also trimming leading/trailing ones),
guarantees a leading letter, and trims the result to 43 characters so the
@"_dlq"@ suffix still fits inside PGMQ's 47-character ceiling.

For example, @queueRef "hospital_capacity.reservation_work"@ yields
@physicalName == "hospital_capacity_reservation_work"@ and
@dlqName == "hospital_capacity_reservation_work_dlq"@.
-}
queueRef :: Text -> QueueRef
queueRef logical =
    QueueRef
        { logicalName = logical
        , physicalName = forceQueueName base
        , dlqName = forceQueueName (base <> "_dlq")
        }
  where
    base = sanitize logical

-- | Reserve 4 characters for the @"_dlq"@ suffix below the 47-char ceiling.
maxBaseLength :: Int
maxBaseLength = 43

sanitize :: Text -> Text
sanitize =
    Text.take maxBaseLength
        . ensureLeadingLetter
        . collapseUnderscores
        . Text.map toLegal
        . Text.toLower
  where
    toLegal c
        | (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' = c
        | otherwise = '_'

{- | Replace runs of underscores with a single underscore and drop leading and
trailing underscores.
-}
collapseUnderscores :: Text -> Text
collapseUnderscores =
    Text.intercalate "_" . filter (not . Text.null) . Text.splitOn "_"

{- | Guarantee the name begins with an ASCII letter (PGMQ-derived table names
must start with a letter). Falls back to a bare @"q"@ for an empty result.
-}
ensureLeadingLetter :: Text -> Text
ensureLeadingLetter t =
    case Text.uncons t of
        Nothing -> "q"
        Just (c, _)
            | c >= 'a' && c <= 'z' -> t
            | otherwise -> Text.cons 'q' t

{- | Build a 'QueueName' from an already-sanitized 'Text'. The sanitizer should
never produce an invalid name; if it somehow does, that is a programmer error,
so we fail loudly with a clear message.
-}
forceQueueName :: Text -> QueueName
forceQueueName t =
    case Pgmq.parseQueueName t of
        Right qn -> qn
        Left err ->
            error
                ( "Keiro.PGMQ.Runtime.queueRef: derived an invalid PGMQ queue name "
                    <> show t
                    <> ": "
                    <> show err
                )

{- | Opaque runtime: a Hasql connection pool plus an optional OpenTelemetry
tracer. Construct it with 'withJobRuntime' (which manages the pool lifecycle).
-}
data JobRuntime = JobRuntime
    { runtimePool :: !Pool
    , runtimeTracer :: !(Maybe Tracer)
    }

{- | Acquire a Hasql pool from a libpq connection string, run @action@ with the
resulting 'JobRuntime', and release the pool afterwards (even on exception).
-}
withJobRuntime :: Text -> Maybe Tracer -> (JobRuntime -> IO a) -> IO a
withJobRuntime connStr tracer action =
    bracket acquire Pool.release $ \pool ->
        action JobRuntime{runtimePool = pool, runtimeTracer = tracer}
  where
    acquire =
        Pool.acquire $
            Pool.Config.settings
                [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
                ]

{- | Run a @Pgmq : Tracing : Error PgmqRuntimeError : IOE@ effect action against
the runtime, surfacing PGMQ errors as a @Left@. The tracer (if any) is threaded
into both the shibuya 'Tracing' effect and the @pgmq@ interpreter:

  * @Nothing@ → 'runTracingNoop' + 'runPgmq'
  * @Just tr@ → 'runTracing' + 'runPgmqTraced'

The interpreter order matters: @runPgmq@/@runPgmqTraced@ require
@Error PgmqRuntimeError :> es@ and @IOE :> es@, so we peel @Pgmq@ first, then
@Tracing@, then @Error@, then @IOE@.
-}
runJobEff ::
    JobRuntime ->
    Eff '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] a ->
    IO (Either PgmqRuntimeError a)
runJobEff rt act =
    runEff $
        runErrorNoCallStack @PgmqRuntimeError $
            case rt.runtimeTracer of
                Nothing -> runTracingNoop (runPgmq rt.runtimePool act)
                Just tr -> runTracing tr (runPgmqTraced rt.runtimePool tr act)
