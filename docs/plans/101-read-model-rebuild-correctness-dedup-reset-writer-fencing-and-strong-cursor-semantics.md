---
id: 101
slug: read-model-rebuild-correctness-dedup-reset-writer-fencing-and-strong-cursor-semantics
title: "Read-model rebuild correctness: dedup reset, writer fencing, and Strong cursor semantics"
kind: exec-plan
created_at: 2026-07-12T05:07:53Z
master_plan: "docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md"
---

# Read-model rebuild correctness: dedup reset, writer fencing, and Strong cursor semantics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Parent initiative: `docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`
(Phase 4, EP-101). This plan has no dependencies on the other child plans and can be
implemented at any time. Per the parent's standing directives, the jitsurei example
repositories must not be cited as evidence or migrated by this plan.


## Purpose / Big Picture

Keiro's read side today has three operational traps, all confirmed by reading the code
during the 2026-07 review and re-verified while authoring this plan.

First, following the documented rebuild runbook produces a silently empty read-model
table. The runbook in `keiro/src/Keiro/ReadModel/Rebuild.hs:11-30` says to truncate
the projection table and reset the subscription checkpoint (step 3, lines 18-20), but
never mentions the `keiro.keiro_projection_dedup` table: every asynchronous
projection application inserts a dedup row keyed by `(projection_name, event_id)`
inside the same transaction as the read-model update
(`keiro/src/Keiro/Projection.hs:127-134` and the insert statement at lines 170-182).
A replay through `applyAsyncProjection` therefore finds every event already recorded
in the dedup table, skips every single one, and the "rebuilt" table stays empty —
which the operator then promotes to `Live`. After this plan, a single helper performs
the whole reset atomically (status flip, table truncate, dedup delete, checkpoint
reset), and promotion refuses to serve a rebuild that applied nothing while the log
plainly has events.

Second, nothing stops a live projection worker from writing into a table that is
being truncated. `markRebuilding` fences only queries (readers), and the runbook
admits "The helpers here do not coordinate workers for you"
(`keiro/src/Keiro/ReadModel/Rebuild.hs:13-14`). After this plan, the write path
itself is fenced: `applyAsyncProjection` checks the read-model registry status
inside its own transaction and refuses to apply while the model is not `Live`, so a
racing worker cannot corrupt a rebuild no matter what the operator forgot to pause.

Third, the `Strong` consistency mode is unusable in any store with more than one
active event category. `Strong` waits for the model's subscription cursor to reach
the head of the entire `$all` log (`keiro/src/Keiro/ReadModel.hs:278-280` and
306-315), but kiroku never advances a category subscription's checkpoint on empty
fetches, so a fully caught-up projection over category A sits at A's last event
while category B pushes the global head ever forward. Every `Strong` query then
burns the full five-second timeout and fails with `ReadModelWaitTimeout`. After this
plan, a read model can declare that its `Strong` target is the head of its own
category, and a caught-up model answers promptly regardless of what other
categories are doing.

You can see all of it working by running the keiro test suite: a rebuild
end-to-end test repopulates a table that the current code leaves empty, a race test
shows a live applier being fenced during a rebuild, and a two-category test shows
`Strong` returning promptly where the current code times out.


## Progress

- [ ] M1: `ReadModelUnregistered` error constructor added to `ReadModelError`.
- [ ] M1: `ensureReadModel` no longer auto-registers; unknown-model queries fail closed.
- [ ] M1: test fixtures register models explicitly; new unregistered-query test passes.
- [ ] M2: `RebuildError` type and `startRebuild` helper (atomic status/truncate/dedup/checkpoint) exist.
- [ ] M2: `finishRebuild` helper with the zero-apply promotion guard exists.
- [ ] M2: red rebuild-per-current-runbook test written and observed failing (empty table).
- [ ] M2: green end-to-end rebuild test passes through the new helpers.
- [ ] M3: `AsyncProjection` carries `readModelName`; `applyAsyncProjection` returns `AsyncApplyOutcome` and fences on non-`Live` status.
- [ ] M3: `applyAsyncProjectionUnfenced` rebuild-path variant exists; all call sites updated.
- [ ] M3: writer-fence race test (live applier vs. rebuild) passes.
- [ ] M4: `StrongScope` field on `ReadModel`; `categoryHeadPosition` query implemented.
- [ ] M4: red cross-category `Strong` timeout test observed failing; green with `CategoryHead` scope.
- [ ] M5: `Rebuild.hs` runbook rewritten as a helper-enforced checklist; docs swept.
- [ ] M5: full `just haskell-build` and `cabal test keiro-test` pass; retrospective written.


## Surprises & Discoveries

Findings from authoring-time verification (2026-07-11); implementation entries go below.

- The dedup table is keyed per projection (`PRIMARY KEY (projection_name, event_id)`,
  `keiro-migrations/sql-migrations/2026-06-15-21-49-37-keiro-projection-dedup.sql:1-6`),
  so a rebuild reset can be scoped precisely to the projections feeding one model
  without touching other projections' dedup windows.
