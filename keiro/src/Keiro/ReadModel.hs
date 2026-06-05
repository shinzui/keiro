{- | Querying the read side, with explicit consistency.

A 'ReadModel' is a named, versioned SQL projection table plus the query that
reads it. Querying it does more than run SQL: 'runQuery' first verifies the
table's registered schema is current and 'Live' (rejecting a stale or
mid-rebuild model), then honours the requested 'ConsistencyMode' before
running the query in a transaction.

The consistency modes trade freshness against latency:

* 'Strong' / 'Eventual' — query immediately; the names document the caller's
  expectation but neither blocks. (Read-your-writes is the projection
  worker's responsibility under 'Eventual'.)
* 'PositionWait' — block until the model's subscription has caught up to a
  target 'GlobalPosition' (typically the position returned by the command
  the caller just ran), giving read-your-writes against an asynchronous
  projection. 'waitFor' implements the polling loop and times out with
  'ReadModelWaitTimeout'.

Schema lifecycle (registration, status transitions) lives in
"Keiro.ReadModel.Schema", which is re-exported here.
-}
module Keiro.ReadModel (
    -- * Definition
    ReadModel (..),

    -- * Consistency
    ConsistencyMode (..),
    PositionWaitOptions (..),

    -- * Querying
    runQuery,
    runQueryWith,
    waitFor,
    readSubscriptionPosition,

    -- * Errors
    ReadModelError (..),

    -- * Schema lifecycle
    module Keiro.ReadModel.Schema,
)
where

import Control.Concurrent (threadDelay)
import Data.Time.Clock (diffUTCTime)
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.ReadModel.Schema
import Keiro.Telemetry (KeiroMetrics, recordProjectionWaitTimeouts)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

{- | A queryable read-side projection over a query input @q@ and result @r@.

* 'name' — logical identity, also the key in the @keiro_read_models@
  registry.
* 'tableName' — the underlying projection table.
* 'subscriptionName' — the cursor that tracks how far the projection worker
  has consumed the event log; consulted by 'PositionWait'.
* 'version' \/ 'shapeHash' — schema identity; a query fails with
  'ReadModelStaleSchema' if the registered values diverge, forcing a rebuild.
* 'defaultConsistency' — the 'ConsistencyMode' used by 'runQuery'.
* 'query' — the SQL read, as a 'Hasql.Transaction.Transaction'.
-}
data ReadModel q r = ReadModel
    { name :: !Text
    , tableName :: !Text
    , subscriptionName :: !Text
    , version :: !Int
    , shapeHash :: !Text
    , defaultConsistency :: !ConsistencyMode
    , query :: !(q -> Tx.Transaction r)
    }
    deriving stock (Generic)

{- | How fresh a read must be before the query runs.

'Strong' and 'Eventual' both query without blocking; 'PositionWait' blocks
until the projection has caught up to a target log position (or times out).
-}
data ConsistencyMode
    = Strong
    | Eventual
    | PositionWait !PositionWaitOptions
    deriving stock (Generic, Eq, Show)

{- | Parameters for a 'PositionWait' query.

* 'target' — the 'GlobalPosition' the projection must reach; 'Nothing'
  skips waiting entirely.
* 'timeoutMicros' — give up after this long with 'ReadModelWaitTimeout'.
* 'pollMicros' — delay between subscription-position checks.
-}
data PositionWaitOptions = PositionWaitOptions
    { target :: !(Maybe GlobalPosition)
    , timeoutMicros :: !Int
    , pollMicros :: !Int
    }
    deriving stock (Generic, Eq, Show)

-- | Why a read-model query could not run.
data ReadModelError
    = {- | The registered schema (version or shape hash) differs from the
      model's current definition: name, expected vs. found version, then
      expected vs. found shape hash. The model must be rebuilt.
      -}
      ReadModelStaleSchema !Text !Int !Int !Text !Text
    | {- | A 'PositionWait' query timed out: model name, target position, and
      the last observed subscription position.
      -}
      ReadModelWaitTimeout !Text !GlobalPosition !GlobalPosition
    | {- | The model is registered but not 'Live' (e.g. rebuilding or
      abandoned): name and current status.
      -}
      ReadModelNotLive !Text !ReadModelStatus
    deriving stock (Generic, Eq, Show)

