---
id: 301
slug: trace-pre-handler-dead-letters-on-the-continuous-job-worker-to-fix-bug-7
title: "Trace pre-handler dead letters on the continuous job worker to fix BUG-7"
kind: exec-plan
created_at: 2026-09-30T21:02:49Z
intention: "intention_01m3t20zasen6se4xbnh3pg50m"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T21:02:49Z
---

# Trace pre-handler dead letters on the continuous job worker to fix BUG-7

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-pgmq` runs typed background jobs on PGMQ, the PostgreSQL-native message queue. Every
job carries a `RetryPolicy` whose `maxRetries` is the number of deliveries PGMQ may make
before the message is moved to the dead-letter queue (DLQ) without running the handler
again. The package promises, in the tracing section of `keiro-pgmq/src/Keiro/PGMQ/Job.hs`
and in [ADR-1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md), that every
delivery on either execution path runs inside exactly one Consumer-kind span named
`<jobName> process`, that the span continues the producer's trace when the message was
enqueued with `enqueueTraced`, and that a dead-letter finalization ends the span with an
`ERROR` status and the reason.

[BUG-7](../bug-reports/7-pre-handler-dead-letter-has-no-process-span.md), filed from the
external verification harness Kenshou, shows that the continuous worker path breaks that
promise for one class of delivery. A message whose PGMQ read count already exceeds
`maxRetries` when it is read is dead-lettered by the PGMQ adapter while it is still
polling, before shibuya's supervised runner has opened the per-message span. The DLQ row
appears, the handler is never called (correct), and no `<jobName> process` span is ever
exported (the defect). An operator following a trace from the producer sees the enqueue and
the low-level PGMQ operation spans, then nothing: the trace simply stops where the job was
given up on.

After this plan, the retry-ceiling check on the continuous path runs inside the process
span, exactly as it already does on the bounded one-shot path. A message that has
exhausted its ceiling produces one Consumer span that is a child of the producer's span,
carries `shibuya.ack.decision=ack_dead_letter` and `shibuya.dead_letter.reason.code=max_retries_exceeded`,
ends with status `ERROR "max_retries_exceeded"`, and, because the DLQ write now happens
inside that span, has the DLQ `publish` span and the main-queue delete span as its
children. Concretely, after implementation, running

```bash
cabal test keiro-pgmq-test --test-show-details=direct --test-options='--match "retry ceiling"'
```

from the repository root passes two examples that fail on today's tree: one that
reproduces Kenshou's exact shape (a traced enqueue to a job with `maxRetries = 0`, one DLQ
row, zero handler calls, exactly one process span with the producer as its parent) and one
that shows a job retried once and then exhausted producing two process spans, one
`ack_retry` and one `ack_dead_letter`. The bug report moves to `fixed` with
`fixedVersion: unreleased` until the next lockstep release.


## Progress

- [ ] Milestone 0: add the `waitForProcessSpan` helper and the red example "worker-path retry ceiling dead letter emits one process span that continues the enqueued parent" to `keiro-pgmq/test/Main.hs`; record its failing output in Surprises & Discoveries.
- [ ] Milestone 0: link this plan from the BUG-7 report body with the root cause, set the report to `confirmed`, advance `generated`, log the bundle, and validate it.
- [ ] Milestone 0: commit the red example and the report update.
- [ ] Milestone 1: add `deliveryReadCount` and `exceedsRetryCeiling` to `keiro-pgmq/src/Keiro/PGMQ/Job.hs`; guard `wrapHandler` with the ceiling; set the adapter's `maxRetries` to `maxBound` in `adapterConfigFor`; reuse `exceedsRetryCeiling` in the one-shot `processMessage`.
- [ ] Milestone 1: rewrite the `RetryPolicy`, `adapterConfigFor`, `wrapHandler`, and `runJobWorkers` haddocks and the module header's delivery and tracing sections.
- [ ] Milestone 1: add the second example "worker-path retry ceiling reached after a Retry traces both deliveries"; `cabal test keiro-pgmq-test` passes in full, including the Milestone 0 example.
- [ ] Milestone 1: write the `keiro-pgmq` and root changelog entries; commit.
- [ ] Milestone 2: update `docs/user/work-queues.md` (retry section and tracing paragraph), advance `generated`, log the bundle, validate.
- [ ] Milestone 2: update ADR-1 with the retry-ceiling ownership rule and the handler-started event difference, advance its `timestamp`, log the bundle, validate.
- [ ] Milestone 2: move BUG-7 to `fixed` with `fixedVersion: unreleased` and a `resolution`; update the bug-report index row; log and validate; commit.
- [ ] Milestone 2: run `just verify` to completion, reading the exit code from inside the log, and record the result.
- [ ] Milestone 2: fill in Outcomes & Retrospective and record the Kenshou follow-up.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fix BUG-7 inside `keiro-pgmq` by moving the retry-ceiling check into keiro's own
  shibuya handler (`wrapHandler`), which shibuya's supervised runner calls inside the
  per-message process span, and by disabling the adapter's own pre-span check with
  `maxRetries = maxBound` in `adapterConfigFor`.
  Rationale: The adapter applies its ceiling on the source stream in `mkIngested`, and
  nothing keiro can pass to the adapter changes where that check runs. The only two
  places keiro controls are the adapter configuration and the handler. The bounded
  one-shot path already performs exactly this check inside its own span
  (`processMessage` in `runJobOnceWithContext`), so after this change both paths apply
  the same keiro-owned rule at the same point in the delivery, which is what ADR-1's
  "shared observable contract" was always meant to describe. The alternative of
  opening a span from the adapter's `onAutoDeadLetter` callback was rejected: that
  callback fires after the DLQ write has completed, in plain `IO`, so any span opened
  there would have a fabricated extent, would not parent the DLQ `publish` span, and
  would not carry the producer's context.
  Date: 2026-09-30

- Decision: Do not wait for, and do not depend on, an upstream change to
  `shibuya-pgmq-adapter` (`mori://shinzui/shibuya-pgmq-adapter`, 0.16.1.0 on Hackage,
  pinned by keiro as `^>=0.16.1.0`).
  Rationale: keiro's contract is keiro's to keep, the fix above is complete without any
  adapter change, and this repository's practice is to block only on released upstream
  fixes. If the adapter later opens a span around its own auto-dead-letter, keiro's
  configuration still never triggers it, so nothing changes for keiro users.
  Date: 2026-09-30

