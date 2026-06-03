---
id: 33
slug: add-an-opentelemetry-metrics-surface-to-keiro-telemetry
title: "Add an OpenTelemetry metrics surface to Keiro.Telemetry"
kind: exec-plan
created_at: 2026-06-03T04:20:10Z
intention: "intention_01kt5v38ztez0tt5b63nr7gbnx"
master_plan: "docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md"
---

# Add an OpenTelemetry metrics surface to Keiro.Telemetry

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro` is a Haskell PostgreSQL event-sourcing framework. Its module
`keiro/src/Keiro/Telemetry.hs` is today the single place the library reaches for
OpenTelemetry, and it emits **traces** only: spans for the outbox publisher, the
inbox consumer, and the command runner, all behind an opt-in `Maybe Tracer`
(when `Nothing`, every helper is a thin pass-through and applications that have
not configured OpenTelemetry are unaffected). There is no **metrics** surface at
all. "Metrics" in OpenTelemetry are aggregatable numbers — counters that only go
up (e.g. "messages published"), gauges that read a current level (e.g. "rows
waiting in the outbox"), and histograms that summarise a distribution (e.g. "how
late timers fired") — and they are the numbers an operator puts on a dashboard
and alerts on, as distinct from the per-request traces that already exist.

After this change, a developer working on `keiro` (or on any of the sibling
plans EP-35 and EP-36) can import `Keiro.Telemetry` and obtain a single record,
`KeiroMetrics`, that holds **every** metric instrument the whole library will
ever record — fourteen of them, covering the outbox, inbox, timer, and
projection workers. They build it once from an OpenTelemetry `Meter` with
`newKeiroMetrics`, thread it into a worker as a `Maybe KeiroMetrics` (passing
`Nothing` to record nothing), and call small one-line recording helpers at the
points where the worker already computes the relevant number. Because the
upstream library installs a no-op meter by default, instrumentation is always
safe: an application that never configures a meter pays only "one `Maybe`
branch" per recording site, exactly like the existing tracing helpers.

You can **see it working** without any database or message broker. This plan
ships a self-contained test in `keiro/test/Main.hs` that builds a real
OpenTelemetry SDK meter wired to an in-memory metric exporter (a test exporter
that appends each exported batch to a list you can read back), constructs
`KeiroMetrics`, records a handful of sample measurements through the helpers,
forces a flush, and then asserts that the exporter captured exactly the
instrument names and values we recorded. A second assertion proves the negative
case: recording through a `Nothing` handle (the no-op path) produces no data
points. When `cabal test` prints that these examples pass, the metrics surface
is demonstrably real, not merely compiled.

This plan is the **foundation** of a five-plan initiative (MasterPlan
`docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md`).
It deliberately instruments **no** worker. The two instrumentation plans, EP-35
(outbox + inbox) and EP-36 (timer + projection), hard-depend on this plan and
will thread the `KeiroMetrics` handle into the workers and call the helpers at
real call sites. This plan's job is to define the surface, name the instruments,
write the conventions audit that records those names, and prove the surface
records correctly in isolation.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — meter surface compiles:

- [x] Add a metrics section to the export list of `keiro/src/Keiro/Telemetry.hs` (instrument-name constants, `KeiroMetrics`, `newKeiroMetrics`, the recording helpers, and the re-exported `Meter`/`InstrumentationLibrary`). (2026-06-03)
- [x] Add the new imports from `OpenTelemetry.Metric.Core` and `OpenTelemetry.Attributes` to `Keiro.Telemetry`. (2026-06-03) — `InstrumentationLibrary(..)` imported from `OpenTelemetry.Trace.Core` instead (see Surprises), and only `emptyAttributes` imported from `OpenTelemetry.Attributes` (the `Attributes` type was unused).
- [x] Define the fourteen instrument-name constants as top-level `Text` bindings. (2026-06-03)
- [x] Define the `keiroInstrumentationLibrary` scope value. (2026-06-03)
- [x] Define the `KeiroMetrics` record with all fourteen instrument fields. (2026-06-03)
- [x] Define `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics`. (2026-06-03)
- [x] Define the thin `Maybe KeiroMetrics` recording helpers (one per instrument, plus the shared attribute builders). (2026-06-03)
- [x] Confirm the library compiles with `cabal build keiro`. (2026-06-03) — clean build, no warnings.

Milestone 2 — conventions audit metrics section:

- [x] Add a "Metrics" section to `docs/research/opentelemetry-semconv-audit.md` listing each instrument's name, unit, kind, description, attributes, and any OTel messaging-metric semconv alignment. (2026-06-03)
- [x] Add a metrics compliance table mirroring the existing span compliance table. (2026-06-03)

Milestone 3 — in-memory exporter test harness:

- [x] Add the metric-exporter imports to `keiro/test/Main.hs`. (2026-06-03) — reused the existing `Data.Vector qualified as Vector` alias and the already-imported `readIORef`; added only `Data.Word (Word64)` and the metric/SDK/exporter modules.
- [x] Add a `describe "Keiro.Telemetry metrics"` block that builds an SDK `MeterProvider` with the in-memory metric exporter, constructs `KeiroMetrics`, records sample measurements, force-flushes, and asserts the captured instrument names and values. (2026-06-03)
- [x] Add the negative assertion that a `Nothing`/noop handle records nothing. (2026-06-03)
- [x] Confirm the suite passes with `cabal test keiro:keiro-test`. (2026-06-03) — ran scoped to `--match "Keiro.Telemetry metrics"`; both examples pass, `2 examples, 0 failures`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03 (Milestone 1): The plan's Edit 2 instructed importing
  `InstrumentationLibrary (..)` from `OpenTelemetry.Metric.Core`, but that module
  imports `InstrumentationLibrary` from `OpenTelemetry.Internal.Common.Types`
  **without re-exporting it** (its export list ends before `InstrumentationLibrary`).
  The public re-export lives in `OpenTelemetry.Trace.Core` (line 142,
  `InstrumentationLibrary (..)`), which `Keiro.Telemetry` already imports for the
  span helpers. Resolved by adding `InstrumentationLibrary (..)` to the existing
  `OpenTelemetry.Trace.Core` import rather than the `Metric.Core` import. Verified
  against `hs-opentelemetry/api/src/OpenTelemetry/Metric/Core.hs` and
  `.../Trace/Core.hs`. No effect on the exported surface — `KeiroMetrics`,
  `newKeiroMetrics`, the names, and the helpers are unchanged.
- 2026-06-03 (Milestone 1): The plan's Edit 2 import block listed the `Attributes`
  type alongside `emptyAttributes`, but the new code references only the
  `emptyAttributes` value, so importing the `Attributes` type would trip
  `-Wunused-imports` under `-Wall`. Imported only `emptyAttributes`.

- 2026-06-03 (Milestone 3): Running the suite scoped with
  `--match "Keiro.Telemetry metrics"` still triggers the `withMigratedSuite`
  fixture, which prints a `codd` "DB and expected schemas do not match" message
  during template setup (PostgreSQL v18 + a pre-existing template database). This
  is an environmental quirk, **not** a failure: the run proceeded and finished
  with `2 examples, 0 failures`, both metrics examples `[✔]`. The metrics
  examples are DB-free (they build an SDK meter entirely in memory), so they are
  unaffected by the fixture warning. Recorded in case a future run sees the same
  message.
- 2026-06-03 (Milestone 2): The plan's M2 acceptance expected
  `grep -oE "keiro\.[a-z.]+" docs/research/opentelemetry-semconv-audit.md | sort -u`
  to print "exactly these fourteen" metric names. It actually prints those
  fourteen plus the pre-existing bespoke `keiro.*` *attribute-key* names the span
  half of the audit already documents (e.g. `keiro.stream.name`, `keiro.timer.id`,
  `keiro.events.appended`, `keiro.snapshot.stream`, `keiro.projection.name`). All
  fourteen metric instrument names are present and spelled to match the
  `Keiro.Telemetry` constants; the extras are not introduced by this plan. The
  acceptance intent (the fourteen metric names match the constants) holds.

(No behavioral surprises; the meter surface compiled cleanly with no warnings.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Add the metrics surface **inside** the existing `keiro/src/Keiro/Telemetry.hs`
  module rather than a new `Keiro.Telemetry.Metrics` module.
  Rationale: The MasterPlan integration point states that `Keiro.Telemetry` must
  remain "the single telemetry import for the library" (the rule EP-25 set for
  spans). Adding a sibling module would split the surface and force call sites to
  import two telemetry modules. Co-locating keeps one import and mirrors how the
  bespoke `keiro_*` `AttributeKey`s already live alongside the span helpers.
  Date: 2026-06-03.

- Decision: Extend the **existing** `docs/research/opentelemetry-semconv-audit.md`
  with a "Metrics" section rather than create a sibling document.
  Rationale: The audit already establishes the convention-citation format,
  legend, and compliance table for spans; metrics readers benefit from finding
  both halves in one file, and the existing "Metrics audit — separate from this
  plan" follow-up line at the bottom of that document is precisely the hook this
  plan fills. The MasterPlan permits either choice and leaves it to EP-33.
  Date: 2026-06-03.

- Decision: `KeiroMetrics` is a flat record of all fourteen pre-built instruments,
  built once by `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics`, and
  consumers thread it as `Maybe KeiroMetrics` (`Nothing` ⇒ record nothing).
  Rationale: Instruments are created once and recorded many times; rebuilding an
  instrument per measurement would be wrong (the SDK keys aggregation state by
  instrument identity) and wasteful. A flat record threaded as `Maybe` matches
  the existing `Maybe Tracer` idiom so the call shape is uniform across the
  tracing and metrics surfaces. The MasterPlan fixed this shape so EP-35/EP-36
  can consume it; this plan owns the final field names and signatures.
  Date: 2026-06-03.

- Decision: Provide a recording helper **per instrument** that takes
  `Maybe KeiroMetrics` and no-ops on `Nothing`, instead of exposing the raw
  instruments and letting callers call `counterAdd`/`gaugeRecord` directly.
  Rationale: It keeps each call site a one-liner, hides the attribute-building
  boilerplate, and centralises the `Nothing` branch so the no-op cost is a single
  `Maybe` test (the same ergonomics the span helpers give). EP-35/EP-36 call
  these helpers; they do not touch the instrument fields.
  Date: 2026-06-03.

- Decision: Backlog and lag are **synchronous gauges** (`Gauge Int64` recorded by
  the worker each poll pass), not asynchronous observable gauges. Tallies are
  `Counter Int64`; distributions are `Histogram` (Double values).
  Rationale: Fixed by the MasterPlan. An observable gauge's callback runs in `IO`
  on the SDK collection thread and would need its own database access to compute a
  backlog, which the library does not own. The workers already hold the `Store`
  effect and run periodically, so recording synchronously each pass is simpler,
  accurate to within one poll interval, and needs no new application wiring. This
  plan defines the synchronous instruments; offering an additional observable
  variant is out of scope here.
  Date: 2026-06-03.

- Decision: Instrument values are `Int64` for counters and gauges and `Double` for
  histograms. The two histograms record in milliseconds (`keiro.timer.fire.lag`)
  and in dimensionless attempt counts (`keiro.timer.attempts`).
  Rationale: Counts and backlogs are naturally integral and map to
  `meterCreateCounterInt64` / `meterCreateGaugeInt64`. Histograms in the upstream
  API record `Double` only (`histogramRecord :: Double -> Attributes -> IO ()`),
  so both histograms are `Double`. Fire lag is a duration, so milliseconds is the
  natural UCUM unit; attempt counts are unitless `{attempt}`.
  Date: 2026-06-03.

- Decision: Units follow UCUM-style annotation strings — `"{event}"`,
  `"{message}"`, `"{timer}"`, `"{attempt}"`, `"{timeout}"` for dimensionless
  counts and `"ms"` for the fire-lag duration.
  Rationale: The OpenTelemetry metric semantic conventions use curly-brace UCUM
  annotations for dimensionless counts (e.g. `{message}`) and `ms`/`s` for
  durations. Using annotations rather than an empty unit makes the exported unit
  self-describing on dashboards. The exact spellings are recorded in the audit so
  EP-35/EP-36 reference them verbatim.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-03): complete.** All three milestones landed and their
acceptance commands pass:

- `cabal build keiro` — clean build, no warnings. `Keiro.Telemetry` now exports
  the metrics surface: the `keiroInstrumentationLibrary` scope, the fourteen
  `keiro*Name` instrument-name constants, the `KeiroMetrics` record, the
  `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics` builder, the
  fourteen `record*` helpers, and re-exports of `Meter` and
  `InstrumentationLibrary`.
- `docs/research/opentelemetry-semconv-audit.md` gained a `## Metrics` section
  cataloguing all fourteen instruments (name / unit / kind / recording site /
  description / semconv alignment) plus a metrics compliance table; the closing
  follow-up bullet now points at it. The fourteen metric names match the
  `Keiro.Telemetry` constants exactly.
