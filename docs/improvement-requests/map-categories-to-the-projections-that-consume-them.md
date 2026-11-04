---
type: Improvement Request
title: Map categories to the projections that consume them
description: >-
  Nothing in the ops surface says which projection groups consume a stream category, so an
  aggregate browser cannot show which read models an aggregate's events feed. Expose, per
  projection group, the categories its subscription reads (or a reverse lookup by category).
timestamp: 2026-11-04T05:28:05Z
requestId: IR-59
status: proposed
origin: mori://shinzui/keiro-ui
plan: docs/plans/324-map-categories-to-projection-and-durable-subscription-consumers.md
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
      Checked all four open Plan 324 milestones and its explicit instruction to retain proposed
      status until acceptance. Linked that plan without claiming implementation.
      Documentation audit against the working tree and retained evidence; no runtime
      suite was rerun for this audit.
---

# Improvement Request: Map Categories to the Projections That Consume Them

## Status

Proposed, with implementation planned in
[ExecPlan 324](../plans/324-map-categories-to-projection-and-durable-subscription-consumers.md).
All four milestones remain open. The plan chooses a pure reverse lookup over mounted
catalog/subscriber metadata and explicitly retains this request's proposed disposition
until acceptance; creating the plan did not deliver the lookup.

Proposed by the keiro runtime console initiative
(`mori://shinzui/keiro-ui/masterplans/2-build-the-keiro-runtime-console`), filed from
`mori://shinzui/keiro-ui/plans/16-build-the-aggregates-process-managers-and-timers-screens`. An
improvement, not a dependency.

## Context

An operator inspecting an aggregate wants to know which read models its events reach, for
example to understand why a query model is stale after an aggregate changed. keiro knows each
projection's subscription and that subscription's category filter at registration time; neither
`/projection/status` nor `/aggregate/show` reports it.

## Console behaviour today

The aggregate browser shows the aggregate's category and links to the Projections section with
the sentence "keiro exposes no per-category projection mapping"; the operator scans the groups
there. The console does not guess consumers from names. With this read, the browser would list
the consuming groups with their global position distance beside the aggregate.

## Requested Change

1. The categories each projection group's subscription consumes, either as a field on the
   projection status row (additive, ADR-35) or as `projection consumers --category NAME`
   (`GET /projection/consumers?category=`).
2. The same for process managers and other durable subscribers if the registration knows them.

## Acceptance

1. For jitsurei, the order category reports `jitsurei-order-reporting` among its consumers.
2. A category no projection reads answers an empty list, not an error.
