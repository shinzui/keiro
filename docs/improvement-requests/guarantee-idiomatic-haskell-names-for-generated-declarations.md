---
type: Improvement Request
title: Guarantee idiomatic Haskell names for every generated declaration
description: >-
  Make Keiro's checked naming model guarantee UpperCamelCase module/type names and lowerCamelCase
  value names, independently of DSL, wire, registry, schema, and table spellings.
timestamp: 2026-08-04T04:14:15Z
requestId: IR-16
status: proposed
origin: mori://shinzui/mori
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-04T04:14:15Z
    document_timestamp: 2026-08-04T04:14:15Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository review of the Language-4 parser, read-model scaffold naming helpers,
      skeleton output, generated conformance fixtures, and a Mori workspace scaffold that
      reproduced underscore-bearing module components.
---

# Improvement Request: Guarantee Idiomatic Haskell Names for Every Generated Declaration

## Status

Proposed as a code-generation correctness and source-quality invariant.

## Context

Keiro's DSL parser deliberately accepts both CamelCase and snake_case identifiers. The read-model
scaffold currently turns a declaration name into a Haskell module component by uppercasing only
its first character. It separately splits underscores when constructing some value stems. As a
result, `readmodel service_oncall` generates the module component `Service_oncall` while generating
values such as `serviceOncall`.

This output compiles because underscores are lexically legal in a Haskell constructor identifier,
but it violates the conventional Haskell module naming contract. The problem is reinforced by
Keiro's own queue/read-model skeletons and checked-in conformance fixtures, which emit and bless
snake_case read-model declarations.

The issue surfaced again while implementing
`mori://shinzui/mori/plans/175-rewrite-the-reaction-aggregate-as-a-functional-execution-lifecycle`:
the Mori declaration `readmodel reaction_history` generated `Mori.Modules.Reaction_history`.
The same consumer already had `Automation_registrations` and `Project_artifacts` generated from
similar declarations. The physical SQL names are separate `table` properties and do not require
these Haskell names to preserve snake_case.

## Requested Change

Introduce one checked Haskell-name derivation model and use it everywhere Keiro turns a DSL name
into generated Haskell source. Module components, types, and constructors must be idiomatic
UpperCamelCase; values and selectors must be idiomatic lowerCamelCase. Snake_case DSL names may be
normalized deterministically, or rejected with a source-located diagnostic where normalization is
unsafe, but scaffolding must never emit a non-idiomatic Haskell module component.

Keep DSL identity, wire names, registry names, SQL schemas, SQL tables, queue names, event types,
and other external spellings independent from generated Haskell names. Detect normalization
collisions during `keiro-dsl check`, before any files are written. Apply the same policy to
skeletons, single-spec scaffolding, workspace scaffolding, generated facades, hole modules,
manifests, scaffold records, import planning, diff impact, and conformance packages.

Because correcting an existing name moves generated and create-once modules, the scaffold plan
must report the source rename explicitly and preserve hand-owned hole contents through a safe,
reviewable migration rather than silently leaving two module trees behind.

## Acceptance

1. `readmodel reaction_history` generates a `ReactionHistory` module component and lowerCamelCase
   values such as `reactionHistoryProjection`; it never generates `Reaction_history` or
   `reaction_historyProjection`.
2. The SQL declaration `table = "reaction_history"` remains exactly `reaction_history` in metadata,
   qualified SQL, runtime registration, and generated table constants.
3. All generated module components, type names, constructors, values, and selectors pass a shared
   checked naming policy before scaffolding; there are no renderer-local naming approximations.
4. Names such as `foo_bar` and `fooBar` that normalize to the same Haskell occurrence fail check
   with a stable, source-located collision diagnostic naming both declarations.
5. Queue/read-model skeletons emit idiomatic DSL identifiers, and all checked-in generated
   conformance packages contain no underscore-bearing module components.
6. A migration regression starts from an existing `Service_oncall` generated tree plus a filled
   create-once hole, plans the move to `ServiceOncall`, preserves the hole contents, and leaves no
   stale old module in the manifest or scaffold record.
7. Workspace diff/replay impact classifies a Haskell-only normalization change as source/build
   impact without reporting a wire, SQL, replay, or runtime identity change.
8. Golden and property tests cover leading/trailing/repeated underscores, acronyms, digits,
   already-idiomatic camel case, reserved words, empty normalized segments, and normalization
   collisions across every declaration kind that contributes a Haskell name.

## Requested Deliverables

- A central validated Haskell-name type and deterministic UpperCamelCase/lowerCamelCase derivation.
- Source-located diagnostics and collision analysis before scaffold writes.
- Naming-aware scaffold, skeleton, manifest, import, diff, and create-once migration behavior.
- Rewritten conformance fixtures proving generated module and value naming conventions.
- Authoring and upgrade documentation that clearly separates logical and external names from
  generated Haskell occurrences.
