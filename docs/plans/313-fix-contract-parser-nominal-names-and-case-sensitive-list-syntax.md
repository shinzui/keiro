---
id: 313
slug: fix-contract-parser-nominal-names-and-case-sensitive-list-syntax
title: "Fix contract parser nominal names and case-sensitive List syntax"
kind: exec-plan
created_at: 2026-10-14T13:48:02Z
intention: "intention_01m4xapmaeejzspbtd99pwwk7h"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-14T13:48:02Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T13:54:02Z
      mode: "other"
      note: "Completed initial parser-fix plan with contextual grammar cases, implementation milestones, and release validation."
---

# Fix contract parser nominal names and case-sensitive List syntax


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Promote durable decisions into the relevant ADRs before completion.

## Purpose / Big Picture


A service author must be able to use an ID declaration named `Optional`, `Map`, `Set`, or `List` in a public integration contract without the parser confusing that name with a container application. At the same time, the container keyword must be exactly `List`: `list text`, `LIST text`, and `LiSt text` must not become alternate spellings. The observable result is that valid Language 6 nominal references pass `check`, generate the existing scalar/list codecs, and round-trip through `pretty`, while malformed container applications and wrong-case keywords fail with useful source locations.

This plan addresses the two parser findings from the review of `keiro-dsl-0.20.0.0` through `a0c82a42`. The independent removal-diff defect is owned by [ExecPlan 314](314-fix-ir-50-command-and-event-removal-diff-classification.md). Neither plan requires the other to land first. This document authorizes implementation planning; its unchecked work has not been performed.

## Progress


- [ ] M1: Add Language 6 regression cases for nominal/container ambiguity and keyword casing; demonstrate failures on the starting implementation.
- [ ] M2: Repair contextual parsing, retain feature gates and precise token spans, and verify parser/check/pretty/scaffold behavior.
- [ ] M3: Run the DSL and corpus gates, document the lexical rule and release correction, and distill the decision into ADR-52.

## Surprises & Discoveries


None recorded during implementation yet.

## Decision Log


2026-10-14: Keep declared-ID names legal and distinguish container application syntax locally. The user chose one plan for both parser corrections and a separate plan for IR-50. Globally reserving additional identifiers would create another source compatibility change and would not repair the defect.

2026-10-14: Treat `List List` as a list whose element is a declared ID named `List`; it is not a nested container unless the second `List` itself has a type operand. A bare reference remains subject to ordinary declared-ID validation. Grammar recognition must not depend on declaration order or on whether an ID lives in another workspace member.

2026-10-14: Use the existing case-sensitive keyword primitive and current Language 6 feature gates. Do not introduce a new source language, public AST variant, runtime capability, wire representation, or dependency for this repair.

## Outcomes & Retrospective


Not implemented. Record actual commands and results here at completion; the prior review's passing baseline tests are not evidence that these new regression cases pass.

## Context and Orientation


Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`. A `.keiro` source selects a language and declares IDs and service nodes. An ID declaration, such as `id Optional prefix=probe`, gives a nominal type: a named identity type with a checked wire prefix. A contract describes public message payloads. `CScalar (CDeclaredId "Optional")` means one such ID; `CList (CDeclaredId "Optional")` means a list of those IDs. Neither is an optional-value container.

`keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs` owns `pContract`, `pContractType`, and `pContractScalarType`. The current `contractContainerKeyword` imports Megaparsec's case-insensitive `string'`, unlike `keyword` in `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`, which uses exact `chunk` matching and checks identifier boundaries. The scalar parser rejects every occurrence of `List`, `Optional`, `Map`, and `Set` before trying `ident`. Consequently an ordinary declared ID is rejected by spelling alone. The outer list branch also consumes a bare `List` before determining whether it has an element type.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines `ContractScalarType` and `ContractType`; nesting is intentionally unrepresentable. `keiro-dsl/src/Keiro/Dsl/Validate.hs`, through `validateContract`, rejects references that do not resolve to ID declarations. `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` renders the normalized types. `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` gates both declared contract IDs and contract lists to candidate Language 6. Parser feature errors own exact token spans through `withOwnedSpan` and `requireLanguageFeatureAt`; preserve those spans when introducing lookahead or backtracking.

`keiro-dsl/test/Main.hs` contains the `contract list fields` group, including nested-container errors, aliases, prefix boundaries, version gates, and scaffold checks. `keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs` checks feature ownership and spans. The compiled list corpus lives under `keiro-dsl/test/conformance-contract-list-fields/`; fixture inputs live in `keiro-dsl/test/fixtures/`. Use the corpus regeneration tool rather than editing generated Haskell directly. `docs/user/keiro-dsl-reference.md` explicitly makes keywords case-sensitive, and `docs/user/keiro-dsl-integration.md` defines the admitted public scalar/list shapes.

