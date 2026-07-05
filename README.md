# keiro — 経路

keiro is a Haskell **framework** for **event sourcing and workflow
orchestration** on PostgreSQL. It composes a set of sibling libraries — an
append-only event store ([kiroku](https://github.com/shinzui/kiroku)), a pure
state-machine core ([keiki](https://github.com/shinzui/keiki)), and supervised
subscription workers ([shibuya](https://github.com/shinzui/shibuya)) — into a
runtime that an application builds on and runs against its own Postgres
database. There is no separate workflow server, no second replicated log, and no
parallel storage path for "workflow state" versus "domain events": everything is
journaled into one kiroku event log.

> [!WARNING]
> **keiro is under active development.** It is already used in production, but
> the public API is not yet stable and may change in breaking ways between
> releases.

**経路** (*keiro*) means *route* or *path* — the way something travels from an
origin to a destination. The name is literal: an event stream is the route an
aggregate's history has taken, a subscription follows the route through the
global log, a projection routes events into read models, and a process manager
routes source events into commands for another stream.

This repository is a Cabal multi-package workspace. Each package lives in its
own subdirectory and is listed in `cabal.project`.

## The idea

keiro unifies two engines over a **single Postgres event log**:

- an **event-sourcing core** built on keiki's symbolic-register state-machine
  transducer (`SymTransducer`). Aggregates decide commands into events; process
  managers and routers turn one category's events into another category's
  commands, with timers, retry counters, and correlation ids as typed register
  slots; projections fold events into read models — all with optimistic-
  concurrency appends and total, replay-safe folds.
- a **durable-execution engine** (the `Workflow` effect). Write a long-running
  process as an ordinary `effectful` computation; each named `step` journals its
  result into a kiroku stream (`wf:<name>-<id>`), so a crash resumes from the
  last recorded step without re-running committed work. Suspension primitives —
  `sleep`, `awakeable` (external signal), and child workflows — journal as
  ordinary step records, and a resume worker recovers in-flight runs. Replay is
  keyed by step *name*, not source position, so refactoring the workflow body is
  safe.

The two engines share one substrate — kiroku streams in your Postgres — so
domain events, process-manager state, and workflow journals sit on one timeline,
inspected with one query. See [`docs/why-keiro.md`](docs/why-keiro.md) for the
motivation and an honest account of what keiro deliberately gives up.

## What the framework provides

- typed stream names, event codecs, schema versions, event-type validation, and
  upcasters (`Keiro.Stream`, `Keiro.Codec`, `Keiro.EventStream`);
- the canonical command cycle — load, streaming replay, decide, append-batch
  with optimistic concurrency — including a **transactional step**
  (`runCommandWithSql`) that appends events, updates inline projections, and
  writes outbox/timer rows in one Postgres transaction (`Keiro.Command`);
- advisory snapshots that never become load-bearing (`Keiro.Snapshot`);
- read models, inline/async projections, and rebuild metadata
  (`Keiro.ReadModel`, `Keiro.Projection`);
- event-sourced process managers, routers, and durable timers
  (`Keiro.ProcessManager`, `Keiro.Router`, `Keiro.Timer`);
- a **durable-execution runtime** — named-step journaling, crash-safe replay and
  resume, and `sleep` / `awakeable` / child-workflow suspension
  (`Keiro.Workflow` and submodules);
- a transactional outbox / idempotent inbox with Kafka adapters
  (`Keiro.Outbox`, `Keiro.Inbox`);
- OpenTelemetry telemetry across every delivery and handler (`Keiro.Telemetry`).

## Runtime stack

keiro is a framework, not a server. It builds on the author's sibling libraries:

- **[kiroku](https://github.com/shinzui/kiroku)** — PostgreSQL append-only event
  store with gap-free contiguous global positions;
- **[keiki](https://github.com/shinzui/keiki)** — the pure `SymTransducer`
  state-machine core used by the event-sourcing side;
- **[shibuya](https://github.com/shinzui/shibuya)** — subscription and worker
  supervision, with pgmq and Kafka adapters;
- **[pgmq-hs](https://github.com/shinzui/pgmq-hs)** — the Postgres-native message
  queue behind `keiro-pgmq` and the outbox drain;

and the wider ecosystem — **hasql** and **effectful** for database access and
effect handling, and **Streamly** for streaming reads and worker loops.

## Packages

- `keiro/` — the framework library (command cycle, snapshots, read models,
  projections, process managers, routers, timers, durable workflows,
  inbox/outbox, telemetry). See [`keiro/README.md`](keiro/README.md) for the
  full overview.
- `keiro-core/` — stable, dependency-light contract modules (`Keiro.Codec`,
  `Keiro.EventStream`, `Keiro.Integration.Event`, `Keiro.Prelude`,
  `Keiro.Snapshot.Policy`, `Keiro.Stream`) shared by the other packages.
- `keiro-pgmq/` — PostgreSQL job-queue (PGMQ) integration: a reusable
  Postgres-backed work queue built on `pgmq-hs` and shibuya's pgmq adapter.
- `keiro-dsl/` — typed-specification (`.keiro`) toolchain for keiro services:
  parse / check / scaffold / harness / diff.
- `keiro-migrations/` — SQL schema migrations for the PostgreSQL event store and
  keiro's tables.
- `keiro-test-support/` — shared PostgreSQL test fixtures for the test suites.
- `jitsurei/` — guide-backed, runnable worked examples that depend on `keiro`.

## Building

From this directory:

```bash
cabal build all
cabal test all
```

The test suites use ephemeral PostgreSQL databases, so a `postgres` toolchain
must be on `PATH` (the Nix dev shell provides one).

## Documentation

- User-facing documentation starts at [`docs/user/README.md`](docs/user/README.md).
- Long-form, guide-backed examples start at
  [`docs/guides/README.md`](docs/guides/README.md) and use the `jitsurei`
  package as their executable source.
- Motivation and comparison to adjacent systems: [`docs/why-keiro.md`](docs/why-keiro.md).
- Design history and implementation plans live under `docs/research/`,
  `docs/masterplans/`, and `docs/plans/`.

## Status

The event-sourcing core (command cycle, snapshots, read models and projections,
process managers, routers, durable timers, transactional outbox/inbox) and the
named-step durable-execution runtime are implemented — production-shaped for
controlled early use, not yet a 1.0. keiro is Haskell-only and single-region
Postgres by design; remaining work is future-facing — exactly-once async
projection checkpoints and higher-level ergonomic facades over the low-level
APIs. See [`docs/user/production-status.md`](docs/user/production-status.md).

## License

BSD-3-Clause.
