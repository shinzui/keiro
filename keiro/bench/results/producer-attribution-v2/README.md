# Fresh producer attribution

Plan 315 follows the accepted isolated/checkpoint-settled harness from plan 321.
The normal benchmark actions, selected warm-up and 1.10 ceilings are unchanged.
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
