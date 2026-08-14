module Main
  ( main,
  )
where

import Control.Lens ((^.))
import Data.Aeson (object)
import Data.Aeson qualified as Aeson
import Data.Int (Int32, Int64)
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), addUTCTime, secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID (UUID, fromString)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Effectful.Reader.Static (Reader)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Jitsurei
import Keiro
import Keiro.Connection (withProjectionSchema)
import Keiro.PGMQ.Job (Job (..))
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), runJobEff, withJobRuntime)
import Keiro.ProcessManager
import Keiro.Projection
import Keiro.Projection.Catalog.Operations qualified as CatalogOperations
import Keiro.ReadModel
import Keiro.ReadModel.Rebuild
import Keiro.ReplayAudit
import Keiro.Test.Postgres (Fixture, StoreRunner (..), withFreshDatabase, withFreshResourceStore, withFreshResourceStoreWith, withMigratedSuiteWith)
import Keiro.Timer
import Kiroku.Store qualified as Store
import Kiroku.Store.Types
  ( EventId (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
  )
import Pgmq.Effectful (Pgmq, PgmqRuntimeError)
import Pgmq.Effectful qualified as Pgmq
import Pgmq.Migration qualified as PgmqMigration
import Pgmq.Types (QueueName)
import Shibuya.Adapter.Pgmq (PgmqAdapterEnv)
import Shibuya.Telemetry.Effect (Tracing)
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- | The effect stack 'runJobEff' interprets for the shipment-notice queue.
type QueueStack = '[Reader PgmqAdapterEnv, Pgmq, Tracing, Error PgmqRuntimeError, IOE]

-- | The work-queue examples need PGMQ's schema, so its native pg-migrate
-- component joins the framework plan applied to the suite's template database —
-- one ledger over kiroku, keiro, and pgmq.
withJitsureiSuite :: (Fixture -> IO a) -> IO a
withJitsureiSuite action = do
  pgmq <- either (fail . show) pure PgmqMigration.pgmqMigrations
  withMigratedSuiteWith [pgmq] action

main :: IO ()
main = withJitsureiSuite $ \fixture -> hspec $ do
  describe "Jitsurei codec evolution" $ do
    it "upcasts a v1 OrderPlaced payload into the current event shape" $
      decodeRaw
        orderCodec
        (EventType "OrderPlaced")
        1
        ( object
            [ "orderId" Aeson..= ("order-100" :: Text),
              "qty" Aeson..= (3 :: Int)
            ]
        )
        `shouldBe` Right
          ( OrderPlaced
              OrderPlacedData
                { orderId = sampleOrderId,
                  sku = Sku "UNKNOWN",
                  quantity = Quantity 3
                }
          )

  describe "Jitsurei command cycle" $ around (withFreshResourceStore fixture) $ do
    it "places and pays for an order in stream order" $ \(_store, StoreRunner runner) -> do
      let target = orderStream sampleOrderId
      Right (Right placed) <-
        runner $
          runCommand defaultRunCommandOptions orderEventStream target samplePlaceOrder
      placed ^. #streamVersion `shouldBe` StreamVersion 1
      Right (Right paid) <-
        runner $
          runCommand defaultRunCommandOptions orderEventStream target sampleApprovePayment
      paid ^. #streamVersion `shouldBe` StreamVersion 2
      Right recorded <-
        runner $
          Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10
      traverse (decodeRecorded orderCodec) (Vector.toList recorded)
        `shouldBe` Right
          [ OrderPlaced
              OrderPlacedData
                { orderId = sampleOrderId,
                  sku = sampleSku,
                  quantity = sampleQuantity
                },
            PaymentApproved
              PaymentApprovedData
                { orderId = sampleOrderId,
                  paymentRef = samplePaymentRef
                }
          ]

    it "rejects shipping an unpaid order as a domain outcome" $ \(_store, StoreRunner runner) -> do
      result <-
        runner $
          runCommand
            defaultRunCommandOptions
            orderEventStream
            (orderStream (OrderId "order-unpaid"))
            ( ShipOrder
                ShipOrderData
                  { orderId = OrderId "order-unpaid",
                    carrier = Carrier "UPS",
                    trackingId = TrackingId "TRACK-1"
                  }
            )
      result `shouldBe` Right (Left CommandRejected)

  describe "Jitsurei replay audit" $ around (withFreshResourceStore fixture) $ do
    it "skips unaffected targets and full-replays Order plus the escalation saga" $ \(_store, StoreRunner runner) -> do
      let orderId = OrderId "audit-order"
          incidentId = IncidentId "audit-incident"
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            orderEventStream
            (orderStream orderId)
            ( PlaceOrder
                PlaceOrderData
                  { orderId,
                    sku = sampleSku,
                    quantity = sampleQuantity
                  }
            )
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            escalationEventStream
            (escalationStream incidentId)
            (NoteRaised NoteRaisedData {incidentId})
      Right targetedReports <-
        runner $
          auditTargets
            ( AuditTargeted
                AffectedSet
                  { affectedEventTypes = Set.singleton (EventType "OrderPlaced"),
                    includeSnapshotStreams = False
                  }
            )
            defaultAuditBudget
            replayAuditTargets
      mapM_ (TIO.putStrLn . renderAuditReport) targetedReports
      map targetCategory targetedReports `shouldBe` ["order", "esc"]
      map streamsSelected targetedReports `shouldBe` [1, 0]
      map streamsSkipped targetedReports `shouldBe` [0, 1]
      auditExitCode targetedReports `shouldBe` 0

      Right fullReports <-
        runner $
          auditTargets
            AuditFull
            defaultAuditBudget
            replayAuditTargets
      mapM_ (TIO.putStrLn . renderAuditReport) fullReports
      map targetCategory fullReports `shouldBe` ["order", "esc"]
      map streamsSelected fullReports `shouldBe` [1, 1]
      auditExitCode fullReports `shouldBe` 0

  describe "Jitsurei read model" $ around (withFreshResourceStoreWith fixture (withProjectionSchema jitsureiProjectionSchema)) $ do
    it "updates and queries the inline order summary in the append transaction" $ \(_store, StoreRunner runner) -> do
      Right () <- runner initializeJitsureiTables
      Right (Right (ProjectionCommandApplied _)) <-
        runner $
          runCommandWithCatalogProjections
            defaultRunCommandOptions
            orderEventStream
            (orderStream sampleOrderId)
            samplePlaceOrder
            jitsureiProjectionCatalog
            orderProjectionSet
      Right summaryResult <-
        runner $
          runQuery Nothing orderSummaryReadModel (OrderSummaryQuery sampleOrderId)
      case summaryResult of
        Right (Just summary) -> do
          summary ^. #orderId `shouldBe` sampleOrderId
          summary ^. #sku `shouldBe` sampleSku
          summary ^. #quantity `shouldBe` sampleQuantity
          summary ^. #status `shouldBe` "placed"
        other -> expectationFailure ("expected live order summary, got " <> show other)

    it "returns all domain decisions while projecting only accepted events" $ \(_store, StoreRunner runner) -> do
      Right () <- runner initializeJitsureiTables
      let acceptedId = OrderId "domain-accepted"
          rejectedId = OrderId "domain-rejected"
          noOpId = OrderId "domain-no-op"
          place orderId =
            PlaceOrder
              PlaceOrderData
                { orderId,
                  sku = sampleSku,
                  quantity = sampleQuantity
                }
          approve orderId =
            ApprovePayment
              ApprovePaymentData
                { orderId,
                  paymentRef = samplePaymentRef
                }
          cancel orderId =
            CancelOrder
              CancelOrderData
                { orderId,
                  reason = "customer request"
                }
          runTyped orderId command =
            runner $
              runDomainCommandWithProjections
                defaultRunCommandOptions
                orderDomainCommandHandler
                (orderStream orderId)
                command
                orderLiveProjections
          readLiveEffectCount = do
            Right (_, _, _, count) <- runner $ Store.runTransaction (Tx.statement () orderCatalogFactsStmt)
            pure count

      Right (Right accepted) <- runTyped acceptedId (place acceptedId)
      case accepted ^. #decision of
        DomainAccepted events -> do
          NonEmpty.toList events
            `shouldBe` [ OrderPlaced
                           OrderPlacedData
                             { orderId = acceptedId,
                               sku = sampleSku,
                               quantity = sampleQuantity
                             }
                       ]
          renderOrderDecision (accepted ^. #decision) `shouldBe` "accepted 1 event(s)"
        other -> expectationFailure ("expected accepted order decision, got " <> show other)
      readLiveEffectCount `shouldReturn` 1

      Right (Right _) <- runTyped rejectedId (place rejectedId)
      Right (Right _) <- runTyped rejectedId (approve rejectedId)
      beforeRejected <- readLiveEffectCount
      Right (Right rejected) <- runTyped rejectedId (cancel rejectedId)
      case rejected ^. #decision of
        DomainRejected PaymentAlreadyApproved ->
          renderOrderDecision (rejected ^. #decision) `shouldBe` "rejected: payment already approved"
        other -> expectationFailure ("expected rejected order decision, got " <> show other)
      readLiveEffectCount `shouldReturn` beforeRejected

      Right (Right _) <- runTyped noOpId (place noOpId)
      Right (Right _) <- runTyped noOpId (cancel noOpId)
      beforeNoOp <- readLiveEffectCount
      Right (Right noOp) <- runTyped noOpId (cancel noOpId)
      case noOp ^. #decision of
        DomainNoOp AlreadyCancelled ->
          renderOrderDecision (noOp ^. #decision) `shouldBe` "no-op: order already cancelled"
        other -> expectationFailure ("expected no-op order decision, got " <> show other)
      readLiveEffectCount `shouldReturn` beforeNoOp

    it "drives live, async, preview, and mixed-policy rebuild paths from one catalog" $ \(_store, StoreRunner runner) -> do
      Right () <- runner initializeJitsureiTables
      length (inventoryProjectionRevisions (catalogInventory jitsureiProjectionCatalog))
        `shouldBe` 2
      let previewResult = CatalogOperations.previewGroupRebuild orderCatalogOperations orderReportingGroupId
      previewReport <- case previewResult of
        Left err -> expectationFailure ("catalog preview failed: " <> show err) >> error "unreachable"
        Right value -> pure value
      map (^. #resetPolicy) (previewReport ^. #targets)
        `shouldBe` [PreserveAndReconcile, ClearBeforeReplay, ClearBeforeReplay]
      previewReport ^. #destructive `shouldBe` True

      Right (Right (ProjectionCommandApplied _)) <-
        runner $
          runCommandWithCatalogProjections
            defaultRunCommandOptions
            orderEventStream
            (orderStream sampleOrderId)
            samplePlaceOrder
            jitsureiProjectionCatalog
            orderProjectionSet
      Right recorded <-
        runner $
          Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10
      let placed = Vector.head recorded
      Right beforeAsync <- runner $ Store.runTransaction (Tx.statement () orderCatalogFactsStmt)
      beforeAsync `shouldBe` (1, 1, 0, 1)
      Right CatalogAsyncApplied <-
        runner $
          Store.runTransaction
            (applyAsyncProjectionFromCatalog jitsureiProjectionCatalog orderAuditProjectionId orderAuditAsyncProjection placed)
      Right (Right _) <-
        runner $
          Store.initializeSubscriptionCheckpoint
            (Store.SubscriptionName "jitsurei-order-audit-subscription")
            0
            Store.FromBeginning
      Right () <- runner $ Store.runTransaction seedBrownfieldRoot
      Right beforeFacts <- runner $ Store.runTransaction (Tx.statement () orderCatalogFactsStmt)
      beforeFacts `shouldBe` (2, 1, 1, 1)

      let runId = parseRebuildRunId "jitsurei-order-rebuild"
          rebuildOptions =
            defaultRebuildOptions
              RebuildRequest
                { rebuildRunId = runId,
                  requestedBy = "jitsurei-test",
                  requestReason = "catalog adoption proof",
                  replayFrom = GlobalPosition 0
                }
      firstAttempt <-
        runner $
          CatalogOperations.startGroupRebuild
            orderCatalogOperations
            orderReportingGroupId
            rebuildOptions
      firstAttempt `shouldSatisfy` \case
        Right (Left (CatalogOperations.CatalogOpsRebuildError CatalogRebuildVerificationFailed {})) -> True
        _ -> False
      Right (Right failed) <-
        runner $ CatalogOperations.inspectGroupRebuild orderCatalogOperations runId
      failed ^. #run . #runStatus `shouldBe` RebuildRunFailed

      let fencedOrderId = OrderId "order-fenced-during-repair"
      Right (Right fenced) <-
        runner $
          runCommandWithCatalogProjections
            defaultRunCommandOptions
            orderEventStream
            (orderStream fencedOrderId)
            ( PlaceOrder
                PlaceOrderData
                  { orderId = fencedOrderId,
                    sku = sampleSku,
                    quantity = sampleQuantity
                  }
            )
            jitsureiProjectionCatalog
            orderProjectionSet
      fenced `shouldBe` ProjectionCommandFenced orderReportingGroupId runId
      Right fencedEvents <-
        runner $
          Store.readStreamForward (StreamName "order-order-fenced-during-repair") (StreamVersion 0) 10
      Vector.null fencedEvents `shouldBe` True

      Right () <- runner $ Store.runTransaction repairBrownfieldRoot
      Right (Right rebuilt) <-
        runner $
          CatalogOperations.resumeGroupRebuild
            orderCatalogOperations
            runId
            rebuildOptions
      rebuilt ^. #run . #runStatus `shouldBe` RebuildRunPromoted
      placed ^. #globalPosition `shouldBe` GlobalPosition 0
      rebuilt ^. #run . #capturedHead `shouldBe` GlobalPosition 1
      Right afterFacts <- runner $ Store.runTransaction (Tx.statement () orderCatalogFactsStmt)
      afterFacts `shouldBe` (2, 1, 1, 1)

      Right brownfield <-
        runner $
          runQuery Nothing orderSummaryReadModel (OrderSummaryQuery (OrderId "brownfield-no-history"))
      brownfield `shouldSatisfy` \case
        Right (Just _) -> True
        _ -> False

      Right (Right (ProjectionCommandApplied _)) <-
        runner $
          runCommandWithCatalogProjections
            defaultRunCommandOptions
            orderEventStream
            (orderStream fencedOrderId)
            ( PlaceOrder
                PlaceOrderData
                  { orderId = fencedOrderId,
                    sku = sampleSku,
                    quantity = sampleQuantity
                  }
            )
            jitsureiProjectionCatalog
            orderProjectionSet
      pure ()

    it "revision delivery routing preserves inline and async ownership across an incompatible V1/V2 rebuild" $ \(store, StoreRunner runner) -> do
      Right () <- runner initializeJitsureiTables
      Right (Right _) <-
        runner $
          Store.initializeSubscriptionCheckpoint
            (Store.SubscriptionName "jitsurei-order-audit-subscription")
            0
            Store.FromBeginning
      Right (Right (ProjectionCommandApplied _)) <-
        runner $
          runCommandWithCatalogProjections
            defaultRunCommandOptions
            orderEventStream
            (orderStream (OrderId "versioned-before"))
            ( PlaceOrder
                PlaceOrderData
                  { orderId = OrderId "versioned-before",
                    sku = sampleSku,
                    quantity = sampleQuantity
                  }
            )
            jitsureiProjectionCatalog
            orderProjectionSet

      let runId = parseRebuildRunId "jitsurei-versioned-schema-change"
          options =
            CatalogOperations.CatalogVersionedStartOptions
              { rebuildRunId = runId,
                rebuildGroupId = orderReportingGroupId,
                servingRevisionId = orderReportingRevisionV1 ^. #revisionId,
                candidateRevisionId = orderReportingRevisionV2 ^. #revisionId,
                targetMode = ApplicationProvisioned,
                replayPageSize = 1,
                cutoverThreshold = 10,
                cutoverLockTimeoutMs = 2_000,
                promotionDedupLimit = 1_000_000,
                retentionDuration = secondsToDiffTime 600,
                requestedBy = "jitsurei-test",
                requestReason = "capture the schema-changing online rebuild transcript"
              }
      Right (Right started) <-
        runner $ CatalogOperations.startVersionedGroupRebuild orderCatalogOperations options
      started ^. #run . #phase `shouldBe` VersionedReplayRunning
      externalStarted <-
        externalProjectionStatus store (rebuildGroupIdText orderReportingGroupId)
      externalStarted
        `shouldSatisfy` \(phase, readable, servingRevision, epoch, activeRun, candidateRevision, candidatePosition, candidateHead) ->
          phase == "rebuilding-versioned"
            && readable
            && servingRevision == Just (projectionRevisionIdText (orderReportingRevisionV1 ^. #revisionId))
            && epoch == 0
            && activeRun == Just (rebuildRunIdText runId)
            && candidateRevision == Just (projectionRevisionIdText (orderReportingRevisionV2 ^. #revisionId))
            && isJust candidatePosition
            && isJust candidateHead
      Right candidateV1Rows <-
        runner $ Store.runTransaction (Tx.statement () orderSummaryExternalV1Stmt)
      candidateV1Rows
        `shouldSatisfy` any (\(orderId, _, _, status, _) -> orderId == "versioned-before" && status == "placed")

      Right (Right (ProjectionCommandApplied _)) <-
        runner $
          runCommandWithCatalogProjections
            defaultRunCommandOptions
            orderEventStream
            (orderStream (OrderId "versioned-during"))
            ( PlaceOrder
                PlaceOrderData
                  { orderId = OrderId "versioned-during",
                    sku = sampleSku,
                    quantity = sampleQuantity
                  }
            )
            jitsureiProjectionCatalog
            orderProjectionSet

      let drive 0 = expectationFailure "versioned Jitsurei rebuild did not promote" >> error "unreachable"
          drive remaining = do
            outcome <- runner $ CatalogOperations.resumeVersionedGroupRebuild orderCatalogOperations runId
            report <- case outcome of
              Right (Right value) -> pure value
              other -> expectationFailure ("versioned resume failed: " <> show other) >> error "unreachable"
            if report ^. #run . #phase == VersionedPromoted
              then pure report
              else drive (remaining - 1)
      promoted <- drive (20 :: Int)
      promoted ^. #run . #servingRevisionId
        `shouldBe` orderReportingRevisionV2 ^. #revisionId
      externalPromoted <-
        externalProjectionStatus store (rebuildGroupIdText orderReportingGroupId)
      externalPromoted
        `shouldSatisfy` \(phase, readable, servingRevision, epoch, activeRun, candidateRevision, candidatePosition, candidateHead) ->
          phase == "serving-versioned"
            && readable
            && servingRevision == Just (projectionRevisionIdText (orderReportingRevisionV2 ^. #revisionId))
            && epoch == 1
            && activeRun == Nothing
            && candidateRevision == Nothing
            && candidatePosition == Nothing
            && candidateHead == Nothing

      Right (Right (ProjectionCommandApplied _)) <-
        runner $
          runCommandWithCatalogProjections
            defaultRunCommandOptions
            orderEventStream
            (orderStream (OrderId "versioned-after"))
            ( PlaceOrder
                PlaceOrderData
                  { orderId = OrderId "versioned-after",
                    sku = sampleSku,
                    quantity = sampleQuantity
                  }
            )
            jitsureiProjectionCatalog
            orderProjectionSet

      Right facts <- runner $ Store.runTransaction (Tx.statement () orderVersionedFactsStmt)
      facts `shouldBe` (3, 3, 2, True)

      Right afterRecorded <-
        runner $
          Store.readStreamForward (StreamName "order-versioned-after") (StreamVersion 0) 10
      let afterPlaced = Vector.head afterRecorded
      Right CatalogAsyncApplied <-
        runner $
          Store.runTransaction
            (applyAsyncProjectionFromCatalog jitsureiProjectionCatalog orderAuditProjectionId orderAuditAsyncProjection afterPlaced)
      Right CatalogAsyncDuplicate <-
        runner $
          Store.runTransaction
            (applyAsyncProjectionFromCatalog jitsureiProjectionCatalog orderAuditProjectionId orderAuditAsyncProjection afterPlaced)
      Right finalFacts <- runner $ Store.runTransaction (Tx.statement () orderVersionedFactsStmt)
      finalFacts `shouldBe` (3, 3, 3, True)
      oldContract <- runner $ Store.runTransaction (Tx.statement () orderSummaryExternalV1Stmt)
      oldContract
        `shouldSatisfy` \case
          Left err -> "KR003" `List.isInfixOf` show err
          Right _ -> False
      Right currentV2Rows <-
        runner $ Store.runTransaction (Tx.statement () orderSummaryExternalV2Stmt)
      currentV2Rows
        `shouldSatisfy` any (\(orderId, _, _, state, _, revision) -> orderId == "versioned-after" && state == "placed" && revision == 2)

      Right beforeRepair <- runner $ Store.runTransaction (Tx.statement () orderTargetedRepairFactsStmt)
      Right () <- runner $ Store.runTransaction (Tx.statement () corruptOneOrderStmt)
      let repairRequest =
            StreamReprojectionRequest
              { rebuildGroupId = orderReportingGroupId,
                projectionId = orderSummaryProjectionId,
                streamName = StreamName "order-versioned-before",
                pageSize = 1
              }
      Right (Right repairPreview) <-
        runner $ CatalogOperations.previewStreamReprojection orderCatalogOperations repairRequest
      repairPreview ^. #servingRevisionId `shouldBe` orderReportingRevisionV2 ^. #revisionId
      repairPreview ^. #eligible `shouldBe` True
      map (targetIdText . (^. #targetId)) (repairPreview ^. #targets)
        `shouldBe` ["jitsurei-order-line", "jitsurei-order-summary"]
      Right (Right repaired) <-
        runner $ CatalogOperations.reprojectCatalogStream orderCatalogOperations repairRequest
      repaired ^. #repair . #streamVersion `shouldBe` StreamVersion 1
      repaired ^. #repair . #replayedEvents `shouldBe` 1
      repaired ^. #repair . #verified `shouldBe` True
      Right afterRepair <- runner $ Store.runTransaction (Tx.statement () orderTargetedRepairFactsStmt)
      List.filter (\(orderId, _, _, _, _) -> orderId /= "versioned-before") afterRepair
        `shouldBe` List.filter (\(orderId, _, _, _, _) -> orderId /= "versioned-before") beforeRepair
      List.find (\(orderId, _, _, _, _) -> orderId == "versioned-before") afterRepair
        `shouldBe` Just ("versioned-before", "placed", skuText sampleSku, 2, 2)

      Right retired <- runner $ CatalogOperations.listRetiredGenerations orderCatalogOperations
      length (retired ^. #generations) `shouldBe` 3

  describe "Jitsurei snapshots" $ around (withFreshResourceStore fixture) $ do
    it "writes a snapshot after the configured threshold" $ \(_store, StoreRunner runner) -> do
      let target = orderStream (OrderId "snapshot-100")
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            snapshotOrderEventStream
            target
            ( PlaceOrder
                PlaceOrderData
                  { orderId = OrderId "snapshot-100",
                    sku = sampleSku,
                    quantity = sampleQuantity
                  }
            )
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            snapshotOrderEventStream
            target
            ( ApprovePayment
                ApprovePaymentData
                  { orderId = OrderId "snapshot-100",
                    paymentRef = samplePaymentRef
                  }
            )
      Right snapshotVersion <-
        runner $
          Store.runTransaction $
            Tx.statement "order-snapshot-100" snapshotVersionForStreamStmt
      snapshotVersion `shouldBe` Just (StreamVersion 2)

  describe "Jitsurei process manager" $ around (withFreshResourceStoreWith fixture (withProjectionSchema jitsureiProjectionSchema)) $ do
    it "dispatches a packing command once for a payment event" $ \(_store, StoreRunner runner) -> do
      -- Dispatching the fulfillment process manager now runs the target's
      -- inline order-summary projection (see commit "run target inline
      -- projections on dispatch"), which writes to jitsurei_order_summary.
      -- That application table must exist before dispatch.
      Right () <- runner initializeJitsureiTables
      let target = orderStream sampleOrderId
      Right (Right _) <-
        runner $
          runCommand defaultRunCommandOptions orderEventStream target samplePlaceOrder
      Right (Right _) <-
        runner $
          runCommand defaultRunCommandOptions orderEventStream target sampleApprovePayment
      Right recorded <-
        runner $
          Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10
      let paymentRecorded = Vector.toList recorded !! 1
      first <-
        runner $
          runFulfillmentOnce
            defaultRunCommandOptions
            paymentRecorded
            (PaymentApproved PaymentApprovedData {orderId = sampleOrderId, paymentRef = samplePaymentRef})
      first `shouldSatisfy` \case
        Right (Right result) ->
          case result ^. #commandResults of
            [PMCommandAppended {}] -> True
            _ -> False
        _ -> False
      second <-
        runner $
          runFulfillmentOnce
            defaultRunCommandOptions
            paymentRecorded
            (PaymentApproved PaymentApprovedData {orderId = sampleOrderId, paymentRef = samplePaymentRef})
      second `shouldSatisfy` \case
        Right (Right result) ->
          case (result ^. #managerResult, result ^. #commandResults) of
            (PMStateDuplicate {}, [PMCommandDuplicate {}]) -> True
            _ -> False
        _ -> False

    it "updates the target inline read model when fulfillment dispatches packing" $ \(_store, StoreRunner runner) -> do
      Right () <- runner initializeJitsureiTables
      let target = orderStream sampleOrderId
      Right (Right (ProjectionCommandApplied _)) <-
        runner $
          runCommandWithCatalogProjections
            defaultRunCommandOptions
            orderEventStream
            target
            samplePlaceOrder
            jitsureiProjectionCatalog
            orderProjectionSet
      Right (Right (ProjectionCommandApplied _)) <-
        runner $
          runCommandWithCatalogProjections
            defaultRunCommandOptions
            orderEventStream
            target
            sampleApprovePayment
            jitsureiProjectionCatalog
            orderProjectionSet
      Right paidSummary <-
        runner $
          runQuery Nothing orderSummaryReadModel (OrderSummaryQuery sampleOrderId)
      case paidSummary of
        Right (Just summary) -> summary ^. #status `shouldBe` "paid"
        other -> expectationFailure ("expected paid order summary, got " <> show other)

      Right recorded <-
        runner $
          Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10
      let paymentRecorded = Vector.toList recorded !! 1
      first <-
        runner $
          runFulfillmentOnce
            defaultRunCommandOptions
            paymentRecorded
            (PaymentApproved PaymentApprovedData {orderId = sampleOrderId, paymentRef = samplePaymentRef})
      first `shouldSatisfy` \case
        Right (Right result) ->
          case result ^. #commandResults of
            [PMCommandAppended {}] -> True
            _ -> False
        _ -> False
      Right packedSummary <-
        runner $
          runQuery Nothing orderSummaryReadModel (OrderSummaryQuery sampleOrderId)
      case packedSummary of
        Right (Just summary) -> summary ^. #status `shouldBe` "packed"
        other -> expectationFailure ("expected packed order summary, got " <> show other)

      second <-
        runner $
          runFulfillmentOnce
            defaultRunCommandOptions
            paymentRecorded
            (PaymentApproved PaymentApprovedData {orderId = sampleOrderId, paymentRef = samplePaymentRef})
      second `shouldSatisfy` \case
        Right (Right result) ->
          case (result ^. #managerResult, result ^. #commandResults) of
            (PMStateDuplicate {}, [PMCommandDuplicate {}]) -> True
            _ -> False
        _ -> False
      Right replayedSummary <-
        runner $
          runQuery Nothing orderSummaryReadModel (OrderSummaryQuery sampleOrderId)
      case replayedSummary of
        Right (Just summary) -> summary ^. #status `shouldBe` "packed"
        other -> expectationFailure ("expected packed order summary after replay, got " <> show other)

  describe "Jitsurei timers" $ around (withFreshResourceStore fixture) $ do
    it "claims a due timer and marks it fired" $ \(_store, StoreRunner runner) -> do
      Right () <-
        runner $
          Store.runTransaction $
            scheduleTimerTx (paymentTimeoutRequest sampleOrderId dueTime)
      Right claimed <-
        runner $
          runPaymentTimeoutWorker Nothing dueTime
      claimed `shouldSatisfy` isJust

  describe "Jitsurei agent-qualification router" $ around (withFreshResourceStore fixture) $ do
    it "routes a transaction to every chapter resolved from its areas, idempotently" $ \(_store, StoreRunner runner) -> do
      Right () <-
        runner $
          initializeAreaChapters
      Right () <- runner $
        Store.runTransaction $ do
          -- area-north and area-south overlap on (m2, c2).
          Tx.statement ("area-north", "m1", "c1") insertAreaChapterStmt
          Tx.statement ("area-north", "m2", "c2") insertAreaChapterStmt
          Tx.statement ("area-south", "m2", "c2") insertAreaChapterStmt
          Tx.statement ("area-south", "m3", "c3") insertAreaChapterStmt
      let transaction =
            Transaction
              { txnId = TxnId "txn-1",
                areas = [AreaId "area-north", AreaId "area-south"]
              }
      -- First pass: three distinct chapters resolved (m2/c2 de-duplicated
      -- across the two overlapping areas), one command appended to each.
      Right (RouterResult rs1) <-
        runner $
          runRouterOnce defaultRunCommandOptions (agentQualRouter Nothing) sourceTransactionEvent transaction
      length rs1 `shouldBe` 3
      rs1 `shouldSatisfy` all isAppended
      Right c1 <-
        runner $
          Store.readStreamForward (StreamName "chapter-m1-c1") (StreamVersion 0) 10
      Right c2 <-
        runner $
          Store.readStreamForward (StreamName "chapter-m2-c2") (StreamVersion 0) 10
      Right c3 <-
        runner $
          Store.readStreamForward (StreamName "chapter-m3-c3") (StreamVersion 0) 10
      Vector.length c1 `shouldBe` 1
      Vector.length c2 `shouldBe` 1
      Vector.length c3 `shouldBe` 1
      -- Data-dependence: a transaction whose areas are unseeded resolves to no
      -- chapters, so the count tracks the read model rather than a fixed list.
      Right (RouterResult rsEmpty) <-
        runner $
          runRouterOnce
            defaultRunCommandOptions
            (agentQualRouter Nothing)
            sourceTransactionEvent
            (Transaction {txnId = TxnId "txn-1", areas = [AreaId "area-empty"]})
      length rsEmpty `shouldBe` 0
      -- Replay: the same source event re-dispatches as duplicates, no new events.
      Right (RouterResult rs2) <-
        runner $
          runRouterOnce defaultRunCommandOptions (agentQualRouter Nothing) sourceTransactionEvent transaction
      length rs2 `shouldBe` 3
      rs2 `shouldSatisfy` all isDuplicate
      Right c1' <-
        runner $
          Store.readStreamForward (StreamName "chapter-m1-c1") (StreamVersion 0) 10
      Right c2' <-
        runner $
          Store.readStreamForward (StreamName "chapter-m2-c2") (StreamVersion 0) 10
      Right c3' <-
        runner $
          Store.readStreamForward (StreamName "chapter-m3-c3") (StreamVersion 0) 10
      Vector.length c1' `shouldBe` 1
      Vector.length c2' `shouldBe` 1
      Vector.length c3' `shouldBe` 1

  describe "Jitsurei incident aggregate" $ around (withFreshResourceStore fixture) $ do
    it "raises, acknowledges, and rejects a post-acknowledgement escalation" $ \(_store, StoreRunner runner) -> do
      let incidentId = IncidentId "inc-1"
          target = incidentStream incidentId
      Right (Right _) <-
        runner $
          runCommand defaultRunCommandOptions incidentEventStream target $
            RaiseIncident
              RaiseIncidentData
                { incidentId = incidentId,
                  service = Service "checkout",
                  severity = Sev1,
                  raisedAt = incidentRaisedAt
                }
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            incidentEventStream
            target
            (AcknowledgeIncident (AcknowledgeIncidentData incidentId))
      -- The aggregate's guards resolve the ack/escalate race: once acknowledged,
      -- EscalateIncident has no edge and is a benign domain rejection.
      escalateResult <-
        runner $
          runCommand
            defaultRunCommandOptions
            incidentEventStream
            target
            (EscalateIncident (EscalateIncidentData incidentId))
      escalateResult `shouldBe` Right (Left CommandRejected)
      Right recorded <-
        runner $
          Store.readStreamForward (StreamName "incident-inc-1") (StreamVersion 0) 10
      traverse (decodeRecorded incidentCodec) (Vector.toList recorded)
        `shouldBe` Right
          [ IncidentRaised
              IncidentRaisedData
                { incidentId = incidentId,
                  service = Service "checkout",
                  severity = Sev1,
                  raisedAt = incidentRaisedAt
                },
            IncidentAcknowledged (IncidentAcknowledgedData incidentId)
          ]

  describe "Jitsurei paging" $ around (withFreshResourceStore fixture) $ do
    it "sends then acknowledges a page" $ \(_store, StoreRunner runner) -> do
      let incidentId = IncidentId "inc-1"
          responderId = ResponderId "alice"
          target = pageStream incidentId responderId
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            pageEventStream
            target
            (SendPage (SendPageData incidentId responderId))
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            pageEventStream
            target
            (AcknowledgePage (AcknowledgePageData incidentId responderId))
      Right recorded <-
        runner $
          Store.readStreamForward (StreamName "page-inc-1-alice") (StreamVersion 0) 10
      traverse (decodeRecorded pageCodec) (Vector.toList recorded)
        `shouldBe` Right
          [ PageSent (PageSentData incidentId responderId),
            PageAcknowledged (PageAcknowledgedData incidentId responderId)
          ]

    it "fans IncidentRaised out to one page per rostered responder, idempotently" $ \(_store, StoreRunner runner) -> do
      Right () <-
        runner $
          initializeOncallRoster
      Right () <- runner $
        Store.runTransaction $ do
          Tx.statement ("checkout", "alice", 1) insertOncallStmt
          Tx.statement ("checkout", "bob", 1) insertOncallStmt
          Tx.statement ("checkout", "carol", 2) insertOncallStmt
      let raised =
            IncidentRaisedData
              { incidentId = IncidentId "inc-1",
                service = Service "checkout",
                severity = Sev1,
                raisedAt = incidentRaisedAt
              }
      Right (RouterResult rs1) <-
        runner $
          runRouterOnce defaultRunCommandOptions (pagingRouter Nothing) incidentRaisedSource raised
      length rs1 `shouldBe` 3
      rs1 `shouldSatisfy` all isAppended
      Right pa <-
        runner $
          Store.readStreamForward (StreamName "page-inc-1-alice") (StreamVersion 0) 10
      Right pb <-
        runner $
          Store.readStreamForward (StreamName "page-inc-1-bob") (StreamVersion 0) 10
      Right pc <-
        runner $
          Store.readStreamForward (StreamName "page-inc-1-carol") (StreamVersion 0) 10
      Vector.length pa `shouldBe` 1
      Vector.length pb `shouldBe` 1
      Vector.length pc `shouldBe` 1
      -- Data-dependence: an unrostered service resolves to no pages.
      Right (RouterResult rsNone) <-
        runner $
          runRouterOnce
            defaultRunCommandOptions
            (pagingRouter Nothing)
            incidentRaisedSource
            IncidentRaisedData
              { incidentId = raised.incidentId,
                service = Service "unstaffed",
                severity = raised.severity,
                raisedAt = raised.raisedAt
              }
      length rsNone `shouldBe` 0
      -- Replay the same source event: every dispatch is a duplicate, no new pages.
      Right (RouterResult rs2) <-
        runner $
          runRouterOnce defaultRunCommandOptions (pagingRouter Nothing) incidentRaisedSource raised
      length rs2 `shouldBe` 3
      rs2 `shouldSatisfy` all isDuplicate
      Right paAgain <-
        runner $
          Store.readStreamForward (StreamName "page-inc-1-alice") (StreamVersion 0) 10
      Vector.length paAgain `shouldBe` 1

  describe "Jitsurei escalation process manager" $ around (withFreshResourceStore fixture) $ do
    it "advances the saga and schedules an escalation timer on IncidentRaised" $ \(_store, StoreRunner runner) -> do
      let incidentId = IncidentId "inc-1"
          raised =
            IncidentRaisedData
              { incidentId = incidentId,
                service = Service "checkout",
                severity = Sev1,
                raisedAt = incidentRaisedAt
              }
      result <-
        runner $
          runEscalationOnce defaultRunCommandOptions incidentRaisedSource (IncidentReported raised)
      case result of
        Right (Right pmResult) -> do
          pmResult ^. #managerResult `shouldSatisfy` \case
            PMStateAppended {} -> True
            _ -> False
          pmResult ^. #timersScheduled `shouldBe` 1
        other -> expectationFailure ("expected process-manager success, got " <> show other)
      -- The Sev1 escalation window is 5 minutes; a timer due at +10m is claimable.
      claimed <- runner $ claimDueTimer (addUTCTime 600 incidentRaisedAt)
      claimed `shouldSatisfy` \case
        Right (Just _) -> True
        _ -> False

    it "dispatches AcknowledgeIncident on PageAcknowledged, idempotently" $ \(_store, StoreRunner runner) -> do
      let incidentId = IncidentId "inc-2"
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            incidentEventStream
            (incidentStream incidentId)
            (RaiseIncident (sampleRaiseCmd incidentId Sev2))
      -- The saga must observe the incident before an acknowledgement, exactly as
      -- the live flow does (IncidentRaised reaches the PM before any PageAcknowledged).
      Right (Right _) <-
        runner $
          runEscalationOnce defaultRunCommandOptions incidentRaisedSource (IncidentReported (sampleRaised incidentId Sev2))
      let acked = PageAcknowledgedData {incidentId = incidentId, responderId = ResponderId "alice"}
      firstResult <-
        runner $
          runEscalationOnce defaultRunCommandOptions pageAckSource (ResponderAcked acked)
      firstResult `shouldSatisfy` \case
        Right (Right pmResult) ->
          case pmResult ^. #commandResults of
            [PMCommandAppended {}] -> True
            _ -> False
        _ -> False
      Right managerSnapshotVersion <-
        runner $
          Store.runTransaction $
            Tx.statement "esc-inc-2" snapshotVersionForStreamStmt
      managerSnapshotVersion `shouldBe` Just (StreamVersion 2)
      Right recorded <-
        runner $
          Store.readStreamForward (StreamName "incident-inc-2") (StreamVersion 0) 10
      fmap last (traverse (decodeRecorded incidentCodec) (Vector.toList recorded))
        `shouldBe` Right (IncidentAcknowledged (IncidentAcknowledgedData incidentId))
      secondResult <-
        runner $
          runEscalationOnce defaultRunCommandOptions pageAckSource (ResponderAcked acked)
      secondResult `shouldSatisfy` \case
        Right (Right pmResult) ->
          case (pmResult ^. #managerResult, pmResult ^. #commandResults) of
            (PMStateDuplicate {}, [PMCommandDuplicate {}]) -> True
            _ -> False
        _ -> False

    it "escalates an unacknowledged incident when the timer fires" $ \(_store, StoreRunner runner) -> do
      let incidentId = IncidentId "inc-3"
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            incidentEventStream
            (incidentStream incidentId)
            (RaiseIncident (sampleRaiseCmd incidentId Sev1))
      Right (Right _) <-
        runner $
          runEscalationOnce defaultRunCommandOptions incidentRaisedSource (IncidentReported (sampleRaised incidentId Sev1))
      _ <-
        runner $
          runEscalationTimerWorker Nothing defaultRunCommandOptions (addUTCTime 600 incidentRaisedAt)
      Right recorded <-
        runner $
          Store.readStreamForward (StreamName "incident-inc-3") (StreamVersion 0) 10
      fmap last (traverse (decodeRecorded incidentCodec) (Vector.toList recorded))
        `shouldBe` Right (IncidentEscalated (IncidentEscalatedData incidentId))

    it "is a benign no-op when the incident was already acknowledged" $ \(_store, StoreRunner runner) -> do
      let incidentId = IncidentId "inc-4"
          target = incidentStream incidentId
      Right (Right _) <-
        runner $
          runCommand defaultRunCommandOptions incidentEventStream target (RaiseIncident (sampleRaiseCmd incidentId Sev1))
      Right (Right _) <-
        runner $
          runCommand
            defaultRunCommandOptions
            incidentEventStream
            target
            (AcknowledgeIncident (AcknowledgeIncidentData incidentId))
      Right (Right _) <-
        runner $
          runEscalationOnce defaultRunCommandOptions incidentRaisedSource (IncidentReported (sampleRaised incidentId Sev1))
      fired <-
        runner $
          runEscalationTimerWorker Nothing defaultRunCommandOptions (addUTCTime 600 incidentRaisedAt)
      fired `shouldSatisfy` \case
        Right (Just _) -> True
        _ -> False
      Right recorded <-
        runner $
          Store.readStreamForward (StreamName "incident-inc-4") (StreamVersion 0) 10
      let events = either (const []) id (traverse (decodeRecorded incidentCodec) (Vector.toList recorded))
      any isIncidentEscalated events `shouldBe` False

  describe "Jitsurei shipment notices" $ do
    it "maps OrderShipped to a notice and ignores every other order event" $ do
      shipmentNoticeFor (OrderShipped sampleShipped)
        `shouldBe` Just sampleNotice
      shipmentNoticeFor (OrderPacked (OrderPackedData {orderId = sampleOrderId}))
        `shouldBe` Nothing

    around (withFreshDatabase fixture) $ do
      it "drains an enqueued notice into the notices table, idempotently" $ \connStr ->
        withJobRuntime connStr Nothing $ \runtime -> do
          let pool = runtime.runtimePool
          -- First delivery: the notice is sent and recorded.
          handled <- runQueue runtime $ do
            ensureShipmentNoticeQueue pool
            _ <- enqueueShipmentNotice sampleNotice
            drainShipmentNotices pool 10
          handled `shouldBe` 1
          noticeCount pool `shouldReturn` 1
          recordedNotice pool sampleOrderId
            `shouldReturn` Just ("UPS", "TRACK-100")

          -- At-least-once redelivery: the same notice is handled again
          -- and the ON CONFLICT DO NOTHING write leaves one row.
          redelivered <- runQueue runtime $ do
            _ <- enqueueShipmentNotice sampleNotice
            drainShipmentNotices pool 10
          redelivered `shouldBe` 1
          noticeCount pool `shouldReturn` 1

      it "dead-letters a notice that can never be sent" $ \connStr ->
        withJobRuntime connStr Nothing $ \runtime -> do
          let pool = runtime.runtimePool
              unsendable = ShipmentNotice {orderId = sampleOrderId, carrier = Carrier "UPS", trackingId = TrackingId "  "}
          handled <- runQueue runtime $ do
            ensureShipmentNoticeQueue pool
            _ <- enqueueShipmentNotice unsendable
            drainShipmentNotices pool 10
          handled `shouldBe` 1
          -- The handler returned Dead, so nothing was written, the main
          -- queue is empty, and the row is parked in the DLQ.
          noticeCount pool `shouldReturn` 0
          mainQueueDepth runtime `shouldReturn` 0
          dlqDepth runtime `shouldReturn` 1

      it "preserves per-order order and drains every grouped notice" $ \connStr ->
        withJobRuntime connStr Nothing $ \runtime -> do
          let pool = runtime.runtimePool
              second = ShipmentNotice {orderId = sampleOrderId, carrier = Carrier "DHL", trackingId = TrackingId "TRACK-101"}
          handled <- runQueue runtime $ do
            ensureShipmentNoticeQueue pool
            _ <- enqueueShipmentNotice sampleNotice
            _ <- enqueueShipmentNotice second
            drainShipmentNotices pool 10
          handled `shouldBe` 2
          -- Both share one FIFO group (the order id), so the first
          -- delivered wins the ON CONFLICT DO NOTHING insert.
          noticeCount pool `shouldReturn` 1
          recordedNotice pool sampleOrderId
            `shouldReturn` Just ("UPS", "TRACK-100")
          mainQueueDepth runtime `shouldReturn` 0

-- | Interpret a queue action against the runtime, failing the test on a PGMQ error.
runQueue :: JobRuntime -> Eff QueueStack a -> IO a
runQueue runtime act = do
  result <- runJobEff runtime act
  either (\err -> fail ("PGMQ runtime error: " <> show err)) pure result

noticeCount :: Pool.Pool -> IO Int64
noticeCount pool =
  either (fail . show) pure
    =<< Pool.use pool (Session.statement () countShipmentNotices)

recordedNotice :: Pool.Pool -> OrderId -> IO (Maybe (Text, Text))
recordedNotice pool orderId =
  either (fail . show) pure
    =<< Pool.use pool (Session.statement (orderIdText orderId) lookupShipmentNotice)

externalProjectionStatus ::
  Store.KirokuStore ->
  Text ->
  IO (Text, Bool, Maybe Text, Int64, Maybe Text, Maybe Text, Maybe Int64, Maybe Int64)
externalProjectionStatus store groupId =
  either (fail . show) pure
    =<< Pool.use
      (store ^. #pool)
      (Session.statement groupId externalProjectionStatusStmt)

externalProjectionStatusStmt ::
  Statement Text (Text, Bool, Maybe Text, Int64, Maybe Text, Maybe Text, Maybe Int64, Maybe Int64)
externalProjectionStatusStmt =
  preparable
    """
    SELECT lifecycle_phase,
           reads_allowed,
           serving_revision_id,
           serving_epoch,
           active_run_id,
           candidate_revision_id,
           candidate_rebuild_position,
           candidate_rebuild_head
    FROM keiro_read.projection_group_status_v1
    WHERE group_id = $1
    """
    (E.param (E.nonNullable E.text))
    ( D.singleRow
        ( (,,,,,,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.bool)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.int8)
            <*> D.column (D.nullable D.int8)
        )
    )

mainQueueDepth :: JobRuntime -> IO Int64
mainQueueDepth runtime =
  runQueue runtime (queueLength (shipmentNoticeJob.jobQueue.physicalName))

dlqDepth :: JobRuntime -> IO Int64
dlqDepth runtime =
  runQueue runtime (queueLength (shipmentNoticeJob.jobQueue.dlqName))

queueLength :: (Pgmq :> es) => QueueName -> Eff es Int64
queueLength name = do
  metrics <- Pgmq.queueMetrics name
  pure metrics.queueLength

sampleShipped :: OrderShippedData
sampleShipped =
  OrderShippedData
    { orderId = sampleOrderId,
      carrier = Carrier "UPS",
      trackingId = TrackingId "TRACK-100"
    }

sampleNotice :: ShipmentNotice
sampleNotice =
  ShipmentNotice
    { orderId = sampleOrderId,
      carrier = Carrier "UPS",
      trackingId = TrackingId "TRACK-100"
    }

sampleOrderId :: OrderId
sampleOrderId = OrderId "order-100"

sampleSku :: Sku
sampleSku = Sku "SKU-RED-MUG"

sampleQuantity :: Quantity
sampleQuantity = Quantity 3

samplePaymentRef :: PaymentRef
samplePaymentRef = PaymentRef "pay_123"

samplePlaceOrder :: OrderCommand
samplePlaceOrder =
  PlaceOrder
    PlaceOrderData
      { orderId = sampleOrderId,
        sku = sampleSku,
        quantity = sampleQuantity
      }

sampleApprovePayment :: OrderCommand
sampleApprovePayment =
  ApprovePayment
    ApprovePaymentData
      { orderId = sampleOrderId,
        paymentRef = samplePaymentRef
      }

dueTime :: UTCTime
dueTime = UTCTime (ModifiedJulianDay 1) (secondsToDiffTime 0)

-- A minimal source event whose only load-bearing field is its id, which seeds
-- the router's deterministic command ids. Its payload is irrelevant to routing.
sourceTransactionEvent :: RecordedEvent
sourceTransactionEvent =
  RecordedEvent
    { eventId = EventId txnSourceUuid,
      eventType = EventType "TransactionSubmitted",
      streamVersion = StreamVersion 1,
      globalPosition = GlobalPosition 1,
      originalStreamId = StreamId 1,
      originalVersion = StreamVersion 1,
      payload = Aeson.Null,
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0)
    }

txnSourceUuid :: UUID
txnSourceUuid =
  case fromString "018f0f18-17aa-7000-8000-0000000000c1" of
    Just value -> value
    Nothing -> error "invalid transaction source UUID"

incidentRaisedAt :: UTCTime
incidentRaisedAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)

-- The command and event payloads share fields but are distinct types; build each
-- from the same inputs.
sampleRaiseCmd :: IncidentId -> Severity -> RaiseIncidentData
sampleRaiseCmd incidentId severity =
  RaiseIncidentData
    { incidentId = incidentId,
      service = Service "checkout",
      severity = severity,
      raisedAt = incidentRaisedAt
    }

sampleRaised :: IncidentId -> Severity -> IncidentRaisedData
sampleRaised incidentId severity =
  IncidentRaisedData
    { incidentId = incidentId,
      service = Service "checkout",
      severity = severity,
      raisedAt = incidentRaisedAt
    }

-- A minimal source event standing in for a recorded IncidentRaised; only its id
-- is load-bearing (it seeds the paging router's deterministic command ids).
incidentRaisedSource :: RecordedEvent
incidentRaisedSource =
  RecordedEvent
    { eventId = EventId incidentSourceUuid,
      eventType = EventType "IncidentRaised",
      streamVersion = StreamVersion 1,
      globalPosition = GlobalPosition 1,
      originalStreamId = StreamId 1,
      originalVersion = StreamVersion 1,
      payload = Aeson.Null,
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = incidentRaisedAt
    }

incidentSourceUuid :: UUID
incidentSourceUuid =
  case fromString "018f0f18-17aa-7000-8000-0000000000d1" of
    Just value -> value
    Nothing -> error "invalid incident source UUID"

-- A second source-event fixture, standing in for a recorded PageAcknowledged.
pageAckSource :: RecordedEvent
pageAckSource = incidentRaisedSource {eventId = EventId pageAckSourceUuid}

pageAckSourceUuid :: UUID
pageAckSourceUuid =
  case fromString "018f0f18-17aa-7000-8000-0000000000d2" of
    Just value -> value
    Nothing -> error "invalid page-ack source UUID"

isIncidentEscalated :: IncidentEvent -> Bool
isIncidentEscalated = \case
  IncidentEscalated {} -> True
  _ -> False

isAppended :: PMCommandResult target -> Bool
isAppended = \case
  PMCommandAppended {} -> True
  _ -> False

isDuplicate :: PMCommandResult target -> Bool
isDuplicate = \case
  PMCommandDuplicate {} -> True
  _ -> False

snapshotVersionForStreamStmt :: Statement Text (Maybe StreamVersion)
snapshotVersionForStreamStmt =
  preparable
    """
    SELECT ks.stream_version
    FROM keiro.keiro_snapshots ks
    JOIN streams s ON s.stream_id = ks.stream_id
    WHERE s.stream_name = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe (StreamVersion <$> D.column (D.nonNullable D.int8)))

parseRebuildRunId :: Text -> RebuildRunId
parseRebuildRunId identity =
  case mkRebuildRunId identity of
    Left err -> error (show err)
    Right value -> value

seedBrownfieldRoot :: Tx.Transaction ()
seedBrownfieldRoot =
  Tx.sql
    """
    INSERT INTO jitsurei.jitsurei_order_summary
      (order_id, sku, quantity, status, last_seen)
    VALUES ('brownfield-no-history', 'BROWNFIELD', 1, 'rebuild-blocked', 0)
    """

repairBrownfieldRoot :: Tx.Transaction ()
repairBrownfieldRoot =
  Tx.sql
    """
    UPDATE jitsurei.jitsurei_order_summary
    SET status = 'retained'
    WHERE order_id = 'brownfield-no-history'
    """

orderCatalogFactsStmt :: Statement () (Int64, Int64, Int64, Int64)
orderCatalogFactsStmt =
  preparable
    """
    SELECT
      (SELECT count(*) FROM jitsurei.jitsurei_order_summary),
      (SELECT count(*) FROM jitsurei.jitsurei_order_line),
      (SELECT count(*) FROM jitsurei.jitsurei_order_async_audit),
      (SELECT count(*) FROM jitsurei.jitsurei_order_live_side_effect)
    """
    E.noParams
    ( D.singleRow
        ( (,,,)
            <$> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
        )
    )

orderVersionedFactsStmt :: Statement () (Int64, Int64, Int64, Bool)
orderVersionedFactsStmt =
  preparable
    """
    SELECT
      (SELECT count(*) FROM jitsurei.jitsurei_order_summary),
      (SELECT count(*) FROM jitsurei.jitsurei_order_line),
      (SELECT count(*) FROM jitsurei.jitsurei_order_async_audit),
      EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'jitsurei'
          AND table_name = 'jitsurei_order_summary'
          AND column_name = 'state'
      ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'jitsurei'
          AND table_name = 'jitsurei_order_summary'
          AND column_name = 'status'
      )
    """
    E.noParams
    ( D.singleRow
        ( (,,,)
            <$> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.bool)
        )
    )

corruptOneOrderStmt :: Statement () ()
corruptOneOrderStmt =
  preparable
    "WITH corrupt_summary AS (UPDATE jitsurei.jitsurei_order_summary SET state = 'corrupt', source_revision = 99 WHERE order_id = 'versioned-before' RETURNING order_id) UPDATE jitsurei.jitsurei_order_line SET sku = 'CORRUPT', source_revision = 99 WHERE order_id IN (SELECT order_id FROM corrupt_summary)"
    E.noParams
    D.noResult

orderTargetedRepairFactsStmt :: Statement () [(Text, Text, Text, Int32, Int32)]
orderTargetedRepairFactsStmt =
  preparable
    "SELECT summaries.order_id, summaries.state, lines.sku, summaries.source_revision::integer, lines.source_revision::integer FROM jitsurei.jitsurei_order_summary AS summaries JOIN jitsurei.jitsurei_order_line AS lines USING (order_id) ORDER BY summaries.order_id"
    E.noParams
    ( D.rowList
        ( (,,,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.int4)
            <*> D.column (D.nonNullable D.int4)
        )
    )

orderSummaryExternalV1Stmt :: Statement () [(Text, Text, Int64, Text, Int64)]
orderSummaryExternalV1Stmt =
  preparable
    "SELECT order_id, sku, quantity, status, last_seen FROM keiro_read.jitsurei_order_summary_reader_v1() ORDER BY order_id"
    E.noParams
    ( D.rowList
        ( (,,,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.int8)
        )
    )

orderSummaryExternalV2Stmt :: Statement () [(Text, Text, Int64, Text, Int64, Int32)]
orderSummaryExternalV2Stmt =
  preparable
    "SELECT order_id, sku, quantity, state, last_seen, source_revision::integer FROM keiro_read.jitsurei_order_summary_reader_v2() ORDER BY order_id"
    E.noParams
    ( D.rowList
        ( (,,,,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int4)
        )
    )
