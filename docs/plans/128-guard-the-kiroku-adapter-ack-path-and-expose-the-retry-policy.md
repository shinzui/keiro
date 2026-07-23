---
id: 128
slug: guard-the-kiroku-adapter-ack-path-and-expose-the-retry-policy
title: "Guard the kiroku adapter ack path and expose the retry policy"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
---

# Guard the kiroku adapter ack path and expose the retry policy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`shibuya-kiroku-adapter` (package inside the kiroku repo at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter`; all kiroku-repo paths below are relative to `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`) bridges kiroku subscriptions into Shibuya, the queue-processing framework keiro services run their handlers on. Delivery is ack-coupled: the kiroku worker delivers one event and then BLOCKS until the Shibuya side finalizes an acknowledgement decision. This plan addresses finding KRS-3 of the parent master plan (`docs/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md`) plus the long-documented retry-policy gap.

KRS-3 (MEDIUM): on the bare `kirokuAdapter` + `mkProcessor` path, if a handler exception ever escapes without the ack being finalized, the kiroku worker blocks forever in `takeTMVar` — the subscription reports `Live`, nothing is delivered, no watchdog exists. The kiroku-side blocking half is confirmed in source; the shibuya-runner half (whether the standard runner can actually leave an ack unfinalized) was rated plausible-but-unproven by the review, so this plan's FIRST milestone reproduces — or empirically refutes — the stall before any fix is chosen. The adapter's own docs assert the hazard and push the burden onto users ("Direct `mkProcessor` users should wrap handlers in `guardKirokuHandler`"); the consumer-group helper auto-wraps but the primary single-adapter path does not.

Second deliverable — close the retry-policy gap (verified still absent): neither adapter config exposes the subscription's `retryPolicy`, so the kiroku default (5 total deliveries, then dead-letter) always applies and only the per-retry delay is controllable (via `AckRetry (RetryDelay d)`). This plan exposes `retryPolicy` on both configs and documents how it interacts with `AckRetry` delays.

After this plan: a throwing handler on ANY supported adapter path results in bounded retries and a dead-letter — never a silent wedge; an unfinalized ack (from whatever cause) is surfaced by a pending-ack watchdog event instead of pure silence; and services can finally configure how many deliveries an event gets before dead-lettering.


## Progress

