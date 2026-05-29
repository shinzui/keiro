# Operations

This page collects deployment and runtime concerns for Keiro applications.

## Database Requirements

Keiro runs on PostgreSQL through Kiroku and Hasql.

Kiroku's schema requires PostgreSQL 18 or newer because it uses `uuidv7()`.
Deployments on PostgreSQL 17 or older fail schema initialization unless you
provide a compatible `uuidv7()` function yourself.

## Schema Initialization

Production deployments should run `keiro-migrate` before starting application
processes. See [Database Migrations](migrations.md) for the command, required
environment variables, and startup guidance.

There is no in-application schema initializer for the framework tables: the
codd migrations in `keiro-migrations` are the single source of schema truth.
Tests apply the same migrations to a template database (see the
`keiro-test-support` `withMigratedSuite` fixture) rather than creating tables
inline.

Keep in mind:

- user read-model tables are application-owned;
- schema evolution should be reviewed and applied through `keiro-migrate` plus
  your application migration tool;
- production rollouts should coordinate code version, codec version, read-model
  version, and shape hashes.

## Runtime Processes

Typical deployments have:

- web/API processes that call `runCommand`;
- projection workers for async read models;
- process-manager and router workers consuming subscription streams;
- timer workers polling due timers;
- outbox publisher workers that drain `keiro_outbox` (`claimOutboxBatch` /
  `publishClaimedOutbox`) to the configured destination;
- operational jobs for rebuilds, repairs, and inbox GC
  (`garbageCollectCompleted` pruning completed `keiro_inbox` rows).

Keiro does not supervise these OS processes. Use your normal process manager,
container orchestrator, or service framework.

## Command Retries

`runCommand` retries optimistic concurrency conflicts. The command decision is
recomputed after each rehydrate.

Keep command handlers deterministic with respect to stored history. Generate
external ids before calling `runCommand` and pass them through command data or
`RunCommandOptions.eventIds`.

## Idempotency

Use explicit idempotency whenever work may be delivered more than once:

- supply event ids for externally retried command submissions;
- use process-manager (and router) deterministic command ids;
- make async projections idempotent by source event id;
- make timer ids deterministic when scheduled from process-manager state;
- deduplicate inbound integration events through the inbox
  (`runInboxTransaction` keys on `(source, dedupe_key)`);
- keep external outbox-delivery handlers idempotent (delivery is at-least-once).

At-least-once delivery is normal for async workers in v1.

See [Run And Operate Jitsurei](../guides/run-and-operate-jitsurei.md) for the
guide-backed local verification path and the operational assumptions behind the
example package.

## Read Models

Use `ReadModel.version` and `shapeHash` to force stale readers to fail closed.

Recommended rebuild pattern:

1. Deploy code that can write the new model separately from old readers.
2. Mark the new model `Rebuilding`.
3. Rebuild from the event log.
4. Mark it `Live`.
5. Move readers to the new version.
6. Mark old versions `Abandoned` when no longer needed.

The exact table-swap strategy is application-owned.

## Snapshots

Snapshots are optional acceleration. Monitor hydration latency before enabling
them widely.

Snapshot corruption or shape mismatch falls back to full replay. Event-log
corruption does not.

## Timers

Timer workers claim one due timer at a time. Multiple workers can run
concurrently because claims use row locking with `SKIP LOCKED`.

Decide an operational policy for timers left in `Firing`. The current v1 API
does not expose automatic retry or cancellation helpers for stuck rows.

## Observability

At minimum, track:

- command success/failure by `CommandError`;
- retry exhaustion;
- hydration latency and stream length;
- projection lag by subscription `last_seen`;
- async projection duplicate counts;
- read-model wait timeouts;
- process-manager duplicate handling;
- due timer backlog and stuck `Firing` timers;
- outbox backlog, attempt counts, and dead-lettered rows;
- inbox duplicate counts and retained-row growth;
- PostgreSQL connection pool saturation.

Keiro emits OpenTelemetry **spans** through `Keiro.Telemetry`: an `Internal`
span around `runCommand` (opt-in via `RunCommandOptions.tracer`), a `Producer`
span around outbox publishing, and `Consumer` spans parented via W3C trace
headers. There is no built-in metric instrumentation yet, so the counts above
are currently derived from your own queries and logs.

## Production Checklist

Before production:

- Confirm PostgreSQL 18+.
- Confirm `keiro-migrate` runs in staging before application startup.
- Run the Keiro test suite in CI.
- Add codec tests for every event type and old version.
- Use deterministic ids for externally retried writes.
- Make every async projection idempotent.
- Make outbox-delivery and inbox handlers idempotent.
- Decide read-model rebuild and rollback procedures.
- Decide timer stuck-row repair procedure.
- Decide outbox dead-letter handling and inbox retention/GC cadence.
- Load test command paths that touch long streams.
- Document which APIs are considered stable for your application.
