---
type: Architecture Decision Record
title: Structural consumer mappings use one schema authority and total bindings
description: Keiro-generated structural and nominal representations own private-event wire policy; aggregate, queue, query, and projection consumers resolve through checked schema authorities, consumer bindings are total isomorphisms, snapshots remain separately invalidated, and Keiki projections come from those authorities.
timestamp: 2026-08-10T04:36:00Z
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

The Keiki API at `mori://shinzui/keiki/packages/keiki` supplies typed symbolic
field projections through `FieldProjection`, `FieldWitness`, `regProj`, and
`inpProj`. Projection results must belong to Keiki's curated symbolic registry;
ordered comparisons require its still-smaller ordering registry. Keiki
validates the symbolic term and supplies `fieldWitnessAgrees` for concrete
agreement tests, but it intentionally cannot prove that a consumer-written
witness came from the same schema as Keiro's codec.

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

`Time` and `UTCTime` are one resolved `Time` identity. Direct `Integer` joins
`Text`, `Int`, `Bool`, `Time`, and `Natural`. Language-version-2 expression
resolution attaches explicit arithmetic evidence rather than inferring it from
generic scalar visibility: `Integer` has exact `+`, `-`, and `*`; `Natural`
has `+`, `*`, and total truncated subtraction; machine `Int` has no arithmetic
because symbolic integers do not model overflow. Direct `Json`, `Optional`,
`List`, and `Map` remain unsupported aggregate shapes and must cross the
structural-mapping boundary described below. A clean checked spec has total
deterministic lowering; scaffolding retains a refusal only as an internal
invariant defense.

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

The same total-binding rule applies when language version 2 binds a direct ID,
direct enum, or nominal scalar to a consumer-owned Haskell type:

```haskell
data NominalBinding domain representation = NominalBinding
  { nominalToRepresentation :: domain -> representation
  , nominalFromRepresentation :: representation -> domain
  }
```

The representation is `KindID prefix` for an ID, a generated closed datatype
for an enum, or exactly one of `Text`, `Int`, `Natural`, `Bool`, or `UTCTime`
for a nominal scalar. JSON parsing may reject malformed or wrong-prefix ID text
or an unknown enum spelling before a representation exists; conversion from a
valid representation is total. A consumer constructor that rejects,
normalizes, or quotients representation values is refined rather than nominal
and remains behind `mapped opaque` until a separately designed refined contract
makes that policy visible.

ID and enum equality is derived from this same declaration and total binding;
the consumer does not implement a second equality authority. The checked
contract fixes a declaration-scoped textual key, its domain, its generated or
consumer owner, and the binding provenance. Consumer `KindID` declarations use
the released TypeID text domain with an exact reverse witness, and enums use
their finite declared wire spellings. Generated language-2 enums are exact for
the same reason. Legacy generated IDs remain public `newtype` wrappers over
unrestricted `Text`, so their concrete equality is type-safe but their symbolic
projection is deliberately one-way and conservatively unverified. Language-3
generated IDs restrict public construction and current JSON decoding through
`keiro-dsl/id-domain/typeid-v7/1`, so they use the same exact full-string domain
and reconstruction evidence as consumer-bound IDs.

Keiro, not the consumer binding, owns that ID admission domain. The checked
contract fixes the prefix, separator, canonical lowercase normalization,
26-character Crockford suffix, maximum length, UUIDv7 version/variant bits, and
JSON text representation. Consumer conversion runs only after this validation.
Generated conformance checks fixture agreement and distinct canonical
representations through both total binding directions, so a binding that
normalizes or quotients valid representations turns the gate red. The stable
domain version is persisted independently of equality in binding explanations
and scaffold history.

Nominal declarations carry the same mandatory provenance inventory as
structural bindings: consumer package/module/type, qualified binding symbol,
binding version, canonical type identity, and non-empty fixture symbol, plus an
initial symbol when used by a register. The generated private-event codec owns
ID prefix checks, enum spellings, and scalar JSON policy. Expected-wire fixtures
exercise both binding laws and pin the declared bytes, but remain finite
evidence. Existing `mapping` record rows are unchanged; nominal provenance uses
an additive `nominal-mapping` row so old readers ignore it safely.

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

Consumer dependency impact has one checked authority, `Keiro.Dsl.SemanticImpact`. It derives from
the resolved graph, groups every command-field, private-event-field, and register root by owning
aggregate, unions each root with its transitive mapped-declaration closure, and inverts those
closures into declaration consumers. Every public projection is deterministically ordered, and
the root fold is exhaustive so a future `UseSite` constructor cannot compile until the impact
model assigns it semantics. Generators, scaffold history, and impact reports consume this model;
they do not reconstruct reachability from raw `Spec` fields.

The complete service declaration inventory is deliberately separate from aggregate consumer
closures. Declaration-owned binding, canonical-identity, fixture, branch-coverage,
opaque-boundary, and projection-witness laws run once at service conformance scope, including for
an intentionally unused declaration. Aggregate harnesses own only codec, wire-policy, replay,
snapshot, and generated projection evidence tied to their checked uses. Service conformance is
therefore not represented as an aggregate consumer, which prevents one declaration change from
making every aggregate appear impacted.

