{-# LANGUAGE OverloadedStrings #-}

-- | Spike driver. Boots an ephemeral Postgres, opens a kiroku store
-- against it, submits a sequence of Counter commands through the
-- spike's @runCommand@, and asserts the load -> fold -> decide ->
-- append cycle behaves as the EP-1 plan claims it does.
--
-- Acceptance (echoes EP-1 §"Validation and Acceptance"):
--
--   1. The append phase creates and grows the stream;
--      @readStreamForward@ returns the events at expected versions.
--   2. The hydration phase replays the stream into @(state, regs)@
--      via Streamly @Stream@ + @Fold@.
--   3. A workflow-flavoured ε-edge (the cooldown) advances state
--      under the @Tick@ command's register-file-driven guard,
--      emitting 'CooldownEnded' as a synthetic event for replay
--      determinism.
--   4. A deliberate concurrent-write contention is resolved by the
--      retry layer; the final counter value matches the analytical
--      sum of all submitted commands.
--
-- The program prints a transcript and exits 0; the final line
-- contains @OK@. Any assertion failure exits non-zero with
-- @failWith@.
module Main (main) where

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVarIO
  )
import Control.Exception (Exception, throwIO)
import Control.Monad (forM_, when)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Text (Text)
import Data.Time
  ( addUTCTime
  , getCurrentTime
  )
import qualified Data.Vector as V
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static
  ( Error
  , runErrorNoCallStack
  )

import qualified EphemeralPg as Pg

import Kiroku.Store.Connection
  ( KirokuStore
  , defaultConnectionSettings
  , withStore
  )
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types
  ( EventType (..)
  , RecordedEvent (..)
  , StreamName (..)
  , StreamVersion (..)
  )

import Spike.Codec (counterAggregate)
import Spike.Command (CommandError, runCommand)
import Spike.Counter
  ( CounterCmd (..)
  , DecrementData (..)
  , IncrementData (..)
  , TickData (..)
  )
import Spike.Retry
  ( RetryConfig
  , RetryError
  , defaultRetryConfig
  , runCommandRetry
  )


-- * Effect stack ---------------------------------------------------------

-- | The full effect stack used by the contention scenario. 'Store'
-- sits between the inner error layers and 'Error StoreError' so that
-- 'runStorePool' (which needs @Error StoreError@ in scope to throw)
-- is applied while the StoreError handler is still present.
type SpikeEffs =
  '[ Error RetryError
   , Error CommandError
   , Store
   , Error StoreError
   , IOE
   ]


-- | Run the full stack down to 'IO', failing loudly with
-- 'SpikeFailure' if any of the three error layers surface a value.
runSpike :: KirokuStore -> Eff SpikeEffs a -> IO a
runSpike store action = do
  result <-
        runEff
      . runErrorNoCallStack @StoreError
      . runStorePool store
      . runErrorNoCallStack @CommandError
      . runErrorNoCallStack @RetryError
      $ action
  case result of
    Left sErr                  -> failIO ("store: "   <> T.pack (show sErr))
    Right (Left cErr)          -> failIO ("command: " <> T.pack (show cErr))
    Right (Right (Left rErr))  -> failIO ("retry: "   <> T.pack (show rErr))
    Right (Right (Right v))    -> pure v


-- | Run a 'runCommand' (no retry layer) returning the surfaced
-- @CommandError@ as @Left@ — needed by 'scenario1' to assert that
-- an early 'Tick' is rejected.
runWithCommand
  :: KirokuStore
  -> Eff '[ Error CommandError, Store, Error StoreError, IOE ] a
  -> IO (Either StoreError (Either CommandError a))
runWithCommand store action =
      runEff
    . runErrorNoCallStack @StoreError
    . runStorePool store
    . runErrorNoCallStack @CommandError
    $ action


newtype SpikeFailure = SpikeFailure Text
  deriving stock (Show)
  deriving anyclass (Exception)


failIO :: Text -> IO a
failIO msg = throwIO (SpikeFailure msg)


-- * The aggregate's stream identity --------------------------------------

counterStream :: StreamName
counterStream = StreamName "counter-42"


-- * Driver --------------------------------------------------------------

main :: IO ()
main = do
  result <- Pg.with $ \db -> do
    let connStr  = Pg.connectionString db
        settings = defaultConnectionSettings connStr
    T.putStrLn $ "[spike] starting ephemeral-pg, connection: " <> connStr
    withStore settings $ \store -> do
      T.putStrLn "[spike] applied kiroku schema"
      driver store
  case result of
    Left err -> do
      hPutStrLn stderr $ "[spike] ephemeral-pg startup failed: " <> show err
      exitFailure
    Right () -> do
      T.putStrLn "[spike] OK"


-- | The full spike scenario.
driver :: KirokuStore -> IO ()
driver store = do
  scenario1 store
  scenario2 store


-- * Scenario 1 — sequential happy path ---------------------------------

