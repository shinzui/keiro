---
id: 1
slug: command-cycle-design-and-spike
title: "Command Cycle Design and Spike"
kind: exec-plan
created_at: 2026-05-04T20:12:06Z
intention: "intention_01kqt8d9t8ehb84kgs19qa1rs9"
master_plan: "docs/masterplans/1-keiro-research-foundation.md"
---

# Command Cycle Design and Spike

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan resolves two interlocking design questions that, together, are the single most important research surface in 経路 (keiro):

1. **What is the proper contract between keiro and keiki?** Concretely, what type does an aggregate-or-workflow author hand to keiro so that keiro can hydrate, decide, and append on their behalf? `Keiki.Decider` is *not* the answer — it is a legacy compatibility facade in keiki. The richer native primitive is `Keiki.Core.SymTransducer phi rs s ci co` with its register file `RegFile rs`, ε-edges, and (eventually) symbolic predicates `phi`. The contract must be derived from first principles, must support both event sourcing and workflows, and must not amputate the workflow-supporting features keiki already provides.
2. **How does that contract execute the load → fold → decide → append cycle on top of kiroku, atomically enough to be safe under concurrent writers?**

After this plan is complete, anyone with the keiro source tree can:

1. read a written design document at `docs/research/06-command-cycle-design.md` that derives the keiro ⇄ keiki contract from first principles, fixes the public types, error model, retry policy, transactional-step combinator, and multi-stream command shape;
2. run a small Haskell program (the *spike*) that:
   - starts an ephemeral Postgres database with the kiroku schema applied,
   - defines a one-aggregate domain (e.g. a `Counter` with `Increment` and `Decrement` commands) directly as a `SymTransducer`,
   - submits a sequence of commands through a `runCommand` function,
   - observes the events appended to kiroku in correct order,
   - survives a synthetic concurrent-write conflict by retrying transparently.

The spike is the empirical proof that the contract is implementable on top of kiroku's and keiki's existing primitives. The design doc fixes the contract for every other ExecPlan in this MasterPlan to refer back to.

The user-visible outcome of the eventual library implementation (which this plan does *not* deliver) is the ability for an aggregate author to assemble a `SymTransducer`-based aggregate, hand it to keiro along with a codec and a snapshot policy, and call something like:

    runCommand :: EventStream a -> AggregateId a -> Command a -> Eff es (Either CommandError [Event a])

…where `EventStream a` is the keiro-native bundle (the `SymTransducer`, codecs, policies — final exact shape derived in this plan) and `Event a` is the typed event sum. The spike validates that the necessary primitives exist; the design doc fixes the contract precisely.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here, even if it requires splitting a partially completed task into two ("done" vs. "remaining"). This section must always reflect the actual current state of the work.

- [x] M0.1 — 2026-05-05: First-principles contract derivation captured in the Decision Log (entry "M0.1 contract derivation"). Each of the seven requirements (event sourcing, workflow control transitions, workflow internal/ε transitions, snapshots, codecs, idempotency, composition) is mapped to the keiki primitive that satisfies it. The resulting `EventStream phi rs s ci co` record is fixed for the spike (M1) and will be elaborated in M2's design doc.
- [x] M0.2 — 2026-05-05: Sanity-check vs EP-2/EP-3/EP-4/EP-5 captured in the Decision Log (entry "M0.2 cross-plan sanity check"). Contract leaves room for EP-2's `Codec co` (replaces the spike's bare encode/decode pair), EP-3's process-manager wrapping (`runCommand` is the inner write path), EP-4's `StateCodec (s, RegFile rs)` and `SnapshotPolicy` (slots in the record left as TODO in the spike), and EP-5's workflow roadmap (the contract preserves `RegFile rs` and ε-edges, so v2 durable execution can layer named-step memoisation on top without changing the public contract).
- [x] M1.1 — 2026-05-05: Bootstrapped `spikes/command-cycle/` cabal package. Files: `spike.cabal`, `cabal.project` (with-compiler ghc-9.12.3 + optional-packages pointing at local kiroku-store, keiki, ephemeral-pg, hasql-notifications). Build env: `nix develop /Users/shinzui/Keikaku/bokuno/keiki` for GHC + cabal, with PATH-prepended Postgres 18 from kiroku's nix shell (kiroku schema requires PG 18+ for `uuidv7()`). Recorded as a Surprise.
- [x] M1.2 — 2026-05-05: Defined `Counter` aggregate as `SymTransducer (HsPred CounterRegs CounterCmd) CounterRegs CounterVertex CounterCmd CounterEvent` via the `Keiki.Builder` DSL in `src/Spike/Counter.hs`. Slots `'[("counter", Int), ("cooldownUntil", UTCTime)]`; vertices `Idle | Cooldown`; commands `Increment | Decrement | Tick (TickData {now})`; events `Incremented | Decremented | CooldownEnded`. Initial register file hand-built with `RCons` (counter=0, cooldownUntil=epoch sentinel) because `emptyRegFile` would crash on read of `#counter` before its first write.
- [x] M1.3 — 2026-05-05: Implemented `runCommand` in `src/Spike/Command.hs`. The hydration phase is a Streamly `Stream (Eff es) RecordedEvent` produced by paginating `readStreamForward` inside `Stream.unfoldrM`, flattened with `Stream.concatMap (Stream.fromList . V.toList)`, and consumed by `Fold.foldlM' replayStep initial` accumulating `(s, RegFile rs, StreamVersion)`. Decide phase calls `step` with three branches; append phase chooses `NoStream | ExactVersion v` based on the threaded `StreamVersion`.
- [x] M1.4 — 2026-05-05: Implemented `runCommandRetry` in `src/Spike/Retry.hs`. Catches `WrongExpectedVersion` from kiroku and re-runs the cycle up to `maxRetries` times with `sleepMicros` backoff. `DuplicateEvent` is treated as success; other `StoreError` variants escalate. Surfaces a `RetryError` once retries are exhausted.
- [x] M1.5 — 2026-05-05: Standalone driver in `app/Main.hs` boots `Pg.with` + `withStore` (which auto-applies kiroku's schema), submits `[Increment, Increment, Decrement, Tick(early), Tick(late), Increment]`, asserts the early Tick is rejected by the cooldown guard, and reads the stream back to verify the final event sequence is `[Incremented, Incremented, Decremented, CooldownEnded, Incremented]`. Acceptance log line: `[spike] appended 5 events to counter-42: Incremented, Incremented, Decremented, CooldownEnded, Incremented`.
- [x] M1.6 — 2026-05-05: Contention scenario in `app/Main.hs::scenario2` runs two `Async`-spawned threads each issuing 10 increments through `runCommandRetry`. Observed 17 retries across 20 commands (heavy contention exercising the retry loop), final counter delta computed from the event log = 22 = 2 (scenario 1 baseline) + 2*10 (scenario 2 increments). Acceptance log: `contention test: 20 commands across 2 threads, observed 17 retries; final counter (computed from event log): 22`.
- [x] M1.7 — 2026-05-05: The Counter's `Tick` edge in `Cooldown` carries a register-file-driven guard: `requireGuard (PEq (TApp2 cooldownExpired d.now #cooldownUntil) (TLit True))`. The transition fires only when the supplied `now` has reached/passed the slot's `cooldownUntil`, demonstrating that keiki's workflow primitives (a transition predicated on register-file state, not on input alone) flow through the chosen contract unchanged. The spike emits a synthetic `CooldownEnded` event for replay determinism (per the M2 outline's preliminary recommendation against true ε-edges with no observable output); replay fidelity verified by scenario 1's hydration succeeding through the full event sequence.
- [x] M2.1 — 2026-05-05: Wrote `docs/research/06-command-cycle-design.md`. 16 sections covering: problem statement; first-principles contract derivation; aggregate identity (`AggregateId a`); public API surface (`runCommand`, `runCommandRetry`, `tick`, `runCommandMulti`, `runCommandWithSql`); the hydration pipeline (Streamly `Stream` + `Fold` with `Stream.unfoldrM` paginating `readStreamForward`); decide phase semantics; tick / silent-advance entry-point; append phase (`NoStream` vs `ExactVersion`); retry policy (`WrongExpectedVersion` handling, `DuplicateEvent` as success); transactional-step combinator (with explicit upstream gap on kiroku-store); multi-stream commands; observability fields on `EventData.metadata`; test plan (spike transcript as v1 acceptance); open questions / upstream gaps for EP-6. The aggregate-author invariant about `solveOutput` only inverting direct field projections is documented in §5 with EP-2 / keiki-side gap forwarding.
- [x] M2.2 — 2026-05-05: Cross-referenced from `docs/research/00-overview.md` (one-line entry under the Document Index).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during implementation. Provide concise evidence.

