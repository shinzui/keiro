---
id: 281
slug: restore-a-green-verify-gate-for-the-0-17-0-0-candidate
title: "Restore a green verify gate for the 0.17.0.0 candidate"
kind: exec-plan
created_at: 2026-09-16T18:25:28Z
intention: "intention_01m2nqd9hre9gbhw37aagtf066"
master_plan: "docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T18:25:28Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-17T23:10:57Z
      mode: "implement"
      note: "Refreshed EP-1 against nominal-ID changes and validated completed milestones"
---

# Restore a green verify gate for the 0.17.0.0 candidate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The repository's release procedure (`agents/skills/release/SKILL.md`) forbids tagging or
uploading a release while `just verify` fails. At commit `fa6b66b2`, the 0.17.0.0 candidate,
`just verify` exits 1, and the release review `docs/reviews/keiro-0-17-release-readiness.md`
(REV-17) traced that exit to three unrelated causes. After this plan, a maintainer can run
`just verify` from a clean checkout of the candidate and watch it exit 0, with every test suite,
policy script, and documentation validator passing, so the release can proceed to the changelog,
blueprint, and bump work that the sibling plans own.

The three causes are independent and each is small: two tests in `keiro-dsl/test/Main.hs` ask
GHC for the `keiki` library by name, which is ambiguous whenever the Cabal store holds two builds
of the same `keiki` version; two generated inventory documents under `keiro-dsl/` were not
regenerated after the last commit that moved source lines; and five frozen generated files
under `keiro-dsl/test/` were edited by hand with a trailing newline that the generator never
emits. None of them is a defect in shipped library code. All of them block the tag.


## Progress

- [x] (2026-09-17T23:09:55Z) Milestone 1: both `keiro-dsl-test` examples that compile generated
      code pass `-package-id` for `keiki`; the targeted two-example run reports 0 failures.
- [x] (2026-09-17T23:09:55Z) Milestone 2: the current record migration manifests are generated
      from the expanded nominal-ID tree and `just record-migration-policy` exits 0.
- [x] (2026-09-17T23:09:55Z) Milestone 3: all 47 registered conformance invocations reproduce
      the committed corpus exactly and `just conformance-corpus-policy` exits 0.
- [ ] Milestone 4: a full `just verify` from a clean tree logs `EXIT=0`, and `git status
      --short` is empty afterwards.


## Surprises & Discoveries

- Discovery: Commits made after this plan was authored already implemented the two package-id
  fixes (`7d235121`) and regenerated the record migration manifests (`acda7fc0`) as part of the
  nominal-ID initiative. That initiative also added tests and candidate corpora, so the planned
  total of 743 examples and the expectation that regeneration touches exactly five files no
  longer describe the current tree.
  Evidence: the two named examples passed on 2026-09-17; `just record-migration-policy` exited 0;
  `just conformance-corpus-policy` reported `corpus: 47 of 47 invocations selected` and
  `conformance corpus: ok` without changing tracked files.


## Decision Log

- Decision: Fix the two tests to select `keiki` by the install plan's package id rather than
  deleting the second `keiki-0.9.1.0` unit from the Cabal store.
  Rationale: Deleting the stray store unit makes the gate pass on one machine today and fails
  again the next time any solve on that machine builds `keiki-0.9.1.0` against a different
  dependency hash. Selecting by id is what the same two tests already do for `keiro-core`, and
  it removes the dependence on store state entirely.
  Date: 2026-09-16
- Decision: Keep the comment-text change that commit da5e2469 made to the generated Language 4
  `QueuePolicy.hs` output, and regenerate the corpora from the current generator rather than
  reverting the generator's comment to the 0.16.0.0 wording.
  Rationale: The new comment is already in the five committed corpus files and in every other
  generated queue policy; it changes no behavior, no exported name, and no identity. Reverting it
  would trade a comment-only diff in frozen output for a second edit to `Scaffold.hs` and a
  second corpus regeneration. The change must nevertheless be disclosed in
  `keiro-dsl/CHANGELOG.md`, because that changelog currently says published languages' generated
  output is unchanged. That disclosure belongs to
  `docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md`;
  this plan does not edit changelogs.
  Date: 2026-09-16
