-- | The spike's @ReadModel q r@ wrapper plus the @runQuery@,
-- @runQueryWith@, and @waitFor@ helpers. Mirrors the design fixed in
-- @docs/research/12-read-model-query-api-and-lifecycle.md@ §5 and §10
-- with two simplifications appropriate for a research spike:
--
-- * The @keiro_read_models@ metadata table and the version /
--   shape-hash mismatch check (design doc §6) are omitted. The spike
--   exercises a single read-model lifetime; rebuild semantics are
--   design-only here.
--
-- * 'rmRowCodec' is omitted; the spike relies on each
--   @ReadModel q r@'s 'rmQuery' carrying its own hasql decoder. The
--   production keiro library pairs the two for the rebuild protocol;
--   the spike does not exercise rebuild.
--
-- The fields and the consistency-mode taxonomy are otherwise
-- as the design doc specifies. Validating them is the spike's job.
module Spike.ReadModel
  ( ReadModel (..)
  , ConsistencyMode (..)
  , WaitTimeout (..)
  , inlineSubscription
  , runQuery
  , runQueryWith
  , waitFor
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (MkSystemTime), getSystemTime)
import Data.Text (Text)
import Data.Text qualified as T

import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Error.Static (Error, throwError)
import Effectful.Reader.Static qualified as Reader

import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement


-- | The typed wrapper. Spike shape (see module header for the two
-- simplifications relative to the design doc).
data ReadModel q r = ReadModel
  { rmName         :: !Text
    -- ^ Application-globally-unique identifier. Used in error
    -- messages and OpenTelemetry attributes (the latter is
    -- design-only in the spike).
  , rmTable        :: !Text
    -- ^ Read-model row table name. Owned by the application's
    -- migrations; the spike's Main.hs creates them inline.
  , rmSubscription :: !Text
    -- ^ The kiroku subscription whose @last_seen@ feeds 'waitFor'.
    -- Set to 'inlineSubscription' for read models fed by an inline
    -- projection (the wait short-circuits to a no-op).
  , rmConsistency  :: !ConsistencyMode
    -- ^ Default mode for queries against this read model. Per-call
    -- overrides via 'runQueryWith'.
  , rmQuery        :: !(q -> Statement.Statement q r)
    -- ^ Application's hasql query, parameterised on the query
    -- argument @q@ and decoded to @r@.
  }


-- | Sentinel value for 'rmSubscription' indicating the read model is
-- fed by an inline projection. 'waitFor' short-circuits when it sees
-- this; design doc §10.6.
inlineSubscription :: Text
inlineSubscription = "<inline>"


-- | The three consistency modes. 'PositionWait' carries its
-- timeout in milliseconds (design doc §3.3).
data ConsistencyMode
  = Strong
  | Eventual
  | PositionWait { pwTimeoutMs :: !Int }
  deriving stock (Eq, Show)


-- | Returned in 'Eff es'\'s error channel by 'waitFor' on timeout.
-- Carries the target the caller asked for, the most recent
-- @last_seen@ observed, and the read-model name for diagnostics.
data WaitTimeout = WaitTimeout
  { wtTarget   :: !Int64
  , wtObserved :: !Int64
  , wtModel    :: !Text
  }
  deriving stock (Eq, Show)


-- | Run a query against a read model, using its declared default
-- consistency mode. The 'Maybe Int64' is the target global position
-- for 'PositionWait' callers; pass @Nothing@ when the call has no
-- "the just-prior write" target (e.g., a dashboard refresh).
runQuery
  :: forall q r es.
     ( Reader.Reader Pool.Pool :> es
     , Error WaitTimeout :> es
     , IOE :> es
     )
  => ReadModel q r
  -> q
  -> Maybe Int64
  -> Eff es r
runQuery rm q target = runQueryWith rm q (rmConsistency rm) target


-- | Run a query overriding the read model's default consistency mode.
-- Useful when an otherwise-eventual-consistency read model needs a
-- one-off read-after-write semantics for a particular call.
runQueryWith
  :: forall q r es.
     ( Reader.Reader Pool.Pool :> es
     , Error WaitTimeout :> es
     , IOE :> es
     )
  => ReadModel q r
  -> q
  -> ConsistencyMode
  -> Maybe Int64
  -> Eff es r