- [ ] M1: stall-reproduction test written against the bare `kirokuAdapter` + `mkProcessor` + `runApp` path with a throwing handler; outcome (wedge reproduced / refuted on shibuya-core 0.8) recorded in Surprises & Discoveries with the transcript; shibuya-core's exception routing read and cited.
- [ ] M2: ack path guarded per M1's outcome — module docs corrected, `kirokuProcessor` helper exported, guarded default decided and implemented; stall scenario now completes with retry/dead-letter.
- [ ] M2 (watchdog): pending-ack watchdog emitting `KirokuEventAdapterAckPending` implemented (or explicitly descoped with rationale in the Decision Log).
- [ ] M3: `retryPolicy` exposed on `KirokuAdapterConfig` and `KirokuConsumerGroupConfig`, threaded to the subscription config; interaction with `AckRetry` documented; tests: default unchanged, custom policy honored.
- [ ] `cabal test shibuya-kiroku-adapter-test` green; living sections updated; ADR distillation pass done.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Milestone 1 is a reproduce-or-refute gate, not a formality; milestone 2's mechanism is chosen by its outcome.
  Rationale: Authoring-time verification found that shibuya-core 0.8.0.1 — the exact version the adapter and keiro pin (`shibuya-core >=0.8 && <0.9`) — added an "always finalize" guarantee to its supervised runner: `processOne` catches handler exceptions and substitutes `AckRetry (RetryDelay 0)`, then always calls the finalizer with bounded retry (see `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`, the `processOne` handler `catchAny`, and `Shibuya/Internal/Runner/Finalize.hs`; the in-code comment states 0.7.1.0's combined catch DID skip finalization when the handler threw). The adapter's module doc (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:106-111`) claiming the runner "records handler exceptions without finalizing the ack" therefore appears STALE for the current cohort. If M1 refutes the wedge on 0.8, the defect narrows to: (a) stale docs steering users wrong, (b) an escaped exception producing a `RetryDelay 0` hot redelivery loop instead of a paced one, and (c) consumers driving `adapter.source` without Shibuya's runner having no guarantee at all — each still worth fixing, with the watchdog covering (c).
  Date: 2026-07-23

- Decision: The watchdog (if built) is observability-only — it emits a `KirokuEvent` when an ack has been pending longer than a threshold; it never auto-finalizes.
  Rationale: Auto-finalizing from a timer races the real handler decision; although the bridge's `finalize` is idempotent (first-wins via `tryPutTMVar`, `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs:119`), a watchdog `AckRetry` that beats a slow-but-correct `AckOk` causes a spurious redelivery and, worse, teaches operators that wedges self-heal. An emitted event turns "silent forever" into "alarmed within a minute", which is the actual gap.
  Date: 2026-07-23

- Decision: Expose `retryPolicy` as a plain field on both configs (defaulting to `defaultRetryPolicy`), not as a new constructor function or a separate escape hatch.
  Rationale: Both configs are built via `default*Config` smart constructors and record-update syntax precisely so added fields inherit defaults without breaking callers (documented at Kiroku.hs:238-239 and 405-410); a field is the established extension point. It is still a PVP-major change (exported record constructors), which the shared release train already absorbs.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All code edits are in the kiroku repo (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, package `shibuya-kiroku-adapter`, plus possibly one observability constructor in `kiroku-store` — see milestone 2; ignore `dist-newstyle`). keiro (this repository, `/Users/shinzui/Keikaku/bokuno/keiro`) is not edited; it consumes the next adapter release. Read plan 125's "Release and pin coordination" for the shared release-train mechanics; the adapter's own next version is 0.5.0.0 (current 0.4.0.0, `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal:3`; record fields added = PVP major).

ADR context: keiro's `docs/adr/` contains only `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq telemetry — not relevant). No kiroku-repo ADR covers the adapter's ack contract. No relevant ADR exists for this work.

Sibling plans: 125 owns all changes to `kiroku-store/src/Kiroku/Store/Error.hs` — this plan consumes store errors but MUST NOT modify that module (master plan Integration Points). 127 touches the subscription worker; this plan touches only the adapter layer above it (and, for the watchdog event, the `KirokuEvent` type in `kiroku-store/src/Kiroku/Store/Observability.hs`, which no sibling owns — coordinate merge order only).

### The ack-coupled bridge (verified)

`kirokuAdapter` (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:301-341`) builds a kiroku `SubscriptionConfig` from `KirokuAdapterConfig` (config record at Kiroku.hs:180-229) and calls `subscriptionAckStream` (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs:180`). That bridge installs a `bridgeHandler` which, for each delivered event, enqueues an `AckItem` carrying an empty reply `TMVar` and then BLOCKS the kiroku subscription worker in `atomically (takeTMVar reply)` (Stream.hs:199-200) until someone finalizes the decision. On the Shibuya side, each stream element becomes an `Ingested` whose `AckHandle.finalize` writes that `TMVar` (`Convert.hs`, `toIngestedAck` at 125+; idempotent first-wins via `tryPutTMVar`, Convert.hs:119). Consequence, confirmed: if NOTHING ever calls `finalize` for a delivered event, the kiroku worker is blocked forever; the store's subscription-state registry still reports `Live`; there is no timeout or watchdog anywhere on the path.

Whether the standard Shibuya path can actually fail to finalize is the unproven half. The adapter's module doc (Kiroku.hs:106-111) says Shibuya's supervised runner "records handler exceptions without finalizing the ack", and directs bare-`mkProcessor` users to wrap handlers in `guardKirokuHandler` (Kiroku.hs:281-282: converts a synchronous exception to `AckRetry (RetryDelay 1)`); `kirokuConsumerGroupProcessors` auto-wraps at Kiroku.hs:516. But shibuya-core 0.8's runner appears to always finalize (see the first Decision Log entry). Locate shibuya-core's source with mori (`mori registry search shibuya-core` — corpus checkout at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, verified at version 0.8.0.1, matching the adapter's `>=0.8 && <0.9` bound) and read `Shibuya/Internal/Runner/Supervised.hs` (`processOne`) and `Shibuya/Internal/Runner/Finalize.hs` during milestone 1. Note `guardKirokuHandlerWith` (Kiroku.hs:268-273) uses `catchSync`, so async exceptions (cancellation) still propagate — that is correct and must be preserved.

### The retry-policy gap (verified)

kiroku's `SubscriptionConfig` has a `retryPolicy :: RetryPolicy` field (`RetryPolicy { retryMaxAttempts :: Int }`, counting TOTAL deliveries; default `defaultRetryPolicy` = 5, `kiroku-store/src/Kiroku/Store/Subscription/Types.hs:174-188`). Neither `KirokuAdapterConfig` (Kiroku.hs:180-229) nor `KirokuConsumerGroupConfig` (Kiroku.hs:359-403) exposes it; `kirokuAdapter`'s `subConfig` (311-319) and the group path's per-member configs never set it, so the default 5 always applies. The delay BETWEEN deliveries is controlled per-ack by the handler returning `AckRetry (RetryDelay seconds)`; the POLICY (how many total deliveries before the worker dead-letters) is what is missing.

### Test scaffolding

The adapter's suite is `shibuya-kiroku-adapter-test` (single `test/Main.hs`, hspec). It already runs full `runApp` + `mkProcessor` pipelines against a real store — see "delivers catch-up events through Shibuya pipeline" (test/Main.hs:276+) for the canonical shape, and the "ack dispositions" group (576+) for retry/dead-letter assertions. Fixtures come from `kiroku-test-support` (`Kiroku.Test.Postgres.withSharedMigratedPostgres` wrapping the suite, `withMigratedTestDatabase` per test). Run from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (inside `nix develop` if `initdb` is not on PATH):

```bash
cabal test shibuya-kiroku-adapter-test
cabal test shibuya-kiroku-adapter-test --test-options='--match "ack"'
```


## Plan of Work

### Milestone 1 — reproduce or refute the stall

Scope: one new test group and a source-reading pass; no production code changes. At the end, this plan's Surprises & Discoveries section records, with a transcript, whether the bare-path wedge exists on the current cohort — and milestone 2 proceeds accordingly.

Write, in `shibuya-kiroku-adapter/test/Main.hs`, a spec "handler exception on the bare adapter path" following the existing pipeline-test shape: real store, append 2 events to a category, `kirokuAdapter` with `defaultKirokuAdapterConfig`, `mkProcessor` WITHOUT any guard, `runApp` with a handler that throws a synchronous exception on the FIRST event only (flag in an `IORef`) and records deliveries. Drive with a bounded overall timeout (the suite's tests use `race`/timeout patterns — reuse them). Assert on observable behavior with three possible outcomes, each explicitly handled so the test DOCUMENTS reality rather than assuming it:

- Wedge: event 2 is never delivered within the window and the subscription still reports alive — the review's KRS-3 confirmed end-to-end. (Check liveness through the delivery record; state can also be read via the store's subscription registry if exported — see `kiroku-store/test/Test/SubscriptionRegistry.hs` for how.)
- No wedge, hot loop: event 1 is redelivered with attempt counts climbing rapidly (shibuya-core substituting `AckRetry (RetryDelay 0)`) until kiroku's default policy (5 total deliveries) dead-letters it, then event 2 arrives. This is the expected outcome on shibuya-core 0.8 per the Decision Log — verify the redelivery pacing (near-zero delay) and that a dead-letter row exists (`kiroku.dead_letters`; the ack-dispositions tests show how to query it).
- No wedge, paced: anything else — investigate and record.

While the test runs, read shibuya-core's routing (corpus at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, found via `mori registry search shibuya-core`): `Shibuya/Internal/Runner/Supervised.hs` `processOne` (handler `catchAny` -> `AckRetry (RetryDelay 0)` substitution -> `finalizeWithRetry`) and `Shibuya/Internal/Runner/Finalize.hs` (bounded finalizer retry). Confirm which shibuya-core versions lack the guarantee (the in-code comment names 0.7.1.0) and whether any supported entry point (`runApp`, `runSupervised`, batch paths) bypasses `processOne` for single-message processors.

Acceptance: the spec passes while ASSERTING the empirically-observed outcome (pin the reality; milestone 2 will change the assertion), and Surprises & Discoveries contains the transcript plus the shibuya-core citations.

### Milestone 2 — guard the ack path

Scope: adapter (and one observability constructor). What "guard" means depends on milestone 1; all three sub-deliverables below are planned, with the third gated:

1. Correct the docs. Rewrite the module-doc hazard paragraph (Kiroku.hs:91-111) to state the verified contract: the kiroku worker blocks until finalization (unchanged, structural); with shibuya-core >= 0.8's always-finalize runner an escaped handler exception yields `AckRetry (RetryDelay 0)` — an UNPACED redelivery loop bounded only by `retryPolicy` (so with the default, 5 rapid deliveries then dead-letter); `guardKirokuHandler` remains recommended to control the retry delay and decision; consumers that drive `adapter.source` without Shibuya's supervised runner MUST finalize every ack themselves or the worker wedges. If milestone 1 instead reproduced a genuine wedge, keep the original warning and say so precisely.

2. Make the guarded path the default surface for single adapters. Export from `Shibuya.Adapter.Kiroku` a helper mirroring what the group path already does internally (Kiroku.hs:516):

```haskell
-- | Build a Shibuya processor from a Kiroku adapter with the handler wrapped
-- in 'guardKirokuHandler' (a synchronous handler exception becomes
-- @AckRetry (RetryDelay 1)@, so redelivery is paced and bounded by the
-- subscription 'Sub.RetryPolicy'). Use 'Shibuya.App.mkProcessor' directly only
-- if you handle exceptions yourself.
kirokuProcessor ::
    Adapter es RecordedEvent -> Handler es RecordedEvent -> QueueProcessor es
kirokuProcessor adapter handler = mkProcessor adapter (guardKirokuHandler handler)
```

   (Match `mkProcessor`'s actual signature/ordering-policy arguments from `Shibuya.App` — mirror how test/Main.hs:179 uses it.) Update the module examples and `docs/user/shibuya-adapter.md` to use `kirokuProcessor`. Decide-and-record whether `kirokuConsumerGroupProcessorsWith` (the factory-parameterized variant, Kiroku.hs:493+) needs the same treatment (it already guards at 516).

3. Pending-ack watchdog (gated: build it if milestone 1 showed any path that can leave an ack unfinalized — including the raw `adapter.source` consumer case, which structurally always can; descope only if the team judges that case out of contract, recording why). Design: `KirokuAdapterConfig` gains `ackPendingWarnAfter :: !(Maybe Int)` (seconds; default `Just 60`; `Nothing` disables). In `kirokuAdapter`, wrap the stream: on yielding an `Ingested`, note the event id and a monotonic timestamp in an `IORef`, and wrap its `finalize` to clear it; a single forked watchdog thread (started with the adapter, killed by `shutdown`) checks the oldest pending entry each ~5s and, past the threshold, emits `KirokuEventAdapterAckPending` (new constructor in `kiroku-store/src/Kiroku/Store/Observability.hs`, carrying subscription name, event id, and pending seconds) through the store's configured event handler (the same channel `KirokuEventHardDeleteIssued` uses; reach it via the `KirokuStore`'s `#eventHandler` — `kiroku-store/src/Kiroku/Store/Effect.hs:331` shows the pattern), re-emitting at most once per threshold interval. Because the bridge delivers effectively one event at a time (depth 1, Kiroku.hs:93-98), "oldest pending" is just "the current one".

Then flip milestone 1's spec to assert the GUARDED behavior on the `kirokuProcessor` path: handler throws on first delivery of event 1 -> event 1 is redelivered after ~1s (the guard's `RetryDelay 1`), handler succeeds on redelivery (make the poison one-shot), event 2 arrives, no dead-letter, nothing wedges. Add a watchdog spec if built: a raw-`adapter.source` consumer that reads one `Ingested` and never finalizes must produce a `KirokuEventAdapterAckPending` within the (test-shortened) threshold.

Acceptance: `cabal test shibuya-kiroku-adapter-test` green; the M1 stall/hot-loop scenario now demonstrably completes with paced retry (and dead-letter only when the poison is persistent).

### Milestone 3 — expose the retry policy

Scope: both configs, threading, docs, tests.

Add `retryPolicy :: !Sub.RetryPolicy` to `KirokuAdapterConfig` (Kiroku.hs:180-229) and `KirokuConsumerGroupConfig` (Kiroku.hs:359-403); default `Sub.defaultRetryPolicy` in `defaultKirokuAdapterConfig` (231+) and `defaultConsumerGroupConfig` (411-424). Thread it: `kirokuAdapter`'s `subConfig` record update (311-319) gains `Sub.retryPolicy = ...`; `kirokuConsumerGroupProcessors` (469+) forwards it into each per-member `KirokuAdapterConfig` (and through `kirokuConsumerGroupProcessorsWith`'s factory). Haddock on both fields must spell out the division of labor: `retryMaxAttempts` counts TOTAL deliveries of an event before the worker dead-letters it (kiroku-side, `Kiroku.Store.Subscription.Types.RetryPolicy`); the DELAY between deliveries comes from the handler's `AckRetry (RetryDelay d)` (or `guardKirokuHandler`'s fixed 1s for escaped exceptions); so "retry 2 times, 5s apart" = `retryPolicy = RetryPolicy 3` + handler returning `AckRetry (RetryDelay 5)`. Update `docs/user/shibuya-adapter.md` accordingly.

