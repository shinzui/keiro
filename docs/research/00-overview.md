# Research Overview — 経路 (keiro)

This directory holds the research backing the design of 経路 (keiro), a Haskell event-sourcing and workflow-engine framework intended to replace an in-production system. Each numbered document is a self-contained survey or design note. Read them in order on first pass; thereafter use this index to jump.

> **Status note (2026-07-13):** these documents preserve the design history and
> may describe gaps as they existed when each study closed. Keiro is now an
> implemented multi-package framework. For the current public contract use the
> [User Guide](../user/README.md), [Production Status](../user/production-status.md),
> [API Reference](../user/api-reference.md), and
> [Typed Specifications](../user/typed-spec-toolchain.md). The overview below
> annotates major closures but does not rewrite historical conclusions in place.

## What keiro is

A library (not a server) that composes:

- **kiroku** — Postgres-backed append-only event store. Already in `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.
- **keiki** — pure functional core (decider/evolve via `SymTransducer`). Already in `/Users/shinzui/Keikaku/bokuno/keiki`.
- **shibuya** — supervised subscription/queue-processing engine. Already in `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.
- **shibuya-pgmq-adapter** — pgmq-backed subscription source. Already in shibuya-project.
- **shibuya-kiroku-adapter** — kiroku-backed subscription source. Already in kiroku-project.
- **pgmq-hs** — Postgres queue. Already on the registry.
- **effectful**, **hasql** — runtime substrate.

Keiro now implements the command cycle, codecs, replay validation, snapshots,
read models/projections, process managers, routers, timers, transactional
messaging, durable workflows, dead-letter tooling, native migrations, PGMQ
jobs, and the `.keiro` typed-spec toolchain described by this research.

## Document index

