{- | The read-model rebuild lifecycle, expressed over a 'ReadModel'.

Thin, type-safe wrappers over the status transitions in
"Keiro.ReadModel.Schema" that take a whole 'ReadModel' and thread its
'name', 'version', and 'shapeHash' through for you. The intended sequence
when reshaping a projection is: 'rebuild' to take it offline, repopulate the
table from the event log, then 'promote' to serve it again — or
'abandonRebuild' to back out. While a model is rebuilding,
'Keiro.ReadModel.runQuery' rejects it with 'ReadModelNotLive'.

Operator runbook for an offline rebuild:

1. Stop or pause every worker that writes the read model's table. The helpers
   here do not coordinate workers for you.
2. Call 'rebuild'. This records the current schema identity with status
   'Rebuilding', so normal queries fail closed instead of serving a half-built
   table.
3. In the database, truncate or otherwise clear the projection table and reset
   the subscription checkpoint that feeds it to the replay position you intend
   to rebuild from.
4. Replay the event log through the projection code until it catches up to the
   current store head. Verify row counts, spot-check representative queries,
   and compare the subscription checkpoint with the store head.
5. Call 'promote' only after verification succeeds, then resume workers. If
   verification fails, call 'abandonRebuild' and keep the model offline until
   the data is repaired or restored.

This is deliberately an offline procedure. Keiro does not yet provide a
shadow-table or online cutover mechanism; applications that need zero-downtime
rebuilds must build that orchestration above this lifecycle API.
-}
module Keiro.ReadModel.Rebuild (
    RebuildError (..),
    startRebuild,
    finishRebuild,
    rebuild,
    promote,
    abandonRebuild,
)
where

import Contravariant.Extras (contrazip2)
import Data.Text.Encoding qualified as TE
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.ReadModel
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- | Why a rebuild could not be promoted.
data RebuildError
    = {- | The model name and current store head when a rebuild started before
      existing events but applied none of its feeding projections.
      -}
      RebuildProducedNoApplies !Text !GlobalPosition
    deriving stock (Generic, Eq, Show)

{- | Atomically take a model offline, truncate its data table, clear the dedup
keys for its feeding async projections, and reset every member of its
subscription to the supplied replay position.

The registry transition runs first and holds the row lock that
'Keiro.Projection.applyAsyncProjection' uses as its writer fence. PostgreSQL
keeps the table truncate transactional. Kiroku's public checkpoint save is
monotonic, so this helper deliberately resets @subscriptions.last_seen@
directly inside the same fenced transaction.
-}
startRebuild ::
    (Store :> es) =>
    ReadModel q r ->
    [Text] ->
    GlobalPosition ->
    Eff es ReadModelMetadata
startRebuild readModel projectionNames replayFrom =
    runTransaction $ do
        metadata <- transitionReadModelTxFor readModel Rebuilding
        Tx.sql (TE.encodeUtf8 ("TRUNCATE TABLE " <> qualifiedTableName readModel))
        unless (null projectionNames) $
            Tx.statement projectionNames deleteProjectionDedupStmt
        Tx.statement
            (readModel ^. #subscriptionName, globalPositionToInt replayFrom)
            resetSubscriptionCheckpointStmt
        pure metadata

{- | Promote a completed rebuild in the same transaction as its safety check.

When async projection names are supplied, a store head beyond @replayFrom@
requires at least one new dedup row. 'startRebuild' deleted those rows, so their
count is the model-independent number of projection applications during this
rebuild. An empty projection-name list denotes an inline-only model and skips
the guard because no async dedup rows can exist for it.
-}
finishRebuild ::
    (Store :> es) =>
    ReadModel q r ->
    [Text] ->
    GlobalPosition ->
    Eff es (Either RebuildError ReadModelMetadata)
finishRebuild readModel projectionNames replayFrom =
    runTransaction $ do
        headPosition <- Tx.statement () storeHeadPositionStmt
        applyCount <-
            if null projectionNames
                then pure 0
                else Tx.statement projectionNames countProjectionDedupStmt
        if null projectionNames || applyCount > 0 || headPosition <= replayFrom
            then Right <$> transitionReadModelTxFor readModel Live
            else pure (Left (RebuildProducedNoApplies (readModel ^. #name) headPosition))

{- | Mark a model 'Rebuilding', taking it out of service while it is
repopulated from the event log.
-}
rebuild :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
rebuild readModel =
    markRebuilding
        (readModel ^. #name)
        (readModel ^. #version)
        (readModel ^. #shapeHash)

-- | Mark a rebuilt model 'Live', returning it to service.
promote :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
promote readModel =
    markLive
        (readModel ^. #name)
        (readModel ^. #version)
        (readModel ^. #shapeHash)

-- | Mark a model 'Abandoned', backing out of an in-progress rebuild.
abandonRebuild :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
abandonRebuild readModel =
    markAbandoned
        (readModel ^. #name)
        (readModel ^. #version)
        (readModel ^. #shapeHash)

transitionReadModelTxFor :: ReadModel q r -> ReadModelStatus -> Tx.Transaction ReadModelMetadata
transitionReadModelTxFor readModel status =
    transitionReadModelTx
        (readModel ^. #name)
        (readModel ^. #version)
        (readModel ^. #shapeHash)
        status

deleteProjectionDedupStmt :: Statement [Text] ()
deleteProjectionDedupStmt =
    preparable
        """
        DELETE FROM keiro.keiro_projection_dedup
        WHERE projection_name = ANY($1)
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        D.noResult

countProjectionDedupStmt :: Statement [Text] Int64
countProjectionDedupStmt =
    preparable
        """
        SELECT count(*)
        FROM keiro.keiro_projection_dedup
        WHERE projection_name = ANY($1)
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        (D.singleRow (D.column (D.nonNullable D.int8)))

resetSubscriptionCheckpointStmt :: Statement (Text, Int64) ()
resetSubscriptionCheckpointStmt =
    preparable
        """
        UPDATE subscriptions
        SET last_seen = $2, updated_at = now()
        WHERE subscription_name = $1
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int8))
        )
        D.noResult

storeHeadPositionStmt :: Statement () GlobalPosition
storeHeadPositionStmt =
    preparable
        """
        SELECT COALESCE(max(stream_version), 0)
        FROM stream_events
        WHERE stream_id = 0
        """
        E.noParams
        (D.singleRow (GlobalPosition <$> D.column (D.nonNullable D.int8)))

globalPositionToInt :: GlobalPosition -> Int64
globalPositionToInt (GlobalPosition position) = position
