---
id: 222
slug: certify-source-stable-semantic-locality-before-fleet-adoption
title: "Certify source-stable semantic locality before fleet adoption"
kind: exec-plan
created_at: 2026-08-09T19:29:29Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md"
---

# Certify source-stable semantic locality before fleet adoption

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This plan is the fleet-adoption gate. It certifies that Keiro's new locality architecture is
correct, mutation-sensitive, deterministic, and materially lower churn before roughly twenty
services depend on it. A minimized workspace and the real Mori Plan 181 scenario prove that only
semantic consumers, context structural conformance, and the isolated behavior source map change.
The complete conformance corpus regenerates once, compiles warning-free, and passes every runtime
assertion.

Completing implementation work is not enough to pass this plan. The plan closes only when missing
evidence and stale source anchors have been falsified, exact byte allowlists pass for single and
workspace paths, wire/fold/snapshot/behavior identities remain frozen, adoption documentation is
published, and IR-21 records implemented evidence. It does not release packages or migrate a
service fleet.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-10T02:52:37Z) Milestone 1: built minimized single/workspace locality fixtures
  with exact generated-tree baselines, a four-file A-only allowlist, explicit source-map/ledger
  provenance exceptions, and constant churn as the workspace grows from two to twelve aggregates.
- [x] (2026-08-10T03:09:12Z) Milestone 2: added and passed restoring correctness mutations for
  service structural evidence, aggregate-use evidence, complete behavior contracts, and moved
  behavior-source anchors; planner anchor failures also prove the output tree stays empty.
- [x] (2026-08-10T03:17:44Z) Milestone 3: replayed the pinned Mori Plan 181 three-field scenario
  read-only, pinned its exact semantic/generated impact set, and measured generated churn falling
  from 22 files/1,869 lines to 9 files/629 lines (8 files/27 lines excluding the isolated map).
- [ ] Milestone 4: regenerate the complete committed corpus once, run full repository/release-
  quality validation, publish adoption guidance, and close IR-21/MasterPlan evidence.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- EP-1 ran the clean-tree corpus policy successfully and found 35 selected scaffold invocations,
  not the 41 estimated while this plan was drafted. `scripts/check-conformance-corpus.sh` also
  proves suite coverage, record/disk consistency, and Cabal inventory consistency; Milestone 4
  must trust that live inventory rather than hard-code an invocation count.
- Mori is under active development while this qualification runs. Resolve its current registered
  path and inspect repository state for orientation, but pin the replay to the before/after
  revisions recorded by Plan 181; never treat a moving working tree as the acceptance baseline or
  write qualification output into Mori.
- The generated-artifact report initially classified aggregate modules in multi-member workspaces
  as generic artifacts because member provenance prefixes the human-readable origin before
  `ModuleRole` is derived. The production classifier now recognizes the preserved `: aggregate `
  owner marker; the focused A-only report contains aggregate-local and service-conformance
  categories while retaining the exact role identity used for migration.
- Source-only movement changes exactly the context `BehaviorSourceMap` generated module plus the
  workspace ledger that records source-bearing role provenance. Every other emitted file remains
  byte-identical, and the scaffold disposition/report identifies only the source-map artifact as
  generated impact.
- Running the pre-existing complete-behavior mutation driver after semantic-impact persistence was
  introduced refreshed its ledger even though all mutated source/generated modules were restored.
  The driver now backs up and restores that ledger too, so both successful and interrupted runs
  preserve every touched tracked byte.
- The pinned Mori replay changes 602 lines in the one context `BehaviorSourceMap`; after separating
  that positional artifact, the semantic generated delta is only 27 lines across three shapes,
  one service structural module, and Project/ProjectArtifact codecs and harnesses. The complete
  generated metric is 629 lines across 9 files, a 66.3% line reduction and 59.1% file reduction
  from the recorded 1,869/22 pre-fix regeneration.
- A fresh scaffold also changes 12 lines in the create-once `Project` binding skeleton so consumers
  can implement the three new optional fields. It is intentionally recorded separately from the
  generated metric: an adopted skeleton is hand-owned and is never overwritten, while both fresh
  revisions must still expose the correct obligation.


## Decision Log

Record every decision made while working on the plan.