- kiroku's checkpoint save is monotonic by construction:
  `GREATEST(subscriptions.last_seen, EXCLUDED.last_seen)` in `saveCheckpointSQL`
  (kiroku-store, `src/Kiroku/Store/SQL.hs`, pinned tag in `cabal.project:24-35`).
  A checkpoint therefore cannot be reset through kiroku's own API — the rebuild
  helper must issue a direct `UPDATE subscriptions SET last_seen = ...`. Keiro
  already reads that table directly (`keiro/src/Keiro/ReadModel.hs:295-304`), so
  this deepens an existing, pinned coupling rather than creating a new one.
- kiroku's subscription state machine emits a `Checkpoint` effect only on
  `DeliverBatch`; `FetchEmpty` and `CaughtUp` transitions emit none
  (kiroku-store, `src/Kiroku/Store/Subscription/Fsm.hs`, `step` arms — verified in
  the local checkout of the pinned revision). This confirms finding 3's premise:
  an idle category subscription's `last_seen` freezes while the `$all` head moves.
- `Kiroku.Store.Read` exports no category-head or backward category read
  (`readStreamForward/Backward`, `readAllForward/Backward`, `readCategory`,
  `getStream`, lookups — the full export list at
  kiroku-store `src/Kiroku/Store/Read.hs:1-12`), so the category head must be
  computed keiro-side (see Decision Log).
- The existing `Strong` tests (`keiro/test/Main.hs:1346-1408`) only ever exercise a
  single category and advance the cursor by hand, which is why the cross-category
  liveness hole was never caught.


## Decision Log

- Decision: perform the whole rebuild reset — registry status to `rebuilding`,
  `TRUNCATE` of the projection table, `DELETE` of the model's projections' dedup
  rows, and the subscription checkpoint reset — in one database transaction inside
  a new `startRebuild` helper, rather than only extending the prose runbook.
  Rationale: the review offered "helper or runbook+guard"; a runbook cannot be
  atomic and the empty-table failure was caused precisely by prose drifting from
  the write path's actual invariants. The helper is the checklist. The registry
  `UPDATE` also takes the row lock the writer fence synchronizes on (see below),
  so atomicity and fencing come from the same transaction.
  Date: 2026-07-11

- Decision: the zero-apply promotion guard counts dedup rows. `finishRebuild`
  refuses to promote when the model has feeding async projections, the store head
  is beyond the replay-from position, and `keiro.keiro_projection_dedup` holds zero
  rows for those projections. Rationale: `startRebuild` deletes those projections'
  dedup rows, so at promotion time the per-projection dedup count *is* the exact
  apply count of the rebuild — no timestamps, no app-table introspection, no
  schema-specific row counting. The alternative (counting rows in the application's
  own table) was rejected because keiro cannot know what "populated" means for an
  arbitrary table shape, while "the replay applied at least one event" is
  model-independent and catches exactly the observed failure (everything skipped).
  Date: 2026-07-11

- Decision (finding 2, option a): the writer fence is a status check inside
  `applyAsyncProjection`'s own transaction — a prepared single-row
  `SELECT status FROM keiro.keiro_read_models WHERE name = $1 FOR SHARE` executed
  before the dedup insert, fencing (skipping dedup insert and apply, returning a
  distinct outcome) whenever the status is not `live`. Missing row also fences
  (fail closed; M1 makes registration explicit so the row always exists for
  correctly wired apps). Cost analysis: one extra prepared, primary-key-indexed,
  single-row `SELECT` per applied event on the same connection inside the already
  open transaction — one round trip, tens of microseconds, dwarfed by the dedup
  `INSERT` plus the application's own update; `FOR SHARE` row locks do not
  conflict with each other, only with the rebuild transition's `UPDATE`, so
  steady-state contention is zero. Piggybacking the check into the dedup `INSERT`
  as a CTE was considered and rejected: it would conflate "fenced" with
  "duplicate" (both surface as zero rows inserted), and it loses the `FOR SHARE`
  interlock. Option (b), advisory locks, rejected: introduces a second ad-hoc
  keying scheme (hashed names), and either leaks session locks across pooled
  connections or (transaction-shared variant) leaves applier transactions blocked
  open for the entire multi-minute rebuild. Option (c), pausing the subscription
  worker, rejected: keiro does not own the drain loop — `Keiro.Projection`
  explicitly documents that the application drives `applyAsyncProjection` per
  event (`keiro/src/Keiro/Projection.hs:150-152`), and workers are process-local
  while the fence must live where all writers meet: the database.
  Date: 2026-07-11

- Decision: the `FOR SHARE` / `UPDATE` row-lock interlock closes the
  read-then-write race. An applier that read `live` holds a share lock on the
  registry row until its transaction commits; `startRebuild`'s registry `UPDATE`
  (which takes the exclusive row lock) therefore waits for every in-flight applier
  to commit before the truncate runs, and every applier that starts after
  `startRebuild` commits observes `rebuilding` and fences. No fenced write can
  interleave with the truncate.
  Date: 2026-07-11

