---
id: 120
slug: add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge
title: "Add an acked batch publish API to kafka-effectful and a reference outbox bridge"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
master_plan: "docs/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review.md"
---

# Add an acked batch publish API to kafka-effectful and a reference outbox bridge

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today, no shipped API can publish keiro's transactional outbox to Kafka safely. keiro's batch publish contract (`keiro/src/Keiro/Outbox.hs`, keiro-repo-relative) says `PublishSucceeded` means "Kafka acknowledged the publish" — but the only batch operation in `kafka-effectful` reports whether librdkafka *enqueued* each record in client memory, not whether the broker acknowledged it. A deployment that wires the obvious pieces together will mark outbox rows `sent` for messages that never reached the topic whenever the broker is down long enough, authentication fails, or the broker rejects a record — silent, unrecoverable event loss at the transport edge (finding KFK-3 of the July 2026 transport review, CRITICAL). The one sound primitive, `produceMessageSync`, forces a full producer-queue flush per record, destroying batching; and a naive `traverse` of it violates keiro's per-key ordering clause on partial failure. Additionally, nothing anywhere mandates the producer properties this path needs (`acks=all`, idempotence), and no code anywhere actually connects keiro to librdkafka — the "bridge" exists only as guide prose.

After this plan: `kafka-effectful` ships **`produceMessageBatchAcked`** — enqueue every record with a per-message delivery callback, flush once, collect all broker reports, return per-record results in input order — and the keiro repository contains a **compiled, tested reference bridge** that implements keiro's `publishClaimedOutbox` publish callback on top of it, with per-key failure re-mapping, exercised by tests that simulate broker-side delivery failures with no broker running. You can see it working three ways: a live example in kafka-effectful that publishes a batch to local Redpanda and prints per-record broker offsets (and per-record errors when the broker is stopped); the new keiro contract tests proving a broker-ack failure marks rows failed and never sent; and the keiro suite growing from its 335/0 baseline.

Work spans two repositories, each with commands run from its own root: **kafka-effectful** at `/Users/shinzui/Keikaku/bokuno/kafka-effectful` (the API), and **keiro** at `/Users/shinzui/Keikaku/bokuno/keiro` (the reference bridge + contract tests; this plan file lives here). A third repository is read-only grounding: **hw-kafka-client** at `/Users/shinzui/Keikaku/hub/haskell/hw-kafka-client-project` (the low-level client whose delivery-report machinery the new API builds on). Note carefully: keiro currently has **no library dependency** on kafka-effectful or hw-kafka-client — no keiro `.cabal` mentions either — and the runtime library keeps it that way. This plan adds a **test-suite-only** dependency (a deliberate, recorded decision; see Decision Log), so `Keiro.Outbox.Kafka` remains a pure, transport-neutral converter and keiro's library still builds without librdkafka.

