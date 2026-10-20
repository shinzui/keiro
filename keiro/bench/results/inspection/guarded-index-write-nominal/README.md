# Guarded index write diagnostic: completed workflow

Five alternating same-binary schema-only pairs run 1,000 measured operations at
50/s after 50 warm operations, on fresh durable 100,000-row clones. Baseline
removes only the unreleased inspection indexes/generated column. Both legs run
VACUUM FULL and ANALYZE before warmup; the dropped-column descriptor and current
runtime binary mean this is not the pre-change runtime cohort comparison.
All durable/autovacuum settings and the 8192-byte block size are recorded.

Paired median changes are p95 +0.25%, throughput
-0.005%, allocation +0.147%, RTS CPU
+1.96%, and cluster WAL +8.86%. P95 ranges
-9.01% to +21.83%; RTS CPU and WAL also
vary substantially across legs. No noisy comparison is promoted to a pass.
Cluster WAL includes background durable work and is not isolated table WAL.
The raw phase/queue samples, counters and derived summary retain every leg.

The normal operation schedules, claims, runs a real named step, completes and
releases. Candidate HOT counts are 3000/4000 versus 2993/4000 baseline. The
pre-change full-domain/active-client/retention gates remain open.

RTS allocation/CPU counters exclude the pre/post measurement SQL statistics
flushes and include the probe's latency-sample collection. Sources, binary
hashes and compressed parent-relative production patches are retained. Query
cost/key compatibility are established separately by the guarded query and
key-domain evidence; the 5% integrated interference gate is still unproven.
