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

Timer workers claim one due timer at a time. Multiple workers can run concurrently
because claims use row locking with `SKIP LOCKED` (`claimDueTimer`). A worker that
crashes after claiming but before firing leaves a row in `Firing`; that row is
re-claimable in principle but will not advance on its own.

### Stuck-row recovery runbook

Keiro exposes a supported recovery API in `Keiro.Timer` / `Keiro.Timer.Schema` (see
`docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md` for the authoritative
signatures). Run this as a periodic operational job:

1. **List stuck rows.** Call `findStuckTimers now stuckFilter` with a `StuckTimerFilter`
   (`minAge` and/or `minAttempts`; `anyStuckTimer` matches every `Firing` row) to get the
   timers parked in `Firing` longer than expected.
2. **Decide per row.** A timer that should still fire: requeue it. A timer that is no
   longer wanted (the workflow moved on or was cancelled): cancel it.
3. **Requeue.** Call `requeueStuckTimer` to move the row back to `Scheduled` so a worker
   re-claims it on the next poll. `fire_at` is unchanged and the call is idempotent;
   because timer ids are deterministic and firing is idempotent, requeuing a timer that
   actually did fire is safe.
4. **Cancel.** Call `cancelTimer` to move the row to `Cancelled` (terminal). Use this for
   timers whose workflow has already advanced past the deadline.
5. **Dead-letter after the ceiling.** Call `deadLetterTimer timerId reason` to move a row
   to the terminal `Dead` state with an explanatory `last_error`. To automate this, run
   the worker with `runTimerWorkerWith (TimerWorkerOptions { maxAttempts = Just n })`: a
   claimed timer whose post-claim `attempts` exceeds `n` is dead-lettered instead of fired.
   Dead rows should page an operator.

Monitor the `keiro.timer.stuck` gauge (rows still in `Firing` past the threshold; see
Observability) before and after a run to confirm the job is draining the backlog rather
than churning. `Dead` is a distinct terminal state and is not counted by that gauge; track
it with a separate query (`status = 'dead'`) if you want a dead-letter count.

## Durable Workflows

Durable workflows (`Keiro.Workflow`) journal each named step to `wf:<name>-<id>`
and resume by re-invocation. Three operational tasks:

- **Resume worker.** Run `resumeWorkflowsOnce <resumeOptions> <registry>` on a
  polling loop — the same claim-process-commit-poll shape as the timer and outbox
  workers (`runWorkflowResumeWorker` wraps the loop). Each pass discovers
  workflows whose journal lacks a terminal marker (via the `keiro_workflow_steps`
  index, unioned with running children) and re-invokes them through the
  application's `WorkflowRegistry`, so suspended workflows resume after their waits
  resolve and after a process restart. The registry must hold a `WorkflowDef` for
  every workflow *name* still in flight; a discovered workflow whose name is absent
  is surfaced as `unknownName` in the `ResumeSummary`, never silently dropped. A
  parent and its child must use **distinct** workflow ids — discovery groups by
  `workflow_id`, so a shared id lets a completed child mask an unfinished parent.
- **Awakeable repair.** A workflow parked on an awakeable that will never be
  signalled is repaired with `cancelAwakeable awkId`, which flips the
  `keiro_awakeables` row (`awakeable_id`, `owner_workflow_id`, `status`, `payload`)
  to `cancelled`; the next resume observes the cancellation and `awaitChild`/the
  awakeable `await` throws so the workflow author's compensation runs. Repair a
  parent stuck on a never-finishing child by driving or cancelling the child
  (`cancelChild`). The `keiro.workflow.awakeables.pending` gauge counts pending
  rows.
- **Journal snapshots.** For workflows with long journals, run them with
  `runWorkflowWith` and a `snapshotPolicy` (set via the generic-lens label,
  `opts & #snapshotPolicy .~ Every n`) so a resume hydrates from a snapshot plus
  the journal tail instead of replaying every step. The workflow snapshot uses
  `workflowStateCodec` with the fixed shape hash `keiro.workflow.stepmap.v1`
  (distinct from the `regFileShapeHash` used by aggregate snapshots — intentional,
  because step names are dynamic).

See the [Durable Workflows guide](../guides/durable-workflows.md) and the
[user reference](durable-workflows.md).

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