- `cabal test keiro:keiro-test --test-options='--match "Keiro.Telemetry metrics"'`
  — `2 examples, 0 failures`. The positive example proves a counter accumulates
  (`3 + 2 = 5`), a gauge keeps its last value (`7`), a histogram records one
  observation summing to `12.5`, and an unrecorded instrument exports no point;
  the negative example proves a `Nothing` handle exports nothing.

This matches the original purpose: the metrics foundation exists, is named, is
documented, and records correctly under a real SDK exporter, with no worker
instrumented (that is EP-35/EP-36). 

**Deviations from the plan as written** (all recorded in Surprises & Discoveries):
`InstrumentationLibrary` is imported from `OpenTelemetry.Trace.Core` (it is not
re-exported by `OpenTelemetry.Metric.Core`); the unused `Attributes` type import
was dropped; the test reuses the existing `Vector` alias and `readIORef` import.
None change the exported surface EP-35/EP-36 depend on.

**Gaps / follow-ups:** none for this plan. The `keiro.timer.stuck` gauge's
"stuck" threshold is defined by EP-34 (`findStuckTimers`); EP-36 wires the gauge
after EP-34 lands. The recording helpers currently record with `emptyAttributes`
(no per-measurement dimensions); EP-35/EP-36 may extend the helper signatures
with low-cardinality attributes later, per the integration-point note in the
MasterPlan.


## Context and Orientation

This section assumes you know nothing about the repository. Read it before editing.

**Repository layout.** The repo root is `/Users/shinzui/Keikaku/bokuno/keiro`.
It is a Haskell project built with `cabal` inside a nix dev shell. The library
package lives under `keiro/`: its source is in `keiro/src/Keiro/...`, its cabal
file is `keiro/keiro.cabal`, and its test suite is the single file
`keiro/test/Main.hs` (the cabal stanza is named `keiro-test`, verified by reading
`keiro/keiro.cabal` lines 94–127). There are two other packages — `keiro-core/`
(low-level types, re-exported by `keiro`) and `jitsurei/` (worked examples) — but
this plan touches neither.

**The module you will edit.** `keiro/src/Keiro/Telemetry.hs` is the library's one
OpenTelemetry surface. Today it exports span helpers (`withProducerSpan`,
`withConsumerSpan`, `withCommandSpan`), a W3C trace-context bridge, a set of
re-exported semantic-convention `AttributeKey`s, and three bespoke `keiro_*`
keys. Every helper takes a `Maybe Tracer`; under `Nothing` it runs the body
unwrapped. You will add a metrics half **alongside** these, leaving the existing
span code untouched.

