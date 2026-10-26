---
id: 325
slug: count-workflow-instances-by-status-class-without-runtime-performance-regressions
title: "Count workflow instances by status class without runtime performance regressions"
kind: exec-plan
created_at: 2026-10-26T19:30:48Z
intention: "intention_01m5wv1274eyxtzm8gz20xhpea"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-26T19:30:48Z
---

# Count workflow instances by status class without runtime performance regressions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


An operator can run `keiro-ops wf inspect counts --json`, optionally with
`--workflow-name NAME`, or request `GET /wf/inspect/counts?workflow_name=NAME`, to
obtain exact current instance counts for all seven workflow status classes. This
implements [IR-58](../improvement-requests/count-workflow-instances-by-status-class.md).
The console can replace its newest-500-row lower bounds with one observation.
The response contains `observed_at` and a `counts` object with `running`,
`retrying`, `sleeping`, `awaiting`, `completed`, `cancelled`, and `failed` integer
fields, including zero-valued fields.

The user's additional requirement is to introduce no performance regressions.
Delivering the endpoint is conditional on measured read cost and ordinary runtime
isolation. First prove the requested index-backed aggregate can finish on one
million instances within the existing 2,000 ms statement timeout. Do not solve
that requirement by silently taxing workflow writes, increasing timeouts, serving
estimates, or weakening the acceptance criteria. A bounded feasibility milestone
comes before transport work because the present schema does not have a covering
index for this query.


## Progress


- [ ] M1: A prototype owner read returns exact counts and retained normal-planner evidence establishes the million-instance timeout and index-backed acceptance without changing runtime writes or schema.
- [ ] M2: The supported library API, CLI command, and mechanically derived HTTP route agree on all seven counts, filtering, observation semantics, and existing resource limits.
- [ ] M3: Matched capacity and active-polling measurements establish no attributable runtime regression; the final candidate passes the existing release gate and documents the measured operating envelope.


## Surprises & Discoveries



## Decision Log


- Decision: Count current instance headers in one database statement using existing indexes first; keep ordinary writes, schema, and migrations unchanged.
  Rationale: Earlier inspection columns/indexes caused a measured 9.22% writer-capacity loss. Exact counts and the user's no-regression constraint must both hold. If M1 cannot meet the requested index-backed and timeout criteria, retain the evidence and obtain a concrete design/scope decision before adding persistent writer maintenance or relaxing the request.
  Date: 2026-10-26
- Decision: All seven counts and the database observation clock come from one statement, without cached totals or seven independent reads.
  Rationale: A result must describe one database snapshot, including an empty table, while doing no history replay or client-side page draining. Ordinary list pages do not share a snapshot across requests.
  Date: 2026-10-26
- Decision: Make performance evidence a prerequisite for completion, including unpaced writer capacity and polling through the actual HTTP application.
  Rationale: A paced test can hide lost writer headroom; a fast isolated SQL query can still interfere with workers. Existing 5% interference guards are rejection ceilings, not permission to introduce a smaller reproducible regression.
  Date: 2026-10-26


## Outcomes & Retrospective



## Context and Orientation


Keiro is a Haskell library backed by PostgreSQL. Each current workflow instance
has one header in `keiro.keiro_workflows`; previous generations are journal history,
not additional instances to count. `keiro/src/Keiro/Workflow/Inspection.hs` exposes
`listWorkflowInstancesPage`, `statusClassOf`, and the canonical JSON encoders.
`keiro/src/Keiro/Workflow/Inspection/Query.hs` owns `WorkflowStatusClass` and list
query records. `keiro/src/Keiro/Workflow/Instance.hs` owns SQL and decoders; its
`inspectionInstanceStatement` has an inspection-only `classPredicate` helper.

The classes partition stored headers: `status = 'running'` with `attempts = 0`
is running, and any nonzero attempts is retrying; suspended with non-null
`wake_after` is sleeping, and suspended with null `wake_after` is awaiting.
Completed, cancelled, and failed map directly from stored status. Due dates,
lease ownership, `next_attempt_at`, and current wall time do not alter that
classification. Preserve `attempts <> 0`, rather than substituting `> 0`.

