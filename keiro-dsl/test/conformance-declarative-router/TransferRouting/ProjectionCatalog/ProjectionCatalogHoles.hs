-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module TransferRouting.ProjectionCatalog.ProjectionCatalogHoles
  ( HospitalLoadWriterEvent
  , applyHospitalLoadWriterLive
  , hospitalLoadWriterIdempotencyKey
  , applyHospitalLoadWriterReplay
  , decodeHospitalLoadWriterReplay
  ) where

import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent)

-- Projection owner hospital_load_writer (order 10).
data HospitalLoadWriterEvent = HospitalLoadWriterEvent
applyHospitalLoadWriterLive :: RecordedEvent -> Tx.Transaction ()
applyHospitalLoadWriterLive = error "HOLE: fill hospital_load_writer live apply"
hospitalLoadWriterIdempotencyKey :: RecordedEvent -> EventId
hospitalLoadWriterIdempotencyKey = error "HOLE: return the durable event id for hospital_load_writer"
decodeHospitalLoadWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult HospitalLoadWriterEvent
decodeHospitalLoadWriterReplay = error "HOLE: classify and decode every hospital_load_writer source event"
applyHospitalLoadWriterReplay :: HospitalLoadWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyHospitalLoadWriterReplay = error "HOLE: fill hospital_load_writer replay apply without live-only side effects"
