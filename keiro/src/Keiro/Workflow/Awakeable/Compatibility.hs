-- | Compatibility probes for awakeables created by generation-0 Keiro.
--
-- These identifiers are predictable from workflow coordinates, but fresh
-- awakeables are random and journaled. Ordinary workflow code must use
-- 'Keiro.Workflow.Awakeable.awakeableNamed' and pass along the returned id.
module Keiro.Workflow.Awakeable.Compatibility
  ( generation0AwakeableId,
    preUtf8Generation0AwakeableId,
  )
where

import Data.Text (Text)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Awakeable.Internal.Identity
  ( generation0AwakeableUuid,
    preUtf8Generation0AwakeableUuid,
  )
import Keiro.Workflow.Types (WorkflowId, WorkflowName)

-- | Reproduce the UTF-8 generation-0 id for compatibility inspection and
-- adoption tests. This does not predict a fresh allocation.
generation0AwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId
generation0AwakeableId name wid label =
  AwakeableId (generation0AwakeableUuid name wid label)

-- | Reproduce the pre-UTF-8 generation-0 id for compatibility inspection and
-- adoption tests. This does not predict a fresh allocation.
preUtf8Generation0AwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId
preUtf8Generation0AwakeableId name wid label =
  AwakeableId (preUtf8Generation0AwakeableUuid name wid label)
