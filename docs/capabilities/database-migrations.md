---
title: "Native database migrations and the keiro-migrate CLI"
type: Capability
description: "Install and upgrade the Kiroku and Keiro Postgres schemas with dependency-ordered, embedded pg-migrate components and a keiro-migrate executable, plus a verified import path from legacy Codd ledgers."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-13
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro-migrations
interface:
  - Keiro.Migrations
  - Keiro.Migrations.SchemaCheck
  - Keiro.Migrations.History.Codd
evidence:
  - kind: test
    resource: keiro-migrations/test/Main.hs
    proves: "The migration components apply in dependency order and the resulting schema matches the expected schema check."
  - kind: guide
    resource: docs/user/migrations.md
    proves: "How to install and upgrade the schema with keiro-migrate, and how migration ownership and deploy ordering work."
  - kind: module
    resource: keiro-migrations/app/Main.hs
    proves: "The keiro-migrate executable entry point that installs and upgrades the schema."
---

# Native database migrations and the keiro-migrate CLI

A separately depended-on package (`keiro-migrations`) that owns the Kiroku and
Keiro Postgres schemas as native, dependency-ordered `pg-migrate` components
embedded in the binary, driven by the `keiro-migrate` executable. A schema check
compares the live database against the expected schema, and a verified import
path brings a database previously managed by a legacy Codd ledger onto the
native migration history without a drop-and-recreate.

This is its own capability because it is a distinct package and CLI a consumer
runs at deploy time, adopted and verified independently of the runtime library
whose tables it provisions.

## Shape

```bash
keiro-migrate up --database-url "$DATABASE_URL"   # install or upgrade the schema
```

## Limits

- The legacy Codd import tooling lives behind the `legacy-codd-tools` cabal flag
  (`Keiro.Migrations.LegacyCodd`, `Keiro.Migrations.New`,
  `Keiro.Migrations.ExpectedSchema`) and pulls in `codd`; it is a one-time
  migration aid, not part of the default build, and a consumer starting fresh
  never needs it.
- Migrations are forward-only and Postgres-specific. There is no down-migration
  path; a rollback is a new forward migration.
