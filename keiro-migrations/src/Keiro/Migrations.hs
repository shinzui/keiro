module Keiro.Migrations (
    CoddLedgerPreflight (..),
    ConnectionProvider,
    DefinitionError,
    MigrationComponent,
    MigrationError,
    MigrationId,
    MigrationPlan,
    PlanError,
    RunOptions,
    StartupHandshake (..),
    VerificationIssue (..),
    connectionProviderFromSettings,
    defaultRunOptions,
    embeddedMigrationEntries,
    frameworkMigrationPlan,
    handshakePassed,
    keiroMigrations,
    missingMigrations,
    preflightFreshLedgerOverCodd,
    renderCoddPreflight,
) where

import Control.Exception (finally)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Database.PostgreSQL.Migrate (
    ConnectionProvider,
    DefinitionError,
    MigrationComponent,
    MigrationError (..),
    MigrationId,
    MigrationPlan,
    PlanError,
    RunOptions,
    VerificationIssue (..),
    connectionProviderFromSettings,
    defaultRunOptions,
    migrationPlan,
    migrationStatusWith,
 )
import Database.PostgreSQL.Migrate qualified as Migrate
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Keiro.Migrations.Internal.Definition (
    embeddedMigrationEntries,
    keiroMigrations,
 )

-- | Whether a codd ledger makes initializing an empty native ledger unsafe.
data CoddLedgerPreflight
    = CoddPreflightClear
    | CoddPreflightBlocked
        { coddLedgerTable :: Text
        -- ^ The detected @codd.sql_migrations@ table.
        , nativeLedgerAbsent :: Bool
        -- ^ 'True' when @pgmigrate.migrations@ is absent; 'False' when it is empty.
        }
    deriving stock (Eq, Show)

-- | Refuse to initialize a fresh native ledger over a retired codd ledger.
preflightFreshLedgerOverCodd ::
    Settings.Settings ->
    IO (Either MigrationError CoddLedgerPreflight)
preflightFreshLedgerOverCodd settings = do
    acquired <- Connection.acquire settings
    case acquired of
        Left connectionError ->
            pure (Left (ConnectionAcquisitionFailed connectionError))
        Right connection -> do
            result <-
                Connection.use connection coddLedgerPreflightSession
                    `finally` Connection.release connection
            pure $ case result of
                Left sessionError -> Left (DatabaseSessionFailed sessionError)
                Right preflight -> Right preflight

-- | Render the blocked state as an operator-facing refusal.
renderCoddPreflight :: CoddLedgerPreflight -> Text
renderCoddPreflight preflight =
    case preflight of
        CoddPreflightClear -> ""
        CoddPreflightBlocked{coddLedgerTable, nativeLedgerAbsent} ->
            "refusing to run up: this database has a codd migration ledger ("
                <> coddLedgerTable
                <> ") and "
                <> nativeHistoryState nativeLedgerAbsent
                <> ". Running up here would initialize a fresh ledger over the codd one "
                <> "and re-plan every migration. Follow "
                <> "docs/user/upgrading-to-the-keiro-schema.md (import the codd history "
                <> "first), or pass --allow-fresh-ledger-over-codd if a fresh native "
                <> "ledger over the retired codd ledger is genuinely intended."
  where
    nativeHistoryState True = "no native pg-migrate history"
    nativeHistoryState False = "an empty native pg-migrate history"

coddLedgerPreflightSession :: Session CoddLedgerPreflight
coddLedgerPreflightSession = do
    (currentCoddExists, legacyCoddExists, nativeLedgerExists) <-
        Session.statement () ledgerPresenceStatement
    case detectedCoddLedger currentCoddExists legacyCoddExists of
        Nothing -> pure CoddPreflightClear
        Just coddLedgerTable
            | not nativeLedgerExists ->
                pure CoddPreflightBlocked{coddLedgerTable, nativeLedgerAbsent = True}
            | otherwise -> do
                nativeRows <- Session.statement () nativeLedgerCountStatement
                pure $
                    if nativeRows == 0
                        then
                            CoddPreflightBlocked
                                { coddLedgerTable
                                , nativeLedgerAbsent = False
                                }
                        else CoddPreflightClear

detectedCoddLedger :: Bool -> Bool -> Maybe Text
detectedCoddLedger currentCoddExists legacyCoddExists
    | currentCoddExists = Just "codd.sql_migrations"
    | legacyCoddExists = Just "codd_schema.sql_migrations"
    | otherwise = Nothing

ledgerPresenceStatement :: Statement () (Bool, Bool, Bool)
ledgerPresenceStatement =
    Statement.preparable
        """
        SELECT to_regclass('codd.sql_migrations') IS NOT NULL,
               to_regclass('codd_schema.sql_migrations') IS NOT NULL,
               to_regclass('pgmigrate.migrations') IS NOT NULL
        """
        Encoders.noParams
        ( Decoders.singleRow
            ( (,,)
                <$> column Decoders.bool
                <*> column Decoders.bool
                <*> column Decoders.bool
            )
        )
  where
    column = Decoders.column . Decoders.nonNullable

nativeLedgerCountStatement :: Statement () Int64
nativeLedgerCountStatement =
    Statement.preparable
        "SELECT count(*) FROM pgmigrate.migrations"
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

-- | Boot-time answer to "does this database carry every migration this binary expects?".
data StartupHandshake = StartupHandshake
    { pendingMigrations :: [MigrationId]
    -- ^ Declared migrations with no applied ledger row, in plan order.
    , ledgerIssues :: [VerificationIssue]
    -- ^ Checksum, position, kind, gap, status, or unknown-row problems.
    }
    deriving stock (Eq, Show)

-- | Whether the database is safe for this binary to serve requests.
handshakePassed :: StartupHandshake -> Bool
handshakePassed handshake =
    null (pendingMigrations handshake) && null (ledgerIssues handshake)

-- | Read-only boot-time migration check; safe to call from every replica.
missingMigrations ::
    RunOptions ->
    ConnectionProvider ->
    MigrationPlan ->
    IO (Either MigrationError StartupHandshake)
missingMigrations options provider plan =
    fmap toStartupHandshake <$> migrationStatusWith options provider plan
  where
    toStartupHandshake :: Migrate.StatusReport -> StartupHandshake
    toStartupHandshake (Migrate.StatusReport statusIssues _ pending _) =
        StartupHandshake
            { pendingMigrations = pending
            , ledgerIssues = statusIssues
            }

{- | Compose the concrete Kiroku and Keiro components in dependency order.

The first argument must be Kiroku's component and the second must be Keiro's.
The native planner validates both identity and ordering, so swapped or unrelated
components fail with a structured 'PlanError'.
-}
frameworkMigrationPlan ::
    MigrationComponent ->
    MigrationComponent ->
    Either PlanError MigrationPlan
frameworkMigrationPlan kiroku keiro =
    migrationPlan (kiroku :| [keiro])
