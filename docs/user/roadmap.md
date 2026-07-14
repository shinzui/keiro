# Keiro Roadmap

This roadmap translates the internal plans in `docs/masterplans/`,
`docs/plans/`, and `docs/research/` into the user-visible delivery path. It is
written for teams planning adoption: what exists now, what is expected next, and
which workflow features are deliberately later.

This is not a date commitment. It is the intended order and shape of the work.

The current baseline includes `0.1.0.0` plus the unreleased hardening described
in `CHANGELOG.md`. See `docs/user/production-status.md` for adoption posture.

## At A Glance

| Phase | Theme | User-visible outcome |
|---|---|---|
| Current baseline | Event-sourcing v1 core (0.1.0.0) | The full v1 substrate — commands (multi-event), codecs, snapshots, read models, process managers, routers, timers, outbox, inbox, integration events, OpenTelemetry tracing, and migrations — is released for controlled internal use, with a worked-examples app and long-form guides. |
| Phase 1 | Stabilize existing core | Complete: multi-event command output landed, the repository test suite exercises the core paths, and migrations/snapshots have production guidance. |
| Phase 2 | Complete v1 workflow substrate | Complete: outbox, inbox, OpenTelemetry tracing and metrics, process-manager snapshot guidance, and the timer stuck-row recovery API and runbook. |
| Phase 3 | Read-side maturity | Async projections, subscriptions, and position waits get stronger consistency and scaling options. |
| Phase 4 | Adoption and ergonomics | The worked-examples app and guides exist; remaining work is full Haddocks, a public stability policy, and higher-level facades. |
| Phase 5 | v2 durable execution | Complete: a named-step `Workflow es a` runtime with durable sleep, awakeables, child workflows, a crash-recovery resume worker, journal snapshots, and `keiro.workflow.*` observability ships on top of the v1 substrate. Phase-2 additions (MasterPlan 6) add continue-as-new journal rotation (`continueAsNew`/`restoreSeed`), the versioning/patch API (`patch`), LISTEN/NOTIFY push delivery (`Keiro.Wake`), and consumer-group sharding for category subscriptions (`Keiro.Subscription.Shard`). |

## Capability Matrix

| Capability | Status | Notes |
|---|---|---|
| Typed streams, codecs, upcasters | Available now | Public v1 authoring surface. |
| Command cycle | Available now | `runCommand`, `ValidatedEventStream` replayability checks, optimistic retry, caller-supplied event ids, same-transaction SQL continuations, and ambient command metadata. |
| Multi-event command output | Available now | One command appends zero, one, or many events in one optimistic-concurrency batch. |
| Snapshots | Available now | Default codec uses `keiki-codec-json` and `regFileShapeHash`; snapshot hydration plus tail replay is tested. |
| Read models and projections | Available now | Inline is transactional and receives `RecordedEvent` metadata; async is at-least-once today. |
| Process managers | Available now | V1 workflow substrate for sagas and choreography. |
| Routers (effectful fan-out) | Available now | `Keiro.Router`: stateless content-based router / recipient list; targets resolved effectfully from read models. |
| Durable timers | Available now | Polling worker, timer table, and a stuck-row recovery API (find/requeue/cancel/dead-letter) with an operations runbook. |
| Native migrations | Available now | `keiro-migrate` composes Kiroku and Keiro `pg-migrate` components in dependency order, including `keiro_outbox`, `keiro_inbox`, and dispatch dead letters. |
| Transactional outbox | Available now | `Keiro.Outbox` + `keiro_outbox`: per-key ordering, backoff, dead-lettering, and a Kafka producer adapter. |
| Inbox deduplication | Available now | `Keiro.Inbox` + `keiro_inbox`: claim/retry/release/dead transitions, GC, and Shibuya + Kafka adapters. |
| Integration events | Available now | `Keiro.Integration.Event`: canonical cross-context envelope with W3C trace context and Kafka header helpers. |
| OpenTelemetry tracing | Available now | `Keiro.Telemetry`: Internal (command), Producer (outbox), and Consumer spans; opt-in via `RunCommandOptions.tracer`. |
| Worker metrics | Available now | `Keiro.Telemetry` exposes opt-in OpenTelemetry metrics for outbox, inbox, timer, and async-projection workers (backlog, lag, duplicate, dead-letter, and stuck-timer instruments). |
| Typed service specifications | Available now | `keiro-dsl` checks, scaffolds, emits conformance harnesses, and classifies persistence-aware evolution across aggregate, coordination, integration, queue, read-model, and workflow nodes. |
| Exactly-once async projections | Planned v1.x / upstream-dependent | Blocks on transactional Shibuya/Kiroku checkpoint handling. |
| Prefix subscriptions | Planned v1.x / upstream-dependent | Needed for `pm:` and future `wf:` stream families at scale. |
| Durable execution runtime | Available now | `Keiro.Workflow`: named-step `Workflow es a`, durable `sleep`, awakeables, child workflows, a crash-recovery resume worker, and journal snapshots (`keiro_workflow_steps` + `keiro_awakeables`). Continue-as-new journal rotation (`continueAsNew`/`restoreSeed`) keeps unbounded histories bounded; the `patch` API gives stable, journaled branch decisions for cross-cutting workflow-logic changes. |