**The upstream metrics API (already a dependency).** `keiro` already depends on
`hs-opentelemetry-api >= 1.0 && < 1.1` (see `keiro/keiro.cabal` line 75). That
package exposes the metrics API at module `OpenTelemetry.Metric.Core`. The facts
you need, verified by reading
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api/src/OpenTelemetry/Metric/Core.hs`
and `.../OpenTelemetry/Internal/Metric/Types.hs`:

- A `Meter` is a handle that creates instruments for one *instrumentation scope*
  (a name/version pair, type `InstrumentationLibrary`). You obtain a `Meter` from
  a `MeterProvider` with `getMeter :: MeterProvider -> InstrumentationLibrary ->
  IO Meter`. `InstrumentationLibrary` has an `IsString` instance, so with
  `OverloadedStrings` the literal `"keiro"` is a valid scope.
- The global default provider is `noopMeterProvider`, whose meter discards every
  measurement. This is why library instrumentation is unconditionally safe.
- Synchronous instrument **constructors** on a `Meter` all take the same first
  four arguments — *name* (`Text`), *unit* (`Maybe Text`), *description*
  (`Maybe Text`), and *advisory parameters* (`AdvisoryParameters`) — and return
  the instrument in `IO`:
  - `meterCreateCounterInt64 :: Meter -> Text -> Maybe Text -> Maybe Text -> AdvisoryParameters -> IO (Counter Int64)`
  - `meterCreateGaugeInt64 :: Meter -> Text -> Maybe Text -> Maybe Text -> AdvisoryParameters -> IO (Gauge Int64)`
  - `meterCreateHistogram :: Meter -> Text -> Maybe Text -> Maybe Text -> AdvisoryParameters -> IO Histogram`

  Note: in the source these are *record fields* of `Meter`, so the call form is
  `meterCreateCounterInt64 meter name unit desc adv`. Use
  `defaultAdvisoryParameters` for the advisory argument everywhere in this plan
  (it leaves bucket boundaries and attribute keys at the SDK defaults).
- The instruments are recorded with:
  - `counterAdd :: Counter a -> a -> Attributes -> IO ()` (a record field too;
    call it `counterAdd c n attrs`). Counters are monotonic; negative deltas are
    silently dropped.
  - `gaugeRecord :: Gauge a -> a -> Attributes -> IO ()` (last value per
    attribute set wins at collection).
  - `histogramRecord :: Histogram -> Double -> Attributes -> IO ()` (NaN/Inf
    silently dropped).
- `Attributes` is the OpenTelemetry attribute bag. Build the empty bag with
  `emptyAttributes` from `OpenTelemetry.Attributes`. For this foundation plan,
  the recording helpers record with `emptyAttributes` (no per-measurement
  dimensions); EP-35/EP-36 may add low-cardinality attributes later through the
  helper signatures this plan provides.

**The SDK and test exporter (already test dependencies).** The test suite already
depends on `hs-opentelemetry-sdk` and `hs-opentelemetry-exporter-in-memory` (see
`keiro/keiro.cabal` lines 110, 112), so **no new dependency is required**. The
SDK provides a real `MeterProvider` that aggregates in process. The facts you
need, verified by reading
`.../hs-opentelemetry/sdk/src/OpenTelemetry/MeterProvider.hs`,
`.../OpenTelemetry/Metric.hs`, and
`.../hs-opentelemetry/exporters/in-memory/src/OpenTelemetry/Exporter/InMemory/Metric.hs`:

- `OpenTelemetry.MeterProvider.createMeterProvider :: MaterializedResources ->
  SdkMeterProviderOptions -> IO (MeterProvider, SdkMeterEnv)` builds a provider.
  Pass `emptyMaterializedResources` (from `OpenTelemetry.Resource`) for the
  resource, and `defaultSdkMeterProviderOptions { metricExporter = Just ex }` for
  the options, where `ex` is the in-memory exporter.
- `OpenTelemetry.Exporter.InMemory.Metric.inMemoryMetricExporter :: (MonadIO m)
  => m (MetricExporter, IORef [ResourceMetricsExport])` returns a test exporter
  and an `IORef` that accumulates every exported batch. After a flush, read the
  `IORef` to inspect what was exported.
- `forceFlushMeterProvider :: MeterProvider -> Maybe Int -> IO FlushResult`
  (from `OpenTelemetry.Metric.Core`) runs one collect-and-export cycle; pass
  `Nothing` for the default timeout. After it returns, the in-memory `IORef`
  holds the exported metrics.

**The export shape you will assert against.** The in-memory exporter stores a
`[ResourceMetricsExport]`. Verified by reading
`.../hs-opentelemetry/api/src/OpenTelemetry/Internal/Metric/Export.hs`, the
nesting is: each `ResourceMetricsExport` has `resourceMetricsScopes :: Vector
ScopeMetricsExport`; each `ScopeMetricsExport` has `scopeMetricsExports :: Vector
MetricExport`; and `MetricExport` is a sum type whose constructors carry a
**name** field and the points. The two constructors this plan asserts against:

- `MetricExportSum { mesName :: Text, ..., mesSumPoints :: Vector SumDataPoint }`
  for counters and gauges' sums — wait, gauges are a separate constructor:
- `MetricExportGauge { megName :: Text, ..., megGaugePoints :: Vector GaugeDataPoint }`
  for gauges, and `MetricExportSum` for counters.
- `MetricExportHistogram { mehName :: Text, ..., mehPoints :: Vector HistogramDataPoint }`
  for histograms.

A `SumDataPoint` carries `sumDataPointValue :: NumberValue`; a `GaugeDataPoint`
carries `gaugeDataPointValue :: NumberValue`; a `HistogramDataPoint` carries
`histogramDataPointCount :: Word64` and `histogramDataPointSum :: Double`.
`NumberValue` is `IntNumber !Int64 | DoubleNumber !Double`. The test will flatten
every export into a list of `(name, value)` pairs and assert membership.

**The conventions audit you will extend.** `docs/research/opentelemetry-semconv-audit.md`
already audits the span sites and ends with a "Follow-ups" section whose final
bullet reads "Metrics audit — separate from this plan." You will add a Metrics
section above (or in place of) that bullet and update the bullet to point at this
section.

**Definitions of terms used below.** *Outbox*: a `keiro_outbox` table of pending
integration events that a background "publisher" worker reads and sends to a
message broker (Kafka). *Inbox*: the consumer side, where incoming messages are
recorded and de-duplicated. *Backlog*: the number of rows waiting to be processed
right now (a gauge). *Dead-letter*: a row that has exhausted its retry budget and
is parked for manual handling. *Timer*: a scheduled future action stored in a
table and fired by a timer worker. *Fire lag*: how late a timer actually fired
versus its scheduled time. *Projection*: a read-model updater that consumes the
event log; its *lag* is how far behind the log head it is. *Position-wait
timeout*: when a read waits for the projection to catch up to a position and
gives up. These are the operational signals the fourteen instruments capture.


## Plan of Work

The work proceeds in three independently verifiable milestones. Milestone 1
adds the metrics surface to `Keiro.Telemetry` and proves it **compiles**.
Milestone 2 writes the conventions audit metrics section (a pure documentation
change). Milestone 3 adds the in-memory-exporter test that proves the surface
**records correctly**. Each milestone names exact files, exact signatures, and
exact commands with expected output.

### Milestone 1 — the meter surface compiles

**Scope.** Edit only `keiro/src/Keiro/Telemetry.hs`. At the end of this
milestone, the library exposes (a) fourteen instrument-name `Text` constants,
(b) an instrumentation-scope value, (c) the `KeiroMetrics` record, (d)
`newKeiroMetrics`, (e) one recording helper per instrument, and (f) re-exports
of `Meter` and `InstrumentationLibrary` so a caller building a meter imports only
`Keiro.Telemetry`. Nothing in the existing span code changes. Acceptance: `cabal
build keiro` succeeds with no warnings (the package is built with `-Wall
-Wcompat` and friends, see `keiro/keiro.cabal` lines 18–21, so unused bindings or
incomplete patterns will fail the build).

**Edit 1 — exports.** In the module header export list of
`keiro/src/Keiro/Telemetry.hs` (currently lines 27–58), add a new export group
after the existing groups. Add, in prose order: the re-exports `Meter` and
`InstrumentationLibrary`; the scope value `keiroInstrumentationLibrary`; the
fourteen instrument-name constants; the record type `KeiroMetrics(..)`; the
builder `newKeiroMetrics`; and the fourteen recording helpers. Keep the existing
span and attribute exports exactly as they are.

**Edit 2 — imports.** Add these imports near the existing
`hs-opentelemetry-api` imports (the file uses `PackageImports`, so keep the
`"hs-opentelemetry-api"` package qualifier to match the file's style):

```haskell
import "hs-opentelemetry-api" OpenTelemetry.Metric.Core
  ( AdvisoryParameters
  , Counter
  , Gauge
  , Histogram
  , InstrumentationLibrary (..)
  , Meter
  , counterAdd
  , defaultAdvisoryParameters
  , gaugeRecord
  , histogramRecord
  , meterCreateCounterInt64
  , meterCreateGaugeInt64
  , meterCreateHistogram
  )
