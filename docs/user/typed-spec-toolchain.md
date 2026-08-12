# Keiro DSL Language 4 Reference

`keiro-dsl` is Keiro's build-time language for describing an event-sourced
service. A checked `.keiro` source can generate Haskell domain types, codecs,
transducers, runtime wiring, conformance harnesses, and create-once modules for
the behavior that remains application-owned. The generated application uses
ordinary Keiro APIs; the DSL is not interpreted in production.

This reference describes **Language 4 only**. Language 4 is the stable language
for all new specifications and the only language users should author against.
Every source in this guide therefore begins with:

```text
language keiro-dsl 4
```

Use this page as both an introduction and a syntax reference. The shortest path
is [Quick start](#quick-start), followed by the node family you need. The
[command reference](#command-reference) and [authoring checklist](#authoring-checklist)
cover the normal development and CI loop.

## What the language describes

A `.keiro` source describes one service context. It can contain shared type
declarations and any combination of these node families:

| Node | Purpose |
| --- | --- |
| `aggregate` | Event-sourced state machine with commands, events, transitions, projections, and snapshots. |
| `process` | Stateful coordination across aggregates, including a durable timer. |
| `router` | Stateless, effectful one-to-many command routing. |
| `contract` | Public integration-event schema and Kafka topics. |
| `intake` | Kafka-to-inbox decoding, deduplication, and disposition policy. |
| `emit` | Private-state-to-contract-event mapping for the outbox. |
| `publisher` | Outbox ordering, retry, and stable identity policy. |
| `workqueue` | PGMQ payload, ordering, provisioning, retry, and DLQ policy. |
| `dispatch` | Read-model-driven fan-out and deduplicated queue enqueueing. |
| `readmodel` | Registered SQL query identity and shape; released languages retain feed/consistency, while candidate Language 5 owns query freshness only. |
| `workflow` | Durable named steps, waits, sleeps, children, patches, and rotation. |
| `operation` | Named command, query, signal, or workflow-run entry point. |

The language deliberately separates declarative facts from hand-owned behavior.
For example, an aggregate transition can declare a guard and register writes
that Keiro can generate, while a router resolver, read-model SQL body, workflow
body, or explicitly opaque transition stays in a create-once Haskell module.

## Quick start

Generate a valid starter, check it, and scaffold it:

```bash
cabal run -v0 keiro-dsl -- new aggregate > service.keiro
cabal run -v0 keiro-dsl -- check service.keiro
cabal run -v0 keiro-dsl -- scaffold service.keiro --out src
```

The aggregate starter has this shape:

```text
language keiro-dsl 4
context my-service

id ThingId prefix=thing

aggregate Thing
  regs
    thingId ThingId = placeholder
  states Pending Done!

  command DoThing { thingId attempt:Int }
  event ThingCompleted { thingId attempt:Int }

  Pending -- DoThing -->
    emit ThingCompleted
    goto Done

  wire kind=ctorName fields=camelCase schemaVersion=1
```

`check` prints `OK` and exits zero only after semantic validation and the pure
scaffold-planning gates succeed under the source-declared context. `scaffold`
re-runs the same ordered gates under its CLI-effective context before writing,
so module-root, placement, or runtime-package overrides receive the same defense
in depth. It emits replaceable files bearing an exact `@generated` banner,
create-once hand-owned modules, a conformance harness, a Cabal fragment, and a
machine-owned scaffold ledger. Copy the fragment's `default-language`,
`default-extensions`, `other-modules`, and `build-depends` blocks into the
consuming Cabal component, fill the create-once modules, and run the generated
harness in CI.

When the service declares mapped types, scaffold also emits one context
`StructuralConformance` module. It owns declaration-wide binding, canonical
identity, fixture-label, branch-coverage, opaque-boundary, and projection-witness
checks. Aggregate harnesses retain only evidence tied to their checked command,
event, and register closure, so an unrelated aggregate does not acquire consumer
imports or generated-byte churn from another aggregate's declaration change.

The generated Haskell contract is GHC2024 with `OverloadedStrings` as its one
shared default extension. Generated modules declare specialized extensions
locally, and only when their emitted syntax needs them. Create-once hand-owned
modules are outside that cleanup boundary and retain the pragmas they owned when
they were created.

Generated Haskell naming is a separate, versioned presentation contract. Logical
`snake_case` or camel-case declarations pass through one ASCII word segmentation:
module segments, types, and constructors become UpperCamelCase; values and record
selectors become lowerCamelCase.

| Logical name | UpperCamelCase | lowerCamelCase |
| --- | --- | --- |
| `foo_bar` | `FooBar` | `fooBar` |
| `ThingID` | `ThingID` | `thingID` |
| `HTTP_server2` | `HTTPServer2` | `httpServer2` |
| `version2_event` | `Version2Event` | `version2Event` |

Leading, trailing, or repeated underscores are rejected as unsafe. Names such as
`foo_bar` and `fooBar` are rejected when they converge in the same generated
namespace, and normalization to a Haskell keyword is rejected before scaffolding.
This never changes external spellings: wire keys and tags, queue names, SQL names,
registry/subscription identities, and explicit consumer-owned Haskell references
remain exactly declared.

After changing a deployed specification, run a compatibility diff before
scaffolding:

```bash
cabal run -v0 keiro-dsl -- diff service.keiro --since HEAD^ --explain
```

## Source file structure

### Preamble and context

A complete source has this outer form:

```text
language keiro-dsl 4
context hospital-capacity
module Acme.Services
layout collocated

# Shared declarations and nodes follow in any order.
```

The language declaration must be the first non-comment content and must appear
immediately before `context`. `module` and `layout`, when present, must follow
`context` and precede all declarations and nodes.

`context` takes a wire word: an ASCII letter or digit followed by ASCII letters,
digits, underscores, or hyphens. It is the service namespace used in generated
module and durable identity derivation.

`module` is an optional Haskell module prefix made from one or more PascalCase
segments. `layout` controls generated-module placement:

| Layout | Generated modules | Hand-owned modules |
| --- | --- | --- |
| `prefixed` (default) | `<Module>.Generated.<Context>.<Node>...` | `<Module>.<Context>.<Node>...` |
| `collocated` | `<Module>.<Context>.<Node>.Generated...` | `<Module>.<Context>.<Node>...` |

`scaffold --module-root PREFIX` overrides `module`, and `--collocate` overrides
the layout for that run. Prefer declaring stable project-wide placement in the
source or workspace manifest rather than relying on repeated CLI flags.

### Lexical rules

- `#` begins a line comment.
- Spaces, blank lines, and indentation are generally insignificant; keywords
  give the document its structure. Indentation is still strongly recommended.
- Identifiers contain ASCII letters, digits, and underscores and cannot contain
  hyphens. Generated Haskell type and constructor names must begin with an
  uppercase ASCII letter; fields and registers must begin with a lowercase
  ASCII letter or underscore. Generated field selectors reject exactly the
  term-level GHC keywords `case`, `class`, `data`, `default`, `deriving`, `do`,
  `else`, `foreign`, `forall`, `if`, `import`, `in`, `infix`, `infixl`,
  `infixr`, `instance`, `let`, `module`, `newtype`, `of`, `then`, `type`, and
  `where`. Contextual words such as `family`, `via`, and `qualified` are valid.
  Use a field's `haskell` alias when its DSL name must remain a hard keyword.
- A *wire word* may also contain hyphens. Context names, ID prefixes, enum wire
  values, state-map values, and workflow labels use this form.
- Double-quoted strings support `\"`, `\\`, `\n`, `\t`, and `\r`. Raw newlines
  and unknown escapes are errors.
- A duration is decimal digits followed by exactly `s`, `m`, or `h`, such as
  `30s`, `5m`, or `2h`.
- Keywords are case-sensitive. In particular, aggregate register initials use
  `True` and `False`, while expressions use `true` and `false`.
- `parse` and `pretty` produce canonical syntax but do not preserve comments or
  original whitespace.

Top-level declarations in the same category must have unique names. Node names
must be unique within their node family. Generated Haskell names must also avoid
case-folded path collisions and constructor collisions.

### Parser scaling

Source-span capture derives each production's consumed slice from Megaparsec offsets, so attaching
exact locations does not measure the complete remaining input before and after every nested field,
expression, state, or transition. Reproduce the manual scaling benchmark with:

```bash
cabal bench keiro-dsl:keiro-dsl-parser-bench \
  --benchmark-options='-j1 --csv /tmp/keiro-dsl-parser.csv'
```

The benchmark keeps a service at eight aggregates and doubles nested transitions from 32 to 256;
its workspace group keeps eight aggregates and 128 transitions while splitting them across one,
two, four, or eight in-memory members. On one Apple arm64 machine with GHC 9.12.4 and Cabal's `-O1`
profile, the 100,762-character largest case changed from 30.742 ms to 28.857 ms through
`parseSurfaceSource` and from 55.581 ms to 50.273 ms through the compatibility `parseSource` route.
The workspace means stayed within measurement uncertainty because `loadWorkspace` also constructs
source indices and composes the semantic service graph.

Exact Unicode/tab/newline spans, diagnostics, semantic results, and frozen compatibility fixtures
remain unchanged. This affects parsing performed by the CLI, workspace loading, code generation,
and source-aware library or editor tooling; it does not speed up generated application runtime.

## Shared declarations

Shared declarations are visible to all nodes in the source or composed
workspace.

### IDs

```text
id TransferReservationId prefix=rsv
id HospitalId prefix=hosp
```

An `id` declares a generated nominal identifier. Language 4 admits current
TypeID-v7 values and generates a distinct Haskell type for each declaration.
The prefix is at most 63 characters, uses lowercase ASCII letters and
underscores, and cannot begin or end with an underscore. Prefixes must be unique
within the service.

An unbound ID register begins at the sentinel `placeholder`:

```text
regs
  reservationId TransferReservationId = placeholder
```

Use a checked TypeID literal in a transition write:

```text
write requestId := RequestId("req_00041061050r3gg28a1c60t3gf")
```

The literal must be canonical, have the declared prefix, and carry a UUID-v7
suffix. Application code should use the safe constructors exposed by the
generated/current ID API rather than constructing raw text wrappers.

### Enums

```text
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

```text
regs
  acuity PatientAcuity = GreenTag

guard cmd.acuity == PatientAcuity.RedTag
```

### Rules

```text
rule lifeCriticalOverride : PatientAcuity -> Bool
  ex RedTag => true ; YellowTag => false ; GreenTag => false
```

A `rule` is a total, deterministic lookup over one declared enum. Every enum
constructor must appear exactly once. Bodies can refer only to enum constructors
and Boolean values and may not sample a clock. Rules can be used as Boolean
atoms in aggregate guards.

### Consumer-owned nominal declarations

Use `using` when an ID or enum already has an application-owned Haskell type:

```text
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

```text
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

```text
regs
  orderId OrderId = initial
  status OrderStatus = initial
  accountNumber AccountNumber = initial
```

The first scaffold creates a binding skeleton. Fill it and its fixture cases;
do not duplicate wire spellings or defaults in the binding. Those remain owned
by the `.keiro` declaration.

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
`mapped opaque` declaration.

### Field inference

A field without `:Type` is inferred in this order:

1. A register with exactly the same field name.
2. A declared ID, enum, aggregate vertex, or mapped type matching the field's
   PascalCase name.
3. `Text`.

For public and persisted shapes, explicit field types are easier to review and
safer during evolution:

```text
command Adjust { amount:Integer requestId:RequestId observedAt:Time }
event Adjusted { amount:Integer requestId:RequestId observedAt:Time }
```

### Mapped type expressions

Structural mapped fields support these recursive expressions:

```text
Text
Int
Integer
Bool
Natural
Time
Json
Optional Text
List Text
List (Optional Text)
Map Text
OtherMappedType
```

`Map T` means a JSON object with text keys and values of type `T`.

## Consumer-owned mapped types

A mapped declaration keeps an existing Haskell type at the application
boundary. A structural mapping gives the DSL complete authority over its JSON
shape; an opaque mapping delegates JSON authority to the consumer type.

### Structural records

```text
mapped structural record ArtifactInfo {
  haskell package=artifact-domain module=Example.Artifact.Domain type=ArtifactInfo
  binding = "Example.Artifact.KeiroBindings.artifactInfoBinding"
  binding-version = "1"
  canonical-type = "example.artifact.ArtifactInfo.v1"
  fixtures = "Example.Artifact.KeiroBindings.artifactInfoCases"
  initial = "Example.Artifact.KeiroBindings.emptyArtifactInfo"
  wire object constructor=ArtifactInfo unknown-fields=reject {
    key         as "key"         : Text          required
    description as "description" : Optional Text optional on-missing=null
    active      as "active"      : Bool          optional on-missing=false
    tags        as "tags"        : List Text     optional on-missing=[]
    attributes  as "attributes"  : Map Text      optional on-missing={}
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
| `{}` | `Map T` |
| constructor name | structural enum |

The checker rejects recursive mappings, unresolved or ambiguous names,
ill-typed defaults, and non-injective nullability such as `Optional Json` when
JSON `null` cannot distinguish the cases.

### Structural string enums

```text
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

```text
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

### Opaque mappings

```text
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

This ownership split changes generated source layout once when adopting the
release: regenerate the service output, add `StructuralConformance` from the
Cabal fragment, and remove declaration-law expectations from aggregate-specific
inventories. Do not hand-move assertions between generated files.

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
and register roots. Candidate language 5 additionally lowers typed queue fields
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

## Aggregate expressions

Guards and register writes use a typed scalar expression language.

### Roots and paths

- `reg.name` selects a register.
- `cmd.name` selects a field of the transition's command.
- An unqualified `name` is allowed only when exactly one of those scopes
  contains it. Qualify ambiguous names.
- `cmd.details.amount` and `reg.details.amount` can traverse required fields of
  structural records to a supported scalar leaf.

Paths cannot cross an optional field, collection, union, `Json`, or opaque
mapping. They must end at `Text`, `Int`, `Integer`, `Bool`, `Natural`, `Time`,
or an eligible nominal scalar.

### Literals

```text
"text"
-100
true
false
OrderStatus.Submitted
OrderId("ord_00041061050r3gg28a1c60t3gf")
```

Quoted literals resolve as `Text` or `Time` from context. Integral literals
resolve as `Int`, `Integer`, or `Natural` from context. Enum and ID literals
must be qualified. No implicit numeric or nominal coercion exists.

### Operators and precedence

From highest to lowest precedence:

1. `*`
2. `+`, `-`
3. `==`, `!=`, `<`, `<=`, `>`, `>=`
4. `&&`
5. `||`

Comparisons are non-associative. Use parentheses to make mixed expressions
obvious.

`Integer` supports exact `+`, `-`, and `*`. `Natural` supports the same
operators, with subtraction defined as monus: `a - b` is never below zero.
`Int` arithmetic is rejected because overflow is not modeled. Division,
remainder, mixed numeric types, Time arithmetic, and collection operators are
not supported.

Equality is available for direct scalars, generated or consumer-owned IDs and
enums, and nominal scalars. Ordering is available for `Int`, `Integer`,
`Natural`, `Time`, and nominal `Int`, `Natural`, or `Time`. It is not available
for `Text`, `Bool`, IDs, or enums. Nominal arithmetic is not supported.

Comparisons and Boolean combinations produce guard predicates; they cannot be
written into a `Bool` register as scalar values.

Example:

```text
Open -- Adjust -->
  guard cmd.amount + reg.balance >= -100
    && reg.reserved + cmd.requested <= reg.capacity
    && cmd.observedAt >= reg.openedAt
    && cmd.mode == reg.mode
  write balance := reg.balance + cmd.amount * 2
  write reserved := reg.reserved + (cmd.requested - reg.capacity)
  write mode := AccountMode.Restricted
  emit Adjusted
  goto Reviewed
```

## Aggregates

An aggregate is an event-sourced consistency boundary.

```text
aggregate Reservation
  regs
    reservationId TransferReservationId = placeholder
    attempts Integer = 0
  states Unrequested Held Confirmed!

  command Request { reservationId amount:Integer }
  command Confirm { reservationId }

  event Requested = fields(Request)
  event ConfirmedEvent { reservationId }

  Unrequested -- Request -->
    guard cmd.amount > 0
    write attempts := reg.attempts + 1
    emit Requested
    goto Held

  Held -- Confirm -->
    emit ConfirmedEvent
    goto Confirmed

  wire kind=ctorName fields=camelCase schemaVersion=1
```

### Registers and states

`regs` is mandatory but may be empty. Each row is `name Type = initial`.
Register names are unique. Initial values must follow the type rules in
[Direct aggregate types](#direct-aggregate-types).

`states` is followed by one or more lifecycle states. The first is the initial
state. A trailing `!` marks a terminal state, which may not have outgoing
transitions. Every non-terminal state must be reachable from the initial state.

Use lifecycle states and `goto` for the aggregate's main state machine. A
parallel `<Aggregate>Vertex` register is rarely needed and can obscure the
single lifecycle authority.

### Commands and events

```text
command Request { reservationId amount:Integer }
event Requested = fields(Request)
event Rejected { reservationId reason:Text }
event PayloadObserved {
  type haskell payloadType:Text
  region haskell serviceRegion as "region_code":Text
}
```

Command names, event names, and fields within each constructor are unique.
`fields(Command)` declares an exact, type-identical copy. When a transition
emits that event, it must consume the named command; the generated transducer
then owns the identity output. An event with an explicit field block needs a
hand-owned output constructor because the source-to-event transformation is not
fully expressed.

A direct field has three names. Its first token is the stable DSL identity;
`haskell <selector>` optionally changes only the generated record selector;
`as "<wire-key>"` optionally changes only the JSON key. When both are present,
write them in that order. Thus `type haskell payloadType:Text` exposes
`payload.payloadType` while encoding the key `"type"`, and the `region` example
exposes `payload.serviceRegion` while encoding `"region_code"`.
`fields(Command)` copies all three identities. Selector and wire-key collisions
are checked independently, and event wire keys may not equal the codec envelope
key `"kind"`.

A wire key is **exempt from a declared `wire … fields=camelCase` convention**.
That is the point of the alias: it preserves a brownfield key the convention
would reject, as `"region_code"` above does. Wire keys are therefore checked only
for structural usability — non-empty, no leading or trailing whitespace, no
control character. Those are not style rules. The wire key is the exact bytes of
the encoded field name, so a typoed `as "family "` would ship a permanently
mis-keyed public field that no later rename could correct without breaking
consumers.

### Transitions

```text
Source -- Command -->
  guard <Boolean expression>
  write register := <scalar expression>
  emit Event
  goto Target
```

A transition must contain exactly one `goto`. It may have multiple guards,
writes, and emits; multiple guards are combined with `&&`, write and emit order
is preserved, and every reference must resolve. A live transition that changes
state or writes a register must emit persisted evidence. An eventless
transition is valid only as a no-op self-loop with no writes.

At most one live unguarded transition may use the same source state and command.
A guarded transition may not have an unguarded sibling for the same pair.
Multiple guarded siblings must be mutually exclusive; generated behavior
verification and the conformance harness expose ambiguity.

By default, Language 4 generates transition behavior from its guard, writes,
emits, and target. Use an explicit hole when the predicate or updates cannot be
expressed:

```text
Reviewed -- Close -->
  implementation hole
  emit ClosedEvent
  goto Closed
```

An implementation-hole transition may not also declare DSL `guard` or `write`
clauses. Its create-once module supplies the implementation and a `FoldVersion`.
Bump that token whenever hand-owned predicate or update behavior changes so
snapshots and replay audits can detect the new fold.

### Candidate Language 5 typed domain outcomes

Language 5 can make every selected command result explicit without turning a
business rejection into an event:

```text
language keiro-dsl 5
context reservations

enum ReservationRejection {
  AlreadyCancelled=already-cancelled
  CapacityUnavailable=capacity-unavailable
}
enum ReservationNoOp { DuplicateRequest=duplicate-request }

aggregate Reservation
  domain-outcomes rejection=ReservationRejection no-op=ReservationNoOp
  regs
    lastRequestId Text = "none"
  states Eligible CancelledState

  command Cancel { requestId:Text }
  event Cancelled = fields(Cancel)

  Eligible -- Cancel -->
    write lastRequestId := cmd.requestId
    outcome accepted
    emit Cancelled
    goto CancelledState

  CancelledState -- Cancel -->
    guard cmd.requestId != reg.lastRequestId
    outcome rejected ReservationRejection.AlreadyCancelled
    goto CancelledState

  CancelledState -- Cancel -->
    guard cmd.requestId == reg.lastRequestId
    outcome no-op ReservationNoOp.DuplicateRequest
    goto CancelledState
```

The aggregate declaration is opt-in. Once present, every live transition has
exactly one outcome clause. `accepted` requires at least one emitted event.
`rejected` and `no-op` require an eventless, write-free self-loop; replay-only
transitions have no outcome. Rejection and no-op reasons use the same typed
scalar expression scope as guards and writes: literals, enum/ID values,
command fields, pre-command registers, arithmetic, and checked mapped
projections. The expression must resolve to the declared result type.

Scaffolding exports
`Generated.<Context>.<Aggregate>.EventStream.<aggregate>DomainCommandHandler`.
Its pure classifier receives Keiki's already-selected `EdgeRef`, dispatches
directly by source state and zero-based outgoing index, and evaluates only that
arm's reason term against the pre-command registers and command. It contains
one constant-size arm per rejected/no-op edge; it does not search a map or
association list and never re-runs a guard. Accepted event retention remains a
responsibility of `Keiro.Command.runDomainCommand`, not generated code.

Behavior conformance uses `RejectedWith reason` and `NoOpWith reason` witnesses.
The generated contract steps Keiki once, verifies the exact edge and unchanged
state/registers, then compares the public handler's result with the independently
owned witness value. `Rejects RejectNoOutgoingEdges` and
`Rejects RejectNoMatchingEdge` remain the expectations for a command that did
not select an edge at all.

The parser-scaling benchmark includes `domain-outcomes/check` and
`domain-outcomes/generate` rows for 8, 32, 128, and 512 silent edges. Its
preflight asserts one arm per silent edge, rejects sequential lookup/search
dispatch, and enforces the sixfold source-growth cap for a fourfold edge
increase. The performance baseline is intentionally not published until the
repository's quiet-host benchmark prerequisite is satisfied.

### Replay-only transitions and event retirement

A replay-only transition participates in hydration but never accepts a new
command:

```text
replay-only Held -- Confirm -->
  emit LegacyConfirmed
  goto Confirmed
```

It must emit at least one event. Use it to preserve inversion of stored events
after their live behavior has been retired.

The initial state is not special. A historical first event can retain a
replay-only sibling beside the current live start rule:

```text
command Start { legacy:Bool }
event Started = fields(Start)

Empty -- Start -->
  guard cmd.legacy == false
  emit Started
  goto Active

replay-only Empty -- Start -->
  guard cmd.legacy == true
  emit Started
  goto Active
```

The generated harness emits one `acceptStart` for the live edge and no live
probe for the replay-only edge. Replay evidence uses detailed attribution and
the exact source-wide `EdgeRef`; if an initial legacy command has only a
replay-only edge, it still receives a required replay witness but no acceptance
helper. Transitions from one source may be interleaved in the specification:
generation preserves declaration order, consolidates them into one source
block, and assigns outgoing indices cumulatively across the whole source.

Event retirement is two-stage:

1. Mark `retiring event Name ...` while a live transition still emits it.
   Terminalize or truncate affected streams.
2. Change it to `deprecated event Name ...`, remove it from live emitters, and
   retain an equivalent replay-only emitter until no stored stream needs it.

`check` warns throughout the protocol and errors when a retiring event has no
live emitter or a deprecated event is still emitted live.

### Event versions and upcasters

```text
event ReservationConfirmed v2 { reservationId note:Text }
  upcast from v1 = HOLE
```

Version 1 is implicit. Every `vN` above 1 needs an `upcast from v(N-1) = HOLE`.
Across the aggregate, the upcaster chain from version 1 through the highest
event version must remain contiguous. Once shipped, a rung remains available
for old payloads.

The aggregate's `wire schemaVersion` should equal its maximum event version.
`diff` detects field additions, removals, type changes, version decreases,
missing bumps, and retirement mistakes. Use `--emit-goldens DIR` to create
non-overwriting old-shape fixtures for version bumps.

### Wire policy

Language 4 supports exactly:

```text
wire kind=ctorName fields=camelCase schemaVersion=1
```

Other `kind` or `fields` values are rejected because generation implements no
other byte convention.

### Aggregate projections

```text
projection transfer_decisions key=reservationId
  status-map {
    Requested=>held
    ConfirmedEvent=>confirmed
  }
```

`key` names the source field used by the projection. Under Language 4 it must
resolve to an aggregate register, command field, or event field. Status-map
keys are exact event names. They must be unique and resolve to events in the
aggregate. The map is total by default; use `status-map partial { ... }` when
some events intentionally do not change projected status.

In Languages 1–4, prefer declaring a matching `readmodel` node. It then owns
schema identity, feed, consistency, and rebuild metadata. An optional
`consistency=Strong|Eventual` on `projection` must agree with the read model.
A projection without a read-model node remains usable but produces a warning
and has no registered schema or rebuild authority. In Language 5 this is a
standalone implicit-inline compatibility form: the referenced read model owns
`freshness`, only `immediate` is reachable, and a projection-level
`consistency` clause is rejected. Catalog-managed queries should use a
top-level projection owner instead.

### Snapshots

```text
snapshot every 100
  state-codec version=1 shape-hash="<captured-live-hash>"
```

or:

```text
snapshot on-terminal
  state-codec version=1 shape-hash="<captured-live-hash>"
```

Intervals and codec versions start at 1, and the hash must be non-empty. The
hash captures the live Haskell state shape; it is independent of event JSON.
Scaffold with a placeholder, run the generated snapshot conformance component,
copy its reported live hash into the specification, scaffold again, and rerun
the harness. Snapshots are advisory caches: a changed codec version, shape hash,
fold identity, or mapped-register identity invalidates stale caches and falls
back to replay.

## Processes and timers

A `process` coordinates a saga aggregate, target aggregates, command dispatches,
and one durable timer.

```text
process HospitalSurge
  name "hospital-surge"
  input SurgeInput { hospitalId availableIcuBeds:Int observedAt:Time }
  correlate input.hospitalId via idText
  saga Surge category "hospitalSurge"
  target Hospital
  projections [ ]

  on SurgeInput
    advance NoteSurgeThreshold { hospitalId timerId=timer.id }
    dispatch Hospital@input.hospitalId ActivateSurge { hospitalId }
      on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
    schedule surgeFollowUp

  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)
  rejected => halt
  poison => halt

  timer surgeFollowUp
    id uuidv5 "hospital-surge-timer:" <> correlationId
    fireAt input.observedAt + 5m
    payload { kind="hospital-surge-follow-up" hospitalId }
    fire dispatch Surge@correlationId MarkSurgeTimerFired { hospitalId timerId }
      fired-event-id uuidv5 "hospital-surge-fired:" <> correlationId
      on-ok Fired ; on-reject Fired ; on-ambiguous Retry ; on-error Retry ; not-mine Retry
    decode unknown-status => Cancelled
    max-attempts 5 dead-letter "surge timer exceeded ceiling"
```

The block identifier (`HospitalSurge`) selects generated modules. `name` is a
stable durable identity shared with the process runtime; it must be non-empty,
must not be `$all`, whitespace, control characters, or contain `:`, and must be
unique across all processes, routers, and workflows.

`saga` and `target` resolve to aggregates. The saga category is a validated
stream category: it must not contain `-`, whitespace, control characters, or
`:`, and cannot be `$all`. Use camelCase for compound categories.

Bindings are either bare input-field copies, `input.<field>` references, quoted
literals, or the exact runtime-owned value `timer.id`; timer-fire bindings may
also copy declared timer payload fields or bare `timerId`. Under Language 4,
the correlate field, dispatch and fire keys, and all
binding values must resolve within those scopes. Advance, dispatch, timer,
command, target, field, projection, and scheduled-timer references are checked.
Do not bind `commandId` or `id`; dispatch identities are runtime-owned.

`fireAt` must reference an injected `:Time` input field. The notation has no
clock-sampling form, and Language 4 rejects a duration whose unit-adjusted
seconds do not fit in `Int`. The timer ID and fired-event ID expressions must
end in `correlationId`; their parsed identifiers are not general field
references.
`decode unknown-status => Name` names the status an undecodable timer row is
read as; it must be one the timer table actually stores — `Scheduled`, `Firing`,
`Fired`, `Cancelled`, or `Dead`. The quoted `dead-letter` text is operator
guidance rendered into the timer hole rather than a runtime category identity:
`runTimerWorkerWith` composes its own message for the attempt ceiling, and an
operator-written worker passes this text to `Keiro.Timer.deadLetterTimer`. It
must therefore say something; a blank reason is refused. `max-attempts` is at
least 1. `not-mine` must be `Retry`: the worker marks a timer `Fired` only when
the fire action returns the id of an event it appended, and a dispatch that is
not this timer's has none. `on-ambiguous` must be `Retry`:
command ambiguity is an aggregate-definition defect, never benign success, and
the ceiling provides a durable dead-letter witness.

`rejected` and `poison` are each `halt`, `deadLetter`, or `skip`. Align the
node-level rejected policy with every dispatch's `on-failed` action. Mapping a
duplicate append to `AckOk` is an explicit benign inversion and produces a
warning; generated runtime code confirms the attempted event ID against the
target stream before acknowledging it.

## Routers

A router resolves zero or more target rows for an input and dispatches one
command per row without keeping its own event-sourced state.

```text
router HospitalTransferRouter
  name "hospital-transfer-router"
  input AcceptedTransferNeed { transferNeedId region }
  key input.transferNeedId via idText
  resolve stable via read-model hospital_load row { hospitalId }
  target Hospital
  projections [ ]
  dispatch-each RouteAcceptedTransferNeed {
    transferNeedId=input.transferNeedId
    hospitalId=resolved.hospitalId
  }
    on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
  dispatch-id strategy=uuidv5 from=(name, key, sourceEventId, targetStreamName, occurrence)
  rejected => deadLetter
  poison => halt
```

`name` follows the stable identity rules described for processes. `key` must
name an input field. A resolver is either `via read-model Name` for a declared
read model or `via hole` for another typed effectful implementation. Under
Language 4, every `row` field on a read-model resolver must name a column of
that read model; only verified row fields become available under `resolved.*`.

The mandatory `resolve stable` phrase acknowledges retry semantics: later
attempts deduplicate targets already dispatched, but a resolver whose result
changes can accumulate the union of targets seen across attempts.

Candidate Language 5 also admits a checked, bounded selection:

```text
resolve declarative {
  identity = "hospital-transfer-selection"
  version = 1
  query = read-model hospital_load with input
  where = row.region == input.region && row.availableBeds > 0
  recipient = row.hospitalId
  order = target-stream
  dedupe = target-stream
  max-recipients = 64
  empty => ack
  failure => retry
  redelivery = stable-union
  partial = retain-successes
}
```

The query input must be mapped structural and the query result must be a list of
mapped structural rows. Check resolves and types the key, predicate, recipient,
and every dispatch field; requires a positive recipient limit; and admits only
the normalization and redelivery policies shown above. The application still
owns the read-model SQL body. Generated code filters and maps its typed result,
sorts commands by physical target stream, collapses exact duplicates, rejects
unequal commands for one stream, and applies the cap after deduplication before
performing any write.

`empty` accepts `ack`, `retry`, `deadLetter`, or `halt`. `failure` accepts
`retry`, `deadLetter`, or `halt`; failures include query/evaluation errors,
target conflicts, and cap overflow. Dispatch itself remains one transaction per
target and retains earlier successes. See
[Routers And Effectful Fan-Out](../guides/routers-and-effectful-fan-out.md#declarative-selection-in-language-5)
for the complete contract and evolution workflow.

Dispatch binding values may be quoted literals, `input.*`, or `resolved.*`.
Bare bindings copy an input field of the same name. Target aggregate, command,
command fields, read model, and projection references are checked. The
dispatch-ID expression is fixed runtime policy and must be written exactly as
shown.

## Integration contracts

A contract owns public event names, topic aliases, and payload fields:

```text
contract emergency {
  schemaVersion 1
  discriminator messageType

  topic incidentEvents "emergency.incident.events"
  topic hospitalEvents "emergency.hospital.events"

  event TransferReservationAccepted on hospitalEvents {
    incidentId: typeid "inc"
    reservationId: typeid "rsv"
    hospitalId: typeid "hsp"
    family: text
    type haskell payloadType: text
    region haskell serviceRegion as "region_code": text
    expirationDeadline: text
  }
}
```

`schemaVersion` starts at 1. Topic aliases and event names are unique, and every
event's alias must resolve. A Kafka topic is 1–249 ASCII characters from
`A-Z`, `a-z`, `0-9`, `.`, `_`, and `-`, excluding `.` and `..`.

Contract field types are:

| Syntax | Generated type |
| --- | --- |
| `typeid "prefix"` | `KindID "prefix"` with current TypeID-v7 decoding |
| `text` | `Text` |
| `int` | `Int` |

Field names are unique within an event and cannot equal the contract
discriminator. TypeID prefixes follow the same validity rules as shared IDs.
The generated decoder rejects malformed, non-canonical, non-v7, and
wrong-prefix values at the field path.

Contract fields use the same optional `haskell` selector and `as "wire-key"`
aliases as aggregate fields. The generated record uses `payloadType` and
`serviceRegion` in the example, while JSON retains `"type"` and
`"region_code"`. Resolved selectors must be valid and unique within the event
record; wire keys must be non-empty, unique, and distinct from the declared
discriminator. A selector-only diff requires re-scaffolding and recompilation;
changing a public wire key is a breaking contract change and consumers deploy
before producers.

## Intakes

An intake connects one contract topic to the inbox:

```text
intake incidentInbox {
  contract emergency
  topic incidentEvents
  accept IncidentTransferNeedDeclared

  bind source from header "keiro-source" required
  bind schemaVersion from header "keiro-schema-version" required cross-check body
  bind messageId from header "keiro-message-id" required cross-check body
  bind key from kafka-key
  bind occurredAt from kafka-cursor
  bind idempotencyKey from body

  dedupe key messageId policy PreferIntegrationMessageId
  persist = dedupe-only

  decode {
    envelope strict-required lenient-optional
    body strict schemaVersion == 1
  }

  disposition {
    processed => ackOk
    duplicate => ackOk
    inProgress => retry 5s
    previouslyFailed => deadLetter "previous inbox failure"
    decodeFailed => deadLetter
    dedupeFailed => deadLetter
    storeFailed => retry 5s
  }
}
```

`contract`, `topic`, and every accepted event must resolve, and accepted events
must belong to the intake topic. One or more event names follow `accept`.

Bind sources are `header "name"`, `body`, `kafka-key`, and `kafka-cursor`.
`required` and `cross-check body` are optional descriptive flags. A bound name
and the dedupe key must resolve to either a field on an accepted contract event
or one of the canonical envelope names, but generated code does not consume the
binding rows or enforce either flag. A flagged row therefore produces
`IntakeBindFlagUnenforced`; consumer-owned decode wiring remains responsible
for the declared binding posture. A `header "name"` source must name one of
keiro's canonical envelope headers (`keiro-message-id`, `keiro-source`,
`traceparent`, and so on). The Kafka inbox reconstructs an envelope from that
fixed set and cannot be remapped, so any other header would describe a
remapping that does not happen and is refused.

```text
messageId source destination key eventType schemaVersion contentType
schemaReference sourceEventId sourceGlobalPosition payloadBytes occurredAt
causationId correlationId traceContext attributes idempotencyKey
```

Dedupe policies are `PreferIntegrationMessageId`,
`PreferSourceEventIdentity`, and `KafkaDeliveryIdentity`.

`persist` is optional and defaults to `full-envelope`. Use `dedupe-only` only
when a successfully processed payload is re-fetchable or no longer valuable;
failed rows keep the full envelope for operators regardless of this choice.

The envelope policy is exactly `strict-required lenient-optional`, and the body
schema version must equal the contract version. Body mode must be `strict`:
generated contract codecs decode every declared body field as required and emit
no lenient fallback, so `lenient` is refused as a description of something that
does not run. The word is still parsed and a posture change is still
diff-classified. The
disposition table is mandatory and contains each of the seven rows exactly
once. Duplicates acknowledge success, a previous terminal failure does not
retry, poison decode failures dead-letter, and transient/in-progress outcomes
use bounded retries according to the declared action. Language 4 rejects any
retry duration whose unit-adjusted seconds do not fit in `Int`.

## Emits and publishers

An emit maps a private discriminant to public contract events:

```text
emit reservationResponse {
  contract emergency
  topic hospitalEvents
  source "hospital-capacity"
  key incidentId
  map status {
    "confirmed" => TransferReservationAccepted
    "rejected" => TransferReservationRejected
    _ => skip
  }
  messageId derive "msg" hole
  idempotencyKey derive hole
}
```

The contract, topic, and mapped events must resolve, and every mapped event must
belong to the selected topic. Discriminant strings are unique. The explicit
`_ => skip` catch-all is mandatory. `source`, `key`, and the map's discriminant
name are descriptive because no typed source read-model namespace is declared;
their values are not field-resolution programs. An emit is validated and
diff-classified but produces no generated module today.

`derive ["prefix"] hole` documents a hand-owned derivation responsibility; it
does not create a module or typed signature. Because the clause is mandatory
grammar, this is true of every emit in every spec, so it carries no per-spec
diagnostic; the scaffold report's no-modules line names each emit node that
contributed nothing. The hand-owned implementation must be deterministic so
retries reproduce the same IDs.

A publisher owns delivery policy for one emit:

```text
publisher hospitalPublisher {
  emit reservationResponse
  ordering PerKeyHeadOfLine
  maxAttempts 10
  backoff exponential 2s max=60s multiplier=2.0
  outboxId stable from messageId
}
```

`emit` must resolve and `maxAttempts` starts at 1. Ordering is one of:

- `PerKeyHeadOfLine`
- `PerSourceStream`
- `StopTheLine`
- `BestEffort`

Backoff is either `constant <duration>` or
`exponential <initial> max=<duration> multiplier=<decimal>`. Exponential
backoff requires both options, a positive initial delay, a maximum at least as
large as the initial delay, and a multiplier of at least 1. Language 4 also
rejects any delay whose unit-adjusted seconds do not fit in `Int`.
`outboxId stable from <field>` declares the identity that coalesces retries;
under Language 4 the field must be `messageId`, `idempotencyKey`, or a field of
an event mapped by the publisher's emit.

## Work queues and dispatch

### Work queues

```text
workqueue reservation_work {
  queue logical = "hospital_capacity.reservation_work"
  derive physical = "hospital_capacity_reservation_work"
         dlq = "hospital_capacity_reservation_work_dlq"
         table = "pgmq.q_hospital_capacity_reservation_work"

  ordering fifo-throughput
  group key from reservationId via raw
  provision standard

  payload ReservationWorkItem {
    reservationId -> "reservation_id" text required
    hospitalId -> "hospital_id" text required
    attempts -> "attempts" int required
    urgent -> "urgent" bool required
  }

  retry maxRetries = 3 delay = 5s dlq = on

  disposition {
    storeFailure -> retry 5s
    commandRejected -> deadLetter
    decodeFailure -> deadLetter
    onCodecReject -> deadLetter
  }
}
```

The logical queue name is the durable source identity. The physical queue, DLQ,
and backing table are captured fixtures; `check` re-derives them and rejects
drift. Long or otherwise non-simple logical names may use a stable hashed
physical derivation; copy the values reported by the checker or a generated
starter rather than inventing them.

Payload rows are `field -> "wire_key" type [required]`. Language 4 closes the
type vocabulary to `text`, `int`, and `bool`, which lower to `Text`, `Int`, and
`Bool`; other words are rejected instead of silently becoming `Text`.
Every payload field is required: generated decoders read all of them with
`o .:`. The `required` marker is therefore accepted but selects nothing, and a
row written with it and a row written without it describe the same queue. For
the same reason, *adding* a payload row is a breaking change however it is
spelled — a job already queued under the old shape does not contain it. Queue
payload evolution is a persisted wire change and must go through `diff`.

Candidate language 5 additionally reserves a colon form for a complete mapped
type expression:

```text
jobData -> "job_data" : List (Optional ArtifactInfo)
```

The colon is the language-5 feature boundary; languages 1 through 4 reject it
at that token and retain their released scalar interpretation. Candidate
scaffolding lowers the complete expression through the checked mapped graph,
imports the exact application-owned Haskell types, and emits structural field
codecs or opaque `ToJSON`/`FromJSON` boundaries. Required, optional, and
present-null behavior is explicit. The queue keeps its schema-version-1
`{v,t,data}` envelope; incompatible queued jobs still require a drain or a
declared transitional codec rather than an automatic upcaster.

Ordering is `unordered` (the default), `fifo-throughput`, or
`fifo-roundrobin`. FIFO requires a group key; unordered queues reject one.
`via raw` requires a `text` field. An opaque derivation uses:

```text
group key from reservationId via reservationGroup
  fixture "rsv_... => group-a"
```

The fixture captures the expected hand-owned derivation.

Provisioning is `standard` (the default), `unlogged`, or:

```text
provision partitioned(interval="daily", retention="7 days")
```

Unlogged queues are truncated after a PostgreSQL crash and produce a warning;
use them only for regenerable work. Partition interval and retention must be
non-empty and are create-time settings. Changing provisioning does not migrate
an existing queue.

`dlq=on` requires `maxRetries >= 1`. Language 4 rejects retry and queue-delay
durations whose unit-adjusted seconds do not fit in `Int`. The disposition
table contains all four named outcomes exactly once. `storeFailure` is
transient and retries; `decodeFailure` is poison and dead-letters. Generated
policy uses a closed queue-specific outcome type, so new rows and spelling
mistakes become compile errors in hand-owned handlers.

### Read-model-driven dispatch

```text
dispatch reservation_work_dispatch {
  source readModel = accepted_transfer_needs key = reservationId
  fanout body = resolveTransferCandidates
  dedup key = reservationId
        seenIn readModel = transfer_decisions field = reservation_id
        seenIn queue = reservation_work field = reservation_id
  enqueue to = reservation_work
}
```

The source and dedupe read models, dedupe column, dedupe queue, queue payload
field, and enqueue target must resolve. Under Language 4, the source key must
also name a generated logical selector for a column of the source read model
(`reservationId` resolves the SQL column `reservation_id`). `fanout body` names
a hand-owned effectful one-to-many function, not a column; it must be a
lowercase-initial identifier that could name a Haskell function. The top-level
`dedup key` obeys the same rule as the source key: it must name a generated
logical selector for a column of the source read model. The two `seenIn` fields
are the enforced dedupe boundaries. A dispatch is validated and diff-classified but produces no
generated module today. Keep the hand-owned queue-side SQL check consistent
with the declared wire key and read-model check.

## Read models

The first form below is the published Languages 1–4 compatibility grammar. It
keeps physical coordinates, delivery feed, and the historical consistency
vocabulary on the read model. Candidate Language 5 uses the catalog form later
in this section and does not accept those delivery/consistency fields.

```text
readmodel transfer_decisions {
  table = "transfer_decisions"
  schema = "hospital_capacity"
  columns {
    reservation_id text required
    hospital_id text required
    status text required
    decided_at timestamptz
  }
  version = 1
  shape = "fnv1a:3717f6d9e3c44bd6"
  consistency = Strong
  scope = category "reservation"
  feed = subscription
  subscription = "hospital-capacity-transfer-decisions-sub"
}
```

`schema`, `table`, and column names must be unquoted PostgreSQL identifiers:
`[a-z_][a-z0-9_]{0,62}`. Column names are unique. Supported SQL types are
`text`, `int`, `bigint`, `bool`, `timestamptz`, `jsonb`, and `numeric`.
`required` means non-null.

`version` starts at 1. `shape` is a captured FNV-1a-64 identity derived from
the table and ordered column surface. If it drifts, `check` prints the expected
value. Update the hash and bump `version` when the real table shape changes.

In Languages 1–4, consistency is `Strong` or `Eventual`. A strong model requires
`feed = subscription`; it cannot be inline-only because a strong read waits for
a subscription cursor. `scope` is legal only for a strong model and is either
`entire-log` or `category "name"`; omitted strong scope defaults to the entire
log. Feed is `inline` or `subscription`. An inline model must be referenced by
an aggregate projection of the same name. A `subscription` override beside
`feed = inline` is ignored and produces `RmInlineSubscriptionIgnored`. A
subscription name is optional for `feed = subscription`; the tool derives a
stable default when omitted. Under Language 4, explicit subscription and scope
category strings must satisfy the stable runtime-identity rules.

The SQL table remains application-migration-owned. The scaffold generates
schema-qualified table facts and create-once apply/query functions. Use the
generated table constant in SQL rather than depending on PostgreSQL
`search_path`.

Candidate language 5 may declare the two type parameters of `ReadModel q r` as
one ordered pair after `columns`:

```text
query input = AccountLookup
query result = Optional AccountSummary
```

Both clauses are required together and resolve complete mapped type
expressions. Languages 1 through 4 reject the first `query` token; an omitted
second clause is a parse error rather than a partial semantic contract.

Scaffolding emits `Generated.<Context>.<ReadModel>.QueryContract`; its aliases use the exact
consumer domain types and deterministic imports. The generated `ReadModel` imports those aliases,
and a newly created hand-owned `ReadModelHoles` imports them for the application query signature.
No query JSON codec or SQL row conversion is generated. SQL columns, row codecs, DDL, migrations,
and query bodies remain application-owned.

If the output already contains a legacy create-once hole with local `QueryInput = ()` and
`QueryResult = ()` aliases, scaffolding preserves it and reports a migration obligation. Remove
those local aliases and import the generated pair; compilation stays red until that application
edit is complete. Query input/result changes are build-breaking API changes, but do not change the
read-model shape hash, catalog fingerprint, target reset policy, replay impact, or persisted
history. A legacy ledger without query-contract rows reports its baseline as unavailable rather
than guessing that the old API was `()`.

### Candidate Language 5 projection catalogs

Language 5 is the current unreleased authoring candidate. It adds a closed
projection catalog without changing the meaning of any language-1–4 source. Do
not rewrite an existing language-4 workspace merely to follow the default; opt
in when the service is ready to declare the complete read-side inventory.

```text
language keiro-dsl 5
context catalog-demo

target order_summary {
  schema = "sales"
  table = "order_summary"
  reset = clear
}

target order_totals {
  schema = "sales"
  table = "order_totals"
  reset = clear
  depends-on = [ order_summary ]
}

rebuild-group reporting {
  targets = [ order_summary order_totals ]
  order = [ order_summary order_totals ]
}

projection-owner order_summary_writer {
  source = aggregate Orders
  delivery = subscription
  group = reporting
  targets = [ order_summary order_totals ]
  order = 10
  subscription = "catalog-demo-orders"
  dedup = "catalog-demo-orders-v1"
  checkpoint-on-missing = from-beginning
  replay = explicit
}

readmodel orderSummary {
  columns {
    order_id text required
  }
  version = 1
  shape = "fnv1a:784e511a19f74c58"
  freshness = immediate
  group = reporting
  targets = [ order_summary ]
}
```

A `target` is the only physical schema/table authority. `reset = clear`
permits group preparation to truncate it; `preserve` leaves brownfield rows in
place for an explicit reconciliation adapter. `depends-on` names targets in
the same group and must be acyclic. A `rebuild-group` lists exactly its targets
and their deterministic preparation order.

Each `projection-owner` selects exactly one typed source: `aggregate Name`,
`category "name"`, or `all`. Split independent sources into separate owners.
It owns at least one target in one group and has a globally unique numeric
handler order. Subscription delivery also requires `subscription` and `dedup`
identities and a query model that observes one of its targets. Inline delivery
must omit those identities. A subscription must also choose exactly one
`checkpoint-on-missing` policy: `from-beginning` replays retained history,
`from-current-head` starts with future events when no row exists, and `fail`
refuses startup until an operator provisions the checkpoint. Inline owners must
omit this policy because they have no durable checkpoint. A replayable owner of
a `reset = clear` target cannot choose `from-current-head`, because clearing the
target and skipping retained history cannot reconstruct it. `replay =
explicit` generates distinct live and replay apply holes. `replay = live-only
"reason"` generates no replay adapter
and is invalid for a clear target.

Target ownership is also query-supply authority. Every catalog-bound read model must
name a non-empty observed-target set whose members all belong to one projection owner
in the same rebuild group. Several read models may observe different subsets of one
owner's targets and resolve to that same owner. The owner handler is generated and
selected once per event source, independently of query count. Do not repeat the
relationship with an aggregate-local `projection <readmodel>` clause; candidate
language 5 reports that as conflicting legacy ownership. A multi-target query's
`backing = <target>` still selects one physical SQL table and does not stand in for the
complete supplier check.

Projection delivery and query freshness are separate Language 5 axes:

```text
delivery = inline
delivery = subscription

freshness = immediate
freshness = wait-for-head entire-log
freshness = wait-for-head category "orders"
```

`immediate` performs no cursor wait and is valid for either owner delivery; an
immediate query supplied by a subscription owner may observe lag. `wait-for-head`
requires one compatible durable subscription cursor derived from the supplying
owner. Entire-log waits require an all-stream source. Category waits accept an
all-stream source or the same category. Inline/implicit owners, missing cursors,
several compatible cursors, or unreachable scopes fail checking as
`CatalogQueryWaitWithoutCompatibleCursor` or
`CatalogQueryWaitWithAmbiguousCursor`. A rebuild group mixing an all-stream owner
with category-scoped owners fails as `CatalogAmbiguousSourceOrdering`, matching
runtime catalog validation. Static Language 5 has no position-wait form; callers
use `runQueryWithFreshness (WaitForPosition options)` with a concrete append
position.

A catalog-bound `readmodel` is a typed query contract. It names its group and
observed targets, declares `freshness = immediate | wait-for-head ...`, and
deliberately omits `schema`, `table`, `feed`, `subscription`, `consistency`, and
`scope`. Physical coordinates belong to target declarations; delivery and cursor
identity derive from the resolved owner. The generated context-level
`Generated.<Context>.ProjectionCatalog` validates one runtime catalog, exports
typed owner/source inline views, `projectionCatalogQuerySupplies`,
registration/inventory functions, and group-scoped rebuild starters.
`<Context>.ProjectionCatalog.ProjectionCatalogHoles` is create-once
and owns live apply, replay apply, heterogeneous decoder, and idempotency
bodies. Regeneration never overwrites reviewed hole code.

A source of `aggregate Name` derives its mapped consumer dependencies from
that aggregate's private-event roots; inline aggregate projections use the
same event authority. Neither relation inherits command-only or register-only
mapped roots, nor queue/query roots declared elsewhere in the service. The
derived relation retains complete transitive paths such as
`Orders event OrderRecorded .payload : OrderPayload .reference : SharedReference`.
Scaffold output reports each typed inline/catalog consumer separately from its
operational group, targets, observing read models, replay policy, and source
fingerprint. Targets and query models are review/rebuild evidence, not a claim
that Keiro inferred SQL column dependencies.

A mapped private-event wire change updates the generated aggregate-source
fingerprint. The ordinary event compatibility finding remains authoritative for
stored payloads; projection findings additionally identify handlers that must
recompile and be reviewed. Replayable catalog owners invalidate their running
rebuild fingerprint and name their affected group. Inline and live-only owners
have build/review impact but no replay impact. Command-only, register-only, and
query-only mapped changes leave the aggregate-source fingerprint byte-stable.
`category` and `all` remain heterogeneous hand-decoded sources, so the checked
graph reports their unsupported typed boundary without inventing a mapped
consumer path.

Catalog declarations do not create tables, migrations, indexes, row codecs, or
SQL. They also cannot prove which tables an unrestricted Hasql transaction
writes. Keep application DDL and qualified SQL under the migration ownership
rules in [Migration Ownership](migration-ownership.md).

## Workflows

```text
workflow HospitalTransferReservation
  name "hospital-transfer-reservation"
  in ReservationWorkflowInput {
    reservationId:Id
    coolingOffDelay:Duration
  }
  out ReservationWorkflowSummary
  id from input.reservationId via idText
  body
    step create-transfer-hold -> ReservationHold
    patch fraud-check-v2 {
      step fraud-check -> FraudCheckResult
    }
    await reservation-confirmation -> ReservationConfirmation
    sleep cooling-off after coolingOffDelay
    child ship-order id input via shipChildId -> Text
    continueAsNew RolloverSeed
```

`name` is the stable workflow identity and follows the same rules and
cross-family uniqueness constraint as process and router names. `in` declares
an input type and optional field inventory; `out` declares the output type.
`id from input via fn` derives from the whole input, while
`id from input.field via fn` requires that field to exist.

The body is ordered, but replay matches journal records by label. Labels across
steps, waits, sleeps, children, and nested patches must be unique. A sleep's
delay names an input field, so time is injected rather than sampled. Child IDs
come from the named hand-owned derivation function.

`patch id { ... }` journals a durable branch decision for an in-flight
evolution. Patch IDs are unique across nested blocks and cannot contain `:`.
Do not reuse an old ID. Use a patch for a coordinated multi-step change; a
single changed step can usually receive a new label.

`continueAsNew SeedType` rotates an unbounded workflow to a new journal
generation. It may appear only as the final top-level body item, never inside a
patch.

Workflow behavior remains hand-owned. The scaffold generates durable facts and
runtime wiring, not the workflow's business body.

## Operations

Operations name application entry points. Four shapes are supported. Operation
declarations are validated and diff-classified but produce no generated module
today; the command/query/signal/run implementation boundary is hand-owned.

### Command operation

```text
operation ConfirmReservation
  command on Reservation
    stream from reservationId via reservationStream
    project [ transferDecision ]
```

The aggregate, stream field, and projections must resolve. `via` names the
hand-owned stream derivation.

### Query operation

```text
operation QueryTransferDecision
  query transferDecision
    input TransferReservationId
    result Maybe TransferDecision
    consistency Strong
```

The read model must resolve. Consistency is `Strong`, `Eventual`, or
`PositionWait`; omitted consistency defaults to `Strong`. The result is kept as
a Haskell type phrase and can contain multiple identifiers.

### Signal operation

```text
operation SignalReservationConfirmation
  signal reservation-confirmation of HospitalTransferReservation
    key from reservationId via reservationWorkflowId
    value ReservationConfirmation
```

The workflow and await label must resolve, and `value` must equal the await's
result type. A mismatch would create a different awakeable identity or payload
and leave the workflow waiting.

### Run operation

```text
operation RunReservationWorkflow
  run HospitalTransferReservation
    input ReservationWorkflowInput
    outcome -> ReservationWorkflowRun
```

The workflow must resolve. The input and outcome names define the hand-owned
application boundary.

## Service workspaces

Use a `.keiro-workspace` manifest when one service is split across several
complete `.keiro` files:

```text
service demo-project
runtime-package demo-project-runtime
module Demo.Modules.Project
layout collocated
spec domain/project-artifact.keiro
spec domain/project.keiro
spec domain/shared.keiro
```

Each member remains a complete source beginning with `language keiro-dsl 4`
and declaring the same `context`. The workspace manifest itself has no language
preamble.

`service` is the stable workspace identity. Optional `runtime-package` names the
consumer Cabal library that compiles the generated service modules; it is build
metadata and need not match `service`. Optional `module` and `layout` are
workspace authority: member clauses must be absent or exactly equal. At least one
`spec` path is required. Paths are manifest-relative, must stay beneath the
manifest directory, use forward slashes, and end in `.keiro`.

Membership is a set and is canonically sorted by normalized path, so reordering
`spec` lines changes neither meaning nor generated bytes. Shared IDs, enums,
rules, mapped declarations, and nodes have one owning member; identical
duplicates are still errors. All file-taking commands accept a workspace and
validate the composed service before acting.

### One runnable conformance package per service

When a workspace declares `runtime-package`, scaffolding generates one local
Cabal package for the complete `service` under the same output root:

```text
src/keiro-dsl-conformance.workspace.demo-project/
  keiro-demo-project-conformance.cabal
  keiro-dsl-conformance-ledger.txt
  src/Main.hs
  src/KeiroConformance/Expectations.hs
```

The member and node counts do not change the package count. A standalone
`.keiro` source opts in with `scaffold --runtime-package PACKAGE` and uses the
distinct `keiro-dsl-conformance.<context>` slot. The explicit package name is
required because a service such as `mori` may be implemented by a differently
named library such as `mori-core`.

The runtime Cabal fragment exposes one generated service facade and keeps all
per-node modules internal. Add the facade to the runtime library exactly as the
manifest says. Then add one stable glob to the repository's root
`cabal.project`:

```cabal
optional-packages:
  service-runtime/src/keiro-dsl-conformance.workspace.*/*.cabal
```

The normal developer and CI command is now stable across member and node
changes:

```bash
cabal test keiro-demo-project-conformance
```

The runner executes the service structural checks once under the `structural/`
prefix, followed by every aggregate and read-model self-check. Process, router,
and workflow facts are compared by qualified key with the create-once
`KeiroConformance.Expectations` module. Keiro populates that module only on the
first scaffold. Later scaffolds never overwrite it, including under
`--force-generated-overwrite`; review and edit it to accept an intentional fact
change. Added, removed, duplicate, or changed facts make the generated target
fail until reviewed.

The package ledger makes repeat runs observable: byte-identical generated files
are reported `unchanged`, Expectations is reported `skipped: already present`,
and removed package files are reported stale but never deleted. Package and
runtime ownership checks both finish before either tree is written, so a
bannerless generated Cabal or runner file refuses the complete scaffold.

The text `keiro-dsl-cabal-fragment.*.txt` remains authoritative for runtime-library
modules and dependencies. The generated package replaces hand-written harness
drivers and test stanzas; it does not remove the need to reconcile that runtime
manifest when generated modules or dependencies change.

To migrate an existing hand-written harness driver, configure the runtime
package, expose the generated facade from the runtime library, add the stable
project glob, and run the old and generated targets together once. Remove the
old driver and stanza only after their results agree.

## Generated and hand-owned files

Scaffolding has two ownership classes:

- Generated modules carry the exact Keiro generated banner. A later scaffold
  may replace them.
- Hole, behavior-evidence, router-value, process-manager, read-model, workflow,
  and binding modules are create-once. A later scaffold skips them so filled
  behavior survives.

Never edit a generated module. Change the specification and scaffold again.
If generated code does not represent the checked declaration faithfully, that
is a toolchain defect rather than an invitation to patch the output.

### Generated Haskell imports

Each generated Haskell module plans its complete import set before rendering.
A consumer-owned type with a unique occurrence name is imported explicitly and
used unqualified. If the name conflicts with another import or a local
declaration, Keiro uses a deterministic short module alias instead. External
values, constructors, generated structural shapes, nominal representations,
fixtures, initials, and binding APIs are always short-qualified so their owner
remains visible. Repeated references merge into one sorted import declaration.

Alias selection uses the shortest unique suffix of the complete module name
and is independent of declaration order, so a second scaffold of an unchanged
workspace produces the same bytes. This is Haskell presentation only: complete
module names remain in manifests, fingerprints, diagnostics, scaffold history,
and provenance. Existing create-once consumer modules are never rewritten for
import style; only a newly created skeleton uses the current presentation.

Before writing, scaffold plans the whole service and checks validation,
case-folded module/path collisions, import cycles, generated-name safety,
lowering support, and existing-file ownership. One refusal stops the write.
`--force-generated-overwrite` bypasses only the missing-banner protection for
a generated target; it does not overwrite create-once hand code.

### Scaffold sidecars

Every sidecar name states who owns the file and what it does:

- `keiro-dsl-ledger.context.<context>.txt` or
  `keiro-dsl-ledger.workspace.<service>.txt` is the machine-owned history read
  by later scaffold runs. It carries source language, generated paths, mapped
  provenance, and ownership. Commit it; do not edit or discard it.
- `keiro-dsl-cabal-fragment.context.<context>.txt` or
  `keiro-dsl-cabal-fragment.workspace.<service>.txt` is human-facing text to
  paste into the consuming Cabal stanza.
- `keiro-dsl-conformance-ledger.txt`, inside an enabled conformance package,
  is machine-owned package history. Its typed JSON rows tolerate unknown row
  kinds and unknown JSON keys while still rejecting corrupt records, unsafe
  paths, duplicate paths, and a mismatched service key.
- `keiro-dsl-migration-report.workspace.<service>.txt` is a one-time human
  review report produced when a workspace adopts attributable standalone
  history.

The breaking rename glossary is:

| Before | Current |
| --- | --- |
| `keiro-dsl-scaffold-record.<context>.txt` | `keiro-dsl-ledger.context.<context>.txt` |
| `keiro-dsl-scaffold-record.workspace.<service>.txt` | `keiro-dsl-ledger.workspace.<service>.txt` |
| `keiro-dsl-conformance-record.txt` | `keiro-dsl-conformance-ledger.txt` |
| `keiro-dsl-manifest.<context>.txt` | `keiro-dsl-cabal-fragment.context.<context>.txt` |
| `keiro-dsl-manifest.workspace.<service>.txt` | `keiro-dsl-cabal-fragment.workspace.<service>.txt` |

If any old-name sidecar remains, ordinary scaffolding refuses before reading
history or writing output and lists every required move. Review the list and
rerun with `--apply-name-migrations`. A lone old file is renamed losslessly; if
both names exist, the new file stays authoritative and the old bytes move under
`.keiro-dsl-name-migrations/sidecar-v1/`. A legacy conformance record is
converted to the current ledger format while its original bytes are retained in
that backup slot. A further run plans no sidecar moves. The `superseded-by:`
marker remains exclusive to workspace adoption and is never written by a
sidecar rename.

Every successful run also reports created, overwritten, unchanged, skipped,
and stale paths.

With an effective runtime package, the same run also writes the one
service-keyed conformance package described above and prints its exact
`cabal test` target.

Stale paths are informational and are never deleted. Review them against
version control or a fresh disposable scaffold. A stale generated file with an
exact banner is a deletion candidate; a missing banner or any create-once path
must be preserved for review.

The one source-moving exception is an upgrade from a recorded legacy generated-name
edition. Ordinary scaffolding first refuses without mutation and prints every exact
old/new/backup path. After review, rerun with `--apply-name-migrations`. Keiro preserves
the original bytes below
`.keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/`, rewrites only exact module
references in Haskell code (never comments or literals), and writes current-only
Cabal-fragment and ledger paths. Source and transformed digests plus same-directory prepared
files make an interrupted source move resumable; changed backup, prepared, or destination
bytes refuse with conflict evidence. The flag does not authorize unrelated stale,
module-root, or layout moves, and `--force-generated-overwrite` cannot bypass it.

### Aggregate behavior evidence

Inspect the finite behavior inventory before filling consumer code:

```bash
cabal run -v0 keiro-dsl -- behavior-obligations service.keiro --format=text
```

The report includes live transitions reachable from the initial state,
reachable state/command rejection cells, replay-only transitions, stable keys,
exact current file/line/column positions, and evidence ownership. Scaffolding
emits one context `BehaviorSourceMap`, a generated `BehaviorContract` per
aggregate, and a create-once `BehaviorHoles` module. Fill live, rejection, and
replay witnesses with real histories, commands, expected events, or expected
rejections.

New pending rows identify the semantic source cell beside the stable key, but
do not copy a position that would become stale after the file becomes
application-owned:

```haskell
Pending (BehaviorKey "behavior-v1-2f3ebf37a55781db")
  -- JourneyActive x Decide: live transition
```

The generated contract resolves the key through the current context source map
when a failure renders. Moving unchanged source rewrites that one map rather
than every aggregate contract or witness file:

```text
FAIL behavior-v1-2f3ebf37a55781db JourneyActive x Decide: live transition (service.keiro:44:3) [event-value-mismatch] runtime event values differ from the exact witness expectation; actual=[DecisionRecorded (DecisionRecordedData {amount = 5})] expected=[DecisionRecorded (DecisionRecordedData {amount = 6})]
```

JSON output remains schema `keiro/behavior-conformance/1`; each failure now
also carries that human-readable cell in its append-only `subject` field.

Replay witnesses assert the detailed runtime edge, including mode and
source-wide `EdgeRef`; predicate verification consumes that same identity.
Replay-only initial transitions never appear in step-based acceptance helpers,
so a green behavior report is the authoritative proof that historical first
events still invert without reopening the live command path.

The compiled conformance report fails missing, pending, duplicate, stale, or
behaviorally false evidence. Opaque predicates and one-way projections remain
honestly unverified unless the consuming CI chooses a stricter policy.

## Command reference

The examples below use Cabal from the Keiro repository. If
`keiro-dsl/bin` is on `PATH`, replace `cabal run -v0 keiro-dsl --` with
`keiro-dsl`.

Every command that accepts `FILE` accepts a `.keiro` source, a
`.keiro-workspace` manifest, or `/dev/stdin`.

### `new`

```bash
cabal run -v0 keiro-dsl -- new KIND
```

Valid kinds are `aggregate`, `process`, `router`, `contract`, `intake`, `emit`,
`publisher`, `workqueue`, `dispatch`, `workflow`, and `operation`. Every starter
is a complete, checked Language 4 service. Coupled kinds include the nodes they
need; for example, the publisher starter includes a contract and emit. There is
no standalone read-model starter; the workqueue starter includes read models.

### `parse` and `pretty`

```bash
cabal run -v0 keiro-dsl -- parse service.keiro
cabal run -v0 keiro-dsl -- pretty service.keiro
```

Both parse and print canonical source. They catch grammar errors but do not run
semantic validation. Canonical output discards comments and formatting.

### `check`

```bash
cabal run -v0 keiro-dsl -- check service.keiro
cabal run -v0 keiro-dsl -- check service.keiro --emit
cabal run -v0 keiro-dsl -- check service.keiro --explain-bindings
cabal run -v0 keiro-dsl -- check service.keiro --min-language 4
cabal run -v0 keiro-dsl -- check service.keiro --deny-warnings
cabal run -v0 keiro-dsl -- check service.keiro \
  --deny DeprecatedEventReplayHazard,WireSchemaVersionMismatch
cabal run -v0 keiro-dsl -- check service.keiro \
  --report-out build/keiro-check-report.json
cabal run -v0 keiro-dsl -- check service.keiro \
  --coverage-report build/keiro-coverage.json \
  --fail-on-opaque
```

`--emit` prints canonical source after successful validation.
`--explain-bindings` lists consumer-owned binding obligations.
`--min-language N` requires a registered released language version at least
`N`; `--min-language 4` is the standard stable-contract gate.
`--deny-warnings` makes every warning fail this invocation without changing its
severity. `--deny CODE[,CODE...]` applies the same exit policy selectively; it
is repeatable, and the spelling is copied exactly from `warning[Code]`. A code
`check` cannot emit is refused rather than silently accepted: cross-revision
codes belong to `diff`, and structural-coverage codes require
`--coverage-report` in the same invocation. This makes a denial in a CI file
either effective or an immediate error, never a decoration.
`--report-out` writes `keiro-dsl/check-report/1` after source or workspace
validation, on success or failure, creating missing parent directories. It
records language provenance, enforcement flags, diagnostics and related
locations, summary counts, and the validation outcome. Object and array-element
keys are append-only; readers must ignore unknown keys. A parse failure and an
unreadable or unparseable workspace manifest occur before any coded diagnostic
exists and therefore write no report; a *composed* workspace refusal does write
one, with `"language": null` because no service graph was formed.
`--coverage-report` inventories structural, opaque, explicit-`Json`, and
consumer-JSON register boundaries. `--fail-on-opaque` turns named private
persisted opaque boundaries into a CI gate. Coverage findings are part of this
invocation's diagnostic surface: they are subject to the same warning policy and
appear in the check report as line-0 entries, so the report's `ok` covers them.
Both reports spell severity `"error"` or `"warning"`.

#### CI recipe

```bash
cabal run -v0 keiro-dsl -- check service.keiro \
  --min-language 4 \
  --deny-warnings \
  --report-out build/keiro-check-report.json
```

A red result means the source did not parse or compose, selected a language
below 4, emitted an error, or emitted a warning denied by this invocation. The
JSON report distinguishes those outcomes whenever a coded diagnostic could be
produced. The report's parent directory is created if it does not exist.

### `inspect`

```bash
cabal run -v0 keiro-dsl -- inspect service.keiro --format=json
```

The report records declared Language 4 provenance, its effective semantic
contract, and `languageSupport: "stable"`. Workspace output lists every member
in canonical path order.

### `behavior-obligations`

```bash
cabal run -v0 keiro-dsl -- behavior-obligations service.keiro --format=text
cabal run -v0 keiro-dsl -- behavior-obligations service.keiro --format=json
```

Use text while authoring and the stable JSON schema for CI or other tooling.
Both forms resolve every behavior key through the checked source index; JSON
keeps schema `keiro-dsl/behavior-obligations/1` and appends `file`, `column`,
and `quality: "exact"` to each location.

### `scaffold`

```bash
cabal run -v0 keiro-dsl -- scaffold service.keiro --out src \
  --runtime-package acme-service-runtime \
  --module-root Acme.Services \
  --collocate \
  --goldens test/golden-payloads
```

Options:

- `--out DIR` is required.
- `--module-root PREFIX` overrides the source module clause.
- `--runtime-package PACKAGE` enables the runnable conformance package and
  overrides a workspace manifest's `runtime-package` value.
- `--collocate` selects collocated generated placement.
- `--force-generated-overwrite` allows replacement of a generated target that
  lacks the expected banner. Use only after proving the target is disposable.
- `--goldens DIR` selects aggregate golden-payload input.
- `--codec-comparison MAPPED-NAME --comparison-out FILE` emits a
  non-production historical codec comparison module for one structural mapped
  type.

The scaffold report includes a `no-modules:` line for every declared emit,
pgmq dispatch, or operation. Those nodes remain validated and diff-classified;
the line makes explicit that they contributed no generated modules.

For mapped declarations, read `semantic impact` separately from
`generated-artifact impact`. Semantic impact comes from the checked dependency
graph and names previous/current aggregate, workqueue, read-model query-position,
and derived projection consumers. It prints complete logical roots and separate
consumer-build, event-history, snapshot-hydration, queued-job-history, query-API,
projection-handler, and replayable-rebuild consequences. The one service-wide
structural-conformance role remains independent. Artifact impact reports which
generated bytes actually changed, distinguishing aggregate modules,
`StructuralConformance`, and `BehaviorSourceMap`. A file disposition never adds
a semantic consumer. In particular, moving otherwise unchanged source text may
change only `BehaviorSourceMap` and report no mapped semantic impact.

Current standalone and workspace ledgers persist the source-independent
semantic baseline. If the previous ledger predates that row, the report says
`baseline: unavailable (legacy ledger)` and names only current consumers; it
does not guess that the old consumer set was empty. The successful run writes
the baseline, so a later run can compare both sides.

The ledgers also persist one router-selection snapshot per router. Declarative
selections record `declarative-verified` identity, version, and fingerprint;
custom resolver forms record `custom-unverified` with no fabricated metadata.
An older ledger with no router-selection row remains readable and gains the row
on the next successful scaffold.

For historical comparison, compile the emitted module in a consumer-owned test
and supply the old codec explicitly. The tool does not discover or fall back to
an old application instance at runtime.

### `diff`

```bash
cabal run -v0 keiro-dsl -- diff service.keiro --since HEAD^ --explain \
  --report-out build/keiro-diff.json \
  --replay-impact-out build/replay-impact.json
```

`diff` reconstructs the old source or workspace from Git and classifies every
finding across six compatibility surfaces:

```text
private-history-read
old-binary-read-new-events
snapshot-hydration
public-consumer
persisted-identity
consumer-build
```

Mapped findings also receive a separate `semantic impact` block. It summarizes
the checked old/current typed consumers, roots, consequences, and service
conformance role. Queue and query positions stay distinct, and only replayable
catalog projection consumers name a rebuild consequence. It does not replace
the detailed compatibility findings, rollout constraints, or replay report.
`--report-out` appends the same sorted projection under
`semanticImpact` while keeping schema `keiro-dsl/diff-report/1`. Source-only or
ownership-only movement has no mapped semantic-impact entries.

Declarative router changes also receive a separate `coordination impact` block.
It reports old/current verification, identity, version, fingerprint, and mapped
use sites. The JSON form appends the same sorted evidence as optional top-level
`coordinationImpact`; legacy report constructors omit the key. Identity changes,
version decreases, and semantic fingerprint changes without a version increase
are breaking. A changed fingerprint with a version increase, a metadata-only
version increase, a declarative/custom boundary crossing, or an affected mapped
selection dependency is advisory. Coordination-breaking findings participate
in the report headline and command exit status; aggregate `ReplayImpact` remains
a separate unchanged contract.

The headline is `ADDITIVE`, `WARNING`, or `BREAKING`. The default gate includes
all surfaces except `old-binary-read-new-events`; repeat `--gate SURFACE` to add
that or any future optional gate. `--explain` prints paths, failing directions,
rollout constraints, and remedies. `--report-out` writes the stable
`keiro-dsl/diff-report/1` JSON report.

Other options:

- `--emit-goldens DIR` writes old-shape payloads for event version bumps
  without overwriting existing files.
- `--replay-impact-out FILE` writes the replay-neutral or replay-affected audit
  input.
- `--coverage-report FILE` writes the mapped-boundary delta.
- `--fail-on-opaque-increase` fails when the change adds a named opaque
  boundary; it requires `--coverage-report`.

Run `diff` from the Git repository containing the source because `--since`
uses `git show`.

## Validation model

The tool separates three failure classes:

1. A parse failure means the source does not match its selected language grammar.
2. An `error[Code]` means the graph parses but cannot safely or faithfully
   lower. `check` exits non-zero, and scaffold writes nothing.
3. A `warning[Code]` calls out a risky but explicit policy, incomplete
   operational proof, or adoption state. Warnings do not make `check` fail by
   default. `--deny-warnings` and `--deny CODE` escalate only this invocation's
   exit result; the diagnostic still renders and reports as `warning`.

A green `check` also means the default scaffold plan has no refusal that is
decidable from the checked graph. Empty aggregates and contracts are
`AggregateEmpty` and `ContractEmpty` errors under every language version. Module
path collisions, generated/consumer import cycles, unsound behavior derivation,
duplicate conformance fact keys, and unexpected internal planning failures use
`GeneratedPathCollision`, `GeneratedImportCycle`, `BehaviorDerivationInvalid`,
`ConformanceFactKeyCollision`, and `GeneratedPlanningInvariantViolation`.
Diagnostics retain source locations where planner evidence exposes them.

Scaffold still owns evidence that exists only after an output tree and invocation
options are known: exact generated-banner protection, golden-root divergence,
explicit name-migration authorization, and stale generated evidence. It also
re-runs the shared gates after applying `--module-root`, `--collocate`,
`--runtime-package`, and golden inputs, so an override-induced refusal is detected
before a write set exists. These checks are defense in depth, not a second
semantic vocabulary.

A source without a `language keiro-dsl N` preamble selects compatibility-only
language 1. Declared languages 1 through 3 are compatibility-only, language 4
remains the published stable contract, and candidate language 5 is the current
development authoring default. Earlier languages do not gain language 5's catalog or mapped
consumer syntax or typed domain-outcome declarations/clauses.
`check` and `scaffold`
print one `language contract:` notice for those sources (workspace notices
summarize member provenance); `diff` prints it for the working-tree side only.
Use `--min-language 5` only after a service intentionally adopts the candidate
catalog and typed-outcome contract; mapped queue/query spellings, outcome
exhaustiveness, generation, conformance, coverage, and evolution reporting are
all checked before adoption.
Existing language-4 CI may keep `--min-language 4` without
triggering a mechanical rewrite.

The warning policy follows the evidence boundary. Three warnings depend on
operational history and therefore remain warnings: `DeprecatedEventReplayHazard`,
`EventRetirementInProgress`, and `ReplayOnlyCommandStillLive`. Deny them in CI
until the database-backed audit establishes the relevant fleet fact. Five
warnings describe deliberate or currently accepted policy:
`WqUnloggedDurability`, `ProcessBenignInversion`, `RouterBenignInversion`,
`AmbiguousFollowsRejectedPolicy`, and `PolicyDeadLetterUnused`. Two more make
accepted but currently inert declarations explicit:
`IntakeBindFlagUnenforced` and `RmInlineSubscriptionIgnored`. Teams may deny
any of these warnings without changing the shared language contract. Two internally decidable
warnings, `WireSchemaVersionMismatch` and `RmProjectionWithoutNode`, are
candidates for an error in a future language version rather than retroactive
tightening of language 4. They can be selected with `--deny` today.

Language 4 validates local syntax and whole-service coupling. Important closed
surfaces include:

- unique declarations, fields, states, registers, map cases, topic aliases,
  columns, and durable identities;
- valid TypeID prefixes and current TypeID-v7 admission;
- typed aggregate expressions, initial values, transition ownership,
  event-sourced state changes, reachability, terminal states, upcaster chains,
  wire policy, projection maps, and snapshot fixtures;
- process/router aggregate, command, key, binding, field, projection, resolver,
  verified resolve-row, timer, and worker-policy references;
- contract topic syntax and topology; intake binding, schema, dedupe, decode,
  persistence, and complete disposition policy; emit topic affinity; publisher
  ordering/backoff/attempt policy;
- queue payload vocabulary, bounded durations, identity fixtures,
  FIFO/group/provisioning rules, complete disposition, and dispatch
  read-model/queue references;
- PostgreSQL read-model names, types, shape fixtures, feed, scope, subscription
  identities, consistency, and projection ownership; and
- workflow label, input, patch, rotation, signal, operation, and stable identity
  rules.

Diagnostics include a source line. Fix the specification first. If a generated
harness later fails, fix the create-once behavior or evidence named by that
harness; do not weaken the generated runtime boundary.

Candidate catalog query-supply diagnostics are:

- `CatalogReadModelBindingMissing` when no observed target is declared;
- `CatalogTargetUnknown` or `CatalogReadModelTargetOutsideGroup` for an invalid
  target prerequisite;
- `CatalogReadModelSupplierMissing` when the complete valid target set has no
  supplier;
- `CatalogReadModelMultipleSuppliers` when valid observed targets span owners,
  with every owner claim site attached; and
- `CatalogReadModelLegacyProjectionConflict` when a catalog-bound query is also
  named by an aggregate-local legacy projection clause.

Existing missing/multiple target-owner diagnostics remain authoritative at target
claims rather than producing duplicate query noise. `RmInlineFeedUnreferenced` retains
its published Languages 1-4 and standalone-read-model meaning; it is not the ownership
rule for a Language 5 catalog-bound query.

## Evolution workflow

For any persisted or public change:

1. Edit the Language 4 source.
2. Run `check` and resolve every error.
3. Run `diff --since <deployed-ref> --explain`.
4. For private event changes, bump event versions, preserve contiguous
   upcasters, and capture goldens as directed.
5. For read-model shape changes, bump the model version and update the reported
   shape fixture together.
6. For snapshot or hand-owned fold changes, bump the corresponding codec,
   shape, or `FoldVersion` identity.
7. Scaffold into a clean tree, reconcile the generated manifest and stale
   report, then compile all hand-owned modules.
8. Run generated codec, binding, behavior, snapshot, forward/replay, and
   service integration conformance tests.
9. Follow the rollout constraints from `diff`; run the real-log replay gate
   when replay impact is reported.

Do not treat a green parse as semantic validation, a green check as proof of
hand-owned behavior, or finite fixtures as proof of every possible consumer
value. The toolchain makes each remaining obligation explicit so CI and rollout
policy can own it at the correct boundary.

## Authoring checklist

Before committing a new or changed service specification:

- The first non-comment line is exactly `language keiro-dsl 4`.
- `check` exits zero for the whole source or workspace.
- Every public/persisted field has an intentional type and wire spelling.
- Aggregate time comes from command/input data, never a sampled clock.
- Every state change emits an event; guarded siblings are mutually exclusive.
- Event changes have a version, contiguous upcaster chain, and payload goldens.
- Mapped structural bindings are total; opaque boundaries are intentional and
  visible in coverage.
- Intake and queue disposition tables contain every required outcome and keep
  transient failures separate from poison or terminal failures.
- Stable process, router, workflow, queue, read-model, topic, patch, and outbox
  identities will not change accidentally.
- `diff` is green under the service's chosen compatibility gates and its
  rollout constraints are recorded.
- Scaffold output, the Cabal manifest, create-once holes, behavior evidence,
  and generated conformance harnesses are all reconciled and green.

For deciding whether a service should use the DSL at all, see
[Choosing `keiro-dsl`](../guides/choosing-keiro-dsl.md). For runtime concepts
behind the declarations, see [Core Concepts](core-concepts.md),
[Codecs And Event Evolution](codecs-and-event-evolution.md),
[Process Managers And Timers](process-managers-and-timers.md),
[Durable Workflows](durable-workflows.md), and [Work Queues](work-queues.md).
