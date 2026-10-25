---
id: 315
slug: attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards
title: "Attribute the command-path append slowdown and restore trustworthy benchmark guards"
kind: exec-plan
created_at: 2026-10-21T12:21:07Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
master_plan: "docs/masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T12:21:07Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-21T13:02:16Z
      mode: "implement"
      note: "M1 and M2: tag sweep and no-preparation experiment attribute the fan-out slowdown to the benchmark harness"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:49:51Z
      mode: "update"
      note: "Reconcile completed observations and EP-7 handoff; correct fresh producer/history mechanisms and baseline acceptance."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T08:17:35Z
      mode: "implement"
      note: "Record baselines and attribute producer fresh work after plan 321 acceptance."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:24:48Z
      verdict: "changes-requested"
      note: "Fresh producer inserts have no second lookup statement; completed attribution and EP-7 split are not reflected in Plan of Work or acceptance; claimed eager 100k history is already env-scoped."
---

# Attribute the command-path append slowdown and restore trustworthy benchmark guards

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


After this plan, `nix develop -c just bench-regression` passes on a quiet machine using
baselines with reproducible workload and environment evidence. The existing sweep establishes
that the August command CSV cannot be reproduced at its own commit on this machine, and that
shared benchmark preparation materially changes HEAD's command timings. Those observations
justify repairing the harness before recording baselines; they do not establish the cost of
every production path. Plan `docs/plans/321-isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture.md`
owns that repair and the remaining order-effect investigation.

This plan owns the five CSV baselines, the producer ratio policy, and retained green guard
runs. Plan `docs/plans/316-run-the-benchmark-regression-guards-in-the-release-gate.md` owns
the runner and release policy ADR. Success is three serial all-guard passes ending in
`BENCH_REGRESSION=PASSED`, followed by that plan's passing release-gate demonstration.


## Progress


- [x] M1 (2026-10-21): Recorded the non-reproducing control and the release-window sweep.
      Ten of fifteen rows fail against the control's own CSV; the fan-out step lies after
      0.16.0.0, and the shared-preparation commits first appear in 0.17.0.0. The noisy 0.17 run
      is inconclusive timing evidence, not a passing comparison.
- [x] M2 (2026-10-21): Recorded the HEAD preparation-sensitivity experiment: removing the
      unconditional delegated preparation reduced 1,000-target rows to 662/777 ms and
      accepted-large to 4.69 ms. The specific eager-100k-history explanation is withdrawn;
      scenario counters and remaining order anomalies are plan 321 acceptance work.
- [x] M3 (2026-10-25): Retained all 25 serial recordings on accepted source `b8695a0d`.
      Median aggregation preserves all 78 rows across all five affected CSVs. The named
      command/inbox subset and all five CSV guards pass in three complete runner controls.
- [x] M4 (2026-10-25): Actual statement counts, paired preparation/SQL and 15-pair full
      factory measurements attribute the fresh path. Median of 15 alternating full ratios
      retains the 1.10 ceiling; +20-ms/action control refuses both shapes (1.606×/1.240×).
      Restored normal guard passes (1.057× batch, 0.961× per event in the first full run).

- [x] M5 (2026-10-25): Five isolated inbox recordings and four consecutive inbox-guard
      passes are retained (named subset plus three complete runner invocations).

- [x] M6 (2026-10-25): Three consecutive complete runs pass at `4f2b4b69`, ending
      10:00:00, 10:08:06 and 10:15:56 UTC. Every run has six zero guard statuses,
      `BENCH_REGRESSION=PASSED` and process exit zero. Source/binary/baseline hashes match.

Accepted handoff (2026-10-25): all milestones are complete. Source `b8695a0d` records
all five affected CSVs from 25 successful serial processes and reproduces them in three
controls. Producer attribution and the unchanged 1.10 paired ceiling are accepted after
the +20-ms/action negative control. `accepted-full-1.txt` through `accepted-full-3.txt`
pass all six guards on identical source/binary/baseline hashes at `4f2b4b69`. Batch paired
medians are 1.0568/1.0618/1.0593; per-event medians are below legacy. The prior sequential
failure remains auditable. Plan 316 consumes this handoff in its accepted full red/green release demonstrations
at `a4332cfe`; their logs are under `keiro/bench/results/release-gates/`.
Evidence is under `keiro/bench/results/baseline-recording-v2/`, each `*-v2/` group and
`producer-attribution-v2/`.

M3–M6 require plan 321 Complete. M1/M2 completion means the observations below are recorded;
it does not require the abandoned micro-driver, a passing August control, or a named upstream
regression. Review corrections do not constitute a fresh benchmark run.


