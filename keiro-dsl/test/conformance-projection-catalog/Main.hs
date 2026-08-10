module Main (main) where

import Control.Monad (unless)
import Generated.CatalogDemo.CatalogAudit.ReadModelHarness qualified as CatalogAudit
import Generated.CatalogDemo.OrderInline.ReadModelHarness qualified as OrderInline
import Generated.CatalogDemo.Orders.Harness qualified as Orders
import Generated.CatalogDemo.ProjectionCatalog
  ( orderSummaryWriterInlineProjections
  , projectionCatalogAsyncRegistrations
  , projectionCatalogInventory
  , projectionCatalogRegistrations
  , reportingRebuildGroupId
  , shipmentWriterInlineProjections
  , shippingRebuildGroupId
  )
import Generated.CatalogDemo.ShipmentLookup.ReadModelHarness qualified as ShipmentLookup
import Generated.CatalogDemo.Shipments.Harness qualified as Shipments
import Generated.CatalogDemo.StructuralConformance (structuralConformanceAssertions)
import Keiro.Projection.Catalog qualified as Catalog

main :: IO ()
main = do
  readModelFactsPassed <- and <$> sequence [CatalogAudit.runReadModelFacts, OrderInline.runReadModelFacts, ShipmentLookup.runReadModelFacts]
  assert "generated read-model facts" readModelFactsPassed
  mapM_ (uncurry assert) Orders.harnessAssertions
  mapM_ (uncurry assert) Shipments.harnessAssertions
  mapM_ (uncurry assert) structuralConformanceAssertions
  let targets = Catalog.inventoryTargets projectionCatalogInventory
      groups = Catalog.inventoryGroups projectionCatalogInventory
  assert "four physical targets" (length targets == 4)
  assert
    "mixed clear/preserve reset policy"
    ( length (filter ((== Catalog.ClearBeforeReplay) . inventoryResetPolicy) targets) == 2
        && length (filter ((== Catalog.PreserveAndReconcile) . inventoryResetPolicy) targets) == 2
    )
  assert "one target dependency" (length (filter (not . null . inventoryDependsOn) targets) == 1)
  assert "two atomic ordered groups" (map (length . inventoryOrderedTargets) groups == [3, 1])
  assert "three generated owners" (length (Catalog.inventoryProjections projectionCatalogInventory) == 3)
  assert "two typed aggregate handlers" (length orderSummaryWriterInlineProjections == 1 && length shipmentWriterInlineProjections == 1)
  assert "three query registrations" (length projectionCatalogRegistrations == 3)
  assert "one async registration" (length projectionCatalogAsyncRegistrations == 1)
  assert "catalog-scoped rebuild group" (Catalog.rebuildGroupIdText reportingRebuildGroupId == "reporting")
  assert "disjoint catalog rebuild group" (Catalog.rebuildGroupIdText shippingRebuildGroupId == "shipping")
  putStrLn "projection catalog conformance: PASS"

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("projection catalog conformance failed: " <> label))

inventoryResetPolicy :: Catalog.InventoryTarget -> Catalog.TargetResetPolicy
inventoryResetPolicy Catalog.InventoryTarget {resetPolicy = policy} = policy

inventoryDependsOn :: Catalog.InventoryTarget -> [Catalog.TargetId]
inventoryDependsOn Catalog.InventoryTarget {dependsOn = dependencies} = dependencies

inventoryOrderedTargets :: Catalog.InventoryGroup -> [Catalog.TargetId]
inventoryOrderedTargets Catalog.InventoryGroup {orderedTargets = targets} = targets
