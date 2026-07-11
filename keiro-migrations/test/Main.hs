{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (finally)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.Codd
import Database.PostgreSQL.Migrate.Internal (
    ComponentDescription (..),
    PlanDescription (..),
    componentNameText,
    migrationChecksumBytes,
    planDescription,
 )
import Database.PostgreSQL.Migrate.Test (withMigratedDatabase)
import EphemeralPg qualified as Pg
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Keiro.Migrations
import Keiro.Migrations.History.Codd
import Kiroku.Store.Migrations qualified as Kiroku
import Kiroku.Store.Migrations.History.Codd qualified as Kiroku.Codd
import Numeric qualified
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

main :: IO ()
main = hspec $ do
    describe "native Keiro migration definition" $ do
        it "tracks seventeen native files in manifest order" $ do
            directory <- findMigrationsDirectory
            manifest <- Text.lines <$> Text.IO.readFile (directory </> "manifest")
            manifest `shouldBe` Text.pack <$> nativeMigrationFiles

        it "preserves every legacy payload byte recorded by migrations.lock" $ do
            directory <- findMigrationsDirectory
            lockPath <- findLockfile
            lockEntries <- parseLockfile <$> Text.IO.readFile lockPath
            forM_ (zip (toList keiroLegacyMigrationNames) nativeMigrationFiles) $ \(legacyName, nativeName) -> do
                bytes <- ByteString.readFile (directory </> nativeName)
                lookup legacyName lockEntries `shouldBe` Just (checksumText bytes)

        it "builds component keiro with dependency kiroku and seventeen migrations" $ do
            plan <- requirePlan
            let PlanDescription components = planDescription plan
            case toList components of
                [ ComponentDescription{name = kirokuName, dependencies = kirokuDependencies, migrations = kirokuEntries}
                    , ComponentDescription{name = keiroName, dependencies = keiroDependencies, migrations = keiroEntries}
                    ] -> do
                        componentNameText kirokuName `shouldBe` "kiroku"
                        kirokuDependencies `shouldBe` mempty
                        length kirokuEntries `shouldBe` 8
                        componentNameText keiroName `shouldBe` "keiro"
                        dependencyName <- requireRight (componentName "kiroku")
                        keiroDependencies `shouldBe` Set.singleton dependencyName
                        length keiroEntries `shouldBe` 17
                actual -> expectationFailure ("unexpected plan description: " <> show actual)
            validateHistoryMappingTargets plan frameworkCoddHistoryMappings `shouldBe` Right ()

        it "rejects missing and reversed Kiroku dependencies" $ do
            kiroku <- requireRight Kiroku.kirokuMigrations
            keiro <- requireRight keiroMigrations
            migrationPlan (keiro :| []) `shouldSatisfy` isLeft
            frameworkMigrationPlan keiro kiroku `shouldSatisfy` isLeft

    describe "fresh native databases" $ do
        it "applies Kiroku then Keiro, verifies strictly, and is repeatable" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                assertSchema connection
                let provider = providerFor connection
                rerun <- runMigrationPlanWith defaultRunOptions provider plan >>= requireRight
                reportOutcomes rerun `shouldBe` replicate 25 AlreadyApplied
                verified <- verifyMigrationPlanWith defaultRunOptions provider plan >>= requireRight
                case verified of
                    VerificationReport verificationIssues applied pending unknown -> do
                        verificationIssues `shouldBe` []
                        length applied `shouldBe` 25
                        pending `shouldBe` []
                        unknown `shouldBe` []
            either (expectationFailure . show) pure result

        it "serializes concurrent composed applies" $ do
            plan <- requirePlan
            withKeiroPg $ \database -> do
                let settings = Pg.connectionSettings database
                (first, second) <-
                    concurrently
                        (runMigrationPlan defaultRunOptions settings plan >>= requireRight)
                        (runMigrationPlan defaultRunOptions settings plan >>= requireRight)
                sort [reportOutcomes first, reportOutcomes second]
                    `shouldBe` sort [replicate 25 AppliedNow, replicate 25 AlreadyApplied]

    describe "combined Codd history import" $ do
        it "imports a shared Codd V5 ledger atomically without replaying target SQL" $
            importFixture "codd"

        it "imports the legacy codd_schema ledger shape" $
            importFixture "codd_schema"

        it "rejects one partial source row before creating the target ledger" $ do
            plan <- requirePlan
            withKeiroPg $ \database -> do
                let settings = Pg.connectionSettings database
                    provider = connectionProviderFromSettings settings
                withConnection settings $ \connection -> do
                    applyLegacyPayloads connection
                    installCoddLedger connection "codd" True False
                config <-
                    requireRight
                        (frameworkCoddSourceConfig provider True "partial fixture must fail" Confirmed)
                imported <-
                    importCoddHistory defaultImportOptions config provider plan frameworkCoddHistoryMappings
                imported `shouldSatisfy` \case
                    Left CoddPartialMigration{} -> True
                    _ -> False
                withConnection settings $ \connection -> do
                    targetExists <- useSession connection (Session.statement "pgmigrate" schemaExistsStatement)
                    targetExists `shouldBe` False

        it "rejects unselected shared-ledger rows in strict mode" $ do
            plan <- requirePlan
            withKeiroPg $ \database -> do
                let settings = Pg.connectionSettings database
                    provider = connectionProviderFromSettings settings
                withConnection settings $ \connection -> do
                    applyLegacyPayloads connection
                    installCoddLedger connection "codd" False True
                config <-
                    requireRight
                        (frameworkCoddSourceConfig provider True "strict source fixture" Confirmed)
                imported <-
                    importCoddHistory defaultImportOptions config provider plan frameworkCoddHistoryMappings
                imported `shouldSatisfy` \case
                    Left CoddStrictSourceHasUnselected{} -> True
                    _ -> False

importFixture :: Text -> Expectation
importFixture sourceSchema = do
    plan <- requirePlan
    withKeiroPg $ \database -> do
        let settings = Pg.connectionSettings database
            provider = connectionProviderFromSettings settings
        withConnection settings $ \connection -> do
            applyLegacyPayloads connection
            installCoddLedger connection sourceSchema False False
        config <-
            requireRight
                (frameworkCoddSourceConfig provider True "verified Keiro shared-ledger cutover" Confirmed)
        first <-
            importCoddHistory defaultImportOptions config provider plan frameworkCoddHistoryMappings
                >>= requireRight
        importOutcomes first `shouldBe` replicate 23 Imported
        kirokuCanaryId <- requireRight (migrationId "kiroku" "0008-schema-management-comment")
        keiroCanaryId <- requireRight (migrationId "keiro" "0017-schema-management-comment")
        verifiedBeforeCanaries <- verifyMigrationPlan defaultRunOptions settings plan >>= requireRight
        case verifiedBeforeCanaries of
            VerificationReport verificationIssues _ _ _ ->
                verificationIssues `shouldBe` [PendingMigration kirokuCanaryId, PendingMigration keiroCanaryId]
        up <- runMigrationPlan defaultRunOptions settings plan >>= requireRight
        reportOutcomes up
            `shouldBe` replicate 7 AlreadyApplied
                <> [AppliedNow]
                <> replicate 16 AlreadyApplied
                <> [AppliedNow]
        verifiedAfterCanaries <- verifyMigrationPlan defaultRunOptions settings plan >>= requireRight
        case verifiedAfterCanaries of
            VerificationReport verificationIssues _ _ _ -> verificationIssues `shouldBe` []
        rerun <- runMigrationPlan defaultRunOptions settings plan >>= requireRight
        reportOutcomes rerun `shouldBe` replicate 25 AlreadyApplied
        second <-
            importCoddHistory defaultImportOptions config provider plan frameworkCoddHistoryMappings
                >>= requireRight
        importOutcomes second `shouldBe` replicate 23 AlreadyImported
        withConnection settings $ \connection -> do
            assertSchema connection
            sourceRows <- useSession connection (Session.statement () (sourceRowCountStatement sourceSchema))
            sourceRows `shouldBe` 23
            facts <- useSession connection (Session.statement () importFactsStatement)
            facts `shouldBe` (25, 23, True)

nativeMigrationFiles :: [FilePath]
nativeMigrationFiles =
    [ "0001-keiro-bootstrap.sql"
    , "0002-keiro-outbox.sql"
    , "0003-keiro-inbox.sql"
    , "0004-keiro-timer-recovery.sql"
    , "0005-keiro-workflow-steps.sql"
    , "0006-keiro-awakeables.sql"
    , "0007-keiro-workflow-children.sql"
    , "0008-keiro-workflow-generation.sql"
    , "0009-keiro-subscription-shards.sql"
    , "0010-keiro-messaging-crash-recovery.sql"
    , "0011-keiro-workflows-instances.sql"
    , "0012-keiro-workflow-gc-index.sql"
    , "0013-keiro-workflows-wake-after.sql"
    , "0014-keiro-projection-dedup.sql"
    , "0015-keiro-outbox-claim-order-index.sql"
    , "0016-keiro-inbox-drop-received-idx.sql"
    , "0017-schema-management-comment.sql"
    ]

findMigrationsDirectory :: IO FilePath
findMigrationsDirectory =
    findDirectory ["keiro-migrations/migrations", "migrations"]

findLockfile :: IO FilePath
findLockfile =
    findFile ["keiro-migrations/migrations.lock", "migrations.lock"]

findDirectory :: [FilePath] -> IO FilePath
findDirectory candidates = do
    existing <- filterM doesDirectoryExist candidates
    case existing of
        directory : _ -> pure directory
        [] -> expectationFailure ("could not find directory: " <> show candidates) >> pure "."

findFile :: [FilePath] -> IO FilePath
findFile candidates = do
    existing <- filterM doesFileExist candidates
    case existing of
        path : _ -> pure path
        [] -> expectationFailure ("could not find file: " <> show candidates) >> pure "."

filterM :: (value -> IO Bool) -> [value] -> IO [value]
filterM predicate = foldr step (pure [])
  where
    step value remaining = do
        matches <- predicate value
        values <- remaining
        pure (if matches then value : values else values)

parseLockfile :: Text -> [(FilePath, Text)]
parseLockfile contents =
    [ (Text.unpack filename, checksum)
    | line <- Text.lines contents
    , [checksum, filename] <- [Text.words line]
    ]

checksumText :: ByteString -> Text
checksumText =
    Text.pack
        . concatMap renderByte
        . ByteString.unpack
        . migrationChecksumBytes
        . migrationFingerprint
  where
    renderByte byte =
        case Numeric.showHex byte "" of
            [digit] -> ['0', digit]
            digits -> digits

requirePlan :: IO MigrationPlan
requirePlan = do
    kiroku <- requireRight Kiroku.kirokuMigrations
    keiro <- requireRight keiroMigrations
    requireRight (frameworkMigrationPlan kiroku keiro)

requireRight :: (Show error) => Either error value -> IO value
requireRight = either failure pure

failure :: (Show value) => value -> IO result
failure value = expectationFailure (show value) >> fail (show value)

providerFor :: Connection.Connection -> ConnectionProvider
providerFor connection = connectionProvider (\action -> Right <$> action connection)

reportOutcomes :: MigrationReport -> [MigrationOutcome]
reportOutcomes MigrationReport{results} = outcome <$> toList results

importOutcomes :: HistoryImportReport -> [HistoryImportOutcome]
importOutcomes HistoryImportReport{importResults} = importOutcome <$> toList importResults

keiroPgConfig :: Pg.Config
keiroPgConfig = Pg.defaultConfig{Pg.user = "keiro"}

withKeiroPg :: (Pg.Database -> IO ()) -> IO ()
withKeiroPg action = do
    started <- Pg.startCached keiroPgConfig Pg.defaultCacheConfig
    case started of
        Left startError -> expectationFailure (show startError)
        Right database -> action database `finally` Pg.stop database

withConnection :: Settings.Settings -> (Connection.Connection -> IO value) -> IO value
withConnection settings action = do
    acquired <- Connection.acquire settings
    connection <- requireRight acquired
    action connection `finally` Connection.release connection

useSession :: Connection.Connection -> Session.Session value -> IO value
useSession connection session =
    Connection.use connection session >>= requireRight

assertSchema :: Connection.Connection -> Expectation
assertSchema connection = do
    healthy <- useSession connection (Session.statement () schemaFactsStatement)
    healthy `shouldBe` True

schemaFactsStatement :: Statement () Bool
schemaFactsStatement =
    Statement.preparable
        """
        SELECT bool_and(ok)
        FROM (VALUES
          (to_regnamespace('kiroku') IS NOT NULL),
          (to_regclass('kiroku.events') IS NOT NULL),
          (to_regnamespace('keiro') IS NOT NULL),
          (to_regclass('keiro.keiro_inbox') IS NOT NULL),
          (to_regclass('keiro.keiro_outbox') IS NOT NULL),
          (to_regclass('keiro.keiro_timers') IS NOT NULL),
          (to_regclass('keiro.keiro_workflows') IS NOT NULL),
          (obj_description(to_regnamespace('kiroku'), 'pg_namespace') = 'Managed by pg-migrate component kiroku through 0008-schema-management-comment'),
          (obj_description(to_regnamespace('keiro'), 'pg_namespace') = 'Managed by pg-migrate component keiro through 0017-schema-management-comment')
        ) AS checks(ok)
        """
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

applyLegacyPayloads :: Connection.Connection -> IO ()
applyLegacyPayloads connection = do
    apply Kiroku.Codd.kirokuLegacyMigrationNames Kiroku.Codd.kirokuCoddSourcePayloads
    apply keiroLegacyMigrationNames keiroCoddSourcePayloads
  where
    apply names payloads =
        forM_ names $ \name ->
            case Map.lookup name payloads of
                Nothing -> failure ("missing source payload " <> name)
                Just bytes -> useSession connection (Session.script (Text.Encoding.decodeUtf8 bytes))

installCoddLedger :: Connection.Connection -> Text -> Bool -> Bool -> IO ()
installCoddLedger connection sourceSchema partial includeExtra =
    useSession connection (Session.script (coddFixtureSql sourceSchema partial includeExtra))

coddFixtureSql :: Text -> Bool -> Bool -> Text
coddFixtureSql sourceSchema partial includeExtra =
    Text.unlines
        [ "CREATE SCHEMA " <> sourceSchema <> ";"
        , "CREATE TABLE " <> sourceSchema <> ".sql_migrations ("
        , "  id serial NOT NULL, migration_timestamp timestamptz NOT NULL,"
        , "  applied_at timestamptz, name text NOT NULL, application_duration interval,"
        , "  num_applied_statements int, no_txn_failed_at timestamptz, txnid bigint, connid int"
        , ");"
        , "INSERT INTO " <> sourceSchema <> ".sql_migrations"
        , "  (migration_timestamp, applied_at, name, application_duration, num_applied_statements, no_txn_failed_at, txnid, connid) VALUES"
        , Text.intercalate ",\n" (zipWith renderRow [1 :: Int ..] filenames) <> ";"
        ]
  where
    selected = toList Kiroku.Codd.kirokuLegacyMigrationNames <> toList keiroLegacyMigrationNames
    filenames = selected <> ["application-owned-extra.sql" | includeExtra]
    renderRow index filename =
        "('2026-01-01 00:00:00+00'::timestamptz + interval '"
            <> Text.pack (show index)
            <> " seconds', "
            <> appliedAt index
            <> ", '"
            <> Text.pack filename
            <> "', interval '1 second', 1, "
            <> failureAt index
            <> ", 1, 1)"
    appliedAt index
        | partial && index == 11 = "NULL"
        | otherwise = "'2026-01-01 00:01:00+00'::timestamptz + interval '" <> Text.pack (show index) <> " seconds'"
    failureAt index
        | partial && index == 11 = "'2026-01-01 00:02:00+00'::timestamptz"
        | otherwise = "NULL"

schemaExistsStatement :: Statement Text Bool
schemaExistsStatement =
    Statement.preparable
        "SELECT to_regnamespace($1) IS NOT NULL"
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

sourceRowCountStatement :: Text -> Statement () Int64
sourceRowCountStatement sourceSchema =
    Statement.unpreparable
        ("SELECT count(*) FROM " <> sourceSchema <> ".sql_migrations")
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

importFactsStatement :: Statement () (Int64, Int64, Bool)
importFactsStatement =
    Statement.preparable
        """
        SELECT
          (SELECT count(*) FROM pgmigrate.migrations),
          (SELECT count(*) FROM pgmigrate.history_imports),
          (SELECT bool_and(source_evidence #>> '{satisfying_evidence,0,details,adapter}' = 'codd') FROM pgmigrate.history_imports)
        """
        Encoders.noParams
        ( Decoders.singleRow
            ( (,,)
                <$> column Decoders.int8
                <*> column Decoders.int8
                <*> column Decoders.bool
            )
        )
  where
    column = Decoders.column . Decoders.nonNullable
