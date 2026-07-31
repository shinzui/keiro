---
type: Architecture Decision Record
title: Structural consumer mappings use one schema authority and total bindings
description: Keiro-generated structural shapes own private-event wire policy; aggregate scalar capabilities and structural mappings each resolve through one checked schema authority, consumer bindings are total isomorphisms, snapshots remain separately invalidated, and Keiki projections come from that authority.
timestamp: 2026-07-31T14:39:19Z
docId: ADR-12
status: Accepted
date: 2026-07-28
---

# 12. Structural consumer mappings use one schema authority and total bindings

Date: 2026-07-28

Status: Accepted


## Context

Keiro's DSL can describe the private events and register shapes from which it
generates code, but consumers often already own nominal Haskell domain types.
Reusing an arbitrary consumer `ToJSON` or `FromJSON` instance would create a
second wire-schema authority that `keiro-dsl diff` cannot inspect. Conversely,
making conversion from a generated structural shape return `Either Text a`
would let the consumer hide additional validity rules behind an apparently
structural declaration. Those rules would also be invisible to the DSL.

Snapshots require a separate distinction. The current state codec serializes
the register file through its consumer `ToJSON` and `FromJSON` instances. A
generated private-event codec therefore does not, by itself, become the
snapshot codec. The snapshot is a rebuildable cache protected by the
three-component discriminator in ADR 0003, not another claim that the DSL owns
all serialization of the consumer type.

Keiki 0.4 adds typed symbolic field projections through `FieldProjection`,
`FieldWitness`, `regProj`, and `inpProj`. The validator permits these
projections only in guards and only from a direct register or matched input
field. Projection results must belong to Keiki's curated symbolic registry;
ordered comparisons require its still-smaller ordering registry. Keiki validates
the symbolic term and supplies `fieldWitnessAgrees` for concrete agreement tests, but it intentionally cannot prove
that a consumer-written witness came from the same schema as Keiro's codec.

Direct aggregate types had a parallel authority problem. Parsing, validation,
Haskell rendering, imports, Cabal dependencies, initial values, deterministic
samples, codecs, snapshots, fingerprints, diffs, replay impact, and scaffold
refusals each carried independent allowlists. A type could therefore pass
`check` and still fail or become partial during generation.


## Decision

Aggregate command fields, event fields, and registers resolve through one
aggregate type authority before lowering. The resolution canonicalizes source
aliases, preserves the established bare-field inference order, and classifies
each use site as `SolverVisible`, `OpaqueOnly`, or `Unsupported`. All generated
type, import, package, initial, codec, snapshot, sample, compatibility, and
fingerprint consumers use that resolved value; they do not reconstruct support
from a raw type name.

`Time` and `UTCTime` are one resolved `Time` identity. Direct `Time` and
`Natural` are solver-visible for equality and ordering, while Natural numeric
arithmetic is deliberately not inferred from those capabilities. Direct
`Json`, `Optional`, `List`, and `Map` remain unsupported aggregate shapes and
must cross the structural-mapping boundary described below. A clean checked
spec has total deterministic lowering; scaffolding retains a refusal only as an
internal invariant defense.

A structural mapped type has exactly one wire-schema authority: its `.keiro`
declaration, resolved into a generated shape and executed by the generated
private-event codec. The consumer-facing conversion is codec-agnostic and is a
total isomorphism:

```haskell
data StructuralBinding domain shape = StructuralBinding
  { bindingToShape   :: domain -> shape
  , bindingFromShape :: shape -> domain
  }
```

The conformance API checks both laws for declared fixtures:

```haskell
bindingDomainRoundTrip :: Eq domain => StructuralBinding domain shape -> domain -> Bool
bindingShapeRoundTrip  :: Eq shape  => StructuralBinding domain shape -> shape -> Bool
```

