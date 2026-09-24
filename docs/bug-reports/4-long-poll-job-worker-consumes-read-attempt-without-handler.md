---
type: Bug Report
title: Long-poll job worker consumes a read attempt without handler delivery
description: Long-poll workers can skip a handler attempt or inflate the DLQ read count after a handler process is killed.
generated:
  by: process:codex
  at: "2026-09-24T05:03:53Z"
bugId: BUG-4
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/keiro
affectedVersion: "0.17.0.0"
environment: PostgreSQL 18 with durable settings; keiro-pgmq 0.17.0.0, pgmq-hs 0.6.1.0, shibuya-pgmq-adapter 0.16.0.0; two worker processes; LongPoll 5 100; three-second visibility timeout.
observed: After handler process deaths, long-poll deliveries sometimes skip attempt one or dead-letter with read_count five after only three handler calls.
expected: Each read that consumes the retry budget should invoke the handler or dead-letter at the configured ceiling. With three killed handlers and maxRetries three, the next read should move the job to the DLQ at read_count four. The Kenshou crash-redelivery ExecPlan specifies this oracle.
reproduction:
  - Build the released cohort used by mori://shinzui/keiro-runtime-kenshou and start durable PostgreSQL 18.
  - Run `nix develop -c cabal run kenshou -- run keiro/queue/concurrency/crash-redelivery-cadence --dim pg.durability=durable --set queue.polling=long-poll --out runs/` from the Kenshou repository.
  - Let the scenario kill the process holding each delivery; a second worker continues polling the same queue.
  - Compare handler attempt numbers in the worker control logs with the DLQ wrapper's read_count and the `crashes-consume-attempts` verdict.
  - Run the same scenario with the default poll-every mode as a control.
workaround: Use PollEvery rather than LongPoll for jobs whose retry ceiling must correspond to handler deliveries; the poll-every control passed under this schedule.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-24T05:05:55Z"
    document_timestamp: "2026-09-24T05:03:53Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Checked the report against failing long-poll runs, passing poll-every controls, and the OKF profile; the cause remains unisolated.
---

# Long-poll job worker consumes a read attempt without handler delivery

Run `01a0d1b3-8a6c-7624-aa6f-7fff066f8787` delivered handler attempts
zero, one, and two at roughly three-second intervals after three process
kills, but the DLQ wrapper recorded `read_count=5`. Run
`01a0d1b4-5232-707b-abed-404ce0d0db3e` delivered attempts zero and two,
6.16 seconds apart, then moved the job to the DLQ at `read_count=4` without a
third handler delivery. A verdict-preserving run
`01a0d1b5-b342-7584-8a62-771055f84aad` reproduced the failed contract
checks. Run artifacts are under `mori://shinzui/keiro-runtime-kenshou` at
`runs/<run-id>`; an artifact-level Mori URI for run directories is pending.

The `PollEvery 1` control passed in runs
`01a0d1b0-e9e6-7507-88a0-4dbb61bf2fc1` and
`01a0d1b6-4762-7781-8f97-8a52245b0bb4`: three handler attempts were
followed by DLQ `read_count=4`. Concurrent long-poll prefetch is a possible
source of the extra lease, but the harness has not isolated the cause.
