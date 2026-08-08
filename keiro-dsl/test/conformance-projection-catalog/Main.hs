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
  let targets = Catalog.inventoryTargets projectionCatalogInventory
      groups = Catalog.inventoryGroups projectionCatalogInventory
  assert "three physical targets" (length targets == 3)
  assert
    "mixed clear/preserve reset policy"
    ( length (filter ((== Catalog.ClearBeforeReplay) . inventoryResetPolicy) targets) == 2
        && length (filter ((== Catalog.PreserveAndReconcile) . inventoryResetPolicy) targets) == 1
    )
  assert "one target dependency" (length (filter (not . null . inventoryDependsOn) targets) == 1)
  assert "one atomic ordered group" (map (length . inventoryOrderedTargets) groups == [3])
  assert "two generated owners" (length (Catalog.inventoryProjections projectionCatalogInventory) == 2)
  assert "one typed inline handler" (length orderSummaryWriterInlineProjections == 1)
  assert "one query registration" (length projectionCatalogRegistrations == 1)
  assert "one async registration" (length projectionCatalogAsyncRegistrations == 1)
  assert "catalog-scoped rebuild group" (Catalog.rebuildGroupIdText reportingRebuildGroupId == "reporting")
  putStrLn "projection catalog conformance: PASS"

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("projection catalog conformance failed: " <> label))

inventoryResetPolicy :: Catalog.InventoryTarget -> Catalog.TargetResetPolicy
inventoryResetPolicy Catalog.InventoryTarget {resetPolicy = policy} = policy

inventoryDependsOn :: Catalog.InventoryTarget -> [Catalog.TargetId]
inventoryDependsOn Catalog.InventoryTarget {dependsOn = dependencies} = dependencies

inventoryOrderedTargets :: Catalog.InventoryGroup -> [Catalog.TargetId]
inventoryOrderedTargets Catalog.InventoryGroup {orderedTargets = targets} = targets
