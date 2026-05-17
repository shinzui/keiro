---
id: 17
slug: adopt-keiki-multi-event-command-output
title: "Adopt keiki multi-event command output"
kind: exec-plan
created_at: 2026-05-17T13:50:18Z
intention: "intention_01krv33nbmea9tmve39wftrma5"
---

# Adopt keiki multi-event command output

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiki's current command step can emit zero, one, or many events from one accepted command. Keiro is the runtime layer that turns a Keiki transducer into the event-sourcing command cycle, so Keiro users should be able to author one transducer edge with two `emit` calls and have `runCommand` append both events in the same optimistic-concurrency batch. After this change, `runCommand`, `runCommandWithSqlEvents`, inline projections, snapshots, and process-manager dispatch continue to work, but a single command can append multiple domain events and report the correct `eventsAppended` count.

The behavior is visible by running the test suite. A new command-cycle spec will build a small Keiki transducer whose `Add` command emits two `CounterEvent` values. Calling `runCommand` against an empty stream must append two stored events in order, return `streamVersion = StreamVersion 2`, and return `eventsAppended = 2`. Calling `runCommandWithSqlEvents` against the same kind of stream must pass both decoded events to the SQL continuation.


## Progress

- [x] Confirm the local keiki package source is the multi-event implementation and update Keiro dependency bounds or package configuration only if the local package version changed. Completed 2026-05-17T14:22:48Z.
- [x] Change `src/Keiro/Command.hs` so command evaluation accepts Keiki's `[co]` output directly instead of the old zero-or-one output shape. Completed 2026-05-17T14:22:48Z.
- [x] Change hydration replay in `src/Keiro/Command.hs` to use Keiki's streaming replay path so stored multi-event command batches can be replayed event by event. Completed 2026-05-17T14:22:48Z.
- [x] Add or update `Eq co` constraints anywhere Keiro calls `Keiki.applyEvents` or `Keiki.applyEventStreaming`. Completed 2026-05-17T14:22:48Z.
- [x] Update command-cycle tests in `test/Main.hs` with a multi-event transducer and assertions for append order, `eventsAppended`, `streamVersion`, SQL event delivery, and replay of prior multi-event history. Completed 2026-05-17T14:22:48Z.
- [x] Update existing test fixtures in `test/Main.hs` from the old `Edge.output = Maybe ...` shape to the current keiki `Edge.output = [...]` shape if compilation requires it. Completed 2026-05-17T14:22:48Z.
- [x] Update user-visible docs in `README.md` and `docs/user/*.md` so they describe multi-event command output accurately. Completed 2026-05-17T14:22:48Z.
- [x] Run validation commands and record results in this plan. Completed 2026-05-17T14:22:48Z; `cabal test all` was attempted and failed in a sibling package test target unrelated to the Keiro changes, as recorded below.


## Surprises & Discoveries

- Observation: The registered local dependency `shinzui/keiki` has no separate Mori docs corpus, so the implementation details must come from the source under `/Users/shinzui/Keikaku/bokuno/keiki`.
  Evidence: `mori registry docs shinzui/keiki` printed `(none)`, while `mori registry show shinzui/keiki --full` showed the source path `/Users/shinzui/Keikaku/bokuno/keiki`.

- Observation: The current local keiki source already has the multi-event API. `Keiki.Core.step` returns `Maybe (s, RegFile rs, [co])`, `Edge.output` is a list, `omega` returns `[co]`, and `applyEvents` requires `Eq co`.
  Evidence: `/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs` documents `@[o1, o2, ...]@` output and exposes `applyEventStreaming` plus `applyEvents`.

- Observation: The Keiro command implementation is between API versions. `src/Keiro/Command.hs` already stores `[co]` in `CommandAppend` and passes `[co]` to `runCommandWithSqlEvents`, but `evaluateCommand` still pattern matches `Just (_, _, Nothing)` and `Just (_, _, Just event)`, which matches the older keiki zero-or-one event shape.
  Evidence: `src/Keiro/Command.hs` currently has `Just (_, _, Nothing) -> Right []` and `Just (_, _, Just event) -> Right [event]`.

- Observation: Propagating Keiki's streaming replay through the public command API requires callers that run command paths indirectly to carry `Eq co` constraints too.
  Evidence: The first `cabal build all` after updating `Keiro.Command` failed in `src/Keiro/Projection.hs` at `runCommandWithSqlEvents` and in `src/Keiro/ProcessManager.hs` at `runCommandWithSql` and `runCommand`, until `Eq co` and `Eq targetCo` were added to those signatures.

