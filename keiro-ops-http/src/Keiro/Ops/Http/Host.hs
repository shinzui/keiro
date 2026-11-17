-- | Shared lifecycle and command-line options for standalone inspection hosts.
module Keiro.Ops.Http.Host
  ( HostOptions (..),
    HostStartupError (..),
    hostOptionsParser,
    loadHostTopology,
    withHost,
    mainWithHooks,
  )
where

import Control.Concurrent.Async (wait)
import Control.Exception (Exception (..), IOException, throwIO, try)
import Data.ByteString qualified as ByteString
import Data.Foldable (traverse_)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations.SchemaCheck
import Keiro.Ops (AppHooks (..), ServiceTopologyDocument, decodeServiceTopology)
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
import System.Exit (ExitCode (..), exitWith)
import System.IO (IOMode (..), hFileSize, stderr, withBinaryFile)

-- | Database selection, request policy, and listener settings for one host.
data HostOptions = HostOptions
  { databaseUrl :: !(Maybe Text),
    http :: !OpsHttpConfig,
    server :: !OpsHttpServerConfig,
    -- | A committed keiro-dsl service-topology file to mount at startup.
    -- It replaces any 'serviceTopology' hook supplied in code.
    topology :: !(Maybe FilePath)
  }

-- | A host refused to start. Raised by 'withHost' before its continuation runs.
newtype HostStartupError = HostStartupError Text
  deriving stock (Show)

instance Exception HostStartupError where
  displayException (HostStartupError message) = Text.unpack message

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
    <*> optional (strOption (long "topology" <> metavar "FILE" <> help "Mount a committed keiro-dsl service-topology document at /topology/show and /topology/summary"))
  where
    textOption modifiers = Text.pack <$> strOption modifiers

-- | Run the command-line host with the application's operational hooks.
mainWithHooks :: AppHooks -> IO ()
mainWithHooks hooks = do
  opts <- execParser (info (hostOptionsParser <**> helper) (fullDesc <> progDesc "Serve Keiro inspection on a trusted network or behind an authenticating proxy"))
  name <- Text.pack <$> getProgName
  started <- try $ withHost opts hooks $ \running -> do
    Text.hPutStrLn stderr (name <> ": listening on " <> opts.server.bindHost <> ":" <> Text.pack (show running.serverPort) <> " (mutations " <> (if opts.http.mutations == MutationsEnabled then "enabled" else "disabled") <> ")")
    wait running.serverThread
  case started of
    Right () -> pure ()
    Left (HostStartupError message) -> do
      Text.hPutStrLn stderr (name <> ": " <> message)
      exitWith (ExitFailure 1)

-- | Allocate the inspection store, feeds, and listener for the continuation.
-- All resources are released before returning, including on exceptions.
-- Port zero selects a free port reported by 'OpsHttpServer'.
withHost :: HostOptions -> AppHooks -> (OpsHttpServer -> IO a) -> IO a
withHost opts suppliedHooks action = do
  let config = opts.http
  -- Resolve file-backed mounts before any database or listener work.
  hooks <- case opts.topology of
    Nothing -> pure suppliedHooks
    Just path -> do
      loaded <- loadHostTopology config.inspectionLimits.maxResponseBytes path
      document <- either (throwIO . HostStartupError) pure loaded
      case suppliedHooks.serviceTopology of
        Just _ -> Text.hPutStrLn stderr ("warning: --topology " <> Text.pack path <> " replaces the service topology mounted in code")
        Nothing -> pure ()
      pure suppliedHooks {serviceTopology = Just document}
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

-- | Read and decode a topology file that must fit the response limit.
-- The size is checked before decoding, and the read is bounded even if the
-- file grows after the check. Diagnostics name the path.
loadHostTopology :: Int -> FilePath -> IO (Either Text ServiceTopologyDocument)
loadHostTopology limit path = do
  result <- try $ withBinaryFile path ReadMode $ \handle -> do
    size <- hFileSize handle
    if size > fromIntegral limit
      then pure (Left (oversized (Text.pack (show size))))
      else do
        bytes <- ByteString.hGet handle (limit + 1)
        pure $
          if ByteString.length bytes > limit
            then Left (oversized ("more than " <> Text.pack (show limit)))
            else Right bytes
  pure $ case result of
    Left (err :: IOException) -> Left (prefix ("cannot read service topology: " <> Text.pack (displayException err)))
    Right (Left message) -> Left (prefix message)
    Right (Right bytes) -> either (Left . prefix) Right (decodeServiceTopology bytes)
  where
    prefix message = "--topology " <> Text.pack path <> ": " <> message
    oversized size =
      "service topology is "
        <> size
        <> " bytes, larger than the response limit of "
        <> Text.pack (show limit)
        <> " bytes (inspectionLimits.maxResponseBytes); /topology/show could never be served"
