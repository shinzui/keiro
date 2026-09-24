---
type: Bug Report
title: Six long-poll processors can leave a job queued on the three-connection runtime pool
description: A six-processor long-poll worker leaves an enqueued job without a handler effect for thirty seconds, while one- and three-processor controls complete.
generated:
  by: process:codex
  at: "2026-09-24T20:53:46Z"
bugId: BUG-6
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/keiro
affectedVersion: "0.17.0.0"
environment: PostgreSQL 18 with durable settings; keiro-pgmq 0.17.0.0, shibuya-pgmq-adapter 0.16.0.0; one worker process with six processors, LongPoll 5 100, and the fixed three-connection job runtime pool.
observed: With six processors, the worker pool had three PostgreSQL connections but a job remained queued with no handler effect after thirty seconds. One- and three-processor controls each completed their job. A replacement one-processor worker eventually drained the stalled job.
expected: A live worker should deliver and acknowledge an available job with bounded delay even when its processor count exceeds the runtime pool size; at minimum, excess long polls should not prevent the available pool connections from making progress.
reproduction:
  - Build the released cohort used by mori://shinzui/keiro-runtime-kenshou and start durable PostgreSQL 18.
  - Run `nix develop -c cabal run kenshou -- run keiro/queue/concurrency/runtime-pool-isolation --dim pg.durability=durable --out runs/` from the Kenshou repository.
  - Inspect the `pool-starvation` diagnosis and the `long-poll-no-loss` verdict parameters for processor counts one, three, and six.
  - Observe that the scenario replaces the stalled six-processor worker with a single-processor worker and verifies eventual delivery without message loss.
workaround: Keep the number of long-poll processors per worker at or below three on the shipped job runtime pool, or use ordinary polling. The one- and three-processor long-poll controls passed under this schedule.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-24T20:54:23Z"
    document_timestamp: "2026-09-24T20:53:46Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Checked the report against three durable runs, the one- and three-processor controls, the recovery run, and the bug-report profile; the exact acquisition failure remains unisolated.
---

# Six long-poll processors can leave a job queued on the three-connection runtime pool

The durable Kenshou runs `01a0d52b-8dc4-77dc-b517-e0abb7c78218` and
`01a0d52d-8a1e-7070-be94-b20e771f6650` reproduced the stall. In the latter
run, the six-processor arm had three job-runtime connections and no handler
effect after thirty seconds; the source queue still contained one row. The
one- and three-processor arms completed with one effect and an empty queue.

Run `01a0d530-2239-7124-af19-f73bbbb94e31` reproduced the same stall and
showed recovery: a replacement worker with one long-poll processor completed
the job. Its `pool-starvation` diagnosis records the stalled processor count,
connection cap, immediate queue state, and recovery result. Run artifacts are
under `mori://shinzui/keiro-runtime-kenshou` at `runs/<run-id>`; an artifact-level
Mori URI for run directories is pending.

The three-connection limit is visible, and excess long polls are the leading
explanation. The probe has not isolated which acquisition or acknowledgement
operation stops progress.