## Surprises & Discoveries


The control `2477a5aa`, measured on 2026-10-21, failed ten of fifteen rows against its
August CSV. This makes that CSV unsuitable for directly attributing changes on today's
environment. The historical observations are retained here; recording a new baseline still
requires the accepted isolated harness and control reruns in M3.

```text
scenario                        CSV (Aug)   2477a5aa today   0.19.0.1   HEAD
 domain.accepted-1              3.13 ms     6.62 ms          3.88 ms    3.92 ms
 domain.accepted-large          29.9 ms     98.8 ms          39.4 ms    44.2 ms
 domain.no-op                   0.80 ms     1.26 ms          73 us      75 us
 router-fanout.1000             629 ms      400 ms           1.86 s     2.01 s
 process-manager-fanout.1000     579 ms      416 ms           2.04 s     1.96 s
```

The sweep measured router/process-manager fan-out at 670/804 ms for 0.16.0.0,
1.80/2.03 s for 0.18.0.0, and 1.945/1.885 s for 0.19.0.0. The 0.17.0.0 run's
21.7/21.6 s means had about 48 s spread and cannot support a precise ratio. Commits
`73231189` and `af37b955` introduced unconditional delegated preparation and its warm-up
in that release window. The sweep stopped there; tags 0.13–0.15 were not measured.

At HEAD `03161924`, replacing `prepareInboxDelegatedBenchmarks store metrics` with `pure []`
without other changes gave:

```text
scenario                        with preparation   without preparation
 domain.accepted-1              3.92 ms            0.467 ms
 domain.accepted-large          44.2 ms             4.69 ms
 router-fanout.1000              2.01 s             662 ms
 process-manager-fanout.1000     1.96 s             777 ms
 domain.no-op                   75 us              21.4 ms
 router-fanout.10 / 100          108 / 678 ms        229 / 3500 ms
```

This supports shared-preparation interference, with unexplained systematic no-op and small
fan-out anomalies. It does not prove every serving path unchanged. Review corrected the
claimed mechanism: `historyBenchmark` already uses `env (prepareHistoryRun store historySize)`;
the 100,000-event history is not built by a command-only selection unless the explicit explain
hook is enabled. Unconditional preparation creates the business table, seeds duplicate traffic,
and executes fresh-scenario warm-up. Plan 321 must count those actions and measure isolation.

The producer benchmark truncates the outbox and requires `ProducerInserted` for every fresh
row. `keiro/src/Keiro/Outbox/Schema.hs:enqueueProducerOutboxTx` returns immediately on insert
success; only a conflict performs the locked lookup. ADR-42 describes that distinction and
contains no absolute millisecond budget. Earlier claims of two statements per fresh row and
an ADR-backed absolute allowance were incorrect.


## Decision Log


- Decision: Keep M1/M2 as completed observation milestones and replace their obsolete
  control-pass/micro-driver criteria with the evidence actually obtained.
  Rationale: A failed historical control and preparation sensitivity are useful results;
  they are not proof of a particular upstream defect. Residual anomalies block plan 321.
  Date: 2026-10-21
- Decision: Plan 321 owns all setup, reset, and warm-up changes; M3–M6 begin after it is Complete.
  Rationale: Recording on a changing fixture would preserve its distortion in the CSV.
  Date: 2026-10-21
- Decision: Retain the producer ratio ceiling until measured fresh-path evidence justifies
  a correction; a replacement must still fail for a deliberately excessive fresh-path cost.
  Rationale: Conflict-only SQL cannot explain a successful fresh insert. No existing ADR
  promises an absolute millisecond allowance.
  Date: 2026-10-21

- Decision: Preserve the producer failure and extend actual-factory attribution before
  resolving its guard. No threshold is changed at this checkpoint.
  Rationale: Actual fresh calls perform 1,000 inserts and zero locked lookups; replay
  performs 1,000 attempted inserts plus 1,000 locked lookups. Five component pairs show
  about 9% native-layout batch SQL overhead, and the full batch guard varies from 1.05×
  to just over 1.10× legacy. Separate phases cannot be summed into an exact full budget;
  passing the first two controls does not establish three consecutive full passes.
  Date: 2026-10-25
