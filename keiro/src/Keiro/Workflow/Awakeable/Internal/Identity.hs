-- | Frozen generation-0 awakeable identity.
--
-- This module owns the seed shape and encoding probes used by both the public
-- compatibility surface and generation-0 row adoption. Keeping those paths on
-- one implementation prevents a compatibility probe from drifting away from
-- the identifier that the runtime can actually adopt.
module Keiro.Workflow.Awakeable.Internal.Identity
  ( generation0AwakeableUuid,
    preUtf8Generation0AwakeableUuid,
    generation0AwakeableUuidProbes,
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID (UUID)
import Data.UUID.V5 qualified as UUID.V5
import Keiro.DeterministicId (deterministicIdProbes, identitySeedBytes, legacySeedBytes)
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))

-- | The frozen UTF-8 generation-0 identifier.
generation0AwakeableUuid :: WorkflowName -> WorkflowId -> Text -> UUID
generation0AwakeableUuid name wid label =
  UUID.V5.generateNamed UUID.V5.namespaceURL $
    identitySeedBytes $
      awakeableSeed name wid label

-- | The frozen pre-UTF-8 generation-0 identifier.
preUtf8Generation0AwakeableUuid :: WorkflowName -> WorkflowId -> Text -> UUID
preUtf8Generation0AwakeableUuid name wid label =
  UUID.V5.generateNamed UUID.V5.namespaceURL $
    legacySeedBytes $
      awakeableSeed name wid label

-- | Ordered adoption candidates: UTF-8 first, then pre-UTF-8 only when the
-- encodings differ.
generation0AwakeableUuidProbes :: WorkflowName -> WorkflowId -> Text -> NonEmpty UUID
generation0AwakeableUuidProbes name wid label =
  deterministicIdProbes (awakeableSeed name wid label)

awakeableSeed :: WorkflowName -> WorkflowId -> Text -> Text
awakeableSeed (WorkflowName name) (WorkflowId wid) label =
  Text.intercalate ":" ["keiro", "awakeable", name, wid, label]
