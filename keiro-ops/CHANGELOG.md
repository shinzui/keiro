# Changelog

All notable changes to `keiro-ops` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

### Added

- A standalone, schema-checked operations console for Keiro- and Kiroku-owned
  database operations, with human tables and stable JSON generated from the
  same result values.
- Preview-before-`--force` mutations, schema-drift refusal, and typed stream-name
  confirmation for permanent stream operations.
- `AppHooks`, `opsCommandTree`, `runOpsInvocation`, and `mainWithHooks` for
  mounting application-owned workflow resume, timer dispatch, candidate-code
  replay audit, and validated projection-catalog rebuild commands.
- Read-only `stream subscriptions` and
  `projection position --subscription NAME` commands backed by the public
  Kiroku 0.4 durable checkpoint inventory. Both preserve member rows and report
  `global_position_distance`; neither queries Kiroku's private schema or claims
  a relevant-event lag.
- Projection catalog inventory and rebuild JSON expose each subscription's
  stable `checkpointOnMissing` value from the same validated catalog used by
  runtime registration and rebuild planning.
- Embedded catalog operations add `rebuild adopt GROUP...`. Without `--force`
  it classifies every catalog group, shows stored/current slice fingerprints
  and removed groups, and prints the exact force invocation. With `--force` it
  calls the supported transactional adoption API and reports the adopted rows.
  Existing rebuild list and preview tables also expose slice identity.
- Embedded `wf resume-once` results expose `advanced` and `paced` counts plus
  the sorted set of `unregistered_names` in JSON (and the corresponding human
  columns), so an operator can terminate a bounded drain on durable progress and
  identify the workflow definitions blocking convergence.

### Breaking Changes

- Requires `kiroku-store >=0.5 && <0.6` for explicit checkpoint lifecycle and
  the public transaction-composable reset API used across the workspace.
