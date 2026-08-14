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
    counterTargetId,
    mainGroupId,
  )
import Contravariant.Extras (contrazip2)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Functor.Contravariant ((>$<))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Connection (qualifyTable)
import Keiro.Prelude
import Keiro.Projection (CatalogAsyncApplyOutcome (..), applyAsyncProjectionFromCatalog)
import Keiro.Projection.Catalog
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.HistoryRetention
  ( HistoryRetentionLeaseRequest (..),
    mkHistoryRetentionLeaseDuration,
    mkHistoryRetentionLeaseOwner,
    mkHistoryRetentionLeaseReason,
  )
import Kiroku.Store.Types
  ( EventId (..),
    EventType (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamVersion (..),
  )
import Test.Hspec

spec :: Fixture -> Spec
spec fixture =
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
        ]
    }

runtimeV1OnlyCatalog :: ProjectionCatalog
runtimeV1OnlyCatalog =
  runtimeBridgeCatalog
    { projectionRevisions = [runtimeRevision "v1" bridgeRevisionV1],
      readContractRevisionReferences = []
    }

runtimeRevision :: Text -> ProjectionRevision -> ProjectionRevision
runtimeRevision schema revision =
  revision
    { targetProvisioners =
        Map.fromList
          [ (counterTargetId, counterProvisioner schema),
            (auditTargetId, auditProvisioner schema)
          ],
      liveHandlers =
        [ RevisionLiveHandler
            ("runtime-live-" <> schema)
            1
            [counterTargetId, auditTargetId]
            (applyRuntimeLive schema)
        ],
      replayAdapters =
        [ RevisionReplayAdapter
            ("runtime-replay-" <> schema)
            1
            [counterTargetId, auditTargetId]
            ( \physicalTargets event -> do
                applyRuntimeLive schema physicalTargets event
                pure (Right True)
            )
        ]
    }

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

requireIdentity :: (Show error) => Either error value -> value
requireIdentity = either (error . show) id

identity :: (Text -> Either error value) -> Text -> value
identity constructor = either (error . const "invalid test identity") id . constructor

run :: Text -> RebuildRunId
run = either (error . Text.unpack) id . mkRebuildRunId

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
