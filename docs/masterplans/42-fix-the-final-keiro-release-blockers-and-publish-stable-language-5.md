---
id: 42
slug: fix-the-final-keiro-release-blockers-and-publish-stable-language-5
title: "Fix the final keiro release blockers and publish stable Language 5"
kind: master-plan
created_at: 2026-08-14T13:33:12Z
intention: "intention_01m0075g1kecjb2959gy704yhc"
---

# Fix the final keiro release blockers and publish stable Language 5

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The final adversarial review at commit `7ddeaabf1850449241aaf0bd114c41a25455de9d`
found five concrete release blockers and one aggregate Language 5 verdict. The evidence is
preserved as [REV-1](../reviews/awakeable-allocation-api.md),
[REV-2](../reviews/dsl-workflow-awakeable-conformance.md),
[REV-3](../reviews/jitsurei-durable-workflow.md),
[REV-4](../reviews/durable-workflow-user-contract.md),
[REV-5](../reviews/keiro-version-api.md), and
[REV-6](../reviews/keiro-dsl-language-5-stability.md). The Language 5-exclusive parser,
validator, canonical-rendering, diff, generation, and compiled-conformance surfaces passed;
the remaining Language 5 blocker is inherited workflow code that presents a legacy-derived
awakeable id as the id of a fresh allocation.

After this initiative completes, a fresh awakeable is opaque throughout the public runtime,
generated workflow surface, examples, and guides; generated conformance allocates and signals
the real id against PostgreSQL; the runnable durable-workflow demo fails unless signalling
succeeds and the workflow completes; `Keiro.version` is derived from Cabal package metadata;
Language 5 is the sole published stable authoring contract while Language 4 remains readable
as an immutable predecessor; and the six publishable packages are released together as the
0.12.0.0 set. Fresh approval reviews in `docs/reviews/` must pin the post-fix commit and close
every finding before any release tag or upload is created.

This MasterPlan includes only the confirmed blockers and the release path. It does not reopen
the Language 5 feature work completed by MasterPlans 36 and 38, the runtime/rebuild fixes
completed by MasterPlans 37, 39, and 41, or the non-gating consolidation work still tracked by
[MasterPlan 40](40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md).
It does not pull unrelated reliability backlog into 0.12. Release preparation, tagging,
Hackage publication, documentation upload, and the GitHub release are included, but every
irreversible or externally visible release action remains subject to the explicit user
confirmation gates in EP-5.


## Decomposition Strategy

The initiative has five work streams. EP-1 deliberately joins the public awakeable API with
the generated workflow runtime and its database-backed conformance proof. They are one
contract: changing only the runtime name leaves generated code broken, while changing only
the generator leaves an attractive public footgun. EP-2 consumes the corrected contract in
the Jitsurei example and both workflow guides; it is separate because it changes teaching and
application publication behavior rather than runtime identity. EP-3 makes version reporting
mechanical and can proceed independently. EP-4 performs the publication transition for the
language registry, restructures conformance accounting so published Language 4 evidence is
not rewritten as Language 5, and records the post-fix review. EP-5 is the release transaction
and cannot begin until EP-4 has closed the review gate.

Splitting REV-1 and REV-2 into separate plans was rejected because both would edit and test
the meaning of the same `AwakeableId` boundary. Folding the example, version API, registry
promotion, and Hackage upload into one large plan was also rejected: each has an independent
behavioral proof and different failure/recovery semantics, and uploads are irreversible while
the preceding edits are ordinary repository changes. A plan that merely flips Language 5 to
`Stable` was rejected because the current conformance manifest maps almost every
`stable-primary` suite to Language 4; publication must preserve that predecessor corpus rather
than silently relabel or rewrite it.

