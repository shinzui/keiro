{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (finally)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Int (Int32, Int64)
import Data.List (findIndex, sort, (\\))
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.Codd
import Database.PostgreSQL.Migrate.Internal
  ( ComponentDescription (..),
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
    it "tracks thirty-one native files in manifest order" $ do
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

    it "builds component keiro with dependency kiroku and thirty-one migrations" $ do
      plan <- requirePlan
      let PlanDescription components = planDescription plan
      case toList components of
        [ ComponentDescription {name = kirokuName, dependencies = kirokuDependencies, migrations = kirokuEntries},
          ComponentDescription {name = keiroName, dependencies = keiroDependencies, migrations = keiroEntries}
          ] -> do
            componentNameText kirokuName `shouldBe` "kiroku"
            kirokuDependencies `shouldBe` mempty
            length kirokuEntries `shouldBe` 11
            componentNameText keiroName `shouldBe` "keiro"
            dependencyName <- requireRight (componentName "kiroku")
            keiroDependencies `shouldBe` Set.singleton dependencyName
            length keiroEntries `shouldBe` 31
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
    let config =
          LintConfig
            { requiredQualifier = "keiro.",
              additionalQualifiers = ["keiro_read."],
              exemptFiles = []
            }

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

    it "accepts a fixed pg_catalog search path on a security-definer function" $ do
      lintViolations
        config
        [ ( "9999-fixture.sql",
            "CREATE FUNCTION keiro_read.safe_v1() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS 'SELECT';"
          )
        ]
        `shouldBe` []

    it "accepts a versioned view in the public read schema" $ do
      lintViolations
        config
        [("9999-fixture.sql", "CREATE VIEW keiro_read.status_v1 AS SELECT 1;")]
        `shouldBe` []

    it "ignores comment-only mentions" $ do
      lintViolations
        config
        [("9999-fixture.sql", "-- Never set search_path in a migration.\nSELECT 1;")]
        `shouldBe` []

    it "passes all 31 embedded native bodies" $ do
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
        length (Keiro.pendingMigrations handshake) `shouldBe` 42
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
        Keiro.pendingMigrations handshake `shouldBe` drop 11 (planMigrationIds plan)
        length (Keiro.pendingMigrations handshake) `shouldBe` 31
        Keiro.ledgerIssues handshake `shouldBe` []
        handshakePassed handshake `shouldBe` False

  describe "native expected schema" $ do
    it "classifies missing, unexpected, and changed objects" $ do
      let expected =
            Text.unlines
              [ "column\twidgets.id\tinteger not null",
                "index\twidgets_id_idx\tCREATE INDEX widgets_id_idx ON keiro.widgets USING btree (id)"
              ]
          actual =
            Text.unlines
              [ "column\twidgets.id\tbigint not null",
                "table\twidgets\tkind=r"
              ]
      compareSchemaSnapshot expected actual
        `shouldMatchList` [ ChangedObject
                              { driftKey = "column\twidgets.id",
                                expectedDefinition = "integer not null",
                                actualDefinition = "bigint not null"
                              },
                            MissingObject
                              "index\twidgets_id_idx\tCREATE INDEX widgets_id_idx ON keiro.widgets USING btree (id)",
                            UnexpectedObject "table\twidgets\tkind=r"
                          ]

    it "checked-in snapshot matches what the migrations build" $ do
      plan <- requirePlan
      snapshotPath <- findNativeExpectedSchema
      regenerate <- maybe False (const True) <$> lookupEnv "KEIRO_REGENERATE_EXPECTED_SCHEMA"
      result <- withMigratedDatabase plan $ \connection -> do
        privateSchema <- useSession connection (snapshotSchema "keiro")
        publicSchema <- useSession connection (snapshotSchema "keiro_read")
        let actual = privateSchema <> publicSchema
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
                DROP VIEW keiro_read.projection_group_status_v1;
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
        rendered
          `shouldSatisfy` any
            (Text.isInfixOf "keiro_read.projection_group_status_v1")

  describe "fresh native databases" $ do
    it "applies Kiroku then Keiro, verifies strictly, and is repeatable" $ do
      plan <- requirePlan
      result <- withMigratedDatabase plan $ \connection -> do
        assertSchema connection
        let provider = providerFor connection
        rerun <- runMigrationPlanWith defaultRunOptions provider plan >>= requireRight
        reportOutcomes rerun `shouldBe` replicate 42 AlreadyApplied
        verified <- verifyMigrationPlanWith defaultRunOptions provider plan >>= requireRight
        case verified of
          VerificationReport verificationIssues applied pending unknown -> do
            verificationIssues `shouldBe` []
            length applied `shouldBe` 42
            pending `shouldBe` []
            unknown `shouldBe` []
      either (expectationFailure . show) pure result

    it "publishes the frozen status shape through an isolated reader grant" $ do
      plan <- requirePlan
      result <- withMigratedDatabase plan $ \connection -> do
        useSession connection (Session.script projectionStatusFixtureSql)
        columns <-
          useSession connection (Session.statement () projectionStatusColumnsStatement)
        columns
          `shouldBe` [ ("group_id", "text"),
                       ("lifecycle_phase", "text"),
                       ("reads_allowed", "boolean"),
                       ("writes_allowed", "boolean"),
                       ("serving_revision_id", "text"),
                       ("serving_epoch", "bigint"),
                       ("serving_position_basis", "text"),
                       ("serving_applied_position", "bigint"),
                       ("active_run_id", "text"),
                       ("candidate_revision_id", "text"),
                       ("candidate_rebuild_position", "bigint"),
                       ("candidate_rebuild_head", "bigint"),
                       ("query_models", "text[]"),
                       ("rebuild_started_at", "timestamp with time zone"),
                       ("last_promoted_at", "timestamp with time zone"),
                       ("failed_at", "timestamp with time zone"),
                       ("failure_code", "text"),
                       ("failure_detail", "text")
                     ]
        contractHealthy <-
          useSession connection (Session.statement () projectionStatusContractStatement)
        contractHealthy `shouldBe` True
        withProjectionReaderRole connection $ do
          readerHealthy <-
            useSession connection (Session.statement () projectionReaderFactsStatement)
          readerHealthy `shouldBe` True
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
          `shouldBe` sort [replicate 42 AppliedNow, replicate 42 AlreadyApplied]

    it "upgrades singleton read-model rows into deterministic rebuild groups" $ do
      fullPlan <- requirePlan
      kiroku <- requireRight Kiroku.kirokuMigrations
      priorKeiro <-
        requireRight
          ( migrationComponentFromEmbeddedSql
              "keiro"
              (Set.singleton "kiroku")
              (NonEmpty.fromList (take 21 (toList embeddedMigrationEntries)))
          )
      priorPlan <- requireRight (frameworkMigrationPlan kiroku priorKeiro)
      withKeiroPg $ \database -> do
        let settings = Pg.connectionSettings database
        _ <- runMigrationPlan defaultRunOptions settings priorPlan >>= requireRight
        withConnection settings $ \connection ->
          useSession connection (Session.script legacyReadModelFixtureSql)
        report <- runMigrationPlan defaultRunOptions settings fullPlan >>= requireRight
        Prelude.drop 32 (reportOutcomes report) `shouldBe` replicate 10 AppliedNow
        withConnection settings $ \connection -> do
          rows <- useSession connection (Session.statement () legacyGroupUpgradeStatement)
          rows
            `shouldBe` [ ("legacy-abandoned", 9, "shape-abandoned", "abandoned", "$legacy-read-model:legacy-abandoned", "failed", Just "$legacy-read-model:legacy-abandoned", Just "abandoned"),
                         ("legacy-live", 7, "shape-live", "live", "$legacy-read-model:legacy-live", "live", Nothing, Nothing),
                         ("legacy-rebuilding", 8, "shape-rebuilding", "rebuilding", "$legacy-read-model:legacy-rebuilding", "rebuilding", Just "$legacy-read-model:legacy-rebuilding", Nothing)
                       ]

    it "0024 stamps in-flight rebuild runs with the pre-canonical sentinel" $ do
      fullPlan <- requirePlan
      kiroku <- requireRight Kiroku.kirokuMigrations
      priorKeiro <-
        requireRight
          ( migrationComponentFromEmbeddedSql
              "keiro"
              (Set.singleton "kiroku")
              (NonEmpty.fromList (take 23 (toList embeddedMigrationEntries)))
          )
      priorPlan <- requireRight (frameworkMigrationPlan kiroku priorKeiro)
      withKeiroPg $ \database -> do
        let settings = Pg.connectionSettings database
        _ <- runMigrationPlan defaultRunOptions settings priorPlan >>= requireRight
        withConnection settings $ \connection ->
          useSession connection (Session.script preCanonicalRebuildFixtureSql)
        report <- runMigrationPlan defaultRunOptions settings fullPlan >>= requireRight
        Prelude.drop 34 (reportOutcomes report) `shouldBe` replicate 8 AppliedNow
        withConnection settings $ \connection -> do
          rows <- useSession connection (Session.statement () preCanonicalRebuildShapeStatement)
          rows
            `shouldBe` [ ("upgrade-failed", Text.replicate 64 "b", "upgrade-run-failed", "$pre-canonical"),
                         ("upgrade-rebuilding", Text.replicate 64 "a", "upgrade-run-live", "$pre-canonical")
                       ]

    it "0026 gives pre-existing groups explicit fail-safe cursor authority" $ do
      fullPlan <- requirePlan
      kiroku <- requireRight Kiroku.kirokuMigrations
      priorKeiro <-
        requireRight
          ( migrationComponentFromEmbeddedSql
              "keiro"
              (Set.singleton "kiroku")
              (NonEmpty.fromList (take 25 (toList embeddedMigrationEntries)))
          )
      priorPlan <- requireRight (frameworkMigrationPlan kiroku priorKeiro)
      withKeiroPg $ \database -> do
        let settings = Pg.connectionSettings database
        _ <- runMigrationPlan defaultRunOptions settings priorPlan >>= requireRight
        withConnection settings $ \connection ->
          useSession connection (Session.script preStatusContractFixtureSql)
        report <- runMigrationPlan defaultRunOptions settings fullPlan >>= requireRight
        Prelude.drop 36 (reportOutcomes report) `shouldBe` replicate 6 AppliedNow
        withConnection settings $ \connection -> do
          facts <- useSession connection (Session.statement () preStatusContractFactsStatement)
          facts `shouldBe` ("unmanaged", 0, "unmanaged", True, True)

    it "0030 upgrades the guard in place with post-lock epoch fencing" $ do
      fullPlan <- requirePlan
      kiroku <- requireRight Kiroku.kirokuMigrations
      priorKeiro <-
        requireRight
          ( migrationComponentFromEmbeddedSql
              "keiro"
              (Set.singleton "kiroku")
              (NonEmpty.fromList (take 29 (toList embeddedMigrationEntries)))
          )
      priorPlan <- requireRight (frameworkMigrationPlan kiroku priorKeiro)
      withKeiroPg $ \database -> do
        let settings = Pg.connectionSettings database
        _ <- runMigrationPlan defaultRunOptions settings priorPlan >>= requireRight
        beforeOid <-
          withConnection settings $ \connection ->
            useSession connection (Session.statement () guardFunctionOidStatement)
        report <- runMigrationPlan defaultRunOptions settings fullPlan >>= requireRight
        Prelude.drop 40 (reportOutcomes report) `shouldBe` replicate 2 AppliedNow
        withConnection settings $ \connection -> do
          (afterOid, epochFenced, publicRevoked) <-
            useSession connection (Session.statement () upgradedGuardFactsStatement)
          afterOid `shouldBe` beforeOid
          epochFenced `shouldBe` True
          publicRevoked `shouldBe` True

    it "0031 adds bounded terminal rejection audit constraints to existing outbox rows" $ do
      fullPlan <- requirePlan
      kiroku <- requireRight Kiroku.kirokuMigrations
      priorKeiro <-
        requireRight
          ( migrationComponentFromEmbeddedSql
              "keiro"
              (Set.singleton "kiroku")
              (NonEmpty.fromList (take 30 (toList embeddedMigrationEntries)))
          )
      priorPlan <- requireRight (frameworkMigrationPlan kiroku priorKeiro)
      withKeiroPg $ \database -> do
        let settings = Pg.connectionSettings database
        _ <- runMigrationPlan defaultRunOptions settings priorPlan >>= requireRight
        withConnection settings $ \connection ->
          useSession connection (Session.script preRejectionOutboxFixtureSql)
        report <- runMigrationPlan defaultRunOptions settings fullPlan >>= requireRight
        Prelude.drop 41 (reportOutcomes report) `shouldBe` [AppliedNow]
        withConnection settings $ \connection -> do
          useSession connection (Session.script validRejectionAuditSql)
          missingAudit <- Connection.use connection (Session.script missingRejectionAuditSql)
          missingAudit `shouldSatisfy` isLeft
          invalidCode <- Connection.use connection (Session.script invalidRejectionCodeSql)
          invalidCode `shouldSatisfy` isLeft
          oversizedDetail <- Connection.use connection (Session.script oversizedRejectionDetailSql)
          oversizedDetail `shouldSatisfy` isLeft
          auditOnSent <- Connection.use connection (Session.script rejectionAuditOnSentSql)
          auditOnSent `shouldSatisfy` isLeft

    it "enforces replay source, adapter, and verification membership constraints" $ do
      plan <- requirePlan
      result <- withMigratedDatabase plan $ \connection -> do
        useSession connection (Session.script replayProgressFixtureSql)
        invalidScope <-
          Connection.use
            connection
            ( Session.script
                "INSERT INTO keiro.keiro_projection_rebuild_sources (run_id, source_id, source_scope, target_position) VALUES ('constraint-run', 'bad-scope', 'category', 0)"
            )
        invalidScope `shouldSatisfy` isLeft
        missingSource <-
          Connection.use
            connection
            ( Session.script
                "INSERT INTO keiro.keiro_projection_rebuild_adapters (run_id, source_id, projection_id, adapter_order) VALUES ('constraint-run', 'missing', 'projection', 0)"
            )
        missingSource `shouldSatisfy` isLeft
        duplicateVerification <-
          Connection.use
            connection
            ( Session.script
                "INSERT INTO keiro.keiro_projection_rebuild_verifications (run_id, verification_id, verification_version) VALUES ('constraint-run', 'verify', 'v2')"
            )
        duplicateVerification `shouldSatisfy` isLeft
      either (expectationFailure . show) pure result

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
          Left CoddPartialMigration {} -> True
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
          Left CoddStrictSourceHasUnselected {} -> True
          _ -> False

  describe "poisoned-ledger recovery" $ do
    it "up before import poisons the ledger and the documented recovery restores the cutover" $ do
      plan <- requirePlan
      withKeiroPg $ \database -> do
        let settings = Pg.connectionSettings database
            provider = connectionProviderFromSettings settings
        withConnection settings $ \connection -> do
          applyLegacyPayloads connection
          installCoddLedger connection "codd" False False

        incident <- runMigrationPlan defaultRunOptions settings plan
        incident `shouldSatisfy` isLeft
        assertPoisonedLedger settings

        config <-
          requireRight
            (frameworkCoddSourceConfig provider True "poisoned-ledger recovery fixture" Confirmed)
        blockedImport <-
          importCoddHistory
            defaultImportOptions
            config
            provider
            plan
            frameworkCoddHistoryMappings
        blockedImport `shouldSatisfy` \case
          Left (CoddTargetImportFailed HistoryImportConflict {}) -> True
          _ -> False

        assertPoisonedLedger settings
        withConnection settings $ \connection ->
          useSession connection (Session.script "DROP SCHEMA pgmigrate CASCADE;")

        recoveredImport <-
          importCoddHistory
            defaultImportOptions
            config
            provider
            plan
            frameworkCoddHistoryMappings
            >>= requireRight
        importOutcomes recoveredImport `shouldBe` replicate 23 Imported

        expectedPending <- postCoddImportPendingIssues
        verifiedBeforeUp <-
          verifyMigrationPlan defaultRunOptions settings plan >>= requireRight
        case verifiedBeforeUp of
          VerificationReport verificationIssues _ _ _ ->
            verificationIssues `shouldBe` expectedPending

        up <- runMigrationPlan defaultRunOptions settings plan >>= requireRight
        reportOutcomes up
          `shouldBe` replicate 7 AlreadyApplied
            <> replicate 4 AppliedNow
            <> replicate 16 AlreadyApplied
            <> replicate 15 AppliedNow

        verifiedAfterUp <-
          verifyMigrationPlan defaultRunOptions settings plan >>= requireRight
        case verifiedAfterUp of
          VerificationReport verificationIssues _ _ _ ->
            verificationIssues `shouldBe` []
        withConnection settings assertSchema

legacyReadModelFixtureSql :: Text
legacyReadModelFixtureSql =
  """
  INSERT INTO keiro.keiro_read_models
    (name, version, shape_hash, last_built_at, status, updated_at)
  VALUES
    ('legacy-live', 7, 'shape-live', '2026-01-01 00:00:00+00', 'live', '2026-01-01 00:00:00+00'),
    ('legacy-rebuilding', 8, 'shape-rebuilding', '2026-01-01 00:00:00+00', 'rebuilding', '2026-01-02 00:00:00+00'),
    ('legacy-abandoned', 9, 'shape-abandoned', '2026-01-01 00:00:00+00', 'abandoned', '2026-01-03 00:00:00+00');
  """

projectionStatusFixtureSql :: Text
projectionStatusFixtureSql =
  """
  INSERT INTO keiro.keiro_projection_rebuild_groups
    (group_id, slice_fingerprint, status, active_run_id,
     reads_allowed, writes_allowed, started_at)
  VALUES
    ('status-contract-group', 'slice-v1:status-contract', 'rebuilding',
     'status-contract-run', false, false, '2026-08-13 12:00:00+00');

  INSERT INTO keiro.keiro_projection_group_cursors
    (group_id, position_basis, subscription_names)
  VALUES ('status-contract-group', 'append', ARRAY[]::TEXT[]);

  INSERT INTO keiro.keiro_projection_rebuild_runs
    (run_id, group_id, catalog_fingerprint, group_slice_fingerprint,
     contract_fingerprint, runner_format, captured_head, page_size)
  VALUES
    ('status-contract-run', 'status-contract-group', 'catalog-status-contract',
     'slice-v1:status-contract', 'contract-v2:status-contract',
     'keiro/projection-replay/v2', 10, 100);

  INSERT INTO keiro.keiro_projection_rebuild_sources
    (run_id, source_id, source_scope, category, cursor_position, target_position)
  VALUES
    ('status-contract-run', 'orders', 'category', 'orders', 7, 10),
    ('status-contract-run', 'customers', 'category', 'customers', 4, 10);

  INSERT INTO keiro.keiro_read_models
    (name, version, shape_hash, status, rebuild_group_id)
  VALUES
    ('orders.summary', 1, 'shape-summary', 'rebuilding', 'status-contract-group'),
    ('orders.by-customer', 1, 'shape-by-customer', 'rebuilding', 'status-contract-group');
  """

projectionStatusColumnsStatement :: Statement () [(Text, Text)]
projectionStatusColumnsStatement =
  Statement.preparable
    """
    SELECT attribute.attname::TEXT, format_type(attribute.atttypid, attribute.atttypmod)
    FROM pg_catalog.pg_attribute AS attribute
    JOIN pg_catalog.pg_class AS relation
      ON relation.oid = attribute.attrelid
    JOIN pg_catalog.pg_namespace AS namespace
      ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'keiro_read'
      AND relation.relname = 'projection_group_status_v1'
      AND attribute.attnum > 0
      AND NOT attribute.attisdropped
    ORDER BY attribute.attnum
    """
    Encoders.noParams
    ( Decoders.rowList
        ( (,)
            <$> column Decoders.text
            <*> column Decoders.text
        )
    )
  where
    column = Decoders.column . Decoders.nonNullable

projectionStatusContractStatement :: Statement () Bool
projectionStatusContractStatement =
  Statement.preparable
    """
    SELECT
      lifecycle_phase = 'rebuilding'
      AND NOT reads_allowed
      AND NOT writes_allowed
      AND serving_revision_id IS NULL
      AND serving_epoch = 0
      AND serving_position_basis = 'append'
      AND serving_applied_position IS NULL
      AND active_run_id = 'status-contract-run'
      AND candidate_revision_id IS NULL
      AND candidate_rebuild_position = 4
      AND candidate_rebuild_head = 10
      AND query_models = ARRAY['orders.by-customer', 'orders.summary']::TEXT[]
      AND rebuild_started_at IS NOT NULL
      AND last_promoted_at IS NULL
      AND failed_at IS NULL
      AND failure_code IS NULL
      AND failure_detail IS NULL
    FROM keiro_read.projection_group_status_v1
    WHERE group_id = 'status-contract-group'
    """
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

projectionReaderFactsStatement :: Statement () Bool
projectionReaderFactsStatement =
  Statement.preparable
    """
    SELECT
      has_schema_privilege(current_user, 'keiro_read', 'USAGE')
      AND has_table_privilege(
        current_user,
        'keiro_read.projection_group_status_v1',
        'SELECT'
      )
      AND NOT has_schema_privilege(current_user, 'keiro', 'USAGE')
      AND NOT has_schema_privilege(current_user, 'kiroku', 'USAGE')
      AND (
        SELECT count(*) = 1
        FROM keiro_read.projection_group_status_v1
        WHERE group_id = 'status-contract-group'
      )
    """
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

backendPidStatement :: Statement () Int32
backendPidStatement =
  Statement.preparable
    "SELECT pg_backend_pid()"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))

