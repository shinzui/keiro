# Inspection implementation evidence

These checkpoints preserve successful correctness experiments, rejected query paths and preliminary/narrow performance comparisons. Their READMEs distinguish attribution, startup, offered-load qualification and acceptance. No directory establishes the complete MasterPlan 45 gate.

Manifests identify source and binary hashes, commands, RTS settings and limitations. Retained `driver.hs`, `runner.py` and `client.py` files preserve earlier probe versions. Compressed `source.patch.gz` files are lossless unified diffs against the named candidate commit; decompress and apply them in a detached checkout before rebuilding that checkpoint. Raw JSON contains full samples and EXPLAIN plans. The root runtime baseline is commit `3bf3ac229f21d6c95179ce49b5e8f6323322f99b`.

The current narrow old/new comparison is `matched-http-qualified/`: all medians lie within 5%, but latency remains inconclusive because controls vary and active connection startup produces an outlier. The subsequent `matched-http-warm/` repeats with warmed persistent clients but aborts when the fifth old-runtime baseline fails headroom; it also establishes no latency pass. The key/class-index experiment remains rejection evidence for generic filtered plans; no extra index migration was selected from it.

`class-branch-prototype/` demonstrates bounded generic class branches on clones.
The direct expression index is rejected by `class-index-write-crash/`: HOT drops
from 210/210 updates to zero and WAL rises about 190%. The nominal companion
would miss this regression. A stored-class alternative remains experimental.
