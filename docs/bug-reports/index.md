---
okf_version: "0.2"
---

# Bug Report

- [Process-manager and router worker heaps grow during steady write-side load](1-write-side-workers-retain-heap-during-steady-soak.md) - Process-manager and router workers retain increasing post-major-GC heap during a five-minute steady write-side workload.
- [Command workload retains heap with seed verification disabled](2-command-workload-retains-heap-with-seed-verification-disabled.md) - Post-major-GC live heap grows during a command soak with a 10000-event history even when seed verification is disabled.
- [Job worker exits after polling backend termination](3-job-worker-exits-after-polling-backend-termination.md) - A continuous job worker exits after one PostgreSQL polling backend termination and leaves later jobs queued.
- [Long-poll job worker consumes a read attempt without handler delivery](4-long-poll-job-worker-consumes-read-attempt-without-handler.md) - Long-poll workers can skip a handler attempt or inflate the DLQ read count after a handler process is killed.
- [Stale outbox publisher finalizes another publisher's reclaimed claim](5-stale-outbox-publisher-finalizes-reclaimed-claim.md) - A publisher resumed after maintenance can mark a newly claimed outbox row failed or dead even after the new publisher reports success.
- [Six long-poll processors can leave a job queued on the three-connection runtime pool](6-long-poll-processors-starve-the-job-runtime-pool.md) - A six-processor long-poll worker leaves an enqueued job without a handler effect for thirty seconds, while one- and three-processor controls complete.
- [Continuous worker dead-letters an exhausted job without a process span](7-pre-handler-dead-letter-has-no-process-span.md) - A job whose first PGMQ read exceeds its zero retry ceiling reaches the DLQ without a handler call or a per-message process span.
- [Read-model harness imports an inconsistent name for a keyword segment](8-read-model-harness-imports-inconsistent-keyword-segment-name.md) - Keiro DSL accepts a read-model name ending in the snake-case segment type, but its generated definition and harness import disagree on capitalization and fail compilation.
