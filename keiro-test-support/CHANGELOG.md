# Changelog

All notable changes to `keiro-test-support` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

## 0.19.0.0 — 2026-09-25

### Breaking Changes

- Require `kiroku-store >=0.9.0.1 && <0.10`, `kiroku-store-migrations
  ^>=0.6.0.0`, and `pg-migrate ^>=1.2.0.0`. Fixture databases now include
  Kiroku migration `0012`. The version moves in lockstep with the rest of the
  packages, and the `keiro-migrations` bound is raised accordingly.

## 0.18.0.0 — 2026-09-20


### New Features

- New exposed module `Keiro.Test.ReplayCompatibility` defines the versioned,
  build-bound replay capture report and the independently derived inventory
  contract that gate mapping evolution. A report that is missing, unverified,
  empty, duplicated, or divergent from its required observations is rejected
  rather than silently accepted. The package now carries its own
  `keiro-test-support-test` suite covering those rejections.

### Other Changes

- Require `ephemeral-pg >=0.3.1 && <0.4`. The suite fixture now starts its
  server under a stable per-user temporary root, `/tmp/ephpg-keiro-<uid>`,
  instead of `$TMPDIR`, so ephemeral-pg's startup sweep reclaims PostgreSQL
  clusters abandoned by earlier killed runs even when `$TMPDIR` is per-session
  (`nix develop`, some CI runners). Consumers whose build plan also pulls in
  `pg-migrate-test-support 1.1.0.0` need
  `allow-newer: pg-migrate-test-support:ephemeral-pg` in their `cabal.project`
  until a Hackage revision widens that cap.

## 0.17.0.0 — 2026-09-17

### New Features

- Add `withFreshResourceStorePrepared`, which clones a database, runs a
  privileged preparation callback against a temporary store for roles and
  ACLs, closes it, and then opens the resource-aware application store with
  modified connection settings.

## 0.16.0.0 — 2026-09-07

### Other Changes

- No user-facing changes; release in lockstep with the Keiro 0.16.0.0 package set.

## 0.15.0.0 — 2026-08-30

No changes this release. `keiro-test-support` is republished at the shared version
so its `keiro-migrations` dependency remains lockstep.

## 0.14.0.0 — 2026-08-21

First published release. `keiro-test-support` existed in the repository from the
beginning as an internal fixture library; it is published from this release on so
that the Keiro packages' test-suites are buildable from their Hackage tarballs,
and so that consumers can reuse the same fixtures for their own Keiro services.

It enters the lockstep package set directly at the shared version 0.14.0.0 rather
than at its internal `0.1.0.0`, because a released `keiro-test-support` must say
which Keiro it pairs with. Its `keiro-migrations` dependency moves in lockstep
from here on.

### New Features

- `Keiro.Test.Postgres` exposes the suite-level `ephemeral-pg` template-database
  fixture: `withMigratedSuite` / `withMigratedSuiteWith` start one cached server
  and migrate one template database per suite, and `withFreshDatabase`,
  `withFreshStore`, `withFreshStoreWith`, `withFreshResourceStore`,
  `withFreshResourceStoreWith`, and `withFreshStores2` clone an isolated database
  per example. `Fixture` is abstract and `StoreRunner` is exported for callers
  that supply their own store runner.

### Other Changes

- Every dependency now carries a PVP upper bound. As an internal package it had
  open-ended bounds on `aeson`, `containers`, `effectful`, `ephemeral-pg`,
  `hasql`, `hasql-pool`, `stm`, `text`, and an entirely unbounded
  `keiro-migrations`; all are bounded to match the rest of the package set.
- Ships a `LICENSE` file, like every other published package in the set.
