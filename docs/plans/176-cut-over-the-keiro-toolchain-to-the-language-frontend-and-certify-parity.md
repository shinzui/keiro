---
id: 176
slug: cut-over-the-keiro-toolchain-to-the-language-frontend-and-certify-parity
title: "Cut over the Keiro toolchain to the language frontend and certify parity"
kind: exec-plan
created_at: 2026-08-01T19:49:10Z
intention: "intention_01kyzdr07ge299bk2axrgwssht"
master_plan: "docs/masterplans/28-build-a-modular-source-aware-keiro-dsl-language-frontend.md"
---

# Cut over the Keiro toolchain to the language frontend and certify parity

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, every way Keiro reads a `.keiro` source uses the same modular, located,
version-profiled frontend. Direct library parsing, CLI parse/check/inspect/scaffold/diff commands,
workspace member loading, pretty round trips, and downstream semantic planning all agree on source
selection, lowering, and compatibility rendering. The transitional direct-to-`Spec` implementation
is gone, so a future grammar feature has one parser owner and one released-profile gate.

Users see no 0.7 language or generation change. They can use the new advanced library API for exact
surface spans and structured frontend failures, while existing parser functions continue to work.
The complete unit, workspace, generated-byte, conformance, ADR, documentation, and native build
matrix demonstrates parity. This plan finishes the parent MasterPlan; it does not publish the next
package release.


## Progress

- [x] Milestone 1: inventoried and routed every source-consuming library, CLI, and workspace path
  (2026-08-01T22:33:43Z).
- [x] Milestone 2: removed the transitional public surface-parser re-export and enforced frontend
  dependency boundaries (2026-08-01T22:33:43Z).
- [x] Milestone 3: refreshed API, user, authoring, changelog, and architecture documentation
  (2026-08-01T22:33:43Z).
- [x] Milestone 4: passed complete parity, conformance, dependent-inventory, and repository
  validation (2026-08-01T22:33:43Z).


## Surprises & Discoveries

- Observation: The source-consumer inventory was already highly converged after EP-174.
  Evidence: `app/Main.hs` and `Workspace.hs` call the `Keiro.Dsl.Parser` compatibility facade;
  the facade delegates to `Keiro.Dsl.Frontend`; `Frontend` reaches the one internal document
  parser; pretty printing, checking, scaffolding, diffing, fold fingerprints, and replay impact
  consume only lowered semantic values.
  Impact: EP-176 required a boundary cutover and proof, not changes to CLI or workspace behavior.

- Observation: `Workspace.hs` still contains a direct Megaparsec parser, but it parses only the
  `.keiro-workspace` manifest grammar.
  Evidence: The `.keiro` member text enters through `parseSource` exactly once per member, while
  the direct `runParser` call owns manifest clauses and paths.
  Impact: The manifest parser remains deliberately separate and is excluded from the single
  `.keiro` document-parser rule.

- Observation: EP-173 temporarily re-exported `parseSurfaceSource` from `Keiro.Dsl.Parser`, even
  though the released 0.7 API probe did not contain that symbol.
  Evidence: The final public compile probe imports the advanced parser from `Keiro.Dsl.Frontend`,
  and a source-boundary test now prevents the compatibility facade from re-exporting it.
  Impact: `Frontend` is the sole advanced public owner; `Parser` contains only the three released
  compatibility entry points and their rendering.

- Observation: Mori reports fourteen registered projects that depend on Keiro: `mori://shinzui/danwa`,
  `mori://shinzui/kanmon`, `mori://shinzui/kawa`, `mori://shinzui/keiro-runtime-docs`,
  `mori://shinzui/keiro-runtime-jitsurei`, `mori://shinzui/keiro-runtime-patterns`,
  `mori://shinzui/keiro-syntax`, `mori://shinzui/kikan`, `mori://shinzui/kioku`,
  `mori://shinzui/kizashi`, `mori://shinzui/kotei`, `mori://shinzui/meibo`,
  `mori://shinzui/mori-app`, and `mori://shinzui/shikigami`.
  Evidence: `mori registry dependents shinzui/keiro --packages`; only
  `mori://shinzui/mori-app` exposed a package-level dependency in the current registry data.
  Impact: No dependent repository needed migration because all released compatibility entry points
  and selectors remain unchanged.


## Decision Log

- Decision: Perform one final consumer cutover after grammar modularization and profile/diagnostic
  work rather than changing each consumer in earlier plans.
  Rationale: All consumers already converge on a small parser facade. One audit against final types
  prevents mixed old/new paths and duplicated compatibility conversion.
  Date: 2026-08-01

