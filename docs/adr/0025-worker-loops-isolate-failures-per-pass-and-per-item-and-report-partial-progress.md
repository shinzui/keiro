---
type: Architecture Decision Record
title: Worker loops isolate failures per pass and per item and report partial progress
description: A keiro background worker never lets one transient error end its loop or one bad item end its batch, and its summary counts work finished rather than work attempted.
timestamp: 2026-08-12T18:24:20Z
docId: ADR-25
status: Accepted
date: 2026-08-06
originatingPlan: docs/plans/203-concurrent-resume-passes-batched-timer-drain-and-worker-pass-robustness.md
---

# 25. Worker loops isolate failures per pass and per item and report partial progress

Date: 2026-08-06

Status: Accepted


## Context

Keiro runs several background workers over the same shape: a loop that wakes on
an interval or a notification, claims a batch of durable work, processes each
item, and sleeps again. The resume worker, the timer worker, the outbox and
inbox publishers, the sharded subscription worker, and workflow garbage
collection are all this shape.

The shape has a failure mode that does not announce itself. A worker whose loop
does not catch dies on its first transient database error, and the process keeps
running — so nothing crashes, nothing alerts, and the work simply stops
happening until someone restarts the process. A worker whose *batch* does not
catch loses every item behind the first bad one on each pass, which looks like
intermittent slowness rather than a stuck item. And a worker whose summary
reports how many items it *selected* rather than how many it *finished* converts
both of those into silence: the numbers say the pass succeeded.

The resume worker had per-pass isolation from the start. The 2026-08 re-audit
found that workflow GC did not: `runWorkflowGcWorker` was a bare `forever` with
no handler, and `gcWorkflowsOnce` computed `deleted` as `length eligible` — the
count of what it looked at, restated. A single failing deletion aborted the
batch, the first transient error ended collection until process restart, and a
pass that collected nothing would have reported full success. The re-audit also
found a narrower instance of the same class in the resume worker: a workflow
that went terminal between crashing and having its crash recorded made the
crash-recording update match zero rows, which failed a single-row decoder
outside the per-advance handlers and aborted the whole pass.

None of this was a design disagreement. The convention existed; it was simply
not written down, so a worker written later did not inherit it.


## Decision

Every keiro background worker loop obeys three rules.

**Isolate per pass.** The loop catches `StoreError` and synchronous exceptions
around each pass, reports them through a caller-supplied hook, sleeps, and
continues. A transient error costs one tick, never the worker.
`Keiro.Workflow.Resume.runWorkflowResumeWorkerWith` and
`Keiro.Workflow.Gc.runWorkflowGcWorkerWith` are the reference shape; a worker
that takes no logging hook takes a compact stderr default instead of swallowing.

**Isolate per item.** Within a pass, one item's failure must not remove the
others from that pass. Where an item's processing can fail independently — a
workflow advance, a workflow deletion — the failure is caught at the item
boundary and the batch continues. This holds for expected-but-unusual outcomes
too: a status guard that legitimately matches no row is an answer, not an error,
and must be decoded as one (`Maybe`, not a single-row decoder).

**Report finished work, not attempted work.** A pass summary counts what it
completed. Where selected and completed can differ, both are reported and the
gap is meaningful — `WorkflowGcSummary` carries `scanned` and `deleted`
separately, and the loop logs when they diverge. A summary field must never be
another field restated.

The same distinction governs bounded workflow drains. `ResumeSummary.discovered`
is the number admitted to a pass; it is a pool-size observation, not evidence of
convergence. `ResumeSummary.advanced` counts candidates whose durable journal or
terminal state moved: every successful workflow outcome and a crash that reaches
the failure ceiling and records `WorkflowFailed`. A sub-ceiling crash, transient
store error, live foreign lease, paced retry, unavailable claim, or unregistered
workflow name is not an advance. Claim refusal is typed as `ClaimAcquired`,
`ClaimLeaseHeld`, `ClaimPaced`, or `ClaimUnavailable`; the summary reports paced
claims separately and carries the deduplicated set of unregistered names.

A caller draining bounded passes repeats only while `advanced > 0`. When a pass
reports zero advances, it stops and reports the remaining blocked pool instead
of spinning until `discovered == 0`, which is impossible for a paced retry or a
definition absent from the application registry.

Asynchronous exceptions are excluded from all of the above: cancellation and
shutdown must propagate.

Convergence is what makes per-item isolation safe rather than lossy. A worker
may only swallow an item's failure when the item remains selectable on the next
pass — workflow GC deletes the instance row that confers eligibility last, so a
partially collected workflow is re-selected; a resume candidate stays `running`
and stays discovered. A worker that would silently drop work instead of retrying
it does not get to isolate; it must surface the failure.


## Consequences

- Worker robustness is a reviewable property with a written contract rather than
  a habit each author reconstructs. A new worker that omits any of the three
  rules is wrong against this record, not merely different.
- Operators can trust a worker's silence. Since a pass logs its own failures and
  its own shortfalls, "no output" means "nothing went wrong", which is only true
  because both are reported.
- Summaries are usable as monitoring signals. A persistent `scanned > deleted`
  gap is a stuck item; before this decision it was invisible.
- Operator drains terminate on durable progress and preserve actionable blocked
  state. `keiro-ops wf resume-once` reports `advanced`, `paced`, and the exact
  sorted `unregistered_names`, while `discovered` remains useful as the admitted
  pool size rather than being overloaded as a continuation flag.
- Per-item isolation is deliberately *not* a general error swallow. A store error
  escaping the resume worker's terminal-marking path still aborts the pass
  (`resumeWorkflowsOnce` returns `Left`), because widening that would change
  which failures an operator sees. Extending isolation to a new call site is a
  decision to make explicitly, with the convergence argument above.
- The rule binds third-party code that runs keiro's single-pass units.
  `resumeWorkflowsOnce`, `gcWorkflowsOnce`, `runTimerWorkerWith`, and
  `drainDueTimersWith` are the testable units; a caller supplying its own loop
  inherits these obligations, which is stated for adopters in
  `docs/guides/durable-workflows.md`.
