---
id: 256
slug: rebuild-into-versioned-targets-with-atomic-cutover
title: "Rebuild into versioned targets with atomic cutover"
kind: exec-plan
created_at: 2026-08-12T23:55:46Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
master_plan: "docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md"
---

# Rebuild into versioned targets with atomic cutover

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today, rebuilding a Keiro read-model group is an offline maintenance window: preparation
truncates every `ClearBeforeReplay` table, replay refills it from the beginning of history,
and until promotion every in-process reader and writer of that group is fenced while every
out-of-process SQL reader silently watches a truncated, then progressively refilling table.
Improvement request IR-22
(`docs/improvement-requests/make-read-models-safely-readable-by-out-of-process-consumers.md`),
capability 3, asks for the alternative: replay into a **new target version alongside the live
one** — which keeps serving, stale but monotonic and internally consistent — then **swap
atomically in one transaction** and drop the old version after drain.

After this plan, an operator can run a catalog rebuild in a new *versioned* mode:

- `keiro-ops rebuild start GROUP --versioned --run-id r1 ... --force` creates Keiro-owned
  sibling copies of the group's tables, replays history into those siblings while the
  declared tables keep serving reads and keep receiving live writes, converges through
  repeated catch-up rounds, then takes one short write fence, replays the final tail,
  verifies, and swaps the siblings under the declared table names in a single transaction.
- Throughout the rebuild, an external SQL reader using the sanctioned read surface from
  `docs/plans/255-fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface.md`
  keeps getting answers: pre-rebuild state until the promotion commit, rebuilt state after
  it, and **never** a truncated or partially replayed table. That is IR-22's acceptance
  criterion for this capability, and this plan proves it with a database test in which a
  concurrent reader polls across the whole lifecycle.
- The old version survives the swap under a retired name until the operator drops it with
  `keiro-ops rebuild drop-retired RUN_ID --force`.

The existing offline in-place rebuild remains fully supported and remains the default; the
versioned mode is opt-in per invocation. This plan deliberately revisits a stated ownership
stance — the runtime-patterns standard currently says Keiro never creates, migrates, or
swaps application-owned tables — and therefore produces a new ADR defining exactly what
Keiro now owns (versioned physical siblings it creates, fills, swaps, and drops) and what
stays application-owned (the declared table shape and all DDL evolution of it).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `Keiro.ReadModel.Rebuild.Versioned` DDL helpers written (clone, rename swap,
      eligibility probes, sequence resync) with `VersionedDdlSpec` proving PostgreSQL
      behavior (clone coverage, concurrent-reader visibility across a rename swap,
      transactional multi-rename atomicity).
- [ ] M2: migration `NNNN` (new group statuses, `target_mode` run column,
      `keiro_projection_rebuild_run_targets` table, additive status-relation columns),
      manifest + native lock + expected-schema snapshot updated,
      `cabal test keiro-migrations-test` green.
- [ ] M2: `Group.hs` versioned lifecycle (begin-versioned in one transaction, eligibility
      refusals, abandon-versioned back to live, fence matrix in `lockProjectionGroupsTx`)
      with `GroupRebuildSpec` coverage.
- [ ] M2: plan 255's generated guard regenerated to classify `rebuilding-versioned` and
      `cutover` as serving (`rebuilding`/`failed` keep raising `KR001`), with a
      DB-backed test that the external read surface keeps serving throughout a
      versioned rebuild (skip if plan 255 has not landed; revisit before M5).
- [ ] M3: `PhysicalTargets` introduced; `ReplayAdapter.applyForReplay` and
      `RebuildVerification.verifyRebuild` made physical-target-parametric; offline runner
      passes declared tables; all existing suites green (offline behavior unchanged).
- [ ] M3: keiro-dsl scaffold emits parametric replay/verification holes and
      `ReadModelTable` resolver; goldens and jitsurei holes updated;
      `cabal test keiro-dsl:tests` and `cabal test jitsurei-test` green.
- [ ] M4: versioned replay protocol in `Runner.hs` (mode dispatch, staging writes,
      catch-up rounds with target extension, resume via run-row mode + contract-v4),
      `ProjectionReplaySpec` versioned coverage green.
- [ ] M5: cutover (enter-cutover fence, tail replay, staged verification, completion
      proof, dedup backfill, checkpoint advance, sequence resync, rename swap,
      external-read view re-point, promotion) plus the concurrent external-reader
      acceptance test and crash-resume test.
- [ ] M6: drain/drop library API and keiro-ops surface (`--versioned`,
      `--cutover-threshold`, `rebuild drop-retired`), `cabal test keiro-ops-test` green,
      CLI transcript captured.
- [ ] M7: new ADR (versioned target lifecycle ownership) allocated, ADR-32 amended,
      `docs/user/read-models-and-projections.md` extended, status-relation contract doc
      extended, changelogs updated (keiro, keiro-dsl, keiro-ops, keiro-migrations),
      `just verify` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Physical shape of a versioned target is a **Keiro-created sibling table in the
  application's schema**, cloned structurally from the live table with
  `CREATE TABLE ... (LIKE <live> INCLUDING ALL)`, promoted by an **`ALTER TABLE RENAME`
  swap** under the declared name. The declared qualified table name always denotes the
  live version. The alternative — permanently versioned physical names behind a registry
  pointer that every reader and writer resolves — was rejected.
  Rationale: every SQL body in this system is an opaque closure with the qualified table
  name baked in at construction: `ReadModel.query` closures, `InlineProjection.apply`
  closures, replay adapters, and the DSL-generated `ReadModelTable` constant
  (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, `emitReadModelTable`) all interpolate
  `qualifyTable schema table` as a compile-time constant. A pointer-flip design would
  require every one of those sites — including hand-written application SQL — to resolve
  a pointer per statement, which the runtime can neither rewrite nor verify. A rename swap
  keeps every live code path untouched and makes "the declared name is the live version"
  the invariant the whole design hangs on.
  Date: 2026-08-12
- Decision: During a versioned rebuild the group is **not write-fenced**. A new group
  lifecycle status `rebuilding-versioned` keeps inline and async writers running against
  the live tables while replay fills the staging siblings. Convergence uses repeated
  catch-up rounds that extend the captured head, followed by a deliberately **short final
  fence**: a `cutover` status that blocks group writers exactly like `rebuilding` does
  today while the remaining tail (bounded by an operator-tunable threshold) is replayed,
  verified, and swapped. This plan says so honestly: group writers are blocked for the
  tail-replay-plus-swap window, and readers are blocked only for the duration of the
  rename's `ACCESS EXCLUSIVE` lock.
  Rationale: an unfenced convergence with a bounded final fence is the only design that
  keeps both the write path and the external read path available for the bulk of the
  rebuild without inventing an unverifiable dual-write protocol inside opaque handler SQL.
  Date: 2026-08-12
- Decision: Replay adapters and rebuild verification hooks become
  **physical-target-parametric** in one clean break: `applyForReplay` gains a leading
  `PhysicalTargets` argument (as does `verifyRebuild`), the offline runner passes the
  declared tables, and the versioned runner passes the staging siblings. There is no
  optional "versioned-capable" second path.
  Rationale: replay SQL must be able to address the staging table, and the only authority
  that knows the staging name is the runner. A single parametric path makes every
  replayable catalog versioned-capable by construction, avoids a capability split that
  ADR-26's closed-world validation would otherwise have to police, and is legal now
  because 0.12.0.0 has not shipped and the project has one known consumer. Closures are
  excluded from fingerprints, so this changes no slice or catalog identity.
  Date: 2026-08-12
- Decision: The `.keiro` language grammar does **not** change. Versioned rebuild is
  selected per invocation (`RebuildOptions.targetMode`, `keiro-ops rebuild start
  --versioned`), never declared in the spec. What changes on the DSL side is generated
  code only: the replay/verification hole signatures and a new `ReadModelTable` resolver
  helper. The pre-Candidate-flip language constraint from the MasterPlan therefore does
  not bind this plan.
  Rationale: whether a particular rebuild runs online is an operational choice about one
  run, not a durable property of the catalog; encoding it in the spec would force a
  fingerprint story for a fact that has none.
  Date: 2026-08-12
