---
type: Reference
title: Keiro DSL Integration Contracts
description: Declare Keiro DSL public contracts, Kafka intakes, emits, and outbox publishers.
docId: DOC-29
tags: [keiro, dsl, integration, kafka, reference]
generated:
  by: anthropic-claude-code/claude-opus-5-5
  at: 2026-11-18T22:27:00Z
---

# Keiro DSL Integration Contracts

This page covers the integration nodes: public contracts and topics, Kafka
intakes into the inbox, emits from private state, and outbox publishers. It is part of the [Keiro DSL Reference](keiro-dsl-reference.md), which
introduces the language, its versions, and source file structure.

## Integration contracts

A contract owns public event names, topic aliases, and payload fields:

```keiro
contract emergency {
  schemaVersion 1
  discriminator messageType

  topic incidentEvents "emergency.incident.events"
  topic hospitalEvents "emergency.hospital.events"

  event TransferReservationAccepted on hospitalEvents {
    incidentId: typeid "inc"
    reservationId: typeid "rsv"
    hospitalId: typeid "hsp"
    family: text
    type haskell payloadType: text
    region haskell serviceRegion as "region_code": text
    expirationDeadline: text
  }
}
```

`schemaVersion` starts at 1. Topic aliases and event names are unique, and every
event's alias must resolve. A Kafka topic is 1–249 ASCII characters from
`A-Z`, `a-z`, `0-9`, `.`, `_`, and `-`, excluding `.` and `..`.

Contract field types are:

| Syntax | Generated type |
| --- | --- |
| `typeid "prefix"` | `KindID "prefix"` with current TypeID-v7 decoding |
| `DeclaredId` (Language 6 candidate) | the declared ID's generated or consumer-bound Haskell type, with that declaration's admission domain (`typeid-v7` unless the declaration says `typeid-v5-or-v7`) |
| `text` | `Text` |
| `int` | `Int` |
| `List <scalar>` (Language 6 candidate) | a Haskell list of the element type; JSON array in list order |
| `Optional <scalar>` (Language 6 candidate) | `Maybe` of the scalar's type; the key is omitted when absent and read as absent when omitted or `null` |

Field names are unique within an event and cannot equal the contract's body
discriminator. TypeID prefixes follow the same validity rules as shared IDs.
The generated decoder rejects malformed, non-canonical, wrong-prefix, and
unadmitted values at the field path; `typeid "prefix"` and default declared IDs
admit only UUIDv7 suffixes.

A candidate Language 6 contract may name a top-level `id` declaration directly:

```keiro
language keiro-dsl 6
context templates

id TemplateId prefix=template

contract publicTemplates {
  schemaVersion 1
  discriminator messageType
  topic templateEvents "templates.events"

  event TemplateClaimed on templateEvents {
    templateId: TemplateId
  }
}
```

This keeps the public field linked to the declaration's prefix and Haskell
ownership. Only `id` declarations are accepted here; enums, nominal scalars,
and mapped declarations are rejected. Moving between `typeid "template"` and
`TemplateId` is a build-only change only when both prefix and resolved admission
domain are unchanged: JSON bytes stay the same, while consumers rebuild for the
changed Haskell type. Admission widening or narrowing and prefix changes are breaking
public-contract changes.

Candidate Language 6 also admits lists of any of these four scalar types:

```keiro
event TemplatesReassigned on templateEvents {
  templateIds: List TemplateId
  labels: List text
}
```

This event belongs inside a contract with the `TemplateId` declaration above.
Encoding writes an ordered JSON array and retains duplicates. Decoding requires every
list field, rejects non-arrays and explicit null at `$.field`, and rejects any invalid
or null element at `$.field[index]`. One bad element rejects the whole payload;
`[]` is valid. Each ID element uses the same prefix and admission checks as a scalar.
Nested containers (including `Optional List` and `List Optional`), `Map` and `Set`
applications, records, unions, enums, and structural references are refused in
contracts. Those application spellings do not reserve ID names: an
`id Optional prefix=probe` declaration can supply `value: Optional`,
`values: List Optional`, and `maybeValue: Optional Optional`. Likewise, a declared ID
named `List` can supply `value: List` and `values: List List`. Followed by an operand,
`List` and `Optional` are always containers, so `values: Optional text` is an optional
`text` field even when an ID named `Optional` exists. A bare type ends at `;`, `}`, or
the next field head (including its aliases and `:`); newlines are whitespace.
Keywords are case-sensitive: only `List` introduces a list and only `Optional` an
optional value, so `list text`, `LIST text`, `optional text`, and `OPTIONAL text` are
invalid applications. Mixed-case words used alone remain ordinary declared ID names.

