{- | Child workflows: spawn, wait on, and cancel a workflow from inside another.

== What this gives you

Fan-out\/fan-in composition of durable workflows. A /parent/ workflow spawns a
/child/ (a second workflow with its own journal stream), waits for the child's
result, and may cancel a child it no longer needs — with the whole relationship
surviving a crash, because the spawn is recorded in the parent's journal and the
link is stored in @keiro_workflow_children@.

@
parent :: ('Workflow' ':>' es, 'Store' ':>' es, 'IOE' ':>' es) => Eff es Text
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
  re-delivers a completed child's stored result onto the current parent
  generation (attach semantics), throws 'WorkflowChildCancelled' if the child
  was cancelled meanwhile, and otherwise re-asserts nothing new (the spawn
  already registered the link). On the hit path
  it decodes a tagged parent-journal envelope: @{"ok": result}@ returns the
  child result, @{"cancelled": true}@ throws 'WorkflowChildCancelled',
  @{"failed": reason}@ throws 'WorkflowChildFailed', and legacy raw values are
  still decoded as pre-envelope successful results.
* __'runChildWorkflow'__ is what the resume worker selects (instead of bare
  'Keiro.Workflow.runWorkflowWith') for any workflow that is some parent's child:
  on 'Completed' it runs 'childCompletionHook', which flips the child row to
  @completed@ and appends @{"ok": result}@ to the parent's
  @child:\<childId\>:result@ step. If it finds a historically
  @cancelled@-but-unmarked row, it ensures the child cancellation marker and
  parent sentinel before returning 'Cancelled'.
* __'cancelChild'__ flips the child row to @cancelled@ and, in the same
  transaction, writes a 'Keiro.Workflow.WorkflowCancelled' marker to the
  /child/ journal plus a @{"cancelled": true}@ sentinel as the parent's
  await-step result. Retrying after a historical row-only cancel repairs both
  markers even though the return value remains 'False' ("this call did not
  transition the row").
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
    WorkflowChildFailed (..),
)
where

import Control.Exception (Exception)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
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
    ChildRow,
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
run compensation. If uncaught, the resume worker records the parent attempt,
backs it off, and eventually marks the parent failed at its configured ceiling.
Mirrors EP-40's 'Keiro.Workflow.Awakeable.WorkflowAwakeableCancelled'.
-}
data WorkflowChildCancelled = WorkflowChildCancelled WorkflowName WorkflowId
    deriving stock (Eq, Show)

instance Exception WorkflowChildCancelled

{- | Thrown out of 'awaitChild' when the child was terminally failed by the
resume worker. Carries the child's identity plus the persisted failure reason.
-}
data WorkflowChildFailed = WorkflowChildFailed WorkflowName WorkflowId Text
    deriving stock (Eq, Show)

instance Exception WorkflowChildFailed

-- ---------------------------------------------------------------------------
-- Authoring surface
-- ---------------------------------------------------------------------------

