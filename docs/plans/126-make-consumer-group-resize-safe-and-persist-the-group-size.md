---
id: 126
slug: make-consumer-group-resize-safe-and-persist-the-group-size
title: "Make consumer-group resize safe and persist the group size"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
---

# Make consumer-group resize safe and persist the group size

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

kiroku (the PostgreSQL event store at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`; keiro paths below are relative to this repository, `/Users/shinzui/Keikaku/bokuno/keiro`) supports consumer groups: a subscription split across N members, each member reading only the streams that hash to its slot. This plan fixes finding KRS-1 of the parent master plan (`docs/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md`): the documented procedure for changing N ("resize") permanently loses events, the schema column meant to record N (`consumer_group_size`) is never written or read, and nothing refuses a mis-sized restart.

After this plan, a kiroku operator can change a consumer group's size without losing events: the store persists each group's size next to its checkpoints, refuses startup with a typed error when the configured size disagrees with the stored one, and ships a supported equalization operation (`resizeConsumerGroup`) that rewinds the new members to the minimum checkpoint across the old members so re-bucketed streams are re-delivered instead of silently skipped. The user guide and the kiroku ADR that both describe an unsafe procedure are corrected. On the keiro side, the sharded-subscription layer (whose shard workers ARE kiroku consumer-group members) gets a safe `shardCount`-change operation and stops committing mixed-count shard rows when a grow attempt is refused.

You can see it working by running the new resize test: a size-2 group with deliberately skewed member checkpoints is restarted as size 3 — today that silently loses the gap events; after this plan the restart is refused with `ConsumerGroupSizeMismatch`, and after running `resizeConsumerGroup` the size-3 group delivers every event at least once.


## Progress

- [ ] M1: `consumer_group_size` written on every checkpoint upsert and read back on checkpoint load; `ConsumerGroupSizeMismatch` typed error refuses a mis-sized startup; legacy-adoption rule implemented; refusal test (size 2 -> 3 with skewed checkpoints) passes.
- [ ] M2: `resizeConsumerGroup` exported from `Kiroku.Store.Subscription`; equalization test passes (post-resize size-3 run is gapless); documented SQL equivalent included in docs.
- [ ] M3: `docs/user/consumer-groups.md` resize and hash-caveat/PG-upgrade sections rewritten; kiroku `docs/adr/0002-static-hash-partitioned-consumer-groups.md` amended.
- [ ] M4: keiro — `ensureShards` validates before inserting (no mixed rows on refusal, advisory-lock guarded); `resizeShardCount` guarded operation added; keiro tests pass (`cabal test keiro-test`).
- [ ] Release/pin coordination recorded (kiroku release train; keiro bound bump if this plan lands the keiro seam first).
- [ ] Living sections updated; ADR distillation pass done (the resize contract is a named ADR candidate in the master plan).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Refuse-then-equalize, not transparent re-bucketing safety.
  Rationale: Inherited from the master plan — transparent safety needs per-stream checkpoints, a redesign kiroku's ADR 0002 explicitly traded away. Persisting and validating the size plus a supported equalization operation closes the loss without the redesign.
  Date: 2026-07-23

- Decision: Ship the equalization as an exported library function `resizeConsumerGroup` (with the equivalent SQL documented for operators), not as a kiroku-cli subcommand.
  Rationale: keiro needs to call it programmatically from its own shard-resize operation (milestone 4), and a library function is testable in the kiroku suite. The documented SQL serves operators without Haskell tooling; a CLI wrapper can be added later without design risk. Recorded as the resolution of the master plan's "operator-CLI vs library function" open point.
  Date: 2026-07-23

- Decision: Legacy rows (written before the size was persisted) are adopted, not refused: a stored size of 1 is treated as "unbound" and rewritten to the configured size on the next checkpoint save.
  Rationale: `consumer_group_size` has defaulted to 1 since the column was created and was never written, so every existing row stores 1 regardless of the group's true size. Refusing on `stored 1 /= configured N` would brick every existing deployment on upgrade. Adopting is safe: for a genuine non-group subscription (member 0, size 1) stored equals configured, so nothing changes; and the only case adoption could mask — an actual unsupervised resize FROM size 1 — is loss-free anyway, because under size 1 member 0 had processed every stream up to its cursor, so growing only re-delivers (members start at 0) and never skips.
  Date: 2026-07-23

- Decision: keiro's `shardCount` change path is a guarded operation (`resizeShardCount`: assert no live leases, rewrite shard rows, equalize kiroku checkpoints in one pass), not refuse-with-runbook.
  Rationale: keiro already refuses loudly at startup (`ShardCountMismatch`); what is missing is any supported way forward. A runbook alone would have the operator hand-editing two tables (`keiro_subscription_shards` and kiroku's `subscriptions`) whose invariants must change together; one guarded function is smaller to test than a runbook is to keep correct. Resolution of the master plan's "guarded operation or refuse-with-runbook" open point.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Two repositories: kiroku at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (milestones 1-3; ignore `dist-newstyle`) and keiro at `/Users/shinzui/Keikaku/bokuno/keiro` (milestone 4).

ADR context: keiro's own `docs/adr/` contains only `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq telemetry — not relevant here). The kiroku repo's `docs/adr/0002-static-hash-partitioned-consumer-groups.md` IS directly relevant: it records the static hash-partitioned consumer-group design this plan hardens, and its "Consequences / Negative" section (lines 60-66, resize claim at 62-64) describes the very resize procedure this plan proves lossy — milestone 3 amends it. kiroku's ADR 0003 (dedicated schema) is background only.

