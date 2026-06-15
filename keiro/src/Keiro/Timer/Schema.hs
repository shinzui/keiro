{- | The @keiro_timers@ table: storage and claim logic for durable timers.

Holds one row per scheduled timer with its 'TimerStatus' lifecycle.
'scheduleTimerTx' inserts (or re-arms a still-@Scheduled@ timer with the same
id) inside the caller's transaction; 'claimDueTimer' atomically picks the
single earliest due timer with @FOR UPDATE SKIP LOCKED@ and moves it to
@Firing@, so competing workers never claim the same timer; 'markTimerFired'
records completion and the produced event id. Stale @Firing@ rows are requeued
by 'requeueStuckTimers' so a crashed worker does not strand a timer forever.

Callers normally use the re-exports from "Keiro.Timer" rather than this
module directly.
-}
module Keiro.Timer.Schema (
    -- * Rows and status
    TimerStatus (..),
    TimerRow (..),

    -- * Storage
    scheduleTimerTx,
    scheduleTimerOnceTx,
    claimDueTimer,
    markTimerFired,

    -- * Read-only counts
    countDueTimers,
    countStuckTimers,

    -- * Recovery
    StuckTimerFilter (..),
    anyStuckTimer,
    findStuckTimers,
    requeueStuckTimers,
    requeueStuckTimer,
    cancelTimer,
    deadLetterTimer,
)
where

