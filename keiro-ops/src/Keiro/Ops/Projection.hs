-- | Operational adapters for projection dedup retention.
--
-- Commands call the public Keiro read-model and projection APIs in accordance
-- with ADR 28.
module Keiro.Ops.Projection
  ( Command (..),
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
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Render
import Keiro.Projection (countAsyncProjectionDedupForBefore, pruneAsyncProjectionDedupForBefore)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Subscription
  ( SubscriptionCheckpoint (..),
    SubscriptionCheckpointInventory (..),
    SubscriptionName (..),
    subscriptionCheckpointInventory,
  )
import Kiroku.Store.Types (GlobalPosition (..))
import Options.Applicative hiding (action, value)
import Prelude

data Command
  = Position !Text
  | PruneDedup !Text !UTCTime
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "position" (info positionParser (progDesc "Show one subscription's durable member checkpoints and floor"))
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

isMutation :: Command -> Bool
isMutation = \case
  Position {} -> False
  PruneDedup {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
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

runPosition :: OpsEnv -> Text -> IO OpsOutcome
runPosition env subscription =
  runAction env subscriptionCheckpointInventory $ \inventory ->
    Succeeded (positionResult subscription inventory)

positionResult :: Text -> SubscriptionCheckpointInventory -> OpsResult
positionResult requested inventory =
  OpsResult
    { headers = ["subscription", "member", "checkpoint_position", "checkpoint_updated_at", "store_position", "global_position_distance", "minimum_checkpoint_position", "maximum_global_position_distance"],
      rows = humanRows,
      jsonValue =
        object
          [ "subscription" .= requested,
            "store_position" .= positionInt captured,
            "members" .= map (memberJson captured) members,
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
    maximumDistance = globalPositionDistance captured <$> minimumCheckpoint
    summaryCells =
      [ maybe "" positionText minimumCheckpoint,
        maybe "" showText maximumDistance
      ]
    humanRows = case members of
      [] -> [[requested, "", "", "", positionText captured, ""] <> summaryCells]
      _ -> map (memberRow captured summaryCells) members

memberRow :: GlobalPosition -> [Text] -> SubscriptionCheckpoint -> [Text]
memberRow captured summaryCells (SubscriptionCheckpoint (SubscriptionName name) member position updatedAt) =
  [ name,
    showText member,
    positionText position,
    utcText updatedAt,
    positionText captured,
    showText (globalPositionDistance captured position)
  ]
    <> summaryCells

memberJson :: GlobalPosition -> SubscriptionCheckpoint -> Value
memberJson captured (SubscriptionCheckpoint (SubscriptionName name) member position updatedAt) =
  object
    [ "subscription" .= name,
      "member" .= member,
      "checkpoint_position" .= positionInt position,
      "checkpoint_updated_at" .= updatedAt,
      "global_position_distance" .= globalPositionDistance captured position
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
