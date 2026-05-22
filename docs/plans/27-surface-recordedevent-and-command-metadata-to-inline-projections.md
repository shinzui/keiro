---
id: 27
slug: surface-recordedevent-and-command-metadata-to-inline-projections
title: "Surface RecordedEvent and command metadata to inline projections"
kind: exec-plan
created_at: 2026-05-22T04:39:46Z
intention: "intention_01ks6z7fxpeydb07j2p3epvkts"
---

# Surface RecordedEvent and command metadata to inline projections

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan responds to a feature request from the first production consumer of `keiro`
(the service nicknamed "Rei"). In their own words:

> A keiro inline projection's `apply` receives the event + `AppendResult` but not the
> event metadata (actor type, agent id, session id). Rei's read models have
> actor/agent/session columns; inline projections had to write them `NULL`, leaving the
> old polling handler as the only path that populates them — which blocks fully retiring
> the polling path for those tables. Suggestion: pass `EventMetadata` (or the full
> `RecordedEvent`) to the inline projection apply.

Two plain-language terms first, because the rest of the plan leans on them:

- An **inline projection** is a small function that writes a read-model row (a flattened,
  query-optimized table) inside the *same database transaction* that appends new events.
  Because the write is in the same transaction as the append, a successful command
  guarantees the read model is already up to date — no waiting for a background worker.
  In this codebase an inline projection is the record `InlineProjection` defined in
  `src/Keiro/Projection.hs`, and it is run by `runCommandWithProjections` in that same
  file.

- A **polling handler** (called an **async projection** here, the record `AsyncProjection`
  in `src/Keiro/Projection.hs`) is the older alternative: a background worker reads events
  back from the store as `RecordedEvent` values and writes the read model *after* the
  command commits. Because it reads `RecordedEvent`, it can see everything the store
  recorded about an event — including its **metadata**, a free-form JSON blob
  (`metadata :: Maybe Value`) that callers use to carry ambient context such as which
  actor, agent, or session caused the event.

The gap is asymmetric. The async path receives a `RecordedEvent` and can populate
actor/agent/session columns from its metadata. The inline path receives only the decoded
domain event (`co`) and an `AppendResult` (which carries only the batch's last stream
version and global position — see `src/Keiro/Command.hs` and the `AppendResult` definition
in the kiroku store, reproduced under "Context and Orientation"). So an inline projection
*cannot* see metadata and is forced to write `NULL` into those columns. That single
asymmetry is what keeps a polling handler alive for those tables.

There is a second, quieter gap that the first one hides: **today there is no way for a
command caller to put actor/agent/session into an event's metadata in the first place.**
The command path in `src/Keiro/Command.hs` encodes every event with
`Keiro.Codec.encodeForAppend`, which hard-codes the metadata to `{ "schemaVersion": N }`
and nothing else. So even if we surfaced metadata to the inline `apply`, it would be
empty. Closing only the surfacing gap would produce code that compiles but does nothing
meaningful. This plan therefore closes both gaps.

After this change a developer can:

1. **Attach ambient metadata to a command.** Set a new optional field on
   `RunCommandOptions` — `metadata :: Maybe Value` — and every event the command appends
   carries that JSON merged with the schema-version marker. For example, a command run with
   `defaultRunCommandOptions & #metadata ?~ object ["actor" .= "agent-7"]` stores events
   whose metadata reads `{ "actor": "agent-7", "schemaVersion": 2 }`.

2. **Read that metadata inside an inline projection.** The inline projection's `apply`
   changes shape from `co -> AppendResult -> Tx.Transaction ()` to
   `co -> RecordedEvent -> Tx.Transaction ()`. The `RecordedEvent` carries the event's id,
   per-event stream version, per-event global position, created-at timestamp, and the
   metadata blob — the same `RecordedEvent` an async projection already receives. An inline
   projection can therefore populate actor/agent/session columns exactly as the polling
   handler did, and a service can share a single `apply`-style function between the two
   paths.

The observable, end-to-end proof (built as a test in Milestone 4): run a command through
`runCommandWithProjections` with `#metadata ?~ object ["actor" .= "agent-7"]` and an inline
projection that copies `recorded`'s metadata `actor` field and `recorded`'s event id into
read-model columns; then query the read-model table and see the `actor` column equal
`"agent-7"` and the `source_event_id` column equal the appended event's id — columns that,
before this change, an inline projection could only leave `NULL`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-05-22): Add `metadata :: Maybe Value` to `RunCommandOptions`; default it to
      `Nothing`; thread it into `encodeEvents` via `encodeForAppendWithMetadata`. `cabal build
      keiro` succeeds.
- [x] M1 (2026-05-22): Add a keiro test proving a command with `#metadata ?~ ...` stores merged
      metadata (read back via `readStreamForward`). Test "command metadata is merged into stored
      event metadata" passes; asserts `{ "actor": "agent-7", "schemaVersion": 1 }` (schema
      version 1, not 2 — see Surprises & Discoveries).
- [x] M2 (2026-05-22): Add `reconstructRecorded` helper in `src/Keiro/Command.hs`.
- [x] M2 (2026-05-22): Refactor `runCommandWithSqlEvents`' append step to prepare events +
      capture time itself (via `prepareEventsIO` + `appendToStreamTx` + `runTransaction`) so it
      can build `RecordedEvent`s.
- [x] M2 (2026-05-22): Change the `runCommandWithSqlEvents` callback type to
      `[(co, RecordedEvent)] -> AppendResult -> Tx.Transaction a`; update `runCommandWithSql`.