- Decision: the rebuild replayer uses a separate, documented
  `applyAsyncProjectionUnfenced` entry point (dedup still enforced, status check
  skipped). Rationale: the rebuild replay must run *while* the status is
  `rebuilding` — the fence has to distinguish the rebuilder from live appliers,
  and two named functions are simpler and more auditable than tokens threaded
  through the transaction.
  Date: 2026-07-11

- Decision (finding 3): `Strong` gains a per-model scope. `ReadModel` gets a
  `strongScope :: StrongScope` field with `data StrongScope = EntireLog |
  CategoryHead Text`; under `CategoryHead cat` the wait target is the maximum
  global position within that category, computed by a keiro-side SQL query against
  kiroku's `streams`/`stream_events` tables. Rationale: kiroku exports no
  category-head read (verified, see Surprises), and the parent plan forbids adding
  kiroku features here. Keiro already queries kiroku's `subscriptions` table
  directly on this exact code path (`keiro/src/Keiro/ReadModel.hs:295-304`), the
  tables live in the same database on the same pool, and the dependency is pinned
  by commit in `cabal.project` — the honest assessment is that this coupling
  already exists and is version-controlled; the new query is covered by an
  integration test that will fail loudly if kiroku's schema changes under a pin
  bump. The upstream fixes (kiroku exporting a category-head read, and/or the
  worker advancing checkpoints on provably empty fetches) are noted for kiroku's
  roadmap but are out of scope; this design degrades gracefully to them later
  because the scope is explicit per model. `EntireLog` remains the default
  behavior and stays correct for single-category stores.
  Date: 2026-07-11

- Decision (finding 4): remove auto-registration entirely rather than adding a
  distinct "auto-registered" status. `ensureReadModel` returns a new
  `ReadModelUnregistered` error when the registry has no row; applications call
  the existing `registerReadModel` once at projection startup. Rationale: the
  auto-register path (`keiro/src/Keiro/ReadModel.hs:239-249`) has exactly one
  caller — the query path itself — so removal is contained; a typo-named or
  never-populated model must be an error, not a `Live` row with a fresh
  `last_built_at` stamp (`keiro/src/Keiro/ReadModel/Schema.hs:120-129` inserts
  `'live', now()`). A softer "distinct status" option would still let the typo'd
  name silently occupy the registry.
  Date: 2026-07-11