## Current Baseline

Keiro v1 is a library-shaped event-sourcing framework on PostgreSQL, released as
`0.1.0.0`.

Implemented today:

- typed stream names through `Keiro.Stream`;
- event codecs, schema versions, known event-type validation, and upcasters
  through `Keiro.Codec`;
- the author-facing `EventStream` contract around Keiki `SymTransducer`, plus
  the `ValidatedEventStream` command boundary for replayability safety;
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
- OpenTelemetry command/producer/consumer spans and opt-in worker metrics
  (`Keiro.Telemetry`);
- native `pg-migrate` components for Kiroku and Keiro framework tables;
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

`keiro-migrate` applies Kiroku and Keiro framework migrations through
`pg-migrate`,
including the `keiro_outbox` and `keiro_inbox` tables.

Production path:

- Run the composed native migration plan before application startup.
- Start Kiroku with runtime schema initialization disabled.
- Keep application read-model tables in the application's own migration set.
- Compose application-owned `MigrationComponent` values after the Kiroku and
  Keiro components when one executable owns the whole database plan.

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
The outbox and inbox shipped in `0.1.0.0`; the process-manager hardening
guidance and worker metrics have since shipped, completing this phase.

| Work item | Status | API or table | Outcome |
|---|---|---|---|
| Transactional outbox | Available now | `Keiro.Outbox`, `keiro_outbox` | Side-effect intents are committed atomically with event/projection writes and delivered asynchronously. |
| Inbox deduplication | Available now | `Keiro.Inbox`, `keiro_inbox` | External messages are handled idempotently by `(source, message_id)`. |
| OpenTelemetry tracing | Available now | `Keiro.Telemetry` | Command, producer, and consumer spans are emitted, with W3C trace-context propagation. |
| Process-manager hardening | Complete | `Keiro.ProcessManager`, `Keiro.Timer` | Deterministic command ids, correlation/causation metadata, the `pm:` convention, snapshot-policy guidance with a tested PM-snapshot example, and a timer stuck-row recovery API plus runbook. |
| Worker metrics | Complete | `Keiro.Telemetry` metrics | Operators can see projection lag, timer/outbox/inbox backlog, fire lag, duplicates, dead letters, and stuck timers on a metrics exporter. |

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

### Process-manager workflow hardening (Complete)

Process managers (and routers) are the v1 workflow substrate. The hardening work
is now complete: the operational polish around state, timers, and recovery shipped.

Already in place:

- Deterministic command ids derived from process-manager name, correlation id,
  source event id, and emit index.
- Causation and correlation metadata carried on emitted commands.
- The `pm:<name>-<correlation>` state-stream convention.
- Snapshot-policy guidance for long-running managers, backed by a tested
  PM-state-stream snapshot example (`docs/user/snapshots.md`,
  `describe "Keiro.ProcessManager snapshots"` in `keiro/test/Main.hs`).
- A timer stuck-row recovery API (`findStuckTimers`, `requeueStuckTimer`,
  `cancelTimer`, `deadLetterTimer`, and a `maxAttempts` worker option) with the
  recovery runbook in `docs/user/operations.md`.
- Worker metrics (see below).

User impact: v1 covers sagas and choreography workflows without a separate
durable-execution runtime.

### Worker metrics (Complete)

Tracing spans were already emitted through `Keiro.Telemetry`; worker metrics have
now shipped alongside them. The instrument set is opt-in via an SDK `Meter`
(`newKeiroMetrics`) and no-op by default, covering the four worker families:
outbox, inbox, timer, and async-projection backlog/lag gauges plus
published/retried/dead-lettered/processed/duplicate/failed/wait-timeout counters
and timer fire-lag and attempt histograms — so operators can alert on workers
rather than only trace individual runs. See the metric catalogue in
`docs/user/operations.md`.

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

Shipped: a durable-execution runtime (`Keiro.Workflow`) that layers on top of —
and does not replace — the v1 event-sourcing and process-manager substrate.

V1 workflow means:

- process managers;
- routers;
- durable timers;
- outbox and inbox;
- projections;
- idempotent commands;
- snapshots for long-lived state streams.

