# Guarded index write diagnostic: repeated crash counter

Five alternating same-binary schema-only pairs run 1,000 measured operations at
50/s after 50 warm operations, on fresh durable 100,000-row clones. Baseline
removes only the unreleased inspection indexes/generated column. Both legs run
VACUUM FULL and ANALYZE before warmup; the dropped-column descriptor and current
runtime binary mean this is not the pre-change runtime cohort comparison.
All durable/autovacuum settings and the 8192-byte block size are recorded.

Paired median changes are p95 +1.42%, throughput
+0.000%, allocation -0.485%, RTS CPU
+0.57%, and cluster WAL -3.97%. P95 ranges
-0.82% to +3.86%; RTS CPU and WAL also
vary substantially across legs. No noisy comparison is promoted to a pass.
Cluster WAL includes background durable work and is not isolated table WAL.
The raw phase/queue samples, counters and derived summary retain every leg.

The public recordCrashTx runs against one short-key running row; public
resetInstanceAttempts runs every twenty crashes. All 1050 baseline updates
are HOT; candidate retains 950/1050, losing HOT only for the 100 class
transitions. The rejected raw-attempt expression index instead lost HOT on
every increment. This remains a storage diagnostic, not a complete worker
crash/replay benchmark.

RTS allocation/CPU counters exclude the pre/post measurement SQL statistics
flushes and include the probe's latency-sample collection. Sources, binary
hashes and compressed parent-relative production patches are retained. Query
cost/key compatibility are established separately by the guarded query and
key-domain evidence; the 5% integrated interference gate is still unproven.
