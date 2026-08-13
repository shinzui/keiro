---
id: 258
slug: make-catalog-rebuild-promotion-redelivery-safe-for-async-projections
title: "Make catalog rebuild promotion redelivery-safe for async projections"
kind: exec-plan
created_at: 2026-08-13T00:49:13Z
intention: "intention_01kzw6dk7qe1qayx2qdz6vcqfd"
master_plan: "docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md"
---

# Make catalog rebuild promotion redelivery-safe for async projections

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today, promoting an offline catalog rebuild silently sets up a second application of
every replayed event onto the rebuilt tables. The rebuild's preparation step deletes the
deduplication rows and rewinds the durable subscription checkpoints of every replayable
async projection in the group; the replay step applies the whole history range through
raw replay adapters that never re-create those deduplication rows; and the promotion
step flips the group live without restoring either. The async worker — which was
correctly parked by the write fence for the entire rebuild — then wakes up, resolves its
rewound checkpoint, and redelivers exactly the range the replay already applied. Every
redelivered event passes the dedup insert (the rows are gone) and runs the live handler
a second time. For any handler whose SQL is not idempotent per event — a running total,
an append-only audit row, a plain `INSERT` — the read model is silently corrupted (a
counter ends at twice its true value) or the worker crash-loops on unique violations.

After this plan, promotion is redelivery-safe: inside the same transaction that flips
the group live, Keiro backfills `keiro.keiro_projection_dedup` with one row per source
event in the replayed range per replayable async projection (using each projection's own
idempotency-key function, `ON CONFLICT DO NOTHING`), and advances the declared
subscription checkpoints to the captured replay head. A worker that redelivers any part
of the replayed range — whether from its durable checkpoint or from an in-flight parked
delivery — receives `CatalogAsyncDuplicate` and applies nothing; systematic redelivery
of the replayed range stops entirely because the checkpoint stands at the head.

You can see it working by running the new database-backed tests in
`keiro/test/ProjectionReplaySpec.hs`: a non-idempotent counter projection is applied
live, rebuilt through `startCatalogRebuild`, promoted, and then driven through the async
worker path (`applyAsyncProjectionFromCatalog`) over the same events. Before this plan
the counter doubles and every redelivery reports `CatalogAsyncApplied`; after it, the
counter is unchanged, every redelivery reports `CatalogAsyncDuplicate`, and the durable
checkpoint equals the run's captured head. The helpers built here are exported for reuse
by the versioned-cutover plan
(`docs/plans/256-rebuild-into-versioned-targets-with-atomic-cutover.md`), which needs the
identical backfill-plus-advance shape for its online cutover.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: baseline `cabal build all` and `cabal test keiro-test` pass at the starting commit.
- [ ] M1: redelivery fixture catalog (async handler, real subscription, real dedup key,
      non-idempotent handler) added to `keiro/test/ProjectionReplaySpec.hs`.
- [ ] M1: red test "promotion leaves redelivery safe for a clear-before-replay async
      projection" written; observed failing (doubled total, `CatalogAsyncApplied`
      outcomes, checkpoint at replay start); red transcript captured in this plan.
- [ ] M1: red test for a `PreserveAndReconcile`-fed async projection written and observed
      failing.
- [ ] M2: `CatalogAsyncDedupSpec` and `catalogAsyncIdempotencyKeys` added to
      `keiro/src/Keiro/Projection/Catalog.hs` and exported; membership assertions added.
- [ ] M3: backfill input collection (`collectAsyncDedupBackfill`) and batched dedup
      insert statement added; `resetDeclaredSubscriptions` exported from
      `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`.
- [ ] M3: `verifyAndPromote` extended — backfill inserts and checkpoint advance inside
      the promote transaction; `CatalogRebuildPromotionCheckpointsMissing` added.
- [ ] M3: M1 red tests now pass; whole `cabal test keiro-test` green.
- [ ] M4: resume-path test (verification failure, then repaired resume promotes with
      backfill) passing; fenced-while-failed and multi-member checkpoint assertions
      passing.
- [ ] M5: ADR-31 amended; docs corrected (`docs/user/read-models-and-projections.md`,
      `docs/guides/run-and-operate-jitsurei.md`); `keiro/CHANGELOG.md` updated.
- [ ] M5: `cabal build all`, `cabal test keiro-test`, and `just verify` green;
      Outcomes & Retrospective written; ADR distillation pass done.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix at promotion time with BOTH a dedup backfill and a checkpoint advance,
  not one or the other.
  Rationale: The checkpoint advance alone stops systematic redelivery but cannot protect
  against an in-flight delivery the worker fetched before the fence and parked on
  `CatalogAsyncFenced` — ack-coupled delivery retries that exact event after promotion
  regardless of the durable checkpoint, and without its dedup row it applies a second
  time. The backfill alone restores correctness but leaves checkpoints at the replay
  start, forcing the worker to redeliver the entire replayed history as no-op duplicates
  — wasteful, slow to converge, and it retroactively widens the redelivery window past
  any operator dedup-pruning schedule (`pruneAsyncProjectionDedupBefore` is documented as
  safe only beyond the redelivery window). Plan 256's cutover decision reached the same
  conclusion for the online path; doing both here keeps the two protocols' convergence
  semantics identical and the helpers shared.
  Date: 2026-08-13