withProjectionReaderRole :: Connection.Connection -> IO value -> IO value
withProjectionReaderRole connection action = do
  backendPid <- useSession connection (Session.statement () backendPidStatement)
  let roleName = "keiro_projection_reader_test_" <> Text.pack (show backendPid)
      install =
        Text.unlines
          [ "CREATE ROLE " <> roleName <> " NOLOGIN;",
            "GRANT USAGE ON SCHEMA keiro_read TO " <> roleName <> ";",
            "GRANT SELECT ON keiro_read.projection_group_status_v1 TO " <> roleName <> ";",
            "SET ROLE " <> roleName <> ";"
          ]
      cleanup =
        Text.unlines
          [ "RESET ROLE;",
            "REVOKE ALL ON keiro_read.projection_group_status_v1 FROM " <> roleName <> ";",
            "REVOKE ALL ON SCHEMA keiro_read FROM " <> roleName <> ";",
            "DROP ROLE " <> roleName <> ";"
          ]
  useSession connection (Session.script install)
  action `finally` useSession connection (Session.script cleanup)

replayProgressFixtureSql :: Text
replayProgressFixtureSql =
  """
  INSERT INTO keiro.keiro_projection_rebuild_groups
    (group_id, slice_fingerprint, status, active_run_id, reads_allowed, writes_allowed)
  VALUES ('constraint-group', 'slice-v1:fixture', 'rebuilding', 'constraint-run', false, false);
  INSERT INTO keiro.keiro_projection_rebuild_runs
    (run_id, group_id, catalog_fingerprint, group_slice_fingerprint, contract_fingerprint,
     runner_format, captured_head, page_size)
  VALUES
    ('constraint-run', 'constraint-group', 'catalog-fingerprint',
     'slice-v1:fixture', 'contract-v2:fixture', 'keiro/projection-replay/v2', 0, 10);
  INSERT INTO keiro.keiro_projection_rebuild_sources
    (run_id, source_id, source_scope, category, target_position)
  VALUES ('constraint-run', 'source', 'category', 'orders', 0);
  INSERT INTO keiro.keiro_projection_rebuild_verifications
    (run_id, verification_id, verification_version)
  VALUES ('constraint-run', 'verify', 'v1');
  """