Keiro emits OpenTelemetry **spans** through `Keiro.Telemetry`: an `Internal` span around
`runCommand` (opt-in via `RunCommandOptions.tracer`), a `Producer` span around outbox
publishing, and `Consumer` spans parented via W3C trace headers.

Keiro also emits OpenTelemetry **metrics** through `Keiro.Telemetry`. Metrics are opt-in
and no-op by default: build the instrument set once from an SDK `Meter`
(`Keiro.Telemetry.newKeiroMetrics`) and thread the resulting `KeiroMetrics` handle into the
workers; with no meter configured (`Nothing`) the instruments do nothing. The instrument
names below are the canonical `keiro.*` names; they are defined and reconciled in
[`opentelemetry-semconv-audit.md`](../research/opentelemetry-semconv-audit.md).

### Metric catalogue

Outbox publisher (`Keiro.Outbox`):

- `keiro.outbox.backlog` — Gauge, `{event}` — claimable rows waiting in `keiro_outbox`,
  recorded each poll pass. Alert when it grows without draining.
- `keiro.outbox.published` — Counter, `{event}` — successfully published rows. Watch for
  the rate dropping to zero while backlog rises.
- `keiro.outbox.retried` — Counter, `{event}` — publish attempts that failed and will be
  retried. A sustained rise signals a failing destination.
- `keiro.outbox.deadlettered` — Counter, `{event}` — rows that exhausted their attempts.
  Any increase should page.

Inbox (`Keiro.Inbox`):

- `keiro.inbox.processed` — Counter, `{message}` — messages handled to completion.
- `keiro.inbox.duplicates` — Counter, `{message}` — duplicate deliveries short-circuited by
  `(source, dedupe_key)`. A high ratio is expected under at-least-once delivery; a sudden
  spike can indicate an upstream redelivery storm.
- `keiro.inbox.failed` — Counter, `{message}` — handler failures (retried or dead). Alert
  on a rising rate.
- `keiro.inbox.backlog` — Gauge, `{message}` — unprocessed/retained inbox rows, recorded
  each poll pass. Alert on unbounded growth (also a GC-cadence signal).

Timer worker (`Keiro.Timer`):

- `keiro.timer.backlog` — Gauge, `{timer}` — due `Scheduled` timers not yet claimed,
  recorded each poll pass. Alert when due timers are not being drained.
- `keiro.timer.fire.lag` — Histogram, `ms` — delay in milliseconds between a timer's
  scheduled time and when it actually fired. Alert on a high p99.
- `keiro.timer.attempts` — Histogram, `{attempt}` — number of attempts a timer took to
  fire; a rising distribution indicates repeated re-claims of stuck rows.
- `keiro.timer.stuck` — Gauge, `{timer}` — rows parked in `Firing` past the threshold (the
  recovery runbook's target), recorded each poll pass. Any non-zero value should be
  investigated. (The terminal `Dead` state is distinct and not counted here.)

Async projection path (`Keiro.Projection` / `Keiro.ReadModel`):

- `keiro.projection.lag` — Gauge, `{event}` — events between the stream head and a
  subscription's checkpoint, recorded each drain pass. Alert when lag climbs steadily.
- `keiro.projection.wait.timeouts` — Counter, `{timeout}` — position-wait calls that timed
  out before the projection caught up. A rising rate means read-after-write waits are not
  being satisfied in time.

These names are owned by the metrics foundation plan
(`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`) and recorded
by the outbox/inbox plan (`docs/plans/35-instrument-the-outbox-and-inbox-workers-with-metrics.md`)
and the timer/projection plan
(`docs/plans/36-instrument-the-timer-and-projection-workers-with-metrics.md`). If a shipped
instrument name, kind, or unit differs from the list above, update this catalogue and
[`opentelemetry-semconv-audit.md`](../research/opentelemetry-semconv-audit.md) together.

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
- Run the timer stuck-row recovery job (`findStuckTimers` → `requeueStuckTimer` / `cancelTimer` / `deadLetterTimer`); see Timers.
- Decide outbox dead-letter handling and inbox retention/GC cadence.
- Load test command paths that touch long streams.
- Document which APIs are considered stable for your application.
