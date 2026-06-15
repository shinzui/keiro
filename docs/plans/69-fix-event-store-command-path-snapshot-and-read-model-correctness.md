---
id: 69
slug: fix-event-store-command-path-snapshot-and-read-model-correctness
title: "Fix event-store command path, snapshot, and read-model correctness"
kind: exec-plan
created_at: 2026-06-11T04:45:56Z
master_plan: "docs/masterplans/9-keiro-production-readiness-hardening.md"
---

# Fix event-store command path, snapshot, and read-model correctness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is child plan EP-3 of the MasterPlan at
`docs/masterplans/9-keiro-production-readiness-hardening.md`. Sibling plans referenced by
path only: `docs/plans/68-harden-keiro-core-codec-and-stream-contracts.md` (EP-2, soft
dependency — see Context), `docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md`
(EP-4, owns outbox/inbox/timer fixes — out of scope here), and
`docs/plans/71-fix-process-manager-and-router-delivery-correctness.md` (EP-5, owns
router/process-manager fixes — out of scope here).


## Purpose / Big Picture

Keiro's command path (hydrate an aggregate from its events, run a command, append the
emitted events) and its read side (snapshots, projections, read models) work on the happy
path but lie or crash on several unhappy ones. After this plan:

1. A command whose events have already durably committed can never be reported as failed
   just because the follow-up snapshot write failed. Today a transient database error
   during the post-commit snapshot write escapes `runCommand` as a `StoreError`, so the
   caller retries a command that already succeeded and — unless it supplied deterministic
   event ids — double-appends.
2. Querying a read model whose subscription is sharded across a consumer group no longer
   crashes. Today `readSubscriptionPosition` assumes one checkpoint row per subscription
   name, but kiroku stores one row per group member, so any group of size 2 or more makes
   position reads throw — which silently breaks `waitFor` (read-your-writes) and
   projection-lag metrics for exactly the read models large enough to be sharded.
3. `ConsistencyMode.Strong` becomes a real consistency level (block until the model's
   subscription has caught up to the log head) instead of a silent synonym for `Eventual`.
4. `AsyncProjection.idempotencyKey` does what its documentation promises: redelivered
   events are deduplicated by the library, in the same transaction as the projection write.
5. The hot read path stops performing a registry write per query, the registration
   statement loses its concurrency race, snapshot policy `Every n` fires when a multi-event
   append crosses a boundary, snapshots can be rewritten after a codec rollback,
   optimistic-concurrency retries back off and show up in telemetry, soft-deleted streams
   fail fast with a precise error, and unknown read-model statuses are loud.
6. Two documentation deliverables: a safe operator runbook for offline read-model rebuilds
   (in the `Keiro.ReadModel.Rebuild` haddocks) and a known-limits note on the kiroku
   `$all`-row append serialization ceiling (in the `Keiro` umbrella module haddock).

Everything is observable: each fix lands with a test in `keiro/test/Main.hs` that fails
against today's code and passes after, runnable with `cabal test keiro-test` from the
repository root.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — command path never lies, retries are visible:

- [x] Add `keiro.command.conflicts`, `keiro.command.retries`, `keiro.command.duplicates`,
      and `keiro.snapshot.write.failures` instruments to `KeiroMetrics` in
      `keiro/src/Keiro/Telemetry.hs` (name constants, record fields, `newKeiroMetrics`
      construction, `record*` helpers), following the existing dot-separated `keiro.*`
      naming catalogue. Completed 2026-06-15.
- [x] Add `metrics :: !(Maybe KeiroMetrics)` and `retryBackoffMicros :: !Int` fields to
      `RunCommandOptions` in `keiro/src/Keiro/Command.hs`; defaults `Nothing` / `5000`.
      Completed 2026-06-15.
- [x] Guard `writeSnapshotIfNeeded` call sites in `runCommand` and
      `runCommandWithSqlEvents` with `tryError @StoreError`; swallow the failure and bump
      `keiro.snapshot.write.failures`. Completed 2026-06-15.
- [x] Test: a command that commits but whose snapshot write fails (CHECK-constraint
      injection on `keiro_snapshots`) returns `Right (Right CommandResult)`, the events are
      readable, and the failure counter reads 1. Completed 2026-06-15.
- [x] Add exponential backoff with jitter between optimistic-concurrency retries in
      `retryOrFail`; make `RetryExhausted` carry the true total attempt count
      (`retryLimit + 1`); update its haddock. Completed 2026-06-15.
- [x] Wire conflict/retry/duplicate counters into `retryOrFail` and the `StoreFailed
      DuplicateEvent` path; record the final 1-based attempt number on the command span as
      `keiro.retry.attempt`; truncate the span status description to 256 characters in
      `recordCommandOutcome`. Completed 2026-06-15.
- [x] Test: an exhausted retry budget reports `RetryExhausted 3` for `retryLimit = 2`,
      counters read conflicts=3 / retries=2, and a successful second-attempt command span
      carries `keiro.retry.attempt = 2`. Completed 2026-06-15.
- [x] Add `ConflictFixpoint !StreamVersion !StoreError` to `CommandError`; detect a
      `StreamAlreadyExists` conflict whose rehydration observes no version progress and
      fail fast instead of burning the retry budget; classify it in `commandErrorClass`.
      Completed 2026-06-15.
- [x] Test: a command against a soft-deleted stream returns `Left (ConflictFixpoint ...)`
      after one rehydrate, not `RetryExhausted` after three. Completed 2026-06-15.

Milestone 2 — snapshot policy and overwrite correctness:

- [ ] Add `shouldSnapshotSpan` (pre-append and post-append versions) to
      `keiro-core/src/Keiro/Snapshot/Policy.hs`; `Every n` fires when a multiple of `n`
      lies in `(pre, post]`; keep `shouldSnapshot` exported and unchanged for
      `Keiro.Workflow` (owned by sibling plans).
- [ ] Switch `writeSnapshotIfNeeded` in `keiro/src/Keiro/Command.hs` to
      `shouldSnapshotSpan`, threading the pre-append version it already holds.
- [ ] Test: a 2-events-per-command stream with policy `Every 3` snapshots at version 4
      (the append 2→4 crossed boundary 3); today it never snapshots.
- [ ] Widen the `writeSnapshotStmt` overwrite guard in
      `keiro/src/Keiro/Snapshot/Schema.hs` so a row with a different
      `state_codec_version` or `regfile_shape_hash` may be overwritten regardless of
      stream version.
- [ ] Test: after a "newer codec" snapshot exists at version 4, a version-2 write under a
      different codec version succeeds (codec rollback no longer bricks snapshotting).

Milestone 3 — read-model read path correctness:

- [ ] Change `lookupSubscriptionPositionStmt` in `keiro/src/Keiro/ReadModel.hs` to
      `SELECT min(last_seen)` with a `singleRow`/nullable decoder.
- [ ] Test: with two consumer-group member rows (positions 7 and 3),
      `readSubscriptionPosition` returns `Just (GlobalPosition 3)` instead of throwing.
- [ ] Move `storeHeadPosition` from `keiro/src/Keiro/Projection.hs` into
      `keiro/src/Keiro/ReadModel.hs` (exported); re-import it in `Projection.hs`.
- [ ] Implement `Strong` in `waitIfNeeded` as a `waitFor` to the store head position
      captured at query start, using a new exported `defaultStrongWaitOptions`; update the
      `ConsistencyMode` haddocks.
- [ ] Update the test fixture `counterReadModel` (`keiro/test/Main.hs`) to
      `defaultConsistency = Eventual` and retitle the inline-projection test; add Strong
      tests: immediate return at head, blocking until a forked thread advances the cursor,
      and immediate return on an empty log.
- [ ] Fix the `registerReadModel` readback race in `keiro/src/Keiro/ReadModel/Schema.hs`:
      replace the `WITH inserted ... UNION ALL` statement with
      `ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING ...`.
- [ ] Take registration off the hot path: `ensureReadModel` in
      `keiro/src/Keiro/ReadModel.hs` does `lookupReadModel` first and only calls
      `registerReadModel` when the row is missing.
- [ ] Test: two consecutive `runQuery` calls leave the registry row's `xmin` unchanged
      (no write per query); concurrent first-time registration smoke test passes.
- [ ] Add `UnknownStatus !Text` to `ReadModelStatus`; `statusFromText` preserves the raw
      text instead of silently mapping to `Paused`; test that a `'wedged'` status surfaces
      as `ReadModelNotLive ... (UnknownStatus "wedged")`.

Milestone 4 — honest async-projection contract and documentation:

- [ ] Add migration `keiro-migrations/sql-migrations/2026-06-10-00-00-00-keiro-projection-dedup.sql`
      creating `keiro_projection_dedup` keyed by `(projection_name, event_id)` with an
      `applied_at` pruning index.
- [ ] Implement the dedup guard in `applyAsyncProjection`
      (`keiro/src/Keiro/Projection.hs`): insert the idempotency key in the same
      transaction; skip `applyRecorded` on conflict. Add
      `pruneAsyncProjectionDedupBefore` and document the retention contract.
