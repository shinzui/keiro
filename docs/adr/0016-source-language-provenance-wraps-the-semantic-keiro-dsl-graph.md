---
type: Architecture Decision Record
title: Source language provenance wraps the semantic Keiro DSL graph
description: A .keiro document selects a released parser contract, produces located surface syntax, and lowers into a normalized Spec wrapped by source provenance and one effective service semantic contract.
timestamp: 2026-08-02T04:49:52Z
docId: ADR-16
status: Accepted
date: 2026-07-31
---

# 16. Source language provenance wraps the semantic Keiro DSL graph

Date: 2026-07-31

Status: Accepted


## Context

Before this decision, every `.keiro` source started at `context` and was parsed by one grammar into
`Keiro.Dsl.Grammar.Spec`. Nothing in the source says which parser and semantic contract the
author intended. A newer tool can therefore accept syntax that an older tool rejects while both
appear to be reading the same unversioned language.

The `Spec` type is also the semantic graph consumed by validation, scaffolding, diffing, fold
fingerprints, and replay-impact analysis. A service workspace parses several complete member
sources and merges their declarations and nodes into one synthetic `Spec`. Source provenance
cannot be represented honestly by one field on that merged graph: a workspace may contain a
legacy-unversioned member and a member that explicitly declares version 1 even though both select
the same effective grammar.


## Decision

**A source selects its language contract before body parsing.** The first significant clause may
be `language keiro-dsl <positive-decimal>` and must precede `context`. The parser recognizes this
preamble without interpreting body syntax, resolves it through one supported-version registry,
and only then invokes the selected body grammar. Unsupported positive versions fail at that
boundary. Zero, non-decimal values, duplicate preambles, and preambles after `context` are invalid
preambles rather than body-validation errors.

**Version 1 freezes the language present when this decision lands.** A missing preamble remains
readable as `LegacyUnversioned` and selects effective version 1, but it never becomes an explicit
declaration unless a later upgrade operation rewrites the file. Once a language version is
released, new syntax or semantics must be registered under a successor version with its
predecessor relation. Existing version parsers and their rejection fixtures are not widened.

**Accepted language versions and the stable authoring version are distinct registry facts.** Each
`LanguageDefinition` carries a `LanguageSupport` lifecycle value. Exactly one registered entry is
`Stable`; every other released entry is `CompatibilityOnly`. `supportedLanguageVersions` continues
to enumerate every accepted source contract, while `currentStableLanguageVersion` selects the
sole stable entry and fails if the registry has zero or multiple stable entries. New skeletons,
authoring examples, and primary conformance derive their source version from that stable entry.
Language 4 is currently stable; versions 1 through 3 and `LegacyUnversioned` remain readable with
their immutable released meaning and are never silently rewritten. A later stable designation
changes the authoring and primary-test baseline, not the behavior of any predecessor.

**Every registry entry explicitly selects immutable syntax and runtime profiles.** A syntax
profile is an exact named set of grammar capabilities, not a numeric minimum-version rule.
Version 1 selects `keiro-dsl/syntax-profile/1`; versions 2 and 3 deliberately select
`keiro-dsl/syntax-profile/2`, and version 4 deliberately reuses that profile.
Versions 1 and 2 select
`keiro-dsl/runtime-semantics/1`, while version 3 selects
`keiro-dsl/runtime-semantics/2` and version 4 selects
`keiro-dsl/runtime-semantics/3`. Runtime semantics 3 preserves version 3's
aggregate ID and fold projection while enabling the separate public-contract
TypeID admission capability. The parser threads the chosen definition through every production,
and semantic planning reads the runtime discriminator from that same definition. Adding a larger
version number therefore enables neither syntax nor runtime behavior until its registry entry
chooses both values explicitly. The historical minimum-version query remains documentation and
compatibility metadata only.

**Version 2 is the first successor contract.** It registers consumer-owned
direct ID/enum/nominal bindings, `Integer`, typed scalar roots, literals,
required structural paths and arithmetic, plus explicit generated-or-Hole
transition ownership. Version 1 rejects the first such token before version-2
semantic checking. Collection expression spellings are reserved but rejected
under version 2; reserving a token is not an implicit language feature.

