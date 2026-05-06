-- | Optimistic-retry wrapper for the spike's 'runCommand'. On
-- 'Kiroku.Store.Error.WrongExpectedVersion' the wrapper re-runs the
-- entire load -> fold -> decide -> append cycle up to 'maxRetries'
-- times. Other 'StoreError' variants escalate. 'DuplicateEvent' is
-- treated as success (the previous append committed) — relevant
-- only when callers supply 'EventData.eventId' for idempotency,
-- which the spike's 'runCommand' currently does not.
module Spike.Retry
  ( RetryConfig (..)
  , defaultRetryConfig
  , RetryError (..)
  , runCommandRetry
  ) where

import Control.Concurrent (threadDelay)

import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Error.Static (Error, catchError, throwError)

import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (StreamName)

import Keiki.Core (BoolAlg, RegFile)

import Spike.Aggregate (Aggregate)
import Spike.Command (CommandError, runCommand)


data RetryConfig = RetryConfig
  { maxRetries  :: !Int
  , sleepMicros :: !Int
  -- ^ Optional backoff between retries. The spike sets this very
  -- low (a few hundred microseconds) so the contention test
  -- finishes promptly; production keiro's analogue should use
  -- jittered exponential backoff per the M2 design doc.
  }
  deriving stock (Eq, Show)


defaultRetryConfig :: RetryConfig
defaultRetryConfig = RetryConfig
  { maxRetries  = 16
  , sleepMicros = 250
  }


-- | What surfaces when retries are exhausted. The carried
-- 'StoreError' is the last 'WrongExpectedVersion' the cycle saw
-- before giving up.
data RetryError = RetryExhausted !StreamName !StoreError
  deriving stock (Show)


-- | Run 'runCommand' with optimistic-retry on
-- 'WrongExpectedVersion'. Returns the value 'runCommand' returned
-- on a successful attempt.
runCommandRetry
  :: forall phi rs s ci co es.
     ( Store :> es
     , Error StoreError  :> es
     , Error CommandError :> es
     , Error RetryError   :> es
     , IOE :> es
     , BoolAlg phi (RegFile rs, ci)
     , Show ci
     )
  => RetryConfig
  -> Aggregate phi rs s ci co
  -> StreamName
  -> ci
  -> Eff es (Maybe co)
runCommandRetry cfg agg sn cmd = go 0
  where
    go :: Int -> Eff es (Maybe co)
    go n =
      runCommand agg sn cmd `catchError` \_callstack err -> case err of
        WrongExpectedVersion {}
          | n < maxRetries cfg -> do
              liftIO (threadDelay (sleepMicros cfg))
              go (n + 1)
          | otherwise          -> throwError (RetryExhausted sn err)
        DuplicateEvent {}      -> pure Nothing
        other                  -> throwError other
