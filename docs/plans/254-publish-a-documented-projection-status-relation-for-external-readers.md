---
id: 254
slug: publish-a-documented-projection-status-relation-for-external-readers
title: "Publish a documented projection status relation for external readers"
kind: exec-plan
created_at: 2026-08-12T23:55:46Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
master_plan: "docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md"
---

# Publish a documented projection status relation for external readers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, any process that can open a PostgreSQL connection — a TypeScript
render service, a monitoring agent, a `psql` session — can `SELECT` one documented,
compatibility-promised relation, `keiro.keiro_projection_group_status`, and learn for
every projection rebuild group: its stable identity, whether it is in live service
(`live`), mid-rebuild (`rebuilding`), or fenced after a failed rebuild (`failed`), the
global position its projections have durably applied, and which query models it backs.
The relation makes two behaviors implementable outside Haskell using its columns alone:
a "wait until the read model has applied position P" loop (the SQL equivalent of Keiro's
`WaitForPosition` query freshness), and position-regression detection (noticing that a
group's applied position moved backwards because a rebuild replayed history).

Today none of this is possible without reading Keiro's private bookkeeping tables
(`keiro.keiro_projection_rebuild_groups`, `keiro.keiro_read_models`,
`keiro.keiro_projection_rebuild_runs`), whose names, columns, and semantics carry no
compatibility promise and change between releases. This plan implements capability 2 of
`docs/improvement-requests/make-read-models-safely-readable-by-out-of-process-consumers.md`
(IR-22) as the first ExecPlan of
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`:
it defines the external vocabulary (group identity, live-service state, applied
position) that the sanctioned SQL read surface (plan 255) and the versioned-cutover
protocol (plan 256) will build on.

To see it working after implementation: run the Jitsurei rebuild rehearsal while a
second `psql` connection polls the relation, and watch the `jitsurei-order-reporting`
group report `live` with a real checkpoint position, leave live service (`rebuilding`,
with replay progress climbing toward the captured head), and return to `live` — with
the post-rebuild applied position honestly regressed to the replay start until the
async worker re-consumes.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: migration `0025-keiro-projection-group-status.sql` (cursor-binding table +
  status view + comments) written, manifest and `migrations.native.lock` updated.
- [ ] M1: `Keiro.Migrations.SchemaCheck` snapshot extended with the `view` object class
  (and view columns), body lint extended to `CREATE VIEW` targets, expected schema
  regenerated.
- [ ] M1: `keiro-migrations/test/Main.hs` counts updated (24 → 25 native files, 32 → 33
  plan migrations) and new SQL-level view-semantics examples pass;
  `cabal test keiro-migrations-test` green.
- [ ] M2: `registerProjectionCatalog` and `adoptCatalogGroups` reconcile
  `keiro.keiro_projection_group_cursors`; database tests prove idempotent reconcile.
- [ ] M3: `Keiro.ReadModel.Rebuild.Status` typed accessor added and re-exported through
  `Keiro.ReadModel.Rebuild`; `GroupStatusSpec` lifecycle proof (live → rebuilding →
  live with honest position regression) passes under `cabal test keiro-test`.
- [ ] M4: documentation section in `docs/user/read-models-and-projections.md`,
  `docs/user/migrations.md` object-class list updated, new ADR created and ADR-9 /
  ADR-26 amended with `okf` validation green, changelogs updated.
- [ ] M4: Jitsurei `psql` transcript captured and recorded in this plan.
- [ ] M5: `just verify` green; Outcomes, MasterPlan 41 registry status, and the ADR
  distillation pass completed.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship the relation as a `VIEW` over Keiro's private tables rather than a
  maintained table.
  Rationale: the private tables are already the single source of truth that
  preparation, promotion, abandonment, and registration write transactionally; a
  second table would need dual writes and could drift. A view also gives external
  readers a privilege boundary: granting `SELECT` on the view (plus `USAGE` on schema
  `keiro`) exposes none of the underlying private tables, because a plain view
  executes with its owner's privileges.
  Date: 2026-08-12
- Decision: The external contract is the view's **name and columns**, never its
  definition. A later keiro-migrations change may `CREATE OR REPLACE` the view body
  (for example to re-base the checkpoint join on a future Kiroku-published surface, or
  for plan 256 to add version columns) as long as existing columns keep their names,
  types, and documented meanings. Evolution is additive only: new columns, new
  `service_state` values, and new `position_basis` values may appear; nothing is
  renamed, retyped, or removed.
  Date: 2026-08-12
- Decision: One row per rebuild group (the IR's requested grain), with a sorted
  `query_models text[]` column so an external reader can find the group backing the
  model it reads (`WHERE 'name' = ANY (query_models)`) without a second relation.
  Rationale: per-query-model rows would drag the legacy `keiro_read_models` status
  vocabulary (`paused`, `abandoned`) into the external contract; plan 255's sanctioned
  read surface performs its per-binding liveness check transactionally against base
  tables and only needs to share this plan's *state vocabulary*, not its row grain.
  Date: 2026-08-12
- Decision: Expose `applied_position` with an explicit `position_basis` discriminator
  (`append`, `checkpoint`, `replay`, `unmanaged`) instead of pretending one number has
  one meaning. For subscription-fed groups the honest applied floor is the minimum
  member checkpoint of the group's bound durable subscriptions; for inline-only groups
  projections commit in the append transaction so no separate cursor exists (the
  column is NULL and the documented guarantee is transactional); during replay the
  honest number is rebuild-run progress, which deliberately regresses.
  Date: 2026-08-12
- Decision: The view's checkpoint branch reads `kiroku.subscriptions`
  (`subscription_name`, `last_seen`) directly, and a new Keiro-owned registration
  table `keiro.keiro_projection_group_cursors` records which subscription names belong
  to each group.
  Rationale: PositionWait-equivalence must be implementable "from these columns alone"
  (IR-22 acceptance), so the checkpoint floor must be *in* the relation; Kiroku
  publishes no SQL-level checkpoint contract today; mirroring checkpoints into a Keiro
  table would add a hot-path dual write that can drift from the authority. The keiro
  migration component already declares a hard dependency on the kiroku component, so
  the referenced objects exist before the view is created, and PostgreSQL dependency
  tracking makes any future incompatible Kiroku DDL change fail loudly at kiroku
  migration time rather than silently corrupting the view. This cross-schema read is a
  deliberate, ADR-recorded exception; a follow-up asks `mori://shinzui/kiroku` to
  publish a supported checkpoint relation the view can be re-based onto.
  Date: 2026-08-12
- Decision: A missing durable member row for any bound subscription makes
  `applied_position` NULL rather than reporting the minimum of the members that do
  exist.
  Rationale: a subscription whose consumer has never checkpointed has made no durable
  progress; reporting its siblings' positions would overstate the group floor.
  Date: 2026-08-12
- Decision: The cursor-binding table is derived registration metadata, exactly like
  `keiro_read_models` rows: it is reconciled (delete-then-insert per group) inside the
  existing registration and adoption transactions, and it participates in **no**
  fingerprint preimage. No `catalog-v3:`/`slice-v2:` prefix bump is needed under
  ADR-32 because canonical identity is unchanged; slice-v2 preimages already include
  resolved cursor identity.
  Date: 2026-08-12
- Decision: No `GRANT` ships in the migration. Role and grant management is
  deployment-owned (ADR-9 excludes roles/grants from the schema snapshot); the
  documentation states exactly which grants an operator gives an external reader role.
  Date: 2026-08-12
- Decision: Create a new ADR for the external status-relation contract instead of
  folding the whole decision into ADR-26, and additionally amend ADR-26 (one paragraph
  attaching the external-observer contract to the rebuild-group identity, as MasterPlan
  41 assigns) and ADR-9 (the expected-schema snapshot now covers views).
  Rationale: ADR-26 is a catalog-identity decision and already very large; the
  compatibility promise, position bases, cross-schema read, and grants stance are a
  distinct durable contract that plans 255 and 256 will cite on their own.
  Date: 2026-08-12
- Decision: No new `keiro-ops` command in this plan. The relation itself is the
  supported operator/reader surface (`psql` suffices), the library accessor provides
  Haskell parity, and `keiro-ops rebuild status` already reports run-grain facts. A
  DB-backed `rebuild groups` listing can wrap the new accessor later without contract
  changes.
  Date: 2026-08-12
- Decision: Do not expose `slice_fingerprint` (internal provenance) or Kiroku's
  authoritative append counter / visible store head in the relation. Positions in the
  relation are Kiroku `$all` global positions; readers who also want the store head for
  distance math use operator tooling (ADR-33's `keiro-ops` vocabulary). Embedding the
  visible-head query into a persisted Keiro object would duplicate dependency-owned SQL
  that ADR-33 deliberately kept in Kiroku. A later additive column can change this if
  Kiroku publishes a SQL-level head contract.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Repository root is `/Users/shinzui/Keikaku/bokuno/keiro`, a multi-package cabal
project. The packages this plan touches are `keiro` (the runtime library),
`keiro-migrations` (the owner of the `keiro` PostgreSQL schema), and the `jitsurei`
demo (acceptance evidence only). Kiroku is the PostgreSQL event store Keiro builds on;
its objects live in the `kiroku` schema of the same database and its migrations are a
separate `pg-migrate` component that the keiro component declares as a dependency
(`keiro-migrations/src/Keiro/Migrations.hs`, `frameworkMigrationPlan`), so kiroku
objects always exist before keiro migrations run.

### How group lifecycle state is persisted today

A *rebuild group* is the unit of atomic read-model lifecycle: the set of physical
target tables that leave service, reset, replay, verify, and return to service
together (`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`).
Its durable state lives in three Keiro-owned tables, created by
`keiro-migrations/migrations/0022.sql`, `0023.sql`, and `0024.sql`:

- `keiro.keiro_projection_rebuild_groups` — one row per group: `group_id` (text
  primary key), `slice_fingerprint` (canonical `slice-v2:` identity, or the sentinel
  `$legacy-unmanaged` for pre-catalog singleton groups), `status` with a CHECK
  constraint allowing exactly `'live'`, `'rebuilding'`, `'failed'`, `active_run_id`
  (NULL exactly when live), request attribution (`requested_by`, `request_reason`),
  and the timestamps `started_at`, `completed_at`, `failed_at` plus `failure_code` /
  `failure_detail`.
- `keiro.keiro_read_models` — one row per query-model binding (`name`, `version`,
  `shape_hash`, `status`, `rebuild_group_id` foreign key). Catalog transitions keep
  these rows in step with their group (`markGroupQueriesRebuildingStmt` and friends in
  `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`). The *legacy* single-model rebuild
  path (`startRebuild` in `keiro/src/Keiro/ReadModel/Rebuild.hs`) transitions only the
  model row and leaves its `$legacy-read-model:<name>` singleton group row `live` —
  the status relation must therefore consult both tables to be truthful.
- `keiro.keiro_projection_rebuild_runs` / `_sources` / `_adapters` /
  `_verifications` — per-rebuild-attempt progress written by the replay runner
  (`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`): the run's immutable
  `captured_head` (the inclusive replay target captured after fencing), and per-source
  `cursor_position` rows that advance with every committed replay chunk.

The lifecycle functions live in `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`:
`registerProjectionCatalog` persists group rows and query-model bindings in one
transaction at startup; `previewCatalogAdoption`/`adoptCatalogGroups` reconcile
reviewed metadata changes; `beginGroupRebuild` fences (status → `rebuilding`,
truncates `ClearBeforeReplay` targets, resets replayable async dedup and subscription
checkpoints); `finishGroupRebuildTx` promotes (status → `live`, stamps
`completed_at`); `abandonGroupRebuild` records failure (status → `failed`, keeps the
fence). Every one of these is a Haskell call boundary. An external SQL reader
participates in none of them and today can only infer state by reading the private
tables above, which may change shape in any release.

### What "applied global position" honestly means

Positions are Kiroku `$all` global positions (BIGINT). Per
`docs/adr/0033-consistency-waits-target-reachable-visible-heads.md`, honest position
vocabulary distinguishes the authoritative append counter from the newest *visible*
event, and per `docs/plans/244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md`
each waiting query model resolves exactly one *durable cursor authority* — a Kiroku
subscription name whose member checkpoints (`kiroku.subscriptions`: one row per
`(subscription_name, consumer_group_member)` with `last_seen`) record durable consumer
progress. Concretely, per group:

- A group whose owners all use **inline delivery** applies projections inside the
  event append transaction. There is no separate cursor; any event a reader's
  snapshot can see is already applied. The only honest "applied position" is the
  transactional guarantee itself.
- A group with **subscription delivery** owners has one or more durable Kiroku
  subscriptions. Its honest applied floor is the minimum `last_seen` across *all*
  member rows of *all* of its bound subscription names — Kiroku's checkpoint saves
  are monotonic (`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`), so this floor only
  regresses when Keiro's rebuild preparation explicitly resets checkpoints.
- A group that is **rebuilding** (or failed mid-rebuild) has honest progress in the
  active run's per-source `cursor_position` (minimum across sources), climbing toward
  the run's `captured_head`. This number deliberately sits below live values — that
  visible regression is exactly what an external reader needs to detect.

Nothing in Keiro's schema currently records *which* subscription names belong to a
group: `GroupPreparation.resetSubscriptionNames` is derived at call time from the
validated catalog (`preparationFor` joins `asyncProjectionRegistrations` — which maps
each async projection to its `subscriptionName` — with `replayAdapterMetadata` — which
maps every projection to its `rebuildGroupId`; both in
`keiro/src/Keiro/Projection/Catalog.hs`). A SQL view therefore cannot compute the
checkpoint floor today; this plan persists that binding at registration time.

### How operators see similar facts today

`keiro-ops/src/Keiro/Ops/Rebuild.hs` wraps `ProjectionCatalogOperations`
(`keiro/src/Keiro/Projection/Catalog/Operations.hs`): `rebuild list/preview/status`
render the mounted catalog's groups, registered slice matches, and run-grain progress
(captured head, source/adapter/verification counts). `keiro-ops projection position`
(`keiro-ops/src/Keiro/Ops/Projection.hs`) reports per-subscription member checkpoints,
the authoritative `store_position`, the reachable `visible_store_head`, and
`global_position_distance` per ADR-33. All of it requires the Haskell binary (and for
rebuild commands, the mounted application catalog). None of it is reachable from a
plain SQL connection, which is the whole point of IR-22 capability 2.

### The keiro-migrations delivery mechanism

Per `docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md`, Keiro's
own schema is migration-owned. A new native migration is a small, review-gated set of
edits: the SQL file under `keiro-migrations/migrations/` (the glob
`migrations/*.sql` in `keiro-migrations.cabal` already covers new files), one appended
line in `keiro-migrations/migrations/manifest` (order is authoritative), one appended
`sha256  filename` line in `keiro-migrations/migrations.native.lock` (plain SHA-256 of
the file bytes; verify with `shasum -a 256`), and regeneration of the expected live
schema snapshot `keiro-migrations/expected-schema/native/keiro-v18.txt` (the test
suite regenerates it under `KEIRO_REGENERATE_EXPECTED_SCHEMA=1`). The migration body
lint (`keiro-migrations/test/Lint.hs`) requires every DDL target to be qualified
`keiro.` and forbids `search_path` mentions. Crucially for this plan, the snapshot
query in `keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` covers only ordinary
tables (`relkind = 'r'`), so a view is currently invisible to
`keiro-migrate verify-schema`; ADR-9 explicitly says adding an object class requires
an explicit format and snapshot change, which milestone 1 performs. The frozen legacy
codd artifacts (`migrations.lock`, `sql-migrations/`, `expected-schema/v18/`) cover
only migrations 0001–0016 and are untouched.

### Coordination with sibling and external plans

MasterPlan 41 orders this plan (EP-1) first: plan 255 (the sanctioned SQL read
surface) consumes this plan's liveness vocabulary — the `service_state` values and
the rule that only `'live'` permits reads — while performing its own transactional
check against base tables; plan 256 (versioned targets with atomic cutover) will ADD
columns to this relation and may never rename or repurpose the ones defined here.
Externally, MasterPlan 39's EP-3/EP-4
(`docs/plans/248-give-pre-canonical-in-flight-rebuild-runs-a-supported-recovery-path.md`,
`docs/plans/249-make-catalog-adoption-scoped-truthful-and-registry-complete.md`)
finalize recovery and adoption lifecycle metadata; this plan is drafted against
current state, and if those plans land first (or concurrently) the implementer must
rebase the documented state vocabulary on whatever they persist — in particular, if
EP-3 introduces a new group status value, the documentation and the fail-safe rule
("anything other than `live` means do not read") already accommodate it additively.

Relevant ADRs, read during planning (repository-relative):
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
(the four catalog identities; the group is the durable lifecycle and fence; "Keiro may
own only its registry, fence, and rebuild-progress schema" — the cursor-binding table
is registry metadata),
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
(prefix-bump rules; this plan changes no canonical preimage, so no bump),
`docs/adr/0033-consistency-waits-target-reachable-visible-heads.md` (honest position
vocabulary; checkpoint monotonicity; Kiroku owns head SQL),
`docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md` (migration
mechanics and snapshot format), and
`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
(why no documented-raw-SQL operator remedy is added; the view itself is a supported
surface). Cross-repository: `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` (checkpoint
initialization and monotonic saves) and `mori://shinzui/mori/okf/adrs/concepts/ADR-20`
(one catalogued owner per live table — what makes an external status contract well
defined). The IR is `docs/improvement-requests/make-read-models-safely-readable-by-out-of-process-consumers.md`.


## Plan of Work

### Milestone 1 — The relation ships as migration 0025 with schema-gate coverage

Scope: everything in `keiro-migrations`. At the end of this milestone a freshly
migrated database contains the cursor-binding table and the status view, both covered
by the expected-schema gate, and SQL-level tests prove the view's semantics against
hand-inserted fixture rows — before any Haskell runtime code writes the new table.

Create `keiro-migrations/migrations/0025-keiro-projection-group-status.sql` with
exactly this content (adjust only if review demands):

```sql
-- keiro projection group status: cursor bindings and the external status relation.
--
-- keiro.keiro_projection_group_status is a SUPPORTED EXTERNAL CONTRACT: its name
-- and columns evolve additively only. The view definition itself is not the
-- contract and may be replaced. See docs/user/read-models-and-projections.md.

CREATE TABLE keiro.keiro_projection_group_cursors (
  group_id TEXT NOT NULL
    REFERENCES keiro.keiro_projection_rebuild_groups (group_id)
    ON DELETE CASCADE,
  subscription_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, subscription_name)
);

COMMENT ON TABLE keiro.keiro_projection_group_cursors IS
  'Keiro-private registration metadata: the durable Kiroku subscription names bound to each projection rebuild group. Not an external contract; read keiro.keiro_projection_group_status instead.';

CREATE VIEW keiro.keiro_projection_group_status AS
SELECT
  g.group_id,
  CASE
    WHEN g.status <> 'live' THEN g.status
    WHEN EXISTS (SELECT 1 FROM keiro.keiro_read_models m
                 WHERE m.rebuild_group_id = g.group_id AND m.status = 'rebuilding')
      THEN 'rebuilding'
    WHEN EXISTS (SELECT 1 FROM keiro.keiro_read_models m
                 WHERE m.rebuild_group_id = g.group_id AND m.status <> 'live')
      THEN 'failed'
    ELSE 'live'
  END AS service_state,
  g.active_run_id,
  CASE
    WHEN g.active_run_id IS NOT NULL THEN 'replay'
    WHEN g.slice_fingerprint = '$legacy-unmanaged' THEN 'unmanaged'
    WHEN EXISTS (SELECT 1 FROM keiro.keiro_projection_group_cursors c
                 WHERE c.group_id = g.group_id)
      THEN 'checkpoint'
    ELSE 'append'
  END AS position_basis,
  CASE
    WHEN g.active_run_id IS NOT NULL THEN
      (SELECT min(s.cursor_position)
       FROM keiro.keiro_projection_rebuild_sources s
       WHERE s.run_id = g.active_run_id)
    WHEN g.slice_fingerprint = '$legacy-unmanaged' THEN NULL
    WHEN EXISTS (SELECT 1
                 FROM keiro.keiro_projection_group_cursors c
                 WHERE c.group_id = g.group_id
                   AND NOT EXISTS (SELECT 1 FROM kiroku.subscriptions sub
                                   WHERE sub.subscription_name = c.subscription_name))
      THEN NULL
    ELSE
      (SELECT min(sub.last_seen)
       FROM keiro.keiro_projection_group_cursors c
       JOIN kiroku.subscriptions sub
         ON sub.subscription_name = c.subscription_name
       WHERE c.group_id = g.group_id)
  END AS applied_position,
  (SELECT r.captured_head
   FROM keiro.keiro_projection_rebuild_runs r
   WHERE r.run_id = g.active_run_id) AS replay_target_position,
  (SELECT COALESCE(array_agg(m.name ORDER BY m.name), '{}')
   FROM keiro.keiro_read_models m
   WHERE m.rebuild_group_id = g.group_id) AS query_models,
  g.started_at AS rebuild_started_at,
  g.completed_at AS last_promoted_at,
  g.failed_at,
  g.failure_code,
  g.failure_detail
FROM keiro.keiro_projection_rebuild_groups g;

COMMENT ON VIEW keiro.keiro_projection_group_status IS
  'Supported external contract (IR-22): per projection rebuild group identity, live-service state, and applied global position. Columns evolve additively only; read only when service_state = ''live''. See docs/user/read-models-and-projections.md.';
```

The semantics this encodes, spelled out so a reviewer can check the SQL against
intent: `service_state` is the group row's status except that a group-row-live group
whose bound query-model rows are not all `live` reports the fail-safe non-live value
(this is what makes legacy single-model rebuilds, which only transition
`keiro_read_models`, truthful); `position_basis` says how to interpret
`applied_position` — `replay` whenever a run is active (rebuilding or failed),
`unmanaged` for pre-catalog legacy singleton groups Keiro knows nothing about,
`checkpoint` for live groups with bound durable subscriptions, `append` for live
inline-only groups; `applied_position` is NULL for `append` (the guarantee is
transactional, not positional), NULL for `unmanaged`, NULL under `checkpoint` when any
bound subscription has no persisted member row (no durable progress may be
overstated), the member-checkpoint floor otherwise, and the run's minimum source
cursor under `replay` (NULL in the brief window after `beginGroupRebuild` and before
the runner initializes its run row, and for legacy-migrated `rebuilding` groups that
have no run row); `replay_target_position` is the active run's `captured_head` and is
non-NULL only when a run row exists.

Update `keiro-migrations/migrations/manifest`: append the new filename as the last
line. Append the lockfile line produced by:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
shasum -a 256 keiro-migrations/migrations/0025-keiro-projection-group-status.sql
```

to `keiro-migrations/migrations.native.lock` (same two-column format as the existing
lines, filename without directory prefix).

Extend `keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` so the snapshot covers
views: in `schemaSnapshotStatement`, change the column branch's filter from
`c.relkind = 'r'` to `c.relkind IN ('r', 'v')`, and add a new `UNION ALL` branch:

```sql
SELECT 'view' || E'\t' || c.relname || E'\t' || pg_get_viewdef(c.oid)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1
    AND c.relkind = 'v'
    AND configured.search_path = 'pg_catalog'
```

Update the module's header comment and the Haddock on `snapshotSchema` ("tables,
views, columns, constraints, and indexes"). Note `pg_get_viewdef` runs under the
locally pinned `pg_catalog` search path, so its rendering is role-independent for the
same reason ADR-9 pins `pg_get_expr`.

Extend the body lint (`keiro-migrations/test/Lint.hs`, `statementTarget`) to
recognize `create view` and `create or replace view` targets (same
qualified-`keiro.`-prefix rule as `create table`), and add a pure lint example in
`keiro-migrations/test/Main.hs` proving an unqualified `CREATE VIEW widgets AS ...`
is flagged. The new migration passes because its targets are `keiro.`-qualified and
the `kiroku.subscriptions` reference inside the body is not a DDL target.

Update the counted expectations in `keiro-migrations/test/Main.hs` — every one of
these is currently pinned and will fail loudly until adjusted, which is the point:
`nativeMigrationFiles` gains the new filename; "tracks twenty-four native files"
becomes twenty-five; `length keiroEntries` 24 → 25; every whole-plan count 32 → 33
(the fresh-database pending count, the `replicate 32 AlreadyApplied` rerun, the
verification `length applied`, and both concurrent-apply expectations); the
Keiro-tail handshake after applying only Kiroku expects 25 pending instead of 24;
the codd-import expectations' trailing `replicate 8 AppliedNow` become `replicate 9
AppliedNow` (two places) and `postCoddImportPendingIssues` gains
`("keiro", "0025-keiro-projection-group-status")`; the singleton-upgrade test's
`Prelude.drop 29 ... replicate 3 AppliedNow` becomes `replicate 4 AppliedNow`; the
lint example "passes all 24 embedded native bodies" becomes 25.

Add a new `describe "projection group status relation"` block to
`keiro-migrations/test/Main.hs` using `withMigratedDatabase` and raw SQL fixtures
(this suite's established pattern — see `replayProgressFixtureSql`), proving with
hand-inserted rows:

1. a live catalog-style group with cursor rows and two `kiroku.subscriptions` member
   rows (`last_seen` 50 and 60) reports `('live', 'checkpoint', 50)` and its sorted
   `query_models` array;
2. deleting all member rows of one bound subscription flips `applied_position` to
   NULL while `position_basis` stays `checkpoint`;
3. a group flipped to `rebuilding` with a run row (`captured_head` 200) and two
   source rows (`cursor_position` 40 and 70) reports
   `('rebuilding', 'replay', 40, 200)`;
4. the migrated legacy singletons from `legacyReadModelFixtureSql` (that fixture
   already exists for the 0022 upgrade test) report `unmanaged` basis with states
   `live` / `rebuilding` / `failed`, and a legacy-`live` group whose *model row* is
   flipped to `'rebuilding'` by hand reports `service_state = 'rebuilding'` even
   though its group row is live.

Acceptance for M1: `cabal test keiro-migrations-test` passes, including the
regenerated snapshot (regenerate intentionally with
`KEIRO_REGENERATE_EXPECTED_SCHEMA=1`, then review the diff: the new table's lines,
the view line, and the view's column lines are the only additions).

### Milestone 2 — Registration and adoption persist the group cursor bindings

Scope: `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` only, plus tests. At the end,
starting an application (catalog registration) or adopting reviewed catalog changes
leaves `keiro.keiro_projection_group_cursors` exactly matching the validated catalog.

Derive the bindings from the validated catalog with a private helper in `Group.hs`
(alongside `preparationFor`):

```haskell
-- | (group, durable subscription name) pairs for every async owner in the
-- catalog, deduplicated and sorted. Unlike preparation's reset list this is
-- not filtered to replayable projections: a live-only async owner still has a
-- durable cursor that measures the group's applied floor.
groupCursorBindings :: ValidatedProjectionCatalog -> [(RebuildGroupId, Text)]
```

implemented by joining `asyncProjectionRegistrations catalog` (projection →
`subscriptionName`) with `replayAdapterMetadata catalog` (projection →
`rebuildGroupId`; one entry per projection) on `projectionId`, then
`List.nub . List.sort`.

Add two prepared statements: `deleteGroupCursorsStmt :: Statement Text ()`
(`DELETE FROM keiro.keiro_projection_group_cursors WHERE group_id = $1`) and
`insertGroupCursorStmt :: Statement (Text, Text) ()` (plain insert; the reconcile
deletes first so no `ON CONFLICT` is needed). Reconcile in both write paths, inside
the existing transactions:

- `registerProjectionCatalogTx`: after `registerGroups` succeeds and before the query
  registrations, for every catalog group id delete its cursor rows and insert the
  current bindings. Registration runs at every application startup, so existing
  deployments acquire cursor rows on their first post-upgrade start without any slice
  change — record this as the upgrade property in the changelog.
- `adoptCatalogGroups` (`adoptTx`): after `adoptGroupSliceStmt`, reconcile the same
  way for exactly the requested groups.

`ON DELETE CASCADE` already covers `deleteOrphanLegacyGroupsStmt`. Do not touch
`beginGroupRebuild`/`finishGroupRebuildTx` — the bindings are registration metadata,
not lifecycle state. Do not add the bindings to any preimage in
`keiro/src/Keiro/Projection/Catalog/Preimage.hs` or `Catalog.hs`; assert in review
that no fingerprint test changes.

Tests: extend `keiro/test/GroupRebuildSpec.hs` (fixture pattern: `spec fixture`,
`around (withFreshStore fixture)`, reusing `CatalogSpec.validCatalog`, which declares
the async subscription `catalog-async-subscription`): after
`registerProjectionCatalog`, a direct SQL statement shows exactly the expected
`(group_id, subscription_name)` rows; re-registration is idempotent (same rows);
after `adoptCatalogGroups` on a catalog variant, rows match the new catalog.
Database-backed suites use the suite-level template-database fixture from
`keiro-test-support` (`withMigratedSuite` in `keiro/test/Main.hs`) — never
per-example migrations.

Acceptance for M2: `cabal test keiro-test` (optionally focused with
`--test-option=--match --test-option="catalog rebuild groups"`) passes with the new
examples.

### Milestone 3 — Typed accessor and the lifecycle proof

Scope: new module `keiro/src/Keiro/ReadModel/Rebuild/Status.hs` (add to
`keiro.cabal` beside `Keiro.ReadModel.Rebuild.Group`, with `{-# OPTIONS_HADDOCK
hide #-}` on the internal module and re-exports through the public facade
`keiro/src/Keiro/ReadModel/Rebuild.hs`), plus a new test module
`keiro/test/GroupStatusSpec.hs` registered in `keiro/test/Main.hs` and the test
stanza of `keiro.cabal`.

The accessor reads the view — parity by construction, one source of truth:

```haskell
data GroupPositionBasis
  = PositionFromAppend
  | PositionFromCheckpoint
  | PositionFromReplay
  | PositionUnmanaged
  | UnknownPositionBasis !Text

data ProjectionGroupStatus = ProjectionGroupStatus
  { rebuildGroupId :: !RebuildGroupId,
    serviceState :: !GroupLifecycleStatus,
    activeRunId :: !(Maybe RebuildRunId),
    positionBasis :: !GroupPositionBasis,
    appliedPosition :: !(Maybe GlobalPosition),
    replayTargetPosition :: !(Maybe GlobalPosition),
    queryModels :: ![Text],
    rebuildStartedAt :: !(Maybe UTCTime),
    lastPromotedAt :: !(Maybe UTCTime),
    failedAt :: !(Maybe UTCTime),
    failureCode :: !(Maybe Text),
    failureDetail :: !(Maybe Text)
  }

listProjectionGroupStatuses ::
  (Store :> es) => Eff es [ProjectionGroupStatus]
lookupProjectionGroupStatus ::
  (Store :> es) => RebuildGroupId -> Eff es (Maybe ProjectionGroupStatus)
```

Both are single `SELECT ... FROM keiro.keiro_projection_group_status` statements
(ordered by `group_id`; the lookup adds `WHERE group_id = $1`), reusing the existing
`GroupLifecycleStatus` decode (`groupStatusFromText` with its `UnknownGroupStatus`
fallback) so a future additive state value decodes without crashing; decode
`position_basis` the same way with `UnknownPositionBasis`. `query_models` decodes with
`D.listArray`.

`GroupStatusSpec` proves the lifecycle end to end against a real store (follow
`GroupRebuildSpec`'s store setup, event appends, and its existing SQL fixture that
seeds `kiroku.subscriptions` member rows):

1. Register `CatalogSpec.validCatalog`; seed the two member checkpoints (50, 60);
   `lookupProjectionGroupStatus` reports `GroupLive`, `PositionFromCheckpoint`,
   applied `Just 50`, the sorted query-model names, `Nothing` run.
2. Delete the member rows; applied becomes `Nothing` (missing-member honesty).
3. Re-seed members, append events, then `beginGroupRebuild` — status
   `GroupRebuilding`, basis `PositionFromReplay`, applied `Nothing` (no run row yet),
   `activeRunId` set. Drive a full rebuild with `startCatalogRebuild` (fresh run id;
   see `ProjectionReplaySpec` for the drive pattern) and observe after promotion:
   `GroupLive` again, `lastPromotedAt` set, and applied regressed to `Just 0` because
   preparation reset the checkpoints to the replay start — the exact
   position-regression signal IR-22 wants external readers to be able to detect.
4. An unregistered group id returns `Nothing`; a `$legacy-read-model:` singleton
   (insert the legacy fixture rows by SQL) reports `PositionUnmanaged`.

Also assert (SQL, not accessor) that a mid-replay run reports
`applied_position = min(cursor_position)` and `replay_target_position =
captured_head` — either by pausing between chunks (insert the run/source rows by SQL
as in the migrations suite if driving a half-finished real replay is awkward) or by
reusing M1's fixture shape; the Haskell-level proof only needs decode coverage, since
M1 already proved the SQL semantics.

Acceptance for M3: `cabal test keiro-test` passes with the new spec; `cabal build
all` shows no new warnings (the repository builds with warnings promoted in CI).

### Milestone 4 — Documentation, ADRs, changelogs, and the psql transcript

Documentation. Add a section "Observe Projection Status From Outside The Process" to
`docs/user/read-models-and-projections.md` (place it after "Inspect And Operate A
Catalog"). It must state, in this order: that `keiro.keiro_projection_group_status`
is the one relation external (non-Haskell) readers may depend on; every column with
its exact meaning (as specified in M1, including every `position_basis` value and
every documented NULL); the state vocabulary `live` / `rebuilding` / `failed` with
the fail-safe rule that a reader must treat *any* value other than `live` —
including values added in future releases — as "do not read"; the compatibility
promise (columns are never renamed, retyped, or removed; columns, `service_state`
values, and `position_basis` values may be *added*; the view definition is not the
contract); the PositionWait-equivalent recipe and the regression-detection recipe
(both shown as SQL below, to be included in the docs); the grants an operator gives a
reader role (`GRANT USAGE ON SCHEMA keiro TO reader; GRANT SELECT ON
keiro.keiro_projection_group_status TO reader;` — and explicitly that this exposes no
base table); and one sentence that the in-process fence does not protect
out-of-process readers of the *target tables themselves*, with the sanctioned
per-query read surface arriving via plan 255 (which owns the full hazard
documentation — keep this plan's paragraph to the relation, so the two plans do not
fight over one section).

```sql
-- PositionWait-equivalent: wait until group 'reporting' has applied position P.
-- basis 'append' + state 'live' needs no wait: inline projections commit with
-- the event append itself.
SELECT service_state = 'live'
       AND (position_basis = 'append' OR applied_position >= :target)
FROM keiro.keiro_projection_group_status
WHERE group_id = 'reporting';
-- Poll until true; treat a missing row, a non-live state, or basis 'unmanaged'
-- as "not satisfied".

-- Position-regression detection: remember the last observed applied_position;
-- a later smaller value (or a transition away from 'live') means history was
-- replayed and any cached derived state must be invalidated.
```

Update `docs/user/migrations.md` line ~53 so the `verify-schema` object-class list
reads "tables, views, columns, constraints, and indexes".

ADRs (follow `agents/skills/exec-plan/ADR.md`; `docs/adr` is a profile-governed OKF
bundle). Allocate the next handle — do not guess:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
```

Create the new ADR (allocate with `okf id next` at landing time — plans 255 and 256
also allocate new ADRs, so do not assume a number; title along the lines of "External readers
observe projection groups through a documented status relation") recording: the
relation name and column contract with additive-only evolution; the position-basis
vocabulary and its honest NULLs; the decision that the columns, not the definition,
are the contract; the deliberate `kiroku.subscriptions` read with its justification
and consequences (PostgreSQL dependency tracking turns incompatible Kiroku DDL into a
loud kiroku-migration failure; a Kiroku-published checkpoint relation is the intended
future re-base, recorded as a follow-up for `mori://shinzui/kiroku`); the
no-grants-in-migrations stance; and the rejected alternatives (maintained status
table with dual writes; per-query-model row grain; exposing the visible store head).
Amend `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
with one paragraph in its Decision (or Consequences) section: the rebuild group's
registration metadata now includes its durable cursor bindings, and the group
identity carries a documented external-observer contract, delegating details to the
new ADR. Amend `docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md`
so the snapshot format sentence includes views. For every ADR whose `timestamp`
advances, run `okf log add`, then validate:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Changelogs. `keiro/CHANGELOG.md` under `## Unreleased` / `### Added`:
`ProjectionGroupStatus`, `GroupPositionBasis`, `listProjectionGroupStatuses`,
`lookupProjectionGroupStatus`; catalog registration and adoption now persist
per-group durable-cursor bindings (`keiro.keiro_projection_group_cursors`) and
therefore require keiro-migrations migration 0025 (the startup handshake reports the
pending migration first, so an un-migrated database fails loudly, not mysteriously).
`keiro-migrations/CHANGELOG.md` under `## Unreleased` / `### Added`: migration
`0025-keiro-projection-group-status.sql` (cursor-binding table plus the documented
external status view), and the expected-schema/verify-schema format now covering
views.

The psql transcript (acceptance evidence; capture the real output into this plan's
Outcomes section). Prerequisites: local PostgreSQL and the Jitsurei demo database
(`just postgres-start`, then the setup steps of
`docs/guides/run-and-operate-jitsurei.md`, which registers `jitsureiProjectionCatalog`
and, on this branch, populates the cursor bindings). All commands from the repository
root; `PGHOST=db` matches the justfile's socket directory. Use a fresh `--run-id`
each rehearsal (run ids are durable rows).

```bash
# 1. Before: the group is live with a real checkpoint floor.
PGHOST=db psql -d jitsurei -x -c "
  SELECT group_id, service_state, position_basis, applied_position,
         replay_target_position, active_run_id, query_models
  FROM keiro.keiro_projection_group_status
  WHERE group_id = 'jitsurei-order-reporting'"

# 2. During: poll from a second connection while the rebuild runs.
( for i in {1..400}; do
    PGHOST=db psql -d jitsurei -At -c "
      SELECT service_state || ' ' || position_basis || ' '
             || coalesce(applied_position::text, '-') || '/'
             || coalesce(replay_target_position::text, '-')
      FROM keiro.keiro_projection_group_status
      WHERE group_id = 'jitsurei-order-reporting'"
  done | uniq ) &
cabal run jitsurei-demo -- ops rebuild start jitsurei-order-reporting \
  --run-id status-rehearsal-1 --requested-by "$USER" \
  --reason "status relation rehearsal" --page-size 1 --force
wait

# 3. After: live again, last_promoted_at stamped, applied position honestly
#    regressed to the replay start until the async worker re-consumes.
PGHOST=db psql -d jitsurei -x -c "
  SELECT group_id, service_state, position_basis, applied_position,
         last_promoted_at
  FROM keiro.keiro_projection_group_status
  WHERE group_id = 'jitsurei-order-reporting'"
```

Expected poll output (deduplicated), proving the group left and re-entered live
service with positions:

```text
live checkpoint <N>/-
rebuilding replay <k>/<H>
live checkpoint 0/-
```

with `<k>` climbing toward the captured head `<H>` across samples. `--page-size 1`
widens the window; if the demo history is too short to catch a `rebuilding` sample,
run the demo again first to append more events and repeat with a new run id. This
rehearsal is safe for the persistent Jitsurei database — it is the same rebuild the
guide rehearses, and the deterministic mid-rebuild proof already lives in the M1/M3
tests; the transcript is corroborating end-to-end evidence, not the only proof.

### Milestone 5 — Full verification and closeout

Run the full gate and record real output in this plan: `just verify` (builds
everything, runs `keiro-test`, `keiro-pgmq-test`, `keiro-ops-test`,
`keiro-dsl:tests`, `jitsurei-test`, ADR/research/capability validation, policy
checks, and `cabal test keiro-migrations-test`). Note: like plan 244's closeout, the
persistent Jitsurei database may need its catalog re-registered on first run after
the upgrade; the startup handshake will name migration 0025 if `keiro-migrate up` has
not been run — apply it with `cabal run keiro-migrate -- up` against the demo
database (`DATABASE_URL` or connection options per `keiro-migrations/README.md`).
Update MasterPlan 41's Exec-Plan Registry row for this plan to Complete and its
Progress section; write this plan's Outcomes & Retrospective; perform the ADR
distillation pass (the new ADR and the two amendments should already carry the
durable context; distill anything additional the Decision Log accumulated).


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
# M1 — migration, snapshot format, lockfile, tests
shasum -a 256 keiro-migrations/migrations/0025-keiro-projection-group-status.sql
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test \
  --test-options='--match "checked-in snapshot"'
git diff keiro-migrations/expected-schema/native/keiro-v18.txt   # review additions only
cabal test keiro-migrations-test

# M2/M3 — runtime changes and database-backed proofs
cabal build all
cabal test keiro-test --test-option=--match --test-option="catalog rebuild groups"
cabal test keiro-test --test-option=--match --test-option="projection group status"
cabal test keiro-test

# M4 — ADR bundle discipline
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce

# M4 — transcript prerequisites
just postgres-start
cabal run keiro-migrate -- up        # against the jitsurei database if pending
# then the three transcript blocks from Milestone 4

# M5 — full gate
just verify
```

Expected shapes: the M1 suite reports the new example group "projection group status
relation" passing and the adjusted counts (25 native files, 33 plan migrations); the
M3 focused run reports the lifecycle examples passing, including the assertion that
`appliedPosition` regressed from `Just 50` to `Just 0` across a completed rebuild;
`just verify` ends with every suite green.


## Validation and Acceptance

Acceptance is observable behavior, in three layers:

1. SQL semantics (no Haskell involved): after `cabal test keiro-migrations-test`, the
   fixture examples prove each documented row shape — `('live', 'checkpoint', 50)`
   with the member floor, NULL applied position when a bound subscription has no
   member row, `('rebuilding', 'replay', 40, 200)` with run progress and captured
   head, legacy singletons as `unmanaged`, and the fail-safe conjunction when a model
   row is non-live under a live group row. `keiro-migrate verify-schema` against a
   freshly migrated database reports no drift, and hand-dropping the view produces a
   named `missing view` drift line (covered by the extended snapshot format).
2. Runtime lifecycle (Haskell accessor over a real store): the `GroupStatusSpec`
   examples listed in Milestone 3, failing before the milestone's code exists and
   passing after, including the honest post-promotion regression to the replay start.
3. End to end (a genuinely out-of-process reader): the Milestone 4 psql transcript —
   a second connection watches `jitsurei-order-reporting` leave live service, replay
   with climbing positions, and return to live — recorded verbatim in this plan.

The IR-22 capability-2 acceptance sentence is satisfied when an external consumer
can, using only documented columns: distinguish "rebuilding/failed" from "no rows
matched"; implement the PositionWait recipe; and detect position regression across a
rebuild. The documentation section is part of acceptance: the contract is not
delivered until `docs/user/read-models-and-projections.md` names the relation, every
column, and the compatibility promise.


## Idempotence and Recovery

Every step is safe to repeat. The migration runs once under pg-migrate's ledger and
advisory lock; re-running `keiro-migrate up` reports `AlreadyApplied`. Never edit
`0025-keiro-projection-group-status.sql` after it ships — schema corrections are new
forward migrations (`keiro-migrations/README.md`). The cursor-binding reconcile is
delete-then-insert inside the registration/adoption transactions, so re-registration
is idempotent and a failed transaction leaves prior rows intact. The expected-schema
snapshot regeneration is deliberate and reviewed (`KEIRO_REGENERATE_EXPECTED_SCHEMA=1`
plus `git diff`); if a regeneration captures unintended lines, discard with
`git checkout -- keiro-migrations/expected-schema/native/keiro-v18.txt` and re-run.
The Jitsurei rehearsal uses the same supported rebuild the guide rehearses; if a
rehearsal run fails mid-replay the run stays resumable
(`cabal run jitsurei-demo -- ops rebuild resume <run-id> --force`); use `rebuild
abandon` only if the run is truly unrecoverable, and prefer completing it — an
abandoned group stays fenced by design. Test databases are ephemeral
(`ephemeral-pg` template fixtures) and rebuilt per run.


## Interfaces and Dependencies

New database objects (keiro-migrations, migration 0025): table
`keiro.keiro_projection_group_cursors (group_id, subscription_name, created_at)` with
PK `(group_id, subscription_name)` and FK to `keiro_projection_rebuild_groups` ON
DELETE CASCADE; view `keiro.keiro_projection_group_status` with columns exactly
`group_id text`, `service_state text`, `active_run_id text`, `position_basis text`,
`applied_position bigint`, `replay_target_position bigint`, `query_models text[]`,
`rebuild_started_at timestamptz`, `last_promoted_at timestamptz`,
`failed_at timestamptz`, `failure_code text`, `failure_detail text`. These column
names are frozen the moment this plan's documentation lands; plan 256 adds columns,
never changes these.

Haskell surface at the end of M3, exported from `Keiro.ReadModel.Rebuild`
(implemented in the new hidden module `Keiro.ReadModel.Rebuild.Status`):
`ProjectionGroupStatus (..)`, `GroupPositionBasis (..)`,
`listProjectionGroupStatuses :: (Store :> es) => Eff es [ProjectionGroupStatus]`,
`lookupProjectionGroupStatus :: (Store :> es) => RebuildGroupId -> Eff es (Maybe
ProjectionGroupStatus)`. Internal additions to `Keiro.ReadModel.Rebuild.Group`:
`groupCursorBindings` plus the two reconcile statements, wired into
`registerProjectionCatalogTx` and `adoptCatalogGroups`. No `keiro-dsl`, `keiro-ops`,
or `keiro-pgmq` API changes; no fingerprint format changes.

Dependencies: `hasql`/`hasql-transaction` statement patterns as used throughout
`Group.hs` (use `D.listArray` for `text[]`); `keiro-test-support`'s
`withMigratedSuite`/`withFreshStore` fixtures for database tests;
`Database.PostgreSQL.Migrate.Test.withMigratedDatabase` in the migrations suite.
Kiroku APIs are unchanged — the only new Kiroku touchpoint is the view's SQL read of
`kiroku.subscriptions (subscription_name, last_seen)`, recorded in the new ADR with
the follow-up for `mori://shinzui/kiroku`. If MasterPlan 39's EP-3/EP-4
(`docs/plans/248-...md`, `docs/plans/249-...md`) land while this plan is in flight,
rebase the documented lifecycle vocabulary on their persisted states before freezing
the documentation; the fail-safe reader rule already tolerates additive state values.


## Commit and Trailer Convention

Use Conventional Commits (`feat(read-model): ...`, `feat(migrations): ...`,
`docs(user): ...`, `test(...): ...`) and include on every commit for this plan the
trailers:

```text
MasterPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
ExecPlan: docs/plans/254-publish-a-documented-projection-status-relation-for-external-readers.md
Intention: intention_01kzw6dkhje7qvw6w321pwyv12
```