import "hs-opentelemetry-api" OpenTelemetry.Attributes (Attributes, emptyAttributes)
```

`MonadIO`, `Text`, and `Int64` are already in scope via `Keiro.Prelude` (the
existing `keiro_*` keys use `Int64` and the helpers use `MonadIO`); if the build
reports any of them missing, import them explicitly (`Int64` from `Data.Int`,
`MonadIO`/`liftIO` from `Control.Monad.IO.Class`).

**Edit 3 — the instrumentation scope.** Add a single scope value the library
uses for all its instruments:

```haskell
-- | The instrumentation scope keiro tags all its metric instruments with.
-- Mirrors the @"keiro"@ scope name the span helpers use on the application's
-- 'Tracer'.
keiroInstrumentationLibrary :: InstrumentationLibrary
keiroInstrumentationLibrary =
  InstrumentationLibrary
    { libraryName = "keiro"
    , libraryVersion = ""
    , librarySchemaUrl = ""
    , libraryAttributes = emptyAttributes
    }
```

(The `IsString` instance would also let you write `"keiro"`, but spelling out the
record makes the version field explicit for a future bump.)

**Edit 4 — instrument-name constants.** Add the fourteen canonical names as
top-level `Text` bindings. These are the exact strings the SDK will export and
that EP-35/EP-36 reference verbatim:

```haskell
keiroOutboxBacklogName       :: Text
keiroOutboxBacklogName       = "keiro.outbox.backlog"
keiroOutboxPublishedName     :: Text
keiroOutboxPublishedName     = "keiro.outbox.published"
keiroOutboxRetriedName       :: Text
keiroOutboxRetriedName       = "keiro.outbox.retried"
keiroOutboxDeadletteredName  :: Text
keiroOutboxDeadletteredName  = "keiro.outbox.deadlettered"
keiroInboxProcessedName      :: Text
keiroInboxProcessedName      = "keiro.inbox.processed"
keiroInboxDuplicatesName     :: Text
keiroInboxDuplicatesName     = "keiro.inbox.duplicates"
keiroInboxFailedName         :: Text
keiroInboxFailedName         = "keiro.inbox.failed"
keiroInboxBacklogName        :: Text
keiroInboxBacklogName        = "keiro.inbox.backlog"
keiroTimerBacklogName        :: Text
keiroTimerBacklogName        = "keiro.timer.backlog"
keiroTimerFireLagName        :: Text
keiroTimerFireLagName        = "keiro.timer.fire.lag"
keiroTimerAttemptsName       :: Text
keiroTimerAttemptsName       = "keiro.timer.attempts"
keiroTimerStuckName          :: Text
keiroTimerStuckName          = "keiro.timer.stuck"
keiroProjectionLagName       :: Text
keiroProjectionLagName       = "keiro.projection.lag"
keiroProjectionWaitTimeoutsName :: Text
keiroProjectionWaitTimeoutsName = "keiro.projection.wait.timeouts"
```

**Edit 5 — the `KeiroMetrics` record.** Add the record holding all fourteen
pre-built instruments. The kind of each field is fixed by the
INSTRUMENT KIND POLICY: backlog/lag/stuck are `Gauge Int64`; tallies are
`Counter Int64`; the two distributions are `Histogram`:

```haskell
{- | All metric instruments the keiro library records, built once from a
'Meter' by 'newKeiroMetrics'. Workers accept a @'Maybe' 'KeiroMetrics'@ and
treat 'Nothing' as "record nothing"; the per-instrument recording helpers in
this module take @'Maybe' 'KeiroMetrics'@ so call sites stay one-liners.

Instrument kinds follow the keiro metrics policy: backlog and lag are
synchronous gauges recorded by each worker per poll pass; tallies are
monotonic counters; distributions are histograms. See
@docs/research/opentelemetry-semconv-audit.md@ for the per-instrument
name / unit / kind / description catalogue.
-}
data KeiroMetrics = KeiroMetrics
  { outboxBacklog      :: Gauge Int64
  , outboxPublished    :: Counter Int64
  , outboxRetried      :: Counter Int64
  , outboxDeadlettered :: Counter Int64
  , inboxProcessed     :: Counter Int64
  , inboxDuplicates    :: Counter Int64
  , inboxFailed        :: Counter Int64
  , inboxBacklog       :: Gauge Int64
  , timerBacklog       :: Gauge Int64
  , timerFireLag       :: Histogram
  , timerAttempts      :: Histogram
  , timerStuck         :: Gauge Int64
  , projectionLag      :: Gauge Int64
  , projectionWaitTimeouts :: Counter Int64
  }
```

This record uses `DuplicateRecordFields` (already on in the cabal `shared`
common stanza, `keiro/keiro.cabal` line 26), so the field names need not be
globally unique; callers use them via the helpers below, not directly.

**Edit 6 — `newKeiroMetrics`.** Add the builder. It calls each constructor once
with the matching name, unit, and description. The unit and description strings
are the *exact* values recorded in the audit (Milestone 2). Use
`defaultAdvisoryParameters` for every advisory argument:

```haskell
{- | Construct every keiro metric instrument from a 'Meter'. Call this once at
application start after building an SDK 'MeterProvider' and obtaining a 'Meter'
(e.g. @getMeter mp keiroInstrumentationLibrary@), then thread the resulting
'KeiroMetrics' into workers as @'Just' metrics@. Under a no-op meter every
instrument is itself a no-op, so this is safe to call unconditionally.
-}
newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics
newKeiroMetrics meter = liftIO $ do
  outboxBacklog'      <- gaugeI64 keiroOutboxBacklogName "{event}" "Outbox rows awaiting publish."
  outboxPublished'    <- counterI64 keiroOutboxPublishedName "{event}" "Outbox events successfully published."
  outboxRetried'      <- counterI64 keiroOutboxRetriedName "{event}" "Outbox publish attempts that failed and will retry."
  outboxDeadlettered' <- counterI64 keiroOutboxDeadletteredName "{event}" "Outbox events parked after exhausting retries."
  inboxProcessed'     <- counterI64 keiroInboxProcessedName "{message}" "Inbox messages processed successfully."
  inboxDuplicates'    <- counterI64 keiroInboxDuplicatesName "{message}" "Inbox messages skipped as duplicates."
  inboxFailed'        <- counterI64 keiroInboxFailedName "{message}" "Inbox messages whose handler failed."
  inboxBacklog'       <- gaugeI64 keiroInboxBacklogName "{message}" "Inbox messages awaiting processing."
  timerBacklog'       <- gaugeI64 keiroTimerBacklogName "{timer}" "Due timers awaiting firing."
  timerFireLag'       <- histogram keiroTimerFireLagName "ms" "Delay between a timer's scheduled time and when it fired."
  timerAttempts'      <- histogram keiroTimerAttemptsName "{attempt}" "Number of attempts a timer took to fire."
  timerStuck'         <- gaugeI64 keiroTimerStuckName "{timer}" "Timers stuck in the Firing state past threshold."
  projectionLag'      <- gaugeI64 keiroProjectionLagName "{event}" "Events between the log head and a projection's checkpoint."
  projectionWaitTimeouts' <- counterI64 keiroProjectionWaitTimeoutsName "{timeout}" "Position-wait calls that timed out before the projection caught up."
  pure
    KeiroMetrics
      { outboxBacklog = outboxBacklog'
      , outboxPublished = outboxPublished'
      , outboxRetried = outboxRetried'
      , outboxDeadlettered = outboxDeadlettered'
      , inboxProcessed = inboxProcessed'
      , inboxDuplicates = inboxDuplicates'
      , inboxFailed = inboxFailed'
      , inboxBacklog = inboxBacklog'
      , timerBacklog = timerBacklog'
      , timerFireLag = timerFireLag'
      , timerAttempts = timerAttempts'
      , timerStuck = timerStuck'
      , projectionLag = projectionLag'
      , projectionWaitTimeouts = projectionWaitTimeouts'
      }
  where
    counterI64 :: Text -> Text -> Text -> IO (Counter Int64)
    counterI64 name unit desc =
      meterCreateCounterInt64 meter name (Just unit) (Just desc) defaultAdvisoryParameters
    gaugeI64 :: Text -> Text -> Text -> IO (Gauge Int64)
    gaugeI64 name unit desc =
      meterCreateGaugeInt64 meter name (Just unit) (Just desc) defaultAdvisoryParameters
    histogram :: Text -> Text -> Text -> IO Histogram
    histogram name unit desc =
      meterCreateHistogram meter name (Just unit) (Just desc) defaultAdvisoryParameters
