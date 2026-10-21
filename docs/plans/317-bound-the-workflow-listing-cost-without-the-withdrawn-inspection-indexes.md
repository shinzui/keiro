---
id: 317
slug: bound-the-workflow-listing-cost-without-the-withdrawn-inspection-indexes
title: "Bound the workflow listing cost without the withdrawn inspection indexes"
kind: exec-plan
created_at: 2026-10-21T12:21:07Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
master_plan: "docs/masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T12:21:07Z
---

# Bound the workflow listing cost without the withdrawn inspection indexes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, an operator who runs `keiro-ops wf inspect list` (or fetches the matching HTTP
page) on a ledger of a million workflows gets the first page, and every continuation page, in
the time it takes PostgreSQL to walk a few dozen index entries, instead of the time it takes to
scan the whole table three times. The unreleased listing becomes public contract with the next
tag, so this plan settles its cost model before that happens: the default order follows the
primary key so the read is an index range scan; the "wide key" machinery that was built for
inspection indexes which were later withdrawn is removed; the one ordering that still needs a
full scan (`created_desc`) is documented as a manual, deadline-bound read; and the retained
query-plan evidence says what the reads actually do.


## Progress

- [ ] M1: The default `wf inspect list` page is an index range scan. With a 100,000-row
      fixture, `EXPLAIN (ANALYZE, BUFFERS)` of the prepared statement that
      `listWorkflowInstancesPage` installs shows an `Index Scan` on `keiro_workflows_pkey`
      with rows removed by filter no larger than the page size, for the first page and for a
      deep cursor, with and without a status-class filter.
- [ ] M2: The wide-key split is gone. `maxIndexedWorkflowKeyBytes`, `maxWideWorkflowCandidates`,
      `maxWideWorkflowKeyBytes`, and `InspectionWorkLimitExceeded` no longer exist, or they are
      retained only for the `created_desc` ordering with a Decision Log entry saying why; the
      `WorkflowInspectionSpec` tests pass; `keiro-ops-test` and `keiro-ops-http-test` pass.
- [ ] M3: The remaining linear reads are documented as an operating envelope. The
      `created_desc` ordering, the pending-timer listing without filters, and `pm show`'s
      timer filter are described in `docs/user/durable-workflows.md` and
      `docs/user/process-managers-and-timers.md` with the measured 100,000-row costs and the
      rule that automatic refresh stays at the measured cadence.
- [ ] M4: The evidence is honest. `keiro/bench/results/inspection/query-readside/README.md` and
      `keiro/bench/results/inspection/README.md` describe the new plans, and a regenerated
      plan set from `scripts/inspection-query-evidence.hs` is retained beside the old one.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Change the default listing order to the primary key's column order
  `(workflow_id, workflow_name)` instead of adding an index for `(workflow_name, workflow_id)`.
  Rationale: ADR-40 forbids writer cost for inspection, the stored-class candidate was withdrawn
  after a measured 9.22% writer-capacity loss, and the listing is unreleased so its cursor
  payload can change without a compatibility edge. The legacy `listWorkflowInstances` API keeps
  its order and remains published.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Durable workflows persist one header row per instance in the PostgreSQL table
`keiro.keiro_workflows` (migration `keiro-migrations/migrations/0011-keiro-workflows-instances.sql`).
Its indexes, listed in `keiro-migrations/expected-schema/native/keiro-v18.txt` lines 653 to
655, are the primary key on `(workflow_id, workflow_name)`, `keiro_workflows_active_idx` on
`(status, wake_after)` for running and suspended rows, and `keiro_workflows_gc_idx` on
`(status, completed_at)`. There is no index on `created_at` and none on
`(workflow_name, workflow_id)`.

