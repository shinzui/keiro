-- | One operational hook definition shared by the CLI and HTTP hosts.
module Jitsurei.Ops
  ( jitsureiOpsHooks,
    jitsureiWorkflowRunOptions,
    jitsureiWorkflowResumeOptions,
  )
where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Jitsurei.DurableWorkflow (jitsureiWorkflowRegistry)
import Jitsurei.Inspection (jitsureiAggregateInspectors, jitsureiProcessManagerInspectors)
import Jitsurei.ReadModels (orderCatalogOperations)
import Jitsurei.ReplayAudit (replayAuditTargets)
import Keiro.Ops qualified as Ops
import Keiro.Telemetry qualified as Telemetry
import Keiro.Workflow (WorkflowRunOptions, defaultWorkflowRunOptions)
import Keiro.Workflow.Resume (WorkflowResumeOptions, defaultWorkflowResumeOptions)
import Keiro.Workflow.Sleep (workflowSleepFireAction)

jitsureiOpsHooks :: Maybe Telemetry.KeiroMetrics -> Ops.AppHooks
jitsureiOpsHooks metrics =
  Ops.AppHooks
    { workflowResume = Just (jitsureiWorkflowRegistry, jitsureiWorkflowResumeOptions metrics),
      timerFire = Just workflowSleepFireAction,
      replayAudit = Just (Ops.OpsAuditConfig replayAuditTargets),
      projectionCatalog = Just orderCatalogOperations,
      aggregates = Just jitsureiAggregateInspectors,
      durableConsumers = Nothing,
      processManagers = Just jitsureiProcessManagerInspectors
    }

jitsureiWorkflowRunOptions :: Maybe Telemetry.KeiroMetrics -> WorkflowRunOptions
jitsureiWorkflowRunOptions metrics =
  defaultWorkflowRunOptions & #metrics .~ metrics

jitsureiWorkflowResumeOptions :: Maybe Telemetry.KeiroMetrics -> WorkflowResumeOptions
jitsureiWorkflowResumeOptions metrics =
  defaultWorkflowResumeOptions & #runOptions .~ jitsureiWorkflowRunOptions metrics