```

**Edit 7 — recording helpers.** Add one helper per instrument. Each takes
`Maybe KeiroMetrics`, no-ops on `Nothing`, and records with `emptyAttributes`.
Counters and gauges take an `Int64`; histograms take a `Double`. Define one
private dispatcher per instrument kind to avoid repetition:

```haskell
-- Internal: record an Int64 on the counter selected by @sel@, or do nothing.
recordCounter
  :: (MonadIO m) => (KeiroMetrics -> Counter Int64) -> Maybe KeiroMetrics -> Int64 -> m ()
recordCounter _ Nothing _ = pure ()
recordCounter sel (Just ms) n = liftIO (counterAdd (sel ms) n emptyAttributes)

-- Internal: record an Int64 on the gauge selected by @sel@, or do nothing.
recordGaugeI64
  :: (MonadIO m) => (KeiroMetrics -> Gauge Int64) -> Maybe KeiroMetrics -> Int64 -> m ()
recordGaugeI64 _ Nothing _ = pure ()
recordGaugeI64 sel (Just ms) n = liftIO (gaugeRecord (sel ms) n emptyAttributes)

-- Internal: record a Double on the histogram selected by @sel@, or do nothing.
recordHistogram
  :: (MonadIO m) => (KeiroMetrics -> Histogram) -> Maybe KeiroMetrics -> Double -> m ()
recordHistogram _ Nothing _ = pure ()
recordHistogram sel (Just ms) v = liftIO (histogramRecord (sel ms) v emptyAttributes)
```

Then the fourteen public helpers, each a one-liner over the dispatchers. Name
them `record<Instrument>`:

```haskell
recordOutboxBacklog       :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordOutboxBacklog       = recordGaugeI64 outboxBacklog
recordOutboxPublished     :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordOutboxPublished     = recordCounter outboxPublished
recordOutboxRetried       :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordOutboxRetried       = recordCounter outboxRetried
recordOutboxDeadlettered  :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordOutboxDeadlettered  = recordCounter outboxDeadlettered
recordInboxProcessed      :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordInboxProcessed      = recordCounter inboxProcessed
recordInboxDuplicates     :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordInboxDuplicates     = recordCounter inboxDuplicates
recordInboxFailed         :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordInboxFailed         = recordCounter inboxFailed
recordInboxBacklog        :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordInboxBacklog        = recordGaugeI64 inboxBacklog
recordTimerBacklog        :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordTimerBacklog        = recordGaugeI64 timerBacklog
recordTimerFireLag        :: (MonadIO m) => Maybe KeiroMetrics -> Double -> m ()
recordTimerFireLag        = recordHistogram timerFireLag
recordTimerAttempts       :: (MonadIO m) => Maybe KeiroMetrics -> Double -> m ()
recordTimerAttempts       = recordHistogram timerAttempts
recordTimerStuck          :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordTimerStuck          = recordGaugeI64 timerStuck
recordProjectionLag       :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordProjectionLag       = recordGaugeI64 projectionLag
recordProjectionWaitTimeouts :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordProjectionWaitTimeouts = recordCounter projectionWaitTimeouts
```

Export from `Keiro.Telemetry`: `keiroInstrumentationLibrary`, all fourteen
`*Name` constants, `KeiroMetrics(..)`, `newKeiroMetrics`, all fourteen
`record*` helpers, and the re-exports `Meter` and `InstrumentationLibrary(..)`.
Do **not** export the three private dispatchers (`recordCounter`,
`recordGaugeI64`, `recordHistogram`) — if you do, `-Wall` will not complain, but
keeping them internal preserves the "helpers are one-liners" surface. Because
`-Wall` flags unused top-level bindings only when they are *not* exported, every
binding you add must either be exported or used; the three dispatchers are used
by the helpers, so they are fine to leave unexported.

**Acceptance for Milestone 1.** From the repo root inside the nix dev shell:

```bash
cabal build keiro
```

Expect a successful build ending roughly like:

```text
[ 1 of 22] Compiling Keiro.Telemetry  ( keiro/src/Keiro/Telemetry.hs, ... )
...
Linking ...
```

No warnings should appear for the new code. If `-Wunused-imports` flags a metric
import you did not end up using, remove it; if `-Wincomplete-patterns` fires,
check that each dispatcher has both the `Nothing` and `Just` equations.

### Milestone 2 — conventions audit metrics section

**Scope.** Edit only `docs/research/opentelemetry-semconv-audit.md`. At the end,
the audit has a "Metrics" section cataloguing all fourteen instruments (name,
unit, kind, description, attributes, and any OTel messaging-metric semconv
alignment) plus a metrics compliance table, and the closing follow-up bullet
"Metrics audit — separate from this plan" is updated to reference the new
section. This is a pure documentation change; acceptance is that the section
exists, the fourteen names match the constants from Milestone 1 exactly, and the
messaging-metric semconv anchors cited are real.

**The messaging-metric semconv anchors to cite.** Verified by grepping the
generated module
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs`,
the relevant Haddock anchors are:

- `-- $metric_messaging_client_sent_messages` (line 3407) — the spec metric
  `messaging.client.sent.messages`, a counter of messages a producer sent.
  `keiro.outbox.published` is keiro's analogue; cite this anchor as the closest
  spec alignment and note that keiro uses its bespoke `keiro.outbox.published`
  name because the library is event-sourcing-specific and tracks
  retried/deadlettered separately, which the spec metric does not.
- `-- $metric_messaging_client_consumed_messages` (line 3410) — the spec metric
  `messaging.client.consumed.messages`, a counter of messages a consumer
  consumed. `keiro.inbox.processed` is the analogue; same note about the bespoke
  name and the extra duplicates/failed breakdown.
