---
type: Improvement Request
title: Support nominal IDs inside structural mapped types
description: >-
  Resolve and lower declared IDs inside structural records, unions, and containers with
  the same nominal identity and checked TypeID contract as direct aggregate fields,
  without requiring an opaque codec or a text-keyed replacement model.
timestamp: 2026-09-16T22:10:35Z
requestId: IR-40
status: proposed
origin: mori://tan/notification-render-service
reviews:
  - kind: model
    reviewer: codex-author
    reviewed_at: 2026-09-16T22:10:35Z
    document_timestamp: 2026-09-16T22:10:35Z
    scope: technical-accuracy
    outcome: commented
    provider: openai
    model: unspecified
    effort: unspecified
    context: >-
      Author self-review against Keiro checkout 5b52b684a10c0368fdc00cffc0f131926cce4b10,
      the structural type graph, nominal resolver, TypeID-v7 codec contract, and a minimal
      checker reproduction. This is not independent review or implementation verification.
---

# Improvement Request: Support Nominal IDs Inside Structural Mapped Types

## Status

Proposed. No compiler fix, language-version decision, or warning-policy exception is
implemented by this request. Request ID allocated using `okf id next` with the repository's
`mori/improvement-requests-profile.dhall` profile.

## Context

The notification service's EP-4 models one `NotificationType` aggregate containing multiple
templates. Its consumer-owned structural state has `List TemplateState`; each template record
carries a `TemplateId`. Reviewed rerouting plans also refer to template IDs in nested records,
and expected claim holders may contain an optional ID. These are ordinary domain references,
not opaque vendor payloads.

The consumer explicitly chose natural records with typed IDs. Replacing these records with
text-keyed maps would lose the checked key domain and spread application validation through the
model. Declaring the ID as `mapped opaque` preserves a consumer-owned TypeID implementation but
causes `CoverageOpaqueSurface`; the consumer's strict `--deny-warnings` gate then blocks production
promotion. Relaxing that gate is not the requested solution.

`Optional` of an opaque value is separately rejected by `MappedNonInjectiveNullability`, because
the declared codec may accept JSON null. That conservative rule is not a bug claimed by this
request. A first-class ID has a known non-null JSON text representation, so optional IDs should
not require a tagged-union workaround solely to avoid that opaque boundary.

## Reproduction and Source Evidence

At Keiro checkout `5b52b684a10c0368fdc00cffc0f131926cce4b10` (`keiro-dsl` 0.16.0.0), the following
Language-5 specification fails `keiro-dsl check`:

```text
language keiro-dsl 5
context nested-id-repro

id TemplateId prefix=template

mapped structural record TemplateState {
  haskell package=example-core module=Example.Model type=TemplateState
  binding = "Example.Bindings.templateStateBinding"
  binding-version = "1"
  canonical-type = "example.TemplateState.v1"
  fixtures = "Example.Bindings.templateStateFixtures"
  wire object constructor=TemplateState unknown-fields=reject {
    templateId as "templateId" : TemplateId required
  }
}

aggregate NotificationType
  regs
  states NotCreated Active!
  command Create { template:TemplateState }
  event Created = fields(Create)
  NotCreated -- Create -->
    emit Created
    goto Active
  wire kind=ctorName fields=camelCase schemaVersion=1
```

The diagnostic is `MappedUnresolvedName`: mapped declaration `TemplateState` references
unresolved mapped type `TemplateId`. The same ID is valid as a direct aggregate command/event
field. This is a name-resolution/type-composition limitation, before GHC checks the example
binding symbols.

Source evidence:

- `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`, `resolveTypeGraph`, builds its reference environment
  from `spec.mapped`; `resolveExpr` resolves `TRef` only against that environment. ID declarations
  and mapped nominal scalar declarations do not enter this structural reference environment.
- `keiro-dsl/src/Keiro/Dsl/Validate.hs`, `typeGraphDiagnostic`, renders the resulting
  `TGUnresolvedRef` as `MappedUnresolvedName`.
- `keiro-dsl/src/Keiro/Dsl/NominalType.hs` independently resolves generated and consumer-bound
  nominal declarations for supported direct uses.
- `keiro-core/src/Keiro/Codec/IdDomain.hs` already defines canonical prefix-bearing TypeID-v7
  admission, including the UUID version check. Nested support should reuse this contract.

## Requested Change