**Source provenance and effective runtime semantics wrap, rather than inhabit, the semantic
graph.** Parsing the full contract produces a source value containing both `SourceLanguage` and
the existing semantic `Spec`. After parsing, `CheckedService` pairs that graph with one
`EffectiveLanguageContract`; validation, lowering, scaffolding, harnesses, fold fingerprints,
diff, and replay-impact planning use this checked service boundary. The effective contract records
the selected language version and a runtime-semantics discriminator. Grammar-only versions may
share the discriminator; a successor that can change runtime or fold behavior must receive a new
one. Compatibility entry points that accept only `Spec` remain documented legacy/version-1
wrappers and are not used by CLI or workspace semantic routes.

**Version 4 tightens only declared public contract TypeID fields.** A contract
field that already says `typeid "inc"` generates `KindID "inc"` and enforces the
frozen TypeID-v7 domain at JSON decoding. Valid JSON bytes remain canonical text.
Versions 1 through 3 retain their generated `Text` field and permissive decoder
bytes. Because aggregate fold behavior is unchanged, runtime semantics 3 reuses
the predecessor's aggregate fingerprint segment; service-aware scaffold,
manifest, durable ID-domain, and diff consumers still observe the new contract
capability through `CheckedService`.

**Primary conformance follows the stable registry entry; historical behavior uses named lanes.**
Ordinary feature, negative-validation, diff, workspace, and skeleton fixtures declare the current
stable language. Every compiled stable-primary component is checked against a fresh service-aware
scaffold plan and must carry the stable language banner. Released predecessor syntax, permissive
decoders, and migration-only replay seams remain covered by an explicit, small compatibility
inventory whose source version and unique rationale are machine-checked. Version-independent
comparisons are named separately rather than presented as either stable or historical authoring.

**Parsing and semantic graph construction are separated by located surface syntax.** After source
selection, Megaparsec produces a non-lossless `SurfaceSource`. Its document clauses and ordered
top-level items carry half-open `SourceSpan` values with the source name, `Text` token offset, and
one-based line and column points. The end point immediately follows the last owned syntax token;
trailing whitespace and comments are not part of the span. The surface tree preserves source order
but deliberately does not preserve trivia.

`lowerSurfaceSource` checks span ownership and source order, groups surface items into the existing
`Spec` fields, and projects each top-level span's starting line into its compatibility `Loc`.
`parseSource`, `parseSpec`, and `parseSpecText` route through this seam while retaining their
released signatures and rendered failures. `Spec` equality, workspace composition, semantic
validation, canonical rendering, generated output, fingerprints, diffs, and replay analysis remain
location- and surface-independent. Advanced callers may inspect the surface representation without
depending on Megaparsec types.

Advanced frontend failures are structured before they cross the parser facade. Each failure names
source-selection, body-parsing, or lowering phase; carries a stable frontend or source-language
code, an exact primary `SourceSpan`, a human message, and optional expected-token and supported-
version data. Megaparsec bundles and custom error components remain internal. The released parser
entry points project this data back to their existing `ParseFailure` and byte-pinned rendering;
semantic validator diagnostics remain a downstream, line-compatible contract.

**Workspace provenance is per member; the effective semantic contract is per service.** Each
`WorkspaceMember` retains its own `SourceLanguage`; `wsMergedSpec` remains the composed semantic
graph, and `wsLanguageContract` records the one effective service contract. Composition compares
effective versions before merging. Legacy-unversioned and declared version 1 may compose because
both select version 1. Different effective versions are refused before graph merge, with member
paths and source locations, so a service cannot accidentally combine two language contracts.

**A declaration-only rewrite is provenance, not behavior.** Rewriting an unchanged legacy source
to declare version 1 is reported by source/workspace inspection, scaffold history, and diff output,
but it produces an all-compatible compatibility vector and remains replay-neutral. It does not
enter an aggregate fold fingerprint or manufacture an event-codec, persisted-identity, or replay
change.

**Scaffold history records provenance and the effective contract additively.** The existing
single-file and workspace record formats already ignore unknown row kinds. Source-language and
semantic-contract rows therefore extend their v1 headers without replacing the schemas; older
readers continue to see file/module history. New readers interpret a missing source row as the
historically accurate legacy-unversioned state and derive a missing semantic row from that source
selection. Duplicate, malformed, unsupported, or inconsistent rows are rejected. These records
support attribution and drift reporting. They are not parser-result caches.

