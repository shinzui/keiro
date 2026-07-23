module Keiro.Migrations (
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
) where

import Data.List.NonEmpty (NonEmpty (..))
import Database.PostgreSQL.Migrate (
    ConnectionProvider,
    DefinitionError,
    MigrationComponent,
    MigrationError,
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
import Keiro.Migrations.Internal.Definition (
    embeddedMigrationEntries,
    keiroMigrations,
 )

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
