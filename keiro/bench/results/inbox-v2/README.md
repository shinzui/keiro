# inbox baseline recording

Thirty-eight existing baseline rows retain their names; all 49 selected cases are recorded. Deferred table/duplicate preparation, representative warm-up/statistics and settled checkpoints replace shared eager setup.

Five serial raw `sample-1` through `sample-5` CSV/stdout/setup files use the exact
runner selection/settings, with source revision, binary and machine in `environment.txt`.
See [the recording protocol](../baseline-recording-v2/README.md). `summary.md` reports each
row's median mean, median two-standard-deviation spread and range. `candidate-baseline.csv`
is derived without changing the guard's 25% ceiling; `original-baseline.csv` preserves the
replaced data. All five recording processes completed successfully at `b8695a0d`; the same-source guard
passes in all three full runner controls. The common protocol records durability and bounds.

The fixture boundary and machine changed. Old and new absolute values are not a controlled
production performance comparison. No baseline moves solely because an old guard was red.
