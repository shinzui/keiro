---
id: 335
slug: persist-trace-context-on-timers-and-workflow-journals-and-link-it-on-fire-and-resume
title: "Persist trace context on timers and workflow journals and link it on fire and resume"
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

# Persist trace context on timers and workflow journals and link it on fire and resume

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Keiro has two mechanisms that deliberately pause work for a long time. A *timer* is scheduled
now and fired later by a worker. A *durable workflow* runs until it must wait (for a sleep, an
external signal, or a child workflow), stops, and is resumed by a worker when the thing it was
waiting for has happened, possibly days later.

Today nothing connects the two sides of a pause in a trace. A timer row stores no trace context
and the timer worker opens no span. A workflow's journal events store no trace context, and
each resume is a new span unrelated to the run that suspended or to whatever woke it.

After this change, with a tracer configured: a timer remembers the trace context that was
current when it was scheduled, and firing it opens a span that *links* to that context; a
workflow's journal events remember the context that was current when each was appended, and a
resumed run's span links to the context of the step that woke it and to the context of the
workflow's start. A link is OpenTelemetry's pointer from one span to a causally related span in
another trace, the right relation when the earlier work finished long ago. Someone can see it
by scheduling a timer inside a traced command, letting the worker fire it, and finding the
fire span linked to the command.


## Progress

- [ ] M1: A forward migration adds nullable trace columns to the timers table; the expected
  schema snapshot is regenerated; migration tests pass.
- [ ] M2: Timers store a supplied trace context, Keiro's own scheduling call sites supply it
  when a tracer is configured, and the timer worker opens a linked span per fired timer.
- [ ] M3: Workflow journal appends are stamped with the current context, and a resumed run's
  span links to the waking step and the start.
- [ ] M4: Benchmark and retention gates pass; costs recorded.
- [ ] M5: Documents and the correlation ADR updated; parent MasterPlan updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Timer trace context is stored in two new nullable columns, not inside `payload`.
  Rationale: `payload` is opaque application data that Keiro does not interpret; putting
  framework keys in it would change what applications read back. The outbox and inbox tables
  already use dedicated `traceparent`/`tracestate` columns.
  Date: 2026-11-11

- Decision: Workflow context is stored in journal event metadata under the same keys as domain
  events, not on the derived instance row.
  Rationale: The journal is the workflow's durable record; each wake appends a journal event,
  so the waking context is naturally per event. No schema change is needed.
  Date: 2026-11-11

- Decision: Resume links are added after the journal is read, with `addLink`, rather than in
  the span's creation arguments.
  Rationale: The contexts to link are in the journal, which is read inside the workflow span.
  Opening the span later would leave journal replay untraced. The cost is that samplers cannot
  see these links; record it as a known limitation.
  Date: 2026-11-11

- Decision: Timer and resume spans are roots that link; they are never children of the stored
  context.
  Rationale: The stored context's span has ended by construction.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a child of
`docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md`.
Prerequisites: `docs/plans/330-establish-tracing-enabled-performance-and-retention-baselines.md`
and
`docs/plans/331-stamp-trace-context-on-appended-events-and-name-command-spans-by-category.md`
are Complete. Plan 331 provides, in `keiro/src/Keiro/Telemetry.hs`:

```haskell
traceContextFromCurrentSpan :: (MonadIO m) => m (Maybe TraceContext)   -- pre-existing
traceContextFromMetadata :: Maybe Value -> Maybe TraceContext
stampTraceContext :: (MonadIO m) => Maybe Value -> m (Maybe Value)
creationLinkFromTraceContext :: TraceContext -> Maybe NewLink
```

and makes commands write `traceparent`/`tracestate` into appended events' metadata. If
`stampTraceContext` does not exist, stop. `TraceContext` is the record
`{ traceparent :: Text, tracestate :: Maybe Text }` from
`keiro-core/src/Keiro/Integration/Event.hs`.

