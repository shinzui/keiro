---
id: 47
slug: key-workflow-step-index-and-discovery-on-workflow-id-and-name
title: "Key workflow step index and discovery on workflow id and name"
kind: exec-plan
created_at: 2026-06-03T21:22:04Z
intention: "intention_01kt7npxxbedqt8e0ba4dmyxzb"
---

# Key workflow step index and discovery on workflow id and name

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A durable workflow in Keiro is identified by a pair: a stable *workflow name* (the
definition, e.g. `order-fulfillment`) and a *workflow id* (the instance, e.g. an
order id). Its journal is a kiroku stream named `wf:<name>-<id>`, and a derived
lookup table, `keiro_workflow_steps`, indexes the steps it has completed so the
runtime can short-circuit replays and a resume worker can discover unfinished
workflows.

Today that index is keyed by `(workflow_id, step_name)` **only — it ignores the
workflow name.** So are the runtime's existence checks (`stepExists`) and the
resume worker's unfinished-workflow discovery (`findUnfinishedWorkflowIds`), whose
"is there a terminal marker?" subquery matches on `workflow_id` alone. The
consequence is a sharp, silent footgun: if a parent workflow and a child workflow
(or any two workflows) share a workflow id under different names, they collide in
the index. A completed child writes a `__workflow_completed__` row for that id, and
because discovery groups by id alone, the still-unfinished parent is treated as
finished and silently dropped from resume discovery — it never reaches its own
`WorkflowCompleted`. Worse, at the storage level the shared
`(workflow_id, '__workflow_completed__')` primary key means one workflow's terminal
row blocks the other's (`ON CONFLICT DO NOTHING`).

This was discovered while building the v2 worked example (MasterPlan 5 /
`docs/plans/45-durable-workflow-worked-example-and-guide.md`, Surprises 2026-06-03):
the demo's parent and child initially shared the order id, the parent never
completed, and the fix there was a *documentation workaround* — "give the child a
distinct id." That workaround is easy to forget and the failure is silent.

**What someone gains after this change:** the workflow runtime keys its step index,
its existence checks, and its unfinished-workflow discovery on the full
`(workflow_id, workflow_name)` pair. Two workflows that happen to share an id under
different names are then fully independent — each accumulates its own steps, each
reaches its own terminal marker, and discovery resumes each correctly. The
"distinct ids" workaround becomes unnecessary, and a whole class of silent
parent/child corruption is eliminated.

**How you can see it working:** a new test runs a parent workflow and a child
workflow that *deliberately share a workflow id* under different names, drives both
through the resume worker, and asserts each independently reaches `Completed` with
its own `WorkflowCompleted` journal marker — and that `findUnfinishedWorkflowIds`
reports the parent as unfinished while only the child has completed, then reports
neither once both have. On the pre-change tree this test fails (the parent is
masked); after, it passes.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: add a migration that re-keys `keiro_workflow_steps` on
  `(workflow_id, workflow_name, step_name)` and widens the lookup index to
  `(workflow_id, workflow_name)`.
- [ ] Milestone 1: confirm `cabal test keiro-migrations-test` (fresh apply) green.
- [ ] Milestone 2: update `Keiro.Workflow.Schema` — `recordStepStmt` ON CONFLICT,
  `stepExists`/`loadStepIndex` to take the workflow name, and
  `findUnfinishedWorkflowIdsStmt`'s terminal-marker subquery to match name too;
  thread the name through the three `stepExists` call sites in `Keiro.Workflow`.
- [ ] Milestone 2: `cabal build keiro` green; update any test/call sites that pass
  the old `stepExists`/`loadStepIndex` signatures.
- [ ] Milestone 3: add the shared-id parent/child regression test to
  `keiro/test/Main.hs`; prove it fails before and passes after.
