{-# LANGUAGE MultilineStrings #-}

module VersionedRebuildSpec
  ( spec,
  )
where

import CatalogSpec
  ( asyncProjectionId,
    auditTargetId,
    bridgeCatalog,
    bridgeRevisionV1,
    bridgeRevisionV2,
    catalogAsyncProjection,
    counterBinding,
    counterReadContract,
    counterTargetId,
    mainGroupId,
  )
import Contravariant.Extras (contrazip2)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Functor.Contravariant ((>$<))
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Data.Vector qualified as Vector
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Connection.Settings qualified as ConnectionSettings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Keiro.Connection (qualifyTable)
import Keiro.Prelude
import Keiro.Projection (CatalogAsyncApplyOutcome (..), applyAsyncProjectionFromCatalog)
import Keiro.Projection.Catalog
import Keiro.ReadModel (ReadModel (..))
import Keiro.ReadModel.External (reconcileExternalReadContracts)
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshDatabase, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.HistoryRetention
  ( HistoryRetentionLeaseRequest (..),
    HistoryRetentionRenewalError (..),
    mkHistoryRetentionLeaseDuration,
    mkHistoryRetentionLeaseOwner,
    mkHistoryRetentionLeaseReason,
  )
import Kiroku.Store.Types
  ( CategoryName (..),
    EventData (..),
    EventId (..),
    EventType (..),
    ExpectedVersion (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
  )
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = do
  describe "schema-versioned rebuild lifecycle" $
    around (withFreshStore fixture) $ do
      it "persists serving and candidate generations and resumes the same run without reprovisioning" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridge
        registerBridge store catalog
        let request = versionedRequest "versioned-retry" physicalTargets

        first <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight
        second <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight

        second `shouldBe` first
        length (first ^. #candidateGenerations) `shouldBe` 2
        map (^. #lifecycle) (first ^. #candidateGenerations)
          `shouldBe` [GenerationStaging, GenerationStaging]
        runStatement store () activeLifecycleFactsStmt
          `shouldReturn` ("rebuilding-versioned", True, True, "counter-v1", 0, 2, 2, 1, 1)

        conflict <-
          expectStore store (beginVersionedRebuild catalog (request & #cutoverThreshold .~ 99))
        conflict
          `shouldSatisfy` \case
            Left (VersionedRunIdentityConflict _ detail) -> "threshold" `Text.isInfixOf` detail
            _ -> False

      it "rolls provisioner failures back with no run, lease, or untracked sibling" $ \store -> do
        setupBridge store
        (failingCatalog, physicalTargets) <-
          validatedBridgeFrom
            ( replaceCandidateProvisionerInCatalog
                counterTargetId
                ( \provisioner ->
                    provisioner
                      { provisionTarget = \targetContext -> do
                          createV2Counter targetContext
                          Tx.sql "SELECT 1 / 0"
                      }
                )
                runtimeBridgeCatalog
            )
        registerBridge store failingCatalog

        result <-
          Store.runStoreIO
            store
            (beginVersionedRebuild failingCatalog (versionedRequest "versioned-provision-failure" physicalTargets))
        result `shouldSatisfy` isLeft
        runStatement store () rolledBackLifecycleFactsStmt
          `shouldReturn` ("live", 0, 0, 0, 0)

      it "rolls typed schema-validation failure back after candidate DDL" $ \store -> do
        setupBridge store
        (failingCatalog, physicalTargets) <-
          validatedBridgeFrom
            ( replaceCandidateProvisionerInCatalog
                counterTargetId
                ( \provisioner ->
                    provisioner
                      { validateTarget =
                          Just
                            ( \_ ->
                                pure
                                  ( Left
                                      [TargetSchemaViolation "shape.counter-v2" "subtotal column was rejected by the application validator"]
                                  )
                            )
                      }
                )
                runtimeBridgeCatalog
            )
        registerBridge store failingCatalog

        result <-
          expectStore store (beginVersionedRebuild failingCatalog (versionedRequest "versioned-validation-failure" physicalTargets))
        result
          `shouldSatisfy` \case
            Left (VersionedSchemaValidationFailed targetId violations) ->
              targetId == counterTargetId && length violations == 1
            _ -> False
        runStatement store () rolledBackLifecycleFactsStmt
          `shouldReturn` ("live", 0, 0, 0, 0)

      it "uses the restricted clone path only for an exact-shape repair" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridgeFrom cloneBridgeCatalog
        registerBridge store catalog
        runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
        appendVersionedEvents store "counter-clone" 3
        let request =
              versionedRequest "versioned-clone" physicalTargets
                & #targetMode
                .~ RestrictedClone
        _ <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight

        final <- driveVersionedToPromotion store catalog (request ^. #rebuildRunId) 12

        final ^. #phase `shouldBe` VersionedPromoted
        final ^. #servingRevisionId `shouldBe` identity mkProjectionRevisionId "counter-v2"
        runStatement store () servingCountsStmt `shouldReturn` (3, 3)
        runStatement store () cloneShapeStmt `shouldReturn` True

      it "remaps cloned primary-key and identity-sequence names during promotion" $ \store -> do
        runScript store identityBridgeSql
        (catalog, physicalTargets) <- validatedBridgeFrom identityCloneBridgeCatalog
        registerBridge store catalog
        runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
        appendVersionedEvents store "counter-identity-clone" 2
        let request =
              versionedRequest "versioned-identity-clone" physicalTargets
                & #targetMode
                .~ RestrictedClone
        _ <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight

        final <- driveVersionedToPromotion store catalog (request ^. #rebuildRunId) 12

        final ^. #phase `shouldBe` VersionedPromoted
        runStatement store () identityCloneObjectsStmt `shouldReturn` True

      it "returns typed restricted-clone findings without leaving a candidate" $ \store -> do
        setupBridge store
        runScript store cloneTriggerSql
        (catalog, physicalTargets) <- validatedBridgeFrom cloneBridgeCatalog
        registerBridge store catalog
        let request =
              versionedRequest "versioned-clone-refused" physicalTargets
                & #targetMode
                .~ RestrictedClone

        refused <- expectStore store (beginVersionedRebuild catalog request)

        refused
          `shouldSatisfy` \case
            Left (VersionedCloneRefused targetId table findings) ->
              targetId == counterTargetId
                && table == QualifiedTable "app" "counter"
                && findings == ["triggers"]
            _ -> False
        runStatement store () rolledBackLifecycleFactsStmt
          `shouldReturn` ("live", 0, 0, 0, 0)

      it "refuses a deterministic staging-name collision and rolls earlier target work back" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridge
        registerBridge store catalog
        let runId = run "versioned-name-collision"
            collision = candidateTable runId counterTargetId
        runScript
          store
          ( Text.Encoding.encodeUtf8
              ( "CREATE TABLE "
                  <> qualifyTable (collision ^. #schemaName) (collision ^. #tableName)
                  <> " (sentinel bigint NOT NULL)"
              )
          )

        result <-
          expectStore store (beginVersionedRebuild catalog (rebuildRequestFor runId physicalTargets))
        collisionOid <- relationOidFor store collision
        result
          `shouldBe` Left (VersionedStagingNameCollision counterTargetId collision collisionOid)
        runStatement store () collisionRollbackFactsStmt
          `shouldReturn` ("live", 0, 0, 0, 1)

      it "abandons staging generations, releases retention, and repeats as a no-op" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridge
        registerBridge store catalog
        let request = versionedRequest "versioned-abandon" physicalTargets
        handle <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight

        first <- expectStore store (abandonVersionedRebuild (request ^. #rebuildRunId)) >>= requireRight
        second <- expectStore store (abandonVersionedRebuild (request ^. #rebuildRunId)) >>= requireRight

        first ^. #alreadyAbandoned `shouldBe` False
        second ^. #alreadyAbandoned `shouldBe` True
        map (^. #lifecycle) (first ^. #droppedGenerations)
          `shouldBe` replicate 2 GenerationDropped
        for_ (handle ^. #candidateGenerations) $ \generation ->
          runStatement store (generation ^. #physicalTable) relationExistsStmt `shouldReturn` False
        runStatement store () abandonedLifecycleFactsStmt
          `shouldReturn` ("serving-versioned", True, True, "abandoned", 2, 1, 2)

      it "dispatches async writes through the persisted serving revision and fails closed when code is absent" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridge
        registerBridge store catalog
        let request = versionedRequest "versioned-dispatch" physicalTargets
        handle <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight

        legacyView <- expectStore store (lookupProjectionRebuildGroup mainGroupId)
        legacyView ^? _Just . #status
          `shouldBe` Just (UnknownGroupStatus "rebuilding-versioned")

        replayed <-
          expectStore
            store
            (applyVersionedReplayEvent catalog (request ^. #rebuildRunId) (recorded 99))
        replayed `shouldBe` Right 1
        verified <-
          expectStore
            store
            (verifyVersionedCandidate catalog (request ^. #rebuildRunId))
        verified `shouldBe` Right ()

        first <-
          expectStore
            store
            ( Store.runTransaction
                (applyAsyncProjectionFromCatalog catalog asyncProjectionId catalogAsyncProjection (recorded 1))
            )
        first `shouldBe` CatalogAsyncApplied
        runStatement store () servingCountsStmt `shouldReturn` (1, 1)
        for_ (handle ^. #candidateGenerations) $ \generation ->
          rowCount store (generation ^. #physicalTable) `shouldReturn` 1

        runScript store promoteDispatchMetadataSql
        second <-
          expectStore
            store
            ( Store.runTransaction
                (applyAsyncProjectionFromCatalog catalog asyncProjectionId catalogAsyncProjection (recorded 2))
            )
        second `shouldBe` CatalogAsyncApplied
        runStatement store () servingCountsStmt `shouldReturn` (1, 1)
        for_ (handle ^. #candidateGenerations) $ \generation ->
          rowCount store (generation ^. #physicalTable) `shouldReturn` 2

        (v1Only, _) <- validatedBridgeFrom runtimeV1OnlyCatalog
        missing <-
          expectStore
            store
            ( Store.runTransaction
                (applyAsyncProjectionFromCatalog v1Only asyncProjectionId catalogAsyncProjection (recorded 3))
            )
        missing
          `shouldBe` CatalogAsyncServingRevisionUnavailable
            mainGroupId
            (identity mkProjectionRevisionId "counter-v2")
        runStatement store () dispatchDedupCountStmt `shouldReturn` 2
        runStatement store () servingCountsStmt `shouldReturn` (1, 1)
        for_ (handle ^. #candidateGenerations) $ \generation ->
          rowCount store (generation ^. #physicalTable) `shouldReturn` 2

      it "captures a durable final head and atomically promotes every target" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridge
        registerBridge store catalog
        runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
        let request = versionedRequest "versioned-promote" physicalTargets
        _ <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight

        rebuildingStatus <- expectStore store (lookupProjectionGroupStatus mainGroupId)
        rebuildingStatus ^? _Just . #lifecyclePhase
          `shouldBe` Just "rebuilding-versioned"
        rebuildingStatus ^? _Just . #readsAllowed `shouldBe` Just True
        rebuildingStatus ^? _Just . #writesAllowed `shouldBe` Just True
        rebuildingStatus ^? _Just . #servingRevisionId
          `shouldBe` Just (Just (identity mkProjectionRevisionId "counter-v1"))
        rebuildingStatus ^? _Just . #servingEpoch `shouldBe` Just 0
        rebuildingStatus ^? _Just . #activeRunId
          `shouldBe` Just (Just (request ^. #rebuildRunId))
        rebuildingStatus ^? _Just . #candidateRevisionId
          `shouldBe` Just (Just (identity mkProjectionRevisionId "counter-v2"))
        rebuildingStatus ^? _Just . #candidateRebuildPosition
          `shouldBe` Just (Just (GlobalPosition 0))
        rebuildingStatus ^? _Just . #candidateRebuildHead
          `shouldBe` Just (Just (GlobalPosition 0))

        final <- driveVersionedToPromotion store catalog (request ^. #rebuildRunId) 10

        final ^. #phase `shouldBe` VersionedPromoted
        final ^. #servingRevisionId `shouldBe` identity mkProjectionRevisionId "counter-v2"
        final ^. #servingEpoch `shouldBe` 1
        map (^. #lifecycle) (final ^. #servingGenerations)
          `shouldBe` [GenerationServing, GenerationServing]
        runStatement store () promotedLifecycleFactsStmt
          `shouldReturn` ("serving-versioned", True, True, "counter-v2", 1, "promoted", 2, 2, 1)
        runStatement store () promotedCounterShapeStmt `shouldReturn` True
        promotedStatus <- expectStore store (lookupProjectionGroupStatus mainGroupId)
        promotedStatus ^? _Just . #lifecyclePhase
          `shouldBe` Just "serving-versioned"
        promotedStatus ^? _Just . #servingRevisionId
          `shouldBe` Just (Just (identity mkProjectionRevisionId "counter-v2"))
        promotedStatus ^? _Just . #servingEpoch `shouldBe` Just 1
        promotedStatus ^? _Just . #activeRunId `shouldBe` Just Nothing
        promotedStatus ^? _Just . #candidateRevisionId `shouldBe` Just Nothing
        promotedStatus ^? _Just . #candidateRebuildPosition `shouldBe` Just Nothing
        promotedStatus ^? _Just . #candidateRebuildHead `shouldBe` Just Nothing
        promotedStatus ^? _Just . #lastPromotedAt `shouldSatisfy` maybe False isJust

      it "keeps an additive all-row v1 contract on the old generation during replay and projects the promoted table to its stable result type" $ \store -> do
        setupExternalBridge store
        (catalog, physicalTargets) <- validatedBridgeFrom compatibleExternalReadCatalog
        registerBridge store catalog
        runScript store servingOnlyRowsSql
        runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
        appendVersionedEvents store "counter-external-compatible" 2

        let request = versionedRequest "versioned-external-compatible" physicalTargets
        _ <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight
        expectStore store (reconcileExternalReadContracts catalog) >>= requireRight
        runStatement store () externalV1RowsStmt `shouldReturn` [(100, 42)]
        ready <- driveVersionedToCutoverReady store catalog (request ^. #rebuildRunId) 10
        ready ^. #phase `shouldBe` VersionedCutoverReplaying
        runStatement store () externalV1RowsStmt `shouldReturn` [(100, 42)]

        promoted <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= requireRight
        promoted ^. #phase `shouldBe` VersionedPromoted
        promotedRows <- runStatement store () externalV1RowsStmt
        promotedRows `shouldSatisfy` (not . null)
        promotedRows `shouldSatisfy` (all ((== 10) . snd))
        promotedRows `shouldSatisfy` (all ((/= 100) . fst))

      it "activates a breaking v2 contract atomically and fails the old contract with KR003" $ \store -> do
        setupExternalBridge store
        (catalog, physicalTargets) <- validatedBridgeFrom breakingExternalReadCatalog
        registerBridge store catalog
        runScript store servingOnlyRowsSql
        runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
        appendVersionedEvents store "counter-external-breaking" 2

        let request = versionedRequest "versioned-external-breaking" physicalTargets
        _ <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight
        expectStore store (reconcileExternalReadContracts catalog) >>= requireRight
        runStatement store () externalV1RowsStmt `shouldReturn` [(100, 42)]
        _ <- driveVersionedToCutoverReady store catalog (request ^. #rebuildRunId) 10
        runStatement store () externalV1RowsStmt `shouldReturn` [(100, 42)]

        promoted <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= requireRight
        promoted ^. #phase `shouldBe` VersionedPromoted
        oldRead <- Store.runStoreIO store (Store.runTransaction (Tx.statement () externalV1RowsStmt))
        oldRead `shouldSatisfy` hasSqlState "KR003"
        newRows <- runStatement store () externalV2RowsStmt
        newRows `shouldSatisfy` (not . null)
        newRows `shouldSatisfy` (all (\(_, subtotal, tax, total) -> subtotal == 8 && tax == 2 && total == 10))

      it "keeps v1 current after a breaking promotion only through an explicit compatibility implementation" $ \store -> do
        setupExternalBridge store
        (catalog, physicalTargets) <- validatedBridgeFrom compatibilityImplementationCatalog
        registerBridge store catalog
        runScript store servingOnlyRowsSql
        runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
        appendVersionedEvents store "counter-external-compatibility-implementation" 2

        let request = versionedRequest "versioned-external-compatibility-implementation" physicalTargets
        _ <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight
        expectStore store (reconcileExternalReadContracts catalog) >>= requireRight
        _ <- driveVersionedToCutoverReady store catalog (request ^. #rebuildRunId) 10
        _ <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= requireRight

        compatibleRows <- runStatement store () externalV1RowsStmt
        compatibleRows `shouldSatisfy` (not . null)
        compatibleRows `shouldSatisfy` (all ((== 10) . snd))
        v2Rows <- runStatement store () externalV2RowsStmt
        v2Rows `shouldSatisfy` (all (\(_, subtotal, tax, total) -> subtotal == 8 && tax == 2 && total == 10))

      it "converges across two replay rounds while live v1 stays serving and backfills async dedup" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridge
        registerBridge store catalog
        runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
        appendVersionedEvents store "counter-live" 4
        originalEvents <-
          expectStore store (Store.readCategory (CategoryName "counter") (GlobalPosition 0) 10)
        let request =
              versionedRequest "versioned-converge" physicalTargets
                & #cutoverThreshold
                .~ 0
        handle <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight

        first <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= requireRight
        first ^. #phase `shouldBe` VersionedReplayRunning
        for_ (handle ^. #candidateGenerations) $ \generation ->
          rowCount store (generation ^. #physicalTable) `shouldReturn` 2

        live <-
          expectStore
            store
            ( Store.runTransaction
                (applyAsyncProjectionFromCatalog catalog asyncProjectionId catalogAsyncProjection (recorded 101))
            )
        live `shouldBe` CatalogAsyncApplied
        runStatement store () servingCountsStmt `shouldReturn` (1, 1)
        for_ (handle ^. #candidateGenerations) $ \generation ->
          rowCount store (generation ^. #physicalTable) `shouldReturn` 2

        appendVersionedEvents store "counter-later" 2
        second <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= requireRight
        allVersionedComplete (second ^. #sources) `shouldBe` True
        for_ (handle ^. #candidateGenerations) $ \generation ->
          rowCount store (generation ^. #physicalTable) `shouldReturn` 4

        extended <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= requireRight
        extended ^. #capturedHead `shouldBe` GlobalPosition 6
        allVersionedComplete (extended ^. #sources) `shouldBe` False
        replayedAgain <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= requireRight
        allVersionedComplete (replayedAgain ^. #sources) `shouldBe` True

        final <- driveVersionedToPromotion store catalog (request ^. #rebuildRunId) 10
        final ^. #phase `shouldBe` VersionedPromoted
        runStatement store () servingCountsStmt `shouldReturn` (6, 6)
        runStatement store () convergeDedupCountStmt `shouldReturn` 7

        redelivered <-
          expectStore
            store
            ( Store.runTransaction
                (applyAsyncProjectionFromCatalog catalog asyncProjectionId catalogAsyncProjection (Vector.head originalEvents))
            )
        redelivered `shouldBe` CatalogAsyncDuplicate
        runStatement store () servingCountsStmt `shouldReturn` (6, 6)

        (v1Only, _) <- validatedBridgeFrom runtimeV1OnlyCatalog
        refused <-
          expectStore
            store
            ( Store.runTransaction
                (applyAsyncProjectionFromCatalog v1Only asyncProjectionId catalogAsyncProjection (recorded 102))
            )
        refused
          `shouldBe` CatalogAsyncServingRevisionUnavailable
            mainGroupId
            (identity mkProjectionRevisionId "counter-v2")
        runStatement store () servingCountsStmt `shouldReturn` (6, 6)

      it "uses the Kiroku lease to refuse hard deletion for the full active run" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridge
        registerBridge store catalog
        appendVersionedEvents store "counter-retained" 1
        let request = versionedRequest "versioned-retention" physicalTargets
        _ <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight

        blocked <- Store.runStoreIO store (Store.hardDeleteStream (StreamName "counter-retained"))
        blocked
          `shouldSatisfy` \case
            Left HistoryRetentionActive {} -> True
            _ -> False

        _ <- expectStore store (abandonVersionedRebuild (request ^. #rebuildRunId)) >>= requireRight
        deleted <- Store.runStoreIO store (Store.hardDeleteStream (StreamName "counter-retained"))
        deleted `shouldSatisfy` isRight

      it "fails closed when the original retention lease expires" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridge
        registerBridge store catalog
        let request =
              versionedRequest "versioned-expired-retention" physicalTargets
                & #retentionLeaseRequest
                . #duration
                .~ requireIdentity (mkHistoryRetentionLeaseDuration (secondsToDiffTime 1))
        _ <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight
        threadDelay 1_200_000

        renewal <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId))
        renewal
          `shouldSatisfy` \case
            Left (VersionedRetentionRenewalFailed runId HistoryRetentionRenewalExpired) ->
              runId == request ^. #rebuildRunId
            _ -> False
        failed <- expectStore store (inspectVersionedRebuild (request ^. #rebuildRunId)) >>= requireRight
        failed ^. #phase `shouldBe` VersionedFailed
        runStatement store () expiredRetentionFactsStmt
          `shouldReturn` ("failed-versioned", True, False, "failed", "retention.renewal-failed")

      it "revalidates candidate DDL under the cutover locks and resumes after repair" $ \store -> do
        setupBridge store
        (catalog, physicalTargets) <- validatedBridgeFrom raceBridgeCatalog
        registerBridge store catalog
        runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
        let request = versionedRequest "versioned-ddl-race" physicalTargets
        handle <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight
        ready <- driveVersionedToCutoverReady store catalog (request ^. #rebuildRunId) 10
        ready ^. #phase `shouldBe` VersionedCutoverReplaying
        let counterCandidate =
              fromMaybe
                (error "counter candidate missing")
                (List.find ((== counterTargetId) . (^. #targetId)) (handle ^. #candidateGenerations))
        runScript
          store
          ( Text.Encoding.encodeUtf8
              ( "ALTER TABLE "
                  <> qualifyTable
                    (counterCandidate ^. #physicalTable . #schemaName)
                    (counterCandidate ^. #physicalTable . #tableName)
                  <> " ADD COLUMN rogue bigint"
              )
          )

        raced <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId))
        raced
          `shouldSatisfy` \case
            Left (VersionedObservedShapeMismatch targetId _ actual) ->
              targetId == counterTargetId && "rogue" `Text.isSuffixOf` actual
            _ -> False
        stillReady <- expectStore store (inspectVersionedRebuild (request ^. #rebuildRunId)) >>= requireRight
        stillReady ^. #phase `shouldBe` VersionedCutoverReplaying
        runStatement store () servingCountsStmt `shouldReturn` (0, 0)

        runScript
          store
          ( Text.Encoding.encodeUtf8
              ( "ALTER TABLE "
                  <> qualifyTable
                    (counterCandidate ^. #physicalTable . #schemaName)
                    (counterCandidate ^. #physicalTable . #tableName)
                  <> " DROP COLUMN rogue"
              )
          )
        repaired <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= requireRight
        repaired ^. #phase `shouldBe` VersionedPromoted

      it "previews retired blockers and drops only an unreferenced generation" $ \store -> do
        setupExternalBridge store
        runScript store retiredReaderSql
        (catalog, physicalTargets) <- validatedBridgeFrom compatibleExternalReadCatalog
        registerBridge store catalog
        runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
        let request = versionedRequest "versioned-retired-drop" physicalTargets
        _ <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight
        _ <- driveVersionedToPromotion store catalog (request ^. #rebuildRunId) 10
        retired <- expectStore store listVersionedRetiredGenerations
        length retired `shouldBe` 2
        let counterRetired =
              fromMaybe
                (error "retired counter generation missing")
                (List.find ((== counterTargetId) . (^. #targetId)) retired)

        contractBlocked <-
          expectStore store (previewVersionedRetiredDrop catalog (counterRetired ^. #generationId))
            >>= requireRight
        contractBlocked ^. #supportedReadContracts `shouldBe` ["counter_reader/v1"]
        contractBlocked ^. #droppable `shouldBe` False

        noContractCatalog <-
          fst <$> validatedBridgeFrom (runtimeBridgeCatalog {externalReadContracts = []})
        dependencyBlocked <-
          expectStore
            store
            (previewVersionedRetiredDrop noContractCatalog (counterRetired ^. #generationId))
            >>= requireRight
        dependencyBlocked ^. #supportedReadContracts `shouldBe` []
        dependencyBlocked ^. #externalDependencies `shouldSatisfy` (not . null)
        refused <-
          expectStore
            store
            (dropVersionedRetiredGeneration noContractCatalog (counterRetired ^. #generationId))
        refused
          `shouldSatisfy` \case
            Left (VersionedRetiredDropBlocked generationId blockers) ->
              generationId == counterRetired ^. #generationId
                && any ("postgres-dependency:" `Text.isPrefixOf`) blockers
            _ -> False

        runScript store "DROP VIEW app.retired_counter_reader"
        clear <-
          expectStore
            store
            (previewVersionedRetiredDrop noContractCatalog (counterRetired ^. #generationId))
            >>= requireRight
        clear ^. #droppable `shouldBe` True
        dropped <-
          expectStore
            store
            (dropVersionedRetiredGeneration noContractCatalog (counterRetired ^. #generationId))
            >>= requireRight
        dropped ^. #alreadyDropped `shouldBe` False
        runStatement store (counterRetired ^. #physicalTable) relationExistsStmt `shouldReturn` False
        secondDrop <-
          expectStore
            store
            (dropVersionedRetiredGeneration noContractCatalog (counterRetired ^. #generationId))
            >>= requireRight
        secondDrop ^. #alreadyDropped `shouldBe` True

  describe "schema-versioned cutover concurrency" $
    around (withFreshDatabase fixture) $ do
      it "bounds the whole lock phase, keeps readers on v1, and resumes promotion" $ \connectionString ->
        Store.withStore (Store.defaultConnectionSettings connectionString) $ \store ->
          withPool connectionString $ \pool -> do
            setupBridge store
            runScript store servingOnlyRowsSql
            (catalog, physicalTargets) <- validatedBridge
            registerBridge store catalog
            runStatement store ("catalog-async-subscription", 0) upsertSubscriptionCursorStmt
            let request =
                  versionedRequest "versioned-lock-timeout" physicalTargets
                    & #cutoverLockTimeoutMs
                    .~ 100
            handle <- expectStore store (beginVersionedRebuild catalog request) >>= requireRight
            ready <- driveVersionedToCutoverReady store catalog (request ^. #rebuildRunId) 10
            ready ^. #phase `shouldBe` VersionedCutoverReplaying

            readerDone <- newEmptyMVar
            _ <-
              forkIO $
                Pool.use
                  pool
                  ( TxSessions.transactionNoRetry
                      TxSessions.ReadCommitted
                      TxSessions.Write
                      ( do
                          counts <- Tx.statement () servingCountsStmt
                          Tx.sql "SELECT pg_sleep(1)"
                          pure counts
                      )
                  )
                  >>= putMVar readerDone
            waitForCounterReader pool 50

            timedOut <- Store.runStoreIO store (resumeVersionedRebuild catalog (request ^. #rebuildRunId))
            timedOut `shouldSatisfy` isLeft
            stillReady <- expectStore store (inspectVersionedRebuild (request ^. #rebuildRunId)) >>= requireRight
            stillReady ^. #phase `shouldBe` VersionedCutoverReplaying
            runStatement store () servingCountsStmt `shouldReturn` (1, 1)
            for_ (handle ^. #candidateGenerations) $ \generation ->
              rowCount store (generation ^. #physicalTable) `shouldReturn` 0

            readerCounts <- expectPoolUsage =<< takeMVar readerDone
            readerCounts `shouldBe` (1, 1)
            promoted <- expectStore store (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= requireRight
            promoted ^. #phase `shouldBe` VersionedPromoted
            runStatement store () servingCountsStmt `shouldReturn` (0, 0)

validatedBridge :: IO (ValidatedProjectionCatalog, PhysicalTargets)
validatedBridge = validatedBridgeFrom runtimeBridgeCatalog

validatedBridgeFrom :: ProjectionCatalog -> IO (ValidatedProjectionCatalog, PhysicalTargets)
validatedBridgeFrom catalogDefinition = do
  catalog <-
    case validateProjectionCatalog catalogDefinition of
      Failure diagnostics -> expectationFailure (show diagnostics) >> error "unreachable"
      Success validated -> pure validated
  physicalTargets <-
    case mkPhysicalTargets
      [counterTargetId, auditTargetId]
      ( Map.fromList
          [ (counterTargetId, QualifiedTable "app" "counter"),
            (auditTargetId, QualifiedTable "app" "counter_audit")
          ]
      ) of
      Left errors -> expectationFailure (show errors) >> error "unreachable"
      Right targets -> pure targets
  pure (catalog, physicalTargets)

runtimeBridgeCatalog :: ProjectionCatalog
runtimeBridgeCatalog =
  bridgeCatalog
    { projectionRevisions =
        [ runtimeRevision "v1" bridgeRevisionV1,
          runtimeRevision "v2" bridgeRevisionV2
        ],
      externalReadContracts = []
    }

compatibleExternalReadCatalog :: ProjectionCatalog
compatibleExternalReadCatalog =
  runtimeBridgeCatalog
    { externalReadContracts = [counterReadContract]
    }

breakingExternalReadCatalog :: ProjectionCatalog
breakingExternalReadCatalog = externalReadCatalogWith counterV1BreakingContract

compatibilityImplementationCatalog :: ProjectionCatalog
compatibilityImplementationCatalog = externalReadCatalogWith counterV1CompatibilityContract

externalReadCatalogWith :: ExternalReadContract -> ProjectionCatalog
externalReadCatalogWith v1Contract =
  runtimeBridgeCatalog
    { queryModels = runtimeBridgeCatalog ^. #queryModels <> [SomeQueryModelBinding counterV2Binding],
      externalReadContracts = [v1Contract, counterV2Contract]
    }

counterV2Binding :: QueryModelBinding Text ()
counterV2Binding =
  counterBinding
    { queryModelId = identity mkQueryModelId "catalog-counter-query-v2",
      readModel =
        (counterBinding ^. #readModel)
          { name = "catalog-counter-query-v2",
            version = 2,
            shapeHash = "catalog-counter-query-v2"
          }
    }

counterV1BreakingContract :: ExternalReadContract
counterV1BreakingContract =
  counterReadContract
    & #compatibleRevisions
    .~ (identity mkProjectionRevisionId "counter-v1" :| [])

counterV1CompatibilityContract :: ExternalReadContract
counterV1CompatibilityContract =
  KeyedExternalRead
    { readContractId = counterReadContract ^. #readContractId,
      contractVersion = counterReadContract ^. #contractVersion,
      queryModelId = counterReadContract ^. #queryModelId,
      arguments = [],
      resultContractType = counterReadContract ^. #resultContractType,
      privateImplementation = QualifiedFunction "app_private" "counter_v1_compat",
      privateImplementationVersion = 1,
      resultShapeHash = counterReadContract ^. #resultShapeHash,
      compatibleRevisions =
        identity mkProjectionRevisionId "counter-v1"
          :| [identity mkProjectionRevisionId "counter-v2"],
      surfaceGeneration = 1,
      claimSite = identity mkClaimSite "versioned:counter-v1-compatibility"
    }

counterV2Contract :: ExternalReadContract
counterV2Contract =
  AllRowsExternalRead
    { readContractId = counterReadContract ^. #readContractId,
      contractVersion = ExternalReadContractVersion 2,
      queryModelId = identity mkQueryModelId "catalog-counter-query-v2",
      resultContractType = QualifiedSqlType "app_contract" "counter_row_v2",
      resultShapeHash = "catalog-counter-query-v2",
      compatibleRevisions = identity mkProjectionRevisionId "counter-v2" :| [],
      surfaceGeneration = 2,
      claimSite = identity mkClaimSite "versioned:counter-reader-v2"
    }

runtimeV1OnlyCatalog :: ProjectionCatalog
runtimeV1OnlyCatalog =
  runtimeBridgeCatalog
    { projectionRevisions = [runtimeRevision "v1" bridgeRevisionV1],
      externalReadContracts = []
    }

cloneBridgeCatalog :: ProjectionCatalog
cloneBridgeCatalog =
  runtimeBridgeCatalog
    { projectionRevisions =
        [ runtimeRevision "v1" bridgeRevisionV1,
          runtimeRevision "v1" bridgeRevisionV2
        ]
    }

identityCloneBridgeCatalog :: ProjectionCatalog
identityCloneBridgeCatalog =
  cloneBridgeCatalog
    { projectionRevisions =
        [ revision
            & #targetProvisioners
            %~ Map.adjust identityCloneProvisioner counterTargetId
        | revision <- cloneBridgeCatalog ^. #projectionRevisions
        ]
    }

identityCloneProvisioner :: TargetProvisioner -> TargetProvisioner
identityCloneProvisioner provisioner =
  provisioner
    { validateTarget = Just (validateRuntimeTarget counterTargetId "v1" identityCloneObjects),
      promotionObjectNames = identityCloneObjects
    }

identityCloneObjects :: [PromotionObjectName]
identityCloneObjects =
  [ PromotionObjectName PromotionConstraint "counter_pkey__clone" "counter_pkey",
    PromotionObjectName PromotionOwnedSequence "counter_id_seq__clone" "counter_id_seq"
  ]

raceBridgeCatalog :: ProjectionCatalog
raceBridgeCatalog =
  replaceCandidateProvisionerInCatalog
    counterTargetId
    (\provisioner -> provisioner {validateTarget = Just validateRaceCounter})
    runtimeBridgeCatalog

validateRaceCounter ::
  TargetProvisioningContext ->
  Tx.Transaction (Either [TargetSchemaViolation] TargetSchemaEvidence)
validateRaceCounter targetContext = do
  baseline <- validateRuntimeTarget counterTargetId "v2" promotionObjects targetContext
  rogue <- Tx.statement (targetContext ^. #stagingTable) rogueColumnStmt
  pure $
    baseline <&> \evidence ->
      if rogue
        then evidence & #observedShapeFingerprint %~ (<> ":rogue")
        else evidence
  where
    promotionObjects =
      [PromotionObjectName PromotionIndex "counter_total_idx__v2" "counter_total_idx"]

runtimeRevision :: Text -> ProjectionRevision -> ProjectionRevision
runtimeRevision schema revision =
  revision
    & #targetProvisioners
    .~ Map.fromList
      [ (counterTargetId, counterProvisioner schema),
        (auditTargetId, auditProvisioner schema)
      ]
    & #liveHandlers
    .~ [ RevisionLiveHandler
           ("runtime-live-" <> schema)
           1
           [counterTargetId, auditTargetId]
           (applyRuntimeLive schema)
       ]
    & #replayAdapters
    .~ [ RevisionReplayAdapter
           ("runtime-replay-" <> schema)
           1
           [counterTargetId, auditTargetId]
           ( \physicalTargets event -> do
               applyRuntimeLive schema physicalTargets event
               pure (Right True)
           )
       ]

applyRuntimeLive :: Text -> PhysicalTargets -> RecordedEvent -> Tx.Transaction ()
applyRuntimeLive schema physicalTargets event = do
  let counterTable = requireTarget counterTargetId
      auditTable = requireTarget auditTargetId
      eventPosition = positionValue (event ^. #globalPosition)
      counterQualified = qualifyTable (counterTable ^. #schemaName) (counterTable ^. #tableName)
      auditQualified = qualifyTable (auditTable ^. #schemaName) (auditTable ^. #tableName)
  if schema == "v1"
    then do
      Tx.sql
        ( Text.Encoding.encodeUtf8
            ( "INSERT INTO "
                <> counterQualified
                <> " (id, total) VALUES ("
                <> Text.pack (show eventPosition)
                <> ", 10)"
            )
        )
      Tx.sql
        ( Text.Encoding.encodeUtf8
            ( "INSERT INTO "
                <> auditQualified
                <> " (id, detail) VALUES ("
                <> Text.pack (show eventPosition)
                <> ", 'v1')"
            )
        )
    else do
      Tx.sql
        ( Text.Encoding.encodeUtf8
            ( "INSERT INTO "
                <> counterQualified
                <> " (id, subtotal, tax) VALUES ("
                <> Text.pack (show eventPosition)
                <> ", 8, 2)"
            )
        )
      Tx.sql
        ( Text.Encoding.encodeUtf8
            ( "INSERT INTO "
                <> auditQualified
                <> " (id, detail, source_position) VALUES ("
                <> Text.pack (show eventPosition)
                <> ", 'v2', "
                <> Text.pack (show eventPosition)
                <> ")"
            )
        )
  where
    requireTarget targetId =
      fromMaybe
        (error ("runtime live handler missing target " <> show targetId))
        (resolvePhysicalTarget targetId physicalTargets)

positionValue :: GlobalPosition -> Int64
positionValue (GlobalPosition value) = value

recorded :: Int64 -> RecordedEvent
recorded value =
  RecordedEvent
    { eventId = EventId (UUID.fromWords64 7 (fromIntegral value)),
      eventType = EventType "VersionedDispatch",
      streamVersion = StreamVersion value,
      globalPosition = GlobalPosition value,
      originalStreamId = StreamId value,
      originalVersion = StreamVersion value,
      payload = Aeson.Null,
      metadata = Just (Aeson.object []),
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0)
    }

counterProvisioner :: Text -> TargetProvisioner
counterProvisioner schema =
  TargetProvisioner
    { provisionerId = "runtime-counter-" <> schema,
      provisionerVersion = 1,
      schemaVersion = TargetSchemaVersion schema,
      expectedShapeId = "runtime-counter-shape-" <> schema,
      provisionTarget =
        if schema == "v1"
          then \_ -> pure ()
          else createV2Counter,
      validatorId = "runtime-counter-validator-" <> schema,
      validatorVersion = 1,
      validateTarget = Just (validateRuntimeTarget counterTargetId schema promotionObjects),
      promotionObjectNames = promotionObjects
    }
  where
    promotionObjects =
      [PromotionObjectName PromotionIndex "counter_total_idx__v2" "counter_total_idx" | schema == "v2"]

auditProvisioner :: Text -> TargetProvisioner
auditProvisioner schema =
  TargetProvisioner
    { provisionerId = "runtime-audit-" <> schema,
      provisionerVersion = 1,
      schemaVersion = TargetSchemaVersion schema,
      expectedShapeId = "runtime-audit-shape-" <> schema,
      provisionTarget =
        if schema == "v1"
          then \_ -> pure ()
          else createV2Audit,
      validatorId = "runtime-audit-validator-" <> schema,
      validatorVersion = 1,
      validateTarget = Just (validateRuntimeTarget auditTargetId schema []),
      promotionObjectNames = []
    }

validateRuntimeTarget ::
  TargetId ->
  Text ->
  [PromotionObjectName] ->
  TargetProvisioningContext ->
  Tx.Transaction (Either [TargetSchemaViolation] TargetSchemaEvidence)
validateRuntimeTarget targetId schema promotionObjects targetContext = do
  maybeOid <- Tx.statement (targetContext ^. #stagingTable) relationOidStmt
  pure $ case maybeOid of
    Nothing -> Left [TargetSchemaViolation "relation.missing" (targetIdText targetId)]
    Just oid ->
      Right
        TargetSchemaEvidence
          { relationOid = oid,
            observedShapeFingerprint = "runtime-" <> targetIdText targetId <> "-shape-" <> schema,
            observedPromotionObjects = promotionObjects,
            catalogSnapshot = "runtime-catalog-snapshot-" <> schema
          }

createV2Counter :: TargetProvisioningContext -> Tx.Transaction ()
createV2Counter targetContext = do
  let table = targetContext ^. #stagingTable
      qualified = qualifyTable (table ^. #schemaName) (table ^. #tableName)
  Tx.sql
    ( Text.Encoding.encodeUtf8
        ( "CREATE TABLE "
            <> qualified
            <> " (id bigint PRIMARY KEY, subtotal bigint NOT NULL, tax bigint NOT NULL, total bigint GENERATED ALWAYS AS (subtotal + tax) STORED)"
        )
    )
  Tx.sql
    ( Text.Encoding.encodeUtf8
        ( "CREATE INDEX \"counter_total_idx__v2\" ON "
            <> qualified
            <> " (total)"
        )
    )

createV2Audit :: TargetProvisioningContext -> Tx.Transaction ()
createV2Audit targetContext = do
  let table = targetContext ^. #stagingTable
  Tx.sql
    ( Text.Encoding.encodeUtf8
        ( "CREATE TABLE "
            <> qualifyTable (table ^. #schemaName) (table ^. #tableName)
            <> " (id bigint PRIMARY KEY, detail text NOT NULL, source_position bigint NOT NULL)"
        )
    )

replaceCandidateProvisionerInCatalog ::
  TargetId ->
  (TargetProvisioner -> TargetProvisioner) ->
  ProjectionCatalog ->
  ProjectionCatalog
replaceCandidateProvisionerInCatalog targetId update catalog =
  catalog
    { projectionRevisions =
        [ if revision ^. #revisionId == identity mkProjectionRevisionId "counter-v2"
            then revision & #targetProvisioners %~ Map.adjust update targetId
            else revision
        | revision <- catalog ^. #projectionRevisions
        ]
    }

registerBridge :: Store.KirokuStore -> ValidatedProjectionCatalog -> IO ()
registerBridge store catalog = do
  result <- expectStore store (registerProjectionCatalog catalog)
  case result of
    Left err -> expectationFailure (show err)
    Right _ -> pure ()

versionedRequest :: Text -> PhysicalTargets -> VersionedRebuildRequest
versionedRequest identityText = rebuildRequestFor (run identityText)

rebuildRequestFor :: RebuildRunId -> PhysicalTargets -> VersionedRebuildRequest
rebuildRequestFor runId physicalTargets =
  VersionedRebuildRequest
    { rebuildRunId = runId,
      rebuildGroupId = mainGroupId,
      servingRevisionId = identity mkProjectionRevisionId "counter-v1",
      candidateRevisionId = identity mkProjectionRevisionId "counter-v2",
      servingTargets = physicalTargets,
      targetMode = ApplicationProvisioned,
      replayPageSize = 2,
      cutoverThreshold = 10,
      cutoverLockTimeoutMs = 2_000,
      retentionLeaseRequest = retentionRequest runId,
      requestedBy = "versioned-rebuild-spec",
      requestReason = "exercise M3 lifecycle persistence"
    }

retentionRequest :: RebuildRunId -> HistoryRetentionLeaseRequest
retentionRequest runId =
  HistoryRetentionLeaseRequest
    { owner = requireIdentity (mkHistoryRetentionLeaseOwner ("keiro-rebuild/" <> rebuildRunIdText runId)),
      reason = requireIdentity (mkHistoryRetentionLeaseReason "schema-versioned projection rebuild"),
      duration = requireIdentity (mkHistoryRetentionLeaseDuration (secondsToDiffTime 600))
    }

candidateTable :: RebuildRunId -> TargetId -> QualifiedTable
candidateTable runId targetId =
  QualifiedTable "app" ("keiro_g_" <> Text.filter (/= '-') (UUID.toText generationId))
  where
    generationId =
      UUID.V5.generateNamed
        UUID.V5.namespaceURL
        ( ByteString.unpack
            ( Text.Encoding.encodeUtf8
                ( Text.intercalate
                    "\NUL"
                    [ "keiro/versioned-candidate-generation/v1",
                      rebuildRunIdText runId,
                      rebuildGroupIdText mainGroupId,
                      targetIdText targetId
                    ]
                )
            )
        )

setupBridge :: Store.KirokuStore -> IO ()
setupBridge store = runScript store bridgeSql

setupExternalBridge :: Store.KirokuStore -> IO ()
setupExternalBridge store = runScript store externalBridgeSql

bridgeSql :: ByteString
bridgeSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (
    id bigint PRIMARY KEY,
    total bigint NOT NULL
  );
  CREATE TABLE app.counter_audit (
    id bigint PRIMARY KEY,
    detail text NOT NULL
  );
  """

externalBridgeSql :: ByteString
externalBridgeSql =
  bridgeSql
    <> """
       CREATE SCHEMA app_contract;
       CREATE TYPE app_contract.counter_row_v1 AS (id bigint, total bigint);
       CREATE TYPE app_contract.counter_row_v2 AS
         (id bigint, subtotal bigint, tax bigint, total bigint);
       CREATE SCHEMA app_private;
       CREATE FUNCTION app_private.counter_v1_compat()
       RETURNS SETOF app_contract.counter_row_v1
       LANGUAGE plpgsql
       STABLE
       AS $compatibility$
       BEGIN
         RETURN QUERY EXECUTE
           'SELECT counter.id, counter.total FROM app.counter AS counter ORDER BY counter.id';
       END
       $compatibility$;
       """

identityBridgeSql :: ByteString
identityBridgeSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (
    id bigint GENERATED BY DEFAULT AS IDENTITY,
    total bigint NOT NULL,
    CONSTRAINT counter_pkey PRIMARY KEY (id)
  );
  CREATE TABLE app.counter_audit (
    id bigint PRIMARY KEY,
    detail text NOT NULL
  );
  """

cloneTriggerSql :: ByteString
cloneTriggerSql =
  """
  CREATE FUNCTION app.clone_refusal_trigger() RETURNS trigger
  LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
  CREATE TRIGGER clone_refusal
    BEFORE INSERT ON app.counter
    FOR EACH ROW EXECUTE FUNCTION app.clone_refusal_trigger();
  """

retiredReaderSql :: ByteString
retiredReaderSql =
  "CREATE VIEW app.retired_counter_reader AS SELECT id, total FROM app.counter"

servingOnlyRowsSql :: ByteString
servingOnlyRowsSql =
  """
  INSERT INTO app.counter (id, total) VALUES (100, 42);
  INSERT INTO app.counter_audit (id, detail) VALUES (100, 'serving-v1');
  """

promoteDispatchMetadataSql :: ByteString
promoteDispatchMetadataSql =
  """
  UPDATE keiro.keiro_projection_target_generations
  SET lifecycle = 'retired', retired_at = now()
  WHERE group_id = 'counter-group' AND lifecycle = 'serving';

  UPDATE keiro.keiro_projection_target_generations AS generations
  SET lifecycle = 'serving', served_at = now()
  FROM keiro.keiro_projection_rebuild_run_targets AS targets
  WHERE targets.run_id = 'versioned-dispatch'
    AND targets.candidate_generation_id = generations.generation_id
    AND generations.lifecycle = 'staging';

  UPDATE keiro.keiro_projection_rebuild_runs
  SET status = 'promoted', history_retention_released_at = now(), updated_at = now()
  WHERE run_id = 'versioned-dispatch';

  UPDATE keiro.keiro_projection_rebuild_groups
  SET status = 'serving-versioned',
      active_run_id = NULL,
      serving_revision_id = 'counter-v2',
      serving_epoch = serving_epoch + 1,
      reads_allowed = TRUE,
      writes_allowed = TRUE,
      completed_at = now(),
      updated_at = now()
  WHERE group_id = 'counter-group';
  """

runScript :: Store.KirokuStore -> ByteString -> IO ()
runScript store sql = expectStore store (Store.runTransaction (Tx.sql sql))

runStatement :: Store.KirokuStore -> params -> Statement params result -> IO result
runStatement store params statement =
  expectStore store (Store.runTransaction (Tx.statement params statement))

withPool :: Text -> (Pool.Pool -> IO a) -> IO a
withPool connectionString =
  bracket
    ( Pool.acquire $
        PoolConfig.settings
          [ PoolConfig.staticConnectionSettings (ConnectionSettings.connectionString connectionString),
            PoolConfig.size 4
          ]
    )
    Pool.release

expectPoolUsage :: (Show error) => Either error value -> IO value
expectPoolUsage = \case
  Left err -> expectationFailure ("database action failed: " <> show err) >> error "unreachable"
  Right value -> pure value

waitForCounterReader :: Pool.Pool -> Int -> IO ()
waitForCounterReader _ 0 = expectationFailure "reader did not acquire ACCESS SHARE in time"
waitForCounterReader pool remaining = do
  locked <-
    expectPoolUsage
      =<< Pool.use pool (TxSessions.transactionNoRetry TxSessions.ReadCommitted TxSessions.Read (Tx.statement () counterAccessShareStmt))
  if locked
    then pure ()
    else threadDelay 20_000 >> waitForCounterReader pool (remaining - 1)

expectStore ::
  Store.KirokuStore ->
  Eff '[Store, Error StoreError, IOE] value ->
  IO value
expectStore store action =
  Store.runStoreIO store action >>= \case
    Left err -> expectationFailure (show err) >> error "unreachable"
    Right value -> pure value

requireRight :: (Show error) => Either error value -> IO value
requireRight = \case
  Left err -> expectationFailure (show err) >> error "unreachable"
  Right value -> pure value

hasSqlState :: (Show error) => String -> Either error value -> Bool
hasSqlState wanted = \case
  Left err -> wanted `List.isInfixOf` show err
  Right _ -> False

requireIdentity :: (Show error) => Either error value -> value
requireIdentity = either (error . show) id

identity :: (Text -> Either error value) -> Text -> value
identity constructor = either (error . const "invalid test identity") id . constructor

run :: Text -> RebuildRunId
run = either (error . Text.unpack) id . mkRebuildRunId

driveVersionedToPromotion ::
  Store.KirokuStore ->
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  Int ->
  IO VersionedRebuildReport
driveVersionedToPromotion store catalog runId attempts
  | attempts <= 0 = expectationFailure "versioned rebuild did not promote" >> error "unreachable"
  | otherwise = do
      report <- expectStore store (resumeVersionedRebuild catalog runId) >>= requireRight
      if report ^. #phase == VersionedPromoted
        then pure report
        else driveVersionedToPromotion store catalog runId (attempts - 1)

driveVersionedToCutoverReady ::
  Store.KirokuStore ->
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  Int ->
  IO VersionedRebuildReport
driveVersionedToCutoverReady store catalog runId attempts
  | attempts <= 0 = expectationFailure "versioned rebuild did not reach cutover" >> error "unreachable"
  | otherwise = do
      report <- expectStore store (resumeVersionedRebuild catalog runId) >>= requireRight
      if report ^. #phase == VersionedCutoverReplaying && allVersionedComplete (report ^. #sources)
        then pure report
        else driveVersionedToCutoverReady store catalog runId (attempts - 1)

allVersionedComplete :: [VersionedSourceProgress] -> Bool
allVersionedComplete =
  all (\source -> source ^. #exhaustedThrough == Just (source ^. #targetPosition))

appendVersionedEvents :: Store.KirokuStore -> Text -> Int -> IO ()
appendVersionedEvents store streamName count = do
  appended <-
    Store.runStoreIO store $
      Store.appendToStream
        (StreamName streamName)
        NoStream
        [ EventData
            { eventId = Nothing,
              eventType = EventType "VersionedDispatch",
              payload = Aeson.Null,
              metadata = Nothing,
              causationId = Nothing,
              correlationId = Nothing
            }
        | _ <- [1 .. count]
        ]
  appended `shouldSatisfy` isRight

relationOidFor :: Store.KirokuStore -> QualifiedTable -> IO Int64
relationOidFor store table = do
  result <- runStatement store table relationOidStmt
  maybe (expectationFailure "relation missing" >> error "unreachable") pure result

relationOidStmt :: Statement QualifiedTable (Maybe Int64)
relationOidStmt =
  preparable
    """
    SELECT classes.oid::bigint
    FROM pg_catalog.pg_class AS classes
    JOIN pg_catalog.pg_namespace AS namespaces
      ON namespaces.oid = classes.relnamespace
    WHERE namespaces.nspname = $1 AND classes.relname = $2
    """
    ( (\table -> (table ^. #schemaName, table ^. #tableName))
        >$< contrazip2
          (E.param (E.nonNullable E.text))
          (E.param (E.nonNullable E.text))
    )
    (D.rowMaybe (D.column (D.nonNullable D.int8)))

relationExistsStmt :: Statement QualifiedTable Bool
relationExistsStmt =
  preparable
    """
    SELECT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_class AS classes
      JOIN pg_catalog.pg_namespace AS namespaces
        ON namespaces.oid = classes.relnamespace
      WHERE namespaces.nspname = $1 AND classes.relname = $2
    )
    """
    ( (\table -> (table ^. #schemaName, table ^. #tableName))
        >$< contrazip2
          (E.param (E.nonNullable E.text))
          (E.param (E.nonNullable E.text))
    )
    (D.singleRow (D.column (D.nonNullable D.bool)))

rogueColumnStmt :: Statement QualifiedTable Bool
rogueColumnStmt =
  preparable
    """
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2 AND column_name = 'rogue'
    )
    """
    ( (\table -> (table ^. #schemaName, table ^. #tableName))
        >$< contrazip2
          (E.param (E.nonNullable E.text))
          (E.param (E.nonNullable E.text))
    )
    (D.singleRow (D.column (D.nonNullable D.bool)))

rowCount :: Store.KirokuStore -> QualifiedTable -> IO Int64
rowCount store table =
  runStatement store () $
    preparable
      ( "SELECT count(*) FROM "
          <> qualifyTable (table ^. #schemaName) (table ^. #tableName)
      )
      E.noParams
      (D.singleRow (D.column (D.nonNullable D.int8)))

servingCountsStmt :: Statement () (Int64, Int64)
servingCountsStmt =
  preparable
    """
    SELECT (SELECT count(*) FROM app.counter),
           (SELECT count(*) FROM app.counter_audit)
    """
    E.noParams
    ( D.singleRow
        ( (,)
            <$> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
        )
    )

externalV1RowsStmt :: Statement () [(Int64, Int64)]
externalV1RowsStmt =
  preparable
    "SELECT id, total FROM keiro_read.counter_reader_v1() ORDER BY id"
    E.noParams
    ( D.rowList
        ( (,)
            <$> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
        )
    )

externalV2RowsStmt :: Statement () [(Int64, Int64, Int64, Int64)]
externalV2RowsStmt =
  preparable
    "SELECT id, subtotal, tax, total FROM keiro_read.counter_reader_v2() ORDER BY id"
    E.noParams
    ( D.rowList
        ( (,,,)
            <$> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
        )
    )

counterAccessShareStmt :: Statement () Bool
counterAccessShareStmt =
  preparable
    """
    SELECT EXISTS (
      SELECT 1
      FROM pg_locks
      WHERE relation = 'app.counter'::regclass
        AND mode = 'AccessShareLock'
        AND granted
        AND pid <> pg_backend_pid()
    )
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

dispatchDedupCountStmt :: Statement () Int64
dispatchDedupCountStmt =
  preparable
    """
    SELECT count(*)
    FROM keiro.keiro_projection_dedup
    WHERE projection_name = 'catalog-async'
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.int8)))

convergeDedupCountStmt :: Statement () Int64
convergeDedupCountStmt = dispatchDedupCountStmt

expiredRetentionFactsStmt :: Statement () (Text, Bool, Bool, Text, Text)
expiredRetentionFactsStmt =
  preparable
    """
    SELECT groups.status, groups.reads_allowed, groups.writes_allowed,
           runs.status, runs.failure_code
    FROM keiro.keiro_projection_rebuild_groups AS groups
    JOIN keiro.keiro_projection_rebuild_runs AS runs
      ON runs.group_id = groups.group_id
    WHERE runs.run_id = 'versioned-expired-retention'
    """
    E.noParams
    ( D.singleRow
        ( (,,,,)
            <$> column D.text
            <*> column D.bool
            <*> column D.bool
            <*> column D.text
            <*> column D.text
        )
    )
  where
    column = D.column . D.nonNullable

upsertSubscriptionCursorStmt :: Statement (Text, Int64) ()
upsertSubscriptionCursorStmt =
  preparable
    """
    INSERT INTO subscriptions (subscription_name, stream_name, last_seen)
    VALUES ($1, '$all', $2)
    ON CONFLICT (subscription_name, consumer_group_member) DO UPDATE
      SET last_seen = EXCLUDED.last_seen,
          updated_at = now()
    """
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
    D.noResult

promotedLifecycleFactsStmt :: Statement () (Text, Bool, Bool, Text, Int64, Text, Int64, Int64, Int64)
promotedLifecycleFactsStmt =
  preparable
    """
    SELECT groups.status, groups.reads_allowed, groups.writes_allowed,
           groups.serving_revision_id, groups.serving_epoch, runs.status,
           (SELECT count(*) FROM keiro.keiro_projection_target_generations WHERE lifecycle = 'serving'),
           (SELECT count(*) FROM keiro.keiro_projection_target_generations WHERE lifecycle = 'retired'),
           (SELECT count(*) FROM kiroku.history_retention_leases WHERE released_at IS NOT NULL)
    FROM keiro.keiro_projection_rebuild_groups AS groups
    JOIN keiro.keiro_projection_rebuild_runs AS runs ON runs.group_id = groups.group_id
    WHERE runs.run_id = 'versioned-promote'
    """
    E.noParams
    ( D.singleRow
        ( (,,,,,,,,)
            <$> column D.text
            <*> column D.bool
            <*> column D.bool
            <*> column D.text
            <*> column D.int8
            <*> column D.text
            <*> column D.int8
            <*> column D.int8
            <*> column D.int8
        )
    )
  where
    column = D.column . D.nonNullable

promotedCounterShapeStmt :: Statement () Bool
promotedCounterShapeStmt =
  preparable
    """
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'app' AND table_name = 'counter'
        AND column_name = 'subtotal'
    )
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

cloneShapeStmt :: Statement () Bool
cloneShapeStmt =
  preparable
    """
    SELECT
      (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'app' AND table_name = 'counter') = 2
      AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'counter'
          AND column_name = 'total'
      )
      AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'counter'
          AND column_name = 'subtotal'
      )
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

identityCloneObjectsStmt :: Statement () Bool
identityCloneObjectsStmt =
  preparable
    """
    SELECT
      pg_catalog.pg_get_serial_sequence('app.counter', 'id') = 'app.counter_id_seq'
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conrelid = 'app.counter'::regclass
          AND conname = 'counter_pkey'
          AND contype = 'p'
      )
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

activeLifecycleFactsStmt :: Statement () (Text, Bool, Bool, Text, Int64, Int64, Int64, Int64, Int64)
activeLifecycleFactsStmt =
  preparable
    """
    SELECT groups.status, groups.reads_allowed, groups.writes_allowed,
           groups.serving_revision_id, groups.serving_epoch,
           (SELECT count(*) FROM keiro.keiro_projection_target_generations WHERE lifecycle = 'serving'),
           (SELECT count(*) FROM keiro.keiro_projection_target_generations WHERE lifecycle = 'staging'),
           (SELECT count(*) FROM keiro.keiro_projection_rebuild_runs WHERE rebuild_mode = 'versioned'),
           (SELECT count(*) FROM kiroku.history_retention_leases WHERE released_at IS NULL)
    FROM keiro.keiro_projection_rebuild_groups AS groups
    WHERE groups.group_id = 'counter-group'
    """
    E.noParams
    ( D.singleRow
        ( (,,,,,,,,)
            <$> column D.text
            <*> column D.bool
            <*> column D.bool
            <*> column D.text
            <*> column D.int8
            <*> column D.int8
            <*> column D.int8
            <*> column D.int8
            <*> column D.int8
        )
    )
  where
    column = D.column . D.nonNullable

rolledBackLifecycleFactsStmt :: Statement () (Text, Int64, Int64, Int64, Int64)
rolledBackLifecycleFactsStmt =
  preparable
    """
    SELECT groups.status,
           (SELECT count(*) FROM keiro.keiro_projection_target_generations),
           (SELECT count(*) FROM keiro.keiro_projection_rebuild_runs WHERE rebuild_mode = 'versioned'),
           (SELECT count(*) FROM kiroku.history_retention_leases),
           (SELECT count(*) FROM pg_catalog.pg_class AS classes JOIN pg_catalog.pg_namespace AS namespaces ON namespaces.oid = classes.relnamespace WHERE namespaces.nspname = 'app' AND classes.relname LIKE 'keiro_g_%')
    FROM keiro.keiro_projection_rebuild_groups AS groups
    WHERE groups.group_id = 'counter-group'
    """
    E.noParams
    ( D.singleRow
        ( (,,,,)
            <$> column D.text
            <*> column D.int8
            <*> column D.int8
            <*> column D.int8
            <*> column D.int8
        )
    )
  where
    column = D.column . D.nonNullable

collisionRollbackFactsStmt :: Statement () (Text, Int64, Int64, Int64, Int64)
collisionRollbackFactsStmt = rolledBackLifecycleFactsStmt

abandonedLifecycleFactsStmt :: Statement () (Text, Bool, Bool, Text, Int64, Int64, Int64)
abandonedLifecycleFactsStmt =
  preparable
    """
    SELECT groups.status, groups.reads_allowed, groups.writes_allowed, runs.status,
           (SELECT count(*) FROM keiro.keiro_projection_target_generations WHERE lifecycle = 'dropped'),
           (SELECT count(*) FROM kiroku.history_retention_leases WHERE released_at IS NOT NULL),
           (SELECT count(*) FROM keiro.keiro_projection_target_generations WHERE lifecycle = 'serving')
    FROM keiro.keiro_projection_rebuild_groups AS groups
    JOIN keiro.keiro_projection_rebuild_runs AS runs
      ON runs.group_id = groups.group_id
    WHERE runs.run_id = 'versioned-abandon'
    """
    E.noParams
    ( D.singleRow
        ( (,,,,,,)
            <$> column D.text
            <*> column D.bool
            <*> column D.bool
            <*> column D.text
            <*> column D.int8
            <*> column D.int8
            <*> column D.int8
        )
    )
  where
    column = D.column . D.nonNullable

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

isRight :: Either a b -> Bool
isRight = not . isLeft
