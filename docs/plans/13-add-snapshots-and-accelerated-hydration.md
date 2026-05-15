---
id: 13
slug: add-snapshots-and-accelerated-hydration
title: "Add snapshots and accelerated hydration"
kind: exec-plan
created_at: 2026-05-15T15:00:21Z
intention: "intention_01krp2azwjessavsfva1he2gx1"
master_plan: "docs/masterplans/2-keiro-library-bootstrap-and-v1-implementation-start.md"
---

# Add snapshots and accelerated hydration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan makes long-lived event streams cheap to command by adding advisory snapshots. After completion, an `EventStream` with a snapshot policy can persist encoded `(state, RegFile rs)` into `keiro_snapshots`; later hydration starts from the newest compatible snapshot and replays only the tail events. If the snapshot is missing, stale, unreadable, or deleted by an operator, `runCommand` falls back to EP-12's full replay and still behaves correctly.

The behavior is visible in tests: a fixture stream writes enough events to trigger a snapshot, a later command hydrates from the snapshot plus tail, and deliberately corrupting the snapshot row causes full replay rather than command failure.


## Progress

- [x] M1 — Create `Keiro.Snapshot.Schema`, `Keiro.Snapshot.Codec`, and `Keiro.Snapshot.Policy` with the `keiro_snapshots` table and state codec helpers. Started at 2026-05-15T18:27:17Z; completed at 2026-05-15T18:37:06Z.
- [x] M2 — Integrate `Keiki.Shape.regFileShapeHash` and `Keiki.Codec.JSON.regFileToJSON` / `regFileFromJSON` into the default `StateCodec` path. Completed at 2026-05-15T18:37:06Z.
- [x] M3 — Add snapshot read support to hydration while preserving full replay fallback. Completed at 2026-05-15T18:37:06Z.
- [x] M4 — Add post-commit snapshot writes with monotonic update guards. Completed at 2026-05-15T18:37:06Z.
- [x] M5 — Add integration tests for snapshot round trip, stale hash/version fallback, corrupt JSON fallback, and operator truncation. Completed at 2026-05-15T18:37:06Z.


## Surprises & Discoveries

- Kiroku prevents updates to event payload rows through an immutability trigger, so the snapshot-acceleration test cannot prove tail replay by corrupting an old event. The test now proves acceleration by switching to a stricter compatible transducer that cannot full-replay the old events but can proceed from the compatible snapshot seed.

Evidence:

```text
ConnectionError "SessionUsageError ... ServerError \"P0001\" \"Immutable table: events cannot be updated\" ..."
```

- `cabal test all` runs sibling dependency suites from the local `cabal.project`, including `keiki-test`, `keiki-codec-json-test`, and `kiroku-store-test`. The full run passed after the snapshot implementation.

Evidence:

```text
Test suite keiro-test: PASS
Test suite kiroku-store-test: PASS
```


## Decision Log

- Decision: Snapshots are advisory and never load-bearing.
  Rationale: The research foundation explicitly chose fall-through semantics. A corrupted snapshot table must not break command correctness.
  Date: 2026-05-15.

- Decision: Use keiki's shipped JSON codec and shape hash directly rather than hand-rolling register-file walkers.
  Rationale: `Keiki.Shape.regFileShapeHash` and `Keiki.Codec.JSON` now exist locally, closing the upstream gap that the research document originally described.
  Date: 2026-05-15.


## Outcomes & Retrospective

Implemented advisory snapshots for the v1 command path. The library now owns `keiro_snapshots`, exposes schema initialization and default snapshot codecs, uses keiki's shape hash and JSON register-file codec, hydrates from compatible snapshots with full replay fallback, and writes post-commit snapshots according to `SnapshotPolicy` without replacing newer rows with older versions.

Validation passed with:

```bash
cabal test all
```

The focused keiro snapshot tests cover writing snapshots, snapshot-assisted hydration, corrupt snapshot JSON fallback, shape-hash mismatch fallback, and operator truncation fallback.


## Context and Orientation

This plan depends on EP-12's correct full-replay hydration. It also consumes `docs/research/09-snapshot-strategy.md` and the existing queued plan `docs/plans/9-integrate-keiki-codec-json-into-keiro-snapshot-path.md`.

Snapshots store the joint state `(s, RegFile rs)` for one event stream. They are internal acceleration, not user query data. They differ from read models in EP-14: a read model must reject stale schemas, while a snapshot silently falls through to replay. The table is keyed by kiroku's numeric `StreamId`, obtainable via `Kiroku.Store.Read.lookupStreamId`. Kiroku's `RecordedEvent.originalVersion` and `AppendResult.streamVersion` identify how far the snapshot is valid.

