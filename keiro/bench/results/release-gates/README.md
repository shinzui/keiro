# Release-gate evidence

Plan 316 is accepted by two uninterrupted `nix develop -c just release-gate` runs at
`a4332cfe` on 2026-10-25. Both start from the same committed implementation, after
plan 315 completion, with Z3 4.16.0 verified in the Nix shell. Correctness runs first;
all six guards run afterward. No separate correctness and benchmark logs are spliced.

| Run | Combined log | Correctness | Benchmark | Recipe exit |
|---|---|---:|---:|---:|
| Deliberate refusal | [10:18 UTC](20261025T101845Z-a4332cfe.log) | 0 | 1 | 1 |
| Accepted green | [10:43 UTC](20261025T104300Z-a4332cfe.log) | 0 | 0 | 0 |

`negative-control.sh` requires a clean tracked tree, backs up the accepted command CSV,
changes only `All.command.legacy.accepted-1` to a 1-ps mean/zero spread, and records the
exact change in `negative-control.patch`. Correctness passes. Only command fails;
producer-identity, outbox, inbox, projection and read-model pass. The runner continues
after command and the release recipe refuses with `VERIFY_EXIT=0`, `BENCH_EXIT=1` and
process exit 1. `negative-control.txt` retains that process status beside the combined
log. `negative-control-source.txt` records the initial source/binary/lock identity.
The script checks every status and restores the exact accepted CSV on every exit;
the deliberate perturbation is not part of the committed baseline.

`positive-control.sh` then runs the complete gate on the restored tree at the same HEAD.
`green-control.txt` contains both zero exit lines, all six zero guard statuses,
`BENCH_REGRESSION=PASSED` and `PROCESS_EXIT=0`. It finishes at 11:05:22 UTC.
`green-source.txt` retains source, binary, lock and all five baseline hashes, Z3 and load.
`green-benchmark-processes.txt` snapshots benchmark-time activity without process arguments:
there is no competing compiler or solver; normal background PostgreSQL activity is retained.
The full gate includes library/retention/ops/HTTP/conformance suites, 884 DSL examples,
strict documentation/policy checks, mutation/compatibility proofs and migration tests.

The benchmark binary hash also matches all three accepted plan 315 control runs.
The final completion commit adds evidence and plan/ADR documentation; it does not change
the tested implementation or numerical baselines. A later release candidate with code or
version changes still needs its own final-candidate gate through plan 303. The accepted
[five-sample recordings and three full controls](../baseline-recording-v2/README.md),
[producer attribution and added-cost refusal](../producer-attribution-v2/README.md), and
[isolated harness evidence](../harness-isolation-v1/README.md) remain separate prerequisites.

## Historical exploratory run

`20261025T053433Z-847b395c.log` ran the earlier gate on clean `847b395c`. Correctness passed
and every guard ran, but producer/projection failed. External test/solver activity and wide
producer spreads made its timings exploratory. It demonstrates the original mechanical
refusal, not quiet-machine acceptance. The accepted later red/green cohort above replaces
it for plan 316 acceptance while retaining the historical evidence.
