# Keiro Roadmap

This roadmap translates the internal plans in `docs/masterplans/`,
`docs/plans/`, and `docs/research/` into the user-visible delivery path. It is
written for teams planning adoption: what exists now, what is expected next, and
which workflow features are deliberately later.

This is not a date commitment. It is the intended order and shape of the work.

The current baseline reflects the `0.1.0.0` release. See `CHANGELOG.md` for the
exact released surface and `docs/user/production-status.md` for adoption posture.

## At A Glance

| Phase | Theme | User-visible outcome |
|---|---|---|
| Current baseline | Event-sourcing v1 core (0.1.0.0) | The full v1 substrate — commands (multi-event), codecs, snapshots, read models, process managers, routers, timers, outbox, inbox, integration events, OpenTelemetry tracing, and migrations — is released for controlled internal use, with a worked-examples app and long-form guides. |
| Phase 1 | Stabilize existing core | Complete: multi-event command output landed, the repository test suite exercises the core paths, and migrations/snapshots have production guidance. |
| Phase 2 | Complete v1 workflow substrate | Outbox and inbox shipped. Remaining: process-manager hardening guidance and worker metrics (tracing spans are already in). |
| Phase 3 | Read-side maturity | Async projections, subscriptions, and position waits get stronger consistency and scaling options. |
| Phase 4 | Adoption and ergonomics | The worked-examples app and guides exist; remaining work is full Haddocks, a public stability policy, and higher-level facades. |
| Phase 5 | v2 durable execution | Named-step workflow execution, awakeables, child workflows, and continue-as-new layer on top of the v1 substrate. |

## Capability Matrix

| Capability | Status | Notes |
|---|---|---|
| Typed streams, codecs, upcasters | Available now | Public v1 authoring surface. |
| Command cycle | Available now | `runCommand`, optimistic retry, caller-supplied event ids, same-transaction SQL continuations, and ambient command metadata. |
| Multi-event command output | Available now | One command appends zero, one, or many events in one optimistic-concurrency batch. |
| Snapshots | Available now | Default codec uses `keiki-codec-json` and `regFileShapeHash`; snapshot hydration plus tail replay is tested. |
| Read models and projections | Available now | Inline is transactional and receives `RecordedEvent` metadata; async is at-least-once today. |
| Process managers | Available now | V1 workflow substrate for sagas and choreography. |
| Routers (effectful fan-out) | Available now | `Keiro.Router`: stateless content-based router / recipient list; targets resolved effectfully from read models. |
| Durable timers | Available now | Polling worker and timer table exist; operational hardening guidance remains. |
| codd migrations | Available now | `keiro-migrate` applies Kiroku and Keiro framework tables, including `keiro_outbox` and `keiro_inbox`. |
| Transactional outbox | Available now | `Keiro.Outbox` + `keiro_outbox`: per-key ordering, backoff, dead-lettering, and a Kafka producer adapter. |
| Inbox deduplication | Available now | `Keiro.Inbox` + `keiro_inbox`: claim/retry/release/dead transitions, GC, and Shibuya + Kafka adapters. |
| Integration events | Available now | `Keiro.Integration.Event`: canonical cross-context envelope with W3C trace context and Kafka header helpers. |
| OpenTelemetry tracing | Available now | `Keiro.Telemetry`: Internal (command), Producer (outbox), and Consumer spans; opt-in via `RunCommandOptions.tracer`. |
| Worker metrics | Planned v1.x | Projection lag, timer/outbox backlog, duplicate, and dead-letter metrics are not yet exposed (only spans are). |
| Exactly-once async projections | Planned v1.x / upstream-dependent | Blocks on transactional Shibuya/Kiroku checkpoint handling. |
| Prefix subscriptions | Planned v1.x / upstream-dependent | Needed for `pm:` and future `wf:` stream families at scale. |
| Durable execution runtime | Planned v2 | Named-step `Workflow es a`, awakeables, child workflows, continue-as-new. |

## Current Baseline

Keiro v1 is a library-shaped event-sourcing framework on PostgreSQL, released as
`0.1.0.0`.

Implemented today:

- typed stream names through `Keiro.Stream`;
- event codecs, schema versions, known event-type validation, and upcasters
  through `Keiro.Codec`;
- the author-facing `EventStream` contract around Keiki `SymTransducer`;
- `runCommand` with optimistic concurrency retry, caller-supplied event ids,
  ambient metadata, multi-event command output, and same-transaction SQL
  continuations;
