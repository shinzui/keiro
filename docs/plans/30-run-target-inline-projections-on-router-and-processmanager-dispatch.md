---
id: 30
slug: run-target-inline-projections-on-router-and-processmanager-dispatch
title: "Run target inline projections on Router and ProcessManager dispatch"
kind: exec-plan
created_at: 2026-05-24T18:10:06Z
intention: intention_01ksdk8pcxeb5936reata58z9a
---

# Run target inline projections on Router and ProcessManager dispatch

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro's two reactor primitives — the content-based `Router`
(`src/Keiro/Router.hs`) and the event-sourced `ProcessManager`
(`src/Keiro/ProcessManager.hs`) — dispatch their resolved target commands through
`Keiro.Command.runCommand`. `runCommand` appends the resulting event(s) to the target
stream but **does not run any inline projections**. Inline projections — the read-model
rows committed in the *same* transaction as the append, which are keiro's headline
read-your-own-writes (RYOW) feature — are only run by `Keiro.Projection.runCommandWithProjections`,
which today is reachable **only from the application's own command path** (e.g. a CLI
handler). So when an aggregate is written by the *application* its inline read model is
current, but when the **same aggregate is written by a reactor** (a Router or
ProcessManager dispatch) its inline read model is **left stale** — there is no code path
that runs the projection for a reactor-dispatched command.

