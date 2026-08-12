---
type: Architecture Decision Record
title: Workflow discovery is exact and the instance row is the complete wake ledger
description: A workflow is discovered only when its keiro_workflows row says it has progress to make, so every wake-source lifecycle transition must write that row.
timestamp: 2026-08-12T18:24:20Z
docId: ADR-23
status: Accepted
date: 2026-08-06
originatingPlan: docs/plans/200-make-suspended-workflows-quiescent-and-discovery-index-aligned.md
---

# 23. Workflow discovery is exact and the instance row is the complete wake ledger

Date: 2026-08-06

Status: Accepted


## Context

The resume worker finds work with one query over `keiro.keiro_workflows`. That
query used to return every non-terminal instance whose `wake_after` hint was
absent or due. Only a sleep arm ever writes `wake_after`, so a workflow
suspended on an awakeable or on a child was returned by every pass: claimed,
journal-replayed, re-armed, and re-suspended, roughly a dozen round-trips for
no progress, once per pass per instance. A deployment holding a thousand parked
approval flows paid that cost every second, and on every store append under the
push-aware worker.

The broad query was also load-bearing in a way that was never written down. It
was what eventually noticed a cancelled awakeable, because `cancelAwakeable`
writes no journal entry and touched no instance row; the workflow only learned
its promise was abandoned by being re-run so its await arm could re-read the
awakeable table. And it masked a race: a run consults the step index, finds the
awaited step absent, arms, and only then writes `suspended`, so a wake
committing in that gap had its `running` overwritten — invisible under an exact
predicate, harmless under a predicate that returned the row anyway.

Narrowing discovery is therefore not a query change. It moves the engine's
liveness argument from "re-examine everything, often" to "every transition
records itself", which is a contract every present and future wake source has
to keep.


## Decision

Discovery is exact. `findUnfinishedWorkflowIds` returns an instance when its
status is `running`, or when its status is `suspended` and its `wake_after`
hint is due. A `suspended` instance with no due hint is parked on a wake source
and is deliberately invisible.

The `keiro_workflows` row is consequently the complete wake ledger: **every**
wake-source lifecycle transition must leave the owning instance discoverable in
the same transaction that performs it. Wake delivery already does this through
`prepareJournalAppend`, which upserts the row to `running` alongside the journal
append and the step-index write. Cancellation of an awakeable — which has no
result to journal — resolves the owner and current generation, takes that same
awaited-step advisory lock, and flips the owner row to `running` in the same
transaction as the row's `pending` to `cancelled` transition. It does not
fabricate a step-index row: ADR 5 makes any indexed value authoritative replay
data, while cancellation has no result value to decode. A third-party wake
source inherits the same obligation; delivering a result through
`appendJournalEntry` satisfies it automatically, and any transition that does
not append must write the instance row itself under an arbitration discipline
the suspend path can observe.

The suspend write arbitrates against wake delivery rather than assuming it
lost or won. `markInstanceSuspendedAwaiting` takes the same per-step advisory
lock the append path takes (`workflowStepLockKey`, shared by both callers so
the derivations cannot drift), re-checks the authoritative step index for the
awaited step on the run's generation, and writes `suspended` only when the step
is still absent. For a syntactically valid `awk:<uuid>` step whose index result
is absent, it additionally consults the awakeable row: `pending` or missing
remains `suspended`, while either terminal status (`completed` or `cancelled`)
writes `running`. The completed case repairs the historical wedge in which the
row settled without its step-index delivery; the awakeable await arm re-delivers
the stored payload on the next run. Signal, cancellation, and suspension are
therefore totally ordered under one lock, and whichever writer runs second
observes the durable artifact the first committed. This preserves ADR 5's rule
that only real result data enters the replay-visible step index.

`wake_after` remains what ADR 7 defines: a sleep-only scheduling hint owned by
the first arm, not a general wake mechanism. No wake source other than a sleep
may write it, and no source may rely on it for visibility.

The child-link table is no longer a discovery source. `spawnChild` upserts the
child's instance row as `running` inside the spawn step's transaction, so a
zero-step child is already discovered; `findRunningChildIds` is retained for
operator inspection only.


## Consequences

- A workflow parked on an awakeable, a child, or a future-dated sleep costs the
  resume worker nothing until something happens to it. Idle cost stops scaling
  with the number of parked workflows.
- Discovery is index-aligned. Both arms of the predicate are stated positively,
  which is the only form from which Postgres can prove partial-index
  applicability — it never consults the table's CHECK constraint — so the query
  plans as an index scan on `keiro_workflows_active_idx`, now
  `(status, wake_after)`.
- A wake source that transitions its durable row without writing the instance
  row strands its workflow permanently. This is the failure mode the old broad
  poll hid, and it is now a correctness requirement rather than a performance
  detail.
- A workflow-sleep timer cancelled by an operator (`Keiro.Timer.cancelTimer`)
  leaves its workflow discoverable-and-idle from the hint's due time onward,
  exactly as before this decision: the arm cannot re-insert the cancelled timer
  row, so nothing rewrites or clears the hint. An operator must resurrect or
  cancel such a workflow deliberately.
- Crash retries are unaffected: a crashed instance stays `running` and stays
  discovered, and `claimInstance`'s `next_attempt_at` gate — not discovery —
  paces the backoff. `ClaimOutcome` and `ResumeSummary.paced` distinguish that
  condition from a live foreign lease.
- Cancellation cannot be overwritten by a stale suspend write. Both commit
  orders leave the instance `running`, so exact discovery re-enters the workflow
  and lets its awakeable arm observe `WorkflowAwakeableCancelled`.
- Migration 0021 returns every pre-existing `suspended` instance to `running`
  once. A legacy suspension may be parked on a promise that was already
  cancelled, or on a transition that predates this rule, and nothing would flip
  it again; one extra replay per legacy instance converges every case through
  the new arbitration.
- Reverting the code alone is a safe rollback. Broad discovery is a superset of
  exact discovery, and the `(status, wake_after)` index serves the old
  predicate too.
