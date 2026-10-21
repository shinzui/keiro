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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:24:48Z
      verdict: "changes-requested"
      note: "Primary-key order cannot bound work for sparse or absent filters; evidence driver must be adapted to removed SQL prefix/error and changed cursor parameters."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:49:51Z
      mode: "update"
      note: "Bound only unfiltered key traversal; specify wf-key2, filtered-query envelopes and evidence-driver migration."
---

# Bound the workflow listing cost without the withdrawn inspection indexes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


After this plan, unfiltered `keiro-ops wf inspect list` traverses the existing primary key
in `(workflow_id, workflow_name)` order, without the obsolete wide-key union or a ledger sort.
Its first and continuation pages examine approximately the requested number of rows. A query
with status, name, creation-time or update-time filters may examine many more rows; creation
ordering may scan and sort the ledger. Those reads retain host deadlines and publish a measured
operating envelope, rather than a page-sized-work promise. No inspection index or writer SQL
change is introduced, and the published legacy `listWorkflowInstances` API keeps its order.


## Progress


- [ ] M1: Unfiltered default first/deep pages use primary-key range scans on the 100,000-row
      fixture, without a ledger sort. Sparse and absent filters are measured separately and
      are not accepted by pretending their rows-examined bound equals page size.
- [ ] M2: Remove the obsolete wide-key split, its three constants and `InspectionWorkLimitExceeded`;
      preserve response/cursor byte caps, valid wide keys, and passing library/CLI/HTTP tests.
      Old default-order tokens fail closed under a new `wf-key2` cursor kind.
- [ ] M3: User documentation distinguishes unfiltered range traversal from filtered and
      creation-order search, with measured costs and deadline/cadence guidance for workflow
      and timer reads. Documentation and relevant ADR validation pass.
- [ ] M4: Adapt the evidence driver to the new SQL, parameters, cursor kind and errors, then
      retain normal-planner custom/generic plans at 10,000 and 100,000 rows in
      `keiro/bench/results/inspection/query-readside-v2/`. Historical artifacts remain intact.


## Surprises & Discoveries


Review identified that ordering by the primary key cannot bound sparse-filter work. The
existing evidence fixture has one failed row per thousand and no retrying rows: a key-order
scan for either class may discard most or all of the ledger. The existing driver also finds
the old statement by `WITH inspection_wide%`, uses old cursor tuples, always supplies a class
array, and pattern-matches the error this plan removes. Regenerating evidence requires editing
that driver, not merely rerunning its existing command.


## Decision Log


- Decision: Use `(workflow_id, workflow_name)` and a new `wf-key2` cursor for unfiltered
  default browsing; retain the legacy API and `wf-created` contract.
  Rationale: The primary key already serves that order without inspection writer cost.
  A new cursor kind prevents an old two-text token being interpreted with reversed meaning.
  Date: 2026-10-21
- Decision: Remove the withdrawn-index wide split for both orderings, retaining cursor and
  response limits. Promise page-proportional traversal only for unfiltered key ranges.
  Rationale: Wide candidates no longer have their former index; arbitrary filters and
  creation sorting still need measured envelopes and host deadlines. No new index is authorized.
  Date: 2026-10-21

Revision note (2026-10-21): Corrected filtered-cost acceptance, fixed cursor-version choice,
and made evidence-driver adaptation an explicit implementation deliverable.


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


M1 changes `Keiro.Workflow.Inspection.Query` and `Keiro.Workflow.Inspection` so `ByKey`
means `(workflow_id, workflow_name)` and its cursor kind is `wf-key2`, carrying that tuple.
Change the key continuation predicate and order in `inspectionInstanceStatement` in
`keiro/src/Keiro/Workflow/Instance.hs` together. Preserve `ByCreatedDesc` and its
`wf-created` token semantics, plus the published `listWorkflowInstances` query. A first or
deep unfiltered page should seek the primary key and return at most `pageSize + 1` candidates.
Keep status classification semantics unchanged. Apply optional filters as predicates, but
never assert that `LIMIT` bounds the candidates they discard. Test cursor continuity with
IDs/names whose lexical orders disagree, old `wf-key` refusal, and every class predicate.

M2 removes `inspection_wide`, `wide_budget`, narrow/wide predicates, the three wide-key
constants and `InspectionWorkLimitExceeded` from the library and the CLI error mapping.
Remove its HTTP documentation/mapping if present, coordinating only this error handling in
`Application.hs` with plan 318's admission changes. Convert wide-key tests into correctness
and cursor-size tests: valid 2,700-byte keys appear in order; a continuation exceeding the
existing 4,096-byte codec cap still returns the supported result-size error. Do not relax
writer key validity, drop unrelated byte caps, or require historical plan/review text to
stop mentioning the removed error.

