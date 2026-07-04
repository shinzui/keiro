# Choosing A Primitive

Keiro gives you several ways to make parts of a system cooperate: a single
`EventStream`, Keiki transducer composition, read-model projections, process
managers, and routers. The other guides teach each one in depth. This guide is
the map that routes you to the right one.

## The dividing question

Almost every "how do I make these cooperate?" question resolves by asking where
the relationship lives:

- **Inside one consistency boundary** (one stream, one entity, one optimistic-
  concurrency version) → it is a *modeling* concern. Stay in Keiki: one
  transducer, composed if needed.
- **Across streams** (different identities, different lifecycles, eventual
  consistency) → it is a *runtime* concern. Reach for a projection, a process
  manager, or a router.

An aggregate is always exactly one transducer. You never mount more than one
transducer per `EventStream`; when a single entity needs several behaviors,
compose them in Keiki first and mount the single result. See [the composition
note](#a-note-on-transducer-composition-and-alternative) below.

## By shape, reach for…

| If your shape is… | Reach for | Guide |
|---|---|---|
| Decide commands → events for one entity inside one consistency boundary | one validated `EventStream` (one transducer) | [Build The Command Side](build-the-command-side.md) |
| Stage A's events feed stage B as a pipeline, all within one stream | Keiki `compose`, then mount the composite as one validated `EventStream` | Keiki `Keiki.Composition` |
| One round of automatic policy reaction within one stream (command → event → follow-up event), observed atomically | Keiki `feedback1` | Keiki `Keiki.Composition` |
| A spanning invariant across two parts of one entity (a decision must read both parts) | one hand-written transducer with product state — **not** `alternative` | [Build The Command Side](build-the-command-side.md) |
| A queryable view derived from one stream, updated in the command's transaction | inline `Projection` + `ReadModel` | [Project Read Models](project-read-models.md) |
| A queryable view derived from many streams (e.g. an `OrderView` over `Order` and `Payment`) | async `Projection` over a Kiroku **category subscription** | [Project Read Models](project-read-models.md), [Read Models And Projections](../user/read-models-and-projections.md) |
| Long-running cross-stream coordination with its own state, timers, or compensation | `ProcessManager` | [Process Managers And Timers](process-managers-and-timers.md) |
| A single long-running function with in-line waits (a durable sleep, an external callback, child work) | a durable `Workflow` | [Durable Workflows](durable-workflows.md) |
| Stateless fan-out of one event to a target set that needs a read-model lookup, applied idempotently | `Router` | [Routers And Effectful Fan-Out](routers-and-effectful-fan-out.md) |
| Both a fan-out and a saga reacting to the same event | a `Router` and a `ProcessManager` together | [Coordinating Incident Response](coordinating-incident-response-with-routers-and-process-managers.md) |

## A note on transducer composition and `alternative`

Keiki ships three composition combinators — `compose`, `alternative`, and
`feedback1` — that combine transducers into one transducer. Composition is a
Keiki-layer concern: the result is a single `SymTransducer` that you drop into a
single `EventStream`. Keiro adds nothing on top of it.

Before a composed stream reaches a command runner, validate the resulting
`EventStream` with `mkEventStream` or `mkEventStreamOrThrow`; see
[Replayability Safety](../user/replay-safety.md).

`alternative` deserves a specific warning. Keiki's composition guide advertises
it for "two sibling aggregates sharing one runtime channel" with examples like
`Orders` and `Customers`. That framing is about a shared *delivery channel*, not
a shared *log*. Mounting `alternative` as one Keiro `EventStream` forces those
two machines to share one stream — one identity, one version counter, one
snapshot — which is almost never what sibling aggregates want. `Orders` and
`Customers` have different identities and lifecycles; they belong in separate
`EventStream`s, dispatched at your API edge.

The cases where co-locating two transducers in one stream is correct are narrow:
two **independent, non-correlated** vocabularies that must share one identity and
one ordered log purely for packaging reasons. If the two parts interact, you
want `feedback1` (in-stream) or a process manager (cross-stream); if a decision
must read both parts, you want one hand-written product transducer. When in
doubt, model cross-stream cooperation with a runtime primitive — a projection,
process manager, or router — not with `alternative`.