Run everything in the Nix development shell (`nix develop -c …`).

Timers. `keiro/src/Keiro/Timer/Types.hs` defines `TimerRequest` (`timerId`,
`processManagerName`, `correlationId`, `fireAt`, `payload`). `scheduleTimerTx` and
`scheduleTimerOnceTx` (`keiro/src/Keiro/Timer/Schema.hs` near lines 553 and 573) insert into
`keiro.keiro_timers`; they run in hasql's `Tx.Transaction`, which has no I/O and no tracer.
`TimerRow` is near line 121 of the same file. The worker is in `keiro/src/Keiro/Timer.hs`:
`runTimerWorkerWith`, `drainDueTimersWith` and `claimAndFireOne` (near lines 167–233) claim a
due row and call a caller-supplied `fire :: TimerRow -> Eff es (Maybe EventId)`, then mark the
timer fired. `TimerWorkerOptions` is near line 114. There is no tracer or span anywhere on this
path. Find Keiro's own callers of the scheduling functions (process-manager timer requests and
workflow sleeps in `keiro/src/Keiro/Workflow/Sleep.hs`) with a search for `scheduleTimer`.

Workflows. `keiro/src/Keiro/Workflow.hs`: `runWorkflowWith` runs or resumes a workflow; its
`runActive` wraps one invocation in `withWorkflowSpan` (near line 579), an Internal-kind span
named `workflow <name>`. `WorkflowRunOptions.tracer` (near line 402) supplies the tracer. Each
workflow generation's journal is a Kiroku stream `wf:<name>-<id>`; journal events are appended
in `keiro/src/Keiro/Workflow/Journal.hs` (near line 91) with
`encodeForAppendWithMetadata workflowJournalCodec Nothing event`, so their metadata carries only
the schema version. A wake (a sleep timer firing through `workflowSleepFireAction` in
`Workflow/Sleep.hs` near line 319, `signalAwakeable`, or a child completing) appends a
`StepRecorded` journal event under the awaited step's name; the resume worker
(`keiro/src/Keiro/Workflow/Resume.hs`, `resumeWorkflowsOnce` near line 401) then calls
`runWorkflowWith` again, passing `WorkflowResumeOptions.runOptions`.

Migrations. Schema changes are forward-only SQL files in `keiro-migrations/migrations/`, listed
in `migrations/manifest`; the latest is `0032.sql`. `keiro-migrations/README.md` and
`docs/user/migrations.md` give the procedure: create the file with `keiro-migrate new`, never
edit a shipped migration, schema-qualify every object, regenerate the expected-schema snapshot.
[ADR-9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) covers live schema
verification.

