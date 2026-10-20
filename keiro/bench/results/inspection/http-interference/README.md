# HTTP interference before schema-comparison optimization

Five alternating same-binary runs measure unmounted, mounted idle, one header poll per second, and 32 distinct header polls per second. Each leg warms 50 workflow operations and then offers 1,000 schedule/claim/step/completion/lease-release operations at 50 per second against a durable disposable database with 100,000 seeded workflow rows. Header polls use a point lookup and a dedicated inspection pool; their path avoids the known unindexed list sorting. Raw samples include scheduled queue delay.

| Mode | Median writer p95, microseconds | Median process allocated bytes | Successful polls per leg |
|---|---:|---:|---:|
| Unmounted | 6973 | 671546608 | 0 |
| Mounted idle | 6779 | 671671128 | 0 |
| One view | 6686 | 723609768 | 20 |
| 32 views | 6886 | 2355497688 | 640 |

All polls succeeded. Latency does not show a consistent regression here, but aggregate allocation rises 7.7% for one view and 250.7% for 32 views relative to mounted idle. This exceeds the required 5% allocation bound for this isolated workload and rejects the current implementation. The allocation counter covers the process, including inspection and the in-process WAI test clients; it is not a per-writer-thread counter. The separate schema-cost attribution experiment distinguishes verification from the point read.

This is rejection evidence, not the full old/new cohort matrix. There is no pre-change binary, network transport, slow-reader/large-value deployment leg, or retention acceptance in this experiment. The manifest records exact commands, settings, limitations, source and binary hashes. Production schema refusal remains unchanged pending an explicit implementation revision and new evidence.
