---
id: 22
slug: validate-kafka-bounded-context-integration
title: "Validate Kafka bounded context integration"
kind: exec-plan
created_at: 2026-05-17T19:38:22Z
intention: "intention_01krvpz783etasqe2n8q5ea2m6"
master_plan: "docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md"
---

# Validate Kafka bounded context integration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan validates the design against the canonical use case: one keiro instance per bounded context, separate Postgres databases, and Kafka topics as the only integration boundary. After this change, a developer can run a test or example where an Ordering context appends a private local event, a checkpointed Ordering integration-producer subscription maps that private event plus its source identity into a public `OrderSubmitted` Kafka contract, Billing consumes it through its inbox, and Billing appends or records its own local reaction exactly once even if Kafka delivers or Ordering republishes the same integration event more than once.

The goal is not just a demo. This plan proves that EP-19's envelope, EP-20's outbox, and EP-21's inbox compose into the reliability story promised by `docs/research/08-subscription-and-process-manager-design.md`: at-least-once transport plus idempotent receive across independently deployed contexts.


## Progress

- [x] Build a two-context fixture with isolated databases and no shared Kiroku streams. (2026-05-18) — `withTwoContexts` in `test/Main.hs` starts two ephemeral Postgres instances and two `KirokuStore` handles. Outbox lives in the Ordering store; inbox lives in the Billing store; no shared schema.
- [~] Add a Kafka or Redpanda test harness reusing shibuya-kafka-adapter patterns. (2026-05-18, deferred) — A real broker harness requires librdkafka as a system dep, which is not in `flake.nix`. The cross-context test instead uses an in-process Kafka simulator (an MVar acting as a topic) that exercises the EP-19 envelope, EP-20 outbox, and EP-21 inbox composition. The broker-bridge surface (`Kafka.Effectful.Producer.produceMessageSync` for publish, `shibuya-kafka-adapter` for consume) is documented in `docs/guides/integration-events-with-kafka.md` as the next deployment step.
- [x] Exercise the Ordering Kafka integration producer subscription from private event to public topic. (2026-05-18) — `Keiro.Outbox.enqueueIntegrationEventTx` + `publishClaimedOutbox` drain into the in-process topic; one test asserts the published count and the consumer-side row count match.
- [x] Exercise inbox consume in Billing and prove duplicate delivery is harmless. (2026-05-18) — A redelivery test re-applies the same Kafka record with a different offset and asserts the Billing handler runs once.
- [x] Exercise per-key head-of-line ordering and the dead-letter unblock path. (2026-05-18) — Two tests: an ordering test asserts events for the same key arrive in submission order; a dead-letter test asserts a stuck row transitions to `dead` after `maxAttempts` failures and unblocks its successor.
- [x] Document the topology, guarantees, and operational runbook. (2026-05-18) — `docs/guides/integration-events-with-kafka.md` covers the topology, guarantees, ordering policy trade-offs, retention guidance, and broker-test follow-up.


## Surprises & Discoveries

- 2026-05-18: librdkafka (and therefore `hw-kafka-client` / `kafka-effectful`) is not in the current `flake.nix`. Including the real Kafka producer in `keiro` would break nix builds for the whole library. Chose to deliver the cross-context validation with an in-process Kafka simulator so the keiro library stays Kafka-deps-free, with the broker bridge documented as the next step in the integration-events guide.
- 2026-05-18: `publishClaimedOutbox` claims at most one row per `(source, message_key)` per pass under `PerKeyHeadOfLine`, so the same-key ordering test calls the worker twice to drain both events. This is the intended behavior (a stuck predecessor must reach a terminal status before its successor is claimable), not a quirk of the test.
- 2026-05-18: `EphemeralPg.withCached` invocations nest cleanly to give two separate Postgres databases inside one test, which keeps the cross-context fixture self-contained without needing a process-compose recipe.


## Decision Log

- Decision: Validate with two separate stores rather than two logical streams in one store.
  Rationale: The user explicitly called out separate keiro instances per bounded context. Sharing one Kiroku database would miss the deployment boundary the inbox and outbox are meant to support.
  Date: 2026-05-17.

- Decision: Treat Kafka as the only shared state in the validation scenario.
  Rationale: The scenario must prove contexts exchange integration events, not internal event-store records or read-model tables.
  Date: 2026-05-17.


## Outcomes & Retrospective

- Cross-context validation is exercised by three new tests under the
  "Keiro cross-context Kafka integration" describe block in
  `test/Main.hs`: end-to-end happy path with duplicate redelivery,
  per-key submission-order preservation, and head-of-line + dead-letter
  unblock.
- `withTwoContexts` fixture stands up two isolated ephemeral Postgres
  databases with their own `KirokuStore`. No keiro tables or kiroku
  streams are shared. The only shared state is the in-process Kafka
  topic MVar.
