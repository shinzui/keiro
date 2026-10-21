{-# OPTIONS_HADDOCK hide #-}

-- | Typed decoding for the frozen public projection-group status relation.
-- The public facade is "Keiro.ReadModel.Rebuild".
module Keiro.ReadModel.Rebuild.Status
  ( ServingPositionBasis (..),
    ProjectionGroupStatusV1 (..),
    listProjectionGroupStatuses,
    lookupProjectionGroupStatus,
    ProjectionStatusPageRequest (..),
    ProjectionStatusReadError (..),
    ProjectionStatusPage (..),
    projectionGroupsCursorKind,
    validateProjectionStatusRequest,
    listProjectionGroupStatusesPage,
  )
where

import Contravariant.Extras (contrazip2)
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Inspection.Cursor
import Keiro.Prelude
import Keiro.Projection.Catalog
  ( ProjectionRevisionId,
    RebuildGroupId,
    mkProjectionRevisionId,
    mkRebuildGroupId,
    rebuildGroupIdText,
  )
import Keiro.ReadModel.Rebuild.Group
  ( RebuildRunId,
    mkRebuildRunId,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- | The v1 interpretation of 'servingAppliedPosition'. Unknown future values
-- require a new SQL contract and deliberately fail this decoder.
data ServingPositionBasis
  = ServingPositionAppend
  | ServingPositionCheckpoint
  | ServingPositionUnmanaged
  deriving stock (Eq, Ord, Show, Generic)

-- | One row from @keiro_read.projection_group_status_v1@. Lifecycle is
-- diagnostic; 'readsAllowed' is the authoritative read-availability fact.
data ProjectionGroupStatusV1 = ProjectionGroupStatusV1
  { groupId :: !RebuildGroupId,
    lifecyclePhase :: !Text,
    readsAllowed :: !Bool,
    writesAllowed :: !Bool,
    servingRevisionId :: !(Maybe ProjectionRevisionId),
    servingEpoch :: !Int64,
    servingPositionBasis :: !ServingPositionBasis,
    servingAppliedPosition :: !(Maybe GlobalPosition),
    activeRunId :: !(Maybe RebuildRunId),
    candidateRevisionId :: !(Maybe ProjectionRevisionId),
    candidateRebuildPosition :: !(Maybe GlobalPosition),
    candidateRebuildHead :: !(Maybe GlobalPosition),
    queryModels :: ![Text],
    rebuildStartedAt :: !(Maybe UTCTime),
    lastPromotedAt :: !(Maybe UTCTime),
    failedAt :: !(Maybe UTCTime),
    failureCode :: !(Maybe Text),
    failureDetail :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | A bounded observation of the frozen v1 relation. The existing unbounded
-- compatibility API below retains its behavior.
data ProjectionStatusPageRequest = ProjectionStatusPageRequest
  {pageSize :: !Int, after :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show, Generic)

data ProjectionStatusReadError
  = InvalidProjectionStatusPageSize !Int
  | InvalidProjectionStatusCursor !CursorError
  | ProjectionStatusResultTooLarge
  deriving stock (Eq, Show, Generic)

data ProjectionStatusPage = ProjectionStatusPage
  {observedAt :: !UTCTime, items :: ![ProjectionGroupStatusV1], next :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show, Generic)

projectionGroupsCursorKind :: Text
projectionGroupsCursorKind = "projection-groups"

validateProjectionStatusRequest :: ProjectionStatusPageRequest -> Either ProjectionStatusReadError (Maybe Text)
validateProjectionStatusRequest request
  | request ^. #pageSize < 1 || request ^. #pageSize > 500 = Left (InvalidProjectionStatusPageSize (request ^. #pageSize))
  | otherwise = traverse decode (request ^. #after)
  where
    decode cursor = do
      (contract, groupId) <- either (Left . InvalidProjectionStatusCursor) Right (decodeCursor projectionGroupsCursorKind cursor)
      if contract /= ("projection_group_status_v1" :: Text)
        then invalid "cursor belongs to another status contract"
        else either (const (invalid "invalid group id")) (Right . rebuildGroupIdText) (mkRebuildGroupId groupId)
    invalid = Left . InvalidProjectionStatusCursor . MalformedCursor

-- | Page in database group-id order, with exclusive continuation and one
-- look-ahead row. Select Keiro-owned group keys first, then use correlated
-- lookups through the frozen owner relation. The OFFSET 0 boundary preserves
-- parameterized lookups instead of flattening the view into fleet-wide joins.
-- A group's own model/checkpoint cardinality remains part of its read cost.
listProjectionGroupStatusesPage :: (Store :> es) => ProjectionStatusPageRequest -> Eff es (Either ProjectionStatusReadError ProjectionStatusPage)
listProjectionGroupStatusesPage request = case validateProjectionStatusRequest request of
  Left err -> pure (Left err)
  Right after -> do
    (observed, rows) <- runTransaction $ do
      observed <- Tx.statement () (preparable "SELECT now()" mempty (D.singleRow (D.column (D.nonNullable D.timestamptz))))
      rows <- Tx.statement (after, fromIntegral size + 1) (pageProjectionGroupStatusesStmt (isJust after))
      pure (observed, rows)
    let selected = take size rows
        continuation = case (drop size rows, reverse selected) of
          (_ : _, row : _) ->
            maybe
              (Left ProjectionStatusResultTooLarge)
              (Right . Just)
              (encodeCursorBounded projectionGroupsCursorKind ("projection_group_status_v1" :: Text, rebuildGroupIdText (row ^. #groupId)))
          _ -> Right Nothing
    pure (ProjectionStatusPage observed selected <$> continuation)
  where
    size = request ^. #pageSize

pageProjectionGroupStatusesStmt :: Bool -> Statement (Maybe Text, Int64) [ProjectionGroupStatusV1]
pageProjectionGroupStatusesStmt after =
  preparable
    ( "WITH inspection_groups AS MATERIALIZED (SELECT group_id FROM keiro.keiro_projection_rebuild_groups"
        <> (if after then " WHERE group_id > $1" else " WHERE $1::text IS NULL")
        <> " ORDER BY group_id LIMIT $2) SELECT status.* FROM inspection_groups page CROSS JOIN LATERAL ("
        <> statusSelect
        <> " WHERE group_id = page.group_id OFFSET 0) status ORDER BY status.group_id"
    )
    (contrazip2 (E.param (E.nullable E.text)) (E.param (E.nonNullable E.int8)))
    (D.rowList projectionGroupStatusDecoder)

-- | List the complete public status relation in stable group-id order.
listProjectionGroupStatuses ::
  (Store :> es) =>
  Eff es [ProjectionGroupStatusV1]
listProjectionGroupStatuses =
  runTransaction $ Tx.statement () listProjectionGroupStatusesStmt

-- | Look up one status row by stable rebuild-group identity.
lookupProjectionGroupStatus ::
  (Store :> es) =>
  RebuildGroupId ->
  Eff es (Maybe ProjectionGroupStatusV1)
lookupProjectionGroupStatus groupId =
  runTransaction $
    Tx.statement
      (rebuildGroupIdText groupId)
      lookupProjectionGroupStatusStmt

listProjectionGroupStatusesStmt :: Statement () [ProjectionGroupStatusV1]
listProjectionGroupStatusesStmt =
  preparable
    (statusSelect <> " ORDER BY group_id")
    E.noParams
    (D.rowList projectionGroupStatusDecoder)

lookupProjectionGroupStatusStmt :: Statement Text (Maybe ProjectionGroupStatusV1)
lookupProjectionGroupStatusStmt =
  preparable
    (statusSelect <> " WHERE group_id = $1")
    (E.param (E.nonNullable E.text))
    (D.rowMaybe projectionGroupStatusDecoder)

statusSelect :: Text
statusSelect =
  """
  SELECT group_id,
         lifecycle_phase,
         reads_allowed,
         writes_allowed,
         serving_revision_id,
         serving_epoch,
         serving_position_basis,
         serving_applied_position,
         active_run_id,
         candidate_revision_id,
         candidate_rebuild_position,
         candidate_rebuild_head,
         query_models,
         rebuild_started_at,
         last_promoted_at,
         failed_at,
         failure_code,
         failure_detail
  FROM keiro_read.projection_group_status_v1
  """

projectionGroupStatusDecoder :: D.Row ProjectionGroupStatusV1
projectionGroupStatusDecoder =
  ProjectionGroupStatusV1
    <$> D.column (D.nonNullable (D.refine decodeGroupId D.text))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.bool)
    <*> D.column (D.nonNullable D.bool)
    <*> D.column (D.nullable (D.refine decodeRevisionId D.text))
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable (D.refine decodeServingPositionBasis D.text))
    <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8))
    <*> D.column (D.nullable (D.refine decodeRunId D.text))
    <*> D.column (D.nullable (D.refine decodeRevisionId D.text))
    <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8))
    <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8))
    <*> D.column (D.nonNullable (D.listArray (D.nonNullable D.text)))
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)

decodeGroupId :: Text -> Either Text RebuildGroupId
decodeGroupId raw =
  case mkRebuildGroupId raw of
    Right value -> Right value
    Left err -> Left ("invalid projection status group id: " <> Text.pack (show err))

decodeRevisionId :: Text -> Either Text ProjectionRevisionId
decodeRevisionId raw =
  case mkProjectionRevisionId raw of
    Right value -> Right value
    Left err -> Left ("invalid projection status revision id: " <> Text.pack (show err))

decodeRunId :: Text -> Either Text RebuildRunId
decodeRunId raw =
  case mkRebuildRunId raw of
    Right value -> Right value
    Left err -> Left ("invalid projection status run id: " <> err)

decodeServingPositionBasis :: Text -> Either Text ServingPositionBasis
decodeServingPositionBasis = \case
  "append" -> Right ServingPositionAppend
  "checkpoint" -> Right ServingPositionCheckpoint
  "unmanaged" -> Right ServingPositionUnmanaged
  raw -> Left ("unknown projection status serving position basis: " <> raw)
