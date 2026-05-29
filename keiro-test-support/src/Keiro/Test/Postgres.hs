{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Suite-level PostgreSQL test fixture for Keiro test suites.

This follows the @ephemeral-pg@ "suite-level template databases" best practice:
start one cached PostgreSQL server for the whole suite, migrate a template
database once, and clone a fresh, isolated database per example with
PostgreSQL's @CREATE DATABASE ... TEMPLATE ...@. Each example still receives an
empty, isolated database, but the expensive work — server startup and running
the Kiroku and Keiro migrations — happens once per suite rather than once per
example.

Usage from @hspec@:

@
main :: IO ()
main =
  'withMigratedSuite' \\fixture ->
    hspec $
      describe "..." $ around ('withFreshStore' fixture) $ do
        it "..." $ \\store -> ...
@
-}
module Keiro.Test.Postgres
  ( Fixture
  , withMigratedSuite
  , withFreshStore
  , withFreshStores2
  )
where

import Codd (CoddSettings (..), VerifySchemas (LaxCheck))
import Codd.Parsing (connStringParser)
import Codd.Representations.Types (DbRep (..))
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, stateTVar)
import Control.Exception (bracket, onException)
import Data.Aeson (Value (Null))
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session qualified as Session
import Keiro.Migrations (runAllKeiroMigrations)
import Kiroku.Store qualified as Store

-- | A running, migrated suite fixture: one cached PostgreSQL server owning a
-- single migrated template database, plus a counter for unique clone names.
data Fixture = Fixture
  { server :: Pg.Database
  , templateName :: Text
  , nextId :: TVar Int
  }

templateDbName :: Text
templateDbName = "keiro_template"

-- | Start one cached PostgreSQL server, create a template database, apply the
-- Kiroku event-store schema and Keiro framework schema to it once, then run
-- @action@ with the resulting 'Fixture'. The server is stopped on exit.
--
-- 'EphemeralPg.startCached' restores a clean @initdb@ cluster (no schema), and
-- 'Kiroku.Store.withStore' deliberately creates no tables, so the migrations
-- are applied here against the template before any example clones it.
withMigratedSuite :: (Fixture -> IO a) -> IO a
withMigratedSuite action = do
  started <- Pg.startCached Pg.defaultConfig Pg.defaultCacheConfig
  case started of
    Left err -> fail (Text.unpack (Pg.renderStartError err))
    Right server ->
      bracket
        (setup server `onException` Pg.stop server)
        (\fixture -> Pg.stop fixture.server)
        action
 where
  setup server = do
    counter <- newTVarIO 0
    runSql server ("CREATE DATABASE " <> quoteIdentifier templateDbName)
    -- Apply migrations through short-lived codd connections, all of which are
    -- released before any clone, so the template has no active sessions when
    -- PostgreSQL copies it.
    migrateTemplate (connectionStringFor server templateDbName)
    pure (Fixture server templateDbName counter)

-- | Clone a fresh, empty, migrated database from the template, open a
-- 'Store.KirokuStore' against it, run @action@, then drop the clone. The store
-- (including its notifier and publisher connections) is torn down before the
-- database is dropped.
withFreshStore :: Fixture -> (Store.KirokuStore -> IO ()) -> IO ()
withFreshStore fixture action =
  withFreshDatabase fixture \connStr ->
    Store.withStore (Store.defaultConnectionSettings connStr) action

-- | Like 'withFreshStore' but provides two independent migrated databases (and
-- two stores) cloned from the same template — used by cross-context
-- integration tests that need two isolated PostgreSQL databases.
withFreshStores2 :: Fixture -> ((Store.KirokuStore, Store.KirokuStore) -> IO ()) -> IO ()
withFreshStores2 fixture action =
  withFreshDatabase fixture \connStrA ->
    withFreshDatabase fixture \connStrB ->
      Store.withStore (Store.defaultConnectionSettings connStrA) \storeA ->
        Store.withStore (Store.defaultConnectionSettings connStrB) \storeB ->
          action (storeA, storeB)

-- | Clone a fresh database from the template, pass its connection string to
-- @action@, and drop it afterwards. Database names are unique per clone.
withFreshDatabase :: Fixture -> (Text -> IO a) -> IO a
withFreshDatabase fixture action =
  bracket create dropDb \dbName ->
    action (connectionStringFor fixture.server dbName)
 where
  create = do
    n <- atomically $ stateTVar fixture.nextId \i -> (i + 1, i + 1)
    let dbName = "keiro_test_" <> Text.pack (show n)
    runSql fixture.server $
      "CREATE DATABASE "
        <> quoteIdentifier dbName
        <> " TEMPLATE "
        <> quoteIdentifier fixture.templateName
    pure dbName

  dropDb dbName =
    runSql fixture.server $
      "DROP DATABASE IF EXISTS " <> quoteIdentifier dbName <> " WITH (FORCE)"

migrateTemplate :: Text -> IO ()
migrateTemplate connStr =
  () <$ runAllKeiroMigrations (templateCoddSettings connStr) (secondsToDiffTime 5) LaxCheck

-- | Codd settings for the template database. Kiroku and Keiro migrations both
-- target the @kiroku@ schema, matching the default search path configured by
-- 'Store.defaultConnectionSettings'. 'LaxCheck' is used because the template
-- keeps no checked-in expected-schema representation.
templateCoddSettings :: Text -> CoddSettings
templateCoddSettings connStr =
  CoddSettings
    { migsConnString = parseConnString connStr
    , sqlMigrations = []
    , onDiskReps = Right (DbRep Null Map.empty Map.empty)
    , namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]
    , extraRolesToCheck = []
    , retryPolicy = singleTryPolicy
    , txnIsolationLvl = DbDefault
    , schemaAlgoOpts = SchemaAlgo False False False
    }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
  case parseOnly (connStringParser <* endOfInput) connStr of
    Left err -> error ("Could not parse ephemeral PostgreSQL connection string for codd: " <> err)
    Right parsed -> parsed

-- | Build a libpq connection string for a named database on the fixture's
-- server, addressing it over the server's Unix socket.
connectionStringFor :: Pg.Database -> Text -> Text
connectionStringFor db dbName =
  Text.unwords
    [ "host=" <> Text.pack db.socketDirectory
    , "port=" <> Text.pack (show db.port)
    , "dbname=" <> dbName
    , "user=" <> db.user
    ]

-- | Run a single SQL command against the server's default database (used for
-- @CREATE DATABASE@ / @DROP DATABASE@, which cannot run inside a transaction).
runSql :: Pg.Database -> Text -> IO ()
runSql db = runSqlOn (Pg.connectionString db)

runSqlOn :: Text -> Text -> IO ()
runSqlOn connStr sql = do
  pool <-
    Pool.acquire $
      Pool.Config.settings
        [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
        , Pool.Config.size 1
        ]
  result <- Pool.use pool (Session.script sql)
  Pool.release pool
  either (fail . show) pure result

quoteIdentifier :: Text -> Text
quoteIdentifier ident =
  "\"" <> Text.replace "\"" "\"\"" ident <> "\""
