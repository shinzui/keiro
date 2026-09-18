# Delegated inbox benchmark evidence

Measured on 2026-09-15 from commit `256b2595` plus the uncommitted Milestone-6
benchmark change. Each row is 2,000 deliveries. The table and delegated variants
use the same 1 KiB integration payload, indexed downstream receipt probe, one
event append, and one SQL counter update. Table intake adds its inbox receipt in
the same transaction. Delegated intake uses the downstream event as its receipt.

The table below reports the median of five serial process runs. The range is the
minimum and maximum of those five `tasty-bench` means. Throughput is derived
from the median. Allocation is the median RTS allocation divided by 2,000.

| Workload, metrics off | Table median (range) | Delegated median (range) | Table / delegated deliveries/s | Table / delegated bytes allocated per delivery |
| --- | ---: | ---: | ---: | ---: |
| Fresh, single | 1.844 s (1.788–2.371) | 1.637 s (1.602–1.736) | 1,084 / 1,222 | 200,228 / 95,612 |
| Fresh, chunks of 100 | 1.308 s (1.271–1.930) | 1.613 s (1.600–1.690) | 1,530 / 1,240 | 182,341 / 96,538 |
| Fresh, chunks of 1,000 | 1.582 s (1.559–1.697) | 1.323 s (1.302–1.769) | 1,264 / 1,511 | 181,660 / 96,098 |
| Repeated key, single | 309.3 ms (303.1–323.1) | 62.5 ms (60.7–77.1) | 6,466 / 31,979 | 181,652 / 12,188 |
| All duplicate, single | 302.7 ms (298.1–312.5) | 58.9 ms (58.4–59.6) | 6,607 / 33,960 | 181,562 / 12,050 |

Metrics-on fresh single delivery measured 1.794 s (1.668–1.961) for table and
1.589 s (1.534–1.655) for delegated, or 1,115 and 1,259 deliveries/s. Repeated
single delivery measured 314.2 ms table and 65.2 ms delegated with metrics on.
The `batch-replay-*.csv` files contain the complete metrics-on/off repeated and
all-duplicate matrix for chunks of 100 and 1,000.

Fresh chunk-100 is the observed crossover: the table batch's shared commit is
about 23% faster. Delegation is about 13% faster for fresh single delivery and
20% faster at chunk 1,000 in these samples, but fresh timings have visibly wider
ranges than replay timings. Use table batching where the service's measured
chunk shape favors it. Delegation's consistent benefit here is lower allocation
and cheaper confirmed replay, not universal fresh-delivery latency.

The equivalent direct-handler loop has a 1.626 s fresh median, compared with
1.637 s through `runInboxDelegated`: 0.68% wrapper overhead. The isolated
`direct-solo-*.csv` and `wrapper-solo-*.csv` files are used for this comparison.
The earlier `wrapper-*.csv` paired runs are retained but excluded: whichever
fresh benchmark ran second inherited thousands of streams from the first and
was consistently slower.

## 2026-09-18 cold-start correction

The original fresh rows included each scenario's first complete intake run in
the measured samples. That cold run dominated the estimate and produced a
two-standard-deviation spread close to the mean. The benchmark now executes one
fresh run for every mode, chunk size, and metrics setting while constructing the
benchmark tree, before `tasty-bench` starts timing. The measured operation keeps
the same per-invocation record and prepared-event construction, unique stream
identities, 2,000 deliveries, and database path; only the one-time cold database
and runtime path is outside the timed action.

Five serial wall-time process runs produced the refreshed `fresh-warmup-1.csv`
through `fresh-warmup-5.csv` evidence. The committed baseline uses the median
mean and median two-standard-deviation value for each of the nine fresh rows it
already tracked; the evidence covers all fourteen fresh variants. The
single-delivery medians are 718.7 ms table, 551.1 ms delegated, and
562.0 ms direct delegated with metrics off. Their five-run mean ranges are
655.2–743.0 ms, 534.9–582.7 ms, and 534.0–652.9 ms respectively. Historical,
repeated-key, duplicate, and history-depth baseline rows were left byte-identical.

## Stream-length evidence

Confirmed duplicate time is flat across target histories:

| Historical events | Median for 2,000 duplicates | Five-run range |
| ---: | ---: | ---: |
| 10 | 57.7 ms | 55.3–61.1 ms |
| 1,000 | 57.9 ms | 56.2–61.1 ms |
| 100,000 | 59.6 ms | 57.1–61.1 ms |

[`explain-100000.txt`](explain-100000.txt) records `EXPLAIN (ANALYZE,
BUFFERS)`: PostgreSQL uses one `stream_events_pkey` index-only search and does
not scan or hydrate the 100,000-event stream. The small benchmark database chose
a sequential scan of its 16-row `streams` catalog to resolve the stream ID.
Runtime tests separately prove zero command dispatch, append, and inbox access
on a confirmed duplicate.

## Environment and method

- Apple M1 Max, 10 cores, 64 GiB RAM; Darwin 25.6.0 arm64.
- GHC 9.12.4, cabal-install 3.16.1.0, package version 0.16.0.0.
- PostgreSQL 18.6 ephemeral fixture: `fsync=off`,
  `synchronous_commit=off`, `full_page_writes=off`. Both modes use the same
  fixture settings and connection pool.
- Built with Cabal's `-O1` benchmark profile and measured in wall-time mode with
  `+RTS -T`; runs were serial (`-j1` behavior).
- Fixture creation, schema migration, duplicate/history prepopulation, the
  100,000-event history build, and one complete fresh warmup for every scenario
  occur outside the timed benchmark operation. Fresh/repeated scenario record
  construction and prepared-event construction remain inside each measured
  invocation because `tasty-bench` has no per-sample setup hook; their cost is
  identical input setup for the compared modes.
- RTS peak residency is process-wide rather than attributable per benchmark. It
  ranged from 97 to 106 MiB and did not grow with history length. Allocation per
  delivery is the stable scenario-level memory comparison.

Raw evidence is preserved in this directory. `paired-single-*`,
`paired-duplicate-*`, `paired-batch-100-*`, `paired-batch-1000-*`,
`repeated-single-*`, `batch-replay-*`, `history-*`, `direct-solo-*`, and
`wrapper-solo-*` each contain five runs. `table-single-metrics-*` and
`delegated-single-metrics-*` contain the five metrics-on fresh runs.

The unchanged historical inbox benchmarks passed the committed 25% regression
guard immediately before this report: `single-full` was 16% faster,
`single-nometrics` and `batch-100` matched baseline, and `single-slim` was 22%
faster. No historical scenario or baseline value was renamed or refreshed; 34
new measured scenario rows were appended only after that guard passed.
