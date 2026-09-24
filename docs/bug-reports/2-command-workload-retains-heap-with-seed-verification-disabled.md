---
type: Bug Report
title: Command workload retains heap with seed verification disabled
description: Post-major-GC live heap grows during a command soak with a 10000-event history even when seed verification is disabled.
generated:
  by: process:claude-code
  at: "2026-09-24T02:56:08Z"
bugId: BUG-2
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/keiro
affectedVersion: "0.17.0.0"
environment: PostgreSQL 18 durable; Keiro 0.17.0.0 with Kiroku Store 0.8.0.1; 10000-event account history; forced major GC every ten seconds.
observed: A three-minute run with seed verification sampling set to zero grew from 13.3 MB to 92.8 MB post-major-GC live heap across 17 samples; matched low-rate runs with sampling off and on grew similarly.
expected: A sustained command workload on an existing stream should eventually reach a stable post-major-GC live heap when retained state is bounded. The Kenshou seed-backlog soak's leak diagnosis checks this expectation; it is an endurance expectation, not a proven Keiro API guarantee.
reproduction:
  - Check out the released Keiro 0.17.0.0 and Kiroku Store 0.8.0.1 cohort used by mori://shinzui/keiro-runtime-kenshou.
  - Run `cabal run kenshou -- run keiro/snapshot/soak/seed-verification-backlog-reduced --set command.stream-length=10000 --set snapshot.seed-verify-sample-rate=0 --set soak.duration-minutes=3 --set diagnose.major-gc-interval-ms=10000 --dim pg.durability=durable --out runs` from the Kenshou repository.
  - Inspect the main process post-major-GC live-byte series and leak verdict under the run directory.
  - Confirm all four durable checks pass, then compare post-major-GC live bytes across the steady window.
workaround: No validated mitigation is known; monitor heap use under long histories and set a process memory budget while this retention is investigated.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-24T02:29:27Z"
    document_timestamp: "2026-09-24T02:28:32Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Checked the report against the Kenshou finding and the OKF bug-report profile; component ownership and long-run behavior remain unproven.
---

# Command workload retains heap with seed verification disabled

Run `01a0d0f6-822c-7427-a4c9-0a84cd11329c` completed 21,527 commands
without failures and passed all four durable checks. Its 17 post-major-GC
samples grew by 79.5 MB over 160 seconds, with a fitted 1.86 GB/hour slope
and 1.92 GB/hour second-half slope. Native memory, Haskell and OS threads,
file descriptors, and PostgreSQL connections were stable. Forced collections
make this diagnostic evidence, not comparable latency evidence.

A controlled two-minute pair at three commands per second completed 391
commands in each arm. Sampling rate zero grew 58.8 MB; rate one grew 59.6 MB.
Their second-half slopes were much smaller than full-window slopes, so a
warming cache remains possible. These observations do not identify the
retaining component among Keiro, Kiroku, and Kenshou. A longer matched pair
and retaining-object profile are needed. The original evidence is in
`mori://shinzui/keiro-runtime-kenshou` at
`docs/findings/2-keiro-seed-backlog-heap-growth.md` (artifact-level URI
pending).

Tracked by [plan 298](../plans/298-isolate-and-fix-command-runner-heap-retention-over-long-snapshotted-histories.md),
which reuses the retention harness of plan 297 for the command runner over a long
snapshotted history.
