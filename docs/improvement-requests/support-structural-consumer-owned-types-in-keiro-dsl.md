---
type: Improvement Request
title: Support structural consumer-owned types in keiro-dsl
description: >-
  Let checked Keiro specifications bind nested consumer-owned Haskell domain types to truthful
  structural wire contracts without lossy surrogates or duplicate business models.
timestamp: 2026-07-28T16:54:33Z
requestId: IR-1
status: completed
origin: mori://shinzui/mori
plan: docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-28T02:32:33Z
    document_timestamp: 2026-07-28T00:11:06Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: xhigh
    context: >-
      In-repository review at mori://shinzui/keiro against Mori-resolved Keiki and Keiro source,
      deliberate Keiki constraints, and the Keiro runtime architecture principles.
---

# Improvement Request: Support Structural Consumer-Owned Types in `keiro-dsl`

## Status

**Implemented.** [MasterPlan 25](../masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md)
and its completed child plans delivered the resolved structural/opaque type graph, total bindings,
generated codecs, conformance harness, usage-aware diffing, binding ergonomics, and documentation.
Keiro/keiro-core/keiro-dsl 0.4.0.1 and Keiki 0.4.0.0 supplied the first authoritative published
line with matching upstream tags.

Mori's historical
`mori://shinzui/mori/plans/171-extend-keiro-dsl-for-structural-mori-domain-contracts` was cancelled
because the generic prerequisite had already shipped; its downstream adoption proof moved to
`mori://shinzui/mori/plans/172-replace-the-project-mirror-with-functional-event-sourced-aggregates`.
No external-decider or event-mirror mode was added.

The architecture review found that consumer-owned values are compatible with Keiki when they are
copied, stored, and emitted as whole values. The blocking design issue was codec ownership: a Keiro
declaration cannot truthfully claim structural control while delegating the same structure to an
arbitrary consumer `ToJSON` or `FromJSON` instance. This revision separates structurally checked
bindings from deliberately opaque external codecs.

That separation does not mean hand-written services lose replay soundness. Keiki validation and
Keiro's validated-stream boundary protect the machine that actually runs in either authoring
path; the DSL adds cross-version evolution evidence on top. The stricter mapping contract exists
so that extra layer never reports confidence about a wire shape the runtime does not execute. The
[guarantee ledger](../guides/dsl-guarantees-and-hand-written-services.md) states the boundary in
adopter-facing terms.

The originating Mori EP-171 retained the earlier passthrough-codec assumptions as historical
context, then was cancelled after verifying the released contract. Its remaining downstream
cutover obligations were transferred to
`mori://shinzui/mori/plans/172-replace-the-project-mirror-with-functional-event-sourced-aggregates`.


## Context

`keiro-dsl` can currently scaffold aggregate fields built from text, integers, booleans, IDs,
enums, and the generated vertex. Real consumer domains also carry nested records and tagged
unions containing optional values, lists, maps, natural numbers, timestamps, and deliberately
opaque JSON leaves. Mori's Project and ProjectArtifact commands and private events are one
concrete consumer, but this is a general DSL contract gap rather than a Mori-specific special
case.

Treating those values as `Text` is lossy. Treating them as unexamined external types is honest
only when Keiro also treats their wire representation as opaque. Otherwise `keiro-dsl diff
--since` can classify a declared shape that is unrelated to the codec that actually runs, and a
generated harness can certify selected round trips without proving that the declaration describes
the consumer's wire format.

Replay soundness is already enforced below the DSL for every service by Keiki's
`validateTransducer` and Keiro-core's `ValidatedEventStream` boundary. The DSL's distinct
contribution is comparing versions of a declared contract before deployment. IR-1 is strict
because a structural diff over a schema the executed codec does not honor creates false
confidence, which is worse than the sanctioned hand-written path making no structural diff claim
at all. See [The Guarantee Ledger](../guides/dsl-guarantees-and-hand-written-services.md) for the
full layered account.

Generating duplicate business records inside the scaffold is also undesirable. Consumers already
own domain types, invariants, optics, and construction policy. Keiro should describe and check the
wire contract while generated modules import and use the existing domain type. A private generated
wire representation or type-level shape used only by a codec adapter is not a second business
model.


## Design Principles

1. **One wire-schema authority.** A structurally checked mapping uses a Keiro-owned generated
   codec. An arbitrary consumer codec is supported only through an explicitly opaque mapping.
