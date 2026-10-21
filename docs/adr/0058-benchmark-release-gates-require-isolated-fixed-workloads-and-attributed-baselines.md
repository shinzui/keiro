---
type: Architecture Decision Record
title: Benchmark release gates require isolated fixed workloads and attributed baselines
description: Release benchmark evidence uses isolated fixtures, fixed measured work, explicit growth bounds and reproducible baselines whose changes have attributed causes.
timestamp: 2026-10-21T13:47:46Z
docId: ADR-58
status: Accepted
date: 2026-10-21
originatingPlan: docs/plans/316-run-the-benchmark-regression-guards-in-the-release-gate.md
---

# Benchmark release gates require isolated fixed workloads and attributed baselines

## Context

REV-20 found benchmark guards that were red but absent from release preflight. A historical
command CSV could not be reproduced at its own source revision on the current environment.
Removing unrelated delegated-inbox preparation materially changed command timings, while
some order anomalies remained. Those observations justify isolated measurement; they do not
prove that every production path is unchanged. A baseline that silently absorbs fixture
interference cannot distinguish a runtime regression from a different workload.

## Decision

Release candidates run the correctness gate followed by all six benchmark guards through
`just release-gate`: five historical CSV comparisons and the producer same-process ratio
guard. Retain the combined log, individual statuses, tested source revision/tree and environment.
A failed or inconclusive comparison is not acceptance. Implementation changes after a passing
run require new evidence; committing evidence alone must preserve the identity of the tested
source. This gate supplements the inspection cohort's independent interference and correctness
gates and mandatory plan completions.

Each benchmark group owns its disposable migrated fixture. The benchmark name/tree is static,
while workload setup and representative database warm-up run only for selected scenarios.
Preparation counters establish isolation; wall time alone is not evidence that work was skipped.
Timed actions measure a stated workload. Irrelevant fixture deletion must not masquerade as
command cost, and fresh identities must not turn intended fresh commands into duplicate probes.
Growth in streams, events or bookkeeping has an explicit bound and stability evidence; exceeding
the bound invalidates the sample rather than producing a truncated successful timing.

Projection rebuild samples reuse one seeded source population and verify the same event count
on repeated runs. New source stream or rebuild group names do not isolate whole-category replay.
Supported target clearing during a rebuild remains part of rebuild cost. Shared reset costs
in ratio comparisons are measured, not assumed to cancel algebraically.

A new CSV uses five serial samples on a quiet machine, with raw CSVs and a README recording
machine, compiler, RTS options, PostgreSQL version/durable settings, fixture/workload bounds,
source revision and aggregation rule. The recording revision must reproduce its own baseline
within the stated ceiling. Re-record each affected workload when its fixture boundary changes,
even if an old, incomparable row happens to pass. Preserve historical samples and state the
attributed reason for replacement. A failing gate alone never justifies baseline movement.

The producer fresh-path guard must be attributed using actual fresh insert work. The locked
lookup in deterministic enqueue is conflict-only; it cannot justify a fresh-path budget.
Threshold or quantity changes require measured rationale and a negative control demonstrating
that excessive cost is still rejected. ADR-42 defines identity semantics, not a millisecond
allowance.

Plan 316 owns this policy and its red/green release-gate demonstrations. Plan 321 owns fixture
isolation and fixed-workload evidence. Plan 315 owns attribution, recording and threshold evidence.
This is an accepted design; the runner is present, but remaining plan checkboxes and benchmark
acceptance are open. This ADR is not a claim of completed measurements or green release status.

## Consequences

A maintainer can audit why a number changed and which source/workload it measures. Investigations
may conclude that an old baseline is non-reproducible without inventing an upstream regression.
Filtered/full comparisons and fixed-count checks must pass before recording replacement rows.
Timing-sensitive release evidence is run on a quiet machine independently of developer iteration.

## References

- [MasterPlan 46](../masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md).
- [Plan 315](../plans/315-attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards.md).
- [Plan 316](../plans/316-run-the-benchmark-regression-guards-in-the-release-gate.md).
- [Plan 321](../plans/321-isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture.md).
- [ADR-42](0042-producer-outbox-identity-is-a-versioned-source-event-contract.md).
- [ADR-48](0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md).