preCanonicalRebuildFixtureSql :: Text
preCanonicalRebuildFixtureSql =
  """
  INSERT INTO keiro.keiro_projection_rebuild_groups
    (group_id, catalog_fingerprint, status, active_run_id, requested_by, request_reason, started_at)
  VALUES
    ('upgrade-rebuilding', repeat('a', 64), 'rebuilding', 'upgrade-run-live', 'ops', 'mid-rebuild upgrade fixture', now()),
    ('upgrade-failed', repeat('b', 64), 'failed', 'upgrade-run-failed', 'ops', 'abandoned before upgrade', now());
  UPDATE keiro.keiro_projection_rebuild_groups
    SET failed_at = now(), failure_code = 'operator.abandoned', failure_detail = 'abandoned with the old binary'
    WHERE group_id = 'upgrade-failed';
  INSERT INTO keiro.keiro_projection_rebuild_runs
    (run_id, group_id, catalog_fingerprint, contract_fingerprint, runner_format, captured_head, page_size, status)
  VALUES
    ('upgrade-run-live', 'upgrade-rebuilding', repeat('a', 64), 'contract-v2:' || repeat('c', 64), 'keiro/projection-replay/v2', 6, 100, 'running');
  INSERT INTO keiro.keiro_projection_rebuild_runs
    (run_id, group_id, catalog_fingerprint, contract_fingerprint, runner_format, captured_head, page_size, status, failed_at, failure_code, failure_detail)
  VALUES
    ('upgrade-run-failed', 'upgrade-failed', repeat('b', 64), 'contract-v2:' || repeat('d', 64), 'keiro/projection-replay/v2', 6, 100, 'failed', now(), 'operator.abandoned', 'abandoned with the old binary');
  """