`keiro-migrations/migrations/0011-keiro-workflows-instances.sql` introduced the
table. The current snapshot, `keiro-migrations/expected-schema/native/keiro-v18.txt`,
has the `(workflow_id, workflow_name)` primary key, the active partial index
`keiro_workflows_active_idx` on `(status, wake_after)` for running/suspended rows,
and `keiro_workflows_gc_idx` on `(status, completed_at)`. None covers all of status,
attempts, wake time, and optional workflow name. A covering index stores every
column a query needs; even an index-only scan may visit the table to check
visibility after updates. An exact count still scans its qualifying population;
a fixed-size response is not constant-time database work. These constraints are
documented by PostgreSQL's [aggregate reference](https://www.postgresql.org/docs/18/functions-aggregate.html)
and [index-only scan reference](https://www.postgresql.org/docs/18/indexes-index-only-scans.html).

[Plan 317](317-bound-the-workflow-listing-cost-without-the-withdrawn-inspection-indexes.md)
changed unfiltered listing to primary-key order; only that unfiltered traversal
has page-proportional search cost. Its current implementation and evidence are
the baseline, not its historical description of the withdrawn wide-key design.
The rejected schema experiment is retained in
`keiro/bench/results/inspection/composed-writer-capacity-final/README.md`:
unmounted writer capacity fell 9.22% and p95 latency rose 12.91%, although a paced
100-operation/second test had hidden the loss. Preserve the unrestricted valid
workflow-name/key domain, including wide text.

`keiro-ops/src/Keiro/Ops/Workflow.hs` owns `InspectionCommand`, parsing,
`validateCommand`, `isMutation`, and `runInspection`. `keiro-ops-http/src/Keiro/Ops/Http/Route.hs`
translates path words and snake_case query options through that command parser;
it does not need a new route table. `keiro-ops-http/src/Keiro/Ops/Http/Application.hs`
owns schema verification and execution through the shared admission budget.
`keiro-ops-http/src/Keiro/Ops/Http/Config.hs` defaults to four admitted requests,
a five-second read deadline, a two-second SQL timeout, and a one-MiB response cap.
`keiro-ops-http/src/Keiro/Ops/Http/Pool.hs` applies the SQL timeout to every
connection in the dedicated inspection pool. Direct library and CLI callers
remain responsible for their connection/statement deadline policy; do not change
a shared runtime connection's settings inside the read.

Relevant decisions consulted are [ADR-23](../adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md),
which makes the instance row the wake ledger and protects exact discovery;
[ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md),
which requires supported owner APIs beneath operator commands;
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md),
which requires bounded inspection and measured runtime isolation;
[ADR-53](../adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md),
which requires shared CLI/HTTP grammar, live schema checks, and uniform budgets;
and [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md),
which requires isolated, fixed workloads and attributed baseline evidence.
No additional cross-repository ADR is needed. The consumer request originates
from `mori://shinzui/keiro-ui/plans/17-build-the-projections-and-overview-screens`;
changing that UI is outside this plan.


## Plan of Work


### M1 — Prove the owner read and its cost before exposing it


Capture the pre-implementation source revision, uncommitted source diff if any,
dependency/build settings, and frozen baseline binary before editing runtime code.
First prepare the measurement-only harness additions described in M3; they use
HTTP URLs and existing writer APIs, so they can compile before the new count API
exists. Freeze that binary against unchanged production code, then retain the
same harness for the candidate. If the workload changes later, rebuild both
controls from their recorded sources. Preserve unrelated work already in this
checkout. Create the proposed types below
in `keiro/src/Keiro/Workflow/Inspection/Query.hs`, re-export them through
`keiro/src/Keiro/Workflow/Inspection.hs`, and prototype
`inspectionInstanceCounts` in `keiro/src/Keiro/Workflow/Instance.hs`.
Keep the dependency direction from the instance module to the small query module.

Compare two read-only statement shapes using the same predicates: a single scan
with seven `count(*) FILTER (WHERE ...)` aggregates, and one statement combining
status-selective aggregate subqueries, using existing status indexes where the
normal planner chooses them. In the latter shape, count running/retrying together
and sleeping/awaiting together, rather than rescanning those populations once
per class. Terminal counts can use the existing status/completion index. Both
shapes return one row containing `now()` and seven non-null `bigint` values. Use
separate prepared shapes for no name filter and a bound exact-name filter;
never interpolate user text or hide the absent filter behind a nullable OR.
Factor the SQL classification helper for list/count reuse without changing list
SQL semantics or moving classification onto writer paths. The independent Haskell
`statusClassOf` remains the parity oracle.

