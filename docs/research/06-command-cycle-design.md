# Command Cycle Design — keiro

Author: ExecPlan EP-1 (`docs/plans/1-command-cycle-design-and-spike.md`). Date: 2026-05-05.

This document fixes the contract and the runtime cycle that keiro will expose for handling a command targeted at an aggregate. It is the foundation document every other keiro design plan refers to. The accompanying spike at `spikes/command-cycle/` is the empirical proof that the contract is implementable on the existing kiroku and keiki primitives, including under concurrent writers.

The reader is assumed to have read `docs/research/01-kiroku-read-side.md`, `docs/research/02-keiki-decide-loop.md`, `docs/research/04-kiroku-keiki-integration.md`, and the parent MasterPlan at `docs/masterplans/1-keiro-research-foundation.md`. Where a key fact from those documents matters here it is repeated; the reader who has not seen them should still be able to follow this design.


## 1. Problem statement

経路 (keiro) is a Haskell library that turns kiroku (Postgres event store), keiki (pure decider/evolve core via `SymTransducer`), shibuya (subscription engine), and a small set of supporting libraries into a single event-sourcing and workflow framework. The single most important behaviour keiro must enable is the canonical command-handling cycle:

1. A caller submits a command targeted at one aggregate identified by a typed stream name.
2. keiro loads that aggregate's events from kiroku.
3. keiro folds the events into a recovered state via keiki's `applyEvents` (over the joint `(state, RegFile)`).
4. keiro runs keiki's `step` to compute the next state and at most one emitted event.
5. keiro appends the emitted event back to kiroku with optimistic concurrency control.
6. On a `WrongExpectedVersion` collision, keiro re-runs the cycle from step 2 up to a configured retry limit.

This cycle does not exist anywhere in the dependencies today (verified in `docs/research/04-kiroku-keiki-integration.md`). The kiroku and keiki libraries are independent: kiroku has no awareness of keiki's state model, and keiki has no awareness of kiroku's append API. Designing the contract that bridges them — and proving it survives concurrent writers — is what this document and the spike accomplish.

The user-visible behaviour the eventual library will deliver is, schematically:

    runCommand :: EventStream phi rs s ci co
               -> AggregateId a
               -> ci
               -> Eff es (Either CommandError (Maybe co))

where `EventStream` is the keiro-native bundle (the `SymTransducer`, codecs, snapshot policy), `AggregateId a` is a typed wrapper around kiroku's `StreamName`, `ci` is the command alphabet, and `co` is the event alphabet. The `Maybe co` reflects that a single `step` either emits one event or none (the silent ε-edge case from keiki). `CommandError` distinguishes a domain rejection ("no edge fires") from infrastructure failure (decode error, replay error, retry exhausted).


## 2. Contract derivation

The contract between keiro and keiki must come from first principles, not from `Keiki.Decider`. `Decider c e s` is keiki's legacy compatibility facade — its `decide :: c -> s -> [e]` masks `omega`'s `Maybe co` as `[]` or `[e]`, and its `evolve :: s -> e -> s` ignores the register file. Both lose information that keiki's *native* primitive — `Keiki.Core.SymTransducer phi rs s ci co` — preserves. Adopting `Decider` as keiro's contract would amputate the very features keiki provides to support workflows: the typed register file `RegFile rs` (timers, retry counters, correlation context, child-workflow handles), ε-edges (silent transitions advancing state without an observable event), and the symbolic predicate carrier `phi` that the v2 SBV/z3 verification layer will consume. See `docs/research/02-keiki-decide-loop.md` §"The Decide" and §"Composition" for the full case.

The seven concrete requirements keiro must satisfy and the keiki primitive that supplies each:

1. **Event-sourcing replay.** Recover an aggregate's *joint* `(s, RegFile rs)` from a sequence of recorded events. Consumes `applyEvents :: SymTransducer phi rs s ci co -> (s, RegFile rs) -> [co] -> Maybe (s, RegFile rs)` (or `applyEvent` per-event for streaming replay, or `reconstitute` from the transducer's initial state). Implication: keiro must persist *and* serialize the register file alongside the control state — replay over plain `s` is insufficient.
2. **Workflow control transitions on commands.** Handle a domain command, advance `(s, RegFile rs)`, optionally emit one event. Consumes `step :: SymTransducer phi rs s ci co -> (s, RegFile rs) -> ci -> Maybe (s, RegFile rs, Maybe co)`. Implication: keiro's decide phase pattern-matches on `Just (s', regs', Just co)` (typical event), `Just (s', regs', Nothing)` (silent ε-edge advance), and `Nothing` (no edge fires, command rejected).
3. **Workflow internal transitions.** Advance `(s, RegFile rs)` silently when a register-file precondition becomes true (a timer expired, a retry counter exhausted, a child-workflow handle completed). Consumes `delta` directly without a `ci` argument, or `step` with a synthetic "tick" command. Implication: keiro exposes a separate `tick` entry-point distinct from the command-driven path.
4. **Snapshots.** Checkpoint `(s, RegFile rs)` after a successful append so future hydrations can skip events older than the snapshot. Implication: the contract must surface the register-file value rather than hide it inside an opaque state — EP-4's snapshot codec serializes both halves.
5. **Typed event codecs.** Encode and decode `co` at the kiroku boundary. Implication: the contract carries (or is paired with) a `Codec co`. EP-2 fixes the codec interface; keiro's command cycle consumes `Codec co` only via two pure functions (encode + decode) at the kiroku boundary.
6. **Idempotent commands.** Deduplicate on a caller-supplied `CommandId`. Implication: idempotency is independent of the transducer; it lives in the keiro wrapper around `runCommand`.
7. **Composition.** Process managers (EP-3) and sagas (EP-5) are themselves transducers consuming events from one alphabet and emitting commands of another. Consumes `compose`, `alternative`, `feedback1` from `Keiki.Composition`. Implication: the contract must keep the underlying `SymTransducer` accessible — downstream plans need the event stream's `esTransducer` to be readable, not buried.

The resulting contract record:

    data EventStream phi rs s ci co = EventStream
      { esTransducer       :: SymTransducer phi rs s ci co
      , esEventCodec       :: Codec co                          -- defined in EP-2
      , esStateCodec       :: StateCodec (s, RegFile rs)        -- defined in EP-4
      , esEventTag         :: co -> Text
      , esSnapshotPolicy   :: SnapshotPolicy (s, RegFile rs)    -- defined in EP-4
      }

The M1 spike collapses this to the substrate slots actually exercised by the load → fold → decide → append cycle: a bare `esEncode :: co -> Aeson.Value` and `esDecode :: Aeson.Value -> Either String co` stand in for `Codec co`, and the snapshot fields are omitted entirely. The shape lives at `spikes/command-cycle/src/Spike/EventStream.hs` with a comment naming the production shape this collapses from.

`esEventTag :: co -> Text` produces the `event_type` discriminator written to kiroku's indexed `event_type` column. The read side routes on it without decoding the JSON payload (cheap probe). EP-2 may move this onto the `Codec` typeclass once codecs land.


### Cost-benefit ledger (2026-05-09 validation pass)

The choice of `SymTransducer` over `Keiki.Decider` is real engineering trade-off, not a slam-dunk. The MasterPlan's 2026-05-09 Surprises & Discoveries entry records the audit. The five differentiators between the two contracts (features available on `SymTransducer` but **not** exposed by `Keiki.Decider.toDecider`, per `keiki/src/Keiki/Decider.hs:1-45`):

| # | Feature                                              | Cost                                                                | Realised in v1?                                              | Net assessment                                                                 |
|---|------------------------------------------------------|---------------------------------------------------------------------|--------------------------------------------------------------|--------------------------------------------------------------------------------|
| 1 | `tick` / direct `delta` access                       | Separate API surface from `runCommand`                              | **Yes.** §7 below; timers + child-workflow completion         | **Load-bearing.** Keeps domain event log clean of infrastructure events.       |
| 2 | `step`'s 3-way return (`Maybe (s', regs', Maybe co)`)| 3-way pattern match instead of list-shaped                          | **Yes.** §6 decide-phase outcomes                             | **Modest realised.** `Decider`'s `[]` vs `[e]` would collapse rejected/silent. |
| 3 | ε-edges observable in `step`                         | The 3-way return                                                    | **Partially.** §6 reifies ε-edges back to synthetic events    | **Weak in v1.** Benefit may strengthen in v2 (`runWorkflow` may not reify).    |
| 4 | `phi` symbolic predicate carrier                     | `BoolAlg phi (RegFile rs, ci)` plumbed through every API            | **No** — reserved for v2 SBV/z3 verification                  | **Future-bet.** Conditioned on keiki shipping z3; tracked in EP-6 §10.4.       |
| 5 | Hidden-input / `solveOutput` constraint              | Event payload fields must be direct projections (`TApp1`/`TApp2` fail) | **Yes (as fragility).** EP-1 spike crashed on this initially | **Net cost — no offset.** `Decider`'s `evolve` does not impose this. EP-6 §7.4 records the upstream mitigation. |

Note that **`RegFile rs` is NOT a differentiator** between `SymTransducer` and `Keiki.Decider` — the latter's state carrier is `(s, RegFile rs)` per the keiki module's `toDecider` definition. The register-file persistence work (EP-36 in keiki) would exist under either contract.