- advisory snapshots for faster hydration;
- read-model metadata, inline projections (which receive `RecordedEvent`
  metadata), async projection helpers, position waits, and rebuild scaffolding;
- event-sourced process managers;
- routers for stateless, effectful fan-out (`Keiro.Router`);
- durable timer storage and polling workers;
- a transactional outbox (`Keiro.Outbox`) with per-key ordering, backoff,
  dead-lettering, and a Kafka producer adapter;
- an idempotent inbox (`Keiro.Inbox`) with claim/retry/release/dead
  transitions, GC, and Shibuya + Kafka adapters;
- the cross-context integration-event envelope (`Keiro.Integration.Event`);
- OpenTelemetry command/producer/consumer spans (`Keiro.Telemetry`);
- embedded codd migrations for Kiroku and Keiro framework tables;
- the `jitsurei` worked-examples package and long-form guides under
  `docs/guides/`.

Current adoption posture:

- Good fit for controlled internal use where the team owns deployment,
  dependency revisions, migrations, and worker operations.
- Not yet a polished public framework with stable third-party API guarantees and
  full Haddocks.
- Async handlers must be idempotent until exactly-once checkpoint handling
  lands.

## Phase 1: Stabilize Existing Core (Complete)

Goal: make the implemented v1 baseline coherent with current dependency APIs
and production migration workflow. This phase shipped in `0.1.0.0`.

| Work item | Status | Outcome |
|---|---|---|
| Multi-event command output | Complete | One command appends zero, one, or many events in one optimistic-concurrency batch. |
| Migration validation | Complete | `keiro-migrate` is exercised by the test suite and documented as the production path. |
| Snapshot codec close-out | Complete | Snapshot hydration plus tail replay is tested; `StateCodec` usage is documented. |

### Multi-event command output

Keiki allows one accepted command to emit zero, one, or many events, and Keiro
adopts that shape end to end:

- `runCommand` appends the whole emitted event batch in order.
- `eventsAppended` reports the batch length.
- Hydration replays stored multi-event command output correctly.
- Snapshots see the final settled state after the whole emitted batch.
- Inline projections and `runCommandWithSqlEvents` receive every produced event.
- Process-manager and router dispatch remain idempotent when a command emits
  multiple events.

User impact: command handlers can model richer domain transitions without
forcing artificial one-event commands.

### Migration validation

`keiro-migrate` applies Kiroku and Keiro framework migrations through codd,
including the `keiro_outbox` and `keiro_inbox` tables.

Production path:

- Run codd migrations before application startup.
- Start Kiroku with runtime schema initialization disabled.
- Keep application read-model tables in the application's own migration set.
- Compose service migrations after `Keiro.Migrations.allKeiroMigrations` when a
  service also uses codd.

User impact: teams get one explicit migration entry point for the event store
plus Keiro framework tables.

### Snapshot codec close-out

Keiro uses `keiki-codec-json` and `regFileShapeHash` in the default snapshot
codec.

Delivered:

- Snapshot hydration plus tail replay is covered by the test suite.
- Guidance on when authors use Keiro `StateCodec` versus direct
  `Keiki.Codec.JSON` helpers is documented in `docs/user/snapshots.md`.

Remaining nicety: published performance numbers for moderately large register
files.

User impact: long-lived streams and process-manager state streams can use
snapshots without hand-written register-file walkers.

## Phase 2: Complete v1 Workflow Substrate

Goal: finish the v1 workflow features that sit between "process managers and
timers exist" and "teams can run real saga/choreography workflows comfortably."
The outbox and inbox shipped in `0.1.0.0`; the remaining work is hardening
guidance and worker metrics.

| Work item | Status | API or table | Outcome |
|---|---|---|---|
| Transactional outbox | Available now | `Keiro.Outbox`, `keiro_outbox` | Side-effect intents are committed atomically with event/projection writes and delivered asynchronously. |
| Inbox deduplication | Available now | `Keiro.Inbox`, `keiro_inbox` | External messages are handled idempotently by `(source, message_id)`. |
| OpenTelemetry tracing | Available now | `Keiro.Telemetry` | Command, producer, and consumer spans are emitted, with W3C trace-context propagation. |
| Process-manager hardening | Partially complete | `Keiro.ProcessManager`, `Keiro.Timer` docs | Deterministic command ids, correlation/causation metadata, and the `pm:` convention exist; snapshot, timer-recovery, and retry guidance remain. |
| Worker metrics | Planned | Metrics | Operators can see projection lag, timer backlog, outbox backlog, duplicates, and dead letters. |

