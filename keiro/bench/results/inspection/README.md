# Inspection implementation evidence

These checkpoints preserve successful correctness experiments, rejected query paths and preliminary/narrow performance comparisons. Their READMEs distinguish attribution, startup, offered-load qualification and acceptance. No directory establishes the complete MasterPlan 45 gate.

Manifests identify source and binary hashes, commands, RTS settings and limitations. Retained `driver.hs`, `runner.py` and `client.py` files preserve earlier probe versions. Compressed `source.patch.gz` files are lossless unified diffs against the named candidate commit; decompress and apply them in a detached checkout before rebuilding that checkpoint. Raw JSON contains full samples and EXPLAIN plans. The root runtime baseline is commit `3bf3ac229f21d6c95179ce49b5e8f6323322f99b`.

## Current candidate: 5893c7eb

The final implementation keeps the published 0.21.0.0 writer schema and migration
payloads. Inspection classes are computed during reads. Ordinary writer SQL,
default-off provenance metadata and default hydration stay on their existing
paths; existing runtime libraries have no web dependency.

- [Writer capacity](readside-writer-capacity/README.md): five alternating pairs,
  throughput -1.66%, p95 -1.70%, writer-thread allocation -0.01%.
- [Final core interference](final-core-interference/README.md): five matched
  blocks pass all six writer throughput/p95/allocation median gates, with raw
  variation retained.
- [Final workflow query plans](query-readside/README.md): 68 actual prepared
  custom/generic plans over 10k/100k ledgers, with existing indexes.
- [Final lifecycle probes](readside-retention/README.md) and
  [active probe](readside-retention-active/README.md): zero feed resources after
  cleanup; mounted server retains about 0.9–1.7 MB. Timing overlapped verification
  and is not latency acceptance.
- [Ordinary hydration](hydration-core-path/README.md): five matched comparisons
  per source mode plus optimized Core for the diagnostic-free worker.
- [Pending timer plans](pending-timer-read/README.md) and
  [projection status plans](projection-status-read/README.md): inspection cost
  evidence and operating envelopes, not blanket performance targets.

## Rejected and diagnostic checkpoints

The former generated-class/guarded-index candidate is withdrawn. Its
[capacity comparison](composed-writer-capacity-final/README.md) loses 9.22%
median writer throughput with inspection unmounted. The earlier
[paced matrix](composed-core-interference/README.md) concealed that capacity
loss and does not accept the final implementation. Old class/key/hash query
plans and schema-only write tests retain the rejected approaches and why they
were investigated; none describes the final writer schema.

The original heap probe retained a floated enumeration even in the pre-change
runtime; [controls](composed-retention-controls/README.md) and optimized Core
identify the instrumentation root. The corrected counter then exposed lazy
HTTP connection-registry map updates retaining finished handles. Those
[intermediate probes](composed-feed-retention-corrected/README.md) predate the
strict registry fix. Final lifecycle evidence is linked above.

Earlier HTTP capacity/startup/long-pool and interrupted experiments are kept
for attribution with their local limitations. In particular, narrow
`matched-http-qualified/` and `matched-http-warm/` comparisons were inconclusive,
and `composed-unmounted-control/` overlapped compilation and was interrupted.
They are not acceptance. Every sample remains available; inspection request
latency, total-process allocation and WAL have no blanket 5% target.
