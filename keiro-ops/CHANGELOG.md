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

### Known Limitations

- Durable subscription checkpoint inventory and projection-position reporting
  wait for the owning Kiroku API tracked by
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2`. This package
  does not inspect Kiroku's private schema.
