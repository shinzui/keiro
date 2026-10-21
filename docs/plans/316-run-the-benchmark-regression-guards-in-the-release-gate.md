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

- [ ] M1: `just bench-regression` runs every guard even after one fails and ends with a
      per-guard summary. `scripts/bench-regression.sh` and the recipe are committed; acceptance
      is one full run on a quiet machine whose log ends in six `GUARD(name)=status` lines and a
      `BENCH_REGRESSION=` line, with the exit status matching the summary.
- [ ] M2: `just release-gate` runs `just verify` then the guards into one retained log and
      exits non-zero when either half fails. The recipe is committed; acceptance is one run
      whose log under `keiro/bench/results/release-gates/` carries `VERIFY_EXIT=`,
      `BENCH_EXIT=`, and the guard lines, and whose exit status is 1 while plan 315's guards are
      still red (the demonstration that the gate stops) and 0 once they are green.
- [ ] M3: The release procedure requires the gate. `agents/skills/release/SKILL.md` step 4
      names `just release-gate`, the quiet-machine rule, the log-in-the-release-commit rule, and
      the no-re-recording rule; `docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`
      Milestone 1 lists the gate log among its preflight artifacts.
- [ ] M4: The rule is durable. An ADR records that benchmark guards are a release gate, how a
      baseline is recorded, and when it may move.


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`justfile` at the repository root is the task runner (`just --list` shows recipes). `verify` is
the correctness gate: build, every test suite, the OKF documentation validators, the policy
scripts, and the mutation proofs. `bench-regression` runs the benchmark regression guards:
six `cabal bench keiro-bench` invocations, five of which compare the `keiro-bench` scenarios
in `keiro/bench/Main.hs` against committed baselines in `keiro/bench/baseline-*.csv` with
`tasty-bench`'s `--fail-if-slower 25`, and one of which (`producer-identity`) compares two
scenarios in the same process against a 1.10 ratio ceiling. A "guard" is one such invocation.
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
names `just release-gate` as the gate. What remains is to run them for acceptance (the machine
was busy with plan 315's sweep when they were written), to update plan 303's preflight, and to
write the ADR.

The companion plan `docs/plans/315-attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards.md`
owns the baselines and makes the guards green; this plan owns the runner, the recipes, and the
skill text, and never edits a baseline.


## Plan of Work

Milestone 1 verifies the runner. Run `nix develop -c just bench-regression` on a quiet machine
and check that the log reaches the summary with six `GUARD(...)` lines even though some guards
fail today, that the exit status is 1, and that `just bench-regression command inbox` runs only
those two.

Milestone 2 verifies the release gate. Run `nix develop -c just release-gate` from a clean
tree on a quiet machine. Today it must exit 1 with `VERIFY_EXIT=0` and `BENCH_EXIT=1`; keep
that log as the demonstration that the gate refuses a red guard. Once plan 315 is complete,
run it again and keep the passing log; the release commit for 0.22.0.0 includes it.

Milestone 3 updates plan 303's Milestone 1 preflight list to name the release-gate log as a
required artifact and to point at the skill text, so the person cutting the release reads the
rule in both places.

Milestone 4 writes the ADR. Allocate the handle with `okf id next docs/adr --profile
docs/adr/profile.dhall ADR`, create the record per `agents/skills/exec-plan/ADR.md`, and state:
the six guards and their baselines are a release gate run through `just release-gate`; a
baseline is recorded from five serial runs on a quiet machine with a README under
`keiro/bench/results/` naming machine, GHC, PostgreSQL, and commit; a baseline moves only with
an attributed cause recorded in such a README, never to make a guard pass; a guard that fails
under load is rerun alone before it counts. Validate with the strict profile command and add
the log entry with `okf log add`.


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

Expected tail while plan 315 is open:

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

ADR allocation and validation:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

M1: the summary block exists in a full-run log and the process exit status equals 1 exactly
when any `GUARD(...)` line is non-zero. M2: a release-gate log exists with both `_EXIT` lines
and the recipe's exit status follows them. M3: plan 303 names the log. M4: `just adr-validate`
passes with the new record and `docs/adr/log.md` carries its entry. The behavioural proof is
the red run: with plan 315 open, `just release-gate` must refuse, and the log must say which
guard refused it.


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
plan 315 cites as acceptance and the release skill reads. No parent milestone must be accepted
before this plan begins; its green outcome depends on plan 315.
