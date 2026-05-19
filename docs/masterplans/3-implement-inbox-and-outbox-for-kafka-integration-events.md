---
id: 3
slug: implement-inbox-and-outbox-for-kafka-integration-events
title: "Implement inbox and outbox for Kafka integration events"
kind: master-plan
created_at: 2026-05-17T19:38:14Z
intention: "intention_01krvpz783etasqe2n8q5ea2m6"
---

# Implement inbox and outbox for Kafka integration events

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

This initiative makes the inbox and outbox described in `docs/research/08-subscription-and-process-manager-design.md`, `docs/why-keiro.md`, and the cross-bounded-context architecture notes in `/Users/shinzui/Keikaku/business-application-applications/docs/ebook-principles/service-architecture-blueprint.md` real in the keiro library. After it completes, an application can run one keiro instance inside each bounded context, keep its private Kiroku streams private, publish stable public Kafka integration events from durable local facts, consume integration events into a second bounded context through an idempotent inbox, and prove that duplicate Kafka deliveries do not run the receiving handler twice.

A bounded context is an independently owned domain boundary, such as "ordering" and "billing". In the canonical use case for this MasterPlan, each bounded context has its own Postgres database and its own keiro runtime. They do not share kiroku event streams or read-model tables. They share only integration events on Kafka topics. The outbox belongs to the publishing context and prevents committed local changes from losing their externally visible event. The inbox belongs to the consuming context and prevents Kafka redelivery from applying the same external message twice.

The scope includes the shared integration-event envelope and codec helpers, `keiro_outbox` and `keiro_inbox` schema and codd migrations, outbox enqueue and claiming APIs, a Kafka integration producer subscription that maps private domain events to public versioned contracts after the source event is durable, a Kafka publisher worker built on `kafka-effectful`, inbox deduplication helpers, a Kafka consumer adapter path built on `shibuya-kafka-adapter`, tests for storage and retry behavior, and an executable or integration test that validates two separate keiro contexts exchanging an integration event through Kafka.

The canonical publisher pipeline is three stages: (1) a command commits a private domain event to the local event store; (2) a checkpointed producer subscription reads that durable private event, mints an application-level `message_id`, maps the event to a public `IntegrationEvent`, and writes one `keiro_outbox` row in its own transaction (advancing the subscription checkpoint atomically with the row insert); (3) a separate publisher worker claims outbox rows with `FOR UPDATE SKIP LOCKED`, publishes to Kafka, and marks each row sent or failed. The subscription does not publish to Kafka directly. The outbox row is the durable handoff between "we decided to publish this" and "we actually published this", and it carries the per-row retry, dead-letter, and operational-visibility state that a bare subscription checkpoint cannot.

Inline outbox enqueue from `runCommandWithSqlEvents` is supported as an escape hatch for sagas, process managers, and command paths that need to emit an integration event without an intermediate private domain event. The canonical Kafka-integration path remains subscription→outbox→worker so that public contract evolution is decoupled from command handlers.

The scope excludes exactly-once Kafka transactions between Postgres and Kafka, because no single transaction can cover both systems. The implementation provides at-least-once publishing and consuming with idempotency. It also does not replace the older local-work-queue design: EP-3's pgmq-backed outbox remains the right shape for slow local external work, while this MasterPlan validates Kafka as the cross-bounded-context integration transport.


## Decomposition Strategy

The decomposition follows the lifecycle of an integration event across service boundaries. EP-19 defines the shared event envelope and serialization contract first, because both outbox and inbox must agree on message identity, topic routing, payload bytes, content type, optional schema-registry reference metadata, type tags, schema version, source event identity or global position, causation, correlation, and trace metadata. EP-20 implements both halves of the canonical publisher pipeline: the producer subscription that reads durable private events and writes mapped public integration events into `keiro_outbox`, and the separate publisher worker that claims outbox rows with `FOR UPDATE SKIP LOCKED` and publishes to Kafka. EP-21 implements the inbox deduplication and consume path. EP-22 validates the whole design with two isolated bounded contexts joined only by Kafka.

