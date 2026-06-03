---
id: 4
slug: close-out-phase-2-worker-metrics-and-process-manager-hardening
title: "Close out Phase 2: worker metrics and process-manager hardening"
kind: master-plan
created_at: 2026-06-03T04:20:03Z
intention: "intention_01kt5v38ztez0tt5b63nr7gbnx"
---

# Close out Phase 2: worker metrics and process-manager hardening

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

`docs/user/roadmap.md` describes Keiro as a five-phase delivery path. Phase 1
(stabilize the core) and most of Phase 2 (the v1 workflow substrate: outbox,
inbox, integration events, OpenTelemetry *tracing*) shipped in `0.1.0.0`. Two
Phase 2 items remain, and this MasterPlan finishes both so Phase 3 (read-side
maturity) and, ultimately, Phase 5 (v2 durable execution) can begin against a
v1 substrate that is observable and operationally hardened:

1. **Worker metrics.** Today `Keiro.Telemetry` emits *spans* only (Internal /
   Producer / Consumer), via the opt-in `Maybe Tracer` pattern. There is no
   metrics surface at all. After this initiative, an application that wires an
   SDK-backed meter can see, on a metrics exporter, the operational health of
   every Keiro background worker: outbox backlog and dead-letter counts, inbox
   duplicate counts and backlog, timer backlog and firing lag, and async
   projection lag. These are the numbers an operator alerts on, as opposed to
   the per-run traces that already exist.

2. **Process-manager hardening.** The `pm:<name>-<correlation>` convention,
   deterministic command ids, and correlation/causation metadata already exist
   and are tested. What remains is operational: a recommended snapshot policy
   for long-running process-manager state streams (today nothing documents
   this and no test exercises a PM snapshot), and a documented, *executable*
   timer stuck-row recovery and retry procedure. Today the timer table has a
   `Firing` status and an `attempts` column but **no** recovery API — a timer
   left `Firing` by a crashed worker can be re-claimed, but there is no
   supported way to find stuck rows, requeue them, cancel them, or dead-letter
   them after too many attempts. This initiative adds that small API and the
   guidance that uses it.

**What a user can do after this initiative that they cannot do today:**

- Wire an SDK `MeterProvider` into a jitsurei-style application and watch, on a
  metrics exporter (the OTLP exporter in production, the handle/stdout exporter
  in the demo, the in-memory exporter in tests), Keiro worker health metrics:
  `keiro.outbox.backlog`, `keiro.outbox.deadlettered`, `keiro.inbox.duplicates`,
  `keiro.timer.backlog`, `keiro.timer.fire.lag`, `keiro.projection.lag`, and the
  rest of the instrument set defined by EP-33.
- Call a supported API to list timers stuck in `Firing`, requeue them to
  `Scheduled`, cancel them, or let them auto-dead-letter after a configurable
  attempt ceiling — and follow a written recovery runbook that uses exactly
  those functions.
- Read concrete guidance on choosing a snapshot policy for a long-running
  process manager, backed by a worked example and a test that proves PM-stream
  snapshot hydration replays only the tail.

**In scope:** an opt-in `Meter`-based metrics surface in `Keiro.Telemetry` with
a no-op default; metric instruments for the outbox, inbox, timer, and async
projection workers; a metrics-conventions audit document analogous to the
existing span audit; a timer stuck-row recovery/cancel/dead-letter API with
tests; user-facing guidance for PM snapshot policy and timer recovery; a
PM-snapshot worked example and test; and the corresponding updates to
`docs/user/operations.md`, `docs/user/production-status.md`, and
`docs/user/roadmap.md`.

**Explicitly out of scope:** exactly-once async projections, prefix
subscriptions, and LISTEN/NOTIFY position waits (all Phase 3, upstream-blocked);
the v2 durable-execution runtime (Phase 5); a full Haddock pass and public
stability policy (Phase 4); and any new transport adapters. This MasterPlan
does not change the existing tracing surface beyond adding the metrics meter
alongside it, and it does not distinguish transient from permanent timer errors
automatically (the same simplification EP-20 made for the outbox).