2. **Consumer ownership remains nominal.** Generated command, event, and register types use the
   consumer's Haskell type; Keiro does not generate a competing business type.
3. **Bindings are typed and explicit.** The consumer supplies total construction/destruction
   adapters or an equivalent typed binding between its type and the declared structural shape.
4. **Compatibility is usage-aware.** Private event history, snapshots, queues, and public
   integration contracts do not share one universal evolution rule.
5. **Keiki structure remains visible.** Whole values may be copied through command fields, event
   fields, and registers, but this capability does not introduce opaque collection guards or
   first-class nested collection mutation.
6. **Public contracts keep their boundary.** A producer's private domain type is not exported as a
   public integration-contract type merely because the shapes are similar.


## The Request

Add a resolved type-expression graph and two explicit kinds of consumer-owned type binding to
`keiro-dsl`.

### Structural mapped types

A structural mapped declaration associates a record, enum, or tagged union with:

- its Cabal package, Haskell module, and Haskell type;
- a stable application-owned type identity for snapshot shape and diagnostics;
- a typed binding that converts between the consumer type and the declared shape;
- an explicit wire representation, including field keys, union encoding, and arm tags; and
- fixture construction and, when used as a register, an explicit initial-value binding.

Keiro generates the nested encoder and decoder from the declared wire shape. The binding supplies
the typed construction and destruction boundary; it does not supply a second independent JSON
schema. Existing consumer `ToJSON` and `FromJSON` instances may be tested for equivalence or used
behind an opaque binding, but their presence alone does not establish structural conformance.

The exact surface syntax belongs to Keiro, but it should express semantics equivalent to:

```text
mapped structural record DocInfo
  haskell package mori-core
  haskell type Mori.Modules.Project.Domain.Aggregate.DocInfo
  binding Mori.Modules.Project.Domain.KeiroBindings.docInfo
  canonical-type "mori.project.DocInfo.v1"
  fixture Mori.Modules.Project.Domain.KeiroBindings.sampleDocInfo
  wire object {
    key         as "key"         : Text                  required
    kind        as "kind"        : DocKind               required
    audience    as "audience"    : DocAudience           required
    description as "description" : Optional Text         on-missing=null
    location    as "location"    : DocLocation           required
    packageName as "packageName" : Optional Text         on-missing=null
  }

mapped structural union DocLocation
  haskell package mori-core
  haskell type Mori.Config.Types.DocLocation
  binding Mori.Modules.Project.Domain.KeiroBindings.docLocation
  canonical-type "mori.config.DocLocation.v1"
  fixture Mori.Modules.Project.Domain.KeiroBindings.sampleDocLocation
  wire tagged-object tag-field="tag" contents-field="contents" {
    LocalFile as "local_file" Text
    LocalDir  as "local_dir"  Text
    RepoPath  as "repo_path"  Text
    LocUrl    as "loc_url"    Text
    Canonical as "canonical"  Text
  }
```

The example is semantic rather than a commitment to spelling. The final design must verify the
actual `mori-core` golden representation; constructor names alone are not a complete union wire
contract.

### Opaque external-codec types

An opaque declaration associates a Haskell type with an external codec identity and version or
fingerprint. Generated code may use the consumer's `ToJSON` and `FromJSON` instances in this mode,
but Keiro does not recursively classify the codec's internal JSON shape.

Changing the opaque codec identity or version, or crossing between opaque and structural modes,
is breaking. An explicit `Json` leaf inside a structural declaration is the nested form of the
same policy: Keiro checks where the opaque boundary exists but makes no compatibility claim about
the value below it.

### Type expressions and wire semantics

Nested type expressions must support:

- optional values, with nullability distinct from missing-key behavior;
- lists and maps with text keys;
- natural numbers with a defined non-negative range and JSON-number representation;
- timestamps with a pinned Haskell type and wire format;
- nested mapped records, enums, and unions;
- existing DSL IDs and enums when their nominal Haskell types match the binding; and
- an explicit `Json` leaf whose internal structure is intentionally opaque.

Every record field declares its wire key, presence requirement, nullability, and optional
on-missing default separately. Every union declares its encoding strategy, discriminator and
payload keys where applicable, and a stable wire tag for every arm. A default is a decode policy,
not merely documentation.

One resolved graph must drive name resolution, validation, pretty-printing, structural diffing,
scaffolding, generated manifests and scaffold records, codecs, replay impact, and the generated
conformance harness. All consumers of the graph must use one total traversal registry so adding a
new type-expression constructor cannot silently omit a subsystem.