- [ ] M2: Add a keiro test proving reconstructed `RecordedEvent`s match `readStreamForward`
      output for a multi-event batch (id, versions, positions, metadata, payload, createdAt).
      (Deferred to M4: the test suite only compiles once fixtures are updated.)
- [x] M3 (2026-05-22): Change `InlineProjection.apply` to `co -> RecordedEvent -> Tx.Transaction ()`;
      update `runCommandWithProjections` to feed `(co, recorded)` pairs. `cabal build keiro`
      succeeds clean (M2+M3 committed together — see Decision Log).
- [ ] M4: Update `jitsurei/src/Jitsurei/ReadModels.hs` to the new `apply` shape.
- [ ] M4: Update the keiro test fixtures (`counterInlineProjection`, the multi-event SQL
      test) to the new shapes.
- [ ] M4: Add the headline end-to-end test (metadata produced → surfaced → persisted).
- [ ] M4: Run `just haskell-test` (keiro + jitsurei) and record output.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (during implementation, 2026-05-22): the plan's M1 acceptance and Validation
  text claim `counterCodec` uses **schema version 2**; it actually uses **schema version 1**
  (`test/Main.hs`, `counterCodec = Codec { ..., schemaVersion = 1, ... }`). The schema-version-2
  codec in the suite is `orderCodec` (the `Keiro.Codec` describe block asserts
  `extractSchemaVersion (recordedFrom encoded) == 2` for it). The M1 metadata test therefore
  asserts the stored metadata equals `{ "actor": "agent-7", "schemaVersion": 1 }`. No code is
  affected — only the test's expected value.

- Discovery (during implementation, 2026-05-22): two `Keiro.ReadModel` tests —
  "waits for async projection cursor with PositionWait" and "times out when PositionWait target
  is not reached" — **fail on clean `master`** (verified via `git stash` + targeted run),
  independent of this plan. Both fail with a `Pattern match failure in 'do' block` on the
  `Right () <- ... upsertSubscriptionCursorStmt` line (the `subscriptions`-table cursor insert).
  They are pre-existing and out of scope here; the rest of `keiro-test` passes (75 examples,
  2 failures — exactly these two). The full-suite acceptance below is read as "0 *new* failures".

- Discovery (during planning, 2026-05-22): a batch append assigns **contiguous** per-event
  stream versions and global positions, which is what makes `RecordedEvent` reconstruction
  sound. The kiroku append SQL
  (`kiroku-store/src/Kiroku/Store/SQL.hs`, `appendNoStreamSQL` and the other three append
  CTEs) numbers events with `WITH ORDINALITY` and inserts them as
  `initial_version + idx` (stream version) and `initial_global_version + idx` (global
  position), `idx` being the 1-based position within the batch. The returned `AppendResult`
  is `(stream_id, initial_version + count, initial_global_version + count)` — i.e. the *last*
  event's positions. So event `i` (1-based) has `streamVersion = last - count + i` and
  `globalPosition = lastGlobal - count + i`. Milestone 2 includes a test that reads the
  events back and asserts the reconstruction matches byte-for-byte, so if kiroku ever breaks
  this invariant the suite fails loudly.


## Decision Log

Record every decision made while working on the plan.

- Decision: Close **both** the producing gap and the surfacing gap in this plan.
  Rationale: keiro's command path currently writes only `{ "schemaVersion": N }` into event
  metadata (`Keiro.Codec.encodeForAppend`), so surfacing metadata to inline projections
  without also giving callers a way to populate it would deliver an empty feature — exactly
  the "compiles but does nothing meaningful" failure PLANS.md warns against. Confirmed with
  the requester.
  Date: 2026-05-22

- Decision: The inline projection `apply` receives a full `RecordedEvent`
  (`apply :: co -> RecordedEvent -> Tx.Transaction ()`), not just the raw `Maybe Value`
  metadata.
  Rationale: the requester explicitly offered "EventMetadata (or the full `RecordedEvent`)".
  The full `RecordedEvent` is strictly more useful (it also carries event id, per-event
  stream version, per-event global position, and created-at) and — decisively — it is the
  *same* type the async projection's `applyRecorded :: RecordedEvent -> Tx.Transaction ()`
  already receives. A service can therefore share one projection function between the inline
  and async paths, which is precisely what "fully retire the polling path" requires.
  Date: 2026-05-22

- Decision: Drop `AppendResult` from the inline `apply` signature (do not keep both).
  Rationale: every datum the old `AppendResult` argument supplied is present, and more
  precisely (per-event rather than per-batch), on the `RecordedEvent`. The lone existing use
  in the jitsurei example reads `appendResult ^. #globalPosition` for a "last seen" cursor;
  `recorded ^. #globalPosition` is the correct per-event replacement. The lower-level
  `runCommandWithSqlEvents` callback still receives the batch-level `AppendResult` as its
  second argument for callers that need it (e.g. the outbox), so nothing is lost there.
  Date: 2026-05-22

- Decision: Metadata is attached at **per-command** granularity (one `Maybe Value` applied
  to every event the command emits), not per-event.
  Rationale: actor/agent/session describe the command invocation (who/what issued it), which
  is identical for every event a single decision produces. Per-command keeps the surface
  minimal (`encodeForAppendWithMetadata` already exists and already merges in the
  schema-version marker) and matches the request.
  Date: 2026-05-22

- Decision: Reconstruct `RecordedEvent` in keiro from the prepared events + `AppendResult`
  rather than reading the events back inside the transaction or changing kiroku to return
  recorded events.
  Rationale: reading back adds a query per command; changing kiroku's append return type is
  a much larger, cross-repo change. Reconstruction is sound given the contiguity invariant
  (see Surprises & Discoveries) and is guarded by a fidelity test. The dependency on that
  invariant is recorded under Interfaces and Dependencies.
  Date: 2026-05-22