- 2026-05-05: keiki's `solveOutput` only inverts the *direct* term shapes — `TLit`, `TReg`, and `TInpCtorField` matching the enclosing `InCtor`. Computed terms (`TApp1`, `TApp2`) cause `solveOutput` to return `Nothing`, which makes `applyEvent` return `Nothing` on replay, which the spike surfaces as a `ReplayError`. First-pass spike encoded `newValue = counter + 1` in `IncrementedData` (a `TApp1`) and `cooldownUntil = at + cooldownDuration` in `DecrementedData` (also `TApp1`); both crashed replay on the second command. Fix: restrict event payloads to direct projections of input fields and let the edge's `update` carry the state delta. This is a real *invariant* every aggregate author must respect — events name the input that caused them, not the resulting state. EP-2 (codec design) and the EP-1 design doc must call it out; EP-6 should record an upstream request to make the constraint a compile-time error rather than a runtime `Nothing`.
- 2026-05-05: Kiroku's `schema.sql` uses Postgres 18's `uuidv7()` (line 27 of the embedded SQL). User's outer nix profile has Postgres 17 only; kiroku's flake explicitly pins `pkgs.postgresql_18`. Running the spike requires either (a) `nix develop /path/to/kiroku-project/kiroku` (which exposes PG 18 + GHC 9.12.2), or (b) PATH-prepending kiroku's PG 18 binaries while inside keiki's GHC 9.12.3 dev shell — this is what the spike is built and tested under. EP-6 may want to record "kiroku schema requires PG 18+" as a deployment prerequisite.
- 2026-05-05: Effectful's effect-stack ordering for `runStorePool` is non-obvious. `runStorePool :: (IOE :> es, Error StoreError :> es) => KirokuStore -> Eff (Store : es) a -> Eff es a` peels `Store` off the head but *requires* `Error StoreError` in the remaining stack to throw. So in the spike's runner-composition the `Error StoreError` handler must be applied *after* (closer to `runEff` than) `runStorePool`. The first spike attempt put `Error StoreError` right above `Store` in the type alias and peeled it before `runStorePool`, producing `[GHC-64725] There is no handler for 'Error StoreError'`. Worth documenting in EP-1's M2 design doc and prominently in any cookbook. Concrete shape that worked: `runEff . runErrorNoCallStack @StoreError . runStorePool store . runErrorNoCallStack @CommandError . runErrorNoCallStack @RetryError` over a stack `'[Error RetryError, Error CommandError, Store, Error StoreError, IOE]`.
- 2026-05-05: The contention test produced 17 retries across 20 commands — under naive optimistic concurrency two threads racing on the same aggregate retry *very* often. With the spike's `defaultRetryConfig` (maxRetries=16, sleepMicros=250) all 20 commands succeeded, but a tighter retry budget would have exhausted. Production keiro should ship jittered exponential backoff (the spike's fixed 250µs is a placeholder) and clearer surfacing of contention-rate metrics so operators can spot hot streams. M2 design doc records this as the preliminary retry policy.


## Decision Log

Record every decision made while working on the plan.

- Decision: Build a Haskell spike under `spikes/command-cycle/` rather than only writing prose.
  Rationale: The cycle's correctness under concurrent writers is the hardest research question; a 200-line working program retires that risk far better than any document. The spike directory is named so it cannot be confused with production keiro modules.
  Date: 2026-05-04.

- Decision: Use `ephemeral-pg` (registered as `shinzui/ephemeral-pg` per `mori registry list`) to spin up a Postgres instance for the spike.
  Rationale: The team already uses it; it avoids any production database setup and gives the spike a fresh schema every run.
  Date: 2026-05-04.

- Decision: The spike uses `Aeson` directly (not the typed-codec layer being designed in EP-2).
  Rationale: EP-2 has a hard dependency on this plan and cannot be implemented before EP-1's types are settled. Using Aeson directly here keeps the spike self-contained while EP-2 designs the production codec layer.
  Date: 2026-05-04.

- Decision: Reject `Keiki.Decider` as the keiro ⇄ keiki contract and derive the contract from first principles, anchored on `Keiki.Core.SymTransducer`.
  Rationale: User clarified that `Decider` is a legacy compatibility facade in keiki. The native `SymTransducer phi rs s ci co` carries strictly more information: a typed register file `RegFile rs` (which can hold timers, retry counters, correlation context, child-workflow handles), ε-edges (silent transitions used by workflow steps), and a symbolic predicate carrier `phi` (which the v2 SBV/z3 layer uses for verification). Any contract that strips these features would amputate keiki's workflow capability. Adding milestone M0 ("First-principles contract derivation") to make this explicit.
  Date: 2026-05-04.

- Decision: The spike must demonstrate at least one workflow-flavoured feature (e.g. an ε-edge advancing state silently when a register-file timer expires) — added as M1.7.
  Rationale: A spike that only exercises the Decider-shaped subset of `SymTransducer` would not actually validate the chosen contract for the workflow case. Forcing the spike to use a register-file slot and an ε-edge keeps the contract honest.
  Date: 2026-05-04.

- Decision: Express the hydration phase of `runCommand` as a Streamly `Stream (Eff es) RecordedEvent` consumed by a `Fold (Eff es) RecordedEvent (s, RegFile rs)` rather than as a `Vector`-of-events held in memory and folded with a plain Haskell `foldM`.
  Rationale: The MasterPlan's "Streamly substrate" Integration Point (`docs/masterplans/1-keiro-research-foundation.md`) makes Streamly the canonical streaming substrate. Shibuya adapters (`Stream (Eff es) (Ingested es msg)`) and kiroku-store's `Subscription/Stream.hs` (`Stream IO RecordedEvent`) already hand back streams; expressing hydration in the same primitives gives constant-memory replay for arbitrarily long streams (which keiro will see for long-lived workflows and process-manager state streams), composes directly with EP-4's snapshot-tail read (which shifts the stream's start version), and avoids introducing a parallel streaming abstraction. The spike (M1) and design doc (M2) must both reflect this — `runCommand`'s hydration step is built around `Stream.fold` over a kiroku-sourced `Stream`, with the fold's accumulator being keiki's joint state `(s, RegFile rs)`.
  Date: 2026-05-04.

- Decision: M0.1 contract derivation. The keiro ⇄ keiki contract is the record `EventStream phi rs s ci co` carrying the native `SymTransducer phi rs s ci co` plus the wire-side companions an event-store-backed runtime needs. For the M1 spike (which has no codec layer because EP-2 is downstream), the record collapses to `{ esTransducer, esEncode :: co -> Aeson.Value, esDecode :: Aeson.Value -> Either String co, esEventTag :: co -> Text }`. The full record sketched for M2 is `{ esTransducer, esEventCodec :: Codec co, esStateCodec :: StateCodec (s, RegFile rs), esEventTag :: co -> Text, esSnapshotPolicy :: SnapshotPolicy (s, RegFile rs) }`. Each requirement maps to a keiki primitive: (1) event-sourcing replay → `applyEvents`/`reconstitute` over `(s, RegFile rs)`, not `s` alone; (2) command-driven control transition → `step` (returning `Maybe (s, RegFile rs, Maybe co)`, never `[e]`); (3) silent ε-transitions → `delta` invoked without a `ci` argument or with a synthetic "tick" command, exposed as a separate `tick` entry-point; (4) snapshots → consume `(s, RegFile rs)` directly, requiring a state codec that traverses the heterogeneous `RegFile rs`; (5) typed event codec → application supplies a `Codec co` (EP-2 owns its shape); (6) idempotent commands → keiro-level wrapper carrying `CommandId`, independent of the transducer; (7) composition → process managers and sagas (EP-3, EP-5) compose `SymTransducer`s via `Keiki.Composition.compose`/`alternative`/`feedback1`, so the contract must keep `esTransducer` accessible rather than burying it.
  Rationale: This derivation is what makes `Keiki.Decider` insufficient. `Decider`'s `decide :: c -> s -> [e]` masks `omega`'s `Maybe co` as `[] | [e]` and is invisible to ε-edges (see `docs/research/02-keiki-decide-loop.md`); its `evolve :: s -> e -> s` ignores the register file. Keiro must address `(s, RegFile rs)` jointly to support workflow primitives (timers, retry counters, child-workflow handles), so the contract surfaces `SymTransducer` natively. Forwarding to keiki's `Keiki.Composition` keeps EP-3 and EP-5 unblocked.
  Date: 2026-05-05.

- Decision: M0.2 cross-plan sanity check. The contract from M0.1 leaves the four follow-on plans unblocked: (a) EP-2 supplies `Codec co` and (later) `StateCodec (s, RegFile rs)`; the spike's bare encode/decode pair is the placeholder. (b) EP-3's process managers each carry their own `EventStream` instance and call `runCommand` for their write path; the contract's typed `esTransducer` is exactly what `Keiki.Composition.compose` consumes. (c) EP-4's snapshot path replaces the initial `readStreamForward` with a snapshot read of `(s, RegFile rs)` followed by tail replay from `snapshot.version + 1`; the contract's `esStateCodec` is the seam. (d) EP-5's workflow roadmap layers durable-execution semantics (named-step memoisation, awakeables) on top of `RegFile rs` slots; because the contract surfaces `RegFile rs` directly rather than burying it inside `Decider`'s opaque `s`, v2 can extend without breaking v1 callers.
  Rationale: M0.2 is the "do not paint into a corner" check before committing time to M1's spike. All four follow-on plans require access to either `(s, RegFile rs)` jointly or to the underlying `SymTransducer`; both are exposed by `EventStream phi rs s ci co`.
  Date: 2026-05-05.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the result against the original purpose.

**Outcome (2026-05-05).** EP-1 delivered everything its purpose statement promised:

1. A working Haskell spike at `spikes/command-cycle/` that exercises the load → fold → decide → append cycle end-to-end against a real Postgres database started by `ephemeral-pg`. The spike uses the contract derived from first principles (the `EventStream phi rs s ci co` record over keiki's native `SymTransducer`, *not* the `Decider` facade), demonstrates an optimistic-retry loop under deliberate concurrent contention (17 retries observed across 20 commands; all 20 committed), and demonstrates a workflow-flavoured register-file-driven guard (the cooldown transition).
2. A self-contained design document at `docs/research/06-command-cycle-design.md` that fixes the contract, the public API, the error model, retry semantics, the transactional-step combinator, multi-stream commands, observability fields, and the upstream gaps every other child plan needs to know about.

**Gaps and lessons.**

- **The keiki `solveOutput` invariant** (event payloads must be direct projections of input fields, no `TApp1`/`TApp2`) was invisible in the keiki documentation and only surfaced when the spike's first run crashed at the second command. Forwarded to EP-2 (so its codec design calls it out) and to EP-6 (so keiki may consider lifting it to a compile-time error).
- **The Postgres-version requirement** (kiroku schema needs PG 18+ for `uuidv7()`) is currently undocumented. Forwarded to EP-6.
- **The transactional-step primitive** depends on a kiroku-store upstream feature that does not exist today (single-stream `appendToStream` does not open a Haskell-layer transaction). The spike does not implement `runCommandWithSql`; it is unblocked by the upstream addition. EP-3 picks it up.
- **Effectful's effect-stack ordering** for `runStorePool` plus `Error StoreError` is non-obvious; the spike's first runner-composition put the error handler too early in the pipeline. The design doc's §4 records the working order. Worth a cookbook entry in any keiro author guide.

**Comparison against the original purpose.** EP-1's purpose was to take keiro from "scaffold" to "ready for EP-2/EP-3/EP-4/EP-5/EP-6 to build on top of". The contract is fixed, the cycle is proved implementable, and every downstream plan has either an explicit signature to consume (`runCommand`, `EventStream`, `AggregateId a`) or an explicit upstream-gap callout to track. EP-2 (codecs), EP-3 (subscriptions/process managers), and EP-4 (snapshots) are now unblocked. EP-5 and EP-6 can also proceed in parallel, with EP-6's backlog already seeded with five concrete items from §14 of the design doc.


## Context and Orientation

Repository layout. The keiro working tree is at `/Users/shinzui/Keikaku/bokuno/keiro`. It currently contains only `agents/skills/` (the seihou skill scaffolding), `docs/research/`, `docs/masterplans/`, and `docs/plans/`. There is no Haskell source yet; this plan creates the first Haskell package in the repository.

Sister projects on the same machine, registered in `mori`:

- `kiroku` (the event store) — `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Public surface is the `Store` effect (`Kiroku.Store.Effect`), the read API (`Kiroku.Store.Read`), the append API (`Kiroku.Store.Append`), and the type module (`Kiroku.Store.Types`). For full details see `docs/research/01-kiroku-read-side.md` in this repo.
- `keiki` (the pure decider/evolve core) — `/Users/shinzui/Keikaku/bokuno/keiki`. Public surface is `Keiki.Decider` (the `Decider c e s` record facade with `decide`, `evolve`, `initialState`, `isTerminal`) and `Keiki.Core` (the underlying `SymTransducer` formalism with `delta`, `omega`, `applyEvent`, `reconstitute`). For full details see `docs/research/02-keiki-decide-loop.md`.
- `ephemeral-pg` — `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`. Spins up a temporary Postgres for tests.