- Decision: Remove the old direct-to-`Spec` parser once no caller uses it; retain only documented
  compatibility wrappers implemented through surface parse and lowering.
  Rationale: A dormant second parser would inevitably drift and defeat the single-language-authority
  goal.
  Date: 2026-08-01

- Decision: Certify no syntax, semantic, diagnostic-text, generated-byte, diff, fingerprint, or replay
  change against 0.7 before completing the MasterPlan.
  Rationale: This initiative is architectural. User-visible language changes require their own
  successor-version plan and cannot hide inside parity updates.
  Date: 2026-08-01

- Decision: Report registered dependents but do not edit or migrate another repository.
  Rationale: The advanced API is additive and the compatibility parser surface remains stable;
  cross-repository source rewriting belongs to IR-5 and requires explicit operator scope.
  Date: 2026-08-01

- Decision: Make `Keiro.Dsl.Frontend` the sole public advanced parse/lower API and keep
  `Keiro.Dsl.Parser` limited to released compatibility functions.
  Rationale: One owner makes the source -> located surface -> lowering direction explicit and
  prevents ordinary callers from accidentally depending on an unreleased transitional re-export.
  Date: 2026-08-01


## Outcomes & Retrospective

Every `.keiro` source now has one route: the CLI and workspace loader call the compatibility
facade, the facade invokes the advanced frontend, the frontend invokes the internal modular
document grammar, and lowering returns the unchanged `ParsedSource`. Boundary tests enforce that
semantic consumers cannot import surface syntax or parser internals, internal grammar cannot
depend on downstream consumers, and workspace source loading cannot bypass the facade. The
separate workspace-manifest parser remains correctly isolated.

The public documentation and Haddocks now describe exact spans, structured failures, explicit
released profiles, and the source -> surface -> lowering -> semantic pipeline. They also state the
important limitation that the surface tree omits comments and whitespace, so canonical pretty
printing is not lossless. The changelog records the additive advanced interface and the deliberate
absence of syntax, generated-output, or compatibility changes. ADRs 4 and 16 already contained the
final durable design after EP-175, so this plan required no further ADR amendment.

Validation completed without an omitted test suite: `cabal test all --test-show-details=direct`
passed 37 suites, and the dedicated `keiro-dsl-test` run passed 464 examples with zero failures.
The broader matrix retained two pre-existing, explicitly pending `keiro-pgmq` examples whose
requirements are documented in their test output. `cabal build all`, the native aarch64-darwin
`nix flake check`, `nix fmt`, strict OKF validation of all 17 ADR concepts, and `git diff --check`
passed. Nix reported only its normal omission of checks for incompatible non-host systems.

Compared with the 445-example EP-172 oracle, the completed suite adds nineteen architectural
checks while preserving every frozen fixture, diagnostic golden, canonical rendering, generated
byte, diff, fingerprint, replay, CLI, and workspace observation. No new language syntax, runtime
semantics, dependency bound, or cross-repository edit was introduced.


## Context and Orientation

The earlier child plans deliver the complete frontend. EP-172 at
[docs/plans/172-freeze-the-keiro-dsl-0-7-language-frontend-contract.md](172-freeze-the-keiro-dsl-0-7-language-frontend-contract.md)
owns the released oracle. EP-173 owns `Keiro.Dsl.Source`, `Keiro.Dsl.Syntax`,
`Keiro.Dsl.Frontend`, and lowering. EP-174 owns internal grammar modules and the parser facade.
EP-175 owns explicit released profiles and structured frontend failures. EP-177 was cancelled, so
the cutover instead preserves every existing selector and audits only new frontend-owned records.
This plan must inspect the working tree versions of all active predecessor plans and their living
sections before implementation; their
delivered interfaces, not the initial sketches in this file, are authoritative.

`keiro-dsl/app/Main.hs` owns CLI input routing. `keiro-dsl/src/Keiro/Dsl/Workspace.hs` reads each
manifest member through `parseSource`, retains member `SourceLanguage`, relocates semantic `Loc`
values for merged diagnostics, and produces one `CheckedService`. `PrettyPrint.hs` renders
`ParsedSource` or `Spec`. `ScaffoldRun.hs`, `WorkspaceScaffold.hs`, `Diff.hs`,
`WorkspaceDiff.hs`, `FoldFingerprint.hs`, and `ReplayImpact.hs` consume the parsed/lowered semantic
graph and effective language contract. The cutover audit must distinguish source consumers from
semantic consumers: semantic modules should not depend on surface syntax merely because the source
frontend now exists.

