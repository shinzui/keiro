# keiro workspace

This repository is a Cabal multi-package workspace for the keiro event-sourcing
framework and workflow engine. Each package lives in its own subdirectory and is
listed in `cabal.project`.

## Packages

- `keiro/` — the main framework library (event-sourcing command cycle,
  snapshots, read models, projections, process managers, timers, inbox/outbox,
  and telemetry). See `keiro/README.md` for the full package overview.
- `keiro-core/` — stable, dependency-light contract modules (`Keiro.Codec`,
  `Keiro.EventStream`, `Keiro.Integration.Event`, `Keiro.Prelude`,
  `Keiro.Snapshot.Policy`, `Keiro.Stream`) shared by the other packages.
- `keiro-migrations/` — SQL schema migrations for the PostgreSQL event store.
- `jitsurei/` — guide-backed, runnable worked examples that depend on `keiro`.

## Building

From this directory:

```bash
cabal build all
cabal test all
```

Design history and implementation plans live under `docs/`.