- [ ] Test: a non-idempotent (incrementing) async projection applied twice in two separate
      transactions counts the event once; after pruning its dedup row, a re-apply applies
      again (window semantics demonstrated).
- [ ] Write the offline-rebuild operator runbook into the
      `keiro/src/Keiro/ReadModel/Rebuild.hs` module haddock (sequence, verification,
      explicit non-goals).
- [ ] Add the kiroku `$all`-row append-serialization known-limits note to the
      `keiro/src/Keiro.hs` module haddock.
- [ ] Full verification: `cabal build all`, `cabal test keiro-test`,
      `cabal test keiro-migrations-test`, `cabal test jitsurei-test` all green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-15: The focused milestone-1 validation passed with `cabal test keiro-test --test-show-details=direct --test-options='--match /Keiro.Command/ --match /Keiro.Snapshot/'`: 24 examples, 0 failures. This covered the new retry metrics, duplicate counter, soft-delete fixpoint, span attempt attribute, truncated span status, and swallowed snapshot-write failure cases.
- 2026-06-15: Full `cabal test keiro-test --test-show-details=direct` passed after milestone 1: 172 examples, 0 failures.


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement `Strong` consistency as a wait for the store head position rather
  than deleting the constructor.
  Rationale: The MasterPlan audit flagged `Strong` as a read-your-writes footgun (it is
  byte-for-byte identical to `Eventual` today). Deleting it would be a breaking removal;
  implementing it gives callers the semantics the name promises using machinery that
  already exists (`waitFor` + `storeHeadPosition`). `Strong` only makes sense for models
  fed by an async subscription — for inline-projected models the subscription cursor never
  advances, so `Strong` would always time out; the haddocks now say this explicitly and
  the test fixture `counterReadModel` (an inline model) moves to `Eventual`.
  Date: 2026-06-10

- Decision: Implement the `AsyncProjection.idempotencyKey` dedup guard (new
  `keiro_projection_dedup` table written in the same transaction as `applyRecorded`)
  rather than removing the field.
  Rationale: The field's haddock already promises dedup; removing it would be a second
  breaking API change in the initiative, and the MasterPlan reserves the single accepted
  breaking change to EP-2 (`Codec.decode`). Table growth is one row per applied event per
  projection — the same order as the event log itself — and is bounded by the new
  `pruneAsyncProjectionDedupBefore` retention function. The dedup window only needs to
  cover the subscription mechanism's redelivery horizon (events since the last
  checkpoint), so even aggressive pruning is safe.
  Date: 2026-06-10

- Decision: Snapshot overwrite after a codec change is handled by widening the existing
  upsert's `WHERE` guard (overwrite allowed when `state_codec_version` or
  `regfile_shape_hash` differ), keeping one row per stream — not by moving to one row per
  codec version.
  Rationale: One-line SQL change, no migration, no unbounded row growth. The trade-off:
  during a rolling deploy where two processes run different codec versions, each process's
  snapshot write can overwrite the other's ("ping-pong"). That is benign — a snapshot miss
  falls back to full replay — and ends when the deploy completes. A row-per-codec-version
  design would need a migration, a new primary key, and garbage collection for abandoned
  codec versions, for no correctness gain.
  Date: 2026-06-10

- Decision: New command-path metrics follow the existing dot-separated `keiro.*`
  instrument naming already in `keiro/src/Keiro/Telemetry.hs` (`keiro.command.conflicts`,
  `keiro.command.retries`, `keiro.command.duplicates`, `keiro.snapshot.write.failures`),
  added as new fields on `KeiroMetrics` constructed in `newKeiroMetrics`.
  Rationale: The MasterPlan integration point says whichever plan lands first sets the
  naming pattern; the library already has twenty dot-separated instruments
  (`keiro.outbox.backlog`, ...), so consistency with the shipped catalogue wins. The
  "snake_case prefixed `keiro_`" phrasing in the MasterPlan matches the Haskell-side
  attribute-key identifiers (`keiro_retry_attempt`), which we also follow.
  Date: 2026-06-10

- Decision: Unknown read-model statuses get an `UnknownStatus !Text` constructor instead
  of a log line or a metrics counter.
  Rationale: `Keiro.ReadModel.Schema` has neither a logging effect nor a metrics handle,
  and threading one in for a decode fallback is disproportionate. With the constructor,
  `validateMetadata`'s existing `/= Live` check turns an unknown status into
  `ReadModelNotLive name (UnknownStatus raw)` — loud, carries the offending text, and
  needs no new plumbing. No code outside the `keiro` package matches on
  `ReadModelStatus` (verified by grep across `jitsurei` and `keiro-dsl`), so widening the
  sum is safe.
  Date: 2026-06-10

- Decision: OCC retry backoff is exponential (`retryBackoffMicros * 2^k`, capped at
  100 ms) with ±50% jitter derived from `GHC.Clock.getMonotonicTimeNSec` low bits — no new
  package dependency. The base is a new `RunCommandOptions.retryBackoffMicros` field
  (default 5000; 0 disables, used by tests).
  Rationale: `keiro` does not depend on `random`, and adding a dependency for three
  delays is not worth it; monotonic-clock low bits are plenty for decorrelating two
  contending writers. A configurable base keeps the conflict-heavy tests fast.
  Date: 2026-06-10

- Decision: The fix for registry write churn (M5) is a lookup-first `ensureReadModel`
  (read the row; insert only when absent), not a per-process registration cache, and
  `waitFor`'s poll loop keeps using `runTransaction`.
  Rationale: The model's `status` must be re-read on every query anyway — a cache would
  mask a concurrent `markRebuilding` and serve a mid-rebuild model. A single-SELECT
  transaction under ReadCommitted assigns no transaction id and writes no WAL, so the
  remaining cost is one BEGIN/COMMIT wrapper. Making it literally read-only would require
  a read-mode entry point on kiroku's `Store` effect (`runTxOnPool` hardcodes
  `TxSessions.Write` in `kiroku-store/src/Kiroku/Store/Effect.hs`), which is upstream
  surface this plan does not own. This adjusts the audit finding's "make waitFor's poll
  read-only" to "remove the per-query registry INSERT", which is where the actual churn
  is — note that the M2 fix alone would make it worse (its `DO UPDATE` writes a row
  version on every call), which is why M2 and M5 land together.
  Date: 2026-06-10

- Decision: The multi-event snapshot-boundary fix adds a new function
  `shouldSnapshotSpan` to `keiro-core/src/Keiro/Snapshot/Policy.hs` and leaves
  `shouldSnapshot` exported and unchanged.
  Rationale: `Keiro.Workflow` (`keiro/src/Keiro/Workflow.hs:442,490`) also calls
  `shouldSnapshot`; workflow snapshot semantics belong to the workflow plans
  (`docs/plans/72-...`, `docs/plans/73-...`), so this plan must not change behavior under
  them. An additive function keeps keiro-core non-breaking, per the MasterPlan rule that
  EP-2 owns the only breaking change.
  Date: 2026-06-10

- Decision: The soft-deleted-stream failure mode gets a dedicated `CommandError`
  constructor `ConflictFixpoint !StreamVersion !StoreError`, raised when a
  `StreamAlreadyExists` conflict is followed by a rehydration that observes the same
  stream version as the failed attempt.
  Rationale: The condition is precisely "the store says the stream exists, but reading it
  shows nothing new", which is what a soft-deleted stream produces (kiroku returns no
  events for soft-deleted streams but `NoStream` appends still collide). Naming the
  fixpoint rather than guessing "soft-deleted" keeps the error truthful if another cause
  ever produces the same observable. Only `StreamAlreadyExists` gets the fixpoint check;
  `WrongExpectedVersion` retries keep their current semantics because rehydration there
  normally observes progress.
  Date: 2026-06-10

- Decision: The `$all` append-serialization ceiling and the offline-rebuild operator
  procedure are documentation-only deliverables, per the MasterPlan Decision Log
  (2026-06-10): both are architectural, not hardening.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section is self-contained: it defines every term and names every file. Read it fully
before touching code.

### The repository and the packages this plan touches

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro` (a cabal multi-package
project; see `cabal.project`). Keiro is an event-sourcing framework: instead of storing
the current state of an entity in a table row, every change is stored as an immutable
*event* appended to that entity's *stream*, and current state is recomputed by replaying
the events. The packages relevant here:

- `keiro-core/` — pure contracts: event codecs, stream naming, snapshot policy. This plan
  touches exactly one file there: `keiro-core/src/Keiro/Snapshot/Policy.hs`.
- `keiro/` — the runtime. This plan's modules: `keiro/src/Keiro/Command.hs`,
  `keiro/src/Keiro/Snapshot.hs`, `keiro/src/Keiro/Snapshot/Codec.hs`,
  `keiro/src/Keiro/Snapshot/Schema.hs`, `keiro/src/Keiro/Projection.hs`,
  `keiro/src/Keiro/ReadModel.hs`, `keiro/src/Keiro/ReadModel/Rebuild.hs`,
  `keiro/src/Keiro/ReadModel/Schema.hs`, `keiro/src/Keiro/Telemetry.hs`, and the umbrella
  module `keiro/src/Keiro.hs` (documentation only).
- `keiro-migrations/` — SQL migrations embedded at compile time. Every `.sql` file under
  `keiro-migrations/sql-migrations/` is picked up automatically (via `embedDir` in
  `keiro-migrations/src/Keiro/Migrations.hs`) and applied in timestamped filename order;
  adding a file is all that is needed to ship a migration. Milestone 4 adds one.
- `keiro-test-support/` — the PostgreSQL test fixture (see "How tests work" below).
- The test suite for the `keiro` package is the single file `keiro/test/Main.hs`
  (~5,400 lines, hspec), run as `cabal test keiro-test`.

Keiro persists events through *kiroku*, a separate PostgreSQL event-store library pinned
in `cabal.project` (source readable at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`,
read-only for this plan). Kiroku exposes an effectful (`effectful` library) `Store` effect
(`Kiroku.Store.Effect`); errors are the `StoreError` sum
(`kiroku-store/src/Kiroku/Store/Error.hs`) thrown through `Effectful.Error.Static.Error
StoreError`. Two kiroku facts matter repeatedly below:

