-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module CatalogDemo.CatalogAudit.ReadModelHoles
  ( CatalogAuditQueryInput
  , CatalogAuditQueryResult
  , catalogAuditQuery
  ) where

import Generated.CatalogDemo.CatalogAudit.ReadModelTable (catalogAuditQualifiedTable)
import Hasql.Transaction qualified as Tx

-- HOLE: replace these aliases with the real query input and result types.
type CatalogAuditQueryInput = ()
type CatalogAuditQueryResult = ()

-- HOLE: query "sales"."audit_log" via catalogAuditQualifiedTable; never rely on search_path.
-- Declared columns:
--   event_id text NOT NULL
catalogAuditQuery :: CatalogAuditQueryInput -> Tx.Transaction CatalogAuditQueryResult
catalogAuditQuery _input = catalogAuditQualifiedTable `seq` error "HOLE: fill catalogAudit query"
