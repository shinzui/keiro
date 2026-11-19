---
id: 349
slug: preserve-stored-timer-trace-context-across-untraced-reschedules-to-fix-bug-14
title: "Preserve stored timer trace context across untraced reschedules to fix BUG-14"
kind: exec-plan
created_at: 2026-11-19T02:49:05Z
intention: "intention_01m7rva7n0eyjr2gj8fa860bb6"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-19T02:49:05Z
---

# Preserve stored timer trace context across untraced reschedules to fix BUG-14

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro timers are rows in the PostgreSQL table `keiro.keiro_timers`. Since Keiro 0.25.0.0
each row can remember the trace context of the code that scheduled it, so that when the
timer fires, the span named `timer fire <manager>` carries a link back to the trace that
created the timer. A trace context here is the W3C pair `traceparent` (which trace and
span) and `tracestate` (optional vendor data), stored in two nullable text columns.

A scheduled timer can be re-armed: scheduling the same timer id again while the row is
still `scheduled` moves its fire time and replaces its payload. Today the re-arm also
overwrites both trace columns with whatever the new request carries. If the new request
carries no trace context, the stored context is replaced by NULL and the eventual fire
span has no link. This is bug report
[BUG-14](../bug-reports/14-untraced-timer-reschedule-clears-stored-trace-context.md). It
happens whenever some schedulers have a tracer and others do not (for example during a
rolling deployment), when a tracer is configured but no span is current, and when
application code calls `scheduleTimer` without capturing context first.

After this change, a re-arm that supplies no trace context keeps the stored pair, and a
re-arm that supplies one replaces the pair. Fire time, payload and every other re-armed
field behave exactly as before. You can see it working by running the durable tracing
tests: a new example schedules a traced timer, re-arms it without a context, fires it,
and finds the original creation link on the fire span. That example fails before the fix
and passes after it.


## Progress

- [ ] Milestone 1: a new `DurableTracingSpec` example fails on the current statement,
  showing the fired row with no trace context after an untraced re-arm. BUG-14 moves to
  `in-progress`.
- [ ] Milestone 2: `scheduleTimerStmt` keeps the stored pair on an untraced re-arm and
  replaces it as a pair on a traced one. The new example and the whole `keiro-test` suite
  pass.
- [ ] Milestone 3: Haddock, the operations guide, ADR-60 and the changelog state the
  re-arm rule. BUG-14 is `fixed` with `fixedVersion: unreleased`, and
  `nix develop -c just verify` passes.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fix the SQL statement in `keiro/src/Keiro/Timer/Schema.hs`; add no migration
  and change no Haskell type or function signature.
  Rationale: The defect is in the `ON CONFLICT … DO UPDATE` clause of one prepared
  statement that lives in Haskell source. The columns from migration `0033` are already
  nullable and need no change.
  Date: 2026-11-19

- Decision: Treat the two trace columns as one pair. A request with a `traceparent`
  replaces both columns, so a new context without `tracestate` clears the old
  `tracestate`. A request without a `traceparent` keeps both stored columns.
  Rationale: A `tracestate` is only meaningful beside the `traceparent` it was captured
  with. Merging the columns independently could attach one vendor's state to another
  trace.
  Date: 2026-11-19

- Decision: A traced re-arm continues to replace the stored context, as it does today.
  Rationale: The operations guide says a supplied `TimerRequest.traceContext` wins. Only
  the untraced case contradicts the documentation. Keeping the first context for ever
  would be a behaviour change that nobody has asked for.
  Date: 2026-11-19

- Decision: Leave `scheduleTimerOnceTx` unchanged.
  Rationale: It uses `ON CONFLICT (timer_id) DO NOTHING`, so an existing row, including
  its trace columns, is never touched.
  Date: 2026-11-19


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root. Run every command from the repository
root, because entering the Nix development shell from a package directory creates a stray
PostgreSQL cluster there.

The timer store is `keiro/src/Keiro/Timer/Schema.hs`. Its function
`scheduleTimerTx :: TimerRequest -> Tx.Transaction ()` runs the prepared statement
`scheduleTimerStmt` (near line 689). The statement inserts a row and, when a row with the
same `timer_id` exists and is still `scheduled`, updates it. The update currently contains
these two assignments, which are the defect:

```sql
traceparent = EXCLUDED.traceparent,
tracestate = EXCLUDED.tracestate,
```

