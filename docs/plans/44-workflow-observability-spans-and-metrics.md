---
id: 44
slug: workflow-observability-spans-and-metrics
title: "Workflow observability: spans and metrics"
kind: exec-plan
created_at: 2026-06-03T14:39:45Z
intention: "intention_01kt6y4cb6eqz9mq48kf2xw8n1"
master_plan: "docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md"
---

# Workflow observability: spans and metrics


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture


This plan makes the v2 durable-execution workflow runtime *operable*. Today (after
EP-38/EP-39/EP-40/EP-41/EP-42/EP-43) a workflow journals its steps, sleeps, awaits
external signals, snapshots a long journal, resumes after a crash, and spawns children —
but an operator running it in production cannot *see* any of that on a metrics dashboard
or a distributed-trace viewer. After this plan, wiring an OpenTelemetry SDK
`MeterProvider` and `Tracer` into the workflow runtime lets an operator answer the
questions they actually page on:

- *How many workflows are live right now?* — the `keiro.workflow.active` gauge.
- *How much real work is the runtime doing vs. just replaying recorded history?* — the
  `keiro.workflow.steps.executed` counter (a fresh step ran a side effect) against
  `keiro.workflow.steps.replayed` (a step short-circuited to its recorded result). A
  spike in replayed-with-no-executed means workflows are crash-looping; a spike in
  executed means real throughput.
- *Is the crash-recovery worker actually re-invoking stuck workflows?* — the
  `keiro.workflow.resumed` counter, incremented each time the EP-42 resume worker
  re-invokes a workflow.
- *Are journals growing without bound?* — the `keiro.workflow.journal.length` histogram,
  recording how many journal events a workflow accumulated by the time it completed.
- *Are awakeables piling up unresolved (an external system that stopped calling back)?* —
  the `keiro.workflow.awakeables.pending` gauge, sampled from EP-40's
  `countPendingAwakeables`.

On the tracing side, this plan adds a `withWorkflowSpan` helper that opens an
`Internal`-kind span around a workflow run (and, when a step name is supplied, around an
individual step or a resume), tagged with the bespoke attributes `keiro.workflow.name`,
`keiro.workflow.id`, and `keiro.workflow.step`. An operator with a trace exporter wired in
sees a span tree per workflow run, exactly as the existing command/outbox/inbox spans
appear today.

The user-visible proof is the same shape EP-35/EP-36 used for the outbox/inbox/timer
instruments: a test builds an OpenTelemetry SDK `MeterProvider` backed by the *in-memory
metric exporter*, constructs a `Meter`, builds a `KeiroMetrics` handle, runs a workflow
with that handle threaded through, flushes the exporter, and asserts the exact instrument
names and values came out — `keiro.workflow.steps.executed` incremented by the number of
fresh steps, `keiro.workflow.steps.replayed` incremented on a replay run,
`keiro.workflow.resumed` incremented when the resume worker re-invokes, and
`keiro.workflow.awakeables.pending` reflecting a pending-awakeable count. A companion
no-op test proves that with a `Nothing` handle the workflow runs identically and nothing
is exported, so an application that never configures OpenTelemetry pays only one `Maybe`
branch per recording site.

"Instrument" here means a single OpenTelemetry metric channel (a counter, a gauge, or a
histogram) created once from a `Meter` and recorded at a call site. "Span" means a timed,
attributed node in a distributed trace. "No-op path" means the code branch taken when the
caller passed `Nothing` for the metrics/tracer handle: every helper returns immediately
without touching OpenTelemetry, so the cost is one pattern match.


## Progress


Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 — Extend `KeiroMetrics` in `keiro/src/Keiro/Telemetry.hs` with the six
  `keiro.workflow.*` instruments, their name constants, their `newKeiroMetrics`
  constructor lines, and their `record*` helpers; add the `withWorkflowSpan` helper and
  the three bespoke `keiro.workflow.*` attribute keys. `cabal build keiro` green.
  (Commit `b406387`.)
