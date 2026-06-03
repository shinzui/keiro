---
id: 5
slug: v2-durable-execution-named-step-workflow-runtime
title: "v2 durable execution: named-step workflow runtime"
kind: master-plan
created_at: 2026-06-03T14:39:28Z
intention: "intention_01kt6y4cb6eqz9mq48kf2xw8n1"
---

# v2 durable execution: named-step workflow runtime

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

`docs/user/roadmap.md` describes Keiro as a five-phase delivery path. Phases 1 and 2
shipped the v1 event-sourcing substrate — command cycle, codecs, snapshots, read
models, process managers, routers, durable timers, transactional outbox/inbox,
integration events, OpenTelemetry tracing, and (closing out under MasterPlan 4)
worker metrics. Phase 5 is the marquee next capability: **v2 durable execution** —
a runtime for writing long-running workflows as ordinary imperative Haskell functions
whose side effects are journaled at named checkpoints so the function can be paused
and resumed across crashes, redeployments, and idle gaps. The design is fixed in
`docs/research/10-workflow-roadmap.md` §4 (named steps, not positional history) and
`docs/research/05-workflow-prior-art.md` (the DBOS re-run-from-the-top model with
Inngest's named-step durability discriminator). This initiative implements it.

A *durable execution runtime* means: a user writes a function like

```haskell
orderFulfillment :: OrderId -> Workflow es ()
orderFulfillment orderId = do
  _ <- step (StepName "reserve-inventory") (runReserve orderId)
  sleep (5 * 60)                              -- durable, survives a crash
  res <- step (StepName "charge-card")    (runCharge orderId)
  (h, await) <- awakeable                     -- wait for an external webhook
  approval <- await
  ...
```

and runs it with `runWorkflow wfId (orderFulfillment orderId)`. Every `step "name"
action` either runs `action` and journals its encoded result, or — on a replay after
a crash — returns the previously recorded result without re-running the side effect.
A `sleep` is backed by the existing `keiro_timers` table; an `awakeable` is a durable
promise an external system resolves through `signalAwakeable`. The journal *is* a
kiroku stream named `wf:<workflow-name>-<workflow-id>`, sharing storage and
observability with the rest of Keiro. A background **resume worker** finds workflows
whose journal lacks a terminal `WorkflowCompleted` event and re-invokes them from the
top, short-circuiting already-journaled steps. Long histories are kept loadable by
**journal snapshots**. Parents can spawn, wait on, and cancel **child workflows**.

**What a user can do after this initiative that they cannot do today:**

- Write a multi-step workflow as a plain `Workflow es a` do-block, run it with
  `runWorkflow`, kill the process partway through, restart, and watch it resume from
  the first un-journaled step — proven by a jitsurei demo and a crash-resume test.
- Use `sleep` for durable delays that survive a restart (no external scheduler), and
  `awakeable`/`signalAwakeable` to suspend a workflow until an external system calls
  back.
- Spawn child workflows from a parent, wait for their results, and cancel them; the
  parent's journal records the child handles so the relationship survives a crash.
- Operate the runtime: see workflow step/replay/resume spans and
  `keiro.workflow.*` metrics on an exporter, snapshot long journals, and follow a
  guide that walks the whole surface end to end.

**In scope:** the `Keiro.Workflow` effect and its four fixed signatures from
`docs/research/10-workflow-roadmap.md` §4 — `step`, `sleep`, `awakeable`,
`runWorkflow` — plus `signalAwakeable`; the `keiro_workflow_steps` step-lookup index
and `keiro_awakeables` table with their migrations; a resume/crash-recovery worker;
journal snapshots reusing the EP-4 snapshot path; child workflows (spawn/wait/cancel);
workflow spans and metrics extending `Keiro.Telemetry`; and a worked example plus a
guide plus the `docs/user/roadmap.md` / `production-status.md` updates.

**Explicitly out of scope (deferred per `docs/research/10-workflow-roadmap.md` §6):**
continue-as-new journal rotation (§6.4); the versioning/patch API `patch :: PatchId ->
Workflow Bool` (§6.5); multi-region/global-ordering (§6.6); LISTEN/NOTIFY push
delivery (§6.11); consumer-group sharding (§6.8); and the kiroku prefix-subscription,
keiki `compensate`-direction, and shibuya supervisor-hosting questions forwarded to
`docs/research/11-upstream-roadmap.md`. This initiative does **not** require any of
those upstream changes: the resume worker discovers unfinished workflows with an
`AllStreams` subscription or a direct index scan rather than a `wf:` prefix
subscription, and reuses the existing polling worker pattern. None of v2's two new
tables invalidate any of the five v1 tables, so a v1 deployment upgrades in place
(`docs/research/10-workflow-roadmap.md` §7).


## Decomposition Strategy

The runtime decomposes into one foundation plus seven extensions, grouped into five
implementation waves. The decomposition follows the v2 design's natural seams: a
single journal/replay core that every other primitive layers onto, then independent
suspension primitives (sleep, awakeables), an orthogonal durability concern
(snapshots), the operational runtime (resume worker), a composition primitive (child
workflows), a cross-cutting observability concern, and finally documentation that can
only be honest once the APIs it references exist.

**The foundation (EP-38) must land first.** It owns the `Keiro.Workflow` effect, the
`Workflow es a` type, the `step`/`runWorkflow` signatures, the `StepRecorded` journal
event and its codec, the `wf:<name>-<id>` stream-naming convention, the in-memory
journal pre-load and named-step short-circuit replay logic, and the
`keiro_workflow_steps` index table plus its migration. Every other plan consumes this
surface, exactly as EP-33 (the metrics foundation) had to land before EP-35/EP-36 in
MasterPlan 4. Splitting the core further (e.g. a separate "stream naming" plan) was
rejected as too granular — the effect type, its handler, and the journal event are one
indivisible verification unit ("a two-step workflow journals and replays").

**The suspension primitives (EP-39 sleep, EP-40 awakeables) and the snapshot concern
(EP-41) form Wave 2** because each layers independently on EP-38 with no dependency on
the others. `sleep` reuses the existing `keiro_timers` subsystem (`Keiro.Timer`,
`Keiro.Timer.Schema`) — a timer whose `owner_stream` is the workflow journal and whose
fire appends a step-completion event that wakes the replay. Awakeables introduce a
new `keiro_awakeables` table and an external-completion API. Snapshots reuse EP-4's
`keiro_snapshots` table and `writeSnapshot`/`hydrateWithSnapshot` plumbing but with a
workflow-specific codec (see Integration Points — the step-result map is dynamically
keyed, so keiki's static `regFileShapeHash` does not directly apply). Folding sleep and
awakeables into one plan was rejected: they have different storage (timer table vs. a
new table), different acceptance ("a slept workflow wakes after N seconds" vs. "an
awaiting workflow resumes when signalled"), and different external surfaces.

**The resume worker (EP-42) is Wave 3.** It hard-depends only on EP-38 but
soft-depends on EP-39 and EP-40 because a resumed workflow is most often one suspended
*on* a sleep or an awakeable, and the worker's tests are far more meaningful once a
real suspension primitive exists to recover from. It follows the existing
claim-process-commit-poll worker shape (`publishClaimedOutbox` in `Keiro.Outbox`,
`runTimerWorker` in `Keiro.Timer`). It is kept separate from EP-38 because "the runtime
discovers and resumes a crashed workflow on startup" is a distinct, independently
verifiable behavior from "a step replays in-process", and because the discovery
mechanism (scan for journals lacking `WorkflowCompleted`) is an operational design
with its own acceptance.

**Child workflows (EP-43) and observability (EP-44) form Wave 4.** Child workflows
hard-depend on EP-38 and soft-depend on EP-40 (waiting on a child resolves like an
awakeable) and EP-42 (the resume worker wakes a parent when a child completes).
Observability hard-depends on EP-38 and soft-depends on EP-39/EP-40/EP-42/EP-43
because it instruments the surfaces those plans expose; it extends the existing
`KeiroMetrics` record and span helpers in `Keiro.Telemetry` exactly as EP-35/EP-36
did, and lands late so the instruments it adds cover the real, shipped call sites.

**The worked example, guide, and roadmap updates (EP-45) are Wave 5,** deliberately
last, because a self-contained jitsurei demo and a copy-pasteable guide require every
API they reference to already exist — the same reason EP-37 (PM hardening guidance)
was last in MasterPlan 4.

This yields eight child plans in five waves. Alternatives considered and rejected:
(a) one "implement v2" ExecPlan — rejected, far more than five milestones across a
dozen new modules; (b) shipping only the journal core and deferring everything else to
later MasterPlans — considered, but the fixed §4 surface (which includes `sleep` and
`awakeable`) plus a resume worker is the minimum that is *demonstrably* a durable
execution runtime rather than a journaling library; (c) merging observability into each
feature plan — rejected because it would fragment the `KeiroMetrics` extension across
four plans and produce inconsistent instrument naming, the same reasoning that kept
metrics instrumentation in dedicated plans in MasterPlan 4.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 38 | Workflow journal and named-step replay core | docs/plans/38-workflow-journal-and-named-step-replay-core.md | None | None | Complete |
| 39 | Durable sleep on the timer table | docs/plans/39-durable-sleep-on-the-timer-table.md | EP-38 | None | Complete |
| 40 | Awakeables and external completion | docs/plans/40-awakeables-and-external-completion.md | EP-38 | None | Complete |
| 41 | Workflow journal snapshots and step-result compaction | docs/plans/41-workflow-journal-snapshots-and-step-result-compaction.md | EP-38 | None | Complete |
| 42 | Workflow resume and crash-recovery worker | docs/plans/42-workflow-resume-and-crash-recovery-worker.md | EP-38 | EP-39, EP-40 | Complete |
| 43 | Child workflows: spawn, wait, and cancel | docs/plans/43-child-workflows-spawn-wait-and-cancel.md | EP-38 | EP-40, EP-42 | Complete |
| 44 | Workflow observability: spans and metrics | docs/plans/44-workflow-observability-spans-and-metrics.md | EP-38 | EP-39, EP-40, EP-42, EP-43 | Complete |
| 45 | Durable workflow worked example and guide | docs/plans/45-durable-workflow-worked-example-and-guide.md | EP-38 | EP-39, EP-40, EP-41, EP-42, EP-43, EP-44 | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-38, EP-40).

Implementation waves:

- **Wave 1:** EP-38 (foundation; depends only on the current tree).
- **Wave 2 (parallel, after EP-38):** EP-39, EP-40, EP-41.
- **Wave 3 (after EP-38; best after EP-39/EP-40):** EP-42.
- **Wave 4 (after EP-42):** EP-43, EP-44.
- **Wave 5 (after all):** EP-45.


## Dependency Graph

EP-38 has no dependency on any plan in this MasterPlan. It builds only on the v1
substrate already in the tree: the `Store` effect (`appendToStream`,
`readStreamForwardStream`, `runTransaction`) re-exported through Keiro, the `Codec`
type in `keiro-core/src/Keiro/Codec.hs`, the migration machinery in
`keiro-migrations/`, and the deterministic-id and stream-naming patterns in
`keiro/src/Keiro/ProcessManager.hs`. EP-38 defines the `Workflow es a` effect, the
`step`/`runWorkflow` entry points, the journal event and codec, the `wf:` naming, the
replay short-circuit, and the `keiro_workflow_steps` table. Everything downstream
imports `Keiro.Workflow`.

EP-39, EP-40, and EP-41 each hard-depend on EP-38 and on nothing else, so they run in
parallel once EP-38 is complete. EP-39 (`sleep`) needs the journal/replay handler to
record a `sleep:<id>` step and the resume path to recognise a fired timer's
completion event; EP-40 (`awakeable`) needs the same handler to record an `awk:<id>`
step and to resume when the awakeable is signalled; EP-41 (snapshots) needs EP-38's
accumulated-step-result state type and the journal stream to snapshot. None of the
three needs the others.

EP-42 (resume worker) hard-depends on EP-38 (it re-invokes a `Workflow es a` through
the EP-38 handler) and soft-depends on EP-39 and EP-40: a workflow that is merely
incomplete because the process crashed mid-run can be resumed using EP-38 alone, but
the *interesting* recovery cases — a workflow blocked on a durable `sleep`, or one
parked on an unresolved `awakeable` — only exist once EP-39/EP-40 land, and the
worker's acceptance tests should exercise them. EP-42 can ship its core
discover-and-reinvoke loop before EP-39/EP-40 and add the suspension-aware cases
afterward; the soft dependency records the preferred ordering, not a hard block.

EP-43 (child workflows) hard-depends on EP-38 (it records child handles in the
parent's journal as steps) and soft-depends on EP-40 (a parent waiting on a child
resolves through the same suspension/resume mechanism an awakeable uses, so reusing
EP-40's wait primitive avoids reinventing it) and EP-42 (when a child completes, the
resume worker is what wakes the parent). EP-43 can define spawn-and-record before
EP-42 but cannot demonstrate parent resumption-on-child-completion without it.

EP-44 (observability) hard-depends on EP-38 (it instruments the journal/replay core)
and soft-depends on EP-39/EP-40/EP-42/EP-43 because it adds metrics and spans for the
sleep, awakeable, resume, and child-workflow surfaces those plans introduce. It should
be implemented after them so the instruments name real call sites; if implemented
earlier it must treat the not-yet-existing instruments as provisional and a later
revision reconciles them — the same pattern MasterPlan 4 used for EP-37's metric
catalogue.

EP-45 (worked example + guide + docs) hard-depends on EP-38 and soft-depends on every
other plan: a self-contained demo and guide must reference functions that exist, and
flipping the Phase 5 roadmap rows to "available" requires the surface they describe to
be shipped. It is last.


## Integration Points

**`Keiro.Workflow` effect surface.** EP-38 owns `keiro/src/Keiro/Workflow.hs` (and the
sibling modules below): the `Workflow` effect, the `Workflow es a` type, `WorkflowId`,
`StepName`, the `step`/`runWorkflow` functions, and the journal/replay handler. EP-39
adds `sleep`, EP-40 adds `awakeable`/`signalAwakeable`, EP-43 adds the child-workflow
spawn/wait/cancel primitives — all as additions to `Keiro.Workflow` (or a child module
it re-exports) that go *through* EP-38's handler so a single import stays the workflow
authoring surface, the same single-import discipline EP-25 established for spans. If a
downstream plan needs a handler capability EP-38 did not provide (for example, a hook
to record a non-`step` journal entry), it extends EP-38's handler and records the
addition in this MasterPlan's Surprises & Discoveries. EP-38 should anticipate this by
making the journal-entry constructor and the "append a journal event in the workflow's
transaction" helper reusable, not private to `step`.

**The suspension primitive (`awaitStep` / `WorkflowOutcome`) is owned by EP-38.** Because
`sleep`, `awakeable`, and child-wait are the same shape — "is the awaited result journaled
yet? if not, arm a wake source once and pause the run" — EP-38 owns that shape so the three
wake-source plans do not depend on one another. EP-38 makes `runWorkflow` return
`WorkflowOutcome a` (`Completed a | Suspended`) and exposes `awaitStep :: (Workflow :> es,
FromJSON a) => StepName -> Eff es () -> Eff es a`. EP-39 supplies an arming action that
schedules a `keiro_timers` row; EP-40 an action that registers an awakeable; EP-43 an
action that spawns and records a child. Each wake source's *external completion* path
(the timer worker firing, `signalAwakeable`, a child finishing) calls EP-38's
`appendJournalEntry` with a `StepRecorded` carrying the awaited step name and the resolved
value, so the next run takes the `awaitStep` hit path. The arming action **must be
idempotent** (a resumed workflow re-runs `arm` on every resume until the step resolves):
EP-39/EP-40/EP-43 must use deterministic ids (timer id, awakeable id, child id) so repeats
collapse to no-ops. This is the central integration contract of the whole initiative.

**Module layout and `keiro/keiro.cabal` exposed-modules.** Several plans add new
modules under `Keiro.Workflow.*`. EP-38 establishes the layout — at minimum
`Keiro.Workflow`, `Keiro.Workflow.Types`, and `Keiro.Workflow.Schema` (the
`keiro_workflow_steps` table) — and adds them to the `exposed-modules` stanza of
`keiro/keiro.cabal` (currently lines ~34–56). EP-40 adds `Keiro.Workflow.Awakeable`
(+ its schema), EP-42 adds `Keiro.Workflow.Resume`, EP-43 adds
`Keiro.Workflow.Child`. Each plan appends its modules to the same cabal stanza; to
avoid merge churn, each plan edits only its own lines and never reorders the list.

**The journal event `StepRecorded` and its codec.** EP-38 owns the journal event
type (carrying at least `stepName :: Text`, `result :: Value`, and `recordedAt ::
UTCTime`) and its `Codec` (built per `keiro-core/src/Keiro/Codec.hs`, schema version
1). EP-39's `sleep`, EP-40's `awakeable`, and EP-43's child handles are journaled as
the *same* `StepRecorded` event with reserved step-name prefixes (`sleep:`, `awk:`,
`child:`) rather than new event types, so the replay loop's lookup logic stays uniform
and the codec does not fragment. Any plan that needs an additional terminal journal
event (EP-38 owns `WorkflowCompleted`; EP-42 or EP-43 may need `WorkflowCancelled` or
`WorkflowFailed`) adds the constructor to EP-38's codec and bumps nothing (additive
within schema version 1) — and records it here. The reserved-prefix convention is an
integration contract: EP-39/EP-40/EP-43 must use exactly the prefixes EP-38 documents.

**`keiro_timers` reuse (EP-39).** EP-39 does not add a table; it reuses the existing
`Keiro.Timer`/`Keiro.Timer.Schema` subsystem. A `sleep delta` inside a workflow
schedules a timer (via `scheduleTimerTx`, `keiro/src/Keiro/Timer/Schema.hs`) whose
`processManagerName`/`correlationId` identify the workflow instance and whose
`owner_stream` is the workflow journal stream `wf:<name>-<id>`; the existing timer
worker (`runTimerWorker`) fires it by appending a step-completion `StepRecorded`
(`sleep:<id>`) event to that journal. EP-39 must confirm whether the existing
`TimerRequest` fields (`processManagerName`, `correlationId`, `payload`) suffice to
route a fired timer to a workflow journal without schema change; the analysis suggests
they do (the worker's fire action is caller-supplied). If a `keiro_timers` column
addition turns out to be needed, EP-39 owns that migration and records it here so EP-44
(which may surface a `keiro.timer.*` workflow dimension) and EP-45 (the runbook) pick
it up.

**`keiro_awakeables` table (EP-40).** EP-40 owns the new table `keiro_awakeables`
(`awakeable_id uuid PK`, `owner_workflow_name`, `owner_workflow_id`, `status`, `payload
jsonb`, timestamps; shape per `docs/research/10-workflow-roadmap.md` §7) and its migration
(`2026-06-03-01-00-00-keiro-awakeables.sql`). It follows the exact schema-module +
timestamped-migration convention of `keiro/src/Keiro/Timer/Schema.hs` and
`keiro-migrations/sql-migrations/`. EP-40 exposes `countPendingAwakeables` (the source for
EP-44's `keiro.workflow.awakeables.pending` gauge). **Resolved (2026-06-03):** EP-43 does
**not** reuse `keiro_awakeables`; it adds a dedicated `keiro_workflow_children` table
(`2026-06-03-02-00-00-keiro-workflow-children.sql`) because a parent↔child link is a
first-class queryable relation with its own cancel lifecycle. EP-43 still reuses the
*wait mechanism* (EP-38's `awaitStep` + journal propagation), only the storage is separate.

**Snapshot machinery (EP-41).** EP-4's snapshot code is the integration surface:
`keiro/src/Keiro/Snapshot.hs` (`writeSnapshot`, `hydrateWithSnapshot`), the
`keiro_snapshots` table (`Snapshot/Schema.hs`), the `StateCodec` type
(`keiro-core/src/Keiro/EventStream.hs`), and the `SnapshotPolicy` type. EP-41 reuses
the *table* and the read/write plumbing but must supply a workflow-specific
`StateCodec` for the accumulated step-result state. **Open design point (carried into
EP-38 and EP-41):** the existing `defaultStateCodec`
(`keiro/src/Keiro/Snapshot/Codec.hs`) computes its `shapeHash` from a statically-known
keiki `RegFile rs` slot list via `regFileShapeHash`. A workflow's accumulated state is
a `Map StepName Value` whose keys are dynamic strings, so `regFileShapeHash` does not
apply. EP-38 must define the canonical in-memory accumulated-state representation
(recommended: a `Map Text Value` of step-name → encoded result, the same value the
journal already carries), and EP-41 must build a `StateCodec (Map Text Value)` whose
`shapeHash` is a fixed sentinel (the step-result payloads are self-describing JSON, so
schema evolution is the per-step-result-`Codec` concern, not a register-file-shape
concern). EP-41 records the chosen discriminant here so EP-45's snapshot guidance is
accurate.

**`Keiro.Telemetry` metrics and spans (EP-44).** EP-44 extends the existing
`KeiroMetrics` record and `newKeiroMetrics` builder in `keiro/src/Keiro/Telemetry.hs`
(record at lines ~478–544) with workflow instruments under a new `keiro.workflow.*`
namespace, and adds workflow span helpers alongside `withCommandSpan`. The canonical
instrument names this MasterPlan expects (finalized by EP-44) and their kinds are:
`keiro.workflow.steps.executed` (Counter Int64), `keiro.workflow.steps.replayed`
(Counter Int64), `keiro.workflow.resumed` (Counter Int64, recorded in EP-42's worker off
its `ResumeSummary`), `keiro.workflow.journal.length` (Histogram Double),
`keiro.workflow.awakeables.pending` (Gauge Int64, sampled from EP-40's
`countPendingAwakeables`), and `keiro.workflow.active` (Gauge Int64, recorded on run
entry/exit via a process-global live-count `IORef`). EP-38 threads a
`Maybe KeiroMetrics`/`Maybe Tracer` through `WorkflowRunOptions` into the workflow handler
and worker entry points following the "handle passed explicitly, defaulting to no-op
(`Nothing`)" convention MasterPlan 4 settled on (its 2026-06-03 EP-35 Surprises entry).
EP-44 **verified this is cycle-safe**: `Keiro.Telemetry` imports no workflow module, so
the only edges are `Keiro.Workflow → Keiro.Telemetry` and `Keiro.Telemetry →
Keiro.Workflow.Types` (a leaf), both acyclic — unlike the `Keiro.Outbox.Types` cycle
MasterPlan 4 hit. EP-44 records the new instruments in
`docs/research/opentelemetry-semconv-audit.md`, the audit EP-25/EP-33 established.

**Migrations and `Keiro.Migrations.allKeiroMigrations`.** Three new timestamped files in
`keiro-migrations/sql-migrations/`, dated after the last existing migration
(`2026-05-17-03-00-00-keiro-timer-recovery.sql`) and ordered among themselves: EP-38's
`2026-06-03-00-00-00-keiro-workflow-steps.sql`, EP-40's
`2026-06-03-01-00-00-keiro-awakeables.sql`, and EP-43's
`2026-06-03-02-00-00-keiro-workflow-children.sql`. (EP-39 adds no migration — it reuses
`keiro_timers`; EP-41 adds none — it reuses `keiro_snapshots`.) All are embedded
automatically by the `embedDir "sql-migrations"` Template Haskell in
`keiro-migrations/src/Keiro/Migrations.hs` and surface through
`allKeiroMigrations`. **Build gotcha (documented by MasterPlan 4's EP-34 entry):**
adding a new `.sql` file does **not** trigger recompilation of `Keiro.Migrations` —
cabal reports "Up to date" and skips ghc even with `-fforce-recomp`. After adding a
migration, force a content recompile of `Keiro.Migrations` (touch the module or
`cabal clean`). EP-38 and EP-40 must each repeat this gotcha in their own plan text so
a novice does not lose an hour to it.

**`docs/user/` documentation set.** `docs/user/roadmap.md`,
`docs/user/production-status.md`, and a new `docs/user/durable-workflows.md` (plus a
`docs/guides/` guide) are touched by EP-45, which owns their final consolidated state:
the worked example, the operations guidance (resume worker, awakeable repair, journal
snapshots), and flipping the Phase 5 "Durable execution runtime" capability-matrix row
from "Planned v2" to "Available". Earlier plans may add a one-paragraph note to
`docs/user/operations.md` for a surface they ship, but EP-45 reconciles them into one
narrative — the same division of labour MasterPlan 4 used for EP-37.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone.

- [x] EP-38 (2026-06-03): define the `Keiro.Workflow` effect, `step`, `awaitStep`, `runWorkflow` (returning `WorkflowOutcome`), the `StepRecorded`/`WorkflowCompleted` journal events + codec, and the `wf:<name>-<id>` naming.
- [x] EP-38 (2026-06-03): implement journal pre-load, named-step short-circuit replay, and the suspend/resume primitive; add the `keiro_workflow_steps` table + migration.
- [x] EP-38 (2026-06-03): prove a two-step workflow journals each step once and replays without re-running side effects; prove an unresolved `awaitStep` yields `Suspended` and an external completion lets the next run finish.
- [x] EP-39 (2026-06-03): add `sleep`/`sleepNamed` backed by `keiro_timers`; a fired timer appends a `sleep:<id>` completion to the journal (`Keiro.Workflow.Sleep`, no migration / no schema change).
- [x] EP-39 (2026-06-03): prove a workflow sleeps, the process restarts (modelled as a second `runWorkflow`), and the workflow wakes after the delay without re-running prior steps — plus a real-time variant proving the delay actually elapses.
- [x] EP-40 (2026-06-03): add the `keiro_awakeables` table + migration, `awakeable`/`awakeableNamed`, `signalAwakeable`, `cancelAwakeable`, and `WorkflowAwakeableCancelled` (`Keiro.Workflow.Awakeable` + `.Schema`).
- [x] EP-40 (2026-06-03): prove a workflow suspends on an awakeable (pending row, no completion) and resumes with the signalled payload; plus idempotent double-signal, crash-safe journal re-append, and cancellation throwing.
- [x] EP-41 (2026-06-03): build the workflow `StateCodec` (`workflowStateCodec`, sentinel shape hash `keiro.workflow.stepmap.v1`) and add `snapshotPolicy` to `WorkflowRunOptions`; snapshot the accumulated step-result map at the `step` miss path and the completion site.
- [x] EP-41 (2026-06-03): prove snapshot + tail-replay hydration loads a long journal without replaying every step (1 tail event vs 7), correctness equality (`Never` ≡ `Every 2`), and advisory fallback on a corrupt/mismatched snapshot.
- [x] EP-42 (2026-06-03): implement the resume worker (`Keiro.Workflow.Resume`: `resumeWorkflowsOnce` + `runWorkflowResumeWorker(With)`, `WorkflowRegistry`/`WorkflowDef`, `ResumeSummary`) — discover journals lacking `WorkflowCompleted` via `findUnfinishedWorkflowIds`, re-invoke through EP-41's `runWorkflowWith`, short-circuit journaled steps. No new table/migration, no `wf:` prefix subscription.
- [x] EP-42 (2026-06-03): prove a crashed mid-run workflow (counter proves step 1 not re-run) and an awaitStep-suspended workflow both resume to `Completed`; plus unknown-name visibility and completed-workflow no-op.
- [x] EP-43 (2026-06-03): add child-workflow spawn/wait/cancel recorded in the parent journal (`Keiro.Workflow.Child` + `.Schema`, `keiro_workflow_children` table); EP-38 gains `WorkflowCancelled`/`WorkflowFailed` codec, a `Cancelled` outcome arm, and a cancel short-circuit; child-result propagation via a `runChildWorkflow` driver (not a `WorkflowRunOptions` hook).
- [x] EP-43 (2026-06-03): prove a parent spawns a child, waits for its result, and can cancel it; the relationship survives a crash — plus a resume-worker-driven variant (union `findRunningChildIds` discovery, child-aware `runChildWorkflow`).
- [x] EP-44 (2026-06-03): extend `KeiroMetrics` with the six `keiro.workflow.*` instruments + `withWorkflowSpan` and the three bespoke attribute keys; thread `metrics`/`tracer` through `WorkflowRunOptions` and wire the four handler sites (executed/replayed/active/journal.length); instrument the resume worker (`resumed` per re-invocation, `awakeables.pending` per pass) reading the handle from `WorkflowResumeOptions.runOptions`; record everything in the semconv audit (now twenty instruments).
- [x] EP-44 (2026-06-03): assert all six workflow instruments under the in-memory metric exporter (executed=2/replayed=2/journal.length count=2/active=0; resumed=1/awakeables.pending=1) plus a `Nothing`-handle no-op test. `cabal test keiro` = 133 examples, 0 failures.
- [ ] EP-45: add the jitsurei durable-workflow demo and the `docs/guides/` guide.
- [ ] EP-45: write the operations guidance (resume, awakeable repair, snapshots) and flip the Phase 5 roadmap rows.


## Surprises & Discoveries

- 2026-06-03 (planning): The v1 substrate the v2 runtime builds on is fully present and
  was mapped against real source during decomposition. Key load-bearing facts the child
  plans rely on: the `Store` effect exposes `appendToStream`/`appendMultiStream`/
  `readStreamForwardStream`/`runTransaction` with optimistic concurrency surfacing
  `DuplicateEvent` for caller-supplied ids (kiroku `Kiroku.Store.Effect`/`Append`/
  `Read`); `RecordedEvent` carries `eventId`/`streamVersion`/`globalPosition`/`payload`/
  `metadata` (kiroku `Kiroku.Store.Types`); `Keiro.ProcessManager.deterministicCommandId`
  derives a v5 UUID over `("keiro":"process-manager":name:correlationId:sourceEventId:
  emitIndex)` and is the exact template for a workflow's deterministic step-event id; the
  `Codec` record (`eventTypes`/`eventType`/`schemaVersion`/`encode`/`decode`/`upcasters`)
  in `keiro-core/src/Keiro/Codec.hs` is how the `StepRecorded` codec is built; the
  snapshot path (`writeSnapshot`/`hydrateWithSnapshot`, `keiro_snapshots`, `StateCodec`,
  `SnapshotPolicy = Never|Every n|OnTerminal|Custom`) is reusable; the timer subsystem
  (`scheduleTimerTx`, `claimDueTimer`, `runTimerWorker`, `TimerStatus` incl. `Dead`,
  `last_error`) backs `sleep`; the worker loop pattern is claim-`FOR UPDATE SKIP
  LOCKED`-process-commit-poll (`Keiro.Outbox.publishClaimedOutbox`); and `KeiroMetrics`/
  `newKeiroMetrics`/`record*` with the `Maybe KeiroMetrics` no-op idiom is the
  observability template. No `Keiro.Workflow` module exists yet — the entire surface is
  greenfield.
- 2026-06-03 (planning): **Dynamic step-result map vs. static `regFileShapeHash`.** The
  research doc (`docs/research/10-workflow-roadmap.md` §4) calls the workflow's
  accumulated step state "a `RegFile`-shaped value", but a register file's shape hash is
  computed from a *statically-known* type-level slot list (`Keiki.Shape.regFileShapeHash`
  over `'[ '("slot", T), ... ]`), whereas workflow step names are dynamic runtime
  strings. The snapshot reuse (EP-41) therefore cannot literally use `defaultStateCodec`.
  Resolution recorded in Integration Points: EP-38 represents accumulated state as a
  `Map Text Value` (step-name → encoded result), and EP-41 supplies a `StateCodec (Map
  Text Value)` with a fixed sentinel `shapeHash`; per-step schema evolution remains the
  individual step-result `Codec`'s concern, not a register-file-shape concern. This is the
  single most important design nuance for the snapshot and core plans to agree on.
- 2026-06-03 (planning): **No `wf:` prefix subscription is required.** The resume worker
  (EP-42) needs to find unfinished workflows, and kiroku only supports
  `AllStreams | Category` (exact-match) subscriptions — the `wf:` prefix subscription is a
  still-open upstream item (`docs/research/11-upstream-roadmap.md`). The decomposition
  deliberately routes around it: the `keiro_workflow_steps` index (EP-38) plus a
  "workflows lacking a terminal event" query is the discovery mechanism, so this
  initiative has **zero** upstream dependency. Recorded so EP-42 does not accidentally
  reach for a prefix subscription.

- 2026-06-03 (EP-38 implementation): the foundation shipped with three refinements the
  downstream waves must account for, none of which change the documented contracts:
  - **`appendJournalEntry`/`appendJournalEntryReturningId` are idempotent and carry
    `(IOE :> es, Store :> es)`** (not `Store` alone). They pre-check `stepExists` before
    appending, so a wake source (EP-39/EP-40/EP-43) that re-records an already-journaled step
    on resume gets a benign no-op returning the deterministic id — no need to catch
    `DuplicateEvent`. The `IOE` is free for those callers (timer worker / `signalAwakeable` /
    child completion all run with `IOE`).
  - **Idempotency is by pre-load gating, not `DuplicateEvent`-as-success.** Combining the
    journal append with the `keiro_workflow_steps` upsert in one `runTransactionAppending`
    means a duplicate event id inside the transaction surfaces as a generic `ConnectionError`
    (and would condemn the index write), so the handler never re-appends: `step` hits
    short-circuit from the pre-loaded map, and completion/external appends pre-check existence.
    Deterministic v5 ids remain for the concurrent two-runner case (EP-42 serializes that with
    claims). EP-42's resume worker should therefore rely on the helpers' idempotence rather
    than on store-level duplicate rejection.
  - **`stepExists :: (Store :> es) => WorkflowId -> Text -> Eff es Bool`** was added to
    `Keiro.Workflow.Schema` (and re-exported from `Keiro.Workflow`) to back that gating; EP-42
    may also find it useful. **`containers`** is now a `keiro` dependency.

- 2026-06-03 (parallel child-plan drafting): authoring EP-39…EP-45 concurrently surfaced a
  consistent set of small additions to EP-38's core surface, now folded into EP-38 and the
  contracts above. Catalogued here so the implementation waves stay aligned:
  - **`currentWorkflow :: (Workflow :> es) => Eff es (WorkflowName, WorkflowId)`** and
    **`freshOrdinal :: (Workflow :> es) => Text -> Eff es Int`** on EP-38 — both EP-39
    (sleep) and EP-40 (awakeables) need them to derive deterministic, replay-stable ids for
    convenience forms (`sleep` → `sleep:0`, `awakeable` → `awk:1`). EP-38 owns one
    `freshOrdinal`, not two. The stable primitives are the *named* forms (`sleepNamed`,
    `awakeableNamed`); the ordinal forms carry a documented reorder-across-deploys caveat.
  - **`appendJournalEntryReturningId`** on EP-38 — EP-39's fired timer needs the appended
    `EventId` for `markTimerFired`.
  - **`runWorkflowWith :: WorkflowRunOptions -> ...`** is owned by EP-38 (minimal
    `WorkflowRunOptions { pageSize }` + `defaultWorkflowRunOptions`); EP-41 adds
    `snapshotPolicy`, EP-44 adds `metrics`/`tracer`, EP-42 re-invokes through it. This is
    the single canonical per-run options home, decided up front so no plan refactors
    `runWorkflow` later.
  - **`WorkflowCancelled` + `WorkflowFailed`** journal constructors (additive within
    `schemaVersion = 1`), a **`Cancelled`** arm on `WorkflowOutcome`, a handler
    cancellation short-circuit, and a `runWorkflowWith` completion hook — introduced by
    EP-43 (child workflows) for child→parent result propagation and cancel; EP-38 keeps the
    codec/outcome/handler structured so these stay local additions.
  - **`WorkflowRegistry es = Map WorkflowName (WorkflowDef es)`** with
    **`data WorkflowDef es = forall a. WorkflowDef { runDef :: WorkflowId -> Eff (Workflow
    : es) a }`** — owned by EP-42 (the application-supplied name→definition map the resume
    worker re-invokes through), also consumed by EP-43 (a spawned child must be registered).
  - **`ResumeSummary`** (EP-42) feeds EP-44's `keiro.workflow.resumed`;
    **`countPendingAwakeables`** (EP-40) feeds EP-44's `keiro.workflow.awakeables.pending`.
  - **Sleep timer routing** uses a payload discriminator
    `{"kind":"keiro.workflow.sleep","step":"sleep:<suffix>"}` (EP-39) so one timer worker
    can serve both PM timers and workflow sleeps; EP-39 confirmed **no `keiro_timers`
    schema change** is needed.
  - **Storage:** three new migrations total — `keiro_workflow_steps` (EP-38),
    `keiro_awakeables` (EP-40), `keiro_workflow_children` (EP-43). EP-39 and EP-41 add none.


- 2026-06-03 (EP-39 implementation): **`sleep` shipped intact and the fire action uses the
  exported journal helper — both fallbacks in EP-39's plan went unused.** EP-38 had already
  folded in `currentWorkflow`, `freshOrdinal`, and `appendJournalEntryReturningId` (recorded in
  the prior Surprises entry), so EP-39 did not have to drop the ordinal `sleep` convenience nor
  recompute the journal-event id. Net: the `keiro_timers` reuse landed with **no migration and
  no `keiro_timers` schema change** — routing is purely the caller-supplied fire action plus the
  `{"kind":"keiro.workflow.sleep","step":"sleep:<suffix>"}` payload discriminator
  (`parseSleepPayload`). Two small cross-cutting notes for the remaining waves: (1) any module
  importing both `aeson` and `Keiro.Prelude` must write `Aeson..=` because `Keiro.Prelude`
  re-exports lens's `.=` — EP-40/EP-43 build JSON payloads and should qualify from the start;
  (2) EP-44 can hang a `keiro.timer.*` workflow-sleep dimension off `parseSleepPayload`, and the
  stable EP-39 surface it/EP-45 consume is `runWorkflowTimerWorker` + `workflowSleepFireAction`
  + `sleepNamed`/`sleep` from `Keiro.Workflow.Sleep`.

- 2026-06-03 (EP-40 implementation): **awakeables shipped against an EP-38 that already owned
  every contract, so no core changes were needed.** Cross-cutting notes for the remaining waves:
  - **`signalAwakeable` carries `(IOE :> es, Store :> es, ToJSON r)`**, not `Store` alone: the
    shipped `appendJournalEntry` requires `IOE`. EP-42 (resume worker) and EP-44 (which may
    instrument the signal call site) must thread `IOE` when they call it. The other external
    surfaces are `cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool` and
    `lookupAwakeable`/`countPendingAwakeables` (the latter is EP-44's `keiro.workflow.awakeables.pending`
    gauge seam, in `Keiro.Workflow.Awakeable.Schema`).
  - **`signalAwakeable` is idempotent *and* crash-safe.** It journals the just-written value on
    a `pending → completed` transition, or re-appends the *stored* payload when the row is
    already `completed` (healing a crash between the row update and the journal append). The
    `Bool` return is strictly "did this call perform the transition", so `False` does not imply
    "nothing happened". EP-42's resume worker can rely on this self-healing rather than ordering
    the two writes in one transaction.
  - **Constructor clashes.** `AwakeableStatus`'s `Pending`/`Completed`/`Cancelled` collide with
    `WorkflowOutcome`'s `Completed` and `TimerStatus`'s `Cancelled`. EP-43 (which reuses the
    await/signal mechanism and imports the workflow surface) should import
    `Keiro.Workflow.Awakeable.Schema` **qualified**.
  - **Awakeable storage** is the dedicated `keiro_awakeables` table (migration
    `2026-06-03-01-00-00-keiro-awakeables.sql`) with `pending`/`completed`/`cancelled` and a
    partial pending index; the codd `LaxCheck` schema-diff log line on apply is expected noise.

- 2026-06-03 (EP-41 implementation): **snapshots shipped reusing EP-4's table wholesale with
  no migration and no core refactor.** Cross-cutting notes for the remaining waves:
  - **`snapshotPolicy` is now a field on `WorkflowRunOptions`** (default `Never`), the canonical
    per-run options home. EP-44 must add its `metrics`/`tracer` fields to *this same record*,
    and EP-42's resume worker passes its own `WorkflowRunOptions` so a resumed run keeps
    snapshotting. The record converted from `newtype` to `data` and **lost its `Eq`/`Show`
    deriving** (the `SnapshotPolicy Custom` arm holds a function); nothing depended on them.
  - **Field-name clash:** `WorkflowRunOptions.snapshotPolicy` collides with keiki's
    `EventStream` field of the same name. A bare record update is ambiguous (`GHC-99339`) when
    both are imported; use the generic-lens label `opts & #snapshotPolicy .~ p`. EP-42/EP-44
    will hit this in their test/worker code.
  - **`appendJournalTx` now returns `(EventId, AppendResult)`** and a new internal
    `appendCompletion :: ... -> Eff es (Maybe AppendResult)` powers the `OnTerminal` write. The
    public helpers (`appendJournalEntry`, `appendJournalEntryReturningId`) are unchanged in
    signature. EP-42's resume worker, which re-invokes through `runWorkflowWith`, is unaffected.
  - **Workflow snapshot discriminant:** `stateCodecVersion = 1` + shape hash
    `"keiro.workflow.stepmap.v1"` (a fixed sentinel — the step-result map's *shape* never
    varies; per-step result-type evolution stays each step's own `ToJSON`/`FromJSON` concern).
    EP-45's snapshot guidance must cite this sentinel.

- 2026-06-03 (EP-42 implementation): **the resume worker shipped against the EP-38/EP-41
  surface with no core changes; one planned feature was demoted.** Notes for the remaining
  waves:
  - **`WorkflowRegistry es = Map WorkflowName (WorkflowDef es)`** with
    **`data WorkflowDef es = forall a. WorkflowDef { runDef :: WorkflowId -> Eff (Workflow :
    es) a }`**, **`WorkflowResumeOptions`** (carries EP-41's `WorkflowRunOptions` as
    `runOptions`, plus `pollInterval` and a *reserved* `useAdvisoryLock`), and
    **`ResumeSummary`** (`discovered`/`resumed`/`completed`/`stillSuspended`/`unknownName`)
    now exist in `Keiro.Workflow.Resume`. EP-43 registers spawned children here for parent
    resumption; EP-44 reads `ResumeSummary` for `keiro.workflow.resumed` and can thread a
    `Maybe KeiroMetrics` into `WorkflowResumeOptions`/`resumeWorkflowsOnce`.
  - **The `useAdvisoryLock` multi-worker optimization is reserved/unwired.** The kiroku
    `Store` is connection-pooled and a re-invocation spans several transactions, so a
    `pg_try_advisory_xact_lock` (transaction-scoped) cannot be held across a whole
    `runWorkflowWith` run and a session lock has no pool affinity. Concurrency is already safe
    by construction (EP-38 deterministic step ids + short-circuit), so the flag is kept for
    forward compatibility but does nothing. EP-44/EP-45 must **not** document the lock as
    functional.
  - **Discovery uses `findUnfinishedWorkflowIds` only** — confirmed no `wf:` prefix
    subscription is imported or needed, as the MasterPlan's discovery decision required.
  - **The umbrella `Keiro` module does not re-export workers**, so `Keiro.Workflow.Resume`
    is imported directly (like `Keiro.Timer`/`Keiro.Outbox`), not added to `Keiro.hs`.

- 2026-06-03 (EP-43 implementation): **child workflows shipped, but the planned
  `runWorkflowWith`-completion-hook contract was replaced by a `runChildWorkflow` driver.**
  The single most important cross-plan correction for the remaining waves:
  - **`WorkflowRunOptions` stays monomorphic; there is no `onComplete` field and
    `runWorkflowWith`'s signature is unchanged from EP-41.** The planned options-hook
    (Integration Points "`runWorkflowWith` with a child-completion hook") would have forced
    `WorkflowRunOptions es`, which broke every shipped `defaultWorkflowRunOptions &
    #snapshotPolicy .~ …` site via generic-lens type-changing-setter ambiguity. Instead,
    `Keiro.Workflow.Child.runChildWorkflow :: (IOE, Store, ToJSON a) => WorkflowRunOptions ->
    WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)` wraps
    `runWorkflowWith` and calls `childCompletionHook` on `Completed`. **EP-44 must add its
    `metrics`/`tracer` to `WorkflowRunOptions` the same monomorphic way — do NOT parametrize
    the record over `es`.**
  - **EP-38 additive changes that landed (all within `schemaVersion = 1`):**
    `WorkflowCancelled`/`WorkflowFailed` journal constructors + codec; a `Cancelled` arm on
    `WorkflowOutcome`; reserved `cancelledStepName`/`failedStepName`; and a pre-run
    `WorkflowCancelled` short-circuit in `runWorkflowWith` (returns `Cancelled`, runs no
    step). `findUnfinishedWorkflowIds` now treats `__workflow_cancelled__` as terminal too.
  - **EP-42 worker changes that landed:** `WorkflowDef`'s existential gained a `ToJSON a`
    constraint (so the worker can call `runChildWorkflow`); `resumeWorkflowsOnce` unions
    `findRunningChildIds` (EP-43, for zero-step children) into discovery and runs any
    discovered *child* through `runChildWorkflow`; `bumpForOutcome` gained a `Cancelled` case.
    `WorkflowResumeOptions` stayed monomorphic.
  - **Storage:** EP-43 owns the dedicated `keiro_workflow_children` table (migration
    `2026-06-03-02-00-00-keiro-workflow-children.sql`) — the third and final v2 migration, as
    forecast. `Keiro.Workflow.Child.Schema.countActiveChildren` is EP-44's seam for a
    `keiro.workflow.children.active` gauge.
  - **For EP-45:** a parent stuck awaiting a child is repaired by driving or cancelling the
    child; a cancelled child reports the `Cancelled` outcome and `awaitChild` throws
    `WorkflowChildCancelled`.

- 2026-06-03 (EP-44 implementation): **observability shipped exactly to plan against an
  all-soft-deps-present tree, with two clarifying decisions and one notable structural win.**
  Notes for EP-45 (the last wave):
  - **The six instruments and the span are final and catalogued.** Names/units/kinds are in
    `docs/research/opentelemetry-semconv-audit.md` (`### Workflow` + the metrics/span compliance
    rows; the metrics lead now reads "twenty instruments"): `keiro.workflow.steps.executed`
    `{step}` Counter, `keiro.workflow.steps.replayed` `{step}` Counter, `keiro.workflow.resumed`
    `{workflow}` Counter, `keiro.workflow.active` `{workflow}` Gauge, `keiro.workflow.journal.length`
    `{event}` Histogram, `keiro.workflow.awakeables.pending` `{awakeable}` Gauge; span
    `workflow <name>` `Internal` with bespoke keys `keiro.workflow.{name,id,step}`. EP-45's guide
    should cite these verbatim.
  - **Telemetry is threaded purely through `WorkflowRunOptions` (`metrics`/`tracer`, both default
    `Nothing`)** — no new positional arguments anywhere. The resume worker reads its handle from
    `WorkflowResumeOptions.runOptions ^. #metrics`, so a resumed (and child-driven) run records
    its own steps/active/journal-length and opens its span automatically. **EP-45 examples must
    set these with the generic-lens label** (`opts & #metrics .~ Just m`), never a bare record
    update — same `GHC-99339` clash EP-41 flagged for `snapshotPolicy`.
  - **`keiro.workflow.active` is a process-global `IORef Int64` gauge** sampled `+1`/`-1` on run
    entry/exit (steady-state 0). Cycle-safety held: the only edges are `Keiro.Workflow →
    Keiro.Telemetry` and `Keiro.Telemetry → Keiro.Workflow.Types` (leaf), confirmed by the GHC
    build order.
  - **Not in scope (so EP-45 should not claim it):** a child-count instrument. EP-43's
    `countActiveChildren` seam exists but no `keiro.workflow.children.active` instrument was
    added — EP-44's scope was the six named instruments only.

- 2026-06-03 (EP-45 implementation): **a parent workflow and its child must use distinct
  `WorkflowId`s** — a cross-cutting contract for every EP-43 (child-workflow) user, surfaced
  while building the worked example. `findUnfinishedWorkflowIds`
  (`keiro/src/Keiro/Workflow/Schema.hs`) discovers unfinished workflows by grouping on
  `workflow_id` *alone* — its `NOT EXISTS` terminal-marker subquery matches `c.workflow_id =
  s.workflow_id` and ignores `workflow_name`. So if a parent and child share an id (differing
  only by name), the child's `__workflow_completed__` row masks the parent's incompleteness and
  the parent silently drops out of resume discovery before it finishes. The keiro test suite
  already uses distinct ids (parent `p1`, child `ship-1`); EP-45 codified it as
  `shipChildId orderId = WorkflowId (orderIdText orderId <> "-ship")`, distinct from
  `workflowIdFor orderId`. With distinct ids the resume worker drives the parent to its own
  `WorkflowCompleted`. EP-45's guide documents this as an operational rule. No code change to
  EP-38/EP-43 is required — the constraint is on the *caller's* id allocation — but it is the
  single most important gotcha for anyone composing parent/child workflows.

## Decision Log

- Decision: Implement Phase 5 (v2 durable execution) as eight child ExecPlans in five
  waves — journal/replay core (EP-38), sleep (EP-39), awakeables (EP-40), snapshots
  (EP-41), resume worker (EP-42), child workflows (EP-43), observability (EP-44), and
  worked example + docs (EP-45).
  Rationale: The runtime has one indivisible foundation (the effect + journal + replay)
  that every other primitive layers onto, mirroring how MasterPlan 4 made the metrics
  foundation (EP-33) a hard prerequisite for instrumentation. Grouping the independent
  extensions into waves keeps each plan independently verifiable and lets Wave 2 run
  three plans in parallel.
  Date: 2026-06-03.

- Decision: Scope this MasterPlan to the fixed §4 surface (`step`/`sleep`/`awakeable`/
  `runWorkflow`) plus a resume worker, snapshots, child workflows, observability, and a
  worked example. Defer continue-as-new, the versioning/patch API, multi-region,
  LISTEN/NOTIFY, and consumer-group sharding to a later phase.
  Rationale: The four-signature surface plus a resume worker is the minimum that is
  *demonstrably* a durable-execution runtime rather than a journaling library. Child
  workflows were pulled in (per the user's scope choice on 2026-06-03) as the
  most-requested composition primitive; the remaining §6 stretch features each add
  operational surface without changing the core story and are cleanly additive later
  (`docs/research/10-workflow-roadmap.md` §6/§7 guarantee forward compatibility).
  Date: 2026-06-03.

- Decision: Journal `sleep`, `awakeable`, and child handles as the same `StepRecorded`
  event with reserved step-name prefixes (`sleep:`, `awk:`, `child:`), not as new
  journal event types.
  Rationale: Keeps the replay loop's name-lookup logic uniform and prevents the journal
  codec from fragmenting across four plans. EP-38 owns the codec and the reserved-prefix
  contract; the suspension/child plans consume it. Mirrors how the v1 PM uses one
  `emitIndex` convention rather than per-emission event types.
  Date: 2026-06-03.

- Decision: Reuse the existing `keiro_timers` subsystem for `sleep` (EP-39) instead of a
  new workflow-timer table.
  Rationale: `docs/research/10-workflow-roadmap.md` §4 fixes `sleep delta = step
  "sleep:<id>" (registerTimer delta)`, and the timer table already has the polling
  worker, the `FOR UPDATE SKIP LOCKED` claim, the `Dead`/`last_error` recovery columns,
  and metrics. A second timer table would duplicate all of it. The only question EP-39
  must settle is whether timer routing to a workflow journal needs any column addition;
  the existing caller-supplied fire action suggests not.
  Date: 2026-06-03.

- Decision: Represent accumulated workflow state as `Map Text Value` and give EP-41 a
  workflow-specific `StateCodec` with a sentinel `shapeHash`, rather than forcing the
  workflow journal through keiki's static-`RegFile` snapshot codec.
  Rationale: Step names are dynamic strings; `regFileShapeHash` requires a static slot
  list. The step-result payloads are self-describing JSON whose evolution is each
  step-result `Codec`'s responsibility, so a register-file-shape discriminant adds no
  safety here. Recorded as the key cross-plan design nuance (see Surprises & Discoveries).
  Date: 2026-06-03.

- Decision: The resume worker (EP-42) discovers unfinished workflows via the
  `keiro_workflow_steps` index plus a "lacks `WorkflowCompleted`" query, not via a
  kiroku `wf:` prefix subscription.
  Rationale: Prefix subscriptions are an open upstream item; routing around them keeps
  this initiative free of any upstream dependency (`docs/research/10-workflow-roadmap.md`
  §9 leaves the prefix-subscription question open). The index already exists for the
  hot-path step lookup, so reusing it for discovery adds no new storage.
  Date: 2026-06-03.


## Outcomes & Retrospective

(To be filled during and after implementation.)
