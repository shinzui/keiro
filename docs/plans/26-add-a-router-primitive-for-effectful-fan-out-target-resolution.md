---
id: 26
slug: add-a-router-primitive-for-effectful-fan-out-target-resolution
title: "Add a Router primitive for effectful fan-out target resolution"
kind: exec-plan
created_at: 2026-05-20T18:41:14Z
intention: "intention_01ks6zzqrwe6t84g28ntqsda9t"
---

# Add a Router primitive for effectful fan-out target resolution

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today keiro can fan one event out to many target streams only when the set of
targets is a *pure* function of the triggering event. That capability is the
`ProcessManager` in `src/Keiro/ProcessManager.hs`: its handler has type
`handle :: input -> ProcessManagerAction ci targetCi` (a pure function), and
the list of target commands it returns (`commands :: [PMCommand targetCi]`)
must therefore be computable from the event alone.

A large class of real fan-outs cannot be expressed that way, because the
target set must be *looked up* — read from a projection (a "read model": a
queryable table kept up to date from the event log). The motivating example is
the agent-qualification decomposition documented in
`docs/research/13-agent-qualification-runtime-wiring.md` and validated against
the production aggregate at
`/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master`. There, a single
incoming property-sale transaction must be routed to every "chapter" whose
geographic service areas overlap the property's areas. The original computes
that set with a SQL query — `where $1 && location_service_qualification_area_ids`
against the `mls_service_read.chapters` table
(`mls-service-v2-core/src/MlsService/Repository/Tables/Chapter.hs:106`) — i.e.
*effectfully*, before it builds any command. keiro has no primitive for "run an
effectful query to decide the targets, then dispatch idempotently to each."

This plan adds that primitive: a `Router`. After this change, a developer can
declare a stateless subscriber that, for each incoming event, runs an
`Eff es` action (typically a read-model query via
`Keiro.ReadModel.runQuery`) to produce a data-dependent list of target streams
and commands, and the framework dispatches one command per target with the
same crash-safe, exactly-once-per-target idempotency the `ProcessManager`
already provides (deterministic command identifiers plus a duplicate check).

You will be able to see it working: a test feeds one source event whose target
set is stored in a read-model table, observes that exactly one command was
appended to each resolved target stream, then feeds the *same* source event
again and observes that every dispatch is reported as a duplicate and no new
events are written. That is the observable proof of "effectful fan-out
resolution" plus "idempotent replay."

Three concrete consumers motivate the primitive (all in research note 13): the
transaction router (area → chapters), the retire coordinator (member →
chapters, on agent removal), and the correction saga (invalid adjustments →
corrections). This plan delivers the primitive and one worked end-to-end
example; wiring all three production consumers is downstream work.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `src/Keiro/Router.hs` with the `Router` type, `RouterResult`, and `runRouterOnce`; export `eventAlreadyIn` from `Keiro.ProcessManager`; add `Keiro.Router` to `keiro.cabal` exposed-modules and re-export it from `src/Keiro.hs`; package builds with `cabal build all`. (done 2026-05-22; `cabal build keiro` clean.)
- [x] M1: Add a `keiro-test` spec proving effectful, data-dependent fan-out and idempotent replay (one source event → N targets resolved by a read-model query; replay → all duplicates, no new events). (done 2026-05-22; two specs green; both negative controls verified — see Surprises & Discoveries.)
- [ ] M2: Add `runRouterWorker` (Shibuya `Adapter`-driven loop) with the documented ack policy; add a worker-level spec.
- [ ] M3: Add a worked `agent-qual-router` example to the `jitsurei` package (an area→chapters read model, a small chapter-like target aggregate, and a `Router`), plus a `jitsurei-test` spec demonstrating the research-note-13 design end-to-end.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- M1 negative control (a) — the read-model query is load-bearing. Temporarily
  stubbing `demoRouter`'s `resolve` to return a fixed 3-element list
  (independent of `routerTargetsReadModel`) made the "resolves targets
  effectfully" spec fail at the unseeded-group assertion:

  ```text
  test/Main.hs:767:22:
  1) Keiro.Router resolves targets effectfully and fans out one command per target
       expected: 0
        but got: 3
  ```

  i.e. routing an unseeded group `"no-such-group"` returned 3 targets instead of
  0, proving the count tracks the read model rather than a constant. Reverted.