- `01-kiroku-read-side.md` — Current state of kiroku: types, append/read APIs, subscriptions, schema, effects, gaps for keiro.
- `02-keiki-decide-loop.md` — Current state of keiki: `SymTransducer` core, `decide`/`evolve`/`reconstitute`, composition, codec story, gaps.
- `03-shibuya-subscriptions.md` — Current state of shibuya: adapter pattern, handler/ack model, concurrency, supervision, observability, gaps.
- `04-kiroku-keiki-integration.md` — The core integration question: does the load → fold → decide → append cycle work today? What must keiro add?
- `05-workflow-prior-art.md` — Survey of Temporal, Restate, DBOS, Inngest, Eventide/message-db, Akka, EventStoreDB/Marten, Reactive/DDD, Haskell prior art. Distils a v1 minimum-viable feature set and a v2 stretch list.
- `06-command-cycle-design.md` — Design of keiro's load → fold → decide → append cycle. The keiro ⇄ keiki contract (an `EventStream phi rs s ci co` record over keiki's native `SymTransducer`), `runCommand`, `runCommandRetry`, hydration as a Streamly `Stream`/`Fold`, the optimistic-retry policy, the transactional-step combinator, and multi-stream commands. Validated by the working spike at `spikes/command-cycle/`. Produced by ExecPlan EP-1 of the research-foundation MasterPlan.
- `07-codec-strategy.md` — Design of keiro's codec layer between typed domain events and kiroku's `Aeson.Value` storage. Value-level `Codec e` record carrying encode + decode + type-tag + version + a consecutive-upcaster chain. Schema versions live in `EventData.metadata.schemaVersion`; type tags stay stable across versions. Verdict on the `hindsight` library is "selectively borrow" — adopt the consecutive-upcaster pattern, version-vector concept, and test discipline at the value level; reject the type-level machinery. Validated by the working spike at `spikes/codec/`. Produced by ExecPlan EP-2 of the research-foundation MasterPlan.
- `08-subscription-and-process-manager-design.md` — Design of keiro's three projection lifecycles (inline / async / live), the event-sourced process-manager substrate that stands in for v1 workflows, the transactional outbox/inbox patterns built on `pgmq-hs` + `shibuya-pgmq-adapter`, the gap-free-read guarantee inherited from kiroku's Strategy E (no Marten-style high-water-mark needed), and the Streamly pipeline shapes each lifecycle exposes. Two upstream gaps blocking exactly-once async projections are forwarded to EP-6: a kiroku-store single-stream `runInTransaction` combinator (**closed 2026-05-10** — shipped as `Kiroku.Store.Transaction.runTransactionAppending`; the design doc carries a corrections-note overlay) and a shibuya-kiroku-adapter `HandlerInTransaction` shape (**still open** as of 2026-05-10). Design-only (the spike was deferred per EP-3's Decision Log because the central exactly-once-via-transaction claim cannot be verified without those upstream additions). Produced by ExecPlan EP-3 of the research-foundation MasterPlan.
- `09-snapshot-strategy.md` — Design of keiro's snapshot path: a single sidecar `keiro_snapshots` table keyed on kiroku's `stream_id`, holding the encoded joint state `(s, RegFile rs)` along with `state_codec_version` and `regfile_shape_hash` discriminants for safe fall-through on schema change. A value-level `StateCodec` record-of-functions (sibling of EP-2's `Codec e`, versioned at the aggregate level rather than per record). A pure `SnapshotPolicy` with three named constructors (`Every n`, `OnTerminal`, `Never`). Hydration short-circuits the EP-1 Streamly `Stream → Fold` pipeline by parameterizing the source's start cursor and the fold's initial accumulator — same pipeline, no parallel code path. Writes are post-commit, asynchronous, and gated by a monotonicity guard on the `ON CONFLICT DO UPDATE` so stale writes cannot regress a fresher snapshot. Snapshots are *advisory* — never load-bearing — so operators can `TRUNCATE` the table at any time. Process managers (EP-3 §5) and long-lived workflow streams (EP-5) are the primary beneficiaries. One keiki-side gap (a `RegFile rs <-> Aeson.Value` helper plus a stable shape hash) is shared with EP-1 and EP-2 and consolidated by EP-6. Design-only. Produced by ExecPlan EP-4 of the research-foundation MasterPlan.
- `10-workflow-roadmap.md` — Roadmap fixing what "workflow" means in keiro v1 vs v2. v1 ships event-sourced process managers (EP-3), durable timers (a new `keiro_timers` table polled by a worker; this document owns the design), the transactional outbox/inbox (EP-3), inline and async projections (EP-3), snapshots (EP-4), and idempotent commands (EP-1) — together covering saga and choreography use cases that account for ~90% of "workflow" demand without a deterministic-replay runtime. v2 adds named-step durable execution on a journaled `Workflow es a` effect (`step`/`sleep`/`awakeable`/`runWorkflow`); the journal lives in kiroku as `wf:<workflow-name>-<workflow-id>` streams, shares storage and observability with v1's PM streams, and the v1-to-v2 upgrade path is mechanical (a process manager *is* a workflow with one explicit step). Named-step durability (Inngest-style) is chosen over positional history (Temporal-style) to make cross-version evolution a compile-time/lint problem rather than a runtime non-determinism nightmare. Three open questions are forwarded to EP-6: kiroku-side prefix-style category subscriptions for `pm:`/`wf:` streams, a keiki-side `compensate` direction on `SymTransducer`, and shibuya-side hosting of the timer-firing worker. Design-only. Produced by ExecPlan EP-5 of the research-foundation MasterPlan.
- `11-upstream-roadmap.md` — Synthesis of every upstream feature gap identified by EP-1 through EP-5 into a single prioritised backlog the kiroku, keiki, shibuya-core, and shibuya-kiroku-adapter maintainers can schedule against. Seventeen entries plus three cross-cutting items plus six explicitly-not-gaps, organised by upstream project, sequenced in four blocks. One **Blocking** item gated keiro v1 implementation when EP-6 was authored: kiroku-store's single-stream `runInTransaction` combinator. **As of 2026-05-10 this item has shipped** as `Kiroku.Store.Transaction.runTransactionAppending` (validated by EP-8's spike, which uses it directly for the Strong-consistency inline-projection scenario); the MasterPlan's Surprises & Discoveries entry of 2026-05-10 records the closure. Block 2 originally held six **Wanted** items that can land in parallel with v1 implementation and retire its workarounds: a Streamly-native single-stream forward read **(closed 2026-05-14 as `readStreamForwardStream`)**, a Postgres 18 deployment-docs note (still open), a `shibuya-kiroku-adapter` `HandlerInTransaction` shape that unblocks exactly-once async projections (still open), a keiki register-file `<-> Aeson.Value` helper plus shape hash shared with EP-1, EP-2, EP-4 **(both closed 2026-05-14 — `Keiki.Shape.regFileShapeHash` in core keiki + sibling package `keiki-codec-json`)**, and a structured error model on keiki's `step`/`omega` (still open). Block 4 *Optional* additionally lost three items 2026-05-14 — the `enrichEvent`/decoder hook (`Kiroku.Store.Settings`), `correlation_id`/`causation_id` walkers (`Kiroku.Store.Causation`), and the `lookupStreamId` helper (`Kiroku.Store.Read`). Three open questions are forwarded to upstream maintainers (codec ownership, compensate direction, supervisor generalisation). Design-only. Produced by ExecPlan EP-6 of the research-foundation MasterPlan.
- `12-read-model-query-api-and-lifecycle.md` — Design of keiro's read-side query surface: the typed `ReadModel q r` wrapper exposed by `Keiro.ReadModel` (carrying name, table, subscription, version, shape hash, default consistency mode, and the application's hasql query), the read-after-write **consistency-mode taxonomy** (`Strong` → inline projection in same tx as append; `Eventual` → async projection, default; `PositionWait { pwTimeoutMs }` → async + caller blocks on `subscriptions.last_seen >= target globalPosition`), the schema-evolution and rebuild protocol (eight-step shadow-table swap with a `keiro_read_models(name, version, shape_hash, last_built_at, status)` metadata table), the multi-stream read-model story (path (a) application-multiplexed N parallel subscriptions or path (b) kiroku prefix-style category subscription — preferred but requires the upstream gap EP-5 §9 already records), the idempotency-token propagation pattern (`source_event_id UUID NOT NULL UNIQUE`, `INSERT … ON CONFLICT DO NOTHING/UPDATE WHERE source_event_id IS DISTINCT`), the read-model-vs-snapshot-vs-projection three-way distinction (snapshots are advisory + internal; projections are workers; read models are queryable artefacts), and the polling-based position-wait helper (50–500 ms exponential back-off; LISTEN/NOTIFY deferred to v2 per the MasterPlan's general posture). Originally validated by a working spike at `spikes/read-model/` (three scenarios — inline / async + position-wait / position-wait timeout — all passed at EP-8 closure). The spike was retired on 2026-05-19 after its design migrated into the live keiro library (`Keiro.ReadModel`, `Keiro.ReadModel.Schema`, and the `Keiro.ReadModel` test group). Produced by ExecPlan EP-8 of the research-foundation MasterPlan.

The above five documents are *current-state* surveys. The MasterPlan (`docs/masterplans/1-keiro-research.md`) decomposes the *design* research that produces concrete keiro design proposals (load/decide/append cycle, codecs, subscriptions, snapshots, workflow roadmap, upstream gaps).

## The single most important question

How does keiro turn the cycle below into a first-class, type-safe, production-quality primitive?

1. Command arrives with a target stream id.
2. Load events for that stream from kiroku (possibly starting from a snapshot).
3. Fold events into the current aggregate state using keiki's `evolve`.
4. Run keiki's `decide(state, command)` to get an error or new events.
5. Append new events to kiroku with `ExpectedVersion = ExactVersion(loadedVersion)`.
6. On `WrongExpectedVersion` retry from step 2.

This cycle now exists in `Keiro.Command` as `runCommand` and its transactional
variants, behind the `ValidatedEventStream` replay-safety boundary. The section
is retained because designing it (and the supporting codecs, snapshots,
subscriptions, process managers, transactional steps, and timers) was the
original purpose of the research program.

## Headline findings (cross-document synthesis)

- **kiroku is solid** for append/read with optimistic concurrency. Crucially,
  kiroku's Strategy E gives gap-free contiguous global positions with immediate
  read-your-own-writes. The transaction, streaming read, enrichment, causation,
  and stream-id primitives identified by the research have shipped. Keiro now
  owns the typed codecs/streams, snapshots, command cycle, and fenced read-model
  rebuilds on top. Point-in-time replay and an upstream transactional
  subscription handler remain demand-driven gaps; exact category subscriptions
  plus Keiro's consumer-group sharding cover the current scaling path.
- **keiki's contract for keiro is `SymTransducer`, not `Decider`.** Keiro uses
  the native symbolic transducer and typed register file. Keiki now supplies the
  JSON/shape support and structured replay validation/failures used by Keiro's
  `ValidatedEventStream` and typed hydration errors. Effectful reads remain
  outside pure aggregate decision, and compensation remains application-owned.
- **shibuya is production-grade** for queue processing with NQE supervision and OpenTelemetry. Missing: transactional checkpoint+side-effect outbox, process-manager primitive (which keiro provides on top of `SymTransducer`), durable timers, aggregate snapshot loading, multi-source correlation.
- **The kiroku × keiki integration has shipped.** `Keiro.Command` performs
  streaming hydration, typed replay failure reporting, deterministic decision,
  optimistic append/retry, transactional SQL/projection continuations, event
  enrichment, post-append replay witnessing, and advisory snapshots. Public
  runners require a `ValidatedEventStream` whose Keiki 0.2 validation includes
  head recoverability, inversion ambiguity, guarded input reads, and
  state-changing epsilon checks.
- **Prior art consensus**: Postgres-native + library-shaped wins at our scale (DBOS, Marten). Defer Temporal/Restate-style deterministic-replay durable execution to v2; for v1 ship event-sourced process managers (~90% of workflow needs). Adopt DBOS's transactional step. *Do not* adopt Marten's high-water-mark — kiroku's Strategy E supersedes it. *Do not* adopt the Chassaing decider facade as the contract — use `SymTransducer` directly.
