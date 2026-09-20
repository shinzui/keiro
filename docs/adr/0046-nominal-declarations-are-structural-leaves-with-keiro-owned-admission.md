---
type: Architecture Decision Record
title: Nominal declarations are structural leaves with Keiro-owned admission
description: Candidate Language 6 preserves declared nominal domain types and explicit versioned ID admission inside structural shapes while generated leaf codecs retain TypeID, scalar, and declared-enum spelling authority across aggregate, queue, contract, and query roots.
timestamp: 2026-09-20T14:34:41Z
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
type expression may resolve a generated or consumer-bound `id` or `enum`, or a consumer-bound
`mapped nominal` scalar, as a nominal leaf. The resolved leaf carries its declaration name,
representation, canonical identity, ownership, binding provenance, and ID-domain facts. The
generated structural shape uses the nominal domain type itself: for example, a field declared
as `ClaimId` has Haskell type `ClaimId`, not `KindID "claim"` or `Text`.

One context-owned generated `Structural.NominalLeaves` module supplies leaf encoders and parsers
to generated structural, aggregate, and queue codecs. Generated IDs use their existing checked
API. Consumer-bound IDs parse through the declaration's Keiro-owned canonical TypeID admission before their total
nominal binding runs. Nominal scalars convert through their declared exact representation
binding. Generated enums encode through their generated declared-spelling function and parse
only their declared wire spellings. Consumer-bound enums convert through their nominal binding
and a generated representation whose parser and encoder own those same spellings. Consumer JSON
instances never become the leaf wire authority. Query contracts reuse
the checked nominal type and import authority but emit no JSON codec or leaf helper when they
are the leaf's only consumer.

A candidate Language 6 named bare container uses the same resolved expression algebra, so nominal
leaves retain Keiro-owned admission inside direct lists, text-keyed maps, and optional positions.
Naming the container does not create a nominal codec boundary: its direct shape codec still calls
the generated nominal leaf parser at the nested path, and structural conformance pins canonical
text for both the bare declaration and any record that references it.

The structural wire fingerprint token is `nominal-id(<prefix>,<domain>)` for an ID and
`nominal-scalar(<representation>)` for a scalar; enums use
`nominal-enum(<sorted-wire-spellings>)`. Binding symbols, binding versions, and Haskell
source names remain build and snapshot provenance rather than wire identity. Nested event and
register fold surfaces include representation, canonical identity, and consumer-binding facts;
fixture-only changes remain outside fold identity.

Nominal leaves are also accepted directly at typed workqueue fields and read-model query
input/result expressions. These roots share the same checked type, import, codec, coverage, and
diff authorities. Query consequences remain build-only. Workqueue changes retain queue-history
rollout semantics. A nominal nested in a structural register does not acquire the nominal
declaration's `initial` obligation because the structural register's own initial constructs the
complete value.

Public contract event fields may name a declared ID directly. The payload uses the declared
generated or consumer-bound Haskell type while the declaration remains the sole prefix and
TypeID admission authority. Moving between a literal `typeid` and a declaration with the
same prefix preserves JSON bytes but changes the consumer build type; changing the prefix is a
public wire break.

Candidate Language 6 ID declarations may explicitly select the frozen
`keiro-dsl/id-domain/typeid-v5-or-v7/1` contract. Omitting the option preserves
`keiro-dsl/id-domain/typeid-v7/1` and all existing generated tokens, ledgers,
fingerprints, and public behavior. Both domains keep canonical prefixed TypeID
text and RFC variant admission; the wider domain adds only UUIDv5 alongside
UUIDv7. Runtime validation and exact Keiki text evidence use one version/variant
table, so a solver domain cannot silently exclude a runtime-reachable value.
Admission does not choose generation policy or permit regenerating an identity.

