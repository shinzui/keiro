-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module CheckedMappingReplay.ProjectionCatalog.ProjectionCatalogHoles
  ( ReplayWriterEvent (..)
  , applyReplayWriterLive
  , replayWriterIdempotencyKey
  , applyReplayWriterReplay
  , decodeReplayWriterReplay
  ) where

import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent)

-- Projection owner replay_writer (order 10).
data ReplayWriterEvent = ReplayWriterEvent
applyReplayWriterLive :: RecordedEvent -> Tx.Transaction ()
applyReplayWriterLive = error "HOLE: fill replay_writer live apply"
replayWriterIdempotencyKey :: RecordedEvent -> EventId
replayWriterIdempotencyKey = error "HOLE: return the durable event id for replay_writer"
decodeReplayWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult ReplayWriterEvent
decodeReplayWriterReplay = error "HOLE: classify and decode every replay_writer source event"
applyReplayWriterReplay :: ReplayWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyReplayWriterReplay = error "HOLE: fill replay_writer replay apply without live-only side effects"
