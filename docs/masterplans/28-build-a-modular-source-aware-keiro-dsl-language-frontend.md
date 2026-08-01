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
and compatibility rendering have named modules and tests. New frontend records use strict semantic
field names and explicit derivations without requiring a
package-wide record migration. Existing production records and their released selectors remain
unchanged. `Keiro.Dsl.Parser` remains the small compatibility facade used by existing library
callers, the CLI, and workspace loading.

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

In scope are `keiro-dsl/src/Keiro/Dsl/Parser.hs`, `Grammar.hs`, `LanguageVersion.hs`,
`SemanticContract.hs`, `PrettyPrint.hs`, `Validate.hs`, `Workspace.hs`, the CLI read paths,
`keiro-dsl/test/`, the `keiro-dsl` Cabal module lists, the authoring notation, user documentation,
and the ADRs that own the language boundary. Existing production-record selectors and a
package-wide strictness/deriving cleanup are explicitly out of scope; EP-177 was cancelled to keep
this initiative focused on the language frontend.
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

The initiative is decomposed into five active behaviorally verifiable work streams, plus EP-177 as
a cancelled record of the deliberately removed package-wide cleanup. EP-172 freezes the released
0.7 input/output contract before any production refactor, providing the oracle every later plan
must satisfy. EP-173 introduces source
points, source spans, a surface source type, and an explicit lowering seam while preserving `Spec`
as the normalized graph. EP-174 then extracts the grammar by language concern behind the stable
facade. EP-175 replaces implicit numeric
feature inheritance and rendered-only parser failures with explicit per-release profiles and
structured span-aware frontend diagnostics. EP-176 performs the consumer audit, removes the old
direct path, proves end-to-end parity, updates documentation and ADRs, and supplies the final
release-quality validation.

The ordering is intentional. Without EP-172, a large internal rewrite could silently bless its
own changed behavior. Building the
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

The package-wide record modernization was removed from this initiative before implementation. New
frontend-owned records still use concise semantic fields, strictness, explicit deriving strategies,
and `Generic` where appropriate, but this local convention does not authorize renaming released
selectors or sweeping unrelated modules. A future independently justified plan may revisit that
cleanup without coupling it to the parser architecture.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 172 | Freeze the Keiro DSL 0.7 language frontend contract | docs/plans/172-freeze-the-keiro-dsl-0-7-language-frontend-contract.md | None | None | Complete |
| 177 | Modernize keiro-dsl records and field access | docs/plans/177-modernize-keiro-dsl-records-and-field-access.md | EP-172 | None | Cancelled |
| 173 | Introduce located Keiro surface syntax and explicit lowering | docs/plans/173-introduce-located-keiro-surface-syntax-and-explicit-lowering.md | EP-172 | None | Complete |
| 174 | Modularize the Keiro Megaparsec grammar by language concern | docs/plans/174-modularize-the-keiro-megaparsec-grammar-by-language-concern.md | EP-173 | None | Complete |
| 175 | Make released Keiro syntax profiles and frontend diagnostics explicit | docs/plans/175-make-released-keiro-syntax-profiles-and-frontend-diagnostics-explicit.md | EP-174 | None | Complete |
| 176 | Cut over the Keiro toolchain to the language frontend and certify parity | docs/plans/176-cut-over-the-keiro-toolchain-to-the-language-frontend-and-certify-parity.md | EP-175 | EP-172, EP-173, EP-174 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-172 starts only after the 0.7.0.0 release is complete. It has no child-plan dependency and
produces the compatibility manifest, curated diagnostic goldens, public-API compile probe, and
corpus-wide parity harness used by every later plan.

EP-177 is cancelled. Its package-wide selector migration, strictness sweep, and deriving cleanup are
not prerequisites for the frontend and are not part of this initiative.

EP-173 hard-depends directly on EP-172 because it changes the parser result path and introduces new
public records while preserving the frozen contract. It defines `SourcePoint`, `SourceSpan`, the
located surface-source boundary, the lowering result, and the
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
conformance matrix. The critical path is therefore EP-172 -> EP-173 -> EP-174 -> EP-175 -> EP-176.
This serialization is deliberate: all plans touch the parser boundary, and the dominant
risk is
an undetected language change rather than contributor throughput. Documentation audits and test
inventory work from EP-176 may be prepared earlier, but production cutover cannot.


## Integration Points

1. **The 0.7 compatibility oracle (EP-172 defines; all later plans consume).** The oracle
   owns the fixture inventory, acceptance/rejection classification, exact curated diagnostics,
   canonical render expectations, public API probe, and generated-byte checks. Later plans may add
   cases but may not rewrite an expectation merely to accommodate the refactor. Any intentional
   difference is out of scope and must be proposed as a successor language change.

