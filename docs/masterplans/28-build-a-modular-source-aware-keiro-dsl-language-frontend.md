---
id: 28
slug: build-a-modular-source-aware-keiro-dsl-language-frontend
title: "Build a modular, source-aware Keiro DSL language frontend"
kind: master-plan
created_at: 2026-08-01T19:49:00Z
intention: "intention_01kyzdr07ge299bk2axrgwssht"
---

# Build a modular, source-aware Keiro DSL language frontend

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

After this initiative, `keiro-dsl` has a recognizable language frontend rather than one
large parser module that constructs the normalized service graph directly. A source is
parsed by Megaparsec into a located surface representation, lowered explicitly into the
existing semantic `Keiro.Dsl.Grammar.Spec`, and then checked under the selected released
language contract. Exact source spans, grammar ownership, version capabilities, lowering,
and compatibility rendering have named modules and tests. Before those types are introduced,
the package's production records are brought into conformance with the record-patterns guide:
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`
Semantic field names replace datatype prefixes, fields are strict, derivations are explicit, and
Keiki's overloaded labels remain isolated from generic-lens's orphan instance. `Keiro.Dsl.Parser` remains the small
compatibility facade used by existing library callers, the CLI, and workspace loading.

The observable language remains the Keiro DSL 0.7.0.0 language. Legacy-unversioned, language
version 1, version 2, and version 3 sources retain their accepted syntax, rejected syntax,
semantic `Spec`, canonical pretty output, diagnostics, generated Haskell bytes, workspace
composition, diff classification, and replay behavior. New advanced library entry points expose
located surface syntax and structured frontend diagnostics without forcing ordinary callers to
understand Megaparsec. The complete 0.7 fixture and conformance corpus becomes an executable
compatibility oracle for later language-version work.

Implementation begins only after the `keiro-dsl-0.7.0.0` release tag and published package are
complete. EP-172 records that released baseline before production parser code changes. No new DSL
construct, language version, runtime semantic, generated module, or compatibility classification
may land under this MasterPlan.

Only the original DSL has downstream adopters at the start of this initiative. Language versions 2
and 3 are already released contracts and remain fully regression-tested, but there is no v2/v3
fleet requiring migration tooling. This is the narrow window to make the Haskell selector cleanup
and advanced frontend API coherent before those dialects are adopted. The selector rename is an
intentional PVP-breaking change for the release after 0.7.0.0; it does not change DSL behavior.

In scope are `keiro-dsl/src/Keiro/Dsl/Parser.hs`, `Grammar.hs`, `LanguageVersion.hs`,
`SemanticContract.hs`, `PrettyPrint.hs`, `Validate.hs`, `Workspace.hs`, the CLI read paths,
the remaining production records under `keiro-dsl/src` and `keiro-dsl/app`, `keiro-dsl/test/`, the
`keiro-dsl` Cabal module lists, the authoring notation, user documentation, and the ADRs that own
the language boundary. Generated domain records are compatibility outputs, not rename targets.
The Megaparsec dependency remains:
`mori://mrkkrp/megaparsec/packages/megaparsec`
This initiative does not change its bounds.

Out of scope are a lossless concrete syntax tree that preserves comments and whitespace, a source
formatter distinct from the existing canonical pretty-printer, editor/LSP integration,
incremental parsing, syntax recovery after multiple errors, language version 4, and the
version-aware rewrite and fleet tooling requested by
[IR-5](../improvement-requests/add-version-aware-keiro-dsl-upgrade-and-fleet-rewrite-tooling.md).
The surface representation records exact spans but deliberately does not retain trivia. If IR-5
later proves that lossless edits are required, it may add a concrete syntax layer above this
frontend rather than changing `Spec` into a source-preservation type.


## Decomposition Strategy

The initiative is decomposed into six behaviorally verifiable work streams. EP-172 freezes the
released 0.7 input/output contract before any production refactor, providing the oracle every
later plan must satisfy. EP-177 then modernizes existing production records and field access so
later frontend records do not extend the prefixed-selector convention. EP-173 introduces source
points, source spans, a surface source type, and an explicit lowering seam while preserving `Spec`
as the normalized graph. EP-174 then extracts the grammar by language concern behind the stable
facade. EP-175 replaces implicit numeric
feature inheritance and rendered-only parser failures with explicit per-release profiles and
structured span-aware frontend diagnostics. EP-176 performs the consumer audit, removes the old
direct path, proves end-to-end parity, updates documentation and ADRs, and supplies the final
release-quality validation.

