---
type: Explanation
title: Core Concepts
description: Introduce streams, codecs, commands, projections, process managers, and timers.
docId: DOC-5
tags: [keiro, concepts, event-sourcing]
generated:
  by: human:nadeem
  at: 2026-09-18T04:06:27Z
timestamp: 2026-10-27T21:15:00Z
---

# Core Concepts

## Event Store

Keiro stores events through [Kiroku](mori://shinzui/kiroku). Kiroku owns
append-only streams, stream versions, global positions, durable subscriptions,
and PostgreSQL storage. Keiro adds application contracts, command execution,
coordination, projections, and durable workflow journals over that log.

The event-store schema is `kiroku`; framework tables live in `keiro`.
Application tables live in an application-owned schema. Apply migrations before
starting workers; see [Database Migrations](migrations.md).

## Stream

`Stream a` wraps a Kiroku `StreamName`:

```haskell
newtype Stream a = Stream { name :: StreamName }
```

The phantom parameter keeps aggregate stream identities distinct in Haskell.
`stream :: Text -> Stream a` wraps a raw name, `streamName` recovers the store
name, and `mapStreamName` transforms it while keeping the type tag.

For aggregate instances, prefer category-safe construction:

```haskell
orderCategory :: StreamCategory OrderEventStream
orderCategory = categoryUnsafe "order"

orderStream :: Text -> Stream OrderEventStream
orderStream = entityStream orderCategory
```

Kiroku takes the category from the text before the first hyphen. Categories
cannot contain that separator; entity IDs may. Use `category` to validate
non-literal categories and `entityStreamId` for a domain ID with a
`StreamIdSegment` instance. A namespace subscription such as
`CategoryNamespace "pm"` follows category `pm` and its colon-separated
descendants; exact-category and arbitrary stream-prefix selection are different
contracts.

## Codec

`Codec e` controls the event storage boundary:

- `eventTypes` lists legal stored tags; `eventType` selects a value's tag;
- `schemaVersion` identifies the current payload version;
- `encode` and `decode` write and read the current JSON shape;
- `upcasters` migrate supported historical payloads to that shape.

Prefer `mkCodec` for explicit configuration validation. Unknown tags and
unrecoverable payloads fail hydration: deciding from a partial history is unsafe.
Generated structural codecs own wire policy independently of consumer JSON
instances. See [Codecs And Event Evolution](codecs-and-event-evolution.md).

## EventStream

`EventStream phi rs s ci co` combines the Keiki predicate carrier, register-file
shape, control state, command type, and emitted event type. Its record holds the
`SymTransducer`, initial state/registers, event codec, name resolver, snapshot
policy, and optional state codec.

Define a raw `...EventStreamDef`, then validate it with `mkEventStream` or
`mkEventStreamOrThrow`. Command runners require the resulting
`ValidatedEventStream`; a `Stream` handle retains the raw `EventStream` type as
its phantom tag. Validation checks the replay contract, not arbitrary business
correctness. See [Replayability Safety](replay-safety.md).

## Command Cycle

A command resolves its stream, hydrates history, decides through the transducer,
encodes zero or more events, and appends the batch with optimistic concurrency.
Retryable append conflicts cause a fresh hydrate/decide attempt up to the retry
limit. Snapshots can accelerate hydration; they do not replace history.

`runCommand` returns a `CommandResult`. Outcome-aware `runDomainCommand`
additionally distinguishes accepted events, a selected typed rejection, and a
selected successful no-op. An unmatched command or infrastructure failure is
still a `CommandError`.

Transactional runners can commit event appends, minimal inline projections,
timer/outbox writes, and other SQL together. Guarded catalog commands can refuse
a relational precondition and roll back that transaction. Keep external network
effects behind a durable handoff. See [Command Cycle](command-cycle.md).

## Snapshots

Snapshots encode a `(state, registers)` seed at a stream version in
`keiro.keiro_snapshots`. Compatible seeds allow tail replay; incompatible or
unusable seeds cause full replay where retained history permits it. An
application that truncates history must retain a usable seed covering that
history boundary.

Hand-written folds need an explicit `FoldVersion` when behavior changes beyond
what structural hashes can detect. Sampled verification detects some divergence;
use a real-log replay audit before deploying a changed fold. See
[Snapshots](snapshots.md) and [Operations](operations.md).

## Read Models

A `ReadModel q r` is a query identity and SQL contract over application-owned
targets, with schema/version/shape metadata. Register it before serving queries;
Keiro tracks metadata in `keiro.keiro_read_models` and fails closed on stale or
unavailable models.

Use `ReadModelBlueprint` with `immediateReadModel`, `headWaitingReadModel`, or
`positionWaitingReadModel`. A waiting model needs a compatible durable cursor.
`Immediate`, `WaitForHead`, and `WaitForPosition` describe query freshness;
they do not choose how projection writes are delivered.

## Projections

Default query views to asynchronous delivery. A bounded post-commit
`WaitForPosition` can provide read-your-write for a command response. Reserve
inline writes for a stated atomic invariant: every inline handler extends the
global append-lock interval.

An `InlineProjection` applies in the command transaction. An `AsyncProjection`
applies from a subscription. Delivery is at-least-once; its dedup receipt and
SQL changes commit together, suppressing repeated application while the receipt
is retained. Pruning receipts removes that protection for older redeliveries.

Prefer one validated `ProjectionCatalog` for targets, owners, sources,
subscriptions, dedup identities, queries, and rebuild groups. Managed runners
share the group fence; offline/online rebuilds and repair use that same declared
ownership. The application still owns DDL, SQL, replay adapters, and the truth of
its declarations. See [Read Models And Projections](read-models-and-projections.md).

## Process Managers

A process manager reacts to source events, journals its own state, dispatches
commands to target streams, and manages durable timers. Its state/timer update
is atomic; each target append commits separately. Stable dispatch IDs let
redelivery complete missing target work.

Legacy managers derive target IDs from manager/correlation/source identity and
emitted-command index. `Keiro.ProcessManager.Reaction` instead uses physical
target stream and occurrence within that target, and provides explicit
no-advance and accepted-only follow-ups. Switching identity families requires a
drained migration. Legacy positional managers retire with Languages 1–5 before
1.0. See [Process Managers And Timers](process-managers-and-timers.md).

## Timers

Timers in `keiro.keiro_timers` carry a stable identity, earliest fire time,
manager/correlation identity, and payload. Workers claim due rows with
`FOR UPDATE SKIP LOCKED`, invoke application code, and settle or recover the
claim. Configure finite attempts and stale-claim recovery explicitly. A fire
action can repeat after a crash, so its downstream command IDs must be stable.

## Durable Workflows

`Keiro.Workflow` expresses a long-running process as an effectful function with
named, journaled steps. Durable sleep, awakeables, and children suspend it; a
registry-backed resume worker re-invokes runnable instances. Replayed steps reuse
recorded results. An external effect can repeat if its result was not yet
journaled when the process crashed.

Keep step identities and codecs compatible with retained journals. Use `patch`
for replayed control-flow changes and `continueAsNew` to bound generations.
See [Durable Workflows](durable-workflows.md).

## Messaging And Operations

The transactional outbox commits outgoing intent with application events, then
publishes asynchronously. The inbox or a delegated durable receipt handles
incoming deduplication. `keiro-pgmq` supplies typed background jobs; its enqueue
is separate from the Kiroku append transaction. See [Integration Events](integration-events.md)
and [Work Queues](work-queues.md).

`keiro-ops` supplies database operations and application-mounted inspection and
repair capabilities. `keiro-ops-http` optionally exposes the same handlers over
HTTP and shared first-page feeds. Reads are bounded observations, not atomic
snapshots of the whole application. See [Operations](operations.md).
