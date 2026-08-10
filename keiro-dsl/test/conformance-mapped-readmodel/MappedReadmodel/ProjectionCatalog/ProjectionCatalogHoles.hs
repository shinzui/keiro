module MappedReadmodel.ProjectionCatalog.ProjectionCatalogHoles
  ( AccountSummaryWriterEvent,
    accountSummaryWriterIdempotencyKey,
    applyAccountSummaryWriterLive,
    applyAccountSummaryWriterReplay,
    decodeAccountSummaryWriterReplay,
  )
where

import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent (..))

data AccountSummaryWriterEvent = AccountSummaryWriterEvent

applyAccountSummaryWriterLive :: RecordedEvent -> Tx.Transaction ()
applyAccountSummaryWriterLive _recorded = pure ()

accountSummaryWriterIdempotencyKey :: RecordedEvent -> EventId
accountSummaryWriterIdempotencyKey RecordedEvent {eventId} = eventId

decodeAccountSummaryWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult AccountSummaryWriterEvent
decodeAccountSummaryWriterReplay _recorded = Catalog.ReplayRelevant AccountSummaryWriterEvent

applyAccountSummaryWriterReplay :: AccountSummaryWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyAccountSummaryWriterReplay _event _recorded = pure ()