`EXCLUDED` is PostgreSQL's name for the row the `INSERT` tried to add, and `keiro_timers`
names the row already stored. `scheduleTimerTx` passes
`fmap (^. #traceparent) (request ^. #traceContext)` and
`(request ^. #traceContext) >>= (^. #tracestate)` as the two trace parameters, so a
request whose `traceContext` is `Nothing` sends two NULLs.

`TimerRequest` is defined in `keiro/src/Keiro/Timer/Types.hs` with a field
`traceContext :: Maybe TraceContext`. `TraceContext` comes from
`Keiro.Integration.Event` and has a `traceparent` and an optional `tracestate`.
`withTimerTraceContext` in the same file and `captureTimerTraceContext` in
`keiro/src/Keiro/Timer.hs` fill a missing context from the current span; both leave the
request unchanged when there is nothing to add. The callers that reach `scheduleTimerTx`
are `keiro/src/Keiro/ProcessManager.hs` (lines near 592 and 736) and
`keiro/src/Keiro/ProcessManager/Reaction.hs` (near line 547). Workflow sleeps in
`keiro/src/Keiro/Workflow/Sleep.hs` use `scheduleTimerOnceTx` and are not affected.

The timer worker is `runTimerWorkerWith` in `keiro/src/Keiro/Timer.hs`. It claims one due
timer, opens the span `timer fire <processManagerName>` with a link built from the row's
stored context, runs the caller's fire action, and returns the claimed `TimerRow`, whose
`traceContext` field shows what was stored.

The tests are in `keiro/test/DurableTracingSpec.hs`, part of the `keiro-test` suite
declared in `keiro/keiro.cabal`. The example "deduplicates first-event sleep as wake and
leaves legacy timers unlinked" already schedules a timer with `Timer.scheduleTimerTx`,
fires it with `Timer.runTimerWorkerWith`, finds the span with the local helper `named`,
and checks links with `assertLinks`. Use it as the model for the new example.

