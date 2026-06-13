---
id: 74
slug: expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient
title: "Expose keiro-pgmq tuning surface and make job workers resilient"
kind: exec-plan
created_at: 2026-06-11T04:45:56Z
master_plan: "docs/masterplans/9-keiro-production-readiness-hardening.md"
---

# Expose keiro-pgmq tuning surface and make job workers resilient

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-pgmq` is this repository's typed background-job package: an application declares a `Job` value (a queue, a payload codec, a retry policy), writes a plain handler of type `p -> Eff es JobOutcome`, and the package runs it against PGMQ (a PostgreSQL-native message queue) through shibuya (a Broadway-style worker framework). The June 2026 production-readiness audit found that the happy path works but several defaults and gaps make the package unsafe for real workloads: the visibility timeout is hard-coded to 30 seconds and unreachable, so any job slower than 30 seconds is processed twice and eventually dead-lettered while still healthy; handlers have no way to extend their message lease for long work; `runJobOnce` — documented as a one-shot drain — actually hangs forever when the queue holds fewer messages than requested; a retry policy of `maxRetries = 0` silently dead-letters every message before the handler ever runs; payloads written by a newer deploy are permanently dead-lettered instead of retried; queue names longer than 43 characters silently collide onto the same physical queue; and there is no way to inspect or redrive the dead-letter queue.

After this plan is implemented, an operator can declare per-queue visibility timeout, batch size, and polling cadence; a handler can extend its lease mid-flight and read its delivery attempt; `runJobOnce n` returns promptly after draining at most `n` messages (never hanging, never double-reading within one call); misconfigured retry policies and tunings fail loudly at construction time via `Either`-returning smart constructors; payloads from a newer schema version are retried rather than dead-lettered (making rolling deploys safe); distinct logical queue names can never collide physically; and the dead-letter queue can be listed, decoded with the job's own codec, redriven back onto the main queue, or purged. Every one of those behaviors is proven by a test in the `keiro-pgmq-test` suite, which this plan also moves onto the isolated per-example databases provided by `keiro-test-support`. You can see all of it working by running, from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-pgmq-test
```

One behavior is explicitly out of this plan's hands: a transient database error during polling currently kills a `runJobWorkers` worker permanently and silently. The root causes live upstream (shibuya's unobserved ingester async and pgmq-effectful's lack of transient-error retry) and are owned by `docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md`. This plan documents the honest contract now and carries a pre-written acceptance test that stays `pending` until that plan lands (see Milestone 8).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

Milestone 1 — test harness on keiro-test-support:

- [x] Make `runSqlOn` in `keiro-test-support/src/Keiro/Test/Postgres.hs` exception-safe with `bracket`. Completed 2026-06-13T13:51:14Z.
- [x] Replace the partial `error` in `parseConnString` with an `IO`-based failure carrying the connection string and parser error. Completed 2026-06-13T13:51:14Z.
- [x] Add `withMigratedSuiteWith :: (Text -> IO ()) -> (Fixture -> IO a) -> IO a` (extra template-migration hook) and re-express `withMigratedSuite` through it. Completed 2026-06-13T13:51:14Z.
- [x] Export `withFreshDatabase` from `Keiro.Test.Postgres`. Completed 2026-06-13T13:51:14Z.
- [x] Add `keiro-test-support` to the `keiro-pgmq-test` build-depends and restructure `keiro-pgmq/test/Main.hs` onto `withMigratedSuiteWith` + `around (withFreshDatabase fixture)` (pgmq schema applied to the template via the hook). Completed 2026-06-13T13:51:14Z.
- [x] All five existing examples pass on isolated databases; `cabal test keiro-test` still passes. Completed 2026-06-13T13:51:14Z; evidence: `cabal build keiro-pgmq keiro-test-support`, `cabal test keiro-pgmq-test` (`5 examples, 0 failures`), and `cabal test keiro-test` (`158 examples, 0 failures`) all passed.

Milestone 2 — structured decode errors and version-ahead retry:

