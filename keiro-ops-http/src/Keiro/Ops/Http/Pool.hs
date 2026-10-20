module Keiro.Ops.Http.Pool (withOpsInspectionPool) where

import Control.Exception (bracket)
import Data.Text qualified as Text
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Keiro.Ops.Http.Budget (newInspectionBudget)
import Keiro.Ops.Http.Config
import Kiroku.Store.Connection (ConnectionSettings)
import Kiroku.Store.Connection qualified as Store

-- | Create an inspection-owned pool, preserving the host's connection string
-- and search path. Substitute this pool on the store passed to the HTTP/feed
-- surface. Every connection gets the same statement timeout, including after
-- cancellation/reconnection. No writer connection is modified.
withOpsInspectionPool :: InspectionLimits -> ConnectionSettings -> (Pool -> IO a) -> IO a
withOpsInspectionPool limits settings action = do
  _ <- newInspectionBudget limits
  bracket (Pool.acquire config) Pool.release action
  where
    quote name = "\"" <> Text.replace "\"" "\"\"" name <> "\""
    initScript =
      "SET search_path TO "
        <> Text.intercalate ", " (map quote (settings.schema : settings.extraSearchPath))
        <> ", pg_catalog; SET statement_timeout = '"
        <> Text.pack (show limits.statementTimeoutMillis)
        <> "ms'; SET idle_in_transaction_session_timeout = '"
        <> Text.pack (show settings.idleInTransactionTimeout)
        <> "s'"
    config =
      PoolConfig.settings
        ( [ PoolConfig.staticConnectionSettings (Settings.connectionString settings.connString),
            PoolConfig.size limits.maxConcurrentReads,
            PoolConfig.initSession (Session.script initScript)
          ]
            <> maybe [] (\observe -> [PoolConfig.observationHandler observe]) settings.observationHandler
        )
