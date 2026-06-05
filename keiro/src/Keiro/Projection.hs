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
    applyAsyncProjection,
    recordProjectionLag,
)
where

import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Stack (HasCallStack)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError, CommandResult, RunCommandOptions, runCommandWithSqlEvents)
import Keiro.EventStream (EventStream)
import Keiro.Prelude
import Keiro.ReadModel (readSubscriptionPosition)
import Keiro.Stream (Stream)
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Telemetry qualified as Telemetry
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readAllBackward)
import Kiroku.Store.Types (EventId, GlobalPosition (..), RecordedEvent)
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
* 'subscriptionName' — the cursor under which the worker checkpoints its
  progress through the event log.
* 'applyRecorded' — folds one 'RecordedEvent' into the read model.
* 'idempotencyKey' — the 'EventId' used to suppress duplicate application on
  redelivery, making the projection safe to retry.
-}
data AsyncProjection = AsyncProjection
    { name :: !Text
    , subscriptionName :: !Text
    , applyRecorded :: !(RecordedEvent -> Tx.Transaction ())
    , idempotencyKey :: !(RecordedEvent -> EventId)
    }
    deriving stock (Generic)

{- | Run a command and apply every supplied 'InlineProjection' to the events
it emits, all inside the command's append transaction. A projection failure
aborts the whole transaction, so the events and the read-model update commit
together or not at all.
-}
runCommandWithProjections ::
    forall phi rs s ci co es.
    (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
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

{- | Apply one event to an 'AsyncProjection', returning the read-model update
as a 'Hasql.Transaction.Transaction' for the subscription worker to run.
-}
applyAsyncProjection :: AsyncProjection -> RecordedEvent -> Tx.Transaction ()
applyAsyncProjection projection recorded =
    (projection ^. #applyRecorded) recorded

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

{- | The global position of the most recent event in the @$all@ log, or
@GlobalPosition 0@ when the log is empty. 'readAllBackward' treats
@GlobalPosition 0@ as "after everything", so a limit of 1 returns the head.
-}
storeHeadPosition :: (Store :> es) => Eff es GlobalPosition
storeHeadPosition = do
    recent <- readAllBackward (GlobalPosition 0) 1
    pure $ case Vector.toList recent of
        (event : _) -> event ^. #globalPosition
        [] -> GlobalPosition 0

-- | The non-negative gap between the log head and a checkpoint, in events.
positionGap :: GlobalPosition -> GlobalPosition -> Int64
positionGap (GlobalPosition headP) (GlobalPosition checkP) = max 0 (headP Prelude.- checkP)
