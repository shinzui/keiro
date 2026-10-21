---
type: Improvement Request
title: Name the feeding subscription on projection status rows
description: >-
  `/projection/status` rows carry each group's serving position but not the durable subscription
  that feeds the group, so a UI cannot join a group to its member checkpoints without being told
  the subscription name. Add the feeding subscription (or null when none) to
  projection_group_status_v1 or alongside it.
timestamp: 2026-10-21T23:30:00Z
requestId: IR-57
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Name the Feeding Subscription on Projection Status Rows

## Status

Proposed by the keiro runtime console initiative
(`mori://shinzui/keiro-ui/masterplans/2-build-the-keiro-runtime-console`), filed from
`mori://shinzui/keiro-ui/plans/17-build-the-projections-and-overview-screens`. An improvement,
not a dependency.

## Context

`keiro_read.projection_group_status_v1` (read by `keiro-ops projection status`,
`keiro/src/Keiro/ReadModel/Rebuild/Status.hs`) gives each group's lifecycle, serving position,
and rebuild state. `projection position --subscription` gives a subscription's member checkpoints
and its maximum global position distance. Nothing connects the two: the status row does not say
which subscription feeds the group. The frozen contract
(`mori://shinzui/keiro/okf/adrs/concepts/ADR-35`) means the field would be additive.

## Console behaviour today

The projection group page states that keiro does not expose the feeding subscription and lets
the operator choose one: it offers the durable subscriptions kiroku's checkpoint inventory knows
and accepts a typed name, then shows that subscription's members and distance. It never assumes
a group and a subscription share a name. With this field, the page would show the feeding
subscription's checkpoints without asking.

## Requested Change

1. A `feeding_subscription` field (text, nullable) on each projection status row, from the
   projection's registration, null for groups without a durable subscription (legacy or
   unmanaged groups).
2. The field also in the `projection_groups` feed items, which reuse the row encoder.

## Acceptance

1. For jitsurei, `GET /projection/status` reports `feeding_subscription:
   "jitsurei-order-reporting"` on that group and null on the `$legacy-read-model:*` groups.
2. Existing fields and their order are unchanged (ADR-35).
