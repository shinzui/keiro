module Jitsurei.ReadModels
  ( OrderSummaryQuery (..),
    OrderSummary (..),
    jitsureiProjectionSchema,
    orderSummaryReadModel,
    orderSummaryInlineProjection,
    orderAuditAsyncProjection,
    orderProjectionSet,
    orderLiveProjections,
    orderSummaryProjectionId,
    orderAuditProjectionId,
    orderReportingGroupId,
    orderReportingRevisionV1,
    orderReportingRevisionV2,
    jitsureiProjectionCatalog,
    orderCatalogOperations,
    initializeOrderSummaryTable,
    selectOrderSummaryStmt,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Jitsurei.Domain
import Jitsurei.OrderStream (orderCodec)
import Keiro.Codec (decodeRecorded)
import Keiro.Connection (qualifyTable, quoteIdentifier)
import Keiro.Prelude
import Keiro.Projection (AsyncProjection (..), InlineProjection (..))
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog.Operations (ProjectionCatalogOperations, projectionCatalogOperations)
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), StrongScope (..))
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (FromBeginning))
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent, StreamName (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

-- | The user's explicit choice of where the jitsurei projection tables live —
-- deliberately a dedicated application schema, not the event store's @kiroku@
-- schema. This is the point of MasterPlan 12's configurable projection schema:
-- application read-model data is cleanly separated from the event store.
jitsureiProjectionSchema :: Text
jitsureiProjectionSchema = "jitsurei"

-- | The fully-qualified, double-quoted order-summary table reference
-- (@"jitsurei"."jitsurei_order_summary"@) interpolated into every DDL/DML
-- statement below, so all reads and writes are correct regardless of
-- @search_path@.
orderSummaryTable :: Text
orderSummaryTable = qualifyTable jitsureiProjectionSchema "jitsurei_order_summary"

orderLineTable :: Text
orderLineTable = qualifyTable jitsureiProjectionSchema "jitsurei_order_line"

orderAuditTable :: Text
orderAuditTable = qualifyTable jitsureiProjectionSchema "jitsurei_order_async_audit"

orderSideEffectTable :: Text
orderSideEffectTable = qualifyTable jitsureiProjectionSchema "jitsurei_order_live_side_effect"

newtype OrderSummaryQuery = OrderSummaryQuery OrderId
  deriving stock (Generic, Eq, Show)

data OrderSummary = OrderSummary
  { orderId :: !OrderId,
    sku :: !Sku,
    quantity :: !Quantity,
    status :: !Text,
    lastSeen :: !GlobalPosition
  }
  deriving stock (Generic, Eq, Show)

orderSummaryReadModel :: ReadModel OrderSummaryQuery (Maybe OrderSummary)
orderSummaryReadModel =
  ReadModel
    { name = "jitsurei-order-summary",
      tableName = "jitsurei_order_summary",
      schema = jitsureiProjectionSchema,
      subscriptionName = "jitsurei-order-summary-inline",
      version = 1,
      shapeHash = "jitsurei-order-summary-v1",
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \(OrderSummaryQuery orderId) ->
        Tx.statement (orderIdText orderId) selectOrderSummaryStmt
    }

orderSummaryReadModelV2 :: ReadModel OrderSummaryQuery (Maybe OrderSummary)
orderSummaryReadModelV2 =
  orderSummaryReadModel
    { name = "jitsurei-order-summary-v2",
      version = 2,
      shapeHash = "jitsurei-order-summary-v2"
    }

orderSummaryInlineProjection :: InlineProjection OrderEvent
orderSummaryInlineProjection =
  InlineProjection
    { name = "jitsurei-order-summary-inline",
      apply = applyOrderEventLive
    }

orderAuditAsyncProjection :: AsyncProjection
orderAuditAsyncProjection =
  AsyncProjection
    { name = "jitsurei-order-audit-async",
      readModelName = orderSummaryReadModel ^. #name,
      subscriptionName = "jitsurei-order-audit-subscription",
      applyRecorded = \recorded ->
        case decodeRecorded orderCodec recorded of
          Left _ -> Tx.condemn
          Right event -> applyOrderAuditEvent event recorded,
      idempotencyKey = (^. #eventId)
    }

applyOrderEventLive :: OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderEventLive event recorded = do
  applyOrderEventForReplay event recorded
  Tx.statement
    ( globalPositionToInt (recorded ^. #globalPosition),
      eventStatus event
    )
    insertLiveSideEffectStmt

applyOrderEventForReplay :: OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderEventForReplay event recorded =
  case event of
    OrderPlaced payload -> do
      Tx.statement
        ( orderIdText payload.orderId,
          skuText payload.sku,
          Prelude.fromIntegral (quantityInt payload.quantity),
          "placed",
          globalPositionToInt (recorded ^. #globalPosition)
        )
        upsertOrderSummaryStmt
      Tx.statement
        ( orderIdText payload.orderId,
          skuText payload.sku,
          Prelude.fromIntegral (quantityInt payload.quantity),
          globalPositionToInt (recorded ^. #globalPosition)
        )
        upsertOrderLineStmt
    PaymentApproved payload ->
      updateStatus payload.orderId "paid" recorded
    OrderPacked payload ->
      updateStatus payload.orderId "packed" recorded
    OrderShipped payload ->
      updateStatus payload.orderId "shipped" recorded
    OrderCancelled payload ->
      updateStatus payload.orderId "cancelled" recorded

applyOrderAuditEvent :: OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderAuditEvent event recorded =
  Tx.statement
    ( globalPositionToInt (recorded ^. #globalPosition),
      eventStatus event
    )
    upsertOrderAuditStmt

eventStatus :: OrderEvent -> Text
eventStatus = \case
  OrderPlaced {} -> "placed"
  PaymentApproved {} -> "paid"
  OrderPacked {} -> "packed"
  OrderShipped {} -> "shipped"
  OrderCancelled {} -> "cancelled"

orderProjectionSet :: ProjectionSet OrderEvent
orderProjectionSet =
  ProjectionSet
    { projectionSource = orderSourceId,
      projectionDefinitions = orderSummaryDefinition :| [orderAuditDefinition],
      claimSite = claim "jitsurei:order-projection-set"
    }

orderSummaryDefinition :: ProjectionDefinition OrderEvent
orderSummaryDefinition =
  ProjectionDefinition
    { projectionId = orderSummaryProjectionId,
      rebuildGroup = orderReportingGroupId,
      ownedTargets = orderSummaryTargetId :| [orderLineTargetId],
      replayPolicy = Replayable (replayAdapterFromCodec orderCodec applyOrderEventForReplay),
      handlers = InlineHandler orderSummaryInlineProjection (claim "jitsurei:order-summary-inline") :| [],
      claimSite = claim "jitsurei:order-summary-owner"
    }

orderAuditDefinition :: ProjectionDefinition OrderEvent
orderAuditDefinition =
  ProjectionDefinition
    { projectionId = orderAuditProjectionId,
      rebuildGroup = orderReportingGroupId,
      ownedTargets = orderAuditTargetId :| [],
      replayPolicy = Replayable (replayAdapterFromCodec orderCodec applyOrderAuditEvent),
      handlers =
        AsyncHandler orderAuditAsyncProjection orderAuditSubscriptionId orderAuditDedupId (claim "jitsurei:order-audit-async")
          :| [],
      claimSite = claim "jitsurei:order-audit-owner"
    }

jitsureiProjectionCatalog :: ValidatedProjectionCatalog
jitsureiProjectionCatalog =
  case validateProjectionCatalog jitsureiProjectionCatalogDefinition of
    Failure diagnostics -> error ("invalid jitsurei projection catalog: " <> show diagnostics)
    Success catalog -> catalog

jitsureiProjectionCatalogDefinition :: ProjectionCatalog
jitsureiProjectionCatalogDefinition =
  ProjectionCatalog
    { sources =
        [ SourceDeclaration
            { sourceId = orderSourceId,
              sourceScope = CategorySource (CategoryName "order"),
              codecFingerprint = "jitsurei/order-codec/v2",
              claimSite = claim "jitsurei:order-source"
            }
        ],
      targets =
        [ TargetDeclaration
            { targetId = orderSummaryTargetId,
              qualifiedTable = QualifiedTable jitsureiProjectionSchema "jitsurei_order_summary",
              resetPolicy = PreserveAndReconcile,
              dependsOn = [],
              claimSite = claim "jitsurei:order-summary-target"
            },
          TargetDeclaration
            { targetId = orderLineTargetId,
              qualifiedTable = QualifiedTable jitsureiProjectionSchema "jitsurei_order_line",
              resetPolicy = ClearBeforeReplay,
              dependsOn = [orderSummaryTargetId],
              claimSite = claim "jitsurei:order-line-target"
            },
          TargetDeclaration
            { targetId = orderAuditTargetId,
              qualifiedTable = QualifiedTable jitsureiProjectionSchema "jitsurei_order_async_audit",
              resetPolicy = ClearBeforeReplay,
              dependsOn = [orderSummaryTargetId],
              claimSite = claim "jitsurei:order-audit-target"
            }
        ],
      rebuildGroups =
        [ RebuildGroupDeclaration
            { rebuildGroupId = orderReportingGroupId,
              orderedTargets = [orderSummaryTargetId, orderLineTargetId, orderAuditTargetId],
              verificationHooks =
                [ RebuildVerification
                    { verificationId = "order-lines-and-brownfield-roots-valid",
                      verificationVersion = "v1",
                      verifyRebuild = do
                        valid <- Tx.statement () verifyOrderLinesStmt
                        pure (if valid then Right () else Left "order lines or preserved brownfield roots require repair")
                    }
                ],
              claimSite = claim "jitsurei:order-reporting-group"
            }
        ],
      projectionRevisions = [orderReportingRevisionV1, orderReportingRevisionV2],
      externalReadContracts =
        [ orderSummaryExternalReadV1,
          orderSummaryExternalReadV2
        ],
      subscriptions =
        [ SubscriptionDeclaration
            { subscriptionId = orderAuditSubscriptionId,
              subscriptionName = orderAuditAsyncProjection ^. #subscriptionName,
              subscriptionSource = orderSourceId,
              checkpointOnMissing = FromBeginning,
              claimSite = claim "jitsurei:order-audit-subscription"
            }
        ],
      dedupKeys =
        [ DedupKeyDeclaration
            { dedupKeyId = orderAuditDedupId,
              dedupName = orderAuditAsyncProjection ^. #name,
              claimSite = claim "jitsurei:order-audit-dedup"
            }
        ],
      queryModels =
        [ SomeQueryModelBinding
            QueryModelBinding
              { queryModelId = orderSummaryQueryModelId,
                readModel = orderSummaryReadModel,
                rebuildGroup = orderReportingGroupId,
                observedTargets = [orderSummaryTargetId],
                claimSite = claim "jitsurei:order-summary-query"
              },
          SomeQueryModelBinding
            QueryModelBinding
              { queryModelId = orderSummaryQueryModelV2Id,
                readModel = orderSummaryReadModelV2,
                rebuildGroup = orderReportingGroupId,
                observedTargets = [orderSummaryTargetId],
                claimSite = claim "jitsurei:order-summary-query-v2"
              }
        ],
      projectionSets = [SomeProjectionSet orderProjectionSet]
    }

-- | A bridge catalog keeps both sides of a schema rollout in one binary. The
-- versioned lifecycle invokes these application-owned closures with serving or
-- staging physical targets. V2 deliberately renames @status@ to @state@ and
-- adds a revision marker, so this is a genuinely incompatible schema.
orderReportingRevisionV1, orderReportingRevisionV2 :: ProjectionRevision
orderReportingRevisionV1 = orderReportingRevision "jitsurei-order-reporting-v1" "v1"
orderReportingRevisionV2 = orderReportingRevision "jitsurei-order-reporting-v2" "v2"

orderSummaryExternalReadV1, orderSummaryExternalReadV2 :: ExternalReadContract
orderSummaryExternalReadV1 =
  AllRowsExternalRead
    { readContractId = orderSummaryExternalReadContractId,
      contractVersion = ExternalReadContractVersion 1,
      queryModelId = orderSummaryQueryModelId,
      resultContractType = QualifiedSqlType "jitsurei_contract" "order_summary_v1",
      resultShapeHash = "jitsurei-order-summary-v1",
      compatibleRevisions = orderReportingRevisionV1 ^. #revisionId :| [],
      surfaceGeneration = 1,
      claimSite = claim "jitsurei:order-summary-external-v1"
    }
orderSummaryExternalReadV2 =
  AllRowsExternalRead
    { readContractId = orderSummaryExternalReadContractId,
      contractVersion = ExternalReadContractVersion 2,
      queryModelId = orderSummaryQueryModelV2Id,
      resultContractType = QualifiedSqlType "jitsurei_contract" "order_summary_v2",
      resultShapeHash = "jitsurei-order-summary-v2",
      compatibleRevisions = orderReportingRevisionV2 ^. #revisionId :| [],
      surfaceGeneration = 2,
      claimSite = claim "jitsurei:order-summary-external-v2"
    }

orderReportingRevision :: Text -> Text -> ProjectionRevision
orderReportingRevision identity schemaVersion =
  ProjectionRevision
    { revisionId = identityOrError mkProjectionRevisionId identity,
      rebuildGroup = orderReportingGroupId,
      targetProvisioners =
        Map.fromList
          [ (targetId, exampleProvisioner targetName)
          | (targetId, targetName) <-
              [ (orderSummaryTargetId, "order-summary"),
                (orderLineTargetId, "order-line"),
                (orderAuditTargetId, "order-audit")
              ]
          ],
      liveHandlers =
        [ RevisionLiveHandler
            { handlerId = identity <> "/live",
              handlerVersion = 1,
              requiredTargets = orderReportingTargetIds,
              runRevisionLive = applyRevisionRecorded schemaVersion
            }
        ],
      replayAdapters =
        [ RevisionReplayAdapter
            { adapterId = identity <> "/replay",
              adapterVersion = 1,
              requiredTargets = orderReportingTargetIds,
              runRevisionReplay = replayRevisionRecorded schemaVersion
            }
        ],
      revisionVerifications =
        [ RevisionVerification
            { revisionVerificationId = identity <> "/verification",
              revisionVerificationVersion = 1,
              requiredTargets = orderReportingTargetIds,
              runRevisionVerification = verifyRevisionTargets
            }
        ],
      streamScopedReplays = [orderSummaryStreamReplay identity schemaVersion],
      claimSite = claim ("jitsurei:" <> identity)
    }
  where
    exampleProvisioner targetName =
      TargetProvisioner
        { provisionerId = identity <> "/" <> targetName <> "/provision",
          provisionerVersion = 1,
          schemaVersion = TargetSchemaVersion schemaVersion,
          expectedShapeId = identity <> "/" <> targetName <> "/shape",
          provisionTarget = provisionRevisionTarget schemaVersion targetName,
          validatorId = identity <> "/" <> targetName <> "/validate",
          validatorVersion = 1,
          validateTarget = Just (validateRevisionTarget identity targetName promotionObjects),
          promotionObjectNames = promotionObjects
        }
      where
        promotionObjects = [primaryKeyPromotion schemaVersion targetName]

primaryKeyPromotion :: Text -> Text -> PromotionObjectName
primaryKeyPromotion schemaVersion targetName =
  PromotionObjectName
    PromotionConstraint
    (if schemaVersion == "v1" then canonical else canonical <> "__v2")
    canonical
  where
    canonical = case targetName of
      "order-summary" -> "jitsurei_order_summary_pkey"
      "order-line" -> "jitsurei_order_line_pkey"
      "order-audit" -> "jitsurei_order_async_audit_pkey"
      _ -> error ("unknown Jitsurei promotion target: " <> Text.unpack targetName)

provisionRevisionTarget :: Text -> Text -> TargetProvisioningContext -> Tx.Transaction ()
provisionRevisionTarget "v1" _ _ = pure ()
provisionRevisionTarget _ targetName context =
  Tx.sql (TE.encodeUtf8 ddl)
  where
    table = context ^. #stagingTable
    qualified = qualifyTable (table ^. #schemaName) (table ^. #tableName)
    constraint = quoteIdentifier (primaryKeyPromotion "v2" targetName ^. #generationName)
    ddl =
      case targetName of
        "order-summary" ->
          "CREATE TABLE "
            <> qualified
            <> " (order_id text NOT NULL, sku text NOT NULL, quantity bigint NOT NULL, state text NOT NULL, last_seen bigint NOT NULL, source_revision smallint NOT NULL DEFAULT 2, CONSTRAINT "
            <> constraint
            <> " PRIMARY KEY (order_id))"
        "order-line" ->
          "CREATE TABLE "
            <> qualified
            <> " (order_id text NOT NULL, line_no integer NOT NULL, sku text NOT NULL, quantity bigint NOT NULL, last_seen bigint NOT NULL, source_revision smallint NOT NULL DEFAULT 2, CONSTRAINT "
            <> constraint
            <> " PRIMARY KEY (order_id, line_no))"
        "order-audit" ->
          "CREATE TABLE "
            <> qualified
            <> " (global_position bigint NOT NULL, state text NOT NULL, source_revision smallint NOT NULL DEFAULT 2, CONSTRAINT "
            <> constraint
            <> " PRIMARY KEY (global_position))"
        _ -> error ("unknown Jitsurei revision target: " <> Text.unpack targetName)

validateRevisionTarget :: Text -> Text -> [PromotionObjectName] -> TargetProvisioningContext -> Tx.Transaction (Either [TargetSchemaViolation] TargetSchemaEvidence)
validateRevisionTarget identity targetName promotionObjects context = do
  maybeOid <-
    Tx.statement
      (context ^. #stagingTable . #schemaName, context ^. #stagingTable . #tableName)
      revisionRelationOidStmt
  pure $ case maybeOid of
    Nothing -> Left [TargetSchemaViolation "relation.missing" targetName]
    Just oid ->
      Right
        TargetSchemaEvidence
          { relationOid = oid,
            observedShapeFingerprint = identity <> "/" <> targetName <> "/shape",
            observedPromotionObjects = promotionObjects,
            catalogSnapshot = "jitsurei-schema-bridge/" <> identity <> "/" <> targetName
          }

verifyRevisionTargets :: PhysicalTargets -> Tx.Transaction (Either Text ())
verifyRevisionTargets targets = do
  present <-
    traverse
      ( \targetId ->
          let table = requirePhysicalTarget targetId targets
           in Tx.statement (table ^. #schemaName, table ^. #tableName) revisionRelationOidStmt
      )
      orderReportingTargetIds
  pure $ if Prelude.all isJust present then Right () else Left "one or more revision targets are missing"

applyRevisionRecorded :: Text -> PhysicalTargets -> RecordedEvent -> Tx.Transaction ()
applyRevisionRecorded schemaVersion targets recorded =
  case decodeRecorded orderCodec recorded of
    Left _ -> Tx.condemn
    Right event -> applyRevisionEvent schemaVersion targets event recorded

replayRevisionRecorded :: Text -> PhysicalTargets -> RecordedEvent -> Tx.Transaction (Either ReplayDecodeError Bool)
replayRevisionRecorded schemaVersion targets recorded =
  case decodeRecorded orderCodec recorded of
    Left err -> pure (Left (ReplayDecodeError (Text.pack (show err))))
    Right event -> applyRevisionEvent schemaVersion targets event recorded >> pure (Right True)

orderSummaryStreamReplay :: Text -> Text -> StreamScopedReplay
orderSummaryStreamReplay identity schemaVersion =
  StreamScopedReplay
    { streamProjectionId = orderSummaryProjectionId,
      streamOwnedTargets = orderSummaryTargetId :| [orderLineTargetId],
      clearerId = identity <> "/order-summary/clear-stream",
      clearerVersion = 1,
      clearStreamRows = \targets stream ->
        case orderIdFromStream stream of
          Nothing -> pure (Left "expected an order-<id> stream")
          Just orderId -> do
            lineRows <- Tx.statement orderId (deleteRevisionOrderRowsStmt (requirePhysicalTarget orderLineTargetId targets))
            summaryRows <- Tx.statement orderId (deleteRevisionOrderRowsStmt (requirePhysicalTarget orderSummaryTargetId targets))
            pure
              ( Right
                  [ StreamClearCount orderSummaryTargetId summaryRows,
                    StreamClearCount orderLineTargetId lineRows
                  ]
              ),
      streamReplayId = identity <> "/order-summary/replay-stream",
      streamReplayVersion = 1,
      replayStreamEvent = \targets recorded ->
        case decodeRecorded orderCodec recorded of
          Left err -> pure (Left (ReplayDecodeError (Text.pack (show err))))
          Right event -> applyRevisionOrderRows schemaVersion targets event recorded >> pure (Right True),
      streamVerificationId = identity <> "/order-summary/verify-stream",
      streamVerificationVersion = 1,
      verifyStreamRows = \targets stream ->
        case orderIdFromStream stream of
          Nothing -> pure (Left "expected an order-<id> stream")
          Just orderId -> do
            summaries <- Tx.statement orderId (countRevisionOrderRowsStmt (requirePhysicalTarget orderSummaryTargetId targets))
            lines <- Tx.statement orderId (countRevisionOrderRowsStmt (requirePhysicalTarget orderLineTargetId targets))
            pure
              ( if summaries == 1 Prelude.&& lines == 1
                  then Right ()
                  else Left "targeted order repair must leave one summary and one line"
              ),
      affectedAsyncDedup = [],
      claimSite = claim ("jitsurei:" <> identity <> "/order-summary-stream-replay")
    }

orderIdFromStream :: StreamName -> Maybe Text
orderIdFromStream (StreamName name) = Text.stripPrefix "order-" name

applyRevisionEvent :: Text -> PhysicalTargets -> OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyRevisionEvent schemaVersion targets event recorded = do
  applyRevisionOrderRows schemaVersion targets event recorded
  let audit = requirePhysicalTarget orderAuditTargetId targets
      position = globalPositionToInt (recorded ^. #globalPosition)
  Tx.statement (position, eventStatus event) (revisionUpsertAuditStmt schemaVersion audit)

applyRevisionOrderRows :: Text -> PhysicalTargets -> OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyRevisionOrderRows schemaVersion targets event recorded =
  case event of
    OrderPlaced payload -> do
      Tx.statement
        ( orderIdText payload.orderId,
          skuText payload.sku,
          Prelude.fromIntegral (quantityInt payload.quantity),
          "placed",
          position
        )
        (revisionUpsertSummaryStmt schemaVersion summary)
      Tx.statement
        ( orderIdText payload.orderId,
          skuText payload.sku,
          Prelude.fromIntegral (quantityInt payload.quantity),
          position
        )
        (revisionUpsertLineStmt schemaVersion line)
    PaymentApproved payload -> updateRevisionStatus payload.orderId "paid"
    OrderPacked payload -> updateRevisionStatus payload.orderId "packed"
    OrderShipped payload -> updateRevisionStatus payload.orderId "shipped"
    OrderCancelled payload -> updateRevisionStatus payload.orderId "cancelled"
  where
    summary = requirePhysicalTarget orderSummaryTargetId targets
    line = requirePhysicalTarget orderLineTargetId targets
    position = globalPositionToInt (recorded ^. #globalPosition)
    updateRevisionStatus orderId status =
      Tx.statement
        (orderIdText orderId, status, position)
        (revisionUpdateSummaryStmt schemaVersion summary)

requirePhysicalTarget :: TargetId -> PhysicalTargets -> QualifiedTable
requirePhysicalTarget targetId targets =
  fromMaybe
    (error ("missing Jitsurei revision target: " <> show targetId))
    (resolvePhysicalTarget targetId targets)

orderReportingTargetIds :: [TargetId]
orderReportingTargetIds = [orderSummaryTargetId, orderLineTargetId, orderAuditTargetId]

orderLiveProjections :: [InlineProjection OrderEvent]
orderLiveProjections = typedInlineProjections jitsureiProjectionCatalog orderProjectionSet

orderCatalogOperations :: ProjectionCatalogOperations
orderCatalogOperations = projectionCatalogOperations jitsureiProjectionCatalog

orderSummaryProjectionId, orderAuditProjectionId :: ProjectionId
orderSummaryProjectionId = identityOrError mkProjectionId "jitsurei-order-summary"
orderAuditProjectionId = identityOrError mkProjectionId "jitsurei-order-audit"

orderSummaryTargetId, orderLineTargetId, orderAuditTargetId :: TargetId
orderSummaryTargetId = identityOrError mkTargetId "jitsurei-order-summary"
orderLineTargetId = identityOrError mkTargetId "jitsurei-order-line"
orderAuditTargetId = identityOrError mkTargetId "jitsurei-order-async-audit"

orderReportingGroupId :: RebuildGroupId
orderReportingGroupId = identityOrError mkRebuildGroupId "jitsurei-order-reporting"

orderSourceId :: SourceId
orderSourceId = identityOrError mkSourceId "jitsurei-order-events"

orderSummaryQueryModelId :: QueryModelId
orderSummaryQueryModelId = identityOrError mkQueryModelId "jitsurei-order-summary-query"

orderSummaryQueryModelV2Id :: QueryModelId
orderSummaryQueryModelV2Id = identityOrError mkQueryModelId "jitsurei-order-summary-query-v2"

orderSummaryExternalReadContractId :: ExternalReadContractId
orderSummaryExternalReadContractId =
  identityOrError mkExternalReadContractId "jitsurei_order_summary_reader"

orderAuditSubscriptionId :: SubscriptionId
orderAuditSubscriptionId = identityOrError mkSubscriptionId "jitsurei-order-audit-subscription"

orderAuditDedupId :: DedupKeyId
orderAuditDedupId = identityOrError mkDedupKeyId "jitsurei-order-audit-dedup"

claim :: Text -> ClaimSite
claim = identityOrError mkClaimSite

identityOrError :: (Text -> Either CatalogIdentityError identity) -> Text -> identity
identityOrError constructor value =
  case constructor value of
    Left err -> error (Text.unpack ("invalid jitsurei catalog identity: " <> Text.pack (show err)))
    Right identity -> identity

updateStatus :: OrderId -> Text -> RecordedEvent -> Tx.Transaction ()
updateStatus orderId status recorded =
  Tx.statement
    ( orderIdText orderId,
      status,
      globalPositionToInt (recorded ^. #globalPosition)
    )
    updateOrderSummaryStatusStmt

-- | Create the application projection schema (opt-in, app-owned) and the
-- order-summary read-model table, fully qualified into that schema. 'Tx.sql' runs
-- a multi-statement, parameter-free script, so the @CREATE SCHEMA@ and
-- @CREATE TABLE@ share one call. Both are idempotent (@IF NOT EXISTS@).
initializeOrderSummaryTable :: Tx.Transaction ()
initializeOrderSummaryTable =
  Tx.sql
    $ TE.encodeUtf8
    $ "CREATE SCHEMA IF NOT EXISTS "
    <> quoteIdentifier jitsureiProjectionSchema
    <> ";\n"
    <> "CREATE SCHEMA IF NOT EXISTS jitsurei_contract;\n"
    <> "DO $jitsurei_contracts$\n"
    <> "BEGIN\n"
    <> "  IF pg_catalog.to_regtype('jitsurei_contract.order_summary_v1') IS NULL THEN\n"
    <> "    CREATE TYPE jitsurei_contract.order_summary_v1 AS (order_id text, sku text, quantity bigint, status text, last_seen bigint);\n"
    <> "  END IF;\n"
    <> "  IF pg_catalog.to_regtype('jitsurei_contract.order_summary_v2') IS NULL THEN\n"
    <> "    CREATE TYPE jitsurei_contract.order_summary_v2 AS (order_id text, sku text, quantity bigint, state text, last_seen bigint, source_revision smallint);\n"
    <> "  END IF;\n"
    <> "END\n"
    <> "$jitsurei_contracts$;\n"
    <> "CREATE TABLE IF NOT EXISTS "
    <> orderSummaryTable
    <> " (\n"
    <> "  order_id TEXT PRIMARY KEY,\n"
    <> "  sku TEXT NOT NULL,\n"
    <> "  quantity BIGINT NOT NULL,\n"
    <> "  status TEXT NOT NULL,\n"
    <> "  last_seen BIGINT NOT NULL\n"
    <> ");\n"
    <> "CREATE TABLE IF NOT EXISTS "
    <> orderLineTable
    <> " (\n"
    <> "  order_id TEXT NOT NULL REFERENCES "
    <> orderSummaryTable
    <> "(order_id),\n"
    <> "  line_no INTEGER NOT NULL,\n"
    <> "  sku TEXT NOT NULL,\n"
    <> "  quantity BIGINT NOT NULL,\n"
    <> "  last_seen BIGINT NOT NULL,\n"
    <> "  PRIMARY KEY (order_id, line_no)\n"
    <> ");\n"
    <> "CREATE TABLE IF NOT EXISTS "
    <> orderAuditTable
    <> " (\n"
    <> "  global_position BIGINT PRIMARY KEY,\n"
    <> "  status TEXT NOT NULL\n"
    <> ");\n"
    <> "CREATE TABLE IF NOT EXISTS "
    <> orderSideEffectTable
    <> " (\n"
    <> "  global_position BIGINT PRIMARY KEY,\n"
    <> "  effect TEXT NOT NULL\n"
    <> ")"

revisionRelationOidStmt :: Statement (Text, Text) (Maybe Int64)
revisionRelationOidStmt =
  preparable
    """
    SELECT classes.oid::bigint
    FROM pg_catalog.pg_class AS classes
    JOIN pg_catalog.pg_namespace AS namespaces
      ON namespaces.oid = classes.relnamespace
    WHERE namespaces.nspname = $1 AND classes.relname = $2
    """
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)))
    (D.rowMaybe (D.column (D.nonNullable D.int8)))

revisionUpsertSummaryStmt :: Text -> QualifiedTable -> Statement (Text, Text, Int64, Text, Int64) ()
revisionUpsertSummaryStmt schemaVersion table =
  preparable
    ( "INSERT INTO "
        <> qualifiedPhysical table
        <> " (order_id, sku, quantity, "
        <> statusColumn
        <> ", last_seen) VALUES ($1, $2, $3, $4, $5) "
        <> "ON CONFLICT (order_id) DO UPDATE SET sku = EXCLUDED.sku, quantity = EXCLUDED.quantity, "
        <> statusColumn
        <> " = EXCLUDED."
        <> statusColumn
        <> ", last_seen = EXCLUDED.last_seen"
    )
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult
  where
    statusColumn = if schemaVersion == "v1" then "status" else "state"

revisionUpsertLineStmt :: Text -> QualifiedTable -> Statement (Text, Text, Int64, Int64) ()
revisionUpsertLineStmt _ table =
  preparable
    ( "INSERT INTO "
        <> qualifiedPhysical table
        <> " (order_id, line_no, sku, quantity, last_seen) VALUES ($1, 1, $2, $3, $4) "
        <> "ON CONFLICT (order_id, line_no) DO UPDATE SET sku = EXCLUDED.sku, quantity = EXCLUDED.quantity, last_seen = EXCLUDED.last_seen"
    )
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

revisionUpsertAuditStmt :: Text -> QualifiedTable -> Statement (Int64, Text) ()
revisionUpsertAuditStmt schemaVersion table =
  preparable
    ( "INSERT INTO "
        <> qualifiedPhysical table
        <> " (global_position, "
        <> statusColumn
        <> ") VALUES ($1, $2) ON CONFLICT (global_position) DO UPDATE SET "
        <> statusColumn
        <> " = EXCLUDED."
        <> statusColumn
    )
    (contrazip2 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.text)))
    D.noResult
  where
    statusColumn = if schemaVersion == "v1" then "status" else "state"

deleteRevisionOrderRowsStmt :: QualifiedTable -> Statement Text Int64
deleteRevisionOrderRowsStmt table =
  preparable
    ("DELETE FROM " <> qualifiedPhysical table <> " WHERE order_id = $1")
    (E.param (E.nonNullable E.text))
    D.rowsAffected

countRevisionOrderRowsStmt :: QualifiedTable -> Statement Text Int64
countRevisionOrderRowsStmt table =
  preparable
    ("SELECT count(*) FROM " <> qualifiedPhysical table <> " WHERE order_id = $1")
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.int8)))

revisionUpdateSummaryStmt :: Text -> QualifiedTable -> Statement (Text, Text, Int64) ()
revisionUpdateSummaryStmt schemaVersion table =
  preparable
    ( "UPDATE "
        <> qualifiedPhysical table
        <> " SET "
        <> statusColumn
        <> " = $2, last_seen = $3 WHERE order_id = $1"
    )
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult
  where
    statusColumn = if schemaVersion == "v1" then "status" else "state"

qualifiedPhysical :: QualifiedTable -> Text
qualifiedPhysical table = qualifyTable (table ^. #schemaName) (table ^. #tableName)

upsertOrderSummaryStmt :: Statement (Text, Text, Int64, Text, Int64) ()
upsertOrderSummaryStmt =
  preparable
    ( "INSERT INTO "
        <> orderSummaryTable
        <> " (order_id, sku, quantity, status, last_seen)\n"
        <> "VALUES ($1, $2, $3, $4, $5)\n"
        <> "ON CONFLICT (order_id) DO UPDATE\n"
        <> "  SET sku = EXCLUDED.sku,\n"
        <> "      quantity = EXCLUDED.quantity,\n"
        <> "      status = EXCLUDED.status,\n"
        <> "      last_seen = EXCLUDED.last_seen"
    )
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

upsertOrderLineStmt :: Statement (Text, Text, Int64, Int64) ()
upsertOrderLineStmt =
  preparable
    ( "INSERT INTO "
        <> orderLineTable
        <> " (order_id, line_no, sku, quantity, last_seen)\n"
        <> "VALUES ($1, 1, $2, $3, $4)\n"
        <> "ON CONFLICT (order_id, line_no) DO UPDATE\n"
        <> "  SET sku = EXCLUDED.sku,\n"
        <> "      quantity = EXCLUDED.quantity,\n"
        <> "      last_seen = EXCLUDED.last_seen"
    )
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

upsertOrderAuditStmt :: Statement (Int64, Text) ()
upsertOrderAuditStmt =
  preparable
    ( "INSERT INTO "
        <> orderAuditTable
        <> " (global_position, status) VALUES ($1, $2)\n"
        <> "ON CONFLICT (global_position) DO UPDATE SET status = EXCLUDED.status"
    )
    (contrazip2 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.text)))
    D.noResult

insertLiveSideEffectStmt :: Statement (Int64, Text) ()
insertLiveSideEffectStmt =
  preparable
    ( "INSERT INTO "
        <> orderSideEffectTable
        <> " (global_position, effect) VALUES ($1, $2)\n"
        <> "ON CONFLICT (global_position) DO NOTHING"
    )
    (contrazip2 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.text)))
    D.noResult

verifyOrderLinesStmt :: Statement () Bool
verifyOrderLinesStmt =
  preparable
    ( "SELECT NOT EXISTS (\n"
        <> "  SELECT 1 FROM "
        <> orderLineTable
        <> " line\n"
        <> "  LEFT JOIN "
        <> orderSummaryTable
        <> " summary ON summary.order_id = line.order_id\n"
        <> "  WHERE summary.order_id IS NULL\n"
        <> ") AND NOT EXISTS (\n"
        <> "  SELECT 1 FROM "
        <> orderSummaryTable
        <> " WHERE status = 'rebuild-blocked'\n"
        <> ")"
    )
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

updateOrderSummaryStatusStmt :: Statement (Text, Text, Int64) ()
updateOrderSummaryStatusStmt =
  preparable
    ( "UPDATE "
        <> orderSummaryTable
        <> "\nSET status = $2,\n    last_seen = $3\n"
        <> "WHERE order_id = $1"
    )
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

selectOrderSummaryStmt :: Statement Text (Maybe OrderSummary)
selectOrderSummaryStmt =
  preparable
    ( "SELECT order_id, sku, quantity, status, last_seen\n"
        <> "FROM "
        <> orderSummaryTable
        <> "\nWHERE order_id = $1"
    )
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe
        ( OrderSummary
            <$> (OrderId <$> D.column (D.nonNullable D.text))
            <*> (Sku <$> D.column (D.nonNullable D.text))
            <*> (Quantity . Prelude.fromIntegral <$> D.column (D.nonNullable D.int8))
            <*> D.column (D.nonNullable D.text)
            <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
        )
    )

globalPositionToInt :: GlobalPosition -> Int64
globalPositionToInt (GlobalPosition value) = value