- Observation: The current `Codec` decoder receives only the payload after event-type validation, not the `EventType`, so two test event constructors with identical JSON payloads are ambiguous at decode time.
  Evidence: `src/Keiro/Codec.hs` defines `decode :: Value -> Either Text e`; the multi-event test fixture uses an `audited` payload flag for `CounterAudited` so `decodeRecorded counterCodec` round-trips both `CounterAdded` and `CounterAudited`.

- Observation: The repository-wide `cabal test all` target includes sibling dependency test suites and is not currently a clean Keiro-only acceptance signal.
  Evidence: After Keiro's own suite passed with 32 examples and Kiroku store passed with 129 examples, the command exited with `Error: [Cabal-7125] Failed to build test:codd-test from codd-0.1.8`; earlier output showed `ghc-9.12.2: could not execute: hspec-discover` while building the sibling `codd` test target.


## Decision Log

- Decision: Treat the local `cabal.project` sibling package `/Users/shinzui/Keikaku/bokuno/keiki` as the "latest keiki" source of truth for this repository.
  Rationale: `mori show --full` declares `shinzui/keiki` as a dependency, `mori registry show shinzui/keiki --full` points to that local source tree, and `cabal.project` already builds Keiro against that local package. There is no curated docs corpus to prefer over the dependency source.
  Date: 2026-05-17

- Decision: Hydration should use Keiki's `applyEventStreaming` rather than continuing to call letter-only `applyEvent`.
  Rationale: Stored events are read one at a time from Kiroku. A multi-event edge appends several ordinary stored events in order, so replay must preserve the "in flight" tail expectation between recorded events. `applyEventStreaming` is the keiki API designed for that situation; `applyEvents` is useful for replaying a known chunk but the Kiroku stream does not record command boundaries in Keiro's public contract.
  Date: 2026-05-17

- Decision: Add `Eq co` constraints to Keiro command-side functions rather than introducing a custom event comparison hook.
  Rationale: Keiki's streaming replay checks that later events in a multi-event edge equal the evaluated expected tail, and the upstream API expresses that requirement as `Eq co`. Most aggregate event types in Keiro tests and examples already derive `Eq`, and surfacing this as a typeclass constraint keeps Keiro aligned with keiki.
  Date: 2026-05-17

- Decision: Keep the new multi-event command tests on the existing counter fixture and make `CounterAudited` payloads explicitly distinguishable.
  Rationale: Reusing the counter fixture exercises existing command, projection, process-manager, and snapshot surfaces with minimal new scaffolding. Because `Codec.decode` does not receive the event type tag, `CounterAudited` needs a payload discriminator to avoid decoding it as `CounterAdded`.
  Date: 2026-05-17


## Outcomes & Retrospective

Implementation is complete for Keiro. `src/Keiro/Command.hs` now evaluates commands as `[co]` batches and replays hydration through `Keiki.applyEventStreaming`. `src/Keiro/Projection.hs` and `src/Keiro/ProcessManager.hs` carry the required `Eq` constraints for indirect command execution. `test/Main.hs` now covers multi-event append order, replay, SQL continuation delivery, and snapshot versioning after a two-event command. `README.md`, `docs/user/command-cycle.md`, `docs/user/getting-started.md`, and `docs/user/api-reference.md` now describe zero-or-more command output.

Validation so far:

```text
cabal build all
Build succeeded.

cabal test keiro-test
32 examples, 0 failures
Test suite keiro-test: PASS

rg -n "at most one|Just event|Just \\(_, _, Just|Keiki\\.applyEvent|one event per command|single event" docs/user README.md
No matches.

cabal test all
Keiro: 32 examples, 0 failures.
Keiki: 201 examples, 0 failures.
Kiroku store: 129 examples, 0 failures.
Final result: failed while building sibling package test:codd-test from codd-0.1.8 because ghc could not execute hspec-discover.
```


## Context and Orientation

This repository is a Haskell library named `keiro`. It composes `kiroku` for PostgreSQL-backed event storage, `keiki` for pure state-machine command decisions and event replay, and `shibuya` for subscription workers. The root `mori.dhall` declares `shinzui/keiki` as a dependency. The root `cabal.project` includes local sibling packages:

```cabal
packages:
  .
  /Users/shinzui/Keikaku/bokuno/keiki
  /Users/shinzui/Keikaku/bokuno/keiki/keiki-codec-json
  /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store
```

