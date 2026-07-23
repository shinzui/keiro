{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (finally)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (findIndex, sort, (\\))
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
import Database.PostgreSQL.Migrate.Internal qualified as Migrate.Internal
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
import Keiro.Migrations qualified as Keiro
import Keiro.Migrations.History.Codd
import Keiro.Migrations.SchemaCheck
import Kiroku.Store.Migrations qualified as Kiroku
import Kiroku.Store.Migrations.History.Codd qualified as Kiroku.Codd
import Lint
import Numeric qualified
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeExtension, (</>))
import Test.Hspec

main :: IO ()
main = hspec $ do
    describe "native Keiro migration definition" $ do
        it "tracks twenty native files in manifest order" $ do
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

        it "builds component keiro with dependency kiroku and twenty migrations" $ do
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
                        length keiroEntries `shouldBe` 20
                actual -> expectationFailure ("unexpected plan description: " <> show actual)
            validateHistoryMappingTargets plan frameworkCoddHistoryMappings `shouldBe` Right ()

        it "rejects missing and reversed Kiroku dependencies" $ do
            kiroku <- requireRight Kiroku.kirokuMigrations
            keiro <- requireRight keiroMigrations
            migrationPlan (keiro :| []) `shouldSatisfy` isLeft
            frameworkMigrationPlan keiro kiroku `shouldSatisfy` isLeft

    describe "native checksum lockfile" $ do
        it "matches the manifest, directory membership, and every payload byte" $ do
            directory <- findMigrationsDirectory
            lockPath <- findNativeLockfile
            lockEntries <- parseLockfile <$> Text.IO.readFile lockPath
            manifestNames <-
                fmap Text.unpack . Text.lines
                    <$> Text.IO.readFile (directory </> "manifest")
            directoryNames <-
                sort
                    . filter ((== ".sql") . takeExtension)
                    <$> listDirectory directory
            let lockNames = fst <$> lockEntries
            assertFileList
                "migrations.native.lock entries differ from migrations/manifest"
                manifestNames
                lockNames
            assertFileList
                "migrations directory entries differ from migrations/manifest"
                (sort manifestNames)
                directoryNames
            forM_ lockEntries $ \(filename, expectedChecksum) -> do
                actualChecksum <-
                    checksumText
                        <$> ByteString.readFile (directory </> filename)
                unless (actualChecksum == expectedChecksum) $
                    expectationFailure
                        ( "migrations.native.lock checksum mismatch for "
                            <> filename
                            <> "\nexpected: "
                            <> Text.unpack expectedChecksum
                            <> "\nactual:   "
                            <> Text.unpack actualChecksum
                        )

    describe "migration body lint" $ do
        let config = LintConfig{requiredQualifier = "keiro.", exemptFiles = []}

        it "flags an unqualified DDL target" $ do
            let violations =
                    lintViolations
                        config
                        [("9999-fixture.sql", "CREATE TABLE widgets (id int);")]
            violations `shouldSatisfy` \case
                [violation] -> "9999-fixture.sql" `Text.isInfixOf` violation
                _ -> False

        it "flags a search_path mention" $ do
            lintViolations
                config
                [("9999-fixture.sql", "SET search_path TO keiro;")]
                `shouldSatisfy` (not . null)

        it "ignores comment-only mentions" $ do
            lintViolations
                config
                [("9999-fixture.sql", "-- Never set search_path in a migration.\nSELECT 1;")]
                `shouldBe` []

        it "passes all 20 embedded native bodies" $ do
            lintViolations config (toList embeddedMigrationEntries) `shouldBe` []

    describe "startup handshake" $ do
        it "reports the full plan on a fresh database" $ do
            plan <- requirePlan
            withKeiroPg $ \database -> do
                handshake <-
                    missingMigrations
                        defaultRunOptions
                        (connectionProviderFromSettings (Pg.connectionSettings database))
                        plan
                        >>= requireRight
                Keiro.pendingMigrations handshake `shouldBe` planMigrationIds plan
                length (Keiro.pendingMigrations handshake) `shouldBe` 28
                Keiro.ledgerIssues handshake `shouldBe` []
                handshakePassed handshake `shouldBe` False

        it "passes on a fully migrated database" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                handshake <-
                    missingMigrations defaultRunOptions (providerFor connection) plan
                        >>= requireRight
                Keiro.pendingMigrations handshake `shouldBe` []
                Keiro.ledgerIssues handshake `shouldBe` []
                handshakePassed handshake `shouldBe` True
            either (expectationFailure . show) pure result

        it "reports the Keiro tail after applying only Kiroku" $ do
            plan <- requirePlan
            withKeiroPg $ \database -> do
                kiroku <- requireRight Kiroku.kirokuMigrations
                kirokuOnly <- requireRight (migrationPlan (kiroku :| []))
                let settings = Pg.connectionSettings database
                    provider = connectionProviderFromSettings settings
                _ <- runMigrationPlan defaultRunOptions settings kirokuOnly >>= requireRight
                handshake <-
                    missingMigrations defaultRunOptions provider plan >>= requireRight
                Keiro.pendingMigrations handshake `shouldBe` drop 8 (planMigrationIds plan)
                length (Keiro.pendingMigrations handshake) `shouldBe` 20
                Keiro.ledgerIssues handshake `shouldBe` []
                handshakePassed handshake `shouldBe` False

    describe "native expected schema" $ do
        it "classifies missing, unexpected, and changed objects" $ do
            let expected =
                    Text.unlines
                        [ "column\twidgets.id\tinteger not null"
                        , "index\twidgets_id_idx\tCREATE INDEX widgets_id_idx ON keiro.widgets USING btree (id)"
                        ]
                actual =
                    Text.unlines
                        [ "column\twidgets.id\tbigint not null"
                        , "table\twidgets\tkind=r"
                        ]
            compareSchemaSnapshot expected actual
                `shouldMatchList` [ ChangedObject
                                        { driftKey = "column\twidgets.id"
                                        , expectedDefinition = "integer not null"
                                        , actualDefinition = "bigint not null"
                                        }
                                  , MissingObject
                                        "index\twidgets_id_idx\tCREATE INDEX widgets_id_idx ON keiro.widgets USING btree (id)"
                                  , UnexpectedObject "table\twidgets\tkind=r"
                                  ]

        it "checked-in snapshot matches what the migrations build" $ do
            plan <- requirePlan
            snapshotPath <- findNativeExpectedSchema
            regenerate <- maybe False (const True) <$> lookupEnv "KEIRO_REGENERATE_EXPECTED_SCHEMA"
            result <- withMigratedDatabase plan $ \connection -> do
                actual <- useSession connection (snapshotSchema "keiro")
                if regenerate
                    then do
                        Text.IO.writeFile snapshotPath actual
                        putStrLn ("regenerated " <> snapshotPath)
                    else do
                        expected <- Text.IO.readFile snapshotPath
                        unless (expected == actual) $
                            expectationFailure (snapshotMismatch snapshotPath expected actual)
            either (expectationFailure . show) pure result

        it "detects named drift after a hand-altered database" $ do
            plan <- requirePlan
            withKeiroPg $ \database -> do
                let settings = Pg.connectionSettings database
                _ <- runMigrationPlan defaultRunOptions settings plan >>= requireRight
                clean <- verifyExpectedSchema settings >>= requireRight
                clean `shouldBe` []
                withConnection settings $ \connection ->
                    useSession
                        connection
                        ( Session.script
                            """
                            DROP INDEX keiro.keiro_outbox_pending_idx;
                            ALTER TABLE keiro.keiro_outbox
                              ALTER COLUMN correlation_id TYPE character varying(64)
                              USING correlation_id::text;
                            """
                        )
                drifts <- verifyExpectedSchema settings >>= requireRight
                let rendered = renderSchemaDrift <$> drifts
                rendered
                    `shouldSatisfy` any
                        (Text.isInfixOf "keiro_outbox_pending_idx")
                rendered
                    `shouldSatisfy` any
                        (Text.isInfixOf "keiro_outbox.correlation_id")

    describe "fresh native databases" $ do
        it "applies Kiroku then Keiro, verifies strictly, and is repeatable" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                assertSchema connection
                let provider = providerFor connection
                rerun <- runMigrationPlanWith defaultRunOptions provider plan >>= requireRight
                reportOutcomes rerun `shouldBe` replicate 28 AlreadyApplied
                verified <- verifyMigrationPlanWith defaultRunOptions provider plan >>= requireRight
                case verified of
                    VerificationReport verificationIssues applied pending unknown -> do
                        verificationIssues `shouldBe` []
                        length applied `shouldBe` 28
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
                    `shouldBe` sort [replicate 28 AppliedNow, replicate 28 AlreadyApplied]

    describe "codd-ledger preflight" $ do
        it "blocks a current codd ledger before native history exists" $
            assertBlockedCoddPreflight "codd"

        it "blocks a legacy codd_schema ledger before native history exists" $
            assertBlockedCoddPreflight "codd_schema"

        it "is clear on a fresh database" $
            withKeiroPg $ \database -> do
                preflight <-
                    preflightFreshLedgerOverCodd (Pg.connectionSettings database)
                        >>= requireRight
                preflight `shouldBe` CoddPreflightClear

        it "is clear after codd history has been imported" $ do
            plan <- requirePlan
            withKeiroPg $ \database -> do
                let settings = Pg.connectionSettings database
                    provider = connectionProviderFromSettings settings
                withConnection settings $ \connection -> do
                    applyLegacyPayloads connection
                    installCoddLedger connection "codd" False False
                config <-
                    requireRight
                        (frameworkCoddSourceConfig provider True "preflight fixture" Confirmed)
                _ <-
                    importCoddHistory
                        defaultImportOptions
                        config
                        provider
                        plan
                        frameworkCoddHistoryMappings
                        >>= requireRight
                preflight <- preflightFreshLedgerOverCodd settings >>= requireRight
                preflight `shouldBe` CoddPreflightClear

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

