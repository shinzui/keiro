# Workflow status counts: query and runtime evidence

The exact read fits the 2,000 ms statement limit. The original index-backed
criterion failed for both shapes. After reviewing these measurements, the user
approved normal planner-selected scans conditional on **no schema changes**.
M1 is accepted under that decision, and the simpler single-scan query is selected.
The library, CLI and HTTP contract now pass focused tests and read-only Jitsurei
comparisons. The [final matched runtime cohort](runtime-serial/README.md) and
[all six existing benchmark guards](benchmark-guards.log) pass. The measured
envelope is one million balanced-class headers, 210 writer operations/sec,
one unfiltered poll/sec and the tested eight-client aligned overload mixture.
The inspection pool disables parallel-query fan-out while preserving four
admitted reads and the existing two/five-second deadlines. Ordinary writer
connections, schema and migrations are unchanged. Earlier interrupted and
failed runs remain in `runtime/` and `runtime-paired/`; the final run continued
on the available machine as directed by the user.

The clean starting revision is `9a54e48030ed3080f79a84d3364ea2dd74d0ab39`.
[manifest.json](manifest.json) records the command, source hashes, build-plan
hash, and expected nonzero exit. [environment.txt](environment.txt) records
GHC 9.12.4, Cabal 3.16.1.0 and the ARM Mac hardware. Libraries use Cabal's
existing `-O1` build; the experiment driver runs through `runghc`. Both shapes
run serially on the same disposable durable PostgreSQL 18.6 fixtures. No builds,
tests, or other repository benchmarks ran during measured query execution.

## Results

[query-summary.json](query-summary.json) summarizes all 648 size/distribution/
table-state/plan-mode/shape/filter cases. Every result equals the independent
Haskell `statusClassOf` totals from a complete 500-row-page list drain of the
same unchanged fixture. Each case retains its first timed read and five warmed
reads, separately from EXPLAIN. All completed within 2,000 ms. The original cohort exited
**1** under its original index-plan criterion, after retaining all results; the
current driver accepts planner-selected scans under the recorded user decision.

Across all 108 million-row cases per shape, the single-scan candidate's largest
first read was 105.851 ms and largest warmed read 102.445 ms. The selective
prototype's corresponding maxima were 128.031 ms and 130.473 ms. These are
read-cost measurements, not proof of zero interference with runtime writers.

The following are median warmed unfiltered timings with automatic prepared-plan
selection; the raw five samples and first reads are in `query/`.

| Distribution | Table state | Single scan (ms) | Selective (ms) | Selective uses sequential scan |
| --- | --- | ---: | ---: | --- |
| balanced | maintained | 57.40 | 36.50 | no |
| balanced | recently updated | 71.85 | 120.19 | no |
| 99% terminal | maintained | 42.38 | 22.68 | no |
| 99% terminal | recently updated | 45.60 | 53.17 | no |
| 99% active | maintained | 67.66 | 40.97 | yes |
| 99% active | recently updated | 52.94 | 66.20 | yes |

The single-scan candidate has a sequential scan in 72 of its 108 million-row
cases. The selective prototype has one in six: the unfiltered 99%-active table,
both maintained and recently updated, in automatic/custom/generic modes. The
running/retrying aggregate is the sequential-scan branch. Its suspended and
terminal branches still use existing indexes. The selective shape uses existing
indexes in all the measured name-filtered cases. These are normal planner
choices: no scan type was disabled. The fixture's existing SSD setting
`random_page_cost=1` is visible in every relevant EXPLAIN SETTINGS result;
this is not a claim about PostgreSQL's default cost setting of 4.
[query/index-failures.json](query/index-failures.json) enumerates the failures.

The concrete alternative is the simpler single-scan owner read already in the
prototype: exact, bounded by the existing timeout, and without schema changes.
The user approved planner-selected sequential scans and plan 325/IR-58 now
record that change. M2 transport checks and final M3 matched runtime measurements pass. Adding an index or
writer-maintained summary has not been authorized or attempted.

## Workload and reproducibility

From the repository root, inside the Nix development shell, build the libraries
and run the evidence driver into a new directory (existing evidence is never
overwritten):

```bash
nix develop -c cabal build keiro keiro-test-support --enable-tests --enable-benchmarks
nix develop -c cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support scripts/workflow-counts-query-evidence.hs keiro/bench/results/workflow-counts/query-new
```

The original cohort exited 1 when both shapes contained a sequential scan in a
required million-row case. That original index diagnostic is retained; the
current driver accepts those scans under the recorded user scope decision. A correctness or timeout error fails immediately. Optional
numeric sizes after the output path support a small smoke test, explicitly
labelled incomplete when it omits one million rows.

