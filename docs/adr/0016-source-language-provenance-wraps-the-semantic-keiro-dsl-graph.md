---
type: Architecture Decision Record
title: Source language provenance wraps the semantic Keiro DSL graph
description: A .keiro document selects a released parser contract before grammar parsing, while its declared/effective language provenance remains separate from the semantic Spec graph used by validation, composition, and replay analysis.
timestamp: 2026-07-31T17:30:13Z
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

**Version 2 is the first successor contract.** It registers consumer-owned
direct ID/enum/nominal bindings, `Integer`, typed scalar roots, literals,
required structural paths and arithmetic, plus explicit generated-or-Hole
transition ownership. Version 1 rejects the first such token before version-2
semantic checking. Collection expression spellings are reserved but rejected
under version 2; reserving a token is not an implicit language feature.

**Source provenance wraps, rather than inhabits, the semantic graph.** Parsing the full contract
produces a source value containing both `SourceLanguage` and the existing semantic `Spec`.
`Spec`, `validateSpec`, aggregate fold fingerprints, and replay-impact analysis remain concerned
only with the normalized semantic graph. Compatibility entry points that historically return
only `Spec` may remain as documented wrappers, but CLI and workspace loading use the
provenance-preserving entry point.

**Workspace provenance is per member.** Each `WorkspaceMember` retains its own
`SourceLanguage`; `wsMergedSpec` remains the composed semantic graph. Composition compares
effective versions before merging. Legacy-unversioned and declared version 1 may compose because
both select version 1. Different effective versions are refused before graph merge, with member
paths and source locations, so a service cannot accidentally combine two language contracts.

**A declaration-only rewrite is provenance, not behavior.** Rewriting an unchanged legacy source
to declare version 1 is reported by source/workspace inspection, scaffold history, and diff output,
but it produces an all-compatible compatibility vector and remains replay-neutral. It does not
enter an aggregate fold fingerprint or manufacture an event-codec, persisted-identity, or replay
change.

**Scaffold history records provenance additively.** The existing single-file and workspace record
formats already ignore unknown row kinds. New source-language rows therefore extend their v1
headers without replacing the schemas; older readers continue to see the file/module history,
while new readers interpret a missing row as the historically accurate legacy-unversioned state.
These records support provenance and drift reporting. They are not parser-result caches.

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
- Workspace composition preserves truthful member provenance without contaminating the merged
  semantic graph or changing existing validator and fingerprint APIs.
- Adding a new grammar feature requires both a successor registry entry and fixtures proving the
  released predecessor still rejects the new form. This is deliberate maintenance work rather
  than an automatic property of the parser-combinator library.
- A version-2 expression is not accepted merely because its tokens parse. Its
  roots, paths, literals, operators, result type, and transition owner must all
  resolve before generated code is emitted.
- Keeping compatibility wrappers that return `Spec` is safe only because parser dispatch has
  already happened; callers needing provenance must use the source-level API.
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