V2 durable execution means journaled functions with named steps.

| Feature | Shipped v2 shape |
|---|---|
| Authoring model | `Workflow es a` |
| Durable side effects | `step "name" action` journals a result by explicit step name. |
| Replay | Recorded step results are returned without re-running side effects. |
| Sleep | `sleepNamed`/`sleep`, backed by the v1 timer table. |
| Journal storage | Kiroku streams named `wf:<workflow-name>-<workflow-id>`. |
| Step lookup | `keiro_workflow_steps` indexes journaled steps for fast lookup. |
| External completion | `keiro_awakeables` stores externally completed durable promises (`awakeable`/`signalAwakeable`/`cancelAwakeable`). |
| Child workflows | Parent journals child handles so it can `spawnChild`/`awaitChild`/`cancelChild`. |
| Resume worker | `resumeWorkflowsOnce` discovers and re-invokes unfinished workflows from a registry. |
| Snapshots | `runWorkflowWith` + `snapshotPolicy` compact long journals via `workflowStateCodec`. |
| Observability | `keiro.workflow.*` metrics and a `workflow <name>` span. |
| Continue-as-new | **Available** — `continueAsNew`/`restoreSeed` rotate a long-running workflow onto a fresh journal generation, keeping per-generation history bounded without losing state (§6.4, MasterPlan 6). |
| Versioning / patch | **Available** — `patch :: PatchId -> Eff es Bool` gives a stable, journaled branch decision so in-flight instances keep old logic while fresh ones take new logic across step boundaries (§6.5, MasterPlan 6). Prefer renaming a step for single-step changes. |

The key design decision is named steps, not positional history. Step identity is
explicit and stable across source-code reordering, avoiding Temporal-style
runtime nondeterminism caused by ordinary code movement.

User impact: teams can now write imperative long-running workflows with durable
checkpoints, sleeps, external completion handles, and child workflows, without
adopting a separate workflow server. See the
[Durable Workflows guide](../guides/durable-workflows.md) and the
[user reference](durable-workflows.md).

## Durable Execution Boundaries

The v2 runtime now ships; the items below record what was required to treat it as
production-shaped and which pieces remain genuinely deferred.

Delivered (EP-38…EP-44 under MasterPlan 5):

- step-result codecs and schema evolution (per-step `ToJSON`/`FromJSON`);
- unfinished-workflow discovery and a crash-recovery resume worker;
- stuck awakeable repair (`cancelAwakeable`);
- child-workflow cancellation semantics (`cancelChild`);
- observability for journal replay versus live execution
  (`keiro.workflow.steps.replayed` vs `keiro.workflow.steps.executed`).

Delivered in phase 2 (EP-48…EP-51 under MasterPlan 6):

- continue-as-new journal rotation for unbounded histories
  (`continueAsNew`/`restoreSeed`);
- the versioning / patch API for cross-cutting workflow-logic changes (`patch`);
- LISTEN/NOTIFY push delivery for the resume worker and subscription loops
  (`Keiro.Wake`, push-aware `runWorkflowResumeWorkerPush`) — sub-second wakeups
  with a durable poll fallback, adding no new connections (§6.11);
- consumer-group sharding for category subscriptions
  (`Keiro.Subscription.Shard`, `runShardedSubscriptionGroup`) — a pool of
  identical workers leases kiroku consumer-group buckets, draining a category
  disjointly with automatic, coordinator-free failover (§6.8–§6.9).

Still deferred (rejected or demand-driven, see §6 of the workflow roadmap):

- multi-region / global ordering, server-side scripted projections, the schema
  registry, and field-level encryption (§6.6, §6.7, §6.10, §6.12).

Why v1 is still the right foundation:

- A process manager is effectively a workflow with explicit event-driven steps.
- The v2 runtime layers journaled named steps on the same Kiroku event log.
- V2 reuses the command cycle, timers, snapshots, codecs, migration story, and
  worker conventions from v1.

## Longer-term Possibilities

These are intentionally outside the current v1 and v2 commitments.

| Possibility | Why later |
|---|---|
| Schema registry | Most useful for multi-team or polyglot event consumers. |
| Field-level encryption | Requires application-specific key-management choices. |
| Multi-region operation | Requires a global-ordering story outside the current single-Postgres design. |
| Binary or compressed snapshots | Useful for hot, large states; JSON remains operator-friendly for v1. |
| Operator CLIs | Useful for snapshot rebuilds, projection rebuilds, outbox repair, and timer repair. |

Server-side scripted projections are not on the roadmap. The design explicitly
rejects that model because it is operationally fragile and hard to debug.
