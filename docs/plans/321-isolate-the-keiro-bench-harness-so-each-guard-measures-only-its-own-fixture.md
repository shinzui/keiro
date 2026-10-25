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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T04:23:38Z
      mode: "implement"
      note: "Implement selected isolated fixtures and fixed source workloads."
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


- [x] M1 (2026-10-25): Seven migrated clones and static selected setup preserve all 96
      names. Listing performs no workload setup; all three command-only traces contain
      no delegated, read-model, outbox, inbox or rebuild preparation. Three alternating
      filtered/full pairs pass every command median comparison, maximum 6.03%.
- [x] M2 (2026-10-25): Actual-count diagnostics pass all 96 cases / 64 count reports,
      including every command/fan-out prefix and 13 persisted rebuild runs with 39 source
      rows and exactly 600 events. Five durable blocks through 3,005,000 seed events differ
      by 1.65% fresh / 4.67% no-op from 100,000 events, with indexed lookup. Settled reset
      alternatives and enforced event/operation/bookkeeping bounds are retained.
- [x] M3 (2026-10-25): Representative warm-up, established statistics, adjacent projection
      controls and settled checkpoint preparation remove the measured order mechanisms.
      All fresh inbox twins in the accepted full runs differ by at most 4.42%; fan-out
      scales monotonically in both selections. No-op/rejected rows remain below 17 us.
      Earlier anomalous/failed cohorts and actual prepared/maintenance probes are retained.
- [x] M4 (2026-10-25): Accepted source `ee2f2667`, environment, binary identity, all six
      raw CSV/log/trace sets and sample spreads are retained under
      `keiro/bench/results/harness-isolation-v1/`. Both analyzers pass. Historical producer
      and delegated-inbox READMEs identify the changed fixture boundary. Plan 315 may
      begin recording; no baseline or ratio ceiling changed in this plan.

The [acceptance README](../../keiro/bench/results/harness-isolation-v1/README.md) is the
handoff to plan 315. `paired-summary.txt` applies the stated median comparison to every
command row and checks every fresh metrics twin; `growth-summary.txt` retains all five
checkpoint blocks and ranges. Failed attempts remain separately labelled.


## Surprises & Discoveries

Logical clones still share PostgreSQL's checkpointer. `maintenance-full-1.*` records
in-progress cluster checkpoints from early delegated intake into command scenarios
(`CheckpointWriteDelay`, requested greater than completed), with 1-GB/5-minute defaults.
A prior three-pair cohort had a late fresh-inbox outlier and slower small appends. The
instrumented run does not directly reconstruct that older outlier's server state; it proves
the remaining cross-scenario mechanism. `checkpoint-full-1.*` completes prior checkpoint
work before final selected warm-up and records zero busy/outstanding checkpoints across
114 snapshots, with every fresh twin within 4.41%. The subsequent unprobed pairs below establish acceptance.

The first complete release gate passed correctness but refused producer and projection.
Projection's sequential one-target rows diverged 2.43x, while its alternating three-target
sampler measured median p95 1.026x and throughput 0.975x. The read-model seed had 25,000
events in only one stream, so event volume did not establish representative stream-name
statistics. The revised seed retains the event count across 5,000 streams and records
actual prepared plans. A tighter follow-up still failed when it measured five legacy
cases before five versioned cases. Adjacent controls preserve every benchmark name and
ceiling while comparing nearer retained populations. The instrumented adjacent run passes
all 12 cases; the separate unprobed run also passes (inline 1.01–1.04x, async 1.06x).
The later checkpoint-settled pairs replace that intermediate cohort; five-block growth spread passes.
Diagnostic runs are not accepted timing measurements.

The first durable rebuild probe correctly aborted at 167 invocations: its counter
was incorrectly charging fixed source replay as retained growth. Rebuilds now have
an independent 10,000-run bookkeeping budget; source count stays exactly 600 and
no run appends sources. The failed probe remains retained, not treated as a timing.


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


The command-growth probe now attributes an order effect to a generic plan made on an
empty `streams` relation: it still sequentially scans 5,001 rows after growth. ANALYZE
switches to the existing stream-name index and no-op means return from 171.7 us to
27.6 us, remaining 21.2 us at 10,000. Retained JSON contains actual prepared plans,
row counts and relation bytes. The earlier one-second smoke is inconclusive and is
preserved as such. The tasty-bench CSV uses picoseconds, correcting this plan's
original nanosecond conversion.

## Decision Log

- Decision: Finish prior cluster checkpoint work before final selected warm-up using
  `checkpointBenchmarkStore` from test support; retain server maintenance probes.
  Rationale: Separate database clones share the checkpointer. Captured requests remain
  in progress across unrelated scenarios; explicit preparation makes the selected
  checkpoint boundary reproducible while preserving durable settings and business work.
  The barrier is untimed; supported business resets stay timed. ADR-58 records the rule.
  Date: 2026-10-25

