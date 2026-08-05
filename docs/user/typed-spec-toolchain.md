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
| `readmodel` | Registered SQL read-model identity, shape, feed, and consistency. |
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
owner. Generated harnesses check both structural binding directions, declared
wire branches, fixture coverage, aggregate payload round trips, and replay
agreement. Fixtures are finite evidence, not proof for all consumer values.

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

Prefer declaring a matching `readmodel` node. It then owns schema identity,
feed, consistency, and rebuild metadata. An optional
`consistency=Strong|Eventual` on `projection` must agree with the read model.
A projection without a read-model node remains usable but produces a warning
and has no registered schema or rebuild authority.

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
Both `decode unknown-status => Name` and the quoted `dead-letter` text are
descriptive-only today. The latter is operator guidance rendered into the timer
hole, not a runtime category identity. `max-attempts` is at least 1.
`on-ambiguous` must be `Retry`:
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
for the declared binding posture.

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
schema version must equal the contract version. Body mode is `strict` or
`lenient`, but that posture is descriptive-only today: generated and runtime
code do not enforce the word. A posture change is still diff-classified. The
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
does not create a module or typed signature. Every emit therefore produces the
`EmitDeriveHoleUnrealized` warning. The hand-owned implementation must be
deterministic so retries reproduce the same IDs.

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
Generated decoders currently require every payload field regardless of whether
the optional `required` marker is present, so omitting it produces
`WqFieldOptionalUnsupported`. Queue payload evolution is a persisted wire
change and must go through `diff`.

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
a hand-owned effectful one-to-many function, not a column. The top-level
`dedup key` is likewise descriptive because committed services use both source
keys and command identities there; the two `seenIn` fields are the enforced
dedupe boundaries. A dispatch is validated and diff-classified but produces no
generated module today. Keep the hand-owned queue-side SQL check consistent
with the declared wire key and read-model check.

## Read models

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

Consistency is `Strong` or `Eventual`. A strong model requires
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

The runner executes every aggregate and read-model self-check. Process, router,
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
manifest/record paths. Source and transformed digests plus same-directory prepared
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
and evidence ownership. Scaffolding emits a generated `BehaviorContract` and a
create-once `BehaviorHoles` module. Fill live, rejection, and replay witnesses
with real histories, commands, expected events, or expected rejections.

New pending rows identify the source cell beside the stable key, so the
create-once file remains readable after it becomes application-owned:

```haskell
Pending (BehaviorKey "behavior-v1-2f3ebf37a55781db")
  -- JourneyActive x Decide: live transition (spec line 44)
```

The generated contract uses the same subject in failures and includes the
runtime and witness values when they differ:

```text
FAIL behavior-v1-2f3ebf37a55781db JourneyActive x Decide: live transition (spec line 44) [event-value-mismatch] runtime event values differ from the exact witness expectation; actual=[DecisionRecorded (DecisionRecordedData {amount = 5})] expected=[DecisionRecorded (DecisionRecordedData {amount = 6})]
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
is repeatable, and the spelling is copied exactly from `warning[Code]`.
`--report-out` writes `keiro-dsl/check-report/1` after source or workspace
validation, on success or failure. It records language provenance, enforcement
flags, diagnostics and related locations, summary counts, and the validation
outcome. Object and array-element keys are append-only; readers must ignore
unknown keys. Parse or workspace-composition failures occur before the report
exists. The report's `ok` excludes the separate structural/opaque coverage
gate, whose artifact remains `--coverage-report`.
`--coverage-report` inventories structural, opaque, explicit-`Json`, and
consumer-JSON register boundaries. `--fail-on-opaque` turns named private
persisted opaque boundaries into a CI gate.

#### CI recipe

```bash
cabal run -v0 keiro-dsl -- check service.keiro \
  --min-language 4 \
  --deny-warnings \
  --report-out build/keiro-check-report.json
```

A red result means the source did not parse or compose, selected a language
below 4, emitted an error, or emitted a warning denied by this invocation. The
JSON report distinguishes those outcomes whenever parsing and composition
succeeded. Ensure the report's parent directory exists before invoking the
command.

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

1. A parse failure means the source does not match Language 4 grammar.
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
language 1. Declared languages 1 through 3 are also compatibility-only, and do
not apply language 4's strict spec-surface validation. `check` and `scaffold`
print one `language contract:` notice for those sources (workspace notices
summarize member provenance); `diff` prints it for the working-tree side only.
Use `--min-language 4` to turn that otherwise-compatible downgrade into the
located `LanguageVersionBelowMinimum` error expected by stable-contract CI.

The warning policy follows the evidence boundary. Three warnings depend on
operational history and therefore remain warnings: `DeprecatedEventReplayHazard`,
`EventRetirementInProgress`, and `ReplayOnlyCommandStillLive`. Deny them in CI
until the database-backed audit establishes the relevant fleet fact. Five
warnings describe deliberate or currently accepted policy:
`WqUnloggedDurability`, `ProcessBenignInversion`, `RouterBenignInversion`,
`AmbiguousFollowsRejectedPolicy`, and `PolicyDeadLetterUnused`. Four more make
accepted but currently inert declarations explicit:
`IntakeBindFlagUnenforced`, `EmitDeriveHoleUnrealized`,
`WqFieldOptionalUnsupported`, and `RmInlineSubscriptionIgnored`. Teams may deny
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
