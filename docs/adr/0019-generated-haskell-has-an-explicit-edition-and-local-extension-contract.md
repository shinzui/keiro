---
type: Architecture Decision Record
title: Generated Haskell has an explicit edition and local-extension contract
description: The generated manifest owns the compilation baseline and naming edition; generated declarations use checked UpperCamelCase or lowerCamelCase while overwriteable modules declare specialized extensions locally only when needed.
timestamp: 2026-08-05T14:23:30Z
docId: ADR-19
status: Accepted
date: 2026-08-03
---

# 19. Generated Haskell has an explicit edition and local-extension contract

Date: 2026-08-03

Status: Accepted


## Context

`keiro-dsl scaffold` produces overwriteable Haskell modules for a consuming
application, but its build manifest previously listed only modules and package
dependencies. The generated source already relied on an ambient compilation
contract: GHC2024 syntax, pervasive overloaded string literals, and specialized
extensions used by particular module families. Repository conformance tests
compiled under the generator's broader defaults, so they could not prove that a
consumer following the manifest had enough information to compile the output.

Repeating every ambient extension in every generated file would make the output
self-contained, but it would obscure which specialized syntax a module actually
uses. Conversely, placing every observed extension in the shared defaults would
make the manifest unnecessarily broad and allow a missing local declaration to
remain hidden.


## Decision

The generated build manifest owns the complete Haskell compilation contract. It
declares `default-language: GHC2024` and `OverloadedStrings` as the sole
`default-extensions` entry before its module and dependency blocks. Repository
conformance components compile through an independent Cabal common stanza with
exactly the same defaults.

Overwriteable generated modules declare non-baseline syntax locally and only
when the concrete emitted module needs it. The allowed local set is closed:
`BlockArguments`, `DeriveAnyClass`, `DuplicateRecordFields`,
`OverloadedLabels`, `OverloadedRecordDot`, `QualifiedDo`, `TemplateHaskell`, and
`TypeFamilies`. Emitters request those extensions through one typed renderer;
semantic predicates beside each emitter decide conditional cases. Rendering is
deduplicated and lexicographically ordered. A generated module with no local
exception begins directly with its provenance banner.

Tracked generated output is independently checked against the same closed set.
Adding a new local extension or promoting one into the shared contract therefore
requires an explicit synchronized change to the typed vocabulary, manifest and
Cabal defaults, emitter predicates, policy, fixtures, and conformance proof. An
edition upgrade removes edition-provided local declarations instead of also
listing them as redundant defaults.

Overwriteable generated modules carry explicit signatures for every top-level
binding and do not use warning-suppression pragmas. Static imports are selected
by semantic predicates beside their emitters, so the complete tracked corpus
compiles with zero warnings under `-Wall`; generated conformance-package Cabal
files advertise that same warning profile. Warning cleanliness is maintained by
fixing emitted declarations and imports, not by weakening the consumer's
compiler diagnostics.

The generated-Haskell presentation contract also has an additive naming edition in single-file
and workspace scaffold history. Current output uses `idiomatic-v1`; a missing row means the
historical `legacy-v1`. One ASCII segmentation derives all logical names. Module segments, types,
and constructors are UpperCamelCase; values and record selectors are lowerCamelCase. Leading,
trailing, and repeated underscores, generated keywords, and normalized collisions are check-time
errors. A final lexical declaration inventory checks emitted generated modules and newly created
hole stubs before writes, independently of external snake-case strings in their bodies.

Semantic occurrence planning inventories the exact transition-derived top-level helpers before
rendering. If two live transitions would emit the same value declaration, the existing generated
occurrence collision refusal reports the later DSL location with the earlier location as related
evidence and produces no write set. Replay-only transitions do not contribute live acceptance or
forward/replay helper occurrences. As defense in depth, the masked final lexical inventory also
rejects repeated top-level type signatures and repeated type, data, or newtype declarations in a
generated module; one signature followed by its ordinary value binding remains valid. Both gates
run before any single-file or workspace output changes.

The naming edition is Haskell presentation, not a source-language or runtime edition. SQL names,
wire keys/tags, queue names, registry/subscription identities, fingerprints, and other external
spellings retain their declared bytes. Explicit consumer Haskell references are validated but not
normalized. A generated-name-only diff is advisory on the consumer-build axis and replay-neutral.

The generated occurrence reserved set is exactly the words GHC rejects as term-level identifiers
under this compilation contract: `case`, `class`, `data`, `default`, `deriving`, `do`, `else`,
`foreign`, `forall`, `if`, `import`, `in`, `infix`, `infixl`, `infixr`, `instance`, `let`, `module`,
`newtype`, `of`, `then`, `type`, and `where`. Contextual words such as `as`, `family`, `mdo`,
`proc`, `qualified`, `rec`, `safe`, `signature`, `stock`, `unsafe`, and `via` are not reserved by
the closed extension set and remain valid selectors. The committed aggregate-scalars conformance
component compiles all eleven as record selectors under the advertised GHC2024 contract. Direct
fields whose DSL identity is one of the 23 rejected words must declare an explicit Haskell
selector; their wire key and semantic identity need not change.

This automated extension cleanup and ordinary regeneration applies only to overwriteable
`Generated` modules.
Create-once `HoleStub` modules, including behavior holes, application holes,
read-model holes, and consumer binding skeletons, become hand-owned when first
created. Later scaffold runs neither rewrite nor normalize their pragmas.
The only source rewrite is the separately authorized legacy-name migration in ADR 0015, which
backs up the entire original create-once file and rewrites exact module tokens without changing
comments, literals, or its application-owned body.


## Consequences

- A consumer can paste the complete manifest fragment into Cabal and know the
  language edition and default extension required by generated output.
- Every specialized local pragma is evidence of syntax in that module rather
  than inherited historical noise.
- Compiling the complete conformance corpus under the advertised profile catches
  a missing specialized pragma that the generator's broader build defaults would
  otherwise conceal.
- Generated-output policy rejects GHC2024-covered, shared-default, or unapproved
  pragmas before they become fixture drift.
- Hand-owned create-once code is not silently rewritten when the generated
  contract changes; its own declarations remain the application's responsibility.
- A consumer can distinguish a source rebuild from a wire/runtime migration:
  generated naming changes require re-scaffold, recompile, and conformance, but do
  not change persisted identities or replay behavior.
- The reserved-word refusal surface cannot grow merely because a word is contextual in an
  extension the generator does not enable; changing the compilation contract requires reviewing
  and recompiling the complete selector probe.


## Related decisions

- [ADR 0014](0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
  makes the workspace manifest the deterministic build inventory for the whole
  service.
- [ADR 0015](0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  distinguishes overwriteable generated files from create-once hand-owned files.
- [ADR 0017](0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  applies the same generated-versus-Hole ownership boundary to aggregate behavior.