This breaks any guard or read that assumes the read model reflects a reactor's own
dispatch. The motivating case (see Surprises — a dogfooding finding from the first real
keiro consumer, Rei) is a two-step coupling: a Router pauses an aggregate by dispatching a
`Pause` command, then later — when a precondition clears — the *same* Router resumes it,
but only if a read-model row shows the aggregate `paused`. Because the pause dispatch never
updated that row, the resume guard never fires. The aggregate is correct in its event
stream (the `Paused` event is appended and stream-folding reads show it), but every
read-model-table reader (status filters, pickers, the reactor's own guard) goes stale.

After this change a `Router` / `ProcessManager` may carry a list of the **target
aggregate's** inline projections, and dispatch runs them in the append transaction —
giving reactor-dispatched writes exactly the RYOW guarantee the application command path
already has. The user-visible payoff: a reactor that mutates an aggregate keeps that
aggregate's inline read models current, so downstream guards and table reads see the
write immediately. A consumer that does not want this passes an empty projection list and
gets the current behaviour unchanged.

Observable acceptance (M3): a jitsurei worked example in which a reactor dispatch updates
a target inline read-model row, asserted by a test that reads the row back after a single
`runRouterOnce` / `runProcessManagerOnce` with no separate projection step.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 — Router runs target inline projections.** Add a `targetProjections ::
      ![InlineProjection targetCo]` field to `Router` (`src/Keiro/Router.hs`); change
      `runRouterOnce`'s `dispatchCommand` to call `runCommandWithProjections` instead of
      `runCommand`, threading `router ^. #targetProjections`. Update the construction sites
      that must compile (`test/Main.hs` `demoRouter` / `failingRouter`; jitsurei
      `Paging.pagingRouter`, `AgentQualRouter.agentQualRouter`) to pass
      `targetProjections = []`. Completed 2026-05-24; `cabal build all` is green. The
      `cabal test keiro-test` validation is blocked by the pre-existing ephemeral database
      schema issue recorded in Surprises.
- [x] **M2 — ProcessManager runs target inline projections.** Same change for
      `ProcessManager` (`src/Keiro/ProcessManager.hs`): add `targetProjections`, swap the
      target dispatch (`runCommand` at the `dispatchCommand` helper) for
      `runCommandWithProjections`. The manager-state append (`runCommandWithSql`) is
      untouched. Update construction sites (`test/Main.hs` `counterProcessManager`; jitsurei
      `FulfillmentProcess.fulfillmentProcessManager`, `EscalationProcess.escalationProcessManager`)
      to pass `targetProjections = []`. Completed 2026-05-24; `fulfillmentProcessManager`
      was then advanced to `[orderSummaryInlineProjection]` for M3. `cabal build all` is
      green; the test-suite run is blocked by the schema issue recorded in Surprises.
- [x] **M3 — Worked example + regression test (RYOW-on-dispatch).** In jitsurei, wire the
      existing `orderSummaryInlineProjection` into `fulfillmentProcessManager`'s target
      dispatch and add a test asserting the order-summary read-model row changes to
      `packed` after a single `runProcessManagerOnce` that dispatches `MarkPacked` (no
      separate projection apply). This was implemented 2026-05-24 without introducing a new
      read-model table. The new spec compiles, but `cabal test jitsurei-test` cannot reach
      the assertion until the ephemeral database has the kiroku schema.
- [x] **M4 — Docs + consumer-migration note.** Update the `Router` / `ProcessManager`
      haddocks to state that dispatch runs `targetProjections` in the append transaction
      (and that `[]` recovers the prior behaviour); note the migration (every `Router{…}` /
      `ProcessManager{…}` gains the field) and the motivating Rei adoption. Update public
      examples in `docs/guides/routers-and-effectful-fan-out.md`,
      `docs/guides/coordinating-incident-response-with-routers-and-process-managers.md`,
      and `docs/user/api-reference.md`. Completed 2026-05-24.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **(Motivating dogfooding finding — Rei, the first real keiro consumer, 2026-05-24.) A
  Router that mutated an aggregate left that aggregate's inline read-model table stale,
  silently breaking a downstream guard.** Rei's Habit auto-pause/resume coupling is a keiro
  `Router` (`Rei.Modules.Habit.Reactor.AutoPauseRouter`): on a `HabitBlockerDeclared` it
  dispatches `PauseHabit`; on the last `HabitBlockerResolved` it dispatches `ResumeHabit`,
  but only if the `habits` read-model row shows the habit `paused`. At the Habit cutover the
  Router fired correctly — `kiroku.stream_events` showed `HabitPaused` appended ~150 ms
  after the blocker, and stream-folding reads (`habit show`/`list`) reported `Paused` — but
  the `public.habits` table row stayed `active`, so the resume guard would never match.
  Root cause: `runRouterOnce` (`src/Keiro/Router.hs`) dispatches via `runCommand`, which
  appends but runs no inline projection; the habit inline projection only ran on Rei's CLI
  write path (`runCommandWithProjections`); and no async projection covered the `habit`
  category. The Rei reactor's own haddock had asserted the opposite — "PauseHabit flips the
  read model to paused (read-your-own-writes via the inline projection)" — which is the
  exact mental-model gap this plan closes: *the command cycle runs my inline projection* is
  true for the application path but not for reactor dispatch. The same gap affects every
  reactor whose target has a table-backed guard/read.

- **(Confirmed against the tree, 2026-05-24.) `Keiro.ProcessManager` has the identical gap.**
  `runProcessManagerOnce`'s target `dispatchCommand` also calls `runCommand`
  (`src/Keiro/ProcessManager.hs`), so a PM whose target has an inline read model leaves it
  stale too. The fix must cover both primitives, not just `Router`.

- **(Confirmed against the tree, 2026-05-24.) The fix needs no new command-cycle code and
  no import cycle.** `Keiro.Projection.runCommandWithProjections` already does exactly what
  is needed — it runs `runCommandWithSqlEvents` with a callback that applies each
  `InlineProjection` to every `(event, recorded)` pair *in the append transaction* — and
  returns the **same** `Either CommandError (CommandResult …)` shape as `runCommand`, with
  the same `Eq co` constraint the reactors already carry. `Keiro.Projection` imports only
  `Keiro.Command` and `Keiro.EventStream` (not `Keiro.Router` / `Keiro.ProcessManager`), so
  the reactors can import it without a cycle.

- **(API validation, 2026-05-24.) The field-based API is the right public shape for this
  change, with one compatibility cost.** `runRouterOnce`, `runRouterWorker`,
  `runProcessManagerOnce`, and `runProcessManagerWorker` keep their existing signatures;
  the projection registry belongs on the long-lived `Router` / `ProcessManager` value,
  next to `targetEventStream`, because it is a property of the target aggregate being
  dispatched to rather than of one runner invocation. The cost is that exporting
  `Router(..)` and `ProcessManager(..)` means adding a record field is a source-breaking
  change for direct record construction, so the plan must update every repository example
  and user-facing guide and clearly document `targetProjections = []` as the migration for
  consumers that do not need inline projection on dispatch.

- **(Worked-example validation, 2026-05-24.) M3 can reuse the existing order-summary read
  model instead of adding a new table.** `Jitsurei.FulfillmentProcess.fulfillmentProcessManager`
  already dispatches `MarkPacked` to `orderEventStream` when it observes
  `PaymentApproved`, and `Jitsurei.ReadModels.orderSummaryInlineProjection` already updates
  the `jitsurei_order_summary` row for `OrderPacked`. The regression test only needs to
  seed the order summary through the existing inline projection on `PlaceOrder` /
  `ApprovePayment`, run the fulfillment process manager once, and assert the status is
  `packed`.

- **(Validation blocker, 2026-05-24.) The Haskell test suites currently fail before
  reaching the reactor projection assertions because the ephemeral PostgreSQL databases
  lack the kiroku event-store schema.** `cabal test keiro-test` reported 51 failures; the
  first failure was `relation "stream_events" does not exist` while reading
  `counter-command-create`, and unrelated command/read-model/outbox/inbox specs failed the
  same way. `cabal test jitsurei-test` reported 15 failures; the ordinary order command
  cycle and the new fulfillment projection spec both failed before dispatch for the same
  missing `stream_events` relation. This is outside the reactor implementation path; the
  source change is still build-validated by `cabal build all`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix it in keiro (a library change) rather than have consumers work around it
  per-reactor (register a duplicate async projection, or rewrite each guard to fold the
  target stream).
  Rationale: the gap is structural to the dispatch path and affects every consumer reactor
  with a table-backed read; a single uniform library fix that gives reactor dispatch the
  same RYOW the application path has is cleaner than N per-reactor workarounds, and it makes
  the natural mental model ("the command cycle runs my inline projection") true everywhere.
  Date: 2026-05-24

- Decision: Reuse `Keiro.Projection.runCommandWithProjections` verbatim; do not add a new
  command-cycle entry point.
  Rationale: it already runs projections in the append transaction, returns the identical
  result shape `runRouterOnce`/`runProcessManagerOnce` already pattern-match on, and skips
  the projection on a no-op (`CommandNoOp`) and on a condemned/duplicate append — exactly
  the dispatch semantics the reactors need. The swap is drop-in.
  Date: 2026-05-24

- Decision: Add a `targetProjections :: ![InlineProjection targetCo]` record field to both
  `Router` and `ProcessManager` (rather than a separate "with-projections" constructor or a
  phantom default).
  Rationale: explicit and discoverable; `[]` recovers the current behaviour exactly; keiro
  is pre-1.0 so adding a record field and updating the handful of construction sites is
  acceptable, and an explicit field documents the capability at every call site. (A smart
  constructor `router`/`processManager` defaulting the field to `[]` may be added later for
  ergonomics, but is not required by this plan.)
  Date: 2026-05-24

- Decision: Keep `targetProjections` on the reactor record, not as an additional argument
  to `runRouterOnce` / `runProcessManagerOnce`.
  Rationale: the projections are part of the target aggregate contract in the same way
  `targetEventStream` is. Keeping the runner signatures unchanged avoids pushing
  projection registration through every call site and worker, while still making the
  capability visible where a reactor is declared.
  Date: 2026-05-24

- Decision: Cover both `Router` and `ProcessManager` in this one plan.
  Rationale: they share the dispatch path and the gap; splitting would leave a known-broken
  primitive and duplicate the migration churn.
  Date: 2026-05-24

- Decision: The ProcessManager's **manager-state** append (`runCommandWithSql` for the PM's
  own state stream) is out of scope — only the **target** command dispatch gains projections.
  Rationale: the PM state stream is the manager's private event log, not a consumer read
  model; `targetProjections` is about the *target* aggregate's read models. (A PM that also
  wants its manager-state projected can be considered separately.)
  Date: 2026-05-24

