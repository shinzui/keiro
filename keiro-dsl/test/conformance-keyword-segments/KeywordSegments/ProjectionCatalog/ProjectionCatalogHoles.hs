-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module KeywordSegments.ProjectionCatalog.ProjectionCatalogHoles
  ( ValidateCustomTypeWriterEvent (..)
  , applyValidateCustomTypeWriterLive
  , validateCustomTypeWriterIdempotencyKey
  , applyValidateCustomTypeWriterReplay
  , decodeValidateCustomTypeWriterReplay
  ) where

import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent (..))

-- Projection owner validate_custom_type_writer (order 10).
data ValidateCustomTypeWriterEvent = ValidateCustomTypeWriterEvent
applyValidateCustomTypeWriterLive :: RecordedEvent -> Tx.Transaction ()
applyValidateCustomTypeWriterLive _recorded = pure ()
validateCustomTypeWriterIdempotencyKey :: RecordedEvent -> EventId
validateCustomTypeWriterIdempotencyKey RecordedEvent {eventId} = eventId
decodeValidateCustomTypeWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult ValidateCustomTypeWriterEvent
decodeValidateCustomTypeWriterReplay _recorded = Catalog.ReplayRelevant ValidateCustomTypeWriterEvent
applyValidateCustomTypeWriterReplay :: ValidateCustomTypeWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyValidateCustomTypeWriterReplay _event _recorded = pure ()