{- | Spawn a child workflow. Records a @StepRecorded \"child:\<childId\>\"@ in
the /parent/ journal (so a replay short-circuits and never re-spawns) and
inserts an idempotent @running@ link row, then returns a 'ChildHandle'. The
child is driven to completion by the resume worker from the registry, so
@childNm@ __must be registered there__; @childDef@ is accepted for authoring
ergonomics but is not run here.

A child id names one execution globally. Spawning an id whose child row already
completed attaches to that execution: 'awaitChild' re-delivers the stored
result onto the parent's current generation. To run a fresh child after
'Keiro.Workflow.continueAsNew', derive a fresh child id from the carried seed.
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

If the child was cancelled or failed, throws 'WorkflowChildCancelled' or
'WorkflowChildFailed'. Parent-journal values are tagged envelopes
(@{"ok": ...}@, @{"cancelled": true}@, @{"failed": reason}@) with a legacy raw
success fallback; a decode mismatch throws 'WorkflowStepDecodeError'.
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
                                , result = childOkEnvelope resultValue
                                , recordedAt = fromMaybe (row ^. #updatedAt) (row ^. #completedAt)
                                }
                -- The spawn already registered the link; nothing more to (re-)arm.
                _ -> pure ()
    raw <- awaitStep resultStep arm
    decodeChildResult childNm childWid (unStepName resultStep) raw

-- ---------------------------------------------------------------------------
-- External control
-- ---------------------------------------------------------------------------

{- | Cancel a child. For a @running@ child, flips its
@keiro_workflow_children@ row to @cancelled@ and, in the same transaction,
writes both the child's 'WorkflowCancelled' marker and the parent's
@{"cancelled": true}@ await-step sentinel. Returns 'True' only when this call
performed the row transition. For an already-@cancelled@ row, returns 'False'
but still ensures both markers, repairing historical crashes that committed the
row flip before either journal append. Already completed/failed/unknown
children return 'False' and no marker is fabricated.
-}
cancelChild ::
    (IOE :> es, Store :> es) =>
    ChildHandle a ->
    Eff es Bool
cancelChild (ChildHandle childNm childWid) = do
    mrow <- lookupChild (unWorkflowId childWid) (unWorkflowName childNm)
    case mrow of
        Nothing -> pure False
        Just row -> do
            (transitioned, childOutcome, parentOutcome) <- ensureChildCancelled row
            throwOnAppendConflict childOutcome
            throwOnAppendConflict parentOutcome
            pure transitioned

-- ---------------------------------------------------------------------------
-- Completion propagation
-- ---------------------------------------------------------------------------

{- | Drive a child workflow to completion, propagating its result to the parent.
This is 'runWorkflowWith' followed by 'childCompletionHook' on 'Completed': the
resume worker selects this (instead of bare 'runWorkflowWith') for any workflow
that is some parent's child, so a finished child wakes its waiting parent. A
'Suspended' child propagates nothing. A child row already marked 'ChildCancelled'
is repaired by ensuring the child cancellation marker and parent sentinel, then
returns 'Cancelled'; a 'ChildFailed' row returns 'Failed'.
-}
runChildWorkflow ::
    (IOE :> es, Store :> es, ToJSON a) =>
    WorkflowRunOptions ->
    WorkflowName ->
    WorkflowId ->
    Eff (Workflow : es) a ->
    Eff es (WorkflowOutcome a)
runChildWorkflow opts childNm childWid action = do
    mrow <- lookupChild (unWorkflowId childWid) (unWorkflowName childNm)
    case fmap (^. #status) mrow of
        Just ChildCancelled -> do
            for_ mrow $ \row -> do
                (_, childOutcome, parentOutcome) <- ensureChildCancelled row
                throwOnAppendConflict childOutcome
                throwOnAppendConflict parentOutcome
            pure Cancelled
        Just ChildFailed -> pure Failed
        _ -> do
            outcome <- runWorkflowWith opts childNm childWid action
            case outcome of
                Completed result -> do
                    childCompletionHook childNm childWid (toJSON result)
                    pure (Completed result)
                other -> pure other

{- | Propagate a finished child's result to its parent: flip the child row to
@completed@ (storing the raw result in the child row) and append an
@{"ok": result}@ @child:\<childId\>:result@ 'StepRecorded' to the /parent/
journal — exactly the wake source the parent's 'awaitChild' resolves on. The
running-row transition and parent append happen in one transaction. An
already-@completed@ row re-appends from the stored result, repairing historical
wedges; cancelled/failed children do not fabricate a success. Normally invoked
via 'runChildWorkflow'.
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
                        , result = childOkEnvelope resultValue
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
                        , result = childOkEnvelope stored
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

ensureChildCancelled ::
    (IOE :> es, Store :> es) =>
    ChildRow ->
    Eff es (Bool, JournalAppendOutcome, JournalAppendOutcome)
ensureChildCancelled row = do
    now <- liftIO getCurrentTime
    let childNm = WorkflowName (row ^. #childName)
        childWid = WorkflowId (row ^. #childId)
        parentNm = WorkflowName (row ^. #parentName)
        parentWid = WorkflowId (row ^. #parentId)
    childGen <- currentGeneration childNm childWid
    parentGen <- currentGeneration parentNm parentWid
    childAppendTx <- prepareJournalAppend childNm childWid childGen WorkflowCancelled{recordedAt = now}
    parentAppendTx <-
        prepareJournalAppend
            parentNm
            parentWid
            parentGen
            StepRecorded
                { stepName = row ^. #awaitStep
                , result = cancelledSentinel
                , recordedAt = now
                }
    runTransaction $ do
        transitioned <-
            if row ^. #status == Running
                then markChildCancelledTx (row ^. #childId) (row ^. #childName)
                else pure False
        if transitioned || row ^. #status == ChildCancelled
            then do
                childOutcome <- childAppendTx
                parentOutcome <- parentAppendTx
                condemnOnAppendConflict childOutcome
                condemnOnAppendConflict parentOutcome
                pure (transitioned, childOutcome, parentOutcome)
            else pure (False, JournalAlreadyPresent Aeson.Null, JournalAlreadyPresent Aeson.Null)

-- ---------------------------------------------------------------------------
-- The cancellation sentinel
-- ---------------------------------------------------------------------------

{- | The @{"cancelled": true}@ value 'cancelChild' writes as a cancelled child's
await-step result so 'awaitChild' can detect it and throw.
-}
cancelledSentinel :: Aeson.Value
cancelledSentinel = Aeson.object ["cancelled" Aeson..= True]

childOkEnvelope :: Aeson.Value -> Aeson.Value
childOkEnvelope value = Aeson.object ["ok" Aeson..= value]

decodeChildResult ::
    (FromJSON a) =>
    WorkflowName ->
    WorkflowId ->
    Text ->
    Aeson.Value ->
    Eff es a
decodeChildResult childNm childWid key raw =
    case raw of
        Aeson.Object obj
            | Just okValue <- KeyMap.lookup "ok" obj ->
                decodeOrThrow okValue
            | Just (Aeson.Bool True) <- KeyMap.lookup "cancelled" obj ->
                throwIO (WorkflowChildCancelled childNm childWid)
            | Just (Aeson.String reason) <- KeyMap.lookup "failed" obj ->
                throwIO (WorkflowChildFailed childNm childWid reason)
        _ -> decodeOrThrow raw
  where
    decodeOrThrow value =
        case Aeson.fromJSON value of
            Aeson.Success a -> pure a
            Aeson.Error e -> throwIO (WorkflowStepDecodeError key (Text.pack e))