preRejectionOutboxFixtureSql :: Text
preRejectionOutboxFixtureSql =
  """
  INSERT INTO keiro.keiro_outbox
    (outbox_id, message_id, source, destination, event_type, schema_version,
     content_type, payload_bytes, occurred_at, status)
  SELECT
    ('018f0f18-0000-7000-8000-000000000b0' || ordinal::text)::uuid,
    'migration-rejection-' || ordinal::text,
    'migration-test',
    'sink',
    'Fixture',
    1,
    'application/json',
    '{}'::bytea,
    now(),
    'publishing'
  FROM generate_series(1, 5) AS ordinal;
  """

validRejectionAuditSql :: Text
validRejectionAuditSql =
  """
  UPDATE keiro.keiro_outbox
  SET status = 'rejected',
      rejected_at = now(),
      rejection_code = 'unsupported.sink',
      rejection_detail = 'the sink cannot accept this event'
  WHERE message_id = 'migration-rejection-1';
  """

missingRejectionAuditSql :: Text
missingRejectionAuditSql =
  """
  UPDATE keiro.keiro_outbox
  SET status = 'rejected'
  WHERE message_id = 'migration-rejection-2';
  """

invalidRejectionCodeSql :: Text
invalidRejectionCodeSql =
  """
  UPDATE keiro.keiro_outbox
  SET status = 'rejected', rejected_at = now(), rejection_code = 'Invalid Code'
  WHERE message_id = 'migration-rejection-3';
  """

