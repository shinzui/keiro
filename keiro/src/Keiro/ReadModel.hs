-- | Querying the read side, with explicit consistency.
--
-- A 'ReadModel' is a named, versioned SQL projection table plus the query that
-- reads it. Querying it does more than run SQL: 'runQuery' first verifies the
-- table's registered schema is current and 'Live' (rejecting a stale or
-- mid-rebuild model), then honours the requested 'ConsistencyMode' before
-- running the query in a transaction.
--
-- The consistency modes trade freshness against latency:
--
-- * 'Strong' — capture the store head position at query start and block until
--   the model's subscription cursor reaches it.
-- * 'Eventual' — query immediately. Read-your-writes is the projection worker's
--   responsibility under 'Eventual'.
-- * 'PositionWait' — block until the model's subscription has caught up to a
--   target 'GlobalPosition' (typically the position returned by the command
--   the caller just ran), giving read-your-writes against an asynchronous
--   projection. 'waitFor' implements the polling loop and times out with
--   'ReadModelWaitTimeout'.
--
-- Schema lifecycle (registration, status transitions) lives in
-- "Keiro.ReadModel.Schema", which is re-exported here.
--
-- Register each model once at projection startup with 'registerReadModel' before
-- serving queries. Queries fail with 'ReadModelUnregistered' when startup wiring
-- has not registered the model; they never create registry rows themselves.
module Keiro.ReadModel
  ( -- * Definition
    ReadModel (..),
    ReadModelBlueprint (..),
    QueryCursorAuthority (..),
    ReadModelDefinitionError (..),
    immediateReadModel,
    headWaitingReadModel,
    positionWaitingReadModel,
    readModelCursorAuthority,
    readModelDefaultFreshness,
    qualifiedTableName,

    -- * Freshness
    QueryFreshness (..),
    HeadScope (..),
    defaultHeadWaitOptions,

    -- * Deprecated consistency compatibility
    ConsistencyMode (..),
    StrongScope (..),
    PositionWaitOptions (..),
    defaultStrongWaitOptions,

    -- * Querying
    runQuery,
    runQueryWith,
    waitFor,
    subscriptionPositionFromInventory,
    readSubscriptionPosition,
    storeHeadPosition,
    categoryHeadPosition,

    -- * Errors
    ReadModelError (..),

    -- * Schema lifecycle
    module Keiro.ReadModel.Schema,
  )
where