The relevant Keiro module is `src/Keiro/Command.hs`. Its public API includes `runCommand`, `runCommandWithSql`, and `runCommandWithSqlEvents`. These functions hydrate an aggregate by reading stored events, decode those events through `Keiro.Codec.decodeRecorded`, replay them through a Keiki transducer, run the command through the same transducer, encode any output events with `Keiro.Codec.encodeForAppend`, and append them to Kiroku with optimistic concurrency. "Optimistic concurrency" means Keiro appends with the stream version it read; if another writer wins first, Kiroku returns a version conflict and Keiro retries by reading the stream again.

A "transducer" is the pure Keiki state machine stored in `EventStream.transducer`. A command input type is named `ci` in Keiro type signatures. A domain event output type is named `co`. The keiki multi-event change means one accepted command transition now returns `[co]`: an empty list means the command was accepted but emitted no stored event, a singleton list means it emitted one event, and a longer list means it emitted several events that must be appended in declaration order.

The local keiki source under `/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs` is the dependency API to follow. In that source, `step` has this shape:

```haskell
step
  :: BoolAlg phi (RegFile rs, ci)
  => SymTransducer phi rs s ci co
  -> (s, RegFile rs)
  -> ci
  -> Maybe (s, RegFile rs, [co])
```

The same source defines `applyEvent` as letter-only replay and `applyEventStreaming` as replay that can move through a multi-event edge one stored event at a time. "Letter-only" means an edge emits at most one event. "Streaming replay" means replay consumes a normal event log one event at a time while carrying a temporary `InFlight` state if the previous stored event was the head of a longer multi-event edge.

Keiro's current `src/Keiro/Command.hs` still has old-shape logic in `evaluateCommand`:

```haskell
case Keiki.step (eventStream ^. #transducer) (state current, registers current) command of
  Nothing -> Left CommandRejected
  Just (_, _, Nothing) -> Right []
  Just (_, _, Just event) -> Right [event]
```

That must become direct use of the `[co]` returned by keiki. The same file has two hydration paths, `hydrate` and `hydrateFull`, both of which call `Keiki.applyEvent`. Those must change because `applyEvent` is documented in keiki as unsuitable for true streaming replay across length-two-or-more edges. `writeSnapshotIfNeeded` already calls `Keiki.applyEvents` with the command's produced `[co]`; after the type constraints are corrected, that remains the right way to compute the final state for snapshot policy because it receives the complete command output batch.

The relevant tests live in `test/Main.hs`. Existing command tests cover single-event append, retry, hydration failure, SQL rollback, snapshots, projections, process managers, and timers. Existing fixtures use `CounterCommand`, `CounterEvent`, `counterTransducer`, and `snapshotCounterTransducer`. Some test transducer literals still use the pre-widening `output = Just (...)` shape. If the latest local keiki is used, those literals should become `output = [pack ...]`; epsilon/no-event edges should use `output = []`.

User-visible documentation that must be updated includes `README.md`, `docs/user/api-reference.md`, `docs/user/command-cycle.md`, `docs/user/getting-started.md`, and any other `docs/user/*.md` page found by searching for old phrases such as "at most one event", `Just event`, or `Keiki.applyEvent`.


## Plan of Work

Milestone 1 updates Keiro's command implementation to match the latest keiki API. In `src/Keiro/Command.hs`, import `Keiki.Core.InFlight` constructors if needed and add `Eq co` to the constraints for `hydrate`, `hydrateFull`, `runCommand`, `runCommandWithSql`, `runCommandWithSqlEvents`, `prepareCommandPlan`, `writeSnapshotIfNeeded`, and `evaluateCommand` where the compiler requires it. Change `evaluateCommand` so `Nothing` still returns `CommandRejected`, and `Just (_, _, events)` returns `Right events`. Keep `prepareCommandPlan` responsible for turning `[]` into `CommandNoOp` and non-empty lists into `CommandAppend`.

In the same milestone, replace both hydration folds with streaming replay. The fold can carry an internal replay record containing the settled `Hydrated` fields plus `Keiki.InFlight s co`. Start from `Keiki.Settled initialState` or `Keiki.Settled snapshotState`. For each decoded recorded event, call `Keiki.applyEventStreaming transducer inFlight registers event`. On success, update registers and the replay wrapper. If the wrapper becomes `Keiki.Settled settledState`, update the exposed hydrated state, stream version, and global position from the current recorded event. If the wrapper remains `Keiki.InFlight`, keep the new registers and record the current stream version/global position internally but do not expose a settled state as command-ready. At the end of the stream, return `Right Hydrated` only if the wrapper is `Keiki.Settled`; if the wrapper is still `Keiki.InFlight`, return `Left (HydrationReplayFailed lastObservedStreamVersion)`. This makes a truncated log fail instead of running a command from a mid-edge state.

