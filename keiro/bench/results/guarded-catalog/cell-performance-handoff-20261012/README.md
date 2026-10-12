# Performance handoff — 2026-10-12

The exhaustive 190-report matrix is stopped after the user objected to its cost and release impact. No new measurement or full-matrix retry is authorized by this checkpoint.

The custom matrix bypassed the bounded `kenshou perf` workflow in mori://shinzui/keiro-runtime-kenshou (project-relative runbook `docs/runbooks/compare-runtime-revision-performance.md`; artifact URI pending). That workflow has a 30-minute example execution budget; increasing a custom matrix deadline to 36 hours was the wrong response to the user's turnaround requirement. The existing profile catalog covers Shibuya core/PGMQ, not this guarded catalog workload. This is a scope/integration mismatch, not evidence that the fast harness is slow or defective.

## Retained evidence

- Run `01a130cb-58bf-7705-9641-f06bb4b46e89` is sealed as cancelled. All 743 files were freshly fetched and verified, manifest SHA-256 `6d40d36c08ae0ae8f55ad3917352151904b342ecca78560e079e89deb3c05923`.
- Durable raw graph: `gs://tan-nb-exp-cells-results/runs/01a130cb-58bf-7705-9641-f06bb4b46e89/`. Local verified tree: `/tmp/keiro306-remote-preparation/measurement-interrupted-fastfetch`.
- Corrected summarizer on a separate analysis copy finds 19 reports: 16 ordinary comparisons, one empty guard, one indexed miss, one pure-hit cost report. No reported budget failures and no missing durability settings. These are partial observations, not verified performance acceptance.
- Cancellation sealed `health-unavailable`; raw role observations are absent. Independent health replay cannot establish healthy isolation. Do not promote the partial reports to an authoritative performance pass.
- Restart `01a13133-d7ad-703f-a9b6-05b08b60434e` failed infrastructure reset before executing the workload. Its six artifacts verify with manifest SHA-256 `20f2af8f1868f171881090ef3a5168dc07e5c217fdce6cf549a1af0c628595ec`. Durable graph: `gs://tan-nb-exp-cells-results/runs/01a13133-d7ad-703f-a9b6-05b08b60434e/`.
- Lease `keiro-306-lease-20261012-fullmatrix` was released. The builder watchdog remains active. Owner shutdown completes successfully after one cloud API timeout: PostgreSQL was already stopped and the driver, monitoring and broker instances were stopped. The owned lease holder has exited; its transient sleep assertion ends with it.

Correctness remains established by the retained 755-example suite and focused concurrency/rollback/catalog lifecycle tests. Exhaustive mixed traffic, fixed-arrival and sustained storage acceptance is incomplete. Future performance work must use explicitly selected relevant scope, a bounded execution budget and supported recovery. No package publication occurred.