Generation realizes that boundary as one replaceable context module named
`StructuralConformance`, emitted whenever the checked service inventory is non-empty and recorded
with context-level workspace provenance. The module exports the declaration-law assertion list;
each aggregate harness plans consumer fixture and initial imports only from its
`aggregateMappedClosure`. The runtime-owned service facade imports the context module once and
prefixes its results with `structural/`. This execution wiring does not turn the service into an
aggregate consumer and does not make module emission conditional on the optional runnable
conformance package.

Candidate language 5 extends the checked root vocabulary with typed workqueue fields and complete
read-model query input/result pairs. Each root resolves the entire recursive `TypeExpr`, records
its source location and outer container path, and reaches mapped declarations through the same
graph as aggregate roots. One pure `ConsumerTypePlan` renders the consumer-facing Haskell type,
deterministic imports, and transitive mapped dependency closure. It contains no JSON, SQL, or
runtime-codec policy: the queue and read-model lowerers must compose their own surface authority
around this common type plan.

Typed workqueue lowering composes that type plan with one shared resolved `MappedCodecPlan`, the
same recursive primitive/`Json`/optional/list/map/structural/opaque algebra now used by aggregate
event generation. At a consumer root, a structural reference crosses its declared total binding;
inside a generated structural shape, nested structural references call the nested shape codec
directly. Opaque references use only their declared consumer JSON boundary. This is a lowering
description, not another runtime codec or schema authority.

Every generated queue object field remains required independently of its value type. A field of
`Optional T` must be present and may contain JSON null; omission is a decode failure. Queue module
imports and inline structural codecs are planned from only the field expression's transitive
mapped closure, while service structural conformance still covers the complete declaration
inventory. Legacy scalar queues retain their released generation path and bytes.

Projection typing is derived rather than redeclared. An aggregate inline projection and a catalog
owner whose source is `aggregate A` consume only A's private-event mapped roots; command-only and
register-only roots do not enter the projection relation. Catalog `category` and `all` sources
remain heterogeneous decoder boundaries and are recorded as unsupported typed sources without a
fabricated mapped path. Public contracts remain outside this private mapped-consumer vocabulary.

The new queue/query spellings are registered only in the unpublished language-5 candidate. Queue
and read-model query generation are complete, so a clean `check` implies total scaffold lowering
for both surfaces. A typed read model receives one generated `QueryContract` module whose aliases
use the consumer domain types and deterministic imports from `ConsumerTypePlan`. It receives no
generated JSON codec, structural shape conversion, SQL codec, or binding import: `ReadModel q r`
passes application Haskell values to an application-owned transaction, while the structural
declarations retain their separate JSON conformance authority.

Snapshot impact continues to follow register use because the snapshot is a cache of the register
file. Query input/result changes are consumer-build API changes only; they do not become event,
queue, snapshot, table-shape, or projection-replay changes. Projection rebuild policies consume
checked roots in their owning follow-up changes; downstream code must not infer unsupported
consumers from descriptive notation.

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

Generated Haskell presentation resolves through one import plan for each
complete target module. A unique consumer-owned type uses an explicit
unqualified import. Consumer values and constructors, generated shape and
nominal APIs, and types whose occurrence conflicts with another import or a
local declaration use deterministic qualified aliases derived from the
shortest unique module suffix. The plan merges, deduplicates, and sorts imports
and is independent of declaration traversal order. It never falls back to a
complete consumer module path at a Haskell use site. This rule changes only
generated Haskell syntax: semantic authorities, wire identities, fingerprints,
diagnostics, manifests, scaffold history, and provenance retain complete module
names. Existing create-once consumer modules remain untouched.

Generated references entering that import plan come from the checked generated-Haskell
occurrence model. Logical Keiro names are normalized once into typed UpperCamelCase or
lowerCamelCase occurrences before an emitter or alias allocator sees them. Explicit
consumer-owned module, type, constructor, and qualified-value references cross the same lexical
validation boundary without re-casing. Consequently, a generated selector rename paired by an
unchanged wire key is consumer-build provenance only: it produces a rebuild advisory while the
mapped wire fingerprint, event compatibility, snapshot identity, and replay surface remain
unchanged.

Binding-authoring conveniences remain downstream of this shape boundary. The scaffolder emits
create-once, hand-owned skeletons grouped by the modules named by qualified binding, fixture, and
register-initial symbols; a shared leaf module may own several declarations. Scaffold records
persist field/constructor-level hole obligations so later declaration changes are reported
without parsing or rewriting consumer Haskell. An opt-in `GHC.Generics` binding is available only
when constructor order and names, selector order and names, arity, and field types correspond
exactly. A mismatch is a compile-time refusal directing the author to the explicit skeleton; the
derivation never strips prefixes, coerces values, guesses a permutation, or acquires wire-policy
capabilities.

