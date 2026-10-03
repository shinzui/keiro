# Bundle Update Log

## 2026-10-03
* **Addition**: BUG-9 records that `keiro-ops --json pgmq dlq read` renders `dlq_message_id` with pgmq-core's derived `Show` instead of a number.
* **Addition**: BUG-8 records a parent left suspended permanently when its child's process dies between the child's completion marker and the parent wake.

## 2026-09-30
* **Update**: BUG-7 is tracked by ExecPlan 301, which confirms from adapter and shibuya source that the retry ceiling runs on the adapter's source stream before the supervised runner opens the process span, and plans the fix inside keiro's handler.
* **Update**: Audit all seven lifecycle statuses and plan coverage: BUG-1/BUG-2 remain duplicate with completed plans 297/298; BUG-4/BUG-6 link unimplemented plan 300; BUG-5 links unimplemented plan 299; BUG-3/BUG-7 remain reported with no plan addressing their specific failures. Add per-report implementation notes and the index summary.

## 2026-09-25
* **Update**: BUG-2 attribution controls pass with released Kiroku 0.9.0.1 and bounded verification threads
* **Update**: BUG-1 and BUG-2 duplicates now point to released kiroku-store 0.9.0.1
* **Update**: BUG-2 is a duplicate of mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3: a single-change Kiroku publisher fix reduced matched command-soak post-major live growth from 93.13 MB to 1.63 MB.
* **Update**: BUG-1 is a duplicate of mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3: both released worker profiles identify the Kiroku publisher thunk, and a strict-update comparison removes the large-object growth.

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
