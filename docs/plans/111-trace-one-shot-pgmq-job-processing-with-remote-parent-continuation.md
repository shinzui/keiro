---
id: 111
slug: trace-one-shot-pgmq-job-processing-with-remote-parent-continuation
title: "Trace one-shot PGMQ job processing with remote parent continuation"
kind: exec-plan
created_at: 2026-07-15T02:27:03Z
intention: "intention_01kxgkp9dbe248pbd5yw1ftthh"
---

# Trace one-shot PGMQ job processing with remote parent continuation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-pgmq` has two ways to execute typed PostgreSQL Message Queue (PGMQ) jobs. The
continuous `runJobWorkers` path passes deliveries through Shibuya, which extracts an
upstream W3C `traceparent` header and creates a Consumer-kind `<job> process` span around
the handler and finalizer. The bounded `runJobOnceWithContext` path reads and finalizes
PGMQ rows directly. It preserves the trace header in `JobContext.headers`, but never
extracts that header as a parent and never creates the process span. Operators therefore
see enqueue, receive, and settlement spans with a hole where the domain job ran.

After this change, every message claimed by `runJobOnceWithContext` or its convenience
wrapper `runJobOnce` creates exactly one Consumer-kind process span. When the producer used
`enqueueTraced`, that span continues the producer's trace by using the W3C context stored in
the PGMQ JSONB headers. Its name and common attributes match the continuous Shibuya path,
and its acknowledgement attribute and status describe `Done`, retry, dead-letter, and
exception outcomes without changing any queue or redelivery behavior.

The behavior is demonstrated entirely inside this repository with the `keiro-pgmq-test`
suite. An in-memory OpenTelemetry exporter will prove that a traced enqueue and a later
one-shot drain share a trace, that the process span's parent is the producer span encoded
in the message, and that there is exactly one process span carrying the expected name,
kind, messaging attributes, and acknowledgement result.


## Progress

- [x] Milestone 1 (2026-07-22): added the in-memory tracing fixture to `keiro-pgmq-test`
  (`mkW3CProvider`, `setupCapturingProvider`, `capturedSpans`, `CapturedSpan`/`captureSpan`,
  `textAttr`, `spansNamed`, `runDbTraced`) plus the example
  "captured tracing fixture sees PGMQ publish and receive spans". Only the test component
  gained a dependency (`hs-opentelemetry-exporter-in-memory`); no production source changed.
  `cabal test keiro-pgmq-test` reported 51 examples, 0 failures, 2 pending.
- [x] Milestone 2 (2026-07-22): instrumented the direct one-shot processing boundary.
  `Keiro.PGMQ.Job` gained the private `withOneShotProcessSpan`, `recordAckOnSpan`,
  `ackDecisionText`, `deadLetterReasonText`, and `haltReasonText`; the drain now converts
  each raw message to an `Envelope` exactly once and threads that envelope plus the span
  through `processMessage`/`settle`/`contextFor`. No public signature changed. The example
  "one-shot process span continues the enqueued W3C parent" asserts cardinality, Consumer
  kind, shared trace id, remote parent span id, the four `messaging.*` attributes,
  `shibuya.ack.decision=ack_ok`, and status `OK`.
  `cabal test keiro-pgmq-test` reported 52 examples, 0 failures, 2 pending.
- [x] Milestone 3 (2026-07-22): added six branch-coverage examples — retry (`ack_retry`/`OK`
  plus a still-queued, still-hidden row), `Dead` (`ack_dead_letter`/`ERROR "poison_pill: bad"`),
  malformed payload (`ack_dead_letter`/`ERROR "invalid_payload: …"` with no
  `shibuya.handler.started` event), thrown handler (exception event, `ERROR`, no
  `shibuya.ack.decision`, row left for redelivery), a header-less message (still exactly one
  Consumer span), and a FIFO delivery (`shibuya.partition=g1`). `CapturedSpan` grew
  `csEventNames` and a `theProcessSpan` helper that fails loudly on any cardinality other
  than one. Module/`runJobWorkers`/`runJobOnce` Haddocks gained a Tracing section, and
  `keiro-pgmq/CHANGELOG.md` gained an `Unreleased` → `Fixed` entry.
  `cabal test keiro-pgmq-test` reported 58 examples, 0 failures, 2 pending.