- [x] Introduce `JobDecodeError` in `keiro-pgmq/src/Keiro/PGMQ/Codec.hs`; change `JobCodec.decodeJob` to `Value -> Either JobDecodeError p`. Completed 2026-06-13T13:55:21Z.
- [x] Add `mkJobCodec :: (p -> Value) -> (Value -> Either Text p) -> JobCodec p` helper; rebase `aesonJobCodec` on it. Completed 2026-06-13T13:55:21Z.
- [x] Detect `version > schemaVersion` in `keiroJobCodec` and surface `JobPayloadFromFuture`. Completed 2026-06-13T13:55:21Z.
- [x] Map `JobPayloadFromFuture` to `AckRetry` (policy's `defaultRetryDelay`) and `JobPayloadMalformed` to `AckDeadLetter (InvalidPayload …)` in `wrapHandler`. Completed 2026-06-13T13:55:21Z.
- [x] Fix the one keiro-dsl compile site (`keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs`) to use `mkJobCodec`. Completed 2026-06-13T13:55:21Z.
- [x] Document worker-before-producer deploy ordering and the aesonJobCodec→keiroJobCodec switch hazard in the `Keiro.PGMQ.Codec` haddock. Completed 2026-06-13T13:55:21Z.
- [x] Codec tests: envelope roundtrip, upcaster-chain decode, version-ahead, malformed envelope. Completed 2026-06-13T13:55:21Z; evidence: `cabal test keiro-pgmq-test` reported `9 examples, 0 failures`; `cabal build all` and `cabal test keiro-test` also passed.

Milestone 3 — validated configuration surface:

- [ ] Add `JobTuning` (+ `JobPolling`), `defaultJobTuning`, and `mkJobTuning :: … -> Either JobTuningConfigError JobTuning` to `keiro-pgmq/src/Keiro/PGMQ/Job.hs`.
- [ ] Add `mkRetryPolicy :: … -> Either RetryPolicyConfigError RetryPolicy` (`maxRetries >= 1`, delay `>= 0`); document the raw constructor as unvalidated, including the `maxRetries <= 0` dead-letters-everything trap.
- [ ] Add the `RetryDefault` constructor to `JobOutcome` (consumes `defaultRetryDelay`); fix the `Dead` docstring (archives, not DLQ, when `useDeadLetter = False`).
- [ ] Clamp `runJobWorkers` inbox size with `max 1` (matching `runJobOnce`) and document.
- [ ] Validation tests for `mkRetryPolicy` / `mkJobTuning`; behavioral test for `RetryDefault`.

Milestone 4 — collision-free queue naming:

- [ ] Replace truncation in `queueRef` with prefix + 16-hex-char FNV-1a-64 suffix for over-long bases and for bases ending in `_dlq`.
- [ ] Document the sanitization-equivalence rule ("a.b" ≡ "a_b") and the new invariant (physical names never end in `_dlq`).
- [ ] Add a migration note for deployments with sanitized names longer than 43 characters.
- [ ] Tests: long-name divergence, `_dlq`-suffix disambiguation, short names unchanged, derived names always parse.

Milestone 5 — consumer tuning, lease access, and attempt numbers:

- [ ] Add `JobContext` (`extendLease`, `attempt`) and `jobProcessorWithContext :: JobTuning -> Job p -> (JobContext es -> p -> Eff es JobOutcome) -> …`; re-express `jobProcessor` through it.
- [ ] Thread `JobTuning` through `adapterConfigFor` (visibility timeout, batch size, polling).
- [ ] Document the invariant handler-duration < visibility-timeout and the crash-retry cadence (the visibility timeout, not `RetryPolicy`).
- [ ] Tests: worker-path lease extension prevents redelivery; `maxRetries` auto-DLQ; `runJobWorkers` end-to-end smoke test; `enqueueWithDelay` delays first delivery.

Milestone 6 — `runJobOnce` becomes a real drain:

- [ ] Implement `runJobOnceWithContext :: JobTuning -> Int -> Job p -> (JobContext es -> p -> Eff es JobOutcome) -> Eff es Int` as a direct read-loop drain (no shibuya runner); re-express `runJobOnce` through it.
- [ ] Per-message exception safety in the drain (handler throw leaves the message invisible until the visibility timeout, drain continues).
- [ ] Tests: `n` greater than queue length returns promptly (regression for the hang); drains in batches > 1; `Retry` delay actually delays; handler-throw path; auto-DLQ parity with the worker path.

Milestone 7 — DLQ consumption and redrive:

- [ ] Add `DlqEntry p`, `readDlq`, `redriveDlq`, and `purgeDlq` to a new module `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`, re-exported from `Keiro.PGMQ`.
- [ ] Document the DLQ envelope shape, the at-least-once redrive window, and a retention story.
- [ ] Tests: dead-lettered payload is decodable via `readDlq`; `redriveDlq` moves it back and it processes; `purgeDlq` empties the DLQ.

Milestone 8 — honest contracts, gated resilience test, and wiring:

- [ ] Write the "Delivery and crash semantics" haddock section in `Keiro.PGMQ.Job` (at-least-once windows, idempotent-handler requirement, DLQ send-then-delete duplicate window, transient-poll-error caveat pending plan 67).
- [ ] Add the worker-resilience acceptance test (`pg_terminate_backend` mid-poll; worker keeps polling) as `pendingWith` until `docs/plans/67-…` lands; flip to active and reconcile against plan 67's Interfaces section when it does.
- [ ] Add `cabal test keiro-pgmq-test` to the `haskell-test` recipe in `Justfile`.
- [ ] Final pass: `cabal build all` and all suites green; update MasterPlan rollup checkboxes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. Research-phase notes that shaped the plan are recorded in Context and Orientation and in the Decision Log — notably that `Shibuya.Adapter.Pgmq.Internal` is a hidden module, which forces the `runJobOnce` drain to own its ack mechanics, and that keiro-dsl conformance fixtures construct `Job`/`JobCodec`/`RetryPolicy` records directly, which constrains which record changes are affordable.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Expose visibility timeout, batch size, and polling as a new `JobTuning` record passed at the consumption sites (`jobProcessorWithContext`, `runJobOnceWithContext`) rather than as a new strict field on `Job` or extra fields on `RetryPolicy`.
  Rationale: The audit finding proposed "a new JobQueueConfig field on Job, or extend RetryPolicy". Both would be compile-breaking: `Job` and `RetryPolicy` use strict fields, and GHC hard-errors on record construction that omits a strict field. Research found three construction sites outside this package's control — the keiro-dsl scaffold emitter (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits `RetryPolicy { … }` literals) and two conformance fixtures — plus the two consumer applications (rei, hospital-capacity) named in `docs/plans/56-…` and `57-…`. The MasterPlan's Decision Log accepts exactly one breaking change in the whole initiative (EP-2's codec signature) and declares the keiro-dsl toolchain out of scope. Tuning is also genuinely a consumer-deployment concern (two worker fleets may legitimately read the same queue with different batch sizes), so attaching it at the point where the handler is supplied is principled, not just convenient. `jobProcessor` and `runJobOnce` keep their exact signatures and defaults (30 s / batch 1 / 1 s standard polling, identical to today's behavior).
  Date: 2026-06-11

- Decision: `JobCodec.decodeJob` changes type from `Value -> Either Text p` to `Value -> Either JobDecodeError p`. This is the one deliberate compile-breaking change in this plan.
  Rationale: Retry-vs-dead-letter for a decode failure is a semantic distinction (`version-ahead` is transient, `malformed` is poison) that cannot be smuggled through a `Text`. Exactly one file outside keiro-pgmq constructs a `JobCodec` record (`keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs`); the new `mkJobCodec` helper makes the fix a two-line change and makes future hand-written codecs simpler than the record literal. The version-ahead check is done locally in `keiroJobCodec` (compare the envelope's `v` against `schemaVersion` before calling `migrateToCurrent`), so it does not depend on `docs/plans/68-harden-keiro-core-codec-and-stream-contracts.md` landing its `VersionAhead` `CodecError`; if plan 68 lands first, `keiroJobCodec` additionally maps that error defensively, and a reconcile note is recorded here.
  Date: 2026-06-11

- Decision: `queueRef` keeps its total `Text -> QueueRef` signature. When the sanitized base exceeds 43 characters, or ends in `_dlq`, the physical name becomes `<first-26-chars-of-base, trailing '_' trimmed>_<16 lowercase hex chars of FNV-1a-64 over the full logical name's code points>` (exactly 43 characters in the long case). Short, non-`_dlq` names are byte-for-byte unchanged.
  Rationale: A stable hash of the full logical name makes collisions between distinct logical names practically impossible (64-bit space over a universe of dozens of queue names), while keeping the common case (every queue name in this repository and both consumer apps is well under 43 characters — `hospital_capacity.reservation_work` sanitizes to 34) bit-identical, so no migration is needed for them. Folding `_dlq`-suffixed logical names into the same hash path establishes the invariant "physical main-queue names never end in `_dlq`; DLQ names always do", which kills the third collision class (a logical name masquerading as another queue's DLQ) without making `queueRef` partial. FNV-1a over code points is implemented in ~10 lines with `Data.Bits` from `base` — no new dependency, no cryptographic requirement (this is collision-spreading, not security). Sanitization equivalence ("a.b" and "a_b" both become `a_b`) is documented as intended behavior, not fixed: both spellings naming one queue is the sanitizer's contract.
  Date: 2026-06-11

- Decision: Keep `RetryPolicy.defaultRetryDelay` and make it live: a new `JobOutcome` constructor `RetryDefault` maps to `AckRetry policy.defaultRetryDelay`, and the version-ahead retry path uses the same delay. Do not drop the field.
  Rationale: Dropping the field breaks the keiro-dsl scaffold emitter and generated fixtures (they construct `RetryPolicy` literals with all three fields); consuming it is additive, gives handlers a one-word "retry with the queue's configured delay" outcome, and gives the version-ahead path a principled delay source.
  Date: 2026-06-11

- Decision: `runJobOnce` is reimplemented as a direct `Pgmq.readMessage` loop inside keiro-pgmq, not via shibuya's `runWithMetrics`. The new `runJobOnceWithContext` returns the number of messages disposed of (`Eff es Int`); the compatibility wrapper `runJobOnce` keeps returning `()`.
  Rationale: The hang is structural: the adapter's source stream is infinite (`Stream.repeatM poll`, `shibuya-pgmq-adapter` `Internal.hs:374`) and `runWithMetrics` runs the ingester to completion before processing anything (`shibuya` `Supervised.hs:197-215`), so `Stream.take n` both blocks forever on a short queue and lets visibility timeouts expire pre-processing on a long one. `Shibuya.Adapter.Pgmq.Internal` (with `mkIngested`/`mkAckHandle`) is a hidden module (`other-modules` in the adapter's cabal file), so the drain must own its ack mechanics; the exposed `Shibuya.Adapter.Pgmq.Convert` module supplies `mkDlqPayload` and `pgmqMessageToEnvelope`, keeping the DLQ payload shape byte-identical between the worker path and the drain path. The drain emits no per-message shibuya consumer span (the worker path still does); pgmq-effectful's traced interpreter still covers the SQL spans. Returning the drained count from the `WithContext` variant supports "loop until empty" cadences; the old signature stays for compatibility (changing its result type would trip `-Wunused-do-bind` at existing call sites).
  Date: 2026-06-11

- Decision: Smart-constructor naming follows the MasterPlan config-validation convention shared with `docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md`: `mkX :: … -> Either XConfigError X` with the raw constructor still exported but documented as unvalidated. This plan introduces `RetryPolicyConfigError` and `JobTuningConfigError`; if plan 70 lands first with a different established naming pattern, rename before merging and note it here.
  Date: 2026-06-11

- Decision: The pgmq schema reaches the test template database through a generic hook (`withMigratedSuiteWith :: (Text -> IO ()) -> (Fixture -> IO a) -> IO a`) rather than a pgmq-specific fixture in keiro-test-support.
  Rationale: keiro-test-support has no pgmq dependencies today; a hook keeps it that way while letting the keiro-pgmq suite (which already depends on `pgmq-migration`) apply `Pgmq.Migration.migrate` to the template once per suite. Other suites that need extra template schema later get the same mechanism for free. The ephemeral-pg initdb cache race is owned by `docs/plans/67-…` and is deliberately not touched here.
  Date: 2026-06-11

- Decision: The worker-resilience acceptance test (finding 4) is written now and marked `pendingWith "blocked on docs/plans/67-… (shibuya ingester supervision + pgmq-effectful transient retry)"` so the suite stays green; the `runJobWorkers` haddock states the current honest contract ("a transient database error during polling stops this worker permanently and without any error surfacing") until then.
  Rationale: The fix is upstream-owned (soft dependency). A pending test keeps the acceptance criterion executable and discoverable; honest documentation prevents anyone shipping multi-replica workers believing they self-heal.
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- Milestone 1 completed on 2026-06-13T13:51:14Z. `keiro-test-support` now exposes a reusable template-migration hook and fresh database helper, and `keiro-pgmq-test` uses them so PGMQ schema installation happens once on the suite template while every example runs against its own clone. The shared fixture remains compatible with `keiro-test`.
- Milestone 2 completed on 2026-06-13T13:55:21Z. `JobCodec` now distinguishes malformed payloads from future-version payloads, `keiroJobCodec` detects version-ahead envelopes before migration, and the worker path retries future payloads with the policy's default retry delay. The single `keiro-dsl` direct codec construction was migrated to `mkJobCodec`, and pure tests cover the new codec behavior.


## Context and Orientation

Everything in this section was verified against the working tree and dependency sources in June 2026. Re-verify line numbers before editing; they drift.

### What keiro-pgmq is

PGMQ is a message queue implemented entirely inside PostgreSQL: a queue is a table, `pgmq.send` inserts a JSON message, and `pgmq.read` returns up to `batchSize` messages while making them invisible to other readers for a *visibility timeout* ("vt", in seconds). If the reader deletes the message within the vt, it is done; if not, the message becomes visible again and is redelivered. Each read increments the message's `read_ct` counter (exposed in Haskell as `readCount`, 1 on first delivery). This repository talks to PGMQ through the `pgmq-hs` libraries (source at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`): `pgmq-core` (types; `Pgmq/Types.hs` caps queue names at 47 characters = PostgreSQL's 63-char identifier limit minus the longest internal index prefix `archived_at_idx_`), `pgmq-effectful` (an `effectful` effect `Pgmq` with an interpreter over a hasql pool), and `pgmq-migration` (installs the PGMQ schema with plain SQL, no Postgres extension needed — used by tests).

Shibuya (source at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, package `shibuya-core`) is a worker framework: an *adapter* exposes a streaming `source` of `Ingested` messages (envelope + ack handle + optional lease), a *handler* maps `Ingested` to an `AckDecision` (`AckOk` / `AckRetry delay` / `AckDeadLetter reason` / `AckHalt`), and runners (`Shibuya.App.runApp`, `Shibuya.Runner.Supervised.runWithMetrics`) pump the stream through the handler. An *ingester* is the async that reads the adapter's stream into a bounded inbox; the processor loop drains the inbox. The PGMQ adapter lives in `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` (package directory `shibuya-pgmq-adapter/`); its config record `PgmqAdapterConfig` (`src/Shibuya/Adapter/Pgmq/Config.hs`) carries `visibilityTimeout` (default 30), `batchSize` (default 1), `polling` (default `StandardPolling {pollInterval = 1}`), `deadLetterConfig`, and `maxRetries`. Three of its four modules are exposed; `Shibuya.Adapter.Pgmq.Internal` (which builds `Ingested` values, ack handles, and leases) is an `other-module` and **cannot be imported** from keiro-pgmq. The exposed `Shibuya.Adapter.Pgmq.Convert` provides `mkDlqPayload` (the DLQ message body builder) and `pgmqMessageToEnvelope`.

`keiro-pgmq` (this repository, directory `keiro-pgmq/`) is two layers over that stack. Layer 1, `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`: `QueueRef`/`queueRef` derive a PGMQ-legal physical name plus a `_dlq`-suffixed dead-letter name from an arbitrary logical name, and `JobRuntime`/`withJobRuntime`/`runJobEff` run the `Pgmq : Tracing : Error PgmqRuntimeError : IOE` stack against a hasql pool. Layer 2, `keiro-pgmq/src/Keiro/PGMQ/Job.hs`: the `Job p` record (`jobName`, `jobQueue :: QueueRef`, `jobCodec :: JobCodec p`, `jobPolicy :: RetryPolicy`), producers `enqueue`/`enqueueWithDelay`, `ensureJobQueue`, and consumers `jobProcessor` (builds a shibuya processor), `runJobWorkers` (continuous supervised run via `Shibuya.App.runApp`), and `runJobOnce` (the broken one-shot drain). `keiro-pgmq/src/Keiro/PGMQ/Codec.hs` defines `JobCodec p` (`encodeJob :: p -> Value`, `decodeJob :: Value -> Either Text p`) with two constructors: `aesonJobCodec` (raw aeson) and `keiroJobCodec` (wraps payloads in a `{"v": <version>, "data": <payload>}` envelope and replays a keiro-core `Codec`'s upcaster chain on decode). `keiro-pgmq/src/Keiro/PGMQ.hs` re-exports all three modules. A *dead-letter queue* (DLQ) is a second PGMQ queue holding messages a worker gave up on; *redrive* means moving a DLQ message back onto the main queue for another attempt.

The package's test suite is `keiro-pgmq/test/Main.hs`, cabal component `keiro-pgmq-test` (verified: `cabal test keiro-pgmq-test --dry-run` resolves). It currently starts one ephemeral PostgreSQL via `EphemeralPg.startCached`, installs the PGMQ schema with `Pgmq.Migration.migrate`, and runs all five examples against that single shared database, isolated only by distinct queue names — it does not use `keiro-test-support`. `keiro-test-support/src/Keiro/Test/Postgres.hs` is the repo's suite-level fixture: one cached server, one template database migrated once (`runAllKeiroMigrations` covers the kiroku and keiro schemas only — no pgmq), and a fresh `CREATE DATABASE … TEMPLATE …` clone per example. The MasterPlan's crash-window-test integration point requires suites to use this pattern. Note the `keiro-pgmq-test` suite is currently absent from the `Justfile` `haskell-test` recipe (only `keiro-test` and `jitsurei-test` run there).

Known in-repo consumers of the keiro-pgmq API surface (matters for any signature change): `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (emits `RetryPolicy { … }` record literals and imports `JobOutcome`/`RetryDelay`), `keiro-dsl/test/conformance-queue-runtime/Generated/HospitalCapacity/Reservation_work/QueuePolicy.hs` (constructs `RetryPolicy`), and `keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs` (constructs `Job { … }` and `JobCodec { … }` literals). The keiro-dsl toolchain is out of the MasterPlan's hardening scope, but compile fixes forced by this plan's one breaking change are in scope here (mirroring the jitsurei carve-out in the MasterPlan).

### The audit findings, re-verified

All fifteen findings relevant to this plan were re-verified against the current sources; line references below are current as of this writing. One finding's *proposed fix shape* was adjusted (finding 1 — see Decision Log first entry); no finding was overturned.

**Finding 1 (HIGH) — visibility timeout hard-coded and unreachable.** `adapterConfigFor` (`keiro-pgmq/src/Keiro/PGMQ/Job.hs:156-164`) starts from shibuya's `defaultConfig` and overrides only `maxRetries` and `deadLetterConfig`; `visibilityTimeout = 30`, `batchSize = 1`, and `StandardPolling 1` are pinned (`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs:169-180`). A handler that takes longer than 30 seconds has its message re-read by the poller while still in flight (duplicate processing), and every vt expiry bumps `read_ct`; once `read_ct > maxRetries` the adapter auto-dead-letters the message before the handler sees it (`mkIngested`, `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:344-365`) — so a healthy-but-slow job is silently dead-lettered without ever failing.

**Finding 2 (HIGH) — no lease access.** The adapter *does* provide vt extension: `mkLease` wraps `pgmq.set_vt` via `changeVisibilityTimeout` (`Internal.hs:164-182`) and `Ingested.lease` carries it. But `wrapHandler` (`Job.hs:170-181`) reduces `Ingested es Value` to just the decoded payload, discarding both the lease and `envelope.attempt` (a zero-based delivery counter populated from `read_ct` by `readCountToAttempt`, `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs:124-132`).

**Finding 3 (HIGH) — `runJobOnce` hangs and can double-process.** `runJobOnce` (`Job.hs:215-230`) applies `Stream.take n` to the adapter's source, which is **infinite** (`Stream.repeatM poll`, `Internal.hs:374` — an empty poll yields an empty `Vector`, which `pgmqMessages` filters out, so `take n` never sees an element to count and keeps polling). And `runWithMetrics` (`shibuya/shibuya-core/src/Shibuya/Runner/Supervised.hs:197-223`) runs the ingester **to completion** before draining the inbox, so even when the queue has ≥ n messages, messages read early can pass their 30-second vt before processing starts, get re-read, re-counted, and processed twice within the same call.

**Finding 4 (HIGH, gated) — transient poll error silently kills a worker.** In `runIngesterAndProcessor` (`Supervised.hs:228-258`) the ingester runs under `UIO.withAsync` whose handle is never awaited; its `finally` sets `streamDoneVar = True`, so when a `PgmqRuntimeError` escapes the polling stream (pgmq-effectful's `runSession` throws on any pool error with no transient retry, `pgmq-effectful/src/Pgmq/Effectful/Interpreter.hs:156-165`, despite the `isTransient` classifier at `:65-78`), the processor drains the inbox and exits *as if the stream had finished normally*. The worker is dead, `done` reads `True`, nothing is logged. Root-cause fixes are owned by `docs/plans/67-…` (currently a skeleton — re-read its Interfaces section when authored; reconcile function names then).

**Finding 5 (MEDIUM) — payloads from the future are permanently dead-lettered.** `keiroJobCodec`'s decode (`keiro-pgmq/src/Keiro/PGMQ/Codec.hs:58-63`) calls `migrateToCurrent`, which returns any payload with `version >= schemaVersion` unchanged (`keiro-core/src/Keiro/Codec.hs:192-196`); the old worker's current decoder then rejects the newer shape, and `wrapHandler` (`Job.hs:174-176`) maps **any** decode failure to `AckDeadLetter (InvalidPayload …)`. During a rolling deploy where producers upgrade before workers, every new-format message is permanently dead-lettered. Related hazard to document: switching an existing queue from `aesonJobCodec` to `keiroJobCodec` changes the wire shape (bare payload → `{"v","data"}` envelope), so in-flight messages fail decode after the switch.

**Finding 6 (MEDIUM) — `queueRef` collisions.** `sanitize` (`keiro-pgmq/src/Keiro/PGMQ/Runtime.hs:85-94`) ends with `Text.take 43`, so two logical names sharing a 43-character prefix collide onto the same physical queue *and* DLQ; `"a.b"` and `"a_b"` collide by sanitization (documented equivalence, kept); and a logical name ending in `_dlq` can collide with another queue's derived DLQ. The 43 + 4 = 47 budget itself is correct (`pgmq-core` `parseQueueName`: 63 − length `"archived_at_idx_"` = 47).

**Finding 7 (MEDIUM) — `RetryPolicy` unvalidated.** First delivery has `read_ct = 1` and the adapter auto-DLQs when `read_ct > maxRetries` (`Internal.hs:349-357`), so `maxRetries = 0` dead-letters every message before the handler runs, silently. A negative `RetryDelay` sets a vt in the past (immediate redelivery storm).

**Finding 8 (MEDIUM) — no DLQ story.** keiro-pgmq configures the DLQ with `directDeadLetter job.jobQueue.dlqName True` (`Job.hs:162`), i.e. `includeMetadata = True`, so DLQ bodies are `{"original_message": …, "dead_letter_reason": …, "original_message_id": …, "original_enqueued_at": …, "last_read_at": …, "read_count": …, "original_headers": …}` (`Convert.hs:134-166`). A `Job`'s own codec cannot decode that wrapper; there is no inspect/redrive helper; DLQs grow forever.

**Finding 9 + 15 — test gaps.** `keiroJobCodec` has zero tests. Also untested: auto-DLQ on `maxRetries`, handler-throws, `Retry` delay actually delaying, `enqueueWithDelay`, `runJobWorkers`, batch > 1, and `runJobOnce` with `n` greater than queue length (which would hang today). The suite shares one database across all examples and does not use keiro-test-support.

**Findings 10–12 (LOW) — documentation and small fixes.** At-least-once windows are undocumented (the adapter's DLQ path *sends to the DLQ, then deletes* — a crash between the two duplicates the message into the DLQ, `Internal.hs:219-274`; crash-retry cadence is the vt, not the `RetryPolicy` delay). `runJobWorkers` passes `inboxSize :: Int` straight to `Shibuya.App.runApp`, which converts via `fromIntegral … :: Natural` (`shibuya-core/src/Shibuya/App.hs:159-180`) — negative values raise an arithmetic-underflow exception inside the spawn path and 0 wedges the inbox, while `runJobOnce` clamps with `max 1 n` (`Job.hs:226`) — inconsistent. `defaultRetryPolicy.defaultRetryDelay` is consumed by nothing. The `JobOutcome.Dead` docstring says "route to the dead-letter queue" unconditionally, but with `useDeadLetter = False` the adapter **archives** instead (`Internal.hs:222-224`).

**Findings 14 + 16 — keiro-test-support hygiene.** `runSqlOn` (`keiro-test-support/src/Keiro/Test/Postgres.hs:184-194`) acquires a pool, uses it, and releases it without `bracket` — an async exception between acquire and release leaks the pool. `parseConnString` (`Postgres.hs:160-164`) uses partial `error`. There is no way to add extra schema (like pgmq) to the template database. The ephemeral-pg initdb cache race is owned by `docs/plans/67-…`; do not touch it here.

### Sibling-plan coordination (reference by path only)

- `docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md` — soft dependency. Owns the shibuya ingester-supervision fix and pgmq-effectful transient retry. Milestone 8's resilience test is gated on it. If, after it lands, shibuya exposes per-processor failed/done state beyond today's `getProcessorState`, surface it through `runJobWorkers`' returned `AppHandle` documentation — write against that plan's Interfaces section and add a reconcile note here.
- `docs/plans/68-harden-keiro-core-codec-and-stream-contracts.md` — soft coordination. If its `VersionAhead` `CodecError` lands first, `keiroJobCodec` maps it to `JobPayloadFromFuture` in addition to (not instead of) the local version check.
- `docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md` — shares the config-validation convention (`mkX :: … -> Either XConfigError X`); whichever lands first sets the `<Thing>ConfigError` naming, the other follows.


## Plan of Work

The work is eight milestones. Milestone 1 rebuilds the test harness first so every later fix lands with an isolated, deterministic test. Milestones 2–4 are independent of each other (codec, config validation, naming). Milestones 5 and 6 are the two consumer-path overhauls and depend on milestone 3's `JobTuning` and milestone 2's `JobDecodeError` (the shared `wrapHandler` mapping). Milestone 7 (DLQ) depends on milestone 6's drain plumbing for its tests. Milestone 8 closes documentation and the gated acceptance test.

### Milestone 1 — move the keiro-pgmq suite onto keiro-test-support, and fix the fixture's hygiene

Scope: `keiro-test-support/src/Keiro/Test/Postgres.hs` and `keiro-pgmq/test/Main.hs` plus both cabal files. At the end, the keiro-pgmq suite runs every example against a fresh database cloned from a template that carries the pgmq schema, and the fixture no longer leaks pools or dies with a bare `error`.

In `Keiro.Test.Postgres`: rewrite `runSqlOn` with `bracket` so the pool is released on any exception:

```haskell
runSqlOn :: Text -> Text -> IO ()
runSqlOn connStr sql =
    bracket acquire Pool.release \pool ->
        Pool.use pool (Session.script sql) >>= either (fail . show) pure
  where
    acquire =
        Pool.acquire $
            Pool.Config.settings
                [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
                , Pool.Config.size 1
                ]
```

Change `parseConnString :: Text -> ConnectionString` to `parseConnString :: Text -> IO ConnectionString`, replacing `error …` with `fail ("Keiro.Test.Postgres: could not parse ephemeral PostgreSQL connection string " <> show connStr <> ": " <> err)` (the string is a local-socket test string; no secrets). Its only caller is `templateCoddSettings`/`migrateTemplate` — lift the `IO` there. Add `withMigratedSuiteWith :: (Text -> IO ()) -> (Fixture -> IO a) -> IO a` whose `setup` runs the standard `migrateTemplate` and then the supplied hook with the *template's* connection string, before any clone exists; define `withMigratedSuite = withMigratedSuiteWith (\_ -> pure ())`. Export `withFreshDatabase :: Fixture -> (Text -> IO a) -> IO a` (already implemented, currently internal). Update the module haddock's usage example to show the hook variant.

In `keiro-pgmq/test/Main.hs`: replace the hand-rolled `Pg.startCached`/`installPgmq`/`finally Pg.stop` scaffolding with:

```haskell
main :: IO ()
main =
    Postgres.withMigratedSuiteWith installPgmq \fixture ->
        hspec $ describe "Keiro.PGMQ" $ around (Postgres.withFreshDatabase fixture) spec
```

where `installPgmq :: Text -> IO ()` keeps the existing `Pool.use pool Migration.migrate` body (the suite already depends on `pgmq-migration`, `hasql-pool`, `hasql`). Each example's type becomes `Text -> IO ()` (the fresh clone's connection string) instead of closing over one shared `connStr`. Keep the per-test queue names; they are now redundant for isolation but harmless and self-describing. Add `keiro-test-support` to the `keiro-pgmq-test` `build-depends` in `keiro-pgmq/keiro-pgmq.cabal`.

Acceptance: `cabal test keiro-pgmq-test` passes with the same five examples; `cabal test keiro-test` (the main keiro suite, an existing consumer of `withMigratedSuite`) still passes, proving the fixture refactor is compatible.

### Milestone 2 — structured decode errors; payloads from the future retry instead of dead-lettering

Scope: `keiro-pgmq/src/Keiro/PGMQ/Codec.hs`, the `wrapHandler` mapping in `Job.hs`, one keiro-dsl fixture, and codec tests. This is the plan's only compile-breaking change (Decision Log).

In `Codec.hs` define:

```haskell
-- | Why a job payload could not be decoded.
data JobDecodeError
    = -- | The payload is malformed for this codec: poison, dead-letter it.
      JobPayloadMalformed !Text
    | -- | The payload was written by a NEWER schema version than this worker
      -- knows (carries payload version, then this codec's version). Transient
      -- during a rolling deploy: retry, do not dead-letter.
      JobPayloadFromFuture !Int !Int
    deriving stock (Eq, Show)
```

Change `JobCodec.decodeJob` to `Value -> Either JobDecodeError p`. Add `mkJobCodec :: (p -> Value) -> (Value -> Either Text p) -> JobCodec p` which wraps the `Left` in `JobPayloadMalformed`; re-express `aesonJobCodec` through it. In `keiroJobCodec`, after `parseEnvelope` succeeds, check `version > Codec.schemaVersion codec` and return `Left (JobPayloadFromFuture version (Codec.schemaVersion codec))` before calling `migrateToCurrent`; map envelope-parse failures and `CodecError`s to `JobPayloadMalformed` as today (and, if plan 68's `VersionAhead` constructor exists by then, map it to `JobPayloadFromFuture` too — defensive, see Decision Log). In `Job.hs`'s `wrapHandler`, map `JobPayloadFromFuture` to `AckRetry job.jobPolicy.defaultRetryDelay` and `JobPayloadMalformed err` to `AckDeadLetter (InvalidPayload err)`.

Fix the one external construction site: `keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs` switches its `JobCodec { encodeJob = …, decodeJob = … }` literal to `mkJobCodec encodeReservationWorkItem parseReservationWorkItem`. Run `grep -rn "JobCodec" --include='*.hs'` (excluding `dist-newstyle`) to confirm no other site constructs the record.

Document in the `Keiro.PGMQ.Codec` haddock: deploy workers before producers when bumping a `keiroJobCodec` schema version (a version-ahead payload now retries until an upgraded worker picks it up — it occupies a delivery slot per retry, so it still counts against `maxRetries`; state that operators should size `maxRetries × defaultRetryDelay` to cover their deploy window); and that switching an existing queue from `aesonJobCodec` to `keiroJobCodec` changes the wire shape, so in-flight messages written before the switch will be dead-lettered as malformed — drain the queue first or deploy a transitional codec that falls back to the bare shape.

Tests (pure, no database): `keiroJobCodec` round-trips a payload through the `{"v","data"}` envelope; a v1 payload decodes through an upcaster chain on a `schemaVersion = 2` codec (construct a small `Keiro.Codec.Codec` inline; add `keiro-core` to the test suite's `build-depends`); a `{"v": 99, …}` envelope yields `JobPayloadFromFuture 99 …`; garbage yields `JobPayloadMalformed`. One database test: enqueue a future-version envelope raw, run the (milestone 6) drain or — until then — assert via `wrapHandler`-level unit test that the outcome is retry, then re-check end-to-end in milestone 6 ("future-version payload stays on the queue, never reaches the DLQ").

Acceptance: `cabal test keiro-pgmq-test` green; `cabal build all` green (proves the keiro-dsl fixture fix).

### Milestone 3 — validated configuration surface

Scope: `Job.hs` only, plus tests. At the end, every numeric knob has a validated constructor and a documented unvalidated escape hatch, and `defaultRetryDelay` does something.

Add to `Job.hs` (exported, with `Keiro.PGMQ` re-exporting automatically):

```haskell
-- | How a consumer reads the queue. Seconds for the visibility timeout
-- because PGMQ's vt is integral seconds (Int32).
data JobPolling
    = -- | Sleep this long between empty polls.
      PollEvery !NominalDiffTime
    | -- | Long-poll inside the database: max seconds to wait, then
      -- check interval in milliseconds.
      LongPoll !Int32 !Int32

data JobTuning = JobTuning
    { visibilityTimeout :: !Int32
    , batchSize :: !Int32
    , polling :: !JobPolling
    }

-- | 30 s visibility timeout, batch of 1, 1 s standard polling — identical to
-- the previous hard-coded behavior.
defaultJobTuning :: JobTuning

data JobTuningConfigError
    = NonPositiveVisibilityTimeout !Int32
    | NonPositiveBatchSize !Int32
    | NonPositivePollInterval
    deriving stock (Eq, Show)

mkJobTuning :: Int32 -> Int32 -> JobPolling -> Either JobTuningConfigError JobTuning

data RetryPolicyConfigError
    = -- | maxRetries must be >= 1: PGMQ's read_ct is 1 on FIRST delivery and
      -- the adapter auto-dead-letters when read_ct > maxRetries, so 0 would
      -- dead-letter every message before the handler ever runs.
      NonPositiveMaxRetries !Int64
    | NegativeRetryDelay !RetryDelay
    deriving stock (Eq, Show)

mkRetryPolicy :: Int64 -> RetryDelay -> Bool -> Either RetryPolicyConfigError RetryPolicy
```

(`NominalDiffTime` needs `time` in the library's `build-depends`; add it.) Keep the raw `RetryPolicy` and `JobTuning` constructors exported but haddock them as unvalidated, mirroring the `mkEventStream` convention named in the MasterPlan's Integration Points. Add the `RetryDefault` constructor to `JobOutcome` ("retry after the policy's `defaultRetryDelay`") and map it in `wrapHandler` (and later in the drain) to `AckRetry job.jobPolicy.defaultRetryDelay`. Fix the `Dead` docstring: "Poison message; routed to the dead-letter queue when the policy enables one, otherwise archived by PGMQ (removed from the queue into its archive table), with this reason." Change `runJobWorkers` to pass `max 1 inboxSize` to `runApp` (consistent with `runJobOnce`'s existing clamp) and document the clamp on both.

Tests (pure): `mkRetryPolicy 0 …` and negative-delay are `Left` with the right constructor; `mkJobTuning` rejects 0/negative vt, batch, and poll interval; valid inputs round-trip. Behavioral (database): a handler returning `RetryDefault` on a policy with `defaultRetryDelay = RetryDelay 5` leaves the message on the queue and invisible (a follow-up `Pgmq.readMessage` within the delay returns empty while `queueMetrics` still counts 1).

Acceptance: `cabal test keiro-pgmq-test` green; `cabal build all` green (the keiro-dsl scaffold emitter still compiles because `RetryPolicy`'s fields are untouched and `JobOutcome` only gained a constructor).

### Milestone 4 — collision-free queue naming

Scope: `Runtime.hs` plus tests. Replace the silent `Text.take 43` truncation with a deterministic, collision-spreading scheme (Decision Log third entry).

In `Runtime.hs`, change `sanitize` so it no longer truncates, and add a post-step in `queueRef`:

- Let `base` be the sanitized name (lower-cased, illegal chars → `_`, underscores collapsed, leading letter ensured).
- If `Text.length base <= 43` and `base` does not end in `"_dlq"`, the physical name is `base` (bit-identical to today for every short name — no migration for them).
- Otherwise the physical name is `prefix <> "_" <> hashHex` where `hashHex` is the 16-character lowercase hex rendering of FNV-1a-64 computed over the code points of the **full original logical name** (`Text.foldl' step 0xcbf29ce484222325 logical` with `step h c = (h `xor` fromIntegral (ord c)) * 0x100000001b3`, all in `Word64` via `Data.Bits`), and `prefix` is the first 26 characters of `base` with any trailing `'_'` trimmed. Total length ≤ 26 + 1 + 16 = 43, so the `"_dlq"` suffix still fits PGMQ's 47-character ceiling.

Because hex digits never spell `"dlq"` after an underscore (hex has no `q`), hashed names never end in `_dlq`; combined with the explicit `_dlq` trigger above this establishes the invariant: *physical main-queue names never end in `_dlq`; derived DLQ names always do*, so no logical name can alias another queue's DLQ. Document in the `queueRef` haddock: the sanitization equivalence (`"a.b"` and `"a_b"` intentionally name the same queue — distinct queues must differ in their `[a-z0-9_]` skeletons); the hashing rule and when it applies; and the **migration note**: any pre-existing deployment whose sanitized logical name exceeds 43 characters (or ends in `_dlq`) derives a *different* physical queue after this change — messages already sitting in the old physical queue are not lost but will no longer be read; operators must drain the old queue before upgrading or temporarily run a worker against the old physical name. Verified: both in-repo consumer apps' queue names are unaffected (`hospital_capacity.reservation_work` sanitizes to 34 characters).

Tests (pure): two 50-character logical names sharing a 43-character prefix derive distinct physical names; `queueRef "foo_dlq"` derives a physical name that is hashed, does not end in `_dlq`, and differs from `(queueRef "foo").dlqName`; `queueRef "hospital_capacity.reservation_work"` is exactly `hospital_capacity_reservation_work` (regression: short names unchanged); for a list of adversarial inputs (empty, all-illegal, 100 chars, trailing underscores) both `physicalName` and `dlqName` satisfy `Pgmq.parseQueueName` and `physicalName` never ends in `_dlq`.

Acceptance: `cabal test keiro-pgmq-test` green.

### Milestone 5 — consumer tuning, lease access, and attempt numbers (worker path)

Scope: `Job.hs` plus tests. At the end, the shibuya worker path honors `JobTuning`, and handlers can extend their lease and read their attempt number.

Add:

```haskell
-- | Per-delivery capabilities handed to context-aware handlers.
data JobContext es = JobContext
    { extendLease :: !(NominalDiffTime -> Eff es ())
      -- ^ Push the message's visibility timeout this much further into the
      -- future (PGMQ @set_vt@). Call before the current vt expires.
    , attempt :: !(Maybe Word)
      -- ^ Zero-based delivery attempt (0 = first delivery), from PGMQ's
      -- read_ct. Nothing only if the transport did not report it.
    }

jobProcessorWithContext ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    JobTuning ->
    Job p ->
    (JobContext es -> p -> Eff es JobOutcome) ->
    Eff es (ProcessorId, QueueProcessor es)
```

Implementation: generalize `wrapHandler` to build a `JobContext` from the `Ingested` it already receives — `extendLease = maybe (const (pure ())) (.leaseExtend) ingested.lease` and `attempt = fmap (fromIntegral . unAttempt) ingested.envelope.attempt` — and pass it to the handler; `jobProcessor job h = jobProcessorWithContext defaultJobTuning job (\_ p -> h p)` keeps the old signature byte-compatible. Generalize `adapterConfigFor :: JobTuning -> Job p -> PgmqAdapterConfig` to also set `visibilityTimeout`, `batchSize`, and `polling` (mapping `PollEvery i` to `StandardPolling i` and `LongPoll s ms` to `LongPolling s ms`). Document prominently on both processor builders: *the handler must finish (or extend its lease) within `visibilityTimeout`, otherwise the message is concurrently redelivered and each expiry consumes one of `maxRetries`*; and *after a worker crash, redelivery happens when the visibility timeout expires — the `RetryPolicy` delay governs only explicit `Retry` outcomes*.

Tests (database, generous timing margins): (a) lease extension — `Job` with `mkJobTuning 2 1 (PollEvery 0.2)`, handler increments an `IORef` counter, immediately calls `extendLease 30`, sleeps 4 seconds, returns `Done`; run via `runJobWorkers IgnoreFailures 16 [jobProcessorWithContext …]`, wait, `stopApp`; assert the counter is exactly 1 and the queue is empty (without the extension the vt would expire at t=2 and the poller would deliver a second time). (b) attempt numbers — handler records `attempt`; first delivery sees `Just 0`. (c) `maxRetries` auto-DLQ — policy with `maxRetries = 1`, handler always returns `Retry (RetryDelay 0)`; after two worker passes the message is in the DLQ and the handler ran exactly once more than `maxRetries` allows (i.e. once), proving auto-DLQ happens *before* the handler on the over-limit delivery. (d) `runJobWorkers` smoke test — enqueue, start, observe processed, `stopApp` returns. (e) `enqueueWithDelay` — enqueue with delay 5; an immediate `Pgmq.readMessage` returns empty while `queueMetrics` counts 1.

Acceptance: `cabal test keiro-pgmq-test` green.

### Milestone 6 — `runJobOnce` becomes a real drain

Scope: `Job.hs` plus tests. At the end, the one-shot cadence is loop-based, prompt, and crash-shaped like the worker path. (Design rationale and the hidden-`Internal`-module constraint: Decision Log fifth entry.)

Implement:

```haskell
runJobOnceWithContext ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    JobTuning ->
    Int ->
    Job p ->
    (JobContext es -> p -> Eff es JobOutcome) ->
    Eff es Int
```

as a loop that owns its mechanics directly against the `Pgmq` effect (no shibuya runner): while fewer than `max 1 n` messages have been disposed of, issue one `Pgmq.readMessage ReadMessage { queueName = job.jobQueue.physicalName, delay = tuning.visibilityTimeout, batchSize = Just (min tuning.batchSize remaining), conditional = Nothing }`; if the returned `Vector` is empty, stop (this is the no-hang fix — one empty poll ends the drain; no sleep, no long-poll, because "drain" means "what is there now"). For each message in the batch, in order: (1) replicate the adapter's auto-DLQ guard — if `msg.readCount > job.jobPolicy.maxRetries`, build the DLQ body with `Shibuya.Adapter.Pgmq.Convert.mkDlqPayload msg MaxRetriesExceeded True`, send it to `job.jobQueue.dlqName` (or `Pgmq.archiveMessage` when `useDeadLetter` is off), then `Pgmq.deleteMessage` — byte-identical DLQ shape to the worker path; (2) otherwise decode with `job.jobCodec` and dispatch the `JobOutcome`/`JobDecodeError` exactly as `wrapHandler` does, executing the mechanics inline: `Done` → `deleteMessage`; `Retry d`/`RetryDefault`/`JobPayloadFromFuture` → `changeVisibilityTimeout` with the delay converted by a local saturating seconds conversion (same clamping semantics as the adapter's `nominalToSeconds`: clamp to `Int32` bounds, then `ceiling`); `Dead why`/`JobPayloadMalformed` → DLQ-send-then-delete (or archive); (3) run the handler under `catchAny` (from `unliftio`, already transitively available via effectful — verify; otherwise add `unliftio` to `build-depends`): on a handler exception, do **not** ack — the message stays invisible until its vt expires and redelivers, matching the worker path's crash shape — count it as disposed and continue the drain. The handler receives a `JobContext` whose `extendLease` calls `changeVisibilityTimeout` for this message and whose `attempt` is `readCount - 1` (clamped at 0). Re-express the old API as `runJobOnce n job h = void (runJobOnceWithContext defaultJobTuning n job (\_ p -> h p))`, updating its haddock: "stops at the first empty poll or after n messages, whichever comes first; returns promptly on an empty queue". The library gains `vector` (and possibly `time`/`unliftio`) in `build-depends`.

Tests: (a) **the regression that fails today** — enqueue 1 message, `runJobOnce 5` returns (wrap in a 30-second `timeout` from `System.Timeout` so a regression fails rather than hangs) and the message is processed; (b) enqueue 5, tuning `batchSize = 2`, `runJobOnceWithContext … 5 …` returns 5 and the queue is empty (batch > 1 path); (c) enqueue 3, drain with `n = 2`: exactly 2 processed, 1 remains; (d) `Retry (RetryDelay 3)`: after the drain the message is still counted by `queueMetrics` but invisible to an immediate read; (e) handler throws: drain returns, message still on the queue (invisible), nothing dead-lettered; (f) future-version envelope (from milestone 2): after a drain the message is still on the queue, the DLQ is empty; (g) auto-DLQ parity: `maxRetries = 1`, first drain retries with delay 0, second drain moves it to the DLQ without invoking the handler (assert via handler-call counter).

Acceptance: `cabal test keiro-pgmq-test` green, including the timeout-guarded no-hang test.

### Milestone 7 — DLQ consumption, redrive, and retention

Scope: new module `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` (added to `exposed-modules` and re-exported from `Keiro.PGMQ`), plus tests.

Define:

```haskell
-- | A decoded dead-letter entry: shibuya's DLQ wrapper, unwrapped.
data DlqEntry p = DlqEntry
    { dlqMessageId :: !MessageId          -- the DLQ row's own pgmq id
    , reason :: !Text                     -- "poison_pill: …" | "invalid_payload: …" | "max_retries_exceeded"
    , originalPayload :: !(Either JobDecodeError p)  -- original_message decoded with the Job's codec
    , originalMessageId :: !(Maybe Int64)
    , originalEnqueuedAt :: !(Maybe UTCTime)
    , readCount :: !(Maybe Int64)
    , rawBody :: !Value                   -- the full DLQ body, for forensics
    }

readDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int32 -> Eff es [DlqEntry p]
redriveDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int -> Eff es Int
purgeDlq :: (Pgmq :> es, IOE :> es) => Job p -> Eff es ()
```

`readDlq job n` reads up to `n` DLQ messages with a short visibility timeout (30 s — inspection holds a temporary lease so two operators do not double-inspect; the lease lapses on its own) and parses the wrapper produced by `Shibuya.Adapter.Pgmq.Convert.mkDlqPayload`: required keys `original_message` and `dead_letter_reason`, optional metadata keys (always present for keiro-pgmq queues since `Job.hs` passes `includeMetadata = True`, but parse them as optional for robustness). `originalPayload` runs `job.jobCodec.decodeJob` on `original_message` — this works for both codec families because the DLQ wrapper preserves the original body verbatim (for `keiroJobCodec` queues, `original_message` *is* the `{"v","data"}` envelope). A wrapper that does not even have the two required keys yields an entry with `JobPayloadMalformed` and the raw body, never a dropped message. `redriveDlq job n` loops like the milestone 6 drain but over the DLQ: read a batch, for each message `Pgmq.sendMessage` the `original_message` value back onto `job.jobQueue.physicalName` (a redriven message starts a fresh `read_ct`, deliberately — document), then `Pgmq.deleteMessage` from the DLQ; stop at the first empty batch or after `n`; return the count. Document the at-least-once window: a crash between send and delete leaves the entry in both queues — handlers must be idempotent (same contract as everywhere else in this package). `purgeDlq` is `Pgmq.deleteAllMessagesFromQueue job.jobQueue.dlqName`. Retention story (haddock on the module): PGMQ never expires messages on its own; teams should either run `redriveDlq`/`purgeDlq` from an operational job on a schedule, or archive entries (PGMQ's archive table) before purging; recommend alerting on `queueMetrics` of the DLQ exceeding a threshold.

Tests: enqueue a poison message (handler returns `Dead "bad"`), drain; `readDlq` returns one entry with `reason` beginning `"poison_pill"` and `originalPayload = Right (Ping …)`; `redriveDlq job 10` returns 1, the DLQ is empty, the main queue has 1, and a follow-up drain with a `Done` handler processes it; `purgeDlq` after a fresh dead-letter empties the DLQ; a hand-sent garbage DLQ body yields a `JobPayloadMalformed` entry rather than an error.

Acceptance: `cabal test keiro-pgmq-test` green.

### Milestone 8 — honest contracts, the gated resilience test, and repo wiring

Scope: haddocks in `Job.hs`, one pending test, `Justfile`, MasterPlan rollup.

Write a "Delivery and crash semantics" section in the `Keiro.PGMQ.Job` module haddock, in plain language: delivery is at-least-once and handlers must be idempotent; a crash mid-handler redelivers after the visibility timeout (cadence = vt, not the `RetryPolicy` delay); dead-lettering is send-then-delete, so a crash between the two can duplicate a message into the DLQ; redrive has the same window in the other direction; each vt expiry consumes one `maxRetries` slot. On `runJobWorkers`, until `docs/plans/67-…` lands, state plainly: "Known limitation: a transient database error during polling (connection drop, pool acquisition timeout) terminates this worker's polling loop permanently and silently — the processor reports done, not failed. Fix tracked in docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md; until it lands, monitor queue depth externally and restart workers on alert." When plan 67 lands: delete that paragraph, flip the pending test below to active, and reconcile against plan 67's Interfaces section (it is a skeleton at the time of writing; whatever supervision/retry API it publishes, the keiro-pgmq-side contract is purely behavioral — no keiro-pgmq code change is expected beyond the test).

The resilience test, written now, `pendingWith` the plan-67 message: in a fresh database, start `runJobWorkers` for a job whose handler records invocations; from a second connection run `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()` (forces a session-level connection error in the worker's next poll — `isTransient` classifies it transient); then `enqueue` a message and assert it is processed within a generous timeout; `stopApp`. Pre-67 this fails (worker silently dead); post-67 it must pass.

Add `cabal test keiro-pgmq-test` to the `haskell-test` recipe in `Justfile` (currently only `keiro-test` and `jitsurei-test` run there, so CI-by-convention never exercised this suite). Tick the two EP-8 lines in the MasterPlan's Progress rollup when the corresponding milestones complete.

Acceptance: `just haskell-test` runs the keiro-pgmq suite; full `cabal build all` and all suites green.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless stated otherwise. Dependency sources are read-only references: shibuya at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, the adapter at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`, pgmq-hs at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`. Never search `/nix/store` or `/`.

Before starting, re-verify the load-bearing facts (line numbers drift):

```bash
grep -n "defaultConfig\|visibilityTimeout = 30" /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs
grep -n "other-modules" -A 2 /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/*.cabal
grep -rn "JobCodec\|RetryPolicy {" --include='*.hs' keiro-dsl | grep -v dist-newstyle
```

Expect: `visibilityTimeout = 30` in `defaultConfig`; `Shibuya.Adapter.Pgmq.Internal` under `other-modules`; exactly one `JobCodec` record construction in keiro-dsl. If any differs, update Context and Orientation and the affected milestone before proceeding, and log the discrepancy under Surprises & Discoveries.

Per milestone, the loop is the same:

```bash
cabal build keiro-pgmq keiro-test-support   # fast type-check of the edited packages
cabal test keiro-pgmq-test                  # the suite this plan owns
```

Expected suite output shape (count grows per milestone; 5 examples exist before milestone 1):

```text
Keiro.PGMQ
  round-trips a payload through aesonJobCodec [✔]
  Done deletes the message [✔]
  ...
Finished in NN.NN seconds
NN examples, 0 failures, 1 pending
```

(The "1 pending" is the milestone 8 resilience test; before milestone 8 expect 0 pending.) After milestones 2 and 3 (the ones that can touch compile sites outside keiro-pgmq), additionally:

```bash
cabal build all
cabal test keiro-test
```

After milestone 1 only, also run `cabal test keiro-test` to prove the keiro-test-support refactor did not disturb the main suite's fixture usage. Commit per milestone with conventional-commit messages, e.g.:

```text
feat(keiro-pgmq): expose JobTuning and JobContext on the consumer path
fix(keiro-pgmq): make runJobOnce a real drain that stops on empty poll
test(keiro-pgmq): move suite onto keiro-test-support template fixture
```

Files this plan edits (no others): `keiro-test-support/src/Keiro/Test/Postgres.hs`, `keiro-test-support/keiro-test-support.cabal` (only if an export forces it — not expected), `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`, `keiro-pgmq/src/Keiro/PGMQ/Codec.hs`, `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, new `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`, `keiro-pgmq/src/Keiro/PGMQ.hs`, `keiro-pgmq/keiro-pgmq.cabal` (library gains `time`, `vector`, possibly `unliftio`; test suite gains `keiro-test-support`, `keiro-core`), `keiro-pgmq/test/Main.hs`, `keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs` (two-line codec fix), `Justfile`, and the MasterPlan rollup.


## Validation and Acceptance

The plan is done when all of the following observable behaviors hold, each backed by a named test in `keiro-pgmq/test/Main.hs` run via `cabal test keiro-pgmq-test` from `/Users/shinzui/Keikaku/bokuno/keiro`:

1. **No hang**: with exactly 1 message enqueued, `runJobOnce 5 job handler` returns within the test's 30-second timeout guard and the message is processed. (This test hangs forever against the pre-plan code — it is the headline regression test.)
2. **Tuning reaches the wire**: a job consumed with `mkJobTuning`-built tuning (vt 2 s) whose handler sleeps 4 s but calls `extendLease 30` runs exactly once; remove the `extendLease` call and the invocation counter reads ≥ 2 (the test asserts the first, the second was verified manually during development).
3. **Validation fails loudly**: `mkRetryPolicy 0 (RetryDelay 60) True` is `Left (NonPositiveMaxRetries 0)`; `mkJobTuning 0 1 (PollEvery 1)` is `Left (NonPositiveVisibilityTimeout 0)`.
4. **Rolling deploys are safe**: a raw `{"v": 99, "data": …}` message on a `keiroJobCodec` queue survives a drain on the main queue (retried, DLQ stays empty); a genuinely malformed body still lands in the DLQ.
5. **Names cannot collide**: two 50-character logical names sharing a 43-character prefix yield distinct `physicalName`s; `queueRef "foo_dlq"` does not alias `(queueRef "foo").dlqName`; `hospital_capacity.reservation_work` derives the same physical name as before this plan.
6. **DLQ is operable**: after a `Dead` outcome, `readDlq` returns the decoded original payload and reason; `redriveDlq` returns 1 and a subsequent drain processes the message; `purgeDlq` empties the DLQ.
7. **Suite hygiene**: every example receives its own database (visible in the test output's isolation — no cross-example queue-name discipline needed); `cabal test keiro-test` still passes.
8. **Honest contract**: the `runJobWorkers` haddock carries the transient-error limitation paragraph, and the resilience test exists as `pending` (post-plan-67: as a passing test).

Interpreting results: hspec prints `NN examples, 0 failures, 1 pending` on success. A failure in test 1 manifests as the suite timing out or the in-test `timeout` returning `Nothing` — both mean the drain regressed to stream-based consumption. Timing-sensitive tests (2, and the Retry-delay tests) use margins of ≥ 2× the relevant interval; if they flake on a loaded machine, widen the vt/sleep pairs proportionally rather than tightening assertions, and log it under Surprises & Discoveries.


## Idempotence and Recovery

Every step is an ordinary source edit plus a test run; re-running any milestone's build/test loop is harmless. The test suite itself is self-cleaning: ephemeral-pg servers are torn down by the fixture's `bracket` even on failure, per-example databases are dropped with `DROP DATABASE … WITH (FORCE)`, and a crashed run at worst leaves a cached initdb directory that the next run reuses (the cache-write race itself is owned by `docs/plans/67-…`).

Two changes carry behavior risk and have explicit fallbacks. First, the `queueRef` hashing change alters derived physical names for long or `_dlq`-suffixed logical names; within this repository and the two known consumer apps no name is affected (verified in milestone 4), but the migration note must ship in the haddock so external operators drain before upgrading — if an affected deployment is discovered mid-rollout, the temporary workaround is to pass the *old physical name* (≤ 43 chars, already sanitized) as the logical name, which the new code maps to itself. Second, the `JobCodec.decodeJob` type change is compile-breaking by design; if an unanticipated construction site surfaces (the grep in milestone 2 missed it), fix it with `mkJobCodec` — the helper is total and behavior-preserving for codecs that previously returned `Left text`.

If a milestone must be abandoned midway, revert its commits (each milestone is committed separately) — no milestone leaves persistent state outside the working tree. The MasterPlan rollup boxes are only ticked after the corresponding milestone's tests are green on a clean checkout.


## Interfaces and Dependencies

Dependencies used and why: `pgmq-effectful >= 0.3 && < 0.4` (`Pgmq.Effectful`) for the `Pgmq` effect — the drain (milestone 6) and DLQ helpers (milestone 7) call `readMessage`, `deleteMessage`, `archiveMessage`, `changeVisibilityTimeout`, `sendMessage`, `deleteAllMessagesFromQueue`, `queueMetrics`, with query records `ReadMessage (..)`, `MessageQuery (..)`, `VisibilityTimeoutQuery (..)`, `SendMessage (..)` all re-exported from `Pgmq.Effectful`. `shibuya-core >= 0.7 && < 0.8` for `Ingested`, `AckDecision`, `RetryDelay`, `Lease`, `runApp`, `runWithMetrics` (the latter only until milestone 6 removes its use). `shibuya-pgmq-adapter >= 0.7 && < 0.8` for `pgmqAdapter`, `PgmqAdapterConfig`, `directDeadLetter`, and — newly load-bearing — `Shibuya.Adapter.Pgmq.Convert.mkDlqPayload` (keeps drain-path DLQ bodies identical to worker-path ones). `keiro-core >= 0.1` for `Keiro.Codec.Codec`/`migrateToCurrent`/`schemaVersion`. New library deps: `time` (NominalDiffTime/UTCTime in `JobContext`/`JobTuning`/`DlqEntry`), `vector` (`readMessage` returns `Vector Message`), and `unliftio` only if `catchAny` is not already reachable. New test deps: `keiro-test-support`, `keiro-core`.

Public surface that must exist at the end (all re-exported through `Keiro.PGMQ`):

In `Keiro.PGMQ.Codec`: `JobCodec (..)` with `decodeJob :: Value -> Either JobDecodeError p`; `data JobDecodeError = JobPayloadMalformed !Text | JobPayloadFromFuture !Int !Int`; `mkJobCodec :: (p -> Value) -> (Value -> Either Text p) -> JobCodec p`; `aesonJobCodec`; `keiroJobCodec :: Codec p -> JobCodec p` (version-ahead aware).

In `Keiro.PGMQ.Job`: `Job (..)` (unchanged fields); `RetryPolicy (..)` (unchanged fields) with `mkRetryPolicy :: Int64 -> RetryDelay -> Bool -> Either RetryPolicyConfigError RetryPolicy` and `data RetryPolicyConfigError`; `data JobOutcome = Done | Retry !RetryDelay | RetryDefault | Dead !Text`; `data JobTuning = JobTuning { visibilityTimeout :: !Int32, batchSize :: !Int32, polling :: !JobPolling }` with `defaultJobTuning`, `mkJobTuning :: Int32 -> Int32 -> JobPolling -> Either JobTuningConfigError JobTuning`, `data JobPolling = PollEvery !NominalDiffTime | LongPoll !Int32 !Int32`, `data JobTuningConfigError`; `data JobContext es = JobContext { extendLease :: !(NominalDiffTime -> Eff es ()), attempt :: !(Maybe Word) }`; `jobProcessorWithContext :: (Pgmq :> es, IOE :> es, Tracing :> es) => JobTuning -> Job p -> (JobContext es -> p -> Eff es JobOutcome) -> Eff es (ProcessorId, QueueProcessor es)`; `runJobOnceWithContext :: (Pgmq :> es, IOE :> es, Tracing :> es) => JobTuning -> Int -> Job p -> (JobContext es -> p -> Eff es JobOutcome) -> Eff es Int`; unchanged signatures for `enqueue`, `enqueueWithDelay`, `ensureJobQueue`, `jobProcessor`, `runJobWorkers` (inbox clamped), `runJobOnce`.

In `Keiro.PGMQ.Dlq` (new): `DlqEntry (..)`, `readDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int32 -> Eff es [DlqEntry p]`, `redriveDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int -> Eff es Int`, `purgeDlq :: (Pgmq :> es, IOE :> es) => Job p -> Eff es ()`.

In `Keiro.PGMQ.Runtime`: `queueRef :: Text -> QueueRef` (same signature, hash-disambiguated derivation, invariant: `physicalName` never ends in `_dlq`).

In `Keiro.Test.Postgres` (keiro-test-support): existing exports unchanged, plus `withMigratedSuiteWith :: (Text -> IO ()) -> (Fixture -> IO a) -> IO a` and `withFreshDatabase :: Fixture -> (Text -> IO a) -> IO a`.

Cross-plan interface notes: the `<Thing>ConfigError` naming is the convention shared with `docs/plans/70-…` (first to land wins; see Decision Log). The version-ahead detection is local and remains correct whether or not `docs/plans/68-…` adds `VersionAhead` to `Keiro.Codec.CodecError`. The milestone 8 resilience test is the consumer of `docs/plans/67-…`'s shibuya/pgmq-effectful fixes; no keiro-pgmq signature depends on that plan's interfaces, only the test's pass/pending status.
