---
id: 321
slug: isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture
title: "Isolate the keiro-bench harness so each guard measures only its own fixture"
kind: exec-plan
created_at: 2026-10-21T13:07:00Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
master_plan: "docs/masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T13:07:00Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:24:48Z
      verdict: "changes-requested"
      note: "Fresh rebuild stream names retain old category events and grow replay work; 100k history is already lazy and cannot prove filtered-run isolation; static benchmark tree must be preserved."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:49:51Z
      mode: "update"
      note: "Use static selected setup, fixed 600-event rebuild sources, representative warm-up, explicit growth bounds and preparation traces."
---

# Isolate the keiro-bench harness so each guard measures only its own fixture

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


After this plan, each benchmark group uses its own migrated database clone, expensive
preparation runs only for selected scenarios, and a filtered command run agrees with command
rows in a full run within measured noise. Command actions stop paying hard-delete fixture
costs, and projection rebuild samples always replay the same 600 source events. Preparation
and representative warm-up are outside timed actions; real rebuild target reset remains part
of the supported rebuild operation.

Plan 315's HEAD experiment demonstrates shared-preparation sensitivity, not an unconditional
100,000-event history build: that history already has selected `env` setup. The unconditional
work to remove is business-table setup, duplicate seeding and fresh delegated warm-up. This
plan proves isolation with explicit preparation counters and source counts before plan 315
records new baselines.


## Progress


- [ ] M1: Separate clones and static benchmark trees keep selected setup isolated. A command
      filter executes no delegated setup/duplicate seeding/warm-up; listing benchmark names
      executes no workload preparation. Filtered/full command measurements agree within noise.
- [ ] M2: Command/fan-out actions use unique iteration identities without timed hard deletes.
      Projection setup seeds exactly 600 category events once; every repeated rebuild scans
      those same 600 events. Other reset choices and growth bounds have measured rationale.
- [ ] M3: Representative setup warm-up resolves first-run/order effects. First inbox fresh
      rows stay within 25% of their metrics twin, fan-out scales with target count, and command
      no-op/rejected rows meet the under-200-us target on the recorded environment. The
      previously observed 21-ms and small-fan-out anomalies have attributed evidence.
- [ ] M4: Retain setup traces, source/workload counts, paired timing samples, environment and
      revision under `keiro/bench/results/harness-isolation-v1/`; annotate old evidence READMEs
      with the new fixture boundary and hand accepted evidence to plan 315.


## Surprises & Discoveries


`prepareInboxDelegatedBenchmarks` creates the business table, seeds duplicate scenarios and
executes each fresh scenario once before defaultMain. Its history nodes instead use
`env (prepareHistoryRun store historySize)` and are already selection-aware; the explain hook
can also explicitly build a history. The former plan confused these paths. Absence of a
100,000-event history in a command-only run is therefore not new isolation evidence.

The rebuild fixture declares CategorySource orders/customers/billing and starts replay at
GlobalPosition 0. New stream names within those categories retain prior events, and changing
the rebuild group ID does not narrow source selection. Repeating that proposal would make
sample n replay roughly n times 600 events. A fixed seeded source avoids that distortion.

Fresh-name command iterations still grow database relations and can affect planning, cache
state and vacuum. Isolation alone does not prove stationary samples; the evidence must record
operation counts and demonstrate that measured cost is stable across the permitted run size.


## Decision Log


- Decision: Keep existing bracketed fixture lifetimes and open one clone per group eagerly;
  make workload preparation selection-aware inside the static benchmark tree.
  Rationale: Clones are cheap and existing withFreshResourceStore owns safe cleanup. This
  avoids inventing acquire/release APIs or an MVar handoff merely to defer clone creation.
  Date: 2026-10-21
- Decision: Mint unique command/fan-out identities per iteration, but seed rebuild source
  categories once and reuse them with fresh rebuild run IDs.
  Rationale: Commands must not time irrelevant hard deletes; a rebuild must not accumulate
  a growing replay input. Rebuild's own target clearing is actual measured behavior.
  Date: 2026-10-21
- Decision: Warm representative database actions in selected setup rather than adding a
  throwaway benchmark expected to run once.
  Rationale: A benchmark action is sampled repeatedly, and the cheapest producer scenario
  derives an ID without warming SQL. Setup order and workload must be explicit.
  Date: 2026-10-21

Revision note (2026-10-21): Corrected the lazy-history attribution, chose static-tree setup
with existing bracketed resources, fixed projection replay size and replaced inferred wall-time
isolation with preparation/workload counters. Plan 315 retains baseline/threshold ownership.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation


`keiro/bench/Main.hs:ordinaryMain` runs `withMigratedSuite` and two
`withFreshResourceStore` brackets. One store is shared by command, outbox, inbox/downstream,
projection and producer-identity; read-model already uses a second. Before `defaultMain`,
rebuild SQL, read-model setup, delegated preparation and optional evidence hooks run.
`keiro-test-support/src/Keiro/Test/Postgres.hs` owns these disposable fixtures.

The benchmark tree and names are public guard inputs. `scripts/bench-regression.sh` runs six
guards; five match `keiro/bench/baseline-*.csv`, while producer-identity compares two rows in
one process. Preserve names including All.inbox.downstream.* when splitting its store.
`InboxDelegatedBench.hs` currently returns IO [Benchmark]; separate its pure scenario/name
specifications from acquired fixture data so selecting or listing the tree never forces IO
to discover names. Read the installed tasty-bench API through Mori before changing resource
combinators. Use its existing env pattern only for data/setup, not dynamic tree discovery.

`commandScenarioBench`, `domainCommandScenarioBench`, `domainRouterFanoutBench` and
`domainProcessManagerFanoutBench` currently time target hard deletes. The fan-out identity
also includes correlation/source inputs; fresh target spelling alone must not accidentally
reuse a command identity and measure deduplication. The producer benchmark truncates its
outbox before each fresh batch, requiring every enqueue to return ProducerInserted.

`rebuildScenarioBench` currently deletes/reseeds three streams, registers the catalog and
rebuilds. `rebuildCatalogDeclaration` sources are whole categories, and the request replays
from zero. `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` reads CategorySource with readCategory;
new group IDs cannot exclude old category events. Move its three-stream seed and catalog
registration into selected setup, retaining the supported repeated rebuild operation.