- Decision: Gate wide adoption on exact file-tree and evidence-count assertions, not only green
  compilation.
  Rationale: The defect is semantically unrelated churn. Compilation can stay green while global
  duplication silently returns.
  Date: 2026-08-09

- Decision: Use restoring mutations to prove both the centralized declaration laws and localized
  aggregate-use checks have teeth.
  Rationale: Counting assertions cannot show they exercise the correct code. Each ownership layer
  needs a mutation that turns only its intended gate red and restores exact bytes.
  Date: 2026-08-09

- Decision: Perform the Mori replay read-only from the source located by Mori and generate only in
  a disposable Keiro-owned temporary directory.
  Rationale: Cross-repository acceptance evidence is required, but this initiative is not
  authorized to rewrite or commit Mori.
  Date: 2026-08-09

- Decision: Do not publish a Keiro package or start fleet migration in this plan.
  Rationale: Qualification establishes the release candidate baseline. Version selection,
  dependency bounds, tagging, and twenty-service rollout remain separately reviewed changes.
  Date: 2026-08-09

- Decision: Treat the actively developed Mori checkout as read-only orientation and reconstruct
  Plan 181 evidence from its recorded revisions into Keiro-owned temporary directories.
  Rationale: A moving checkout is not a reproducible baseline, and this plan is authorized to
  qualify Keiro rather than coordinate or alter concurrent Mori development.
  Date: 2026-08-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestones 1 through 3 establish the release-candidate locality claim at both scales. The minimized
fixture holds its generated delta constant as ten unrelated aggregates are added, and restoring
mutations prove centralized structural laws, aggregate-local use laws, and exact source anchors
can all fail independently. The pinned real-world replay reduces generated churn from 22 files and
1,869 lines to 9 files and 629 lines; only 27 changed lines remain after excluding the deliberately
isolated positional map. Milestone 4 still owns the one-time corpus migration, documentation,
request/ADR evidence, and full release-quality validation before fleet adoption is allowed.


## Context and Orientation

This plan hard-depends on all output/reporting children:
[Plan 218](218-centralize-structural-conformance-at-the-service-boundary-and-localize-aggregate-harnesses.md),
[Plan 220](220-generate-one-stable-behavior-source-map-from-semantic-anchors.md), and
[Plan 221](221-report-scaffold-and-diff-impact-from-semantic-dependencies.md). Their foundation
plans are transitively required. Run this plan against their final interfaces; do not add test-only
alternate closure or source-map logic.

The committed DSL corpus is regenerated by `keiro-dsl-corpus-regen`, implemented under
[Plan 195](195-build-conformance-corpus-regeneration-tooling.md), and checked by
`scripts/check-conformance-corpus.sh`. At EP-1's checkpoint the policy selected 35 public CLI
invocations and verified that its inventory covers every planned suite and generated conformance
component declared in `keiro-dsl/keiro-dsl.cabal`; the count may change as fixtures evolve, so the
policy's live suite-coverage gate is authoritative. [Plan 196](196-polish-generated-conformance-output-for-maintainers.md)
made that full replay the clean-tree policy and established zero-warning generated compilation.
Because EP-2 and EP-4 both change templates, this plan owns one combined corpus refresh.

Existing restoring gates include `keiro-dsl/test/structural-mutation-test.sh` and
`keiro-dsl/test/behavior-complete-mutation-test.sh`. Extend or add sibling scripts using the same
temporary backup/trap discipline. `keiro-dsl/test/Main.hs` already contains a single/workspace
parity normalization for behavior source lines; this plan removes that exception and requires
exact contract parity, with only the source-map artifact allowed to differ when file qualification
differs.

The real acceptance case is
`mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers`.
It added optional `upstream`/`versionConstraint` fields to three structural payloads used by
Project and ProjectArtifact. The observed pre-fix regeneration changed 1,869 generated Haskell
lines across 22 files: unrelated aggregate harnesses repeated the same optional-field assertions,
and later behavior contracts changed only relocated lines. Use `mori registry show shinzui/mori
--full` and repository-relative paths returned by Mori to locate source; do not put an absolute
sibling path in durable documentation.

