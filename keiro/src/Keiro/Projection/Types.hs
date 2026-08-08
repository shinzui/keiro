{-# OPTIONS_HADDOCK hide #-}

module Keiro.Projection.Types
  ( InlineProjection (..),
    AsyncProjection (..),
  )
where

import Keiro.Prelude
import Kiroku.Store.Types (EventId, RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- | A projection applied in the same SQL transaction as its source event
-- append. A failing handler rolls back both the append and the target writes.
data InlineProjection event = InlineProjection
  { -- | Stable operational name used in inventory and diagnostics.
    name :: !Text,
    -- | Apply one decoded domain event together with its durable event-store
    -- envelope.
    apply :: !(event -> RecordedEvent -> Tx.Transaction ())
  }
  deriving stock (Generic)

-- | An at-least-once projection applied from a recorded event. The physical
-- name remains the compatibility dedup identity; catalog-aware callers also
-- bind it to stable logical subscription, dedup, projection, and group IDs.
data AsyncProjection = AsyncProjection
  { -- | Physical projection name used by the dedup table.
    name :: !Text,
    -- | Legacy read-model registry name used by unmanaged fencing.
    readModelName :: !Text,
    -- | Delivery checkpoint identity used by unmanaged workers.
    subscriptionName :: !Text,
    -- | Apply one recorded event to application-owned targets.
    applyRecorded :: !(RecordedEvent -> Tx.Transaction ()),
    -- | Stable event identity inserted transactionally before application.
    idempotencyKey :: !(RecordedEvent -> EventId)
  }
  deriving stock (Generic)
