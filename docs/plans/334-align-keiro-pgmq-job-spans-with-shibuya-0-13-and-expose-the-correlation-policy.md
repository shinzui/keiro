---
id: 334
slug: align-keiro-pgmq-job-spans-with-shibuya-0-13-and-expose-the-correlation-policy
title: "Align keiro-pgmq job spans with Shibuya 0.13 and expose the correlation policy"
kind: exec-plan
created_at: 2026-11-12T04:43:48Z
intention: "intention_01m770wgzbe9vakycrq50yq7th"
master_plan: "docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-12T04:43:48Z
---

# Align keiro-pgmq job spans with Shibuya 0.13 and expose the correlation policy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

`keiro-pgmq` runs typed jobs from PostgreSQL message queues. Every delivery is wrapped in an
OpenTelemetry *processing span*. There are two execution paths: continuous workers, which run
under Shibuya's supervised runner and get the span from Shibuya; and a bounded drain
(`runJobOnce`), which reads the queue directly and opens the same span itself with code copied
from Shibuya by hand. ADR-1 records that the copy can silently drift.

`shibuya-core` 0.13 changes that span in three ways: it is renamed from `<job> process` to
`process <job>`; it always carries a *link* (a pointer to a causally related span in another
trace) to the context recorded when the job was enqueued; and whether it is also a child of
that context is a per-adapter policy, `ParentAndLink` or `LinkOnly`. Without this plan the
continuous path would pick up the new behaviour and the bounded path would keep the old, which
is exactly the drift ADR-1 warned about.

After this plan both paths produce the same span by calling the same Shibuya function, and a
job author can choose the policy per job. `LinkOnly` is the right choice for jobs enqueued with
a delay or retried over long intervals, where joining the enqueuing trace attaches late work to
a trace that ended long ago. Someone can see it by running the same job through both paths with
a tracer and comparing the exported spans.


## Progress

- [ ] M1: `keiro-pgmq` builds and passes its tests against `shibuya-core` 0.13 and the matching
  `shibuya-pgmq-adapter` release (if a sibling plan has not already done the bump).
- [ ] M2: The bounded drain opens its span through Shibuya's shared function; the hand-copied
  construction is gone; both paths export identical span names, links and common attributes.
- [ ] M3: `JobTuning` carries the telemetry policy and both paths honour it.
- [ ] M4: Tests cover both policies on both paths; ADR-1, the user guide and the changelog are
  revised; the parent MasterPlan is updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The bounded drain calls `Shibuya.Telemetry.Process.withProcessSpan` instead of
  constructing the span.
  Rationale: One implementation of the span's name, kind, link and parent rule removes the
  silent-divergence risk ADR-1 accepted when no shared function existed.
  Date: 2026-11-11

- Decision: The policy is a field on `JobTuning`, holding Shibuya's `AdapterTelemetry` value,
  defaulting to `ParentAndLink`.
  Rationale: `JobTuning` is the only consumer-side configuration a job user controls, and
  `adapterConfigFor` already derives the adapter configuration from it. Carrying the whole
  `AdapterTelemetry` record means future Shibuya telemetry options reach job users without a
  further change here. The default matches the PGMQ adapter's.
  Date: 2026-11-11

- Decision: Extraction stays W3C-only on the consumer side although `enqueueTraced` injects
  with the provider's configured propagator.
  Rationale: Extraction is done by `shibuya-core`, which reads `traceparent` directly, and
  changing that is out of scope in the Shibuya initiative. The asymmetry is documented: with a
  non-W3C propagator configured, enqueued context is written but not read.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a child of
`docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md`.
Prerequisites, both outside this repository: `shibuya-core` 0.13.0.0 on Hackage, and a
`shibuya-pgmq-adapter` release built against it whose `PgmqAdapterConfig` has a
`telemetry :: AdapterTelemetry` field. Verify on Hackage itself. If either is missing, this plan
cannot start. The tracer-enabled baselines of
`docs/plans/330-establish-tracing-enabled-performance-and-retention-baselines.md` are useful but
not required: `keiro-pgmq` has no benchmark stanza.

Run everything in the Nix development shell (`nix develop -c …`).

What the two releases provide (from
`mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`; follow
the released Haddocks where they differ and note it):