- Decision: Async projection convergence is handled with a **checkpoint advance plus dedup
  backfill inside the cutover fence**: cutover refuses to begin until every group async
  subscription checkpoint is within the threshold of the head; inside the fence, Keiro
  inserts `keiro_projection_dedup` rows (ON CONFLICT DO NOTHING) for every source event in
  `(checkpoint, finalHead]` per async projection, then advances the subscription
  checkpoints to the final head with `resetSubscriptionCheckpointsTx`.
  Rationale: the staging tables already contain every event ≤ finalHead via replay. A
  worker holding an in-flight batch fetched before the fence could re-apply those events
  after promotion; the backfilled dedup rows make those applications no-ops through the
  existing `applyAsyncProjectionUnfenced` conflict path, and the checkpoint advance stops
  pointless redelivery. This deliberately differs from the offline protocol (which resets
  checkpoints and deletes dedup rows) because here the worker was never taken out of
  service.
  Date: 2026-08-12
- Decision: Versioned-rebuild eligibility is gated, with typed refusals, to groups where
  every target is `ClearBeforeReplay` and no target table has foreign-key constraints (in
  either direction), triggers, or row-level security. Identity/serial columns are allowed
  and resynchronized with `setval` at cutover.
  Rationale: `LIKE ... INCLUDING ALL` clones columns, defaults, identity, CHECK/NOT
  NULL constraints, and indexes, but PostgreSQL never copies foreign keys, triggers,
  policies, or grants — a swap would silently strip them from the live name. A
  `PreserveAndReconcile` target cannot be forked consistently without fencing writers for
  the duration of the copy, so preserved targets keep the offline path in this version.
  Refusing loudly is honest; widening the gate is future work recorded in the new ADR.
  Date: 2026-08-12
- Decision: Resume of a versioned run dispatches on a persisted `target_mode` column on
  `keiro_projection_rebuild_runs` and continues to require the **contract-v4** resume
  fingerprint defined by
  `docs/plans/247-capture-replay-adapter-application-order-in-the-rebuild-resume-contract.md`.
  The mode is not folded into the contract preimage.
  Rationale: the contract fingerprint answers "is this the same catalog/replay identity";
  the mode answers "which protocol drives this run". An explicit column is inspectable,
  needs no second prefix bump, and old runtimes are already excluded by the v4 fingerprint
  itself. If plan 247 lands with different naming, reconcile here and record it.
  Date: 2026-08-12
- Decision: Abandoning a versioned run returns the group directly to `live` (dropping the
  staging siblings) instead of parking it in `failed`.
  Rationale: unlike the offline protocol, versioned preparation destroys nothing — the
  live tables were never truncated — so there is no unrecoverable application state to
  fence. Failure evidence is preserved on the run row.
  Date: 2026-08-12
- Decision: The retired old version is kept under a retired name after promotion and is
  dropped only by an explicit, destructive, previewed operator command
  (`keiro-ops rebuild drop-retired`), which is also mountable in the standalone binary.
  Rationale: drain semantics (in-flight statements planned against the old table's OID,
  operator forensics) argue for keeping it briefly; dropping is irreversible and therefore
  operator-owned per ADR-28's two-phase policy. The drop needs only database state (the
  persisted retired names), so the standalone binary can mount it.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Keiro is a Haskell runtime for event-sourced services on PostgreSQL. Applications append
