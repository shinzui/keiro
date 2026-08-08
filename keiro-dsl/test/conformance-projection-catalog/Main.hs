module Main (main) where

import Control.Monad (unless)
import Generated.CatalogDemo.CatalogAudit.ReadModelHarness (runReadModelFacts)
import Generated.CatalogDemo.Orders.Harness (harnessAssertions)
import Generated.CatalogDemo.ProjectionCatalog
  ( orderSummaryWriterInlineProjections
  , projectionCatalogAsyncRegistrations
  , projectionCatalogInventory
  , projectionCatalogRegistrations
  , reportingRebuildGroupId
  )
import Keiro.Projection.Catalog qualified as Catalog

main :: IO ()
main = do
  readModelFactsPassed <- runReadModelFacts
  assert "generated read-model facts" readModelFactsPassed
  mapM_ (uncurry assert) harnessAssertions
  assert "three physical targets" (length (Catalog.inventoryTargets projectionCatalogInventory) == 3)
  assert "two generated owners" (length (Catalog.inventoryProjections projectionCatalogInventory) == 2)
  assert "one typed inline handler" (length orderSummaryWriterInlineProjections == 1)
  assert "one query registration" (length projectionCatalogRegistrations == 1)
  assert "one async registration" (length projectionCatalogAsyncRegistrations == 1)
  assert "catalog-scoped rebuild group" (Catalog.rebuildGroupIdText reportingRebuildGroupId == "reporting")
  putStrLn "projection catalog conformance: PASS"

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("projection catalog conformance failed: " <> label))