```haskell
-- shibuya-core: Shibuya.Telemetry.Correlation, re-exported from Shibuya.Adapter
data TraceCorrelation = ParentAndLink | LinkOnly
data AdapterTelemetry            -- constructor not exported
defaultAdapterTelemetry :: AdapterTelemetry        -- traceCorrelation = ParentAndLink
-- record update: defaultAdapterTelemetry {traceCorrelation = LinkOnly}

-- shibuya-core: Shibuya.Telemetry.Process
withProcessSpan ::
  (Tracing :> es, IOE :> es) =>
  TraceCorrelation -> Text -> Maybe TraceHeaders -> (Span -> Eff es a) -> Eff es a

-- shibuya-core: Shibuya.Telemetry.Semantic
processSpanName :: Text -> Text          -- now "process <destination>"
attrMessagingOperationName :: Text       -- messaging.operation.name

-- shibuya-pgmq-adapter: Shibuya.Adapter.Pgmq.Config
data PgmqAdapterConfig = PgmqAdapterConfig { ..., telemetry :: !AdapterTelemetry }
```

`withProcessSpan` opens the Consumer-kind span with the given full name, always linked to the
creation context in the headers when there is one, a child of it under `ParentAndLink`, a root
under `LinkOnly`; with tracing disabled it passes a sentinel span and does nothing else.

The code, all in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`:

- `data Job p` (near line 429): `jobName`, `jobQueue`, `jobCodec`, `jobOrdering`, `jobPolicy`.
- `data JobTuning` (near line 328): `visibilityTimeout`, `batchSize`, `polling`, `ordering`;
  the raw constructor is exported and `mkJobTuning` validates.
- `adapterConfigFor :: JobTuning -> Job p -> PgmqAdapterConfig` (near line 799, not exported)
  starts from the adapter's `defaultConfig` and sets the fields it knows.
  `jobProcessorWithContext` (near line 846) builds the continuous processor with
  `pgmqAdapter env (adapterConfigFor tuning job)`.
- `withOneShotProcessSpan` (near line 917) is the hand copy: `withExtractedContext` on the
  decoded headers, then `withSpan' (processSpanName job.jobName) consumerSpanArgs`, then five
  `addAttribute` calls. `recordAckOnSpan` (near line 941) writes the acknowledgement decision.
  `runJobOnceWithContext` (near line 986) calls it per message (near line 1045).
- `enqueueTraced` and `enqueueTracedWithDelay` (near line 554) inject the current context into
  the message headers through the tracer provider's configured propagator.

`keiro-pgmq/src/Keiro/PGMQ/Runtime.hs` chooses `runTracing tracer` or `runTracingNoop` for the
effect stack.

Tests are in `keiro-pgmq/test/Main.hs`: span capture fixtures near lines 226–240;
`theProcessSpan` (near line 289) selects the span named `jobName <> " process"`; cases near
lines 1050–1207 assert the common attributes, the acknowledgement vocabulary, parent
continuation, and `shibuya.partition`; cases near 1034–1046 assert the lower-level
`publish <queue>` and `receive <queue>` spans that the traced PGMQ interpreter emits, which this
plan does not change.

Relevant ADRs.
[ADR-1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md) is the contract this plan
revises: both paths emit one Consumer span per delivery with shared name, attributes and
acknowledgement vocabulary; the bounded path omits `shibuya.inflight.*` and records no
acknowledgement when a handler throws. Those two deliberate differences remain. What changes is
the span's name, the added link, the policy, and that the "duplicated instrumentation site"
consequence no longer holds. The known gap in
[BUG-7](../bug-reports/7-pre-handler-dead-letter-has-no-process-span.md) (a job dead-lettered
before its handler runs has no processing span) is not addressed here.


## Plan of Work

### Milestone 1: the dependency bump

If not already done by
`docs/plans/333-open-linked-processing-spans-in-subscription-workers-and-the-inbox-consumer-helper.md`,
raise `shibuya-core` to `^>=0.13.0.0` and `shibuya-pgmq-adapter` to the release that supports
it, in every stanza across the repository that names them, after checking the published
versions; add `telemetry = defaultAdapterTelemetry` to every `Adapter { … }` literal the compiler
reports. Record the bump in the parent MasterPlan. Expect `keiro-pgmq-test` to fail on span
names at this point for the continuous path only; that is the divergence this plan removes.

### Milestone 2: one span implementation

Rewrite `withOneShotProcessSpan` to call
`withProcessSpan policy (processSpanName job.jobName) envelope.traceContext`, keeping its
attribute-setting body, and add `messaging.operation.name = "process"` so the bounded path
matches what Shibuya's runner now sets. Remove the now-unused imports
(`withExtractedContext`, `extractTraceContext`, `consumerSpanArgs`). `recordAckOnSpan` is
unchanged. Compare, attribute by attribute, the span the continuous path exports under 0.13
with the bounded path's, and bring the bounded path's common set into agreement; the two
deliberate differences recorded in ADR-1 stay.

Update `theProcessSpan` and every assertion that matches the old name.

### Milestone 3: the policy

