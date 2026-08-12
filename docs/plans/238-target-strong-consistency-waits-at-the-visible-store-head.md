---
id: 238
slug: target-strong-consistency-waits-at-the-visible-store-head
title: "Target strong-consistency waits at the visible store head"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjzp13e28vvrz7jfdve3dt"
master_plan: "docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md"
---

# Target strong-consistency waits at the visible store head

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A service that garbage-collects finished workflows must not lose the ability to serve
strongly consistent reads. Today it does: after Keiro's workflow garbage collector
hard-deletes the journal streams that happen to occupy the newest global positions in the
event store, every `Strong`-consistency read-model query on a fully caught-up, otherwise
idle system blocks for its full five-second timeout and then fails with
`ReadModelWaitTimeout`. The projection distance gauge simultaneously reports a permanent,
non-zero backlog for a system that has nothing left to consume. Both symptoms persist
until some unrelated event happens to be appended.

After this plan is implemented, a `Strong` query issued after garbage collection on a
caught-up system returns promptly with the correct result, a `Strong` query issued while
the read model is genuinely behind still waits (and still times out honestly if the model
never catches up), and `keiro.projection.global_position_distance` reads zero exactly when
there is nothing visible left to project. You can see all of this working by running the
`keiro-test` suite: this plan adds a database-backed regression test that completes a
workflow, garbage-collects it, and proves the `Strong` query no longer stalls.

