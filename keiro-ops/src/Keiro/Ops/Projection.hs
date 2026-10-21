-- | Operational adapters for projection dedup retention.
--
-- Commands call the public Keiro read-model and projection APIs in accordance
-- with ADR 28.
module Keiro.Ops.Projection
  ( Command (..),
    ProjectionStatusOptions (..),
    projectionGroupStatusJson,
    validateCommand,
    commandParser,
    isMutation,
    runCommand,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Inspection.Cursor (InspectionCursor (..))
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (cursorReader, positiveIntReader)
import Keiro.Ops.Render
import Keiro.Projection (countAsyncProjectionDedupForBefore, pruneAsyncProjectionDedupForBefore)
import Keiro.Projection.Catalog (projectionRevisionIdText, rebuildGroupIdText)
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
import Kiroku.Store.Types (GlobalPosition (..))
import Options.Applicative hiding (action)
import Prelude

data ProjectionStatusOptions = ProjectionStatusOptions {limit :: !Int, after :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show)

data Command
  = Status !ProjectionStatusOptions
  | Position !Text
  | PruneDedup !Text !UTCTime
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "status" (info (Status <$> (ProjectionStatusOptions <$> option positiveIntReader (long "limit" <> value 100 <> metavar "N") <*> optional (option cursorReader (long "after" <> metavar "CURSOR")))) (progDesc "Observe one bounded page of projection-group status"))
        <> command "position" (info positionParser (progDesc "Show one subscription's durable member checkpoints and floor"))
        <> command "prune-dedup" (info pruneParser (progDesc "Preview or prune one projection's old dedup rows"))
    )
  where
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
  Status {} -> False
  Position {} -> False
  PruneDedup {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  Status options -> runAction env action $ \case
    Left err -> uncurry InspectionFailed (statusError err)
    Right (page, head) ->
      Succeeded
        ( OpsResult
            ["group_id", "lifecycle_phase", "reads_allowed", "serving_position_basis"]
            [[rebuildGroupIdText row.groupId, row.lifecyclePhase, Text.pack (show row.readsAllowed), basisText row.servingPositionBasis] | row <- page.items]
            ( object
                ( ["observed_at" .= page.observedAt, "visible_store_head" .= positionInt head, "items" .= map projectionGroupStatusJson page.items]
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
projectionGroupStatusJson row =
  object
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
