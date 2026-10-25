# Recording the accepted harness baselines

Plan 315 records five serial samples for each affected CSV after plan 321 acceptance.
`record.sh` copies the runner's selection, wall-time, `-j1`, 5% requested deviation,
ten-second timeout and `-N2` options. Projection alone enables `KEIRO_READ_MODEL_P95=1`.
Every timed cohort disables diagnostic probes and separates setup stderr from stdout.
Source must be committed; existing recording output is protected from overwrite.

`aggregate.py` validates every selected row and process status, preserves existing CSV
names/order/header, and derives each row's median mean and median two-standard-deviation
spread independently. It first emits candidates, original CSVs and range summaries;
`--apply` writes those validated candidates. No threshold is changed.

All five existing CSVs are affected. Command drops timed hard deletes and uses fresh bounded
identities, established statistics and settled selected setup. Inbox moves table/duplicate
preparation into its isolated selected fixture and warms representative work. Outbox gains
an isolated durable fixture and selected warm-up. Projection/read-model use the isolated
durable read-model fixture, representative stream cardinality and settled setup; projection
controls are adjacent and its P95 sampler is selection-specific. Thus even an old green
row must be re-recorded. These changes and the new machine prevent interpreting CSV movement
as a production before/after speedup.

Build with `nix develop -c cabal build keiro:bench:keiro-bench`, then run `record.sh` inside
`nix develop`. After all 25 processes complete, run `aggregate.py` there to inspect the
candidates and then `aggregate.py --apply`. The recording revision must reproduce the new
rows under the unchanged 25% guard. Raw samples and source/environment evidence remain
beside each group. Failed or incomplete recordings must be retained and investigated.