[ADR-16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) makes syntax contextual, source-located, and independent of the normalized semantic graph; contextual keywords must not accidentally reserve unrelated identifiers. [ADR-52](../adr/0052-integration-contracts-admit-lists-of-scalar-fields.md) admits only one list layer over existing scalars and requires strict arrays and scalar identity keys. [ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md) makes new positive coverage target Language 6, while describing a separate staged retirement that this plan does not execute. Preserve the currently supported older-language rejection checks; do not rewrite the historical corpus for this repair.

The review reproduced the current defects with valid declarations named `Optional`, `Map`, `Set`, and `List`, each used as a scalar contract field. The first three fail with the unsupported-container message and the last expects an additional type. `Listing` succeeds. All four tested spellings of the list keyword currently succeed. These observations motivate new tests, rather than establishing a desired reservation policy.

## Plan of Work


### Milestone 1: Specify the contextual grammar with failing tests


Extend the `contract list fields` group in `keiro-dsl/test/Main.hs`. Use compact inline Language 6 sources for the parser matrix, and add a durable fixture only where compiled or workspace coverage needs one. Assert the AST shape as well as successful parsing, because accidentally converting a scalar into a list is a wire change. Each of `Optional`, `Map`, `Set`, and `List` must work as a declared scalar ID and as the element of one `List`; `Listing` and names with longer prefixes must keep working. Test absent declarations separately: a syntactically bare reference must reach `ContractIdUnknown`, not silently become a supported container.

Exercise a bare `List` before `}`, before `;`, and before the next field without a semicolon. The next field may carry `haskell` and `as` aliases. Include comments and newlines, but also put adjacent fields on one line: whitespace and indentation are not delimiters in this grammar. Test `values: List List` as a valid list of declared IDs and `values: List List text` as invalid nesting. Unsupported applications such as `Optional text`, `Map text`, and `Set text` remain invalid; a declaration with one of those names must not cause their application syntax to be accepted.

Test `List text`, `List int`, `List typeid "probe"`, and `List SomeId` positively, and `list text`, `LIST text`, and `LiSt text` negatively. A mixed-case word used alone may still be an ordinary declared identifier; the casing restriction applies to the container keyword, not to ID naming. Retain the Language 5 `ContractListFieldSyntax` refusal and its precise `List` span. Show that these new nominal and case assertions fail against the starting code before changing the implementation.

### Milestone 2: Repair recognition without coupling parsing to symbol resolution


In `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs`, replace case-insensitive container matching with the shared exact keyword behavior. Remove the unconditional spelling blacklist from the scalar identifier branch. Decide whether exact `List` begins an application by syntax, not by an ID symbol table. A field type followed by `;`, `}`, or the syntactic start of the next field is complete; the next field head consists of an identifier, optional selector/wire aliases in their existing order, and `:`. Lookahead must recognize that boundary before consuming a would-be element identifier, so `value: List other: text` retains two fields instead of swallowing `other` as an element type.

When exact `List` has a scalar operand rather than a field boundary, parse one `CList` with the ordinary scalar grammar. That grammar can return a declared ID named `List`, `Optional`, `Map`, or `Set`. Extra type operands must fail as malformed application syntax, so a third token cannot turn `List List text` into a valid nested shape or an invented field. Preserve helpful unsupported-container errors where they can be proved syntactically, but do not preserve an erroneous diagnostic by rejecting valid nominal names. Adjust the existing nested-container message assertions to distinguish genuine malformed applications from valid nominal references.

Keep feature gating outside any backtracking that could erase `LanguageFeatureRequiresVersion`. Capture the actual list token's span once the application has been recognized. Use no global changes to `reservedWords`, and do not make newlines meaningful. Add a workspace test with the ID declaration in another member to show that parsing does not rely on local declaration order. Through the public frontend, assert parse/pretty/parse equality and `check` success. Scaffold at least the ambiguous scalar and list forms, verify their generated Haskell field types and codec shape, and compile an extension of the existing contract-list corpus if a new fixture changes generated output.

### Milestone 3: Verify and document the repaired contract


Run the focused tests, full DSL suite, and generated-corpus checks below. Existing list admission, array ordering, required-key, indexed failure, identity-key, and diff tests must remain green. If adding committed fixtures, update the fixture inventory and corpus registration used by `keiro-dsl/test/Main.hs` and the regeneration tool; regenerate rather than patch generated files. Repeated scaffold output must be identical.

