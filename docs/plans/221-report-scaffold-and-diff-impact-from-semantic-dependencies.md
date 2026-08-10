---
id: 221
slug: report-scaffold-and-diff-impact-from-semantic-dependencies
title: "Report scaffold and diff impact from semantic dependencies"
kind: exec-plan
created_at: 2026-08-09T19:29:29Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md"
---

# Report scaffold and diff impact from semantic dependencies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, `keiro-dsl diff` and successful scaffold reports explain mapped-type impact in
semantic terms: the changed declaration, the aggregates that consumed it before and after, and the
separate service structural-conformance impact. They no longer call an aggregate impacted because
its old harness repeated global assertions. Source-only movement is reported as a source-map file
change, not as aggregate semantic impact.

Scaffold ledgers persist an additive snapshot of the same checked model so later runs can compare
old and current consumers without re-reading old source. A legacy ledger with no snapshot is
reported as “baseline unavailable”; Keiro never guesses that missing evidence means zero impact.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: define a deterministic semantic-impact snapshot/delta shared by diff and
  scaffold reporting and serialize it as extension-tolerant ledger evidence. Completed
  2026-08-10T01:38:49Z; `cabal build keiro-dsl` and the focused `semantic impact` tests pass.
- [x] Milestone 2: add old/new semantic consumer summaries to single/workspace diff text and the
  append-only JSON report without changing compatibility verdicts. Completed 2026-08-10T01:43:00Z;
  the focused A-only test, `cabal build keiro-dsl`, and `bash keiro-dsl/test/diff-test.sh` pass.
- [ ] Milestone 3: add semantic and generated-artifact impact sections to single/workspace scaffold
  reports, including honest legacy-baseline behavior.
- [ ] Milestone 4: prove mapped locality, source-only neutrality, ledger compatibility, and report
  determinism; update ADRs/docs and pass focused/full tests.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The durable snapshot cannot use a JSON object keyed by `MappedKey` without inheriting Aeson's
  map-key encoding as a file-format contract. Canonical arrays keep names explicit; parsing then
  rejects duplicate declarations, duplicate consumers, and disagreement with the service
  inventory before a scaffold write.
- The workspace diff shell assertion still expected the pre-EP-3 approximate declaration line 3,
  while the exact checked source index correctly reports the enum at line 4. The regression now
  pins the exact line and additionally requires semantic impact in both text and JSON.


## Decision Log

Record every decision made while working on the plan.

- Decision: Report semantic consumer impact separately from generated-file write dispositions.
  Rationale: A changed file is implementation evidence, not dependency authority. Both are useful,
  but conflating them would make a template or source-position change look semantic.
  Date: 2026-08-09

- Decision: Persist consumer snapshots additively in both scaffold ledgers.
  Rationale: Scaffold sees only the current graph; removed declarations and consumers cannot be
  reconstructed correctly from mapping identity rows alone. The existing ledgers are explicitly
  extension-tolerant.
  Date: 2026-08-09

- Decision: Keep existing mapped compatibility findings and gate vectors unchanged.
  Rationale: `MappedDiff` already classifies event, register/snapshot, and consumer-build surfaces
  from complete `UsePath` values. This plan adds an explanation projection, not a second differ.
  Date: 2026-08-09

- Decision: Encode semantic-impact snapshots as sorted declaration rows plus a sorted explicit
  service inventory, and reserve absence of the single ledger row for pre-feature history.
  Rationale: The array encoding is deterministic and validates duplicates explicitly; the
  absent-versus-empty distinction prevents a legacy ledger from claiming zero old consumers.
  Date: 2026-08-10

- Decision: Preserve the existing `diffReport` and `workspaceDiffReport` smart constructors as
  byte-compatible legacy entry points, and add explicit semantic-impact constructors for current
  CLI output.
  Rationale: The CLI must append `semanticImpact` to schema 1, while library callers that explicitly
  selected the old constructor should not receive an unrequested output-byte change.
  Date: 2026-08-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan hard-depends on
[Plan 217](217-define-one-checked-semantic-impact-model-for-keiro-dsl-consumers.md). It consumes
that exact `SemanticImpact`; it must not repeat `UseSite` pattern matches in report code. It
soft-depends on [Plan 218](218-centralize-structural-conformance-at-the-service-boundary-and-localize-aggregate-harnesses.md)
and [Plan 220](220-generate-one-stable-behavior-source-map-from-semantic-anchors.md) so final report
roles name `StructuralConformance` and `BehaviorSourceMap` correctly.

