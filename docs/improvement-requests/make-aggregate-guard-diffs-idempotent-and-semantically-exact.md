---
type: Improvement Request
title: Make aggregate guard diffs idempotent and semantically exact
description: >-
  Stop keiro-dsl diff from reporting AggGuardTightened for byte-identical or additive-only
  aggregate sources, and emit the replay-only remedy only when the old guard has a real,
  satisfiable region excluded by the new guard.
timestamp: 2026-08-21T19:32:06Z
requestId: IR-33
status: proposed
origin: mori://shinzui/mori
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-08-22T04:40:12Z
    document_timestamp: 2026-08-21T19:32:06Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-fable-5
    effort: unspecified
    context: >-
      Reviewed ExecPlans 265 and 266 as originally drafted against Keiro master at ad0c04da:
      Keiro.Dsl.Diff (guardTighteningDiff, hasReplayOnlyTwin, aggregatePairDiff, diffServices,
      classifyCompatibility, the private code registry), Keiro.Dsl.ReplayImpact
      (changedTransitionEvents, cancelExact, cancelLoosenings, guardImplies),
      Keiro.Dsl.CanonicalEncoding.canonicalTransition, Keiro.Dsl.Validate (no-emit, replay-only,
      and domain-outcome rules; DiagnosticCode), Keiro.Dsl.DiffReport.remediationFor,
      Keiro.Dsl.Grammar (Loc equality, complementExpr), Keiro.Dsl.SemanticContract,
      Keiro.Dsl.Expression, Keiro.Dsl.Workspace, the Plan-143 fixtures and goldens, ADRs 2, 4,
      16, 17, and 18, the evolution guide, and Mori's committed domain/*.keiro sources, where
      second-and-later live siblings per (aggregate, source, command) were counted to confirm the
      39 reported findings. Analysis was from source; no binary was built or run.
---

# Improvement Request: Make Aggregate Guard Diffs Idempotent and Semantically Exact

## Status

**Reviewed and approved with a narrowed scope; planned, not yet implemented.** Proposed from
`mori://shinzui/mori/plans/236-model-project-releases-in-the-registry`, after reproducing the
problem with the current published `keiro-dsl` 0.14.0.0 binary and current Keiro `master`.
The same defect was first isolated during
`mori://shinzui/mori/plans/223-move-the-mori-workspace-to-keiro-dsl-language-5`; it is not a
regression introduced by Mori's release model.

The 2026-08-22 review confirmed the defect, traced it to a single cause, and split the work into
[Plan 265](../plans/265-make-aggregate-transition-family-diffs-idempotent-and-order-independent.md)
(idempotent, order-independent transition-family diffs) and
[Plan 266](../plans/266-classify-guard-unions-by-replay-body-and-validate-replay-only-remedies.md)
(replay-body guard-union classification and validated remedies). The semantic satisfiability
engine originally drafted for Plan 266 was **deferred**; the "Review Decision" section below
records the findings, the narrowed scope, and the conditions under which the engine may be
reconsidered.

## Context

`keiro-dsl diff` is not idempotent for Mori's workspace. With every `domain/` source byte equal
to `HEAD`, this command:

```text
keiro-dsl diff domain/mori.keiro-workspace --since HEAD \
  --report-out build/keiro-mori-diff.json \
  --replay-impact-out build/keiro-mori-replay-impact.json
```

reports 39 `AggGuardTightened` advisories: 36 `ProjectArtifact` `Observe*` transitions and three
existing `Project` transitions. The JSON report says `breaking: false`; the replay-impact report
says `replay-neutral`. The result is identical with the published 0.14.0.0 executable built from
tag `keiro-dsl-0.14.0.0` and with current `master` at `ad0c04da`.

The proposed replay-only twins demonstrate that the reported removed regions are not credible.
Representative output conjoins the unchanged guard with a disjunction containing the same
equality, or repeats an equality on both sides of the conjunction. For example:

```text
guard cmd.descriptionHash == reg.currentDescriptionHash
   && cmd.descriptionHash == reg.currentDescriptionHash
```

Another generated twin combines `contentHash == currentContentHash` with a disjunction whose last
arm is that same equality. These predicates do not witness commands that the old guard admitted
and the new guard rejects.

This makes compatibility review noisy in exactly the dangerous category: a real guard tightening
means historical events may no longer invert, so reviewers must not learn to ignore the warning.
The current implementation in `Keiro.Dsl.Diff.guardTighteningDiff` compares paired guard ASTs with
`tGuard newT /= tGuard oldT` and prints `oldGuard AND complement(newGuard)` without establishing
that the two loaded/expanded guards differ semantically or that the removed region is satisfiable.

The defect also distorts additive-change review. Plan 236 adds one Project command/event and one
catalog projection owner. The release-only aggregate diff is additive, but a later whole-workspace
diff repeats all 39 unrelated guard warnings. The new declarations should not make unchanged
transition guards appear tighter.