This split keeps the storage primitives independently verifiable. EP-20 can prove that the subscription writes one outbox row per mapped private event under at-least-once retry, that rows are claimed with `FOR UPDATE SKIP LOCKED`, published, and marked sent or failed, without requiring an inbox. EP-21 can prove that `(source, message_id)` deduplication runs a handler once without requiring a publisher. EP-22 then checks the design-level assumption the user called out: separate keiro instances in separate bounded contexts can share integration events using Kafka, with the inbox and outbox forming the reliability boundary.

Alternatives considered:

- One large "Kafka integration" ExecPlan. Rejected because schema, producer worker, consumer deduplication, and end-to-end validation have different failure modes and would make a single plan too large to restart safely.
- Implement Kafka first, then tables. Rejected because the core correctness claim is database-backed durability and deduplication; Kafka adapters are transport edges that should consume stable storage APIs.
- Build a generic plugin transport abstraction first. Rejected for v1 because Kafka is the only transport the canonical use case requires. The core tables remain transport-neutral enough to add pgmq later, but EP-20 and EP-21 should not invent an abstraction before the Kafka path is proven.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 19 | Define the integration event contract | docs/plans/19-define-the-integration-event-contract.md | None | EP-12, EP-14, EP-16 | Complete |
| 20 | Implement the durable outbox | docs/plans/20-implement-the-durable-outbox.md | EP-19 | EP-12, EP-16 | Complete |
| 21 | Implement the idempotent inbox | docs/plans/21-implement-the-idempotent-inbox.md | EP-19 | EP-14, EP-16 | Not Started |
| 22 | Validate Kafka bounded context integration | docs/plans/22-validate-kafka-bounded-context-integration.md | EP-19, EP-20, EP-21 | EP-16 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-19 has no hard dependency within this MasterPlan. It defines the integration-event envelope, message identity rules, encode/decode functions, and module names that every later plan imports. It has soft dependencies on completed command and read-model work because its design consumes existing `Keiro.Codec`, `Keiro.Command.runCommandWithSqlEvents`, `Keiro.Projection`, and migration conventions.

EP-20 hard-depends on EP-19 because outbox rows store the envelope shape and publisher workers must know how to convert an outbox row into a Kafka `ProducerRecord`. EP-20 also relies on the transaction boundary already implemented by `Keiro.Command.runCommandWithSqlEvents` and `Kiroku.Store.Transaction.runTransactionAppending`, so it can enqueue rows in the same Postgres transaction as a command append or inline projection.

EP-21 hard-depends on EP-19 because inbox deduplication keys use the envelope source and message id. It can proceed in parallel with EP-20 after EP-19 is complete, because the inbox does not need the outbox implementation to prove duplicate suppression. It consumes `shibuya-kafka-adapter` for Kafka delivery, but the storage tests can inject synthetic envelopes without a Kafka broker.

EP-22 hard-depends on EP-19, EP-20, and EP-21 because it validates their integration as a complete scenario: one context writes an outbox row, a publisher sends it to Kafka, a second context consumes it through the inbox, and duplicate delivery is harmless. EP-22 should begin only after the storage and worker APIs are stable.

EP-16 is a soft dependency for every schema-touching child plan because it created the `keiro-migrations` package and codd workflow. EP-20 and EP-21 must extend its migration package rather than adding only runtime `CREATE TABLE IF NOT EXISTS` helpers.


## Integration Points

**Integration-event envelope.** EP-19 owns `Keiro.Integration.Event` and the public types for message identity, source, destination topic, key, payload bytes, content type, optional schema reference, event type, schema version, source event id or source global position, causation id, correlation id, trace headers, and attributes. EP-20 stores this shape in `keiro_outbox` and converts it to Kafka producer records. EP-21 decodes it from Kafka consumer payloads and records its dedupe identity in `keiro_inbox`. EP-22 uses the same type in the two-context example. The canonical persisted payload must be bytes, not only JSON, so future Confluent-compatible schema registry, Apicurio-style registry, Avro, Protobuf, or JSON Schema payloads can be added without rewriting table layout.

