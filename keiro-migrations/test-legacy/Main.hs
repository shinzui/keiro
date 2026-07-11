module Main (
    main,
)
where

import Codd (ApplyResult (..), CoddSettings (..), VerifySchemas (LaxCheck, StrictCheck))
import Codd.Extras.Guards
import Codd.Parsing (connStringParser)
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Contravariant.Extras (contrazip3)
import Control.Concurrent.Async (concurrently)
import Control.Exception (finally)
import Control.Monad (filterM)
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Int (Int32)
import Data.List (isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Keiro.Migrations.LegacyCodd (
    MigrationStatus (..),
    VerifyOutcome (..),
    embeddedMigrationNames,
    embeddedMigrationSources,
    kirokuEmbeddedMigrationNames,
    migrationStatus,
    missingMigrations,
    runAllKeiroMigrations,
    runAllKeiroMigrationsNoCheck,
    runKirokuMigrationsNoCheck,
    verifySchema,
 )
import Keiro.Migrations.New (migrationFileName, migrationSlug, newMigrationFile)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeFileName)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

{- | Pin the ephemeral PostgreSQL superuser to the fixed name @keiro@ so the
captured snapshot identity (roles, database owner, per-object owners) is
deterministic across machines and CI rather than the local OS username. This is
the portability fix for the strict drift gate.
-}
keiroPgConfig :: Pg.Config
keiroPgConfig = Pg.defaultConfig{Pg.user = "keiro"}

{- | Start a cached ephemeral server whose PostgreSQL superuser is the fixed
name @keiro@. Mirrors 'Pg.withCached' but pins the user; 'Pg.withCachedConfig'
is not exported, so we use 'Pg.startCached' + 'finally'.
-}
withKeiroPg :: (Pg.Database -> IO a) -> IO (Either Pg.StartError a)
withKeiroPg action = do
    started <- Pg.startCached keiroPgConfig Pg.defaultCacheConfig
    case started of
        Left err -> pure (Left err)
        Right db -> Right <$> (action db `finally` Pg.stop db)

main :: IO ()
main =
    hspec $ do
        migrationFileNameSpec
        migrationIntegritySpec
        scaffolderSpec
        migrationUpgradeSpec
        describe "Keiro codd migrations" $ do
            it "applies Kiroku and Keiro migrations to a fresh database and is repeatable" $ do
                result <- withKeiroPg $ \db -> do
                    let connStr = Pg.connectionString db
                        coddSettings = testCoddSettings connStr "keiro-migrations/expected-schema"

                    runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                    assertTablesExist connStr "kiroku" kirokuTables
                    assertTablesExist connStr "keiro" keiroTables
                    assertTablesAbsent connStr "kiroku" keiroTables
                    assertTablesAbsent connStr "public" keiroTables
                    assertTablesAbsent connStr "public" kirokuTables

                    runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                    assertTablesExist connStr "kiroku" kirokuTables
                    assertTablesExist connStr "keiro" keiroTables
                    assertTablesAbsent connStr "kiroku" keiroTables
                    assertTablesAbsent connStr "public" keiroTables
                    assertColumnExists connStr "keiro" "keiro_timers" "last_error"

                case result of
                    Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                    Right () -> pure ()

            it "matches the checked-in expected schema" $ do
                expectedSchemaDir <- findExpectedSchemaDir
                result <- withKeiroPg $ \db -> do
                    let coddSettings = testCoddSettings (Pg.connectionString db) expectedSchemaDir
                    runAllKeiroMigrations coddSettings (secondsToDiffTime 5) StrictCheck

                case result of
                    Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                    Right (SchemasMatch _) -> pure ()
                    Right SchemasNotVerified -> expectationFailure "StrictCheck did not verify schemas"
                    Right (SchemasDiffer _) -> expectationFailure "StrictCheck returned a schema mismatch without throwing"

            it "reports schema drift under LaxCheck" $ do
                expectedSchemaDir <- findExpectedSchemaDir
                result <- withKeiroPg $ \db -> do
                    let connStr = Pg.connectionString db
                        coddSettings = testCoddSettings connStr expectedSchemaDir
                    runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                    runDb
                        connStr
                        "drift drill"
                        (Session.script "ALTER TABLE keiro.keiro_timers ALTER COLUMN last_error SET NOT NULL;")
                    runAllKeiroMigrations coddSettings (secondsToDiffTime 5) LaxCheck

                case result of
                    Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                    Right (SchemasDiffer _) -> pure ()
                    Right SchemasNotVerified -> expectationFailure "LaxCheck did not verify schemas"
                    Right (SchemasMatch _) -> expectationFailure "LaxCheck did not report schema drift"

