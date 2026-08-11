module Jitsurei.ReadModels
  ( OrderSummaryQuery (..),
    OrderSummary (..),
    jitsureiProjectionSchema,
    orderSummaryReadModel,
    orderSummaryInlineProjection,
    orderAuditAsyncProjection,
    orderProjectionSet,
    orderLiveProjections,
    orderAuditProjectionId,
    orderReportingGroupId,
    jitsureiProjectionCatalog,
    orderCatalogOperations,
    initializeOrderSummaryTable,
    selectOrderSummaryStmt,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Jitsurei.Domain
import Jitsurei.OrderStream (orderCodec)
import Keiro.Codec (decodeRecorded)
import Keiro.Connection (qualifyTable, quoteIdentifier)
import Keiro.Prelude
import Keiro.Projection (AsyncProjection (..), InlineProjection (..))
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog.Operations (ProjectionCatalogOperations, projectionCatalogOperations)
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), StrongScope (..))
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (FromBeginning))
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

-- | The user's explicit choice of where the jitsurei projection tables live —
-- deliberately a dedicated application schema, not the event store's @kiroku@
-- schema. This is the point of MasterPlan 12's configurable projection schema:
-- application read-model data is cleanly separated from the event store.
jitsureiProjectionSchema :: Text
jitsureiProjectionSchema = "jitsurei"

-- | The fully-qualified, double-quoted order-summary table reference
-- (@"jitsurei"."jitsurei_order_summary"@) interpolated into every DDL/DML
-- statement below, so all reads and writes are correct regardless of
-- @search_path@.
orderSummaryTable :: Text
orderSummaryTable = qualifyTable jitsureiProjectionSchema "jitsurei_order_summary"

orderLineTable :: Text
orderLineTable = qualifyTable jitsureiProjectionSchema "jitsurei_order_line"

orderAuditTable :: Text
orderAuditTable = qualifyTable jitsureiProjectionSchema "jitsurei_order_async_audit"

orderSideEffectTable :: Text
orderSideEffectTable = qualifyTable jitsureiProjectionSchema "jitsurei_order_live_side_effect"

newtype OrderSummaryQuery = OrderSummaryQuery OrderId
  deriving stock (Generic, Eq, Show)

data OrderSummary = OrderSummary
  { orderId :: !OrderId,
    sku :: !Sku,
    quantity :: !Quantity,
    status :: !Text,
    lastSeen :: !GlobalPosition
  }
  deriving stock (Generic, Eq, Show)

orderSummaryReadModel :: ReadModel OrderSummaryQuery (Maybe OrderSummary)
orderSummaryReadModel =
  ReadModel
    { name = "jitsurei-order-summary",
      tableName = "jitsurei_order_summary",
      schema = jitsureiProjectionSchema,
      subscriptionName = "jitsurei-order-summary-inline",
      version = 1,
      shapeHash = "jitsurei-order-summary-v1",
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \(OrderSummaryQuery orderId) ->
        Tx.statement (orderIdText orderId) selectOrderSummaryStmt
    }

orderSummaryInlineProjection :: InlineProjection OrderEvent
orderSummaryInlineProjection =
  InlineProjection
    { name = "jitsurei-order-summary-inline",
      apply = applyOrderEventLive
    }

