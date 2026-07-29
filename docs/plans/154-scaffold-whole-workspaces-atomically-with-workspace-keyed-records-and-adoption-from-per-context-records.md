---
id: 154
slug: scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records
title: "Scaffold whole workspaces atomically with workspace-keyed records and adoption from per-context records"
kind: exec-plan
created_at: 2026-07-29T14:09:13Z
intention: "intention_01kyq39tsbepwt43q6db89h0d7"
master_plan: "docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md"
---

# Scaffold whole workspaces atomically with workspace-keyed records and adoption from per-context records

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today `keiro-dsl scaffold` takes exactly one `.keiro` specification file and writes one
generated module tree, one build manifest, and one scaffold record into `--out`. Both the
record and the manifest are keyed **only by the spec's context name**
(`keiro-dsl-scaffold-record.<context>.txt`, `keiro-dsl-manifest.<context>.txt`), and mapped
structural declarations emit **one context-level `StructuralProjections` facade** whose module
name is derived purely from the context. The consequence, proven by an existing test in
`keiro-dsl/test/Main.hs` ("reports the entire old tree across a module-root flip", lines
2152-2162), is that two specifications sharing one context but scaffolded independently into
one output directory replace each other's record, flag each other's modules as stale, and
overwrite the shared context facade from whichever spec ran last — an incomplete view of the
mapped-type graph.

After this plan, `keiro-dsl scaffold` also accepts a **service workspace manifest** (the
`.keiro-workspace` file delivered by the sibling plan
`docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md`,
called EP-1 below). One invocation plans the complete generated module set for **all** member
`.keiro` files before writing a single byte: every pure refusal — case-folded path collisions,
generated/consumer import cycles, firewall breaches, lowering refusals, missing generated
banners — is computed across the entire merged module set first. The context-level
`StructuralProjections` facade and the context-level `ReplayAudit` assembly module are emitted
exactly once from the merged graph. History is kept in a new **workspace-keyed** scaffold
record (`keiro-dsl-scaffold-record.workspace.<service>.txt`) that also remembers, for every
emitted module, **which member file produced it** — so moving an aggregate from one member
file to another is reported as an ownership move, not as a stale/new pair. Running the same
workspace twice is provably idempotent (the report shows every generated module as
`unchanged`), reordering manifest members produces byte-identical output, and a failure in any
member leaves the output tree, record, and manifest untouched. Finally, the first workspace
scaffold into an output directory that already holds legacy per-context records imports their
file sets with explicit provenance and emits a human-readable migration report instead of
silently claiming or clobbering anything. The single-file CLI path keeps its current
context-keyed record names and byte-identical behavior throughout.

To see it working after implementation, from the repository root
(`/Users/shinzui/Keikaku/bokuno/keiro`):

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/workspace/service.keiro-workspace --out /tmp/ws-demo
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/workspace/service.keiro-workspace --out /tmp/ws-demo
```

The first run prints one plan covering every member's modules with exactly one
`StructuralProjections` line and writes `keiro-dsl-scaffold-record.workspace.<service>.txt`;
the second run's report shows every generated module as `(unchanged)` and no stale section.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Confirm EP-1 (plan 153) is Complete: `.keiro-workspace` grammar, `Keiro.Dsl.Workspace`
      loader/`WorkspaceSpec`, per-declaration/per-node owner map, effective context, CLI
      dispatch, and compose-time conflict refusals are merged. Record the actual exported
      names and any deviations from the working names assumed in this plan. — 2026-07-29
      (names as assumed: `WorkspaceSpec`, `wsMergedSpec`, `wsOwnership`, `wsMembers`,
      `wmPath`/`wmSpec`, `declarationOwner`, `nodeOwner`, `oneMemberWorkspace`,
      `loadWorkspace`, `checkWorkspace`, `fileContentSource`, `isWorkspacePath`. One
      deviation with consequences: `Keiro.Dsl.Workspace` **imports**
      `Keiro.Dsl.ScaffoldRun`, so this plan's new functions cannot live there — see the
      Decision Log.)
- [x] M1: Create `keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs` with `WorkspaceRecord`,
      `renderWorkspaceRecord`, `parseWorkspaceRecord`, `workspaceRecordFileName`,
      `workspaceManifestFileName`; register the module in `keiro-dsl/keiro-dsl.cabal`.
      — 2026-07-29
- [x] M1: Round-trip, forward-compatibility (unknown rows), path-safety, and
      name-non-collision tests for the workspace record in `keiro-dsl/test/Main.hs`
      (describe-group `workspace record`). — 2026-07-29
- [x] M1: Add `planWorkspaceScaffoldWithGoldens`, `WorkspacePlan`, `ModuleProvenance` — in
      the new `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` rather than `ScaffoldRun.hs`
      (module cycle; Decision Log); module set built once from the merged spec with
      structural per-declaration and per-node ownership attribution and
      member-path-augmented origins. — 2026-07-29
- [x] M1: Golden-root divergence refusal (`GoldenRootDivergence`) as an IO preflight
      (`goldenRootDivergence`), with the workspace golden root carried on `WorkspacePlan`.
      — 2026-07-29
- [x] M1: Plan-phase tests: cross-member case-folded collision cites both member files;
      facade and replay-audit emitted once from merged graph; one-member workspace module
      set *and refusal set* identical to the single-file path; obligations computed from
      the complete merged graph and spanning members. — 2026-07-29
- [x] M1 commit with the mandated trailers. — 2026-07-29
- [x] M2: Add `executeWorkspaceScaffold`, `WorkspaceScaffoldReport`, `OwnershipMove`, and
      `renderWorkspaceScaffoldReport` to `WorkspaceScaffold.hs`, and the `Unchanged`
      disposition to `ScaffoldRun.hs` (where `WriteDisposition` lives). — 2026-07-29
- [x] M2: Wire the workspace branch of the `Scaffold` command in `keiro-dsl/app/Main.hs`
      through EP-1's dispatch (validation gate, context precedence, goldens, plan, execute).
      — 2026-07-29
- [x] M2: Filesystem tests: whole-workspace stale detection without cross-member false
      positives; idempotent second run reports zero changes; member reorder produces
      byte-identical trees/record/manifest; any-member failure leaves tree, record, and
      manifest untouched; ownership move reported when a node moves between members; plus a
      bannerless-target refusal test and an end-to-end CLI test. — 2026-07-29
- [x] M2: Regression guard: full existing `keiro-dsl-test` suite passes unchanged
      (359 examples, 0 failures); single-file record names and bytes pinned by the
      pre-existing `structural scaffold record` and `scaffold gates` groups. — 2026-07-29
- [x] M2 commit with the mandated trailers. — 2026-07-29
- [x] M3: Adoption path in the new `keiro-dsl/src/Keiro/Dsl/WorkspaceAdoption.hs`: legacy
      per-context record discovery, claim rules (record-attributed or banner-attributed
      only), `MigrationReport`, persisted
      `keiro-dsl-migration-report.workspace.<service>.txt`, `superseded-by:` marker append.
      — 2026-07-29
- [x] M3: Adoption tests: import from an overwritten same-context record pair (both evidence
      kinds); unclaimed hand-written files listed and untouched; a bannerless Generated
      target still refuses and writes no report; legacy record still parses after the marker
      and gained exactly that one line; second workspace run performs no adoption and is
      idempotent. — 2026-07-29
- [x] M3: New ADR for the workspace scaffold-history and adoption model
      (`docs/adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md`,
      handle `ADR-15` allocated with `okf id next`), `log.md` updated with `okf log add`,
      `just adr-validate` green (`OK: 15 concepts`). — 2026-07-29
- [x] M3 commit with the mandated trailers. — 2026-07-29
- [x] Final: update MasterPlan 26 Progress entries for EP-2, write Outcomes & Retrospective,
      perform the ADR distillation pass (ADR-15 carries every durable decision; the rest is
      task-local and stays here). — 2026-07-29


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`Keiro.Dsl.Workspace` imports `Keiro.Dsl.ScaffoldRun`, so the workspace scaffold
  functions cannot live in `ScaffoldRun`.** EP-1's cross-member collision check calls
  `planScaffoldWithGoldens` (`keiro-dsl/src/Keiro/Dsl/Workspace.hs` line 100 imports
  `Keiro.Dsl.ScaffoldRun (Refusal (..), planScaffoldWithGoldens)`), so a
  `planWorkspaceScaffoldWithGoldens :: … -> WorkspaceSpec -> …` in `ScaffoldRun` would be a
  module cycle. The work landed in a new module `Keiro.Dsl.WorkspaceScaffold` instead, and
  `ScaffoldRun` grew a small documented export section for the pieces the workspace path
  reuses (`pureRefusals`, `missingGeneratedBanners`, `staleAgainst`, `constraintPlan`,
  `mappingDrift`, `newBindingObligations`, plus two render helpers). Nothing was
  duplicated. (2026-07-29)

- **The one-member-workspace equivalence is stronger than planned: it holds for refusals
  too.** The plan asked for module-set equality on fixtures that plan successfully. The
  test as written compares `Either [Refusal] [ScaffoldModule]` for four fixtures, and
  `test/fixtures/hospital-surge.keiro` refuses identically on both paths:

  ```text
  Left [LoweringRefusal ["AggregateEmpty: aggregate 'Surge' must declare at least one
  command, event, and transition", …]]
  ```

  That is a better test than the planned one — it proves the gates agree, not only the
  emitters — and it is why the member-path prefix on `origin` is suppressed for a
  one-member workspace (Decision Log). (2026-07-29)

- **Adoption provenance was silently dropped by the next run, and the one-shot test caught
  it.** The first draft wrote `wrAdopted` only from the current run's migration report, so
  the second (non-adopting) run rewrote the record with an empty `adopted` list — the
  workspace forgot where its files came from, one run after learning it. The
  "adopts at most once" test failed on a whole-tree byte comparison:

  ```text
  1) workspace adoption, adopts at most once, and the second run is an ordinary
     idempotent run
       expected: […keiro-dsl-scaffold-record.workspace.adoption-demo.txt with adopted rows…]
        but got: […the same record without them…]
  ```

  Fixed by carrying the previous record's rows forward whenever a run adopts nothing.
  Adoption provenance is durable history, not a per-run note. (2026-07-29)

- **Binding skeleton modules are grouped by owning module, not by declaration.**
  `bindingSkeletonModules` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) groups obligations by
  `obligationModule`, and its own comment says "Multiple mapped declarations may
  intentionally share a leaf binding module". In a workspace those declarations can be
  owned by *different* members, so a single skeleton has no single owner. The attribution
  rule handles it explicitly (Decision Log); EP-3 must expect skeletons to appear as
  context-level in the record whenever their declarations span members. (2026-07-29)


## Decision Log

- Decision: Workspace history files are keyed by a `workspace.<service>` slot:
  `keiro-dsl-scaffold-record.workspace.<service>.txt` and
  `keiro-dsl-manifest.workspace.<service>.txt`, not the bare
  `keiro-dsl-scaffold-record.<service>.txt` working proposal from MasterPlan 26.
  Rationale: a context name is lexed by `wireWord` in
  `keiro-dsl/src/Keiro/Dsl/Parser.hs` (lines 210-216) as letters/digits/underscore/dash —
  it can never contain a dot — so the `workspace.<service>` key provably never collides
  with any legacy context-keyed name produced by `recordFileName`
  (`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` lines 115-116), even in the very likely
  case where the service is named after its context (Kotei's service and context would
  both be `kotei`). Under the bare proposal that case would alias the legacy record path,
  and an old keiro-dsl binary running a single-file scaffold would fail to parse the
  workspace record at that path, treat the directory as history-free, and overwrite it
  with a v1 record — silent destruction of workspace history by an older tool. Distinct
  names make old binaries structurally incapable of touching workspace history and keep
  legacy records inspectable during and after adoption.
  Date: 2026-07-29

- Decision: Coexistence rule — the workspace scaffold path never reads or writes
  context-keyed file names except during the explicit M3 adoption step (read, then append
  one marker line); the single-file path is not modified at all, keeping its current names
  and output bytes. Adoption marks an imported legacy record by appending a
  `superseded-by: keiro-dsl-scaffold-record.workspace.<service>.txt` line; the v1 parser
  ignores unknown lines (proven by the existing test at `keiro-dsl/test/Main.hs` line 2191,
  which inserts an unknown row and asserts the parse is unchanged), so old binaries still
  read the legacy record. Nothing is renamed or deleted.
  Rationale: IR-2's migration section demands "must not silently claim ownership of
  hand-written files or delete anything"; MasterPlan 26's Decision Log fixes that the
  single-file path keeps current context-keyed names and bytes. Appending a
  forward-compatible marker is the only in-place option that leaves both old-binary
  behavior and human inspection intact while making supersession visible.
  Date: 2026-07-29

- Decision: The whole-workspace module set is produced by the existing single emission
  registry (`scaffoldModulesWithGoldens` in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` lines
  83-102) applied to EP-1's **merged spec**, not by concatenating per-member scaffolds.
  Ownership is attributed structurally: context-level emitters (`scaffoldStructural`'s
  facade, `scaffoldReplayAudit`) are tagged `ContextLevel`; per-node and per-declaration
  emitters are tagged with the owning member file from EP-1's owner map.
  Rationale: emitting from one merged spec makes "facade emitted once from the complete
  mapped graph" true by construction, makes the one-member workspace byte-identical to the
  single-file path by construction (same functions, same order, same input), and lets every
  existing pure refusal gate (`collisionRefusals` lines 168-178, `dependencyRefusals` lines
  121-138, firewall, lowering) run unchanged over the complete set. Concatenating
  per-member scaffolds would emit the facade N times from N incomplete graphs — the exact
  defect this plan fixes.
  Date: 2026-07-29

