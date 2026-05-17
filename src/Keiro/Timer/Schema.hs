{-# LANGUAGE MultilineStrings #-}

module Keiro.Timer.Schema
  ( TimerStatus (..)
  , TimerRow (..)
  , initializeTimerSchema
  , scheduleTimerTx
  , claimDueTimer
  , markTimerFired
  )
where

import Contravariant.Extras (contrazip2, contrazip6)
import Data.UUID (UUID)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Prelude
import Keiro.Timer.Types (TimerId (..), TimerRequest (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))

data TimerStatus
  = Scheduled
  | Firing
  | Fired
  | Cancelled
  deriving stock (Generic, Eq, Show)

data TimerRow = TimerRow
  { timerId :: !TimerId
  , processManagerName :: !Text
  , correlationId :: !Text
  , fireAt :: !UTCTime
  , payload :: !Value
  , status :: !TimerStatus
  , attempts :: !Int
  , firedEventId :: !(Maybe EventId)
  }
  deriving stock (Generic, Eq, Show)

-- | Compatibility helper for development and tests.
--
-- Production deployments should run @keiro-migrate@ before application startup.
initializeTimerSchema :: (Store :> es) => Eff es ()
initializeTimerSchema =
  runTransaction $
    Tx.sql
      """
      CREATE TABLE IF NOT EXISTS keiro_timers (
        timer_id UUID PRIMARY KEY,
        process_manager_name TEXT NOT NULL,
        correlation_id TEXT NOT NULL,
        fire_at TIMESTAMPTZ NOT NULL,
        payload JSONB NOT NULL,
        status TEXT NOT NULL DEFAULT 'scheduled',
        attempts BIGINT NOT NULL DEFAULT 0,
        fired_event_id UUID,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
        ON keiro_timers (status, fire_at, process_manager_name);
      """

scheduleTimerTx :: TimerRequest -> Tx.Transaction ()
scheduleTimerTx request =
  Tx.statement
    ( timerIdToUuid (request ^. #timerId)
    , request ^. #processManagerName
    , request ^. #correlationId
    , request ^. #fireAt
    , request ^. #payload
    , statusToText Scheduled
    )
    scheduleTimerStmt

claimDueTimer :: (Store :> es) => UTCTime -> Eff es (Maybe TimerRow)
claimDueTimer now =
  runTransaction $
    Tx.statement now claimDueTimerStmt

markTimerFired :: (Store :> es) => TimerId -> EventId -> Eff es ()
markTimerFired timerId eventId =
  runTransaction $
    Tx.statement (timerIdToUuid timerId, eventIdToUuid eventId) markTimerFiredStmt

scheduleTimerStmt :: Statement (UUID, Text, Text, UTCTime, Value, Text) ()
scheduleTimerStmt =
  preparable
    """
    INSERT INTO keiro_timers
      (timer_id, process_manager_name, correlation_id, fire_at, payload, status)
    VALUES
      ($1, $2, $3, $4, $5, $6)
    ON CONFLICT (timer_id) DO UPDATE
      SET process_manager_name = EXCLUDED.process_manager_name,
          correlation_id = EXCLUDED.correlation_id,
          fire_at = EXCLUDED.fire_at,
          payload = EXCLUDED.payload,
          status = EXCLUDED.status,
          updated_at = now()
      WHERE keiro_timers.status = 'scheduled'
    """
    ( contrazip6
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.jsonb))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

claimDueTimerStmt :: Statement UTCTime (Maybe TimerRow)
claimDueTimerStmt =
  preparable
    """
    WITH due AS (
      SELECT timer_id
      FROM keiro_timers
      WHERE status = 'scheduled'
        AND fire_at <= $1
      ORDER BY fire_at, timer_id
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    UPDATE keiro_timers kt
    SET status = 'firing',
        attempts = kt.attempts + 1,
        updated_at = now()
    FROM due
    WHERE kt.timer_id = due.timer_id
    RETURNING kt.timer_id, kt.process_manager_name, kt.correlation_id, kt.fire_at,
      kt.payload, kt.status, kt.attempts, kt.fired_event_id
    """
    (E.param (E.nonNullable E.timestamptz))
    (D.rowMaybe timerRowDecoder)

markTimerFiredStmt :: Statement (UUID, UUID) ()
markTimerFiredStmt =
  preparable
    """
    UPDATE keiro_timers
    SET status = 'fired',
        fired_event_id = $2,
        updated_at = now()
    WHERE timer_id = $1
    """
    ( contrazip2
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.uuid))
    )
    D.noResult

timerRowDecoder :: D.Row TimerRow
timerRowDecoder =
  TimerRow
    <$> (TimerId <$> D.column (D.nonNullable D.uuid))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.jsonb)
    <*> (statusFromText <$> D.column (D.nonNullable D.text))
    <*> (fromIntegral <$> D.column (D.nonNullable D.int8))
    <*> (fmap EventId <$> D.column (D.nullable D.uuid))

statusToText :: TimerStatus -> Text
statusToText = \case
  Scheduled -> "scheduled"
  Firing -> "firing"
  Fired -> "fired"
  Cancelled -> "cancelled"

statusFromText :: Text -> TimerStatus
statusFromText = \case
  "scheduled" -> Scheduled
  "firing" -> Firing
  "fired" -> Fired
  "cancelled" -> Cancelled
  _ -> Cancelled

timerIdToUuid :: TimerId -> UUID
timerIdToUuid (TimerId uuid) = uuid

eventIdToUuid :: EventId -> UUID
eventIdToUuid (EventId uuid) = uuid