The documented behaviour is in `docs/user/operations.md` (the paragraph beginning "Timers
persist creation context outside their opaque payload", near line 535) and in
[ADR-60](../adr/0060-event-creation-context-and-durable-span-correlation.md), which says
"Timers persist request context in dedicated nullable columns, preserving explicit
context." [ADR-59](../adr/0059-durable-trace-correlation-preserves-replay-and-exact-wake-identity.md)
establishes that this trace data is advisory: it never controls when a timer fires, what
it replays, or which workflow it wakes. Neither ADR says what a re-arm does to the stored
context; this plan adds that sentence to ADR-60. No other ADR is relevant.

The bug was validated on 2026-11-19 by the owning repository. The statement text was
run on PostgreSQL 18.6 in the project Nix shell beside the candidate statement below; the
current statement left both columns NULL after an untraced re-arm, and the candidate kept
the pair and replaced it on a traced re-arm. The transcript is in
`docs/bug-reports/evidence/BUG-14-untraced-reschedule-clears-trace-context.txt`.


## Plan of Work

### Milestone 1: a failing example

Add one example to the `durable tracing` group in `keiro/test/DurableTracingSpec.hs`,
named "keeps a scheduled timer's creation context across an untraced re-arm and replaces
it as a pair when one is supplied". It uses the same `withRecorder` and `runStore`
helpers as its neighbours and two timers with distinct ids and distinct
`processManagerName` values, so their fire spans have different names.

For the first timer, schedule a `Timer.TimerRequest` whose `traceContext` is `Just` a
context with a valid `traceparent` (for example
`00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`) and `tracestate`
`vendor=a`, with a `fireAt` in the past. Schedule the same timer id again with
`traceContext = Nothing`, a different past `fireAt` and a different payload. Fire it with
`Timer.runTimerWorkerWith Nothing (Timer.defaultTimerWorkerOptions & #tracer .~ Just tracer)`.
Expect the returned row to carry the second `fireAt` and payload and the first trace
context, and expect the `timer fire <manager>` span to have exactly one link whose trace
id and span id are those of the first `traceparent`.

For the second timer, schedule it with the same first context, re-arm it with a
different context that has a `traceparent` and no `tracestate`, fire it, and expect the
returned row's context to be the second one with `tracestate` absent.

Run the example. The first half must fail on the current code, with the fired row's
`traceContext` equal to `Nothing`. Then set BUG-14's `status` to `in-progress` in
`docs/bug-reports/14-untraced-timer-reschedule-clears-stored-trace-context.md`, update
its row in `docs/bug-reports/index.md`, and add a line to `docs/bug-reports/log.md`.

### Milestone 2: the statement

In `scheduleTimerStmt` in `keiro/src/Keiro/Timer/Schema.hs`, replace the two trace
assignments with:

```sql
traceparent = COALESCE(EXCLUDED.traceparent, keiro_timers.traceparent),
tracestate = CASE WHEN EXCLUDED.traceparent IS NULL
                  THEN keiro_timers.tracestate
                  ELSE EXCLUDED.tracestate END,
```

Change nothing else in the statement: the parameter list, the `WHERE
keiro_timers.status = 'scheduled'` guard and the other assignments stay as they are.
Extend the Haddock comment on `scheduleTimerTx` with one sentence stating that a re-arm
without a trace context keeps the stored one and a re-arm with one replaces it.

### Milestone 3: documentation and closure

In `docs/user/operations.md`, add to the timer tracing paragraph that re-arming a
scheduled timer without a context keeps the stored creation context, and that a supplied
context replaces it together with its `tracestate`. In ADR-60, extend the sentence about
timers in the same way, advance its `timestamp`, and add a log entry with `okf log add`
(see `okf log add --help`). Add a "Bug Fixes" entry for `keiro` under `## [Unreleased]`
in `CHANGELOG.md`. Set BUG-14 to `fixed` with `fixedVersion: "unreleased"` and a
`resolution` sentence, and update the bug-report index and log, following the shape of
`docs/bug-reports/12-ops-schema-verification-flags-keiro-managed-binding-view.md`.


## Concrete Steps

Check the shell first, from the repository root:

```bash
nix develop -c z3 --version
```

Run the durable tracing examples:

```bash
nix develop -c cabal test keiro:test:keiro-test --test-show-details=direct \
  --test-options='--match "/durable tracing/"'
```

Before Milestone 2 the new example fails with an expectation of this shape:

```text
  expected: Just (TraceContext {traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", tracestate = Just "vendor=a"})
   but got: Nothing
```

After Milestone 2 every example in the group passes. Then run the whole suite and the
repository gate:

```bash
nix develop -c cabal test keiro:test:keiro-test --test-show-details=direct
nix develop -c just verify
```

`just verify` includes `adr-validate`, `bug-reports-validate` and
`user-documentation-validate`, which check the documentation edits of Milestone 3.


## Validation and Acceptance

The change is accepted when all of the following hold.

The new example fails before the statement change and passes after it, and it checks
three things: the stored context survives an untraced re-arm, the fire span links to
that context, and a traced re-arm replaces `traceparent` and `tracestate` together.

The existing example "deduplicates first-event sleep as wake and leaves legacy timers
unlinked" still passes. It proves that a timer never given a context still fires with an
unlinked span.

No other guarantee changes, and this must be stated with evidence when the plan is
closed. The re-arm still updates `fire_at`, `payload`, `process_manager_name` and
`correlation_id`, which the new example checks through the returned row. A timer that is
`firing`, `fired`, `cancelled` or `dead` is still not resurrected, because the `WHERE`
guard is untouched; the existing timer examples in the `keiro-test` suite cover this.
Replay and wake identity are unaffected, because the trace columns are advisory (ADR-59)
and no code reads them to decide behaviour.

There is no performance regression to measure. The statement is still one upsert on the
primary key with the same parameters, round trips and locks; the new expressions read
two columns of the row the update already holds. The `keiro-bench` release-gate guards do
not cover timer scheduling, so the evidence for this claim is the unchanged statement
shape, not a benchmark.

Binaries built before this fix still clear the context when they re-arm a timer. During
a rolling deployment the stored context is safe only from schedulers that carry the fix.
Say so in the changelog entry.


## Idempotence and Recovery

Every step is an ordinary source or documentation edit and can be repeated. The tests
create their own databases through the fixture in `Keiro.Test.Postgres` and leave nothing
behind. No migration or stored data changes, so reverting the commit restores the old
behaviour completely.


## Interfaces and Dependencies

No public interface changes. `Keiro.Timer.Schema.scheduleTimerTx`,
`Keiro.Timer.scheduleTimer`, `Keiro.Timer.Types.TimerRequest` and the
`keiro.keiro_timers` table keep their types and columns. The only behavioural contract
that changes is the one documented above: on a re-arm of a `scheduled` timer,
`traceContext = Nothing` now means "keep the stored context" where it used to mean
"clear it". No dependency is added or upgraded.

Commits made under this plan carry both trailers:

```text
ExecPlan: docs/plans/349-preserve-stored-timer-trace-context-across-untraced-reschedules-to-fix-bug-14.md
Intention: intention_01m7rva7n0eyjr2gj8fa860bb6
```
