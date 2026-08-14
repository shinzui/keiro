# Operations

This page collects deployment and runtime concerns for Keiro applications.

## Operating Keiro

Install the `keiro-ops` package to get the standalone database operations
console. Point it at PostgreSQL with `--database-url`,
`KEIRO_OPS_DATABASE_URL`, `DATABASE_URL`, or the normal libpq `PG*` variables:

```console
keiro-ops --database-url "$DATABASE_URL" --help
keiro-ops --database-url "$DATABASE_URL" outbox backlog
keiro-ops --database-url "$DATABASE_URL" wf list --json
```

Every invocation verifies the live Keiro schema before opening the command
environment. Read-only commands report drift as warnings. Mutations fail closed
on drift unless the operator explicitly supplies `--allow-schema-drift`, and
they first return an exact preview plus a `--force` reinvocation. Permanent
stream operations also require the stream name to be typed in human mode.
`--json` emits the same result value as the human table and is the stable
automation surface.

The standalone executable can operate only on capabilities whose complete
contract lives in the database. Application-code-dependent commands are
mounted from the candidate application binary with `Keiro.Ops.AppHooks` and
`Keiro.Ops.mainWithHooks` (or by composing `opsCommandTree` and
`runOpsInvocation` into an existing parser):

```haskell
Ops.AppHooks
  { workflowResume = Just (applicationWorkflowRegistry, resumeOptions)
  , timerFire = Just applicationTimerFire
  , replayAudit = Just (Ops.OpsAuditConfig applicationAuditTargets)
  , projectionCatalog = Just applicationCatalogOperations
  }
```

A hook-dependent command is absent from help when its hook is absent. The
worked mounting point is `jitsurei/app/Main.hs`; inspect it with:

```console
cabal run jitsurei:exe:jitsurei-demo -- ops --help
```

### Durable subscription positions