Plan `docs/plans/315-attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards.md`
records HEAD router/process-manager fan-out at 2.01/1.96 s with preparation versus 662/777 ms
without it; accepted-large was 44.2 versus 4.69 ms. The same experiment gave anomalous no-op
21.4 ms and fan-out 10/100 at 229/3500 ms. These are investigation inputs, not target values
after removing deletes. [ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
provides the isolated-leg and discarded warm-up precedent. Plan 316 owns [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
and consumes this plan's fixture evidence; no cross-repository ADR is required.


## Plan of Work


M1 keeps `withMigratedSuite` and opens separate bracket-owned clones for command, outbox,
ordinary inbox, delegated inbox/downstream, producer-identity, projection and read-model.
Keep store handles in closures with the same lifetime as defaultMain. Move table/fixture
preparation into selected env setup, preserving a pure list of group/scenario names. In
InboxDelegatedBench.hs split scenario specification from acquisition; build names from the
pure specification and access prepared data only inside benchmark actions. Do not obtain the
Benchmark list itself from an env value. Preserve read-model and explicit explain/evidence
entry points without running their preparation on ordinary unrelated selections.

Add an opt-in `KEIRO_BENCH_SETUP_TRACE=1` diagnostic to setup actions that emits group,
scenario and preparation kind (schema, duplicate-seed, warm-up, history), plus operation/source
counts. It must not expose credentials. A command-only selection must show no delegated
preparation; an all-tests listing must show no workload preparation. A selected history run
must show its own history setup once. This distinguishes new isolation from the already-lazy
100k history. Keep every existing benchmark name and baseline-match pattern unchanged.

M2 gives command/fan-out scenarios per-scenario counters acquired in setup. Include the next
counter in target names, correlation/saga names and any identity seed necessary to produce
fresh commands. Assert the accepted rows append the expected event counts and no-op/rejected
rows append none. The work must remain command execution, not accidental duplicate probes.
Record iterations, resulting stream/event counts and relation growth for each sample.

For projection, setup creates app tables, seeds the existing three category streams with
200 events each and registers the catalog once. Each timed action generates a new RebuildRunId
and invokes the same supported rebuild group with replayFrom zero. It does not append, delete,
or rename sources. The rebuild's own ClearBeforeReplay target reset remains timed. Verify at
least three consecutive rebuilds each traverse exactly 600 input events, including after
warm-up; count source reads/events in a diagnostic run and preserve production timing without
that probe. Record bounded growth in rebuild-run bookkeeping as well as fixed source count.

Measure outbox and inbox reset alternatives on their isolated stores. Keep their existing
TRUNCATE when it is required to hold the workload fixed, documenting timed reset cost and
why growing retained rows would change the operation. For producer-identity keep equal reset
boundaries, but do not claim a common additive cost cancels from a ratio: measure/reset-report
it separately and pass that evidence to plan 315 before any threshold change.

M3 warms representative database actions in selected setup, with a bounded, recorded number
of invocations and distinct identities. For producer fresh rows, warm SQL enqueue rather than
only pure derive-v1. Do not add an adaptive throwaway benchmark and call it one invocation.
Measure the first fresh inbox scenario and its metrics twin, and run no-op/fan-out comparisons
in both orders. Use statement plans/counters on disposable fixtures to attribute the 21-ms
and inverted fan-out anomalies. If statistics matter, record the exact ANALYZE schedule and
show it matches the admitted workload, rather than hiding a cost by arbitrary tuning.

Fresh-name samples must have an explicit finite growth budget enforced by the harness; a
budget overrun aborts the sample with a diagnostic, never reports a truncated successful
measurement. --timeout/--stdev are measurement controls, not a deterministic row-count bound.
Establish stationary cost across early/late blocks within the chosen budget. If that fails,
revise the fixture design with evidence before accepting M2/M3 or recording baselines.

M4 retains at least three alternating filtered/full command pairs on a quiet machine using
identical settings and serial execution. Compare matching names with a CSV parser, excluding
setup from timing and retaining setup traces separately. Require median relative differences
within 10% for each command row and report sample spreads; investigate larger or inconclusive
differences, not silently accept noise. Preserve the old before/after measurements as historical
observations and document the accepted fixed-workload protocol for plan 315.


## Concrete Steps


From the repository root inside `nix develop`, after implementing setup tracing:

```bash
cabal build keiro:bench:keiro-bench
KEIRO_BENCH_SETUP_TRACE=1 cabal bench keiro-bench --benchmark-options='--list-tests'
KEIRO_BENCH_SETUP_TRACE=1 cabal bench keiro-bench --benchmark-options='-p command -j1 --time-mode wall --hide-progress --csv /tmp/command-alone.csv'
KEIRO_BENCH_SETUP_TRACE=1 cabal bench keiro-bench --benchmark-options='-j1 --time-mode wall --hide-progress --csv /tmp/all.csv'
python3 - <<'PY_COMPARE'
import csv

def rows(path):
    with open(path, newline='') as handle:
        return {row[0]: float(row[1]) for row in csv.reader(handle)
                if row and row[0].startswith('All.command.')}

alone, full = rows('/tmp/command-alone.csv'), rows('/tmp/all.csv')
assert alone and alone.keys() == full.keys(), 'missing or changed command names'
for name in sorted(alone):
    assert alone[name] > 0
    print(f'{name}: filtered={alone[name]/1e6:.3f} ms full={full[name]/1e6:.3f} ms difference={100*(full[name]/alone[name]-1):+.1f}%')
PY_COMPARE
```

These are one paired sample, not M4's full acceptance. Use distinct CSV/log names for the
three alternating pairs and record the runner/RTS options. The first command listing must not
emit preparation events. The command filter must emit no delegated-inbox setup events. The
CSV parser handles quoted names correctly and converts nanoseconds to milliseconds with 1e6.

Exercise the fixed projection fixture and verify three diagnostic iterations each traverse
600 events before measuring it normally. Implement the count probe as a benchmark-only option
and document its exact invocation in the evidence README; no production API is added for it.


## Validation and Acceptance


M1 requires static-name listing and preparation traces proving unselected setup is absent,
and M4's paired measurement evidence. M2 requires command outcome/event-count checks,
no timed command hard deletes, three exact 600-event rebuild iterations, measured reset
exceptions and enforced growth budgets. A new rebuild group ID alone is not isolation.

M3 requires the stated inbox/fan-out/no-op targets and evidence explaining the previous
anomalies under controlled order; a noisy/inconclusive run remains open work. M4 requires
three serial alternating filtered/full pairs, matching command rows within the 10% median
comparison, raw evidence and corrected README annotations. Fixed-source and growth-count
checks run with probes; timed acceptance runs disable them. No baseline or producer ceiling
is changed here. Plan 315's recording milestones may start only after this plan is Complete.


## Idempotence and Recovery


Runs use disposable bracket-owned clones and leave production stores untouched. Preserve
scratch samples used for decisions before cleanup; do not overwrite historical evidence.
A fixture-budget overrun or nonstationary workload fails acceptance and requires a fixture
revision, not a looser statistical option. Cancelled selected setup must unwind through the
existing fixture brackets. No new acquire/drop resource implementation is required.


## Interfaces and Dependencies


This plan owns fixture/setup/action boundaries in `keiro/bench/Main.hs`,
`InboxDelegatedBench.hs`, `ProducerIdentityBench.hs`, and `ReadModelBench.hs`. Preserve all
scenario names and public benchmark entry points. It uses existing bracketed fixtures from
`keiro-test-support`; no guessed tasty-bench cleanup API or package change is required.

Plan 315 owns recording, all affected baseline CSVs and measured producer threshold policy;
its M3–M6 require this plan Complete. Plan 316 owns runner commands and the durable benchmark
ADR, consuming this plan's isolation/fixed-workload evidence. No prerequisite blocks this
plan, and it is the next implementation work under MasterPlan 46.