- Decision: The workspace record is a **new schema in a new module**
  (`keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs`, header line
  `keiro-dsl workspace scaffold record v1`) rather than a v2 of
  `Keiro.Dsl.ScaffoldRecord`. Module rows are canonical single-line JSON after a `module `
  prefix (kind, path, optional owner member), following the precedent set for `mapping `
  rows in plan 150.
  Rationale: leaving `ScaffoldRecord.hs` untouched makes "single-file record names and
  bytes unchanged" provable by the existing pinned tests instead of by argument; the
  workspace record needs fields the v1 line grammar cannot carry without ambiguity
  (per-module owner paths, member list, adoption provenance), and JSON rows avoid a second
  ad hoc token grammar while staying forward compatible (unknown row kinds and unknown JSON
  keys are ignored).
  Date: 2026-07-29

- Decision: One golden-payload root per workspace: `--goldens DIR` if given, otherwise
  `takeDirectory manifestPath </> "golden-payloads"`. During planning, each member's own
  adjacent `golden-payloads` directory is probed for fixtures that the member's declared
  upcasters would load but that are absent from the workspace root; any hit is a new
  plan-phase refusal (`GoldenRootDivergence`) listing the exact fixture paths to move.
  Rationale: golden fixtures are keyed `<context>/<Aggregate>/<Event>.v<N>.json`
  (`keiro-dsl/src/Keiro/Dsl/Goldens.hs`), i.e. by aggregate, and aggregates have exactly
  one owner across the workspace — so one root cannot collide, while per-member roots would
  make a fixture's location depend on which file currently owns the aggregate, breaking the
  "ownership move is not a content change" property. Silently failing to find a
  member-adjacent fixture would swap an embedded file-owned golden for a synthesized
  stand-in and change harness bytes without any diagnostic — exactly the class of silent
  divergence IR-2 forbids and ADR-4 says must be refused at the earliest boundary.
  Date: 2026-07-29

- Decision: Adoption claims an on-disk file into the new workspace record only when it is
  attributable: either listed in a discovered legacy per-context record for the workspace's
  effective context (provenance `record`), or sitting at a planned Generated path with the
  `-- @generated` banner (provenance `banner`, covering files orphaned when one legacy
  record overwrote another — the known defect). Hole paths are never claimed; the
  create-once rule keeps governing them. Everything else on disk is reported as
  unclaimed/hand-written and left untouched. The migration report is printed and also
  persisted once as `keiro-dsl-migration-report.workspace.<service>.txt` in the out
  directory, only on the adopting run.
  Rationale: IR-2 permits "import the existing manifests, require a reviewed baseline, or
  emit a migration report, but it must not silently claim ownership of hand-written files
  or delete anything"; the banner is the codebase's existing attribution mechanism (the
  banner preflight in `ScaffoldRun.hs` lines 286-297 already treats bannerless files at
  Generated paths as hand-adopted and refuses). Persisting the report gives the reviewed
  baseline IR-2 suggests without blocking on interactive approval.
  Date: 2026-07-29

