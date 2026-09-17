---
type: Architecture Decision Record
title: Nominal declarations are structural leaves with Keiro-owned admission
description: Candidate Language 6 preserves declared nominal domain types inside structural shapes while generated leaf codecs retain TypeID and scalar admission authority across aggregate, queue, and query roots.
timestamp: 2026-09-17T17:16:09Z
docId: ADR-46
status: Accepted
date: 2026-09-17
originatingPlan: docs/plans/287-support-nominal-ids-inside-structural-mapped-types.md
---

# Nominal declarations are structural leaves with Keiro-owned admission

## Context

Structural mapped declarations previously resolved references only to other mapped
declarations. A declared ID or nominal scalar could be used directly by an aggregate but not
inside a structural record, union, or container. Consumers preserved the desired Haskell ID
type by declaring an opaque twin and sometimes another opaque optional wrapper. That transferred
JSON authority to consumer instances, prevented nested prefix admission from being checked, and
made otherwise structural persisted roots fail opaque-coverage gates.

Lowering a nominal to `Text` would make the source check but erase its Haskell identity and the
declared TypeID-v7 or scalar contract. Calling arbitrary consumer `ToJSON` and `FromJSON`
instances would create the second schema authority rejected by ADR-12. The structural graph,
coverage, fold identity, and compatibility reports must all observe the same nominal leaf.

## Decision

Candidate Language 6 adds the `StructuralNominalLeaves` runtime capability. A checked structural
type expression may resolve a generated or consumer-bound `id`, or a consumer-bound
`mapped nominal` scalar, as a nominal leaf. The resolved leaf carries its declaration name,
representation, canonical identity, ownership, binding provenance, and ID-domain facts. The
generated structural shape uses the nominal domain type itself: for example, a field declared
as `ClaimId` has Haskell type `ClaimId`, not `KindID "claim"` or `Text`.

One context-owned generated `Structural.NominalLeaves` module supplies leaf encoders and parsers
to generated structural, aggregate, and queue codecs. Generated IDs use their existing checked
API. Consumer-bound IDs parse through Keiro's canonical TypeID-v7 admission before their total
nominal binding runs. Nominal scalars convert through their declared exact representation
binding. Consumer JSON instances never become the leaf wire authority. Query contracts reuse
the checked nominal type and import authority but emit no JSON codec or leaf helper when they
are the leaf's only consumer.

The structural wire fingerprint token is `nominal-id(<prefix>,<domain>)` for an ID and
`nominal-scalar(<representation>)` for a scalar. Binding symbols, binding versions, and Haskell
source names remain build and snapshot provenance rather than wire identity. Nested event and
register fold surfaces include representation, canonical identity, and consumer-binding facts;
fixture-only changes remain outside fold identity.

Nominal leaves are also accepted directly at typed workqueue fields and read-model query
input/result expressions. These roots share the same checked type, import, codec, coverage, and
diff authorities. Query consequences remain build-only. Workqueue changes retain queue-history
rollout semantics. A nominal nested in a structural register does not acquire the nominal
declaration's `initial` obligation because the structural register's own initial constructs the
complete value.

Generated and consumer-bound nominal enums are excluded. A nested enumeration must use
`mapped structural enum`, whose constructor/default and branch-coverage contract is already
explicit. Refined scalars, typed map keys, and arbitrary expression projection through nested
nominals remain outside this decision.

Replacing `Text` or an opaque twin with a nominal leaf is conservatively
`MappedFieldTypeChanged` at every affected root. A historical codec comparison over explicit
old-codec samples may establish valid-byte parity and malformed-ID rejection, but that evidence
does not itself waive event versioning, queue drains or transitional decoders, snapshot rebuilds,
or consumer recompilation. Prefix, domain, representation, binding, fixture, and canonical-type
changes retain their existing nominal finding codes and now carry complete structural contexts.

## Consequences

Natural consumer records can retain nominal IDs through nested records, unions, `Optional`,
`List`, and text-keyed `Map` values without an opaque boundary. Optional absence remains JSON
null while every present ID remains canonical non-null text. Shared workspace declarations have
one consumer owner and one context codec authority even when member-owned structural records use
the ID independently.

Coverage report schema 1 gains an append-only `nominalBoundaries` inventory. Nominal-only queue
and query roots count as structural and do not fabricate opaque boundaries. Structural
conformance runs consumer nominal laws once, while generated-ID fixture paths additionally pin
canonical encoded text.

Published Languages 1 through 5 remain unchanged. This is preview support until Language 6 is
published and downstream adoption/replay evidence exists; implementation completion alone does
not make IR-40 a supported production capability.

## References

- [ADR-12](0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
- [IR-40](../improvement-requests/support-nominal-ids-inside-structural-mapped-types.md)
- [ExecPlan 287](../plans/287-support-nominal-ids-inside-structural-mapped-types.md)
