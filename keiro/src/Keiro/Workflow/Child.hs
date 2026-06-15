{- | Child workflows: spawn, wait on, and cancel a workflow from inside another.

== What this gives you

Fan-out\/fan-in composition of durable workflows. A /parent/ workflow spawns a
/child/ (a second workflow with its own journal stream), waits for the child's
result, and may cancel a child it no longer needs — with the whole relationship
surviving a crash, because the spawn is recorded in the parent's journal and the
link is stored in @keiro_workflow_children@.

@
parent :: ('Workflow' ':>' es, 'Store' ':>' es) => Eff es Text
parent = do
  h      <- 'spawnChild' (WorkflowName \"ship-order\") (WorkflowId \"ord-7\") shipWorkflow
  result <- 'awaitChild' h                  -- SUSPEND until the child completes
  _      <- 'Keiro.Workflow.step' (StepName \"notify\") (pure (\"shipped: \" <> result))
  pure result
@

== How it works (contract recap for downstream plans)

* __'spawnChild' is a journaled step.__ It records a @StepRecorded
  \"child:\<childId\>\"@ in the /parent/ journal (so a replay short-circuits the
  spawn and never re-spawns) and inserts a @running@ row in
  @keiro_workflow_children@ linking the child back to the parent plus the
  parent-journal step the parent awaits (@child:\<childId\>:result@). It does
  __not__ run the child inline — the EP-42 resume worker drives the child to
  completion from the application's @WorkflowRegistry@, so __a child's
  'WorkflowName' must be registered there__, exactly like any resumable
  workflow. (The @childDef@ argument is taken for authoring ergonomics; the
  registry, keyed by 'WorkflowName', is the source of truth for the child's
  body.)
* __'awaitChild' reuses EP-38's suspension primitive__ — it is
  @'awaitStep' (StepName \"child:\<childId\>:result\") arm@. On the miss path it
  re-asserts nothing new (the spawn already registered the link) but throws
  'WorkflowChildCancelled' if the child was cancelled meanwhile; on the hit path
  it decodes the child's result, which 'childCompletionHook' propagated into the
  parent journal when the child finished.
* __'runChildWorkflow'__ is what the resume worker selects (instead of bare
  'Keiro.Workflow.runWorkflowWith') for any workflow that is some parent's child:
  on 'Completed' it runs 'childCompletionHook', which flips the child row to
  @completed@ and appends the @child:\<childId\>:result@ 'StepRecorded' to the
  parent's journal.
* __'cancelChild'__ flips the child row to @cancelled@ and writes a
  'Keiro.Workflow.WorkflowCancelled' marker to the /child/ journal (so the
  child's next resume short-circuits and stops) plus a @{"cancelled": true}@
  sentinel as the parent's await-step result (so a suspended parent's
  'awaitChild' throws 'WorkflowChildCancelled' rather than blocking forever).
* @'Keiro.Workflow.Child.Schema.countActiveChildren'@ backs a potential
  @keiro.workflow.children.active@ gauge for EP-44.
-}
module Keiro.Workflow.Child (
    -- * Child handles and reserved step names
    ChildHandle (..),
    childSpawnStepName,
    childResultStepName,

    -- * Authoring surface (inside a parent workflow)
    spawnChild,
    awaitChild,

    -- * External control
    cancelChild,

    -- * Driving a child to completion (used by the resume worker)
    runChildWorkflow,
    childCompletionHook,

    -- * Errors
    WorkflowChildCancelled (..),
)
where

import Control.Exception (Exception)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Keiro.Prelude
import Keiro.Workflow (
    JournalAppendOutcome (..),
    StepName (..),
    Workflow,
    WorkflowError (..),
    WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowName (..),
    WorkflowOutcome (..),
    WorkflowRunOptions,
    appendJournalEntry,
    awaitStep,
    childStepPrefix,
    currentGeneration,
    currentWorkflow,
    prepareJournalAppend,
    runWorkflowWith,
    step,
 )
import Keiro.Workflow.Child.Schema (
    ChildStatus (..),
    lookupChild,
    markChildCancelledTx,
    markChildResultTx,
    registerChildTx,
 )
import Keiro.Workflow.Instance (WorkflowStatus (..), upsertInstanceTx)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- ---------------------------------------------------------------------------
-- Handles and reserved step names
-- ---------------------------------------------------------------------------

{- | An in-memory handle to a spawned child, returned by 'spawnChild' and taken
by 'awaitChild' \/ 'cancelChild'. The phantom type parameter @a@ records the
child's result type so 'awaitChild' decodes without an extra annotation; the
handle itself carries only the child's name and id (the child journal is
@wf:\<childName\>-\<childWfId\>@).
-}
data ChildHandle a = ChildHandle
    { childName :: !WorkflowName
    , childWfId :: !WorkflowId
    }
    deriving stock (Eq, Show)

{- | The reserved /spawn/ step name a child is recorded under in its parent's
journal: @child:\<childId\>@ (uses EP-38's 'childStepPrefix').
-}
childSpawnStepName :: WorkflowId -> Text
childSpawnStepName (WorkflowId wid) = childStepPrefix <> wid

{- | The reserved /result/ step name the parent awaits and the child's
completion is propagated under: @child:\<childId\>:result@.
-}
childResultStepName :: WorkflowId -> Text
childResultStepName (WorkflowId wid) = childStepPrefix <> wid <> ":result"

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

{- | Thrown out of 'awaitChild' when the awaited child was 'cancelChild'led. A
cancelled child never produces a result, so suspending forever would be wrong
and fabricating a result would be wrong; the parent author can @catch@ this to
run compensation, and EP-42's resume worker treats it as a parent failure.
Mirrors EP-40's 'Keiro.Workflow.Awakeable.WorkflowAwakeableCancelled'.
-}
data WorkflowChildCancelled = WorkflowChildCancelled WorkflowName WorkflowId
    deriving stock (Eq, Show)

instance Exception WorkflowChildCancelled

-- ---------------------------------------------------------------------------
-- Authoring surface
-- ---------------------------------------------------------------------------

{- | Spawn a child workflow. Records a @StepRecorded \"child:\<childId\>\"@ in
the /parent/ journal (so a replay short-circuits and never re-spawns) and
inserts an idempotent @running@ link row, then returns a 'ChildHandle'. The
child is driven to completion by the resume worker from the registry, so
@childNm@ __must be registered there__; @childDef@ is accepted for authoring
ergonomics but is not run here.
-}
spawnChild ::
    (Workflow :> es, Store :> es) =>
    -- | The child's name (must be in the resume worker's registry).
    WorkflowName ->
    -- | The child's id (names the child journal).
    WorkflowId ->
    -- | The child workflow definition (for authoring; the registry actually runs it).
    Eff (Workflow : es) a ->
    Eff es (ChildHandle a)
spawnChild childNm childWid _childDef = do
    (parentNm, parentWid) <- currentWorkflow
    let spawnStep = StepName (childSpawnStepName childWid)
        resultStep = childResultStepName childWid
    -- Journaled as a step in the PARENT journal: a parent replay short-circuits
    -- this body, and the ON CONFLICT DO NOTHING register collapses on re-run.
    _ <-
        step spawnStep $ do
            runTransaction $
                registerChildTx
                    (unWorkflowId childWid)
                    (unWorkflowName childNm)
                    (unWorkflowId parentWid)
                    (unWorkflowName parentNm)
                    resultStep
                    *> upsertInstanceTx
                        (unWorkflowId childWid)
                        (unWorkflowName childNm)
                        0
                        WfRunning
                        Nothing
            pure ()
    pure (ChildHandle childNm childWid)

{- | Suspend the parent until the child completes, then return the child's
result. This is EP-38's 'awaitStep' on the @child:\<childId\>:result@ step:
'childCompletionHook' journals that step into the parent when the child
finishes, so the next parent run replays past the wait and decodes the result.

If the child was cancelled, throws 'WorkflowChildCancelled' — detected both on
the suspend path (the arm checks the child row's status) and on the hit path
(a cancelled child's result entry is a @{"cancelled": true}@ sentinel).
-}
awaitChild ::
    (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
    ChildHandle a ->
    Eff es a
awaitChild (ChildHandle childNm childWid) = do
    let resultStep = StepName (childResultStepName childWid)
        arm = do
            mrow <- lookupChild (unWorkflowId childWid) (unWorkflowName childNm)
            case mrow of
                Just row
                    | (row ^. #status) == ChildCancelled ->
                        throwIO (WorkflowChildCancelled childNm childWid)
                    | (row ^. #status) == ChildCompleted
                    , Just resultValue <- row ^. #result ->
                        appendJournalEntry
                            (WorkflowName (row ^. #parentName))
                            (WorkflowId (row ^. #parentId))
                            StepRecorded
                                { stepName = row ^. #awaitStep
                                , result = resultValue
                                , recordedAt = fromMaybe (row ^. #updatedAt) (row ^. #completedAt)
                                }
                -- The spawn already registered the link; nothing more to (re-)arm.
                _ -> pure ()
    raw <- awaitStep resultStep arm
    if isCancelledSentinel raw
        then throwIO (WorkflowChildCancelled childNm childWid)
        else case Aeson.fromJSON raw of
            Aeson.Success a -> pure a
            Aeson.Error e ->
                error ("awaitChild: cannot decode child result for " <> show childWid <> ": " <> e)

-- ---------------------------------------------------------------------------
-- External control
-- ---------------------------------------------------------------------------

{- | Cancel a child. Flips its @keiro_workflow_children@ row from @running@ to
@cancelled@ (a no-op for an already-resolved child, returning 'False'), and on a
successful transition: (1) writes a 'WorkflowCancelled' marker to the /child/
journal so the child's next resume short-circuits via EP-38's handler, and (2)
writes a @{"cancelled": true}@ sentinel as the parent's await-step result so a
suspended parent's 'awaitChild' throws 'WorkflowChildCancelled'. Both appends
use deterministic ids (idempotent), so a retried cancel is safe.
-}
cancelChild ::
    (IOE :> es, Store :> es) =>
    ChildHandle a ->
    Eff es Bool
cancelChild (ChildHandle childNm childWid) = do
    cancelled <-
        runTransaction $
            markChildCancelledTx (unWorkflowId childWid) (unWorkflowName childNm)
    when cancelled $ do
        now <- liftIO getCurrentTime
        -- 1) durable cancellation marker in the CHILD journal:
        appendJournalEntry childNm childWid (WorkflowCancelled{recordedAt = now})
        -- 2) wake the parent's awaitChild with a cancellation sentinel result:
        mrow <- lookupChild (unWorkflowId childWid) (unWorkflowName childNm)
        for_ mrow $ \row ->
            appendJournalEntry
                (WorkflowName (row ^. #parentName))
                (WorkflowId (row ^. #parentId))
                StepRecorded
                    { stepName = row ^. #awaitStep
                    , result = cancelledSentinel
                    , recordedAt = now
                    }
    pure cancelled

-- ---------------------------------------------------------------------------
-- Completion propagation
-- ---------------------------------------------------------------------------

{- | Drive a child workflow to completion, propagating its result to the parent.
This is 'runWorkflowWith' followed by 'childCompletionHook' on 'Completed': the
resume worker selects this (instead of bare 'runWorkflowWith') for any workflow
that is some parent's child, so a finished child wakes its waiting parent. A
'Suspended' or 'Cancelled' child propagates nothing (it has no result yet).
-}
runChildWorkflow ::
    (IOE :> es, Store :> es, ToJSON a) =>
    WorkflowRunOptions ->
    WorkflowName ->
    WorkflowId ->
    Eff (Workflow : es) a ->
    Eff es (WorkflowOutcome a)
runChildWorkflow opts childNm childWid action = do
    outcome <- runWorkflowWith opts childNm childWid action
    case outcome of
        Completed result -> do
            childCompletionHook childNm childWid (toJSON result)
            pure (Completed result)
        other -> pure other

{- | Propagate a finished child's result to its parent: flip the child row to
@completed@ (storing the result) and append the @child:\<childId\>:result@
'StepRecorded' to the /parent/ journal — exactly the wake source the parent's
'awaitChild' resolves on. Idempotent and crash-safe: it always looks the parent
link up and (re-)appends, treating a duplicate append as success, so a crash
between the child completing and the parent being notified self-heals on the
next drive. Normally invoked via 'runChildWorkflow'.
-}
childCompletionHook ::
    (IOE :> es, Store :> es) =>
    WorkflowName ->
    WorkflowId ->
    Aeson.Value ->
    Eff es ()
childCompletionHook childNm childWid resultValue = do
    mrow <- lookupChild (unWorkflowId childWid) (unWorkflowName childNm)
    for_ mrow $ \row -> case row ^. #status of
        Running -> do
            now <- liftIO getCurrentTime
            let parentName = WorkflowName (row ^. #parentName)
                parentId = WorkflowId (row ^. #parentId)
            gen <- currentGeneration parentName parentId
            appendTx <-
                prepareJournalAppend
                    parentName
                    parentId
                    gen
                    StepRecorded
                        { stepName = row ^. #awaitStep
                        , result = resultValue
                        , recordedAt = now
                        }
            appendOutcome <-
                runTransaction $ do
                    transitioned <- markChildResultTx (unWorkflowId childWid) (unWorkflowName childNm) resultValue now
                    if transitioned
                        then do
                            appendOutcome <- appendTx
                            condemnOnAppendConflict appendOutcome
                            pure appendOutcome
                        else pure (JournalAlreadyPresent resultValue)
            throwOnAppendConflict appendOutcome
        ChildCompleted ->
            for_ (row ^. #result) $ \stored ->
                appendJournalEntry
                    (WorkflowName (row ^. #parentName))
                    (WorkflowId (row ^. #parentId))
                    StepRecorded
                        { stepName = row ^. #awaitStep
                        , result = stored
                        , recordedAt = fromMaybe (row ^. #updatedAt) (row ^. #completedAt)
                        }
        ChildCancelled -> pure ()
        ChildFailed -> pure ()

condemnOnAppendConflict :: JournalAppendOutcome -> Tx.Transaction ()
condemnOnAppendConflict = \case
    JournalAppendConflict{} -> Tx.condemn
    _ -> pure ()

throwOnAppendConflict :: JournalAppendOutcome -> Eff es ()
throwOnAppendConflict = \case
    JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))
    _ -> pure ()

-- ---------------------------------------------------------------------------
-- The cancellation sentinel
-- ---------------------------------------------------------------------------

{- | The @{"cancelled": true}@ value 'cancelChild' writes as a cancelled child's
await-step result so 'awaitChild' can detect it and throw.
-}
cancelledSentinel :: Aeson.Value
cancelledSentinel = Aeson.object ["cancelled" Aeson..= True]

-- | Whether a journaled await-step result is the cancellation sentinel.
isCancelledSentinel :: Aeson.Value -> Bool
isCancelledSentinel v = v == cancelledSentinel