- Decision: Regenerate the record migration manifests rather than editing them by hand.
  Rationale: The only drift is source line numbers and one inventory count, and the generator is
  the sole authority over these files; hand edits would drift again at the next line move.
  Date: 2026-09-16


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Keiro is a Cabal multi-package Haskell workspace. `just verify` (recipe in `Justfile`, line 15)
is the canonical release gate: it runs `process-compose-check`, the `jitsurei` example,
`haskell-verify` (which is `haskell-build`, that is `cabal build all`, followed by
`haskell-test`, which runs each package's test suites in turn), the OKF documentation validators,
several policy scripts, and finally `cabal test keiro-migrations-test`. Recipes run in the
order they are listed after the colon on line 15, and the first failing recipe stops the run.

Three recipes fail at the candidate commit.

The first is `haskell-test`, which runs `cabal test keiro-dsl:tests`. Two examples in
`keiro-dsl-test` fail with the same GHC error:

```text
error: [GHC-45102]
    Ambiguous module name ‘Keiki.Shape’.
    it was found in multiple packages: keiki-0.9.1.0 keiki-0.9.1.0
```

The examples are "ID domain keeps the raw constructor outside the compiled public module
surface" and "structural scaffold fresh binding skeletons compile at the application boundary".
Both scaffold a service into a temporary directory and then shell out to `cabal exec
--enable-tests -- ghc ...` to type-check the generated Haskell with `-fno-code`. The two calls
to `readProcessWithExitCode "cabal" [...]` are at `keiro-dsl/test/Main.hs` line 2996 and line
9002. Each argument list passes `"-package-id", keiroCorePackageId` for `keiro-core`, where
`keiroCorePackageId` comes from the helper `activeCabalPackageId "keiro-core"`, and then passes
`"-package", "keiki"` for `keiki`. The helper `activeCabalPackageId` (defined at
`keiro-dsl/test/Main.hs` line 12787) opens `dist-newstyle/cache/plan.json`, Cabal's record of the
current install plan, and returns the single `id` of the entry whose `pkg-name` matches and whose
`component-name` is `lib`, failing the test if there is not exactly one.

The difference matters because `cabal exec` writes a GHC package environment file that exposes
the whole Cabal store package database (`~/.cabal/store/ghc-9.12.4-8bff/package.db`) as well as
the plan's package ids. A store can hold several builds of the same package version, each
keyed by a hash of its own dependency closure. On the reviewing machine `ghc-pkg` lists
`keiki-0.9.1.0` twice, as `kk-0.9.1.0-0e5dc76b` and `kk-0.9.1.0-28a60311`, differing in the
hashes of `sbv`, `profunctors`, `nothunks`, and `cryptohash-sha256`; `plan.json` contains only
`kk-0.9.1.0-28a60311`. Asking GHC for `-package keiki` exposes both and GHC refuses to choose.
A one-line probe module importing `Keiki.Shape` reproduced the error under `-package keiki` and
compiled under `-package-id kk-0.9.1.0-28a60311`. The tests, their invocation, and the store
state all predate the 0.17.0.0 cycle, so this is a fragility in the gate, not a regression in
shipped code, but the release procedure still requires the gate to pass.

The second failing recipe is `record-migration-policy`, which runs
`python3 scripts/generate-record-migration-manifests.py --check`. That script inventories every
record field in the `keiro-dsl` package and in the generated conformance corpora and writes two
Markdown documents, `keiro-dsl/record-field-migration-0.15.md` and
`keiro-dsl/generated-haskell-edition-idiomatic-v2.md`; with `--check` it instead compares what
it would write against the committed files and exits 1 with `stale record migration manifest:
<path>` on any difference. The committed files were last regenerated at commit 987f8f92. Commit
da5e2469 later added lines to `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and to the hand-owned file
`keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs`
without regenerating, so every inventoried row after those insertions now carries a stale line
number (for example `Scaffold.hs:7409` where the field is now at `Scaffold.hs:7410`) and the
generated-edition document's field-label count is 14,462 where the tree now has 14,464.

The third failing recipe is `conformance-corpus-policy`, which runs
`scripts/check-conformance-corpus.sh`, which runs `cabal run -v0 keiro-dsl-corpus-regen --
check`. The corpus-regen tool (`keiro-dsl/tools/corpus-regen/src/Main.hs`) first refuses to run
if any corpus path is uncommitted (it prints "conformance corpus requires clean corpus paths
before scaffolding" and exits 1), then re-scaffolds every registered conformance corpus with the
freshly built `keiro-dsl` executable, and in check mode finally requires `git status` and `git
diff` over the corpus paths to be empty, printing "conformance corpus drifted after regeneration;
review and commit the generated diff" otherwise. Commit da5e2469 edited five committed corpus
files by hand instead of regenerating them:

```text
keiro-dsl/test/conformance-queue/Generated/HospitalCapacity/ReservationWork/QueuePolicy.hs
keiro-dsl/test/conformance-queue-runtime/Generated/HospitalCapacity/ReservationWork/QueuePolicy.hs
keiro-dsl/test/conformance-dispatch-full/Generated/HospitalCapacity/ReservationWork/QueuePolicy.hs
keiro-dsl/test/conformance-mapped-queue/Generated/MappedQueue/MappedJobs/QueuePolicy.hs
keiro-dsl/test/conformance-projection-catalog/Generated/CatalogDemo/QualificationJobs/QueuePolicy.hs
```

The hand edit applied the generator's new comment text correctly but also added a trailing
newline. The generator joins its output lines with `T.intercalate "\n"` and ends
`emitQueuePolicy` on the last disposition row, so it never writes a final newline. After
regeneration each file differs from the committed version by exactly one hunk, `\ No newline at
end of file`, and the check fails. These five corpora are Language 4 conformance corpora. ADR-16,
`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`, is why they
are frozen: once a language version is released, its parser and generated output are not widened
or rewritten, and the corpus check exists to prove byte-for-byte that the generator still
produces what is committed. The comment-text change in da5e2469 is therefore a real, if
comment-only, change to published-language output; the Decision Log above records that it is
kept and must be disclosed by the changelog plan.

No ADR governs the gate's mechanics themselves. The two later plans that also regenerate corpora,
`docs/plans/284-gate-ordering-fifo-heads-to-language-6.md` and
`docs/plans/285-harden-the-language-6-reaction-candidate-before-it-is-published.md`, should run
after this plan has landed or rerun `just corpus-regen` themselves before their own gate runs.


## Plan of Work

### Milestone 1: select `keiki` by package id in the two compile tests

At the end of this milestone the two failing examples pass regardless of how many `keiki`
builds the store holds, because they name the exact unit the install plan uses.

In `keiro-dsl/test/Main.hs`, in the example at line 2996 ("ID domain keeps the raw constructor
outside the compiled public module surface"), add a second helper call immediately after
`keiroCorePackageId <- activeCabalPackageId "keiro-core"`:

```haskell
        keikiPackageId <- activeCabalPackageId "keiki"
```

and replace the two consecutive list elements `"-package", "keiki",` with `"-package-id",
keikiPackageId,`. Make the identical change in the example at line 9002 ("structural scaffold
fresh binding skeletons compile at the application boundary"). No other argument changes; the
`-package-id keiroCorePackageId` pair stays as it is. The helper already handles the failure
modes (no plan file, zero or several matching ids) with an `expectationFailure`, so no new error
handling is needed.

Then run the two examples on their own and the whole suite. Acceptance is 2 examples, 0 failures
for the targeted run and 743 examples, 0 failures for the suite.

### Milestone 2: regenerate the record migration manifests

At the end of this milestone `just record-migration-policy` exits 0. Run the generator without
`--check` from the repository root. It rewrites `keiro-dsl/record-field-migration-0.15.md` and
`keiro-dsl/generated-haskell-edition-idiomatic-v2.md`. Inspect the diff: it must consist only of
line-number changes in the `Scaffold.hs` rows, the inventory count line, and the
`WorkqueueJob.hs` rows in the hand-owned section. Any other row means the generator is seeing
a source change that this plan did not expect; stop and record it under Surprises & Discoveries
before continuing. Commit the two files.

### Milestone 3: regenerate the frozen queue corpora

At the end of this milestone the five `QueuePolicy.hs` files are byte-identical to what the
generator emits and `just conformance-corpus-policy` exits 0. Run `just corpus-regen` from the
repository root with a clean corpus (the tool refuses to start otherwise). It re-scaffolds every
registered corpus; the only resulting diff must be the five files above, each showing the single
`\ No newline at end of file` hunk. Commit them. The check mode refuses uncommitted corpus paths,
so the commit is part of the milestone, not a follow-up.

### Milestone 4: run the whole gate from a clean tree

At the end of this milestone there is a log proving `just verify` exited 0 at the fixed commit.
Run the gate in the background with the exit status written into the log, because the gate
routinely exceeds ten minutes and a foreground timeout would kill it. After it finishes,
confirm `git status --short` prints nothing: the `process-reaction-proof` recipe's mutation
script (`keiro-dsl/test/process-reaction-mutation-test.sh`) rewrites
`keiro-dsl/test/conformance-process-reactions` and `keiro-dsl/test/conformance-process-timers`
in place and restores them by re-scaffolding on exit, and its hydration script builds `keiro`
with the `reaction-hydration-probe` flag in a temporary `--builddir` so the main build is not
disturbed. A dirty tree after the run means a restore was skipped and must be investigated.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro` on the
reviewing machine; substitute your checkout path.

Milestone 1. Edit the two argument lists as described, then:

```bash
cabal test keiro-dsl-test --test-show-details=direct \
  --test-options='--match "/ID domain/keeps the raw constructor outside the compiled public module surface/" --match "/structural scaffold/fresh binding skeletons compile at the application boundary/"'
```

Expected tail of the output:

```text
  keeps the raw constructor outside the compiled public module surface [✔]
  fresh binding skeletons compile at the application boundary [✔]

Finished in ... seconds
2 examples, 0 failures
```

Then the whole suite:

```bash
cabal test keiro-dsl-test --test-show-details=direct 2>&1 | tail -3
```

Expected:

```text
743 examples, 0 failures
Test suite keiro-dsl-test: PASS
```

Commit with a Conventional Commits message and the trailers this initiative requires:

```text
fix(dsl-test): select keiki by package id when compiling generated code

Two keiro-dsl-test examples asked GHC for keiki by name through cabal exec,
which is ambiguous whenever the Cabal store holds two builds of the same
keiki version. Resolve the id from the install plan, as the tests already do
for keiro-core.

MasterPlan: docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md
ExecPlan: docs/plans/281-restore-a-green-verify-gate-for-the-0-17-0-0-candidate.md
Intention: intention_01m2nqd9hre9gbhw37aagtf066
```

Milestone 2:

```bash
python3 scripts/generate-record-migration-manifests.py
git diff --stat -- keiro-dsl/record-field-migration-0.15.md keiro-dsl/generated-haskell-edition-idiomatic-v2.md
just record-migration-policy
```

Expected: the diff stat shows both files changed (11 line-number rows in the first, about four
lines in the second at the time of writing), and the policy prints nothing and exits 0. Commit
the two files with type `docs(dsl)` and the same three trailers.

Milestone 3:

```bash
git status --short -- keiro-dsl/test   # must print nothing before regenerating
just corpus-regen
git status --short -- keiro-dsl/test
git diff -- keiro-dsl/test | grep -c 'No newline at end of file'
```

Expected: exactly the five `QueuePolicy.hs` paths listed in Context and Orientation are modified,
and the count is 5. Commit them with type `test(dsl)` and the three trailers, then:

```bash
just conformance-corpus-policy
```

Expected last line:

```text
conformance corpus: ok
```

Milestone 4:

```bash
git status --short          # must print nothing
LOG=/tmp/keiro-verify-$(date -u +%Y%m%dT%H%M%SZ).log
( just verify > "$LOG" 2>&1; echo "EXIT=$?" >> "$LOG" ) &
```

When the background job finishes:

```bash
grep -E '^EXIT=' "$LOG"
grep -E 'examples, [0-9]+ failures' "$LOG" | sort | uniq -c
git status --short
```

Expected: `EXIT=0`, every line ends in `0 failures` (including `743 examples, 0 failures` for
`keiro-dsl-test`, `694 examples, 0 failures` for `keiro-test`, and `79 examples, 0 failures, 2
pending` for `keiro-pgmq-test`), and `git status --short` prints nothing.


## Validation and Acceptance

The plan is complete when all of the following are observed on the fixed commit. First,
`cabal test keiro-dsl-test` reports 743 examples and 0 failures, and the two previously failing
examples pass even on a machine whose store lists `keiki-0.9.1.0` twice (check with `ghc-pkg
--package-db ~/.cabal/store/ghc-9.12.4-*/package.db list | grep keiki`; two entries prove the
fix is exercised). Second, `just record-migration-policy` exits 0. Third, `just
conformance-corpus-policy` prints `conformance corpus: ok`. Fourth, a full `just verify` logs
`EXIT=0` and leaves the working tree clean. Fifth, `git diff keiro-0.16.0.0..HEAD -- keiro-dsl/test`
restricted to the five `QueuePolicy.hs` files shows the comment change and no trailing newline,
that is, the committed bytes equal the generator's bytes.


## Idempotence and Recovery

Every step is repeatable. Rerunning the generator or `just corpus-regen` on an already-fixed
tree produces no diff. If `just corpus-regen` reports that corpus paths are dirty, either commit
the intended change first or discard stray edits with `git checkout -- keiro-dsl/test` before
retrying; do not use `--allow-dirty`, which exists for local iteration and defeats the check. If
`just verify` fails on an unrelated suite while you are working, read the failure before
retrying: the process-reaction proof needs PostgreSQL through process-compose, and a dirty tree
after the run points at the mutation script's restore step. If Milestone 1's targeted run still
reports the ambiguity, confirm that `activeCabalPackageId "keiki"` resolved a single id by
inspecting `dist-newstyle/cache/plan.json` for entries with `"pkg-name": "keiki"`.


## Interfaces and Dependencies

This plan changes no library interface. It touches the test module `keiro-dsl/test/Main.hs`
(using the existing helper `activeCabalPackageId :: String -> IO String`), the generated
inventory documents `keiro-dsl/record-field-migration-0.15.md` and
`keiro-dsl/generated-haskell-edition-idiomatic-v2.md`, and five generated corpus files under
`keiro-dsl/test/`. It relies on `cabal-install` 3.16 and GHC 9.12.4 (`cabal exec` environment
files and `plan.json` layout), on the `keiro-dsl-corpus-regen` tool in
`keiro-dsl/tools/corpus-regen/`, and on a running PostgreSQL for the full gate, which `just
verify` provisions through process-compose. It has no hard dependency on any sibling plan.


Revision note (2026-09-17): Refreshed the progress and acceptance evidence against the current
tree after the nominal-ID work implemented the package-id fix, expanded the test/corpus surface,
and regenerated the migration manifests. The release gate remains the final open milestone.
