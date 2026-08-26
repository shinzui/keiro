---
type: Review
title: Keiro 0.15.0.0 release readiness
description: The 0.14.0.0 to HEAD increment builds and passes every repository gate, but the release notes misplace the keiro-test-support publication, hard-code bounds the bump rewrites, link to paths Hackage cannot serve, and the mandatory 0.14 to 0.15 upgrade edge does not exist yet.
generated:
  by: process:claude-code
  at: "2026-08-26T23:38:11Z"
reviewId: REV-15
subject: mori://shinzui/keiro
subjectKind: project
reviewedSha: acb9ee6cca88dd2ab6db5f6a3ff80b788e8e5d21
coverage: incremental
baseSha: 0bdd4b7d9c3e766c394ea487333822ddf9a554a8
previousReview: REV-12
reviewedAt: "2026-08-26T23:38:11Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: changes-requested
dimensions:
  - documentation
  - operability
  - design
context: >-
  Reviewed the fifteen commits between the keiro-0.14.0.0 tag and HEAD against
  the repository release procedure: every root and per-package changelog, all
  seven Cabal files and their internal bounds, the keiro-upgrade blueprint,
  cabal.project pins, Hackage state, source distributions, and the repository
  gates. Component-level correctness of the two shipped surfaces is recorded
  separately in REV-13 and REV-14; this record continues the review chain from
  REV-12, the last record before the 0.12 to 0.14 releases.
---

# Keiro 0.15.0.0 release readiness

## Release verdict

Changes requested. The increment itself is sound: `cabal build all`, the full
`just verify` gate, `cabal check` for all seven packages, and every OKF and
policy validator pass at the reviewed commit, and the non-Haskell conformance
corpus changed only in the three ways the record migration permits. What is
not ready is the release surface a consumer reads: the changelogs contain text
that is misplaced or will become false at the bump, the `keiro-dsl` changelog
links to files Hackage will not serve, and the consumer-upgrade edge that the
release procedure makes mandatory for a breaking release has not been written.
None of these requires a code change, but all of them must land before the
release commit is tagged, because tags and Hackage uploads are irreversible.

## Required before tagging

1. **Write the `0.14.0.0 -> 0.15.0.0` blueprint edge.**
   `blueprints/keiro-upgrade/blueprint.dhall` declares only the `0.12 -> 0.13`
   and `0.13 -> 0.14` edges. This release removes every package-authored
   product selector (288 declarations, 1,412 fields) and makes every existing
   scaffolded consumer with an `idiomatic-v1` ledger fail its next `scaffold`
   with `generated Haskell edition migration required` until it reruns with
   `--apply-generated-haskell-edition` and adopts four new
   `default-extensions`. That is exactly the "consumer must change source"
   condition the release procedure names. The edge needs
   `migrations/0-14-to-0-15.md`, a `BlueprintMigration` entry with `from =
   "0.14.0.0"` and no `entails` (no upstream bound moved this cycle; the only
   `kiroku` diff is cabal-fmt realignment), the blueprint `version` bump with
   its `seihou-registry.dhall` mirror, the README edge table, and a 0.15.0.0
   row in `files/keiro-cohort-versions.md`, whose lead sentence still says
   "six published packages" although `keiro-test-support` made it seven.
2. **Move the `keiro-test-support` publication note into the 0.14.0.0
   section.** The root `CHANGELOG.md` lists "keiro-test-support is now
   published to Hackage, starting at the shared version 0.14.0.0" under
   `Unreleased`, and the root `0.14.0.0` section does not mention it. The tag
   `keiro-test-support-0.14.0.0` points at `ad0c04da`, one commit after the
   `0.14.0.0` release commit, and Hackage already serves that version. Because
   the root section feeds the GitHub release notes, a 0.15 reader would be told
   a package was first published in 0.15. Keep only the 0.15-visible effect
   under `Unreleased`: the test and benchmark stanzas of `keiro`, `keiro-pgmq`,
   and `keiro-ops` now bound `keiro-test-support`.
3. **Stop hard-coding the outgoing bound in unreleased text.** The root
   `Unreleased` entry and the `keiro`, `keiro-pgmq`, and `keiro-ops`
   `Unreleased` entries say the new `keiro-test-support` bound is
   `^>=0.14.0.0`. The release bump rewrites those Cabal lines to
   `^>=0.15.0.0`, so the sentence becomes false the moment it is published.
   Say "the lockstep bound" or rewrite the four entries during the bump.