The selected domain travels with both the direct nominal representation and a
nested nominal leaf. It therefore enters direct aggregate replay/fold identity,
nested structural wire identity, keyed-map keys, queues, router recipients, and
declared public-contract codecs. Widening is an old-reader/new-writer hazard;
narrowing is a retained-history read hazard. Either direction is a breaking
domain finding and replay-affected. Process and workflow journals, child/timer
identities, stream names, event IDs, and content-derived IDs remain
application-owned and immutable across admission adoption.

Required structural record paths may terminate at nominal IDs, enums, and scalar leaves in
aggregate expressions and declarative router selection. Equality requires the same nominal
declaration. IDs and enums do not gain ordering, and paths still cannot cross `Optional`,
collections, unions, `Json`, or opaque mappings. A router recipient that is a nominal ID keeps
that domain in its checked selection identity.

An optional nominal enum leaf may name a constructor as its `on-missing` default. Generated
defaults construct the domain enum directly; consumer-bound defaults construct the generated
representation and cross the declared nominal binding. Nominal fixtures already cover the enum
arms, so embedding the enum in a structural declaration does not create a duplicate per-field
branch-coverage obligation. Refined scalars and arbitrary expression projection
through optional nominal paths remain outside this decision. Direct aggregate
`Optional <nominal>` fields therefore remain unsupported; their diagnostic directs authors to
a one-field structural record with an optional nominal leaf and `on-missing=null`.

Candidate Language 6 also adds the explicit structural form `Map[Id] Value`. Its JSON object
keys pass through the same nominal ID admission as value-position leaves, and its Haskell shape
is keyed by the ID domain type. Generated IDs supply canonical text ordering. A consumer-bound
ID must provide `Ord` consistent with canonical TypeID text order; structural conformance checks
that obligation over all fixture pairs. Coverage records key position, fold identity includes
key nominal facts, and mapped diff treats a text-keyed map or changed key declaration as a field
type change. Enums, nominal scalars, and mapped declarations cannot be map keys.

Replacing `Text` or an opaque twin with a nominal leaf is conservatively
`MappedFieldTypeChanged` at every affected root. A historical codec comparison over explicit
old-codec samples may establish valid-byte parity and malformed-ID rejection, but that evidence
does not itself waive event versioning, queue drains or transitional decoders, snapshot rebuilds,
or consumer recompilation. Prefix, domain, representation, binding, fixture, and canonical-type
changes retain their existing nominal finding codes and now carry complete structural contexts.

## Consequences

Natural consumer records can retain nominal IDs and enums through nested records, unions,
`Optional`, `List`, and text-keyed `Map` values without an opaque boundary. Optional absence
remains JSON null while every present ID remains canonical non-null text and every enum uses its
declared wire spelling. Shared workspace declarations have one consumer owner and one context
codec authority even when member-owned structural records use the nominal independently.

Coverage report schema 1 gains an append-only `nominalBoundaries` inventory. Nominal-only queue
and query roots count as structural and do not fabricate opaque boundaries. Structural
conformance runs consumer nominal laws once, while generated-ID fixture paths additionally pin
canonical encoded text.

Published Languages 1 through 5 remain unchanged. This is preview support until Language 6 is
published and downstream adoption/replay evidence exists; implementation completion alone does
not make IR-40 or IR-46 a supported production capability.

## References

- [ADR-12](0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
- [IR-40](../improvement-requests/support-nominal-ids-inside-structural-mapped-types.md)
- [ExecPlan 287](../plans/287-support-nominal-ids-inside-structural-mapped-types.md)
- [ExecPlan 288](../plans/288-complete-nominal-id-support-across-contracts-expressions-nested-enums-and-direct-optional-fields.md)
- [ExecPlan 290](../plans/290-support-named-bare-container-structural-mappings-with-transitive-nullability.md)
- [IR-46](../improvement-requests/support-explicit-legacy-id-admission-domains.md)
- [ExecPlan 294](../plans/294-add-explicit-versioned-uuid-admission-domains-with-sound-keiki-evidence.md)
