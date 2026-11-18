---
id: 346
slug: evaluate-adopting-heni-for-keiro-dsl-mutation-testing
title: "Evaluate adopting heni for keiro-dsl mutation testing"
kind: exec-plan
created_at: 2026-11-18T17:46:25Z
intention: "intention_01m7qw8mereb084cd8yhvnz7zg"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-18T17:46:25Z
---

# Evaluate adopting heni for keiro-dsl mutation testing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is deliberately deferred. It records how to decide, with evidence, whether
keiro-dsl's hand-written mutation scripts should move to heni. Nothing is adopted until
the decision gate after Milestone 1 says so.


## Purpose / Big Picture

keiro-dsl proves many of its guarantees with mutation scripts. A mutation script makes
a deliberate fault, such as editing a witness, a generated module, or generator source.
It then rebuilds and requires a named test to fail with a specific message. The
recurring claim is "this test would catch that fault", and a mutation that cannot fail
proves nothing.

The 26 scripts under `keiro-dsl/test/*mutation*.sh` each reimplement backup, in-place
editing, restore traps, build and test invocation, and output matching in Bash. Plan 337
found the failure that this design allows. A `perl -pi` pattern in
`keiro-dsl/test/behavior-complete-mutation-test.sh` stopped matching when `7b06bc52`
renamed `layoutOutgoingIndex entry` to `(.outgoingIndex) entry`. The substitution
silently changed nothing, so the mutation could never go red. Nothing reported it for
three months. Plan 337's follow-up added an `assert_changed` guard to that one script only.

heni (`mori://shinzui/heni`) is the user's mutation-testing library and CLI. It first
proves the unchanged baseline passes. It then applies checked edits to a disposable
copy, treats an edit whose `old` text is absent as an invalid mutation rather than a
pass, and classifies each case as `caught`, `survived`, or invalid, with a retained
JSON report. Adopting it would make the stale-pattern failure impossible by
construction, stop scripts from editing the real checkout, and replace ad hoc output
greps with declared witnesses.

When this plan is complete, a contributor runs `heni run` against a checked-in manifest
instead of a Bash script and gets a report of caught cases. A stale mutation fails
loudly. The `just` recipes in `just verify` invoke heni, and the old scripts are gone.
If the measured cost or heni's maturity rules adoption out, the plan instead closes with
a recorded decision. It then extends the `assert_changed` guard to every remaining
script so the known failure class is still closed.


## Progress

- [ ] Milestone 0: heni's release status, distribution route, and dev-shell
  availability are verified and recorded, and the user has approved the dependency route.
- [ ] Milestone 1: `keiro-dsl/test/behavior-complete-mutation-test.sh` is ported to a
  heni manifest with the same 14 cases and witnesses. Parity, stale-edit detection, and
  wall-clock cost are measured, and the adopt/stop decision is recorded.
- [ ] Milestone 2 (only if adopted): the four scripts invoked by `just verify` run
  through heni and the replaced scripts are deleted.
- [ ] Milestone 3 (only if adopted): the remaining scripts are migrated or explicitly
  retained with reasons. Otherwise (if stopped), every remaining script carries the
  `assert_changed` guard.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Evaluate on one script before committing to a migration, and keep a
  non-heni fallback that closes the same failure class.
  Rationale: heni is version 0.1.0.0, unreleased and experimental. Its disposable-copy
  model may make keiro-dsl's Cabal builds far slower than today's in-place incremental
  rebuilds. The guarantee at stake, that every mutation can fail, is obtainable either way.
  Date: 2026-11-18

