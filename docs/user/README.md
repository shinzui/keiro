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
- [Choosing A Primitive](../guides/choosing-a-primitive.md): the routing map for
  deciding between an `EventStream`, Keiki composition, a projection, a process
  manager, or a router.
- [Command Cycle](command-cycle.md): how `runCommand` works and how to handle
  errors, retries, idempotency, and inline SQL.
- [Codecs And Event Evolution](codecs-and-event-evolution.md): event type tags,
  schema versions, upcasters, and decode failures.
- [Snapshots](snapshots.md): enabling advisory snapshot hydration.
- [Read Models And Projections](read-models-and-projections.md): strong,
  eventual, and position-wait reads.
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
- [Database Migrations](migrations.md): running `keiro-migrate`, disabling
  runtime schema initialization, and owning application table migrations.
- [Operations](operations.md): database requirements, schema initialization,
  workers, retries, idempotency, and production checklist.
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
- `runCommand`, `runCommandWithSql`, and `runCommandWithSqlEvents` through
  `Keiro.Command`;
- advisory snapshots through `Keiro.Snapshot`;
- read models, inline projections, async projection helpers, and rebuild
  metadata through `Keiro.ReadModel` and `Keiro.Projection`;
- event-sourced process managers through `Keiro.ProcessManager`;
- stateless, effectful fan-out (routers) through `Keiro.Router`;
- durable timer storage and worker helpers through `Keiro.Timer`;
- the cross-context integration-event envelope through
  `Keiro.Integration.Event`;
- a transactional outbox through `Keiro.Outbox` and an idempotent inbox through
  `Keiro.Inbox`, each with a Kafka adapter;
- OpenTelemetry command/producer/consumer spans through `Keiro.Telemetry`.

The top-level `Keiro` module re-exports the core stream, codec, event-stream,
command, router, and snapshot APIs. Import read-model, projection,
process-manager, timer, outbox, inbox, integration-event, and telemetry modules
directly.

## What this guide assumes

The examples assume you already have:

- a domain event type, command type, state type, and `Keiki.Core.SymTransducer`;
- a `Codec` for your output events;
- a Kiroku store interpreter running against PostgreSQL;
- `Effectful` in the application runtime stack.

The sibling `jitsurei` package is the best source of complete executable
examples. Its guide entry point is [Keiro Guides](../guides/README.md), and its
tests live in `jitsurei/test/Main.hs`.
