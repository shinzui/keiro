---
id: 35
slug: instrument-the-outbox-and-inbox-workers-with-metrics
title: "Instrument the outbox and inbox workers with metrics"
kind: exec-plan
created_at: 2026-06-03T04:20:10Z
intention: "intention_01kt5v38ztez0tt5b63nr7gbnx"
master_plan: "docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md"
---

# Instrument the outbox and inbox workers with metrics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is a Haskell event-sourcing framework backed by PostgreSQL. It ships two
background "workers" that move integration events between services: the
**outbox publisher** (drains rows the application has queued for publishing to a
message broker such as Kafka) and the **inbox** (records each incoming
integration event exactly once so duplicate redeliveries do not re-run the
handler). Today these workers emit OpenTelemetry **spans** — per-operation
traces — but no **metrics**. A metric, in OpenTelemetry, is a numeric
measurement the application periodically exports to a metrics backend; operators
alert on metrics (for example, "page me when the outbox backlog exceeds 1000" or
"alert when dead-lettered messages climb"), whereas spans are for tracing one
request through the system.

After this change, an application that wires an OpenTelemetry **meter** (the
object that creates metric instruments) into keiro's outbox and inbox will see,
on whatever metrics exporter it configured, eight numbers that describe the
operational health of those two workers:

- `keiro.outbox.backlog` — how many outbox rows are waiting to be published
  (a **gauge**: a point-in-time value that can go up or down).
- `keiro.outbox.published` — how many rows were successfully published
  (a **counter**: a value that only ever increases).
- `keiro.outbox.retried` — how many publish attempts failed and will be retried.
- `keiro.outbox.deadlettered` — how many rows exhausted their retries and were
  parked for operator inspection.
- `keiro.inbox.processed` — how many incoming events ran their handler for the
  first time.
- `keiro.inbox.duplicates` — how many incoming events were recognized as
  duplicate redeliveries and skipped.
- `keiro.inbox.failed` — how many incoming events were rejected because a prior
  delivery had recorded a permanent failure.
- `keiro.inbox.backlog` — how many inbox rows are stuck in a non-terminal state
  (a gauge).