The ordering is intentional. Without EP-172, a large internal rewrite could silently bless its
own changed behavior. Completing the record conversion before introducing the surface layer avoids
constructing a new public API in a convention already scheduled for removal. Building the
surface/lowering seam before splitting modules gives every extracted parser a stable result type.
Extracting modules before changing the release registry
keeps semantic policy edits out of the mechanical move. The final cutover waits until both the
grammar and contract surfaces are stable, so the CLI, workspaces, pretty printer, checker,
scaffolder, diff, and replay paths are reconciled once.

[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires each
failure to occur at the first boundary with enough evidence and gives stable diagnostic codes to
machine consumers. [ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires separately parsed members to merge into one semantic authority.
[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) is the central
constraint: source provenance wraps the normalized `Spec`, version selection precedes body
parsing, and released grammars stay frozen. [ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
is relevant because versioned surface syntax must continue lowering ownership into exactly one
semantic authority. EP-173 must amend ADR 16, or add a successor ADR if clearer, to record the
surface-to-semantic frontend boundary. EP-175 must update ADR 4 and ADR 16 if the structured
diagnostic or explicit-profile design changes their durable wording.

A wholesale parser rewrite was rejected. The current Megaparsec productions already encode the
right grammar; they should be moved behind stronger boundaries with the 0.7 oracle continuously
green. Parameterizing every semantic AST type by a location annotation was rejected because it
would force locations through all scaffold, diff, fingerprint, and replay consumers. The located
surface tree instead lowers into the unchanged semantic graph and projects each span's starting
line into the existing `Loc` compatibility field. A lossless tree was rejected for this initiative
because canonical rendering, not edit preservation, is the existing contract and IR-5 owns source
rewrites.

Keeping prefixed selectors as deprecated aliases was rejected. The package has not yet acquired
v2/v3 adopters, aliases would preserve two vocabularies throughout a public graph, and common target
names would make aliases increasingly collision-prone. EP-177 instead supplies a complete selector
migration table for the next PVP-breaking release while the 0.7 oracle protects every non-selector
contract.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 172 | Freeze the Keiro DSL 0.7 language frontend contract | docs/plans/172-freeze-the-keiro-dsl-0-7-language-frontend-contract.md | None | None | Not Started |
| 177 | Modernize keiro-dsl records and field access | docs/plans/177-modernize-keiro-dsl-records-and-field-access.md | EP-172 | None | Not Started |
| 173 | Introduce located Keiro surface syntax and explicit lowering | docs/plans/173-introduce-located-keiro-surface-syntax-and-explicit-lowering.md | EP-177 | None | Not Started |
| 174 | Modularize the Keiro Megaparsec grammar by language concern | docs/plans/174-modularize-the-keiro-megaparsec-grammar-by-language-concern.md | EP-173 | None | Not Started |
| 175 | Make released Keiro syntax profiles and frontend diagnostics explicit | docs/plans/175-make-released-keiro-syntax-profiles-and-frontend-diagnostics-explicit.md | EP-174 | EP-177 | Not Started |
| 176 | Cut over the Keiro toolchain to the language frontend and certify parity | docs/plans/176-cut-over-the-keiro-toolchain-to-the-language-frontend-and-certify-parity.md | EP-175 | EP-172, EP-177, EP-173, EP-174 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-172 starts only after the 0.7.0.0 release is complete. It has no child-plan dependency and
produces the compatibility manifest, curated diagnostic goldens, public-API compile probe, and
corpus-wide parity harness used by every later plan.

EP-177 hard-depends on EP-172 because it intentionally changes public Haskell field selectors while
requiring all language, serialization, rendered, generated, and runtime behavior to stay pinned.
It defines the unprefixed field vocabulary, migration manifest, strictness/deriving baseline, and
the Keiki-label isolation guard consumed by all later plans.

EP-173 hard-depends on EP-177 because it changes the parser result path and introduces new public
records. It defines `SourcePoint`, `SourceSpan`, the located surface-source boundary, the lowering
result, and the
projection back to the existing `Loc`/`Spec` representation. EP-174 hard-depends on those types:
each extracted grammar module must construct the same surface representation rather than inventing
a module-local AST.

EP-175 hard-depends on EP-174 because it replaces the version-dispatch and error plumbing used by
all productions. Performing that work before extraction would cause every mechanical move to
carry policy changes and make parity failures hard to attribute. Its soft dependency on EP-173
records that the span model is the diagnostic substrate, although the hard path already includes
it transitively.

EP-176 hard-depends on EP-175 because it removes the legacy direct parser and routes every
consumer through the final frontend interfaces. It then runs the complete compatibility and
conformance matrix. The critical path is therefore EP-172 -> EP-177 -> EP-173 -> EP-174 -> EP-175
-> EP-176. This serialization is deliberate: all plans touch the parser boundary, and the dominant
risk is
an undetected language change rather than contributor throughput. Documentation audits and test
inventory work from EP-176 may be prepared earlier, but production cutover cannot.


## Integration Points

1. **The 0.7 compatibility oracle (EP-172 defines; all later plans consume).** The oracle
   owns the fixture inventory, acceptance/rejection classification, exact curated diagnostics,
   canonical render expectations, public API probe, and generated-byte checks. Later plans may add
   cases but may not rewrite an expectation merely to accommodate the refactor. EP-177's manifest
   is the sole authorized exception for Haskell record selectors; any other intentional difference
   is out of scope and must be proposed as a successor language change.

2. **Production record conventions (EP-177 defines; EP-173 through EP-176 consume).** Product
   records use strict, unprefixed semantic labels with explicit deriving strategies and `Generic`;
   `unTypeName` remains valid for newtypes. JSON keys, rendered output, and generated source never
   derive accidentally from selector spelling. `Data.Generics.Labels` is excluded from preludes,
   definition modules, and Keiki-facing import closures. EP-177 owns the complete selector
   migration table and downstream compile probes.

3. **`SourcePoint`, `SourceSpan`, and compatibility `Loc` (EP-173 defines; EP-174, EP-175, and
   EP-176 consume).** `SourceSpan` carries source name, start/end offsets, and one-based start/end
   line and column. It has ordinary structural equality. Lowering projects its start line into
   `Grammar.Loc`; `Loc` retains its historical equality behavior so semantic round trips and
   fingerprints remain location-insensitive. EP-175 owns structured frontend diagnostic use of
   spans. EP-176 maps spans through workspace member attribution without relocating them into the
   merged graph.

4. **Surface syntax and lowering (EP-173 defines; all later plans consume).**
   `Keiro.Dsl.Syntax.SurfaceSource` represents one parsed document and
   `Keiro.Dsl.Frontend.lowerSurfaceSource` produces the existing `ParsedSource`. The surface layer
   retains syntax distinctions and exact spans needed for version gates and errors but not
   comments or whitespace. `Grammar.Spec` remains the semantic interchange used by validation,
   composition, generation, diff, and replay. This boundary is durable ADR material.

5. **The parser module graph (EP-174 defines; EP-175 and EP-176 extend).**
   `Keiro.Dsl.Parser` owns only stable public wrappers and rendering. Internal modules own lexer,
   preamble/document composition, declarations, mapped/nominal types, expressions, aggregates,
   coordination nodes, integration nodes, queue/read-model nodes, and workflow/operation nodes.
   Grammar modules may import `Parser.Core` and `Syntax`; they must not import the facade or each
   other in cycles.

6. **The released-language registry (EP-175 defines; EP-176 audits).** Each `LanguageDefinition`
   explicitly names its syntax profile and runtime-semantics discriminator. Version 3 may reuse
   the version-2 syntax profile by an explicit value, but adding a future registry entry never
   inherits features merely because its number is greater. `SemanticContract` consumes the same
   registry rather than maintaining a numeric threshold.

7. **Frontend diagnostics (EP-175 defines; EP-176 integrates).** The advanced frontend API returns
   structured phase, code, span, and message data. Existing `parseSource`, `parseSpec`, and
   `parseSpecText` retain their 0.7 signatures and compatibility rendering. CLI output remains
   pinned by EP-172. Semantic validator `Diagnostic` remains downstream of lowering; widening it
   to carry spans is not required unless EP-175 can do so without changing the compatibility
   renderer or semantic consumers.

8. **Consumer routing and documentation (EP-176 owns).** `app/Main.hs`, `Workspace.hs`,
   `PrettyPrint.hs`, scaffold/diff/replay entry points, `docs/user/typed-spec-toolchain.md`,
   `agents/skills/keiro-dsl-authoring/NOTATION.md`, and `keiro-dsl/CHANGELOG.md` must describe and
   consume the same frontend. EP-176 also owns final ADR distillation and strict OKF validation.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-172: verify the published/tagged 0.7.0.0 baseline and inventory every source-consuming path.
- [ ] EP-172: land the compatibility oracle, curated goldens, and public API compile probe.
- [ ] EP-177: inventory every production record and publish the 0.7-to-next-major selector map.
- [ ] EP-177: modernize records and field access while preserving wire/output and Keiki-label behavior.
- [ ] EP-173: define exact source spans and a non-lossless located surface representation.
- [ ] EP-173: route parsing through explicit surface lowering while preserving all 0.7 behavior.
- [ ] EP-174: extract lexer, document, declaration, expression, and node-family grammar modules.
- [ ] EP-174: reduce `Keiro.Dsl.Parser` to the compatibility facade with the oracle green.
- [ ] EP-175: make every released syntax/runtime profile explicit in one registry.
- [ ] EP-175: expose structured span-aware frontend failures with compatibility rendering.
- [ ] EP-176: route CLI, workspace, pretty, check, scaffold, diff, and replay paths through the frontend.
- [ ] EP-176: remove the direct path, refresh docs/ADRs, and pass full release-quality validation.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Observation: Only the original DSL has downstream users; language versions 2 and 3 are not used
  anywhere yet.
  Evidence: Maintainer report on 2026-08-01.
  Impact: Preserve v2/v3 as released test contracts, but perform the public record/API cleanup now
  without building fleet migration machinery for nonexistent v2/v3 adopters.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Begin implementation only after the Keiro 0.7.0.0 release and tag are complete, and
  make EP-172 the next DSL work before any new grammar feature.
  Rationale: The released tree is the neutral behavioral oracle. Mixing a release repair, a new
  feature, and a frontend refactor would make regressions impossible to classify confidently.
  Date: 2026-08-01

- Decision: Retain Megaparsec and refactor the current grammar rather than replacing the parser
  library or rewriting productions from scratch.
  Rationale: The current failures arose from missing language boundaries and raw textual scans,
  not from Megaparsec. Its offsets, source positions, custom errors, regions, and expression
  combinators already support the required frontend.
  Date: 2026-08-01

- Decision: Add a located, non-lossless surface representation that lowers into the existing
  semantic `Spec` instead of parameterizing `Spec` by locations or putting source trivia on it.
  Rationale: ADR 16 and workspace composition require `Spec` to remain a normalized graph.
  A separate surface layer gives diagnostics and future language tooling exact evidence without
  contaminating fingerprints, diffs, replay, or generated output.
  Date: 2026-08-01

- Decision: Preserve the signatures and 0.7 behavior of `parseSource`, `parseSpec`, and
  `parseSpecText`, while allowing a new advanced frontend module and cleanup of parser-configuration
  types that should not have been public policy.
  Rationale: Ordinary adopters need a stable entry point; pre-adoption is still the right time to
  introduce a principled advanced API and stop exporting accidental internals.
  Date: 2026-08-01

- Decision: Represent released syntax capabilities and runtime semantics explicitly per registry
  entry; do not infer inheritance from numeric ordering.
  Rationale: A frozen language version is a declared contract. Adding a higher version must not
  silently widen it or any future version without an explicit profile choice.
  Date: 2026-08-01

- Decision: Exclude lossless formatting and upgrade/rewrite tooling from this MasterPlan.
  Rationale: Exact spans and explicit lowering are prerequisites for those capabilities, but trivia
  retention, atomic rewrites, and fleet coordination are separately valuable behavior already
  requested by IR-5.
  Date: 2026-08-01

- Decision: Put a package-wide production-record modernization in EP-177 between the 0.7 oracle
  and every newly introduced frontend record.
  Rationale: Existing prefixes are not the desired record convention, and introducing
  `sourceOffset`, `locatedValue`, or `definitionVersion` would deepen the cleanup. Doing the
  breaking selector change immediately after 0.7 and before v2/v3 adoption minimizes migration
  cost while the oracle protects language behavior.
  Date: 2026-08-01

- Decision: Apply `mori://shinzui/haskell-jitsurei/docs/core-record-patterns` without exposing
  generic-lens's orphan labels to Keiki-facing import closures.
  Rationale: The record guide requires unprefixed strict Generic records and explicitly warns that
  transitive `Data.Generics.Labels` imports conflict with Keiki labels. Pattern construction and
  puns are the safe default wherever isolation cannot be proven.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