- M1 negative control (b) — `deterministicCommandId` is load-bearing for
  idempotency. Temporarily replacing the per-target id with a fresh
  `EventId <$> liftIO UUID.V4.nextRandom` in `runRouterOnce` made the replay spec
  fail: the second dispatch of the same source event produced new appends
  (`StreamVersion 2`, all `PMCommandAppended`) instead of duplicates:

  ```text
  test/Main.hs:795:11:
  1) Keiro.Router reports every dispatch as a duplicate on replay, writing no new events
       predicate failed on: [PMCommandAppended (CommandResult {target = Stream {name = StreamName "router-target-a"}, streamVersion = StreamVersion 2, ...}), ...]
  ```

  Reverted; with the deterministic id restored, replay yields three
  `PMCommandDuplicate` and the target streams stay at one event each.

- Pre-existing, unrelated test failures in `Keiro.ReadModel`. Two specs —
  "waits for async projection cursor with PositionWait" (`test/Main.hs:575`) and
  "times out when PositionWait target is not reached" (`test/Main.hs:589`) —
  fail with a `Pattern match failure in 'do' block` on the `Right () <-`
  binding of `upsertSubscriptionCursorStmt`. Verified these are **pre-existing on
  pristine `master`**: with all my changes stashed (`git stash -u`) and the
  ephemeral-pg cache cleared, the `Keiro.ReadModel`-only run still reports the
  same 2 failures. They are the only two specs that use
  `upsertSubscriptionCursorStmt` and fail deterministically (likely a
  `subscriptions`-table schema drift in a kiroku-store update); fixing them is
  out of scope for this plan. My Router additions add 2 passing examples and
  introduce 0 new failures (full suite: 79 examples, the same 2 failures).