This plan is child EP-2 of the master plan at `docs/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review.md`. Siblings, referenced by path only: `docs/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter.md` (consumer side; fully independent of this plan) and `docs/plans/121-enforce-consumer-offset-store-configuration-and-correct-the-kafka-transport-docs.md` (docs; it quotes this plan's API name **exactly as fixed in this plan's Decision Log** — do not rename `produceMessageBatchAcked` without updating that Decision Log entry, since plan 121's implementer reads it). Per the master plan's Integration Points, this plan must NOT edit `docs/guides/integration-events-with-kafka.md` or `docs/user/production-status.md` in keiro; those belong to plan 121.


## Progress

- [ ] Milestone 1: `ProduceMessageBatchAcked` operation added to the `KafkaProducer` effect with smart constructor `produceMessageBatchAcked`; haddock mandates producer properties.
- [ ] Milestone 1: plain interpreter implemented (per-record MVar callbacks, single flush, in-order collection); OTel interpreter case implemented.
- [ ] Milestone 1: `examples/BatchAckedPublish.hs` added behind the `examples` flag; manual run against Redpanda captured (success offsets; per-record failures with broker stopped).
- [ ] Milestone 2: kafka-effectful CHANGELOG entry written; version bumped to 0.4.0.0; test suite green.
- [ ] Milestone 3: keiro test-suite dependency added (kafka-effectful, hw-kafka-client); dev override via `cabal.project.local` documented and working.
- [ ] Milestone 3: reference bridge module `test/Keiro/TestBridge/Kafka.hs` written (record conversion, `produceMessageBatchAcked` call, per-key re-map).
- [ ] Milestone 3: fake effect-level interpreter written; three contract tests passing (ack-failure never marks sent; mid-batch same-key re-map; per-key order/input-order preservation).
- [ ] Milestone 3: full `cabal test keiro-test` green (baseline 335 examples / 0 failures, plus the new examples).
- [ ] Master plan Progress checkboxes for EP-2 updated; Decision Log entries confirmed final for plan 121 to quote.

## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The new operation is named **`produceMessageBatchAcked`**, with effect constructor `ProduceMessageBatchAcked` and smart constructor signature `produceMessageBatchAcked :: (KafkaProducer :> es) => [ProducerRecord] -> Eff es [Either KafkaError Offset]`, results in input order, one flush per call. This name and signature are frozen for sibling plan `docs/plans/121-...md` to quote in keiro's guide.
  Rationale: it reads as the acked sibling of the existing `produceMessageBatch`, and the `[Either KafkaError Offset]` shape gives callers both the broker-assigned offset on success and the precise per-record error on failure, positionally aligned with the input (the batch APIs' record-pairing alternative was rejected because `ProducerRecord` has no `Eq`-friendly identity and input order is the contract keiro's worker needs).
  Date: 2026-07-23

- Decision: Per-key failure semantics = mandated producer properties **plus** caller-side re-mapping in the reference bridge (options (b) + (a)'s re-map from the review). The API haddock mandates `enable.idempotence=true` and `acks=all` (idempotence forces acks=all and bounds `max.in.flight` at 5, preserving per-partition order across librdkafka's internal retries); the bridge re-maps any same-key `Right` that follows a same-key `Left` from the same call to a failure before reporting to keiro.
  Rationale: stop-on-first-failure per key is physically impossible after enqueue-all (delivery is out of the client's hands), so the transport cannot literally refuse to deliver a later same-key record. Keiro's contract tolerates the re-map: marking a delivered row failed only causes a redundant republish, which is safe under at-least-once with the idempotent inbox. Confirmed during authoring: keiro's worker *already* ignores reported outcomes for rows after the first failure in an ordered group (`groupMarks`, `keiro/src/Keiro/Outbox.hs:500-512` — the whole rest of the group goes to `skippedRows` regardless of reported outcome, and skipped rows are republished after the failed row). The bridge-side re-map is therefore contract honesty and defense-in-depth — the bridge's *reported* outcomes are truthful about ordering even if a future caller uses it outside `publishClaimedOutbox`.
  Date: 2026-07-23

- Decision: The reference bridge lives as a **compiled module inside keiro's existing `keiro-test` suite** (`keiro/test/Keiro/TestBridge/Kafka.hs`), with kafka-effectful and hw-kafka-client added to the `keiro-test` stanza only. Sibling plan 121 excerpts it into the guide. Alternatives rejected: a new tiny `keiro-kafka-bridge` package (release overhead disproportionate to ~60 lines of reference code; the master plan flags this decision for the ADR pass — record there that the package can be extracted later if a second consumer appears); a jitsurei example module (drags librdkafka into the example package's build for all jitsurei users); guide-only prose (the exact rot this initiative is fixing).
  Rationale: compiled-and-tested code cannot silently rot; keiro's dev shell already ships `pkgs.rdkafka` (`keiro/nix/haskell.nix:30`), so the native library costs nothing new; and `keiro-test` already depends on another own-family upstream (`shibuya-core`), so the precedent exists.
  Date: 2026-07-23

- Decision: kafka-effectful releases this as **0.4.0.0** with a CHANGELOG entry.
  Rationale: adding a constructor to the exported `KafkaProducer` GADT breaks every downstream custom interpreter's exhaustive match — a PVP major bump from 0.3.0.0. Both in-repo interpreters (plain and OpenTelemetry) must add the new case in the same change.
  Date: 2026-07-23

- Decision: Live-broker validation is a runnable example behind kafka-effectful's existing `examples` cabal flag, run manually against the repo's Redpanda harness — not an automated broker-gated test.
  Rationale: kafka-effectful's test suite is deliberately pure (OTel semantics only; no broker harness in CI), and the master plan scopes out broker-level integration infrastructure "beyond what the acked-publish work itself needs". The semantic contract is covered brokerlessly by the keiro fake-interpreter tests; the example proves the librdkafka mechanics end to end. If a live automated test is wanted later, record it in the ADR pass.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### ADRs

keiro's `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq job telemetry) — not relevant to this work; no relevant ADR exists. Neither kafka-effectful nor hw-kafka-client's checkout has a `docs/adr/` directory. The master plan marks the acked-publish contract and mandated producer properties as a candidate ADR at completion.

### How Kafka publishing actually works (hw-kafka-client ≥5.3, the layer under everything here)

librdkafka is the C Kafka client. Publishing is asynchronous: `produceMessage` "can return before messages are sent" — its own haddock says so (hw-kafka-client `src/Kafka/Producer.hs:132-139`) — because it only places the record in an in-memory outbound queue. Whether the *broker* accepted the record is reported later through a **delivery report**: when creating a producer, `newProducer` installs a global delivery callback (it does this unconditionally — `Producer.hs:117-119` adds `deliveryCallback (const mempty)` before user callbacks), and each record can additionally carry its own per-message callback as a `StablePtr` in the record's opaque field. When librdkafka fires the report, hw-kafka-client dereferences that per-message callback and **forks a thread** to run it (`src/Kafka/Producer/Callbacks.hs:32-56`; the fork is at the bottom of `deliveryCallback`). A `DeliveryReport` is one of `DeliverySuccess record offset`, `DeliveryFailure record err`, or `NoMessageError err`. Reports are bounded in time by librdkafka's `message.timeout.ms` (default 300000 ms = 5 minutes): past that, librdkafka fails the record locally and the report fires with an error. `flushProducer` (`Producer.hs:199-205`) loops polling events until the outbound queue is empty — after it returns, every enqueued record's report has fired. `closeProducer` = `flushProducer` (`Producer.hs:193-196`).

### What kafka-effectful ships today and why none of it satisfies keiro

`kafka-effectful` (version 0.3.0.0, on Hackage) wraps hw-kafka-client in an `effectful` effect. The producer effect is the GADT `KafkaProducer` in `src/Kafka/Effectful/Producer/Effect.hs` with operations `ProduceMessage`, `ProduceMessage'` (caller-supplied delivery callback), `ProduceMessageSync`, `ProduceMessageBatch`, `FlushProducer`, the transaction ops, and `AskProducerHandle`. The plain interpreter is `src/Kafka/Effectful/Producer/Interpreter.hs`; the OpenTelemetry interpreter (`src/Kafka/Effectful/OpenTelemetry/Producer/Interpreter.hs`) duplicates the dispatch with spans and must stay case-complete.

- `ProduceMessageBatch` (`Producer/Interpreter.hs:61-67`) maps `K.produceMessage` over the list and returns only **enqueue** failures; the delivery report is discarded. Broker-side failures — broker down past `message.timeout.ms`, auth failure, broker-side record-too-large — are invisible to the caller. Wire this to keiro's outbox and rows get marked `sent` for messages never on the topic. This is KFK-3's core.
- `ProduceMessageSync` (`Producer/Interpreter.hs:68-81`; OTel variant in the OTel interpreter file) is the sound-but-slow primitive: per-message MVar callback, then `flushProducer`, then `takeMVar` — one **full flush per record**, so `traverse produceMessageSync` serializes the pipeline and defeats the batching that keiro's July 2026 throughput work (MasterPlan 11) exists to provide. It also throws on the first failure, abandoning per-record results.
- Nothing mandates `acks=all` or idempotence for a publisher (only the *transaction* API haddock mentions them).

The master plan's Decision Log fixed the resolution: ship an acked batch publish API (enqueue all with per-message delivery callbacks, flush once, collect all reports — preserving librdkafka pipelining), rather than documenting a `traverse produceMessageSync` bridge.

### keiro's contract, quoted, and what the worker already does

`keiro/src/Keiro/Outbox.hs` (path relative to the keiro repo root; the file is in the `keiro` package's `src/`). The outcome type (lines 269-275): `PublishSucceeded` is documented as "Kafka acknowledged the publish."; `PublishFailed !Text` as "Publish failed; will be retried after the configured backoff." The worker `publishClaimedOutbox` (lines 303-364) claims rows, calls the caller-supplied `publish :: [OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]` with the batch in claim order, and marks rows. Its haddock's transport clause (lines 287-293): for ordered policies, "if a row fails then later rows in the same ordered group are skipped and returned to @failed@ without consuming an attempt; ... A real Kafka transport must not successfully deliver a later same-key record after reporting an earlier same-key failure from the same call." Fail-closed envelope: the worker wraps `publish` in `trySync` and converts a thrown exception into `PublishFailed` for every row in the call (lines 355-363) — build on this; do not duplicate it in the bridge. Missing outcomes become `PublishFailed "publisher returned no outcome"` (lines 394-397). And — verified during authoring — `groupMarks` (lines 500-512) walks each ordered group and, at the **first** failure, sends the *entire rest of the group* to `skippedRows` regardless of what the publisher reported for them; skipped rows are marked with `markOutboxSkippedTx "skipped: earlier record for the same key failed"` and republished later. So a delivered-then-remapped row costs only a redundant republish — exactly what at-least-once plus keiro's idempotent inbox absorbs.

The pure converter that already exists: `Keiro.Outbox.Kafka` (`keiro/src/Keiro/Outbox/Kafka.hs`) turns an `OutboxRow` into a transport-neutral `KafkaProducerRecord` (topic, optional UTF-8 key, payload bytes, canonical headers) and its haddock states keiro "deliberately does not import hw-kafka-client or kafka-effectful". The bridge in this plan is the missing last inch: `KafkaProducerRecord` → hw-kafka-client `ProducerRecord` → `produceMessageBatchAcked` → `PublishOutcome`s.

### Why per-key stop-on-failure cannot be literal, and what we do instead

keiro's clause forbids the transport from *successfully delivering* a later same-key record after reporting an earlier same-key failure from the same call. With enqueue-all + single-flush, delivery of later records is out of the client's hands by the time the earlier failure is known — no client-side design can un-deliver them. Two complementary mitigations make the contract hold in effect: (1) **mandated properties** — with `enable.idempotence=true`, librdkafka guarantees per-partition ordering across its own retries (idempotence implies `acks=all` and caps in-flight requests at 5), so within one call the broker log order matches enqueue order per partition, and a mid-key failure means the *broker rejected/timed-out that record*, not that later records jumped it silently; (2) **caller-side re-map** — the bridge reports any same-key success that follows a same-key failure from the same call as a failure, so keiro republishes both in order and the topic converges to the correct sequence. See the Decision Log for why the re-map is safe (redundant republish) and already mirrored worker-side.

### Toolchains, versions, baselines

- kafka-effectful: version 0.3.0.0 (`kafka-effectful.cabal:3`), GHC 9.12.4 via `nix develop`, tests with `cabal test kafka-effectful-test` (pure; no broker), examples behind the `examples` cabal flag, Redpanda + Jaeger via `just process-up`, topics via `just create-topics`. Follows the Haskell PVP (stated at the top of its CHANGELOG).
- keiro: `cabal test keiro-test` from the repo root inside `nix develop`; the suite is hspec, baseline **335 examples, 0 failures**. It needs local Postgres: `just postgres-start` (initializes and starts the dev-shell cluster; the shell hook sets `PGHOST`/`PGDATA`/`PG_CONNECTION_STRING`). Database-touching specs use the suite-level template-database fixture from `keiro-test-support` — follow the existing outbox specs' setup in `keiro/test/Main.hs`; do not add per-example migrations.
- hw-kafka-client: local checkout is master (exports `produceMessageBatch`, which Hackage 5.3.0 does not — the interpreter comment at `Producer/Interpreter.hs:62-65` records this); the plan relies only on API present in Hackage ≥5.3: `produceMessage'`, `flushProducer`, `DeliveryReport`, `Offset`.


## Plan of Work

### Milestone 1 — `produceMessageBatchAcked` in kafka-effectful

Scope: the effect, both interpreters, haddock with mandated properties, and a runnable example. At the end, a program inside `runKafkaProducer` can publish N records with one flush and receive N broker verdicts in input order, demonstrated live against Redpanda.

1. `src/Kafka/Effectful/Producer/Effect.hs` — add the constructor to the GADT:

   ```haskell
   ProduceMessageBatchAcked ::
       [ProducerRecord] ->
       KafkaProducer m [Either KafkaError Offset]
   ```

   and the smart constructor, exported from the module's Operations group (and re-exported wherever `produceMessageBatch` is re-exported — check `src/Kafka/Effectful/Producer.hs` and `src/Kafka/Effectful.hs` export lists):

   ```haskell
   {- | Send many records in one call and wait for the BROKER's verdict on
   every record. Returns one result per input record, in input order:
   @Right offset@ when the broker acknowledged the record (the assigned
   offset), @Left err@ when it was rejected, timed out, or could not be
   enqueued. Unlike 'produceMessageBatch', which reports only local
   enqueue failures and discards delivery reports, a @Right@ here means
   the record is on the topic.

   The call enqueues every record with a per-message delivery callback,
   flushes the producer ONCE, and collects all reports — librdkafka's
   internal batching and pipelining are preserved, so this is the
   throughput path for ack-verified publishing (transactional-outbox
   drains and the like). Latency is bounded by @message.timeout.ms@
   (librdkafka default: 300000 ms); a broker outage makes the call block
   up to that long before returning @Left@ per record.

   The producer MUST be configured with @enable.idempotence=true@ (which
   itself forces @acks=all@ and caps @max.in.flight@ at 5). Without
   idempotence, librdkafka's internal retries can reorder records within
   a partition, and a @Right@ does not imply every earlier same-partition
   record from this call landed before it. This requirement is a
   contract, not a runtime check.

   Per-key ordering on partial failure: this operation CANNOT stop
   delivering later same-key records after an earlier same-key failure —
   all records are already enqueued when the first report arrives.
   Callers whose downstream contract forbids a later same-key success
   after an earlier same-key failure (for example keiro's outbox worker)
   must re-map trailing same-key @Right@s to failures themselves; under
   an at-least-once regime the cost is a redundant republish.

   @since 0.4.0.0
   -}
   produceMessageBatchAcked ::
       (KafkaProducer :> es) =>
       [ProducerRecord] ->
       Eff es [Either KafkaError Offset]
   produceMessageBatchAcked = send . ProduceMessageBatchAcked
   ```

2. `src/Kafka/Effectful/Producer/Interpreter.hs` — implement the case in `handleProducer`, generalizing the `ProduceMessageSync` protocol (per-record MVar, `K.produceMessage'` with `Concurrent.putMVar var` as the callback) from one record to N with a single flush:

   ```haskell
   ProduceMessageBatchAcked records -> Effectful.liftIO $ do
       -- Phase 1: enqueue every record with its own delivery-report MVar.
       -- An enqueue (ImmediateError) failure yields an immediate Left slot;
       -- there is no report to wait for in that case.
       slots <-
           mapM
               ( \record -> do
                   var <- Concurrent.newEmptyMVar
                   res <- K.produceMessage' producer record (Concurrent.putMVar var)
                   pure $ case res of
                       Left (K.ImmediateError err) -> Left err
                       Right () -> Right var
               )
               records
       -- Phase 2: one flush for the whole batch; after it returns, every
       -- enqueued record's delivery report has fired (per-message callbacks
       -- are forked by hw-kafka-client; takeMVar below joins each).
       K.flushProducer producer
       -- Phase 3: collect verdicts in input order.
       mapM
           ( \case
               Left err -> pure (Left err)
               Right var -> do
                   report <- Concurrent.takeMVar var
                   pure $ case report of
                       K.DeliverySuccess _ offset -> Right offset
                       K.DeliveryFailure _ err -> Left err
                       K.NoMessageError err -> Left err
           )
           slots
   ```

   Note the deliberate differences from `ProduceMessageSync`: nothing is thrown through the `Error` effect — per-record results are the whole point — and the flush happens once, between enqueue-all and collect-all. Per-message callbacks work without any extra properties because `newProducer` always installs the global delivery callback that dispatches them (hw-kafka-client `Producer.hs:117-119`).
3. `src/Kafka/Effectful/OpenTelemetry/Producer/Interpreter.hs` — add the case to `handleTracedProducer`, following the file's `ProduceMessageBatch` precedent (one Producer-kind span per record, opened at enqueue time via `withProducerSpan`, so partition/key attributes stay per-record). Enqueue each record inside its span (recording an `ImmediateError` on the span), flush once outside any span, then collect; record each `Left` verdict on its record's span with `recordKafkaError` before ending it — which requires restructuring so spans stay open across the flush, or (simpler, and acceptable — record the choice in the Decision Log if taken) end the enqueue spans at enqueue time and add a `Left`-verdict span event on a wrapping batch span. Decide while implementing; the OTel shape is not part of the frozen API contract, only the operation's semantics are.
4. `examples/BatchAckedPublish.hs`, new stanza in `kafka-effectful.cabal` mirroring the existing example stanzas (buildable only with `-f examples`; name it `example-batch-acked-publish`). The example: build a producer with `brokersList ["localhost:9092"]` plus `extraProps` setting `enable.idempotence=true` and a short `message.timeout.ms` (10000) so the failure demo is quick; publish five records (mixed keys) to topic `kafka-effectful-sync-demo` via `produceMessageBatchAcked`; print each result as `i: Right (Offset o)` / `i: Left err`. Add a Justfile recipe `batch-acked-example` following the `otel-example` pattern.

Acceptance: `cabal build -f examples all` and `cabal test kafka-effectful-test` green (from the kafka-effectful root); against `just process-up` + `just create-topics` the example prints five `Right (Offset _)` lines; with Redpanda stopped it prints five `Left` lines after roughly `message.timeout.ms` — capture both transcripts into Surprises & Discoveries or Outcomes as evidence.

### Milestone 2 — version, CHANGELOG, release readiness

Scope: bump `kafka-effectful.cabal` `version:` to `0.4.0.0`; add the CHANGELOG section on top, following the house style:

```markdown
## 0.4.0.0 — 2026-07-XX

### Breaking Changes

- Add `ProduceMessageBatchAcked` to the `KafkaProducer` effect. Custom
  interpreters must add a case for the new constructor.

### New Features

- Add `produceMessageBatchAcked`: enqueue a batch with per-message
  delivery-report callbacks, flush once, and return the broker's verdict
  per record (`Either KafkaError Offset`) in input order. This is the
  ack-verified batch publish path; `produceMessageBatch` reports only
  local enqueue failures. Requires `enable.idempotence=true` (see
  haddock) for per-partition ordering guarantees.
```

Acceptance: `cabal build all`, `cabal test kafka-effectful-test`, and `cabal haddock kafka-effectful` all succeed from the kafka-effectful root; `cabal check` passes. Actual Hackage upload is the repo owner's call and not blocked on by milestone 3 (which uses a local source override until the release exists — see Concrete Steps). Commit with `feat!: add produceMessageBatchAcked (broker-acked batch publish)`.

### Milestone 3 — the reference bridge and contract tests in keiro

Scope: keiro's `keiro-test` suite gains the bridge module, a fake producer interpreter, and three contract tests. At the end, `cabal test keiro-test` proves keiro's outbox contract holds over the new API with zero brokers involved. No keiro *library* code changes.

1. Dependency wiring, `keiro/keiro.cabal` (keiro-repo-relative — the `keiro` package directory inside the repo), `test-suite keiro-test` stanza only: add `kafka-effectful ^>=0.4` and `hw-kafka-client >=5.3 && <6` to `build-depends`, and the new module to `other-modules` (add an `other-modules:` field listing `Keiro.TestBridge.Kafka` alongside the existing `ReplaySafetyTypeProbe` if it is listed; check the stanza — `hs-source-dirs: test`). The keiro dev shell already provides librdkafka (`nix/haskell.nix:30` ships `pkgs.rdkafka`), so no flake change is needed.
2. New module `keiro/test/Keiro/TestBridge/Kafka.hs` (keiro-repo-relative) — the reference bridge, written to be excerpt-ready for the guide (plan 121 copies from here; keep it self-contained and commented). Contents, in order:
   - `toProducerRecord :: KafkaProducerRecord -> Kafka.Producer.Types.ProducerRecord` — topic text to `TopicName`, `UnassignedPartition`, key bytes to `prKey`, payload to `prValue`, header pairs to `prHeaders` via `headersFromList`.
   - The per-key re-map. Group positions by their record's ordering identity — mirror `Keiro.Outbox`'s own grouping: rows whose event has a key group by `(event.source, key)`, keyless rows are singleton groups (see `outcomeGroups`, `keiro/src/Keiro/Outbox.hs:527-545`). Walk each group in input order; after the first `Left`, replace every following `Right` with `Left "suppressed: an earlier record with the same key failed broker acknowledgement in this batch"` (a `PublishFailed`-destined text, not a `KafkaError` — do the re-map after converting to outcomes, which is simpler: convert first, then re-map `PublishSucceeded` → `PublishFailed`).
   - The bridge itself:

     ```haskell
     -- | Reference implementation of keiro's outbox publish callback over
     -- kafka-effectful's broker-acked batch publish. Pass to
     -- 'publishClaimedOutbox'. The producer MUST be configured with
     -- enable.idempotence=true (implies acks=all, max.in.flight <= 5).
     publishOutboxBatchAcked ::
         (KafkaProducer :> es) =>
         [OutboxRow] ->
         Eff es [(OutboxId, PublishOutcome)]
     ```

     Implementation: `outboxRowToKafkaRecord` each row (from `Keiro.Outbox.Kafka`), convert, call `produceMessageBatchAcked`, zip verdicts back to rows in order (`Right _` → `PublishSucceeded`; `Left err` → `PublishFailed (textShow err)`), apply the per-key re-map, return `[(row.outboxId, outcome)]` in input order. Do not catch exceptions here — `publishClaimedOutbox` already wraps the callback in `trySync` and fails the whole call closed (`Outbox.hs:355-363`).
3. Fake interpreter, in the same module or a sibling test module: an `effectful` `interpret` of the `KafkaProducer` effect that services **only** `ProduceMessageBatchAcked` from a script and errors loudly on any other op (mirroring the mock style of shibuya-kafka-adapter's test suite). Script shape: `[ProducerRecord] -> [Either KafkaError Offset]` driven by an `IORef` of queued verdict lists, so each test enqueues the verdicts it wants the "broker" to return. This is the seam that makes broker-failure simulation trivial and deterministic.
4. Three hspec specs in `keiro/test/Main.hs` (keiro-repo-relative), in a new `describe "outbox kafka bridge (reference)"` block, using the existing template-database fixture exactly as the neighboring outbox specs do:
   - **Broker-ack failure marks rows failed, never sent.** Enqueue two outbox rows with *different* keys; script verdicts `[Right 0, Left KafkaError...]`; run `publishClaimedOutbox publishOutboxBatchAcked ...` under the fake; assert the summary (`published = 1`, `retried = 1`, `dead = 0`) and, by direct query or by a second worker pass, that row 2 is retryable/failed and row 1 is sent. This is the KFK-3 regression: under `produceMessageBatch` semantics row 2 would have been marked sent.
   - **Mid-batch same-key failure re-maps trailing same-key acks.** Three rows, same key `k`: verdicts `[Right 0, Left err, Right 2]`. Assert unit-level (call `publishOutboxBatchAcked` directly under the fake) that the returned outcomes are `[PublishSucceeded, PublishFailed _, PublishFailed suppressed]` — the third re-mapped despite its `Right`. Then assert end-to-end that no row after the failure is marked sent (keiro's worker would skip it anyway via `groupMarks`; the unit assertion is what pins the *bridge's* honesty).
   - **Order preservation.** Five rows across two keys interleaved; all verdicts `Right`; assert the returned association list is in exactly the input (claim) order with all `PublishSucceeded`, and that a scripted failure in key A does not re-map key B's later successes.
5. Run the whole suite; the baseline 335 examples must still pass, plus the new ones.

Acceptance: from `/Users/shinzui/Keikaku/bokuno/keiro`, `cabal test keiro-test` prints `338 examples, 0 failures` (or 335+n for n specs actually added; record the real number in Progress). The bridge module compiles against the *real* kafka-effectful 0.4.0.0 types — which is the anti-rot property the location decision buys.


## Concrete Steps

kafka-effectful work (milestones 1–2):

```bash
cd /Users/shinzui/Keikaku/bokuno/kafka-effectful
nix develop
cabal build all
cabal test kafka-effectful-test
cabal build -f examples all
```

Live example run — terminal 2:

```bash
cd /Users/shinzui/Keikaku/bokuno/kafka-effectful
nix develop
just process-up
```

terminal 1 (topic exists via `just create-topics`):

```bash
cd /Users/shinzui/Keikaku/bokuno/kafka-effectful
just create-topics
cabal run example-batch-acked-publish -f examples -- --bootstrap-servers localhost:9092 --topic kafka-effectful-sync-demo
```

Expected success transcript shape:

```text
0: Right (Offset 12)
1: Right (Offset 13)
2: Right (Offset 14)
3: Right (Offset 15)
4: Right (Offset 16)
```

Then `just process-down` and rerun the example; expected after ~10 s (the example's `message.timeout.ms`): five `Left (KafkaResponseError RdKafkaRespErrMsgTimedOut)` lines (exact constructor may differ by librdkafka version — record the observed one in Surprises & Discoveries).

keiro work (milestone 3). Until kafka-effectful 0.4.0.0 is on Hackage, point keiro at the sibling checkout with an uncommitted local override:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
printf 'packages:\n  /Users/shinzui/Keikaku/bokuno/kafka-effectful\n' > cabal.project.local
```

(`cabal.project.local` is git-ignored by convention — verify with `git status`; never commit it. Once 0.4.0.0 is published, delete the file and the Hackage bound in the test stanza takes over.) Then:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop
just postgres-start
cabal build keiro-test
cabal test keiro-test
```

Expected tail:

```text
Finished in XX.XX seconds
338 examples, 0 failures
```

Baseline check before starting milestone 3 (should print `335 examples, 0 failures`): run `cabal test keiro-test` once before touching anything and record the output in Progress.

Commits: kafka-effectful repo — `feat!: add produceMessageBatchAcked (broker-acked batch publish)` then `chore(release): 0.4.0.0`; keiro repo — `test(outbox): reference Kafka bridge over produceMessageBatchAcked with per-key re-map` plus `docs(plans): ...` updates to this plan and the master plan.


## Validation and Acceptance

- The API is effective beyond compilation: the live example shows broker offsets on success and per-record errors on broker outage — the exact observability `produceMessageBatch` lacks (it would print nothing and return `[]` in both scenarios, since enqueue succeeds either way).
- The contract holds: the keiro spec "broker-ack failure marks rows failed, never sent" fails if the bridge is (mis)implemented over `produceMessageBatch` — a worthwhile temporary sanity check during development: swap the bridge's call to `produceMessageBatch` and watch the spec fail with row 2 marked sent, then swap back.
- The per-key clause holds in effect: the mid-batch same-key spec pins the re-map; the order spec pins input-order and cross-key isolation.
- Nothing regresses: kafka-effectful's existing suite (OTel semantics) and keiro's 335-example baseline stay green; `runKafkaProducer`'s close-on-scope-exit (which flushes, hw-kafka-client `Producer.hs:193-196`) and the worker's `trySync` fail-closed envelope are exercised, not reimplemented.


## Idempotence and Recovery

Everything here is additive: a new effect constructor, a new example, a new test module, new specs. Re-running any build or test command is safe. The `cabal.project.local` override is the only stateful development artifact; deleting it returns keiro to Hackage-resolved dependencies (and, before 0.4.0.0 exists on Hackage, makes `keiro-test` fail to resolve — that is the expected signal to either restore the override or release). If milestone 3 must land before the Hackage release, keep the override local and mark the Progress entry "blocked on 0.4.0.0 publish"; do not commit a `source-repository-package` pin to keiro's `cabal.project` without recording that decision here first. If the OTel interpreter case proves awkward (spans across the flush), the recovery path is the simpler enqueue-time-span shape described in milestone 1 step 3 — record the choice in the Decision Log; do not leave the OTel interpreter non-exhaustive (it will not compile, which is the guard).


## Interfaces and Dependencies

Frozen by this plan (siblings quote them from the Decision Log):

- `Kafka.Effectful.Producer.Effect.produceMessageBatchAcked :: (KafkaProducer :> es) => [ProducerRecord] -> Eff es [Either KafkaError Offset]` — results in input order; `Right` = broker-acknowledged with assigned offset; one flush per call; mandated properties `enable.idempotence=true` (implying `acks=all`, `max.in.flight <= 5`); latency bound `message.timeout.ms`.
- `Keiro.TestBridge.Kafka.publishOutboxBatchAcked :: (KafkaProducer :> es) => [OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]` — the reference bridge for `publishClaimedOutbox`, with per-key (grouped by `(event.source, event.key)`; keyless rows ungrouped) failure re-mapping.

Modules and libraries used and why: `kafka-effectful` 0.4.0.0 (the effect + interpreters; the subject of milestones 1–2); `hw-kafka-client` ≥5.3 (`Kafka.Producer.Types.ProducerRecord`, `DeliveryReport`, `Kafka.Types.KafkaError`, `Offset` — the vocabulary types the bridge converts into; also `headersFromList`); `effectful`/`effectful-core` (already keiro deps; `interpret` powers the fake); keiro's own `Keiro.Outbox` (`publishClaimedOutbox`, `PublishOutcome`, `OutboxRow`, `OutboxId`) and `Keiro.Outbox.Kafka` (`KafkaProducerRecord`, `outboxRowToKafkaRecord`) — unchanged, consumed as-is; `keiro-test-support` (template-database fixture for the DB-backed specs — suite-level fixture, not per-example migration). keiro's runtime library gains **no** new dependency; the `keiro-test` stanza gains exactly two.
