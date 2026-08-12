---
type: Architecture Decision Record
title: Consistency waits target reachable visible heads
description: Keiro targets whole-store consistency waits and projection distance at the newest visible event while retaining the authoritative append counter for capacity and audit reporting.
timestamp: 2026-08-12T18:51:10Z
docId: ADR-33
status: Accepted
date: 2026-08-12
originatingPlan: docs/plans/238-target-strong-consistency-waits-at-the-visible-store-head.md
---

# 33. Consistency waits target reachable visible heads

Date: 2026-08-12

Status: Accepted


## Context

Kiroku exposes two different whole-store positions. Its subscription checkpoint
inventory reports the authoritative `$all` append counter from the `streams` row.
Hard deletion removes event rows but deliberately does not decrement that counter.
The newest visible event is instead the greatest `$all` position still present in
`stream_events`, or zero when no event remains.

Subscription checkpoints advance at delivered batch tails. An empty fetch delivers
nothing and therefore cannot advance a checkpoint to an authoritative position whose
event has been hard-deleted. After workflow garbage collection deletes the newest
journal stream, a fully caught-up subscription can consequently remain below the
authoritative counter forever on an otherwise idle store. Using that counter as a
Strong read target caused every query to wait five seconds and return
`ReadModelWaitTimeout`; using it for projection distance also reported permanent work
that no consumer could perform.

The inventory remains correct and valuable. Its member rows are the authority for
durable consumer progress, and its store counter records append capacity and audit
history. The defect came from asking that counter to serve as a reachable event
boundary.


## Decision

A consistency wait target must be reachable by the consumer being observed. Keiro's
whole-store captured-head waits therefore target the newest visible `$all` event:
`COALESCE(max(stream_version), 0)` from `stream_events` where `stream_id = 0`.
`storeHeadPosition` keeps its released public name and returns that visible position;
Keiro does not export a second authoritative-head wrapper because Kiroku's
`subscriptionCheckpointInventory` already exposes the counter directly.

Kiroku 0.6 owns this query through its public
`Kiroku.Store.Read.visibleGlobalHeadPosition` effect operation, and Keiro's
`storeHeadPosition` delegates to it. The transaction-composable rebuild-completion guard
uses Kiroku's public `Kiroku.Store.SQL.visibleGlobalHeadPositionStmt`, so both paths share
the same basis without duplicating dependency-owned SQL. This preserves the semantic
contract established against Kiroku 0.5 while moving schema knowledge back to its owner.

Each Strong or `WaitForHead EntireVisibleLog` query captures the visible head once and
waits for its durable cursor to reach that position. Category-scoped waits continue to
capture the newest visible event in their category. Checkpoints remain monotonic under
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`, so a later reduction of the visible
head cannot regress the observed cursor. If an event is deleted after capture before a
genuinely behind consumer sees it, the bounded wait may still time out; that is honest
because the consumer was behind by at least the garbage-collection retention window.

Projection global position distance uses the same visible whole-store head and clamps
at zero when a durable checkpoint is above a head that regressed through deletion. The
deprecated `keiro.projection.lag` gauge records the identical compatibility value.

Operator commands report both truths. `store_position` is Kiroku's authoritative append
counter, `visible_store_head` is the reachable event boundary, and every
`global_position_distance` value is computed from the visible head. This uses the
supported Keiro and Kiroku APIs required by
[ADR 0028](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md).


## Consequences

- A caught-up whole-store read returns promptly after tail hard-deletion, while a
  genuinely behind read still waits and times out against the visible event target.
- Projection distance reaches zero when no visible work remains, so alerts do not stay
  red because of positions that no subscription can consume.
- Operators can distinguish deleted-tail history from actionable consumer distance by
  comparing `store_position` with `visible_store_head`.
- `subscriptionCheckpointInventory` remains the only authority for member-aware cursor
  floors and the authoritative append counter. Keiro does not query or mutate Kiroku's
  private checkpoint state.
- The visible head can move backward after deletion. This is safe because each wait
  captures one target and checkpoint saves remain monotonic; later queries may capture
  the smaller reachable boundary independently.


## Alternatives considered

- Keep the authoritative append counter as the wait and distance target. Rejected
  because tail deletion can make that position unreachable indefinitely.
- Implement the visible head with `readAllBackward`. Rejected because it fetches and
  decodes the newest event payload on every Strong query, adding unnecessary hot-path
  work and a payload-decoding failure mode to a position lookup.
- Export separate visible and authoritative head functions from Keiro. Rejected because
  `storeHeadPosition` had visible semantics in released Keiro 0.11, while Kiroku's
  public inventory already exposes the authoritative value. A second Keiro wrapper
  would preserve the unreleased regression as an attractive footgun.


## References

- [ADR 0023](0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md)
  provides the workflow lifecycle context in which terminal journal deletion is routine.
- [ADR 0028](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  keeps both operator head values on supported library APIs.
- [ADR 0031](0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md)
  preserves Kiroku-owned member checkpoints and monotonic save semantics.
- `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` owns checkpoint initialization,
  monotonic ordinary saves, and explicit reset.
- `mori://shinzui/kiroku/packages/kiroku-store` owns the public visible-global-head
  effect operation and transaction-composable statement used by this decision.
- [ExecPlan 238](../plans/238-target-strong-consistency-waits-at-the-visible-store-head.md)
  implements and verifies this decision.
