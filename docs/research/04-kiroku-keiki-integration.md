# Kiroku × Keiki Integration — Current State of the Command Cycle

Survey author: research subagent (Explore), 2026-05-04.

## The cycle keiro must run

1. Command arrives with a target stream id.
2. Load events for that stream from kiroku (possibly starting from a snapshot).
3. Fold events into current aggregate state using keiki's `evolve`.
4. Run `decide(state, command)` to get either an error or new events.
5. Append new events to kiroku with the expected-version that matches the loaded version (optimistic concurrency).
6. Return the result; on conflict, retry from step 2.

## Existing Glue: None

There is no existing module that implements the command-handling cycle. The kiroku and keiki libraries are completely independent; neither imports nor references the other.

- `kiroku-store` (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/`) exports read, append, and lifecycle operations.
- `keiki` (`/Users/shinzui/Keikaku/bokuno/keiki/src/`) exports the pure `SymTransducer` formalism with `decide` (via `omega`), `evolve` (via `applyEvent`), and batch replay (via `applyEvents`).
- `keiro` (`/Users/shinzui/Keikaku/bokuno/keiro/`) has only empty scaffolding (no Haskell sources yet — only `agents/skills/` and `docs/research/`).

No adapter layer exists that connects these. The shibuya-kiroku-adapter (`kiroku-project/kiroku/shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:1-148`) bridges subscriptions into Shibuya's pull interface but does not implement command handling.

**Verdict: stub only. Every seam needs implementation.**

## Type Compatibility: Minor Impedance Mismatch

Kiroku emits `RecordedEvent` with `payload :: Value` (JSONB) plus metadata fields (`Kiroku.Store.Types:190-213`). Keiki consumes a generic `co` (event), no assumption about serialization.

Keiki's `applyEvent` signature (`Keiki/Core.hs:663-675`):

    applyEvent
      :: SymTransducer phi rs s ci co
      -> s -> RegFile rs -> co -> Maybe (s, RegFile rs)

It expects unwrapped `co`, not `RecordedEvent`. Decoding belongs **outside** keiki:

    -- (sketch)
    recordedEventToEvent :: RecordedEvent -> Either ParseError co

**Verdict: partially implementable.** Kiroku's read API returns raw `Value`; keiki consumes typed events. A decoding layer (e.g., Aeson `FromJSON co`) sits in the middle, with error handling for malformed logs.

## Version Threading: Fully Implementable

Kiroku provides:

- `StreamInfo.version :: StreamVersion` (`Kiroku.Store.Types:160-177`)
- `getStream :: StreamName -> Eff es (Maybe StreamInfo)` (`Read.hs:104-108`)
- `appendToStream` accepts `ExpectedVersion` (`Append.hs:53-59`)
- On success, `AppendResult` returns the final `streamVersion` (`Types:216-229`)

Threading:

1. Read stream metadata via `getStream` → capture `StreamInfo.version`.
2. Load events via `readStreamForward`.
3. Fold via `applyEvents`.
4. Run `decide`.
5. Append with `ExactVersion(capturedVersion)`.
6. On `WrongExpectedVersion` (`Error.hs:40-45`), retry from step 1.

Version is a simple `Int64` (wrapped in `StreamVersion`); thread it as a pure value. **No transaction needed to capture it — reads are read-committed.**

**Verdict: fully implementable.** `ExactVersion` is the optimistic-concurrency linchpin; version threading is already in the API.

## Transaction Model: Read-Committed; Single-Stream Read+Append Not Atomic

Boundaries (`Kiroku.Store.Effect:74-201`):

1. **Single-stream append** (`AppendToStream`) — non-transactional at the Haskell layer. `Pool.use → Session.statement` runs the SQL CTE atomically inside Postgres (all-or-nothing per `Append.hs:17-23`). At Haskell layer: fetch time, prepare events, bind version, send. **No atomic read → append in Haskell.**
2. **Multi-stream append** (`AppendMultiStream`) — transactional. `TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write txn` (`Effect.hs:160`). Pre-locks streams in deterministic `stream_id` order (`Effect.hs:137`).

Can the entire read → append happen in one tx? Not with the current single-stream API. The read sends a separate statement outside any transaction context. To make it atomic, keiro would need to wrap both inside a `TxSessions.transaction ... Write` block — doable with a new interpreter, but not currently supported.

Conflict detection:

- `ExactVersion` enforced as a CTE condition: mismatch → 0-row CTE → `emptyResultError` (`Error.hs:176-185`).
- `WrongExpectedVersion (StreamName, ExpectedVersion, StreamVersion)` signals the conflict.
- No advisory locks; no uniqueness on `(stream, version)` beyond row-level check.

**Verdict: partially implementable.** Single-stream read+append is *not* atomic; multi-stream append *is*. Keiro must either implement an optimistic retry loop on `WrongExpectedVersion`, or add a new transactional read-then-append primitive to kiroku-store. Multi-stream aggregate commands can use `appendMultiStream` for atomicity.

## Effectful Composition: Straightforward

Current signatures:

    -- kiroku-store
    readStreamForward :: (Store :> es) =>
        StreamName -> StreamVersion -> Int32 -> Eff es (Vector RecordedEvent)
    appendToStream :: (Store :> es) =>
        StreamName -> ExpectedVersion -> [EventData] -> Eff es AppendResult
    runStorePool :: (IOE :> es, Error StoreError :> es) =>
        KirokuStore -> Eff (Store : es) a -> Eff es a

    -- keiki (pure)
    applyEvent :: SymTransducer phi rs s ci co
                -> s -> RegFile rs -> co -> Maybe (s, RegFile rs)
    applyEvents :: SymTransducer phi rs s ci co
                -> (s, RegFile rs) -> [co] -> Maybe (s, RegFile rs)

Composition pattern (sketch):

    runCommand :: (Store :> es, Error StoreError :> es)
               => Decider ci co s -> StreamName -> ci -> Eff es (Either Err [co])
    runCommand decider sn cmd = do
      events <- readStreamForward sn (StreamVersion 0) maxBound
      let decoded = mapM (decode :: RecordedEvent -> Either ParseErr co) events
      let state0 = (initial decider, initialRegs decider)
      case applyEvents decider state0 decoded of
        Nothing -> pure (Left "Replay failed")
        Just s  -> do
          let newEvents = decide decider cmd s
          appendToStream sn (ExactVersion loadedVersion) (encode newEvents)
            >>= \_ -> pure (Right newEvents)

New effects needed: a `CommandBus` is optional; the cycle composes cleanly into `Eff es` as long as readers handle `Store` and `Error`. A decoding layer (effect or typeclass) is needed to lift deserialization out of pure code.

**Verdict: fully implementable.** Effectful's constraint-based composition is well-suited; keiki's purity makes embedding easy. No new primitive is required; a decoding layer is the only addition.

## Idempotency: Partial

Kiroku — `EventData.eventId :: Maybe EventId` (`Types:126-131`). If supplied and a retry occurs, duplicate appends surface as `DuplicateEvent (Maybe EventId)` (`Error.hs:60-61`). Comment from `Append.hs:28-33`:

> A retry whose previous attempt actually committed surfaces as `DuplicateEvent` (when the `events_pkey` detail is parseable). A retry that observed `WrongExpectedVersion` on an `ExactVersion` append should be treated as ambiguous: either a concurrent writer raced you or your previous attempt succeeded; the recovery in both cases is to re-read the stream and decide.

Keiki — no idempotency support; `decide` is a pure function of `(state, command)`, not tagged with a command ID.

Gap:

- Keiro must assign command IDs at the entry point and pass them down.
- On `WrongExpectedVersion`, retry (re-read → decide → append).
- On `DuplicateEvent`, retry is unambiguous: previous attempt committed; return success.
- Keiki side: command must be deterministic (true by design).

**Verdict: partially implementable.** Kiroku's event-id dedup works. Keiki's purity guarantees idempotent commands. Keiro must add command-id threading and retry-on-conflict logic.

## Snapshots: No Current Support

Neither library has snapshots. Only a comment exists (`Effect.hs:169-170` on snapshot behavior during hard deletes). A snapshot table or adaptor is needed: `(stream_id, version, state, regs_serialized, created_at)`. On load: read latest snapshot, then events after its version, fold from snapshot's `(state, RegFile)`.

**Verdict: not implementable today.** Both libraries lack snapshots. Future optimization.

## Retry on Conflict: Implementable as Generic Combinator

No retry logic exists in either library.

    retryOnConflict :: Int -> Eff es a -> (StoreError -> Bool) -> Eff es a
    retryOnConflict 0 action _   = action
    retryOnConflict n action ok  = do
      result <- tryError action
      case result of
        Left err | ok err -> do
          liftIO (threadDelay 1000)
          retryOnConflict (n - 1) action ok
        other -> pure other

    retryOnConflict 3
      (runCommand decider streamName cmd)
      (\e -> case e of WrongExpectedVersion {} -> True; _ -> False)

`StoreError` (`Error.hs:39-87`) is structured for retry-vs-escalate decisions.

**Verdict: fully implementable.** A pure combinator in keiro; no library changes needed.

## What Keiro Must Add

Module: `Keiro.Command`.

    runCommand ::
        ( Store :> es,
          Error CommandError :> es,
          FromJSON co, ToJSON co,
          Eq s, Eq co
        )
     => Decider ci co (s, RegFile rs)
     -> StreamName -> ci -> Eff es [co]

Implementation sketch:

1. `getStream` → `StreamNotFound` if missing.
2. `readStreamForward` events from version 0 with a large batch limit.
3. Decode each `RecordedEvent.payload` via `Aeson.fromJSON`.
4. Fold via `applyEvents decider initialState decodedEvents`, defensive against parse/replay failures.
5. Run `decide decider cmd state` to produce new events.
6. Encode each event via `toJSON`.
7. Wrap in `EventData` with caller-supplied command-id (idempotency).
8. `appendToStream sn (ExactVersion loadedVersion) eventDatas`.
9. On `WrongExpectedVersion`, sleep and retry up to N times.
10. On `DuplicateEvent`, return success (previous attempt committed).
11. On other errors, escalate.

Supporting types:

    data CommandError
        = DecodeError StreamName EventId String
        | ReplayError StreamName (Maybe EventId)
        | StoreError_ StoreError
        | CommandDecision String
        | ConflictUnresolved StreamName Int

    data CommandConfig = CommandConfig
        { maxRetries :: Int            -- default 3
        , retryBackoff :: Int          -- microseconds; default 1000
        , decodingTimeout :: Maybe Int
        }

Companion modules:

- `Keiro.Decoding` — Aeson bridge; pluggable for MessagePack/Protobuf.
- `Keiro.Idempotency` — wrap commands with `(UUID, ci)`, thread through append.
- `Keiro.Snapshot` — stub initially.
- `Keiro.Batch` — `appendMultiStream`-based multi-aggregate commands.

File placement (estimates):

- `keiro/src/Keiro/Command.hs` — main cycle (~250 LOC)
- `keiro/src/Keiro/Decoding.hs` — JSON bridge (~100 LOC)
- `keiro/src/Keiro/Idempotency.hs` — command-id wrapping (~80 LOC)
- `keiro/src/Keiro/Snapshot.hs` — stub (~50 LOC)
- `keiro.cabal` — add `kiroku-store`, `keiki`, `aeson`, `effectful`.

Critical invariant: every call to `decide` must be on the state immediately after `applyEvents` with events read at one moment. If a concurrent writer advances the stream, retry. Never auto-merge; always re-read and re-decide.

## Top 5 Risks

1. **Replay validation gap (high).** `applyEvents` silently returns `Nothing` on a malformed log. Error handling must distinguish "log corrupted" (operator alert) from "transient error, retry." Suggestion: add an event-id cursor so keiro can resume from the last known-good event and alert on gaps.
2. **Version capture race (medium).** Optimistic concurrency handles it; document that `WrongExpectedVersion` is a normal concurrency signal and expect a 5–10% retry rate under contention.
3. **Encoding/decoding asymmetry (medium).** Keiki's `applyEvent` may not match an output event against any edge (future schema). Run a validation pass on fresh aggregates and old logs in CI; alert on schema drift.
4. **Snapshot staleness (medium, deferred).** Snapshots become stale if hard-deletes/re-writes occur. Snapshots are safe for reads only; never use for conflict detection. Verify `snapshotVersion < loadedVersion` before using.
5. **Command determinism assumption (low).** Keiki's `decide` is pure but downstream handlers (email, webhooks) are not. Keiro must not retry a command that has side effects post-append. Boundary: only `decide` is retryable; effects (via Shibuya) are not.

## Implementability Summary

| Aspect                | Status   | Effort |
|-----------------------|----------|--------|
| Existing glue         | Absent   | High (all-new) |
| Type compatibility    | Mismatch | Medium (decode layer) |
| Version threading     | Ready    | Low |
| Transaction model     | Partial  | Medium (retry loop / new primitive) |
| Effectful composition | Ready    | Low |
| Idempotency           | Partial  | Medium (command-id wrapper) |
| Snapshots             | Absent   | High (future) |
| Retry on conflict     | Absent   | Low (combinator) |

Estimated effort for a production-ready keiro v0.1 (core cycle, no snapshots): 4–6 weeks. Recommended starting point: `Keiro.Command` module + a test aggregate, validating end-to-end before adding multi-stream or snapshot layers.
