---
id: 175
slug: make-released-keiro-syntax-profiles-and-frontend-diagnostics-explicit
title: "Make released Keiro syntax profiles and frontend diagnostics explicit"
kind: exec-plan
created_at: 2026-08-01T19:49:10Z
intention: "intention_01kyzdr07ge299bk2axrgwssht"
master_plan: "docs/masterplans/28-build-a-modular-source-aware-keiro-dsl-language-frontend.md"
---

# Make released Keiro syntax profiles and frontend diagnostics explicit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, each released Keiro language version explicitly names the syntax capabilities
and runtime-semantics contract it owns. Version 3 can intentionally reuse version 2's syntax while
selecting newer ID-domain semantics, but no future version inherits a feature merely because its
number is larger. The modular grammar receives one selected `FrontendContext` and asks that exact
profile whether a production is available.

The advanced frontend API also returns structured failures with a phase, stable code, and exact
`SourceSpan`; callers no longer have to parse Megaparsec's rendered text to identify a malformed
preamble, body grammar failure, feature gate, or lowering refusal. Existing 0.7 parser functions
and CLI text remain compatibility wrappers and continue satisfying the EP-172 oracle.


## Progress

- [ ] Milestone 1: replace numeric feature/runtime inference with explicit released-language profiles.
- [ ] Milestone 2: thread one selected frontend context through every modular grammar production.
- [ ] Milestone 3: add structured span-aware source-selection, parse, and lowering failures.
- [ ] Milestone 4: prove frozen v1/v2/v3 matrices, compatibility rendering, and ADR conformance.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Store syntax profile and runtime-semantics identity in the authoritative
  `LanguageDefinition` registry entry.
  Rationale: Parser dispatch and downstream semantic planning are two aspects of one released
  language contract. Separate numeric threshold functions can drift and silently affect a later
  version.
  Date: 2026-08-01

- Decision: Make feature membership exact per profile; keep `languageFeatureMinimumVersion` only as
  a derived compatibility/documentation query, never as parser policy.
  Rationale: “Introduced in version 2” does not imply “unconditionally accepted by every greater
  version.” Explicit profiles freeze both inheritance and deliberate future removal.
  Date: 2026-08-01

- Decision: Add a new structured frontend failure API while preserving the three released parser
  entry points and their rendered failures.
  Rationale: Language tooling needs phase/code/span data, while existing library and CLI callers
  should not break during an internal architecture refactor.
  Date: 2026-08-01

- Decision: Keep semantic validator diagnostics downstream and line-compatible in this plan.
  Rationale: Surface, source-selection, parsing, and lowering failures have exact spans available.
  Retrofitting all of semantic validation with span keys is separable work and is not required to
  establish the frontend boundary.
  Date: 2026-08-01

- Decision: Use EP-177's unprefixed, strict record convention for the registry, context, and
  frontend-failure records.
  Rationale: Names such as `definitionVersion` and `frontendCode` repeat their owning types and
  would undo the record modernization on newly introduced API.
  Date: 2026-08-01


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` currently defines `LanguageDefinition` with a version,
predecessor, and a closed `LanguageBodyParser` choice. Version 1 selects `LanguageBodyParserV1`;
versions 2 and 3 select `LanguageBodyParserV2`. A separate `LanguageFeature` registry maps each
feature to a minimum version, and `languageSupportsFeature` accepts the feature whenever the selected
version is numerically greater than or equal to that minimum.

`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` independently selects runtime semantics with another
numeric rule: versions at least 3 use `keiro-dsl/runtime-semantics/2`, while older versions use
runtime semantics 1. These rules happen to describe 0.7 correctly, but a version-4 registry entry
would inherit both decisions automatically before its author explicitly chose them.

EP-174 at
[docs/plans/174-modularize-the-keiro-megaparsec-grammar-by-language-concern.md](174-modularize-the-keiro-megaparsec-grammar-by-language-concern.md)
is a hard dependency. Its `Parser.Document` selects the body parser, and its concern modules
currently receive a language version or provisional frontend context. EP-173 supplies exact spans
and structured lowering failure data. EP-177 supplies the record naming, strictness, deriving, and
Keiki-label isolation rules. EP-172 supplies exact compatibility rendering.

A “syntax profile” is the immutable set of grammar capabilities explicitly assigned to one released
language definition. A “runtime-semantics identity” is the stable text discriminator consumed by
`CheckedService`, fingerprints, diff, replay, and generation; it is not source syntax.

[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) requires one
append-only version registry and frozen predecessor rejection fixtures. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires source selection and feature rejection at their earliest sound boundary with machine-stable
codes. [ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
requires version-2 expression/ownership syntax and version-3 ID semantics to remain distinct
contracts. No cross-repository ADR is required.


## Plan of Work

Milestone 1 refactors `LanguageVersion.hs`. Define an opaque `SyntaxProfile` with exact feature
membership and a stable profile identifier used in inspection/tests. Define the 0.7 profiles
explicitly: version 1 owns no successor features; version 2 owns `NominalBindingSyntax`,
`IntegerScalarSyntax`, `TypedAggregateExpressionSyntax`, and
`ExplicitTransitionImplementationSyntax`; version 3 explicitly selects the same syntax profile as
version 2. Do not derive profile membership from version ordering.

Extend each `LanguageDefinition` with its selected `SyntaxProfile` and runtime-semantics identity.
Version 1 and version 2 explicitly select `keiro-dsl/runtime-semantics/1`; version 3 explicitly
selects `keiro-dsl/runtime-semantics/2`. Change
`SemanticContract.effectiveLanguageContractForVersion` to read that registry entry and delete its
numeric threshold. Preserve predecessor links and supported-version ordering.

`languageSupportsFeature` must look up the exact definition/profile. Keep
`languageFeatureMinimumVersion` source-compatible if EP-172's public probe pins it, but derive it by
searching the explicit profiles and use it only for documentation/error remedies. Retire
`LanguageBodyParser` and `definitionBodyParser` from active parsing. If they are public in 0.7,
either retain deprecated compatibility projections through this release cycle or record their
intentional removal as accidental-internal API cleanup in `keiro-dsl/CHANGELOG.md`; do not remove
the three parse entry points.

Milestone 2 defines `FrontendContext` in `Keiro.Dsl.Frontend` or an internal context module. It
carries the chosen `LanguageDefinition`, source identity, and helpers for exact feature checks. Route
the same value from `Parser.Document` into every concern parser. Replace functions that take only a
`LanguageVersion` when they make syntax-policy decisions. A production encountering a disabled
feature emits `LanguageFeatureRequiresVersion` at the surface span of the actual grammar marker.
Comments, strings, wire keys, and legal identifiers remain inert because only productions can ask
for a feature.

Milestone 3 defines a public structured failure model in `Keiro.Dsl.Frontend`. It distinguishes
`SourceSelectionPhase`, `BodyParsingPhase`, and `LoweringPhase`; carries a stable frontend code, a
primary `SourceSpan`, a human message, and optional expected/supported-version data. Convert
Megaparsec bundles at the facade boundary without exposing `ParseErrorBundle` or custom component
types. Ordinary unexpected-token failures use a stable general body-syntax code plus Megaparsec's
expected/unexpected text. Custom grammar failures retain their existing source-language code.

Make `parseSurfaceSource` return the structured failure. `lowerSurfaceSource` retains its structured
lowering failure, convertible into the common type. `parseSource` maps the new failure back to the
existing `ParseFailure`; `parseSpec` and `parseSpecText` continue rendering `ParseError` text exactly
as EP-172 pins it. Add JSON instances only if a current CLI/API uses JSON for frontend failures;
otherwise avoid committing a serialization schema in this refactor.

Milestone 4 adds a table-driven released-language matrix. For every `LanguageFeature`, test one real
grammar occurrence plus inert comment/string/identifier occurrences against versions 1, 2, and 3.
Assert exact profile identifiers, runtime semantics, predecessor links, supported versions,
structured phase/code/span, and compatibility text. Add a construction test proving a hypothetical
registry entry is not created implicitly and a source-code review check that parser policy no longer
uses version comparison.

Amend ADR 16 to record explicit profile inheritance and amend ADR 4 if necessary to record the
structured frontend boundary. Preserve their stable `docId`s, advance timestamps, update
`docs/adr/log.md` through the established OKF command, and run strict validation.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='released language profiles'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='frontend diagnostics'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='source language'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='frontend 0.7 compatibility'
```

