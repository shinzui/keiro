---
type: Architecture Decision Record
title: Catalog fingerprints are canonical and rebuild lifecycle identity is slice-scoped
description: Keiro hashes injective canonical preimages, uses group slices for rebuild lifecycle compatibility, pins adapter application order in replay contracts, retains whole-catalog provenance, and requires explicit transactional adoption of reviewed slice changes.
timestamp: 2026-08-13T03:15:22Z
docId: ADR-32
status: Accepted
date: 2026-08-12
originatingPlan: docs/plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md
---

# 32. Catalog fingerprints are canonical and rebuild lifecycle identity is slice-scoped

Date: 2026-08-12

Status: Accepted


## Context

Projection catalog fingerprints are persisted compatibility boundaries, not
display-only summaries. The original renderer joined nested text with ordinary
delimiters. Delimiter-bearing values could therefore make distinct inventories
produce the same hash preimage. That made the fingerprint unsuitable as an
identity even though SHA-256 itself remained collision-resistant.

The original group registry and replay contract also used the fingerprint of
the complete catalog. Adding an unrelated source, target, group, or query model
changed that fingerprint and refused registration or resume for every existing
group. The lifecycle fence was broader than the state and replay facts it
protected.

Changing a real group slice must still be deliberate. It may invalidate
application-owned rows or move query registration metadata, and it must not be
silently accepted merely to make startup pass. Pre-canonical persisted values
also need a supported clean-break recovery path before the unreleased 0.12
format becomes stable.


## Decision

Keiro hashes a typed canonical preimage tree. Text nodes encode their UTF-8 byte
length before their bytes; list and record nodes encode a distinguishing tag,
child count, and recursively encoded children. Every structural boundary is
therefore recoverable without delimiter escaping. Whole-catalog fingerprints
use the `catalog-v3:` prefix and group-slice fingerprints use `slice-v2:`.
Prefix changes are mandatory when the canonical identity contract changes.

A group slice contains only the normalized catalog facts that can affect that
group's preparation, writers, query bindings, replay adapters, sources, and
verification. Group registration stores the slice fingerprint. Begin, finish,
abandon, completion proof, active-run locking, and resume compatibility compare
the stored group slice, not the complete catalog. Adding an unrelated group is
therefore compatible, while changing a source codec, target, projection,
query-registration fact, reset identity, or verification in the selected group
still produces typed drift.

The query-to-supplying-projection relation is derived from facts already present in
these preimages: each target's projection owner plus each query's rebuild group and
observed-target set. The normalized `ResolvedQuerySupply` view is not serialized as a
second fingerprint field. Changing an authoritative owner or observed-target fact still
changes the owning catalog/group identity, while merely adding or reading the derived
accessor changes no fingerprint or format prefix.

The v3/v2 revision normalizes a projection declaration's set-valued owned targets and
adds each query's normalized freshness plus optional resolved subscription identity to
the whole catalog and owning group slice. Immediate query models serialize no cursor
when none is unambiguously available. Waiting query models serialize the one cursor
derived from their validated owner; missing or ambiguous candidates fail validation and
never reach fingerprinting. Reordering owned targets is therefore identity-neutral,
while changing freshness or resolved cursor changes the whole catalog and only the
owning group slice.

The complete catalog fingerprint remains useful provenance. A replay run stores
both the whole catalog fingerprint and the group slice that owns its lifecycle.
The persisted runner format is `keiro/projection-replay/v4`; its `contract-v4:` value is
derived from the group slice, the runner format, and the ordered replay-adapter identity
sequence. Each adapter identity is its source id and projection id in application order.
Application order is deliberately excluded from the group slice: reordering projection
declarations preserves registration and group identity, but refuses resume of an
interrupted run because its already-applied prefix used the retired order. Abandonment
requires only group-slice identity because it applies no adapter effects. Inspection and
joins use the slice for compatibility and expose the whole catalog value without treating
it as a fence.

