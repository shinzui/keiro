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


- [ ] M1: Separate clones and static benchmark trees keep selected setup isolated. A command
      filter executes no delegated setup/duplicate seeding/warm-up; listing benchmark names
      executes no workload preparation. Filtered/full command measurements agree within noise.
- [x] M2 (2026-10-25): Fresh command/fan-out identities and 64 actual-count reports verify
      expected stored work without timed hard deletes. Rebuild runs retain exactly 600 source
      events and persisted bookkeeping matches run counts. Five durable growth blocks through
      3,005,000 seeded events differ by 1.65% fresh / 4.67% no-op from 100,000 events;
      actual late plans remain indexed. Reset alternatives retain fixed row counts and
      measured costs in `harness-isolation-v1/reset-probe.txt`; growth spreads/counts are in
      `harness-isolation-v1/growth-summary.txt`.
- [ ] M3: Representative setup warm-up resolves first-run/order effects. First inbox fresh
      rows stay within 25% of their metrics twin, fan-out scales with target count, and command
      no-op/rejected rows meet the under-200-us target on the recorded environment. The
      previously observed 21-ms and small-fan-out anomalies have attributed evidence.
- [ ] M4: Retain setup traces, source/workload counts, paired timing samples, environment and
      revision under `keiro/bench/results/harness-isolation-v1/`; annotate old evidence READMEs
      with the new fixture boundary and hand accepted evidence to plan 315.


Implementation status (2026-10-25): The isolated static-tree harness builds in the Nix
shell. `harness-isolation-v1/list-tests.log` has no setup events; the rebuild probe records
six successive 600-event reports. A one-second command smoke run is deliberately not
acceptance: the two largest fan-outs time out and accepted-1 drifts across scenario order.
`KEIRO_BENCH_COMMAND_PROBE=1` diagnoses actual prepared stream-read plans and growth before
recording. No baseline or ratio threshold has changed. The growth probe remains indexed through
1,205,500 events (including diagnostic rows), with fresh/no-op means of 140/24 us
at the late population. The ordinary entry point now uses the existing durable
benchmark fixture rather than fast correctness settings. Durable growth through 1.2 million events and reset alternatives are retained.
The first paired attempt was stopped after explicit 100,000-unit counter failures
and delegated-inbox drift; it is not acceptance. Silent commands now have a finite
one-million-operation budget without pretending they retain event rows; large batches
allow 10,000 invocations (one million events), while one-event/fan-out rows retain
100,000-event budgets. The aggregate command store is bounded at 3,005,000 events.
Selected delegated setup ANALYZEs after its first representative warm-up, then warms
twice more. Actual prepared existence plans are probed before/after that schedule.
Actual count diagnostics now complete all 96 cases with no mismatches, including
command/fan-out prefixes, delegated/history inputs, fixed rebuild sources and persisted
bookkeeping. The first full release gate exposed a read-model order effect despite its
passing alternating latency sampler. Its unchanged 25,000 seed events now span 5,000
streams; one fixture-wide ANALYZE precedes selected three-invocation warm-up. Read-model
command/async/promotion growth was initially bounded at 100,000/100,000/10,000.
The tighter run reached 84,942 command and 65,540 async operations. Current finite caps
are 500,000 command events, one million async operations and 10,000 promotion runs,
so correctly fast adaptive samples do not exhaust those initial budgets.
`work-counts.*` and its exact source patch retain the diagnostic. The single-block durable probe is followed by five checkpoint blocks through
3,005,000 seed events. Fresh/no-op medians at the maximum are 145.18/20.60 us,
within 1.65%/4.67% of the 100,000-event checkpoint, with actual indexed plans,
counts and durable settings. The first replacement pairs at `cfc57046` pass every command median (maximum 6.66%)
but a later inbox row has a 59.30% metrics-twin outlier in the third full run.
`attempt-2/` retains all three pairs and is not final acceptance. Maintenance snapshots
show cluster checkpoints spanning cloned databases and selected scenarios. The candidate
now finishes prior checkpoint work before final selected warm-up. Its instrumented full
run passes 96 cases, all fresh twins within 4.41%, and all 114 maintenance snapshots show
an idle checkpointer with no outstanding request. Final work counts also pass all 96 diagnostic cases / 64 actual reports,
including persisted fixed rebuild inputs; settled reset alternatives and the 96-name
zero-setup listing pass. Only unprobed pairs on that boundary remain open.

## Surprises & Discoveries

Logical clones still share PostgreSQL's checkpointer. `maintenance-full-1.*` records
in-progress cluster checkpoints from early delegated intake into command scenarios
(`CheckpointWriteDelay`, requested greater than completed), with 1-GB/5-minute defaults.
A prior three-pair cohort had a late fresh-inbox outlier and slower small appends. The
instrumented run does not directly reconstruct that older outlier's server state; it proves
the remaining cross-scenario mechanism. `checkpoint-full-1.*` completes prior checkpoint
work before final selected warm-up and records zero busy/outstanding checkpoints across
114 snapshots, with every fresh twin within 4.41%. New unprobed pairs remain required.

The first complete release gate passed correctness but refused producer and projection.
Projection's sequential one-target rows diverged 2.43x, while its alternating three-target
sampler measured median p95 1.026x and throughput 0.975x. The read-model seed had 25,000
events in only one stream, so event volume did not establish representative stream-name
statistics. The revised seed retains the event count across 5,000 streams and records
actual prepared plans. A tighter follow-up still failed when it measured five legacy
cases before five versioned cases. Adjacent controls preserve every benchmark name and
ceiling while comparing nearer retained populations. The instrumented adjacent run passes
all 12 cases; the separate unprobed run also passes (inline 1.01–1.04x, async 1.06x).
Replacement command pairs remain acceptance work; five-block growth spread passes.
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