{- | Guard against the recurring mistake of hand-assigning rounded, sentinel
migration timestamps (e.g. @2026-05-17-00-00-00-...@, @...-01-00-00-...@).
Migrations must be created with @keiro-migrate new@ ("Keiro.Migrations.New"),
which stamps the real current UTC time to the second, so filenames sort in true
authoring order and never collide in codd's timestamp-keyed ledger.
-}
migrationFileNameSpec :: Spec
migrationFileNameSpec =
    describe "migration file names" $ do
        it "carry real UTC authoring timestamps, not hand-assigned sentinels" $ do
            files <- migrationFiles
            files `shouldNotBe` []
            sentinelViolations files `shouldHaveNoViolations` "sentinel timestamp violations"

        it "have unique, strictly increasing timestamps" $ do
            files <- migrationFiles
            duplicateTimestampViolations files `shouldHaveNoViolations` "duplicate timestamp violations"

migrationIntegritySpec :: Spec
migrationIntegritySpec =
    describe "migration integrity guards" $ do
        it "embeds exactly the checked-in sql-migrations directory" $ do
            diskNames <- sort <$> migrationFiles
            embeddedMigrationNames `shouldBe` diskNames

        it "matches the checked-in SHA-256 manifest" $ do
            manifestPath <- findLockfile
            parsed <- parseChecksumManifest <$> TIO.readFile manifestPath
            case parsed of
                Left err -> expectationFailure (T.unpack err)
                Right manifest ->
                    checksumViolations manifest embeddedMigrationSources
                        `shouldHaveNoViolations` "checksum manifest violations"

        it "keeps future migration bodies schema-qualified and codd-safe" $ do
            lintViolations
                LintConfig
                    { requiredQualifier = "keiro."
                    , exemptFiles = []
                    }
                embeddedMigrationSources
                `shouldHaveNoViolations` "migration body lint violations"

        it "keeps timestamps unique across the combined Kiroku and Keiro ledger" $ do
            duplicateTimestampViolations expectedLedgerNames
                `shouldHaveNoViolations` "combined-ledger duplicate timestamp violations"

        it "records every embedded Kiroku and Keiro migration in the codd v5 ledger" $ do
            result <- withKeiroPg $ \db -> do
                let connStr = Pg.connectionString db
                    coddSettings = testCoddSettings connStr "keiro-migrations/expected-schema"
                runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                schema <- detectLedgerSchema connStr
                schema `shouldBe` "codd"
                names <- ledgerNames connStr schema
                names `shouldBe` map T.pack expectedLedgerNames
            case result of
                Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()

        it "serializes concurrent combined applies with the shared advisory lock" $ do
            result <- withKeiroPg $ \db -> do
                let connStr = Pg.connectionString db
                    coddSettings = testCoddSettings connStr "keiro-migrations/expected-schema"
                concurrently
                    (runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5))
                    (runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5))
                schema <- detectLedgerSchema connStr
                names <- ledgerNames connStr schema
                names `shouldBe` map T.pack expectedLedgerNames
                count <- ledgerRowCount connStr schema
                count `shouldBe` fromIntegral (length expectedLedgerNames)
            case result of
                Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()

        it "reports every embedded migration as pending on an empty database" $ do
            result <- withKeiroPg $ \db -> do
                let coddSettings = testCoddSettings (Pg.connectionString db) "keiro-migrations/expected-schema"
                verifySchema coddSettings (secondsToDiffTime 5) `shouldReturn` VerifyPending expectedLedgerNames
                status <- migrationStatus coddSettings (secondsToDiffTime 5)
                statusApplied status `shouldBe` []
                statusPending status `shouldBe` expectedLedgerNames
                missingMigrations coddSettings (secondsToDiffTime 5) `shouldReturn` expectedLedgerNames
            case result of
                Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()

        it "reports only Keiro migrations as pending after Kiroku-only apply" $ do
            result <- withKeiroPg $ \db -> do
                let coddSettings = testCoddSettings (Pg.connectionString db) "keiro-migrations/expected-schema"
                runKirokuMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                verifySchema coddSettings (secondsToDiffTime 5) `shouldReturn` VerifyPending embeddedMigrationNames
                status <- migrationStatus coddSettings (secondsToDiffTime 5)
                map fst (statusApplied status) `shouldBe` kirokuEmbeddedMigrationNames
                statusPending status `shouldBe` embeddedMigrationNames
                missingMigrations coddSettings (secondsToDiffTime 5) `shouldReturn` embeddedMigrationNames
            case result of
                Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()

        it "verifies the embedded Keiro expected schema after combined apply" $ do
            result <- withKeiroPg $ \db -> do
                let coddSettings = testCoddSettings (Pg.connectionString db) "keiro-migrations/expected-schema"
                runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                verifySchema coddSettings (secondsToDiffTime 5) `shouldReturn` VerifySucceeded
                status <- migrationStatus coddSettings (secondsToDiffTime 5)
                map fst (statusApplied status) `shouldBe` expectedLedgerNames
                statusPending status `shouldBe` []
                missingMigrations coddSettings (secondsToDiffTime 5) `shouldReturn` []
            case result of
                Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()

        it "reports Keiro schema drift without applying migrations" $ do
            result <- withKeiroPg $ \db -> do
                let connStr = Pg.connectionString db
                    coddSettings = testCoddSettings connStr "keiro-migrations/expected-schema"
                runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                beforeCount <- ledgerRowCount connStr "codd"
                runDb connStr "verify drift mutation" (Session.script "CREATE TABLE keiro.verify_drift (id int);")
                verifySchema coddSettings (secondsToDiffTime 5) `shouldReturn` VerifyFailed
                afterCount <- ledgerRowCount connStr "codd"
                afterCount `shouldBe` beforeCount
            case result of
                Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()

        it "realigns historical sentinel ledger rows before a repeat migrate" $ do
            fixupPath <- findLedgerFixup
            fixupScript <- TIO.readFile fixupPath
            result <- withKeiroPg $ \db -> do
                let connStr = Pg.connectionString db
                    coddSettings = testCoddSettings connStr "keiro-migrations/expected-schema"
                runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                schema <- detectLedgerSchema connStr
                rewindKeiroLedgerToSentinelNames connStr schema
                sentinelNames <- ledgerNames connStr schema
                sentinelNames `shouldSatisfy` any (`elem` map oldLedgerName keiroLedgerRemaps)
                runDb connStr "keiro ledger fixup script" (Session.script fixupScript)
                fixedNames <- ledgerNames connStr schema
                fixedNames `shouldBe` map T.pack expectedLedgerNames
                beforeCount <- ledgerRowCount connStr schema
                runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                afterCount <- ledgerRowCount connStr schema
                afterCount `shouldBe` beforeCount
            case result of
                Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()

