---
id: 155
slug: diff-whole-workspaces-with-shared-declaration-impact-classification-and-unified-compatibility-reports
title: "Diff whole workspaces with shared-declaration impact classification and unified compatibility reports"
kind: exec-plan
created_at: 2026-07-29T14:09:13Z
intention: "intention_01kyq39tsbepwt43q6db89h0d7"
master_plan: "docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md"
---

# Diff whole workspaces with shared-declaration impact classification and unified compatibility reports

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today `keiro-dsl diff <FILE> --since <git-ref>` compares exactly one `.keiro` spec file
against the version of that same file at a git revision. A service that keeps each
aggregate in its own file — the layout the workspace initiative exists to support —
therefore has no evolution gate over the *service*: a change to a shared declaration
(an `id`, `enum`, or mapped structural type used by several aggregates in several
files) is classified only against the uses visible inside one file, and moving an
aggregate from one member file to another cannot be diffed at all, because neither
file's old revision contains both sides of the move.

After this plan, `keiro-dsl diff <manifest> --since <rev>` accepts a service workspace
manifest (the `.keiro-workspace` file introduced by EP-1,
`docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md`)
and compares two *whole service graphs*: the old one composed from the manifest and
member files as they existed at `<rev>` (read from git blobs, never from the working
tree), and the new one composed from the working tree. Nodes are matched by name
across the whole graph, not by file, so an aggregate moved between member files diffs
against itself and produces zero wire findings. A change to a shared declaration is
classified at every use site across every member, and each finding cites both the
declaration's owning file and the use site's owning file. The command emits one set of
per-surface compatibility vectors, one replay-impact report, and one coverage report
for the service, and the `--gate` exit-code contract is byte-for-byte the single-file
contract applied to the merged findings. Finally, adding or renaming a member file, or
moving an unchanged aggregate between members, is reported as a distinct advisory
"ownership move" finding — never as breaking or additive wire evolution — consistent
with how EP-2's workspace scaffold record tracks per-module source ownership
(`docs/plans/154-scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records.md`).

To see it working: with a two-member fixture workspace committed to a throwaway git
repo, edit a shared enum in the file that owns it, run
`keiro-dsl diff workspace.keiro-workspace --since HEAD`, and observe one finding per
use site across both aggregates — each carrying its compatibility vector, the
declaration's file, and the use site's file — plus a single replay-impact line naming
both affected aggregates. Move an untouched aggregate to a new member file instead,
re-run the same command, and observe exactly one `WARNING … [OwnershipMoved]` finding
and exit code 0. The existing single-file diff path is unchanged in behavior and bytes.


## Progress

- [x] M1: git-blob content provider in `keiro-dsl/app/Main.hs` (repo-root resolution,
      manifest-relative member paths, `git show <rev>:<relpath>`) — 2026-07-29T18:18:45Z
- [x] M1: old-side workspace resolution — manifest text at `<rev>`, old member set
      composed through EP-1's loader with the blob provider — 2026-07-29T18:18:45Z
