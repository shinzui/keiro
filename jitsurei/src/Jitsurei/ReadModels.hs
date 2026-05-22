module Jitsurei.ReadModels
  ( OrderSummaryQuery (..)
  , OrderSummary (..)
  , orderSummaryReadModel
  , orderSummaryInlineProjection
  , initializeOrderSummaryTable
  , selectOrderSummaryStmt
  )
where

import Contravariant.Extras (contrazip3, contrazip5)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..))
import Keiro.Prelude
import Kiroku.Store.Types (GlobalPosition (..), RecordedEvent)
import Prelude qualified
import Jitsurei.Domain

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
orderSummaryReadModel = ReadModel
  { name = "jitsurei-order-summary"
  , tableName = "jitsurei_order_summary"
  , subscriptionName = "jitsurei-order-summary-inline"
  , version = 1
  , shapeHash = "jitsurei-order-summary-v1"
  , defaultConsistency = Strong
  , query = \(OrderSummaryQuery orderId) ->
      Tx.statement (orderIdText orderId) selectOrderSummaryStmt
  }

orderSummaryInlineProjection :: InlineProjection OrderEvent
orderSummaryInlineProjection = InlineProjection
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

initializeOrderSummaryTable :: Tx.Transaction ()
initializeOrderSummaryTable =
  Tx.sql
    """
    CREATE TABLE IF NOT EXISTS jitsurei_order_summary (
      order_id TEXT PRIMARY KEY,
      sku TEXT NOT NULL,
      quantity BIGINT NOT NULL,
      status TEXT NOT NULL,
      last_seen BIGINT NOT NULL
    )
    """

upsertOrderSummaryStmt :: Statement (Text, Text, Int64, Text, Int64) ()
upsertOrderSummaryStmt =
  preparable
    """
    INSERT INTO jitsurei_order_summary (order_id, sku, quantity, status, last_seen)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (order_id) DO UPDATE
      SET sku = EXCLUDED.sku,
          quantity = EXCLUDED.quantity,
          status = EXCLUDED.status,
          last_seen = EXCLUDED.last_seen
    """
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
    """
    UPDATE jitsurei_order_summary
    SET status = $2,
        last_seen = $3
    WHERE order_id = $1
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

selectOrderSummaryStmt :: Statement Text (Maybe OrderSummary)
selectOrderSummaryStmt =
  preparable
    """
    SELECT order_id, sku, quantity, status, last_seen
    FROM jitsurei_order_summary
    WHERE order_id = $1
    """
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