{- | Prove the scaffolder (`Keiro.Migrations.New`) is the producer that satisfies
the reactive filename guard. The deterministic check proves the slug convention;
the temp-dir check proves the live writer creates a schema-qualified template.
-}
scaffolderSpec :: Spec
scaffolderSpec =
    describe "migration scaffolder" $ do
        it "stamps a real, non-sentinel UTC timestamp and a keiro-prefixed slug" $ do
            let sampled = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime (19 * 3600 + 9 * 60 + 18))
                name = migrationFileName sampled "Add widget index"
            takeFileName name `shouldBe` name
            isTimestampShaped (take timestampWidth name) `shouldBe` True
            handAssignedTimestamp name `shouldBe` False
            migrationSlug "Add widget index" `shouldBe` "keiro-add-widget-index"

        it "writes a well-named file into a temp dir with a qualified template" $
            withSystemTempDirectory "keiro-scaffolder" $ \dir -> do
                path <- newMigrationFile dir "add widget index"
                let base = takeFileName path
                isTimestampShaped (take timestampWidth base) `shouldBe` True
                length base `shouldSatisfy` (> timestampWidth)
                body <- TIO.readFile path
                (".sql" `isSuffixOf` path) `shouldBe` True
                ("keiro.keiro_example" `T.isInfixOf` body) `shouldBe` True
                ("search_path" `T.isInfixOf` body) `shouldBe` False