- `runTransaction` (the escape hatch keiro uses for all its own SQL) always runs
  `BEGIN ... COMMIT` at ReadCommitted isolation in *Write* access mode
  (`runTxOnPool` in `kiroku-store/src/Kiroku/Store/Effect.hs`), and maps any SQL/pool
  failure to `ConnectionError` and throws it.
- kiroku's `subscriptions` checkpoint table (created by
  `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`) has a
  composite unique key `(subscription_name, consumer_group_member)`: a *consumer group*
  (several worker processes sharing one logical subscription, each owning a shard of the
  streams) stores one `last_seen` checkpoint row **per member**. A non-grouped
  subscription is member 0 with group size 1 — one row.

### The command pipeline, in plain language

An *aggregate* is an entity whose state is the fold of its stream's events through a
*transducer* (a state machine from the `keiki` library). Running a command
(`keiro/src/Keiro/Command.hs`) means:

1. *Hydrate*: read the stream's stored events forward and replay them through the
   transducer to recover `(state, registers)` and the current *stream version* (the
   per-stream event counter; version 0 means empty). If the stream has a *snapshot* — a
   stored JSON copy of the folded state at a known version, in the `keiro_snapshots`
   table — hydration starts from it and replays only the tail.
2. *Transduce*: step the transducer with the command; it either rejects
   (`CommandRejected`) or emits zero or more events.
3. *Append*: encode the events and append them at the expected version
   (`NoStream` for version 0, `ExactVersion v` otherwise). If another writer appended
   first, the store returns a conflict (`WrongExpectedVersion` or `StreamAlreadyExists`)
   and the runner re-hydrates and retries — *optimistic concurrency control* (OCC) — up to
   `retryLimit` times, then gives up with `RetryExhausted`.

Three runners share this skeleton: `runCommand` (plain append, lines 355–393),
`runCommandWithSql` (extra SQL in the same transaction as the append), and
`runCommandWithSqlEvents` (lines 420–469; the callback also receives the emitted events —
this is what projections build on). After a successful append, both `runCommand` (line
390) and `runCommandWithSqlEvents` (line 464) call `writeSnapshotIfNeeded` (lines
538–556), which consults the stream's `SnapshotPolicy` and, when it fires, upserts the
folded state into `keiro_snapshots` via `Keiro.Snapshot.writeSnapshot` →
`Keiro.Snapshot.Schema.writeSnapshotRow` — **in a separate transaction, after the append
has committed**.

### The read side, in plain language

A *projection* folds recorded events into ordinary SQL tables (the *read model*).
`keiro/src/Keiro/Projection.hs` has two flavors: `InlineProjection` runs inside the
command's append transaction (never stale); `AsyncProjection` is applied later by an
application-driven subscription worker, checkpointing its progress in kiroku's
`subscriptions` table under `subscriptionName`, and carries an `idempotencyKey ::
RecordedEvent -> EventId` field whose haddock (lines 71–77) promises duplicate
suppression on redelivery.

`keiro/src/Keiro/ReadModel.hs` is the query side. A `ReadModel` names its table, its
subscription, and a schema identity (`version` + `shapeHash`) registered in the
`keiro_read_models` table (`keiro/src/Keiro/ReadModel/Schema.hs`; DDL in
`keiro-migrations/sql-migrations/2026-05-17-00-00-00-keiro-bootstrap.sql`). `runQuery`
first calls `ensureReadModel` (lines 194–204) which calls `registerReadModel` — an
`INSERT ... ON CONFLICT DO NOTHING` + readback — then validates version/shape/status, then
honours the `ConsistencyMode` (`Strong` | `Eventual` | `PositionWait opts`), then runs the
query. `waitFor` (lines 162–192) implements `PositionWait` by polling
`readSubscriptionPosition` (lines 240–257) until the subscription's `last_seen` reaches a
target *global position* (the monotonically increasing position of an event in the
store-wide `$all` log). `Keiro.ReadModel.Rebuild` wraps the registry status transitions
(`Rebuilding`/`Live`/`Abandoned`) for taking a model offline to repopulate it.

`keiro/src/Keiro/Telemetry.hs` is the single OpenTelemetry surface: span helpers
(`withCommandSpan`, lines 321–338, which accepts a never-used retry-attempt argument) and
the `KeiroMetrics` record of instruments (lines 548–569) built by `newKeiroMetrics`. All
helpers take `Maybe` handles and no-op on `Nothing`.

### The findings this plan fixes (verified 2026-06-10 against the working tree)

Severity tags are from the June 2026 production-readiness audit recorded in the
MasterPlan. Line numbers re-verified during plan authoring; re-verify before editing
(especially in `Command.hs`, which EP-2 also edits — see "Coordination" below).

**H1 — a failed snapshot write makes a committed command look failed.**
`keiro/src/Keiro/Command.hs:390` and `:464`: after the append (or append + inline
projection transaction) commits, `writeSnapshotIfNeeded` runs unguarded in a separate
transaction. `writeSnapshotRow` uses `runTransaction`, which throws `ConnectionError` on
any failure, and the runners' `Error StoreError` constraint lets it escape `runCommand`
*after the events are durable*. Callers observe a failure for a command that succeeded;
a retry double-appends unless `eventIds` were supplied deterministically.

**H3 — `readSubscriptionPosition` crashes on consumer-group subscriptions.**
`keiro/src/Keiro/ReadModel.hs:248–257` selects `last_seen ... WHERE subscription_name =
$1` and decodes with `D.rowMaybe`, which demands at most one row. Kiroku stores one row
per group member (composite unique key — see above), so any group of size ≥ 2 makes hasql
fail with `UnexpectedAmountOfRows`, surfaced as a thrown `ConnectionError`. That breaks
`waitFor` (so `PositionWait` and, after this plan, `Strong`) and
`recordProjectionLag` (`keiro/src/Keiro/Projection.hs:128–138`) for exactly the sharded
read models.

**M2 — `registerReadModel` readback race.** `keiro/src/Keiro/ReadModel/Schema.hs:118–141`:
the statement is `WITH inserted AS (INSERT ... ON CONFLICT (name) DO NOTHING RETURNING ...)
SELECT ... FROM inserted UNION ALL SELECT ... FROM keiro_read_models WHERE name = $1
LIMIT 1`. Under ReadCommitted, when two sessions insert the same new name concurrently,
the loser's `DO NOTHING` observes the winner's row (conflict arbitration sees committed
rows), but the trailing `SELECT` runs against the statement snapshot taken *before* the
winner committed — zero rows from both branches — and `D.singleRow` throws.

**M3 — `Strong` is a no-op.** `keiro/src/Keiro/ReadModel.hs:88–92` (constructor) and
`233–234` (`waitIfNeeded _ Strong _ = pure (Right ())`, identical to `Eventual`). A
caller choosing `Strong` for read-your-writes silently gets eventual consistency.

