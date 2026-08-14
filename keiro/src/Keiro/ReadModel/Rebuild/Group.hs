{-# OPTIONS_HADDOCK hide #-}

-- | Internal implementation shared by the public rebuild lifecycle and the
-- catalog-derived live-writer paths. The public facade is
-- "Keiro.ReadModel.Rebuild".
module Keiro.ReadModel.Rebuild.Group
  ( preCanonicalRunSliceSentinel,
    canonicalSlicePrefix,
    RebuildRunId,
    mkRebuildRunId,
    rebuildRunIdText,
    RebuildRequest (..),
    RebuildFailure (..),
    GroupLifecycleStatus (..),
    GroupRebuildMetadata (..),
    CatalogRegistrationError (..),
    GroupAdoptionClass (..),
    RegistrationAdoptionAction (..),
    RegistrationAdoption (..),
    OrphanedRegistration (..),
    CatalogAdoptionPlan (..),
    CatalogAdoptionResult (..),
    CatalogAdoptionError (..),
    RebuildStartError (..),
    GroupTransitionError (..),
    ProjectionWriteBinding (..),
    ProjectionWriteFence (..),
    GroupPreparation (..),
    groupPreparationFor,
    GroupRebuildHandle,
    groupRebuildHandleGroup,
    groupRebuildHandleRun,
    groupRebuildHandleSliceFingerprint,
    groupRebuildHandlePreparation,
    groupRebuildHandleResetCheckpointKeys,
    GroupCompletionToken,
    completionTokenForHandle,
    groupRebuildHandleFor,
    registerProjectionCatalog,
    previewCatalogAdoption,
    adoptCatalogGroups,
    lookupProjectionRebuildGroup,
    beginGroupRebuild,
    resetDeclaredSubscriptions,
    insertProjectionDedupBatchStmt,
    finishGroupRebuild,
    finishGroupRebuildTx,
    abandonGroupRebuild,
    abandonPreCanonicalGroupRebuild,
    lockProjectionGroupsTx,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Data.Functor (($>))
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe, maybeToList)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.UUID (UUID)
import Data.Vector qualified as Vector
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Connection (qualifyTable)
import Keiro.Prelude
import Keiro.Projection.Catalog
  ( CatalogRegistration (..),
    GroupSliceFingerprint,
    PhysicalTargets,
    ProjectionRevisionId,
    QualifiedTable (..),
    RebuildGroupId,
    TargetResetPolicy (..),
    ValidatedProjectionCatalog,
    asyncProjectionRegistrations,
    catalogInventory,
    catalogRegistrations,
    groupSliceFingerprint,
    groupSliceFingerprintText,
    mkPhysicalTargets,
    mkRebuildGroupId,
    mkTargetId,
    projectionRevisionIdText,
    rebuildGroupIdText,
    replayAdapterMetadata,
  )
import Keiro.Projection.Catalog qualified as Catalog
import Keiro.ReadModel.External qualified as External
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
import Prelude (not, null, (&&), (||))
import Prelude qualified

-- | Sentinel that migration 0024 stamps into
-- @keiro_projection_rebuild_runs.group_slice_fingerprint@ for runs begun
-- before canonical slice identity existed. Handled only by the recovery
-- paths: always abandonable, never resumable, never a valid identity.
preCanonicalRunSliceSentinel :: Text
preCanonicalRunSliceSentinel = "$pre-canonical"

-- | Prefix of the current canonical group-slice format (ADR-32).
canonicalSlicePrefix :: Text
canonicalSlicePrefix = "slice-v4:"

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
    sliceFingerprint :: !Text,
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
  = RegisteredGroupSliceDrift !RebuildGroupId !Text !Text
  | RegisteredGroupStaleFingerprint !RebuildGroupId !Text
  | RegisteredQueryModelDrift !Text !Text
  | RegisteredQueryModelNotLive !Text
  | RegisteredExternalReadContract !External.ExternalReadReconciliationError
  deriving stock (Eq, Show, Generic)

data GroupAdoptionClass
  = AdoptionNew
  | AdoptionUnchanged
  | AdoptionSliceChanged !Text !Text
  | AdoptionStaleFormat !Text
  deriving stock (Eq, Show, Generic)

-- | What adoption did, or in a preview will do, for one catalog registration.
data RegistrationAdoptionAction
  = RegistrationUpdate
  | RegistrationInsert
  deriving stock (Eq, Show, Generic)

data RegistrationAdoption = RegistrationAdoption
  { registryName :: !Text,
    rebuildGroupId :: !RebuildGroupId,
    action :: !RegistrationAdoptionAction
  }
  deriving stock (Eq, Show, Generic)

-- | A registry row bound to a catalog group whose name no registration in the
-- complete validated catalog claims.
data OrphanedRegistration = OrphanedRegistration
  { registryName :: !Text,
    boundGroupId :: !RebuildGroupId
  }
  deriving stock (Eq, Show, Generic)

data CatalogAdoptionPlan = CatalogAdoptionPlan
  { groupStates :: ![(RebuildGroupId, GroupAdoptionClass)],
    removedGroups :: ![RebuildGroupId],
    registrations :: ![RegistrationAdoption],
    orphanedRegistrations :: ![OrphanedRegistration]
  }
  deriving stock (Eq, Show, Generic)

data CatalogAdoptionResult = CatalogAdoptionResult
  { adoptedGroups :: ![GroupRebuildMetadata],
    registrationOutcomes :: ![RegistrationAdoption],
    removedOrphans :: ![OrphanedRegistration]
  }
  deriving stock (Eq, Show, Generic)

data CatalogAdoptionError
  = AdoptGroupNotInCatalog !RebuildGroupId
  | AdoptGroupUnregistered !RebuildGroupId
  | AdoptGroupNotLive !RebuildGroupId !GroupLifecycleStatus !(Maybe RebuildRunId)
  | AdoptExternalReadContract !External.ExternalReadReconciliationError
  deriving stock (Eq, Show, Generic)

data RebuildStartError
  = RebuildGroupNotInCatalog !RebuildGroupId
  | RebuildGroupUnregistered !RebuildGroupId
  | RebuildGroupSliceDrift !RebuildGroupId !Text !Text
  | RebuildGroupNotLive !RebuildGroupId !GroupLifecycleStatus !(Maybe RebuildRunId)
  | -- | At least one catalog-declared subscription had no persisted member to reset.
    RebuildSubscriptionCheckpointsMissing !RebuildGroupId ![SubscriptionName]
  deriving stock (Eq, Show, Generic)

data GroupTransitionError
  = RebuildHandleNoLongerActive !RebuildGroupId !RebuildRunId
  | RebuildCompletionTokenMismatch !RebuildGroupId !RebuildRunId
  deriving stock (Eq, Show, Generic)

-- | Revision and closed-world physical target binding selected while the
-- corresponding group row remains locked. Legacy groups have no revision but
-- still carry their catalog-declared physical targets.
data ProjectionWriteBinding = ProjectionWriteBinding
  { writeGroupId :: !RebuildGroupId,
    writeRevisionId :: !(Maybe ProjectionRevisionId),
    writePhysicalTargets :: !PhysicalTargets
  }
  deriving stock (Eq, Show, Generic)

data ProjectionWriteFence
  = ProjectionWritesAllowed ![ProjectionWriteBinding]
  | ProjectionWriteFenced !RebuildGroupId !RebuildRunId
  | ProjectionWriteGroupUnregistered !RebuildGroupId
  | ProjectionServingRevisionUnavailable !RebuildGroupId !ProjectionRevisionId
  | ProjectionServingBindingInvalid !RebuildGroupId !ProjectionRevisionId !Text
  deriving stock (Eq, Show, Generic)

data GroupPreparation = GroupPreparation
  { clearTargets :: ![QualifiedTable],
    preservedTargets :: ![QualifiedTable],
    resetDedupNames :: ![Text],
    resetSubscriptionNames :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | Resolve the closed-world target, deduplication, and subscription preparation
-- declared for one group. Versioned promotion reuses this catalog authority
-- without constructing an offline rebuild handle.
groupPreparationFor :: ValidatedProjectionCatalog -> RebuildGroupId -> Maybe GroupPreparation
groupPreparationFor = preparationFor

data GroupRebuildHandle = GroupRebuildHandle
  { handleGroup :: !RebuildGroupId,
    handleRun :: !RebuildRunId,
    handleSliceFingerprint :: !GroupSliceFingerprint,
    handlePreparation :: !GroupPreparation,
    handleResetCheckpointKeys :: ![SubscriptionCheckpointKey]
  }
  deriving stock (Eq, Show, Generic)

groupRebuildHandleGroup :: GroupRebuildHandle -> RebuildGroupId
groupRebuildHandleGroup = handleGroup

groupRebuildHandleRun :: GroupRebuildHandle -> RebuildRunId
groupRebuildHandleRun = handleRun

groupRebuildHandleSliceFingerprint :: GroupRebuildHandle -> GroupSliceFingerprint
groupRebuildHandleSliceFingerprint = handleSliceFingerprint

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
    completionSliceFingerprint :: !GroupSliceFingerprint
  }

completionTokenForHandle :: GroupRebuildHandle -> GroupCompletionToken
completionTokenForHandle handle =
  GroupCompletionToken
    { completionGroup = handleGroup handle,
      completionRun = handleRun handle,
      completionSliceFingerprint = handleSliceFingerprint handle
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
  slice <- groupSliceFingerprint catalog groupId
  pure
    GroupRebuildHandle
      { handleGroup = groupId,
        handleRun = runId,
        handleSliceFingerprint = slice,
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
      revisionsResult <- registerRevisions revisionRegistrations
      case revisionsResult of
        Left err -> Tx.condemn $> Left err
        Right () -> do
          reconcileCursorAuthorities groupIds
          queriesResult <- registerQueries queryRegistrations
          case queriesResult of
            Left err -> Tx.condemn $> Left err
            Right () -> do
              externalReads <- External.reconcileExternalReadContractsTx catalog
              case externalReads of
                Left err -> Tx.condemn $> Left (RegisteredExternalReadContract err)
                Right () -> do
                  Tx.statement () deleteOrphanLegacyGroupsStmt
                  pure (Right (List.sortOn (rebuildGroupIdText . (^. #rebuildGroupId)) groups))
  where
    groupIds = (^. #rebuildGroupId) <$> (catalogInventory catalog ^. #inventoryGroups)
    revisionRegistrations =
      [ ( revision ^. #rebuildGroupId,
          revision ^. #revisionId,
          sliceTextFor catalog (revision ^. #rebuildGroupId)
        )
      | revision <- catalogInventory catalog ^. #inventoryProjectionRevisions
      ]
    queryRegistrations = catalogRegistrations catalog

    reconcileCursorAuthorities =
      traverse_ $ \groupId ->
        Tx.statement
          (cursorAuthorityParams catalog groupId)
          upsertGroupCursorAuthorityStmt

    registerGroups accumulated = \case
      [] -> pure (Right (Prelude.reverse accumulated))
      groupId : rest -> do
        let currentSlice = sliceFor groupId
            currentText = groupSliceFingerprintText currentSlice
        metadata <-
          Tx.statement
            (rebuildGroupIdText groupId, currentText)
            registerGroupStmt
        let stored = metadata ^. #sliceFingerprint
        if stored == currentText
          then registerGroups (metadata : accumulated) rest
          else
            if canonicalSlicePrefix `Text.isPrefixOf` stored
              then pure (Left (RegisteredGroupSliceDrift groupId stored currentText))
              else pure (Left (RegisteredGroupStaleFingerprint groupId stored))

    sliceFor groupId =
      fromMaybe
        (error "registerProjectionCatalogTx: inventory group has no slice")
        (groupSliceFingerprint catalog groupId)

    registerRevisions = \case
      [] -> pure (Right ())
      (groupId, revisionId, slice) : rest -> do
        stored <-
          Tx.statement
            (rebuildGroupIdText groupId, projectionRevisionIdText revisionId, slice)
            registerProjectionRevisionStmt
        if stored == slice
          then registerRevisions rest
          else pure (Left (RegisteredGroupSliceDrift groupId stored slice))

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

previewCatalogAdoption ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  Eff es CatalogAdoptionPlan
previewCatalogAdoption catalog =
  runTransaction $ do
    registered <- Tx.statement () listGroupsStmt
    registryRows <- Tx.statement () listQueryRegistrationBindingsStmt
    let registeredById = Map.fromList [(metadata ^. #rebuildGroupId, metadata) | metadata <- registered]
        catalogGroups =
          List.sortOn
            rebuildGroupIdText
            ((^. #rebuildGroupId) <$> (catalogInventory catalog ^. #inventoryGroups))
        catalogGroupSet = Set.fromList catalogGroups
        classify groupId =
          ( groupId,
            case Map.lookup groupId registeredById of
              Nothing -> AdoptionNew
              Just metadata -> adoptionClass groupId (metadata ^. #sliceFingerprint)
          )
        removed =
          List.sortOn
            rebuildGroupIdText
            [ metadata ^. #rebuildGroupId
            | metadata <- registered,
              metadata ^. #sliceFingerprint /= "$legacy-unmanaged",
              (metadata ^. #rebuildGroupId) `Set.notMember` catalogGroupSet
            ]
        catalogRegistrationRows = List.sortOn (^. #registryName) (catalogRegistrations catalog)
        catalogRegistrationNames = Set.fromList ((^. #registryName) <$> catalogRegistrationRows)
        registeredNames = Set.fromList (Prelude.fst <$> registryRows)
        registrationPlans =
          [ RegistrationAdoption
              { registryName = registration ^. #registryName,
                rebuildGroupId = registration ^. #rebuildGroupId,
                action =
                  if (registration ^. #registryName) `Set.member` registeredNames
                    then RegistrationUpdate
                    else RegistrationInsert
              }
          | registration <- catalogRegistrationRows
          ]
        orphaned =
          List.sortOn
            (^. #registryName)
            [ OrphanedRegistration name groupId
            | (name, storedGroupId) <- registryRows,
              name `Set.notMember` catalogRegistrationNames,
              groupId <- maybeToList (either (Prelude.const Nothing) Just (mkRebuildGroupId storedGroupId)),
              groupId `Set.member` catalogGroupSet
            ]
    pure
      CatalogAdoptionPlan
        { groupStates = classify <$> catalogGroups,
          removedGroups = removed,
          registrations = registrationPlans,
          orphanedRegistrations = orphaned
        }
  where
    adoptionClass groupId stored
      | stored == current = AdoptionUnchanged
      | canonicalSlicePrefix `Text.isPrefixOf` stored = AdoptionSliceChanged stored current
      | otherwise = AdoptionStaleFormat stored
      where
        current = sliceTextFor catalog groupId

adoptCatalogGroups ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  NonEmpty.NonEmpty RebuildGroupId ->
  Eff es (Either CatalogAdoptionError CatalogAdoptionResult)
adoptCatalogGroups catalog requested =
  case List.find (`Set.notMember` catalogGroupSet) groupIds of
    Just groupId -> pure (Left (AdoptGroupNotInCatalog groupId))
    Nothing -> runTransaction adoptTx
  where
    groupIds = List.sort . Set.toList . Set.fromList $ NonEmpty.toList requested
    catalogGroupSet =
      Set.fromList ((^. #rebuildGroupId) <$> (catalogInventory catalog ^. #inventoryGroups))
    namedGroupSet = Set.fromList groupIds
    registrations =
      List.sortOn
        (^. #registryName)
        [ registration
        | registration <- catalogRegistrations catalog,
          (registration ^. #rebuildGroupId) `Set.member` namedGroupSet
        ]
    allRegistrationNames = Set.fromList ((^. #registryName) <$> catalogRegistrations catalog)
    revisionRegistrations =
      [ ( revision ^. #rebuildGroupId,
          revision ^. #revisionId,
          sliceTextFor catalog (revision ^. #rebuildGroupId)
        )
      | revision <- catalogInventory catalog ^. #inventoryProjectionRevisions,
        (revision ^. #rebuildGroupId) `Set.member` namedGroupSet
      ]

    adoptTx = do
      locked <- lockAll [] groupIds
      case locked of
        Left err -> Tx.condemn $> Left err
        Right lockedGroups -> do
          for_ groupIds $ \groupId ->
            Tx.statement
              (rebuildGroupIdText groupId, sliceTextFor catalog groupId)
              adoptGroupSliceStmt
          for_ revisionRegistrations $ \(groupId, revisionId, slice) ->
            void
              ( Tx.statement
                  (rebuildGroupIdText groupId, projectionRevisionIdText revisionId, slice)
                  adoptProjectionRevisionStmt
              )
          for_ groupIds $ \groupId ->
            Tx.statement
              (cursorAuthorityParams catalog groupId)
              upsertGroupCursorAuthorityStmt
          registrationResults <- traverse (reconcileRegistration lockedGroups) registrations
          boundRows <- Tx.statement (rebuildGroupIdText <$> groupIds) lockGroupRegistrationsStmt
          let groupByText = Map.fromList [(rebuildGroupIdText groupId, groupId) | groupId <- groupIds]
              orphaned =
                List.sortOn
                  (^. #registryName)
                  [ OrphanedRegistration name groupId
                  | (name, storedGroupId) <- boundRows,
                    name `Set.notMember` allRegistrationNames,
                    groupId <- maybeToList (Map.lookup storedGroupId groupByText)
                  ]
          unless (null orphaned)
            $ Tx.statement ((^. #registryName) <$> orphaned) deleteQueryRegistrationsStmt
          externalReads <-
            External.reconcileExternalReadContractsForGroupsTx
              catalog
              (Just namedGroupSet)
          case externalReads of
            Left err -> Tx.condemn $> Left (AdoptExternalReadContract err)
            Right () -> do
              updated <- traverse (\groupId -> Tx.statement (rebuildGroupIdText groupId) lookupGroupStmt) groupIds
              pure
                ( Right
                    CatalogAdoptionResult
                      { adoptedGroups = [metadata | Just metadata <- updated],
                        registrationOutcomes = registrationResults,
                        removedOrphans = orphaned
                      }
                )

    reconcileRegistration lockedGroups registration = do
      existing <- Tx.statement (registration ^. #registryName) lookupQueryRegistrationStmt
      action <-
        case existing of
          Just _ -> do
            affected <- Tx.statement (queryRegistrationParams registration) adoptQueryRegistrationStmt
            when (affected /= 1)
              $ error "adoptTx: locked registration row vanished"
            pure RegistrationUpdate
          Nothing -> do
            Tx.statement
              (adoptionQueryRegistrationParams lockedGroups registration)
              insertAdoptedQueryRegistrationStmt
            pure RegistrationInsert
      pure
        RegistrationAdoption
          { registryName = registration ^. #registryName,
            rebuildGroupId = registration ^. #rebuildGroupId,
            action
          }

    adoptionQueryRegistrationParams lockedGroups registration =
      let (name, version, shape, groupId) = queryRegistrationParams registration
          status =
            case List.find ((== registration ^. #rebuildGroupId) . (^. #rebuildGroupId)) lockedGroups of
              Just metadata -> case metadata ^. #status of
                GroupLive -> "live"
                GroupFailed -> "abandoned"
                _ -> error "adoptTx: non-adoptable group reached registration insert"
              Nothing -> error "adoptTx: registration group was not locked"
       in (name, version, shape, groupId, status)

    lockAll accumulated = \case
      [] -> pure (Right (Prelude.reverse accumulated))
      groupId : rest -> do
        row <- Tx.statement (rebuildGroupIdText groupId) lockGroupForUpdateStmt
        case row of
          Nothing -> pure (Left (AdoptGroupUnregistered groupId))
          Just metadata
            | not (adoptable metadata) ->
                pure
                  ( Left
                      ( AdoptGroupNotLive
                          groupId
                          (metadata ^. #status)
                          (metadata ^. #activeRunId)
                      )
                  )
            | otherwise -> lockAll (metadata : accumulated) rest

    adoptable metadata =
      metadata
        ^. #status
        == GroupLive
        || ( metadata ^. #status == GroupFailed
               && not
                 ( canonicalSlicePrefix
                     `Text.isPrefixOf` (metadata ^. #sliceFingerprint)
                 )
           )

sliceTextFor :: ValidatedProjectionCatalog -> RebuildGroupId -> Text
sliceTextFor catalog groupId =
  maybe
    (error "sliceTextFor: catalog inventory group has no slice")
    groupSliceFingerprintText
    (groupSliceFingerprint catalog groupId)

cursorAuthorityParams ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  (Text, Text, [Text])
cursorAuthorityParams catalog groupId =
  ( rebuildGroupIdText groupId,
    if null subscriptionNames then "append" else "checkpoint",
    subscriptionNames
  )
  where
    inventory = catalogInventory catalog
    subscriptionNamesById =
      Map.fromList
        [ (subscription ^. #subscriptionId, subscription ^. #subscriptionName)
        | subscription <- inventory ^. #inventorySubscriptions
        ]
    subscriptionIds =
      Set.fromList
        [ subscriptionId
        | projection <- inventory ^. #inventoryProjections,
          projection ^. #rebuildGroupId == groupId,
          Catalog.InventoryAsyncHandler _ subscriptionId _ <- projection ^. #handlers
        ]
    subscriptionNames =
      List.sort
        [ fromMaybe
            (error "cursorAuthorityParams: validated handler has no subscription")
            (Map.lookup subscriptionId subscriptionNamesById)
        | subscriptionId <- Set.toList subscriptionIds
        ]

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
            | metadata ^. #sliceFingerprint /= expectedSliceText ->
                Tx.condemn
                  $> Left
                    ( RebuildGroupSliceDrift
                        groupId
                        (metadata ^. #sliceFingerprint)
                        expectedSliceText
                    )
            | metadata ^. #status /= GroupLive
                && metadata ^. #status /= GroupFailed ->
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
                              handleSliceFingerprint = expectedSlice,
                              handlePreparation = preparation,
                              handleResetCheckpointKeys = Vector.toList (resetReport ^. #resetCheckpointKeys)
                            }
                      )
                  else
                    Tx.condemn
                      $> Left (RebuildSubscriptionCheckpointsMissing groupId missingNames)
  where
    expectedSlice =
      fromMaybe
        (error "beginGroupRebuild: prepared group has no catalog slice")
        (groupSliceFingerprint catalog groupId)
    expectedSliceText = groupSliceFingerprintText expectedSlice

-- | Reset every declared subscription member to one exact position.
-- Preparation uses this to rewind to @replayFrom@; promotion uses it to
-- advance to the captured head. Both transitions remain inside the group
-- lifecycle transaction.
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
            groupSliceFingerprintText (handleSliceFingerprint handle)
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
          groupSliceFingerprintText (handleSliceFingerprint handle),
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

-- | Abandon a run stamped by migration 0024 before canonical slice identity
-- existed. This recovery transition deliberately does not compare a catalog
-- slice: the sentinel is evidence that no meaningful slice was persisted.
-- Failed groups are returned unchanged so retries preserve the first failure
-- evidence.
abandonPreCanonicalGroupRebuild ::
  (Store :> es) =>
  RebuildGroupId ->
  RebuildRunId ->
  RebuildFailure ->
  Eff es (Either GroupTransitionError GroupRebuildMetadata)
abandonPreCanonicalGroupRebuild groupId runId failure =
  runTransaction $ do
    locked <- Tx.statement (rebuildGroupIdText groupId) lockGroupForUpdateStmt
    case locked of
      Just metadata
        | metadata ^. #activeRunId == Just runId ->
            case metadata ^. #status of
              GroupFailed -> pure (Right metadata)
              GroupRebuilding -> do
                abandoned <-
                  Tx.statement
                    ( rebuildGroupIdText groupId,
                      rebuildRunIdText runId,
                      failure ^. #failureCode,
                      failure ^. #failureDetail
                    )
                    abandonPreCanonicalGroupStmt
                case abandoned of
                  Nothing -> inactive
                  Just updated -> do
                    Tx.statement (rebuildGroupIdText groupId) markGroupQueriesAbandonedStmt
                    pure (Right updated)
              _ -> inactive
      _ -> inactive
  where
    inactive =
      Tx.condemn
        $> Left (RebuildHandleNoLongerActive groupId runId)

lockProjectionGroupsTx ::
  ValidatedProjectionCatalog ->
  [RebuildGroupId] ->
  Tx.Transaction ProjectionWriteFence
lockProjectionGroupsTx catalog = go [] . List.sort . Set.toList . Set.fromList
  where
    go bindings = \case
      [] -> pure (ProjectionWritesAllowed (Prelude.reverse bindings))
      groupId : rest -> do
        row <-
          Tx.statement
            (rebuildGroupIdText groupId)
            lockGroupForShareStmt
        case row of
          Nothing -> pure (ProjectionWriteGroupUnregistered groupId)
          Just (_, activeRunId, _, False) ->
            case activeRunId of
              Just runId -> pure (ProjectionWriteFenced groupId (RebuildRunId runId))
              Nothing -> pure (ProjectionWriteGroupUnregistered groupId)
          Just ("live", Nothing, Nothing, True) ->
            case declaredPhysicalTargets catalog groupId of
              Nothing -> pure (ProjectionWriteGroupUnregistered groupId)
              Just targets ->
                go
                  (ProjectionWriteBinding groupId Nothing targets : bindings)
                  rest
          Just (status, _, Just revisionIdText, True)
            | status `Prelude.elem` ["serving-versioned", "rebuilding-versioned"] ->
                case findRevision revisionIdText of
                  Nothing ->
                    case Catalog.mkProjectionRevisionId revisionIdText of
                      Left _ -> pure (ProjectionWriteGroupUnregistered groupId)
                      Right revisionId ->
                        pure (ProjectionServingRevisionUnavailable groupId revisionId)
                  Just revision -> do
                    rows <-
                      Tx.statement
                        (rebuildGroupIdText groupId)
                        servingTargetBindingsStmt
                    case servingPhysicalTargets revision rows of
                      Left detail ->
                        pure
                          ( ProjectionServingBindingInvalid
                              groupId
                              (revision ^. #revisionId)
                              detail
                          )
                      Right targets ->
                        go
                          ( ProjectionWriteBinding
                              groupId
                              (Just (revision ^. #revisionId))
                              targets
                              : bindings
                          )
                          rest
          Just _ -> pure (ProjectionWriteGroupUnregistered groupId)

    findRevision revisionIdText =
      List.find
        (\revision -> projectionRevisionIdText (revision ^. #revisionId) == revisionIdText)
        (Catalog.catalogProjectionRevisions catalog)

declaredPhysicalTargets ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  Maybe PhysicalTargets
declaredPhysicalTargets catalog groupId = do
  group <-
    List.find
      ((== groupId) . (^. #rebuildGroupId))
      (inventory ^. #inventoryGroups)
  targetRows <- traverse targetFor (group ^. #orderedTargets)
  either (Prelude.const Nothing) Just
    $ mkPhysicalTargets
      (group ^. #orderedTargets)
      ( Map.fromList
          [ (target ^. #targetId, target ^. #qualifiedTable)
          | target <- targetRows
          ]
      )
  where
    inventory = catalogInventory catalog
    targetFor targetId =
      List.find ((== targetId) . (^. #targetId)) (inventory ^. #inventoryTargets)

servingPhysicalTargets ::
  Catalog.ProjectionRevision ->
  [(Text, Text, Text, Text)] ->
  Either Text PhysicalTargets
servingPhysicalTargets revision rows = do
  parsedRows <- traverse parseRow rows
  let expected = Map.keys (revision ^. #targetProvisioners)
      supplied = Map.fromList [(targetId, table) | (targetId, table) <- parsedRows]
  case mkPhysicalTargets expected supplied of
    Left errors -> Left (Text.pack (show errors))
    Right targets -> Right targets
  where
    parseRow (targetIdTextValue, revisionIdTextValue, schemaName, tableName)
      | revisionIdTextValue /= projectionRevisionIdText (revision ^. #revisionId) =
          Left
            ( "serving target "
                <> targetIdTextValue
                <> " belongs to revision "
                <> revisionIdTextValue
            )
      | otherwise = do
          targetId <-
            case mkTargetId targetIdTextValue of
              Left err -> Left (Text.pack (show err))
              Right value -> Right value
          pure (targetId, QualifiedTable schemaName tableName)

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
    && completionSliceFingerprint token == handleSliceFingerprint handle

registerGroupStmt :: Statement (Text, Text) GroupRebuildMetadata
registerGroupStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_groups
      (group_id, slice_fingerprint, status)
    VALUES ($1, $2, 'live')
    ON CONFLICT (group_id) DO UPDATE
      SET group_id = EXCLUDED.group_id
    RETURNING group_id, slice_fingerprint, status, active_run_id,
              requested_by, request_reason, started_at, completed_at, failed_at,
              failure_code, failure_detail
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    groupMetadataSingle

registerProjectionRevisionStmt :: Statement (Text, Text, Text) Text
registerProjectionRevisionStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_revisions
      (group_id, revision_id, group_slice_fingerprint)
    VALUES ($1, $2, $3)
    ON CONFLICT (group_id, revision_id) DO UPDATE
      SET revision_id = EXCLUDED.revision_id
    RETURNING group_slice_fingerprint
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.singleRow (D.column (D.nonNullable D.text)))

upsertGroupCursorAuthorityStmt :: Statement (Text, Text, [Text]) ()
upsertGroupCursorAuthorityStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_group_cursors
      (group_id, position_basis, subscription_names)
    VALUES ($1, $2, $3)
    ON CONFLICT (group_id) DO UPDATE
      SET position_basis = EXCLUDED.position_basis,
          subscription_names = EXCLUDED.subscription_names,
          updated_at = now()
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
    )
    D.noResult

adoptProjectionRevisionStmt :: Statement (Text, Text, Text) ()
adoptProjectionRevisionStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_revisions
      (group_id, revision_id, group_slice_fingerprint)
    VALUES ($1, $2, $3)
    ON CONFLICT (group_id, revision_id) DO UPDATE
      SET group_slice_fingerprint = EXCLUDED.group_slice_fingerprint,
          updated_at = now()
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

lookupGroupStmt :: Statement Text (Maybe GroupRebuildMetadata)
lookupGroupStmt =
  preparable
    """
    SELECT group_id, slice_fingerprint, status, active_run_id,
           requested_by, request_reason, started_at, completed_at, failed_at,
           failure_code, failure_detail
    FROM keiro.keiro_projection_rebuild_groups
    WHERE group_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe groupMetadataDecoder)

listGroupsStmt :: Statement () [GroupRebuildMetadata]
listGroupsStmt =
  preparable
    """
    SELECT group_id, slice_fingerprint, status, active_run_id,
           requested_by, request_reason, started_at, completed_at, failed_at,
           failure_code, failure_detail
    FROM keiro.keiro_projection_rebuild_groups
    ORDER BY group_id
    """
    E.noParams
    (D.rowList groupMetadataDecoder)

lockGroupForUpdateStmt :: Statement Text (Maybe GroupRebuildMetadata)
lockGroupForUpdateStmt =
  preparable
    """
    SELECT group_id, slice_fingerprint, status, active_run_id,
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
        reads_allowed = FALSE,
        writes_allowed = FALSE,
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
        reads_allowed = TRUE,
        writes_allowed = TRUE,
        active_run_id = NULL,
        completed_at = now(),
        failed_at = NULL,
        failure_code = NULL,
        failure_detail = NULL,
        updated_at = now()
    WHERE group_id = $1
      AND active_run_id = $2
      AND slice_fingerprint = $3
      AND status = 'rebuilding'
    RETURNING group_id, slice_fingerprint, status, active_run_id,
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
        reads_allowed = FALSE,
        writes_allowed = FALSE,
        failed_at = now(),
        failure_code = $4,
        failure_detail = $5,
        updated_at = now()
    WHERE group_id = $1
      AND active_run_id = $2
      AND slice_fingerprint = $3
      AND status = 'rebuilding'
    RETURNING group_id, slice_fingerprint, status, active_run_id,
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

abandonPreCanonicalGroupStmt :: Statement (Text, Text, Text, Text) (Maybe GroupRebuildMetadata)
abandonPreCanonicalGroupStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET status = 'failed',
        reads_allowed = FALSE,
        writes_allowed = FALSE,
        failed_at = now(),
        failure_code = $3,
        failure_detail = $4,
        updated_at = now()
    WHERE group_id = $1
      AND active_run_id = $2
      AND status = 'rebuilding'
    RETURNING group_id, slice_fingerprint, status, active_run_id,
              requested_by, request_reason, started_at, completed_at, failed_at,
              failure_code, failure_detail
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.rowMaybe groupMetadataDecoder)

lockGroupForShareStmt :: Statement Text (Maybe (Text, Maybe Text, Maybe Text, Bool))
lockGroupForShareStmt =
  preparable
    """
    SELECT status, active_run_id, serving_revision_id, writes_allowed
    FROM keiro.keiro_projection_rebuild_groups
    WHERE group_id = $1
    FOR SHARE
    """
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe
        ( (,,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nonNullable D.bool)
        )
    )

servingTargetBindingsStmt :: Statement Text [(Text, Text, Text, Text)]
servingTargetBindingsStmt =
  preparable
    """
    SELECT target_id, revision_id, schema_name, relation_name
    FROM keiro.keiro_projection_target_generations
    WHERE group_id = $1 AND lifecycle = 'serving'
    ORDER BY target_id
    """
    (E.param (E.nonNullable E.text))
    ( D.rowList
        ( (,,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
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

insertAdoptedQueryRegistrationStmt :: Statement (Text, Int64, Text, Text, Text) ()
insertAdoptedQueryRegistrationStmt =
  preparable
    """
    INSERT INTO keiro.keiro_read_models
      (name, version, shape_hash, rebuild_group_id, status, last_built_at)
    VALUES ($1, $2, $3, $4, $5,
            CASE WHEN $5 = 'live' THEN now() ELSE NULL END)
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
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

adoptGroupSliceStmt :: Statement (Text, Text) ()
adoptGroupSliceStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET slice_fingerprint = $2,
        updated_at = now()
    WHERE group_id = $1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

adoptQueryRegistrationStmt :: Statement (Text, Int64, Text, Text) Int64
adoptQueryRegistrationStmt =
  preparable
    """
    UPDATE keiro.keiro_read_models
    SET version = $2,
        shape_hash = $3,
        rebuild_group_id = $4,
        updated_at = now()
    WHERE name = $1
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.rowsAffected

listQueryRegistrationBindingsStmt :: Statement () [(Text, Text)]
listQueryRegistrationBindingsStmt =
  preparable
    """
    SELECT name, rebuild_group_id
    FROM keiro.keiro_read_models
    ORDER BY name
    """
    E.noParams
    (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))

lockGroupRegistrationsStmt :: Statement [Text] [(Text, Text)]
lockGroupRegistrationsStmt =
  preparable
    """
    SELECT name, rebuild_group_id
    FROM keiro.keiro_read_models
    WHERE rebuild_group_id = ANY($1)
    ORDER BY name
    FOR UPDATE
    """
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
    (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))

deleteQueryRegistrationsStmt :: Statement [Text] ()
deleteQueryRegistrationsStmt =
  preparable
    """
    DELETE FROM keiro.keiro_read_models
    WHERE name = ANY($1)
    """
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
    D.noResult

deleteOrphanLegacyGroupsStmt :: Statement () ()
deleteOrphanLegacyGroupsStmt =
  preparable
    """
    DELETE FROM keiro.keiro_projection_rebuild_groups AS groups
    WHERE groups.slice_fingerprint = '$legacy-unmanaged'
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

-- | Insert a bounded batch of async-projection dedup identities. Existing
-- identities are expected during promotion retries and are left unchanged.
insertProjectionDedupBatchStmt :: Statement ([Text], [UUID]) Int64
insertProjectionDedupBatchStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_dedup (projection_name, event_id)
    SELECT pair.name, pair.event
    FROM unnest($1::text[], $2::uuid[]) AS pair (name, event)
    ON CONFLICT (projection_name, event_id) DO NOTHING
    """
    ( contrazip2
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
    )
    D.rowsAffected

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
