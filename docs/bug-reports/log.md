# Bundle Update Log

## 2026-09-24
* **Update**: BUG-1 and BUG-2 are tracked by ExecPlans 297 and 298, which attribute the retention across keiro, kiroku, and the Kenshou harness before any fix.
* **Addition**: BUG-1 records process-manager and router worker heap growth in
the steady write-side soak; BUG-2 records command-workload heap growth with
seed verification disabled. Both remain reported pending component isolation.

## 2026-09-23
* **Bootstrap**: Establish the bug-report bundle under the shared
`coordination.bugReports` profile.
