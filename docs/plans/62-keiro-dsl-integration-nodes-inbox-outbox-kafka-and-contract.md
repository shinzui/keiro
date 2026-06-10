---
id: 62
slug: keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract
title: "keiro-dsl integration nodes: inbox, outbox, Kafka and contract"
kind: exec-plan
created_at: 2026-06-10T01:05:27Z
intention: "intention_01ktqdn85xe2btqzr2zghxgrpr"
master_plan: "docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md"
---

# keiro-dsl integration nodes: inbox, outbox, Kafka and contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A keiro **service** is a bounded context that uses event sourcing plus Kafka to exchange
public messages with other services. Today the Kafka-facing code — receiving a message
("inbox"), buffering an outgoing message durably ("outbox"), publishing it, and the shared
schema both sides agree on ("contract") — is hand-written Haskell that is 70–95% mechanical
template and 5–30% genuinely-decided behavior. The decided part hides a handful of
**dangerous, counter-intuitive choices** (for example: a duplicate redelivery must be
treated as *success*, and a message that previously failed must be *dead-lettered, not
retried*). When a human or a coding agent writes that code from scratch, those are exactly
the choices they get wrong.

This ExecPlan, **EP-4** of the MasterPlan `docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`,
adds four node types to the keiro DSL toolchain (`keiro-dsl`) so that the integration layer
of a service becomes a **typed specification** instead of hand-written boilerplate:

- `contract` — declares the shared message schema once (topic names, the closed set of
  event types and their field-sets, the schema version, and the wire discriminator field).
- `intake` — declares a Kafka *consumer* (the inbox): which contract it reads, how each
  required Kafka header binds to an envelope field, which field is the deduplication key,
  how strictly the body is decoded, and — mandatorily — the full disposition table that
  says what acknowledgement each inbox outcome produces.
- `emit` — declares that a private domain event is mapped to a public contract message
  (the outbox): the status→event-type mapping, the destination topic, the partition key,
  and which cases are deliberately skipped.
- `publisher` — declares the at-least-once publishing policy for an `emit`'s topic
  (ordering policy, max attempts, backoff).

After this change a developer (or a coding agent planning a feature) can:

1. Write the integration surface of a service in terse `.kdsl` notation that names a real
   Kafka topic, the real event types on it, and every required header binding.
2. Run `keiro-dsl check service.kdsl` and have the checker **reject the spec before any
   Haskell is written** if the disposition table is incomplete, if a dangerous inversion is
   stated the safe-but-wrong way (duplicate⇒retry, previouslyFailed⇒retry,
   invalid-payload⇒unbounded-retry), if a contract field is left unbound to any wire
   source, if a header that exists in both the Kafka header and the JSON body is not given
   an explicit cross-check decision, or if a producer and consumer of the same topic
   reference different contracts.
3. Run `keiro-dsl scaffold service.kdsl` and get the **symbol-free deterministic layer**
   — the `IntegrationMessage`/`IntegrationPayload` contract types, the inbox/outbox wiring,
   the consumer/publisher config records — emitted into `-- @generated` modules, plus
   precisely-typed **holes** (Haskell function signatures with `undefined` bodies and a
   `-- HOLE:` comment) for the few behavior-bearing pieces an agent must write: custom id
   derivations, mapper bodies, and the disposition function.
4. Fill the holes and run the emitted **harness** (a generated test module) to confirm the
   behavior matches the spec: every event type round-trips through encode/decode, and the
   disposition table is exercised for all four inbox outcomes plus the failure cases.

You can see it working by running, from `keiro-dsl/`, `cabal run keiro-dsl -- check` on a
spec with a deliberately wrong disposition row and observing a non-zero exit with a precise
diagnostic; then `cabal run keiro-dsl -- scaffold` and `cabal test` to see the generated
contract types compile and the harness exercise every event type. The end-state acceptance
is **conformance**: a `.kdsl` transcribed from the real `hospital-capacity` and
`incident-command` Kafka integration modules scaffolds code whose generated contract is
byte-for-byte equivalent (same topics, event types, field-sets, discriminator) to the
hand-written `Integration/Contracts.hs` it was derived from.

The `contract` block defined here is the **one cross-vertical integration point** of the
MasterPlan: EP-5 (`docs/plans/63-keiro-dsl-pgmq-workqueue-and-dispatch-nodes.md`) consumes
it to couple a PGMQ queue to a contract. Its grammar, validation, and the artifact EP-5
reads are documented in this plan's *Interfaces and Dependencies* section so EP-5 can
reference them by path.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work. All items begin
unchecked; check them off with a timestamp as work proceeds.

Milestone 1 — Grammar + parser: **IN PROGRESS 2026-06-10** (contract node done; intake/emit/publisher remaining)

- [x] Add the `NContract`/`ContractNode` constructor to `Keiro.Dsl.Grammar` (schemaVersion, discriminator, topic aliases, events-on-topic with typed fields `typeid \"x\"`/`text`/`int`). The `intake`/`emit`/`publisher` constructors remain. (2026-06-10)
- [x] Extend `Keiro.Dsl.Parser.parseSpec` to parse the `contract` block (adapted to the existing flat `context` top-level rather than a `service { … }` wrapper, for consistency with EP-1–EP-3). (2026-06-10)
- [x] Extend the pretty-printer so parse→print→parse round-trips for the contract block. (2026-06-10)
- [x] Unit tests: parse `contract.kdsl` into the expected AST + round-trip. (2026-06-10)
- [x] `intake` node (contract/topic/accept, envelope bind rows with wire sources + cross-check, dedupe, decode strictness, the mandatory disposition table) — grammar, parser, pretty, round-trip. The runtime-config `consumer` block is hole-kind 8, deferred. (2026-06-10)
- [x] `emit` node (status→event map + mandatory `_ => skip`, topic/source/key, messageId/idempotencyKey derive holes) and `publisher` node (ordering/maxAttempts/backoff/outboxId) — grammar, parser, pretty, round-trip. (2026-06-10)
- **All four EP-4 node types (contract/intake/emit/publisher) now parse, round-trip, and validate.**

