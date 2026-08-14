---
type: Architecture Decision Record
title: Subscription checkpoint policy is catalog identity and replay safety
description: Keiro fingerprints every explicit missing-checkpoint policy, rejects unsafe head seeding, and brackets catalog replay with atomic dedup and checkpoint restoration.
timestamp: 2026-08-14T06:53:09Z
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

Candidate Keiro DSL Language 5 requires exactly one `checkpoint-on-missing` clause on every
subscription projection owner and forbids the clause on inline owners. Its closed source spellings
`from-beginning`, `from-current-head`, and `fail` lower directly to Kiroku's three constructors;
there is no compatibility default because Language 5 remains unreleased. The DSL repeats the
runtime replay-safety gate before scaffolding so an unsafe source fails at the earliest boundary,
while runtime validation continues to protect hand-written and stale generated catalogs.

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

Catalog rebuild promotion restores the other half of this replay-safety boundary. After replay and
verification succeed, Keiro reads each declared subscription's durable floor (the minimum across
its persisted consumer-group members) and pages source history protected from hard deletion for
the active run over the interval @(floor, captured head]@. For each replayable async projection it derives the event identity through
that projection's own `idempotencyKey`, then backfills `keiro_projection_dedup` and advances every
persisted member of the declared subscriptions to the captured head through the same Kiroku exact-
position reset primitive used by preparation. The inserts, checkpoint advance, completion proof,
and group transition to live commit in one transaction. A missing declared row condemns promotion
with typed evidence and leaves the run resumable; Keiro still never invents checkpoint topology.
Inline-only groups skip this work.

Projection revisions preserve that same delivery identity. A revision's subscription
handler names its projection, subscription, and dedup key, and the async path invokes
only that handler after claiming the corresponding event identity. Inline command
dispatch cannot execute the subscription closure or create its dedup evidence. This is
required even when application SQL happens to be idempotent: handler idempotence cannot
substitute for the declared delivery and retained redelivery authority.

An online schema-versioned rebuild applies the same rule at its captured final head.
Candidate replay does not rewind the live subscription while V1 continues serving.
Instead, each replay chunk incrementally stages its async redelivery keys in a
run-scoped database relation. Before the writer fence, Keiro prunes keys already below
durable subscription floors and refuses if the staged count plus the bounded tail could
exceed the run's persisted promotion limit. After the fence captures the final head,
tail replay adds only the remaining bounded keys.

A durable preparation transaction rechecks the exact staged count, installs ordinary
async dedup keys set-wise, advances every declared member, and releases the history
lease before target relations are locked. The group stays write-fenced and records
that preparation completed. A later short promotion transaction swaps all candidate
generations and the serving revision. A missing member, expired lease, or failed
preparation rolls its transaction back; a failed lock attempt after preparation leaves
the prepared evidence and checkpoint state intact and the group fenced for resume or
explicit abandonment. V2 is never exposed with skipped delivery evidence.

Targeted per-stream reprojection uses the same deduplication rule with a different
checkpoint consequence. While holding the group exclusively, it replays one complete
retained stream into the persisted serving projection revision and inserts that
projection's ordinary deduplication keys for every replayed event in the repair
transaction. It does not advance the shared subscription checkpoint because doing so
could skip unrelated streams. Later delivery observes the dedup rows, performs no
projection effect, and checkpoints through the ordinary worker path.

A policy-only DSL change emits `CatalogCheckpointPolicyChanged`. Its compatibility vector marks the
generated consumer build breaking and requires stop-the-world operational review, but marks
persisted subscription identity compatible. Text and JSON include the old and new policy; catalog
replay impact names the affected group, targets, source, and adapter. Existing rows remain
authoritative and do not move merely because source policy changed.

Under [ADR 0032](0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md),
the policy changes the slice of every group that owns the subscription, but not unrelated groups.
Registration refuses the changed slice until an operator reviews and explicitly adopts it; adoption
does not itself reset a checkpoint or rebuild application data.


## Consequences

- Startup intent is reviewable through the same inventory, fingerprint, and operations surface as
  projection ownership and reset policy.
- Clearing a replayable target cannot combine with a missing-checkpoint choice that silently skips
  retained history.
- Multi-member reset remains Kiroku-owned while target, fence, dedup, and checkpoint
  changes commit or roll back at each boundary: offline preparation rewinds while
  fenced; online versioned preparation installs bounded staged dedup and advances every
  member durably before the short atomic generation promotion returns the group live.
- Async application remains exactly-once per retained dedup window across an offline catalog
  rebuild, including an in-flight delivery parked on the rebuild fence. Idempotent handler SQL is
  still useful defense in depth after operator pruning moves an event outside that window.
- Targeted stream repair also treats deduplication as correctness state. It backfills
  affected keys atomically and leaves shared checkpoints unchanged; handler idempotence
  alone is not sufficient repair evidence.
- Rebuild code may call history at or below a captured head immutable only while an
  owner-provided retention or hard-delete serialization guarantee is active.
- Renaming a subscription or losing a checkpoint remains operationally significant. Operators must
  repair missing state or change the declaration; Keiro does not synthesize topology.
- Changing only `checkpointOnMissing` changes the catalog fingerprint even though the persisted
  subscription/member identity is unchanged. More precisely, it changes the affected group slice
  and whole-catalog provenance while leaving unrelated group slices stable.
- Candidate Language 5 cannot omit or default the policy, and evolution tooling does not conflate a
  policy change with a subscription rename or checkpoint mutation.


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
- [ADR 0032](0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md)
  defines canonical group-slice identity and explicit adoption of reviewed policy changes.
- `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` owns absent-row initialization, existing-row
  precedence, monotonic save, and explicit reset semantics.
- [ExecPlan 215](../plans/215-adopt-explicit-checkpoint-lifecycle-semantics-in-the-projection-catalog.md)
  implements this decision.
- [ExecPlan 216](../plans/216-generate-and-classify-missing-checkpoint-policy-in-candidate-language-5.md)
  implements the candidate-language and evolution-tooling boundary.
- [ExecPlan 258](../plans/258-make-catalog-rebuild-promotion-redelivery-safe-for-async-projections.md)
  restores async redelivery safety at catalog rebuild promotion.
- [ADR 0034](0034-online-projection-rebuilds-use-schema-versioned-target-generations.md)
  requires source-retention evidence for online candidate replay and cutover.
- [ExecPlan 257](../plans/257-add-targeted-per-stream-reprojection-to-catalog-operations.md)
  applies the deduplication rule to one-stream transactional repair without advancing
  a shared checkpoint.