The unreleased inspection listing lives in `keiro/src/Keiro/Workflow/Inspection.hs`
(`listWorkflowInstancesPage`, the cursor codec use, `statusClassOf`) and the SQL it runs is
built by `inspectionInstanceStatement` in `keiro/src/Keiro/Workflow/Instance.hs`; the query
record and the constants are in `keiro/src/Keiro/Workflow/Inspection/Query.hs`. A "cursor" is
an opaque base64url token (`keiro/src/Keiro/Inspection/Cursor.hs`) that encodes the last row's
ordering key under a kind (`wf-key` for the default order, `wf-created` for `created_desc`);
clients echo it to get the next page. The statement splits every list into a "narrow" page
(rows whose `workflow_name` plus `workflow_id` is at most 2,600 bytes) and a "wide" union of
seven per-status-class branches, each limited to 65 rows, whose candidate count and bytes are
budgeted before merging; more than 64 wide candidates refuses the request with
`InspectionWorkLimitExceeded`. Those constants are named for the inspection indexes that plan
275 built to exclude oversized tuples (`keiro/bench/results/inspection/key-domain/README.md`
explains the index tuple limit), but commit `5893c7eb` withdrew those indexes after the
capacity loss in `keiro/bench/results/inspection/composed-writer-capacity-final/README.md`,
and the split stayed.

REV-20 (`docs/reviews/keiro-0-20-0-21-unreleased-review.md`, first finding) read the retained
plan `keiro/bench/results/inspection/query-readside/100000-force_custom_plan-key-first.json`:
the `running` and `retrying` wide branches are sequential scans that remove 100,001 and
100,002 rows by filter, the five terminal-class branches are `keiro_workflows_gc_idx` scans,
and the narrow page itself is a parallel sequential scan plus a top-N sort because
`ORDER BY workflow_name, workflow_id` cannot use a primary key whose first column is
`workflow_id`. The first page costs 15.2 ms at 100,000 rows and grows linearly; the deep-cursor
page costs 12.6 ms. The published `listWorkflowInstances` (same file, `listWorkflowInstancesStmt`)
uses the same order and cursor and has the same mismatch, but it is released API and is not
changed by this plan. The `keiro-ops` command `wf inspect list` (`keiro-ops/src/Keiro/Ops/Workflow.hs`,
the `--ordering key|created_desc` option defaulting to `key`) and the HTTP route in
`keiro-ops-http/src/Keiro/Ops/Http/Route.hs` call the library read and treat the cursor as
opaque.

Relevant local ADRs: ADR-40
(`docs/adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md`) requires
that inspection adds no writer cost and renders supported reads. ADR-23
(`docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`)
owns the writer-side indexes and must not be weakened. ADR-56
(`docs/adr/0056-inspection-feeds-own-bounded-shared-drivers-and-an-active-only-wake-cursor.md`)
makes the workflow feed read the same first page, so the feed inherits whatever this plan does.
No cross-repository ADR applies.


## Plan of Work

Milestone 1 reorders the default listing. In `Keiro.Workflow.Inspection.Query`, make `ByKey`
mean the primary key's order: `ORDER BY workflow_id, workflow_name`, with the cursor predicate
`(workflow_id, workflow_name) > ($n, $n+1)` and the `wf-key` cursor payload carrying
`(workflowId, workflowName)` in that order. Keep `ByCreatedDesc` as it is. Rewrite
`inspectionInstanceStatement` so the default page is one `SELECT ... WHERE <filters> ORDER BY
workflow_id, workflow_name LIMIT $n`, and the status-class filter is a plain predicate over
`status`, `attempts`, and `wake_after` (the same expressions `classPredicate` emits today) rather
than a `UNION ALL` of per-class branches; PostgreSQL applies the predicate while walking the
index and stops after the page. Update `WorkflowInspectionSpec` in `keiro/test/` so its cursor
expectations follow the new order, and add a test that a cursor minted by the old order is
rejected as `MalformedCursor` only if the payload shape changed (if the shape is the same pair
in a different order, add a version to the cursor kind, for example `wf-key2`, so an old token
cannot silently page in the wrong order).

Milestone 2 removes the wide-key split. Delete `inspection_wide`, `wide_budget`, the
`narrowKey`/`wideKey` predicates, the three constants, and `InspectionWorkLimitExceeded` from
the library, the `keiro-ops` renderer (`inspectionError` in `keiro-ops/src/Keiro/Ops/Workflow.hs`),
and the HTTP error table (`keiro-ops-http/src/Keiro/Ops/Http/Application.hs`); remove the
`query-wide-key-budget` fixture tests or convert them into a test that a 2,700-byte key simply
appears in its index position. If the owner prefers to keep a candidate budget for
`created_desc`, record that in the Decision Log and keep only what that ordering needs.