## Decomposition Strategy

The decomposition follows two independent functional axes that meet only in the
shared `Keiro.Telemetry` surface and the shared `Keiro.Timer.Schema` module:
**observability** (metrics) and **operability** (timer recovery + PM guidance).

The metrics axis is split into a foundation plus two instrumentation plans. The
foundation (EP-33) must land first because it owns the meter handle, the no-op
pattern, the instrument-naming conventions, and the in-memory metric test
harness that both instrumentation plans depend on — exactly as the span work in
EP-25 first built `Keiro.Telemetry` and an audit document before any call site
used it. The two instrumentation plans are grouped by worker family rather than
by metric so each is independently verifiable and balanced: EP-35 covers the
**integration-messaging** workers (outbox and inbox), which is also where
dead-letter and duplicate counts naturally live; EP-36 covers the **internal
scheduling/read-side** workers (timer and async projection), which is where
backlog and lag gauges live. Splitting metrics four ways (one plan per
subsystem) was rejected as too granular — each would be a few instruments and a
test — and folding all instrumentation into one plan was rejected as too large
to restart safely and as mixing four distinct verification scenarios.

The operability axis is split into code (EP-34) and guidance (EP-37). EP-34 is
pure library code: the timer recovery/cancel/dead-letter functions and their
tests, with no documentation obligation. It is separated from EP-36 (timer
metrics) even though both touch `Keiro.Timer.Schema` because they are different
concerns with different acceptance — "a stuck row can be requeued" versus "a
backlog gauge is exported" — and keeping them apart lets the metrics work
proceed without waiting on the recovery API design. EP-37 is the guidance and
worked-example plan: it documents the PM snapshot policy (adding the first PM
snapshot test, since none exists), writes the timer recovery runbook *using*
EP-34's real functions, documents the new metrics from EP-35/EP-36, and updates
the production checklist and roadmap. EP-37 is deliberately last because
honest, copy-pasteable docs require the APIs they reference to already exist.

This yields five child plans in three implementation waves:

- **Wave 1 (parallel):** EP-33 (metrics foundation) and EP-34 (timer recovery
  code) — both depend only on the current tree.
- **Wave 2 (parallel, after EP-33):** EP-35 and EP-36 (the two instrumentation
  plans).
- **Wave 3 (after EP-34; best after EP-35/EP-36):** EP-37 (guidance + example).

Alternatives considered and rejected: (a) one "finish Phase 2" ExecPlan —
rejected, more than five milestones across unrelated modules; (b) metrics-first
then recovery-then-docs as a strict chain — rejected because EP-33 and EP-34
have no shared code and serializing them wastes the parallelism; (c) merging
EP-34 into EP-36 because both edit `Keiro.Timer.Schema` — rejected because they
edit different functions (read-only count queries versus mutation/recovery) and
have independent acceptance, with the shared file handled as an integration
point below.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 33 | Add an OpenTelemetry metrics surface to Keiro.Telemetry | docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md | None | EP-25 | Complete |
| 34 | Add timer stuck-row recovery and cancellation API | docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md | None | None | In Progress |
| 35 | Instrument the outbox and inbox workers with metrics | docs/plans/35-instrument-the-outbox-and-inbox-workers-with-metrics.md | EP-33 | None | Not Started |
| 36 | Instrument the timer and projection workers with metrics | docs/plans/36-instrument-the-timer-and-projection-workers-with-metrics.md | EP-33 | EP-34 | Not Started |
| 37 | Process-manager hardening guidance and snapshot worked example | docs/plans/37-process-manager-hardening-guidance-and-snapshot-worked-example.md | EP-34 | EP-35, EP-36 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-33 has no hard dependency on any plan in this MasterPlan. It softly depends
on EP-25 (the completed span instrumentation) because it extends the same
`Keiro.Telemetry` module and reuses its conventions — the `Maybe Tracer`
opt-in pattern becomes a `Maybe Meter` (or a combined handle) opt-in pattern,
and the bespoke `keiro_*` `AttributeKey` precedent becomes the bespoke
`keiro.*` instrument-name precedent. EP-33 defines the meter handle, the
instrument constructors and their names/units/kinds, the no-op default, the
metrics-conventions audit document, and the in-memory-metric-exporter test
harness.

