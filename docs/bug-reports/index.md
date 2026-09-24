---
okf_version: "0.2"
---

# Bug Report

- [Process-manager and router worker heaps grow during steady write-side load](1-write-side-workers-retain-heap-during-steady-soak.md) - Process-manager and router workers retain increasing post-major-GC heap during a five-minute steady write-side workload.
- [Command workload retains heap with seed verification disabled](2-command-workload-retains-heap-with-seed-verification-disabled.md) - Post-major-GC live heap grows during a command soak with a 10000-event history even when seed verification is disabled.