Keiki now provides the upstream pieces that EP-4 requested. `Keiki.Shape.regFileShapeHash :: Proxy rs -> Text` computes a stable hash of a register-file shape. `Keiki.Codec.JSON.regFileToJSON`, `regFileFromJSON`, and `regFileToEncoding` serialize register files whose slot values have Aeson instances. The implementation must read `/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Shape.hs` and `/Users/shinzui/Keikaku/bokuno/keiki/keiki-codec-json/src/Keiki/Codec/JSON.hs` before coding.


## Plan of Work

Milestone 1 creates the schema and module structure. Add `src/Keiro/Snapshot/Schema.hs` with idempotent DDL for `keiro_snapshots`. New keiro modules must import `Keiro.Prelude` for common types, JSON classes, and lens operators. The table should include `stream_id`, `stream_version`, encoded state JSON, `state_codec_version`, `regfile_shape_hash`, and timestamps. Add an index or primary key on `stream_id`. Keep DDL separate from kiroku's schema; keiro owns this table.

Milestone 2 implements the codec. In `Keiro.Snapshot.Codec`, define helpers that combine an application-provided state codec for `s` with `RegFileToJSON rs` and `KnownRegFileShape rs`. Encode the state and register file in a stable JSON object so operators can inspect it. Use `regFileToEncoding` for the write path if the code stores encoded bytes before JSONB, otherwise document why `regFileToJSON` is sufficient.

Milestone 3 modifies EP-12 hydration. Add a function such as `hydrateWithSnapshot` that looks up the stream id, reads the newest snapshot matching `state_codec_version` and `regfile_shape_hash`, decodes it, and then calls the same Streamly tail replay fold starting at the snapshot's stream version. Any recoverable failure returns `Nothing` and full replay proceeds. Log or expose a warning hook if the codebase has one; do not fail `runCommand`.

Milestone 4 writes snapshots after successful command commits. Use the `SnapshotPolicy` from EP-11 to decide whether the post-command joint state should be snapshotted. The write should happen after append success. Use an `ON CONFLICT DO UPDATE` guard that refuses to replace a newer snapshot with an older stream version.

Milestone 5 tests the behavior. Use real Postgres. Write a fixture aggregate with a non-empty register file, run commands until a snapshot is produced, assert the row exists, run another command with instrumentation or counters proving the tail replay starts after the snapshot, then corrupt the row and prove the next command still succeeds via full replay.


## Concrete Steps

Re-check current upstream helpers:

```bash
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Shape.hs
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/keiki/keiki-codec-json/src/Keiki/Codec/JSON.hs
sed -n '1,180p' /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Read.hs
```

Run validation:

```bash
cabal build all
cabal test all
```

Expected focused output:

```text
keiro-snapshot-integration
  writes a snapshot after policy threshold
  hydrates from snapshot and replays tail
  falls back when shape hash mismatches
  falls back when snapshot JSON is corrupt
```


## Validation and Acceptance

Acceptance requires an idempotent keiro-owned snapshot schema, a default `StateCodec` path using `Keiki.Codec.JSON`, and integration tests proving both acceleration and fallback. A snapshot decode failure must not surface as `CommandError` from `runCommand`.

The implementation must not store projections or read-model rows in `keiro_snapshots`, and it must not make snapshot writing part of the user SQL transaction from `runCommandWithSql` unless a later recorded decision changes the design.


## Idempotence and Recovery

The schema migration must use `CREATE TABLE IF NOT EXISTS` and safe index creation. Snapshot writes must be monotonic so retrying an old write cannot overwrite a newer row. Operators should be able to `TRUNCATE keiro_snapshots` and then rerun commands; the only effect should be slower full replay until new snapshots are written.


## Interfaces and Dependencies

This plan must expose:

```haskell
module Keiro.Snapshot
  ( hydrateWithSnapshot
  , writeSnapshot
  )

module Keiro.Snapshot.Schema
  ( initializeSnapshotSchema
  )

module Keiro.Snapshot.Codec
  ( defaultStateCodec
  )
```


## Revision Notes

2026-05-15: Implemented the plan end-to-end, marked all milestones complete, recorded the kiroku immutability discovery that changed the snapshot acceleration test shape, and captured the passing `cabal test all` validation evidence.

Dependencies include EP-12 hydration functions, `Kiroku.Store.Read.lookupStreamId`, hasql statements or transactions for keiro-owned tables, `Keiki.Shape.regFileShapeHash`, `Keiki.Codec.JSON.RegFileToJSON`, and Aeson.
