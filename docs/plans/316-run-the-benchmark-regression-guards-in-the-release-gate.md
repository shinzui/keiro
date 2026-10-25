---
id: 316
slug: run-the-benchmark-regression-guards-in-the-release-gate
title: "Run the benchmark regression guards in the release gate"
kind: exec-plan
created_at: 2026-10-21T12:21:07Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
master_plan: "docs/masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T12:21:07Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:24:48Z
      verdict: "approved"
      note: "Runner, recipes, release procedure, and independent gate-wiring scope agree with the tree; red/green execution evidence remains pending as documented."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:49:51Z
      mode: "update"
      note: "Make passing-run dependency explicit, reconcile release preflight, and link ADR-58 policy and remaining implementation evidence."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T05:17:09Z
      mode: "implement"
      note: "Align all guard invocations with serial fixed RTS measurement settings before recording."
---

# Run the benchmark regression guards in the release gate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, no Keiro release can be tagged without the six benchmark regression guards
having run and passed on the release commit, and the evidence travels with the release. A
maintainer runs one command, `nix develop -c just release-gate`, on a quiet machine; it runs
the correctness gate (`just verify`) and then every guard, records both exit statuses and one
line per guard inside a log under `keiro/bench/results/release-gates/`, and exits non-zero if
anything failed. The release skill names that command as the gate and requires the log in the
release commit. The guards stop being something a reviewer remembers to run by hand: REV-20
(`docs/reviews/keiro-0-20-0-21-unreleased-review.md`) found the `command` guard red across
several releases because the procedure never required it.


## Progress

- [x] M1 (2026-10-25): Full runner logs retain all six statuses, continue after a
      producer failure and return matching aggregate/process exits. The command/inbox
      subset runs exactly those two. Evidence: `keiro/bench/results/baseline-recording-v2/`
      (`control-subset.txt`, `control-full-1` through `control-full-3`, `accepted-full-1.txt`).

- [x] M2 (2026-10-25): Full refusing and green release gates run at `a4332cfe` after
      plan 315 completion. Both pass correctness and run all six guards. The deliberate
      1-ps command baseline makes only command fail (recipe exit 1); after exact restoration,
      every guard passes (recipe exit 0). Combined logs, patches and wrapper statuses are
      retained under `keiro/bench/results/release-gates/`; no partial logs are spliced.

- [x] M3 (2026-10-25): The release procedure requires the gate. `agents/skills/release/SKILL.md` step 4
      names `just release-gate`, the quiet-machine rule, the log-in-the-release-commit rule, and
      the no-re-recording rule; `docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`
      Milestone 1 lists the gate log and all MasterPlan 46 mandatory prerequisites among its preflight artifacts.
- [x] M4 (2026-10-25): ADR-58 links accepted plan 315/321 evidence and full red/green
      logs. Its policy matches the implementation; strict profile/log enforcement passes
      for all 58 ADR concepts after the final timestamp and log update.


## Surprises & Discoveries

The first full run on clean `847b395c` records `VERIFY_EXIT=0`, all six guard statuses,
`BENCH_EXIT=1`, and recipe exit 1 in
`keiro/bench/results/release-gates/20261025T053433Z-847b395c.log`.
Producer and projection failed; outbox/inbox/command/read-model passed. This proves refusal
and all-guard continuation mechanically. External solver/test activity appeared during
producer sampling, so its timings are exploratory and do not establish quiet-machine
acceptance. The later `a4332cfe` red/green cohort below supplies quiet acceptance after
the fixture, recording and producer evidence are accepted.

The initial runner fixed `-j1`/`-N2` only for producer identity; CSV guards inherited
all host capabilities. It now uses serial wall-clock measurements at `-N2` for every
guard, with a five-percent requested deviation and ten-second CSV timeout. Producer
identity retains one-percent/120-second standalone timing. Plan 315 changes its guard
quantity to median of 15 fixed alternating actual-workload ratios at the same 1.10 ceiling,
with every raw pair retained and a measured +20-ms/action refusal control. Plan 315
records CSV baselines with the same CSV runner options. A timeout or growth-budget failure remains inconclusive.