Sibling plans: 125 (write path), 127 (subscription worker), 128 (adapter). Coordination hotspots (from the master plan's Integration Points): this plan and plan 127 both edit `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` (disjoint functions: this plan touches checkpoint load/save, 127 touches the live-loop exit mapping and subscribe validation) and both add a column write to the same checkpoint-upsert SQL statements (this plan adds `consumer_group_size`; 127 adds `stream_name`). The parameter additions are independent; whichever plan lands second rebases mechanically. This plan owns any schema change to the `subscriptions` table — as implemented below, NO new migration file is needed (both columns already exist); if that changes, claim the next migration number (currently `0009`, after `kiroku-store-migrations/migrations/0008-schema-management-comment.sql`) and record it in the master plan's Integration Points section.

### How consumer groups work today (verified against source)

A consumer group member is an ordinary subscription whose config carries `ConsumerGroup { member, size }`. Member assignment is computed in SQL at fetch time by hashing the originating stream's surrogate id into `[0, size)`: see `readAllForwardConsumerGroupSQL` (`kiroku-store/src/Kiroku/Store/SQL.hs:902-917`, predicate at 914) and the category variant `readCategoryForwardConsumerGroupSQL` (SQL.hs:852-875, predicate at 872). Every fetch is strictly `position > cursor` for the member's OWN cursor.

Checkpoints are one global cursor per `(subscription_name, consumer_group_member)`: `getCheckpointMemberSQL` (SQL.hs:1234-1241) reads `last_seen`; `saveCheckpointMemberSQL` (SQL.hs:1243-1250) upserts with `GREATEST` monotonicity. A second writer exists: `insertDeadLetterAndCheckpointSQL` (SQL.hs:1309-1322) atomically records a dead letter and advances the same checkpoint row. The Haskell callers are `loadCheckpoint` (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:443-461`, run once at worker startup, Worker.hs:212) and `saveCheckpoint` (Worker.hs:764-776).

The schema (`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`): the `subscriptions` table has `consumer_group_member` (line 126) and `consumer_group_size INT NOT NULL DEFAULT 1` (line 127; the idempotent-convergence `ALTER` at line 138). Verified: `consumer_group_size` has ZERO references in any `.hs` file in the kiroku repo — it is never written (every row keeps the DEFAULT 1) and never read. `subscribe` validates only local bounds — `size >= 1`, `0 <= member < size` (`kiroku-store/src/Kiroku/Store/Subscription.hs:117-119`) — it cannot see what size the checkpoints were written under.

### The loss mechanism (KRS-1)

Change the size and the hash formula reassigns ("re-buckets") streams to different members. Consider stream S re-bucketed to member M whose cursor is ahead of S's unprocessed events (M was fast, or S's old owner was slow). M's next fetch is `position > M.cursor` — S's events between S's old owner's cursor and M's cursor are never fetched by anyone, permanently. No rescue path exists: all reads are strictly `>` a member's own cursor, and even the reconnect/rewind machinery (plan 127's territory) can never reach below a member's own checkpoint. The idealized procedure — full drain (every member caught up to the same tail) plus writer quiescence — makes the gap empty, but nothing checks or enforces either condition.

The documentation is wrong about this. `docs/user/consumer-groups.md:131-153` ("Resizing The Group") prescribes stop -> drain -> restart-with-new-size, explicitly permits `cancel` (line 140, which abandons in-flight positions on a batch boundary), and claims mixed sizes cause "duplicates and gaps until every member agrees on `size` again" (149-151) — falsely implying the gap heals; it persists forever. kiroku's ADR 0002 repeats the same claim (`docs/adr/0002-static-hash-partitioned-consumer-groups.md:60-66`).

### The keiro seam (verified)

keiro's sharded subscription layer is a lease coordinator on top of kiroku consumer groups. Each shard worker opens a kiroku subscription with `Sub.consumerGroup = Just (ConsumerGroup { member = bucket, size = shardCount })` (`keiro/src/Keiro/Subscription/Shard/Worker.hs:321-327`). Positions live entirely in kiroku: `keiro/src/Keiro/Subscription/Shard/Schema.hs:10-13` states the shard table stores no event positions — kiroku's per-member checkpoints do. Normal lease rebalancing never re-buckets anything (the `shardCount` is fixed; only ownership of a bucket moves, and the re-homed bucket resumes from the same kiroku checkpoint row). A `shardCount` CHANGE is guarded: `ensureShards` (`keiro/src/Keiro/Subscription/Shard.hs:111-125`) lists the distinct `shard_count` values present and throws `ShardCountMismatch` if any row disagrees with the configured count. That `throwIO` is a real exception, so it escapes the `Left err -> reportShardError ...` swallow at the call site (`keiro/src/Keiro/Subscription/Shard/Worker.hs:412-415`, which only catches `StoreError`-shaped `Left`s from `runStoreIO`) — a loud outage, not silent loss. BUT: there is no safe path to actually change the count, and the guard has a wart — `ensureShards` runs `ensureShardRows` (the insert) and `listShardCounts` (the check) in one transaction that COMMITS before the mismatch is thrown (Shard.hs:113-115 commit, 118-125 throw), so a grow attempt inserts the new-N rows first and leaves mixed `shard_count` rows that make EVERY worker — old config and new — fail the mismatch check until someone hand-deletes rows.

An existing keiro test pins the refusal (`keiro/test/Main.hs`, "ensureShards rejects a shardCount mismatch", around line 6956) but does not assert the table state afterward — it currently passes while the wart corrupts the table.

### Release and pin coordination

All kiroku-repo plans (125-128) share one release train; whichever lands last cuts the kiroku-store release keiro re-pins (plan 125 makes it 0.4.0.0 — a PVP-major — so this plan's kiroku changes ride that version). keiro's milestone 4 needs the released `resizeConsumerGroup`, so if this plan lands the keiro seam first among the keiro-side changes, it also records the bound bump `kiroku-store >=0.4 && <0.5` in `keiro/keiro.cabal` (see plan 125 milestone 4 for the mechanics; do it once, in whichever plan lands first).

### Running the tests

kiroku: from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (inside `nix develop` if `initdb` is not on PATH), `cabal test kiroku-store-test`; filter with `--test-options='--match "resize"'`. The suite boots its own ephemeral PostgreSQL. keiro: from `/Users/shinzui/Keikaku/bokuno/keiro`, `cabal test keiro-test`. Existing consumer-group specs to study before writing new ones: `kiroku-store/test/Test/ConsumerGroup.hs`, `Test/ConsumerGroupSql.hs`, `Test/ConsumerGroupEffect.hs`; keiro's shard specs live inline in `keiro/test/Main.hs` (search "Sharded subscription").


## Plan of Work

### Milestone 1 — persist and validate the size; refuse a mis-sized startup

Scope: kiroku only. At the end, every checkpoint write records the size it was written under, a subscription whose configured size disagrees with the stored size fails startup with a typed error naming the supported procedure, and the previously-missing resize test exists (asserting refusal).

Edits, in order:

1. `kiroku-store/src/Kiroku/Store/SQL.hs`: extend `saveCheckpointMemberSQL` (1243-1250) to a 4-parameter statement writing `consumer_group_size` on insert AND update:

```sql
INSERT INTO subscriptions (subscription_name, consumer_group_member, last_seen, consumer_group_size, updated_at)
VALUES ($1, $2, $3, $4, now())
ON CONFLICT (subscription_name, consumer_group_member)
DO UPDATE SET last_seen = GREATEST(subscriptions.last_seen, EXCLUDED.last_seen),
              consumer_group_size = EXCLUDED.consumer_group_size,
              updated_at = now()
```

   Extend `saveCheckpointMemberStmt`'s encoder (contrazip4, the new param `E.int4`). Do the same to the checkpoint half of `insertDeadLetterAndCheckpointSQL` (1309-1322) and add the size field to `DeadLetterParams` (SQL.hs:1256-1280) and its encoder. Extend `getCheckpointMemberSQL` (1234-1241) to `SELECT last_seen, consumer_group_size ...` and change `getCheckpointMemberStmt`'s decoder to `Maybe (Int64, Int32)`; then grep the repo for `getCheckpointMemberStmt` and fix every caller (at minimum `loadCheckpoint` and the test helper in `kiroku-store/test/Test/SubscriptionReconnect.hs:45-50`).

2. `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`: add a `configSize` helper next to the existing `configMember` (the member accessor `loadCheckpoint`/`saveCheckpoint` already use) returning the configured size (1 for non-group). Thread it into `saveCheckpoint` (764-776) and the dead-letter checkpoint call. In `loadCheckpoint` (443-461), after a successful read of `Just (pos, storedSize)`, apply the validation rule: if `storedSize == configured` proceed; else if `storedSize == 1` proceed (legacy adoption — the next save rewrites it; see Decision Log); else `throwIO (ConsumerGroupSizeMismatch subName member configured storedSize)`. `loadCheckpoint` runs inside the worker body whose exceptions surface through the subscription handle's `wait` (the worker's outer `try` at Worker.hs:384-390 re-emits and rethrows), so startup fails loudly.

3. `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`: define the error next to `InvalidConsumerGroup` (Types.hs:397):

```haskell
data ConsumerGroupSizeMismatch = ConsumerGroupSizeMismatch
    { mismatchSubscription :: !SubscriptionName
    , mismatchMember :: !Int32
    , mismatchConfiguredSize :: !Int32
    , mismatchStoredSize :: !Int32
    }
    deriving stock (Eq, Show)
    deriving anyclass (Exception)
```

   Its `Show`/haddock must name the remedy: "the group's checkpoints were written under a different size; run Kiroku.Store.Subscription.resizeConsumerGroup (or the documented SQL) before restarting with the new size". Export it from `Kiroku.Store.Subscription` and the umbrella `Kiroku.Store` module (follow how `InvalidConsumerGroup` is exported).

4. New spec `kiroku-store/test/Test/ConsumerGroupResize.hs` (wire into `test/Main.hs` + `other-modules`). Test "resize 2 -> 3 with skewed checkpoints is refused": seed a category with events across several streams; run a size-2 group to completion (both members live/caught up, checkpoints saved); then artificially skew — append more events and let ONLY member 0 advance (run member 0 alone; member 1 stays behind); stop everything; subscribe member 0 with `ConsumerGroup 0 3` and assert `wait` returns `Left` whose exception `fromException`s to `ConsumerGroupSizeMismatch { mismatchConfiguredSize = 3, mismatchStoredSize = 2 }`. Also test the legacy-adoption rule: hand-write a checkpoint row with `consumer_group_size = 1` (raw SQL through the store pool) for a member of a configured size-3 group and assert the subscription starts and the next checkpoint save rewrites the stored size to 3.

Acceptance: `cabal test kiroku-store-test --test-options='--match "resize"'` green, and the full suite green (the decoder change ripples through existing specs — the compiler finds the callers).

### Milestone 2 — the supported resize operation

Scope: kiroku only. At the end, `resizeConsumerGroup` exists, is exported, and the resize test proves gapless delivery after using it.

In `kiroku-store/src/Kiroku/Store/Subscription.hs` (or a small new module `Kiroku.Store.Subscription.Resize` re-exported from it), implement:

```haskell
-- | Equalize a consumer group's checkpoints for a size change. Precondition:
-- every member of the group is stopped (this function cannot verify liveness;
-- see the user guide). In one transaction: read min(last_seen) over the
-- subscription's existing rows, delete them, and insert newSize fresh rows
-- (members 0..newSize-1) at that minimum with consumer_group_size = newSize.
-- Returns the position every member will resume from. Idempotent: re-running
-- with the same newSize is a no-op on already-equalized rows.
resizeConsumerGroup ::
    (MonadIO m) =>
    KirokuStore -> SubscriptionName -> Int32 -> m GlobalPosition
```

Implementation: one `ReadCommitted` write transaction through the store pool (mirror how `Kiroku.Store.Effect` runs `TxSessions.transaction`, or reuse `Kiroku.Store.Transaction.runTransaction` if you route through the effectful surface — pick whichever keeps this callable from plain `MonadIO`, since `subscribe` itself is `MonadIO`). Statements: `SELECT COALESCE(MIN(last_seen), 0) FROM subscriptions WHERE subscription_name = $1` (with `FOR UPDATE` on the selected rows to serialize concurrent resizes — use a separate `SELECT ... FOR UPDATE` first), then `DELETE FROM subscriptions WHERE subscription_name = $1`, then a generated `INSERT` of `newSize` rows `(name, member, min, newSize)`. Validate `newSize >= 1` (throw `InvalidConsumerGroup`-style on violation). A group that has never checkpointed (no rows) resumes at 0, which is correct. Note the direct `DELETE`+`INSERT` deliberately bypasses `saveCheckpointMemberSQL`'s `GREATEST` — rewinding is the point; document that in the haddock.

Document the operator SQL equivalent in the user guide (milestone 3) so a non-Haskell operator can do the same in psql.

Extend `Test/ConsumerGroupResize.hs`: continuing the milestone 1 scenario after the refusal, call `resizeConsumerGroup store subName 3`, restart members 0..2 with size 3, and assert every seeded event id is observed at least once across the three members (collect delivered event ids into a shared `IORef` set; compare against the seeded set). Duplicates are expected and fine (at-least-once); the assertion is set-equality on coverage. Also assert idempotence: calling `resizeConsumerGroup` twice in a row leaves the same three rows.

Acceptance: the gapless test passes; against un-fixed code the same scenario (skipping the refusal by writing size rows manually) demonstrably loses the skewed gap — keep that negative variant as a commented-out or `xit` reference if it is too slow, otherwise as a live proof that the equalization is what closes the gap.

### Milestone 3 — correct the documentation and the ADR

Scope: kiroku docs only. Rewrite `docs/user/consumer-groups.md`'s "Resizing The Group" section (currently 131-153): the procedure becomes (1) stop all members (draining via `Stop` is no longer load-bearing, but still recommended to minimize re-delivery; `cancel` is now acceptable), (2) run `resizeConsumerGroup` (show both the Haskell call and the psql equivalent), (3) start members `0..newSize-1`. State plainly WHY: checkpoints are per-member global cursors; a size change re-buckets streams, and without equalization a stream re-bucketed to a member with a higher cursor loses the gap permanently — the old text's "gaps until every member agrees" was wrong, and the store now refuses a mis-sized start with `ConsumerGroupSizeMismatch`. Update the "Hash Caveat" section (176+) similarly: a PostgreSQL major upgrade that changed `hashtextextended` would re-bucket exactly like a resize, so the same equalization procedure applies (run `resizeConsumerGroup` with the SAME size to rewind to the group minimum before resuming on the new PG version).

Amend `docs/adr/0002-static-hash-partitioned-consumer-groups.md` — do not rewrite history; append an "Amendment (2026-07)" section stating: the original Negative bullet (62-64) understated resize — stop/drain/restart alone permanently skips events for re-bucketed streams whose new member's cursor is ahead; the store now persists `consumer_group_size`, refuses mismatched startups, and ships `resizeConsumerGroup`; link the master plan and this plan by path (they live in the keiro repo — reference as "keiro repo, docs/plans/126-...").

Acceptance: docs review — the two files contain no remaining claim that draining alone makes a resize safe (grep the kiroku docs tree for "agrees on" and "drain" in resize context).

### Milestone 4 — keiro: fix the grow wart and add the guarded shard resize

Scope: keiro only (`keiro/src/Keiro/Subscription/Shard.hs`, `Shard/Schema.hs`, tests in `keiro/test/Main.hs`). Requires the kiroku release carrying milestones 1-2 (see pin coordination in Context); until that release exists, develop against a source override if the workflow allows, or land after the release.

Part A — validate BEFORE inserting. Restructure `ensureShards` (Shard.hs:111-125) so the check and the insert happen in one transaction with the check first, guarded against racing initializers by a transaction-scoped advisory lock:

```haskell
ensureShards lease = do
    outcome <- runTransaction $ do
        acquireShardTableLock (subscriptionName lease)   -- pg_advisory_xact_lock keyed on the name
        counts <- listShardCounts (subscriptionName lease)
        let configured = shardCount lease
            found = [n | (n, _) <- counts, n /= configured]
        if null found
            then Right () <$ ensureShardRows (subscriptionName lease) configured
            else pure (Left found)
    case outcome of
        Right () -> pure ()
        Left found -> throwIO ShardCountMismatch{..}
```

`acquireShardTableLock` is a new statement in `Shard/Schema.hs`: `SELECT pg_advisory_xact_lock(hashtextextended('keiro_shard:' || $1, 0))` (transaction-scoped, auto-released at commit/rollback; it serializes two workers racing `ensureShards` with different counts on an empty table, which was the residual race). Because the mismatch branch inserts nothing, a refused grow leaves the table exactly as it was — the wart is gone.

Part B — the guarded resize. In `Shard.hs`, add:

```haskell
-- | Change a sharded subscription's bucket count. Refuses if any bucket lease
-- is currently live (unexpired): stop the workers first. In one pass: verifies
-- quiescence, rewrites the shard rows to newCount buckets (unowned), and
-- equalizes the kiroku consumer-group checkpoints via
-- Kiroku.Store.Subscription.resizeConsumerGroup.
resizeShardCount ::
    (IOE :> es, Store :> es) =>
    KirokuStore -> SubscriptionName -> Int -> Eff es GlobalPosition
```

Implementation: within `runTransaction` — advisory lock (Part A's), `listShardOwnership`, refuse (return a `Left`/throw after the transaction) if any row has an owner with `lease_expires_at` in the future; otherwise delete all shard rows for the name and insert `newCount` fresh unowned rows (add the needed delete/insert statements to `Shard/Schema.hs`, following `ensureShardRows`'s style). Then call kiroku's `resizeConsumerGroup store name (fromIntegral newCount)`. The kiroku call is a second transaction; order matters — rows first, checkpoints second is safe because workers of the new count cannot start until this function returns, and if the process dies between the two steps, re-running `resizeShardCount` is idempotent (the quiescence check still passes, rows are rewritten to the same state, and `resizeConsumerGroup` is idempotent). Define a typed refusal error (for example `ShardResizeBlocked` carrying the live buckets/owners) alongside `ShardCountMismatch` (Shard.hs:91-97).

Tests, in `keiro/test/Main.hs` next to the existing shard specs: (1) extend "ensureShards rejects a shardCount mismatch" (~line 6956) to ALSO assert, after the refused `ensureShards lease6`, that `listShardCounts` still reports only `[4]` — this is the mixed-rows regression and fails against unmodified code; (2) "resizeShardCount refuses while a lease is live": claim a bucket with a long TTL, call `resizeShardCount ... 6`, expect the typed refusal and unchanged rows; (3) "resizeShardCount grows 4 -> 6 when quiescent": with all leases expired/released, call it, assert 6 unowned rows with `shard_count = 6` and that kiroku's `subscriptions` table now holds 6 member rows for the name at the pre-resize minimum (query through the store pool); then run a sharded group end-to-end at the new count over a seeded category and assert full coverage (reuse the sink-table pattern of the existing "one worker with N=4 buckets drains a seeded category exactly once" spec).

Acceptance: from `/Users/shinzui/Keikaku/bokuno/keiro`, `cabal test keiro-test` green, with test (1) failing before Part A and passing after.


## Concrete Steps

`$KIROKU` = `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, `$KEIRO` = `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
cd $KIROKU
nix develop            # if initdb/postgres are not already on PATH
# M1 (after SQL + Worker + Types edits and the new spec):
cabal build kiroku-store-test
cabal test kiroku-store-test --test-options='--match "resize"'
cabal test kiroku-store-test
```

```bash
cd $KIROKU
# M2 (after resizeConsumerGroup):
cabal test kiroku-store-test --test-options='--match "resize"'
```

Expected transcript shape for M1+M2:

```text
consumer-group resize
  refuses startup when the stored group size disagrees (2 -> 3) [✔]
  adopts legacy rows whose stored size is the never-written default [✔]
  delivers every event at least once after resizeConsumerGroup (2 -> 3) [✔]
  resizeConsumerGroup is idempotent [✔]
```

```bash
cd $KIROKU
# M3: docs only — verify no stale claims remain:
grep -rn "agrees on" docs/user/consumer-groups.md docs/adr/0002-static-hash-partitioned-consumer-groups.md
```

```bash
cd $KEIRO
# M4 (after Shard.hs / Schema.hs edits and tests; kiroku 0.4 release pinned):
cabal build all
cabal test keiro-test
```


## Validation and Acceptance

Beyond compilation: (1) the refusal is observable — subscribing a member with a size that disagrees with stored checkpoints makes `wait` return `Left` with `ConsumerGroupSizeMismatch` naming both sizes; (2) the loss is closed — the milestone 2 coverage test proves a 2 -> 3 resize via `resizeConsumerGroup` delivers every seeded event at least once, where the pre-fix procedure demonstrably skipped the skewed gap; (3) the keiro grow wart is closed — a refused `ensureShards` leaves `keiro_subscription_shards` untouched (test 1 of milestone 4, red before / green after); (4) the guarded resize works end-to-end — after `resizeShardCount` 4 -> 6, a sharded group drains a seeded category with full coverage at the new count; (5) docs and ADR no longer describe the lossy procedure.


## Idempotence and Recovery

`resizeConsumerGroup` and `resizeShardCount` are deliberately idempotent (documented above; both tested). The checkpoint-upsert change is backward-compatible at the SQL level (columns already exist; no migration). If milestone 1's decoder change breaks unexpected callers, the compiler lists them — fix mechanically. If the keiro milestone must be rolled back, reverting `ensureShards` restores old behavior exactly (the mismatch test reverts to passing-with-wart). Both new operations refuse rather than act when their preconditions fail (mismatch/live leases), so a botched invocation cannot destroy positions: the only destructive step — checkpoint rewind — moves cursors DOWN to a group minimum, which under at-least-once semantics causes re-delivery, never loss. Re-running any test command is safe; each suite run gets a fresh ephemeral database.


## Interfaces and Dependencies

End state, kiroku (`kiroku-store` 0.4.0.0 on the shared release train — see plan 125 for why 0.4):

- `Kiroku.Store.Subscription.resizeConsumerGroup :: MonadIO m => KirokuStore -> SubscriptionName -> Int32 -> m GlobalPosition` (new, exported; also from umbrella `Kiroku.Store` if that is where subscription surface re-exports live — match `subscribe`).
- `Kiroku.Store.Subscription.Types.ConsumerGroupSizeMismatch` (new exception, exported like `InvalidConsumerGroup`).
- `Kiroku.Store.SQL`: `saveCheckpointMemberStmt :: Statement (Text, Int32, Int64, Int32) ()`, `getCheckpointMemberStmt :: Statement (Text, Int32) (Maybe (Int64, Int32))`, `DeadLetterParams` gains the size field.

End state, keiro:

- `Keiro.Subscription.Shard.resizeShardCount :: (IOE :> es, Store :> es) => KirokuStore -> SubscriptionName -> Int -> Eff es GlobalPosition` (new) and a typed `ShardResizeBlocked` error; `ensureShards` same signature, check-before-insert semantics.
- `Keiro.Subscription.Shard.Schema`: new statements — advisory lock, shard-row delete, shard-row insert-for-count (names in `ensureShardRows` style).
- Dependency: `kiroku-store >=0.4 && <0.5` (bound bump shared with plan 125 milestone 4 — record in whichever lands first, per master plan Integration Points).

No new packages anywhere; everything uses hasql/hasql-transaction/effectful already in place.