Language rewriting is a separate operation. The source-version contract supplies the dispatch
boundary, but sequential `N -> N+1` transformations, atomic workspace rewrites, and Mori-aware
fleet planning remain in
[IR-5](../improvement-requests/add-version-aware-keiro-dsl-upgrade-and-fleet-rewrite-tooling.md).


## Consequences

- Every command that reads a `.keiro` source can reject a future version before current grammar
  or lowering sees it. Parsing a `.keiro-workspace` manifest alone remains a manifest-only
  operation; commands that load its members apply the source gate to each member.
- Existing unversioned sources keep working, while inspection can distinguish intentional version
  declarations from compatibility fallback.
- Accepted does not mean recommended for new work: inspection reports `stable` or
  `compatibility-only`, skeletons emit the sole stable version, and neither path upgrades old
  sources as a side effect.
- Workspace composition preserves truthful member provenance without contaminating the merged
  semantic graph, while exposing one checked contract to every semantic planner.
- Exact source evidence is available before lowering without adding spans or trivia to `Spec`.
  Consumers that operate on semantics continue to use `ParsedSource` or `CheckedService`; tooling
  that needs syntax ownership may opt into `SurfaceSource`.
- Adding a new grammar feature requires both a successor registry entry and fixtures proving the
  released predecessor still rejects the new form. This is deliberate maintenance work rather
  than an automatic property of the parser-combinator library.
- A higher language version does not inherit a predecessor's feature set or runtime semantics by
  ordering. Intentional reuse is visible as the same profile identifier in two registry entries.
- Version 4 demonstrates that a successor runtime profile may preserve the
  predecessor's aggregate-fold projection while changing another checked
  semantic consumer. Fingerprint equality is explicit and does not authorize
  scaffold or diff code to discard `CheckedService`.
- A stable-language release requires migrating the primary conformance inventory in the same
  change. Historical assertions remain executable through named compatibility components instead
  of holding the ordinary corpus on an older source contract.
- Source-aware tools can branch on frontend phase, stable code, and exact span without parsing
  human-readable Megaparsec output; compatibility callers retain the released text.
- A version-2 expression is not accepted merely because its tokens parse. Its
  roots, paths, literals, operators, result type, and transition owner must all
  resolve before generated code is emitted.
- `Spec`-only semantic functions are compatibility bridges with explicit legacy/version-1
  semantics. Source-aware callers construct `CheckedService`; parser dispatch alone is not enough
  once a successor contract can alter runtime behavior.
- No external package dependency is introduced. `Natural`/`NonEmpty` come from existing base
  libraries, and JSON record/inspection encoding uses the already-declared `aeson` dependency.


## Alternatives considered

**Put declared and effective versions directly on `Spec`.** Rejected because a workspace merges
several source documents into one `Spec`; any single value would erase member differences or
invent a declaration for a synthetic graph. It would also invite semantic consumers such as fold
fingerprinting to treat provenance as behavior.

**Treat the installed parser version as the source contract.** Rejected because two tool releases
could then claim to understand the same language while accepting different programs, leaving no
sound dispatch point for upgrades.

**Make the preamble mandatory immediately.** Rejected because it would force an unrelated
cross-repository fleet rewrite before the foundational contract exists. Explicit legacy state
preserves compatibility without lying about what a source declared.

**Have pretty printing add version 1 to legacy sources.** Rejected because ordinary parse/pretty
would become an implicit migration and erase the provenance distinction. Only explicit upgrade
tooling may rewrite the declaration.

**Attach locations directly to every semantic AST value.** Rejected because it would spread source
layout through workspace composition, fingerprints, diffs, replay, and generation. A separate
surface representation makes location ownership explicit and discards it at one lowering boundary.


## Related decisions

- [ADR 0004](0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) places a future
  language rejection before grammar parsing, the earliest boundary with the required evidence.
- [ADR 0014](0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
  keeps `wsMergedSpec` a semantic composition authority while member source metadata stays
  attributable.
- [ADR 0015](0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  defines the append-only, workspace-keyed scaffold history extended with per-member language
  provenance.
- [ADR 0017](0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  defines the behavior-ownership seam introduced by the version-2 expression
  contract.
