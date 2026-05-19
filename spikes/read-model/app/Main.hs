{-# LANGUAGE OverloadedStrings #-}

-- | Spike driver for EP-8 (read-model query API and lifecycle).
-- Boots an ephemeral Postgres, opens a kiroku store, then runs three
-- scenarios that exercise the @ReadModel q r@ API end-to-end:
--
--   1. Inline projection (Strong consistency) — counter_view is
--      written in the same Postgres tx as the event append, via
--      kiroku-store's @runTransactionAppending@. A query
--      immediately after the command returns the new value.
--
--   2. Async projection + position-wait (PositionWait consistency).
--      counter_audit_view is populated by a background worker. The
--      caller appends, captures the global position, calls
--      @waitFor@, then queries — and sees the new audit row.
--
--   3. Position-wait timeout. The async worker is *not* started;
--      after appending, @waitFor@ with a short timeout returns a
--      'WaitTimeout' rather than blocking forever.
--
-- The driver prints a transcript and exits 0 on success; the final
-- line is @[read-model-spike] OK@. Any assertion failure exits
-- non-zero.
module Main (main) where

import Contravariant.Extras (contrazip4)
import Control.Exception (Exception)
import Data.Int (Int32, Int64)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Effectful (Eff, IOE, runEff, liftIO)
import Effectful.Error.Static
  ( Error
  , runErrorNoCallStack
  )
import Effectful.Reader.Static qualified as Reader

import EphemeralPg qualified as Pg

import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx

import Kiroku.Store.Connection
  ( KirokuStore (..)
  , defaultConnectionSettings
  , withStore
  )
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types
  ( EventId (..)
  , EventType (..)
  , RecordedEvent (..)
  , StreamName (..)
  )

import Spike.Codec (counterEventStream)
import Spike.Command (CommandError, runCommandInline)
import Spike.Counter
  ( CounterCmd (..)
  , IncrementData (..)
  )
import Spike.Projection
  ( defaultProjectionConfig
  , ensureSubscription
  , startProjection
  , stopProjection
  , ProjectionConfig (..)
  )
import Spike.ReadModel
  ( ConsistencyMode (..)
  , ReadModel (..)
  , WaitTimeout (..)
  , inlineSubscription
  , runQuery
  )


-- * Effect stack ---------------------------------------------------------

type SpikeEffs =
  '[ Error WaitTimeout
   , Reader.Reader Pool.Pool
   , Error CommandError
   , Store
   , Error StoreError
   , IOE
   ]


runSpike :: KirokuStore -> Pool.Pool -> Eff SpikeEffs a -> IO (Either SpikeFailure a)
runSpike store pool action = do
  result <-
        runEff
      . runErrorNoCallStack @StoreError
      . runStorePool store
      . runErrorNoCallStack @CommandError
      . Reader.runReader pool
      . runErrorNoCallStack @WaitTimeout
      $ action
  pure $ case result of
    Left storeErr           -> Left (StoreFailure storeErr)
    Right (Left cmdErr)     -> Left (CommandFailure cmdErr)
    Right (Right (Left wt)) -> Left (WaitFailure wt)
    Right (Right (Right v)) -> Right v


data SpikeFailure
  = StoreFailure StoreError
  | CommandFailure CommandError
  | WaitFailure WaitTimeout
  deriving (Show)

instance Exception SpikeFailure


-- * Read model values ----------------------------------------------------

counterView :: ReadModel Text (Maybe Int32)
counterView = ReadModel
  { rmName         = "counter_view"
  , rmTable        = "counter_view"
  , rmSubscription = inlineSubscription
  , rmConsistency  = Strong
  , rmQuery        = const $ Statement.preparable
      "SELECT current_value FROM counter_view WHERE counter_name = $1"
      (Encoders.param (Encoders.nonNullable Encoders.text))
      (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.int4)))
  }


