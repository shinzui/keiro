# 2. Keiro owns live schema verification under pg-migrate

Date: 2026-07-23

Status: Accepted


## Context

Keiro replaced codd with pg-migrate as its migration runner. pg-migrate verifies the
declared migration plan against its checksum-keyed ledger, but deliberately does not
describe or compare the live PostgreSQL schema. The old codd build had also supplied a
schema-shape check, a migration-body lint, and a service-startup handshake. Those checks
survived only behind Keiro's disabled `legacy-codd-tools` flag after the runner swap.

Ledger integrity and live-schema integrity answer different questions. A valid ledger proves
that the expected migration history was recorded. It cannot detect an index dropped by hand,
a column altered after migration, or a partially restored schema. Conversely, a schema
snapshot cannot establish migration order, checksums, or ledger completeness.

The old expected-schema format was codd-specific JSON, included machine-sensitive role and
database settings, and was already stale relative to Keiro's native migrations. Porting it
would have recreated a substantial part of the retired runner.

pg-migrate also keeps `ConnectionProvider` opaque. Its public API can pass a provider to
pg-migrate operations, but it cannot run an application-defined Hasql `Session`. Importing
`Database.PostgreSQL.Migrate.Internal` to bypass that boundary would couple Keiro to an
explicitly unsupported API.


## Decision

Keep pg-migrate's `verify` command as the ledger-integrity gate, and make live-schema
verification a separate Keiro-owned gate named `keiro-migrate verify-schema`.

The expected live schema is a checked-in, sorted text snapshot of the `keiro` schema's
tables, columns, constraints, and indexes. It targets PostgreSQL 18, matching Keiro's
supported native expected-schema baseline. Roles, grants, database settings, and standalone
sequence properties are outside this gate. Sequence-backed column defaults remain covered
as column definitions.

`Keiro.Migrations.SchemaCheck` exposes two layers:

- `snapshotSchema :: Text -> Session Text` for callers that own a Hasql connection.
- `verifyExpectedSchema :: Settings -> IO (Either MigrationError [SchemaDrift])` for the
  CLI and other callers that have connection settings.

The settings-based boundary is intentional. Keiro will not import pg-migrate internals or
require an upstream release merely to run its own catalog query.

Catalog rendering must be independent of the login role. The snapshot query locally pins
`search_path` to `pg_catalog` before calling PostgreSQL deparsing functions such as
`pg_get_expr`; otherwise an unchanged `regclass` default can render with or without a schema
qualification depending on whether the role's `$user` schema is visible.

The other restored checks remain separate and run in the default build:

- A pure body lint rejects unqualified DDL targets and any migration that manipulates
  `search_path`.
- `missingMigrations` uses pg-migrate's public status report to power a strict application
  startup handshake.

No check replaces another. Operators use `verify` for ledger integrity and `verify-schema`
for live objects; services use the startup handshake; CI runs the lint and regenerates the
expected schema in a fresh database.


## Consequences

Hand-altered live schemas now produce a nonzero CLI result naming each missing, unexpected,
or changed object, while pg-migrate's existing ledger semantics remain unchanged.

The snapshot is readable and reviewable, but it is a Keiro-maintained representation rather
than a general PostgreSQL schema-diff engine. Adding an object class or supporting another
PostgreSQL major version requires an explicit format and snapshot change.

Callers with only a pg-migrate `ConnectionProvider` cannot reuse the high-level verifier.
They must retain `Settings`, own a Hasql session and call `snapshotSchema`, or wait for a
future public pg-migrate extension point. That constraint is preferable to depending on an
unstable internal module.

Because the three restored gates are in the normal cabal components, regressions no longer
depend on anyone remembering to enable `legacy-codd-tools`.


## References

- [docs/plans/122-restore-live-schema-verification-body-lint-and-the-startup-handshake-under-pg-migrate.md](../plans/122-restore-live-schema-verification-body-lint-and-the-startup-handshake-under-pg-migrate.md)
  — implementation plan and negative-path evidence.
- [docs/masterplans/19-restore-the-migration-integrity-gates-under-pg-migrate-surfaced-by-the-2026-07-migration-review.md](../masterplans/19-restore-the-migration-integrity-gates-under-pg-migrate-surfaced-by-the-2026-07-migration-review.md)
  — initiative scope and the remaining build-integrity and cutover gates.
- [docs/user/migrations.md](../user/migrations.md)
  — operator commands and the application-startup handshake.
