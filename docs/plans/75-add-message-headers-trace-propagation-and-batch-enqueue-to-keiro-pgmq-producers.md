---
id: 75
slug: add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers
title: "Add message headers, trace propagation, and batch enqueue to keiro-pgmq producers"
kind: exec-plan
created_at: 2026-06-13T14:29:36Z
intention: "intention_01kv0jvq2qe70reyz4f6dpfxnk"
master_plan: "docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md"
---

# Add message headers, trace propagation, and batch enqueue to keiro-pgmq producers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-pgmq` (the Haskell package whose source lives under `keiro-pgmq/` in this
repository) is a typed background-job queue. An application declares a `Job p` value — a
queue, a way to encode/decode the payload `p`, and a retry/dead-letter policy — and writes
a plain handler `p -> Eff es JobOutcome`. The package puts that work onto PGMQ (PGMQ is the
PostgreSQL-native message queue: a Postgres extension that stores each queue as a table and
hands out messages with a per-message visibility timeout) and runs the handler against it.

Today the producers `enqueue` and `enqueueWithDelay` (in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`)
send a message body and nothing else. They attach **no message headers**. A "message header"
in PGMQ is a JSON object stored alongside the body in the queue table's `headers` column
(JSONB) — arbitrary metadata the producer chooses and the consumer can read. Because keiro
producers never set headers, a keiro application currently cannot: attach application
metadata to a job; propagate a distributed-tracing context from the code that enqueues a job
to the code that handles it (so that a trace started in the web request that enqueued the job
continues into the worker that runs it); or enqueue many jobs in a single database round-trip
instead of one statement per job.

After this change, a keiro application can do all three. Concretely, a developer will be able
to write `enqueueWithHeaders job (MessageHeaders (object ["tenant" .= tenantId])) payload`
to stamp metadata onto a job; call `enqueueTraced provider job extraHeaders payload` to inject
the current W3C `traceparent` (the standard textual encoding of "which trace and span am I
inside", defined by the W3C Trace Context specification — it looks like
`00-<32 hex trace id>-<16 hex span id>-01`) so the handler runs inside the same trace; and
call `enqueueBatch job [p1, p2, p3]` to enqueue three payloads in one round-trip. A handler
will also be able to read the headers that were attached, through a new
`headers :: Maybe Value` field on the per-delivery `JobContext` value the package hands to
context-aware handlers.

You can see it working by running the package's behavioral test suite from the repository
root `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-pgmq-test
```

The suite gains new examples that enqueue with a header and then read the raw PGMQ message
back to prove the header is on the wire; that enqueue a batch and prove the queue depth and
the count of returned message ids both equal the batch size; and that set a `traceparent` at
enqueue time and prove the same `traceparent` is visible to the drain-path handler through
`JobContext.headers`. When those examples pass, the capability is demonstrably real rather
than merely compiled.

This plan is **EP-1** of the MasterPlan
`docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md`.
That initiative expands keiro-pgmq's queue features (FIFO ordering, headers, provisioning,
observability) across four exec-plans. EP-1 owns the producer (send) side and the
handler-visible-header read side. A later sibling plan,
`docs/plans/77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md` (**EP-3**),
builds strict per-key ordering on top of EP-1's header-carrying enqueue by setting a reserved
header key named `x-pgmq-group`. EP-1 therefore must ship a header API that EP-3 can layer on
without re-deriving header plumbing, and must never reserve, strip, or rewrite the
`x-pgmq-group` key. That contract is stated precisely in Interfaces and Dependencies.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `enqueueWithHeaders` and `enqueueWithHeadersAndDelay` to `keiro-pgmq/src/Keiro/PGMQ/Job.hs` over `Pgmq.sendMessageWithHeaders`. (2026-06-13)
- [x] M1: Add `MessageHeaders` (and the `Value`-building helpers the tests need) to the `Keiro.PGMQ.Job` export list and confirm the umbrella re-exports it. (2026-06-13)
- [x] M1: Add the `keiro-pgmq-test` examples `enqueueWithHeaders attaches a header readable on the raw PGMQ message` and `enqueueWithHeaders leaves the x-pgmq-group key untouched`. (2026-06-13)
- [x] M1: `cabal test keiro-pgmq-test` is green with the two M1 examples added. (2026-06-13)
- [x] M2: Add `enqueueBatch`, `enqueueBatchWithDelay`, and `enqueueBatchWithHeaders` to `keiro-pgmq/src/Keiro/PGMQ/Job.hs` over `Pgmq.batchSendMessage` / `Pgmq.batchSendMessageWithHeaders`. (2026-06-13)
- [x] M2: Add the `keiro-pgmq-test` examples `enqueueBatch of three payloads yields three ids and queue depth three` and `enqueueBatchWithHeaders attaches per-message headers`. (2026-06-13)
- [x] M2: `cabal test keiro-pgmq-test` is green with the M2 examples added. (2026-06-13)
- [x] M3: Add the `headers :: Maybe Value` field to `JobContext` and populate it on the drain path (`runJobOnceWithContext`) and the worker path (`wrapHandler`). (2026-06-13)
- [x] M3: Add `enqueueTraced` (and `enqueueTracedWithDelay`) injecting the current trace context via the pgmq-effectful Telemetry helpers. (2026-06-13)
- [x] M3: Add the `keiro-pgmq-test` examples `drain-path JobContext exposes the enqueued headers` and `a traceparent set at enqueue is visible to the drain-path handler`. (2026-06-13)
- [x] M3: `cabal test keiro-pgmq-test` is green with all milestones' examples added. (2026-06-13)
- [x] Final: Fill Outcomes & Retrospective; reconcile MasterPlan #10 Progress checkboxes for EP-1's three rows. (2026-06-13)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-13 — **The M3 `traceparent` test needed no fallback; the genuine W3C round-trip
  works.** The plan anticipated that a no-op global tracer provider might emit no
  `traceparent`, requiring a fallback to merely asserting additive-merge behavior. Instead I
  built a real provider in the test (`setupW3CProvider`) mirroring `pgmq-effectful`'s own
  `TracedInterpreterSpec`: `OTel.createTracerProvider []` with
  `tracerProviderOptionsIdGenerator = defaultIdGenerator` and
  `tracerProviderOptionsPropagators = W3C.w3cTraceContextPropagator`, then created a parent
  span and `CtxtLocal.attachContext`-ed it before the enqueue. `enqueueTraced`'s internal
  `getContext` picks up that thread-local span on the same thread, and the example
  `"a traceparent set at enqueue is visible to the drain-path handler"` observes a real
  `traceparent` string in the drained handler's `ctx.headers`. Evidence: `cabal test
  keiro-pgmq-test` → 37 examples, 0 failures, 1 pending.
- 2026-06-13 — **The trace test required three new test-only build-deps**, not just the
  `hs-opentelemetry-api` the plan named for the library. To stand up a real W3C provider the
  test component (`keiro-pgmq.cabal`'s `keiro-pgmq-test`) gained
  `hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`, and `hs-opentelemetry-sdk`
  (`defaultIdGenerator` lives in the SDK; the W3C propagator in its own package). All three
  are already used elsewhere in the workspace (`keiro.cabal`, `pgmq-effectful`'s suite), so
  resolution was free. The *library* still needs no new dependency, as the plan stated.


## Decision Log

Record every decision made while working on the plan.

- Decision: Name the header-carrying producer `enqueueWithHeaders :: (Pgmq :> es, IOE :> es)
  => Job p -> MessageHeaders -> p -> Eff es MessageId`, with a delayed sibling
  `enqueueWithHeadersAndDelay :: (Pgmq :> es, IOE :> es) => Job p -> Int32 -> MessageHeaders
  -> p -> Eff es MessageId`. The `MessageHeaders` argument sits between the `Job` and the
  payload `p` so the payload stays last (matching `enqueue`/`enqueueWithDelay`, whose payload
  is last) and so a partial application `enqueueWithHeaders job hdrs` reads naturally.
  Rationale: This is **Integration Point 2** of MasterPlan #10. EP-3
  (`docs/plans/77-…`) builds `enqueueToGroup job groupKey p = enqueueWithHeaders job
  (groupHeader groupKey) p`, so the shape `Job -> MessageHeaders -> p -> Eff es MessageId`
  must be stable. `MessageHeaders` is the existing `newtype MessageHeaders {unMessageHeaders
  :: Value}` from `pgmq-core` (re-exported by `pgmq-effectful` as `Pgmq.Effectful
  (MessageHeaders (..))`); reusing it avoids inventing a parallel header type. The `IOE :> es`
  constraint is redundant for the send itself but is kept to match the existing producer
  contract (`enqueue` already carries and documents this exact redundant constraint, silenced
  with `-Wno-redundant-constraints` at the top of `Job.hs`).
  Date: 2026-06-13

- Decision: Reuse the pgmq-effectful Telemetry helpers for trace propagation rather than
  reimplementing W3C injection. EP-1's `enqueueTraced` fetches the thread-local OpenTelemetry
  context, injects it to carrier headers with `injectTraceContext`, merges those onto any
  caller-supplied headers with `mergeTraceHeaders` (user keys win), and sends via
  `enqueueWithHeaders`.
  Rationale: `pgmq-effectful` already ships `injectTraceContext`, `extractTraceContext`,
  `mergeTraceHeaders`, and `TraceHeaders` (module `Pgmq.Effectful.Telemetry`, re-exported
  from the `Pgmq.Effectful` umbrella) and uses exactly this pattern in its own
  `sendMessageTraced` (`Pgmq.Effectful.Traced`). keiro-pgmq already depends on
  `hs-opentelemetry-api`, so no new build-dep is required. Reimplementing W3C string handling
  would duplicate code and risk drifting from whatever propagator the provider is configured
  with (W3C by default, but B3/Datadog are supported transparently). `enqueueTraced` takes the
  `TracerProvider` explicitly (it does not call `getGlobalTracerProvider` internally) to match
  `sendMessageTraced`'s shape and to keep the function testable with an explicit provider.
  Date: 2026-06-13

- Decision: Provide handler-visible headers on the **drain path** in full, and document the
  **worker path** as carrying trace context but not arbitrary headers.
  Rationale: Reading
  `shibuya-pgmq-adapter`'s `Shibuya.Adapter.Pgmq.Convert.pgmqMessageToEnvelope`
  (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs`,
  lines 110–122) shows it sets the shibuya `Envelope`'s `headers` field to `Nothing`
  deliberately — pgmq's JSONB header object is unordered, so the adapter does not re-present
  it as the ordered, duplicate-allowing broker-`Headers` type. It does, however, project the
  W3C trace context out of the same JSONB headers into `Envelope.traceContext`
  (`extractTraceHeaders`, line 117), and shibuya's framework re-establishes the parent span
  from `traceContext`. So on the worker path, distributed tracing already works end-to-end
  (the handler runs inside the producer's trace) but arbitrary header bytes are not surfaced
  on the `Envelope`. The drain path (`runJobOnceWithContext` in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`)
  reads the raw `Pgmq.Message` and has `message.headers :: Maybe Value` directly, so full
  header access is straightforward there. EP-1 therefore populates `JobContext.headers` with
  the raw `Just headers` on the drain path and with `Nothing` on the worker path, and the
  Haddock on the field states this asymmetry plainly. Inventing a shibuya capability that does
  not exist (surfacing arbitrary headers on the worker `Envelope`) is out of scope and would
  require patching a separate repository.
  Date: 2026-06-13

- Decision: EP-1's header API leaves the reserved key `x-pgmq-group` completely untouched —
  it never reserves the name, never injects it, and never strips or rewrites it.
  Rationale: `x-pgmq-group` is the FIFO group key. PGMQ's grouped reads and the shibuya
  adapter (`Convert.extractPartition`, which looks up exactly `"x-pgmq-group"`) consume it,
  and EP-3 (`docs/plans/77-…`) sets it through EP-1's `enqueueWithHeaders`. If EP-1 mangled or
  reserved the key, EP-3 could not express a group. `enqueueWithHeaders` therefore passes the
  caller's `MessageHeaders` through verbatim; `enqueueTraced`'s only mutation of headers is an
  additive merge of trace keys with `mergeTraceHeaders`, which preserves all existing keys
  (user keys win), so it too leaves `x-pgmq-group` intact. This is **Integration Point 2**'s
  no-reserve contract.
  Date: 2026-06-13

- Decision: Add the batch producers `enqueueBatch :: Job p -> [p] -> Eff es [MessageId]`,
  `enqueueBatchWithDelay :: Job p -> Int32 -> [p] -> Eff es [MessageId]`, and
  `enqueueBatchWithHeaders :: Job p -> [(MessageHeaders, p)] -> Eff es [MessageId]`.
  Rationale: `pgmq-effectful` exposes `batchSendMessage` (one `delay` for the whole batch,
  bodies as `[MessageBody]`) and `batchSendMessageWithHeaders` (bodies plus a parallel
  `[MessageHeaders]`, one header object per body, one shared `delay`). `enqueueBatch` and
  `enqueueBatchWithDelay` map onto `BatchSendMessage`; `enqueueBatchWithHeaders` takes a list
  of `(MessageHeaders, p)` pairs (rather than two parallel lists) so a caller cannot
  accidentally desynchronize the header list from the body list, and unzips them into the
  parallel `[MessageBody]`/`[MessageHeaders]` that `BatchSendMessageWithHeaders` wants. Each
  payload is encoded with the job's codec via `encodeJob job.jobCodec`. An empty input list is
  handled by short-circuiting to `pure []` so we never issue a zero-row batch statement.
  Date: 2026-06-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

All three milestones are complete and the capability is proven behaviorally. A keiro
application can now: stamp arbitrary metadata onto a job with `enqueueWithHeaders` /
`enqueueWithHeadersAndDelay`; enqueue many payloads in one round-trip with `enqueueBatch` /
`enqueueBatchWithDelay` / `enqueueBatchWithHeaders`; propagate the current OpenTelemetry trace
into a job with `enqueueTraced` / `enqueueTracedWithDelay`; and read the attached headers in a
context-aware handler via the new `JobContext.headers :: Maybe Value` field. All new public
surface lives in `Keiro.PGMQ.Job` (with `MessageHeaders (..)` newly re-exported) and is
reachable through the `Keiro.PGMQ` umbrella with no umbrella edit.

The work matched the plan almost exactly. Every upstream API the plan named existed as
described (`SendMessageWithHeaders`, `BatchSendMessage`, `BatchSendMessageWithHeaders`,
`injectTraceContext`, `mergeTraceHeaders`, all re-exported from the `Pgmq.Effectful`
umbrella; `Delay = Int32`). The single `JobContext` breaking change was absorbed at its two
in-repo `contextFor` sites with no fallout (the worker-path examples still pass with
`headers = Nothing`). The only deviation from the plan was upward: the M3 `traceparent` test
is the genuine round-trip rather than the anticipated additive-merge fallback (see Surprises),
at the cost of three test-only OpenTelemetry build-deps. Six new examples; final suite is 37
examples, 0 failures, 1 pending (the pre-existing `#67`-blocked example).

The EP-3 contract is satisfied: `enqueueWithHeaders :: Job p -> MessageHeaders -> p -> Eff es
MessageId` ships with the agreed argument order, and the `x-pgmq-group` key passes through
verbatim — proven by `"enqueueWithHeaders leaves the x-pgmq-group key untouched"`.


## Context and Orientation

This section assumes you know nothing about this repository. Read it before editing.

The package you are changing lives under `keiro-pgmq/` in the repository rooted at
`/Users/shinzui/Keikaku/bokuno/keiro`. Its Cabal file is `keiro-pgmq/keiro-pgmq.cabal`; it
declares one library and one test component, `keiro-pgmq-test` (test driver
`keiro-pgmq/test/Main.hs`). All commands in this plan are run from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro` unless stated otherwise.

The library has five modules. `keiro-pgmq/src/Keiro/PGMQ.hs` is the umbrella module: it
re-exports the whole public surface with `module Keiro.PGMQ.Job` (and the other three
modules), so anything you add to a sub-module's export list is automatically available to a
consumer who writes `import Keiro.PGMQ`. You will **not** need to edit the umbrella in this
plan, because all new functions and the new `JobContext` field live in `Keiro.PGMQ.Job`,
which the umbrella already re-exports in full. `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs` holds
the transport-agnostic runtime and `QueueRef`. `keiro-pgmq/src/Keiro/PGMQ/Codec.hs` holds the
payload codecs. `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` holds dead-letter-queue inspection.
`keiro-pgmq/src/Keiro/PGMQ/Job.hs` is the file you edit the most: it defines `Job`,
`JobContext`, the producers, and the consumers.

A few terms of art, defined in plain language and tied to where they appear:

"PGMQ" is the PostgreSQL message-queue extension. A queue is a table; sending a message
inserts a row; reading takes the oldest unclaimed row and hides it for a visibility-timeout
window. keiro talks to PGMQ through the `pgmq-effectful` library, whose source is at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful`.

"`Pgmq` effect" is an `effectful` capability (`effectful` is a Haskell effect-system library;
an effect `E :> es` is a capability available in the effect row `es`). The functions you call
on it — `Pgmq.sendMessage`, `Pgmq.sendMessageWithHeaders`, `Pgmq.batchSendMessage`,
`Pgmq.batchSendMessageWithHeaders`, `Pgmq.readMessage` — are defined in
`Pgmq.Effectful.Effect` and re-exported from the `Pgmq.Effectful` umbrella module. keiro
imports them as `import "pgmq-effectful" Pgmq.Effectful qualified as Pgmq` and the request
record types unqualified from `Pgmq.Effectful` (see the existing import block at the top of
`keiro-pgmq/src/Keiro/PGMQ/Job.hs`, lines 87–99).

"Message headers" in PGMQ are a JSON object stored in the queue row's `headers` column. The
wire type is `MessageHeaders`, defined in `pgmq-core` as `newtype MessageHeaders
{unMessageHeaders :: Value}` (an aeson `Value`, i.e. arbitrary JSON), and re-exported by
`pgmq-effectful` as `Pgmq.Effectful (MessageHeaders (..))`. The send request that carries
headers is `SendMessageWithHeaders { queueName, messageBody, messageHeaders, delay }`. keiro
**already imports both** of these in `Job.hs` (lines 91 and 96) because the dead-letter path
(`sendDlq`, lines 518–536) already calls `Pgmq.sendMessageWithHeaders` to *preserve* a
message's headers onto the DLQ. So the wire-level support EP-1 needs is already a build-dep
and already imported; EP-1 exposes it on the *producer* side.

"`Job p`" is the declarative job record in `Job.hs` (lines 254–260): `Job { jobName :: Text,
jobQueue :: QueueRef, jobCodec :: JobCodec p, jobPolicy :: RetryPolicy }`. "`QueueRef`" (in
`Runtime.hs`) is `QueueRef { logicalName, physicalName :: QueueName, dlqName :: QueueName }`.
**You must not change the fields of `Job` or `QueueRef`** — MasterPlan #10's Integration Point
4 freezes them so all four exec-plans stay independent. EP-1 only *reads* them (it uses
`job.jobQueue.physicalName` and `job.jobCodec`).

"`encodeJob` / `decodeJob`" come from `keiro-pgmq/src/Keiro/PGMQ/Codec.hs`: `encodeJob
job.jobCodec p :: Value` turns a payload into JSON for the body, and `decodeJob` reverses it.
Producers use `encodeJob`; consumers use `decodeJob`. `MessageBody` (from `pgmq-effectful`)
wraps the body `Value`, exactly as the existing `enqueue` does: `MessageBody (encodeJob
job.jobCodec p)`.

"`JobContext es`" (lines 263–268) is the per-delivery capability bundle handed to
context-aware handlers (handlers of type `JobContext es -> p -> Eff es JobOutcome`). Today it
has two fields: `extendLease :: NominalDiffTime -> Eff es ()` (push the visibility timeout
further out) and `attempt :: Maybe Word` (zero-based delivery count). EP-1 adds a third field,
`headers :: Maybe Value`. `JobContext` is constructed in exactly two places, both inside
`Job.hs`: in `wrapHandler` (the worker path, `contextFor`, line 335) and in
`runJobOnceWithContext` (the drain path, `contextFor`, line 461). A repository-wide search
(`grep -rn "JobContext" --include="*.hs" .`) confirms there are no construction sites outside
`Job.hs`, so adding a field is a self-contained breaking change EP-1 fully absorbs by updating
those two `contextFor` helpers.

"Drain path vs. worker path." The package runs jobs two ways. The **worker path** is the
continuous, supervised run through shibuya (`jobProcessorWithContext` builds a shibuya
processor; the handler receives an `Ingested es Value`, whose `envelope` is built by the
shibuya adapter's `pgmqMessageToEnvelope`). The **drain path** is the one-shot
`runJobOnceWithContext`, which reads directly with `Pgmq.readMessage` and holds the raw
`Pgmq.Message` (with `message.headers :: Maybe Value`) in hand. This distinction matters for
EP-1's header readability (see the Decision Log and M3): the drain path can expose full
headers; the worker path's `Envelope` deliberately carries only trace context, not arbitrary
headers (the adapter sets `Envelope.headers = Nothing`).

"W3C `traceparent` / trace context propagation." OpenTelemetry (an observability standard)
represents the current trace and span as a small set of headers; the W3C Trace Context
standard names the primary one `traceparent`. Propagating it from producer to consumer means
writing it into the message at enqueue and reading it back at dequeue so both halves of the
work appear under one trace. `pgmq-effectful`'s `Pgmq.Effectful.Telemetry` module
(`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful/Telemetry.hs`)
provides `injectTraceContext :: MonadIO m => TracerProvider -> Context -> m TraceHeaders`
(writes the current context to carrier headers), `mergeTraceHeaders :: TraceHeaders -> Maybe
Value -> Value` (additively folds those carrier headers into an existing JSON headers object,
existing keys winning), and `TraceHeaders` (the carrier type). A `TracerProvider` is the
OpenTelemetry object that owns the configured propagator; the global one is obtained with
`getGlobalTracerProvider :: MonadIO m => m TracerProvider` from `OpenTelemetry.Trace.Core`
(in the already-depended-on `hs-opentelemetry-api`). The "current context" is fetched with
`OpenTelemetry.Context.ThreadLocal.getContext`. This is exactly the recipe `pgmq-effectful`'s
own `sendMessageTraced` uses (`Pgmq.Effectful.Traced`, lines 70–87); EP-1's `enqueueTraced`
mirrors it but encodes the job payload and goes through `enqueueWithHeaders`.

"The test harness." `keiro-pgmq/test/Main.hs` is an hspec suite. Its `main` starts one
suite-level PostgreSQL server, installs the PGMQ schema into a migrated template database
(`Postgres.withMigratedSuiteWith installPgmq`), then gives every example a fresh cloned
database (`around (Postgres.withFreshDatabase fixture)`); each example receives that database's
connection string. The helper `runDb connStr act` runs an `Eff Stack a` action against the
fresh database, where `type Stack = '[Pgmq, Tracing, Error PgmqRuntimeError, IOE]`. Existing
examples enqueue with `enqueue`, drain with `runJobOnce`, and inspect the queue with
`Pgmq.queueMetrics` (the helper `queueLen` returns `metrics.queueLength`) or by reading
messages directly with `Pgmq.readMessage`. New examples follow the same style. The `Tracing`
effect in the stack is shibuya's `Shibuya.Telemetry.Effect.Tracing`; `runDb` runs it in
no-op mode (the runtime has no tracer), which is fine for EP-1's tests because `enqueueTraced`
takes a `TracerProvider` explicitly and the trace test reads the resulting header off the raw
message rather than depending on the `Tracing` effect.


## Plan of Work

The work is three milestones, each independently verifiable by a single
`cabal test keiro-pgmq-test` run from `/Users/shinzui/Keikaku/bokuno/keiro` and each adding
named behavioral examples. All edits are additive: existing functions and signatures are left
intact, with the single exception of adding one field to `JobContext` in M3, which is a
breaking change EP-1 fully absorbs at its two in-repo construction sites.

### Milestone M1 — header-carrying enqueue and the reserved-key contract

Scope: expose the ability to attach message headers to an enqueued job. At the end of M1, a
caller can write `enqueueWithHeaders job (MessageHeaders (object ["k" .= v])) payload` and the
header is on the wire, readable by reading the raw PGMQ message back. A delayed variant exists.
The reserved FIFO key `x-pgmq-group` passes through verbatim.

Work: In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, immediately after the existing `enqueueWithDelay`
(which ends near line 290), add two producers. `enqueueWithHeaders job hdrs p` calls
`Pgmq.sendMessageWithHeaders SendMessageWithHeaders { queueName = job.jobQueue.physicalName,
messageBody = MessageBody (encodeJob job.jobCodec p), messageHeaders = hdrs, delay = Nothing }`.
`enqueueWithHeadersAndDelay job d hdrs p` is identical but with `delay = Just d`. Both carry
the constraint `(Pgmq :> es, IOE :> es)` and return `Eff es MessageId`. `SendMessageWithHeaders`,
`MessageBody`, and `MessageHeaders` are already imported in the file's import block (lines 91,
93, 96), so no import changes are needed for the producers themselves.

Add `enqueue`'s two new siblings to the module export list under the "Producing work" heading
(currently lines 63–65: `enqueue, enqueueWithDelay,`). Also add `MessageHeaders (..)` to the
export list so a consumer who writes `import Keiro.PGMQ` gets the header type without importing
`pgmq-effectful` directly. Add it under a new export comment, for example
`-- * Message metadata` followed by `MessageHeaders (..),`. To re-export the constructor from
this module you re-export the already-imported name; because the import is
`Pgmq.Effectful (... MessageHeaders (..) ...)`, listing `MessageHeaders (..)` in this module's
export list re-exports it.

Tests: add two examples to `keiro-pgmq/test/Main.hs`'s `spec`. The example
`"enqueueWithHeaders attaches a header readable on the raw PGMQ message"` ensures the queue,
calls `enqueueWithHeaders job (MessageHeaders (object ["tenant" .= ("acme" :: Text)])) (Ping
"hdr" 1)`, then reads the message back with `Pgmq.readMessage` (mirroring the existing
`readOneIsEmpty` helper but returning the message) and asserts the returned `message.headers`
is `Just v` where `v` contains `"tenant" -> "acme"`. The example
`"enqueueWithHeaders leaves the x-pgmq-group key untouched"` enqueues with
`MessageHeaders (object ["x-pgmq-group" .= ("g1" :: Text)])`, reads the message back, and
asserts `message.headers` round-trips the exact key `"x-pgmq-group"` with value `"g1"` (proving
EP-1 does not strip or rename it — the contract EP-3 relies on).

Acceptance: from `/Users/shinzui/Keikaku/bokuno/keiro`, run `cabal test keiro-pgmq-test`. Both
new examples pass; no existing example regresses.

### Milestone M2 — batch enqueue

Scope: enqueue many payloads in a single database round-trip. At the end of M2,
`enqueueBatch job [p1, p2, p3]` returns three `MessageId`s and leaves queue depth three; a
delayed and a with-headers batch variant exist.

Work: In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, after the M1 producers, add three functions.
`enqueueBatch job ps`, short-circuiting `[] -> pure []`, otherwise calls
`Pgmq.batchSendMessage BatchSendMessage { queueName = job.jobQueue.physicalName, messageBodies
= map (MessageBody . encodeJob job.jobCodec) ps, delay = Nothing }`. `enqueueBatchWithDelay job
d ps` is identical with `delay = Just d`. `enqueueBatchWithHeaders job pairs`, short-circuiting
`[] -> pure []`, unzips the `[(MessageHeaders, p)]` into a parallel header list and body list
and calls `Pgmq.batchSendMessageWithHeaders BatchSendMessageWithHeaders { queueName =
job.jobQueue.physicalName, messageBodies = map (MessageBody . encodeJob job.jobCodec . snd)
pairs, messageHeaders = map fst pairs, delay = Nothing }`. All three carry `(Pgmq :> es, IOE :>
es)` and return `Eff es [MessageId]`. Add the imports `BatchSendMessage (..)` and
`BatchSendMessageWithHeaders (..)` to the existing `Pgmq.Effectful (...)` import block (they are
re-exported from the umbrella — confirmed by reading
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful.hs`,
which re-exports both). Add the three names to the module's "Producing work" export section.

Tests: add two examples. `"enqueueBatch of three payloads yields three ids and queue depth
three"` ensures the queue, calls `ids <- enqueueBatch job [Ping "a" 1, Ping "b" 2, Ping "c"
3]`, asserts `length ids == 3`, and asserts `queueLen job.jobQueue.physicalName == 3`.
`"enqueueBatchWithHeaders attaches per-message headers"` enqueues a two-element batch with
distinct headers (e.g. `[(MessageHeaders (object ["i" .= (1 :: Int)]), Ping "a" 1),
(MessageHeaders (object ["i" .= (2 :: Int)]), Ping "b" 2)]`), drains both, and asserts the
headers seen match — most simply by reading both raw messages back and checking each carries
its `"i"` value. (Reading the two messages requires a small helper that reads up to two
messages; you can reuse `Pgmq.readMessage` with `batchSize = Just 2` and inspect the returned
vector's `headers`.)

Acceptance: from `/Users/shinzui/Keikaku/bokuno/keiro`, run `cabal test keiro-pgmq-test`. Both
new examples pass; M1's examples still pass.

### Milestone M3 — handler-visible headers and trace propagation

Scope: let a handler read the headers attached to a job, and let a producer propagate the
current OpenTelemetry trace into the job so the handler runs inside the same trace. At the end
of M3, `JobContext` has a `headers :: Maybe Value` field populated on the drain path;
`enqueueTraced provider job extraHeaders payload` injects the current `traceparent`; and a test
proves the producer's `traceparent` reaches the drain-path handler.

Work, part A (the field): In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, add `headers :: !(Maybe
Value)` to `JobContext` (after `attempt`, lines 263–268), with Haddock stating that on the
drain path this is the raw PGMQ message header object (`Just` when the message had headers,
`Nothing` when it had none) and on the worker path it is always `Nothing` because the shibuya
adapter's `Envelope` does not surface arbitrary headers (only the trace context, which shibuya
already uses to continue the trace). `Value` is already imported (line 81). Then fix the two
construction sites. In `wrapHandler`'s `contextFor` (line 335), add `headers = Nothing` (the
worker path; the `Ingested`/`Envelope` does not carry arbitrary headers). In
`runJobOnceWithContext`'s `contextFor` (line 461), add `headers = message.headers` (the raw
`Pgmq.Message` is in scope as `message`, and `message.headers :: Maybe Value`). Both edits are
required for the file to compile because `JobContext`'s constructor is strict and both call
sites build it positionally-by-name.

Work, part B (trace propagation): add `enqueueTraced` and `enqueueTracedWithDelay`.
`enqueueTraced provider job extraHeaders p` does: `ctx <- liftIO
OpenTelemetry.Context.ThreadLocal.getContext`; `traceHeaders <- injectTraceContext provider
ctx`; `let merged = MessageHeaders (mergeTraceHeaders traceHeaders (Just (unMessageHeaders
extraHeaders)))`; `enqueueWithHeaders job merged p`. The delayed variant threads the `Int32`
delay through `enqueueWithHeadersAndDelay`. Signatures: `enqueueTraced :: (Pgmq :> es, IOE :>
es) => TracerProvider -> Job p -> MessageHeaders -> p -> Eff es MessageId` and
`enqueueTracedWithDelay :: (Pgmq :> es, IOE :> es) => TracerProvider -> Job p -> Int32 ->
MessageHeaders -> p -> Eff es MessageId`. Add imports: `injectTraceContext`, `mergeTraceHeaders`
(both re-exported from the `Pgmq.Effectful` umbrella — confirmed by reading the umbrella's
export list), `TracerProvider` from `"hs-opentelemetry-api" OpenTelemetry.Trace.Core
(TracerProvider)`, `getContext` from `"hs-opentelemetry-api"
OpenTelemetry.Context.ThreadLocal (getContext)`, and `liftIO` from `Effectful (liftIO)`. The
merge is additive and existing keys win, so passing `MessageHeaders (object [])` as
`extraHeaders` injects only the trace, and passing real headers preserves them (and would
preserve `x-pgmq-group` if present). Add both names to the export list. No new build-dep is
required (`hs-opentelemetry-api` is already a dependency; verify the import resolves at build
time).

Tests: add two examples. `"drain-path JobContext exposes the enqueued headers"` ensures the
queue, calls `enqueueWithHeaders job (MessageHeaders (object ["tenant" .= ("acme" :: Text)]))
(Ping "h" 1)`, then drains with `runJobOnceWithContext defaultJobTuning 1 job \ctx _payload ->
do { liftIO (writeIORef seen ctx.headers); pure Done }`, and asserts the captured
`ctx.headers` is `Just v` with `"tenant" -> "acme"`. `"a traceparent set at enqueue is visible
to the drain-path handler"` obtains a provider with `provider <- liftIO getGlobalTracerProvider`,
calls `enqueueTraced provider job (MessageHeaders (object [])) (Ping "t" 1)`, then drains and
asserts the captured `ctx.headers` is `Just v` where `v` is an object containing the key
`"traceparent"` (a string). Because the test runtime installs no real tracer provider, the
global provider may be a no-op whose propagator writes no `traceparent`; if so, the example
must establish a span first so the context is non-empty. The robust form: in the test, wrap the
enqueue in an actual span using the global provider's tracer (`OpenTelemetry.Trace.Core`'s
`inSpan`/`createTracer`) so a `traceparent` is produced, then assert it appears in
`ctx.headers`. State this requirement in the example and, if the no-op provider cannot produce
a `traceparent`, fall back to asserting the additive-merge behavior directly (that
`enqueueTraced` with non-empty `extraHeaders` preserves those headers on the message), and
record the limitation in Surprises & Discoveries with the observed provider behavior.

Acceptance: from `/Users/shinzui/Keikaku/bokuno/keiro`, run `cabal test keiro-pgmq-test`. All
M1, M2, and M3 examples pass.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

First, confirm the starting state builds and tests pass, so you can attribute any later
failure to your change:

```bash
cabal build keiro-pgmq
cabal test keiro-pgmq-test
```

Expected: the build succeeds and the existing suite is green. A typical tail looks like:

```text
Keiro.PGMQ
  ... (existing examples) ...
Finished in N.NNNN seconds
NN examples, 0 failures
```

Then implement M1 by editing `keiro-pgmq/src/Keiro/PGMQ/Job.hs` (add the two producers and the
exports as described in the Plan of Work) and `keiro-pgmq/test/Main.hs` (add the two M1
examples). Rebuild and test:

```bash
cabal build keiro-pgmq
cabal test keiro-pgmq-test
```

Expected: two more examples than before, all passing. If the build fails with "Not in scope:
data constructor MessageHeaders" in the test, add `MessageHeaders (..)` to the test's
`Pgmq.Effectful (...)` import (or import it from `Keiro.PGMQ`, which now re-exports it).

Repeat the edit/build/test cycle for M2 (three batch producers plus two examples) and M3 (the
`JobContext.headers` field, the two `contextFor` fixes, `enqueueTraced`/`enqueueTracedWithDelay`,
and two examples). After M3:

```bash
cabal test keiro-pgmq-test
```

Expected final tail (example count is illustrative; the point is zero failures):

```text
Keiro.PGMQ
  ...
  enqueueWithHeaders attaches a header readable on the raw PGMQ message
  enqueueWithHeaders leaves the x-pgmq-group key untouched
  enqueueBatch of three payloads yields three ids and queue depth three
  enqueueBatchWithHeaders attaches per-message headers
  drain-path JobContext exposes the enqueued headers
  a traceparent set at enqueue is visible to the drain-path handler
Finished in N.NNNN seconds
NN examples, 0 failures
```


## Validation and Acceptance

Acceptance is behavioral, phrased as observable input/output, and proven by the suite. After
all milestones, `cabal test keiro-pgmq-test` (run from `/Users/shinzui/Keikaku/bokuno/keiro`)
must report zero failures with the six new examples present.

For M1, the proof that headers reach the wire is the example
`"enqueueWithHeaders attaches a header readable on the raw PGMQ message"`: it enqueues with a
`tenant=acme` header and reads the raw PGMQ message back, observing `message.headers == Just v`
with `v` containing `"tenant" -> "acme"`. The reserved-key contract is proven by
`"enqueueWithHeaders leaves the x-pgmq-group key untouched"`: enqueuing with an `x-pgmq-group`
header and reading it back unchanged demonstrates EP-1 neither strips nor renames the key, which
is exactly what EP-3 (`docs/plans/77-…`) depends on.

For M2, `"enqueueBatch of three payloads yields three ids and queue depth three"` proves the
batch reached the queue in one call by observing both `length ids == 3` and queue depth `3`
through `queueLen`. `"enqueueBatchWithHeaders attaches per-message headers"` proves per-message
headers by reading both messages back and observing each carries its distinct header value.

For M3, `"drain-path JobContext exposes the enqueued headers"` proves a handler can read the
headers: the drain handler captures `ctx.headers` and the example observes
`Just v` with the enqueued key. `"a traceparent set at enqueue is visible to the drain-path
handler"` proves trace propagation: a `traceparent` set by `enqueueTraced` is observed in the
drained handler's `ctx.headers`. Each example would fail before the corresponding code exists
(the function would not be in scope, or `ctx.headers` would not type-check, or the header would
be absent) and passes after, which is the "effective beyond compilation" evidence the
specification requires.

Worker-path note for reviewers: the worker path's `JobContext.headers` is intentionally
`Nothing` (the shibuya adapter sets `Envelope.headers = Nothing`); the existing worker-path
examples in the suite (`"worker-path context exposes the first attempt number"` and the
worker smoke/lease examples) continue to pass unchanged, confirming the new field does not
disturb the worker path. Distributed tracing on the worker path is handled by shibuya itself
through `Envelope.traceContext`, which `pgmqMessageToEnvelope` already populates from the same
JSONB headers; EP-1 does not need to (and does not) re-implement that.


## Idempotence and Recovery

Every step is additive Haskell-source editing and is safe to repeat: re-running
`cabal build keiro-pgmq` and `cabal test keiro-pgmq-test` after an edit simply rebuilds and
re-tests. The test harness gives each example a fresh, isolated database
(`Postgres.withFreshDatabase`), so re-running the suite never accumulates state and examples do
not interfere with one another. PGMQ's `createQueue` (used by `ensureJobQueue`) is idempotent,
so the new examples calling `ensureJobQueue` are safe to run repeatedly.

The only breaking change in this plan is adding the `headers` field to `JobContext` (M3). If
the build fails after that edit, the cause is an un-updated `JobContext` constructor: there are
exactly two, both in `keiro-pgmq/src/Keiro/PGMQ/Job.hs` (`wrapHandler`'s `contextFor` and
`runJobOnceWithContext`'s `contextFor`); add `headers = Nothing` to the former and `headers =
message.headers` to the latter. To roll back any milestone, revert the corresponding edits to
`Job.hs` and `Main.hs`; because every change is additive (except the single `JobContext` field,
which is internal to keiro-pgmq), reverting cannot leave a partially-broken public surface for
downstream consumers — no consumer constructs `JobContext`.

If `cabal test` cannot start a PostgreSQL server (the suite needs an ephemeral Postgres via
`keiro-test-support`), that is an environment issue, not a regression; the M1 pure examples
(`enqueueWithHeaders` exports compiling) still validate via `cabal build keiro-pgmq`. The
header-on-wire and drain assertions, however, require the database and must be run where the
ephemeral Postgres is available.


## Interfaces and Dependencies

All new public surface lives in the module `Keiro.PGMQ.Job`
(`keiro-pgmq/src/Keiro/PGMQ/Job.hs`) and is re-exported automatically by the umbrella
`Keiro.PGMQ` (`keiro-pgmq/src/Keiro/PGMQ.hs`), which already re-exports `module
Keiro.PGMQ.Job` in full. No edit to the umbrella module is needed. No new Cabal build
dependency is needed: `aeson` (for `Value`/`object`/`.=`), `pgmq-effectful` (for
`MessageHeaders`, `SendMessageWithHeaders`, `BatchSendMessage`, `BatchSendMessageWithHeaders`,
`injectTraceContext`, `mergeTraceHeaders`), and `hs-opentelemetry-api` (for `TracerProvider`,
`getContext`) are already listed in `keiro-pgmq/keiro-pgmq.cabal`'s library `build-depends`.

The exact final public signatures EP-1 adds, all with module path
`Keiro.PGMQ.Job` (and re-exported from `Keiro.PGMQ`):

```haskell
-- Header-carrying producers (Milestone M1)
enqueueWithHeaders ::
  (Pgmq :> es, IOE :> es) =>
  Job p -> MessageHeaders -> p -> Eff es MessageId

enqueueWithHeadersAndDelay ::
  (Pgmq :> es, IOE :> es) =>
  Job p -> Int32 -> MessageHeaders -> p -> Eff es MessageId

-- Batch producers (Milestone M2)
enqueueBatch ::
  (Pgmq :> es, IOE :> es) =>
  Job p -> [p] -> Eff es [MessageId]

enqueueBatchWithDelay ::
  (Pgmq :> es, IOE :> es) =>
  Job p -> Int32 -> [p] -> Eff es [MessageId]

enqueueBatchWithHeaders ::
  (Pgmq :> es, IOE :> es) =>
  Job p -> [(MessageHeaders, p)] -> Eff es [MessageId]

-- Trace-propagating producers (Milestone M3)
enqueueTraced ::
  (Pgmq :> es, IOE :> es) =>
  TracerProvider -> Job p -> MessageHeaders -> p -> Eff es MessageId

enqueueTracedWithDelay ::
  (Pgmq :> es, IOE :> es) =>
  TracerProvider -> Job p -> Int32 -> MessageHeaders -> p -> Eff es MessageId
```

The re-exported header type (added to `Keiro.PGMQ.Job`'s export list, originally from
`pgmq-core` via `pgmq-effectful`):

```haskell
newtype MessageHeaders = MessageHeaders { unMessageHeaders :: Value }
```

The new `JobContext` field (Milestone M3), with the full record after the change:

```haskell
data JobContext es = JobContext
  { extendLease :: !(NominalDiffTime -> Eff es ())
  , attempt     :: !(Maybe Word)
  , headers     :: !(Maybe Value)
  -- ^ Drain path: the raw PGMQ message header object ('Just' when the
  --   message carried headers, 'Nothing' otherwise). Worker path: always
  --   'Nothing', because the shibuya adapter's 'Envelope' does not surface
  --   arbitrary headers (only the trace context, which shibuya itself uses
  --   to continue the trace).
  }
```

The library functions EP-1 depends on, and why:

- `Pgmq.sendMessageWithHeaders :: (Pgmq :> es) => SendMessageWithHeaders -> Eff es MessageId`
  and the record `SendMessageWithHeaders { queueName, messageBody, messageHeaders, delay }` —
  the header-carrying send. Both already imported in `Job.hs` (used by `sendDlq`).
- `Pgmq.batchSendMessage :: (Pgmq :> es) => BatchSendMessage -> Eff es [MessageId]` with
  `BatchSendMessage { queueName, messageBodies :: [MessageBody], delay :: Maybe Int32 }`, and
  `Pgmq.batchSendMessageWithHeaders :: (Pgmq :> es) => BatchSendMessageWithHeaders -> Eff es
  [MessageId]` with `BatchSendMessageWithHeaders { queueName, messageBodies :: [MessageBody],
  messageHeaders :: [MessageHeaders], delay :: Maybe Int32 }` — the one-round-trip batch sends.
  All re-exported from the `Pgmq.Effectful` umbrella (confirmed).
- `injectTraceContext :: MonadIO m => TracerProvider -> Context -> m TraceHeaders` and
  `mergeTraceHeaders :: TraceHeaders -> Maybe Value -> Value` (module
  `Pgmq.Effectful.Telemetry`, re-exported from the `Pgmq.Effectful` umbrella) — the trace
  injection and additive merge used by `enqueueTraced`.
- `TracerProvider` and `getGlobalTracerProvider :: MonadIO m => m TracerProvider` from
  `OpenTelemetry.Trace.Core` (`hs-opentelemetry-api`), and `getContext` from
  `OpenTelemetry.Context.ThreadLocal` (same package) — the provider/context inputs to the
  trace injection. `getGlobalTracerProvider` is used in the M3 test, not the library.
- `encodeJob :: JobCodec p -> p -> Value` (`Keiro.PGMQ.Codec`) — payload encoding, already in
  use by `enqueue`.

Integration Point contract (MasterPlan #10, Integration Point 2). EP-3
(`docs/plans/77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md`) depends on
EP-1 providing `enqueueWithHeaders :: (Pgmq :> es, IOE :> es) => Job p -> MessageHeaders -> p
-> Eff es MessageId` with the argument order `Job -> MessageHeaders -> p` and on EP-1 leaving
the reserved header key `x-pgmq-group` untouched (never reserved, injected, stripped, or
renamed). EP-3 will define `enqueueToGroup job groupKey p = enqueueWithHeaders job
(groupHeader groupKey) p` where `groupHeader k = MessageHeaders (object ["x-pgmq-group" .=
k])`. EP-1 satisfies the no-reserve contract because `enqueueWithHeaders` passes the caller's
`MessageHeaders` through verbatim and `enqueueTraced`'s only header mutation is the additive
`mergeTraceHeaders` (existing keys win, so `x-pgmq-group` survives). If EP-1's final
`enqueueWithHeaders` shape ever changes, this section and MasterPlan #10's Integration Point 2
must be updated before EP-3 begins.

Frozen shapes (MasterPlan #10, Integration Point 4). EP-1 reads but does not modify the fields
of `Job` (`jobName`, `jobQueue :: QueueRef`, `jobCodec :: JobCodec p`, `jobPolicy ::
RetryPolicy`) or `QueueRef` (`logicalName`, `physicalName :: QueueName`, `dlqName ::
QueueName`). The only record EP-1 changes is `JobContext`, which is constructed solely inside
`keiro-pgmq` (two sites in `Job.hs`) and so is safe to extend.
