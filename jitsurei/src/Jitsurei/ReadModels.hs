module Jitsurei.ReadModels (
    OrderSummaryQuery (..),
    OrderSummary (..),
    jitsureiProjectionSchema,
    orderSummaryReadModel,
    orderSummaryInlineProjection,
    initializeOrderSummaryTable,
    selectOrderSummaryStmt,
)
where

import Contravariant.Extras (contrazip3, contrazip5)
import Data.Text.Encoding qualified as TE
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Jitsurei.Domain
import Keiro.Connection (qualifyTable, quoteIdentifier)
import Keiro.Prelude
import Keiro.Projection (InlineProjection (..))
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..))
import Kiroku.Store.Types (GlobalPosition (..), RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

{- | The user's explicit choice of where the jitsurei projection tables live —
deliberately a dedicated application schema, not the event store's @kiroku@
schema. This is the point of MasterPlan 12's configurable projection schema:
application read-model data is cleanly separated from the event store.
-}
jitsureiProjectionSchema :: Text
jitsureiProjectionSchema = "jitsurei"

{- | The fully-qualified, double-quoted order-summary table reference
(@"jitsurei"."jitsurei_order_summary"@) interpolated into every DDL/DML
statement below, so all reads and writes are correct regardless of
@search_path@.
-}
orderSummaryTable :: Text
orderSummaryTable = qualifyTable jitsureiProjectionSchema "jitsurei_order_summary"

newtype OrderSummaryQuery = OrderSummaryQuery OrderId
    deriving stock (Generic, Eq, Show)

data OrderSummary = OrderSummary
    { orderId :: !OrderId
    , sku :: !Sku
    , quantity :: !Quantity
    , status :: !Text
    , lastSeen :: !GlobalPosition
    }
    deriving stock (Generic, Eq, Show)

orderSummaryReadModel :: ReadModel OrderSummaryQuery (Maybe OrderSummary)
orderSummaryReadModel =
    ReadModel
        { name = "jitsurei-order-summary"
        , tableName = "jitsurei_order_summary"
        , schema = jitsureiProjectionSchema
        , subscriptionName = "jitsurei-order-summary-inline"
        , version = 1
        , shapeHash = "jitsurei-order-summary-v1"
        , defaultConsistency = Eventual
        , query = \(OrderSummaryQuery orderId) ->
            Tx.statement (orderIdText orderId) selectOrderSummaryStmt
        }

orderSummaryInlineProjection :: InlineProjection OrderEvent
orderSummaryInlineProjection =
    InlineProjection
        { name = "jitsurei-order-summary-inline"
        , apply = applyOrderEvent
        }

applyOrderEvent :: OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderEvent event recorded =
    case event of
        OrderPlaced payload ->
            Tx.statement
                ( orderIdText payload.orderId
                , skuText payload.sku
                , Prelude.fromIntegral (quantityInt payload.quantity)
                , "placed"
                , globalPositionToInt (recorded ^. #globalPosition)
                )
                upsertOrderSummaryStmt
        PaymentApproved payload ->
            updateStatus payload.orderId "paid" recorded
        OrderPacked payload ->
            updateStatus payload.orderId "packed" recorded
        OrderShipped payload ->
            updateStatus payload.orderId "shipped" recorded
        OrderCancelled payload ->
            updateStatus payload.orderId "cancelled" recorded

updateStatus :: OrderId -> Text -> RecordedEvent -> Tx.Transaction ()
updateStatus orderId status recorded =
    Tx.statement
        ( orderIdText orderId
        , status
        , globalPositionToInt (recorded ^. #globalPosition)
        )
        updateOrderSummaryStatusStmt

{- | Create the application projection schema (opt-in, app-owned) and the
order-summary read-model table, fully qualified into that schema. 'Tx.sql' runs
a multi-statement, parameter-free script, so the @CREATE SCHEMA@ and
@CREATE TABLE@ share one call. Both are idempotent (@IF NOT EXISTS@).
-}
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
