---
type: Architecture Decision Record
title: Integration contracts admit optional scalar fields and envelope-discriminated payloads
description: A public contract field may be Optional of one scalar, absent as an omitted key and read from an omitted key or null, and a contract may take its event type from the envelope instead of a body key.
timestamp: 2026-11-18T18:27:51Z
docId: ADR-65
status: Accepted
date: 2026-11-18
originatingPlan: docs/plans/345-let-integration-contracts-declare-optional-fields-and-an-envelope-discriminator.md
---

# Integration contracts admit optional scalar fields and envelope-discriminated payloads

## Context

[ADR-52](0052-integration-contracts-admit-lists-of-scalar-fields.md) admitted lists of
contract scalars and kept `Optional` out until the absent-key versus `null` question in
[RES-18](../research/15-containers-in-public-contract-fields.md) was settled.
[IR-64](../improvement-requests/let-integration-contracts-describe-events-owned-by-other-producers.md)
supplied the case: `mori://tan/registration-service-v2` publishes `RegistrationCompleted`
on `registration.completed.v1` as a bare JSON object, omits two fields when they are
unknown, and names the event only in the Kafka `keiro-event-type` header. A Keiro consumer
could not declare that event, so it hand-wrote the payload decoder.

## Decision

In candidate Language 6 a contract field may be `Optional <scalar>`, where the scalar is
one existing contract scalar: literal `typeid "prefix"`, a declared `id`, `text` or `int`.
`ContractType` gains `COptional` beside `CScalar` and `CList`, so nesting stays
unrepresentable: `Optional List`, `List Optional`, and every other nesting are refused with
the contract-type message. Recognition follows ADR-52: only exact `Optional` followed by an
operand is the container, so `Optional` alone still names a declared id, and `Optional text`
is an optional field even when an id named `Optional` exists.

On the wire an absent value is an omitted key. The generated encoder never writes `null`.
The generated decoder reads an omitted key and an explicit `null` as absent; any other value
must satisfy the scalar's parser, so a wrong type or TypeID prefix rejects the payload at
`$.wireKey`. A present declared id keeps Keiro-owned admission
([ADR-46](0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md)).
The record field is `Maybe` of the scalar's type. Generated code uses aeson's `.:?` and
`explicitParseFieldMaybe`, and contracts without optional fields keep their exact bytes.

An optional field is never a publisher `outboxId` or an intake `dedupe` key:
`ContractOptionalFieldUsedAsKey` reports it once per clause. Canonical envelope names keep
precedence over payload fields, and a name that is a list in one selected event reports
`ContractListFieldUsedAsKey` instead, so one mistake yields one diagnostic.

Evolution: adding an optional field is the additive `ContractOptionalFieldAdded` and needs
no `schemaVersion` bump, because generated decoders ignore unknown keys and read a missing
optional key as absent. Changing a field between required and optional is breaking
`ContractFieldChanged` in both directions, and the detail names the direction: deployed
consumers still require the key, or retained messages that omit it no longer decode.
Changing the scalar under `Optional`, or between `Optional` and `List`, is breaking. A
literal-to-declared move under `Optional` is build-only exactly when it is for scalars and
lists: equal prefix and equal resolved admission domain. Removing a field stays breaking.

A contract may declare `discriminator from envelope` in place of `discriminator <key>`.
`ContractNode.discriminator` is a `ContractDiscriminator`: `DiscriminatorBodyKey` or
`DiscriminatorEnvelope`. `from` is reserved, so the phrase cannot collide with a body key.
Such a contract's encoder writes no discriminator key, and its module exports
`parse<Contract>PayloadAs :: Text -> Value -> Either Text <Contract>Payload` in place of
`parse<Contract>Payload`. The decoder always checks the event type it is given, even for
one event, and rejects a type the contract does not declare; an event's declared name must
equal the envelope's event type exactly. keiro-core's `decodeJsonIntegrationEventWith`
passes an envelope's `eventType` and decoded JSON body to such a parser, so the generated
module stays free of envelope types. A field may then use the wire key `messageType`.
Changing between a body key and the envelope is breaking `ContractDiscriminatorChanged`.

The service topology writes `discriminator: null` for an envelope-discriminated contract.
Both topology schemas were amended in place to admit `null`, with no new schema id: the
export had not been released and had no consumer
([ADR-62](0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)
governs it once it has one). Documents for existing services keep their bytes.

## Consequences

A Keiro service can mirror a foreign producer's event whose fields may be absent and whose
event type travels outside the body. A non-Keiro consumer implements the same rule: a
property that is not required and admits `null`, which JSON Schema states directly.
Mapping a foreign producer's own header names onto Keiro's envelope stays out of scope;
intake `bind … from header` rows remain descriptive, so such a consumer keeps a small header
adapter. Event names that are not identifiers, and wire-name aliases for events, remain
unsupported. Contracts stay a separately owned grammar
([ADR-13](0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)),
and field aliases keep independent selector and wire identities
([ADR-21](0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md)).
The library change has no compatibility shim, following ADR-52; the next keiro-dsl
release is a PVP-major bump.
