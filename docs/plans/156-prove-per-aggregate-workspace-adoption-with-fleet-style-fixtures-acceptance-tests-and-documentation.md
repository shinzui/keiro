---
id: 156
slug: prove-per-aggregate-workspace-adoption-with-fleet-style-fixtures-acceptance-tests-and-documentation
title: "Prove per-aggregate workspace adoption with fleet-style fixtures, acceptance tests, and documentation"
kind: exec-plan
created_at: 2026-07-29T14:09:13Z
intention: "intention_01kyq39tsbepwt43q6db89h0d7"
master_plan: "docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md"
---

# Prove per-aggregate workspace adoption with fleet-style fixtures, acceptance tests, and documentation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The three preceding plans of MasterPlan 26 give `keiro-dsl` a service workspace: a small
manifest file that names one service and lists several `.keiro` member files, which
`check`, `scaffold`, and `diff` treat as one resolved service graph. What does not exist
yet is proof. No checked-in fixture demonstrates the layout the fleet actually uses — one
complete aggregate per file, every file declaring the same context — and no test suite
walks the ten acceptance bullets of the initiative's improvement request, IR-2
(`docs/improvement-requests/support-composable-multi-file-service-specifications-in-keiro-dsl.md`).
Nor does any documentation tell a team like Kotei's how to adopt a workspace over the
per-aggregate files they already have, or tell a team like Danwa's why their
three-aggregates-in-one-file layout keeps working untouched.

After this plan, a reader can open `keiro-dsl/test/fixtures/workspace-fleet/` and see a
realistic per-aggregate service — a shared-declarations file plus two aggregate files under
one context and one manifest — then run the transcripts in Concrete Steps and watch
whole-service `check` refuse cross-file conflicts with multi-file diagnostics, watch
`scaffold` emit both aggregate rings and exactly one context facade idempotently, and watch
`diff` propagate a shared structural-type change into every affected aggregate. The test
suite pins every IR-2 acceptance bullet by name, including an end-to-end migration from
today's colliding same-context independent scaffolds into one adopted workspace. The DSL
guides, the authoring skill, and the CLI references document both layouts with real
captured output. This plan is the initiative's exit gate: when it is complete, IR-2's
Acceptance section is demonstrably satisfied and MasterPlan 26 can close.


## Progress

- [ ] Read the landed state of plans 153, 154, and 155 (paths in Context and Orientation)
      and reconcile every manifest spelling, CLI flag, module name, and report string in
      this plan against what actually landed; record divergences in the Decision Log.
- [ ] M1: author `keiro-dsl/test/fixtures/workspace-fleet/` (shared.keiro, project.keiro,
      project-artifact.keiro, fleet.keiro-workspace) and confirm `check` accepts it clean.
- [ ] M1: add the "fleet workspace" hspec describe block with the clean-compose test and
      the four refusal tests (duplicate aggregate, duplicate shared declaration,
      cross-file unresolved reference, case-folded generated-path collision).
- [ ] M1: add the whole-service scaffold tests (both rings + one facade + one record, no
      stale false positives; scaffold-twice idempotence; member-reorder byte identity;
      one-aggregate change preserves the other; failing-second-member leaves the tree and
      record byte-for-byte unchanged in all three failure variants).
- [ ] M1: add the member-permutation QuickCheck property and the whole-service diff
      shared-type propagation test.
- [ ] M1: confirm every pre-existing `keiro-dsl-test` example and golden fixture still
      passes without modification.
- [ ] M2: add the pinned baseline test reproducing today's same-context collision
      (record overwrite plus stale false positives) with the current warning text.
- [ ] M2: add the adoption end-to-end test (migration report, imported ownership, refusal
      of unattributable files, nothing deleted or overwritten silently) and the reverse
      safety test (bannerless hand-written file still refused through the workspace path).
- [ ] M3: update `docs/user/typed-spec-toolchain.md` with the workspace section and
      captured transcripts.
- [ ] M3: update `docs/guides/brownfield-migration-and-transducer-modeling.md` with the
      adoption walkthroughs (from one file; from independent same-context scaffolds).
- [ ] M3: update `docs/guides/evolution-and-replayability.md` with whole-service diff.
- [ ] M3: update `agents/skills/keiro-dsl-authoring/SKILL.md`, `NOTATION.md`, and
      `LOOP.md` (manifest notation, whole-service commands, layout choice guidance).
- [ ] M3: re-run every documented command against the fixture and paste the real output.
- [ ] Write the traceability verification result in Validation and Acceptance, update the
      MasterPlan's Progress entries for EP-4, and complete the Outcomes & Retrospective
      entry that feeds MasterPlan 26's final ADR distillation pass.
- [ ] Run `just verify` and confirm the full repository gate passes.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The fixture workspace is a directory `keiro-dsl/test/fixtures/workspace-fleet/`
  containing `shared.keiro` (shared id, enum, mapped structural type, read model),
  `project.keiro` and `project-artifact.keiro` (one complete aggregate each), and one
  manifest `fleet.keiro-workspace`, all under a single context `fleet`.
  Rationale: the shape mirrors both real motivations at once — Kotei's per-aggregate
  same-context files (`/Users/shinzui/Keikaku/bokuno/kotei/kdsl/*.keiro`, every file
  opening with `context kotei`) and IR-2's originating Mori need for a `Project` root
  aggregate plus a `ProjectArtifact` aggregate sharing `ProjectId`. A dedicated directory
  follows the existing precedent of fixture subdirectories (`incident-paging/`,
  `reference/`) and keeps the workspace's member-path resolution realistic, while the flat
  single-file fixtures (`surge-service.keiro`, `duplicate-names.keiro`) stay untouched.
  Date: 2026-07-29