**Message identity.** `message_id` is an application-level identifier (UUIDv7 or equivalent time-ordered UUID) minted by the producer subscription when it writes the outbox row, not derived from the source event identity. The envelope also carries `sourceEventId` and `sourceGlobalPosition` as separate fields so consumers, replay tools, and audit can correlate a public message back to the private event that produced it. This keeps message identity stable across publish retries (the same outbox row keeps its id) while letting one source event fan out to multiple integration events when needed.

**Database migrations.** EP-20 and EP-21 both extend `keiro-migrations/sql-migrations/` with forward codd migrations. EP-20 owns `keiro_outbox`; EP-21 owns `keiro_inbox`. Both plans must update `keiro-migrations/test/Main.hs` so the migration test proves the new tables exist after `runAllKeiroMigrations`.

**Producer subscription boundary.** EP-20 consumes Keiro's async projection/subscription conventions so a service can map its private durable domain events into public Kafka contracts from a checkpointed producer subscription. This follows the prior architecture rule: do not make command handlers dual-write to the event store and Kafka. The canonical pipeline is **subscription → outbox → worker**: the subscription decodes one private recorded event, mints a `message_id`, builds the public `IntegrationEvent`, and writes one `keiro_outbox` row in the same transaction that advances its checkpoint; a separate publisher worker claims rows with `FOR UPDATE SKIP LOCKED` and publishes to Kafka. The subscription never publishes to Kafka directly — that boundary is what makes per-message retry, dead-letter, and operational visibility possible. `Keiro.Command.runCommandWithSqlEvents` remains available for local side-effect outbox rows, timers, and process-manager flows that must enqueue an integration event inline (the escape hatch), but the canonical cross-bounded-context Kafka path is the subscription pipeline above.

