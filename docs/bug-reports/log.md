# Bundle Update Log

## 2026-09-24
* **Addition**: BUG-7 records a pre-handler retry-ceiling DLQ delivery that has no per-message process span despite traced enqueue.
* **Addition**: BUG-6 records a six-processor long-poll stall on the fixed three-connection job runtime pool; a one-processor replacement recovered the queued job.
* **Report**: Recorded a durable stale-publisher finalization race after outbox maintenance reclaims a row.
* **Addition**: BUG-3 records a continuous job worker exiting after polling backend termination; BUG-4 records long-poll read attempts consumed without handler delivery after process death. Both were reproduced by the Kenshou queue scenarios and remain reported pending upstream investigation.
* **Update**: BUG-1 and BUG-2 are tracked by ExecPlans 297 and 298, which attribute the retention across keiro, kiroku, and the Kenshou harness before any fix.
* **Addition**: BUG-1 records process-manager and router worker heap growth in
the steady write-side soak; BUG-2 records command-workload heap growth with
seed verification disabled. Both remain reported pending component isolation.

## 2026-09-23
* **Bootstrap**: Establish the bug-report bundle under the shared
`coordination.bugReports` profile.
