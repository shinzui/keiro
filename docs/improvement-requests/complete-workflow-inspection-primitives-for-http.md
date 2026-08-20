---
type: Improvement Request
title: Complete workflow inspection primitives for HTTP
description: >-
  Add the cursor-paged workflow listings and incremental detail reads (journal, steps,
  children, awakeables) that a browser UI needs beyond the one-shot keiro-ops wf output, in
  the owning library first, so the durable-execution screens can render and refresh
  incrementally against the keiro_workflows wake ledger.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-30
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Complete Workflow Inspection Primitives for HTTP

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`).
Companion to `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`, which serves
whatever primitives exist; this request is about the primitives that do not exist yet in the
shape a UI needs. Implementation is keiro's downstream work.

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
