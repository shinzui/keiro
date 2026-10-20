# Guarded index write diagnostic: large wake-ledger row

Five alternating same-binary schema-only pairs run 1,000 measured operations at
50/s after 50 warm operations, on fresh durable 100,000-row clones. Baseline
removes only the unreleased inspection indexes/generated column. Both legs run
VACUUM FULL and ANALYZE before warmup; the dropped-column descriptor and current
runtime binary mean this is not the pre-change runtime cohort comparison.
All durable/autovacuum settings and the 8192-byte block size are recorded.

Paired median changes are p95 +1.03%, throughput
+0.000%, allocation +0.156%, RTS CPU
-0.12%, and cluster WAL +43.75%. P95 ranges
-6.73% to +4.77%; RTS CPU and WAL also
vary substantially across legs. No noisy comparison is promoted to a pass.
Cluster WAL includes background durable work and is not isolated table WAL.
The raw phase/queue samples, counters and derived summary retain every leg.

This storage-only operation upserts a large-key wake-ledger row, claims it,
records its first crash and releases without progress. It writes no journal:
the failed sibling fixture demonstrated that its key exceeds the released
journal's stream-name contract. Candidate HOT counts are 2000/3000; baseline
is 2989..3000/3000. The class change on first crash adds index maintenance;
this cost is reported rather than claimed to be free. It is not a completed
workflow or full worker measurement.

RTS allocation/CPU counters exclude the pre/post measurement SQL statistics
flushes and include the probe's latency-sample collection. Sources, binary
hashes and compressed parent-relative production patches are retained. Query
cost/key compatibility are established separately by the guarded query and
key-domain evidence; the 5% integrated interference gate is still unproven.
