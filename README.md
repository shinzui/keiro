# keiro — 経路

keiro is a Haskell library for event sourcing and workflow orchestration. It
combines an append-only event store, a pure functional state machine, and
subscription workers into one library-shaped runtime that an application imports
and runs against PostgreSQL.

## The name

**経路** (*keiro*) means **route**, **path**, or **course** in Japanese: the way
something travels from an origin to a destination.

| Kanji | Reading | Meaning |
|---|---|---|
| 経 | *kei* | to pass through, to elapse, a way, a longitude |
| 路 | *ro* | a road, path, or way |

The name is literal. keiro is about the paths events take through a system:

- an event stream is the route an aggregate's history has taken;
- a subscription follows the route through the global event log;
- a projection routes events into queryable read models;
- a process manager routes source events into commands for another stream;
- a workflow is a durable route through state, timers, and external effects.

The sibling project **keiki** (継起, "successive occurrence") names the
succession of events. **keiro** names the routes those events travel and the
routes downstream processes follow.

## What it provides

The current v1 library provides:

- typed stream names through `Keiro.Stream`;
- event codecs, schema versions, event type validation, and upcasters through
  `Keiro.Codec`;
- the author-facing `EventStream` contract in `Keiro.EventStream`;
- `runCommand` and `runCommandWithSql` in `Keiro.Command` for the canonical
  load, streaming replay, decide, append-event-batch cycle with optimistic
  concurrency;
- advisory snapshots in `Keiro.Snapshot`;
- read models, inline projections, async projection helpers, and rebuild
  metadata in `Keiro.ReadModel` and `Keiro.Projection`;
- event-sourced process managers in `Keiro.ProcessManager`;
- durable timer storage and workers in `Keiro.Timer`.

The stable contracts used by future Keiro packages live in the sibling
`keiro-core` package. The full `keiro` package depends on `keiro-core` and
re-exports those core modules, so existing imports such as `Keiro.Codec`,
`Keiro.EventStream`, `Keiro.Stream`, and `Keiro.Integration.Event` continue to
work for applications that depend on `keiro`.

The top-level `Keiro` module re-exports the core stream, codec, event-stream,
command, and snapshot APIs. Read-model, projection, process-manager, and timer
modules are exposed directly so applications can import them explicitly.

## Runtime stack

keiro is not a server. The `keiro-core` package contains reusable contracts and
pure helpers; the `keiro` package adds the runtime that composes these
dependencies:

- **kiroku** for the PostgreSQL-backed append-only event store;
- **keiki** for the pure `SymTransducer` state-machine core;
- **shibuya** for subscription and worker supervision;
- **hasql** and **effectful** for database access and effect handling;
- **Streamly** for streaming reads and worker loops.

## Development

From the repository root:

```bash
cabal build all
cabal test all
cabal test jitsurei-test
just haskell-verify
```

The package metadata lives in `keiro.cabal`. The implementation plans and design
history live under `docs/masterplans/`, `docs/plans/`, and `docs/research/`.
User-facing documentation starts at `docs/user/README.md`. Long-form,
guide-backed examples start at `docs/guides/README.md` and use the sibling
`jitsurei` package as their executable source.

## Status

The v1 implementation MasterPlan is complete. The library currently includes
the package scaffold, public `EventStream` and codec contract, command cycle,
snapshots, read models and projections, process managers, and durable timer APIs.

Remaining work is future-facing: the v2 deterministic durable-execution runtime,
exactly-once async projection checkpoint/user-SQL transactions once shibuya
exposes that boundary, and higher-level ergonomic facades over the low-level v1
APIs.

## License

BSD-3-Clause.
