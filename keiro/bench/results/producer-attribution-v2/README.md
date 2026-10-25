# Fresh producer attribution

Plan 315 follows the accepted isolated/checkpoint-settled harness from plan 321.
The full normal benchmark actions and 1.10 ceiling are retained. The guard estimator
now uses 15 alternating full-workload pairs rather than two sequential adaptive means.
The probe source is `fb241994` plus `source.patch`; `environment.txt` identifies the
built executable and environment. Invoke it inside `nix develop` with
`KEIRO_BENCH_PRODUCER_PROBE=1`, the built `keiro-bench` binary and `+RTS -N2 -RTS`.
`probe-2.jsonl` completed with exit zero and empty stderr. `probe-1` is the earlier
count/same-input experiment, before adding the native-identity input comparison.

Counters query session-local `pg_prepared_statements` before/after actual library calls in
the same transaction. Classification happens in Haskell, so the observation query cannot
match itself. PostgreSQL reports generic/custom plan choices in its
[prepared-statement view](https://www.postgresql.org/docs/18/view-pg-prepared-statements.html).
The matching 1,000 calls choose 1,000 producer insert plans and zero locked lookups on fresh
success. Identical replay chooses 1,000 attempted inserts and 1,000 locked lookups. Legacy
inserts choose 1,000 legacy plans. These are enqueue-statement families; transaction control,
reset and observation queries are separate. Every phase checks the retained 1,000 rows.

Preparation estimates use the actual legacy generators and equivalent deterministic dynamic
assembly, forcing identifiers, timestamp, provenance and payload handles. The equivalent
assembly is checked against all 1,000 envelopes and identities stored by the actual public
factory before timing. It estimates dynamic preparation rather than claiming to call a
private factory in isolation. The existing `derive-v1` benchmark independently forces both
identifiers. SQL phases hold prepared inputs constant, alternate order across five pairs,
and cover a single transaction and one transaction per event. Identical-input comparisons
isolate insert/encoding/result work; native-layout comparisons preserve each path's actual
UUID/message-ID shape. Assertions require every deterministic enqueue to be fresh.

`summary.md` reports medians and preparation ranges. Prepared SQL timings include the Hasql/
transaction wrapper and encoding; they exclude the preceding TRUNCATE. Full normal guard
timings retain their reset and actual preparation boundaries. The settled producer reset
probe is separately about 1.4 ms per 1,000-row batch; a common additive reset does not cancel
from a ratio. These separately sampled phases must not be summed into an exact full-path
budget. Conflict lookup/comparison cost cannot justify a fresh-path allowance, and ADR-42
provides no millisecond allowance. No threshold or quantity is replaced by this investigation.

`precision-guard.txt` records the normal one-percent/120-second guard at committed
source `b8695a0d`: all six cases passed, batch fresh 1.05× legacy and per-event fresh
0.96×, with `GUARD(producer-identity)=0` and process exit zero. The first two complete controls pass at 1.09×/1.08× batch. The third fails at
46.6/42.2 ms (>1.10×), with the other five guards passing. That failure remains in
`../baseline-recording-v2/control-full-3.txt`; the three-pass acceptance is not met.
Actual full-factory alternating pairs will extend attribution. No ceiling has moved.

`probe-3.jsonl` adds 15 alternating actual full-workload pairs per transaction shape;
`full-factory-source.patch` applies to `dfa9944c`, and `full-factory-environment.txt`
records its executable. All 113 records completed with process exit zero and empty stderr.
`analyze-full.py` validates every pair and retained row count; `full-factory-summary.md`
reports batch median ratio 1.0496 (range 1.0202–1.1101), per-event 0.9706 (range
0.9155–3.1692). The large individual per-event pause remains in the data. Separate
component estimates do not predict an exact full-path budget.

The guard retains its 1.10 ceiling and full workload, but now enforces the median of
15 adjacent full-workload ratios, alternating order by sample. It emits every raw pair
and the median, checks 1,000 retained rows after each action and never repeats samples
until green. This replaces comparison of sequential adaptive means: the accepted source
varied from 1.05 to just above 1.10 even with small individual reported spreads, while
actual paired data separates typical fresh overhead from occasional pauses. Ordinary
six benchmark names and standalone timing actions remain available. Paired measurements
are selected only for the two fresh comparisons and add fixed diagnostic work to those
cases; other groups' workload setup and all five CSVs are unaffected.

The known same-input statement difference is about 7.3% for batch SQL; each path's native
identity layout measures about 9.1%. Production handles either unique identity through
untargeted `ON CONFLICT DO NOTHING`, whereas the legacy helper targets `(source,message_id)`
and discards row results. PostgreSQL [documents the arbiter scope](https://www.postgresql.org/docs/18/sql-insert.html).
Those controlled SQL measurements include encoding/results and do not isolate each index
or identifier byte individually. The actual full paired batch overhead is about 5%, giving
about five percentage points to the existing ceiling; per-event median is below legacy.
No conflict-read cost or ADR-backed absolute allowance is asserted.

`negative-control.sh` temporarily adds 20 ms to each deterministic 1,000-event action,
records the exact source patch and executable, runs the real producer guard, requires both
paired medians to exceed 1.10 and restores/rebuilds the original source. This adds roughly
47% of the observed legacy batch and 26% of legacy per-event cost, beyond the measured
headroom. `negative-control.txt` refuses both shapes at 1.6060× batch and 1.2401× per-event,
returns `GUARD(producer-identity)=1`/process 1, and retains all raw pairs. The source
patch, negative executable hash and successful restored build are retained. The script
completes with `PRODUCER_NEGATIVE_CONTROL=PASSED` at clean source `4f2b4b69`.
Three restored full six-guard runs pass at the same source/binary/baseline set:
`../baseline-recording-v2/accepted-full-1.txt` through `accepted-full-3.txt`.
Batch medians are 1.0568×/1.0618×/1.0593× and every per-event median is below legacy.
Each full process exits zero. This accepts the producer policy and three-pass obligation;
the full correctness-plus-performance release-gate demonstration belongs to plan 316.