orderAuditAsyncProjection :: AsyncProjection
orderAuditAsyncProjection =
  AsyncProjection
    { name = "jitsurei-order-audit-async",
      readModelName = orderSummaryReadModel ^. #name,
      subscriptionName = "jitsurei-order-audit-subscription",
      applyRecorded = \recorded ->
        case decodeRecorded orderCodec recorded of
          Left _ -> Tx.condemn
          Right event -> applyOrderAuditEvent event recorded,
      idempotencyKey = (^. #eventId)
    }

applyOrderEventLive :: OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderEventLive event recorded = do
  applyOrderEventForReplay event recorded
  Tx.statement
    ( globalPositionToInt (recorded ^. #globalPosition),
      eventStatus event
    )
    insertLiveSideEffectStmt

applyOrderEventForReplay :: OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderEventForReplay event recorded =
  case event of
    OrderPlaced payload -> do
      Tx.statement
        ( orderIdText payload.orderId,
          skuText payload.sku,
          Prelude.fromIntegral (quantityInt payload.quantity),
          "placed",
          globalPositionToInt (recorded ^. #globalPosition)
        )
        upsertOrderSummaryStmt
      Tx.statement
        ( orderIdText payload.orderId,
          skuText payload.sku,
          Prelude.fromIntegral (quantityInt payload.quantity),
          globalPositionToInt (recorded ^. #globalPosition)
        )
        upsertOrderLineStmt
    PaymentApproved payload ->
      updateStatus payload.orderId "paid" recorded
    OrderPacked payload ->
      updateStatus payload.orderId "packed" recorded
    OrderShipped payload ->
      updateStatus payload.orderId "shipped" recorded
    OrderCancelled payload ->
      updateStatus payload.orderId "cancelled" recorded

applyOrderAuditEvent :: OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderAuditEvent event recorded =
  Tx.statement
    ( globalPositionToInt (recorded ^. #globalPosition),
      eventStatus event
    )
    upsertOrderAuditStmt

eventStatus :: OrderEvent -> Text
eventStatus = \case
  OrderPlaced {} -> "placed"
  PaymentApproved {} -> "paid"
  OrderPacked {} -> "packed"
  OrderShipped {} -> "shipped"
  OrderCancelled {} -> "cancelled"

orderProjectionSet :: ProjectionSet OrderEvent
orderProjectionSet =
  ProjectionSet
    { projectionSource = orderSourceId,
      projectionDefinitions = orderSummaryDefinition :| [orderAuditDefinition],
      claimSite = claim "jitsurei:order-projection-set"
    }

orderSummaryDefinition :: ProjectionDefinition OrderEvent
orderSummaryDefinition =
  ProjectionDefinition
    { projectionId = orderSummaryProjectionId,
      rebuildGroup = orderReportingGroupId,
      ownedTargets = orderSummaryTargetId :| [orderLineTargetId],
      replayPolicy = Replayable (replayAdapterFromCodec orderCodec applyOrderEventForReplay),
      handlers = InlineHandler orderSummaryInlineProjection (claim "jitsurei:order-summary-inline") :| [],
      claimSite = claim "jitsurei:order-summary-owner"
    }

orderAuditDefinition :: ProjectionDefinition OrderEvent
orderAuditDefinition =
  ProjectionDefinition
    { projectionId = orderAuditProjectionId,
      rebuildGroup = orderReportingGroupId,
      ownedTargets = orderAuditTargetId :| [],
      replayPolicy = Replayable (replayAdapterFromCodec orderCodec applyOrderAuditEvent),
      handlers =
        AsyncHandler orderAuditAsyncProjection orderAuditSubscriptionId orderAuditDedupId (claim "jitsurei:order-audit-async")
          :| [],
      claimSite = claim "jitsurei:order-audit-owner"
    }

jitsureiProjectionCatalog :: ValidatedProjectionCatalog
jitsureiProjectionCatalog =
  case validateProjectionCatalog jitsureiProjectionCatalogDefinition of
    Failure diagnostics -> error ("invalid jitsurei projection catalog: " <> show diagnostics)
    Success catalog -> catalog

jitsureiProjectionCatalogDefinition :: ProjectionCatalog
jitsureiProjectionCatalogDefinition =
  ProjectionCatalog
    { sources =
        [ SourceDeclaration
            { sourceId = orderSourceId,
              sourceScope = CategorySource (CategoryName "order"),
              codecFingerprint = "jitsurei/order-codec/v2",
              claimSite = claim "jitsurei:order-source"
            }
        ],
      targets =
        [ TargetDeclaration
            { targetId = orderSummaryTargetId,
              qualifiedTable = QualifiedTable jitsureiProjectionSchema "jitsurei_order_summary",
              resetPolicy = PreserveAndReconcile,
              dependsOn = [],
              claimSite = claim "jitsurei:order-summary-target"
            },
          TargetDeclaration
            { targetId = orderLineTargetId,
              qualifiedTable = QualifiedTable jitsureiProjectionSchema "jitsurei_order_line",
              resetPolicy = ClearBeforeReplay,
              dependsOn = [orderSummaryTargetId],
              claimSite = claim "jitsurei:order-line-target"
            },
          TargetDeclaration
            { targetId = orderAuditTargetId,
              qualifiedTable = QualifiedTable jitsureiProjectionSchema "jitsurei_order_async_audit",
              resetPolicy = ClearBeforeReplay,
              dependsOn = [orderSummaryTargetId],
              claimSite = claim "jitsurei:order-audit-target"
            }
        ],
      rebuildGroups =
        [ RebuildGroupDeclaration
            { rebuildGroupId = orderReportingGroupId,
              orderedTargets = [orderSummaryTargetId, orderLineTargetId, orderAuditTargetId],
              verificationHooks =
                [ RebuildVerification
                    { verificationId = "order-lines-and-brownfield-roots-valid",
                      verificationVersion = "v1",
                      verifyRebuild = do
                        valid <- Tx.statement () verifyOrderLinesStmt
                        pure (if valid then Right () else Left "order lines or preserved brownfield roots require repair")
                    }
                ],
              claimSite = claim "jitsurei:order-reporting-group"
            }
        ],
      subscriptions =
        [ SubscriptionDeclaration
            { subscriptionId = orderAuditSubscriptionId,
              subscriptionName = orderAuditAsyncProjection ^. #subscriptionName,
              subscriptionSource = orderSourceId,
              checkpointOnMissing = FromBeginning,
              claimSite = claim "jitsurei:order-audit-subscription"
            }
        ],
      dedupKeys =
        [ DedupKeyDeclaration
            { dedupKeyId = orderAuditDedupId,
              dedupName = orderAuditAsyncProjection ^. #name,
              claimSite = claim "jitsurei:order-audit-dedup"
            }
        ],
      queryModels =
        [ SomeQueryModelBinding
            QueryModelBinding
              { queryModelId = orderSummaryQueryModelId,
                readModel = orderSummaryReadModel,
                rebuildGroup = orderReportingGroupId,
                observedTargets = [orderSummaryTargetId],
                claimSite = claim "jitsurei:order-summary-query"
              }
        ],
      projectionSets = [SomeProjectionSet orderProjectionSet]
    }

orderLiveProjections :: [InlineProjection OrderEvent]
orderLiveProjections = typedInlineProjections jitsureiProjectionCatalog orderProjectionSet

orderCatalogOperations :: ProjectionCatalogOperations
orderCatalogOperations = projectionCatalogOperations jitsureiProjectionCatalog

orderSummaryProjectionId, orderAuditProjectionId :: ProjectionId
orderSummaryProjectionId = identityOrError mkProjectionId "jitsurei-order-summary"
orderAuditProjectionId = identityOrError mkProjectionId "jitsurei-order-audit"

orderSummaryTargetId, orderLineTargetId, orderAuditTargetId :: TargetId
orderSummaryTargetId = identityOrError mkTargetId "jitsurei-order-summary"
orderLineTargetId = identityOrError mkTargetId "jitsurei-order-line"
orderAuditTargetId = identityOrError mkTargetId "jitsurei-order-async-audit"

orderReportingGroupId :: RebuildGroupId
orderReportingGroupId = identityOrError mkRebuildGroupId "jitsurei-order-reporting"

orderSourceId :: SourceId
orderSourceId = identityOrError mkSourceId "jitsurei-order-events"

orderSummaryQueryModelId :: QueryModelId
orderSummaryQueryModelId = identityOrError mkQueryModelId "jitsurei-order-summary-query"

orderAuditSubscriptionId :: SubscriptionId
orderAuditSubscriptionId = identityOrError mkSubscriptionId "jitsurei-order-audit-subscription"

orderAuditDedupId :: DedupKeyId
orderAuditDedupId = identityOrError mkDedupKeyId "jitsurei-order-audit-dedup"

claim :: Text -> ClaimSite
claim = identityOrError mkClaimSite

identityOrError :: (Text -> Either CatalogIdentityError identity) -> Text -> identity
identityOrError constructor value =
  case constructor value of
    Left err -> error (Text.unpack ("invalid jitsurei catalog identity: " <> Text.pack (show err)))
    Right identity -> identity

updateStatus :: OrderId -> Text -> RecordedEvent -> Tx.Transaction ()
updateStatus orderId status recorded =
  Tx.statement
    ( orderIdText orderId,
      status,
      globalPositionToInt (recorded ^. #globalPosition)
    )
    updateOrderSummaryStatusStmt

-- | Create the application projection schema (opt-in, app-owned) and the
-- order-summary read-model table, fully qualified into that schema. 'Tx.sql' runs
-- a multi-statement, parameter-free script, so the @CREATE SCHEMA@ and
-- @CREATE TABLE@ share one call. Both are idempotent (@IF NOT EXISTS@).
initializeOrderSummaryTable :: Tx.Transaction ()
initializeOrderSummaryTable =
  Tx.sql
    $ TE.encodeUtf8
    $ "CREATE SCHEMA IF NOT EXISTS "
    <> quoteIdentifier jitsureiProjectionSchema
    <> ";\n"
    <> "CREATE TABLE IF NOT EXISTS "
    <> orderSummaryTable
    <> " (\n"
    <> "  order_id TEXT PRIMARY KEY,\n"
    <> "  sku TEXT NOT NULL,\n"
    <> "  quantity BIGINT NOT NULL,\n"
    <> "  status TEXT NOT NULL,\n"
    <> "  last_seen BIGINT NOT NULL\n"
    <> ");\n"
    <> "CREATE TABLE IF NOT EXISTS "
    <> orderLineTable
    <> " (\n"
    <> "  order_id TEXT NOT NULL REFERENCES "
    <> orderSummaryTable
    <> "(order_id),\n"
    <> "  line_no INTEGER NOT NULL,\n"
    <> "  sku TEXT NOT NULL,\n"
    <> "  quantity BIGINT NOT NULL,\n"
    <> "  last_seen BIGINT NOT NULL,\n"
    <> "  PRIMARY KEY (order_id, line_no)\n"
    <> ");\n"
    <> "CREATE TABLE IF NOT EXISTS "
    <> orderAuditTable
    <> " (\n"
    <> "  global_position BIGINT PRIMARY KEY,\n"
    <> "  status TEXT NOT NULL\n"
    <> ");\n"
    <> "CREATE TABLE IF NOT EXISTS "
    <> orderSideEffectTable
    <> " (\n"
    <> "  global_position BIGINT PRIMARY KEY,\n"
    <> "  effect TEXT NOT NULL\n"
    <> ")"

upsertOrderSummaryStmt :: Statement (Text, Text, Int64, Text, Int64) ()
upsertOrderSummaryStmt =
  preparable
    ( "INSERT INTO "
        <> orderSummaryTable
        <> " (order_id, sku, quantity, status, last_seen)\n"
        <> "VALUES ($1, $2, $3, $4, $5)\n"
        <> "ON CONFLICT (order_id) DO UPDATE\n"
        <> "  SET sku = EXCLUDED.sku,\n"
        <> "      quantity = EXCLUDED.quantity,\n"
        <> "      status = EXCLUDED.status,\n"
        <> "      last_seen = EXCLUDED.last_seen"
    )
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

upsertOrderLineStmt :: Statement (Text, Text, Int64, Int64) ()
upsertOrderLineStmt =
  preparable
    ( "INSERT INTO "
        <> orderLineTable
        <> " (order_id, line_no, sku, quantity, last_seen)\n"
        <> "VALUES ($1, 1, $2, $3, $4)\n"
        <> "ON CONFLICT (order_id, line_no) DO UPDATE\n"
        <> "  SET sku = EXCLUDED.sku,\n"
        <> "      quantity = EXCLUDED.quantity,\n"
        <> "      last_seen = EXCLUDED.last_seen"
    )
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

upsertOrderAuditStmt :: Statement (Int64, Text) ()
upsertOrderAuditStmt =
  preparable
    ( "INSERT INTO "
        <> orderAuditTable
        <> " (global_position, status) VALUES ($1, $2)\n"
        <> "ON CONFLICT (global_position) DO UPDATE SET status = EXCLUDED.status"
    )
    (contrazip2 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.text)))
    D.noResult

insertLiveSideEffectStmt :: Statement (Int64, Text) ()
insertLiveSideEffectStmt =
  preparable
    ( "INSERT INTO "
        <> orderSideEffectTable
        <> " (global_position, effect) VALUES ($1, $2)\n"
        <> "ON CONFLICT (global_position) DO NOTHING"
    )
    (contrazip2 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.text)))
    D.noResult

verifyOrderLinesStmt :: Statement () Bool
verifyOrderLinesStmt =
  preparable
    ( "SELECT NOT EXISTS (\n"
        <> "  SELECT 1 FROM "
        <> orderLineTable
        <> " line\n"
        <> "  LEFT JOIN "
        <> orderSummaryTable
        <> " summary ON summary.order_id = line.order_id\n"
        <> "  WHERE summary.order_id IS NULL\n"
        <> ") AND NOT EXISTS (\n"
        <> "  SELECT 1 FROM "
        <> orderSummaryTable
        <> " WHERE status = 'rebuild-blocked'\n"
        <> ")"
    )
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

updateOrderSummaryStatusStmt :: Statement (Text, Text, Int64) ()
updateOrderSummaryStatusStmt =
  preparable
    ( "UPDATE "
        <> orderSummaryTable
        <> "\nSET status = $2,\n    last_seen = $3\n"
        <> "WHERE order_id = $1"
    )
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

selectOrderSummaryStmt :: Statement Text (Maybe OrderSummary)
selectOrderSummaryStmt =
  preparable
    ( "SELECT order_id, sku, quantity, status, last_seen\n"
        <> "FROM "
        <> orderSummaryTable
        <> "\nWHERE order_id = $1"
    )
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe
        ( OrderSummary
            <$> (OrderId <$> D.column (D.nonNullable D.text))
            <*> (Sku <$> D.column (D.nonNullable D.text))
            <*> (Quantity . Prelude.fromIntegral <$> D.column (D.nonNullable D.int8))
            <*> D.column (D.nonNullable D.text)
            <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
        )
    )

globalPositionToInt :: GlobalPosition -> Int64
globalPositionToInt (GlobalPosition value) = value