## Requested Change

Make aggregate guard comparison idempotent and semantic at the checked-spec boundary.

1. Load, resolve, expand, and normalize the baseline and candidate workspace through symmetric
   paths before pairing transitions.
2. Compare guards using one canonical checked representation, not incidental AST shape produced by
   different source-loading or expansion paths.
3. Emit `AggGuardTightened` only when the old guard admits a satisfiable region that the new guard
   excludes. If semantic implication cannot be decided for a supported expression, report that
   limitation explicitly rather than printing an unsound paste-ready twin.
4. Preserve the existing replay-only remedy for a genuine tightening: its predicate must denote
   exactly `oldGuard AND NOT newGuard`, and adding the twin must still silence the advisory.
5. Keep fold-surface, declaration, catalog, and other compatibility findings independent. Fixing
   this warning must not suppress a real `AggFoldSurfaceChanged` or a catalog membership change.

The implementation may use canonical normalization, the existing Keiki solver vocabulary, or a
combination. The required contract is observable: identical and semantically equivalent guards
produce no tightening; a real strict subset does.

## Review Decision (2026-08-22)

### Findings confirmed from source

1. **Single cause.** `Keiro.Dsl.Diff.guardTighteningDiff` pairs every candidate live transition
   with the *first* baseline transition sharing source, command, and live mode (`Data.List.find`).
   Mori declares a no-emit no-op branch before each complementary emitting branch, so the emitting
   branch is compared with the no-op branch's guard. Counting second-and-later live siblings per
   (aggregate, source, command) in Mori's `domain/` gives exactly 39; the mechanism explains every
   reported finding. Baseline and candidate loading are already symmetric, and `Loc` equality is
   constant-true, so neither loading asymmetry nor source locations contribute.

2. **Replay impact already does it right.** `ReplayImpact.changedTransitionEvents` cancels exact
   `canonicalTransition` matches as a sorted multiset per (mode, source, command) family, which is
   why the same command reports guard advisories yet finishes `replay-neutral`.

3. **Two further defects in the printed twin.** The twin copies the whole old transition, so in
   Language 5 it carries a forward `outcome` that the validator rejects on a replay-only
   transition (`DomainOutcomeReplayOnlyClause`); and when the mispaired baseline is a no-op
   branch, the twin emits nothing and is rejected as `ReplayOnlyEmitsNothing`. Both are visible
   in the reproduced output.

4. **No-emit transitions cannot strand history.** The validator makes a no-emit transition that
   changes its vertex or writes a register an error, so such a transition never produces a stored
   event and never serves as an inverting edge. Guard changes on it are not replay hazards.

5. **Existing twin suppression is source/command-only** (`hasReplayOnlyTwin`), so a stale or
   unrelated replay-only sibling hides a later real change.

6. **Removed emitting bodies are an unreported hazard.** Deleting an emitting live transition
   strands its whole guard region, but only `AggFoldSurfaceChanged` (snapshot wording) and the
   replay-affected verdict fire, and no remedy is offered although a replay-only copy of the old
   transition is exactly the sanctioned one.

### Why the semantic engine was deferred

The original Plan 266 proposed a three-valued proof engine: propositional unsatisfiability over
canonical atoms, satisfiability witnesses only by exhaustive enumeration over finite Bool/enum
domains, `Unknown` otherwise; twins printed only for a proved-satisfiable removed region; and
existing twins accepted only when proved *equivalent* to the removed region. The engine design
is sound as far as it goes. It was deferred for two product reasons, not for soundness:

- **Finite-domain witnesses make every real tightening on Text, Int, Integer, Natural, Time, or
  ID guards `Unknown` with no remedy.** Every guard in Mori's workspace is a Text-hash equality.
  Today such a tightening yields `AggGuardTightened` plus a mechanically exact twin; under the
  engine it would yield `Unknown`, do-not-deploy, and no twin, pushing operators to hand-write
  the complement that `complementExpr` exists to compute. That is a regression in actionable
  safety for the dominant guard class, even though it is "conservative".
- **Exact-equivalence coverage reintroduces false positives.** ADR-2's live-first inversion makes
  an over-covering replay-only edge safe, so the natural hand-written twin (the old guard
  verbatim) is correct; under the engine it fails `twin => removed` and, on infinite-domain
  roots, becomes a perpetual `Unknown`.

Also noted: the twin `oldGuard AND NOT newGuard` over a correctly paired same-body group is sound
whether or not the region is non-empty (an empty region is a dead replay-only edge), so
satisfiability is not a precondition for offering it. The word "fabricated" in Acceptance item 6
refers to twins produced by mispairing, which Plans 265 and 266 eliminate structurally.

### Accepted scope

