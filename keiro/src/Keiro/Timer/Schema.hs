{- | The @keiro_timers@ table: storage and claim logic for durable timers.

Holds one row per scheduled timer with its 'TimerStatus' lifecycle.
'scheduleTimerTx' inserts (or re-arms a still-@Scheduled@ timer with the same
id) inside the caller's transaction; 'claimDueTimer' atomically picks the
single earliest due timer with @FOR UPDATE SKIP LOCKED@ and moves it to
@Firing@, so competing workers never claim the same timer; 'markTimerFired'
records completion and the produced event id.

Callers normally use the re-exports from "Keiro.Timer" rather than this
module directly.
-}
module Keiro.Timer.Schema
  ( -- * Rows and status
    TimerStatus (..)
  , TimerRow (..)

    -- * Storage
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

{- | A timer's lifecycle state.

* 'Scheduled' — waiting for its 'fireAt'; claimable.
* 'Firing' — claimed by a worker and being processed (re-claimable if the
  worker crashes before completing).
* 'Fired' — successfully fired; terminal.
* 'Cancelled' — withdrawn before firing; also the decode fallback for an
  unrecognized stored value.
-}
data TimerStatus
  = Scheduled
  | Firing
  | Fired
  | Cancelled
  deriving stock (Generic, Eq, Show)

{- | A timer row as stored: the original 'TimerRequest' fields plus the live
'status', the 'attempts' count (incremented on each claim), and the
'firedEventId' recorded once it fires.
-}
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

{- | Schedule a timer inside the caller's transaction (typically a process
manager's append). Upserts on 'timerId': a conflicting row is re-armed only
while it is still @Scheduled@, so a timer that has already fired or been
cancelled is not resurrected.
-}
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

{- | Atomically claim the single earliest timer due at @now@, moving it to
@Firing@ and bumping its attempt count. Uses @FOR UPDATE SKIP LOCKED@ so
concurrent workers each get a distinct timer. Returns 'Nothing' when none is
due.
-}
claimDueTimer :: (Store :> es) => UTCTime -> Eff es (Maybe TimerRow)
claimDueTimer now =
  runTransaction $
    Tx.statement now claimDueTimerStmt

-- | Mark a claimed timer @Fired@, recording the id of the event its firing
-- produced.
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