- The broker-level test against Redpanda is intentionally deferred to
  keep keiro itself free of `hw-kafka-client` / librdkafka. The
  integration-events guide describes the wiring an integrator
  performs to bridge `Kafka.Effectful.Producer.produceMessageSync`
  and `shibuya-kafka-adapter` into the same in-process surface that
  the test exercises today.
- `docs/guides/integration-events-with-kafka.md` is now the canonical
  operational reference for the canonical Kafka topology and the
  guarantees that compose from EP-19, EP-20, and EP-21.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. This plan depends on the three earlier child plans of `docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md`:

- `docs/plans/19-define-the-integration-event-contract.md` defines `Keiro.Integration.Event`.
- `docs/plans/20-implement-the-durable-outbox.md` defines outbox storage and publishing.
- `docs/plans/21-implement-the-idempotent-inbox.md` defines inbox deduplication and Kafka consume helpers.

The current test suite already uses ephemeral PostgreSQL in `test/Main.hs` for command, snapshot, read-model, and process-manager behavior. The migration package has its own ephemeral PostgreSQL test in `keiro-migrations/test/Main.hs`. Reuse these patterns for two separate Postgres databases: one Ordering database and one Billing database.

Kafka test patterns live in the dependency source found by Mori: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/shibuya-kafka-adapter/test/Kafka/TestEnv.hs`. That package also has Redpanda/process-compose development recipes in its README. Prefer reusing its test environment helpers if they are importable; otherwise copy only the minimal approach into this repo and record why direct reuse was not practical.

A bounded context in this validation is not a Haskell module boundary. It is a runtime boundary: separate store connection, separate keiro schema, separate local event streams, and only Kafka messages crossing between them.


## Plan of Work

Milestone 1 builds a local two-context fixture without Kafka. Add test fixtures under `test/` or `jitsurei/` that define Ordering and Billing event streams. Ordering should have a command such as `SubmitOrder` that appends a private local `OrderSubmittedLocal` event. A producer-subscription mapper then converts that durable private event and its `RecordedEvent` metadata into a public integration event with source `ordering`, destination topic `billing.orders.v1`, key `order-123`, event type `OrderSubmitted`, source event id and source global position taken from the recorded event, content type `application/json`, JSON payload bytes, and an optional schema reference such as subject `billing.orders.v1.OrderSubmitted`. The EP-20 producer-subscription helper mints `message_id` as a UUIDv7 when it writes the outbox row; the test should not pre-supply or compute `message_id` from the source event. Billing should have a handler that consumes that integration event and translates it into a local Billing concept, such as a `BillingOrderOpened` command or an external-order snapshot row. Acceptance: with direct function calls, the producer mapper writes one outbox row per private event, the publisher worker (or fake) drains it, and inbox processing in the Billing context records exactly one local reaction across two different ephemeral Postgres stores.

Milestone 2 adds Kafka infrastructure. Add a test suite, executable, or jitsurei example depending on repository conventions after EP-20 and EP-21 land. If automated Kafka is feasible, add a test that starts Redpanda using the helper pattern from `shibuya-kafka-adapter`. If a broker cannot be reliably started in the normal test suite, add a jitsurei executable and a documented manual validation command instead. The plan should prefer automated validation but must not make `cabal test all` depend on a locally unavailable daemon unless the repo already has that pattern.

Milestone 3 wires publish and consume. Run the Ordering command, run the Ordering integration producer subscription until it publishes the mapped public event to Kafka, run the Billing Kafka consumer until it processes one message through the inbox, and assert that Billing's local database has exactly one reaction. Use a bounded wait with clear timeout, not an infinite worker.

Milestone 4 proves duplicate behavior. Publish the same outbox row twice (e.g. mark the row pending after a successful publish and let the worker republish), or reset the consumer offset to redeliver the same payload at a different Kafka offset. Both attempts carry the same `(source, message_id)` because `message_id` lives on the outbox row. Billing's inbox must report duplicate on the second delivery using the default `(source, message_id)` policy, and Billing's local reaction count must remain one. As a secondary scenario, exercise the `PreferSourceEventIdentity` policy by republishing the same private event through a fresh outbox row (so a new `message_id` is minted) and assert the inbox still suppresses the second handler run.

Milestone 5 proves per-key head-of-line ordering and the dead-letter unblock path. Submit two Ordering commands that produce two private events for the *same* `order_id` (the Kafka key) — `OrderSubmitted` then `OrderCancelled`. Inject a failure into the publisher's Kafka send so the first row (`OrderSubmitted`) fails transiently `max_attempts` times configured low for the test (e.g. 3). While that row is in `failed` status, assert that the second row (`OrderCancelled`, same key) is *not* claimed and not delivered to Kafka. After the first row transitions to `dead`, assert the second row becomes claimable and publishes. Then, separately, do a positive ordering test: two rows for the same key that both publish successfully arrive at the Billing inbox in submission order (`OrderSubmitted` first, `OrderCancelled` second), and Billing's local reaction sequence reflects that order. Also exercise a third row with a *different* key concurrent with a stuck row: it should publish without waiting.

Milestone 6 documents the topology. Add a guide such as `docs/guides/integration-events-with-kafka.md` and link it from `docs/guides/README.md` or `docs/user/README.md`. Include the operational guarantees: outbox gives durable at-least-once publish; the publisher worker enforces per-key head-of-line ordering by default so per-partition Kafka order is preserved for events sharing a `message_key`; auto-dead-letter after `max_attempts` prevents a permanently-broken row from freezing its key and surfaces stuck messages as a first-class operational artifact (`SELECT * FROM keiro_outbox WHERE status = 'dead'`); Kafka gives at-least-once delivery; inbox gives idempotent receive within the retention window keyed on `(source, message_id)`; no cross-service distributed transaction is promised. Document the alternate `OrderingPolicy` choices (`PerSourceStream`, `StopTheLine`, `BestEffort`) and the situations where each applies.


## Concrete Steps

Start with dependency lookup:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori show --full
mori registry show shinzui/shibuya-kafka-adapter --full
mori registry show shinzui/kafka-effectful --full
```

