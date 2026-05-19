{-# LANGUAGE MultilineStrings #-}

module Main
  ( main
  )
where

import Codd (CoddSettings (..), VerifySchemas (LaxCheck))
import Codd.Parsing (connStringParser)
import Codd.Representations.Types (DbRep (..))
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Data.Aeson (Value (Null))
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Functor.Contravariant ((>$<))
import Data.Map qualified as Map
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
import Keiro.Migrations (runAllKeiroMigrations)
import Test.Hspec

main :: IO ()
main =
  hspec $
    describe "Keiro codd migrations" $ do
      it "applies Kiroku and Keiro migrations to a fresh database and is repeatable" $ do
        result <- Pg.withCached $ \db -> do
          let connStr = Pg.connectionString db
              coddSettings = testCoddSettings connStr

          _ <- runAllKeiroMigrations coddSettings (secondsToDiffTime 5) LaxCheck
          assertTablesExist connStr expectedTables

          _ <- runAllKeiroMigrations coddSettings (secondsToDiffTime 5) LaxCheck
          assertTablesExist connStr expectedTables

        case result of
          Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
          Right () -> pure ()

      it "creates inbox worker columns" $ do
        result <- Pg.withCached $ \db -> do
          let connStr = Pg.connectionString db
              coddSettings = testCoddSettings connStr
          _ <- runAllKeiroMigrations coddSettings (secondsToDiffTime 5) LaxCheck
          assertColumnsExist connStr "keiro_inbox"
            [ "attempt_count"
            , "next_attempt_at"
            , "claimed_at"
            ]
          assertIndexExists connStr "keiro_inbox" "keiro_inbox_claimable_idx"
        case result of
          Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
          Right () -> pure ()

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

testCoddSettings :: Text -> CoddSettings
testCoddSettings connStr =
  CoddSettings
    { migsConnString = parseConnString connStr
    , sqlMigrations = []
    , onDiskReps = Right (DbRep Null Map.empty Map.empty)
    , namespacesToCheck = IncludeSchemas [SqlSchema "public"]
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

assertTablesExist :: Text -> [Text] -> IO ()
assertTablesExist connStr tables =
  withPool connStr $ \pool -> do
    result <- Pool.use pool (Session.statement () publicTablesStmt)
    case result of
      Left err -> expectationFailure ("table verification query failed: " <> show err)
      Right actualTables -> do
        let missing = filter (`notElem` actualTables) tables
        missing `shouldBe` []

assertColumnsExist :: Text -> Text -> [Text] -> IO ()
assertColumnsExist connStr table columns =
  withPool connStr $ \pool -> do
    result <- Pool.use pool (Session.statement table tableColumnsStmt)
    case result of
      Left err -> expectationFailure ("column verification query failed: " <> show err)
      Right actualColumns -> do
        let missing = filter (`notElem` actualColumns) columns
        missing `shouldBe` []

assertIndexExists :: Text -> Text -> Text -> IO ()
assertIndexExists connStr table indexName =
  withPool connStr $ \pool -> do
    result <- Pool.use pool (Session.statement (table, indexName) indexExistsStmt)
    case result of
      Left err -> expectationFailure ("index verification query failed: " <> show err)
      Right True -> pure ()
      Right False ->
        expectationFailure ("expected index " <> show indexName <> " on " <> show table)

withPool :: Text -> (Pool.Pool -> IO ()) -> IO ()
withPool connStr action = do
  pool <- Pool.acquire poolConfig
  action pool
  Pool.release pool
 where
  poolConfig =
    Pool.Config.settings
      [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
      , Pool.Config.size 1
      ]

publicTablesStmt :: Statement () [Text]
publicTablesStmt =
  preparable
    """
    SELECT table_name::text
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE'
    ORDER BY table_name
    """
    E.noParams
    (D.rowList (D.column (D.nonNullable D.text)))

tableColumnsStmt :: Statement Text [Text]
tableColumnsStmt =
  preparable
    """
    SELECT column_name::text
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = $1
    ORDER BY column_name
    """
    (E.param (E.nonNullable E.text))
    (D.rowList (D.column (D.nonNullable D.text)))

indexExistsStmt :: Statement (Text, Text) Bool
indexExistsStmt =
  preparable
    """
    SELECT EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE schemaname = 'public'
        AND tablename = $1
        AND indexname = $2
    )
    """
    ( (fst >$< E.param (E.nonNullable E.text))
        <> (snd >$< E.param (E.nonNullable E.text))
    )
    (D.singleRow (D.column (D.nonNullable D.bool)))
