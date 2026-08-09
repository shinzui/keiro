-- | Application-owned hooks for commands that cannot exist in the standalone
-- @keiro-ops@ binary. Commands are mounted only when their hook is present.
--
-- This is the embedding boundary established by
-- @docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md@.
module Keiro.Ops.Embed
  ( AppHooks (..),
    OpsAuditConfig (..),
    emptyAppHooks,
  )
where

import Keiro.Ops.ReplayAudit (OpsAuditConfig (..))
import Keiro.Ops.Timer (TimerFire)
import Keiro.Ops.Workflow (ResumeHook)
import Keiro.Projection.Catalog.Operations (ProjectionCatalogOperations)

data AppHooks = AppHooks
  { workflowResume :: !(Maybe ResumeHook),
    timerFire :: !(Maybe TimerFire),
    replayAudit :: !(Maybe OpsAuditConfig),
    projectionCatalog :: !(Maybe ProjectionCatalogOperations)
  }

emptyAppHooks :: AppHooks
emptyAppHooks =
  AppHooks
    { workflowResume = Nothing,
      timerFire = Nothing,
      replayAudit = Nothing,
      projectionCatalog = Nothing
    }