A list field cannot be a publisher `outboxId` or an intake `dedupe` key; the checker
reports `ContractListFieldUsedAsKey`. Canonical envelope identity names take precedence
over colliding payload fields. For publishers these are `messageId` and
`idempotencyKey`; intakes retain their canonical envelope fields. A non-envelope name
that denotes a list in any selected event is refused even if another selected event has
a scalar of the same name. Emit `key` remains descriptive, as explained below.

Changing between a scalar and a list, changing the element type, or changing an element's
prefix or admission is breaking public evolution. Moving a literal ID element to a
declared ID is build-only only when list shape, prefix, and admission are all unchanged.

### Optional fields

Candidate Language 6 admits `Optional` of any of the four scalar types, for a field a
producer leaves out when it has no value:

```keiro
event MemberNoted on notes {
  memberId: MemberId
  note: Optional text
  referrerId: Optional typeid "member"
}
```

The generated record holds `note :: Maybe Text`. On the wire an absent value is an
omitted key: the encoder never writes `null`. The decoder reads an omitted key and an
explicit `null` as `Nothing`. Any other value must satisfy the scalar's parser, and the
error names the field's own path: `"note": 7` rejects the payload at `$.note`, and a
wrong-prefix `referrerId` rejects it at `$.referrerId`. A present declared ID keeps its
admission domain. A consumer in any language can apply the same rule, which
JSON Schema states as a property that is not required and admits `null`. Aliases work as
for any field: `note haskell memberNote as "member_note": Optional text`.

`Optional` takes exactly one scalar. `Optional List text`, `List Optional text`, and any
other nesting are refused, because an empty array is already the way to say "no values".

An optional field cannot be a publisher `outboxId` or an intake `dedupe` key: an identity
that may be absent identifies nothing, and the checker reports
`ContractOptionalFieldUsedAsKey`. The canonical envelope precedence described for lists
applies, and a name that is a list in any selected event reports
`ContractListFieldUsedAsKey` instead, so one mistake yields one diagnostic.

