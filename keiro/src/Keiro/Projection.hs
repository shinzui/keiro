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
module Keiro.Projection
  ( -- * Inline projections
    InlineProjection (..)
  , runCommandWithProjections

    -- * Asynchronous projections
  , AsyncProjection (..)
  , applyAsyncProjection
  )
where

import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Stack (HasCallStack)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError, CommandResult, RunCommandOptions, runCommandWithSqlEvents)
import Keiro.EventStream (EventStream)
import Keiro.Prelude
import Keiro.Stream (Stream)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventId, RecordedEvent)
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

-- | Apply one event to an 'AsyncProjection', returning the read-model update
-- as a 'Hasql.Transaction.Transaction' for the subscription worker to run.
applyAsyncProjection :: AsyncProjection -> RecordedEvent -> Tx.Transaction ()
applyAsyncProjection projection recorded =
  (projection ^. #applyRecorded) recorded
