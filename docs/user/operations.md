# Operations

This page collects deployment and runtime concerns for Keiro applications.

## Database Requirements

Keiro runs on PostgreSQL through Kiroku and Hasql.

Kiroku's schema requires PostgreSQL 18 or newer because it uses `uuidv7()`.
Deployments on PostgreSQL 17 or older fail schema initialization unless you
provide a compatible `uuidv7()` function yourself.

## Schema Initialization

Initialize the Kiroku event-store schema first. Then initialize the Keiro feature
schemas you use:

```haskell
initializeSnapshotSchema
initializeReadModelSchema
initializeTimerSchema
```

Keiro's schema initializers are idempotent. They are still not a replacement for
application migrations:

- user read-model tables are application-owned;
- schema evolution should be reviewed and applied through your migration tool;
- production rollouts should coordinate code version, codec version, read-model
  version, and shape hashes.

## Runtime Processes

Typical deployments have:

- web/API processes that call `runCommand`;
- projection workers for async read models;
- process-manager workers consuming subscription streams;
- timer workers polling due timers;
- operational jobs for rebuilds and repairs.

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
- use process-manager deterministic command ids;
- make async projections idempotent by source event id;
- make timer ids deterministic when scheduled from process-manager state.

At-least-once delivery is normal for async workers in v1.

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
- PostgreSQL connection pool saturation.

## Production Checklist

Before production:

- Confirm PostgreSQL 18+.
- Confirm Kiroku and Keiro schemas initialize in staging.
- Run the Keiro test suite in CI.
- Add codec tests for every event type and old version.
- Use deterministic ids for externally retried writes.
- Make every async projection idempotent.
- Decide read-model rebuild and rollback procedures.
- Decide timer stuck-row repair procedure.
- Load test command paths that touch long streams.
- Document which APIs are considered stable for your application.