Make existing nominal ID declarations usable as leaves of structural mapped type expressions,
including record fields, union payloads, `Optional`, `List`, and text-keyed `Map` values. Preserve
the declared Haskell nominal type, canonical TypeID wire text, prefix and UUID-v7 admission,
and codec ownership through every nesting level. Do not lower the ID to unchecked `Text` or
invoke an arbitrary consumer `ToJSON`/`FromJSON` instance while claiming structural coverage.

Support both generated `id` declarations and the existing consumer-bound `id ... using` form,
with the existing shared declaration ownership rules. The latter is especially useful when a
consumer-owned record should depend on a consumer-owned ID without importing generated aggregate
modules. Generate the necessary structural binding ingredients, imports, codec composition,
fixtures, and conformance obligations without duplicate nominal declarations or cyclic imports.

The same structural lookup boundary also affects existing `mapped nominal` scalars. Assess
those and nominal enums together when designing the resolved representation, and explicitly
state which nominal categories the change supports. Nested TypeIDs are the required consumer
capability; broader scalar/enum composition may be delivered alongside it or tracked separately,
but must not be silently erased to primitive types or mislabeled as opaque. Arbitrary refined
scalar predicates and typed map keys are not required here.

## Acceptance

1. The minimal reproduction checks without `MappedUnresolvedName`; generated-ID and consumer-bound
   ID variants have compiled structural bindings and passing generated conformance tests.
2. A compiled fixture stores `List TemplateState` in aggregate state, accepts/emits that shape,
   replays it, and round-trips snapshots. Additional fixtures cover union ID payloads,
   `Optional TemplateId`, `List (Optional TemplateId)`, and `Map TemplateId` values. Optional absence
   and present IDs remain distinct; existing genuinely null-capable opaque cases remain rejected.
3. Nested decoders accept canonical TypeID-v7 text with the declared prefix and reject wrong
   prefixes, malformed/noncanonical text, non-v7 suffixes, and JSON null where an ID is required.
   Failure diagnostics identify the nested field/container location. Tests prevent fallback to
   arbitrary consumer JSON instances from weakening the contract.
4. Generated/consumer-owned nominal identity is retained in Haskell. Distinct ID declarations
   cannot be interchanged merely because their wire representation is text. Shared workspace
   declarations have one owner and can be referenced from multiple aggregate records.
5. Structural coverage and the consumer graph follow nested nominal dependencies through persisted
   roots, including event-derived consumers. A fully structural fixture containing these IDs
   passes the strict warning gate and the opaque-coverage gate without an exception.
6. Semantic diff and compatibility reporting detect a changed nested ID prefix, domain contract,
   binding identity/version, or supported nominal representation at the affected uses. Existing
   language-version/replay compatibility rules remain explicit; no silent tightening of legacy
   persisted ID contracts is permitted.
7. Single-spec and workspace scaffolding produce compilable, deterministic code and honest binding
   explanations. Repeated generation is stable, with no hand-edited generated files required.
8. Documentation explains supported nested nominal categories, Haskell ownership, fixture duties,
   and migration from an opaque-ID workaround. Unsupported categories have deliberate diagnostics.

## Scope and Compatibility

This extends composition of existing declarations; it does not change the consumer's aggregate
boundary, add automatic command routing, or replace implementation holes with a new domain engine.
It does not require typed map keys, general recursive mapped types, removal of opaque coverage
warnings, or weakening structural nullability checks.

Choose the language-version treatment explicitly using Keiro's existing compatibility policy.
The acceptance target is a supported strict production specification, not merely successful
parsing or a name-table entry. Existing generated code, persisted wire contracts, and consumer
bindings need compatibility evidence.

## Related Work

- [IR-1: Structural consumer-owned types](support-structural-consumer-owned-types-in-keiro-dsl.md)
  established truthful structural codec ownership and nested type reporting.
- [IR-14: Enforceable ID domains](make-id-prefix-declarations-enforceable-and-evolution-safe.md)
  supplies the TypeID contract that must also apply when the ID is nested.
- [IR-12: Nominal equality](make-nominal-id-and-enum-equality-first-class-in-aggregate-expressions.md)
  concerns expression capabilities; this request concerns structural composition and codecs.
- Consumer implementation plan:
  `mori://tan/notification-render-service/plans/4-event-sourced-notification-type-aggregate-with-template-drafts-and-revisions`.