- Decision: Use `Jitsurei.FulfillmentProcess.fulfillmentProcessManager` and
  `Jitsurei.ReadModels.orderSummaryInlineProjection` for the M3 regression.
  Rationale: the target aggregate and inline read model already exist, so the test focuses
  on the new API behavior instead of mixing in unrelated schema work. It also demonstrates
  the ProcessManager case that has the same production risk as Router dispatch.
  Date: 2026-05-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation. At completion: both reactor primitives run
their target's inline projections on dispatch; a jitsurei worked example + test prove a
reactor-dispatched command updates a target read-model row in the same transaction; the
`[]` default preserves prior behaviour; and the motivating Rei consumer adopts the field
[`targetProjections = [habitInlineProjection, …]`] and its Habit auto-resume guard then
fires — closing the dogfooding loop.)

2026-05-24: Implemented the public API and dispatch semantics. `Router` and
`ProcessManager` now carry `targetProjections`, target dispatch calls
`runCommandWithProjections`, existing examples use `[]` where append-only behavior is
intended, and the jitsurei fulfillment process manager demonstrates a non-empty target
projection list with an order-summary regression spec. `cabal build all` succeeds. The
database-backed test suites are blocked by an unrelated ephemeral schema initialization
problem (`stream_events` missing) before they can validate the new behavior end-to-end.