- Decision: Use `keiro-dsl/test/behavior-complete-mutation-test.sh` as the spike.
  Rationale: it is the script whose mutation silently rotted. Its 14 cases cover all
  three edit targets keiro uses (hand-owned witness files, committed generated modules,
  and generator source that forces a keiro-dsl rebuild), plus two witness styles (a
  report command and a focused hspec test). heni already ships a migration example
  modeled on `keiro-dsl/test/history-dependent-holes-mutation-test.sh`, so that simpler
  script would teach less.
  Date: 2026-11-18


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**Terms.** A *mutation* is a deliberate source edit that should break a guarantee. A
*witness* is the observable failure that proves a test caught it, usually an exit status
plus an exact output fragment such as `edge-attribution`. *Caught* means the mutated run
failed with the witness. *Survived* means it passed, which is a gap in the tests. A
*stale* or *invalid* mutation is one whose edit no longer applies; it proves nothing
either way.

**Keiro's scripts today.** `git ls-files '*mutation*.sh'` lists 26 Bash files in
`keiro-dsl/test/`, from 32 to 196 lines, plus four 4-line case files under
`keiro-dsl/test/conformance-nominal-scalars/mutations/`. The typical shape is the one in
`keiro-dsl/test/behavior-complete-mutation-test.sh`:

1. Copy each target file to a `mktemp -d` backup and install an `EXIT` trap that
   restores them.
2. For each case, edit a file in the real checkout with `sed -i` or `perl -0pi`.
3. Run `cabal run -v0 keiro-dsl-behavior-complete-report -- --format=json`, or a focused
   `cabal test keiro-dsl-test --test-options='--match …'`. Require a nonzero exit and
   `grep -F` an expected code.
4. Restore that file before the next case.

Because edits happen in place, Cabal's incremental build in the repository's
`dist-newstyle` keeps each case fast. The cost is that an interrupted run can leave the
checkout mutated until the trap runs, and that nothing except the guard added in plan
337 checks that an edit applied.

The `justfile` runs four scripts inside `just verify`, through the `_verify` dependency
list: `initial-hole-proof`, `process-reaction-proof`,
`mapped-register-construction-proof`, and `mapped-structural-enum-equality-proof`. Their
scripts are `history-dependent-holes-mutation-test.sh`,
`process-reaction-mutation-test.sh`, `mapped-register-construction-mutation-test.sh`,
and `mapped-structural-enum-equality-mutation-test.sh`. The other 22 scripts run only
when someone remembers to run them. That is how the behavior-complete script rotted
unnoticed.

**heni.** heni is `mori://shinzui/heni`, checked out at `/Users/shinzui/Keikaku/bokuno/heni`
according to `mori registry show shinzui/heni --full`. Its packages are `heni` (the
framework-neutral `Test.Heni` library), `heni-cli` (the `heni` executable),
`heni-hspec`, and `heni-tasty`. Its README states version 0.1.0.0 is unreleased and its
lifecycle is Experimental.

The CLI reads a strict JSON manifest, `schemaVersion` 1. A manifest has named `commands`
(literal argv plus `timeoutSeconds`) and `cases`. Each case has `edits`, for example
`{"kind": "replace", "path": …, "old": …, "new": …}`, names its build and test commands,
and declares an `expect` such as
`{"kind": "diagnostic", "stage": "test", "exitCode": 1, "outputContains": "…"}`.

The commands are `heni check <manifest>`, `heni run <manifest> [--case ID] --output DIR`,
and `heni report DIR/report.json`. `run` exits 0 for caught, 1 for survived, and 2 for
configuration or infrastructure failure. heni snapshots the source, including dirty and
untracked files, runs in a disposable copy, and never modifies the original checkout.

Its build-reuse guide (`docs/user/build-reuse-guide.md` in the heni project; the
artifact URI is pending) states that there is no generic safe Cabal incremental reuse.
Retained build directories need a consumer-written content-observation verifier. This is
the main cost risk for keiro, because a fresh keiro-dsl build is many minutes. heni's
`docs/user/migration-guide.md` lists a "generated code" example
(`examples/migrations/generated-code/heni.json`) modeled on keiro-dsl's
history-dependent-holes script.

`mori://shinzui/shikigami` already declares a dependency on `heni-cli`
(`mori://shinzui/shikigami/packages/shikigami-core`). Consult it for how an adopter
installs and pins heni.

