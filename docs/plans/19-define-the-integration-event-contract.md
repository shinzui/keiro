---
id: 19
slug: define-the-integration-event-contract
title: "Define the integration event contract"
kind: exec-plan
created_at: 2026-05-17T19:38:22Z
intention: "intention_01krvpz783etasqe2n8q5ea2m6"
master_plan: "docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md"
---

# Define the integration event contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, keiro has one public, documented shape for integration events: messages that cross from one bounded context to another over Kafka. A bounded context is an independently owned domain boundary, such as ordering or billing. Each context runs its own keiro instance and database; they share only integration events. This plan gives both the outbox and inbox later in the MasterPlan a stable contract for identity, routing, payload bytes, content type, optional schema-registry reference metadata, source event identity or global position, causation, correlation, schema versions, and trace headers.

The behavior is visible without Kafka: tests can build an `IntegrationEvent`, encode it to bytes and headers, decode it back, and verify that the message id, source, event type, schema version, content type, optional schema reference, causation id, correlation id, and payload bytes survive round trip. JSON is the first supported payload encoding, but the contract must not make JSON the only possible wire format.


## Progress

- [x] Add `Keiro.Integration.Event` with envelope, routing, metadata, and encode/decode helpers. (2026-05-18)
- [x] Export the module from `keiro.cabal` and optionally from `Keiro` only if no name collisions appear. (2026-05-18; exposed as a direct module; not re-exported from `Keiro` because `DecodeFailed` would collide with `Keiro.Codec.DecodeFailed`.)
- [x] Add pure tests proving JSON/body/header round trips and malformed payload failures. (2026-05-18; 8 tests in `Keiro.Integration.Event` describe block.)
- [x] Document the Kafka mapping and identity rules in a user-facing guide or API reference section. (2026-05-18; `docs/user/integration-events.md` linked from `docs/user/README.md`.)


## Surprises & Discoveries

- 2026-05-18: The `DecodeFailed` constructor name in `IntegrationEventError` collides with `Keiro.Codec.CodecError.DecodeFailed` when both are imported unqualified. The integration-event module is therefore *not* re-exported from the top-level `Keiro` module — callers import `Keiro.Integration.Event` directly. This matches the existing `Keiro.ReadModel` precedent of keeping the surface narrow when constructor names overlap.


## Decision Log

- Decision: Use an explicit keiro integration-event envelope instead of reusing `Kiroku.Store.Types.RecordedEvent` as the wire contract.
  Rationale: Integration events are public messages between bounded contexts, while recorded events are local event-store facts. The wire contract needs Kafka topic/key/header metadata and stable external message identity that should not expose Kiroku internals.
  Date: 2026-05-17.

- Decision: Keep the core contract Kafka-mappable but not Kafka-owned.
  Rationale: Kafka is the canonical validation transport, but the durable storage code should also support future transports by storing source, destination, payload, and attributes independently of Kafka client types.
  Date: 2026-05-17.

- Decision: Model payload as bytes with content-type and optional schema reference metadata, not as `Aeson.Value` alone.
  Rationale: Future schema-registry integration may use JSON Schema, Avro, Protobuf, or another binary format identified by registry subject/version or schema id. A byte-oriented payload plus schema metadata keeps the v1 JSON path simple while avoiding a breaking table/API migration later.
  Date: 2026-05-17.

- Decision: `messageId` is an application-level identifier (UUIDv7 or equivalent time-ordered UUID) minted by the producer subscription at outbox enqueue time. It is not derived from the source event identity. The envelope persists `sourceEventId` and `sourceGlobalPosition` as separate fields alongside `messageId`.
  Rationale: A UUIDv7 minted at outbox enqueue is stable across publish retries because it lives in the outbox row, time-ordered for index locality, and independent of source identity — so a single source event can fan out to multiple integration events with distinct ids when needed. Keeping `sourceEventId` and `sourceGlobalPosition` alongside preserves traceability, audit, and replay tooling, and lets a consuming service fall back to source-position deduplication when it wants to suppress reissued public events that share an upstream cause.
  Date: 2026-05-18.


## Outcomes & Retrospective

Implemented 2026-05-18 in one pass. `Keiro.Integration.Event` exposes the
byte-oriented envelope, JSON convenience helpers, the canonical wire
header list, and parsing of content-type strings. The library builds
cleanly under `-Wall`, and the 8 pure tests under the `Keiro.Integration.Event`
describe block pass without requiring PostgreSQL or Kafka. Downstream
plans (EP-20, EP-21) can consume the contract directly.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. The main library is declared in `keiro.cabal`, with exposed modules under `src/Keiro/`. The public module index is `src/Keiro.hs`, but the prior read-model work deliberately avoids re-exporting some modules from `Keiro` when field names collide. Follow that precedent if this plan introduces common field names such as `source` or `version`.