- Decision: Replace the producer ratio of two sequential adaptive means with median of
  15 adjacent alternating full-workload ratios; retain 1.10 separately for both shapes.
  Rationale: The sequential batch ratio crosses the ceiling at small reported spreads,
  while 15 actual pairs measure typical 1.0496× batch and 0.9706× per-event with retained
  outliers. Both actual actions, preparation, reset and assertions are shared, with all
  pairs printed and a fixed sample count. Roughly five percentage points of typical batch
  headroom remain. No row is discarded and no ceiling is increased. A +20-ms/action
  negative control must refuse before acceptance. ADR-58 records the durable estimator.
  Date: 2026-10-25

Revision note (2026-10-21): Reconciled completed observations with acceptance and the EP-7
split, corrected history/producer mechanisms, and retained measurements without asserting a
universal runtime conclusion. No raw results or baseline numbers were changed by this review.


## Outcomes & Retrospective

All five affected baseline inventories are preserved and reproduced: 15 command,
3 outbox, 38 inbox, 12 projection and 10 read-model rows. Five raw samples per group,
median means/spreads, original CSVs, environment and exact scripts travel together.
The named subset proves runner selection; three original controls reproduce every CSV,
and the new three-run series passes all six guards. Inbox has more than its three
required consecutive passes. The accepted series uses one source, binary and baseline set.

Actual fresh producer calls execute one insert each and no conflict reads. Replay executes
one attempted insert plus one locked read. Preparation, same-input SQL, native identity
layout and actual full-factory pairs are measured separately; they are not an additive
absolute budget. The original sequential estimator crossed 1.10 in its third control.
Fixed alternating full-workload pairs retain that ceiling and every observation, with
about 6% typical batch overhead in the accepted series. The +20-ms/action control refuses
both shapes at 1.606×/1.240× and restores/rebuilds the source. This is a measured estimator
correction, not an increased ceiling or invented ADR allowance.

The historical baseline failure and preparation sensitivity do not establish a universal
absence of production regressions. Fixture/statistics/checkpoint evidence belongs to plan
321; ADR-58 retains the durable recording and comparison rules. Plan 316 consumes these
accepted artifacts for the release-gate proof. No dependency or upstream code changed.


## Context and Orientation


`keiro/bench/Main.hs` owns `keiro-bench`, a tasty-bench program comparing command, outbox,
inbox, projection, and read-model groups with `keiro/bench/baseline-*.csv`. The sixth guard,
producer-identity, compares fresh deterministic and legacy enqueue in the same process.
`scripts/bench-regression.sh` selects the groups and emits per-guard exit status plus an
aggregate result. The accepted command actions now use fresh bounded identities, selected preparation and
settled checkpoints. Seven clones isolate logical groups. Plan 321 retains actual counts,
three alternating filtered/full pairs, five growth blocks and earlier rejected cohorts;
its changed durable workload boundary requires recording every affected CSV.

The original review is `docs/reviews/keiro-0-20-0-21-unreleased-review.md`. The control CSV was
recorded at `2477a5aa`; the existing sweep and HEAD experiment are summarized above. Relevant
source for the producer investigation is `keiro/bench/ProducerIdentityBench.hs`,
`keiro/src/Keiro/Outbox.hs`, `keiro/src/Keiro/Outbox/Identity.hs`, and
`keiro/src/Keiro/Outbox/Schema.hs`. Measure fresh success separately from duplicate and conflict
handling. Existing producer and inbox evidence is under `keiro/bench/results/producer-identity-v1/`
and `keiro/bench/results/delegated-inbox-v1/`; extend it without replacing historical samples.