The library module list and dependency boundary live in `keiro-dsl/keiro-dsl.cabal`. Public API
documentation lives in module Haddocks, `docs/user/typed-spec-toolchain.md`, and
`docs/guides/choosing-keiro-dsl.md`. Authoring truth lives in
`agents/skills/keiro-dsl-authoring/NOTATION.md`, `WALKTHROUGH.md`, and `SKILL.md`.
`keiro-dsl/CHANGELOG.md` begins with the 0.7.0.0 release and should receive an unreleased entry for
the frontend architecture and any intentional public cleanup.

[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) owns the
source/surface/semantic boundary and workspace provenance. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
owns the failure boundary. [ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
owns member composition. [ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
is the proof that syntax, lowering, checking, generation, and runtime authority must remain aligned.
This plan performs the final ADR distillation pass across the parent and all children.


## Plan of Work

Milestone 1 builds a call-site inventory before editing. Search the library, executable, and tests for
`parseSource`, `parseSpec`, `parseSpecText`, direct `runParser` calls over `.keiro` text, preamble
selection, `LanguageDefinition`, and construction of `ParsedSource`. Classify each hit as a source
frontend, compatibility wrapper, test, or semantic-only consumer. Record the inventory in Surprises
& Discoveries with the owning module and expected final route.

Route `app/Main.hs` single-file commands through the stable facade or advanced frontend as
appropriate. CLI user-visible paths use compatibility rendering pinned by EP-172. `inspect` may use
the structured values internally but keeps its existing JSON schema. Route `Workspace.hs` member
loading through the same frontend once per member; preserve the original member-local source name
on every span and only project/relocate semantic `Loc` values for the merged graph. A manifest-only
`parse` remains a manifest parser and must not be conflated with the source grammar.

Audit `PrettyPrint.renderSource`, single/workspace scaffold planning, source-aware diff, replay
impact, and fold fingerprints. Each receives `ParsedSource`, `WorkspaceMember`, or `CheckedService`
after lowering. No downstream module may parse source text, inspect surface constructors, or derive
language policy from a version number.

Milestone 2 deletes the transitional direct-to-`Spec` document parser, obsolete parser helpers,
temporary re-exports, and unused `LanguageBodyParser` compatibility only to the extent decided and
documented by EP-175. `Keiro.Dsl.Parser` keeps the released three entry points, failure rendering,
and a small delegation to `Frontend`. `Keiro.Dsl.Frontend` is the only public owner of the advanced
surface parse/lower pipeline; internal `Parser.*` modules are the only `.keiro` modules importing
Megaparsec.

Add dependency-boundary checks. Semantic modules including `Grammar`, `Validate`, `SemanticContract`,
`Scaffold`, `Diff`, `FoldFingerprint`, and `ReplayImpact` must not import `Syntax` or internal parser
modules. `Workspace` may import the public facade/frontend but not internals. Internal parser modules
must not import the facade, workspace, validator, scaffold, diff, or replay modules. Remove dead code
only after the full compatibility oracle passes.

Milestone 3 documents the delivered model. Add module-level examples to `Keiro.Dsl.Frontend` showing
advanced surface parsing, exact span inspection, lowering, and ordinary compatibility parsing.
Update `docs/user/typed-spec-toolchain.md` with the parse -> located surface -> lower -> semantic
check pipeline and explain that canonical pretty printing is not lossless formatting. Update
`docs/guides/choosing-keiro-dsl.md` only where the operational cost/benefit of a versioned language
frontend changes. Update `agents/skills/keiro-dsl-authoring/NOTATION.md` and `SKILL.md` to tell future
authors that a feature is registered in an explicit released syntax profile and implemented in one
concern module; do not teach internal module names as end-user notation.

Add an unreleased `keiro-dsl/CHANGELOG.md` section describing the additive surface/frontend API,
structured diagnostic API, internal grammar modularization, exact-profile registry, stable
compatibility entry points, and deliberate absence of syntax/generated-output changes. If a public
accidental internal such as `LanguageBodyParser` was removed, identify it plainly as a breaking
library cleanup so the next package version can follow PVP.

Review every Decision Log, Surprises & Discoveries, and Outcome section in MasterPlan 28 and
EP-172, EP-177, EP-173, EP-174, EP-175, and this plan. Amend ADR 16 with the final
source/surface/lowering/semantic boundary and
explicit profile ownership. Amend ADR 4 with the structured phase/code/span boundary if delivered.
Create a new ADR only if the final design contains a durable decision not naturally owned by those
records. Preserve stable handles, update timestamps/log entries, and run strict OKF validation.

Milestone 4 runs the entire acceptance matrix. Run focused frontend tests, the full Hspec suite,
every `keiro-dsl` conformance suite, all-package build, native Nix checks, strict ADR validation,
formatting checks, and `git diff --check`. Use Mori's reverse-dependent inventory to report which
registered projects/packages consume Keiro; do not modify them. Compare the final results with
EP-172 and record exact counts and any platform omissions.


## Concrete Steps

Run the call-site and boundary inventory from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
rg -n 'parseSource|parseSpecText|parseSpec|runParser|LanguageBodyParser|LanguageDefinition|ParsedSource' keiro-dsl/src keiro-dsl/app keiro-dsl/test --glob '*.hs'
rg -n 'import (Text\.Megaparsec|Keiro\.Dsl\.Parser\.)' keiro-dsl/src --glob '*.hs'
```

After cutover, run focused checks:

```bash
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='frontend 0.7 compatibility'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='surface lowering'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='released language profiles'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='frontend diagnostics'
```

Run final package and repository validation:

```bash
cabal test keiro-dsl-test --test-show-details=direct
cabal test all --test-show-details=direct
cabal build all
nix flake check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
mori registry dependents shinzui/keiro --packages
```

If `cabal test all` includes an environment-dependent suite unavailable on the implementation
machine, run every pure and compiled `keiro-dsl-*` suite explicitly, record the exact omitted suite
and requirement, and do not mark the plan complete until the release environment supplies its proof.
Update this section with observed counts and commands if suite names change.


## Validation and Acceptance

Every source-consuming inventory row must route through `Keiro.Dsl.Frontend` or the documented
`Keiro.Dsl.Parser` compatibility facade. There is no second document parser. The EP-172 manifest,
curated diagnostic goldens, public type probe, surface spans, lowering parity, released profile
matrix, canonical rendering, workspace attribution, generated-byte freshness, compatibility diffs,
fold fingerprints, and replay impact all pass unchanged.

Existing production-record selectors still compile through the EP-172 public-API probe, and new
frontend records follow the EP-173 local convention. JSON keys, generated source, and all other
observations remain pinned. No package-wide record migration or generic-lens dependency is part of
this plan.

The advanced API must demonstrate exact span inspection without exposing Megaparsec and must lower
to the same `ParsedSource` as ordinary parsing. The CLI's existing text and JSON contracts remain
unchanged. All internal parser modules satisfy the import boundary, all semantic modules remain
surface-independent, and documentation accurately distinguishes canonical pretty printing from
lossless source preservation.

All pure/compiled conformance, package builds, native checks, and strict ADR validation must pass.
No new `.keiro` syntax, language version, generated Haskell change, or cross-repository edit is
accepted under this plan.


## Idempotence and Recovery

The cutover is code-only and can be tested repeatedly. Make one consumer family green at a time and
keep compatibility wrappers until the inventory proves no direct caller remains. Delete the old path
only in an isolated commit after the full oracle passes. If deletion reveals an unclassified caller,
restore the minimal helper with `apply_patch`, classify the caller, and route it deliberately; do not
reintroduce a permanent parallel parser. Documentation and ADR log changes are additive and must be
validated after every timestamp change.


## Interfaces and Dependencies

The final public direction is:

```haskell
parseSurfaceSource :: FilePath -> Text -> Either FrontendFailure SurfaceSource
lowerSurfaceSource :: SurfaceSource -> Either LoweringFailure ParsedSource
parseSource :: FilePath -> Text -> Either ParseFailure ParsedSource
parseSpec :: FilePath -> Text -> Either ParseError Spec
parseSpecText :: Text -> Either ParseError Spec
```

`Keiro.Dsl.Frontend` and the `Source`/`Syntax` types are the advanced interface.
`Keiro.Dsl.Parser` is the compatibility interface. `Grammar.Spec` and `CheckedService` remain the
semantic interfaces. Internal `Keiro.Dsl.Parser.*` modules are Cabal `other-modules`. Use the same
Megaparsec and parser-combinators dependencies and bounds as 0.7; this plan performs no dependency
selection or release publication.


## Revision Note

2026-08-01: Removed cancelled EP-177 from the cutover's dependency assumptions and acceptance
exceptions. Final certification now requires the existing selector API to remain unchanged.

2026-08-01: Completed the consumer cutover, made `Keiro.Dsl.Frontend` the sole advanced public API,
documented the delivered pipeline, audited fourteen Mori-registered dependents, and certified the
0.7 contract with 464 DSL examples plus the complete 37-suite repository matrix.