Milestone 1 is independently verifiable by running:

```bash
cabal build all
```

The build should no longer fail on keiki's `step` return shape or `Edge.output` shape. If it fails only because test fixtures still use `output = Just ...`, proceed to Milestone 2 and fix the fixtures before rerunning.

Milestone 2 adds behavior tests. In `test/Main.hs`, update every existing `Edge` literal so single-event edges use `output = [pack ...]` and no-event edges use `output = []`. Add a second counter event constructor, for example `CounterAudited !Int`, or a small separate `MultiCounterEvent` type if that keeps the existing tests simpler. Extend or add a codec that can encode and decode both event types. Add a transducer where `Add n` emits two events in order from one edge:

```haskell
output =
  [ pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)
  , pack addCtor counterAuditedCtor (inpCtor addCtor #amount *: oNil)
  ]
```

Add tests under `describe "Keiro.Command"` for at least these cases. First, `runCommand` on an empty stream appends both events, returns `eventsAppended = 2`, and the stored stream decodes to `[CounterAdded n, CounterAudited n]`. Second, running a later command on the same stream hydrates through the prior two-event command and appends the next two events at versions 3 and 4. Third, `runCommandWithSqlEvents` passes both decoded events to the continuation in order. Fourth, if snapshots are enabled for a multi-event stream, `writeSnapshotIfNeeded` sees the final settled state after the whole emitted list, not just the first event.

Milestone 2 is independently verifiable by running:

```bash
cabal test keiro-test
```

The command specs should prove that multi-event output works beyond compilation.

Milestone 3 updates user-visible documentation. In `docs/user/command-cycle.md`, change the Hydration section to say Keiro replays with Keiki's streaming replay path, not plain `Keiki.applyEvent`, because multi-event edges have an in-flight tail while replaying one stored event at a time. Change the Decision section so outcomes are `Nothing` for rejection and `Just (_, _, events)` for accepted commands, where `events` is a possibly empty list. Remove any statement that v1 appends at most one event. Explain that `eventsAppended` is the count of encoded events appended from that command. In the Inline SQL section, state that `runCommandWithSqlEvents` passes the whole produced event list in append order.

In `docs/user/getting-started.md`, update the command-cycle explanation so a command may append multiple events. In `README.md`, adjust the feature bullet if needed to mention "event batch" or "zero-or-more events" rather than implying a single event. In `docs/user/api-reference.md`, keep the exported symbol list but update the `Keiro.Command` summary if needed. Search all user docs with:

```bash
rg -n "at most one|Just event|Just \\(_, _, Just|Keiki\\.applyEvent|one event|single event" docs/user README.md
```

Update every user-facing stale statement discovered by that search.

Milestone 3 is independently verifiable by running the search above and confirming no stale command API claims remain, then running the full validation command:

```bash
cabal test all
```


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Before editing dependencies, confirm Mori still points at the same local packages:

```bash
mori show --full
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
```

Expected facts are that `mori show --full` lists `shinzui/keiki` under dependencies, `mori registry show shinzui/keiki --full` shows `/Users/shinzui/Keikaku/bokuno/keiki`, and `mori registry docs shinzui/keiki` may print `(none)`.

Inspect the upstream API before changing Keiro:

```bash
sed -n '620,840p' /Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs
```

Expected facts are that `step` returns `Maybe (s, RegFile rs, [co])`, `applyEventStreaming` requires `Eq co`, and `applyEvents` folds `applyEventStreaming`.

Edit `src/Keiro/Command.hs`. Replace the old `evaluateCommand` cases with direct list handling:

```haskell
evaluateCommand eventStream current command =
  case Keiki.step (eventStream ^. #transducer) (state current, registers current) command of
    Nothing -> Left CommandRejected
    Just (_, _, events) -> Right events
```

Then update hydration in the same file to use `Keiki.applyEventStreaming` as described in Milestone 1. Do not use `/nix/store` for any lookup or search.

Update tests in `test/Main.hs`, then run:

```bash
cabal build all
cabal test keiro-test
```

Expected successful output is similar to:

```text
Build profile: -w ghc-9.12...
...
Test suite keiro-test: PASS
```

Update docs, then run:

```bash
rg -n "at most one|Just event|Just \\(_, _, Just|Keiki\\.applyEvent|one event per command" docs/user README.md
cabal test all
```

The search should return no stale user-facing statements about the old command API. `cabal test all` should finish with all Keiro tests passing.

After each implementation stopping point, update this plan's Progress section. If committing during implementation, use Conventional Commits and include both trailers:

