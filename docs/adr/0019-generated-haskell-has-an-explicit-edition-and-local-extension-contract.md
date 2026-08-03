---
type: Architecture Decision Record
title: Generated Haskell has an explicit edition and local-extension contract
description: The generated manifest owns a GHC2024 plus OverloadedStrings compilation baseline, while overwriteable modules declare specialized extensions locally and only when their emitted syntax needs them.
timestamp: 2026-08-03T16:33:13Z
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

This automated cleanup applies only to overwriteable `Generated` modules.
Create-once `HoleStub` modules, including behavior holes, application holes,
read-model holes, and consumer binding skeletons, become hand-owned when first
created. Later scaffold runs neither rewrite nor normalize their pragmas.


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


## Related decisions

- [ADR 0014](0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
  makes the workspace manifest the deterministic build inventory for the whole
  service.
- [ADR 0015](0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  distinguishes overwriteable generated files from create-once hand-owned files.
- [ADR 0017](0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  applies the same generated-versus-Hole ownership boundary to aggregate behavior.
