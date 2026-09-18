---
id: 43
slug: address-the-rev-17-keiro-0-17-0-0-release-readiness-findings
title: "Address the REV-17 keiro 0.17.0.0 release readiness findings"
kind: master-plan
created_at: 2026-09-16T18:25:28Z
intention: "intention_01m2nqd9hre9gbhw37aagtf066"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T18:25:28Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-17T23:10:58Z
      mode: "implement"
      note: "Started EP-1 and refreshed coordination against current nominal-ID work"
---

# Address the REV-17 keiro 0.17.0.0 release readiness findings

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The release review `docs/reviews/keiro-0-17-release-readiness.md` (REV-17, recorded at
commit `fa6b66b2` against the `keiro-0.16.0.0` tag) found the 0.17.0.0 increment's code
correct and its measured performance costs within the guards that plans 83, 116, and 164
approved, but it requested changes before the tag. When this initiative is complete, a
maintainer can run the release skill in `agents/skills/release/SKILL.md` for 0.17.0.0 and
every precondition it names holds: `just verify` exits 0 from a clean tree; the
`blueprints/keiro-upgrade` blueprint carries a `0.16.0.0 -> 0.17.0.0` edge that names every
source change a consumer must make; the root and package changelogs describe every shipped
and breaking surface, including the `keiro-dsl` public API changes and the comment-only change
to frozen Language 4 output; the user reference documents the guarded DLQ purge workflow and the
new diff and intake surfaces; and `ordering fifo-heads` is accepted only by the Language 6
candidate, so the published Language 4 and 5 grammars stay frozen as ADR-16 requires. A second
wave, which does not gate the tag, hardens the Language 6 reaction candidate before it is
published (timer identity, rollout metadata, fingerprint scope, ledger facts, skeleton defaults)
and closes the follow-ups REV-17 and REV-15 carried: an empty timer transaction on reaction
paths, a false replay-twin advisory, deprecation pragmas that promise a removal in 0.13, two
unbounded internal dependencies in `keiro-dsl.cabal`, and a benchmark first-run cost that makes
one 25% guard fail on a loaded machine.

Included: everything listed under "Required before tagging" and "Follow-ups that do not block
the tag" in REV-17, plus the verdict-affecting keiro-dsl findings in its keiro-dsl section.
Excluded: the release cut itself (version bump, tag, Hackage upload, GitHub release), which
runs through the release skill after Phase 1 lands and is not a child plan; publishing Language
6, which remains a candidate; any change to Language 1 through 5 generated output beyond
restoring the five hand-edited corpora to generator-exact bytes; the shibuya-pgmq-adapter and
pgmq-hs repositories, whose published 0.16.0.0 and 0.6.0.0 releases were verified sufficient.


## Decomposition Strategy

The findings were grouped by the artifact they change and by whether they gate the tag, not by
the review item that surfaced them. Phase 1 holds the four plans the tag waits on, each
independently verifiable by a command a maintainer already runs: the verify gate (EP-1), the
upgrade edge and release metadata (EP-2), the changelogs and user documentation (EP-3), and the
published-language grammar freeze for `fifo-heads` (EP-4). Phase 2 holds the two plans that
must land before Language 6 is published or the next release cycle closes: hardening the
reaction candidate (EP-5) and the carried-over runtime, DSL diff, packaging, and benchmark
follow-ups (EP-6).

Three alternatives were rejected. Folding the `fifo-heads` gate into the gate-repair plan would
have mixed a mechanical restoration with a language-contract decision that the upgrade edge and
changelog both depend on; keeping it separate lets EP-2 and EP-3 read one decision. Merging the
changelog and blueprint work into one "release surface" plan was rejected because the blueprint
edge is consumer-facing tooling validated with `seihou`, while changelogs and user docs are
validated by the OKF documentation validators; they share prose but not tooling or reviewers.
Putting the replay-twin relaxation into EP-4 as "published-language contract corrections" was
rejected because it is not tag-blocking, and a plan that gates the tag should contain only
tag-blocking work.