assertBlockedCoddPreflight :: Text -> Expectation
assertBlockedCoddPreflight sourceSchema =
    withKeiroPg $ \database -> do
        let settings = Pg.connectionSettings database
        withConnection settings $ \connection -> do
            applyLegacyPayloads connection
            installCoddLedger connection sourceSchema False False
        preflight <- preflightFreshLedgerOverCodd settings >>= requireRight
        let expectedTable = sourceSchema <> ".sql_migrations"
        preflight
            `shouldBe` CoddPreflightBlocked
                { coddLedgerTable = expectedTable
                , nativeLedgerAbsent = True
                }
        renderCoddPreflight preflight `shouldSatisfy` Text.isInfixOf expectedTable

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
        keiroDeadLettersId <- requireRight (migrationId "keiro" "0018")
        keiroStateShapeId <- requireRight (migrationId "keiro" "0019-keiro-snapshots-state-shape-hash")
        keiroFailureReasonId <- requireRight (migrationId "keiro" "0020-keiro-workflow-children-failure-reason")
        verifiedBeforeCanaries <- verifyMigrationPlan defaultRunOptions settings plan >>= requireRight
        case verifiedBeforeCanaries of
            VerificationReport verificationIssues _ _ _ ->
                verificationIssues
                    `shouldBe` [ PendingMigration kirokuCanaryId
                               , PendingMigration keiroCanaryId
                               , PendingMigration keiroDeadLettersId
                               , PendingMigration keiroStateShapeId
                               , PendingMigration keiroFailureReasonId
                               ]
        up <- runMigrationPlan defaultRunOptions settings plan >>= requireRight
        reportOutcomes up
            `shouldBe` replicate 7 AlreadyApplied
                <> [AppliedNow]
                <> replicate 16 AlreadyApplied
                <> [AppliedNow, AppliedNow, AppliedNow, AppliedNow]
        verifiedAfterCanaries <- verifyMigrationPlan defaultRunOptions settings plan >>= requireRight
        case verifiedAfterCanaries of
            VerificationReport verificationIssues _ _ _ -> verificationIssues `shouldBe` []
        rerun <- runMigrationPlan defaultRunOptions settings plan >>= requireRight
        reportOutcomes rerun `shouldBe` replicate 28 AlreadyApplied
        second <-
            importCoddHistory defaultImportOptions config provider plan frameworkCoddHistoryMappings
                >>= requireRight
        importOutcomes second `shouldBe` replicate 23 AlreadyImported
        withConnection settings $ \connection -> do
            assertSchema connection
            sourceRows <- useSession connection (Session.statement () (sourceRowCountStatement sourceSchema))
            sourceRows `shouldBe` 23
            facts <- useSession connection (Session.statement () importFactsStatement)
            facts `shouldBe` (28, 23, True)

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
    , "0018.sql"
    , "0019-keiro-snapshots-state-shape-hash.sql"
    , "0020-keiro-workflow-children-failure-reason.sql"
    ]

