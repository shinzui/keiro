# Production Status

Keiro v1 is production-shaped for controlled early use. It is not yet a
turnkey, externally polished framework.

## What Is Implemented

The current library includes:

- typed stream names;
- event codecs with schema versions and upcasters;
- the `EventStream` aggregate contract and `ValidatedEventStream` command
  boundary for replayability safety;
- command execution with hydration, replay, decision, optimistic append, and
  retry;
- multi-event command output (one command appends zero, one, or many events in
  one optimistic batch);
- same-transaction SQL continuations for inline projections;
- advisory snapshots;
- read-model metadata, consistency modes, and position waits;
- explicitly registered read models; atomically fenced rebuilds; category-scoped
  strong reads; and async projection outcomes that prevent checkpointing fenced
  events;
- event-sourced process managers, with snapshot-policy guidance and a tested
  PM-state-stream snapshot example;
- stateless, effectful fan-out routers;
- durable timer storage and worker helpers, plus a stuck-row recovery API
  (find/requeue/cancel/dead-letter);
- a transactional outbox with per-key ordering, backoff, and dead-lettering,
  plus a Kafka producer adapter;
- an idempotent inbox with claim/retry/release/dead transitions and GC, plus
  Shibuya and Kafka consumer adapters;
- the cross-context integration-event envelope;
- OpenTelemetry command/producer/consumer spans and opt-in worker metrics
  (outbox/inbox/timer/projection backlog, lag, duplicate, dead-letter, and
  stuck-timer instruments);
- named-step durable workflows (`Keiro.Workflow`): `step`/`sleep`/`awakeable` plus
  child workflows, a journal per workflow (`wf:<name>-<id>`), a crash-recovery
  resume worker, journal snapshots, `continueAsNew` journal rotation, the `patch`
  versioning API, and `keiro.workflow.*` observability;
- LISTEN/NOTIFY push delivery (`Keiro.Wake`, `runWorkflowResumeWorkerPush`):
  sub-second wakeups for the resume worker and subscription loops over kiroku's
  existing per-store notifier, with a durable poll fallback and no new connections;
- consumer-group sharding for category subscriptions (`Keiro.Subscription.Shard`,
  `runShardedSubscriptionGroup`): a pool of identical workers leases kiroku
  consumer-group buckets to drain a high-volume category disjointly, with
  automatic, coordinator-free failover when a worker dies;
- Postgres-native work queues (`keiro-pgmq`): typed PGMQ jobs with retry and
  dead-letter policy, continuous workers or bounded drains, per-group FIFO
  delivery, standard/unlogged/partitioned provisioning, DLQ redrive and
  archive-then-purge retention, and a one-span-per-delivery tracing contract;
- durable rejected-dispatch records plus idempotent replay of Kiroku
  subscription dead letters;
- native `pg-migrate` components for Kiroku and Keiro framework tables, composed
  in dependency order by `keiro-migrate`.
- the `keiro-dsl` typed-spec toolchain across aggregates, process managers,
  routers, integration, queues, read models, and durable workflows, with
  validation, safe scaffolding, conformance harnesses, and evolution diffs.

The repository test suite exercises these paths against an ephemeral PostgreSQL
database.

## Good Fit Today

Keiro is a reasonable fit when:

- your team controls the application and deployment environment;
- PostgreSQL is already part of the system;
- you want a library, not a separate workflow/event-store server;
- you can write explicit codecs and migration tests;
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

### APIs are low-level

The command, projection, read-model, process-manager, and timer APIs expose the
runtime primitives directly. Higher-level ergonomic facades are future work.

### Migration ownership is split

Keiro ships `keiro-migrate` for Kiroku and Keiro framework tables. Application
read-model tables, codec evolution, and deployment sequencing remain
application responsibilities.

## Recommendation

Use Keiro v1 in production only with explicit guardrails:

- pin dependency revisions;
- run the full test suite in CI;
- add application-level codec and projection idempotency tests;
- document operational repair procedures;
- treat API changes as expected until the library reaches a stronger stability
  milestone.

For an internal system with those controls, the core paths are ready to trial.
For broad external adoption, the library needs more examples, Haddocks, release
discipline, and the remaining v1.x ergonomics.
