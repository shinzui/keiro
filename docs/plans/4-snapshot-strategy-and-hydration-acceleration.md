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

The user-visible behaviour the eventual library will deliver: aggregate authors annotate their `EventStream` (EP-1's `EventStream phi rs s ci co` contract over keiki's native `SymTransducer`, *not* the legacy `Keiki.Decider` facade) with a snapshot policy (`every N events`); hydration paths transparently use the latest snapshot when present and fall back to full replay when not; operators can purge snapshots safely at any time.


## Progress

- [x] M1.1 — Survey snapshot designs from `docs/research/05-workflow-prior-art.md` (Marten, Akka, Eventide); pick one shape. Completed 2026-05-06: adopted the Marten sidecar shape; rejected Akka's pluggability (parent MasterPlan's "Postgres-only" decision) and Eventide's silence on the topic; recorded in §1 of `docs/research/09-snapshot-strategy.md`.
- [x] M1.2 — Design the `keiro_snapshots` table layout. Completed 2026-05-06: full DDL plus the `regfile_shape_hash` secondary discriminant added per the keiki survey's "register-file shape hash" hint. Rationale recorded column-by-column in §2 of `docs/research/09-snapshot-strategy.md`.
- [x] M1.3 — Design the snapshot read path: load snapshot, read events from `snapshot_version+1`, fold through `evolve`. Completed 2026-05-06: §6 of `docs/research/09-snapshot-strategy.md`. Includes the `SnapshotRead` outcome enumeration (`Hit` / `Miss` / `IncompatibleCodec` / `IncompatibleShape` / `DecodeError`) and the read-during-write race analysis.
- [x] M1.4 — Design the snapshot write path: pure post-hydration policy hook, written outside the command-cycle's optimistic-concurrency tx. Completed 2026-05-06: §7 of `docs/research/09-snapshot-strategy.md`. Includes the `INSERT … ON CONFLICT (stream_id) DO UPDATE … WHERE keiro_snapshots.stream_version < EXCLUDED.stream_version` monotonicity guard and the fire-and-forget rationale (vs. queue-backed retry).
- [x] M1.5 — Design the schema-change invalidation: codec version of `state` recorded with the snapshot; hydration falls back to full replay when codec versions disagree. Completed 2026-05-06: §8 of `docs/research/09-snapshot-strategy.md`. Promoted to *two* discriminants (`state_codec_version` plus `regfile_shape_hash`) to handle slot-list reshapes the codec-version integer alone cannot detect.
- [x] M1.6 — Design the GC story: snapshots are never load-bearing for correctness, so they can be deleted at any time. Completed 2026-05-06: §9 of `docs/research/09-snapshot-strategy.md`. 30-day default retention; `ix_keiro_snapshots_taken_at` index supports the GC query; operator playbook cross-referenced from §10.
- [x] M2.1 — Write `docs/research/09-snapshot-strategy.md`. Completed 2026-05-06. 18 sections, ~31 KB. Self-contained per the ExecPlan spec; a reviewer with EP-1, EP-2, and this doc can write the migration, the Haskell skeleton, and answer every operational question §17 enumerates.
- [x] M2.2 — Update `docs/research/00-overview.md`. Completed 2026-05-06: added the index entry summarizing the sidecar table, the value-level `StateCodec`, the policy types, the Streamly hydration short-circuit, and the shared keiki gap (consolidated by EP-6).


## Surprises & Discoveries

- 2026-05-06: The keiki survey at `docs/research/02-keiki-decide-loop.md` §"Schema" carries a one-line hint that "register-file shape changes invalidate existing snapshots (snapshot validation uses a register-file shape hash)." This hint was not anchored anywhere else in the plan inputs; without it, the EP-4 plan's single `state_codec_version` integer would have silently failed to detect slot-list reshapes (swapping two slots of the same JSON type, renaming a slot whose `Symbol` is not visible in the encoded JSON). Promoted the hash to a first-class column (`regfile_shape_hash TEXT NOT NULL`) and a `SnapshotRead` outcome (`SnapshotIncompatibleShape`). **Cascade**: EP-6 gains a second keiki-side gap (a `KnownRegFileShape` class with a stable `shapeHash` derivation) sharing customers with the existing `RegFile <-> Aeson.Value` helper. Evidence: §2 of `docs/research/09-snapshot-strategy.md` (column rationale); §3 (the `regFileShapeHash :: Text` field on `StateCodec`); §6 (the read-path classification of incompatible-shape rows); §15 gap (2).