Evolution follows from the wire rule. The rollout column is the `rollout` entry of the
finding's compatibility vector, which `keiro-dsl diff` prints on its `vector:` line; see
[Deploy Ordering](deploy-ordering.md#7-coordinate-integration-contracts-manually).

| Change | Classification | Rollout |
| --- | --- | --- |
| add an `Optional` field | warning `ContractOptionalFieldAdded`: `public-consumer=compatible`, `consumer-build=advisory`; no `schemaVersion` bump needed, and the default gate passes | any order; re-scaffold and recompile, because the generated constructor gains a `Maybe` argument |
| required to `Optional` | breaking `ContractFieldChanged`: deployed consumers still require the key | `producer-last`: every reader tolerates omission before any writer drops the key |
| `Optional` to required, keeping the scalar or moving between `typeid "p"` and a declared ID of equal prefix and admission | breaking `ContractFieldChanged`: retained messages that omit the key no longer decode | `producer-first`, `drain-required`: writers that supply the key deploy first, then retained messages without it drain before the stricter reader runs |
| change the scalar under `Optional`, or `Optional` to or from `List` | breaking `ContractFieldChanged` | `producer-last` |
| `Optional typeid "p"` to or from `Optional DeclaredId` | build-only when prefix and admission are unchanged, as for scalars | no rollout entry; recompile consumers |
| remove an `Optional` field | breaking `ContractFieldChanged`, like any removed field | `producer-last` |

### Payloads without a body discriminator

A contract normally names the JSON key that carries the event name, as in
`discriminator messageType`. An event published by a service that does not follow that
convention may carry its name only in the envelope, which arrives over Kafka as the
`keiro-event-type` header. Candidate Language 6 declares such a contract with
`discriminator from envelope`:

```keiro
language keiro-dsl 6
context registration-intake

id MemberId prefix=member

contract registration {
  schemaVersion 1
  discriminator from envelope

  topic completed "registration.completed.v1"

  event RegistrationCompleted on completed {
    registrationId: typeid "registration"
    occurredAt: text
    ownerEmail: Optional text
    mlsMemberId: Optional MemberId
  }
}
```

The generated encoder writes only the fields; an event without fields encodes as `{}`.
`messageTypeOf` still names the event, and a producer puts it in the envelope's
`eventType`. In place of `parseRegistrationPayload`, the module exports

```haskell
parseRegistrationPayloadAs :: Text -> Value -> Either Text RegistrationPayload
```

which takes the event type as its first argument and rejects a type the contract does not
declare, even when the contract has one event. A declared event name must equal the
envelope's event type exactly. Join it to an envelope with keiro-core's
`decodeJsonIntegrationEventWith` from `Keiro.Integration.Event`:

```haskell
decodeJsonIntegrationEventWith parseRegistrationPayloadAs envelope
  :: Either IntegrationEventError RegistrationPayload
```

It refuses a non-JSON content type with `UnsupportedContentType`, reports unparsable bytes
as `MalformedPayload`, and reports the parser's `Left`, including an undeclared event
type, as `DecodeFailed`. Because the body has no discriminator key, a field may use the
wire key `messageType`. Changing between a body key and `from envelope` is breaking
`ContractDiscriminatorChanged`. A body key to `from envelope` is `producer-last`, because
old readers still require the key; `from envelope` to a body key is `producer-first` with
`drain-required`, because the new reader requires a key old producers never wrote.
`keiro-dsl topology` exports such a contract with `discriminator: null`.

Mapping another producer's own header names onto Keiro's envelope is out of scope: intake
`bind … from header` rows stay descriptive, so a consumer of such a producer rebuilds the
envelope in a small adapter before calling `decodeJsonIntegrationEventWith`.

Contract fields use the same optional `haskell` selector and `as "wire-key"`
aliases as aggregate fields. The generated record uses `payloadType` and
`serviceRegion` in the example, while JSON retains `"type"` and
`"region_code"`. Resolved selectors must be valid and unique within the event
record; wire keys must be non-empty, unique, and distinct from a declared body
discriminator. A selector-only diff requires re-scaffolding and recompilation;
changing a public wire key is a breaking contract change and consumers deploy
before producers.

## Intakes

An intake connects one contract topic to the inbox:

```keiro
intake incidentInbox {
  contract emergency
  topic incidentEvents
  accept IncidentTransferNeedDeclared

  bind source from header "keiro-source" required
  bind schemaVersion from header "keiro-schema-version" required cross-check body
  bind messageId from header "keiro-message-id" required cross-check body
  bind key from kafka-key
  bind occurredAt from kafka-cursor
  bind idempotencyKey from body

  dedupe key messageId policy PreferIntegrationMessageId
  persist = dedupe-only

  decode {
    envelope strict-required lenient-optional
    body strict schemaVersion == 1
  }

  disposition {
    processed => ackOk
    duplicate => ackOk
    inProgress => retry 5s
    previouslyFailed => deadLetter "previous inbox failure"
    decodeFailed => deadLetter
    dedupeFailed => deadLetter
    storeFailed => retry 5s
  }
}
```

`contract`, `topic`, and every accepted event must resolve, and accepted events
must belong to the intake topic. One or more event names follow `accept`.

Bind sources are `header "name"`, `body`, `kafka-key`, and `kafka-cursor`.
`required` and `cross-check body` are optional descriptive flags. A bound name
and the dedupe key must resolve to either a field on an accepted contract event
or one of the canonical envelope names, but generated code does not consume the
binding rows or enforce either flag. A flagged row therefore produces
`IntakeBindFlagUnenforced`; consumer-owned decode wiring remains responsible
for the declared binding posture. A `header "name"` source must name one of
keiro's canonical envelope headers (`keiro-message-id`, `keiro-source`,
`traceparent`, and so on). The Kafka inbox reconstructs an envelope from that
fixed set and cannot be remapped, so any other header would describe a
remapping that does not happen and is refused.