Relevant ADRs: ADR-9 above;
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
and
[ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
for Milestone 4;
[ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md) and
[ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
freeze workflow replay identity: journal *metadata* must not influence replay, and Milestone 3
includes a check that it does not. Plan 331 creates the correlation ADR that this plan extends.

The contract from the parent MasterPlan: with no tracer nothing new is computed or stored
(columns and metadata keys stay absent); with a tracer, one context read per schedule or journal
append and at most two links per resume; stored context never changes a replay; nothing
reachable from a span references a timer payload or journal event.


## Plan of Work

### Milestone 1: the migration

Create a forward migration adding `traceparent text` and `tracestate text`, both nullable with
no default, to `keiro.keiro_timers`. Adding nullable columns without defaults does not rewrite
the table. Follow the README: generate the file with `keiro-migrate new`, run `check`,
regenerate the expected-schema snapshot, and run the migrations test suite. Old code that does
not name the columns in its inserts keeps working against the new schema, which is what makes a
rolling deployment safe; confirm every existing insert and select names its columns explicitly.

### Milestone 2: timers

Add `traceContext :: !(Maybe TraceContext)` to `TimerRequest` and to `TimerRow`, write it in the
scheduling statements and read it in the claim statements. `TimerRequest`'s constructor is
exported, so this is a breaking change for applications that build it positionally; note it in
the changelog and, if the module has a smart constructor or default, set the field to `Nothing`
there.

Because scheduling runs in a transaction, the context must be captured before it. At each of
Keiro's own scheduling call sites, when a tracer is configured in the surrounding options,
call `traceContextFromCurrentSpan` in the effect layer before entering the transaction and put
the result in the request. With no tracer, leave it `Nothing` and make no call. For a timer
scheduled from a process-manager reaction, the current span is the dispatching command's span
or, once
`docs/plans/333-open-linked-processing-spans-in-subscription-workers-and-the-inbox-consumer-helper.md`
is done, the worker's processing span; either is a correct creation context.

Add a `tracer :: !(Maybe Tracer)` field to `TimerWorkerOptions` (default `Nothing`) and a helper
`withTimerFireSpan` in `Keiro.Telemetry` (signature in Interfaces and Dependencies). In
`claimAndFireOne`, wrap the call to `fire` and the subsequent mark-fired in it. The span is
Internal-kind, named `timer fire <processManagerName>`, opened in an empty context so it is a
root, with the link to the row's stored context in its creation arguments, and attributes
`keiro.timer.id`, `keiro.timer.process_manager` and the lag between `fireAt` and now. Commands
dispatched by `fire` then run as children of this span and stamp their events with their own
command spans. A firing that throws sets error status; the existing retry and dead-letter
behaviour is unchanged.

Tests: a timer scheduled inside a traced command stores that command span's context; firing it
exports one root span with a link to that span; a command dispatched by `fire` is its child; a
timer scheduled without a tracer stores nulls and fires with no span when the worker has no
tracer, and with an unlinked span when it has one; rows written before the migration (nulls)
fire normally.

### Milestone 3: workflows

Stamp journal appends. In `Workflow/Journal.hs`, the append takes metadata `Nothing`; thread an
optional pre-computed metadata value from the callers, computed with `stampTraceContext Nothing`
in the effect layer when `WorkflowRunOptions.tracer` (or the waking code's tracer) is set, and
`Nothing` otherwise. Cover every journal append: steps recorded by a running workflow (current
span: the workflow span), the wake appends from the sleep fire action (current span: the timer
fire span from Milestone 2), `signalAwakeable` (current span: whatever the caller has), and
child completion.

Confirm journal metadata does not influence replay: read how journal events are decoded and
folded, and add a test that replays one journal twice, once with and once without trace keys in
metadata, and gets identical results and identical replay digests.

Link on resume. In `runActive`, after the journal has been read for a run that is a resume,
collect at most two contexts from the journal events' metadata with `traceContextFromMetadata`:
the first journal event's (the start) and the most recent wake's (the last `StepRecorded` that
was not written by this run). Add them to the workflow span with `addLink`, each with a
one-entry attribute map `keiro.workflow.link = "start"` or `"wake"`; when both are the same
context, add one. A first run adds nothing. Do this only when the tracer is set. Extend
`withWorkflowSpan` or its body as needed, keeping its pass-through behaviour.

Tests: a workflow that sleeps and is resumed by the timer worker exports a resume span with a
`wake` link to the timer fire span and a `start` link to the first run's workflow span; a
workflow resumed by a signal links to the signalling caller's span; a first run has no links;
no tracer, no metadata keys and no links; the replay-equality test above.

### Milestone 4: gates

Add benchmark cells, with and without a tracer, for scheduling and firing a fixed number of
timers and for a workflow that suspends and resumes a fixed number of times. Compare against a
worktree of the previous plan's last commit using the procedure plan 330 recorded. Reading
rule: no-tracer cells unchanged in allocation except for the two extra null columns per timer
row read, which should be negligible and must be stated; tracer cells increase by one context
read and two short strings per schedule or journal append, and one span per fire; record each.
Anything else stops the plan.

Add tracer-enabled retention legs for a long run of timer fires and for a workflow with a long
journal that is resumed repeatedly. Both must end `Bounded`; in particular the resume span must
not retain the journal it scanned for contexts.

### Milestone 5: documents

Update the "Timer fire" and "Workflow run" sections of
`docs/research/opentelemetry-semconv-audit.md`, the capability document, `docs/user/operations.md`,
the migrations guide's list of migrations if it has one, and the changelog (new migration,
`TimerRequest` field, `TimerWorkerOptions.tracer`, new spans and links). Extend the correlation
ADR with: where timer and workflow contexts are stored; resume links use `addLink` and why;
journal metadata is excluded from replay. Mark this plan Complete in the parent MasterPlan and
update Progress.


## Concrete Steps

From the repository root:

```bash
nix develop -c cabal run keiro-migrate -- new --manifest keiro-migrations/migrations/manifest --description "add trace context columns to timers"
nix develop -c cabal run keiro-migrate -- check --manifest keiro-migrations/migrations/manifest
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 nix develop -c cabal test keiro-migrations-test --test-options='--match "checked-in snapshot"'
nix develop -c cabal test keiro-migrations-test
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal test keiro-test
nix develop -c cabal test keiro-retention
nix develop -c just adr-validate
nix develop -c just verify
```

Check the exact `keiro-migrate` invocation against `keiro-migrations/README.md` before running;
that file is authoritative.

Expected new test lines:

```text
a timer stores the scheduling span's context
firing a timer opens a root span linked to the scheduling span
a resumed workflow links to the wake and to the start
journal metadata does not affect replay
```


## Validation and Acceptance

Scheduling a timer inside a traced command and letting the worker fire it exports a span
`timer fire <manager>` with no parent and one link to the command's span. Before this plan no
span is exported for the fire.

A workflow that sleeps and resumes exports two `workflow <name>` spans; the second carries a
`wake` link to the timer fire span and a `start` link to the first. Before this plan the second
has no links.

Replaying a journal with and without trace metadata gives identical results. The migration
applies cleanly to a database at `0032`, and code from before this plan runs against the
migrated schema.

`keiro-test`, `keiro-migrations-test`, `keiro-retention` and `just verify` pass, and the
benchmark comparison matches the reading rule with costs recorded here.


## Idempotence and Recovery

The migration is forward-only and additive; never edit it after it ships, and correct mistakes
with a further migration. It is safe to apply before deploying the new code. Rolling back the
code leaves two unused nullable columns and extra metadata keys that older code ignores. If
`keiro-migrate new` was run twice, delete the unwanted file and its manifest line before
committing, and re-run `check`. Tests use throwaway databases.


## Interfaces and Dependencies

Prerequisites: plans 330 and 331 Complete. Plan 333 improves the creation context captured for
timers scheduled by subscription workers but is not required. No new package dependency.

Changed:

```haskell
-- Keiro.Timer.Types
data TimerRequest = TimerRequest
  { timerId :: !TimerId, processManagerName :: !Text, correlationId :: !Text,
    fireAt :: !UTCTime, payload :: !Value,
    traceContext :: !(Maybe TraceContext) }

-- Keiro.Timer
data TimerWorkerOptions = TimerWorkerOptions { ..., tracer :: !(Maybe Tracer) }
```

Added to `Keiro.Telemetry`:

```haskell
withTimerFireSpan ::
  (MonadUnliftIO m, HasCallStack) =>
  Maybe Tracer ->
  -- | process manager name
  Text ->
  -- | timer id text
  Text ->
  Maybe TraceContext ->
  (Maybe Span -> m a) ->
  m a
```

New attribute keys: `keiro.timer.id`, `keiro.timer.process_manager`, `keiro.timer.fire_lag`,
`keiro.workflow.link`. New table columns: `keiro.keiro_timers.traceparent`, `.tracestate`.
No other plan depends on this one.
