# Routers And Effectful Fan-Out

A [process manager](process-managers-and-timers.md) fans one event out to other
streams when the set of targets is a *pure* function of the event — its `handle`
returns the target commands directly. A **router** covers the case the process
manager cannot: when the target set must be *looked up* — read from a projection
(a read model) — before any command exists.

`jitsurei` models this with the agent-qualification routing problem: a single
property-sale transaction must be recorded against every "chapter" whose
geographic service areas overlap the transaction's areas. That set of chapters
is not derivable from the transaction alone; it lives in a read-model table and
must be queried. The router runs that query, then dispatches one command per
resolved chapter — with crash-safe, per-target redelivery idempotency whenever
the target is resolved again. Resolver output
may drift between redeliveries; the precise cumulative contract is described
under Idempotency below.

The primitive is `Keiro.Router`
([`../../keiro/src/Keiro/Router.hs`](../../keiro/src/Keiro/Router.hs)); the worked example is
[`../../jitsurei/src/Jitsurei/AgentQualRouter.hs`](../../jitsurei/src/Jitsurei/AgentQualRouter.hs).

## Router vs. process manager

| | `ProcessManager` | `Router` |
| --- | --- | --- |
| Target resolution | pure `handle :: input -> ProcessManagerAction` | effectful `resolve :: input -> Eff es [PMCommand targetCi]` |
| State | has its own `pm:…` state stream, `correlate`, self-command | stateless — no state stream, no self-command |
| Use it when | targets follow purely from the event | targets must be queried from a read model |

## In Enterprise Integration Patterns terms

Keiro's two fan-out primitives are named after the patterns they implement
(Hohpe & Woolf, *Enterprise Integration Patterns*):

- A `Router` is a *Message Router* — here specifically a **content-based
  Router** (it inspects the message to decide where it goes) that forwards to a
  dynamic **Recipient List** (a *set* of destinations computed per message). It
  is stateless: examine a message, compute its recipients, forward to each. The
  one thing keiro adds to the textbook pattern is that the recipient set is
  computed *effectfully* — by querying a read model — so it can route on data
  that is not in the message.
- A `ProcessManager` is the EIP **Process Manager**: a stateful coordinator with
  its own state stream, a correlation id, and timers.

So the choice between them is the EIP choice between a routing element and a
coordinator: reach for the `Router` when you only need "compute the recipients
and forward, now," and the `ProcessManager` when you need to *remember* where a
multi-step process is. The router's only new capability over the process manager
is that recipient resolution runs in `Eff es`.

## The shape

```haskell
data Router input targetPhi targetRs targetState targetCi targetCo es = Router
  { name :: !Text
    -- stable id; part of every dispatched command's deterministic id
  , key :: !(input -> Text)
    -- correlation string for the source event (e.g. the transaction id)
  , resolve :: !(input -> Eff es [PMCommand targetCi])
    -- THE seam: effectfully compute the data-dependent target set
  , targetEventStream :: !(ValidatedEventStream targetPhi targetRs targetState targetCi targetCo)
  , targetProjections :: !(Stream targetCi -> [InlineProjection targetCo])
  }
```

`resolve` is where the read-model query happens. Everything else mirrors the
target half of a process manager. `targetProjections` selects inline projections
per target stream; return `[]` (typically as `const []`) for append-only
dispatch, or return the same projections your command path uses when the router
must keep target read models current in the dispatch transaction.

Use `targetProjections` only when the router, or an immediate reader after the
router runs, depends on the target aggregate's read model reflecting the
dispatched command right away. Keep `targetProjections = const []` for ordinary
fan-out where eventual consistency is acceptable. Do not move expensive reporting,
analytics, integration publishing, or broad denormalization work into this
field; inline projections run inside the append transaction, so slow or failing
projection SQL slows or fails the dispatch itself.

## The read model

The router needs a queryable mapping from area to chapters. In `jitsurei` that is
`areaChaptersReadModel`, keyed by `AreaId` and returning the `(member, chapter)`
pairs whose service areas include it:

```haskell
areaChaptersReadModel :: ReadModel AreaId [ChapterTarget]
areaChaptersReadModel = ReadModel
  { name = "jitsurei-area-chapters"
  , tableName = "jitsurei_area_chapters"
  , schema = "jitsurei"
  , subscriptionName = "jitsurei-area-chapters-sub"
  , version = 1
  , shapeHash = "jitsurei-area-chapters-v1"
  , defaultConsistency = Eventual
  , strongScope = EntireLog
  , query = \(AreaId area) -> Tx.statement area selectAreaChaptersStmt
  }
```

See [Project Read Models](project-read-models.md) for how read models are built
and kept up to date.

## The target aggregate

Each chapter is a tiny event-sourced aggregate: one command,
`RecordTransaction`, that emits one event, `TransactionRecorded`, and stays in a
single `ChapterOpen` state. It is deliberately minimal — the demonstration is the
fan-out, not the chapter's domain. The aggregate is an ordinary Keiro
`EventStream` definition validated exactly as in [Build The Command Side](build-the-command-side.md).
Its stream name is derived from the `(member, chapter)` pair:

```haskell
chapterStream :: MemberId -> ChapterId -> Stream ChapterCommand
chapterStream member chapter =
  stream ("chapter-" <> memberIdText member <> "-" <> chapterIdText chapter)
```

## The router

`agentQualRouter` ties them together. Its `resolve` queries the read model once
per area, de-duplicates chapters that overlap across areas, and produces one
`RecordTransaction` command per resolved chapter stream:

```haskell
agentQualRouter ::
  (IOE :> es, Store :> es) =>
  Router Transaction (HsPred ChapterRegs ChapterCommand) ChapterRegs
         ChapterState ChapterCommand ChapterEvent es
agentQualRouter = Router
  { name = "agent-qual-router"
  , key = \transaction -> txnIdText transaction.txnId
  , resolve = \transaction -> do
      resolved <- traverse (runQuery areaChaptersReadModel) transaction.areas
      let targets = nub (concat [chapters | Right chapters <- resolved])
      pure
        [ PMCommand
            { target = chapterStream target.member target.chapter
            , command = RecordTransaction (RecordTransactionData {txnId = transaction.txnId})
            }
        | target <- targets
        ]
  , targetEventStream = chapterEventStream
  , targetProjections = const []
  }
```

Because `resolve` calls `runQuery`, the router's effect row carries
`(IOE :> es, Store :> es)`. That is the whole point: the read model is in the
loop between "event arrives" and "targets computed."

## Dispatching once

`runRouterOnce` resolves the targets and dispatches each command:

```haskell
RouterResult results <-
  runRouterOnce defaultRunCommandOptions agentQualRouter sourceEvent transaction
```

It takes the recorded source event (its id seeds the deterministic command ids)
and the decoded routing input. The result is one `PMCommandResult` per target:

```haskell
data PMCommandResult target
  = PMCommandAppended !(CommandResult target)  -- newly written
  | PMCommandDuplicate !EventId                -- already written (replay)
  | PMCommandFailed !CommandError              -- store/domain failure
```

There is no outer `Either` — unlike a process manager, a router has no
manager-state append that could fail before dispatch; per-target outcomes live in
the list.

### Idempotency

Fan-out is **not** one multi-stream transaction — each target append is its own
optimistic-concurrency transaction, which cannot be made atomic across N streams.
Safety comes from determinism instead: Keiro derives each command's event id from
`(router name, key input, source event id, resolved target stream name,
occurrence)`, where occurrence counts commands addressed to the same stream in
one resolve batch. It uses a point lookup to pre-check whether that id is already
in the target stream. If a concurrent worker wins after the pre-check, a store
duplicate rejection becomes `PMCommandDuplicate` only after another point lookup
confirms that the attempted id is in that target stream. Target order and the
positions of distinct targets therefore do not affect redelivery ids.

`resolve` remains effectful, so two attempts may produce different target sets.
The cumulative dispatched set is the union of attempt outputs: a target resolved
only on the first attempt keeps its immutable dispatch, while a target first
resolved on a later attempt is dispatched then. Where the exact recipient set
matters, make `resolve` a stable function of the source event across
redeliveries. Repeating one target within a batch is supported; the relative
order of commands for that same target determines their occurrence numbers and
must also remain stable across redeliveries.

## Running as a worker

`runRouterWorker` drives a router from a Shibuya `Adapter` with
`defaultWorkerOptions`, decoding each message to a `(RecordedEvent, input)` pair
and dispatching it. Use `runRouterWorkerWith` to override poison-message
handling, transient retry delay, or dispatch metrics. Its ack policy:

- a message that fails to decode follows the configured `PoisonPolicy` (default:
  `PoisonHalt`, which finalizes the message `AckHalt`);
- after dispatch, if every target is `PMCommandAppended` or `PMCommandDuplicate`
  the message is `AckOk`;
- if any target is `PMCommandFailed`, transient store failures are `AckRetry`
  and deterministic failures are `AckHalt`.

The decision is delivered to the adapter via the message's `AckHandle.finalize`.

Because a halted dispatch is retried, **benign domain rejections must not surface
as `PMCommandFailed`.** If a target aggregate can legitimately refuse a command
(for example, a "check" command below some threshold), model that as a *total*
transition — an ε-complement self-loop in the Keiki transducer — so the command
is accepted as a no-op rather than rejected. Otherwise an ordinary domain outcome
would wedge the worker.

## Verifying it

The spec in
[`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs) (under "Jitsurei
agent-qualification router") seeds two overlapping areas onto a shared chapter,
feeds one transaction, and asserts:

- three *distinct* chapter streams each receive exactly one event (the shared
  chapter is de-duplicated — the count tracks the read model, not a fixed list);
- a transaction whose areas are unseeded resolves to zero targets;
- replaying the same source event reports every dispatch as `PMCommandDuplicate`
  and writes no new events.

Run it with:

```bash
cabal test jitsurei-test
```

## Pairing a router with a process manager

Real workflows usually need both a router and a process manager reacting to the
same event — one to fan out to a looked-up recipient set, the other to run a
stateful, time-bound process. For a worked example that uses both together (an
on-call incident that is *paged* by a router and *escalated* by a process
manager with a timer), see [Coordinating Incident Response: Routers And Process
Managers Together](coordinating-incident-response-with-routers-and-process-managers.md).