- [x] Final validation (2026-07-22): `nix fmt` (no churn beyond the touched files),
  `cabal build keiro-pgmq`, `cabal test keiro-pgmq-test` (58/0/2), `just haskell-test`
  (`keiro-test` 335/0, `keiro-pgmq-test` 58/0/2, `jitsurei-test` 16/0, diagrams up to date),
  `cabal build all`, `git diff --check` clean. The module export list is byte-identical to
  the pre-change version and the only dependency change is test-only.
- [x] Out-of-plan repair (2026-07-22): `just haskell-test` failed on entry for a reason
  unrelated to this plan — see Surprises & Discoveries. Fixed in its own commit.


## Surprises & Discoveries

- Shibuya's `MessageId` newtype cannot be read with `OverloadedRecordDot`. `Shibuya.Core.Types`
  is compiled with `NoFieldSelectors`, and GHC 9.12 declines to solve the implied
  `HasField "unMessageId"` constraint, so `envelope.messageId.unMessageId` fails to compile:

  ```text
  src/Keiro/PGMQ/Job.hs:797:59: error: [GHC-39999]
      • Could not deduce ‘HasField "unMessageId" Shibuya.Core.Types.MessageId a0’
  ```

  Importing the field selector directly is also unavailable (`the module ‘Shibuya.Core.Types’
  does not export ‘unMessageId’ … suppressed by NoFieldSelectors`). Worse, importing the
  type unqualified would collide with `Pgmq.Effectful`'s own `MessageId`, which the producer
  signatures already use. The resolution is a narrow qualified import
  (`Shibuya.Core.Types qualified as ShibuyaTypes`) used only to pattern-match the
  constructor: `let ShibuyaTypes.MessageId messageIdText = envelope.messageId`.
  Date: 2026-07-22

