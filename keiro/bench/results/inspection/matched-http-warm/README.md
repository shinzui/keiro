# Warmed real-HTTP comparison: aborted, inconclusive

This repeat warms each active view on a retained TCP connection before the
parent starts measurement. Every mode has a one-second settling interval after
warmup. It reuses the previously qualified fixed writer load of 380 operations/s;
see the manifest, retained sources, binary hashes and source patch for provenance.

Four of five trials completed. The fifth old-runtime baseline failed the declared
headroom check, so the runner stopped before its candidate legs and produced no
comparison summary. No leg or outlier was removed. This is not a five-run gate
and establishes no latency acceptance. Trial four's candidate unmounted and idle
controls also had p95 spikes (about 263 ms and 633 ms). Concurrent unrelated host
work was observed, but these data do not identify the cause of any individual spike.

Retain the failed baseline and logs. Repeat at one fixed, qualified offered load
in a quiet benchmark window or an exclusively leased environment before accepting
the 5% gate. Do not derive a pass from the earlier quiet-looking legs. This narrow
header workload also excludes the complete domain, large-value, slow-reader and
retention matrix required by the master plan.
