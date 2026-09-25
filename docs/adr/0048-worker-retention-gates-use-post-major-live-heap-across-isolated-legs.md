---
type: Architecture Decision Record
title: Worker retention gates use post-major live heap across isolated legs
description: Keiro gates worker heap retention on post-major live bytes measured across isolated store, adapter, and dispatch workloads with a conservative slope and growth threshold.
timestamp: 2026-09-25T23:51:50Z
docId: ADR-48
status: Accepted
date: 2026-09-25
originatingPlan: docs/plans/297-isolate-and-fix-write-side-worker-heap-retention-under-steady-subscription-load.md
---

# Worker retention gates use post-major live heap across isolated legs

## Context

A steady subscription workload can grow allocated bytes or process resident memory
without retaining Haskell objects. Conversely, a worker may keep objects alive
without growing its thread or file descriptor counts. The worker heap report in
[BUG-1](../bug-reports/1-write-side-workers-retain-heap-during-steady-soak.md)
was observed in a workload that combined Keiro dispatch, Kiroku storage and
subscriptions, the Shibuya adapter, and an external measurement harness. A
single end-to-end heap trend cannot assign ownership to one of those layers.

## Decision

The `keiro-retention` suite samples `GHC.Stats` live bytes after a forced major
collection at equal operation blocks. It discards the first block as warm-up,
fits a slope against completed operation counts, and reports both the slope and
growth between the first and last kept samples. A leg fails when its slope
exceeds 512 bytes per operation **and** its kept-sample growth exceeds 2 MiB.
The suite also prints large-object bytes and thread counts for diagnosis. These
thresholds are regression gates, not proof that a passing process has no leak.

The suite separates a no-store baseline, direct and transactional Kiroku append,
existence probes, Kiroku subscription delivery, a hand-built ack bridge, the
released Shibuya adapter, the process-manager and router workers, and projection
application. Every leg gets a fresh migrated database. Subscription legs sample
after acknowledged messages; worker legs also record a post-return sample
because a callback sample can keep the current handler frame alive. Worker
legs check their dispatched target event counts. The suite runs in `just
verify` so the same measured workload is exercised in the regular repository
gate.

The command-runner extension seeds a 10,000-event stream with a snapshot at
version 10,000 and measures commands on that stream separately from repeated
hydration, Kiroku tail reads, and commands spread across sixteen streams.
Every command leg asserts its event count and resulting stream version; the
long-history leg also asserts the final snapshot version. The same post-major
gate applies to these legs. A verification-every command leg remains
informational because it intentionally launches asynchronous full replays.
The thread column counts running and blocked Haskell threads after major GC;
finished `Async` handles that remain reachable during the measurement loop are
excluded. This keeps the column aligned with active verification concurrency.
The released command soak became stable when only Kiroku's idle-publisher
position update was made strict, so no Keiro append or hydration repair was
made for BUG-2. That match is recorded in
[ExecPlan 298](../plans/298-isolate-and-fix-command-runner-heap-retention-over-long-snapshotted-histories.md).

Sampled snapshot-seed verification has a process-wide in-flight limit of one
by default. A sampled hit arriving at capacity is skipped and counted, while
an unexpected verification exception is counted and logged; neither changes
the command result. Callers can tune the limit or use zero for unbounded
verification. The limit bounds the additional threads and full-replay heap
that a high sample rate can create, independently of the Kiroku publisher
defect.

For the router, the default 1,500-operation run uses unsnapshotted targets to
match the reported workload. The 20,000-operation diagnostic uses a snapshot
every 100 target events to keep repeated history replay from overwhelming the
worker retention measurement. Results from that longer variant must be named
with its snapshot policy; they do not replace a profile of the original
unsnapshotted workload when assigning the reported defect's cause.

## Consequences

Maintainers can observe a growing worker trend alongside its lower-layer
controls before changing dispatch code or assigning an upstream owner. A
positive short-run slope that settles over a longer run is recorded as warm-up
behavior rather than immediately treated as a leak. A burst that creates
large objects may differ from a paced worker workload, so rate and the
post-return reading remain part of attribution. Closure ownership still
requires matching evidence from the reported workload or a focused profile;
this gate alone cannot identify retained closure types.

## References

- [ExecPlan 297](../plans/297-isolate-and-fix-write-side-worker-heap-retention-under-steady-subscription-load.md)
  — probe design, run tables, and attribution rules.
- [BUG-1](../bug-reports/1-write-side-workers-retain-heap-during-steady-soak.md)
  — the original steady subscription report.
- [ExecPlan 298](../plans/298-isolate-and-fix-command-runner-heap-retention-over-long-snapshotted-histories.md)
  — command-runner controls, matched Kiroku comparison, and verification bound.
- [BUG-2](../bug-reports/2-command-workload-retains-heap-with-seed-verification-disabled.md)
  — the command workload report, now attributed to upstream Kiroku BUG-3.
- `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`
  — the idle-publisher position thunk fixed in Kiroku.
- `mori://shinzui/keiro-runtime-kenshou/okf/adrs/concepts/ADR-10`
  — Kenshou's accepted decision to judge heap trends from post-major live
  bytes. The artifact URI is awaiting coverage in the local Mori registry.
