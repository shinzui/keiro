# Production Status

Keiro v1 is production-shaped for controlled early use. It is not yet a
turnkey, externally polished framework.

## Availability

The five published packages — `keiro-core`, `keiro`, `keiro-pgmq`,
`keiro-migrations`, and `keiro-dsl` — are on Hackage and share one version.
They are released together, each with its own git tag. `keiro-test-support` and
`jitsurei` are internal and are not published.

Every library and executable dependency carries a PVP upper bound, so a
breaking upstream release cannot silently enter your build plan. The corollary
is that upper bounds may lag a dependency you already run; a Hackage metadata
revision, not a new release, is the normal fix. Test-suite-only dependencies
are deliberately left open — they do not affect consumers.

## What Is Implemented

Grouped by functionality. Unless noted, everything below lives in `keiro` and
`keiro-core`.

### Event sourcing core

- typed stream names;
- event codecs with schema versions and upcasters;
- the `EventStream` aggregate contract and `ValidatedEventStream` command
  boundary for replayability safety;
- command execution with hydration, replay, decision, optimistic append, and
  retry;
- multi-event command output (one command appends zero, one, or many events in
  one optimistic batch).

### Snapshots and replay safety

- advisory snapshots whose discriminator (codec version, register layout, and
  control-state shape) invalidates stale seeds automatically, plus
  `withFoldFingerprint`/`FoldVersion` for fold changes that register layout
  alone cannot see;
- a sampled runtime witness (`RunCommandOptions.seedVerifySampleRate`, one in
  1000 usable seeds by default) that full-replays a snapshot hit and emits
  `keiro.snapshot.seed.divergence` on a mismatch without blocking the command;
- a read-only pre-deploy replay gate (`Keiro.ReplayAudit`): replays real streams
  through a candidate binary in affected-event `AuditTargeted` or `AuditFull`
  mode, compares accepted snapshot seeds against full replay over RFC 8785
  canonical JSON, reports `ReplayOk`/`ReplayFailed`/`SeedDivergence` with stable
  digests, and exposes `auditExitCode` for CI. Generated DSL services assemble
  one context-wide `Generated.<Context>.ReplayAudit.auditTargets`.

### Read models and projections

- same-transaction SQL continuations for inline projections;
- read-model metadata, consistency modes, and position waits;
- explicitly registered read models; atomically fenced rebuilds; category-scoped
  strong reads; and async projection outcomes that prevent checkpointing fenced
  events.

### Coordination

- event-sourced process managers, with snapshot-policy guidance and a tested
  PM-state-stream snapshot example;
- stateless, effectful fan-out routers;
- durable timer storage and worker helpers, plus a stuck-row recovery API
  (find/requeue/cancel/dead-letter).

### Durable workflows

- named-step durable workflows (`Keiro.Workflow`): `step`/`sleep`/`awakeable`
  plus child workflows, a journal per workflow (`wf:<name>-<id>`), a
  crash-recovery resume worker, journal snapshots, `continueAsNew` journal
  rotation, and the `patch` versioning API;
- lease renewal at fresh actions and await arms
  (`WorkflowRunOptions.leaseHeartbeat`), so a healthy long advance is not
  charged a crash attempt;
- the operator recovery API `Keiro.Workflow.Instance.resurrectFailedWorkflow`,
  plus `keiro.workflow.*` observability.

### Messaging and integration

- a transactional outbox with per-key ordering, backoff, and dead-lettering,
  plus a Kafka producer adapter;
- an idempotent inbox with claim/retry/release/dead transitions and GC, plus
  Shibuya and Kafka consumer adapters;
- the cross-context integration-event envelope;
- Postgres-native work queues (`keiro-pgmq`): typed PGMQ jobs with retry and
  dead-letter policy, continuous workers or bounded drains, per-group FIFO
  delivery, standard/unlogged/partitioned provisioning, DLQ redrive and
  archive-then-purge retention, and a one-span-per-delivery tracing contract;
- durable rejected-dispatch records plus idempotent replay of Kiroku
  subscription dead letters.

### Delivery and scale-out

- LISTEN/NOTIFY push delivery (`Keiro.Wake`, `runWorkflowResumeWorkerPush`):
  sub-second wakeups for the resume worker and subscription loops over kiroku's
  existing per-store notifier, with a durable poll fallback and no new
  connections;