events to a Kiroku event store and project them into **read models**: ordinary
application-owned PostgreSQL tables filled by projection handlers. A **projection
catalog** (`keiro/src/Keiro/Projection/Catalog.hs`) is the single validated inventory of
that read side. Four identities matter here (per
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`):
a **physical target** names one application-owned qualified table
(`TargetDeclaration` with a `QualifiedTable { schemaName, tableName }` and a
`TargetResetPolicy` of `ClearBeforeReplay` or `PreserveAndReconcile`); a **rebuild group**
owns the ordered set of targets that move through one lifecycle together; a **projection
definition** owns targets and carries the live handlers plus an optional **replay
adapter**; a **query-model binding** ties a `ReadModel q r` (name, version, shapeHash,
table, SQL closure) to the group and the targets it observes. Registration persists one
row per group in `keiro.keiro_projection_rebuild_groups` and one row per query model in
`keiro.keiro_read_models` — the latter already carries `version` and `shape_hash`
columns (written by `queryRegistrationParams` in
`keiro/src/Keiro/ReadModel/Rebuild/Group.hs` from `CatalogRegistration` in
`keiro/src/Keiro/Projection/Catalog.hs`), which IR-22 reads as having anticipated a
versioned target lifecycle.


### How the offline rebuild works today

`beginGroupRebuild` (`keiro/src/Keiro/ReadModel/Rebuild/Group.hs`, around line 458) is one
transaction: it takes `FOR UPDATE` on the group row (which blocks the `FOR SHARE` locks
that every live inline and async writer takes inside its own append/apply transaction via
`lockProjectionGroupsTx`), verifies the stored slice fingerprint matches the catalog,
flips the group to `rebuilding`, marks the bound query registrations `rebuilding`,
truncates every `ClearBeforeReplay` target in one quoted multi-table `TRUNCATE`, deletes
the replayable async dedup rows, and resets the declared subscription checkpoints to the
requested `replayFrom`. From that commit onward, `runQuery` refuses the group's query
models, `runCommandWithCatalogProjections` (`keiro/src/Keiro/Projection.hs`) rolls back
appends with a typed fenced outcome, and `applyAsyncProjectionFromCatalog` performs no
dedup insert or write.

The replay runner (`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`) then captures the
newest visible global position once (`captureHead`, line 351, via
`Store.readAllBackward (GlobalPosition 0) 1`) and treats it as an immutable inclusive
target. `initializeRunTx` persists a run row in `keiro.keiro_projection_rebuild_runs`
(with `catalog_fingerprint`, `group_slice_fingerprint`, `contract_fingerprint`,
`runner_format`, `captured_head`, `page_size`) plus one row per source, adapter, and
verification hook (tables created by `keiro-migrations/migrations/0023.sql`, revised by
`0024.sql`). `driveCatalogRebuild` pages events from each source, merges pages by global
position, and applies each chunk in one transaction (`applyChunkTx`) that first proves
the run and group are still active (`lockActiveRunStmt`: run `running`, group
`rebuilding`, matching `active_run_id` and slice). When every source has proven
exhaustion through the captured head, `verifyAndPromote` runs the application's
verification hooks, evaluates the `completionProofStmt` (source, adapter, and
verification completeness against `captured_head`), and promotes run and group to
`live` in the same transaction via `finishGroupRebuildTx`. Resume
(`resumeCatalogRebuild`) recomputes the **rebuild contract** fingerprint — today
`contract-v3`, the group slice plus the runner format, hashed by `rebuildContract`
(line 826) — and refuses to resume a run whose stored contract differs.

Everything above is enforced at Haskell call boundaries. A non-Haskell process holding
its own connection and issuing `SELECT` participates in none of it — that is IR-22's
core hazard, addressed head-on by sibling plans 254 and 255; this plan removes the
*availability* cost that remains once those land.


### The load-bearing constraint: table names are baked into SQL closures

Every piece of application SQL in this system embeds its table name as text at
construction time. `ReadModel.query` is a `q -> Tx.Transaction r` closure whose SQL the
application writes against `qualifiedTableName` (`keiro/src/Keiro/ReadModel.hs`, line
264). Inline handlers (`InlineProjection.apply`) and replay adapters
(`ReplayAdapter.applyForReplay :: event -> RecordedEvent -> Tx.Transaction ()`,
`keiro/src/Keiro/Projection/Catalog.hs` line 375) are the same. The DSL scaffolds a
`ReadModelTable` module exporting a compile-time constant
(`emitReadModelTable` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, line 4565):

```haskell
ordersQualifiedTable :: Text
ordersQualifiedTable = qualifyTable "app" "orders_projection"
```

and hole authors interpolate it into their SQL. The catalog knows each target's
`QualifiedTable` but **not** its column DDL — targets are declared as coordinates plus a
reset policy, and ADR-26 keeps the SQL boundary deliberately unchecked.

Two consequences shape the whole design. First, Keiro can only create a new physical
version of a target *structurally*, by asking PostgreSQL to clone the live table
(`CREATE TABLE ... (LIKE ... INCLUDING ALL)`); it has no column authority of its own.
Second, no runtime data structure can redirect existing SQL: the only way replay can
write somewhere else is for replay SQL to take the table name as an argument, and the
only way live traffic can move to the new version is for the new version to *take over
the declared name* — an `ALTER TABLE RENAME` swap. Both are exactly what this plan does.

PostgreSQL facts the design leans on (verified in Milestone 1 against a real server):
`CREATE TABLE ... (LIKE src INCLUDING ALL)` copies column definitions, NOT NULL and
CHECK constraints, defaults, identity specifications (with fresh sequences), indexes
(including those backing PRIMARY KEY and UNIQUE constraints), statistics, storage, and
comments — but never foreign keys, triggers, row-level-security policies, or grants.
`ALTER TABLE ... RENAME TO` takes an `ACCESS EXCLUSIVE` lock, is transactional, waits
behind in-flight readers, and briefly queues new readers; after commit, statements that
resolve the name get the new table. Sequences backing identity/serial columns are
per-table objects, so the clone's sequences start fresh and must be resynchronized with
`setval` before the swap commits.


### What this plan builds: the versioned rebuild protocol

The protocol in one narrative, so every later milestone can refer back to it. A
**staging sibling** is a Keiro-created table in the application's schema named
`<table>__kv_<h>`, where `<h>` is the first 12 hex digits of the SHA-256 of
`runId || targetId` and the base name is truncated as needed to respect PostgreSQL's
63-byte identifier limit. A **retired sibling** is the old live table after promotion,
renamed to `<table>__kr_<h>`. Exact names are persisted in a new
`keiro.keiro_projection_rebuild_run_targets` table at begin time and never re-derived.

1. **Begin (one transaction).** Capture an initial head H0. Then, in a single
   transaction: lock the group row `FOR UPDATE`; require status `live`, slice match, and
   versioned eligibility (every target `ClearBeforeReplay`; no foreign keys in either
   direction, no triggers, no RLS on any target table — probed from `pg_catalog`);
   create every staging sibling with `LIKE ... INCLUDING ALL`; insert the run row with
   `target_mode = 'versioned'` and `captured_head = H0`, the per-target name rows, and
   the usual source/adapter/verification rows; set the group to `rebuilding-versioned`
   with the run as `active_run_id`. No truncation, no dedup deletion, no checkpoint
   reset — live writers and the async worker keep running, and the bound query
   registrations stay `live` so `runQuery` keeps serving. `lockProjectionGroupsTx`
   treats `rebuilding-versioned` as writes-allowed.
2. **Catch-up replay.** The existing paging/merge/chunk machinery replays sources into
   the staging siblings — adapters receive a `PhysicalTargets` mapping that resolves each
   target to its staging name. Chunk transactions prove liveness against
   `rebuilding-versioned`. When every source proves exhaustion through the current
   target, the runner captures a fresh head H(n+1): if the distance from H(n) exceeds
   the cutover threshold, it extends `captured_head` and each source's
   `target_position` (clearing `exhausted_through`) and loops; otherwise it proceeds to
   cutover. Because events keep appending, convergence is monotonic: each round replays
   only the delta.
3. **Enter cutover (short fence).** Precondition, checked without mutation: remaining
   distance ≤ threshold **and** every declared async subscription checkpoint of the
   group is within the threshold of the head. A small transaction then moves the group
   to a new `cutover` status. From that commit, `lockProjectionGroupsTx` fences the
   group's inline and async writers exactly as `rebuilding` does today. Readers — both
   in-process `runQuery` and the plan-255 external surface — keep serving the live
   (old) tables.
4. **Tail replay.** Capture the final head Hf; extend the run target to Hf; replay the
   remaining tail with the ordinary chunk transactions (now proving the `cutover`
   status). The tail is bounded by the threshold plus whatever committed between the
   threshold check and the fence.
5. **Promote (one transaction).** In a single transaction: lock group and run; run
   every verification hook against the staging tables (hooks receive the same
   `PhysicalTargets`); evaluate the completion proof against Hf; backfill
   `keiro_projection_dedup` rows for each async projection's source events in
   `(checkpoint, Hf]` (computed from pages read just before the transaction — history
   ≤ Hf is immutable — and inserted with `ON CONFLICT DO NOTHING`); advance the group's
   subscription checkpoints to Hf via `resetSubscriptionCheckpointsTx`; resynchronize
   identity/serial sequences on the staging tables with `setval`; under
   `SET LOCAL lock_timeout`, rename live → retired and staging → live for every target
   in declared order; record the retired names on the run-target rows; move the group
   `cutover -> live` (clearing `active_run_id`, stamping `completed_at`), stamp the
   bound query registrations' `last_built_at`, and mark the run `promoted`. If the
   rename cannot acquire its lock inside `lock_timeout`, the transaction aborts and the
   group stays fenced in `cutover`; resume retries the promotion.
6. **Drain and drop.** The retired tables stay in place, frozen at their pre-swap
   contents. `keiro-ops rebuild drop-retired RUN_ID` previews the exact tables and, with
   `--force`, drops them through a supported library call.

Abandonment from `rebuilding-versioned` or `cutover` drops the staging siblings and
returns the group to `live` in one transaction; the run keeps its failure evidence.

Why the external reader never sees a partial state: the sanctioned surface and every
in-process query resolve the *declared* name, which denotes the old version until the
promote transaction commits and the new version after; the staging name is never
resolved by any reader. The only reader-visible artifact of the swap is a brief block on
the rename's `ACCESS EXCLUSIVE` lock. This plan states that honestly rather than
claiming zero impact.

A note on the offline protocol's checkpoint semantics, for contrast: offline preparation
resets checkpoints to `replayFrom` and deletes dedup rows, so post-promotion redelivery
re-applies from the reset point. The versioned protocol cannot inherit that shape,
because its async worker never left service; its checkpoint/dedup handling is defined
independently in step 5 above (see the Decision Log).


### Foundations from MasterPlan 39 and coordination with sibling plans

This plan hard-depends, externally, on MasterPlan 39's
`docs/plans/246-preserve-cross-source-global-position-order-in-buffered-replay-paging.md`
(the pager must apply events in ascending global position across sources under every
paging boundary — the versioned catch-up loop replays through that same merged pager) and
`docs/plans/247-capture-replay-adapter-application-order-in-the-rebuild-resume-contract.md`
(the persisted resume contract must pin replay-adapter application order; it bumps the
contract encoding to **contract-v4**). Resume of a versioned replay uses that contract-v4
encoding unchanged; the versioned/in-place distinction is a persisted run column, not a
contract preimage fact (Decision Log). Do not start Milestone 4 until both are merged;
if their landed details differ from what this plan assumes (function names near
`rebuildContract`, the v4 preimage shape), plan against the landed code and record the
delta in Surprises & Discoveries.

Within MasterPlan 41
(`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`),
this plan hard-depends on
`docs/plans/254-publish-a-documented-projection-status-relation-for-external-readers.md`
and `docs/plans/255-fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface.md`.
The contracts this plan needs from them, stated here so drift is caught at integration:

- **Plan 254 (status relation).** This plan adds columns to that relation — *additive
  only*, never renaming or repurposing, because the relation is an external contract from
  the moment 254 documents it. The additions: `active_run_mode` (`in-place` or
  `versioned` while a run is active, else NULL), `active_run_replay_position` (the
  minimum source cursor of the active run, so an external consumer can watch convergence),
  and `active_run_captured_head`. Match 254's landed naming conventions; if it exposes
  run facts already, extend rather than duplicate.
- **Plan 255 (sanctioned read surface).** The MasterPlan describes the shared indirection
  as "the read function resolves the current live physical target rather than baking in
  a table name". Plan 255's landed shape is view-based: per-target
  `keiro_read."target__<targetId>"` views over the application table, composed under a
  guard function with frozen SQLSTATEs. PostgreSQL views bind table OIDs at definition
  time, so a rename swap does NOT redirect them — 255's contract section ("The cutover
  indirection") therefore reserves exactly one permitted mutation for this plan:
  re-pointing those `target__<targetId>` views to the new physical tables **inside the
  same cutover transaction** as the renames (`CREATE OR REPLACE VIEW` per swapped
  target). Function identities, the guard, and the SQLSTATE vocabulary stay frozen; the
  external function identity and the rows it serves are both stable across cutover.
  Additionally, this plan — not 255 — owns extending the generated guard's serving set:
  255's guard is deliberately fail-safe (any status other than `live` raises `KR001`,
  unknown statuses included), so the milestone that introduces `rebuilding-versioned`
  and `cutover` must, in the same change, regenerate the guard to classify those two
  statuses as *serving* (the live table keeps serving reads throughout; the swap's
  `ACCESS EXCLUSIVE` lock, bounded by `lock_timeout`, is what external readers briefly
  wait on during cutover) while `rebuilding` and `failed` keep raising. Verify both
  against 255's landed code before starting Milestone 2.

Plan 249 (`docs/plans/249-make-catalog-adoption-scoped-truthful-and-registry-complete.md`,
MasterPlan 39) reshapes adoption result types; adoption interacts with this plan only in
that `adoptCatalogGroups` requires `GroupLive` and therefore correctly refuses a group
mid-versioned-rebuild.

Plan 258 (`docs/plans/258-make-catalog-rebuild-promotion-redelivery-safe-for-async-projections.md`,
MasterPlan 39, added 2026-08-13) fixes the confirmed offline-path counterpart of the
dedup-backfill-plus-checkpoint-advance this plan specifies for cutover: the offline
promotion transaction today leaves checkpoints at `replayFrom` with dedup unseeded, so
post-promotion async redelivery double-applies the replayed range. Plan 258 lands
first and defines the shared backfill/advance helpers; this plan's promote transaction
(steps 4–5) reuses them rather than reimplementing — verify their landed signatures
before Milestone 5.


### Relevant ADRs

- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
  — the catalog identities and the group lifecycle
  (`live -> rebuilding -> live|failed`) this plan extends with the parallel
  `live -> rebuilding-versioned -> cutover -> live` path; also the source of the
  "online shadow-table cutover ... remain[s] outside this decision" exclusion this plan
  deliberately supersedes. Its Consequences list is updated by the new ADR's
  cross-reference rather than rewritten.
- `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
  — canonical preimages, slice-scoped lifecycle identity, and mandatory prefix bumps.
  This plan **amends** it: the persisted run format gains `target_mode` and the
  run-target name rows; the amendment records that mode is a dispatch column outside the
  contract preimage and why no prefix bump is needed beyond plan 247's v4.
- `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
  — every operator command wraps a supported library API, destructive commands are
  two-phase (preview, then `--force`), and application-code-dependent commands mount only
  in embedding binaries. The new `--versioned` start and `drop-retired` follow it.
- `docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md` — Keiro's own
  `keiro` schema is migration-owned with a checked-in expected-schema snapshot; this
  plan's registry changes ship as a keiro-migrations migration with snapshot and native
  lock updates. The snapshot covers only the `keiro` schema, so staging/retired siblings
  in application schemas are outside that gate; the new ADR states their ownership
  explicitly (Keiro-lifecycle artifacts, excluded from application schema expectations).
- `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
  — missing-checkpoint policy is catalog identity; the cutover's checkpoint advance uses
  the same Kiroku primitive as preparation and never invents policy.
- `docs/adr/0033-consistency-waits-target-reachable-visible-heads.md` — head capture
  targets reachable visible positions; the versioned runner reuses the runner's existing
  `captureHead`, and convergence distances are "global position distance" in ADR-28's
  vocabulary, never event counts.
- New ADR (this plan): versioned target lifecycle ownership — what Keiro now creates,
  fills, swaps, and drops; what stays application-owned; the eligibility gate and its
  rationale; the retired-version drain policy. Cross-repository context:
  `mori://shinzui/mori/okf/adrs/concepts/ADR-20` (one catalogued owner per live table) is
  what makes "the declared name denotes the live version" well defined.

The `docs/adr/` bundle is profile-governed (`docs/adr/profile.dhall`); allocate the new
handle with `okf id next` and validate with strict profile enforcement (commands in
Concrete Steps). The cross-repository runtime-patterns standard update
(`keiro-runtime-patterns`, which currently states "Keiro never creates, migrates, or
swaps application-owned tables") is a MasterPlan-recorded follow-up in that repository,
not a deliverable here.


## Plan of Work

The work is seven milestones. Milestone 1 is an explicit prototyping milestone (per the
ExecPlan specification) that proves the PostgreSQL mechanics before any protocol code
exists; its spec and module are kept, not discarded. Milestones 2–5 build the protocol
bottom-up: persisted lifecycle, parametric write boundary, converging replay, atomic
cutover. Milestone 6 adds the operator surface; milestone 7 pays the documentation, ADR,
and changelog obligations and runs the full gate.

Commit after every green milestone (and at safe intermediate points), using Conventional
Commits with the trailer block given in Concrete Steps.


### Milestone 1 — prototype the swap mechanics against a real PostgreSQL

Scope: prove, against the suite's real PostgreSQL 18, every database behavior the design
leans on, in a new low-level module plus spec — before the protocol exists. At the end
of this milestone there is a `Keiro.ReadModel.Rebuild.Versioned` module
(`keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs`) exporting DDL helpers, and a
`keiro/test/VersionedDdlSpec.hs` exercising them. This is prototyping in the sense that
the *protocol* may still change; the helpers and their proofs are permanent.

The module exports (initial signatures; adjust as implementation demands):

```haskell
-- Deterministic sibling names, truncated to PostgreSQL's identifier limit.
stagingTableName :: Text -> RebuildRunId -> TargetId -> Text
retiredTableName :: Text -> RebuildRunId -> TargetId -> Text

-- One CREATE TABLE ... (LIKE ... INCLUDING ALL) per target, as Tx.Transaction ().
createStagingTableTx :: QualifiedTable -> Text -> Tx.Transaction ()

-- Eligibility probes against pg_catalog: FKs (either direction), triggers, RLS.
data VersionedIneligibility
  = IneligiblePreservedTarget !TargetId
  | IneligibleForeignKey !QualifiedTable !Text
  | IneligibleTrigger !QualifiedTable !Text
  | IneligibleRowSecurity !QualifiedTable
probeVersionedEligibilityTx :: [QualifiedTable] -> Tx.Transaction [VersionedIneligibility]

-- The rename swap for one target, and sequence resync for identity/serial columns.
renameSwapTx :: QualifiedTable -> Text -> Text -> Tx.Transaction ()
resyncOwnedSequencesTx :: QualifiedTable -> Tx.Transaction ()
```

The spec (`VersionedDdlSpec`, wired into `keiro/test/Main.hs` next to `GroupRebuildSpec`,
using the suite fixture via `withFreshDatabase`/`withFreshStore` from
`keiro-test-support/src/Keiro/Test/Postgres.hs`) proves, at minimum:

- Cloning a table that has a primary key, a CHECK constraint, a default, an identity
  column, and a secondary index yields a staging table with all of those (assert via
  `pg_catalog` queries), and that a foreign key on the source is **not** cloned — the
  documented reason the eligibility gate exists.
- The eligibility probe reports each ineligibility class (create fixture tables with an
  FK, a trigger, and RLS; assert the typed findings).
- A transaction performing `retire live; promote staging` renames for **two** tables is
  atomic: a concurrent reader (second connection opened with the fixture's connection
  string) polling `SELECT` on the declared names observes only old-state rows before the
  commit and only new-state rows after it, never a mixture and never a missing table.
  Use the `forkIO`/`MVar` coordination style already present in
  `keiro/test/GroupRebuildSpec.hs`.
- `resyncOwnedSequencesTx` leaves `nextval` past the maximum replayed value for an
  identity column (and handles the empty-table case).
- Sibling names for a 63-byte-limit table name stay unique and within the limit.

Acceptance: `cabal test keiro-test` green, with the new spec listed in the output.
Promotion criterion for the prototype: every listed behavior proven; if any fails (for
example `INCLUDING ALL` copying less than assumed on the supported PostgreSQL), stop and
revise the design and this plan's Context before continuing — that is the point of the
milestone.


### Milestone 2 — persist the versioned lifecycle

Scope: the database schema and the `Group.hs` lifecycle, with no replay yet. At the end,
a versioned rebuild can begin and be abandoned, the fence matrix is enforced, and the
registry records everything durably.

**Migration.** Add the next free migration (call it `NNNN.sql`; take the next number
after whatever plans 246–255 landed; a migration is a three-file diff per ADR-9: the SQL
file, a `keiro-migrations/migrations/manifest` line, and a
`keiro-migrations/migrations.native.lock` entry). Contents:

```sql
-- versioned rebuild targets and lifecycle

ALTER TABLE keiro.keiro_projection_rebuild_groups
  DROP CONSTRAINT keiro_projection_rebuild_groups_status_chk;
ALTER TABLE keiro.keiro_projection_rebuild_groups
  ADD CONSTRAINT keiro_projection_rebuild_groups_status_chk
  CHECK (status IN ('live', 'rebuilding', 'failed', 'rebuilding-versioned', 'cutover'));

ALTER TABLE keiro.keiro_projection_rebuild_groups
  DROP CONSTRAINT keiro_projection_rebuild_groups_active_run_chk;
ALTER TABLE keiro.keiro_projection_rebuild_groups
  ADD CONSTRAINT keiro_projection_rebuild_groups_active_run_chk
  CHECK (
    (status = 'live' AND active_run_id IS NULL)
    OR (status IN ('rebuilding', 'failed', 'rebuilding-versioned', 'cutover')
        AND active_run_id IS NOT NULL)
  );

ALTER TABLE keiro.keiro_projection_rebuild_runs
  ADD COLUMN target_mode TEXT NOT NULL DEFAULT 'in-place'
  CHECK (target_mode IN ('in-place', 'versioned'));
ALTER TABLE keiro.keiro_projection_rebuild_runs
  ALTER COLUMN target_mode DROP DEFAULT;

CREATE TABLE keiro.keiro_projection_rebuild_run_targets (
  run_id TEXT NOT NULL
    REFERENCES keiro.keiro_projection_rebuild_runs (run_id) ON DELETE CASCADE,
  target_id TEXT NOT NULL,
  schema_name TEXT NOT NULL,
  live_table TEXT NOT NULL,
  staging_table TEXT NOT NULL,
  retired_table TEXT,
  retired_dropped_at TIMESTAMPTZ,
  PRIMARY KEY (run_id, target_id)
);
```

plus a `CREATE OR REPLACE VIEW` (or equivalent) that re-states plan 254's status
relation with the three additive columns named in Context (`active_run_mode`,
`active_run_replay_position`, `active_run_captured_head`), appended at the end of the
select list. Read 254's landed migration first and copy its naming conventions exactly.
Update the expected-schema snapshot
(`KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test`, then review the
diff of `keiro-migrations/expected-schema/native/keiro-v18.txt`) and the native lock
(sha256 line for the new file; the suite verifies it).

**Types and lifecycle in `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`.**

- `GroupLifecycleStatus` gains `GroupRebuildingVersioned` and `GroupCutover`;
  `groupStatusFromText`/status rendering extended everywhere it is matched (including
  `keiro-ops` rendering in Milestone 6).
- `RebuildStartError` gains
  `RebuildGroupVersionedIneligible !RebuildGroupId ![VersionedIneligibility]`.
- New `beginVersionedGroupRebuild :: (Store :> es) => ValidatedProjectionCatalog ->
  RebuildGroupId -> RebuildRequest -> GlobalPosition -> Eff es (Either RebuildStartError
  VersionedGroupRebuildHandle)` implementing protocol step 1 as **one transaction**
  (unlike the offline path, the run rows are inserted in the same transaction as the
  group transition, so a crash between them cannot strand a runless fenced group; the
  initial head H0 is passed in by the runner, which captures it just before). The handle
  carries group, run, slice, preparation, and the persisted staging map.
- `lockProjectionGroupsTx` change: `Just ("rebuilding-versioned", _) -> go rest` — the
  one-line heart of "the live one keeps serving". `cutover` deliberately falls through to
  the existing fenced arm.
- `abandonVersionedGroupRebuild`: one transaction; requires the group in
  `rebuilding-versioned` or `cutover` with the matching run; drops the staging siblings
  (`DROP TABLE IF EXISTS`, names from `keiro_projection_rebuild_run_targets`); returns
  the group to `live` with `active_run_id = NULL`; leaves failure evidence on the run row
  via the existing `recordFailureStmt` path.
- `enterCutoverTx` and `finishVersionedGroupRebuildTx`
  (`cutover -> live`, mirroring `finishGroupStmt` with the `cutover` precondition and the
  existing `markGroupQueriesLiveStmt` stamp), used by Milestone 5.
- Eligibility: `beginVersionedGroupRebuild` refuses unless every group target is
  `ClearBeforeReplay` (from `preparationFor`) and `probeVersionedEligibilityTx` returns
  no findings.

**Tests** (extend `keiro/test/GroupRebuildSpec.hs`, DB-backed via the suite-level
template fixture — never per-example migrations):

- begin-versioned on the valid catalog creates staging tables (assert existence and
  emptiness via a raw statement), persists run-target rows, and leaves query
  registrations `live`.
- during `rebuilding-versioned`, `lockProjectionGroupsTx` returns
  `ProjectionWritesAllowed` and an inline catalog command commits (contrast test: same
  command under offline `rebuilding` is fenced).
- offline `beginGroupRebuild` refuses a group in `rebuilding-versioned`
  (`RebuildGroupNotLive`), and vice versa; `adoptCatalogGroups` refuses it
  (`AdoptGroupNotLive`).
- begin-versioned refuses a group with a `PreserveAndReconcile` target and a group whose
  table carries an FK/trigger, with the typed ineligibility list.
- abandon-versioned drops the staging tables, returns the group to `live`, and live
  writes/queries continue untouched.

Acceptance: `cabal test keiro-test` and `cabal test keiro-migrations-test` green.


### Milestone 3 — make replay writes physical-target-parametric

Scope: the clean break that lets replay address staging tables. At the end, every
replayable adapter and verification hook takes a `PhysicalTargets` argument, the offline
runner passes the declared tables (behavior unchanged, proven by the existing suites),
and the DSL generates the new shapes.

**Runtime (`keiro/src/Keiro/Projection/Catalog.hs`).**

```haskell
-- | Resolution from declared targets to the physical tables a replay run may
-- write. Outside a versioned rebuild this is the identity mapping.
newtype PhysicalTargets = PhysicalTargets (Map TargetId QualifiedTable)

-- | Total: unknown ids resolve to the declared coordinates.
physicalTableFor :: PhysicalTargets -> Text -> QualifiedTable -> Text

declaredPhysicalTargets :: ValidatedProjectionCatalog -> RebuildGroupId -> PhysicalTargets
```

- `ReplayAdapter.applyForReplay` becomes
  `PhysicalTargets -> event -> RecordedEvent -> Tx.Transaction ()`;
  `replayAdapterFromCodec` threads the argument.
- `RebuildVerification.verifyRebuild` becomes
  `PhysicalTargets -> Tx.Transaction (Either Text ())`.
- `runCatalogReplayAdapter` gains the `PhysicalTargets` parameter;
  `applyChunkTx` and `runVerificationsTx` in `Runner.hs` thread it; the offline paths
  pass `declaredPhysicalTargets`.
- Add `catalogAsyncIdempotencyKeys :: ValidatedProjectionCatalog -> RebuildGroupId ->
  [(SubscriptionName, Text {- dedup name -}, SourceId, RecordedEvent -> EventId)]`
  (extracted from the typed projection sets) for Milestone 5's dedup backfill.

Closures are excluded from every fingerprint (ADR-32), so no slice, catalog, or contract
identity changes; assert that in a test (fingerprint of the fixture catalog before/after
the signature change is the same value — the existing fingerprint goldens in
`keiro/test/PreimageSpec.hs`/`CatalogSpec.hs` already pin this).

**DSL (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`).** No grammar, parser, validation, or
fingerprint change. Generated-output changes only:

- `emitReadModelTable` additionally emits
  `<stem>QualifiedTableIn :: Catalog.PhysicalTargets -> Text`, resolving via
  `physicalTableFor` with the generated target-id string and declared coordinates; the
  legacy constant remains for live SQL.
- `emitProjectionCatalogHoles` (line 4487): the replay-apply hole becomes
  `apply<Owner>Replay :: Catalog.PhysicalTargets -> <Event> -> RecordedEvent ->
  Tx.Transaction ()`; the wiring in `replayPolicyExpr` (line 4406) is unchanged in shape
  because the hole's new arity matches the new `ReplayAdapter` field.
- Verification-hook scaffolding (wherever `RebuildVerification` values are emitted or
  stubbed) gains the same leading parameter.

Update the DSL golden corpus (`cabal test keiro-dsl:tests` will show the diffs; review
each), and update the `jitsurei` demo's hand-owned hole modules to the new signatures
(hole modules are created-once, so this is a manual edit in `jitsurei/`; the replay hole
bodies change from interpolating the constant to interpolating
`<stem>QualifiedTableIn targets`).

Changelog obligations begin here: record the breaking `ReplayAdapter` /
`RebuildVerification` signature change in `keiro/CHANGELOG.md` (Unreleased, Breaking
Changes) and the generated-output change in `keiro-dsl/CHANGELOG.md`.

Acceptance: `cabal build all` clean; `cabal test keiro-test`,
`cabal test keiro-dsl:tests`, `cabal test jitsurei-test` green — in particular the whole
of `ProjectionReplaySpec` passes with only mechanical fixture edits (each fixture
`applyReplay` gains the argument and keeps writing the declared table), which is the
proof that offline behavior is unchanged.


### Milestone 4 — versioned replay with converging catch-up

Scope: protocol steps 1–2 wired through `Runner.hs`. At the end, a versioned rebuild
fills staging tables to a converging head while live traffic proceeds, is inspectable,
resumable, and abandonable; cutover does not exist yet (the drive loop parks the run
once converged if Milestone 5 is not yet merged — see the note at the end).

**`RebuildOptions`** (`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`) gains:

```haskell
data RebuildTargetMode = InPlaceRebuild | VersionedRebuild
  deriving stock (Eq, Show, Generic)

data RebuildOptions = RebuildOptions
  { rebuildRequest :: !RebuildRequest,
    replayPageSize :: !Int32,
    rebuildMetrics :: !(Maybe KeiroMetrics),
    targetMode :: !RebuildTargetMode,
    cutoverThreshold :: !Int64   -- global position distance; used by versioned mode only
  }
```

`defaultRebuildOptions` keeps `InPlaceRebuild` and a default threshold of 1000.

- `startCatalogRebuild` dispatches on `targetMode`. The versioned arm captures H0 with
  the existing `captureHead`, calls `beginVersionedGroupRebuild` (which persists
  everything in one transaction, including the run row with `target_mode = 'versioned'`
  — extend `insertRunStmt` or add a versioned variant, and load/store the staging map
  through `keiro_projection_rebuild_run_targets`), then enters the versioned drive loop.
- The versioned drive loop reuses `readSourcePage`, `orderedCandidates`,
  `duplicatePosition`, `advanceSourcePages`, and `applyChunkTx` unchanged except that
  chunk/verification liveness statements accept the group status expected for the mode
  (`rebuilding-versioned` during catch-up; parameterize `lockActiveRunStmt` and
  `resumeRunStmt` by an expected-status set rather than duplicating SQL). Adapters
  receive the staging `PhysicalTargets` loaded from the run-target rows.
- On all-sources-exhausted: capture a fresh head; if
  `distance(newHead, captured_head) > cutoverThreshold`, extend — one transaction
  updating `runs.captured_head` and every source row's `target_position` (clearing
  `exhausted_through`; the `0023.sql` CHECK constraints permit exactly this) — and
  continue; otherwise stop (Milestone 5 takes over here).
- `resumeCatalogRebuild` reads the run row, verifies the stored **contract-v4**
  fingerprint exactly as plan 247 left it, and dispatches on the persisted
  `target_mode`; a versioned run resumed by the versioned arm re-loads the staging map
  and continues from the persisted cursors. `RebuildRunReport` gains `targetMode`,
  the run-target rows (staging/retired names), and the current convergence distance;
  bump the operations envelope `reportSchema` to `keiro/catalog-rebuild-run/v2` in
  `keiro/src/Keiro/Projection/Catalog/Operations.hs`.
- `abandonCatalogRebuild` dispatches to `abandonVersionedGroupRebuild` for versioned
  runs.

**Tests** (extend `keiro/test/ProjectionReplaySpec.hs`): start a versioned rebuild on the
replay fixture catalog; while it drives, append further interleaved events and commit an
inline catalog command (proving writers are not fenced — the same command under an
offline rebuild of the same group is fenced); assert the staging tables converge to
contain every event across at least two catch-up rounds (force rounds by appending more
than the threshold between exhaustions); assert the live tables never lost or changed
rows during replay; interrupt (simulate by driving with a wrapper that stops after N
chunks, as the existing resume tests do) and resume, asserting the resume refuses under
a drifted catalog (contract-v4) and continues under the same catalog; abandon and assert
staging tables are gone and the group is `live`.

Acceptance: `cabal test keiro-test` green. If Milestone 5 is developed in the same
session, the "park when converged" state may be skipped and cutover entered directly;
if not, a converged run simply keeps extending rounds until abandoned — either is
acceptable at this milestone boundary, but say which in Progress.


### Milestone 5 — atomic cutover and the external-reader acceptance proof

Scope: protocol steps 3–5 and the IR-22 acceptance test. This is the deliverable the
MasterPlan exists for; do not trim its tests.

**Cutover entry.** In the versioned drive loop, when the post-exhaustion distance is
within `cutoverThreshold`: check the async precondition — via
`Kiroku.Store.Subscription.subscriptionCheckpointInventory`, every declared subscription
of the group has a durable checkpoint within `cutoverThreshold` of the head; if not,
keep extending rounds (the worker is live and catching up; log/record progress in the
run report rather than failing). Then run `enterCutoverTx`
(`rebuilding-versioned -> cutover`, one small transaction). From here writers are
fenced; every subsequent chunk/verification/proof statement expects `cutover`.

**Tail replay.** Capture Hf; extend the run target to Hf; drive the ordinary chunk loop
to exhaustion. Then compute the dedup backfill input *outside* the promote transaction:
for each async projection (from `catalogAsyncIdempotencyKeys`), page its source scope
over `(checkpoint, Hf]` and collect `(dedupName, eventId)` pairs — history at or below
Hf is immutable, so reading it outside the transaction is sound.

**Promote transaction** (one `runTransaction`, in this order):

1. `lockActiveRunStmt` variant for `cutover` (locks run and group rows `FOR UPDATE`).
2. `runVerificationsTx` with the staging `PhysicalTargets`.
3. `completionProofStmt` against Hf (reused verbatim except the group-status
   parameterization).
4. Dedup backfill inserts (`ON CONFLICT DO NOTHING` on
   `keiro.keiro_projection_dedup`).
5. `resetSubscriptionCheckpointsTx` to Hf for the group's declared subscriptions
   (missing members are a condemned typed failure, mirroring
   `RebuildSubscriptionCheckpointsMissing`).
6. `resyncOwnedSequencesTx` for each staging table.
7. `SET LOCAL lock_timeout = '5s'` (literal via `Tx.sql`); then for each target in
   declared order: rename live to its retired name, rename staging to the declared name
   (`renameSwapTx`); update the run-target row with the retired name.
8. For each externally readable binding on a swapped target (plan 255's surface, when
   present): `CREATE OR REPLACE VIEW keiro_read."target__<targetId>"` against the
   declared qualified name, so the view's OID binding follows the swap — PostgreSQL
   views keep pointing at the renamed (retired) table otherwise. This is the single
   mutation plan 255's "cutover indirection" contract reserves for this plan; guard,
   functions, and SQLSTATEs are untouched. Skip when the catalog declares no external
   readers.
9. `markVerifiedStmt`, `finishVersionedGroupRebuildTx` (group `cutover -> live`,
   queries' `last_built_at` stamped), `markPromotedStmt`.

A `lock_timeout` abort leaves the group fenced in `cutover` with all progress persisted;
`resumeCatalogRebuild` on the run re-enters at the tail-replay step idempotently (all
chunk work is cursor-guarded; verifications re-run; renames that already happened cannot
have happened, because the promote transaction is atomic). Telemetry: reuse the existing
rebuild counters; promotions increment `recordProjectionRebuildPromotions`.

**Acceptance tests** (new `keiro/test/VersionedCutoverSpec.hs` or a `describe` group in
`ProjectionReplaySpec`, DB-backed):

- **The IR-22 transcript test.** Arrange a catalog group with an inline projection and a
  query model over one `ClearBeforeReplay` table; seed history; register; run a
  *deliberately wrong* projection state (e.g., seed the live table with a manually
  corrupted row to make old and new versions distinguishable — this simulates the
  bugfix-rebuild motivation). Start a versioned rebuild on a background thread. On a
  **second connection** (open one via `withFreshDatabase`'s connection string — this is
  the out-of-process reader), poll in a loop through plan 255's sanctioned surface (use
  the surface exactly as 255's landed code installs it; if the group also permits it,
  poll a raw `SELECT` on the declared name as a second observer): every successful read
  during the rebuild returns exactly the pre-rebuild (corrupted) state; after promotion,
  reads return exactly the rebuilt state; no read ever returns an empty table, a
  partially replayed prefix, or an error other than a transient lock wait. Assert the
  final staging/retired bookkeeping rows. This test, plus its recorded transcript in
  Validation and Acceptance, is the IR-22 capability-3 acceptance.
- **Write-fence honesty.** Inline commands issued during `rebuilding-versioned` commit;
  a command issued during `cutover` returns the typed fenced outcome; after promotion,
  commands commit and their events flow into the *new* live table.
- **Async convergence.** A group with an async handler: run the worker loop
  (`applyAsyncProjectionFromCatalog`) concurrently during the rebuild; after promotion,
  deliver the pre-fence tail again (simulating redelivery) and assert the new table's
  rows are not double-applied (dedup backfill) and the checkpoint stands at Hf.
- **Crash-resume.** Force a `lock_timeout` abort of the promote transaction (hold an
  `ACCESS SHARE` lock from the reader connection past the timeout); assert the group is
  still `cutover` (fenced), then release and resume to completion.

Acceptance: `cabal test keiro-test` green, transcripts captured into this plan.


### Milestone 6 — drain, drop, and the operator surface

Scope: the retired-version lifecycle and keiro-ops, per ADR-28. At the end an operator
can drive the entire versioned lifecycle without hand-written SQL.

**Library** (`Group.hs` + `Operations.hs`):

- `listRetiredTargetVersions :: (Store :> es) => RebuildRunId -> Eff es [RetiredTarget]`
  and `dropRetiredTargetVersions :: (Store :> es) => RebuildRunId -> Eff es (Either
  RetiredDropError [RetiredTarget])` — drop each recorded retired table
  (`DROP TABLE IF EXISTS`), stamp `retired_dropped_at`, refuse if the run is not
  `promoted`. Database-only: no catalog required.
- `Operations.hs`: thread `targetMode`/`cutoverThreshold` through `startGroupRebuild`
  options (no signature change — they ride `RebuildOptions`); extend `RebuildPreview`
  with the mode-relevant facts (staging names are run-scoped, so the preview shows the
  eligibility verdict and `capturedHeadStrategy` text for versioned mode); add
  preview/drop wrappers for retired versions; bump affected `reportSchema` strings.

**keiro-ops** (`keiro-ops/src/Keiro/Ops/Rebuild.hs`):

- `rebuild start` gains `--versioned` and `--cutover-threshold N` (positive Int64;
  validated before database access per ADR-28). The non-forced preview renders the
  versioned eligibility verdict and the staging plan; the forced run drives to promotion.
- `rebuild status` renders `target_mode`, convergence distance, and staging/retired
  names (new columns in `runResult`).
- New `rebuild drop-retired RUN_ID`: without `--force`, renders the exact retired tables
  and the force invocation and exits unsuccessfully; with `--force`, calls
  `dropRetiredTargetVersions` and reports actual outcomes including idempotent no-ops.
  Mount it in both the embedded and standalone binaries (database-only).
- `isMutation` and rendering updated; JSON and table outputs stay alternative renderings
  of the same structured result.

Tests: extend the keiro-ops suite (`cabal test keiro-ops-test`) with parser round-trips,
preview-required behavior, and a drop-retired execution against the fixture; capture one
end-to-end CLI transcript (start --versioned preview, forced run, status, drop-retired
preview, forced drop) for this plan and the user guide.

Acceptance: `cabal test keiro-ops-test` and `cabal test keiro-test` green.


### Milestone 7 — ADRs, documentation, changelogs, full gate

Scope: durable memory and the gate.

- **New ADR** in `docs/adr/`: "Versioned rebuild targets are Keiro-created siblings
  promoted by rename" (title may be refined). Contents: the ownership boundary this
  revises (quote the runtime-patterns stance and IR-22's conditional ask, citing IR-22
  by its repository-relative path
  `docs/improvement-requests/make-read-models-safely-readable-by-out-of-process-consumers.md`
  and the cross-repository owner-per-table decision as
  `mori://shinzui/mori/okf/adrs/concepts/ADR-20`); what Keiro now creates, fills,
  swaps, drops (staging/retired siblings, their naming, their exclusion from
  application schema expectations); what remains application-owned (declared shape, DDL
  evolution, grants, FKs/triggers — and therefore the eligibility gate); the lifecycle
  states and fence semantics; the drain/drop policy; alternatives considered
  (registry-pointer flip — rejected on the baked-name analysis; dual-write — rejected as
  unverifiable inside opaque SQL). Allocate the handle with `okf id next`, keep
  `log.md` current via `okf log add`, and run the strict profile validation (Concrete
  Steps).
- **Amend `docs/adr/0032-...md`**: the persisted run format now carries `target_mode`
  and run-target rows; mode is dispatch state outside the contract preimage; the
  contract prefix remains plan 247's v4. Add a cross-reference from ADR-26's
  "online shadow-table cutover ... outside this decision" consequence to the new ADR.
- **User guide** `docs/user/read-models-and-projections.md`: a new section "Rebuild into
  a versioned target (online)" after "Replay A Catalog Group": when to choose it
  (bugfix/logic rebuilds of clear-before-replay groups), eligibility and its reasons,
  the lifecycle diagram in prose (`live -> rebuilding-versioned -> cutover -> live`),
  what external readers observe (with the plan-255 surface named explicitly), the honest
  costs (writer fence during cutover; rename lock blip; identity-sequence resync), the
  keiro-ops invocations with the Milestone 6 transcript, and drain/drop guidance. Also
  extend the status-relation contract documentation that plan 254 created (wherever it
  landed — likely `docs/user/operations.md` or a 254-created page) with the three
  additive columns.
- **Changelogs** (`Unreleased` sections): `keiro/CHANGELOG.md` (versioned rebuild
  protocol, new lifecycle statuses, breaking parametric replay/verification signatures,
  new APIs); `keiro-dsl/CHANGELOG.md` (generated hole/table-module changes);
  `keiro-ops/CHANGELOG.md` (`--versioned`, `--cutover-threshold`, `drop-retired`);
  `keiro-migrations/CHANGELOG.md` (migration NNNN, status-relation columns, snapshot).
- Update the MasterPlan registry row for this plan to Complete, and reflect milestone
  status in its Progress section (coordination edits to the MasterPlan's own file are in
  scope at completion time per the master-plan workflow).
- Run the full gate and fix fallout: `just verify` from the repo root (builds, all test
  suites, ADR validation, policy checks).

Acceptance: `just verify` green; ADR bundle validates strictly; all four changelogs
mention their changes; the plan's living sections are complete and an Outcomes &
Retrospective entry written; ADR distillation pass done.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

Build and targeted suites, in the order the milestones need them:

```bash
cabal build all
cabal test keiro-test               # keiro runtime suite (DB-backed via ephemeral-pg)
cabal test keiro-migrations-test    # migration lint, native lock, expected schema
cabal test keiro-dsl:tests          # ALL keiro-dsl suites (:tests, not the bare name)
cabal test jitsurei-test            # demo service (holes touched in M3)
cabal test keiro-ops-test           # operator CLI suite (M6)
```

A passing DB-backed suite prints hspec output ending like:

```text
Finished in 92.31 seconds
412 examples, 0 failures
```

The DB suites use the suite-level template-database fixture from
`keiro-test-support/src/Keiro/Test/Postgres.hs` (`withMigratedSuite` in
`keiro/test/Main.hs`); add new specs to that `Main.hs` and take the `Fixture` argument —
never run migrations per example. For a focused run while iterating:

```bash
cabal test keiro-test --test-options='--match "versioned"'
```

Expected-schema snapshot regeneration after the migration lands (then review the diff):

```bash
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test
git diff keiro-migrations/expected-schema/native/keiro-v18.txt
```

Native lock entry for the new migration (append in manifest order; the suite verifies):

```bash
shasum -a 256 keiro-migrations/migrations/NNNN.sql
```

ADR handle allocation and validation (profile-governed bundle):

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add docs/adr ...   # keep log.md current when timestamps advance
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Full gate at the end (and before declaring any milestone complete when in doubt):

```bash
just verify
```

Commit and trailer convention: use Conventional Commits (`feat(rebuild): ...`,
`test(rebuild): ...`, `feat(ops): ...`, `docs(adr): ...`, `feat(migrations): ...`), one
logical change per commit, committed at every green stopping point, each with the
trailers:

```text
MasterPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
ExecPlan: docs/plans/256-rebuild-into-versioned-targets-with-atomic-cutover.md
Intention: intention_01kzw6dkhje7qvw6w321pwyv12
```


## Validation and Acceptance

The change is accepted when the following behaviors are observable, not merely when code
compiles.

**IR-22 capability-3 acceptance (the headline).** The Milestone 5 test demonstrates,
against a real PostgreSQL: begin a versioned rebuild of a group containing a
`ClearBeforeReplay` target whose live table holds a distinguishable pre-rebuild state;
from a separate connection, poll the sanctioned read surface throughout; every read
succeeds; reads return the pre-rebuild state until the promotion commit and the rebuilt
state after it; no read observes an empty or partially replayed table. Capture the
test's output in this section when it passes, in this shape:

```text
versioned cutover
  serves external readers throughout a versioned rebuild
    reader observed 214 successful reads: 187 pre-rebuild, 27 post-promotion, 0 partial
```

**Fence honesty.** Tests show inline catalog commands committing during
`rebuilding-versioned`, fenced (typed outcome, event append rolled back) during
`cutover`, and committing into the new version after promotion. The offline in-place
rebuild's entire existing suite (`GroupRebuildSpec`, `ProjectionReplaySpec`,
`CatalogOperationsSpec`) passes unchanged apart from the mechanical
`PhysicalTargets` fixture edits — the proof that the default path did not move.

**Operator transcript.** From Milestone 6, a real CLI session (recorded here and in the
user guide) shows: non-forced `rebuild start GROUP --versioned ...` printing the
eligibility verdict, staging plan, and exact force invocation and exiting unsuccessfully;
the forced invocation driving to `promoted`; `rebuild status RUN` showing
`target_mode=versioned` and the retired names; `rebuild drop-retired RUN` previewing and
then, forced, reporting the dropped tables.

**Registry truth.** After promotion: the group row is `live` with no active run; the run
row is `promoted` with `target_mode='versioned'` and `captured_head=Hf`; every
run-target row carries live, staging, and retired names; the plan-254 relation shows the
additive columns as NULL when idle and populated during a run (SQL session transcript).

**Convergence bookkeeping.** During a forced multi-round test, the run report shows the
captured head advancing monotonically across rounds and the final promoted head equal to
the last fence-captured head.


## Idempotence and Recovery

Every step of the protocol is either one transaction or cursor-guarded, so re-running is
safe by construction; this section states the recovery story an operator (or the test
suite) relies on.

Begin-versioned is a single transaction: on any failure nothing exists — no staging
tables, no run rows, group still `live`. Re-invoking with the same run id after a
successful begin fails with `CatalogRebuildRunAlreadyExists` (existing semantics).

Catch-up replay is the existing chunk machinery: each chunk commits its writes and
cursors together and re-proves run/group liveness first; a crashed process resumes with
`keiro-ops rebuild resume RUN_ID --force` (contract-v4 check, mode dispatch) and repeats
no work. Extending the head is one transaction and idempotent to retry.

During `rebuilding-versioned`, nothing about the live tables changed, so abandoning at
any point (`keiro-ops rebuild abandon RUN_ID --code ... --detail ... --force`) drops the
staging tables and returns the group to `live` with zero data impact. This is the safe
bail-out at every stage before promotion; it is also the remediation if eligibility
probing later proves too permissive.

During `cutover`, writers are fenced and the group stays fenced across a crash — exactly
the conservative failure mode the offline protocol already has, but with the live tables
intact. Resume re-runs the tail replay and promotion; abandon returns to `live`. The
promote transaction is atomic: either every rename, checkpoint advance, dedup backfill,
and status flip committed, or none did. A `lock_timeout` abort (a long-running external
reader blocking the rename) is expected occasionally and is retried by resume; the
timeout also bounds how long the rename can head-of-line-block other readers in the lock
queue.

After promotion, the retired tables are frozen (no writer references them; the declared
name moved). `drop-retired` is the only destructive step in the whole protocol and is
two-phase, records `retired_dropped_at`, and uses `DROP TABLE IF EXISTS` so a partial
failure re-runs cleanly. Wait to drop until no transaction predating the cutover is
still running (the preview says so).

The migration is additive except for the two CHECK-constraint replacements, which are
instantaneous metadata swaps valid for all existing rows ('live'/'rebuilding'/'failed'
remain legal); it can be applied to a database with registered groups mid-flight only in
`live`/`rebuilding`/`failed` states, all untouched by it.


## Interfaces and Dependencies

Libraries and modules touched, and the shapes that must exist at the end of each
milestone (full module paths; signatures may be refined during implementation, with the
refinement recorded in the Decision Log):

- `keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs` (new, M1): `stagingTableName`,
  `retiredTableName`, `createStagingTableTx`, `probeVersionedEligibilityTx`,
  `VersionedIneligibility(..)`, `renameSwapTx`, `resyncOwnedSequencesTx`.
- `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` (M2, M5, M6):
  `GroupLifecycleStatus(GroupRebuildingVersioned, GroupCutover)`,
  `RebuildStartError(RebuildGroupVersionedIneligible)`, `beginVersionedGroupRebuild`,
  `abandonVersionedGroupRebuild`, `enterCutoverTx`, `finishVersionedGroupRebuildTx`,
  `lockProjectionGroupsTx` (versioned arm), retired listing/drop transactions.
- `keiro/src/Keiro/Projection/Catalog.hs` (M3): `PhysicalTargets`, `physicalTableFor`,
  `declaredPhysicalTargets`, parametric `ReplayAdapter`/`RebuildVerification`,
  `replayAdapterFromCodec`, `runCatalogReplayAdapter`, `catalogAsyncIdempotencyKeys`.
- `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` (M4, M5): `RebuildTargetMode`,
  extended `RebuildOptions` (`targetMode`, `cutoverThreshold`), mode-dispatched
  `startCatalogRebuild`/`resumeCatalogRebuild`/`abandonCatalogRebuild`, the versioned
  drive loop, head extension, cutover entry, tail replay, promote transaction; extended
  `RebuildRunReport`.
- `keiro/src/Keiro/ReadModel/Rebuild.hs` (facade): re-export the new public vocabulary.
- `keiro/src/Keiro/Projection/Catalog/Operations.hs` (M4, M6): report-schema bumps,
  preview extensions, retired-version operations.
- `keiro-ops/src/Keiro/Ops/Rebuild.hs` (M6): `--versioned`, `--cutover-threshold`,
  `drop-retired`, status rendering.
- `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (M3): `emitReadModelTable` resolver,
  parametric replay/verification holes; golden corpus under `keiro-dsl`'s tests;
  `jitsurei` hole modules.
- `keiro-migrations/migrations/NNNN.sql` + `manifest` + `migrations.native.lock` +
  `expected-schema/native/keiro-v18.txt` (M2); the plan-254 status relation view
  (additive columns).
- Kiroku (dependency, no changes expected): `Kiroku.Store.Subscription.Checkpoint.
  resetSubscriptionCheckpointsTx` (checkpoint advance), `Kiroku.Store.Subscription.
  subscriptionCheckpointInventory` (cutover precondition), `Kiroku.Store.Read` paging
  (tail reads). If any needed primitive turns out to be missing or non-transactional,
  ADR-28's rule applies — add it upstream in the owning library first — and that becomes
  a recorded blocker in Progress, not an inline SQL workaround. Locate kiroku sources
  with `mori registry show shinzui/kiroku --full` when needed.
- Test infrastructure: `keiro-test-support/src/Keiro/Test/Postgres.hs`
  (`withMigratedSuite`, `withFreshStore`, `withFreshDatabase` for second-connection
  readers) — suite-level template fixture only.

External plan dependencies restated: MasterPlan 39 plans 246 and 247 must be merged
before Milestone 4; MasterPlan 41 plans 254 and 255 must be merged before the Milestone
2 view amendment and the Milestone 5 acceptance test respectively. The plan-255
interface constraints this plan consumes (per-call name resolution; serving-status
vocabulary `live`/`rebuilding-versioned`/`cutover`) and the plan-254 additive-column
contract are stated in Context and must be re-verified against the landed code before
the corresponding milestones begin.