2. **Frontend-local record conventions (EP-173 defines; EP-174 through EP-176 consume).** New
   frontend product records use strict semantic labels with explicit deriving strategies and
   `Generic` where appropriate. Existing record fields are left intact. JSON keys, rendered output,
   and generated source must never drift because of a new internal representation.

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

- [x] EP-172: verified the published/tagged 0.7.0.0 baseline and inventoried every source-consuming path (2026-08-01T20:48:58Z).
- [x] EP-172: landed the compatibility oracle, curated goldens, and public API compile probe (2026-08-01T20:55:00Z).
- [x] EP-177: cancelled the package-wide record modernization to focus the initiative on the
  source-aware frontend (2026-08-01).
- [x] EP-173: defined exact source spans and a non-lossless located surface representation
  (2026-08-01T21:35:07Z).
- [x] EP-173: routed parsing through explicit surface lowering while preserving all 0.7 behavior
  (2026-08-01T21:35:07Z).
- [x] EP-174: extracted lexer, document, declaration, expression, and node-family grammar modules
  (2026-08-01T21:58:28Z).
- [x] EP-174: reduced `Keiro.Dsl.Parser` to the compatibility facade with the oracle green
  (2026-08-01T21:58:28Z).
- [x] EP-175: made every released syntax/runtime profile explicit in one registry
  (2026-08-01T22:21:24Z).
- [x] EP-175: exposed structured span-aware frontend failures with compatibility rendering
  (2026-08-01T22:21:24Z).
- [x] EP-176: routed CLI and workspace source loading through the frontend and proved pretty, check,
  scaffold, diff, fingerprint, and replay consumers remain semantic-only (2026-08-01T22:33:43Z).
- [x] EP-176: removed the transitional advanced re-export, refreshed documentation, and passed
  full release-quality validation (2026-08-01T22:33:43Z).


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Observation: Only the original DSL has downstream users; language versions 2 and 3 are not used
  anywhere yet.
  Evidence: Maintainer report on 2026-08-01.
  Impact: Preserve v2/v3 as released test contracts without building fleet migration machinery for
  nonexistent v2/v3 adopters.

- Observation: The 0.7 compatibility renderer reports version 3, rather than the registry minimum
  version 2, in every `LanguageFeatureRequiresVersion` message.
  Evidence: EP-172's four feature-gate goldens reproduce the released bytes while
  `languageFeatureMinimumVersion` returns version 2.
  Impact: EP-175 must distinguish corrected structured metadata from the pinned legacy renderer so
  diagnostic modernization does not accidentally change CLI compatibility output.

- Observation: EP-177 is substantially larger than the source-aware frontend and is not a
  technical prerequisite for EP-173 through EP-176.
  Evidence: Its proposed scope spans every production record, public selector, serialization
  boundary, and Keiki-facing import closure, while the remaining plans need only a convention for
  the small set of new frontend-owned records.
  Impact: EP-177 is cancelled, EP-173 now depends directly on EP-172, and existing record APIs stay
  pinned by the compatibility oracle.

- Observation: The released lexeme design consumes trailing trivia, but exact owned spans can be
  added without changing that lexer contract.
  Evidence: EP-173's `withOwnedSpan` computes the final owned token from the consumed `Text` slice;
  Unicode, trailing-comment, multi-line declaration, nested-field, and expression tests pass while
  the six-example EP-172 compatibility group remains green.
  Impact: EP-174 can mechanically extract parser modules without first changing whitespace or
  diagnostic behavior.

- Observation: The source grammar can be isolated behind an acyclic concern graph without changing
  any released behavior, while the workspace manifest remains a separate Megaparsec grammar.
  Evidence: EP-174 reduced the public facade to 43 lines, added twelve internal modules and three
  import-boundary tests, and passed all 454 examples, `cabal build all`, and `nix flake check`.
  Impact: EP-175 can change syntax-profile and diagnostic policy in named core/preamble/document
  owners instead of editing one monolithic parser.

- Observation: Structured profile metadata can correct the meaning of supported versions without
  changing the frozen compatibility renderer.
  Evidence: EP-175 reports feature support as versions 2 and 3 from exact profile membership, while
  its compatibility projection retains the historical text naming version 3; all 13 goldens pass.
  Impact: New tooling consumes phase/code/span/profile data, while existing CLI and library callers
  retain byte-identical diagnostics.

- Observation: The final consumer inventory found one `.keiro` document route and one intentionally
  separate workspace-manifest grammar; downstream planning modules never need the surface tree.
  Evidence: EP-176 boundary tests cover the facade, all internal parser modules, workspace loading,
  and the semantic consumers; the complete 464-example DSL suite passes.
  Impact: Future grammar work has one source owner, while normalized `Spec` remains the stable
  interchange for checking, generation, diffing, fingerprints, and replay analysis.

