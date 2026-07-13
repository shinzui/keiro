{- | Projections: turning a stream's events into read-side state.

Two flavors, trading consistency against coupling:

* An 'InlineProjection' runs in the /same/ transaction as the command that
  produced the events, so the read model is updated atomically with the
  append — never stale, but tied to the writer's transaction and latency.
  'runCommandWithProjections' runs a command and applies a list of inline
  projections to whatever it emits.
* An 'AsyncProjection' runs later from a subscription draining the event
  log. It carries a 'subscriptionName' for checkpointing and an
  'idempotencyKey' so redelivery is safe; 'applyAsyncProjection' performs
  one application. This decouples the read model from the writer at the
  cost of eventual consistency.

Both ultimately fold events into a SQL read model via a
'Hasql.Transaction.Transaction'; the difference is only /when/ that
transaction runs.
-}
module Keiro.Projection (
    -- * Inline projections
    InlineProjection (..),
    runCommandWithProjections,

    -- * Asynchronous projections
    AsyncProjection (..),
    AsyncApplyOutcome (..),
    applyAsyncProjection,
    applyAsyncProjectionUnfenced,
    pruneAsyncProjectionDedupBefore,
    recordProjectionLag,
)
where

import Contravariant.Extras (contrazip2)
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Stack (HasCallStack)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError, CommandResult, RunCommandOptions, runCommandWithSqlEvents)
import Keiro.EventStream (EventStream)
import Keiro.EventStream.Validate (ValidatedEventStream)
import Keiro.Prelude
import Keiro.ReadModel (readSubscriptionPosition, storeHeadPosition)
import Keiro.Stream (Stream)
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Telemetry qualified as Telemetry
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..), RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

{- | A read-model update applied synchronously with the command that emits
the event. 'apply' receives both the decoded event @co@ and the
'RecordedEvent' the store persisted, and runs in the append transaction.
'name' identifies the projection for diagnostics.
-}
data InlineProjection co = InlineProjection
    { name :: !Text
    , apply :: !(co -> RecordedEvent -> Tx.Transaction ())
    }
    deriving stock (Generic)

{- | A read-model update applied asynchronously by a subscription worker.

* 'name' — identifies the projection for diagnostics.
* 'readModelName' — names the registry row for the model this projection writes.
* 'subscriptionName' — the cursor under which the worker checkpoints its
  progress through the event log.
* 'applyRecorded' — folds one 'RecordedEvent' into the read model.
* 'idempotencyKey' — the 'EventId' used to suppress duplicate application on
  redelivery, making the projection safe to retry.
-}
data AsyncProjection = AsyncProjection
    { name :: !Text
    , readModelName :: !Text
    , subscriptionName :: !Text
    , applyRecorded :: !(RecordedEvent -> Tx.Transaction ())
    , idempotencyKey :: !(RecordedEvent -> EventId)
    }
    deriving stock (Generic)

-- | The database-visible result of one asynchronous projection attempt.
data AsyncApplyOutcome
    = AsyncApplied
    | AsyncDuplicate
    | AsyncFenced
    deriving stock (Generic, Eq, Show)

{- | Run a command and apply every supplied 'InlineProjection' to the events
it emits, all inside the command's append transaction. A projection failure
aborts the whole transaction, so the events and the read-model update commit
together or not at all.
-}
runCommandWithProjections ::
    forall phi rs s ci co es.
    (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    ValidatedEventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    ci ->
    [InlineProjection co] ->
    Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co)))