## Context and Orientation

This section assumes no prior knowledge of keiro internals. All paths are relative to the
keiro repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

**What keiro is.** keiro is a Haskell runtime that ties together a pure transducer core
(keiki) and an append-only PostgreSQL event store (kiroku). Its command cycle hydrates an
aggregate from its stream, runs a keiki transducer step to produce events, and appends
them. On top of that it offers read-model **projections**, a content-based **Router**, an
event-sourced **ProcessManager**, durable **timers**, and snapshots. The packages are
`keiro-core` (the `Codec`/`EventStream`/`Stream`/`Snapshot` foundation, under
`keiro-core/src/Keiro/`) and `keiro` (the runtime: `Command`, `Projection`, `Router`,
`ProcessManager`, `Timer`, under `src/Keiro/`). The canonical worked-example package is
`jitsurei` (under `jitsurei/`). Build with `cabal build all`; the test suites are
`keiro-test` and `jitsurei-test` (see the `Justfile`).

**The command cycle** lives in `src/Keiro/Command.hs`:

- `runCommand :: RunCommandOptions -> EventStream phi rs s ci co -> Stream (EventStream …)
  -> ci -> Eff es (Either CommandError (CommandResult (EventStream …)))` — hydrate, run the
  transducer, append. **Runs no projections.**
- `runCommandWithSqlEvents :: … -> ci -> ([(co, RecordedEvent)] -> AppendResult ->
  Tx.Transaction a) -> Eff es (Either CommandError (CommandResult …, Maybe a))` — the same
  cycle, but the append happens inside a `Hasql.Transaction` and the supplied callback runs
  **in that same transaction** with each appended event reconstructed as a `RecordedEvent`.
  On a `CommandNoOp` (the transducer produced no events) the callback is **not** run; on an
  append conflict the transaction is `Tx.condemn`ed and the callback's effects roll back.
- `CommandError` (in the same module) has constructors `HydrationDecodeFailed`,
  `HydrationReplayFailed`, `CommandRejected`, `EncodeFailed`, `StoreFailed StoreError`,
  `RetryExhausted`. The reactors specifically pattern-match `StoreFailed (DuplicateEvent …)`
  to fold an idempotent re-dispatch into a benign duplicate.

**Inline projections** live in `src/Keiro/Projection.hs`:

```haskell
data InlineProjection co = InlineProjection
  { name  :: !Text
  , apply :: !(co -> RecordedEvent -> Tx.Transaction ())
  }

runCommandWithProjections ::
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es,
   BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  [InlineProjection co] ->
  Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co)))
```

`runCommandWithProjections` is implemented as `runCommandWithSqlEvents` with an
`afterAppend` callback that, for each appended `(event, recorded)` pair, runs every
projection's `apply event recorded` in the append transaction, then drops the `Maybe a`
(returning the same `Either CommandError (CommandResult …)` as `runCommand`). It is the
exact primitive the reactors need, but is currently only called from application code.