The existing event-store contract lives in `src/Keiro/EventStream.hs`, `src/Keiro/Codec.hs`, and `src/Keiro/Command.hs`. `Keiro.Codec` already knows how to encode domain events to Kiroku `EventData` and decode Kiroku `RecordedEvent`. Do not reuse that type as the cross-context wire envelope. A domain event is an internal event in one event stream. An integration event is a public notification to other bounded contexts that may use a different domain model.

The prior cross-bounded-context design lives in `/Users/shinzui/Keikaku/business-application-applications/docs/ebook-principles/service-architecture-blueprint.md` §9-§10 and `/Users/shinzui/Keikaku/business-application-applications/docs/ebook-principles/00-ideal-platform-architecture.md`. Its core rule is that a Kafka integration event is a stable public contract, not a private domain event. A service maps internal domain events into integration events after the local event is durable. The integration event should carry source event identity or source global position so consumers can deduplicate and reason about freshness. Topic names should include contract versions such as `mls.member.events.v1`.

The existing command transaction boundary is `Keiro.Command.runCommandWithSqlEvents` in `src/Keiro/Command.hs`. It supplies decoded output events and a Kiroku `AppendResult` to a `Hasql.Transaction.Transaction`. This remains relevant for local transactional steps, but the canonical Kafka integration producer in EP-20 is a checkpointed subscription over durable local events, not command-handler Kafka publication.

Kafka dependency source was checked with Mori. `mori registry show shinzui/kafka-effectful --full` reports source at `/Users/shinzui/Keikaku/bokuno/kafka-effectful`, and its `Kafka.Effectful.Producer` module exposes `ProducerRecord`, `TopicName`, `Headers`, `headersFromList`, `headersToList`, and `produceMessageSync`. `mori registry show shinzui/shibuya-kafka-adapter --full` reports source at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`. Its converter builds Shibuya `Envelope` values from Kafka records and records Kafka offsets in `messageId`, but keiro should prefer an application-level message id in headers when present.


## Plan of Work

Milestone 1 creates the public type and pure codec. Add `src/Keiro/Integration/Event.hs` and expose it from `keiro.cabal`. Define small newtypes or records for `IntegrationMessageId`, `IntegrationSource`, `IntegrationDestination`, `IntegrationContentType`, and `SchemaReference`, plus an `IntegrationEvent` record. Use strict fields and the repository's record style: `DuplicateRecordFields`, unprefixed field names, deriving stock `Generic`, and imports through `Keiro.Prelude` where practical.

The intended shape is:

```haskell
data IntegrationEvent = IntegrationEvent
  { messageId :: !Text
  , source :: !Text
  , destination :: !Text
  , key :: !(Maybe Text)
  , eventType :: !Text
  , schemaVersion :: !Int
  , contentType :: !IntegrationContentType
  , schemaReference :: !(Maybe SchemaReference)
  , sourceEventId :: !(Maybe EventId)
  , sourceGlobalPosition :: !(Maybe GlobalPosition)
  , payloadBytes :: !ByteString
  , occurredAt :: !UTCTime
  , causationId :: !(Maybe EventId)
  , correlationId :: !(Maybe EventId)
  , traceContext :: !(Maybe TraceContext)
  , attributes :: !(Maybe Value)
  }
