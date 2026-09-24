---
type: Bug Report
title: Job worker exits after polling backend termination
description: A continuous job worker exits after one PostgreSQL polling backend termination and leaves later jobs queued.
generated:
  by: process:codex
  at: "2026-09-24T05:03:53Z"
bugId: BUG-3
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/keiro
affectedVersion: "0.17.0.0"
environment: PostgreSQL 18 with durable settings; keiro-pgmq 0.17.0.0, pgmq-effectful 0.6.1.0, shibuya-pgmq-adapter 0.16.0.0; StopAllOnFailure supervision.
observed: After a polling backend is terminated, the worker exits with a PgmqSessionError containing UnexpectedRowCountStatementError for pgmq.read. The next batch stays queued.
expected: A transient polling connection failure should be retried within the adapter's five-attempt budget, and the continuous worker should resume handling queued jobs. Keiro's pending runJobWorkers transient-polling test and the Kenshou ExecPlan state this expectation.
reproduction:
  - Build the released cohort used by mori://shinzui/keiro-runtime-kenshou and start durable PostgreSQL 18.
  - Run `nix develop -c cabal run kenshou -- run keiro/queue/concurrency/workers-survive-transient-polling-error --dim pg.durability=durable --out runs/` from the Kenshou repository.
  - Let the worker process its first batch of twenty jobs; the scenario terminates its PostgreSQL polling backend and enqueues the next batch.
  - Inspect the worker control log and the `processing-resumed` and `no-loss` verdicts under the run directory.
workaround: Monitor continuous worker exits and restart runJobWorkers after a polling failure; queued jobs remain durable for recovery.
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
    context: Checked the report against durable Kenshou runs and the OKF profile; the root cause remains under investigation.
---

# Job worker exits after polling backend termination

The harness reproduced the failure with `StopAllOnFailure` in runs
`01a0d1a5-1650-76e3-8cd2-4614dd07ff19` and
`01a0d1a6-a1b0-7753-abc2-a5b50d1d5b76`. The verdict-preserving run
`01a0d1a8-a608-70aa-aca6-8f8272384b92` records the three failed
contract checks and leaves the later batch in the queue. Run artifacts are
under `mori://shinzui/keiro-runtime-kenshou` at `runs/<run-id>`; an
artifact-level Mori URI for run directories is pending.

The worker log reports `PgmqSessionError (StatementSessionError ...
UnexpectedRowCountStatementError 1 1 1)` for `pgmq.read`. The
`shibuya-pgmq-adapter` poll path calls `Pgmq.Effectful.isTransient` before
retrying. That classifier treats statement row-count errors as permanent.
Whether the interrupted connection caused the row-count error needs upstream
investigation; the observation does not establish that the classifier alone
is wrong. Keiro's pending test in `keiro-pgmq/test/Main.hs` names this same
transient-polling behavior.