**The Router** (`src/Keiro/Router.hs`):

```haskell
data Router input targetPhi targetRs targetState targetCi targetCo es = Router
  { name :: !Text
  , key :: !(input -> Text)
  , resolve :: !(input -> Eff es [PMCommand targetCi])
  , targetEventStream :: !(EventStream targetPhi targetRs targetState targetCi targetCo)
  }
```

`runRouterOnce options router sourceEvent input` resolves the target commands, then for
each one derives a `deterministicCommandId`, pre-checks `eventAlreadyIn` the target stream
(returning `PMCommandDuplicate` if already processed), and otherwise dispatches:

```haskell
outcome <- runCommand targetOptions targetEventStream targetStream (command ^. #command)
pure $ case outcome of
  Right result -> PMCommandAppended result
  Left (StoreFailed (DuplicateEvent (Just duplicateId))) | duplicateId == commandId -> PMCommandDuplicate commandId
  Left (StoreFailed (DuplicateEvent Nothing)) -> PMCommandDuplicate commandId
  Left err -> PMCommandFailed err
```

This `runCommand` is the only place the Router appends; it is the line this plan changes.

**The ProcessManager** (`src/Keiro/ProcessManager.hs`) has the same `targetEventStream`
field and a `dispatchCommand` helper that calls `runCommand options (manager ^.
#targetEventStream) …` for each target command (it additionally appends to the manager's
own state stream via `runCommandWithSql`, which is unrelated and untouched).

**Why `runCommandWithProjections` is a safe drop-in for `runCommand` here.** Same return
type (`Either CommandError (CommandResult …)`), same constraints plus `Eq co` (already
required by both reactors). On a duplicate/conflict the transaction is condemned, so the
projection does not run for a non-append; on a `CommandNoOp` the callback is skipped, so no
projection runs when no event is produced. Combined with the Router/PM's existing
`eventAlreadyIn` pre-check and deterministic command id, each dispatched command appends
**and projects exactly once**; replay/redelivery short-circuits to `PMCommandDuplicate`
before re-running anything. So idempotency is preserved end-to-end.

**Construction sites that must keep compiling** when the field is added (found 2026-05-24):

- `src/Keiro/Router.hs` — the `Router` data definition (the field is added here).
- `src/Keiro/ProcessManager.hs` — the `ProcessManager` data definition (field added here).
- `test/Main.hs` (the `keiro-test` suite) — `demoRouter`, `failingRouter`,
  `counterProcessManager`.
- `jitsurei/src/Jitsurei/Paging.hs` — `pagingRouter`.
- `jitsurei/src/Jitsurei/AgentQualRouter.hs` — `agentQualRouter`.
- `jitsurei/src/Jitsurei/FulfillmentProcess.hs` — `fulfillmentProcessManager` (initially
  `[]` in M2, then `[orderSummaryInlineProjection]` in M3).
- `jitsurei/src/Jitsurei/EscalationProcess.hs` — `escalationProcessManager`.
- `docs/guides/routers-and-effectful-fan-out.md` — published `Router` type and
  `agentQualRouter` example.
- `docs/guides/coordinating-incident-response-with-routers-and-process-managers.md` —
  published `pagingRouter` example and process-manager prose.
- `docs/user/api-reference.md` — public API description for `Keiro.Router`,
  `Keiro.ProcessManager`, and `Keiro.Projection`.

All source examples pass `targetProjections = []` except
`fulfillmentProcessManager` after M3, which passes `[orderSummaryInlineProjection]` to
demonstrate the feature.

**API shape validation.** This is a good addition to keiro's public API because it puts the
new capability at the point where users define a reactor's target, not at each runner call.
The list type is deliberately simple: multiple inline projections already compose by
running each `apply` action for each appended event, and `[]` means "append only." The field
name must stay `targetProjections` rather than `projections` to prevent a common
misreading: these projections apply to the **target aggregate's events**, not to the source
event and not to a ProcessManager's private state stream. The API remains explicit and
predictable, with the known source break limited to record construction sites because the
library currently exports the record constructors.

