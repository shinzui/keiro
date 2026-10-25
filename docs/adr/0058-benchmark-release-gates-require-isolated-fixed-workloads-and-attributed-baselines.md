---
type: Architecture Decision Record
title: Benchmark release gates require isolated fixed workloads and attributed baselines
description: Release benchmark evidence uses isolated fixtures, fixed measured work, explicit growth bounds and reproducible baselines whose changes have attributed causes.
timestamp: 2026-10-25T11:07:22Z
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

Database clones share server-wide checkpoint work. Selected serial benchmark setup finishes
prior checkpoint work outside timing, then performs final representative warm-up. This
settles the fixture boundary without changing command SQL, event counts or durable commit
settings. OS and autovacuum activity remain part of the recorded environment. Retain
maintenance snapshots when investigating cross-scenario effects: logical data isolation alone
cannot establish physical independence. PostgreSQL documents the shared checkpoint I/O and
its WAL/time triggers in its [WAL configuration guide](https://www.postgresql.org/docs/18/wal-configuration.html).

Control comparisons must see nearby retained populations. Placing every legacy case before
every versioned case in a growing store can compare different points in that growth, even
with isolated groups and selected warm-up. Keep corresponding sequential controls adjacent,
retain the alternating sampler for its stated latency/throughput contract, and verify with
probes disabled. Representative statistics describe both stream cardinality and event volume;
many events in one stream do not establish a stream-name lookup population.

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
allowance. The fresh guard compares the median of 15 adjacent legacy/deterministic
full-workload ratios in alternating order, separately for batch and per-event transactions,
with the 1.10 ceiling retained. Every pair includes the actual preparation, timed reset,
transaction boundaries and insert assertions, and verifies the retained 1,000 rows. Retain
all pair timings. Sequential adaptive means put controls at different times even when their
individual spreads are small; a fixed paired median reduces sensitivity to drift and rare
maintenance pauses without deleting observations. Deliberate extra fresh cost must still fail.

Plan 316 owns this policy and its red/green release-gate demonstrations. Plan 321 owns fixture
isolation and fixed-workload evidence. Plan 315 owns attribution, recording and threshold evidence.
Fixture acceptance is demonstrated at `ee2f2667`: three alternating filtered/full pairs,
all 96 names, actual stored counts, fixed rebuild inputs, settled reset probes and five-block
growth evidence are retained. Plan 315 records all five CSVs from 25 successful serial
samples at `b8695a0d`, preserving all 78 names. Same-source controls reproduce every CSV.
Actual producer counts and preparation/SQL/full-factory pairs attribute fresh work; a
+20-ms/action control refuses both transaction shapes. Three consecutive complete
six-guard runs pass with identical source/binary/baseline hashes at `4f2b4b69` under the
1.10 paired ceiling. Plan 316 demonstrates the full release gate at `a4332cfe`: correctness
passes in both complete runs, a retained impossible command baseline produces the sole guard
failure and recipe exit 1, and exact restoration produces six passing guards and recipe exit 0.
Both uninterrupted combined logs, the perturbation, source/binary/baseline identity and wrapper
process statuses are retained. The final evidence/documentation commit preserves the tested
implementation. A later release candidate still requires its own complete gate.

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
- [Harness diagnostics](../../keiro/bench/results/harness-isolation-v1/README.md) retain accepted actual counts, prepared plans, growth spreads, settled checkpoint boundaries and three alternating pairs; rejected cohorts remain separate.
- [Baseline recording and accepted full controls](../../keiro/bench/results/baseline-recording-v2/README.md).
- [Producer attribution and added-cost refusal](../../keiro/bench/results/producer-attribution-v2/README.md).
- [Accepted red/green release evidence](../../keiro/bench/results/release-gates/README.md).
- [Full refusing gate](../../keiro/bench/results/release-gates/20261025T101845Z-a4332cfe.log).
- [Full passing gate](../../keiro/bench/results/release-gates/20261025T104300Z-a4332cfe.log).
- [ADR-42](0042-producer-outbox-identity-is-a-versioned-source-event-contract.md).
- [ADR-48](0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md).
