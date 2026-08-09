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

### Breaking Changes

- Requires `kiroku-store >=0.4 && <0.5` for the released durable inventory API.
