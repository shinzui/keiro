---
id: 265
slug: make-aggregate-transition-family-diffs-idempotent-and-order-independent
title: "Make aggregate transition-family diffs idempotent and order-independent"
kind: exec-plan
created_at: 2026-08-22T03:59:33Z
intention: "intention_01m0kst1x4ejdsnxmweqv8brne"
---

# Make aggregate transition-family diffs idempotent and order-independent

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl diff` currently compares each candidate aggregate transition with the first
baseline transition that has the same source state, command, and mode. That is incorrect
when an aggregate has several sibling branches for one source/command pair. A byte-identical
workspace can consequently print `AggGuardTightened` advisories even though no transition
changed, while the replay-impact report correctly says `replay-neutral`.

After this plan, transition families are compared as order-independent multisets before any
guard advisory is considered. Identical siblings cancel exactly, a candidate declaration or
catalog addition cannot change the classification of an unrelated transition, and an
ambiguous remaining family produces a conservative diagnostic without a fabricated
replay-only remedy. A developer can demonstrate the result by diffing the minimized
Language-5 regression against itself and by diffing a disposable checkout of
`mori://shinzui/mori/repos/mori` against `HEAD`: both produce no guard finding and a
`replay-neutral` result.

This plan deliberately stops at the structural safety boundary. It does not claim that two
different guard expressions are semantically equivalent or that a computed twin is proved
satisfiable. The dependent [ExecPlan 266](266-prove-aggregate-guard-relations-and-validate-replay-only-remedies.md)
adds those proofs after this plan establishes one shared, deterministic transition-family
comparison.


## Progress

- [ ] Capture the current contradiction with a minimized Language-5 sibling fixture and
      text, JSON, and replay-impact assertions.
- [ ] Add one internal transition-family module that groups, sorts, and exactly cancels
      transitions as a multiset.
- [ ] Make both aggregate guard diffing and replay-impact analysis consume that shared
      family result, preserving conservative behavior for unresolved changes.
- [ ] Add the append-only `AggGuardRelationUnknown` diagnostic for structurally ambiguous
      families, with the private-history safety vector and no replay-only remedy.
- [ ] Prove identical, reordered, additive-only, genuinely changed, and ambiguous cases in
      unit and CLI tests, including the minimized Mori-derived shape.
- [ ] Run the disposable Mori regression, the complete `keiro-dsl` test inventory, formatting,
      documentation validation, and the ADR distillation pass.


## Surprises & Discoveries

- Observation: baseline and candidate workspace loading is already symmetric for an ordinary
  self-diff. `keiro-dsl/app/Main.hs` loads the working tree with `loadWorkspace`, loads the Git
  revision through the same `loadWorkspace` entry point and a different `ContentSource`, then
  passes both through `checkedWorkspace`. The special adoption baseline applies only when the
  historical manifest does not exist.
  Evidence: `runWorkspaceDiff` in `keiro-dsl/app/Main.hs` and `diffWorkspaces` in
  `keiro-dsl/src/Keiro/Dsl/WorkspaceDiff.hs`.

- Observation: the false positives come from sibling mispairing. `guardTighteningDiff` searches
  the old transition list with `find` and therefore selects the first transition with the same
  source, command, and live mode for every candidate sibling. Mori uses complementary no-op and
  emitting branches for the same source/command pair, so the unchanged second branch is compared
  with the wrong first branch.
  Evidence: `keiro-dsl/src/Keiro/Dsl/Diff.hs`, function `guardTighteningDiff`; the reproduced
  detail repeats an equality or conjoins an equality with a disjunction containing that same
  equality.

- Observation: replay-impact analysis already cancels exact transitions as a sorted multiset and
  is declaration-order independent. That is why the same command can print guard advisories and
  finish with `replay-neutral`.
  Evidence: `changedTransitionEvents`, `cancelExact`, and `cancelLoosenings` in
  `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`, plus its permutation test in
  `keiro-dsl/test/Main.hs`.


## Decision Log

- Decision: Split IR-33 into this structural correctness plan and dependent ExecPlan 266 for
  semantic proofs and remedy validation.
  Rationale: exact multiset cancellation is sufficient to remove the reproduced self-diff bug
  and can be verified without a solver. Semantic implication, satisfiability, existing-twin
  coverage, and Language-5 remedy validation are a second coherent safety boundary and should
  not make the contained idempotence fix harder to review or land.
  Date: 2026-08-21

