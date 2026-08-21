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
---

# Improvement Request: Make Aggregate Guard Diffs Idempotent and Semantically Exact

## Status

Proposed from
`mori://shinzui/mori/plans/236-model-project-releases-in-the-registry`, after reproducing the
problem with the current published `keiro-dsl` 0.14.0.0 binary and current Keiro `master`.
The same defect was first isolated during
`mori://shinzui/mori/plans/223-move-the-mori-workspace-to-keiro-dsl-language-5`; it is not a
regression introduced by Mori's release model.

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
