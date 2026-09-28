---
type: Reference
title: Keiro DSL Integration Contracts
description: Declare Keiro DSL public contracts, Kafka intakes, emits, and outbox publishers.
docId: DOC-29
tags: [keiro, dsl, integration, kafka, reference]
generated:
  by: anthropic-claude-code/claude-opus-5
  at: 2026-09-28T00:00:00Z
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

Field names are unique within an event and cannot equal the contract
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
`TemplateId` with the same prefix preserves JSON bytes but requires consumers
to rebuild for the changed Haskell type. A prefix change remains a breaking
public-contract change.

Contract fields use the same optional `haskell` selector and `as "wire-key"`
aliases as aggregate fields. The generated record uses `payloadType` and
`serviceRegion` in the example, while JSON retains `"type"` and
`"region_code"`. Resolved selectors must be valid and unique within the event
record; wire keys must be non-empty, unique, and distinct from the declared
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
generated contract codecs decode every declared body field as required and emit
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
