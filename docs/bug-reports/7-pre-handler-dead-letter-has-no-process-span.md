---
type: Bug Report
title: Continuous worker dead-letters an exhausted job without a process span
description: A job whose first PGMQ read exceeds its zero retry ceiling reaches the DLQ without a handler call or a per-message process span.
generated:
  by: process:codex
  at: "2026-09-24T22:44:18Z"
bugId: BUG-7
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/keiro
affectedVersion: "0.17.0.0"
environment: PostgreSQL 18 with durable settings; keiro-pgmq 0.17.0.0; sdk-inmemory tracing and collected metrics.
observed: The continuous worker moved a traced job with maxRetries=0 to its DLQ before invoking the handler. The DLQ held one row and the handler call count was zero, but no telemetry-pre-handler process span was exported.
expected: The documented per-message Consumer span should cover this delivery and record its dead-letter acknowledgement and error status, even when the retry ceiling prevents a handler call.
reproduction:
  - Build the released cohort used by mori://shinzui/keiro-runtime-kenshou and start durable PostgreSQL 18.
  - Run `nix develop -c cabal run kenshou -- run keiro/queue/correctness/telemetry-contract --dim pg.durability=durable --dim telemetry.tracing=sdk-inmemory --dim telemetry.metrics=collect --out runs/` from the Kenshou repository.
  - Inspect the `queue-telemetry` measurement summary. The observed run had `preHandlerCalls=0`, `preHandlerDlqRows=1`, and `preHandlerSpanCount=0`.
workaround: Treat the DLQ row and PGMQ operation spans as the available evidence for these pre-handler dead letters; a per-message process span is currently absent.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-24T22:44:18Z"
    document_timestamp: "2026-09-24T22:44:18Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Checked the report against the durable telemetry summary, Keiro's tracing contract, and the observed pre-handler DLQ row; the exact upstream fix remains untested.
---

# Continuous worker dead-letters an exhausted job without a process span

The durable Kenshou run `01a0d594-5f5a-74c9-9089-2a3a94db3eb3` passed its
queue telemetry contract and recorded the observation. Its pre-handler job had
`maxRetries=0`, was enqueued with trace context, and was handled by a continuous
`runJobWorkers` worker. One DLQ row appeared with no handler call. The in-memory
exporter recorded zero `telemetry-pre-handler process` spans, while the two
ordinary worker deliveries each produced a process span.

The tracing section of `keiro-pgmq/src/Keiro/PGMQ/Job.hs` promises a common
per-message process span for both execution shapes and an error status for
dead-lettering. The adapter's retry-ceiling path runs during polling before
the supervised runner invokes the processor handler. That path is the likely
reason the runner never opens a per-message span; this is an inference from
the observed run and source control flow, not an isolated patch test.

Run artifacts are under `mori://shinzui/keiro-runtime-kenshou` at
`runs/<run-id>`; an artifact-level Mori URI for run directories is pending.