- The `keiro-test` suite runs with hspec **randomized ordering** ("Randomized
  with seed …" in output) over a *cached* ephemeral Postgres (`Pg.withCached`),
  so cross-spec state can persist within a run. The Router specs are robust to
  this because each seeds its own `router_targets` rows and asserts on
  per-target stream names it owns.


## Decision Log

Record every decision made while working on the plan.

- Decision: Introduce a new `Keiro.Router` type rather than adding an effectful handler variant to `ProcessManager`.
  Rationale: A `Router` is *stateless* — it has no manager state stream, no `correlate`, and no self-directed `command` (compare `ProcessManager` in `src/Keiro/ProcessManager.hs:40-55`, which appends a state-advance event to a `pm:…` stream on every input). Its only new capability is that target resolution is effectful. Bolting an `Eff es` handler onto `ProcessManager` would either fork its type signature or break its existing pure consumers (the `counterProcessManager`/`fulfillmentProcessManager` tests). A focused new type leaves `ProcessManager` untouched and names the stateless-router concept directly.
  Date: 2026-05-20

- Decision: The effect row `es` appears as a type parameter on the `Router` record, because `resolve :: input -> Eff es [PMCommand targetCi]` is a field.
  Rationale: Matches `ProcessManager`'s "bundle everything in the record" ergonomics and reads cleanly at call sites. The alternative — keep `Router` effect-free and pass `resolve` as a separate argument to the runner — was considered and rejected for asymmetry with `ProcessManager` and for splitting one logical declaration across two values.
  Date: 2026-05-20

- Decision: Reuse `deterministicCommandId`, `eventAlreadyIn`, and per-target `runCommand` from `Keiro.ProcessManager` verbatim; export `eventAlreadyIn` (currently a private helper at `src/Keiro/ProcessManager.hs:212`).
  Rationale: Idempotent fan-out is already solved and correct in `ProcessManager`; the *only* new thing is effectful target resolution. Sharing the dispatch primitives avoids divergence in the idempotency logic.
  Date: 2026-05-20

- Decision: The worker (`runRouterWorker`) acks (advances the subscription) only when every dispatched command is `PMCommandAppended` or `PMCommandDuplicate`; if any is `PMCommandFailed`, it halts so the source event is retried. Benign domain rejections (a command the target aggregate refuses because no edge matches — e.g. a "QualifyCheck" below threshold) must be modeled as *total* transitions (an ε-complement self-loop in the keiki transducer) so they never surface as `PMCommandFailed`.
  Rationale: Acking past a transient store failure would silently drop a dispatch; halting + idempotent replay is the safe default. Requiring totality for "check" commands keeps that default from misfiring on ordinary domain outcomes — and the keiki core already supports total edges.
  Date: 2026-05-20

- Decision: Scope is the primitive plus one worked example, validated against the original `mls-service-v2`. The three production consumers (transaction router, retire coordinator, correction saga) are named but not wired here.
  Rationale: The primitive is the reusable unit; wiring each consumer needs its own read models and codecs and belongs in follow-on work. Research note 13 records the full target design.
  Date: 2026-05-20

- Decision: Make data-dependence load-bearing *inside* the committed M1 spec (not only via the temporary negative control) by also routing an unseeded group and asserting it resolves to zero targets.
  Rationale: A fixed-list `resolve` would pass a "3 seeded → 3 dispatched" assertion by coincidence; adding "unseeded group → 0 dispatched" makes the read-model query observably load-bearing in CI, while the temporary stub (Surprises & Discoveries) confirms the assertion actually fails when `resolve` ignores the read model.
  Date: 2026-05-22

- Decision: Treat the two failing `Keiro.ReadModel` PositionWait specs as out of scope and do not fix them under this plan.
  Rationale: They reproduce on pristine `master` with a cleared ephemeral-pg cache and no Router code present (verified via `git stash -u`), so they are not regressions from this work. They concern `upsertSubscriptionCursorStmt` / the `subscriptions` table, unrelated to the Router primitive. Fixing them would mix an unrelated bug fix into this plan's commits.
  Date: 2026-05-22
  Rationale: keiro's stateful fan-out primitive already takes its name from the EIP *Process Manager* — a stateful coordinator with `correlate` and its own state stream (`src/Keiro/ProcessManager.hs:40-55`). The new primitive is *stateless*: no state stream, no `correlate`, no self-command. Its sole job is to inspect an event and dispatch to a runtime-resolved set of target streams — which is the EIP *content-based Router* / dynamic *Recipient List*: examine a message, compute its recipients, forward. Naming it `Router` keeps the pair `(ProcessManager, Router)` reading as the two EIP patterns they are — the stateful coordinator vs. the stateless routing element — and names the *concern* (routing / target resolution, research note 13 §1) rather than the mechanism (the effectful `resolve` field). The network-router analogy holds: a stateless element whose only job is to pick a message's next hop(s).
  Date: 2026-05-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of this repository. Read it fully before editing.

**What keiro is.** keiro is a Haskell event-sourcing framework and workflow
engine (one library package, `keiro.cabal`, sources under `src/Keiro/`). "Event
sourcing" means application state is stored as an append-only log of events per
"stream" (one stream ≈ one entity instance); current state is recovered by
replaying the events. keiro builds on two sibling libraries: `kiroku-store`
(the Postgres-backed event store; its effect type is `Store`, run with
`Kiroku.Store.runStoreIO`) and `keiki` (a pure state-machine/aggregate core —
a "transducer" that, given a state and a command, computes the next state and
an optional output event). keiro uses the `effectful` library: computations run
in `Eff es` where `es` is a type-level list of capabilities (e.g.
`Store :> es` means "the event store is available").

**The command cycle.** The single-stream write path is `runCommand` in
`src/Keiro/Command.hs:264`:

```haskell
runCommand ::
  ( HasCallStack, IOE :> es, Store :> es, Error StoreError :> es
  , BoolAlg phi (RegFile rs, ci), Eq co ) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co)))
```

It hydrates the stream (snapshot + replay), runs the keiki transducer one step,
and appends the emitted event under optimistic concurrency. `RunCommandOptions`
(`src/Keiro/Command.hs:66`) has fields `retryLimit`, `pageSize`, and
`eventIds :: [EventId]`; `defaultRunCommandOptions` (`:81`) leaves `eventIds`
empty. Supplying `eventIds` forces the identifiers of the appended events,
which is how deterministic (idempotent) appends are achieved.

`EventStream phi rs s ci co` (`src/Keiro/EventStream.hs:14`) bundles a keiki
transducer with its initial state/registers, an event `Codec`, a stream-name
resolver, and a snapshot policy. `Stream a` (`src/Keiro/Stream.hs:12`) is a
newtype over a single `StreamName` (it is *not* a structured key; composite
identities are encoded into the name string). `RegFile rs` is keiki's typed
register file (per-stream scalar state); `BoolAlg phi (…)` is a keiki
constraint carried through for symbolic analysis — you never construct it, you
just propagate it in signatures.

**The existing fan-out primitive.** `src/Keiro/ProcessManager.hs` defines:

```haskell
data ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo = ProcessManager
  { name :: !Text
  , correlate :: !(input -> Text)
  , eventStream :: !(EventStream phi rs s ci co)            -- the PM's own state stream
  , streamFor :: !(Text -> Stream (EventStream phi rs s ci co))
  , targetEventStream :: !(EventStream targetPhi targetRs targetState targetCi targetCo)
  , handle :: !(input -> ProcessManagerAction ci targetCi)  -- PURE
  }

data ProcessManagerAction ci targetCi = ProcessManagerAction
  { command :: !ci                       -- advances the PM's own state
  , commands :: ![PMCommand targetCi]    -- fan-out targets
  , timers :: ![TimerRequest]
  }

data PMCommand targetCi = PMCommand
  { target :: !(Stream targetCi)
  , command :: !targetCi
  }

data PMCommandResult target
  = PMCommandAppended !(CommandResult target)
  | PMCommandDuplicate !EventId
  | PMCommandFailed !CommandError
```

The runner `runProcessManagerOnce` (`:97`) appends the PM's own state event
(via `runCommandWithSql`, `:125`) and then dispatches each target command in
its **own** `runCommand` (`:165`). Crucially, **fan-out is not one
multi-stream transaction** — each target append is a separate transaction.
Crash-safety comes from deterministic identifiers:

```haskell
deterministicCommandId :: Text -> Text -> EventId -> Int -> EventId
--                        name    corrId  sourceEvent emitIndex     (src/Keiro/ProcessManager.hs:81)
```

plus a pre-check `eventAlreadyIn` (`:212`, currently private) and the store's
`DuplicateEvent` rejection. On replay the same identifiers are re-derived, so
already-appended commands are detected and skipped. This is the correct model
because N independent optimistic-concurrency streams cannot be written in one
distributed transaction; idempotent replay — not atomicity — is what makes
one-event-in → N-commands-out safe.

**The gap this plan closes.** The fan-out list `commands` is produced by the
*pure* `handle`. To route by a read-model lookup, resolution must be effectful.
`Keiro.ReadModel.runQuery` (`src/Keiro/ReadModel.hs:57`) is the query API:

```haskell
runQuery :: (IOE :> es, Store :> es) => ReadModel q r -> q -> Eff es (Either ReadModelError r)
```

There is no seam in `ProcessManager` to call this between "event arrives" and
"targets computed." The `Router` provides that seam.

**The worker substrate.** `runProcessManagerWorker` (`:179`) drives the
process manager from a Shibuya `Adapter es msg` (a pull-based stream of
messages; `Shibuya.Adapter`), decoding each message to `(RecordedEvent,
input)` and producing an `AckDecision` (`AckOk` to advance, `AckHalt` to stop).
`Router`'s worker mirrors this.

**Where the design is recorded.** `docs/research/13-agent-qualification-runtime-wiring.md`
is the case study this primitive serves; its §3, §5, §6, §10 name the three
consumers and the `Router` shape. `keiki/docs/research/agent-qualification-decomposition-sketch.md`
is the companion that models the pure per-chapter aggregate. You do not need to
read the production source to implement this plan, but the routing query cited
above (`mls-service-v2-core/src/MlsService/Application/TransactionRecorder.hs:150`
calling `findChaptersWithQualifyingAreaIds`, `Repository/ChapterRepository.hs:39`)
is the ground-truth example of effectful target resolution in the wild.

**Build and test commands.** From the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal build all          # or: just haskell-build
cabal test keiro-test    # the library's test-suite (keiro.cabal:91)
cabal test jitsurei-test # the worked-examples package (jitsurei/jitsurei.cabal)
# or both at once:
just haskell-test
```

Tests provision their own ephemeral Postgres via the `EphemeralPg` module (see
`test/Main.hs:2139` `withTestStore` and `jitsurei/test/Main.hs:205`), so a
running database is not required, but the Postgres binaries must be on `PATH` —
use the project's Nix dev shell (`nix develop`, or `direnv allow` if configured)
so they are present.


## Plan of Work

The work is three milestones. M1 delivers the primitive and the headline
behavior. M2 adds the worker so a `Router` can run as a real subscription. M3
adds a domain-flavored worked example that matches research note 13.

### Milestone M1 — the `Router` type and `runRouterOnce`

Scope: introduce the primitive and prove "effectful, data-dependent fan-out +
idempotent replay" with a `keiro-test` spec. At the end, `Keiro.Router` exists,
the package builds, and a test demonstrates the behavior.

First, make the shared idempotency helper reusable. In
`src/Keiro/ProcessManager.hs`, add `eventAlreadyIn` to the module's export list
(top of file, the `module Keiro.ProcessManager ( … )` block). It is already
defined at `:212`; only the export is missing. Do not change its body.

Then create `src/Keiro/Router.hs`. The type mirrors the *target half* of
`ProcessManager` (no manager state stream, no `correlate`, no self `command`),
with an effectful `resolve`:

```haskell
module Keiro.Router
  ( Router (..)
  , RouterResult (..)
  , runRouterOnce
  , runRouterWorker
  ) where

import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Stack (HasCallStack)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError, RunCommandOptions, runCommand)
import Keiro.EventStream (EventStream)
import Keiro.Prelude
import Keiro.ProcessManager (PMCommand (..), PMCommandResult (..), deterministicCommandId, eventAlreadyIn)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (RecordedEvent)
-- plus Shibuya imports for the worker (added in M2)

