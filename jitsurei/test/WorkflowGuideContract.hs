-- | Compile-owned witnesses for the signatures displayed in the durable
-- workflow guide and user reference. These are deliberately thin forwards to
-- the public API: if a documented constraint drifts, this module stops building.
module WorkflowGuideContract
  ( guideStep,
    guideSleepNamed,
    guideAwakeableNamed,
    guideSignalAwakeable,
    guideCancelAwakeable,
    guideSpawnChild,
    guideAwaitChild,
    guideCancelChild,
    guideRunWorkflow,
    guideRunWorkflowWith,
    guideContinueAsNew,
    guideRestoreSeed,
    guidePatch,
    guideResumeWorkflowsOnce,
    guideOrderFulfillmentWorkflow,
    guideJitsureiWorkflowRegistryWith,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Jitsurei.Domain (OrderId)
import Jitsurei.DurableWorkflow
  ( PublishPaymentAwakeable,
    jitsureiWorkflowRegistryWith,
    orderFulfillmentWorkflow,
  )
import Keiro.Workflow
  ( PatchId,
    StepName,
    Workflow,
    WorkflowId,
    WorkflowName,
    WorkflowOutcome,
    WorkflowRunOptions,
    continueAsNew,
    patch,
    restoreSeed,
    runWorkflow,
    runWorkflowWith,
    step,
  )
import Keiro.Workflow.Awakeable
  ( AwakeableId,
    awakeableNamed,
    cancelAwakeable,
    signalAwakeable,
  )
import Keiro.Workflow.Child
  ( ChildHandle,
    awaitChild,
    cancelChild,
    spawnChild,
  )
import Keiro.Workflow.Resume
  ( ResumeSummary,
    WorkflowRegistry,
    WorkflowResumeOptions,
    resumeWorkflowsOnce,
  )
import Keiro.Workflow.Sleep (sleepNamed)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)

guideStep ::
  (Workflow :> es, ToJSON a, FromJSON a) =>
  StepName ->
  Eff es a ->
  Eff es a
guideStep = step

guideSleepNamed ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  StepName ->
  NominalDiffTime ->
  Eff es ()
guideSleepNamed = sleepNamed

guideAwakeableNamed ::
  (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
  StepName ->
  Eff es (AwakeableId, Eff es a)
guideAwakeableNamed = awakeableNamed

guideSignalAwakeable ::
  (IOE :> es, Store :> es, ToJSON r) =>
  AwakeableId ->
  r ->
  Eff es Bool
guideSignalAwakeable = signalAwakeable

guideCancelAwakeable ::
  (Store :> es) =>
  AwakeableId ->
  Eff es Bool
guideCancelAwakeable = cancelAwakeable

guideSpawnChild ::
  (Workflow :> es, Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  Eff (Workflow : es) a ->
  Eff es (ChildHandle a)
guideSpawnChild = spawnChild

guideAwaitChild ::
  (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
  ChildHandle a ->
  Eff es a
guideAwaitChild = awaitChild

guideCancelChild ::
  (IOE :> es, Store :> es) =>
  ChildHandle a ->
  Eff es Bool
guideCancelChild = cancelChild

guideRunWorkflow ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  WorkflowName ->
  WorkflowId ->
  Eff (Workflow : es) a ->
  Eff es (WorkflowOutcome a)
guideRunWorkflow = runWorkflow

guideRunWorkflowWith ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  WorkflowRunOptions ->
  WorkflowName ->
  WorkflowId ->
  Eff (Workflow : es) a ->
  Eff es (WorkflowOutcome a)
guideRunWorkflowWith = runWorkflowWith

guideContinueAsNew ::
  (Workflow :> es, ToJSON s) =>
  s ->
  Eff es a
guideContinueAsNew = continueAsNew

guideRestoreSeed ::
  (Workflow :> es, ToJSON s, FromJSON s) =>
  s ->
  Eff es s
guideRestoreSeed = restoreSeed

guidePatch ::
  (Workflow :> es) =>
  PatchId ->
  Eff es Bool
guidePatch = patch

guideResumeWorkflowsOnce ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  WorkflowResumeOptions ->
  WorkflowRegistry es ->
  Eff es ResumeSummary
guideResumeWorkflowsOnce = resumeWorkflowsOnce

guideOrderFulfillmentWorkflow ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  PublishPaymentAwakeable es ->
  OrderId ->
  Eff es Text
guideOrderFulfillmentWorkflow = orderFulfillmentWorkflow

guideJitsureiWorkflowRegistryWith ::
  (Store :> es, IOE :> es) =>
  PublishPaymentAwakeable es ->
  WorkflowRegistry es
guideJitsureiWorkflowRegistryWith = jitsureiWorkflowRegistryWith