- Decision: Seed 5,000 unrelated singleton streams and ANALYZE the three event-store
  relations once during selected command-group setup. One-event and fan-out rows cap at
  100,000 events, large rows at one million events, and silent rows at one million
  operations, including warm-up.
  Rationale: The empty-fixture generic sequential plan explains observed growth drift.
  Established statistics select existing indexes before timing without changing serving
  SQL or adding indexes. Acceptance still requires growth and paired-run evidence.
  Date: 2026-10-25


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

The isolated harness is accepted at `ee2f2667`. All three filtered runs pass 15 cases and
all three full runs pass 96. Every command median difference is at most 6.03%, every fresh
inbox twin at most 4.42%, and silent rows stay below 17 us. Actual counts establish fresh
work rather than accidental deduplication; repeated rebuilds retain exactly 600 source events.
The conservative growth probe reaches more than three million streams with stable indexed
lookup and retained five-block spreads.

The investigation required more than logical clones: statistics, sequential control placement
and cluster checkpoint state all affected the measurement. Earlier counter failures, outliers
and partial runs remain auditable rather than being relabelled as acceptance. ADR-58 carries
those durable lessons. Baseline and producer policy ownership now passes to plan 315; release
acceptance remains plan 316's separate obligation.


## Context and Orientation


`keiro/bench/Main.hs:ordinaryMain` uses `withMigratedBenchmarkSuite` and seven bracket-owned
clones for command, outbox, ordinary inbox, delegated inbox, producer identity, rebuild and
read-model work. `keiro-test-support/src/Keiro/Test/Postgres.hs` owns those disposable
resources and `checkpointBenchmarkStore`, which executes a cluster checkpoint outside a
transaction before final selected warm-up. Durability and autovacuum remain enabled.
`BenchSetup.hs` keeps a static tree and acquires workload handles only for selected cases.
Read-model setup is memoized across its three selected top-level groups.

The guard names are public inputs: five CSV baselines and the same-process producer ratio
use them. All 96 names are preserved. `InboxDelegatedBench.hs` declares pure scenario names;
selected setup creates its table, duplicate seed and warm-up. The history fixture already
used selected setup before this plan. It was never valid evidence of newly deferred work.

Command and fan-out actions mint fresh identities and enforce finite counters; accepted
results and diagnostic stored prefixes verify the expected work. Rebuild setup seeds three
category streams once, with 200 events each, and registers the catalog. Every supported
rebuild replays those same 600 events and retains its real ClearBeforeReplay reset.
Bookkeeping has a separate 10,000-run budget. Fixed-size outbox/inbox/producer actions retain
TRUNCATE, with measured reset exceptions rather than an assumption that additive costs cancel.

Actual prepared stream/existence/group plans, checkpoint activity and relation counts explain
fixture behavior. Empty statistics retain sequential lookup plans; many seed events in one
stream do not establish stream cardinality. Logical clones also share checkpoint work.
Selected setup establishes statistics and settles prior checkpoint work before final warm-up;
projection controls are adjacent while its alternating sampler retains the separate p95/
throughput contract. Timing acceptance disables all probes and uses serial wall time,
`--stdev 5 --timeout 10s +RTS -N2 -RTS`.

Plan [315](315-attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards.md)
owns recording and producer policy after this accepted handoff. [ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
provides the isolated-leg precedent; [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
retains the durable measurement rules. No serving SQL, index or dependency bound changed here.


## Plan of Work


M1 uses the durable `withMigratedBenchmarkSuite` and opens separate bracket-owned clones for command, outbox,
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
KEIRO_BENCH_SETUP_TRACE=1 cabal bench keiro-bench --benchmark-options='-p command -j1 --time-mode wall --hide-progress --stdev 5 --timeout 10s --csv /tmp/command-alone.csv +RTS -N2 -RTS'
KEIRO_BENCH_SETUP_TRACE=1 cabal bench keiro-bench --benchmark-options='-j1 --time-mode wall --hide-progress --stdev 5 --timeout 10s --csv /tmp/all.csv +RTS -N2 -RTS'
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
    print(f'{name}: filtered={alone[name]/1e9:.3f} ms full={full[name]/1e9:.3f} ms difference={100*(full[name]/alone[name]-1):+.1f}%')
PY_COMPARE
```

These are one paired sample, not M4's full acceptance. Use distinct CSV/log names for the
three alternating pairs and record the runner/RTS options. The first command listing must not
emit preparation events. The command filter must emit no delegated-inbox setup events. The
CSV parser must inspect the header: this installed tasty-bench emits picoseconds, so
convert to milliseconds with 1e9 (ratios are unit independent).

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
