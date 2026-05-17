module Keiro.Projection
  ( InlineProjection (..)
  , AsyncProjection (..)
  , runCommandWithProjections
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
import Kiroku.Store.Types (AppendResult, EventId, RecordedEvent)
import Prelude qualified

data InlineProjection co = InlineProjection
  { name :: !Text
  , apply :: !(co -> AppendResult -> Tx.Transaction ())
  }
  deriving stock (Generic)

data AsyncProjection = AsyncProjection
  { name :: !Text
  , subscriptionName :: !Text
  , applyRecorded :: !(RecordedEvent -> Tx.Transaction ())
  , idempotencyKey :: !(RecordedEvent -> EventId)
  }
  deriving stock (Generic)

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
      ( \events appendResult ->
          traverse_ (\projection -> traverse_ (\event -> (projection ^. #apply) event appendResult) events) projections
      )
  pure (fmap Prelude.fst result)

applyAsyncProjection :: AsyncProjection -> RecordedEvent -> Tx.Transaction ()
applyAsyncProjection projection recorded =
  (projection ^. #applyRecorded) recorded