- [ ] Milestone 4: full green — `cabal build all`, `cabal test keiro`,
  `cabal test jitsurei-test` — and refresh the EP-45/MasterPlan notes so the
  "distinct ids" guidance is downgraded from "required" to "recommended".


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Fix the footgun at the root (key the index, existence checks, and
  discovery on `(workflow_id, workflow_name)`) rather than only documenting "use
  distinct ids".
  Rationale: The failure is silent and data-corrupting (a masked parent never
  completes), and the constraint "workflow ids must be globally unique across all
  workflow names" is non-obvious and unenforced. Keying on the full identity pair —
  which the journal stream name `wf:<name>-<id>` already does — makes the storage
  layer agree with the stream layer and removes the footgun entirely. The
  documentation workaround in EP-45 stays as a *recommendation* (distinct ids are
  still tidy) but is no longer load-bearing.
  Date: 2026-06-03.

- Decision: Change the primary key of `keiro_workflow_steps` from `(workflow_id,
  step_name)` to `(workflow_id, workflow_name, step_name)` via a new forward
  migration, not by editing the original create migration.
  Rationale: codd applies migrations forward and records them by filename; the
  create migration may already be applied in deployments, so the key change is a new
  timestamped migration. Adding `workflow_name` to the key is a strict relaxation
  (the old key already guaranteed uniqueness on the narrower pair), so no existing
  row can violate the new key — the migration is safe on populated tables.
  Date: 2026-06-03.

- Decision: Give `stepExists` and `loadStepIndex` an explicit `WorkflowName`
  parameter (importing `WorkflowName` from the leaf module `Keiro.Workflow.Types`)
  rather than packing identity into a tuple or a new type.
  Rationale: `Keiro.Workflow.Schema` already imports `Keiro.Workflow.Types
  (WorkflowId (..))`; `WorkflowName` lives in the same leaf module, so importing it
  introduces no cycle. An explicit `WorkflowName -> WorkflowId -> Text` parameter
  list reads clearly at the three call sites in `Keiro.Workflow`, all of which
  already hold the workflow name.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this fully before editing; it assumes no prior knowledge of the repository.

**The repository.** Keiro is a Haskell event-sourcing framework using the
`effectful` effect system. The durable-workflow runtime is the `Keiro.Workflow`
module family in the `keiro` Cabal package; its tables are created by SQL
migrations in `keiro-migrations/sql-migrations/`. All Cabal commands run from the
repository root `/Users/shinzui/Keikaku/bokuno/keiro`. The workflow tables live in
the PostgreSQL schema named `kiroku` (the runtime connects with `search_path =
kiroku`); a related fix,
`docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md`,
makes every migration self-set that search_path — the new migration in this plan
must follow that same convention (begin with `SET search_path TO kiroku,
pg_catalog;`).

**The step index.** `keiro_workflow_steps` is a derived lookup table (the journal
stream `wf:<name>-<id>` is the source of truth for replay). Its current definition,
in `keiro-migrations/sql-migrations/2026-06-03-00-00-00-keiro-workflow-steps.sql`:

```sql
CREATE TABLE IF NOT EXISTS keiro_workflow_steps (
  workflow_id    text        NOT NULL,
  workflow_name  text        NOT NULL,
  step_name      text        NOT NULL,
  result         jsonb       NOT NULL,
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workflow_id, step_name)
);

CREATE INDEX IF NOT EXISTS keiro_workflow_steps_workflow_idx
  ON keiro_workflow_steps (workflow_id);
```

The row already carries `workflow_name`, but it is not part of the key, and the
index is on `workflow_id` alone.

**The Haskell that uses it** is `keiro/src/Keiro/Workflow/Schema.hs`:

- `recordStepStmt` is an `INSERT ... ON CONFLICT (workflow_id, step_name) DO
  NOTHING` — so a second workflow with the same id and a colliding step name (most
  importantly the reserved terminal markers `__workflow_completed__` /
  `__workflow_cancelled__`) is silently swallowed.
- `stepExists :: (Store :> es) => WorkflowId -> Text -> Eff es Bool` runs
  `SELECT EXISTS (... WHERE workflow_id = $1 AND step_name = $2)` — name-blind.
- `loadStepIndex :: (Store :> es) => WorkflowId -> Eff es (Map Text Value)` selects
  `WHERE workflow_id = $1` — name-blind. (Exposed for the resume worker; verify its
  call sites before changing the signature — `grep -rn loadStepIndex keiro`.)
