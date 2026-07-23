---
id: 23
slug: make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically
title: "Make the Kafka consumer streaming stack surface fatal errors and close deterministically"
kind: master-plan
created_at: 2026-07-23T04:18:29Z
---

# Make the Kafka consumer streaming stack surface fatal errors and close deterministically

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The consumer half of the Kafka stack — hw-kafka-streamly (`/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly`) and kafka-effectful's consumer side (`/Users/shinzui/Keikaku/bokuno/kafka-effectful`), over hw-kafka-client 5.3 — had never been reviewed (MasterPlan 18 covered the producer and the shibuya adapter). The July 2026 consumer-stack review, with adversarial verification against hw-kafka-client, hs-opentelemetry, streamly-core, and librdkafka sources, found the stack's defining weakness is fatal-error blindness. Verified against librdkafka's own delivery mechanics: in hw-kafka-client's default Async callback mode, consumer fatal errors (e.g. a fenced static group member) are delivered only on the consumer queue, which the binding's background loop drains with `void` — so **no layer of this stack can observe a consumer fatal at all**: not `error_cb` (the op short-circuits to return-as-message before the error branch), not the app (it reads the forwarded queue), and not librdkafka's own `max.poll.interval.ms` watchdog, which the loop resets every 100ms regardless of application progress; every voided rkmessage is also leaked (KSC-3, upstream, confirmed-and-stronger). In Sync mode the fatal does arrive in-band — and hw-kafka-streamly's `isFatal` misclassifies it as non-fatal via the catch-all, so the recommended `skipNonFatal` silently drops the one signal that the consumer is dead (KSC-2). Additional confirmed findings: `pollMessage` throws on routine in-band conditions (auto-offset-reset after retention loss, partition EOF), producing crash-loops where the batch variant and hw-kafka-streamly correctly stay in-band — contradictory taxonomies in one interpreter (KSC-4); `commitAllOffsets` throws on the benign `NoOffset` idle condition that hw-kafka-client documents as not-an-error — the shibuya adapter hand-works around it, other consumers (shikigami) do not (KSC-5); the traced interpreter leaks extracted trace context into the thread-local so headerless records chain onto the previous record's remote trace, and its "process" span is a zero-duration point closed before processing (KSC-6); and `kafkaStream`'s close is deferred to GC whenever the stream is partially consumed or abandoned — the module's own worked example (`Stream.take 5`) is exactly that case — leaving a zombie consumer that keeps heartbeating, retains partitions, and resets the poll watchdog, starving its partitions until some GC runs (KSC-7, confirmed; the rd_kafka GC finalizer cannot fire while the poll loop holds the handle). One claim was refuted and downgraded: non-UTF-8 headers do not crash the traced consumer — hs-opentelemetry's `extract` catches everything — but they do silently drop inbound trace context and spam warnings (KSC-1 residual). kafka-effectful has zero consumer-interpreter test coverage.

