---
id: 125
slug: lock-hard-delete-against-concurrent-appends-and-classify-transient-conflicts-as-retryable
title: "Lock hard-delete against concurrent appends and classify transient conflicts as retryable"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
---

# Lock hard-delete against concurrent appends and classify transient conflicts as retryable

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

kiroku is the PostgreSQL event store that every keiro service persists into. Its source lives in a sibling checkout at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (all kiroku file paths below are relative to that directory; keiro paths are relative to this repository, `/Users/shinzui/Keikaku/bokuno/keiro`). This plan fixes the two write-path defects confirmed by the July 2026 kiroku review, findings KRW-1 and KRW-2 of the parent master plan (`docs/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md`).

KRW-1 (HIGH): `hardDeleteStream` never locks the stream row before running its seven-statement delete transaction. An append that commits inside a specific window turns acknowledged, durably-committed events into permanent orphans: rows in the global `$all` log that point at a stream that no longer exists. They are invisible to per-stream and category readers, still visible to `$all` readers, and can never be purged again. keiro's workflow garbage collector calls `hardDeleteStream` in an endless loop, so this race is exercised continuously in production, not only by rare operator deletes.

KRW-2 (MEDIUM): each append interpreter retries a transient PostgreSQL conflict (SQLSTATE `40001` serialization failure or `40P01` deadlock) exactly once. If the retry hits a second transient conflict, the error is surfaced as `UnexpectedServerError` — a constructor whose documentation says "not generally retryable — investigate". keiro's process-manager and router workers trust that documentation and halt fatally on it. Two consecutive deadlocks — an ordinary event under load — therefore kills a worker that should simply have retried.

After this plan: a hard delete opens by taking a `FOR UPDATE` row lock on the stream, so concurrent appends and links serialize against it and either land wholly before the purge (cleanly deleted) or wholly after it (the stream is gone; the append re-creates a fresh stream, which is the documented semantics). And a transient conflict always surfaces on a new, explicitly-retryable `TransientConflict` constructor, keiro's classifiers treat it as transient, and the misleading haddocks are corrected. Both fixes are demonstrated by tests that fail against today's code.


## Progress

- [ ] M1: new spec `kiroku-store/test/Test/HardDeleteConcurrency.hs` written and wired into `test/Main.hs` and the cabal `other-modules` list; the deterministic two-connection interleaving test reproduces the orphan window and fails against unmodified code.
- [ ] M1: racy API-level invariant test (concurrent `hardDeleteStream` vs `appendToStream` loop) and the `linkToStream`-racing-delete test written.
- [ ] M2: `findStreamIdForUpdateStmt` added to `kiroku-store/src/Kiroku/Store/SQL.hs`; `HardDeleteStream` in `kiroku-store/src/Kiroku/Store/Effect.hs` uses it; all M1 tests pass; `hardDeleteStream` haddock documents the concurrency contract.
- [ ] M3: `TransientConflict` constructor added to `StoreError` in `kiroku-store/src/Kiroku/Store/Error.hs`; `mapServerError` and `mapGenericUsageError` map `40001`/`40P01` to it; deterministic mapping unit tests pass.
- [ ] M3: haddocks corrected in `kiroku-store/src/Kiroku/Store/Transaction.hs` (lines 92-93 and 104-109); the racy leak test in `kiroku-store/test/Test/Concurrency.hs` strengthened.
- [ ] M3: `mapUniqueViolation` gains explicit `stream_events_pkey` and `ux_stream_events_stream_version` branches; same-stream deterministic-id duplicate test added.
- [ ] M4: keiro side — `isTransientStoreError` in `keiro/src/Keiro/ProcessManager.hs` classifies `TransientConflict` as transient; regression test added to `keiro/test/Main.hs`; `kiroku-store` bounds bumped; `cabal test keiro-test` passes.
- [ ] Living sections of this plan updated; ADR distillation pass done (hard-delete concurrency contract and the retryable-SQLSTATE taxonomy are ADR candidates per the master plan).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fix KRW-2 in kiroku with a new `TransientConflict` constructor rather than patching keiro's classifiers or reusing `ConnectionError`.
  Rationale: The master plan already rejected the keiro-side-only fix (the store must classify its own errors truthfully). Reusing `ConnectionError` would work for today's keiro classifier (it treats `ConnectionError` as transient) but erases the distinction between "the network/session died" and "the transaction lost a conflict race", and `ConnectionError` is documented as a legacy catch-all that new code should avoid. A typed constructor lets consumers pick different backoff for the two cases and keeps the catch-all's meaning intact.
  Date: 2026-07-23