EP-35 hard-depends on EP-33 because outbox/inbox instruments are created and
recorded through the meter surface EP-33 defines; without it the call sites
have nothing to call. EP-36 likewise hard-depends on EP-33 for the same
reason. EP-35 and EP-36 do not depend on each other and run in parallel once
EP-33 is complete.

EP-34 has no hard dependency. It adds new functions to `Keiro.Timer` and
`Keiro.Timer.Schema` and their tests; it neither needs nor blocks the metrics
foundation, so it runs in parallel with EP-33 in Wave 1.

EP-36 softly depends on EP-34: the timer-metrics plan may expose a "stuck
timers" gauge that counts rows in `Firing` past an attempt/age threshold, which
is most meaningful once EP-34 defines what "stuck" formally means. EP-36 can
ship its other timer/projection instruments without EP-34 and add the stuck
gauge afterward; the soft dependency records the preferred ordering, not a hard
block.

EP-37 hard-depends on EP-34 because its timer recovery runbook documents and
demonstrates EP-34's concrete functions (listing stuck timers, requeue, cancel,
dead-letter) — writing that runbook before the functions exist would violate
the "no undefined references" rule for self-contained docs. EP-37 softly
depends on EP-35 and EP-36 because it documents the new metric names in
`docs/user/operations.md`; it should be implemented after them so the names it
prints are the real, shipped instrument names. If EP-37 is implemented before
the metrics plans land, it must treat the metric names as provisional and a
later revision must reconcile them.


## Integration Points

**`Keiro.Telemetry` metrics surface.** EP-33 owns the new metrics exports in
`keiro/src/Keiro/Telemetry.hs`: the meter handle type (a `Maybe Meter`, or a
small record that pairs the existing `Maybe Tracer` with a `Maybe Meter` — EP-33
decides and documents which), the instrument constructor helpers, and the
bespoke `keiro.*` instrument names. EP-35 and EP-36 consume this surface to
create and record their instruments and must not define instruments outside it,
so `Keiro.Telemetry` stays the single telemetry import for the library (the same
rule EP-25 established for spans). If EP-35 or EP-36 needs an instrument kind or
helper EP-33 did not provide, it extends `Keiro.Telemetry` and records the
addition in this MasterPlan's Surprises & Discoveries.

**Metric instrument naming and the conventions audit.** EP-33 owns the
`keiro.*` instrument-name namespace and a metrics section in the conventions
audit (`docs/research/opentelemetry-semconv-audit.md`, or a sibling document —
EP-33 decides), recording each instrument's name, unit, kind (Counter /
UpDownCounter / Histogram / observable Gauge), and any OpenTelemetry messaging
metric semantic-convention alignment (for example `messaging.*` consumed/produced
counts where applicable). EP-35, EP-36, and EP-37 reference these names verbatim
and must not invent new names without updating the audit. The canonical
instrument names this MasterPlan expects (final spelling owned by EP-33) are:
`keiro.outbox.backlog`, `keiro.outbox.published`, `keiro.outbox.retried`,
`keiro.outbox.deadlettered`, `keiro.inbox.processed`, `keiro.inbox.duplicates`,
`keiro.inbox.failed`, `keiro.inbox.backlog`, `keiro.timer.backlog`,
`keiro.timer.fire.lag`, `keiro.timer.attempts`, `keiro.timer.stuck`,
`keiro.projection.lag`, and `keiro.projection.wait.timeouts`.

