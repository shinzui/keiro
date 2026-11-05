-- | Operational adapters for projection dedup retention.
--
-- Commands call the public Keiro read-model and projection APIs in accordance
-- with ADR 28.
module Keiro.Ops.Projection
  ( Command (..),
    ProjectionStatusOptions (..),
    ConsumersOptions (..),
    prepareConsumers,
    commandParserWithConsumers,
    runCommandWithConsumers,
    projectionGroupStatusJson,
    projectionGroupStatusRowJson,
    validateCommand,
    commandParser,
    isMutation,
    runCommand,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encoding qualified as Encoding
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.Int (Int64)
import Data.List (groupBy)
import Data.Map.Lazy qualified as LazyMap
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Inspection.Consumers qualified as Consumers
import Keiro.Inspection.Cursor (InspectionCursor (..), decodeCursor, encodeCursorBounded)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (cursorReader, positiveIntReader)
import Keiro.Ops.Render
import Keiro.Projection (countAsyncProjectionDedupForBefore, pruneAsyncProjectionDedupForBefore)
import Keiro.Projection.Catalog (projectionIdText, projectionRevisionIdText, rebuildGroupIdText, subscriptionIdText)
import Keiro.Projection.Catalog.Operations qualified as Catalog
import Keiro.ReadModel (storeHeadPosition)
import Keiro.ReadModel.Rebuild
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Subscription
  ( SubscriptionCheckpoint (..),
    SubscriptionCheckpointInventory (..),
    SubscriptionName (..),
    subscriptionCheckpointInventory,
  )
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..))
import Options.Applicative hiding (action)
import Prelude

data ProjectionStatusOptions = ProjectionStatusOptions {limit :: !Int, after :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show)

data Command
  = Status !ProjectionStatusOptions
  | Consumers !ConsumersOptions
  | Position !Text
  | PruneDedup !Text !UTCTime
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser = commandParserWithConsumers False

commandParserWithConsumers :: Bool -> Parser Command
commandParserWithConsumers mounted =
  hsubparser
    ( command "status" (info (Status <$> (ProjectionStatusOptions <$> option positiveIntReader (long "limit" <> value 100 <> metavar "N") <*> optional (option cursorReader (long "after" <> metavar "CURSOR")))) (progDesc "Observe one bounded page of projection-group status"))
        <> (if mounted then command "consumers" (info consumersParser (progDesc "Find declared consumers of one category in mounted configuration")) else mempty)
        <> command "position" (info positionParser (progDesc "Show one subscription's durable member checkpoints and floor"))
        <> command "prune-dedup" (info pruneParser (progDesc "Preview or prune one projection's old dedup rows"))
    )
  where
    consumersParser =
      Consumers
        <$> ( ConsumersOptions
                <$> textOption "category" "CATEGORY" "Exact stream category (case sensitive)"
                <*> option positiveIntReader (long "limit" <> value 100 <> metavar "N" <> help "Page size, 1..500")
                <*> optional (option cursorReader (long "after" <> metavar "CURSOR"))
            )
    positionParser = Position <$> textOption "subscription" "NAME" "Durable Kiroku subscription name"
    pruneParser =
      PruneDedup
        <$> textOption "projection" "NAME" "Async projection name"
        <*> option utcReader (long "before" <> metavar "UTC" <> help "Prune rows older than ISO-8601 UTC, for example 2026-08-01T00:00:00Z")

textOption :: String -> String -> String -> Parser Text
textOption name metavarText helpText = Text.pack <$> strOption (long name <> metavar metavarText <> help helpText)

