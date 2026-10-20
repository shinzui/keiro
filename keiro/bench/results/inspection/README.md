# Inspection implementation evidence

These checkpoints preserve successful correctness experiments, rejected query paths and preliminary/narrow performance comparisons. Their READMEs distinguish attribution, startup, offered-load qualification and acceptance. No directory establishes the complete MasterPlan 45 gate.

Manifests identify source and binary hashes, commands, RTS settings and limitations. Retained `driver.hs`, `runner.py` and `client.py` files preserve earlier probe versions. Compressed `source.patch.gz` files are lossless unified diffs against the named candidate commit; decompress and apply them in a detached checkout before rebuilding that checkpoint. Raw JSON contains full samples and EXPLAIN plans. The root runtime baseline is commit `3bf3ac229f21d6c95179ce49b5e8f6323322f99b`.

The current narrow old/new comparison is `matched-http-qualified/`: all medians lie within 5%, but latency remains inconclusive because controls vary and active connection startup produces an outlier. The subsequent `matched-http-warm/` repeats with warmed persistent clients but aborts when the fifth old-runtime baseline fails headroom; it also establishes no latency pass. The key/class-index experiment remains rejection evidence for generic filtered plans; no extra index migration was selected from it.

`class-branch-prototype/` demonstrates bounded generic class branches on clones.
The direct expression index is rejected by `class-index-write-crash/`: HOT drops
from 210/210 updates to zero and WAL rises about 190%. The nominal companion
would miss this regression. The guarded candidate uses a stored class instead; its longer schema-only
write diagnostics are retained separately and do not establish cohort acceptance.

`key-domain/` rejects the unguarded workflow and compound-owner indexes because
they reject previously accepted stored keys. `query-guarded-keys/` and
`query-wide-key-budget/` retain 136 actual prepared plans for the revised guarded
workflow schema, including bounded explicit failures over 100,000 wide keys.
Owner compound indexes remain unselected; their write diagnostic exceeds the
preliminary 5% median p95 threshold, and the pages stay manual under deadlines.

`guarded-index-write-nominal/` is a longer same-binary schema-only comparison,
not a pre-change/full-cohort proof. Its p95 spread is still inconclusive.
`guarded-index-write-wide/` is a failed pre-measurement fixture: a journal stream
name constraint rejects that key during warmup. Large-row storage checks must
be distinguished from valid completed-workflow measurements.
