---
type: Improvement Request
title: Expose process-manager inspection reads
description: >-
  Add supported library-level reads that reconstruct a process-manager instance view from its
  journal streams, list shard ownership from keiro_subscription_shards, and list a process
  manager's pending timers — then endpoints wrapping them — so an operator can see what a
  process manager last did and what it is waiting on.
timestamp: 2026-11-04T05:28:05Z
requestId: IR-29
status: completed
origin: mori://shinzui/keiro-ui
plan: docs/plans/274-expose-process-manager-inspection-reads.md
relatedPlans:
  - docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md
  - docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md
  - docs/plans/326-make-releases-preflighted-resumable-and-isolated.md
  - docs/plans/319-inspect-reaction-process-managers-and-label-legacy-inspection-before-1-0.md
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-09-16T04:45:00Z
    document_timestamp: 2026-09-11T14:30:01Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5
    effort: high
    context: >-
      Bundle refresh at Keiro `708aa215`. `accepted` is correct and the plan link resolves. Plan
      274 has 1 checked item (planning) and 16 open, so nothing is implemented. The premises
      hold: no pending-timer or manager-instance inspection read exists under `keiro/src`, and
      the kiroku listing dependency is still unreleased — the kiroku checkout ships
      `kiroku-store` 0.8.0.0 with no `listStreams`, and Hackage's newest release is 0.8.0.0. The
      Planning section's reference to `listStreamsInCategory` is the name used in kiroku's IR-8;
      plan 274 and IR-28 both describe the delivered shape as the prefix-filtered `listStreams`
      of kiroku plan 88, which is the same primitive under the name kiroku settled on.
completedAt: 2026-11-04T05:28:05Z
resolution: >-
  Plan 274 delivered process-manager state and instance reads, pending-timer paging, and shard
  inspection.
  Keiro 0.22.0.0 shipped the cohort after the accepted b2be482b release gate.
  Plan 326 retains an exact-version published consumer with a healthy composed
  /keiro/health response; the 0.23.0.0 published consumer repeats that proof.
  Completion reconciles retained evidence; Plan 303 release tracking lags those records.
---

# Improvement Request: Expose Process-Manager Inspection Reads

## Status

**Completed; reconciled on 2026-11-04.**
[ExecPlan 274](../plans/274-expose-process-manager-inspection-reads.md)
delivered process-manager state and instance reads, pending-timer paging, and shard inspection.
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md)
records all six implementation children Complete and their accepted runtime-interference evidence.

The cohort shipped in Keiro 0.22.0.0 (release commit `fb6e3cff`) after the
[final release gate](../../keiro/bench/results/release-gates/0.22.0.0-checks.txt)
passed correctness, all six benchmark guards, native Nix and package checks.
[ExecPlan 326](../plans/326-make-releases-preflighted-resumable-and-isolated.md) retains the
[exact-version published consumer](../../keiro/bench/results/release-gates/workflow-326/published/result.json),
which builds the released packages and serves the composed `/keiro/health` response
with `status: ok` and no schema drift. The
[0.23.0.0 published consumer](../../keiro/bench/results/release-gates/0.23.0.0-20261031T121415Z-60c43662/published/result.json)
repeats that proof (evidence commit `e643c696`). These records satisfy the publication and
consumer gates assigned to
[ExecPlan 303](../plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md);
its older unchecked release milestones do not describe the released state.