oversizedRejectionDetailSql :: Text
oversizedRejectionDetailSql =
  """
  UPDATE keiro.keiro_outbox
  SET status = 'rejected',
      rejected_at = now(),
      rejection_code = 'invalid.payload',
      rejection_detail = repeat('é', 513)
  WHERE message_id = 'migration-rejection-4';
  """

rejectionAuditOnSentSql :: Text
rejectionAuditOnSentSql =
  """
  UPDATE keiro.keiro_outbox
  SET status = 'sent', rejected_at = now(), rejection_code = 'invalid.destination'
  WHERE message_id = 'migration-rejection-5';
  """

preStatusContractFixtureSql :: Text
preStatusContractFixtureSql =
  """
  INSERT INTO keiro.keiro_projection_rebuild_groups
    (group_id, slice_fingerprint, status, reads_allowed, writes_allowed)
  VALUES
    ('upgrade-status-group', 'slice-v6:upgrade-status', 'live', true, true);
  """

preStatusContractFactsStatement :: Statement () (Text, Int32, Text, Bool, Bool)
preStatusContractFactsStatement =
  Statement.preparable
    """
    SELECT cursors.position_basis,
           cardinality(cursors.subscription_names)::integer,
           status.serving_position_basis,
           status.serving_applied_position IS NULL,
           status.reads_allowed
    FROM keiro.keiro_projection_group_cursors AS cursors
    JOIN keiro_read.projection_group_status_v1 AS status
      ON status.group_id = cursors.group_id
    WHERE cursors.group_id = 'upgrade-status-group'
    """
    Encoders.noParams
    ( Decoders.singleRow
        ( (,,,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.int4)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.bool)
            <*> Decoders.column (Decoders.nonNullable Decoders.bool)
        )
    )