- Decision: Keep the in-interpreter retry a single immediate retry (no backoff added); truthful classification is the fix.
  Rationale: The single retry exists to absorb the common one-shot deadlock cheaply. Adding backoff/looping inside the interpreter duplicates the retry policies that callers (keiro's command loop, ack retries) already own. With `TransientConflict` surfaced truthfully, callers' policies now engage instead of halting, which is the actual defect. Recorded as the resolution of the master plan's "add backoff or leave single-retry" open point.
  Date: 2026-07-23

- Decision: Lock with a new statement `findStreamIdForUpdateStmt` used only by hard-delete, instead of adding `FOR UPDATE` to the shared `findStreamIdStmt`.
  Rationale: `findStreamIdStmt` also serves the read-only `LookupStreamId` operation (`kiroku-store/src/Kiroku/Store/Effect.hs:213-216`); locking there would make an innocent lookup contend with appends.
  Date: 2026-07-23

- Decision: A `ux_stream_events_stream_version` unique violation maps to `UnexpectedServerError "23505" message` (an explicit branch), not to a new constructor and not to `WrongExpectedVersion`.
  Rationale: That index being violated means two junction rows claimed the same `(stream_id, stream_version)` slot — store-internal corruption, not a caller version conflict. `UnexpectedServerError` is exactly the "investigate, do not blindly retry" channel, and keiro halts on it, which is the correct response to corruption. Today it falls through to `WrongExpectedVersion`, which callers treat as a routine OCC conflict and retry forever.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Two repositories are involved. The kiroku repository at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` contains the event store (`kiroku-store` package), its migrations (`kiroku-store-migrations`), and a Shibuya adapter; ignore its `dist-newstyle` directory. This keiro repository at `/Users/shinzui/Keikaku/bokuno/keiro` contains the runtime that consumes kiroku (`keiro` package) and this plan. Milestones 1-3 edit kiroku; milestone 4 edits keiro.

ADR context: keiro's `docs/adr/` contains only `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq telemetry — not relevant to this work). The kiroku repo has its own ADR directory; its `docs/adr/0002-static-hash-partitioned-consumer-groups.md` is the concern of sibling plan `docs/plans/126-make-consumer-group-resize-safe-and-persist-the-group-size.md`, not this one. No existing ADR covers the hard-delete concurrency contract or the error taxonomy; the master plan names both as candidate ADRs to create in the kiroku repo at distillation time.

Sibling plans (coordinate merge order only, no hard dependencies): 126 (consumer-group resize), 127 (subscription worker), 128 (adapter). This plan owns every change to `kiroku-store/src/Kiroku/Store/Error.hs`; plan 128 consumes that module but must not modify it (master plan Integration Points).

### How the store lays out data

Three tables matter here (created by `kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`, all in the `kiroku` schema). `streams` maps a stream name to a surrogate `stream_id` and holds the stream's version; row `stream_id = 0` is the reserved `$all` stream, the global ordered log. `events` holds one immutable payload row per event, keyed by `event_id` (UUID). `stream_events` is the junction table: each event gets a "home" row `(event_id, stream_id_of_its_stream)`, one `$all` row `(event_id, 0)` whose `stream_version` is the global position, and possibly link rows in other streams. Critically, `stream_events.original_stream_id` (migration 0001 lines 78-85, the column at line 82) has NO foreign key to `streams` — it is a plain `BIGINT`. `stream_events.stream_id` DOES reference `streams(stream_id)`, and `stream_events.event_id` references `events(event_id)`. Category reads resolve events through `original_stream_id` by joining `streams` (that join is what makes orphans invisible to them).

Hard deletes are gated by a trigger: any `DELETE` on `events`/`stream_events`/`streams` raises unless the transaction has run `SET LOCAL kiroku.enable_hard_deletes = 'on'` (migration 0001 lines 178-201).

### KRW-1: the unlocked hard-delete window (verified line by line)

`HardDeleteStream` is interpreted at `kiroku-store/src/Kiroku/Store/Effect.hs:307-333`. It runs one `ReadCommitted` write transaction (via `TxSessions.transaction`, Effect.hs:323-325) containing, in order:

- the `SET LOCAL` gate (Effect.hs:310);
- S1 `findStreamIdStmt` (Effect.hs:311) — a bare `SELECT stream_id FROM streams WHERE stream_name = $1` (`kiroku-store/src/Kiroku/Store/SQL.hs:956`, statement declared at 953-958). No lock of any kind;
- S2 `deleteAllRowsForOriginStmt` (Effect.hs:315; SQL at SQL.hs:991-996) — deletes the `$all` junction rows whose `original_stream_id` is the target, returning the originated event ids;
- S3 `deleteJunctionsByEventIdsStmt` (Effect.hs:316; SQL.hs:1009-1012) — deletes all remaining junction rows for those event ids (home rows and links elsewhere);
- S4 `deleteStreamOwnJunctionsStmt` (Effect.hs:317; SQL.hs:1029-1033) — deletes junction rows whose visible stream is the target (events linked in from elsewhere), returning their ids;
- S5 `deleteDeadLettersForOrphanedEventsStmt` (Effect.hs:319; SQL.hs:1052-1059) and S6 `deleteOrphanedEventsStmt` (Effect.hs:320; SQL.hs:1082-1089) — delete dead letters and event payloads for candidate events, but only those with no surviving `stream_events` row (`NOT EXISTS` re-checked per statement);
- S7 `deleteStreamRowStmt` (Effect.hs:321; SQL.hs:1099) — `DELETE FROM streams WHERE stream_id = $1`.

Under `ReadCommitted`, every statement takes a fresh snapshot. Appends lock only the target stream's `streams` row and the `$all` row; nothing before S7 locks the `streams` row from the delete side. Four interleavings against a concurrent append to the same stream (call it T2), all adversarially verified:

1. T2 commits before S2's snapshot: S2 sees T2's rows; clean purge. Safe.
2. T2 commits after S2's snapshot but before S4's snapshot: THE ORPHAN WINDOW. S2 already ran, so T2's new `$all` row survives. S4's snapshot sees T2's home junction row (visible stream = target) and deletes it. S6's `NOT EXISTS` check then sees the surviving `$all` row, so the event payload is kept. S7 deletes the `streams` row — nothing blocks it, because `original_stream_id` has no FK (migration 0001:78-85). Result: a committed, acknowledged event whose only junction row is a `$all` row pointing at a nonexistent origin stream. It is invisible to per-stream reads (the stream is gone) and to category reads — `readCategoryForwardSQL` (SQL.hs:794-816) and its consumer-group variant (SQL.hs:852-875) join `streams` on the origin — but still visible in `readAllForward` (SQL.hs:547-561) and consumer-group `$all` reads (SQL.hs:902-917). It is unpurgeable: re-running the delete finds no stream (S1 returns `Nothing`), and re-creating the stream mints a fresh `stream_id`, so the old-id orphan is unreachable forever. The audit event `KirokuEventHardDeleteIssued` still fires as if the delete succeeded (Effect.hs:330-332).
3. T2 commits after S4's snapshot: T2's home junction row survives S4; S7's `streams` delete then violates the `stream_events.stream_id -> streams` FK; the whole transaction aborts with SQLSTATE `23503`. Safe (loud failure).
4. T2 still uncommitted when S7 runs: S7 blocks on T2's row lock; when T2 commits, the delete's RI check sees T2's surviving home row and aborts with `23503`, surfaced through `usePool` (Effect.hs:373-377) as `ConnectionError` — which keiro classifies transient, so the delete is retried. Benign.

The exposure amplifier: keiro's workflow GC (`keiro/src/Keiro/Workflow/Gc.hs`, `runWorkflowGcWorker` at lines 56-61 driving `deleteWorkflow` at 63-80) calls `hardDeleteStream` at line 73 inside a per-generation loop, forever, on a poll. Window 2 is exercised whenever anything appends to a workflow stream being collected.

The fix: make S1 `SELECT ... FOR UPDATE`. Every append statement updates the target `streams` row (version bump), so it takes that row's lock; with S1 holding the lock from the top of the delete transaction, an in-flight append either commits before S1 (windows collapse to case 1) or blocks until the delete commits and then re-evaluates against the deleted row: an `ExactVersion`/`StreamExists` append finds no stream and fails, and a `NoStream`/`AnyVersion` append creates a fresh stream with a fresh `stream_id` — the documented re-create semantics. `linkToStream` likewise bumps the target stream row, so links serialize the same way. Note the delete transaction runs through `TxSessions.transaction`, which auto-retries `40001`/`40P01`, so any deadlock introduced by the new lock ordering self-heals; and the delete never touches the `$all` `streams` row (row 0), so it cannot form a lock cycle with appends (which lock stream row then `$all` row).

