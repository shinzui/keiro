module Keiro.Ops.Http.Budget
  ( InspectionBudget,
    BudgetFailure (..),
    newInspectionBudget,
    withInspectionAdmission,
    withInspectionDeadline,
    withInspectionBudget,
    encodeBounded,
  )
where

import Control.Concurrent.STM
import Control.Exception (bracket, evaluate, mask)
import Data.Aeson (Value, encode)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Keiro.Ops.Http.Config
import System.Timeout (timeout)

-- | One mount's admission counter; feed refreshes share this exact handle.
data InspectionBudget = InspectionBudget !Int !(TVar Int)

data BudgetFailure = InspectionBusy | InspectionTimedOut
  deriving stock (Eq, Show)

newInspectionBudget :: InspectionLimits -> IO InspectionBudget
newInspectionBudget limits
  | any (<= 0) values || any (> maxBound `div` 1000000) deadlines =
      ioError (userError "inspection limits must be positive and deadlines representable in microseconds")
  | otherwise = InspectionBudget limits.maxConcurrentReads <$> newTVarIO 0
  where
    deadlines = [limits.readDeadlineSeconds, limits.mutationDeadlineSeconds]
    values = deadlines <> [limits.maxConcurrentReads, limits.statementTimeoutMillis, limits.maxResponseBytes, limits.maxRequestBytes]

-- | No waiting queue. Timed-out or cancelled work unwinds before releasing the
-- permit. Exceptions from work are preserved.
withInspectionBudget :: InspectionBudget -> Int -> IO a -> IO (Either BudgetFailure a)
withInspectionBudget budget seconds action = do
  result <- withInspectionAdmission budget (withInspectionDeadline seconds action)
  pure (either Left id result)

-- | Keep the permit through response delivery as well as computation, so slow
-- clients cannot retain an unbounded number of encoded response bodies.
withInspectionAdmission :: InspectionBudget -> IO a -> IO (Either BudgetFailure a)
withInspectionAdmission (InspectionBudget capacity active) action = mask $ \restore -> do
  admitted <- atomically $ do
    count <- readTVar active
    if count >= capacity then pure False else writeTVar active (count + 1) >> pure True
  if not admitted
    then pure (Left InspectionBusy)
    else bracket (pure ()) (const (atomically (modifyTVar' active (subtract 1)))) $ \_ -> do
      Right <$> restore action

-- | Bound computation separately from delivery: once headers are sent, a
-- computation timeout response can no longer be substituted safely.
withInspectionDeadline :: Int -> IO a -> IO (Either BudgetFailure a)
withInspectionDeadline seconds action = do
  -- The threaded RTS timer manager delivers an async exception on expiry;
  -- successful reads reuse the request thread rather than allocating two Async
  -- threads and fresh stacks per request. timeout owns timer cleanup as well as
  -- unwinding the action before returning Nothing.
  outcome <- timeout (seconds * 1000000) action
  pure (maybe (Left InspectionTimedOut) Right outcome)

-- | Demand at most the cap plus one byte of Aeson's lazy output. Force the
-- bounded body before leaving the deadline; no partial result is served.
encodeBounded :: Int -> Value -> IO (Maybe LazyByteString.ByteString)
encodeBounded limit value = do
  let prefix = LazyByteString.take (fromIntegral limit + 1) (encode value)
  size <- evaluate (LazyByteString.length prefix)
  if size > fromIntegral limit
    then pure Nothing
    else do
      body <- evaluate (LazyByteString.toStrict prefix)
      _ <- evaluate (ByteString.length body)
      pure (Just (LazyByteString.fromStrict body))
