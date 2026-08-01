---
type: Improvement Request
title: Support composable multi-file service specifications in keiro-dsl
description: >-
  Let one Keiro service keep complete aggregates in separate .keiro files while resolving shared
  declarations, validating the whole service, and scaffolding context-level outputs atomically.
timestamp: 2026-08-01T00:14:56Z
requestId: IR-2
status: planned
origin: mori://shinzui/mori
plan: docs/plans/168-give-shared-workspace-nominal-declarations-one-generated-haskell-owner.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T23:44:22Z
    document_timestamp: 2026-07-31T23:44:22Z
    scope: technical-accuracy
    outcome: changes-requested
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Keiro 0.6.0.0 workspace check/scaffold exercise against Mori's two-aggregate service found
      that one resolved shared declaration is emitted as incompatible nominal types in both
      generated aggregate modules, failing IR-2 and ADR-0014 acceptance.
---

# Improvement Request: Support Composable Multi-File Service Specifications in `keiro-dsl`

## Status

**Planned, with a release-blocking acceptance failure in Keiro 0.6.0.0.** The corrective work is
owned by [Plan 168](../plans/168-give-shared-workspace-nominal-declarations-one-generated-haskell-owner.md)
under [MasterPlan 27](../masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md).
This request belongs to
`shinzui/keiro` and originates from Mori MasterPlan 22. The workspace checker and atomic scaffold
entrypoint have landed, but the generated Haskell does not yet satisfy the single nominal type
requirement below. Mori must not adopt the workspace scaffold until that identity split is fixed.


## Keiro 0.6.0.0 Implementation Finding

Scaffolding Mori's two-member Project workspace with Keiro 0.6.0.0 emits independent declarations
of `ProjectId` and `ProjectArtifactKind` in both
`Mori.Modules.Project.Generated.Domain` and
`Mori.Modules.ProjectArtifact.Generated.Domain`. The workspace resolver therefore has one logical
declaration, but generated consumers receive two incompatible Haskell types. It also emits the
shared enum in an aggregate that does not use it.

This is not merely a module-layout preference: it fails this request's acceptance requirement to
"produce one nominal generated type for a shared declaration such as `ProjectId`" and ADR-0014's
single-authority rule. The fix must give a shared declaration one generated owner and make every
aggregate module import that same nominal type. A version-2 consumer binding may intentionally
select an existing consumer-owned type, but it must not be required to hide duplicate default
generation.


## Context

`keiro-dsl` currently parses and operates on one `Spec` from one file per CLI invocation. A file
may contain one or several aggregates. Fleet practice uses both shapes: Kotei keeps aggregates in
separate `.keiro` files under one `kotei` context, while Danwa and Keiro's examples place several
aggregates in one file.

The missing capability is not permission to create several files. It is composition of those
files as one service contract. Separate invocations do not share IDs, enums, mapped structural
declarations, read models, or a resolved type graph. They cannot validate duplicate names,
cross-node references, generated paths, or compatibility consequences across the service.

Scaffolding exposes a more concrete collision. The scaffold record and manifest are named only by
context, and mapped structural declarations emit one context-level `StructuralProjections`
facade. Scaffolding two same-context specs into one output tree can therefore replace shared state,
report the other spec's files as stale, or overwrite a context-level generated module from an
incomplete graph. Using different contexts avoids the collision but falsely turns aggregate file
ownership into a generated namespace and read-model identity decision.

Mori needs a Project root aggregate and a ProjectArtifact aggregate. Keeping one complete
aggregate per file is easier to review and gives plans unambiguous ownership, but both aggregates
belong to the same service and share `ProjectId`, module policy, compatibility gates, and generated
context surfaces. This is a general fleet need, not a Mori-specific grammar special case.


## Design Principles

1. **One service graph, many source files.** All selected files resolve into the same semantic
   graph before validation, diffing, scaffolding, or harness generation.
2. **Aggregate ownership stays whole.** One aggregate definition has one owning source file.
   Cross-file partial aggregate merging is not required by this request.
3. **Composition is semantic, not textual.** The tool should not depend on order-sensitive text
   inclusion or macro expansion.
4. **Shared declarations have one authority.** IDs, enums, rules, mapped types, read models, and
   other service-level declarations resolve once, with duplicate and conflict diagnostics.
5. **Generated context surfaces are atomic.** A whole-service scaffold plans collisions and stale
   files before writing, then emits each context-level artifact once from the merged graph.
6. **Single-file use remains valid.** Existing commands and specifications continue to work as a
   one-member service workspace.


## The Request

Add a first-class service-workspace input to `keiro-dsl`. The exact syntax belongs to Keiro. It
may be a small manifest, repeated `--spec` options, a directory entrypoint with an explicit file
list, or another deterministic form. It must identify:

- the service/context identity;
- shared module-root and layout policy;
- an ordered or canonically sorted set of `.keiro` source files;
- the ownership location of shared declarations, if they are not declared in the manifest; and
- one stable workspace identity for scaffold and compatibility history.

The semantic result is one resolved `ServiceSpec` or equivalent graph. Source order must not
change its meaning or generated bytes. Every declaration and node retains its source file and span
for diagnostics.

