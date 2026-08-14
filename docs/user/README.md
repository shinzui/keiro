# Keiro User Guide

Keiro is a Haskell library for building Postgres-backed event-sourced
applications. It gives application code a typed event-stream contract, command
execution with optimistic concurrency, optional snapshots, read-model helpers,
process managers, routers, durable timers, a transactional outbox and idempotent
inbox for cross-context integration events, and OpenTelemetry tracing.

Keiro is not a server. Your application owns its process model, database
connection settings, deployment, and domain modules. Keiro supplies the runtime
pieces those modules import.

## Start here

- [Getting Started](getting-started.md): prerequisites, install shape, schemas,
  and the first command path.
- [Core Concepts](core-concepts.md): streams, codecs, event streams, commands,
  projections, process managers, and timers.
- [Replayability Safety](replay-safety.md): the `ValidatedEventStream` boundary,
  hidden-input rejection, and what replay safety does and does not guarantee.
- [Keiro DSL Language 4 Reference](typed-spec-toolchain.md): the complete
  Language 4 grammar, type and expression rules, every node family, workspaces,
  generated ownership, CLI commands, validation, and evolution workflow.
- [Adopting Mapped Consumer Surfaces](mapped-consumer-adoption.md): the candidate
  language-5 queue, query, projection, event, and snapshot gate; prerequisites;
  one-service baseline; and rollout ownership.
- [Choosing `keiro-dsl`](../guides/choosing-keiro-dsl.md): benefits, costs,
  granular escape hatches, and the service shapes that favor a typed
  specification, hybrid ownership, or hand-written Keiro.
- [Choosing A Primitive](../guides/choosing-a-primitive.md): the routing map for
  deciding between an `EventStream`, Keiki composition, a projection, a process
  manager, or a router.
- [Command Cycle](command-cycle.md): how `runCommand` works and how to handle
  errors, retries, idempotency, and inline SQL.
- [Codecs And Event Evolution](codecs-and-event-evolution.md): event type tags,
  schema versions, upcasters, structural codec authority, and decode failures.
- [Snapshots](snapshots.md): enabling advisory snapshot hydration and assigning
  a hand-owned `FoldVersion` to hand-written folds.
- [Read Models And Projections](read-models-and-projections.md): one validated
  projection catalog, managed live/async application, strong/eventual reads,
  offline and online schema-versioned rebuilds, operations reports, and staged
  migration. The full online runbook is
  [Online Schema-Versioned Projection Rebuilds](../guides/online-projection-rebuilds.md).
- [Process Managers And Timers](process-managers-and-timers.md): event-sourced
  coordination, deterministic command ids, and timer workers.
- [Durable Workflows](durable-workflows.md): named-step workflows, durable sleep,
  awakeables, child workflows, the resume worker, and journal snapshots.
- [Integration Events](integration-events.md): the public envelope used to
  publish across bounded contexts over Kafka.
- [Durable Outbox](outbox.md): how outgoing integration events become
  durable rows, ordering and dead-letter policies, and the
  publish-pipeline contract.
- [Idempotent Inbox](inbox.md): how the receiving bounded context
  deduplicates Kafka redeliveries, dedupe policies, and the
  transactional handler wrapper.
- [Work Queues](work-queues.md): typed PGMQ background jobs — the `Job`
  declaration, workers versus one-shot drains, retry and dead-letter policy,
  FIFO groups, provisioning, and DLQ operations.
- [Dead Letters And Replay](dead-letters.md): rejected dispatch records and
  idempotent operator replay of subscription dead letters.
- [Database Migrations](migrations.md): running `keiro-migrate`, disabling
  runtime schema initialization, and owning application table migrations.
- [Migration Ownership](migration-ownership.md): framework-owned vs
  application-owned migrations, combined-ledger composition, and operator checks.
- [Deploy Ordering](deploy-ordering.md): which binaries must roll first for
  codec, queue, decide, timer, integration, and workflow changes.
- [Operations](operations.md): database requirements, schema initialization,
  workers, catalog-backed rebuild commands, retries, idempotency, and the
  production checklist.
- [Roadmap](roadmap.md): capability matrix, v1.x workflow substrate, read-side
  maturity work, adoption milestones, and the v2 durable-execution direction.
- [API Reference](api-reference.md): module-by-module public surface.
- [Production Status](production-status.md): what is production-shaped today and
  what remains intentionally deferred.

## Long-form guides

For a complete, guide-backed example, start with
[Keiro Guides](../guides/README.md). The guides use the sibling `jitsurei`
package as their source of truth and can be verified with
`cabal test jitsurei-test`.

## Current v1 scope

The v1 library includes:

- typed stream names through `Keiro.Stream`;
- event codecs, schema-version metadata, event type validation, and upcasters
  through `Keiro.Codec`;
- the author-facing `EventStream` contract through `Keiro.EventStream`;
- replayability validation and the `ValidatedEventStream` command boundary
  through `Keiro.EventStream.Validate`;
- `runCommand`, `runCommandWithSql`, and `runCommandWithSqlEvents` through
  `Keiro.Command`;
- advisory snapshots through `Keiro.Snapshot`;
- read models, validated projection catalogs, managed inline/async projection
  helpers, and resumable coordinated rebuilds through `Keiro.ReadModel`,
  `Keiro.Projection`, and `Keiro.Projection.Catalog`;
- event-sourced process managers through `Keiro.ProcessManager`;
- stateless, effectful fan-out (routers) through `Keiro.Router`;
- durable timer storage and worker helpers through `Keiro.Timer`;
- the cross-context integration-event envelope through
  `Keiro.Integration.Event`;
- a transactional outbox through `Keiro.Outbox` and an idempotent inbox through
  `Keiro.Inbox`, each with a Kafka adapter;
- named-step durable workflows — steps, durable sleep, awakeables, child
  workflows, a resume worker, journal snapshots, `continueAsNew`, and `patch` —
  through the `Keiro.Workflow*` modules;
- LISTEN/NOTIFY push delivery for poll-loop workers through `Keiro.Wake`, and
  leased consumer-group sharding for category subscriptions through
  `Keiro.Subscription.Shard`;
- the pre-deploy real-log replay gate through `Keiro.ReplayAudit`;
- Postgres-native work queues through the `keiro-pgmq` package (see
  [Work Queues](work-queues.md));
- OpenTelemetry command/producer/consumer spans and opt-in worker metrics
  through `Keiro.Telemetry`.
- checked `.keiro` specifications, structural/opaque consumer-owned mappings,
  generated binding/codec conformance, safe scaffolding, compatibility-vector
  diffs, historical codec comparison, and supported-root coverage reporting
  through the `keiro-dsl` package.

The top-level `Keiro` module re-exports the core stream, codec, event-stream,
command, router, and snapshot APIs. Import read-model, projection,
process-manager, timer, workflow, outbox, inbox, integration-event, replay-audit,
and telemetry modules directly.

## What this guide assumes

The examples assume you already have:

- a domain event type, command type, state type, and `Keiki.Core.SymTransducer`;
- a `Codec` for your output events;
- a Kiroku store interpreter running against PostgreSQL;
- `Effectful` in the application runtime stack.

The sibling `jitsurei` package is the best source of complete executable
examples. Its guide entry point is [Keiro Guides](../guides/README.md), and its
tests live in `jitsurei/test/Main.hs`.
