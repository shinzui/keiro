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

import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Render
import Keiro.Projection (countAsyncProjectionDedupForBefore, pruneAsyncProjectionDedupForBefore)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Options.Applicative hiding (action, value)

data Command
  = PruneDedup !Text !UTCTime
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    (command "prune-dedup" (info pruneParser (progDesc "Preview or prune one projection's old dedup rows")))
  where
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
  PruneDedup {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  PruneDedup projection before
    | env.force ->
        runAction env (pruneAsyncProjectionDedupForBefore projection before) $ \affected ->
          Succeeded (pruneResult False projection before affected)
    | otherwise ->
        runAction env (countAsyncProjectionDedupForBefore projection before) $ \affected ->
          PreviewRequired
            (pruneResult True projection before affected)
            (forceInvocation env ["projection", "prune-dedup", "--projection", projection, "--before", utcText before])

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