Inspect the Kafka test harness:

```bash
sed -n '1,240p' /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/shibuya-kafka-adapter/test/Kafka/TestEnv.hs
```

After implementing the validation fixture:

```bash
cabal build all
cabal test keiro-migrations-test
cabal test keiro-test
```

If an optional Kafka integration test is split behind a Cabal flag or separate executable, document and run the exact command, for example:

```bash
cabal test keiro-kafka-integration-test
```

or:

```bash
cabal run jitsurei-kafka-integration-events
```

Expected successful output should include a concise line like:

```text
[keiro-kafka-integration] ordering published 1 event; billing processed 1 event; duplicate deliveries ignored: 1
```


## Validation and Acceptance

Acceptance requires:

- The validation uses two separate Postgres stores or schemas initialized independently with Kiroku and Keiro migrations.
- Ordering's local command commits even though Billing has no direct database access to Ordering.
- Ordering's producer subscription publishes an integration event to Kafka with the EP-19 message id, source event identity/global position, content type, optional schema reference, and headers.
- Billing consumes the Kafka message through the EP-21 inbox and records a local reaction.
- Delivering the same integration event twice, including at a different Kafka offset, leaves exactly one Billing reaction and one completed inbox row for the stable source dedupe key.
- Two integration events with the same Kafka key (e.g. `OrderSubmitted` then `OrderCancelled` for the same order) arrive at the Billing inbox in submission order, and the Billing local reaction sequence reflects that order.
- When the first row for a key fails repeatedly, the second row for the same key is not published until the first reaches a terminal status (`sent` or `dead`).
- A row that exceeds the configured `max_attempts` transitions to `status = 'dead'`, stops blocking its key, and remains in the table for operator inspection.
- A row with a *different* key from a stuck row publishes without waiting on the stuck row.
- Documentation explains that `message_id` is minted by the producer subscription at outbox-enqueue time (UUIDv7), Kafka topic/partition/offset are delivery metadata only, `(source, message_id)` is the default deduplication key with source event identity available as an opt-in alternate policy, and per-key head-of-line is the default ordering policy with alternates available for advanced use.


## Idempotence and Recovery

Tests should generate unique topic names, consumer group ids, stream ids, and message ids per run. If Redpanda/Kafka topics are reused, the test must seek or use a fresh consumer group so old messages do not affect assertions.

If the automated Kafka harness is flaky in the local environment, keep the storage-level tests mandatory and move the broker scenario to a documented jitsurei executable with a clear manual command. Record the tradeoff in Surprises & Discoveries and keep the bounded-context validation guide explicit about what was machine-tested.


## Interfaces and Dependencies

This plan consumes these keiro modules once prior child plans are complete:

- `Keiro.Integration.Event` for message envelope and encode/decode.
- `Keiro.Outbox` and possibly `Keiro.Outbox.Kafka` for enqueue, claim, and publish.
- `Keiro.Inbox` and possibly `Keiro.Inbox.Kafka` for deduplicated consume.
- `Keiro.Command`, `Keiro.EventStream`, and `Keiro.Codec` for local context commands.
- `Keiro.Migrations` from the `keiro-migrations` package for database initialization.

External dependencies are `kafka-effectful` for Kafka production and `shibuya-kafka-adapter` for Kafka consumption. The broker in tests should be Redpanda if reusing the existing adapter test environment, because that dependency already validates against Redpanda.

The validation fixture should expose no new core library API unless implementation reveals a missing ergonomic helper. If a helper is needed, record it in the Decision Log and add it to the relevant EP-20 or EP-21 plan before implementing it here.
