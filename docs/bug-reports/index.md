---
okf_version: "0.2"
---

# Bug Report

- [Process-manager and router worker heaps grow during steady write-side load](1-write-side-workers-retain-heap-during-steady-soak.md) - Process-manager and router workers retain increasing post-major-GC heap during a five-minute steady write-side workload.
- [Command workload retains heap with seed verification disabled](2-command-workload-retains-heap-with-seed-verification-disabled.md) - Post-major-GC live heap grows during a command soak with a 10000-event history even when seed verification is disabled.
- [Job worker exits after polling backend termination](3-job-worker-exits-after-polling-backend-termination.md) - A continuous worker exits after its polling backend is terminated and leaves later jobs queued.
- [Long-poll job worker consumes a read attempt without handler delivery](4-long-poll-job-worker-consumes-read-attempt-without-handler.md) - Long polling can consume retry budget after process death without a corresponding handler call.
- [Stale outbox publisher finalizes another publisher's reclaimed claim](5-stale-outbox-publisher-finalizes-reclaimed-claim.md) - A resumed publisher can mark a newer claim failed or dead after its publisher reported success.
- [Six long-poll processors can leave a job queued on the three-connection runtime pool](6-long-poll-processors-starve-the-job-runtime-pool.md) - Excess long-poll processors can leave a job queued until a smaller worker takes over.
