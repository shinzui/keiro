---
type: Bug Report
title: Command workload retains heap with seed verification disabled
description: Post-major-GC live heap grows during a command soak with a 10000-event history even when seed verification is disabled.
generated:
  by: process:codex
  at: "2026-09-25T22:16:28Z"
bugId: BUG-2
status: duplicate
duplicateOf: mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3
resolution: >-
  A matched three-minute Kenshou command soak changed only Kiroku Store 0.8.0.1's
  idle-publisher position update to force the scalar before its TVar write.
  Post-major live growth fell from 93.13 MB to 1.63 MB and large-object growth
  from 88.33 MB to 0.27 MB; both runs completed about 22,000 commands without
  errors and passed the durable checks. Kiroku BUG-3 owns the publisher thunk
  that retained earlier Hasql append results. Keiro's independent sampled
  verification fan-out is bounded in plan 298 but did not cause this report.
  The publisher fix is released in kiroku-store 0.9.0.1.
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
workaround: Upgrade to kiroku-store 0.9.0.1 or later. From the reported 0.8.0.1 cohort, stop older writers, apply Kiroku schema migration 0012, then start the new writers; this is not a rolling upgrade.
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
warming cache remained possible from these runs alone. A matched diagnostic
profile then used the same released Keiro 0.17.0.0 cohort, command settings,
and three-minute duration, replacing only Kiroku Store 0.8.0.1 with its tagged
source plus the strict publisher-position update. The unchanged arm grew
93.13 MB post-major live heap and 88.33 MB of large objects; the patched arm
grew 1.63 MB and 0.27 MB respectively, with a `stable` verdict and all durable
checks passing. This identifies the upstream publisher thunk as the cause of
the headline command-soak growth. The fix is published in `kiroku-store`
0.9.0.1. The original evidence is in
`mori://shinzui/keiro-runtime-kenshou` at
`docs/findings/2-keiro-seed-backlog-heap-growth.md` (artifact-level URI
pending).

Tracked by [plan 298](../plans/298-isolate-and-fix-command-runner-heap-retention-over-long-snapshotted-histories.md),
which reuses the retention harness of plan 297 for the command runner over a long
snapshotted history.

## Attribution controls

The original cohort's closure-type profile grew `THUNK_1_0`, `THUNK_2_0`,
`ARR_WORDS`, and `Data.ByteString.Internal.Type.BS` bands while its stack band
stayed flat. The info-table render could not name the owner of those bands.
The source-locked Kiroku comparison above supplies the attribution to
`mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`.

With released `kiroku-store` 0.9.0.1, the independent retention harness's
20,000-command long-history leg passed stream and final-snapshot checks. Its
eight post-major live samples stayed between 2.19 and 3.02 MiB, large objects
stayed at 340,528 bytes, and the fitted slope was -30 bytes per operation
(`bounded`). At 1,500 operations the long-history, hydration-only, Kiroku
tail-read, and short-history legs were also `bounded`, growing 0.67, 0.32,
0.22, and 0.37 MiB respectively across kept samples. The sampled
verification-every leg had 21 active threads at each of six samples after
Keiro's independent one-task process-wide bound.