- consumer-group sharding for category subscriptions (`Keiro.Subscription.Shard`,
  `runShardedSubscriptionGroup`): a pool of identical workers leases kiroku
  consumer-group buckets to drain a high-volume category disjointly, with
  automatic, coordinator-free failover when a worker dies.

### Observability

- OpenTelemetry command/producer/consumer spans and opt-in worker metrics
  (outbox/inbox/timer/projection backlog, lag, duplicate, dead-letter, and
  stuck-timer instruments).

### Schema and tooling

- native `pg-migrate` components for Kiroku and Keiro framework tables, composed
  in dependency order by `keiro-migrate`;
- the `keiro-dsl` typed-spec toolchain across aggregates, process managers,
  routers, integration, queues, read models, and durable workflows, including
  structural/opaque consumer mappings, total bindings, generated private-event
  codecs, safe scaffolding, conformance harnesses, compatibility-vector diffs,
  finite historical codec comparison, and supported-root coverage reports.

The repository test suite exercises these paths against an ephemeral PostgreSQL
database.

## Good Fit Today

Keiro is a reasonable fit when:

- your team controls the application and deployment environment;
- PostgreSQL is already part of the system;
- you want a library, not a separate workflow/event-store server;
- you can write explicit codecs and migration tests, or adopt checked
  structural declarations with finite historical-comparison evidence;
- you can make async handlers idempotent;
- you are comfortable with low-level Haskell APIs while v1 ergonomics mature.

## Not A Good Fit Yet

Keiro is not yet a good fit when:

- you need a stable public API for third-party consumers;
- you need exactly-once async projections without user-side idempotency;
- you need positional-history durable execution (Temporal-style step identity
  derived from call order) — Keiro's runtime uses **named** steps that are stable
  across source reordering, by design;
- you need built-in schema migration tooling for user read models;
- you need a complete sample application and extensive Haddocks before adoption;
- your deployment cannot run PostgreSQL 18+.

## Known v1 Limits

### Async projections are at-least-once

The current Shibuya/Kiroku subscription boundary does not combine user SQL and
checkpoint advancement in one transaction. Async projection handlers must be
idempotent.

Inline projections can be transactional with the command append.

### Durable execution is named-step

The v2 durable-execution runtime is available (`Keiro.Workflow`): named-step
`Workflow es a` functions with durable sleep, awakeables, child workflows, a
crash-recovery resume worker, and journal snapshots. Step identity is by **name**,
not call-order position, so it is stable across source reordering. Continue-as-new
journal rotation (`continueAsNew`/`restoreSeed`) keeps unbounded histories bounded,
and the `patch` API gives stable, journaled branch decisions for cross-cutting
workflow-logic changes (prefer renaming a step for single-step changes). V1 process
managers and timers remain the saga-style / time-based coordination layer; reach
for a workflow when the process reads as one long-running function with in-line
waits. See the [Durable Workflows guide](../guides/durable-workflows.md).

### Snapshot seed verification is sampled, not exhaustive

Snapshot discriminators reject seeds whose codec version, register layout, or
control-state shape changed, and the runtime witness full-replays a sampled
fraction of accepted seeds to catch divergence the discriminator cannot see.
Both are detection, not prevention: a fold change invisible to register layout
still needs an explicit `withFoldFingerprint` token, and the default one-in-1000
sample rate means divergence is found eventually rather than immediately. Run
`Keiro.ReplayAudit` before deploying a changed fold surface instead of relying
on the sample.

### APIs are low-level

The command, projection, read-model, process-manager, and timer APIs expose the
runtime primitives directly. Higher-level ergonomic facades are future work.

### Migration ownership is split

Keiro ships `keiro-migrate` for Kiroku and Keiro framework tables. Application
read-model tables, codec evolution, historical-corpus selection, and deployment
sequencing remain application responsibilities. The DSL can classify changes
and compare an explicit historical codec over a finite corpus, but it does not
turn that evidence into an automatic production migration.

## Recommendation

Use Keiro v1 in production only with explicit guardrails:

- pin dependency revisions;
- run the full test suite in CI;
- add application-level codec and projection idempotency tests;
- gate deploys on a `Keiro.ReplayAudit` run against real streams — targeted for
  a known affected set, full when the fold surface changed;
- document operational repair procedures;
- treat API changes as expected until the library reaches a stronger stability
  milestone.

For an internal system with those controls, the core paths are ready to trial.
For broad external adoption, the library needs more examples, Haddocks, release
discipline, and the remaining v1.x ergonomics.