guardFunctionOidStatement :: Statement () Int64
guardFunctionOidStatement =
  Statement.preparable
    """
    SELECT 'keiro_read.guard_external_read_v1(text,integer)'::regprocedure::oid::bigint
    """
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

upgradedGuardFactsStatement :: Statement () (Int64, Bool, Bool)
upgradedGuardFactsStatement =
  Statement.preparable
    """
    SELECT procedures.oid::bigint,
           pg_catalog.pg_get_functiondef(procedures.oid)
             LIKE '%group_serving_epoch_before%',
           NOT pg_catalog.has_function_privilege(
             'public',
             procedures.oid,
             'EXECUTE'
           )
    FROM pg_catalog.pg_proc AS procedures
    WHERE procedures.oid =
      'keiro_read.guard_external_read_v1(text,integer)'::regprocedure
    """
    Encoders.noParams
    ( Decoders.singleRow
        ( (,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.int8)
            <*> Decoders.column (Decoders.nonNullable Decoders.bool)
            <*> Decoders.column (Decoders.nonNullable Decoders.bool)
        )
    )

preCanonicalRebuildShapeStatement :: Statement () [(Text, Text, Text, Text)]
preCanonicalRebuildShapeStatement =
  Statement.preparable
    """
    SELECT groups.group_id,
           groups.slice_fingerprint,
           runs.run_id,
           runs.group_slice_fingerprint
    FROM keiro.keiro_projection_rebuild_groups AS groups
    JOIN keiro.keiro_projection_rebuild_runs AS runs
      ON runs.group_id = groups.group_id
    WHERE groups.group_id IN ('upgrade-rebuilding', 'upgrade-failed')
    ORDER BY groups.group_id
    """
    Encoders.noParams
    ( Decoders.rowList
        ( (,,,)
            <$> column Decoders.text
            <*> column Decoders.text
            <*> column Decoders.text
            <*> column Decoders.text
        )
    )
  where
    column = Decoders.column . Decoders.nonNullable