Originally proposed by the runtime UI initiative under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`.
The implementation notes below retain the earlier local checkpoints; their pending-release
statements describe those dates, before the release and consumer proof.

## Context

Process managers — the components that react to events with commands, carrying sagas and
long-running coordinations — journal their state into kiroku streams and are otherwise
invisible: no keiro read API reconstructs a process-manager instance's view, and the only
tabled state is the shard-ownership leases in `keiro_subscription_shards`. When a saga stalls,
the operator's questions are concrete: which instance is it, what did it last do, what event
is it waiting for, which timer will wake it, and which process currently owns its shard? Every
one of those answers exists in journal streams, `keiro_timers`, and
`keiro_subscription_shards` — none is reachable without writing Haskell against internals.

Boundaries: raw journal-event display delegates to kiroku's browsing surface
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8`), with surrogate-id name
resolution per `mori://shinzui/kiroku/okf/adrs/concepts/ADR-1`; processor-level supervision of
the queue workers that drive delivery is shibuya's
(`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-3`). keiro's view is the
framework semantics: the instance, its journaled state, its timers, its shard.

## Requested Change

1. Library-level reads in the owning packages:
   a. list process-manager instances (by process-manager type, cursor-paginated) with enough
      identity to drill in;
   b. reconstruct one instance's inspection view from its journal streams — last handled
      event, emitted commands, current waiting condition — through the same supported
      machinery the runtime itself uses to rebuild PM state, never a parallel decoder;
   c. shard ownership views over `keiro_subscription_shards`: which buckets exist, which
      process holds each lease, lease age;
   d. per-instance and per-type pending timers from `keiro_timers`.
2. Endpoints in the IR-26 sister package wrapping those reads, following the initiative's
   wire conventions (project `mori://shinzui/keiro-ui`, path
   `docs/architecture/inspection-api-conventions.md`, artifact-level URI pending) and ADR-28's
   reporting vocabulary.
3. Raw journal browsing delegated by reference to kiroku's endpoints, as in IR-28.

## Acceptance

1. With a test application running a process manager across several instances, the list read
   pages instances by type, and the instance view shows the last handled event and the
   current waiting condition, matching what the runtime's own rebuild would compute (asserted
   by test).
2. Shard views show every bucket with its owner and lease age; killing an owner and letting
   the lease pass shows the new owner without restarting the read surface.
3. Timer listings for an instance show its pending timers with due times; after a timer
   fires, a fresh read no longer lists it.
4. All reads go through supported library operations — no ad-hoc SQL against `keiro` or
   kiroku private schemas (ADR-28), verifiable by inspection.
5. The endpoints serve the same data as the library reads (spot-checked per domain), paged
   and shaped per the conventions.

## Requested Deliverables

The library reads with tests (including the rebuild-equivalence assertion for the instance
view), the wrapping endpoints with documented transcripts, and the delegation links to
kiroku's browsing surface.

## Planning (2026-09-10)

[ExecPlan 274](../plans/274-expose-process-manager-inspection-reads.md) sequences this
request as a validation gate followed by reaction provenance, the instance view, pending
timer reads, shard ownership views, instance listing, and documentation. Three scoping
decisions are recorded there. The manager journal carries no link to the source event a
reaction answered, so manager-state appends gain additive provenance metadata that leaves
deterministic ids and payloads unchanged. Listing instances by type needs a kiroku-store
primitive (`listStreamsInCategory`, item 1a of
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8`), which is added and released in
kiroku before keiro wraps it. The endpoints of item 2 are delivered as read-only `keiro-ops`
commands emitting the initiative's wire shapes; the HTTP transport itself is
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`'s sister package.
At this planning checkpoint, completion awaited implementation and release evidence;
the Status section above records their subsequent reconciliation.

## Implementation evidence (2026-10-20, historical checkpoint)

Plan 274 adds `Keiro.ProcessManager.Inspect`, pending-timer pages and detailed
shard ownership/listing through supported owner APIs. The embedded example
mounts the fulfillment catalog beside existing hooks. Its packing test compares
CLI JSON with the library state and intended-dispatch witness. Core tests cover
runtime rebuild equivalence, default-off metadata, bounded capture, membership
continuation, read-only timer pages and lease failover. Historical and modern
reaction provenance remain explicitly unavailable; target witnesses never infer
failure. Integrated interference, feeds and publication were pending at this
checkpoint; see Status for subsequent completion.