- `just haskell-test` was already failing on `master` before any work in this plan, for an
  unrelated reason. Commit `9e81fff` ("align Keiro.version with the released package
  version") changed `keiro/src/Keiro.hs` to report `0.3.0.0` but left
  `keiro/test/Main.hs` asserting the old literal:

  ```text
  test/Main.hs:356:31:
  1) Keiro exposes the scaffold version
       expected: "0.1.0.0"
        but got: "0.3.0.0"
  ```

  Neither file is touched by this plan (`git diff --stat` over this plan's commits lists
  only `keiro-pgmq/*` and the plan itself). Because this plan's acceptance gate runs
  `just haskell-test`, the stale literal was corrected in a separate, clearly scoped commit
  rather than being worked around or silently tolerated.
  Date: 2026-07-22

- The captured-span assertions are a genuine regression test, not a tautology: before
  Milestone 2 the drain emitted no `<jobName> process` span at all, so every one of these
  examples would have failed at `theProcessSpan` with an empty match list.
  Date: 2026-07-22


## Decision Log

- Decision: Instrument the existing direct drain instead of implementing one-shot work by
  starting and immediately stopping a Shibuya application.
  Rationale: `runJobOnceWithContext` is deliberately a prompt bounded drain. It stops when
  the queue is empty, caps work at `n`, performs batch and FIFO reads directly, leaves a
  thrown-handler delivery invisible for visibility-timeout redelivery, and returns a
  handled count. `runApp` is a continuous supervised lifecycle with background ingestion,
  an inbox, concurrency, shutdown, and different handler-exception finalization. Routing
  the one-shot API through it would change behavior merely to obtain telemetry.
  Date: 2026-07-14

- Decision: Reuse Shibuya's public telemetry helpers and semantic constants, but do not
  import or copy its private `processOne` runner.
  Rationale: `Shibuya.Telemetry` already exposes `extractTraceContext`,
  `withExtractedContext`, `withSpan'`, `processSpanName`, `consumerSpanArgs`, attribute
  keys, events, exception recording, and status mutation. These are sufficient to make the
  shared observable surface agree. The private runner also owns continuous-only metrics,
  concurrency, halt state, and finalization retries that do not exist in a bounded drain.
  Date: 2026-07-14

- Decision: Match the continuous path only where the two execution models have the same
  meaning.
  Rationale: The one-shot span will use `<jobName> process`, Consumer kind,
  `messaging.system=shibuya`, `messaging.destination.name=<jobName>`,
  `messaging.operation.type=process`, `messaging.message.id`, optional
  `shibuya.partition`, and `shibuya.ack.decision`. It will not invent
  `shibuya.inflight.*` values because the direct drain has no Shibuya inbox or concurrency
  meter. PGMQ's existing `publish <queue>` and `receive <queue>` spans remain separate.
  Date: 2026-07-14

- Decision: Preserve direct-drain exception and acknowledgement semantics exactly.
  Rationale: A successful `Done` or retry finalization is status `OK`; a successful
  dead-letter finalization is status `ERROR`, matching Shibuya. A thrown domain handler is
  recorded as an exception and status `ERROR`, but it does not claim an `ack_retry`
  decision because the direct path intentionally makes no finalizer call and leaves the
  row invisible until its visibility timeout. The acknowledgement attribute is added only
  after `ackMessage` returns successfully.
  Date: 2026-07-14

- Decision: Keep every existing public type and function signature unchanged.
  Rationale: This is an observability repair. `runJobOnceWithContext`, `runJobOnce`,
  `JobContext`, `JobOutcome`, and `JobTuning` already carry everything required. The only
  new code should be private helpers and tests, so downstream applications gain trace
  continuity by rebuilding rather than by migrating source or persisted data.
  Date: 2026-07-14

- Decision: Read shibuya's `MessageId` through a narrowly qualified import
  (`Shibuya.Core.Types qualified as ShibuyaTypes`) used only to pattern-match the
  constructor, rather than importing `MessageId (..)` unqualified.
  Rationale: `Shibuya.Core.Types` is compiled with `NoFieldSelectors`, so neither
  `OverloadedRecordDot` nor a selector import can reach the wrapped `Text` (see Surprises &
  Discoveries). Importing the type unqualified would additionally shadow
  `Pgmq.Effectful`'s `MessageId`, which every producer signature in this module already
  returns. The qualified alias touches one line and leaves the producer signatures alone.
  Date: 2026-07-22

- Decision: `settle` performs `ackMessage` first and `recordAckOnSpan` second, rather than
  annotating the span with the intended decision up front.
  Rationale: The acknowledgement attribute must describe what actually happened. If a PGMQ
  statement throws, the exception propagates out of the span with no `shibuya.ack.decision`
  attached, which is the truthful reading. Annotating first would leave a span claiming an
  acknowledgement that the database never performed.
  Date: 2026-07-22

- Decision: Add a `theProcessSpan` test helper that fails when the match count is anything
  other than exactly one, and include every captured span name in the failure message.
  Rationale: The plan's Idempotence and Recovery section forbids weakening the cardinality
  check or selecting the first span. Encoding that rule in a helper makes it impossible for
  a later example to quietly take the head of a list, and the failure message points
  straight at a duplicated wrapper.
  Date: 2026-07-22

- Decision: Fix the unrelated stale `Keiro.version` assertion in `keiro/test/Main.hs` inside
  this plan's work, in a separate commit.
  Rationale: The plan's acceptance gate runs `just haskell-test`, which was red on entry for
  a reason this plan did not cause (see Surprises & Discoveries). Skipping the gate would
  hide real regressions; a one-line correction of a literal that a prior commit forgot is
  lower risk than leaving the suite red. Keeping it in its own commit with its own message
  keeps the plan's diff honest.
  Date: 2026-07-22


## Outcomes & Retrospective

The gap is closed. Every message claimed by `runJobOnce` or `runJobOnceWithContext` now runs
inside exactly one Consumer-kind `<jobName> process` span. When the producer used
`enqueueTraced`, that span is a direct child of the producer span encoded in the PGMQ JSONB
headers, proven by a test that attaches the producer context only for the enqueue and
detaches it before the drain — so the only path from producer to consumer is the stored
`traceparent`, not thread-local state.

What exists now that did not before, all inside `keiro-pgmq`:

- `Keiro.PGMQ.Job` gained five private helpers — `withOneShotProcessSpan`,
  `recordAckOnSpan`, `ackDecisionText`, `deadLetterReasonText`, `haltReasonText` — and the
  drain converts each raw PGMQ row to a shibuya `Envelope` exactly once, threading that
  envelope and the span through `processMessage`, `settle`, and `contextFor`.
- `keiro-pgmq/test/Main.hs` gained a reusable captured-span fixture (`mkW3CProvider`,
  `setupCapturingProvider`, `capturedSpans`, `CapturedSpan`/`captureSpan`, `textAttr`,
  `spansNamed`, `parentSpanContext`, `theProcessSpan`, `runDbTraced`) and seven examples: the
  fixture self-check, the central remote-parent proof, and five branch-coverage cases.
- The module, `runJobWorkers`, and `runJobOnce` Haddocks now describe the shared span
  surface and name the deliberate difference, and `CHANGELOG.md` carries the `Unreleased`
  entry.

The suite went from 51 to 58 examples with zero failures, and the two pre-existing pendings
(the `pg_partman` live test and the transient-polling fault injector) are untouched.

What did not change, verified rather than asserted: the module export list is byte-identical
to the pre-change version, no function signature moved, the only dependency edit is
`hs-opentelemetry-exporter-in-memory` in the test component, and no migration, PGMQ header
shape, or wire payload was touched. Every pre-existing drain behavior test — empty-queue
promptness, multi-message batches, `Done` deletion, retry hiding, thrown-handler
redelivery, max-retry and malformed dead-lettering, FIFO ordering, handled counts — passes
unchanged, and the whole `runDb` (no-tracer) suite passing is the standing proof that
disabled telemetry adds no required runtime setup.

Lessons worth carrying forward. First, proving the test fixture against spans that already
existed (Milestone 1) before writing any production code was worth the extra milestone: it
meant the Milestone 2 failure mode "the assertion is wrong" had already been ruled out, so
the first red run could only mean "the instrumentation is wrong". Second, ordering the
finalization before the span annotation is what makes the telemetry trustworthy under
failure, and that ordering is easy to reverse by accident during a later refactor — it is
now stated in both the code comment and the ADR. Third, the plan's instruction to diagnose
rather than weaken a cardinality failure was best honored by encoding it in a helper instead
of trusting future authors to remember it.

The durable half of this — why the two execution shapes are instrumented separately, and
what their spans are contractually required to agree on — is promoted to
[docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md),
which is the first ADR in this repository.


## Context and Orientation

Work from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. The package being
changed is `keiro-pgmq/`, currently version 0.3.0.0. Its public typed-job implementation is
`keiro-pgmq/src/Keiro/PGMQ/Job.hs`, its runtime interpreter is
`keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`, its Cabal file is
`keiro-pgmq/keiro-pgmq.cabal`, and its integration suite is
`keiro-pgmq/test/Main.hs`. `keiro-pgmq/src/Keiro/PGMQ.hs` re-exports the job module but
does not need to change because this plan adds no public API.

PGMQ is a queue implemented in PostgreSQL. Reading a row claims it by making it invisible
for a visibility timeout; deleting it acknowledges success; changing its visibility
timeout schedules a retry; and sending a wrapper to a second queue followed by deleting
the original implements dead-lettering. Delivery is at least once, meaning the handler must
tolerate the same row being delivered again after a crash or timeout.

OpenTelemetry represents one distributed operation as a trace made of parent/child spans.
A W3C `traceparent` header contains the upstream trace identifier and producer span
identifier. A remote-parent continuation means extracting that header at consumption time
and making the consumer span a child of the encoded producer span even when producer and
consumer ran in different processes. A Consumer-kind process span represents the domain
handling of a received message; it is distinct from the lower-level PGMQ receive span that
represents claiming the database row.

`Keiro.PGMQ.Job.enqueueTraced` already obtains the active OpenTelemetry context and writes
`traceparent` and optional `tracestate` into the PGMQ message's JSONB `headers` object.
`Shibuya.Adapter.Pgmq.Convert.pgmqMessageToEnvelope` converts a raw PGMQ message into a
Shibuya `Envelope Value` and projects those JSON values into `Envelope.traceContext`. This
conversion is available publicly from the `shibuya-pgmq-adapter` package.

The continuous path is already correct. `jobProcessorWithContext` constructs a Shibuya
processor using `pgmqMessageToEnvelope`; `runJobWorkers` starts it with
`Shibuya.App.runApp`. Shibuya's public source in the registered dependency at
`mori://shinzui/shibuya/repos/shibuya` shows that
`Shibuya.Internal.Runner.Supervised.processOne` extracts `Envelope.traceContext`, installs
it temporarily with `withExtractedContext`, and opens `processSpanName processorId` using
`consumerSpanArgs`. It records the message identity, acknowledgement decision, events,
exceptions, and final status. The relevant public support modules are
`Shibuya.Telemetry.Effect`, `Shibuya.Telemetry.Propagation`, and
`Shibuya.Telemetry.Semantic`, all re-exported by `Shibuya.Telemetry`.

The one-shot path is the gap. `runJobOnceWithContext` in `Keiro.PGMQ.Job` performs an
unordered or grouped PGMQ read, then its local `processMessage` function calls
`pgmqMessageToEnvelope` only to obtain the payload and attempt number. `contextFor` exposes
the original JSON headers to the handler, but no code calls `extractTraceContext`,
`withExtractedContext`, or `withSpan'`. The surrounding `runJobEff` runtime may therefore
emit `publish <queue>`, `receive <queue>`, delete/change-visibility, and DLQ spans through
the traced `pgmq-effectful` interpreter, but it emits no span for the job handler itself.

When this plan was written `docs/adr/` did not exist, so no ADR context applied. The
distillation pass at completion created the directory's first entry,
[docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md),
which records why the two execution shapes are instrumented separately and what their spans
are contractually required to agree on. Read that ADR before changing either path's
telemetry.

The behavior and hardening history are recorded in checked-in plans
`docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md` and
`docs/plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md`.
Plan 74 intentionally replaced the old one-shot adapter stream with the current direct
drain; plan 75 added header propagation and proved only that `JobContext.headers` contains
a `traceparent`. This plan completes that path without reversing either decision.

The test suite already uses `Keiro.Test.Postgres.withMigratedSuiteWith` to install the PGMQ
schema once and clone a fresh database per example. Its `runDb` helper creates a
`JobRuntime` with no tracer; add a traced sibling rather than changing every existing test.
The suite already depends on `hs-opentelemetry-api`,
`hs-opentelemetry-propagator-w3c`, and `hs-opentelemetry-sdk`, and its
`setupW3CProvider` helper creates real trace identifiers. The workspace's main Keiro test
suite demonstrates the repository convention for exported-span assertions with
`OpenTelemetry.Exporter.InMemory.Span.inMemoryListExporter` and `ImmutableSpan` capture.


## Plan of Work

### Milestone 1: establish a captured-span test fixture

Add `hs-opentelemetry-exporter-in-memory >=1.0 && <1.1` only to the
`keiro-pgmq-test` component in `keiro-pgmq/keiro-pgmq.cabal`. In
`keiro-pgmq/test/Main.hs`, replace or extend `setupW3CProvider` with a fixture that returns
the provider, tracer, and the in-memory exporter's span reference. Keep the W3C propagator
and `defaultIdGenerator`, because dummy identifiers cannot produce a valid `traceparent`.
Add `runDbTraced`, parallel to `runDb`, that passes `Just tracer` to `withJobRuntime` and
still fails the test on `PgmqRuntimeError`.

Prove the fixture before changing production code: enqueue and read a message under
`runDbTraced`, shut down the provider, and filter the exported spans to find the existing
`publish <physicalQueue>` and `receive <physicalQueue>` operations. This milestone is
accepted when the focused test captures those two spans, the rest of the suite remains
green, and no production source changed. It gives the later test a trustworthy way to
distinguish the new process span from PGMQ's existing operation spans.

### Milestone 2: instrument every direct one-shot delivery

Refactor the local functions under `runJobOnceWithContext` in
`keiro-pgmq/src/Keiro/PGMQ/Job.hs` so each raw PGMQ message is converted to an `Envelope`
once, then processed inside a private helper such as `withOneShotProcessSpan`. The helper
must:

1. Read `envelope.traceContext`, call Shibuya's public `extractTraceContext`, and install
   the result only for the dynamic scope of this delivery with `withExtractedContext`.
2. Open `processSpanName job.jobName` with `consumerSpanArgs` and `withSpan'`.
3. Add the same common attributes as the continuous path:
   `messaging.system=shibuya`, `messaging.destination.name=job.jobName`,
   `messaging.operation.type=process`, and the envelope's `messaging.message.id`. When the
   envelope has a FIFO partition/group, also add `shibuya.partition`.
4. Return the span handle to the existing decode, handler, and finalization branches so
   those branches can record their truthful result.

Keep all reads, handled-count accounting, `JobContext` construction, lease extension,
payload decoding, retry timing, DLQ writing, archive behavior, and FIFO ordering as they
are. Do not call `runApp`, import `Shibuya.Internal.*`, create a Shibuya inbox, or add
continuous-worker metrics to the direct drain.

Add small private functions that map `AckDecision` to the same text and status used by the
continuous runner. Add `shibuya.ack.decision` and a handler-completed event only after
`ackMessage` returns successfully. Use `OK` for `AckOk` and `AckRetry`, and `ERROR` with a
useful reason for `AckDeadLetter` and `AckHalt`. Add the handler-started event only when a
decoded payload is about to enter the domain handler. If the handler throws, retain the
existing `False` return and no-finalizer behavior, but call `recordException` and set the
span status to `ERROR`; do not fabricate an acknowledgement attribute.

Extend `keiro-pgmq/test/Main.hs` with the central end-to-end example. Create and attach an
explicit producer span, call `enqueueTraced`, detach the producer context, end that span,
and then drain in a separate `runDbTraced` action. After provider shutdown, filter for
`<jobName> process` and assert:

- exactly one matching span exists;
- its kind is `Consumer`;
- its trace identifier equals the producer span's trace identifier;
- its parent span identifier equals the producer span identifier;
- its common messaging attributes and `shibuya.ack.decision=ack_ok` are present; and
- its status is `OK`.

Detaching the producer context before the drain is essential: it proves the consumer got
its parent from the PGMQ header rather than accidentally inheriting thread-local state.
This milestone is accepted when that test passes and all pre-existing direct-drain behavior
tests still pass unchanged.

### Milestone 3: close branch coverage and documentation

Add focused exported-span examples for the branches whose telemetry meaning differs. A
retry outcome must report `ack_retry` with status `OK` and leave the row queued but hidden
for its configured delay. A `Dead` outcome or malformed payload that successfully reaches
the DLQ must report `ack_dead_letter` with status `ERROR`. A thrown handler must record an
exception, have status `ERROR`, omit `shibuya.ack.decision`, and leave the row for
visibility-timeout redelivery. A message without valid trace headers must still get one
process span, using Shibuya's normal local-context fallback. Existing tests executed through
`runDb` prove the no-tracer path remains a no-op with identical handled counts and queue
state; add a dedicated assertion only if the refactor makes that guarantee unclear.

Update the module and function Haddocks in `keiro-pgmq/src/Keiro/PGMQ/Job.hs` to state that
both execution shapes propagate W3C context and emit the same common process-span surface,
while only continuous workers expose Shibuya inbox/concurrency metrics. Add an `Unreleased`
entry to `keiro-pgmq/CHANGELOG.md` describing the repaired one-shot trace continuation and
explicitly saying that no public API or delivery semantics changed.

Run the formatter and full validation. Review the diff to ensure the only dependency change
is test-only, the package exposes no new module or function, and generated or migration
files did not change. Record the exact test counts and any implementation discoveries in
Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective before the
final commit.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`. Before editing, confirm the
dependency and working-tree baseline:

```bash
mori show --full
mori registry show shinzui/shibuya --full
mori registry show shinzui/shibuya-pgmq-adapter --full
mori registry show shinzui/pgmq-hs --full
git status --short
```

The repository must be clean apart from changes the implementer knowingly owns. Inspect the
current implementation and the public upstream helpers without searching `/nix/store`:

```bash
rg -n "runJobOnceWithContext|runJobWorkers|processMessage|wrapHandler" keiro-pgmq/src/Keiro/PGMQ/Job.hs
rg -n "processOne|withExtractedContext|processSpanName|consumerSpanArgs" \
  /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src
rg -n "pgmqMessageToEnvelope|extractTraceHeaders" \
  /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src
```

After Milestone 1, run the package test and confirm the in-memory exporter sees PGMQ's
existing operation spans. The exact Hspec example name may be refined during implementation,
but its observable output should resemble:

```bash
cabal test keiro-pgmq-test --test-show-details=direct
```

```text
captured tracing fixture sees PGMQ publish and receive spans: PASS
```

After Milestone 2, run the same command. The new central example should report success with
a name that states the cross-process relationship explicitly:

```text
one-shot process span continues the enqueued W3C parent: PASS
```

After Milestone 3, format and run the complete validation sequence:

```bash
nix fmt
cabal build keiro-pgmq
cabal test keiro-pgmq-test --test-show-details=direct
just haskell-test
cabal build all
git diff --check
git status --short
```

The focused suite must have zero failures and no pending example introduced by this plan.
`just haskell-test` must pass `keiro-test`, `keiro-pgmq-test`, `jitsurei-test`, and the
checked diagram generation. `cabal build all` must compile the full workspace. Formatting
may change the touched Haskell/Cabal files but must not create unrelated churn.

Implementation commits use Conventional Commits and must carry both active trailers. A
representative final message is:

```text
fix(pgmq): continue traces through one-shot job processing

ExecPlan: docs/plans/111-trace-one-shot-pgmq-job-processing-with-remote-parent-continuation.md
Intention: intention_01kxgkp9dbe248pbd5yw1ftthh
```


## Validation and Acceptance

The plan is accepted only when behavior, not merely compilation, proves the gap is closed.
The main test must enqueue under an explicit producer span, remove that span from the local
thread before consumption, and then run `runJobOnceWithContext` with tracing enabled. The
captured `<jobName> process` span must be unique, Consumer-kind, in the producer's trace,
and directly parented to the producer span encoded in PGMQ headers. It must contain:

```text
messaging.system = shibuya
messaging.destination.name = <logical job name>
messaging.operation.type = process
messaging.message.id = <PGMQ message id>
shibuya.ack.decision = ack_ok
otel.status_code = OK
```

The focused outcome tests must additionally prove `ack_retry`/`OK`,
`ack_dead_letter`/`ERROR`, and thrown-handler exception/`ERROR` with no false acknowledgement.
A FIFO delivery must retain its `shibuya.partition` attribute if an existing grouped test can
be extended without duplicating expensive setup. A delivery with no valid trace header must
still emit exactly one local process span rather than skipping instrumentation.

Every existing one-shot queue assertion remains authoritative: empty queues return promptly;
batch sizes greater than one drain correctly; `Done` deletes; retry delays hide without
deleting; thrown handlers remain for timeout redelivery; max-retry and malformed messages
reach the DLQ; FIFO modes preserve their ordering behavior; and handled counts do not change.
The existing no-tracer `runDb` suite passing is the proof that disabled telemetry adds no
required runtime setup.

No new public symbol, changed function signature, database migration, PGMQ header shape, or
wire payload is accepted. The `Unreleased` changelog and Haddocks must describe the exact
observable addition and the deliberate absence of continuous-only inflight metrics.


## Idempotence and Recovery

This change is code, tests, and documentation only. It does not alter a migration, queue,
payload, header, or ledger, so there is no data rollback. `keiro-pgmq-test` starts a cached
ephemeral PostgreSQL server and gives each example a fresh cloned database; rerunning the
suite cannot contaminate a prior result. The in-memory exporter has no external collector
and is recreated per example.

If a trace assertion fails, first inspect all captured span names rather than weakening the
cardinality check. A duplicate `<jobName> process` span means the new wrapper overlaps
another processing boundary and must be fixed; it is not acceptable to select the first
span. If parenting fails, verify that the producer context was attached during
`enqueueTraced` and detached before the drain, then inspect the raw `JobContext.headers`
using the already-existing test before changing propagation code.

Formatting and all validation commands are safe to repeat. If implementation stops between
milestones, leave the Progress section split into completed and remaining work, preserve any
failing evidence in Surprises & Discoveries, and resume from the focused
`keiro-pgmq-test`. Do not modify dependency source repositories to make the Keiro test pass;
this plan intentionally uses their current public APIs.


## Interfaces and Dependencies

The public consumer interfaces remain exactly:

```haskell
runJobOnceWithContext ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    JobTuning ->
    Int ->
    Job p ->
    (JobContext es -> p -> Eff es JobOutcome) ->
    Eff es Int

runJobOnce ::
    (Pgmq :> es, IOE :> es, Tracing :> es) =>
    Int ->
    Job p ->
    (p -> Eff es JobOutcome) ->
    Eff es ()
```

Implementation helpers stay private to `Keiro.PGMQ.Job`. A suitable shape is a helper that
accepts the `Job`, already-converted `Envelope Value`, and a callback receiving the span,
plus a second helper that records a successfully finalized `AckDecision`. Exact private
names may change under Fourmolu, but no helper is exported.

Use the public `shibuya-core >=0.8.0.1 && <0.9` modules already available to the library:

- `Shibuya.Telemetry.Effect` for `Tracing`, `withExtractedContext`, `withSpan'`,
  `addAttribute`, `addEvent`, `recordException`, `setStatus`, and span/status types.
- `Shibuya.Telemetry.Propagation` for `extractTraceContext`.
- `Shibuya.Telemetry.Semantic` for `processSpanName`, `consumerSpanArgs`, the
  `messaging.*` and `shibuya.*` keys, and handler events.
- `Shibuya.Core.Types` for the envelope and textual message identifier already produced by
  `pgmqMessageToEnvelope`.

Use `Shibuya.Adapter.Pgmq.Convert.pgmqMessageToEnvelope` from
`shibuya-pgmq-adapter >=0.12 && <0.13` as the one conversion point for payload, attempt,
partition, message ID, and trace context. Do not depend on
`Shibuya.Adapter.Pgmq.Internal`; it is not exposed and would couple Keiro to adapter
implementation details.

The existing `pgmq-effectful >=0.4 && <0.5` traced interpreter continues to own database
operation spans such as `publish`, `receive`, delete, archive, visibility change, and DLQ
send. The new process span wraps domain processing and settlement but does not replace or
rename those spans.

The only dependency addition is
`hs-opentelemetry-exporter-in-memory >=1.0 && <1.1` in the test component. The test continues
to use its existing OpenTelemetry API, W3C propagator, and SDK dependencies. No new library
dependency is needed because `keiro-pgmq` already depends on `shibuya-core` and
`shibuya-pgmq-adapter`.


## Revision Notes

### 2026-07-22 — implementation complete

All three milestones and final validation are done; Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective are filled in from what actually happened rather
than from what was planned.

Three things diverged from the plan as written and are recorded above rather than silently
absorbed. Reading shibuya's `MessageId` needed a narrowly qualified import because
`Shibuya.Core.Types` is compiled with `NoFieldSelectors` and its type name collides with
`Pgmq.Effectful`'s. `just haskell-test` was already red on entry for an unrelated stale
assertion in `keiro/test/Main.hs`, which was corrected in its own commit so this plan's
acceptance gate could actually run. And the Context and Orientation section, which
originally noted that no ADR directory existed, now points at the ADR the completion pass
created.

The plan's substance did not change: no public API, signature, migration, PGMQ header shape,
or wire payload was touched, and the module export list is byte-identical to the pre-change
version.