### Transactional outbox (Available now)

The outbox is for side effects that cannot safely run inside the database
transaction: HTTP calls, email, webhooks, downstream queues, and third-party API
requests.

As shipped:

- `keiro_outbox` stores side-effect intents written inside the same transaction
  as an event append, inline projection, or process-manager state advance.
- Each row records destination, payload, attempt count, backoff schedule, and
  correlation/causation attributes.
- `claimOutboxBatch` claims rows for a worker; `publishClaimedOutbox` publishes
  them with per-key (head-of-line) ordering.
- Rows are dead-lettered after a configurable max-attempt count.
- A Kafka producer adapter ships with the library.
- Downstream delivery remains at-least-once, so external handlers must be
  idempotent.

User impact: handlers can request external side effects without making network
calls inside the database transaction.

### Inbox deduplication (Available now)

The inbox is the receive-side dual of the outbox.

As shipped:

- `keiro_inbox` records external messages keyed by `(source, message_id)`.
- Handlers run inside `runInboxTransaction` / `runInboxTransactionWithKey`, with
  claim/retry/release/dead transitions.
- Duplicate external deliveries short-circuit safely.
- `garbageCollectCompleted` reclaims completed rows.
- Shibuya and Kafka consumer adapters ship with the library.

User impact: pgmq, webhook, Kafka, and external-message consumers get a standard
duplicate-detection path.

### Process-manager workflow hardening

Process managers (and routers) are the v1 workflow substrate. Some hardening is
in place; the rest is operational polish around state, timers, and recovery.

Already in place:

- Deterministic command ids derived from process-manager name, correlation id,
  source event id, and emit index.
- Causation and correlation metadata carried on emitted commands.
- The `pm:<name>-<correlation>` state-stream convention.

Remaining:

- Recommend snapshot policies for long-running process managers.
- Document timer stuck-row recovery and retry policy.
- Expose worker metrics (see below).

User impact: v1 covers sagas and choreography workflows without a separate
durable-execution runtime.

### Worker metrics

Tracing spans are emitted today through `Keiro.Telemetry`. The remaining
observability work is metrics: projection lag, timer backlog, outbox backlog,
duplicate counts, and dead-letter counts, so operators can alert on workers
rather than only trace individual runs.

## Phase 3: Read-side And Subscription Maturity

Goal: improve consistency, scaling, and latency for projections and
subscriptions.

| Work item | Status | Constraint | Expected outcome |
|---|---|---|---|
| Exactly-once async projections | Upstream-dependent | Needs transactional Shibuya/Kiroku checkpoint handling | User SQL and checkpoint advancement commit together. |
| Prefix subscriptions | Upstream-dependent | Needs Kiroku subscription target beyond exact category | `pm:`, future `wf:`, and multi-stream families become easier to observe. |
| LISTEN/NOTIFY waits | Planned | Adds long-lived DB connections | `PositionWait` can wake by notification instead of polling. |

### Exactly-once async projections

Current async projections are at-least-once. The missing upstream shape is a
Shibuya/Kiroku handler that runs user SQL and subscription checkpoint advancement
in one transaction.

Until that lands:

- async projection handlers must be idempotent;
- `source_event_id` or equivalent unique keys are the recommended dedup path;
- inline projections remain the strongly consistent read-side path.

After it lands:

- async projection writes and checkpoint advancement commit atomically;
- many user-side dedup tables become optional rather than mandatory;
- the same transaction boundary can support process-manager subscription
  handlers where exact checkpointing matters.

### Category and prefix subscriptions

Kiroku currently supports all-stream or exact-category subscriptions. Keiro
needs prefix-style subscriptions for larger deployments.

Expected uses:

- observe every process-manager stream under `pm:`;
- observe every future workflow stream under `wf:`;
- support multi-stream read models without registering every stream family
  manually.

Near-term workaround: register one subscription per known category or process
manager. Prefix subscriptions are the scaling and operability improvement.

### Position waits and push delivery

Position waits currently use polling. A later v1 improvement can add
LISTEN/NOTIFY-backed wakeups.

Benefits:

- lower read-after-write latency for `PositionWait`;
- fewer polling queries under high request volume.

