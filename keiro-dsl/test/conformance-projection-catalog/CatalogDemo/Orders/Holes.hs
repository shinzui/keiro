{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}
-- This is a HAND-OWNED version-2 hook module. keiro-dsl creates it once
-- and never overwrites it. Generated code owns every transition envelope
-- and every declared guard/write. This module supplies explicit event-field
-- mappings and explicitly selected Hole behavior only; fields(Command)
-- identity mappings are generated directly and have no hook.
module CatalogDemo.Orders.Holes
  ( applyOrderInline
  ) where

import Generated.CatalogDemo.Orders.Domain
import Generated.CatalogDemo.OrderInline.ReadModelTable (orderInlineQualifiedTable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent)

-- HOLE: the read-model SQL for the projection (a DB-coupled hole; the
-- pure event->status mapping is generated as orderInlineStatusFor).
-- Table: ""."". Use orderInlineQualifiedTable; never rely on search_path.
-- Declared columns:
--   order_id text NOT NULL
applyOrderInline :: OrdersEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderInline _event _recorded = orderInlineQualifiedTable `seq` pure ()