Add `scripts/workflow-counts-query-evidence.hs`, following the disposable fixtures
and prepared-statement discovery in `scripts/inspection-query-evidence.hs`.
Mark the actual production candidate SQL with `/* keiro-inspection-counts-v1 */`.
Explain that prepared statement on the same connection, rather than explaining
a separately retyped approximation. Test 10,000, 100,000, and 1,000,000 instances
with balanced classes, 99% terminal rows, and 99% active rows; include running
retry churn and suspended wake-time changes. Test unfiltered, dominant-name,
rare-name, absent-name, Unicode/literal-special-character names, and valid wide
keys. Name filtering is exact equality, never a wildcard pattern. Retain custom,
generic, and default automatic prepared-plan results, including repeated execution
after automatic plan selection. Record execution time, rows examined, rows removed,
heap fetches, shared buffers, temporary spill, and exact totals.

Measure both a stable maintained table and a recently updated table without
artificially vacuuming between every update and read. Record the first measured
read separately from warmed repetitions; do not describe it as an OS-cold test
without actually establishing that condition. Normal durability and autovacuum
stay enabled. Execute the supported read with `statement_timeout = '2000ms'` on
its dedicated fixture connection, and retain at least five timed repetitions
per million-row case separately from EXPLAIN overhead.

M1 passes when the prototype's counts equal a complete list drain on unchanged
fixtures and the required million-row cases complete within the timeout with
normal-planner evidence supporting the request's index-backed aggregate. Do not
force index selection by disabling sequential scans. If the planner instead
chooses table scans, report precisely which cases do so; fast table scans alone
do not discharge the index-backed criterion. Select the simplest qualifying
shape and discard the other prototype. If neither qualifies, retain both
correctness/cost results and leave M1 incomplete. Present a concrete measured
alternative before seeking a decision about the index requirement or a schema
change. No index, generated column, trigger, summary table, periodic refresh, or
writer-side counter is pre-authorized by this plan.

### M2 — Deliver the library, CLI, and HTTP contract


Finalize `countWorkflowInstancesByStatus` as a thin facade over the selected
owner read and implement its canonical `ToJSON` encoding in
`keiro/src/Keiro/Workflow/Inspection.hs`. Count only current headers, including
terminal rows still retained; garbage-collected rows are absent. The timestamp
is the database transaction observation clock, not a historical as-of token or
a promise that other requests share that snapshot. Always return every class,
including on an empty table or unknown name. Propagate storage errors normally;
a timeout must not be converted to zero counts or a partial success.

Add `InspectCounts !Inspection.WorkflowCountsQuery` in
`keiro-ops/src/Keiro/Ops/Workflow.hs`, the `counts` subcommand with only the
optional `--workflow-name`, a read-only classification, validation coverage,
and a `runInspection` branch that uses the same canonical JSON for human and
JSON output through `OpsResult`. Do not add pagination or status filters to
counts. The existing HTTP parser then provides `GET /wf/inspect/counts` and
the `workflow_name` parameter, without transport SQL or special budget bypasses.
Prove a single seeded request across library, command, and HTTP before expanding
the test matrix. Ignore timestamps only when comparing separate observations.

Extend `keiro/test/WorkflowInspectionSpec.hs` for empty and unknown-name zeroes,
every classification branch, ignored lease/retry-time fields, status transitions,
generation rotation, exact names, and sums matching full paging. Use more than
500 instances so a first-page count cannot accidentally pass. Exercise public
lifecycle operations where they establish a transition; seed test-only edge
rows directly when testing stored classification. Test JSON integers beyond
32-bit range using a constructed result without inserting billions of rows.
Extend `keiro-ops/test/Main.hs` for parsing, rejected unsupported options,
read-only classification and JSON parity. Extend `keiro-ops-http/test/Main.hs`
for GET parity, name translation, missing-name zeroes, live schema refusal,
admission refusal, statement cancellation, and permit recovery. Use a controlled
fixture lock or short test timeout to make cancellation deterministic; a timed-out
read must release resources and allow a subsequent successful request.

Add `scripts/check-workflow-counts.py`, a read-only HTTP checker accepting a base
URL and optional exact workflow name. It fetches counts, follows every opaque
`next_cursor` from list with `limit=500` and the identical filter, totals each
returned `status_class`, and asserts equality and complete seven-key coverage.
URL-encode names and cursors and fail on HTTP errors. Run it against a quiescent
Jitsurei database: stop demo workers or use a disposable database copy before
comparing. A concurrently changing database is unsuitable for exact cross-request
comparison; do not add production locks or claim snapshot paging to make it pass.
M2 acceptance is passing tests and retained all-name and `order-fulfillment`
Jitsurei comparisons, including an absent name.