M3 writes the workflow envelope in `docs/user/durable-workflows.md`: unfiltered key order
uses a range scan, while sparse/absent class, name and time filters can search the ledger,
and `created_desc` can scan/sort it. Library callers must provide deadlines; HTTP/feed hosts
retain admission and SQL/read deadlines. Filtered automatic views remain subject to measured
cadence and workload limits, not the unfiltered complexity claim. Update the pending-timer
cost section in `docs/user/process-managers-and-timers.md`, retaining the five-second minimum
automatic timer cadence. Plan 319 owns that page's manager/API wording, and plan 320 owns
changelogs. ADR-40 records the guarantee boundary; amend ADR-28 if its obsolete wide-index
paragraph still describes the pre-withdrawal design when the implementation lands.

M4 adapts `scripts/inspection-query-evidence.hs`. Add a stable SQL comment marker such as
`/* keiro-inspection-page-v2 */` to the new inspection statement and have the driver select
that marker in `pg_prepared_statements` on the same single-connection pool that installed it.
Keep the driver explaining the actual library-prepared statement. Replace old `wf-key` tokens
with `wf-key2` and `(id,name)` tuples. Rebuild each case's EXECUTE arguments to match the
new statement's actual parameter order; remove unconditional class-array arguments if the
new query no longer binds them. Remove the deleted-error branch and report success versus
supported size errors explicitly. Do not make a new SQL query in the driver and explain that
instead of the library statement.

Retain first/deep unfiltered, running/rare/absent class, absent/small name, time-window,
creation-order and wide-key cases under custom and generic plans at both sizes. Record
rows returned, rows removed, buffers and elapsed time. The sparse/absent cases are required
to demonstrate the limit of the guarantee, not to satisfy a false page-size scan criterion.
Keep old evidence untouched and update its README with a dated link to the replacement.


## Concrete Steps


From the repository root inside `nix develop`:

```bash
cabal build keiro keiro-ops keiro-ops-http
cabal test keiro-test --test-options='-m "WorkflowInspection"'
cabal test keiro-ops-test keiro-ops-http-test
cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support scripts/inspection-query-evidence.hs keiro/bench/results/inspection/query-readside-v2
cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support scripts/inspection-query-evidence.hs keiro/bench/results/inspection/query-readside-v2/wide wide
just user-documentation-validate
just adr-validate
```

The driver creates disposable fixtures and executes EXPLAIN in the connection that installed
the prepared statement. A separate psql session cannot inspect another connection's prepared
statements. Adapt the driver as M4 specifies before running it. The expected unfiltered
20-row page has a Limit over a primary-key index scan returning up to 21 rows, no ledger sort,
and no residual-filter rejections. Filtered cases may use different indexes or scans.

Check removal only in live source/test trees:

```bash
rg -n 'InspectionWorkLimitExceeded|maxIndexedWorkflowKeyBytes|maxWideWorkflowCandidates|maxWideWorkflowKeyBytes' keiro/src keiro/test keiro-ops/src keiro-ops/test keiro-ops-http/src keiro-ops-http/test scripts/inspection-query-evidence.hs
```

That search should return no matches after M2/M4. Historical plans and evidence are excluded.


## Validation and Acceptance


M1 requires actual custom/generic EXPLAIN plans for first/deep unfiltered ranges without a
ledger sort, and passing cursor/class correctness tests. For this fixture the range scan
returns at most pageSize + 1 rows and has zero rows removed by residual filtering. Do not
require that shape for filtered queries: rare/absent class, name and time cases must instead
retain honest cost evidence and matching deadline/cadence guidance.

M2 requires live-source removal of the obsolete split/error plus successful wide-key,
result-size, library, CLI and HTTP tests. M3 requires accurate owner-authored envelope text
and validators passing. M4 requires a runnable adapted driver and retained v2 artifacts for
all named cases at both fixture sizes and plan modes. The existing writer-capacity evidence
remains applicable only while writer statements and indexes are unchanged; any proposed DDL
change must be treated as a new design decision with matched writer evidence.


## Idempotence and Recovery

All steps are ordinary source and documentation edits; `git checkout` restores any file. The
evidence driver uses disposable fixtures and never touches a persistent database. If the
cursor kind is versioned, old tokens fail closed with `MalformedCursor`, which is the intended
behaviour for an unreleased contract.


## Interfaces and Dependencies


This plan owns `keiro/src/Keiro/Workflow/Inspection.hs`, `Inspection/Query.hs`, the inspection
statement in `Workflow/Instance.hs`, workflow error rendering in `keiro-ops`, and the evidence
driver. The cursor producer, CLI/HTTP consumers and workflow feed must agree through their
existing owner-read tests. In `keiro-ops-http/src/Keiro/Ops/Http/Application.hs`, this plan owns
only the removed workflow-error mapping; plan 318 owns admission/delivery.

This plan owns workflow/timer cost-envelope paragraphs in the user guides. Plan 319 owns
manager and legacy wording in the shared manager/timer page; plan 320 consumes both for
changelogs. No prerequisite blocks implementation. Plan 320 final M1/M4 and plan 303's tag
require this plan Complete.
