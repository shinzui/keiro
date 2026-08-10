-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module CatalogDemo.OrderInline.ReadModelHoles
  ( orderInlineQuery
  ) where

import CatalogDemo.MappedDomain (QualificationResult (..))
import Generated.CatalogDemo.OrderInline.QueryContract (OrderInlineQueryInput, OrderInlineQueryResult)
import Generated.CatalogDemo.OrderInline.ReadModelTable (orderInlineQualifiedTable)
import Hasql.Transaction qualified as Tx

-- HOLE: query "sales"."order_summary" via orderInlineQualifiedTable; never rely on search_path.
-- Declared columns:
--   order_id text NOT NULL
orderInlineQuery :: OrderInlineQueryInput -> Tx.Transaction OrderInlineQueryResult
orderInlineQuery _input = orderInlineQualifiedTable `seq` pure (Just (QualificationResult "qualified"))