runQueryWith rm q mode target = do
  case mode of
    Strong   -> pure ()
    Eventual -> pure ()
    PositionWait {} ->
      case target of
        Just pos -> waitFor' rm pos (modeTimeoutMs mode)
        Nothing  -> pure ()  -- degrades to Eventual
  pool <- Reader.ask
  result <- liftIO $ Pool.use pool (Session.statement q (rmQuery rm q))
  case result of
    Right v  -> pure v
    Left err -> liftIO . fail $
      "runQueryWith[" <> T.unpack (rmName rm) <> "] hasql error: " <> show err


-- | Block until the read model's projection has caught up to a
-- target global position. For inline-fed read models (whose
-- 'rmSubscription' is 'inlineSubscription') returns immediately as
-- a no-op (design doc §10.6).
--
-- The default timeout (5 seconds) applies when 'rmConsistency' is
-- 'PositionWait { pwTimeoutMs }' — the carried value wins. If
-- 'rmConsistency' is 'Strong' or 'Eventual' but a caller still
-- invokes 'waitFor', the conservative 5 s default applies.
waitFor
  :: forall q r es.
     ( Reader.Reader Pool.Pool :> es
     , Error WaitTimeout :> es
     , IOE :> es
     )
  => ReadModel q r
  -> Int64
  -> Eff es ()
waitFor rm target = waitFor' rm target (modeTimeoutMs (rmConsistency rm))


waitFor'
  :: forall q r es.
     ( Reader.Reader Pool.Pool :> es
     , Error WaitTimeout :> es
     , IOE :> es
     )
  => ReadModel q r
  -> Int64
  -> Int     -- ^ Timeout in milliseconds.
  -> Eff es ()
waitFor' rm target timeoutMs
  | rmSubscription rm == inlineSubscription = pure ()
  | otherwise = do
      pool <- Reader.ask
      startMs <- liftIO nowMs
      let loop interval = do
            observed <- liftIO $ queryLastSeen pool (rmSubscription rm)
            if observed >= target
              then pure ()
              else do
                now <- liftIO nowMs
                if now - startMs >= fromIntegral timeoutMs
                  then throwError $ WaitTimeout
                         { wtTarget   = target
                         , wtObserved = observed
                         , wtModel    = rmName rm
                         }
                  else do
                    liftIO (threadDelay (interval * 1000))
                    loop (min pollMaxMs (interval * 2))
      loop pollMinMs


-- | Initial polling interval, in milliseconds. Design doc §10.2 fixes
-- the value at 50 ms; the spike copies it.
pollMinMs :: Int
pollMinMs = 50


-- | Cap on the polling interval, in milliseconds. Design doc §10.2
-- fixes the value at 500 ms.
pollMaxMs :: Int
pollMaxMs = 500


modeTimeoutMs :: ConsistencyMode -> Int
modeTimeoutMs (PositionWait t) = t
modeTimeoutMs Strong           = 5000
modeTimeoutMs Eventual         = 5000


-- | The single SQL the polling loop runs:
-- @SELECT last_seen FROM subscriptions WHERE subscription_name = $1@.
-- Returns 0 when the row does not exist (the projection has never
-- written a checkpoint).
queryLastSeen :: Pool.Pool -> Text -> IO Int64
queryLastSeen pool name = do
  result <- Pool.use pool (Session.statement name selectStmt)
  case result of
    Right v -> pure v
    Left err -> do
      _ <- try @IOError (fail ("queryLastSeen hasql error: " <> show err))
      pure 0
  where
    selectStmt :: Statement.Statement Text Int64
    selectStmt = Statement.preparable
      "SELECT COALESCE((SELECT last_seen FROM subscriptions WHERE subscription_name = $1), 0)"
      (Encoders.param (Encoders.nonNullable Encoders.text))
      (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))


nowMs :: IO Int64
nowMs = do
  MkSystemTime secs nsecs <- getSystemTime
  pure $ fromIntegral secs * 1000 + fromIntegral nsecs `div` 1_000_000