migrationUpgradeSpec :: Spec
migrationUpgradeSpec =
    describe "keiro migration upgrade artifacts" $ do
        it "remediates a 0.1.0.0-style kiroku-schema layout without losing rows" $ do
            remediationPath <- findRemediationScript
            remediationScript <- TIO.readFile remediationPath
            expectedSchemaDir <- findExpectedSchemaDir
            result <- withKeiroPg $ \db -> do
                let connStr = Pg.connectionString db
                    coddSettings = testCoddSettings connStr expectedSchemaDir
                runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                schema <- detectLedgerSchema connStr
                moveKeiroTablesBackToKiroku connStr
                seedRemediationRows connStr
                runDb connStr "keiro schema remediation script" (Session.script remediationScript)

                assertTablesExist connStr "keiro" keiroTables
                assertTablesAbsent connStr "kiroku" keiroTables
                assertSnapshotRowSurvived connStr
                assertTimerRowSurvived connStr

                beforeCount <- ledgerRowCount connStr schema
                runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                afterCount <- ledgerRowCount connStr schema
                afterCount `shouldBe` beforeCount

                strictResult <- runAllKeiroMigrations coddSettings (secondsToDiffTime 5) StrictCheck
                case strictResult of
                    SchemasMatch _ -> pure ()
                    SchemasNotVerified -> expectationFailure "StrictCheck did not verify remediated schemas"
                    SchemasDiffer _ -> expectationFailure "StrictCheck returned a schema mismatch after remediation"

                runDb connStr "idempotent keiro schema remediation script" (Session.script remediationScript)
                assertTablesExist connStr "keiro" keiroTables
                assertTablesAbsent connStr "kiroku" keiroTables
                assertSnapshotRowSurvived connStr
                assertTimerRowSurvived connStr
            case result of
                Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()

-- | The migration @.sql@ files, wherever the suite is run from.
migrationFiles :: IO [FilePath]
migrationFiles = do
    dir <- findMigrationsDir
    filter (".sql" `isSuffixOf`) <$> listDirectory dir

findMigrationsDir :: IO FilePath
findMigrationsDir = do
    let candidates = ["keiro-migrations/sql-migrations", "sql-migrations"]
    existing <- filterM doesDirectoryExist candidates
    case existing of
        dir : _ -> pure dir
        [] ->
            expectationFailure "Could not find keiro-migrations/sql-migrations"
                >> pure "keiro-migrations/sql-migrations"

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

findLockfile :: IO FilePath
findLockfile = findExistingFile ["keiro-migrations/migrations.lock", "migrations.lock"]

findLedgerFixup :: IO FilePath
findLedgerFixup =
    findExistingFile
        [ "keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql"
        , "ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql"
        ]

findRemediationScript :: IO FilePath
findRemediationScript =
    findExistingFile
        [ "keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql"
        , "remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql"
        ]

findExistingFile :: [FilePath] -> IO FilePath
findExistingFile candidates = do
    existing <- filterM doesFileExist candidates
    case existing of
        path : _ -> pure path
        [] -> expectationFailure ("Could not find any of: " <> show candidates) >> pure fallback
  where
    fallback =
        case candidates of
            path : _ -> path
            [] -> "."

expectedLedgerNames :: [FilePath]
expectedLedgerNames = sort (kirokuEmbeddedMigrationNames <> embeddedMigrationNames)