After this initiative: a fenced or otherwise fatally-dead consumer is loudly observable in both poll modes across the whole stack; routine broker events (retention resets, EOF, idle commits) never kill a healthy consumer; the traced interpreter neither leaks context across records nor mis-parents headerless messages; consumer close is deterministic under partial consumption; and the consumer interpreters gain their first tests. In scope: KSC-2 through KSC-7 plus the KSC-1 residual, across hw-kafka-streamly, kafka-effectful, and an upstream hw-kafka-client contribution (fork-pin until merged, following the repo's established fork-pin precedent); the rkmessage leak fix rides the same upstream change. Out of scope: MasterPlan 18's producer/adapter findings; redesigning poll modes; shikigami's call sites beyond verifying they inherit the fixes.


## Decomposition Strategy

Three child plans. EP-1 (plan 135) owns fatal observability — the one-hole-two-halves fix: upstream, stop voiding consumer-queue messages in hw-kafka-client's Async loop (surface at minimum `ERR__FATAL` into the forwarded queue or a side channel, destroy what is dropped, and stop unconditional watchdog resets — an upstream patch + fork pin); in hw-kafka-streamly, add the missing `isFatal` arms (`RdKafkaRespErrFatal`, SASL auth) so Sync mode terminates loudly. EP-2 (plan 136) owns interpreter taxonomy and tracing hygiene: classify in-band poll errors (port the corrected `isFatal`), treat `NoOffset` as success in both interpreters' commit ops, save/attach/detach context correctly (new-root for headerless records), switch header decoding to total functions, and stand up the consumer-interpreter test suite. EP-3 (plan 137) owns deterministic lifecycle: a `withKafkaConsumerStream` bracket (or streamly `withAcquireIO`) guaranteeing close on abandonment, fixing the worked example, and documenting the GC-deferral hazard on the legacy entry points.

Alternatives considered. Splitting the upstream hw-kafka-client work into its own plan was rejected: EP-1's streamly-side fix is only meaningful with the upstream half, and the fork-pin makes them one deliverable. Fixing KSC-5 keiro-ecosystem-wide by documenting the adapter workaround was rejected: the library must return what its dependency documents as success.

ADR context: no relevant ADR in keiro's `docs/adr/`. Candidate ADR: the consumer fatal-observability contract across the stack (which layer surfaces what, in which poll mode).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Surface librdkafka fatal errors through the consumer stack | docs/plans/135-surface-librdkafka-fatal-errors-through-the-consumer-stack.md | None | None | Not Started |
| 2 | Classify poll and commit errors and fix traced-context hygiene | docs/plans/136-classify-poll-and-commit-errors-and-fix-traced-context-hygiene.md | None | EP-1 | Not Started |
| 3 | Guarantee deterministic consumer close in hw-kafka-streamly | docs/plans/137-guarantee-deterministic-consumer-close-in-hw-kafka-streamly.md | None | None | Not Started |


## Dependency Graph

EP-2 is soft-dependent on EP-1: its poll-error classification should port the *corrected* `isFatal` table (with the new fatal arms) rather than the current one; it can proceed against the current table and re-sync when EP-1 lands. EP-1 and EP-3 are independent (different mechanisms, same repo for the streamly half — coordinate the hw-kafka-streamly release). The hw-kafka-client fork pin introduced by EP-1 must be consumed by every repo building the stack (hw-kafka-streamly, kafka-effectful, shibuya-kafka-adapter) — EP-1 records the pin recipe; consumers adopt it when they next build.


## Integration Points

hw-kafka-client fork (EP-1): the pin (cabal.project source-repository-package) must be applied consistently; EP-1 documents the exact commit and the upstream PR link; EP-2's tests may rely on the surfaced-fatal behavior only behind the pin.

`hw-kafka-streamly/src/Kafka/Streamly/Stream.hs`: EP-1 (isFatal arms) and EP-3 (bracket API + example) — disjoint sections, one release; EP-1's `StreamTest.hs` taxonomy-pin update must incorporate the new arms EP-3 does not touch.

`kafka-effectful` consumer interpreters: EP-2 owns both (plain + traced) plus the new test suite; nothing else touches them.

Cross-plan decision for ADR promotion: the fatal-observability contract and the poll-mode guidance (when Sync is required until the upstream fix merges).


## Progress

- [ ] EP-1: hw-kafka-client fork surfaces consumer-queue fatals (and destroys dropped messages, stops unconditional watchdog resets); upstream PR filed; pin recipe documented.
- [ ] EP-1: `isFatal` gains `RdKafkaRespErrFatal` + SASL arms; taxonomy test updated; fenced-consumer path terminates loudly in Sync mode.
- [ ] EP-2: Poll errors classified (EOF/auto-offset-reset in-band or swallowed; fatals thrown); `NoOffset` commits succeed; context save/attach/detach correct with new-root for headerless; total header decoding; first consumer-interpreter tests pass.
- [ ] EP-3: Deterministic-close bracket shipped; worked example fixed; GC-deferral documented on legacy entry points; zombie-consumer regression test.


## Surprises & Discoveries

- Verification (2026-07-23): KSC-1 refuted — hs-opentelemetry's `extract` catches `SomeException` (three independent layers), so non-UTF-8 headers cost trace context and log noise, not a crash-loop; downgraded to a residual fixed in EP-2.
- Verification (2026-07-23): KSC-3 hardened — `error_cb` cannot see consumer fatals (return-as-message short-circuits before the error branch), hw-kafka-client has no `rd_kafka_fatal_error` binding, and the Async loop leaks every message it voids; "no layer observes by default" became "no layer can observe".
- Verification (2026-07-23): KSC-2's symptom is Sync-mode-only; in the default Async mode the fatal never reaches the stream — the two findings are one hole with two halves, fixed across EP-1's two components.
- Plan authoring (2026-07-23), affects EP-2: KSC-4's auto-offset-reset trigger is narrower than stated — librdkafka emits `ERR__AUTO_OFFSET_RESET` as a consumer error only under `auto.offset.reset=error` or a failed reset; a successful retention-loss reset only logs. The classification fix is unchanged; docs/plans/136 states the accurate trigger.
- Plan authoring (2026-07-23), affects EP-1: the `rd_kafka_queue_poll` alternative for avoiding watchdog resets is refuted — any poll of a consumer-flagged queue resets `max.poll.interval.ms` (librdkafka `rdkafka_queue.c:134-138`); docs/plans/135 documents the watchdog defect in the primary route and records the main-queue/forward route (needing a new binding) as PR follow-up.


## Decision Log

- Decision: Fix fatal observability upstream in hw-kafka-client (fork-pin + PR) rather than working around it with an application-level no-progress watchdog.
  Rationale: The verification proved no downstream workaround can observe the signal; a watchdog would fire on legitimately idle topics or require progress heuristics. The repo has established fork-pin precedent (hasql-migration).
  Date: 2026-07-23

- Decision: KSC-6's span-timing observation (zero-duration process span) is fixed as part of EP-2's context hygiene, but reshaping the span to cover user processing is out of scope.
  Rationale: Covering processing requires an API change (handler-wrapping) that belongs to a telemetry initiative, not a correctness fix; the ADR-0001-style contract for this stack can note it.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)
