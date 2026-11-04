---
type: Improvement Request
title: Complete workflow inspection primitives for HTTP
description: >-
  Add the cursor-paged workflow listings and incremental detail reads (journal, steps,
  children, awakeables) that a browser UI needs beyond the one-shot keiro-ops wf output, in
  the owning library first, so the durable-execution screens can render and refresh
  incrementally against the keiro_workflows wake ledger.
timestamp: 2026-11-04T05:28:05Z
requestId: IR-30
status: completed
origin: mori://shinzui/keiro-ui
plan: docs/plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md
relatedPlans:
  - docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md
  - docs/plans/276-serve-the-keiro-ops-surface-over-http.md
  - docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md
  - docs/plans/326-make-releases-preflighted-resumable-and-isolated.md
  - docs/plans/317-bound-the-workflow-listing-cost-without-the-withdrawn-inspection-indexes.md
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-09-16T04:45:00Z
    document_timestamp: 2026-09-11T14:30:01Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5
    effort: high
    context: >-
      Bundle refresh at Keiro `708aa215`. `accepted` is correct and the plan link resolves. Plan
      275 has 0 checked items and 5 open milestones, and the related plan 276 is likewise
      unstarted, so neither the library half nor the endpoint half exists. Both links resolve.
      The deliberate split — cursor-paged reads, status vocabulary, cursor contract, JSON
      rendering, and `keiro-ops` adoption in plan 275; endpoint exposure in the IR-26 sister
      package — still matches what those two plans scope.
completedAt: 2026-11-04T05:28:05Z
resolution: >-
  Plan 275 delivered cursor-paged workflow instances, headers, journals, steps, children, and
  awakeables.
  Keiro 0.22.0.0 shipped the cohort after the accepted b2be482b release gate.
  Plan 326 retains an exact-version published consumer with a healthy composed
  /keiro/health response; the 0.23.0.0 published consumer repeats that proof.
  Completion reconciles retained evidence; Plan 303 release tracking lags those records.
---

# Improvement Request: Complete Workflow Inspection Primitives for HTTP

## Status

**Completed; reconciled on 2026-11-04.**
[ExecPlan 275](../plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md)
delivered cursor-paged workflow instances, headers, journals, steps, children, and awakeables.
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md)
records all six implementation children Complete and their accepted runtime-interference evidence.

The cohort shipped in Keiro 0.22.0.0 (release commit `fb6e3cff`) after the
[final release gate](../../keiro/bench/results/release-gates/0.22.0.0-checks.txt)
passed correctness, all six benchmark guards, native Nix and package checks.
[ExecPlan 326](../plans/326-make-releases-preflighted-resumable-and-isolated.md) retains the
[exact-version published consumer](../../keiro/bench/results/release-gates/workflow-326/published/result.json),
which builds the released packages and serves the composed `/keiro/health` response
with `status: ok` and no schema drift. The
[0.23.0.0 published consumer](../../keiro/bench/results/release-gates/0.23.0.0-20261031T121415Z-60c43662/published/result.json)
repeats that proof (evidence commit `e643c696`). These records satisfy the publication and
consumer gates assigned to
[ExecPlan 303](../plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md);
its older unchecked release milestones do not describe the released state.

Originally proposed by the runtime UI initiative under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`.
The implementation notes below retain the earlier local checkpoints; their pending-release
statements describe those dates, before the release and consumer proof.

## Context

Workflow inspection is keiro's best-covered operational domain: `keiro-ops wf` offers list,
show, steps, journal, awakeable, cancel, resurrect, lease, and gc, all rendering into the
`OpsResult` envelope. The durable-execution screens of the planned UI — the centerpiece
screens, in the mold of Restate's workflow views — need those reads in an incremental shape
the CLI does not:

- **Cursor-paged listings.** A CLI lists once and exits; a UI pages thousands of workflow
  instances by status, type, and age, needing stable cursors over the `keiro_workflows` wake
  ledger (the authoritative table for status, attempts, lease, next attempt).
- **Incremental detail reads.** A workflow detail screen loads the instance header, then
  pages its journal and step index (`keiro_workflow_steps`), its children
  (`keiro_workflow_children`), and its awakeables (`keiro_awakeables`) as the operator
  scrolls — not one monolithic dump per invocation.
- **Filter vocabularies.** Listing by status class (running, stuck-retrying, awaiting
  signal, cancelled, done) requires the read to expose the ledger's states as a stable,
  documented enumeration.

Per `mori://shinzui/keiro/okf/adrs/concepts/ADR-28`, these must exist as supported library
reads before any endpoint serves them; the CLI itself may adopt them where its own output
would improve, but the CLI's existing one-shot behavior is not in question.

## Requested Change

1. Library-level reads in the owning package(s), cursor-paginated and filterable:
   a. list workflow instances over `keiro_workflows` by status class, workflow type, and age
      windows, with stable cursors;
   b. one instance's header (status, attempts, lease holder and expiry, next attempt time);
   c. paged reads of the instance's journal and step index, children, and awakeables;
   d. the status enumeration documented as a stable vocabulary for filter parameters.
2. Endpoints in the IR-26 sister package wrapping those reads under its envelope and the
   initiative's wire conventions (project `mori://shinzui/keiro-ui`, path
   `docs/architecture/inspection-api-conventions.md`, artifact-level URI pending; cursor
   pagination with `next_cursor` omitted on the last page).
3. Live refresh of these listings is `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-27`'s
   concern; this request supplies the poll-path reads those feeds re-read (push is a hint,
   poll is truth — `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`).

## Acceptance

1. Against a test ledger with more instances than one page, listing by status class pages
   completely and stably (no skips or repeats while quiescent), with `next_cursor` omitted on
   the final page.
2. The instance header read agrees with `keiro-ops wf show --json` for the same instance
   (asserted by diff in a test).
3. Journal, steps, children, and awakeables each page independently for an instance with
   entries in all four.
4. A stuck instance (retries exhausted, lease held) is findable through the documented status
   filter vocabulary alone.
5. All reads wrap supported operations on the owning library — no ad-hoc SQL (ADR-28) — and
   the endpoints serve them per the conventions.

## Requested Deliverables

The paged reads with tests (including the CLI-agreement diff), the endpoint exposure under
IR-26, and documentation of the status vocabulary and cursors.


## Implementation evidence (2026-10-20, historical checkpoint)

[ExecPlan 275](../plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md)
implements the shared cursor codec, status classes, instance orderings,
owner/generation-bound detail pages, canonical JSON, and six `wf inspect`
commands. HTTP pages the ledger and maps typed errors. A header with 100,000
children performs verification plus one instance read. Migration 0033 installs
the creation index and its schema snapshot; 41 migration examples pass.
Initial focused workflow, ops, and HTTP suites pass 10, 51, and 22 examples.
Query/write-cost acceptance, full repository verification, and cohort release
remain outstanding.

The revised workflow index candidate preserves large stored keys with guarded
ordered indexes and a separately budgeted exceptional set. All 13 focused
workflow examples and 43 migration/51 ops/26 HTTP examples pass at the recorded
checkpoints. 136 actual custom/generic plans cover normal and 100,000-wide-key
fixtures, including an explicit 65-row-lookahead failure. Manual time and owner
detail shapes remain outside automatic feeds under host deadlines. Longer
schema-only write diagnostics retain WAL/HOT costs and noisy control ranges;
they do not establish the integrated 5% or retention gates. Publication and
request completion remain owned by plan 303.
