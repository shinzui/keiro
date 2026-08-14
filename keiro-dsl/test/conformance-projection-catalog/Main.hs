module Main (main) where

import CatalogDemo.MappedDomain (QualificationPayload (..), QualificationResult (..), QueryCriteria (..), QueueMetadata (..), SharedReference (..))
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Generated.CatalogDemo.CatalogAudit.ReadModelHarness qualified as CatalogAudit
import Generated.CatalogDemo.OrderInline.QueryContract (OrderInlineQueryInput, OrderInlineQueryResult)
import Generated.CatalogDemo.OrderInline.ReadModelHarness qualified as OrderInline
import Generated.CatalogDemo.OrderTotalsLookup.ReadModelHarness qualified as OrderTotalsLookup
import Generated.CatalogDemo.Orders.Harness qualified as Orders
import Generated.CatalogDemo.ProjectionCatalog
  ( orderSummaryWriterInlineProjections
  , ordersInlineProjections
  , projectionCatalogAsyncRegistrations
  , projectionCatalogInventory
  , projectionCatalogQuerySupplies
  , projectionCatalogRegistrations
  , reportingRebuildGroupId
  , shipmentWriterInlineProjections
  , shipmentsInlineProjections
  , shippingRebuildGroupId
  )
import Generated.CatalogDemo.ShipmentLookup.ReadModelHarness qualified as ShipmentLookup
import Generated.CatalogDemo.Shipments.Harness qualified as Shipments
import Generated.CatalogDemo.QualificationJobs.Queue
import Generated.CatalogDemo.QualificationJobs.QueueCodec (qualificationJobsJobCodec)
import Generated.CatalogDemo.StructuralConformance (structuralConformanceAssertions)
import Keiro.PGMQ.Codec (JobCodec (..))
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (FromCurrentHead))

main :: IO ()
main = do
  readModelFactsPassed <- and <$> sequence [CatalogAudit.runReadModelFacts, OrderInline.runReadModelFacts, OrderTotalsLookup.runReadModelFacts, ShipmentLookup.runReadModelFacts]
  assert "generated read-model facts" readModelFactsPassed
  let perturbed = map perturbSubscriptionName projectionCatalogAsyncRegistrations
      mutated = CatalogAudit.catalogFactsAgainst projectionCatalogRegistrations perturbed projectionCatalogQuerySupplies
  assert
    "perturbed async registration identity is detected"
    (any (\(fact, expected, actual) -> fact == "asyncRegistration:audit_writer" && expected /= actual) mutated)
  let mutatedReadModelFacts factName =
        [ if fact == factName then (fact, expected, actual <> "-WRONG") else row
        | row@(fact, expected, actual) <- CatalogAudit.readModelFacts
        ]
      mutationFails factName =
        any (\(fact, expected, actual) -> fact == factName && expected /= actual) (mutatedReadModelFacts factName)
  assert "freshness fact mutation is detected" (mutationFails "freshness")
  assert "cursor fact mutation is detected" (mutationFails "cursorAuthority")
  assert "delivery fact mutation is detected" (mutationFails "projectionDelivery")
  mapM_ (uncurry assert) Orders.harnessAssertions
  mapM_ (uncurry assert) Shipments.harnessAssertions
  mapM_ (uncurry assert) structuralConformanceAssertions
  let queryInput :: OrderInlineQueryInput
      queryInput = QueryCriteria "qualification-query"
      queryResult :: OrderInlineQueryResult
      queryResult = Just (QualificationResult "qualified-result")
  assert "non-unit typed query contract" (queryCriteriaText queryInput == "qualification-query" && queryResult == Just (QualificationResult "qualified-result"))
  exerciseQualificationQueue
  let targets = Catalog.inventoryTargets projectionCatalogInventory
      groups = Catalog.inventoryGroups projectionCatalogInventory
      sourceFingerprints = map inventoryCodecFingerprint (Catalog.inventorySources projectionCatalogInventory)
  assert "four physical targets" (length targets == 4)
  assert
    "mixed clear/preserve reset policy"
    ( length (filter ((== Catalog.ClearBeforeReplay) . inventoryResetPolicy) targets) == 2
        && length (filter ((== Catalog.PreserveAndReconcile) . inventoryResetPolicy) targets) == 2
    )
  assert "one target dependency" (length (filter (not . null . inventoryDependsOn) targets) == 1)
  assert "two atomic ordered groups" (map (length . inventoryOrderedTargets) groups == [3, 1])
  assert
    "projection source fingerprints"
    ( sourceFingerprints
        == [ "aggregate:Orders/generated-codec/v1/mapped-132056a8f2ee095d",
             "aggregate:Shipments/generated-codec/v1/mapped-9456a95e380c74b5",
             "category:audit/application-decoder/v1"
           ]
    )
  assert "three generated owners" (length (Catalog.inventoryProjections projectionCatalogInventory) == 3)
  assert
    "v1/v2 projection revision bridge"
    ( map (Catalog.projectionRevisionIdText . inventoryRevisionId) (Catalog.inventoryProjectionRevisions projectionCatalogInventory)
        == ["reporting_v1", "reporting_v2"]
    )
  assert "two typed aggregate handlers" (length orderSummaryWriterInlineProjections == 1 && length shipmentWriterInlineProjections == 1)
  assert "source-selected inline handlers stay singular" (length ordersInlineProjections == 1 && length shipmentsInlineProjections == 1)
  assert "four query registrations" (length projectionCatalogRegistrations == 4)
  assert
    "one owner supplies both order queries"
    ( map (Catalog.projectionIdText . Catalog.resolvedProjectionId) projectionCatalogQuerySupplies
        == ["audit_writer", "order_summary_writer", "order_summary_writer", "shipment_writer"]
    )
  assert "one async registration" (length projectionCatalogAsyncRegistrations == 1)
  assert "generated missing-checkpoint policy" (map inventoryCheckpointPolicy (Catalog.inventorySubscriptions projectionCatalogInventory) == [FromCurrentHead])
  assert "catalog-scoped rebuild group" (Catalog.rebuildGroupIdText reportingRebuildGroupId == "reporting")
  assert "disjoint catalog rebuild group" (Catalog.rebuildGroupIdText shippingRebuildGroupId == "shipping")
  putStrLn "projection catalog conformance: PASS"