import Control.Concurrent (threadDelay)
import Data.Time.Clock (diffUTCTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Connection (qualifyTable)
import Keiro.Prelude
import Keiro.ReadModel.Schema
import Keiro.Telemetry (KeiroMetrics, recordProjectionWaitTimeouts)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Subscription
  ( SubscriptionCheckpoint (..),
    SubscriptionCheckpointInventory (..),
    SubscriptionName (..),
    subscriptionCheckpointInventory,
  )
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

-- | A queryable read-side projection over a query input @q@ and result @r@.
--
-- * 'name' — logical identity, also the key in the @keiro_read_models@
--   registry.
-- * 'tableName' — the underlying projection table.
-- * 'schema' — the PostgreSQL schema the read-model /data/ table lives in. The
--   application qualifies its 'query' SQL against this schema (typically via
--   'Keiro.Connection.qualifyTable' or 'qualifiedTableName'); Keiro does not
--   rewrite 'query'. This is the application's data schema and is entirely
--   separate from Keiro's own @keiro@ schema, where the @keiro_read_models@
--   registry lives. It is deliberately not persisted (see 'ensureReadModel').
-- * 'subscriptionName' — the cursor that tracks how far the projection worker
--   has consumed the event log; consulted by 'PositionWait'.
-- * 'version' \/ 'shapeHash' — schema identity; a query fails with
--   'ReadModelStaleSchema' if the registered values diverge, forcing a rebuild.
-- * 'defaultConsistency' — the 'ConsistencyMode' used by 'runQuery'.
-- * 'strongScope' — the event-log head a 'Strong' query waits for.
-- * 'query' — the SQL read, as a 'Hasql.Transaction.Transaction'.
data ReadModel q r = ReadModel
  { name :: !Text,
    tableName :: !Text,
    schema :: !Text,
    subscriptionName :: !Text,
    version :: !Int,
    shapeHash :: !Text,
    defaultConsistency :: !ConsistencyMode,
    strongScope :: !StrongScope,
    query :: !(q -> Tx.Transaction r)
  }
  deriving stock (Generic)

-- | The cursor capability available to a read model. Immediate queries need no
-- cursor. Head and caller-position waits require exactly one durable cursor
-- whose checkpoint represents the projection supplying the model.
data QueryCursorAuthority
  = NoQueryCursor
  | DurableQueryCursor !Text
  deriving stock (Generic, Eq, Show)

-- | Honest construction input for a 'ReadModel'. It contains query identity,
-- schema, and SQL without requiring legacy consistency fields or a fictional
-- subscription name for an inline model.
data ReadModelBlueprint q r = ReadModelBlueprint
  { name :: !Text,
    tableName :: !Text,
    schema :: !Text,
    version :: !Int,
    shapeHash :: !Text,
    cursorAuthority :: !QueryCursorAuthority,
    query :: !(q -> Tx.Transaction r)
  }
  deriving stock (Generic)

-- | Why an honest read-model definition could not be constructed.
data ReadModelDefinitionError
  = -- | A waiting default was requested for a model without a durable cursor:
    -- model name and requested freshness.
    ReadModelDefinitionMissingCursor !Text !QueryFreshness
  | -- | A position-waiting default omitted its required target: model name.
    ReadModelDefinitionMissingPosition !Text
  deriving stock (Generic, Eq, Show)

-- | What, if anything, a query waits for before executing its SQL.
data QueryFreshness
  = Immediate
  | WaitForHead !HeadScope
  | WaitForPosition !PositionWaitOptions
  deriving stock (Generic, Eq, Show)

-- | The visible event-log boundary captured by 'WaitForHead'.
data HeadScope
  = EntireVisibleLog
  | CategoryVisibleHead !Text
  deriving stock (Generic, Eq, Show)

-- | Build a read model whose default query executes immediately. The model may
-- still retain a durable cursor for caller-selected position waits.
immediateReadModel :: ReadModelBlueprint q r -> ReadModel q r
immediateReadModel = blueprintReadModel Immediate

-- | Build a read model whose default query waits for a captured visible head.
-- A durable cursor is required because an inline-only model has nothing that
-- can advance while the query waits.
headWaitingReadModel ::
  HeadScope ->
  ReadModelBlueprint q r ->
  Either ReadModelDefinitionError (ReadModel q r)
headWaitingReadModel scope blueprint =
  requireCursor blueprint (WaitForHead scope)

-- | Build a read model whose default query waits for a concrete caller-supplied
-- position. Both a durable cursor and a non-'Nothing' target are required.
positionWaitingReadModel ::
  PositionWaitOptions ->
  ReadModelBlueprint q r ->
  Either ReadModelDefinitionError (ReadModel q r)
positionWaitingReadModel options blueprint =
  case options ^. #target of
    Nothing -> Left (ReadModelDefinitionMissingPosition (blueprint ^. #name))
    Just _ -> requireCursor blueprint (WaitForPosition options)

-- | Recover the honest cursor capability from the compatibility representation.
-- Values built directly with the legacy record retain their named subscription.
readModelCursorAuthority :: ReadModel q r -> QueryCursorAuthority
readModelCursorAuthority readModel
  | readModel ^. #subscriptionName == noQueryCursorSentinel = NoQueryCursor
  | otherwise = DurableQueryCursor (readModel ^. #subscriptionName)

-- | Translate the legacy default into its exact operational freshness. In
-- particular, the historical @PositionWait@ with no target is immediate.
readModelDefaultFreshness :: ReadModel q r -> QueryFreshness
readModelDefaultFreshness readModel =
  case readModel ^. #defaultConsistency of
    Strong -> WaitForHead (legacyHeadScope (readModel ^. #strongScope))
    Eventual -> Immediate
    PositionWait options ->
      case options ^. #target of
        Nothing -> Immediate
        Just _ -> WaitForPosition options

blueprintReadModel :: QueryFreshness -> ReadModelBlueprint q r -> ReadModel q r
blueprintReadModel freshness blueprint =
  ReadModel
    { name = blueprint ^. #name,
      tableName = blueprint ^. #tableName,
      schema = blueprint ^. #schema,
      subscriptionName = cursorText (blueprint ^. #cursorAuthority),
      version = blueprint ^. #version,
      shapeHash = blueprint ^. #shapeHash,
      defaultConsistency = legacyConsistency freshness,
      strongScope = legacyStrongScope freshness,
      query = blueprint ^. #query
    }

requireCursor ::
  ReadModelBlueprint q r ->
  QueryFreshness ->
  Either ReadModelDefinitionError (ReadModel q r)
requireCursor blueprint freshness =
  case blueprint ^. #cursorAuthority of
    NoQueryCursor ->
      Left (ReadModelDefinitionMissingCursor (blueprint ^. #name) freshness)
    DurableQueryCursor _ -> Right (blueprintReadModel freshness blueprint)

cursorText :: QueryCursorAuthority -> Text
cursorText NoQueryCursor = noQueryCursorSentinel
cursorText (DurableQueryCursor cursor) = cursor

noQueryCursorSentinel :: Text
noQueryCursorSentinel = "\NULkeiro:no-query-cursor"

legacyConsistency :: QueryFreshness -> ConsistencyMode
legacyConsistency Immediate = Eventual
legacyConsistency WaitForHead {} = Strong
legacyConsistency (WaitForPosition options) = PositionWait options

legacyStrongScope :: QueryFreshness -> StrongScope
legacyStrongScope (WaitForHead EntireVisibleLog) = EntireLog
legacyStrongScope (WaitForHead (CategoryVisibleHead category)) = CategoryHead category
legacyStrongScope _ = EntireLog

legacyHeadScope :: StrongScope -> HeadScope
legacyHeadScope EntireLog = EntireVisibleLog
legacyHeadScope (CategoryHead category) = CategoryVisibleHead category

-- | The read model's fully-qualified, double-quoted table reference
-- @"schema"."table"@, for interpolation into the application's projection SQL.
-- Equal to @'Keiro.Connection.qualifyTable' ('schema' rm) ('tableName' rm)@.
qualifiedTableName :: ReadModel q r -> Text
qualifiedTableName readModel =
  qualifyTable (readModel ^. #schema) (readModel ^. #tableName)

-- | How fresh a read must be before the query runs.
--
-- 'Strong' waits for the model's subscription to reach the store head captured
-- at query start according to the model's 'strongScope'. It is intended for
-- asynchronous read models with a worker advancing that subscription cursor;
-- inline-only models should use 'Eventual' because they have no subscription
-- worker to advance while waiting.
-- 'PositionWait' blocks until the projection has caught up to a caller-supplied
-- target log position (or times out). 'Eventual' queries immediately.
data ConsistencyMode
  = Strong
  | Eventual
  | PositionWait !PositionWaitOptions
  deriving stock (Generic, Eq, Show)

-- | Which log head a 'Strong' read must reach.
--
-- 'EntireLog' preserves the original behavior and is live only when the model's
-- subscription observes every event. A category subscription should use
-- 'CategoryHead' with its Kiroku category, so unrelated categories cannot hold
-- the read behind forever. A model fed by multiple categories should use
-- 'PositionWait' for an explicit write position or 'EntireLog' with a matching
-- all-stream subscription.
--
-- Kiroku currently does not advance category checkpoints on empty fetches. If it
-- does so in a future release, category-scoped targets may become unnecessary,
-- but the explicit model contract remains valid.
data StrongScope
  = EntireLog
  | CategoryHead !Text
  deriving stock (Generic, Eq, Show)

-- | Parameters for a 'PositionWait' query.
--
-- * 'target' — the 'GlobalPosition' the projection must reach; 'Nothing'
--   skips waiting entirely.
-- * 'timeoutMicros' — give up after this long with 'ReadModelWaitTimeout'.
-- * 'pollMicros' — delay between subscription-position checks.
data PositionWaitOptions = PositionWaitOptions
  { target :: !(Maybe GlobalPosition),
    timeoutMicros :: !Int,
    pollMicros :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | Default wait settings used by 'Strong': wait up to five seconds, polling
-- every 10ms, for the store head captured at query start.
defaultStrongWaitOptions :: PositionWaitOptions
defaultStrongWaitOptions = defaultHeadWaitOptions

-- | Default options for a captured-head wait: five seconds total, polling
-- every 10ms. 'WaitForHead' supplies the captured target at execution time.
defaultHeadWaitOptions :: PositionWaitOptions
defaultHeadWaitOptions =
  PositionWaitOptions
    { target = Nothing,
      timeoutMicros = 5000000,
      pollMicros = 10000
    }

{-# DEPRECATED ConsistencyMode "Use QueryFreshness. ConsistencyMode remains through the 0.12 compatibility window and is removed in 0.13." #-}

{-# DEPRECATED Strong "Use WaitForHead. Strong is a bounded captured-head wait, not linearizability; it is removed in 0.13." #-}

{-# DEPRECATED Eventual "Use Immediate. Eventual means only that the query does not wait; it is removed in 0.13." #-}

{-# DEPRECATED PositionWait "Use WaitForPosition with a concrete target. Legacy PositionWait Nothing remains immediate through 0.12 and is removed in 0.13." #-}

{-# DEPRECATED StrongScope "Use HeadScope. StrongScope remains through the 0.12 compatibility window and is removed in 0.13." #-}

{-# DEPRECATED EntireLog "Use EntireVisibleLog. EntireLog remains through the 0.12 compatibility window and is removed in 0.13." #-}

{-# DEPRECATED CategoryHead "Use CategoryVisibleHead. CategoryHead remains through the 0.12 compatibility window and is removed in 0.13." #-}

{-# DEPRECATED defaultStrongWaitOptions "Use defaultHeadWaitOptions. The legacy name is removed in 0.13." #-}

{-# DEPRECATED subscriptionName "Use ReadModelBlueprint.cursorAuthority and readModelCursorAuthority. The legacy record field is removed in 0.13." #-}

{-# DEPRECATED defaultConsistency "Use ReadModelBlueprint builders and readModelDefaultFreshness. The legacy record field is removed in 0.13." #-}

{-# DEPRECATED strongScope "Use HeadScope through the ReadModelBlueprint builders. The legacy record field is removed in 0.13." #-}

-- | Why a read-model query could not run.
data ReadModelError
  = -- | No registry row exists for the model. Register it once at projection
    --       startup with 'registerReadModel' before serving queries.
    ReadModelUnregistered !Text
  | -- | The registered schema (version or shape hash) differs from the
    --       model's current definition: name, expected vs. found version, then
    --       expected vs. found shape hash. The model must be rebuilt.
    ReadModelStaleSchema !Text !Int !Int !Text !Text
  | -- | A 'PositionWait' query timed out: model name, target position, and
    --       the last observed subscription position.
    ReadModelWaitTimeout !Text !GlobalPosition !GlobalPosition
  | -- | The model is registered but not 'Live' (e.g. rebuilding or
    --       abandoned): name and current status.
    ReadModelNotLive !Text !ReadModelStatus
  deriving stock (Generic, Eq, Show)

-- | Query a read model using its 'defaultConsistency'. Validates schema and
-- liveness first, waits if the mode requires it, then runs the query.
runQuery ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  ReadModel q r ->
  q ->
  Eff es (Either ReadModelError r)
runQuery metrics readModel =
  runQueryWith metrics (readModel ^. #defaultConsistency) readModel

-- | Query a read model with an explicit 'ConsistencyMode', overriding its
-- default. Validates the model's schema and liveness, honours the wait mode,
-- then runs the query in a transaction.
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

-- | Block until the model's subscription has advanced to @targetPosition@,
-- polling at 'pollMicros' intervals. Returns @Right ()@ once caught up, or
-- 'ReadModelWaitTimeout' if 'timeoutMicros' elapses first.
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

-- Note: the read model's 'schema' field is deliberately NOT persisted here. The
-- registry keys on name/version/shapeHash/status (the model's schema identity);
-- where the application's data table physically lives is a deployment/wiring
-- concern, not part of that identity. See EP-4's Decision Log.
ensureReadModel ::
  (Store :> es) =>
  ReadModel q r ->
  Eff es (Either ReadModelError ())
ensureReadModel readModel = do
  found <- lookupReadModel (readModel ^. #name)
  pure $ case found of
    Just metadata -> validateMetadata readModel metadata
    Nothing -> Left (ReadModelUnregistered (readModel ^. #name))

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
waitIfNeeded metrics Strong readModel = do
  target <- case readModel ^. #strongScope of
    EntireLog -> storeHeadPosition
    CategoryHead category -> categoryHeadPosition category
  waitFor metrics (defaultStrongWaitOptions & #target ?~ target) readModel target
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
  subscriptionPositionFromInventory (SubscriptionName subscriptionName)
    <$> subscriptionCheckpointInventory

-- | Derive one subscription's durable position from a captured inventory.
-- Consumer-group members share the subscription name, so the subscription-wide
-- position is the slowest member's checkpoint. A missing durable row is
-- represented by 'Nothing', not a synthetic position zero.
subscriptionPositionFromInventory ::
  SubscriptionName ->
  SubscriptionCheckpointInventory ->
  Maybe GlobalPosition
subscriptionPositionFromInventory wanted inventory =
  minimumMay
    [ position
    | SubscriptionCheckpoint name _member position _updatedAt <-
        Vector.toList (checkpoints inventory),
      name == wanted
    ]
  where
    minimumMay [] = Nothing
    minimumMay positions = Just (Prelude.minimum positions)

-- | The global position captured by Kiroku's durable checkpoint inventory.
-- This reads the authoritative @$all@ stream position even when no decodable
-- event is visible (for example after hard deletion).
storeHeadPosition :: (Store :> es) => Eff es GlobalPosition
storeHeadPosition = storePosition <$> subscriptionCheckpointInventory

-- | The latest global position originating in a Kiroku category, or
-- @GlobalPosition 0@ when that category has no events. This deliberately reads
-- Kiroku's indexed @streams@ and @$all@ membership tables because Kiroku 0.3 does
-- not export a category-head query.
categoryHeadPosition :: (Store :> es) => Text -> Eff es GlobalPosition
categoryHeadPosition category =
  runTransaction
    $ Tx.statement category categoryHeadPositionStmt

categoryHeadPositionStmt :: Statement Text GlobalPosition
categoryHeadPositionStmt =
  preparable
    """
    SELECT COALESCE(max(se.stream_version), 0)
    FROM streams s
    JOIN stream_events se
      ON se.original_stream_id = s.stream_id
     AND se.stream_id = 0
    WHERE s.category = $1
    """
    (E.param (E.nonNullable E.text))
    (D.singleRow (GlobalPosition <$> D.column (D.nonNullable D.int8)))
