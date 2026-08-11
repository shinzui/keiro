{-# OPTIONS_HADDOCK hide #-}

-- | Internal implementation shared by the public rebuild lifecycle and the
-- catalog-derived live-writer paths. The public facade is
-- "Keiro.ReadModel.Rebuild".
module Keiro.ReadModel.Rebuild.Group
  ( RebuildRunId,
    mkRebuildRunId,
    rebuildRunIdText,
    RebuildRequest (..),
    RebuildFailure (..),
    GroupLifecycleStatus (..),
    GroupRebuildMetadata (..),
    CatalogRegistrationError (..),
    RebuildStartError (..),
    GroupTransitionError (..),
    ProjectionWriteFence (..),
    GroupPreparation (..),
    GroupRebuildHandle,
    groupRebuildHandleGroup,
    groupRebuildHandleRun,
    groupRebuildHandleFingerprint,
    groupRebuildHandlePreparation,
    groupRebuildHandleResetCheckpointKeys,
    GroupCompletionToken,
    completionTokenForHandle,
    groupRebuildHandleFor,
    registerProjectionCatalog,
    lookupProjectionRebuildGroup,
    beginGroupRebuild,
    finishGroupRebuild,
    finishGroupRebuildTx,
    abandonGroupRebuild,
    lockProjectionGroupsTx,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Data.Functor (($>))
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as Vector
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Connection (qualifyTable)
import Keiro.Prelude
import Keiro.Projection.Catalog
  ( CatalogFingerprint,
    CatalogRegistration (..),
    QualifiedTable (..),
    RebuildGroupId,
    TargetResetPolicy (..),
    ValidatedProjectionCatalog,
    asyncProjectionRegistrations,
    catalogFingerprintText,
    catalogInventory,
    catalogRegistrations,
    mkRebuildGroupId,
    rebuildGroupIdText,
    replayAdapterMetadata,
  )
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Subscription.Checkpoint
  ( SubscriptionCheckpointResetReport (..),
    resetSubscriptionCheckpointsTx,
  )
import Kiroku.Store.Subscription.Types
  ( SubscriptionCheckpointKey,
    SubscriptionName (..),
  )
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude (not, null, (&&))
import Prelude qualified

-- | Stable operator-supplied identity for one rebuild attempt.
newtype RebuildRunId = RebuildRunId Text
  deriving stock (Eq, Ord, Show, Generic)

mkRebuildRunId :: Text -> Either Text RebuildRunId
mkRebuildRunId value
  | Text.null value = Left "rebuild run id must not be empty"
  | Text.strip value /= value = Left "rebuild run id must not have surrounding whitespace"
  | otherwise = Right (RebuildRunId value)

rebuildRunIdText :: RebuildRunId -> Text
rebuildRunIdText (RebuildRunId value) = value

data RebuildRequest = RebuildRequest
  { rebuildRunId :: !RebuildRunId,
    requestedBy :: !Text,
    requestReason :: !Text,
    replayFrom :: !GlobalPosition
  }
  deriving stock (Eq, Show, Generic)

data RebuildFailure = RebuildFailure
  { failureCode :: !Text,
    failureDetail :: !Text
  }
  deriving stock (Eq, Show, Generic)

data GroupLifecycleStatus
  = GroupLive
  | GroupRebuilding
  | GroupFailed
  | UnknownGroupStatus !Text
  deriving stock (Eq, Ord, Show, Generic)

data GroupRebuildMetadata = GroupRebuildMetadata
  { rebuildGroupId :: !RebuildGroupId,
    catalogFingerprint :: !Text,
    status :: !GroupLifecycleStatus,
    activeRunId :: !(Maybe RebuildRunId),
    requestedBy :: !(Maybe Text),
    requestReason :: !(Maybe Text),
    startedAt :: !(Maybe UTCTime),
    completedAt :: !(Maybe UTCTime),
    failedAt :: !(Maybe UTCTime),
    failureCode :: !(Maybe Text),
    failureDetail :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data CatalogRegistrationError
  = RegisteredGroupFingerprintDrift !RebuildGroupId !Text !Text
  | RegisteredQueryModelDrift !Text !Text
  | RegisteredQueryModelNotLive !Text
  deriving stock (Eq, Show, Generic)

data RebuildStartError
  = RebuildGroupNotInCatalog !RebuildGroupId
  | RebuildGroupUnregistered !RebuildGroupId
  | RebuildCatalogFingerprintDrift !RebuildGroupId !Text !Text
  | RebuildGroupNotLive !RebuildGroupId !GroupLifecycleStatus !(Maybe RebuildRunId)
  | -- | At least one catalog-declared subscription had no persisted member to reset.
    RebuildSubscriptionCheckpointsMissing !RebuildGroupId ![SubscriptionName]
  deriving stock (Eq, Show, Generic)

data GroupTransitionError
  = RebuildHandleNoLongerActive !RebuildGroupId !RebuildRunId
  | RebuildCompletionTokenMismatch !RebuildGroupId !RebuildRunId
  deriving stock (Eq, Show, Generic)

data ProjectionWriteFence
  = ProjectionWritesAllowed
  | ProjectionWriteFenced !RebuildGroupId !RebuildRunId
  | ProjectionWriteGroupUnregistered !RebuildGroupId
  deriving stock (Eq, Show, Generic)

data GroupPreparation = GroupPreparation
  { clearTargets :: ![QualifiedTable],
    preservedTargets :: ![QualifiedTable],
    resetDedupNames :: ![Text],
    resetSubscriptionNames :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

data GroupRebuildHandle = GroupRebuildHandle
  { handleGroup :: !RebuildGroupId,
    handleRun :: !RebuildRunId,
    handleFingerprint :: !CatalogFingerprint,
    handlePreparation :: !GroupPreparation,
    handleResetCheckpointKeys :: ![SubscriptionCheckpointKey]
  }
  deriving stock (Eq, Show, Generic)

groupRebuildHandleGroup :: GroupRebuildHandle -> RebuildGroupId
groupRebuildHandleGroup = handleGroup

groupRebuildHandleRun :: GroupRebuildHandle -> RebuildRunId
groupRebuildHandleRun = handleRun

groupRebuildHandleFingerprint :: GroupRebuildHandle -> CatalogFingerprint
groupRebuildHandleFingerprint = handleFingerprint

groupRebuildHandlePreparation :: GroupRebuildHandle -> GroupPreparation
groupRebuildHandlePreparation = handlePreparation

-- | Exact persisted subscription-member rows reset during preparation.
groupRebuildHandleResetCheckpointKeys :: GroupRebuildHandle -> [SubscriptionCheckpointKey]
groupRebuildHandleResetCheckpointKeys = handleResetCheckpointKeys

-- | Opaque proof that completion verification was recorded for this exact
-- group, run, and catalog. Plan 211 constructs it only after durable completion
-- accounting; ordinary callers cannot fabricate one through the public facade.
data GroupCompletionToken = GroupCompletionToken
  { completionGroup :: !RebuildGroupId,
    completionRun :: !RebuildRunId,
    completionFingerprint :: !CatalogFingerprint
  }

completionTokenForHandle :: GroupRebuildHandle -> GroupCompletionToken
completionTokenForHandle handle =
  GroupCompletionToken
    { completionGroup = handleGroup handle,
      completionRun = handleRun handle,
      completionFingerprint = handleFingerprint handle
    }

-- | Reconstruct the opaque authorization for a persisted run. The replay
-- runner must still prove the active group/run/fingerprint in the same
-- transaction as every use of this value.
groupRebuildHandleFor ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  RebuildRunId ->
  Maybe GroupRebuildHandle
groupRebuildHandleFor catalog groupId runId = do
  preparation <- preparationFor catalog groupId
  pure
    GroupRebuildHandle
      { handleGroup = groupId,
        handleRun = runId,
        handleFingerprint = Catalog.catalogFingerprint catalog,
        handlePreparation = preparation,
        handleResetCheckpointKeys = []
      }

registerProjectionCatalog ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  Eff es (Either CatalogRegistrationError [GroupRebuildMetadata])
registerProjectionCatalog catalog =
  runTransaction $ registerProjectionCatalogTx catalog

registerProjectionCatalogTx ::
  ValidatedProjectionCatalog ->
  Tx.Transaction (Either CatalogRegistrationError [GroupRebuildMetadata])
registerProjectionCatalogTx catalog = do
  groupsResult <- registerGroups [] groupIds
  case groupsResult of
    Left err -> Tx.condemn $> Left err
    Right groups -> do
      queriesResult <- registerQueries queryRegistrations
      case queriesResult of
        Left err -> Tx.condemn $> Left err
        Right () -> do
          Tx.statement () deleteOrphanLegacyGroupsStmt
          pure (Right (List.sortOn (rebuildGroupIdText . (^. #rebuildGroupId)) groups))
  where
    fingerprint = Catalog.catalogFingerprint catalog
    fingerprintText = catalogFingerprintText fingerprint
    groupIds = (^. #rebuildGroupId) <$> (catalogInventory catalog ^. #inventoryGroups)
    queryRegistrations = catalogRegistrations catalog

    registerGroups accumulated = \case
      [] -> pure (Right (Prelude.reverse accumulated))
      groupId : rest -> do
        metadata <-
          Tx.statement
            (rebuildGroupIdText groupId, fingerprintText)
            registerGroupStmt
        if metadata ^. #catalogFingerprint == fingerprintText
          then registerGroups (metadata : accumulated) rest
          else
            pure
              ( Left
                  ( RegisteredGroupFingerprintDrift
                      groupId
                      (metadata ^. #catalogFingerprint)
                      fingerprintText
                  )
              )

    registerQueries = \case
      [] -> pure (Right ())
      registration : rest -> do
        existing <- Tx.statement (registration ^. #registryName) lookupQueryRegistrationStmt
        result <-
          case existing of
            Nothing -> do
              Tx.statement (queryRegistrationParams registration) insertQueryRegistrationStmt
              pure (Right ())
            Just row -> reconcileQueryRegistration registration row
        case result of
          Left err -> pure (Left err)
          Right () -> registerQueries rest

    reconcileQueryRegistration registration row
      | rowVersion row /= registration ^. #version =
          pure (Left (queryDrift registration row "version differs"))
      | rowShapeHash row /= registration ^. #shapeHash =
          pure (Left (queryDrift registration row "shape hash differs"))
      | rowGroupId row == rebuildGroupIdText (registration ^. #rebuildGroupId) =
          pure (Right ())
      | rowStatus row == "live" && "$legacy-read-model:" `Text.isPrefixOf` rowGroupId row = do
          Tx.statement
            (registration ^. #registryName, rebuildGroupIdText (registration ^. #rebuildGroupId))
            adoptLegacyQueryRegistrationStmt
          pure (Right ())
      | rowStatus row /= "live" =
          pure (Left (RegisteredQueryModelNotLive (registration ^. #registryName)))
      | otherwise = pure (Left (queryDrift registration row "rebuild group differs"))

    queryDrift registration row reason =
      RegisteredQueryModelDrift
        (registration ^. #registryName)
        ( reason
            <> "; registered group="
            <> rowGroupId row
            <> ", catalog group="
            <> rebuildGroupIdText (registration ^. #rebuildGroupId)
        )

lookupProjectionRebuildGroup ::
  (Store :> es) =>
  RebuildGroupId ->
  Eff es (Maybe GroupRebuildMetadata)
lookupProjectionRebuildGroup groupId =
  runTransaction
    $ Tx.statement
      (rebuildGroupIdText groupId)
      lookupGroupStmt

beginGroupRebuild ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  RebuildRequest ->
  Eff es (Either RebuildStartError GroupRebuildHandle)
beginGroupRebuild catalog groupId request =
  case preparationFor catalog groupId of
    Nothing -> pure (Left (RebuildGroupNotInCatalog groupId))
    Just preparation ->
      runTransaction $ do
        registered <-
          Tx.statement
            (rebuildGroupIdText groupId)
            lockGroupForUpdateStmt
        case registered of
          Nothing -> Tx.condemn $> Left (RebuildGroupUnregistered groupId)
          Just metadata
            | metadata ^. #catalogFingerprint /= expectedFingerprintText ->
                Tx.condemn
                  $> Left
                    ( RebuildCatalogFingerprintDrift
                        groupId
                        (metadata ^. #catalogFingerprint)
                        expectedFingerprintText
                    )
            | metadata ^. #status /= GroupLive ->
                Tx.condemn
                  $> Left
                    ( RebuildGroupNotLive
                        groupId
                        (metadata ^. #status)
                        (metadata ^. #activeRunId)
                    )
            | otherwise -> do
                Tx.statement
                  ( rebuildGroupIdText groupId,
                    rebuildRunIdText (request ^. #rebuildRunId),
                    request ^. #requestedBy,
                    request ^. #requestReason
                  )
                  beginGroupStmt
                Tx.statement (rebuildGroupIdText groupId) markGroupQueriesRebuildingStmt
                truncateTargets (preparation ^. #clearTargets)
                unless (null (preparation ^. #resetDedupNames))
                  $ Tx.statement (preparation ^. #resetDedupNames) deleteProjectionDedupStmt
                resetReport <- resetDeclaredSubscriptions preparation (request ^. #replayFrom)
                let missingNames = Vector.toList (resetReport ^. #missingSubscriptionNames)
                if null missingNames
                  then
                    pure
                      ( Right
                          GroupRebuildHandle
                            { handleGroup = groupId,
                              handleRun = request ^. #rebuildRunId,
                              handleFingerprint = expectedFingerprint,
                              handlePreparation = preparation,
                              handleResetCheckpointKeys = Vector.toList (resetReport ^. #resetCheckpointKeys)
                            }
                      )
                  else
                    Tx.condemn
                      $> Left (RebuildSubscriptionCheckpointsMissing groupId missingNames)
  where
    expectedFingerprint = Catalog.catalogFingerprint catalog
    expectedFingerprintText = catalogFingerprintText expectedFingerprint

resetDeclaredSubscriptions :: GroupPreparation -> GlobalPosition -> Tx.Transaction SubscriptionCheckpointResetReport
resetDeclaredSubscriptions preparation replayFrom =
  case NonEmpty.nonEmpty (SubscriptionName <$> preparation ^. #resetSubscriptionNames) of
    Nothing ->
      pure
        SubscriptionCheckpointResetReport
          { resetCheckpointKeys = Vector.empty,
            missingSubscriptionNames = Vector.empty
          }
    Just subscriptionNames -> resetSubscriptionCheckpointsTx subscriptionNames replayFrom

finishGroupRebuild ::
  (Store :> es) =>
  GroupRebuildHandle ->
  GroupCompletionToken ->
  Eff es (Either GroupTransitionError GroupRebuildMetadata)
finishGroupRebuild handle token
  | not (tokenMatchesHandle handle token) =
      pure (Left (RebuildCompletionTokenMismatch (handleGroup handle) (handleRun handle)))
  | otherwise = runTransaction (finishGroupRebuildTx handle token)

finishGroupRebuildTx ::
  GroupRebuildHandle ->
  GroupCompletionToken ->
  Tx.Transaction (Either GroupTransitionError GroupRebuildMetadata)
finishGroupRebuildTx handle token
  | not (tokenMatchesHandle handle token) =
      pure (Left (RebuildCompletionTokenMismatch (handleGroup handle) (handleRun handle)))
  | otherwise = do
      promoted <-
        Tx.statement
          ( rebuildGroupIdText (handleGroup handle),
            rebuildRunIdText (handleRun handle),
            catalogFingerprintText (handleFingerprint handle)
          )
          finishGroupStmt
      case promoted of
        Nothing ->
          Tx.condemn
            $> Left (RebuildHandleNoLongerActive (handleGroup handle) (handleRun handle))
        Just metadata -> do
          Tx.statement (rebuildGroupIdText (handleGroup handle)) markGroupQueriesLiveStmt
          pure (Right metadata)

abandonGroupRebuild ::
  (Store :> es) =>
  GroupRebuildHandle ->
  RebuildFailure ->
  Eff es (Either GroupTransitionError GroupRebuildMetadata)
abandonGroupRebuild handle failure =
  runTransaction $ do
    abandoned <-
      Tx.statement
        ( rebuildGroupIdText (handleGroup handle),
          rebuildRunIdText (handleRun handle),
          catalogFingerprintText (handleFingerprint handle),
          failure ^. #failureCode,
          failure ^. #failureDetail
        )
        abandonGroupStmt
    case abandoned of
      Nothing ->
        Tx.condemn
          $> Left (RebuildHandleNoLongerActive (handleGroup handle) (handleRun handle))
      Just metadata -> do
        Tx.statement (rebuildGroupIdText (handleGroup handle)) markGroupQueriesAbandonedStmt
        pure (Right metadata)

lockProjectionGroupsTx :: [RebuildGroupId] -> Tx.Transaction ProjectionWriteFence
lockProjectionGroupsTx = go . List.sort . Set.toList . Set.fromList
  where
    go = \case
      [] -> pure ProjectionWritesAllowed
      groupId : rest -> do
        row <-
          Tx.statement
            (rebuildGroupIdText groupId)
            lockGroupForShareStmt
        case row of
          Nothing -> pure (ProjectionWriteGroupUnregistered groupId)
          Just ("live", _) -> go rest
          Just (_, Just runId) -> pure (ProjectionWriteFenced groupId (RebuildRunId runId))
          Just _ -> pure (ProjectionWriteGroupUnregistered groupId)

data RegisteredQueryRow = RegisteredQueryRow
  { rowVersion :: !Int,
    rowShapeHash :: !Text,
    rowGroupId :: !Text,
    rowStatus :: !Text
  }

queryRegistrationParams :: CatalogRegistration -> (Text, Int64, Text, Text)
queryRegistrationParams registration =
  ( registration ^. #registryName,
    Prelude.fromIntegral (registration ^. #version),
    registration ^. #shapeHash,
    rebuildGroupIdText (registration ^. #rebuildGroupId)
  )

preparationFor :: ValidatedProjectionCatalog -> RebuildGroupId -> Maybe GroupPreparation
preparationFor catalog groupId = do
  group <- List.find ((== groupId) . (^. #rebuildGroupId)) (inventory ^. #inventoryGroups)
  let orderedTargetRows = mapMaybe targetFor (group ^. #orderedTargets)
      replayableProjectionIds =
        Set.fromList
          [ entry ^. #projectionId
          | entry <- replayAdapterMetadata catalog,
            entry ^. #rebuildGroupId == groupId,
            entry ^. #replayable
          ]
      asyncRows =
        [ entry
        | entry <- asyncProjectionRegistrations catalog,
          (entry ^. #projectionId) `Set.member` replayableProjectionIds
        ]
  pure
    GroupPreparation
      { clearTargets =
          [ target ^. #qualifiedTable
          | target <- orderedTargetRows,
            target ^. #resetPolicy == ClearBeforeReplay
          ],
        preservedTargets =
          [ target ^. #qualifiedTable
          | target <- orderedTargetRows,
            target ^. #resetPolicy == PreserveAndReconcile
          ],
        resetDedupNames = List.nub (List.sort ((^. #dedupName) <$> asyncRows)),
        resetSubscriptionNames = List.nub (List.sort ((^. #subscriptionName) <$> asyncRows))
      }
  where
    inventory = catalogInventory catalog
    targetFor targetId =
      List.find ((== targetId) . (^. #targetId)) (inventory ^. #inventoryTargets)

truncateTargets :: [QualifiedTable] -> Tx.Transaction ()
truncateTargets = \case
  [] -> pure ()
  targets ->
    Tx.sql
      ( TE.encodeUtf8
          ( "TRUNCATE TABLE "
              <> Text.intercalate
                ", "
                [ qualifyTable (target ^. #schemaName) (target ^. #tableName)
                | target <- targets
                ]
          )
      )

tokenMatchesHandle :: GroupRebuildHandle -> GroupCompletionToken -> Bool
tokenMatchesHandle handle token =
  completionGroup token == handleGroup handle
    && completionRun token == handleRun handle
    && completionFingerprint token == handleFingerprint handle

registerGroupStmt :: Statement (Text, Text) GroupRebuildMetadata
registerGroupStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_groups
      (group_id, catalog_fingerprint, status)
    VALUES ($1, $2, 'live')
    ON CONFLICT (group_id) DO UPDATE
      SET group_id = EXCLUDED.group_id
    RETURNING group_id, catalog_fingerprint, status, active_run_id,
              requested_by, request_reason, started_at, completed_at, failed_at,
              failure_code, failure_detail
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    groupMetadataSingle

lookupGroupStmt :: Statement Text (Maybe GroupRebuildMetadata)
lookupGroupStmt =
  preparable
    """
    SELECT group_id, catalog_fingerprint, status, active_run_id,
           requested_by, request_reason, started_at, completed_at, failed_at,
           failure_code, failure_detail
    FROM keiro.keiro_projection_rebuild_groups
    WHERE group_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe groupMetadataDecoder)

lockGroupForUpdateStmt :: Statement Text (Maybe GroupRebuildMetadata)
lockGroupForUpdateStmt =
  preparable
    """
    SELECT group_id, catalog_fingerprint, status, active_run_id,
           requested_by, request_reason, started_at, completed_at, failed_at,
           failure_code, failure_detail
    FROM keiro.keiro_projection_rebuild_groups
    WHERE group_id = $1
    FOR UPDATE
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe groupMetadataDecoder)

beginGroupStmt :: Statement (Text, Text, Text, Text) ()
beginGroupStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET status = 'rebuilding',
        active_run_id = $2,
        requested_by = $3,
        request_reason = $4,
        started_at = now(),
        completed_at = NULL,
        failed_at = NULL,
        failure_code = NULL,
        failure_detail = NULL,
        updated_at = now()
    WHERE group_id = $1
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

finishGroupStmt :: Statement (Text, Text, Text) (Maybe GroupRebuildMetadata)
finishGroupStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET status = 'live',
        active_run_id = NULL,
        completed_at = now(),
        failed_at = NULL,
        failure_code = NULL,
        failure_detail = NULL,
        updated_at = now()
    WHERE group_id = $1
      AND active_run_id = $2
      AND catalog_fingerprint = $3
      AND status = 'rebuilding'
    RETURNING group_id, catalog_fingerprint, status, active_run_id,
              requested_by, request_reason, started_at, completed_at, failed_at,
              failure_code, failure_detail
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.rowMaybe groupMetadataDecoder)

abandonGroupStmt :: Statement (Text, Text, Text, Text, Text) (Maybe GroupRebuildMetadata)
abandonGroupStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET status = 'failed',
        failed_at = now(),
        failure_code = $4,
        failure_detail = $5,
        updated_at = now()
    WHERE group_id = $1
      AND active_run_id = $2
      AND catalog_fingerprint = $3
      AND status = 'rebuilding'
    RETURNING group_id, catalog_fingerprint, status, active_run_id,
              requested_by, request_reason, started_at, completed_at, failed_at,
              failure_code, failure_detail
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.rowMaybe groupMetadataDecoder)

lockGroupForShareStmt :: Statement Text (Maybe (Text, Maybe Text))
lockGroupForShareStmt =
  preparable
    """
    SELECT status, active_run_id
    FROM keiro.keiro_projection_rebuild_groups
    WHERE group_id = $1
    FOR SHARE
    """
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe
        ( (,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
        )
    )

insertQueryRegistrationStmt :: Statement (Text, Int64, Text, Text) ()
insertQueryRegistrationStmt =
  preparable
    """
    INSERT INTO keiro.keiro_read_models
      (name, version, shape_hash, rebuild_group_id, status, last_built_at)
    VALUES ($1, $2, $3, $4, 'live', now())
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

lookupQueryRegistrationStmt :: Statement Text (Maybe RegisteredQueryRow)
lookupQueryRegistrationStmt =
  preparable
    """
    SELECT version, shape_hash, rebuild_group_id, status
    FROM keiro.keiro_read_models
    WHERE name = $1
    FOR UPDATE
    """
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe
        ( RegisteredQueryRow
            <$> (Prelude.fromIntegral <$> D.column (D.nonNullable D.int8))
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
        )
    )

adoptLegacyQueryRegistrationStmt :: Statement (Text, Text) ()
adoptLegacyQueryRegistrationStmt =
  preparable
    """
    UPDATE keiro.keiro_read_models
    SET rebuild_group_id = $2,
        updated_at = now()
    WHERE name = $1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

deleteOrphanLegacyGroupsStmt :: Statement () ()
deleteOrphanLegacyGroupsStmt =
  preparable
    """
    DELETE FROM keiro.keiro_projection_rebuild_groups AS groups
    WHERE groups.catalog_fingerprint = '$legacy-unmanaged'
      AND groups.status = 'live'
      AND NOT EXISTS (
        SELECT 1
        FROM keiro.keiro_read_models AS models
        WHERE models.rebuild_group_id = groups.group_id
      )
    """
    E.noParams
    D.noResult

markGroupQueriesRebuildingStmt :: Statement Text ()
markGroupQueriesRebuildingStmt =
  queryStatusStatement "rebuilding" False

markGroupQueriesLiveStmt :: Statement Text ()
markGroupQueriesLiveStmt =
  queryStatusStatement "live" True

markGroupQueriesAbandonedStmt :: Statement Text ()
markGroupQueriesAbandonedStmt =
  queryStatusStatement "abandoned" False

queryStatusStatement :: Text -> Bool -> Statement Text ()
queryStatusStatement newStatus stampBuilt =
  preparable
    ( "UPDATE keiro.keiro_read_models SET status = '"
        <> newStatus
        <> "', last_built_at = "
        <> (if stampBuilt then "now()" else "last_built_at")
        <> ", updated_at = now() WHERE rebuild_group_id = $1"
    )
    (E.param (E.nonNullable E.text))
    D.noResult

deleteProjectionDedupStmt :: Statement [Text] ()
deleteProjectionDedupStmt =
  preparable
    """
    DELETE FROM keiro.keiro_projection_dedup
    WHERE projection_name = ANY($1)
    """
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
    D.noResult

groupMetadataSingle :: D.Result GroupRebuildMetadata
groupMetadataSingle = D.singleRow groupMetadataDecoder

groupMetadataDecoder :: D.Row GroupRebuildMetadata
groupMetadataDecoder =
  GroupRebuildMetadata
    <$> (decodeGroupId <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.text)
    <*> (groupStatusFromText <$> D.column (D.nonNullable D.text))
    <*> (fmap RebuildRunId <$> D.column (D.nullable D.text))
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
  where
    decodeGroupId raw =
      case mkRebuildGroupId raw of
        Right value -> value
        Left _ -> error "stored rebuild group id violates catalog identity invariants"

groupStatusFromText :: Text -> GroupLifecycleStatus
groupStatusFromText = \case
  "live" -> GroupLive
  "rebuilding" -> GroupRebuilding
  "failed" -> GroupFailed
  raw -> UnknownGroupStatus raw
