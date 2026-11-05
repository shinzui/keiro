# Projection feeding-subscription evidence

Plan 327's measured performance acceptance passes. Final application source is
`00fafcd47798e87d0b9c03a71a0eb385ce058471`, compared with
`d64849f19d2d922a5373b121d13d0fac5bc9132f`. Full Nix verification and the
unchanged read-model benchmark guard pass. The frozen relation, complete-list and
lookup SQL, writer/registration paths, schema and CSV baseline remain unchanged.

## Final measurements, 2026-11-05

All eight SQL gates pass; the maximum paired median ratio is 1.0378072 against
the original 1.10 ceiling. Every candidate plan retains 101 SQL look-ahead rows
and ten added parameterized primary-key probes for the ten checkpoint keys.
Append and unmanaged arrays need no lookup, by the existing table constraint.

| Groups | Plan | Page | Baseline median ms | Candidate median ms | Paired median ratio |
| --- | --- | --- | ---: | ---: | ---: |
| 10000 | custom_plan | first | 2.719 | 2.734 | 1.0007 |
| 10000 | custom_plan | deep | 0.530 | 0.545 | 1.0074 |
| 10000 | generic_plan | first | 2.754 | 2.751 | 1.0094 |
| 10000 | generic_plan | deep | 0.533 | 0.543 | 1.0198 |
| 100000 | custom_plan | first | 2.687 | 2.732 | 1.0183 |
| 100000 | custom_plan | deep | 0.552 | 0.563 | 1.0246 |
| 100000 | generic_plan | first | 2.765 | 2.742 | 1.0176 |
| 100000 | generic_plan | deep | 0.548 | 0.561 | 1.0378 |

The fixed full writer cohort contains forty 20-second trials: five alternating
baseline/candidate pairs in each of idle, four HTTP pollers, and four shared feed
subscribers, plus five paired same-source idle controls. Every trial fulfills
100 offered operations/second (at least 99% achieved). Each polling trial completes
its eighty scheduled HTTP requests; feeds receive snapshots and updates with non-empty subscription
arrays, and views/connections/wake pumps return to idle. Durable PostgreSQL
settings remain enabled. No poll/feed throughput, latency or writer-allocation
comparison shows statistically supported degradation.

The full cohort flagged idle p95: median ratio 1.00714875, CI95
1.00339121–1.09613147. Idle does not execute the changed query or encoder. A
predeclared follow-up ran exactly five additional idle pairs with reversed order,
retained all samples and evaluated all four writer metrics. The idle p95 signal
did not reproduce: replication ratio 1.00027049, CI95 0.98700255–1.01902064.
The combined ten-pair p95 ratio is 1.00351648, CI95 0.99503648–1.01902064.
All ten idle pairs are included; no trial was replaced. In total, fifty trials
and 100,000 writer operations pass raw-record, offered-load and cleanup checks.
The final matched assessment shows no statistically supported candidate degradation.

| Mode | Pairs | p95 ratio (95% interval) | p99 ratio (95% interval) |
| --- | ---: | --- | --- |
| idle | 10 | 1.0035 (0.9950–1.0190) | 1.0097 (0.9683–1.0352) |
| poll | 5 | 1.0117 (0.6478–1.0155) | 1.0743 (0.8808–1.0770) |
| feed | 5 | 0.9878 (0.9495–1.0034) | 0.9816 (0.9594–1.0140) |

`2026-11-05/assessment.json` retains discovery, replication and combined ratios
for all four idle metrics, alongside the original full-cohort report. Higher
ratios mean worse performance (throughput ratios are inverted). Intervals use
seed 327 and 20,000 trial-pair median bootstrap resamples, with the actual number
of pairs in each report. This finite experiment does not establish zero loss or
1% equivalence; the intervals show its uncertainty.

