---
type: Reference
title: Production Status
description: State Keiro's production maturity, supported adoption posture, and intentionally deferred work.
docId: DOC-18
tags: [keiro, production, maturity, reference]
generated:
  by: human:nadeem
  at: 2026-09-18T04:06:27Z
timestamp: 2026-10-27T21:15:00Z
---

# Production Status

Keiro 0.22.0.0 is production-shaped for controlled early use. It is not yet a
turnkey, externally polished framework.

## Availability

The eight published packages — `keiro-core`, `keiro`, `keiro-pgmq`,
`keiro-migrations`, `keiro-dsl`, `keiro-ops`, `keiro-ops-http`, and
`keiro-test-support` — are on Hackage at 0.22.0.0. They are released together,
each with its own git tag. `jitsurei` is the internal worked-example package.
See [Getting Started](getting-started.md) for dependencies and
[Deploy Ordering](deploy-ordering.md) before upgrading.

Library, executable, and test-suite dependency bounds are declared in the Cabal
files. Keep consumers on one Keiro cohort and review upstream release notes
before changing bounds. A tested metadata revision can widen compatibility;
source or behavior changes require a package release.

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
- validated catalogs with explicit target ownership and query suppliers;
- registered read models, independent delivery/freshness contracts, and bounded
  post-commit position waits;
- coordinated fixed-head offline rebuilds, schema-versioned online rebuilds,
  resume, atomic cutover, and stream-scoped repair;
- managed append/projection fences and guarded catalog preconditions that roll
  back refused appends;
- transactional async dedup receipts, with outcomes that prevent checkpointing
  fenced events.

### Coordination

- event-sourced process managers, with snapshot-policy guidance and a tested
  PM-state-stream snapshot example;
- typed process reactions (`Keiro.ProcessManager.Reaction`): explicit
  no-advance and accepted-only follow-ups, atomic saga/timer mutation, and
  target-keyed dispatch identity;
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
  plus `keiro.workflow.*` observability;
- a suspension cost model you can plan against: a workflow parked on an
  awakeable, a child, or a future-dated sleep is not discovered at all, so idle
  cost does not scale with the number of parked workflows. Budget instead for
  due sleeps waiting on a timer worker (batch them with
  `drainWorkflowSleepTimers`), crash retries, and journal replay per
  re-invocation. `WorkflowRunOptions.snapshotPolicy` defaults to `Never`, which
  means a resume replays the whole journal — set `Every n` for suspend-heavy or
  long-journal workflows. A pass can advance several workflows at once
  (`WorkflowResumeOptions.maxConcurrentAdvances`, default 1); size it against
  the store's connection pool.

### Messaging and integration

- a transactional outbox with per-key ordering, backoff, and dead-lettering,
  plus a Kafka producer adapter; canonical producers derive replay-safe
  deterministic message IDs and report content drift through the
  `keiro.outbox.identity.conflict` metric;
- an idempotent inbox with claim/retry/release/dead transitions and GC, plus
  Shibuya and Kafka consumer adapters, and delegated intake
  (`Keiro.Inbox.Delegated`) when the downstream state transition owns the
  durable receipt;
- the cross-context integration-event envelope;
- Postgres-native work queues (`keiro-pgmq`): typed PGMQ jobs with retry and
  dead-letter policy, continuous workers or bounded drains, per-group FIFO
  delivery with `FifoHeads` safe batching of independent group heads,
  standard/unlogged/partitioned provisioning, header-preserving DLQ redrive,
  archive-then-purge retention with a purge that refuses while inspected rows
  remain hidden, and a one-span-per-delivery tracing contract;
- durable rejected-dispatch records plus idempotent replay of Kiroku
  subscription dead letters.

### Delivery and scale-out

- LISTEN/NOTIFY push delivery (`Keiro.Wake`, `runWorkflowResumeWorkerPush`):
  sub-second wakeups for the resume worker and subscription loops over kiroku's
  existing per-store notifier, with a durable poll fallback and no new
  connections;