[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md),
[ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md),
[ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md),
and [ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md)
define the correctness and ownership claims to falsify. [ADR 0018](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
and [ADR 0003](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md)
protect fold/snapshot identity. No external ADR changes the gate.


## Plan of Work

Milestone 1 creates a dedicated fixture family under `keiro-dsl/test/fixtures` and a focused Hspec
or shell driver. Start with two workspace members and two aggregates. Declare an A-only mapped
record, a nested declaration, a shared declaration, and an unused declaration. Capture old/new
variants for an optional field addition, fixture-symbol change, comment/blank-line insertion,
unrelated top-level declaration, member reorder, and shared-use addition. Scaffold each variant to
fresh directories and compare every relative file byte plus text/JSON reports and ledger rows.

The allowlist is role-based and exact: an A-only shape edit may change its shape module,
Aggregate A's applicable generated codec/harness files, `StructuralConformance`, semantic impact
ledger/report rows, and `BehaviorSourceMap` only when current positions moved. No Aggregate B file
may change. A source-only edit may change only `BehaviorSourceMap` and ordinary provenance/report
bytes that explicitly describe that artifact. Build a parameterized variant with ten unrelated
aggregates and assert the changed generated-file set is constant as unrelated aggregate count
grows. Shared use names both consumers but declaration laws still occur once.

Milestone 2 proves correctness by falsification. Update the structural mutation script so a
transposed binding and missing optional/union fixture fail under the service structural prefix,
while an aggregate mapped-event omission fails under that aggregate. Add a mutation that removes
or changes an aggregate-local use assertion from generated output and ensure the compiled service
gate turns red. Add a pure planner mutation for missing/inexact/duplicate source anchors and assert
stable diagnostic codes plus an empty output tree. Run a failing behavior witness after source
movement and assert the new exact `file:line:column`. Every script restores exact source and
generated bytes even on interruption.

Milestone 3 replays the Mori scenario. Locate the producing repository with Mori, identify the
before/after revisions recorded by its plan, and scaffold both versions with the candidate Keiro
binary into disposable directories without editing Mori. Compare normalized generated roles,
behavior keys, wire/fold/snapshot identities, impact reports, and line counts. The allowed semantic
consumers are Project and ProjectArtifact; the changed structural set is the three payloads; one
service structural module changes; unrelated aggregate trees are byte-identical; positional
movement is isolated to `BehaviorSourceMap`. Record the before/after changed-file and changed-line
counts in this plan's Surprises/Outcomes during execution. If current Mori has evolved beyond the
recorded revisions, use the plan's committed source snapshots or reconstruct those Git revisions;
do not weaken the expected consumer set.

Milestone 4 runs the one deliberate corpus migration. Execute `keiro-dsl-corpus-regen --
regenerate`, review every changed role, update Cabal module inventories for new context modules,
and run the clean-tree corpus checker. Remove old `requirementLine`/`(spec line ...)` pins and any
parity normalization that hides source churn. Run all DSL tests and generated components,
restoring mutations, full repository verification, formatting, Nix checks, ADR/request validation,
and diff hygiene.

Update `docs/user/typed-spec-toolchain.md`, `keiro-dsl/CHANGELOG.md`, and release notes with the
one-time regeneration, semantic-versus-artifact impact output, required service-conformance
execution, and future locality guarantee. Update IR-21 to `implemented` only after its corrected
acceptance bullets link to these tests and the Mori result. Fill every child/master living section
and distill durable decisions into ADRs. State explicitly that fleet adoption may begin only from a
release containing this complete gate; do not tag or publish it here.


## Concrete Steps

Work from the Keiro repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Refresh project/reproducer evidence and verify the corpus tools:

```bash
mori registry show shinzui/keiro --full
mori registry show shinzui/mori --full
mori registry docs shinzui/mori
mori path mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers
cabal run -v0 keiro-dsl-corpus-regen -- check
```

If the current Mori CLI cannot yet resolve the plan artifact, use the registered Mori source path
and its project-relative `docs/plans/181-add-dependency-version-constraints-and-upstream-pointers.md`;
keep only the canonical URI in durable Keiro documents.

Run focused locality and mutation gates:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='semantic locality qualification'
bash keiro-dsl/test/structural-mutation-test.sh
bash keiro-dsl/test/behavior-complete-mutation-test.sh
bash keiro-dsl/test/source-anchor-mutation-test.sh
```

Perform the one corpus refresh and immediately verify it is reproducible:

```bash
cabal run -v0 keiro-dsl-corpus-regen -- regenerate
cabal run -v0 keiro-dsl-corpus-regen -- check
scripts/check-conformance-corpus.sh
```

Run final release-quality acceptance:

```bash
cabal build all
cabal test keiro-dsl:tests
just verify
mori improvement-requests validate --path /Users/shinzui/Keikaku/bokuno/keiro
just adr-validate
nix fmt
nix flake check
git diff --check
git status --short
```

Expected results are zero test/warning/policy failures, a byte-clean second corpus replay, no
unrestored mutation, and a reviewed generated diff containing only planned module-role changes.


## Validation and Acceptance

The minimized A-only optional-field edit changes no Aggregate B generated byte. It changes exactly
the relevant mapped shape, A use-specific outputs, and the single service structural module; the
impact report names A and service conformance only. Adding unrelated aggregates does not increase
the changed-file set. A shared declaration names both real consumers, but declaration-wide
binding/fixture/coverage labels execute once through the service facade.

Comment, blank-line, unrelated declaration, and earlier-member field insertions leave every
semantically unchanged behavior contract, behavior witness, behavior key, transducer, codec,
harness, fold fingerprint, and snapshot discriminator byte-identical. Only the context source map
tracks moved positions. A failing witness reports the current file, line, and column. Missing,
inexact, duplicate, and colliding anchors fail with stable codes before any write.

Every mapped structural type, including unused declarations, retains declaration-wide conformance.
Mutations prove binding inversion, missing branch coverage, aggregate codec/replay use, and source
anchor coherence all turn the correct gate red. Evidence counts in the generated service facade
match the checked service inventory and contain no duplicate keys.

The Mori Plan 181 replay names only Project and ProjectArtifact as aggregate consumers and exactly
the three changed payload declarations, plus service conformance. All other aggregate directories
are byte-identical. Record the measured reduction from the 1,869-line/22-file pre-fix observation;
do not pass merely because the new number is smaller if any unrelated role remains.

The second complete corpus replay is byte-clean, all generated modules compile with `-Wall`, every
DSL test suite and restoring mutation passes, and frozen wire/fold/snapshot/behavior-key baselines
are unchanged. Documentation states the one-time adoption regeneration and blocks wide adoption
on the release containing this evidence. IR-21 and MasterPlan 34 close only after these results are
recorded.


## Idempotence and Recovery

All fixture scaffolds and Mori replays target fresh directories created with `mktemp -d`; scripts
validate the resolved path and remove only their own temporary directory in a trap. Mori source is
read-only. Repeating a fixture or corpus check must produce identical bytes and reports.

The corpus regeneration overwrites only recognized generated files and never overwrites create-once modules,
as established by Plan 195. Review the first diff before accepting it. If any unrelated generated
role changes, repair the owning generator and rerun from the current worktree; do not hand-edit
generated output or accept a broader golden. Mutation scripts preserve backups until restoration
has been verified.

No release operation is recoverable by this plan because no release operation is authorized. Do
not bump versions, edit dependency bounds solely for release, create tags, upload packages, or
write into downstream services. Preserve the qualification evidence if implementation is rolled
back.


## Interfaces and Dependencies

No new runtime or package dependency. This plan consumes the public CLI, `SemanticImpact`,
`StructuralConformance`, `SemanticSourceIndex`, `BehaviorSourceMap`, scaffold ledgers/reports, and
diff JSON delivered by EP-1 through EP-5. Tests must exercise those production interfaces; no
test-only closure or source locator is acceptable.

The fixture comparison helper should expose an equivalent typed result:

```haskell
data GeneratedTreeDelta = GeneratedTreeDelta
  { changedPaths :: !(Set FilePath)
  , addedPaths :: !(Set FilePath)
  , removedPaths :: !(Set FilePath)
  , changedLineCounts :: !(Map FilePath Int)
  }

assertAllowedGeneratedDelta ::
  Set GeneratedModuleRole ->
  GeneratedTreeDelta ->
  Expectation
```

Classify paths through production scaffold module roles/provenance where possible, not filename
substring guesses. The Mori dependency is evidence at
`mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers`; no Mori
API or code is imported. The release skill and fleet rewrite tooling are downstream and out of
scope until this plan and MasterPlan 34 are complete.


## Revision Notes

- 2026-08-10: Recorded that Mori is under active development and made the plan's read-only,
  revision-pinned replay rule explicit before qualification began.