Kiroku completed
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2` in
`kiroku-store` 0.4.0.0. The standalone console now reads that public durable
inventory; it does not query Kiroku's private tables. List every persisted
subscription/member checkpoint, including rows whose worker is no longer
running, in human or JSON form:

```console
keiro-ops stream subscriptions
keiro-ops stream subscriptions --json
```

Human output repeats the store position captured by the same Kiroku statement:

```text
subscription  member  checkpoint_position  checkpoint_updated_at       store_position  global_position_distance
orders        0       35                   2026-08-09T14:00:00Z         42              7
orders        1       40                   2026-08-09T14:01:00Z         42              2
```

The JSON automation surface is stable:

```json
{
  "store_position": 42,
  "checkpoints": [
    {
      "subscription": "orders",
      "member": 0,
      "checkpoint_position": 35,
      "checkpoint_updated_at": "2026-08-09T14:00:00Z",
      "global_position_distance": 7
    }
  ]
}
```

Inspect one subscription's members and slowest-member floor with:

```console
keiro-ops projection position --subscription orders
keiro-ops projection position --subscription orders --json
```

Projection JSON uses `members` for the matching rows and adds
`minimum_checkpoint_position` plus `maximum_global_position_distance`. A
missing subscription returns an empty `members` array and `null` summaries; it
does not manufacture member zero or checkpoint zero.

`global_position_distance` is the non-negative subtraction of a durable
checkpoint from the captured global store cursor. It is not an event count:
filtered, category, hard-deleted, and sharded histories may skip global
positions. A true relevant-event lag needs a compatible source frontier and a
definition supplied by the owning library, so there is deliberately no
`projection lag` command.

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
embedded native `pg-migrate` components are the single source of schema truth.
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
- operator tooling that lists rejected dispatches and replays Kiroku
  subscription dead letters through idempotent handlers.

Keiro does not supervise these OS processes. Use your normal process manager,
container orchestrator, or service framework.

## Command Retries

`runCommand` retries optimistic concurrency conflicts. The command decision is
recomputed after each rehydrate.

Keep command handlers deterministic with respect to stored history. Generate
external ids before calling `runCommand` and pass them through command data or
`RunCommandOptions.eventIds`.

## Replayability Safety

Every command-side stream should be validated before it reaches a runner.
Public write APIs require `ValidatedEventStream`, which is produced by
`mkEventStream` or `mkEventStreamOrThrow` after Keiki checks hidden inputs, head
recoverability, inversion ambiguity, guarded reads, output-free state changes,
guard determinism, and dead edges. Treat validation failures as deploy-time
incidents: a replay-unsafe aggregate can make live state diverge from rebuilt
state after restart or snapshot fallback.

See [Replayability Safety](replay-safety.md) for the exact guarantee and the
application responsibilities that remain outside the type-level boundary.
When the candidate application mounts its audit targets, use the embedded
command as the deployment gate:

```console
yourapp ops replay-audit --target EventTypeChanged --json
yourapp ops replay-audit --full --json
```

Targeted mode accepts one or more affected stored event types. Full mode audits
every configured category. Both accept `--budget`, `--parallelism`, and
`--resume-from`; the process exits nonzero on a decode failure or seed
divergence.

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

See [Dead Letters And Replay](dead-letters.md) before acknowledging rejected
dispatches or replaying terminal subscription failures.

See [Run And Operate Jitsurei](../guides/run-and-operate-jitsurei.md) for the
guide-backed local verification path and the operational assumptions behind the
example package.

## Read Models

Use `ReadModel.version` and `shapeHash` to force stale readers to fail closed.

For catalog-managed read models, register one validated
`Keiro.Projection.Catalog.ValidatedProjectionCatalog` at startup and operate a
whole rebuild group rather than individual tables. Mount
`ProjectionCatalogOperations` in `AppHooks`, then use the embedded commands:

```console
yourapp ops rebuild list
yourapp ops rebuild preview GROUP
yourapp ops rebuild start GROUP --run-id RUN --requested-by OPERATOR --reason TEXT
yourapp ops rebuild status RUN
yourapp ops rebuild resume RUN
yourapp ops rebuild abandon RUN --code CODE --detail TEXT
yourapp ops rebuild adopt GROUP
yourapp ops rebuild versioned start GROUP --run-id RUN --serving-revision V1 --candidate-revision V2 --page-size 100 --cutover-threshold 10 --cutover-lock-timeout-ms 2000 --retention-seconds 600 --requested-by OPERATOR --reason TEXT
yourapp ops rebuild versioned status RUN
yourapp ops rebuild versioned resume RUN
yourapp ops rebuild versioned abandon RUN
yourapp ops rebuild retired
yourapp ops rebuild drop-retired GENERATION_UUID
yourapp ops rebuild external-read CONTRACT VERSION
yourapp ops rebuild retire-external-read CONTRACT VERSION
```

For a runnable local mount with the real `jitsurei-order-reporting` group, see
[Rehearse A Catalog Rebuild](../guides/run-and-operate-jitsurei.md#rehearse-a-catalog-rebuild).
That walkthrough distinguishes the standalone binary from an application
binary, shows read-only text/JSON inventory and preview, and keeps forced
execution scoped to the disposable example database.

`list`, `preview`, `status`, `versioned status`, `retired`, and `external-read`
are read-only. `start`, `resume`, `abandon`, their versioned counterparts,
`drop-retired`, and `retire-external-read` return a preview unless `--force` is
supplied. The preview comes directly from
the mounted validated catalog and reports its fingerprint, qualified targets,
clear/preserve policy, sources, subscription and dedup resets, verification
hooks, lock scope, and destructive disposition. The runtime then fences the
group, captures one fixed head, prepares every declared target atomically,
replays with durable progress, verifies, and promotes. A failed run stays
fenced; repair the application-owned cause and resume the same run. Abandonment
records explicit failure evidence and does not expose partial data.

To recover a rebuild stranded by the 0.12 identity migration, first run each
mutation without `--force` and review its preview. The run table's `group_slice`
column shows `$pre-canonical`, which means the historical run cannot be resumed.
Then execute the supported recovery sequence:

```console
yourapp ops rebuild abandon OLD_RUN --code operator.pre-canonical --detail "discard run stranded by migration 0024" --force
yourapp ops rebuild adopt GROUP --force
yourapp ops rebuild start GROUP --run-id NEW_RUN --requested-by OPERATOR --reason "fresh canonical rebuild" --force
```

Abandon records evidence and keeps the group fenced. Adoption stamps the
reviewed canonical slice but preserves the failed state, so startup registration
continues to fail with `RegisteredGroupStaleFingerprint` until that adoption
succeeds. The fresh start is allowed from `failed` after the slice matches; it
replays and verifies normally, and promotion returns the group to live service.
Use a new run id when retrying a start whose id was already persisted.

These commands wrap `catalogInventoryReport`, `previewRegisteredGroupRebuild`,
`startGroupRebuild`, `inspectGroupRebuild`, `resumeGroupRebuild`, and
`abandonGroupRebuild`, plus the supported versioned-generation and external-read
inspection/retirement APIs. There is no parallel name-to-action rebuild map.

`ClearBeforeReplay` uses a single foreign-key-compatible multi-table truncate
without `CASCADE`; undeclared references fail and roll the preparation back.
`PreserveAndReconcile` retains brownfield rows and therefore needs idempotent
replay adapters plus application verification. Application code owns desired DDL;
Keiro owns the schema-versioned staging, replay, validation, atomic promotion, and
retirement protocol described in
[Online Schema-Versioned Projection Rebuilds](../guides/online-projection-rebuilds.md).

## Snapshots

Snapshots are optional acceleration. Monitor hydration latency before enabling
them widely.

Snapshot corruption or shape mismatch falls back to full replay. Event-log
corruption does not.

## Stream Truncation

Keiro never truncates streams itself. Kiroku's per-stream truncation marker is
an operator-controlled visibility boundary, so take a covering Keiro snapshot
before moving it:

1. Inspect the snapshot with `keiro-ops snapshot show --stream STREAM`.
2. Run `keiro-ops snapshot truncation-preflight --stream STREAM --before VERSION`.
   Workflow journals have fixed public discriminators; aggregate streams also
   require `--state-codec-version`, `--regfile-shape-hash`, and
   `--state-shape-hash` from the candidate application.
3. Preview `keiro-ops stream truncate-before set STREAM VERSION` with the same
   discriminator flags, then re-run the emitted invocation with `--force` and
   type the stream name when prompted.
4. Run a command against the stream and monitor command errors before applying
   the same change broadly. Reverse the marker with
   `keiro-ops stream truncate-before clear STREAM`, also previewed before force.

If visible history begins after the hydration seed's next expected version,
Keiro fails closed with `HydrationGapDetected expected observed`. If the marker
is above the stream head and the stream appears completely empty, an append can
repeatedly collide with the still-existing stream and end in `ConflictFixpoint`.
Both operations are reversible: call `clearStreamTruncateBefore` to restore
per-stream visibility.

Truncation hides events; it does not delete them. Kiroku's `$all`, category,
and subscription reads remain unchanged. Keiro snapshots are rows in
`keiro_snapshots`, not Kiroku's snapshot-event convention; coverage is based on
the snapshot row's recorded stream version. See [Snapshots](snapshots.md) for
the snapshot contract.

## Timers

Timer workers claim one due timer at a time. Multiple workers can run concurrently
because claims use row locking with `SKIP LOCKED` (`claimDueTimer`). The default
worker policy requeues a row left in `Firing` for five minutes; configure that
timeout explicitly with `requeueStuckAfter` when the handler's normal runtime is
longer, or set it to `Nothing` when a separate recovery job owns requeueing.

### Stuck-row recovery runbook

Run this as a periodic operational job:

1. List candidates with `keiro-ops timer stuck list --min-age 5m` and optionally
   `--min-attempts N`.
2. Preview `keiro-ops timer requeue TIMER_ID`, `timer cancel TIMER_ID`, or
   `timer dead-letter TIMER_ID --reason TEXT` according to the row's intended
   disposition, then re-run the emitted command with `--force`.
3. In an application-embedded console, preview and run one bounded worker pass
   with `yourapp ops timer drain-once --limit N`; it is available only when the
   application mounts its timer-fire action.

The commands wrap `findStuckTimers`, `requeueStuckTimer`, `cancelTimer`,
`deadLetterTimer`, and `drainDueTimersWith`. For automatic attempt ceilings,
build validated `TimerWorkerOptions` with `maxAttempts` and
`requeueStuckAfter`; a claimed timer beyond the ceiling is dead-lettered instead
of fired.

Monitor the `keiro.timer.stuck` gauge (rows still in `Firing` past the threshold; see
Observability) before and after a run to confirm the job is draining the backlog rather
than churning. `Dead` is a distinct terminal state and is not counted by that gauge; track
it with a separate query (`status = 'dead'`) if you want a dead-letter count.

## Durable Workflows

Durable workflows (`Keiro.Workflow`) journal each named step to `wf:<name>-<id>`
and resume by re-invocation. Use the standalone console for database-generic
inspection and repair:

```console
keiro-ops wf list --status failed
keiro-ops wf show NAME ID
keiro-ops wf steps NAME ID
keiro-ops wf journal NAME ID
keiro-ops wf resurrect NAME ID
keiro-ops wf lease release NAME ID
keiro-ops wf gc run-once --retention 30d --batch 100
```

Mutations preview before force. Three application-aware tasks remain:

- **Resume worker.** The embedded
  `yourapp ops wf resume-once --limit N` command runs one bounded pass through
  the mounted application registry; `runWorkflowResumeWorker` remains the
  continuous service loop. Each pass discovers instance rows that are `running`
  or `suspended` with a due `wake_after`, and re-invokes them through the
  application's `WorkflowRegistry`, so suspended workflows resume after their waits
  resolve and after a process restart. Repeat bounded passes while
  `ResumeSummary.advanced > 0`. A stopped pass with `sleep_due > 0` means the
  timer worker is behind, down, or a sleep timer was cancelled; run or repair the
  timer worker rather than issuing more resume passes. The registry must hold a
  `WorkflowDef` for every workflow *name* still in flight; a discovered workflow
  whose name is absent is surfaced as `unknownName` in the `ResumeSummary`, never
  silently dropped.
- **Awakeable repair.** Inspect with `keiro-ops wf awakeable show UUID`. A
  workflow parked on an awakeable that will never be signalled is repaired with
  `keiro-ops wf awakeable cancel UUID`; an operator-supplied completion uses
  `keiro-ops wf awakeable signal UUID --payload JSON`. These commands wrap
  `cancelAwakeable` and `signalAwakeable`, which transition the
  `keiro_awakeables` row (`awakeable_id`, `owner_workflow_id`, `status`, `payload`)
  to `cancelled` or `completed`; the next resume observes a cancellation and the
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
- durable subscription checkpoints and their explicitly named global position distance;
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

Outcome-aware commands expose only the bounded decision class. Successful
spans carry `keiro.command.decision = accepted | rejected | no_op`, and the
`keiro.command.decisions` counter uses that same attribute. Never copy an
application rejection/no-op payload into metric labels, `error.type`, span
status descriptions, structured logs, or dispatch dead-letter reasons. Those
values can be sensitive and high-cardinality. Typed rejection and no-op are
successful span outcomes, not errors.

### Metric catalogue

This is the complete set of instruments `newKeiroMetrics` builds. Every one is a
no-op until the corresponding worker or runner is given the handle.

Outbox publisher (`Keiro.Outbox`):

- `keiro.outbox.backlog` — Gauge, `{event}` — claimable rows waiting in `keiro_outbox`,
  recorded each poll pass. Alert when it grows without draining.
- `keiro.outbox.published` — Counter, `{event}` — successfully published rows. Watch for
  the rate dropping to zero while backlog rises.
- `keiro.outbox.retried` — Counter, `{event}` — publish attempts that failed and will be
  retried. A sustained rise signals a failing destination.
- `keiro.outbox.deadlettered` — Counter, `{event}` — rows that exhausted their attempts.
  Any increase should page.
- `keiro.outbox.reclaimed` — Counter, `{event}` — rows reclaimed from a crashed or
  stalled publisher by `outboxMaintenancePass`. A sustained rate means workers are
  dying mid-publish.

Inbox (`Keiro.Inbox`):

- `keiro.inbox.processed` — Counter, `{message}` — messages handled to completion.
- `keiro.inbox.duplicates` — Counter, `{message}` — duplicate deliveries short-circuited by
  `(source, dedupe_key)`. A high ratio is expected under at-least-once delivery; a sudden
  spike can indicate an upstream redelivery storm.
- `keiro.inbox.failed` — Counter, `{message}` — handler failures (retried or dead). Alert
  on a rising rate.
- `keiro.inbox.poisoned` — Counter, `{message}` — messages dead-lettered after exhausting
  handler attempts. Any increase should page.
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
- `keiro.timer.requeued` — Counter, `{timer}` — timers returned from `Firing` to
  `Scheduled` after a stale claim. A rising rate means `requeueStuckAfter` is shorter than
  real handler runtimes, or workers are crashing mid-fire.

Async projection path (`Keiro.Projection` / `Keiro.ReadModel`):

- `keiro.projection.global_position_distance` — Gauge, `{position}` — the
  non-negative global cursor distance between the captured store position and
  the subscription's slowest durable member checkpoint, recorded each drain
  pass. Investigate a steadily growing distance, but do not interpret it as a
  count of relevant events.
- `keiro.projection.lag` — Gauge, `{position}` — deprecated compatibility alias
  recorded with the same value for the 0.11 release series. Migrate dashboards
  to `keiro.projection.global_position_distance`.
- `keiro.projection.wait.timeouts` — Counter, `{timeout}` — position-wait calls that timed
  out before the projection caught up. A rising rate means read-after-write waits are not
  being satisfied in time.

Command runners (`Keiro.Command`, opt in via `RunCommandOptions.metrics`):

- `keiro.command.decisions` — Counter, `{decision}` — successfully selected
  domain decisions partitioned by exactly `accepted`, `rejected`, or `no_op`.
  Alerting may use those three classes; it must not derive labels from
  application payloads.
- `keiro.command.conflicts` — Counter, `{conflict}` — optimistic-concurrency conflicts
  observed.
- `keiro.command.retries` — Counter, `{retry}` — retry attempts started after a conflict.
  Compare against conflicts to spot retry storms on hot streams.
- `keiro.command.duplicates` — Counter, `{event}` — appends rejected as duplicate
  deterministic event ids.

Snapshots (`Keiro.Snapshot`, recorded on the command path):

- `keiro.snapshot.read.hits` — Counter, `{read}` — lookups that yielded a usable seed.
- `keiro.snapshot.read.misses` — Counter, `{read}` — lookups that fell back to full replay.
- `keiro.snapshot.decode.failures` — Counter, `{failure}` — matching rows whose bytes
  failed to decode.
- `keiro.snapshot.encode.failures` — Counter, `{failure}` — post-commit encodes that failed
  and were swallowed.
- `keiro.snapshot.write.failures` — Counter, `{failure}` — post-commit writes that failed
  and were swallowed.
- `keiro.snapshot.apply.divergence` — Counter, `{failure}` — just-appended batches that
  failed to replay from the pre-command state. Any increase should page: the stream is
  poisoned and its next hydration will fail.
- `keiro.snapshot.seed.divergence` — Counter, `{failure}` — sampled seeds whose encoded
  state disagreed with a full replay. Any non-zero value should page (see
  [Snapshots](snapshots.md)).

Process-manager and router dispatch (`WorkerOptions.metrics`):

- `keiro.dispatch.failed` — Counter, `{command}` — dispatched commands that failed.
- `keiro.dispatch.duplicates` — Counter, `{command}` — dispatches skipped as duplicate
  deterministic event ids (normal under redelivery).
- `keiro.dispatch.poison` — Counter, `{message}` — worker messages classified as poison.
- `keiro.dispatch.deadlettered` — Counter, `{command}` — rejected dispatches handled by the
  dead-letter or skip policy.
- `keiro.subscription.deadlettered` — Counter, `{event}` — Kiroku source events
  dead-lettered by explicit disposition or retry exhaustion (recorded through
  `Keiro.Telemetry.kirokuEventBridge`).

Durable workflows (`WorkflowRunOptions.metrics` / `WorkflowResumeOptions`):

- `keiro.workflow.steps.executed` — Counter, `{step}` — steps that ran their action.
- `keiro.workflow.steps.replayed` — Counter, `{step}` — steps short-circuited to a recorded
  result.
- `keiro.workflow.active` — Gauge, `{workflow}` — runs in progress in this process.
- `keiro.workflow.journal.length` — Histogram, `{event}` — journal length at completion; a
  climbing distribution is the signal to enable snapshots or `continueAsNew`.
- `keiro.workflow.resumed` — Counter, `{workflow}` — re-invocations by the resume worker.
- `keiro.workflow.failed` — Counter, `{workflow}` — instances marked terminally failed.
  Any increase should page; recovery needs `resurrectFailedWorkflow`.
- `keiro.workflow.resume.errors` — Counter, `{error}` — transient store errors in the
  resume worker (these do not consume workflow attempts).
- `keiro.workflow.lease.skipped` — Counter, `{workflow}` — instances skipped because
  another worker holds the lease. A high rate against a small pool suggests `leaseTtl` is
  sized too long.
- `keiro.workflow.awakeables.pending` — Gauge, `{awakeable}` — awakeables awaiting a
  signal, recorded each resume pass.

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