For every eligible scalar leaf path in a structural mapped record, the generation layer emits a
narrow projection facade containing one canonical nominal tag type,
`FieldProjection` instance, and `FieldWitness`. It derives the concrete getter
and symbolic metadata from the same resolved graph and total binding as the
codec. The facade exposes Keiki's `regProj` and `inpProj` capability to both the
generated version-2 transducer and hand-written Holes; it does not invent a
second evaluator.
The instance's owner is the consumer type; its shape id is the declaration's
`canonical-type`; its field name is the RFC 6901 JSON Pointer for the wire-key path; and its total getter runs
`bindingToShape` followed by generated shape selection. A nested path is eligible only through
required total record fields, never through optional, union, collection, JSON, or opaque
boundaries. The canonical tag is reused at every occurrence so Keiki's nominal `Typeable`
identity shares repeated reads. Remaining eligibility follows Keiki's public constraints:
direct register or matched input-field base, a result in the curated symbolic registry, and the
ordering subset when ordered comparison is required.

Language version 2 claims checked dotted syntax only across those required
record paths and only when the endpoint is a supported scalar. The expression
resolver consumes the same graph and witness identity as the generated codec.
One resolved transition inventory drives imports and rendering in the generated
`Transducer` module. Nested projections are bound once under transition-local
business-shaped aliases whose right-hand sides remain the generated `regProj` or
`inpProj` witness applications; guards and writes are rendered inline from the
same checked trees. The transducer executes those exact trees during forward
decisions and replay; there is no second pure-Haskell evaluator, generated
guard/write helper module, or hand-owned override seam. Version 1 retains its
historical comment/Holes surface unchanged.

Private event/register schemas and public contract DTOs remain separate
ownership domains. Structural private types are not reused in a public
contract merely to demonstrate a compatibility-vector scenario.

Language version 4 reuses Keiro's frozen TypeID-v7 admission authority at the
public contract boundary without turning a contract DTO into a private
aggregate type. A declared `typeid "inc"` field lowers to `KindID "inc"` in the
generated public DTO, renders with `KindID.toText`, and parses through the same
canonical lowercase, declared-prefix, and UUIDv7 checks before construction.
The valid JSON representation remains a string. The generated module imports
`keiro-core` for that policy and `mmzk-typeid` for the prefix-indexed type; its
per-field domain identity is persisted independently of private aggregate ID
ownership.

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
- Mapped consumer locality is defined once over the resolved graph. An aggregate closure contains
  only declarations reachable from its checked roots, while service conformance retains every
  checked declaration independently of current use.
- Candidate-language typed queue and read-model expressions are explicit checked roots, while
  aggregate-sourced projections are derived event consumers. Public contracts and heterogeneous
  category/all projection sources remain outside mapped impact rather than overstating Keiro's
  evidence.
- A queue or query expression cannot pass `check` until its surface-specific lowering is total;
  registering syntax and roots does not authorize partial generation.
- Canonical aggregate identities feed diff, replay-impact, and fold/snapshot
  fingerprints, so source aliases do not create compatibility churn while real
  type or initial changes remain visible.
- Generated modules use one deterministic import plan: unique consumer types
  are explicit and unqualified, while collisions and external APIs use stable
  short aliases. Import presentation does not alter semantic identity or permit
  rewriting a create-once consumer module.
- The import planner cannot silently invent a second casing policy. Generated
  occurrences are already checked values, while explicit consumer references preserve
  their declared spelling and identity.
- The binding API has no partial inverse or semantic-error channel. A binding that rejects or
  normalizes valid shapes violates the shape round-trip contract, and both directions have
  explicit law tests. `check` and `diff` still do not inspect hand-written Haskell.
- Direct consumer-owned IDs, enums, and nominal scalars obey the same rule.
  Prefix and enum-wire rejection belongs to parsing into the typed/closed
  representation, not to `nominalFromRepresentation`; refined scalar
  constructors remain opaque.
- Language-3 generated and consumer-bound IDs share one Keiro-owned runtime
  and Keiki exact-domain contract. Binding mode cannot widen, normalize, or
  redefine the declared prefix domain; versions 1 and 2 retain their released
  generated-ID behavior.
- Language-4 public contract TypeID fields reuse that admission contract in
  prefix-indexed DTO fields and field-path-aware decoders. They remain public
  integration types with canonical JSON text, not aliases of private aggregate
  IDs; versions 1 through 3 retain their released `Text` DTO representation.
- Bound scalar whole-value projections reuse the declared total nominal binding
  and canonical identity. Same-declaration IDs and enums also reuse that
  authority for equality: consumer `KindID` IDs and all enums have exact
  domains, while legacy generated IDs remain conservatively one-way. Cross-ID,
  cross-enum, and nominal-to-`Text` comparisons are rejected, and no nominal
  ordering or arithmetic capability is inferred.
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
- Keiki 0.7 is the coordinated dependency floor for exact `Integer`, total
  `Natural` monus, conservative one-way projection classification, exact
  projection domains, and reconstructible models; downstream exhaustive
  matches must handle those structures and results.
- Snapshot compatibility is conservative and operationally honest: mapped
  schema changes invalidate and rebuild cached state rather than pretending the
  generated event codec decodes historical snapshots.
- Version-2 nested scalar paths are limited to total required structural
  records and execute the same generated Keiki structure the checker validates;
  optional, union, collection, JSON, and opaque paths remain unavailable.
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