-- | Sequential scenario: increment, decrement, observe the cooldown's
-- register-file-driven guard rejecting a too-early Tick, then a late
-- Tick succeeding. Verifies the event log matches the expected
-- sequence.
scenario1 :: KirokuStore -> IO ()
scenario1 store = do
  T.putStrLn "[spike] --- scenario 1: sequential happy-path ---"
  t0 <- getCurrentTime
  let tEarly = addUTCTime 0.001 t0   -- 1ms after t0; before cooldown ends
      tLate  = addUTCTime 1.000 t0   -- 1s after t0; well past cooldown

  _ <- runSpike store $
    runCommand counterAggregate counterStream (Increment (IncrementData t0))
  _ <- runSpike store $
    runCommand counterAggregate counterStream (Increment (IncrementData t0))
  _ <- runSpike store $
    runCommand counterAggregate counterStream (Decrement (DecrementData t0))

  earlyResult <- runWithCommand store $
    runCommand counterAggregate counterStream (Tick (TickData tEarly))
  case earlyResult of
    Right (Left _cmdErr) -> T.putStrLn "[spike] early Tick correctly rejected"
    Right (Right v)      -> failIO $ "early Tick should have been rejected, got: "
                              <> T.pack (show v)
    Left sErr            -> failIO $ "early Tick raised StoreError: "
                              <> T.pack (show sErr)

  _ <- runSpike store $
    runCommand counterAggregate counterStream (Tick (TickData tLate))
  _ <- runSpike store $
    runCommand counterAggregate counterStream (Increment (IncrementData t0))

  -- Read the stream back and verify the event-type sequence.
  events <-
        runEff
      . runErrorNoCallStack @StoreError
      . runStorePool store
      $ readStreamForward counterStream (StreamVersion 0) 1024
  case events of
    Right vec -> do
      let eventTypes = V.toList (V.map (eventTypeText . (.eventType)) vec)
      T.putStrLn $ "[spike] appended " <> T.pack (show (V.length vec))
                <> " events to " <> streamNameText counterStream
                <> ": " <> T.intercalate ", " eventTypes
      let expected =
            [ "Incremented", "Incremented", "Decremented"
            , "CooldownEnded", "Incremented"
            ]
      when (eventTypes /= expected) $
        failIO $ "scenario 1 event sequence mismatch. expected="
              <> T.pack (show expected) <> " got=" <> T.pack (show eventTypes)
    Left err -> failIO $ "readStreamForward failed: " <> T.pack (show err)


-- * Scenario 2 — contention test ---------------------------------------

-- | Contention scenario: two threads racing on the same aggregate.
-- Both go through 'runCommandRetry' so their 'WrongExpectedVersion'
-- collisions are absorbed by the retry loop. We observe retries
-- indirectly: a stream advancing by more than one between our pre-
-- and post-call reads means another thread interleaved a write.
scenario2 :: KirokuStore -> IO ()
scenario2 store = do
  T.putStrLn "[spike] --- scenario 2: contention test ---"
  let perThread = 10 :: Int
      threads   = 2 :: Int
      cfg       = defaultRetryConfig
  retryCount <- newTVarIO (0 :: Int)
  t0 <- getCurrentTime
  let runOne :: IO ()
      runOne = forM_ [1 .. perThread] $ \i -> do
        let cmd = Increment
              (IncrementData
                 (addUTCTime (realToFrac (i :: Int) * 0.001) t0))
        runOneCommand store cfg counterStream cmd retryCount

  concurrently_ runOne runOne

  observed <- readTVarIO retryCount
  T.putStrLn $ "[spike] contention test: "
            <> T.pack (show (perThread * threads))
            <> " commands across " <> T.pack (show threads)
            <> " threads, observed " <> T.pack (show observed) <> " retries"

  -- Hydrate the aggregate by replaying the full stream and checking
  -- the analytical counter value.
  events <-
        runEff
      . runErrorNoCallStack @StoreError
      . runStorePool store
      $ readStreamForward counterStream (StreamVersion 0) 4096
  case events of
    Right vec -> do
      let counterDelta = V.foldl' deltaFor 0 vec
      T.putStrLn $ "[spike] final counter (computed from event log): "
                <> T.pack (show counterDelta)
      -- Scenario 1 ended at counter = +2 -1 +1 = 2. Scenario 2 added
      -- 2 * perThread increments. Expected = 2 + 2*perThread.
      let expected = 2 + threads * perThread
      when (counterDelta /= expected) $
        failIO $ "final counter mismatch: expected="
              <> T.pack (show expected) <> " got=" <> T.pack (show counterDelta)
    Left err -> failIO $ "readStreamForward failed: " <> T.pack (show err)


-- | Run a single command via the retry-aware path. We measure
-- contention by comparing the stream's length before and after; an
-- unbroken append advances by 1, a contended append by >1 (the
-- difference is the number of inserts another thread won).
runOneCommand
  :: KirokuStore
  -> RetryConfig
  -> StreamName
  -> CounterCmd
  -> TVar Int
  -> IO ()
runOneCommand store cfg sn cmd retryCounter = do
  startVersion <- currentVersion store sn
  _ <- runSpike store (runCommandRetry cfg counterAggregate sn cmd)
  endVersion   <- currentVersion store sn
  let raced = max 0 (endVersion - startVersion - 1)
  when (raced > 0) $
    atomically (modifyTVar' retryCounter (+ raced))


currentVersion :: KirokuStore -> StreamName -> IO Int
currentVersion store sn = do
  result <-
        runEff
      . runErrorNoCallStack @StoreError
      . runStorePool store
      $ readStreamForward sn (StreamVersion 0) 4096
  case result of
    Right vec -> pure (V.length vec)
    Left _    -> pure 0


-- | Compute the counter delta contributed by one recorded event from
-- its @event_type@ alone — cheap probe that avoids decoding JSON.
deltaFor :: Int -> RecordedEvent -> Int
deltaFor acc recorded =
  case eventTypeText recorded.eventType of
    "Incremented" -> acc + 1
    "Decremented" -> acc - 1
    _             -> acc


-- * Tiny shims ----------------------------------------------------------

eventTypeText :: EventType -> Text
eventTypeText (EventType t) = t


streamNameText :: StreamName -> Text
streamNameText (StreamName t) = t