- Decision: Make transition-family comparison a shared internal Keiro module rather than copy
  replay-impact's current cancellation into `Diff.hs`.
  Rationale: text/JSON findings and replay-impact are two projections of the same transition
  relation. A second independent pairing implementation would allow them to disagree again.
  Date: 2026-08-21

- Decision: Exact cancellation uses the frozen replay transition encoding as a multiset key and
  never rewrites that encoding.
  Rationale: `canonicalTransition` intentionally excludes source locations and forward-only
  domain outcomes while including mode, ownership, guard, writes, ordered emits, and target. It
  is already the replay-fold identity used by replay impact. Changing its bytes would be a
  snapshot-identity migration forbidden by ADR 0018; consuming it as a comparison key is safe.
  Date: 2026-08-21

- Decision: If exact cancellation leaves more than one plausible old/new guard pair, report
  `AggGuardRelationUnknown` with the same private-history compatibility vector and no computed
  twin.
  Rationale: selecting a pair by declaration order can both misidentify the affected history and
  print a transition that does not preserve it. A conservative, machine-detectable limitation preserves
  safety until ExecPlan 266 can compare guard unions by replay body.
  Date: 2026-08-21

- Decision: Do not change Keiki or add a solver dependency in this plan.
  Rationale: the defect occurs before symbolic reasoning: byte-identical sibling transitions are
  paired incorrectly inside Keiro. A dependency change would add release coordination without
  improving this proof.
  Date: 2026-08-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The affected package is `keiro-dsl`, identified across repositories by this canonical handle:

`mori://shinzui/keiro/packages/keiro-dsl`

Its normalized aggregate syntax lives in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs`. A `Transition` records a source state (`tSource`), command
(`tCommand`), behavior owner, optional guard, ordered writes and emitted events, an optional
forward-only domain outcome, target state, mode, and source location. A *live* transition may
accept a new command. A *replay-only* transition is skipped by forward execution and retained so
historical events can still be inverted and folded.

A *transition family* in this plan is every transition with one mode, source state, and command.
Several siblings in a family represent alternative branches. A *multiset* retains duplicate
counts but not declaration order: cancelling one identical old and new transition removes exactly
one occurrence from each side. A *family remainder* is what is left after that cancellation.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` owns ordinary cross-spec compatibility findings.
`aggregatePairDiff` currently invokes `guardTighteningDiff`, which walks every candidate live
transition and uses `Data.List.find` to select the first baseline live transition with the same
source and command. It tests raw `Expr` inequality, constructs `oldGuard AND NOT newGuard` with
`complementExpr`, and suppresses the warning if any candidate replay-only sibling shares the
source and command. This plan changes only the pairing boundary and ambiguous-family response;
ExecPlan 266 owns semantic relation and replay-only coverage correctness.

`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` answers the narrower question of which historical event
types and snapshots require an audit. Its `changedTransitionEvents` groups transitions by mode,
source, and command; `cancelExact` removes exact canonical matches; `cancelLoosenings` removes a
small syntactically provable loosening fragment; and remaining transitions contribute their event
types. The exact cancellation and stable grouping belong in the shared module introduced here.
The syntactic loosening rule remains in replay impact until ExecPlan 266 replaces it with a shared
guard relation.

`keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs` defines `canonicalTransition`. These bytes are
frozen persisted fold identity: they include replay behavior and exclude `tOutcome`, because a
domain outcome labels forward command behavior without changing replay. This plan must not
normalize, simplify, or otherwise change those bytes. It may sort and compare them.

`keiro-dsl/src/Keiro/Dsl/DiffReport.hs` maps a diagnostic code to machine-readable remedies.
`keiro-dsl/src/Keiro/Dsl/Validate.hs` owns the append-only `DiagnosticCode` enumeration, code
parsing, and diagnostic origin. New constructors are appended at the end of the enumeration, not
inserted beside older guard codes, so existing ordinal-derived behavior is not silently reordered.
`keiro-dsl/test/Main.hs` contains unit tests for replay impact and the existing Plan-143 guard
advisory. `keiro-dsl/test/diff-test.sh` exercises the real Git-based CLI and JSON report path.

The originating request is
`docs/improvement-requests/make-aggregate-guard-diffs-idempotent-and-semantically-exact.md`
(IR-33). Its Mori evidence uses these canonical plan handles:

- `mori://shinzui/mori/plans/223-move-the-mori-workspace-to-keiro-dsl-language-5`
- `mori://shinzui/mori/plans/236-model-project-releases-in-the-registry`

Do not edit the registered Mori checkout during implementation; use a disposable local clone for
the final reproducer.

Relevant architectural decisions are:

- [ADR 0002](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
  defines why a real tightening threatens hydration and why a replay-only edge is the sanctioned
  remedy. Runtime live-first/replay-only inversion remains unchanged by this plan.
- [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  requires diff to report cross-revision hazards while runtime construction and database replay
  audits remain independent defenses.
- [ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
  places diff and replay analysis at the `CheckedService` boundary and keeps source layout out of
  normalized graph equality.
- [ADR 0018](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
  freezes canonical fold bytes and already requires replay comparison to be invariant under
  sibling declaration order.

[ExecPlan 143](143-add-first-class-replay-only-transitions-for-guard-evolution.md) implemented the
current remedy and supplies the existing end-to-end black-acuity safety proof. This plan corrects
its conservative pairing without changing Keiki edge selection, runtime hydration, forward
stepping, event codecs, fold fingerprints, or stored data.


## Plan of Work

### Milestone 1 — Pin the sibling-family failure

Add a small Language-5 aggregate fixture under `keiro-dsl/test/fixtures/` derived from Mori's
`ProjectArtifact` pattern. It must contain at least two valid live transitions with the same
source and command: an equality/no-op branch and the complementary inequality/emitting branch.
Keep the fixture self-contained and name Mori only through the canonical references in this plan
or a fixture comment. Add an additive variant that introduces an unrelated declaration without
changing either branch, and an ambiguous variant in which exact cancellation leaves more than one
changed old/new sibling.

In `keiro-dsl/test/Main.hs`, first record the current failure, then assert the intended behavior:
diffing the fixture against itself, against a source-location-only relocation, and against every
permutation of its transition declaration order yields no `AggGuardTightened` and no
`AggGuardRelationUnknown`; replay impact is `ReplayNeutral`. Diffing the base against the additive
variant leaves every pre-existing guard classification unchanged. The ambiguous changed variant
must eventually produce exactly one unknown family finding and no text containing a rendered
`replay-only` transition. Retain the existing genuine-tightening test as a regression; this plan
must not silence its one-to-one warning.

Extend `keiro-dsl/test/diff-test.sh` with a Git-backed self-diff case. Commit the minimized fixture
inside the script's disposable repository, run `diff --since HEAD` with both report outputs, and
assert an empty `findings` array plus `{"verdict":"replay-neutral"}`. This proves the same CLI path
that failed in Mori rather than only the pure library helper.

Milestone acceptance is a red/green focused test: before the implementation, at least the current
false `AggGuardTightened` is observed; after later milestones, all new assertions pass.

### Milestone 2 — Establish one transition-family authority

Create the internal module `keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` and register it under
`other-modules` in `keiro-dsl/keiro-dsl.cabal`. Define an ordered `TransitionFamilyKey` containing
mode, source, and command, plus a `TransitionFamilyDelta` containing that key and the exact old and
new remainders. Provide a pure function with this conceptual interface:

```haskell
transitionFamilyDeltas :: [Transition] -> [Transition] -> [TransitionFamilyDelta]
```

The implementation groups both inputs, sorts each family by `canonicalTransition`, and performs
duplicate-aware merge cancellation. It returns families in key order and remainders in canonical
order. Do not use source locations or list positions as semantic identity. Add focused tests for
duplicates, empty sides, unrelated keys, and every permutation of a three-sibling family.

Replace the private `cancelExact` and grouping code in
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` with this shared result. Continue applying the existing
`cancelLoosenings` only to each exact remainder, preserving its conservative replay behavior for
now. The existing replay-impact permutation test must remain green.

Move aggregate guard findings out of the spec-only `aggregatePairDiff` path and into a
service-aware guard evolution pass invoked by `diffServices`. The new pass still uses the old and
new normalized specs, but starts with `transitionFamilyDeltas`. A family with an empty exact
remainder produces no guard finding. Exactly one old and one new live remainder follows the
existing raw guard-change path so the established Plan-143 behavior remains available. A family
with plausible transitions on both sides but no unique remaining pair produces the conservative
unknown finding defined in Milestone 3. An old-only removal or new-only addition remains owned by
the independent fold/replay/declaration analyses rather than being mislabeled as a guard
relation.

Milestone acceptance is that the minimized self-diff and all declaration permutations are empty
and replay-neutral, while the genuine one-to-one tightening remains visible.

### Milestone 3 — Make ambiguity truthful and machine-readable

Append `AggGuardRelationUnknown` to `DiagnosticCode` in
`keiro-dsl/src/Keiro/Dsl/Validate.hs`, classify it as `DiffDiagnostic`, and include it in every
exhaustive diff-code registry used by `Diff.hs`. In `classifyCompatibility`, give it the same
`private-history-read=advisory` vector as `AggGuardTightened`; do not demote it merely because the
tool lacks a unique pair. Its detail must name the aggregate family, old/new remainder counts, and
state that no replay-only transition was generated because the relationship is ambiguous.

In `keiro-dsl/src/Keiro/Dsl/DiffReport.hs`, map this code to `RemedyDoNotDeploy` with guidance to
resolve the family ambiguity or run the targeted replay audit. It must never map to
`RemedyReplayOnlyEdge`. Add text and JSON assertions for the code, compatibility vector, and
remediation. Update `keiro-dsl/CHANGELOG.md` and the guard-evolution section of
`docs/guides/evolution-and-replayability.md` to explain that code-specific consumers of
`AggGuardTightened` must also recognize `AggGuardRelationUnknown`, while compatibility-surface
gates continue to catch both automatically.

Milestone acceptance is that an ambiguous family cannot disappear, cannot print a guessed twin,
and remains classified on the private-history surface in the default report so downstream policy
can recognize it without scraping prose.

### Milestone 4 — Prove the real adopter and close the structural plan

Build the local `keiro-dsl` executable. Resolve `mori://shinzui/mori/repos/mori` with Mori, clone it
to a fresh temporary directory, and run the local executable there against the committed
Language-5 workspace and `HEAD`. Do not run against or modify the registered checkout. Record in
this plan the checked Mori commit and the concise `jq` evidence: zero
`AggGuardTightened`, zero `AggGuardRelationUnknown`, an empty finding array for the identical
source, and `replay-neutral`.

Run the complete package tests, formatting, and OKF checks listed below. Review this plan's
Decision Log and discoveries. Update ADR 0018 if implementation changes the durable definition of
transition-family comparison, and update ADR 0004 if the new unknown code changes the durable diff
gate inventory. Do not create a new ADR when those accepted records already own the decision.

Milestone acceptance is a green complete suite and a disposable real-Mori self-diff with no guard
noise. ExecPlan 266 may then begin.


## Concrete Steps

Run all Keiro commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro

cabal test keiro-dsl-test --test-options='--match "transition family"'
cabal test keiro-dsl-test --test-options='--match "replay impact"'
bash keiro-dsl/test/diff-test.sh
```

The focused result after Milestones 1–3 should include passing examples for identical siblings,
permutations, additive locality, one-to-one tightening, and ambiguous-family refusal. The CLI
script should print a success line comparable to:

```text
ok: identical transition siblings cancel before guard classification
```

Build the executable and run the disposable Mori proof. Resolve the source with Mori rather than
hard-coding another repository's filesystem path:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro

keiro_dsl_bin="$(cabal list-bin exe:keiro-dsl)"
mori_source="$(mori path mori://shinzui/mori/repos/mori)"
guard_diff_scratch="$(mktemp -d "${TMPDIR:-/tmp}/keiro-guard-family.XXXXXX")"
git clone --local --no-hardlinks "$mori_source" "$guard_diff_scratch/mori"

cd "$guard_diff_scratch/mori"
"$keiro_dsl_bin" diff domain/mori.keiro-workspace --since HEAD \
  --report-out "$guard_diff_scratch/mori-diff.json" \
  --replay-impact-out "$guard_diff_scratch/mori-replay.json"
jq '{breaking, codes: [.findings[].code]}' "$guard_diff_scratch/mori-diff.json"
jq . "$guard_diff_scratch/mori-replay.json"
```

Expected evidence is:

```json
{
  "breaking": false,
  "codes": []
}
```

```json
{
  "verdict": "replay-neutral"
}
```

After recording the exact temporary path in a shell-local variable as above, the temporary clone
may be deleted. Never point a recursive deletion at the Mori source returned by `mori path`.

Run the complete validation bar from the Keiro root:

```bash
cabal build keiro-dsl
cabal test keiro-dsl:tests
cabal test keiro-test --test-options='--match "guard tightening"'
cabal test keiro-test --test-options='--match "black-acuity"'
cabal test keiro-test --test-options='--match "replay-only twin"'
nix fmt -- --check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
```

If an ADR is changed, add its new timestamp to `docs/adr/log.md` using the repository's normal
`okf log add` workflow before running strict validation. Update Progress and capture the actual
test counts and Mori commit rather than copying anticipated counts into the completion record.


## Validation and Acceptance

The plan is complete only when all of the following observable behaviors hold.

The minimized Language-5 sibling fixture diffed against itself, against a location-only rewrite,
and under every tested declaration permutation produces neither `AggGuardTightened` nor
`AggGuardRelationUnknown`. The corresponding replay impact is `ReplayNeutral`. Adding an unrelated
command, event, mapped declaration, or projection owner does not create a finding for an existing
transition family.

The Git-backed CLI self-diff writes `keiro-dsl/diff-report/1` with an empty `findings` array and a
replay-impact document whose verdict is `replay-neutral`. Text output contains no paste-ready
twin. A disposable checkout of `mori://shinzui/mori/repos/mori` shows the same outcome against its
own `HEAD`.

A one-to-one real tightening continues to produce exactly one `AggGuardTightened` with the
existing private-history compatibility vector. This plan does not weaken the runtime or audit
proofs from ExecPlan 143. Conversely, a family whose exact remainders cannot be uniquely paired
produces exactly one `AggGuardRelationUnknown`, uses the private-history advisory vector, supplies
a do-not-deploy/audit remediation, and contains no rendered `replay-only` transition.

`ReplayImpact` and ordinary diff both consume the same exact family partition. Its existing
permutation test remains order-independent, and identical transitions cannot be classified as
replay-affected by one output while being classified as a guard change by another.

No canonical expression or transition golden changes, no fold fingerprint changes, no Keiki
package or dependency bound changes, and no Language-1-through-5 parser/scaffold golden changes are
expected. Any such change is a stop-and-investigate failure, not an acceptable incidental update.
The entire `cabal test keiro-dsl:tests` inventory and the focused Keiro black-acuity tests pass.


## Idempotence and Recovery

All production changes are pure comparison logic and append-only diagnostics. Running the tests,
Mori lookup, or disposable clone repeatedly does not alter a service specification or stored data.
The implementation never auto-applies a replay-only edge.

Land the milestones incrementally. The minimized regression can be committed red only on a local
worktree and must turn green in the same working series before a shared commit. The new internal
module can coexist temporarily with replay impact's private functions while tests are moved, but
delete the private duplicate before completing Milestone 2. If integration fails, revert only the
call site to the old local helper; do not change canonical encoding to make tests pass.

An interrupted disposable Mori proof is recovered by creating a new `mktemp` directory and
re-running the clone. Never clean or reset the registered Mori checkout. If the local Keiro tree
contains pre-existing user changes, preserve them and constrain edits to the named files; stop if
those changes overlap the same transition-diff functions in a way that cannot be reconciled.

Because the diagnostic registry is append-only, do not delete or rename
`AggGuardRelationUnknown` after it has been committed or released. Later semantic work may reduce
how often it appears, but must keep parsing and reporting the code.


## Interfaces and Dependencies

`keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` is an internal library module, registered in
`keiro-dsl/keiro-dsl.cabal`. It owns `TransitionFamilyKey`, `TransitionFamilyDelta`, and
`transitionFamilyDeltas`. The exact record field names may follow repository conventions, but the
observable contract is fixed: key-ordered families, duplicate-aware exact cancellation using
`canonicalTransition`, and canonical-order remainders independent of source declaration order.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` gains a service-aware aggregate guard pass called by
`diffServices`; the spec-only node-family differ no longer performs its own first-match guard
comparison. The public `diffServices :: CheckedService -> CheckedService -> Either FoldSurfaceError
[Change]` signature and the JSON schema remain unchanged.

`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` consumes the same family deltas before its existing
syntactic loosening pass. Its public
`replayImpactServices :: CheckedService -> CheckedService -> Either FoldSurfaceError ReplayImpact`
signature and the released replay-impact JSON shapes remain unchanged.

`keiro-dsl/src/Keiro/Dsl/Validate.hs` appends `AggGuardRelationUnknown` and classifies it as a diff
diagnostic. `keiro-dsl/src/Keiro/Dsl/Diff.hs` assigns the private-history advisory vector.
`keiro-dsl/src/Keiro/Dsl/DiffReport.hs` maps it to `RemedyDoNotDeploy`, never
`RemedyReplayOnlyEdge`.

There are no new external libraries, no database changes, and no Keiki source or version change.
The only cross-repository dependency in validation is the read-only disposable Mori adopter proof,
located through this canonical handle:

`mori://shinzui/mori/repos/mori`

Every commit implementing this plan must include:

```text
ExecPlan: docs/plans/265-make-aggregate-transition-family-diffs-idempotent-and-order-independent.md
Intention: intention_01m0kst1x4ejdsnxmweqv8brne
```