The relevant local decisions are
[ADR 5](../adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md),
which makes the step index authoritative for a journaled awakeable result;
[ADR 6](../adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md),
which requires the allocated row to exist before an id is exposed;
[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md),
which distinguishes registration from publication and requires published languages to remain
immutable;
[ADR 20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md),
which forbids generator-produced expected and actual values from forming a tautological proof;
[ADR 23](../adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md),
which explains why the broken demo can disappear from discovery while still suspended; and
[ADR 24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md),
which freezes deterministic awakeable ids solely for generation-0 compatibility while fresh
allocations remain random. EP-1 should amend ADR 24 to make the public compatibility boundary
explicit, and EP-4 should amend ADR 16 with the Language 5 publication event and the preserved
Language 4 conformance lane. No cross-repository ADR governs this initiative; Mori inspection
identified it as local to `mori://shinzui/keiro`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Make fresh awakeables opaque across the runtime and generated workflows | docs/plans/260-make-fresh-awakeables-opaque-across-the-runtime-and-generated-workflows.md | None | None | In Progress |
| 2 | Make the durable workflow example and guides prove the live contract | docs/plans/261-make-the-durable-workflow-example-and-guides-prove-the-live-contract.md | EP-1 | None | Not Started |
| 3 | Derive the Keiro version API from package metadata | docs/plans/262-derive-the-keiro-version-api-from-package-metadata.md | None | None | Not Started |
| 4 | Publish stable keiro-dsl Language 5 and close the blocker review | docs/plans/263-publish-stable-keiro-dsl-language-5-and-close-the-blocker-review.md | EP-1, EP-2, EP-3 | None | Not Started |
| 5 | Release the keiro 0.12.0.0 package set | docs/plans/264-release-the-keiro-0-12-0-0-package-set.md | EP-4 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 and EP-3 can begin independently. EP-2 hard-depends on EP-1 because its example must
consume the generated/runtime rule selected there and must compile after the legacy
derivation exports are removed from the ordinary awakeable module. EP-4 hard-depends on
EP-1 through EP-3 because its job is not only to flip the registry but to review and close
all five blockers at one post-fix commit. This keeps a partially repaired tree from being
declared stable. EP-5 hard-depends on EP-4 because release preparation must start from an
approved Language 5 contract and a review bundle with no unresolved release blocker.

Within those constraints, EP-3 may be implemented in parallel with EP-1. After EP-1 lands,
EP-2 may proceed while EP-3 finishes. EP-4 and EP-5 are intentionally serialized release
gates. If any EP-4 review still requests changes, EP-4 remains in progress, the relevant
earlier plan is revised or supplemented, and EP-5 stays blocked.


## Integration Points

The awakeable authoring boundary is shared by EP-1 and EP-2. EP-1 owns the public modules,
the compatibility-only derivation names, and the generated `AwaitBinding` allocation API.
EP-2 must consume the `AwakeableId` returned by `awakeableNamed` or the generated wrapper;
it must never reconstruct an id from workflow coordinates. ADR 24 is the durable owner of
the compatibility constraint.

The workflow conformance corpus is shared by EP-1 and EP-4. EP-1 owns the behavioral repair
and regenerates the affected committed output. EP-4 owns publication maturity and corpus-role
accounting. It must preserve EP-1's live allocate/signal/completion test unchanged while
moving at least one workflow proof into the stable Language 5 lane.

The public package version is shared by EP-3 and EP-5. EP-3 owns the rule that
`Keiro.version` is rendered from Cabal's generated `Paths_keiro.version`. EP-5 changes the
authoritative `version:` field to the confirmed release version and verifies that the public
value follows automatically; EP-5 must not reintroduce a literal.

The assurance-review bundle under `docs/reviews/` is consumed by every plan and owned for
closure by EP-4. EP-1 through EP-3 preserve focused validation evidence in their living
sections. EP-4 allocates new review handles through the bundle profile and records fresh,
commit-pinned approvals; it never rewrites REV-1 through REV-6 to erase the original findings.

The release metadata in the six publishable `.cabal` files and seven changelogs (root plus one
per package) is owned exclusively by
EP-5. Earlier plans may add unreleased changelog bullets for their user-visible changes, but
only EP-5 creates the dated 0.12.0.0 sections, changes the shared versions/internal bounds,
commits the release, tags, uploads, and creates the GitHub release.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1 M1: move deterministic generation-0 derivation out of the ordinary awakeable authoring surface while preserving frozen compatibility probes
- [ ] EP-1 M2: replace generated coordinate derivation with opaque declared await bindings that return the live allocation id
- [ ] EP-1 M3: make workflow-runtime conformance allocate, signal, resume, and complete against PostgreSQL; regenerate all affected outputs
- [ ] EP-1 M4: run focused runtime/DSL gates, update changelogs, and amend ADR 24
- [ ] EP-2 M1: publish the actual allocated id from the Jitsurei workflow through an idempotent application callback
- [ ] EP-2 M2: make the demo and a focused database test fail unless signal succeeds, completion is terminal, and restart discovery is empty
- [ ] EP-2 M3: correct both workflow guides, API reference, signatures, and at-least-once crash-window guidance
- [ ] EP-3 M1: replace the stale `Keiro.version` literal with Cabal-generated package metadata
- [ ] EP-3 M2: make the focused test compare the public value with the authoritative package version and run the Keiro suite
- [ ] EP-4 M1: restructure conformance roles to preserve published Language 4 while making Language 5 the sole stable contract
- [ ] EP-4 M2: add or migrate a real Language 5 workflow proof, flip the registry maturity, regenerate the corpus, and update user documentation
- [ ] EP-4 M3: run the complete blocker matrix and record fresh approval reviews at the post-fix commit
- [ ] EP-5 M1: re-derive the PVP bump, dependency graph, Hackage prerequisites, and changelog coverage; obtain user approval
- [ ] EP-5 M2: update the six package versions/internal bounds and seven changelogs, then pass every release gate
- [ ] EP-5 M3: obtain final approval, commit with plan trailers, create and push annotated package tags
- [ ] EP-5 M4: publish packages and documentation in dependency order, verify live URLs, and create the GitHub release


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- The reviewed runtime already has the correct fresh-allocation behavior: it journals a random
  UUIDv4 and its focused forged-id test passes. The release blocker is an API and first-party
  integration contradiction, not a storage algorithm defect.