### M3 — Establish runtime isolation and publish the operating envelope


Adapt `keiro-ops-http/bench/InspectionInterference.hs` and
`keiro-ops-http/bench/InspectionClients.hs` with explicit `wf-counts` and
`wf-counts-many` modes, preserving existing scenarios. Add a configurable workflow
fixture size defaulting to its existing size; the counts measurements must select
one million rows. The single-client mode polls unfiltered counts once per second.
The many-client mode runs eight clients with a mixture of unfiltered, common,
rare, and absent names, each at one request per second, including aligned bursts
to exercise the four-slot admission cap. Require successful count responses
through the real WAI/Warp application as well as recording every refusal and
timeout. A run that protects writers by refusing all count work is invalid.
The normal single-client mode must complete every measured poll within existing
limits. Overload may return the existing admission refusal and must recover.

Create `scripts/measure-workflow-counts.sh` as the serial controller and
`scripts/analyze-workflow-counts.py` as its failing analyzer, reusing the existing
interference harness patterns without inheriting hard-coded historical commits
from `scripts/inspection-matched-http-evidence.py`. Accept explicit frozen
baseline/candidate binaries and output directory. Record their hashes, complete
commands, source trees, compiler/optimization, RTS settings, PostgreSQL version,
pool sizes, hardware, class/name distribution, durability settings and workload
seed. Build the same instrumented writer/measurement harness against both source
trees; baseline runs existing disabled/idle modes without invoking a nonexistent
count endpoint. Keep fixtures and measurement code otherwise identical.

Run at least five alternating pairs of unpaced writer capacity measurements, then
at least five alternating blocks comparing baseline with candidate unmounted,
mounted-idle, one count poller, and eight count pollers. Qualify a fixed offered
rate below 75% of the slowest baseline capacity; verify stable scheduling delay
so a growing backlog cannot appear as healthy throughput. Use at least 20 seconds
of measurement after warm-up, increasing the duration when too few count reads
or maintenance noise make results inconclusive. Do not run builds, tests, or
other repository benchmarks concurrently. The measured runtime work must retain
real schedule/claim/resume/release, workflow completion, and timer work, and add
representative retry and suspension transitions if the selected harness lacks
them. Retain per-operation timings, throughput, writer-thread allocation, query
counts, WAL (the database write-ahead log), update statistics, poll outcomes and
raw samples. Attribute runtime allocation to runtime work; total-process bytes
divided by writer completions includes inspection and is not that measurement.

Analyze paired medians. A capacity or throughput reduction above 5%, p95 latency
increase above 5%, or runtime allocated bytes per operation increase above 5%
fails automatically, matching the existing inspection gate. The user requires no
regressions: investigate and fix smaller reproducible attributable degradations
as well. State measurement spread and uncertainty; noisy or inconclusive results
do not pass. Reject new ordinary-path SQL, event reads, metadata serialization,
background work, or retained per-instance counting state even if wall time looks
unchanged. Keep list first/deep-page behavior and the existing benchmark guards
green. Do not move baselines, loosen thresholds, reduce the promised fixture, or
increase deadlines to manufacture acceptance. A negative control in the analyzer
must fail when supplied a deliberately degraded capacity/latency sample.

Retain evidence under `keiro/bench/results/workflow-counts/` with an auditable
README, not just a green summary. Document the measured supported cadence and
dataset in `docs/user/durable-workflows.md` and
`docs/guides/serve-keiro-ops-over-http.md`, including exact filtering, zeros,
clock semantics, timeout/refusal behavior, linear population cost, index plans,
and the requirement for deadline-configured direct callers. Update the applicable
unreleased changelogs. Distill the accepted count/isolation contract into ADR-28
and ADR-40 if it adds durable context; preserve their metadata and log conventions.
Only mark M3 complete after final-source evidence and `just release-gate` pass.


## Concrete Steps