- Decision: Derive the delivery's PGMQ read count on the worker path from shibuya's
  zero-based `Envelope.attempt` as `attempt + 1`, and treat a missing attempt as a first
  delivery.
  Rationale: The adapter's `pgmqMessageToEnvelope` sets `attempt = Just (read_ct - 1)`
  on every message (clamped at zero), so `attempt + 1 > maxRetries` is exactly the
  adapter's `read_ct > maxRetries`. The raw envelope is not available to a shibuya
  handler, so the attempt is the only faithful source. A missing attempt cannot happen
  with this adapter; treating it as a first delivery means only a policy with
  `maxRetries <= 0` would dead-letter it, which matches the documented meaning of that
  policy rather than silently disabling the ceiling.
  Date: 2026-09-30

- Decision: Accept that a worker-path pre-handler dead letter carries the
  `shibuya.handler.started` span event, and record this as a deliberate difference in
  ADR-1 rather than suppressing it.
  Rationale: shibuya's `processOne` adds that event before it invokes the processor
  handler, and keiro's ceiling check runs inside that handler. The event is true at the
  shibuya level (the processor handler did start) and false at the domain level (the
  job handler did not). The bounded path emits the event only when the domain handler is
  about to run, and its tests assert its absence for pre-handler dead letters. Neither
  behavior is part of the attribute-and-status contract ADR-1 fixes, and suppressing the
  event would require patching shibuya. The one-shot test that asserts the event's
  absence stays as it is; the new worker-path tests do not assert on the event.
  Date: 2026-09-30

- Decision: Acceptance is in-repository: two `keiro-pgmq-test` examples that fail on today's
  tree. Re-running Kenshou's `keiro/queue/correctness/telemetry-contract` scenario and
  strengthening its `pre-handler-dead-letter` cell to demand the span are post-release
  follow-ups in that repository.
  Rationale: Kenshou's cohorts pin released keiro versions from Hackage, and running it
  against an unreleased keiro means authoring a new cohort there, which is separate work
  (the same reasoning as [plan 299](299-fence-outbox-finalization-by-claim-generation-to-fix-bug-5.md)
  and [plan 300](300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md)).
  The in-memory tracing fixture that plan 111 built for the one-shot path already gives
  this repository a faithful witness.
  Date: 2026-09-30

- Decision: Mark BUG-7 `confirmed` in Milestone 0 once the in-repository example
  reproduces the missing span, and `fixed` with `fixedVersion: unreleased` at the end of
  Milestone 2; the release process replaces `unreleased` with the shipped version.
  Rationale: The bug-report profile reserves `confirmed` for the owning repository after
  reproduction and requires `fixedVersion` on `fixed`; `unreleased` is the bundle's
  convention for fixes on master.
  Date: 2026-09-30

- Decision: Update ADR-1 rather than write a new ADR.
  Rationale: ADR-1 already owns the two-path telemetry contract; the durable lesson here
  (keiro owns the retry ceiling on both paths and the adapter's ceiling must stay
  disabled, or the span disappears again) is a constraint on that same contract, not a
  new decision.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a multi-package Haskell repository built with `cabal`. The package that matters
here is `keiro-pgmq/` (cabal package `keiro-pgmq`, version 0.19.0.0, library modules under
`keiro-pgmq/src/Keiro/PGMQ/`, test suite `keiro-pgmq-test` in `keiro-pgmq/test/Main.hs`).
Its tests use `keiro-test-support/` (`Keiro.Test.Postgres`), which starts one throwaway
PostgreSQL server for the whole suite through the `ephemeral-pg` library, installs the
PGMQ schema into a template database, and gives every example a fresh cloned database
whose libpq connection string is the example's argument. Documentation lives under
`docs/`; several `docs/` directories are OKF bundles, directories of Markdown records with
YAML frontmatter that the `okf` command validates and whose `log.md` you append to with
`okf log add`. All commands in this plan run from the repository root unless stated
otherwise. Tests that touch the database need `initdb` and `postgres` on the `PATH`; the
repository's `nix develop` shell provides PostgreSQL 18.

### The pieces, in the words this plan uses

A *job* is a `Job p` value from `keiro-pgmq/src/Keiro/PGMQ/Job.hs`: a queue name, a
payload codec, an ordering contract, and a `RetryPolicy` (defined near line 258). PGMQ
counts deliveries in the message row's `read_ct` column; every read of a row increments
`read_ct`, so the first delivery has `read_ct = 1`. The policy's `maxRetries :: Int64` is
compared against that column: a delivery with `read_ct > maxRetries` must be dead-lettered
with reason `max_retries_exceeded` without calling the handler. With
`defaultRetryPolicy` (`maxRetries = 5`) the sixth read is dead-lettered; with
`maxRetries = 0`, which Kenshou uses to provoke the pre-handler path, the first read is.

A *dead-letter queue* (DLQ) is a second PGMQ queue named `<queue>_dlq`. Dead-lettering
writes a wrapper row there (the original payload, the original headers, `read_ct`, and the
reason) and deletes the main-queue row. `readDlq` in `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`
returns those wrappers as `DlqEntry` values whose `reason` field is the rendered reason
text and whose `readCount` is the original row's `read_ct`.

A *process span* is the OpenTelemetry span that represents the handling of one delivery.
It is Consumer-kind, named `<jobName> process`, and carries the attributes listed in ADR-1.
When a producer used `enqueueTraced`, the message's JSONB `headers` column holds a W3C
`traceparent`, and the consumer installs it as the span's remote parent so the consumer
span is a child of the producer's span in the same trace. The test suite's in-memory
tracing fixture (`setupCapturingProvider`, `capturedSpans`, `theProcessSpan`,
`textAttr`, `parentSpanContext`, `runDbTraced`, near lines 210 to 310 of
`keiro-pgmq/test/Main.hs`) captures every ended span so examples can assert on them.

There are two execution paths. The *bounded one-shot path* is `runJobOnceWithContext`
(near line 984 of `Job.hs`): it reads PGMQ rows directly, converts each to a shibuya
`Envelope`, opens the process span itself with the private `withOneShotProcessSpan`
(near line 915), and inside that span its local `processMessage` (near line 1052) checks
`message.readCount > job.jobPolicy.maxRetries` first, then decodes, then runs the handler,
then settles. This path is correct today and is the model for the fix.

The *continuous worker path* is `runJobWorkers` (near line 890). It hands one *processor*
per job to `Shibuya.App.runApp` from the `shibuya-core` package (a Broadway-style worker
framework, registry project `shinzui/shibuya`, canonical URI `mori://shinzui/shibuya`,
version 0.10.0.0). Each processor is built by `jobProcessorWithContext` (near line 844),
which calls `adapterConfigFor tuning job` (near line 797) to derive a `PgmqAdapterConfig`,
builds the adapter with `pgmqAdapter`, and pairs it with `wrapHandler job handle` (near
line 814). `wrapHandler` is keiro's shibuya handler: it receives a `Shibuya.Message es Value`
(an `Envelope` plus an optional lease), decodes the payload with the job's codec, runs the
domain handler, and translates its `JobOutcome` into a shibuya `AckDecision`. The relevant
code today is:

```haskell
-- keiro-pgmq/src/Keiro/PGMQ/Job.hs, near line 797
adapterConfigFor :: JobTuning -> Job p -> PgmqAdapterConfig
adapterConfigFor tuning job =
  (defaultConfig job.jobQueue.physicalName)
    { visibilityTimeout = tuning.visibilityTimeout,
      batchSize = tuning.batchSize,
      polling = toPollingConfig tuning.polling,
      fifoConfig = toFifoConfig tuning.ordering,
      maxRetries = job.jobPolicy.maxRetries,
      deadLetterConfig =
        if job.jobPolicy.useDeadLetter
          then Just (directDeadLetter job.jobQueue.dlqName True)
          else Nothing
    }

-- near line 814
wrapHandler ::
  Job p ->
  (JobContext es -> p -> Eff es JobOutcome) ->
  (Shibuya.Message es Value -> Eff es AckDecision)
wrapHandler job handle ingested =
  case decodeJob job.jobCodec ingested.envelope.payload of
    Left (JobPayloadFromFuture _payloadVersion _workerVersion) ->
      pure (AckRetry job.jobPolicy.defaultRetryDelay)
    Left (JobPayloadMalformed err) ->
      pure (AckDeadLetter (InvalidPayload err))
    Right p -> toAck <$> handle (contextFor ingested) p
```

### Where the span is opened on the worker path, and why the ceiling misses it