- The dedicated workflow-runtime conformance target is green for the wrong reason: it compares
  `deterministicAwakeableId` with itself while the database-backed runtime test proves that id
  cannot signal a fresh allocation. EP-1 therefore replaces, rather than weakens, that test.
- A suspended workflow parked on an unresolved awakeable is deliberately absent from exact
  discovery under ADR 23. The Jitsurei restart check cannot use “nothing discovered” as a proxy
  for completion; it must assert the terminal outcome and journal.
- All five publishable package manifests currently report 0.11.0.0, but `Keiro.version` reports
  0.4.0.0 and its test repeats that stale literal. The release version change itself must remain
  metadata-only after EP-3.
- The conformance baseline currently derives `stable-primary` from the registry's stable pointer.
  Moving the pointer from 4 to 5 without changing the manifest would falsely demand Language 5
  banners from the Language 4 corpus. EP-4 treats publication as an explicit corpus migration,
  not a one-line registry edit.
- Release research found that `keiro-ops/keiro-ops.cabal` is a sixth publishable package at
  0.11.0.0, has no historical package tag, is absent from Hackage, and depends on `keiro`,
  `keiro-migrations`, and `keiro-pgmq`. The existing release skill and Mori package inventory
  predate its creation and list only five publishable packages. EP-5 must repair both inventories
  and publish `keiro-ops` last; omitting it would leave the newly documented operator surface
  unavailable to consumers.
- EP-1 found that the frozen Language 4 skeleton corpus compiles its generated
  `WorkflowRuntime`, so removing the ordinary deterministic awakeable export required an explicit
  runtime-support update in that otherwise frozen corpus. EP-4 must keep the file in the Language
  4 compatibility lane and describe the change as the blocker repair, not as a Language 5 source
  migration or permission for unrelated predecessor rewrites.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Treat REV-1 through REV-5 as release blockers and REV-6 as the aggregate Language 5
  gate; require fresh approval records rather than editing the original findings.
  Rationale: Review records are commit-pinned evidence. Preserving the failed review and adding
  post-fix evidence makes the release decision auditable.
  Date: 2026-08-14
- Decision: Combine runtime awakeable API repair and generated workflow repair in EP-1.
  Rationale: They define one identity contract and one live conformance proof; either half alone
  leaves first-party code capable of signalling an id the runtime rejects.
  Date: 2026-08-14
- Decision: Make the DSL generator expose an opaque declared await binding that allocates through
  `awakeableNamed`, not any coordinate-to-id function.
  Rationale: A binding keeps declared labels type-directed without pretending a fresh id is
  predictable, and lets conformance exercise the real allocation return value.
  Date: 2026-08-14
- Decision: Preserve Language 4 as an explicit published-compatibility corpus when Language 5
  becomes stable.
  Rationale: ADR 16 forbids silently rewriting an immutable predecessor; stable-pointer movement
  must not erase the evidence for sources and generated bytes released under Language 4.
  Date: 2026-08-14
- Decision: Keep non-blocking cleanup and unrelated backlog outside the release gate.
  Rationale: The user requested a blocker-only final pass. Expanding the release transaction would
  increase risk without closing a confirmed release defect.
  Date: 2026-08-14
- Decision: Plan 0.12.0.0 as the shared release version, but retain the release workflow's explicit
  PVP and changelog confirmation before edits and its final approval before tags/uploads.
  Rationale: Prior MasterPlans and current unreleased breaking changes consistently establish the
  0.11.0.0 to 0.12.0.0 major line; irreversible publication still requires current user approval.
  Date: 2026-08-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