- 2026-05-06: kiroku's hard-delete protection (`protect_deletion` / `protect_truncation` triggers in `kiroku-store/sql/schema.sql`, gated by the `kiroku.enable_hard_deletes` GUC) means the `ON DELETE CASCADE` on `fk_keiro_snapshots_stream` is *defensively correct but rarely fires*. Under normal operation an operator cannot delete a row from `streams`; the cascade only triggers under the explicit GDPR / maintenance opt-in. This is fine — the cascade is the right semantic when it does fire — but the design doc must call it out so reviewers do not assume snapshot rows are auto-purged on every stream-level cleanup. Documented in §2 ("`ON DELETE CASCADE`" rationale paragraph) of `docs/research/09-snapshot-strategy.md`. No EP-1/EP-2/EP-3/EP-5 impact; EP-6 may want to record that keiro should expose its own hard-delete GUC analogue for the `keiro snapshot purge --all` operator command (§10).

- 2026-05-06: The snapshot codec deliberately does *not* use an upcaster chain — a structural departure from EP-2's `Codec e` design. The reason is that snapshots are advisory: a stale row falls through to full replay, so there is no correctness reason to read an old format; aggregate authors bumping the codec version reset every snapshot for the aggregate. This makes the snapshot codec dramatically simpler (one integer version, no upcaster chain) but is easy to misread as inconsistency between EP-2 and EP-4. Documented in §3 ("What this plan does *not* inherit") and §12 ("No upcaster chain on `StateCodec`") of `docs/research/09-snapshot-strategy.md`. **Cascade**: none beyond the cross-link; EP-6 records the asymmetry as intentional rather than as a gap.


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