**Worker option records / entry points.** The threading of the meter handle
into each worker is a shared interface. EP-35 threads the handle into the outbox
publisher (`publishClaimedOutbox` / `OutboxPublishOptions` in
`keiro/src/Keiro/Outbox.hs` and `Outbox/Types.hs`) and the inbox
(`runInboxTransaction` in `keiro/src/Keiro/Inbox.hs`). EP-36 threads it into the
timer worker (`runTimerWorker` in `keiro/src/Keiro/Timer.hs`) and the async
projection path (`applyAsyncProjection` / the subscription drain in
`keiro/src/Keiro/Projection.hs` and the position machinery in
`keiro/src/Keiro/ReadModel.hs`). Each plan must follow EP-33's documented
threading convention (handle passed explicitly, defaulting to no-op) so the two
plans produce a consistent call shape.

**`Keiro.Timer.Schema`.** Both EP-34 and EP-36 touch
`keiro/src/Keiro/Timer/Schema.hs`. EP-34 owns new *mutation* functions
(requeue / reset to `Scheduled`, cancel / `markTimerCancelled`, find-stuck
query, optional auto-dead-letter on attempt ceiling) and any status or column
additions they require. EP-36 owns new *read-only* count queries (due-timer
backlog, stuck count). To avoid conflicting edits, EP-34 lands first (Wave 1)
and EP-36 builds on whatever stuck-row definition and any new status value EP-34
introduces. If EP-34 adds a new `TimerStatus` constructor (for example a
terminal `Dead`), EP-36's gauges and EP-37's runbook must use it; EP-34 records
any such addition in this MasterPlan's Surprises & Discoveries so the later
plans pick it up.

**User documentation set.** `docs/user/operations.md`,
`docs/user/production-status.md`, and `docs/user/roadmap.md` are touched by
several plans. EP-37 owns the consolidated, final state of these files (the
recovery runbook, the snapshot-policy guidance, the metrics catalogue, the
production checklist, and flipping the Phase 2 roadmap rows to complete). EP-34,
EP-35, and EP-36 may each add a short note to `operations.md` for the surface
they ship, but EP-37 reconciles them into one coherent narrative. To avoid
churn, EP-35/EP-36 should keep their `operations.md` edits minimal and defer the
full metrics catalogue to EP-37.

**`docs/research/opentelemetry-semconv-audit.md`.** EP-33 extends this existing
audit (or adds a sibling) with the metrics section; EP-25 created it for spans.
EP-35/EP-36 verify their instruments against it. EP-33 is the definer.


## Progress

Track milestone-level progress across all child plans. Each entry names the child
plan and the milestone.

- [x] EP-33: define the `Keiro.Telemetry` meter handle, no-op default, and instrument constructors. (2026-06-03)
- [x] EP-33: write the metrics section of the conventions audit (names, units, kinds, semconv alignment). (2026-06-03)
- [x] EP-33: add the in-memory-metric-exporter test harness and assert instruments record under it. (2026-06-03)
- [ ] EP-34: add `findStuckTimers`, requeue-to-`Scheduled`, and cancel functions in `Keiro.Timer`/`Timer.Schema`.
- [ ] EP-34: add the attempt-ceiling auto-dead-letter path (or document its deliberate omission) with tests.
- [ ] EP-35: thread the meter handle into the outbox publisher and record backlog / published / retried / deadlettered.
- [ ] EP-35: thread the meter handle into the inbox and record processed / duplicates / failed / backlog.
- [ ] EP-35: assert outbox/inbox instruments under the in-memory metric exporter.
- [ ] EP-36: thread the meter handle into the timer worker and record backlog / fire.lag / attempts (+ stuck after EP-34).
- [ ] EP-36: record projection lag and position-wait timeouts on the async projection path.
- [ ] EP-36: assert timer/projection instruments under the in-memory metric exporter.
- [ ] EP-37: add the first PM-stream snapshot test and the snapshot-policy guidance.
- [ ] EP-37: write the timer stuck-row recovery runbook using EP-34's functions.
- [ ] EP-37: document the metric catalogue, update the production checklist, and flip the Phase 2 roadmap rows.


## Surprises & Discoveries