Catalog evolution uses an explicit preview-then-adopt API. Preview classifies
catalog groups as new, unchanged, slice-changed, or stale-format and lists
registered non-legacy groups absent from the new catalog. Adoption accepts a
non-empty set of reviewed group IDs, sorts and deduplicates them, locks and
validates the entire set before updating anything, requires every row to be
registered and `live`, then updates group slices and reconciles bound query
model version, shape, and group metadata in one transaction. An unchanged
group is a successful idempotent outcome. Adoption never changes
application-owned tables and never starts a rebuild.

The embedded `keiro-ops rebuild adopt GROUP...` command wraps those library
operations. Without `--force` it is read-only, shows stored and current slices,
and prints the exact force invocation. With `--force` it reports the library's
actual adopted rows. The standalone binary cannot mount the command because it
does not contain the application's validated catalog.

Migration `0024` is a pre-0.12 clean break. It renames the group column to
`slice_fingerprint` and records `group_slice_fingerprint` on runs. Operators
must complete or abandon active catalog rebuilds before applying it because the
migration cannot infer an old run's precise slice. A pre-canonical group row is
then refused at registration until an operator previews and explicitly adopts
the current catalog slice.

The v3/v2 identity cutover reuses that same reviewed adoption workflow. A stored
`slice-v1:` value is stale-format and must be previewed and adopted while the group is
`live`. An active replay written as `keiro/projection-replay/v2` cannot be resumed by the
v3 runner or adopted in place; operators complete it with the old runtime or explicitly
abandon it before upgrading, then preview and adopt the live group metadata.

The v4 contract revision adds replay-adapter application order without changing catalog
or group-slice identity. Stored `contract-v3:` values and
`keiro/projection-replay/v3` runs are refused on resume by the v4 runner. Because the
0.12 formats remain unreleased, there is no migration: complete a persisted run with the
old runtime or abandon it. Abandon compares slices, so it remains available across this
contract break when the catalog's group slice is unchanged.


## Consequences

- SHA-256 receives an injective serialization of the catalog tree rather than
  an ambiguous display rendering.
- Unrelated additive catalog evolution neither rewrites existing group identity
  nor strands an interrupted replay.
- Genuine group changes and stale persisted formats remain visible typed
  startup or rebuild errors; the runtime never auto-adopts them.
- Adoption is metadata coordination, not data migration. Operators separately
  decide whether application rows require a schema migration or rebuild.
- Query models moving between groups require coordinated review of every
  affected group; ordinary registration continues to expose any half-adopted
  move as drift.
- Catalog and slice prefixes, replay format, and migration evidence make future
  identity changes explicit rather than silently reinterpreting stored hashes.
- Replay-adapter application order is in-flight replay identity, not group identity;
  order swaps never strand registration or a fresh rebuild but always refuse resume of
  an interrupted run.
- Derived supplier lookup adds no duplicate owner edge, but normalized query freshness
  and the cursor selected from that relationship are explicit query-binding identity.


## Alternatives considered

- Escape the existing delimiters. Rejected because every current and future
  field site would need perfect agreement on an escaping discipline.
- Keep whole-catalog identity as every group's fence. Rejected because it turns
  unrelated additive declarations into fleet-wide downtime and replay lockout.
- Automatically overwrite changed fingerprints during registration. Rejected
  because startup cannot prove that persisted application rows remain valid.
- Derive old active-run slices during migration. Rejected because the database
  does not contain the complete historical catalog needed to reconstruct them.


## References

- [ADR 0026](0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
  defines the catalog identities and group lifecycle whose compatibility scope
  this decision narrows.
- [ADR 0028](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  requires the adoption command to wrap the supported library transaction.
- [ADR 0031](0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md)
  makes missing-checkpoint policy one of the group-slice replay facts.
- [ExecPlan 237](../plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md)
  implements and verifies this decision.
- [ExecPlan 244](../plans/244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md)
  implements and verifies the v3/v2 freshness, cursor, and owned-target normalization
  revision.
- [ExecPlan 245](../plans/245-separate-language-5-projection-delivery-from-query-freshness.md)
  populates those normalized freshness/cursor facts from checked Language 5 source and proves
  delivery and freshness evolution remain distinct.