4. **Fix the `keiro-dsl` changelog links for Hackage.** Hackage serves a
   package's files only under `src/`: `/package/keiro-dsl-0.14.0.0/CHANGELOG.md`
   returns 404 while `/package/keiro-dsl-0.14.0.0/src/CHANGELOG.md` returns
   200, and the rendered changelog page does not rewrite relative links. The
   `Unreleased` entry links `record-field-migration-0.15.md` bare, which will
   404 from `/package/keiro-dsl-0.15.0.0/changelog`, and links
   `../docs/guides/adopting-keiro-dsl-idiomatic-v2.md`, which is outside the
   package entirely. Use `src/record-field-migration-0.15.md` and an absolute
   repository URL for the guide.
5. **At bump time, follow the procedure's traps, which are all live this
   cycle.** `keiro-core`, `keiro-migrations`, and `keiro-test-support` have
   empty `Unreleased` sections and untouched trees, so they need the "No
   changes this release" note; sixteen internal-bound lines move, and
   `keiro-pgmq.cabal` carries `shibuya-pgmq-adapter ^>=0.14.0.0` twice, which a
   blind replace would corrupt exactly as it did at 0.14.0.0; all 433
   `@generated by keiro-dsl 0.14.0.0` provenance headers must be restamped by
   `just corpus-regen`, and the resulting diff must be provenance-only.

## Follow-ups that do not block the tag

- `keiro-dsl.cabal` still carries unbounded internal dependencies outside the
  conformance suites: `keiro` and `shibuya-core` in
  `keiro-dsl-runtime-vocabulary-test`, and `keiro` in `keiro-dsl-codec-bench`.
  Both were unbounded at 0.14.0.0. They are not consumer-reachable, but the
  release procedure treats an unbounded internal dependency in a non-conformance
  stanza as a defect and fixed `keiro-dsl-test` for it last release.
- `keiro/src/Keiro/ReadModel.hs` still ships `ConsistencyMode`, `Strong`,
  `Eventual`, `PositionWait`, `StrongScope`, `EntireLog`, and `CategoryHead`
  with `DEPRECATED` pragmas that promise removal "in 0.13". They survived 0.13
  and 0.14, and the frozen Language 1 to 4 conformance fixtures emit 22
  `-Wdeprecations` warnings against them under `cabal build all`. A breaking
  release is the moment to either remove them or restate the window.

## Evidence

- `git log keiro-0.14.0.0..HEAD` lists fifteen commits touching 480 files;
  every user-facing commit is represented in the root and owning changelogs,
  and the remaining ten touch only `docs/`, `mori.dhall`, and the task runner.
- `curl -s -o /dev/null -w '%{http_code}'` against
  `hackage.haskell.org/package/keiro-dsl-0.14.0.0/CHANGELOG.md` returned 404
  and against `.../keiro-dsl-0.14.0.0/src/CHANGELOG.md` returned 200.
- Hackage `preferred` reports 0.14.0.0 as the newest normal version of all
  seven packages; `keiro-test-support` has exactly one published version.
- `git rev-list -n1 keiro-test-support-0.14.0.0` is `ad0c04da`; `git
  rev-list -n1 keiro-0.14.0.0` is `0bdd4b7d`.
- `git diff keiro-0.14.0.0..HEAD -- '*.cabal'` moves no upstream bound; the
  only `kiroku` hunks are cabal-fmt column realignment.
- `cabal sdist keiro-dsl keiro-test-support` succeeded; the `keiro-dsl`
  tarball contains both new `extra-doc-files`. `cabal check` reported no
  errors or warnings in any of the seven package directories.
- `cabal build all` exited 0 at the reviewed commit with 79 warnings, none in
  `keiro-dsl` source: 32 `-Wdeprecations` (22 of them in the frozen
  conformance fixtures), 30 `-Wunused-top-binds`, 15 `-Wpartial-fields`, and
  2 `-Wname-shadowing`, all in `keiro`, `jitsurei`, and frozen fixtures that
  this cycle did not change.
- `just process-compose-check`, `extension-policy`, `generated-name-policy`,
  `adr-validate`, `research-validate`, `capabilities-validate`,
  `reviews-validate`, and `user-documentation-validate` all exited 0.
- `just verify` exited 0 at the reviewed commit (started 2026-08-26T23:26:22Z, finished 23:40:13Z): 49 of 49 test suites passed with zero failures, including 712 `keiro-dsl-test` and 620 `keiro-test` examples, the jitsurei walkthrough and diagram check, the conformance-corpus replay check (39 of 39, frozen skeleton corpus verified only), the extension and generated-name policies, and `keiro-migrations-test`.
