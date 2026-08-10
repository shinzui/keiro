-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module CatalogDemo.OrderInline.ReadModelHoles
  ( OrderInlineQueryInput
  , OrderInlineQueryResult
  , orderInlineQuery
  ) where

import Generated.CatalogDemo.OrderInline.ReadModelTable (orderInlineQualifiedTable)
import Hasql.Transaction qualified as Tx

-- HOLE: replace these aliases with the real query input and result types.
type OrderInlineQueryInput = ()
type OrderInlineQueryResult = ()

-- HOLE: query "sales"."order_summary" via orderInlineQualifiedTable; never rely on search_path.
-- Declared columns:
--   order_id text NOT NULL
orderInlineQuery :: OrderInlineQueryInput -> Tx.Transaction OrderInlineQueryResult
orderInlineQuery _input = orderInlineQualifiedTable `seq` pure ()
