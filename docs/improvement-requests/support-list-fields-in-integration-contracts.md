---
type: Improvement Request
title: Support list fields in integration contracts
description: >-
  Let a contract event field carry a list of an admitted scalar contract type (a declared id,
  typeid, text or int), lowered to a Haskell list and a JSON array by the generated codec and
  governed by diff as public contract evolution, so a service whose integration message names
  several entities at once can keep that contract DSL-owned instead of hand-writing its codec.
timestamp: 2026-10-07T06:30:00Z
generated:
  by: process:claude-code
  at: 2026-10-07T06:30:00Z
requestId: IR-53
status: proposed
origin: mori://tan/notification-render-service
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-10-07T06:30:00Z
    document_timestamp: 2026-10-07T06:30:00Z
    scope: technical-accuracy
    outcome: commented
    provider: anthropic
    model: claude-fable-5-1
    effort: high
    context: >-
      Author self-review at Keiro b5ad9d57 against keiro-dsl's Grammar (ContractType, TypeExpr),
      Parser/Integration (pContractType), Scaffold (contractValueType, encodeField, decodeField),
      Diff (contractFieldIdDomain) and the released 0.18.0.0 sources; consumer evidence read in
      mori://tan/notification-render-service. Independent review is pending.
---

# Improvement Request: Support List Fields in Integration Contracts

## Status

Proposed.

Raised by `mori://tan/notification-render-service`, the notification renderer's Haskell domain
service, from its ExecPlan 17 (`docs/plans/17-publish-admin-change-signals-to-kafka-through-the-keiro-outbox.md`).

## Problem and evidence

A `contract` event field accepts exactly four value types. `ContractType` in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs:1063` is `CTypeId Text | CDeclaredId Name | CText | CInt`,
and `pContractType` in `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs:63–72` parses only
`typeid "prefix"`, `text`, `int` or a declared `id` name. Aggregate and read-model declarations,
by contrast, lower through `TypeExpr`, which has `TList` and `TMap` (`Grammar.hs:269`), so a
private event can carry `claimChanges : List AssignmentChange` while the public contract that
announces the same fact cannot carry `templateIds : List TemplateId`.

The consumer case: every change to a notification type publishes one Kafka message keyed by the
type id. A publication can change several templates in one event (the new holder of a slot and
the displaced holder, listed in the private event's `claimChanges`), and a retirement archives
every template of the type. The gateway's push pipeline needs one tick per changed entity, so
the message must name every template the event touched:

```json
{"typeId": "notification_type_01…", "templateIds": ["template_01…", "template_02…"], "messagePosition": "7"}
```

Because the contract grammar has no list, the service cannot declare this event in its
`integration.keiro`. The alternatives it weighed and rejected:

- declare `templateIds: text` and encode the array as a string, which changes the wire contract
  for every consumer;
- fan one private event out into one contract event per template, which multiplies outbox rows
  and loses one-record-per-event;
- hand-write the payload type and Aeson codec, which is what it is doing. The contract then has
  no `keiro-diff` evolution reporting, no generated `Contract` module, and the service's pattern
  register records the deviation as "hand-owned by language limit".

The pattern catalogue's integration-events standard assumes contract fields that carry ids are
declared `typeid` or as a declared id. A service that must leave the DSL for one list field loses
that governance for the whole event.

## Requested behavior

Admit a list of an admitted scalar contract type as a contract field value type:

```keiro-dsl
contract uiEvents {
  schemaVersion 1
  discriminator messageType
  topic uiEvents "notification-renderer.ui-events.v1"
  event NotificationTypeChanged on uiEvents {
    typeId: NotificationTypeId
    templateIds: List TemplateId
    messagePosition: text
  }
}
```

- The element type is one of the existing four (`typeid "prefix"`, `text`, `int`, declared `id`).
  Nested lists, maps and records are not requested.
- The generated `Contract` module lowers the field to a Haskell list of the element's lowered
  type (`[KindID "template"]`, the nominal leaf type for a declared id, `[Text]`, `[Int]`) and the
  codec writes a JSON array in declaration order, applying the element's existing encode and
  parse helpers per element (`Scaffold.hs:3928–3933` and `3995–4010` already own those per
  scalar).
- Decoding is strict: a non-array or an element that fails the element's parser rejects the
  payload, as a scalar field does today. An empty array is a valid value. Whether a missing key
  decodes as an empty list is a codec policy the request leaves to Keiro, stated explicitly.
- `keiro-diff` treats a change of element type, of the declared id's prefix or of its ID-domain
  contract as public contract evolution, the same class `contractFieldIdDomain`
  (`Diff.hs:898–928`) reports for a direct field today. Scalar-to-list and list-to-scalar on one
  wire key are breaking.
- Intake binding and emit mapping need no change: `bind … from body` names a field, and an emit
  `key` must remain a scalar field. A list field is not admissible as `key`, and validation
  should say so.

## Acceptance criteria

- `keiro-dsl check` accepts `List <scalar>` in a contract field under the language versions that
  carry contracts, and refuses nested containers, records and a list used as emit `key` with
  stable diagnostics.
- The scaffolded `Contract` module compiles under the generated compilation contract and round
  trips a payload with an empty list, a one-element list and a multi-element list of declared ids
  through encode and decode, with element order preserved.
- A declared-id element enforces the same TypeID-v7 prefix contract as a direct declared-id field,
  per element.
- `keiro-diff` reports element-type and prefix changes as public contract evolution and
  scalar/list changes as breaking.
- The language reference's contract section lists the admitted element types and the codec policy
  for a missing key.

## Not requested

Maps, nested lists, inline records or unions in contracts, optional fields, and any change to
intake dedupe or publisher identity. If Keiro prefers one general mechanism, letting a contract
field reference a `mapped structural` declaration would also cover this case, but it is a larger
surface than the list the consumer needs.

## Consumer evidence

Source: `mori://tan/notification-render-service`, project-relative files
`docs/plans/17-publish-admin-change-signals-to-kafka-through-the-keiro-outbox.md` (the contract
and its Decision Log), `domain/notification-type.keiro` (private events with `List` fields, lines
123, 187, 252 and 326) and `docs/KEIRO-PATTERNS.md` (the hand-owned deviation row, once the plan
lands). The gateway's one-tick-per-entity constraint is in `admin-graphql-server`,
`src/schema/graphql/pushNodeUpdates.ts` (`parseTick` returns one entity id and foreign ticks are
dropped).

Review basis: Keiro source at `b5ad9d57` and the released `keiro-dsl-0.18.0.0` tarball, whose
`Parser/Integration.hs` has the same four-constructor grammar.
