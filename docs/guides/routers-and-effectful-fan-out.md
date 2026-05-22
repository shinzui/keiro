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
resolved chapter — with the same crash-safe, exactly-once-per-target idempotency
the process manager provides.

The primitive is `Keiro.Router`
([`../../src/Keiro/Router.hs`](../../src/Keiro/Router.hs)); the worked example is
[`../../jitsurei/src/Jitsurei/AgentQualRouter.hs`](../../jitsurei/src/Jitsurei/AgentQualRouter.hs).

## Router vs. process manager

| | `ProcessManager` | `Router` |
| --- | --- | --- |
| Target resolution | pure `handle :: input -> ProcessManagerAction` | effectful `resolve :: input -> Eff es [PMCommand targetCi]` |
| State | has its own `pm:…` state stream, `correlate`, self-command | stateless — no state stream, no self-command |
| Use it when | targets follow purely from the event | targets must be queried from a read model |

A `Router` is a stateless, content-based router in the Enterprise Integration
Patterns sense: examine a message, compute its recipients, forward. Its only new
capability over the process manager is that recipient resolution runs in
`Eff es`.

## The shape

```haskell
data Router input targetPhi targetRs targetState targetCi targetCo es = Router
  { name :: !Text
    -- stable id; part of every dispatched command's deterministic id
  , key :: !(input -> Text)
    -- correlation string for the source event (e.g. the transaction id)
  , resolve :: !(input -> Eff es [PMCommand targetCi])
    -- THE seam: effectfully compute the data-dependent target set
  , targetEventStream :: !(EventStream targetPhi targetRs targetState targetCi targetCo)
  }
```

`resolve` is where the read-model query happens. Everything else mirrors the
target half of a process manager.

## The read model

The router needs a queryable mapping from area to chapters. In `jitsurei` that is
`areaChaptersReadModel`, keyed by `AreaId` and returning the `(member, chapter)`
pairs whose service areas include it:

```haskell
areaChaptersReadModel :: ReadModel AreaId [ChapterTarget]
areaChaptersReadModel = ReadModel
  { name = "jitsurei-area-chapters"
  , tableName = "jitsurei_area_chapters"
  , subscriptionName = "jitsurei-area-chapters-sub"
  , version = 1
  , shapeHash = "jitsurei-area-chapters-v1"
  , defaultConsistency = Strong
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
`EventStream` built exactly as in [Build The Command Side](build-the-command-side.md).
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
            , command = RecordTransaction transaction.txnId
            }
        | target <- targets
        ]
  , targetEventStream = chapterEventStream
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
`(router name, key input, source event id, target index)`, pre-checks whether
that id is already in the target stream, and folds the store's duplicate
rejection into `PMCommandDuplicate`. Re-running the router over the same source
event — after a crash, or a retried delivery — therefore writes nothing new.

## Running as a worker

`runRouterWorker` drives a router from a Shibuya `Adapter`, decoding each message
to a `(RecordedEvent, input)` pair and dispatching it. Its ack policy:

- a message that fails to decode is `AckHalt`;
- after dispatch, if every target is `PMCommandAppended` or `PMCommandDuplicate`
  the message is `AckOk`;
- if any target is `PMCommandFailed`, the message is `AckHalt` so the source
  event is retried — idempotent replay makes the retry safe.

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
