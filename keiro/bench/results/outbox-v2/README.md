# outbox baseline recording

Three existing publisher rows retain fixed 2,000-message batches and timed TRUNCATE/seed/drain work. The group now has its own durable clone and selected warm-up.

Five serial raw `sample-1` through `sample-5` CSV/stdout/setup files use the exact
runner selection/settings, with source revision, binary and machine in `environment.txt`.
See [the recording protocol](../baseline-recording-v2/README.md). `summary.md` reports each
row's median mean, median two-standard-deviation spread and range. `candidate-baseline.csv`
is derived without changing the guard's 25% ceiling; `original-baseline.csv` preserves the
replaced data. Recording and same-source control acceptance are initially pending.

The fixture boundary and machine changed. Old and new absolute values are not a controlled
production performance comparison. No baseline moves solely because an old guard was red.
