-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module StructuralNominalLeaves.ProjectionCatalog.ProjectionCatalogHoles
  ( TemplateWriterEvent (..)
  , applyTemplateWriterLive
  , templateWriterIdempotencyKey
  , applyTemplateWriterReplay
  , decodeTemplateWriterReplay
  ) where

import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent)

-- Projection owner template_writer (order 10).
data TemplateWriterEvent = TemplateWriterEvent
applyTemplateWriterLive :: RecordedEvent -> Tx.Transaction ()
applyTemplateWriterLive = error "HOLE: fill template_writer live apply"
templateWriterIdempotencyKey :: RecordedEvent -> EventId
templateWriterIdempotencyKey = error "HOLE: return the durable event id for template_writer"
decodeTemplateWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult TemplateWriterEvent
decodeTemplateWriterReplay = error "HOLE: classify and decode every template_writer source event"
applyTemplateWriterReplay :: TemplateWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyTemplateWriterReplay = error "HOLE: fill template_writer replay apply without live-only side effects"
