---
type: Improvement Request
title: Name the feeding subscription on projection status rows
description: >-
  `/projection/status` rows carry each group's serving position but not the durable subscription
  that feeds the group, so a UI cannot join a group to its member checkpoints without being told
  the subscription name. Publish the sorted feeding subscription names beside the frozen
  projection_group_status_v1 row on bounded status pages and feeds.
timestamp: 2026-11-04T18:02:00Z
requestId: IR-57
status: accepted
plan: docs/plans/327-name-the-feeding-subscriptions-on-projection-status-pages-without-runtime-performance-regressions.md
origin: mori://shinzui/keiro-ui
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
      Confirmed the frozen projection status reader and JSON encoder still lack
      feeding_subscription. No implementing plan exists; proposed remains correct.
      Documentation audit against the working tree and retained evidence; no runtime
      suite was rerun for this audit.
---

# Improvement Request: Name the Feeding Subscription on Projection Status Rows

## Status

Accepted under [ExecPlan 327](../plans/327-name-the-feeding-subscriptions-on-projection-status-pages-without-runtime-performance-regressions.md).

Originally proposed by the keiro runtime console initiative
(`mori://shinzui/keiro-ui/masterplans/2-build-the-keiro-runtime-console`), filed from
`mori://shinzui/keiro-ui/plans/17-build-the-projections-and-overview-screens`. An improvement,
not a dependency.

## Context

`keiro_read.projection_group_status_v1` (read by `keiro-ops projection status`,
`keiro/src/Keiro/ReadModel/Rebuild/Status.hs`) gives each group's lifecycle, serving position,
and rebuild state. `projection position --subscription` gives a subscription's member checkpoints
and its maximum global position distance. Nothing connects the two: the status row does not say
which subscription feeds the group. The frozen contract
(`mori://shinzui/keiro/okf/adrs/concepts/ADR-35`) forbids extending the v1 relation. Registration metadata must travel beside it.

## Console behaviour today

The projection group page states that keiro does not expose the feeding subscription and lets
the operator choose one: it offers the durable subscriptions kiroku's checkpoint inventory knows
and accepts a typed name, then shows that subscription's members and distance. It never assumes
a group and a subscription share a name. With this field, the page would show the feeding
subscription's checkpoints without asking.

## Requested Change

Publish `feeding_subscriptions`, a sorted array of registered durable subscription names,
on each bounded projection status item and `projection_groups` feed item. Keep the frozen
v1 SQL relation unchanged. Inline-only (`append`) groups have an empty array. Unmanaged
groups also have an empty array because their authority is unknown; the console must retain
its manual chooser for them. Multiple subscriptions are supported.

## Acceptance

For jitsurei, `GET /projection/status` reports
`"feeding_subscriptions":["jitsurei-order-audit-subscription"]` on
`jitsurei-order-reporting` and `[]` on `$legacy-read-model:*` groups. The CLI and feed
publish the same field. Removing it yields exactly the previous JSON keys and values;
the frozen SQL relation retains its ordered column signature. Paired page-read and runtime
interference evidence must satisfy ExecPlan 327 without moving benchmark baselines.