All commands start in the repository root. Builds, tests, benchmarks, and document
checks run inside the Nix development shell. The scripts named below are new
deliverables defined above; create them before invoking them.

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop
z3 --version
```

After the measurement-only harness changes, before production edits, freeze the
baseline. Use a new output directory if one already exists; do not overwrite
prior evidence. The source identity files must accompany the binary.

```bash
mkdir -p keiro/bench/results/workflow-counts/binaries
git rev-parse HEAD > keiro/bench/results/workflow-counts/binaries/baseline-revision.txt
git diff --binary > keiro/bench/results/workflow-counts/binaries/baseline-source.patch
cabal build keiro-ops-http:bench:inspection-interference --enable-benchmarks
cabal list-bin keiro-ops-http:bench:inspection-interference > keiro/bench/results/workflow-counts/binaries/baseline-built-path.txt
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path('keiro/bench/results/workflow-counts/binaries')
target = root / 'baseline'
assert not target.exists(), 'refusing to replace baseline'
shutil.copy2((root / 'baseline-built-path.txt').read_text().strip(), target)
PY
```

Retain any relevant untracked source files alongside the patch; a Git diff alone
does not include them. Reconstructible source identity is required for both legs.
After implementing M1/M2, run:

```bash
cabal build keiro keiro-ops keiro-ops-http --enable-tests --enable-benchmarks
cabal test keiro-test --test-options='-m "Keiro.Workflow.Inspection"' --test-show-details=direct
cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support scripts/workflow-counts-query-evidence.hs keiro/bench/results/workflow-counts/query
cabal test keiro-ops-test keiro-ops-http-test --test-show-details=direct
```

The focused tests must pass, and the query driver must write artifacts for every
specified size, distribution, filter, and plan mode, exiting nonzero on mismatched
counts, timeout, or failed required cost criteria. Its README must identify any
nonqualifying prototype rather than label it accepted.

For Jitsurei acceptance, set `DATABASE_URL` to a quiescent existing demo database
or a disposable copy prepared using `docs/guides/run-and-operate-jitsurei.md`.
Do not reseed or reset an existing developer database for this check. In one Nix
shell start the database-only HTTP host; in another Nix shell run the checker:

```bash
cabal run exe:keiro-ops-http -- --database-url "$DATABASE_URL" --port 9092
```

```bash
python3 scripts/check-workflow-counts.py http://127.0.0.1:9092
python3 scripts/check-workflow-counts.py http://127.0.0.1:9092 --workflow-name order-fulfillment
python3 scripts/check-workflow-counts.py http://127.0.0.1:9092 --workflow-name absent-workflow
cabal run exe:keiro-ops -- --database-url "$DATABASE_URL" wf inspect counts --json
curl --fail --get --data-urlencode workflow_name=order-fulfillment http://127.0.0.1:9092/wf/inspect/counts
```

The checker prints `PASS: counts equal all listed instances` with compared totals
and exits zero only on equality. Empty selection has this shape, with a real
database timestamp in place of the example:

```json
{"observed_at":"2026-10-26T00:00:00Z","counts":{"running":0,"retrying":0,"sleeping":0,"awaiting":0,"completed":0,"cancelled":0,"failed":0}}
```

After building and freezing the matched harness binaries, set `COUNTS_BASELINE_BIN`
and `COUNTS_CANDIDATE_BIN` to their absolute paths; the controller validates both
and copies their hashes into its manifest. These are task-specific environment
variables, not system-directory overrides.

```bash
cabal build keiro-ops-http:bench:inspection-interference --enable-benchmarks
cabal list-bin keiro-ops-http:bench:inspection-interference > keiro/bench/results/workflow-counts/binaries/candidate-built-path.txt
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path('keiro/bench/results/workflow-counts/binaries')
target = root / 'candidate'
assert not target.exists(), 'refusing to replace candidate'
shutil.copy2((root / 'candidate-built-path.txt').read_text().strip(), target)
PY
export COUNTS_BASELINE_BIN="$PWD/keiro/bench/results/workflow-counts/binaries/baseline"
export COUNTS_CANDIDATE_BIN="$PWD/keiro/bench/results/workflow-counts/binaries/candidate"
bash scripts/measure-workflow-counts.sh "$COUNTS_BASELINE_BIN" "$COUNTS_CANDIDATE_BIN" keiro/bench/results/workflow-counts/runtime
python3 scripts/analyze-workflow-counts.py --self-test
python3 scripts/analyze-workflow-counts.py keiro/bench/results/workflow-counts/runtime
just user-documentation-validate
just adr-validate
just release-gate
git diff --check
```

The controller must retain exact build/freeze commands in its README as soon as
the harness changes are known. Expected final results are complete paired
evidence, successful analyzer negative control, zero failing performance gates,
passing strict documentation validation, and a zero exit from the combined
correctness/six-benchmark release gate. There is no performance acceptance claim
at plan-creation time.


## Validation and Acceptance


Correctness requires agreement with `statusClassOf` over every row of complete
list paging on stable fixtures and the Jitsurei database, all-name and filtered.
The seven totals must sum to the selected current instance population. Empty
selections return seven zeroes and an observation clock. A transition between
classes changes the next count response immediately without a refresh job; a
generation change does not duplicate an instance. Large numeric values encode as
integers and no status class is omitted. The public command and HTTP response
use the owning library's representation.

Boundedness requires shared schema verification/admission, existing statement
and handler deadlines, successful cancellation recovery, no partial count
success, and a fixed-size result. The million-row test is about database work,
not just the size of the result. Required index-backed evidence uses the actual
prepared owner query and the normal planner. Record filtered-query costs too;
there is no existing leading workflow-name index to assume away an absent-name
scan. Failure to meet either IR-58 criterion leaves the plan incomplete.

Performance requires M3's final-source matched capacity and interference evidence
with real successful poll traffic, no added work on default runtime paths,
unchanged existing list behavior, and a passing release gate. A dedicated pool
does not isolate PostgreSQL CPU, storage, or cache contention. Old cohort evidence
and historical benchmark smoke tests cannot substitute for measuring these new
counts on one million rows. Report the observed envelope and uncertainty, rather
than claiming a universal zero-cost guarantee from a finite experiment.


## Idempotence and Recovery


The chosen design adds no migration or persistent maintenance state. Code changes
can be reverted together without restoring data; keep existing list and lifecycle
APIs intact. Seed and update only uniquely named disposable benchmark fixtures
using `Keiro.Test.Postgres`; retain failed-run artifacts in a separate directory
before repeating so measurements are never silently overwritten. Stop the
fixture-owned clients/host and release pools on cancellation. The Jitsurei checker
is read-only and must fail clearly when the target changes during comparison.

If a performance gate fails, diagnose the relevant query/workload, retain the
failure, and rerun affected comparisons after a fix. Do not mark a failed
prototype as a completed feature, silently accept approximation, or alter another
contributor's work while recovering. Any later proposal for schema changes must
add migration, compatibility, wide-key, and matched writer evidence before it can
replace this plan's schema-preserving design.


## Interfaces and Dependencies


The new owning types in `Keiro.Workflow.Inspection.Query` are intentionally
small and inspection-only. Re-export them from `Keiro.Workflow.Inspection`:

```haskell
data WorkflowCountsQuery = WorkflowCountsQuery
  { workflowName :: !(Maybe Text) }

