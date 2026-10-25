module Main (main) where

import Control.Concurrent.Async (wait)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Keiro.Ops (emptyAppHooks)
import Keiro.Ops.Env (resolveConnectionString)
import Keiro.Ops.Http
import Keiro.Ops.Http.Application (opsApplicationWithBudget)
import Keiro.Ops.Http.Config qualified as Config
import Keiro.Ops.Http.WebSocket (feedsMiddleware)
import Kiroku.Metrics qualified as Metrics
import Kiroku.Metrics.Config qualified as MetricsConfig
import Kiroku.Store.Connection (ConnectionSettingsM (..), KirokuStore (..), defaultConnectionSettings, withStore)
import Options.Applicative
import System.IO (stderr)

data Options = Options !(Maybe Text) !Text !Int ![Text]

options :: Parser Options
options =
  Options
    <$> optional (textOption (long "database-url" <> metavar "URL"))
    <*> textOption (long "bind" <> value "127.0.0.1")
    <*> option auto (long "port" <> value 9092)
    <*> many (textOption (long "allow-origin" <> metavar "ORIGIN"))
  where
    textOption modifiers = Text.pack <$> strOption modifiers

main :: IO ()
main = do
  Options database host port origins <- execParser (info (options <**> helper) (fullDesc <> progDesc "Compose inspection surfaces on a trusted network or behind an authenticating proxy"))
  connectionString <- resolveConnectionString database
  parsedOrigins <- either (fail . show) pure (traverse Metrics.allowedOrigin origins)
  let cors = Metrics.corsAllowOrigins parsedOrigins
  let config = defaultOpsHttpConfig {Config.allowedOrigins = origins}
      serverConfig = defaultOpsHttpServerConfig {bindHost = host, port}
      settings = (defaultConnectionSettings connectionString) {poolSize = config.inspectionLimits.maxConcurrentReads, statementTimeout = Just 2}
  -- An inspection-owned store and pool; the application never borrows the
  -- runtime writer's reserved connections. Each constructor runs once.
  withStore settings $ \baseStore -> withOpsInspectionPool config.inspectionLimits settings $ \pool -> do
    let store = baseStore {pool}
        metricsConfig = Metrics.defaultConfig {MetricsConfig.cors = cors}
    metrics <- Metrics.newKirokuMetrics store
    providers <- Metrics.storeServerProviders metricsConfig metrics store
    let kiroku = Metrics.combinedAppWithProviders metricsConfig metrics [] providers
    withFeedHandle config defaultFeedConfig store $ \feeds -> do
      http <- opsApplicationWithBudget config (handleBudget feeds) emptyAppHooks store
      let keiro = feedsMiddleware config feeds http
      app <-
        either (fail . Text.unpack . renderComposeError) pure $
          composeSurfaces (ComposeConfig origins) [MountedSurface keiroPrefix keiro, MountedSurface kirokuPrefix kiroku]
      withOpsHttpServer serverConfig app $ \server -> do
        Text.hPutStrLn stderr ("keiro-ops-http-compose-example: listening on " <> host <> ":" <> Text.pack (show server.serverPort) <> "; surfaces /keiro /kiroku")
        wait server.serverThread