- Decision: Record the workspace scaffold-history and adoption model as a **new ADR**,
  with its handle allocated by `okf id next docs/adr --profile docs/adr/profile.dhall ADR`
  (expected but not assumed to be ADR-15, one past EP-1's expected ADR-14), rather than
  extending EP-1's workspace-identity ADR.
  Rationale: the `docs/adr` bundle's profile is one decision per file. Workspace identity
  (what names a workspace) and scaffold history (how records are keyed, how ownership and
  adoption work, the superseded marker) are separable durable judgments with different
  lifecycles; MasterPlan 26's Integration Points explicitly allows "extending EP-1's ADR or
  adding its own". Fallback: if EP-1's ADR turns out to already fix record file naming,
  amend that ADR for the naming portion and scope the new ADR to history/adoption only.
  Date: 2026-07-29

- Decision: Workspace execution makes idempotence observable: the workspace write path
  compares existing bytes before writing a Generated module and reports (and skips) an
  `Unchanged` disposition when equal. The single-file `writeModule` (lines 299-311 of
  `ScaffoldRun.hs`) is not modified.
  Rationale: the MasterPlan milestone requires "running the same workspace twice is
  idempotent (report proves zero changes)"; today's `Overwritten` disposition cannot
  distinguish a byte-identical rewrite from a change. Confining the new disposition to the
  workspace path preserves single-file report bytes.
  Date: 2026-07-29


- Decision: Whole-workspace planning and execution live in a new module
  `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`, not in `ScaffoldRun.hs` as this plan
  originally specified. `ScaffoldRun` exports the gates and helpers the workspace path
  reuses under a documented "Shared with whole-workspace scaffolding" section.
  Rationale: `Keiro.Dsl.Workspace` imports `Keiro.Dsl.ScaffoldRun` for EP-1's cross-member
  collision check, so a `WorkspaceSpec`-taking function in `ScaffoldRun` is a module cycle.
  Exporting the gates keeps the "reuse, never duplicate" property the plan required — a
  workspace and a single spec still run literally the same `pureRefusals`,
  `missingGeneratedBanners`, and stale comparison — while removing the cycle. The single
  alternative (moving EP-1's collision check out of `Workspace`) would have re-opened
  merged code for no behavioral gain.
  Date: 2026-07-29

- Decision: Module ownership is attributed **structurally**, through two new seams in
  `Keiro.Dsl.Scaffold` — `scaffoldStructuralOwners` (each structural module paired with the
  mapped declarations it was emitted for) and `bindingSkeletonOwners` — plus `nodeIdentity`
  for node-produced modules. The `origin` string is never parsed.
  Rationale: MasterPlan 26's Surprises section records that EP-1 had to recover ownership by
  parsing `nodeOrigin`'s `(line N)` suffix and asks EP-2 to make ownership first-class. Both
  new functions are defined so the existing ones are `map fst` of them, which makes the
  emitted set provably unchanged rather than argued to be.
  Date: 2026-07-29

- Decision: A structural module is `MemberOwned` only when *every* declaration it was
  emitted for resolves to the same member; otherwise it is `ContextLevel`.
  Rationale: binding skeletons group by owning module, and two mapped declarations owned by
  different members may legitimately share one leaf binding module. Attributing such a
  skeleton to one of them would make the other member's obligations look like an ownership
  move whenever the grouping order changed. Context-level is the honest answer: the module
  belongs to the service, not to a member.
  Date: 2026-07-29

- Decision: The member-path prefix on a module's `origin` is added only when the workspace
  has more than one member.
  Rationale: the prefix exists to disambiguate a cross-member refusal; with one member there
  is nothing to disambiguate, and suppressing it makes the one-member workspace identical to
  the single-file path in *every* field of `ScaffoldModule`, so the equivalence test can
  compare whole values instead of a projection.
  Date: 2026-07-29

- Decision: `planWorkspaceScaffoldWithGoldens` takes the resolved golden root as an extra
  argument and `WorkspacePlan` carries it; the golden-root divergence check is the IO
  function `goldenRootDivergence`, run as a pre-write preflight beside the banner check
  rather than inside the pure plan. `GoldenRootDivergence` carries the root as well as the
  stranded fixture paths.
  Rationale: deciding whether a member-adjacent fixture exists and the workspace root lacks
  it is a filesystem question, so it cannot be a pure plan-phase gate. The contract this plan
  actually owes (MasterPlan 26 Decision Log) is *detection before the first write*, which a
  preflight satisfies exactly as the pre-existing banner check does. Carrying the root in the
  refusal lets the message name where to move the files.
  Date: 2026-07-29

- Decision: The adoption model lives in its own module,
  `keiro-dsl/src/Keiro/Dsl/WorkspaceAdoption.hs`, rather than inside
  `Keiro.Dsl.WorkspaceRecord` (the plan offered either).
  Rationale: `WorkspaceRecord` is a persistence schema — pure, no filesystem. Adoption walks
  the output tree, reads legacy records, and inspects banners. Keeping the schema free of IO
  keeps its round-trip property easy to state and test, and gives the adoption rules one
  place to be read and argued about.
  Date: 2026-07-29

- Decision: A run that adopts nothing carries the previous record's `adopted` rows forward.
  Rationale: found by the one-shot test (Surprises). Adoption provenance answers "where did
  these files come from", which stays true forever; recomputing it per run would erase it on
  the very next scaffold. The `adopted` rows are history, and history accumulates.
  Date: 2026-07-29

- Decision: The unclaimed list excludes planned Generated paths.
  Rationale: the report says unclaimed files are "left untouched", and a file at a planned
  Generated path is about to be written by this very run (either it carries the banner and is
  claimed, or the run already refused, or `--force-generated-overwrite` was passed). Listing
  it as untouched would be false. What remains is genuinely untouched: files at hole paths,
  which the create-once rule protects, and files the plan never mentions.
  Date: 2026-07-29

- Decision: `wsrMigration` is added to `WorkspaceScaffoldReport` in M3, when
  `MigrationReport` exists, rather than being introduced in M2 as a permanently-`Nothing`
  field of a stub type.
  Rationale: the plan sketched the field in M2's record for completeness, but a record field
  whose type has no inhabitants yet is a placeholder, not a contract. Adding it with its type
  in one change keeps every intermediate commit honest.
  Date: 2026-07-29

- Decision: The ownership-move test moves the aggregate to the *front* of the receiving
  member so that the merged spec's node order is unchanged.
  Rationale: the replay-audit assembly lists aggregates in merged-spec order, so moving a node
  to the end of another member would legitimately change one generated file and muddy the
  "an ownership move is not a content change" claim. Prepending isolates the change to
  ownership, and the test then asserts every disposition is `Unchanged`/`Skipped`, which is
  the strongest form of that claim.
  Date: 2026-07-29

- Decision: The workspace record stores the manifest's **file name** (`manifest:`), not the
  path the user typed.
  Rationale: members are relative to the manifest's directory, so the directory is wherever
  the manifest sits; recording the invoking path would make the record's bytes depend on the
  working directory and would break the byte-identical-output property the determinism test
  asserts across two temp directories.
  Date: 2026-07-29


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

**Delivered, against the original purpose.** `keiro-dsl scaffold
<manifest>.keiro-workspace --out DIR` plans and emits the complete generated module set
for every member in one invocation. All eight acceptance bullets in Validation and
Acceptance are observable, each pinned by a test in `keiro-dsl/test/Main.hs` under
`workspace record`, `workspace plan`, `workspace scaffold`, and `workspace adoption`. The
suite went from 351 to 363 examples, 0 failures, with the pre-existing single-file tests —
including the record pin and the module-root-flip test whose behavior this plan
deliberately preserves — untouched and passing.

The manual check from Concrete Steps behaves as the plan predicted:

```text
$ cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/workspace/service.keiro-workspace --out /tmp/ws-demo
workspace: demo-project (…/service.keiro-workspace) -> /tmp/ws-demo (module-root=Demo.Modules.Project, layout=collocated)
members:  domain/project-artifact.keiro, domain/project.keiro, domain/shared.keiro
  generated  …Generated.StructuralProjections   (overwritten)  (context-level)
  generated  …Generated.ReplayAudit             (overwritten)  (context-level)
  generated  …Project.Generated.Domain          (overwritten)  domain/project.keiro
  …
record:   /tmp/ws-demo/keiro-dsl-scaffold-record.workspace.demo-project.txt

$ cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/workspace/service.keiro-workspace --out /tmp/ws-demo
  generated  …Generated.StructuralProjections   (unchanged)  (context-level)
  …
```

Exactly one `StructuralProjections` and one `ReplayAudit`, both context-level; every
member-owned module names its member; the second run rewrites nothing.

**Deviations from the plan as written**, all in the Decision Log with rationale: the code
landed in two new modules (`Keiro.Dsl.WorkspaceScaffold`, `Keiro.Dsl.WorkspaceAdoption`)
rather than in `ScaffoldRun.hs`, because `Keiro.Dsl.Workspace` imports `ScaffoldRun`;
`planWorkspaceScaffoldWithGoldens` gained the golden-root argument and the golden-root
divergence check is an IO preflight rather than a pure plan gate; `GoldenRootDivergence`
carries the root as well as the stranded paths; and `wsrMigration` arrived with its type in
M3 instead of as a stub in M2.

**What the tests taught, beyond passing.** Two of them changed the design. The one-member
equivalence test was written to compare `Either [Refusal] [ScaffoldModule]` rather than only
the success case, which proved the *gates* agree as well as the emitters — and forced the
decision to suppress the member-path origin prefix for a single-member workspace so the
comparison could be total. The adoption one-shot test compared whole trees and caught the
record silently losing its `adopted` rows on the second run.

**Gaps and follow-ups, none blocking.**

- EP-3 (plan 155) must classify an ownership move exactly as `OwnershipMove` records it:
  path unchanged, owner changed, no stale and no new entry. `provenanceOwner` and the
  record's optional `owner` field are the shared vocabulary.
- EP-4 (plan 156) can promote `keiro-dsl/test/fixtures/workspace/` as its fleet-style
  fixture; it already exercises three members, a shared declaration owner, two aggregates in
  different files, and a read model. The adoption end-to-end story it tests is implementable
  from `withInlineWorkspace` plus `adoptionMembers` in `keiro-dsl/test/Main.hs`.
- A binding skeleton whose obligations span two members is recorded as context-level. No
  fixture exercises that shape yet — the rule is implemented and commented but only
  indirectly covered. Worth a fixture when a real multi-member mapped graph appears.
- Migration report content is asserted structurally (claimed sets, evidence kinds, unclaimed
  sets) rather than pinned as golden text, deliberately: the wording should be free to
  improve without a test edit.


## Context and Orientation

This repository is the Keiro event-sourcing stack. The package this plan changes is
`keiro-dsl` (the `.keiro` spec language and CLI toolchain, sources under
`keiro-dsl/src/Keiro/Dsl/`, CLI in `keiro-dsl/app/Main.hs`, hspec suite in
`keiro-dsl/test/Main.hs`, test-suite name `keiro-dsl-test` in `keiro-dsl/keiro-dsl.cabal`).
All commands in this plan run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Definitions used throughout. A **spec** is one parsed `.keiro` file (`Spec` in
`Keiro.Dsl.Grammar`), opening with a `context <name>` clause; the context name is a
`wireWord` (letters, digits, underscore, dash — never a dot; `keiro-dsl/src/Keiro/Dsl/Parser.hs`
lines 210-216). A **scaffold** run turns a spec into Haskell files of two kinds
(`ModuleKind` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` lines 96-101): **Generated** modules
carry a `-- @generated` banner and are overwritten on every run, and **HoleStub** ("Holes")
modules are hand-owned, created only when absent, never overwritten. The **scaffold record**
is a small text file the scaffolder writes beside its output listing every file it produced,
so the next run can report files that are no longer produced ("stale") without ever deleting
anything. The **build manifest** is a Cabal-pasteable text summary (`other-modules:`,
`build-depends:`, consumer blocks) rendered by `renderManifest` in
`keiro-dsl/src/Keiro/Dsl/Manifest.hs`. A **workspace** is EP-1's new unit: a
`.keiro-workspace` manifest file naming a service and an explicit list of member `.keiro`
files that together form one service contract. The **service name** on the manifest's
`service <name>` line is the stable workspace identity this plan keys history by.

### The current single-spec pipeline, verified in the working tree

`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` separates pure planning from execution so every
refusal is known before the first output byte is written:

- `scaffoldModulesWithGoldens` (lines 83-102) is the single emission registry:
  `scaffoldStructural ctx spec <> scaffoldReplayAudit ctx spec <> concat [per-node emitters]`.
  Two of its products are **context-level**, meaning their module names contain no node
  segment: the structural-projection facade (see below) and the `ReplayAudit` assembly
  module (`scaffoldReplayAudit`, `Scaffold.hs` lines 1100-1145, emitted whenever the spec
  has aggregates; it imports every aggregate's generated `EventStream`).
- `planScaffoldWithGoldens` (lines 110-119) accumulates **all** pure refusals before any
  write: `collisionRefusals` (lines 168-178, case-folded module-path collisions with every
  origin listed), `dependencyRefusals` (lines 121-138, consumer-module/generated-path
  collisions and generated/consumer import cycles), firewall breaches, and lowering
  refusals. A refusal result carries no write set at all.
- `executeScaffold` (lines 184-217) evaluates `missingGeneratedBanners` (lines 286-297)
  over the complete module set **before** `createDirectoryIfMissing` or any write: an
  existing file at a Generated path without the `-- @generated` banner refuses the whole
  run (overridable with `--force-generated-overwrite`). It then reads the previous record
  from `out </> recordFileName (specContext spec)` (line 190), computes `existingStale`
  (lines 266-273: files in the previous record no longer in the new plan and still on
  disk), writes every module via `writeModule` (lines 299-311: Generated overwritten
  unconditionally, HoleStub skipped when present), writes the manifest to
  `out </> "keiro-dsl-manifest." <> context <> ".txt"` (line 199), and rewrites the record
  (line 201).
- `renderScaffoldReport` prints a `previousSpecNote` (lines 399-405) when the record's spec
  path differs — literally warning that "specs sharing context ... in one --out also
  share" the manifest — and a stale section (lines 416-425) ending with
  "keiro-dsl never deletes files."

`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` defines the v1 record: header line
`keiro-dsl scaffold record v1`; exactly-once `spec:`, `module-root:`, `layout:` fields;
`generated <path>` / `hole <path>` file rows; `mapping <json>` and `binding <json>` rows;
unknown lines ignored for forward compatibility; absolute paths and `..` segments rejected.
`recordFileName` (lines 115-116) is `"keiro-dsl-scaffold-record." <> context <> ".txt"`.
Note what the record does **not** carry: any notion of which source file produced which
module, and any identity beyond the context embedded in its file name.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` defines `Context` (lines 107-114:
`contextName`, `moduleRoot`, `placement`). `scaffoldStructural` (lines 398-415) emits, from
the resolved mapped-type graph, per-declaration `Structural.Shape.*` modules, per-declaration
binding-skeleton holes, and **one** facade module at
`structuralProjectionModule ctx` (lines 787-788: `structuralPrefix ctx <> "Projections"`,
e.g. `Generated/<Ctx>/StructuralProjections.hs`) with kind Generated. The facade's name is
purely context-derived, so a second same-context spec scaffolded into the same out directory
silently overwrites it from that spec's **incomplete** mapped graph. This is the core defect
this plan fixes: the facade (and `ReplayAudit`) must be emitted once, from the merged graph.

`keiro-dsl/app/Main.hs` drives the `Scaffold` command (lines 180-212): parse, validation
gate (abort on any error-severity diagnostic before writing anything, lines 189-191),
`mkContext` folding CLI flags over spec clauses over defaults (lines 332-341, precedence
CLI > spec clause > built-in default), golden payloads loaded from
`fromMaybe (takeDirectory fp </> "golden-payloads") cliGoldens` (line 193), then
`planScaffoldWithGoldens` → `executeScaffold` → report. `loadGoldenPayloads`
(`keiro-dsl/src/Keiro/Dsl/Goldens.hs`) loads only fixtures for declared upcasters, from
`<root>/<context>/<Aggregate>/<Event>.v<version>.json`, and never overwrites existing files.

Obligations surfaced by a scaffold run, all pure functions of the spec:
`bindingHoles` (`Keiro.Dsl.ExplainBindings`) computes binding/fixture/initial-value
obligations; `consumerPlan` (`Keiro.Dsl.MappedConsumer`) computes consumer packages and
modules; `constraintPlan` (`ScaffoldRun.hs` lines 219-238) computes per-mapping constraint
requirements. In the workspace path all three must be computed from the **complete merged
graph**, or a member could compile against an incomplete obligation list.

The failing behavior to internalize: `keiro-dsl/test/Main.hs` line 2152, test
"reports the entire old tree across a module-root flip", scaffolds the same spec twice into
one directory under different contexts-with-different-roots and proves the second run
classifies the entire first tree as stale. The same mechanism misfires for two *different*
same-context specs: each run replaces `keiro-dsl-scaffold-record.<context>.txt` and reports
the sibling's files as stale. The test file also provides the filesystem-test vocabulary this
plan's tests reuse: `withTempDirectory` (line 2505, bracket-style temp dir),
`executePlannedScaffold` (line 2482, plan-then-execute or fail loudly), `parseInlineSpec`
(line 2934), and `scaffoldFixture` (line 2836).

### What EP-1 provides (hard dependency)

EP-1 is `docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md`.
This plan must not begin implementation until EP-1 is Complete; consult that plan for exact
merged names. For self-containment, this plan assumes and consumes the following artifacts
(working names; reconcile against EP-1's merged code in the first Progress step):

- A **workspace manifest file** with extension `.keiro-workspace`, whose `service <name>`
  line is the stable workspace identity and which lists member `.keiro` files explicitly.
  EP-1 owns the grammar, canonical member ordering (source order in the manifest must not
  affect semantics — EP-1 canonically sorts members before composing), and the rule for the
  effective context, module root, and layout.
- A composed **`WorkspaceSpec`** (working module `keiro-dsl/src/Keiro/Dsl/Workspace.hs`)
  carrying: the service name; the manifest path; the member `Spec`s with their manifest-
  relative paths; the **merged declarations** (ids, enums, rules, mapped structural/opaque
  types, read models) with per-declaration owning member file and span; a per-**node**
  owner map (which member file declared each aggregate/process/router/... node); a
  **merged `Spec`** view (all nodes and declarations under the one effective context) that
  the type-graph resolver and emitters can consume unchanged; and the effective
  `Context`-forming data.
- **CLI dispatch** in `keiro-dsl/app/Main.hs` that recognizes the manifest extension for
  every command's `FILE` argument, plus the single-file-as-one-member-workspace fallback.
- **Compose-time refusals** for cross-member conflicts (duplicate declarations, duplicate
  node names, context/policy disagreement, a member in two workspaces), raised before any
  consumer of `WorkspaceSpec` runs — per ADR-4's earliest-boundary rule. This plan's
  collision gates therefore only need to cover what emerges at *emission* time (module
  paths, consumer modules, firewall, banners), not declaration-level conflicts.

If EP-1's merged names differ (for example `workspaceMergedSpec` versus a field), adapt the
signatures in Interfaces and Dependencies and note the change in this plan's Decision Log.

### ADRs

Local ADRs relevant to this work, per the `agents/skills/exec-plan/ADR.md` workflow (the
`docs/adr` bundle is profile-governed OKF: `docs/adr/profile.dhall`, reserved `log.md`,
handles allocated with `okf id next`, strict validation via `just adr-validate`):

- `docs/adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md`
  (ADR-12) — one schema authority per structural mapping; emitting the single
  `StructuralProjections` facade from the merged mapped-type graph is this rule's
  workspace-level consequence (two facades from two partial graphs would be two competing
  authorities for one context).
- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR-4) —
  every evolution hazard is refused at the earliest boundary with enough evidence; this plan
  extends detection-before-first-write across the entire member set and adds the
  golden-root-divergence refusal at plan time.
- EP-1 records the workspace identity and ownership decision as a new ADR (MasterPlan 26
  expects ADR-14; verify with `okf id list`). This plan adds its own ADR for the
  scaffold-history/adoption model (Decision Log above).

No other local ADR covers scaffold records or adoption. Cross-repository: IR-2 originates
from `mori://shinzui/mori` (Mori MasterPlan 22); no cross-repository ADR governs this design.

Normative requirement sources, both checked in: MasterPlan 26
(`docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md`) — this plan
is its EP-2 and implements exactly the three "EP-2" Progress milestones; its Decision Log
fixes that **atomicity means detection before the first write** (staged temp-file/rename
writes are explicitly out of scope) and that the single-file path keeps context-keyed names
and bytes. IR-2
(`docs/improvement-requests/support-composable-multi-file-service-specifications-in-keiro-dsl.md`)
— especially "Atomic scaffolding and history" (plan the complete set, emit each
context-level artifact once, one record/manifest keyed by stable workspace identity,
whole-workspace stale comparison, idempotence, source ownership in the record) and
"Compatibility and Migration" (explicit adoption path, no silent claiming, no deletion).


## Plan of Work

The work proceeds in three milestones matching MasterPlan 26's three EP-2 Progress entries:
first the workspace-keyed record schema and the whole-workspace **plan** phase (everything
pure, testable without touching a filesystem), then whole-workspace **execution** with stale
detection, idempotence, determinism, and the CLI wiring (filesystem tests), and finally the
**adoption** path from legacy per-context records with its migration report and the ADR.

### Milestone 1 — workspace-keyed record schema and the whole-workspace plan phase

Scope: a new record schema keyed by workspace identity and carrying per-module source
ownership, plus a pure planning function that produces the complete whole-workspace module
set — context-level modules once from the merged graph, per-node modules from their owning
members — with every pure refusal computed across the entire set. At the end, unit tests
prove the record round-trips, the facade appears exactly once, a one-member workspace plans
byte-identically to the single-file path, and cross-member collisions refuse with both
member files named. No CLI or filesystem behavior changes yet.

**The workspace record.** Create `keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs` (add it to
`exposed-modules` in `keiro-dsl/keiro-dsl.cabal`). The format is line-oriented like the v1
record, with a distinct header so no reader can confuse the schemas:

```text
keiro-dsl workspace scaffold record v1
service: mori-project
manifest: mori-project.keiro-workspace
context: mori
module-root: Mori.Modules
layout: collocated
member domain/shared.keiro
member domain/project.keiro
member domain/project-artifact.keiro
module {"kind":"generated","path":"Generated/Mori/StructuralProjections.hs"}
module {"kind":"generated","path":"Generated/Mori/Project/Domain.hs","owner":"domain/project.keiro"}
module {"kind":"hole","path":"Mori/Project/Holes.hs","owner":"domain/project.keiro"}
mapping {"schema":1,...}
binding {"schema":1,...}
adopted {"path":"Generated/Mori/Project/Domain.hs","evidence":"record","source":"keiro-dsl-scaffold-record.mori.txt","spec":"project.keiro"}
```

Rules, mirroring the v1 conventions the fleet already relies on: the header line must match
exactly; `service:`, `manifest:`, `context:`, `module-root:` (with the `(none)` spelling for
an empty root), and `layout:` must each appear exactly once; `member <path>` rows are the
canonically ordered manifest-relative member paths; `module ` rows are canonical single-line
JSON objects with required `kind` (`"generated"` or `"hole"`) and `path`, and an optional
`owner` naming the producing member file — **absent `owner` means context-level**, emitted
from the merged graph (the facade, `ReplayAudit`). `mapping ` and `binding ` rows reuse the
existing JSON encodings of `MappingIdentity` and `BindingHole` unchanged. `adopted ` rows
(written only by M3) carry provenance for files imported from legacy records. Unknown row
kinds and unknown JSON keys are ignored (forward compatibility); paths are rejected when
absolute or containing `..`, exactly as `parseRecord` does today. Export:

```haskell
data WorkspaceModuleRow = WorkspaceModuleRow
    { wmKind :: !ModuleKind
    , wmPath :: !FilePath
    , wmOwner :: !(Maybe FilePath)  -- Nothing = context-level (merged graph)
    }

data AdoptedRow = AdoptedRow
    { adPath :: !FilePath
    , adEvidence :: !Text        -- "record" | "banner"
    , adSource :: !(Maybe Text)  -- legacy record file name when evidence == "record"
    , adSpec :: !(Maybe Text)    -- legacy record's spec: field, when available
    }

data WorkspaceRecord = WorkspaceRecord
    { wrService :: !Text
    , wrManifestPath :: !Text
    , wrContext :: !Text
    , wrModuleRoot :: !Text
    , wrLayout :: !Text
    , wrMembers :: ![FilePath]
    , wrModules :: ![WorkspaceModuleRow]
    , wrMappings :: ![MappingIdentity]
    , wrBindingObligations :: ![BindingHole]
    , wrAdopted :: ![AdoptedRow]
    }

renderWorkspaceRecord :: WorkspaceRecord -> Text
parseWorkspaceRecord :: Text -> Maybe WorkspaceRecord
workspaceRecordFileName :: Text -> FilePath   -- "keiro-dsl-scaffold-record.workspace." <> service <> ".txt"
workspaceManifestFileName :: Text -> FilePath -- "keiro-dsl-manifest.workspace." <> service <> ".txt"
```

The `workspace.<service>` key slot cannot collide with any context-keyed name because
context names cannot contain dots (Decision Log). Restate the coexistence rule in the module
Haddock: legacy context-keyed records and a workspace record may share one out directory;
the workspace path never writes context-keyed names.

**The plan phase.** Extend `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` (same module, so the
private gates `collisionRefusals`, `dependencyRefusals`, `firewallBreaches` are reused, not
duplicated) with:

```haskell
data ModuleProvenance = ContextLevel | MemberOwned !FilePath
    deriving stock (Eq, Show)

data WorkspacePlan = WorkspacePlan
    { wpWorkspace :: !WorkspaceSpec
    , wpContext :: !Context
    , wpModules :: ![(ScaffoldModule, ModuleProvenance)]
    }

planWorkspaceScaffoldWithGoldens
    :: [GoldenPayload] -> Context -> WorkspaceSpec -> Either [Refusal] WorkspacePlan
```

Build the module list with exactly the shape of `scaffoldModulesWithGoldens`, over the
**merged spec**, tagging as it goes: `scaffoldStructural ctx mergedSpec` contributes the
per-declaration shape and binding-skeleton modules tagged `MemberOwned` via EP-1's
declaration owner map (match on the declaration name each module was emitted for) and the
facade tagged `ContextLevel`; `scaffoldReplayAudit ctx mergedSpec` is `ContextLevel`; each
node's emitters (`scaffoldAggregate ctx mergedSpec agg <> harnessForWithGoldens ...` and
the other node kinds, in today's registry order) are tagged `MemberOwned` with that node's
owner from EP-1's node owner map. Passing the merged spec everywhere is what makes
cross-member references (a shared `ProjectId`, a shared enum) resolve inside another
member's aggregate ring, and what makes the facade and `ReplayAudit` see every declaration
and every aggregate. Do not modify the emitters themselves; the single-file path keeps
calling them identically.

For refusal messages that must cite files: after tagging, rewrite each member-owned
module's `origin` field to `memberPath <> ": " <> origin m`. `origin` is pure metadata used
only by refusal rendering (`PathCollision` origins) and never reaches `moduleText`, the
record, or the manifest, so output bytes are unaffected — but a cross-member case-folded
collision now names both member files.

Then run the existing gates over the complete list: `collisionRefusals`,
`dependencyRefusals ctx mergedSpec`, `FirewallBreach`, `LoweringRefusal` — the same
composition as `planScaffoldWithGoldens` lines 110-119, over `map fst` of the tagged list.
Add the golden-root check: given the manifest directory and the resolved workspace golden
root, for each member compute the fixtures its declared upcasters would load (the same
paths `loadGoldenPayloads` probes) and refuse with the new constructor

```haskell
GoldenRootDivergence ![FilePath]  -- member-adjacent fixture files not present under the workspace root
```

when a member-adjacent `golden-payloads` directory contains a fixture file the workspace
root lacks. Render it in `renderRefusals` with the explicit remedy ("move these files under
<workspace root>; keiro-dsl reads one golden root per workspace") and the standard
"nothing was written" tail.

Obligations from the complete graph: `bindingHoles mergedSpec`, `consumerPlan mergedSpec`,
and `constraintPlan mergedSpec` are computed once over the merged spec — they need no new
code, only the merged input; assert in tests that a mapped declaration owned by member A and
used by member B's aggregate yields obligations that mention both use sites.

Verification for this milestone (all pure, in `keiro-dsl/test/Main.hs` under new
describe-groups `workspace record` and `workspace plan`): record render/parse round trip
including ownerless rows and adopted rows; unknown-row and unknown-key tolerance; path
safety; `workspaceRecordFileName "kotei" /= recordFileName "kotei"`; a two-member workspace
(build the `WorkspaceSpec` with EP-1's compose function over two inline specs) plans exactly
one module whose path ends in `StructuralProjections.hs` and exactly one ending in
`ReplayAudit.hs`; the facade text mentions declarations from **both** members; a one-member
workspace's `map fst wpModules` equals `planScaffoldWithGoldens` output for that spec
byte-for-byte; two members each declaring aggregates whose module paths collide case-folded
refuse with a `PathCollision` whose origins mention both member paths. Run
`cabal test keiro-dsl-test`.

Commit (conventional message plus the mandated trailers, shown in Concrete Steps):
`feat(dsl): add workspace-keyed scaffold record and whole-workspace plan phase`.

### Milestone 2 — whole-workspace execution, stale detection, idempotence, determinism

Scope: the execution half and the CLI wiring. At the end, `keiro-dsl scaffold
<manifest>.keiro-workspace --out DIR` works end to end; stale detection compares whole
workspaces; a second identical run reports zero changes; member reordering yields
byte-identical output; any member failure leaves the tree, record, and manifest untouched;
ownership moves are reported; the single-file path is bit-for-bit unaffected.

In `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` add:

```haskell
data OwnershipMove = OwnershipMove
    { omPath :: !FilePath
    , omPrevious :: !(Maybe FilePath)  -- Nothing = was context-level
    , omCurrent :: !(Maybe FilePath)
    }

data WorkspaceScaffoldReport = WorkspaceScaffoldReport
    { wsrManifestPath :: !FilePath
    , wsrOutDir :: !FilePath
    , wsrService :: !Text
    , wsrContext :: !Context
    , wsrDispositions :: ![(ScaffoldModule, ModuleProvenance, WriteDisposition)]
    , wsrBuildManifestPath :: !FilePath
    , wsrRecordPath :: !FilePath
    , wsrPreviousManifestPath :: !(Maybe Text)
    , wsrStale :: ![StaleModule]
    , wsrOwnershipMoves :: ![OwnershipMove]
    , wsrConsumerPlan :: !ConsumerPlan
    , wsrConstraintPlan :: ![Text]
    , wsrMappingDrift :: ![MappingDrift]
    , wsrNewHoles :: ![BindingHole]
    , wsrMigration :: !(Maybe MigrationReport)  -- populated by M3; Nothing until then
    }

executeWorkspaceScaffold
    :: FilePath  -- out
    -> Bool      -- force generated overwrite
    -> WorkspacePlan
    -> IO (Either [Refusal] WorkspaceScaffoldReport)

renderWorkspaceScaffoldReport :: WorkspaceScaffoldReport -> [Text]
```

`executeWorkspaceScaffold` mirrors `executeScaffold` step for step, with these deltas.
Banner preflight runs `missingGeneratedBanners out (map fst (wpModules plan))` over the
**complete** workspace set before the out directory is created or any file is changed —
same all-or-nothing shape as today, so a bannerless file under any member's subtree refuses
the entire workspace run. The previous record is read from
`out </> workspaceRecordFileName service` and parsed with `parseWorkspaceRecord`. Stale
detection compares that record's `wrModules` paths against the whole current plan's paths
(same still-on-disk filter as `existingStale`); because both sides now cover the whole
workspace, a module produced by another member is in the current set and can no longer be a
false positive. **Ownership moves** are computed before stale: a path present in both the
previous record and the current plan whose `owner` differs becomes an `OwnershipMove`, not
a stale entry (it never entered the removed set anyway, since the path is still produced —
the move is purely informational, and EP-3's diff must classify it identically). Writing
uses a workspace-local `writeWorkspaceModule` that, for Generated modules, reads any
existing file first and reports `Unchanged` without writing when the bytes already match
(HoleStub keeps create-once `Skipped`/`Created`); add the `Unchanged` constructor to
`WriteDisposition` — the single-file `writeModule` never produces it, so single-file
reports are unchanged. The build manifest is rendered by the existing `renderManifest`
(passing the manifest path as the source name and the merged spec) to
`out </> workspaceManifestFileName service`, and the record is rendered from the plan's
tagged modules (`wmOwner = Just member` for `MemberOwned`, `Nothing` for `ContextLevel`),
the canonical member list, and the merged-graph mappings and obligations. Mapping drift and
new-hole computation reuse `mappingDrift` and `newBindingObligations` against the previous
workspace record's rows. `renderWorkspaceScaffoldReport` follows `renderScaffoldReport`'s
format with a `workspace:` header line naming the service, per-module lines that append the
owning member (or `(context-level)`), an `ownership moves:` section, a stale section keyed
by the service ("no longer produced by this workspace") retaining the exact sentence
"keiro-dsl never deletes files.", and a note when the previous record's manifest path
differs from the current one.

Atomicity is inherited, not re-implemented: every refusal (`Left`) path in both
`planWorkspaceScaffoldWithGoldens` and the banner preflight returns before
`createDirectoryIfMissing`/any write, exactly like today's lines 184-201 — and EP-1
refuses parse/validation/compose failures before a `WorkspaceSpec` even exists. Add no
staged writes (MasterPlan 26 Decision Log: out of scope).

In `keiro-dsl/app/Main.hs`, extend `run (Scaffold fp out ...)` (lines 180-212) through
EP-1's dispatch: when `fp` has the `.keiro-workspace` extension, load the workspace with
EP-1's loader (its compose refusals and per-member validation gate mirror the single-file
error-severity gate at lines 189-191 — confirm and reuse rather than re-validate), build
the effective `Context` with the same precedence as `mkContext` (lines 332-341: CLI
`--module-root`/`--collocate` still win over the workspace authority, which wins over
member clauses — EP-1 owns the manifest-versus-member rule; this plan only threads CLI
precedence unchanged), resolve the golden root as `fromMaybe (takeDirectory fp </>
"golden-payloads") cliGoldens`, load goldens once over the merged spec, then
`planWorkspaceScaffoldWithGoldens` → `executeWorkspaceScaffold` → render, with the same
exit-code discipline as the single-file branch. The `--codec-compare` request keeps
working by passing the merged spec to `codecComparisonModule`. The single-file branch is
untouched.

Verification (filesystem tests in `keiro-dsl/test/Main.hs`, describe-group
`workspace scaffold`, using `withTempDirectory`; plus one committed fixture workspace under
`keiro-dsl/test/fixtures/workspace/` with a manifest and two same-context member specs
sharing an id declaration — coordinate the fixture's shape with EP-4's fleet-style fixture
so it can be promoted):

- **No cross-member false positives**: scaffold the two-member workspace; re-scaffold after
  editing only member A (rename one of A's events); the report lists stale files only under
  A's old module names, never B's; B's files on disk are byte-identical.
- **Idempotence**: scaffold twice with no edits; second report has every Generated module
  `Unchanged`, every hole `Skipped`, empty stale, empty ownership moves; record and build
  manifest bytes identical across runs.
- **Member-order determinism**: write two manifests listing the same members in reversed
  order; scaffold each into its own temp dir; walk both trees and compare every file's
  bytes, plus record and manifest bytes — identical. (EP-1 owns the canonical sort; this
  test proves the bytes.)
- **Any-member failure leaves everything untouched**: after a successful scaffold, mutate
  the in-memory workspace so one member introduces a case-folded collision (the
  `duplicate`/`caseVariant` construction from test line 2114 adapted to two members); the
  plan refuses; assert every previously written file, the record, and the manifest are
  byte-identical, and that scaffolding a fresh temp dir with the broken workspace creates
  no files at all.
- **Ownership move**: move an aggregate node from member A's spec text to member B's;
  re-scaffold; the report shows ownership moves for that aggregate's modules, zero stale
  entries for them, and (content unchanged) `Unchanged` dispositions.
- **Single-file compatibility**: the entire pre-existing suite passes unchanged, in
  particular the record pin at lines 2173-2192 and the module-root-flip test at 2152-2162
  (whose behavior for the legacy path is deliberately preserved).

Run `cabal build all` and `cabal test keiro-dsl-test`. Commit:
`feat(dsl): execute whole-workspace scaffolds with workspace-keyed history`.

### Milestone 3 — adoption from per-context records with a migration report

Scope: the first workspace scaffold into an out directory that already holds legacy
per-context history — including the overwritten-record case IR-2 describes — imports what
is attributable, reports everything, claims nothing silently, deletes nothing. The durable
decisions land in a new ADR. At the end, the migration end-to-end story EP-4 will test is
implementable from this plan alone.

Add a `MigrationReport` (in `Keiro.Dsl.WorkspaceRecord` or a small
`Keiro.Dsl.WorkspaceAdoption` module — implementer's choice, recorded in the Decision Log)
carrying: the legacy record file(s) consulted; claimed files with evidence
(`record`-attributed: listed in a legacy record for the workspace's effective context;
`banner`-attributed: at a planned Generated path bearing `-- @generated` but listed in no
surviving record — the orphan case created when one legacy record overwrote another);
likely-stale legacy rows (in a legacy record, on disk, not in the new plan) with the
existing generated-versus-hole guidance wording from lines 423-425; and unclaimed files
(hole-path files and any other hand-written files the plan encountered), explicitly marked
"left untouched".

Adoption runs inside `executeWorkspaceScaffold`, only when no workspace record exists at
`out </> workspaceRecordFileName service`, after the banner preflight and before any write.
It reads `out </> recordFileName effectiveContext` (only the workspace's own effective
context — records for other contexts belong to other services and are never touched or
reported), computes the report purely, and only then proceeds to the normal write sequence,
additionally: writing `adopted ` provenance rows into the new workspace record; writing the
human-readable report to `out </> "keiro-dsl-migration-report.workspace." <> service <>
".txt"` (created on the adopting run only; never rewritten later — like goldens, an
existing report is authoritative review material); appending the single line
`superseded-by: keiro-dsl-scaffold-record.workspace.<service>.txt` to the legacy record
(ignored by the v1 parser; Decision Log); and printing the report in the scaffold output.
The refusal posture is unchanged from M2: a bannerless file at a planned Generated path
still refuses the entire run — adoption never weakens the banner check, and "refusing to
claim what is not attributable" is implemented as claim-nothing-plus-report, not as a new
refusal (the file simply stays unclaimed and untouched; if it occupies a planned Generated
path without a banner, the existing refusal already fires).

Likely-stale legacy rows are reported in the migration report but are **not** merged into
the workspace record's module rows: the record states what this workspace produces and
adopted, not what an abandoned scaffold once produced. The migration report is the durable
review artifact for cleanup.

Record the durable decisions as a new ADR: allocate the handle with
`okf id next docs/adr --profile docs/adr/profile.dhall ADR` (do not assume ADR-15; EP-1 is
expected to have taken ADR-14), title along the lines of "Workspace scaffold history is
workspace-keyed with attributable adoption", covering: the `workspace.<service>` record and
manifest naming with the no-dot collision argument; per-module source ownership and the
ownership-move classification EP-3 must match; the adoption evidence rules
(record/banner/unclaimed) and the never-delete, never-rename, append-only-marker stance;
and the deliberate single-golden-root rule. Reference EP-1's identity ADR; if EP-1's ADR
already fixed record naming, amend it there instead and narrow the new ADR (Decision Log
fallback). Update `docs/adr/log.md` with `okf log add` and run the strict validation shown
in Concrete Steps.

Verification (describe-group `workspace adoption`):

- Reproduce the defect, then adopt: scaffold two same-context inline specs independently
  into one temp dir with `executePlannedScaffold` (the second overwrites the first's
  record — today's behavior); then scaffold a workspace composed of both members into the
  same dir. Assert: the report and persisted migration file claim the second spec's files
  as `record`-attributed and the first's as `banner`-attributed; zero stale false
  positives; both specs' generated files byte-identical to a fresh workspace scaffold of
  the same members (adoption is not a content change when context and module policy are
  unchanged — assert it on this fixture, since merged-graph resolution could legitimately
  differ for specs that newly see shared declarations); the legacy record still parses
  with `parseRecord` and now contains the `superseded-by:` line; the workspace record
  contains matching `adopted ` rows.
- Hand-written files: pre-create a hole-path file and an unrelated `Notes.hs`; adoption
  lists both as unclaimed, bytes untouched; a bannerless file at a planned Generated path
  still refuses the entire run with `MissingGeneratedBanner` and no writes.
- One-shot: the second workspace run performs no adoption (no report rewrite, no new
  marker line, `wsrMigration = Nothing`), and is idempotent per M2.
- `just adr-validate` passes with the new ADR and updated log.

Commit: `feat(dsl): adopt legacy per-context scaffold records into workspace history` and
`docs(adr): record workspace scaffold-history and adoption decisions` (or one commit if the
ADR lands with the code; both carry the trailers).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Before starting, confirm the hard dependency and the ADR handle situation:

```bash
git log --oneline -5
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
```

EP-1 must be Complete (check `docs/plans/153-...md`'s Progress section and the presence of
`keiro-dsl/src/Keiro/Dsl/Workspace.hs` or its merged equivalent). Build and test loop while
implementing:

```bash
cabal build all
cabal test keiro-dsl-test
```

Note that `just verify` does **not** run `keiro-dsl-test` (the Justfile's `haskell-test`
recipe runs `keiro-test`, `keiro-pgmq-test`, `jitsurei-test`, and the diagrams check), so
`cabal test keiro-dsl-test` must always be run explicitly. A successful suite run ends:

```text
Finished in ... seconds
NNN examples, 0 failures
Test suite keiro-dsl-test: PASS
```

Manual end-to-end check after M2 (expect one facade line, a workspace record path, and on
the second run only `(unchanged)`/`(skipped: already present)` dispositions):

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/workspace/service.keiro-workspace --out /tmp/ws-demo
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/workspace/service.keiro-workspace --out /tmp/ws-demo
ls /tmp/ws-demo
```

After the M3 ADR work, run strict profile enforcement (this is also `just adr-validate`):

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Before each commit, run the full repository gate:

```bash
nix fmt
just verify
cabal test keiro-dsl-test
```

Every commit uses a conventional message and carries these exact trailers:

```text
feat(dsl): <milestone summary>

<body>

MasterPlan: docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md
ExecPlan: docs/plans/154-scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records.md
Intention: intention_01kyq39tsbepwt43q6db89h0d7
```

Commit directly to the current branch (no feature branch), one commit per milestone at
minimum, updating this plan's Progress section in the same commit as the work it records.


## Validation and Acceptance

Acceptance is behavioral and maps one-to-one onto IR-2's scaffolding bullets and MasterPlan
26's EP-2 milestones. All of the following must be observable by running the commands shown:

1. **Whole-workspace planning with one facade.** Scaffolding the fixture workspace (two
   same-context members sharing declarations) emits both aggregate rings and create-once
   Holes, exactly one `StructuralProjections.hs`, and exactly one `ReplayAudit.hs`; the
   facade's text covers mapped declarations from both members. Observed via the M1 plan
   tests and by inspecting `/tmp/ws-demo` after the manual run.
2. **Cross-member refusal before any write.** A case-folded module-path collision between
   two members refuses with both member files named in the `PathCollision` origins, and the
   out directory is not created. A member-adjacent golden fixture missing from the
   workspace root refuses with `GoldenRootDivergence` naming the exact files.
3. **Workspace-keyed history.** After a successful run,
   `keiro-dsl-scaffold-record.workspace.<service>.txt` parses to a `WorkspaceRecord` whose
   module rows carry owners for member-owned modules and no owner for the facade and
   `ReplayAudit`; `keiro-dsl-manifest.workspace.<service>.txt` exists; no context-keyed
   file was written by the workspace path.
4. **Stale without false positives; ownership moves.** Editing one member reports stale
   only for that member's renamed modules; moving an aggregate between members reports an
   ownership move and zero stale/new churn for its unchanged modules. The stale section
   still ends with "keiro-dsl never deletes files." and nothing is deleted.
5. **Idempotence and determinism.** An unchanged second run reports every Generated module
   `(unchanged)` with byte-identical record and manifest; reversed member order produces a
   byte-identical output tree, record, and manifest.
6. **Atomic failure.** A validation error, collision, or bannerless Generated target in any
   member leaves the output tree, workspace record, and build manifest byte-for-byte
   untouched (fresh directory: nothing created).
7. **Adoption.** The reproduced overwritten-records scenario adopts with a printed and
   persisted migration report distinguishing record-attributed, banner-attributed,
   likely-stale, and unclaimed files; hand-written files are untouched; the legacy record
   gains only the `superseded-by:` line and still parses; the run's outputs are
   byte-identical to a fresh workspace scaffold of the same members.
8. **No single-file regression.** The full pre-existing `keiro-dsl-test` suite passes
   unchanged; `recordFileName` output and single-file record/report bytes are pinned by the
   existing tests at `keiro-dsl/test/Main.hs` lines 2173-2192.

The exact test command for all of the above is `cabal test keiro-dsl-test` from the
repository root; failures print the offending expectation with the hspec label from the
describe-groups named in the milestones (`workspace record`, `workspace plan`,
`workspace scaffold`, `workspace adoption`).


## Idempotence and Recovery

Every step of this plan is safe to repeat. The implementation itself is additive: new
module `WorkspaceRecord.hs`, new functions in `ScaffoldRun.hs`, a new CLI branch — the
single-file pipeline is not edited, so a half-finished milestone never degrades existing
behavior; `git status` plus this plan's Progress section is sufficient to resume.

The delivered tool behavior is idempotent by design and by test: re-running a workspace
scaffold rewrites only modules whose bytes changed (reporting `unchanged` otherwise),
re-creates nothing that exists at hole paths, and never deletes. Refusals happen before the
first write, so an interrupted or refused run leaves the previous state fully intact; the
recovery action after fixing the cause is simply to re-run the same command. Adoption runs
at most once (guarded by workspace-record absence); if a run is interrupted after the
migration report is written but before the workspace record lands, the next run performs
adoption again from the same still-intact legacy record — the report file is regenerated
from the same inputs (existing migration report files are only preserved once a workspace
record exists; on the adoption retry path they are rewritten deterministically). The only
mutation of pre-existing files is the appended `superseded-by:` line, which is idempotent
if guarded (append only when absent — implement it that way) and harmless to v1 parsers in
any case. Temp-dir tests use the `withTempDirectory` bracket and clean up on failure.

If a milestone must be rolled back, `git revert` of its commit restores the previous
behavior completely, because no existing file format was altered: legacy records were never
rewritten into a new schema, and workspace files are ignored by the old code.


## Interfaces and Dependencies

Hard dependency: EP-1
(`docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md`)
must be Complete. Consumed from it (working names, reconciled at start of work): the
`.keiro-workspace` manifest with `service <name>` identity; `Keiro.Dsl.Workspace` with
`WorkspaceSpec` (member specs and manifest-relative paths, merged declarations with
per-declaration owner, per-node owner map, merged `Spec` view, effective
context/module-root/layout); CLI dispatch for the manifest extension; compose-time
refusals. This plan must not re-parse member files or invent a secondary identity source
(MasterPlan 26 Integration Points).

Peer coordination: EP-3 (plan 155) reports ownership moves and must classify them exactly
as `OwnershipMove` records them (path unchanged, owner changed ⇒ move, not stale/new);
whichever plan lands second reconciles. EP-4 (plan 156) consumes the fixture workspace and
the adoption behavior for its end-to-end migration tests.

Libraries: only what `keiro-dsl` already depends on — `aeson` for the JSON record rows
(matching the `mapping `/`binding ` row precedent), `containers`, `text`, `directory`,
`filepath`. No new dependencies.

Interfaces that must exist at the end of each milestone, with full module paths:

- After M1, in `Keiro.Dsl.WorkspaceRecord`
  (`keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs`): `WorkspaceRecord`,
  `WorkspaceModuleRow`, `AdoptedRow`, `renderWorkspaceRecord`, `parseWorkspaceRecord`,
  `workspaceRecordFileName :: Text -> FilePath`,
  `workspaceManifestFileName :: Text -> FilePath`. In `Keiro.Dsl.ScaffoldRun`:
  `ModuleProvenance`, `WorkspacePlan`,
  `planWorkspaceScaffoldWithGoldens :: [GoldenPayload] -> Context -> WorkspaceSpec ->
  Either [Refusal] WorkspacePlan`, and the `GoldenRootDivergence` constructor on
  `Refusal` rendered by `renderRefusals`.
- After M2, in `Keiro.Dsl.ScaffoldRun`: `OwnershipMove`, `WorkspaceScaffoldReport`,
  `executeWorkspaceScaffold :: FilePath -> Bool -> WorkspacePlan -> IO (Either [Refusal]
  WorkspaceScaffoldReport)`, `renderWorkspaceScaffoldReport`, and the `Unchanged`
  constructor on `WriteDisposition` (produced only by the workspace path). In
  `keiro-dsl/app/Main.hs`: the `Scaffold` command handles a `.keiro-workspace` argument
  end to end with unchanged flags (`--out`, `--module-root`, `--collocate`,
  `--force-generated-overwrite`, `--goldens`, `--codec-compare`).
- After M3: `MigrationReport` with its render function (module per Decision Log), the
  adoption pass inside `executeWorkspaceScaffold` populating `wsrMigration` and the
  record's `adopted ` rows, the persisted
  `keiro-dsl-migration-report.workspace.<service>.txt`, and the new ADR under `docs/adr/`
  with its allocated handle, updated `log.md`, and green
  `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce
  --log-enforce`.