**M4 — `idempotencyKey` promises dedup that never happens.**
`keiro/src/Keiro/Projection.hs:71–77` (haddock: "used to suppress duplicate application
on redelivery") versus `:114–116` (`applyAsyncProjection projection recorded =
(projection ^. #applyRecorded) recorded` — the key is never consulted). Every
async-projection author who trusted the haddock has a silent double-apply bug.

**M5 — a registry write transaction on every read-model query.**
`keiro/src/Keiro/ReadModel.hs:148–156` → `ensureReadModel` (194–204) →
`registerReadModel`: every `runQuery` performs the INSERT-flavored registration. Today
the conflicting insert is mostly free, but the M2 fix (`DO UPDATE`) would make it a real
row write per query — lock and WAL churn on the hottest read path. (The related audit
note that `waitFor` polls "in write mode" is adjusted in the Decision Log: the poll is a
single SELECT that assigns no transaction id; the actionable churn is the registration
INSERT.)

**M7 (documentation) — rebuild is offline-only and uncoordinated.**
`keiro/src/Keiro/ReadModel/Rebuild.hs`: `rebuild` flips status so `runQuery` rejects, but
nothing repopulates the table, resets the subscription cursor, or verifies before
`promote`. The safe operator sequence exists only in people's heads; this plan writes it
into the module haddock. Online (shadow-table) rebuild is explicitly out of scope per the
MasterPlan Decision Log.

**L1 — `Every n` skips boundaries on multi-event appends.**
`keiro-core/src/Keiro/Snapshot/Policy.hs:30–32`: fires only when the *post-append*
version is an exact multiple of `n`. A command that appends from version 2 to version 4
under `Every 3` crosses the boundary at 3 but `4 mod 3 /= 0`, so streams whose batch
sizes never land exactly on a multiple never snapshot. The pre-append version needed for
a crossing check is already in scope at the call site
(`keiro/src/Keiro/Command.hs:546–556` — `current ^. #streamVersion`).

**L2 — OCC retry has no backoff and `RetryExhausted` misreports attempts.**
`keiro/src/Keiro/Command.hs:558–571`: retries are immediate (two contending writers
re-collide in lockstep), and the error carries `options ^. #retryLimit` although the
runner actually made `retryLimit + 1` attempts.

**L3 — retries are invisible in telemetry.** `keiro/src/Keiro/Command.hs:364` and `:430`
always pass `Nothing` as the retry attempt to `withCommandSpan`, so the
`keiro.retry.attempt` attribute (`keiro/src/Keiro/Telemetry.hs:204–205`) is dead code;
`KeiroMetrics` has no conflict/retry/duplicate counters at all; and
`recordCommandOutcome` (`Command.hs:524`) puts the full `show err` — which can embed
event-payload fragments from decode errors — into the span status description.

**L4 — soft-deleted streams burn the retry budget.** kiroku's reads return no events for
a soft-deleted stream, so hydration sees version 0 and `expectedVersion`
(`Command.hs:594–596`) chooses `NoStream`; the append then fails with
`StreamAlreadyExists` (the stream row still exists), which `isRetryableConflict`
(`Command.hs:663–667`) treats as retryable; rehydration observes version 0 again — a
fixpoint — and the runner futilely repeats until `RetryExhausted`, a misleading error.

**L5 — the snapshot overwrite guard ignores codec identity.**
`keiro/src/Keiro/Snapshot/Schema.hs:120–126`: the upsert's `WHERE
keiro_snapshots.stream_version <= EXCLUDED.stream_version` compares only versions. After
a codec rollback (a process running an older `state_codec_version` than the row), the
old-codec process can never write a snapshot until the stream's version passes the
stored one — and since `lookupSnapshot` filters by codec identity, it also never *reads*
one: snapshotting is bricked for that stream until the version catches up.

**L7 — unknown statuses silently become `Paused`.**
`keiro/src/Keiro/ReadModel/Schema.hs:199–205`: `statusFromText _ = Paused`. An operator
typo or a future status value silently pauses a model with no trace of the real value.

**Known-limits note (documentation)** — every kiroku append updates the
`streams.stream_id = 0` row (the `$all` global log; see `WHERE stream_id = 0` sites in
`kiroku-store/src/Kiroku/Store/SQL.hs` and the comment at `SQL.hs:505`), so all appends
across all streams serialize on one row lock. This is an architectural throughput
ceiling the MasterPlan explicitly documents rather than fixes; the note lands in the
`keiro/src/Keiro.hs` umbrella haddock.

### Coordination with EP-2 (soft dependency)

`docs/plans/68-harden-keiro-core-codec-and-stream-contracts.md` makes the initiative's
one breaking change: `Keiro.Codec.decode :: Value -> Either Text e`
(`keiro-core/src/Keiro/Codec.hs:82`) gains the stored event-type tag, and EP-2 updates
every call site — including `decodeRecorded` usage inside `hydrate`/`hydrateFull` in
`keiro/src/Keiro/Command.hs`. This plan edits *other* regions of the same module
(`appendOnce`, `appendWithSqlOnce`, `retryOrFail`, `writeSnapshotIfNeeded`,
`recordCommandOutcome`, `RunCommandOptions`, `CommandError`), so the overlap is textual,
not semantic. **Land this plan after EP-2.** If EP-2 has not landed when you start, the
hydration code you see will still use the old one-argument `decode` shape — that is fine;
nothing in this plan touches those lines. If line numbers have drifted, anchor on
function names, not numbers.

### Out of scope

Outbox, inbox, timer, and shard-worker fixes belong to
`docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md`. Router
and process-manager fixes (including the duplicate-event fold and `eventAlreadyIn`)
belong to `docs/plans/71-fix-process-manager-and-router-delivery-correctness.md`.
Workflow modules are owned by `docs/plans/72-...` and `docs/plans/73-...`; this plan must
not change `Keiro.Workflow`'s observable behavior (hence the additive
`shouldSnapshotSpan`). Online read-model rebuild and any redesign of the `$all` append
path are out of scope per the MasterPlan.

### How tests work

The keiro suite is `keiro/test/Main.hs`, an hspec program whose `main` is
`withMigratedSuite $ \fixture -> hspec $ ...`. `withMigratedSuite`
(`keiro-test-support/src/Keiro/Test/Postgres.hs`) starts one cached ephemeral PostgreSQL
server for the whole suite, applies all kiroku + keiro migrations once to a template
database, and `withFreshStore fixture` clones a fresh migrated database per example
(`around (withFreshStore fixture)`), handing the example a `Store.KirokuStore`. **Never
add per-example migration runs** — new tables must come from a real migration file so the
template carries them. Store actions run via `Store.runStoreIO storeHandle (...)`, which
returns `IO (Either StoreError a)`; raw SQL runs via `Store.runTransaction` with
`Tx.statement`/`Tx.sql`. Existing fixtures this plan reuses: `counterEventStream` (one
event per `Add` command), `multiCounterEventStream` (two events per `Add`),
`snapshotCounterEventStream` (snapshots `Every 2`), `counterReadModel` /
`counterInlineProjection` / `counterAsyncProjection` (a `counter_read_model` table
created per example by `initializeCounterReadModelTable`), `upsertSubscriptionCursorStmt`
(writes a `subscriptions` checkpoint row), and `snapshotVersionForStreamStmt` (reads the
snapshot version for a stream name). Telemetry assertions use the in-memory span
exporter (`inMemoryListExporter`, see the test at `Main.hs:664`) and the in-memory
metric exporter (`inMemoryMetricExporter` + `flattenScalarPoints`, see the test at
`Main.hs:954`).

Run the suite from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-test --test-show-details=direct
```

Expected tail of the output on success (counts will grow as this plan adds examples):

```text
Finished in ... seconds
... examples, 0 failures
Test suite keiro-test: PASS
```


## Plan of Work

Four milestones. Each is independently verifiable with `cabal test keiro-test` plus the
named examples; each leaves the tree green.

### Milestone 1 — the command path never lies, and retries are visible

Scope: H1, L2, L3, L4, and the telemetry additions they need. At the end, a committed
command can never surface a snapshot-write error; conflicts, retries, duplicates, and
snapshot-write failures each have a counter; the command span records the attempt that
produced its outcome; retries back off; exhaustion reports true attempt counts; and a
soft-deleted stream fails fast with `ConflictFixpoint`.

First the telemetry surface, since the command runner records into it. In
`keiro/src/Keiro/Telemetry.hs`, add four name constants next to the existing ones:

```haskell
keiroCommandConflictsName :: Text
keiroCommandConflictsName = "keiro.command.conflicts"
keiroCommandRetriesName :: Text
keiroCommandRetriesName = "keiro.command.retries"
keiroCommandDuplicatesName :: Text
keiroCommandDuplicatesName = "keiro.command.duplicates"
keiroSnapshotWriteFailuresName :: Text
keiroSnapshotWriteFailuresName = "keiro.snapshot.write.failures"
```

Add matching `Counter Int64` fields to `KeiroMetrics` (`commandConflicts`,
`commandRetries`, `commandDuplicates`, `snapshotWriteFailures`), construct them in
`newKeiroMetrics` with `counterI64` (units `{conflict}`, `{retry}`, `{event}`,
`{failure}`; one-line descriptions in the style of the existing ones), add the four
`record*` helpers via the existing `recordCounter` internal, and export everything. This
is purely additive; `KeiroMetrics` is built via `newKeiroMetrics`, so no caller breaks.

In `keiro/src/Keiro/Command.hs`, extend `RunCommandOptions` with two fields and update
`defaultRunCommandOptions` and the haddock:

```haskell
    , retryBackoffMicros :: !Int
    -- ^ Base delay before the k-th OCC retry: retryBackoffMicros * 2^k, capped at
    -- 100ms, with +/-50% jitter. 0 disables backoff (used by tests). Default 5000.
    , metrics :: !(Maybe KeiroMetrics)
    -- ^ Optional metrics handle for conflict/retry/duplicate/snapshot-failure
    -- counters. 'Nothing' records nothing, mirroring 'tracer'. Default 'Nothing'.
```

**H1.** Make `writeSnapshotIfNeeded` failure-proof. Give it the runner's error context
and the options (it needs `metrics`), and wrap the write:

```haskell
writeSnapshotIfNeeded ::
    forall phi rs s ci co es.
    (BoolAlg phi (RegFile rs, ci), IOE :> es, Store :> es, Error StoreError :> es, Eq co) =>
    RunCommandOptions ->
    EventStream phi rs s ci co ->
    Hydrated rs s ->
    [co] ->
    AppendResult ->
    Eff es ()
```

Inside, replace the bare `writeSnapshot ...` call with

```haskell
outcome <- tryError @StoreError (writeSnapshot (appendResult ^. #streamId) finalVersion codec finalState)
case outcome of
    Right () -> pure ()
    Left _ -> recordSnapshotWriteFailures (options ^. #metrics) 1
```

and update both call sites (`runCommand` line ~390, `runCommandWithSqlEvents` line ~464)
to pass `options`. The haddock on the module header ("Snapshots are written transparently
after a successful append") gains a sentence: a snapshot-write failure is swallowed and
counted, never surfaced, because the command has already committed.

**L2 + L3 + L4.** Restructure the retry loop so it knows the attempt number and the
previous conflict. Today `attempt :: Int -> Eff es (...)` takes "remaining"; change both
runners' loops to thread `attemptNo :: Int` (1-based) and `lastConflict :: Maybe
(StoreError, StreamVersion)` (the error of the previous attempt and the hydrated version
that attempt saw). Concretely, in each runner:

- `attempt attemptNo lastConflict` hydrates, then — *fixpoint check* — if `lastConflict`
  is `Just (StreamAlreadyExists{}, prevVersion)` and the fresh hydration's
  `streamVersion == prevVersion`, return
  `Left (ConflictFixpoint prevVersion previousError)` immediately.
- `retryOrFail` gains the options' metrics, the attempt number, and the conflict context.
  On a retryable conflict it records `recordCommandConflicts ... 1`; if budget remains it
  sleeps `backoffDelay options attemptNo`, records `recordCommandRetries ... 1`, and
  retries with `attemptNo + 1` and the new `lastConflict`; if exhausted it returns
  `RetryExhausted totalAttempts storeError` where `totalAttempts` is the actual number of
  attempts made (`retryLimit + 1` when the budget is fully burned) — update the
  `RetryExhausted` haddock to say "total attempts made". On a non-retryable error, when
  the error is `DuplicateEvent{}` record `recordCommandDuplicates ... 1`, then return
  `StoreFailed` as today.

Backoff helper (no new dependency):

```haskell
backoffDelay :: (IOE :> es) => RunCommandOptions -> Int -> Eff es ()
backoffDelay options attemptNo
    | base <= 0 = pure ()
    | otherwise = do
        nanos <- liftIO getMonotonicTimeNSec   -- GHC.Clock (base)
        let exp' = min 100000 (base * (2 ^ (attemptNo - 1)))
            jitter = Prelude.fromIntegral (nanos `Prelude.mod` Prelude.fromIntegral exp') - (exp' `Prelude.div` 2)
        liftIO (threadDelay (exp' + jitter))
  where
    base = options ^. #retryBackoffMicros
```

Add the new error constructor with a precise haddock:

```haskell
    | {- | Retrying after a 'StreamAlreadyExists' conflict re-observed the same
      stream version: the store says the stream exists but reading it shows no
      progress. The typical cause is a soft-deleted stream (reads return nothing,
      appends still collide). Carries the observed version and the conflict.
      -}
      ConflictFixpoint !StreamVersion !StoreError
```

and classify it in `commandErrorClass` as `"conflict_fixpoint"`.

Span fixes: in both runners, after `attempt` returns, the final 1-based attempt number is
known; record it on the span (when present) with
`addAttribute sp (unkey keiro_retry_attempt) n` inside `recordCommandOutcome` (pass the
attempt count in), which revives the dead `keiro_retry_attempt` key. The unused
`Maybe Int64` parameter of `withCommandSpan` can stay (other callers exist); the runners
keep passing `Nothing` there since the attribute is now set at completion with the true
value. Also in `recordCommandOutcome`, replace
`setStatus sp (Error (Text.pack (show err)))` with a truncated rendering:

```haskell
setStatus sp (Error (Text.take 256 (Text.pack (show err))))
```

keeping `error_type` (already low-cardinality via `commandErrorClass`) as the classifier.

Milestone-1 tests, all in the `describe "Keiro.Command"` block of `keiro/test/Main.hs`
(plus one new metric assertion pattern copied from the `Keiro.Telemetry metrics`
examples):

- *Committed command survives snapshot failure* (H1): using
  `snapshotCounterEventStream` (policy `Every 2`), run one command (version 1), then
  disable snapshot writes with a check constraint that only affects new rows —
  `Tx.sql "ALTER TABLE keiro_snapshots ADD CONSTRAINT keiro_snapshots_no_writes CHECK (false) NOT VALID"`
  — then run the second command with `metrics = Just keiroMetrics`. Assert the result is
  `Right (Right r)` with `r ^. #streamVersion == StreamVersion 2`, the two events read
  back, no snapshot row exists, and `keiro.snapshot.write.failures` flushed as
  `IntNumber 1`. Then drop the constraint and run two more commands; assert
  `snapshotVersionForStreamStmt` now returns `Just (StreamVersion 4)` (recovery).
  Against today's code the second command returns `Left (ConnectionError ...)` even
  though the events committed — that is the bug, demonstrated.
- *Exhaustion reports true attempts and counters* (L2/L3): `beforeAppend` that always
  appends a conflicting event (extend the existing `IORef` trick at `Main.hs:487` to
  fire on every attempt), `retryLimit = 2`, `retryBackoffMicros = 0`, metrics wired.
  Assert `Left (RetryExhausted 3 _)` (3 total attempts), conflicts counter 3, retries
  counter 2.
- *Successful retry records the attempt on the span* (L3): the existing
  one-shot-conflict scenario plus a tracer; assert the span has
  `keiro.retry.attempt == 2` (IntAttribute) and status `Unset`/`Ok`.
- *Soft-deleted stream fails fast* (L4): create a stream with one command, soft-delete
  it (`Store.softDeleteStream` from `Kiroku.Store` — check the exact export under
  `Kiroku.Store.Effect`/`Kiroku.Store` and import accordingly), run another command with
  metrics wired. Assert `Left (ConflictFixpoint (StreamVersion 0) (StreamAlreadyExists _))`
  and that the conflicts counter is 1 (one conflict, one rehydrate, no budget burn).
  Today this returns `RetryExhausted` after three identical cycles.
- *Truncated status description*: hydrate-decode-failure scenario (copy the
  `OtherEvent` setup at `Main.hs:519`) with a tracer and a long payload; assert the
  captured span's error-status description length is at most 256.

Acceptance: `cabal test keiro-test` green; the five new examples named above pass; all
pre-existing command examples (which use `defaultRunCommandOptions`) pass unchanged
because both new option fields default to off.

### Milestone 2 — snapshot policy crossings and codec-rollback overwrites

Scope: L1 and L5. At the end, multi-event appends snapshot when they cross an `Every n`
boundary, and a process running a different state-codec version can replace an
incompatible snapshot row.

**L1.** In `keiro-core/src/Keiro/Snapshot/Policy.hs`, add (and export) a span-aware
variant; keep `shouldSnapshot` untouched for `Keiro.Workflow`:

```haskell
{- | Like 'shouldSnapshot', but evaluated over the half-open version span
@(preVersion, postVersion]@ that one append covered. 'Every' @n@ fires when any
positive multiple of @n@ lies inside the span, so a batch append that jumps over
a boundary still snapshots (at the post-append version, the state actually held).
The other policies ignore the span and behave exactly as 'shouldSnapshot'.
-}
shouldSnapshotSpan :: SnapshotPolicy state -> Bool -> state -> StreamVersion -> StreamVersion -> Bool
shouldSnapshotSpan Never _ _ _ _ = False
shouldSnapshotSpan (Every interval) _ _ (StreamVersion pre) (StreamVersion post)
    | interval <= 0 = False
    | otherwise = post `Prelude.div` n > pre `Prelude.div` n
  where
    n = Prelude.fromIntegral interval
shouldSnapshotSpan OnTerminal terminal _ _ _ = terminal
shouldSnapshotSpan (Custom decide) _ state _ post = decide state post
```

(`post div n > pre div n` is exactly "a multiple of n in `(pre, post]`" for
non-negative versions; the single-event case `post == pre + 1` reduces to today's
`post mod n == 0`, so existing behavior for one-event appends is identical.)

In `keiro/src/Keiro/Command.hs` `writeSnapshotIfNeeded`, replace the `shouldSnapshot`
call with `shouldSnapshotSpan (eventStream ^. #snapshotPolicy) terminal finalState
(current ^. #streamVersion) finalVersion` — `current` is the pre-append `Hydrated`, whose
`streamVersion` is exactly the version before this append. Update the import.

**L5.** In `keiro/src/Keiro/Snapshot/Schema.hs` `writeSnapshotStmt`, widen the guard:

```sql
WHERE keiro_snapshots.stream_version <= EXCLUDED.stream_version
   OR keiro_snapshots.state_codec_version <> EXCLUDED.state_codec_version
   OR keiro_snapshots.regfile_shape_hash <> EXCLUDED.regfile_shape_hash
```

Update the statement's and `writeSnapshotRow`'s haddocks: the no-regress rule applies
*within* one codec identity; a write under a different codec identity always wins,
because a snapshot that the current codec cannot read is worthless to it (see Decision
Log on the rolling-deploy ping-pong trade-off). Also extend the module header in
`keiro/src/Keiro/Snapshot.hs` ("keeps only the highest-version snapshot per stream")
with the same caveat.

Milestone-2 tests:

- *Boundary crossing* (L1), in `describe "Keiro.Snapshot"`: add a fixture
  `everyThreeSnapshotCounterEventStream` — identical to
  `multiSnapshotCounterEventStream` (two events per `Add`) but `snapshotPolicy = Every 3`.
  Run `Add` twice (versions 0→2, then 2→4). Assert `snapshotVersionForStreamStmt`
  returns `Just (StreamVersion 4)`: the second append crossed boundary 3. Today it
  returns `Nothing` forever (even versions never satisfy `mod 3 == 0`).
- *Codec rollback overwrite* (L5), schema-level: `writeSnapshotRow` a row with
  `stateCodecVersion = 2` at version 4; then `writeSnapshotRow` with
  `stateCodecVersion = 1` at version 2; `lookupSnapshot streamId 1 hash` must return the
  version-2 row (today: `Nothing` — the write was silently skipped). Then assert the
  within-codec no-regress rule still holds: a v1 write at version 1 does not replace the
  v1 row at version 2.

Acceptance: the two new examples pass; the existing snapshot examples (exact-multiple
batches, corrupt/stale fallbacks, truncation fallback) pass unchanged.

### Milestone 3 — the read-model read path

Scope: H3, M3, M2, M5, L7. At the end, sharded subscriptions are readable, `Strong`
blocks until the head, registration is race-free and off the hot path, and unknown
statuses are loud. These land together because they all touch `runQueryWith`'s
verification-and-wait pipeline and its tests.

**H3.** In `keiro/src/Keiro/ReadModel.hs`, replace `lookupSubscriptionPositionStmt`:

```haskell
lookupSubscriptionPositionStmt :: Statement Text (Maybe GlobalPosition)
lookupSubscriptionPositionStmt =
    preparable
        """
        SELECT min(last_seen)
        FROM subscriptions
        WHERE subscription_name = $1
        """
        (E.param (E.nonNullable E.text))
        (D.singleRow (fmap GlobalPosition <$> D.column (D.nullable D.int8)))
```

An aggregate always returns exactly one row; `min` over zero rows is SQL `NULL`, which
the nullable column maps to `Nothing` — same external contract as today for the no-row
case. `min` is the correct fold for a consumer group: the group as a whole has reached a
position only when its *slowest* member has. Update `readSubscriptionPosition`'s haddock
to state the consumer-group semantics.

**M3.** Move `storeHeadPosition` (verbatim, with its haddock and the `positionGap`-free
parts) from `keiro/src/Keiro/Projection.hs` to `keiro/src/Keiro/ReadModel.hs`, export it
there, and import it back in `Projection.hs` (Projection already imports
`Keiro.ReadModel`; the reverse import would be a cycle, which is why the function moves).
Add the defaults and implement the mode:

```haskell
{- | The wait parameters 'Strong' uses: up to 5 seconds, polling every 20ms,
against the store head position captured when the query starts. The 'target'
field is ignored ('Strong' computes its own). -}
defaultStrongWaitOptions :: PositionWaitOptions
defaultStrongWaitOptions =
    PositionWaitOptions{target = Nothing, timeoutMicros = 5000000, pollMicros = 20000}
```

```haskell
waitIfNeeded metrics Strong readModel = do
    headPosition <- storeHeadPosition
    if headPosition <= GlobalPosition 0
        then pure (Right ())
        else waitFor metrics defaultStrongWaitOptions readModel headPosition
```

Rewrite the `ConsistencyMode` and module haddocks honestly: `Strong` = "block until this
model's subscription has caught up to the log head as of query start; only meaningful
for models maintained by an asynchronous projection that advances `subscriptionName` —
an inline-projected model's cursor never moves, so `Strong` against it times out with
`ReadModelWaitTimeout`. Inline models should declare `Eventual` (they are already
read-your-writes by construction)."

**M2.** In `keiro/src/Keiro/ReadModel/Schema.hs`, replace `registerReadModelStmt`'s SQL:

```sql
INSERT INTO keiro_read_models (name, version, shape_hash, status, last_built_at)
VALUES ($1, $2, $3, 'live', now())
ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
RETURNING name, version, shape_hash, last_built_at, status
```

`DO UPDATE` (unlike `DO NOTHING`) locks the conflicting row, waits out a concurrent
inserter, and re-checks against the *latest* row version, so `RETURNING` always yields
exactly one row — the snapshot hole is gone. The no-op `SET name = EXCLUDED.name`
deliberately leaves `version`/`shape_hash`/`status` untouched so drift detection still
works; note in the haddock that the row's `xmin` advances on conflict, which is why M5
keeps this statement off the hot path.

**M5.** In `keiro/src/Keiro/ReadModel.hs`, make `ensureReadModel` lookup-first:

```haskell
ensureReadModel readModel = do
    existing <- lookupReadModel (readModel ^. #name)
    metadata <- case existing of
        Just found -> pure found
        Nothing ->
            registerReadModel
                (readModel ^. #name)
                (readModel ^. #version)
                (readModel ^. #shapeHash)
    pure (validateMetadata readModel metadata)
```

The steady-state query path is now one SELECT (which must stay per-query: it carries the
`status` check that rejects mid-rebuild models). First-ever query still registers, and
concurrent first queries are safe thanks to M2.

**L7.** In `keiro/src/Keiro/ReadModel/Schema.hs`, add the constructor and adjust the
codecs:

```haskell
data ReadModelStatus
    = Live
    | Rebuilding
    | Paused
    | Abandoned
    | -- | A stored status string this library version does not recognize.
      -- Carried verbatim so the error a query surfaces names the real value.
      UnknownStatus !Text
```

`statusFromText` maps an unrecognized value `other` to `UnknownStatus other`;
`statusToText (UnknownStatus t) = t` (round-trip; the transition helpers never construct
it). `validateMetadata` in `ReadModel.hs` needs no change — `UnknownStatus _ /= Live`
already yields `ReadModelNotLive`. Update the module haddock line that currently
advertises the silent `Paused` fallback.

Milestone-3 tests, in `describe "Keiro.ReadModel"`:

- *Group position read* (H3): add a test statement like `upsertSubscriptionCursorStmt`
  but parameterized by `consumer_group_member` (and `consumer_group_size = 2`); insert
  members 0 at 7 and 1 at 3 under one name; call
  `Keiro.ReadModel.readSubscriptionPosition` (export it — it already is) and assert
  `Right (Just (GlobalPosition 3))`. Today this throws
  `ConnectionError`/`UnexpectedAmountOfRows`. Add a second assertion: `runQueryWith` in
  `PositionWait` mode with target 5 times out (min is 3), then after advancing member 1
  to 5 it succeeds — group semantics end to end.
- *Strong fixture honesty* (M3): change `counterReadModel`'s `defaultConsistency` to
  `Eventual` and retitle the first example to "queries inline projection with Eventual
  consistency" (its body is unchanged). This is required: with Strong implemented, the
  old fixture would wait on a cursor that never moves.
- *Strong returns at head* (M3): run a command with an inline projection, upsert the
  subscription cursor to the command's `globalPosition` (the head), `runQueryWith
  Nothing Strong counterReadModel` returns `Right (Right n)` promptly.
- *Strong actually blocks* (M3): cursor at head minus 1; `forkIO` a thread that sleeps
  ~100ms then upserts the cursor to head (each thread uses its own
  `Store.runStoreIO storeHandle` — the pool is thread-safe); the foreground Strong query
  returns `Right` and the measured elapsed time is at least ~50ms. This proves Strong is
  no longer a no-op without any long-timeout test.
- *Strong on an empty log* (M3): fresh database, no events: Strong returns immediately
  (`storeHeadPosition` is 0).
- *No registry write per query* (M5): after one warm-up `runQuery`, read
  `SELECT xmin::text FROM keiro_read_models WHERE name = $1`, run `runQuery` again,
  re-read `xmin`; assert equal. (With registration on the hot path and the M2 statement,
  `xmin` would advance every query.)
- *Concurrent first registration* (M2): two forked threads call `registerReadModel` for
  the same brand-new name simultaneously (synchronize the start with an `MVar`); assert
  both return `Right` metadata with `version` 1. The old statement could throw
  `UnexpectedAmountOfRows` from `D.singleRow` here; the race is timing-dependent, so this
  is a smoke test — the deterministic argument for the fix is the statement semantics
  described above, which the Decision Log and haddock record.
- *Unknown status is loud* (L7): `UPDATE keiro_read_models SET status = 'wedged' WHERE
  name = ...`, then `runQuery` returns
  `Left (ReadModelNotLive "counter-read-model" (UnknownStatus "wedged"))`.

Also update the existing `recordProjectionLag` import path if the `storeHeadPosition`
move requires it (it should not — the function was private to `Projection.hs`).

Acceptance: all new examples pass; the existing `PositionWait`, stale-schema, rebuild
transition, lag, and timeout-counter examples pass unchanged (they use `runQueryWith`
with explicit modes or `Eventual` after the fixture change).

### Milestone 4 — honest async projections, and the two documentation deliverables

Scope: M4, M7, and the `$all` known-limits note. At the end, redelivered events are
deduplicated by the library inside the projection transaction, dedup rows are prunable,
and the rebuild runbook and append-ceiling notes are in the haddocks.

**M4.** New migration `keiro-migrations/sql-migrations/2026-06-10-00-00-00-keiro-projection-dedup.sql`
(plain SQL with a leading comment, matching the style of the existing files — see
`2026-06-05-01-00-00-keiro-subscription-shards.sql`):

```sql
-- The keiro_projection_dedup table: per-projection idempotency ledger (EP-69 / M4).
--
-- applyAsyncProjection inserts (projection_name, idempotency key) in the same
-- transaction as the read-model write and skips the apply on conflict, so an event
-- redelivered by a subscription worker (e.g. replay since the last checkpoint after
-- a crash) is applied exactly once per projection. Rows are pruned by retention via
-- Keiro.Projection.pruneAsyncProjectionDedupBefore; the retention window only needs
-- to exceed the subscription mechanism's redelivery horizon.

CREATE TABLE IF NOT EXISTS keiro_projection_dedup (
  projection_name TEXT NOT NULL,
  event_id UUID NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (projection_name, event_id)
);

CREATE INDEX IF NOT EXISTS keiro_projection_dedup_applied_at_idx
  ON keiro_projection_dedup (applied_at);
```

No Haskell change is needed in `keiro-migrations` — `embedDir` picks the file up. The
suite's template database gains the table automatically via `withMigratedSuite`.

In `keiro/src/Keiro/Projection.hs`, implement the guard, keeping the public type
unchanged (`AsyncProjection -> RecordedEvent -> Tx.Transaction ()`):

```haskell
applyAsyncProjection :: AsyncProjection -> RecordedEvent -> Tx.Transaction ()
applyAsyncProjection projection recorded = do
    firstApplication <-
        Tx.statement
            (projection ^. #name, eventIdUuid ((projection ^. #idempotencyKey) recorded))
            insertProjectionDedupStmt
    when firstApplication ((projection ^. #applyRecorded) recorded)
```

with `insertProjectionDedupStmt :: Statement (Text, UUID) Bool` built from
`INSERT INTO keiro_projection_dedup (projection_name, event_id) VALUES ($1, $2)
ON CONFLICT DO NOTHING RETURNING TRUE` decoded with
`isJust <$> D.rowMaybe (D.column (D.nonNullable D.bool))` (a conflicting insert returns
zero rows; in the same-transaction double-apply case PostgreSQL sees the
uncommitted first insert and conflicts too, so the existing same-transaction test keeps
passing). `EventId` unwraps to `UUID` via a small local `eventIdUuid (EventId u) = u`.
Update the `AsyncProjection` and `applyAsyncProjection` haddocks: dedup is now real,
write-side, transactional, and keyed by `(name, idempotencyKey event)`; redelivery
*within the retention window* is exactly-once per projection; beyond the window it is
at-least-once again.

Add the pruning function (exported):

```haskell
{- | Delete dedup ledger rows for one projection older than the cutoff, returning
how many were removed. Run periodically (e.g. daily) with a cutoff comfortably
older than the subscription's worst-case redelivery horizon — events older than
the cutoff that are redelivered will be applied again. -}
pruneAsyncProjectionDedupBefore ::
    (Store :> es) => Text -> UTCTime -> Eff es Int64
```

implemented with `runTransaction` over `DELETE FROM keiro_projection_dedup WHERE
projection_name = $1 AND applied_at < $2` using `D.rowsAffected`.

**M7.** Rewrite the module haddock of `keiro/src/Keiro/ReadModel/Rebuild.hs` into an
operator runbook (prose, numbered):

1. Stop (or pause) the worker that applies this model's async projection; the registry
   only gates `runQuery`, it does not stop writers.
2. `rebuild model` — queries now fail fast with `ReadModelNotLive name Rebuilding`.
3. In one transaction: clear the projection table (e.g. `TRUNCATE` or scoped `DELETE`)
   and reset the model's subscription checkpoint rows
   (`UPDATE subscriptions SET last_seen = 0 WHERE subscription_name = ...` — all member
   rows for a consumer group).
4. Repopulate by running the projection from position 0. There is no in-library drain
   driver: the application drives `applyAsyncProjection` per event (this is also where a
   schema change to the table is applied first).
5. Verify before serving: `promote` performs no verification of its own — compare row
   counts or spot-check aggregates against the event log first.
6. `promote model` to serve again, or `abandonRebuild model` to back out (the model then
   stays unqueryable until an operator intervenes).

State explicitly: this is an offline procedure (queries fail while it runs); an online
shadow-table rebuild is out of scope for the library per
`docs/masterplans/9-keiro-production-readiness-hardening.md`.

**Known-limits note.** Append a "Known limits" paragraph to the module haddock of
`keiro/src/Keiro.hs`: kiroku assigns global positions by updating the single
`streams.stream_id = 0` (`$all`) row inside every append transaction, so *all appends
across all streams serialize on one row lock*. This is a deliberate design (gapless
global ordering) and an architectural throughput ceiling: total system write throughput
is bounded by the commit rate on one hot row regardless of how many streams or
connections exist. Sizing guidance: measure with your hardware; do not shard by running
multiple keiro instances against one database. Documented, not fixed, per the MasterPlan
Decision Log (2026-06-10).

Milestone-4 tests, in `describe "Keiro.ReadModel"` (or a new
`describe "Keiro.Projection dedup"` block) — the key point is the projection must NOT be
self-idempotent, unlike the existing `counterAsyncProjection`:

- *Library dedup across transactions*: define `incrementingAsyncProjection` whose
  `applyRecorded` does `INSERT ... ON CONFLICT (model_id) DO UPDATE SET amount =
  counter_read_model.amount + EXCLUDED.amount` against `counter_read_model` (pass
  `source_event_id = NULL` to dodge that column's UNIQUE constraint), `idempotencyKey =
  (^. #eventId)`. Append one event; run `applyAsyncProjection` for it in two *separate*
  `runTransaction` calls. Assert the amount equals the event's amount once. Today the
  second apply doubles it.
- *Same-transaction double apply still deduped*: the existing example at
  `Main.hs:917` keeps passing; additionally port its body to the incrementing projection
  to prove the guard (not the projection's own upsert) does the work.
- *Pruning window*: after the dedup test, call `pruneAsyncProjectionDedupBefore` with a
  cutoff in the future; assert it returns 1; re-apply the same event in a fresh
  transaction; assert the amount doubled — demonstrating (and documenting) that pruning
  reopens the at-least-once window.

Acceptance: new examples pass; `cabal test keiro-migrations-test` passes (the migrations
suite applies every embedded migration, now including the dedup table); haddock-only
changes verified by `cabal build keiro` (haddock syntax errors fail the build's doc
parsing only when building docs — also run `cabal haddock keiro` if available, otherwise
proofread).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Before starting, confirm the baseline is green and check whether EP-2
(`docs/plans/68-harden-keiro-core-codec-and-stream-contracts.md`) has landed (look at its
Progress section; if it is mid-flight, coordinate before editing
`keiro/src/Keiro/Command.hs`):

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git status
cabal build all
cabal test keiro-test --test-show-details=direct
```

Expected: clean tree, build succeeds, and the suite ends with

```text
... examples, 0 failures
Test suite keiro-test: PASS
```

Then per milestone (edit, test, commit — Conventional Commits, no feature branch):

```bash
# Milestone 1
cabal build keiro
cabal test keiro-test --test-show-details=direct
git add -A && git commit -m "fix(keiro): never fail committed commands on snapshot writes; visible, backed-off OCC retries"

# Milestone 2
cabal build keiro-core keiro
cabal test keiro-test --test-show-details=direct
git add -A && git commit -m "fix(keiro): snapshot Every-n boundary crossings and codec-identity overwrites"

# Milestone 3
cabal build keiro
cabal test keiro-test --test-show-details=direct
git add -A && git commit -m "fix(keiro): consumer-group position reads, real Strong consistency, race-free off-hot-path registration"

# Milestone 4
cabal build all
cabal test keiro-test --test-show-details=direct
cabal test keiro-migrations-test
git add -A && git commit -m "feat(keiro): transactional async-projection dedup; rebuild runbook and \$all-ceiling docs"
```

To run only the suites you are iterating on, hspec match works through cabal:

```bash
cabal test keiro-test --test-show-details=direct --test-options='--match "Keiro.Command"'
cabal test keiro-test --test-show-details=direct --test-options='--match "Keiro.ReadModel"'
```

Final verification (also exercises the jitsurei example service, which consumes
`runCommand` and read models and must compile and pass against the additive changes):

```bash
cabal build all
cabal test keiro-test
cabal test jitsurei-test
cabal test keiro-migrations-test
```

Each `cabal test` must end with `PASS`. Keep this plan's Progress section updated at
every stopping point, and append discoveries to Surprises & Discoveries with evidence.


## Validation and Acceptance

Beyond "tests pass", each headline behavior is observable as follows. (All scenarios are
encoded as the named hspec examples; this section states what a human reviewer should be
able to confirm by reading the test output and, where useful, by replaying the scenario
in a REPL or psql against an ephemeral database.)

1. *Committed commands never report snapshot failures* (H1): with snapshot writes
   disabled by the `CHECK (false) NOT VALID` constraint, a boundary-hitting command
   returns `Right (Right CommandResult{streamVersion = 2, ...})`, the stream readback
   shows both events, and the flushed metrics contain
   `keiro.snapshot.write.failures = 1`. Reverting just the `tryError` guard makes the
   example fail with `Left (ConnectionError ...)` — the exact production symptom.
2. *Sharded models are readable* (H3): with two member checkpoint rows (7 and 3),
   `readSubscriptionPosition` returns `Just (GlobalPosition 3)`; before the fix the same
   example dies with `ConnectionError` mentioning `UnexpectedAmountOfRows`.
3. *Strong blocks and releases* (M3): the blocking example measures elapsed time ≥ 50ms
   while a forked thread advances the cursor, then returns the queried value; the no-op
   implementation returns immediately and the elapsed-time assertion fails.
4. *Dedup is real* (M4): the incrementing projection applied twice across two
   transactions yields the amount once; before the fix it yields double.
5. *No hot-path registry writes* (M5): the `xmin` of the `keiro_read_models` row is
   identical before and after a second `runQuery`.
6. *Policy crossings* (L1): `Every 3` with 2-event batches snapshots at version 4;
   before the fix `snapshotVersionForStreamStmt` stays `Nothing`.
7. *Codec rollback* (L5): an old-codec write at a lower version replaces a newer-codec
   row; the within-codec no-regress rule still rejects same-codec stale writes.
8. *Retry visibility and honesty* (L2/L3): `RetryExhausted 3` for `retryLimit 2`;
   conflict/retry counters 3/2; span attribute `keiro.retry.attempt = 2` on a
   second-attempt success; error-status descriptions capped at 256 chars.
9. *Fail fast on soft-deleted streams* (L4): one conflict, one rehydrate,
   `ConflictFixpoint (StreamVersion 0) (StreamAlreadyExists _)` — not three blind cycles.
10. *Loud unknown statuses* (L7): a `'wedged'` row produces
    `ReadModelNotLive ... (UnknownStatus "wedged")`.
11. *Documentation*: `keiro/src/Keiro/ReadModel/Rebuild.hs` haddock contains the
    six-step runbook including the cursor-reset SQL and the "promote verifies nothing"
    warning; `keiro/src/Keiro.hs` haddock contains the `$all` serialization-ceiling
    paragraph. Reviewer check: read the rendered haddock or the source.

Full-suite acceptance: `cabal test keiro-test`, `cabal test keiro-migrations-test`, and
`cabal test jitsurei-test` all `PASS` from a clean checkout of the final commit.


## Idempotence and Recovery

Every step is an ordinary source edit plus a test run; re-running any command is safe.
Specific notes:

- The new migration uses `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`, so
  re-applying against a database that already has the table is harmless. Codd tracks
  applied migrations by filename; do not rename the file after it has been applied to any
  shared database. The test suite always builds a fresh template, so local iteration is
  unaffected.
- The test suite's ephemeral databases are created and dropped per example by
  `keiro-test-support`; a crashed test run can leave a cached server directory behind,
  which `ephemeral-pg` reuses or rebuilds on the next run — no manual cleanup needed.
- If Milestone 1's restructuring of the retry loop goes wrong midway, `git checkout --
  keiro/src/Keiro/Command.hs` restores the baseline; the telemetry additions
  (Milestone 1's first two steps) are independent and can be committed separately before
  the loop work starts — do that if you want a smaller blast radius.
- The `counterReadModel` fixture change (Strong → Eventual) intentionally alters an
  existing test's title and mode; if other examples unexpectedly fail after it, check
  they did not rely on `defaultConsistency = Strong` being a no-op (search
  `keiro/test/Main.hs` for `counterReadModel` uses — all current uses pass an explicit
  mode or expect immediate reads).
- All schema statements changed here (`registerReadModelStmt`,
  `lookupSubscriptionPositionStmt`, `writeSnapshotStmt`) are `preparable`; hasql prepares
  per connection, so no server-side state needs invalidating between test runs.
- If a previously committed milestone breaks while working on a later one, fix forward
  in the same plan and record the cause in Surprises & Discoveries.


## Interfaces and Dependencies

No new package dependencies anywhere (`GHC.Clock` and `Control.Concurrent` come from
`base`, already imported by the `keiro` package; the test additions use only packages
already in `keiro-test`'s `build-depends`). No new modules; no `.cabal` edits. The only
cross-package source edits are one additive function in `keiro-core` and one SQL file in
`keiro-migrations`.

Signatures that must exist when the plan is complete (full module paths; "additive"
means existing exports are unchanged):

In `keiro-core/src/Keiro/Snapshot/Policy.hs` (additive):

```haskell
shouldSnapshotSpan ::
    SnapshotPolicy state -> Bool -> state -> StreamVersion -> StreamVersion -> Bool
-- shouldSnapshot remains exported with its current signature and behavior.
```

In `keiro/src/Keiro/Telemetry.hs` (additive; establishes the MasterPlan KeiroMetrics
integration-point pattern — EP-4 and EP-6 add their counters the same way):

```haskell
keiroCommandConflictsName, keiroCommandRetriesName,
    keiroCommandDuplicatesName, keiroSnapshotWriteFailuresName :: Text

data KeiroMetrics = KeiroMetrics
    { -- ... all existing fields ...
    , commandConflicts :: Counter Int64
    , commandRetries :: Counter Int64
    , commandDuplicates :: Counter Int64
    , snapshotWriteFailures :: Counter Int64
    }

recordCommandConflicts, recordCommandRetries, recordCommandDuplicates,
    recordSnapshotWriteFailures :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
```

In `keiro/src/Keiro/Command.hs`:

```haskell
data RunCommandOptions = RunCommandOptions
    { retryLimit :: !Int
    , pageSize :: !Int32
    , eventIds :: ![EventId]
    , beforeAppend :: !(IO ())
    , tracer :: !(Maybe Tracer)
    , metadata :: !(Maybe Value)
    , retryBackoffMicros :: !Int          -- new; default 5000
    , metrics :: !(Maybe KeiroMetrics)    -- new; default Nothing
    }

data CommandError
    = HydrationDecodeFailed !CodecError
    | HydrationReplayFailed !StreamVersion
    | CommandRejected
    | EncodeFailed !CodecError
    | StoreFailed !StoreError
    | RetryExhausted !Int !StoreError      -- now: total attempts made
    | ConflictFixpoint !StreamVersion !StoreError   -- new
-- runCommand / runCommandWithSql / runCommandWithSqlEvents keep their signatures.
```

In `keiro/src/Keiro/ReadModel.hs` (additive):

```haskell
storeHeadPosition :: (Store :> es) => Eff es GlobalPosition   -- moved from Projection.hs
defaultStrongWaitOptions :: PositionWaitOptions
-- ConsistencyMode keeps its three constructors; Strong gains real semantics.
```

In `keiro/src/Keiro/ReadModel/Schema.hs`:

```haskell
data ReadModelStatus = Live | Rebuilding | Paused | Abandoned | UnknownStatus !Text
-- registerReadModel / lookupReadModel / mark* keep their signatures.
```

In `keiro/src/Keiro/Projection.hs`:

```haskell
applyAsyncProjection :: AsyncProjection -> RecordedEvent -> Tx.Transaction ()  -- now dedups
pruneAsyncProjectionDedupBefore :: (Store :> es) => Text -> UTCTime -> Eff es Int64  -- new
-- AsyncProjection / InlineProjection / runCommandWithProjections / recordProjectionLag unchanged.
```

New database object (via `keiro-migrations/sql-migrations/2026-06-10-00-00-00-keiro-projection-dedup.sql`):
table `keiro_projection_dedup (projection_name TEXT, event_id UUID, applied_at
TIMESTAMPTZ, PRIMARY KEY (projection_name, event_id))` with index
`keiro_projection_dedup_applied_at_idx`.

Upstream interfaces consumed, not changed: kiroku's `Store` effect
(`runTransaction`, `readAllBackward`, `softDeleteStream`, `appendToStream`,
`appendToStreamTx`), `StoreError` (`WrongExpectedVersion`, `StreamAlreadyExists`,
`DuplicateEvent`, `ConnectionError`), and the `subscriptions` table shape
(`subscription_name`, `last_seen`, `consumer_group_member`). The EP-1 kiroku change
(surfacing `DuplicateEvent` from transactional appends) will make the
`keiro.command.duplicates` counter fire on the `runCommandWithSqlEvents` path too; until
then it fires only where kiroku already reports duplicates — note this in the counter's
description if EP-1 has not landed when you wire it.
