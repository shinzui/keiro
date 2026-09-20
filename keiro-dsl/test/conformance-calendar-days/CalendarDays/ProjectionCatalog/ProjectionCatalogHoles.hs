-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module CalendarDays.ProjectionCatalog.ProjectionCatalogHoles
  ( CalendarWriterEvent (..)
  , applyCalendarWriterLive
  , calendarWriterIdempotencyKey
  , applyCalendarWriterReplay
  , decodeCalendarWriterReplay
  ) where

import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent)

-- Projection owner calendar_writer (order 10).
data CalendarWriterEvent = CalendarWriterEvent
applyCalendarWriterLive :: RecordedEvent -> Tx.Transaction ()
applyCalendarWriterLive = error "HOLE: fill calendar_writer live apply"
calendarWriterIdempotencyKey :: RecordedEvent -> EventId
calendarWriterIdempotencyKey = error "HOLE: return the durable event id for calendar_writer"
decodeCalendarWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult CalendarWriterEvent
decodeCalendarWriterReplay = error "HOLE: classify and decode every calendar_writer source event"
applyCalendarWriterReplay :: CalendarWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyCalendarWriterReplay = error "HOLE: fill calendar_writer replay apply without live-only side effects"