Add `telemetry :: !AdapterTelemetry` to `JobTuning`, defaulting to `defaultAdapterTelemetry` in
the default tuning and in `mkJobTuning` (which gains no new validation). In `adapterConfigFor`,
set the adapter configuration's `telemetry` from it. In `runJobOnceWithContext`, pass
`tuning.telemetry.traceCorrelation` to `withOneShotProcessSpan`. Re-export `TraceCorrelation`,
`AdapterTelemetry` and `defaultAdapterTelemetry` from the module so job authors need no Shibuya
import. `JobTuning` derives `Eq` and `Show`; confirm `AdapterTelemetry` has those instances in
the released version, and if it does not, raise it against the Shibuya plan rather than dropping
the instances here.

Adding a field to `JobTuning`, whose constructor is exported, is a breaking change; state it in
the changelog and point users at `mkJobTuning` and record update.

### Milestone 4: tests and documents

Add tests that run the same enqueued job through both paths under each policy and assert
equality of span name, kind, link target and parent presence between the paths: under
`ParentAndLink`, the span's trace is the enqueuer's and it has one link to the enqueuing span;
under `LinkOnly`, a new trace, no parent, the same link. Add a delayed-job case
(`enqueueTracedWithDelay`) under `LinkOnly`, and a retried job whose two deliveries are two
traces each linking to the one enqueuing span. Keep the existing acknowledgement-vocabulary
tests passing.

Revise ADR-1 in place, following `agents/skills/exec-plan/ADR.md` (profile-governed bundle:
keep the `docId`, advance the timestamp, add a log entry, run `just adr-validate`): new span
name; the link; the policy and where it is set; the bounded path now calls Shibuya's function,
so the hand-synchronisation consequence is replaced by "both paths share one span
implementation; the attribute set and acknowledgement mapping are still kept in step by the
tests". Update `docs/guides/work-queues.md` with a "Parent or link" section (default, when to
choose `LinkOnly`, the effect on sampling, the W3C-only extraction caveat), the capability
document, and `keiro-pgmq/CHANGELOG.md` (breaking: span rename with old and new forms, the
`JobTuning` field, the raised bounds).

Mark this plan Complete in the parent MasterPlan and update Progress.


## Concrete Steps

From the repository root:

```bash
cabal update
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal test keiro-pgmq-test --test-show-details=direct
nix develop -c just adr-validate
nix develop -c just verify
```

Expected new test lines:

```text
both paths export the same process span under ParentAndLink
both paths export the same process span under LinkOnly
a delayed job under LinkOnly is a linked root
each redelivery under LinkOnly is its own linked trace
```


## Validation and Acceptance

A job named `send-email`, enqueued with `enqueueTraced` and run through `runJobWorkers` and
through `runJobOnce`, exports in both cases a Consumer span named `process send-email` with one
link to the enqueuing span and the same common attributes. Before this plan, under
`shibuya-core` 0.13, the two paths export differently named spans and only one has a link.

With `tuning {telemetry = defaultAdapterTelemetry {traceCorrelation = LinkOnly}}` both paths
export a root span in a new trace.

`keiro-pgmq-test` and `just verify` pass against Hackage releases with no source pins added to
`cabal.project`. `Keiro.PGMQ.Job` no longer imports `withExtractedContext`.


## Idempotence and Recovery

Source and bound edits only. All commands are repeatable; tests provision their own queues. If
the upstream releases are missing, do not pin source checkouts to proceed; the plan stays Not
Started. There is no performance gate of its own because the change removes code from the
bounded path and adds one strict field read per worker; if the parent MasterPlan's release gate
shows a `keiro-pgmq` regression, investigate here first.


## Interfaces and Dependencies

Prerequisites: `shibuya-core` 0.13.0.0 and the matching `shibuya-pgmq-adapter` on Hackage.

Consumes `Shibuya.Telemetry.Process.withProcessSpan`, `Shibuya.Telemetry.Semantic.processSpanName`
and `attrMessagingOperationName`, `Shibuya.Adapter.AdapterTelemetry`, `defaultAdapterTelemetry`,
`TraceCorrelation`, and `Shibuya.Adapter.Pgmq.Config.PgmqAdapterConfig.telemetry`.

Changed:

```haskell
data JobTuning = JobTuning
  { visibilityTimeout :: !Int32,
    batchSize :: !Int32,
    polling :: !JobPolling,
    ordering :: !JobOrdering,
    telemetry :: !AdapterTelemetry      -- default: traceCorrelation = ParentAndLink
  }
```

A related, independent improvement to the `receive <queue>` spans of the traced PGMQ
interpreter is planned in
`mori://shinzui/pgmq-hs/plans/32-link-receive-spans-to-message-creation-contexts-in-the-traced-interpreter`;
nothing here depends on it. No other plan depends on this one.