```

`SchemaReference` should be registry-neutral. It must be able to represent at least a registry name or URL, a subject, an optional version, an optional numeric schema id, and an optional fingerprint/hash. Do not import a concrete schema-registry client in this plan. A future registry adapter can fill these fields when publishing and use them when consuming.

`messageId` is an application-level identifier (UUIDv7 or equivalent time-ordered UUID) minted by the producer subscription when it writes the outbox row in EP-20. It must remain stable across publish retries; the outbox row carries the same `messageId` until it is marked `sent` or `failed`. `messageId` is *not* derived from `sourceEventId` or `sourceGlobalPosition` — those are separate envelope fields persisted alongside so consumers can correlate the public message back to the private event that produced it, and so a single source event can fan out to multiple integration events with distinct ids. EP-19 itself does not mint ids; it only specifies that `messageId` is a stable application-level value and that `sourceEventId`/`sourceGlobalPosition` are independent fields.

The final names may be adjusted during implementation if newtypes make downstream code clearer, but the fields above must remain representable. Add `encodeJsonIntegrationEvent :: ToJSON a => ... -> a -> IntegrationEvent` and `decodeJsonIntegrationEvent :: FromJSON a => IntegrationEvent -> Either IntegrationEventError a` as v1 conveniences, but keep `IntegrationEvent` itself byte-oriented. Add a Kafka mapping helper that converts an event to a body plus headers without requiring the main contract to import a Kafka producer handle. Headers should include content type and schema reference fields when present.

Milestone 2 adds tests. Extend `test/Main.hs` or create a focused test module if the test suite has already been split. Test a successful byte/header round trip, a JSON convenience round trip, a malformed JSON body through the JSON decoder, a missing required field, schema-version preservation, schema-reference preservation, and trace header preservation. The tests should not require PostgreSQL, Kafka, or a live schema registry.

Milestone 3 documents the contract. Add a section to `docs/user/api-reference.md` or a new `docs/user/integration-events.md` and link it from `docs/user/README.md` if that index exists. Explain that the message id is globally unique per producing context and stable across retries, while Kafka topic/partition/offset is a delivery identity and not the business id. Also explain the prior design rule: integration events are public contracts versioned independently from private domain events, and producer subscriptions should map from private event + source position to public event rather than exposing private event ADTs directly. Add a short "future schema registry" subsection stating that v1 does not contact a registry, but the wire format carries `contentType` and optional `schemaReference` so a later adapter can register, validate, or look up schemas without changing the outbox/inbox tables.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori show --full
mori registry show shinzui/kafka-effectful --full
mori registry show shinzui/shibuya-kafka-adapter --full
```

Add the module and tests, then run:

```bash
cabal build keiro
cabal test keiro-test
```

Expected result after implementation is that `cabal build keiro` compiles the new exposed module and `cabal test keiro-test` reports the integration-event round-trip tests passing. If `keiro-test` is still blocked by the known Keiki multi-event command output migration from `docs/plans/17-adopt-keiki-multi-event-command-output.md`, run the narrow build and record the failure in this plan's Surprises & Discoveries with the exact compiler error.


## Validation and Acceptance

Acceptance requires all of the following:

- `Keiro.Integration.Event` is exposed by the library and Haddock can describe the public types.
- A test constructs an integration event with a stable message id, source `ordering`, destination `billing.order-events.v1`, key `order-123`, event type `OrderSubmitted`, schema version `1`, content type `application/json`, a schema reference such as subject `billing.orders.v1.OrderSubmitted`, source event id or source global position, JSON payload bytes, causation id, correlation id, and trace context; encoding and decoding returns the same value.
- A malformed body returns a typed decode error rather than throwing an exception.
- The docs explain that Kafka redelivery may produce a different topic/partition/offset but must carry the same application-level `messageId` for inbox deduplication.
- The docs explain that a future schema-registry adapter can populate or validate `schemaReference`, but the core event contract does not depend on any registry vendor or network call.


## Idempotence and Recovery

The edits are additive. Re-running the tests is safe. If the module is exposed in `Keiro` and causes field-name ambiguity, remove the broad re-export and keep the direct exposed module, matching the `Keiro.ReadModel` precedent in `docs/masterplans/2-keiro-library-bootstrap-and-v1-implementation-start.md`.

If the byte/header envelope shape changes before EP-20 or EP-21 starts, update the tests and this plan's Decision Log before downstream plans consume it. Once outbox rows are migrated, wire-format changes must be versioned with `schemaVersion`, `contentType`, and `schemaReference` rather than edited in place.


## Interfaces and Dependencies

Use `bytestring` for canonical Kafka payload bytes, `aeson` only for JSON convenience helpers and attributes, `text` for stable identifiers, `time` for `occurredAt`, and `kiroku-store`'s `Kiroku.Store.Types.EventId` / `GlobalPosition` for causation, correlation, and source-position metadata. If the Kafka mapping helper imports Kafka types directly, add the smallest necessary dependency to `keiro.cabal`; otherwise keep it as body/header neutral values and let EP-20 perform the concrete `ProducerRecord` conversion. Do not add a schema-registry dependency in this plan.

The public module must provide the equivalent of:

```haskell
module Keiro.Integration.Event
  ( IntegrationEvent (..)
  , IntegrationContentType (..)
  , SchemaReference (..)
  , TraceContext (..)
  , IntegrationEventError (..)
  , encodeJsonIntegrationEvent
  , decodeJsonIntegrationEvent
  , integrationPayload
  , integrationHeaders
  )
```

Downstream plans consume `IntegrationEvent` directly. EP-20 mints `messageId`, stores the envelope in `keiro_outbox`, and a separate publisher worker sends each row to Kafka. EP-21 decodes the envelope from Kafka and defaults to deduplicating on `(source, messageId)`, with `sourceEventId` and `sourceGlobalPosition` available as alternate policies the consuming service can select.