- Decision: Do not switch the command path to kiroku's hook-aware append
  (`runTransactionAppendingResource`) / the `enrichEvent` store hook in this plan.
  Rationale: that path adds a `KirokuStoreResource` constraint to the whole command-function
  family — a broader change to the effect stack than this request needs. The new
  `RunCommandOptions.metadata` field covers the stated use case (caller-supplied ambient
  context). The enrich-hook route remains available as a future enhancement and is noted
  under Interfaces and Dependencies.
  Date: 2026-05-22

- Decision: Commit Milestones 2 and 3 together (one commit), not separately.
  Rationale: M2 changes the `runCommandWithSqlEvents` callback shape to
  `[(co, RecordedEvent)] -> AppendResult -> ...`; its only in-library consumer,
  `Keiro.Projection.runCommandWithProjections`, is updated in M3. A standalone M2 commit would
  leave the `keiro` library non-compiling (Projection.hs still feeds the old `[co]` callback),
  violating the "every commit builds" rule. The two are a single atomic breaking change to the
  callback contract and its sole internal consumer, so they share one commit. The plan's
  milestone *structure* (separate Progress items + validations) is preserved; only the commit
  boundary merges. Test fixtures and jitsurei remain intentionally broken until M4, as the plan
  already anticipates.
  Date: 2026-05-22

- Decision: No keiro database migration is required.
  Rationale: this change touches only Haskell types and the command transaction wiring. The
  metadata column already exists on the events table (kiroku's `events.metadata jsonb`).
  Read-model tables with actor/agent/session columns are owned by the consuming service (and,
  for the tests, by the test fixtures). `keiro-migrations/` is untouched.
  Date: 2026-05-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Everything in this plan lives in two repositories on disk. You only edit the first; the
second is a dependency you read for type definitions.

- `keiro` — this repository, working directory `/Users/shinzui/Keikaku/bokuno/keiro`. It is a
  Haskell event-sourcing framework. The relevant source files are:
  - `src/Keiro/Command.hs` — the command runner. Hydrates an aggregate, runs the decision,
    encodes the resulting events, appends them, and (in the `*WithSql*` variants) runs
    caller SQL in the same transaction. **Most edits land here.**
  - `src/Keiro/Projection.hs` — defines `InlineProjection`, `AsyncProjection`,
    `runCommandWithProjections`, and `applyAsyncProjection`.
  - `src/Keiro/Codec.hs` — defines `encodeForAppend`, `encodeForAppendWithMetadata`, and
    `metadataFor`. Already supports merging caller metadata; today the command path simply
    never calls the metadata-aware variant.
  - `src/Keiro/EventStream.hs` — defines the `EventStream` contract (transducer, codec,
    stream-name resolver). Read-only for this plan.
  - `jitsurei/src/Jitsurei/ReadModels.hs` — a worked example inline projection
    (`orderSummaryInlineProjection`). Must be updated to the new `apply` shape.
  - `test/Main.hs` — the keiro hspec suite, including the fixtures `counterInlineProjection`
    and `counterAsyncProjection` and the `counter_read_model` table. New and updated tests
    land here.
  - `jitsurei/test/Main.hs` — the jitsurei hspec suite that runs the order-summary inline
    projection end-to-end.

- `kiroku` — the event store, working directory
  `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (located via `mori registry show
  shinzui/kiroku --full`). You do **not** edit it. You read these types:
  - `kiroku-store/src/Kiroku/Store/Types.hs` — `EventData`, `RecordedEvent`, `AppendResult`,
    `EventId`, `EventType`, `StreamVersion`, `GlobalPosition`, `StreamId`.
  - `kiroku-store/src/Kiroku/Store/Transaction.hs` — `prepareEventsIO`, `appendToStreamTx`,
    `PreparedEvent`, `runTransaction`, `runTransactionNoRetry`, `AppendConflict`,
    `appendConflictToStoreError`.
  - `kiroku-store/src/Kiroku/Store/Effect.hs` — the `PreparedEvent` record fields.

The three kiroku types this plan revolves around, reproduced so the plan is self-contained:

```haskell
-- kiroku-store/src/Kiroku/Store/Types.hs

-- | Result of a successful append. Carries only the LAST event's positions.
data AppendResult = AppendResult
    { streamId       :: !StreamId        -- the appended-to stream's surrogate id
    , streamVersion  :: !StreamVersion   -- the LAST event's stream version
    , globalPosition :: !GlobalPosition  -- the LAST event's global position
    }

-- | What comes back from reading events. The shape we will reconstruct.
data RecordedEvent = RecordedEvent
    { eventId          :: !EventId
    , eventType        :: !EventType
    , streamVersion    :: !StreamVersion   -- per-event
    , globalPosition   :: !GlobalPosition  -- per-event
    , originalStreamId :: !StreamId
    , originalVersion  :: !StreamVersion
    , payload          :: !Value
    , metadata         :: !(Maybe Value)   -- actor/agent/session live here
    , causationId      :: !(Maybe UUID)
    , correlationId    :: !(Maybe UUID)
    , createdAt        :: !UTCTime
    }
```

```haskell
-- kiroku-store/src/Kiroku/Store/Effect.hs
-- | An event with a guaranteed event id (pre-generated if the caller did not supply one).
data PreparedEvent = PreparedEvent
    { peEventId       :: !UUID
    , peEventType     :: !EventType
    , pePayload       :: !Value
    , peMetadata      :: !(Maybe Value)
    , peCausationId   :: !(Maybe UUID)
    , peCorrelationId :: !(Maybe UUID)
    }
```

How the current command transaction is structured (the part we change). In
`src/Keiro/Command.hs`, `runCommandWithSqlEvents` builds a plan, then in `appendWithSqlOnce`
calls kiroku's `runTransactionAppending`, passing the encoded events and a continuation:

```haskell
-- src/Keiro/Command.hs (current)
runCommandWithSqlEvents ::
  ... =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  ([co] -> AppendResult -> Tx.Transaction a) ->   -- <-- callback: decoded events + AppendResult
  Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co), Maybe a))