perturbSubscriptionName :: Catalog.AsyncProjectionRegistration -> Catalog.AsyncProjectionRegistration
perturbSubscriptionName (Catalog.AsyncProjectionRegistration projectionId projectionName subscriptionId _ checkpointOnMissing dedupKeyId dedupName) =
  Catalog.AsyncProjectionRegistration projectionId projectionName subscriptionId "catalog-demo-audit-WRONG" checkpointOnMissing dedupKeyId dedupName

inventoryRevisionId :: Catalog.InventoryProjectionRevision -> Catalog.ProjectionRevisionId
inventoryRevisionId (Catalog.InventoryProjectionRevision revisionId _ _ _ _ _ _) = revisionId

exerciseQualificationQueue :: IO ()
exerciseQualificationQueue = do
  let payload =
        QualificationJob
          (SharedReference "shared-queue")
          (QualificationPayload "qualification-7" Nothing)
          (QueueMetadata "metadata-7")
          Nothing
          2
          (object ["trace_id" .= ("trace-7" :: Text)])
      encoded = encodeQualificationJob payload
      expected =
        object
          [ "shared_reference" .= SharedReference "shared-queue",
            "payload"
              .= object
                [ "qualification_id" .= ("qualification-7" :: Text),
                  "note" .= Null
                ],
            "metadata" .= QueueMetadata "metadata-7",
            "maybe_metadata" .= Null,
            "attempt" .= (2 :: Int),
            "trace" .= object ["trace_id" .= ("trace-7" :: Text)]
          ]
      envelope =
        object
          [ "v" .= (1 :: Int),
            "t" .= ("QualificationJob" :: Text),
            "data" .= expected
          ]
      missingRequired = case encoded of
        Object fields -> parseQualificationJob (Object (KeyMap.delete "payload" fields))
        _ -> error "qualification queue encoder did not produce an object"
      checks =
        [ ("qualification queue exact payload", encoded == expected),
          ("qualification queue structural and opaque round-trip", parseQualificationJob encoded == Right payload),
          ("qualification queue required key rejects omission", isLeft missingRequired),
          ("qualification queue present null admits Optional", (maybeMetadata <$> parseQualificationJob encoded) == Right Nothing),
          ("qualification queue schema-v1 envelope", encodeJob qualificationJobsJobCodec payload == envelope && decodeJob qualificationJobsJobCodec envelope == Right payload),
          ("qualification queue physical identity", queuePhysical == "catalog_demo_qualification_jobs")
        ]
  forM_ checks (uncurry assert)

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("projection catalog conformance failed: " <> label))

isLeft :: Either problem value -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

inventoryResetPolicy :: Catalog.InventoryTarget -> Catalog.TargetResetPolicy
inventoryResetPolicy Catalog.InventoryTarget {resetPolicy = policy} = policy

inventoryDependsOn :: Catalog.InventoryTarget -> [Catalog.TargetId]
inventoryDependsOn Catalog.InventoryTarget {dependsOn = dependencies} = dependencies

inventoryOrderedTargets :: Catalog.InventoryGroup -> [Catalog.TargetId]
inventoryOrderedTargets Catalog.InventoryGroup {orderedTargets = targets} = targets

inventoryCodecFingerprint :: Catalog.InventorySource -> Text
inventoryCodecFingerprint (Catalog.InventorySource _ _ fingerprint) = fingerprint

inventoryCheckpointPolicy :: Catalog.InventorySubscription -> MissingCheckpointPolicy
inventoryCheckpointPolicy (Catalog.InventorySubscription _ _ _ policy) = policy