JSON decoding may fail while parsing bytes into the generated shape, but
conversion from a valid shape may not add another rejection. If a consumer
type has an invariant that the structural grammar cannot express, the schema
must be refined until every shape is valid or the type must use the honest
opaque mode. A future refined mode would need an explicit, diff-visible
contract; it must not be smuggled into `bindingFromShape`.

Each structural declaration carries a mandatory application-owned `binding-version`. It must
change whenever the domain↔shape behavior changes, even if the Haskell symbol and type do not.
The token is diff-visible, recorded as mapping provenance, and included in mapped-register
snapshot invalidation. Keiro does not attempt to hash or inspect arbitrary Haskell source.

The structural grammar also rejects wire encodings that cannot be inverted independently of a
consumer binding. In version 1, `Optional T` may not wrap `Json`, another `Optional`, or an opaque
mapped declaration because those inner values may already encode as JSON null. Tagged-object tag
and contents keys must be distinct. Parser declarations may be incomplete for useful diagnostics,
but the resolved graph exposes only checked declarations with all mandatory facts present.

The landed spec layer exposes total folds over checked mapped declarations, structural shapes,
and nested type expressions. Adding a new constructor therefore requires every checker, differ,
fingerprinter, golden synthesizer, and later generation consumer to handle it at compile time.
The graph records transitive reachability and every complete command, event, and register root
path. Its wire fingerprint contains only schema authority facts; Haskell selector and source
names remain consumer-build provenance rather than wire identity. Recursive diff expands a leaf
change through those root paths so event migration, snapshot invalidation, and consumer build are
not conflated.

Spec-only golden synthesis runs the same total folds over the checked old shape. Such a payload is
explicitly labelled a synthesized weak stand-in because no consumer codec or historical bytes ran.
It is useful for scaffolding and shape coverage, but a hand-captured historical payload is stronger
evidence and is never overwritten.

The generated code also checks that each consumer `CanonicalTypeName` value
equals the declaration's `canonical-type`. Keiro does not generate orphan
instances for this purpose.

Snapshot encoding remains a separate cache surface. Structural event-codec
coverage must not be reported as structural snapshot encoding. Changes to a
mapped wire shape, binding provenance, register initial-value provenance, or the projection schema contribute to
the generated fold/snapshot fingerprint so stale snapshots are rejected and
rebuilt. Consumer `ToJSON` and `FromJSON` constraints may therefore remain for
snapshot storage, but they are documented as cache serialization rather than
event wire authority.

Generated structural shapes live in one context-level leaf module per mapped declaration.
This keeps binding imports acyclic, prevents unrelated data constructors from colliding in a
single generated module, and preserves exact constructor metadata for the optional generic
binding path. Structural records declare the consumer constructor explicitly; the generated
shape type uses that constructor name and binding modules import it qualified. Shape modules
never import binding or Holes modules.

Binding-authoring conveniences remain downstream of this shape boundary. The scaffolder emits
create-once, hand-owned skeletons grouped by the modules named by qualified binding, fixture, and
register-initial symbols; a shared leaf module may own several declarations. Scaffold records
persist field/constructor-level hole obligations so later declaration changes are reported
without parsing or rewriting consumer Haskell. An opt-in `GHC.Generics` binding is available only
when constructor order and names, selector order and names, arity, and field types correspond
exactly. A mismatch is a compile-time refusal directing the author to the explicit skeleton; the
derivation never strips prefixes, coerces values, guesses a permutation, or acquires wire-policy
capabilities.

For every eligible scalar leaf path in a structural mapped record, the generation layer may
emit a narrow projection facade containing one canonical nominal tag type,
`FieldProjection` instance, and `FieldWitness`. It derives the concrete getter
and symbolic metadata from the same resolved graph and total binding as the
codec. The facade exposes Keiki 0.4's existing `regProj` and `inpProj`
capability to hand-written Holes; it does not invent a second evaluator.
The instance's owner is the consumer type; its shape id is the declaration's
`canonical-type`; its field name is the RFC 6901 JSON Pointer for the wire-key path; and its total getter runs
`bindingToShape` followed by generated shape selection. A nested path is eligible only through
required total record fields, never through optional, union, collection, JSON, or opaque
boundaries. The canonical tag is reused at every occurrence so Keiki's nominal `Typeable`
identity shares repeated reads. Remaining eligibility follows Keiki's public constraints:
direct register or matched input-field base, guard use only, a result in the curated symbolic
registry, and the ordering subset when ordered comparison is required.