Audit for forbidden policy inference:

```bash
rg -n 'languageVersionNumber.*[<>]=?|[<>]=?.*languageVersionNumber|version *>=|version *>' keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs keiro-dsl/src/Keiro/Dsl/SemanticContract.hs keiro-dsl/src/Keiro/Dsl/Parser
```

Review every hit. No syntax-capability or runtime-semantics selection may depend on numeric ordering;
numeric comparison remains legitimate for validating positive version tokens or presenting sorted
supported versions. Finish with:

```bash
cabal test keiro-dsl-test --test-show-details=direct
cabal build all
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix flake check
```

Record exact counts and the final profile table in the living plan.


## Validation and Acceptance

Inspection of the registry must show: v1/profile-v1/runtime-1; v2/profile-v2/runtime-1;
v3/profile-v2/runtime-2. Every version/feature matrix row must match the frozen 0.7 acceptance
contract. A version-1 successor feature returns a structured body-parsing failure whose span begins
at the real syntax marker; the same spelling inside a comment or string succeeds. Unknown and
malformed preambles report source-selection phase. An ordinary missing token reports body-parsing
phase. A lowering cardinality refusal reports lowering phase.

The compatibility parser functions, exact diagnostic goldens, canonical renderings, semantic
graphs, generated bytes, and workspace attribution must remain unchanged. `SemanticContract.hs`
and parser modules must contain no numeric threshold that selects released policy. Strict ADR
validation and the complete build/test matrix must pass.


## Idempotence and Recovery

Registry edits are deterministic and contain no source migration. Add the explicit profile fields
before removing compatibility projections such as `definitionBodyParser` so the project compiles
at each step. If a compatibility renderer
drifts, compare the structured failure with the EP-172 golden and fix the projection; do not change
the golden. If retiring `LanguageBodyParser` causes an internal caller failure, convert that caller
to `FrontendContext`; if it exposes a real external compatibility concern, keep a deprecated
projection until a separately documented package boundary permits removal.


## Interfaces and Dependencies

The final design must provide the equivalent of:

```haskell
data LanguageDefinition = LanguageDefinition
  { version :: !LanguageVersion
  , predecessor :: !(Maybe LanguageVersion)
  , syntaxProfile :: !SyntaxProfile
  , runtimeSemantics :: !Text
  }
  deriving stock (Eq, Show, Generic)

languageSupportsFeature :: LanguageVersion -> LanguageFeature -> Bool

data FrontendPhase
  = SourceSelectionPhase
  | BodyParsingPhase
  | LoweringPhase

data FrontendFailure = FrontendFailure
  { phase :: !FrontendPhase
  , code :: !FrontendErrorCode
  , span :: !SourceSpan
  , message :: !Text
  }
  deriving stock (Eq, Show, Generic)
```

Reuse `SourceSpan` from EP-173 and existing `SourceLanguageErrorCode` values where applicable. All
new product records follow EP-177 and must not introduce owner-prefixed selectors. Do not expose
Megaparsec types. No dependency or bound change is required.