- 2026-06-03: `hs-opentelemetry-api` `1.0` (the version EP-32 upgraded keiro to)
  ships a full **metrics** API at `OpenTelemetry.Metric.Core` — synchronous
  `Counter` / `UpDownCounter` / `Histogram` / `Gauge` and asynchronous
  `ObservableCounter` / `ObservableUpDownCounter` / `ObservableGauge`, with a
  `noopMeterProvider` global default. This is new since the older versions that
  were traces-only, and it is what makes this initiative feasible. The no-op
  default means library instrumentation is safe unconditionally, mirroring the
  no-op `Tracer` pattern keiro already uses. Observable gauges (callback read at
  export time) are the right shape for backlog/lag (computed by a `SELECT
  COUNT(*)` or a head-minus-checkpoint subtraction on demand); synchronous
  counters fit duplicate/dead-letter/published tallies recorded inline.
- 2026-06-03: The SDK side is also present — `OpenTelemetry.Metric`,
  `OpenTelemetry.MeterProvider`, and `OpenTelemetry.MetricReader` in
  `hs-opentelemetry-sdk`, plus metric exporters for in-memory
  (`OpenTelemetry.Exporter.InMemory.Metric`), handle/stdout
  (`OpenTelemetry.Exporter.Handle.Metric`), and OTLP
  (`OpenTelemetry.Exporter.OTLP.Metric`). `keiro`'s test suite already depends on
  `hs-opentelemetry-exporter-in-memory` and `hs-opentelemetry-sdk`, so the
  metric test harness needs no new dependency. The jitsurei demo can use the
  handle exporter to print metrics to stdout.
- 2026-06-03: There is currently **no** timer recovery API. `Keiro.Timer.Schema`
  exposes only `scheduleTimerTx`, `claimDueTimer` (which uses `FOR UPDATE SKIP
  LOCKED` and increments `attempts`), and `markTimerFired`. A crashed worker
  leaves a row in `Firing`; it is re-claimable in principle, but nothing finds
  or repairs stuck rows, and there is no terminal failure state for a timer that
  can never fire. `TimerStatus` is `Scheduled | Firing | Fired | Cancelled` —
  EP-34 may need to add a terminal `Dead`-like state. `docs/user/operations.md`
  already lists "decide timer stuck-row repair procedure" as an open production
  checklist item.
- 2026-06-03: No test exercises a process-manager *state-stream* snapshot. The
  snapshot tests in `keiro/test/Main.hs` all use a counter `EventStream`
  (`snapshotCounterEventStream`, `Every 2`), and the jitsurei
  `FulfillmentProcess` uses `snapshotPolicy = Never`. EP-37 adds the first
  PM-snapshot test/example. PMs already *can* snapshot by configuring the
  manager `EventStream`'s `snapshotPolicy`/`stateCodec`; the gap is purely
  guidance + demonstration, not new snapshot machinery.
- 2026-06-03 (drafting EP-35): Potential **import cycle** EP-33 must resolve.
  `Keiro.Telemetry` transitively imports `Keiro.Outbox.Kafka` and
  `Keiro.Integration.Event`, so if `KeiroMetrics` is defined in `Keiro.Telemetry`
  and `Keiro.Outbox.Types` (or other worker option modules) import it for an
  `OutboxPublishOptions` field, GHC may see a module cycle. EP-33 owns the fix —
  options: define `KeiroMetrics` in a leaf module that `Keiro.Telemetry`
  re-exports, or keep the handle out of the option *records* and pass it as a
  direct argument to the worker entry points (`Keiro.Outbox.hs` already imports
  `Keiro.Telemetry`, so passing the handle to `publishClaimedOutbox` from there
  avoids the cycle). EP-35/EP-36 must follow whatever EP-33 chooses. Also open
  for EP-33 to settle: whether a zero-delta counter records `Just 0` vs nothing,
  and whether the optional `keiro.outbox.attempts` histogram ships.