- `findUnfinishedWorkflowIdsStmt` returns `(workflow_id, workflow_name)` for every
  workflow that has at least one step row but **no** terminal-marker row, where the
  `NOT EXISTS` subquery matches only `c.workflow_id = s.workflow_id`:

  ```sql
  SELECT DISTINCT s.workflow_id, s.workflow_name
  FROM keiro_workflow_steps s
  WHERE NOT EXISTS (
    SELECT 1 FROM keiro_workflow_steps c
    WHERE c.workflow_id = s.workflow_id
      AND c.step_name IN ('__workflow_completed__', '__workflow_cancelled__')
  )
  ```

  Because the subquery ignores `workflow_name`, a completed workflow's terminal row
  satisfies the `NOT EXISTS` for *every* workflow sharing its id, masking the others.

**The call sites in `keiro/src/Keiro/Workflow.hs`** that hold the workflow name and
must thread it into the (newly name-aware) `stepExists`:

- `runWorkflowWith` cancellation short-circuit: `cancelled <- stepExists wid
  cancelledStepName` (the function has `name` in scope).
- `appendJournalEntryReturningId`: `exists <- stepExists wid key` (has `name`).
- `appendCompletion`: `exists <- stepExists wid key` (has `name`).

`recordStep` already builds a `WorkflowStepRow` carrying `workflowName`, so
`recordStepTx` needs no new argument — only the `ON CONFLICT` target column list
changes in SQL.

**The reserved step names** are defined in `keiro/src/Keiro/Workflow/Types.hs`:
`completedStepName = "__workflow_completed__"`, `cancelledStepName =
"__workflow_cancelled__"`. The SQL literals in `findUnfinishedWorkflowIdsStmt` must
keep matching these.

**The child links table** `keiro_workflow_children`
(`keiro/src/Keiro/Workflow/Child/Schema.hs`) is already keyed by `(child_id,
child_name)` and `findRunningChildIds` already returns `(child_id, child_name)`
pairs, so it is *not* affected by this bug. After this fix, the resume worker's
discovery union (`findUnfinishedWorkflowIds <> findRunningChildIds`, deduped) yields
distinct pairs for a parent and a child even when they share an id.

**Why the journal replay itself is already correct.** The in-memory replay
pre-loads from the journal *stream* `wf:<name>-<id>` (`loadJournal` in
`Keiro.Workflow` reads `readStreamForwardStream journalName`), whose name includes
the workflow name, so each workflow's step map is already isolated. The bug is
purely in the *derived index* and the *discovery/existence* queries built on it —
which is exactly what this plan re-keys.


## Plan of Work

### Milestone 1: re-key the index (migration)

Add a new migration file
`keiro-migrations/sql-migrations/2026-06-04-00-00-00-keiro-workflow-steps-name-key.sql`
(timestamped after the existing v2 migrations). Its body:

```sql
-- Resolve unqualified names into the Kiroku schema (search_path is session-scoped;
-- see docs/plans/46-...). The kiroku schema and keiro_workflow_steps already exist.
SET search_path TO kiroku, pg_catalog;

-- Re-key the step index on the full workflow identity (id + name). Two workflows
-- that share an id under different names were previously conflated; including the
-- name makes them independent. Adding a column to the key is a strict relaxation,
-- so no existing row can violate the new key.
ALTER TABLE keiro_workflow_steps DROP CONSTRAINT keiro_workflow_steps_pkey;
ALTER TABLE keiro_workflow_steps ADD PRIMARY KEY (workflow_id, workflow_name, step_name);

-- Widen the lookup index so discovery's per-(id,name) grouping is index-supported.
DROP INDEX IF EXISTS keiro_workflow_steps_workflow_idx;
CREATE INDEX IF NOT EXISTS keiro_workflow_steps_workflow_idx
  ON keiro_workflow_steps (workflow_id, workflow_name);
```

Confirm the original create migration's default PK name (`keiro_workflow_steps_pkey`)
with `\d kiroku.keiro_workflow_steps` against a migrated database before relying on
it; adjust the `DROP CONSTRAINT` name if it differs. Remember the cabal recompile
gotcha for migrations recorded in MasterPlan 5's Integration Points: after adding a
`.sql` file, `cabal` may report `Keiro.Migrations` "up to date" — touch the module
or `cabal clean` the `keiro-migrations` build if the embedded set looks stale.

