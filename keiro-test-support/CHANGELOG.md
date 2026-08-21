# Changelog

All notable changes to `keiro-test-support` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

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