Tests, in the ack-dispositions group of `test/Main.hs`: (a) default unchanged — a handler that always returns `AckRetry (RetryDelay 0)` sees exactly 5 deliveries (attempts 0..4 via the envelope's attempt field) and then a dead-letter row (this may already be pinned by an existing spec — extend rather than duplicate); (b) custom policy honored — `retryPolicy = RetryPolicy { retryMaxAttempts = 2 }` on `KirokuAdapterConfig` yields exactly 2 deliveries then dead-letter; (c) group config — same assertion through `kirokuConsumerGroupProcessors` with a size-2 group; (d) the milestone 2 guarded-poison spec re-run with `retryMaxAttempts = 2` and a PERSISTENT poison completes with a dead-letter instead of wedging — the end-to-end closure of KRS-3.

Acceptance: all four specs green; full suite green.


## Concrete Steps

`$KIROKU` = `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

```bash
# Locate and read shibuya-core for M1 (do not guess at its behavior):
mori registry search shibuya-core
# then read, in the printed checkout:
#   shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs   (processOne)
#   shibuya-core/src/Shibuya/Internal/Runner/Finalize.hs
```

```bash
cd $KIROKU
nix develop        # if initdb/postgres are not on PATH
# M1:
cabal test shibuya-kiroku-adapter-test --test-options='--match "handler exception"'
# record the observed outcome + transcript in Surprises & Discoveries
```

```bash
cd $KIROKU
# M2 and M3, iterating:
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter-test --test-options='--match "handler exception"'
cabal test shibuya-kiroku-adapter-test --test-options='--match "retry"'
cabal test shibuya-kiroku-adapter-test
```

Expected final transcript additions:

```text
kiroku adapter ack guard
  a throwing handler on the guarded path is retried after ~1s and completes [✔]
  an unfinalized ack raises KirokuEventAdapterAckPending within the threshold [✔]
retry policy
  default policy delivers 5 times then dead-letters [✔]
  custom retryMaxAttempts=2 delivers twice then dead-letters [✔]
  group config forwards the policy to every member [✔]
  persistent poison with a custom policy dead-letters instead of wedging [✔]
```


## Validation and Acceptance

Beyond compilation: (1) the KRS-3 scenario — a handler that throws — is demonstrated end-to-end BEFORE the fix (milestone 1's pinned reality: wedge or unpaced hot loop) and AFTER (paced retry, then completion or dead-letter; never a wedge, never `Live`-while-dead silence); (2) if the watchdog is built, silence itself is gone: a deliberately-unfinalized ack produces a typed observability event a human can alarm on; (3) the retry policy is user-visible: changing one config field changes the observable delivery count before the dead-letter row appears, on both the single and group paths; (4) the module docs and user guide describe the verified contract, not the pre-0.8 one.


## Idempotence and Recovery

All tests run against per-test/per-suite ephemeral databases and are safely repeatable. The milestone 2 helper and milestone 3 fields are additive; existing callers compile unchanged only if they use the `default*Config` smart constructors (the module already documents that full record literals are unsupported extension-wise — Kiroku.hs:238-239); keiro uses the smart constructors. If the watchdog misfires in practice (false pending warnings under long legitimate handler runs), it is tunable (`ackPendingWarnAfter`) and disableable (`Nothing`) without touching the guard or policy work — and it never changes ack outcomes by design. Version/release: adapter 0.5.0.0 on the shared release train (see plan 125); if this plan lands last among 125-128 it cuts the kiroku release and the keiro-side pin bump happens per plan 125 milestone 4 / plan 126's coordination note.


## Interfaces and Dependencies

End state, package `shibuya-kiroku-adapter` (0.5.0.0):

- `Shibuya.Adapter.Kiroku.kirokuProcessor :: Adapter es RecordedEvent -> Handler es RecordedEvent -> QueueProcessor es` (new; exact signature aligned with `Shibuya.App.mkProcessor`'s real shape at implementation time).
- `Shibuya.Adapter.Kiroku.KirokuAdapterConfig` gains `retryPolicy :: !Kiroku.Store.Subscription.Types.RetryPolicy` and (if built) `ackPendingWarnAfter :: !(Maybe Int)`; `KirokuConsumerGroupConfig` gains `retryPolicy`; both defaults extended.
- Unchanged: `guardKirokuHandler` / `guardKirokuHandlerWith` semantics (sync-only catch), `kirokuAdapter`'s signature, the `Convert` module's idempotent finalize.

Possible `kiroku-store` addition (watchdog only): `Kiroku.Store.Observability.KirokuEvent` gains `KirokuEventAdapterAckPending` — coordinate with sibling plans on the shared file, and note plan 125 owns `Error.hs`, NOT `Observability.hs`, so this is merge-order coordination only.

Dependencies read but not modified: `shibuya-core` 0.8.x (`Shibuya.App.mkProcessor`/`runApp`, `Shibuya.Handler.Handler`, `Shibuya.Core.Ack.AckDecision`; source via `mori registry search shibuya-core`); `kiroku-store` subscription surface (`subscriptionAckStream`, `RetryPolicy`, dead-letter table). Test dependencies already present in `shibuya-kiroku-adapter.cabal` (hspec, async, stm, kiroku-test-support).