-- | Kiroku's own event-store tables, which remain in the kiroku schema.
kirokuTables :: [Text]
kirokuTables =
    [ "events"
    , "stream_events"
    , "streams"
    , "subscriptions"
    ]

-- | Keiro's framework tables, which live in the dedicated keiro schema.
keiroTables :: [Text]
keiroTables =
    [ "keiro_awakeables"
    , "keiro_inbox"
    , "keiro_outbox"
    , "keiro_projection_dedup"
    , "keiro_read_models"
    , "keiro_snapshots"
    , "keiro_subscription_shards"
    , "keiro_timers"
    , "keiro_workflow_children"
    , "keiro_workflow_steps"
    , "keiro_workflows"
    ]

testCoddSettings :: Text -> FilePath -> CoddSettings
testCoddSettings connStr expectedSchemaDir =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Left expectedSchemaDir
        , namespacesToCheck = IncludeSchemas [SqlSchema "keiro"]
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

shouldHaveNoViolations :: [Text] -> String -> Expectation
shouldHaveNoViolations [] _ = pure ()
shouldHaveNoViolations violations label =
    expectationFailure (label <> ":\n" <> T.unpack (T.unlines violations))

runDb :: Text -> String -> Session.Session a -> IO a
runDb connStr label session = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool session
    Pool.release pool
    case result of
        Left err -> expectationFailure (label <> " failed: " <> show err) >> fail label
        Right value -> pure value
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

detectLedgerSchema :: Text -> IO Text
detectLedgerSchema connStr = do
    (hasCodd, hasCoddSchema) <- runDb connStr "ledger schema detection" (Session.statement () ledgerSchemaStmt)
    case (hasCodd, hasCoddSchema) of
        (True, False) -> pure "codd"
        (False, True) -> pure "codd_schema"
        (False, False) -> expectationFailure "codd ledger table was not found" >> pure "codd"
        (True, True) -> expectationFailure "both codd and codd_schema ledger tables exist" >> pure "codd"

ledgerSchemaStmt :: Statement () (Bool, Bool)
ledgerSchemaStmt =
    preparable
        "SELECT to_regclass('codd.sql_migrations') IS NOT NULL, to_regclass('codd_schema.sql_migrations') IS NOT NULL"
        E.noParams
        (D.singleRow ((,) <$> D.column (D.nonNullable D.bool) <*> D.column (D.nonNullable D.bool)))

ledgerNames :: Text -> Text -> IO [Text]
ledgerNames connStr "codd" = runDb connStr "codd ledger names" (Session.statement () ledgerNamesCoddStmt)
ledgerNames connStr "codd_schema" = runDb connStr "codd_schema ledger names" (Session.statement () ledgerNamesCoddSchemaStmt)
ledgerNames _ schema = expectationFailure ("unknown ledger schema " <> T.unpack schema) >> pure []

ledgerNamesCoddStmt :: Statement () [Text]
ledgerNamesCoddStmt =
    preparable
        "SELECT name::text FROM codd.sql_migrations ORDER BY name"
        E.noParams
        (D.rowList (D.column (D.nonNullable D.text)))

ledgerNamesCoddSchemaStmt :: Statement () [Text]
ledgerNamesCoddSchemaStmt =
    preparable
        "SELECT name::text FROM codd_schema.sql_migrations ORDER BY name"
        E.noParams
        (D.rowList (D.column (D.nonNullable D.text)))

ledgerRowCount :: Text -> Text -> IO Int32
ledgerRowCount connStr "codd" = runDb connStr "codd ledger row count" (Session.statement () ledgerCountCoddStmt)
ledgerRowCount connStr "codd_schema" = runDb connStr "codd_schema ledger row count" (Session.statement () ledgerCountCoddSchemaStmt)
ledgerRowCount _ schema = expectationFailure ("unknown ledger schema " <> T.unpack schema) >> pure 0

ledgerCountCoddStmt :: Statement () Int32
ledgerCountCoddStmt =
    preparable
        "SELECT count(*)::int FROM codd.sql_migrations"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.int4)))

