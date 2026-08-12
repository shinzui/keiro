---
id: 235
slug: retire-or-repair-the-legacy-spec-only-scaffold-entry-points
title: "Retire or repair the legacy Spec-only scaffold entry points"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjznhgeyvbcpfk1znzmbnr"
master_plan: "docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md"
---

# Retire or repair the legacy Spec-only scaffold entry points

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The `keiro-dsl` library currently exports seven scaffold-planning and check entry points
that can no longer succeed for any realistic input. `planServiceScaffold` (and its
`WithGoldens` / `WithRuntimePackage` / `WithRuntimePackageAndGoldens` variants),
`planScaffold`, `planScaffoldWithGoldens`, and `checkServiceDiagnostics` all accept a
semantic spec without source provenance, silently derive a line-only "compatibility" source
index for it, and then hand that index to a planning pipeline that — by deliberate design
of the exact-provenance work in
`docs/masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md` —
refuses every line-only anchor. The result: any spec containing at least one aggregate
transition gets one `BehaviorSourceAnchorInexact` planning error per behavior requirement,
on a perfectly valid spec that these same entry points planned cleanly in the released
0.11.0.0. The 2026-08-11 pre-release review confirmed this as a defect that must be
resolved before 0.12.0.0 ships.

This plan resolves it by RETIRING the seven entry points in the 0.12.0.0 major release
rather than repairing them (the decision and its evidence are in the Decision Log and in
Context and Orientation below). After this change, a library consumer who follows the
types can only reach the planners that actually work: the `planIndexedServiceScaffold*`
family and `checkIndexedServiceDiagnostics`, which take an explicit `SemanticSourceIndex`.
The user-visible outcome is threefold: the package compiles with the dead entry points
gone; the `keiro-dsl` test suite passes without referencing them (while still proving that
line-only provenance can never fabricate exact behavior columns); and the
`keiro-dsl/CHANGELOG.md` Unreleased section documents the removal with a concrete
migration recipe for 0.11.0.0 callers, including callers that construct a `Spec`
programmatically.