import Contravariant.Extras (contrazip2, contrazip6)
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID (UUID)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Timer.Types (TimerId (..), TimerRequest (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

{- | A timer's lifecycle state.

* 'Scheduled' — waiting for its 'fireAt'; claimable.
* 'Firing' — claimed by a worker and being processed; stale rows become
  claimable again when 'requeueStuckTimers' moves them back to 'Scheduled'.
* 'Fired' — successfully fired; terminal.
* 'Cancelled' — withdrawn before firing.
* 'Dead' — abandoned after exceeding the attempt ceiling; terminal; carries an
  optional @last_error@ describing why it was given up on.
-}
data TimerStatus
    = Scheduled
    | Firing
    | Fired
    | Cancelled
    | Dead
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

{- | Criteria selecting timers stranded in 'Firing'. A row is "stuck" when its
'status' is @firing@ and it matches every set bound: 'minAge' (it has been
firing at least this long, measured from @updated_at@) and 'minAttempts' (it
has been claimed at least this many times). Both unset selects every @firing@
row.
-}
data StuckTimerFilter = StuckTimerFilter
    { minAge :: !(Maybe NominalDiffTime)
    , minAttempts :: !(Maybe Int)
    }
    deriving stock (Generic, Eq, Show)

-- | Select every @firing@ row regardless of age or attempts.
anyStuckTimer :: StuckTimerFilter
anyStuckTimer = StuckTimerFilter Nothing Nothing

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

{- | Schedule a timer only if no row with the same 'timerId' already exists.

This is for callers whose first arm must win, such as durable workflow sleeps:
every resume pass re-runs the sleep arm until the timer fires, and preserving
the original 'fireAt' keeps the sleep measured from the first arm. Process
managers that intentionally push a deadline back should keep using
'scheduleTimerTx'.
-}
scheduleTimerOnceTx :: TimerRequest -> Tx.Transaction ()
scheduleTimerOnceTx request =
    Tx.statement
        ( timerIdToUuid (request ^. #timerId)
        , request ^. #processManagerName
        , request ^. #correlationId
        , request ^. #fireAt
        , request ^. #payload
        , statusToText Scheduled
        )
        scheduleTimerOnceStmt

{- | Atomically claim the single earliest timer due at @now@, moving it to
@Firing@ and bumping its attempt count. Uses @FOR UPDATE SKIP LOCKED@ so
concurrent workers each get a distinct timer. Returns 'Nothing' when none is
due.
-}
claimDueTimer :: (Store :> es) => UTCTime -> Eff es (Maybe TimerRow)
claimDueTimer now =
    runTransaction $
        Tx.statement now claimDueTimerStmt

{- | Mark a claimed timer @Fired@, recording the id of the event its firing
produced. Returns 'False' when the row left @Firing@ while the fire action was
running (for example, it was requeued, cancelled, or dead-lettered).
-}
markTimerFired :: (Store :> es) => TimerId -> EventId -> Eff es Bool
markTimerFired timerId eventId =
    runTransaction $
        Tx.statement (timerIdToUuid timerId, eventIdToUuid eventId) markTimerFiredStmt

{- | Count timers that are @scheduled@ and already due at @now@ — the timer
backlog. Read-only; mirrors 'claimDueTimer''s WHERE clause but counts rather
than locking, so it never claims or mutates a row.
-}
countDueTimers :: (Store :> es) => UTCTime -> Eff es Int
countDueTimers now =
    runTransaction $
        Tx.statement now countDueTimersStmt

{- | Count timers stranded in @Firing@ that match the given 'StuckTimerFilter' —
the same "stuck" predicate 'findStuckTimers' lists, evaluated against @now@.
Read-only. 'anyStuckTimer' counts every @firing@ row.
-}
countStuckTimers :: (Store :> es) => UTCTime -> StuckTimerFilter -> Eff es Int
countStuckTimers now stuckFilter =
    runTransaction $
        Tx.statement (cutoff, fmap fromIntegral (stuckFilter ^. #minAttempts)) countStuckTimersStmt
  where
    cutoff = fmap (\age -> addUTCTime (negate age) now) (stuckFilter ^. #minAge)

{- | List timers stranded in @Firing@ that match the given 'StuckTimerFilter'.
The @minAge@ bound is evaluated against @now@: a row qualifies when its
@updated_at@ is at least @minAge@ in the past (cutoff @now - minAge@). Results
are ordered oldest-first by @updated_at@.
-}
findStuckTimers ::
    (Store :> es) => UTCTime -> StuckTimerFilter -> Eff es [TimerRow]
findStuckTimers now stuckFilter =
    runTransaction $
        Tx.statement (cutoff, fmap fromIntegral (stuckFilter ^. #minAttempts)) findStuckTimersStmt
  where
    cutoff = fmap (\age -> addUTCTime (negate age) now) (stuckFilter ^. #minAge)

{- | Move every timer stranded in @Firing@ for at least @olderThan@ back to
@Scheduled@. The statement preserves @fire_at@, so a due timer becomes
claimable on the same worker pass. Returns the number of rows requeued.
-}
requeueStuckTimers :: (Store :> es) => NominalDiffTime -> UTCTime -> Eff es Int
requeueStuckTimers olderThan now =
    runTransaction $
        Tx.statement cutoff requeueStuckTimersStmt
  where
    cutoff = addUTCTime (negate olderThan) now

{- | Move a timer from @Firing@ back to @Scheduled@ so the ordinary claim loop
re-fires it. Leaves @fire_at@ unchanged, so a due timer becomes immediately
re-claimable. Idempotent: only @firing@ rows match, so re-running on an
already-requeued row affects nothing. Returns 'True' when a row changed.
-}
requeueStuckTimer :: (Store :> es) => TimerId -> Eff es Bool
requeueStuckTimer timerId =
    runTransaction $
        Tx.statement (timerIdToUuid timerId) requeueStuckTimerStmt

{- | Move a timer from @Scheduled@ or @Firing@ to the terminal @Cancelled@
state so it never fires. Terminal rows (@fired@, @cancelled@, @dead@) are left
untouched. Idempotent. Returns 'True' when a row changed.
-}
cancelTimer :: (Store :> es) => TimerId -> Eff es Bool
cancelTimer timerId =
    runTransaction $
        Tx.statement (timerIdToUuid timerId) cancelTimerStmt

{- | Move a timer from @Scheduled@ or @Firing@ to the terminal @Dead@ state,
recording @reason@ in @last_error@ so an operator can see why it was abandoned
(@SELECT * FROM keiro_timers WHERE status = 'dead'@). Terminal rows are left
untouched. Idempotent. Returns 'True' when a row changed.
-}
deadLetterTimer :: (Store :> es) => TimerId -> Text -> Eff es Bool
deadLetterTimer timerId reason =
    runTransaction $
        Tx.statement (timerIdToUuid timerId, reason) deadLetterTimerStmt

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

scheduleTimerOnceStmt :: Statement (UUID, Text, Text, UTCTime, Value, Text) ()
scheduleTimerOnceStmt =
    preparable
        """
        INSERT INTO keiro_timers
          (timer_id, process_manager_name, correlation_id, fire_at, payload, status)
        VALUES
          ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (timer_id) DO NOTHING
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

markTimerFiredStmt :: Statement (UUID, UUID) Bool
markTimerFiredStmt =
    preparable
        """
        UPDATE keiro_timers
        SET status = 'fired',
            fired_event_id = $2,
            updated_at = now()
        WHERE timer_id = $1
          AND status = 'firing'
        """
        ( contrazip2
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.uuid))
        )
        ((> 0) <$> D.rowsAffected)

countDueTimersStmt :: Statement UTCTime Int
countDueTimersStmt =
    preparable
        """
        SELECT count(*)
        FROM keiro_timers
        WHERE status = 'scheduled'
          AND fire_at <= $1
        """
        (E.param (E.nonNullable E.timestamptz))
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

countStuckTimersStmt :: Statement (Maybe UTCTime, Maybe Int64) Int
countStuckTimersStmt =
    preparable
        """
        SELECT count(*)
        FROM keiro_timers
        WHERE status = 'firing'
          AND ($1::timestamptz IS NULL OR updated_at <= $1)
          AND ($2::bigint IS NULL OR attempts >= $2)
        """
        ( contrazip2
            (E.param (E.nullable E.timestamptz))
            (E.param (E.nullable E.int8))
        )
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

findStuckTimersStmt :: Statement (Maybe UTCTime, Maybe Int64) [TimerRow]
findStuckTimersStmt =
    preparable
        """
        SELECT timer_id, process_manager_name, correlation_id, fire_at,
          payload, status, attempts, fired_event_id
        FROM keiro_timers
        WHERE status = 'firing'
          AND ($1::timestamptz IS NULL OR updated_at <= $1)
          AND ($2::bigint IS NULL OR attempts >= $2)
        ORDER BY updated_at, timer_id
        """
        ( contrazip2
            (E.param (E.nullable E.timestamptz))
            (E.param (E.nullable E.int8))
        )
        (D.rowList timerRowDecoder)

requeueStuckTimersStmt :: Statement UTCTime Int
requeueStuckTimersStmt =
    preparable
        """
        UPDATE keiro_timers
        SET status = 'scheduled',
            updated_at = now()
        WHERE status = 'firing'
          AND updated_at <= $1
        """
        (E.param (E.nonNullable E.timestamptz))
        (fromIntegral <$> D.rowsAffected)

requeueStuckTimerStmt :: Statement UUID Bool
requeueStuckTimerStmt =
    preparable
        """
        UPDATE keiro_timers
        SET status = 'scheduled',
            updated_at = now()
        WHERE timer_id = $1
          AND status = 'firing'
        """
        (E.param (E.nonNullable E.uuid))
        ((> 0) <$> D.rowsAffected)

cancelTimerStmt :: Statement UUID Bool
cancelTimerStmt =
    preparable
        """
        UPDATE keiro_timers
        SET status = 'cancelled',
            updated_at = now()
        WHERE timer_id = $1
          AND status IN ('scheduled', 'firing')
        """
        (E.param (E.nonNullable E.uuid))
        ((> 0) <$> D.rowsAffected)

deadLetterTimerStmt :: Statement (UUID, Text) Bool
deadLetterTimerStmt =
    preparable
        """
        UPDATE keiro_timers
        SET status = 'dead',
            last_error = $2,
            updated_at = now()
        WHERE timer_id = $1
          AND status IN ('scheduled', 'firing')
        """
        ( contrazip2
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.text))
        )
        ((> 0) <$> D.rowsAffected)

timerRowDecoder :: D.Row TimerRow
timerRowDecoder =
    TimerRow
        <$> (TimerId <$> D.column (D.nonNullable D.uuid))
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.jsonb)
        <*> D.column (D.nonNullable (D.refine statusFromText D.text))
        <*> (fromIntegral <$> D.column (D.nonNullable D.int8))
        <*> (fmap EventId <$> D.column (D.nullable D.uuid))

statusToText :: TimerStatus -> Text
statusToText = \case
    Scheduled -> "scheduled"
    Firing -> "firing"
    Fired -> "fired"
    Cancelled -> "cancelled"
    Dead -> "dead"

statusFromText :: Text -> Either Text TimerStatus
statusFromText = \case
    "scheduled" -> Right Scheduled
    "firing" -> Right Firing
    "fired" -> Right Fired
    "cancelled" -> Right Cancelled
    "dead" -> Right Dead
    other -> Left ("unknown keiro_timers.status: " <> other)

timerIdToUuid :: TimerId -> UUID
timerIdToUuid (TimerId uuid) = uuid

eventIdToUuid :: EventId -> UUID
eventIdToUuid (EventId uuid) = uuid