- Decision: The backfill range for each async projection starts at that subscription's
  durable checkpoint floor read at promotion time (minimum across consumer-group
  members, via Kiroku's checkpoint inventory), not at a persisted copy of `replayFrom`.
  Rationale: The run row (`keiro.keiro_projection_rebuild_runs`) does not persist
  `replayFrom`, and source cursor rows mutate during replay, so `replayFrom` is not
  durably recoverable on the resume path. Preparation reset every declared member to
  `replayFrom` and the fence prevents a contract-honoring worker from checkpointing
  while the group is rebuilding, so the floor at promotion equals `replayFrom` exactly.
  Reading the floor requires no new run column (hence no persisted-format change and no
  ADR-32 prefix bump), covers precisely the range the subscription will redeliver, and
  makes the helper byte-for-byte the shape plan 256 needs for its cutover, where the
  floor is a live worker's real position instead.
  Date: 2026-08-13
- Decision: Backfill input (the `(dedup name, event id)` pairs) is computed outside the
  promote transaction by paging the store; the inserts and the checkpoint advance
  execute inside the promote transaction, before `finishGroupRebuildTx`.
  Rationale: History at or below the captured head is immutable, so paging it outside
  the transaction is sound (plan 256 relies on the same fact). Keeping the inserts inside
  the promote transaction makes promotion atomic with redelivery safety: any crash rolls
  back to a plainly `rebuilding` group with unseeded dedup and rewound checkpoints, which
  resume or a fresh rebuild handles today. The alternative — seeding dedup incrementally
  inside each replay chunk transaction, mirroring the legacy protocol — was rejected:
  it edits the paging/merge loop that plan 246 owns, inflates every chunk transaction
  with writes unrelated to replay progress, and cannot mirror the legacy shape anyway
  because raw replay adapters intentionally know nothing about dedup identities.
  Date: 2026-08-13
- Decision: The whole backfill-and-advance step is skipped when the group has no
  replayable async projections, and no persisted format (run columns, statuses,
  fingerprints, contract preimage, runner format) changes.
  Rationale: Inline-only groups have no dedup or checkpoint state to restore — this is
  why every existing `ProjectionReplaySpec` scenario must keep passing unmodified.
  Because nothing persisted changes shape, ADR-32's mandatory-prefix-bump rule is not
  triggered; the fix is behavioral, inside the existing promotion transaction.
  Date: 2026-08-13
- Decision: Missing checkpoint rows at promotion condemn the promote transaction with a
  new typed error `CatalogRebuildPromotionCheckpointsMissing`, recorded as run failure
  evidence, leaving the run resumable after repair.
  Rationale: Preparation already condemns on missing declared subscription rows
  (`RebuildSubscriptionCheckpointsMissing`), so a missing row at promotion means the row
  was deleted mid-rebuild — an operator-visible anomaly that must not be silently
  absorbed (Keiro never creates member rows; ADR-31). `resumeRunStmt` accepts a `failed`
  run while the group is still `rebuilding`, so recording failure keeps the supported
  retry path open.
  Date: 2026-08-13
- Decision: Documentation is aligned to the library contract: dedup (the
  `idempotencyKey` mechanism) is the redelivery-safety mechanism; handler-level
  idempotent SQL is recommended defense-in-depth, not a correctness requirement.
  Rationale: `keiro/src/Keiro/Projection.hs` states the primary contract ("an
  'idempotencyKey' so redelivery is safe"; a dedup conflict means "already applied …
  skipped") and this plan restores that contract across rebuilds. The two contradicting
  doc lines ("Async projections must be idempotent by source event id" in the jitsurei
  guide; "Make every async handler idempotent" in the read-models guide) are unenforced
  and, once this fix lands, wrong as stated. Defense-in-depth remains worth recommending
  because dedup rows can be pruned past the redelivery window by operator action.
  Date: 2026-08-13
- Decision: The new helpers are exported with plan 256 as a named consumer:
  `catalogAsyncIdempotencyKeys` from `Keiro.Projection.Catalog`,
  `collectAsyncDedupBackfill` and the batched insert from the rebuild modules, and
  `resetDeclaredSubscriptions` from `Keiro.ReadModel.Rebuild.Group`.
  Rationale: Plan 256 (MasterPlan 41) states it "reuses [258's] backfill/advance helpers"
  for its cutover promote transaction and will verify the landed signatures before its
  Milestone 5. Owning the helpers here avoids two divergent implementations of the same
  invariant.
  Date: 2026-08-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Keiro is a Haskell runtime for event-sourced services on PostgreSQL, packaged as a
multi-package cabal project. The `keiro` package (under `keiro/`) contains the runtime
this plan changes; `keiro-test-support/` provides the database test fixture; `docs/`
holds user documentation, ADRs (Architecture Decision Records — durable design
decisions, one Markdown file each under `docs/adr/`), and these plans. Applications
append immutable events to a Kiroku event store (the `kiroku-store` library, a separate
repository: `mori://shinzui/kiroku`) and project them into **read models**: ordinary
application-owned PostgreSQL tables filled by projection handlers. Every event carries a
**global position** — a monotonically increasing `bigint` across the whole store — and
an **event id** (a UUID).

A **projection catalog** (`keiro/src/Keiro/Projection/Catalog.hs`) is the validated
inventory of an application's read side. The identities that matter here, per
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`:
a **target** is one application table with a reset policy (`ClearBeforeReplay`: truncate
before replaying; `PreserveAndReconcile`: keep rows, let the replay adapter reconcile); a
**rebuild group** is the set of targets that move through one rebuild lifecycle
together; a **projection definition** owns targets and carries handlers plus an optional
**replay adapter** (a decode function and a raw apply function used only during
rebuilds); a **query-model binding** ties a registered query to the group. Groups
persist in `keiro.keiro_projection_rebuild_groups`, queries in `keiro.keiro_read_models`.

Handlers come in two delivery flavors. An **inline** handler runs in the same
transaction as the command append. An **async** handler (`AsyncProjection`, defined in
`keiro/src/Keiro/Projection/Types.hs`, applied by `keiro/src/Keiro/Projection.hs`) runs
later from a **subscription**: a durable named cursor in Kiroku's `subscriptions` table,
one row per `(subscription_name, consumer_group_member)`, whose `last_seen` column is the
**checkpoint** — the global position through which that member has processed. The
application owns the worker loop: it drains events from the subscription and calls
`applyAsyncProjectionFromCatalog` once per delivered event (there is no in-library drain
loop). Delivery is at-least-once, so each `AsyncProjection` carries an
`idempotencyKey :: RecordedEvent -> EventId` and `applyAsyncProjectionUnfenced`
(`keiro/src/Keiro/Projection.hs`, around line 365) makes application exactly-once: it
first inserts `(projection name, idempotencyKey event)` into
`keiro.keiro_projection_dedup` (`insertProjectionDedupStmt`, around line 453 — the ONLY
insert into that table in the codebase) and runs `applyRecorded` only when the insert
actually inserted; a conflict returns `AsyncDuplicate` and applies nothing. The module
header (lines 10–14) states the contract plainly: the idempotency key makes "redelivery
safe". Catalog validation (`keiro/src/Keiro/Projection/Catalog.hs`, around line 1295)
forces each async handler's declared dedup name to equal the `AsyncProjection`'s `name`,
so the dedup table is keyed by a catalog-governed identity.

`applyAsyncProjectionFromCatalog` (`keiro/src/Keiro/Projection.hs`, around line 336)
wraps the unfenced core in the **write fence**: inside the same transaction it takes a
`FOR SHARE` lock on the group row (`lockProjectionGroupsTx`); if the group's status is
anything but `live` it returns `CatalogAsyncFenced` having written nothing — no dedup
insert, no target write. The documented worker contract (same file, around lines
303–311 and 332–335) is that a fenced delivery must NOT be checkpointed: park or fail
it and retry after promotion. That contract is what turns this plan's defect into a
guaranteed double application rather than a race.


### How the offline catalog rebuild works today

The supported offline rebuild has three phases, all driven by
`startCatalogRebuild` (`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`, around line 209).

**Preparation.** `beginGroupRebuild` (`keiro/src/Keiro/ReadModel/Rebuild/Group.hs`,
around lines 458–526) runs one transaction: it locks the group row `FOR UPDATE`,
verifies the stored slice fingerprint, flips the group and its bound query registrations
to `rebuilding`, truncates every `ClearBeforeReplay` target, **deletes the dedup rows**
of every replayable async projection in the group (lines 502–503, via
`deleteProjectionDedupStmt`, around line 963), and **resets the declared subscription
checkpoints to the requested `replayFrom`** — the replay START — via
`resetDeclaredSubscriptions` (around lines 528–537), which calls Kiroku's
`resetSubscriptionCheckpointsTx`. That Kiroku primitive (module
`Kiroku.Store.Subscription.Checkpoint` in `mori://shinzui/kiroku`; semantics owned by
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`) sets every existing member of each
named subscription to the exact target position — unlike ordinary worker saves it may
move a checkpoint backward — and reports the exact member keys moved plus any requested
names that have no row at all; `beginGroupRebuild` condemns the whole transaction when
any declared name is missing (`RebuildSubscriptionCheckpointsMissing`). The membership
for both the dedup delete and the checkpoint reset comes from `preparationFor` (around
lines 627–661): it intersects `asyncProjectionRegistrations` with the projections whose
`replayAdapterMetadata` entry is replayable and in the group — note it filters by
**replayability only, not by target reset policy**, so async projections feeding
`PreserveAndReconcile` targets are included identically.

**Replay.** Back in `Runner.hs`, `startCatalogRebuild` captures the store head H once
(`captureHead`, around line 351) and refuses if `replayFrom > H`. `driveCatalogRebuild`
then pages each source, merges pages in ascending global position, and applies each
chunk in one transaction (`applyChunkTx`) that first proves the run and group are still
active. Application goes through `runCatalogReplayAdapter`
(`keiro/src/Keiro/Projection/Catalog.hs`, around lines 802–812): decode the raw event
with the adapter's `decodeForReplay`, and if relevant run the adapter's raw
`applyForReplay`. This path performs **no dedup insert** — the only
`INSERT INTO keiro.keiro_projection_dedup` in the codebase is the one in
`Projection.hs`, reachable solely through `applyAsyncProjection` /
`applyAsyncProjectionFromCatalog` / `applyAsyncProjectionUnfenced`, none of which the
catalog runner calls. That is by design at the adapter level: the DSL scaffolds separate
raw holes for live and replay application (`apply<Owner>Live` vs `apply<Owner>Replay`,
plus a per-owner idempotency-key hole — see `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`,
around lines 4406–4460), and replay adapters intentionally know nothing about dedup.

**Promotion.** When every source proves exhaustion through H, `verifyAndPromote`
(`Runner.hs`, around lines 653–701) runs the application's verification hooks in one
transaction, then in a second transaction evaluates `completionProofStmt` (source,
adapter, and verification completeness), marks the run verified, calls
`finishGroupRebuildTx` (`Group.hs`, around lines 549–570 — group `rebuilding -> live`,
`active_run_id` cleared, bound queries marked live), and marks the run promoted. This
transaction touches **neither the dedup table nor the subscription checkpoints**.


### The defect, end to end

Take one replayable async projection in the group, a log with events at global
positions 1..10 in its source category, `replayFrom = 0`, and a live handler that is not
idempotent per event (say `total = total + delta`). Before the rebuild the worker has
applied all ten events (dedup has ten rows; the checkpoint stands at 10; `total = Σ`).

1. Preparation deletes the ten dedup rows, resets the checkpoint to 0, truncates the
   target (or preserves it under `PreserveAndReconcile`), and fences the group.
2. Replay captures H = 10 and applies events 1..10 through the raw adapter. The target
   is correct again (`total = Σ`). No dedup rows exist.
3. During the rebuild the worker is fenced: every delivery returns
   `CatalogAsyncFenced`; honoring the contract, it checkpoints nothing and parks. The
   durable checkpoint stays at 0.
4. Promotion flips the group live, touching neither dedup nor checkpoints.
5. The worker retries. The fence now passes. It resolves its durable checkpoint — 0 —
   and redelivers events 1..10, the exact range replay already applied. Every
   `insertProjectionDedupStmt` succeeds (the rows were deleted in step 1 and never
   re-seeded), so `applyRecorded` runs a second time for every event:
   `total = 2Σ`. A plain-`INSERT` handler instead raises unique violations and the
   worker crash-loops.

The same overlap hits `PreserveAndReconcile` targets fed by replayable async
projections, because `preparationFor` includes them in the dedup delete and checkpoint
reset regardless of target policy: after promotion the worker re-applies the replayed
range onto the preserved table.

The **legacy** (non-catalog, single-read-model) protocol preserves the invariant
deliberately, which is why the defect is catalog-path-only. Its documented checklist
(`keiro/src/Keiro/ReadModel/Rebuild.hs`, lines 21–23) replays through
`applyAsyncProjectionUnfenced`, so replay itself re-seeds the dedup rows event by event,
and `finishRebuild` (around lines 153–168) even uses the replay-seeded dedup count as
its promotion guard. Tests pin it: `keiro/test/Main.hs` around lines 3727–3753 asserts
the queried value is unchanged after a rebuild-and-promote, and around lines 3855–3872
asserts exactly one dedup row exists after rebuild (the prune returns 1). The catalog
runner reused the same preparation semantics but switched replay to raw adapters,
dropping the re-seeding half of the invariant.

No catalog-path test catches this. The `ProjectionReplaySpec` fixture catalogs declare
`subscriptions = []` and `dedupKeys = []` (`keiro/test/ProjectionReplaySpec.hs`, lines
317–318) — inline-only groups. `keiro/test/GroupRebuildSpec.hs` exercises preparation
and fencing with a real async projection but never promotes and then redelivers. The
`jitsurei` demo's async audit projection is an `ON CONFLICT` upsert, so the bug is
invisible there.

Finally, the documentation contradicts itself. The library contract
(`keiro/src/Keiro/Projection.hs`, lines 10–14 and around 316–321) says the idempotency
key and dedup table make redelivery safe. But
`docs/guides/run-and-operate-jitsurei.md` (line 128) says "Async projections must be
idempotent by source event id", and `docs/user/read-models-and-projections.md`
(line 736) says "Async projections are at-least-once in v1. Make every async handler
idempotent." Neither requirement is enforced anywhere, and the framework's design treats
dedup — not handler SQL — as the safety mechanism. This plan fixes the mechanism and
aligns the docs (handler idempotency stays as recommended defense-in-depth).


### Relevant ADRs

- `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
  — the checkpoint/replay-safety contract this plan restores and **amends**. It already
  records that deliberate coordinated reset composes Kiroku's
  `resetSubscriptionCheckpointsTx` with the group fence, target preparation, and dedup
  reset in one transaction, that Keiro condemns when a declared name is missing, and
  that Keiro never creates member rows. The amendment adds the promotion half of the
  lifecycle: promotion backfills dedup for the replayed range and advances the declared
  checkpoints to the captured head in the same transaction as the group flip, so
  preparation's reset and promotion's advance bracket the rebuild symmetrically.
- `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
  — canonical preimages and the mandatory-prefix-bump rule for persisted format changes.
  This plan changes **no** persisted format (no new run columns, statuses, or preimage
  facts), so no prefix bump and no ADR-32 amendment is required; if during
  implementation you find you must persist anything new, stop and follow ADR-32's rule
  and amend it in the same change.
- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
  — the catalog identities and group lifecycle summarized above; read for vocabulary,
  no amendment expected.
- `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
  — Keiro must reach Kiroku state only through Kiroku's public API. The checkpoint
  advance therefore reuses `resetSubscriptionCheckpointsTx` (via the existing
  `resetDeclaredSubscriptions` wrapper) and the floor read reuses Kiroku's public
  checkpoint inventory; never write SQL against Kiroku's `subscriptions` table.
- Cross-repository: `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` owns absent-row
  initialization, existing-row precedence, monotonic ordinary saves, and explicit reset
  semantics for subscription checkpoints.


### Coordination with sibling plans (MasterPlan 39 and 41)

This plan is EP-5 of
`docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md`,
with soft dependencies on EP-1
(`docs/plans/246-preserve-cross-source-global-position-order-in-buffered-replay-paging.md`,
which owns the paging/merge loop in `Runner.hs` around line 433) and EP-2
(`docs/plans/247-capture-replay-adapter-application-order-in-the-rebuild-resume-contract.md`,
which owns the contract functions around `rebuildContract`, line 826, and bumps the
persisted contract/runner format to v4). Sequence this plan after both: they edit other
regions of `Runner.hs` and both extend `keiro/test/ProjectionReplaySpec.hs`, so landing
later minimizes merge friction. This plan touches `verifyAndPromote` (around lines
653–701) and adds new top-level definitions — regions neither sibling rewrites. Do not
hardcode any contract or runner-format string; this plan does not read or change them.
Plan 248 owns the `'$pre-canonical'` sentinel and recovery semantics — this plan's new
statements are all new code, so no reconciliation is needed. Plan 249 owns the adoption
result vocabulary — this plan must not touch adoption code or types. Plan 256
(MasterPlan 41) is the named consumer of the helpers built here; its Context section
already records that plan 258 "lands first and defines the shared backfill/advance
helpers" and that its promote transaction reuses them.


## Plan of Work

The work is five milestones: reproduce (red tests), extract the catalog identity helper,
fix promotion, widen the proof matrix, then document and gate. Work from the repository
root, `/Users/shinzui/Keikaku/bokuno/keiro`, on the current branch (no feature branch).


### Milestone 1 — reproduce the defect with red database-backed tests

Scope: add an async-projection fixture and two failing tests to
`keiro/test/ProjectionReplaySpec.hs`. At the end, the defect is pinned by tests that
fail for exactly the predicted reason, and the red transcript is captured in this plan.
Commit the red tests together with the Milestone 3 fix so every commit keeps
`cabal test keiro-test` green; until then keep the red evidence in the plan.

First confirm the baseline: `cabal build all` and `cabal test keiro-test` must pass
before you change anything.

The test suite runs against a real PostgreSQL using the suite-level template-database
fixture from `keiro-test-support` (`keiro-test-support/src/Keiro/Test/Postgres.hs`):
one server and one migrated template database per suite run, one cheap clone per
example via `withFreshStore fixture`. `keiro/test/Main.hs` already threads the fixture
into `ProjectionReplaySpec.spec fixture` (around line 400), so extending that module
needs no `Main.hs` changes and no per-example migrations — follow the existing pattern
exactly.

Inside `ProjectionReplaySpec.spec`, add a second `describe` group, for example
`describe "catalog rebuild promotion redelivery" $ around (withFreshStore fixture) $ …`,
plus the fixture definitions below the existing ones. The fixture mirrors the catalog
shapes in `keiro/test/CatalogSpec.hs` (which `GroupRebuildSpec` reuses; you can copy
its helper shapes rather than importing, since this catalog needs different tables):

- Fixture SQL (a new multiline `ByteString`, applied per example through
  `Store.runTransaction (Tx.sql …)` exactly as `replayFixtureSql` is):

```sql
CREATE SCHEMA app;
CREATE TABLE app.audit_totals (id text PRIMARY KEY, total bigint NOT NULL);
CREATE TABLE app.audit_entries (
  event_pos bigint PRIMARY KEY,
  value bigint NOT NULL,
  live_applies bigint NOT NULL
);
INSERT INTO subscriptions (subscription_name, consumer_group_member, consumer_group_size, last_seen)
VALUES ('audit-subscription', 0, 2, 0), ('audit-subscription', 1, 2, 0);
```

  Two consumer-group members are deliberate: they pin that the floor is the minimum
  member position and that the promotion advance moves every member (the same shape
  `GroupRebuildSpec`'s `mixedFixtureSql` uses). The `subscriptions` table is Kiroku's,
  created by the suite migrations; seeding rows directly in test fixture SQL is the
  established pattern (`GroupRebuildSpec.hs`, `mixedFixtureSql`).

- A catalog (call it `redeliveryCatalog`) with: one source (`CategorySource
  (CategoryName "audit")`, codec fingerprint e.g. `"audit-v1"`); one target
  `app.audit_totals` with `ClearBeforeReplay`; one rebuild group; one
  `SubscriptionDeclaration` (name `"audit-subscription"`, `checkpointOnMissing =
  FromBeginning`); one `DedupKeyDeclaration` (`dedupName = "audit-async"`); one query
  model binding over `app.audit_totals` (copy `CatalogSpec.readModelDefinition`'s
  shape: an `Eventual` `ReadModel Text ()` with `subscriptionName =
  "audit-subscription"`, registry name e.g. `"audit-query"`); and one projection
  definition owning the target with `replayPolicy = Replayable …` and a single
  `AsyncHandler`. Validation requires the async projection's `name` to equal the
  declared dedup name (`"audit-async"`), its `subscriptionName` to equal the declared
  subscription, its `readModelName` to equal the bound query's registry name, and the
  subscription's source to equal the projection set's source — get any of these wrong
  and `validateProjectionCatalog` tells you with a typed diagnostic.

- The **non-idempotent live handler** (`applyRecorded`): decode the payload as `Int64`
  (events are appended with `Aeson.toJSON (n :: Int64)`, same as the existing helpers)
  and run, in one statement, an add-upsert:

```sql
INSERT INTO app.audit_totals (id, total) VALUES ('audit', $1)
ON CONFLICT (id) DO UPDATE SET total = app.audit_totals.total + EXCLUDED.total
```

  Applying an event twice visibly doubles its contribution. `idempotencyKey` is
  `(^. #eventId)`, as in `CatalogSpec.catalogAsyncProjection`.

- The **replay adapter**: `decodeForReplay` accepts `EventType "AuditEvent"` payloads
  (mirror `goodDecoder`), and `applyForReplay` performs the same add-upsert — the
  correct replay of a truncated table.

Now the first red test, "promotion leaves redelivery safe for a clear-before-replay
async projection":

1. Apply the fixture SQL. Append three events (values 10, 20, 30) to stream
   `audit-1` with `EventType "AuditEvent"` using the existing `appendRaw` helper.
2. Validate and register the catalog (`expectValid`, `registerProjectionCatalog`).
3. Simulate the live worker: read the category's events
   (`Store.readCategory (CategoryName "audit") (GlobalPosition 0) 100` or read them
   back per stream), and for each event run
   `applyAsyncProjectionFromCatalog validated auditProjectionId auditAsyncProjection event`
   inside `Store.runTransaction`, asserting `CatalogAsyncApplied`, then move both
   member checkpoints to the event's global position with a direct
   `UPDATE subscriptions SET last_seen = $2 WHERE subscription_name = $1` statement
   (mirroring `upsertSubscriptionCursorStmt` in `keiro/test/Main.hs`). Assert
   `app.audit_totals` shows `total = 60` and the dedup count for `'audit-async'` is 3.
4. Rebuild: `startCatalogRebuild validated auditGroupId (options "redelivery-run" 2)`
   (the existing `options` helper; `replayFrom = GlobalPosition 0`). Assert the report
   is `RebuildRunPromoted` and note `report ^. #capturedHead` (call it H). Assert the
   replay restored `total = 60`.
5. **The assertions that are red today.** After promotion:
   - both members' `last_seen` for `'audit-subscription'` equal H
     (today: 0 — preparation reset them and nothing advanced them);
   - the dedup count for `'audit-async'` is 3
     (today: 0 — deleted at begin, never re-seeded);
   - drive the worker path again over all three events (simulating both the parked
     in-flight delivery and checkpoint-based redelivery):
     every `applyAsyncProjectionFromCatalog` call returns `CatalogAsyncDuplicate`
     (today: `CatalogAsyncApplied`), and afterwards `total` is still 60
     (today: 120).

The second red test, "promotion leaves redelivery safe for a preserve-and-reconcile
async projection", uses a variant catalog whose async-owned target is
`app.audit_entries` with `PreserveAndReconcile` (derive it from the first catalog with a
lens update, as `GroupRebuildSpec.mixedPolicyCatalogFor` does). Its live handler inserts
one row per event and counts applications:

```sql
INSERT INTO app.audit_entries (event_pos, value, live_applies) VALUES ($1, $2, 1)
ON CONFLICT (event_pos) DO UPDATE
  SET live_applies = app.audit_entries.live_applies + 1
```

Its replay adapter reconciles the preserved table idempotently
(`INSERT … ON CONFLICT (event_pos) DO NOTHING`, never touching `live_applies`). The
flow is the same: live-apply three events with checkpoint saves, rebuild with
`replayFrom = 0`, promote, then redeliver all three events through the worker path.
Red assertions: every redelivery returns `CatalogAsyncDuplicate` and every row still has
`live_applies = 1` (today: redelivery returns `CatalogAsyncApplied` and `live_applies`
becomes 2 — the preserved table is corrupted even though replay itself was perfectly
reconciling).

Run `cabal test keiro-test` and capture the failure output for both tests into this
plan (Validation and Acceptance section) — the expected red is the doubled
total / `live_applies = 2`, `CatalogAsyncApplied` outcomes, and checkpoints at 0.

Acceptance for M1: both new tests fail with exactly those assertion messages; every
pre-existing test still passes.


### Milestone 2 — expose each async projection's redelivery identity from the catalog

Scope: a pure, exported catalog accessor that the promotion fix (and later plan 256)
uses to know, for one rebuild group, every replayable async projection's subscription,
dedup name, source scope, and idempotency-key function. At the end the accessor exists,
is exported, and its membership is pinned by tests.

In `keiro/src/Keiro/Projection/Catalog.hs`, add (near `catalogReplayAdapters`, which it
mirrors structurally):

```haskell
-- | One replayable async handler's redelivery identity: everything promotion
-- needs to re-seed dedup rows and advance the declared checkpoint for one
-- rebuild group. Membership matches 'preparationFor' exactly: replayable
-- definitions of the group, regardless of target reset policy.
data CatalogAsyncDedupSpec = CatalogAsyncDedupSpec
  { specSubscriptionName :: !Text,
    specDedupName :: !Text,
    specSourceId :: !SourceId,
    specSourceScope :: !SourceScope,
    specIdempotencyKey :: !(RecordedEvent -> EventId)
  }
  deriving stock (Generic)

catalogAsyncIdempotencyKeys ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  [CatalogAsyncDedupSpec]
```

Implementation: walk `originalCatalog ^. #projectionSets` exactly as
`catalogReplayAdapters` does (around line 1096), keeping definitions whose
`rebuildGroup` matches and whose `replayPolicy` is `Replayable`; for each
`AsyncHandler projection subscriptionId dedupId _` in the definition's handlers, emit
one spec. Resolve the subscription name via the inventory's subscriptions (as
`asyncProjectionRegistrations`, around line 1049, does) and the dedup name via the
inventory's dedup keys; take the source id from the projection set's
`projectionSource` and resolve its scope from the catalog inventory's
`inventorySources` (as `sourceSpecs` in `Runner.hs` does); take `specIdempotencyKey`
from the `AsyncProjection`'s `idempotencyKey` field. Deterministic order: preserve
projection-set and definition declaration order, like the adapter fleet. The membership
is by construction the same set whose dedup rows `preparationFor` deletes and whose
subscriptions it resets — that equivalence is the invariant everything else relies on,
so pin it: in the M1 test group (or `CatalogSpec` if more natural), assert that for the
redelivery catalog `catalogAsyncIdempotencyKeys` returns exactly one spec with
subscription `"audit-subscription"`, dedup name `"audit-async"`, the audit source and
scope; and assert a `LiveOnly` variant of the definition yields `[]`. Export the type
and function from the module's export list (plan 256 consumes them; say so in the
Haddock).

Acceptance: `cabal build all` compiles; the membership assertions pass; the M1 tests
are still red (nothing behavioral changed yet).


### Milestone 3 — make promotion backfill dedup and advance checkpoints

Scope: the fix. At the end, `verifyAndPromote` re-seeds the dedup rows for the replayed
range and advances the declared checkpoints to the captured head inside the promote
transaction, the M1 tests pass, and the whole suite is green.

**Export the advance.** In `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`, add
`resetDeclaredSubscriptions` (around line 528) to the module export list, with a Haddock
note that begin uses it to rewind to `replayFrom` and promotion uses it to advance to
the captured head (both are Kiroku exact-position resets; ADR-31 owns the composition
rule). Also add and export a batched dedup insert next to `deleteProjectionDedupStmt`:

```haskell
insertProjectionDedupBatchStmt :: Statement ([Text], [UUID]) Int64
```

```sql
INSERT INTO keiro.keiro_projection_dedup (projection_name, event_id)
SELECT pair.name, pair.event
FROM unnest($1::text[], $2::uuid[]) AS pair (name, event)
ON CONFLICT (projection_name, event_id) DO NOTHING
```

with `D.rowsAffected` as the result (evidence of how many rows were actually new;
conflicts are expected and fine). Encode with `contrazip2` over two
`E.foldableArray` params, mirroring the existing statements in the file.

**Collect the backfill input.** In `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`, add:

```haskell
-- | The promotion-time redelivery-safety input for one group: every
-- (dedup name, event id) pair a subscription could redeliver at or below the
-- captured head, plus the floors it was computed from. Missing checkpoint
-- rows are reported, never invented.
data AsyncDedupBackfill = AsyncDedupBackfill
  { backfillPairs :: ![(Text, UUID)],
    backfillFloors :: ![(Text, GlobalPosition)]
  }

collectAsyncDedupBackfill ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  Int32 ->              -- page size (reuse the run's configured page size)
  GlobalPosition ->     -- captured head H
  Eff es (Either [SubscriptionName] AsyncDedupBackfill)
```

Implementation: call `catalogAsyncIdempotencyKeys`; if empty, return an empty backfill
immediately (inline-only groups take the fast path). Otherwise read Kiroku's checkpoint
inventory once (`subscriptionCheckpointInventory` from `Kiroku.Store.Subscription`,
already used by `keiro/src/Keiro/Projection.hs` and re-exported through
`Keiro.ReadModel`'s `subscriptionPositionFromInventory`, which derives the minimum
across matching consumer-group members — the floor). Any spec whose subscription has no
row at all goes into the `Left` (deduplicated, sorted). For the events, group specs by
`(specSourceId, specSourceScope)` and page each distinct scope once from the minimum
floor among its specs up to H, using the same store reads the runner already uses
(`Store.readAllForward` / `Store.readCategory`, as `readSourcePage` around line 485
does; stop when a page proves positions beyond H, exactly like `readSourcePage`'s
`takeWhile`). For every event with position strictly greater than a spec's own floor and
at most H, emit `(specDedupName, uuid)` where the UUID is unwrapped from
`specIdempotencyKey event` (`EventId` is a newtype over `UUID` in
`Kiroku.Store.Types`; pattern-match it locally as `Projection.hs`'s `eventIdToUuid`
does). History at or below H is immutable, so reading it outside the promote
transaction is sound; the pairs are buffered in memory — acceptable for the offline
protocol (see Decision Log; plan 256's bounded-range cutover is the scalable future).

Why the floor and not `replayFrom`: see the Decision Log. For a contract-honoring
worker the floor at promotion IS `replayFrom` (preparation reset it there and the fence
prevented checkpointing since), so the backfilled range is exactly the replayed range
`(replayFrom, H]`. Reading the floor keeps the helper honest — it covers precisely what
the subscription can redeliver — and needs no persisted format change. One boundary
case is intentionally out of scope: an operator who starts a rebuild with `replayFrom`
strictly ahead of the worker's real progress, while a delivery below `replayFrom` is
parked, creates an ambiguity that exists identically in the legacy protocol and
predates this plan; the backfill covers the redelivery window as durable state defines
it.

**Extend the promote transaction.** In `verifyAndPromote` (around lines 653–701), after
verification succeeds and before opening the promote transaction: fetch the run report
(`inspectCatalogRebuildMaybe runId`) for `capturedHead` and `configuredPageSize` (or
thread them in from `driveCatalogRebuild`, which has both — your choice; keep the
signature change minimal), then run `collectAsyncDedupBackfill`. On `Left missing`:
`recordFailure runId "promotion.checkpoints-missing" detail Nothing Nothing Nothing`,
count a failure metric, and return the new typed error (below) — the run is `failed`,
the group still `rebuilding`, and `resumeRunStmt` (around line 1073) accepts exactly
that state after the operator repairs the subscription rows. On `Right backfill`,
inside the existing promote transaction, after `markVerifiedStmt` and before
`finishGroupRebuildTx`:

1. insert `backfillPairs` in bounded batches (e.g. 10,000 pairs per
   `insertProjectionDedupBatchStmt` call) — idempotent by `ON CONFLICT DO NOTHING`;
2. when the group has async specs, advance the checkpoints:
   `resetDeclaredSubscriptions (handlePreparation handle) capturedHead` — the handle is
   already in scope (`groupRebuildHandleFor`, which reconstructs `handlePreparation`
   via `preparationFor`, so the advanced names are exactly the names begin reset; a
   non-empty `missingSubscriptionNames` in the report here means rows vanished after
   the collect step — `Tx.condemn` and surface the same typed error;
3. proceed to `finishGroupRebuildTx` and `markPromotedStmt` unchanged.

Because everything is in one transaction, promotion and redelivery safety commit or
roll back together. Skip steps 1–2 entirely when `catalogAsyncIdempotencyKeys` is empty
so inline-only groups execute byte-for-byte the same statements as today.

**The typed error.** Add to `CatalogRebuildError` (around line 106):

```haskell
  | CatalogRebuildPromotionCheckpointsMissing !RebuildRunId ![SubscriptionName]
```

importing `SubscriptionName` from `Kiroku.Store.Subscription.Types` (as
`keiro/src/Keiro/ReadModel/Rebuild.hs` already does). The operations layer
(`keiro/src/Keiro/Projection/Catalog/Operations.hs`, `keiro-ops`) wraps
`CatalogRebuildError` generically via derived `Show`, so no renderer needs extending —
verify with `cabal build all`.

Re-export the new names through `keiro/src/Keiro/ReadModel/Rebuild.hs` (the public
facade module) so applications and plan 256 reach them without importing internal
modules: `CatalogAsyncDedupSpec`/`catalogAsyncIdempotencyKeys` stay in
`Keiro.Projection.Catalog`'s export list; add `collectAsyncDedupBackfill`,
`AsyncDedupBackfill (..)`, `insertProjectionDedupBatchStmt`, and
`resetDeclaredSubscriptions` to the rebuild modules' export lists as appropriate.

Acceptance: both M1 tests now pass; `cabal test keiro-test` is fully green — in
particular every pre-existing `ProjectionReplaySpec`, `GroupRebuildSpec`, and legacy
rebuild test passes unmodified, which proves inline-only groups and the legacy protocol
are untouched. Commit the tests and fix together (Conventional Commits, trailers as
below).


### Milestone 4 — widen the proof matrix: resume, failure, and fencing honesty

Scope: pin the recovery-path behaviors the Decision Log relies on. At the end, three
more tests pass in the new `ProjectionReplaySpec` group.

**Resume-path backfill.** Register the redelivery catalog but with a failing
verification hook (mirror `failingVerification`); start the rebuild — it fails after
replay committed (`CatalogRebuildVerificationFailed`). Assert the mid-failure state is
honest: dedup count for `'audit-async'` is 0, both member checkpoints are 0, the group
is `GroupRebuilding`, and a worker delivery returns `CatalogAsyncFenced` (no write, no
checkpoint moved) — this is also the abandon-window story, since an abandoned group
keeps its `active_run_id` and stays fenced the same way. Then resume with the repaired
(passing-verification) catalog via `resumeCatalogRebuild` (the existing
"retains committed pages across verification failure" test shows the exact technique).
After the resumed promotion: checkpoints equal H, dedup count is 3, redelivering all
three events yields `CatalogAsyncDuplicate` and `total = 60`. This proves the backfill
lives on the one promotion path both `startCatalogRebuild` and `resumeCatalogRebuild`
share, and that a crash-or-fail between begin and promote leaves a state a resume (or a
fresh rebuild, once plan 248 widens `beginGroupRebuild` beyond `GroupLive`) fully
recovers: re-preparation deletes any dedup rows and re-resets checkpoints, so nothing
this plan adds can double-apply across attempts.

**Multi-member advance.** Already folded into the M1 fixture (two members): add the
explicit assertion, if M1 didn't, that BOTH member rows stand at H after promotion and
that the floor used for backfill was the minimum member position (drive one member's
checkpoint ahead of the other before the rebuild to make the minimum meaningful; begin
resets both to `replayFrom`, so also assert both are 0 mid-rebuild).

**Idempotent re-promotion safety.** No new test machinery: assert that running the
redelivery loop twice after promotion still yields duplicates and an unchanged total —
the dedup rows survive redelivery, which is the property that makes the backfill
`ON CONFLICT DO NOTHING` sufficient under retried promote transactions as well.

Acceptance: `cabal test keiro-test` green with all new tests listed by name in the
output.


### Milestone 5 — documentation, ADR amendment, changelog, full gate

Scope: align the written contracts with the restored mechanical one; run the full
repository gate.

- **ADR-31** (`docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`):
  amend the Decision and Consequences sections to record the promotion half of the
  lifecycle: the offline catalog rebuild's promotion transaction backfills
  `keiro_projection_dedup` for each replayable async projection over the redelivery
  window (durable floor at promotion, captured head] using the projection's own
  idempotency key, and advances every persisted member of the declared subscriptions to
  the captured head through the same Kiroku reset primitive preparation uses; missing
  declared rows condemn promotion with typed evidence exactly as they condemn
  preparation. Follow the ADR workflow in `agents/skills/exec-plan/ADR.md`: the bundle
  is profile-governed, so preserve `docId: ADR-31`, update the `timestamp`, run the
  strict `okf validate docs/adr --strict --profile docs/adr/profile.dhall
  --profile-enforce --log-enforce` check, and record the revision with `okf log add`.
  Do not amend ADR-32 unless implementation forced a persisted-format change (it should
  not have; see Decision Log).
- **`docs/user/read-models-and-projections.md`**: replace the line "Async projections
  are at-least-once in v1. Make every async handler idempotent." (around line 736) with
  the truthful contract: delivery is at-least-once, `idempotencyKey` plus the dedup
  table make application exactly-once per retained dedup window — including across
  offline catalog rebuilds, whose promotion re-seeds dedup and advances checkpoints —
  and idempotent handler SQL remains recommended defense-in-depth because dedup rows
  can be pruned beyond the redelivery window. In the offline-rebuild section (around
  lines 292–312), add one short paragraph after the preparation description stating
  what promotion now does (backfill + advance in the promotion transaction).
- **`docs/guides/run-and-operate-jitsurei.md`**: rewrite the sentence "Async
  projections must be idempotent by source event id." (line 128) the same way —
  recommended defense-in-depth, not a correctness requirement; the framework's dedup
  key is the safety mechanism.
- **`keiro/CHANGELOG.md`**, `Unreleased` under a `### Fixed` heading (create it if
  absent): the offline catalog rebuild's promotion now backfills async projection dedup
  rows for the replayed range and advances the declared subscription checkpoints to the
  captured head inside the promotion transaction; previously every replayed event was
  redelivered and re-applied after promotion, corrupting non-idempotent async read
  models. Mention the new exports (`catalogAsyncIdempotencyKeys`,
  `collectAsyncDedupBackfill`, `resetDeclaredSubscriptions`,
  `insertProjectionDedupBatchStmt`, `CatalogRebuildPromotionCheckpointsMissing`) under
  `### Added`.
- Run the full gate and finish the living sections; perform the ADR distillation pass
  (the Decision Log entries about the promotion contract belong in ADR-31; task-local
  details stay here). Update the MasterPlan 39 Progress list entry for EP-5 when done
  (coordination edit, allowed at completion per the MasterPlan's own instructions —
  if in doubt, leave a note for the MasterPlan owner instead).

Acceptance: `just verify` passes from the repository root (it runs the process-compose
check, jitsurei, the Haskell verification including all test suites, ADR validation,
and the policy checks — see `justfile`).


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

Baseline (Milestone 1):

```bash
cabal build all
cabal test keiro-test
```

Both must succeed before any edit. The keiro-test suite starts its own ephemeral
PostgreSQL through `keiro-test-support`; no external database setup is needed.

Red run (Milestone 1, after writing the tests) — expect exactly the new tests to fail:

```bash
cabal test keiro-test
```

Expected red excerpts (shapes, exact positions may differ by fixture):

```text
  catalog rebuild promotion redelivery
    promotion leaves redelivery safe for a clear-before-replay async projection FAILED
      expected: CatalogAsyncDuplicate
       but got: CatalogAsyncApplied
    promotion leaves redelivery safe for a preserve-and-reconcile async projection FAILED
      expected: 1
       but got: 2
```

(Also observed on the first test if you assert totals/checkpoints before outcomes:
`expected: 60 / but got: 120` and `expected: GlobalPosition 6 / but got: GlobalPosition 0`.)
Capture the real output into Validation and Acceptance.

Iterate during Milestones 2–4:

```bash
cabal build all
cabal test keiro-test
```

To run only the replay spec while iterating (hspec match):

```bash
cabal test keiro-test --test-options='--match "catalog rebuild promotion redelivery"'
```

After the docs/ADR edits (Milestone 5):

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

`just verify` is the full repository gate and must pass before the plan is marked
complete.


### Commit and trailer convention

Use Conventional Commits (`fix(rebuild): …`, `test(rebuild): …`, `docs(adr): …` etc.),
committing directly to the current branch. Every commit for this plan carries the
trailers:

```text
MasterPlan: docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md
ExecPlan: docs/plans/258-make-catalog-rebuild-promotion-redelivery-safe-for-async-projections.md
Intention: intention_01kzw6dk7qe1qayx2qdz6vcqfd
```

Suggested commit sequence: one commit for M1+M2+M3 (red tests, helper, fix — keeps
every commit green), one for M4 (matrix tests), one for M5 (docs/ADR/changelog). Splitting
M2 out first is also fine since it is additive and green on its own.


## Validation and Acceptance

The change is proven by behavior, not by code shape:

1. **Redelivery is inert after promotion (clear-before-replay).** Given three events
   applied live by a non-idempotent async counter handler (`total = 60`), then
   `startCatalogRebuild` … `RebuildRunPromoted`: replay restores `total = 60`; both
   consumer-group members of the declared subscription stand at the run's
   `capturedHead`; the dedup table holds one row per event for the projection; and
   driving `applyAsyncProjectionFromCatalog` over all three events again returns
   `CatalogAsyncDuplicate` three times with `total` still 60. Before this plan the same
   scenario returns `CatalogAsyncApplied` three times, `total = 120`, checkpoints at 0,
   and zero dedup rows — the captured red transcript goes here.
2. **Preserved targets equally protected.** The `PreserveAndReconcile` variant shows
   `live_applies = 1` on every row after promote-then-redeliver (previously 2), with
   duplicates reported.
3. **Resume path covered.** A verification-failed run leaves dedup empty, checkpoints
   at 0, and deliveries fenced (`CatalogAsyncFenced`); resuming with a repaired catalog
   promotes and yields the exact state of (1).
4. **No collateral behavior change.** Every pre-existing test in
   `cabal test keiro-test` passes unmodified — in particular all existing
   `ProjectionReplaySpec` scenarios (inline-only groups take the empty-backfill fast
   path) and the legacy rebuild tests in `keiro/test/Main.hs` (legacy protocol
   untouched).
5. **Full gate.** `just verify` passes, including the strict ADR profile check for the
   ADR-31 amendment.

Record the final green run's relevant excerpt (the new test names passing) and the red
excerpt from Milestone 1 in this section as evidence when executing the plan.


## Idempotence and Recovery

Every step is safe to repeat. The tests run against per-example database clones, so
re-running them cannot accumulate state. The backfill insert is `ON CONFLICT DO
NOTHING` and the checkpoint advance sets an exact position, so a retried promote
transaction (after a crash or a serialization failure) converges to the same state. A
crash strictly before the promote transaction commits leaves the group `rebuilding`
with dedup unseeded and checkpoints at `replayFrom` — precisely today's mid-rebuild
state — and is recovered by `resumeCatalogRebuild` (which re-runs verification,
recomputes the backfill input from immutable history and the unchanged floors, and
retries promotion) or by abandoning and running a fresh rebuild, whose preparation
deletes and resets everything again. A promotion refused by
`CatalogRebuildPromotionCheckpointsMissing` records failure evidence on the run;
`resumeRunStmt` explicitly accepts a `failed` run whose group is still `rebuilding`, so
the operator repairs the missing subscription rows and resumes. No step in this plan
deletes or rewrites application data; the only destructive operations (target truncate,
dedup delete, checkpoint rewind) remain where they were, in preparation, unchanged.

If implementation stalls partway, the repository stays releasable: Milestone 2 is
purely additive; Milestone 3 is the only behavioral edit and lands in the same commit
as its red-turned-green tests.


## Interfaces and Dependencies

New and changed public surface at the end of the plan (all in the `keiro` package;
names may be adjusted for house style, but record any rename in the Decision Log
because plan 256 consumes these):

- `Keiro.Projection.Catalog` (`keiro/src/Keiro/Projection/Catalog.hs`):
  `data CatalogAsyncDedupSpec` with `specSubscriptionName :: Text`,
  `specDedupName :: Text`, `specSourceId :: SourceId`,
  `specSourceScope :: SourceScope`, `specIdempotencyKey :: RecordedEvent -> EventId`;
  `catalogAsyncIdempotencyKeys :: ValidatedProjectionCatalog -> RebuildGroupId ->
  [CatalogAsyncDedupSpec]`. Pure; membership mirrors `preparationFor` (replayable-only,
  group-scoped, target-policy-blind).
- `Keiro.ReadModel.Rebuild.Group` (`keiro/src/Keiro/ReadModel/Rebuild/Group.hs`):
  export existing `resetDeclaredSubscriptions :: GroupPreparation -> GlobalPosition ->
  Tx.Transaction SubscriptionCheckpointResetReport`; add and export
  `insertProjectionDedupBatchStmt :: Statement ([Text], [UUID]) Int64`.
- `Keiro.ReadModel.Rebuild.Runner` (`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`):
  `data AsyncDedupBackfill` (`backfillPairs :: [(Text, UUID)]`,
  `backfillFloors :: [(Text, GlobalPosition)]`);
  `collectAsyncDedupBackfill :: (Store :> es) => ValidatedProjectionCatalog ->
  RebuildGroupId -> Int32 -> GlobalPosition -> Eff es (Either [SubscriptionName]
  AsyncDedupBackfill)`; new `CatalogRebuildError` constructor
  `CatalogRebuildPromotionCheckpointsMissing !RebuildRunId ![SubscriptionName]`;
  `verifyAndPromote` behavior extended as specified (signature change, if any, stays
  internal). Re-export the new names through `Keiro.ReadModel.Rebuild`.

Dependencies used, and why: Kiroku's `resetSubscriptionCheckpointsTx`
(`Kiroku.Store.Subscription.Checkpoint`) is the only sanctioned way to move checkpoints
non-monotonically (ADR-28/ADR-31; semantics in
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`); Kiroku's
`subscriptionCheckpointInventory` plus Keiro's `subscriptionPositionFromInventory`
(`keiro/src/Keiro/ReadModel.hs`) provide the durable floor without touching Kiroku's
table; the store read effects (`Store.readAllForward`, `Store.readCategory`) page
immutable history for the backfill input. No new package dependencies; no migrations;
no persisted-format changes; no keiro-dsl, keiro-ops, or jitsurei code changes (the
ops layer renders the new error constructor through derived `Show`).

Consumers to keep in mind: plan 256 (`docs/plans/256-rebuild-into-versioned-targets-with-atomic-cutover.md`)
reuses `catalogAsyncIdempotencyKeys`, the backfill collector, the batched insert, and
the checkpoint advance in its cutover promote transaction — it pages `(checkpoint, Hf]`
with a live (unfenced) worker's floor instead of `replayFrom`, which is exactly why the
floor-based range was chosen here. If that plan lands first (it should not; it declares
this plan as landing first), reconcile signatures against its landed code and record
the delta in Surprises & Discoveries.