{- | Query a read model using its 'defaultConsistency'. Validates schema and
liveness first, waits if the mode requires it, then runs the query.
-}
runQuery ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    ReadModel q r ->
    q ->
    Eff es (Either ReadModelError r)
runQuery metrics readModel =
    runQueryWith metrics (readModel ^. #defaultConsistency) readModel

{- | Query a read model with an explicit 'ConsistencyMode', overriding its
default. Validates the model's schema and liveness, honours the wait mode,
then runs the query in a transaction.
-}
runQueryWith ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    ConsistencyMode ->
    ReadModel q r ->
    q ->
    Eff es (Either ReadModelError r)
runQueryWith metrics consistency readModel input = do
    schemaCheck <- ensureReadModel readModel
    case schemaCheck of
        Left err -> pure (Left err)
        Right () -> do
            waitResult <- waitIfNeeded metrics consistency readModel
            case waitResult of
                Left err -> pure (Left err)
                Right () -> Right <$> runTransaction ((readModel ^. #query) input)

{- | Block until the model's subscription has advanced to @targetPosition@,
polling at 'pollMicros' intervals. Returns @Right ()@ once caught up, or
'ReadModelWaitTimeout' if 'timeoutMicros' elapses first.
-}
waitFor ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    PositionWaitOptions ->
    ReadModel q r ->
    GlobalPosition ->
    Eff es (Either ReadModelError ())
waitFor metrics options readModel targetPosition = do
    started <- liftIO getCurrentTime
    poll started (GlobalPosition 0)
  where
    poll started observed = do
        current <- readSubscriptionPosition (readModel ^. #subscriptionName)
        let observed' = fromMaybe observed current
        if observed' >= targetPosition
            then pure (Right ())
            else do
                now <- liftIO getCurrentTime
                let elapsedMicros =
                        Prelude.floor
                            (diffUTCTime now started Prelude.* 1000000)
                if elapsedMicros >= options ^. #timeoutMicros
                    then do
                        -- A genuine give-up: bump keiro.projection.wait.timeouts (no-op
                        -- under a 'Nothing' handle) before surfacing the timeout.
                        recordProjectionWaitTimeouts metrics 1
                        pure
                            (Left (ReadModelWaitTimeout (readModel ^. #name) targetPosition observed'))
                    else do
                        liftIO (threadDelay (options ^. #pollMicros))
                        poll started observed'

ensureReadModel ::
    (Store :> es) =>
    ReadModel q r ->
    Eff es (Either ReadModelError ())
ensureReadModel readModel = do
    metadata <-
        registerReadModel
            (readModel ^. #name)
            (readModel ^. #version)
            (readModel ^. #shapeHash)
    pure (validateMetadata readModel metadata)

validateMetadata :: ReadModel q r -> ReadModelMetadata -> Either ReadModelError ()
validateMetadata readModel metadata
    | metadata ^. #version /= readModel ^. #version =
        stale
    | metadata ^. #shapeHash /= readModel ^. #shapeHash =
        stale
    | metadata ^. #status /= Live =
        Left (ReadModelNotLive (readModel ^. #name) (metadata ^. #status))
    | otherwise =
        Right ()
  where
    stale =
        Left
            ( ReadModelStaleSchema
                (readModel ^. #name)
                (readModel ^. #version)
                (metadata ^. #version)
                (readModel ^. #shapeHash)
                (metadata ^. #shapeHash)
            )

waitIfNeeded ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    ConsistencyMode ->
    ReadModel q r ->
    Eff es (Either ReadModelError ())
waitIfNeeded _ Strong _ = pure (Right ())
waitIfNeeded _ Eventual _ = pure (Right ())
waitIfNeeded metrics (PositionWait options) readModel =
    case options ^. #target of
        Nothing -> pure (Right ())
        Just targetPosition -> waitFor metrics options readModel targetPosition

readSubscriptionPosition ::
    (Store :> es) =>
    Text ->
    Eff es (Maybe GlobalPosition)
readSubscriptionPosition subscriptionName =
    runTransaction
        $ Tx.statement subscriptionName lookupSubscriptionPositionStmt

lookupSubscriptionPositionStmt :: Statement Text (Maybe GlobalPosition)
lookupSubscriptionPositionStmt =
    preparable
        """
        SELECT last_seen
        FROM subscriptions
        WHERE subscription_name = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (GlobalPosition <$> D.column (D.nonNullable D.int8)))
