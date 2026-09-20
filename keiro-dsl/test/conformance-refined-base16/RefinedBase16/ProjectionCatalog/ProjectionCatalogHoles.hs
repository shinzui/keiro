-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module RefinedBase16.ProjectionCatalog.ProjectionCatalogHoles
  ( HashWriterEvent (..)
  , applyHashWriterLive
  , hashWriterIdempotencyKey
  , applyHashWriterReplay
  , decodeHashWriterReplay
  ) where

import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent)

-- Projection owner hash_writer (order 10).
data HashWriterEvent = HashWriterEvent
applyHashWriterLive :: RecordedEvent -> Tx.Transaction ()
applyHashWriterLive = error "HOLE: fill hash_writer live apply"
hashWriterIdempotencyKey :: RecordedEvent -> EventId
hashWriterIdempotencyKey = error "HOLE: return the durable event id for hash_writer"
decodeHashWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult HashWriterEvent
decodeHashWriterReplay = error "HOLE: classify and decode every hash_writer source event"
applyHashWriterReplay :: HashWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyHashWriterReplay = error "HOLE: fill hash_writer replay apply without live-only side effects"
