-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module BareContainers.ProjectionCatalog.ProjectionCatalogHoles
  ( BareWriterEvent (..)
  , applyBareWriterLive
  , bareWriterIdempotencyKey
  , applyBareWriterReplay
  , decodeBareWriterReplay
  ) where

import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent)

-- Projection owner bare_writer (order 10).
data BareWriterEvent = BareWriterEvent
applyBareWriterLive :: RecordedEvent -> Tx.Transaction ()
applyBareWriterLive = error "HOLE: fill bare_writer live apply"
bareWriterIdempotencyKey :: RecordedEvent -> EventId
bareWriterIdempotencyKey = error "HOLE: return the durable event id for bare_writer"
decodeBareWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult BareWriterEvent
decodeBareWriterReplay = error "HOLE: classify and decode every bare_writer source event"
applyBareWriterReplay :: BareWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyBareWriterReplay = error "HOLE: fill bare_writer replay apply without live-only side effects"