counterAuditView :: ReadModel Text Int64
counterAuditView = ReadModel
  { rmName         = "counter_audit_view"
  , rmTable        = "counter_audit_view"
  , rmSubscription = "counter-audit"
  , rmConsistency  = PositionWait { pwTimeoutMs = 3000 }
  , rmQuery        = const $ Statement.preparable
      "SELECT COUNT(*)::int8 FROM counter_audit_view WHERE counter_name = $1"
      (Encoders.param (Encoders.nonNullable Encoders.text))
      (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
  }


-- * Schema setup ---------------------------------------------------------

execSql :: Pool.Pool -> Text -> IO ()
execSql pool sql = do
  result <- Pool.use pool (Session.script sql)
  case result of
    Right () -> pure ()
    Left err -> fail $ "execSql error: " <> show err


createReadModelTables :: Pool.Pool -> IO ()
createReadModelTables pool = do
  execSql pool
    """
    CREATE TABLE IF NOT EXISTS counter_view (
      counter_name TEXT PRIMARY KEY,
      current_value INT NOT NULL,
      source_event_id UUID NOT NULL
    )
    """
  execSql pool
    """
    CREATE TABLE IF NOT EXISTS counter_audit_view (
      source_event_id UUID PRIMARY KEY,
      counter_name TEXT NOT NULL,
      event_type TEXT NOT NULL,
      event_at TIMESTAMPTZ NOT NULL
    )
    """


-- * Inline projection write ---------------------------------------------

counterViewWrite :: Text -> a -> Tx.Transaction ()
counterViewWrite counterName _ = Tx.statement counterName upsertStmt
  where
    upsertStmt :: Statement.Statement Text ()
    upsertStmt = Statement.preparable
      """
      INSERT INTO counter_view (counter_name, current_value, source_event_id)
      VALUES ($1, 1, gen_random_uuid())
      ON CONFLICT (counter_name) DO UPDATE
        SET current_value = counter_view.current_value + 1,
            source_event_id = EXCLUDED.source_event_id
      """
      (Encoders.param (Encoders.nonNullable Encoders.text))
      Decoders.noResult


-- * Async projection handler --------------------------------------------

counterAuditHandler :: Text -> Pool.Pool -> RecordedEvent -> IO ()
counterAuditHandler counterName pool recorded = do
  let EventId evId   = recorded.eventId
      EventType evType = recorded.eventType
      evTime = recorded.createdAt
  result <- Pool.use pool $ Session.statement
    (evId, counterName, evType, evTime)
    insertStmt
  case result of
    Right () -> pure ()
    Left err -> fail $ "counterAuditHandler error: " <> show err
  where
    insertStmt :: Statement.Statement (UUID.UUID, Text, Text, UTCTime) ()
    insertStmt = Statement.preparable
      """
      INSERT INTO counter_audit_view (source_event_id, counter_name, event_type, event_at)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (source_event_id) DO NOTHING
      """
      enc
      Decoders.noResult

    enc :: Encoders.Params (UUID.UUID, Text, Text, UTCTime)
    enc =
      contrazip4
        (Encoders.param (Encoders.nonNullable Encoders.uuid))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.timestamptz))


-- * Helper: query latest globalPosition ---------------------------------

latestPosition :: Pool.Pool -> IO Int64
latestPosition pool = do
  result <- Pool.use pool (Session.statement () stmt)
  case result of
    Right v  -> pure v
    Left err -> fail $ "latestPosition error: " <> show err
  where
    stmt :: Statement.Statement () Int64
    stmt = Statement.preparable
      "SELECT COALESCE(MAX(stream_version), 0)::bigint FROM stream_events WHERE stream_id = 0"
      Encoders.noParams
      (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))


-- * Scenarios -----------------------------------------------------------