Term definitions (define each before using it):

- *Stream* — kiroku's per-aggregate ordered list of events, identified by a `StreamName` (text such as `"counter-42"`). The category prefix (here, `"counter"`) is auto-derived from the substring before the first `-`.
- *Stream version* — `Kiroku.Store.Types.StreamVersion`, a 64-bit integer that increments by one per appended event. A new stream has version 0 before any append; after one append it has version 1.
- *Expected version* — the optimistic-concurrency control input on append. `Kiroku.Store.Types.ExpectedVersion` has constructors `NoStream` (must not exist), `StreamExists` (must exist), `ExactVersion v` (must equal `v`), `AnyVersion` (no precondition). Mismatches raise `Kiroku.Store.Error.WrongExpectedVersion`.
- *SymTransducer* — keiki's native primitive, defined in `Keiki.Core` as `data SymTransducer phi rs s ci co = SymTransducer { edgesOut :: s -> [Edge phi rs ci co s], initial :: s, initialRegs :: RegFile rs, isFinal :: s -> Bool }`. The five type parameters: `phi` is the predicate carrier (Haskell functions in v1, SBV/z3 in v2), `rs` is the typed register-file slot list (a heterogeneous tuple of `(Symbol, Type)`), `s` is the control vertex type (typically a user-defined sum), `ci` is the command/input alphabet, `co` is the event/output alphabet. It is pure; it cannot perform IO.
- *Register file* — `RegFile rs` is keiki's typed heterogeneous tuple of named slots that travel alongside the control state `s`. Slots can store timers, retry counters, correlation IDs, child-workflow handles, accumulated subtotals — anything an ordinary algebraic state field would, with the difference that slots are addressed by name and updated by edges. **This is the feature that lets `SymTransducer` represent workflows, not just deciders.**
- *ε-edge* — an edge whose `output` is `Nothing`. It advances `(s, RegFile rs)` silently with no observable event. Useful for workflow steps that progress when a precondition (timer expired, register populated) becomes true. Replay (`applyEvent`) does not see ε-edges; only forward stepping (`delta`) does.
- *`step`* — the canonical forward operation: `step :: SymTransducer phi rs s ci co -> (s, RegFile rs) -> ci -> Maybe (s, RegFile rs, Maybe co)`. Given current state and a command, produces the new state and (at most one) emitted event, or `Nothing` if no edge fires.
- *`applyEvent`* / *`applyEvents`* / *`reconstitute`* — replay operations. Given a recorded event `co`, `applyEvent` reverses through the matching edge to update `(s, RegFile rs)` (using `solveOutput` and the edge's update). `applyEvents` folds. `reconstitute :: [co] -> Maybe (s, RegFile rs)` is the convenience wrapper from `(initial t, initialRegs t)`.
- *`Decider`* — `Keiki.Decider.Decider c e s` exposes `decide :: c -> s -> [e]`, `evolve :: s -> e -> s`, `initialState :: s`, `isTerminal :: s -> Bool`. It is a legacy compatibility facade: `decide` masks `omega`'s `Maybe co` as `[] | [e]` and is invisible to ε-edges. **Keiro does not use this facade.** It is mentioned here only so a reader who has read keiki's documentation knows why we are not using it.
- *Hydration* — the operation of loading all events for an aggregate's stream from kiroku, decoding them, and folding them through `applyEvents` to recover `(s, RegFile rs)`.
- *Optimistic-retry loop* — when an append fails with `WrongExpectedVersion`, drop the in-memory state, re-hydrate, re-step, re-append. Bounded by a retry count.
- *Spike* — a self-contained Haskell program kept under `spikes/command-cycle/` that exists only to validate this plan's design. It is **not** the keiro library; it is throwaway code.

What does *not* exist today (verified in `docs/research/04-kiroku-keiki-integration.md`):

- No module that connects kiroku's read/append API to keiki's decide/evolve.
- No `runCommand` of any shape.
- No optimistic-retry combinator.
- No transactional read-then-append for a single stream (kiroku's `Store.Effect` only opens a Haskell-layer transaction inside `appendMultiStream`).
- No idempotent-command primitive (although kiroku's `EventData.eventId` field allows caller-supplied UUIDs, surfacing duplicate appends as `Kiroku.Store.Error.DuplicateEvent`).

The relevant pre-existing kiroku function signatures (full text in `docs/research/01-kiroku-read-side.md`):

    appendToStream :: (HasCallStack, Store :> es) =>
        StreamName -> ExpectedVersion -> [EventData] -> Eff es AppendResult

    readStreamForward :: (Store :> es) =>
        StreamName -> StreamVersion -> Int32 -> Eff es (Vector RecordedEvent)

    getStream :: (Store :> es) =>
        StreamName -> Eff es (Maybe StreamInfo)

    runStorePool :: (IOE :> es, Error StoreError :> es) =>
        KirokuStore -> Eff (Store : es) a -> Eff es a

`RecordedEvent` carries `payload :: Aeson.Value`, `eventType :: Text`, `streamVersion :: StreamVersion`, `globalPosition :: GlobalPosition`, and metadata fields. `EventData` (the append-side counterpart) carries `eventId :: Maybe EventId`, `eventType :: Text`, `payload :: Aeson.Value`, `metadata :: Maybe Aeson.Value`, plus optional correlation/causation IDs.

Keiki's relevant native function signatures (from `Keiki.Core`; full module reference in `docs/research/02-keiki-decide-loop.md`):

    data SymTransducer phi rs s ci co = SymTransducer
      { edgesOut    :: s -> [Edge phi rs ci co s]
      , initial     :: s
      , initialRegs :: RegFile rs
      , isFinal     :: s -> Bool
      }

    -- forward (handle a command):
    step    :: BoolAlg phi (RegFile rs, ci)
            => SymTransducer phi rs s ci co
            -> (s, RegFile rs) -> ci
            -> Maybe (s, RegFile rs, Maybe co)

    delta   :: ... -> s -> RegFile rs -> ci -> Maybe (s, RegFile rs)
    omega   :: ... -> s -> RegFile rs -> ci -> Maybe co

    -- backward (replay a recorded event):
    applyEvent  :: ... -> s -> RegFile rs -> co -> Maybe (s, RegFile rs)
    applyEvents :: ... -> (s, RegFile rs) -> [co] -> Maybe (s, RegFile rs)
    reconstitute :: ... -> [co] -> Maybe (s, RegFile rs)

These are the contract surface this plan derives from. The `Keiki.Decider` facade (`Decider c e s` with `decide :: c -> s -> [e]` and `evolve :: s -> e -> s`) is *not* used; it would silently swallow ε-edges and ignore the register file.


## Plan of Work

Three milestones. Each is independently verifiable.

### Milestone 0 — First-principles contract derivation

Before writing any Haskell, derive the contract by enumerating the requirements keiro's contract must satisfy and asking which keiki primitives consume each requirement. Capture the derivation in `docs/research/06-command-cycle-design.md`'s opening section (drafted alongside M2). The derivation must explicitly cover:

1. **Event sourcing** — replay a list of recorded events into current state. Consumes `applyEvents`/`reconstitute` over `(s, RegFile rs)`, not over plain `s`. Implication: keiro must persist *and* serialize the register file alongside the control state.
2. **Workflow control transitions on commands** — handle a command, advance state, optionally emit one event. Consumes `step`. Implication: the contract handles the `Maybe co` from `step` (a single event or none) — not the `[e]` shape of the legacy `Decider`.
3. **Workflow internal transitions** — advance state silently when a register-file precondition becomes true (timer fired, retry-count exhausted, child-workflow completed). Consumes ε-edges via `delta`. Implication: keiro needs an explicit "tick" entry point that calls `delta` without a command, distinct from the command-driven `step`.
4. **Snapshots (EP-4)** — checkpoint `(s, RegFile rs)` after a successful append. Implication: the contract must expose the register-file value, not hide it inside an opaque state.
5. **Codecs (EP-2)** — encode/decode events `co`. Implication: the contract carries (or is paired with) a `Codec co`. The aggregate's *state* `(s, RegFile rs)` needs its own codec only for snapshots.
6. **Idempotent commands** — dedup on a caller-supplied `CommandId`. Implication: independent of the transducer; lives in keiro's command wrapper.
7. **Composition (process managers, EP-3, EP-5)** — process managers are themselves transducers consuming events from one alphabet and emitting commands of another. Consumes `compose`/`alternative`/`feedback1` from `Keiki.Composition`. Implication: the contract should not bury the underlying transducer; downstream plans must be able to compose it.

The contract sketch produced by M0 (refined by M2):

    -- An aggregate (or workflow) keiro can run.
    -- Concrete type parameters: phi predicate carrier, rs register-file slots,
    -- s control state, ci command, co event.
    data EventStream phi rs s ci co = EventStream
      { esTransducer :: SymTransducer phi rs s ci co
      , esEventCodec :: Codec co               -- defined in EP-2
      , esStateCodec :: StateCodec (s, RegFile rs)  -- defined in EP-4
      , esEventTag   :: co -> Text             -- stable event-type discriminator
      , esSnapshotPolicy :: SnapshotPolicy (s, RegFile rs)  -- defined in EP-4
      }

    -- Optional bundle for type-parameter ergonomics:
    type AnyEventStream ci co = forall phi rs s. EventStream phi rs s ci co

`AggregateId a` (defined in keiro, *not* in kiroku) is a typed wrapper carrying a `StreamName`; the `a` parameter ties it to a specific `EventStream` instance so the type system rejects "command-meant-for-Order applied to a Counter stream" mistakes. The exact phantom-vs-data-family choice is part of the M2 design doc.

Acceptance for M0: the contract sketch above (or its refinement) is documented and each requirement above is mapped to the keiki primitive that satisfies it. M0 has no code; it is gating thinking.

### Milestone 1 — Working spike

Create a Haskell package under `spikes/command-cycle/` that demonstrates the entire cycle, using the contract from M0, running against a real Postgres database. By the end of this milestone, `cabal run spike` (cwd `spikes/command-cycle`) prints a transcript showing:

- a stream being created from `NoStream`,
- multiple events being appended at growing versions,
- an ε-edge silently advancing state when a register-file timer expires,
- a deliberate concurrent-write contention being resolved by retry,
- the final stream content matching the expected sequence.

Concretely:

1. **Package setup.** Write `spikes/command-cycle/spike.cabal`, `spikes/command-cycle/cabal.project`, and `spikes/command-cycle/app/Main.hs`. Depend on `kiroku-store`, `keiki`, `effectful`, `effectful-core`, `hasql`, `hasql-pool`, `aeson`, `text`, `vector`, `ephemeral-pg`.
   - `cabal.project` should reference the local kiroku, keiki, and ephemeral-pg checkouts via `packages:` lines using the absolute paths above. (The keiro repo will not have a workspace `cabal.project` until the production library is created in a future MasterPlan.)
2. **Domain.** In `Spike.Counter`, declare:

       -- Control state
       data CounterS = Idle | Cooldown deriving (Eq, Show, Generic)

       -- Register-file slots (a tiny non-symbolic phi over Haskell predicates)
       -- Slot "value" :: Int — counter's tally
       -- Slot "cooldownUntil" :: UTCTime — when the cooldown ε-edge may fire

       data CounterCmd = Increment | Decrement | Tick UTCTime deriving (Eq, Show, Generic)
       data CounterEvent = Incremented | Decremented | CooldownEnded deriving (Eq, Show, Generic)

   The aggregate has an Idle state in which Increment/Decrement update the `value` slot and emit Incremented/Decremented; after a Decrement it transitions to Cooldown and sets `cooldownUntil`; in Cooldown an ε-edge fires when a `Tick` shows current time has passed `cooldownUntil` and emits `CooldownEnded`. This shape exercises both event-sourcing and a workflow primitive (timed transition) in <60 lines of code.

   Provide `ToJSON`/`FromJSON` instances on the event sum.
3. **Transducer.** Build `counterAgg :: EventStream (HsPred '[ '("value",Int), '("cooldownUntil",UTCTime)] CounterCmd) ... CounterS CounterCmd CounterEvent` directly via keiki's builder DSL. Wrap into the keiro `EventStream` record sketched in M0 (codec / state codec stubbed for the spike).
4. **`runCommand` (spike version).** In `Spike.Command`, write:

       runCommand
         :: (Store :> es, Error StoreError :> es, Error CommandError :> es)
         => EventStream phi rs s ci co
         -> StreamName
         -> ci
         -> Eff es (Maybe co)

   Implementation steps:

   - `mInfo <- getStream sn`, capturing `version` (or `StreamVersion 0` if `Nothing`).
   - `events <- readStreamForward sn (StreamVersion 0) maxBound` (paginate if needed; for the spike, one read suffices).
   - decode each `RecordedEvent.payload` via `esEventCodec`, throwing `DecodeError` on failure.
   - run `applyEvents (esTransducer agg) (initial t, initialRegs t) decoded` to recover `(s, RegFile rs)`. Failure (`Nothing`) → `ReplayError`.
   - call `step (esTransducer agg) (s, regs) cmd`. Three cases:
     - `Just (s', regs', Just ev)` — typical: encode `ev`, append to stream with `expected = if version == 0 then NoStream else ExactVersion version`, return `Just ev`.
     - `Just (s', regs', Nothing)` — command consumed but no event emitted (rare; see M1.7's ε-edge demo where `Tick` may produce nothing if cooldown has not yet elapsed). Return `Nothing` without appending.
     - `Nothing` — no edge fires; return `Left CommandRejected` (caller's choice: model invariant violation or noop).
5. **Retry wrapper.** In `Spike.Retry`:

       data RetryConfig = RetryConfig { maxRetries :: !Int, sleepMicros :: !Int }
       runCommandRetry :: ... -> RetryConfig -> StreamName -> ci -> Eff es (Maybe co)

   Catches `WrongExpectedVersion` and re-runs `runCommand`. Anything else propagates. `DuplicateEvent` is treated as success (the previous append committed).
6. **Driver.** In `app/Main.hs`:

   - launch `ephemeral-pg`,
   - construct a `KirokuStore` against its connection string,
   - run `Kiroku.Store.Schema.initializeSchema`,
   - submit a sequence of commands `[Increment, Increment, Decrement, Tick (now+0.1s), Tick (now+1s), Increment]`,
   - assert the second `Tick` emits `CooldownEnded` (validates the ε-edge path through `step`),
   - read back events via `readStreamForward` and print them,
   - run a contention test: two `forkIO` threads each calling `runCommandRetry` ten times; assert the final counter value matches the expected sum.

Acceptance for M1: the program prints something like:

    [spike] starting ephemeral-pg on port 54931
    [spike] applied kiroku schema
    [spike] appended 5 events to counter-42 (Incremented, Incremented, Decremented, CooldownEnded, Incremented)
    [spike] hydrated state: (Idle, value=2, cooldownUntil=...)
    [spike] contention test: 20 commands across 2 threads, observed 3 retries, final value 12

### Milestone 2 — Design document

Write `docs/research/06-command-cycle-design.md`. The document must be self-contained for a reader who has not seen this plan. Structure:

- *Problem statement* — restate the cycle and why no existing module covers it.
- *Contract derivation* (from M0) — the requirements list, the keiki primitive that satisfies each, and the resulting `EventStream phi rs s ci co` record. Explicitly explain why `Keiki.Decider` is *not* the contract: it loses the register file, the ε-edge path, and the symbolic predicate carrier that v2 verification will need. Cite `docs/research/02-keiki-decide-loop.md` for keiki's primitive list.
- *Public API surface* — final type signatures of `Keiro.Command.runCommand`, `runCommandRetry`, the `CommandError` ADT, the `RetryConfig` record, and the multi-stream `runCommandMulti` (which uses kiroku's `appendMultiStream` for atomicity across streams).
- *Type-safe stream identity* — define `newtype AggregateId a = AggregateId StreamName`. `a` is the aggregate-identity type whose `EventStream` instance carries the matching transducer/codecs. Explain why the typed wrapper lives in keiro (not kiroku).
- *Hydration phase* — pagination, batch sizing, the `DecodeError` and `ReplayError` cases, when an unknown-event-type is fatal vs ignorable. Note that hydration produces `(s, RegFile rs)`, not just `s`. **Express the hydration pipeline as a Streamly `Stream` of `RecordedEvent`s consumed by a `Fold` that decodes, calls `applyEvent`, and accumulates `(s, RegFile rs)`.** The `Stream` is sourced either from a chunked `Kiroku.Store.Read.readStreamForward` loop wrapped in `Streamly.Data.Stream.unfoldrM`, or — once kiroku grows a Streamly-native single-stream read (forwarded to EP-6 if missing) — from kiroku directly. The `Fold` is `Fold.foldlM' replayStep (initial t, initialRegs t)`, where `replayStep (s, rs) recorded = decode recorded >>= applyEventOrError`. Use `Fold.take maxBound` (i.e., consume the entire stream) for hydration, and `Fold.take n` for snapshot-bounded reads (EP-4). This gives constant-memory replay regardless of stream length and matches the substrate already used by shibuya and kiroku-store.
- *Decide phase* — pure `step`; how an effectful-read need (e.g. "is this email blacklisted?") is satisfied by pre-fetching into the command payload at the call site (this matches keiki's design rationale, see `docs/research/02-keiki-decide-loop.md`). Three outcomes: edge fires with output, edge fires silently (ε-edge), or no edge fires.
- *Tick / silent-advance entrypoint* — beyond the command-driven cycle, expose `tick :: AggregateId a -> Eff es ()` that loads, runs `delta` without a command (looking for an active ε-edge), and persists any silent state advance. Useful for timer-driven workflows. Discuss whether the ε-transition should produce a domain event for log fidelity or remain truly silent (preliminary recommendation: emit a `StateAdvanced` synthetic event for replay determinism).
- *Append phase* — `ExpectedVersion` selection rule (`NoStream` if hydrated version is 0, else `ExactVersion v`), `eventId` defaulting, idempotency by caller-supplied command id.
- *Retry policy* — `WrongExpectedVersion` is normal (treat as concurrency signal, retry up to `maxRetries`); `DuplicateEvent` is treated as success; all other `StoreError` variants escalate.
- *Transactional step combinator* — design of `runCommandWithSql :: ... -> Hasql.Session () -> Eff es (Maybe co)` that opens a `TxSessions.transaction ReadCommitted Write` block containing both the append and a user-supplied SQL action. Explain that kiroku-store currently does not expose this combinator for single streams; record the upstream feature request (forward to EP-6).
- *Multi-stream commands* — design of `runCommandMulti` that takes a list of `(AggregateId, ExpectedVersion, command)` triples and uses `appendMultiStream`. Note the deadlock-avoidance rule (kiroku pre-locks streams in `stream_id` order — already handled by kiroku).
- *Observability* — correlation/causation propagation, expected `OpenTelemetry` spans (defer details to the keiro implementation MasterPlan; the design doc only fixes the *fields* on `EventData.metadata`).
- *Test plan* — the spike's contention test is the v1 acceptance for the cycle; the production library's tests will cover idempotency, retry exhaustion, decode errors, multi-stream atomicity, and ε-edge replay determinism.
- *Open questions / upstream gaps* — explicitly forwarded to EP-6 (`docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md`). Anticipated keiki-side items: structured error model on `step`/`omega` (currently bare `Maybe`); register-file serialization helper for snapshots.

Acceptance for M2: the document is checked in at `docs/research/06-command-cycle-design.md`, is referenced from `docs/research/00-overview.md`, and a reviewer can answer every "what does keiro do when …?" question for the cycle by reading just this document.


## Concrete Steps

The commands below assume the working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless otherwise noted.

Bootstrap the spike package:

    mkdir -p spikes/command-cycle/app spikes/command-cycle/src
    # Author files; see Plan of Work.
    cd spikes/command-cycle
    cabal build all

Run the spike:

    cd spikes/command-cycle
    cabal run spike

Expected (truncated) transcript:

    [spike] starting ephemeral-pg on port <ephemeral>
    [spike] applied kiroku schema
    [spike] appended 4 events to counter-42
    [spike] hydrated state: Counter 1
    [spike] contention test: 20 commands across 2 threads, observed N retries, final value 7
    [spike] OK

If the spike fails with `WrongExpectedVersion` after exhausting retries, the test is broken (retry count too low or contention too high); raise `maxRetries` and rerun.

Write the design doc:

    # author docs/research/06-command-cycle-design.md per Plan of Work milestone 2
    # then update docs/research/00-overview.md to list the new file


## Validation and Acceptance

Concrete acceptance criteria, all must hold:

1. `cabal build all` from `spikes/command-cycle` exits 0.
2. `cabal run spike` from `spikes/command-cycle` exits 0 and prints a transcript whose final line contains `OK`.
3. The spike's contention test issues at least 20 concurrent commands and records at least one observed retry (proving the retry loop is exercised, not bypassed).
4. The hydrated counter value matches the analytical sum of the commands issued, demonstrating that no events were lost or double-counted.
5. `docs/research/06-command-cycle-design.md` exists and is referenced from `docs/research/00-overview.md`.
6. Every public type or function named in the design document is realized in the spike's code (proving the design is implementable on the existing kiroku/keiki APIs).

Phrased as observable behaviour: a reviewer who clones this repo, follows the commands above on a Mac (the only supported platform per `flake.nix`), and reads `docs/research/06-command-cycle-design.md` should be able to write a one-sentence answer to "how does keiro handle a command?" without having to read kiroku or keiki source.


## Idempotence and Recovery

The spike package is destination-only — running it never modifies anything outside `/tmp` (where `ephemeral-pg` writes its data dir, deleted on exit). The spike can be run any number of times.

Editing the design document is idempotent (re-saving the same content is a no-op).

If the spike build breaks because kiroku, keiki, or ephemeral-pg has moved on disk, fix the absolute paths in `spikes/command-cycle/cabal.project`. There is no "rollback" required; the spike is throwaway.

If a Postgres connection fails (port collision, `ephemeral-pg` startup race), simply re-run `cabal run spike`; each invocation starts a fresh ephemeral instance.


## Interfaces and Dependencies

Libraries used:

- `kiroku-store` — the event-store effect and types. Path: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store`. Exposes `Kiroku.Store.Effect.Store`, `Kiroku.Store.Append.appendToStream`, `Kiroku.Store.Read.readStreamForward`/`.getStream`, `Kiroku.Store.Types.{StreamName, StreamVersion, ExpectedVersion, EventData, RecordedEvent}`, `Kiroku.Store.Error.StoreError`, `Kiroku.Store.Schema.initializeSchema`, `Kiroku.Store.Connection.withStore`/`KirokuStore`. Also exposes a Streamly-based subscription bridge in `Kiroku.Store.Subscription.Stream` (returns `Streamly.Data.Stream.Stream IO RecordedEvent` via `Stream.unfoldrM`), which is the substrate `shibuya-kiroku-adapter` lifts into shibuya. Whether kiroku also exposes a Streamly-native *single-stream forward read* (returning a `Stream IO RecordedEvent` for `readStreamForward`) is to be confirmed in M0 / M1.1; if not, the spike uses the `Vector`-based read paginated inside `Stream.unfoldrM`, and EP-6 records the gap.
- `keiki` — the pure functional core. Path: `/Users/shinzui/Keikaku/bokuno/keiki`. Exposes `Keiki.Core` (the native `SymTransducer phi rs s ci co` plus `step`, `delta`, `omega`, `applyEvent`, `applyEvents`, `reconstitute`), the builder DSL, and `Keiki.Composition` (`compose`, `alternative`, `feedback1`). The spike uses `SymTransducer` directly; the `Keiki.Decider` legacy facade is *not* used.
- `effectful` — `Eff`, effect constraints, `Effectful.Error.Static.Error`/`tryError`/`throwError`.
- `hasql` and `hasql-pool` — used transitively through kiroku-store; the spike does not call them directly.
- `aeson` — for `ToJSON`/`FromJSON` on the spike's domain types.
- `streamly` (registered as `composewell/streamly`) and `streamly-core` — `Streamly.Data.Stream` (`Stream`, `unfoldrM`, `mapM`, `morphInner`, `take`) and `Streamly.Data.Fold` (`Fold`, `foldlM'`, `drain`, `take`). Already a transitive dependency through shibuya and kiroku-store; the spike depends on it directly so the hydration `Stream → Fold` pipeline can be expressed without going through a shibuya adapter (commands do not consume from a queue).
- `ephemeral-pg` (registered as `shinzui/ephemeral-pg`) — for the ephemeral Postgres in the spike.

Function signatures that must exist by the end of M1 (final names may be tightened in M2's design doc):

    -- spikes/command-cycle/src/Spike/EventStream.hs
    data EventStream phi rs s ci co = EventStream
      { esTransducer :: SymTransducer phi rs s ci co
      , esEncode     :: co -> Aeson.Value           -- standalone in spike; promoted to Codec in EP-2
      , esDecode     :: Aeson.Value -> Either String co
      , esEventTag   :: co -> Text
      }

    -- spikes/command-cycle/src/Spike/Command.hs
    runCommand
      :: ( Store :> es, Error StoreError :> es, Error CommandError :> es
         , BoolAlg phi (RegFile rs, ci)
         )
      => EventStream phi rs s ci co
      -> StreamName
      -> ci
      -> Eff es (Maybe co)

    -- spikes/command-cycle/src/Spike/Retry.hs
    data RetryConfig = RetryConfig { maxRetries :: !Int, sleepMicros :: !Int }
    runCommandRetry
      :: ( Store :> es, Error StoreError :> es, Error CommandError :> es
         , IOE :> es, BoolAlg phi (RegFile rs, ci)
         )
      => RetryConfig
      -> EventStream phi rs s ci co
      -> StreamName
      -> ci
      -> Eff es (Maybe co)

    -- spikes/command-cycle/src/Spike/Command.hs
    data CommandError
      = DecodeError StreamName Text String
      | ReplayError StreamName Text
      | CommandRejected StreamName Text
      deriving (Eq, Show)

By the end of M2, `docs/research/06-command-cycle-design.md` additionally fixes the production-shape signatures including `AggregateId a`, the snapshot-aware variant of `runCommand`, the `tick` entry point for ε-edge advancement, `runCommandMulti`, and the transactional-step combinator `runCommandWithSql`.

Downstream consumers (must be informed of any signature change in this plan):

- EP-2 (`docs/plans/2-codec-and-event-schema-strategy.md`) consumes the encoder/decoder slot in `runCommand`'s signature.
- EP-3 (`docs/plans/3-subscriptions-projections-and-process-managers.md`) consumes `runCommand` to implement process-manager write paths.
- EP-4 (`docs/plans/4-snapshot-strategy-and-hydration-acceleration.md`) consumes the hydration-phase contract; the snapshot path replaces the initial `readStreamForward` call.
- EP-6 (`docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md`) consumes the "open questions / upstream gaps" subsection of the design doc.


## Revisions

- 2026-05-04: Replaced `Keiki.Decider` with `SymTransducer` throughout. The keiki team clarified that `Decider` is a legacy compatibility facade; the native primitive is `SymTransducer phi rs s ci co` with the register file `RegFile rs` and ε-edges, both of which are required to support workflows (timers, retry counters, silent state advances). Added milestone M0 to make first-principles contract derivation an explicit deliverable. Added milestone M1.7 forcing the spike to exercise an ε-edge (the cooldown timer in the `Counter` aggregate) so the contract is honest about supporting workflow primitives, not just deciders. Updated the design-document outline and the M1 signatures accordingly. Reason: avoid amputating keiki's workflow capability at the contract boundary.

- 2026-05-04: Adopted Streamly's `Stream` and `Fold` as the substrate for the hydration pipeline. Updated the *Hydration phase* subsection of the M2 design-doc outline to express the read-decode-fold as `Stream (Eff es) RecordedEvent` consumed by a `Fold (Eff es) RecordedEvent (s, RegFile rs)`. Added `streamly`/`streamly-core` to the spike's dependencies. Added a Decision Log entry. Noted in *Interfaces and Dependencies* that kiroku-store's existing `Kiroku.Store.Subscription.Stream` returns a Streamly stream, and that whether kiroku exposes a Streamly-native single-stream forward read is a question for M0/M1.1 (with EP-6 picking up the gap if not). Reason: matches the MasterPlan's new "Streamly substrate" Integration Point; aligns with the substrate already used by shibuya and kiroku-store; gives constant-memory hydration for long streams.
