# Brownfield Migration And Transducer Modeling

This guide is for a team moving an existing service onto Keiro when production
history, wire shapes, and downstream readers already exist. It assumes the team
has chosen Keiro and now needs the practical *how*: first model the domain as a
Keiki transducer, then migrate historical bytes without rewriting them or
creating two codec authorities. If you are still evaluating the architectural
trade, read [Adopting Keiro From tan-event-source](adopting-keiro-from-tan-event-source.md)
first; that guide is the *why*, while this guide is the migration playbook.

The doctrine here translates sections 4, 5, 6, and 12 of
[`docs/research/14-structural-consumer-type-tradeoffs.md`](../research/14-structural-consumer-type-tradeoffs.md)
and the modeling constraints in
[`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`](../improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md).
Those documents motivate the constraints; the runtime, the accepted ADRs, and
the code that executes remain authoritative. This guide does not document the
future structural/opaque declaration grammar because that tooling has not
landed.

The migration has two halves. Part A turns domain choices into a transducer
whose forward execution and replay agree. Part B starts from genuine historical
wire values and moves the service through goldens, shadow comparison, explicit
versions, runtime validation, a full replay audit, and a coordinated cutover.


## Part A: Modeling the domain as a transducer

A Keiki transducer has one edge set for both live command execution and replay.
An edge checks a guard, emits durable events, writes registers, and moves to a
control-state vertex. During replay, Keiki inverts each stored event back to the
command that produced it, checks the same guard, and applies the same writes.
Every modeling choice is therefore also a replay choice: information that
affects state must be recoverable from the durable output, and decision logic
must remain true for the history it originally admitted.

[The Guarantee Ledger](dsl-guarantees-and-hand-written-services.md) explains
the complete layered gate model. In short, the compiler, validated stream
construction, replay audit, and typed runtime failures protect both hand-written
and DSL-generated services. `keiro-dsl check`, cross-version `diff`, and the
generated conformance harness add evidence that only a checked `.keiro` spec can
provide. No one layer proves every property.


### Decision scalars versus payload data

Put values that select behavior into explicit, solver-visible scalar fields.
Identity, revision, lifecycle, quantities, and content hashes are typical
decision state. Carry a rich payload beside those scalars when events,
registers, or projections need the whole value. Keiki can then reason about the
decision while copying the payload without pretending to understand every
nested field.

For example, prefer a command shape and guard like this:

```text
command ObserveDoc {
  key         : Text
  contentHash : Text
  doc         : DocInfo
}

when register.contentHash != command.contentHash
emit DocObserved { doc = command.doc, contentHash = command.contentHash }
```

The edge decides from `contentHash`; `doc` remains payload data. If the next
rule repeatedly needs another nested fact, promote that fact to a scalar rather
than hiding a Haskell getter inside syntax that looks checked.

The worked order aggregate follows the scalar-first shape. Its command payload
is declared in
[`Jitsurei.Domain`](../../jitsurei/src/Jitsurei/Domain.hs), and
[`orderTransducer`](../../jitsurei/src/Jitsurei/OrderStream.hs) emits those
fields directly:

```haskell
data PlaceOrderData = PlaceOrderData
  { orderId :: !OrderId
  , sku :: !Sku
  , quantity :: !Quantity
  }
```

Keiki 0.4 also has typed `FieldProjection` witnesses consumed through
`regProj` and `inpProj`. Keiro does not yet generate those witnesses from a
consumer-owned structural mapping. After
[`docs/plans/150`](../plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md)
lands, a hand-written Holes module may use its generated facade for a genuine
scalar field. That facility is deliberately narrow: projections are guard-only,
start from a direct register or matched-input field, and return a result in
Keiki's curated symbolic registry. It does not create checked nested `.keiro`
paths, because the current scaffolder renders guard intent as comments rather
than lowering that text into the running transducer.

The negative rule is as important as the convenience. If a predicate cannot be
represented by Keiki's symbolic language, call it opaque, keep the
`OpaqueGuard` warning and audit obligation visible, and do not let it satisfy a
deployment gate that requires checked guards.


### Register design and head invertibility

A register is a typed state slot carried alongside the control-state vertex.
Register design is constrained by replay: every command field read by an edge
must be recoverable from the *first* event emitted by that edge. Streaming
replay sees the head event first and must reconstruct the command before it can
re-check the guard or process later output.

Keiki reports a value present only in later events as
`HirHeadUnrecoverable`; Keiro renders that family as `HeadUnrecoverable` and
refuses `mkEventStream`/`mkEventStreamOrThrow` construction. The practical rules
are simple:

- If a register write needs a command value, put that value in the head event.
- If later events also need it, repeat or derive it from head-recoverable data;
  do not rely on a tail event to make the command invertible.
- A side-effect result that is never emitted cannot become durable register
  state. Emit it first, then fold it.

The order edge demonstrates the safe pattern: `PlaceOrderData.orderId`, `sku`,
and `quantity` are all copied into the head `OrderPlaced` event before the edge
moves from `NotStarted` to `Placed`. See
[Replayability Safety](../user/replay-safety.md) for the invariant and
[the latent replay-safety bug section](migrating-to-validated-event-stream.md#the-one-thing-that-can-block-you-a-latent-replay-safety-bug)
for how an existing service encounters it at the validated boundary.


### Lifecycle vertices instead of fake initial values

Never initialize a register with a value that the domain rejects. `ProjectId
""` is type-correct but false; `error "unset"` merely postpones failure until
validation or hydration; inventing a `Default` instance hides the same lie.

Represent absence in the control state. Start in an `Absent`, `Unreported`, or
`NotStarted` vertex, accept only the initializing command there, and let its
event populate the real values before later vertices use them. The incident
example is compiled evidence:

```haskell
data IncidentState
  = Unreported
  | Triaging
  | Acknowledged
  | Escalated
  | Resolved

incidentTransducer =
  B.buildTransducer Unreported RNil isTerminal do
    B.from Unreported do
      B.onCmd inCtorRaiseIncident $ \d -> B.do
        B.emit wireIncidentRaised IncidentRaisedTermFields
          { incidentId = d.incidentId
          , service = d.service
          , severity = d.severity
          , raisedAt = d.raisedAt
          }
        B.goto Triaging
```

The complete definition is in
[`Jitsurei.Incident`](../../jitsurei/src/Jitsurei/Incident.hs).
`Jitsurei.OrderStream` uses `NotStarted` in the same way. For a brownfield
entity, an explicit import command and event such as
`BackfilledFromLegacy` should initialize its register file. That event records
the migration fact; a synthetic initial state would pretend the history had
always existed.


### One stream per entity, not a catalog map

A single stream containing a map of every entity may look atomically
convenient, but it pushes membership, arbitrary diffs, and dynamic collection
updates outside Keiki's symbolic model. It also puts unrelated entities behind
one optimistic-concurrency version and makes replay grow with the whole
catalog.

Give each stable entity its own stream. A reconciler can dispatch idempotent
observations and removals; each hydrated transducer decides added, updated,
no-op, or removed from its own scalar state. `Jitsurei.OrderStream` shows the
typed naming pattern:

```haskell
orderStream :: OrderId -> Stream OrderEventStream
orderStream = Stream.entityStream orderCategory . orderIdText
```

This gives up all-or-nothing visibility of an arbitrarily large catalog
update. Recovery becomes convergence: retry idempotent per-entity commands
until every target reaches the intended state. If readers need a coherent
generation, persist orchestration state—generation identity, desired inventory
hash, per-target progress, and activation—and expose only the activated
generation. If several streams genuinely need to cooperate, use
[Choosing A Primitive](choosing-a-primitive.md) to select a projection, process
manager, or router instead of rebuilding cross-stream behavior inside one
aggregate.


### Guard evolution with replay-only edges

Tightening a guard changes replay. A stored event admitted by the old guard may
no longer invert under the new one, and the next command then fails with
`HydrationNoInvertingEdge`. The sanctioned remedy is a `replay-only` twin edge
covering the removed region:

```text
old guard AND NOT new guard
```

Keiki's `ReplayOnly` mode excludes the twin from live command stepping and
tries it only when no live edge can invert the historical event. `keiro-dsl
diff` reports `AggGuardTightened` and prints the computed twin; the author pastes
it when history needs the old region or proves through the replay audit that no
stored stream does. Retire the twin only after affected streams are terminal,
truncated behind a covering snapshot, or audited clean.

Model guards from scalar comparisons so the removed region is visible enough
for this procedure. An opaque predicate cannot produce a trustworthy
complement or a precise affected surface. The durable decision is
[`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md);
the operational sequence is in
[Changing decisions: guards, outputs, and dispatch](evolution-and-replayability.md#changing-decisions-guards-outputs-and-dispatch).

Binding-authoring tooling does not exist yet. Plan 151 will append the
create-once skeleton and explanation workflow here after its implementation
lands.

<!-- appended-by: docs/plans/151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md
     anchor: binding-authoring-tooling
     (binding skeleton scaffolds and `check --explain-bindings` sections land here) -->