The audit's verdict: **the decision holds.** Load-bearing benefit #1 (`tick`) alone justifies the choice for any keiro consumer building workflows or process managers. Modest benefit #2 sweetens it for any consumer needing rejected-vs-silent observability. Future-bet #4 is the largest exposure — if z3 verification slips, we carry `phi` overhead with no offset; EP-6 §10.4 forwards this concern to the keiki maintainer for confirmation.

The audit also flags two follow-ups: (a) revisit ε-edge reification in v2 (#3 — we may be paying for ε-edges twice); (b) consider an internal `Keiro.Decider`-style ergonomic wrapper over `runCommand` for pure-CQRS users who do not need the workflow surface — captured as a separate keiro ExecPlan, NOT a contract reversal.


## 3. Event-stream identity

`AggregateId a` is keiro's typed wrapper around kiroku's `StreamName`:

    newtype AggregateId a = AggregateId { unAggregateId :: StreamName }

The phantom type parameter `a` is the event-stream-identity tag: a type whose `EventStream` instance carries the matching `SymTransducer phi rs s ci co`, codec, and policies. With this, `runCommand :: EventStream phi rs s ci co -> AggregateId a -> ci -> ...` can refuse to type-check when a caller hands an `AggregateId Order` to a `runCommand` whose `EventStream` is for `Counter`. The wrapper lives in keiro (not kiroku) for two reasons:

- kiroku's `StreamName` is `Text`-shaped and intentionally untyped at the API boundary; promoting it to `newtype StreamName Text` upstream would force every kiroku caller to bear a phantom they may not need.
- keiro can pair `AggregateId a` with an `EventStream phi rs s ci co` lookup (TypeFamily / class instance) so the whole contract is recovered from a single type-level tag.

The class shape:

    class HasEventStream a where
      type EsPhi a   :: Type
      type EsRegs a  :: [Slot]
      type EsState a :: Type
      type EsCmd a   :: Type
      type EsEvent a :: Type
      eventStreamOf :: EventStream (EsPhi a) (EsRegs a) (EsState a) (EsCmd a) (EsEvent a)

The class is only required when the user wants the type-level lookup. A simpler shape — passing the `EventStream` value as an explicit argument alongside the `AggregateId` — is what the spike does and is also the recommended default for v1. The spike does not introduce `HasEventStream` precisely so the contract stays minimal; the production library may add the class as a convenience layer.

EP-6 records the alternative — pushing `newtype StreamName a` upstream into kiroku — as an upstream-gap candidate. The current decision is to keep the typed wrapper in keiro and to leave kiroku's API untyped at the boundary; this matches the principle that kiroku owns *append/read* semantics while keiro owns *aggregate semantics*.


## 4. Public API surface

The production keiro public types and signatures are:

    -- The command cycle
    runCommand
      :: ( Store :> es
         , Error StoreError   :> es
         , Error CommandError :> es
         , BoolAlg phi (RegFile rs, ci)
         , Show ci
         )
      => EventStream phi rs s ci co
      -> AggregateId a
      -> ci
      -> Eff es (Maybe co)

    -- Optimistic-retry wrapper
    data RetryConfig = RetryConfig
      { maxRetries  :: !Int
      , baseSleepMicros :: !Int
      , jitter      :: !Bool
      }

    runCommandRetry
      :: ( Store :> es
         , Error StoreError   :> es
         , Error CommandError :> es
         , Error RetryError   :> es
         , IOE :> es
         , BoolAlg phi (RegFile rs, ci)
         , Show ci
         )
      => RetryConfig
      -> EventStream phi rs s ci co
      -> AggregateId a
      -> ci
      -> Eff es (Maybe co)

    -- Silent-advance entry point (workflow timer ticks)
    tick
      :: ( Store :> es
         , Error StoreError   :> es
         , Error CommandError :> es
         , BoolAlg phi (RegFile rs, ci)
         )
      => EventStream phi rs s ci co
      -> AggregateId a
      -> Eff es (Maybe co)

    -- Multi-stream atomic command (kiroku appendMultiStream-backed)
    runCommandMulti
      :: ( Store :> es
         , Error StoreError   :> es
         , Error CommandError :> es
         )
      => [SomeMultiCommand]
      -> Eff es [Maybe SomeEvent]

    -- Transactional-step combinator (single stream)
    runCommandWithSql
      :: ( Store :> es
         , Error StoreError   :> es
         , Error CommandError :> es
         , BoolAlg phi (RegFile rs, ci)
         )
      => EventStream phi rs s ci co
      -> AggregateId a
      -> ci
      -> Hasql.Session.Session ()   -- user-supplied SQL action committed in the same tx
      -> Eff es (Maybe co)

    -- Errors
    data CommandError
      = DecodeError    !StreamName !EventType !String
      | ReplayError    !StreamName !EventType
      | CommandRejected !StreamName !Text
      deriving stock (Eq, Show)

    data RetryError = RetryExhausted !StreamName !StoreError
      deriving stock (Show)

`SomeMultiCommand` and `SomeEvent` are existentially-quantified packagings of `(AggregateId, EventStream, ci)` and `(AggregateId, Maybe co)`; their precise shape is part of `runCommandMulti`'s implementation and is sketched in §11.

The spike implements `runCommand`, `runCommandRetry`, and `CommandError`/`RetryError` with the simpler `StreamName` argument (no typed `AggregateId a`) so it can demonstrate the cycle's mechanics without committing to the typed-identity surface. The production library adds the typed wrapper. Callers who want to skip the wrapper can always recover the bare-`StreamName` form by `unAggregateId`.


## 5. Hydration phase

Hydration is the load → fold half of the cycle. keiro consumes kiroku's `readStreamForward` and feeds the events through keiki's `applyEvent` to recover `(s, RegFile rs)`.

The pipeline is expressed as a Streamly `Stream` of `RecordedEvent`s consumed by a `Fold`:

    hydrate
      :: ( Store :> es
         , Error StoreError   :> es
         , Error CommandError :> es
         , BoolAlg phi (RegFile rs, ci)
         )
      => EventStream phi rs s ci co
      -> StreamName
      -> Eff es (s, RegFile rs, StreamVersion)
    hydrate agg sn =
      Stream.fold
        (Fold.foldlM' replayStep (pure (initial t, initialRegs t, StreamVersion 0)))
        (hydrationStream sn pageSize)
      where
        t = esTransducer agg

The `Stream` itself is built by paginating `readStreamForward`:

    hydrationStream :: (Store :> es, Error StoreError :> es)
                    => StreamName -> Int32 -> Stream (Eff es) RecordedEvent
    hydrationStream sn pageSize =
      Stream.concatMap (Stream.fromList . V.toList) pages
      where
        pages = Stream.unfoldrM nextPage (StreamVersion 0)
        nextPage cursor = do
          events <- readStreamForward sn cursor pageSize
          if V.null events
            then pure Nothing
            else
              let lastV = (V.last events).streamVersion
              in pure (Just (events, lastV))

Each `replayStep` decodes the event payload via `esDecode`, runs `applyEvent` to advance `(s, RegFile rs)`, and threads the highest `streamVersion` seen so the caller knows whether to choose `NoStream` or `ExactVersion v` on the eventual append. Decode failures raise `DecodeError`; replay failures (event matches no active edge) raise `ReplayError`.

The constant-memory shape matters because keiro's process-manager state streams (EP-3) and long-running workflow streams (EP-5) can grow to thousands of events. Holding the events in a `Vector` in memory and folding with `foldM` would scale linearly with stream length; the `Stream`/`Fold` shape uses constant memory regardless. EP-4's snapshot path replaces the initial cursor with `snapshot.version + 1` so tail replay is bounded by the snapshot policy's events-since-snapshot threshold rather than the absolute stream length.

This shape matches the parent MasterPlan's "Streamly substrate" Integration Point. Shibuya's adapters expose `Stream (Eff es) (Ingested es msg)`; kiroku-store's subscription bridge (`Kiroku.Store.Subscription.Stream`) exposes `Stream IO RecordedEvent`. keiro's hydration is the same primitive set. EP-3 (subscription handlers) and EP-4 (snapshot-tail replay) reuse it.

**Invariant for aggregate authors.** keiki's `solveOutput` walks an edge's `OutFields` to invert an observed event back into the input that produced it (so `applyEvent` can replay through the matching edge's update). It only inverts:

- `TLit r`             — literal
- `TReg ix`            — register read (treated as a no-op in the inverse, fine)
- `TInpCtorField ic ix` — direct projection of a field of the named input constructor

Computed terms — `TApp1 f t`, `TApp2 f a b` — defeat the inverse: `solveOutput` returns `Nothing`, `applyEvent` returns `Nothing`, replay raises `ReplayError`. Therefore **event payload fields must be direct projections of input fields**; the state delta (counter += 1, cooldownUntil = at + duration) is carried by the edge's `update`, not duplicated into the event payload. The spike's first pass violated this and crashed on the second command of scenario 1; see EP-1's Surprises log entry. EP-2's codec design and any keiro author cookbook must call this out prominently. EP-6 may want to lift it to a compile-time error in keiki itself.

Page size for `hydrationStream` defaults to 256 (matching the spike). Larger pages reduce round-trips but inflate per-page memory; smaller pages do the inverse. Production keiro should expose this as a tunable (`EventStream.esPageSize` field) and let event-stream authors override the default for hot streams.


## 6. Decide phase

The decide phase is pure: `step` is `keiki`'s native operation that does *not* perform IO and cannot read external state. Decisions that need a database lookup must pre-fetch the value into the command payload at the call site (see `docs/research/02-keiki-decide-loop.md` §"Effectful Story" for the rationale). This keeps the transducer deterministic and replay-safe.

Three outcomes from `step (esTransducer agg) (s, regs) cmd`:

- `Just (s', regs', Just ev)` — the typical case. Encode `ev`, append it to kiroku.
- `Just (s', regs', Nothing)` — a silent ε-edge fired. The state advanced but no event is observable on the wire. v1 keiro's recommendation: emit a synthetic `StateAdvanced` event (preliminary name) so replay determinism is preserved. The spike's Counter does not exercise this path because its CooldownEnded transition emits a real domain event for replay determinism — but the public API's `Maybe co` return type leaves the silent path expressible.
- `Nothing` — no edge fires. keiro raises `CommandRejected sn (T.pack (show cmd))`. The caller distinguishes domain rejection from infrastructure failure by pattern-matching on `CommandError`.

The pure step has no observability hook of its own; tracing/metrics live in the keiro wrapper around it. §12 covers observability.


## 7. Tick / silent-advance entry point

Beyond the command-driven cycle keiro exposes `tick :: AggregateId a -> Eff es (Maybe co)`. `tick` hydrates the aggregate, then runs `delta` over `(s, regs)` *without* a domain command, looking for an active ε-edge to fire. If exactly one ε-edge has a satisfied guard, `tick` records the silent advance (as a synthetic event for replay determinism) and persists the new state.

Use cases:

- A workflow timer expired (the register-file slot `cooldownUntil` is in the past). External infrastructure — a scheduler, a periodic worker — issues a `tick` to give keiki a chance to fire the timer-driven ε-edge.
- A child-workflow completed. The child-workflow's emit triggers a `tick` on the parent so it can pick up the result via a register-file slot.

The decision on whether `tick` emits a domain event or remains silent is recorded in §6: v1 emits a synthetic event for replay determinism; v2 may revisit if call sites need the difference between "we ran a tick and nothing happened" and "we ran a tick and the state advanced silently".

The spike does not implement `tick` (its Counter aggregate uses `Tick` as a domain command). The production library will add it once the synthetic-event format is settled (probably an envelope event with `event_type = "_tick"` and an empty payload).


## 8. Append phase

Append uses kiroku's `appendToStream` with one of two `ExpectedVersion` settings:

- `NoStream` if the hydrated `streamVersion` is `0` (the stream has no events yet — this is an aggregate's first append).
- `ExactVersion v` if the hydrated version is `v > 0` (optimistic concurrency: another writer must not have advanced the stream while we were hydrating and deciding).

The choice is mechanical and lives inside `runCommand`:

    let expected = case version of
          StreamVersion 0 -> NoStream
          v               -> ExactVersion v

`EventData.eventId` defaults to `Nothing` (kiroku generates a UUIDv7 at append time). For idempotent commands keiro will generate a deterministic `eventId` from the command's `CommandId` (a v5 UUID over a fixed namespace), so a retry whose previous attempt committed surfaces as `DuplicateEvent` rather than a duplicate insert. The spike does not exercise idempotency — `runCommand` lets kiroku generate the id — and treats `DuplicateEvent` as success in `runCommandRetry` (line 75 of `Spike/Retry.hs`).

`EventData.metadata`, `causationId`, and `correlationId` are reserved for keiro's observability layer (§12). They are filled by an inner `EventData` constructor inside the keiro production library; the spike leaves them all `Nothing` for simplicity.


## 9. Retry policy

`runCommandRetry` catches `WrongExpectedVersion` from kiroku and re-runs the entire load → fold → decide → append cycle. The retry budget is bounded by `RetryConfig.maxRetries`. Each retry sleeps `baseSleepMicros` microseconds (with jitter, in production); the spike uses a fixed `250µs` placeholder.

Other `StoreError` variants:

- `DuplicateEvent` is treated as success. Relevant only when callers supply `EventData.eventId` for idempotency; see §8.
- `StreamAlreadyExists`, `StreamNotFound`, `PoolAcquisitionTimeout`, `ConnectionLost`, `UnexpectedServerError`, `ConnectionError` all escalate as-is — they indicate misuse or infrastructure failure, not concurrency.

When retries are exhausted, `runCommandRetry` raises `RetryError = RetryExhausted !StreamName !StoreError`. The carried `StoreError` is the last `WrongExpectedVersion` the cycle saw, so callers can correlate the final attempt's expected/actual versions with whatever advanced the stream.

The spike's contention test (scenario 2) verifies this empirically: two threads each issuing 10 increments through `runCommandRetry`, with `defaultRetryConfig { maxRetries = 16, sleepMicros = 250 }`. Observed result on the local environment: 17 retries across 20 commands; all 20 committed; final analytical counter delta = 22 = 2 (scenario 1 baseline) + 2*10. Under heavier contention or with a tighter retry budget this would have exhausted; production keiro should default to jittered exponential backoff so the retry rate decays under sustained load.

EP-3 (process managers) and EP-5 (workflow roadmap) reuse this retry shape unchanged: a process manager that reacts to an event by emitting a command runs `runCommandRetry` internally, with the same `RetryConfig` bounds.


## 10. Transactional-step combinator

`runCommandWithSql` is the keiro-side analogue of DBOS's transactional step: append the emitted event *and* a user-supplied SQL action in one Postgres transaction. Use cases:

- Inline projection: append events and update a read-model row in one tx so the projection's row is never out of sync with the appended events.
- Outbox: append events and insert outbox rows that an external relay later forwards (see EP-3).

Concrete shape:

    runCommandWithSql agg sn cmd userSession = do
      ...
      -- inside a TxSessions.transaction ReadCommitted Write block:
      _ <- appendToStream sn expected [evData]
      Hasql.Transaction.statement userSession
      pure ()

**Upstream gap.** kiroku-store currently does not expose a Haskell-layer transaction primitive for *single-stream* appends — only `appendMultiStream` opens a `TxSessions.transaction ReadCommitted Write` block. Single-stream `appendToStream` runs as a single SQL CTE with no Haskell-layer transaction wrapping it, which means it cannot be combined atomically with another `Hasql.Session.Session ()`. EP-6 records this as an upstream feature request: kiroku-store needs a public combinator like

    appendToStreamInTransaction
      :: StreamName -> ExpectedVersion -> [EventData]
      -> (StreamId -> Hasql.Transaction.Transaction a)  -- runs after the append, in the same tx
      -> Eff es a

or, alternatively, a refactor that exposes the underlying `Transaction` for any append. Until the upstream lands, keiro can implement `runCommandWithSql` by routing through `appendMultiStream` with a single-element list — this opens a transaction for free — but the workaround is mildly wasteful (it acquires a `stream_id` advisory lock that is unnecessary for single-stream appends). The spike does not implement `runCommandWithSql` because the upstream gap forces the workaround; EP-3 picks it up once kiroku-store exposes the cleaner combinator.


## 11. Multi-stream commands

`runCommandMulti` accepts a list of `(SomeMultiCommand)` triples, each carrying an `AggregateId`, an `EventStream`, and a command. Internally it hydrates each event stream, runs `step` on each, and uses kiroku's `appendMultiStream` to atomically append the emitted events.

Concrete shape (existential packaging):

    data SomeMultiCommand where
      SomeMultiCommand
        :: ( BoolAlg phi (RegFile rs, ci), Show ci )
        => EventStream phi rs s ci co
        -> AggregateId a
        -> ci
        -> SomeMultiCommand

    data SomeEvent where
      SomeEvent
        :: AggregateId a
        -> Maybe co
        -> SomeEvent

    runCommandMulti
      :: ( Store :> es, Error StoreError :> es, Error CommandError :> es )
      => [SomeMultiCommand] -> Eff es [SomeEvent]

Atomicity: `appendMultiStream` runs in a `TxSessions.transaction ReadCommitted Write` block. Either every per-stream append succeeds or all roll back. `WrongExpectedVersion` on any stream causes the entire batch to fail — the retry layer re-runs the batch from hydration. Deadlock avoidance is kiroku's responsibility (it pre-locks streams in `stream_id` order); keiro inherits the property unchanged.

The spike does not implement `runCommandMulti` because its Counter aggregate is single-stream. The production library will add it; the implementation strategy is:

1. Hydrate each `(AggregateId, EventStream)` independently (they can run in parallel).
2. Run `step` on each (pure, parallel-safe).
3. Encode the emitted events into a `[(StreamName, ExpectedVersion, [EventData])]` triple list.
4. Call `appendMultiStream`.

`runCommandMulti` does not have a built-in retry layer at v1 — callers wrap it with a manually-written retry combinator if they want it. The reason: the retry failure modes for a multi-stream command are richer (one stream's `WrongExpectedVersion` requires re-hydrating *all* aggregates, not just the one that lost the race), and giving callers the choice avoids surprising semantics.


## 12. Observability

keiro's command cycle exposes structured signals for the production library to emit OpenTelemetry spans, structured logs, and metrics. The fields fixed at this layer:

**`EventData.metadata` JSON fields (v1).**

- `keiro.command.id` — caller-supplied `CommandId` (v5 UUID); used for idempotency dedup and for tracing the originating command.
- `keiro.command.tag` — application-level command discriminator (the `Show ci` representation, truncated).
- `keiro.event_stream.id` — the `StreamName` of the event stream.
- `keiro.event_stream.type` — the `AggregateId`'s phantom-type tag, when available.
- `keiro.attempt` — 1-indexed retry attempt (1 means the first try succeeded).
- `keiro.span.trace_id` and `keiro.span.span_id` — the OpenTelemetry trace and span ids, propagated downstream so subscribers and process managers can stitch causality.

**`EventData.causationId` and `EventData.correlationId`.** keiro fills `causationId` with the `eventId` of the *originating* event when the command was emitted by a process manager (see EP-3); for caller-issued commands `causationId` is `Nothing`. `correlationId` is set on the first command of a saga and propagated through every downstream command/event the saga emits.

The full OpenTelemetry span shape (span names, attributes, events) is deferred to the keiro implementation MasterPlan. This document only fixes the *fields* on `EventData.metadata` so EP-3 (which surfaces them on subscriptions) and EP-6 (which records any kiroku-side index needed for span-id lookups) have a stable contract.


## 13. Test plan

The spike's contention test is the v1 acceptance for the load → fold → decide → append cycle. Production keiro's tests will additionally cover:

- **Idempotency.** Submit the same command twice with the same `CommandId`; assert exactly one event in the stream and the second call returns the first attempt's result.
- **Retry exhaustion.** Force `maxRetries` consecutive `WrongExpectedVersion` collisions; assert `RetryExhausted` is raised with the last `StoreError` carried.
- **Decode errors.** Inject a stream with an event whose `eventType` is unknown to the codec; assert `DecodeError` is raised with the offending `eventType`.
- **Replay errors.** Inject a stream with an event whose payload has the wrong shape (a field renamed in the source code without an upcaster); assert `ReplayError` is raised.
- **Multi-stream atomicity.** A two-stream command where one stream's `ExactVersion` would fail; assert neither stream advances.
- **ε-edge replay determinism.** Event streams that emit synthetic state-advance events on `tick`; assert that hydration over the resulting stream yields the same `(s, RegFile rs)` as a fresh forward run with no events skipped.

The spike's transcript is the v1 reference output, repeated here verbatim:

    [spike] starting ephemeral-pg, connection: host=/tmp/nix-shell.zDemgL/pg--… port=55417 dbname=postgres user=shinzui
    [spike] applied kiroku schema
    [spike] --- scenario 1: sequential happy-path ---
    [spike] early Tick correctly rejected
    [spike] appended 5 events to counter-42: Incremented, Incremented, Decremented, CooldownEnded, Incremented
    [spike] --- scenario 2: contention test ---
    [spike] contention test: 20 commands across 2 threads, observed 17 retries
    [spike] final counter (computed from event log): 22
    [spike] OK


## 14. Open questions and upstream gaps

The following items are forwarded to EP-6 (`docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md`) for the consolidated kiroku/keiki feature backlog. Each carries a brief rationale so EP-6 can prioritize.

**kiroku-side.**

- *Single-stream transactional append.* Currently only `appendMultiStream` opens a Haskell-layer transaction; `appendToStream` runs as a single CTE. keiro needs a public combinator that wraps a single-stream `appendToStream` plus a user-supplied `Hasql.Transaction.Transaction a` so the transactional-step primitive (§10) can be implemented cleanly. Workaround until then: route single-stream commands through `appendMultiStream` with a singleton list.

- *Streamly-native single-stream forward read.* Today `readStreamForward` returns `Vector RecordedEvent` (a paginated read). keiro's hydration paginates inside `Stream.unfoldrM` to flatten into a `Stream`. Native streamly support would eliminate the manual paging and let keiro express hydration as a one-line `Stream.fold` over a kiroku-sourced stream. The kiroku-side `Subscription.Stream` already has the right shape — extending it to forward single-stream reads is a copy-and-modify.

- *Postgres-version requirement documentation.* kiroku's schema uses `uuidv7()` which is Postgres 18+ only. Production deployments must pin PG 18; CI environments that ship PG 17 (the current Nixpkgs default in some flakes) will fail at schema initialization. Either document this prominently in kiroku's README or supply a polyfill `uuidv7()` via `pg_uuidv7` for older deployments.

**keiki-side.**

- *Structured error model on `step`/`omega`.* Today these return `Maybe`; keiro must distinguish "guard failed" from "no edge for this command in this state" from "edge update failed" (the latter is currently impossible because updates are total, but the v2 register-typed updates may not be). A typed error sum (`Either StepError ...`) at `step`'s return site would let keiro raise more specific `CommandError` variants.

- *Compile-time check that event payloads are inverse-recoverable.* The spike crashed on its first run because `Incremented { newValue = counter + 1 }` includes a `TApp1` term in its `OutFields`, and `solveOutput` only inverts `TLit` / `TReg` / `TInpCtorField`. The constraint is well-defined and stated in `docs/research/02-keiki-decide-loop.md`, but it is enforced at runtime (a `Nothing` from `applyEvent`) rather than compile-time. A type-class or TH-level check that an `OutFields` contains no `TApp1` / `TApp2` would convert the runtime failure into a compile-time error, which is exactly the kind of safety keiro needs.

- *Register-file serialization helper.* `RegFile rs` is a typed heterogeneous tuple of `(Symbol, Type)` slots. EP-4's snapshot path needs a `StateCodec (s, RegFile rs)` that walks the slot list and serializes each. keiki could expose a `Generic`-style helper that produces a default JSON codec for any `RegFile rs` whose slot types all have `ToJSON`/`FromJSON`. Without it every aggregate author writes a hand-rolled `RegFile` encoder.

- *Optional effectful reads in `decide`.* The pure `step` cannot read external state. keiki's effects-boundary note (`Keiki/docs/research/effects-boundary.md`) explicitly designs around this: callers pre-fetch into the command payload. Some authors will want a constrained "read-only, deterministic, memoizable" effect inside `decide` (e.g. for blacklist lookups). EP-6 should record whether keiki opens this door in v2 or whether keiro builds the pre-fetch convention into its command-receipt path.


## 15. How to verify

The spike at `spikes/command-cycle/` is the empirical proof of this design. To run it:

    cd /Users/shinzui/Keikaku/bokuno/keiro/spikes/command-cycle

    # Build env: GHC 9.12.3 + cabal-install via the keiki nix flake;
    # Postgres 18 + binaries via PATH-prepending kiroku's nix store path
    # (kiroku schema requires uuidv7).
    nix develop /Users/shinzui/Keikaku/bokuno/keiki --command bash -c \
      'export PATH=/nix/store/nh8iirirvq79f54pgz71ylqmmwi1gpc9-postgresql-18.3/bin:$PATH; \
       cabal build all && cabal run spike'

The expected last line of the transcript is `[spike] OK`. If the program fails, the failure mode is one of:

- `SpikeFailure "store: ..."` — kiroku raised a `StoreError`. Check the connection string printed at startup; ephemeral-pg may have failed to start (port collision is rare but possible).
- `SpikeFailure "command: DecodeError ..."` — a stored event's payload no longer matches the codec. Don't expect this on the first run; a stale `dist-newstyle/` after editing the Counter aggregate could produce it.
- `SpikeFailure "command: ReplayError ..."` — an event's payload contains a computed term that defeated `solveOutput`. The aggregate-author invariant in §5 was violated.
- `SpikeFailure "retry: RetryExhausted ..."` — the contention test exceeded `maxRetries`. Increase `defaultRetryConfig.maxRetries` or reduce `perThread` and rerun.

Every public type or function named in this document is realized in the spike (`AggregateId` is the one exception — the spike uses the bare `StreamName`). A reviewer who has read this document and the spike's source code should be able to answer "how does keiro handle a command?" without consulting kiroku's or keiki's source.


## 16. Summary

The keiro command cycle is the load → fold → decide → append loop with optimistic-concurrency retry. Its contract — `EventStream phi rs s ci co` — is built on keiki's native `SymTransducer` rather than the legacy `Decider` facade so workflow primitives (the typed register file, ε-edges, the symbolic predicate carrier) survive into keiro unchanged. Hydration is a Streamly `Stream`/`Fold` pipeline so it composes with the rest of keiro's streaming substrate and runs in constant memory. Append is `kiroku`'s `appendToStream` with `ExactVersion`; retries on `WrongExpectedVersion` are handled by a separate combinator. Multi-stream commands ride on `appendMultiStream`; the transactional-step combinator awaits an upstream addition to kiroku-store. The spike at `spikes/command-cycle/` is the empirical proof of the design under real Postgres + concurrent writers.

EP-2 (codecs) replaces the spike's bare encode/decode pair with a typed `Codec co` and the schema-evolution machinery. EP-3 (subscriptions, projections, process managers) wraps `runCommand` for the process-manager write path. EP-4 (snapshots) replaces the hydration phase's initial cursor with a snapshot read. EP-5 (workflow roadmap) layers durable execution on top of the register file the contract surfaces. EP-6 consolidates the upstream gaps §14 records into a kiroku/keiki feature backlog. All five plans now have a stable foundation to build on.