This is ExecPlan 2 of the parent MasterPlan
`docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md`
(finding: "Strong-consistency read-model queries stall forever after workflow garbage
collection hard-deletes the newest events"). The 0.12.0.0 release is the first stable
release and ships with no known bugs; this defect was confirmed by the 2026-08-11
pre-release review and must be fixed before the tag.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: add the failing regression test "Strong returns promptly after workflow GC hard-deletes the newest events" to `keiro/test/Main.hs` and observe the current inventory-based head fail the fixed-contract assertion (2026-08-12T16:52:22Z).
- [x] M1: reimplement `storeHeadPosition` in `keiro/src/Keiro/ReadModel.hs` as the newest visible event's global position (keiro-owned `max(stream_version)` statement) and update its Haddock plus the module and `StrongScope` docs (2026-08-12T16:55:27Z).
- [x] M1: rewrite the existing test "uses Kiroku's captured store head after a stream is hard deleted" to assert the new visible-head semantics (head falls back to `GlobalPosition 0`; the inventory's authoritative `storePosition` is unchanged) (2026-08-12T16:55:27Z).
- [x] M1: add the genuine-behind test "Strong still times out when visible events outrun the subscription" asserting the timeout error carries the visible-head target (2026-08-12T16:55:27Z).
- [x] M1: run the `Keiro.ReadModel` test group and confirm all green, including the previously failing regression test: 29 examples, 0 failures (2026-08-12T16:55:27Z).
- [x] M2: rebase `recordProjectionGlobalPositionDistance` in `keiro/src/Keiro/Projection.hs` on the visible head; keep the deprecated `recordProjectionLag` alias recording the identical value (2026-08-12T17:00:29Z).
- [x] M2: add the gauge test "reports zero global position distance after the newest events are hard deleted" and confirm the focused metric tests (2 examples) and full `keiro-test` suite (494 examples) pass with zero failures (2026-08-12T17:00:29Z).
- [x] M3: add the visible head to `keiro-ops` `projection position` and `stream subscriptions` output and compute their distance columns against it; update `keiro-ops/test/Main.hs` expectations and add a hard-delete divergence test; `keiro-ops-test` passes 32 examples (2026-08-12T17:03:19Z).
- [ ] M4: update `docs/user/api-reference.md` and the `CHANGELOG.md` Unreleased entries that describe the inventory-based head.
- [ ] M4: distill the durable decision (wait targets must be reachable positions; the authoritative counter is not a wait target) into a new ADR in `docs/adr/` and run `just adr-validate`.
- [ ] M4: run `just verify` from the repository root and record the result here.
- [ ] Update the parent MasterPlan's Progress entry for EP-2 (238) when the milestones above complete.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Reproduce-first run (2026-08-12): the production workflow-GC scenario failed before
  entering the query wait because `storeHeadPosition` returned the authoritative
  `GlobalPosition 4` after GC while the newest surviving event was `GlobalPosition 1`.
  Evidence:

  ```text
  expected: Right (GlobalPosition 1)
   but got: Right (GlobalPosition 4)
  ```

  This is the planned first assertion of the same defect: a caught-up cursor at position 1
  cannot reach the inventory counter at position 4 after the three newer workflow journal
  events have been hard-deleted.


## Decision Log

Record every decision made while working on the plan.

- Decision: The `Strong`/`EntireLog` wait target becomes the newest VISIBLE event's global
  position, not Kiroku's authoritative `$all` append counter.
  Rationale: A wait target must be a position a caught-up subscription can actually reach.
  Kiroku subscription checkpoints advance only at the tails of delivered batches, and an
  empty fetch (`FetchEmpty` in `Kiroku.Store.Subscription.Fsm.step`) never emits a
  `Checkpoint` effect, so after hard deletion removes the newest events no checkpoint can
  ever reach the authoritative counter until an unrelated append lands. The newest visible
  position is by construction deliverable. This also re-aligns `EntireLog` with
  `CategoryHead`, whose `categoryHeadPosition` never left the visible basis.
  Date: 2026-08-11
- Decision: Implement the visible head with a keiro-owned SQL statement
  (`SELECT COALESCE(max(stream_version), 0) FROM stream_events WHERE stream_id = 0`)
  rather than Kiroku's `readAllBackward (GlobalPosition 0) 1` (the pre-0.12 implementation)
  or a new Kiroku API.
  Rationale: Kiroku 0.5 exports no query that returns the newest visible position without
  fetching the newest event row; `readAllBackward` fetches the full payload and runs it
  through the store's decode hook (`decodeEvents`) on every `Strong` query — wasted work on
  a hot path and a spurious failure mode if the newest payload cannot be decoded. The exact
  statement already exists in `keiro/src/Keiro/ReadModel/Rebuild.hs` (`storeHeadPositionStmt`,
  guarding `finishRebuild`), so the wait target and the rebuild-completion guard share one
  basis, and `categoryHeadPosition` in the same module already documents the precedent of
  reading Kiroku's indexed tables when Kiroku exports no equivalent query. Filing a Kiroku
  improvement request for a public visible-head query is a recorded follow-up, not a
  blocker.
  Date: 2026-08-11
- Decision: Restore the visible-head meaning under the existing exported name
  `storeHeadPosition` instead of adding a parallel `visibleStoreHeadPosition` beside the
  inventory-based one.
  Rationale: The inventory-based semantics never shipped — keiro 0.11.0.0 (released
  2026-08-06 at tag `e796227c`) exported `storeHeadPosition` with visible-head semantics,
  and the rewiring commits `d612b770`/`f47053a7` (2026-08-09, ExecPlan
  `docs/plans/214-adopt-kiroku-s-durable-subscription-checkpoint-inventory.md`) exist only
  in the unreleased 0.12 window. Restoring the released contract avoids offering a
  footgun pair of head functions; callers who need the authoritative counter read the
  public `storePosition` field of Kiroku's `subscriptionCheckpointInventory` directly, as
  `keiro-ops` already does.
  Date: 2026-08-11
- Decision: `recordProjectionGlobalPositionDistance` switches its head operand to the
  visible head; the deprecated `recordProjectionLag` alias keeps recording the identical
  value.
  Rationale: The gauge exists so operators can alert on "the projection has work it has not
  done". Distance to the authoritative counter over-reports forever after GC on a quiet
  system (positions that no subscription can ever reach), which makes any threshold alert
  permanently red — the review's exact finding. Distance to the visible head is the
  actionable backlog and reads zero exactly when the projection is done. Operators who want
  the authoritative counter still have it: `keiro-ops projection position` and
  `stream subscriptions` keep their `store_position` column (see next decision), and
  Kiroku's inventory API is public. The alias contract ("same value under the historical
  name") is unchanged.
  Date: 2026-08-11
- Decision: `keiro-ops` keeps reporting the authoritative `store_position`, additionally
  reports the visible head as `visible_store_head`, and computes its
  `global_position_distance` columns against the visible head.
  Rationale: The operator surface is where "authoritative versus visible" is genuinely
  interesting: the gap between the two columns is precisely the hard-deleted tail. Dropping
  `store_position` would hide capacity/audit information; leaving the distance on the
  authoritative basis would reproduce the permanent-lag defect in every operator readout.
  Reporting both makes each row self-explaining. The visible head is fetched through
  keiro's public `storeHeadPosition`, keeping `keiro-ops` on supported library APIs per
  `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`.
  Date: 2026-08-11
- Decision: The headline regression test drives the real workflow garbage collector
  (`Keiro.Workflow.Gc.gcWorkflowsOnce`), not a bare `hardDeleteStream`; the smaller
  head/gauge unit tests use `hardDeleteStream` directly.
  Rationale: The review scenario is "complete a workflow, GC it, then query" — exercising
  the production deletion path (journal stream plus snapshot, per generation) proves the
  fix against the code that actually creates the condition, while the unit tests stay
  minimal and fast.
  Date: 2026-08-11
- Decision: Accept one deliberately slow (~5 s) test: `Strong` genuine-behind timeout via
  `runQueryWith`.
  Rationale: `Strong` uses the fixed `defaultStrongWaitOptions` (5 s timeout, 10 ms poll),
  so an honest end-to-end proof that the give-up still works — and that the reported target
  is now the visible head — costs five seconds once. The fast-timeout path is already
  covered by the existing `PositionWait` tests using `fastWaitOptions` (50 ms).
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestone 1 restores `storeHeadPosition` to the newest visible `$all` event and pins
both sides of the contract. A caught-up Strong query now returns promptly after the
workflow collector deletes a newer journal tail, while a genuinely behind subscription
still waits five seconds and reports `ReadModelWaitTimeout` with the visible target.
The focused `Keiro.ReadModel` group passes all 29 examples.

Milestone 2 rebases projection distance telemetry on the visible event head. The
preferred `keiro.projection.global_position_distance` gauge and deprecated
`keiro.projection.lag` alias now both report zero when a checkpoint is at the newest
surviving event after tail deletion. The focused metric tests and all 494 `keiro-test`
examples pass.

Milestone 3 exposes both notions of head in `keiro-ops`. `store_position` remains
the authoritative append counter, `visible_store_head` reports the newest surviving
event, and member plus summary distances use the visible value. The hard-delete
fixture proves the columns diverge from 5 to 4 while the orders floor distance becomes
2; all 32 `keiro-ops-test` examples pass.


## Context and Orientation

Everything below was verified against the working tree at the commit this plan was
written on (`5db45a42` on `master`) and against the Kiroku 0.5.0.0 sources. Repository
root: the `keiro` multi-package Haskell repository. All paths are repository-relative
unless stated otherwise.

### Vocabulary

An *event store* (Kiroku, the `kiroku-store` library) persists immutable events in named
*streams*. Every event also joins the global `$all` stream, whose ordering key is the
*global position* (`GlobalPosition`, a monotonically increasing `Int64`; positions start
at 1). A *subscription* is a named durable consumer of the log; Kiroku persists its
progress as a *checkpoint* row in the `subscriptions` table, keyed by
`(subscription_name, consumer_group_member)`. A *read model* is a named SQL projection
table plus the query that reads it (`Keiro.ReadModel.ReadModel`); a *projection* is the
code that folds events into that table. *Hard deletion* (`Kiroku.Store.Lifecycle.hardDeleteStream`)
physically removes a stream's rows: its `$all` junction rows in `stream_events`, its
orphaned `events` rows, and its `streams` row. Keiro's *workflow garbage collector*
(`keiro/src/Keiro/Workflow/Gc.hs`) hard-deletes the journal streams of terminal workflow
instances older than a retention cutoff (see `deleteWorkflow`, which calls
`hardDeleteStream` for every generation of the workflow's journal stream).

Two different notions of "head of the log" are central to this plan:

- The *authoritative store position* is `streams.stream_version` for `stream_id = 0` (the
  `$all` bookkeeping row seeded by Kiroku's bootstrap migration). It is a pure append
  counter: hard deletion removes events but never decrements it.
- The *visible store head* is the global position of the newest event that still exists —
  `max(stream_events.stream_version)` for `stream_id = 0`, or 0 when nothing is visible.

The two coincide until something is hard-deleted from the tail of the log; then the
authoritative counter is strictly larger, permanently, until new appends catch up past it.

### The defect

`keiro/src/Keiro/ReadModel.hs` implements consistency waits. `runQueryWith` calls
`waitIfNeeded` (line ~289), which for `Strong` with the `EntireLog` scope captures a
target with `storeHeadPosition` and passes it to `waitFor`, a poll loop that repeatedly
reads the model's subscription checkpoint (`readSubscriptionPosition`, the minimum
`last_seen` across consumer-group members with the exact subscription name) until it
reaches the target or `timeoutMicros` elapses (`defaultStrongWaitOptions`: 5 s timeout,
10 ms poll), then fails with `ReadModelWaitTimeout name target observed`.

Commit `d612b770` ("feat(read-model): adopt durable checkpoint inventory", 2026-08-09,
ExecPlan `docs/plans/214-adopt-kiroku-s-durable-subscription-checkpoint-inventory.md`)
rewired `storeHeadPosition` from the newest visible event (it previously called Kiroku's
`readAllBackward (GlobalPosition 0) 1` and took the returned event's `globalPosition`,
falling back to 0 on an empty log) onto Kiroku's one-statement checkpoint inventory:

```haskell
-- current, defective (keiro/src/Keiro/ReadModel.hs, ~line 336)
storeHeadPosition :: (Store :> es) => Eff es GlobalPosition
storeHeadPosition = storePosition <$> subscriptionCheckpointInventory
```

`subscriptionCheckpointInventory` (Kiroku 0.5,
`Kiroku.Store.Subscription`, implemented by
`Kiroku.Store.Subscription.CheckpointInventory.SQL.getSubscriptionCheckpointInventoryStmt`)
reads `streams.stream_version WHERE stream_id = 0` — the authoritative counter — so
`storePosition` counts hard-deleted events.

Why no checkpoint can reach that counter after tail deletion: Kiroku's subscription
worker advances the durable checkpoint only when it delivers a batch (the FSM in
`Kiroku.Store.Subscription.Fsm.step` emits `Checkpoint` only alongside `DeliverBatch`
tails or a handler `Stop`); an empty fetch produces the `FetchEmpty` input, whose
transitions (`CatchingUp c → (Live c, [EmitCaughtUp])` and `Live c → (Live c, [RunLive])`)
emit no `Checkpoint` effect. So a subscription whose checkpoint sits at the newest
*visible* position fetches nothing, stays exactly there, and is — correctly — caught up.
Meanwhile the `Strong` target is the authoritative counter, which is strictly above every
reachable position. Every `Strong` `runQuery` on the deployment blocks for the full five
seconds and returns `ReadModelWaitTimeout`, and it heals only when some unrelated append
gives the subscription a new batch tail to checkpoint at.

The same wrong operand feeds telemetry: `recordProjectionGlobalPositionDistance`
(`keiro/src/Keiro/Projection.hs`, ~line 432) computes
`globalPositionDistance (storePosition inventory) checkpoint` and records it on the
`keiro.projection.global_position_distance` gauge and its deprecated
`keiro.projection.lag` alias (`keiro/src/Keiro/Telemetry.hs`, lines 974–978) — permanently
non-zero on a caught-up system after GC. The `keiro-ops` read-only commands
`projection position` (`keiro-ops/src/Keiro/Ops/Projection.hs`, `positionResult`) and
`stream subscriptions` (`keiro-ops/src/Keiro/Ops/Stream.hs`, `subscriptionInventoryResult`)
compute their `global_position_distance` columns from the same captured `storePosition`
and over-report identically.

Note what is *not* defective: `readSubscriptionPosition` / `subscriptionPositionFromInventory`
(member-aware checkpoint floor) are correct and keep using the inventory;
`categoryHeadPosition` (the `CategoryHead` strong scope) always computed a visible-basis
head (`max(se.stream_version)` over the category's `$all` junction rows) and is
unaffected; `finishRebuild` in `keiro/src/Keiro/ReadModel/Rebuild.hs` already has a
private `storeHeadPositionStmt` with exactly the visible-basis SQL this plan adopts.

### Why the visible head is a sound wait target (races)

`waitFor` captures the target once, before polling. Checkpoint saves are monotonic (an
existing row only advances; Kiroku's checkpoint decision
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`, summarized in
`docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`),
so the poll loop's observed position never regresses mid-wait. The visible head captured
at query start is the position of an event that existed at capture time, so a subscription
consuming `$all` reaches it in one of exactly two ways: it delivers that event (checkpoint
lands at or beyond the target, because batch tails are at-or-after every delivered
position), or the event is hard-deleted after capture and any later append pushes the next
batch tail past the target. The visible head itself may *regress* between two queries
(further GC of the tail), but that is harmless: each wait compares against its own
captured target, and a smaller later target only makes later waits easier to satisfy.

The residual window is narrow and honest: if the captured target is hard-deleted during
the wait, no later append arrives within the timeout, and the model's subscription had
not yet consumed that far, the wait times out. That subscription was genuinely behind by
more than the GC retention period (the collector only deletes terminal workflows older
than `WorkflowGcPolicy.retention`), so a timeout is the truthful answer — unlike the
defect, where a fully caught-up subscription times out. The empty-log case also stays
correct: visible head 0, and `waitFor` treats a missing checkpoint row as observed 0, so
`0 >= 0` returns immediately (the existing test "Strong returns immediately on an empty
log" pins this).

### Kiroku 0.5 API survey (what is available for "newest visible position")

Locate the Kiroku sources with `mori registry show shinzui/kiroku --full` (package
`mori://shinzui/kiroku/packages/kiroku-store`; currently checked out at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, version 0.5.0.0, matching keiro's
bound `kiroku-store >=0.5 && <0.6` in `keiro/keiro.cabal`). Verified findings:

- `Kiroku.Store.Read.readAllBackward (GlobalPosition 0) 1` returns the newest visible
  event (cursor 0 maps to "after everything"; hard-deleted streams' events do not appear
  in `$all`). This is the pre-0.12 implementation. Cost: fetches the newest event's full
  row (`data`, `metadata`) and runs `decodeEvents` (the store's decode hook) on it.
- `subscriptionCheckpointInventory` returns `SubscriptionCheckpointInventory
  { storePosition :: GlobalPosition, checkpoints :: Vector SubscriptionCheckpoint }` —
  `storePosition` is the authoritative counter (reads `streams` row `stream_id = 0`,
  which `hardDeleteStream` never touches), so it is NOT usable as a visible head.
- No exported query returns the newest visible position without fetching an event row.
  There is no `headPosition`/`visibleHead`-style API in 0.5.
- The `$all` seed is a `streams` row only (`INSERT INTO streams (stream_id, stream_name,
  stream_version) VALUES (0, '$all', 0)` in `kiroku-store-migrations`
  `0001-kiroku-bootstrap.sql`); `stream_events` has no seed row, so
  `COALESCE(max(stream_version), 0)` over `stream_events WHERE stream_id = 0` is exactly
  the visible head with a correct 0 sentinel for the empty log.

### Test infrastructure this plan builds on

The `keiro` package's suite is `keiro-test` (`keiro/test/Main.hs`, declared in
`keiro/keiro.cabal`). It uses the suite-level template-database fixture from
`keiro-test-support` (`keiro-test-support/src/Keiro/Test/Postgres.hs`): `withMigratedSuite`
starts one cached ephemeral PostgreSQL server, migrates a single `keiro_template` database
once (Kiroku + Keiro migrations), and every example clones a fresh database from the
template via `around (withFreshStore fixture)` (yielding a `KirokuStore` handle) or
`withFreshResourceStore fixture` (yielding `(storeHandle, StoreRunner runner)` for
resource-bracketed APIs). No externally provisioned database or environment variables are
needed; the suite requires only the PostgreSQL binaries from the repository dev shell.
Follow this pattern — do not add per-example migrations.

Existing fixtures in `keiro/test/Main.hs` that the new tests reuse: `counterReadModel`
(~line 14130; `subscriptionName = "counter-read-model-sub"`, `strongScope = EntireLog`),
`counterAsyncProjection` (~line 14183, same subscription name),
`initializeRegisteredReadModel`, `counterInlineProjection`, `upsertSubscriptionCursorStmt`
(~line 14399; upserts a `subscriptions` row for `'$all'` — the tests' way of simulating a
subscription worker's durable checkpoint), `globalPositionToInt`, `fastWaitOptions`
(~line 14205, 50 ms), the workflow helpers `demoWorkflow` (~line 11598),
`runWorkflowWith`, `defaultWorkflowRunOptions`, and the `Keiro.Workflow.Gc` examples
(~line 11106) showing the complete run-then-GC recipe with
`WorkflowGc.WorkflowGcPolicy {retention = 0, batchSize = 10}`. The metrics tests
(~line 3713) show the in-memory OTel exporter recipe (`inMemoryMetricExporter`,
`createMeterProvider`, `Telemetry.newKeiroMetrics`, `flattenScalarPoints`).

The `keiro-ops` suite is `keiro-ops-test` (`keiro-ops/test/Main.hs`), same fixture
library; its "durable checkpoint inventory" group (~line 118) seeds five events plus
checkpoint rows (`seedCheckpointInventory`, ~line 820) and asserts exact row/JSON shapes
for both read-only commands.

### Relevant ADRs

Read during planning (local, repository-relative):

- `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md` —
  checkpoint ownership and semantics this plan must preserve: existing checkpoint rows
  always win, ordinary saves are monotonic, Keiro never writes private SQL against
  Kiroku's `subscriptions` table. This plan reads only Keiro-side heads and touches no
  checkpoint.
- `docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md` —
  the workflow instance-row ledger that makes terminal workflows GC-eligible; context for
  why hard-deleting terminal journals is routine (the GC module doc in
  `keiro/src/Keiro/Workflow/Gc.hs` describes exactly what is deleted).
- `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md` —
  constrains Milestone 3: `keiro-ops` obtains the visible head through keiro's public
  `storeHeadPosition`, not its own SQL.
- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md` —
  background for the catalog surfaces named by the parent MasterPlan; nothing here changes
  catalog identity.

Cross-repository: `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` (Kiroku's checkpoint
initialization/monotonic-save/reset decision, already cited by ADR 0031). No other
relevant ADR was found (scanned `docs/adr/` filenames and headings, 0001–0031).


## Plan of Work

The work is four milestones. Milestone 1 is the defect fix with a reproduce-first
regression test; Milestone 2 rebases the telemetry gauge; Milestone 3 extends the
operator CLI truthfully; Milestone 4 is documentation, ADR distillation, and full
verification. Milestones 1–3 are independently verifiable by their named test commands;
each leaves the tree compiling and green for everything already passing.

### Milestone 1 — Reproduce the stall, then retarget the Strong wait at the visible head

Scope: `keiro/src/Keiro/ReadModel.hs` and the `describe "Keiro.ReadModel"` group of
`keiro/test/Main.hs`. At the end of this milestone the regression scenario passes: a
caught-up model answers a `Strong` query promptly after workflow GC, a genuinely-behind
model still waits and times out with a visible-head target, and `storeHeadPosition`'s
documented meaning matches its released 0.11 contract again.

First write the regression test so the defect is captured executable. In
`keiro/test/Main.hs`, inside `describe "Keiro.ReadModel"` (after the existing test
"Strong blocks until the subscription reaches the store head captured at query start"),
add a test named `Strong returns promptly after workflow GC hard-deletes the newest
events` using `withFreshResourceStore fixture`. The body, in order: register the model
(`initializeRegisteredReadModel counterReadModel initializeCounterReadModelTable`); append
one counter event through the inline projection
(`runner $ runCommandWithProjections defaultRunCommandOptions counterEventStream
(stream "read-model-gc-strong" :: Stream CounterEventStream) (Add 5)
[counterInlineProjection]`) and capture its global position `visiblePos` from the command
result; simulate the caught-up projection worker by upserting the durable cursor
(`Tx.statement ("counter-read-model-sub", globalPositionToInt visiblePos)
upsertSubscriptionCursorStmt` — legitimate because a real worker checkpoints at delivered
batch tails, and `visiblePos` is the newest deliverable position); run a workflow to
completion exactly as the `Keiro.Workflow.Gc` tests do (`counter <- newIORef 0` then
`Store.runStoreIO storeHandle $ runWorkflowWith (defaultWorkflowRunOptions &
#snapshotPolicy .~ OnTerminal) (WorkflowName "gc-strong-wf") (WorkflowId "gsw-1")
(demoWorkflow counter)` expecting `Completed _`) so its journal events occupy the newest
global positions; collect it (`WorkflowGc.gcWorkflowsOnce (addUTCTime 1 now)
WorkflowGc.WorkflowGcPolicy {retention = 0, batchSize = 10}` expecting
`WorkflowGcSummary {scanned = 1, deleted = 1}`); prove the scenario shape by asserting
`storeHeadPosition` equals `visiblePos` while the inventory's `storePosition` is strictly
greater (add `subscriptionCheckpointInventory` to the existing
`Kiroku.Store.Subscription`-family imports; the types are already imported via
`KirokuSub`); finally time the query — capture `getCurrentTime`, run
`Store.runStoreIO storeHandle $ runQueryWith Nothing Strong counterReadModel "inline"`,
assert the result is `Right (Right 5)`, and assert the elapsed `diffUTCTime` is under
2 seconds. (The head-shape assertion is written against the FIXED semantics, so before
the fix this test fails twice over: the head assertion sees the authoritative counter,
and the query returns `Right (Left (ReadModelWaitTimeout …))` after five seconds. Both
failures are the point — run it and record the output.)

Then fix `keiro/src/Keiro/ReadModel.hs`. Replace the inventory-based `storeHeadPosition`
(~line 336) with a visible-head query executed through the store's transaction API,
mirroring `categoryHeadPosition` directly below it:

```haskell
-- | The global position of the newest visible event in the @$all@ stream, or
-- @GlobalPosition 0@ when no event is visible. This is deliberately NOT
-- Kiroku's authoritative @$all@ append counter (the inventory's
-- 'Kiroku.Store.Subscription.storePosition'), which counts hard-deleted
-- events: subscription checkpoints advance only at delivered batch tails, so
-- after tail hard-deletion (for example workflow GC) the authoritative
-- counter is unreachable until an unrelated append lands, while the visible
-- head is reachable by any caught-up subscription. Reads Kiroku's indexed
-- @stream_events@ table because Kiroku 0.5 exports no visible-head query;
-- 'finishRebuild' guards on the same statement.
storeHeadPosition :: (Store :> es) => Eff es GlobalPosition
storeHeadPosition =
  runTransaction $ Tx.statement () visibleStoreHeadPositionStmt

visibleStoreHeadPositionStmt :: Statement () GlobalPosition
visibleStoreHeadPositionStmt =
  preparable
    """
    SELECT COALESCE(max(stream_version), 0)
    FROM stream_events
    WHERE stream_id = 0
    """
    E.noParams
    (D.singleRow (GlobalPosition <$> D.column (D.nonNullable D.int8)))
```

`waitIfNeeded` needs no textual change (`EntireLog -> storeHeadPosition`). Keep the
`Kiroku.Store.Subscription` import block — `readSubscriptionPosition` and
`subscriptionPositionFromInventory` still use the inventory and are correct. Update the
module header's `Strong` bullet and the `StrongScope`/`ReadModel` Haddocks so every
mention of "store head" says *visible* store head and no longer describes the wait target
as the captured inventory cursor. Leave `keiro/src/Keiro/ReadModel/Rebuild.hs` untouched:
its private identical statement is deliberate duplication for now (the parent MasterPlan's
EP-6 owns consolidation waves; note it there if desired, do not widen this plan).

Rewrite the now-contradicted test `uses Kiroku's captured store head after a stream is
hard deleted` (~line 3166) as `returns the newest visible position after a stream is hard
deleted`: same setup (append one event to stream `read-model-captured-head`, capture its
position, hard-delete the stream), but assert `storeHeadPosition` returns
`GlobalPosition 0` (nothing visible remains in a fresh clone) AND that
`subscriptionCheckpointInventory`'s `storePosition` still equals the captured position —
one test now documents both heads and their divergence.

Add the genuine-behind guard test `Strong still times out when visible events outrun the
subscription`: register the model, append one counter event via
`runCommandWithProjections` capturing position `p`, do NOT write any cursor row, run
`runQueryWith Nothing Strong counterReadModel "inline"`, and assert exactly
`Right (Left (ReadModelWaitTimeout "counter-read-model" p (GlobalPosition 0)))`. The
asserted target `p` proves the wait now aims at the visible head; the observed
`GlobalPosition 0` documents the missing-checkpoint fallback. This test intentionally
takes the full five-second `Strong` timeout (Decision Log).

Acceptance: `cabal test keiro-test --test-options='--match "Keiro.ReadModel"'` is green,
including the new regression test that failed before the fix; the pre-existing tests
"Strong returns immediately on an empty log", "Strong returns immediately when the
subscription is already at the store head", "Strong blocks until the subscription reaches
the store head captured at query start", and the `CategoryHead` and `PositionWait` tests
pass unchanged (no deletions occur in them, so visible and authoritative heads coincide).

### Milestone 2 — Rebase the projection distance gauge on the visible head

Scope: `keiro/src/Keiro/Projection.hs` and the metrics tests in `keiro/test/Main.hs`. At
the end, `keiro.projection.global_position_distance` (and the deprecated
`keiro.projection.lag` alias) read zero on a caught-up system after GC.

In `recordProjectionGlobalPositionDistance` (~line 432), take the head from
`storeHeadPosition` instead of the inventory's captured counter — the module already
imports from `Keiro.ReadModel` (line 81, `subscriptionPositionFromInventory`), so extend
that import:

```haskell
recordProjectionGlobalPositionDistance metrics projection = do
  inventory <- subscriptionCheckpointInventory
  visibleHead <- storeHeadPosition
  let checkpoint =
        fromMaybe (GlobalPosition 0)
          $ subscriptionPositionFromInventory
            (SubscriptionName (projection ^. #subscriptionName))
            inventory
      distance = globalPositionDistance visibleHead checkpoint
  Telemetry.recordProjectionGlobalPositionDistance metrics distance
  Telemetry.recordProjectionLag metrics distance
```

This is two statements per call instead of one; the function is invoked once per drain
pass, not per event, so the cost is immaterial. Update its Haddock: the value is the
non-negative distance from the newest visible event to the slowest durable member
checkpoint — the actionable backlog — and reads zero after tail hard-deletion on a
caught-up system; the deprecated `recordProjectionLag` alias records the same value under
the historical name (leave the `DEPRECATED` pragma and alias body untouched).
`globalPositionDistance` already clamps at zero (`max 0`), which is what makes a
checkpoint above the regressed visible head read as 0, not negative.

Add a metrics test beside "records matching global position distance and projection lag
gauges" (~line 3713), named `reports zero global position distance after the newest
events are hard deleted`: same exporter/meter scaffolding; append one counter event to
stream `gauge-gc-survivor` capturing position `v`; upsert the cursor for
`"counter-read-model-sub"` to `v`; append one counter event to stream `gauge-gc-victim`;
`Store.hardDeleteStream (StreamName "gauge-gc-victim")`; call
`recordProjectionGlobalPositionDistance (Just keiroMetrics) counterAsyncProjection`;
flush and assert both `keiro.projection.global_position_distance` and
`keiro.projection.lag` are `IntNumber 0`. Before this milestone's change the recorded
value is at least 1 (authoritative head minus cursor), so the test is a true regression
guard. The existing gauge test needs no edit: it performs no deletion, so both bases give
the same number.

Acceptance: `cabal test keiro-test --test-options='--match "Keiro.ReadModel"'` green
(the metrics tests live in that describe group's file section; if `--match` filtering by
example name is easier, use `--match "global position distance"`), plus the full
`cabal test keiro-test` stays green.

### Milestone 3 — Report both heads in keiro-ops and compute distance against the visible one

Scope: `keiro-ops/src/Keiro/Ops/Projection.hs`, `keiro-ops/src/Keiro/Ops/Stream.hs`,
`keiro-ops/test/Main.hs`. At the end, both read-only inventory commands show
`store_position` (authoritative, unchanged meaning) and a new `visible_store_head`
column, and every `global_position_distance` value is computed against the visible head.

In `Keiro.Ops.Projection`: `runPosition` currently runs only
`subscriptionCheckpointInventory`; make its action also call
`Keiro.ReadModel.storeHeadPosition` (import it) and pass both to `positionResult`, whose
signature becomes `positionResult :: Text -> GlobalPosition ->
SubscriptionCheckpointInventory -> OpsResult` (visible head first, mirroring how
`captured` threads today). Add `visible_store_head` to `headers` immediately after
`store_position`, emit `"visible_store_head" .= positionInt visibleHead` in the JSON
beside `store_position`, and compute `maximumDistance` and each member row's distance
with `globalPositionDistance visibleHead …` instead of `captured`. Keep the
`store_position` column and JSON field exactly as they are. Apply the same mechanical
change to `Keiro.Ops.Stream`'s `runSubscriptions` / `subscriptionInventoryResult` /
`checkpointRow` / `checkpointJson`.

Update the `keiro-ops/test/Main.hs` "durable checkpoint inventory" expectations: the
seeded fixture appends five events and deletes nothing, so `visible_store_head` equals
`store_position` (`5`, or `0` in the empty-store example) and every distance value is
unchanged — only the added column/field appears. Then add one new example in the same
`around (withFreshStore fixture)` block, `diverges store_position from visible_store_head
after a hard delete`: seed via `seedCheckpointInventory store`, hard-delete the newest
seeded stream (`checkpoint-inventory-5`), rerun both commands, and assert
`store_position` is still `5`, `visible_store_head` is `4`, and the `orders` member
distances are now computed from 4 (member 0 at checkpoint 2 → 2; member 1 at checkpoint
3 → 1; `maximum_global_position_distance` 2). This is the operator-facing proof that the
gap between the two columns is exactly the hard-deleted tail.

Acceptance: `cabal test keiro-ops-test` green, including the new divergence example.

### Milestone 4 — Documentation, ADR distillation, full verification

Scope: `docs/user/api-reference.md`, `CHANGELOG.md`, `docs/adr/`, and the repository
verify target. In `docs/user/api-reference.md` (~lines 376–388) the `Keiro.ReadModel`
section currently says `storeHeadPosition` "uses the store cursor captured by Kiroku's
public one-statement inventory, rather than inferring the head from the newest visible
event" — invert it: `storeHeadPosition` returns the newest visible event's global
position (the only target a caught-up subscription can reach; the inventory's
authoritative counter counts hard-deleted events and is available via Kiroku's
`subscriptionCheckpointInventory`). In `CHANGELOG.md`'s Unreleased section, amend the
`**keiro**` inventory-adoption bullet (~line 74) so it claims the inventory for
member-aware checkpoint floors and operator reporting but states that consistency-wait
targets and the distance gauge use the newest visible event, and amend the
`**keiro-ops**` bullet (~line 81) to mention `visible_store_head` and the visible-basis
distance; add a bullet under the appropriate heading recording the fix itself (Strong
waits no longer stall after workflow GC hard-deletes the newest events). Since the
defective behavior never shipped in a release, these are edits to the existing Unreleased
narrative, not a separate "Fixed vs 0.11" entry — but keep the fix bullet explicit so the
0.12 release notes name it.

ADR distillation (required by this repository's ExecPlan contract before completion):
the durable lesson is "a consistency wait target must be a position the waited-on
consumer can reach; the authoritative append counter is capacity/audit data, not a wait
target, because checkpoints advance only at delivered batch tails and empty fetches never
checkpoint". Write it as a new ADR in `docs/adr/` (allocate the next free number — 0031
is the highest at planning time, but sibling plans 237/239–242 may allocate concurrently;
check `ls docs/adr` and `docs/adr/log.md` at write time), following the bundle's profile
frontmatter (copy the shape of
`docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`,
set `originatingPlan: docs/plans/238-target-strong-consistency-waits-at-the-visible-store-head.md`),
cross-referencing ADR 0028 (why keiro-ops consumes the head through the library API),
ADR 0031 and `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` (checkpoint monotonicity
and ownership), and recording the rejected alternatives from this plan's Decision Log
(authoritative-counter target; `readAllBackward` implementation; dual head exports).
Update `docs/adr/index.md`/`log.md` per the bundle convention and run `just adr-validate`.

Finally run `just verify` (which includes `just haskell-verify` = `cabal build all` plus
every test suite, and the docs validators) from the repository root, then update the
parent MasterPlan `docs/masterplans/37-...md`: tick the EP-2 Progress entry and set the
registry row's Status to Complete, and complete this plan's living sections (Progress,
Outcomes & Retrospective, any Surprises).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`, inside
the repository dev shell (direnv/nix) so `cabal`, `just`, and the PostgreSQL binaries are
on PATH. The test suites provision their own ephemeral PostgreSQL server; no `just
postgres-start` or environment variables are required for them.

Build everything once before editing, to establish a clean baseline:

```bash
cabal build all
```

Milestone 1, step 1 — add the regression test, then watch it fail against current code:

```bash
cabal test keiro-test --test-options='--match "Strong returns promptly after workflow GC"'
```

Expected failure transcript (abbreviated; the run takes ~5 s in the wait loop — the
head-shape assertion may fail first with the authoritative counter, and the query
assertion fails like this):

```text
  1) Keiro.ReadModel Strong returns promptly after workflow GC hard-deletes the newest events
       expected: Right (Right 5)
        but got: Right (Left (ReadModelWaitTimeout "counter-read-model" (GlobalPosition 8) (GlobalPosition 1)))
```

(The exact numeric positions depend on how many journal events the demo workflow appends;
what matters is target > observed with the query timing out despite the cursor sitting at
the newest visible position.) Record the actual transcript in Surprises & Discoveries if
it deviates in kind, not just in numbers.

Milestone 1, step 2 — apply the `ReadModel.hs` fix and test edits, then:

```bash
cabal build keiro
cabal test keiro-test --test-options='--match "Keiro.ReadModel"'
```

Expected: all examples in the group pass; the run includes one deliberate ~5 s example
(the genuine-behind timeout). Success looks like hspec's summary with zero failures, e.g.:

```text
Finished in 32.41 seconds
47 examples, 0 failures
```

(Example count will differ; zero failures is the acceptance.)

Milestone 2 — after the `Projection.hs` change and the new gauge test:

```bash
cabal build keiro
cabal test keiro-test --test-options='--match "global position distance"'
cabal test keiro-test
```

Expected: the zero-after-GC gauge example and the pre-existing gauge/timeout-counter
examples all pass; then the full suite passes.

Milestone 3 — after the `keiro-ops` changes and test updates:

```bash
cabal build keiro-ops
cabal test keiro-ops-test
```

Expected: zero failures, including `diverges store_position from visible_store_head
after a hard delete`.

Milestone 4 — docs, ADR, and the full gate:

```bash
just adr-validate
just verify
```

Expected: `okf validate` reports no violations for `docs/adr`; `just verify` completes
every suite and validator without failures. `just verify` also runs the jitsurei demos
against a local PostgreSQL it manages via process-compose configuration checks; if the
full target is unavailable in the current environment, run at minimum
`just haskell-verify` plus `just adr-validate` and record the substitution in Progress.


## Validation and Acceptance

The change is accepted when all of the following observable behaviors hold, each pinned
by a named test in `keiro/test/Main.hs` or `keiro-ops/test/Main.hs`:

First, the review scenario itself: with a read model registered and its subscription
cursor at the newest visible event, completing and garbage-collecting a workflow (which
hard-deletes the journal events occupying the newest global positions) leaves a `Strong`
query returning its result within ~2 seconds — not `ReadModelWaitTimeout` after 5 — while
Kiroku's authoritative inventory position remains strictly above the visible head. Test:
`Strong returns promptly after workflow GC hard-deletes the newest events`. This test
fails before Milestone 1's code change (transcript in Concrete Steps) and passes after —
run it in both states at least once.

Second, no weakening of strong consistency: with visible events beyond the model's
checkpoint (and no checkpoint row at all), a `Strong` query waits its full timeout and
fails with `ReadModelWaitTimeout` whose target equals the newest visible position and
whose observed position is `GlobalPosition 0`. Test: `Strong still times out when visible
events outrun the subscription`. The pre-existing `Strong` examples (empty log; already at
head; blocking then succeeding when the cursor advances mid-wait; `CategoryHead` scoping;
`PositionWait` success and timeout, including the wait-timeout metrics counter) must pass
unchanged.

Third, head semantics are explicit: after hard-deleting the only stream,
`storeHeadPosition` returns `GlobalPosition 0` while the inventory's `storePosition`
still reports the captured pre-deletion counter. Test: `returns the newest visible
position after a stream is hard deleted` (rewritten from the test that pinned the
defective semantics).

Fourth, telemetry is honest: with the cursor at the newest surviving event and the newer
stream hard-deleted, `recordProjectionGlobalPositionDistance` records `0` on both
`keiro.projection.global_position_distance` and the deprecated `keiro.projection.lag`
(same value by the alias contract). Test: `reports zero global position distance after
the newest events are hard deleted`. The pre-existing test proving the two gauges match
on a lagging system passes unchanged.

Fifth, the operator surface reports both truths: `keiro-ops projection position` and
`stream subscriptions` show `store_position` (authoritative) and `visible_store_head`,
with all distance values computed from the visible head; after hard-deleting the newest
seeded stream the columns diverge exactly by the deleted tail. Tests: the updated
inventory-shape examples plus `diverges store_position from visible_store_head after a
hard delete`.

Finally, the whole-repo gate `just verify` passes, and `docs/user/api-reference.md`,
`CHANGELOG.md`, and the new ADR describe the visible-head contract (ADR validated by
`just adr-validate`).


## Idempotence and Recovery

Every step is safe to repeat. The code edits are ordinary source changes with no
migration, no schema change, and no data movement; re-running any test command is
side-effect-free because each example runs in a fresh database cloned from the suite
template and dropped afterward (`keiro-test-support`'s `withMigratedSuite` fixture). If a
suite run is interrupted, simply re-run it; the ephemeral server is cache-managed by
`ephemeral-pg` and recreated as needed.

If Milestone 1's fix needs to be backed out mid-stream, reverting
`keiro/src/Keiro/ReadModel.hs` alone restores the current (defective) behavior and only
the new/rewritten tests fail — nothing else in the tree depends on the head's basis.
Milestones 2 and 3 are independent of each other and can land or be reverted separately;
each is a self-contained function-plus-tests change. The documentation and ADR edits in
Milestone 4 are additive prose.

Do not commit on a red suite; commit per milestone with Conventional Commits messages
(for example `fix(read-model): target strong waits at the visible store head`) so any
milestone can be reverted in isolation. This plan touches no files owned by sibling plans
237/239–242 except `keiro/test/Main.hs` (shared test file — merge conflicts there are
append-order only) and the shared `CHANGELOG.md`; coordinate ADR numbering with siblings
at write time as described in Milestone 4.


## Interfaces and Dependencies

No dependency bounds change. Everything uses `kiroku-store >=0.5 && <0.6` as already
declared in `keiro/keiro.cabal` and `keiro-ops/keiro-ops.cabal`; the Kiroku APIs consumed
are all public and present in 0.5.0.0 (`Kiroku.Store.Subscription.subscriptionCheckpointInventory`,
the `SubscriptionCheckpointInventory`/`SubscriptionCheckpoint` types,
`Kiroku.Store.Lifecycle.hardDeleteStream`, `Kiroku.Store.Transaction.runTransaction`).
Locate Kiroku's sources via `mori registry show shinzui/kiroku --full`
(`mori://shinzui/kiroku/packages/kiroku-store`).

At the end of Milestone 1, `keiro/src/Keiro/ReadModel.hs` exports the same names it does
today — `runQuery`, `runQueryWith`, `waitFor`, `subscriptionPositionFromInventory`,
`readSubscriptionPosition`, `storeHeadPosition`, `categoryHeadPosition`, the consistency
types, and `ReadModelError` — with exactly one changed contract:

```haskell
-- newest visible event's global position; GlobalPosition 0 when none visible
storeHeadPosition :: (Store :> es) => Eff es GlobalPosition
```

backed by the private `visibleStoreHeadPositionStmt :: Statement () GlobalPosition`
(`SELECT COALESCE(max(stream_version), 0) FROM stream_events WHERE stream_id = 0`).
`waitIfNeeded` retains its shape (`Strong`/`EntireLog` targets `storeHeadPosition`;
`Strong`/`CategoryHead` targets `categoryHeadPosition`; `Eventual` no-ops;
`PositionWait` honors its explicit target), and `waitFor`, `PositionWaitOptions`,
`defaultStrongWaitOptions` (5 s / 10 ms), and `ReadModelWaitTimeout` are unchanged.

At the end of Milestone 2, `Keiro.Projection.recordProjectionGlobalPositionDistance ::
(IOE :> es, Store :> es) => Maybe KeiroMetrics -> AsyncProjection -> Eff es ()` keeps its
signature but computes `globalPositionDistance visibleHead memberFloor`, importing
`storeHeadPosition` from `Keiro.ReadModel` (that import edge already exists for
`subscriptionPositionFromInventory`; `Keiro.ReadModel` does not import `Keiro.Projection`,
so no cycle). `recordProjectionLag` remains the deprecated alias with the same value, and
`Keiro.Telemetry`'s gauge names (`keiro.projection.global_position_distance`,
`keiro.projection.lag`) and `recordProjectionWaitTimeouts` are untouched.

At the end of Milestone 3, `keiro-ops` internals change shape (both modules are
internal-to-the-CLI surfaces, re-exported only through the command tree):
`Keiro.Ops.Projection.positionResult :: Text -> GlobalPosition ->
SubscriptionCheckpointInventory -> OpsResult` and
`Keiro.Ops.Stream.subscriptionInventoryResult :: GlobalPosition ->
SubscriptionCheckpointInventory -> OpsResult`, each taking the visible head obtained via
`Keiro.ReadModel.storeHeadPosition` in the command runner (per ADR 0028, no new SQL in
keiro-ops). Human-readable headers and JSON gain `visible_store_head`; `store_position`
and all existing field names are preserved.

Test-side, everything builds on `keiro-test-support`'s `Keiro.Test.Postgres` fixture
(`withMigratedSuite`, `withFreshStore`, `withFreshResourceStore`) — do not introduce any
other database provisioning. New test imports needed in `keiro/test/Main.hs`:
`subscriptionCheckpointInventory` (from `Kiroku.Store.Subscription`); everything else the
new tests use (`WorkflowGc`, `runWorkflowWith`, `Store.hardDeleteStream`, the counter
fixtures, the OTel in-memory exporter helpers) is already imported.


## Revision Notes

- 2026-08-11: Initial complete draft, replacing the init-script skeleton. Researched
  against the working tree at `5db45a42` and Kiroku 0.5.0.0 sources; defect mechanism,
  API survey, and test-infrastructure claims verified by reading
  `keiro/src/Keiro/ReadModel.hs`, `keiro/src/Keiro/Projection.hs`,
  `keiro/src/Keiro/Workflow/Gc.hs`, `keiro/src/Keiro/ReadModel/Rebuild.hs`,
  `keiro-ops/src/Keiro/Ops/{Projection,Stream}.hs`, both test mains, the
  `d612b770`/`f47053a7` diffs, and Kiroku's `Subscription`, `Fsm`, `Effect`, `Read`,
  `CheckpointInventory.SQL`, and bootstrap-migration sources.