...
    appendWithSqlOnce remaining current events encoded = do
      liftIO (options ^. #beforeAppend)
      outcome <- tryError @StoreError $
        runTransactionAppending                       -- <-- kiroku prepares + commits internally
          ((eventStream ^. #resolveStreamName) targetStream)
          (expectedVersion (current ^. #streamVersion))
          encoded
          ( \appendResult -> do
              userValue <- afterAppend events appendResult
              pure (appendResult, userValue)
          )
      ...
```

`runTransactionAppending` performs `prepareEventsIO` (which generates the UUIDv7 event ids)
and captures the current time *inside itself*, so keiro never sees the prepared events or
the timestamp — which is exactly what we need to build `RecordedEvent`s. Milestone 2 inlines
the equivalent of `runTransactionAppending` into keiro so those values are in scope.

The inline projection surface today:

```haskell
-- src/Keiro/Projection.hs (current)
data InlineProjection co = InlineProjection
  { name  :: !Text
  , apply :: !(co -> AppendResult -> Tx.Transaction ())   -- <-- no metadata visible
  }

data AsyncProjection = AsyncProjection
  { name           :: !Text
  , subscriptionName :: !Text
  , applyRecorded  :: !(RecordedEvent -> Tx.Transaction ())  -- <-- already gets RecordedEvent
  , idempotencyKey :: !(RecordedEvent -> EventId)
  }
```

Note the target end-state: `InlineProjection.apply` becomes
`co -> RecordedEvent -> Tx.Transaction ()`, deliberately mirroring
`AsyncProjection.applyRecorded` with the decoded `co` added for convenience.


## Plan of Work

The work is four milestones, each independently buildable and verifiable. Milestones 1 and 2
are additive infrastructure; Milestone 3 makes the breaking surface change; Milestone 4
updates every call site and adds the headline proof. Commit after each milestone with the
trailers shown in "Concrete Steps".


### Milestone 1 — Let a command stamp metadata onto its events

Scope: add an optional, per-command metadata blob to `RunCommandOptions` and route it through
event encoding. At the end, a command run with a metadata blob stores events whose
`metadata` JSON contains both the caller's keys and the schema-version marker; default
behavior (no metadata field set) is byte-for-byte unchanged.

Edits, all in `src/Keiro/Command.hs`:

1. Add a field to `RunCommandOptions`:

   ```haskell
   data RunCommandOptions = RunCommandOptions
     { retryLimit :: !Int
     , pageSize   :: !Int32
     , eventIds   :: ![EventId]
     , beforeAppend :: !(IO ())
     , tracer     :: !(Maybe Tracer)
     , metadata   :: !(Maybe Value)
     -- ^ Optional JSON merged into every event's metadata for this command
     --   invocation. Carries ambient context such as actor type, agent id,
     --   and session id. The codec always adds a @schemaVersion@ key; the
     --   keys here are merged on top (see 'Keiro.Codec.metadataFor'). When
     --   'Nothing', events carry only the schema-version marker, exactly as
     --   before this field existed.
     }
   ```

   `Value` is already in scope via `Keiro.Prelude` (it re-exports `Data.Aeson (Value)`).

2. Set the default in `defaultRunCommandOptions`:

   ```haskell
   defaultRunCommandOptions = RunCommandOptions
     { retryLimit = 3
     , pageSize = 256
     , eventIds = []
     , beforeAppend = pure ()
     , tracer = Nothing
     , metadata = Nothing
     }
   ```

3. Change `encodeEvents` to accept the metadata and use the metadata-aware codec entry point.
   Today:

   ```haskell
   encodeEvents :: Codec co -> [co] -> Either CommandError [EventData]
   encodeEvents codec = Prelude.mapM (mapLeft EncodeFailed . encodeForAppend codec)
   ```

   becomes:

   ```haskell
   encodeEvents :: Codec co -> Maybe Value -> [co] -> Either CommandError [EventData]
   encodeEvents codec md =
     Prelude.mapM (mapLeft EncodeFailed . encodeForAppendWithMetadata codec md)
   ```

   `encodeForAppendWithMetadata` is already exported from `Keiro.Codec` but is **not** yet
   imported in `Keiro.Command` — add it to the existing
   `import Keiro.Codec (Codec, CodecError, decodeRecorded, encodeForAppend)` list.

4. Update the single call site in `prepareCommandPlan` (it already has `options` in scope):

   ```haskell
   toPlan events =
     CommandAppend current events
       . assignEventIds (options ^. #eventIds)
       <$> encodeEvents (eventStream ^. #eventCodec) (options ^. #metadata) events
   ```

Acceptance: build succeeds; a new test (described under Validation) appends with
`#metadata ?~ object ["actor" .= ("agent-7" :: Text)]`, reads the stream back with
`readStreamForward`, and finds `recorded ^. #metadata` equal to
`Just (object ["actor" .= "agent-7", "schemaVersion" .= (N :: Int)])` where `N` is the
codec's schema version (2 for `counterCodec`).


### Milestone 2 — Reconstruct RecordedEvent and thread it through the command transaction

Scope: make `runCommandWithSqlEvents` prepare events and capture the timestamp itself so it
can build a `RecordedEvent` per appended event, and change its callback to receive
`[(co, RecordedEvent)]`. At the end, the lower-level SQL command API hands callers both the
decoded event and its full recorded form; `runCommandWithProjections` (changed in M3) builds
on this.

Edits, all in `src/Keiro/Command.hs`:

1. Adjust imports. Remove `runTransactionAppending` from the
   `import Kiroku.Store.Transaction (...)` line and replace it with the lower-level pieces:

   ```haskell
   import Kiroku.Store.Transaction
     ( prepareEventsIO
     , appendToStreamTx
     , PreparedEvent
     , runTransaction
     , appendConflictToStoreError
     )
   ```

   Add `($>)` for the condemn-and-return idiom and widen the kiroku-types import so the
   `RecordedEvent` constructor and `GlobalPosition` constructor are available:

   ```haskell
   import Data.Functor (($>))
   ```

   In the existing `import Kiroku.Store.Types (...)` list, change `RecordedEvent` to
   `RecordedEvent (..)` and `GlobalPosition` to `GlobalPosition (..)` (the `StreamVersion (..)`
   import is already in the list, and `EventId` is already imported).

2. Add the reconstruction helper near `appendedResult`:

   ```haskell
   {- | Rebuild the per-event 'RecordedEvent' values for a just-appended batch.

   The store assigns each event in a batch a contiguous stream version and
   global position: event @i@ (1-based) gets @last - count + i@ for both
   counters, where @last@ is the position the 'AppendResult' reports for the
   final event and @count@ is the batch size. (The kiroku append SQL numbers
   events with @WITH ORDINALITY@ and inserts @initial + idx@; see EP-27's
   Surprises & Discoveries.) We therefore reconstruct each 'RecordedEvent'
   exactly, rather than reading the batch back. The @createdAt@ is the same
   timestamp 'prepareEventsIO'/'appendToStreamTx' used for the insert.

   This is a source append (events are written to their own stream), so
   @streamVersion == originalVersion@ and @originalStreamId@ is the appended
   stream's id, per the 'RecordedEvent' contract.
   -}
   reconstructRecorded :: AppendResult -> UTCTime -> [PreparedEvent] -> [RecordedEvent]
   reconstructRecorded appendResult now prepared =
     Prelude.zipWith mk [0 ..] prepared
     where
       count = Prelude.length prepared
       StreamVersion lastSv = appendResult ^. #streamVersion
       GlobalPosition lastGp = appendResult ^. #globalPosition
       firstSv = lastSv Prelude.- Prelude.fromIntegral count Prelude.+ 1
       firstGp = lastGp Prelude.- Prelude.fromIntegral count Prelude.+ 1
       mk :: Int64 -> PreparedEvent -> RecordedEvent
       mk i prepared' = RecordedEvent
         { eventId = EventId (prepared' ^. #peEventId)
         , eventType = prepared' ^. #peEventType
         , streamVersion = StreamVersion (firstSv Prelude.+ i)
         , globalPosition = GlobalPosition (firstGp Prelude.+ i)
         , originalStreamId = appendResult ^. #streamId
         , originalVersion = StreamVersion (firstSv Prelude.+ i)
         , payload = prepared' ^. #pePayload
         , metadata = prepared' ^. #peMetadata
         , causationId = prepared' ^. #peCausationId
         , correlationId = prepared' ^. #peCorrelationId
         , createdAt = now
         }
   ```

3. Change the callback type of `runCommandWithSqlEvents` from
   `[co] -> AppendResult -> Tx.Transaction a` to
   `[(co, RecordedEvent)] -> AppendResult -> Tx.Transaction a`, and rewrite
   `appendWithSqlOnce` to prepare events, capture time, append via `appendToStreamTx`, build
   the `RecordedEvent`s, and pass the zipped pairs to the callback. The new body mirrors
   kiroku's own `runTransactionAppendingWith` (auto-retrying `runTransaction`, condemn on
   conflict) but with the prepared events and timestamp in scope:

   ```haskell
   appendWithSqlOnce remaining current events encoded = do
     liftIO (options ^. #beforeAppend)
     prepared <- prepareEventsIO encoded
     now <- liftIO getCurrentTime
     let streamName = (eventStream ^. #resolveStreamName) targetStream
         expected = expectedVersion (current ^. #streamVersion)
         body = do
           appended <- appendToStreamTx streamName expected prepared now
           case appended of
             Left conflict ->
               Tx.condemn $> Left (appendConflictToStoreError conflict)
             Right appendResult -> do
               let recordeds = reconstructRecorded appendResult now prepared
               userValue <- afterAppend (Prelude.zip events recordeds) appendResult
               pure (Right (appendResult, userValue))
     outcome <- tryError @StoreError (runTransaction body)
     case outcome of
       Right (Right (appendResult, userValue)) -> do
         writeSnapshotIfNeeded eventStream current events appendResult
         pure (Right (appendedResult targetStream appendResult (Prelude.length encoded), Just userValue))
       Right (Left storeError) ->
         retryOrFail options attempt remaining storeError
       Left (_, storeError) ->
         retryOrFail options attempt remaining storeError
   ```

   `getCurrentTime` is in scope via `Keiro.Prelude`. `Tx.condemn` is in scope via the
   existing `import "hasql-transaction" Hasql.Transaction qualified as Tx`.

   Note on the reserved `$all` stream: `appendToStreamTx` does not itself reject the reserved
   `$all` stream name (the old `runTransactionAppending` did so up front). keiro's command
   path resolves stream names through `eventStream ^. #resolveStreamName`, which is
   application-controlled and never yields `$all`, so this is not a regression in practice.
   This is recorded as a deliberate scoping decision; see Idempotence and Recovery.

4. Update `runCommandWithSql` (the variant that ignores events) — only its inner lambda's
   first argument changes name/type, and it already ignores it:

   ```haskell
   runCommandWithSql options eventStream targetStream command afterAppend =
     runCommandWithSqlEvents options eventStream targetStream command (\_ appendResult -> afterAppend appendResult)
   ```

   No change is needed beyond confirming the `\_` still type-checks against
   `[(co, RecordedEvent)]`.

Acceptance: build succeeds; a new test (under Validation) runs a *multi-event* command
through `runCommandWithSqlEvents`, captures the `[(co, RecordedEvent)]`, then reads the same
stream back with `readStreamForward` and asserts that for every event the reconstructed
`RecordedEvent` equals the stored one on `eventId`, `eventType`, `streamVersion`,
`globalPosition`, `originalStreamId`, `originalVersion`, `payload`, and `metadata`. (The
stored `globalPosition` is available because `readStreamForward` returns it; if the read API
in use returns `0` for global position on plain stream reads, assert positions via a `$all`
read or `readCategory` instead — see Validation for the exact statement used.)


### Milestone 3 — Change the inline projection surface

Scope: change `InlineProjection.apply` to `co -> RecordedEvent -> Tx.Transaction ()` and feed
it from `runCommandWithProjections`. At the end, the framework's inline-projection contract
exposes the full recorded event.

Edits in `src/Keiro/Projection.hs`:

1. Change the record:

   ```haskell
   data InlineProjection co = InlineProjection
     { name  :: !Text
     , apply :: !(co -> RecordedEvent -> Tx.Transaction ())
     }
     deriving stock (Generic)
   ```

2. Update `runCommandWithProjections` to consume the new
   `[(co, RecordedEvent)]` callback shape. The current implementation loops projections on
   the outside and events on the inside; preserve that ordering:

   ```haskell
   runCommandWithProjections options eventStream targetStream command projections = do
     result <-
       runCommandWithSqlEvents
         options
         eventStream
         targetStream
         command
         ( \pairs _appendResult ->
             traverse_
               (\projection ->
                  traverse_
                    (\(event, recorded) -> (projection ^. #apply) event recorded)
                    pairs)
               projections
         )
     pure (fmap Prelude.fst result)
   ```

   `AppendResult` is still referenced in `runCommandWithSqlEvents`' type, so keep its import;
   it is simply unused in this lambda (hence `_appendResult`).

Acceptance: `cabal build all` succeeds for the library (call-site test/example breakage in
`jitsurei` and `test/Main.hs` is fixed in Milestone 4 and is expected until then; build the
library target alone here, e.g. `cabal build keiro`).


### Milestone 4 — Update call sites and prove the end-to-end behavior

Scope: bring the example projection and the test fixtures up to the new shape, and add the
headline test that proves metadata flows command → event → inline projection → read-model
column. At the end, `just haskell-test` is green and the new behavior is demonstrated.

Edits:

1. `jitsurei/src/Jitsurei/ReadModels.hs`:
   - Change the import `Kiroku.Store.Types (AppendResult, GlobalPosition (..))` to
     `Kiroku.Store.Types (RecordedEvent, GlobalPosition (..))`.
   - Change `applyOrderEvent :: OrderEvent -> AppendResult -> Tx.Transaction ()` to
     `applyOrderEvent :: OrderEvent -> RecordedEvent -> Tx.Transaction ()` and
     `updateStatus :: OrderId -> Text -> AppendResult -> Tx.Transaction ()` to take a
     `RecordedEvent`.
   - Replace every `appendResult ^. #globalPosition` with `recorded ^. #globalPosition`
     (rename the bound parameter from `appendResult` to `recorded` throughout these two
     functions).

2. `test/Main.hs` — update fixtures and the affected test:
   - `counterInlineProjection`: change `apply = \event appendResult -> ...` to
     `apply = \event recorded -> ...`. Where it previously wrote `Nothing` for
     `source_event_id`, write `Just (eventIdToUuid (recorded ^. #eventId))` (the helper
     `eventIdToUuid` already exists in the file). Replace
     `globalPositionToInt (appendResult ^. #globalPosition)` with
     `globalPositionToInt (recorded ^. #globalPosition)`.
   - The test "passes the complete multi-event batch to inline SQL in append order" calls
     `runCommandWithSqlEvents ... (\events _ -> pure events)` and asserts
     `observed == [CounterAdded 8, CounterAudited 8]`. Change the lambda to
     `(\pairs _ -> pure (Prelude.map Prelude.fst pairs))` (or `fmap fst pairs`) so it still
     yields the decoded events; the assertion is unchanged.
   - Extend `counter_read_model` with a nullable metadata column to demonstrate metadata
     persistence. In `initializeCounterReadModelTable` add `actor TEXT` (nullable). Widen
     `upsertCounterReadModelStmt` to a 5-tuple `(Text, Int64, Int64, Maybe UUID, Maybe Text)`
     inserting `actor`, using `contrazip5` (already imported pattern: the file imports
     `contrazip2/3/4`; add `contrazip5` to that import). Update both the `counterInline`
     fixture and the `counterAsyncProjection` fixture call sites to pass the new column
     (`counterAsyncProjection` passes `Nothing`; the inline fixture extracts the `actor`
     string from `recorded ^. #metadata`).
   - Add a small JSON accessor in the test module:

     ```haskell
     metadataActor :: RecordedEvent -> Maybe Text
     metadataActor recorded = do
       Aeson.Object o <- recorded ^. #metadata
       Aeson.String s <- KeyMap.lookup "actor" o   -- import Data.Aeson.KeyMap qualified as KeyMap
       pure s
     ```

   - Add the headline test in the `Keiro.ReadModel` describe block:

     ```haskell
     it "inline projection populates actor and source_event_id from command metadata" $ \storeHandle -> do
       Right () <- Store.runStoreIO storeHandle initializeReadModelSchema
       Right () <- Store.runStoreIO storeHandle $
         Store.runTransaction initializeCounterReadModelTable
       let target = stream "read-model-inline-metadata" :: Stream CounterEventStream
           opts = defaultRunCommandOptions
             & #metadata ?~ Aeson.object ["actor" Aeson..= ("agent-7" :: Text)]
       Right (Right _) <- Store.runStoreIO storeHandle $
         runCommandWithProjections opts counterEventStream target (Add 5) [counterInlineProjection]
       Right row <- Store.runStoreIO storeHandle $
         Store.runTransaction (Tx.statement "inline" selectCounterMetaStmt)
       -- selectCounterMetaStmt returns (amount, actor, source_event_id)
       row `shouldSatisfy` \(amount, actor, srcId) ->
         amount == 5 && actor == Just "agent-7" && isJust srcId
     ```

     Add the supporting `selectCounterMetaStmt :: Statement Text (Int64, Maybe Text, Maybe UUID)`
     near the other counter statements (a `SELECT amount, actor, source_event_id FROM
     counter_read_model WHERE model_id = $1`). This single test proves the whole chain:
     metadata produced by the command (M1), surfaced as `RecordedEvent` to the inline apply
     (M2/M3), and persisted into previously-`NULL` columns.

3. `jitsurei/test/Main.hs`: build and run; the order-summary inline projection's behavior is
   unchanged (it still writes `last_seen`), so this suite should pass without edits beyond
   what compiles. If it references `apply` directly or asserts on a value that came from
   `AppendResult.globalPosition`, adjust to `recorded ^. #globalPosition` — verify during
   implementation and record any change in Progress.

Acceptance: `just haskell-test` passes (it runs `cabal test keiro-test`, `cabal test
jitsurei-test`, and the jitsurei diagram check). The headline test passes. Record the
transcript in Concrete Steps.


## Concrete Steps

All commands run from the keiro working directory unless noted:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

The test suites start an ephemeral PostgreSQL automatically (via `ephemeral-pg` /
`Pg.withCached`), so no database needs to be running first.

Milestone 1 — build the library after the `RunCommandOptions`/`encodeEvents` change:

```bash
cabal build keiro
```

Expected: compiles with no errors. (Warnings about unused imports, if any, should be fixed
before committing.)

Milestone 2 — build the library after the reconstruction + transaction refactor:

```bash
cabal build keiro
```

Milestone 3 — build the library after the `InlineProjection` surface change:

```bash
cabal build keiro
```

Expected: the `keiro` library compiles. The `keiro-test` and `jitsurei` targets will not
compile until Milestone 4 (their call sites still use the old `apply` shape); that is
expected.

Milestone 4 — build everything and run the suites:

```bash
cabal build all
just haskell-test
```

Expected (abridged) transcript:

```text
Keiro.Command
  ...
  passes the complete multi-event batch to inline SQL in append order [✔]
  command metadata is merged into stored event metadata [✔]
  reconstructed RecordedEvents match the stored batch [✔]
Keiro.ReadModel
  queries inline projection with Strong consistency [✔]
  inline projection populates actor and source_event_id from command metadata [✔]
  ...
Finished in N seconds
M examples, 0 failures
```

Commit after each milestone. Every commit must carry both trailers (an ExecPlan and the
active Intention). Example for Milestone 1:

```text
feat(command): add per-command metadata option to RunCommandOptions

Thread an optional metadata JSON blob through the command path so callers
can stamp ambient context (actor/agent/session) onto every event a command
appends. Encodes via encodeForAppendWithMetadata; default is Nothing.

ExecPlan: docs/plans/27-surface-recordedevent-and-command-metadata-to-inline-projections.md
Intention: intention_01ks6z7fxpeydb07j2p3epvkts
```


## Validation and Acceptance

Validation is behavioral and lives in the hspec suites. The three new/changed tests, by the
behavior they prove:

1. **Command metadata is stored (M1).** Append with
   `defaultRunCommandOptions & #metadata ?~ object ["actor" .= ("agent-7" :: Text)]` against
   `counterEventStream`, then `Store.readStreamForward (StreamName "...") (StreamVersion 0) 10`
   and check the single event's `metadata` field equals
   `Just (object ["actor" .= "agent-7", "schemaVersion" .= (2 :: Int)])`. Proves the producing
   gap is closed and that caller keys merge with the schema-version marker rather than
   replacing it. (Schema version 2 is what `counterCodec` uses — confirm against the codec in
   `test/Main.hs`.)

2. **Reconstruction is faithful (M2).** Run a multi-event command (the existing
   `multiCounterEventStream` emits two events per `Add`) through `runCommandWithSqlEvents`,
   capturing `pairs :: [(co, RecordedEvent)]`. Then read the events back and assert each
   reconstructed `RecordedEvent` matches the stored event. Use a read path that returns the
   real global position. `Store.readStreamForward` returns `0` for `globalPosition` on plain
   stream reads (see the SQL note `For stream reads, global_position is set to 0`), so assert
   global positions via `Store.readCategory (CategoryName "counter") (GlobalPosition 0) N` or
   `Store.readAllForward`, which carry true global positions; assert `eventId`, `eventType`,
   `streamVersion`, `payload`, and `metadata` against `readStreamForward`, and `globalPosition`
   against the category/all read. This proves the contiguity-based reconstruction is correct
   and guards the kiroku invariant.

3. **End-to-end metadata into a read model (M4, headline).** The test in Milestone 4 step 2:
   command with `#metadata ?~ {actor: agent-7}` + inline projection → query
   `counter_read_model` and observe `actor = 'agent-7'` and a non-null `source_event_id`.
   Proves the full chain and directly demonstrates the requester's blocked scenario
   ("inline projections had to write them NULL") is unblocked.

Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
just haskell-test
```

Success is `0 failures` across `keiro-test` and `jitsurei-test`. A failure in test 2 with a
positions mismatch would indicate kiroku changed its batch-numbering invariant; investigate
the append SQL before "fixing" the test.


## Idempotence and Recovery

The source edits are ordinary code changes and can be re-applied or reverted with git; no
data migration is involved (see the Decision Log entry on migrations). Re-running
`cabal build` and `just haskell-test` is safe and repeatable; the test harness creates and
tears down its own ephemeral PostgreSQL per run, so repeated runs do not accumulate state.

Behavioral safety notes:

- The transaction refactor in Milestone 2 preserves the existing retry semantics. As before,
  event ids and the timestamp are generated *once*, outside the transaction body, so when
  PostgreSQL retries the body on a serialization conflict the same ids and `createdAt` are
  reused — appends remain idempotent across retries, and the reconstructed `RecordedEvent`s
  always reflect the `AppendResult` of the attempt that actually committed.
- keiro's own optimistic-concurrency retry (`retryOrFail`, on `WrongExpectedVersion` /
  `StreamAlreadyExists`) re-hydrates and re-enters `appendWithSqlOnce`, which re-prepares a
  fresh batch — unchanged from today.
- The `$all` reserved-stream up-front rejection that `runTransactionAppending` performed is
  not replicated, because the command path's stream name comes from
  `eventStream ^. #resolveStreamName` and is application-controlled; it never resolves to
  `$all`. If a future change makes user-supplied stream names reachable here, restore the
  guard by checking the resolved `StreamName` against `"$all"` before
  `prepareEventsIO`/`appendToStreamTx` and returning `Left (StoreFailed (ReservedStreamName …))`.


## Interfaces and Dependencies

End-state signatures that must exist:

- `src/Keiro/Command.hs`
  - `RunCommandOptions` gains `metadata :: !(Maybe Value)`; `defaultRunCommandOptions`
    sets it to `Nothing`.
  - `encodeEvents :: Codec co -> Maybe Value -> [co] -> Either CommandError [EventData]`.
  - `reconstructRecorded :: AppendResult -> UTCTime -> [PreparedEvent] -> [RecordedEvent]`
    (module-internal; not exported).
  - `runCommandWithSqlEvents :: ... -> ([(co, RecordedEvent)] -> AppendResult -> Tx.Transaction a) -> ...`.
  - `runCommandWithSql` unchanged in signature (its callback ignores the events argument).

- `src/Keiro/Projection.hs`
  - `InlineProjection co` with `apply :: !(co -> RecordedEvent -> Tx.Transaction ())`.
  - `runCommandWithProjections` unchanged in signature; its internal callback adapts to the
    new `[(co, RecordedEvent)]` shape.
  - `AsyncProjection` and `applyAsyncProjection` unchanged.

Dependencies and why:

- `Keiro.Codec.encodeForAppendWithMetadata` (already exported) — merges caller metadata with
  the schema-version marker via `metadataFor`. Reused rather than reimplemented.
- `Kiroku.Store.Transaction.{prepareEventsIO, appendToStreamTx, runTransaction,
  appendConflictToStoreError}` and `Kiroku.Store.Transaction.PreparedEvent` — the lower-level
  building blocks of `runTransactionAppending`, used directly so keiro can see the prepared
  events (event ids + metadata) and the captured timestamp needed to reconstruct
  `RecordedEvent`s. `runTransaction` (auto-retry) matches the retry behavior of the
  `runTransactionAppending` it replaces.
- `Kiroku.Store.Types.{RecordedEvent (..), AppendResult, GlobalPosition (..), StreamVersion (..),
  EventId}` — the types reconstructed and threaded.

Invariant this plan depends on (record and guard, do not silently rely on):

- **Contiguous batch numbering.** A single batch append assigns event `i` (1-based) the
  stream version `last - count + i` and global position `lastGlobal - count + i`, where
  `(last, lastGlobal)` are the `AppendResult` values and `count` is the batch size. This holds
  because kiroku's append CTEs number events with `WITH ORDINALITY` and insert
  `initial_version + idx` / `initial_global_version + idx`
  (`kiroku-store/src/Kiroku/Store/SQL.hs`). The Milestone 2 fidelity test fails if this
  invariant ever changes.

Future enhancement, explicitly out of scope (recorded so the next contributor sees it):

- Running kiroku's `enrichEvent` store hook in the command path (via
  `runTransactionAppendingResource`) would let a store-wide hook inject ambient metadata
  uniformly across direct appends and command appends, at the cost of adding a
  `KirokuStoreResource` constraint to the command-function family. The per-command
  `RunCommandOptions.metadata` field added here is the targeted, lower-blast-radius answer to
  this request; the hook route can layer on later.
