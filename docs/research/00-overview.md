# Research Overview — 経路 (keiro)

This directory holds the research backing the design of 経路 (keiro), a Haskell event-sourcing and workflow-engine framework intended to replace an in-production system. Each numbered document is a self-contained survey or design note. Read them in order on first pass; thereafter use this index to jump.

## What keiro is

A library (not a server) that composes:

- **kiroku** — Postgres-backed append-only event store. Already in `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.
- **keiki** — pure functional core (decider/evolve via `SymTransducer`). Already in `/Users/shinzui/Keikaku/bokuno/keiki`.
- **shibuya** — supervised subscription/queue-processing engine. Already in `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.
- **shibuya-pgmq-adapter** — pgmq-backed subscription source. Already in shibuya-project.
- **shibuya-kiroku-adapter** — kiroku-backed subscription source. Already in kiroku-project.
- **pgmq-hs** — Postgres queue. Already on the registry.
- **effectful**, **hasql** — runtime substrate.

keiro itself is currently empty (`agents/skills/`, `docs/`). The work this research informs is to design and then build keiro on top of the above.

## Document index

- `01-kiroku-read-side.md` — Current state of kiroku: types, append/read APIs, subscriptions, schema, effects, gaps for keiro.
- `02-keiki-decide-loop.md` — Current state of keiki: `SymTransducer` core, `decide`/`evolve`/`reconstitute`, composition, codec story, gaps.
- `03-shibuya-subscriptions.md` — Current state of shibuya: adapter pattern, handler/ack model, concurrency, supervision, observability, gaps.
- `04-kiroku-keiki-integration.md` — The core integration question: does the load → fold → decide → append cycle work today? What must keiro add?
- `05-workflow-prior-art.md` — Survey of Temporal, Restate, DBOS, Inngest, Eventide/message-db, Akka, EventStoreDB/Marten, Reactive/DDD, Haskell prior art. Distils a v1 minimum-viable feature set and a v2 stretch list.

The above five documents are *current-state* surveys. The MasterPlan (`docs/masterplans/1-keiro-research.md`) decomposes the *design* research that produces concrete keiro design proposals (load/decide/append cycle, codecs, subscriptions, snapshots, workflow roadmap, upstream gaps).

## The single most important question

How does keiro turn the cycle below into a first-class, type-safe, production-quality primitive?

1. Command arrives with a target stream id.
2. Load events for that stream from kiroku (possibly starting from a snapshot).
3. Fold events into the current aggregate state using keiki's `evolve`.
4. Run keiki's `decide(state, command)` to get an error or new events.
5. Append new events to kiroku with `ExpectedVersion = ExactVersion(loadedVersion)`.
6. On `WrongExpectedVersion` retry from step 2.

This cycle does not exist today: kiroku and keiki are independent libraries, with no glue. Designing it (and all the supporting primitives — codecs, snapshots, subscriptions, process managers, transactional steps, durable timers) is the purpose of the research MasterPlan.

## Headline findings (cross-document synthesis)

- **kiroku is solid** for append/read with optimistic concurrency. Crucially, kiroku's Strategy E (atomic counter on the `$all` row) gives gap-free contiguous global positions with immediate read-your-own-writes — see `kiroku/docs/DESIGN.md`. This is a deliberate departure from Marten's bigserial-plus-high-water-mark approach; keiro must rely on Strategy E rather than reinventing HWM. Missing for keiro: typed payload codecs, typed `StreamId` per aggregate, snapshots, a read-decide-append combinator, a `runInTransaction` primitive, projection-rebuild helpers, point-in-time replay.
- **keiki's contract for keiro is `SymTransducer`, not `Decider`.** `Keiki.Decider` is a legacy compatibility facade that masks ε-edges and the typed register file `RegFile rs` — the very features keiki provides to support workflows. Keiro consumes the native `SymTransducer phi rs s ci co` directly via `step`/`delta`/`omega`/`applyEvent`/`applyEvents`/`reconstitute`. Missing for keiro: a structured error model on `step`, a register-file serialization helper, optional effectful reads in decide, a saga/compensate direction.
- **shibuya is production-grade** for queue processing with NQE supervision and OpenTelemetry. Missing: transactional checkpoint+side-effect outbox, process-manager primitive (which keiro provides on top of `SymTransducer`), durable timers, aggregate snapshot loading, multi-source correlation.
- **The kiroku × keiki integration is stub-only.** Read+append in a single Haskell-layer transaction is not currently exposed for a single stream (only `appendMultiStream` opens a tx). Optimistic-retry on `WrongExpectedVersion` is the path forward and is implementable as a generic combinator.
- **Prior art consensus**: Postgres-native + library-shaped wins at our scale (DBOS, Marten). Defer Temporal/Restate-style deterministic-replay durable execution to v2; for v1 ship event-sourced process managers (~90% of workflow needs). Adopt DBOS's transactional step. *Do not* adopt Marten's high-water-mark — kiroku's Strategy E supersedes it. *Do not* adopt the Chassaing decider facade as the contract — use `SymTransducer` directly.