## Decision Log

- Decision: Keep `just verify` as the correctness gate and add the guards through a separate
  `release-gate` recipe rather than inside `verify`.
  Rationale: The guards take ten to fifteen minutes, are timing-sensitive, and fail under the
  load that `verify` itself produces; a developer iterating on a fix should be able to run the
  correctness gate alone, and the release is where both must pass together.
  Date: 2026-10-21
- Decision: The guard runner runs every guard and summarizes instead of stopping at the first
  failure.
  Rationale: The earlier recipe stopped at the first failing line, so REV-20's first run
  reported only the producer guard and never reached the command guard; a release gate must
  show the whole picture in one run.
  Date: 2026-10-21


Revision note (2026-10-21): Made the passing-run prerequisite explicit, reconciled release
preflight obligations, and assigned this plan sole ownership of the benchmark policy ADR.


## Outcomes & Retrospective

The release gate is demonstrated end to end at `a4332cfe`, after plan 315 completion.
`20261025T101845Z-a4332cfe.log` passes correctness and refuses a deliberately impossible
command baseline while reporting every guard. `20261025T104300Z-a4332cfe.log` then passes
correctness and all six guards on the restored tree, finishing 11:05:22 UTC. Their wrappers
retain recipe exits 1/0; both logs carry matching `VERIFY_EXIT`/`BENCH_EXIT` values. The
negative patch is retained and absent from the accepted CSV. No test or benchmark halves
were spliced, and the tested implementation does not change in the evidence commit.

The named subset and original failing full control establish selection and continuation.
Accepted plan 315/321 artifacts establish fixture isolation, bounded work, attributed
five-sample baselines and a producer comparison that still refuses deliberately added cost.
ADR-58 records these durable rules and links their demonstrated implementation. The release
skill and plan 303 require a fresh full gate on the final release candidate; this plan
implements and verifies preflight but performs no release cut.


## Context and Orientation

`justfile` at the repository root is the task runner (`just --list` shows recipes). `verify` is
the correctness gate: build, every test suite, the OKF documentation validators, the policy
scripts, and the mutation proofs. `bench-regression` runs the benchmark regression guards:
six `cabal bench keiro-bench` invocations, five of which compare the `keiro-bench` scenarios
in `keiro/bench/Main.hs` against committed baselines in `keiro/bench/baseline-*.csv` with
`tasty-bench`'s `--fail-if-slower 25`, and one of which (`producer-identity`) compares 15 alternating full legacy/deterministic
pairs for each fresh transaction shape against a 1.10 median-ratio ceiling. A "guard" is one such invocation.
Until this plan, `bench-regression` was a recipe of six lines that stopped at the first failure,
and nothing in the release procedure (`agents/skills/release/SKILL.md`) ran it; the retention
suite is the precedent for a measured workload inside the gate (ADR-48,
`docs/adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md`).

This plan's first two milestones were implemented in the session that created it:
`scripts/bench-regression.sh` runs the six guards (or a named subset), prints
`##### guard <name>` before each and `GUARD(<name>)=<status>` lines plus
`BENCH_REGRESSION=PASSED|FAILED` after all, and exits 1 if any failed; the `bench-regression`
recipe calls it and accepts guard names as arguments; the `release-gate` recipe runs
`just verify`, then `just bench-regression`, teeing both into
`keiro/bench/results/release-gates/<UTC timestamp>-<short sha>.log` with `VERIFY_EXIT=` and
`BENCH_EXIT=` lines, and exits non-zero unless both were 0. Step 4 of the release skill now
names `just release-gate` as the gate. Their accepted red/green runs and the plan 303
preflight review are retained in `keiro/bench/results/release-gates/README.md`, with
implementation evidence in [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md).

The companion plan `docs/plans/315-attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards.md`
owns the baselines and makes the guards green; this plan owns the runner, the recipes, and the
skill text, and never edits a baseline.


## Plan of Work