`keiro-dsl/src/Keiro/Dsl/MappedDiff.hs` compares two resolved graphs. Each `MappedFinding` names the
changed declaration and carries complete `UsePath` values from the union of old/new roots.
`keiro-dsl/src/Keiro/Dsl/Diff.hs` turns those paths into compatibility `Change` rows: command roots
are consumer-build, private-event roots are history/rollout, and register roots are snapshot
impact. This behavior is already semantically local and remains authoritative.

`keiro-dsl/src/Keiro/Dsl/DiffReport.hs` emits text and schema
`keiro-dsl/diff-report/1`; object fields are append-only and readers ignore unknown keys.
`keiro-dsl/src/Keiro/Dsl/WorkspaceDiff.hs` adds workspace provenance and ownership movement while
comparing composed service graphs. Neither report currently has a single per-declaration consumer
summary or a separate service-conformance impact.

`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` report every module as created, overwritten,
skipped, or unchanged plus mapping, behavior, ownership, and stale drift. `MappingDrift` compares
declaration-level identities stored by `ScaffoldRecord`/`WorkspaceRecord`, but the records do not
persist aggregate consumers. Therefore a removed declaration's old consumers are unknowable on a
later scaffold unless this plan adds evidence.

`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs` use line-oriented, forward-compatible formats. Known
JSON row kinds are parsed strictly; unknown row kinds and unknown JSON keys are ignored. This is
the intended extension point from [ADR 0022](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md).
[ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
requires attributable, non-destructive history. [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
defines the existing diff compatibility authority, and
[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
defines mapped use paths. No cross-repository ADR applies.


## Plan of Work

Milestone 1 extends EP-1's module, or adds a small `SemanticImpactReport` module, with canonical
snapshot and delta types. A snapshot records every checked mapped key and its sorted
`MappedConsumer` set plus the service-inventory membership implied by the graph. A delta compares
the union of old/new keys and records added/removed aggregate consumers and whether a declaration
change requires the service structural-conformance inventory to rerun. It does not carry source
locations, module paths, or compatibility verdicts.

Serialize the snapshot as canonical single-line JSON under one `semantic-impact ` row in
`ScaffoldRecord` and `WorkspaceRecord`. Known rows reject duplicate keys/consumers and malformed
data; unknown JSON fields remain ignorable. Old records with no row parse successfully as
`Nothing`. New records always write one snapshot, including an empty mapped inventory, so absence
unambiguously means pre-feature history. Add parse/render round trips, old-reader fixtures, unknown
field/row tests, corruption refusals, and deterministic order tests.

Milestone 2 computes old/new `SemanticImpact` beside `diffMapped` in `Diff.hs` and workspace diff.
Filter the delta to declarations with actual `MappedFinding` rows; a pure declaration ownership or
source move is not a mapped schema change. Render a compact section naming before/after aggregate
consumers and `service-conformance: impacted`. Added/removed or currently unused declarations have
honest empty aggregate sets while service conformance remains named. Append a `semanticImpact`
object to `keiro-dsl/diff-report/1`; do not bump the schema or change `Change`,
`CompatibilityVector`, rollout constraints, gate results, or replay impact.

Milestone 3 populates snapshots during single/workspace scaffold planning and carries previous
snapshot evidence into `ScaffoldReport` and `WorkspaceScaffoldReport`. For each changed
`MappingDrift`, compare old/current snapshot when both exist. If the old row is absent, render
`semantic impact baseline: unavailable (legacy ledger); current consumers: ...` and store the new
baseline. Do not make a claim about removed consumers. Render aggregate consumers and the separate
service-conformance role, then render actual changed generated roles from write dispositions:
aggregate modules, `StructuralConformance`, and `BehaviorSourceMap` are distinct categories.

A position-only overwrite of `BehaviorSourceMap` appears only in generated-artifact impact. An
aggregate harness byte change with no semantic consumer delta is labelled generator drift and
covered by a regression test; do not silently include the aggregate in semantic impact to make the
report look consistent. Keep public report record additions explicit in the changelog because
exhaustive library consumers must update.

Milestone 4 adds single and workspace report goldens for A-only, shared, unused, added, removed,
and nested mapped declarations; legacy/current ledgers; member ownership moves; and source-only
movement. Diff a two-aggregate workspace and assert Aggregate B is absent from both text and JSON
for an A-only shape. Reorder declarations/members and assert byte-identical reports. Amend ADR
0015/0022 for the snapshot row and update user guidance for semantic versus artifact impact.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Inventory report and ledger authorities:

```bash
mori registry show shinzui/keiro --full
rg -n 'MappedFinding|mappedFindingChanges|diff-report/1|MappingDrift|ScaffoldReport|WorkspaceScaffoldReport' \
  keiro-dsl/src keiro-dsl/test
rg -n 'renderRecord|parseRecord|renderWorkspaceRecord|parseWorkspaceRecord' \
  keiro-dsl/src/Keiro/Dsl
```

Run focused ledger/diff/scaffold report tests:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='semantic impact ledger'
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='semantic impact report'
bash keiro-dsl/test/diff-test.sh
```

Before closure, run:

```bash
cabal build keiro-dsl
cabal test keiro-dsl:keiro-dsl-test
scripts/check-conformance-corpus.sh
just check-adr
git diff --check
git status --short
```

Expected focused output names Aggregate A and service conformance for an A-only change, never
Aggregate B. Source-only movement names the behavior source-map artifact and no semantic consumer.


## Validation and Acceptance

For a mapped field change reachable only from Aggregate A, diff text and JSON name A, the relevant
old/new root facts, and service structural conformance. Aggregate B and its files do not appear in
semantic impact. The existing detailed mapped changes, compatibility vectors, rollout constraints,
gate result, and replay-impact JSON remain byte-identical except for append-only report fields.

For a shared declaration, the summary names exactly both consumers. For an unused declaration,
the aggregate set is empty and service conformance is impacted. A removed declaration uses the
old snapshot/graph consumers; an added declaration uses the new consumers. Current grammar emits
no read-model consumer and the report does not fabricate one. Future root constructors must extend
EP-1's typed consumer model before this report can compile.

Scaffolding with a current ledger reports the same semantic delta as diff for equivalent old/new
graphs. A legacy ledger says the old baseline is unavailable and records the current snapshot; the
next unchanged run has a complete baseline and no impact. Malformed known snapshot rows refuse
before writes, while unknown row kinds/keys remain compatible.

Adding lines before a later member may overwrite only `BehaviorSourceMap`; it produces no mapped
semantic delta. Module dispositions and semantic impact are both deterministic under member and
declaration reordering. Full tests, diff shell regressions, corpus byte policy, ADR validation, and
diff hygiene pass.


## Idempotence and Recovery

Snapshot derivation and rendering are pure. A successful first run over a legacy ledger adds one
row; subsequent unchanged runs reproduce it byte-for-byte. Ledger parsing completes before any
generated write. A malformed known row refuses and preserves all files.

Never recover missing historical impact by reading generated Haskell, parsing human report text,
or treating absence as an empty set. The operator may run one accepted scaffold to establish the
baseline or use `diff` against source history. Existing non-destructive stale and migration rules
remain unchanged.


## Interfaces and Dependencies

No new dependency. Reuse `aeson`, `containers`, `MappedKey`, `MappedConsumer`, and existing report
JSON helpers. The shared interface must be equivalent to:

```haskell
data SemanticImpactSnapshot = SemanticImpactSnapshot
  { snapshotMappedConsumers :: !(Map MappedKey (Set MappedConsumer))
  , snapshotServiceInventory :: !(Set MappedKey)
  }

data MappedImpactDelta = MappedImpactDelta
  { impactDeclaration :: !MappedKey
  , impactPreviousConsumers :: !(Set MappedConsumer)
  , impactCurrentConsumers :: !(Set MappedConsumer)
  , impactServiceConformance :: !Bool
  }

semanticImpactSnapshot :: SemanticImpact -> SemanticImpactSnapshot
diffSemanticImpact :: SemanticImpactSnapshot -> SemanticImpactSnapshot -> [MappedImpactDelta]
```

`ScaffoldRecord` and `WorkspaceRecord` gain `Maybe SemanticImpactSnapshot` for parsed historical
state and write a present current snapshot. Public scaffold report records gain a typed impact
field rather than only rendered text. `DiffReport` JSON appends an ignore-unknown
`semanticImpact` object with sorted declarations and consumers. EP-6 consumes the final text/JSON
and ledger behavior as its adoption evidence.


## Revision Notes

- 2026-08-10: Recorded Milestone 1's canonical snapshot/delta implementation, ledger compatibility
  evidence, and the durable absent-baseline encoding decision so the plan remains restartable.
- 2026-08-10: Recorded Milestone 2's single/workspace diff summaries, append-only JSON projection,
  exact-location shell evidence, and compatibility-preserving public constructor decision.