**Downstream consumer (for context; not edited by this plan).** Rei
(`/Users/shinzui/Keikaku/bokuno/rei-project/rei.keiro-migration`) is the first real keiro
consumer and the source of the motivating finding. After this plan lands and Rei re-pins
keiro, Rei adopts the field — e.g. its Habit auto-pause Router passes `targetProjections =
[habitInlineProjection]` — which is what makes its auto-resume guard fire. That adoption is
tracked in Rei's MasterPlan #8 (`docs/plans/94-…`, Wave B-5) and Rei's keiro dogfooding
ledger; it is **out of scope here** but is the validation that closes the loop.


## Plan of Work

The work is four milestones. M1 and M2 are the core fix (one primitive each), M3 proves it
with a worked example + test, M4 documents it. Each milestone leaves the tree building and
both test suites green.

### M1 — Router runs target inline projections

Scope: make `runRouterOnce` run the target aggregate's inline projections in the append
transaction.

Edits in `src/Keiro/Router.hs`:

1. Imports: replace `import Keiro.Command (CommandError (..), RunCommandOptions, runCommand)`
   with `import Keiro.Command (CommandError (..), RunCommandOptions)` and add
   `import Keiro.Projection (InlineProjection, runCommandWithProjections)`. (Keep
   `CommandError (..)` — the `StoreFailed (DuplicateEvent …)` pattern still needs it.)
2. Add the field to `Router`:

   ```haskell
   , targetProjections :: ![InlineProjection targetCo]
   -- ^ Inline projections for the target aggregate, run in the same transaction as
   --   each dispatched command's append (read-your-own-writes for reactor dispatch).
   --   Pass @[]@ to append without projecting (the pre-EP-30 behaviour).
   ```

3. In `runRouterOnce`'s `dispatchCommand`, replace the dispatch line:

   ```haskell
   outcome <- runCommand targetOptions targetEventStream targetStream (command ^. #command)
   ```

   with:

   ```haskell
   outcome <-
     runCommandWithProjections
       targetOptions
       targetEventStream
       targetStream
       (command ^. #command)
       (router ^. #targetProjections)
   ```

   The `case outcome of …` block is unchanged (identical result type).

Then update the construction sites so the suites compile: add `targetProjections = []` to
`demoRouter` and `failingRouter` in `test/Main.hs`, and to `pagingRouter`
(`jitsurei/src/Jitsurei/Paging.hs`) and `agentQualRouter`
(`jitsurei/src/Jitsurei/AgentQualRouter.hs`).

Acceptance: `cabal build all`; `cabal test keiro-test`; `cabal test jitsurei-test` — all
green (behaviour unchanged because every site passes `[]`).

### M2 — ProcessManager runs target inline projections

Scope: the same change for `ProcessManager`.

Edits in `src/Keiro/ProcessManager.hs`:

1. Imports: drop `runCommand` from the `Keiro.Command` import if it becomes unused (keep
   `runCommandWithSql`, used for the manager-state append); add `import Keiro.Projection
   (InlineProjection, runCommandWithProjections)`.
2. Add `targetProjections :: ![InlineProjection targetCo]` to the `ProcessManager` record
   (same haddock as the Router field).
3. In the target `dispatchCommand` helper, replace `runCommand options (manager ^.
   #targetEventStream) targetStream (command ^. #command)` with
   `runCommandWithProjections options (manager ^. #targetEventStream) targetStream
   (command ^. #command) (manager ^. #targetProjections)`. Leave the manager-state
   `runCommandWithSql` append untouched.

Update construction sites: `counterProcessManager` (`test/Main.hs`),
`fulfillmentProcessManager` (`jitsurei/src/Jitsurei/FulfillmentProcess.hs`),
`escalationProcessManager` (`jitsurei/src/Jitsurei/EscalationProcess.hs`) — add
`targetProjections = []`.

Acceptance: build + both suites green.

### M3 — Worked example + regression test (RYOW on dispatch)