ledgerCountCoddSchemaStmt :: Statement () Int32
ledgerCountCoddSchemaStmt =
    preparable
        "SELECT count(*)::int FROM codd_schema.sql_migrations"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.int4)))

data KeiroLedgerRemap = KeiroLedgerRemap
    { newLedgerName :: Text
    , oldLedgerName :: Text
    , oldLedgerTimestamp :: Text
    }
    deriving stock (Eq, Show)

keiroLedgerRemaps :: [KeiroLedgerRemap]
keiroLedgerRemaps =
    [ KeiroLedgerRemap "2026-05-17-13-58-15-keiro-bootstrap.sql" "2026-05-17-00-00-00-keiro-bootstrap.sql" "2026-05-17 00:00:00+00"
    , KeiroLedgerRemap "2026-05-19-12-55-02-keiro-outbox.sql" "2026-05-17-01-00-00-keiro-outbox.sql" "2026-05-17 01:00:00+00"
    , KeiroLedgerRemap "2026-05-19-13-05-23-keiro-inbox.sql" "2026-05-17-02-00-00-keiro-inbox.sql" "2026-05-17 02:00:00+00"
    , KeiroLedgerRemap "2026-06-03-05-14-28-keiro-timer-recovery.sql" "2026-05-17-03-00-00-keiro-timer-recovery.sql" "2026-05-17 03:00:00+00"
    , KeiroLedgerRemap "2026-06-03-16-10-05-keiro-workflow-steps.sql" "2026-06-03-00-00-00-keiro-workflow-steps.sql" "2026-06-03 00:00:00+00"
    , KeiroLedgerRemap "2026-06-03-18-19-41-keiro-awakeables.sql" "2026-06-03-01-00-00-keiro-awakeables.sql" "2026-06-03 01:00:00+00"
    , KeiroLedgerRemap "2026-06-03-19-49-23-keiro-workflow-children.sql" "2026-06-03-02-00-00-keiro-workflow-children.sql" "2026-06-03 02:00:00+00"
    , KeiroLedgerRemap "2026-06-04-02-12-28-keiro-workflow-generation.sql" "2026-06-05-00-00-00-keiro-workflow-generation.sql" "2026-06-05 00:00:00+00"
    , KeiroLedgerRemap "2026-06-04-03-53-34-keiro-subscription-shards.sql" "2026-06-05-01-00-00-keiro-subscription-shards.sql" "2026-06-05 01:00:00+00"
    , KeiroLedgerRemap "2026-06-15-15-07-25-keiro-workflows-instances.sql" "2026-06-11-00-00-04-keiro-workflows-instances.sql" "2026-06-11 00:00:04+00"
    , KeiroLedgerRemap "2026-06-15-17-53-48-keiro-workflow-gc-index.sql" "2026-06-15-22-10-00-keiro-workflow-gc-index.sql" "2026-06-15 22:10:00+00"
    , KeiroLedgerRemap "2026-06-15-18-01-33-keiro-workflows-wake-after.sql" "2026-06-15-22-20-00-keiro-workflows-wake-after.sql" "2026-06-15 22:20:00+00"
    , KeiroLedgerRemap "2026-07-02-00-15-48-keiro-outbox-claim-order-index.sql" "2026-07-02-00-12-00-keiro-outbox-claim-order-index.sql" "2026-07-02 00:12:00+00"
    , KeiroLedgerRemap "2026-07-02-00-58-54-keiro-inbox-drop-received-idx.sql" "2026-07-02-00-55-00-keiro-inbox-drop-received-idx.sql" "2026-07-02 00:55:00+00"
    ]

rewindKeiroLedgerToSentinelNames :: Text -> Text -> IO ()
rewindKeiroLedgerToSentinelNames connStr schema =
    runDb connStr "keiro ledger rewind to sentinel names" (Session.script script)
  where
    qname = schema <> ".sql_migrations"
    -- Kept in sync with ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql.
    script =
        T.unlines
            [ "UPDATE " <> qname <> " SET name = '" <> oldName <> "', migration_timestamp = '" <> oldTimestamp <> "' WHERE name = '" <> newName <> "';"
            | KeiroLedgerRemap newName oldName oldTimestamp <- keiroLedgerRemaps
            ]

