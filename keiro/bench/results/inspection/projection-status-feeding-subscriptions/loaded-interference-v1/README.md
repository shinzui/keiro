# Rejected loaded writer cohort at 970ce6e6

All 40 trials sustained the offered workload, all HTTP polls succeeded, and feeds
received snapshots and updates and cleaned up. The fixed analyzer refused acceptance:
feed p95 candidate/baseline median was 1.037748 (CI95 1.015959..1.289418), while
same-source p99 control CI95 was 0.430751..1.434925. Other latency comparisons were
inconclusive at the required 1% resolution. Throughput and writer-thread allocation
intervals passed. Compiler/test overlap was observed in 416 of 458 process snapshots.
This cohort does not establish a causal runtime regression or a no-regression pass.
No samples or outliers were removed. The next candidate removes an avoidable encoder
list append before repeating the unchanged gate.