Relevant local ADRs, read for this decomposition: ADR-16
(`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`) fixes that
released syntax is registered under a successor version and published parsers are not widened,
which decides EP-4 and freezes the corpora EP-1 restores; ADR-24
(`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`)
requires every deterministic id to hash UTF-8 seed bytes through
`Keiro.DeterministicId.identitySeedBytes`, which the reaction template EP-5 fixes violates;
ADR-18 (`docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md`)
places persisted pre-hash bytes in the frozen canonical encoding rather than the pretty
printer, which governs the reaction fingerprint decision in EP-5; ADR-4
(`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`) makes
machine-readable diagnostic codes the contract tooling depends on, which is why EP-5 aligns the
reaction codes' rollout vectors; ADR-2
(`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`)
defines replay-only twins, whose coverage test EP-6 relaxes; ADR-41, ADR-42, ADR-43, ADR-44,
and ADR-45 record the reaction, producer identity, delegated inbox, FIFO, and provisioning
contracts that EP-2 and EP-3 describe to consumers. No cross-repository ADR applies. No new
ADR is expected from Phase 1; EP-5's fingerprint decision may amend ADR-41 or ADR-18, and EP-6's
deprecation-window decision should be recorded as an ADR amendment if it ties removal to
retiring the Language 4 read-model generator.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Restore a green verify gate for the 0.17.0.0 candidate | docs/plans/281-restore-a-green-verify-gate-for-the-0-17-0-0-candidate.md | None | None | Complete |
| 2 | Write the 0.16.0.0 to 0.17.0.0 upgrade edge and reconcile release metadata | docs/plans/282-write-the-0-16-0-0-to-0-17-0-0-upgrade-edge-and-reconcile-release-metadata.md | None | EP-3, EP-4 | Complete |
| 3 | Reconcile the 0.17.0.0 changelogs and user documentation with the shipped surfaces | docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md | None | EP-1, EP-4, EP-6 | Complete |
| 4 | Gate ordering fifo-heads to Language 6 | docs/plans/284-gate-ordering-fifo-heads-to-language-6.md | None | EP-1 | Complete |
| 5 | Harden the Language 6 reaction candidate before it is published | docs/plans/285-harden-the-language-6-reaction-candidate-before-it-is-published.md | None | EP-1, EP-4 | Not Started |
| 6 | Close the carried-over runtime, DSL diff, packaging, and benchmark follow-ups | docs/plans/286-close-the-carried-over-runtime-dsl-diff-packaging-and-benchmark-follow-ups.md | None | EP-3 | Not Started |

Phase 1 (gates the 0.17.0.0 tag): EP-1, EP-2, EP-3, EP-4. Phase 2 (before Language 6 is
published or the next cycle closes): EP-5, EP-6.


## Dependency Graph

No child plan has a hard dependency: none of them needs a type, module, or file that another
plan creates, and each can be implemented and verified on its own branch of work. The soft
dependencies express reading order, not compilation order.

EP-4 should land before EP-2 and EP-3 finalize their prose, because both describe `ordering
fifo-heads` to consumers and must say whether it needs Language 6. If EP-4 is delayed, EP-2 and
EP-3 may proceed with the wording "requires the Language 6 candidate" on the strength of the
decision recorded in EP-4's Decision Log and in this plan's Decision Log, and re-check it before
the release commit.

EP-1 should land before EP-4 and EP-5 run their own `just corpus-regen`, because EP-1 restores
the five hand-edited Language 4 corpora to generator-exact bytes; a later regeneration would
restore them too, but it would then mix that restoration into a plan whose diff should be
limited to the corpora it changes on purpose. EP-3 reads EP-1's Decision Log for the
comment-only change it must disclose.

EP-3 owns the structure of every `[Unreleased]` changelog section; EP-4, EP-5, and EP-6 append
bullets under that structure, so they should land after EP-3 or rebase their bullets onto it.
EP-3 also reads EP-6's outcome for the replay-twin wording: if EP-6 has relaxed
`coversBody`, the changelog describes semantic coverage; otherwise it describes the syntactic
rule precisely.

Within Phase 1, EP-1, EP-2, and EP-4 can proceed in parallel from the start; EP-3 can start its
changelog and user-doc rewrites in parallel and finalize two wordings last. Phase 2 plans can
proceed in parallel with each other and with Phase 1, but neither should be merged into the
release commit: they are amendments to a candidate language and to follow-up surfaces, and the
tag must not wait on them.


## Integration Points