- `-- $metric_messaging_process_duration` (line 3404) — `messaging.process.duration`,
  a histogram of consumer processing time. Not a direct match for any keiro
  instrument (keiro's histograms are timer-specific), but cite it as the spec's
  precedent for a messaging histogram.

The backlog gauges, timer instruments, and projection instruments have **no**
messaging-metric semconv equivalent; state that plainly (the spec's messaging
metrics are client send/consume/duration oriented, not queue-depth oriented), so
the bespoke `keiro.*` namespace is the right home, exactly as the bespoke
`keiro_*` attribute keys are for spans.

**The section to add.** Insert a "## Metrics" section before the
"## Verifying the citations" section. For each instrument write a short prose
paragraph naming: the instrument name (matching the Milestone 1 constant), the
unit, the kind (Counter / Gauge / Histogram), the recording site it will be
called from once EP-35/EP-36 land (the worker and the helper name), the
description string (matching `newKeiroMetrics` exactly), and the semconv
alignment line. Group them under sub-headings "### Outbox", "### Inbox",
"### Timer", "### Projection".

Then add a compliance table mirroring the existing span table at the end of the
audit:

```text
| Instrument                       | Unit       | Kind      | Recording site (EP-35/EP-36)              | Semconv alignment                                   |
| -------------------------------- | ---------- | --------- | ----------------------------------------- | --------------------------------------------------- |
| keiro.outbox.backlog             | {event}    | Gauge     | outbox publisher, per poll pass           | none (queue-depth; no messaging-metric equivalent)  |
| keiro.outbox.published           | {event}    | Counter   | outbox publisher, on publish success      | $metric_messaging_client_sent_messages 3407 (loose) |
| keiro.outbox.retried             | {event}    | Counter   | outbox publisher, on transient failure    | none                                                |
| keiro.outbox.deadlettered        | {event}    | Counter   | outbox publisher, on retry exhaustion     | none                                                |
| keiro.inbox.processed            | {message}  | Counter   | inbox runner, on handler success          | $metric_messaging_client_consumed_messages 3410     |
| keiro.inbox.duplicates           | {message}  | Counter   | inbox runner, on duplicate skip           | none                                                |
| keiro.inbox.failed               | {message}  | Counter   | inbox runner, on handler failure          | none                                                |
| keiro.inbox.backlog              | {message}  | Gauge     | inbox runner, per poll pass               | none (queue-depth)                                  |
| keiro.timer.backlog              | {timer}    | Gauge     | timer worker, per poll pass               | none                                                |
| keiro.timer.fire.lag             | ms         | Histogram | timer worker, on fire                     | $metric_messaging_process_duration 3404 (precedent) |
| keiro.timer.attempts             | {attempt}  | Histogram | timer worker, on fire                     | none                                                |
| keiro.timer.stuck                | {timer}    | Gauge     | timer worker, per poll pass (after EP-34) | none                                                |
| keiro.projection.lag             | {event}    | Gauge     | async projection drain, per pass          | none                                                |
| keiro.projection.wait.timeouts   | {timeout}  | Counter   | position-wait path, on timeout            | none                                                |
```

Finally, update the closing follow-up bullet. Change the line
"- **Metrics audit** — separate from this plan." to point at the new section,
e.g. "- **Metrics audit** — see the `## Metrics` section above (added by
`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`)."

**Acceptance for Milestone 2.** The fourteen names in the audit match the
Milestone 1 constants character-for-character. Verify with:

```bash
grep -oE "keiro\.[a-z.]+" docs/research/opentelemetry-semconv-audit.md | sort -u
```

Expect exactly these fourteen lines (order will be sorted):

```text
keiro.inbox.backlog
keiro.inbox.duplicates
keiro.inbox.failed
keiro.inbox.processed
keiro.outbox.backlog
keiro.outbox.deadlettered
keiro.outbox.published
keiro.outbox.retried
keiro.projection.lag
keiro.projection.wait.timeouts
keiro.timer.attempts
keiro.timer.backlog
keiro.timer.fire.lag
keiro.timer.stuck
```

And confirm the cited anchors exist in the generated module:

```bash
grep -nE "metric_messaging_client_sent_messages|metric_messaging_client_consumed_messages|metric_messaging_process_duration" \
  /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
```

Expect three matching lines around 3404–3410.

### Milestone 3 — the in-memory exporter test harness

**Scope.** Edit only `keiro/test/Main.hs`. At the end, the suite has a
`describe "Keiro.Telemetry metrics"` block with two examples: a positive case
that records through a real SDK meter and asserts the exporter captured the right
instrument names and values, and a negative case that records through `Nothing`
and asserts nothing was exported. No new dependency is needed (the SDK and
in-memory metric exporter are already test dependencies, `keiro/keiro.cabal`
lines 110, 112). Acceptance: `cabal test keiro:keiro-test` passes including the
two new examples.

**Edit 1 — imports.** Add near the existing telemetry test imports (around
`keiro/test/Main.hs` lines 126–144):

```haskell
import OpenTelemetry.Metric.Core
  ( forceFlushMeterProvider
  , getMeter
  )
import OpenTelemetry.MeterProvider
  ( SdkMeterProviderOptions (..)
  , createMeterProvider
  , defaultSdkMeterProviderOptions
  )
import OpenTelemetry.Exporter.InMemory.Metric (inMemoryMetricExporter)
import OpenTelemetry.Exporter.Metric
  ( GaugeDataPoint (..)
  , MetricExport (..)
  , NumberValue (..)
  , ResourceMetricsExport (..)
  , ScopeMetricsExport (..)
  , SumDataPoint (..)
  , HistogramDataPoint (..)
  )
import OpenTelemetry.Resource (emptyMaterializedResources)
import Data.IORef (readIORef)
import qualified Data.Vector as V
```

`Telemetry` is already imported qualified (`keiro/test/Main.hs` line 105:
`import Keiro.Telemetry qualified as Telemetry`), so reference the new surface as
`Telemetry.newKeiroMetrics`, `Telemetry.recordOutboxPublished`, etc.

**Edit 2 — a flattening helper.** Add a top-level helper near the other test
helpers (e.g. next to `inMemoryAdapter` at the bottom of the file) that flattens
the export tree into `(name, NumberValue)` pairs for counters and gauges, and a
parallel one for histogram `(name, count, sum)`:

```haskell
-- Flatten exported counter/gauge points to (instrument name, value).
flattenScalarPoints :: [ResourceMetricsExport] -> [(Text, NumberValue)]
flattenScalarPoints rmes =
  [ (name, val)
  | rme <- rmes
  , scope <- V.toList (resourceMetricsScopes rme)
  , export <- V.toList (scopeMetricsExports scope)
  , (name, val) <- pointsOf export
  ]
  where
    pointsOf (MetricExportSum n _ _ _ _ _ _ pts) =
      [ (n, sumDataPointValue p) | p <- V.toList pts ]
    pointsOf (MetricExportGauge n _ _ _ _ pts) =
      [ (n, gaugeDataPointValue p) | p <- V.toList pts ]
    pointsOf _ = []

-- Flatten exported histogram points to (instrument name, count, sum).
flattenHistogramPoints :: [ResourceMetricsExport] -> [(Text, Word64, Double)]
flattenHistogramPoints rmes =
  [ (n, histogramDataPointCount p, histogramDataPointSum p)
  | rme <- rmes
  , scope <- V.toList (resourceMetricsScopes rme)
  , export <- V.toList (scopeMetricsExports scope)
  , MetricExportHistogram n _ _ _ _ pts <- [export]
  , p <- V.toList pts
  ]
```

`Word64` comes from `Data.Word` — add `import Data.Word (Word64)` if not already
present. The field-pattern arities for `MetricExportSum`/`MetricExportGauge`/
`MetricExportHistogram` match the constructor definitions read from
`OpenTelemetry/Internal/Metric/Export.hs` (Sum has 8 fields, Gauge has 6,
Histogram has 6); if a future upstream bump changes the arity, the compiler will
tell you and you adjust the wildcard count.

**Edit 3 — the test block.** Add inside the top-level `hspec $ do` in `main`
(anywhere among the `describe` blocks; it needs no database, so it does not use
`fixture`):