legacyGroupUpgradeStatement ::
  Statement () [(Text, Int64, Text, Text, Text, Text, Maybe Text, Maybe Text)]
legacyGroupUpgradeStatement =
  Statement.preparable
    """
    SELECT rm.name,
           rm.version,
           rm.shape_hash,
           rm.status,
           rm.rebuild_group_id,
           rg.status,
           rg.active_run_id,
           rg.failure_detail
    FROM keiro.keiro_read_models AS rm
    JOIN keiro.keiro_projection_rebuild_groups AS rg
      ON rg.group_id = rm.rebuild_group_id
    ORDER BY rm.name
    """
    Encoders.noParams
    ( Decoders.rowList
        ( (,,,,,,,)
            <$> column Decoders.text
            <*> column Decoders.int8
            <*> column Decoders.text
            <*> column Decoders.text
            <*> column Decoders.text
            <*> column Decoders.text
            <*> nullableColumn Decoders.text
            <*> nullableColumn Decoders.text
        )
    )
  where
    column = Decoders.column . Decoders.nonNullable
    nullableColumn = Decoders.column . Decoders.nullable

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
        { coddLedgerTable = expectedTable,
          nativeLedgerAbsent = True
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
    expectedPending <- postCoddImportPendingIssues
    verifiedBeforeCanaries <- verifyMigrationPlan defaultRunOptions settings plan >>= requireRight
    case verifiedBeforeCanaries of
      VerificationReport verificationIssues _ _ _ ->
        verificationIssues `shouldBe` expectedPending
    up <- runMigrationPlan defaultRunOptions settings plan >>= requireRight
    reportOutcomes up
      `shouldBe` replicate 7 AlreadyApplied
        <> replicate 4 AppliedNow
        <> replicate 16 AlreadyApplied
        <> replicate 15 AppliedNow
    verifiedAfterCanaries <- verifyMigrationPlan defaultRunOptions settings plan >>= requireRight
    case verifiedAfterCanaries of
      VerificationReport verificationIssues _ _ _ -> verificationIssues `shouldBe` []
    rerun <- runMigrationPlan defaultRunOptions settings plan >>= requireRight
    reportOutcomes rerun `shouldBe` replicate 42 AlreadyApplied
    second <-
      importCoddHistory defaultImportOptions config provider plan frameworkCoddHistoryMappings
        >>= requireRight
    importOutcomes second `shouldBe` replicate 23 AlreadyImported
    withConnection settings $ \connection -> do
      assertSchema connection
      sourceRows <- useSession connection (Session.statement () (sourceRowCountStatement sourceSchema))
      sourceRows `shouldBe` 23
      facts <- useSession connection (Session.statement () importFactsStatement)
      facts `shouldBe` (42, 23, True)

postCoddImportPendingIssues :: IO [VerificationIssue]
postCoddImportPendingIssues =
  traverse pendingMigration pendingNames
  where
    pendingMigration (component, name) =
      PendingMigration <$> requireRight (migrationId component name)

    pendingNames =
      [ ("kiroku", "0008-schema-management-comment"),
        ("kiroku", "0009"),
        ("kiroku", "0010"),
        ("kiroku", "0011"),
        ("keiro", "0017-schema-management-comment"),
        ("keiro", "0018"),
        ("keiro", "0019-keiro-snapshots-state-shape-hash"),
        ("keiro", "0020-keiro-workflow-children-failure-reason"),
        ("keiro", "0021-keiro-workflows-exact-discovery"),
        ("keiro", "0022"),
        ("keiro", "0023"),
        ("keiro", "0024"),
        ("keiro", "0025"),
        ("keiro", "0026"),
        ("keiro", "0027"),
        ("keiro", "0028"),
        ("keiro", "0029"),
        ("keiro", "0030"),
        ("keiro", "0031")
      ]

assertPoisonedLedger :: Settings.Settings -> Expectation
assertPoisonedLedger settings =
  withConnection settings $ \connection -> do
    facts <-
      useSession
        connection
        (Session.statement () poisonedLedgerFactsStatement)
    facts `shouldBe` (5, 5, 0)

nativeMigrationFiles :: [FilePath]
nativeMigrationFiles =
  [ "0001-keiro-bootstrap.sql",
    "0002-keiro-outbox.sql",
    "0003-keiro-inbox.sql",
    "0004-keiro-timer-recovery.sql",
    "0005-keiro-workflow-steps.sql",
    "0006-keiro-awakeables.sql",
    "0007-keiro-workflow-children.sql",
    "0008-keiro-workflow-generation.sql",
    "0009-keiro-subscription-shards.sql",
    "0010-keiro-messaging-crash-recovery.sql",
    "0011-keiro-workflows-instances.sql",
    "0012-keiro-workflow-gc-index.sql",
    "0013-keiro-workflows-wake-after.sql",
    "0014-keiro-projection-dedup.sql",
    "0015-keiro-outbox-claim-order-index.sql",
    "0016-keiro-inbox-drop-received-idx.sql",
    "0017-schema-management-comment.sql",
    "0018.sql",
    "0019-keiro-snapshots-state-shape-hash.sql",
    "0020-keiro-workflow-children-failure-reason.sql",
    "0021-keiro-workflows-exact-discovery.sql",
    "0022.sql",
    "0023.sql",
    "0024.sql",
    "0025.sql",
    "0026.sql",
    "0027.sql",
    "0028.sql",
    "0029.sql",
    "0030.sql",
    "0031.sql"
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
    [ "keiro-migrations/migrations.native.lock",
      "migrations.native.lock"
    ]

findNativeExpectedSchema :: IO FilePath
findNativeExpectedSchema =
  findFile
    [ "keiro-migrations/expected-schema/native/keiro-v18.txt",
      "expected-schema/native/keiro-v18.txt"
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
  | line <- Text.lines contents,
    [checksum, filename] <- [Text.words line]
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
  | ComponentDescription {migrations} <- toList components,
    Migrate.Internal.MigrationDescription identifier _ _ _ _ <- toList migrations
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
reportOutcomes MigrationReport {results} = outcome <$> toList results

importOutcomes :: HistoryImportReport -> [HistoryImportOutcome]
importOutcomes HistoryImportReport {importResults} = importOutcome <$> toList importResults

keiroPgConfig :: Pg.Config
keiroPgConfig = Pg.defaultConfig {Pg.user = "keiro"}

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
      (to_regnamespace('keiro_read') IS NOT NULL),
      (to_regclass('keiro.keiro_inbox') IS NOT NULL),
      (to_regclass('keiro.keiro_outbox') IS NOT NULL),
      (to_regclass('keiro.keiro_timers') IS NOT NULL),
      (to_regclass('keiro.keiro_workflows') IS NOT NULL),
      (to_regclass('keiro.keiro_projection_group_cursors') IS NOT NULL),
      (to_regclass('keiro_read.projection_group_status_v1') IS NOT NULL),
      (obj_description(to_regnamespace('keiro_read'), 'pg_namespace') =
        'Versioned, owner-rights read contracts for out-of-process Keiro consumers.'),
      (obj_description(to_regnamespace('kiroku'), 'pg_namespace') = 'Managed by pg-migrate component kiroku through 0011'),
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
    [ "CREATE SCHEMA " <> sourceSchema <> ";",
      "CREATE TABLE " <> sourceSchema <> ".sql_migrations (",
      "  id serial NOT NULL, migration_timestamp timestamptz NOT NULL,",
      "  applied_at timestamptz, name text NOT NULL, application_duration interval,",
      "  num_applied_statements int, no_txn_failed_at timestamptz, txnid bigint, connid int",
      ");",
      "INSERT INTO " <> sourceSchema <> ".sql_migrations",
      "  (migration_timestamp, applied_at, name, application_duration, num_applied_statements, no_txn_failed_at, txnid, connid) VALUES",
      Text.intercalate ",\n" (zipWith renderRow [1 :: Int ..] filenames) <> ";"
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

poisonedLedgerFactsStatement :: Statement () (Int64, Int64, Int64)
poisonedLedgerFactsStatement =
  Statement.preparable
    """
    SELECT
      (SELECT count(*) FROM pgmigrate.migrations),
      (SELECT count(*) FROM pgmigrate.migrations WHERE component = 'kiroku'),
      (SELECT count(*) FROM pgmigrate.history_imports)
    """
    Encoders.noParams
    ( Decoders.singleRow
        ( (,,)
            <$> column Decoders.int8
            <*> column Decoders.int8
            <*> column Decoders.int8
        )
    )
  where
    column = Decoders.column . Decoders.nonNullable