You can see it working by building and testing from the repository root
(`/Users/shinzui/Keikaku/bokuno/keiro`): `cabal build keiro-dsl` succeeds, a repo-wide
grep for the removed names finds no live Haskell reference, `cabal test keiro-dsl:tests`
passes, and `just verify` stays green.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-12T02:49:06Z) Milestone 1: deleted the seven legacy exports and their definitions from
      `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, relocated their still-true Haddock prose to
      the indexed variants, tightened the now-partial imports, and verified that
      `cabal build keiro-dsl` compiles cleanly.
- [x] (2026-08-12T03:00:07Z) Milestone 2: removed the one remaining test reference from
      `keiro-dsl/test/Main.hs`, replaced the guard with a direct
      `planBehaviorSourceMap`-over-compatibility-index assertion, verified that no live Haskell
      reference remains, and passed both `cabal test keiro-dsl-test` and
      `cabal test keiro-dsl:tests`.
- [x] (2026-08-12T03:01:29Z) Milestone 3 documentation: added the Breaking Changes migration
      recipes to `keiro-dsl/CHANGELOG.md` and amended
      `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md` to record
      indexed-only planning as API policy.
- [x] (2026-08-12T03:10:59Z) Milestone 3 validation and bookkeeping: passed strict ADR-16
      profile/log enforcement and `just verify`, then updated the MasterPlan 36 registry row and
      all EP-3 progress lines.
- [x] (2026-08-12T03:10:59Z) Wrote the Outcomes & Retrospective entry and completed the ADR
      distillation pass by amending ADR-16.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. Findings made during plan research — for example, that the test suite had
already migrated itself onto the indexed path via private helpers — are recorded in
Context and Orientation, not here; this section is for discoveries made while
implementing.)


## Decision Log

Record every decision made while working on the plan.

- Decision: RETIRE the legacy Spec-only entry points; do not repair them.
  Rationale: Every live caller inventory came back empty. The `keiro-dsl` CLI
  (`keiro-dsl/app/Main.hs`) parses with `parseSourceDocument` and calls only
  `checkIndexedServiceDiagnostics` and `planIndexedServiceScaffoldWithRuntimePackageAndGoldens`.
  No module under `keiro-dsl/src` calls the legacy planners. `jitsurei/` and
  `keiro-test-support/` contain no references. The test suite defines its own indexed
  helpers (`planTestScaffold`, `planTestServiceScaffold`, `checkTestServiceDiagnostics`
  over a `syntheticExactSourceIndex`, `keiro-dsl/test/Main.hs` lines 10656–10683) and
  touches `planServiceScaffold` exactly once — as a negative test asserting it refuses
  (line 3069). Outside the repository, `mori registry dependents keiro --packages` lists
  only one package-level dependent, `mori://shinzui/mori-app`, whose checkout contains
  zero `Keiro.Dsl` imports, and `mori://shinzui/keiro-syntax` is VimScript/TypeScript
  syntax highlighting that consumes no Haskell API; all other dependents are project-level
  documentation references. Repair, by contrast, would require making
  `CompatibilityLineOnly` anchors plannable, which directly contradicts two accepted ADRs:
  `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
  ("Bare-`Spec` scaffold planning cannot use its compatibility line-only index as exact
  provenance and fails explicitly instead of inventing columns") and
  `docs/adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md`
  ("Missing, inexact, duplicate, or colliding anchors refuse before scaffold writes").
  0.12.0.0 is a major release, so removal is legal now and never will be cheaper; because
  the regression exists only on the unreleased development branch, external 0.11.0.0
  consumers go straight from "worked in 0.11" to "removed in 0.12 with a migration note"
  and never observe the always-refusing intermediate state.
  Date: 2026-08-11 (plan authoring).
- Decision: delete `checkServiceDiagnostics` rather than keep it.
  Rationale: the retire-or-repair brief allowed keeping it if something real uses it.
  Nothing does — a repo-wide grep finds no caller in `keiro-dsl/app`, `keiro-dsl/src`
  (other than its own definition and export), `keiro-dsl/test`, `jitsurei/`, or
  `keiro-test-support/`, and no external Haskell consumer exists (see previous entry).
  Date: 2026-08-11 (plan authoring).
- Decision: keep the Spec-only non-planning compatibility bridges —
  `scaffoldModules`, `scaffoldModulesWithGoldens` (module-set builders in
  `Keiro.Dsl.ScaffoldRun`), `validateSpec`, the `Keiro.Dsl.Scaffold` per-node wrappers,
  and `compatibilitySemanticSourceIndex` itself in `Keiro.Dsl.SourceIndex`.
  Rationale: none of them joins behavior requirements to source anchors, so none of them
  is broken; the test suite uses `scaffoldModules` at thirteen call sites; and ADR-0016
  explicitly blesses Spec-only functions as "compatibility bridges with explicit
  legacy/version-1 semantics" for surfaces that do not claim provenance.
  `Keiro.Dsl.Workspace` (line 724) also uses `compatibilitySemanticSourceIndex` for
  honest line-only member adapters. Retirement is scoped to the seven planning/check
  wrappers that can only fail.
  Date: 2026-08-11 (plan authoring).
- Decision: replace, not delete, the negative guard assertion at
  `keiro-dsl/test/Main.hs` lines 3069–3071.
  Rationale: that assertion ("semantic-only planner fabricated exact behavior columns")
  protects a real property — line-only provenance must never appear as exact columns in
  generated bytes. After retirement the property is enforced twice: by the type system
  (no exported planner accepts a service without a `SemanticSourceIndex`) and by the
  direct join-level assertion this plan substitutes (see Milestone 2), which pins
  `planBehaviorSourceMap` + `compatibilitySemanticSourceIndex` to all-`BehaviorSourceAnchorInexact`
  refusals inside the same end-to-end example.
  Date: 2026-08-11 (plan authoring).
- Decision: record the durable "indexed-only planning" API policy by amending existing
  ADR-0016 rather than allocating a new ADR.
  Rationale: ADR-0016 already owns the Spec-only-wrapper contract (its Decision section
  currently promises "Compatibility entry points that accept only `Spec` remain documented
  legacy/version-1 wrappers"); the ExecPlan specification directs updating an existing ADR
  when it already covers the topic. MasterPlan 36's Integration Points anticipates exactly
  this ADR touch for EP-3.
  Date: 2026-08-11 (plan authoring).


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The seven unusable Spec-only planning and check entry points are retired. The remaining public
planning surface requires a caller-supplied `SemanticSourceIndex`, while the Spec-only module-set
builders that make no provenance claim remain available. The test suite still proves that a
compatibility line-only index cannot fabricate exact behavior columns by exercising the source-map
join directly.

The migration is documented for both parsed source documents and programmatically constructed
specs. ADR-16 now records indexed-only planning as durable API policy, and the ADR bundle log
records the amendment. `cabal build keiro-dsl`, the focused 695-example suite, every declared
`keiro-dsl` suite, strict ADR validation, and `just verify` all pass. The conformance corpus remains
byte-identical, so the retirement changed only the public surface and its negative proof, not
indexed planning output.


## Context and Orientation

This repository is a Haskell multi-package project. The package that matters here is
`keiro-dsl`, which compiles `.keiro` service specifications into generated Haskell
modules. Its library is consumed by its own CLI executable (`keiro-dsl/app/Main.hs`), its
test suites (`keiro-dsl/test/Main.hs` and many conformance suites), and in principle by
any external package. Version `0.11.0.0` of every keiro package was released on
2026-08-05/06; the working tree targets the next major release, 0.12.0.0
(`keiro-dsl/keiro-dsl.cabal` still says `version: 0.11.0.0`; the bump happens in release
mechanics outside this plan). Because 0.12.0.0 is a major version, breaking library-API
changes are legal, and this is the cheapest moment they will ever be.

Terms used below, defined once:

- A *spec* (`Spec`, defined in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`) is the semantic
  graph of one service: aggregates with states and transitions, routers, contracts,
  read models, and so on. It deliberately carries no source positions beyond legacy
  line numbers (`Loc`).
