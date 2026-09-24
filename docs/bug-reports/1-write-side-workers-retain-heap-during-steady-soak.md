---
type: Bug Report
title: Process-manager and router worker heaps grow during steady write-side load
description: Process-manager and router workers retain increasing post-major-GC heap during a five-minute steady write-side workload.
generated:
  by: process:claude-code
  at: "2026-09-24T02:56:08Z"
bugId: BUG-1
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/keiro
affectedVersion: "0.17.0.0"
environment: PostgreSQL 18 durable; Keiro 0.17.0.0 with Kiroku Store 0.8.0.1; sixteen accounts, four router recipients, twenty commands per second.
observed: Process-manager post-major-GC live bytes rose from 527680 to 26216704 across 11 samples; router live bytes rose from 529680 to 21746240 across 33 samples in five minutes.
expected: Under steady offered load and bounded persisted state, worker post-major-GC live heap should settle within an operational budget. The Kenshou write-side soak's per-process leak verdict checks this expectation; it is an endurance expectation, not a proven Keiro API guarantee.
reproduction:
  - Check out the released Keiro 0.17.0.0 and Kiroku Store 0.8.0.1 cohort used by mori://shinzui/keiro-runtime-kenshou.
  - Run `cabal run kenshou -- run keiro/command/soak/write-side-steady-state-reduced --set soak.duration-minutes=5 --set command.rate-per-second=20 --set command.accounts=16 --set router.fanout=4 --set projection.prune-interval-seconds=60 --dim pg.durability=durable --out runs` from the Kenshou repository.
  - Inspect the process-manager and router child leak reports and the post-major-GC live-byte series under the run directory.
  - Confirm the nine durable SQL checks pass and compare the first and last post-major-GC samples for both workers.
workaround: No validated mitigation is known; monitor the workers' post-major-GC heap and restart them before reaching the deployment's memory limit if operationally safe.
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
    context: Checked the report against the Kenshou finding and the OKF bug-report profile; component ownership remains unproven.
---

# Process-manager and router worker heaps grow during steady write-side load

The reduced run `01a0d0e6-050d-7746-aaf2-bf0c11368618` completed all nine
durable SQL checks over 9,250 account events, with no dead letters and bounded
snapshot and dedup rows. The process-manager and router child leak verdicts
were `leak-suspected`, with fitted slopes of 301 MB/hour and 220 MB/hour.
Their native memory, thread counts, file descriptors, and PostgreSQL
connection counts were stable. Writer and projection heap series lacked enough
post-major-GC samples for a verdict.

This is a reproducible retention signal in a combined Keiro/Kiroku workload,
not an isolated Keiro defect or proof of unbounded growth. A longer soak,
isolated subscription workload, and retaining-object profiles are needed to
identify the component. The original evidence is in
`mori://shinzui/keiro-runtime-kenshou` at
`docs/findings/1-keiro-write-side-worker-heap-growth.md` (artifact-level URI
pending).

Tracked by [plan 297](../plans/297-isolate-and-fix-write-side-worker-heap-retention-under-steady-subscription-load.md),
which attributes the retention across keiro, kiroku, and the harness before fixing it.
