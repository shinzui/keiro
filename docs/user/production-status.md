# Production Status

Keiro v1 is production-shaped for controlled early use. It is not yet a
turnkey, externally polished framework.

## What Is Implemented

The current library includes:

- typed stream names;
- event codecs with schema versions and upcasters;
- the `EventStream` aggregate contract;
- command execution with hydration, replay, decision, optimistic append, and
  retry;
- multi-event command output (one command appends zero, one, or many events in
  one optimistic batch);
- same-transaction SQL continuations for inline projections;
- advisory snapshots;
- read-model metadata, consistency modes, and position waits;
- async projection helpers with idempotency expectations;
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
  resume worker, journal snapshots, and `keiro.workflow.*` observability;
- embedded codd migrations for Kiroku and Keiro framework tables.

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
- you need continue-as-new journal rotation for unbounded-length workflow
  histories (still deferred);
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
not call-order position, so it is stable across source reordering. V1 process
managers and timers remain the saga-style / time-based coordination layer; reach
for a workflow when the process reads as one long-running function with in-line
waits. The deferred pieces are continue-as-new journal rotation and the
versioning/patch API. See the [Durable Workflows guide](../guides/durable-workflows.md).

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
