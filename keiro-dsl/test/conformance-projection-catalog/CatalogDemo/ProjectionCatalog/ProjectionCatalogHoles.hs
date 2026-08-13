module CatalogDemo.ProjectionCatalog.ProjectionCatalogHoles
  ( applyOrderSummaryWriterLive
  , applyOrderSummaryWriterReplay
  , applyShipmentWriterLive
  , AuditWriterEvent
  , applyAuditWriterLive
  , auditWriterIdempotencyKey
  , applyAuditWriterReplay
  , decodeAuditWriterReplay
  , provisionReportingV1OrderSummary
  , validateReportingV1OrderSummary
  , provisionReportingV1OrderTotals
  , validateReportingV1OrderTotals
  , provisionReportingV1AuditLog
  , validateReportingV1AuditLog
  , applyReportingV1Live
  , applyReportingV1Replay
  , verifyReportingV1
  , provisionReportingV2OrderSummary
  , validateReportingV2OrderSummary
  , provisionReportingV2OrderTotals
  , validateReportingV2OrderTotals
  , provisionReportingV2AuditLog
  , validateReportingV2AuditLog
  , applyReportingV2Live
  , applyReportingV2Replay
  , verifyReportingV2
  ) where

import Data.Text (Text)
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

provisionReportingV1OrderSummary, provisionReportingV1OrderTotals, provisionReportingV1AuditLog :: Catalog.TargetProvisioningContext -> Tx.Transaction ()
provisionReportingV1OrderSummary = provisionNothing
provisionReportingV1OrderTotals = provisionNothing
provisionReportingV1AuditLog = provisionNothing

validateReportingV1OrderSummary, validateReportingV1OrderTotals, validateReportingV1AuditLog :: Catalog.TargetProvisioningContext -> Tx.Transaction (Either [Catalog.TargetSchemaViolation] Catalog.TargetSchemaEvidence)
validateReportingV1OrderSummary = validateAs "order-summary-v1" [promotion Catalog.PromotionIndex "order_summary_status_idx__v1" "order_summary_status_idx"]
validateReportingV1OrderTotals = validateAs "order-totals-v1" [promotion Catalog.PromotionConstraint "order_totals_pkey__v1" "order_totals_pkey"]
validateReportingV1AuditLog = validateAs "audit-log-v1" [promotion Catalog.PromotionOwnedSequence "audit_log_id_seq__v1" "audit_log_id_seq"]

applyReportingV1Live :: Catalog.PhysicalTargets -> RecordedEvent -> Tx.Transaction ()
applyReportingV1Live _targets _recorded = pure ()

applyReportingV1Replay :: Catalog.PhysicalTargets -> RecordedEvent -> Tx.Transaction (Either Catalog.ReplayDecodeError Bool)
applyReportingV1Replay _targets _recorded = pure (Right False)

verifyReportingV1 :: Catalog.PhysicalTargets -> Tx.Transaction (Either Text ())
verifyReportingV1 _targets = pure (Right ())

provisionReportingV2OrderSummary, provisionReportingV2OrderTotals, provisionReportingV2AuditLog :: Catalog.TargetProvisioningContext -> Tx.Transaction ()
provisionReportingV2OrderSummary = provisionNothing
provisionReportingV2OrderTotals = provisionNothing
provisionReportingV2AuditLog = provisionNothing

validateReportingV2OrderSummary, validateReportingV2OrderTotals, validateReportingV2AuditLog :: Catalog.TargetProvisioningContext -> Tx.Transaction (Either [Catalog.TargetSchemaViolation] Catalog.TargetSchemaEvidence)
validateReportingV2OrderSummary = validateAs "order-summary-v2" [promotion Catalog.PromotionIndex "order_summary_status_idx__v2" "order_summary_status_idx"]
validateReportingV2OrderTotals = validateAs "order-totals-v2" [promotion Catalog.PromotionConstraint "order_totals_pkey__v2" "order_totals_pkey"]
validateReportingV2AuditLog = validateAs "audit-log-v2" [promotion Catalog.PromotionOwnedSequence "audit_log_id_seq__v2" "audit_log_id_seq"]

applyReportingV2Live :: Catalog.PhysicalTargets -> RecordedEvent -> Tx.Transaction ()
applyReportingV2Live _targets _recorded = pure ()

applyReportingV2Replay :: Catalog.PhysicalTargets -> RecordedEvent -> Tx.Transaction (Either Catalog.ReplayDecodeError Bool)
applyReportingV2Replay _targets _recorded = pure (Right False)

verifyReportingV2 :: Catalog.PhysicalTargets -> Tx.Transaction (Either Text ())
verifyReportingV2 _targets = pure (Right ())

provisionNothing :: Catalog.TargetProvisioningContext -> Tx.Transaction ()
provisionNothing _context = pure ()

validateAs :: Text -> [Catalog.PromotionObjectName] -> Catalog.TargetProvisioningContext -> Tx.Transaction (Either [Catalog.TargetSchemaViolation] Catalog.TargetSchemaEvidence)
validateAs shape promotionObjects _context =
  pure
    ( Right
        Catalog.TargetSchemaEvidence
          { relationOid = 1,
            observedShapeFingerprint = shape,
            observedPromotionObjects = promotionObjects,
            catalogSnapshot = "conformance-catalog-snapshot-v1"
          }
    )

promotion :: Catalog.PromotionObjectKind -> Text -> Text -> Catalog.PromotionObjectName
promotion = Catalog.PromotionObjectName