- A *checked service* (`CheckedService`, `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`)
  pairs a `Spec` with the effective language contract chosen by the source's `language`
  preamble. `legacyCheckedService` wraps a bare `Spec` with legacy/version-1 semantics.
- A *semantic source index* (`SemanticSourceIndex`,
  `keiro-dsl/src/Keiro/Dsl/SourceIndex.hs`) maps each aggregate state and each aggregate
  transition ordinal (the *source subjects*) to a source span. Every entry carries a
  quality tag: `ExactSourcePosition` (produced by the real parser) or
  `CompatibilityLineOnly` (synthesized from a bare `Spec`'s legacy line numbers, column
  fixed at 1 — honest about being inexact).
- A *parsed source document* (`ParsedSourceDocument`, same module) is what
  `parseSourceDocument` (`keiro-dsl/src/Keiro/Dsl/Parser.hs`) returns: the parsed source
  plus its checked, complete, exact index. The older `parseSource`/`parseSpec` entry
  points return no index and remain supported for parse/pretty compatibility.
- A *behavior requirement* (`keiro-dsl/src/Keiro/Dsl/BehaviorCoverage.hs`) is one frozen
  obligation derived from the spec — one per live aggregate transition and one per
  reachable state/command rejection cell. Scaffolding emits a generated context
  `BehaviorSourceMap` module mapping each requirement's frozen key to its exact current
  file, line, and column.

