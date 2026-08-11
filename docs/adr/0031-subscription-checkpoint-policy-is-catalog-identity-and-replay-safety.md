---
type: Architecture Decision Record
title: Subscription checkpoint policy is catalog identity and replay safety
description: Keiro fingerprints every explicit missing-checkpoint policy, rejects current-head seeding after a replayable clear, and composes Kiroku-owned checkpoint resets with rebuild preparation.
timestamp: 2026-08-11T18:47:11Z
docId: ADR-31
status: Accepted
date: 2026-08-11
originatingPlan: docs/plans/215-adopt-explicit-checkpoint-lifecycle-semantics-in-the-projection-catalog.md
---

# 31. Subscription checkpoint policy is catalog identity and replay safety

Date: 2026-08-11

Status: Accepted


## Context

Kiroku owns the durable `(subscription name, consumer-group member)` checkpoint and defines what
happens when that exact row is absent. Its decision
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` provides three atomic policies, gives existing rows
precedence, keeps ordinary saves monotonic, and exposes deliberate reset as a transaction
combinator. Keiro owns a different question: whether a declared policy is safe for the projection
target and rebuild lifecycle in one validated catalog.

A replayable projection whose target is cleared before replay needs retained history to reconstruct
that target. If its absent checkpoint were initialized at the current store head, the worker could
skip the very events needed after a clear. Keeping the policy only in worker wiring would also let
startup behavior change without changing the catalog fingerprint, operator inventory, or rebuild
evidence.


## Decision

Every `SubscriptionDeclaration` stores Kiroku's closed `MissingCheckpointPolicy` directly. The
policy is projected through inventory and async registration, rendered with an exhaustive stable
constructor spelling, included in the deterministic catalog fingerprint, and exposed in operator
JSON. Keiro defines local canonical ordering for the upstream type rather than adding an orphan
`Ord` instance or deriving persistent text from `Show`.

Catalog validation rejects `FromCurrentHead` when the subscription feeds a replayable projection
that owns a `ClearBeforeReplay` target. The diagnostic identifies the subscription ID and name,
target ID, policy, reset mode, and claim sites. `FromBeginning` and `FailIfMissing` remain safe for
that target; every explicit policy remains valid for a preserved target. This gate runs before a
validated catalog can reach registration, workers, rebuilds, or operations.

Checkpoint initialization applies only to an absent exact member row. An existing checkpoint
always wins, and changing catalog policy never rewinds or fast-forwards it. Deliberate coordinated
reset calls Kiroku's `resetSubscriptionCheckpointsTx` inside the same transaction as the group
fence, target preparation, and dedup reset. Keiro returns the exact affected member keys and
condemns the entire transaction when any catalog-declared subscription name is missing. It never
creates member rows, deletes checkpoints, infers group topology, or issues private SQL against
Kiroku's table.


## Consequences

- Startup intent is reviewable through the same inventory, fingerprint, and operations surface as
  projection ownership and reset policy.
- Clearing a replayable target cannot combine with a missing-checkpoint choice that silently skips
  retained history.
- Multi-member reset remains Kiroku-owned while target, fence, dedup, and checkpoint changes commit
  or roll back as one Keiro preparation transaction.
- Renaming a subscription or losing a checkpoint remains operationally significant. Operators must
  repair missing state or change the declaration; Keiro does not synthesize topology.
- Changing only `checkpointOnMissing` changes the catalog fingerprint even though the persisted
  subscription/member identity is unchanged.


## Alternatives considered

- Keep policy only in worker configuration. Rejected because catalog and operator evidence could
  drift from startup behavior.
- Default every Keiro declaration to `FromBeginning`. Rejected because an implicit fallback hides
  future-only and strict-startup intent; candidate Language 5 can require the field before release.
- Permit `FromCurrentHead` for every target. Rejected because clearing a replayable target followed
  by head seeding discards reconstructible history.
- Reset through Keiro-owned SQL or create missing member rows. Rejected by schema ownership and
  because a subscription name does not authoritatively describe runtime group members.


## References

- [ADR 0004](0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) keeps runtime and
  candidate-language validation at the earliest sound boundary.
- [ADR 0026](0026-projection-catalogs-separate-query-target-group-and-handler-identities.md) makes
  the catalog the shared runtime and operations authority.
- [ADR 0028](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  requires Keiro operations to call the owning library's public API.
- `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` owns absent-row initialization, existing-row
  precedence, monotonic save, and explicit reset semantics.
- [ExecPlan 215](../plans/215-adopt-explicit-checkpoint-lifecycle-semantics-in-the-projection-catalog.md)
  implements this decision.
