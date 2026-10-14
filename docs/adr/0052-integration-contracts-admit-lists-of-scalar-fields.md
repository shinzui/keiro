---
type: Architecture Decision Record
title: Integration contracts admit lists of scalar fields
description: Public contracts own ordered arrays of admitted scalars with strict element admission, scalar identity keys, and shape-aware public evolution.
timestamp: 2026-10-14T04:08:20Z
docId: ADR-52
status: Accepted
date: 2026-10-14
originatingPlan: docs/plans/312-support-list-fields-in-integration-contracts.md
---

# Integration contracts admit lists of scalar fields

## Context

[RES-18](../research/15-containers-in-public-contract-fields.md) deferred public
containers until a producer brought a message that cannot be flattened without loss.
[IR-54](../improvement-requests/support-list-fields-in-integration-contracts.md) supplies
that case: `mori://tan/notification-render-service` needs one event to identify every
template changed by one domain operation. Hand-owned codecs lose DSL evolution reporting.

## Decision

Adopt RES-18 Option B restricted to `List` in candidate Language 6. A list element is
one existing contract scalar: literal `typeid "prefix"`, declared `id`, `text`, or `int`.
The separately owned grammar represents scalars and lists of scalars independently,
so nesting is unrepresentable. Optional values, maps, sets, records, unions, and references
to structural mappings remain excluded. This breaks the library's `ContractType` API;
its former constructors belong to `ContractScalarType`, without a compatibility shim.

The writer emits a JSON array preserving order and duplicates. The reader requires the
field, rejects non-arrays and null, and validates each element through its scalar parser.
An invalid element rejects the payload at `$.wireKey[index]`; an empty array is valid.
Declared IDs retain Keiro-owned admission before their total consumer binding runs.
Generated list parsing uses Aeson's field-path and index annotations and adds no dependency.

Lists are values, never publisher outbox or intake dedupe identities. A selected list
field yields `ContractListFieldUsedAsKey` once per clause, including when another selected
event has a scalar with the same DSL name. Canonical envelope identities take precedence
over colliding payload names. Emit key clauses remain descriptive, as before.

Changing scalar/list shape or element type is public breaking `ContractFieldChanged`.
Moving between literal and declared IDs is build-only only when shape, prefix, and
resolved admission domain agree. Prefix equality alone is insufficient even for scalars.
Changed declared-ID prefixes and admission retain the existing public nominal and ID-domain
findings. Admission widening and narrowing both break public consumers, for rolling-reader
and retained-history reasons respectively ([ADR-46](0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md)).

## Consequences

Contracts remain a separately owned grammar; [ADR-13](0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)'s
not-applicable structural coverage classification remains true. Non-Keiro consumers need
only an array of the scalar wire representation. JSON Schema and Avro can express that
array with an element schema. Haskell selector and wire aliases remain independent,
following [ADR-21](0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md).

A future Optional contract field must first resolve RES-18's absent-key versus null policy.
Structural consumer provenance does not become public compatibility authority
([ADR-12](0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)).
The syntax lands before Language 6 finalization in
[plan 304](../plans/304-retire-legacy-language-and-runtime-compatibility-before-keiro-1-0.md).