The defect. `planServiceScaffoldWithRuntimePackageAndGoldens`
(`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, lines 337–344) is the shared body of the
legacy planners. It calls `compatibilitySemanticSourceIndex "<semantic-only>"
(checkedSpec service)` (`SourceIndex.hs` lines 133–153), which tags every anchor
`CompatibilityLineOnly`, then delegates to the indexed planner. The indexed planner's
`behaviorSourcePlan` (lines 382–384) derives the behavior requirements and joins them via
`BehaviorSource.planBehaviorSourceMap`. Inside that join, `planEntry`
(`keiro-dsl/src/Keiro/Dsl/BehaviorSourceMap.hs`, lines 140–153) pattern-matches the
anchor quality and returns `Left (… BehaviorSourceAnchorInexact …)` for every
`CompatibilityLineOnly` anchor — "behavior source subject has only a compatibility line,
not an exact position". So for any spec with at least one aggregate transition or
rejection cell, `completeModulePlan` fails with one `BehaviorSourceRefusal` carrying one
`BehaviorSourceAnchorInexact` failure per requirement, and the legacy planners can never
return `Right`. Only aggregate-free specs (whose requirement inventory is empty) still
pass. `checkServiceDiagnostics` (lines 443–456) routes through the same compatibility
index into `checkIndexedServiceDiagnostics` and surfaces the same refusals as
`BehaviorSourceAnchorInexact` diagnostics. `planScaffold` and `planScaffoldWithGoldens`
(lines 570–574) are `Spec`-level wrappers over the same body via `legacyCheckedService`.
In released 0.11.0.0 these entry points planned transition-bearing specs cleanly; the
regression arrived with the exact-provenance work of MasterPlan 34 and exists only on the
unreleased development branch.

The seven affected exports, all from `Keiro.Dsl.ScaffoldRun` (export list lines 18–21,
26–27, and 48 of `ScaffoldRun.hs`):

- `planServiceScaffold`
- `planServiceScaffoldWithGoldens`
- `planServiceScaffoldWithRuntimePackage`
- `planServiceScaffoldWithRuntimePackageAndGoldens`
- `planScaffold`
- `planScaffoldWithGoldens`
- `checkServiceDiagnostics`

`Keiro.Dsl.ScaffoldRun` is directly exposed in `keiro-dsl/keiro-dsl.cabal`
(`exposed-modules`, line 97); there is no umbrella module re-exporting these names, so
the export list of `ScaffoldRun.hs` is the entire public surface to edit.

Caller inventory (the evidence the Decision Log rests on; re-verify with the grep in
Concrete Steps before editing):

- `keiro-dsl/app/Main.hs` (the CLI): imports only `checkIndexedServiceDiagnostics`,
  `executeServiceScaffoldWithRuntimePackageAndNameMigrations`,
  `planIndexedServiceScaffoldWithRuntimePackageAndGoldens`, `renderRefusals`, and
  `renderScaffoldReport` from `ScaffoldRun` (line 33). Every command parses with
  `parseSourceDocument` and threads `documentSourceIndex` through.
- `keiro-dsl/src`: no module other than `ScaffoldRun.hs` itself references the seven
  names. `Keiro.Dsl.WorkspaceScaffold` reuses the shared seam (`planningGatePipeline`,
  `checkIndexedServiceDiagnostics`, and friends), never the legacy wrappers.
- `keiro-dsl/test/Main.hs`: imports `planServiceScaffold` (line 73) and calls it once, at
  lines 3069–3071, inside the example "plans one exact context source map and removes
  line-derived contract and witness bytes" — a negative test asserting the legacy planner
  refuses with all-`BehaviorSourceAnchorInexact` failures. All positive planning tests go
  through private helpers (`planTestScaffold`, `planTestServiceScaffold`,
  `planTestServiceScaffoldWithRuntimePackage`, `checkTestServiceDiagnostics`, lines
  10656–10683) that promote a compatibility index into a checked exact index
  (`syntheticExactSourceIndex`) and call the indexed planners. The test suite migrated
  itself off the legacy path when MasterPlan 34 landed.
- `jitsurei/` and `keiro-test-support/`: zero references.
- External consumers, via `mori registry dependents keiro --packages`: the only
  package-level dependent is `mori://shinzui/mori-app`, whose checkout
  (`/Users/shinzui/Keikaku/bokuno/mori-project/mori-app`) contains no `Keiro.Dsl`
  imports at all (it consumes keiro runtime packages). `mori://shinzui/keiro-syntax` is
  a VimScript/TypeScript syntax-highlighting project with no Haskell code. Every other
  dependent edge is project-level (documentation), not a library dependency. No external
  consumer of the `keiro-dsl` library API exists today.

Relevant ADRs (local; no relevant cross-repository ADR was found):

- `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
  (ADR-16). Establishes that source provenance wraps rather than inhabits the semantic
  graph; that production CLI and workspace routes use the checked
  `ParsedSourceDocument`/exact-index path; that a compatibility adapter from a bare
  `Spec` "never fabricates an exact column"; and — decisive here — that "Bare-`Spec`
  scaffold planning cannot use its compatibility line-only index as exact provenance and
  fails explicitly instead of inventing columns". It also currently states that
  "Compatibility entry points that accept only `Spec` remain documented legacy/version-1
  wrappers"; Milestone 3 amends that statement for the planning/check wrappers this plan
  removes.
- `docs/adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md`
  (ADR-17). Defines behavior ownership and the generated behavior evidence chain,
  including: "One generated context `BehaviorSourceMap` resolves each key to the current
  exact file, line, and column after a complete checked join … Missing, inexact,
  duplicate, or colliding anchors refuse before scaffold writes." Repairing the legacy
  planners to accept inexact anchors would violate this sentence; retiring them upholds
  it.

Parent MasterPlan:
`docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md`.
This plan is its EP-3. The MasterPlan's exit criterion for EP-3 reads "legacy `Spec`-only
entry-point decision executed (retire or repair) with changelog migration notes".

Integration constraints with sibling plans. Plans
`docs/plans/234-bind-catalog-read-models-to-one-explicit-physical-target.md` (EP-2) and
`docs/plans/236-resolve-the-spec-type-graph-once-per-check-and-scaffold-run.md` (EP-4)
also edit `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`. EP-2 owns catalog read-model binding
semantics (including `resolveCatalogReadModel`, lines 307–315, immediately above the
legacy region); EP-4 refactors `resolveTypeGraph` call sites and must keep outputs
byte-identical. This plan therefore confines its `ScaffoldRun.hs` edits to the legacy
entry-point definitions, their export-list lines, their Haddock comments, and the one
import line made partial by the deletions — and must not alter the behavior of the
indexed (`ParsedSourceDocument`) path in any way. The deletions are pure removals, so all
three plans can land in any order with at most trivial textual rebasing.


## Plan of Work

The work is three milestones: delete the entry points (library), retire the test
references while preserving the anti-fabrication guarantee (tests), then document and
distill (changelog, ADR, MasterPlan bookkeeping). Each milestone leaves the repository
building and testable on its own.

### Milestone 1: remove the legacy entry points from ScaffoldRun.hs

Scope: `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` only. At the end of this milestone the
seven names no longer exist anywhere in the library, the module's remaining Haddock prose
is accurate, and `cabal build keiro-dsl` compiles without warnings. Line numbers below
refer to the file as of commit `5db45a42`; re-locate by name if the file has drifted.

Edits, in file order:

1. In the module export list, delete the four `planServiceScaffold*` lines (18–21), the
   `planScaffold` and `planScaffoldWithGoldens` lines (26–27), and the
   `checkServiceDiagnostics` line (48). Leave `planIndexedServiceScaffold*`,
   `checkIndexedServiceDiagnostics`, `planningGatePipeline`,
   `planningRefusalDiagnostics`, `scaffoldModules`, `scaffoldModulesWithGoldens`, and
   every execution/render export untouched — the `-- $shared` seam consumed by
   `Keiro.Dsl.WorkspaceScaffold` must not change.
2. Delete the definitions of `planServiceScaffold`, `planServiceScaffoldWithGoldens`,
   `planServiceScaffoldWithRuntimePackage`, and
   `planServiceScaffoldWithRuntimePackageAndGoldens` together with their Haddock comments
   (lines 324–344). Two pieces of that prose remain true of the indexed path and must
   move rather than vanish: relocate "Run every pure refusal gate under the effective
   semantic contract." onto `planIndexedServiceScaffold`, and relocate the facade comment
   ("Add the one service-level conformance facade only when the runtime package is
   explicitly configured. …") onto `planIndexedServiceScaffoldWithRuntimePackage`, whose
   body is where that behavior actually lives.
3. Delete `checkServiceDiagnostics` and its Haddock (lines 438–456). Move the Haddock
   ("Validate a checked service, then run the shared planning gates unless an error makes
   module generation unsound. `GeneratedOccurrenceCollision` is the deliberate exception
   …") onto `checkIndexedServiceDiagnostics`, dropping any sentence about deriving a
   semantic-only index.
4. Delete `planScaffold` and `planScaffoldWithGoldens` with their Haddock (lines
   568–574). Relocate the still-true sentence "A successful result is the exact write
   set; a refusal has no write set and therefore cannot be accidentally executed." into
   the `planIndexedServiceScaffold` Haddock from step 2.
5. Tighten the import at line 130 from
   `import Keiro.Dsl.SourceIndex (SemanticSourceIndex, compatibilitySemanticSourceIndex)`
   to `import Keiro.Dsl.SourceIndex (SemanticSourceIndex)` — the two deleted bodies were
   this module's only `compatibilitySemanticSourceIndex` uses. Do not touch
   `Keiro.Dsl.SourceIndex` itself: `compatibilitySemanticSourceIndex` stays exported
   there for `Keiro.Dsl.Workspace` (line 724) and the tests. Keep the
   `legacyCheckedService` and `checkedService` imports (line 112): `scaffoldModulesWithGoldens`
   (line 322) and `executeScaffoldWithLanguage` (line 852) still use them. If GHC reports
   any other import made unused by the deletions, trim it in the same edit.

Acceptance: `cabal build keiro-dsl` from the repository root succeeds with no warnings;
`grep -n 'planServiceScaffold\|checkServiceDiagnostics\|planScaffoldWithGoldens\|planScaffold ' keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`
returns no definition or export lines (only, at most, `planIndexedServiceScaffold*`
matches, which contain the substring only if your grep is unanchored — the exact
acceptance grep in Concrete Steps uses word boundaries).

### Milestone 2: retire the test references, keep the anti-fabrication proof

Scope: `keiro-dsl/test/Main.hs` only. At the end of this milestone no test references the
removed names, and the property the deleted negative test protected — line-only
provenance can never surface as exact behavior columns — is still asserted directly.

Edits:

1. In the big `Keiro.Dsl.ScaffoldRun` import at line 73, delete `planServiceScaffold`
   from the import list (it is the only removed name this file imports).
2. In the example "plans one exact context source map and removes line-derived contract
   and witness bytes", replace the trailing guard (lines 3069–3071):

   ```haskell
   case planServiceScaffold ctx service of
     Left refusals -> refusals `shouldSatisfy` any (\case BehaviorSourceRefusal failures -> all ((== BehaviorSource.BehaviorSourceAnchorInexact) . BehaviorSource.failureCode) failures; _ -> False)
     Right _ -> expectationFailure "semantic-only planner fabricated exact behavior columns"
   ```

   with a direct assertion at the join level, using bindings already in scope in that
   example (`service`) and imports already present (`Behavior` qualified at line 30,
   `BehaviorSource` qualified at line 31, `compatibilitySemanticSourceIndex` from the
   `Keiro.Dsl.SourceIndex` import at line 81):

   ```haskell
   compatibility <-
     either (\failure -> expectationFailure (show failure) >> fail "unreachable") pure $
       compatibilitySemanticSourceIndex "<semantic-only>" (checkedSpec service)
   requirements <-
     either (\errors -> expectationFailure (show errors) >> fail "unreachable") pure $
       Behavior.deriveBehaviorRequirements (checkedSpec service)
   case BehaviorSource.planBehaviorSourceMap requirements compatibility of
     Left failures ->
       failures `shouldSatisfy` all ((== BehaviorSource.BehaviorSourceAnchorInexact) . BehaviorSource.failureCode)
     Right _ -> expectationFailure "compatibility line-only provenance fabricated exact behavior columns"
   ```

   This keeps the end-to-end example proving, on the same fixture
   (`test/fixtures/behavior-complete.keiro`), that a compatibility index refuses with
   exactly the inexact-anchor code. The sibling example just above (lines 3026–3032)
   already asserts the same codes over compatibility and empty indices, so if the
   replacement ever feels redundant during implementation, prefer keeping both: one
   asserts the failure code taxonomy in isolation, the other inside the exact-source-map
   scenario. Note the stronger post-retirement guarantee for the retired surface itself:
   no exported planner accepts a service without a `SemanticSourceIndex`, so the
   "semantic-only planner" the old guard exercised is now unrepresentable.
3. Leave every `scaffoldModules` call site and all `planTestScaffold`-family helpers
   untouched — they are on the surviving, working surfaces.

Acceptance: `cabal test keiro-dsl-test` passes; then `cabal test keiro-dsl:tests` passes
(note the `:tests` suffix — a bare `cabal test keiro-dsl` resolves to a single component
and silently skips the other declared suites, a known trap recorded in the `justfile`
comment at lines 67–72).

### Milestone 3: changelog, ADR amendment, and MasterPlan bookkeeping

Scope: documentation that makes the removal survivable for consumers and durable for the
project. At the end of this milestone a 0.11.0.0 library consumer reading the changelog
knows exactly what changed and how to migrate, and the project's ADR record no longer
promises Spec-only planning wrappers that do not exist.

Edits:

1. `keiro-dsl/CHANGELOG.md`, under `## Unreleased` → `### Breaking Changes`, append this
   bullet (verbatim; adjust only if surrounding bullets have changed):

   ```markdown
   - Removes the semantic-only planning and check entry points from
     `Keiro.Dsl.ScaffoldRun`: `planServiceScaffold`, `planServiceScaffoldWithGoldens`,
     `planServiceScaffoldWithRuntimePackage`,
     `planServiceScaffoldWithRuntimePackageAndGoldens`, `planScaffold`,
     `planScaffoldWithGoldens`, and `checkServiceDiagnostics`. Once behavior provenance
     became part of planning, these wrappers could only derive a `CompatibilityLineOnly`
     source index, whose behavior-source join refuses every aggregate transition and
     rejection anchor — so they refused every transition-bearing service that they
     planned cleanly under 0.11.0.0. Migrate by parsing with `parseSourceDocument` and
     passing the document's `documentSourceIndex` to `planIndexedServiceScaffold`,
     `planIndexedServiceScaffoldWithGoldens`,
     `planIndexedServiceScaffoldWithRuntimePackage`,
     `planIndexedServiceScaffoldWithRuntimePackageAndGoldens`, or
     `checkIndexedServiceDiagnostics`. A `Spec` constructed programmatically can still
     be planned by building a complete exact index with
     `Keiro.Dsl.SourceIndex.exactSemanticSourceIndex` over `semanticSourceSubjects`,
     taking responsibility for the spans it asserts. The Spec-only module-set builders
     (`scaffoldModules`, `scaffoldModulesWithGoldens`) and every execution entry point
     are unchanged.
   ```

2. `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`:
   amend the Decision-section sentence "Compatibility entry points that accept only
   `Spec` remain documented legacy/version-1 wrappers and are not used by CLI or
   workspace semantic routes" and the related bare-`Spec` planning sentence to record
   that, as of 0.12.0.0, the Spec-only scaffold-planning and check wrappers are removed
   and planning is indexed-only; Spec-only compatibility bridges survive exactly where
   they make no provenance claim (`parseSource`, `parseSpec`, `parseSpecText`,
   `validateSpec`, `scaffoldModules`, workspace member adapters). Honor the repository's
   ADR convention when editing (this bundle is validated by `just adr-validate`); keep
   the amendment short and dated rather than rewriting history.
3. `docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md`:
   set the EP-3 registry row Status to Complete and tick the EP-3 progress line
   ("legacy `Spec`-only entry-point decision executed (retire or repair) with changelog
   migration notes"), noting the decision was RETIRE.
4. Update this plan's living sections (Progress, Surprises & Discoveries if any,
   Outcomes & Retrospective) and perform the ADR distillation pass — for this plan the
   distillation *is* edit 2, unless implementation surfaced something more.

Acceptance: `just adr-validate` passes after edit 2; `just verify` passes end to end.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

First, re-verify the caller inventory is still empty before deleting anything (protects
against a caller added since this plan was written):

```bash
grep -rn --include='*.hs' -E '\b(planServiceScaffold|planServiceScaffoldWithGoldens|planServiceScaffoldWithRuntimePackage|planServiceScaffoldWithRuntimePackageAndGoldens|planScaffold|planScaffoldWithGoldens|checkServiceDiagnostics)\b' \
  keiro-dsl jitsurei keiro-test-support
```

Expected: hits only in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` (exports and
definitions) and `keiro-dsl/test/Main.hs` (line 73 import, line 3069 call). Any other
hit is a new caller: stop, migrate that caller to the indexed path first (as
`keiro-dsl/test/Main.hs` lines 10656–10683 demonstrate), record it in Surprises &
Discoveries, and only then proceed.

Milestone 1 (edit `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` per the Plan of Work, then):

```bash
cabal build keiro-dsl
```

Expected: `Compiling ... Keiro.Dsl.ScaffoldRun` and every downstream module, ending in a
successful build with no warnings. An error like
`Variable not in scope: planServiceScaffold` means a caller was missed — return to the
grep above.

Milestone 2 (edit `keiro-dsl/test/Main.hs` per the Plan of Work, then):

```bash
cabal test keiro-dsl-test
cabal test keiro-dsl:tests
```

Expected: the unit suite first (fast feedback), then every declared `keiro-dsl` suite,
all ending

```text
Test suite keiro-dsl-test: PASS
```

(and correspondingly `PASS` for each conformance suite under the `:tests` invocation).
The edited example "plans one exact context source map and removes line-derived contract
and witness bytes" must be listed as passing.

Confirm no live reference to the removed names remains anywhere in Haskell sources
(historical mentions under `docs/plans/` and `docs/masterplans/` are expected and
correct — they are records, not code):

```bash
grep -rn --include='*.hs' -E '\b(planServiceScaffold|planServiceScaffoldWithGoldens|planServiceScaffoldWithRuntimePackage|planServiceScaffoldWithRuntimePackageAndGoldens|planScaffold|planScaffoldWithGoldens|checkServiceDiagnostics)\b' \
  keiro-dsl jitsurei keiro-test-support; echo "exit: $?"
```

Expected output: no matches, `exit: 1`.

Milestone 3 (edit `keiro-dsl/CHANGELOG.md`, ADR-0016, and MasterPlan 36 per the Plan of
Work, then):

```bash
just adr-validate
just verify
```

Expected: both succeed. `just verify` runs the process-compose check, jitsurei, the full
Haskell build and test set, ADR/research/capabilities validation, the extension and
generated-name policies, and the conformance-corpus policy; it is the repository's
definition of done. This plan changes no generated output and no grammar, so the
conformance corpus must not change — if `conformance-corpus-policy` reports drift,
something outside this plan's scope was touched; revert and re-check.

Commit per repository convention (Conventional Commits), for example one commit per
milestone:

```text
refactor(dsl)!: retire the Spec-only scaffold planning and check entry points

test(dsl): assert line-only provenance refusal at the source-map join

docs(dsl): document the 0.12 removal of Spec-only planners with migration notes
```


## Validation and Acceptance

Acceptance is behavioral, matching the RETIRE decision:

1. The package builds with the exports gone. `cabal build keiro-dsl` succeeds, and
   compiling a scratch module that imports any of the seven removed names from
   `Keiro.Dsl.ScaffoldRun` fails with an out-of-scope/export error. (No scratch file
   needs committing; the word-boundary grep in Concrete Steps returning nothing plus a
   clean build is the recorded evidence.)
2. No test references the removed names, and the suite still proves the property the old
   negative test protected: in `keiro-dsl/test/Main.hs`, the example "plans one exact
   context source map and removes line-derived contract and witness bytes" (a) plans the
   `behavior-complete.keiro` fixture successfully through `planIndexedServiceScaffold`
   with the parsed document's exact index, and (b) shows that the same service joined
   against a `compatibilitySemanticSourceIndex` refuses with failures that are all
   `BehaviorSourceAnchorInexact`. `cabal test keiro-dsl-test` and
   `cabal test keiro-dsl:tests` pass.
3. The changelog documents the removal and migration. `keiro-dsl/CHANGELOG.md`'s
   Unreleased Breaking Changes section names all seven removed exports, explains why they
   could no longer succeed, and gives both migration recipes (parse via
   `parseSourceDocument`; or build an exact index with `exactSemanticSourceIndex` for
   programmatic specs).
4. The indexed path's behavior is untouched: no change under `keiro-dsl/src` other than
   `ScaffoldRun.hs`, no change to `planIndexedServiceScaffoldWithRuntimePackageAndGoldens`'s
   body or to `planningGatePipeline`, and the conformance corpus is byte-identical
   (`just verify`'s `conformance-corpus-policy` gate is the check).
5. `just verify` passes from the repository root.


## Idempotence and Recovery

Every step is a pure text edit plus a build or test run; all commands can be re-run any
number of times. The deletions are independent per milestone: if Milestone 1 lands and
Milestone 2 has not, the build fails loudly at the test component (an out-of-scope
`planServiceScaffold` in `test/Main.hs`), which is safe — nothing is written to disk by
any of these code paths at build or test time beyond normal test scratch directories.

To abandon or restart cleanly at any point before committing:

```bash
git checkout -- keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs keiro-dsl/test/Main.hs keiro-dsl/CHANGELOG.md docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md
```

If a milestone was committed and must be unwound, revert the milestone commit
(`git revert <sha>`); the milestones were designed to be revertible independently in
reverse order. There is no migration, no generated-output change, and no destructive
operation anywhere in this plan.


## Interfaces and Dependencies

No new libraries, packages, or modules. The plan only narrows the export surface of one
exposed module and edits tests and documentation.

The surviving planning and check surface of `Keiro.Dsl.ScaffoldRun`
(`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`), which this plan must leave signature- and
behavior-identical:

```haskell
planIndexedServiceScaffold :: SemanticSourceIndex -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planIndexedServiceScaffoldWithGoldens :: [GoldenPayload] -> SemanticSourceIndex -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planIndexedServiceScaffoldWithRuntimePackage :: Maybe RuntimePackageName -> SemanticSourceIndex -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
planIndexedServiceScaffoldWithRuntimePackageAndGoldens :: [GoldenPayload] -> Maybe RuntimePackageName -> SemanticSourceIndex -> Context -> CheckedService -> Either [Refusal] [ScaffoldModule]
checkIndexedServiceDiagnostics :: Maybe RuntimePackageName -> SemanticSourceIndex -> Context -> CheckedService -> [Diagnostic]
```

together with the Spec-only non-planning bridges that stay
(`scaffoldModules :: Context -> Spec -> [ScaffoldModule]`,
`scaffoldModulesWithGoldens :: [GoldenPayload] -> Context -> Spec -> [ScaffoldModule]`),
the whole-workspace seam (`planningGatePipeline`, `planningRefusalDiagnostics`,
`pureRefusals`, and the rest of the `-- $shared` export group), and every
`executeScaffold*`/`executeServiceScaffold*` entry point.

The provenance suppliers callers migrate to, in `Keiro.Dsl.Parser`
(`keiro-dsl/src/Keiro/Dsl/Parser.hs`) and `Keiro.Dsl.SourceIndex`
(`keiro-dsl/src/Keiro/Dsl/SourceIndex.hs`):

```haskell
parseSourceDocument :: FilePath -> Text -> Either ParseFailure ParsedSourceDocument
exactSemanticSourceIndex :: FilePath -> [SourceSubject] -> [(SourceSubject, SourceSpan)] -> Either SourceIndexFailure SemanticSourceIndex
semanticSourceSubjects :: Spec -> [SourceSubject]
compatibilitySemanticSourceIndex :: FilePath -> Spec -> Either SourceIndexFailure SemanticSourceIndex
```

None of their signatures change. After each milestone the interface obligation is simply:
Milestone 1 — the five surviving planner/check signatures above exist and the seven
retired names do not; Milestone 2 — the test component compiles against exactly that
surface; Milestone 3 — no code interface changes at all.

---

Revision note (2026-08-11): fleshed out from the init-script skeleton into the full
ExecPlan. Research established that the RETIRE branch of the title's "retire or repair"
question is correct — no live caller exists in this repository or any registered
dependent, and both ADR-16 and ADR-17 mandate the refusal behavior that makes the legacy
entry points unusable — so the plan commits to retirement and seeds the Decision Log with
the evidence.