- Decision: Snapshot policy is a function `(s, RegFile rs) -> StreamVersion -> Bool` carried alongside the `EventStream phi rs s ci co` contract from EP-1 (built on keiki's native `SymTransducer`, *not* the legacy `Keiki.Decider` facade).
  Rationale: Common policies are "every N events" (`\_ v -> v `mod` 100 == 0`), "on terminal state" (`\(s,_) _ -> isTerminal s`), or "never" (`\_ _ -> False`). A pluggable function avoids hard-coding policy choices. The policy reads the *joint* state `(s, RegFile rs)` because the register file may carry workflow-relevant slots (timer fire-times, retry counters) that legitimately influence "should we snapshot now".
  Date: 2026-05-04.

- Decision: The snapshot record includes a `state_codec_version :: Int` field.
  Rationale: When the state codec changes incompatibly, all existing snapshots become invalid. Comparing codec versions on read lets the loader fall back to full replay safely; this is a cheap correctness check.
  Date: 2026-05-04.

- Decision: Snapshot reads are not gated on `highWaterMark` from EP-3.
  Rationale: Snapshots are written *after* a successful append, and the snapshot's `version` is the per-stream `StreamVersion`, which is monotonic without bigserial gaps. The high-water-mark concern applies to global-position-based subscribers, not per-stream readers.
  Date: 2026-05-04.

- Decision: Promote the register-file shape hash to a first-class column (`regfile_shape_hash TEXT NOT NULL`) and a `SnapshotRead` outcome (`SnapshotIncompatibleShape`), independent of `state_codec_version`.
  Rationale: The keiki survey at `docs/research/02-keiki-decide-loop.md` §"Schema" notes that "register-file shape changes invalidate existing snapshots (snapshot validation uses a register-file shape hash)." The codec-version integer alone does not detect every register-file reshape: an aggregate author can swap two slots of the same JSON type or rename a slot whose `Symbol` does not appear in the encoded JSON without bumping the codec version, and the joint state would silently round-trip to a wrong shape. The shape hash is a cheap secondary discriminant (`Text`, derived once at compile time) that closes this gap. EP-4 is the only customer for the shape hash today; the helper is a single-line keiki-side gap consolidated by EP-6.
  Date: 2026-05-06.

- Decision: `StateCodec` carries one `stateCodecVersion :: Int` and *no* upcaster chain, in deliberate contrast to EP-2's `Codec e`.
  Rationale: Snapshots are advisory — a stale row falls through to full replay rather than blocking a working command path. There is no correctness reason to read an old snapshot format; the next command-cycle's policy fire writes a fresh snapshot at the current version. An upcaster chain on `StateCodec` would be both unused (no production load reads the chain) and a maintenance burden. The asymmetry with EP-2 is intentional and documented in §3 ("What this plan does *not* inherit") and §12 ("No upcaster chain on `StateCodec`") of `docs/research/09-snapshot-strategy.md`.
  Date: 2026-05-06.

- Decision: Snapshot writes are fire-and-forget (post-commit, asynchronous, no durable retry queue). A failed write is logged and discarded; the next policy fire writes a fresher snapshot.
  Rationale: A pgmq-backed retry queue (the substrate EP-3 §6 uses for the outbox) would give durable retry, but the use case is wrong: a stale failed-write has no value once a fresher one is queueable, and pgmq's at-least-once redelivery would re-do work indefinitely against a snapshot that the next command's policy fire will overwrite anyway. EP-3's outbox uses pgmq because *missed messages are correctness failures*; here, missed snapshots are cache misses. The asymmetry justifies the simpler shape (`forkAsync` style fire-and-forget) recorded in §7 of `docs/research/09-snapshot-strategy.md`.
  Date: 2026-05-06.

- Decision: The `ON CONFLICT (stream_id) DO UPDATE` clause carries a monotonicity guard `WHERE keiro_snapshots.stream_version < EXCLUDED.stream_version`.
  Rationale: Two concurrent retry-winners — a command at `streamVersion 100` whose snapshot write is delayed and a later command at `streamVersion 110` whose snapshot write completes first — must converge to the higher-version snapshot. Without the guard, the `100`-writer's late-arriving update overwrites the `110`-writer's row, regressing the snapshot to a stale version. The guard makes the lower-version writer's update a no-op; the higher-version snapshot wins. Recorded in §7 of `docs/research/09-snapshot-strategy.md`.
  Date: 2026-05-06.


## Outcomes & Retrospective

EP-4 closed 2026-05-06 with `docs/research/09-snapshot-strategy.md` (18 sections, ~31 KB) and an updated `docs/research/00-overview.md` index. Design-only; no spike, per the EP-4 plan's Decision Log (snapshots are storage plumbing whose every component has been implemented many times and would not retire any unknown if prototyped).

What the design fixes:

- **Storage**: a single sidecar `keiro_snapshots` table keyed on kiroku's `stream_id`, holding the encoded joint state `(s, RegFile rs)` plus two independent staleness discriminants (`state_codec_version :: Int` and `regfile_shape_hash :: Text`). Rationale recorded column-by-column in §2 of the design doc; full DDL fits the EP-4 plan's M1.2 acceptance.
- **Codec**: a value-level `StateCodec t` record-of-functions, sibling of EP-2's `Codec e` but versioned at the aggregate level rather than per record, with no upcaster chain (snapshots are advisory; bumping the version invalidates every existing snapshot). §3 of the design doc.
- **Policy**: a pure function `(s, RegFile rs) -> StreamVersion -> Bool` with three named constructors (`snapshotPolicyEvery n`, `snapshotPolicyOnTerminal isTerminal`, `snapshotPolicyNever`). §4.
- **Read path**: hydration short-circuits the EP-1 Streamly `Stream → Fold` pipeline by parameterizing the source's start cursor (`StreamVersion (snap.streamVersion + 1)` on hit, `StreamVersion 0` on miss) and the fold's initial accumulator (decoded snapshot state on hit, `(initial t, initialRegs t)` on miss). Same pipeline, no parallel code path — matching the parent MasterPlan's "Streamly substrate" Integration Point. §6.
- **Write path**: post-commit, asynchronous, gated by an `INSERT … ON CONFLICT (stream_id) DO UPDATE … WHERE keiro_snapshots.stream_version < EXCLUDED.stream_version` monotonicity guard so stale writes cannot regress fresher snapshots. §7.
- **Schema-change invalidation**: the read path's two-discriminant fall-through (`state_codec_version` mismatch *or* `regfile_shape_hash` mismatch returns `Nothing` to the caller, with a logged warning); operators can `TRUNCATE keiro_snapshots` to accelerate convergence. §8.
- **GC**: 30-day default retention via `DELETE FROM keiro_snapshots WHERE taken_at < now() - interval '30 days'` (`ix_keiro_snapshots_taken_at` index). Snapshots are advisory; deletion is correctness-safe. §9.
- **Operator commands**: five `keiro snapshot` subcommands (`list`, `show`, `purge`, `rebuild`, `stats`). §10.
- **Integrations**: §§11–14 record the EP-1, EP-2, EP-3 (no use of snapshots), and EP-5 cross-links explicitly so reviewers do not look for snapshot use in the wrong place.
- **Testing**: three test classes the production library will run — round-trip (per-codec QuickCheck), hydration equivalence (snapshot + tail = full replay), schema-change fall-through. §16.
- **How to verify**: §17 lists seven concrete questions a reviewer must be able to answer purely from the doc.

Gaps forwarded to EP-6:

1. **keiki: `RegFile rs <-> Aeson.Value` helper** — shared with EP-1 (`docs/research/06-command-cycle-design.md` §14) and EP-2 (`docs/research/07-codec-strategy.md` §12). Three customers, one helper. **[CLOSED 2026-05-14 — shipped as the new sibling package `keiki-codec-json` v0.1.0.0 (`Keiki.Codec.JSON.regFileToJSON`/`regFileFromJSON`/`regFileToEncoding` + TH `deriveRegFileCodec`). Keiro-side integration tracked by EP-9 (`docs/plans/9-integrate-keiki-codec-json-into-keiro-snapshot-path.md`), queued waiting on EP-37 Hackage upload.]**
2. **keiki: `KnownRegFileShape rs` class with stable `shapeHash` derivation** — EP-4 is the only customer; could land alongside (1). **[CLOSED 2026-05-14 — shipped in core keiki as `Keiki.Shape.regFileShapeHash :: forall rs. KnownRegFileShape rs => Proxy rs -> Text` (SHA-256 over canonical `[(Symbol, TypeRep)]` rendering). Lands together with (1) as predicted.]**
3. **kiroku: optional `lookupStreamId :: StreamName -> Eff es (Maybe StreamId)` helper** — performance-only, not correctness; recorded as a candidate optimization rather than a requirement. **[CLOSED 2026-05-14 — shipped as `Kiroku.Store.Read.lookupStreamId` (`kiroku-store/src/Kiroku/Store/Read.hs:163–167`).]**

Compared against the original EP-4 plan: the design grew one column (`regfile_shape_hash`) beyond what the plan sketched, prompted by the keiki survey hint about register-file shape hashes — see Surprises & Discoveries entry 1. Otherwise the design landed as the plan sketched, with prose elaboration (constant-memory Streamly inheritance, monotonicity guard rationale, fire-and-forget vs. queue-backed retry comparison, EP-3 explicit non-use, EP-5 explicit relationship to v2 named-step snapshots) added to make the doc self-contained per the ExecPlan spec.

Acceptance per §17 of the design doc:

1. ✓ DDL present (§2), idempotent, references operative Postgres types precisely.
2. ✓ Read path's three branches (hit / miss / mismatch) all specified (§6).
3. ✓ Write path's three branches (policy fires / does not / write fails) all specified (§§4, 7).
4. ✓ Upstream gaps recorded for EP-6 consumption (§15).
5. ✓ Failure semantics make snapshots advisory throughout (§§6, 7, 8).

The next implementable plans in the parent MasterPlan are EP-5 (workflow roadmap; no hard deps) and EP-6 (upstream roadmap; hard-deps on every other plan, so blocked until EP-5 closes).


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
- The keiro ⇄ keiki contract is EP-1's `EventStream phi rs s ci co` record over keiki's native `SymTransducer phi rs s ci co` (operations `step`, `delta`, `omega`, `applyEvent`, `applyEvents`, `reconstitute`). The legacy `Keiki.Decider` facade is *not* used (it would lose the register file `RegFile rs` and ε-edges that snapshots must persist). The state EP-4 serializes is the *joint* `(s, RegFile rs)`, not just `s`.
- `Stream a` is a typed wrapper introduced by EP-1 (named `AggregateId a` until 2026-05-13; renamed across the research foundation per the parent MasterPlan's 2026-05-13 Decision Log + Revisions entries).

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
      readSnapshot  :: Stream a -> Eff es (Maybe (StreamVersion, t))
      writeSnapshot :: Stream a -> StreamVersion -> t -> Eff es ()

- *Schema-change invalidation* — when an author bumps `stateVersion`, all existing snapshots are silently ignored on read; the loader falls back to full replay; operators can `TRUNCATE keiro_snapshots` to reclaim space.
- *Failure semantics* — every snapshot write/read failure is non-fatal. A read failure logs and falls through to full replay. A write failure logs and skips this snapshot opportunity (the next command cycle may write again).
- *GC* — `DELETE FROM keiro_snapshots WHERE taken_at < now() - interval '30 days'` is safe at any time. Document the operator playbook.
- *Operator commands* — `keiro snapshot rebuild --aggregate Counter` re-snapshots all existing streams of an aggregate; `keiro snapshot purge --before <date>` deletes old snapshots.
- *Integration with EP-1's Streamly hydration pipeline* — EP-1 (`docs/plans/1-command-cycle-design-and-spike.md`) expresses hydration as a Streamly `Stream (Eff es) RecordedEvent` consumed by a `Fold (Eff es) RecordedEvent (s, RegFile rs)`. The snapshot path is *not* a separate code path; it is the same pipeline with two differences: (1) the source `Stream` is sourced from `readStreamForward sn (snapshot.streamVersion + 1) maxBound` instead of `(StreamVersion 0)`; (2) the `Fold`'s initial accumulator is the decoded snapshot state instead of `(initial t, initialRegs t)`. This means snapshot-accelerated hydration retains constant-memory behaviour for the tail and reuses every Streamly combinator EP-1 sets up. State this explicitly in the design doc so reviewers do not look for a parallel snapshot-load implementation.

- *Integration with EP-1* — the modified `runCommand` pseudocode (joint state `(s, RegFile rs)` written as `t`):

      runCommand agg aid cmd = do
        sn <- streamName aid
        snap <- readSnapshot aid
        let t0 = (initial trans, initialRegs trans)
              where trans = esTransducer agg
        let (startVersion, startState) = case snap of
              Just (v, t) -> (v, t)
              Nothing     -> (StreamVersion 0, t0)
        events <- readStreamForward sn startVersion maxBound
        decoded <- traverse (decodeRecorded (esEventCodec agg)) events
        Just t1 <- pure (applyEvents (esTransducer agg) startState decoded)
        case step (esTransducer agg) t1 cmd of
          Just (s', regs', mev) -> do
            appendToStream sn (ExactVersion <newVersion>) [encodeForAppend (esEventCodec agg) ev | Just ev <- [mev]]
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
- `keiki` — provides the native `SymTransducer phi rs s ci co` (consumed via EP-1's `EventStream phi rs s ci co` contract; the legacy `Keiki.Decider` facade is *not* used). The serialized payload is the *joint* state `(s, RegFile rs)`, with `RegFile rs` decoded via the keiki-side register-file helper that is a Wanted gap consolidated by EP-6.
- `aeson` — wire format.
- `hasql` — for the SQL statements that this plan's design specifies (the implementation MasterPlan will write the actual statements; this plan only fixes their shape).

Function signatures the design must fix (`t` = `(s, RegFile rs)`):

    -- Keiro.Snapshot
    data SnapshotPolicy t
    data StateCodec t
    readSnapshot  :: Stream a -> Eff es (Maybe (StreamVersion, t))
    writeSnapshot :: Stream a -> StreamVersion -> t -> Eff es ()
    snapshotPolicyEvery      :: Int -> SnapshotPolicy t
    snapshotPolicyOnTerminal :: (t -> Bool) -> SnapshotPolicy t
    snapshotPolicyNever      :: SnapshotPolicy t

Downstream consumers:

- EP-1 (command cycle) — `runCommand` design must be updated to consult snapshots; cross-link.
- EP-6 (upstream roadmap) — record kiroku-side (`LEFT JOIN keiro_snapshots` helper, optional) and keiki-side (register-file serialization helper, Wanted) gaps identified here.


## Revisions

- 2026-05-04: Replaced `Decider`/`s` references with `SymTransducer`/`(s, RegFile rs)` throughout. Snapshots now persist the joint state including the register file — required because the register file is where keiki keeps timers, retry counters, and other workflow-relevant slot values that ε-edges and `step` consume. Added a Wanted keiki-side gap for a `RegFile`-serialization helper, since keiro cannot decode the typed heterogeneous tuple without keiki's cooperation. Reason: aligning EP-4 with the EP-1 contract correction (SymTransducer, not Decider).

- 2026-05-08: Closed the gap left by the 2026-05-04 revision, which claimed "Replaced Decider/s references throughout" but missed four spots. Updated: (1) Vision/Scope user-visible-behaviour paragraph (line 26 — "annotate their `Decider`" → "annotate their `EventStream` (EP-1's `EventStream phi rs s ci co` contract over keiki's native `SymTransducer`, not the legacy `Keiki.Decider` facade)"); (2) Decision Log "Snapshot policy" entry (line 64 — `Decider` → `EventStream phi rs s ci co`, plus the policy now reads the joint `(s, RegFile rs)`); (3) "Inputs from EP-1" assumption list (line 156 — replaced the `Decider c e s` line with an explicit statement that the contract is `EventStream phi rs s ci co` over `SymTransducer`); (4) "Interfaces and Dependencies" keiki entry (line 281 — replaced "provides `Decider c e s`" with "provides the native `SymTransducer phi rs s ci co`, consumed via EP-1's `EventStream phi rs s ci co` contract"). Reason: `Keiki.Decider` is a legacy compatibility facade for the old system; keiro must never rely on it. Found and fixed during the cross-cutting verification pass recorded in the parent MasterPlan (`docs/masterplans/1-keiro-research-foundation.md` Surprises & Discoveries entry of 2026-05-08).

- 2026-05-04: Added an *Integration with EP-1's Streamly hydration pipeline* subsection to the M1 design-doc outline, making explicit that snapshot-accelerated hydration is the same Streamly `Stream → Fold` pipeline as full hydration — only the source's start `StreamVersion` and the fold's initial accumulator differ. Reason: matches the MasterPlan's new "Streamly substrate" Integration Point and the corresponding EP-1 revision; prevents reviewers from looking for a parallel snapshot-load code path.

- 2026-05-13: **Renamed the typed event-stream-id wrapper `AggregateId a` → `Stream a`** in this plan body, cascaded from the parent MasterPlan's 2026-05-13 rename decision. **Updates this revision applied (this plan only)**: line 157 ("Inputs from EP-1" assumption list), lines 208-209 (the *API* design-doc-outline subsection's `readSnapshot` / `writeSnapshot` signatures), lines 290-291 (the closing *Function signatures* summary). The published EP-4 design doc at `docs/research/09-snapshot-strategy.md` is also updated in place (it is not yet under the closed-doc convention as of 2026-05-13) — see its new 2026-05-13 Revisions entry. The parent MasterPlan's 2026-05-13 Decision Log entry records the alternative-comparison reasoning: an intermediate `StreamRef a` selection from the first 2026-05-13 pass was discarded after team feedback in favour of the bare `Stream a`, accepting the name collision with `Streamly.Data.Stream.Stream` and resolving it at use sites with qualified imports. EP-4's snapshot module is one of the keiro modules that names the typed `Stream a` newtype on its public surface (`readSnapshot :: Stream a -> Eff es (...)` and `writeSnapshot :: Stream a -> ...`); when the implementation MasterPlan ships the corresponding Haskell module, it must `import qualified Streamly.Data.Stream as Stream` if the snapshot path also consumes Streamly streams (it does — the Streamly hydration short-circuit per §"Integration with EP-1's Streamly hydration pipeline" reads from `streamReadFrom` which returns a `Streamly.Data.Stream.Stream`). EP-4 status remains Complete; only the type name is refreshed. Reason: cascade from the MasterPlan rename; the user observed that `AggregateId` is too tied to DDD and keiro is a more general framework, and team feedback after the StreamRef intermediate selection preferred the bare `Stream` name.