Inside shibuya-core 0.10.0.0, module
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`, every processor runs two
threads. The *ingester* pulls from the adapter's source stream into a bounded inbox. The
processor loop takes messages from the inbox and, for each one, calls the private
`processOne` (near line 608 of that file). `processOne` is the only place on this path that
opens the process span: it extracts the envelope's trace context with
`extractTraceContext`, installs it with `withExtractedContext`, opens
`withSpan' (processSpanName processorId) consumerSpanArgs`, adds the `messaging.*`
attributes, `shibuya.partition`, `shibuya.inflight.count` and `shibuya.inflight.max`, adds
the `shibuya.handler.started` event, calls the processor handler (keiro's `wrapHandler`),
finalizes the returned decision through the adapter's acknowledgement handle with retries,
and then records `shibuya.ack.decision`, the completion event, and the status. For an
`AckDeadLetter reason` it also adds `shibuya.dead_letter.reason.code` and sets status
`Error (renderDeadLetterReason reason)`, which for `MaxRetriesExceeded` is the text
`max_retries_exceeded`.

Inside shibuya-pgmq-adapter 0.16.1.0 (registry project `shinzui/shibuya-pgmq-adapter`,
canonical URI `mori://shinzui/shibuya-pgmq-adapter`, module
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`), the source stream is
`pgmqSource env config = pgmqMessages config & Stream.mapMaybeM (mkIngested env config)`.
`mkIngested` (near line 424) builds the lease and the acknowledgement handle and then:

```haskell
  if msg.readCount > config.maxRetries
    then do
      finalizeAutoDeadLetter
        msg
        env.onAutoDeadLetter
        env.onAckFailure
        (ackHandle.finalize (AckDeadLetter MaxRetriesExceeded))
      pure Nothing
    else
      pure $ Just Ingested { envelope = pgmqMessageToEnvelope msg, ack = ackHandle, lease = Just lease }
```

That is the whole defect. The comparison, the DLQ write, and the main-queue delete all run
on the source stream, on the ingester thread, before the message reaches the inbox. The
message is then dropped (`Nothing`), so `processOne` never sees it and never opens a span.
The only notification is `env.onAutoDeadLetter`, which keiro's `mkPgmqAdapterEnv` (used by
`runJobEff` in `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`) leaves as a no-op. The adapter's
`AckDeadLetter` branch also calls `currentTraceHeaders` to stash the consumer's active span
into the DLQ row's headers; on this path there is no active span, so the original headers
are forwarded verbatim. The Kenshou run recorded `preHandlerCalls=0`,
`preHandlerDlqRows=1`, `preHandlerSpanCount=0`, which is exactly this flow.

Two facts make the fix small. First, the adapter's `validateConfig` rejects only a negative
`maxRetries`, so `maxBound :: Int64` is a valid value that no `read_ct` can exceed, and
`maxRetries` is read nowhere else in the adapter. Second, the adapter's
`pgmqMessageToEnvelope` (module `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs`,
`readCountToAttempt`) sets `Envelope.attempt = Just (Attempt (read_ct - 1))` clamped at
zero, and `wrapHandler` already reads `ingested.envelope.attempt` to populate
`JobContext.attempt`. So keiro can recover `read_ct` as `attempt + 1` and apply the same
comparison the adapter did, from inside `processOne`'s span.

### What changes for a pre-handler dead letter after the fix

The message enters the inbox like any other delivery and is dead-lettered by the processor
loop instead of the ingester. Observable consequences, all intended: exactly one process
span is emitted, parented on the producer when the message was traced; the span carries
`shibuya.ack.decision=ack_dead_letter`, `shibuya.dead_letter.reason.code=max_retries_exceeded`,
status `ERROR "max_retries_exceeded"`, and the `shibuya.inflight.*` gauges; the DLQ
`publish` span and the delete span become children of the process span; the DLQ row's
own headers column now carries the consumer span's `traceparent` with the producer's moved
to `x-shibuya-upstream-traceparent`, exactly as a `Dead` outcome already does on this path
(the wrapper's `original_message.headers`, which `DlqEntry.originalHeaders` and
`redriveDlq` use, is unchanged); shibuya's processor metrics count the delivery as a dead
letter; and a permanently failing DLQ write surfaces through `processOne`'s
`finalization_failed` path (a `ProcessorFailure`) instead of the ingester's stream error.
The DLQ wrapper itself is byte-for-byte what it was: the adapter still builds it from the
same `Pgmq.Message` with `mkDlqPayload`, so `reason` is `max_retries_exceeded` and
`readCount` is the original `read_ct`.

### What must not change

The `RetryPolicy` type and `mkRetryPolicy` validation, `defaultRetryPolicy`, the
`JobContext` record, every exported signature, the one-shot path's observable behaviour
(its ceiling check only gains a shared helper), FIFO ordering, at-least-once delivery, and
the DLQ wrapper shape all stay as they are. `keiro-dsl` scaffolds only a `RetryPolicy`
value (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, near line 4752) and never touches the
adapter configuration, so generated services pick the fix up by rebuilding. `jitsurei`
imports only the `PgmqAdapterEnv` type from the adapter.

### Relevant ADRs

[ADR-1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md) fixes the telemetry
contract for both job execution paths: one Consumer span named `<jobName> process` per
delivery, remote-parent continuation from the enqueued `traceparent`, the common
`messaging.*` attributes, the `shibuya.ack.decision` vocabulary, and the status mapping in
which `AckDeadLetter` ends the span `ERROR` with the reason. It records that the continuous
path gets its span from shibuya's `processOne` and that lower-level PGMQ operation spans
come from the traced `pgmq-effectful` interpreter. This plan restores that contract for
retry-ceiling dead letters on the continuous path and adds one constraint to the ADR: the
retry ceiling is keiro's check on both paths and must run inside the span, so the adapter's
own ceiling stays disabled.

[ADR-25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md)
requires a worker never to let one item's failure end its loop. A dead letter finalized
through `processOne` is one item's terminal outcome, handled per item; the loop continues.

[ADR-44](../adr/0044-fifo-jobs-declare-ordering-and-only-group-heads-batch-safely.md)
governs FIFO consumption. A ceiling-exhausted FIFO head now passes through shibuya's
partitioned scheduling before it is dead-lettered, which preserves within-group order
(the head is finalized before its successor is eligible) exactly as a `Dead` outcome does.

No cross-repository ADR is relevant. Kenshou records its side as finding 38 in
`mori://shinzui/keiro-runtime-kenshou` at `docs/findings/38-keiro-pre-handler-dead-letter-lacks-process-span.md`
(an artifact-level URI is pending).

### Prior plans that shaped this code

[Plan 111](111-trace-one-shot-pgmq-job-processing-with-remote-parent-continuation.md) built
the in-memory tracing fixture, instrumented the one-shot path, and wrote ADR-1; its
Decision Log explains why the two paths are instrumented separately. [Plan 74](74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md)
introduced `adapterConfigFor` and the `maxRetries` pass-through this plan replaces.
[Plan 300](300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md)
edits the same `adapterConfigFor` function (the `polling` field) and the same test file; if
it lands first, rebase on it and keep both changes, and if it lands second, its author does
the same. Neither plan's change depends on the other.

### Sibling reports

[BUG-3](../bug-reports/3-job-worker-exits-after-polling-backend-termination.md) (a worker
exits after its polling backend is terminated) concerns the adapter's transient-error
classifier and is not addressed here. [BUG-4](../bug-reports/4-long-poll-job-worker-consumes-read-attempt-without-handler.md)
and [BUG-6](../bug-reports/6-long-poll-processors-starve-the-job-runtime-pool.md) are
plan 300's. Nothing in this plan makes any of them better or worse.


## Plan of Work

### Milestone 0: reproduce the missing span in `keiro-pgmq-test` and confirm the report

This milestone adds one helper and one example to `keiro-pgmq/test/Main.hs`, updates the
bug report, and commits with the example failing. At the end, running the new example
prints a failure from `theProcessSpan` saying it expected exactly one
`"keiro_pgmq_test.worker_pre_handler_span process"` span and got zero, and that output is
recorded in Surprises & Discoveries.

Add a helper next to `waitUntil` that waits for a named span to be exported. Shibuya ends
the process span after finalization, and the in-memory exporter records a span when it
ends, so an example that has only observed the DLQ row must not assume the span has been
exported yet:

```haskell
-- | Wait (up to 'waitUntil''s budget) for at least one exported span with this
-- exact name. Reading the reference does not shut the provider down, so the
-- caller still ends with 'capturedSpans'.
waitForProcessSpan :: IORef [ImmutableSpan] -> Text -> IO Bool
waitForProcessSpan spansRef name =
  waitUntil do
    spans <- traverse captureSpan =<< readIORef spansRef
    pure (not (null (spansNamed name spans)))
```

Then add the example. It is Kenshou's shape reproduced in one process: a job with
`maxRetries = 0`, a traced enqueue whose producer context is attached only for the enqueue
and detached before the worker starts (so the only path from producer to consumer is the
`traceparent` stored in the PGMQ headers, exactly as the existing one-shot example does), a
continuous worker whose handler counts calls, and assertions on the DLQ wrapper and the
captured span. Place it after "worker-path retry limit auto-routes to the DLQ before the
handler reruns" so the worker-path examples stay together:

```haskell
  it "worker-path retry ceiling dead letter emits one process span that continues the enqueued parent" $ \connStr -> do
    (provider, spansRef) <- setupCapturingProvider
    callCount <- newIORef (0 :: Int)
    let tracer = OTel.makeTracer provider "keiro-pgmq-test" OTel.tracerOptions
        job =
          (mkJob "keiro_pgmq_test.worker_pre_handler_span")
            { jobPolicy = RetryPolicy 0 (RetryDelay 0) True
            }
        tuning =
          either (error . show) id $
            mkJobTuning 30 1 (PollEvery 0.1)
        processSpanName = job.jobName <> " process"
    producerSpan <- OTel.createSpan tracer Ctxt.empty "enqueue" OTel.defaultSpanArguments
    producerCtx <- OTel.getSpanContext producerSpan
    token <- CtxtLocal.attachContext (Ctxt.insertSpan producerSpan Ctxt.empty)
    runDbTraced connStr tracer $ do
      ensureJobQueue job
      _ <- enqueueTraced provider job (MessageHeaders (object [])) (Ping "exhausted" 1)
      pure ()
    CtxtLocal.detachContext token
    OTel.endSpan producerSpan Nothing

    (dlqReached, spanSeen, entries) <-
      runDbTraced connStr tracer $ do
        result <-
          runJobWorkers
            IgnoreFailures
            16
            [ jobProcessorWithContext tuning job \_ctx _payload -> do
                liftIO $ modifyIORef' callCount (+ 1)
                pure Done
            ]
        case result of
          Left err -> liftIO $ fail ("runJobWorkers failed: " <> show err)
          Right app -> do
            ok <- liftIO $ waitUntil do
              dlqLen <- runDb connStr (queueLen job.jobQueue.dlqName)
              pure (dlqLen == 1)
            seen <- liftIO $ waitForProcessSpan spansRef processSpanName
            stopAppQuickly app
            rows <- readDlq job 1
            pure (ok, seen, rows)
    dlqReached `shouldBe` True
    readIORef callCount `shouldReturn` 0
    case entries of
      [entry] -> do
        entry.reason `shouldBe` "max_retries_exceeded"
        entry.readCount `shouldBe` Just 1
      _ -> expectationFailure ("expected one DLQ entry, got " <> show (length entries))
    mainLen <- runDb connStr (queueLen job.jobQueue.physicalName)
    mainLen `shouldBe` 0

    spanSeen `shouldBe` True
    spans <- capturedSpans provider spansRef
    processSpan <- theProcessSpan job.jobName spans
    csKind processSpan `shouldBe` OTel.Consumer
    OTel.traceId (csContext processSpan) `shouldBe` OTel.traceId producerCtx
    parent <- parentSpanContext processSpan
    fmap OTel.spanId parent `shouldBe` Just (OTel.spanId producerCtx)
    textAttr (csAttributes processSpan) "messaging.system" `shouldBe` Just "shibuya"
    textAttr (csAttributes processSpan) "messaging.destination.name"
      `shouldBe` Just job.jobName
    textAttr (csAttributes processSpan) "messaging.operation.type" `shouldBe` Just "process"
    textAttr (csAttributes processSpan) "messaging.message.id" `shouldSatisfy` \case
      Just _ -> True
      Nothing -> False
    textAttr (csAttributes processSpan) "shibuya.ack.decision"
      `shouldBe` Just "ack_dead_letter"
    textAttr (csAttributes processSpan) "shibuya.dead_letter.reason.code"
      `shouldBe` Just "max_retries_exceeded"
    csStatus processSpan `shouldBe` OTel.Error "max_retries_exceeded"
    lookupAttribute (csAttributes processSpan) "shibuya.inflight.count" `shouldSatisfy` \case
      Just _ -> True
      Nothing -> False
```

Every name used here already exists in the test module: `RetryPolicy`, `RetryDelay`,
`mkJobTuning`, `PollEvery`, `enqueueTraced`, `MessageHeaders`, `readDlq`, `IgnoreFailures`,
`runJobWorkers`, `jobProcessorWithContext`, `stopAppQuickly`, `waitUntil`, the tracing
fixture, `Ctxt`, `CtxtLocal`, `OTel`, and `lookupAttribute`. `RetryPolicy 0 ...` uses the
raw constructor deliberately (`mkRetryPolicy` rejects a zero ceiling) because a zero
ceiling is the documented way to dead-letter every delivery before the handler, and it is
what Kenshou's scenario uses. On today's tree the worker dead-letters the row inside the
adapter, `waitForProcessSpan` times out after ten seconds, `spanSeen` is `False`, and the
example fails at `spanSeen `shouldBe` True`; if you comment that line out to see further,
`theProcessSpan` fails with the "expected exactly one ... got 0" message. Record whichever
failure block the tree produces.

Then update the bug report. In
`docs/bug-reports/7-pre-handler-dead-letter-has-no-process-span.md`, set `status:
confirmed`, replace the `generated` block with `by: process:claude-code` and the current UTC
timestamp, keep the existing `reviews` entry untouched, and replace the "Status and
implementation" section's contents with a paragraph that says the report is tracked by
[plan 301](../plans/301-trace-pre-handler-dead-letters-on-the-continuous-job-worker-to-fix-bug-7.md),
that the owning repository reproduced it on the named date with the example above, and a
"Root cause" paragraph in the report's own words: the adapter's `mkIngested` applies the
`read_ct > maxRetries` ceiling on its source stream and drops the message before shibuya's
`processOne`, the only place the continuous path opens a process span, ever sees it. Log
the change and validate:

```bash
okf log add docs/bug-reports --kind Update -m "BUG-7 is confirmed: the adapter dead-letters an over-ceiling read on its source stream before shibuya's supervised runner opens the process span; reproduced by a keiro-pgmq-test example and tracked by ExecPlan 301."
just bug-reports-validate
```

Commit the test file and the report together. The example is red at this commit by design;
say so in the commit body.

### Milestone 1: apply the retry ceiling inside the process span

This milestone is the fix. At the end, the Milestone 0 example passes, a second example
proves the ceiling still triggers after a real retry, every pre-existing example still
passes, and the haddocks and changelogs say what changed.

In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, add two private helpers immediately above
`wrapHandler`. They are the single definition of the ceiling that both paths will use:

```haskell
-- | PGMQ's @read_ct@ for a worker-path delivery, recovered from shibuya's
-- zero-based 'Attempt': the adapter sets @attempt = read_ct - 1@ on every
-- message, so the first delivery is attempt 0 and read count 1. A missing
-- attempt (which the PGMQ adapter never produces) is treated as a first
-- delivery, so only a policy with @maxRetries <= 0@ dead-letters it.
deliveryReadCount :: Maybe Attempt -> Int64
deliveryReadCount = maybe 1 (\(Attempt n) -> fromIntegral n + 1)

-- | The job's retry ceiling, shared by both execution paths: a delivery whose
-- PGMQ read count exceeds 'maxRetries' is dead-lettered with
-- 'MaxRetriesExceeded' before the domain handler runs. Both paths apply this
-- inside the per-message process span, so the dead letter is traced like any
-- other finalization (see ADR-1 and BUG-7).
exceedsRetryCeiling :: Job p -> Int64 -> Bool
exceedsRetryCeiling job readCount = readCount > job.jobPolicy.maxRetries
```

`Attempt (..)` and `Int64` are already imported. Then guard `wrapHandler` so the ceiling is
the first thing it checks, before decoding:

```haskell
wrapHandler job handle ingested
  | exceedsRetryCeiling job (deliveryReadCount ingested.envelope.attempt) =
      pure (AckDeadLetter MaxRetriesExceeded)
  | otherwise =
      case decodeJob job.jobCodec ingested.envelope.payload of
        Left (JobPayloadFromFuture _payloadVersion _workerVersion) ->
          pure (AckRetry job.jobPolicy.defaultRetryDelay)
        Left (JobPayloadMalformed err) ->
          pure (AckDeadLetter (InvalidPayload err))
        Right p -> toAck <$> handle (contextFor ingested) p
  where
    -- contextFor and toAck unchanged
```

`MaxRetriesExceeded` is already imported from `Shibuya.Core.Ack` (the one-shot path uses
it). In `adapterConfigFor`, replace `maxRetries = job.jobPolicy.maxRetries` with
`maxRetries = maxBound` and rewrite its haddock:

```haskell
-- | Build the shibuya PGMQ adapter config from a job's queue and policy: route
-- to the DLQ via the adapter's @directDeadLetter@ path when the policy enables it.
--
-- The adapter's own retry ceiling is disabled on purpose (@maxRetries =
-- maxBound@, which its validation accepts and no @read_ct@ can exceed). The
-- adapter applies that ceiling on its source stream, before shibuya's
-- supervised runner has opened the per-message process span, so a message it
-- dead-lettered there was invisible to tracing (BUG-7). 'wrapHandler' applies
-- the job's 'RetryPolicy' ceiling instead, inside the span. Re-enabling the
-- adapter's ceiling reintroduces the missing span.
```

In `runJobOnceWithContext`'s local `processMessage`, replace the guard
`message.readCount > job.jobPolicy.maxRetries` with
`exceedsRetryCeiling job message.readCount`. Its behaviour is unchanged; the point is that a
reader of either path finds one rule.

Update the prose. In the `RetryPolicy` haddock (near line 252), the sentence "the adapter
auto-dead-letters when @read_ct > maxRetries@" becomes "keiro dead-letters the delivery
when @read_ct > maxRetries@, inside the per-message process span, before the handler
runs". In the module header's "Delivery and crash semantics" section, after "messages whose
read count exceeds 'maxRetries' are dead-lettered before the handler sees them", add: "On
both execution paths that check runs inside the delivery's process span, so a
retry-ceiling dead letter is traced exactly like a handler-decided one." In the "Tracing"
section, after "dead-lettering and halting end it @ERROR@ with the reason", add: "including
the pre-handler dead letters for an exhausted retry ceiling and a malformed payload". In the
`runJobWorkers` haddock, add a sentence stating that keiro's handler applies the retry
ceiling inside that span and the adapter's own ceiling is disabled.

Add the second example to `keiro-pgmq/test/Main.hs`, directly after the Milestone 0 one.
It is the traced twin of "worker-path retry limit auto-routes to the DLQ before the handler
reruns": a ceiling of one, a handler that always asks for an immediate retry, and the
assertion that the two deliveries produce two process spans with the two different
decisions. Span export order is not guaranteed, so the assertions compare as multisets:

```haskell
  it "worker-path retry ceiling reached after a Retry traces both deliveries" $ \connStr -> do
    (provider, spansRef) <- setupCapturingProvider
    callCount <- newIORef (0 :: Int)
    let tracer = OTel.makeTracer provider "keiro-pgmq-test" OTel.tracerOptions
        job =
          (mkJob "keiro_pgmq_test.worker_ceiling_after_retry")
            { jobPolicy = RetryPolicy 1 (RetryDelay 0) True
            }
        tuning =
          either (error . show) id $
            mkJobTuning 30 1 (PollEvery 0.1)
        processSpanName = job.jobName <> " process"
    dlqReached <-
      runDbTraced connStr tracer $ do
        ensureJobQueue job
        _ <- enqueue job (Ping "retry-then-ceiling" 1)
        result <-
          runJobWorkers
            IgnoreFailures
            16
            [ jobProcessorWithContext tuning job \_ctx _payload -> do
                liftIO $ modifyIORef' callCount (+ 1)
                pure (Retry (RetryDelay 0))
            ]
        case result of
          Left err -> liftIO $ fail ("runJobWorkers failed: " <> show err)
          Right app -> do
            ok <- liftIO $ waitUntil do
              dlqLen <- runDb connStr (queueLen job.jobQueue.dlqName)
              pure (dlqLen == 1)
            _ <- liftIO $ waitUntil do
              spans <- traverse captureSpan =<< readIORef spansRef
              pure (length (spansNamed processSpanName spans) >= 2)
            stopAppQuickly app
            pure ok
    dlqReached `shouldBe` True
    readIORef callCount `shouldReturn` 1
    spans <- spansNamed processSpanName <$> capturedSpans provider spansRef
    length spans `shouldBe` 2
    map (\s -> textAttr (csAttributes s) "shibuya.ack.decision") spans
      `shouldMatchList` [Just "ack_retry", Just "ack_dead_letter"]
    map csStatus spans
      `shouldMatchList` [OTel.Ok, OTel.Error "max_retries_exceeded"]
```

`shouldMatchList` comes from `Test.Hspec`, which is imported unqualified. Run the whole
suite:

```bash
cabal test keiro-pgmq-test --test-show-details=direct
```

Both new examples and every pre-existing one must pass. The pre-existing untraced example
"worker-path retry limit auto-routes to the DLQ before the handler reruns" is the proof
that the ceiling's queue-level behaviour (one handler call, then a DLQ row) is unchanged;
"worker-path context exposes the first attempt number" proves `JobContext.attempt` still
reports `Just 0`; the seven one-shot tracing examples prove the shared helper did not
disturb that path.

Add changelog entries under `## [Unreleased]` in `keiro-pgmq/CHANGELOG.md`:

```markdown
### Fixed

- A continuous `runJobWorkers` delivery whose PGMQ read count already exceeds the
  job's `maxRetries` is now dead-lettered inside its `<jobName> process` span,
  so the span exists, continues the producer's trace, and records
  `shibuya.ack.decision=ack_dead_letter` with status `ERROR "max_retries_exceeded"`.
  Previously the PGMQ adapter dead-lettered such a delivery while polling, before
  shibuya opened the span, and no process span was emitted (BUG-7). The retry
  ceiling is now keiro's check on both execution paths; the adapter's own ceiling
  is disabled. Queue behaviour is unchanged: the handler is still not called and
  the DLQ wrapper is the same.
```

and a corresponding entry in the root `CHANGELOG.md` under `## [Unreleased]` in a `### Fixed`
section, naming the package. Run `nix fmt` (the repository's `treefmt` formatter) and
confirm it changes nothing outside the touched files. Commit.

### Milestone 2: document, distill, close the report, and verify

This milestone finishes the paperwork the repository requires and runs the release gate.

In `docs/user/work-queues.md`, in the "Retry, dead-letter, and poison payloads" section,
change the sentence "the raw constructor is unvalidated, and `maxRetries <= 0` dead-letters
**every** message before the handler runs, because PGMQ's `read_ct` is already 1 on first
delivery and the adapter auto-dead-letters when `read_ct > maxRetries`." so that the
final clause reads "and keiro dead-letters a delivery whose `read_ct` exceeds
`maxRetries`". Extend the third bullet ("Every visibility-timeout expiry consumes one
attempt.") with one sentence: "On both execution shapes that dead letter happens inside
the delivery's process span, which records `shibuya.ack.decision=ack_dead_letter` and an
`ERROR` status of `max_retries_exceeded`." In the tracing paragraph that begins "Tracing
follows one contract on both execution shapes", after the sentence ending "continues the
producer's trace across processes.", add: "Pre-handler dead letters (an exhausted retry
ceiling, a malformed payload) are covered by the same span." Change the page's `generated`
block to `by: process:claude-code` with the current UTC time, then log and validate:

```bash
okf log add docs/user --kind Update -m "Work Queues: the retry ceiling is keiro's check on both execution shapes and runs inside the process span, so pre-handler dead letters are traced (BUG-7, plan 301)."
just user-documentation-validate
```

Update ADR-1 (`docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md`). Keep its
`docId`, `status`, and `date`; advance `timestamp` to the current UTC time. In the Decision
section, after the paragraph beginning "`shibuya.ack.decision` is written only after the
finalizing PGMQ statement has returned", add a paragraph stating that the retry ceiling
(`read_ct > maxRetries`, reason `max_retries_exceeded`) is keiro's check on both paths and
runs inside the process span: the bounded drain compares the raw read count in
`processMessage`, and the continuous path compares `attempt + 1` in `wrapHandler`, while
`adapterConfigFor` sets the adapter's own `maxRetries` to `maxBound` because the adapter
applies its ceiling on the source stream before any span exists. Add a second short
paragraph to the deliberate-differences list: the continuous path records the
`shibuya.handler.started` event before keiro's pre-handler checks run, because shibuya
emits it before invoking the processor handler, whereas the bounded path emits it only when
the domain handler is about to run. In Consequences, add that re-enabling the adapter's
ceiling, or moving keiro's check out of the handler, silently removes the span for
exhausted deliveries, and that the two worker-path examples named in this plan are the
guard. Add this plan to References. Then:

```bash
okf log add docs/adr --kind Update -m "ADR-1: the retry ceiling is keiro's check on both job execution paths and runs inside the process span; the adapter's ceiling stays disabled (BUG-7, plan 301)."
just adr-validate
```

Close the report. In `docs/bug-reports/7-pre-handler-dead-letter-has-no-process-span.md`
set `status: fixed`, add `fixedVersion: unreleased`, add a `resolution: >-` block ("The
retry ceiling now runs inside keiro's shibuya handler, within the per-message process
span, and the adapter's own pre-span ceiling is disabled; an exhausted delivery emits one
Consumer span with `ack_dead_letter` and status `ERROR max_retries_exceeded` that
continues the producer's trace. Re-running the Kenshou scenario with a stronger
pre-handler cell is a post-release follow-up."), and advance `generated.at`. In
`docs/bug-reports/index.md`, update the BUG-7 row of the status table to `fixed`, plan 301,
and "Implemented; fixedVersion unreleased." Log and validate:

```bash
okf log add docs/bug-reports --kind Update -m "BUG-7 is fixed on master (fixedVersion unreleased): the retry ceiling runs inside the process span on the continuous worker path; ExecPlan 301."
just bug-reports-validate
```

Commit. Finally run the release gate and record the result in Progress:

```bash
just verify > /tmp/verify-301.log 2>&1; echo "exit=$?" >> /tmp/verify-301.log
tail -5 /tmp/verify-301.log
```

`just verify` stops at the first failing recipe, so read the `exit=` line from inside the
log rather than trusting the last lines of output, and if it fails, fix the failing recipe
and rerun until the log ends with `exit=0`. Then write Outcomes & Retrospective, including
the follow-up outside this repository: after the next keiro release, Kenshou
(`mori://shinzui/keiro-runtime-kenshou`) should strengthen the `pre-handler-dead-letter`
cell in `kenshou-keiro/src/Kenshou/Suite/Keiro/Queue/Telemetry.hs` to require exactly one
`telemetry-pre-handler process` span with `ack_dead_letter` and an error status whenever
tracing is on, re-run `keiro/queue/correctness/telemetry-contract` on a cohort that
includes the released keiro, and close its finding 38.


## Concrete Steps

All commands run from the repository root, inside `nix develop` (or any shell with GHC
9.12, `cabal`, `bun`, `okf`, `just`, and PostgreSQL 18 binaries on the `PATH`).

Before starting, confirm the tree and the tools:

```bash
git status --short
which initdb postgres okf just
cabal build keiro-pgmq
```

Expect an empty status (or only files you already know about), four paths, and a
successful build.

Milestone 0. Edit `keiro-pgmq/test/Main.hs` as described, then run only the new example:

```bash
cabal test keiro-pgmq-test --test-show-details=direct --test-options='--match "retry ceiling"'
```

Expected today:

```text
Keiro.PGMQ
  worker-path retry ceiling dead letter emits one process span that continues the enqueued parent [✘]

Failures:

  keiro-pgmq/test/Main.hs:NNN:
  1) Keiro.PGMQ worker-path retry ceiling dead letter emits one process span that continues the enqueued parent
       expected: True
        but got: False
```

The `False` is `spanSeen`: ten seconds after the DLQ row appeared, no
`keiro_pgmq_test.worker_pre_handler_span process` span had been exported. Copy the failure
block into Surprises & Discoveries. Update the bug report, log, validate, and commit:

```bash
git add keiro-pgmq/test/Main.hs docs/bug-reports
git commit -m "test(keiro-pgmq): reproduce the untraced retry-ceiling dead letter on the worker path

Add a traced worker-path example for a job whose first read exceeds a zero
retry ceiling. Today the adapter dead-letters the row while polling, before
shibuya opens the per-message span, so the example fails with no process
span exported; it passes once the ceiling runs inside the handler.
Confirm BUG-7 with this reproduction.

ExecPlan: docs/plans/301-trace-pre-handler-dead-letters-on-the-continuous-job-worker-to-fix-bug-7.md
Intention: intention_01m3t20zasen6se4xbnh3pg50m"
```

Milestone 1. Edit `keiro-pgmq/src/Keiro/PGMQ/Job.hs` and `keiro-pgmq/test/Main.hs` as
described, then:

```bash
cabal build keiro-pgmq
cabal test keiro-pgmq-test --test-show-details=direct
```

Expected: the build succeeds with no new warnings (the package builds with `-Wall`), and the
test summary reports the previous example count plus two, `0 failures`, and the two
pre-existing pendings (the `pg_partman` live test and the transient-polling fault
injector). The `--match "retry ceiling"` filter now shows both examples with `[✔]`. Then:

```bash
nix fmt
git status --short
```

Expect only the files you edited to be listed. Write the two changelog entries and commit:

```bash
git add keiro-pgmq/src/Keiro/PGMQ/Job.hs keiro-pgmq/test/Main.hs keiro-pgmq/CHANGELOG.md CHANGELOG.md
git commit -m "fix(keiro-pgmq): apply the retry ceiling inside the worker-path process span

Move the read_ct > maxRetries check into wrapHandler, which shibuya's
supervised runner calls inside the per-message span, and disable the
adapter's own ceiling with maxRetries = maxBound. An exhausted delivery
now emits one Consumer span that continues the producer's trace and
records ack_dead_letter with status ERROR max_retries_exceeded. The
one-shot path shares the same helper. Queue behaviour is unchanged.

ExecPlan: docs/plans/301-trace-pre-handler-dead-letters-on-the-continuous-job-worker-to-fix-bug-7.md
Intention: intention_01m3t20zasen6se4xbnh3pg50m"
```

Milestone 2. Edit the user page, ADR-1, and the bug report as described; run the three
`okf log add` commands and the three validators. Each validator prints nothing on success
and exits 0; a non-zero exit with a field name means a frontmatter rule failed (for the
bug report, `fixed` without `fixedVersion` is the likely mistake). Commit:

```bash
git add docs/user docs/adr docs/bug-reports
git commit -m "docs: record the traced retry ceiling and close BUG-7

Document that the retry ceiling is keiro's check on both execution shapes
and runs inside the process span (Work Queues, ADR-1), and move BUG-7 to
fixed with fixedVersion unreleased.

ExecPlan: docs/plans/301-trace-pre-handler-dead-letters-on-the-continuous-job-worker-to-fix-bug-7.md
Intention: intention_01m3t20zasen6se4xbnh3pg50m"
```

Then run the release gate as shown in Milestone 2, record the `exit=` line in Progress,
write Outcomes & Retrospective, record the provenance revision entry, and commit the plan:

```bash
bun agents/skills/exec-plan/record-provenance.ts revision \
  --plan docs/plans/301-trace-pre-handler-dead-letters-on-the-continuous-job-worker-to-fix-bug-7.md \
  --model <your-model-id> --harness <your-harness> --mode implement \
  --note "Milestones 0-2 implemented; BUG-7 fixed"
```


## Validation and Acceptance

The change is accepted when all of the following hold on the implemented tree.

Running the focused filter passes both worker-path examples:

```bash
cabal test keiro-pgmq-test --test-show-details=direct --test-options='--match "retry ceiling"'
```

```text
Keiro.PGMQ
  worker-path retry ceiling dead letter emits one process span that continues the enqueued parent [✔]
  worker-path retry ceiling reached after a Retry traces both deliveries [✔]

Finished in N.NN seconds
2 examples, 0 failures
```

The first example is the observable statement of the fix: a job with `maxRetries = 0`
enqueued with a producer span, consumed by `runJobWorkers`, yields zero handler calls, one
DLQ wrapper with reason `max_retries_exceeded` and `readCount = 1`, an empty main queue,
and exactly one `<jobName> process` span that is Consumer-kind, shares the producer's trace
id, has the producer span as its parent, carries the four `messaging.*` attributes,
`shibuya.ack.decision=ack_dead_letter`, `shibuya.dead_letter.reason.code=max_retries_exceeded`,
and `shibuya.inflight.count`, and ends with status `ERROR "max_retries_exceeded"`. On the
tree before Milestone 1 the same example fails because no such span is exported.

The full suite passes with the previous example count plus two and zero failures, which
proves the queue-level behaviour of the ceiling, the one-shot path's tracing, FIFO
ordering, DLQ inspection, and redrive are all unchanged:

```bash
cabal test keiro-pgmq-test --test-show-details=direct
```

The three OKF validators exit 0 after the documentation, ADR, and bug-report edits, and
`just verify` completes with `exit=0` recorded in its log.

The bug report `docs/bug-reports/7-pre-handler-dead-letter-has-no-process-span.md` reads
`status: fixed`, `fixedVersion: unreleased`, and carries a `resolution`; the index table
row agrees.


## Idempotence and Recovery

Every step is additive or a plain edit and can be repeated. Re-running the test suite is
always safe: every example gets a fresh cloned database. If a run is interrupted, a stale
ephemeral PostgreSQL server may linger; `Keiro.Test.Postgres` starts a new one on the next
run and the old one exits with its parent.

If the Milestone 0 example passes on a tree that has not yet applied Milestone 1, stop:
either the adapter version in `dist-newstyle` differs from `^>=0.16.1.0` (check
`cabal build keiro-pgmq -v1 | grep shibuya-pgmq-adapter`) or the test is not exercising the
worker path. Do not weaken the assertions to make it red.

If `theProcessSpan` reports more than one span after Milestone 1, the ceiling is being
applied twice (for example the adapter's `maxRetries` was left at the policy value and the
handler check also fired on a redelivery). Diagnose rather than pick the first span; the
helper names every captured span in its failure message.

If `nix fmt` reformats files you did not touch, revert those hunks (`git checkout -- <file>`)
and format only the edited files; the gate runs formatting as part of `just verify` and
should not see unrelated churn.

If `just bug-reports-validate` rejects the report after Milestone 2, the usual causes are a
missing `fixedVersion`, a `resolution` that is not a scalar, or a `generated.at` that is
not a quoted ISO-8601 timestamp; compare against
`docs/bug-reports/1-write-side-workers-retain-heap-during-steady-soak.md`, which is a
closed report that validates.

If plan 300 has landed in the meantime, `adapterConfigFor` will already differ in its
`polling` line; apply this plan's `maxRetries` change on top and keep both. The two test
files' additions are in different examples and do not overlap.

To roll the fix back, restore `maxRetries = job.jobPolicy.maxRetries` in `adapterConfigFor`
and remove the guard from `wrapHandler`; the two new examples then fail again, which is the
intended signal.


## Interfaces and Dependencies

No public signature changes. The `keiro-pgmq` module `Keiro.PGMQ.Job` gains two private
helpers, both in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`:

```haskell
deliveryReadCount :: Maybe Attempt -> Int64
exceedsRetryCeiling :: Job p -> Int64 -> Bool
```

`wrapHandler :: Job p -> (JobContext es -> p -> Eff es JobOutcome) -> (Shibuya.Message es Value -> Eff es AckDecision)`
keeps its type and gains the ceiling guard. `adapterConfigFor :: JobTuning -> Job p -> PgmqAdapterConfig`
keeps its type and sets `maxRetries = maxBound`. `runJobOnceWithContext` keeps its type and
calls `exceedsRetryCeiling`.

The test module `keiro-pgmq/test/Main.hs` gains one helper and two examples:

```haskell
waitForProcessSpan :: IORef [ImmutableSpan] -> Text -> IO Bool
```

Dependencies used, all already in `keiro-pgmq.cabal` at their current bounds: `shibuya-core
^>=0.10.0.0` (`Shibuya.Core.Types.Attempt`, `Shibuya.Core.Ack.MaxRetriesExceeded`,
`Shibuya.Core.Ingested.Message`), `shibuya-pgmq-adapter ^>=0.16.1.0` (`PgmqAdapterConfig`,
whose `validateConfig` accepts `maxRetries = maxBound`), and in the test component
`hs-opentelemetry-exporter-in-memory`, `hs-opentelemetry-api`, `hs-opentelemetry-sdk`, and
`hspec` (for `shouldMatchList`). No dependency bound changes and no new package.

Source facts this plan relies on, verified on 2026-09-30: shibuya-pgmq-adapter 0.16.1.0
`Shibuya.Adapter.Pgmq.Internal.mkIngested` (source stream ceiling), `Convert.readCountToAttempt`
(`attempt = max 0 (read_ct - 1)`), `Config.validateConfig` (rejects only `maxRetries < 0`);
shibuya-core 0.10.0.0 `Shibuya.Internal.Runner.Supervised.processOne` (opens the span,
adds `shibuya.handler.started` before the handler, records `shibuya.dead_letter.reason.code`
and `Error (renderDeadLetterReason reason)` for `AckDeadLetter`);
`Shibuya.Core.Ack.renderDeadLetterReason MaxRetriesExceeded == "max_retries_exceeded"`.
Hackage lists 0.16.1.0 and 0.10.0.0 as the newest releases of those two packages.