Milestone 2 — Validator rules: **PARTIAL 2026-06-10** (the inbox-disposition rules — EP-4's headline value — done)

- [x] `validateIntake`: `DispositionIncomplete` (the table must cover all seven outcomes) and the three dangerous inversions — `DispositionDuplicateRetry`, `DispositionPreviouslyFailedRetry`, `DispositionDecodeUnboundedRetry` — each rejected with a line-numbered diagnostic; the canonical intake passes clean. (2026-06-10)
- [x] `EmitSkipMissing` (skip-totality), cross-node contract coupling (`IntakeUnresolvedContract`, `EmitUnresolvedContract` over contract/topic/event), and `PublisherUnresolvedEmit` (producer pairing). (2026-06-10)
- [ ] Remaining (lower-value): envelope-binding completeness, cross-check-declaration, dedupe-key resolution, explicit-decode-strictness checks.

Milestone 3–4 (scaffold + harness) — **PARTIAL 2026-06-10**: `scaffoldContract` emits a self-contained `-- @generated` payload ADT (per-event Data records) + topic constants + `messageType` discriminator + strict codec; the `keiro-dsl-conformance-contract` component compiles it and round-trips every contract event type (firewall holds). The intake/emit/publisher scaffold (inbox/outbox wiring, runtime-coupled) and M5 conformance vs the captured `Integration/` modules remain.

Milestone 2 — Validator rules:

- [ ] Implement the eleven integration validator rules (disposition completeness, the three
      inversion flags, transient-only-retry, envelope-binding completeness, cross-check
      declaration, dedupe-key resolution, explicit decode strictness, cross-node contract
      coupling, producer at-least-once pairing, skip-totality).
- [ ] Negative tests: each rule fires on a crafted bad spec; positive test: the conformance
      spec passes clean.

Milestone 3 — Scaffold (symbol-free):

- [ ] Emit `-- @generated` contract module (`IntegrationMessage`/`IntegrationPayload`,
      topic constants, `messageType` discriminator, topic-routing predicates).
- [ ] Emit `-- @generated` inbox wiring (envelope reconstruction call, dedupe policy,
      decode-strictness scaffold) and `-- @generated` outbox/publisher config records.
- [ ] Emit `-- HOLE:` typed stubs for mapper bodies, custom id derivations, and the
      disposition function.
- [ ] Assert the firewall invariant on every emitted `Generated` module (no keiki symbolic
      operator on any `-- @generated` line).

Milestone 4 — Harness:

- [ ] Emit a round-trip golden-fixture test per contract event type.
- [ ] Emit a disposition-table coverage test asserting all four inbox classifications plus
      decode/dedupe/store failures map to the spec's acknowledgement.
- [ ] Emit a clock-free assertion (time is injected, never sampled, in scaffolded code).

Milestone 5 — Conformance:

- [ ] Capture `hospital-capacity` and `incident-command` `Integration/` into
      `keiro-dsl/test/fixtures/` (read-only reference modules + the derived `.kdsl`).
- [ ] Prove generated contract equals the captured `Contracts.hs` shape (same topics,
      event types, field-sets, discriminator) and the harness is green.
- [ ] Mutation check: flip one disposition row in the spec; the harness coverage test turns
      red.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Make the inbox **disposition table mandatory and complete** in the grammar —
  the `intake` block must state an acknowledgement for all four `InboxResult`
  classifications (`processed`, `duplicate`, `inProgress`, `previouslyFailed`) plus the
  three failure classes (`decodeFailed`, `dedupeFailed`, `storeFailed`). A missing row is a
  `check` error, not a silent default.
  Rationale: the real corpus mapping (`hospital-capacity` `KafkaConsumer.hs:111-123`) is
  counter-intuitive and the dangerous choices are precisely the implicit ones. Forcing the
  table makes every acknowledgement an explicit, reviewed decision. Date: 2026-06-10

- Decision: The validator **flags the three dangerous inversions by value**, not just by
  presence: `duplicate` must be `ackOk` (replay is success); `previouslyFailed` must be
  `deadLetter` (not retry); and any invalid/decode case must not be unbounded `retry`.
  Stating the safe-but-wrong direction is a hard error with a fix-it message.
  Rationale: these are the empirically-confirmed mistakes (MasterPlan Surprises; corpus
  `KafkaConsumer.hs:114-121`). A grammar that merely *allows* stating them would not protect
  the author. Date: 2026-06-10

- Decision: Model the two `occurredAt` values as **two distinct, separately-bound fields**
  in the spec: `envelope.occurredAt` binds to `kafka-cursor` (delivery `receivedAt`) and
  any body `occurredAt` binds to `body`. The spec never conflates them.
  Rationale: `Inbox/Kafka.hs:119-125` sets the envelope `occurredAt` to the delivery
  `receivedAt` and explicitly does *not* read a producer `occurredAt` header; the body
  separately carries the producer wall-clock. This duality is real and load-bearing, so the
  notation must name both. Date: 2026-06-10

- Decision: The **cross-check is a first-class, declared hole** (hole-kind 4). For any field
  that appears in *both* the Kafka header layer and the JSON body (for example `messageId`,
  `schemaVersion`), the `intake` block must declare one of `cross-check`, `prefer-header`,
  or `prefer-body`; omitting it is a `check` error.
  Rationale: in the corpus nothing validates that header and body agree — dedupe uses the
  *header* `messageId` (`Store.hs:328` via `PreferIntegrationMessageId`) while the *body*
  `messageId` is what gets stored (`Inbox.hs:124-127`). Silent divergence is a latent bug;
  the spec must force a decision. Date: 2026-06-10

- Decision: `keiro-dsl` **does not emit symbolic transducer code or mapper bodies**; those
  are typed holes pinned by the harness (the MasterPlan firewall invariant). The scaffold
  emits the contract types, wiring, and config records (all symbol-free) plus `-- HOLE:`
  stubs for the disposition function, mapper bodies, and custom id derivations.
  Rationale: load-bearing MasterPlan scope decision — the behavior-bearing logic (status
  string surgery, idempotency-key concatenation, per-field literal injection) is exactly
  what an agent writes well from a spec + examples, and the determinism guarantee is
  delivered behaviorally by the harness, not by a brittle code generator. Date: 2026-06-10

- Decision: Conformance corpus is captured **read-only** from the external
  `keiro-runtime-jitsurei` `hospital-capacity` and `incident-command` `Integration/`
  modules into `keiro-dsl/test/fixtures/`, with `hospital-capacity` as the primary single-
  topic-pair example and `incident-command` proving the **one-union-across-two-topics**
  shape (`isIncidentTopicMessage`/`isHospitalTopicMessage` routing predicates).
  Rationale: the rich integration features live only in the external repo; capturing keeps
  the tests hermetic, and the two-topic union is a real grammar requirement
  (MasterPlan Surprises: "contract-union-across-topics"). Date: 2026-06-10

- Decision: The `contract` block is the **single source** for `{topic, eventType→fieldset,
  schemaVersion, discriminator}` and is the artifact EP-5 reads. `intake` and `emit`
  reference a contract by name; a producer `emit` and a consumer `intake` on the same topic
  must reference the *same* contract id (a checkable coupling).
  Rationale: this is Integration Point #8 of the MasterPlan — the one cross-vertical
  contact. Defining it here once, with a documented shape, lets EP-5 couple a PGMQ queue to
  a contract without re-deriving it. Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### What already exists, and what EP-1 gives you

This repository (`keiro`) contains the keiro runtime libraries and the `keiro-dsl`
toolchain. **EP-1 Foundations**
(`docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`)
is a **hard prerequisite** for this plan and must be Complete before you start. EP-1 creates
the `keiro-dsl` package and these modules, whose signatures this plan restates because you
will extend them:

- `Keiro.Dsl.Grammar` — the abstract syntax tree (AST) of a `.kdsl` spec. EP-1 defines a
  top-level record `Spec` that aggregates a list of nodes, the shared declaration types
  (`IdDecl`, `EnumDecl`, `RuleDecl`), the eight hole types, and a small expression
  sublanguage `Expr`. A "node" is one block in the spec (today only `Aggregate`). **You add
  four node constructors here.**
- `Keiro.Dsl.Parser` — `parseSpec :: Text -> Either ParseError Spec`, a megaparsec parser
  for the terse notation. **You extend it to parse the four new blocks.**
- `Keiro.Dsl.Validate` — `validateSpec :: Spec -> [Diagnostic]`, returning a list of
  `Diagnostic` (a record carrying a severity `Error`/`Warning`, a human message, and a
  source span). An empty list means the spec is valid. The CLI `check` command runs this
  and exits non-zero if any `Error` is present. **You add the integration rules here.**
- `Keiro.Dsl.Scaffold` — the code emitter. Its central type is
  `ScaffoldModule { modulePath :: FilePath, moduleText :: Text, kind :: ModuleKind }` where
  `ModuleKind = Generated | HoleStub`. A `Generated` module carries a `-- @generated`
  marker and is overwritten on every scaffold; a `HoleStub` module is written only if it
  does not already exist (create-if-absent), so hand-filled holes are never clobbered. EP-1
  enforces the **firewall invariant**: no line in a `Generated` module's `moduleText` that
  is marked `-- @generated` may contain a keiki symbolic operator (the operators `./=`,
  `lit`, `B.slot`, `B.requireGuard`, and similar from the `keiki` library). **Your emitters
  must satisfy this invariant.**
- `Keiro.Dsl.Harness` — emits a test module that exercises scaffolded behavior (golden wire
  fixtures, a clock-free assertion). **You emit integration-specific harness tests.**
- The CLI (`keiro-dsl/app/Main.hs`) exposes `parse`, `check`, `scaffold` subcommands. You
  add **no** new subcommand; you extend the behavior of the existing ones.

You reference EP-1 only by the path above. Everything you need from it is restated here.

### The keiro integration runtime you are modeling (the bijection)

The DSL is a **bijection** (a one-to-one structural correspondence) with real keiro
primitives. Each new node maps to a specific runtime module. The Integration envelope
primitive lives in the **`keiro-core`** package, *not* `keiro` — the directory
`keiro/src/Keiro/Integration/` is empty. The canonical source files, all of which you must
read to mirror their shape faithfully, are:

- **Envelope / header contract:** `keiro-core/src/Keiro/Integration/Event.hs`. Defines
  `IntegrationEvent` (the wire envelope), the canonical header *names*, and the pure
  encode/decode helpers `integrationHeaders`, `integrationPayload`,
  `encodeJsonIntegrationEvent`, `decodeJsonIntegrationEvent`.
- **Inbox (consumer side), in `keiro`:** `keiro/src/Keiro/Inbox.hs`,
  `keiro/src/Keiro/Inbox/Kafka.hs`, `keiro/src/Keiro/Inbox/Types.hs`.
- **Outbox (producer side), in `keiro`:** `keiro/src/Keiro/Outbox.hs`,
  `keiro/src/Keiro/Outbox/Kafka.hs`, `keiro/src/Keiro/Outbox/Types.hs`.

The corpus — hand-written service code these nodes generate — lives in the **external**
`keiro-runtime-jitsurei` repo:
`keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/Integration/{Contracts,Inbox,Outbox,KafkaConsumer,KafkaPublisher}.hs`
and the `incident-command` equivalents under
`services/incident-command/src/IncidentCommand/Integration/`.

The bijection this plan implements:

- `intake` ⇄ `Keiro.Inbox` + `Keiro.Inbox.Kafka` (the consumer/inbox).
- `emit` ⇄ `Keiro.Outbox` (the `IntegrationProducer.mapEvent` mapping) and `publisher`
  ⇄ `Keiro.Outbox.publishClaimedOutbox` + `Keiro.Outbox.Kafka` (the durable outbox drain
  and Kafka publish).
- `contract` ⇄ the service's `Integration/Contracts.hs` — the shared `IntegrationMessage` /
  `IntegrationPayload` schema imported by *both* sides.

### Key runtime facts the spec must encode (with file:line anchors)

These are the non-obvious, load-bearing behaviors of the runtime. The grammar, validator,
and scaffold all exist to make these explicit and safe.

**The inbox envelope is reconstructed entirely from Kafka headers.**
`integrationEventFromKafka` (`keiro/src/Keiro/Inbox/Kafka.hs:86-137`) builds an
`IntegrationEvent` from the record's `[(Text, Text)]` header list. Six headers are
**required** — absence yields `MissingHeader` (`Inbox/Kafka.hs:91-97`). Their canonical
names are constants in `keiro-core/src/Keiro/Integration/Event.hs:209-232`:

| envelope field   | header name (canonical) | required? | source layer |
|------------------|-------------------------|-----------|--------------|
| `source`         | `keiro-source`          | yes       | header       |
| `destination`    | `keiro-destination`     | yes       | header       |
| `eventType`      | `keiro-event-type`      | yes       | header       |
| `schemaVersion`  | `keiro-schema-version`  | yes       | header       |
| `contentType`    | `content-type`          | yes       | header       |
| `messageId`      | `keiro-message-id`      | yes       | header       |
| `key`            | (none — Kafka record key) | no      | kafka-key    |
| `occurredAt`     | (none — delivery `receivedAt`) | no | kafka-cursor |
| `sourceEventId`, `causationId`, `correlationId`, schema-reference fields, `traceparent` | various | no | header (optional) |

Two subtleties the spec must preserve:

- `key` is the Kafka **record key**, not a header (`Inbox/Kafka.hs:112`,
  `Inbox/Kafka.hs:61`). In the spec it binds to `kafka-key`.
- `occurredAt` is set to the delivery `receivedAt`, **not** to any header
  (`Inbox/Kafka.hs:119-125`). The producer's wall-clock `occurredAt` rides separately *in
  the JSON body*. **Two `occurredAt` exist by design.** In the spec these are two distinct
  fields: envelope `occurredAt` binds `kafka-cursor`; body `occurredAt` binds `body`.

**The cross-check is a real hole (hole-kind 4).** `messageId`, `schemaVersion`, and similar
fields exist in *both* the header layer and the JSON body, and **nothing validates that they
match**. The body `messageId` is what the handler stores (`hospital-capacity`
`Inbox.hs:124-127`, column `message_id`), while deduplication keys off the **header**
`messageId` (`PreferIntegrationMessageId` selects `event.messageId`, which came from the
header — `Store.hs:328`, `Inbox/Types.hs:148-152`). A header/body divergence is therefore a
latent bug the runtime will not catch. The DSL forces an explicit cross-check decision per
such field.

**The inbox disposition is a four-way classification, and the acknowledgement mapping is
counter-intuitive service code.** `runInboxTransaction` returns
`InboxResult = InboxProcessed a | InboxDuplicate | InboxInProgress | InboxPreviouslyFailed (Maybe Text)`
(`Inbox.hs:103-106`, `Inbox/Types.hs:81-86`). The mapping from that classification to a
Kafka acknowledgement is *service* code, and in the corpus
(`hospital-capacity` `KafkaConsumer.hs:111-123`) it is:

- `InboxProcessed` → `AckOk`.
- `InboxDuplicate` → **`AckOk`** (a replay is *success*; do not reprocess, do not retry).
- `InboxPreviouslyFailed` → **`AckDeadLetter`** (poison pill — *not* retry).
- decode failure / dedupe failure → `AckDeadLetter` with `InvalidPayload` (terminal — a
  malformed message will never become valid, so retrying is unbounded waste).
- `InboxInProgress` → `AckRetry (RetryDelay 5)` (transient — another attempt is in flight).
- store / DB error → `AckRetry (RetryDelay 5)` (transient — the DB may recover).

The two dangerous inversions the validator must force explicit **and** flag if stated wrong:
`duplicate ⇒ ackOk` (not retry, which would loop forever on every replay), and
`previouslyFailed ⇒ deadLetter` (not retry, which would re-run a known-bad message
endlessly). A third: any invalid/decode case must be terminal (`deadLetter`), never
unbounded `retry`.

**Dedupe policy is a closed enum.** `InboxDedupePolicy = PreferIntegrationMessageId (default)
| PreferSourceEventIdentity | KafkaDeliveryIdentity | CustomDedupeKey Text`
(`Inbox/Types.hs:48-53`). Separately, the handler does a row-level
`ON CONFLICT (message_id) DO NOTHING` on the **body** id (`hospital-capacity`
`Inbox.hs:191`) — a second, independent idempotency guard.

**Decode strictness has three layers (hole-kind 6).** The envelope decode is *lenient* on
optional headers but *strict* on the six required ones (`Inbox/Kafka.hs:86-137`). The body
decode is *strict and schema-version-pinned*: `hospital-capacity` `Contracts.hs:171-174`
hard-fails unless `schemaVersion == 1`; `Contracts.hs:175-181` pins each id field to a
TypeID prefix allow-list; and `Inbox.hs:106-110` applies a *message-type allow-list* (an
inbox that only handles `IncidentTransferNeedDeclared` rejects every other type with
`UnexpectedIntegrationMessage`). The spec states the pinned version concretely and whether
each layer is strict or lenient.

**Runtime config is declared, the loop is delegated (hole-kind 8).**
`HospitalKafkaConsumerConfig { brokers, groupId, topics }` plus environment overrides
(`KafkaConsumer.hs:45-103`), `offsetReset Earliest`, and a `Stream.take 1` single-shot loop
that the application schedules. The DSL declares the consumer-group / batch / pool knobs;
the actual consume loop body is delegated (runtime-owned), not generated.

**Outbox: the private→public mapping is a partial function (holes 3 + 7).** The producer
maps a private `RecordedEvent` to an optional draft via
`mapEvent :: RecordedEvent -> e -> Maybe IntegrationEventDraft` (`Outbox.hs:119-124`);
returning `Nothing` **skips** the event (hole-kind 7, optionality). The corpus maps a status
field to one of N payload constructors or `Nothing` (`hospital-capacity` `Outbox.hs:66-138`:
`"confirmed"→TransferReservationAccepted`, `"released"→TransferReservationRejected`,
`"expired"→TransferExpired`, `"admitted"→PatientAdmitted`, `_→Nothing`) — that is hole-kind 3
(mapping) plus hole-kind 7. The topic is `event.destination` and the partition key is
`event.key` (`Outbox/Kafka.hs:62-63`), both author-chosen values (hole-kind 3). The envelope
encode is fully derived (`Event.hs:160-204`) **except** the live trace headers, which are
stripped and re-injected at *publish* time, not enqueue time (`KafkaPublisher.hs:71-85`).

**Outbox at-least-once delivery.** `publishClaimedOutbox` claims rows
`FOR UPDATE SKIP LOCKED` under an `OrderingPolicy`
(`PerKeyHeadOfLine (default) | PerSourceStream | StopTheLine | BestEffort`,
`Outbox/Types.hs:67-87`) with `maxAttempts` and a `BackoffSchedule`
(`Outbox.hs:240-307`, `Types.hs:152-186`). The `OutboxId` is **stable**, derived from the
`messageId` (`hospital-capacity` `Outbox.hs:188`, `Outbox.hs:241-247`:
`outboxIdForMessage` parses the message TypeID back into the `OutboxId` UUID), so a retried
enqueue coalesces on the `(source, message_id)` unique constraint instead of double-sending.

**The contract is define-once and imported by both sides (hole-kind 5).**
`Integration/Contracts.hs` pins the topic-name constants, the `IntegrationMessage` envelope,
the **closed** `IntegrationPayload` union (one constructor per event type, each with its own
field-set), the `messageType` wire discriminator (a `Text` derived from the payload
constructor — `Contracts.hs:196-205`), and topic-routing predicates. It is imported by both
the producer's `Outbox.hs` and the consumer's `Inbox.hs`. In `incident-command`, the *one*
`IntegrationPayload` union spans **two** topics, with `isIncidentTopicMessage` /
`isHospitalTopicMessage` predicates (`Contracts.hs:210-218`) routing each constructor to its
topic — a single contract, two topics.

### The notation this plan introduces

A `contract` block defines the message shape once. `intake` and `emit` reference it by name.
An `intake` block lists **envelope-binding rows** (each states a field, its wire source —
`header "name"` / `body` / `kafka-key` / `kafka-cursor` — and, for fields present in two
layers, a cross-check decision) and a mandatory, complete **disposition table**. An `emit`
block lists a **mapping** from a private-event discriminant to a contract event type with an
explicit `_ => skip` catch-all, plus the topic and partition-key expressions. A `publisher`
block declares ordering, max-attempts, and backoff for an `emit`'s topic.

Here is a concrete spec transcribed from the real `hospital-capacity` Integration modules,
which the conformance milestone uses verbatim. Topic and event names are the real ones
(`emergency.incident.events`, `emergency.hospital.events`, `IncidentTransferNeedDeclared`,
`TransferReservationAccepted`, …):

```text
service hospital-capacity {

  # ---- The shared schema, define-once (hole-kind 5) ----
  contract emergency {
    schemaVersion 1
    discriminator messageType            # wire field that selects the payload constructor

    topic incidentEvents "emergency.incident.events"
    topic hospitalEvents "emergency.hospital.events"

    # eventType  ->  fieldset  (on which topic)
    event IncidentTransferNeedDeclared on incidentEvents {
      incidentId: typeid "inc"
      triageRecordId: text
      region: text
      patientAcuity: text
      requiredBedType: text
      redCount: int
      requestedByService: text
    }
    event TransferReservationRequested on incidentEvents {
      incidentId: typeid "inc"; reservationId: typeid "rsv"; region: text
      patientAcuity: text; requiredBedType: text; expirationDeadline: text
    }
    event TransferReservationAccepted on hospitalEvents {
      incidentId: typeid "inc"; reservationId: typeid "rsv"; hospitalId: typeid "hsp"
      patientAcuity: text; requiredBedType: text; expirationDeadline: text
    }
    event TransferReservationRejected on hospitalEvents {
      incidentId: typeid "inc"; reservationId: typeid "rsv"; hospitalId: typeid "hsp"
      reason: text
    }
    event PatientAdmitted on hospitalEvents {
      incidentId: typeid "inc"; reservationId: typeid "rsv"; hospitalId: typeid "hsp"
      admissionOutcome: text
    }
    event TransferExpired on hospitalEvents {
      incidentId: typeid "inc"; reservationId: typeid "rsv"; hospitalId: typeid "hsp"
      expiredAt: text
    }
    event HospitalCapacitySnapshotPublished on hospitalEvents {
      hospitalId: typeid "hsp"; snapshotId: typeid "snp"; region: text
      divertStatus: text; capacityLevel: text
      availableIcuBeds: int; staffedIcuBeds: int
      reservedIcuBeds: int; occupiedIcuBeds: int
    }
  }

  # ---- The consumer / inbox (hole-kinds 2,4,6,7,8) ----
  intake incidentInbox {
    contract emergency
    topic incidentEvents
    accept IncidentTransferNeedDeclared            # message-type allow-list; others rejected

    # envelope-binding rows: every contract/envelope field bound to a wire source.
    # The six keiro-required headers MUST be bound `header` and required.
    bind source        from header "keiro-source"          required
    bind destination   from header "keiro-destination"     required
    bind eventType     from header "keiro-event-type"       required
    bind schemaVersion from header "keiro-schema-version"   required  cross-check body
    bind contentType   from header "content-type"           required
    bind messageId     from header "keiro-message-id"       required  cross-check body
    bind key           from kafka-key
    bind occurredAt    from kafka-cursor                              # delivery receivedAt
    bind bodyOccurredAt from body                                     # producer wall-clock
    bind idempotencyKey from body

    dedupe key messageId   policy PreferIntegrationMessageId          # uses the HEADER id

    decode {
      envelope strict-required lenient-optional
      body strict schemaVersion == 1                                   # hard-fail otherwise
    }

    # MANDATORY, COMPLETE disposition table. Every classification + failure class.
    disposition {
      processed        => ackOk
      duplicate        => ackOk              # replay is SUCCESS  (inversion 1)
      inProgress       => retry 5s           # transient
      previouslyFailed => deadLetter "previous inbox failure"   # NOT retry (inversion 2)
      decodeFailed     => deadLetter         # terminal, NOT unbounded retry (inversion 3)
      dedupeFailed     => deadLetter
      storeFailed      => retry 5s           # transient
    }

    consumer { brokers env "HOSPITAL_CAPACITY_KAFKA_BROKERS"
               groupId env "HOSPITAL_CAPACITY_KAFKA_GROUP_ID" default "hospital-capacity-inbox"
               offsetReset earliest }
  }

  # ---- The producer / outbox mapping (hole-kinds 3,7) ----
  emit reservationResponse {
    contract emergency
    topic hospitalEvents
    source "hospital-capacity"
    key incidentId                       # partition key expression (author-chosen)

    # status discriminant -> contract event type ; explicit `_ => skip` is MANDATORY
    map status {
      "confirmed" => TransferReservationAccepted
      "released"  => TransferReservationRejected
      "expired"   => TransferExpired
      "admitted"  => PatientAdmitted
      _           => skip                  # hole-kind 7 (optionality): Nothing skips the row
    }

    # The mapper body (field population, literal/default injection) is a HOLE.
    messageId derive "msg"  hole            # custom id derivation (hole-kind 1)
    idempotencyKey derive   hole
  }

  # ---- The at-least-once publisher for the emit's topic ----
  publisher hospitalPublisher {
    emit reservationResponse
    ordering PerKeyHeadOfLine
    maxAttempts 10
    backoff constant 2s
    outboxId stable from messageId         # retries coalesce on (source, message_id)
  }
}
```

Notice the load-bearing rows: every required keiro header is bound `header … required`; the
`duplicate => ackOk` and `previouslyFailed => deadLetter` rows are present and stated the
*safe* way; the body decode pins `schemaVersion == 1`; and the `map status` has an explicit
`_ => skip`. A spec missing any of these is rejected by `check`.

### The eight hole-kinds, as they appear in this vertical

A "hole" is a behavior-bearing decision the spec records but whose code body the scaffold
does **not** generate (it emits a typed `-- HOLE:` stub instead). The eight kinds:

1. **Derivation** — custom id/idempotency-key derivation (the message-id string surgery in
   `Outbox.hs:215-247`; concatenated idempotency keys in `Outbox.hs:149,200`).
2. **Disposition** — the inbox acknowledgement classification (`AckOk | Retry n |
   DeadLetter r`) with the dangerous inversions.
3. **Mapping** — status→event-type and field population in the mapper body.
4. **Field-source / envelope-binding** — header vs body vs kafka-key vs kafka-cursor, plus
   the header/body cross-check.
5. **Cross-node coupling** — producer `emit` and consumer `intake` referencing the same
   contract id; every event type in `accept`/`map` existing as a contract wire.
6. **Decode strictness** — envelope strict-required/lenient-optional; body strict,
   schema-version-pinned, typeid-prefix-pinned, message-type allow-listed.
7. **Optionality** — `Nothing` skips (the `_ => skip` catch-all; `mapEvent` returning
   `Nothing`).
8. **Runtime config** — consumer group / batch / pool knobs declared; the consume/drain
   loop body delegated to the runtime.

Cross-cutting (inherited from EP-1): **time is injected, never sampled.** Scaffolded code
takes `occurredAt`/`now` as a parameter (see `mintIntegrationEvent` taking `occurredAt` from
the draft, and `runInboxTransactionWithKey` taking `now <- getCurrentTime` only at the I/O
boundary); the harness asserts no scaffolded pure function calls `getCurrentTime`.

### Honest coverage gaps (agent-written holes, not spec failures)

These appear in the corpus and are **not** expressible in the spec by design; they are
agent-written holes pinned by the harness, and the plan records them so a future reader is
not surprised:

- Computed message/idempotency ids: per-status string surgery
  (`Outbox.hs:215-235`, `statusSuffix` reverses/rotates the suffix per status) and
  concatenated idempotency keys (`Outbox.hs:149,200`).
- Per-field literal/default injection in mappers (e.g. `reason = "reservation released"`,
  `admissionOutcome = fromMaybe "admitted" …` — `Outbox.hs:90,110`).
- One contract union spanning two topics with topic-routing predicates
  (`incident-command` `Contracts.hs:210-218`). The grammar expresses the routing
  (`event … on <topic>`); the *predicate functions* are generated, but any hand-tuned
  routing logic beyond per-constructor topic is a hole.
- Cursor/partition parse from a non-keiro `shibuya` `Envelope`
  (`hospital-capacity` `Inbox.hs:224-241`): the adapter that turns a `shibuya`
  `Envelope (Maybe ByteString)` into a `KafkaInboundRecord` is runtime/adapter glue.
- The `occurredAt = receivedAt` vs body-`occurredAt` duality (named, but the choice of
  *which* a downstream consumer reads is a hole).
- Publish-time live-trace strip + re-inject (`KafkaPublisher.hs:71-85`).


## Plan of Work

The work is five milestones. Each is independently verifiable and each builds the
integration vertical strictly additively on top of EP-1's shared engine — no existing keiro
runtime package is touched, only the `keiro-dsl` package is extended.

### Milestone 1 — Grammar and parser

**Scope.** Teach the DSL to *represent and read* the four new blocks. At the end, a `.kdsl`
file containing `contract`/`intake`/`emit`/`publisher` parses into a `Spec` AST and
pretty-prints back to equivalent source.

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add four constructors to the node sum used by
`Spec`. Concretely:

- `Contract` — a record `{ contractName :: Text, schemaVersion :: Int, discriminator :: Text,
  topics :: [(Text, Text)] (alias→wire-name), events :: [ContractEvent] }` where
  `ContractEvent = { eventTypeName :: Text, onTopic :: Text, fields :: [(Text, FieldType)] }`
  and `FieldType = FtText | FtInt | FtTypeId Text | FtBool | …` (mirror the corpus field
  types in `Contracts.hs`: `Text`, `Int`, and TypeID-prefixed text).
- `Intake` — `{ intakeName :: Text, contractRef :: Text, intakeTopic :: Text,
  accept :: [Text] (allow-listed event types), bindings :: [EnvelopeBinding],
  dedupe :: DedupeDecl, decode :: DecodeDecl, disposition :: DispositionTable,
  consumer :: ConsumerConfig }`. `EnvelopeBinding = { field :: Text, wireSource :: WireSource,
  required :: Bool, crossCheck :: Maybe CrossCheck }`,
  `WireSource = FromHeader Text | FromBody | FromKafkaKey | FromKafkaCursor`,
  `CrossCheck = CrossCheckBody | PreferHeader | PreferBody`.
  `DispositionTable` is a record with one field per classification
  (`processed, duplicate, inProgress, previouslyFailed, decodeFailed, dedupeFailed,
  storeFailed :: Disposition`) where `Disposition = AckOk | AckRetry NominalDiffTime |
  AckDeadLetter (Maybe Text)`. Making the seven fields a *record* (not a list) guarantees at
  the *type* level that the table is total — a missing entry is unrepresentable, and the
  parser must supply all seven.
- `Emit` — `{ emitName :: Text, contractRef :: Text, emitTopic :: Text, source :: Text,
  keyExpr :: Expr, statusMap :: StatusMap, idHoles :: [IdHole] }` where
  `StatusMap = { discriminantField :: Text, cases :: [(Text, Text)] (value→eventType),
  fallthrough :: SkipOrType }` and `SkipOrType = MapSkip | MapTo Text`. `keyExpr` reuses
  EP-1's `Expr` sublanguage.
- `Publisher` — `{ publisherName :: Text, emitRef :: Text, ordering :: OrderingPolicy,
  maxAttempts :: Int, backoff :: BackoffDecl, outboxIdStableFrom :: Text }`. Mirror the
  runtime enum `OrderingPolicy` from `keiro/src/Keiro/Outbox/Types.hs:82-87`.

In `keiro-dsl/src/Keiro/Dsl/Parser.hs`, extend `parseSpec` with one megaparsec parser per
block, matching the notation in the Context example. Add the new blocks to the top-level
`many nodeParser`. In the pretty-printer module EP-1 created, add a printer per block so
`parseSpec . prettySpec == Right` for any spec (round-trip property).

Acceptance: from `keiro-dsl/`, `cabal test` runs a parser unit test that parses the
conformance `.kdsl` (Milestone 5's fixture, also embedded as a string literal in the test)
and asserts the resulting `Spec` has one `Contract` with seven events across two topics, one
`Intake` with a seven-row disposition table, one `Emit` with a five-case status map ending
in `MapSkip`, and one `Publisher`. The round-trip property test passes.

### Milestone 2 — Validator rules

**Scope.** Make `check` reject every unsafe or incomplete integration spec. At the end,
`validateSpec` returns precise `Error` diagnostics for each violation and an empty list for
the conformance spec.

In `keiro-dsl/src/Keiro/Dsl/Validate.hs`, add a function
`validateIntegration :: Spec -> [Diagnostic]` and call it from `validateSpec`. Implement
eleven rules:

1. **Disposition completeness.** Every `Intake` supplies all seven classifications. (The
   record type from Milestone 1 makes most of this a parse-time guarantee; the validator
   additionally rejects a `Disposition` that is structurally present but semantically empty,
   e.g. an `AckDeadLetter` with no reason where the spec demanded one.)
2. **Inversion: duplicate must be `AckOk`.** If `disposition.duplicate` is not `AckOk`, emit
   an `Error` quoting "a duplicate redelivery is success; acking it prevents an infinite
   reprocessing loop" with a fix-it suggestion.
3. **Inversion: previouslyFailed must be `AckDeadLetter`.** If it is `AckRetry`, `Error`:
   "a previously-failed message will fail again; dead-letter it instead of retrying."
4. **Inversion: invalid/decode must not unbounded-retry.** If `decodeFailed` or
   `dedupeFailed` is `AckRetry`, `Error`: "a malformed message never becomes valid;
   dead-letter it." (`storeFailed` and `inProgress` *may* retry — they are transient.)
5. **Transient-only-retry.** Only `inProgress` and `storeFailed` may be `AckRetry`; any other
   classification set to `AckRetry` is an `Error`. (Rules 2–4 are the named subcases.)
6. **Envelope-binding completeness.** Every field the contract/envelope needs is bound to
   exactly one `WireSource`; the six keiro-required headers (`keiro-source`,
   `keiro-destination`, `keiro-event-type`, `keiro-schema-version`, `content-type`,
   `keiro-message-id`) must each be bound `FromHeader <canonical-name>` and `required = True`.
   A missing or non-required required-header binding is an `Error`.
7. **Cross-check declaration.** Any field bound to a header *and* also present in the body
   (the validator knows the body fields from the referenced contract event's field-set and
   the well-known dual fields `messageId`, `schemaVersion`) must carry a non-`Nothing`
   `crossCheck`. Omission is an `Error`: "messageId/schemaVersion appear in both header and
   body and nothing validates they match; declare cross-check | prefer-header | prefer-body."
8. **Dedupe-key resolution.** The `dedupe key` field must name a binding that is `required`
   (a dedupe key that can be absent is an `Error`).
9. **Explicit decode strictness with a concrete pinned version.** The `decode` block must
   state envelope strictness and a body `schemaVersion == <n>` literal; absence is an
   `Error` ("decode strictness must be explicit; pin the body schema version").
10. **Cross-node contract coupling.** For every topic, if both an `emit` and an `intake`
    reference it, they must reference the *same* contract id (`Error` if not). Every event
    type appearing in an `intake.accept` or an `emit.map` target must exist as a
    `ContractEvent` of the referenced contract (`Error` if not). A `Warning` is emitted for
    any contract topic that has neither an `emit` nor an `intake`.
11. **Producer at-least-once + skip-totality.** Every `emit` must be paired with exactly one
    `publisher` that declares `ordering`, `maxAttempts`, and `backoff`, and an
    `outboxId stable from <field>` (`Error` if unpaired or missing a knob). Every `emit.map`
    must end in `_ => skip` *or* cover every contract event type on its topic exhaustively
    (`Error`: "status map is not total; add `_ => skip` or cover all cases").

Acceptance: from `keiro-dsl/`, a validator test suite with one positive case (the
conformance spec → `[]`) and eleven negative cases, each a minimal spec mutated to violate
one rule, asserting the expected diagnostic message substring appears and `check` exits
non-zero.

### Milestone 3 — Scaffold (symbol-free deterministic layer + typed holes)

**Scope.** Emit compiling Haskell. At the end, `scaffold` writes the contract types, the
inbox/outbox/publisher wiring and config records as `Generated` modules, and the
behavior-bearing pieces as `HoleStub` modules, and every `Generated` line satisfies the
firewall invariant.

In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, add emitters:

- `scaffoldContract :: Contract -> ScaffoldModule` (kind `Generated`) — emits a module
  shaped like `Integration/Contracts.hs`: the topic-name constants, the `IntegrationMessage`
  record, the closed `IntegrationPayload` union (one constructor per `ContractEvent` with a
  `<EventType>Data` record carrying the field-set), the `messageType` discriminator function,
  the `parsePayload`/`payloadToValue` codec pair, the schema-version-pinned `FromJSON`, and
  the `isXTopicMessage` routing predicates when the union spans more than one topic. All of
  this is plain ADTs + Aeson — *no keiki symbolic operator* appears, so the firewall holds.
- `scaffoldIntake :: Intake -> [ScaffoldModule]` — a `Generated` wiring module that calls
  `integrationEventFromKafka` (`keiro/src/Keiro/Inbox/Kafka.hs`), threads the chosen
  `InboxDedupePolicy`, runs `runInboxTransaction`, and a `Generated` `ConsumerConfig` record
  mirroring `HospitalKafkaConsumerConfig` with the env-override helper. The disposition
  *function* (`InboxResult → AckDecision`) is emitted as a `HoleStub` with the spec's table
  as a `-- HOLE:` comment block so an agent fills the body against the stated rows (or a
  follow-up may generate the obvious total function directly — left as a hole here to keep
  the scaffold symbol-free and reviewable).
- `scaffoldEmit :: Emit -> [ScaffoldModule]` — a `Generated` module defining the
  `IntegrationProducer` config (`name`/`source`/`messageIdPrefix`) and the draft-construction
  skeleton, plus a `HoleStub` for `mapEvent` (the status→constructor body and field
  population) and for the custom id derivations (`messageId derive`, `idempotencyKey derive`).
- `scaffoldPublisher :: Publisher -> ScaffoldModule` (kind `Generated`) — emits the
  `OutboxPublishOptions` value (`batchSize`/`maxAttempts`/`backoff`/`orderingPolicy`) from the
  declared knobs and the stable-`OutboxId` derivation wiring (`outboxIdForMessage`-shaped),
  calling `publishClaimedOutbox`.

After building each `ScaffoldModule`, run the EP-1 firewall check over every `Generated`
module and fail scaffolding if any `-- @generated` line contains a keiki symbolic operator.

Acceptance: from `keiro-dsl/`, `cabal run keiro-dsl -- scaffold test/fixtures/hospital-capacity.kdsl --out <tmp>`
emits modules; a test compiles the emitted contract module against `keiro-core`/`keiro`
(via a small fixture cabal target or by `ghc -fno-code` type-check) and asserts the
firewall invariant holds on every `Generated` module. The `HoleStub` modules contain
`undefined` bodies and `-- HOLE:` comments and are *not* overwritten on a second scaffold run.

### Milestone 4 — Harness

**Scope.** Emit tests that prove behavior, not just compilation. At the end, the scaffolded
service has a generated test module that round-trips every event type and exercises the full
disposition table.

In `keiro-dsl/src/Keiro/Dsl/Harness.hs`, add an integration harness emitter that produces a
`Generated` test module with:

- A **round-trip golden fixture per event type**: for each `ContractEvent`, build a sample
  `IntegrationMessage`, encode it (`Aeson.encode`), decode it back
  (`Aeson.eitherDecodeStrict`), and assert equality and that `messageType` equals the event
  type name — pinning the contract codec, the discriminator, and the schema-version gate.
- A **disposition-table coverage test**: a table-driven test asserting that for each of the
  seven classifications the disposition function returns the spec's stated acknowledgement.
  This is the test that turns red under the Milestone 5 mutation.
- A **clock-free assertion** (inherited from EP-1): a check that no scaffolded pure function
  references `getCurrentTime`.

Acceptance: from `keiro-dsl/`, after scaffolding the fixture and filling the holes from the
captured reference modules, `cabal test` runs the emitted harness green: N round-trip cases
(one per event type) plus seven disposition cases all pass.

### Milestone 5 — Conformance against the corpus

**Scope.** Prove the vertical is faithful to real services. At the end, a `.kdsl` derived
from `hospital-capacity` and one from `incident-command` scaffold code structurally
equivalent to the hand-written originals, and the harness is green.

Capture the corpus into `keiro-dsl/test/fixtures/`:

- `keiro-dsl/test/fixtures/hospital-capacity/` — a read-only copy of the five
  `Integration/*.hs` reference modules plus `hospital-capacity.kdsl` (the spec in the Context
  section). Primary example: one topic-pair, the four-status `emit` map, the seven-row
  disposition table.
- `keiro-dsl/test/fixtures/incident-command/` — the `incident-command` `Integration/*.hs`
  plus `incident-command.kdsl`. This proves the **one-union-across-two-topics** shape: a
  single `contract` whose `IntegrationPayload` spans `incidentEvents` and `hospitalEvents`
  and whose generated `isIncidentTopicMessage`/`isHospitalTopicMessage` predicates match the
  captured `Contracts.hs:210-218`.

Write a conformance test that scaffolds each fixture and asserts the *generated*
`Contracts`-shaped module agrees with the captured reference on the observable contract: the
same topic-name constants, the same set of event-type constructors, the same per-event
field-sets (name + type), the same `messageType` discriminator strings, and (for
incident-command) the same topic-routing partition of constructors. Then fill the holes from
the captured `Inbox.hs`/`Outbox.hs` and run the harness green.

Finally, the **mutation check**: edit `hospital-capacity.kdsl` to flip
`duplicate => ackOk` to `duplicate => retry 5s`, re-run `check`, and confirm it now *fails*
validation (rule 2); separately, with validation bypassed, confirm the harness disposition
coverage test would turn red. Restore the file.

Acceptance: from `keiro-dsl/`, `cabal test` runs all of the above green on the unmutated
fixtures; the documented mutation makes `check` exit non-zero with the rule-2 diagnostic.


## Concrete Steps

All commands run from the repository root unless a working directory is named. The
`keiro-dsl` package is created by EP-1; confirm it exists before starting.

Confirm the prerequisite engine is present:

```bash
ls keiro-dsl/src/Keiro/Dsl/Grammar.hs keiro-dsl/src/Keiro/Dsl/Parser.hs \
   keiro-dsl/src/Keiro/Dsl/Validate.hs keiro-dsl/src/Keiro/Dsl/Scaffold.hs \
   keiro-dsl/src/Keiro/Dsl/Harness.hs keiro-dsl/app/Main.hs
```

Expected: all six paths listed, no "No such file". If any is missing, EP-1 is not Complete;
stop and finish EP-1 first.

Read the runtime sources you mirror (do this before editing the grammar):

```bash
sed -n '88,233p' keiro-core/src/Keiro/Integration/Event.hs   # envelope + header names
sed -n '86,137p' keiro/src/Keiro/Inbox/Kafka.hs              # header reconstruction
sed -n '48,106p' keiro/src/Keiro/Inbox/Types.hs              # dedupe policy + InboxResult
sed -n '67,138p' keiro/src/Keiro/Outbox/Types.hs            # OrderingPolicy + backoff
```

Build and test the package after each milestone (working directory `keiro-dsl/`):

```bash
cd keiro-dsl && cabal build
cabal test
```

Milestone 1 acceptance transcript (parser test):

```text
Grammar/Parser
  parses hospital-capacity.kdsl
    contract emergency: 7 events across 2 topics      [✔]
    intake incidentInbox: 7-row disposition table     [✔]
    emit reservationResponse: status map ends in skip  [✔]
    publisher hospitalPublisher present                [✔]
  round-trip parse . pretty == id                      [✔]
```

Milestone 2 — run the checker on a deliberately broken spec and observe rejection:

```bash
cd keiro-dsl
cabal run keiro-dsl -- check test/fixtures/bad-duplicate-retry.kdsl ; echo "exit=$?"
```

Expected:

```text
error: intake incidentInbox: disposition `duplicate => retry 5s` is unsafe.
  A duplicate redelivery is a successful replay; retrying loops forever.
  fix: `duplicate => ackOk`.
exit=1
```

And the clean spec passes:

```bash
cabal run keiro-dsl -- check test/fixtures/hospital-capacity/hospital-capacity.kdsl ; echo "exit=$?"
```

```text
ok: 1 contract, 1 intake, 1 emit, 1 publisher; no diagnostics.
exit=0
```

Milestone 3 — scaffold and inspect the generated contract:

```bash
cd keiro-dsl
cabal run keiro-dsl -- scaffold test/fixtures/hospital-capacity/hospital-capacity.kdsl \
  --out /tmp/hc-scaffold
grep -c '^-- @generated' /tmp/hc-scaffold/**/Contracts.hs        # marker present
grep -rl 'HOLE:' /tmp/hc-scaffold                                # the hole stubs
```

Expected: the contract module carries `-- @generated`; the disposition/mapper/id-derivation
modules contain `-- HOLE:`. The firewall self-check runs inside `scaffold` and prints
nothing on success (non-zero exit + a `firewall:` message on violation).

Milestone 4 + 5 — fill holes from the captured references and run the harness:

```bash
cd keiro-dsl && cabal test --test-options="--match Conformance"
```

Expected: every event type round-trips, the seven disposition cases pass, and the
generated-vs-captured contract equivalence assertions pass for both fixtures.

Mutation check (Milestone 5):

```bash
cd keiro-dsl
sed -i.bak 's/duplicate        => ackOk/duplicate        => retry 5s/' \
  test/fixtures/hospital-capacity/hospital-capacity.kdsl
cabal run keiro-dsl -- check test/fixtures/hospital-capacity/hospital-capacity.kdsl ; echo "exit=$?"
mv test/fixtures/hospital-capacity/hospital-capacity.kdsl.bak \
   test/fixtures/hospital-capacity/hospital-capacity.kdsl
```

Expected: `exit=1` with the rule-2 diagnostic, then the file is restored.


## Validation and Acceptance

The change is effective when these behaviors are observable, not merely when code compiles.

**Behavior 1 — the checker rejects the dangerous inversions.** Given a spec whose `intake`
states `duplicate => retry`, `previouslyFailed => retry`, or `decodeFailed => retry`,
`cabal run keiro-dsl -- check <spec>` exits non-zero and prints the corresponding rule-2/3/4
diagnostic naming the field and the fix. Given the safe spec, it exits zero. Test:
`cabal test --test-options="--match Validate"` runs eleven negative cases and one positive
case; all pass.

**Behavior 2 — the checker rejects an unbound required header.** Delete the
`bind messageId from header "keiro-message-id" required` row and `check` reports rule-6 with
the canonical header name. This proves the spec cannot silently omit a header the runtime
requires (`Inbox/Kafka.hs:97` would otherwise produce a `MissingHeader` only at run time).

**Behavior 3 — the checker rejects a missing cross-check.** Remove `cross-check body` from
the `messageId` binding and `check` reports rule-7, because `messageId` is present in both
the header and the body and nothing else validates they agree.

**Behavior 4 — the checker rejects a non-total status map and an unpaired emit.** Remove the
`_ => skip` line and `check` reports rule-11 (not total); remove the `publisher` block and
`check` reports rule-11 (emit not paired with a publisher declaring ordering/maxAttempts/
backoff).

**Behavior 5 — the scaffold emits a symbol-free contract that compiles.** After
`scaffold`, the generated `Contracts`-shaped module type-checks against `keiro-core`/`keiro`,
contains the seven `IntegrationPayload` constructors and the `messageType` discriminator, and
no `-- @generated` line contains a keiki symbolic operator (firewall self-check). Test:
`cabal test --test-options="--match Scaffold"`.

**Behavior 6 — the harness proves behavior per event type.** After filling holes from the
captured reference modules, `cabal test --test-options="--match Conformance"` round-trips all
seven hospital-capacity event types and exercises all seven disposition classifications, and
proves the generated contract equals the captured `Contracts.hs` shape for both
hospital-capacity (one topic-pair) and incident-command (one union across two topics).

**Behavior 7 — mutation turns a test red.** Flipping `duplicate => ackOk` to
`duplicate => retry 5s` makes `check` fail (rule 2) and, with validation bypassed, makes the
harness disposition coverage case for `duplicate` fail. This proves the harness asserts
behavior, not shape.

Acceptance for the whole plan: from `keiro-dsl/`, `cabal build && cabal test` is green on the
unmutated fixtures, the seven behaviors above are reproducible by the exact commands in
Concrete Steps, and the MasterPlan Progress line "EP-4: …" can be checked off.


## Idempotence and Recovery

Every step in this plan is safe to repeat.

- **Editing the engine modules** (`Grammar.hs`, `Parser.hs`, `Validate.hs`, `Scaffold.hs`,
  `Harness.hs`) is ordinary additive source editing under version control; re-run
  `cabal build` freely. If an edit breaks the build, `git diff`/`git checkout -- <file>`
  reverts it.
- **`keiro-dsl -- check`** is read-only: it parses and validates, writing nothing. Run it as
  many times as needed.
- **`keiro-dsl -- scaffold`** is idempotent by construction (the EP-1 discipline this plan
  inherits): `Generated` modules carry `-- @generated` and are *overwritten* on every run, so
  re-scaffolding always reproduces the same deterministic layer; `HoleStub` modules are
  *create-if-absent*, so re-scaffolding never clobbers a filled hole. Scaffolding to a fresh
  `--out` directory (as in Concrete Steps) is fully disposable — `rm -rf /tmp/hc-scaffold`
  to reset.
- **The captured fixtures** under `keiro-dsl/test/fixtures/` are read-only copies of external
  corpus modules; they are never mutated by the toolchain. The mutation check in Milestone 5
  edits a `.kdsl` in place but immediately restores it from the `.bak` it writes; if
  interrupted, restore with `git checkout -- keiro-dsl/test/fixtures/`.
- **No runtime package is touched.** This plan adds only to `keiro-dsl`; `keiro`,
  `keiro-core`, and the corpus services are read-only here, so there is no migration or
  destructive operation to roll back. If the whole vertical needs to be abandoned, removing
  the four `Grammar` constructors and their parser/validator/scaffold cases returns
  `keiro-dsl` to its EP-1 state with no residue elsewhere.

If a milestone's `cabal test` fails partway, the failing milestone's Progress item stays
unchecked and is split into "done" and "remaining" entries; nothing downstream depends on a
half-finished milestone because each is independently verifiable.


## Interfaces and Dependencies

### Libraries and runtime modules consumed (read-only)

This plan generates code that targets, and mirrors the shape of, these existing modules. It
adds no new third-party dependency beyond what EP-1 already pulls in (megaparsec,
optparse-applicative, prettyprinter); the scaffolded *output* depends on `aeson`, `text`,
`keiro`, and `keiro-core`, exactly as the corpus modules do.

- `keiro-core/src/Keiro/Integration/Event.hs` — the envelope contract. The scaffold mirrors
  the canonical header-name constants (`headerSource`, `headerDestination`, `headerEventType`,
  `headerSchemaVersion`, `headerContentType`, `headerMessageId` — `Event.hs:209-232`) and the
  pure helpers `integrationHeaders`/`integrationPayload`/`encodeJsonIntegrationEvent`/
  `decodeJsonIntegrationEvent`. The wire envelope record is
  `IntegrationEvent { messageId, source, destination, key, eventType, schemaVersion,
  contentType, schemaReference, sourceEventId, sourceGlobalPosition, payloadBytes, occurredAt,
  causationId, correlationId, traceContext, attributes }` (`Event.hs:88-105`).
- `keiro/src/Keiro/Inbox/Kafka.hs` — `integrationEventFromKafka :: KafkaInboundRecord ->
  Either KafkaDecodeError (IntegrationEvent, KafkaDeliveryRef)` (`:86-137`); the six
  `MissingHeader` requirements; `KafkaInboundRecord { topic, partition, offset, key, payload,
  headers, receivedAt }`.
- `keiro/src/Keiro/Inbox/Types.hs` — `InboxDedupePolicy = PreferIntegrationMessageId |
  PreferSourceEventIdentity | KafkaDeliveryIdentity | CustomDedupeKey Text` (`:48-53`);
  `InboxResult a = InboxProcessed a | InboxDuplicate | InboxInProgress |
  InboxPreviouslyFailed (Maybe Text)` (`:81-86`); `dedupeKeyFor` (`:142-174`).
- `keiro/src/Keiro/Inbox.hs` — `runInboxTransaction` (`:63-76`) returns the four-way
  classification the disposition table covers.
- `keiro/src/Keiro/Outbox.hs` — `IntegrationProducer { name, source, messageIdPrefix,
  mapEvent }` with `mapEvent :: RecordedEvent -> e -> Maybe IntegrationEventDraft` (`:119-124`);
  `mintIntegrationEvent`/`draftToEvent` (`:157-186`); `publishClaimedOutbox ::
  (OutboxRow -> Eff es PublishOutcome) -> OutboxPublishOptions -> Maybe KeiroMetrics ->
  Eff es OutboxPublishSummary` (`:240-262`).
- `keiro/src/Keiro/Outbox/Types.hs` — `OrderingPolicy = PerKeyHeadOfLine | PerSourceStream |
  StopTheLine | BestEffort` (`:82-87`); `BackoffSchedule = ConstantBackoff NominalDiffTime |
  ExponentialBackoff ExponentialBackoffOptions` (`:102-105`); `OutboxPublishOptions { batchSize,
  maxAttempts, backoff, orderingPolicy, tracer }` (`:152-159`); `OutboxId` (`:34`).
- `keiro/src/Keiro/Outbox/Kafka.hs` — `KafkaProducerRecord { topic, key, payload, headers }`,
  `outboxRowToKafkaRecord`, `integrationEventToKafkaRecord` (`:46-67`): topic = `destination`,
  key = `key`.

### EP-1 engine extensions this plan must make (signatures at each milestone's end)

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs` (end of Milestone 1): four new node constructors
`Contract`, `Intake`, `Emit`, `Publisher` added to the `Spec` node sum, with the records
named in Plan of Work (`ContractEvent`, `FieldType`, `EnvelopeBinding`, `WireSource`,
`CrossCheck`, `DispositionTable` (a *record* of seven `Disposition` fields, totality by
type), `Disposition`, `StatusMap`, `SkipOrType`, `ConsumerConfig`, `BackoffDecl`).

In `keiro-dsl/src/Keiro/Dsl/Parser.hs` (Milestone 1): `parseSpec :: Text -> Either ParseError
Spec` extended with `contractP`, `intakeP`, `emitP`, `publisherP`, wired into the top-level
node parser. Pretty-printer extended so `parseSpec . prettySpec` round-trips.

In `keiro-dsl/src/Keiro/Dsl/Validate.hs` (Milestone 2): `validateSpec :: Spec -> [Diagnostic]`
calls a new `validateIntegration :: Spec -> [Diagnostic]` implementing the eleven rules.

In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (Milestone 3): `scaffoldContract :: Contract ->
ScaffoldModule`, `scaffoldIntake :: Intake -> [ScaffoldModule]`, `scaffoldEmit :: Emit ->
[ScaffoldModule]`, `scaffoldPublisher :: Publisher -> ScaffoldModule`, each producing
`ScaffoldModule { modulePath, moduleText, kind }` with `kind = Generated` for the symbol-free
layer and `kind = HoleStub` for the disposition function, mapper bodies, and id derivations.
All `Generated` output satisfies the firewall invariant.

In `keiro-dsl/src/Keiro/Dsl/Harness.hs` (Milestone 4): an integration harness emitter
producing a `Generated` test module with per-event round-trip cases, a seven-row disposition
coverage test, and the clock-free assertion.

### The `contract` artifact EP-5 consumes (cross-vertical contract)

This is MasterPlan Integration Point #8 and the one cross-vertical contact. EP-5
(`docs/plans/63-keiro-dsl-pgmq-workqueue-and-dispatch-nodes.md`) couples a PGMQ queue to a
contract and therefore reads the `Contract` node this plan defines. For EP-5 to depend on it
by path, the stable shape is:

- The `Contract` constructor in `keiro-dsl/src/Keiro/Dsl/Grammar.hs` with fields
  `contractName :: Text`, `schemaVersion :: Int`, `discriminator :: Text`,
  `topics :: [(Text, Text)]` (alias→wire name), and `events :: [ContractEvent]` where
  `ContractEvent = { eventTypeName :: Text, onTopic :: Text, fields :: [(Text, FieldType)] }`.
- A lookup helper `contractByName :: Spec -> Text -> Maybe Contract` and
  `contractEventNames :: Contract -> [Text]` exported from `Keiro.Dsl.Grammar`, so EP-5 can
  resolve a contract reference and enumerate its event types without re-parsing.
- The single-source guarantee: `{topic, eventType→fieldset, schemaVersion, discriminator}`
  lives only in the `Contract` node; `intake`/`emit` (and EP-5's `dispatch`) reference it by
  `contractName`, never redefine it. The cross-node coupling check (Milestone 2, rule 10) is
  the enforcement mechanism EP-5 reuses for queue/contract coupling.

EP-5 should reference this section by path
(`docs/plans/62-keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract.md`,
"The `contract` artifact EP-5 consumes") rather than re-deriving the contract shape.
