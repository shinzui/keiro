-- | The @keiro_timers@ table: storage and claim logic for durable timers.
--
-- Holds one row per scheduled timer with its 'TimerStatus' lifecycle.
-- 'scheduleTimerTx' inserts (or re-arms a still-@Scheduled@ timer with the same
-- id) inside the caller's transaction; 'claimDueTimer' atomically picks the
-- single earliest due timer with @FOR UPDATE SKIP LOCKED@ and moves it to
-- @Firing@, so competing workers never claim the same timer; 'markTimerFired'
-- records completion and the produced event id. Stale @Firing@ rows are requeued
-- by 'requeueStuckTimers' so a crashed worker does not strand a timer forever.
--
-- ID-only completion, cancellation, dead-lettering and requeueing refuse all
-- token-bearing foreground claims, including expired claims awaiting recovery.
--
-- Callers normally use the re-exports from "Keiro.Timer" rather than this
-- module directly.
module Keiro.Timer.Schema
  ( -- * Rows and status
    TimerStatus (..),
    TimerRow (..),

    -- * Read-only inspection
    TimerInspection (..),
    TimerReasonFilter (..),
    DeadTimerFilter (..),
    anyDeadTimer,
    DeadTimerPageRequest (..),
    DeadTimerReadError (..),
    DeadTimerPage (..),
    lookupTimerInspection,
    findDeadTimers,

    -- * Guarded foreground resume
    DeadTimerClaimRequest (..),
    TimerResumeError (..),
    TimerResumeClaim,
    resumeClaimTimer,
    resumeClaimLeaseUntil,
    claimDeadTimer,
    renewTimerResume,
    completeTimerResume,
    parkTimerResume,
    cancelTimerResume,
    recoverExpiredTimerResumes,

    -- * Storage
    scheduleTimerTx,
    scheduleTimerOnceTx,
    claimDueTimer,
    lookupTimer,
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

import Contravariant.Extras (contrazip2, contrazip5, contrazip6)
import Data.Int (Int32)
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID (UUID)
import Data.UUID.V4 qualified as UUIDv4
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Timer.Types (TimerId (..), TimerRequest (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- | A timer's lifecycle state.
--
-- * 'Scheduled' — waiting for its 'fireAt'; claimable.
-- * 'Firing' — claimed by a worker and being processed; stale rows become
--   claimable again when 'requeueStuckTimers' moves them back to 'Scheduled'.
-- * 'Fired' — successfully fired; terminal.
-- * 'Cancelled' — withdrawn before firing.
-- * 'Dead' — parked or abandoned; guarded foreground resume is possible; carries an
--   optional @last_error@ describing why it was given up on.
data TimerStatus
  = Scheduled
  | Firing
  | Fired
  | Cancelled
  | Dead
  -- 'Enum'/'Bounded' let a consumer enumerate the complete lifecycle rather than
  -- restate it; keiro-dsl's cross-package vocabulary test relies on this.
  deriving stock (Generic, Eq, Show, Enum, Bounded)

-- | A timer row as stored: the original 'TimerRequest' fields plus the live
-- 'status', the 'attempts' count (incremented on each claim), and the
-- 'firedEventId' recorded once it fires.
data TimerRow = TimerRow
  { timerId :: !TimerId,
    processManagerName :: !Text,
    correlationId :: !Text,
    fireAt :: !UTCTime,
    payload :: !Value,
    status :: !TimerStatus,
    attempts :: !Int,
    firedEventId :: !(Maybe EventId)
  }
  deriving stock (Generic, Eq, Show)

-- | Original timer metadata and the full stored reason. NULL and empty text
-- remain distinct. Reading does not claim work or authorize its disclosure.
data TimerInspection = TimerInspection
  { timer :: !TimerRow,
    lastError :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | Case-sensitive literal reason matching. An empty prefix matches every
-- non-NULL reason; percent, underscore, and backslash are ordinary characters.
data TimerReasonFilter
  = AnyTimerReason
  | ReasonAbsent
  | ReasonExact !Text
  | ReasonPrefix !Text
  deriving stock (Generic, Eq, Show)

-- | Dead rows matching both the optional exact owner and the reason predicate.
-- The owner label is not an application authorization credential.
data DeadTimerFilter = DeadTimerFilter
  { processManagerName :: !(Maybe Text),
    reason :: !TimerReasonFilter
  }
  deriving stock (Generic, Eq, Show)

-- | Select all dead timers.
anyDeadTimer :: DeadTimerFilter
anyDeadTimer = DeadTimerFilter Nothing AnyTimerReason

-- | Request 1 through 100 rows, strictly after an optional UUID cursor.
-- Restart without a cursor when changing filters.
data DeadTimerPageRequest = DeadTimerPageRequest
  { pageSize :: !Int,
    afterTimerId :: !(Maybe TimerId)
  }
  deriving stock (Generic, Eq, Show)

-- | Invalid sizes are rejected before database access, without clamping.
data DeadTimerReadError = InvalidDeadTimerPageSize !Int
  deriving stock (Generic, Eq, Show)

-- | Ascending UUID order, not chronological order. Continuation exists only
-- when another matching row was observed. Requests see current eligibility,
-- not a shared snapshot: newly eligible IDs behind the cursor are not revisited.
data DeadTimerPage = DeadTimerPage
  { timers :: ![TimerInspection],
    nextAfterTimerId :: !(Maybe TimerId)
  }
  deriving stock (Generic, Eq, Show)

-- | Inspect any lifecycle state without mutations or row-claim locks.
lookupTimerInspection :: (Store :> es) => TimerId -> Eff es (Maybe TimerInspection)
lookupTimerInspection timerId =
  runTransaction $ Tx.statement (timerIdToUuid timerId) lookupTimerInspectionStmt

-- | Observe a bounded page of dead timers. Limits bound returned rows, not
-- database search cost. Callers must decode and authorize before rendering,
-- following storage continuation even if authorization removes an entire page.
findDeadTimers ::
  (Store :> es) =>
  DeadTimerFilter ->
  DeadTimerPageRequest ->
  Eff es (Either DeadTimerReadError DeadTimerPage)
findDeadTimers deadFilter request
  | size < 1 || size > 100 = pure (Left (InvalidDeadTimerPageSize size))
  | otherwise = do
      rows <-
        runTransaction $
          Tx.statement
            ( deadFilter ^. #processManagerName,
              mode,
              reasonText,
              timerIdToUuid <$> request ^. #afterTimerId,
              fromIntegral size + 1
            )
            findDeadTimersStmt
      let selected = take size rows
          continuation = case drop size rows of
            [] -> Nothing
            _ -> case reverse selected of
              lastRow : _ -> Just (lastRow ^. #timer . #timerId)
              [] -> Nothing
      pure (Right (DeadTimerPage selected continuation))
  where
    size = request ^. #pageSize
    (mode, reasonText) = case deadFilter ^. #reason of
      AnyTimerReason -> (0, Nothing)
      ReasonAbsent -> (1, Nothing)
      ReasonExact value -> (2, Just value)
      ReasonPrefix value -> (3, Just value)

-- | Exact dead-row guards and an explicit total attempt ceiling. Lease seconds
-- must be between 1 and 2147483647, avoiding interval conversion overflow.
data DeadTimerClaimRequest = DeadTimerClaimRequest
  { timerId :: !TimerId,
    processManagerName :: !Text,
    expectedReason :: !Text,
    maxAttempts :: !Int,
    leaseSeconds :: !Int
  }
  deriving stock (Generic, Eq, Show)

data TimerResumeError
  = InvalidTimerResumeMaxAttempts !Int
  | InvalidTimerResumeLeaseSeconds !Int
  deriving stock (Generic, Eq, Show)

-- | Opaque storage ownership, not application authorization.
data TimerResumeClaim = TimerResumeClaim !TimerRow !UUID !UTCTime

-- | Original work as claimed, including the incremented attempt count.
resumeClaimTimer :: TimerResumeClaim -> TimerRow
resumeClaimTimer (TimerResumeClaim row _ _) = row

-- | Claim-time snapshot only. Renewals retain the token and update the database;
-- schedule renewals by the requested interval, not this old snapshot.
resumeClaimLeaseUntil :: TimerResumeClaim -> UTCTime
resumeClaimLeaseUntil (TimerResumeClaim _ _ deadline) = deadline

validResumeLease :: Int -> Bool
validResumeLease seconds = seconds > 0 && toInteger seconds <= toInteger (maxBound :: Int32)

-- | Claim only the exact owner and non-NULL reason. Refusal consumes no attempt.
-- Authorize and establish session availability before calling; execute outside
-- the retried SQL transaction, only after receiving ownership.
claimDeadTimer :: (IOE :> es, Store :> es) => DeadTimerClaimRequest -> Eff es (Either TimerResumeError (Maybe TimerResumeClaim))
claimDeadTimer request
  | request ^. #maxAttempts < 0 = pure (Left (InvalidTimerResumeMaxAttempts (request ^. #maxAttempts)))
  | not (validResumeLease (request ^. #leaseSeconds)) = pure (Left (InvalidTimerResumeLeaseSeconds (request ^. #leaseSeconds)))
  | otherwise = do
      token <- liftIO UUIDv4.nextRandom
      Right
        <$> runTransaction
          ( do
              lockTimerResumeTx (request ^. #timerId)
              Tx.statement
                ( timerIdToUuid (request ^. #timerId),
                  request ^. #processManagerName,
                  request ^. #expectedReason,
                  fromIntegral (request ^. #maxAttempts),
                  token,
                  fromIntegral (request ^. #leaseSeconds)
                )
                claimDeadTimerStmt
          )

-- Lock in a separate statement: subsequent predicates and clock_timestamp()
-- observe the committed winner after a ReadCommitted lock wait.
lockTimerResumeTx :: TimerId -> Tx.Transaction ()
lockTimerResumeTx tid = void $ Tx.statement (timerIdToUuid tid) lockTimerResumeStmt

lockTimerResumeStmt :: Statement UUID (Maybe UUID)
lockTimerResumeStmt =
  preparable
    "SELECT timer_id FROM keiro.keiro_timers WHERE timer_id = $1 FOR UPDATE"
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe (D.column (D.nonNullable D.uuid)))

claimDeadTimerStmt :: Statement (UUID, Text, Text, Int64, UUID, Int32) (Maybe TimerResumeClaim)
claimDeadTimerStmt =
  preparable
    """
    WITH stamp AS MATERIALIZED (SELECT clock_timestamp() AS now)
    UPDATE keiro.keiro_timers kt
    SET status = 'firing', attempts = attempts + 1,
        resume_claim_token = $5, resume_lease_until = stamp.now + $6::integer * interval '1 second',
        updated_at = stamp.now
    FROM stamp
    WHERE timer_id = $1 AND status = 'dead'
      AND process_manager_name COLLATE "C" = $2
      AND last_error COLLATE "C" = $3 AND attempts < $4
    RETURNING kt.timer_id, kt.process_manager_name, kt.correlation_id, kt.fire_at,
      kt.payload, kt.status, kt.attempts, kt.fired_event_id, kt.resume_claim_token, kt.resume_lease_until
    """
    ( contrazip6
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.int4))
    )
    (D.rowMaybe (TimerResumeClaim <$> timerRowDecoder <*> D.column (D.nonNullable D.uuid) <*> D.column (D.nonNullable D.timestamptz)))

-- | Extend from database time. False means ownership was lost; an expired claim
-- cannot be revived. Stop local work where possible on loss of ownership.
renewTimerResume :: (Store :> es) => TimerResumeClaim -> Int -> Eff es (Either TimerResumeError Bool)
renewTimerResume claim seconds
  | not (validResumeLease seconds) = pure (Left (InvalidTimerResumeLeaseSeconds seconds))
  | otherwise = Right <$> mutateTimerResume claim "firing" Nothing (Just (fromIntegral seconds))

-- | Complete with the resulting event. False must not be reported as successful
-- timer completion. External effects still need caller-owned idempotency.
completeTimerResume :: (Store :> es) => TimerResumeClaim -> EventId -> Eff es Bool
completeTimerResume claim event = mutateTimerResume claim "fired" (Just (eventIdToUuid event)) Nothing

-- | Return to Dead with the original reason and incremented attempts retained.
parkTimerResume :: (Store :> es) => TimerResumeClaim -> Eff es Bool
parkTimerResume claim = mutateTimerResume claim "dead" Nothing Nothing

-- | Explicit abandonment by the current owner.
cancelTimerResume :: (Store :> es) => TimerResumeClaim -> Eff es Bool
cancelTimerResume claim = mutateTimerResume claim "cancelled" Nothing Nothing

mutateTimerResume :: (Store :> es) => TimerResumeClaim -> Text -> Maybe UUID -> Maybe Int32 -> Eff es Bool
mutateTimerResume (TimerResumeClaim row token _) target event seconds = runTransaction $ do
  lockTimerResumeTx (row ^. #timerId)
  Tx.statement (timerIdToUuid (row ^. #timerId), token, target, event, seconds) mutateTimerResumeStmt

mutateTimerResumeStmt :: Statement (UUID, UUID, Text, Maybe UUID, Maybe Int32) Bool
mutateTimerResumeStmt =
  preparable
    """
    WITH stamp AS MATERIALIZED (SELECT clock_timestamp() AS now)
    UPDATE keiro.keiro_timers
    SET status = $3,
        fired_event_id = CASE WHEN $3 = 'fired' THEN $4 ELSE fired_event_id END,
        resume_claim_token = CASE WHEN $5::integer IS NULL THEN NULL ELSE resume_claim_token END,
        resume_lease_until = CASE WHEN $5::integer IS NULL THEN NULL ELSE stamp.now + $5 * interval '1 second' END,
        updated_at = stamp.now
    FROM stamp
    WHERE timer_id = $1 AND resume_claim_token = $2 AND status = 'firing'
      AND resume_lease_until > stamp.now
    """
    ( contrazip5
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.uuid))
        (E.param (E.nullable E.int4))
    )
    ((> 0) <$> D.rowsAffected)

-- | Re-park expired foreground work directly to Dead. Foreground-only hosts
-- must run this periodically and before discovery/resume. Ordinary worker passes
-- also run it, independently of their ordinary stale-claim recovery option.
recoverExpiredTimerResumes :: (Store :> es) => Eff es Int
recoverExpiredTimerResumes = runTransaction $ do
  -- Deterministic lock ordering, with a fresh predicate in the second statement.
  ids <- Tx.statement () lockExpiredTimerResumesStmt
  sum <$> traverse (\tid -> Tx.statement tid recoverExpiredTimerResumesStmt) ids

lockExpiredTimerResumesStmt :: Statement () [UUID]
lockExpiredTimerResumesStmt =
  preparable
    """
    SELECT timer_id FROM keiro.keiro_timers
    WHERE status = 'firing' AND resume_claim_token IS NOT NULL
      AND resume_lease_until <= clock_timestamp()
    ORDER BY timer_id FOR UPDATE
    """
    mempty
    (D.rowList (D.column (D.nonNullable D.uuid)))

recoverExpiredTimerResumesStmt :: Statement UUID Int
recoverExpiredTimerResumesStmt =
  preparable
    """
    UPDATE keiro.keiro_timers
    SET status = 'dead', resume_claim_token = NULL, resume_lease_until = NULL,
        updated_at = clock_timestamp()
    WHERE timer_id = $1 AND status = 'firing' AND resume_claim_token IS NOT NULL
      AND resume_lease_until <= clock_timestamp()
    """
    (E.param (E.nonNullable E.uuid))
    (fromIntegral <$> D.rowsAffected)

-- | Criteria selecting timers stranded in 'Firing'. A row is "stuck" when its
-- 'status' is @firing@ and it matches every set bound: 'minAge' (it has been
-- firing at least this long, measured from @updated_at@) and 'minAttempts' (it
-- has been claimed at least this many times). Both unset selects every @firing@
-- row.
data StuckTimerFilter = StuckTimerFilter
  { minAge :: !(Maybe NominalDiffTime),
    minAttempts :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

-- | Select every @firing@ row regardless of age or attempts.
anyStuckTimer :: StuckTimerFilter
anyStuckTimer = StuckTimerFilter Nothing Nothing

-- | Schedule a timer inside the caller's transaction (typically a process
-- manager's append). Upserts on 'timerId': a conflicting row is re-armed only
-- while it is still @Scheduled@, so a timer that has already fired or been
-- cancelled is not resurrected.
scheduleTimerTx :: TimerRequest -> Tx.Transaction ()
scheduleTimerTx request =
  Tx.statement
    ( timerIdToUuid (request ^. #timerId),
      request ^. #processManagerName,
      request ^. #correlationId,
      request ^. #fireAt,
      request ^. #payload,
      statusToText Scheduled
    )
    scheduleTimerStmt

-- | Schedule a timer only if no row with the same 'timerId' already exists.
--
-- This is for callers whose first arm must win, such as durable workflow sleeps:
-- every resume pass re-runs the sleep arm until the timer fires, and preserving
-- the original 'fireAt' keeps the sleep measured from the first arm. Process
-- managers that intentionally push a deadline back should keep using
-- 'scheduleTimerTx'. Returns 'True' when this call inserted the row and 'False'
-- when an existing timer won.
scheduleTimerOnceTx :: TimerRequest -> Tx.Transaction Bool
scheduleTimerOnceTx request =
  Tx.statement
    ( timerIdToUuid (request ^. #timerId),
      request ^. #processManagerName,
      request ^. #correlationId,
      request ^. #fireAt,
      request ^. #payload,
      statusToText Scheduled
    )
    scheduleTimerOnceStmt

-- | Atomically claim the single earliest timer due at @now@, moving it to
-- @Firing@ and bumping its attempt count. Uses @FOR UPDATE SKIP LOCKED@ so
-- concurrent workers each get a distinct timer. Returns 'Nothing' when none is
-- due.
claimDueTimer :: (Store :> es) => UTCTime -> Eff es (Maybe TimerRow)
claimDueTimer now =
  runTransaction $
    Tx.statement now claimDueTimerStmt

-- | Look up one timer by its stable identifier without claiming or mutating it.
--
-- Operational tooling uses this to render an exact preview before invoking one
-- of the guarded lifecycle transitions below.
lookupTimer :: (Store :> es) => TimerId -> Eff es (Maybe TimerRow)
lookupTimer timerId =
  runTransaction $
    Tx.statement (timerIdToUuid timerId) lookupTimerStmt

-- | Mark a claimed timer @Fired@, recording the id of the event its firing
-- produced. Returns 'False' when the row left @Firing@ while the fire action was
-- running (for example, it was requeued, cancelled, or dead-lettered).
markTimerFired :: (Store :> es) => TimerId -> EventId -> Eff es Bool
markTimerFired timerId eventId =
  runTransaction $
    Tx.statement (timerIdToUuid timerId, eventIdToUuid eventId) markTimerFiredStmt

-- | Count timers that are @scheduled@ and already due at @now@ — the timer
-- backlog. Read-only; mirrors 'claimDueTimer''s WHERE clause but counts rather
-- than locking, so it never claims or mutates a row.
countDueTimers :: (Store :> es) => UTCTime -> Eff es Int
countDueTimers now =
  runTransaction $
    Tx.statement now countDueTimersStmt

-- | Count timers stranded in @Firing@ that match the given 'StuckTimerFilter' —
-- the same "stuck" predicate 'findStuckTimers' lists, evaluated against @now@.
-- Read-only. 'anyStuckTimer' counts every @firing@ row.
countStuckTimers :: (Store :> es) => UTCTime -> StuckTimerFilter -> Eff es Int
countStuckTimers now stuckFilter =
  runTransaction $
    Tx.statement (cutoff, fmap fromIntegral (stuckFilter ^. #minAttempts)) countStuckTimersStmt
  where
    cutoff = fmap (\age -> addUTCTime (negate age) now) (stuckFilter ^. #minAge)

-- | List timers stranded in @Firing@ that match the given 'StuckTimerFilter'.
-- The @minAge@ bound is evaluated against @now@: a row qualifies when its
-- @updated_at@ is at least @minAge@ in the past (cutoff @now - minAge@). Results
-- are ordered oldest-first by @updated_at@.
findStuckTimers ::
  (Store :> es) => UTCTime -> StuckTimerFilter -> Eff es [TimerRow]
findStuckTimers now stuckFilter =
  runTransaction $
    Tx.statement (cutoff, fmap fromIntegral (stuckFilter ^. #minAttempts)) findStuckTimersStmt
  where
    cutoff = fmap (\age -> addUTCTime (negate age) now) (stuckFilter ^. #minAge)

-- | Move every timer stranded in @Firing@ for at least @olderThan@ back to
-- @Scheduled@. The statement preserves @fire_at@, so a due timer becomes
-- claimable on the same worker pass. Returns the number of rows requeued.
requeueStuckTimers :: (Store :> es) => NominalDiffTime -> UTCTime -> Eff es Int
requeueStuckTimers olderThan now =
  runTransaction $
    Tx.statement cutoff requeueStuckTimersStmt
  where
    cutoff = addUTCTime (negate olderThan) now

-- | Move a timer from @Firing@ back to @Scheduled@ so the ordinary claim loop
-- re-fires it. Leaves @fire_at@ unchanged, so a due timer becomes immediately
-- re-claimable. Idempotent: only @firing@ rows match, so re-running on an
-- already-requeued row affects nothing. Returns 'True' when a row changed.
requeueStuckTimer :: (Store :> es) => TimerId -> Eff es Bool
requeueStuckTimer timerId =
  runTransaction $
    Tx.statement (timerIdToUuid timerId) requeueStuckTimerStmt

-- | Move a timer from @Scheduled@ or @Firing@ to the terminal @Cancelled@
-- state so it never fires. Terminal rows (@fired@, @cancelled@, @dead@) are left
-- untouched. Idempotent. Returns 'True' when a row changed.
cancelTimer :: (Store :> es) => TimerId -> Eff es Bool
cancelTimer timerId =
  runTransaction $
    Tx.statement (timerIdToUuid timerId) cancelTimerStmt

-- | Move a timer from @Scheduled@ or @Firing@ to the terminal @Dead@ state,
-- recording @reason@ in @last_error@ so an operator can see why it was abandoned
-- through 'lookupTimerInspection' or 'findDeadTimers'. Terminal rows are left
-- untouched. Idempotent. Returns 'True' when a row changed.
deadLetterTimer :: (Store :> es) => TimerId -> Text -> Eff es Bool
deadLetterTimer timerId reason =
  runTransaction $
    Tx.statement (timerIdToUuid timerId, reason) deadLetterTimerStmt

scheduleTimerStmt :: Statement (UUID, Text, Text, UTCTime, Value, Text) ()
scheduleTimerStmt =
  preparable
    """
    INSERT INTO keiro.keiro_timers
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

scheduleTimerOnceStmt :: Statement (UUID, Text, Text, UTCTime, Value, Text) Bool
scheduleTimerOnceStmt =
  preparable
    """
    INSERT INTO keiro.keiro_timers
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
    ((> 0) <$> D.rowsAffected)

claimDueTimerStmt :: Statement UTCTime (Maybe TimerRow)
claimDueTimerStmt =
  preparable
    """
    WITH due AS (
      SELECT timer_id
      FROM keiro.keiro_timers
      WHERE status = 'scheduled'
        AND fire_at <= $1
      ORDER BY fire_at, timer_id
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    UPDATE keiro.keiro_timers kt
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

lookupTimerStmt :: Statement UUID (Maybe TimerRow)
lookupTimerStmt =
  preparable
    """
    SELECT timer_id, process_manager_name, correlation_id, fire_at,
      payload, status, attempts, fired_event_id
    FROM keiro.keiro_timers
    WHERE timer_id = $1
    """
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe timerRowDecoder)

lookupTimerInspectionStmt :: Statement UUID (Maybe TimerInspection)
lookupTimerInspectionStmt =
  preparable
    """
    SELECT timer_id, process_manager_name, correlation_id, fire_at,
      payload, status, attempts, fired_event_id, last_error
    FROM keiro.keiro_timers
    WHERE timer_id = $1
    """
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe timerInspectionDecoder)

findDeadTimersStmt :: Statement (Maybe Text, Int32, Maybe Text, Maybe UUID, Int64) [TimerInspection]
findDeadTimersStmt =
  preparable
    """
    SELECT timer_id, process_manager_name, correlation_id, fire_at,
      payload, status, attempts, fired_event_id, last_error
    FROM keiro.keiro_timers
    WHERE status = 'dead'
      AND ($1::text IS NULL OR process_manager_name COLLATE "C" = $1)
      AND (CASE $2::integer
        WHEN 0 THEN TRUE
        WHEN 1 THEN last_error IS NULL
        WHEN 2 THEN last_error COLLATE "C" = $3::text
        WHEN 3 THEN left(last_error, char_length($3::text)) COLLATE "C" = $3::text
        ELSE FALSE END)
      AND ($4::uuid IS NULL OR timer_id > $4)
    ORDER BY timer_id ASC
    LIMIT $5::bigint
    """
    ( contrazip5
        (E.param (E.nullable E.text))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.uuid))
        (E.param (E.nonNullable E.int8))
    )
    (D.rowList timerInspectionDecoder)

timerInspectionDecoder :: D.Row TimerInspection
timerInspectionDecoder =
  TimerInspection <$> timerRowDecoder <*> D.column (D.nullable D.text)

markTimerFiredStmt :: Statement (UUID, UUID) Bool
markTimerFiredStmt =
  preparable
    """
    UPDATE keiro.keiro_timers
    SET status = 'fired',
        fired_event_id = $2,
        updated_at = now()
    WHERE timer_id = $1
      AND status = 'firing'
      AND resume_claim_token IS NULL
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
    FROM keiro.keiro_timers
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
    FROM keiro.keiro_timers
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
    FROM keiro.keiro_timers
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
    UPDATE keiro.keiro_timers
    SET status = 'scheduled',
        updated_at = now()
    WHERE status = 'firing'
      AND resume_claim_token IS NULL
      AND updated_at <= $1
    """
    (E.param (E.nonNullable E.timestamptz))
    (fromIntegral <$> D.rowsAffected)

requeueStuckTimerStmt :: Statement UUID Bool
requeueStuckTimerStmt =
  preparable
    """
    UPDATE keiro.keiro_timers
    SET status = 'scheduled',
        updated_at = now()
    WHERE timer_id = $1
      AND status = 'firing'
      AND resume_claim_token IS NULL
    """
    (E.param (E.nonNullable E.uuid))
    ((> 0) <$> D.rowsAffected)

cancelTimerStmt :: Statement UUID Bool
cancelTimerStmt =
  preparable
    """
    UPDATE keiro.keiro_timers
    SET status = 'cancelled',
        updated_at = now()
    WHERE timer_id = $1
      AND status IN ('scheduled', 'firing')
      AND resume_claim_token IS NULL
    """
    (E.param (E.nonNullable E.uuid))
    ((> 0) <$> D.rowsAffected)

deadLetterTimerStmt :: Statement (UUID, Text) Bool
deadLetterTimerStmt =
  preparable
    """
    UPDATE keiro.keiro_timers
    SET status = 'dead',
        last_error = $2,
        updated_at = now()
    WHERE timer_id = $1
      AND status IN ('scheduled', 'firing')
      AND resume_claim_token IS NULL
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
