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
- [Continuous worker dead-letters an exhausted job without a process span](7-pre-handler-dead-letter-has-no-process-span.md) - A pre-handler retry-ceiling dead letter emits no per-message process span.

## Status and plan coverage

Audited on 2026-09-30 against plan progress, recorded validation, current source,
and implementation commits. All seven reports have valid lifecycle statuses under
`mori/bug-reports-profile.dhall`. Plan coverage is recorded separately from the bug
status: an unimplemented plan does not make a report `in-progress` or `fixed`.
`confirmed` requires reproduction by the owning repository; the local reproduction
steps in plans 299 and 300 are still unchecked.

| Report | Status | Plan | Implementation |
| --- | --- | --- | --- |
| [BUG-1](1-write-side-workers-retain-heap-during-steady-soak.md) | `duplicate` | [297](../plans/297-isolate-and-fix-write-side-worker-heap-retention-under-steady-subscription-load.md) | Completed; upstream publisher fix released in kiroku-store 0.9.0.1. Full live-worker soak remains a follow-up. |
| [BUG-2](2-command-workload-retains-heap-with-seed-verification-disabled.md) | `duplicate` | [298](../plans/298-isolate-and-fix-command-runner-heap-retention-over-long-snapshotted-histories.md) | Completed; attribution and retention controls validated, independent verification bound implemented. |
| [BUG-3](3-job-worker-exits-after-polling-backend-termination.md) | `reported` | No plan for this failure | Open; earlier transient-poll retry work does not resolve this observation. |
| [BUG-4](4-long-poll-job-worker-consumes-read-attempt-without-handler.md) | `reported` | [300](../plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md) | Unimplemented; 0/15 progress items checked. |
| [BUG-5](5-stale-outbox-publisher-finalizes-reclaimed-claim.md) | `reported` | [299](../plans/299-fence-outbox-finalization-by-claim-generation-to-fix-bug-5.md) | Unimplemented; 0/22 progress items checked. |
| [BUG-6](6-long-poll-processors-starve-the-job-runtime-pool.md) | `reported` | [300](../plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md) | Unimplemented; 0/15 progress items checked. |
| [BUG-7](7-pre-handler-dead-letter-has-no-process-span.md) | `reported` | No plan for this failure | Open; earlier one-shot tracing work does not resolve this continuous-worker gap. |