data Router input targetPhi targetRs targetState targetCi targetCo es = Router
  { name :: !Text
    -- ^ stable identifier; part of every dispatched command's deterministic id
  , key :: !(input -> Text)
    -- ^ correlation string for the source event (e.g. the transaction id)
  , resolve :: !(input -> Eff es [PMCommand targetCi])
    -- ^ THE new seam: effectfully compute the data-dependent target set
    --   (typically `runQuery readModel q`)
  , targetEventStream :: !(EventStream targetPhi targetRs targetState targetCi targetCo)
  }
  deriving stock (Generic)

newtype RouterResult target = RouterResult
  { commandResults :: [PMCommandResult target]
  }
  deriving stock (Generic, Eq, Show)
```

`runRouterOnce` resolves the targets, then dispatches each with a deterministic
identifier derived from `(name, key input, sourceEvent's id, emitIndex)`,
pre-checking `eventAlreadyIn` and treating the store's `DuplicateEvent` as a
benign duplicate — exactly the per-command logic in `runProcessManagerOnce`'s
`dispatchCommand` (`src/Keiro/ProcessManager.hs:155-174`), lifted out of the
`where`-clause:

```haskell
runRouterOnce ::
  forall input targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack, IOE :> es, Store :> es, Error StoreError :> es
  , BoolAlg targetPhi (RegFile targetRs, targetCi), Eq targetCo ) =>
  RunCommandOptions ->
  Router input targetPhi targetRs targetState targetCi targetCo es ->
  RecordedEvent ->   -- source event: supplies the id that seeds deterministic command ids
  input ->
  Eff es (RouterResult (EventStream targetPhi targetRs targetState targetCi targetCo))
runRouterOnce options router sourceEvent input = do
  let corrId = (router ^. #key) input
  commands <- (router ^. #resolve) input          -- the effectful seam
  results <-
    traverse
      (\(i, cmd) -> dispatchOne corrId (sourceEvent ^. #eventId) i cmd)
      (zip [0 ..] commands)
  pure (RouterResult results)
  where
    dispatchOne corrId sourceEventId emitIndex (PMCommand targetStream command) = do
      let commandId = deterministicCommandId (router ^. #name) corrId sourceEventId emitIndex
          targetOptions = options & #eventIds .~ [commandId]
          targetEventStream = router ^. #targetEventStream
          targetStream' = coerceTarget targetStream
          targetStreamName = (targetEventStream ^. #resolveStreamName) targetStream'
      already <- eventAlreadyIn options targetStreamName commandId
      if already
        then pure (PMCommandDuplicate commandId)
        else do
          outcome <- runCommand targetOptions targetEventStream targetStream' command
          pure $ case outcome of
            Right result -> PMCommandAppended result
            Left (StoreFailed (DuplicateEvent (Just dup))) | dup == commandId -> PMCommandDuplicate commandId
            Left (StoreFailed (DuplicateEvent Nothing)) -> PMCommandDuplicate commandId
            Left err -> PMCommandFailed err
```

`coerceTarget :: Stream targetCi -> Stream (EventStream …)` is the same
`coerce` `runProcessManagerOnce` uses (`retarget`, `:176`) — `Stream` is a
phantom-tagged newtype, so the coercion is total and free. Import `Data.Coerce
(coerce)` and `Keiro.Stream (Stream)` to write it.

Note `runRouterOnce` returns `RouterResult` directly (no outer `Either
CommandError`), because — unlike `ProcessManager` — there is no manager-state
append that can fail before dispatch. Per-target failures are inside the
`PMCommandResult` list.

Wire the new module in: add `Keiro.Router` to the `exposed-modules` of the
`library` stanza in `keiro.cabal` (the stanza beginning at `keiro.cabal:31`),
and add `, module Keiro.Router` plus `import Keiro.Router` to `src/Keiro.hs`
(the umbrella module, currently re-exporting `Keiro.Command`, `Keiro.Codec`,
etc.).

The M1 test goes in `test/Main.hs`. Reuse the counter target aggregate that
`counterProcessManager` already dispatches to (defined in `test/Main.hs`; see
its use at `:595`) so you do not define a new aggregate. Add a tiny read model
that maps a "group" to a list of target counter stream names, so resolution is
genuinely effectful and data-dependent. Concretely:

1. Create a table and a `ReadModel` whose query, given a group id, returns the
   list of target stream identifiers for that group. Model it on the existing
   counter read model in `test/Main.hs` (search for `initializeCounterReadModelTable`
   and the `ReadModel` value near `:483`). The table can be as small as
   `router_targets(group_id text, target_id text)`.
2. Define a `Router` whose `resolve grp = do { Right ids <- runQuery targetsReadModel grp; pure [ PMCommand (counterStream i) bumpCommand | i <- ids ] }`, where `counterStream`/`bumpCommand` are the target stream constructor and command the counter aggregate already uses.
3. The spec body, under `around withTestStore`, initializes the schemas
   (`initializeReadModelSchema`, the counter table, the targets table), seeds
   the targets table with, say, three ids for one group, constructs a
   `RecordedEvent` to act as the source (mirror how `:595` builds `sourceEvent`),
   then:

```haskell
Right (RouterResult rs1) <- Store.runStoreIO store $
  runRouterOnce defaultRunCommandOptions demoRouter sourceEvent (RouteGroup "g1")
-- assert: length rs1 == 3 and all are PMCommandAppended
Right (RouterResult rs2) <- Store.runStoreIO store $
  runRouterOnce defaultRunCommandOptions demoRouter sourceEvent (RouteGroup "g1")
-- assert: length rs2 == 3 and all are PMCommandDuplicate
```

(Match the existing `Store.runStoreIO store $ …` pattern; the `Right (… )`
pattern unwraps the `Either StoreError` that `runStoreIO` returns, as the
existing tests do at `:595`.) Finally assert that each target counter stream
has exactly one event after both runs (replay added nothing) — read the stream
with the store read API the existing tests use, or assert via the counter read
model.

Acceptance for M1: `cabal build all` succeeds; `cabal test keiro-test` passes,
and the new spec fails if you stub `resolve` to ignore the read model (proving
the query is load-bearing) or if you replace `deterministicCommandId` with a
random id (proving idempotency is load-bearing). Record both negative checks in
Surprises & Discoveries.

### Milestone M2 — `runRouterWorker`

Scope: let a `Router` run as a live subscription over a Shibuya `Adapter`,
with the documented ack policy. At the end, a worker-level spec drives a stream
of messages through the router and asserts the fan-out.

Add `runRouterWorker` to `src/Keiro/Router.hs`, mirroring
`runProcessManagerWorker` (`src/Keiro/ProcessManager.hs:179-207`):

```haskell
runRouterWorker ::
  forall msg input targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack, IOE :> es, Store :> es, Error StoreError :> es
  , BoolAlg targetPhi (RegFile targetRs, targetCi), Eq targetCo ) =>
  RunCommandOptions ->
  Router input targetPhi targetRs targetState targetCi targetCo es ->
  Adapter es msg ->
  (msg -> Maybe (RecordedEvent, input)) ->
  Eff es ()
```

Drive it with `Streamly.fold Fold.drain . Streamly.mapM handleIngested
. source` exactly as the process-manager worker does. The ack policy
(Decision Log): decode failure → `AckHalt (HaltFatal …)`; otherwise run
`runRouterOnce`, then inspect the `RouterResult` — if every element is
`PMCommandAppended` or `PMCommandDuplicate`, return `AckOk`; if any is
`PMCommandFailed err`, return `AckHalt (HaltFatal (show err))` so the source
event is retried (idempotent replay makes retry safe). Import the Shibuya
pieces the process-manager worker imports (`Shibuya.Adapter (Adapter (..))`,
`Shibuya.Core.Ack`, `Shibuya.Core.Ingested`, `Shibuya.Core.Types (Envelope
(..))`, and the two `Streamly.Data.*` modules).

The M2 spec (in `test/Main.hs`) builds an in-memory `Adapter` yielding two or
three messages (follow any existing Shibuya adapter test helper in
`test/Main.hs`; if none exists, construct an `Adapter` whose `source` is a
`Streamly` stream of `Ingested` envelopes wrapping your messages) and asserts
that after the worker drains, the resolved targets each received their command.
Reuse the M1 router and read model.

Acceptance for M2: `cabal test keiro-test` passes with the worker spec;
flipping a dispatched command to fail (e.g. point a target at a stream whose
aggregate rejects the command) makes the worker halt rather than ack, which the
spec asserts.

### Milestone M3 — worked `agent-qual-router` example in `jitsurei`

Scope: a domain-flavored example matching research note 13, so the design is
demonstrated end-to-end and future consumers have a template. At the end, the
`jitsurei` package contains an `agent-qual-router` and a passing
`jitsurei-test` spec.

In `jitsurei/src/Jitsurei/` add a module (e.g. `Jitsurei/AgentQualRouter.hs`)
containing: a minimal chapter-like target aggregate as an `EventStream` (a
single `Record`-style command bumping a tally register and emitting a recorded
event — model it on `Jitsurei/OrderStream.hs:56`); an `areaChapters`
`ReadModel` mapping an area id to a list of `(member, chapter)` stream names
(model it on the read models in `Jitsurei/ReadModels.hs`); and a `Router` whose
`resolve txn = do { Right targets <- runQuery areaChaptersRM (txn ^. #areas); pure [ PMCommand (chapterStream m c) (recordCmdFor txn) | (m,c) <- targets ] }`.
Register the module in `jitsurei/jitsurei.cabal` (`other-modules`/`exposed-modules`
of its library stanza) and export what the test needs from `jitsurei/src/Jitsurei.hs`.

The `jitsurei-test` spec (in `jitsurei/test/Main.hs`, following its existing
`around withTestStore` style) seeds the `areaChapters` table so one area maps
to several chapters, feeds one transaction event, asserts one recorded event
per resolved chapter stream, then replays the same source event and asserts all
dispatches are duplicates. This is the executable form of research note 13's §3.

Acceptance for M3: `cabal test jitsurei-test` passes; the spec demonstrates a
data-dependent chapter count (change the seeded mapping → the number of target
streams written changes) and idempotent replay.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.
Ensure the Nix dev shell is active so Postgres binaries are present
(`nix develop`, or rely on `direnv` if configured).

1. M1 edits:
   - Edit `src/Keiro/ProcessManager.hs`: add `eventAlreadyIn` to the export list.
   - Create `src/Keiro/Router.hs` (type + `RouterResult` + `runRouterOnce` as above).
   - Edit `keiro.cabal`: add `Keiro.Router` under the library `exposed-modules` (stanza at `keiro.cabal:31`).
   - Edit `src/Keiro.hs`: `import Keiro.Router` and add `, module Keiro.Router` to the export list.
   - Build:

   ```bash
   cabal build all
   ```

   Expected: the library and `jitsurei` compile. If GHC reports an ambiguous
   `Stream` (it clashes with `Streamly.Data.Stream.Stream`), import keiro's as
   `import Keiro.Stream (Stream)` and qualify Streamly — research note for
   document 08 records this collision and its resolution.

   - Add the M1 spec to `test/Main.hs` and run:

   ```bash
   cabal test keiro-test
   ```

   Expected tail of output:

   ```text
   Router
     resolves targets effectfully and fans out one command per target
     reports every dispatch as a duplicate on replay, writing no new events
   Finished in N.NNNN seconds
   All M tests passed
   ```

2. M2 edits: add `runRouterWorker` to `src/Keiro/Router.hs` and a worker spec to `test/Main.hs`; re-run `cabal test keiro-test`.

3. M3 edits: add `Jitsurei/AgentQualRouter.hs`, register it in `jitsurei/jitsurei.cabal`, export from `jitsurei/src/Jitsurei.hs`, add the spec to `jitsurei/test/Main.hs`, then:

   ```bash
   cabal test jitsurei-test
   ```

4. Full gate before declaring done:

   ```bash
   just haskell-test   # cabal test keiro-test && cabal test jitsurei-test
   ```

Each milestone is a commit (or a few). Every commit must carry the trailers:

```text
ExecPlan: docs/plans/26-add-a-router-primitive-for-effectful-fan-out-target-resolution.md
Intention: intention_01ks6zzqrwe6t84g28ntqsda9t
```


## Validation and Acceptance

The change is effective beyond compilation when this scenario holds (M1, the
headline): a read-model table maps a group to three target stream ids; calling
`runRouterOnce` once with a source event for that group appends exactly one
command to each of the three target streams (three `PMCommandAppended`); calling
it again with the *same* source event returns three `PMCommandDuplicate` and the
target streams still hold exactly one event each. Phrased as the test asserts:

```text
length (commandResults rs1) == 3 && all isAppended  (commandResults rs1)
length (commandResults rs2) == 3 && all isDuplicate (commandResults rs2)
each target stream version == 1   -- replay added nothing
```

Two negative controls prove the two new capabilities are load-bearing, not
incidental: (a) replacing `resolve` with one that returns a fixed list
independent of the read model makes the "data-dependent count" assertion fail
when the seeded mapping changes; (b) replacing `deterministicCommandId` with a
fresh random id makes the replay assertion fail (duplicates become new appends).
Record both in Surprises & Discoveries with the failing output.

M2 acceptance: the worker drains a multi-message adapter and the resolved
targets receive their commands; a deliberately failing dispatch makes the
worker `AckHalt` rather than `AckOk`.

M3 acceptance: the `jitsurei` `agent-qual-router` spec shows one recorded event
per resolved chapter for a seeded area→chapters mapping, a target count that
tracks the mapping, and idempotent replay.

Run the suites with `cabal test keiro-test` and `cabal test jitsurei-test` (or
`just haskell-test`). Success is all specs green; failure prints the offending
expectation with expected-vs-actual, as Hspec does.


## Idempotence and Recovery

The plan's edits are additive and safe to repeat: creating
`src/Keiro/Router.hs`, adding an export, adding cabal modules, and adding specs
are all re-runnable; re-running `cabal build`/`cabal test` is idempotent. No
migrations to production data are involved (test tables live in ephemeral
Postgres provisioned per test run).

The *feature itself* is built for recovery: dispatch is idempotent by
construction (deterministic command ids + duplicate detection), so re-running a
`Router` over the same source events — after a crash, or because the worker
halted and retried — produces no duplicate effects. That property is precisely
what the M1 replay test asserts. If a milestone is left half-done, the Progress
checklist plus the per-file steps above let the next contributor resume from the
exact file under edit.


## Interfaces and Dependencies

New module `Keiro.Router` (file `src/Keiro/Router.hs`), depending only on
already-present libraries (`effectful`, `keiki`, `kiroku-store`, `shibuya`,
`streamly`) and on `Keiro.ProcessManager`, `Keiro.Command`, `Keiro.EventStream`,
`Keiro.Stream`, `Keiro.ReadModel`. No new package dependencies.

Signatures that must exist at the end of each milestone:

- End of M1:
  - `data Router input targetPhi targetRs targetState targetCi targetCo es` with fields `name :: Text`, `key :: input -> Text`, `resolve :: input -> Eff es [PMCommand targetCi]`, `targetEventStream :: EventStream targetPhi targetRs targetState targetCi targetCo`.
  - `newtype RouterResult target = RouterResult { commandResults :: [PMCommandResult target] }`.
  - `runRouterOnce :: (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg targetPhi (RegFile targetRs, targetCi), Eq targetCo) => RunCommandOptions -> Router input targetPhi targetRs targetState targetCi targetCo es -> RecordedEvent -> input -> Eff es (RouterResult (EventStream targetPhi targetRs targetState targetCi targetCo))`.
  - `Keiro.ProcessManager` exports `eventAlreadyIn`.
  - `Keiro.Router` is in `keiro.cabal` exposed-modules and re-exported from `Keiro`.
- End of M2:
  - `runRouterWorker :: (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg targetPhi (RegFile targetRs, targetCi), Eq targetCo) => RunCommandOptions -> Router input targetPhi targetRs targetState targetCi targetCo es -> Adapter es msg -> (msg -> Maybe (RecordedEvent, input)) -> Eff es ()`.
- End of M3:
  - A `jitsurei` module exporting an `EventStream` target aggregate, an `areaChapters` `ReadModel`, and a `Router` value, plus whatever the spec imports.

Reused, unchanged interfaces: `PMCommand (..)`, `PMCommandResult (..)`,
`deterministicCommandId`, `eventAlreadyIn` (from `Keiro.ProcessManager`);
`runCommand`, `RunCommandOptions (..)`, `defaultRunCommandOptions`,
`CommandError` (from `Keiro.Command`); `runQuery`, `ReadModel (..)` (from
`Keiro.ReadModel`); `Stream` (from `Keiro.Stream`); `EventStream` (from
`Keiro.EventStream`); `Store`, `StoreError (..)`, `RecordedEvent` (from
`kiroku-store`); `Adapter`, `AckDecision`, `Ingested`, `Envelope` (from
`shibuya`).