**ADRs.** No ADR in `docs/adr/` governs mutation tooling or falsification scripts. The
mutation scripts are evidence for guarantees recorded elsewhere, for example
[ADR-17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
for finite witness evidence. Migrating them must keep that evidence at the same strength.
If adoption is decided, record the policy "every keiro-dsl mutation is declared in a
manifest whose edits must apply" as a new ADR.


## Plan of Work

**Milestone 0: prerequisites.** This milestone writes no code, only facts and one user
decision. Check whether `heni` and `heni-cli` are published: query the Hackage package
pages and the upstream tags of the `shinzui/heni` repository, and do not trust the
local Mori corpus for this. Read the heni dev-shell and flake files
(`flake.module.nix.example` in the heni project) and shikigami's integration to see how
an adopter gets the `heni` executable.

Then ask the user to choose the route. A released `heni-cli` would come from the Cabal
index or nixpkgs. An unreleased one would be a pinned flake input added to keiro's
`flake.module.nix` (`haskellProject.extraDevPackages`, beside `z3`). Do not add an
unreleased dependency without that choice. Acceptance: the release state, the route,
and the exact pin are recorded in the Decision Log, and `nix develop -c heni --help`
works on a branch if a route was chosen.

**Milestone 1: spike and decision gate.** Translate
`keiro-dsl/test/behavior-complete-mutation-test.sh` into a manifest. The proposed path
is `keiro-dsl/test/mutations/behavior-complete.heni.json`; keep the existing script
until the gate passes. The cases are:

- one case per `expect_red` and `expect_focused_test_red` block, 14 in all, each with
  the same edit and the same expected fragment;
- the "obsolete legacy hook" step, which expects success rather than a failure.

Each `sed` or `perl` edit becomes a `replace` edit with literal `old` and `new` text. If
a regex-only edit has no literal equivalent, prefer an explicit checked patch, and
record it.

Build commands should be literal argv, for example `cabal build
keiro-dsl:exe:keiro-dsl-behavior-complete-report`, with test commands to match. Fill in
the timeouts once the baseline build has been measured.

Then measure three things:

1. **Parity:** every case is `caught` with the same witness the script greps for.
2. **Stale detection:** reintroduce the old `layoutOutgoingIndex entry` text as the
   `old` of the edge-index case. heni must report an invalid mutation with exit 2,
   never `caught` or `survived`.
3. **Cost:** compare the wall-clock time of `heni run` for the whole manifest with the
   current script, both inside `nix develop`, cold and warm.

If cost is prohibitive, investigate in this order:

- whether heni's opt-in baseline sharing applies;
- whether pointing the copy's Cabal builds at a shared store and build directory is
  sound under heni's isolation contract;
- whether a keiro-owned build-reuse verifier, following heni's guide, is worth writing.

Record the verdict. Adopt if parity and stale detection hold and the total cost of the
four `just verify` scripts would grow by no more than the bound the user accepts at this
gate. Otherwise stop: go straight to the fallback in Milestone 3 and record why.

**Milestone 2: the `just verify` scripts (only if adopted).** Port the four scripts
behind `initial-hole-proof`, `process-reaction-proof`,
`mapped-register-construction-proof`, and `mapped-structural-enum-equality-proof`.
Point each `justfile` recipe at `heni run` with an output directory under the
repository's ignored build area. Run the old script and the new manifest side by side
once and compare case-by-case verdicts. Then delete the script and add the policy ADR.

**Milestone 3: the rest.** If adopted, migrate the remaining scripts in small batches
(one family per commit, such as `mapped-*`, `structural-*`, `process-*`, or `router`,
`workflow`, `replay`). Any script that heni cannot express cleanly stays as Bash, with
its reason recorded and with the guard below. If stopped, add an `assert_changed`-style
guard to every remaining script instead: compare each mutated file with its backup
after the edit, and fail when they are identical. Plan 337's version in
`keiro-dsl/test/behavior-complete-mutation-test.sh` is the template. Either way, decide
whether the 22 scripts outside `just verify` should join a scheduled or `verify`-adjacent
gate, so they cannot silently rot again.


## Concrete Steps

Run everything from the keiro repository root inside the Nix shell, per `AGENTS.md`.

Milestone 0 discovery:

```bash
mori registry show shinzui/heni --full
mori registry docs shinzui/heni
mori registry dependents shinzui/heni --packages
cabal list --simple-output heni-cli   # empty output means not in the local index
```

Current baseline for the spike (record the elapsed time):

```bash
time nix develop -c bash keiro-dsl/test/behavior-complete-mutation-test.sh
```

Expected tail: `PASS: all behavior mutations were caught and exact files restored`.

Milestone 1, once the CLI is available in the shell:

```bash
nix develop -c heni check keiro-dsl/test/mutations/behavior-complete.heni.json
time nix develop -c heni run keiro-dsl/test/mutations/behavior-complete.heni.json --output .heni-runs/behavior-complete
nix develop -c heni report .heni-runs/behavior-complete/report.json
```

Expect exit 0 and every case `caught`. For the stale-detection check, write a second
manifest containing only the edge-index case with the old `layoutOutgoingIndex entry`
text, and expect exit 2. After every run, `git status --short` must show no changes
from heni, because it works in a copy.


## Validation and Acceptance

Milestone 1 is accepted when all of these hold:

- the manifest reproduces every case of the script, with each case `caught` and its
  report showing the same witness fragment;
- a deliberately stale edit is rejected as invalid (exit 2), not counted as caught;
- `git status` is unchanged by the heni run;
- the cold and warm timings of both runners are recorded beside the adopt/stop decision.

Milestone 2 is accepted when:

- `nix develop -c just verify` passes with the four recipes running heni;
- a side-by-side run showed identical per-case verdicts before the scripts were deleted;
- reverting one guarded fix in the generator makes the corresponding heni case
  `survived`, exit 1, and fails `just verify`. This shows the gate still bites.

Milestone 3 is accepted when every file in `git ls-files '*mutation*.sh'` is either gone
(migrated) or contains the guard. A deliberately stale edit in a retained script exits
nonzero.

Guarantees and performance, stated per guarantee:

- **Mutation evidence:** no mutation case is dropped and no witness is loosened. Compare
  case lists and witness strings before and after each migration.
- **Isolation:** heni never edits the checkout.
- **Performance:** runtime and generated code are untouched, so the only cost is CI
  wall-clock time. Measure that with `time` on the affected `just` recipes, not inferred.
  The `keiro-bench` release-gate guards do not cover this path.


## Idempotence and Recovery

heni runs are repeatable and write only to their `--output` directory; delete it to
rerun cleanly. A retained shell script can be interrupted and leave mutated files, so
run `git status --short` and `git checkout -- <file>` for any file listed in that
script's backup set. Keep each old script until its manifest has matched it side by
side, so any migration step can be reverted by restoring the script and its `just`
recipe. A dependency pin added in Milestone 0 can be removed from `flake.module.nix`
without affecting any other component.


## Interfaces and Dependencies

- **`heni-cli`** (`mori://shinzui/heni/packages/heni-cli`): the `heni` executable and its
  manifest schema version 1. Verify the released version and its registry metadata
  before pinning, as the global instructions require; the local Mori corpus may lag
  upstream. Optional: `heni-hspec` (`mori://shinzui/heni/packages/heni-hspec`) can give
  named-test evidence for focused hspec cases such as `keiro-dsl-test --match …`. Adopt
  it only if plain output-fragment witnesses prove too weak.
- **keiro build entry points used as manifest commands:**
  - the executable `keiro-dsl:exe:keiro-dsl-behavior-complete-report`;
  - the test suite `keiro-dsl:test:keiro-dsl-test`;
  - the `keiro-dsl scaffold` CLI;
  - the `justfile` recipes listed above.
- **No library API, generated code, wire format, or runtime path of keiro changes.**
