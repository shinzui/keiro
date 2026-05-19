-- | A minimal async-projection worker for the spike. Mirrors the
-- shape EP-3's async lifecycle uses without depending on shibuya:
-- the worker polls @readAllForward@ for new events past the
-- subscription's @last_seen@, applies a user-supplied per-event
-- handler, and advances the checkpoint in a separate connection
-- (mirroring shibuya-kiroku-adapter's at-least-once semantics — see
-- @docs/research/12-…@ §4 substrate facts).
module Spike.Projection
  ( ProjectionConfig (..)
  , defaultProjectionConfig
  , startProjection
  , stopProjection
  , ProjectionHandle
  , ensureSubscription
  ) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (try, SomeException)
import Control.Monad (when)
import Data.Int (Int64)
import Data.Vector qualified as V
import Data.Text (Text)

import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement

import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)

import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (runStorePool)
import Kiroku.Store.Error qualified as KErr
import Kiroku.Store.Read (readAllForward)
import Kiroku.Store.Types
  ( GlobalPosition (..)
  , RecordedEvent (..)
  )


data ProjectionConfig = ProjectionConfig
  { pcName            :: !Text
  , pcPageSize        :: !Int
  , pcPollDelayMs     :: !Int
  , pcPerEventDelayMs :: !Int
  }


defaultProjectionConfig :: Text -> ProjectionConfig
defaultProjectionConfig name = ProjectionConfig
  { pcName            = name
  , pcPageSize        = 64
  , pcPollDelayMs     = 25
  , pcPerEventDelayMs = 0
  }


data ProjectionHandle = ProjectionHandle
  { phAsync :: !(Async ())
  , phStop  :: !(TVar Bool)
  }


startProjection
  :: KirokuStore
  -> Pool.Pool
  -> ProjectionConfig
  -> (Pool.Pool -> RecordedEvent -> IO ())
  -> IO ProjectionHandle
startProjection store pool cfg handler = do
  stopFlag <- newTVarIO False
  worker <- async $ runWorker store pool cfg stopFlag handler
  pure ProjectionHandle { phAsync = worker, phStop = stopFlag }


stopProjection :: ProjectionHandle -> IO ()
stopProjection ph = do
  atomically $ writeTVar (phStop ph) True
  cancel (phAsync ph)


ensureSubscription :: Pool.Pool -> Text -> IO ()
ensureSubscription pool name = do
  result <- Pool.use pool (Session.statement name upsertStmt)
  case result of
    Right () -> pure ()
    Left err -> fail $ "ensureSubscription hasql error: " <> show err
  where
    upsertStmt :: Statement.Statement Text ()
    upsertStmt = Statement.preparable
      "INSERT INTO subscriptions (subscription_name) VALUES ($1) ON CONFLICT (subscription_name) DO NOTHING"
      (Encoders.param (Encoders.nonNullable Encoders.text))
      Decoders.noResult


runWorker
  :: KirokuStore
  -> Pool.Pool
  -> ProjectionConfig
  -> TVar Bool
  -> (Pool.Pool -> RecordedEvent -> IO ())
  -> IO ()
runWorker store pool cfg stopFlag handler = loop
  where
    loop = do
      stopped <- readTVarIO stopFlag
      if stopped
        then pure ()
        else stepLoop

    stepLoop = do
      lastSeen <- readLastSeen pool (pcName cfg)
      eRes <- try @SomeException $
        runEff
          . runErrorNoCallStack @KErr.StoreError
          . runStorePool store
          $ readAllForward (GlobalPosition lastSeen) (fromIntegral (pcPageSize cfg))
      case eRes of
        Left e -> do
          putStrLn $ "[projection " <> show (pcName cfg) <> "] error: " <> show e
          threadDelay (pcPollDelayMs cfg * 1000)
          loop
        Right (Left storeErr) -> do
          putStrLn $ "[projection " <> show (pcName cfg) <> "] store error: " <> show storeErr
          threadDelay (pcPollDelayMs cfg * 1000)
          loop
        Right (Right events) ->
          if V.null events
            then do
              threadDelay (pcPollDelayMs cfg * 1000)
              loop
            else do
              V.mapM_ (processOne pool cfg handler) events
              loop

    processOne
      :: Pool.Pool
      -> ProjectionConfig
      -> (Pool.Pool -> RecordedEvent -> IO ())
      -> RecordedEvent
      -> IO ()
    processOne p cfg' h ev = do
      when (pcPerEventDelayMs cfg' > 0) $
        threadDelay (pcPerEventDelayMs cfg' * 1000)
      h p ev
      let GlobalPosition pos = ev.globalPosition
      advanceLastSeen p (pcName cfg') pos


readLastSeen :: Pool.Pool -> Text -> IO Int64
readLastSeen pool name = do
  result <- Pool.use pool (Session.statement name stmt)
  case result of
    Right v  -> pure v
    Left err -> fail $ "readLastSeen hasql error: " <> show err
  where
    stmt :: Statement.Statement Text Int64
    stmt = Statement.preparable
      "SELECT COALESCE((SELECT last_seen FROM subscriptions WHERE subscription_name = $1), 0)"
      (Encoders.param (Encoders.nonNullable Encoders.text))
      (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))


advanceLastSeen :: Pool.Pool -> Text -> Int64 -> IO ()
advanceLastSeen pool name pos = do
  result <- Pool.use pool (Session.statement (name, pos) stmt)
  case result of
    Right () -> pure ()
    Left err -> fail $ "advanceLastSeen hasql error: " <> show err
  where
    nameTextEnc :: Encoders.Params (Text, Int64)
    nameTextEnc =
      contrazip2
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.int8))

    stmt :: Statement.Statement (Text, Int64) ()
    stmt = Statement.preparable
      "UPDATE subscriptions SET last_seen = $2, updated_at = now() WHERE subscription_name = $1 AND last_seen < $2"
      nameTextEnc
      Decoders.noResult