- Decision: accept the breaking record changes (`ReadModel.strongScope`,
  `AsyncProjection.readModelName`, `applyAsyncProjection`'s return type). All
  construction sites live in this repository's packages and tests; the compiler
  finds every one. The alternative — parallel `*'` types — was rejected as
  permanent API debt for a pre-1.0 framework.
  Date: 2026-07-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Keiro is a Haskell event-sourcing framework in this repository (packages `keiro`,
`keiro-core`, `keiro-migrations`, and test packages), built on the kiroku event
store, which is consumed as a pinned git source dependency (`cabal.project:24-35`;
if you need to read kiroku source beyond what this plan quotes, the pinned revision
is the source of truth). Events are appended to PostgreSQL; everything below is
plain SQL against one database.

Terms used throughout, in plain language:

- An *event* is an immutable fact row. The *global position* is its position in the
  `$all` log — the single total order over every event in the store. In kiroku's
  schema the `$all` log is the set of `stream_events` rows with `stream_id = 0`,
  and an event's global position is that row's `stream_version` (kiroku's
  `readAllForwardSQL` selects `se.stream_version AS global_position`).
- A *category* is the stream-name prefix before the first hyphen: stream
  `orders-42` is in category `orders`. kiroku materializes this as a generated
  column `streams.category` with index `ix_streams_category`, plus a covering
  index `ix_stream_events_all_by_origin` on the `$all` rows by originating stream
  (kiroku-store-migrations `migrations/0001-kiroku-bootstrap.sql`).
- A *read model* is a named, versioned SQL projection table plus the query that
  reads it: the `ReadModel` record in `keiro/src/Keiro/ReadModel.hs:85-95`, with
  fields `name`, `tableName`, `schema` (the PostgreSQL schema of the data table),
  `subscriptionName`, `version`, `shapeHash`, `defaultConsistency`, `query`.
- The *registry* is keiro's `keiro.keiro_read_models` table: one row per model
  holding `version`, `shape_hash`, `status` (`live` / `rebuilding` / `paused` /
  `abandoned`), and `last_built_at`. `Keiro.ReadModel.runQuery` refuses to serve
  a model whose registered schema drifted or whose status is not `live`
  (`keiro/src/Keiro/ReadModel.hs:251-260`). SQL for the registry lives in
  `keiro/src/Keiro/ReadModel/Schema.hs`.
- A *projection* turns events into read-model rows. An `InlineProjection` runs in
  the same transaction as the command that emitted the events. An
  `AsyncProjection` (`keiro/src/Keiro/Projection.hs:77-83`) is applied later by an
  application-driven worker draining a subscription; keiro provides only the
  per-event `applyAsyncProjection` — the drain loop is the application's
  (`keiro/src/Keiro/Projection.hs:150-152`).
- A *subscription checkpoint* is kiroku's `subscriptions` table row(s) for a
  subscription name: `last_seen` is the highest global position delivered. Keiro
  reads it as `min(last_seen)` across consumer-group members
  (`keiro/src/Keiro/ReadModel.hs:295-304`). kiroku only saves a checkpoint when a
  batch is *delivered*; empty fetches and caught-up transitions save nothing, and
  saves are monotonic (`GREATEST(...)`), so a checkpoint can never be moved
  backward through kiroku's API.
- The *dedup table* is `keiro.keiro_projection_dedup` with
  `PRIMARY KEY (projection_name, event_id)` and an `applied_at` timestamp
  (`keiro-migrations/sql-migrations/2026-06-15-21-49-37-keiro-projection-dedup.sql`).
  `applyAsyncProjection` inserts into it with `ON CONFLICT DO NOTHING` and only
  runs the application's update when the insert took effect
  (`keiro/src/Keiro/Projection.hs:127-134`, statement at 170-182). This is what
  makes redelivery safe — and what makes a naive replay a no-op.
- A *writer fence* (this plan's term) is a database-enforced rule that write
  transactions check before touching a table, so an operator mistake cannot let a
  live writer and a rebuild interleave.

How the three defects manifest, concretely:

1. Rebuild emptiness. The runbook (`keiro/src/Keiro/ReadModel/Rebuild.hs:11-30`)
   never mentions the dedup table. Replay re-presents the same `event_id`s to
   `applyAsyncProjection`; every dedup insert conflicts; every update is skipped;
   the truncated table stays empty; `promote` marks it `live` anyway. The only
   dedup-clearing function, `pruneAsyncProjectionDedupBefore`
   (`keiro/src/Keiro/Projection.hs:139-142`), is documented exclusively for aging
   out events older than the redelivery window (docstring at lines 119-126) — an
   operator following the docs has no reason to call it, and calling it correctly
   scoped (per projection, full window) isn't even possible: it prunes by
   timestamp across *all* projections.
2. No writer fence. `markRebuilding` flips a registry row that only `runQuery`
   consults. A live worker calling `applyAsyncProjection` neither reads that row
   nor fails — it happily re-inserts dedup rows and writes into the table between
   the operator's truncate and promote. Today the only protection is "step 1: stop
   your workers" prose.
3. `Strong` under cross-category load. `waitIfNeeded Strong` targets
   `storeHeadPosition` — the `$all` head (`keiro/src/Keiro/ReadModel.hs:278-280`,
   310-315) — with a hardcoded five-second wait (`defaultStrongWaitOptions`,
   lines 137-143). A category subscription that has delivered everything in its
   category has `last_seen` frozen at its category's last event (kiroku saves
   checkpoints only on delivery). Any other active category keeps the `$all` head
   ahead of that frozen cursor forever, so every `Strong` query times out with
   `ReadModelWaitTimeout`. Fails closed, but unusable.
4. Auto-registration. The first query against an unknown name inserts a `live`
   registry row stamped `last_built_at = now()`
   (`keiro/src/Keiro/ReadModel.hs:239-249`,
   `keiro/src/Keiro/ReadModel/Schema.hs:120-129`), so an unpopulated or typo-named
   model serves empty results as a healthy `Live` model.

Test infrastructure you will use: `keiro/test/Main.hs` (one hspec suite, ~9000
lines; `main` at lines 316-317 wraps everything in `withMigratedSuite`).
PostgreSQL is provisioned automatically —
`keiro-test-support/src/Keiro/Test/Postgres.hs` starts one cached ephemeral-pg
server per suite, migrates a template database once (kiroku + keiro migrations),
and clones a fresh database per example; no external database or environment
variables are needed. Reusable fixtures: `counterReadModel`
(`keiro/test/Main.hs:8185-8196`, note `schema = "kiroku"` and
`subscriptionName = "counter-read-model-sub"`), `counterAsyncProjection`
(lines 8216-8235), the table bootstrap `initializeCounterReadModelTable`
(lines 8245-8256), direct checkpoint manipulation via
`upsertSubscriptionCursorStmt` (lines 8419-8433), a short-timeout
`fastWaitOptions` (lines 8237-8243), and a two-`forkIO`-workers-with-`MVar`s
concurrency pattern (lines 1500-1514). Existing read-model specs to extend sit
between lines ~1300 and ~1700 (Strong tests 1346-1408, dedup tests 1552-1620,
rebuild-transition test 1622-1634).

Build and test commands (repo root, `/…/keiro`; the `Justfile` is the source of
truth): `cabal build all` (or `just haskell-build`) and `cabal test keiro-test`.
To iterate on a single spec: `cabal run keiro-test -- --match "read model"`.

One schema subtlety: the store pool's `search_path` begins with kiroku's private
`kiroku` schema (`keiro/src/Keiro/Connection.hs`, module haddock), which is why
keiro's runtime SQL can say `FROM subscriptions` unqualified, while keiro's own
tables are always written qualified as `keiro.…`, and application read-model
tables should be reached via `qualifiedTableName`
(`keiro/src/Keiro/ReadModel.hs:101-103`). New SQL in this plan follows the same
three-way convention.


## Plan of Work

The work is five milestones. M1 (explicit registration) goes first because the
writer fence in M3 fails closed on a missing registry row, so registration must be
an explicit, documented lifecycle step before fencing lands. M2 (atomic rebuild
helpers) and M3 (fence) share the registry row-lock design and land in that order.
M4 (`Strong` scope) is independent. M5 rewrites the runbook prose that the helpers
now enforce and sweeps the docs.

### Milestone 1 — Registration becomes explicit; unknown models are errors

Scope: `keiro/src/Keiro/ReadModel.hs`, `keiro/src/Keiro/ReadModel/Schema.hs`
(haddocks only), `keiro/test/Main.hs`. At the end, querying a read model whose
name has no registry row returns `Left (ReadModelUnregistered name)` and inserts
nothing; applications (and every test) register at startup with the existing
`registerReadModel`.

Add a constructor `ReadModelUnregistered !Text` to `ReadModelError`
(`keiro/src/Keiro/ReadModel.hs:145-160`) with a haddock explaining the fix:
register at projection startup. In `ensureReadModel` (lines 235-249), replace the
`Nothing -> registerReadModel …` arm with
`Nothing -> pure (Left (ReadModelUnregistered (readModel ^. #name)))` — the
function's shape (`Eff es (Either ReadModelError ())`) already accommodates it;
`registerReadModel` stays exported from `Keiro.ReadModel.Schema` as the explicit
startup call. Update the module haddock of `Keiro.ReadModel` (lines 1-23) and the
`registerReadModel` haddock to state the lifecycle: register once at startup,
query thereafter; note in the changelog-worthy haddock that pre-existing
deployments relying on first-query auto-registration must add the startup call.

Tests: every existing read-model spec relied on auto-registration, so add one
explicit registration line to the setup of each read-model example (a small local
helper in `keiro/test/Main.hs`, e.g. `registerCounterReadModel storeHandle`,
keeps this to one line per test). Add a new spec: querying a `ReadModel` named
`"never-registered"` returns `Left (ReadModelUnregistered "never-registered")`
and a follow-up `lookupReadModel "never-registered"` returns `Nothing` (proving
no row was created). Acceptance: `cabal test keiro-test` passes; the new spec
fails before the `ensureReadModel` change (it auto-registers and returns a query
result) and passes after.

### Milestone 2 — Atomic rebuild helpers with dedup reset and a zero-apply promotion guard

Scope: `keiro/src/Keiro/ReadModel/Rebuild.hs`, `keiro/test/Main.hs`. At the end,
`startRebuild` performs the entire reset atomically and `finishRebuild` refuses to
promote a rebuild that applied nothing while the log has events past the replay
point. The low-level `rebuild`/`promote`/`abandonRebuild` wrappers remain (their
haddocks point to the new helpers as the supported path).

First write the red test, because it documents the current defect exactly: in a
new spec "rebuild through the documented runbook leaves the table empty"
(temporary name; it becomes the green end-to-end test), populate the counter model
— run a command, apply `counterAsyncProjection` to the recorded event, advance the
checkpoint, assert the queried amount — then follow today's runbook literally:
`Rebuild.rebuild`, `TRUNCATE counter_read_model` plus
`UPDATE subscriptions SET last_seen = 0 WHERE subscription_name =
'counter-read-model-sub'` in a transaction, replay the event through
`applyAsyncProjection` again, `Rebuild.promote`, re-query. Assert the amount is
restored. Run it and record the failure in Surprises & Discoveries: the
re-applied event is skipped by dedup and the query returns no row / zero — this
observed red run is the proof the defect is real and the fixture is faithful.

Then implement in `keiro/src/Keiro/ReadModel/Rebuild.hs`:

`startRebuild` takes the `ReadModel`, the list of feeding async projection names,
and the `GlobalPosition` to replay from, and runs ONE transaction that (in order):
upserts the registry row to `rebuilding` via the existing `transitionReadModelStmt`
shape (this `UPDATE` takes the registry row's exclusive lock — the fence interlock
from the Decision Log); executes `TRUNCATE <qualifiedTableName model>` (built with
`Keiro.Connection.qualifyTable`; `TRUNCATE` is transactional in PostgreSQL and its
ACCESS EXCLUSIVE lock additionally waits out any straggler holding locks in the
data table); deletes the dedup rows scoped per projection
(`DELETE FROM keiro.keiro_projection_dedup WHERE projection_name = ANY ($1)` — the
per-projection key verified in the migration makes this exact); and resets the
checkpoint (`UPDATE subscriptions SET last_seen = $2, updated_at = now() WHERE
subscription_name = $1`, unqualified like the existing cursor read at
`keiro/src/Keiro/ReadModel.hs:295-304`; a direct write is required because
kiroku's save API is monotonic — see Surprises). Since the registry statements
currently live as single-statement helpers in `Keiro.ReadModel.Schema`, export
the underlying `Statement`s (or `Tx.Transaction` fragments) from that module so
`startRebuild` can compose them into one transaction; do not run four separate
transactions.

`finishRebuild` takes the model and the same projection names and runs the guard
plus promotion in one transaction: count dedup rows for those projections (since
`startRebuild` deleted them, this count is precisely the rebuild's apply count);
read the store head (`storeHeadPosition` semantics, but read inside the same
transaction via the `$all` head query) and compare with the recorded replay-from
position (pass it as an argument rather than persisting it); if the count is zero
while the head is beyond replay-from, return
`Left (RebuildProducedNoApplies modelName headPosition)` and leave the status
`rebuilding`; otherwise upsert to `live` and return the metadata. Define
`data RebuildError = RebuildProducedNoApplies !Text !GlobalPosition` (room to
grow) in `Rebuild.hs`. Models with no async projections (inline-only) pass an
empty projection list and the guard is skipped — document why in the haddock.

Convert the red test to green: replace the manual truncate/reset with
`startRebuild`, replay (still through `applyAsyncProjection` until M3 renames the
rebuild path — adjust in M3), promote via `finishRebuild`, and assert the table is
repopulated and the model queryable. Add a second spec for the guard: start a
rebuild, replay nothing, and assert `finishRebuild` returns
`RebuildProducedNoApplies` and `runQuery` still fails `ReadModelNotLive`.
Acceptance: both specs pass; the suite passes.

### Milestone 3 — Writer fencing on the async apply path

Scope: `keiro/src/Keiro/Projection.hs`, `keiro/test/Main.hs`, plus a grep for all
`applyAsyncProjection` call sites. At the end, a live applier cannot write during
a rebuild even if the operator pauses nothing.

Extend `AsyncProjection` with `readModelName :: !Text` (the registry name of the
model this projection feeds — the record at `keiro/src/Keiro/Projection.hs:77-83`;
the compiler will flag every construction site, including
`counterAsyncProjection`). Add
`data AsyncApplyOutcome = AsyncApplied | AsyncDuplicate | AsyncFenced` and change
`applyAsyncProjection` to
`AsyncProjection -> RecordedEvent -> Tx.Transaction AsyncApplyOutcome`: first run
the fence statement `SELECT status FROM keiro.keiro_read_models WHERE name = $1
FOR SHARE` (prepared, single row); if the row is missing or the status is not
`live`, return `AsyncFenced` without touching the dedup table or calling
`applyRecorded`; otherwise proceed as today, returning `AsyncDuplicate` on a
dedup conflict and `AsyncApplied` on success. Add
`applyAsyncProjectionUnfenced` with the old behavior plus the outcome type
(dedup check, no status check), haddocked as the rebuild-replay entry point only.
Haddock the caller contract explicitly: a worker receiving `AsyncFenced` must not
checkpoint past the event — fail or park the delivery and retry; with kiroku's
ack-coupled delivery a failed handler never advances the checkpoint. Update all
call sites (the M2 rebuild test's replay switches to the unfenced variant; other
test call sites bind the outcome).

The race test, modeled on the two-worker pattern at `keiro/test/Main.hs:1500-1514`:
populate the model; fork a "live applier" thread that appends a fresh event and
applies it in a loop, collecting outcomes into an `IORef`/`MVar`; on the main
thread run `startRebuild`, replay via the unfenced variant, `finishRebuild`;
signal the applier to stop. Assert: at least one applier outcome during the
rebuild window is `AsyncFenced` (coordinate the window with `MVar`s so the test
is deterministic — block the applier until `startRebuild` has committed, then
assert its very next outcome is `AsyncFenced`); after promotion the applier's
apply succeeds again (`AsyncApplied`); and the final table content equals the
replayed history plus post-promotion applies — no torn writes. Also add a plain
unit spec: with the registry row forced to `rebuilding`, `applyAsyncProjection`
returns `AsyncFenced` and inserts no dedup row. Acceptance: both specs pass; the
suite passes.

### Milestone 4 — Strong with category-scoped head

Scope: `keiro/src/Keiro/ReadModel.hs`, `keiro/test/Main.hs`. At the end, a model
declaring `strongScope = CategoryHead "counter"` answers `Strong` queries promptly
while other categories churn; `EntireLog` preserves today's semantics.

First the red test: seed the model's category (one command on a `counter`-category
stream, apply the projection, advance `counter-read-model-sub`'s cursor to that
event's global position — the model is fully caught up on its category), then
append an event in a second category (any stream named e.g. `otherload-1` — the
category is the prefix before the first hyphen). Query with
`runQueryWith Nothing Strong counterReadModel …`. Against current code this
observably burns the full five-second `defaultStrongWaitOptions` timeout and
returns `Left (ReadModelWaitTimeout …)` — run it, record the transcript in
Surprises & Discoveries. (The five-second red run is acceptable one-off evidence;
the green test is fast.)

Then implement: add `data StrongScope = EntireLog | CategoryHead !Text` and a
`strongScope :: !StrongScope` field to `ReadModel` (update the record haddock at
`keiro/src/Keiro/ReadModel.hs:67-84` and every construction site; existing
fixtures set `EntireLog` except where the test wants the new behavior). Add
`categoryHeadPosition :: (Store :> es) => Text -> Eff es GlobalPosition` running

```sql
SELECT COALESCE(max(se.stream_version), 0)
FROM streams s
JOIN stream_events se
  ON se.original_stream_id = s.stream_id AND se.stream_id = 0
WHERE s.category = $1
```

(unqualified names resolve through the kiroku-first `search_path`, exactly like
the cursor read; `stream_version` of a `stream_id = 0` row *is* the global
position; the query is served by `ix_streams_category` plus
`ix_stream_events_all_by_origin`). In `waitIfNeeded` (lines 272-285), the `Strong`
arm computes the target from the model's scope: `EntireLog` keeps
`storeHeadPosition`; `CategoryHead cat` uses `categoryHeadPosition cat`. Document
in the `Strong`/`StrongScope` haddocks: `EntireLog` is only live in stores where
the model's subscription observes every event; category-scoped subscriptions
should declare their category; the caveat that a model reading multiple
categories needs `PositionWait` or `EntireLog`; and the upstream note that
checkpoint-advance-on-empty-fetch in kiroku would obsolete this workaround (out
of scope here — do not add kiroku features).

Green test: same scenario with `strongScope = CategoryHead "counter"` (either a
tweaked fixture or a record update of `counterReadModel`) asserting the query
returns `Right (Right …)` well under the timeout. Keep the three existing
`Strong` specs (lines 1346-1408) passing under `EntireLog`. Acceptance: red
observed, green passes, suite passes.

### Milestone 5 — The runbook becomes the helpers; docs sweep

Scope: `keiro/src/Keiro/ReadModel/Rebuild.hs` haddock, `keiro/src/Keiro/Projection.hs`
haddock, `docs/research/12-read-model-query-api-and-lifecycle.md` (a pointer note
only — research docs are historical), `CHANGELOG.md`. Rewrite the Rebuild module
haddock so the operator procedure is: register your model at startup (M1); call
`startRebuild` with your projection names and replay-from position (it fences
writers, truncates, clears dedup, resets the checkpoint — atomically); replay via
`applyAsyncProjectionUnfenced`; call `finishRebuild` (it refuses an empty
rebuild); `abandonRebuild` to back out. State explicitly which failure each step
forecloses, in one sentence each. Update `pruneAsyncProjectionDedupBefore`'s
haddock to point rebuilds at `startRebuild` and reserve pruning for age-out.
Sweep: `grep -rn "runbook\|truncate" keiro/src docs/foundations site/src` for any
other statement of the old procedure and align it. Add CHANGELOG entries for the
four breaking changes. Acceptance: `just haskell-build` and
`cabal test keiro-test` pass; `cabal haddock keiro` builds without new warnings;
retrospective written.


## Concrete Steps

All commands run from the repository root (`/Users/shinzui/Keikaku/bokuno/keiro`).
No database setup is needed for tests — the suite provisions its own ephemeral
PostgreSQL (see Context).

Build and run the full suite before starting, to establish a clean baseline:

```bash
cabal build all
cabal test keiro-test
```

Expected tail of a passing run (counts will differ as specs are added):

```text
Finished in ...s
... examples, 0 failures
Test suite keiro-test: PASS
```

Iterate on the read-model specs only:

```bash
cabal run keiro-test -- --match "read model"
```

Capture the M2 red run (after writing the runbook-literal test, before the fix):

```bash
cabal run keiro-test -- --match "rebuild"
```

Expected red evidence (shape, not exact text): the end-to-end spec fails on the
post-rebuild assertion with the queried amount empty/zero, e.g.

```text
Failures:
  test/Main.hs:NNNN
  1) ... rebuild repopulates the projection table through the helpers
       expected: Right (Right 7)
        but got: Right (Right 0)
```

Capture the M4 red run the same way (`--match "Strong"`); the failing expectation
is a `ReadModelWaitTimeout` after a visible ~5s stall.

Commit after each milestone with a conventional-commit message and the plan
trailer, for example:

```text
feat(readmodel): make read-model registration explicit and fail closed on unknown models

ExecPlan: docs/plans/101-read-model-rebuild-correctness-dedup-reset-writer-fencing-and-strong-cursor-semantics.md
```

Final verification:

```bash
just haskell-build
cabal test keiro-test
cabal haddock keiro
```


## Validation and Acceptance

Acceptance is behavioral, all demonstrated by named specs in `keiro/test/Main.hs`:

1. Rebuild end-to-end: populate the counter model, rebuild through
   `startRebuild`/replay/`finishRebuild`, and the query returns the repopulated
   value. The same scenario expressed through the current runbook was observed
   failing with an empty table before the fix (red run recorded in Surprises &
   Discoveries) — that red/green pair is the proof the defect existed and is
   closed.
2. Zero-apply guard: a rebuild that replays nothing cannot be promoted;
   `finishRebuild` returns `RebuildProducedNoApplies` and queries keep failing
   `ReadModelNotLive` instead of serving an empty table.
3. Writer fence: with a rebuild in progress, a concurrent applier's
   `applyAsyncProjection` returns `AsyncFenced` and writes neither a dedup row
   nor a table row; after promotion it applies again; final table content is
   exactly replay-plus-post-promotion history.
4. `Strong` cross-category: with the model caught up on its own category and a
   second category active, a `Strong` query on a `CategoryHead`-scoped model
   returns the correct value promptly; the identical scenario under current code
   was observed timing out with `ReadModelWaitTimeout` after ~5s (red run
   recorded). The three pre-existing single-category `Strong` specs still pass
   under `EntireLog`.
5. Unregistered model: querying a never-registered name returns
   `ReadModelUnregistered` and creates no registry row.

Beyond the specs: `cabal build all`, `cabal test keiro-test`, and
`cabal haddock keiro` all succeed. Every breaking surface (`ReadModel` record,
`AsyncProjection` record, `applyAsyncProjection` signature, removed
auto-registration) is covered by a CHANGELOG entry and updated haddocks that a
novice can follow without this plan.


## Idempotence and Recovery

Every step is safe to repeat. The test suite clones a fresh database per example,
so failed runs leave no state. `startRebuild` is itself idempotent by design:
running it twice truncates an already-empty table, re-deletes absent dedup rows,
and re-writes the same `rebuilding` status — converging, not compounding; this is
also the operator's recovery path for a rebuild that died midway (just run
`startRebuild` again and re-replay). `finishRebuild` failing leaves the model
`rebuilding` (queries keep failing closed) — recover by re-replaying or
`abandonRebuild`. If a milestone's refactor breaks compilation midway, the
breaking record changes are compiler-guided: fix construction sites until
`cabal build all` is clean before touching tests. Commits land per milestone so
`git revert` of a single milestone is always possible; no migration files are
added or renamed by this plan (the dedup and registry schemas are unchanged —
only how keiro's code and one new direct `UPDATE` use them).

One production caution to preserve in the haddocks: `startRebuild`'s checkpoint
reset writes kiroku's `subscriptions` table directly because kiroku's own save is
deliberately monotonic. That write must only ever run inside `startRebuild`'s
fenced transaction; document it, and do not export the raw statement.


## Interfaces and Dependencies

No new packages. Everything uses the already-present stack: `hasql` statements via
`Hasql.Statement.preparable`, transactions via `Kiroku.Store.Transaction.runTransaction`
and `Hasql.Transaction`, the `Store` effect from `Kiroku.Store.Effect`, types from
`Kiroku.Store.Types` (`GlobalPosition`, `EventId`, `RecordedEvent`). kiroku stays at
the pin in `cabal.project`; this plan adds no kiroku features.

End-state signatures (module-qualified; field lists show only additions):

```haskell
-- keiro/src/Keiro/ReadModel.hs
data StrongScope = EntireLog | CategoryHead !Text

data ReadModel q r = ReadModel
    { -- existing fields unchanged …
      strongScope :: !StrongScope
    , -- …
    }

data ReadModelError
    = -- existing constructors unchanged …
      ReadModelUnregistered !Text

categoryHeadPosition :: (Store :> es) => Text -> Eff es GlobalPosition

-- keiro/src/Keiro/Projection.hs
data AsyncProjection = AsyncProjection
    { -- existing fields unchanged …
      readModelName :: !Text
    }

data AsyncApplyOutcome = AsyncApplied | AsyncDuplicate | AsyncFenced

applyAsyncProjection ::
    AsyncProjection -> RecordedEvent -> Tx.Transaction AsyncApplyOutcome

applyAsyncProjectionUnfenced ::
    AsyncProjection -> RecordedEvent -> Tx.Transaction AsyncApplyOutcome

-- keiro/src/Keiro/ReadModel/Rebuild.hs
data RebuildError = RebuildProducedNoApplies !Text !GlobalPosition

startRebuild ::
    (Store :> es) =>
    ReadModel q r ->
    [Text] ->            -- feeding async projection names (dedup reset scope)
    GlobalPosition ->    -- replay-from position (checkpoint reset target)
    Eff es ReadModelMetadata

finishRebuild ::
    (Store :> es) =>
    ReadModel q r ->
    [Text] ->            -- same projection names (apply-count guard scope)
    GlobalPosition ->    -- the replay-from position given to startRebuild
    Eff es (Either RebuildError ReadModelMetadata)
```

Milestone-by-milestone existence: M1 delivers `ReadModelUnregistered` and the
non-registering `ensureReadModel`; M2 delivers `RebuildError`, `startRebuild`,
`finishRebuild` (plus `Keiro.ReadModel.Schema` exporting composable registry
transaction fragments); M3 delivers `AsyncApplyOutcome`, the `readModelName`
field, and both apply entry points; M4 delivers `StrongScope`,
`categoryHeadPosition`, and the scoped `waitIfNeeded`; M5 delivers only
documentation. `rebuild`, `promote`, `abandonRebuild`,
`pruneAsyncProjectionDedupBefore`, `registerReadModel`, `waitFor`,
`readSubscriptionPosition`, and `storeHeadPosition` keep their signatures.