```text
messageId source destination key eventType schemaVersion contentType
schemaReference sourceEventId sourceGlobalPosition payloadBytes occurredAt
causationId correlationId traceContext attributes idempotencyKey
```

Dedupe policies are `PreferIntegrationMessageId`,
`PreferSourceEventIdentity`, and `KafkaDeliveryIdentity`.

Candidate Language 6 can delegate receipt ownership to the downstream state
machine:

```keiro
dedupe key messageId policy PreferIntegrationMessageId
idempotence delegated
```

The `idempotence` clause is optional, and omission means `table` in every
language. `delegated` requires Language 6 and generates the typed
`runInboxIntake` wrapper over `runInboxDelegated`. It must not be combined with
`persist = dedupe-only`, because delegated mode writes no inbox storage; the
validator reports `DelegatedInboxDedupeOnlyPersistence`.

`persist` is optional and defaults to `full-envelope`. Use `dedupe-only` only
when a successfully processed payload is re-fetchable or no longer valuable;
failed rows keep the full envelope for operators regardless of this choice.

The envelope policy is exactly `strict-required lenient-optional`, and the body
schema version must equal the contract version. Body mode must be `strict`:
generated contract codecs require every body field not declared `Optional` and emit
no lenient fallback, so `lenient` is refused as a description of something that
does not run. The word is still parsed and a posture change is still
diff-classified. The
disposition table is mandatory and contains each of the seven rows exactly
once. Duplicates acknowledge success, a previous terminal failure does not
retry, poison decode failures dead-letter, and transient/in-progress outcomes
use bounded retries according to the declared action. The checker rejects any
retry duration whose unit-adjusted seconds do not fit in `Int`.

## Emits and publishers

An emit maps a private discriminant to public contract events:

```keiro
emit reservationResponse {
  contract emergency
  topic hospitalEvents
  source "hospital-capacity"
  key incidentId
  map status {
    "confirmed" => TransferReservationAccepted
    "rejected" => TransferReservationRejected
    _ => skip
  }
  messageId derive "msg" hole
  idempotencyKey derive hole
}
```

The contract, topic, and mapped events must resolve, and every mapped event must
belong to the selected topic. Discriminant strings are unique. The explicit
`_ => skip` catch-all is mandatory. `source`, `key`, and the map's discriminant
name are descriptive because no typed source read-model namespace is declared;
their values are not field-resolution programs. An emit is validated and
diff-classified but produces no generated module today.

`derive ["prefix"] hole` documents a hand-owned derivation responsibility; it
does not create a module or typed signature. Because the clause is mandatory
grammar, this is true of every emit in every spec, so it carries no per-spec
diagnostic; the scaffold report's no-modules line names each emit node that
contributed nothing. The hand-owned implementation must be deterministic so
retries reproduce the same IDs.

A publisher owns delivery policy for one emit:

```keiro
publisher hospitalPublisher {
  emit reservationResponse
  ordering PerKeyHeadOfLine
  maxAttempts 10
  backoff exponential 2s max=60s multiplier=2.0
  outboxId stable from messageId
}
```

`emit` must resolve and `maxAttempts` starts at 1. Ordering is one of:

- `PerKeyHeadOfLine`
- `PerSourceStream`
- `StopTheLine`
- `BestEffort`

Backoff is either `constant <duration>` or
`exponential <initial> max=<duration> multiplier=<decimal>`. Exponential
backoff requires both options, a positive initial delay, a maximum at least as
large as the initial delay, and a multiplier of at least 1. The checker also
rejects any delay whose unit-adjusted seconds do not fit in `Int`.
`outboxId stable from <field>` declares the identity that coalesces retries;
the field must be `messageId`, `idempotencyKey`, or a field of
an event mapped by the publisher's emit.