The DSL does not yet claim checked nested field-path syntax. Today guard and
write expressions are rendered into create-once Holes as comments rather than
lowered into executable generated transducers. A future syntax proposal must
first define exact lowering and an equivalence or conformance gate connecting
the checked DSL expression to the code that runs.

Private event/register schemas and public contract DTOs remain separate
ownership domains. Structural private types are not reused in a public
contract merely to demonstrate a compatibility-vector scenario.

The implementation gate is a generated, fixture-driven conformance harness. It checks both
binding laws, canonical identity, declared branch coverage, missing/null/unknown-field policy,
generated codec round trips, pinned event payload bytes, projection witness/getter agreement,
and forward-versus-replay equality for every register. Opaque declarations receive only
boundary codec assertions. Mapping provenance is persisted in the scaffold record, so changing
the declared wire, binding, initial value, or projection identity produces visible drift rather
than silently reusing a generated ring. These checks are finite evidence, not a replacement for
the totality and ownership requirements above.


## Consequences

- Adding an aggregate type or capability requires extending the central
  resolver and its exhaustive type-by-use-site matrix; an isolated parser,
  validator, or generator allowlist is not a complete implementation.
- Canonical aggregate identities feed diff, replay-impact, and fold/snapshot
  fingerprints, so source aliases do not create compatibility churn while real
  type or initial changes remain visible.
- The binding API has no partial inverse or semantic-error channel. A binding that rejects or
  normalizes valid shapes violates the shape round-trip contract, and both directions have
  explicit law tests. `check` and `diff` still do not inspect hand-written Haskell.
- Haskell does not prove the two laws for a hand-written binding. Declared fixture/shape cases
  and mutation tests are finite evidence; exact generic derivation can establish stronger
  representation correspondence. Documentation must not call a passing finite harness a proof
  for all values.
- Skeletons and exact generic derivation reduce application-boundary boilerplate without becoming
  compatibility gates or schema authorities. GHC and conformance evidence check consumer code;
  `check` and `diff` continue to reason only from the declared and resolved schema.
- Consumers with refined domain constructors may need a richer structural
  declaration or must choose opaque mode until such a declaration exists.
- Binding implementation changes require an explicit `binding-version` bump, conformance run,
  and mapped-snapshot invalidation; keeping the token unchanged is a contract violation.
- Generated projection witnesses have auditable provenance and are reusable by
  consumers other than Mori, while staying within Keiki's validated fragment.
- Keiki 0.4 is a coordinated dependency/API migration: downstream exhaustive
  matches must handle projection terms and the new validation/composition
  warnings before the facade can ship.
- Snapshot compatibility is conservative and operationally honest: mapped
  schema changes invalidate and rebuild cached state rather than pretending the
  generated event codec decodes historical snapshots.
- Nested `.keiro` guard syntax remains unavailable until it can be shown to
  execute the same semantics the checker validates.
- Generated codecs and projection facades may use consumer constructors and
  getters, but consumer JSON instances never become the private-event wire
  authority.
- Wire fingerprints ignore consumer-side naming, while binding/source provenance remains
  separately diff-visible; neither policy implies that Keiro inspects arbitrary Haskell.
- The compiled structural conformance fixture and its mutation suite demonstrate that a
  transposed binding, an uncovered union arm, and a mapped value omitted from the first event all
  turn their owning gate red. The generated structural codec remained within 1.04x of a
  policy-equivalent hand-written Aeson baseline in the representative benchmark matrix, so the
  sanctioned fusion optimization is not required for this implementation.