## Usage Boundaries

Structural consumer-owned types may appear in private aggregate commands, private events, and
registers. They may also appear in internal process, queue, snapshot, or projection surfaces when
the owning node has an explicit codec and evolution policy for that use.

Public integration contracts must not directly expose a producer-internal domain type. Keiro may
reuse the structural schema to generate or bind a contract-owned DTO, but the private-to-public
mapping remains explicit and hand-owned. Public contract evolution is evaluated from the
consumer's compatibility direction, independently of private event replay.

Generated imports must point at modules below the generated ring and must not introduce a Haskell
module cycle. The manifest records required packages and consumer modules. External imports are
not stale generated modules; stale-file reporting continues to cover only files previously emitted
by the scaffold.


## Keiki and Functional Event-Sourcing Constraints

This capability exists to let generated Keiro structure participate in the real aggregate model.
It must not add an external-decider mode, an `Insert<Event>` escape hatch, a register-free event
mirror, or a second hand-written decide/evolve pair. Commands are still decided by the hand-owned
Keiki transducer in the generated Holes module, and emitted private events must reproduce forward
register state through structured replay.

Mapped values are whole values in Keiki's symbolic language:

- a command field may be copied wholesale to an event field or register;
- a register may be compared or emitted only where the required Haskell constraints exist;
- no nested field lookup, map membership, element update, collection fold, or quantified guard is
  added by this request; and
- a mapped value needed to recover a command must be present as an invertible field in the first
  emitted private event of a multi-event edge.

The validator must reject DSL constructs that claim solver-visible nested collection semantics.
Equality or ordering guards over mapped types outside Keiki's curated symbolic set must be rejected
or carry an explicit opaque-guard diagnostic and audit obligation; compilation alone is not proof
of determinism. `Natural` is not currently in Keiki's curated symbolic set, whereas `UTCTime` is,
so merely adding those type names to Keiro does not give them identical guard semantics.

A mapped type used by generated private events must provide the constraints required by the
generated ring, including `Eq`, `Show`, and the selected codec binding. Snapshot-bearing mapped
registers additionally require `ToJSON`, `FromJSON`, and a stable `CanonicalTypeName`. Every mapped
register requires an explicit initial value; Keiro must not invent `Default` instances or emit a
latent `error` as a valid initial aggregate state.


## Evolution Contract

`keiro-dsl diff --since` must recursively inspect structural mappings at every use site and report
the complete path from the persisted or public root to the changed nested declaration. It compares
wire identities rather than assuming that Haskell selector or constructor names are wire names.

The classification depends on the owning surface:

- For a new decoder reading existing private history, adding a field is additive only when an
  explicit on-missing default preserves the old meaning. Otherwise the containing event or
  snapshot requires a versioned migration.
- Adding a union arm is not universally additive. It may be backward-readable for existing private
  history, but emitting the new arm can break an older binary or a closed public consumer. The
  differ must attach the appropriate rollout advisory or breaking public-contract result.
- Removing or changing a replay-relevant private-event field is replay-affecting even when the JSON
  decoder would ignore the historical key.
- A Haskell module/type binding change is a source/build compatibility change. It is reported
  separately from a wire-schema change, although either may gate a release.
- Renaming a Haskell field or constructor while pinning its existing wire key or tag is not by
  itself a wire break. Renaming the wire identity is breaking unless an outer migration handles it.
- Removing an on-missing default, changing a field's wire type, changing presence or nullability,
  changing union encoding, or crossing the structural/opaque boundary is breaking.
- Changing an opaque codec identity or version is breaking because Keiro cannot inspect the
  internal compatibility claim.

A nested breaking change propagates to every containing private event, snapshot, queue payload, or
public contract. Each affected outer root must supply its own version bump, upcaster, or deployment
obligation. Replay-impact JSON must name affected aggregate event types and snapshot streams rather
than reporting only the mapped declaration.


## Validation and Scaffolding Contract

`keiro-dsl check` must reject:

- unresolved or ambiguous type and binding names;
- duplicate record wire keys, duplicate union arm names, or duplicate union wire tags;
- recursive structural mappings and unbounded structural recursion;
- unsupported map keys or unsupported wire encodings;
- missing package/module/type, binding, stable type identity, fixture, or required initial value;
- invalid Haskell package, module, type, and binding names;
- conflicting imports, aliases, generated paths, or package declarations;
- structural declarations whose defaults are ill-typed for the field; and
- mapped uses that request unsupported Keiki guard or update semantics.

