---
id: 18
slug: make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review
title: "Make the Kafka transport edge production-safe surfaced by the 2026-07 transport review"
kind: master-plan
created_at: 2026-07-23T03:02:16Z
---

# Make the Kafka transport edge production-safe surfaced by the 2026-07 transport review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Every prior review of keiro's integration-event path stopped at keiro's own tables: the June 2026 audit and the July 2026 throughput overhaul (MasterPlans 9 and 11) reviewed `Keiro/Outbox.hs` and `Keiro/Inbox.hs`, but the transport edge — shibuya-kafka-adapter's consumer, kafka-effectful's producer, and the recipe by which a deployment wires keiro's batch-publish contract to a real librdkafka producer — was explicitly excluded every time ("Kafka internals beyond documentation caveats"), trusted on the strength of its own upstream tests. The July 2026 transport review deep-read those two repositories against keiro's contracts and hw-kafka-client's actual semantics, with an adversarial verification pass on the two consumer findings. This matters acutely for the planned 10-15 microservice adoption: these services will talk to each other over exactly this edge.

The review found the consumer's retry path unsound in two verified ways. First (KFK-2, fires on every retry with buffered successors — no race needed): after a handler failure sets the per-partition seek barrier, up to `inboxSize` (default 100) already-buffered same-partition records still execute their handlers before the failed record is redelivered; only their offset-store is suppressed. With keiro's idempotent inbox as the handler, the in-order redeliveries dedupe to `InboxDuplicate` without re-running effects, so the inversion is committed permanently — breaking the per-partition ordering that Kafka promises and keiro's inbox consumers implicitly rely on. Second (KFK-1, critical): a stale successor's own retry overwrites the barrier with a plain `Map.insert` and seeks forward past the still-unprocessed failed offset; under consecutive fast failures (exactly what a downstream outage produces, since a thrown handler is substituted with `AckRetry (RetryDelay 0)`) the failed record's loss latches — librdkafka's offset store has no gap tracking, so the next successful store commits past it forever. On the producer side (KFK-3): no shipped API can implement keiro's batch publish contract safely — the only batch operation reports librdkafka enqueue results, not broker acks, so the obvious wiring marks outbox rows `sent` for messages the broker never acknowledged; the one sound primitive (`produceMessageSync`) is per-record with a full flush per call, defeating MasterPlan 11's batching purpose; and no code anywhere connects keiro to librdkafka (the "bridge" exists only as guide prose). Two adoption traps round it out: the guide still documents the header-drop defect as current although shibuya-kafka-adapter 0.7.0.0 fixed it (KFK-4; the review initially attributed the fix to 0.8 — plan authoring corrected it against the adapter's CHANGELOG), and the adapter's entire at-least-once story silently depends on callers remembering `noAutoOffsetStore` in consumer properties with no wiring-time check (KFK-5).

After this initiative is complete: a failed record blocks its partition's successors from executing until it is redelivered (order preserved), and no interleaving of retries can skip a failed offset; a deployment publishes the outbox through a shipped, broker-ack-verified batch API with a reference bridge and mandated producer properties, so a broker outage can never mark unpublished rows `sent`; misconfigured consumer properties fail fast at wiring time instead of losing messages on the first crash; and the guide and `production-status.md` describe what actually ships.

In scope: the five findings (KFK-1 through KFK-5), fixes in shibuya-kafka-adapter and kafka-effectful (cross-repo, following MasterPlan 9's precedent), a reference outbox bridge and its test, and the documentation corrections. Out of scope: exactly-once across Postgres+Kafka (at-least-once plus idempotent inbox remains the design); the accepted outbox claim-epoch race; broker-level integration tests requiring librdkafka in `flake.nix` beyond what the acked-publish work itself needs (the plan decides how far to go); and changes to keiro's outbox/inbox internals (verified by two prior reviews).


## Decomposition Strategy

Three child plans, split by repository and by the direction of data flow.

EP-1 (plan 119) owns the consumer: the seek-barrier overwrite (KFK-1) and the stale-successor handler execution (KFK-2), fixed together in shibuya-kafka-adapter because the verification pass showed one mechanism closes both — consulting the barrier at processing time (finalize stale records without running the handler) plus a monotone barrier (`Map.insertWith min` and seek only to the minimum). Includes the double-retry and buffered-successor tests the adapter suite lacks.

EP-2 (plan 120) owns the producer: an acked batch publish API in kafka-effectful (enqueue all with per-message delivery callbacks, flush once, collect all reports — preserving librdkafka pipelining), per-key failure semantics compatible with `Keiro.Outbox`'s contract ("must not deliver a later same-key record after reporting an earlier same-key failure"), mandated producer properties (`acks=all`, idempotence), and a reference bridge showing keiro's `publishClaimedOutbox` wired to it, with a test against a real or simulated delivery-report path.

EP-3 (plan 121) owns adoption guardrails: wiring-time enforcement of the consumer offset-store configuration (KFK-5) in shibuya-kafka-adapter, and the documentation corrections in keiro (KFK-4: the stale header-drop claim, the overstated `production-status.md` transport claims, and the guide's bridge recipe updated to the EP-1/EP-2 reality).

Alternatives considered. Merging EP-1 and EP-3's adapter change into one plan was rejected: EP-1 changes retry semantics on the hot path and needs concurrency tests, while EP-3's config enforcement is an API-surface change; separating keeps EP-1 reviewable. Making the reference bridge its own plan was rejected: the bridge is the acceptance test of EP-2's API — without it the API cannot be validated against keiro's contract.

ADR context: `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md`, not relevant to the Kafka edge — no relevant ADR exists. Candidate ADRs at completion: the acked-publish contract and mandated producer properties (EP-2), and the consumer ordering guarantee the fixed adapter provides (EP-1).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Fix the seek-barrier ordering and stale-successor execution in shibuya-kafka-adapter | docs/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter.md | None | None | Not Started |
| 2 | Add an acked batch publish API to kafka-effectful and a reference outbox bridge | docs/plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge.md | None | None | Not Started |
| 3 | Enforce consumer offset-store configuration and correct the Kafka transport docs | docs/plans/121-enforce-consumer-offset-store-configuration-and-correct-the-kafka-transport-docs.md | None | EP-1, EP-2 | Not Started |


## Dependency Graph

EP-1 and EP-2 are independent (different repositories, different data directions) and can proceed in parallel.

EP-3 is soft-dependent on both: its documentation must describe the fixed consumer semantics (EP-1) and the shipped publish bridge (EP-2). Its adapter config-enforcement work is independent and can start immediately; only the docs milestone should wait for the other two plans' outcomes to be settled (their Decision Logs fix the semantics even before implementation completes).


## Integration Points

shibuya-kafka-adapter (repository `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`): EP-1 changes `Shibuya/Adapter/Kafka/Internal.hs` (barrier semantics); EP-3 changes the adapter's public wiring surface (`Shibuya/Adapter/Kafka.hs` / `Config.hs`) to enforce consumer properties. Same repo, one release: EP-1 defines the version bump; EP-3 rides it or cuts the next. Both must state the resulting version bound for keiro's docs (keiro does not depend on the adapter as a library — the bound appears in the guide's recipe).

kafka-effectful (repository `/Users/shinzui/Keikaku/bokuno/kafka-effectful`): EP-2 owns all changes (producer effect + interpreter). EP-3's guide references its new API by name; the name and signature are fixed in EP-2's plan and must be quoted identically in EP-3.

`keiro/docs/guides/integration-events-with-kafka.md` and `keiro/docs/user/production-status.md`: EP-3 owns both files entirely; EP-1 and EP-2 must not edit them (they record their externally visible semantics in their own Decision Logs for EP-3 to consume).

Cross-plan decision for ADR promotion: where the reference bridge lives (in-repo example module vs guide-only code) and whether keiro gains an optional `keiro-kafka-bridge` package is decided in EP-2 and recorded for the ADR pass.


## Progress

- [ ] EP-1: Monotone barrier (`insertWith min`, seek-to-minimum) implemented; double-retry overwrite test passes.
- [ ] EP-1: Lock-step finalize-gated emission (buffered successors never reach the handler past a barrier); buffered-successor ordering test passes.
- [ ] EP-2: Acked batch publish API (enqueue all, single flush, collect delivery reports) shipped in kafka-effectful with per-key failure semantics.
- [ ] EP-2: Reference outbox bridge validates keiro's batch publish contract against the new API; broker-ack failure marks rows failed, never sent.
- [ ] EP-3: Consumer offset-store configuration enforced at wiring time; misconfiguration fails fast with a clear error.
- [ ] EP-3: Guide and production-status corrected (header fix acknowledged, bridge recipe updated, transport claims made truthful).


## Surprises & Discoveries

- Plan authoring (2026-07-23), affects EP-1: the imagined "pre-handler barrier check in the adapter's handler wrapper" is not implementable — the handler type carries no seam and `processOne` calls it directly in shibuya-core, which is out of scope. EP-1 (docs/plans/119) achieves the same processing-time guarantee with lock-step emission: a finalize-gated source releases the next record to the processor only after the previous record's finalize, so a barrier set by a retry is always consulted before any buffered successor is emitted. The Decision Log entry below is amended accordingly.
- Plan authoring (2026-07-23), affects EP-2: keiro's outbox worker already re-maps trailing same-key rows to skipped after the first failure in a claimed group (`Outbox.hs:500-512`), so the reference bridge's per-key re-map is defense-in-depth for direct API consumers, not the sole enforcement of the contract.
- Plan authoring (2026-07-23), affects EP-3: hw-kafka-client exposes no config readback from a live consumer handle, so KFK-5 enforcement must intercept `ConsumerProperties` before construction (right-biased semigroup); a startup assertion against the live consumer is impossible.
- Plan authoring (2026-07-23): the header pass-through fix landed in shibuya-kafka-adapter 0.7.0.0 (commit `424a4c2`), not 0.8 as the review stated; Vision & Scope corrected.


## Decision Log

- Decision: Fix both consumer findings with one mechanism — a monotone barrier plus lock-step (finalize-gated) emission into the processor — rather than patching the overwrite alone.
  Rationale: The verification pass showed the overwrite fix alone leaves KFK-2's order inversion (which needs no race) fully intact; gating emission on finalize guarantees the barrier is consulted before any buffered successor reaches the handler. (Originally phrased as a "processing-time barrier check"; amended at plan authoring when the adapter's handler type proved to carry no seam for it — see Surprises & Discoveries.)
  Date: 2026-07-23

- Decision: Cross-repo fixes (shibuya-kafka-adapter, kafka-effectful) are in scope of this keiro master plan.
  Rationale: MasterPlan 9 precedent (upstream fixes belong to the initiative that needs them); the defects block keiro's production adoption specifically.
  Date: 2026-07-23

- Decision: Ship an acked batch publish API rather than documenting `traverse produceMessageSync` as the bridge.
  Rationale: Per-record sync publish defeats MasterPlan 11's batching purpose (full queue flush per record), and a naive traverse violates keiro's per-key ordering contract on partial failure; the review confirmed no shipped API can satisfy the contract today.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


---

Revision note (2026-07-23): corrected the header-fix version from 0.8 to 0.7.0.0 (verified against the adapter CHANGELOG during child-plan authoring) and amended the consumer-fix mechanism from "processing-time barrier check" to lock-step finalize-gated emission after the adapter's handler type proved to carry no pre-handler seam. Both changes are reflected in Vision & Scope, the Decision Log, Progress, and Surprises & Discoveries.
