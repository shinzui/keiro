---
type: Improvement Request
title: Add version-aware modernization linting to keiro-dsl
description: >-
  Detect valid but outdated Keiro DSL usage against an explicit target language, distinguish
  provable replacements from consumer-evidence candidates, and emit stable actionable diagnostics
  without rewriting source or weakening compatibility guarantees.
timestamp: 2026-09-22T00:58:20Z
requestId: IR-48
status: proposed
origin: mori://shinzui/rei
reviews:
  - kind: model
    reviewer: codex-author
    reviewed_at: 2026-09-22T00:58:20Z
    document_timestamp: 2026-09-22T00:58:20Z
    scope: technical-accuracy
    outcome: commented
    provider: openai
    model: gpt-5.6-sol
    effort: unspecified
    context: >-
      Author self-review against Keiro c68dbdd7 and the Rei checked-mapping audit in
      mori://shinzui/rei/plans/242-replace-eligible-shared-keiro-opaque-mappings-with-checked-declarations.
      The current check command, language registry, source-aware diagnostics, coverage report, and
      IR-5 upgrade request were inspected. The request is deliberately read-only and requires
      uncertainty to remain visible when a consumer-owned codec prevents a sound static conclusion.
---

# Add Version-Aware Modernization Linting to `keiro-dsl`

## Status

Proposed. Keiro validates a source against the language contract it declares, can enforce a
minimum language version, and can report opaque persisted roots. It does not currently answer the
different authoring question: “Which usages are valid but outdated relative to the language I am
preparing to adopt, and what evidence is still needed before replacing them?” No plan implements
this request.

## Problem and evidence

`keiro-dsl check` is primarily a correctness gate. `--min-language N` rejects a source below an
operator-selected floor, while `--coverage-report` and `CoverageOpaqueSurface` enumerate persisted
roots that pass through opaque mapped boundaries. Neither facility distinguishes an intentional
opaque boundary from one that predates a now-supported checked construct. The language registry
knows which syntax and runtime capabilities each version provides, but that knowledge is not
exposed as modernization advice.

The audit recorded by
`mori://shinzui/rei/plans/242-replace-eligible-shared-keiro-opaque-mappings-with-checked-declarations`
is a concrete example. Rei had twenty shared opaque mappings after adopting Keiro DSL 0.18. Manual
inspection found eighteen candidates for released bare-container, calendar-day, text-set, refined
base16, nominal-leaf, enum, or explicit legacy-ID declarations. Two must remain opaque:
`MaybeMaybeText` is non-injective under its stored JSON `null`, and `KnowledgeAnchor` uses a bespoke
flattened object encoding that Keiro's uniform structural union cannot describe. The existing
coverage warning treats all twenty alike, so a consumer must rediscover both the opportunities and
the safety exceptions by hand.

Keiro cannot infer a consumer-owned Haskell type or opaque Aeson codec from a symbol name. A useful
linter therefore must preserve uncertainty. It may prove that a parsed source form is superseded,
but it may only describe an opaque mapping as a candidate until a proposed checked shape, total
binding, fixture bytes, and retained-history evidence establish equivalence. Guessing from a name
such as `MaybeText` would turn an authoring convenience into a compatibility hazard.

This request is separate from
[IR-5](add-version-aware-keiro-dsl-upgrade-and-fleet-rewrite-tooling.md). IR-5 requests sequential,
atomic source rewrites. IR-48 requests a read-only inventory and explanation layer that can guide a
human or become an input to a future upgrade planner; it never rewrites `.keiro` files.

## Requested behavior

Add a version-aware lint entry point, preferably `keiro-dsl lint FILE --target-language N`, for a
single source or workspace. The target must be explicit in automation so a new candidate language
cannot silently change CI results. The report must record the target language's stability and
runtime-semantics identifiers alongside the source's declared and effective language contracts.

Maintain an append-only modernization-rule catalog. Each rule must have a stable code, the source
and target language range where it applies, severity, source span, current construct, suggested
replacement or next investigation, and one of these evidence levels:

- `definite`: the parsed and checked DSL graph proves that the replacement preserves the relevant
  semantics.