### KRW-2: the doubled transient conflict (verified line by line)

The single-stream append interpreter retries once on a transient conflict at `kiroku-store/src/Kiroku/Store/Effect.hs:171-183`; the multi-stream variant at 267-280. The trigger predicate is `isTransientSerializationError` (`kiroku-store/src/Kiroku/Store/Error.hs:475-481`): SQLSTATE `40001` or `40P01` (line 479), matching hasql-transaction's retryable set. If the retry also fails transiently, the error flows into `mapUsageError` and down to `mapServerError` (Error.hs:249-253), whose `otherwise` branch (line 253) produces `UnexpectedServerError code message`. That constructor's haddock (Error.hs:127-133) says "This is *not* generally retryable — investigate". Opaque transactions and links take `mapTransactionUsageError` (Error.hs:189-198) into `mapGenericUsageError` (Error.hs:204-215), same terminal mapping (line 213).

Two haddocks actively lie: `kiroku-store/src/Kiroku/Store/Transaction.hs:92-93` ("a hasql `UsageError` is translated to `ConnectionError`") and 104-109 (`runTransactionNoRetry`: "A conflict surfaces as `ConnectionError`"). In reality `runTxOnPool` (Effect.hs:384-397) maps through `mapTransactionUsageError`, so a conflict surfaces as `UnexpectedServerError "40001"/"40P01"` (or `DuplicateEvent` for the 23505 special cases).

keiro-side amplification (verified): `isTransientStoreError` (`keiro/src/Keiro/ProcessManager.hs:293-307`) maps `UnexpectedServerError{}` to `False` (line 307). `decideForFailures` (ProcessManager.hs:344-360) then treats it as systemic-deterministic and produces `AckHalt (HaltFatal ...)` (359-360); `ackForCommandError` (398-401) does the same for the router, wired at `keiro/src/Keiro/Router.hs:378` and `392`. The command retry loop also refuses to retry it: `isRetryableConflict` (`keiro/src/Keiro/Command.hs:891-895`) recognizes only `WrongExpectedVersion` and `StreamAlreadyExists`, so `retryOrFail` (Command.hs:759-773) falls to `StoreFailed`. Only the workflow resume worker is immune — it treats every `StoreError` as transient (`keiro/src/Keiro/Workflow/Resume.hs:333-338`). So a doubled deadlock halts a process-manager or router worker. A realistic doubled member at `ReadCommitted` is `40P01` (for example a fresh-stream speculative insert racing the `$all` row-lock cycle); note the in-interpreter retry is immediate, with no backoff, which makes hitting the same deadlock twice plausible under load.

An existing kiroku test states the guarantee but is acknowledged racy: `kiroku-store/test/Test/Concurrency.hs:252-256` ("must never surface PostgreSQL's transient transaction SQLSTATEs (40001/40P01) to callers as UnexpectedServerError" — the test can pass vacuously on fast machines).

Secondary observations from the review, fixed here because they live in the same `mapUniqueViolation` function (Error.hs:268-277): (a) the `events_pkey` branch matches by `T.isInfixOf`, and `"events_pkey"` is an infix of `"stream_events_pkey"`, so a same-stream duplicate-id append maps to `DuplicateEvent` only by accident — add an explicit `stream_events_pkey` branch first (mirroring `mapTransactionUsageError`'s composite-detail extraction at Error.hs:195-196) so the behavior is deliberate and tested; (b) a violation of the unique index `ux_stream_events_stream_version` (created by `kiroku-store-migrations/migrations/0005-index-hygiene-and-streams-fillfactor.sql:14`) currently falls to the generic `WrongExpectedVersion` fallback, disguising a corruption alarm as a routine version conflict — add an explicit branch mapping it to `UnexpectedServerError`.

### Release and pin coordination

All four sibling plans land on one kiroku release train (master plan Dependency Graph): whichever lands last cuts the release keiro re-pins. Adding a constructor to the exported `StoreError` type is a PVP-major change, so the next `kiroku-store` release is 0.4.0.0 (current: 0.3.1.0, see `kiroku-store/kiroku-store.cabal:3` and kiroku commit `3009dda`). keiro consumes `kiroku-store >=0.3 && <0.4` (three components in `keiro/keiro.cabal` — grep the keiro repo for every occurrence); milestone 4 bumps those bounds to `>=0.4 && <0.5`. kiroku commits follow Conventional Commits, same as keiro.

### Running the tests

kiroku's test suite spins up its own ephemeral PostgreSQL (the `withSharedMigratedPostgres` bracket from the `kiroku-test-support` package, module `Kiroku.Test.Postgres`; the store suite's own `Test.Helpers.withTestStore` builds on it). It needs `initdb`/`postgres` on `PATH` — run inside the kiroku repo's dev shell (`nix develop`) if they are not. From `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`: `cabal test kiroku-store-test` runs the store suite; `just test` runs everything. hspec filtering: `cabal test kiroku-store-test --test-options='--match "hard-delete"'`. From `/Users/shinzui/Keikaku/bokuno/keiro`: `cabal test keiro-test`.