```haskell
  describe "Keiro.Telemetry metrics" $ do
    it "records instrument names and values through an SDK meter" $ do
      (exporter, ref) <- inMemoryMetricExporter
      (provider, _env) <-
        createMeterProvider
          emptyMaterializedResources
          defaultSdkMeterProviderOptions {metricExporter = Just exporter}
      meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
      metrics <- Telemetry.newKeiroMetrics meter
      let h = Just metrics
      -- A counter (monotonic sum), a gauge (last value wins), a histogram.
      Telemetry.recordOutboxPublished h 3
      Telemetry.recordOutboxPublished h 2
      Telemetry.recordOutboxBacklog h 7
      Telemetry.recordInboxDuplicates h 1
      Telemetry.recordTimerFireLag h 12.5
      _ <- forceFlushMeterProvider provider Nothing
      exported <- readIORef ref
      let scalars = flattenScalarPoints exported
          hists = flattenHistogramPoints exported
      -- The counter accumulated 3 + 2 = 5.
      lookup "keiro.outbox.published" scalars `shouldBe` Just (IntNumber 5)
      -- The gauge holds its last recorded value.
      lookup "keiro.outbox.backlog" scalars `shouldBe` Just (IntNumber 7)
      -- The duplicate counter holds 1.
      lookup "keiro.inbox.duplicates" scalars `shouldBe` Just (IntNumber 1)
      -- The histogram saw one observation summing to 12.5.
      let lag = [ (c, s) | (n, c, s) <- hists, n == "keiro.timer.fire.lag" ]
      lag `shouldBe` [(1, 12.5)]
      -- Instruments we never recorded export no points.
      lookup "keiro.timer.stuck" scalars `shouldBe` Nothing

    it "records nothing through a Nothing handle" $ do
      (exporter, ref) <- inMemoryMetricExporter
      (provider, _env) <-
        createMeterProvider
          emptyMaterializedResources
          defaultSdkMeterProviderOptions {metricExporter = Just exporter}
      -- A Nothing handle is the no-op path: helpers must short-circuit.
      let h = Nothing
      Telemetry.recordOutboxPublished h 99
      Telemetry.recordOutboxBacklog h 99
      Telemetry.recordTimerFireLag h 99.0
      _ <- forceFlushMeterProvider provider Nothing
      exported <- readIORef ref
      flattenScalarPoints exported `shouldBe` []
      flattenHistogramPoints exported `shouldBe` []
```

The negative case builds a real provider but records through `Nothing`, proving
the helper short-circuits **before** touching any instrument. (Recording through
`Just` instruments built from a no-op meter would also export nothing, but
routing through `Nothing` is the exact path EP-35/EP-36 use when an application
does not configure metrics, so it is the more faithful negative test.)

**Acceptance for Milestone 3.** From the repo root inside the nix dev shell:

```bash
cabal test keiro:keiro-test
```

Expect the new examples to pass, with output containing:

```text
  Keiro.Telemetry metrics
    records instrument names and values through an SDK meter [✔]
    records nothing through a Nothing handle [✔]
```

and the suite finishing with `0 failures`.


## Concrete Steps

Run all commands from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro` inside the nix dev shell (the shell that
provides `cabal` and GHC 9.12). The steps are ordered; each milestone's
acceptance command is the gate to the next.

1. **Edit the library.** Apply Milestone 1 edits 1–7 to
   `keiro/src/Keiro/Telemetry.hs`. Then build only the library to catch errors
   fast:

   ```bash
   cabal build keiro
   ```

   Expected tail of a clean build:

   ```text
   [n of m] Compiling Keiro.Telemetry  ( keiro/src/Keiro/Telemetry.hs, dist-newstyle/... )
   ...
   ```

   with no warnings about the new bindings. If you see
   `Not in scope: meterCreateGaugeInt64` (or similar), re-check Edit 2's import
   list. If you see an "unused import" warning, delete the offending import.

2. **Write the audit section.** Apply Milestone 2 to
   `docs/research/opentelemetry-semconv-audit.md`. Verify the names and anchors:

   ```bash
   grep -oE "keiro\.[a-z.]+" docs/research/opentelemetry-semconv-audit.md | sort -u
   grep -nE "metric_messaging_client_sent_messages|metric_messaging_client_consumed_messages|metric_messaging_process_duration" \
     /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
   ```

   The first command must print exactly the fourteen names listed in Milestone 2's
   acceptance; the second must print three lines near 3404–3410.

3. **Write the test.** Apply Milestone 3 edits 1–3 to `keiro/test/Main.hs`. Run
   the suite:

   ```bash
   cabal test keiro:keiro-test
   ```

   Expected: the two new `Keiro.Telemetry metrics` examples pass and the run ends
   with `0 failures`. The metrics examples need no PostgreSQL — they build an SDK
   meter entirely in memory — so they pass even if the DB-backed examples in the
   suite are skipped or fail for environmental reasons; if the overall run cannot
   start because of the DB fixture, run with hspec's match filter to scope to the
   metrics block:

   ```bash
   cabal test keiro:keiro-test --test-options='--match "Keiro.Telemetry metrics"'
   ```

   Expected output:

   ```text
   Keiro.Telemetry metrics
     records instrument names and values through an SDK meter [✔]
     records nothing through a Nothing handle [✔]

   Finished in 0.00xx seconds
   2 examples, 0 failures
   ```

4. **Update Progress.** Tick the Progress checkboxes for whichever steps are done
   and record any deviation in Surprises & Discoveries and the Decision Log.


## Validation and Acceptance

The plan is complete when all three of the following observable behaviors hold,
each phrased as a command and the output a human can check.

**The library exposes the metrics surface and compiles.** Running
`cabal build keiro` from the repo root succeeds. A developer can open a `ghci`
session (`cabal repl keiro`) and evaluate the names, e.g.
`Keiro.Telemetry.keiroOutboxPublishedName` prints `"keiro.outbox.published"`,
and `:t Keiro.Telemetry.newKeiroMetrics` prints
`Keiro.Telemetry.newKeiroMetrics :: MonadIO m => Meter -> m KeiroMetrics`. This
proves the surface exists with the signatures EP-35/EP-36 depend on.

**The conventions audit catalogues exactly the fourteen instruments.** Running
`grep -oE "keiro\.[a-z.]+" docs/research/opentelemetry-semconv-audit.md | sort -u`
prints exactly the fourteen canonical names with no extras and no omissions, and
each name's unit/kind/description in the audit matches the corresponding
`newKeiroMetrics` line. This proves the names EP-35/EP-36 reference are recorded
and authoritative.

**The surface records correctly under a real exporter.** Running
`cabal test keiro:keiro-test` (or the scoped variant in Concrete Steps step 3)
shows the two `Keiro.Telemetry metrics` examples passing. The positive example
proves that a counter accumulates (`3 + 2 = 5`), that a gauge keeps its last
value (`7`), that a histogram records one observation summing to `12.5`, and that
an instrument we never recorded exports no point. The negative example proves
that recording through a `Nothing` handle exports nothing at all. Together these
demonstrate the surface beyond compilation: the bytes the SDK would send to a
real OTLP backend carry exactly the names and values keiro recorded.

This plan does **not** instrument any worker, so there is no end-to-end
worker-metric scenario to validate here; that is EP-35/EP-36's acceptance. The
in-memory test is the faithful isolation proof that the foundation is sound.


## Idempotence and Recovery

Every step is additive and safe to repeat. Re-running `cabal build keiro` or
`cabal test keiro:keiro-test` is idempotent. The edits to
`keiro/src/Keiro/Telemetry.hs` only **add** exports, bindings, and a record; they
do not modify the existing span helpers, so re-applying a partial edit cannot
corrupt the tracing surface — if a binding already exists, the second edit is a
no-op or a compile error you fix in place. The audit edit only adds a section and
rewrites one follow-up bullet; if run twice, you would get a duplicate section,
which is obvious and removable. The test edit only adds a `describe` block and
two helpers; a duplicate `describe` block compiles and runs both copies
harmlessly (remove the duplicate). No database migration, no destructive
operation, and no global state are involved (the test builds its own
`MeterProvider`; it never calls `setGlobalMeterProvider`, so it cannot disturb
any other test). If the build fails midway, no partial state persists beyond the
edited source files, which are under version control; revert with
`git checkout -- keiro/src/Keiro/Telemetry.hs` (and the other two files) to
return to a clean tree.

When the implementation lands, commits must carry the git trailers
`MasterPlan: docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md`,
`ExecPlan: docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`,
and `Intention: intention_01kt5v38ztez0tt5b63nr7gbnx`. Do not commit unless the
user asks.


## Interfaces and Dependencies

**Libraries used (all already declared in `keiro/keiro.cabal`).** The library
edits use `hs-opentelemetry-api >= 1.0 && < 1.1` (line 75) for
`OpenTelemetry.Metric.Core` (instrument types and constructors) and
`OpenTelemetry.Attributes` (the attribute bag). The test edits additionally use
`hs-opentelemetry-sdk >= 1.0 && < 1.1` (line 112) for
`OpenTelemetry.MeterProvider` (the SDK provider) and
`hs-opentelemetry-exporter-in-memory >= 1.0 && < 1.1` (line 110) for
`OpenTelemetry.Exporter.InMemory.Metric`. **No new dependency is added** to
either stanza.

**Why these and not alternatives.** The upstream metrics API ships a no-op meter
provider as the global default, which is what makes unconditional library
instrumentation safe and mirrors the existing no-op `Tracer` pattern. The SDK's
synchronous instruments (`Gauge`, `Counter`, `Histogram`) are used because the
MasterPlan fixed backlog/lag as worker-recorded synchronous gauges (an
observable callback would need DB access the library does not own). The in-memory
metric exporter is used in tests because it captures exported batches in an
`IORef` with no network or broker, giving a deterministic assertion target.

**Exact signatures that must exist at the end of Milestone 1** (in
`keiro/src/Keiro/Telemetry.hs`, all exported unless marked internal):

```haskell
keiroInstrumentationLibrary :: InstrumentationLibrary

