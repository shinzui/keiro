# Keiro Roadmap

This roadmap translates the internal plans in `docs/masterplans/`,
`docs/plans/`, and `docs/research/` into the user-visible delivery path. It is
written for teams planning adoption: what exists now, what is expected next, and
which workflow features are deliberately later.

This is not a date commitment. It is the intended order and shape of the work.

## At A Glance

| Phase | Theme | User-visible outcome |
|---|---|---|
| Current baseline | Event-sourcing v1 core | Commands, codecs, snapshots, read models, process managers, timers, and framework migrations are available for controlled internal use. |
| Phase 1 | Stabilize existing core | Keiro matches current Keiki APIs, the full test suite is green, and migrations/snapshots have clear production guidance. |
| Phase 2 | Complete v1 workflow substrate | Outbox, inbox, process-manager hardening, and worker observability make v1 viable for saga and choreography workflows. |
| Phase 3 | Read-side maturity | Async projections, subscriptions, and position waits get stronger consistency and scaling options. |
| Phase 4 | Adoption and ergonomics | Examples, Haddocks, public stability guidance, and higher-level facades make the library easier to adopt. |
| Phase 5 | v2 durable execution | Named-step workflow execution, awakeables, child workflows, and continue-as-new layer on top of the v1 substrate. |

## Capability Matrix

| Capability | Status | Notes |
|---|---|---|
| Typed streams, codecs, upcasters | Available now | Public v1 authoring surface. |
| Command cycle | Available now | `runCommand`, optimistic retry, event ids, and same-transaction SQL continuations. |
| Multi-event command output | In progress | Required to match latest Keiki output shape. |
| Snapshots | Available now, validation close-out pending | Default codec uses `keiki-codec-json`; full-replay equivalence proof remains. |
| Read models and projections | Available now | Inline is transactional; async is at-least-once today. |
| Process managers | Available now | V1 workflow substrate for sagas and choreography. |
| Durable timers | Available now | Polling worker and timer table exist; operational hardening remains. |
| codd migrations | Available now, validation close-out pending | `keiro-migrate` applies Kiroku and Keiro framework tables. |
| Transactional outbox | Planned v1.x | Designed, but no public `Keiro.Outbox` API yet. |
| Inbox deduplication | Planned v1.x | Designed, but no public `Keiro.Inbox` API yet. |
| Exactly-once async projections | Planned v1.x / upstream-dependent | Blocks on transactional Shibuya/Kiroku checkpoint handling. |
| Prefix subscriptions | Planned v1.x / upstream-dependent | Needed for `pm:` and future `wf:` stream families at scale. |
| Durable execution runtime | Planned v2 | Named-step `Workflow es a`, awakeables, child workflows, continue-as-new. |

## Current Baseline

Keiro v1 is a library-shaped event-sourcing framework on PostgreSQL.

Implemented today:

- typed stream names through `Keiro.Stream`;
- event codecs, schema versions, known event-type validation, and upcasters
  through `Keiro.Codec`;
- the author-facing `EventStream` contract around Keiki `SymTransducer`;
- `runCommand`, optimistic concurrency retry, caller-supplied event ids, and
  same-transaction SQL continuations;
- advisory snapshots for faster hydration;
- read-model metadata, inline projections, async projection helpers, position
  waits, and rebuild scaffolding;
- event-sourced process managers;
- durable timer storage and polling workers;
- embedded codd migrations for Kiroku and Keiro framework tables.

Current adoption posture:

- Good fit for controlled internal use where the team owns deployment,
  dependency revisions, migrations, and worker operations.
- Not yet a polished public framework with stable third-party API guarantees,
  complete examples, and full Haddocks.
- Async handlers must be idempotent until exactly-once checkpoint handling
  lands.

## Phase 1: Stabilize Existing Core

Goal: make the implemented v1 baseline coherent with current dependency APIs
and production migration workflow.

| Work item | Status | Depends on | Expected outcome |
|---|---|---|---|
| Multi-event command output | In progress | Latest Keiki API | One command can append zero, one, or many events in one optimistic-concurrency batch. |
| Migration validation | Partially complete | Multi-event compile fix | `keiro-migrate` is validated with the full test suite and documented as the production path. |
| Snapshot codec close-out | Partially complete | Multi-event compile fix | Snapshot hydration, full replay equivalence, and `StateCodec` usage guidance are complete. |

### Multi-event command output

Keiki now allows one accepted command to emit zero, one, or many events. Keiro
must adopt that shape end to end.

Deliverables:

- `runCommand` appends the whole emitted event batch in order.
- `eventsAppended` reports the batch length.
- Hydration replays stored multi-event command output correctly.
- Snapshots see the final settled state after the whole emitted batch.
- Inline projections and `runCommandWithSqlEvents` receive every produced event.
- Process-manager dispatch remains idempotent when a command emits multiple
  events.

User impact: command handlers can model richer domain transitions without
forcing artificial one-event commands.

### Migration validation

`keiro-migrate` already applies Kiroku and Keiro framework migrations through
codd. The remaining work is to restore the full test suite after the multi-event
update and finish documenting the production path.

Deliverables:

- Run codd migrations before application startup.
- Start Kiroku with runtime schema initialization disabled.
- Keep application read-model tables in the application's own migration set.
- Compose service migrations after `Keiro.Migrations.allKeiroMigrations` when a
  service also uses codd.

User impact: teams get one explicit migration entry point for the event store
plus Keiro framework tables.

### Snapshot codec close-out

Keiro already uses `keiki-codec-json` and `regFileShapeHash` in the default
snapshot codec.

Deliverables:

- Prove snapshot hydration plus tail replay matches full replay for a
  non-trivial register file.
- Document when authors use Keiro `StateCodec` versus direct
  `Keiki.Codec.JSON` helpers.
- Record performance numbers for moderately large register files.

User impact: long-lived streams and process-manager state streams can use
snapshots without hand-written register-file walkers.

## Phase 2: Complete v1 Workflow Substrate

Goal: finish the v1 workflow features that sit between "process managers and
timers exist" and "teams can run real saga/choreography workflows comfortably."

| Work item | Status | Expected API or table | Expected outcome |
|---|---|---|---|
| Transactional outbox | Planned | `Keiro.Outbox`, `keiro_outbox` | Side-effect intents are committed atomically with event/projection writes and delivered asynchronously. |
| Inbox deduplication | Planned | `Keiro.Inbox`, `keiro_inbox` | External messages can be handled idempotently by `(source, message_id)`. |
| Process-manager hardening | Planned | `Keiro.ProcessManager`, `Keiro.Timer` docs and metrics | Sagas get clearer tracing, recovery, snapshot, timer, and worker guidance. |
| Worker observability | Planned | Metrics and spans | Operators can see projection lag, timer backlog, outbox backlog, duplicates, and dead letters. |

### Transactional outbox

The outbox is for side effects that cannot safely run inside the database
transaction: HTTP calls, email, webhooks, downstream queues, and third-party API
requests.

Expected design:

- `keiro_outbox` stores side-effect intents written inside the same transaction
  as an event append, inline projection, or process-manager state advance.
- Each row records destination, payload, enqueue time, attempt count, and
  correlation/causation attributes.
- A drain worker claims rows with `FOR UPDATE SKIP LOCKED`.
- The worker enqueues to a downstream queue such as pgmq and deletes the outbox
  row in the same transaction.
- Downstream delivery remains at-least-once, so external handlers must be
  idempotent.

User impact: handlers can request external side effects without making network
calls inside the database transaction.

### Inbox deduplication

The inbox is the receive-side dual of the outbox.

Expected design:

- `keiro_inbox(source, message_id, seen_at)` records external messages that have
  already been handled.
- Handlers insert into the inbox table inside their own transaction.
- Duplicate external deliveries short-circuit safely.
- Retention and GC are configurable, with the tradeoff documented.

User impact: pgmq, webhook, and external-message consumers get a standard
duplicate-detection path.

### Process-manager workflow hardening

Process managers are the v1 workflow substrate. They need production polish
around state, tracing, timers, and recovery.

Expected work:

- Keep deterministic command ids derived from process-manager name, correlation
  id, source event id, and emit index.
- Carry causation and correlation metadata on emitted commands.
- Standardize the `pm:<name>-<correlation>` state-stream convention.
- Recommend snapshot policies for long-running process managers.
- Document timer stuck-row recovery and retry policy.
- Expose worker metrics for projection lag, timer backlog, outbox backlog,
  duplicate counts, and dead-letter counts.

User impact: v1 covers sagas and choreography workflows without a separate
durable-execution runtime.

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
| Sample application | Planned | One complete reference app shows commands, snapshots, read models, PMs, timers, migrations, outbox, and inbox together. |
| Haddocks and examples | Planned | Each public module has reference docs and copy-pasteable examples. |
| Stability policy | Planned | Users know what can break before a stronger public API milestone. |
| Read-model migration guide | Planned | Application-owned query tables have clear migration ownership. |
| Decider-style facade | Exploratory | A higher-level pure-CQRS wrapper may reduce authoring friction if it stays thin. |

Expected work:

- Complete sample application.
- Broader Haddocks and examples for each public module.
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