- `candidate`: the target language supports a better construct, but consumer-owned types, codecs,
  bindings, or retained data must be inspected before replacement.
- `blocked`: the available facts show why the apparent modernization is unsound, such as
  non-injective nullability or a wire shape the target construct cannot represent.

The first rule set should cover three classes. First, report legacy-unversioned and
compatibility-only language contracts relative to the explicit target without describing them as
invalid. Second, report source forms accepted under an older contract that have a target-language
replacement, using the source-aware frontend so every diagnostic points to the owning member and
span. Third, improve opaque-mapping advice: correlate coverage roots with target checked-mapping
capabilities and explain which declaration families are now available, while keeping the result at
`candidate` until consumer evidence proves a specific wire shape and total binding. If an optional
machine-readable evidence input is introduced, it must record the proposed representation and
codec/binding observations; finite fixtures alone must never be promoted to proof of all values or
retained-history compatibility.

Human output should explain why the usage is old, show a target-language example when one is
sound, name the compatibility work still required, and link to the relevant in-repository guide.
JSON output must have a versioned schema suitable for repository policy. Consumers must be able to
deny selected stable lint codes without treating every candidate or every intentionally opaque
boundary as an error. Results must be deterministic and workspace-atomic: all members are checked
under one target, and a member that cannot be parsed or checked prevents a misleading partial
modernization verdict.

The linter must not mutate sources, bump language preambles, generate bindings, suppress ordinary
validation failures, or claim that an opaque-to-checked change is replay-neutral. It should reuse
the language registry, source index, checked service graph, coverage planner, binding obligations,
and compatibility vocabulary rather than creating a second parser or an independent feature
matrix.

## Acceptance criteria

1. A fixture corpus spanning every supported source-language contract produces deterministic lint
   results against an explicit target. A source already using the target's preferred constructs is
   clean, and repeating the command produces byte-identical JSON.
2. Legacy-unversioned and compatibility-only sources receive a stable advisory that distinguishes
   “still supported” from “recommended for new authoring”; the linter does not redefine release or
   language-support policy.
3. At least one statically provable old source form receives a `definite` replacement with an exact
   source span and target-language example. Single-file and multi-member workspace results agree
   on the same owned construct.
4. A representative opaque optional/container/hash/ID mapping receives a `candidate` finding that
   names the applicable target capability and requires a total binding, byte comparison, Keiro
   compatibility diff, and retained-history audit. It is never presented as an automatic safe fix.
5. Negative fixtures retain honest exclusions: nested nullable optionals report a non-injective
   blocker when that proposed shape is known, and a bespoke flattened union is not recommended as
   a structural union without a total representable shape.
6. Human and versioned JSON output carry stable codes, source ownership, source/target contracts,
   evidence level, remediation, and relevant persisted roots. Selective policy can fail on named
   codes while leaving unrelated candidate findings advisory.
7. Parser, checker, formatter, scaffolder, diff, and generated output remain unchanged by running
   lint. Published language contracts and their compatibility diagnostics stay byte-stable.
8. Documentation explains how lint differs from `check`, `--min-language`, coverage opacity,
   historical-codec comparison, `diff`, and the future IR-5 rewrite workflow.

## Requested deliverables

- A source- and workspace-aware modernization rule engine backed by the authoritative language and
  runtime-capability registries.
- A read-only CLI with human and versioned JSON output, stable codes, evidence levels, and selective
  policy gates.
- Rules and fixtures for language support, superseded source forms, and checked-mapping candidates
  with explicit blocked cases.
- Integration with existing source locations, coverage paths, binding explanations, and
  compatibility terminology.
- An authoring guide and changelog entry that keep detection, compatibility proof, and source
  rewriting as separate steps.

## Consumer evidence

The motivating consumer is `mori://shinzui/rei`. The exact audit and planned adoption are recorded
at
`mori://shinzui/rei/plans/242-replace-eligible-shared-keiro-opaque-mappings-with-checked-declarations`.
The request is intentionally generic: no rule may hard-code Rei type names, codec identities, or
repository paths.
