module Main (
    main,
)
where

import Codd (ApplyResult (..), CoddSettings (..), VerifySchemas (StrictCheck))
import Codd.Parsing (connStringParser)
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Contravariant.Extras (contrazip3)
import Control.Monad (filterM)
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Keiro.Migrations (runAllKeiroMigrations, runAllKeiroMigrationsNoCheck)
import System.Directory (doesDirectoryExist)
import Test.Hspec

main :: IO ()
main =
    hspec $
        describe "Keiro codd migrations" $ do
            it "applies Kiroku and Keiro migrations to a fresh database and is repeatable" $ do
                result <- Pg.withCached $ \db -> do
                    let connStr = Pg.connectionString db
                        coddSettings = testCoddSettings connStr "keiro-migrations/expected-schema"

                    runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                    assertTablesExist connStr "kiroku" expectedTables
                    assertTablesAbsent connStr "public" expectedTables

                    runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                    assertTablesExist connStr "kiroku" expectedTables
                    assertTablesAbsent connStr "public" expectedTables
                    assertColumnExists connStr "kiroku" "keiro_timers" "last_error"

                case result of
                    Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                    Right () -> pure ()

            it "matches the checked-in expected schema" $ do
                expectedSchemaDir <- findExpectedSchemaDir
                result <- Pg.withCached $ \db -> do
                    let coddSettings = testCoddSettings (Pg.connectionString db) expectedSchemaDir
                    runAllKeiroMigrations coddSettings (secondsToDiffTime 5) StrictCheck

                case result of
                    Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                    Right (SchemasMatch _) -> pure ()
                    Right SchemasNotVerified -> expectationFailure "StrictCheck did not verify schemas"
                    Right (SchemasDiffer _) -> expectationFailure "StrictCheck returned a schema mismatch without throwing"

expectedTables :: [Text]
expectedTables =
    [ "events"
    , "keiro_inbox"
    , "keiro_outbox"
    , "keiro_read_models"
    , "keiro_snapshots"
    , "keiro_timers"
    , "stream_events"
    , "streams"
    , "subscriptions"
    ]

testCoddSettings :: Text -> FilePath -> CoddSettings
testCoddSettings connStr expectedSchemaDir =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Left expectedSchemaDir
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

findExpectedSchemaDir :: IO FilePath
findExpectedSchemaDir = do
    let candidates =
            [ "keiro-migrations/expected-schema"
            , "expected-schema"
            ]
    existing <- filterM doesDirectoryExist candidates
    case existing of
        dir : _ -> pure dir
        [] ->
            expectationFailure "Could not find keiro-migrations/expected-schema"
                >> pure "keiro-migrations/expected-schema"

assertTablesExist :: Text -> Text -> [Text] -> IO ()
assertTablesExist connStr schema tables = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement schema schemaTablesStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("table verification query failed: " <> show err)
        Right actualTables -> do
            let missing = filter (`notElem` actualTables) tables
            missing `shouldBe` []
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

assertTablesAbsent :: Text -> Text -> [Text] -> IO ()
assertTablesAbsent connStr schema tables = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement schema schemaTablesStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("table verification query failed: " <> show err)
        Right actualTables -> do
            let present = filter (`elem` actualTables) tables
            present `shouldBe` []
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

assertColumnExists :: Text -> Text -> Text -> Text -> IO ()
assertColumnExists connStr schema table column = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement (schema, table, column) columnExistsStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("column verification query failed: " <> show err)
        Right present -> present `shouldBe` True
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

columnExistsStmt :: Statement (Text, Text, Text) Bool
columnExistsStmt =
    preparable
        """
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        )
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (D.singleRow (D.column (D.nonNullable D.bool)))

schemaTablesStmt :: Statement Text [Text]
schemaTablesStmt =
    preparable
        """
        SELECT table_name::text
        FROM information_schema.tables
        WHERE table_schema = $1
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
        """
        (E.param (E.nonNullable E.text))
        (D.rowList (D.column (D.nonNullable D.text)))