Relevant ADRs are [ADR-42](../adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md)
(fresh insert versus conflict lookup) and
[ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
(isolated workloads and measured warm-up). Plan 316 owns [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md) and consumes this plan's evidence. No cross-repository ADR is required. Any further upstream investigation
must discover sources through Mori and cite the owning project, `mori://shinzui/kiroku`, with
an exact artifact URI when available; no dependency change is pre-authorized by these measurements.


## Plan of Work


M1 and M2 are already recorded observation milestones. Do not repeat the tag sweep or create
the abandoned three-way micro-driver merely to satisfy old wording. If new evidence contradicts
the preparation attribution, reopen the relevant conclusion and record why. Plan 321 must
resolve fixture interference and remaining order effects before this plan continues.

M3 records the command baseline after plan 321 Complete. Run five serial, baseline-free
samples using identical compiler, RTS, durable PostgreSQL settings and scenario selection.
Retain the raw CSVs under `keiro/bench/results/command-v2/` with the exact commands, source
revision, machine, GHC and PostgreSQL versions, settings, fixture bounds, and any patch needed
to reproduce the recording tree. Take each row's median mean and median spread using the
existing CSV format. Then rerun the same revision against its new CSV and require every
row to satisfy the 25% guard. Inspect all five CSV guards for changed workload semantics;
record affected outbox/projection/read-model baselines with equivalent evidence instead of
leaving incomparable historical rows solely because they are green.

M4 measures the actual producer fresh path. Retain paired legacy/deterministic measurements
with the same transaction size and isolated fixture; verify all rows are inserted and count
statements through a benchmark-only probe. Attribute any difference using identity/envelope
preparation and insert costs; separately measure replay so conflict reads cannot be confused
with fresh work. Fix a measured regression if found. A changed threshold or absolute guard
requires a stated quantity, measured allowance and headroom, retained rationale, and a
negative control that adds cost beyond the allowance and makes the guard fail. Do not
reinterpret ADR-42 as a timing budget or relax the guard solely to make a run green.

M5 records the inbox rows after plan 321 has accepted representative warm-up and removal of
order anomalies. Use five serial recording samples and retain three consecutive inbox passes.
If order effects return, reopen plan 321 rather than implementing another warm-up here.

M6 retains three consecutive all-guard passes. Give plan 316 the recording and threshold
policy for its ADR and passing release-gate run. No upstream improvement request is required
unless new measurements actually identify an upstream serving-path regression.


## Concrete Steps


The accepted recording at `b8695a0d` used these commands inside `nix develop`:

```bash
cabal build keiro:bench:keiro-bench
bash keiro/bench/results/baseline-recording-v2/record.sh
python3 keiro/bench/results/baseline-recording-v2/aggregate.py
python3 keiro/bench/results/baseline-recording-v2/aggregate.py --apply
bash keiro/bench/results/baseline-recording-v2/controls.sh
```

The final original control refuses producer while reproducing every CSV. After the
measured producer estimator correction (`03e76d10`) and portable control scripts
(`4f2b4b69`), acceptance used:

```bash
bash keiro/bench/results/producer-attribution-v2/negative-control.sh
bash keiro/bench/results/baseline-recording-v2/accepted-controls.sh
```

The recording script uses the exact runner selection/settings for all five groups;
aggregation validates all raw samples before writing candidates. The first control script
also proves the named `command inbox` subset. The accepted script requires three complete
runs, recomputes every paired median from raw values and stops on any failure. The negative
control restores and rebuilds the unperturbed source before acceptance.

These scripts intentionally refuse to overwrite the retained committed evidence. A repeat
cohort must use new artifact names/directories and retain its source/environment identity;
see `keiro/bench/results/baseline-recording-v2/README.md` and the producer evidence README.
Do not overwrite historical samples or move a CSV because a comparison fails.

Expected passing summary:

```text
GUARD(command)=0
BENCH_REGRESSION=PASSED
```

A full run must contain all six guard names; a named subset is not full-gate evidence.


## Validation and Acceptance


M1/M2 are accepted by the retained observations and explicitly limited interpretation above.
M3 requires plan 321 acceptance, five raw samples, their documented aggregation, the workload
comparison for every affected CSV, and a same-recording-revision control that passes its rows.
M4 requires fresh-path statement/cost evidence and a passing producer guard; any replacement
must fail the negative control. M5 requires three consecutive inbox passes. M6 requires three
consecutive complete six-guard passes, each retained with exit status zero.

No baseline moves solely because it is red. A noisy or timed-out comparison is inconclusive,
not a pass. Routine source builds or the historical sweep do not substitute for these remaining
acceptance runs. Plan 316 remains responsible for the release-gate red/green demonstrations.


## Idempotence and Recovery


All benchmark runs use disposable migrated fixtures. Use distinct evidence directories or
sample names when rerunning; retain any sample used for a decision. Do not discard a poor
sample without recording its invalidating condition. Restore only this task's baseline edits
if an attribution is withdrawn, and reopen plan 321 for fixture defects. Upstream repositories
are read-only in this plan. No release, dependency change, or production mutation is part of
baseline recording.


## Interfaces and Dependencies


Plan `docs/plans/321-isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture.md`
is a hard prerequisite for M3–M6. It owns `keiro/bench/Main.hs`, `InboxDelegatedBench.hs`,
`ReadModelBench.hs`, and fixture/warm-up changes to `ProducerIdentityBench.hs`. This plan owns
baseline CSVs, recording evidence, and measured producer guard thresholds after that handoff.
Plan `docs/plans/316-run-the-benchmark-regression-guards-in-the-release-gate.md` owns the
runner, recipes and benchmark ADR. Preserve scenario names and its
`GUARD(name)=status` / `BENCH_REGRESSION=PASSED|FAILED` output contract.