findMigrationsDirectory :: IO FilePath
findMigrationsDirectory =
    findDirectory ["keiro-migrations/migrations", "migrations"]

findLockfile :: IO FilePath
findLockfile =
    findFile ["keiro-migrations/migrations.lock", "migrations.lock"]

findNativeLockfile :: IO FilePath
findNativeLockfile =
    findFile
        [ "keiro-migrations/migrations.native.lock"
        , "migrations.native.lock"
        ]

findNativeExpectedSchema :: IO FilePath
findNativeExpectedSchema =
    findFile
        [ "keiro-migrations/expected-schema/native/keiro-v18.txt"
        , "expected-schema/native/keiro-v18.txt"
        ]

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

assertFileList :: String -> [FilePath] -> [FilePath] -> Expectation
assertFileList message expected actual =
    unless (actual == expected) $
        expectationFailure
            ( message
                <> "\nmissing:    "
                <> show (expected \\ actual)
                <> "\nunexpected: "
                <> show (actual \\ expected)
                <> orderDifference
            )
  where
    orderDifference
        | sort expected == sort actual =
            "\norder differs\nexpected: "
                <> show expected
                <> "\nactual:   "
                <> show actual
        | otherwise = ""

snapshotMismatch :: FilePath -> Text -> Text -> String
snapshotMismatch path expected actual =
    "checked-in native schema snapshot differs at "
        <> firstDifference
        <> "\nRegenerate intentionally with "
        <> "KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test "
        <> "--test-options='--match \"checked-in snapshot\"' and review "
        <> path
  where
    expectedLines = Text.lines expected
    actualLines = Text.lines actual
    lineCount = max (length expectedLines) (length actualLines)
    paddedExpected = take lineCount (expectedLines <> repeat "<end of snapshot>")
    paddedActual = take lineCount (actualLines <> repeat "<end of snapshot>")
    firstDifference =
        case findIndex (uncurry (/=)) (zip paddedExpected paddedActual) of
            Nothing -> "an unknown position"
            Just index ->
                "line "
                    <> show (index + 1)
                    <> "\nexpected: "
                    <> Text.unpack (paddedExpected !! index)
                    <> "\nactual:   "
                    <> Text.unpack (paddedActual !! index)

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

planMigrationIds :: MigrationPlan -> [MigrationId]
planMigrationIds plan =
    [ identifier
    | ComponentDescription{migrations} <- toList components
    , Migrate.Internal.MigrationDescription identifier _ _ _ _ <- toList migrations
    ]
  where
    PlanDescription components = planDescription plan

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