keiroOutboxBacklogName          :: Text
keiroOutboxPublishedName        :: Text
keiroOutboxRetriedName          :: Text
keiroOutboxDeadletteredName     :: Text
keiroInboxProcessedName         :: Text
keiroInboxDuplicatesName        :: Text
keiroInboxFailedName            :: Text
keiroInboxBacklogName           :: Text
keiroTimerBacklogName           :: Text
keiroTimerFireLagName           :: Text
keiroTimerAttemptsName          :: Text
keiroTimerStuckName             :: Text
keiroProjectionLagName          :: Text
keiroProjectionWaitTimeoutsName :: Text

data KeiroMetrics = KeiroMetrics
  { outboxBacklog          :: Gauge Int64
  , outboxPublished        :: Counter Int64
  , outboxRetried          :: Counter Int64
  , outboxDeadlettered     :: Counter Int64
  , inboxProcessed         :: Counter Int64
  , inboxDuplicates        :: Counter Int64
  , inboxFailed            :: Counter Int64
  , inboxBacklog           :: Gauge Int64
  , timerBacklog           :: Gauge Int64
  , timerFireLag           :: Histogram
  , timerAttempts          :: Histogram
  , timerStuck             :: Gauge Int64
  , projectionLag          :: Gauge Int64
  , projectionWaitTimeouts :: Counter Int64
  }

newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics

recordOutboxBacklog          :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordOutboxPublished        :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordOutboxRetried          :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordOutboxDeadlettered     :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordInboxProcessed         :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordInboxDuplicates        :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordInboxFailed            :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordInboxBacklog           :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordTimerBacklog           :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordTimerFireLag           :: (MonadIO m) => Maybe KeiroMetrics -> Double -> m ()
recordTimerAttempts          :: (MonadIO m) => Maybe KeiroMetrics -> Double -> m ()
recordTimerStuck             :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordProjectionLag          :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()
recordProjectionWaitTimeouts :: (MonadIO m) => Maybe KeiroMetrics -> Int64  -> m ()

-- Re-exported from OpenTelemetry.Metric.Core for one-stop import:
--   Meter, InstrumentationLibrary(..)

-- Internal (not exported), used by the helpers:
-- recordCounter   :: (MonadIO m) => (KeiroMetrics -> Counter Int64) -> Maybe KeiroMetrics -> Int64  -> m ()
-- recordGaugeI64  :: (MonadIO m) => (KeiroMetrics -> Gauge Int64)   -> Maybe KeiroMetrics -> Int64  -> m ()
-- recordHistogram :: (MonadIO m) => (KeiroMetrics -> Histogram)     -> Maybe KeiroMetrics -> Double -> m ()
```

**Upstream signatures relied upon** (from
`OpenTelemetry.Metric.Core` / `OpenTelemetry.Internal.Metric.Types`, verified by
reading the source; these are *record fields*, so the call form is
`field record arg...`):

```haskell
getMeter                 :: MeterProvider -> InstrumentationLibrary -> IO Meter
forceFlushMeterProvider  :: MeterProvider -> Maybe Int -> IO FlushResult
defaultAdvisoryParameters :: AdvisoryParameters

meterCreateCounterInt64 :: Meter -> Text -> Maybe Text -> Maybe Text -> AdvisoryParameters -> IO (Counter Int64)
meterCreateGaugeInt64   :: Meter -> Text -> Maybe Text -> Maybe Text -> AdvisoryParameters -> IO (Gauge Int64)
meterCreateHistogram    :: Meter -> Text -> Maybe Text -> Maybe Text -> AdvisoryParameters -> IO Histogram

counterAdd      :: Counter a -> a      -> Attributes -> IO ()
gaugeRecord     :: Gauge a   -> a      -> Attributes -> IO ()
histogramRecord :: Histogram -> Double -> Attributes -> IO ()

emptyAttributes :: Attributes
```

**SDK + exporter signatures relied upon by the test** (from
`OpenTelemetry.MeterProvider`, `OpenTelemetry.Exporter.InMemory.Metric`,
`OpenTelemetry.Resource`, verified by reading the source):

```haskell
createMeterProvider :: MaterializedResources -> SdkMeterProviderOptions -> IO (MeterProvider, SdkMeterEnv)
defaultSdkMeterProviderOptions :: SdkMeterProviderOptions   -- field: metricExporter :: Maybe MetricExporter
inMemoryMetricExporter :: (MonadIO m) => m (MetricExporter, IORef [ResourceMetricsExport])
emptyMaterializedResources :: MaterializedResources
```

**Export-shape constructors the test pattern-matches** (from
`OpenTelemetry.Internal.Metric.Export`, re-exported via
`OpenTelemetry.Exporter.Metric`):

```haskell
data MetricExport
  = MetricExportSum       { mesName :: Text, ..., mesSumPoints   :: Vector SumDataPoint }       -- 8 fields
  | MetricExportHistogram { mehName :: Text, ..., mehPoints      :: Vector HistogramDataPoint } -- 6 fields
  | MetricExportExponentialHistogram { ... }
  | MetricExportGauge     { megName :: Text, ..., megGaugePoints :: Vector GaugeDataPoint }     -- 6 fields

sumDataPointValue        :: SumDataPoint       -> NumberValue
gaugeDataPointValue      :: GaugeDataPoint     -> NumberValue
histogramDataPointCount  :: HistogramDataPoint -> Word64
histogramDataPointSum    :: HistogramDataPoint -> Double
data NumberValue = IntNumber !Int64 | DoubleNumber !Double
```

**Consumers of this plan.** EP-35 (outbox + inbox) and EP-36 (timer +
projection) hard-depend on `KeiroMetrics`, `newKeiroMetrics`, and the `record*`
helpers exactly as specified above. They must not define instruments outside
`Keiro.Telemetry`; if either needs an instrument or helper this plan did not
provide, it extends `Keiro.Telemetry` and records the addition in the
MasterPlan's Surprises & Discoveries. The instrument **names** are frozen by the
audit section from Milestone 2; EP-35/EP-36/EP-37 reference them verbatim.