- Observation: Fourteen Mori-registered projects depend on Keiro, but none needs migration for this
  initiative.
  Evidence: The reverse-dependent inventory found only existing compatibility/API usage, and the
  released public compile probe remains green.
  Impact: The advanced frontend is additive, and cross-repository adoption can occur independently.


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

- Decision: Superseded on 2026-08-01. Put a package-wide production-record modernization in EP-177
  between the 0.7 oracle and every newly introduced frontend record.
  Rationale: Existing prefixes are not the desired record convention, and introducing
  `sourceOffset`, `locatedValue`, or `definitionVersion` would deepen the cleanup. Doing the
  breaking selector change immediately after 0.7 and before v2/v3 adoption minimizes migration
  cost while the oracle protects language behavior.
  Date: 2026-08-01

- Decision: Superseded on 2026-08-01. Apply
  `mori://shinzui/haskell-jitsurei/docs/core-record-patterns` without exposing generic-lens's orphan
  labels to Keiki-facing import closures.
  Rationale: The record guide requires unprefixed strict Generic records and explicitly warns that
  transitive `Data.Generics.Labels` imports conflict with Keiki labels. Pattern construction and
  puns are the safe default wherever isolation cannot be proven.
  Date: 2026-08-01

- Decision: Cancel EP-177 and preserve existing production records while applying a concise,
  strict record style only to newly introduced frontend-owned types.
  Rationale: The package-wide migration is independently large and would delay the language
  frontend without supplying a required capability. Keeping released selectors stable also makes
  EP-172 a complete oracle with no planned public-API exception.
  Date: 2026-08-01


## Outcomes & Retrospective

The initiative delivered the intended modular, source-aware frontend without changing the 0.7
language. `Keiro.Dsl.Frontend` now owns exact source spans, the located non-lossless surface tree,
structured failures, and explicit lowering. Twelve internal parser modules own grammar concerns;
one registry explicitly maps each released language to its syntax and runtime profiles; and
`Keiro.Dsl.Parser` remains the small compatibility facade used by the CLI and workspace loader.
Semantic checking, generation, diffing, fold fingerprints, and replay analysis continue to consume
the unchanged normalized graph.

EP-172 froze 256 fixtures across 17 source-consuming paths, 13 diagnostic goldens, generated-byte
and public-API probes, and a 445-example baseline. EP-173 through EP-176 grew that suite to 464
examples while keeping every frozen observation unchanged. The final `cabal test all` run passed 37
suites; `cabal build all`, native `nix flake check`, formatting, and strict validation of all 17 ADR
concepts also passed. The only pending examples are two pre-existing `keiro-pgmq` environment/fault-
injection cases documented by that suite; no suite was omitted.

The principal lesson was that the package-wide record modernization in EP-177 was neither small nor
necessary. Cancelling it kept the compatibility surface exact and allowed the architectural work to
remain reviewable. The other key constraint was preserving a single semantic authority: exact
surface evidence is useful for diagnostics and future tooling, but lowering it before validation,
workspace composition, generation, diff, fingerprint, and replay work avoided a pervasive AST
migration. ADRs 4 and 16 now carry the durable failure-boundary and source/surface/semantic model.

No syntax, language version, runtime semantic, generated Haskell byte, dependency bound, or
cross-repository source was changed. Lossless formatting, editor integration, and version-aware
rewrite/fleet work remain intentionally deferred to separately scoped initiatives.


## Revision Note

2026-08-01: Cancelled EP-177 at the maintainer's direction, removed it from all downstream
dependencies and integration assumptions, and shortened the critical path to EP-172 -> EP-173 ->
EP-174 -> EP-175 -> EP-176. Existing production-record APIs are now preserved; only new
frontend-owned records adopt the local semantic-field convention.

2026-08-01: Marked EP-173 complete after delivering located surface syntax, explicit checked
lowering, nested field/expression evidence, the unchanged compatibility facade, and the ADR 16
amendment. EP-174 is now unblocked.

2026-08-01: Marked EP-174 complete after extracting twelve internal parser modules, enforcing the
facade/import boundaries, and passing the 454-example compatibility and conformance suite plus all
package and native flake checks. EP-175 is now unblocked.

2026-08-01: Marked EP-175 complete after making the three released registry entries explicit,
threading one frontend context through profile-sensitive productions, exposing structured failures,
amending ADRs 4 and 16, and passing the 462-example suite and release-quality checks. EP-176 is now
unblocked.

2026-08-01: Marked EP-176 and MasterPlan 28 complete after converging every source consumer on the
frontend, documenting the public and authoring model, auditing registered dependents, and passing
the 464-example DSL suite, complete 37-suite matrix, all-package build, native flake checks, and
strict ADR validation.