- category-namespace subscriptions through the released
  [Kiroku Store](mori://shinzui/kiroku/packages/kiroku-store) 0.12 cohort;
  Keiro catalog/DSL sources remain all-stream or exact-category declarations;
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
- the `keiro-ops` standalone and embeddable operations console: schema
  handshake, preview/`--force` mutations, stable JSON, and application hooks for
  bounded workflow resume, timer drain, candidate-code replay audit, and typed
  catalog rebuilds;
- application-owned aggregate/manager catalogs, bounded workflow/timer/projection
  pages, pure `pm types` discovery, and database-clock shard observations;
- optional `keiro-ops-http` HTTP operations, shared first-page WebSocket feeds,
  and stable-prefix composition using the same owner reads and command handlers;
- the `keiro-dsl` typed-spec toolchain across aggregates, process managers,
  routers, integration, queues, read models, and durable workflows, including
  structural/opaque consumer mappings, total bindings, generated private-event
  codecs, safe scaffolding, conformance harnesses, compatibility-vector diffs,
  finite historical codec comparison, and supported-root coverage reports.
  Language 5 is the published stable contract; Language 6 (process
  reactions, delegated intake, `ordering fifo-heads`, nominal structural
  leaves, keyed maps, checked values, contract lists, mapped-register
  construction, and structural enum equality) ships as a candidate, not a stable
  compatibility contract. Languages 1–4 are deprecated today; Languages 1–5 and
  legacy positional managers are scheduled to retire before 1.0 under
  [ADR 49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md).

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
- you need atomic subscription checkpoint advancement with projection SQL;
- you need positional-history durable execution (Temporal-style step identity
  derived from call order) — Keiro's runtime uses **named** steps that are stable
  across source reordering, by design;
- you need built-in schema migration tooling for user read models;
- you need complete public Haddocks and a stable third-party API before adoption.

The repository verification and schema-inspection baseline is PostgreSQL 18.
Kiroku also supplies UUIDv7 support on PostgreSQL 17; see
[Database Requirements](operations.md#database-requirements) before selecting
a different full-stack server baseline.

## Known v1 Limits

### Async projections are at-least-once

The subscription boundary does not combine user SQL and checkpoint advancement
in one transaction. Keiro does commit a projection's dedup receipt and handler
SQL together, suppressing duplicate application while that receipt is retained.
A crash can still repeat delivery; pruned receipts no longer protect older
events. Keep handler SQL idempotent where practical and size receipt retention
against redelivery and rebuild windows.

Inline projections can be transactional with the command append.

### Durable execution is named-step

The v2 durable-execution runtime is available (`Keiro.Workflow`): named-step
`Workflow es a` functions with durable sleep, awakeables, child workflows, a
crash-recovery resume worker, and journal snapshots. Step identity is by **name**,
not call-order position, so it is stable across source reordering. Continue-as-new
journal rotation (`continueAsNew`/`restoreSeed`) keeps unbounded histories bounded,
and the `patch` API gives stable, journaled branch decisions for cross-cutting
workflow-logic changes. Preserve names/codecs for retained steps; a new name
creates a new action and needs an explicit in-flight rollout policy. One sharp
edge to plan for: rotating with `continueAsNew` abandons any awakeable id already
handed to an external system, because the next generation re-runs the allocation
step and hands out a fresh id — re-notify the holder from that step. V1 process
managers and timers remain the saga-style / time-based coordination layer; reach
for a workflow when the process reads as one long-running function with in-line
waits. See the [Durable Workflows guide](../guides/durable-workflows.md).

### Snapshot seed verification is sampled, not exhaustive

Snapshot discriminators reject seeds whose codec version, register layout, or
control-state shape changed, and the runtime witness full-replays a sampled
fraction of accepted seeds to catch divergence the discriminator cannot see.
At most one sampled full replay runs per process by default; set
`RunCommandOptions.seedVerifyInFlightLimit` to change the bound, or to zero
for unbounded verification. A sample that finds the limit full increments
`keiro.snapshot.seed.skipped`; an unexpected replay exception increments
`keiro.snapshot.seed.verification.failed` and is logged as JSON.
Both are detection, not prevention: a fold change invisible to register layout
still needs an explicit `withFoldFingerprint` token. The default one-in-1000
sample rate and capacity skips mean a divergence may go undetected. Run
`Keiro.ReplayAudit` before deploying a changed fold surface instead of relying
on the sample.

### APIs are low-level

The command, projection, read-model, process-manager, and timer APIs expose the
runtime primitives directly. `keiro-ops` now provides the supported operational
facade. The DSL provides generated aggregate authoring over the transducer
contract; a Decider-style facade was declined (see
[plan 7](../plans/7-internal-decider-style-ergonomic-facade-over-runcommand.md)).
Durable checkpoint inventory is implemented through Kiroku's public
`subscriptionCheckpointInventory`; `stream subscriptions` and
`projection position` expose it. Position distance uses the separately observed
visible head and is not a relevant-event backlog count. See
[Operations](operations.md#durable-subscription-positions).

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
- gate deploys on the embedded `replay-audit` command against real streams —
  targeted for a known affected set, full when the fold surface changed;
- document operational repair procedures;
- treat API changes as expected until the library reaches a stronger stability
  milestone.

For an internal system with those controls, the core paths are ready to trial.
Broader external adoption still needs stronger API stability guarantees,
broader Haddock coverage, and consumer-specific operational qualification.
