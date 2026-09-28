---
type: Reference
title: Keiro DSL Aggregates
description: Write Keiro DSL aggregate expressions, registers, commands, events, transitions, outcomes, projections, and snapshots.
docId: DOC-27
tags: [keiro, dsl, aggregates, reference]
generated:
  by: anthropic-claude-code/claude-opus-5
  at: 2026-09-28T00:00:00Z
---

# Keiro DSL Aggregates

This page covers the aggregate node: its typed guard and write expressions,
registers, states, commands, events, transitions, typed domain outcomes,
event evolution, projections, and snapshots. It is part of the [Keiro DSL Reference](keiro-dsl-reference.md), which
introduces the language, its versions, and source file structure.

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
mapping. They may end at `Text`, `Int`, `Integer`, `Bool`, `Natural`, `Time`,
or a nominal ID, enum, or scalar leaf. Nominal IDs and enums support equality
only; their declaration identity is preserved, so different ID declarations
never compare even when their wire prefixes happen to match.

### Literals

```keiro
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

```keiro
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

```keiro
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
[Direct aggregate types](keiro-dsl-types-and-mappings.md#direct-aggregate-types).

`states` is followed by one or more lifecycle states. The first is the initial
state. A trailing `!` marks a terminal state, which may not have outgoing
transitions. Every non-terminal state must be reachable from the initial state.

Use lifecycle states and `goto` for the aggregate's main state machine. A
parallel `<Aggregate>Vertex` register is rarely needed and can obscure the
single lifecycle authority.

### Commands and events

```keiro
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

```keiro
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

By default, the toolchain generates transition behavior from its guard, writes,
emits, and target. Use an explicit hole when the predicate or updates cannot be
expressed:

```keiro
Reviewed -- Close -->
  implementation hole
  emit ClosedEvent
  goto Closed
```

An implementation-hole transition may not also declare DSL `guard` or `write`
clauses. Its create-once module supplies the implementation and a `FoldVersion`.
Bump that token whenever hand-owned predicate or update behavior changes so
snapshots and replay audits can detect the new fold.

### Typed domain outcomes

A transition can make every selected command result explicit without turning a
business rejection into an event:

```keiro
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

```keiro
replay-only Held -- Confirm -->
  emit LegacyConfirmed
  goto Confirmed
```

It must emit at least one event. Use it to preserve inversion of stored events
after their live behavior has been retired.

The initial state is not special. A historical first event can retain a
replay-only sibling beside the current live start rule:

```keiro
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

```keiro
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

The only supported wire policy is:

```keiro
wire kind=ctorName fields=camelCase schemaVersion=1
```

Other `kind` or `fields` values are rejected because generation implements no
other byte convention.

### Aggregate projections

```keiro
projection transfer_decisions key=reservationId
  status-map {
    Requested=>held
    ConfirmedEvent=>confirmed
  }
```

`key` names the source field used by the projection. It must resolve to an aggregate register, command field, or event field. Status-map
keys are exact event names. They must be unique and resolve to events in the
aggregate. The map is total by default; use `status-map partial { ... }` when
some events intentionally do not change projected status.

An aggregate-local projection is a standalone, implicitly inline form. Declare
a matching `readmodel` node, which owns schema identity and `freshness`; only
`freshness = immediate` is reachable, because an inline projection has no
cursor to wait for. A projection-level `consistency` clause is rejected. A
projection without a read-model node remains usable but produces
`RmProjectionWithoutNode` and has no registered schema or rebuild authority.
Catalog-managed queries should use a top-level projection owner instead; see
[Projection catalogs](keiro-dsl-queues-and-read-models.md#projection-catalogs).

### Snapshots

```keiro
snapshot every 100
  state-codec version=1 shape-hash="<captured-live-hash>"
```

or:

```keiro
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