**Kafka dependencies and adapters.** EP-20 is responsible for adding `kafka-effectful` and `hw-kafka-client`-level producer dependencies if needed. EP-21 is responsible for adding `shibuya-kafka-adapter` if the consuming worker lives in the main library or an example package. EP-22 owns any Redpanda or Kafka test fixture wiring and should reuse the patterns from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/shibuya-kafka-adapter/test/Kafka/TestEnv.hs` rather than inventing a new broker harness.

**Observability metadata.** EP-19 defines metadata fields and naming. EP-20 and EP-21 must preserve `traceparent` and `tracestate` through Kafka headers when available. EP-22 verifies by inspecting envelope fields in tests rather than requiring a full OpenTelemetry backend.


## Progress

- [x] EP-19: define `Keiro.Integration.Event` and pure envelope encode/decode tests. (2026-05-18)
- [x] EP-19: document identity, topic, key, causation, correlation, schema-version, and trace-header conventions. (2026-05-18)
- [x] EP-20: add `keiro_outbox` schema, codd migration, and storage API tests. (2026-05-18)
- [x] EP-20: add outbox claim/publish/mark-result worker functions and Kafka producer conversion tests. (2026-05-18)
- [ ] EP-21: add `keiro_inbox` schema, codd migration, and deduplication API tests.
- [ ] EP-21: add Kafka consumer handling that records inbox receipt and dispatches exactly once per message id.
- [ ] EP-22: build the two-bounded-context Kafka validation scenario.
- [ ] EP-22: document the canonical deployment topology and operational guarantees.


## Surprises & Discoveries

- 2026-05-17: `mori show --full` reports this repository as `shinzui/keiro`, a Haskell framework depending on `shinzui/kiroku`, `shinzui/keiki`, `shinzui/shibuya`, `hasql/hasql`, and `effectful/effectful`. Kafka-specific dependencies are registered separately as `shinzui/kafka-effectful` and `shinzui/shibuya-kafka-adapter`, so this MasterPlan must explicitly add them where used.
- 2026-05-17: `mori registry show shinzui/shibuya-kafka-adapter --full` reports a Kafka adapter with polling, offset commit semantics, partition awareness, and graceful shutdown. Its source converts Kafka records to Shibuya `Envelope` values whose `messageId` is derived from topic, partition, and offset. EP-21 can use that id directly for Kafka delivery deduplication unless EP-19 chooses an application-level message id header as a stronger cross-topic identity.
- 2026-05-18: `mmzk-typeid` (already wired into `cabal.project` as a local package) re-exports a `Data.UUID.V7` generator and a TypeID layer on top of it. EP-20 uses both: UUIDv7 for `outboxId` and TypeID (prefix `"msg"` by default) for the public `messageId`. This avoids a separate UUIDv7 dependency.
- 2026-05-18: Adding `hw-kafka-client` / `kafka-effectful` to the keiro library pulls in librdkafka as a system dep, which is not in the current `flake.nix`. EP-20 keeps the library free of that dependency by defining its own neutral `KafkaProducerRecord` in `Keiro.Outbox.Kafka`. EP-22 bridges to `Kafka.Producer.Types.ProducerRecord` inside its own dependency scope.
- 2026-05-17: `mori registry show shinzui/kafka-effectful --full` reports producer support including synchronous publish and transactions. This MasterPlan does not rely on Kafka transactions for Postgres atomicity; the durable outbox is still required because Postgres and Kafka do not share a transaction manager.
- 2026-05-17: `/Users/shinzui/Keikaku/business-application-applications/docs/ebook-principles/service-architecture-blueprint.md` §9 and `/Users/shinzui/Keikaku/business-application-applications/docs/ebook-principles/00-ideal-platform-architecture.md` specify the cross-bounded-context Kafka design more sharply than the initial draft of this MasterPlan: a producer subscription maps private domain events to stable public integration events after the local event is durable. Kafka integration events must not mirror private domain event ADTs mechanically, must include source event identity or source global position, and must be versioned independently from private events.
- 2026-05-17: `docs/why-keiro.md` §5.4 and `docs/research/08-subscription-and-process-manager-design.md` §6-§7 still define the first-class `keiro_outbox`/`keiro_inbox` table pair. The updated decomposition therefore keeps table-backed outbox/inbox primitives while making the Kafka producer-subscription pattern the canonical cross-bounded-context validation path.
- 2026-05-17: Future schema-registry integration requires the integration-event payload to be modeled as bytes plus metadata, not as a Haskell `Value` or Postgres `jsonb` only. JSON remains the v1 encoding, but EP-19, EP-20, and EP-21 must preserve optional schema subject/version/id/fingerprint metadata and avoid baking registry choice into the core API.
- 2026-05-17: Running the child-plan init script concurrently created four `docs/plans/19-...` files with duplicate ids. The files were renamed to the serial sequence 19 through 22 and the generated id fields were corrected to match, preserving the skeleton content and recording this as a coordination decision below.
- 2026-05-18: Pre-implementation validation pass surfaced a latent ambiguity in EP-20. The previous wording said the producer subscription "publishes" mapped integration events; in practice that could mean either "writes outbox rows" or "calls Kafka directly with a checkpoint." These are different architectures with different operational profiles. Decision: the canonical pipeline is subscription → outbox → worker (see Decision Log). The subscription itself never touches Kafka. The outbox table earns its keep with per-message DLQ, observability via `SELECT * FROM keiro_outbox WHERE sent_at IS NULL`, and an out-of-band enqueue path for sagas and process managers; the inbox remains the only thing that actually delivers idempotency on the consumer side. Child plans EP-19, EP-20, EP-21, and EP-22 were updated to reflect this and the message-id minting decision below.
- 2026-05-18: Same validation pass also surfaced that the original EP-20 claim query allowed the publisher to skip a failed row and publish a later row with the same Kafka key, which silently breaks per-partition order (e.g. `OrderShipped` before `OrderPaid`), corrupts log-compacted topic views, and can let saga steps progress past a step that never actually published. Decision: the publisher worker enforces per-key head-of-line blocking by default, and a row that fails `max_attempts` times transitions to a terminal `dead` status so a permanently broken event does not freeze its key forever. See the two ordering/DLQ entries in the Decision Log.
- 2026-05-18: EP-19 surfaced a name collision between `IntegrationEventError.DecodeFailed` and the existing `Keiro.Codec.CodecError.DecodeFailed`. Resolved by *not* re-exporting `Keiro.Integration.Event` from the top-level `Keiro` module — callers import it directly, matching the `Keiro.ReadModel` precedent.


## Decision Log

- Decision: Decompose the initiative into four child ExecPlans: shared integration-event contract, durable outbox, idempotent inbox, and Kafka bounded-context validation.
  Rationale: The contract is a hard dependency for both storage paths, outbox and inbox are independently testable after the contract lands, and the Kafka scenario should validate stable APIs rather than define them.
  Date: 2026-05-17.

- Decision: Make Kafka the canonical validation transport while keeping the outbox and inbox storage APIs transport-neutral.
  Rationale: The user's canonical use case is separate keiro instances sharing integration events over Kafka. At the same time, correctness lives in Postgres-backed durability and deduplication, so the core tables should not bake in Kafka-only names where neutral names are clearer.
  Date: 2026-05-17.

- Decision: Model the canonical Kafka producer as a checkpointed subscription over private local domain events, not as command-handler Kafka publishing.
  Rationale: The prior architecture design says the local domain event is durable first, then a service-owned producer subscription maps it to a public integration event and publishes/checkpoints. This avoids making command handlers responsible for a Message DB plus Kafka dual write and keeps private event evolution independent from Kafka contract evolution.
  Date: 2026-05-17.

- Decision: The canonical publisher pipeline is **subscription → outbox → worker**. The producer subscription writes mapped public integration events into `keiro_outbox` in the same transaction that advances its checkpoint; a separate publisher worker claims rows with `FOR UPDATE SKIP LOCKED` and publishes to Kafka. The subscription itself never publishes to Kafka. Inline outbox enqueue from `runCommandWithSqlEvents` remains available as an escape hatch for sagas and process managers but is not the canonical Kafka-integration path.
  Rationale: A bare publishing subscription with a checkpoint is itself a form of transactional outbox, but a single checkpoint cursor cannot park a poison message — one unpublishable event blocks every event behind it. A dedicated `keiro_outbox` row carries `attempts`, `last_error`, and `sent`/`failed`/`dead` status per message, supports per-row DLQ, makes "what is pending to Kafka right now?" a first-class SQL query, and gives sagas/process managers a place to enqueue integration events that do not correspond to a single private domain event. The cost is one extra table and one extra worker stage; for cross-bounded-context integration that price is worth paying. Idempotency itself remains an inbox concern; the outbox provides durability and operational ergonomics, not exactly-once publish.
  Date: 2026-05-18.

- Decision: `message_id` is an application-level identifier (UUIDv7 or equivalent time-ordered UUID) minted by the producer subscription when it writes the outbox row, not derived from the source event identity. The envelope persists `sourceEventId` and `sourceGlobalPosition` as separate fields alongside `message_id`. The inbox's default dedupe policy is `(source, message_id)`.
  Rationale: A UUIDv7 minted at outbox enqueue is stable across publish retries because it lives in the row, time-ordered for index locality, and independent of source identity — so a single source event can fan out to multiple integration events with distinct ids when needed. Keeping `sourceEventId` and `sourceGlobalPosition` alongside preserves traceability, audit, and replay tooling, and lets a consuming service fall back to source-position deduplication when it wants to suppress reissued public events that share an upstream cause.
  Date: 2026-05-18.

- Decision: The publisher worker enforces **per-key head-of-line blocking** by default. The claim query refuses to claim a row whose `(source, message_key)` has an earlier non-terminal sibling (status not in `sent` or `dead`). Rows with `message_key IS NULL` bypass the block because Kafka makes no cross-key ordering promise for null-keyed records. `OutboxPublishOptions` exposes opt-in upgrades to per-source-stream strict order or stop-the-line, and opt-out to best-effort no-blocking for callers whose events have no per-key relationship.
  Rationale: Skipping a failed row and publishing a later row with the same key violates the per-partition ordering guarantee that Kafka consumers are written against — `OrderShipped` would arrive before `OrderPaid` for the same order, lifecycle projections would see orphan updates before creates, saga steps could charge a card whose inventory reservation never published, and log-compacted topics would record a permanently lossy view. Per-key head-of-line is cheap (one `NOT EXISTS` clause plus a `(source, message_key, created_at) WHERE status NOT IN ('sent', 'dead')` index) and contains blast radius to one aggregate at a time. Best-effort no-blocking is not safe as a silent default; making it an explicit opt-in surfaces the correctness cost.
  Date: 2026-05-18.

- Decision: A row that fails to publish `max_attempts` times transitions to a terminal `dead` status and stops blocking its key. `max_attempts` is configurable per publisher (default 10). Operators are responsible for inspecting, resurrecting, or dropping dead rows. Transient and permanent errors are not distinguished automatically in v1 — every error counts an attempt.
  Rationale: Without an automatic terminal state, a permanently-broken row (oversized payload, schema-registry reject, topic doesn't exist, unrecoverable serialization bug) blocks its key forever and requires immediate operator response. Auto-dead-letter after a bounded number of attempts preserves liveness for the healthy traffic on the same key while still surfacing the failure as a first-class operational artifact (`SELECT * FROM keiro_outbox WHERE status = 'dead'`). Distinguishing transient from permanent errors is valuable but requires a careful Kafka-error taxonomy; deferring that to a later refinement keeps EP-20 small.
  Date: 2026-05-18.

- Decision: Provide at-least-once delivery with idempotent receive, not exactly-once delivery across Postgres and Kafka.
  Rationale: Postgres command commits and Kafka publishes cannot be enclosed in one atomic transaction. The transactional outbox narrows the failure window to durable retry, and the inbox handles duplicate Kafka delivery explicitly.
  Date: 2026-05-17.

- Decision: Make the integration-event wire payload schema-registry-ready by storing bytes plus optional schema reference metadata.
  Rationale: A future schema registry may identify schemas by subject/version, numeric schema id, content type, or fingerprint, and formats may include JSON, JSON Schema, Avro, or Protobuf. If Keiro stores only `jsonb` as the canonical payload, future registry integration would require a disruptive table and API migration. Storing bytes now keeps JSON as a v1 encoding while preserving a clean path to registry-backed binary formats.
  Date: 2026-05-17.

- Decision: Correct the child-plan numbering race by renaming the generated files to 19, 20, 21, and 22.
  Rationale: The init script was invoked concurrently and allocated duplicate `id: 19` frontmatter. Serial invocation would have produced the 19 through 22 sequence after the existing `docs/plans/18-...` file. A valid MasterPlan registry requires unique child identifiers and paths.
  Date: 2026-05-17.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revisions

- 2026-05-18: Pre-implementation validation pass. Made the canonical publisher pipeline explicit as subscription → outbox → worker, with inline `runCommandWithSqlEvents` enqueue retained as an escape hatch. Set `message_id` as an application-level UUIDv7 minted at outbox enqueue, with `sourceEventId` and `sourceGlobalPosition` persisted alongside. Cascaded the message-id and pipeline decisions into EP-19, EP-20, EP-21, and EP-22. Updated Vision & Scope, Decomposition Strategy, Integration Points, Surprises & Discoveries, and Decision Log accordingly.
- 2026-05-18: Same pass added ordering correctness to the publisher: per-key head-of-line blocking by default and an auto-dead-letter terminal status after `max_attempts`. Cascaded into EP-20 (claim query, schema, acceptance), EP-21 (note that per-key order is now preserved on the wire), and EP-22 (head-of-line + dead-letter validation scenario).