scenario1 :: KirokuStore -> Pool.Pool -> IO ()
scenario1 store pool = do
  T.putStrLn "[read-model-spike scenario 1] inline projection (Strong)"
  let streamName = StreamName "counter-strong"
      counterName = "strong"
  now <- getCurrentTime
  res <- runSpike store pool $ do
    _ <- runCommandInline counterEventStream streamName
           (Increment IncrementData { at = now })
           (counterViewWrite counterName)
    runQuery counterView counterName Nothing
  case res of
    Left e -> failWith ("scenario 1: " <> T.pack (show e))
    Right (Just 1) -> T.putStrLn "[read-model-spike scenario 1] OK"
    Right v -> failWith ("scenario 1 expected Just 1, got: " <> T.pack (show v))


scenario2 :: KirokuStore -> Pool.Pool -> IO ()
scenario2 store pool = do
  T.putStrLn "[read-model-spike scenario 2] async projection + position-wait"
  ensureSubscription pool "counter-audit"
  -- Skip historical events: position the cursor at the current head
  -- so the projection only sees events appended in this scenario.
  -- (A real keiro projection that is freshly registered does the
  -- same to avoid back-replaying events from before its lifetime.)
  startPos <- latestPosition pool
  execSql pool $
    "UPDATE subscriptions SET last_seen = " <> T.pack (show startPos)
      <> " WHERE subscription_name = 'counter-audit'"
  let counterName = "audit"
      cfg = (defaultProjectionConfig "counter-audit")
              { pcPerEventDelayMs = 50
              }
  ph <- startProjection store pool cfg (counterAuditHandler counterName)
  now <- getCurrentTime
  let streamName = StreamName "counter-audit-stream"
  res <- runSpike store pool $ do
    _ <- runCommandInline counterEventStream streamName
           (Increment IncrementData { at = now })
           (\_ -> pure ())
    targetPos <- liftIO (latestPosition pool)
    runQuery counterAuditView counterName (Just targetPos)
  stopProjection ph
  case res of
    Left e         -> failWith ("scenario 2: " <> T.pack (show e))
    Right 1        -> T.putStrLn "[read-model-spike scenario 2] OK"
    Right v        -> failWith ("scenario 2 expected count=1, got: " <> T.pack (show v))


scenario3 :: KirokuStore -> Pool.Pool -> IO ()
scenario3 store pool = do
  T.putStrLn "[read-model-spike scenario 3] position-wait timeout"
  ensureSubscription pool "counter-audit-stopped"
  let counterName = "stopped"
      streamName = StreamName "counter-stopped-stream"
      timeoutModel = counterAuditView
        { rmName         = "counter_audit_view_stopped"
        , rmSubscription = "counter-audit-stopped"
        , rmConsistency  = PositionWait { pwTimeoutMs = 300 }
        }
  now <- getCurrentTime
  res <- runSpike store pool $ do
    _ <- runCommandInline counterEventStream streamName
           (Increment IncrementData { at = now })
           (\_ -> pure ())
    targetPos <- liftIO (latestPosition pool)
    runQuery timeoutModel counterName (Just targetPos)
  case res of
    Left (WaitFailure WaitTimeout {}) ->
      T.putStrLn "[read-model-spike scenario 3] OK (got expected WaitTimeout)"
    Left e -> failWith ("scenario 3 unexpected error: " <> T.pack (show e))
    Right v -> failWith ("scenario 3 expected timeout, got count=" <> T.pack (show v))


-- * Driver ---------------------------------------------------------------

main :: IO ()
main = do
  result <- Pg.with $ \db -> do
    let connStr = Pg.connectionString db
        settings = defaultConnectionSettings connStr
    T.putStrLn $ "[read-model-spike] starting ephemeral-pg, connection: " <> connStr
    withStore settings $ \store -> do
      let pool = store.pool
      T.putStrLn "[read-model-spike] applied kiroku schema"
      createReadModelTables pool
      scenario1 store pool
      scenario2 store pool
      scenario3 store pool
  case result of
    Left err -> do
      hPutStrLn stderr $ "[read-model-spike] ephemeral-pg startup failed: " <> show err
      exitFailure
    Right () -> T.putStrLn "[read-model-spike] OK"


failWith :: Text -> IO a
failWith msg = do
  hPutStrLn stderr (T.unpack msg)
  exitFailure
