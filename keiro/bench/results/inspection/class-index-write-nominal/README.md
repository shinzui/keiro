# Direct class-expression index: rejected

Five alternating baseline/candidate legs use the same binary on durable fresh
100,000-row clones. Baseline retains migration 0033; candidate adds only the
class/name/id expression index. Normal autovacuum and durable settings are
asserted and retained in every raw sample. The retained driver and manifest
record the operation, build, and source/binary identity. These short 50/s runs
are preliminary storage diagnostics, not old/new cohort or latency acceptance.

Normal schedule/claim/named-step/completion/release operations retain the same
597 HOT updates out of 800 updates, but WAL increases about 5.35% in every leg.
The separate crash-counter experiment rejects this design: normal completion
alone would have missed its write amplification.