The scaffold firewall continues to prevent generated decision logic. It also checks that generated
imports use the resolved binding plan and do not collide. Manifests include consumer package and
module requirements. Scaffold records retain binding identities so a subsequent run can report
binding drift, while stale-module checks remain limited to scaffold-owned files.

Haskell compilation is the final check that consumer bindings have the promised types and
instances. `keiro-dsl check` must not claim to inspect arbitrary Haskell source or prove arbitrary
instance behavior.


## Conformance Harness Contract

The generated harness obtains real mapped values from declared fixture bindings rather than
inventing values for arbitrary consumer types. For each structural mapped type and containing
private event it must exercise:

- structural binding round trips between the consumer value and declared shape;
- generated JSON codec round trips and pinned JSON golden fixtures;
- missing-field defaults, null handling, unknown-field policy, and every union arm;
- outer event tags, schema versions, and historical upcaster goldens; and
- forward stepping followed by structured replay of the emitted event chain, comparing both the
  final vertex and every register value.

The aggregate conformance package must run `validateTransducer`, the opaque-guard audit, codec
tests, and forward/replay equality. A mapped value read by a state update but omitted from the
first emitted event must make validation or the replay assertion fail.


## Acceptance

The request is complete when all of the following are demonstrated in Keiro:

- parser/pretty-printer round trips cover structural and opaque declarations, every supported
  type expression, explicit wire metadata, defaults, and JSON leaves;
- negative fixtures reject unresolved, recursive, duplicate, unsupported, binding-incomplete,
  guard-opaque, and import/package-collision declarations;
- evolution fixtures distinguish wire, binding, replay, rollout, and public-contract changes with
  stable diagnostic codes and complete usage paths;
- mutation tests prove an unvisited nested field or union arm makes the diff, codec, or harness
  suite fail;
- a conformance package supplies hand-owned sample types and bindings, scaffolds the complete
  generated ring, compiles one create-once Holes transducer, and passes structural-codec and
  forward/replay tests;
- an opaque-codec fixture proves that Keiro does not make nested compatibility claims across the
  declared opaque boundary;
- generated modules import consumer-owned private types without generating competing business
  models, while public contracts retain contract-owned Haskell types;
- manifests name required consumer packages and modules and scaffold records detect binding drift;
  and
- the capability is released and tagged so consumers can pin an authoritative version.

Mori provides the downstream compatibility proof from EP-171: `domain/mori.keiro` describes a
representative Project root payload, the actual current `DocInfo` and `DocLocation` shapes, and an
artifact payload union. The generated probe compiles against `mori-core`, pins real JSON goldens,
and uses no lossy string conversion or duplicate business type.


## Compatibility Baseline

The architecture review verified the authoritative releases before revising this request:

- `keiki` is released and tagged at `0.3.1.0`;
- `keiro-dsl` is released and tagged at `0.3.0.0`; and
- the current local Keiro checkout contains post-`0.3.0.0` unreleased DSL evolution work.

Implementation must repeat the Hackage and upstream-tag check before choosing dependency bounds or
declaring the capability released.


## Out of Scope

- Implementing Mori's Project root or ProjectArtifact transducers; that remains Mori work after
  this capability is released.
- Generating consumer business types that already exist.
- Inferring structure from arbitrary Haskell source or runtime reflection.
- Proving that an arbitrary external `ToJSON` or `FromJSON` instance matches a structural
  declaration.
- Treating arbitrary JSON internals as structurally compatible.
- Adding first-class collection mutation or solver-visible nested collection predicates to Keiki.
- Exporting producer-private domain types as public integration contracts.
- Supporting an external legacy decider, event insertion command, or event-mirror architecture.


## References

- Origin plan:
  `mori://shinzui/mori/plans/171-extend-keiro-dsl-for-structural-mori-domain-contracts`
- Mori architecture decision:
  `mori://shinzui/mori/okf/adrs/concepts/ADR-6`
- Keiro package:
  `mori://shinzui/keiro/packages/keiro-dsl`
- Keiki package:
  `mori://shinzui/keiki/packages/keiki`
- Runtime guidance:
  `mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption`
- Collection and opaque-guard guidance:
  `mori://shinzui/keiro-runtime-patterns/docs/keiki-collections-and-opaque-guards`
- Structured replay guidance:
  `mori://shinzui/keiro-runtime-patterns/docs/keiki-structured-replay-and-hydration`
