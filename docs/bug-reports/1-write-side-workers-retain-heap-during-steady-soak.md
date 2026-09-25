---
type: Bug Report
title: Process-manager and router worker heaps grow during steady write-side load
description: Process-manager and router workers retain increasing post-major-GC heap during a five-minute steady write-side workload.
generated:
  by: process:codex
  at: "2026-09-25T22:16:28Z"
bugId: BUG-1
status: duplicate
duplicateOf: mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3
resolution: >-
  Exact released-cohort info-table profiles of both live workers identify the same
  growing Kiroku EventPublisher cheapAdvance thunk at line 251 and a Hasql decoder
  closure. Kiroku's empty-subscriber path stores an unevaluated max in its position
  TVar, retaining earlier append results. A 20,000-append Kiroku-only control grew
  16.92 MiB with 15.03 MiB of large objects; forcing the scalar position in an
  isolated Kiroku 0.9.0.0 worktree held large objects near 0.30 MiB. The upstream
  defect is tracked as Kiroku BUG-3 and fixed in kiroku-store 0.9.0.1.
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
workaround: Upgrade to kiroku-store 0.9.0.1 or later. From the reported 0.8.0.1 cohort, stop older writers, apply Kiroku schema migration 0012, then start the new writers; this is not a rolling upgrade. The full live-worker soak still needs re-verification against the published package.
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
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-25T20:28:57Z"
    document_timestamp: "2026-09-25T20:28:57Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Checked both released-cohort info-table profiles, Kiroku 0.8.0.1 and 0.9.0.0 publisher source, the isolated strict-update comparison, and upstream BUG-3.
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

## Attribution

The exact released-cohort process-manager and router profiles both name
`Kiroku.Store.Subscription.EventPublisher` line 251 and a Hasql decoder as
growing allocation sites. The Kiroku-only 20,000-operation direct append leg
retained 16.92 MiB at 1,184 bytes per operation, with large objects reaching
15.03 MiB. A detached Kiroku 0.9.0.0 worktree that forced the publisher's next
global position before the TVar write reduced that leg to 332 bytes per
operation and kept large objects near 0.30 MiB. Kiroku 0.8.0.1, used by the
reported cohort, contains the same lazy update. The worker retention therefore
duplicates `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`.

At the default 1,500 operations, `baseline-no-store`,
`kiroku-append-probe`, `kiroku-append-only`, `kiroku-append-tx`,
`kiroku-probe-only`, `kiroku-subscribe-ack`, `hand-bridge-ack`,
`shibuya-adapter-ack`, `pm-worker`, `router-worker`, and
`projection-apply` were all `bounded`. Both worker legs were also bounded at
20,000 operations; the longer router run used snapshots every 100 target
events. Those worker legs consume pre-appended source events, so their samples
do not reproduce the reporter's live feed into the publisher. The separate
Kiroku control and matching live worker profiles provide the attribution.
The strict publisher update is released in `kiroku-store` 0.9.0.1; a full
live-worker soak against that release remains to be run.
