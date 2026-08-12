---
type: Architecture Decision Record
title: Catalog fingerprints are canonical and rebuild lifecycle identity is slice-scoped
description: Keiro hashes injective canonical preimages, uses group slices for rebuild lifecycle compatibility, retains whole-catalog provenance, and requires explicit transactional adoption of reviewed slice changes.
timestamp: 2026-08-12T13:30:39Z
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
use the `catalog-v2:` prefix and group-slice fingerprints use `slice-v1:`.
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

The current `catalog-v2`/`slice-v1` contract preserves a projection declaration's owned
target order even though supplier resolution treats that set order-independently.
Normalizing that existing preimage is an identity-contract change and therefore requires
a future prefix revision and explicit adoption evidence; it must not be repaired silently
under the current prefixes.

The complete catalog fingerprint remains useful provenance. A replay run stores
both the whole catalog fingerprint and the group slice that owns its lifecycle.
The persisted runner format is `keiro/projection-replay/v2`; its contract is
derived from the group slice plus normalized runner facts. Inspection and joins
use the slice for compatibility and expose the whole catalog value without
treating it as a fence.

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
- Derived supplier lookup adds no independent identity field. Any future normalization
  of existing owned-target ordering must advance the applicable prefixes.


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
