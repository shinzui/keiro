module CatalogDemo.ProjectionCatalog.ProjectionCatalogHoles
  ( applyOrderSummaryWriterLive
  , applyOrderSummaryWriterReplay
  , applyShipmentWriterLive
  , AuditWriterEvent
  , applyAuditWriterLive
  , auditWriterIdempotencyKey
  , applyAuditWriterReplay
  , decodeAuditWriterReplay
  ) where

import Hasql.Transaction qualified as Tx
import Generated.CatalogDemo.Orders.Domain (OrdersEvent)
import Generated.CatalogDemo.Shipments.Domain (ShipmentsEvent)
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (EventId, RecordedEvent (..))

applyOrderSummaryWriterLive :: OrdersEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderSummaryWriterLive _event _recorded = pure ()

applyOrderSummaryWriterReplay :: OrdersEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderSummaryWriterReplay _event _recorded = pure ()

applyShipmentWriterLive :: ShipmentsEvent -> RecordedEvent -> Tx.Transaction ()
applyShipmentWriterLive _event _recorded = pure ()

data AuditWriterEvent = AuditWriterEvent

applyAuditWriterLive :: RecordedEvent -> Tx.Transaction ()
applyAuditWriterLive _recorded = pure ()

auditWriterIdempotencyKey :: RecordedEvent -> EventId
auditWriterIdempotencyKey RecordedEvent {eventId} = eventId

decodeAuditWriterReplay :: RecordedEvent -> Catalog.ReplayDecodeResult AuditWriterEvent
decodeAuditWriterReplay _recorded = Catalog.ReplayRelevant AuditWriterEvent

applyAuditWriterReplay :: AuditWriterEvent -> RecordedEvent -> Tx.Transaction ()
applyAuditWriterReplay _event _recorded = pure ()