At the end of this milestone `cabal test keiro-migrations-test` passes on a fresh
apply (extend its `expectedTables` if not already covered by plan 46) and a manual
`\d kiroku.keiro_workflow_steps` shows the three-column primary key.

### Milestone 2: make the schema layer name-aware

Edit `keiro/src/Keiro/Workflow/Schema.hs`:

1. `recordStepStmt`: change `ON CONFLICT (workflow_id, step_name)` to `ON CONFLICT
   (workflow_id, workflow_name, step_name)`.
2. `stepExists`: import `WorkflowName (..)` from `Keiro.Workflow.Types`; change the
   signature to `stepExists :: (Store :> es) => WorkflowName -> WorkflowId -> Text
   -> Eff es Bool` and the statement's `WHERE` to `workflow_id = $1 AND
   workflow_name = $2 AND step_name = $3` (use `contrazip3`).
3. `loadStepIndex`: change to `loadStepIndex :: (Store :> es) => WorkflowName ->
   WorkflowId -> Eff es (Map Text Value)` with `WHERE workflow_id = $1 AND
   workflow_name = $2`.
4. `findUnfinishedWorkflowIdsStmt`: add `AND c.workflow_name = s.workflow_name` to
   the `NOT EXISTS` subquery so the terminal-marker check is per-(id, name).

Then edit `keiro/src/Keiro/Workflow.hs` to pass `name` at the three `stepExists`
call sites (`stepExists name wid cancelledStepName`, and the two `stepExists name
wid key`). Update the re-export list if the signatures' documentation changes.
Find and update any other caller: `grep -rn "stepExists\|loadStepIndex" keiro`.

At the end of this milestone `cabal build keiro` is green with no warnings.

### Milestone 3: the shared-id regression test

Add a test to `keiro/test/Main.hs` in the `describe "Keiro.Workflow.Child"` (or a
new `describe "Keiro.Workflow shared-id"`) block. Define a parent and a child that
**share a workflow id** under different names — e.g. parent `(WorkflowName
"parent", WorkflowId "shared-1")` and child `(WorkflowName "ship", WorkflowId
"shared-1")` — using the existing `parentWorkflow`/`shipWorkflow` helpers (note
`parentWorkflow` currently derives the child id from its argument; pass it the
*same* id as the parent to force the collision). Drive both through
`resumeWorkflowsOnce` from a registry, and assert:

- after the child completes but before the parent does, `findUnfinishedWorkflowIds`
  contains `("shared-1", "parent")` (the parent is **not** masked);
- the parent reaches `Completed` with a `WorkflowCompleted` in `wf:parent-shared-1`;
- the child has its own `WorkflowCompleted` in `wf:ship-shared-1`;
- once both are done, `findUnfinishedWorkflowIds` contains neither.

Prove the regression: this test must **fail** on the tree before Milestone 2 (the
parent is masked and never completes) and **pass** after. Demonstrate both (Concrete
Steps).

### Milestone 4: full green and doc reconciliation

Run `cabal build all`, `cabal test keiro`, `cabal test jitsurei-test`. Then update
the EP-45 plan's Surprises entry and MasterPlan 5's Surprises entry (the
"distinct-ids" contract) to note that, as of this plan, sharing an id is *safe* and
distinct ids are now a recommendation, not a requirement — and that the `jitsurei`
demo (which already uses distinct ids via `shipChildId`) needs no change.


## Concrete Steps

Run all commands from the repository root.

**Step 0 — confirm the current name-blind shape:**

```bash
grep -n "ON CONFLICT\|workflow_id = \|c.workflow_id = s.workflow_id" keiro/src/Keiro/Workflow/Schema.hs
```

Expected: the `ON CONFLICT (workflow_id, step_name)`, the name-blind `WHERE`s, and
the name-blind `NOT EXISTS` subquery.

**Step 1 — add the migration (Milestone 1), then:**

```bash
cabal test keiro-migrations-test
```

Expected: fresh apply green; `\d kiroku.keiro_workflow_steps` shows
`PRIMARY KEY (workflow_id, workflow_name, step_name)`.

**Step 2 — edit the schema + call sites (Milestone 2):**

```bash
cabal build keiro
```

Expected: green, no warnings.

**Step 3 — add the regression test and prove it both ways (Milestone 3):**

```bash
# After Milestone 2, the shared-id test passes:
cabal test keiro