- [x] M1: adoption fallback when the manifest does not exist at `<rev>` (old side
      composed from the current members' old blobs; printed notice) — 2026-07-29T18:18:45Z
- [x] M1: member-absent-at-rev handling (new member ⇒ additive whole-node surface;
      old-manifest member missing as a blob ⇒ refusal with guidance) — 2026-07-29T18:18:45Z
- [x] M1: unit tests over an in-memory content provider (member added / removed /
      renamed between revisions) and a diff-test.sh workspace scenario — 2026-07-29T18:18:45Z
- [x] M1: single-file diff path proven unchanged (existing diff-test.sh scenarios and
      unit suite green without edits to their expectations) — 2026-07-29T18:18:45Z
- [ ] M2: `Keiro.Dsl.WorkspaceDiff` module — `diffWorkspaces`, ownership annotation of
      merged-graph findings (declaration site + use sites)
- [ ] M2: rendering of file citations as indented continuation lines under the
      existing headline/vector grammar
- [ ] M2: unified reports — one findings stream, one `replayImpact`, one
      `coverageDiffReport` keyed by the manifest path; `--gate`/exit semantics over
      merged findings
- [ ] M2: `keiro-dsl/diff-report/1` extended additively with `declaration`,
      `useSites`, and top-level `workspace` keys including adoption-baseline metadata
      (workspace inputs only)
- [ ] M2: `--emit-goldens` resolves a relative DIR against the manifest's directory
      (one workspace golden root, matching plan 154's layout decision)
- [ ] M2: fixture workspace pair (old/new) with a shared-declaration change; golden
      output test; cross-member use-site assertions
- [ ] M3: `OwnershipMoved` and `WorkspaceAuthorityChanged` appended to
      `DiagnosticCode`; `classifyCompatibility` and `remediationFor` rows;
      `RemedyRescaffoldWorkspace`
- [ ] M3: ownership-move detection in `diffWorkspaces` (node and shared-declaration
      owner changed, content unchanged ⇒ single advisory finding, zero wire findings)
- [ ] M3: workspace authority change reporting (context rename, module-root move,
      layout flip, service identity rename) distinct from wire evolution
- [ ] M3: tests — moved-unchanged-aggregate scenario, renamed member, authority
      change alongside its derived read-model breaking findings
- [ ] M3: ADR-4 inventory amendment for the two new codes and the whole-workspace
      diff boundary; `okf log add`; `just adr-validate` green
- [ ] Final: Outcomes & Retrospective written; ADR distillation pass done


## Surprises & Discoveries

- **The existing `loadWorkspace` reads the manifest through the same source by base
  name, which makes adoption filtering possible without adding a second parser or
  loader API.** The adoption path injects a canonical manifest containing only member
  blobs present at the old revision into a wrapper `ContentSource`; member parsing and
  composition remain entirely inside EP-1's loader. When no current member existed at
  the revision, the manifest grammar's non-empty-member invariant means there is
  nothing to feed that loader, so the old side is an explicitly empty `Spec` carrying
  the current workspace's identity and authority. Evidence: the in-memory added /
  removed / renamed test and the real-git adoption scenario both pass. (2026-07-29)


## Decision Log

- Decision: When the workspace manifest does not exist at `--since <rev>` (the
  adoption case, including a manifest renamed since `<rev>`), the old service graph is
  composed from the *current* manifest's members using each member's blob at `<rev>`;
  members with no blob at `<rev>` contribute nothing (their nodes surface as additive).
  The command prints a one-line adoption notice and stamps
  `"adoptionBaseline": true` into the report's `workspace` metadata. It refuses (with
  guidance to commit the manifest first or fix the members) only when those old blobs
  fail to parse or fail to compose — for example on context disagreement.
  Rationale: IR-2's Compatibility and Migration section requires that existing
  multi-file repositories "can adopt a workspace by listing their current files" with
  byte-stable generated modules; refusing to diff on the very commit that introduces
  the manifest would turn the evolution gate off exactly when member edits ride along
  with adoption, which contradicts ADR-4's earliest-sound-boundary stance. The
  fallback has the same visibility posture as today's single-file diff — files not
  named by the (current) input are invisible — so it weakens nothing that exists.
  Adoption provenance is report metadata, not a `Change` finding, because there is no
  old/new declaration pair to classify and ADR-4 reserves diagnostic codes for
  correlatable spec hazards.
  Date: 2026-07-29

- Decision: The report schema stays `keiro-dsl/diff-report/1` and is extended
  additively — per-finding optional `declaration` (owning file/line) and `useSites`
  (path plus owning file/line) keys, and a top-level `workspace` object (identity,
  manifest path, since ref, old/new member lists, adoption flag). The new keys are
  emitted only for workspace inputs; a single-file diff report remains byte-identical.
  Rationale: the version-1 contract was designed for exactly this. The module haddock
  of `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` (lines 1–7) states that consumers must
  ignore unknown object keys and that the schema is append-only; the only in-repo
  consumer is the unit suite. Bumping to `/2` would force every external reader to
  update for a purely additive enrichment and would squander the append-only promise
  the schema id was given for.
  Date: 2026-07-29

- Decision: Ownership moves and workspace-authority changes are two new append-only
  diagnostic codes, `OwnershipMoved` and `WorkspaceAuthorityChanged`, both Advisory
  headlines whose vectors carry `consumer-build = advisory` and every wire surface
  compatible or not-applicable, with an empty rollout set. A new remedy,
  `RemedyRescaffoldWorkspace`, tells the operator to re-run the whole-workspace
  scaffold so the record's per-module ownership follows the change.
  Rationale: moving an unchanged aggregate between member files changes no generated
  byte and no persisted identity (generated modules are derived from context and node
  names, never from source file paths), so every wire surface is honestly compatible —
  but it does obligate regenerating the workspace scaffold record (golden fixtures
  live in the single workspace root keyed by aggregate, so they do not move),
  which is precisely the consumer-build surface ("generated …
  must be updated … even though wire identity is unchanged"). Carrying that advisory
  verdict also keeps the machine-checked invariant that every headline is derivable
  from its vector under the default gate (`deriveLabel`), which an all-compatible
  Advisory would violate. Neither code is breaking on any gated surface, so the
  default exit code is 0, matching IR-2: "Adding or renaming a source file without
  changing the semantic graph is not a wire break, although it may be reported as an
  ownership move."
  Date: 2026-07-29

- Decision: A workspace context rename or module-root/layout move is reported as
  `WorkspaceAuthorityChanged` (advisory), and its genuinely wire-relevant
  consequences are deliberately left to the existing codes rather than folded into
  the new one. A context rename re-derives read-model registry and subscription names
  (`registryNameFor`/`subscriptionNameFor` take the spec context —
  `keiro-dsl/src/Keiro/Dsl/Diff.hs` lines 807–820), so the existing
  `DerivedIdentityChanged` breaking findings still fire from the merged diff whenever
  a read model exists; a module-root or layout move changes only generated module
  paths, which no persisted identity derives from. The advisory therefore never
  suppresses, replaces, or duplicates a breaking finding.
  Rationale: IR-2's Compatibility section requires the rename/move to be "reported
  separately from private-event wire evolution", and ADR-4 forbids weakening: the
  separation is achieved by adding an advisory beside the existing breaking findings,
  never by rerouting them.
  Date: 2026-07-29

- Decision: The workspace diff is a wrapper layer, `Keiro.Dsl.WorkspaceDiff`, that
  runs the existing `diffSpecs`/`replayImpact`/`coverageDiffReport` over the two
  *merged* `Spec`s and annotates each finding with ownership from the two
  `WorkspaceSpec`s; the `Change` type, `diffSpecs`, and the single-file CLI path are
  not modified (beyond exporting one existing constructor helper).
  Rationale: `diffSpecs` already matches nodes by name (`pairByName`, Diff.hs lines
  554–575) and shared declarations by name (`pairDeclarations`, lines 1254–1264), and
  already fans shared-declaration changes out over whole-graph use sites (`enumUsages`
  lines 1242–1252, `mappedFindingChanges` lines 616–627) — composing first makes
  cross-file matching and use-site propagation fall out for free. Keeping `Change`
  untouched keeps every existing golden, script grep, and report byte stable for
  single-file inputs.
  Date: 2026-07-29

- Decision: For a workspace input, `--emit-goldens DIR` resolves a relative `DIR`
  against the manifest's directory, giving one workspace golden root:
  `--emit-goldens golden-payloads` writes every synthesized payload under
  `<manifest-dir>/golden-payloads/<context>/<aggregate>/<event>.v<n>.json`. An
  absolute `DIR` is honored as given. This adopts plan 154's workspace golden-root
  decision verbatim (one root per workspace, manifest-adjacent default,
  member-adjacent fixtures refused at scaffold plan time with
  `GoldenRootDivergence`), so emission lands exactly where the whole-workspace
  scaffold's `loadGoldenPayloads` will look.
  Rationale: golden fixtures are keyed `<context>/<aggregate>/<event>.v<n>.json`
  (`keiro-dsl/src/Keiro/Dsl/Goldens.hs`), i.e. by aggregate and never by source
  file, so a single root loses no information; per-member roots would scatter
  fixtures into exactly the layout plan 154 refuses. The MasterPlan makes EP-2 the
  owner of the golden-root layout, so this plan follows it rather than inventing a
  second convention. (Revised 2026-07-29 during the MasterPlan consistency review:
  the initial draft routed payloads to each owning member's directory, which
  contradicted plan 154's `GoldenRootDivergence` refusal; corrected before any
  implementation started — see the revision note at the bottom of this plan.)
  Date: 2026-07-29


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository is the `keiro` event-sourcing runtime; the repo root in this checkout
is `/Users/shinzui/Keikaku/bokuno/keiro`, and all paths below are repository-relative.
The package `keiro-dsl` (directory `keiro-dsl/`) is a toolchain over `.keiro`
specification files: a `.keiro` file declares one bounded context's aggregates
(event-sourced state machines), shared declarations (`id`, `enum`, `rule`, mapped
structural/opaque types), contracts, workqueues, processes, routers, read models, and
workflows. The CLI (`keiro-dsl/app/Main.hs`) parses, validates (`check`), generates
code from (`scaffold`), and classifies evolution of (`diff`) those specs. All line
numbers below were verified against this checkout on 2026-07-29; EP-1's merge will
shift some of them, so always re-locate by the named symbol, not the number.

**The diff command today.** `run (Diff …)` in `keiro-dsl/app/Main.hs` (lines 217–247)
resolves the repository root with `git -C <dir-of-FILE> rev-parse --show-toplevel`,
canonicalizes the single `FILE`, computes its repo-relative path, reads the old text
with `git show <ref>:<relpath>`, parses both sides, and then: computes
`changes = diffSpecs oldSpec newSpec` and `impact = replayImpact oldSpec newSpec`;
optionally synthesizes old-shape event payload fixtures (`--emit-goldens DIR` →
`emitGoldenPayloads`); prints each finding with `renderFinding` and, under
`--explain`, `renderExplainBlock`; prints and optionally writes the replay-impact
JSON (`--replay-impact-out FILE`); optionally writes the full compatibility report
(`--report-out FILE` → `diffReport`, schema id `keiro-dsl/diff-report/1`); optionally
writes a coverage diff report (`--coverage-report FILE`, with
`--fail-on-opaque-increase` as an opt-in gate); and exits non-zero iff
`any (gatedBreaking effectiveGate) changes` or the coverage gate failed, where
`effectiveGate = gateWith gatedSurfaces` merges the default gate with repeatable
`--gate SURFACE` options.

**The differ.** `keiro-dsl/src/Keiro/Dsl/Diff.hs` exports
`diffSpecs :: Spec -> Spec -> [Change]` (line 597). A `Change` is
`Additive ChangeKind | Advisory ChangeKind | Breaking ChangeKind`; `ChangeKind`
carries the node name, facet, subject, a mandatory `DiagnosticCode`, an opaque
`ChangeContext`, a six-surface `CompatibilityVector` (type at line 107; surfaces:
private-history-read, old-binary-read-new-events, snapshot-hydration,
public-consumer, persisted-identity, consumer-build), root-to-leaf `ckPaths`, and
prose detail. The headline label is derivable from the vector under a gate
(`deriveLabel`, line 477; `defaultGate` excludes only old-binary-read-new-events,
line 471) and the unit suite enforces that derivation for every exercised finding
(`keiro-dsl/test/Main.hs` lines 1302–1317). Two facts are load-bearing for this plan:

1. *Matching is by name, never by file.* Node families pair old and new declarations
   with `pairByName` (lines 554–575) keyed on the node's stable name; shared
   declarations (`specIds`, `specEnums`, mapped declarations) pair with
   `pairDeclarations` (lines 1254–1264) and the mapped-type graph pairs by
   `MappedKey` (`keiro-dsl/src/Keiro/Dsl/MappedDiff.hs`, `diffMapped` lines 41–64).
   A `Spec` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs` lines 1160–1169) has no notion of
   a source file beyond parse-time locations. Consequently, diffing two *merged*
   specs makes a node moved between files diff against itself.

2. *Use-site propagation already spans the whole spec.* An enum-constructor addition
   fans out into one finding per use site via `enumUsages` (Diff.hs lines
   1242–1252), which scans every aggregate's registers and event fields in the whole
   `Spec`; register uses get a snapshot-hydration advisory and event uses get an
   old-binary rollout advisory (`enumAdditionDiff`, lines 1201–1229). Mapped-type
   findings carry complete `UsePath`s from the resolved type graph and
   `mappedFindingChanges` (lines 616–627) emits one `Change` per path, choosing the
   event/snapshot/build context per root kind (`mappedUseChange`, lines 643–652).
   This is the single-file mechanism this plan generalizes: once the old and new
   sides are *composed* service graphs, the same code classifies a shared
   declaration at every use site in every member. What is genuinely new is citing
   the owning files, because a merged `Spec` has forgotten them — that is what the
   `WorkspaceSpec` ownership data restores.

**Rendering and the report.** `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` owns the pure
renderers and the JSON encoding. `renderFinding` (line 214) prints the stable
headline grammar `ADDITIVE:`/`WARNING:`/`BREAKING:` with a bracketed code on
non-additive lines, followed by an indented `    vector: …` continuation line when
the vector is non-uniform; `renderExplainBlock` (line 246) prints paths, failing
directions, and remedies from the total registry `remediationFor` (line 91);
`parseSurfaceName` (line 274) parses `--gate` spellings. The JSON report
(`instance ToJSON DiffReport`, lines 54–75) emits
`{"schema":"keiro-dsl/diff-report/1","gate":[…],"breaking":…,"findings":[…]}` with an
object-keyed vector per finding. The haddock (lines 1–7) freezes the compatibility
rules: ignore unknown keys, vector keys and `paths` entries are append-only. The
end-to-end script `keiro-dsl/test/diff-test.sh` greps output substrings and asserts
exit codes, so *adding* lines and keys is safe; changing the headline grammar is not.

**Replay impact.** `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` computes
`replayImpact :: Spec -> Spec -> ReplayImpact` (lines 62–75), a conservative
per-aggregate audit input keyed by aggregate name, rendered by `renderReplayImpact`
(lines 223–236) and encoded as the frozen JSON contract
`{"verdict":"replay-neutral"}` / `{"verdict":"affected","aggregates":{…}}` fixed by
ADR-4. This plan feeds it merged specs and does not touch its schema: aggregate
names are unique across a composed service (EP-1 refuses duplicates), so the map
keys remain unambiguous.

**Coverage.** `keiro-dsl/src/Keiro/Dsl/Coverage.hs` provides
`coverageDiffReport :: FilePath -> Text -> Spec -> Spec -> Either … CoverageReport`
(lines 188–226): it builds old/new coverage over the resolved mapped-type graphs,
computes opaque-boundary deltas, and `--fail-on-opaque-increase` converts added
boundaries into an error finding (`failOnOpaqueIncrease`, lines 235–244). Its paths
are node-rooted use paths, file-agnostic, so it works on merged specs unchanged; the
`FilePath` argument becomes the manifest path and the reference the `--since` rev.
Per ADR-13 the report stays reporting-first — this plan adds no new coverage gate.

**Goldens.** `keiro-dsl/src/Keiro/Dsl/Goldens.hs`: `goldensForDiff` (lines 49–66)
synthesizes one old-shape payload per event whose version increased;
`emitGoldenPayloads root old new` (lines 74–86) writes them under
`root/<context>/<aggregate>/<event>.v<n>.json`, never overwriting;
`loadGoldenPayloads` (lines 91–119) is what `scaffold` uses to embed fixtures,
resolving `root` or `root/<context>` (lines 133–143), with the per-spec default root
`takeDirectory fp </> "golden-payloads"` chosen in `keiro-dsl/app/Main.hs` line 193.

**Tests.** The unit suite is `test-suite keiro-dsl-test` (`keiro-dsl/test/Main.hs`,
hspec). The established diff pattern is `diffFixtures :: FilePath -> FilePath -> IO
[Change]` (line 2587) parsing two fixtures under `keiro-dsl/test/fixtures/` and
diffing them, plus `replayImpactFixtures` (line 2627) and a rendered golden
comparison (`compatibility-vector.diff.golden`, exercised at lines 1327–1351). The
merge-gate integration test is `bash keiro-dsl/test/diff-test.sh`, which builds a
throwaway git repo under `mktemp -d`, swaps fixtures in, and asserts classifications,
codes, and exit statuses.

**EP-1 artifacts this plan consumes** (assumed to exist before implementation
begins; this plan hard-depends on EP-1 per the MasterPlan registry — do not start M1
until `docs/plans/153-…md` is Complete; the names below restate EP-1's contract for
self-containment, and if EP-1's landed names differ, adapt to them and note it in
Surprises & Discoveries):

- A workspace manifest file, extension `.keiro-workspace`, declaring the service
  identity (`service <name>`), the module-root/layout authority, and an explicit
  ordered list of member `.keiro` files (`spec <path>` entries, paths relative to
  the manifest's directory). Membership is a versioned file precisely so this plan
  can reconstruct the member set at `<rev>` from git alone (MasterPlan Integration
  Points).
- A composed-graph module (working name `keiro-dsl/src/Keiro/Dsl/Workspace.hs`)
  with a `WorkspaceSpec` carrying: the stable workspace identity, the manifest path,
  the member list, the *merged* `Spec` (one context, all declarations and nodes),
  and per-declaration/per-node source ownership — for every top-level name, the
  owning member file and its source span. Composition refuses duplicate
  declarations, context disagreement, and cross-file conflicts (the no-silent-merge
  rule, ADR-12's one-schema-authority stance).
- A content-provider abstraction in the loader — roughly
  `type ContentProvider m = FilePath -> m (Either Text Text)` — with a filesystem
  provider, designed exactly so this plan can resolve members from git blobs by
  supplying a provider, without re-implementing composition or shelling out per
  member with its own logic (MasterPlan Integration Points: "EP-1 also provides
  source-abstract loading … so EP-3 does not shell out per member file").
- CLI input dispatch in `keiro-dsl/app/Main.hs` that decides by file extension
  whether the `FILE` argument is a workspace manifest or a single `.keiro` spec.
  This plan extends `diff` through that same dispatch and must not add parallel
  flags or subcommands.

**EP-2 integration (record ownership).** EP-2 extends the scaffold record and build
manifest with per-module *source-file ownership* so that moving an aggregate between
member files is recorded as an ownership move rather than a stale/new module pair.
The MasterPlan binds this plan to it: "EP-3 reports ownership moves and must
classify them exactly as EP-2 records them." Concretely: the unit of ownership is
the top-level declaration/node name mapped to its owning member file (EP-1's
ownership data is the shared source of truth for both plans); a move is *only* a
change of that mapping with unchanged declaration content; and this plan's
`OwnershipMoved` finding (M3) must fire in exactly the situations EP-2's record
would re-attribute modules — never when content also changed (then the wire findings
own the story and the move annotation rides along as file citations). EP-2 also owns
the workspace golden-root layout; see the `--emit-goldens` Decision Log entry.
EP-2 and EP-3 are parallel plans: whichever lands second reconciles.

**Relevant ADRs** (scanned `docs/adr/` per `agents/skills/exec-plan/ADR.md`; only
these are needed):

- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`
  (ADR-4) — the evolution-gate inventory. `keiro-dsl diff` is boundary 2 ("hazards
  that require old and new declarations"); diagnostic codes, not prose, are the
  machine contract and are append-only; the replay-impact JSON shape is frozen; the
  compatibility-vector output contract (six surfaces, default gate, `--gate`
  semantics, the `keiro-dsl/diff-report/1` schema with append-only/ignore-unknown
  rules) lives in its Decision section. Constraint on this plan: whole-service diff
  must not weaken any existing single-file gate — every finding that is breaking
  today stays breaking on the merged graph, default exit codes are preserved, and
  the two new codes are added to ADR-4's inventory under its amendment protocol.
- `docs/adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md`
  (ADR-13) — coverage reports named boundaries with no global percentage and no
  default gate; opacity refusal is opt-in (`--fail-on-opaque-increase`). The
  whole-service coverage report aggregates the merged graph's findings without
  inventing new gates.
- `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`
  (ADR-2) — checked for interaction: guard-tightening classification
  (`AggGuardTightened`, Diff.hs lines 918–950) operates per aggregate by name and is
  unaffected by which member file owns the aggregate, so replay-only transitions do
  not interact with this plan's new findings beyond the existing remedy text that
  already cites ADR-2. Not otherwise relevant.
- `docs/adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md`
  (ADR-12) — background for why a shared declaration has exactly one owning file
  producing one nominal type; EP-1 enforces it, this plan relies on it (ownership
  lookup is total for every name the merged differ can emit).
- EP-1 records the workspace identity/ownership decision as a new ADR (expected
  ADR-14 via `okf id next`); cite it from the code once it exists. No
  cross-repository ADR governs this work.

**Definitions.** A *workspace* is the service described by one manifest plus its
member `.keiro` files. The *merged spec* is the single `Spec` value EP-1's composer
produces from all members. An *owning file* for a name is the member that declares
it. A *use site* is a concrete path from a persisted root (an event field, register,
or command field) to the changed leaf — the strings already produced by
`enumUsages`/`renderUsePath`. An *ownership move* is a change of owning file with
byte-identical declaration content. The *authority* is the workspace-level
context/module-root/layout/identity clause set.


## Plan of Work

The work is three milestones matching the MasterPlan's EP-3 Progress entries
exactly. M1 makes `diff --since` able to *see* two whole workspaces; M2 makes the
classification, citations, and the three unified reports; M3 separates ownership
motion from wire evolution. Each milestone keeps `cabal test keiro-dsl-test` and
`bash keiro-dsl/test/diff-test.sh` green.

### Milestone 1 — Workspace resolution at `--since` from git blobs

Scope: `keiro-dsl diff <manifest> --since <rev>` resolves the OLD service graph
from git blobs at `<rev>` — including the manifest itself, whose old member set may
differ from the current one — and the NEW graph from the working tree, both through
EP-1's composer. At the end of this milestone the command parses, composes, and
diffs the two merged specs (findings still without file citations; those are M2),
and every membership edge case has defined behavior. The single-file path is
untouched.

In `keiro-dsl/app/Main.hs`, inside the existing `run (Diff …)` arm (today lines
217–247), branch on EP-1's manifest dispatch. The single-file branch keeps the
current code verbatim. The workspace branch:

1. Resolve the repository root exactly as today: `git -C (takeDirectory fp)
   rev-parse --show-toplevel` via the existing `git` helper (lines 255–260), then
   `canonicalizePath` the manifest and compute its repo-relative path with
   `makeRelative`.
2. Read the old manifest text with `git show <rev>:<relManifestPath>`. Distinguish
   two failures: a bad revision (report git's stderr verbatim and exit, as today)
   versus a path absent from the tree at that revision (git's "does not exist" /
   "exists on disk, but not in" messages) — the latter triggers the adoption
   fallback below.
3. Build a *git-blob content provider* — a `ContentSource` in plan 153's
   `Keiro.Dsl.Workspace` vocabulary (`csRead :: FilePath -> IO (Either Text Text)`)
   — whose read maps a member path to `git show <rev>:<relMemberPath>`. Member paths in a manifest are relative to the
   manifest's directory, so compute each blob path textually as
   `normalise (takeDirectory relManifestPath </> memberPath)` — never
   `canonicalizePath` a member, because an old member may no longer exist on disk.
   The provider returns `Left` with git's message when the blob is missing.
4. Old side: parse the manifest text from step 2 with EP-1's manifest parser, then
   load and compose its members through EP-1's loader with the blob provider. Any
   member listed by the old manifest whose blob is missing at `<rev>` is a hard
   refusal naming the revision and path (the repository was inconsistent at that
   commit; there is no sound old graph to build). Composition refusals (duplicate
   declarations, context disagreement) surface with EP-1's multi-file diagnostics
   and a non-zero exit, before any output artifact is written.
5. New side: load the same manifest path from the working tree with the filesystem
   provider — the identical composer, so old and new graphs are built by the same
   rules.
6. Adoption fallback (manifest absent at `<rev>`): compose the OLD side from the
   *current* manifest's member list, reading each member's blob at `<rev>`; a
   member with no blob at `<rev>` simply contributes nothing, so its nodes appear
   only in the new graph and classify as additive whole-node surfaces
   (`DeclarationAdded`, exactly like a new aggregate today). Print one notice line
   before the findings:
   `workspace adoption baseline: <manifest> does not exist at <rev>; composing the old service from the current members' blobs at <rev>`
   and record the fact for M2's report metadata. If those old blobs fail to parse
   or compose, refuse with guidance ("commit the workspace manifest before
   diffing across it, or fix the member files at the old revision") — never fall
   back to an empty old side, which would misreport every existing event as new.
   See the Decision Log for the full rationale.
7. Membership deltas fall out of composition, and the milestone's tests pin them:
   a member *added* since `<rev>` (listed now, not then) contributes nodes only to
   the new graph → additive; a member *removed* since `<rev>` contributes nodes
   only to the old graph → the existing removal findings fire (for example
   `EvtRemovedNotDeprecated` — deleting a member file deletes its aggregates'
   decoders, which is genuinely breaking); a member *renamed* with unchanged
   content composes to identical merged specs → zero findings in M1 (M3 adds the
   ownership-move advisory).
8. Run the tail of the existing pipeline on the merged specs: `diffSpecs`,
   `replayImpact`, rendering, gates, exit codes — unchanged code paths operating on
   composed inputs. (`--emit-goldens`, `--report-out` enrichment, and coverage
   keying move in M2; in M1 wire them conservatively: goldens and coverage keyed as
   today but off the merged specs, report unchanged.)

Testing: composition-at-a-revision must be testable without git, so EP-1's provider
abstraction is exercised in `keiro-dsl/test/Main.hs` with an in-memory provider
(a `Map FilePath Text`): old/new manifest+member sets covering added, removed, and
renamed members, asserting the classifications above. The git plumbing itself is
covered by extending `keiro-dsl/test/diff-test.sh` with a workspace scenario: build
the temp repo with a manifest and two members, commit, then (a) edit one member and
assert the finding and exit code, and (b) exercise the adoption case by committing
the members *without* the manifest first and adding the manifest only in the
working tree, so `--since HEAD` sees members but no manifest — assert the adoption
notice line and the correct classification.

Acceptance: `cabal test keiro-dsl-test` green including the new provider tests;
`bash keiro-dsl/test/diff-test.sh` prints its final PASS line with the workspace
scenario included; all pre-existing scenarios and expectations unchanged.

### Milestone 2 — Shared-declaration use-site classification and unified compatibility/replay/coverage reports

Scope: workspace findings carry file citations for both the declaration's owner and
every use site's owner; the command emits ONE findings stream, ONE replay-impact
report, and ONE coverage report for the service; gating works across the merged
findings identically to today; `--emit-goldens` writes into the single
manifest-adjacent workspace golden root; the JSON
report gains additive workspace keys. At the end, the observable transcript in the
Purpose section works end to end.

Create `keiro-dsl/src/Keiro/Dsl/WorkspaceDiff.hs` (add to `exposed-modules` in
`keiro-dsl/keiro-dsl.cabal`), the annotation layer over the existing differ:

```haskell
-- | A source citation resolved from a WorkspaceSpec's ownership data.
data OwnedSite = OwnedSite
    { osFile :: !FilePath   -- the owning member, manifest-relative
    , osLine :: !Int        -- the declaration's span start
    }

-- | One merged-graph finding plus the files that own its participants.
data WorkspaceChange = WorkspaceChange
    { wcChange :: !Change
    , wcDeclarationSite :: !(Maybe OwnedSite)  -- owner of ckNode (new side; old side for removals)
    , wcUseSites :: ![(Text, Maybe OwnedSite)] -- each ckPaths entry with its root's owner
    }

diffWorkspaces :: WorkspaceSpec -> WorkspaceSpec -> [WorkspaceChange]
renderWorkspaceFinding :: WorkspaceChange -> Text
```

`diffWorkspaces old new` runs `diffSpecs` on the two merged specs and annotates:
the declaration site is the owner of `ckNode` looked up in the new side's ownership
map (falling back to the old side for pure removals); each use-site owner is found
by taking the root segment of the path (the text before the first `.` — the using
node's name, by construction of `pathFor`, `enumUsages`, and `renderUsePath`) and
looking *that* name up. The lookup is total for every name the merged differ can
emit because EP-1's composer refuses unowned or duplicate names (ADR-12); still,
carry `Maybe` and render nothing rather than crash if a lookup misses, and add a
unit test asserting no `Nothing` occurs for the fixture corpus (that test is the
tripwire for a differ path format drifting from the ownership key).

`renderWorkspaceFinding` prints `renderFinding` (headline + vector line, byte
identical) followed by indented continuation lines, one per citation:

```text
BREAKING: OrderStatus enum-constructor Expired: constructor removed; stored wire value 'expired' no longer decodes; used by Order.reg.status, Shipment.event.ShipmentClosed.finalStatus [EnumCtorRemoved]
    declared: domain/shared.keiro:12
    use-site: Order.reg.status (domain/order.keiro:31)
    use-site: Shipment.event.ShipmentClosed.finalStatus (domain/shipment.keiro:22)
```

Adding indented lines is safe: diff-test.sh greps substrings and the additive
headline grammar is untouched.

Unified reports, wired in the workspace branch of `keiro-dsl/app/Main.hs`:

- Findings: print `renderWorkspaceFinding` per change; `--explain` prints the
  existing `renderExplainBlock` of the inner `Change` (remedies and directions are
  file-agnostic).
- Replay impact: `replayImpact mergedOld mergedNew` — one line, one optional JSON
  file, schema untouched (frozen by ADR-4).
- Coverage: `coverageDiffReport <manifestPath> <rev> mergedOld mergedNew` — one
  report; `--fail-on-opaque-increase` unchanged (ADR-13: no new gates).
- Gate and exit: non-zero iff `any (gatedBreaking effectiveGate . wcChange)` or the
  coverage gate failed — literally today's predicate over the merged findings.

Report schema: in `keiro-dsl/src/Keiro/Dsl/DiffReport.hs`, add a workspace-aware
encoder (for example `workspaceDiffReport :: WorkspaceMeta -> Set
CompatibilitySurface -> [WorkspaceChange] -> DiffReportW` or an extension of the
existing type — keep the existing `diffReport` and its output bytes for single-file
inputs). Same schema id `keiro-dsl/diff-report/1`; per finding add `"declaration":
{"file":…,"line":…}` and `"useSites": [{"path":…,"file":…,"line":…}]`; top level
add `"workspace": {"identity":…,"manifest":…,"since":…,"membersOld":[…],
"membersNew":[…],"adoptionBaseline":…}`. Update the module haddock to document the
new keys as part of the append-only surface. Rationale in the Decision Log.

`--emit-goldens` against the workspace golden root: no new emission function is
needed. For a workspace input, resolve the `DIR` argument —
`takeDirectory manifestPath </> DIR` when relative, `DIR` itself when absolute —
and call the existing `emitGoldenPayloads` (`keiro-dsl/src/Keiro/Dsl/Goldens.hs`
lines 74–86) with the two merged `Spec`s and that root. Payloads land under
`<root>/<context>/<aggregate>/<event>.v<n>.json`, exactly where plan 154's
whole-workspace `loadGoldenPayloads` reads fixtures (its single manifest-adjacent
root; member-adjacent fixtures are refused there at plan time with
`GoldenRootDivergence`). The existing never-overwrite write loop is unchanged, and
the single-file path keeps its current per-spec root resolution untouched. This is
the EP-2 golden-root integration named in the Decision Log.

Fixtures and tests: add a fixture workspace under
`keiro-dsl/test/fixtures/workspace/` — `service.keiro-workspace`, `shared.keiro`
(owning a shared `id`, a shared `enum`, and a shared mapped structural type),
`order.keiro` and `shipment.keiro` (one aggregate each, both using the shared
declarations; give one a snapshot register use and the other an event-field use so
the two use-site classifications differ) — plus an `-new` variant set with a
shared-enum constructor addition and a mapped-type leaf change. Unit tests (via the
in-memory provider, no git):

- the enum addition yields one finding per use site across *both* members, the
  event use advisory-breaking on old-binary-read-new-events and the register use a
  snapshot-hydration advisory (same split the single-file suite pins at
  `keiro-dsl/test/Main.hs` lines 1341–1348), each citing `shared.keiro` as declared
  site and the correct member as use site;
- the mapped leaf change propagates to complete root paths in both members
  (pattern of the nested-propagation test at lines 1394–1406);
- a rendered golden `keiro-dsl/test/fixtures/workspace/workspace.diff.golden`
  pinned with the citation lines;
- the JSON report contains the workspace object, declaration/useSites keys, and
  round-trips the same `breaking` verdict as `gatedBreaking`;
- a single-file report fixture asserts byte-identical output to the pre-M2
  golden (no new keys leak into single-file mode);
- one replay-impact value naming both aggregates when the shared type change
  affects both replay folds.

Acceptance: `cabal test keiro-dsl-test` green including new goldens; diff-test.sh
workspace scenario extended to grep a `declared:` line and a `use-site:` line and
to assert the `--gate`/exit contract on the merged findings; all existing
expectations unchanged.

### Milestone 3 — Ownership-move reporting distinct from wire evolution

Scope: motion of files and ownership is reported, and it is *only* reported — it
never manufactures or suppresses wire findings. At the end: moving an unchanged
aggregate between members, adding or renaming a member file, or changing the
workspace authority each produce exactly the advisory findings defined here, exit
code 0 by default, and the ADR-4 inventory records the new codes.

Append to `DiagnosticCode` in `keiro-dsl/src/Keiro/Dsl/Validate.hs` (at the end of
the enum, after `CodecCompareInvalidInput`, with a
`-- MasterPlan 26 / EP-155 workspace diff codes.` comment; codes are append-only
per ADR-4):

```haskell
    | OwnershipMoved
    | WorkspaceAuthorityChanged
```

In `keiro-dsl/src/Keiro/Dsl/Diff.hs`: give both codes `classifyCompatibility` rows
producing the consumer-build advisory vector (all wire surfaces
compatible/not-applicable, `cvConsumerBuild = VAdvisory`, empty rollout — reuse the
existing `mappedBuildVector` shape), and route them through
`consumerBuildContext` in `contextFor`. Export `advisoryAt` (the context-carrying
advisory constructor, line 1899) so `WorkspaceDiff` can construct the findings. In
`keiro-dsl/src/Keiro/Dsl/DiffReport.hs`: add `RemedyRescaffoldWorkspace` to
`Remedy`, rendered as
`"re-run the whole-workspace scaffold so the record's ownership and golden roots follow the change"`,
and `remediationFor` rows: `OwnershipMoved` → `RemedyRescaffoldWorkspace :| []`;
`WorkspaceAuthorityChanged` → `RemedyRescaffoldWorkspace :| [RemedyRecompileConsumers]`.
The existing totality tests (every emitted code classifies and has a non-empty
remedy) enforce completeness.

In `Keiro.Dsl.WorkspaceDiff`, extend `diffWorkspaces` with two detections that run
beside the merged diff:

1. *Ownership moves.* For every top-level name owned on both sides, if the owning
   member file differs, emit
   `WARNING: <name> ownership <name>: declaration moved <oldFile> -> <newFile> [OwnershipMoved]`
   (facet `"ownership"`, node and subject the moved name, declaration site the new
   owner, use sites empty). Emit it for nodes *and* shared declarations. This must
   agree exactly with EP-2's record semantics (Context and Orientation): the
   trigger is the ownership mapping changing, nothing else. When the moved
   declaration's content also changed, the wire findings from the merged diff carry
   the classification and the `OwnershipMoved` advisory still appears — motion and
   evolution are two facts, reported separately; the critical direction is proven
   by test: content-identical moves produce the advisory and *zero* other findings,
   because the merged specs are equal. A member file rename is the same detection
   applied to every name it owns; a *new* member's names have no old owner and emit
   nothing here (they are additive wire surfaces from M1).
2. *Authority changes.* Compare the composed authority of the two sides — service
   identity, effective context, effective module root, effective layout. Any
   difference emits one
   `WARNING: <service> workspace-authority <field>: … '<old>' -> '<new>' [WorkspaceAuthorityChanged]`
   per changed field, with detail prose per field: a context rename notes that
   generated module namespaces change and that read-model registry/subscription
   identities derive from the context, so accompanying `DerivedIdentityChanged`
   breaking findings (which the merged diff emits on its own, Diff.hs lines
   807–820) are expected whenever read models exist, and that snapshot spec
   identity may change (ADR-3 discriminator); a module-root or layout move notes
   that only generated module paths change; a service-identity rename notes that
   scaffold and compatibility history is re-keyed and points at EP-2's adoption
   path. The advisory never replaces those derived breaking findings — verify with
   a test that a context rename over a fixture containing a read model yields
   *both* the authority advisory and the existing breaking finding, and exits
   non-zero (unchanged gating). This satisfies IR-2's "reported separately from
   private-event wire evolution" without weakening any gate (ADR-4). Gate default:
   both codes are advisory-only vectors, so neither blocks by default nor under any
   `--gate` (no surface is breaking); the reasoned exception — "unless generated
   module paths change wire-relevant identity" — is precisely the read-model case,
   and there the *existing* `DerivedIdentityChanged` code blocks, which is the
   correct owner of that hazard.

The single-file CLI path emits neither code (it has no ownership or workspace
authority input; a single file's context rename keeps today's behavior — visible
only through its derived findings). Record in the report JSON: ownership-move
findings serialize like any finding, with `declaration` citing the new owner.

Tests: fixture variants for (a) moving the `shipment` aggregate unchanged from
`shipment.keiro` into `order.keiro` and deleting the member from the manifest —
assert exactly one `OwnershipMoved` per moved name, zero wire findings, exit 0;
(b) renaming `shipment.keiro` to `shipping.keiro` (manifest updated, content
identical) — same assertions; (c) moving *and* editing — assert the wire finding
and the move advisory coexist; (d) authority rename with a read model — both
findings, exit non-zero; (e) the derivation invariant — both new codes satisfy
`deriveLabel defaultGate . ckVector == Advisory` (they are picked up automatically
by the existing corpus-wide invariant test once fixtures exist). Extend
diff-test.sh with scenario (a) end to end against real git history.

ADR work: amend ADR-4
(`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`) per
its amendment protocol — add inventory rows for `OwnershipMoved` and
`WorkspaceAuthorityChanged` (boundary: cross-spec diff over composed workspaces;
runtime consequence: none on wire surfaces; remedy: re-scaffold the workspace) and
a sentence in the Decision section that `diff` now operates over composed workspace
graphs resolved from git revisions with membership taken from the manifest at each
revision. Keep `docId: ADR-4` and the original `date`; advance `timestamp`; add the
log entry with `okf log add` (never hand-edit `docs/adr/log.md` when the tool
succeeds); run `just adr-validate`. If EP-1's ADR-14 exists by then, cross-reference
it for the identity/ownership definitions instead of restating them.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.
The project builds with cabal inside the flake dev environment; if your shell is
not already in it, run `nix develop` first. The recipe file is `Justfile` (capital
J); `just --list` shows recipes.

The tight loop for every milestone:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test
```

Expected on success: the hspec run ends with `0 failures`. Note that the repo-wide
recipes do not cover this suite — the `Justfile`'s `haskell-test` recipe is:

```text
[group('haskell')]
haskell-test:
    cabal test keiro-test
    cabal test keiro-pgmq-test
    cabal test jitsurei-test
    cabal run jitsurei:exe:jitsurei-diagrams -- --check
```

so `keiro-dsl-test` must be run explicitly as above. The full repo gate, if you
want it before a milestone commit, is `just verify` (which chains
`process-compose-check jitsurei haskell-verify adr-validate research-validate` plus
`cabal test keiro-migrations-test` and needs the local Postgres environment).

The end-to-end merge-gate script (requires a prior `cabal build keiro-dsl` so
`cabal list-bin keiro-dsl` resolves):

```bash
bash keiro-dsl/test/diff-test.sh
```

Expected final line: the script's PASS summary (currently
`PASS: diff --since gates the decode and identity surface`; extend the message when
you extend the script). The script builds its own throwaway git repo under
`mktemp -d` and cleans up on exit.

ADR validation after the M3 amendment — the `Justfile` recipe is:

```text
[group('docs')]
adr-validate:
    okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Run it as `just adr-validate`; it must exit 0. If it reports a stale log, add the
entry with `okf log add` (run `okf log add --help` for arguments; match the
existing entry style) and re-run.

Manual smoke transcript (after M2), using the fixture workspace in a temp repo:

```bash
DEMO=$(mktemp -d)
git -C "$DEMO" init -q
cp keiro-dsl/test/fixtures/workspace/*.keiro keiro-dsl/test/fixtures/workspace/service.keiro-workspace "$DEMO"/
git -C "$DEMO" add . && git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm baseline
cp keiro-dsl/test/fixtures/workspace-new/shared.keiro "$DEMO"/shared.keiro
"$(cabal list-bin keiro-dsl)" diff --since HEAD "$DEMO"/service.keiro-workspace
```

Expected: one finding per use site across both members with `declared:` and
`use-site:` citation lines, one replay-impact line, and the exit code implied by
the gated surfaces.

Commit per milestone (or more often at any green point) on the current branch —
no feature branch — with conventional-commit messages, and put the coordination
trailers on **every** commit:

```text
feat(dsl): resolve whole-workspace diffs at --since from git blobs

MasterPlan: docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md
ExecPlan: docs/plans/155-diff-whole-workspaces-with-shared-declaration-impact-classification-and-unified-compatibility-reports.md
Intention: intention_01kyq39tsbepwt43q6db89h0d7
```

Suggested subjects for the later milestones:

```text
feat(dsl): classify shared-declaration changes at every workspace use site with owned citations
feat(dsl): emit one compatibility, replay-impact, and coverage report per service workspace
feat(dsl): report ownership moves and authority changes distinct from wire evolution
docs(adr): record workspace diff boundary and ownership-move codes in ADR 0004
```

Update this plan's Progress section (and Decision Log / Surprises when applicable)
in the same commit as the work it describes.


## Validation and Acceptance

**No-weakening (the ADR-4 constraint, machine-checked).** Every pre-existing
diff-test.sh scenario and unit expectation passes without modification: the
single-file path is not edited, so anything BREAKING today is BREAKING after, with
identical codes and exit statuses. On the workspace path, the corpus-wide
invariant test (`deriveLabel defaultGate . ckVector` reproduces every headline)
extends over the new fixtures automatically, so neither new code nor any
annotation can demote a finding. The negative test that must exist: a shared-enum
constructor *removal* in `shared.keiro` exits non-zero with `EnumCtorRemoved`
citing use sites in both members — the same hazard that today's single-file gate
catches in one file must be caught service-wide.

**M1 acceptance.** With the fixture workspace committed and one member edited,
`diff <manifest> --since HEAD` classifies the edit; with a member added since the
baseline, its nodes are ADDITIVE (`DeclarationAdded`) and exit is 0; with a member
removed, its aggregates' events are BREAKING (`EvtRemovedNotDeprecated`) and exit
is non-zero; with the manifest absent at the baseline, the adoption notice line
prints and classification proceeds from the current members' old blobs; with an
old-manifest member missing as a blob, the command refuses naming rev and path.
`cabal test keiro-dsl-test` and `bash keiro-dsl/test/diff-test.sh` green.

**M2 acceptance.** The smoke transcript above shows, for one shared-declaration
edit: findings at every use site in every member; each finding's `declared:` line
citing `shared.keiro` and each `use-site:` line citing the correct member file;
exactly one replay-impact line (and one JSON file under `--replay-impact-out`)
naming every affected aggregate; exactly one coverage report keyed by the manifest
path under `--coverage-report`; and a `--report-out` JSON with schema
`keiro-dsl/diff-report/1`, a `workspace` object, and `declaration`/`useSites` keys
on findings. A single-file diff's report and text output are byte-identical to
before this plan (pinned by test). `--gate old-binary-read-new-events` flips the
shared-enum event-use advisory to blocking exactly as it does today for the
single-file enum fixture. `--emit-goldens golden-payloads` on a workspace with an
event version bump writes the synthesized payload under the manifest-adjacent
`golden-payloads` root and never overwrites an existing file.

**M3 acceptance.** Moving the unchanged `shipment` aggregate between members:
output contains `[OwnershipMoved]` warnings (one per moved name) with the
`<oldFile> -> <newFile>` detail, contains no ADDITIVE or BREAKING wire finding,
and exits 0. Renaming a member file with identical content: same. Moving and
editing: both the wire finding and the move advisory appear. Renaming the context
in a fixture with a read model: `[WorkspaceAuthorityChanged]` appears *and* the
existing `DerivedIdentityChanged` breaking finding appears, exit non-zero.
`remediationFor` totality and derivation-invariant tests pass for both new codes.
`just adr-validate` exits 0 after the ADR-4 amendment and log entry.

**Regression.** `cabal build keiro-dsl`, `cabal test keiro-dsl-test`,
`bash keiro-dsl/test/diff-test.sh` all green at every milestone boundary. No
scaffold conformance suite is affected (this plan writes no generated modules);
if any conformance suite fails, something leaked outside the diff subsystem —
stop and investigate.


## Idempotence and Recovery

Every step is additive and repeatable. Re-running cabal builds and tests is always
safe; diff-test.sh isolates itself in a `mktemp -d` repo and cleans up on exit, so
re-runs cannot pollute the working tree. `diff` itself only ever writes the files
named by explicit flags (`--report-out`, `--replay-impact-out`,
`--coverage-report`, `--emit-goldens`); golden emission never overwrites, so
re-running it is idempotent by construction. Fixture goldens are checked-in text:
if a rendering change is intentional, regenerate by copying the new rendered
output after eyeballing the diff and say why in the commit message. The
`DiagnosticCode` additions are append-only; if a milestone must be reverted, the
new codes can remain in the enum harmlessly (no emitter, and the totality tests
only cover emitted codes). The ADR-4 amendment is a text edit plus `okf log add`;
if the log entry is duplicated, remove the duplicate and re-run
`just adr-validate`. M1, M2, and M3 land as separate commits and each leaves the
tool releasable: M1 without citations is a functional whole-service gate, M2
without M3 simply reports a content-identical move as zero findings (silent but
sound), so partial completion never misclassifies wire evolution.

If EP-1's landed interfaces differ from the names assumed here (provider shape,
`WorkspaceSpec` accessors, manifest extension), adapt at the seams named in
Interfaces and Dependencies, note the deltas in Surprises & Discoveries, and do
not fork parallel loaders — the MasterPlan forbids secondary identity sources and
re-parsing members outside EP-1's loader.


## Interfaces and Dependencies

No new package dependencies. Everything lands in the existing `keiro-dsl` package
(`keiro-dsl/keiro-dsl.cabal`); JSON uses the already-depended `aeson`, the CLI the
already-depended `optparse-applicative`, and git access the already-used
`readProcessWithExitCode` plumbing in `keiro-dsl/app/Main.hs`.

Consumed from EP-1 (`docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md`),
restated: the `.keiro-workspace` manifest grammar and parser; `Keiro.Dsl.Workspace`
(working name) with `WorkspaceSpec` (identity, manifest path, member list, merged
`Spec`, per-name owning file and span), a loader parameterized by a content
provider (`FilePath -> m (Either Text Text)` or EP-1's equivalent), the filesystem
provider, multi-file diagnostics, and the CLI manifest-extension dispatch. This
plan must not re-parse member files or invent a second identity.

At the end of M1, `keiro-dsl/app/Main.hs` additionally contains the git-blob
content provider (built over the existing `git` helper) and the workspace branch of
`run (Diff …)` that composes both sides and defines the adoption fallback and
membership-delta behavior.

At the end of M2, the library additionally exposes `Keiro.Dsl.WorkspaceDiff` with
`OwnedSite`, `WorkspaceChange`, `diffWorkspaces :: WorkspaceSpec -> WorkspaceSpec
-> [WorkspaceChange]`, and `renderWorkspaceFinding :: WorkspaceChange -> Text`;
`Keiro.Dsl.DiffReport` gains the workspace report encoder emitting schema
`keiro-dsl/diff-report/1` with the additive `declaration`/`useSites`/`workspace`
keys; `Keiro.Dsl.Goldens` is unchanged — the workspace path calls the existing
`emitGoldenPayloads` with the manifest-resolved root. The replay-impact and
coverage modules are unchanged; they are fed merged specs and the manifest path.

At the end of M3, `Keiro.Dsl.Validate` has appended `OwnershipMoved` and
`WorkspaceAuthorityChanged`; `Keiro.Dsl.Diff` classifies both (consumer-build
advisory vectors), routes them through `consumerBuildContext`, and exports
`advisoryAt`; `Keiro.Dsl.DiffReport` has `RemedyRescaffoldWorkspace` and remedy
rows for both codes; `Keiro.Dsl.WorkspaceDiff` emits the ownership-move and
authority-change findings. ADR-4 carries the amended inventory, and EP-1's
workspace ADR (expected ADR-14) is cross-referenced where the identity and
ownership definitions are used.

Integration points owned elsewhere and honored here: EP-2's record ownership model
and golden-root layout (`docs/plans/154-scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records.md`)
— ownership moves are classified exactly as EP-2 records them, and golden routing
follows EP-2's layout, with the second-lander reconciling; the CLI dispatch and
composed graph (EP-1); the fixture workspace built here is reused and extended by
EP-4 (`docs/plans/156-prove-per-aggregate-workspace-adoption-with-fleet-style-fixtures-acceptance-tests-and-documentation.md`)
for the IR-2 acceptance sweep.


## Revision Notes

- 2026-07-29: Reconciled golden-payload emission with plan 154 during the MasterPlan
  consistency review, before any implementation. The initial draft routed
  `--emit-goldens` output to each owning member's directory; plan 154 had
  independently decided on one manifest-adjacent workspace golden root and a
  plan-time `GoldenRootDivergence` refusal for member-adjacent fixtures, and the
  MasterPlan assigns golden-root ownership to EP-2. This plan now resolves a
  relative `--emit-goldens DIR` against the manifest's directory and reuses the
  existing `emitGoldenPayloads` unchanged (the proposed `emitGoldenPayloadsOwned`
  helper was dropped). Progress, Decision Log, Milestone 2, acceptance, and
  interface sections were updated together.