- [x] M2 — Thread `Maybe KeiroMetrics` and `Maybe Tracer` through `WorkflowRunOptions`
  (EP-41's record) into the EP-38 handler: record `steps.executed` on a step miss,
  `steps.replayed` on a step hit (and an `awaitStep` hit), `active` on entry/exit via a
  process-global live-count `IORef` bracketed `+1`/`-1`, `journal.length` at completion,
  and open `withWorkflowSpan` around the run. `cabal build keiro` green; existing EP-38/41
  workflow tests still pass. (Commit `55c46b9`.)
- [x] M3 — Wire `resumed` (EP-42's resume worker, on each re-invocation) and
  `awakeables.pending` (sampled via EP-40's `countPendingAwakeables`). The metrics handle
  rides on `WorkflowResumeOptions.runOptions` (EP-44's telemetry lives on
  `WorkflowRunOptions`), so no new worker argument was needed. `cabal build keiro` green.
  (Commit `734db24`.)
- [x] M4 — Update `docs/research/opentelemetry-semconv-audit.md` with a workflow metrics
  subsection (name/unit/kind/recording-site for all six instruments), the workflow span
  row, and the three bespoke attribute keys. (Commit `ea0350b`.)
- [x] M5 — Add the in-memory-exporter validation tests in `keiro/test/Main.hs` (positive
  assertions for executed/replayed/active/journal.length + resumed/awakeables.pending + a
  `Nothing`-handle no-op test). `cabal test keiro` green (133 examples, 0 failures).
  (Commit `511ee42`.)


## Surprises & Discoveries


Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03 (implementation): **the entire surface landed exactly as planned — every
  soft dependency (EP-39/EP-40/EP-42/EP-43) was already present, so no provisional path
  was taken.** The cycle-safety prediction held: GHC compiled `Keiro.Workflow.Types`
  before `Keiro.Telemetry` (`[Keiro.Workflow.Types] … [22 of 33] Keiro.Telemetry`) and
  `Keiro.Workflow` after `Keiro.Telemetry`, confirming the only edges are
  `Keiro.Workflow → Keiro.Telemetry` and `Keiro.Telemetry → Keiro.Workflow.Types` (a leaf).
- 2026-06-03 (implementation): **M3 needed no new resume-worker argument.** The plan
  offered two paths (add a `Maybe KeiroMetrics` argument like `runTimerWorker`, or reuse an
  existing one). Because EP-44's own design decision puts telemetry on `WorkflowRunOptions`
  and EP-42's `WorkflowResumeOptions` already carries `runOptions :: WorkflowRunOptions`,
  the metrics handle was read straight from `runOptions opts ^. #metrics`. This is strictly
  better than a separate argument: the same handle is *already forwarded* into every
  `runWorkflowWith`/`runChildWorkflow` re-invocation, so a resumed run records its own
  steps/active/journal-length and opens its span with zero extra wiring. `recordWorkflowResumed`
  is incremented once per re-invocation in `resumeWorkflowsOnce`'s registry-hit branch (the
  `unknownName` branch does not count); `recordWorkflowAwakeablesPending` is sampled once per
  pass next to the discovery query.
- 2026-06-03 (implementation): **the `metrics`/`tracer` fields use a bare-record-update–safe
  generic-lens label at every set site.** EP-41 flagged that `WorkflowRunOptions.snapshotPolicy`
  collides with keiki's `EventStream.snapshotPolicy` under a bare record update (`GHC-99339`);
  the same risk applies to any field. The tests therefore set the handles with
  `defaultWorkflowRunOptions & #metrics .~ Just metrics` (and
  `defaultWorkflowResumeOptions & #runOptions .~ (… & #metrics .~ …)`), never a bare
  `r { metrics = … }`. EP-45 examples should follow the label form.
- 2026-06-03 (implementation): **`keiro.workflow.active` is backed by a process-global
  `{-# NOINLINE #-} activeCountRef :: IORef Int64`** in `Keiro.Workflow`, bracketed `+1`/`-1`
  around each run with the gauge sampled on *both* edges (so the exported last-value is the
  true live count, 0 in steady state). The bracket is unconditional (only the *recording* is
  gated by `Nothing`), so the counter stays balanced even on a crash/exception path — proven
  indirectly by the existing `crashAfterStep1` test (the suite stays green and the new
  observability test reads `active == 0`). One test-hygiene consequence: the gauge is shared
  process-wide, so its steady-state assertion only holds because hspec runs sequentially and
  every run balances its own `+1`/`-1`.


## Decision Log


Record every decision made while working on the plan.

- Decision: Thread the telemetry handles (`Maybe KeiroMetrics`, `Maybe Tracer`) into the
  workflow runtime by adding two fields to EP-41's `WorkflowRunOptions` record (in
  `keiro/src/Keiro/Workflow.hs`), **not** as bare positional arguments to `runWorkflowWith`.
  Rationale: EP-41 explicitly designated `WorkflowRunOptions` as "the natural home for
  future cross-cutting run options" and called out by name that "EP-44 (telemetry) will add
  `Maybe KeiroMetrics` / `Maybe Tracer` fields here"
  (`docs/plans/41-workflow-journal-snapshots-and-step-result-compaction.md`, lines 486–489).
  The MasterPlan's Telemetry integration point requires the handle be threaded as an
  *explicit function argument* and **not** placed on a record that a module
  `Keiro.Telemetry` transitively imports (the cycle MasterPlan 4 hit). `WorkflowRunOptions`
  lives in `Keiro.Workflow`, which `Keiro.Telemetry` does **not** import — so the field
  placement is cycle-safe (see the cycle-check decision below). `WorkflowRunOptions` is itself
  the explicit argument the runtime receives, so this satisfies "passed explicitly" while
  reusing the canonical home EP-41 built.
  Date: 2026-06-03.

- Decision (cycle check): Placing `Maybe KeiroMetrics` / `Maybe Tracer` on
  `WorkflowRunOptions` does **not** create a `Keiro.Telemetry` import cycle.
  Rationale: `Keiro.Telemetry`'s only intra-package imports are `Keiro.Inbox.Kafka`,
  `Keiro.Integration.Event`, `Keiro.Outbox.Kafka`, and `Keiro.Prelude` (verified by
  `grep "^import Keiro" keiro/src/Keiro/Telemetry.hs`). It imports **no** workflow module.
  The dependency direction is `Keiro.Workflow → Keiro.Telemetry` (the workflow handler
  imports the telemetry surface to record), which is acyclic. The cycle MasterPlan 4 hit was
  `Keiro.Telemetry → Keiro.Outbox.Types` (a record `Keiro.Telemetry` itself needed to name) —
  that does not recur here because `KeiroMetrics`/`Tracer` are defined *in*
  `Keiro.Telemetry` and merely *referenced from* `Keiro.Workflow`. Confirmed cycle-safe;
  no fallback to a bare positional argument is needed.
  Date: 2026-06-03.

- Decision: `keiro.workflow.active` is an `Int64` **Gauge** (last-value-wins), recorded as
  the live workflow-run count on entry and exit of `runWorkflowWith`.
  Rationale: This matches how EP-33/EP-36 modelled `keiro.timer.backlog` and
  `keiro.inbox.backlog` — a synchronous gauge the runtime records with the value it already
  has in hand, rather than an asynchronous observable gauge (which would need its own
  database callback the library does not own; see the MasterPlan metrics-kind policy in
  `docs/research/opentelemetry-semconv-audit.md` "## Metrics"). The runtime holds a process-
  wide live-count `IORef`; it records `+1` on entry and `-1` on exit. (UpDownCounter would
  also model this, but the existing keiro pattern uses synchronous gauges for "how many are
  live right now", and `meterCreateGaugeInt64` is the only delta-free instrument the
  `newKeiroMetrics` helpers already wrap.)
  Date: 2026-06-03.

- Decision: `keiro.workflow.journal.length` is a **Histogram** (`Double`), recorded once
  per completed workflow with the journal-event count at completion.
  Rationale: Per-workflow the journal length is a single scalar, but the operator question
  ("are journals growing?") is a *distribution across workflows* — p50/p95/max journal
  length — which is exactly what a histogram captures and a gauge cannot (a gauge would only
  retain the last completing workflow's length). The existing `keiro.timer.fire.lag` and
  `keiro.timer.attempts` instruments set the precedent: a per-event scalar that is
  operationally interesting in aggregate is a histogram, not a gauge.
  Date: 2026-06-03.

- Decision: `keiro.workflow.awakeables.pending` is an `Int64` **Gauge**, recorded by the
  EP-42 resume worker each poll pass (or by an explicit sampler) from EP-40's
  `countPendingAwakeables :: (Store :> es) => Eff es Int`.
  Rationale: It is a queue-depth-style "how many right now" number, identical in shape to
  `keiro.inbox.backlog`/`keiro.timer.backlog`. EP-40 exposed `countPendingAwakeables`
  specifically as "the seam EP-44 backs `keiro.workflow.awakeables.pending` on"
  (`docs/plans/40-awakeables-and-external-completion.md`, lines 131–134). The resume worker
  is the natural per-poll recording site because it already wakes on a timer and already
  holds a `Store` to run the query.
  Date: 2026-06-03.

- Decision: `keiro.workflow.steps.executed` and `keiro.workflow.steps.replayed` are
  `Int64` **Counters** (monotonic), and `keiro.workflow.resumed` is an `Int64` **Counter**.
  Rationale: All three are tallies (cumulative counts of events), which the keiro metrics
  policy models as monotonic counters recorded inline at the event site — exactly like
  `keiro.outbox.published` and `keiro.inbox.processed`. Steps executed/replayed are recorded
  one-per-step inside the `Step` handler branch; resumed is recorded one-per-re-invocation
  in the resume worker.
  Date: 2026-06-03.

- Decision (implementation): the resume worker reads its metrics handle from
  `WorkflowResumeOptions.runOptions ^. #metrics` rather than taking a new `Maybe KeiroMetrics`
  argument.
  Rationale: EP-44 already decided telemetry lives on `WorkflowRunOptions`, and EP-42's
  `WorkflowResumeOptions` carries a `runOptions :: WorkflowRunOptions` it forwards verbatim
  into every `runWorkflowWith`/`runChildWorkflow` re-invocation. Reading from there keeps a
  single canonical telemetry home, avoids widening the worker's signature, and means resumed
  runs automatically record their steps/active/journal-length and open their span. The
  plan's "add an argument like `runTimerWorker`" alternative was unnecessary because the
  handle was already in scope.
  Date: 2026-06-03.

- Decision (implementation): `keiro.workflow.journal.length` is recorded on *every*
  completing run — including a replay that re-completes an already-finished workflow — not
  only on a fresh `WorkflowCompleted` append.
  Rationale: the histogram's operator question is "how long are journals at completion",
  one observation per completion event the runtime witnesses. The M5 test runs the same
  two-step workflow twice (fresh + replay) and asserts the histogram count is `[2]`, which
  fixes this semantics. Length is computed as `Map.size finalMap + 1` (recorded step map
  plus the `WorkflowCompleted` marker), the cheapest value already in hand at the completion
  site.
  Date: 2026-06-03.


## Outcomes & Retrospective


Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- **Outcome (2026-06-03): complete, exactly to plan, no gaps.** The v2 workflow runtime is
  now operable: an operator who wires an OpenTelemetry SDK `MeterProvider`/`Tracer` into
  `WorkflowRunOptions` (and the resume worker's `WorkflowResumeOptions.runOptions`) gets all
  six `keiro.workflow.*` instruments and a per-run `workflow <name>` `Internal` span. All
  five milestones landed in five commits (`b406387`, `55c46b9`, `734db24`, `ea0350b`,
  `511ee42`); `cabal test keiro` is green at **133 examples, 0 failures**, with the three new
  observability assertions among them.
- **Against the original purpose:** every operator question in Purpose / Big Picture is now
  answerable — live workflows (`active`), real work vs. replay (`steps.executed` vs.
  `steps.replayed`), resume activity (`resumed`), journal growth (`journal.length`), and
  stuck awakeables (`awakeables.pending`). The no-op idiom holds end to end: a run with
  `defaultWorkflowRunOptions` exports zero points (proven by the `Nothing`-handle test).
- **Gaps / deferred:** none for this plan. Child-workflow-specific instruments
  (`keiro.workflow.children.active`, seam `Keiro.Workflow.Child.Schema.countActiveChildren`)
  were *not* added — they were never in this plan's six-instrument scope; EP-43's surprise
  entry flagged the seam for a future plan, and EP-45 can decide whether to surface it.
- **Lesson:** putting cross-cutting run options on one record (`WorkflowRunOptions`, EP-41's
  decision) paid off — EP-44 added two fields and the resume worker, child driver, and tests
  all inherited the handles for free, with no signature churn. The only friction is the
  bare-record-update ambiguity EP-41 warned about, sidestepped by always using the
  generic-lens label at set sites.

Green transcript (relevant group) from `cabal test keiro`:

```text
Keiro.Workflow observability
  records workflow instruments through an SDK meter [✔]
  records a resume and the pending-awakeable count when the worker re-invokes [✔]
  records nothing through a Nothing handle [✔]
...
Finished in 15.8904 seconds
133 examples, 0 failures
Test suite keiro-test: PASS
```


## Context and Orientation


The working tree is at `/Users/shinzui/Keikaku/bokuno/keiro`. The library packages are
`keiro-core` (pure contracts), `keiro` (the runtime — this plan touches it), `keiro-migrations`
(embedded SQL), `keiro-test-support` (PostgreSQL test fixtures), and `jitsurei` (worked
examples). This plan adds code to one existing module (`keiro/src/Keiro/Telemetry.hs`),
edits two others (`keiro/src/Keiro/Workflow.hs` and the EP-42 resume-worker module
`keiro/src/Keiro/Workflow/Resume.hs`), updates one research doc
(`docs/research/opentelemetry-semconv-audit.md`), and adds tests to `keiro/test/Main.hs`.
It introduces **no** new module, **no** migration, and **no** new package dependency.

Definitions used throughout (define-on-first-use, per the plan spec):

- *OpenTelemetry* — the vendor-neutral observability standard. keiro reaches it through
  `hs-opentelemetry-api` (the abstract surface: `Meter`, `Counter`, `Gauge`, `Histogram`,
  `Tracer`, `Span`) and, in tests only, `hs-opentelemetry-sdk` plus the in-memory exporters.
- *Meter* — an OpenTelemetry object that mints metric instruments. Obtained from a
  `MeterProvider` via `getMeter`. A *no-op meter* (the default when no SDK provider is
  configured) mints instruments that record nothing, so building `KeiroMetrics` is always
  safe.
- *instrument* — one metric channel. A **Counter** only goes up (a tally); a **Gauge**
  holds the last value recorded (a level); a **Histogram** records a distribution of
  observations (buckets + count + sum).
- *Tracer* — an OpenTelemetry object that opens spans. keiro's helpers take a
  `Maybe Tracer`; `Nothing` means "do not open a span, just run the body".
- *Span* — a timed, attributed node in a distributed trace. *Span kind* `Internal` means
  the span describes work inside this process (not a network producer/consumer boundary).
- *the no-op idiom* — every keiro telemetry `record*` helper takes a `Maybe KeiroMetrics`
  and pattern-matches `Nothing → pure ()`. An application that never builds a `KeiroMetrics`
  passes `Nothing` and pays nothing. This is the same idiom the `Maybe Tracer` span helpers
  use.

**The existing `Keiro.Telemetry` surface you extend** (`keiro/src/Keiro/Telemetry.hs`,
~590 lines). Study these landmarks before editing; the line numbers are guides, not
guarantees:

- The bespoke `keiro.*` `AttributeKey`s at lines ~181–188: `keiro_stream_name`,
  `keiro_retry_attempt`, `keiro_events_appended`, each `AttributeKey "keiro.<dotted.name>"`.
  You add three more here (`keiro_workflow_name`, `keiro_workflow_id`, `keiro_workflow_step`).
- The span helpers `withProducerSpan` / `withConsumerSpan` / `withCommandSpan` at lines
  ~207–309. `withCommandSpan` (lines 291–309) is the template for `withWorkflowSpan`: a
  `Maybe Tracer`; `Nothing → body Nothing`; `Just tracer → inSpan' tracer name
  (defaultSpanArguments {kind = Internal}) $ \sp -> addAttribute sp (unkey key) value >>
  body (Just sp)`. Note `unkey` strips the `AttributeKey` newtype; `inSpan'` is from
  `OpenTelemetry.Trace.Core`.
- The instrument-name `Text` constants at lines ~438–465 (`keiroOutboxBacklogName =
  "keiro.outbox.backlog"`, etc.). You add six (`keiroWorkflowStepsExecutedName`, …).
- The `KeiroMetrics` record at lines ~478–493 (fourteen instruments today). You add six
  fields.
- `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics` at lines ~502–544, which
  builds each instrument using the local helpers `counterI64`, `gaugeI64`, `histogram`
  (lines ~536–544). You add six constructor lines and six record-assignment lines.
- The `record*` helpers at lines ~547–591: the internal `recordCounter` / `recordGaugeI64`
  / `recordHistogram` dispatchers (each `Nothing → pure ()`), and one public
  `record<Name>` per instrument. You add six public helpers.
- The module export list at lines ~58–94 (the `-- * Metrics surface` and span-helper
  sections). You add the six name constants, the six `record*` helpers,
  `withWorkflowSpan`, and the three `keiro_workflow_*` attribute keys.

**The workflow runtime you instrument.** EP-38 owns `keiro/src/Keiro/Workflow.hs`: the
`Workflow` effect, `step`, `awaitStep`, and the journal/replay handler inside `runWorkflow`.
EP-41 refactored that handler into `runWorkflowWith :: WorkflowRunOptions -> WorkflowName ->
WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)`, with `runWorkflow =
runWorkflowWith defaultWorkflowRunOptions`. EP-41's `WorkflowRunOptions` record currently has
two fields (`snapshotPolicy`, `pageSize`); this plan adds two more. The handler's two
recording sites are:

- The `Step name action` interpretation: a **hit** (the step name is already in the in-memory
  journal map → return the recorded result without running `action`) is a *replay*; a
  **miss** (run `action`, journal the result) is an *execution*. EP-38's M3 describes these
  branches in `docs/plans/38-workflow-journal-and-named-step-replay-core.md` (Milestone 3,
  "Hit:" / "Miss:" bullets). You record `recordWorkflowStepReplayed` on the hit and
  `recordWorkflowStepExecuted` on the miss.
- Workflow completion: when `runWorkflowWith` finishes and appends `WorkflowCompleted`, the
  journal length is known. You record `recordWorkflowJournalLength` there.
- Run entry/exit: `runWorkflowWith` brackets the whole run; you record `+1`/`-1` on the
  live-count `IORef` and `withWorkflowSpan` around the body.

**The EP-42 resume worker you instrument.** EP-42 owns `keiro/src/Keiro/Workflow/Resume.hs`
(per the MasterPlan module-layout integration point) with a poll loop that discovers
unfinished workflows via `findUnfinishedWorkflowIds` and re-invokes each via
`runWorkflowWith`. Each re-invocation is a *resume*; you record `recordWorkflowResumed` once
per re-invocation. The same worker's poll pass is the natural place to sample
`countPendingAwakeables` and record `recordWorkflowAwakeablesPending`. If EP-42 has not yet
landed when you implement this plan, see "Idempotence and Recovery" for the provisional path
(instrument `runWorkflowWith` resume entry and add a standalone sampler), and reconcile in a
revision once EP-42 ships — the same provisional pattern the MasterPlan documents for late
observability plans.

**EP-40's awakeable count.** `keiro/src/Keiro/Workflow/Awakeable/Schema.hs` exposes
`countPendingAwakeables :: (Store :> es) => Eff es Int` (`SELECT count(*) FROM
keiro_awakeables WHERE status = 'pending'`), added by EP-40 specifically to back this gauge
(`docs/plans/40-awakeables-and-external-completion.md` lines 131–134, 799, 819).

**The test harness.** `keiro/test/Main.hs` already depends on
`hs-opentelemetry-exporter-in-memory` and `hs-opentelemetry-sdk`. The existing
`"Keiro.Telemetry metrics"` describe-block (lines ~174–220) is the exact template: it calls
`inMemoryMetricExporter` to get `(exporter, ref)`, builds a `MeterProvider` via
`createMeterProvider emptyMaterializedResources defaultSdkMeterProviderOptions {metricExporter
= Just exporter}`, gets a `Meter` via `getMeter provider Telemetry.keiroInstrumentationLibrary`,
builds `metrics <- Telemetry.newKeiroMetrics meter`, records, calls `forceFlushMeterProvider
provider Nothing`, reads `exported <- readIORef ref`, and asserts via the local helpers
`flattenScalarPoints` (returns `[(Text, NumberDataPoint)]` where a scalar is `IntNumber n`)
and `flattenHistogramPoints` (returns `[(Text, count, sum)]`). The no-op test (lines
~206–220) asserts `flattenScalarPoints exported == []` and `flattenHistogramPoints exported
== []` under a `Nothing` handle. You copy both shapes for the workflow instruments, but your
positive test additionally runs a real workflow (against the ephemeral PostgreSQL store the
DB-backed tests use, acquired through `keiro-test-support`'s template-database fixture) so the
instruments are recorded by the runtime, not by direct `record*` calls.


## Plan of Work


Five milestones. Each is independently verifiable; commit after each with the three git
trailers (see Interfaces and Dependencies).


### Milestone 1 — Extend the `Keiro.Telemetry` surface


Scope: add the six workflow instruments, their plumbing, the span helper, and the attribute
keys to `keiro/src/Keiro/Telemetry.hs`. At the end of this milestone the telemetry surface
compiles and exports everything the runtime will call, but nothing records yet (no call
sites wired). This is a pure, additive, self-contained change — the same kind of change
EP-33 made when it first introduced `KeiroMetrics`.

First, the **bespoke attribute keys**. Next to `keiro_events_appended` (line ~188) add:

```haskell
keiro_workflow_name :: AttributeKey Text
keiro_workflow_name = AttributeKey "keiro.workflow.name"

keiro_workflow_id :: AttributeKey Text
keiro_workflow_id = AttributeKey "keiro.workflow.id"

keiro_workflow_step :: AttributeKey Text
keiro_workflow_step = AttributeKey "keiro.workflow.step"
```

Then the **span helper**, next to `withCommandSpan` (after line ~309). It mirrors
`withCommandSpan` exactly: `Internal` kind, `Nothing` tracer is a pass-through, attributes
set from the supplied identifiers. The optional `StepName` lets the same helper wrap either a
whole run (step `Nothing`) or an individual step/resume (step `Just`):

```haskell
{- | Open an @Internal@ span around a workflow run (or a single step/resume when a
'StepName' is supplied), named @"workflow " <> name@. Attributes carry the bespoke
@keiro.workflow.name@, @keiro.workflow.id@, and — when present — @keiro.workflow.step@
keys. Like 'withCommandSpan', a 'Nothing' tracer makes the helper a pass-through, so it
is safe to call unconditionally.
-}
withWorkflowSpan
  :: (MonadUnliftIO m, HasCallStack)
  => Maybe Tracer
  -> WorkflowName
  -> WorkflowId
  -> Maybe StepName
  -> (Maybe Span -> m a)
  -> m a
withWorkflowSpan Nothing _ _ _ body = body Nothing
withWorkflowSpan (Just tracer) name wid mStep body =
  inSpan' tracer spanName args $ \sp -> do
    addAttribute sp (unkey keiro_workflow_name) (unWorkflowName name)
    addAttribute sp (unkey keiro_workflow_id) (unWorkflowId wid)
    case mStep of
      Nothing -> pure ()
      Just s -> addAttribute sp (unkey keiro_workflow_step) (unStepName s)
    body (Just sp)
  where
    spanName = "workflow " <> unWorkflowName name
    args = defaultSpanArguments {kind = Internal}
```

`withWorkflowSpan` references `WorkflowName`/`WorkflowId`/`StepName` and their accessors
(`unWorkflowName`/`unWorkflowId`/`unStepName`). Add an import
`import Keiro.Workflow.Types (WorkflowName (..), WorkflowId (..), StepName (..))` to
`Keiro.Telemetry`. **This is the one cross-module reference this milestone introduces**;
confirm it does not close a cycle by checking `Keiro.Workflow.Types` imports nothing from
`Keiro.Telemetry` (it is a leaf types module — EP-38 M1 defines only newtypes, the codec, and
constants there, with no telemetry dependency). If for any reason `Keiro.Workflow.Types` ever
needed `Keiro.Telemetry`, the fallback is to give `withWorkflowSpan` three `Text` arguments
instead of the typed newtypes (the runtime unwraps before calling); record that in the
Decision Log if you take it. As of this plan the typed signature is cycle-free.

Next, the **name constants**, after `keiroProjectionWaitTimeoutsName` (line ~465):

```haskell
keiroWorkflowStepsExecutedName :: Text
keiroWorkflowStepsExecutedName = "keiro.workflow.steps.executed"
keiroWorkflowStepsReplayedName :: Text
keiroWorkflowStepsReplayedName = "keiro.workflow.steps.replayed"
keiroWorkflowResumedName :: Text
keiroWorkflowResumedName = "keiro.workflow.resumed"
keiroWorkflowJournalLengthName :: Text
keiroWorkflowJournalLengthName = "keiro.workflow.journal.length"
keiroWorkflowAwakeablesPendingName :: Text
keiroWorkflowAwakeablesPendingName = "keiro.workflow.awakeables.pending"
keiroWorkflowActiveName :: Text
keiroWorkflowActiveName = "keiro.workflow.active"
```

Next, the **`KeiroMetrics` fields**. Inside `data KeiroMetrics = KeiroMetrics { … }` (line
~478), after `projectionWaitTimeouts`, add:

```haskell
  , workflowStepsExecuted :: Counter Int64
  , workflowStepsReplayed :: Counter Int64
  , workflowResumed :: Counter Int64
  , workflowActive :: Gauge Int64
  , workflowJournalLength :: Histogram
  , workflowAwakeablesPending :: Gauge Int64
```

Next, the **`newKeiroMetrics` constructor lines**. After `projectionWaitTimeouts' <- …`
(line ~517) add, using the existing local `counterI64` / `gaugeI64` / `histogram` helpers:

```haskell
  workflowStepsExecuted' <- counterI64 keiroWorkflowStepsExecutedName "{step}" "Workflow steps that ran their action (a journal miss)."
  workflowStepsReplayed' <- counterI64 keiroWorkflowStepsReplayedName "{step}" "Workflow steps short-circuited to a recorded result (a journal hit)."
  workflowResumed' <- counterI64 keiroWorkflowResumedName "{workflow}" "Workflow re-invocations performed by the resume worker."
  workflowActive' <- gaugeI64 keiroWorkflowActiveName "{workflow}" "Workflow runs currently in progress in this process."
  workflowJournalLength' <- histogram keiroWorkflowJournalLengthName "{event}" "Journal event count of a workflow at completion."
  workflowAwakeablesPending' <- gaugeI64 keiroWorkflowAwakeablesPendingName "{awakeable}" "Awakeables awaiting an external signal."
```

and the matching record assignments inside the returned `KeiroMetrics { … }` (after
`projectionWaitTimeouts = projectionWaitTimeouts'`, line ~533):

```haskell
      , workflowStepsExecuted = workflowStepsExecuted'
      , workflowStepsReplayed = workflowStepsReplayed'
      , workflowResumed = workflowResumed'
      , workflowActive = workflowActive'
      , workflowJournalLength = workflowJournalLength'
      , workflowAwakeablesPending = workflowAwakeablesPending'
```

Finally, the **public `record*` helpers**, after `recordProjectionWaitTimeouts` (line ~591),
reusing the internal `recordCounter` / `recordGaugeI64` / `recordHistogram` dispatchers that
already no-op on `Nothing`:

```haskell
recordWorkflowStepExecuted :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowStepExecuted = recordCounter workflowStepsExecuted
recordWorkflowStepReplayed :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowStepReplayed = recordCounter workflowStepsReplayed
recordWorkflowResumed :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowResumed = recordCounter workflowResumed
recordWorkflowActive :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowActive = recordGaugeI64 workflowActive
recordWorkflowJournalLength :: (MonadIO m) => Maybe KeiroMetrics -> Double -> m ()
recordWorkflowJournalLength = recordHistogram workflowJournalLength
recordWorkflowAwakeablesPending :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowAwakeablesPending = recordGaugeI64 workflowAwakeablesPending
```

Add every new public name to the module **export list** (lines ~58–94): the six
`keiroWorkflow*Name` constants, the six `recordWorkflow*` helpers, `withWorkflowSpan` (in the
`-- * Span helpers` section near `withCommandSpan`), and the three `keiro_workflow_*`
attribute keys (in the `-- * Bespoke keiro 'AttributeKey's` section near `keiro_stream_name`).

Acceptance for M1: `cabal build keiro` succeeds. A throwaway `ghci` check (optional) confirms
`newKeiroMetrics` typechecks with the six new fields. No behavior change yet — nothing calls
the new helpers.


### Milestone 2 — Thread the handles through `WorkflowRunOptions` and instrument the handler


Scope: add `metrics :: Maybe KeiroMetrics` and `tracer :: Maybe Tracer` fields to EP-41's
`WorkflowRunOptions` (in `keiro/src/Keiro/Workflow.hs`), default both to `Nothing`, and wire
the four handler recording sites. At the end of this milestone, running a workflow with a
`Just metrics` handle records `steps.executed`/`steps.replayed`/`active`/`journal.length`,
and opens a span when a `Just tracer` is supplied; running with `defaultWorkflowRunOptions`
(both `Nothing`) behaves exactly as before.

Edit `WorkflowRunOptions` (the record EP-41 added around lines 490–503 of
`keiro/src/Keiro/Workflow.hs`) to add the two fields after `pageSize`:

```haskell
data WorkflowRunOptions = WorkflowRunOptions
  { snapshotPolicy :: !(SnapshotPolicy WorkflowState)
  , pageSize :: !Int32
  , metrics :: !(Maybe KeiroMetrics)
  -- ^ EP-44: when 'Just', the runtime records the @keiro.workflow.*@ instruments
  --   (steps executed/replayed, active count, journal length). 'Nothing' is the no-op
  --   default.
  , tracer :: !(Maybe Tracer)
  -- ^ EP-44: when 'Just', the runtime opens a @workflow <name>@ 'Internal' span around the
  --   run. 'Nothing' runs the body unwrapped.
  }
  deriving stock (Generic)

defaultWorkflowRunOptions :: WorkflowRunOptions
defaultWorkflowRunOptions = WorkflowRunOptions
  { snapshotPolicy = Never
  , pageSize = 256
  , metrics = Nothing
  , tracer = Nothing
  }
```

Add the import `import Keiro.Telemetry (KeiroMetrics, Tracer, withWorkflowSpan,
recordWorkflowStepExecuted, recordWorkflowStepReplayed, recordWorkflowActive,
recordWorkflowJournalLength)` to `keiro/src/Keiro/Workflow.hs`. This is the
`Keiro.Workflow → Keiro.Telemetry` edge — acyclic, as verified in the Decision Log.

Now wire `runWorkflowWith` (the handler body EP-41 parameterised). Pull the two handles out
once at the top: `let mMetrics = options ^. #metrics; mTracer = options ^. #tracer`.

- **Run bracket + span + active gauge.** Wrap the entire interpreted body in
  `withWorkflowSpan mTracer name wid Nothing $ \_sp -> …`. Around that, maintain the
  process-wide live count. The simplest faithful implementation: keep a module-level
  `activeCountRef :: IORef Int64` (a top-level `unsafePerformIO (newIORef 0)` with
  `{-# NOINLINE #-}`, the standard pattern for a process-global counter), and bracket the run
  with `Effectful.Exception.bracket_`:

  ```haskell
  bracket_
    (liftIO (atomicModifyIORef' activeCountRef (\n -> (n + 1, ()))) >> sampleActive)
    (liftIO (atomicModifyIORef' activeCountRef (\n -> (n - 1, ()))) >> sampleActive)
    (withWorkflowSpan mTracer name wid Nothing $ \_sp -> runBody)
    where
      sampleActive = liftIO (readIORef activeCountRef) >>= recordWorkflowActive mMetrics
  ```

  Recording the gauge on **both** entry and exit means the exported last-value reflects the
  true live count whether the run is mid-flight or finished. (If you prefer to avoid a
  process-global `IORef`, an equivalent is acceptable: record `+`/`-` deltas through an
  UpDownCounter — but that instrument is not in `newKeiroMetrics`'s helper set, so the gauge
  + global-counter approach is the path of least change. Record the choice in the Decision
  Log if you deviate.)

- **Step miss (execution).** In the `Step name action` handler branch, on the miss path
  (after `action` runs and the journal append succeeds), add
  `recordWorkflowStepExecuted mMetrics 1`.

- **Step hit (replay).** On the hit path (the recorded result is returned without running
  `action`), add `recordWorkflowStepReplayed mMetrics 1`.

  The same two recordings apply to the `awaitStep` hit/miss branches at your discretion: an
  `awaitStep` hit (the wake source already resolved the step) is a replay, and arming on a
  miss is not a step execution (no user action ran), so record `replayed` on the `awaitStep`
  hit and record nothing on the `awaitStep` arm-and-suspend miss. Document this in a code
  comment so the executed/replayed semantics are unambiguous.

- **Journal length at completion.** After `runWorkflowWith` appends `WorkflowCompleted` (the
  completion branch EP-38 M3 describes), it knows the journal length. Compute it as the size
  of the in-memory journal map plus one (the `WorkflowCompleted` event), or re-read the
  stream version — whichever EP-38's completion code already has in hand; the in-memory map
  size is cheapest. Record `recordWorkflowJournalLength mMetrics (fromIntegral journalLen)`.
  Record it only on the `Completed` path, not the `Suspended` path (a suspended workflow has
  not finished, so its journal length is not yet meaningful).

Acceptance for M2: `cabal build keiro` green. All existing EP-38/EP-41 workflow tests still
pass under `cabal test keiro` (the new fields default to `Nothing`, so default-options runs
are unchanged). The new instruments are exercised in M5.


### Milestone 3 — Instrument the resume worker and the awakeable gauge


Scope: record `keiro.workflow.resumed` once per re-invocation in EP-42's resume worker, and
`keiro.workflow.awakeables.pending` once per poll pass from EP-40's `countPendingAwakeables`.
At the end of this milestone the resume worker, when given a `Just metrics` handle, reports
how often it re-invokes workflows and how many awakeables are pending.

Edit `keiro/src/Keiro/Workflow/Resume.hs` (EP-42's module). Its worker entry point should
accept a `Maybe KeiroMetrics` argument following the exact convention `runTimerWorker` uses
(`keiro/src/Keiro/Timer.hs` threads `Maybe KeiroMetrics` as its first argument; mirror that).
If EP-42 already threads `Maybe KeiroMetrics` (it may, since the MasterPlan asked EP-38 to
thread the handle into worker entry points), reuse it; otherwise add the argument. Import
`recordWorkflowResumed` and `recordWorkflowAwakeablesPending` from `Keiro.Telemetry` and
`countPendingAwakeables` from `Keiro.Workflow.Awakeable.Schema`.

- **`resumed` counter.** In the loop body, immediately after the worker calls
  `runWorkflowWith` to re-invoke a discovered unfinished workflow, add
  `recordWorkflowResumed mMetrics 1`. One increment per re-invocation. (If the worker
  re-invokes a batch in one pass, increment once per workflow, not once per pass.) When the
  resume worker constructs the `WorkflowRunOptions` it passes to `runWorkflowWith`, it should
  forward its own `metrics`/`tracer` handles into that record too, so a resumed run also
  records its steps and opens its span — i.e. set `options { metrics = mMetrics, tracer =
  mTracer }`.

- **`awakeables.pending` gauge.** Once per poll pass (the same cadence the timer worker
  records its backlog gauge), run `pending <- countPendingAwakeables` and
  `recordWorkflowAwakeablesPending mMetrics (fromIntegral pending)`. Place it alongside the
  `findUnfinishedWorkflowIds` discovery query so both run on the same `Store` per pass.

Acceptance for M3: `cabal build keiro` green. The resume worker compiles with the metrics
handle threaded; the awakeable gauge is sampled per pass. Exercised in M5.

Provisional fallback if EP-42/EP-40 have not landed yet: see "Idempotence and Recovery". In
that case, M3 records only what exists, marks the unavailable instrument as "wired in a later
revision" in Progress, and the M5 test asserts only the available instruments. The MasterPlan
explicitly permits this late-plan provisional path.


### Milestone 4 — Update the OpenTelemetry semconv audit


Scope: extend `docs/research/opentelemetry-semconv-audit.md` so the workflow instruments and
span are catalogued exactly as the outbox/inbox/timer/projection instruments are. This is the
audit EP-25/EP-33 established and the MasterPlan's Telemetry integration point requires you to
update. At the end of this milestone the audit names every new instrument's name/unit/kind/
recording-site and the new span + attribute keys.

In the `## Metrics` section, after the `### Projection` subsection (before the `### Metrics
compliance table`), add:

```text
### Workflow

- **`keiro.workflow.steps.executed`** — unit `{step}`, **Counter** (`Int64`). Recorded by
  the workflow handler on a step *miss* (the action ran and was journaled)
  (`recordWorkflowStepExecuted`). Description: "Workflow steps that ran their action (a
  journal miss)." Semconv alignment: none (durable-execution-specific).
- **`keiro.workflow.steps.replayed`** — unit `{step}`, **Counter** (`Int64`). Recorded by
  the workflow handler on a step *hit* (the recorded result was returned without running the
  action) (`recordWorkflowStepReplayed`). Description: "Workflow steps short-circuited to a
  recorded result (a journal hit)." Semconv alignment: none.
- **`keiro.workflow.resumed`** — unit `{workflow}`, **Counter** (`Int64`). Recorded by the
  resume worker once per re-invocation of a discovered unfinished workflow
  (`recordWorkflowResumed`). Description: "Workflow re-invocations performed by the resume
  worker." Semconv alignment: none.
- **`keiro.workflow.active`** — unit `{workflow}`, **Gauge** (`Int64`). Recorded by the
  workflow handler on run entry and exit with the process-wide live-run count
  (`recordWorkflowActive`). Description: "Workflow runs currently in progress in this
  process." Semconv alignment: none (level gauge, like the backlog gauges).
- **`keiro.workflow.journal.length`** — unit `{event}`, **Histogram** (`Double`). Recorded
  by the workflow handler once per completion with the journal event count
  (`recordWorkflowJournalLength`). Description: "Journal event count of a workflow at
  completion." Semconv alignment: none (distribution, like `keiro.timer.fire.lag`).
- **`keiro.workflow.awakeables.pending`** — unit `{awakeable}`, **Gauge** (`Int64`).
  Recorded by the resume worker each poll pass from `countPendingAwakeables`
  (`recordWorkflowAwakeablesPending`). Description: "Awakeables awaiting an external signal."
  Semconv alignment: none (queue depth).
```

Append the six rows to the `### Metrics compliance table`:

```text
| keiro.workflow.steps.executed    | {step}     | Counter   | workflow handler, on step miss            | none                                                |
| keiro.workflow.steps.replayed    | {step}     | Counter   | workflow handler, on step hit             | none                                                |
| keiro.workflow.resumed           | {workflow} | Counter   | resume worker, per re-invocation          | none                                                |
| keiro.workflow.active            | {workflow} | Gauge     | workflow handler, on run entry/exit       | none (level)                                        |
| keiro.workflow.journal.length    | {event}    | Histogram | workflow handler, on completion           | none (distribution)                                 |
| keiro.workflow.awakeables.pending| {awakeable}| Gauge     | resume worker, per poll pass              | none (queue depth)                                  |
```

In the span sections, add a `## Workflow run` per-site section after `## Timer fire`:

```text
## Workflow run

**File:** `src/Keiro/Workflow.hs` — `runWorkflowWith` (the handler body); the per-step
span uses the same helper with a `Just stepName`.

**Span name:** `workflow <workflow-name>`.

**Span kind:** `Internal`. The workflow runs entirely in-process; no network boundary is
crossed by the runtime itself.

**Attributes (keiro-specific; spec defines no "workflow" span):**

- `keiro.workflow.name` — bespoke key; value: the `WorkflowName`.
- `keiro.workflow.id` — bespoke key; value: the `WorkflowId`.
- `keiro.workflow.step` — bespoke key; value: the `StepName`, set only when the span wraps a
  single step or a resume (omitted on the whole-run span).

**Gap as of 2026-06-03:** opened by EP-44 via `Keiro.Telemetry.withWorkflowSpan`, threaded
through `WorkflowRunOptions.tracer`.
```

And add the row to the span `## Compliance table`:

```text
| Workflow run        | `workflow <name>`              | Internal | n/a (bespoke)                                | Gap → EP-44             |
```

Finally, update the `## Metrics` section's lead paragraph that says "This section catalogues
the fourteen metric instruments" — change "fourteen" to "twenty" and add a sentence noting the
six `keiro.workflow.*` instruments were added by EP-44.

Acceptance for M4: the audit file contains a `### Workflow` metrics subsection, six new
compliance-table rows, a `## Workflow run` span section, the span compliance-table row, and
the three bespoke attribute keys named. The instrument names/units/descriptions match
`newKeiroMetrics` character-for-character (the same discipline the existing sections hold).


### Milestone 5 — In-memory-exporter validation tests


Scope: add tests to `keiro/test/Main.hs` that run a real workflow with metrics wired and
assert the workflow instruments came out of the in-memory metric exporter with the right
values, plus a no-op test. At the end of this milestone `cabal test keiro` proves the
instrumentation works end to end, not merely that it compiles.

Add a describe-block `"Keiro.Workflow observability"` modelled on the existing
`"Keiro.Telemetry metrics"` block (lines ~174–220) but running a real workflow against the
ephemeral store (use the same template-database fixture the other DB-backed describe-blocks
use — `around (withFreshStore fixture)` per the project memory; do not migrate per-example).

Positive test ("records workflow instruments through an SDK meter"):

1. Build the in-memory metric exporter, `MeterProvider`, `Meter`, and
   `metrics <- Telemetry.newKeiroMetrics meter`, exactly as the existing metrics test does.
2. Define a two-step demo workflow whose steps each increment a shared `IORef` counter and
   return its value (the same `demo` shape EP-38's tests use).
3. Run it once with `runWorkflowWith (defaultWorkflowRunOptions { metrics = Just metrics })
   (WorkflowName "obs") wid demo` inside `Store.runStoreIO storeHandle`. Both steps miss →
   two executions.
4. Run it **again** with the same `wid` and the same options. Both steps hit → two replays.
5. `forceFlushMeterProvider provider Nothing`; `exported <- readIORef ref`; flatten.
6. Assert:
   - `lookup "keiro.workflow.steps.executed" scalars == Just (IntNumber 2)` (two fresh
     steps on the first run; the second run executed none).
   - `lookup "keiro.workflow.steps.replayed" scalars == Just (IntNumber 2)` (two
     short-circuits on the replay run).
   - the `keiro.workflow.journal.length` histogram recorded two observations (one per
     completed run); assert the count via `flattenHistogramPoints` — e.g.
     `[ c | (n, c, _) <- hists, n == "keiro.workflow.journal.length" ] == [2]`.
   - `lookup "keiro.workflow.active" scalars == Just (IntNumber 0)` (both runs finished, so
     the live count returned to zero).

Resume test ("records a resume when the worker re-invokes"): if EP-42's resume worker is
available, suspend a workflow on an awakeable (or `awaitStep` with a never-arming action so it
returns `Suspended` without a wake source — EP-38's M3(b) test does exactly this), then run
one resume-worker pass with `Just metrics`; assert `lookup "keiro.workflow.resumed" scalars`
is `Just (IntNumber n)` with `n >= 1`. In the same setup, register one pending awakeable
(EP-40's API) before the pass and assert `lookup "keiro.workflow.awakeables.pending" scalars
== Just (IntNumber 1)`. If EP-42/EP-40 are not yet present, mark this test pending and
reconcile in a revision (see Idempotence and Recovery).

No-op test ("records nothing through a Nothing handle"): run the same demo workflow with
`defaultWorkflowRunOptions` (metrics `Nothing`) against a fresh exporter; flush; assert
`flattenScalarPoints exported == []` **for the workflow instruments** — concretely, assert
each `lookup "keiro.workflow.*" scalars == Nothing` and the workflow histogram is absent. (Do
not assert the whole list is empty if the workflow happens to share a provider with other
recordings; use a dedicated provider for this test as the existing no-op test does, so the
strict `== []` assertion holds.)

Acceptance for M5: `cabal test keiro` green; the workflow-observability describe-block passes.
Capture the green transcript in the Validation and Acceptance section's final revision.


## Concrete Steps


Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted. The repo builds with
`cabal` under a Nix-provided GHC.

```bash
# M1 — extend the telemetry surface
$EDITOR keiro/src/Keiro/Telemetry.hs    # attr keys, withWorkflowSpan, name constants,
                                         # KeiroMetrics fields, newKeiroMetrics lines,
                                         # record* helpers, export list
cabal build keiro

# M2 — thread handles through WorkflowRunOptions + instrument the handler
$EDITOR keiro/src/Keiro/Workflow.hs      # add metrics/tracer fields + 4 recording sites
cabal build keiro
cabal test keiro                          # existing EP-38/41 tests must still pass

# M3 — resume worker + awakeable gauge
$EDITOR keiro/src/Keiro/Workflow/Resume.hs   # recordWorkflowResumed + recordWorkflowAwakeablesPending
cabal build keiro

# M4 — audit doc
$EDITOR docs/research/opentelemetry-semconv-audit.md   # ### Workflow + ## Workflow run + rows

# M5 — validation tests
$EDITOR keiro/test/Main.hs                # "Keiro.Workflow observability" describe-block
cabal test keiro
```

Expected `cabal build keiro` tail after each build milestone:

```text
[N of M] Compiling Keiro.Telemetry  ( ... )
[..] Compiling Keiro.Workflow      ( ... )
Linking ...
```

Expected `cabal test keiro` tail at M5 (the relevant group):

```text
Keiro.Workflow observability
  records workflow instruments through an SDK meter [✔]
  records a resume when the worker re-invokes [✔]
  records nothing through a Nothing handle [✔]

All N tests passed
```


## Validation and Acceptance


The plan is accepted when `cabal test keiro` is green and the workflow instruments are
observable through the in-memory exporter, not merely compiled:

- **Executed vs. replayed.** After a first run of a two-step workflow with `Just metrics`,
  the exporter reports `keiro.workflow.steps.executed` = 2 and (after a second same-id run)
  `keiro.workflow.steps.replayed` = 2. This is the headline operability signal: real work vs.
  replayed history.
- **Active gauge.** After both runs finish, `keiro.workflow.active` reads 0 — the live count
  returned to zero. (A mid-flight assertion is not required; the gauge being recorded on
  entry and exit is what makes the steady-state value correct.)
- **Journal length.** The `keiro.workflow.journal.length` histogram recorded one observation
  per completed run (count 2 across the two runs above).
- **Resume + pending awakeables** (when EP-42/EP-40 are present). One resume-worker pass over
  a suspended workflow increments `keiro.workflow.resumed`, and a pending awakeable makes
  `keiro.workflow.awakeables.pending` read 1.
- **No-op.** The same workflow run with `defaultWorkflowRunOptions` (metrics `Nothing`)
  exports **no** `keiro.workflow.*` points — proving the no-op idiom holds end to end and an
  application without OpenTelemetry is unaffected.
- **Audit doc.** `docs/research/opentelemetry-semconv-audit.md` catalogues all six
  instruments and the workflow span; the names match `newKeiroMetrics` character-for-character.

Paste the green `cabal test keiro` transcript (the `Keiro.Workflow observability` group) into
this section in the final revision as evidence.

**Evidence (2026-06-03):** all acceptance bullets verified — `steps.executed` = 2,
`steps.replayed` = 2, `journal.length` histogram count = 2, `active` = 0 after both runs,
`resumed` = 1 and `awakeables.pending` = 1 after one resume pass, and the `Nothing`-handle
run exported no points (`flattenScalarPoints == []`, `flattenHistogramPoints == []`).

```text
Keiro.Workflow observability
  records workflow instruments through an SDK meter [✔]
  records a resume and the pending-awakeable count when the worker re-invokes [✔]
  records nothing through a Nothing handle [✔]

Finished in 15.8904 seconds
133 examples, 0 failures
Test suite keiro-test: PASS
```


## Idempotence and Recovery


Every step is additive and re-runnable. Re-editing `Keiro.Telemetry.hs` is idempotent (the
new fields/constants/helpers are uniquely named; a second pass is a no-op once present).
Adding the two `WorkflowRunOptions` fields with `Nothing` defaults cannot break existing call
sites (every existing run uses `defaultWorkflowRunOptions` or sets only `snapshotPolicy`/
`pageSize`, leaving the new fields at their defaults). No migration and no new dependency are
introduced, so there is nothing to roll back at the database or build-graph level.

**If a soft-dependency plan has not landed when you implement this one** (EP-42's resume
worker `keiro/src/Keiro/Workflow/Resume.hs`, EP-40's `countPendingAwakeables`, EP-43's child
spans): the MasterPlan explicitly permits EP-44 to instrument only the call sites that exist
and treat the rest as provisional, reconciling in a later revision (the same pattern
MasterPlan 4 used for EP-37). Concretely:

- If `Keiro.Workflow/Resume.hs` is absent, implement M1/M2/M4/M5's executed/replayed/active/
  journal-length surface fully (those depend only on EP-38/EP-41), mark the `resumed` and
  `awakeables.pending` Progress items "wired in a later revision", and have the M5 resume test
  `pending` with a note. When EP-42 lands, a one-paragraph revision wires `recordWorkflowResumed`
  and flips the test on.
- If `countPendingAwakeables` is absent (EP-40 not landed), the `awakeables.pending` gauge has
  no source; defer it the same way and note it.

This keeps the plan re-startable from the file alone: a future contributor reads Progress,
sees which instruments are live vs. deferred, and knows exactly what a reconciliation revision
must add.


## Interfaces and Dependencies


Libraries/modules used and why: `hs-opentelemetry-api` (the `Meter`/`Counter`/`Gauge`/
`Histogram`/`Tracer`/`Span` surface and `inSpan'`/`addAttribute`, already imported by
`Keiro.Telemetry`); `Keiro.Telemetry` (the surface this plan extends and the workflow handler
imports); `Keiro.Workflow` / `Keiro.Workflow.Types` (the runtime and its newtypes the span
helper references); `Keiro.Workflow.Resume` (EP-42, the resume worker recording site);
`Keiro.Workflow.Awakeable.Schema` (EP-40's `countPendingAwakeables`); and, in tests only,
`hs-opentelemetry-sdk` + `hs-opentelemetry-exporter-in-memory` (already test deps). **No new
package dependency and no migration are added.**

**Cycle safety (the MasterPlan's explicit requirement).** The handles are threaded by adding
`metrics :: Maybe KeiroMetrics` and `tracer :: Maybe Tracer` to `WorkflowRunOptions` in
`Keiro.Workflow` — the canonical home EP-41 designated. This is cycle-safe because the import
edge is `Keiro.Workflow → Keiro.Telemetry` only: `Keiro.Telemetry` imports `Keiro.Inbox.Kafka`,
`Keiro.Integration.Event`, `Keiro.Outbox.Kafka`, `Keiro.Prelude` and **no** workflow module
(verified by `grep "^import Keiro" keiro/src/Keiro/Telemetry.hs`). The one new cross-edge
`Keiro.Telemetry → Keiro.Workflow.Types` (for the `withWorkflowSpan` newtype arguments) is to
a leaf types module that imports nothing from `Keiro.Telemetry`, so it is also acyclic. The
plan therefore threads the handle via `WorkflowRunOptions` and does **not** fall back to a
bare positional argument. (If a future change ever made `Keiro.Workflow.Types` depend on
`Keiro.Telemetry`, the documented fallback is to give `withWorkflowSpan` three `Text`
arguments instead of the typed newtypes.)

Signatures and surface that must exist at the end of each milestone (full module paths):

```haskell
-- Keiro.Telemetry (after M1) — new exports
keiro_workflow_name, keiro_workflow_id, keiro_workflow_step :: AttributeKey Text
withWorkflowSpan
  :: (MonadUnliftIO m, HasCallStack)
  => Maybe Tracer -> WorkflowName -> WorkflowId -> Maybe StepName
  -> (Maybe Span -> m a) -> m a
keiroWorkflowStepsExecutedName, keiroWorkflowStepsReplayedName, keiroWorkflowResumedName,
  keiroWorkflowJournalLengthName, keiroWorkflowAwakeablesPendingName,
  keiroWorkflowActiveName :: Text
data KeiroMetrics = KeiroMetrics { {- … 14 existing … -}
  , workflowStepsExecuted :: Counter Int64
  , workflowStepsReplayed :: Counter Int64
  , workflowResumed       :: Counter Int64
  , workflowActive        :: Gauge Int64
  , workflowJournalLength :: Histogram
  , workflowAwakeablesPending :: Gauge Int64
  }
recordWorkflowStepExecuted, recordWorkflowStepReplayed, recordWorkflowResumed,
  recordWorkflowActive, recordWorkflowAwakeablesPending
    :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowJournalLength :: (MonadIO m) => Maybe KeiroMetrics -> Double -> m ()

-- Keiro.Workflow (after M2) — WorkflowRunOptions gains two fields
data WorkflowRunOptions = WorkflowRunOptions
  { snapshotPolicy :: !(SnapshotPolicy WorkflowState)
  , pageSize       :: !Int32
  , metrics        :: !(Maybe KeiroMetrics)   -- EP-44, defaults to Nothing
  , tracer         :: !(Maybe Tracer)         -- EP-44, defaults to Nothing
  }
-- defaultWorkflowRunOptions sets metrics = Nothing, tracer = Nothing.
-- runWorkflowWith records executed/replayed/active/journal.length and opens the span.

-- Keiro.Workflow.Resume (after M3) — the resume worker records:
--   recordWorkflowResumed metrics 1            -- once per re-invocation
--   recordWorkflowAwakeablesPending metrics n  -- once per poll pass, n = countPendingAwakeables
```

Downstream consumer: EP-45 (worked example + guide) references the `keiro.workflow.*`
instruments and the workflow span when documenting how to operate the runtime; this plan's
audit-doc update and instrument names are the source EP-45 cites.

Every commit while implementing this plan must carry all three git trailers:

```text
MasterPlan: docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md
ExecPlan: docs/plans/44-workflow-observability-spans-and-metrics.md
Intention: intention_01kt6y4cb6eqz9mq48kf2xw8n1
```