# Prove it would fail before the schema fix: revert only the Schema/Workflow edits
# (keep the test and migration), run, restore.
git stash push -- keiro/src/Keiro/Workflow/Schema.hs keiro/src/Keiro/Workflow.hs
cabal test keiro    # expect: the shared-id test FAILS (parent masked, never completes)
git stash pop
cabal test keiro    # expect: green
```

Record the failing-then-passing transcript in Surprises & Discoveries.

**Step 4 — full green (Milestone 4):**

```bash
cabal build all
cabal test keiro
cabal test jitsurei-test
```


## Validation and Acceptance

Acceptance is observable behavior:

**Check 1 — a parent and child sharing an id both complete.** The Milestone 3 test
drives a parent and a child that share `WorkflowId "shared-1"` (names `parent` and
`ship`) through the resume worker; both reach `Completed`, each with its own
`WorkflowCompleted` journal marker. Fails before the fix (parent masked), passes
after.

**Check 2 — discovery is per-(id, name).** In that test,
`findUnfinishedWorkflowIds` reports `("shared-1", "parent")` while only the child
has completed, and reports neither once both have.

**Check 3 — storage key is the full identity.** `\d kiroku.keiro_workflow_steps`
(against a migrated database) shows `PRIMARY KEY (workflow_id, workflow_name,
step_name)`.

**Check 4 — whole repository green.** `cabal build all`, `cabal test keiro`, and
`cabal test jitsurei-test` all pass.


## Idempotence and Recovery

The migration is a one-way key relaxation and is safe to apply once (codd records it
by filename and will not re-run it). It cannot fail on existing data because adding a
column to a primary key never introduces a duplicate. The schema-layer edits are
ordinary code changes; the test uses a throwaway ephemeral database per run. If a
deployment had already worked around the footgun with distinct ids, this change is
transparent to it (distinct ids remain valid). To roll back, revert the code and
leave the migration applied — the wider key is backward-compatible with the
name-blind queries (they would simply ignore the extra key column), so a mixed
state during rollout is safe.


## Interfaces and Dependencies

This plan adds one migration and changes the signatures of two internal lookups; it
adds no new package dependency.

- New migration:
  `keiro-migrations/sql-migrations/2026-06-04-00-00-00-keiro-workflow-steps-name-key.sql`.
- `keiro/src/Keiro/Workflow/Schema.hs`:
  - `recordStepStmt` — `ON CONFLICT (workflow_id, workflow_name, step_name)`.
  - `stepExists :: (Store :> es) => WorkflowName -> WorkflowId -> Text -> Eff es Bool`.
  - `loadStepIndex :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es (Map Text Value)`.
  - `findUnfinishedWorkflowIdsStmt` — `NOT EXISTS` subquery matches `workflow_name` too.
- `keiro/src/Keiro/Workflow.hs` — pass `name` at the three `stepExists` call sites;
  re-export list unchanged in membership (signatures change).
- `keiro/test/Main.hs` — the shared-id regression test; update any existing
  `stepExists`/`loadStepIndex` call there to the new signatures.

Unaffected and relied upon as-is: the journal stream replay (`loadJournal` reads
`wf:<name>-<id>`, already name-isolated); `keiro_workflow_children` and
`findRunningChildIds` (already keyed by `(child_id, child_name)`); the resume worker
(`Keiro.Workflow.Resume`), whose discovery becomes correct once
`findUnfinishedWorkflowIds` is name-aware.

**Relationship to other plans.** Soft-depends on
`docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md`
(the new migration follows its `SET search_path` convention; the line is included
here regardless, so the two plans are independent in either order). Supersedes the
"workflow ids must be distinct across names" workaround recorded in
`docs/plans/45-durable-workflow-worked-example-and-guide.md` and MasterPlan 5.

**Git trailers.** Every commit must carry, after a blank line:

```text
ExecPlan: docs/plans/47-key-workflow-step-index-and-discovery-on-workflow-id-and-name.md
Intention: intention_01kt7npxxbedqt8e0ba4dmyxzb
```