Tradeoff: LISTEN/NOTIFY consumes long-lived database connections and complicates
connection-pool sizing. It is useful, but not required for correctness.

## Phase 4: Adoption And API Ergonomics

Goal: make the library easier to learn, operate, and upgrade.

| Work item | Status | Expected outcome |
|---|---|---|
| Worked-examples app | Available now | `jitsurei` shows commands, snapshots, read models, PMs, routers, timers, outbox, inbox, and integration events together. |
| Long-form guides | Available now | `docs/guides/` covers the command side, event evolution, read models, PMs & timers, snapshots, integration events, routers, and a combined incident-response example. |
| Haddocks | Partially complete | Each public module gets reference docs and copy-pasteable examples. |
| Stability policy | Planned | Users know what can break before a stronger public API milestone. |
| Read-model migration guide | Planned | Application-owned query tables have clear migration ownership. |
| Decider-style facade | Exploratory | A higher-level pure-CQRS wrapper may reduce authoring friction if it stays thin. |

Remaining work:

- Broader Haddocks for each public module.
- Public stability policy for API changes and migration compatibility.
- Release discipline around dependency pinning and local sibling packages.
- Stronger docs for application-owned read-model migrations.
- Production checklist covering workers, dead letters, timer repair, outbox
  drain repair, projection rebuilds, and snapshot GC.

The exploratory Decider-style facade belongs here only if real examples prove it
helps. It should remain a wrapper over `EventStream` and `runCommand`, not a
second framework model.

## Phase 5: v2 Durable Execution

Goal: add a durable-execution runtime without replacing the v1 event-sourcing
and process-manager substrate.

V1 workflow means:

- process managers;
- routers;
- durable timers;
- outbox and inbox;
- projections;
- idempotent commands;
- snapshots for long-lived state streams.

V2 durable execution means journaled functions with named steps.

| Feature | Planned v2 shape |
|---|---|
| Authoring model | `Workflow es a` |
| Durable side effects | `step "name" action` journals a result by explicit step name. |
| Replay | Recorded step results are returned without re-running side effects. |
| Sleep | Backed by the v1 timer table. |
| Journal storage | Kiroku streams named `wf:<workflow-name>-<workflow-id>`. |
| Step lookup | `keiro_workflow_steps` indexes journaled steps for fast lookup. |
| External completion | `keiro_awakeables` stores externally completed durable promises. |
| Child workflows | Parent journals child handles so it can wait on or cancel them. |
| Continue-as-new | Long workflow histories rotate without losing state. |

The key design decision is named steps, not positional history. Step identity is
explicit and stable across source-code reordering, avoiding Temporal-style
runtime nondeterminism caused by ordinary code movement.

User impact: teams can write imperative long-running workflows with durable
checkpoints, sleeps, external completion handles, and child workflows, without
adopting a separate workflow server.

## Durable Execution Boundaries

The v2 runtime is intentionally deferred because it adds a large operational and
compatibility surface.

Required before v2 can be treated as production-shaped:

- step-result codecs and schema evolution;
- versioning or patch APIs for changed workflow logic;
- unfinished-workflow discovery and resume workers;
- stuck awakeable repair;
- long-history compaction or continue-as-new;
- child-workflow cancellation semantics;
- observability for journal replay versus live execution.

Why v1 is still the right foundation:

- A process manager is effectively a workflow with explicit event-driven steps.
- The v2 runtime layers journaled named steps on the same Kiroku event log.
- V2 reuses the command cycle, timers, snapshots, codecs, migration story, and
  worker conventions from v1.

## Longer-term Possibilities

These are intentionally outside the current v1 and v2 commitments.

| Possibility | Why later |
|---|---|
| Consumer-group sharding | Needed only for very high-volume category subscriptions. |
| Cluster-aware leadership | Current Postgres/advisory-lock conventions are enough for v1. |
| Schema registry | Most useful for multi-team or polyglot event consumers. |
| Field-level encryption | Requires application-specific key-management choices. |
| Multi-region operation | Requires a global-ordering story outside the current single-Postgres design. |
| Binary or compressed snapshots | Useful for hot, large states; JSON remains operator-friendly for v1. |
| Operator CLIs | Useful for snapshot rebuilds, projection rebuilds, outbox repair, and timer repair. |

Server-side scripted projections are not on the roadmap. The design explicitly
rejects that model because it is operationally fragile and hard to debug.
