---
id: 4
slug: snapshot-strategy-and-hydration-acceleration
title: "Snapshot Strategy and Hydration Acceleration"
kind: exec-plan
created_at: 2026-05-04T20:12:10Z
intention: "intention_01kqt8d9t8ehb84kgs19qa1rs9"
master_plan: "docs/masterplans/1-keiro-research-foundation.md"
---

# Snapshot Strategy and Hydration Acceleration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

EP-1's command cycle hydrates an aggregate by reading every event in its stream and folding through `applyEvents` to recover keiki's joint state `(s, RegFile rs)`. For an aggregate with thousands of events, this is wasteful. Industry-standard remediation is the *snapshot*: a periodically-persisted serialization of `((s, RegFile rs), version)` so hydration can read the latest snapshot, then read only events newer than the snapshot's version.

This plan resolves how keiro persists, reads, and rebuilds snapshots on top of Postgres, without altering kiroku's existing event-store schema.

After this plan is complete, anyone with the keiro source tree can read `docs/research/09-snapshot-strategy.md` and answer: where snapshots live, when they are written, when they are read, what happens on a schema change, how they fail safely, and which kiroku-side primitives are required (forwarded to EP-6).

This plan is *design-only*: no spike. The reasoning is that snapshots are pure storage plumbing — every component (table layout, codec for state, hydration short-circuit) is well-understood and has been implemented many times in industry (`docs/research/05-workflow-prior-art.md`). A spike would not retire any unknown.

The user-visible behaviour the eventual library will deliver: aggregate authors annotate their `Decider` with a snapshot policy (`every N events`); hydration paths transparently use the latest snapshot when present and fall back to full replay when not; operators can purge snapshots safely at any time.


## Progress

