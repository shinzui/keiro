# keiro snapshot strategy and hydration acceleration

This document fixes how keiro persists, reads, and rebuilds *snapshots* — periodically-written serializations of an aggregate's joint state `(s, RegFile rs)` — so that hydration of a long-lived stream does not have to re-fold every event from version 0. It is the design output of EP-4 of the research-foundation MasterPlan (`docs/masterplans/1-keiro-research-foundation.md`).

It is design-only: no spike. The reasoning is recorded in EP-4's plan (`docs/plans/4-snapshot-strategy-and-hydration-acceleration.md`) — snapshots are pure storage plumbing whose every component (a sidecar table, a state codec, a hydration short-circuit, a fall-through on codec-version mismatch) has been implemented many times in industry and would not retire any unknown if prototyped here. The EP-1 spike (`spikes/command-cycle/`) and the EP-2 spike (`spikes/codec/`) already validate the moving pieces this design plugs into: the Streamly hydration pipeline keiro short-circuits, and the value-level codec pattern keiro reuses for the snapshot codec.

This document is consumed by EP-1 (the command cycle's hydration phase short-circuits to a snapshot when one is available), EP-2 (the snapshot codec is a sibling of `Codec e`, structurally similar but versioned at the aggregate level), EP-3 (subscription/projection lifecycles do *not* use snapshots — recorded explicitly so reviewers do not look for snapshot use there), EP-5 (workflow-engine roadmap; long-lived workflow streams will use this same primitive), and EP-6 (consolidates the keiroku-side and keiki-side gaps this design identifies).


## 1. Problem statement

EP-1's `runCommand` hydrates an aggregate by calling `Kiroku.Store.Read.readStreamForward sn (StreamVersion 0) maxBound`, paginating into a Streamly `Stream (Eff es) RecordedEvent`, decoding each event via the `Codec e` instance from EP-2, and folding the decoded events through `applyEvent` into the joint state `(s, RegFile rs)`. The pipeline shape is `Stream → Fold` and is constant-memory in the *number of events resident at any one time* (one page, default 256), but its total work is linear in the *cumulative stream length*. For an aggregate with thousands of events — which both EP-3's process-manager state streams (`pm-OrderFulfillment-<id>`) and EP-5's long-lived workflow streams will routinely produce — replaying the entire history on every command is wasteful, and the wastage scales with the wall-clock age of the stream.

Industry-standard remediation is the *snapshot*: a periodically-persisted serialization of the joint state at a particular `StreamVersion`. Hydration consults the snapshot first, then reads only events newer than the snapshot's version, then folds those into the snapshot's state. The cost of hydration becomes proportional to the snapshot policy's events-since-snapshot threshold rather than the absolute stream length.

Two snapshot designs were surveyed in the prior-art document (`docs/research/05-workflow-prior-art.md`):

- **Marten** writes snapshots to a sidecar table (`mt_doc_<aggregate>`) keyed by stream id, with the snapshot version recorded alongside. Hydration loads snapshot, reads events past the snapshot version, folds. Operators can `TRUNCATE` and rebuild safely. Marten's only structural quirk is the high-water-mark for *async subscribers* — which keiro does not need because kiroku's Strategy E gives gap-free contiguous global positions; see EP-3 (`docs/research/08-subscription-and-process-manager-design.md` §4) for the rejection of HWM. Snapshot reads are per-stream and do not interact with HWM in any case.
- **Akka Persistence** has a pluggable snapshot store (JDBC/Cassandra/R2DBC). Snapshots are written periodically; the journal and the snapshot store are independent persistence concerns. Akka's pluggability is rejected by the parent MasterPlan's "Postgres-only" decision (recorded in the MasterPlan's Decision Log under "Adopt the prior-art guidance from `docs/research/05-workflow-prior-art.md`"), but the *concept* — independent sidecar storage that the loader prefers when available — is exactly what we want.
- **Eventide / message-db** does not standardize a snapshot mechanism; the consensus is "aggregates rebuild from events on each command (optionally with snapshots)." This is consistent with our design: snapshots are an optimization, never a substitute for the event log.

keiro adopts the Marten shape: a single sidecar table, keyed on the stream id kiroku already assigns, holding one snapshot row per stream, with a state-codec-version field that lets the reader fall through to full replay on schema change. The snapshot codec itself is value-level (a record of functions), structurally analogous to EP-2's `Codec e` but with its own versioning semantics (versioned at the aggregate level, not per record).

The user-visible behaviour the eventual library will deliver: aggregate authors annotate their `EventStream` value with a snapshot policy (`snapshotPolicyEvery 100`, `snapshotPolicyOnTerminal isCompleted`, or `snapshotPolicyNever`); hydration paths transparently use the latest snapshot when present and fall back to full replay when not; operators can drop or truncate the `keiro_snapshots` table at any time without affecting correctness.


## 2. Storage layout

Snapshots live in a *sidecar* table — independent of kiroku's `events` and `stream_events` — created by a keiro-owned migration. The decision to use a sidecar (rather than encoding snapshots as events on a derived stream, or as in-event metadata) is recorded in EP-4's Decision Log: a sidecar table is independently GC'able, schema-evolvable, and does not require any change to kiroku's append semantics. The relevant kiroku schema (`kiroku-store/sql/schema.sql`) is:

    CREATE TABLE IF NOT EXISTS streams (
        stream_id      BIGSERIAL    PRIMARY KEY,
        stream_name    TEXT         NOT NULL,
        category       TEXT         GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED,
        stream_version BIGINT       NOT NULL DEFAULT 0,
        created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
        deleted_at     TIMESTAMPTZ,
        CONSTRAINT ix_streams_stream_name UNIQUE (stream_name)
    );

The keiro-owned migration adds:

    CREATE TABLE IF NOT EXISTS keiro_snapshots (
        stream_id            BIGINT       NOT NULL,
        stream_name          TEXT         NOT NULL,
        stream_version       BIGINT       NOT NULL,
        state                JSONB        NOT NULL,
        state_codec_version  INTEGER      NOT NULL,
        regfile_shape_hash   TEXT         NOT NULL,
        taken_at             TIMESTAMPTZ  NOT NULL DEFAULT now(),
        PRIMARY KEY (stream_id),
        CONSTRAINT fk_keiro_snapshots_stream
            FOREIGN KEY (stream_id) REFERENCES streams(stream_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS ix_keiro_snapshots_stream_name
        ON keiro_snapshots(stream_name);

    CREATE INDEX IF NOT EXISTS ix_keiro_snapshots_taken_at
        ON keiro_snapshots(taken_at);

Column-by-column rationale:

- **`stream_id BIGINT NOT NULL`, primary key.** kiroku already assigns one BIGSERIAL `stream_id` per `stream_name`. Reusing it as the snapshot's primary key makes the snapshot lookup an index-only scan. Choosing `stream_id` (rather than `stream_name`) as the key keeps the row narrow (8 bytes vs. variable-length text) and aligns with kiroku's read paths, which already work in terms of `stream_id`. The PK is *not* `(stream_id, stream_version)` because we keep only the most recent snapshot per stream — see the write path (§7) for the `ON CONFLICT DO UPDATE` shape that maintains this invariant.

- **`stream_name TEXT NOT NULL`.** Denormalized from `streams(stream_name)` for operator readability. An operator running `psql -c 'SELECT stream_name, stream_version, taken_at FROM keiro_snapshots ORDER BY taken_at DESC LIMIT 50'` should see human-meaningful names without joining. The denormalization is safe because kiroku does not currently expose stream renaming, and adding it would itself be a kiroku-side breaking change recorded in EP-6.

- **`stream_version BIGINT NOT NULL`.** The `StreamVersion` (per-stream monotonic counter, not the global position) of the last event included in the snapshotted state. The hydration short-circuit uses this as the start of the tail-replay range: `readStreamForward sn (snapshot.streamVersion + 1) maxBound`. Using `StreamVersion` rather than `globalPosition` is deliberate — see the second to last paragraph of §6 for why per-stream versions are the right cursor.

- **`state JSONB NOT NULL`.** The encoded joint state `(s, RegFile rs)`. JSONB rather than `bytea` because (a) the joint state is opaque to operators in any case (it is keiki's typed product, not a domain object an operator would inspect by hand), but (b) when an operator *does* need to inspect a snapshot during incident response, a JSONB column is at least browseable with `jsonb_pretty`, whereas `bytea` is opaque. The JSONB representation is produced by the snapshot codec (§3); the codec's responsibility is to choose a stable JSON shape, not to optimize byte size.

- **`state_codec_version INTEGER NOT NULL`.** The aggregate's snapshot-codec version at the time of write. Aggregates declare this integer alongside their `StateCodec`; bumping it on a backwards-incompatible change to the joint state's wire shape signals every reader that pre-bump snapshots are stale. The reader (§6) compares this against the aggregate's current `stateCodecVersion` and falls through to full replay on mismatch. This is the single most important field for forward-evolution safety.

- **`regfile_shape_hash TEXT NOT NULL`.** A hash of the type-level register-file shape `rs` (the slot list `'[ '("name", T1), '("other", T2), … ]`) at write time. Keiki's research survey (`docs/research/02-keiki-decide-loop.md` §"Schema") records that "register-file shape changes invalidate existing snapshots (snapshot validation uses a register-file shape hash)." The shape hash is a *secondary* discriminant beneath the codec version, useful when an aggregate author bumps the slot list in a way that the codec layer alone cannot detect (for example, swapping two slots of the same JSON type, or renaming a slot whose `Symbol` does not appear in the encoded JSON). The hash is computed from the slot-list `(Symbol, Type)` pairs at compile time using a `Generic`/`TypeRep` derivation provided by keiki (the helper itself is a keiki-side gap; see §13). On read, mismatch falls through to full replay.

- **`taken_at TIMESTAMPTZ NOT NULL DEFAULT now()`.** The wall-clock time of the snapshot write, useful for the GC playbook ("delete snapshots older than 30 days") and for operator triage ("when was the last snapshot for this stream?"). Indexed for the GC query.

- **`ON DELETE CASCADE`.** Hard deletes of `streams` rows are gated by kiroku's `kiroku.enable_hard_deletes` GUC (the `protect_deletion` and `protect_truncation` triggers in `kiroku-store/sql/schema.sql`); under normal operation operators cannot delete from `streams`. The cascade therefore fires only during the GDPR / maintenance path that operators explicitly opt into. Cascade semantics there are correct: when an operator hard-deletes a stream's row, every snapshot tied to that stream goes with it. Without `ON DELETE CASCADE`, the snapshot would be orphaned by `stream_id` until manually purged.

- **`ix_keiro_snapshots_stream_name`.** Supports operator queries like "show me the snapshot for stream `pm-OrderFulfillment-7`." The primary key on `stream_id` already supports the hot path (read-by-id during hydration); this index is for human-driven inspection, not for the read path.

- **`ix_keiro_snapshots_taken_at`.** Supports the GC query (§9) `DELETE FROM keiro_snapshots WHERE taken_at < now() - interval '30 days'`.

The migration belongs in keiro's SQL bundle (the production library will follow kiroku-store's pattern of an embedded `schema.sql`). It is idempotent (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`) and can be run repeatedly without effect. The migration does not depend on kiroku-store's own migration ordering except that `streams` must already exist; this is satisfied by ordering keiro's migration after kiroku-store's bundle, which is the only sensible deployment order anyway.

What the layout deliberately does *not* include:

- **No `aggregate_type` column.** The mapping between a `stream_name` and the aggregate it belongs to is a keiro-side concern that lives in the typed `AggregateId a` newtype (EP-1). Including it on the row would duplicate information already recoverable from the stream name's category prefix (kiroku's `streams.category` generated column). EP-6 may revisit if the production library finds operators routinely needing aggregate-level rollups.

- **No `event_id` of the last-included event.** The `stream_version` is sufficient to determine the tail-replay range. Recording the last `event_id` would be a debugging aid only and would couple snapshot writes to event-id propagation.

- **No history.** Only the most recent snapshot per stream is retained. Keeping multiple snapshots per stream would buy partial reconstruction at the cost of permanent linear growth in storage; the optimization is too marginal to justify the cost. If a future workload needs snapshot history (for example, a "time-travel debugger" that loads any historical state), it is additive — drop the PK constraint, switch to `(stream_id, stream_version)`, and add a "latest snapshot" view. This is recorded as a v2 candidate in §13.


## 3. Snapshot codec

The snapshot codec is the keiro-side analogue of EP-2's `Codec e` (`docs/research/07-codec-strategy.md` §2), specialized to the joint state `(s, RegFile rs)`. It is *not* a `Codec` over the same algebra: events have stable per-constructor type tags and a per-record `schemaVersion`; the joint state has neither. EP-2 §8 explicitly defers the snapshot codec to this plan and explains why the two interfaces are not nominal subtypes of each other.

The interface (writing `t = (s, RegFile rs)` for brevity):

    -- Keiro.Snapshot.Codec
    data StateCodec t = StateCodec
      { stateEncode      :: t -> Aeson.Value
      , stateDecode      :: Aeson.Value -> Either String t
      , stateCodecVersion :: Int
      , regFileShapeHash :: Text
      }

Field-by-field:

- **`stateEncode`**: serialize the joint state. The encoder is responsible for producing a stable JSON shape that round-trips through `stateDecode`. Common implementation is a record-shaped JSON object with a `"control"` field carrying the encoded `s` and a `"registers"` field carrying the encoded `RegFile rs` — but the exact shape is the codec author's choice; the only contract is round-tripping.

- **`stateDecode`**: deserialize. Returns `Either String t` rather than throwing; the keiro snapshot read path translates a `Left` into "fall through to full replay" with a logged warning (§8). It does not raise an error, because a bad-on-disk snapshot must never break a working command path.

- **`stateCodecVersion`**: an integer recording the wire-shape generation. EventStream authors bump it on every backwards-incompatible change to `stateEncode`/`stateDecode`. The hydration short-circuit checks this against the on-disk row (§6); a mismatch silently falls through.

- **`regFileShapeHash`**: a stable `Text` hash of the register-file shape `rs` (the slot-list of `(Symbol, Type)` pairs). Computed at compile time, ideally via a keiki-side helper (`Keiki.RegFile.shapeHash :: forall rs. KnownRegFileShape rs => Proxy rs -> Text`). The hash is independent of the slot *values*; it is a function of the type-level shape only. Used as a secondary discriminant on read (§6).

Why a separate codec rather than reusing `Codec e`:

- **The shape is different.** Events are sum types with stable per-constructor `eventType` tags; the joint state is a product of the control vertex `s` and a heterogeneous register file `RegFile rs`. The encoding "the third register slot of a five-slot RegFile is a `UTCTime`" needs slot-walking machinery that the event codec does not have. EP-2 §8 records this distinction explicitly.

- **The lifecycle is different.** Events accumulate forever; an event from 2026 must remain decodable in 2030. Snapshots are written periodically and are *advisory* — a snapshot that no longer decodes is not a correctness failure, it is a cache miss. Snapshot codecs may legitimately rebuild from scratch on a schema change rather than carry a chain of upcasters. There is no upcaster chain on `StateCodec`; bumping the version invalidates every existing snapshot for that aggregate, and the next command-cycle's policy fire writes a fresh one.

- **Versioning semantics differ.** Events carry their own version per record (`metadata.schemaVersion`); snapshots are versioned at the *aggregate* level — every snapshot for an aggregate uses the same `stateCodecVersion`. This is why the codec carries a single `stateCodecVersion :: Int` rather than an upcaster chain.

The snapshot codec consumes the same Aeson primitives EP-2's event codecs use (`Aeson.encode`, `Aeson.eitherDecode`), but the patterns at this layer are different. EP-2's "selectively borrow" verdict on the `hindsight` library (`docs/research/07-codec-strategy.md` §11) does *not* apply here: hindsight's value-add is in event evolution (consecutive upcasters composed by a type-level chain), and snapshots have no need for that machinery. This plan adopts EP-2's value-level ergonomics — record-of-functions rather than typeclass — for the same reasons EP-2 records (testability, parametricity, constructor-time validation).

A common derivation pattern for the encoder is:

    derivedStateCodec
      :: ( Aeson.ToJSON s, Aeson.FromJSON s
         , KnownRegFileShape rs
         , RegFileToJSON rs
         )
      => Int  -- author-supplied stateCodecVersion
      -> StateCodec (s, RegFile rs)
    derivedStateCodec v = StateCodec
      { stateEncode = \(s, regs) ->
          Aeson.object [ "control" .= s, "registers" .= regFileToJSON regs ]
      , stateDecode = \val ->
          flip Aeson.parseEither val $ Aeson.withObject "State" $ \o -> do
            s    <- o .: "control"
            regs <- regFileFromJSON =<< o .: "registers"
            pure (s, regs)
      , stateCodecVersion = v
      , regFileShapeHash  = shapeHash (Proxy @rs)
      }

The `RegFileToJSON rs` constraint and `regFileToJSON` / `regFileFromJSON` helpers are *keiki-side* gaps: keiki today does not perform serialization (`docs/research/02-keiki-decide-loop.md` §"Effectful Story" notes "no built-in JSON or binary"; EP-1 §14 already requested the helper for the same reason). EP-6 must consolidate this into the keiki backlog. Until the helper lands, every aggregate author hand-rolls the register-file encoder by walking the slot list themselves; this is tedious but mechanical.


## 4. Snapshot policy

A *snapshot policy* is a pure function that decides, after a successful command cycle, whether to write a snapshot. The interface:

    -- Keiro.Snapshot.Policy
    newtype SnapshotPolicy t = SnapshotPolicy
      { runSnapshotPolicy :: t -> StreamVersion -> Bool
      }

    snapshotPolicyEvery :: Int -> SnapshotPolicy t
    snapshotPolicyEvery n = SnapshotPolicy $ \_ (StreamVersion v) ->
      v > 0 && fromIntegral v `mod` n == 0

    snapshotPolicyOnTerminal :: (t -> Bool) -> SnapshotPolicy t
    snapshotPolicyOnTerminal isTerminal = SnapshotPolicy $ \t _ -> isTerminal t

    snapshotPolicyOnTerminalOrEvery :: (t -> Bool) -> Int -> SnapshotPolicy t
    snapshotPolicyOnTerminalOrEvery isTerminal n = SnapshotPolicy $ \t v ->
      runSnapshotPolicy (snapshotPolicyOnTerminal isTerminal) t v
        || runSnapshotPolicy (snapshotPolicyEvery n) t v

    snapshotPolicyNever :: SnapshotPolicy t
    snapshotPolicyNever = SnapshotPolicy $ \_ _ -> False

The function is pure; it can read the joint state and the post-append `StreamVersion`, but cannot perform IO. This keeps policy decisions deterministic and replay-safe (a future replay-oriented test framework can re-run the policy on a known state and assert the same answer).

The three named constructors cover the common shapes:

- **`snapshotPolicyEvery n`**: write a snapshot every `n` events. The default for most aggregates. `n = 100` is a sensible starting value: with 100-event tail replays, hydration cost stays bounded regardless of stream length, and snapshot writes happen roughly 1% as often as commands. Aggregates with very expensive `applyEvent` may want smaller `n`; aggregates with cheap `applyEvent` can use larger `n` (or `Never`).

- **`snapshotPolicyOnTerminal isTerminal`**: write a snapshot only when the joint state enters a terminal sink. Useful for short-lived process-manager streams (EP-3 §5): a process manager that completes after ~10 events does not need periodic snapshots, but a snapshot at terminal preserves the final state for any future audit.

- **`snapshotPolicyNever`**: do not write snapshots. Appropriate for aggregates whose streams are intrinsically short (typical `Counter`-shape aggregates with under ~50 events) or for prototype phases where snapshot overhead is not yet warranted. The hydration path always works without a snapshot — full replay is the baseline.

The policy is carried alongside the rest of the aggregate definition. EP-1's `EventStream phi rs s ci co` already includes an `esSnapshotPolicy :: SnapshotPolicy (s, RegFile rs)` field (`docs/research/06-command-cycle-design.md` §4); this plan supplies the `SnapshotPolicy` type. The default for an aggregate that does not specify a policy is `snapshotPolicyEvery 100`, but this plan does not enforce a default — that is a production-library choice.


## 5. EventStream-level wiring

EP-1's `EventStream phi rs s ci co` record (the keiro ⇄ keiki contract, recorded in `docs/research/06-command-cycle-design.md` §4) carries every aggregate-specific configuration the command cycle needs. This plan adds two of its fields:

    data EventStream phi rs s ci co = EventStream
      { esTransducer       :: SymTransducer phi rs s ci co
      , aggCategory         :: Text
      , aggIdToStreamName   :: AggregateId (EventStream phi rs s ci co) -> StreamName
      , esEventCodec       :: Codec co                         -- defined in EP-2
      , esStateCodec       :: StateCodec (s, RegFile rs)       -- defined here, EP-4
      , esSnapshotPolicy   :: SnapshotPolicy (s, RegFile rs)   -- defined here, EP-4
      , …
      }

EP-1 already references both fields; this plan binds the types they have. No new wiring is required at the `EventStream` layer beyond what EP-1 already specified.

A keiro author with no snapshot needs writes:

    myEventStream = EventStream
      { …
      , esStateCodec     = derivedStateCodec 1
      , esSnapshotPolicy = snapshotPolicyNever
      }

A keiro author with periodic snapshots writes:

    orderFulfillment = EventStream
      { …
      , esStateCodec     = derivedStateCodec 1
      , esSnapshotPolicy = snapshotPolicyEvery 100
      }

A keiro author with terminal-state snapshots writes:

    onboardingProcessManager = EventStream
      { …
      , esStateCodec     = derivedStateCodec 1
      , esSnapshotPolicy = snapshotPolicyOnTerminal $ \(s, _) -> isComplete s
      }


## 6. Read path

The hydration short-circuit replaces EP-1's hydration entry point. Recall EP-1's hydration shape (`docs/research/06-command-cycle-design.md` §5):

    hydrate
      :: …
      => EventStream phi rs s ci co
      -> StreamName
      -> Eff es (s, RegFile rs, StreamVersion)
    hydrate agg sn =
      Stream.fold
        (Fold.foldlM' replayStep (pure (initial t, initialRegs t, StreamVersion 0)))
        (hydrationStream sn pageSize)
      where
        t = esTransducer agg

The snapshot-aware version is structurally identical — same `Stream`, same `Fold` — but parameterized by an *initial cursor* and *initial accumulator* derived from the snapshot read:

    hydrateWithSnapshot
      :: …
      => EventStream phi rs s ci co
      -> StreamName
      -> Eff es (s, RegFile rs, StreamVersion)
    hydrateWithSnapshot agg sn = do
      snap <- readSnapshot agg sn
      let (startCursor, startState) = case snap of
            Just (v, t) -> (v + 1, t)
            Nothing     -> (StreamVersion 0, (initial trans, initialRegs trans))
      Stream.fold
        (Fold.foldlM' replayStep (pure (startState, startCursor)))
        (hydrationStream sn (startCursor, pageSize))
      where
        trans = esTransducer agg

`readSnapshot`'s shape:

    -- Keiro.Snapshot
    data SnapshotRead t
      = SnapshotHit !StreamVersion !t
      | SnapshotMiss        -- no row for this stream
      | SnapshotIncompatibleCodec      -- row exists but stateCodecVersion mismatch
      | SnapshotIncompatibleShape      -- row exists, codec version matches, but shape hash mismatch
      | SnapshotDecodeError !Text      -- row exists, codec/shape match, but decode failed

    readSnapshot
      :: ( Store :> es, Error StoreError :> es )
      => EventStream phi rs s ci co
      -> StreamName
      -> Eff es (Maybe (StreamVersion, (s, RegFile rs)))
    readSnapshot agg sn = do
      raw <- runStorePool (loadSnapshotRow sn)
      case raw of
        Nothing -> pure Nothing       -- SnapshotMiss
        Just row
          | row.codecVersion /= stateCodecVersion (esStateCodec agg) ->
              do logSnapshotIncompatibleCodec sn row
                 pure Nothing
          | row.shapeHash    /= regFileShapeHash (esStateCodec agg) ->
              do logSnapshotIncompatibleShape sn row
                 pure Nothing
        Just row ->
          case stateDecode (esStateCodec agg) row.state of
            Left  err -> do logSnapshotDecodeError sn row err
                            pure Nothing
            Right t   -> pure (Just (row.streamVersion, t))

The reader collapses every recoverable failure (no row, wrong codec version, wrong shape hash, decode error) into `Nothing`, with a logged warning carrying the stream name and the discriminant. The caller — `runCommand` — is none the wiser: a returned `Nothing` is indistinguishable from "no snapshot exists yet," and full replay proceeds. This is the *advisory* property recorded in EP-4's Decision Log: snapshots are never load-bearing for correctness; a missing or unreadable snapshot must not break a working command path.

The underlying SQL is a single index-only lookup on the primary key:

    SELECT stream_version,
           state,
           state_codec_version,
           regfile_shape_hash
      FROM keiro_snapshots
     WHERE stream_id = $1

The query is keyed on `stream_id`. EP-1's `runCommand` already resolves `StreamName -> stream_id` as part of its append path (kiroku's `appendToStream` is keyed by name; the underlying SQL looks up the id internally). The snapshot read uses the same lookup; if the production library finds the duplicate name→id resolution costly, kiroku-store could expose a `lookupStreamId :: StreamName -> Eff es (Maybe StreamId)` helper that both paths share. Recorded in §13 as a candidate kiroku-side optimization.

The cursor `startCursor` in `hydrateWithSnapshot` above is `StreamVersion (snap.streamVersion + 1)` on a hit. The reader of `readStreamForward` will return events strictly newer than the snapshot. On a miss, `startCursor = StreamVersion 0`, equivalent to EP-1's full-replay path. The fold's initial accumulator is the decoded snapshot state on hit, or `(initial t, initialRegs t)` on miss. The `Stream` and `Fold` shapes are otherwise identical; this is the property the parent MasterPlan's "Streamly substrate" Integration Point requires (a single hydration pipeline, parameterized rather than duplicated).

**Why per-stream `StreamVersion`, not `globalPosition`?** The snapshot is keyed and indexed per stream because hydration is per-stream. `globalPosition` (kiroku's gap-free Strategy-E counter on the `$all` row) is the cursor *async subscribers* use, not aggregate hydration. Mixing them would fail when, for example, two disjoint aggregates are written interleaved: the snapshot for stream A at `globalPosition 50` and the snapshot for stream B at `globalPosition 51` would seem to require ordering that does not actually exist between them. `StreamVersion` is the only cursor with the right cardinality for hydration. EP-3 §4 records the orthogonal claim for subscriptions ("kiroku's Strategy E gives gap-free contiguous global positions"); the two cursors do not interfere.

**Read-during-write race.** A reader that sees an old snapshot (or no snapshot) and replays through the latest events will arrive at the same joint state as a reader that sees a newer snapshot and replays only the tail. This is the mathematical property that makes snapshots an optimization rather than a substitute: `snapshot.state ⊕ tail-events = full-replay`. The Postgres MVCC isolation kiroku and keiro share (`ReadCommitted`, the default for kiroku reads — `docs/research/01-kiroku-read-side.md`) is sufficient: a snapshot row visible to a transaction was committed at-or-before the transaction's start, and the events it summarizes are by construction also visible. There is no race that produces an inconsistent state.


## 7. Write path

Snapshot writes happen *after* a successful command cycle, asynchronously, outside the cycle's optimistic-concurrency transaction. The decision to keep the snapshot write outside the cycle's transaction is recorded in EP-4's Decision Log: including the snapshot write inside the cycle would (a) make every command pay the snapshot cost regardless of whether the policy fires, (b) couple the cycle's success to a non-load-bearing optimization, and (c) increase the cycle's lock-window on `keiro_snapshots`.

The post-cycle hook lives in `runCommand`'s tail (writing `t = (s, RegFile rs)` for brevity):

    runCommand agg aid cmd = do
      sn          <- streamNameOf agg aid
      (t0, ver0)  <- hydrateWithSnapshot agg sn
      case step (esTransducer agg) t0 cmd of
        Nothing                     -> throwError (CommandRejected sn (T.pack (show cmd)))
        Just (s', regs', mev)       -> do
          let evs = maybe [] (pure . encodeForAppend (esEventCodec agg)) mev
          newVer <- appendToStreamWithExpected sn ver0 evs
          let t1 = (s', regs')
          when (runSnapshotPolicy (esSnapshotPolicy agg) t1 newVer) $
            forkAsync (writeSnapshot agg aid newVer t1)
          pure ()

`forkAsync` is whatever the production library uses to fire-and-forget within an `Eff es` context; the spike at `spikes/command-cycle/` does not exercise it because the spike has no snapshot policy. A reasonable shape is `Effectful.Async.async :: Eff es a -> Eff es (Async a)` with the caller deliberately discarding the `Async` so failures surface in logs/traces but do not propagate to the caller. The production library may also choose to use a single-threaded background worker that drains a small in-memory queue of pending snapshot writes; the design doc does not pin the choice, only the contract that the write is asynchronous and non-fatal.

`writeSnapshot`:

    writeSnapshot
      :: ( Store :> es, Error StoreError :> es )
      => EventStream phi rs s ci co
      -> AggregateId (EventStream phi rs s ci co)
      -> StreamVersion
      -> (s, RegFile rs)
      -> Eff es ()
    writeSnapshot agg aid version t =
      runStorePool (writeSnapshotRow sn version state codecVersion shapeHash)
      where
        sn           = aggIdToStreamName agg aid
        state        = stateEncode (esStateCodec agg) t
        codecVersion = stateCodecVersion (esStateCodec agg)
        shapeHash    = regFileShapeHash (esStateCodec agg)

The SQL is a monotonic upsert:

    INSERT INTO keiro_snapshots
        (stream_id, stream_name, stream_version,
         state, state_codec_version, regfile_shape_hash, taken_at)
    VALUES
        ((SELECT stream_id FROM streams WHERE stream_name = $1), $1,
         $2, $3::jsonb, $4, $5, now())
    ON CONFLICT (stream_id) DO UPDATE
       SET stream_version       = EXCLUDED.stream_version,
           state                = EXCLUDED.state,
           state_codec_version  = EXCLUDED.state_codec_version,
           regfile_shape_hash   = EXCLUDED.regfile_shape_hash,
           taken_at             = EXCLUDED.taken_at
     WHERE keiro_snapshots.stream_version < EXCLUDED.stream_version

The `WHERE` clause on the conflict-update is the *monotonicity guard*. Two concurrent writers — for example, a command at `streamVersion 100` whose snapshot write is delayed, and a later command at `streamVersion 110` whose snapshot write completes first — would otherwise allow the older writer to overwrite the newer snapshot. The guard ensures only the higher-version writer's update applies; the lower-version writer's `ON CONFLICT DO UPDATE` becomes a no-op. Without the guard, the snapshot could regress to an older version, which would still be correct (snapshots are advisory) but would defeat the optimization.

`stream_id` is resolved by the inline `SELECT` against `streams(stream_name)`. The unique constraint on `streams.stream_name` makes this a single row lookup. Resolving id once at write time is preferable to caching it in the runtime: streams can in principle be hard-deleted (under the `kiroku.enable_hard_deletes` GUC) and re-created with a different id, and a stale cached id would write into the wrong row.

**Failure semantics.** Any failure in `writeSnapshot` (connection lost, FK violation, JSON encoding error in `stateEncode`) is logged and discarded. The next command-cycle policy fire writes again; eventually a successful write recovers the snapshot. This is the *advisory* property recorded in EP-4's Decision Log applied to the write path.

**Why fire-and-forget rather than queue-backed.** A pgmq-hs queue (the substrate EP-3 §6 uses for the outbox) would give durable retry, but the use case is wrong: a failed snapshot write should not be retried indefinitely; it should be discarded. The next command's policy fire will write a fresher snapshot anyway, so retrying a stale one wastes work. EP-3's outbox uses pgmq because *missed messages are correctness failures*; here, missed snapshots are cache misses. The asymmetry justifies the simpler shape.

**Why post-commit, not pre-commit.** The snapshot must reflect committed state. Writing the snapshot before the cycle's append commit would create a window where the snapshot describes a state that does not exist (the hypothetical "we appended events 91-100 and snapshotted at 100, but the append rolled back"). A post-commit hook avoids this. The cost is a brief window where another reader could re-do work (load the older snapshot, replay the just-committed events) — which is fine.


## 8. Schema-change invalidation

When an aggregate author makes a backwards-incompatible change to the joint state's wire shape — adding a register slot, changing a control vertex constructor's payload, changing a slot's JSON encoding — they bump `stateCodecVersion` (and, if the register-file slot list itself changed, the `regFileShapeHash` updates automatically from the recompiled type). Existing snapshots are now stale.

The reader (§6) handles this automatically: a `stateCodecVersion` mismatch or `regFileShapeHash` mismatch returns `Nothing`, which sends the cycle into full replay. The cycle's policy may then write a fresh snapshot at the new version. Eventually all aggregates converge to the new version through normal command traffic; legacy snapshot rows linger until the GC playbook (§9) deletes them or until a fresh snapshot overwrites them via the `ON CONFLICT DO UPDATE`.

Operators may *force* a faster convergence in two ways:

- **`TRUNCATE keiro_snapshots`** — under the `kiroku.enable_hard_deletes` GUC analogue (which keiro should ship; see §10) — wipes every snapshot. The next command for each aggregate triggers a full replay; if its policy fires, a fresh snapshot is written at the new version. Cheap and total.

- **`DELETE FROM keiro_snapshots WHERE state_codec_version < <current>`** removes only snapshots that the new code cannot read anyway. Slightly more surgical than `TRUNCATE`.

There is no "rebuild" step: snapshots are passively rebuilt by the policy on next write. An operator command `keiro snapshot rebuild --aggregate <Cat>` could optionally force a re-snapshot pass by issuing a no-op `tick` per stream of the category, but this is a v1 nice-to-have (§10), not a correctness requirement.

The keiki survey (`docs/research/02-keiki-decide-loop.md` §"Schema") records: "keiki commits to a single static schema per deployment. Schema evolution is an *application* concern. Register-file shape changes invalidate existing snapshots (snapshot validation uses a register-file shape hash)." This plan honours that constraint by computing the hash at compile time and comparing it on read; keiki's hash computation is the §13 keiki-side gap.


## 9. GC and retention

Snapshots are eligible for deletion at any time. The advisory property guarantees that any deletion strategy preserves correctness; the only cost is replay work on the next hydration of the affected stream. The recommended retention is **30 days**, after which snapshots are GC'd:

    DELETE FROM keiro_snapshots WHERE taken_at < now() - interval '30 days'

The 30-day default is conservative — most aggregates will receive a fresh snapshot well within 30 days, so the GC mostly removes snapshots for streams that have gone idle (terminated process managers, dormant aggregates). For high-traffic systems, 7 days is reasonable; for archival systems, 90 days.

The GC query is supported by the `ix_keiro_snapshots_taken_at` index (§2). It can be run on a schedule (cron, pg_cron) or manually. Running it during peak traffic is fine: snapshots are not lock-load-bearing, and the deletes are point queries on the index.

**Does the 30-day window risk missing snapshots for active streams?** No. The write path's `ON CONFLICT DO UPDATE` overwrites a stream's snapshot on every policy fire; an active stream's `taken_at` is regularly refreshed. The GC only catches snapshots whose stream has gone idle for 30 days. If the stream is *also* idle from a hydration perspective, the GC's removal costs nothing. If the stream is hydrated again after GC, full replay runs — exactly the cost we expected, and is paid once.

**Is GC ever load-bearing?** Briefly — when `state_codec_version` is bumped and operators need the old snapshots to disappear quickly to free space, the GC playbook accelerates that. But this is an operational nicety, not a correctness requirement.

Operators who need to inspect snapshots before purging can use the `ix_keiro_snapshots_stream_name` index to scope by stream: `SELECT * FROM keiro_snapshots WHERE stream_name LIKE 'pm-OrderFulfillment-%' ORDER BY taken_at`. The category-prefixed stream-name convention (`pm-<pmName>-<correlationId>` for process managers, `<aggregate>-<id>` for aggregates) makes this a useful inspection vector.


## 10. Operator commands

The production library is expected to expose an operator CLI subcommand for snapshot management. The shapes proposed here are not pinned to a particular CLI framework; they describe the interface contract.

- **`keiro snapshot list [--category <Cat>] [--stream <name>] [--older-than <duration>]`** — lists snapshot rows, sorted by `taken_at`, with category/stream/duration filters. Read-only; useful for triage. Defaults to the last 50 rows.

- **`keiro snapshot show --stream <name>`** — pretty-prints a single snapshot's `state` JSONB and metadata. Read-only.

- **`keiro snapshot purge [--older-than <duration>] [--category <Cat>] [--codec-version <int>]`** — runs the GC `DELETE`. Refuses by default unless one filter is specified; the GUC-gated total-purge is `keiro snapshot purge --all` and requires explicit confirmation. The CLI is the recommended path for the §8 schema-change accelerated invalidation.

- **`keiro snapshot rebuild --aggregate <Cat>`** — issues a `tick` (the silent-advance entry point from `docs/research/06-command-cycle-design.md` §7) per stream of the category, forcing a snapshot rewrite under the new codec version. Useful immediately after a schema bump for hot aggregates whose stream growth would otherwise pay full replay until the policy fires naturally. v1 production-library nice-to-have; can be deferred.

- **`keiro snapshot stats [--category <Cat>]`** — reports per-category counts, average snapshot size, oldest and newest `taken_at`. Useful for capacity planning.

The commands ship as a single binary (`keiro-admin` or similar) the production library will define; the design doc does not pin the binary name.


## 11. Integration with EP-1 (command cycle)

EP-1's hydration is the single most important consumer of this design. Recall EP-1 §5: hydration is a Streamly `Stream (Eff es) RecordedEvent` consumed by a `Fold (Eff es) RecordedEvent (s, RegFile rs, StreamVersion)`. The snapshot path is *not* a separate code path; it is the same pipeline with two differences:

1. The source `Stream` is sourced from `readStreamForward sn (snapshot.streamVersion + 1) maxBound` instead of `readStreamForward sn (StreamVersion 0) maxBound`.
2. The `Fold`'s initial accumulator is the decoded snapshot state instead of `(initial t, initialRegs t, StreamVersion 0)`.

This is the property the parent MasterPlan's "Streamly substrate" Integration Point requires (`docs/masterplans/1-keiro-research-foundation.md` §Integration Points): keiro's hydration is a single Streamly `Stream → Fold` pipeline, parameterized rather than duplicated. Reviewers should not look for a parallel snapshot-load pipeline; there is none.

The constant-memory shape of the underlying Streamly fold (one `RecordedEvent` page resident at a time, default page size 256) is preserved on the snapshot path. The total *work* is bounded by the snapshot policy's events-since-snapshot threshold rather than the absolute stream length.

EP-1's `runCommand` design (§4) and `runCommandRetry` (§9) consume `hydrateWithSnapshot` transparently. Retry semantics are unchanged: a `WrongExpectedVersion` triggers a re-hydration, which transparently re-reads the latest snapshot (in the rare case where another writer wrote a snapshot between this attempt and the previous attempt, the snapshot itself does not regress because of the §7 monotonicity guard).

EP-1's transactional-step combinator (§10) is unchanged. The snapshot write is post-commit and does *not* enter the user-supplied SQL action's transaction. If a future use case demands "snapshot write inside the cycle's transaction" — for example, a bizarre invariant where an external table must be updated atomically with the snapshot — the production library can add a dedicated `runCommandWithSnapshot` variant. This plan does not cover it; it is not on the v1 critical path.

EP-1 §5's "Invariant for aggregate authors" — event payload fields must be direct projections of input fields, not computed terms — applies to events, not to the snapshot codec. Snapshots serialize the post-update state, not the events themselves; the inversion concern (`solveOutput` + `applyEvent`) does not arise on the snapshot path. A snapshot read followed by tail-replay still goes through `applyEvent` for the tail, so the invariant must hold for any event that may live in the tail; but this is the same invariant EP-1 already records.


## 12. Integration with EP-2 (codec strategy)

The snapshot codec (§3) is a sibling of EP-2's `Codec e` (`docs/research/07-codec-strategy.md` §2), not a subtype. The patterns translate (record-of-functions, value-level, no `hindsight`-style type-level machinery), but the signatures differ. EP-2 §8 records the rationale for the separation; this plan implements it.

What this plan inherits from EP-2:

- **Aeson as the wire format.** kiroku stores `EventData.payload :: Aeson.Value`; keiro events round-trip through Aeson via `Codec e`; keiro snapshots use the same primitives. There is no second wire format to operate.

- **Value-level codec ergonomics.** EP-2's "selectively borrow" verdict on hindsight (record-of-functions over typeclass instances) carries over here for the same reasons: testability, parametricity, no orphan-instance problems. The snapshot codec is a record, not a typeclass.

- **Versioning via an integer.** EP-2 stores `metadata.schemaVersion :: Int` per event record; keiro stores `state_codec_version :: Int` per snapshot row. The integer-based scheme is the same; the *semantics* differ (EP-2's per-record version drives an upcaster chain; keiro's aggregate-level version drives a fall-through invalidation).

What this plan does *not* inherit:

- **No upcaster chain on `StateCodec`.** Snapshots are advisory; bumping the version invalidates every existing snapshot for the aggregate, and the policy writes a fresh one on the next fire. No chain, no `Upcast n` instance, no `MigrateVersion` machinery.

- **No per-record schema-version metadata.** `StateCodec` carries one integer for the whole aggregate; individual snapshot rows do not negotiate their own version with the codec.

EP-2 §12 records the only upstream gap EP-2 introduces: the `RegFile rs <-> Aeson.Value` helper from keiki. EP-4 reuses that helper (§3); the gap is a single keiki-side feature consumed by both plans. EP-6 records it once with both EPs as customers.


## 13. Integration with EP-3 (subscriptions, projections, process managers)

EP-3's three subscription lifecycles — inline projections (`docs/research/08-subscription-and-process-manager-design.md` §2), async projections (§3), and live projections — *do not* use snapshots. The reason is structural: subscriptions consume events monotonically by `globalPosition` (kiroku's gap-free Strategy-E counter), with their own per-subscription checkpoint table (`subscriptions.last_seen`). They never replay an aggregate's full event stream; they consume a global event stream incrementally.

Inline projections (EP-3 §2) write a read-model row in the same `Hasql.Transaction.Transaction` as the aggregate's append. There is no hydration step that snapshots could short-circuit.

Async projections (EP-3 §3) consume `Ingested es msg` from `shibuya-kiroku-adapter`'s Streamly source. The handler decodes `RecordedEvent.payload` via `Codec e` and updates the read model. There is no hydration step.

Live projections (mentioned in EP-3 but a v1 nice-to-have) materialize a query-time view from a stream of events. They do not require snapshots; if a live projection wants accelerated cold-start, it can persist its own checkpoint, which is a different concern from aggregate snapshots and does not use the `keiro_snapshots` table.

Process managers (EP-3 §5) are themselves event-sourced aggregates: a process manager has its own kiroku stream (`pm-OrderFulfillment-<id>`) and its `applyEvent` recovers a `(s, RegFile rs)` exactly as a domain aggregate's does. **Process managers therefore benefit from snapshots in exactly the same way** — they use the same `EventStream` machinery EP-1 §4 exposes, with `esSnapshotPolicy` controlling whether and when their state is snapshotted. EP-3 §5 cross-references this plan as the snapshot mechanism for process-manager state. A long-running process manager (one whose stream grows past ~100 events) should set `snapshotPolicyEvery 100`; a short-lived one can use `snapshotPolicyOnTerminal isComplete` or `snapshotPolicyNever`.

EP-3's outbox (§6) and inbox (§7) are pgmq-backed message-passing primitives, not state-replay primitives. They are unrelated to snapshots.

The takeaway for reviewers: the *only* keiro abstraction that uses `keiro_snapshots` is aggregate hydration via EP-1's `runCommand`. Process managers participate as a special case of aggregate hydration. Subscriptions and the outbox/inbox use entirely different storage. EP-3's design doc records this orthogonality; this plan repeats it for clarity.


## 14. Integration with EP-5 (workflow roadmap)

EP-5 (`docs/plans/5-workflow-engine-and-durable-execution-roadmap.md`, output document `docs/research/10-workflow-roadmap.md` to be written next) describes the v1 process-manager substrate and a v2 named-step durable-execution roadmap. The v1 substrate consumes process managers, which (as §13 records) participate in snapshots through EP-1's `EventStream` machinery. Long-lived workflow streams — the "child workflow ticked 5,000 times before the parent resolved" case — are precisely where snapshots earn their keep.

The v2 durable-execution layer (deferred, not in scope for this MasterPlan) may add a *replay-oriented* snapshot story where a workflow's deterministic-replay log is checkpointed at "named steps." This is structurally different from aggregate snapshots — it operates over a workflow's command/event journal at a granularity below `StreamVersion` — and EP-5's roadmap will treat it as a separate primitive. EP-4's `keiro_snapshots` table is the *aggregate* snapshot, not the *step* snapshot. A future v2 can add a sibling table without disturbing this one.

EP-5 should record the relationship explicitly when it is written: the process-manager snapshot (this plan) is the only snapshot story the v1 keiro library ships; v2 may add a deterministic-replay step-snapshot in addition, not in replacement.


## 15. Open questions and upstream gaps

This plan introduces three upstream gaps that EP-6 must consolidate:

1. **keiki: register-file serialization helper.** The joint state keiro persists is `(s, RegFile rs)`, where `RegFile rs` is keiki's typed heterogeneous tuple of `(Symbol, Type)` slots. Without help from keiki, every aggregate author hand-rolls the encoding by walking the slot list themselves (using `Generic` or `Keiki.Generics`'s existing `mkInCtor`-style helpers extended to registers). The cleanest interface is for keiki to expose:

       regFileToJSON   :: (RegFileToJSON rs) => RegFile rs -> Aeson.Value
       regFileFromJSON :: (RegFileToJSON rs) => Aeson.Value -> Either String (RegFile rs)

   plus a class `RegFileToJSON rs` with default instances derived from each slot type's `ToJSON`/`FromJSON`. EP-1 already requested this helper for the snapshot path (`docs/research/06-command-cycle-design.md` §14 "Register-file serialization helper"); EP-2 reiterated the request for the same reason (`docs/research/07-codec-strategy.md` §12). EP-4 is the third customer. EP-6 records it once with three customers.

2. **keiki: register-file shape hash.** A stable `Text` hash of the type-level slot list `rs`, computable at compile time. Used as the secondary discriminant on snapshot read (§6). The interface should be:

       class KnownRegFileShape rs where
         regFileShapeHashFor :: Proxy rs -> Text

   A reasonable implementation hashes the rendered representation of each `(Symbol, Type)` pair. EP-4 is the only customer for this helper today; it could land in keiki alongside the serialization helper.

3. **kiroku: optional `lookupStreamId` helper.** The snapshot read SQL is keyed on `stream_id`; the snapshot write SQL resolves `stream_id` from `stream_name` via an inline `SELECT`. If profiling shows the duplicate name→id resolution is hot, kiroku-store could expose a public `lookupStreamId :: StreamName -> Eff es (Maybe StreamId)` helper. This is an optimization, not a correctness gap; recorded as a candidate, not a requirement.

Two questions deferred to v2:

- **Multi-snapshot history.** Keeping multiple snapshots per stream (snapshot at `version 100`, snapshot at `version 200`, snapshot at `version 300`) would enable a "time-travel" hydration that loads the joint state at any historical version. The cost is permanent linear storage growth. v1 keeps only the most recent snapshot; a future v2 can drop the PK constraint and switch to `(stream_id, stream_version)` if the use case appears.

- **Compressed snapshots.** JSONB is browseable but verbose. For very large joint states (process managers carrying thousands of register slots, hypothetically), a binary encoding (CBOR, MessagePack) plus `bytea` storage would reduce storage cost at the price of operator-friendliness. v1 prefers operator-friendliness; v2 can add an optional binary path for hot aggregates.


## 16. Test strategy

The production library will validate the snapshot path with three test classes; no spike runs in this design phase, but the test plan must be concrete enough that the eventual test author has a clear target.

**Round-trip test** (per aggregate's `StateCodec`): `forAll t. stateDecode codec (stateEncode codec t) === Right t`. This is the same shape EP-2 §10 records for `Codec e`, applied to the joint state. Aggregates that derive their codec via `derivedStateCodec` (see §3) inherit this test from a shared property; aggregates that hand-roll their codec must implement it themselves.

**Hydration equivalence test**: hydrating an aggregate from its snapshot plus tail events must yield the same `(s, RegFile rs)` as full replay from version 0. The test fixture appends N events to a stream, records the joint state, writes a snapshot at some `0 < k < N`, then re-hydrates and asserts equality. This is the fundamental correctness test for the snapshot path; it must pass for every aggregate whose `esSnapshotPolicy` is non-trivial.

**Schema-change fall-through test**: after writing a snapshot at `stateCodecVersion = v`, bump the codec to `v+1` and re-hydrate. The reader must return `Nothing` (not a decode error, not stale state); the cycle must complete via full replay. The test asserts the reader's classification of the four `SnapshotRead` outcomes (§6) is correct.

The production library will use property-based testing (QuickCheck or Hedgehog) for the round-trip test and example-based testing for the other two. The test database is a real Postgres instance (matching kiroku-store's test pattern); mocks of `kiroku_snapshots` are not appropriate because the SQL on the write path (the `ON CONFLICT DO UPDATE … WHERE` monotonicity guard) requires the real semantic.

Three candidate failure modes the test suite must cover, beyond the three above:

- A snapshot write that fails (FK violation because the stream was concurrently hard-deleted, JSON encoding error in `stateEncode`, connection timeout) must not propagate as a `runCommand` error.
- A snapshot read that fails (decode error, malformed JSONB on disk, codec-version mismatch) must fall through to full replay.
- Two concurrent snapshot writes for the same stream at different versions must converge to the higher-version snapshot (the §7 monotonicity guard).


## 17. How to verify

A reviewer with access only to this document, EP-1 (`docs/research/06-command-cycle-design.md`), and EP-2 (`docs/research/07-codec-strategy.md`) should be able to:

1. **Write the kiroku migration adding `keiro_snapshots`.** §2 includes the full DDL, the index definitions, and the `ON DELETE CASCADE` rationale. The migration is idempotent (`CREATE … IF NOT EXISTS`) and depends only on `streams` already existing.

2. **Write the Haskell skeleton for `readSnapshot` and `writeSnapshot`.** §6 and §7 give the function signatures, the SQL statements, and the failure-handling shape. The Effectful effect-stack is the same as EP-1's `runCommand` (`Store :> es, Error StoreError :> es`); the snapshot module reuses `runStorePool` and `Hasql.Transaction.Transaction` directly.

3. **Answer "what happens when an operator drops `keiro_snapshots` at runtime?"** §8 records: the next hydration of every stream returns `Nothing` from `readSnapshot`, full replay runs, the cycle's policy may write a fresh snapshot, the system continues.

4. **Answer "what happens when an aggregate author bumps `stateCodecVersion`?"** §8 records: existing snapshot rows have the old version; the reader's version-mismatch branch (§6) returns `Nothing`; full replay runs; the policy writes a fresh row at the new version; eventually all active streams converge. Operators can `TRUNCATE keiro_snapshots` to accelerate convergence.

5. **Answer "what happens when two concurrent commands both fire the snapshot policy?"** §7 records: both `INSERT … ON CONFLICT (stream_id) DO UPDATE … WHERE keiro_snapshots.stream_version < EXCLUDED.stream_version` statements run; the lower-version writer's update is gated out by the monotonicity guard; the higher-version snapshot wins.

6. **Sketch the operator CLI interface.** §10 names the five subcommands (`list`, `show`, `purge`, `rebuild`, `stats`) and their flags.

7. **Locate every upstream gap this plan introduces.** §15 lists three (keiki: serialization helper, keiki: shape hash; kiroku: optional `lookupStreamId`) and notes that gap (1) is shared with EP-1 and EP-2.

If any of these answers is not derivable from this document, the document is incomplete and must be revised.


## 18. Summary

keiro's snapshot story is a single sidecar table (`keiro_snapshots`), keyed on kiroku's `stream_id`, holding one snapshot row per stream. The row carries the encoded joint state `(s, RegFile rs)` along with two discriminants — `state_codec_version` and `regfile_shape_hash` — that let the reader fall through to full replay on schema change. The snapshot codec is value-level (`StateCodec` record-of-functions), structurally analogous to EP-2's `Codec e` but versioned at the aggregate level, not per record. The snapshot policy is a pure function `(s, RegFile rs) -> StreamVersion -> Bool`, with three named constructors (`Every n`, `OnTerminal`, `Never`).

Hydration is unchanged structurally: it remains a Streamly `Stream → Fold` pipeline (per the parent MasterPlan's "Streamly substrate" Integration Point); the snapshot path only parameterizes the source's start cursor and the fold's initial accumulator. The write happens post-commit, asynchronously, with a monotonicity guard on the `ON CONFLICT DO UPDATE` to prevent a stale write from regressing a fresher snapshot. Every snapshot operation is *advisory* — never load-bearing for correctness. Operators can drop, truncate, or GC the table at any time; full replay is always the recoverable baseline.

The single keiki-side gap (`RegFile rs <-> Aeson.Value` plus the shape hash) is shared with EP-1 and EP-2, and is consolidated by EP-6 as a single keiki backlog item with three customers. No kiroku-side change is *required* (only an optional `lookupStreamId` optimization). Process managers (EP-3 §5) and long-lived workflow streams (EP-5) are the primary beneficiaries.

The design is deliberately small: one table, one codec, one policy, one read path, one write path, one fall-through invalidation strategy. The modesty is the point — snapshots are an optimization, and an optimization that fails closed (full replay) cannot break the system.