runCommandWithProjections options eventStream targetStream command projections = do
    result <-
        runCommandWithSqlEvents
            options
            eventStream
            targetStream
            command
            ( \pairs _appendResult ->
                traverse_
                    ( \projection ->
                        traverse_
                            (\(event, recorded) -> (projection ^. #apply) event recorded)
                            pairs
                    )
                    projections
            )
    pure (fmap Prelude.fst result)

{- | Apply one event to a live 'AsyncProjection', returning a distinct outcome
for a successful application, a retained dedup key, or a rebuild fence.

The registry row is read with @FOR SHARE@ inside the same transaction as the
dedup insert and application. A missing row or any status other than @live@
returns 'AsyncFenced' without touching either table. A worker that receives
'AsyncFenced' must not checkpoint past the event: fail or park the delivery and
retry after promotion. Ack-coupled Kiroku delivery preserves the checkpoint
when its handler does not acknowledge success.

The projection's 'idempotencyKey' is inserted into @keiro_projection_dedup@
inside the same transaction as 'applyRecorded'. When that insert conflicts,
the event was already applied within the retained dedup window and the update
is skipped. Use 'pruneAsyncProjectionDedupBefore' only for events older than
the subscription system can redeliver; pruning intentionally re-opens those
events for application if they are replayed later.
-}
applyAsyncProjection :: AsyncProjection -> RecordedEvent -> Tx.Transaction AsyncApplyOutcome
applyAsyncProjection projection recorded = do
    status <-
        Tx.statement
            (projection ^. #readModelName)
            lockReadModelStatusStmt
    case status of
        Just "live" -> applyAsyncProjectionUnfenced projection recorded
        _ -> pure AsyncFenced

{- | Apply one event without consulting the read-model registry fence.

This is exclusively the rebuild replay entry point: it retains normal dedup
semantics while permitting the designated rebuilder to write while the model is
@rebuilding@. Live workers must use 'applyAsyncProjection'.
-}
applyAsyncProjectionUnfenced :: AsyncProjection -> RecordedEvent -> Tx.Transaction AsyncApplyOutcome
applyAsyncProjectionUnfenced projection recorded = do
    inserted <-
        Tx.statement
            (projection ^. #name, eventIdToUuid ((projection ^. #idempotencyKey) recorded))
            insertProjectionDedupStmt
    if inserted
        then do
            (projection ^. #applyRecorded) recorded
            pure AsyncApplied
        else pure AsyncDuplicate

{- | Age out async-projection dedup rows older than the supplied timestamp.

Use this only beyond the subscription system's redelivery window; pruning
re-opens those events for application. It is not a rebuild reset. Supported
rebuilds use 'Keiro.ReadModel.Rebuild.startRebuild', which atomically deletes
only the named projections' keys while fencing writers and resetting the model.
Returns the number of rows pruned.
-}
pruneAsyncProjectionDedupBefore :: (Store :> es) => UTCTime -> Eff es Int64
pruneAsyncProjectionDedupBefore cutoff =
    runTransaction
        $ Tx.statement cutoff pruneProjectionDedupBeforeStmt

{- | Record 'keiro.projection.lag' for one async projection: how many events its
subscription is behind the global log head, computed as the store head global
position minus the subscription's checkpoint position (clamped at 0). A no-op
when no metrics handle is supplied. Call once per drain pass, after applying the
batch, so the gauge reflects the backlog the worker has left to catch up on.

There is no in-library polling drain loop today (the application drives
'applyAsyncProjection' per event), so this is the entry point an application
calls to surface lag for a subscription.
-}
recordProjectionLag ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    AsyncProjection ->
    Eff es ()
recordProjectionLag metrics projection = do
    headPos <- storeHeadPosition
    checkpoint <-
        fromMaybe (GlobalPosition 0)
            <$> readSubscriptionPosition (projection ^. #subscriptionName)
    Telemetry.recordProjectionLag metrics (positionGap headPos checkpoint)

-- | The non-negative gap between the log head and a checkpoint, in events.
positionGap :: GlobalPosition -> GlobalPosition -> Int64
positionGap (GlobalPosition headP) (GlobalPosition checkP) = max 0 (headP Prelude.- checkP)

insertProjectionDedupStmt :: Statement (Text, UUID) Bool
insertProjectionDedupStmt =
    preparable
        """
        INSERT INTO keiro.keiro_projection_dedup (projection_name, event_id)
        VALUES ($1, $2)
        ON CONFLICT (projection_name, event_id) DO NOTHING
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.uuid))
        )
        ((> 0) <$> D.rowsAffected)

lockReadModelStatusStmt :: Statement Text (Maybe Text)
lockReadModelStatusStmt =
    preparable
        """
        SELECT status
        FROM keiro.keiro_read_models
        WHERE name = $1
        FOR SHARE
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (D.column (D.nonNullable D.text)))

pruneProjectionDedupBeforeStmt :: Statement UTCTime Int64
pruneProjectionDedupBeforeStmt =
    preparable
        """
        DELETE FROM keiro.keiro_projection_dedup
        WHERE applied_at < $1
        """
        (E.param (E.nonNullable E.timestamptz))
        D.rowsAffected

eventIdToUuid :: EventId -> UUID
eventIdToUuid (EventId value) = value
