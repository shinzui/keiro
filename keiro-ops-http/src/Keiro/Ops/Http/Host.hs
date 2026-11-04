-- | Shared lifecycle and command-line options for standalone inspection hosts.
module Keiro.Ops.Http.Host
  ( HostOptions (..),
    hostOptionsParser,
    withHost,
    mainWithHooks,
  )
where

import Control.Concurrent.Async (wait)
import Data.Foldable (traverse_)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations.SchemaCheck
import Keiro.Ops (AppHooks)
import Keiro.Ops.Env (resolveConnectionString)
import Keiro.Ops.Http.Config
import Keiro.Ops.Http.Config qualified as Config
import Keiro.Ops.Http.Feed
import Keiro.Ops.Http.Pool
import Keiro.Ops.Http.Server
import Keiro.Ops.Http.WebSocket (opsApplicationWithFeeds)
import Kiroku.Store.Connection (ConnectionSettingsM (..), KirokuStore (..), defaultConnectionSettings, withStore)
import Options.Applicative
import System.Environment (getProgName)
import System.IO (stderr)

-- | Database selection, request policy, and listener settings for one host.
data HostOptions = HostOptions
  { databaseUrl :: !(Maybe Text),
    http :: !OpsHttpConfig,
    server :: !OpsHttpServerConfig
  }

-- | The common flag surface used by database-only and application hosts.
hostOptionsParser :: Parser HostOptions
hostOptionsParser =
  HostOptions
    <$> optional (textOption (long "database-url" <> metavar "URL"))
    <*> ( (\enabled drift origins -> defaultOpsHttpConfig {mutations = if enabled then MutationsEnabled else MutationsDisabled, schemaDrift = if drift then AllowDrift else RefuseOnDrift, Config.allowedOrigins = origins})
            <$> switch (long "enable-mutations")
            <*> switch (long "allow-schema-drift")
            <*> many (textOption (long "allow-origin" <> metavar "ORIGIN"))
        )
    <*> (OpsHttpServerConfig <$> textOption (long "bind" <> value "127.0.0.1") <*> option auto (long "port" <> value 9092) <*> option auto (long "request-timeout" <> value 300))
  where
    textOption modifiers = Text.pack <$> strOption modifiers

-- | Run the command-line host with the application's operational hooks.
mainWithHooks :: AppHooks -> IO ()
mainWithHooks hooks = do
  opts <- execParser (info (hostOptionsParser <**> helper) (fullDesc <> progDesc "Serve Keiro inspection on a trusted network or behind an authenticating proxy"))
  name <- Text.pack <$> getProgName
  withHost opts hooks $ \running -> do
    Text.hPutStrLn stderr (name <> ": listening on " <> opts.server.bindHost <> ":" <> Text.pack (show running.serverPort) <> " (mutations " <> (if opts.http.mutations == MutationsEnabled then "enabled" else "disabled") <> ")")
    wait running.serverThread

-- | Allocate the inspection store, feeds, and listener for the continuation.
-- All resources are released before returning, including on exceptions.
-- Port zero selects a free port reported by 'OpsHttpServer'.
withHost :: HostOptions -> AppHooks -> (OpsHttpServer -> IO a) -> IO a
withHost opts hooks action = do
  let config = opts.http
  connectionString <- resolveConnectionString opts.databaseUrl
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
      app <- opsApplicationWithFeeds config feeds hooks store
      withOpsHttpServer opts.server app action