- 2026-06-03 (drafting EP-34): EP-34's API is now concrete and EP-36/EP-37 must
  use these exact names (not the provisional names in their first drafts):
  `findStuckTimers :: UTCTime -> StuckTimerFilter -> Eff es [TimerRow]` with
  `StuckTimerFilter { minAge :: Maybe NominalDiffTime, minAttempts :: Maybe Int }`
  and `anyStuckTimer`; `requeueStuckTimer :: TimerId -> Eff es Bool` (firing →
  scheduled, `fire_at` unchanged, idempotent); `cancelTimer :: TimerId -> Eff es
  Bool`; `deadLetterTimer :: TimerId -> Text -> Eff es Bool`; and
  `runTimerWorkerWith :: TimerWorkerOptions -> ...` with `TimerWorkerOptions {
  maxAttempts :: Maybe Int }` / `defaultTimerWorkerOptions` (`runTimerWorker`
  kept as the default alias). EP-34 adds a terminal `TimerStatus` value `Dead`
  (stored `'dead'`), a new column `keiro_timers.last_error TEXT`, and a migration
  `keiro-migrations/sql-migrations/2026-05-17-03-00-00-keiro-timer-recovery.sql`.
  "Stuck" is defined as `status = 'firing'` plus optional `minAge` (measured on
  `updated_at`) and/or `minAttempts`. EP-36's `keiro.timer.stuck` gauge and
  EP-37's recovery runbook must reuse exactly this definition and these names.
  EP-37 drafted with provisional `requeueTimer`; its M0 reconciliation step must
  rename to `requeueStuckTimer`.
- 2026-06-03: EP-33 and EP-34 were still skeletons while EP-35/EP-36/EP-37 were
  drafted in parallel, so those three consume the foundation/recovery contracts
  *by reference* from this MasterPlan's Decision Log and the entries above. Each
  carries an explicit early reconciliation step (re-read the shipped EP-33/EP-34
  and align helper/field/instrument/function spelling) before implementation.
  EP-37, as the last plan, holds final reconciliation responsibility for metric
  names and timer-recovery function names.


- 2026-06-03 (EP-33 shipped): The metrics foundation landed. EP-35/EP-36 must
  consume **exactly** this shape from `keiro/src/Keiro/Telemetry.hs`:
  - `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics` builds the flat
    `KeiroMetrics` record; workers take `Maybe KeiroMetrics` and the fourteen
    `record*` helpers no-op on `Nothing`. Helper names and Int64/Double argument
    types are frozen in the plan's "Interfaces and Dependencies" and the audit.
  - The **import-cycle question** the prior discovery flagged was resolved by
    keeping the handle **out of the worker option records** is *not* yet decided
    by EP-33 — EP-33 only defines the surface and instruments no worker, so it
    introduced no option-record field and hit no cycle. EP-35/EP-36 still own the
    threading decision; the safe path the MasterPlan already noted is to pass
    `Maybe KeiroMetrics` as a direct argument to the worker entry points (the
    worker modules already import `Keiro.Telemetry`), avoiding any
    `Keiro.Outbox.Types`→`Keiro.Telemetry` cycle. EP-33 did not need to relocate
    `KeiroMetrics` to a leaf module.
  - Recording helpers record with `emptyAttributes` today (no per-measurement
    dimensions). If EP-35/EP-36 need low-cardinality attributes, they extend the
    helper signatures in `Keiro.Telemetry` and note it here.
  - Minor import deviations (no effect on the surface): `InstrumentationLibrary`
    is re-exported from `OpenTelemetry.Trace.Core`, not `OpenTelemetry.Metric.Core`
    (the latter imports but does not re-export it). `newKeiroMetrics` calls the
    instrument constructors as `meterCreateCounterInt64 meter name (Just unit)
    (Just desc) defaultAdvisoryParameters` — unit and description are both
    `Maybe Text`.

## Decision Log

