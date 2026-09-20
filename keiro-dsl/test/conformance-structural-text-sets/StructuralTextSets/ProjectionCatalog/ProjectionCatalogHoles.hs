-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module StructuralTextSets.ProjectionCatalog.ProjectionCatalogHoles
  ( LabelWriterEvent (..)
  , applyLabelWriterLive
  , labelWriterIdempotencyKey
  , applyLabelWriterReplay
  , decodeLabelWriterReplay
  ) where

import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent)

-- Projection owner label_writer (order 10).
data LabelWriterEvent = LabelWriterEvent
applyLabelWriterLive :: RecordedEvent -> Tx.Transaction ()
applyLabelWriterLive = error "HOLE: fill label_writer live apply"
labelWriterIdempotencyKey :: RecordedEvent -> EventId
labelWriterIdempotencyKey = error "HOLE: return the durable event id for label_writer"
decodeLabelWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult LabelWriterEvent
decodeLabelWriterReplay = error "HOLE: classify and decode every label_writer source event"
applyLabelWriterReplay :: LabelWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyLabelWriterReplay = error "HOLE: fill label_writer replay apply without live-only side effects"