Scope: demonstrate and lock in the feature with the existing fulfillment example. Do not add
a new read-model table. Instead, wire
`Jitsurei.ReadModels.orderSummaryInlineProjection :: InlineProjection OrderEvent` into
`Jitsurei.FulfillmentProcess.fulfillmentProcessManager`, whose target is already
`orderEventStream`. Import `orderSummaryInlineProjection` in
`jitsurei/src/Jitsurei/FulfillmentProcess.hs` and set:

```haskell
, targetProjections = [orderSummaryInlineProjection]
```

The regression test belongs in `jitsurei/test/Main.hs`, under "Jitsurei process manager"
or "Jitsurei read model". It needs a live store, just like the existing jitsurei command,
read-model, and process-manager tests. The exact scenario is:

1. Initialize framework and application tables with `initializeJitsureiTables`.
2. Run `samplePlaceOrder` through `runCommandWithProjections … [orderSummaryInlineProjection]`.
3. Run `sampleApprovePayment` through `runCommandWithProjections … [orderSummaryInlineProjection]`.
4. Read `orderSummaryReadModel (OrderSummaryQuery sampleOrderId)` and assert the row exists
   with `status == "paid"` before the reactor dispatch.
5. Find the recorded `PaymentApproved` event from the order stream and run
   `runFulfillmentOnce defaultRunCommandOptions paymentRecorded (PaymentApproved …)` once.
6. Assert the process-manager result has `[PMCommandAppended{}]`.
7. Read the same order summary again and assert `status == "packed"`. There must be no
   separate call to `runCommandWithProjections` for the `MarkPacked` command; the
   projection is applied by `runProcessManagerOnce` through `targetProjections`.
8. Run the same `runFulfillmentOnce` again with the same source `RecordedEvent`, assert
   `(PMStateDuplicate{}, [PMCommandDuplicate{}])`, then read the summary again and assert
   it is still `packed`. This proves idempotent replay does not re-run the projection.

Acceptance: the new test passes; `cabal test jitsurei-test` green.

### M4 — Docs + consumer-migration note

Scope: update the haddocks on `Router` and `ProcessManager` to document that dispatch runs
`targetProjections` in the append transaction and that `[]` preserves prior behaviour. Add
a one-paragraph migration note (every `Router{…}`/`ProcessManager{…}` gains the field) at
the top of each module or in the relevant `docs/` note. Update the public examples in
`docs/guides/routers-and-effectful-fan-out.md` and
`docs/guides/coordinating-incident-response-with-routers-and-process-managers.md` so every
shown record literal includes `targetProjections = []` or the concrete projection list.
Update `docs/user/api-reference.md` to mention that:

- `Router` and `ProcessManager` carry `targetProjections`;
- the projections are for target events only;
- `[]` gives append-only dispatch and is the migration default;
- non-empty lists give read-your-own-writes for reactor-dispatched commands.

If a design doc describes reactor dispatch / read-model semantics (e.g. the Router plan
`docs/plans/26-…` or the escalation worked-example plan `docs/plans/28-…`), add a
back-reference to this plan. Record the motivating Rei finding so the dogfooding provenance
is captured.

Acceptance: `cabal build all` still green (haddock comments only); the migration note names
every construction site a consumer must touch.


## Concrete Steps

State the exact commands to run and where to run them (working directory). All commands run
from the keiro repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless noted. Update
this section with real transcripts as work proceeds.

```bash
# Survey the exact construction sites before editing (re-confirm; pre-1.0 churn):
rg -n "= Router$|Router\{|= ProcessManager$|ProcessManager\{" src/ jitsurei/ test/
rg -n "= Router$|Router\{|= ProcessManager$|ProcessManager\{" docs/guides docs/user
rg -n "runRouterOnce|runProcessManagerOnce|runRouterWorker|runProcessManagerWorker" src/Keiro/Router.hs src/Keiro/ProcessManager.hs

# After the M1/M2 edits:
cabal build all
cabal test keiro-test
cabal test jitsurei-test

# M3 (worked example uses the existing jitsurei order-summary read model):
cabal test jitsurei-test
# Optionally run the demo to see it end-to-end:
just jitsurei-escalation   # or the recipe hosting the chosen example
```

Commit per milestone with a Conventional-Commits message and the plan trailer, e.g.:

```text
feat(router): run target inline projections on Router dispatch

runRouterOnce now dispatches via runCommandWithProjections, threading a new
Router.targetProjections field, so reactor-dispatched commands update the target
aggregate's inline read models in the append transaction (read-your-own-writes).
[] preserves the prior behaviour.

ExecPlan: docs/plans/30-run-target-inline-projections-on-router-and-processmanager-dispatch.md
```


## Validation and Acceptance

- **M1/M2 (no behaviour change for `[]` consumers):** `cabal build all`, `cabal test
  keiro-test`, `cabal test jitsurei-test` all green with every existing construction site
  passing `targetProjections = []`. This proves the field addition + dispatch swap are
  transparent when no projections are supplied.
- **M3 (the feature):** a jitsurei test seeds the order-summary inline read model to
  `paid`, dispatches `MarkPacked` exactly once through
  `fulfillmentProcessManager`/`runProcessManagerOnce`, and then reads the same row back as
  `packed` with no separate projection apply. A second dispatch of the same source event
  yields `PMCommandDuplicate` and leaves the row at `packed`, proving idempotent replay
  does not double-apply projections.
- **Whole change:** the only semantic difference from before is that a reactor carrying a
  non-empty `targetProjections` now updates the target's read model in the append
  transaction. The `[]` path preserves the prior `runCommand` semantics (same result shape,
  same duplicate/no-op handling).


## Idempotence and Recovery

All edits are pure source changes; rebuilding is the only "apply" step and is safe to
repeat. The runtime behaviour preserves keiro's existing dispatch idempotency: the
`eventAlreadyIn` pre-check + `deterministicCommandId` short-circuit a redelivered source
event to `PMCommandDuplicate` *before* dispatch, so neither the append nor the projection
re-runs; and within a dispatch, a conflicting append condemns the transaction so the
projection's writes roll back atomically. A consumer can revert to the prior behaviour at
any time by passing `targetProjections = []`. M3 reuses the existing
`jitsurei_order_summary` table and `initializeJitsureiTables`, so it adds no migration and
is safe to rerun against the ephemeral jitsurei test database.


## Interfaces and Dependencies

**Modules:** `Keiro.Router` and `Keiro.ProcessManager` (edited) depend on
`Keiro.Projection` (`InlineProjection`, `runCommandWithProjections`) and `Keiro.Command`
(`CommandError`, `RunCommandOptions`). `Keiro.Projection` depends only on `Keiro.Command`
and `Keiro.EventStream`, so importing it from the reactors introduces no cycle.

**Signatures that must exist at the end of each milestone:**

- M1: `Router` gains
  `targetProjections :: ![InlineProjection targetCo]` (the other type parameters
  unchanged: `Router input targetPhi targetRs targetState targetCi targetCo es`).
  `runRouterOnce`'s signature is unchanged; only its body now calls
  `runCommandWithProjections`.
- M2: `ProcessManager` gains the same `targetProjections :: ![InlineProjection targetCo]`
  field; `runProcessManagerOnce`'s signature is unchanged.
- M3: `jitsurei/src/Jitsurei/FulfillmentProcess.hs` imports
  `orderSummaryInlineProjection` and sets
  `targetProjections = [orderSummaryInlineProjection]`; `jitsurei/test/Main.hs` asserts
  that a fulfillment-driven `MarkPacked` dispatch updates `orderSummaryReadModel` from
  `paid` to `packed` without a separate projection call.

**Build/test commands:** `cabal build all`; `cabal test keiro-test`; `cabal test
jitsurei-test` (the `Justfile` `test` recipe runs both plus the jitsurei diagrams check).


## Revision Note — 2026-05-24

Validated the plan as a public API addition. The revision keeps the
`targetProjections` field-based design, records why it is the right API shape, adds the
source-breaking migration/documentation cost, expands M4 to include public guides and the
API reference, and replaces the vague M3 worked-example search with the existing
`FulfillmentProcess` + `orderSummaryInlineProjection` regression path.

## Revision Note — 2026-05-24

Associated this ExecPlan with intention `intention_01ksdk8pcxeb5936reata58z9a` in the
frontmatter so future implementation commits can include the matching `Intention:`
trailer.