```text
ExecPlan: docs/plans/17-adopt-keiki-multi-event-command-output.md
Intention: intention_01krv33nbmea9tmve39wftrma5
```


## Validation and Acceptance

Acceptance requires observable behavior, not just typechecking. The implementation is accepted when a test constructs an `EventStream` whose Keiki transducer emits two domain events from one command edge, then `runCommand defaultRunCommandOptions eventStream target (Add 5)` returns a successful `CommandResult` with `streamVersion = StreamVersion 2` and `eventsAppended = 2`. Reading the target Kiroku stream must decode to the exact ordered list produced by the transducer.

Replay acceptance requires a second command on the same target stream. After the first multi-event command is stored, a second `runCommand` must hydrate through both prior recorded events without `HydrationReplayFailed`, append the second command's two events, and return `streamVersion = StreamVersion 4`.

SQL continuation acceptance requires `runCommandWithSqlEvents` to pass the full produced event list to its continuation in append order. A test can write the received list into an `IORef` from inside the continuation or project both events into a test table. The assertion must prove that both events were observed, not only the first one.

Snapshot acceptance requires a multi-event command with a snapshot policy to evaluate snapshot state after the whole emitted list. If the snapshot counter stores the last amount in a register, a command `Add 9` that emits two events must leave the snapshot state/registers corresponding to the complete command, and later hydration from that snapshot must still accept a next valid command.

Documentation acceptance requires no user-facing stale claim that Keiro appends at most one event per command. The command-cycle docs must explain that a command produces a list of events, `eventsAppended` is the length of that list after encoding, and `runCommandWithSqlEvents` receives the list in append order.


## Idempotence and Recovery

The code edits are ordinary source changes and can be retried safely. Running `cabal build all`, `cabal test keiro-test`, `cabal test all`, and `rg` searches is safe and repeatable. The tests use ephemeral PostgreSQL through `ephemeral-pg`, so they should not mutate a developer's persistent database. If a test run leaves local database files from the development shell, remove only files known to be generated by the test tooling or development shell after inspecting them; do not run destructive cleanup commands blindly.

If hydration streaming replay is implemented incorrectly and tests start failing with `HydrationReplayFailed`, inspect the failure stream's decoded events and the transducer edge output order. A failure after the first event of a multi-event edge usually means the replay code discarded `Keiki.InFlight` between recorded events. A failure at end of stream means the stored log ended mid-edge; that should remain an error because Keiro cannot safely run the next command from an unsettled state.

There are existing unrelated working-tree changes at plan creation time: `docs/plans/9-integrate-keiki-codec-json-into-keiro-snapshot-path.md` is modified and `docs/plans/16-adopt-codd-for-database-migrations.md` is untracked. Do not revert, overwrite, or commit them as part of this plan unless the user explicitly asks.


## Interfaces and Dependencies

Use Mori before guessing at dependency APIs. The dependency lookup commands for this plan are:

```bash
mori show --full
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
```

The dependency source of truth is `/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs`. Do not search or read `/nix/store`.

At the end of this plan, `src/Keiro/Command.hs` must expose the same public function names as before:

```haskell
runCommand
runCommandWithSql
runCommandWithSqlEvents
```

Their result types should remain source-compatible: `runCommand` returns `Either CommandError (CommandResult target)` and `runCommandWithSqlEvents` returns `Either CommandError (CommandResult target, Maybe a)`. The likely source-visible change is an added `Eq co` constraint on these functions and downstream helpers such as `Keiro.Projection.runCommandWithProjections` and `Keiro.ProcessManager.runProcessManagerOnce` if the compiler requires it. This is acceptable because keiki itself requires `Eq co` for streaming replay through multi-event edges.

`CommandResult.eventsAppended` remains an `Int`, but its meaning is now explicitly "the number of encoded events appended by this command", which may be greater than one.

`RunCommandOptions.eventIds` remains `[EventId]`. Its multi-event behavior should remain prefix assignment: if the caller supplies two ids and the command emits two events, both stored events use those ids in order; if fewer ids are supplied than emitted events, remaining events use store-generated ids. Existing `assignEventIds` already implements this behavior and should be covered by a multi-event test.

`Keiro.Projection.runCommandWithProjections` already traverses all produced events passed by `runCommandWithSqlEvents`; after this plan, that list can have length greater than one and every inline projection must run for every event.

`Keiro.ProcessManager.deterministicCommandId` currently computes one event id per dispatched command. If a target command can emit multiple events, only the first event receives the deterministic id unless future work expands `ProcessManagerAction` to provide an id list per command. This plan should document the behavior but does not need to redesign process-manager id allocation unless tests reveal duplicate handling is broken.
