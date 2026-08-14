{-# OPTIONS_HADDOCK hide #-}

-- | Typed decoding for the frozen public projection-group status relation.
-- The public facade is "Keiro.ReadModel.Rebuild".
module Keiro.ReadModel.Rebuild.Status
  ( ServingPositionBasis (..),
    ProjectionGroupStatusV1 (..),
    listProjectionGroupStatuses,
    lookupProjectionGroupStatus,
  )
where

import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
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
