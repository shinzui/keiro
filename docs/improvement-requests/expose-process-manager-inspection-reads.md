---
type: Improvement Request
title: Expose process-manager inspection reads
description: >-
  Add supported library-level reads that reconstruct a process-manager instance view from its
  journal streams, list shard ownership from keiro_subscription_shards, and list a process
  manager's pending timers — then endpoints wrapping them — so an operator can see what a
  process manager last did and what it is waiting on.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-29
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Expose Process-Manager Inspection Reads

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`).
Library-first like its sibling
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-28`: reads in the owning packages,
endpoints (under `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`) wrapping
them, per `mori://shinzui/keiro/okf/adrs/concepts/ADR-28`. Implementation is keiro's
downstream work.

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