You can see it working by running the keiro test suite. Two new tests drive a
real outbox publish pass and a real inbox double-delivery against an ephemeral
PostgreSQL database with a real OpenTelemetry SDK meter wired to an **in-memory
metric exporter** (a test exporter that collects exported metrics into a list
you can inspect). The tests force a metrics flush and assert that the counters
and gauges above carry the expected values. The exact command is `cabal test
keiro-test` from the repository root; expected output is shown in
[Validation and Acceptance](#validation-and-acceptance).

This plan does **not** define the metrics surface itself. That is owned by its
hard dependency, EP-33
(`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`),
which adds a `KeiroMetrics` record of pre-built instruments, a builder
`newKeiroMetrics`, the recording helpers, the canonical `keiro.*` instrument
names, and the in-memory-metric test harness. This plan **consumes** that
surface: it threads a `Maybe KeiroMetrics` handle into the two workers and calls
EP-33's recording helpers at the right places. EP-33 must be implemented and
merged before this plan can be implemented.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Confirm EP-33 is merged and read the exact `KeiroMetrics` / `newKeiroMetrics` / recording-helper contract it shipped (reconciled in the Decision Log: helper is `recordInboxDuplicates` plural, all helpers take `Int64`, harness extractor is `flattenScalarPoints`). (2026-06-03)
- [x] M1a: ~~Add a `metrics` field to `OutboxPublishOptions`~~ — **blocked by a real import cycle** (`Telemetry → Outbox.Kafka → Outbox.Types`). Used the plan's documented fallback: pass `Maybe KeiroMetrics` as a trailing argument to `publishClaimedOutbox` in `Keiro.Outbox` instead. (2026-06-03)
- [x] M1a: Add a backlog-count query `countOutboxBacklog` to `keiro/src/Keiro/Outbox/Schema.hs` and export it from `Keiro.Outbox`. (2026-06-03)
- [x] M1b: In `publishClaimedOutbox` (`keiro/src/Keiro/Outbox.hs`), record the backlog gauge once per pass (after the claim) and the published / retried / deadlettered counters from the final `OutboxPublishSummary`. (2026-06-03)
- [x] M1c: Add the outbox metrics test in `keiro/test/Main.hs`: wire an SDK MeterProvider + in-memory metric exporter (reuse EP-33's harness), run two publish passes that exercise published=1 / retried=1 / deadlettered=1, force-flush, and assert all four outbox instruments. (2026-06-03)
- [x] M2a: Add a leading `Maybe KeiroMetrics` parameter to `runInboxTransaction` / `runInboxTransactionWithKey` in `keiro/src/Keiro/Inbox.hs` and record processed / duplicates / failed from the `InboxResult`. (2026-06-03)
- [x] M2a: Add a backlog-count query `countInboxBacklog` to `keiro/src/Keiro/Inbox/Schema.hs`, export it from `Keiro.Inbox`, and record the `keiro.inbox.backlog` gauge. (2026-06-03)
- [x] M2b: Add the inbox metrics test in `keiro/test/Main.hs`: deliver the same `(source, message_id)` twice, force-flush, and assert `keiro.inbox.processed` = 1 and `keiro.inbox.duplicates` = 1. (2026-06-03)
- [x] Update every existing `runInboxTransaction` call site (11 in `keiro/test/Main.hs`) to pass `Nothing` for the new metrics argument; likewise every `publishClaimedOutbox` call site (the cycle forced a trailing-arg change those didn't anticipate). (2026-06-03)
- [x] Add the minimal one-line `operations.md` pointer and leave the full catalogue to EP-37. (2026-06-03)
- [x] Run `cabal test keiro-test` from the repo root; all 88 examples pass; transcript in Concrete Steps / Validation. (2026-06-03)
- [x] Write the Outcomes & Retrospective entry and reconcile surface differences with EP-33. (2026-06-03)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03 (authoring): The outbox publisher already computes everything the
  four outbox instruments need. `publishClaimedOutbox` returns an
  `OutboxPublishSummary` with `published`, `retried`, and `dead` fields
  (`keiro/src/Keiro/Outbox/Types.hs`), so the published/retried/deadlettered
  counters can be derived from the summary at the end of a pass without
  recomputing anything. Only the backlog gauge needs a new `SELECT COUNT(*)`.
- 2026-06-03 (authoring): The inbox already classifies each delivery into the
  exact buckets the three inbox counters need. `runInboxTransactionWithKey`
  returns an `InboxResult a` whose constructors are `InboxProcessed`,
  `InboxDuplicate`, `InboxInProgress`, and `InboxPreviouslyFailed`
  (`keiro/src/Keiro/Inbox/Types.hs`). `InboxProcessed` → processed,
  `InboxDuplicate` → duplicates, `InboxPreviouslyFailed` → failed. The plan
  records nothing for `InboxInProgress` (it is reserved for a future async path
  and never escapes the v1 single-transaction wrapper).
- 2026-06-03 (authoring): The SDK in-memory metric exporter
  (`OpenTelemetry.Exporter.InMemory.Metric.inMemoryMetricExporter`,
  `hs-opentelemetry-exporter-in-memory`) collects exported batches into an
  `IORef [ResourceMetricsExport]`. Metrics are only pushed into that ref when the
  meter provider exports — either at shutdown or on an explicit force-flush — so
  the tests **must** call `forceFlushMeterProvider` (or shut the provider down)
  before reading the ref, exactly the way the existing span tests call
  `shutdownTracerProvider` before reading the span ref. Evidence: the SDK's
  `meterProviderForceFlush` calls `collectResourceMetrics` then
  `metricExporterExport` (`OpenTelemetry.MeterProvider`).

- 2026-06-03 (implementing): **The outbox import cycle is real**, confirming the
  MasterPlan's 2026-06-03 "drafting EP-35" warning. `Keiro.Telemetry` imports
  `Keiro.Outbox.Kafka`, which imports `Keiro.Outbox.Types`. Putting a
  `metrics :: Maybe KeiroMetrics` field on `OutboxPublishOptions` (in
  `Keiro.Outbox.Types`) would close the loop `Outbox.Types → Telemetry →
  Outbox.Kafka → Outbox.Types`. EP-33 left `KeiroMetrics` in `Keiro.Telemetry`
  (it did not relocate the type to a leaf module), so the options-record approach
  this plan's first Decision Log entry preferred is not available without an EP-33
  change. Used the plan's documented fallback instead: `publishClaimedOutbox`
  takes `Maybe KeiroMetrics` as a trailing argument (in `Keiro.Outbox`, which
  already imports `Keiro.Telemetry`). The inbox has no such cycle
  (`Keiro.Telemetry` imports `Keiro.Inbox.Kafka`, not `Keiro.Inbox`), so the
  inbox handle is a normal added parameter as planned.
- 2026-06-03 (implementing): EP-33's shipped recording helpers differ slightly in
  spelling from this plan's assumed intent names: the duplicate counter helper is
  `recordInboxDuplicates` (plural). All `record*` helpers take `Int64`, so the
  `Int` backlog counts go through `fromIntegral`. The helpers used here are
  `recordOutboxBacklog` / `recordOutboxPublished` / `recordOutboxRetried` /
  `recordOutboxDeadlettered` and `recordInboxProcessed` / `recordInboxDuplicates`
  / `recordInboxFailed` / `recordInboxBacklog`.
- 2026-06-03 (implementing): EP-33's in-memory metric harness exposes the
  extractor `flattenScalarPoints :: [ResourceMetricsExport] -> [(Text,
  NumberValue)]` (and `flattenHistogramPoints`). The tests reuse it with `lookup`
  rather than the inline traversal the plan sketched, and obtain the meter via
  `getMeter provider Telemetry.keiroInstrumentationLibrary`.
- 2026-06-03 (implementing): A **synchronous gauge recorded with value `0` does
  emit a data point** under the SDK in-memory exporter —
  `lookup "keiro.outbox.backlog" scalars == Just (IntNumber 0)` after a pass that
  leaves no backlog. This resolves the plan's open question about zero-delta
  series: a recorded zero gauge is observable as `Just 0`, not `Nothing`. (A
  counter that is only ever `add 0` was avoided in the test by exercising
  `retried` with a real non-zero value across two passes, so the `retried`
  assertion is unambiguously `Just (IntNumber 1)`.)

(Add further discoveries here during implementation.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Thread the outbox metrics handle through `OutboxPublishOptions` (a
  new `metrics :: !(Maybe KeiroMetrics)` field) rather than as a new positional
  argument to `publishClaimedOutbox`.
  Rationale: The existing tracer handle already lives on `OutboxPublishOptions`
  as `tracer :: !(Maybe Tracer)` (`keiro/src/Keiro/Outbox/Types.hs`). Putting the
  meter handle in the same record keeps the publisher's call shape stable
  (`publishClaimedOutbox publish options`), matches the established opt-in
  convention, and means existing callers that build options from
  `defaultPublishOptions` get the no-op default for free with zero code changes.
  This is the "Worker option records" integration point the MasterPlan calls for.
  Date: 2026-06-03.

- Decision (SUPERSEDES the entry above): Thread the outbox metrics handle as a
  trailing `Maybe KeiroMetrics` argument to `publishClaimedOutbox`, **not** as a
  field on `OutboxPublishOptions`.
  Rationale: The `OutboxPublishOptions` field would create a real GHC import cycle
  — `Keiro.Outbox.Types` (where the record lives) → `Keiro.Telemetry` (for
  `KeiroMetrics`) → `Keiro.Outbox.Kafka` → `Keiro.Outbox.Types`. EP-33 kept
  `KeiroMetrics` in `Keiro.Telemetry` rather than relocating it to a leaf module,
  so the field approach is unavailable without an EP-33 change. This plan and the
  MasterPlan both pre-authorized this exact fallback for a real cycle. The cost is
  that every `publishClaimedOutbox` call site gains a trailing `Nothing` (the
  original plan expected zero outbox call-site churn); the benefit is that the
  outbox and inbox now share one "handle passed explicitly as an argument,
  defaulting to no-op" call shape, which is the consistency the MasterPlan's
  "Worker option records / entry points" integration point ultimately wanted.
  Date: 2026-06-03.

- Decision: Thread the inbox metrics handle as a new explicit parameter to
  `runInboxTransaction` and `runInboxTransactionWithKey`, not through a new
  options record.
  Rationale: The inbox has no options record today — `runInboxTransaction` takes
  its inputs positionally (`policy event kafka handler`). Inventing an options
  record solely to carry one optional handle would be a larger, riskier change
  than the metrics work justifies, and would churn every call site more than a
  single added `Maybe KeiroMetrics` argument does. Adding one `Maybe KeiroMetrics`
  parameter keeps the change additive and matches EP-33's "handle passed
  explicitly, defaulting to no-op" convention. The argument is placed first so
  the existing trailing `handler` continuation reads naturally at call sites.
  Date: 2026-06-03.

- Decision: Record backlog as a **synchronous** gauge computed by the worker on
  each pass (one `SELECT COUNT(*)` over the relevant non-terminal statuses),
  not as an asynchronous observable gauge with an export-time callback.
  Rationale: This is the baseline the MasterPlan fixes for all metrics plans (see
  its Decision Log entry on synchronous backlog/lag). The worker already holds
  the `Store` effect and runs periodically, so it can run the count cheaply each
  pass; an observable callback would need its own database access on the SDK's
  collection thread, which the library does not own. Accuracy is within one poll
  interval, which is fine for an operator backlog signal.
  Date: 2026-06-03.

- Decision: Derive the outbox published/retried/deadlettered counters from the
  final `OutboxPublishSummary` after the batch drains, in a single recording
  step, rather than incrementing per row inside `drainBatch`.
  Rationale: The summary already aggregates exactly these three counts, so one
  recording site at the end is simpler, is equivalent in value, and keeps the
  hot per-row loop untouched. (If EP-33 also ships a `keiro.outbox.attempts`
  histogram, that one must be recorded per row, since it observes each attempt's
  attempt-count; see the optional histogram note below.)
  Date: 2026-06-03.

- Decision: Keep `docs/user/operations.md` edits to a single pointer line and
  explicitly defer the full metrics catalogue to EP-37.
  Rationale: The MasterPlan's "User documentation set" integration point assigns
  the consolidated metrics catalogue to EP-37 and asks EP-35/EP-36 to keep their
  `operations.md` edits minimal to avoid churn. This plan therefore only flips
  the existing "There is no built-in metric instrumentation yet" sentence into a
  pointer that metric instrumentation now exists for the outbox and inbox and is
  catalogued in EP-37's revision.
  Date: 2026-06-03.

- Decision: Reference EP-33's metrics surface by path and reconcile spelling at
  implementation time rather than re-specifying it here.
  Rationale: EP-33 owns the final names of `KeiroMetrics`, `newKeiroMetrics`, and
  the recording helpers, plus the canonical `keiro.*` instrument names. At the
  time this plan was authored EP-33 was still a skeleton, so this plan assumes
  the contract recorded in the MasterPlan's Decision Log (a `KeiroMetrics` record,
  `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics`, recording helpers
  taking `Maybe KeiroMetrics` where `Nothing` is a no-op) and the canonical
  instrument names listed in the MasterPlan's Integration Points. The first
  implementation step re-reads the shipped EP-33 file and reconciles any naming
  difference in this Decision Log before writing code.
  Date: 2026-06-03.

(Add further decisions here during implementation.)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-03): complete.** Both milestones landed and the full
`keiro-test` suite passes at **88 examples, 0 failures**, including the two new
metrics examples. Against the original purpose — "an application that wires a
meter sees eight numbers describing outbox/inbox health" — all eight instruments
(`keiro.outbox.backlog`, `.published`, `.retried`, `.deadlettered`,
`keiro.inbox.processed`, `.duplicates`, `.failed`, `.backlog`) are now recorded
by the workers and observable under the in-memory metric exporter. The no-op
default holds: every pre-existing example still passes, with the outbox passing a
trailing `Nothing` and the inbox a leading `Nothing`.

**What changed vs. the plan.** The single substantive deviation is the outbox
threading mechanism: the planned `OutboxPublishOptions.metrics` field was
impossible because of a real `Telemetry → Outbox.Kafka → Outbox.Types` import
cycle, so the handle is a trailing argument to `publishClaimedOutbox` (the plan's
own pre-authorized fallback). This forced ~14 `publishClaimedOutbox` call sites
to gain a `Nothing` that the plan had not anticipated, but produced a more
consistent call shape across the two workers. The inbox went exactly as planned.

**Gaps / deferred.** The optional `keiro.outbox.attempts` histogram was not
recorded here (EP-33 ships the instrument on `KeiroMetrics` as `timerAttempts`
for the timer worker, but there is no outbox per-attempt histogram helper, and
it is explicitly optional in the MasterPlan). The full operator-facing metrics
catalogue is intentionally deferred to EP-37; `operations.md` carries only a
one-line pointer. The backlog gauges are recorded synchronously once per
worker pass/delivery (the MasterPlan baseline), so they are accurate to within
one poll interval, not continuously.

**Lessons.** (1) Verify the import graph before choosing a threading mechanism —
the cycle warning in the MasterPlan was correct and the fallback was the right
call. (2) A zero-valued synchronous gauge *is* exported as `Just 0`, so backlog
assertions need no special-casing; counters that only ever add 0 are the
ambiguous case, so the outbox test drives `retried` to a real non-zero value
across two passes instead of asserting a zero counter.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before
editing anything.

### The repository

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. The keiro library
lives under `keiro/`; its public modules are listed in `keiro/keiro.cabal`. The
library's test suite is a single file, `keiro/test/Main.hs`, declared as the
`keiro-test` test target in `keiro/keiro.cabal`. You run it from the repository
root with `cabal test keiro-test`.

Tests that touch the database use a **suite-level template-database fixture**
from the `keiro-test-support` package. In `keiro/test/Main.hs`, `main` wraps the
whole spec in `withMigratedSuite $ \fixture -> hspec $ ...`
(`Keiro.Test.Postgres.withMigratedSuite`), which migrates one template database
once. Each database-touching example is then introduced with `around
(withFreshStore fixture)`, which hands the example a fresh `Store.KirokuStore`
handle (a connection to a freshly cloned database). The example receives that
handle as its argument (commonly named `storeHandle`) and runs keiro effects
against it with `Store.runStoreIO storeHandle (...)`. You will follow this exact
pattern for the two new tests; do not invent per-example migration.

### The outbox publisher

`keiro/src/Keiro/Outbox.hs` defines the publisher worker:

```haskell
publishClaimedOutbox ::
  forall es.
  (IOE :> es, Store :> es) =>
  (OutboxRow -> Eff es PublishOutcome) ->
  OutboxPublishOptions ->
  Eff es OutboxPublishSummary
```

It claims a batch of rows (`claimOutboxBatch`, defined in
`keiro/src/Keiro/Outbox/Schema.hs`), hands each to the caller-supplied `publish`
function, and marks every row sent, retryable (`failed`), or `dead`. It returns
an `OutboxPublishSummary`:

```haskell
data OutboxPublishSummary = OutboxPublishSummary
  { claimed :: !Int
  , published :: !Int
  , retried :: !Int
  , dead :: !Int
  , haltedOn :: !(Maybe OutboxId)
  }
```

The knobs that govern a pass are `OutboxPublishOptions`
(`keiro/src/Keiro/Outbox/Types.hs`), which already carries an opt-in tracer:

```haskell
data OutboxPublishOptions = OutboxPublishOptions
  { batchSize :: !Int
  , maxAttempts :: !Int
  , backoff :: !BackoffSchedule
  , orderingPolicy :: !OrderingPolicy
  , tracer :: !(Maybe Tracer)
  }
```

The `keiro_outbox` table column `status` takes the values `pending`,
`publishing`, `sent`, `failed`, `dead` (`statusText` / `parseStatus` in
`keiro/src/Keiro/Outbox/Types.hs`). The **backlog** for the gauge is the count of
rows in a non-terminal, claimable state: `status IN ('pending', 'failed')`. (A
`publishing` row is one currently held by a worker mid-pass; it is excluded so
the gauge measures work still awaiting a publisher, matching the claim query's
own `status IN ('pending','failed')` predicate in
`keiro/src/Keiro/Outbox/Schema.hs`.) The `dead` count for the deadlettered
counter comes from `summary.dead`; published from `summary.published`; retried
from `summary.retried`.

### The inbox

`keiro/src/Keiro/Inbox.hs` defines the inbox wrapper:

```haskell
runInboxTransaction ::
  forall a es.
  (IOE :> es, Store :> es) =>
  InboxDedupePolicy ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  (IntegrationEvent -> Tx.Transaction a) ->
  Eff es (Either InboxError (InboxResult a))

runInboxTransactionWithKey ::
  forall a es.
  (IOE :> es, Store :> es) =>
  Text ->
  Text ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  (IntegrationEvent -> Tx.Transaction a) ->
  Eff es (InboxResult a)
```

`runInboxTransaction` computes a dedupe key from the policy then delegates to
`runInboxTransactionWithKey`, which does the actual single-transaction work and
returns `InboxResult a`:

```haskell
data InboxResult a
  = InboxProcessed !a
  | InboxDuplicate
  | InboxInProgress
  | InboxPreviouslyFailed !(Maybe Text)
```

The `keiro_inbox` table column `status` takes the values `processing`,
`completed`, `failed` (`inboxStatusText` / `parseInboxStatus` in
`keiro/src/Keiro/Inbox/Types.hs`). The **backlog** for the inbox gauge is the
count of rows in a non-terminal state: `status IN ('processing', 'failed')`.
The classification for the counters is: `InboxProcessed` → `keiro.inbox.processed`,
`InboxDuplicate` → `keiro.inbox.duplicates`, `InboxPreviouslyFailed` →
`keiro.inbox.failed`. `InboxInProgress` records nothing.

### The metrics surface this plan consumes (owned by EP-33)

EP-33 (`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`)
adds, to `keiro/src/Keiro/Telemetry.hs`:

- A record `KeiroMetrics` holding all of keiro's pre-built metric instruments,
  including the eight this plan records.
- A builder `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics` that
  creates the instruments from an OpenTelemetry `Meter` (the object an
  application obtains from its SDK meter provider with `getMeter`).
- Recording helpers that take a `Maybe KeiroMetrics` and treat `Nothing` as a
  no-op. The exact helper names and signatures are owned by EP-33; this plan
  refers to them by intent (for example, "the helper that adds to
  `keiro.outbox.published`") and the implementer binds them to the real names
  after reading the shipped EP-33 file. If EP-33 instead exposes the raw
  instruments on the record and expects callers to call `counterAdd` /
  `gaugeRecord` directly, this plan does that instead; the recording semantics
  are identical either way.

The canonical instrument names (final spelling owned by EP-33) are
`keiro.outbox.backlog` (gauge), `keiro.outbox.published`, `keiro.outbox.retried`,
`keiro.outbox.deadlettered` (counters), `keiro.inbox.processed`,
`keiro.inbox.duplicates`, `keiro.inbox.failed` (counters), and
`keiro.inbox.backlog` (gauge). EP-33 may additionally ship a
`keiro.outbox.attempts` **histogram**; if it does, this plan records one
observation per row publish attempt (see the optional step in M1b). If EP-33 does
not ship it, this plan omits it — it is explicitly optional in the MasterPlan.

### The OpenTelemetry metrics types you will touch in tests

These come from `hs-opentelemetry-api`, `hs-opentelemetry-sdk`, and
`hs-opentelemetry-exporter-in-memory`, all already test dependencies of
`keiro-test` (`keiro/keiro.cabal`). A **meter provider** creates **meters**; a
meter creates **instruments** (counters, gauges, histograms); recording on an
instrument updates an in-process aggregate; an **export** (on flush or shutdown)
pushes those aggregates to an **exporter**. The in-memory exporter collects
exports into an `IORef [ResourceMetricsExport]`.

The relevant types for assertions (from `OpenTelemetry.Exporter.Metric`, which
re-exports `OpenTelemetry.Internal.Metric.Export`):

```haskell
data ResourceMetricsExport = ResourceMetricsExport
  { resourceMetricsResource :: !MaterializedResources
  , resourceMetricsScopes :: !(Vector ScopeMetricsExport)
  }

data ScopeMetricsExport = ScopeMetricsExport
  { scopeMetricsScope :: !InstrumentationLibrary
  , scopeMetricsExports :: !(Vector MetricExport)
  }

data MetricExport
  = MetricExportSum   { mesName :: !Text, ..., mesSumPoints :: !(Vector SumDataPoint) }
  | MetricExportHistogram { mehName :: !Text, ..., mehPoints :: !(Vector HistogramDataPoint) }
  | MetricExportExponentialHistogram { meehName :: !Text, ... }
  | MetricExportGauge { megName :: !Text, ..., megGaugePoints :: !(Vector GaugeDataPoint) }

data SumDataPoint   = SumDataPoint   { ..., sumDataPointValue   :: !NumberValue, ... }
data GaugeDataPoint = GaugeDataPoint { ..., gaugeDataPointValue :: !NumberValue, ... }
data NumberValue = IntNumber !Int64 | DoubleNumber !Double
```

A **counter** exports as `MetricExportSum`; a **synchronous gauge** exports as
`MetricExportGauge`. To assert a counter you find the `MetricExportSum` whose
`mesName` equals the instrument name and read the single `SumDataPoint`'s
`sumDataPointValue`. To assert a gauge you find the `MetricExportGauge` whose
`megName` equals the instrument name and read the single `GaugeDataPoint`'s
`gaugeDataPointValue`. EP-33's test harness should provide small helper
extractors for this; if it does, use them rather than re-implementing the
traversal. The plan below includes the traversal inline so it is self-contained
even if EP-33's harness names differ.


## Plan of Work

The work is two milestones. M1 instruments and tests the outbox; M2 instruments
and tests the inbox. Each milestone is independently verifiable by running
`cabal test keiro-test` and seeing its new test pass. Before either milestone,
do the prerequisite reconciliation step.

### Prerequisite: reconcile with EP-33

Confirm EP-33 is merged (the `Keiro.Telemetry` module exports `KeiroMetrics`,
`newKeiroMetrics`, and the recording helpers, and the in-memory-metric test
harness exists). Read the shipped
`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md` and
`keiro/src/Keiro/Telemetry.hs`. Record in this plan's Decision Log any naming
difference between what this plan assumes and what EP-33 shipped (helper names,
record field names, instrument-name spelling, and whether the test harness
exposes extractor helpers). All later steps use the **real** EP-33 names.

### Milestone 1 — Instrument the outbox publisher

Scope: thread a `Maybe KeiroMetrics` handle into the outbox publisher and record
`keiro.outbox.backlog` (gauge), `keiro.outbox.published`, `keiro.outbox.retried`,
and `keiro.outbox.deadlettered` (counters). At the end of this milestone, a
publish pass driven by a stub publisher records all four instruments, and a new
test asserts them under the in-memory metric exporter. Run `cabal test
keiro-test`; acceptance is that the new outbox-metrics example passes and every
existing outbox example still passes.

**M1a — types and the backlog query.**

In `keiro/src/Keiro/Outbox/Types.hs`:

- Import `KeiroMetrics` from `Keiro.Telemetry`. Note `Keiro.Telemetry` itself
  imports `Keiro.Outbox.Kafka`; adding `import Keiro.Telemetry (KeiroMetrics)`
  to `Keiro.Outbox.Types` must not create an import cycle. `Keiro.Telemetry`
  imports `Keiro.Outbox.Kafka` and `Keiro.Integration.Event`, **not**
  `Keiro.Outbox.Types`, so importing `KeiroMetrics` into `Keiro.Outbox.Types`
  from `Keiro.Telemetry` would create a cycle (`Telemetry → Outbox.Kafka → …`
  and `Outbox.Types → Telemetry`). To avoid that, confirm where EP-33 defined
  `KeiroMetrics`: if EP-33 placed `KeiroMetrics` in `Keiro.Telemetry` and that
  module already depends (transitively) on `Keiro.Outbox.Types`, then
  `Keiro.Outbox.Types` cannot import it. The implementer must check the actual
  module graph after EP-33 lands. If a cycle exists, the resolution is to define
  `KeiroMetrics` in a leaf module EP-33 controls (EP-33's responsibility to make
  the type importable by worker modules) — record the need in this plan's
  Surprises & Discoveries and, if it requires an EP-33 change, in the
  MasterPlan's Surprises & Discoveries per the integration-point rule. As a
  fallback that needs no EP-33 change, thread the handle into `publishClaimedOutbox`
  as a separate argument typed `Maybe KeiroMetrics` (importing it in
  `Keiro/Outbox.hs`, which already imports `Keiro.Telemetry`) instead of putting
  it on `OutboxPublishOptions`; choose this only if the cycle is real, and record
  the choice in the Decision Log.
- Assuming no cycle, add a field to `OutboxPublishOptions`:
  `metrics :: !(Maybe KeiroMetrics)`.
- Set `metrics = Nothing` in `defaultPublishOptions`.

In `keiro/src/Keiro/Outbox/Schema.hs`, add a read-only backlog count and export
it from the module list:

```haskell
-- | Count outbox rows awaiting publish (backlog gauge source).
--
-- Backlog = rows in a claimable, non-terminal state. Mirrors the claim
-- query's @status IN ('pending','failed')@ predicate so the gauge measures
-- exactly the rows a publisher still has to drain.
countOutboxBacklog :: (Store :> es) => Eff es Int
countOutboxBacklog =
  runTransaction (Tx.statement () countBacklogStmt)

countBacklogStmt :: Statement () Int
countBacklogStmt =
  preparable
    "SELECT COUNT(*)::bigint FROM keiro_outbox WHERE status IN ('pending', 'failed')"
    E.noParams
    (fmap fromIntegral (D.singleRow (D.column (D.nonNullable D.int8))))
```

Re-export `countOutboxBacklog` from `Keiro.Outbox` (add it to the export list in
`keiro/src/Keiro/Outbox.hs`, under "Storage primitives").

**M1b — record in the publisher.**

In `keiro/src/Keiro/Outbox.hs`, import the EP-33 recording helpers (or the
instruments off `KeiroMetrics`) from `Keiro.Telemetry`. Rewrite
`publishClaimedOutbox` so that, with `let mMetrics = options ^. #metrics`:

1. Before draining, compute the backlog and record the gauge. Compute it after
   the claim has run so the gauge reflects rows still awaiting publish (claimed
   rows have moved to `publishing` and are excluded by the predicate). Concretely,
   record the gauge once, after `claimOutboxBatch`, using
   `countOutboxBacklog`:

   ```haskell
   backlog <- countOutboxBacklog
   recordOutboxBacklog mMetrics backlog   -- EP-33 helper; no-op when Nothing
   ```

   (If EP-33's helper is named differently or takes the raw gauge, adapt; the
   value recorded is the `Int` backlog. Recording the gauge once per pass after
   the claim is the synchronous-gauge baseline the MasterPlan fixes.)

2. Drain the batch as today, producing the final `OutboxPublishSummary`.

3. After the batch drains, record the three counters from the summary in one
   step (each helper is a no-op under `Nothing`):

   ```haskell
   recordOutboxPublished     mMetrics (summary ^. #published)
   recordOutboxRetried       mMetrics (summary ^. #retried)
   recordOutboxDeadlettered  mMetrics (summary ^. #dead)
   ```

   Counters take a non-negative delta; `published`, `retried`, and `dead` are
   each `>= 0`, so adding them is always valid. Recording a zero delta is
   harmless (no data point change), so passing `0` on an empty pass is fine.

4. Return the summary unchanged (the function's type and return value do not
   change).

Optional (only if EP-33 shipped `keiro.outbox.attempts` as a histogram): inside
the per-row drain, after each publish attempt, record one observation of the
row's attempt number (`row ^. #attemptCount`, an `Int`) on the histogram. Place
the recording call inside `drainBatch` for both the success and failure branches.
If EP-33 did not ship the histogram, skip this entirely.

Keep the existing `withProducerSpan` tracing logic exactly as-is; metrics and
spans are independent and both opt-in.

**M1c — outbox metrics test.**

Add a new example to the `describe "Keiro.Outbox"` block in
`keiro/test/Main.hs` (the block introduced with `around (withFreshStore
fixture)` near line 890). Model the meter wiring on the existing producer-span
test (`keiro/test/Main.hs` line 1080, "publishClaimedOutbox emits a Producer
span …"), which wires an in-memory **span** exporter; the metric version wires an
in-memory **metric** exporter via EP-33's harness.

Add the imports the test needs at the top of `keiro/test/Main.hs` (use EP-33's
harness helper if it exposes one; otherwise import directly):

```haskell
import OpenTelemetry.Exporter.InMemory.Metric (inMemoryMetricExporter)
import OpenTelemetry.MeterProvider (createMeterProvider, defaultSdkMeterProviderOptions, metricExporter)
import OpenTelemetry.Metric.Core (getMeter, forceFlushMeterProvider)
import OpenTelemetry.Resource (emptyMaterializedResources)
import OpenTelemetry.Exporter.Metric
  ( MetricExport (..)
  , SumDataPoint (..)
  , GaugeDataPoint (..)
  , NumberValue (..)
  , ResourceMetricsExport (..)
  , ScopeMetricsExport (..)
  )
import qualified Data.Vector as V   -- already imported as `Data.Vector qualified as Vector`; reuse that
```

If EP-33's harness already provides a one-call "make me a meter plus a way to
read the exported metrics" helper and small extractor functions, prefer those
and drop the lower-level imports. The test body, written against the lower-level
SDK directly so it is self-contained:

```haskell
it "publishClaimedOutbox records outbox metrics under the in-memory exporter" $ \storeHandle -> do
  (exporter, metricsRef) <- inMemoryMetricExporter
  (provider, _env) <-
    createMeterProvider
      emptyMaterializedResources
      defaultSdkMeterProviderOptions {metricExporter = Just exporter}
  meter <- getMeter provider "keiro-test"
  keiroMetrics <- Telemetry.newKeiroMetrics meter
  -- Enqueue one row that will publish and one that will dead-letter on its
  -- first failure (maxAttempts = 1 means the first failure is terminal).
  let okId   = OutboxId outboxUuid1
      deadId = OutboxId outboxUuid2
      okEvent   = sampleIntegrationEnvelope & #messageId .~ "metrics-ok"   & #key .~ Nothing
      deadEvent = sampleIntegrationEnvelope & #messageId .~ "metrics-dead" & #key .~ Nothing
  Right () <- Store.runStoreIO storeHandle $
    Store.runTransaction (enqueueIntegrationEventTx okId okEvent)
  Right () <- Store.runStoreIO storeHandle $
    Store.runTransaction (enqueueIntegrationEventTx deadId deadEvent)
  let publish row
        | row ^. #outboxId == okId = pure PublishSucceeded
        | otherwise                = pure (PublishFailed "broker down")
      opts =
        defaultPublishOptions
          & #batchSize .~ 10
          & #maxAttempts .~ 1            -- first failure dead-letters
          & #backoff .~ ConstantBackoff 0
          & #orderingPolicy .~ BestEffort
          & #metrics ?~ keiroMetrics
  Right summary <- Store.runStoreIO storeHandle (publishClaimedOutbox publish opts)
  summary ^. #published `shouldBe` 1
  summary ^. #dead `shouldBe` 1
  -- Flush so the in-memory exporter receives the aggregates.
  _ <- forceFlushMeterProvider provider Nothing
  batches <- readIORef metricsRef
  -- Helpers: find a counter's / gauge's single value by instrument name.
  let allExports =
        [ ex
        | rme <- batches
        , scope <- V.toList (resourceMetricsScopes rme)
        , ex <- V.toList (scopeMetricsExports scope)
        ]
      counterValue name =
        case [ sumDataPointValue p
             | MetricExportSum {mesName, mesSumPoints} <- allExports
             , mesName == name
             , p <- V.toList mesSumPoints
             ] of
          (IntNumber n : _) -> Just n
          (DoubleNumber d : _) -> Just (round d)
          [] -> Nothing
      gaugeValue name =
        case [ gaugeDataPointValue p
             | MetricExportGauge {megName, megGaugePoints} <- allExports
             , megName == name
             , p <- V.toList megGaugePoints
             ] of
          (IntNumber n : _) -> Just n
          (DoubleNumber d : _) -> Just (round d)
          [] -> Nothing
  counterValue "keiro.outbox.published"     `shouldBe` Just 1
  counterValue "keiro.outbox.deadlettered"  `shouldBe` Just 1
  counterValue "keiro.outbox.retried"       `shouldBe` Just 0  -- or Nothing; see note
  -- Backlog after the pass: the ok row is 'sent', the dead row is 'dead',
  -- so nothing is left in ('pending','failed'): backlog is 0.
  gaugeValue "keiro.outbox.backlog" `shouldBe` Just 0
```

Notes for the implementer:

- The `retried` assertion: a counter that was only ever `add 0` may or may not
  produce a data point depending on EP-33's recording-helper design (some no-op
  on a zero delta, some create the series at zero). After running the test once,
  set the `keiro.outbox.retried` expectation to whichever EP-33 actually emits
  (`Just 0` or `Nothing`) and record the observed behavior in Surprises &
  Discoveries. To make `retried` unambiguous and exercise all three counters
  with non-zero values, **prefer** a two-row-retried variant: keep `maxAttempts`
  at its default (>1) for a second failing row so it lands in `retried` not
  `dead`. The simplest robust shape is three rows: one succeeds (published=1),
  one fails under `maxAttempts > 1` (retried=1), and one fails under a separate
  pass / `maxAttempts = 1` (dead=1). If a single pass cannot produce both a
  retried and a dead row (because `maxAttempts` is per-options, not per-row),
  split into two passes: pass 1 with `maxAttempts` high to get a `retried` row,
  pass 2 with `maxAttempts = 1` (or after enough passes) to dead-letter another
  row, sharing one meter/exporter across both passes and flushing once at the
  end. Counters are cumulative, so the asserted values are the totals across
  both passes.
- `outboxUuid1` and `outboxUuid2` are existing test fixtures in
  `keiro/test/Main.hs`; reuse them (and add `outboxUuid3` if you take the
  three-row shape — it already exists, used by the head-of-line test).
- `sampleIntegrationEnvelope` is the existing sample event used by the other
  outbox tests; reuse it.
- `Telemetry.newKeiroMetrics meter` runs in `IO` here (the test is in `IO`),
  matching `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics`.

### Milestone 2 — Instrument the inbox

Scope: thread a `Maybe KeiroMetrics` parameter into `runInboxTransaction` /
`runInboxTransactionWithKey` and record `keiro.inbox.processed`,
`keiro.inbox.duplicates`, `keiro.inbox.failed` (counters) and
`keiro.inbox.backlog` (gauge). At the end, delivering the same `(source,
message_id)` twice records one processed and one duplicate, asserted under the
in-memory metric exporter. Run `cabal test keiro-test`; acceptance is that the
new inbox-metrics example passes and every existing inbox example still passes
(after updating their call sites to pass the new argument).

**M2a — thread the handle and record.**

In `keiro/src/Keiro/Inbox.hs`:

- Import `KeiroMetrics` and the inbox recording helpers from `Keiro.Telemetry`,
  and `countInboxBacklog` from `Keiro.Inbox.Schema` (added below). Check the
  module graph: `Keiro.Telemetry` imports `Keiro.Inbox.Kafka` (not
  `Keiro.Inbox`), so `Keiro.Inbox` importing `Keiro.Telemetry` is fine (it is a
  leaf consumer). Confirm after EP-33 lands.
- Add a leading `Maybe KeiroMetrics` parameter to both functions. New signatures:

  ```haskell
  runInboxTransaction ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    InboxDedupePolicy ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))

  runInboxTransactionWithKey ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Text ->
    Text ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (InboxResult a)
  ```

- `runInboxTransaction` threads the handle to `runInboxTransactionWithKey`.
- In `runInboxTransactionWithKey`, after the transaction returns the
  `InboxResult`, record the counter that matches the outcome and then record the
  backlog gauge. Recording happens **outside** the inbox transaction (the
  transaction returns the classified `InboxResult`; do not record inside the
  Hasql transaction). Concretely, after `result <- runTransaction (...)`:

  ```haskell
  case result of
    InboxProcessed _        -> recordInboxProcessed  mMetrics
    InboxDuplicate          -> recordInboxDuplicate  mMetrics
    InboxPreviouslyFailed _ -> recordInboxFailed     mMetrics
    InboxInProgress         -> pure ()   -- not recorded in v1
  backlog <- countInboxBacklog
  recordInboxBacklog mMetrics backlog
  pure result
  ```

  Each counter helper adds 1; each is a no-op under `Nothing`. The backlog gauge
  records the post-transaction non-terminal count once per delivery.

In `keiro/src/Keiro/Inbox/Schema.hs`, add and export a backlog count mirroring
the outbox one:

```haskell
-- | Count inbox rows in a non-terminal state (backlog gauge source).
countInboxBacklog :: (Store :> es) => Eff es Int
countInboxBacklog =
  runTransaction (Tx.statement () countInboxBacklogStmt)

countInboxBacklogStmt :: Statement () Int
countInboxBacklogStmt =
  preparable
    "SELECT COUNT(*)::bigint FROM keiro_inbox WHERE status IN ('processing', 'failed')"
    E.noParams
    (fmap fromIntegral (D.singleRow (D.column (D.nonNullable D.int8))))
```

Re-export `countInboxBacklog` from `Keiro.Inbox` (add it to the export list in
`keiro/src/Keiro/Inbox.hs` under "Storage primitives").

**M2a (continued) — fix existing call sites.**

Adding a parameter changes every caller. The only callers are in
`keiro/test/Main.hs` (the `describe "Keiro.Inbox"` block, roughly lines
1129–1230). Update each `runInboxTransaction <policy> ...` call to
`runInboxTransaction Nothing <policy> ...`, passing `Nothing` for the new metrics
handle so those tests stay unchanged in behavior. There is no production call
site inside the library beyond `runInboxTransaction` delegating to
`runInboxTransactionWithKey`. (Grep to be sure: `grep -rn
"runInboxTransaction" keiro/` before and after.)

This `Nothing` default is exactly the **backward-compatibility** mechanism: any
caller — test or downstream application — that does not opt into metrics passes
`Nothing` and the inbox records nothing, behaving identically to today. The same
holds for the outbox: callers that build options from `defaultPublishOptions`
inherit `metrics = Nothing`.

**M2b — inbox metrics test.**

Add a new example to the `describe "Keiro.Inbox"` block in `keiro/test/Main.hs`.
Reuse the meter-wiring shape from M1c (consider factoring a small local helper
`withInMemoryMeter :: (Telemetry.KeiroMetrics -> IORef [ResourceMetricsExport] -> IO a) -> IO a`
in the test file if EP-33's harness does not already provide one; otherwise
inline). Model the inbox handler / table setup on the existing "treats a
redelivery with the same messageId as a duplicate" test
(`keiro/test/Main.hs` line 1150).

```haskell
it "records inbox metrics: one processed and one duplicate under the in-memory exporter" $ \storeHandle -> do
  (exporter, metricsRef) <- inMemoryMetricExporter
  (provider, _env) <-
    createMeterProvider
      emptyMaterializedResources
      defaultSdkMeterProviderOptions {metricExporter = Just exporter}
  meter <- getMeter provider "keiro-test"
  keiroMetrics <- Telemetry.newKeiroMetrics meter
  Right () <- Store.runStoreIO storeHandle $
    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
  let event = sampleIntegrationEnvelope & #messageId .~ "inbox-metrics-dup" & #source .~ "ordering"
      handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
  -- First delivery: processed.
  Right (Right (InboxProcessed ())) <- Store.runStoreIO storeHandle $
    runInboxTransaction (Just keiroMetrics) PreferIntegrationMessageId event Nothing handler
  -- Second delivery of the same (source, message_id): duplicate.
  Right result2 <- Store.runStoreIO storeHandle $
    runInboxTransaction (Just keiroMetrics) PreferIntegrationMessageId event Nothing handler
  result2 `shouldBe` Right InboxDuplicate
  _ <- forceFlushMeterProvider provider Nothing
  batches <- readIORef metricsRef
  let allExports =
        [ ex | rme <- batches, scope <- V.toList (resourceMetricsScopes rme), ex <- V.toList (scopeMetricsExports scope) ]
      counterValue name =
        case [ sumDataPointValue p
             | MetricExportSum {mesName, mesSumPoints} <- allExports, mesName == name, p <- V.toList mesSumPoints ] of
          (IntNumber n : _) -> Just n
          (DoubleNumber d : _) -> Just (round d)
          [] -> Nothing
  counterValue "keiro.inbox.processed"  `shouldBe` Just 1
  counterValue "keiro.inbox.duplicates" `shouldBe` Just 1
```

The handler runs only on the first delivery (the second is a duplicate), so the
local `inbox_test_counter` table — used by the existing inbox tests — would hold
one row; you may additionally assert that to prove the handler ran exactly once,
mirroring the existing duplicate test.

### Minimal documentation pointer

In `docs/user/operations.md`, in the "Observability" section, change the final
sentence ("There is no built-in metric instrumentation yet, so the counts above
are currently derived from your own queries and logs.") to a one-line pointer
that metric instrumentation now exists for the outbox and inbox workers and that
the full instrument catalogue is documented separately. Keep it to one line; do
**not** add the catalogue here — EP-37 owns the consolidated metrics catalogue
(per the MasterPlan's "User documentation set" integration point). Suggested
replacement:

```text
Keiro now also emits OpenTelemetry **metrics** for the outbox and inbox workers
(backlog gauges and published/retried/dead-lettered/duplicate counters) via the
opt-in `KeiroMetrics` handle; the full instrument catalogue is documented with
the rest of the metrics surface (see the metrics catalogue in the operations
guide once EP-37 lands).
```

Do not touch `docs/user/production-status.md` or `docs/user/roadmap.md`; those
are EP-37's.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

1. Confirm EP-33 is present:

   ```bash
   grep -n "newKeiroMetrics\|KeiroMetrics" keiro/src/Keiro/Telemetry.hs
   ```

   You should see the `KeiroMetrics` type and `newKeiroMetrics` builder. If you
   do not, stop — EP-33 is the hard dependency and must land first.

2. Make the M1 source edits (Outbox/Types.hs, Outbox/Schema.hs, Outbox.hs) and
   the M2 source edits (Inbox.hs, Inbox/Schema.hs) described above, then update
   the inbox test call sites to pass `Nothing`, and add the two new tests.

3. Build and test:

   ```bash
   cabal build keiro
   cabal test keiro-test
   ```

   Expected (abbreviated) transcript:

   ```text
   Keiro.Outbox
     ...
     publishClaimedOutbox marks success and records failures with last_error [✔]
     publishClaimedOutbox records outbox metrics under the in-memory exporter [✔]
     ...
   Keiro.Inbox
     runs the handler once and records the row as completed [✔]
     treats a redelivery with the same messageId as a duplicate [✔]
     records inbox metrics: one processed and one duplicate under the in-memory exporter [✔]
     ...

   Finished in N.NNNN seconds
   NN examples, 0 failures
   Test suite keiro-test: PASS
   ```

4. Confirm there are no stray un-updated call sites:

   ```bash
   grep -rn "runInboxTransaction" keiro/
   ```

   Every call should now pass a `Maybe KeiroMetrics` first argument (`Nothing`
   for the non-metrics tests, `Just keiroMetrics` for the new metrics test).

Real transcript (2026-06-03, `cabal test keiro-test`):

```text
Keiro.Outbox
  ...
  publishClaimedOutbox emits a Producer span with messaging semconv attributes [✔]
  publishClaimedOutbox records outbox metrics under the in-memory exporter [✔]
Keiro.Inbox
  runs the handler once and records the row as completed [✔]
  treats a redelivery with the same messageId as a duplicate [✔]
  records inbox metrics: one processed and one duplicate under the in-memory exporter [✔]
  ...

Finished in 8.7856 seconds
88 examples, 0 failures
Test suite keiro-test: PASS
```

Note: `grep -rn "runInboxTransaction" keiro/` confirms all 11 inbox call sites pass
a leading `Maybe KeiroMetrics` (`Nothing` for the non-metrics tests, `Just
keiroMetrics` for the new one), and all `publishClaimedOutbox` call sites pass a
trailing `Maybe KeiroMetrics`.


## Validation and Acceptance

Acceptance is behavioral and observed through the test suite:

- **Outbox.** After running a publish pass with a stub publisher that publishes
  one row and dead-letters another, with a real SDK meter wired to the in-memory
  metric exporter and a force-flush, the exported metrics contain
  `keiro.outbox.published = 1`, `keiro.outbox.deadlettered = 1`, the
  `keiro.outbox.retried` counter consistent with the scenario, and a
  `keiro.outbox.backlog` gauge equal to the number of `pending`/`failed` rows
  remaining (0 in the single-pass dead-letter scenario, since the surviving rows
  are `sent` and `dead`). This proves the publisher records all four instruments
  and that the values are derived from real database state and the real
  `OutboxPublishSummary`, not hard-coded.

- **Inbox.** After delivering the same `(source, message_id)` twice through
  `runInboxTransaction (Just keiroMetrics) ...`, with a force-flush, the exported
  metrics contain `keiro.inbox.processed = 1` and `keiro.inbox.duplicates = 1`,
  and the handler ran exactly once (one row in `inbox_test_counter`). This proves
  the inbox records the processed/duplicate classification correctly and that the
  duplicate path does not re-run the handler.

- **Backward compatibility.** Every pre-existing outbox and inbox test still
  passes. Outbox tests are unchanged because they build options from
  `defaultPublishOptions` (which now defaults `metrics = Nothing`). Inbox tests
  are changed only mechanically — each call now passes `Nothing` as the first
  argument — and their assertions are unchanged, proving the no-op path behaves
  identically to before.

The exact command, from the repository root, is `cabal test keiro-test`. A pass
is `NN examples, 0 failures` and `Test suite keiro-test: PASS`. A failure prints
the failing example name and a `shouldBe` mismatch (for example, `expected: Just
1` / `but got: Nothing`), which tells you whether the instrument was not recorded
(`Nothing`), recorded with the wrong value, or named differently than asserted.

If an assertion returns `Nothing` for an instrument you expected, the most likely
causes, in order, are: (a) you read `metricsRef` before flushing — call
`forceFlushMeterProvider provider Nothing` first; (b) the instrument name in the
assertion does not match EP-33's actual spelling — re-check against
`keiro/src/Keiro/Telemetry.hs`; (c) the handle was `Nothing` at the call site —
confirm you passed `Just keiroMetrics`.


## Idempotence and Recovery

All edits are additive and safe to apply repeatedly. Adding a record field with a
default, adding two read-only `COUNT(*)` queries, adding two recording sites, and
adding one parameter are all reversible by reverting the diff. Re-running `cabal
test keiro-test` is safe and repeatable: the suite uses the template-database
fixture, so each example runs against a fresh clone and leaves no shared state.
The new `COUNT(*)` queries are read-only and cannot corrupt data. If a build
fails after the inbox signature change, it is almost always an un-updated call
site — `grep -rn "runInboxTransaction" keiro/` and add the `Nothing` argument.

If EP-33's surface turns out to differ from this plan's assumptions (helper
names, the location of `KeiroMetrics`, instrument-name spelling, or an import
cycle), do not work around it silently: record the difference in this plan's
Decision Log and, where it implies an EP-33 change, in the MasterPlan's Surprises
& Discoveries, then proceed with the real names.


## Interfaces and Dependencies

Libraries and modules used and why:

- `Keiro.Telemetry` (extended by EP-33) — supplies `KeiroMetrics`,
  `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics`, and the recording
  helpers consumed here. This plan must not define any instrument outside
  `Keiro.Telemetry` (the MasterPlan's single-telemetry-import rule). If a needed
  helper or instrument is missing, extend `Keiro.Telemetry` and record it in the
  MasterPlan's Surprises & Discoveries.
- `hs-opentelemetry-sdk` (`OpenTelemetry.MeterProvider`,
  `OpenTelemetry.Metric.Core`) — test-only: builds the SDK meter provider
  (`createMeterProvider`), obtains a `Meter` (`getMeter`), and flushes
  (`forceFlushMeterProvider`). Already a `keiro-test` dependency.
- `hs-opentelemetry-exporter-in-memory`
  (`OpenTelemetry.Exporter.InMemory.Metric.inMemoryMetricExporter`) — test-only:
  collects exported metric batches into an `IORef [ResourceMetricsExport]`.
  Already a `keiro-test` dependency.
- `hs-opentelemetry-api` (`OpenTelemetry.Exporter.Metric`) — test-only: the
  `MetricExport` / `SumDataPoint` / `GaugeDataPoint` / `NumberValue` types used
  to read exported values. Already a `keiro-test` dependency.
- `keiro-test-support` (`Keiro.Test.Postgres`) — the template-database fixture
  (`withMigratedSuite`, `withFreshStore`). Already a `keiro-test` dependency.

No new dependencies are added to `keiro/keiro.cabal` — the library already
depends on `hs-opentelemetry-api` (which gives it the `Meter` type via
`Keiro.Telemetry`), and the test target already has the SDK, in-memory exporter,
and test-support deps. Confirm by reading `keiro/keiro.cabal` before editing; if
EP-33 added a dependency this plan needs, it is already present.

Types and signatures that must exist at the end of each milestone:

- End of M1:
  - `OutboxPublishOptions` has a field `metrics :: !(Maybe KeiroMetrics)` and
    `defaultPublishOptions` sets it to `Nothing` (`keiro/src/Keiro/Outbox/Types.hs`).
  - `countOutboxBacklog :: (Store :> es) => Eff es Int` exists in
    `keiro/src/Keiro/Outbox/Schema.hs` and is re-exported from `Keiro.Outbox`.
  - `publishClaimedOutbox`'s type is unchanged; its body records
    `keiro.outbox.backlog` (gauge, once per pass) and `keiro.outbox.published`,
    `keiro.outbox.retried`, `keiro.outbox.deadlettered` (counters, from the
    summary).
- End of M2:
  - `runInboxTransaction` and `runInboxTransactionWithKey` each take a leading
    `Maybe KeiroMetrics` argument (`keiro/src/Keiro/Inbox.hs`).
  - `countInboxBacklog :: (Store :> es) => Eff es Int` exists in
    `keiro/src/Keiro/Inbox/Schema.hs` and is re-exported from `Keiro.Inbox`.
  - `runInboxTransactionWithKey` records `keiro.inbox.processed` /
    `keiro.inbox.duplicates` / `keiro.inbox.failed` from the `InboxResult` and
    `keiro.inbox.backlog` (gauge) once per delivery.

Every implementation commit for this plan must carry these trailers:

```text
MasterPlan: docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md
ExecPlan: docs/plans/35-instrument-the-outbox-and-inbox-workers-with-metrics.md
Intention: intention_01kt5v38ztez0tt5b63nr7gbnx
```
