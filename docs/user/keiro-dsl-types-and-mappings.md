---
type: Reference
title: Keiro DSL Types and Mappings
description: Declare Keiro DSL IDs, enums, rules, direct types, and consumer-owned nominal, structural, refined, and opaque mappings.
docId: DOC-26
tags: [keiro, dsl, types, mappings, reference]
generated:
  by: anthropic-claude-code/claude-opus-5
  at: 2026-09-28T00:00:00Z
---

# Keiro DSL Types and Mappings

This page covers the shared declarations and types that every node can use:
IDs, enums, rules, nominal declarations, direct aggregate types, and
consumer-owned mapped types with their binding obligations. It is part of the [Keiro DSL Reference](keiro-dsl-reference.md), which
introduces the language, its versions, and source file structure.

## Shared declarations

Shared declarations are visible to all nodes in the source or composed
workspace.

### IDs

```keiro
id TransferReservationId prefix=rsv
id HospitalId prefix=hosp
```

An `id` declares a generated nominal identifier. Language 4 admits current
TypeID-v7 values and generates a distinct Haskell type for each declaration.
The prefix is at most 63 characters, uses lowercase ASCII letters and
underscores, and cannot begin or end with an underscore. Prefixes must be unique
within the service.

An unbound ID register begins at the sentinel `placeholder`:

```keiro
regs
  reservationId TransferReservationId = placeholder
```

Use a checked TypeID literal in a transition write:

```keiro
write requestId := RequestId("req_00041061050r3gg28a1c60t3gf")
```

The literal must be canonical, have the declared prefix, and carry a UUID-v7
suffix. Application code should use the safe constructors exposed by the
generated/current ID API rather than constructing raw text wrappers.

#### Admission domains (candidate Language 6)

Candidate Language 6 lets an ID declaration name the frozen set of canonical
TypeIDs its readers and public constructors admit:

```keiro
language keiro-dsl 6
context identity-history

id LegacyId prefix=legacy domain=typeid-v5-or-v7
```

`domain` is `typeid-v7` (the default when omitted) or `typeid-v5-or-v7`.
Omitting it keeps the released TypeID-v7 behavior and its compatibility
identity, so existing declarations are unaffected. `typeid-v5-or-v7` admits
canonical TypeIDs whose suffix is either a UUIDv5 or a UUIDv7, for retained
data that holds deterministic, name-derived identifiers. It controls admission
only: it does not select an ID generator, change deterministic seeds, or
authorize regenerating stored identifiers.

The selected domain follows the ID everywhere the declaration is used: direct
and nested aggregate fields, structural and keyed-map codecs, workqueue
payloads, read-model query types, router recipients, and declared public
contract fields. Process and workflow codecs, stream names, and workflow,
child, and timer IDs stay application-owned.

Changing the domain is a compatibility change in either direction. Widening to
`typeid-v5-or-v7` is an old-reader/new-writer hazard, because older readers
reject newly written UUIDv5 values. Narrowing back is a historical-read hazard,
because retained UUIDv5 values stop decoding. `diff` reports either direction as
`IdDomainContractChanged` at every direct and nested use, changes the affected
fold fingerprint, and marks aggregate replay as affected. See
[Explicit ID admission domains](../id-admission-domains.md) for the
supported-use matrix.

### Enums

```keiro
enum PatientAcuity {
  RedTag=red
  YellowTag=yellow
  GreenTag=green
}
```

The left side is the Haskell constructor; the right side is its stable wire
spelling. Constructor names and wire spellings must each be unique. Enum
registers start at a declared constructor, and expression literals are
qualified:

```keiro
regs
  acuity PatientAcuity = GreenTag

guard cmd.acuity == PatientAcuity.RedTag
```

### Rules

```keiro
rule lifeCriticalOverride : PatientAcuity -> Bool
  ex RedTag => true ; YellowTag => false ; GreenTag => false
```

A `rule` is a total, deterministic lookup over one declared enum. Every enum
constructor must appear exactly once. Bodies can refer only to enum constructors
and Boolean values and may not sample a clock. Rules can be used as Boolean
atoms in aggregate guards.

### Consumer-owned nominal declarations

Use `using` when an ID or enum already has an application-owned Haskell type:

```keiro
id OrderId prefix=ord using {
  haskell package=orders-domain module=Orders.Id type=OrderId
  binding = "Orders.KeiroBindings.orderIdBinding"
  binding-version = "1"
  canonical-type = "orders.OrderId.v1"
  fixtures = "Orders.KeiroBindings.orderIdFixtures"
  initial = "Orders.KeiroBindings.initialOrderId"
}

enum OrderStatus { Draft=draft Submitted=submitted } using {
  haskell package=orders-domain module=Orders.Order type=OrderStatus
  binding = "Orders.KeiroBindings.orderStatusBinding"
  binding-version = "1"
  canonical-type = "orders.OrderStatus.v1"
  fixtures = "Orders.KeiroBindings.orderStatusFixtures"
  initial = "Orders.KeiroBindings.initialOrderStatus"
}
```

Use `mapped nominal` for an application-owned scalar wrapper:

```keiro
mapped nominal AccountNumber : Text {
  haskell package=orders-domain module=Orders.Account type=AccountNumber
  binding = "Orders.KeiroBindings.accountNumberBinding"
  binding-version = "1"
  canonical-type = "orders.AccountNumber.v1"
  fixtures = "Orders.KeiroBindings.accountNumberFixtures"
  initial = "Orders.KeiroBindings.initialAccountNumber"
}
```

Nominal scalar representations are `Text`, `Int`, `Natural`, `Bool`, and
`Time`. The binding must be a total isomorphism: converting to the declared
representation and back must preserve the value, and the reverse direction
must also preserve the representation. A validating, normalizing, or otherwise
partial constructor is not nominal; represent it as `mapped opaque` instead.

`haskell`, `binding`, `binding-version`, `canonical-type`, and `fixtures` are
required. `initial` is required when the type is used by a register. A
consumer-owned register starts with the bare token `initial`, which selects the
declared symbol:

```keiro
regs
  orderId OrderId = initial
  status OrderStatus = initial
  accountNumber AccountNumber = initial
```

The first scaffold creates a binding skeleton. Fill it and its fixture cases;
do not duplicate wire spellings or defaults in the binding. Those remain owned
by the `.keiro` declaration.

Candidate Language 6 also permits an `id`, `enum`, or `mapped nominal` declaration as a
leaf inside a structural mapping, typed workqueue field, or read-model query
input/result. The generated private shape contains the nominal domain type, not
its `KindID` or primitive representation. One context-owned
`Structural.NominalLeaves` module applies the declared binding and Keiro-owned
admission policy wherever a generated JSON codec needs the leaf. Query-only
aliases reuse the checked nominal type and import plan without emitting that
helper. Nominal enum leaf codecs accept and emit only the declaration's exact
wire spellings. An optional enum leaf may use one of its declared constructors
as an `on-missing` default.

## Types

### Direct aggregate types

Aggregate registers and explicit command/event fields accept:

| DSL type | Haskell meaning | Notes |
| --- | --- | --- |
| `Text` | `Text` | Quoted initial. Equality only. |
| `Int` | machine-width `Int` | Signed integral initial. Equality and ordering; no arithmetic. |
| `Integer` | arbitrary-precision `Integer` | Signed integral initial. Equality, ordering, and exact arithmetic. |
| `Bool` | `Bool` | Initial is `True` or `False`; equality only. |
| `Time` | `UTCTime` | Quoted ISO-8601 UTC initial; equality and ordering. |
| `Natural` | `Natural` | Non-negative integral initial; equality, ordering, and total arithmetic. |
| declared `id` or `enum` | nominal generated or consumer type | Equality and whole-value writes. |
| `mapped` type | consumer-owned type | Whole-value fields/registers/writes; scalar projection depends on shape. |
| `<Aggregate>Vertex` | aggregate lifecycle vertex | Register use is opaque; `goto` normally owns lifecycle state. |

`UTCTime` is accepted as an input alias and canonicalizes to `Time`.