Milestone 3 documents the envelope. In `docs/user/durable-workflows.md`, the inspection
section (around the `wf inspect` examples near line 318) states that the default order is a
primary-key range scan whose cost follows the page size, that `--ordering created_desc` scans
and sorts the ledger (26.9 ms at 100,000 rows in the retained plans) and is for manual use
under the host's statement deadline, and that the HTTP and feed hosts enforce that deadline.
In `docs/user/process-managers-and-timers.md`, state the pending-timer listing's measured
envelope (0.038 to 15.8 ms at 100,000 rows, `keiro/bench/results/inspection/pending-timer-read/README.md`)
and the five-second automatic refresh floor. Both bundles validate with
`just user-documentation-validate`.

Milestone 4 regenerates the evidence. Build and run `scripts/inspection-query-evidence.hs`
against a fresh 10,000-row and 100,000-row fixture the way its header comment describes, write
the plans to `keiro/bench/results/inspection/query-readside-v2/`, and update the two READMEs so
the claim "existing key/status indexes serve the reads" is true of the default order. Then
update ADR-40's rationale paragraph or add a short ADR that records the cost model: inspection
browses in primary-key order, adds no index, and documents any ordering that needs a scan.


## Concrete Steps

From the repository root inside `nix develop`:

```bash
cabal build keiro keiro-ops keiro-ops-http
cabal test keiro-test --test-options='-m "WorkflowInspection"'
cabal test keiro-ops-test keiro-ops-http-test
```

To look at the plan the library installs, start the project database (`just postgres-start`),
seed 100,000 workflow rows with the fixture builder in
`scripts/inspection-query-evidence.hs`, then from `psql`:

```sql
SELECT name, statement FROM pg_prepared_statements;   -- after one listWorkflowInstancesPage call
EXPLAIN (ANALYZE, BUFFERS) EXECUTE <name>('{...}', ...); -- with the parameters the driver prints
```

Expected shape for the first default page:

```text
Limit (actual rows=101)
  -> Index Scan using keiro_workflows_pkey on keiro_workflows
       Rows Removed by Filter: 0
```

Documentation validation:

```bash
just user-documentation-validate
just adr-validate
```


## Validation and Acceptance

M1 is accepted by the `Index Scan` plans for first page, deep cursor, with and without a
class filter, each with rows removed by filter at most the page size, plus a passing
`WorkflowInspectionSpec`. M2 is accepted when the constants and error are gone from `keiro`,
`keiro-ops`, and `keiro-ops-http`, the three suites pass, and `grep -rn InspectionWorkLimitExceeded
keiro keiro-ops keiro-ops-http docs` finds nothing (or only the Decision Log entry that kept
it for `created_desc`). M3 is accepted by the validator passing and the two documents stating
the envelope. M4 is accepted by the v2 evidence directory and the corrected README sentences.
The writer-capacity gate does not need rerunning because no writer statement or index changes;
say so in the evidence README.


## Idempotence and Recovery

All steps are ordinary source and documentation edits; `git checkout` restores any file. The
evidence driver uses disposable fixtures and never touches a persistent database. If the
cursor kind is versioned, old tokens fail closed with `MalformedCursor`, which is the intended
behaviour for an unreleased contract.


## Interfaces and Dependencies

`keiro/src/Keiro/Workflow/Inspection.hs`, `keiro/src/Keiro/Workflow/Inspection/Query.hs`,
`keiro/src/Keiro/Workflow/Instance.hs` (`inspectionInstanceStatement`, `inspectionInstanceRows`),
`keiro/src/Keiro/Inspection/Cursor.hs`; `keiro-ops/src/Keiro/Ops/Workflow.hs`;
`keiro-ops-http/src/Keiro/Ops/Http/Application.hs` and `Views.hs` (the workflow feed reads the
same first page); `hasql` statements and `tasty`/`hspec` tests. The cursor payload for `wf-key`
is the interface other work consumes, and this plan owns it. Plan 320 describes the shipped
result in the changelogs. No parent milestone must be accepted before this plan begins.