- Decision: Negative-case workspaces (duplicate aggregate, duplicate shared declaration,
  unresolved cross-file reference, case-folded path collision, failing second member) are
  constructed inside tests by copying the fixture into a `withTempDirectory` sandbox and
  mutating one member with `T.replace`, not committed as sibling fixture directories.
  Rationale: `keiro-dsl/test/Main.hs` already derives most negative variants inline
  (`parseInlineSpec` plus `T.replace` over a fixture source, e.g. the backoff and
  workqueue variants), which keeps one honest on-disk example instead of a dozen
  near-identical broken trees, and guarantees each negative differs from the positive by
  exactly the mutation under test. The on-disk fixture stays a clean, adoptable example
  that the documentation can run against.
  Date: 2026-07-29

- Decision: The documentation surfaces this plan updates are exactly
  `docs/user/typed-spec-toolchain.md`, `docs/guides/brownfield-migration-and-transducer-modeling.md`,
  `docs/guides/evolution-and-replayability.md`, `agents/skills/keiro-dsl-authoring/SKILL.md`,
  `agents/skills/keiro-dsl-authoring/NOTATION.md`, and
  `agents/skills/keiro-dsl-authoring/LOOP.md`, plus `docs/guides/README.md` only if its
  one-line description of the typed-spec guide needs the word "workspace".
  Rationale: these are the surfaces that show `keiro-dsl` CLI command lines today
  (verified by grep on 2026-07-29: the typed-spec guide's synopsis at lines 95–99, the
  brownfield guide's scaffold transcripts at lines 230/278/403, the evolution guide's
  check/diff transcripts at lines 168–171, the skill's "The CLI" section, NOTATION.md's
  "CLI" and "Shared declarations"/"module placement" sections, LOOP.md's numbered loop).
  The root `README.md` names the toolchain only at package-inventory level
  ("parse / check / scaffold / harness / diff", line 108) and gains no workspace-specific
  claim, and `docs/guides/dsl-guarantees-and-hand-written-services.md` mentions `diff`
  only as a guarantee-ledger row; neither needs a change unless implementation proves
  otherwise.
  Date: 2026-07-29

- Decision: Today's collision behavior is pinned as an explicit baseline test before the
  adoption test, asserting the current observable facts: the second same-context scaffold
  overwrites the context-keyed record, reports the first spec's modules as stale, and
  renders the existing "previous scaffold record used spec …" warning.
  Rationale: the migration test is only meaningful against a proven starting point. The
  repository already pins one face of this reality ("reports the entire old tree across a
  module-root flip", `keiro-dsl/test/Main.hs:2152`); the baseline test extends it to the
  two-spec collision IR-2 describes, so the adoption assertions ("imported ownership",
  "no stale false positives") are measured against demonstrated misbehavior, not assumed
  misbehavior. If EP-2's landed adoption path already added an equivalent baseline test,
  extend it rather than duplicating it, and note that here.
  Date: 2026-07-29

- Decision: The IR-2 "property test" obligation is satisfied with a QuickCheck property in
  the existing style of `keiro-dsl/test/Main.hs` (hspec `property $ forAll …` over
  hand-written generators, as in `genSpec`): composition and the planned module set are
  invariant under any permutation of the manifest's member order, generated with
  `QuickCheck`'s `shuffle`.
  Rationale: the suite already uses hspec + QuickCheck (imports at
  `keiro-dsl/test/Main.hs:50–51`) with `forAll`-based properties; permutation invariance
  is the workspace's core determinism claim (IR-2: "Source order must not change its
  meaning or generated bytes") and generalizes the single reorder acceptance bullet from
  one example to all orderings.
  Date: 2026-07-29

- Decision: All new tests live in the existing `keiro-dsl-test` suite
  (`keiro-dsl/test/Main.hs`), in new describe blocks, rather than a new test-suite stanza.
  Rationale: the workspace tests need exactly the helpers that file already defines
  (`withTempDirectory`, `specOf`, `parseInlineSpec`, `readTestText`, `resolveTestPath`,
  `executePlannedScaffold`) and, unlike the conformance suites, compile no consumer code;
  a new stanza would duplicate helper code for no isolation benefit.
  Date: 2026-07-29

- Decision: Draft this plan against the artifact contracts stated in MasterPlan 26's
  Integration Points, and require the implementer to read the landed state of plans 153,
  154, and 155 before writing any code, reconciling every spelling here against what
  landed.
  Rationale: at drafting time the three dependency plans exist as files but are not yet
  implemented, so the manifest grammar, CLI dispatch, record naming, and report wording
  below are targets fixed by the MasterPlan's integration contracts, not observed
  behavior. The landed code is authoritative; divergences must be recorded in this
  Decision Log, exactly as plan 152 did for its dependency on plan 150.
  Date: 2026-07-29


## Outcomes & Retrospective

(To be filled during and after implementation. This section is deliberately load-bearing
beyond this plan: it gathers the inputs for MasterPlan 26's final ADR distillation pass —
whatever migration, adoption, or determinism judgment proves durable here must be listed
so the MasterPlan's completion review can promote it into `docs/adr/`.)


## Context and Orientation

This repository is a Cabal multi-package Haskell project; everything in this plan happens
in the `keiro-dsl` package, under `docs/`, and under `agents/skills/keiro-dsl-authoring/`.
`keiro-dsl` is a specification toolchain: a service is written as a `.keiro` text file,
parsed by `keiro-dsl/src/Keiro/Dsl/Parser.hs`, validated by
`keiro-dsl/src/Keiro/Dsl/Validate.hs`, scaffolded into generated Haskell plus typed holes
by `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and `ScaffoldRun.hs`, and compared across git
revisions by `keiro-dsl/src/Keiro/Dsl/Diff.hs`. The CLI lives in `keiro-dsl/app/Main.hs`
(subcommands `parse`, `check`, `scaffold`, `diff`, `new`).

Terms used throughout, in plain language:

- A *workspace* is one Keiro service whose specification is split across several `.keiro`
  files. A *workspace manifest* is the small file that names the service and lists the
  member files; MasterPlan 26 fixed that membership lives in a versioned file (so
  `diff --since <rev>` can reconstruct it from git) rather than in CLI flags or globs.
  The illustrative form, whose exact landed grammar plan 153 owns, is:

  ```text
  service fleet
  module Fleet.Services
  layout collocated
  spec shared.keiro
  spec project.keiro
  spec project-artifact.keiro
  ```

  `service <name>` is the stable workspace identity that keys scaffold and compatibility
  history; `module`/`layout` are the workspace-level authority for module-root and
  placement policy; each `spec <path>` names a member file relative to the manifest; and
  members have a canonical ordering, meaning reordering the `spec` lines changes neither
  the resolved graph nor one generated byte.
- The *composed graph* (`WorkspaceSpec`, from plan 153's
  `keiro-dsl/src/Keiro/Dsl/Workspace.hs`) is the one resolved service: all members must
  agree on context; shared IDs, enums, rules, mapped structural/opaque declarations, and
  read models resolve once with exactly one owning file each; duplicates — even textually
  identical ones — are refused, never silently merged; and every diagnostic can cite
  file/line locations in several member files.
- A *generated ring* is the set of `-- @generated` modules scaffold emits for one node
  (domain ADTs, codecs, wiring, harness) plus its create-once hand-owned holes. The
  *StructuralProjections facade* is the single context-level generated module derived
  from the merged mapped-type graph; before this initiative it was unconditionally
  overwritten per invocation, which is the collision IR-2 documents.
- The *scaffold record* and *build manifest* are the two bookkeeping files scaffold
  writes into `--out` (today `keiro-dsl-scaffold-record.<context>.txt` and
  `keiro-dsl-manifest.<context>.txt`). Plan 154 keys them by workspace identity, records
  per-module source-file ownership (so moving an aggregate between member files is an
  ownership move, not a stale/new pair), and provides an explicit adoption path that
  imports legacy per-context records without deleting anything or claiming hand-written
  files. *Stale detection* compares the previous whole-workspace module set with the new
  one and never deletes; a *stale false positive* is the pre-workspace failure where two
  same-context specs flagged each other's live modules as stale.
- *Whole-service diff* (plan 155) resolves two complete workspace graphs — working tree
  versus a git revision — classifies a shared-declaration change at every use site, and
  emits one compatibility vector, coverage report, and replay-impact report for the
  service, with ownership moves reported separately from wire evolution.

Hard dependencies. This plan consumes, and must not re-implement, the artifacts of the
three sibling plans:
`docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md`
(EP-1: manifest grammar and loader, `WorkspaceSpec`, multi-file diagnostics, CLI dispatch
that recognizes a manifest versus a single `.keiro`, whole-service `check`),
`docs/plans/154-scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records.md`
(EP-2: whole-workspace planning and execution, workspace-keyed record/manifest with
per-module ownership, idempotence and member-order determinism, the adoption path with
its migration report), and
`docs/plans/155-diff-whole-workspaces-with-shared-declaration-impact-classification-and-unified-compatibility-reports.md`
(EP-3: workspace resolution at `--since` from git blobs, use-site classification, unified
reports, ownership-move advisories). Before writing any code, read all three in their
landed state — their Interfaces and Dependencies sections name the authoritative module
paths, manifest spelling, flags, and report wording — and revise this plan to match,
logging divergences in the Decision Log. If any of the three is not Complete, stop: this
plan's hard dependencies are unmet.

The test suite this plan extends: `keiro-dsl/test/Main.hs` is a single hspec driver
(`main = hspec $ do …`, ~4,200 lines) with QuickCheck for properties
(`import Test.Hspec hiding (Spec)` and `import Test.QuickCheck` at lines 50–51;
properties are written `property $ forAll genSpec $ …` over hand-written generators such
as `genSpec` near line 4193). Filesystem tests run inside
`withTempDirectory :: String -> (FilePath -> IO a) -> IO a` (near line 2505; bracket over
a fresh directory under the system temp root, removed with `removePathForcibly`), execute
real scaffolds with `executePlannedScaffold` (near line 2482), and load fixtures through
`specOf`/`readTestText`/`resolveTestPath`, which locate `test/fixtures/...` from either
the package directory or the repo root. Existing tests to model on: "reports renamed-node
modules as stale without deleting them" and "reports the entire old tree across a
module-root flip" (lines 2141–2162, the scaffold-twice and record-collision patterns),
"refuses a bannerless Generated target without changing its bytes" (line 2123, the
byte-preservation pattern), and the golden comparison against
`test/fixtures/compatibility-vector.diff.golden` (near line 1329, compared with
``T.stripEnd rendered `shouldBe` T.stripEnd golden``).

The fleet layouts being modeled, both verified on 2026-07-29 and neither modified by this
plan: `/Users/shinzui/Keikaku/bokuno/kotei/kdsl/` keeps one aggregate (or integration
surface) per file — `action_run.keiro`, `deployment.keiro`, `forge.keiro`,
`rule-execution.keiro`, `run.keiro` — every file opening with `context kotei` and each
declaring its own ids and enums at the top (for example `deployment.keiro` opens
`context kotei`, `id DeploymentId prefix=dep`, `enum DeploymentStatus { … }`,
`aggregate Deployment`); today these files can only be scaffolded independently, which is
exactly the record-collision reality M2 reproduces. `/Users/shinzui/Keikaku/bokuno/danwa/domain/danwa.keiro`
is the opposite shape: one file, `context danwa`, `layout collocated`, six ids and seven
enums shared in-file by three aggregates (`Conversation`, `Message`, `Embellishment`).
Both shapes must remain valid: the Danwa file is a one-member workspace (or no workspace
at all — single-file commands are unchanged), and the Kotei layout is what the fixture
workspace imitates.

Relevant local ADRs (filenames scanned in `docs/adr/`; only these are relevant):

- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` — each
  evolution hazard is checked at the earliest boundary with enough evidence; the M1
  refusal tests pin exactly this placement (cross-file conflicts refused at compose time,
  before scaffold ever plans a write).
- `docs/adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md`
  — one schema authority per structural mapping; the fixture's shared mapped type must
  resolve to exactly one nominal generated type used by both aggregates, which the
  single-facade scaffold test observes.
- `docs/adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md`
  — coverage stays reporting-first; the whole-service diff test asserts aggregated
  reports, not new gates.
- The workspace-identity/ownership ADR that plan 153 creates (expected `ADR-14`,
  allocated via `okf id next`, exact filename determined when it lands) and any EP-2
  extension of it for adoption semantics: this plan's tests are that ADR's acceptance
  evidence, and M3's documentation must agree with its recorded decision.

This plan expects to create no new ADR: the durable decisions (identity, ownership,
adoption, no-silent-merge, detection-before-write) belong to plans 153 and 154 and the
MasterPlan. If the migration end-to-end tests surface a durable judgment none of those
records cover — for example a refusal rule about unattributable files that EP-2 left
implicit — create or extend the ADR in the same change, following
`agents/skills/exec-plan/ADR.md` (allocate the docId with
`okf id next docs/adr --profile docs/adr/profile.dhall ADR`, maintain `docs/adr/log.md`
with `okf log add`, and run the strict validation shown in Concrete Steps). No relevant
cross-repository ADR exists; IR-2's origin (`mori://shinzui/mori`, Mori MasterPlan 22)
imposes no design constraint beyond the request itself.

Build and test commands (verified against the repo-root `Justfile` on 2026-07-29):
development happens inside the Nix dev shell (`nix develop` from the repo root). The
relevant recipes, quoted exactly: `just adr-validate` runs
`okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`;
`just haskell-build` runs `cabal build all`; `just verify` runs
`process-compose-check jitsurei haskell-verify adr-validate research-validate` and then
`cabal test keiro-migrations-test`. Note that the Justfile's `haskell-test` recipe does
not run the keiro-dsl suites, so the day-to-day loop for this plan is direct:
`cabal build keiro-dsl` and `cabal test keiro-dsl-test` from the repo root.


## Plan of Work

The work proceeds in three milestones matching MasterPlan 26's three EP-4 Progress
entries. The story: first make the fleet layout a checked-in, executable fact and pin
every IR-2 acceptance bullet to a named test against it; then prove the migration path by
first reproducing today's collision and then adopting out of it; then teach both layouts
in the documentation using output captured from the same fixture, so the docs cannot
drift from the behavior without a test noticing.

### Milestone 1 — Fleet-style per-aggregate fixture workspace and acceptance tests for every IR-2 bullet

Scope: the fixture directory and the acceptance describe blocks in
`keiro-dsl/test/Main.hs`. At the end of this milestone,
`keiro-dsl/test/fixtures/workspace-fleet/` exists, `cabal test keiro-dsl-test` runs the
new "fleet workspace" tests green, and every pre-existing example still passes unchanged.

Author the fixture first. `shared.keiro` opens `context fleet` and owns the four shared
declaration kinds the acceptance bullets name: a shared id (`id ProjectId prefix=proj`),
a shared enum (`enum ProjectStatus { Draft=draft Active=active Retired=retired }`), one
mapped structural record (working name `ProjectInfo`, written in the exact syntax of
`keiro-dsl/test/fixtures/structural-conformance.keiro` — `haskell package=… module=…
type=…`, `binding = …`, `binding-version`, `canonical-type`, `fixtures`, `initial`, and a
`wire object` block; the named consumer modules are fictional, which is fine because
these tests plan and write scaffolds without compiling consumer code), and one read model
(working name `readmodel project_index`, in the syntax of
`keiro-dsl/test/fixtures/readmodel.keiro`). `project.keiro` opens `context fleet` and
declares one complete `aggregate Project` whose registers use `ProjectId`,
`ProjectStatus`, and `ProjectInfo` (the mapped register makes the structural facade
necessary) with a `wire` block and a `projection` feeding `project_index`.
`project-artifact.keiro` declares one complete `aggregate ProjectArtifact` that also
references `ProjectId` and the shared enum or mapped type, so both members demonstrably
consume shared declarations. `fleet.keiro-workspace` is the manifest listing the three
members, spelled exactly as plan 153's landed grammar requires. Model prose and structure
on the Kotei files, but keep every declaration repo-local; do not copy Kotei text.

Then add a describe block ("fleet workspace acceptance" or similar) with the following
named tests. The names below are load-bearing: the traceability passage in Validation and
Acceptance refers to them, so keep them stable (adjust spelling only alongside that
passage).

Composition and refusal tests. "composes the fleet workspace and checks it clean" loads
the manifest through plan 153's loader (and once through the CLI, per Concrete Steps) and
asserts zero diagnostics. "refuses a duplicate aggregate declared in two member files"
copies the fixture into a temp sandbox, appends a second `aggregate Project` (a mutated
copy) to `project-artifact.keiro`, and asserts one refusal diagnostic citing both files
with line positions. "refuses a textually identical shared declaration in two members"
duplicates the `id ProjectId prefix=proj` line verbatim into `project.keiro` and asserts
refusal — this is the no-silent-merge pin: byte-identical duplicates are still conflicts
with both owners cited. "reports a cross-file unresolved reference with every relevant
location" deletes the shared enum from `shared.keiro` and asserts the diagnostic names
the use site in `project.keiro` (file and line) rather than a single-file error. "refuses
case-folded generated-path collisions across members" renames `ProjectArtifact` to a
case-variant that collides with `Project`'s generated module path after case folding
(derive the exact variant from the landed path scheme; the single-spec precedent is
"refuses duplicate and case-folded module paths with both origins",
`keiro-dsl/test/Main.hs:2114`) and asserts a refusal naming both member files.

Scaffold tests, all inside `withTempDirectory`. "scaffolds both rings, one facade, and
one workspace record with no stale entries" scaffolds the fixture workspace and asserts:
generated modules for both `Project` and `ProjectArtifact` exist; exactly one
context-level `StructuralProjections` facade module exists (count matching files, expect
one); exactly one workspace-keyed scaffold record and one build manifest exist (and no
context-keyed legacy pair appears); and the report's stale section is empty.
"scaffolding the fleet workspace twice is idempotent" runs scaffold again over the same
output directory and asserts the second report has an empty stale section and the full
recursive file tree is byte-identical (capture path → bytes maps before and after and
compare). "reordering manifest members produces byte-identical output" rewrites the
manifest with `spec` lines in a different order, scaffolds into a second fresh directory,
and compares the two trees byte-for-byte, records included. The companion QuickCheck
property "workspace composition is invariant under member permutation" uses
`forAll (shuffle members)` to assert the composed graph and the planned module set (pure
planning, no filesystem) are equal for every permutation — the property generalizes the
byte test without paying filesystem cost per case. "changing one aggregate preserves the
other's generated files and history" scaffolds, snapshots the bytes of every
`ProjectArtifact` module and the record's ownership entries for them, edits
`project.keiro` (add an event), rescaffolds, and asserts the `ProjectArtifact` bytes and
ownership entries are unchanged, nothing was reported stale, and only `Project` modules
changed. "a failing second member leaves the output tree and record byte-for-byte
unchanged" scaffolds successfully once, snapshots the whole tree, then breaks
`project-artifact.keiro` three ways in three variants — a parse error (truncate a block),
a validation error (reference an undeclared id), and a collision (case-folded duplicate
path) — and asserts each rescaffold attempt refuses with exit-before-write semantics:
the snapshot compares equal afterwards, record included. This pins the MasterPlan's
detection-before-write atomicity decision at workspace scope.

Diff test. "whole-service diff propagates a shared structural-type change to every
affected aggregate and replay root" commits the fixture (or uses plan 155's
source-abstract loader against two in-memory revisions if it exposes one — prefer
whatever plan 155's own tests do), changes `ProjectInfo`'s wire shape in `shared.keiro`
(add a required field), and asserts the unified report classifies the change at the use
sites in both aggregates and the replay-impact report names both aggregates' replay
roots, in one report stamped with the workspace identity.

Regression pin. No existing fixture or golden is edited; the milestone is complete only
when `cabal test keiro-dsl-test` shows every pre-existing example passing byte-unchanged
(the compatibility-vector golden and diff fixtures included), which is the acceptance
bullet that single-file behavior and golden fixtures remain compatible.

### Milestone 2 — Migration end-to-end tests from independent same-context scaffolds

Scope: a second describe block ("workspace adoption from independent scaffolds") in
`keiro-dsl/test/Main.hs`. At the end of this milestone, the collision reality IR-2
documents is pinned as a baseline test, and the adoption path out of it is proven end to
end. All tests run inside `withTempDirectory`.

"independent same-context scaffolds collide in one output tree (baseline)" scaffolds
`project.keiro` alone (single-file mode) into an output directory, then scaffolds
`project-artifact.keiro` alone into the same directory, and asserts today's documented
behavior: both runs wrote the same context-keyed record path (one
`keiro-dsl-scaffold-record.fleet.txt`, its `spec` field now naming the second file), the
second report lists the first aggregate's live modules as stale false positives, and the
rendered report carries the existing warning ("previous scaffold record used spec …", the
message pinned at `keiro-dsl/test/Main.hs:2162`). If plan 154's landed changes altered
this single-file behavior, that is a Surprise — record it and pin the actual behavior;
the point is that the baseline is asserted, not assumed.

"adopting a workspace over independent scaffolds imports ownership without deleting
anything" continues from that exact directory state: it snapshots the full tree, runs the
first workspace scaffold with plan 154's adoption path (whatever its landed spelling —
a flag, an interactive-free default, or a reviewed baseline file), and asserts the
migration report's content: it names the legacy per-context record(s) it imported, it
attributes each existing generated module to its owning member file, the resulting
workspace record carries that per-module ownership, the subsequent report contains no
stale false positive for either aggregate's live modules, and — comparing against the
snapshot — no pre-existing file was deleted and no file was overwritten except the
bookkeeping the migration report explicitly claims (the workspace record/manifest and any
files the report lists as rewritten). A follow-up plain rescaffold is then idempotent.

"adoption refuses to claim an unattributable generated file" plants a file with a
plausible generated path and a `-- @generated` banner that no member's plan produces
(e.g. a leftover from a renamed aggregate of some third spec), runs adoption, and asserts
the file is neither imported into the workspace record's ownership nor deleted; the
migration report lists it as unattributable and leaves it for human review.

"a hand-written bannerless file still refuses through the workspace path (reverse
safety)" mirrors the single-spec banner test (`keiro-dsl/test/Main.hs:2123`) at workspace
scope: place hand-written, banner-less content at one of `ProjectArtifact`'s Generated
target paths, run the workspace scaffold (with and without adoption), and assert refusal
with the file's bytes unchanged — adoption must not become a license to clobber
hand-written code.

### Milestone 3 — Adoption and scaffolding documentation for one-file and per-aggregate layouts

Scope: the six documentation surfaces from the Decision Log, updated with real commands
and real captured output. At the end of this milestone a novice can follow any of three
walkthroughs — start fresh per-aggregate, keep one file, or adopt a workspace over
existing same-context scaffolds — and every command shown is one they can replay against
the checked-in fixture.

`docs/user/typed-spec-toolchain.md` gains a "Service workspaces" section after the
current CLI synopsis: the manifest form with its clause meanings (`service` identity,
`module`/`layout` authority, `spec` members, canonical ordering), the rule that every
command accepts a manifest wherever it accepts a `.keiro` file and that a single `.keiro`
file is a one-member workspace, and a captured check/scaffold/diff transcript against
`keiro-dsl/test/fixtures/workspace-fleet/`. Update the synopsis lines (currently lines
95–99) to show the manifest-accepting form.

`docs/guides/brownfield-migration-and-transducer-modeling.md` gains the adoption
walkthroughs where it currently shows single-file scaffold commands (lines 230/278/403):
first, when to choose per-aggregate files versus one file — per-aggregate for review
ownership and fleet symmetry (Kotei's shape), one file while the service is small or the
declarations are dense with cross-references (Danwa's shape), with the explicit statement
that both are the same service contract and switching later is an ownership move, not a
rewrite; second, adopting a workspace from one existing multi-aggregate file (write the
manifest, optionally split aggregates into member files, rescaffold, observe byte-stable
aggregate modules); third, adopting from independent same-context scaffolds — the M2
scenario narrated for humans, including what the migration report says, what
"unattributable" means, and the instruction that nothing is deleted for you.

`docs/guides/evolution-and-replayability.md`: where `keiro-dsl diff --since` is described
(lines 69, 168–171), add that a workspace manifest diffs as one service — one
compatibility vector, coverage report, and replay-impact report — with a captured
transcript of the M1 shared-type-change diff, and one sentence on ownership-move
advisories being distinct from wire evolution.

`agents/skills/keiro-dsl-authoring/NOTATION.md`: add a "workspace manifest" section
beside "Shared declarations" and "module placement" documenting the manifest grammar
exactly as landed, and extend the "CLI" section's command table with the manifest-input
forms. `agents/skills/keiro-dsl-authoring/SKILL.md`: extend "The CLI" fence with the
manifest forms and add one load-bearing rule sentence: shared declarations have exactly
one owning member file, and duplicates — even identical text — are refused, so fix
conflicts by moving the declaration, never by copying it.
`agents/skills/keiro-dsl-authoring/LOOP.md`: note at the check and scaffold steps that a
multi-file service runs the same loop with the manifest path as the argument.

Every fence added is language-tagged (`text` for manifests and transcripts, `bash` for
commands). Every transcript is captured, not composed: run the command against the
fixture, paste the output, and trim only elisions marked with `…`. State in the
typed-spec guide (once, where the workspace section begins) that the examples are kept
honest by re-running them against `keiro-dsl/test/fixtures/workspace-fleet/` whenever
workspace behavior changes — the fixture is the same one the acceptance tests pin, so a
behavior change that would falsify the docs fails `cabal test keiro-dsl-test` first.

Commit discipline, for every commit in every milestone: Conventional Commits
(`test(dsl): …` for M1/M2, `docs: …` or `docs(skill): …` for M3), committed directly to
the current branch, and each commit message carries the three trailers:

```text
MasterPlan: docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md
ExecPlan: docs/plans/156-prove-per-aggregate-workspace-adoption-with-fleet-style-fixtures-acceptance-tests-and-documentation.md
Intention: intention_01kyq39tsbepwt43q6db89h0d7
```


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`, inside
the Nix dev shell (`nix develop`). Update this section with real transcripts as work
lands; the outputs below are target shapes drawn from the MasterPlan's contracts and must
be replaced with captured text once plans 153–155 are landed.

Read the dependencies' landed state first:

```bash
cat docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md
cat docs/plans/154-scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records.md
cat docs/plans/155-diff-whole-workspaces-with-shared-declaration-impact-classification-and-unified-compatibility-reports.md
```

Confirm each Progress section shows the plan Complete, and note the authoritative
manifest grammar, CLI spelling, record file names, adoption flag, and report wording from
their Interfaces and Dependencies sections. Reconcile this plan before coding.

Build and test after each change:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test
```

Expected tail of a passing run (the example count grows as tests are added):

```text
Finished in ... seconds
... examples, 0 failures
```

Exercise the fixture by hand, the same commands M3's docs capture:

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/workspace-fleet/fleet.keiro-workspace
```

Target shape of a clean whole-service check (replace with captured output):

```text
workspace fleet: 3 member files, context fleet
check: OK
```

```bash
out=$(mktemp -d)
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/workspace-fleet/fleet.keiro-workspace --out "$out"
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/workspace-fleet/fleet.keiro-workspace --out "$out"
```

Target shape: the first run prints both aggregates' modules and dispositions, exactly one
`StructuralProjections` facade path, `firewall: OK …`, and one workspace record/manifest
path; the second run prints all-unchanged dispositions and no `stale:` section. Verify
one facade and the record naming directly:

```bash
find "$out" -name '*StructuralProjections*'   # exactly one path expected
ls "$out" | grep keiro-dsl                    # workspace-keyed record + manifest, per plan 154's naming
```

The diff transcript (after committing a shared-type edit on a scratch branch of the
fixture, or as reproduced hermetically by the M1 diff test):

```bash
cabal run keiro-dsl -- diff keiro-dsl/test/fixtures/workspace-fleet/fleet.keiro-workspace --since HEAD^
```

Target shape: one report stamped with the workspace identity in which the
`ProjectInfo` change is classified at its use sites in both `Project` and
`ProjectArtifact`, and the replay-impact section names both aggregates.

If (and only if) the migration tests force an ADR change (see Context and Orientation),
follow the OKF workflow and validate:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add docs/adr --profile docs/adr/profile.dhall   # consult okf log add --help for exact form
just adr-validate
```

Finish every milestone, and the plan, with the full repository gate:

```bash
just verify
```


## Validation and Acceptance

Acceptance is behavioral. The plan is done when all of the following are observable:

1. `cabal test keiro-dsl-test` passes with every named test from Milestones 1 and 2
   present and green, and with every pre-existing example unmodified and green.
2. The three hand-run transcripts in Concrete Steps (check, scaffold-twice, diff) behave
   as captured against `keiro-dsl/test/fixtures/workspace-fleet/`, and the captured
   output in this plan and in the M3 documentation matches what the commands print today.
3. A falsification probe demonstrates the tests guard behavior, not prose: temporarily
   reorder two `spec` lines in a scratch copy of the manifest while corrupting the
   comparison (or temporarily weaken the byte-tree comparison to path-only) and observe
   "reordering manifest members produces byte-identical output" fail; revert and observe
   green. Likewise, temporarily skip the record snapshot in the failing-second-member
   test and confirm the test still fails if the record is allowed to change. Record both
   probes' results here when performed.
4. The six documentation surfaces named in the Decision Log show the workspace form with
   captured transcripts, and the typed-spec guide states the fixture-honesty rule.
5. `just verify` passes from a clean checkout of the branch.

Traceability from IR-2's ten acceptance bullets to this plan's named evidence, which is
the exit-gate obligation of the whole initiative. The first bullet — a fixture service
with two aggregate files under one context and one shared ID declaration — is the
checked-in `workspace-fleet/` fixture itself, exercised by "composes the fleet workspace
and checks it clean". The second — either aggregate referencing shared enums, mapped
types, and read models under the chosen ownership rules — is the fixture's content
(both aggregates consume `ProjectId`, `ProjectStatus`, `ProjectInfo`, and
`project_index` owned by `shared.keiro`) as resolved by that same clean-check test and
lowered by "scaffolds both rings, one facade, and one workspace record with no stale
entries". The third — whole-service check catching duplicate aggregates, conflicting
shared declarations, cross-file unresolved references, and generated-path collisions with
file/line diagnostics — is the four refusal tests: "refuses a duplicate aggregate
declared in two member files", "refuses a textually identical shared declaration in two
members", "reports a cross-file unresolved reference with every relevant location", and
"refuses case-folded generated-path collisions across members". The fourth — both rings,
exactly one context-level facade, one manifest/record, no stale false positives — is the
single-facade scaffold test again, whose facade count and record census are its explicit
assertions. The fifth — changing one aggregate preserves the other's generated files and
scaffold history — is "changing one aggregate preserves the other's generated files and
history". The sixth — a failed second-file parse, validation, or collision leaves the
output tree and workspace record unchanged — is the three variants of "a failing second
member leaves the output tree and record byte-for-byte unchanged". The seventh —
whole-service diff propagating a shared structural-type change to every affected
aggregate and replay root — is "whole-service diff propagates a shared structural-type
change to every affected aggregate and replay root" plus the hand-run diff transcript.
The eighth — reordering manifest members and repeating scaffold produce byte-identical
output — is "reordering manifest members produces byte-identical output" together with
"scaffolding the fleet workspace twice is idempotent" and the permutation property
"workspace composition is invariant under member permutation". The ninth — existing
single-file CLI behavior and golden fixtures remain compatible — is the Milestone 1
regression pin: the pre-existing `keiro-dsl-test` examples and goldens
(`compatibility-vector.diff.golden` among them) pass without a byte of fixture change.
The tenth — a fleet-style same-context per-aggregate example adopting the workspace
without combining its aggregate sources into one file — is the Milestone 2 pair
("independent same-context scaffolds collide in one output tree (baseline)" then
"adopting a workspace over independent scaffolds imports ownership without deleting
anything", with "adoption refuses to claim an unattributable generated file" and the
reverse-safety banner test guarding the edges), whose scenario the brownfield guide
narrates as the documented adoption walkthrough. When implementation lands, append the
verification result here — bullet by bullet, test by test — before marking the plan
Complete; that verification, together with the Outcomes entry, is the input MasterPlan 26
consumes for its completion review and final ADR distillation pass.


## Idempotence and Recovery

Every step is safe to repeat. The fixture files are static; tests create and destroy
their own sandboxes through `withTempDirectory`, which removes them even on failure, so
a crashed run leaves at most an orphaned directory under the system temp root. The
hand-run transcripts scaffold into `mktemp -d` directories and never touch the checked-in
fixture; the diff transcript uses a scratch branch or the test's hermetic two-revision
setup, never a mutation of `master`'s fixture. Documentation edits are ordinary text
changes: if a captured transcript goes stale mid-work, re-run the command and re-paste.
The only ordering-sensitive step is the conditional ADR workflow (allocate the docId with
`okf id next` immediately before writing the file; if validation fails, fix frontmatter
and re-run — retries corrupt nothing). If a milestone stalls, the earlier ones remain
independently valuable: the fixture plus M1 tests are a complete acceptance harness even
before the migration tests exist, and both are shippable before any documentation
changes. Record every stopping point in Progress.


## Interfaces and Dependencies

This plan adds no library dependency and no new module. It consumes, and is revised
against, the landed interfaces of the three sibling plans:

- From plan 153 (`docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md`):
  the manifest grammar and loader plus the composed-graph type in
  `keiro-dsl/src/Keiro/Dsl/Workspace.hs` (working name `WorkspaceSpec`, carrying merged
  declarations with per-declaration owning file and span, the member `Spec`s, and the
  effective context/module-root/layout), the multi-file diagnostic rendering extended
  from `keiro-dsl/src/Keiro/Dsl/Validate.hs`, and the CLI dispatch in
  `keiro-dsl/app/Main.hs` by which `check`/`scaffold`/`diff` accept a manifest path.
- From plan 154 (`docs/plans/154-scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records.md`):
  the whole-workspace plan/execute entry points over `WorkspaceSpec` (extending
  `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`), the workspace-keyed scaffold record and
  build manifest with per-module source ownership
  (`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs`, `Manifest.hs`), and the adoption entry
  point with its migration-report type — the M2 tests assert against that report's landed
  fields/wording.
- From plan 155 (`docs/plans/155-diff-whole-workspaces-with-shared-declaration-impact-classification-and-unified-compatibility-reports.md`):
  workspace resolution at `--since` from git blobs, use-site classification of
  shared-declaration changes, and the unified compatibility/coverage/replay-impact
  reports stamped with the workspace identity, plus ownership-move advisories.

Within this repository the tests use only existing test infrastructure from
`keiro-dsl/test/Main.hs`: `withTempDirectory`, `executePlannedScaffold` (or its
workspace-scoped analogue from plan 154's tests), `specOf`, `parseInlineSpec`,
`readTestText`/`resolveTestPath`, hspec (`describe`/`it`/`shouldBe`/`shouldSatisfy`),
and QuickCheck (`property`, `forAll`, `shuffle`). Fixture reads resolve through
`resolveTestPath`, so the new fixture directory needs no cabal packaging change (the
suite locates `test/fixtures/...` relative to the package directory or repo root; verify
`keiro-dsl/keiro-dsl.cabal` after adding files in case extra-source-file listing is
required for sdist hygiene, and follow the existing convention either way).

At the end of Milestone 1 the repository contains
`keiro-dsl/test/fixtures/workspace-fleet/{shared.keiro,project.keiro,project-artifact.keiro,fleet.keiro-workspace}`
and the M1 describe block in `keiro-dsl/test/Main.hs`. At the end of Milestone 2 it
additionally contains the adoption describe block, including the pinned baseline test. At
the end of Milestone 3 the six documentation surfaces carry the workspace sections with
captured transcripts, and this plan's living sections carry the traceability
verification, the Outcomes entry feeding MasterPlan 26's distillation pass, and the
updated Progress checklist.