`Json`, `Optional`, `List`, and `Map` are not legal as direct aggregate fields
or registers. Put those shapes behind a named `mapped structural` or
`mapped opaque` declaration. The candidate Language 6 `Day` and `Set Text`
types follow the same rule: declare a named
[bare value](#structural-bare-values) such as `wire Day` and use that mapping as
the field or register type. A `mapped refined` declaration may be used directly.

### Optional identifiers on commands

A command or explicit event field cannot use `Optional DeclaredId` directly.
Give the optional value a named structural boundary, then use that mapped type
at the aggregate field:

```keiro
mapped structural record TemplateIdRef {
  haskell package=templates-domain module=Templates.Domain type=TemplateIdRef
  binding = "Templates.KeiroBindings.templateIdRefBinding"
  binding-version = "1"
  canonical-type = "templates.TemplateIdRef.v1"
  fixtures = "Templates.KeiroBindings.templateIdRefFixtures"
  wire object constructor=TemplateIdRef unknown-fields=reject {
    templateId as "templateId" : Optional TemplateId optional on-missing=null
  }
}

command FindTemplate { reference:TemplateIdRef }
```

The diagnostic prints the one-field `mapped structural record` shape as
guidance. A real declaration still needs the Haskell source, binding version,
canonical identity, fixtures, and complete wire block shown above.

### Field inference

A field without `:Type` is inferred in this order:

1. A register with exactly the same field name.
2. A declared ID, enum, aggregate vertex, or mapped type matching the field's
   PascalCase name.
3. `Text`.

For public and persisted shapes, explicit field types are easier to review and
safer during evolution:

```keiro
command Adjust { amount:Integer requestId:RequestId observedAt:Time }
event Adjusted { amount:Integer requestId:RequestId observedAt:Time }
```

### Mapped type expressions

Structural mapped fields support these recursive expressions:

```keiro
Text
Int
Integer
Bool
Natural
Time
Day
Json
Optional Text
List Text
List (Optional Text)
Map Text
Map[DeclaredId] Text
Set Text
Optional (Set Text)
OtherMappedType
RefinedMappedType
DeclaredId
DeclaredEnum
MappedNominalScalar
```

`Map T` means a JSON object with text keys and values of type `T`.
Candidate Language 6 adds `Map[DeclaredId] T`, whose JSON object keys are
admitted through the declared ID codec and whose generated shape is
`Map DeclaredId T`. The bracketed key must name an `id`; enums, nominal
scalars, and mapped declarations are rejected. For a consumer-bound ID,
`Ord` on the consumer type must agree with the ordering of its canonical
TypeID text. Generated conformance checks that law over every pair of declared
fixtures.
`DeclaredId`, `DeclaredEnum`, and `MappedNominalScalar` stand for the names of existing `id`,
`enum`, and `mapped nominal` declarations and require candidate Language 6. They may
occur beneath `Optional`, `List`, and `Map` and at typed workqueue and read-model
query roots. Generated and consumer-bound IDs, enums, and nominal scalars are supported.

`Day`, `Set Text`, and the names of `mapped refined` declarations
(`RefinedMappedType` above) also require candidate Language 6. `Day` and
`Set Text` lower to `Data.Time.Calendar.Day` and `Set Text` through the frozen
policies in [Checked value wire policies](#checked-value-wire-policies). They
may occur beneath `Optional`, `List`, and text-keyed `Map`, and a refined value
may occur in the same positions. `Set` accepts only `Text` elements, and neither
a set, a day, nor a refined value may be a `Map[...]` key; use a declared ID for
a keyed map.

## Consumer-owned mapped types

A mapped declaration keeps an existing Haskell type at the application
boundary. A structural mapping gives the DSL complete authority over its JSON
shape; an opaque mapping delegates JSON authority to the consumer type.

### Structural records

```keiro
mapped structural record ArtifactInfo {
  haskell package=artifact-domain module=Example.Artifact.Domain type=ArtifactInfo
  binding = "Example.Artifact.KeiroBindings.artifactInfoBinding"
  binding-version = "1"
  canonical-type = "example.artifact.ArtifactInfo.v1"
  fixtures = "Example.Artifact.KeiroBindings.artifactInfoCases"
  initial = "Example.Artifact.KeiroBindings.emptyArtifactInfo"
  wire object constructor=ArtifactInfo unknown-fields=reject {
    artifactId   as "artifactId"   : ArtifactId    required
    claimId      as "claimId"      : Optional ClaimId optional on-missing=null
    key         as "key"         : Text          required
    description as "description" : Optional Text optional on-missing=null
    active      as "active"      : Bool          optional on-missing=false
    tags        as "tags"        : List Text     optional on-missing=[]
    attributes  as "attributes"  : Map Text      optional on-missing={}
    owners      as "owners"      : Map[ClaimId] Text optional on-missing={}
  }
}
```

Each row gives the Haskell selector, JSON key, type, and presence. JSON keys and
Haskell field names must be unique. `unknown-fields` is `reject` or `ignore`.
Optional fields need a type-correct `on-missing` value:

| Default syntax | Intended type |
| --- | --- |
| `null` | `Optional T` |
| `"text"` | `Text` |
| integer literal | `Int`, `Integer`, or `Natural` as valid |
| `true`, `false` | `Bool` |
| `[]` | `List T` |
| `{}` | `Map T` or `Map[DeclaredId] T` |
| constructor name | structural enum |

The checker rejects recursive mappings, unresolved or ambiguous names,
ill-typed defaults, and non-injective nullability such as `Optional Json` when
JSON `null` cannot distinguish the cases.

### Structural string enums

```keiro
mapped structural enum ArtifactKind {
  haskell package=artifact-domain module=Example.Artifact.Domain type=ArtifactKind
  binding = "Example.Artifact.KeiroBindings.artifactKindBinding"
  binding-version = "1"
  canonical-type = "example.artifact.ArtifactKind.v1"
  fixtures = "Example.Artifact.KeiroBindings.artifactKindCases"
  wire string {
    Guide as "guide"
    Reference as "reference"
  }
}
```

Constructor names and JSON string values must each be unique.

### Structural tagged unions

```keiro
mapped structural union ArtifactLocation {
  haskell package=artifact-domain module=Example.Artifact.Domain type=ArtifactLocation
  binding = "Example.Artifact.KeiroBindings.artifactLocationBinding"
  binding-version = "1"
  canonical-type = "example.artifact.ArtifactLocation.v1"
  fixtures = "Example.Artifact.KeiroBindings.artifactLocationCases"
  wire tagged-object tag="tag" contents="contents" unknown-fields=reject {
    LocalFile as "local_file" : Text
    RepoPath as "repo_path" : Text
    Unknown as "unknown"
  }
}
```

An arm may omit its payload. Arm constructor names and tag values must each be
unique, and the tag and contents keys must not collide.

### Structural bare values

Candidate Language 6 adds `mapped structural value`, which gives a named
consumer type a bare structural wire shape instead of an object, string enum,
or tagged union:

```keiro
language keiro-dsl 6

mapped structural value MaybeLabel {
  haskell package=labels-domain module=Labels.Domain type=MaybeLabel
  binding = "Labels.KeiroBindings.maybeLabelBinding"
  binding-version = "1"
  canonical-type = "labels.MaybeLabel.v1"
  fixtures = "Labels.KeiroBindings.maybeLabelFixtures"
  initial = "Labels.KeiroBindings.initialMaybeLabel"
  wire Optional Text
}

mapped structural value ImportantDays {
  # binding metadata omitted
  wire List Day
}

mapped structural value NestedIds {
  # binding metadata omitted
  wire List (Optional ItemId)
}
```

The outer constructor of the `wire` expression must be `Optional`, `List`,
text-keyed `Map`, `Day`, or `Set Text`; the checker rejects any other bare root
with `MappedUnsupportedEncoding`. The value is encoded as that shape directly,
without an object wrapper. Nullability propagates transitively through named
values, so a value whose root is `Optional` is null-capable wherever it is
used, and wrapping it in another `Optional` is rejected as non-injective in the
same way as `Optional Json`. A field of such a type may use `on-missing=null`,
and a direct private-event field whose checked root is `Optional` treats an
omitted key the same as an explicit JSON `null`.

The binding is a total isomorphism between the consumer type and the generated
shape, exactly as for records:

```haskell
maybeLabelBinding :: StructuralBinding MaybeLabel MaybeLabelShape
maybeLabelBinding =
  StructuralBinding
    { bindingToShape = \(MaybeLabel value) -> value
    , bindingFromShape = MaybeLabel
    }
```

Named bare values are also how an aggregate field or register carries a `Day`,
a `Set Text`, or an optional or collection shape.

### Refined values

Candidate Language 6 adds `mapped refined`, a consumer type whose wire form is
one of Keiro's frozen refined policies. The only policy is `base16-bytes`:

```keiro
language keiro-dsl 6

mapped refined ContentHash {
  haskell package=storage-domain module=Storage.Hash type=ContentHash
  binding = "Storage.KeiroBindings.contentHashBinding"
  binding-version = "1"
  canonical-type = "storage.ContentHash.v1"
  fixtures = "Storage.KeiroBindings.contentHashFixtures"
  initial = "Storage.KeiroBindings.initialContentHash"
  wire base16-bytes
}
```

The generated shape is a `ByteString`, and the binding converts between it and
the consumer type totally. The policy has no length or content callback: any
byte string, including the empty string, is admitted. Model a bounded byte
type as a new explicit policy rather than validating in `bindingFromShape`.

A refined declaration may be used directly as an aggregate field or register,
inside structural records, bare values, lists, and text-keyed maps, and in
typed queue payloads and read-model query types. It is not supported as a map
key, in guard or write expressions beyond whole-value assignment, or in a
public contract, where consumers cannot share the refined codec.

### Checked value wire policies

`Day`, `Set Text`, and `base16-bytes` each lower to a frozen `keiro-core` codec
rather than a consumer validation callback. Each policy has a stable identity
that participates in the generated mapped-wire fingerprint, so a change to
what it reads or writes needs a successor policy and a retained reader.

| Type | Codec | Writes | Reads |
| --- | --- | --- | --- |
| `Day` | `Keiro.Codec.CalendarDay` | `[-]YYYY-MM-DD`, proleptic Gregorian, four-digit minimum year, never a `+` sign | The same language plus an optional `+` sign and redundant year zeroes; invalid dates rejected; no timezone or instant conversion |
| `Set Text` | `Keiro.Codec.TextSet` | A JSON array of unique strings in Unicode code-point order | Any array order and duplicate strings; no Unicode normalization or case folding |
| `base16-bytes` | `Keiro.Codec.Base16Bytes` | Lowercase hexadecimal with no prefix, preserving leading zero bytes and the empty value | Upper- or lowercase hexadecimal; prefixes, whitespace, odd lengths, and non-hex digits rejected |

Every reader accepts the full historical language and normalizes it, so
retained non-canonical bytes decode to the same value that the writer would
emit. Each family is a separate capability of the candidate runtime profile
`keiro-dsl/runtime-semantics/5` and changes generated codecs only, not
transition or fold semantics.

### Opaque mappings

```keiro
mapped opaque VendorGeometry {
  haskell package=vendor-geometry module=Vendor.Geometry type=Geometry
  codec = "vendor.geometry.json"
  version = "3"
  fixtures = "Vendor.Geometry.KeiroBindings.geometryCases"
  initial = "Vendor.Geometry.KeiroBindings.emptyGeometry"
}
```

An opaque mapping requires `haskell`, `codec`, `version`, and `fixtures`.
`initial` is required for register use. Keiro delegates to the consumer type's
codec and makes no compatibility claim about fields below the opaque boundary.
Use coverage reports to keep these boundaries visible.

### Structural binding obligations

Run:

```bash
cabal run -v0 keiro-dsl -- check service.keiro --explain-bindings
```

The output names every required binding, fixture, and initial symbol with its
owner. The generated context `StructuralConformance` module checks both binding
directions, canonical identities, fixture labels and branch coverage, opaque
boundaries, and structural projection witnesses once for the complete service
inventory, including intentionally unused declarations. Aggregate harnesses
check only use-specific payload round trips, generated codec wire policy,
snapshot/register behavior, and forward/replay agreement for declarations in
their checked semantic closure. Fixtures are finite evidence, not proof for all
consumer values.

When structural declarations reach nominal leaves, scaffolding also emits one
context-owned `Structural.NominalLeaves` module. Generated shape, event,
and workqueue codecs share its leaf encoders and parsers, so a consumer ID
binding cannot become a second JSON authority. Query aliases share the checked
domain type and import authority without inventing a codec. `StructuralConformance`
adds the consumer nominal domain/representation round-trip and canonical-identity
laws; generated IDs receive canonical-text assertions at every structural fixture
path. Enum declaration fixtures cover every declared arm once, so embedding the enum
does not create a duplicate per-field arm-coverage obligation. The Cabal fragment records the nominal owner and binding modules once,
including across workspace members.

This ownership split changes generated source layout once when adopting the
release: regenerate the service output, add `StructuralConformance` from the
Cabal fragment, and remove declaration-law expectations from aggregate-specific
inventories. Do not hand-move assertions between generated files.

### Migrating from an opaque ID workaround

Before candidate Language 6, an application could preserve its Haskell ID type
only by declaring a `mapped opaque` twin of the consumer-bound ID and, for an
optional field, another opaque wrapper around `Maybe ClaimId`. That workaround
made the consumer Aeson instance authoritative and caused persisted roots to
remain visible as opaque coverage. The same workaround was needed when retained
IDs carried UUIDv5 suffixes; a declaration with
[`domain=typeid-v5-or-v7`](#admission-domains-candidate-language-6) now admits
those values through the checked nominal path.

Replace the opaque twin with the nominal declaration name directly:

```keiro
id ClaimId prefix=claim using {
  haskell package=claims-domain module=Claims.Id type=ClaimId
  binding = "Claims.KeiroBindings.claimIdBinding"
  binding-version = "1"
  canonical-type = "claims.ClaimId.v1"
  fixtures = "Claims.KeiroBindings.claimIdFixtures"
}

mapped structural record TemplateState {
  # binding metadata omitted
  wire object constructor=TemplateState unknown-fields=reject {
    templateId as "templateId" : TemplateId required
    holder as "holder" : Optional ClaimId optional on-missing=null
  }
}
```

`diff` conservatively reports the opaque-or-`Text` to nominal replacement as
`MappedFieldTypeChanged` at every affected root. Generate a historical codec
comparison for the structural declaration, run the old codec against committed
missing/null/present samples, and require byte parity plus rejection of
malformed IDs. That comparison is migration evidence, not permission by itself
to bypass event versioning, queue drain, or snapshot rules; apply the decisions
in [Codecs And Event Evolution](codecs-and-event-evolution.md#structural-consumer-owned-payloads).

### Adopting semantically local regeneration

Adopt this contract only from a Keiro revision where
[MasterPlan 34](../masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md)
and
[MasterPlan 35](../masterplans/35-make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption.md)
are complete. Regenerate every service once, reconcile the
generated Cabal fragment (including `StructuralConformance` and
`BehaviorSourceMap`), compile the runtime package, and run the generated service
conformance target. The migration may move declaration-wide assertions out of
aggregate harnesses and add `semantic-impact` rows to scaffold ledgers; these
are generated layout and evidence changes, not wire, fold, snapshot, or
behavior-key changes.

After that baseline, a mapped declaration change rewrites use-specific output
only for consumers that reach it through checked roots, plus the service
structural module. Released languages expose aggregate command, private-event,
and register roots. Language 5 additionally lowers typed queue fields
and read-model query pairs and derives aggregate-sourced projection consumers.
Queue fields receive generated persisted JSON codecs; read-model query pairs
receive generated Haskell aliases only. Public contracts and heterogeneous
category/all projection sources are not inferred as private mapped consumers.
Follow [Adopting Mapped Consumer Surfaces](mapped-consumer-adoption.md) for the
baseline, consequence-to-owner checklist, and the boundary between a green
repository gate and an authorized fleet rollout.

Source-only movement is separate. Moving an unchanged behavior requirement
rewrites its context `BehaviorSourceMap` and source-bearing ledger provenance,
while its stable key, generated contract, create-once witness, fold, and runtime
semantics remain byte-identical. Failures still resolve the key against the
current map and report the exact file, line, and column.

Review scaffold and diff output as two independent projections: `semantic
impact` names checked consumers and service conformance, while
`generated-artifact impact` names bytes that changed. A legacy ledger has no
historic semantic snapshot, so its first report says `baseline: unavailable
(legacy ledger)` rather than guessing an empty old consumer set.