- Plan 265: order-independent exact multiset cancellation per (mode, source, command) family
  shared by diff and replay impact; no-emit exclusion; outcome fields cleared from twins;
  `AggGuardRelationUnknown` (private-history advisory vector, explicit do-not-deploy remedy, no
  twin) for structurally unpairable families; the guard pass stays in place so finding order and
  the rendering golden are unchanged.
- Plan 266: replay-body key (ownership, writes, emits, target) and per-body guard unions;
  removed emitting bodies reported as the same hazard with the old transition as twin; the
  syntactic `guardImplies` fragment shared with replay impact as the sole loosening authority;
  same-body, by-construction twin coverage (computed twin, old guard verbatim, or unguarded);
  every advertised twin proved by insert, render, parse, and `validateService`, with
  `AggGuardRemedyUnavailable` otherwise.

### Deferred scope and revival conditions

Semantic guard-relation proofs (equivalence under association, commutation, and repeated terms
beyond the syntactic fragment; loosening versus tightening versus replacement) are deferred. A
future plan may reopen them only under these constraints, which the review established as
necessary to avoid the regressions above:

1. **Never withhold a twin.** An undecided relation keeps the mechanically exact twin; proofs may
   only *suppress* findings or *refine* their wording, never remove the remedy.
2. **Cover the realistic theory before enumerating finite domains.** The first exact fragment
   must include equality, disequality, and order atoms over infinite totally ordered scalars
   (union-find over equalities against distinct literals and cycle detection over order atoms,
   per disjunct), because that is the guard class adopters actually write. Finite Bool/enum
   enumeration is an addition, not the foundation.
3. **Coverage by implication, not equivalence.** An existing twin suppresses a finding when
   `removed => twinUnion` is proved; over-coverage is at most a separate low-severity lint.
4. **Unknown stays on the private-history surface** with the same vector as a tightening.
5. **No Keiki API, bound, or release change** without a separately reviewed dependency plan.

### Acceptance dispositions

| Item | Disposition |
| --- | --- |
| 1, 2, 3, 7, 8 | In scope: Plan 265 (self-diff idempotence, minimized fixture, additive locality, text/JSON/replay agreement, suite compatibility). |
| 5 | In scope: Plan 265 keeps the one-to-one advisory and twin; Plan 266 validates every twin and extends the remedy to removed bodies. |
| 4 | Partially in scope: sibling splits/merges that preserve the canonical union and loosenings inside the syntactic fragment produce no advisory (Plan 266). General ACI equivalence is deferred. |
| 6 | Partially in scope: syntactic-fragment loosenings produce no advisory; other guard changes keep today's conservative advisory with an exact, validated twin rather than a distinct undecidable code. The undecidable code exists only for structurally unpairable families. |

## Acceptance

1. Diffing a workspace against the same Git revision produces zero `AggGuardTightened` findings,
   including Mori's current Language-5 workspace.
2. A minimized fixture covers the shared or expanded guard form responsible for Mori's 36
   `ProjectArtifact` findings and proves identical-source diff idempotence.
3. Adding an unrelated command, event, mapped declaration, or projection owner leaves every
   pre-existing transition's guard classification unchanged.
4. Semantically equivalent guards expressed with harmless association, commutation, or repeated
   terms produce no tightening advisory.
5. A genuinely tightened guard still produces exactly one `AggGuardTightened`, a non-empty removed
   region, the existing compatibility vector, and a paste-ready replay-only twin; the twin parses,
   validates, and silences the finding.
6. A pure guard loosening does not claim that old history became unreadable. If Keiro deliberately
   keeps a conservative advisory for undecidable cases, it uses a distinct truthful code and does
   not present a fabricated removed-region twin.
7. JSON/text reports and replay-impact output agree: an identical-source diff is empty and
   replay-neutral, while a real tightening identifies only its affected aggregate and event
   history.
8. Existing Languages 1–5 parse and scaffold compatibility remains unchanged, and the complete
   `keiro-dsl` diff/conformance suite passes.

## Requested Deliverables

- A symmetric baseline/candidate guard-resolution path and canonical comparison boundary.
- A satisfiability or implication check sufficient to distinguish equivalence, loosening, and real
  tightening for the supported guard expression language.
- Minimal regressions for identical, equivalent, additive-only, loosened, and tightened guards.
- A pinned Mori workspace regression or fixture derived from it, plus updated evolution guidance
  if any diagnostic contract changes.

## References

- Affected package: `mori://shinzui/keiro/packages/keiro-dsl`
- Original Mori adoption evidence:
  `mori://shinzui/mori/plans/223-move-the-mori-workspace-to-keiro-dsl-language-5`
- Current reproducer:
  `mori://shinzui/mori/plans/236-model-project-releases-in-the-registry`
- Related source-stability request:
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-21`
- Existing genuine-tightening remedy: [Plan 143](../plans/143-add-first-class-replay-only-transitions-for-guard-evolution.md)