- [ ] M1.1 — Survey snapshot designs from `docs/research/05-workflow-prior-art.md` (Marten, Akka, Eventide); pick one shape.
- [ ] M1.2 — Design the `keiro_snapshots` table layout.
- [ ] M1.3 — Design the snapshot read path: load snapshot, read events from `snapshot_version+1`, fold through `evolve`.
- [ ] M1.4 — Design the snapshot write path: pure post-hydration policy hook, written outside the command-cycle's optimistic-concurrency tx.
- [ ] M1.5 — Design the schema-change invalidation: codec version of `state` recorded with the snapshot; hydration falls back to full replay when codec versions disagree.
- [ ] M1.6 — Design the GC story: snapshots are never load-bearing for correctness, so they can be deleted at any time.
- [ ] M2.1 — Write `docs/research/09-snapshot-strategy.md`.
- [ ] M2.2 — Update `docs/research/00-overview.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Snapshots live in a sidecar table `keiro_snapshots`, *not* as events in a derived stream.
  Rationale: Event-streams-as-snapshots couples snapshot lifecycle to kiroku's append semantics and clutters the event log with non-domain entries. A sidecar table is independently GC'able, schema-evolvable, and does not require kiroku changes. Recommended in `docs/research/01-kiroku-read-side.md` "Snapshots" section and `docs/research/05-workflow-prior-art.md` §10.
  Date: 2026-05-04.

- Decision: Snapshots are *advisory*, never load-bearing.
  Rationale: Hydration must always work without a snapshot, by full replay. Snapshots are an optimization, never a substitute for the event log. Operators can drop the table at any time and the system still works.
  Date: 2026-05-04.

- Decision: Snapshot write happens *after* a successful command cycle, asynchronously, outside the cycle's transaction.
  Rationale: Including snapshot write in the command-cycle transaction would make every command pay the snapshot cost even when no snapshot policy fires. Asynchronous write keeps the hot path tight.
  Date: 2026-05-04.

- Decision: Snapshot policy is a function `s -> StreamVersion -> Bool` carried alongside the `Decider`.
  Rationale: Common policies are "every N events" (`\_ v -> v `mod` 100 == 0`), "on terminal state" (`\s _ -> isTerminal s`), or "never" (`\_ _ -> False`). A pluggable function avoids hard-coding policy choices.
  Date: 2026-05-04.

- Decision: The snapshot record includes a `state_codec_version :: Int` field.
  Rationale: When the state codec changes incompatibly, all existing snapshots become invalid. Comparing codec versions on read lets the loader fall back to full replay safely; this is a cheap correctness check.
  Date: 2026-05-04.

- Decision: Snapshot reads are not gated on `highWaterMark` from EP-3.
  Rationale: Snapshots are written *after* a successful append, and the snapshot's `version` is the per-stream `StreamVersion`, which is monotonic without bigserial gaps. The high-water-mark concern applies to global-position-based subscribers, not per-stream readers.
  Date: 2026-05-04.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Repository layout. Working tree at `/Users/shinzui/Keikaku/bokuno/keiro`.

Sister projects:

- `kiroku` at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. The `streams` table tracks `stream_id`, `stream_name`, `stream_version`. The `events` and `stream_events` tables hold events. There is no snapshot table.
- `keiki` at `/Users/shinzui/Keikaku/bokuno/keiki`. The native `SymTransducer phi rs s ci co` exposes the joint state `(s, RegFile rs)`. The control vertex `s` is a user-defined sum and is straightforward to serialize. The register file `RegFile rs` is keiki's typed heterogeneous tuple of `(Symbol, Type)` slots — it requires a keiki-side serialization helper to encode/decode without leaking type-level machinery into keiro. Keiki does not perform serialization today (see `docs/research/02-keiki-decide-loop.md`); this plan therefore identifies that helper as a keiki-side gap (forwarded to EP-6).

Term definitions:

- *Snapshot* — a serialized representation of an aggregate's joint state `(s, RegFile rs)` (control vertex plus register file, in keiki's terminology) at a particular `StreamVersion`. Stored in a separate table; not part of the event log.
- *Snapshot policy* — a pure function deciding whether to write a snapshot after a successful command cycle. Common: every N events.
- *Snapshot codec version* — an integer identifying the wire-shape of `state`. Increments when the state's serialization format changes incompatibly. Allows hydration to detect stale snapshots and fall back.
- *Hydration short-circuit* — the decision in the command cycle to load the latest snapshot (if any), then read events from `snapshot.version + 1`, instead of replaying the entire stream.
- *GC* — periodic deletion of old snapshot rows to reclaim space. Safe at any time because snapshots are advisory.

What does **not** exist today:

- No `keiro_snapshots` table.
- No snapshot read/write API in any library.
- No snapshot policy abstraction.

The following design choices from EP-1 (`docs/plans/1-command-cycle-design-and-spike.md`) are assumed in this plan and *not* re-derived here:

- `runCommand` reads events via `Kiroku.Store.Read.readStreamForward sn (StreamVersion 0) maxBound`.
- `Decider c e s` is the keiki facade; `evolve :: s -> e -> s`; `initialState :: s`.
- `AggregateId a` is a typed wrapper introduced by EP-1.

The following from EP-2 (`docs/plans/2-codec-and-event-schema-strategy.md`):

- The `Codec e` record-of-functions shape.
- The `metadata.schemaVersion :: Int` convention.
- Upcaster chains for events.

A *separate* `Codec s` for the aggregate's state will be defined here, with its own version integer.


## Plan of Work

One milestone, design-only.

### Milestone 1 — Snapshot strategy design document

Write `docs/research/09-snapshot-strategy.md`. Self-contained. Structure:

- *Problem statement* — full-replay hydration is unbounded; snapshots short-circuit it.
- *Storage layout* — the `keiro_snapshots` table:

      CREATE TABLE keiro_snapshots (
        stream_id            BIGINT       NOT NULL,
        stream_name          TEXT         NOT NULL,
        stream_version       BIGINT       NOT NULL,
        state                JSONB        NOT NULL,  -- encodes (s, RegFile rs)
        state_codec_version  INTEGER      NOT NULL,
        taken_at             TIMESTAMPTZ  NOT NULL DEFAULT now(),
        PRIMARY KEY (stream_id),  -- one snapshot per stream; replace on write
        CONSTRAINT fk_stream FOREIGN KEY (stream_id) REFERENCES streams(stream_id) ON DELETE CASCADE
      );
      CREATE INDEX ix_keiro_snapshots_stream_name ON keiro_snapshots(stream_name);

  Rationale notes: (a) `ON DELETE CASCADE` ties snapshot lifecycle to kiroku's stream lifecycle. (b) `stream_name` indexed for ad-hoc operator queries. (c) JSONB rather than bytea so operators can read snapshots in `psql` for debugging. (d) `state` is a single JSON object because the joint `(s, RegFile rs)` is opaque to operators in any case; the `state_codec_version` is the discriminant they care about.
- *Write path* — after a successful command cycle:
  - if `policy state newVersion == True`, asynchronously fire `writeSnapshot streamId newVersion state codec`,
  - `INSERT … ON CONFLICT (stream_id) DO UPDATE` so we always keep the most recent snapshot,
  - any failure is logged but does not affect the command result.
- *Read path* — at the start of hydration:
  - `SELECT stream_version, state, state_codec_version FROM keiro_snapshots WHERE stream_id = ?`,
  - if found and `state_codec_version == codec.version`, decode the state, then `readStreamForward sn snapshot.streamVersion maxBound`, fold from the snapshot's state,
  - else (no snapshot, or codec mismatch), proceed with full replay from `(StreamVersion 0, initialState)`.
- *API* — final shape of the keiro snapshot module. Note `t` below stands for the joint `(s, RegFile rs)`:

      data SnapshotPolicy t = SnapshotPolicy (t -> StreamVersion -> Bool)
      data StateCodec t = StateCodec
        { stateEncode  :: t -> Aeson.Value
        , stateDecode  :: Aeson.Value -> Either String t
        , stateVersion :: Int
        }
      readSnapshot  :: AggregateId a -> Eff es (Maybe (StreamVersion, t))
      writeSnapshot :: AggregateId a -> StreamVersion -> t -> Eff es ()

- *Schema-change invalidation* — when an author bumps `stateVersion`, all existing snapshots are silently ignored on read; the loader falls back to full replay; operators can `TRUNCATE keiro_snapshots` to reclaim space.
- *Failure semantics* — every snapshot write/read failure is non-fatal. A read failure logs and falls through to full replay. A write failure logs and skips this snapshot opportunity (the next command cycle may write again).
- *GC* — `DELETE FROM keiro_snapshots WHERE taken_at < now() - interval '30 days'` is safe at any time. Document the operator playbook.
- *Operator commands* — `keiro snapshot rebuild --aggregate Counter` re-snapshots all existing streams of an aggregate; `keiro snapshot purge --before <date>` deletes old snapshots.
- *Integration with EP-1* — the modified `runCommand` pseudocode (joint state `(s, RegFile rs)` written as `t`):

      runCommand agg aid cmd = do
        sn <- streamName aid
        snap <- readSnapshot aid
        let t0 = (initial trans, initialRegs trans)
              where trans = aggTransducer agg
        let (startVersion, startState) = case snap of
              Just (v, t) -> (v, t)
              Nothing     -> (StreamVersion 0, t0)
        events <- readStreamForward sn startVersion maxBound
        decoded <- traverse (decodeRecorded (aggEventCodec agg)) events
        Just t1 <- pure (applyEvents (aggTransducer agg) startState decoded)
        case step (aggTransducer agg) t1 cmd of
          Just (s', regs', mev) -> do
            appendToStream sn (ExactVersion <newVersion>) [encodeForAppend (aggEventCodec agg) ev | Just ev <- [mev]]
            when (snapshotPolicyFires agg (s', regs') newVersion)
                 (writeSnapshotAsync aid newVersion (s', regs'))
          Nothing -> pure ()  -- no edge fires; CommandRejected if desired

- *Integration with EP-2* — uses a `StateCodec s` analogous to `Codec e`. Cross-link.
- *Integration with EP-3* — async projections do not use snapshots (they consume events monotonically and have their own checkpoint table). Inline projections similarly. Document explicitly so reviewers do not look for snapshot use in those paths.
- *Open questions / upstream gaps* — record:
  - kiroku could add a single `LEFT JOIN keiro_snapshots` query that returns "snapshot if any plus events from version" in one round-trip; deferred to EP-6.
  - keiki should expose a register-file serialization helper. The joint state keiro must persist is `(s, RegFile rs)`, where `RegFile rs` is keiki's typed heterogeneous tuple of `(Symbol, Type)` slots. Without help from keiki, keiro would have to consume the type-level slot list directly (via `Generic` over the register-file type, or via `Keiki.Generics`'s existing `mkInCtor` style helpers extended to registers). The cleanest interface is for keiki to expose `regFileToJSON :: RegFile rs -> Aeson.Value` and `regFileFromJSON :: Aeson.Value -> Either String (RegFile rs)` constrained appropriately. Forward to EP-6 as a Wanted keiki-side gap.

Acceptance: doc exists, references operative SQL precisely, defines every type, and a reviewer can sketch a kiroku migration script that creates the `keiro_snapshots` table without further questions.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

Write the design doc:

    # author docs/research/09-snapshot-strategy.md per Plan of Work milestone 1
    # update docs/research/00-overview.md to add the new entry


## Validation and Acceptance

All must hold:

1. `docs/research/09-snapshot-strategy.md` exists and is referenced from `docs/research/00-overview.md`.
2. The document includes the full DDL for `keiro_snapshots`.
3. The document specifies the read path's behaviour on (a) no snapshot, (b) compatible snapshot, (c) codec-version mismatch.
4. The document specifies the write path's behaviour on (a) policy returns `True`, (b) policy returns `False`, (c) write failure.
5. The document records the upstream kiroku/keiki gaps it identifies, ready for EP-6 to consume.

Phrased as observable behaviour: a reviewer who has read EP-1 and EP-2 can write a kiroku migration adding `keiro_snapshots`, write a Haskell skeleton for `readSnapshot`/`writeSnapshot`, and answer "what happens when an operator drops the snapshots table at runtime?" purely from this document.


## Idempotence and Recovery

The design document is a normal Markdown file; saving twice is a no-op. There is no spike to recover from.

If the design conflicts with a discovery from EP-1 or EP-2 implementation (e.g. EP-2 chooses a non-Aeson wire format), update this plan's design accordingly and append a revision note at the bottom.


## Interfaces and Dependencies

Libraries (consumed at design level only — no spike):

- `kiroku-store` — provides `streams` table referenced by FK; provides `readStreamForward`.
- `keiki` — provides `Decider c e s`; the `s` type is what we serialize.
- `aeson` — wire format.
- `hasql` — for the SQL statements that this plan's design specifies (the implementation MasterPlan will write the actual statements; this plan only fixes their shape).

Function signatures the design must fix (`t` = `(s, RegFile rs)`):

    -- Keiro.Snapshot
    data SnapshotPolicy t
    data StateCodec t
    readSnapshot  :: AggregateId a -> Eff es (Maybe (StreamVersion, t))
    writeSnapshot :: AggregateId a -> StreamVersion -> t -> Eff es ()
    snapshotPolicyEvery      :: Int -> SnapshotPolicy t
    snapshotPolicyOnTerminal :: (t -> Bool) -> SnapshotPolicy t
    snapshotPolicyNever      :: SnapshotPolicy t

Downstream consumers:

- EP-1 (command cycle) — `runCommand` design must be updated to consult snapshots; cross-link.
- EP-6 (upstream roadmap) — record kiroku-side (`LEFT JOIN keiro_snapshots` helper, optional) and keiki-side (register-file serialization helper, Wanted) gaps identified here.


## Revisions

- 2026-05-04: Replaced `Decider`/`s` references with `SymTransducer`/`(s, RegFile rs)` throughout. Snapshots now persist the joint state including the register file — required because the register file is where keiki keeps timers, retry counters, and other workflow-relevant slot values that ε-edges and `step` consume. Added a Wanted keiki-side gap for a `RegFile`-serialization helper, since keiro cannot decode the typed heterogeneous tuple without keiki's cooperation. Reason: aligning EP-4 with the EP-1 contract correction (SymTransducer, not Decider).
