module Main (main) where

import Control.Concurrent.Async (wait)
import Data.Foldable (traverse_)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations.SchemaCheck
import Keiro.Ops (emptyAppHooks)
import Keiro.Ops.Env (resolveConnectionString)
import Keiro.Ops.Http
import Kiroku.Store.Connection (ConnectionSettingsM (..), KirokuStore (..), defaultConnectionSettings, withStore)
import Options.Applicative
import System.IO (stderr)

data Options = Options !(Maybe Text) !OpsHttpConfig !OpsHttpServerConfig

options :: Parser Options
options =
  Options
    <$> optional (textOption (long "database-url" <> metavar "URL"))
    <*> ( (\enabled drift origins -> defaultOpsHttpConfig {mutations = if enabled then MutationsEnabled else MutationsDisabled, schemaDrift = if drift then AllowDrift else RefuseOnDrift, allowedOrigins = origins})
            <$> switch (long "enable-mutations")
            <*> switch (long "allow-schema-drift")
            <*> many (textOption (long "allow-origin" <> metavar "ORIGIN"))
        )
    <*> (OpsHttpServerConfig <$> textOption (long "bind" <> value "127.0.0.1") <*> option auto (long "port" <> value 9092) <*> option auto (long "request-timeout" <> value 300))
  where
    textOption modifiers = Text.pack <$> strOption modifiers

main :: IO ()
main = do
  Options database config serverConfig <- execParser (info (options <**> helper) (fullDesc <> progDesc "Serve Keiro inspection on a trusted network or behind an authenticating proxy"))
  connectionString <- resolveConnectionString database
  verified <- verifyExpectedSchema (Settings.connectionString connectionString)
  case verified of
    Left err -> ioError (userError (show err))
    Right drift -> traverse_ (Text.hPutStrLn stderr . ("warning: " <>) . renderSchemaDrift) drift
  -- This store belongs only to inspection. All its pooled connections inherit
  -- the SQL deadline; command execution never borrows the runtime's pool.
  let settings = (defaultConnectionSettings connectionString) {poolSize = config.inspectionLimits.maxConcurrentReads, statementTimeout = Just 2}
  withStore settings $ \baseStore -> withOpsInspectionPool config.inspectionLimits settings $ \pool -> do
    let store = baseStore {pool}
    withFeedHandle config defaultFeedConfig store $ \feeds -> do
      app <- opsApplicationWithFeeds config feeds emptyAppHooks store
      withOpsHttpServer serverConfig app $ \server -> do
        Text.hPutStrLn stderr ("keiro-ops-http: listening on " <> serverConfig.bindHost <> ":" <> Text.pack (show server.serverPort) <> " (mutations " <> (if config.mutations == MutationsEnabled then "enabled" else "disabled") <> ")")
        wait server.serverThread