## Plan of Work

### Milestone 1 — reproduce the orphan (tests that fail today)

Scope: a new test module that demonstrates window 2 deterministically and the race probabilistically, before any fix. At the end of this milestone the new specs exist, are wired in, and FAIL against unmodified code (the deterministic one reliably; run it to capture the failure as evidence). This milestone proves the defect is real and gives milestone 2 its acceptance criterion.

Create `kiroku-store/test/Test/HardDeleteConcurrency.hs` and register it: add `Test.HardDeleteConcurrency` to `other-modules` of the `kiroku-store-test` suite in `kiroku-store/kiroku-store.cabal` (the list starts at line ~89) and call its `spec` from `kiroku-store/test/Main.hs` alongside the other specs.

Test A (deterministic interleaving). Use `Kiroku.Test.Postgres.withMigratedTestDatabase :: (Text -> IO a) -> IO a` from `kiroku-test-support` (already a dependency of the test suite) to get a connection string, then open two raw hasql connections (`Hasql.Connection.acquire`; the `hasql` package is already a test dependency). On connection A, replay the hard-delete statement sequence manually with explicit transaction control, pausing between S2 and S4:

- `BEGIN; SET LOCAL kiroku.enable_hard_deletes = 'on';` then run S1 and S2 (the statements are exported from `Kiroku.Store.SQL`: `findStreamIdStmt`, `deleteAllRowsForOriginStmt`, and so on — run them via `Hasql.Session.statement` inside the open transaction; remember to set `search_path` to `kiroku` or schema-qualify, matching how the store's pool is configured in `Test.Helpers`).
- On connection B (a separate thread or simply sequentially, since A's transaction stays open), run a full `appendToStream`-equivalent commit to the same stream. The simplest correct form: use a second `KirokuStore` handle (`withTestStore` gives one, or build a one-connection pool from the same connection string) and call `appendToStream name AnyVersion [event]`, which commits immediately.
- Back on connection A, run S3, S4, S5, S6, S7, `COMMIT`.

Then assert the orphan invariant is violated, with a raw query on either connection:

```sql
SELECT count(*)
FROM kiroku.stream_events se
WHERE NOT EXISTS (SELECT 1 FROM kiroku.streams s WHERE s.stream_id = se.original_stream_id);
```

Write the assertion the way it must read AFTER the fix — `count = 0` — so this test fails now (count is 1: the appended event's `$all` row survives with a dead origin) and passes once milestone 2 lands. Also assert the companion symptoms while you are here: the orphaned event appears in `readAllForward` from position 0 but not in `readCategoryForward` for its category. Note: after the fix, running this same manual sequence changes behavior at a different point — S1 (now `FOR UPDATE`) makes connection B's append BLOCK until A commits; so the test must run B's append with a timeout-guarded `Async` and accept either "append blocked until commit, then re-created the stream" or "append completed before A began". Structure the test to assert the invariant, not the exact interleaving.

Test B (racy, API-level). In a loop of ~25 rounds: create a stream with one event, then run `hardDeleteStream` and `appendToStream name AnyVersion [...]` concurrently (`Async.concurrently`), accept any combination of results (either may fail with `StreamNotFound`/version errors/`ConnectionError` — all fine), and after each round assert the orphan-count invariant above is 0. This is the regression net for interleavings test A does not pin.

Test C (link racing delete). Same shape as B but the concurrent operation is `linkToStream` linking an event from a second, surviving stream into the doomed stream. Invariant: after the dust settles, no junction row (home, link, or `$all`) references a nonexistent `streams` row, and the linked event's payload still exists (it has a surviving home row in the second stream).

Acceptance: `cabal test kiroku-store-test --test-options='--match "hard-delete"'` shows test A failing with orphan count 1 against unmodified code (capture the transcript into Surprises & Discoveries), and B/C failing at least intermittently.

### Milestone 2 — take the lock

Scope: the one-line-of-SQL fix plus documentation. At the end, all milestone 1 tests pass deterministically.

In `kiroku-store/src/Kiroku/Store/SQL.hs`, next to `findStreamIdStmt` (953-958), add and export:

```haskell
-- | Like 'findStreamIdStmt' but takes the stream's row lock, serializing
-- hard-delete against concurrent appends and links (which update the same
-- row). Used only by the hard-delete transaction.
findStreamIdForUpdateStmt :: Statement Text (Maybe Int64)
findStreamIdForUpdateStmt =
    preparable
        "SELECT stream_id FROM streams WHERE stream_name = $1 FOR UPDATE"
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (D.column (D.nonNullable D.int8)))
```

In `kiroku-store/src/Kiroku/Store/Effect.hs:311`, change the hard-delete transaction's S1 from `SQL.findStreamIdStmt` to `SQL.findStreamIdForUpdateStmt`. Do NOT touch the `LookupStreamId` interpreter (Effect.hs:213-216) — it keeps the unlocked statement.

Update the public `hardDeleteStream` haddock (the user-facing wrapper lives in `kiroku-store/src/Kiroku/Store/Lifecycle.hs`; also touch the interpreter comment at Effect.hs:307+) to state the contract: the delete locks the stream row for its whole transaction; a concurrent append or link either commits entirely before the delete (and is purged with the stream) or blocks and then observes the stream as deleted — `NoStream`/`AnyVersion` appends re-create a fresh stream with a fresh `stream_id`, `ExactVersion`/`StreamExists` appends fail with the usual not-found/conflict errors. Mention that window-4-style aborts surface as `ConnectionError` (retryable) today.

Acceptance: from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, `cabal test kiroku-store-test` fully green, including the new spec; run the hard-delete spec ~5 times to shake out flakiness. Expected tail of the transcript:

```text
hard-delete under concurrency
  leaves no orphaned $all rows under a deterministic append interleaving [✔]
  leaves no orphaned rows under a concurrent append loop [✔]
  leaves no orphaned rows when linkToStream races the delete [✔]
```

### Milestone 3 — TransientConflict and the unique-violation branches

Scope: the error-taxonomy fix in `kiroku-store/src/Kiroku/Store/Error.hs`, haddock corrections, and tests. Independently verifiable without milestones 1-2.

Add to `StoreError` (after `ConnectionLost`, before `UnexpectedServerError`, keeping the catch-all `ConnectionError` last):

```haskell
    | {- | PostgreSQL aborted the transaction with a transient conflict:
      SQLSTATE @40001@ (serialization_failure) or @40P01@ (deadlock_detected).
      The transaction rolled back cleanly and the operation is safe to retry;
      the store has already retried once internally before surfacing this.
      Fields: SQLSTATE code, server message.
      -}
      TransientConflict !Text !Text
```

Map it in exactly two places so every surface is covered: in `mapServerError` (Error.hs:249-253) add a guard `| code == "40001" || code == "40P01" = TransientConflict code message` before the `otherwise`; in `mapGenericUsageError` (Error.hs:204-215) add the same branch on the extracted `ServerError` before the `UnexpectedServerError` fallback. (`mapTransactionUsageError` and `mapLinkUsageError` both fall through to `mapGenericUsageError`, and the append path goes through `mapServerError`, so nothing else is needed — verify by grepping `UnexpectedServerError` construction sites.) Update the `UnexpectedServerError` haddock (127-133) and the `mapUsageError` mapping-table comment (161-166) to mention the new constructor. Keep `isTransientSerializationError` unchanged — it still drives the in-interpreter retry.

Fix the lying haddocks in `kiroku-store/src/Kiroku/Store/Transaction.hs`: lines 92-93 and 104-109 must say errors surface via `Kiroku.Store.Error.mapTransactionUsageError` — `DuplicateEvent` for append-shaped 23505s, `TransientConflict` for 40001/40P01 (for `runTransactionNoRetry`, which does not auto-retry; plain `runTransaction` retries them via hasql-transaction and only surfaces what remains), `UnexpectedServerError` for other server codes, `ConnectionLost`/`PoolAcquisitionTimeout`/`ConnectionError` for transport-level failures.

In `mapUniqueViolation` (Error.hs:268-277), restructure the guards in this order: `stream_events_pkey` (explicit, using `extractFirstUuidFromCompositeDetail`, mirroring Error.hs:195-196) then `events_pkey` then `ix_streams_stream_name` then `ux_stream_events_stream_version -> UnexpectedServerError "23505" message` then the `WrongExpectedVersion` fallback. Order matters twice: `stream_events_pkey` must precede `events_pkey` (infix containment), and the `ux_` branch must precede the fallback.

Tests, in `kiroku-store/test/Test/Concurrency.hs` or a small new pure spec module (no DB needed for the mapping tests — construct `Hasql.Errors.ServerError` values directly and feed them through `mapUsageError` / `mapTransactionUsageError` / `mapGenericUsageError`):

- `40001` and `40P01` map to `TransientConflict` on all three entry points; `40001` wrapped at any depth never yields `UnexpectedServerError`.
- a synthetic `stream_events_pkey` violation with a composite detail string maps to `DuplicateEvent (Just eid)`.
- a synthetic `ux_stream_events_stream_version` violation maps to `UnexpectedServerError`, not `WrongExpectedVersion`.
- DB-backed: appending the same caller-supplied deterministic `eventId` twice into the SAME stream yields `DuplicateEvent` (the same-stream retry case the infix accident was silently covering).
- Strengthen the racy leak test (Test/Concurrency.hs:252-274): extend `assertNoTransientLeak` so a `Left` that is `UnexpectedServerError c _` with `c` in {40001, 40P01} fails the test, while `TransientConflict` is accepted as a legitimate outcome.

Acceptance: `cabal test kiroku-store-test` green; the pure mapping specs listed above each shown passing.

### Milestone 4 — keiro classifier, regression test, pin bump

Scope: the keiro repo. Because `isTransientStoreError` (`keiro/src/Keiro/ProcessManager.hs:293-307`) pattern-matches `StoreError` exhaustively, bumping the dependency makes it a compile error until the new constructor is handled — that is the designed safety net.

Steps, from `/Users/shinzui/Keikaku/bokuno/keiro`: bump every `kiroku-store >=0.3 && <0.4` bound in the repo to `>=0.4 && <0.5` (grep `kiroku-store` across `*.cabal`; the `keiro` package has three components carrying it, and check `keiro-test-support` too). This presumes the kiroku release train has cut 0.4.0.0; if this plan's keiro half lands before the release exists, park this milestone and note it in Progress (the master plan says whichever kiroku plan lands last cuts the release). Add `TransientConflict{} -> True` to `isTransientStoreError`. Decide nothing else: `isRetryableConflict` in `keiro/src/Keiro/Command.hs:891-895` should NOT gain `TransientConflict` — that predicate selects conflicts warranting an OCC re-read/re-decide cycle, whereas a `TransientConflict` append is already safe to re-drive through the normal transient path (`retryOrFail` maps it to `StoreFailed`, and `isTransientCommandError` now calls it transient, so the ack layer retries the source event — the correct semantics). Record that reasoning in the Decision Log when implementing.

Add a regression test to `keiro/test/Main.hs` (pure, no DB): `isTransientStoreError (TransientConflict "40001" "serialization failure") == True`, same for `40P01`, and `isTransientStoreError (UnexpectedServerError "XX000" "boom") == False` — pinning the halt-inversion fix. Also assert `ackForCommandError` on `StoreFailed (TransientConflict ...)` yields `AckRetry`, not `AckHalt` (both functions are exported or exportable from `Keiro.ProcessManager`).

Update the keiro `CHANGELOG.md` following the repo's existing dependency-bump entries (see commit `87bf3ff` for the shape), commit message `chore(deps)!: upgrade kiroku-store to 0.4` or similar Conventional Commit.

Acceptance: `cabal build all` and `cabal test keiro-test` green from the keiro root.


## Concrete Steps

All commands are exact; `$KIROKU` means `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, `$KEIRO` means `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
cd $KIROKU
# enter the dev shell if initdb/psql are not on PATH
nix develop
# M1: after writing the new spec + wiring it in:
cabal build kiroku-store-test
cabal test kiroku-store-test --test-options='--match "hard-delete"'
# expect: FAIL (orphan count 1) — capture output into this plan
```

```bash
cd $KIROKU
# M2: after the SQL + Effect.hs edit:
cabal test kiroku-store-test --test-options='--match "hard-delete"'   # expect PASS
cabal test kiroku-store-test                                          # full suite PASS
```

```bash
cd $KIROKU
# M3: after Error.hs / Transaction.hs edits and new specs:
cabal test kiroku-store-test --test-options='--match "Transient"'
cabal test kiroku-store-test
```

```bash
cd $KEIRO
# M4: after bound bumps and the classifier case:
cabal build all          # a missing TransientConflict case would fail here
cabal test keiro-test
```

When a step fails, read the hspec failure text: the deterministic hard-delete test prints the orphan count; a mapping test failure prints the constructor mismatch (for example `expected: TransientConflict "40001" ..., but got: UnexpectedServerError "40001" ...`).


## Validation and Acceptance

Behavioral acceptance, beyond compilation:

1. Window-2 orphan closed: milestone 1's deterministic test, which fails against unmodified code with orphan count 1, passes after milestone 2. Additionally demonstrable by hand: with the fix, running the manual S1..S2 prefix in a psql transaction (`BEGIN; SET LOCAL kiroku.enable_hard_deletes='on'; SELECT stream_id FROM kiroku.streams WHERE stream_name='x' FOR UPDATE;`) makes a concurrent append to `x` from a second psql session block until the first commits.
2. Concurrent GC-shaped load safe: the loop test (B) and link test (C) hold the zero-orphan invariant across every round.
3. Doubled conflict retryable: the pure mapping specs prove `40001`/`40P01` can no longer surface as `UnexpectedServerError` from any mapper; the strengthened racy test enforces it end-to-end when the race fires.
4. keiro no longer halts: the milestone 4 unit tests prove the process-manager/router classification path yields `AckRetry` for `TransientConflict`.
5. Docs truthful: `runTransactionNoRetry`'s haddock names `TransientConflict`, and `hardDeleteStream`'s haddock states the lock contract (review the rendered comments in the diff).


## Idempotence and Recovery

Every step is re-runnable. Tests create uniquely-named streams (or run on a per-test database via `withMigratedTestDatabase`), so re-running cannot poison state; the ephemeral PostgreSQL is discarded per suite run. The SQL change is a new statement plus a one-identifier call-site edit — reverting Effect.hs:311 to `findStreamIdStmt` restores exactly the old behavior if the lock causes unexpected contention (the milestone 1 tests then fail again, which is the signal you have reverted the fix, not just the symptom). The Error.hs change is additive (new constructor + earlier-matching guards); consumers outside keiro that pattern-match non-exhaustively are unaffected, and keiro's exhaustive match is fixed in milestone 4. No migration files are touched by this plan.


## Interfaces and Dependencies

At the end of the kiroku milestones, `kiroku-store` exports (module paths exact):

- `Kiroku.Store.SQL.findStreamIdForUpdateStmt :: Hasql.Statement.Statement Data.Text.Text (Maybe Data.Int.Int64)` — new; used only by the `HardDeleteStream` interpreter.
- `Kiroku.Store.Error.StoreError` gains `TransientConflict !Text !Text`; `Kiroku.Store.Error.isTransientSerializationError` unchanged.
- No signature changes to `Kiroku.Store.Effect.runStorePool`, `Kiroku.Store.Lifecycle.hardDeleteStream`, `Kiroku.Store.Transaction.runTransaction/runTransactionNoRetry` — haddock-only there.

At the end of milestone 4, keiro has: `Keiro.ProcessManager.isTransientStoreError` total over the 0.4 `StoreError` (with `TransientConflict{} -> True`), bounds `kiroku-store >=0.4 && <0.5` everywhere, and the new pure regression specs in `keiro/test/Main.hs`. Dependencies used: `hasql` (raw connections in tests), `async` (interleavings), `kiroku-test-support` (`Kiroku.Test.Postgres.withMigratedTestDatabase`) — all already in the respective cabal files. Release artifacts: kiroku-store 0.4.0.0 on the shared release train (versions/CHANGELOG per kiroku's `chore(release):` convention); this plan does not itself cut the release unless it lands last among plans 125-128.