moveKeiroTablesBackToKiroku :: Text -> IO ()
moveKeiroTablesBackToKiroku connStr =
    runDb connStr "move keiro tables back to kiroku schema" (Session.script script)
  where
    tableArray = T.intercalate ", " ["'" <> table <> "'" | table <- keiroTables]
    script =
        T.unlines
            [ "DO $$"
            , "DECLARE"
            , "  t text;"
            , "  tables text[] := ARRAY[" <> tableArray <> "];"
            , "BEGIN"
            , "  FOREACH t IN ARRAY tables LOOP"
            , "    IF to_regclass('keiro.' || t) IS NOT NULL THEN"
            , "      EXECUTE format('ALTER TABLE keiro.%I SET SCHEMA kiroku', t);"
            , "    END IF;"
            , "  END LOOP;"
            , "END"
            , "$$;"
            , "DROP SCHEMA IF EXISTS keiro;"
            ]

seedRemediationRows :: Text -> IO ()
seedRemediationRows connStr =
    runDb connStr "seed 0.1.0.0-layout keiro rows" (Session.script script)
  where
    script =
        """
        INSERT INTO kiroku.keiro_snapshots
          (stream_id, stream_version, state, state_codec_version, regfile_shape_hash)
        VALUES
          (4242, 7, '{"ok": true}'::jsonb, 3, 'shape-abc');

        INSERT INTO kiroku.keiro_timers
          (timer_id, process_manager_name, correlation_id, fire_at, payload, status)
        VALUES
          ('00000000-0000-4000-8000-000000000001', 'remediation-test', 'corr-1',
           '2026-07-06 00:00:00+00', '{"wake": true}'::jsonb, 'scheduled');
        """

assertSnapshotRowSurvived :: Text -> IO ()
assertSnapshotRowSurvived connStr = do
    present <- runDb connStr "snapshot survival query" (Session.statement () snapshotSurvivedStmt)
    present `shouldBe` True

snapshotSurvivedStmt :: Statement () Bool
snapshotSurvivedStmt =
    preparable
        """
        SELECT EXISTS (
          SELECT 1
          FROM keiro.keiro_snapshots
          WHERE stream_id = 4242
            AND stream_version = 7
            AND state = '{"ok": true}'::jsonb
            AND state_codec_version = 3
            AND regfile_shape_hash = 'shape-abc'
        )
        """
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

assertTimerRowSurvived :: Text -> IO ()
assertTimerRowSurvived connStr = do
    present <- runDb connStr "timer survival query" (Session.statement () timerSurvivedStmt)
    present `shouldBe` True

timerSurvivedStmt :: Statement () Bool
timerSurvivedStmt =
    preparable
        """
        SELECT EXISTS (
          SELECT 1
          FROM keiro.keiro_timers
          WHERE timer_id = '00000000-0000-4000-8000-000000000001'
            AND process_manager_name = 'remediation-test'
            AND correlation_id = 'corr-1'
            AND payload = '{"wake": true}'::jsonb
            AND status = 'scheduled'
        )
        """
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

assertTablesExist :: Text -> Text -> [Text] -> IO ()
assertTablesExist connStr schema tables = do
    actualTables <- runDb connStr "table verification query" (Session.statement schema schemaTablesStmt)
    let missing = filter (`notElem` actualTables) tables
    missing `shouldBe` []

assertTablesAbsent :: Text -> Text -> [Text] -> IO ()
assertTablesAbsent connStr schema tables = do
    actualTables <- runDb connStr "table verification query" (Session.statement schema schemaTablesStmt)
    let present = filter (`elem` actualTables) tables
    present `shouldBe` []

assertColumnExists :: Text -> Text -> Text -> Text -> IO ()
assertColumnExists connStr schema table column = do
    present <- runDb connStr "column verification query" (Session.statement (schema, table, column) columnExistsStmt)
    present `shouldBe` True

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