utcReader :: ReadM UTCTime
utcReader = eitherReader $ \raw ->
  maybe
    (Left "expected ISO-8601 UTC such as 2026-08-01T00:00:00Z")
    Right
    (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" raw)

statusInput :: ProjectionStatusOptions -> ProjectionStatusPageRequest
statusInput options = ProjectionStatusPageRequest options.limit options.after

validateCommand :: Command -> Either (Text, Text) ()
validateCommand (Status options) = either (Left . statusError) (const (Right ())) (validateProjectionStatusRequest (statusInput options))
validateCommand (Consumers options) = validateConsumers options
validateCommand _ = Right ()

statusError :: ProjectionStatusReadError -> (Text, Text)
statusError err =
  ( case err of
      InvalidProjectionStatusPageSize _ -> "invalid_page_size"
      InvalidProjectionStatusCursor _ -> "invalid_cursor"
      ProjectionStatusResultTooLarge -> "inspection_result_too_large",
    Text.pack (show err)
  )

isMutation :: Command -> Bool
isMutation = \case
  Consumers {} -> False
  Status {} -> False
  Position {} -> False
  PruneDedup {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand = runCommandWithConsumers Nothing Nothing

runCommandWithConsumers :: Maybe Catalog.ProjectionCatalogOperations -> Maybe Consumers.DurableConsumerRegistry -> OpsEnv -> Command -> IO OpsOutcome
runCommandWithConsumers catalog durable env = \case
  Consumers options -> pure $ case prepareConsumers catalog durable options of
    Left (code, detail) -> InspectionFailed code detail
    Right (result, _) -> Succeeded result
  Status options -> runAction env action $ \case
    Left err -> uncurry InspectionFailed (statusError err)
    Right (page, head) ->
      Succeeded
        ( OpsResult
            ["group_id", "lifecycle_phase", "reads_allowed", "serving_position_basis"]
            [[rebuildGroupIdText row.status.groupId, row.status.lifecyclePhase, Text.pack (show row.status.readsAllowed), basisText row.status.servingPositionBasis] | row <- page.items]
            ( object
                ( ["observed_at" .= page.observedAt, "visible_store_head" .= positionInt head, "items" .= map projectionGroupStatusRowJson page.items]
                    <> maybe [] (\cursor -> ["next_cursor" .= cursor.cursorText]) page.next
                )
            )
        )
    where
      action = do
        page <- listProjectionGroupStatusesPage (statusInput options)
        case page of
          Left err -> pure (Left err)
          Right value -> Right . (value,) <$> storeHeadPosition
  Position subscription -> runPosition env subscription
  PruneDedup projection before
    | env.force ->
        runAction env (pruneAsyncProjectionDedupForBefore projection before) $ \affected ->
          Succeeded (pruneResult False projection before affected)
    | otherwise ->
        runAction env (countAsyncProjectionDedupForBefore projection before) $ \affected ->
          PreviewRequired
            (pruneResult True projection before affected)
            (forceInvocation env ["projection", "prune-dedup", "--projection", projection, "--before", utcText before])

-- | The frozen v1 owner relation, using ADR-28 position vocabulary.
projectionGroupStatusJson :: ProjectionGroupStatusV1 -> Value
projectionGroupStatusJson = object . projectionGroupStatusPairs

-- | The bounded page item, including registered feeding subscriptions.
projectionGroupStatusRowJson :: ProjectionGroupStatusRow -> Value
projectionGroupStatusRowJson row =
  -- Prepending avoids traversing the frozen row's pair list.
  object (("feeding_subscriptions" .= row.feedingSubscriptions) : projectionGroupStatusPairs row.status)

projectionGroupStatusPairs :: ProjectionGroupStatusV1 -> [Pair]
projectionGroupStatusPairs row =
  [ "group_id" .= rebuildGroupIdText row.groupId,
    "lifecycle_phase" .= row.lifecyclePhase,
    "reads_allowed" .= row.readsAllowed,
    "writes_allowed" .= row.writesAllowed,
    "serving_revision_id" .= fmap projectionRevisionIdText row.servingRevisionId,
    "serving_epoch" .= row.servingEpoch,
    "serving_position_basis" .= basisText row.servingPositionBasis,
    "serving_applied_position" .= fmap positionInt row.servingAppliedPosition,
    "active_run_id" .= fmap rebuildRunIdText row.activeRunId,
    "candidate_revision_id" .= fmap projectionRevisionIdText row.candidateRevisionId,
    "candidate_rebuild_position" .= fmap positionInt row.candidateRebuildPosition,
    "candidate_rebuild_head" .= fmap positionInt row.candidateRebuildHead,
    "query_models" .= row.queryModels,
    "rebuild_started_at" .= row.rebuildStartedAt,
    "last_promoted_at" .= row.lastPromotedAt,
    "failed_at" .= row.failedAt,
    "failure_code" .= row.failureCode,
    "failure_detail" .= row.failureDetail
  ]

basisText :: ServingPositionBasis -> Text
basisText = \case ServingPositionAppend -> "append"; ServingPositionCheckpoint -> "checkpoint"; ServingPositionUnmanaged -> "unmanaged"

runPosition :: OpsEnv -> Text -> IO OpsOutcome
runPosition env subscription =
  runAction env action $ \(visibleHead, inventory) ->
    Succeeded (positionResult subscription visibleHead inventory)
  where
    action = (,) <$> storeHeadPosition <*> subscriptionCheckpointInventory

positionResult :: Text -> GlobalPosition -> SubscriptionCheckpointInventory -> OpsResult
positionResult requested visibleHead inventory =
  OpsResult
    { headers = ["subscription", "member", "checkpoint_position", "checkpoint_updated_at", "store_position", "visible_store_head", "global_position_distance", "minimum_checkpoint_position", "maximum_global_position_distance"],
      rows = humanRows,
      jsonValue =
        object
          [ "subscription" .= requested,
            "store_position" .= positionInt captured,
            "visible_store_head" .= positionInt visibleHead,
            "members" .= map (memberJson visibleHead) members,
            "minimum_checkpoint_position" .= fmap positionInt minimumCheckpoint,
            "maximum_global_position_distance" .= maximumDistance
          ]
    }
  where
    captured = storePosition inventory
    members =
      [ checkpoint
      | checkpoint@(SubscriptionCheckpoint (SubscriptionName name) _member _position _updatedAt) <-
          Vector.toList (checkpoints inventory),
        name == requested
      ]
    minimumCheckpoint = minimumMay [position | SubscriptionCheckpoint _ _ position _ <- members]
    maximumDistance = globalPositionDistance visibleHead <$> minimumCheckpoint
    summaryCells =
      [ maybe "" positionText minimumCheckpoint,
        maybe "" showText maximumDistance
      ]
    humanRows = case members of
      [] -> [[requested, "", "", "", positionText captured, positionText visibleHead, ""] <> summaryCells]
      _ -> map (memberRow captured visibleHead summaryCells) members

memberRow :: GlobalPosition -> GlobalPosition -> [Text] -> SubscriptionCheckpoint -> [Text]
memberRow captured visibleHead summaryCells (SubscriptionCheckpoint (SubscriptionName name) member position updatedAt) =
  [ name,
    showText member,
    positionText position,
    utcText updatedAt,
    positionText captured,
    positionText visibleHead,
    showText (globalPositionDistance visibleHead position)
  ]
    <> summaryCells

memberJson :: GlobalPosition -> SubscriptionCheckpoint -> Value
memberJson visibleHead (SubscriptionCheckpoint (SubscriptionName name) member position updatedAt) =
  object
    [ "subscription" .= name,
      "member" .= member,
      "checkpoint_position" .= positionInt position,
      "checkpoint_updated_at" .= updatedAt,
      "global_position_distance" .= globalPositionDistance visibleHead position
    ]

minimumMay :: (Ord a) => [a] -> Maybe a
minimumMay [] = Nothing
minimumMay values = Just (Prelude.minimum values)

globalPositionDistance :: GlobalPosition -> GlobalPosition -> Int64
globalPositionDistance (GlobalPosition captured) (GlobalPosition checkpoint) = max 0 (captured - checkpoint)

positionInt :: GlobalPosition -> Int64
positionInt (GlobalPosition value) = value

positionText :: GlobalPosition -> Text
positionText = showText . positionInt

runAction :: OpsEnv -> Eff '[Store, Error StoreError, IOE] a -> (a -> OpsOutcome) -> IO OpsOutcome
runAction env action onSuccess = do
  result <- runStoreIO env.store action
  pure $ either (Failed . Text.pack . show) onSuccess result

pruneResult :: Bool -> Text -> UTCTime -> Int64 -> OpsResult
pruneResult preview projection before affected =
  OpsResult
    { headers = ["projection", "before", if preview then "would_prune" else "pruned"],
      rows = [[projection, utcText before, showText affected]],
      jsonValue = object ["preview" .= preview, "projection" .= projection, "before" .= before, "affected" .= affected]
    }

utcText :: UTCTime -> Text
utcText = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"

showText :: (Show a) => a -> Text
showText = Text.pack . show

forceInvocation :: OpsEnv -> [Text] -> Text
forceInvocation env arguments = Text.unwords (map shellQuote ("keiro-ops" : arguments <> globalFlags <> ["--force"]))
  where
    globalFlags = ["--json" | env.outputMode == Json] <> ["--allow-schema-drift" | env.allowSchemaDrift]

shellQuote :: Text -> Text
shellQuote value = "'" <> Text.replace "'" "'\"'\"'" value <> "'"

-- | One category per request; the host byte cap also bounds nested bindings.
data ConsumersOptions = ConsumersOptions
  { category :: !Text,
    limit :: !Int,
    after :: !(Maybe InspectionCursor)
  }
  deriving stock (Eq, Show)

consumersSchema :: Text
consumersSchema = "keiro/category-consumers/v1"

type ConsumerKey = (Text, Text)

type ConsumerInventory = (Maybe Text, Maybe Text)

type ConsumerCursor = (Text, ConsumerInventory, ConsumerKey)

validateConsumers :: ConsumersOptions -> Either (Text, Text) ()
validateConsumers options
  | Text.null options.category || Text.strip options.category /= options.category = Left ("invalid_category", "category must be nonempty and have no surrounding whitespace")
  | options.limit < 1 || options.limit > 500 = Left ("invalid_page_size", "page size must be 1..500")
  | otherwise = () <$ consumerCursor options

consumerCursor :: ConsumersOptions -> Either (Text, Text) (Maybe ConsumerCursor)
consumerCursor options = traverse decode options.after
  where
    decode cursor = case decodeCursor consumersSchema cursor of
      Right payload@(category, _, (kind, name))
        | category == options.category,
          kind `elem` ["durable_subscriber", "process_manager", "projection_group"],
          not (Text.null name) ->
            Right payload
      _ -> Left ("invalid_cursor", "cursor is malformed or belongs to another category/read")

data ConsumerItem = ConsumerItem !Text !Text !(Maybe Text) ![ConsumerBinding]

data ConsumerBinding = ConsumerBinding !(Maybe Text) !(Maybe Text) !(Maybe Text) !(Maybe Text) !Consumers.ConsumerSource

consumerKey :: ConsumerItem -> ConsumerKey
consumerKey (ConsumerItem kind name _ _) = (kind, name)

-- | One filtered page supplies both presentations. On HTTP the canonical items
-- array stays lazy, and every request encodes afresh inside the host's budget.
prepareConsumers :: Maybe Catalog.ProjectionCatalogOperations -> Maybe Consumers.DurableConsumerRegistry -> ConsumersOptions -> Either (Text, Text) (OpsResult, Encoding.Encoding)
prepareConsumers catalog durable options = do
  validateConsumers options
  if not (isJust catalog || isJust durable)
    then Left ("unsupported_command", "consumer metadata hooks are not mounted")
    else Right ()
  cursor <- consumerCursor options
  let inventory = (Catalog.projectionConsumerInventoryIdentity <$> catalog, Consumers.durableConsumerInventoryIdentity <$> durable)
  case cursor of
    Just (_, previous, _) | previous /= inventory -> Left ("invalid_cursor", "mounted consumer inventory changed; restart from the first page")
    _ -> Right ()
  let matching = maybe [] (durableItems options.category) durable <> maybe [] (projectionItems options.category) catalog
      remaining = case cursor of
        Nothing -> matching
        Just (_, _, lastKey) -> dropWhile ((<= lastKey) . consumerKey) matching
      window = take (options.limit + 1) remaining
      page = take options.limit window
  next <-
    if length window <= options.limit
      then Right Nothing
      else case encodeCursorBounded consumersSchema (options.category, inventory, consumerKey (last page)) of
        Nothing -> Left ("inspection_result_too_large", "consumer continuation exceeds cursor byte limit")
        Just token -> Right (Just token)
  let coverage = object ["projection_catalog" .= isJust catalog, "durable_subscribers" .= isJust durable]
      fields =
        [("schema", Aeson.String consumersSchema), ("category", Aeson.String options.category), ("scope", Aeson.String "mounted_configuration"), ("coverage", coverage), ("items", Aeson.toJSON page)]
          <> maybe [] (\token -> [("next_cursor", Aeson.String token.cursorText)]) next
      canonical = Aeson.Object (KeyMap.fromMap (LazyMap.fromList fields))
      encoding =
        Encoding.pairs
          ( Encoding.pair "schema" (Encoding.text consumersSchema)
              <> Encoding.pair "category" (Encoding.text options.category)
              <> Encoding.pair "scope" (Encoding.text "mounted_configuration")
              <> Encoding.pair "coverage" (Aeson.toEncoding coverage)
              <> Encoding.pair "items" (Aeson.toEncoding page)
              <> foldMap (Encoding.pair "next_cursor" . Encoding.text . (.cursorText)) next
          )
  pure (OpsResult ["kind", "name", "group_id", "subscription", "source"] (concatMap consumerRows page) canonical, encoding)

projectionItems :: Text -> Catalog.ProjectionCatalogOperations -> [ConsumerItem]
projectionItems category catalog =
  [ ConsumerItem
      "projection_group"
      (rebuildGroupIdText group.groupId)
      (Just (rebuildGroupIdText group.groupId))
      [ ConsumerBinding
          (Just (projectionIdText binding.projectionId))
          (Just binding.handlerName)
          (subscriptionIdText <$> binding.subscriptionId)
          binding.subscriptionName
          binding.source
      | binding <- group.bindings
      ]
  | group <- Catalog.projectionConsumers catalog (CategoryName category)
  ]

durableItems :: Text -> Consumers.DurableConsumerRegistry -> [ConsumerItem]
durableItems category registry =
  [ ConsumerItem
      (kindText first.kind)
      first.name
      Nothing
      [ConsumerBinding Nothing Nothing Nothing (Just description.subscriptionName) description.source | description <- descriptions]
  | descriptions@(first : _) <- groupBy sameConsumer (Consumers.durableConsumersForCategory registry (CategoryName category))
  ]
  where
    sameConsumer left right = (left.kind, left.name) == (right.kind, right.name)
    kindText Consumers.DurableSubscriber = "durable_subscriber"
    kindText Consumers.ProcessManagerConsumer = "process_manager"

instance Aeson.ToJSON ConsumerItem where
  toJSON (ConsumerItem kind name group bindings) = object ["kind" .= kind, "name" .= name, "group_id" .= group, "bindings" .= bindings]
  toEncoding (ConsumerItem kind name group bindings) =
    Encoding.pairs
      ( Encoding.pair "kind" (Encoding.text kind)
          <> Encoding.pair "name" (Encoding.text name)
          <> Encoding.pair "group_id" (Aeson.toEncoding group)
          <> Encoding.pair "bindings" (Aeson.toEncoding bindings)
      )

instance Aeson.ToJSON ConsumerBinding where
  toJSON (ConsumerBinding projection handler subscriptionId subscription source) =
    object
      [ "projection_id" .= projection,
        "handler_name" .= handler,
        "delivery" .= delivery subscription,
        "subscription_id" .= subscriptionId,
        "subscription_name" .= subscription,
        "source" .= sourceJson source
      ]
  toEncoding (ConsumerBinding projection handler subscriptionId subscription source) =
    Encoding.pairs
      ( Encoding.pair "projection_id" (Aeson.toEncoding projection)
          <> Encoding.pair "handler_name" (Aeson.toEncoding handler)
          <> Encoding.pair "delivery" (Encoding.text (delivery subscription))
          <> Encoding.pair "subscription_id" (Aeson.toEncoding subscriptionId)
          <> Encoding.pair "subscription_name" (Aeson.toEncoding subscription)
          <> Encoding.pair "source" (sourceEncoding source)
      )

delivery :: Maybe Text -> Text
delivery Nothing = "inline"
delivery (Just _) = "subscription"

sourceJson :: Consumers.ConsumerSource -> Value
sourceJson = \case
  Consumers.AllCategories -> object ["kind" .= ("all" :: Text)]
  Consumers.ExactCategory category -> object ["kind" .= ("category" :: Text), "category" .= category]
  Consumers.CategoryNamespace namespace -> object ["kind" .= ("namespace" :: Text), "namespace" .= namespace]

sourceEncoding :: Consumers.ConsumerSource -> Encoding.Encoding
sourceEncoding source = Encoding.pairs $ case source of
  Consumers.AllCategories -> Encoding.pair "kind" (Encoding.text "all")
  Consumers.ExactCategory category -> Encoding.pair "kind" (Encoding.text "category") <> Encoding.pair "category" (Encoding.text category)
  Consumers.CategoryNamespace namespace -> Encoding.pair "kind" (Encoding.text "namespace") <> Encoding.pair "namespace" (Encoding.text namespace)

consumerRows :: ConsumerItem -> [[Text]]
consumerRows (ConsumerItem kind name group bindings) =
  [[kind, name, maybe "" id group, maybe "" id subscription, sourceText source] | ConsumerBinding _ _ _ subscription source <- bindings]
  where
    sourceText Consumers.AllCategories = "all categories"
    sourceText (Consumers.ExactCategory category) = "category: " <> category
    sourceText (Consumers.CategoryNamespace namespace) = "namespace: " <> namespace
