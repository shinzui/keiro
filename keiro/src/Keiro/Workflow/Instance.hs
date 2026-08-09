-- | Durable workflow instance summaries.
--
-- The journal stream and @keiro_workflow_steps@ index remain the source of truth
-- for replay. This module maintains one @keiro_workflows@ row per logical
-- workflow instance so the resume worker can track lifecycle, attempts, and
-- leases without scanning journal history.
module Keiro.Workflow.Instance
  ( WorkflowStatus (..),
    WorkflowInstanceRow (..),
    WorkflowInstanceFilter (..),
    defaultWorkflowInstanceFilter,
    ResurrectOutcome (..),
    CancelWorkflowOutcome (..),
    statusToText,
    statusFromText,
    upsertInstanceTx,
    markInstanceSuspendedAwaiting,
    lookupInstance,
    listWorkflowInstances,
    cancelWorkflow,
    claimInstance,
    renewInstanceLeaseTx,
    renewInstanceLease,
    releaseInstance,
    forceReleaseInstanceLease,
    recordCrashTx,
    resetInstanceAttempts,
    reviveFailedInstanceTx,
    resurrectFailedWorkflow,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Data.Int (Int32)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Workflow.Child.Cancel (ensureChildCancelled)
import Keiro.Workflow.Child.Schema
  ( ChildStatus (..),
    lookupChild,
    reviveFailedChildTx,
  )
import Keiro.Workflow.Instance.Schema
  ( WorkflowStatus (..),
    statusFromText,
    statusToText,
    upsertInstanceTx,
  )
import Keiro.Workflow.Journal
  ( JournalAppendOutcome (..),
    prepareJournalAppend,
  )
import Keiro.Workflow.Schema
  ( currentGeneration,
    deleteStepRowTx,
    loadStepIndex,
    lockWorkflowStepTx,
    lookupStepResultTx,
    workflowStepLockKey,
  )
import Keiro.Workflow.Types
  ( WorkflowError (..),
    WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowName (..),
    cancelledStepName,
    completedStepName,
    continuedAsNewStepName,
    failedStepName,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

data WorkflowInstanceRow = WorkflowInstanceRow
  { workflowId :: !Text,
    workflowName :: !Text,
    generation :: !Int32,
    status :: !WorkflowStatus,
    attempts :: !Int32,
    lastError :: !(Maybe Text),
    nextAttemptAt :: !(Maybe UTCTime),
    wakeAfter :: !(Maybe UTCTime),
    leasedBy :: !(Maybe Text),
    leaseExpiresAt :: !(Maybe UTCTime),
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime,
    completedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)

-- | Filters and keyset cursor for operator-facing workflow enumeration.
--
-- Results are ordered by @(workflow_name, workflow_id)@. Pass the final row's
-- name and id as 'afterKey' to fetch the next page without the instability and
-- growing scan cost of an @OFFSET@ query. A non-positive 'pageSize' returns an
-- empty page.
data WorkflowInstanceFilter = WorkflowInstanceFilter
  { statuses :: !(Maybe (NonEmpty WorkflowStatus)),
    workflowName :: !(Maybe Text),
    afterKey :: !(Maybe (Text, Text)),
    pageSize :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | List every status and workflow name, starting at the first key, 100 rows
-- at a time.
defaultWorkflowInstanceFilter :: WorkflowInstanceFilter
defaultWorkflowInstanceFilter =
  WorkflowInstanceFilter
    { statuses = Nothing,
      workflowName = Nothing,
      afterKey = Nothing,
      pageSize = 100
    }

data ResurrectOutcome
  = WorkflowResurrected
  | WorkflowNotFailed
  | WorkflowNotFound
  deriving stock (Generic, Eq, Show)

-- | Honest result of an operator cancellation request.
data CancelWorkflowOutcome
  = WorkflowCancelRecorded
  | WorkflowAlreadyTerminal !WorkflowStatus
  | WorkflowCancelUnknown
  deriving stock (Generic, Eq, Show)

-- | Record that a run parked on @awaitedStep@, arbitrating against a wake
-- delivery that may be landing at the same moment.
--
-- Discovery is exact: a @suspended@ instance with no due wake hint is never
-- returned, so a suspended status written /after/ a wake has already been
-- delivered would strand the workflow forever. The window is real — a run
-- consults the step index, finds the awaited step absent, runs its arm, and only
-- then writes its status, and a wake can commit anywhere in between.
--
-- The fix reuses the lock the append path already takes. Every wake delivery
-- goes through @prepareJournalAppend@, which holds the per-step advisory lock
-- ('lockWorkflowStepTx' on 'workflowStepLockKey') while it appends and upserts
-- the instance row. Taking the same lock here totally orders the two writers:
--
-- * suspend wins the lock — it writes @suspended@; the wake, queued behind it,
--   then writes @running@;
-- * wake wins the lock — this transaction sees the committed step-index row and
--   writes @running@ itself.
--
-- Either way no resolved wake is left behind a @suspended@ status. The
-- re-check reads the same authoritative @keiro_workflow_steps@ index the
-- @Await@ miss path consults, which is written in the same transaction as every
-- journal append. This also covers the self-repair arms (an awakeable or child
-- whose arm appends the awaited result itself and then suspends): they observe
-- their own append and end @running@.
markInstanceSuspendedAwaiting ::
  (Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  -- | The generation the run operated on.
  Int ->
  -- | The step name the run parked on.
  Text ->
  Eff es ()
markInstanceSuspendedAwaiting (WorkflowName nameText) (WorkflowId widText) gen awaitedStep =
  runTransaction $ do
    lockWorkflowStepTx (workflowStepLockKey widText nameText gen awaitedStep)
    resolved <- lookupStepResultTx widText nameText gen awaitedStep
    let status = maybe WfSuspended (const WfRunning) resolved
    upsertInstanceTx widText nameText (fromIntegral gen) status Nothing

lookupInstance :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es (Maybe WorkflowInstanceRow)
lookupInstance (WorkflowName name) (WorkflowId wid) =
  runTransaction (Tx.statement (wid, name) lookupInstanceStmt)

-- | Enumerate workflow instance summaries using stable keyset pagination.
--
-- Status and name filters are exact. Rows inserted before the supplied cursor
-- are intentionally not revisited; rows deleted or updated concurrently never
-- cause later keys to be skipped as an @OFFSET@ query could.
listWorkflowInstances ::
  (Store :> es) =>
  WorkflowInstanceFilter ->
  Eff es [WorkflowInstanceRow]
listWorkflowInstances filters
  | filters ^. #pageSize <= 0 = pure []
  | otherwise =
      runTransaction $
        Tx.statement
          ( NonEmpty.toList . fmap statusToText <$> filters ^. #statuses,
            filters ^. #workflowName,
            fst <$> filters ^. #afterKey,
            snd <$> filters ^. #afterKey,
            fromIntegral
              ( min
                  (filters ^. #pageSize)
                  (fromIntegral (maxBound :: Int32))
              ) ::
              Int32
          )
          listWorkflowInstancesStmt

-- | Stop a top-level or linked-child workflow at its next durable boundary.
--
-- Cancellation is an append-only journal marker. Linked children delegate to
-- the same transaction as 'Keiro.Workflow.Child.cancelChild' so their parent is
-- woken with the typed cancellation sentinel. Children are not cascaded: an
-- operator must cancel descendants explicitly. A step action already in flight
-- may finish and journal idempotently; no later boundary may start.
cancelWorkflow ::
  (IOE :> es, Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  Eff es CancelWorkflowOutcome
cancelWorkflow name@(WorkflowName nameText) wid@(WorkflowId widText) =
  lookupInstance name wid >>= \case
    Just row
      | Just terminal <- terminalStatus (row ^. #status) ->
          pure (WorkflowAlreadyTerminal terminal)
    mrow -> do
      exists <- case mrow of
        Just _ -> pure True
        Nothing -> do
          gen <- currentGeneration name wid
          not . Map.null <$> loadStepIndex name wid gen
      if not exists
        then pure WorkflowCancelUnknown
        else
          lookupChild widText nameText >>= \case
            Just child -> cancelLinkedChild child
            Nothing -> cancelTopLevel
  where
    terminalStatus = \case
      WfCompleted -> Just WfCompleted
      WfCancelled -> Just WfCancelled
      WfFailed -> Just WfFailed
      _ -> Nothing

    cancelLinkedChild child = do
      (transitioned, childOutcome, parentOutcome) <- ensureChildCancelled child
      traverse_ throwOnJournalConflict [childOutcome, parentOutcome]
      if transitioned
        then pure WorkflowCancelRecorded
        else case child ^. #status of
          ChildCancelled -> pure (WorkflowAlreadyTerminal WfCancelled)
          ChildCompleted -> pure (WorkflowAlreadyTerminal WfCompleted)
          ChildFailed -> pure (WorkflowAlreadyTerminal WfFailed)
          -- The guarded child-row transition lost a race. Re-read both the
          -- instance and child rows before deciding which terminal state won.
          Running -> cancelWorkflow name wid

    cancelTopLevel = do
      gen <- currentGeneration name wid
      now <- liftIO getCurrentTime
      appendTx <-
        prepareJournalAppend
          name
          wid
          gen
          WorkflowCancelled {recordedAt = now}
      runTransaction appendTx >>= \case
        JournalAppended {} -> pure WorkflowCancelRecorded
        JournalAlreadyPresent {} ->
          pure (WorkflowAlreadyTerminal WfCancelled)
        JournalRefusedTerminal marker
          | marker == continuedAsNewStepName -> cancelWorkflow name wid
          | marker == completedStepName -> pure (WorkflowAlreadyTerminal WfCompleted)
          | marker == failedStepName -> pure (WorkflowAlreadyTerminal WfFailed)
          | marker == cancelledStepName -> pure (WorkflowAlreadyTerminal WfCancelled)
          | otherwise -> cancelWorkflow name wid
        conflict@JournalAppendConflict {} ->
          throwOnJournalConflict conflict *> pure WorkflowCancelUnknown

    throwOnJournalConflict = \case
      JournalAppendConflict err ->
        throwIO (WorkflowJournalAppendError (Text.pack (show err)))
      _ -> pure ()

claimInstance :: (IOE :> es, Store :> es) => Text -> NominalDiffTime -> WorkflowName -> WorkflowId -> Eff es Bool
claimInstance owner ttl (WorkflowName nameText) (WorkflowId widText) = do
  now <- liftIO getCurrentTime
  runTransaction $ do
    -- Generation 0, not the resolved current generation: 'ensureInstanceStmt' is
    -- an ON CONFLICT DO NOTHING insert, so the value is used only when no row
    -- exists at all — and every discovered workflow has one (migration 0011
    -- backfilled the pre-existing instances, every append upserts, and spawnChild
    -- writes the child's row inside the spawn step's transaction). Where the
    -- insert does fire, 0 is a floor that the next truthful writer raises:
    -- 'upsertInstanceTx' takes GREATEST(stored, supplied) on conflict. Resolving
    -- MAX(generation) here would cost a query per claim to learn a number the
    -- insert almost never uses.
    Tx.statement (widText, nameText, 0 :: Int32) ensureInstanceStmt
    fromMaybe False
      <$> Tx.statement
        (widText, nameText, owner, now, addUTCTime ttl now)
        claimInstanceStmt

-- | Extend an instance lease only when @owner@ still holds it.
--
-- The caller supplies one clock reading so @updated_at@ and the new expiry share
-- the same boundary. Returns 'False' after ownership is lost or the row vanishes.
renewInstanceLeaseTx ::
  Text ->
  NominalDiffTime ->
  UTCTime ->
  Text ->
  Text ->
  Tx.Transaction Bool
renewInstanceLeaseTx owner ttl now wid name =
  Tx.statement
    (wid, name, owner, now, addUTCTime ttl now)
    renewInstanceLeaseStmt

-- | Effect-level wrapper around 'renewInstanceLeaseTx' using the current time.
renewInstanceLease ::
  (IOE :> es, Store :> es) =>
  Text ->
  NominalDiffTime ->
  WorkflowName ->
  WorkflowId ->
  Eff es Bool
renewInstanceLease owner ttl (WorkflowName name) (WorkflowId wid) = do
  now <- liftIO getCurrentTime
  runTransaction (renewInstanceLeaseTx owner ttl now wid name)

releaseInstance :: (Store :> es) => Text -> Bool -> WorkflowName -> WorkflowId -> Eff es ()
releaseInstance owner progressed (WorkflowName name) (WorkflowId wid) =
  runTransaction $
    Tx.statement (wid, name, owner, progressed) releaseInstanceStmt

-- | Clear any current instance lease, returning 'True' only when a lease was
-- present.
--
-- A previous live owner is not interrupted inside an action already in flight.
-- Its next owner-guarded 'renewInstanceLease' matches no row and raises
-- 'Keiro.Workflow.WorkflowLeaseLost' before a later workflow boundary, while a
-- replacement owner can claim immediately instead of waiting for the old TTL.
forceReleaseInstanceLease ::
  (Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  Eff es Bool
forceReleaseInstanceLease (WorkflowName name) (WorkflowId wid) =
  runTransaction (Tx.statement (wid, name) forceReleaseInstanceLeaseStmt)

-- | Record a crashed advance against the instance row: bump @attempts@, store
-- the rendered error, and push @next_attempt_at@ out along the backoff ladder.
-- Returns the new attempt count, or 'Nothing' when the row matched nothing
-- because the workflow reached a terminal status between the crash and this
-- update (a parent's @cancelChild@, an operator cancellation, a concurrent
-- failure marker). That race is ordinary, not exceptional: there is no live
-- instance left to pace, so nothing is recorded and the caller skips it.
recordCrashTx :: Text -> Text -> Text -> Tx.Transaction (Maybe Int32)
recordCrashTx wid name err =
  Tx.statement (wid, name, err) recordCrashStmt

resetInstanceAttempts :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es ()
resetInstanceAttempts (WorkflowName name) (WorkflowId wid) =
  runTransaction (Tx.statement (wid, name) resetInstanceAttemptsStmt)

reviveFailedInstanceTx :: Text -> Text -> Tx.Transaction Bool
reviveFailedInstanceTx wid name =
  Tx.statement (wid, name) reviveFailedInstanceStmt

-- | Return a terminally failed workflow to the runnable pool.
--
-- The operation removes only the current generation's derived failed-marker index
-- row; the append-only 'Keiro.Workflow.WorkflowFailed' journal event remains as
-- history. A failed child link is revived in the same transaction. Parent failure
-- sentinels already delivered to another journal are not retracted.
resurrectFailedWorkflow ::
  (Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  Eff es ResurrectOutcome
resurrectFailedWorkflow name@(WorkflowName nameText) wid@(WorkflowId widText) =
  lookupInstance name wid >>= \case
    Nothing -> pure WorkflowNotFound
    Just row
      | row ^. #status /= WfFailed -> pure WorkflowNotFailed
      | otherwise -> do
          gen <- currentGeneration name wid
          revived <-
            runTransaction $ do
              instanceRevived <- reviveFailedInstanceTx widText nameText
              when instanceRevived $ do
                deleteStepRowTx widText nameText gen failedStepName
                void (reviveFailedChildTx widText nameText)
              pure instanceRevived
          pure $
            if revived
              then WorkflowResurrected
              else WorkflowNotFailed

lookupInstanceStmt :: Statement (Text, Text) (Maybe WorkflowInstanceRow)
lookupInstanceStmt =
  preparable
    """
    SELECT workflow_id, workflow_name, generation, status, attempts,
           last_error, next_attempt_at, wake_after, leased_by, lease_expires_at,
           created_at, updated_at, completed_at
    FROM keiro.keiro_workflows
    WHERE workflow_id = $1 AND workflow_name = $2
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.rowMaybe instanceRowDecoder)

listWorkflowInstancesStmt :: Statement (Maybe [Text], Maybe Text, Maybe Text, Maybe Text, Int32) [WorkflowInstanceRow]
listWorkflowInstancesStmt =
  preparable
    """
    SELECT workflow_id, workflow_name, generation, status, attempts,
           last_error, next_attempt_at, wake_after, leased_by, lease_expires_at,
           created_at, updated_at, completed_at
    FROM keiro.keiro_workflows
    WHERE ($1::text[] IS NULL OR status = ANY($1))
      AND ($2::text IS NULL OR workflow_name = $2)
      AND (
        $3::text IS NULL
        OR (workflow_name, workflow_id) > ($3, $4)
      )
    ORDER BY workflow_name, workflow_id
    LIMIT $5
    """
    ( contrazip5
        (E.param (E.nullable (E.foldableArray (E.nonNullable E.text))))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    (D.rowList instanceRowDecoder)

ensureInstanceStmt :: Statement (Text, Text, Int32) ()
ensureInstanceStmt =
  preparable
    """
    INSERT INTO keiro.keiro_workflows
      (workflow_id, workflow_name, generation, status)
    VALUES ($1, $2, $3, 'running')
    ON CONFLICT (workflow_id, workflow_name) DO NOTHING
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    D.noResult

claimInstanceStmt :: Statement (Text, Text, Text, UTCTime, UTCTime) (Maybe Bool)
claimInstanceStmt =
  preparable
    """
    UPDATE keiro.keiro_workflows
    SET leased_by = $3,
        lease_expires_at = $5,
        updated_at = $4
    WHERE workflow_id = $1
      AND workflow_name = $2
      AND status IN ('running', 'suspended')
      AND (lease_expires_at IS NULL OR lease_expires_at < $4)
      AND (next_attempt_at IS NULL OR next_attempt_at <= $4)
    RETURNING TRUE
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.timestamptz))
    )
    (D.rowMaybe (D.column (D.nonNullable D.bool)))

renewInstanceLeaseStmt :: Statement (Text, Text, Text, UTCTime, UTCTime) Bool
renewInstanceLeaseStmt =
  preparable
    """
    UPDATE keiro.keiro_workflows
    SET lease_expires_at = $5,
        updated_at = $4
    WHERE workflow_id = $1
      AND workflow_name = $2
      AND leased_by = $3
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.timestamptz))
    )
    ((> 0) <$> D.rowsAffected)

releaseInstanceStmt :: Statement (Text, Text, Text, Bool) ()
releaseInstanceStmt =
  preparable
    """
    UPDATE keiro.keiro_workflows
    SET leased_by = NULL,
        lease_expires_at = NULL,
        attempts = CASE WHEN $4 THEN 0 ELSE attempts END,
        last_error = CASE WHEN $4 THEN NULL ELSE last_error END,
        next_attempt_at = CASE WHEN $4 THEN NULL ELSE next_attempt_at END,
        updated_at = now()
    WHERE workflow_id = $1
      AND workflow_name = $2
      AND leased_by = $3
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.bool))
    )
    D.noResult

forceReleaseInstanceLeaseStmt :: Statement (Text, Text) Bool
forceReleaseInstanceLeaseStmt =
  preparable
    """
    UPDATE keiro.keiro_workflows
    SET leased_by = NULL,
        lease_expires_at = NULL,
        updated_at = now()
    WHERE workflow_id = $1
      AND workflow_name = $2
      AND leased_by IS NOT NULL
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    ((> 0) <$> D.rowsAffected)

recordCrashStmt :: Statement (Text, Text, Text) (Maybe Int32)
recordCrashStmt =
  preparable
    """
    UPDATE keiro.keiro_workflows
    SET attempts = attempts + 1,
        last_error = $3,
        next_attempt_at = now() + (LEAST(power(2, attempts + 1), 64) * interval '1 second'),
        updated_at = now()
    WHERE workflow_id = $1
      AND workflow_name = $2
      AND status NOT IN ('completed', 'cancelled', 'failed')
    RETURNING attempts
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    -- 'rowMaybe', not 'singleRow': the WHERE clause deliberately matches
    -- nothing once the workflow is terminal, and a workflow can go terminal
    -- between its crash and this update.
    (D.rowMaybe (D.column (D.nonNullable D.int4)))

resetInstanceAttemptsStmt :: Statement (Text, Text) ()
resetInstanceAttemptsStmt =
  preparable
    """
    UPDATE keiro.keiro_workflows
    SET attempts = 0,
        last_error = NULL,
        next_attempt_at = NULL,
        updated_at = now()
    WHERE workflow_id = $1
      AND workflow_name = $2
      AND status NOT IN ('completed', 'cancelled', 'failed')
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

reviveFailedInstanceStmt :: Statement (Text, Text) Bool
reviveFailedInstanceStmt =
  preparable
    """
    UPDATE keiro.keiro_workflows
    SET status = 'running',
        attempts = 0,
        last_error = NULL,
        next_attempt_at = NULL,
        leased_by = NULL,
        lease_expires_at = NULL,
        completed_at = NULL,
        updated_at = now()
    WHERE workflow_id = $1
      AND workflow_name = $2
      AND status = 'failed'
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    ((> 0) <$> D.rowsAffected)

instanceRowDecoder :: D.Row WorkflowInstanceRow
instanceRowDecoder =
  WorkflowInstanceRow
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.int4)
    <*> (statusFromText <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.int4)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
