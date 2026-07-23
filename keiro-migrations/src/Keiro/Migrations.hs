module Keiro.Migrations (
    DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    embeddedMigrationEntries,
    frameworkMigrationPlan,
    keiroMigrations,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Database.PostgreSQL.Migrate (
    DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    migrationPlan,
 )
import Keiro.Migrations.Internal.Definition (
    embeddedMigrationEntries,
    keiroMigrations,
 )

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