### Composition and name resolution

The composer must:

- require compatible context, module-root, and layout policy across member files, or move those
  clauses to the workspace authority;
- resolve service-level IDs, enums, rules, mapped structural/opaque types, read models, and node
  references across files;
- produce one nominal generated type for a shared declaration such as `ProjectId`;
- reject conflicting declarations, duplicate node names, case-folded generated-path collisions,
  ambiguous references, and a source file assigned to two workspaces;
- reject two files that define or partially define the same aggregate; and
- report every diagnostic with all relevant source locations.

Identical repeated declarations should not silently merge. Keiro should either require one owner
or define an explicit, validated re-export mechanism. Avoiding accidental first-wins behavior is
more important than minimizing manifest syntax.

### Whole-service commands

Provide whole-service equivalents of the current operations:

```text
keiro-dsl check <service-workspace>
keiro-dsl scaffold <service-workspace> --out <directory>
keiro-dsl diff <service-workspace> --since <revision>
```

The spelling is illustrative. `check` must validate the merged graph, including cross-file
references, generated paths, read-model identities, binding obligations, coverage, replay-head
rules, and all existing node-specific validation.

`diff` must compare two complete workspace graphs. It must classify shared-declaration changes at
every use site, retain file-aware diagnostics, and emit one compatibility vector, coverage report,
and replay-impact report for the service. Adding or renaming a source file without changing the
semantic graph is not a wire break, although it may be reported as an ownership move.

### Atomic scaffolding and history

`scaffold` must plan the complete generated module set before writing. It must emit:

- aggregate-specific generated rings and create-once Holes from their owning files;
- one context-level structural-projection facade from the merged mapped-type graph;
- one context-level replay-audit or other service assembly module where applicable;
- one manifest and scaffold record keyed by stable workspace identity; and
- binding, fixture, package, import, and constraint obligations from the complete graph.

Stale-file detection compares the previous whole-workspace module set with the new whole-workspace
set. Running the workspace twice is idempotent. A refusal, collision, parse error, or validation
error is detected before any generated file, manifest, or record is changed. The record retains
source ownership so moving an aggregate between files does not misclassify its unchanged modules
as another specification's stale output.


## Illustrative Service Shape

The following is semantic, not a commitment to grammar:

```text
service mori-project
  module Mori.Modules.Project
  layout collocated
  shared domain/shared.keiro
  specs {
    domain/project.keiro
    domain/project-artifact.keiro
  }
```

`shared.keiro` could own `ProjectId` and declarations used by both aggregates. An equally valid
design could place the shared declarations in the manifest or give one member file explicit
export ownership. The important property is one resolved authority, not the location or spelling.


## Compatibility and Migration

An existing single `.keiro` file is treated as a one-member workspace with unchanged generated
module names and wire behavior. Existing multi-file repositories can adopt a workspace by listing
their current files; when the semantic context and module policy are unchanged, aggregate-specific
generated modules should remain byte-stable.

If current same-context independent scaffolds have separate or overwritten records, the first
workspace scaffold must provide an explicit adoption path. It may import the existing manifests,
require a reviewed baseline, or emit a migration report, but it must not silently claim ownership
of hand-written files or delete anything.

The workspace identity belongs in compatibility and scaffold records. A context rename, module
root move, or aggregate ownership move is reported separately from private-event wire evolution.


## Out of Scope

IR-2 does not request:

- partial aggregate declarations spread across files;
- order-sensitive textual includes, macros, or lifecycle templates;
- dynamic runtime loading or plugin discovery;
- cross-service private-type sharing;
- weakening the generated-ring/Holes firewall; or
- treating separate bounded contexts as one workspace merely because they share a repository.


## Acceptance

The request is complete when Keiro demonstrates all of the following:

- a fixture service contains two aggregate files under one context and one shared ID declaration;
- either aggregate can reference shared enums, mapped types, and read models according to the
  chosen ownership rules;
- whole-service `check` catches duplicate aggregates, conflicting shared declarations,
  cross-file unresolved references, and generated-path collisions with file/line diagnostics;
- whole-service scaffolding emits both aggregate rings, exactly one context-level structural
  facade, and one workspace manifest/record without stale false positives;
- changing one aggregate preserves the other aggregate's generated files and scaffold history;
- a failed second-file parse, validation, or collision leaves the output tree and workspace record
  unchanged;
- whole-service `diff` propagates a shared structural-type change to every affected aggregate and
  replay root;
- reordering manifest members and repeating scaffold produce byte-identical output;
- existing single-file CLI behavior and golden fixtures remain compatible; and
- a fleet-style same-context per-aggregate example, such as Kotei's layout, can adopt the workspace
  without combining its aggregate sources into one file.


## Requested Deliverables

1. A durable design decision for workspace identity, shared-declaration ownership, and atomic
   scaffold history.
2. Parser/loader and resolved-graph support with source-aware diagnostics.
3. Whole-service `check`, `scaffold`, and `diff` entrypoints.
4. Unit, golden, property, and filesystem tests covering composition, collision refusal,
   idempotence, and migration from independent specs.
5. Updated DSL adoption and scaffolding documentation with both one-file and per-aggregate service
   layouts.