The `[Unreleased]` sections of `CHANGELOG.md`, `keiro/CHANGELOG.md`, `keiro-dsl/CHANGELOG.md`,
`keiro-pgmq/CHANGELOG.md`, `keiro-ops/CHANGELOG.md`, and `keiro-test-support/CHANGELOG.md` are
touched by EP-3 (owner: it reconciles and structures them under the release skill's headings),
EP-4 (fifo-heads bullet says Language 6), EP-5 (candidate changes), and EP-6 (twin wording,
deprecation window, bounds). Later plans append bullets under EP-3's headings and never
restructure.

The conformance corpora under `keiro-dsl/test/conformance-*` and the `just corpus-regen`
baseline are touched by EP-1 (owner: restores the five Language 4 `QueuePolicy.hs` files and
establishes a clean check), EP-4 (fixture header only; no corpus is expected to change), and EP-5
(regenerates `conformance-process-reactions` and `conformance-process-timers`). Every plan that
regenerates must confirm with `git status --short` that only the corpora it intended changed.

`profileV5` and the `LanguageFeature` enumeration in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`
are touched by EP-4 (owner: adds the workqueue fifo-heads feature to the Language 6 candidate
profile) and read by EP-5 (adds no feature). The registry test that syntax profiles are monotone
must pass after both.

`blueprints/keiro-upgrade/migrations/0.16.0.0-to-0.17.0.0.md` (EP-2, owner) summarizes what
`keiro-dsl/CHANGELOG.md` and `keiro/CHANGELOG.md` record (EP-3) and states the `fifo-heads`
language requirement (EP-4). It must be re-read against both before the release commit.

`docs/user/typed-spec-toolchain.md`, `docs/user/work-queues.md`,
`docs/user/deploy-ordering.md`, and `docs/corpus/keiro-dsl-corpus.md` are touched by EP-3
(owner: the DLQ section, `diff --deny`, the new diff codes, the intake idempotence syntax, the
skeleton language statement), EP-4 (one-sentence qualifications that `fifo-heads` needs the
Language 6 candidate), and EP-5 (skeletons open with the stable Language 5, timer-identity and
fingerprint rollout consequences). EP-5 has decided that skeletons target
`currentStableLanguageVersion`, so EP-3's statement says Language 5. Every touch bumps the
document's `generated.at` and adds a `docs/user/log.md` entry.

The record migration manifests `keiro-dsl/record-field-migration-0.15.md` and
`keiro-dsl/generated-haskell-edition-idiomatic-v2.md` are regenerated by EP-1 (owner: the
baseline), by EP-4 (adding lines to `LanguageVersion.hs` shifts inventoried line numbers), and
possibly by EP-5 (any public record gaining a field). Regeneration is idempotent; whichever plan
lands second reruns `python3 scripts/generate-record-migration-manifests.py` and commits.

The `keiro-dsl/CHANGELOG.md` sentence describing existing replay-twin coverage is written by
EP-3 (syntactic rule) and rewritten by EP-6 (semantic rule) if EP-6 lands; whichever lands
second re-reads that bullet.

`keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs` (minimum-version table and feature cases) and
the workqueue property generator in `keiro-dsl/test/Main.hs` are changed only by EP-4.
`keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs` gains a frozen reaction-surface encoder only in
EP-5, and `ScaffoldRun.hs` call sites of the two helpers that begin returning `Either` change
only in EP-5.

Cross-plan decisions that may deserve ADR records: EP-5's choice of a frozen canonical encoding
for the reaction fingerprint (an amendment to ADR-41 or ADR-18) and its amendment of ADR-24 to
name the generated reaction template as a fifth derivation routed through
`identitySeedBytes`; and EP-6's decision to tie the read-model deprecation window to retiring
the Language 4 read-model generator (an amendment to whichever ADR introduced
`QueryFreshness`, or a new record).


## Progress

- [x] EP-1: the two `keiro-dsl-test` compile examples select `keiki` by package id
- [x] EP-1: record migration manifests regenerated and `just record-migration-policy` passes
- [x] EP-1: all 47 registered corpora reproduce their committed generator-exact bytes
- [x] EP-1: full `just verify` from a clean commit exits 0 and leaves the tree clean
- [x] EP-2: `migrations/0.16.0.0-to-0.17.0.0.md` written with every consumer-visible change
- [x] EP-2: blueprint entry declared and version bumped in `blueprint.dhall`, `seihou-registry.dhall`, README, and cohort map
- [x] EP-2: `seihou validate-blueprint` passes and the synced-copy preview shows the edge
- [x] EP-2: `mori.dhall` adapter constraint and release-skill formatter text reconciled
- [x] EP-3: root and package changelogs reconciled and corrected (`keiro-dsl` breaking list, `keiro` content-type, `keiro-test-support` export)
- [x] EP-3: DLQ section of `docs/user/work-queues.md` rewritten for the guarded workflow
- [x] EP-3: `docs/user/typed-spec-toolchain.md` covers `diff --deny`, the new diff codes, intake idempotence syntax, and skeleton language
- [x] EP-3: documentation validators pass and every bullet re-verified against source
- [x] EP-4: `WorkqueueFifoHeadsSyntax` registered in the Language 6 profile and the parser refuses the token under Languages 4 and 5 at its span
- [x] EP-4: corpora and manifests proven unchanged or regenerated; all four policies pass
- [x] EP-4: changelogs and user reference say the token needs the Language 6 candidate
- [ ] EP-5: reaction template timer ids derive from length-prefixed UTF-8 seeds; candidate corpora regenerated; vectors pinned
- [ ] EP-5: reaction diff codes carry the rollout and identity vectors their prose promises
- [ ] EP-5: reaction fingerprint derives from a frozen canonical encoding that excludes operator text
- [ ] EP-5: harness ownership fact, partial helpers, and skeleton default language corrected
- [ ] EP-5: changelog, user documentation, ADR-24 amendment, and full gate
- [ ] EP-6: dispatch-only reactions open no timer transaction
- [ ] EP-6: semantically equivalent hand-simplified replay twins no longer draw `AggGuardTightened`
- [ ] EP-6: read-model deprecation windows restated
- [ ] EP-6: `keiro-dsl.cabal` non-conformance internal dependencies bounded
- [ ] EP-6: delegated inbox benchmark first-run cost moved out of the timed action and fresh baselines re-recorded


## Surprises & Discoveries

- Discovery: Work completed after this MasterPlan was written already delivered EP-1's two
  `keiki` package-id fixes and regenerated both record migration manifests while implementing
  nominal-ID support. The same work expanded `keiro-dsl-test` and the conformance corpus, so the
  original fixed test counts and narrow regeneration-diff expectations are historical rather
  than current acceptance criteria.
  Evidence: commits `7d235121` and `acda7fc0`; on 2026-09-17 the two targeted examples passed,
  `just record-migration-policy` exited 0, and `just conformance-corpus-policy` reported 47 of 47
  invocations and `conformance corpus: ok`.
- Discovery: The refreshed full release gate passes with 755 `keiro-dsl-test` examples rather
  than the 743 examples recorded when EP-1 was drafted. This is expected growth from the
  nominal-ID work and does not change the release criterion.
  Evidence: `just verify` exited 0 on 2026-09-17 from commit `e6183397` and left the tree clean.


## Decision Log

- Decision: Decompose into two phases, with Phase 1 containing only work the 0.17.0.0 tag
  waits on.
  Rationale: The release procedure makes tags and Hackage uploads irreversible, so the set of
  plans that gate the tag must be as small as the review's required list and nothing in it
  should be a candidate-language amendment or a follow-up.
  Date: 2026-09-16
- Decision: Gate `ordering fifo-heads` to Language 6 (EP-4) rather than documenting an
  exception that lets published languages accept it.
  Rationale: ADR-16 states that released syntax is registered under a successor version and that
  existing version parsers are not widened; the other two Language 6 constructs already follow
  this rule, and once 0.17.0.0 is on Hackage the token could never be gated without breaking
  published specs.
  Date: 2026-09-16
- Decision: Keep the comment-only change that da5e2469 made to generated Language 4
  `QueuePolicy.hs` output and disclose it in the changelog (EP-1 decides, EP-3 discloses).
  Rationale: The new comment is already in the committed corpora and changes no behavior or
  identity; reverting it would add a second generator edit and regeneration for no consumer
  benefit. The changelog's claim that published-language output is unchanged must be corrected
  because the freeze is byte-level.
  Date: 2026-09-16
- Decision: Fix the two `keiki` compile tests to select by package id (EP-1) rather than
  clean the Cabal store.
  Rationale: The store can legitimately hold two builds of one version; the tests already select
  `keiro-core` by id, and only a test change removes the dependence on machine state.
  Date: 2026-09-16
- Decision: Place the reaction-candidate hardening (EP-5) in Phase 2 even though the timer-id
  derivation is a real defect.
  Rationale: Language 6 is registered as a candidate and its generated identities are not yet
  frozen; ADR-16 allows candidates to be amended in place. Fixing before publication is what
  matters, and holding the 0.17.0.0 tag for it would not protect any consumer.
  Date: 2026-09-16
- Decision: The release cut is not a child plan.
  Rationale: `agents/skills/release/SKILL.md` already prescribes the bump, corpus restamp,
  gate rerun, tag, upload, and GitHub release steps with their traps; duplicating them in an
  ExecPlan would create a second procedure to keep in sync.
  Date: 2026-09-16


## Outcomes & Retrospective

(To be filled during and after implementation.)