The user explicitly instructed on 2026-11-05 that full machine quiet is unnecessary.
Process observations remain context, not a gate. The implementer also withdrew
an unapproved added requirement for 1% confidence resolution. The original strict
analyzer and its false precision result are preserved unchanged; no raw data,
SQL ceiling or committed benchmark baseline was adjusted. The original discovery
idle flag remains visible. Its fixed replication and combined estimate, rather
than repeated trials until a favorable result, supply the final idle assessment.

## Audit and reproduction

`evaluate-20261105.py` recomputes every raw p95/p99 and writer allocation mean,
checks all fifty offered-load/client/cleanup/settings records, replays the original
full-cohort analysis byte-for-byte, and computes the predeclared idle replication.
Its acceptance receipt separates measured findings from the withdrawn added gates.
The retained evaluator's binary-hash audit uses the original local binary paths;
when reproducing elsewhere, rebuild the recorded source and update local paths.

```bash
nix develop -c python3 keiro/bench/results/inspection/projection-status-feeding-subscriptions/evaluate-20261105.py keiro/bench/results/inspection/projection-status-feeding-subscriptions/2026-11-05
nix develop -c just bench-regression read-model
```

The original full-cohort analyzer still exits nonzero for its precision diagnostic:

```bash
nix develop -c python3 scripts/analyze-projection-feeding-subscriptions.py keiro/bench/results/inspection/projection-status-feeding-subscriptions/2026-11-05/writer
```

Use a new output directory for new measurements and separately compiled, identical
sources against both package sets. `scripts/measure-projection-feeding-subscriptions.sh`
is the fixed full controller; `2026-11-05/idle-replication-controller.sh.txt` records
the reversed-order follow-up and `sql-controller.sh.txt` records the three SQL pairs.
`run-quiet.py --diagnostic` can retain process context while allowing background
activity; its nonzero overlap status is not the acceptance decision.

Apple M5 Ultra, 36 cores, 256 GiB RAM; Darwin 27.2.0; GHC 9.12.4;
PostgreSQL 18.6; Python 3.14.7; Z3 4.16.0. `identity.json` records source commits,
binary SHA-256, exact flags, RTS `-N2 -T`, and 311 matching external package unit
identities. The SQL driver uses O2; libraries and interference harness use O1.
Benchmarks create private durable ephemeral PostgreSQL clusters through
`Keiro.Test.Postgres.withMigratedBenchmarkSuite`; setup is outside timing.
The shell cluster is used separately for the executable jitsurei demonstration.

Fixtures have 10k/100k projection groups, three models per group, a ten-percent
checkpoint stripe with a non-empty name, plus 10k extra models on the first group
for SQL. Both forced plan modes and first/deep pages retain five SQL samples per
shape per binary in each of three alternating pairs. The writer harness also seeds
100k workflows and timers and uses the existing durable schedule/claim/resume/timer
operation. All sources, raw samples, dependencies and bootstrap scripts are retained.

## Behavior, verification and history

`jitsurei-cli.json` and `jitsurei-http.json` agree: reporting names
`jitsurei-order-audit-subscription`; the legacy area-chapters group has `[]`.
`compatibility.txt` records the unchanged frozen definitions and all eighteen
original JSON pair expressions. `read-model-guard.log` records all ten guard cases
passing with the original CSV; `verify.log` is the passing full final-source Nix
verification. Strict IR closure validation passes (60 concepts). A redundant full repeat was
stopped at the user's request and retained as `2026-11-05/verification-repeat-interrupted.log`
with exit 130; it is not a second passing run. The earlier passing full verification
remains applicable because application and DSL source are unchanged.
ADR-35 records the durable query and interface decisions.

`report-before-20261105.md`, root `evaluation.json`, root `interference/`, and
`loaded-*` directories are historical reports, including unsuccessful diagnostics
and earlier query/encoder candidates; each retains its source/binary identity.
The 2026-11-05 interrupted run and refused preflights are retained as history and
are not substituted into the fixed fifty-trial assessment. `manifest.json` hashes
every retained artifact except itself. Compiled binaries remain local.
