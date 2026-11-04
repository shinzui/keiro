---
type: Improvement Request
title: Count workflow instances by status class
description: >-
  `/wf/inspect/list` pages instances but nothing counts them, so a dashboard can only sample a
  page and mark counts as lower bounds. Add a bounded read returning the instance count per
  status class, optionally filtered by workflow name.
timestamp: 2026-11-04T05:28:05Z
requestId: IR-58
status: accepted
origin: mori://shinzui/keiro-ui
plan: docs/plans/325-count-workflow-instances-by-status-class-without-runtime-performance-regressions.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-11-04T05:28:05Z
    document_timestamp: 2026-11-04T05:28:05Z
    scope: status-and-plan-links
    outcome: commented
    provider: openai
    model: unspecified
    effort: unspecified
    context: >-
      Checked Plan 325 progress and the absence of the requested counting API. Linked the plan
      and recorded accepted status; implementation and performance acceptance remain open.
      Documentation audit against the working tree and retained evidence; no runtime
      suite was rerun for this audit.
---

# Improvement Request: Count Workflow Instances by Status Class

## Status

Accepted for implementation under
[ExecPlan 325](../plans/325-count-workflow-instances-by-status-class-without-runtime-performance-regressions.md).
All three implementation milestones remain open: the million-instance query proof, the
library/CLI/HTTP integration, and matched runtime-performance acceptance. No counting API
has been delivered yet.

Originally proposed by the keiro runtime console initiative
(`mori://shinzui/keiro-ui/masterplans/2-build-the-keiro-runtime-console`), filed from
`mori://shinzui/keiro-ui/plans/17-build-the-projections-and-overview-screens`.
An improvement, not a dependency.

## Context

`keiro-ops wf inspect list` derives each instance's status class (`statusClassOf` in
`keiro/src/Keiro/Workflow/Inspection.hs`) and pages with keyset cursors. An operator's first
question about workflows, "how many are running, retrying, failed", needs either every page or a
sample. Seven filtered list requests per refresh would cost more than one counting query over
`keiro_workflows`.

## Console behaviour today

The Overview's Workflows card reads the newest 500 instances in one request and counts them by
class. When a further page exists it marks every count with "+" and prefixes "newest 500
instances:", so the numbers are honest lower bounds. The Workflows list itself is unaffected.
With this read, the card would show exact counts.

## Requested Change

1. `keiro-ops wf inspect counts [--workflow-name NAME]` returning
   `{observed_at, counts: {running, retrying, sleeping, awaiting, completed, cancelled, failed}}`,
   computed with the same classification as the list.
2. Served as `GET /wf/inspect/counts`, inside the inspection budget and statement timeout like the
   other reads.

## Acceptance

1. On the jitsurei database the counts equal the class totals of a full paging of
   `/wf/inspect/list`.
2. The read stays within the inspection statement timeout on a table of a million instances
   (an index-backed aggregate, documented in the guide).