Milestone 1 verifies the runner. Run `nix develop -c just bench-regression` on a quiet machine
and check that the log reaches the summary with six `GUARD(...)` lines and the exit status agrees with their individual results, and that `just bench-regression command inbox` runs only
those two.

Milestone 2 verifies the release gate. Run `nix develop -c just release-gate` from a clean
tree on a quiet machine. With correctness passing and a known failing benchmark it must exit 1 with `VERIFY_EXIT=0`
and `BENCH_EXIT=1`; keep that log as the refusal demonstration. If the historical guards have
already been repaired, use an isolated temporary baseline with a deliberately impossible
ceiling, record the perturbation, and restore it before the passing run. Do not rely on an
unrelated correctness failure. Once plan 315 is Complete,
run it again and keep the passing log; the release commit for 0.22.0.0 includes it.

Milestone 3 verifies plan 303's preflight now names the release-gate log and MasterPlan 46's
mandatory completions: plans 315, 316, 317, 318, 320, and 321, plus plan 319 M3. The preflight
was amended during review remediation. Check that the release skill and plan agree; plan 319's
optional state-inspector milestones may not substitute for required legacy labelling.

Milestone 4 completes evidence for [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md), allocated during review
remediation. Do not allocate a duplicate ADR. Check its isolated/fixed-workload policy against
plan 321 evidence, and its five-sample/control and threshold rules against plan 315 evidence.
Link the accepted evidence directories and red/green gate logs, retaining the distinction
between an accepted design and demonstrated implementation. Validate the ADR bundle and
append its update log whenever the ADR timestamp advances.


## Concrete Steps

From the repository root inside `nix develop`:

```bash
just --show bench-regression
just --show release-gate
bash -n scripts/bench-regression.sh
just bench-regression command inbox      # subset, about five minutes
just bench-regression                    # all six, ten to fifteen minutes
just release-gate                        # verify then guards, about thirty minutes
tail -n 12 keiro/bench/results/release-gates/*.log
```

Example failing tail (the actual failed subset may change as plan 315 progresses):

```text
GUARD(producer-identity)=1
GUARD(outbox)=0
GUARD(inbox)=1
GUARD(command)=1
GUARD(projection)=0
GUARD(read-model)=0
BENCH_REGRESSION=FAILED
BENCH_EXIT=1
finished 2026-10-21T13:40:00Z
```

ADR validation (ADR-58 already exists):

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

M1: the summary block exists in a full-run log and the process exit status equals 1 exactly
when any `GUARD(...)` line is non-zero. M2: a release-gate log exists with both `_EXIT` lines
and the recipe's exit status follows them. M3: plan 303 names the log and every mandatory MasterPlan 46 release prerequisite. M4: `just adr-validate`
passes with ADR-58 and its accepted implementation evidence and `docs/adr/log.md` carries its entry. The behavioural proof is
the red run: with a known failing guard, `just release-gate` must refuse and identify that
guard; a separate passing run is required after plan 315 Complete.


## Idempotence and Recovery

Every recipe is safe to rerun; each `release-gate` run writes a new timestamped log and never
overwrites an earlier one. Logs are plain text and may be deleted if a run was invalid (for
example, under load), but a log that is cited by a release commit stays. If `just verify` fails
inside `release-gate`, fix the cause and rerun the whole recipe; do not splice a passing
`verify` log with a separate guard log.


## Interfaces and Dependencies

`justfile` recipes `bench-regression` and `release-gate`; `scripts/bench-regression.sh`; the
`keiro-bench` benchmark and `tasty-bench` options; `agents/skills/release/SKILL.md` step 4;
`docs/plans/303-...` Milestone 1; the OKF ADR bundle under `docs/adr/`. The output contract
other work depends on is the `GUARD(<name>)=<status>` and `BENCH_REGRESSION=` lines, which
plan 315 cites as acceptance and the release skill reads. No prerequisite blocks wiring or the red demonstration. M2 passing-run acceptance requires
plan 315 Complete. That prerequisite and all four milestones are now accepted, so this
plan is Complete. The milestone dependency in the MasterPlan registry does not cycle
through the independently available runner.