The driver uses `Keiro.Test.Postgres.withMigratedBenchmarkSuite` and uniquely
cloned disposable databases, with fsync, synchronous commit, full-page writes,
and autovacuum enabled. No existing developer database is read or changed.
Fixtures have 10,000, 100,000 or 1,000,000 current headers; balanced seven-class,
99%-terminal, and 99%-active populations; roughly 90% dominant-name headers;
rare, absent and literal Unicode/quote/backslash/wildcard name selections; a
2,700-character name; and a valid 2,600-byte incompressible workflow id.
Retries include negative stored attempts. Only status, attempts and wake time
classify a row. The recently updated state flips attempts and wake time in
roughly 10% of headers without manually vacuuming afterward. The maintained
state has one VACUUM ANALYZE before measurement. Autovacuum stays enabled.

Each artifact retains server settings and index definitions, actual prepared
statement text, exact totals, plan-cache counters, and full EXPLAIN ANALYZE /
BUFFERS / SETTINGS JSON, including examined/removed rows, heap fetches, shared
buffers and temporary blocks. There was no temporary spill. Automatic mode
is followed through repeated executions; forced custom and generic modes are
also retained. The first read follows fixture setup and is **not OS-cold**;
this machine has 256 GiB RAM and the dataset fits in its OS cache. PostgreSQL's
fixture shared buffers are 12 MB and work_mem is 4 MB.

The single-scan SQL is discovered after calling the actual owner API on the
same one-connection store. The alternative groups the actual candidate FILTER
expressions into five status-selective aggregates: running/retrying together,
sleeping/awaiting together, and three terminal aggregates. Both use a separate
bound-name shape rather than a nullable OR or interpolated user input. No
persistent state is added by either shape.

[list-sql-identity.json](list-sql-identity.json) retains all 68 before/after
prepared list SQL comparisons, including exact text and equal SHA-256 hashes.
They were obtained with `scripts/inspection-query-evidence.hs` before and after
factoring the inspection-only classification helper. Thus the retained Plan 317
list SQL remains byte-identical.

Focused validation passed:

```bash
nix develop -c cabal test keiro-test --test-options='-m Keiro.Workflow.Inspection' --test-show-details=direct
```

Result: 19 examples, zero failures, including empty/unknown names, all seven
classes beyond a first page, negative retry attempts, exact special names,
ignored lease/retry clocks and changed classes after updates. DSL conformance
and the combined release gate were excluded per the user's requested scope.
M2 validation subsequently passed 20 owner, 58 ops and 58 HTTP examples.
[jitsurei.txt](jitsurei.txt) retains exact full-paging comparisons on the existing
quiescent demo database: all names (two completed), order-fulfillment (one
completed), and an absent name (seven zeroes). No demo data or schema was changed.
The M3 harness is the same in the recorded original baseline and candidate source
trees; frozen binaries are outside the checkout and their hashes/build identities
are retained in `binaries/`. The overload smoke test completed eight successful
count reads and eight admission refusals, followed by successful recovery.

## Final operating envelope and reproduction

The final cohort has forty complete legs: five alternating baseline/candidate
capacity pairs and five paced six-leg blocks. It contains 100 successful
single-client reads and 400 successful burst reads, 400 expected admission
refusals, and successful recovery after every polling leg. Throughput and
writer-thread allocation show no attributable regression; active-count paired
median p95 changes were -2.677% and -2.683% against mounted-idle controls. Raw
pair ranges and the small mixed-sign capacity/idle changes are retained in
`runtime-serial/comparisons.json`; they are not presented as a universal
zero-cost guarantee or as proof that polling improves writer speed.

All six guards returned zero in `benchmark-guards.log`. They ran serially after
the matched cohort, using the retained baseline dependency constraints. The
combined release gate and DSL conformance were excluded per user instructions.
Strict user, guide, ADR and improvement-request bundle checks also pass.

Frozen binaries remain outside the checkout. `binaries/baseline.json` and
`binaries/candidate.json` bind their hashes, compiler/optimization and source
patches. Source patches use zero context; reconstruct on their recorded base
with `git apply --unidiff-zero`. The original candidate and failed burst behavior
are preserved separately as `candidate-v1.*`. Retained dependency constraints
preserve the baseline's exact shared dependency unit identities during rebuilds;
no project dependency bounds or published pins changed.

```bash
nix develop -c bash scripts/measure-workflow-counts.sh /Users/shinzui/.cache/keiro/workflow-counts-20261105/baseline /Users/shinzui/.cache/keiro/workflow-counts-20261105/candidate-serial NEW_OUTPUT_DIRECTORY
nix develop -c python3 scripts/analyze-workflow-counts.py --self-test
nix develop -c python3 scripts/analyze-workflow-counts.py keiro/bench/results/workflow-counts/runtime-serial
```

The controller refuses to overwrite evidence. It records ambient activity and
judges paired results; merely observing another process never rejects a run.
SQL, dataset, cadence, duration, numerical limits and existing baselines were
not loosened to obtain acceptance. The actual burst-latency failure was fixed
by bounding inspection-only parallelism, without adding schema or writer work.

Benchmark `.log` files match ignore rules on this checkout; retain future cohorts
with an explicit `git add -f` for those logs. JSON, text summaries and source
patches are retained normally.
