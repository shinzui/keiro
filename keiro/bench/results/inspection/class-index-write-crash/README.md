# Direct class-expression index: rejected

Five alternating baseline/candidate legs use the same binary on durable fresh
100,000-row clones. Baseline retains migration 0033; candidate adds only the
class/name/id expression index. Normal autovacuum and durable settings are
asserted and retained in every raw sample. The retained driver and manifest
record the operation, build, and source/binary identity. These short 50/s runs
are preliminary storage diagnostics, not old/new cohort or latency acceptance.

The public recordCrashTx runs repeatedly against one running row, with public
resetInstanceAttempts every twenty crashes. All 210 baseline updates are HOT;
zero candidate updates are HOT. WAL increases about 190% in all five pairs.
The expression references attempts, so incrementing it invalidates HOT even
when the resulting class remains retrying. The diagnostic includes ten resets;
it is not a complete resumed/crashing worker workload. No migration adopts
this index. See the nominal experiment for the completion-path comparison.