Update `keiro-dsl/CHANGELOG.md` and clarify in `docs/user/keiro-dsl-integration.md` that unsupported container applications do not reserve identically spelled ID names. Keep the reference's case-sensitive lexical rule. Distill this contextual distinction into ADR-52, maintaining its existing document ID and the ADR bundle log. Follow the local ADR profile and validate it; this is a clarification of the admitted scalar grammar, not support for Optional/Map/Set containers. Record results in this plan and commit with its ExecPlan and Intention trailers.

## Concrete Steps


All commands run at the repository root. Use the Nix shell for verification, including Z3 for symbolic tests.

```bash
nix develop -c z3 --version
nix develop -c cabal test keiro-dsl-test --test-show-details=direct --test-options='--match "contract list fields"'
nix develop -c cabal test keiro-dsl:tests --test-show-details=direct
nix develop -c just dsl-api-boundaries record-migration-policy conformance-corpus-policy
```

The focused command must first expose the new regressions, then pass after M2. The full suite must have no failures; its count may increase. To observe the nominal case directly, place this source in a temporary file:

```keiro
language keiro-dsl 6
context parser-probe
id Optional prefix=probe
contract notices {
  schemaVersion 1
  discriminator kind
  topic notices "probe.notices"
  event Noticed on notices { value: Optional values: List Optional }
}
```

```bash
nix develop -c cabal run -v0 keiro-dsl -- check /tmp/parser-probe.keiro
nix develop -c cabal run -v0 keiro-dsl -- pretty /tmp/parser-probe.keiro
```

Expected `check` output is `OK` with exit 0. Changing only `List Optional` to `LiSt Optional` must fail rather than create a list. Repeat with declared `List`, taking care to distinguish `value: List` from `values: List List`.

If committed generated fixtures changed, use the established regeneration command, inspect its diff, then rerun the corpus check. For ADR/documentation edits, use the existing repository checks:

```bash
nix develop -c just corpus-regen
nix develop -c just adr-validate user-documentation-validate
nix develop -c just record-migration-policy conformance-corpus-policy
git diff --check
```

Do not run regeneration merely to restamp unrelated files. Commits for this work use Conventional Commits and these trailers:

```text
ExecPlan: docs/plans/313-fix-contract-parser-nominal-names-and-case-sensitive-list-syntax.md
Intention: intention_01m4xapmaeejzspbtd99pwwk7h
```

## Validation and Acceptance


Completion requires the scalar AST for every declared-name case, the list AST for one-layer applications, successful validation for locally or workspace-declared IDs, and ordinary unknown-ID diagnostics for unresolved bare references. The same shapes must survive canonical pretty printing. The no-semicolon adjacent-field cases must preserve every field name, alias, and type. Genuine nesting and unsupported container applications must fail; wrong-case list applications must fail; longer identifiers must not be consumed as keyword prefixes. The Language 5 list gate must retain its source-language code and exact token span.

Generated scalar JSON remains a scalar and generated list JSON remains an ordered array using the same ID admission rules. Passing the existing compiled list suite and corpus comparison is required. No aggregate fold fingerprint, runtime capability, list wire policy, or public report schema changes as a side effect. Update documentation and provenance only after recording actual outcomes.

## Idempotence and Recovery


Parsing and checking are read-only. Use temporary output directories for scaffold probes and preserve consumer-owned holes. Fixture regeneration is repeatable; inspect the worktree before and after and retain unrelated edits. If a parsing experiment changes existing wire shapes, back out only that experiment, keep the failing regression, and revisit the syntactic boundary. Do not recover by globally reserving type words or weakening feature gates. The two release-fix plans are independently commit-ready and can be implemented in either order.

## Interfaces and Dependencies


Preserve the public `ContractScalarType`, `ContractType`, parser/frontend entry points, and `ContractListFieldSyntax` contract. Keep disambiguation helpers internal to `Keiro.Dsl.Parser.Integration`; the shared `Keiro.Dsl.Parser.Core.keyword` remains exact and boundary-aware. No dependency version change is expected. Before relying on a Megaparsec API beyond the locally demonstrated primitives, use `mori registry search megaparsec`, inspect the matching project's full registry entry and docs, and read its source. Never search `/nix/store` or the filesystem root. If bounds unexpectedly need changing, verify releases against the authoritative registry and upstream tags first.

Creation note (2026-10-14): Authored from the release review and current parser, frontend tests, and ADRs. Both parser fixes share this plan; IR-50 is deliberately separate.