data WorkflowStatusCounts = WorkflowStatusCounts
  { running :: !Int64, retrying :: !Int64, sleeping :: !Int64
  , awaiting :: !Int64, completed :: !Int64, cancelled :: !Int64
  , failed :: !Int64 }

data WorkflowCounts = WorkflowCounts
  { observedAt :: !UTCTime, counts :: !WorkflowStatusCounts }

-- Keiro.Workflow.Instance: one statement, database clock, seven bigint totals.
inspectionInstanceCounts
  :: (Store :> es) => WorkflowCountsQuery -> Eff es WorkflowCounts

-- Keiro.Workflow.Inspection: public owner facade and canonical ToJSON instance.
countWorkflowInstancesByStatus
  :: (Store :> es) => WorkflowCountsQuery -> Eff es WorkflowCounts
```

Use the repository's existing record extensions and deriving conventions.
There is no cursor or page validation error in this query: a supplied text name
is an exact filter, and storage failures continue through `Store`. PostgreSQL
`count(*)` returns `bigint`; decode with the existing Hasql `int8` pattern into
`Data.Int.Int64`, not `Int32` or floating point. Reuse existing Hasql statements
and `Kiroku.Store.Transaction.runTransaction`; Mori discovery identified the
owner as `mori://shinzui/kiroku/packages/kiroku-store`, and its source confirms
the transaction combinator runs at read-committed isolation. A single SELECT
therefore avoids mismatched snapshots between class totals.

No dependency bounds or pins change. Before adding an unfamiliar dependency API,
discover its source/docs with Mori; verify the authoritative registry and release
tags before any subsequent dependency change. This is a standalone plan, with no
new MasterPlan dependency. M2 depends on M1's accepted query, and M3 depends on
the integrated route. Count feeds, UI implementation, schema redesign, cached
statistics, and release tagging are outside this scope. Implementation commits
carry this plan's `ExecPlan:` trailer and
`Intention: intention_01m5wv1274eyxtzm8gz20xhpea`.
