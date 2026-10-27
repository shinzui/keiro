# Release-gate evidence

## Resumable release evidence (plan 326)

`just release-gate` now runs mandatory preflight followed by correctness and all
six guards. Correctness failure stops before any guard. Stage receipts (`*-<stage>.json`)
record command, input identity, status, timestamps, initial load and log checksum.
`*-manifest.json` references the original receipts and their checksums; original
logs remain separate. `accepted: true` requires all seven stages to pass.

Retries reuse only successful matching evidence less than 24 hours old. The
identity includes tracked source bytes/modes, resolved plan, compiler, relevant
environment, local Cabal configuration and PostgreSQL server/settings. Only this
evidence directory and Markdown ExecPlan and MasterPlan documents are excluded from source identity.
Other documentation and non-Markdown files in plan directories invalidate reuse. Preflight always
reruns. A newer failure or interrupted attempt supersedes an old pass; missing,
stale or modified logs refuse reuse. `just release-gate --fresh` runs every stage.
This replaces the old uninterrupted combined-log restriction, not any numerical
guard, baseline or workload rule in [ADR-58](../../../../docs/adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md).

Commit the accepted manifest **and every referenced receipt and log**. Before
publication, `just release-ready <manifest>` also checks all sixteen archive
checksums and the current staged-consumer proof. Archive and consumer commands
only prepare/verify local files; they do not upload or create tags. See the
[release skill](../../../../agents/skills/release/SKILL.md) for the complete sequence.

The historical evidence below remains valid under its original policy and is
not automatically imported into the new receipt format.

### Plan 326 acceptance

The workflow is accepted at tested source `522fd54c`. The
[summary and timings](workflow-326/summary.json) bind the exact source identity and
stage references. [Full correctness and five guards](20261027T202041Z-905fb443-manifest.json)
passed in the 27-minute attempt, while three inbox cases failed at 63–66 percent over
baseline. That attempt is retained as **refused**, never as acceptance.
The [accepted resumed manifest](20261027T204838Z-dbae5693-manifest.json) reuses six stages
and reruns the full inbox guard, which passes with the affected cases at 385–397 ms.
It completes in 184.432 seconds without any source or baseline change.
The [fully cached manifest](20261027T205643Z-f7d2d374-manifest.json) then reuses all seven
stages across a new Nix shell in 67.552 seconds. Both manifests reference the original
receipt/log files rather than a synthetic combined transcript.

[Twenty-seven controls](workflow-326/unit-controls.log),
[native Nix checks](workflow-326/native-nix.log),
[archive checksums](workflow-326/artifacts.json),
[staged](workflow-326/staged/result.json) and
[published](workflow-326/published/result.json) consumer results, and
[readiness](workflow-326/ready.log) all pass. Both consumers check all eight exact-version
packages and healthy HTTP responses against disposable migrated databases.
The package version 0.22.0.0 is a fixture for this workflow acceptance; no new release
was cut. Earlier interrupted development work, command guard failures and metadata
transport refusals remain diagnostic evidence in `workflow-326/` and the stage logs.
The metadata retry fix recovered a real truncated response without accepting partial JSON.

## Keiro 0.22.0.0

The final candidate at `b2be482b` passes the complete
[release gate](20261027T174942Z-b2be482b.log): `VERIFY_EXIT=0`, all six `GUARD(name)=0`
statuses, `BENCH_REGRESSION=PASSED`, and `BENCH_EXIT=0`.
The release commit adds retained evidence after testing; implementation, package
versions, corpus provenance, and generated inventories are unchanged from that
tested candidate. Native Nix checks and all eight package checks also pass.
The PGMQ suite retains two pre-existing optional pending checks.

The user explicitly authorized concurrent adapter performance work. Numerical
ceilings and committed baselines are unchanged. The three earlier logs are failed
preparation attempts, not acceptance: `20261027T162850Z-d106a92c.log` stopped at
an unavailable registry and was interrupted during overlapping documentation
builds; `20261027T165947Z-d106a92c.log` stopped at stale generated inventory and
was interrupted before completing benchmarks. The inventories were regenerated
and the full remaining policy set passed. `20261027T172118Z-b2be482b.log` passed
all correctness checks and five guards, with one inbox case at 2.48 ms (27% over
baseline, against a 25% ceiling). The separate
[inbox rerun](0.22.0.0-inbox-retry.log) passed all 49 cases; that case measured
1.97 ms, effectively matching baseline. This final combined run is the accepted
gate; earlier failures and the retry remain visible.

[Additional checks](0.22.0.0-checks.txt),
[dependency publication audit](0.22.0.0-dependencies.txt), and
[archive checksums](0.22.0.0-artifacts.json) retain the release preparation evidence.

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