- Decision: Decompose the remaining Phase 2 work into five child ExecPlans —
  metrics foundation (EP-33), timer recovery code (EP-34), outbox/inbox metrics
  (EP-35), timer/projection metrics (EP-36), and PM hardening guidance +
  snapshot example (EP-37) — in three waves.
  Rationale: The work splits cleanly along an observability axis (metrics) and an
  operability axis (recovery + guidance) that meet only in `Keiro.Telemetry` and
  `Keiro.Timer.Schema`. A foundation-first metrics split mirrors how EP-25 built
  the span surface before instrumenting call sites, and grouping instrumentation
  by worker family keeps each plan independently verifiable and balanced.
  Date: 2026-06-03.

- Decision: Group metric instrumentation by worker family (outbox+inbox in
  EP-35, timer+projection in EP-36) rather than one plan per subsystem or one
  plan for everything.
  Rationale: Four subsystem plans would each be trivially small; one combined
  plan would be too large to restart safely and would bundle four distinct
  acceptance scenarios. The two-way split puts the dead-letter/duplicate counts
  with the integration-messaging workers and the backlog/lag gauges with the
  scheduling/read-side workers, which is also how operators reason about them.
  Date: 2026-06-03.

- Decision: Keep timer recovery code (EP-34) separate from timer metrics (EP-36)
  even though both edit `Keiro.Timer.Schema`, and land EP-34 first.
  Rationale: They are different concerns (operability versus observability) with
  independent acceptance, and EP-34 edits mutation functions while EP-36 edits
  read-only queries. Landing EP-34 first lets it define "stuck" and any new
  terminal status, which EP-36's stuck gauge and EP-37's runbook then consume.
  The shared file is managed as an integration point.
  Date: 2026-06-03.

- Decision: EP-37 (guidance) is last and hard-depends on EP-34.
  Rationale: A self-contained recovery runbook must reference functions that
  exist; documenting EP-34's API before it ships would violate the no-undefined-
  references rule. EP-37 softly depends on EP-35/EP-36 so the metric names it
  catalogues are the shipped names.
  Date: 2026-06-03.

- Decision: Use the opt-in no-op meter pattern (default `noopMeterProvider` /
  `Nothing` handle), not a mandatory meter.
  Rationale: It matches the existing `Maybe Tracer` opt-in for spans, keeps
  applications that have not configured OpenTelemetry unaffected, and the
  upstream `noopMeterProvider` makes unconditional library instrumentation safe.
  Date: 2026-06-03.

- Decision: Recommended consumer contract for the metrics surface (EP-33 owns the
  final naming): EP-33 exposes a `KeiroMetrics` record holding the constructed
  instruments and a builder `newKeiroMetrics :: (MonadIO m) => Meter -> m
  KeiroMetrics`; workers accept a `Maybe KeiroMetrics` and treat `Nothing` as
  "record nothing". EP-35 and EP-36 consume this exact shape.
  Rationale: Instruments are created once and recorded many times, so a record of
  pre-built instruments threaded as `Maybe` matches the `Maybe Tracer` idiom
  while avoiding per-record reconstruction. Fixing the shape in the MasterPlan
  keeps the three metrics plans consistent even if authored in parallel.
  Date: 2026-06-03.

- Decision: Backlog and lag are recorded as **synchronous** instruments (a
  `Gauge` via `gaugeRecord`, or an `UpDownCounter`) written by each worker on
  every poll pass using the count/age it already computes with its `Store`
  effect — not as asynchronous observable gauges with export-time callbacks.
  Rationale: An observable gauge's callback runs in `IO` on the SDK's collection
  thread and would need its own database access (a captured connection pool or
  `Store` runner) to compute a backlog, which the library does not own. The
  background workers already hold `Store` and run periodically, so recording the
  backlog/lag synchronously each pass is simpler, needs no new application wiring,
  and is accurate to within one poll interval. EP-33 may additionally offer an
  observable variant for applications that want export-time reads, but the
  worker-recorded synchronous gauge is the baseline that EP-35/EP-36 implement.
  Date: 2026-06-03.


## Outcomes & Retrospective

(To be filled during and after implementation.)
</content>
</invoke>
