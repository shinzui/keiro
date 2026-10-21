-- | Application-owned hooks for commands that cannot exist in the standalone
-- @keiro-ops@ binary. Commands are mounted only when their hook is present.
--
-- This is the embedding boundary established by
-- @docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md@.
module Keiro.Ops.Embed
  ( AppHooks (..),
    OpsAuditConfig (..),
    AggregateInspectors,
    ProcessManagerInspectors,
    emptyAppHooks,
  )
where

import Keiro.Inspection.Aggregate (AggregateInspectors)
import Keiro.Ops.ReplayAudit (OpsAuditConfig (..))
import Keiro.Ops.Timer (TimerFire)
import Keiro.Ops.Workflow (ResumeHook)
import Keiro.ProcessManager.Inspect (ProcessManagerInspectors)
import Keiro.Projection.Catalog.Operations (ProjectionCatalogOperations)

data AppHooks = AppHooks
  { workflowResume :: !(Maybe ResumeHook),
    timerFire :: !(Maybe TimerFire),
    replayAudit :: !(Maybe OpsAuditConfig),
    projectionCatalog :: !(Maybe ProjectionCatalogOperations),
    aggregates :: !(Maybe AggregateInspectors),
    processManagers :: !(Maybe ProcessManagerInspectors)
  }

emptyAppHooks :: AppHooks
emptyAppHooks =
  AppHooks
    { workflowResume = Nothing,
      timerFire = Nothing,
      replayAudit = Nothing,
      projectionCatalog = Nothing,
      aggregates = Nothing,
      processManagers = Nothing
    }
