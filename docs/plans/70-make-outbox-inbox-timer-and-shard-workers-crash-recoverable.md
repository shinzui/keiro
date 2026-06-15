---
id: 70
slug: make-outbox-inbox-timer-and-shard-workers-crash-recoverable
title: "Make outbox, inbox, timer, and shard workers crash-recoverable"
kind: exec-plan
created_at: 2026-06-11T04:45:56Z
intention: intention_01kv40hzwaenftzem0gxypz4mj
master_plan: "docs/masterplans/9-keiro-production-readiness-hardening.md"
---

# Make outbox, inbox, timer, and shard workers crash-recoverable

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The keiro library (the `keiro` package in this repository) ships four PostgreSQL-backed messaging workers: a durable **outbox** that publishes integration events to Kafka, an idempotent **inbox** that deduplicates incoming integration events, durable **timers** that wake process managers (sagas) at a future time, and **sharded subscriptions** that let a pool of identical worker processes cooperatively split a busy event category. A June 2026 production-readiness audit found that every one of these workers handles the happy path correctly but loses work or wedges permanently when a worker process crashes, when a handler throws, or when the database blips.

The headline defect (audit id C1, severity critical): an outbox row that a worker claims and then never marks — because the process crashed or the publish callback threw — is stranded in status `publishing` forever. No code path in the repository reclaims it, even though the documentation in `keiro/src/Keiro/Outbox/Types.hs` explicitly promises it is "reclaimable through the same claim query". Worse, under the default per-key ordering policy that stuck row blocks every later event with the same key for eternity. One worker crash at the wrong instant means silent message loss plus a permanent head-of-line wedge.

After this plan is implemented, every documented recovery guarantee in these four subsystems is real and proven by a test that simulates a crash between the two statements the guarantee spans: a crashed outbox publisher's rows are reclaimed and published; a publish exception poisons one row, not the whole batch; a timer stranded mid-fire re-fires automatically; a poison inbox message is recorded as failed and dead-lettered after a ceiling instead of wedging its Kafka partition; a transient database error no longer makes a shard worker silently drop all its readers; a dead reader thread is detected and restarted; graceful shutdown releases shard leases immediately instead of costing a full lease TTL on every deploy; processed outbox rows are pruned instead of growing without bound; and invalid worker configurations are rejected at construction time with typed errors. You can see all of it working by running `cabal test keiro-test` from the repository root and watching the new crash-window examples pass.


## Progress

- [x] M1: generate the new migration `keiro-messaging-crash-recovery` (inbox `attempt_count` column, inbox backlog index, outbox sent-GC index, outbox per-source ordering index) (completed 2026-06-15; migration `keiro-migrations/sql-migrations/2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql`)
- [x] M1: add the `SET search_path TO kiroku, pg_catalog;` pin to the seven older migrations that lack it (completed 2026-06-15)
- [x] M1: touch the embed comment in `keiro-migrations/src/Keiro/Migrations.hs` and verify with `cabal test keiro-migrations-test` (completed 2026-06-15; `keiro-migrations-test` passed with 2 examples, 0 failures; `keiro-test` passed with 182 examples, 0 failures)
- [x] M2: add `requeueStuckOutbox` to `keiro/src/Keiro/Outbox/Schema.hs` and re-export it from `keiro/src/Keiro/Outbox.hs` (completed 2026-06-15)
- [x] M2: add `publishingTimeout` to `OutboxPublishOptions` (default 300 s) and call the sweeper at the start of `publishClaimedOutbox` (completed 2026-06-15)
- [x] M2: wrap the publish callback in `trySync` so an exception becomes `PublishFailed` instead of stranding the batch (completed 2026-06-15)
- [x] M2: guard `markOutboxSent` with `AND status = 'publishing'` and return `Bool` (completed 2026-06-15)
- [x] M2: make `parseStatus` return `Either Text OutboxStatus` and fail the row decode via `D.refine` on unknown statuses (completed 2026-06-15)
- [x] M2: fix the false reclaim claim in the `OutboxStatus` haddock in `keiro/src/Keiro/Outbox/Types.hs` (completed 2026-06-15)
- [x] M2: add the `keiro.outbox.reclaimed` counter to `keiro/src/Keiro/Telemetry.hs` (completed 2026-06-15)
- [x] M2: write the crash-window tests (reclaim after timeout, no premature reclaim, exception guard, dead-letter on exhausted crash loop, sent-guard lost race) (completed 2026-06-15; focused `Keiro.Outbox` run passed with 20 examples, 0 failures; full `keiro-test` passed with 188 examples, 0 failures)
- [x] M3: add `garbageCollectSent` to the outbox schema and public module, with tests (completed 2026-06-15)
- [x] M3: document the per-key ordering constraint on `enqueueOutboxTx` / `enqueueIntegrationEventTx` / `OrderingPolicy` (M1 finding, documentation-only) (completed 2026-06-15)
- [x] M3: extend the `KafkaDeliveryIdentity` docstring (does not dedupe producer republishes) (completed 2026-06-15; focused `Keiro.Outbox` run passed with 21 examples, 0 failures; full `keiro-test` passed with 189 examples, 0 failures)
- [ ] M4: skip `countInboxBacklog` in `runInboxTransactionWithKey` when metrics are disabled
- [ ] M4: add `attemptCount` to `InboxRow`, the decoder, and `selectAllSql`
- [ ] M4: add `recordFailedAttemptTx` upsert statement to `keiro/src/Keiro/Inbox/Schema.hs`
- [ ] M4: add `runInboxTransactionWithRetries` / `runInboxTransactionWithRetriesKey` and the `InboxHandlerFailed` result constructor
- [ ] M4: export `markFailedTx` from `keiro/src/Keiro/Inbox.hs`
- [ ] M4: add the `keiro.inbox.poisoned` counter
- [ ] M4: fix `defaultEpoch` partial `read`, the stale race comment, and make `parseInboxStatus` loud
- [ ] M4: write the poison-message tests (record failure, retry below ceiling, dead-letter at ceiling)
- [ ] M5: add `requeueStuckTimers` to `keiro/src/Keiro/Timer/Schema.hs`
- [ ] M5: add `requeueStuckAfter` to `TimerWorkerOptions` (default `Just 300`) and invoke the requeue in `runTimerWorkerWith`
- [ ] M5: guard `markTimerFired` with `AND status = 'firing'` and return `Bool`
- [ ] M5: make `statusFromText` loud (unknown timer status must not decode as `Cancelled`)
- [ ] M5: add the `keiro.timer.requeued` counter; fix the module and function docs
- [ ] M5: write the timer crash-window tests
- [ ] M6: stop mapping shard snapshot/acquire errors to empty sets; keep the previous owned set and report through the new `onShardError` hook
- [ ] M6: supervise reader threads with `forkFinally` + intentional-stop flag; restart dead readers on the next reconcile
- [ ] M6: relinquish all held buckets in the shutdown `finally` of `runShardedSubscriptionGroup`
- [ ] M6: make `ensureShards` fail loudly on a `shard_count` mismatch against existing rows
- [ ] M6: document the zombie-worker / checkpoint-regression edge (M5 finding, documentation-only)
- [ ] M6: write the shard tests (immediate relinquish on shutdown, dead-reader restart, pure error-path unit test)
- [ ] M7: add `mkOutboxPublishOptions`, `mkTimerWorkerOptions`, `mkShardedWorkerOptions`, `mkIntegrationProducer` smart constructors with `<Thing>ConfigError` types, with tests
- [ ] Final: full `cabal build all` and `cabal test keiro-test` green; update masterplan rollup checkboxes for EP-4


## Surprises & Discoveries

Authoring-time findings that correct or extend the June 2026 audit notes (re-verify nothing here blindly — file references were checked on 2026-06-10):

- The masterplan's KeiroMetrics integration point says "snake_case metric names prefixed `keiro_`", but every existing instrument in `keiro/src/Keiro/Telemetry.hs` (lines 496–535) uses dot-separated names such as `keiro.outbox.backlog`. The existing code wins; new instruments follow the dot convention (see Decision Log).
- The audit said only `2026-06-05-01` pins `search_path`; in fact `2026-06-05-00-00-00-keiro-workflow-generation.sql` pins it too, and the three `2026-06-03` workflow migrations are also unpinned. Seven migrations need the pin, not four (see Decision Log for the scope call).
- codd (the migration tool, source at `/Users/shinzui/Keikaku/hub/haskell/codd-project`) tracks applied migrations purely by file name — `SELECT num_applied_statements, no_txn_failed_at FROM codd_schema.sql_migrations WHERE name=?` in `codd/src/Codd/Internal.hs` (~line 423). There is no content checksum of applied migrations, so editing an already-applied migration in place is safe: existing databases skip it by name, fresh databases (including every test template) get the corrected text.
- The haddock on `runTimerWorkerWith` in `keiro/src/Keiro/Timer.hs` (lines 87–88) claims "A @fire@ that returns 'Nothing' leaves the timer @Firing@ to be retried on a later claim" — false today for the same reason as H2 (the claim query only takes `scheduled` rows). The M5 fix makes this sentence true.
- `Data.TypeID.genTypeID` from the `mmzk-typeid` package throws a `TypeIDError` at runtime for an invalid prefix (verified in `/Users/shinzui/Keikaku/hub/haskell/mmzk-typeid-project/mmzk-typeid/src/Data/TypeID/Internal.hs`, `genTypeIDs`), and the package exports `checkPrefix :: Text -> Maybe TypeIDError` from `Data.TypeID` — exactly what `mkIntegrationProducer` needs for construction-time validation (L4).
- Milestone 1 also requires regenerating `keiro-migrations/expected-schema` with `cabal run keiro-write-expected-schema`. The new migration applied and repeated successfully before regeneration, but `cabal test keiro-migrations-test` failed its strict schema comparison until the expected-schema files included the inbox `attempt_count` column and the new inbox/outbox indexes.
- The M2 head-of-line reclaim test needs two publisher passes for two same-key rows, not one. `publishClaimedOutbox` is intentionally a one-batch worker: after the sweeper moves the stranded first row from `publishing` to `failed`, the claim query can claim that first row, but the second row remains blocked by the non-terminal first row until the first reaches `sent`. This preserves the one-shot worker contract and still proves the key is unwedgeable.


## Decision Log

- Decision: Fix C1 with an explicit reclaim sweeper (`requeueStuckOutbox`, invoked at the start of every `publishClaimedOutbox` pass) rather than widening the claim query's status predicate.
  Rationale: Keeps the policy-parameterised claim SQL and its head-of-line `NOT EXISTS` predicates untouched; mirrors the timer fix so both subsystems share one recovery idiom ("stale in-flight rows are moved back to a claimable status by the worker itself"); makes reclaims countable for the `keiro.outbox.reclaimed` metric; and lets the sweeper dead-letter a row whose claims have already exhausted `maxAttempts` (a publish that crashes the worker every time must not loop forever).
  Date: 2026-06-10

- Decision: `publishingTimeout` defaults to 300 seconds (5 minutes). A row reclaimed while a slow-but-alive publisher still holds it will be published twice; this is within the outbox's documented at-least-once contract and is called out in the haddock, with guidance to set the timeout above the worst-case batch publish duration.
  Rationale: A shorter default keeps the post-crash head-of-line wedge bounded to minutes; a Kafka client's own delivery timeouts are well under 5 minutes, so false reclaims need pathological stalls.
  Date: 2026-06-10

- Decision: `garbageCollectSent` deletes only `sent` rows older than the retention window. `dead` rows are never pruned automatically.
  Rationale: A `dead` row is an unresolved operator action item — pruning it silently destroys the only record that an event was never published. Operators delete dead rows manually (or resurrect them) after investigation; the haddock says so.
  Date: 2026-06-10

- Decision: M1 (per-key ordering versus concurrent enqueuers) is fixed by documentation only; no sequence column or commit-horizon (`pg_snapshot_xmin`) gating in this plan.
  Rationale: The canonical enqueue path — the single-threaded `IntegrationProducer` subscription — serialises same-key enqueues, so the race is reachable only through the `enqueueIntegrationEventTx` escape hatch. Commit-horizon gating would complicate the claim query for every caller to protect an edge the canonical path cannot hit. The constraint is documented loudly on the escape hatch and on `OrderingPolicy`; a sequence-based design is left as recorded future work.
  Date: 2026-06-10

- Decision: M6 (migration `search_path` fragility) is fixed by editing the seven unpinned migrations in place, and the scope is widened from the audit's four (`2026-05-17-*`) to also cover the three `2026-06-03-*` workflow migrations.
  Rationale: codd registers applied migrations by name with no content checksum (verified in codd's source, see Surprises), so in-place edits cannot break existing databases — they skip by name — while every fresh apply (and every test-suite template database) gets the pin. Leaving three files with the identical defect for another plan to fix would be coordination overhead for a one-line mechanical change.
  Date: 2026-06-10

- Decision: New metric instruments use the existing dot-separated naming (`keiro.outbox.reclaimed`, `keiro.timer.requeued`, `keiro.inbox.poisoned`), not the snake_case the masterplan's integration note suggests.
  Rationale: Twenty existing instruments in `keiro/src/Keiro/Telemetry.hs` already use dots; consistency inside the codebase beats consistency with a one-line masterplan note. Recorded here so the masterplan can be corrected.
  Date: 2026-06-10

- Decision: Timer stuck-`firing` requeue is on by default (`requeueStuckAfter = Just 300` in `defaultTimerWorkerOptions`), not opt-in.
  Rationale: The module documentation has promised this behavior since the timer shipped ("A timer left @Firing@ by a crash becomes claimable again", `keiro/src/Keiro/Timer.hs` lines 9–10); defaulting it off would perpetuate the documentation lie. `Nothing` opts out for callers that run their own recovery.
  Date: 2026-06-10

- Decision: The inbox poison-message path is a new opt-in wrapper (`runInboxTransactionWithRetries`); the existing `runInboxTransaction` keeps its exact rollback-and-rethrow semantics.
  Rationale: Existing consumers may rely on "handler exception ⇒ no inbox row ⇒ Kafka redelivery retries cleanly". The new wrapper changes failure persistence (a second transaction records the failed attempt), which must be a conscious choice. Requires a new `attempt_count` column on `keiro_inbox` (migration in M1).
  Date: 2026-06-10

- Decision: Unknown status strings read back from the database become hasql decode failures (via `Hasql.Decoders.refine`) instead of being silently mapped to a fallback constructor (L1).
  Rationale: The current fallbacks rewrite corruption into business meaning — worst of all the timer's, where an unrecognized status decodes as `Cancelled` and a saga timeout silently never fires. A loud decode error surfaces through the `Store` error channel that every caller already handles.
  Date: 2026-06-10

- Decision: On a snapshot or acquire error the shard worker keeps its previous owned set and running readers untouched, reporting through a new optional `onShardError` callback on `ShardedWorkerOptions`; a renewal failure is not treated as lease loss (the lease is only truly lost when another worker claims it after TTL expiry).
  Rationale: A transient blip must degrade to "no rebalance this tick", never to "stop all readers". Disjointness is unaffected: the worker keeps reading buckets whose leases it may have failed to renew, but kiroku subscriptions are at-least-once and a competing claim only happens after the TTL anyway — exactly the documented zombie window (M5).
  Date: 2026-06-10

- Decision: After the M6 shutdown fix, `killThread` on the worker loop triggers `finally`, which now relinquishes leases — so the existing end-to-end failover test no longer exercises failover-by-expiry. That coverage is retained at the SQL layer ("B claims A's buckets after A's lease expires" in `keiro/test/Main.hs` ~line 3046), so no new end-to-end expiry test is added.
  Rationale: A real crash (SIGKILL) cannot run `finally` either; expiry recovery is a property of the lease table, already proven where it lives.
  Date: 2026-06-10

- Decision: Smart constructors take the fully built record and validate it — `mkOutboxPublishOptions :: OutboxPublishOptions -> Either OutboxPublishConfigError OutboxPublishOptions` — rather than taking positional arguments. Error types are named `<Thing>ConfigError` per the masterplan convention shared with `docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md`.
  Rationale: These option records have five to seven fields with sensible defaults; the idiomatic call site is a record update of the default followed by validation. The convention being coordinated with EP-8 is the error-type naming and the `Either` shape, both preserved.
  Date: 2026-06-10

- Decision: No `lease_generation` fencing counter in this plan; the zombie-worker double-read and the kiroku checkpoint-regression edge are documented on the worker (M5 is documentation-only).
  Rationale: The subsystem is documented at-least-once end to end; fencing changes the kiroku checkpoint write path, which is outside this repository's messaging modules and out of the initiative's hardening scope.
  Date: 2026-06-10


## Outcomes & Retrospective

Milestone 1 completed on 2026-06-15. The migration layer now creates the inbox failure-attempt column and the three indexes later milestones rely on, every Keiro-owned framework migration pins `search_path`, and the embedded-migration comment plus checked-in expected schema were updated. Validation passed with `cabal test keiro-migrations-test` (2 examples, 0 failures) and `cabal test keiro-test` (182 examples, 0 failures).

Milestone 2 completed on 2026-06-15. The outbox worker now reclaims stale `publishing` rows, dead-letters stale rows that have exhausted their claim budget, converts synchronous publisher exceptions into ordinary failed attempts so the batch continues, guards `markOutboxSent` against stale races, decodes unknown statuses loudly, and records `keiro.outbox.reclaimed`. Validation passed with focused `cabal test keiro-test --test-show-details=direct --test-options='--match "Keiro.Outbox"'` (20 examples, 0 failures) and full `cabal test keiro-test` (188 examples, 0 failures).

Milestone 3 completed on 2026-06-15. The outbox now exposes `garbageCollectSent` for pruning expired successful publishes while preserving `dead` rows, the ordering caveat for concurrent same-key enqueue escape hatches is documented on the public surfaces, and `KafkaDeliveryIdentity` now states that producer republishes receive new offsets and are not deduplicated by that policy. Validation passed with focused `Keiro.Outbox` tests (21 examples, 0 failures) and full `cabal test keiro-test` (189 examples, 0 failures).


## Context and Orientation

This is a Haskell monorepo built with `cabal` (run all commands from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`, inside the project's dev shell). The relevant packages:

- `keiro/` — the runtime library this plan edits. Its messaging modules live under `keiro/src/Keiro/`: `Outbox.hs`, `Outbox/Schema.hs`, `Outbox/Types.hs`, `Outbox/Kafka.hs`, `Inbox.hs`, `Inbox/Schema.hs`, `Inbox/Types.hs`, `Inbox/Kafka.hs`, `Timer.hs`, `Timer/Schema.hs`, `Timer/Types.hs`, `Subscription/Shard.hs`, `Subscription/Shard/Schema.hs`, `Subscription/Shard/Worker.hs`, and the shared telemetry surface `Telemetry.hs`. Its single test suite is `keiro/test/Main.hs` (cabal target `keiro-test`).
- `keiro-migrations/` — embedded SQL migrations applied by codd. The `.sql` files live in `keiro-migrations/sql-migrations/` and are compiled in via Template Haskell (`embedDir` in `keiro-migrations/src/Keiro/Migrations.hs`; note the comment at the bottom of that file — you must touch it after adding a `.sql` file or GHC will not recompile the embed). `cabal run keiro-migrate -- new <description>` (run from `keiro-migrations/`) generates a correctly named skeleton.
- `keiro-test-support/` — the PostgreSQL test fixture. `withMigratedSuite` in `keiro-test-support/src/Keiro/Test/Postgres.hs` starts one ephemeral PostgreSQL server per suite, applies all kiroku + keiro migrations once to a template database, and `withFreshStore` clones a fresh migrated database per example. DB tests always go through this fixture; never write per-example migration code.
- kiroku (the event store, separate repository at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`) provides the `Store` effect (`Kiroku.Store.Effect`), `runTransaction :: Store :> es => Tx.Transaction a -> Eff es a` (hasql transactions through kiroku's pool), and `runStoreIO :: KirokuStore -> Eff '[Store, IOE] a -> IO (Either err a)` used heavily in tests.

Key idioms: the code uses the `effectful` effect system (`Eff es`, constraints like `(IOE :> es, Store :> es)`); SQL is written as hasql `Statement` values with multiline-string literals; record access uses `generic-lens` optics (`row ^. #status`); exceptions are handled with `Effectful.Exception` (which provides `trySync`/`catchSync` — synchronous-only variants that do not swallow thread-kill).

How each worker functions today, and what is broken (every file:line was re-verified on 2026-06-10; re-verify before editing — line numbers drift):

**Outbox.** `keiro_outbox` rows (created by `enqueueOutboxTx`, migration `2026-05-17-01-00-00-keiro-outbox.sql`) carry `status` ∈ {`pending`, `publishing`, `sent`, `failed`, `dead`}, `attempt_count`, `next_attempt_at`, `created_at DEFAULT now()`. `publishClaimedOutbox` (`keiro/src/Keiro/Outbox.hs` ~240–306) claims a batch via `claimOutboxBatch`, which runs `claimSql` (`keiro/src/Keiro/Outbox/Schema.hs` ~313–351): select `WHERE r.status IN ('pending','failed') AND next_attempt_at <= $2` plus an ordering-policy predicate, `FOR UPDATE SKIP LOCKED`, then `UPDATE ... SET status = 'publishing', attempt_count = attempt_count + 1, updated_at = $2`. The findings:

- C1 (critical): nothing ever selects `status = 'publishing'` again. A crash (or thrown exception) between claim and mark strands the row forever. The haddock on `OutboxPublishing` in `keiro/src/Keiro/Outbox/Types.hs` (~50–53) falsely says such rows are "reclaimable through the same claim query". Under `PerKeyHeadOfLine`/`PerSourceStream` the `NOT EXISTS ... status NOT IN ('sent','dead')` predicates (Schema.hs ~293–311) treat the stuck row as a live predecessor, blocking all later same-key/same-source rows forever.
- H1: `publish row` (Outbox.hs ~276) is not exception-guarded. `withProducerSpan` (`keiro/src/Keiro/Telemetry.hs` ~236–250) re-throws. Real Kafka clients throw; one throw strands the entire claimed batch in `publishing` (and is then also C1).
- M7 (outbox half): `markSentStmt` (Schema.hs ~396–411) updates `WHERE outbox_id = $1` with no status guard — a zombie worker can flip an operator-dead-lettered row to `sent`.
- H4: there is no outbox pruning at all (the inbox has `garbageCollectCompleted`; the outbox has nothing). `sent` rows accumulate forever.
- M1: `created_at` defaults to `now()`, which in PostgreSQL is *transaction-start* time. Two concurrent enqueue transactions can commit in the opposite order of their `created_at`; a publisher pass between the two commits publishes the later-created row first and the per-key order is violated. Safe on the canonical single-threaded `IntegrationProducer` path; reachable via `enqueueIntegrationEventTx`.
- L1 (outbox): `parseStatus` (Types.hs ~198–205) maps unknown text to `OutboxFailed` silently.
- L4: `mintIntegrationEvent` (Outbox.hs ~162–163) calls `TypeID.genTypeID (producer ^. #messageIdPrefix)`, which throws at first use if the prefix is invalid; nothing validates at construction.
- L8: the only partial index supporting head-of-line checks is `keiro_outbox_head_of_line_idx (source, message_key, created_at) WHERE ... message_key IS NOT NULL`; the `PerSourceStream` predicate (any key, including NULL) has no supporting index.

**Inbox.** `keiro_inbox` rows (migration `2026-05-17-02-00-00-keiro-inbox.sql`, primary key `(source, dedupe_key)`) carry `status` ∈ {`processing`, `completed`, `failed`}. `runInboxTransactionWithKey` (`keiro/src/Keiro/Inbox.hs` ~84–116) inserts the row as `processing`, runs the handler in the same transaction, and marks `completed`; a duplicate insert branches on the existing row's status. The findings:

- H3: lines ~114–115 run `countInboxBacklog` — `SELECT COUNT(*) ... WHERE status IN ('processing','failed')` — unconditionally on every consumed message, even when `mMetrics = Nothing` makes `recordInboxBacklog` a no-op. `keiro_inbox` has indexes only on `received_at` and a partial one on `completed_at WHERE status = 'completed'`, so this is a sequential scan per message.
- H5: the documented permanent-failure path is unreachable: `markFailedTx` is exported only from `Keiro.Inbox.Schema`, not from the public `Keiro.Inbox` (export list, Inbox.hs ~15–28). An always-throwing handler rolls back the insert and the Kafka layer redelivers forever — a wedged partition with no recorded trace.
- L1 (inbox): `parseInboxStatus` (`keiro/src/Keiro/Inbox/Types.hs` ~129–134) maps unknown statuses to `InboxFailed`.
- L2: `defaultEpoch` (`keiro/src/Keiro/Inbox/Schema.hs` ~497–498) is `read "1970-01-01 00:00:00 UTC"` — a partial function evaluated lazily inside a decoder.
- L9: the comment block at Schema.hs ~68–71 floats detached below `tryInsertProcessingTx` and describes the insert-conflict-then-vanished race incorrectly ("the next insert in this transaction will reflect the up-to-date state" — there is no next insert).
- L6: the `KafkaDeliveryIdentity` haddock (Types.hs ~41–43) does not state that topic/partition/offset identity cannot deduplicate a producer republish (a republish gets a new offset).
- L3 (not this plan): propagating the producer's `occurred_at` as a Kafka header is owned by `docs/plans/68-harden-keiro-core-codec-and-stream-contracts.md`. If you touch the `occurredAt` haddocks in `keiro/src/Keiro/Inbox/Kafka.hs`, only cross-reference that plan; do not implement the header.

**Timers.** `keiro_timers` rows (created in `2026-05-17-00-00-00-keiro-bootstrap.sql`, recovery columns in `2026-05-17-03-00-00-keiro-timer-recovery.sql`) carry `status` ∈ {`scheduled`, `firing`, `fired`, `cancelled`, `dead`}, `attempts`, `updated_at`. `runTimerWorkerWith` (`keiro/src/Keiro/Timer.hs` ~93–131) claims one due timer (`claimDueTimerStmt`, `keiro/src/Keiro/Timer/Schema.hs` ~226–249: `WHERE status = 'scheduled' AND fire_at <= $1`, sets `status = 'firing'`, `attempts + 1`, `updated_at = now()` — note: *database* clock), runs the caller's `fire`, then `markTimerFired`. The findings:

- H2: nothing automatically requeues `firing` rows. The module doc (Timer.hs ~8–10) and `Firing`'s haddock (Timer/Schema.hs ~54–55) claim a crashed worker's timer "becomes claimable again" — false. Operator-facing pieces exist (`findStuckTimers`, `requeueStuckTimer`, all one-row-at-a-time) but `runTimerWorkerWith` only *counts* stuck rows for the `keiro.timer.stuck` gauge (Timer.hs ~108–109). A crash mid-fire strands a saga timeout until a human intervenes.
- M7 (timer half): `markTimerFiredStmt` (Timer/Schema.hs ~251–265) has no status guard.
- L1 (timer, the worst of the three): `statusFromText` (Timer/Schema.hs ~376–383) maps any unknown status to `Cancelled` — corruption silently cancels a timer.
- L7 (mention only, optional future work): the claim is one-timer-per-call; a batch claim would amortise round trips. Out of scope.

**Sharded subscriptions.** `keiro_subscription_shards` (migration `2026-06-05-01-00-00-keiro-subscription-shards.sql`) holds one lease row per `(subscription_name, bucket)`. `runShardedSubscriptionGroup` (`keiro/src/Keiro/Subscription/Shard/Worker.hs` ~222–248) loops `reconcileShardsOnce` every `renewInterval`: snapshot ownership, `acquireOwnedBuckets` (renew + claim one), shed excess, then start/stop one kiroku consumer-group reader per owned bucket. The findings:

- M2: both store calls swallow errors — `either (const []) id` (Worker.hs ~150) and `either (const Set.empty) id` (~155). A transient DB error makes `claimed = ∅`, so `toStop = all running readers` (~169–171), silently, with nothing logged; `ensureShards`' result is discarded at ~237.
- M3: `startReader` forks the drain with a bare `forkIO` (~201). If the handler throws, the thread dies; the bucket stays leased by this worker but is never read — leased-but-dark, undetected.
- M4: the shutdown `finally` (~239) only stops readers. `relinquish` (`keiro/src/Keiro/Subscription/Shard.hs` ~150) exists but is never called on shutdown, so every deploy eats up to `leaseTtl` (default 30 s) of bucket downtime.
- M5 (documentation-only): there is no fencing token; a zombie worker past TTL can double-read a bucket concurrently with the new owner and race kiroku's per-member checkpoint (a regression enlarges the redelivery window). At-least-once is already documented (~40–42); the checkpoint-regression edge is not.
- L5 (shard part): nothing detects a `shardCount` change across replicas — `ensureShardRows` is `ON CONFLICT DO NOTHING`, so old rows keep the old `shard_count` and two workers can disagree on the hash modulus, silently double-reading or skipping streams.

**Telemetry.** `KeiroMetrics` (`keiro/src/Keiro/Telemetry.hs` ~548–569) is a record of instruments built by `newKeiroMetrics`; every worker takes `Maybe KeiroMetrics` and the `record*` helpers no-op on `Nothing`. This plan adds three counters (additive fields; instrument names follow the existing dot convention).

**Masterplan integration points that constrain this plan** (from `docs/masterplans/9-keiro-production-readiness-hardening.md`): this plan owns the timer claim/requeue/mark statements, and `docs/plans/73-workflow-sleep-generation-and-patch-semantics-plus-journal-scale-hygiene.md` will later change the arm path (`scheduleTimerTx`) to preserve `fire_at` on re-arm — so every statement added here must keep working when a re-arm no longer rewrites `fire_at`; the requeue designed below touches only `status` and `updated_at`, which satisfies that. The config-validation convention (`mkX :: ... -> Either XConfigError X`, raw constructor still exported) is shared with `docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md`. This plan is expected to land the initiative's first crash-window tests and thereby establish the pattern that `docs/plans/71-...`, `72-...`, and `73-...` reuse; the pattern is specified in Milestone 2.


## Plan of Work

The work is seven milestones. Each is independently verifiable with `cabal test keiro-test` (plus `cabal test keiro-migrations-test` for Milestone 1) and lands its own tests in `keiro/test/Main.hs` inside the existing `describe` blocks for the touched subsystem.

### Milestone 1 — Schema groundwork (migration + search_path pins)

Scope: everything that changes SQL files, so all later code milestones build on a settled schema. At the end, a fresh database (and therefore the test-suite template) has an `attempt_count` column on `keiro_inbox`, three new partial indexes, and every keiro migration pins its `search_path`.

Generate the new migration from the `keiro-migrations/` directory:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations
cabal run keiro-migrate -- new messaging crash recovery
```

Expected output (timestamp will differ):

```text
Created sql-migrations/2026-06-11-09-15-00-keiro-messaging-crash-recovery.sql
Next: touch the embed comment in src/Keiro/Migrations.hs so embedDir picks it up (or run `cabal clean`).
```

Replace the generated body placeholder so the file reads (keep the generated header comment and the `SET search_path` line the template already emits):

```sql
SET search_path TO kiroku, pg_catalog;

-- H5: per-message failure accounting for the inbox poison-message path.
ALTER TABLE keiro_inbox
  ADD COLUMN IF NOT EXISTS attempt_count BIGINT NOT NULL DEFAULT 0;

-- H3: lets the backlog gauge count rows without a sequential scan.
CREATE INDEX IF NOT EXISTS keiro_inbox_backlog_idx
  ON keiro_inbox (status)
  WHERE status IN ('processing', 'failed');

-- H4: lets garbageCollectSent find expired sent rows without a sequential scan.
CREATE INDEX IF NOT EXISTS keiro_outbox_sent_gc_idx
  ON keiro_outbox (published_at)
  WHERE status = 'sent';

-- L8: supports the PerSourceStream head-of-line predicate (any key, including
-- NULL); the existing keiro_outbox_head_of_line_idx excludes NULL keys.
CREATE INDEX IF NOT EXISTS keiro_outbox_source_order_idx
  ON keiro_outbox (source, created_at, outbox_id)
  WHERE status NOT IN ('sent', 'dead');
```

Then add the pin line (with the standard three-line explanatory comment the template in `keiro-migrations/src/Keiro/Migrations/New.hs` emits) as the first statement of the seven unpinned migrations: `2026-05-17-00-00-00-keiro-bootstrap.sql`, `2026-05-17-01-00-00-keiro-outbox.sql`, `2026-05-17-02-00-00-keiro-inbox.sql`, `2026-05-17-03-00-00-keiro-timer-recovery.sql`, `2026-06-03-00-00-00-keiro-workflow-steps.sql`, `2026-06-03-01-00-00-keiro-awakeables.sql`, `2026-06-03-02-00-00-keiro-workflow-children.sql`. This is safe for already-migrated databases because codd skips applied migrations by name (see Surprises & Discoveries). Finally, edit the embed-touch comment at the bottom of `keiro-migrations/src/Keiro/Migrations.hs` (append the new file's name to the list) so the TH `embedDir` recompiles.

Acceptance: `cabal test keiro-migrations-test` passes, and `cabal test keiro-test` still passes (the suite template now carries the new column and indexes). To eyeball the schema, any test failure message aside, you can also run the jitsurei dev database flow, but the two test suites are the gate.

### Milestone 2 — Outbox crash recovery (C1, H1, M7-outbox, L1-outbox) and the crash-window test pattern

Scope: a crashed or throwing publisher can no longer lose an event or wedge a key. This milestone establishes the initiative's crash-window test pattern.

In `keiro/src/Keiro/Outbox/Schema.hs` add a sweeper and its statements:

```haskell
-- | Reclaim rows stranded in @publishing@ longer than @olderThan@.
-- Rows whose claim already consumed the attempt budget are dead-lettered;
-- the rest return to @failed@ (immediately claimable, since their
-- @next_attempt_at@ already passed when they were claimed). Returns
-- (requeued, deadLettered).
requeueStuckOutbox ::
    (Store :> es) =>
    Int ->                -- ^ maxAttempts (same value the worker passes to markOutboxFailedTx)
    NominalDiffTime ->    -- ^ olderThan: minimum age of the stale claim, measured on updated_at
    UTCTime ->            -- ^ now
    Eff es (Int, Int)
```

Implemented as one transaction running two `UPDATE` statements (both `D.rowsAffected`): first dead-letter — `SET status = 'dead', last_error = COALESCE(last_error, 'reclaimed: publisher crashed mid-publish'), updated_at = $3 WHERE status = 'publishing' AND updated_at <= $1 AND attempt_count >= $2`; then requeue — same predicate with `attempt_count < $2`, setting `status = 'failed'` instead. The cutoff `$1` is `addUTCTime (negate olderThan) now` computed in Haskell, like `garbageCollectCompleted` does. The existing `keiro_outbox_pending_idx (status, next_attempt_at, created_at)` serves the `status = 'publishing'` equality prefix; no new index is needed.

In `keiro/src/Keiro/Outbox/Types.hs`: add `publishingTimeout :: !NominalDiffTime` to `OutboxPublishOptions`, set `300` in `defaultPublishOptions`; rewrite the `OutboxPublishing` haddock to describe the sweeper (the current text promises a mechanism that does not exist); change `parseStatus :: Text -> OutboxStatus` to `parseStatus :: Text -> Either Text OutboxStatus` (unknown input becomes `Left "unknown keiro_outbox.status: …"`).

In `keiro/src/Keiro/Outbox/Schema.hs`: switch the status column decode to `D.column (D.nonNullable (D.refine parseStatus D.text))` so an unknown status fails the decode loudly; add `AND status = 'publishing'` to `markSentStmt` and change `markOutboxSent` to return `Bool` via `(> 0) <$> D.rowsAffected` (haddock: `False` means the row left `publishing` while we were publishing — reclaimed or operator-modified; the publish itself still happened, which is within at-least-once).

In `keiro/src/Keiro/Outbox.hs` (`publishClaimedOutbox`): before claiming, run `(requeued, deadened) <- requeueStuckOutbox (options ^. #maxAttempts) (options ^. #publishingTimeout) now`, record `recordOutboxReclaimed mMetrics` and `recordOutboxDeadlettered mMetrics` accordingly; wrap the publish callback with `Effectful.Exception.trySync` so a thrown exception becomes `PublishFailed (Text.pack (displayException e))` and the batch continues (the existing `markOutboxFailedTx` path then applies backoff/dead-letter as for any failure); ignore-but-document the `Bool` from `markOutboxSent` (count it as published either way); re-export `requeueStuckOutbox`. Also skip the `countOutboxBacklog` query when `mMetrics` is `Nothing` (the outbox half of H3 — it runs once per pass, not per message, but the consistency is free while editing this function).

In `keiro/src/Keiro/Telemetry.hs`: add `outboxReclaimed :: Counter Int64` to `KeiroMetrics`, instrument name `keiro.outbox.reclaimed`, unit `{event}`, description "Outbox rows reclaimed from a crashed or stalled publisher.", helper `recordOutboxReclaimed`, wired in `newKeiroMetrics`.

**The crash-window test pattern** (this is the integration point other plans reuse; keep this comment-documented in the test file). A crash-window test proves a recovery guarantee that spans two SQL statements by executing only the first statement and then exercising recovery, never by killing a process. Shape: (1) arrange rows with ordinary public API calls; (2) simulate the crash by calling the *schema-level claim statement directly* and then doing nothing — for statements that persist a caller-supplied timestamp (the outbox claim writes `updated_at = $2`), pass a timestamp far enough in the past that the recovery TTL has already elapsed; for statements that persist the database clock (the timer claim writes `updated_at = now()`), instead drive the recovery entry point with a `now` far enough in the *future*; (3) assert the stranded intermediate state with a lookup; (4) run the worker entry point once; (5) assert the row was recovered and processed exactly once. No sleeping, no process control — time is an injected parameter throughout these workers, which is precisely why the pattern works.

New examples in the `describe "Keiro.Outbox"` block of `keiro/test/Main.hs` (all `around (withFreshStore fixture)`, using the existing `sampleIntegrationEnvelope` / `outboxUuid*` helpers):

1. "reclaims a row stranded in publishing by a crashed worker (crash window: claim → mark)": enqueue one row; `claimOutboxBatch PerKeyHeadOfLine 10 pastNow` where `pastNow = addUTCTime (-3600) now` (simulated crash); assert `lookupOutbox` shows `OutboxPublishing`; run `publishClaimedOutbox` with an always-succeeding publish and default options; assert the summary shows one published, the row is `OutboxSent`, and the publish callback ran exactly once (IORef counter).
2. "head-of-line traffic unwedges after reclaim": enqueue two same-key rows; strand only the first (`claimOutboxBatch _ 1 pastNow`); assert a plain pass with a fresh `now` publishes *both*, in `created_at` order.
3. "does not reclaim a recently claimed row": claim with the current time; run a pass; assert the row is still `OutboxPublishing` and the publish callback never ran.
4. "a throwing publish callback fails one row and continues the batch" (H1): two rows with different keys, publish throws (`error "kafka exploded"`) for the first and succeeds for the second; assert summary `retried = 1, published = 1`, the first row is `OutboxFailed` with `last_error` containing the exception text, the second `OutboxSent`.
5. "a row that exhausts attempts while crash-looping is dead-lettered by the sweeper": options with `maxAttempts = 1`; claim with `pastNow` (the claim sets `attempt_count = 1`); run a pass; assert the row is `OutboxDead` and the publish callback never ran for it.
6. "markOutboxSent does not resurrect a dead row" (M7): enqueue, claim, drive to `dead` via `runTransaction (markOutboxFailedTx oid "boom" 0 0 now)`; assert `markOutboxSent oid now` returns `False` and the status stays `OutboxDead`.

### Milestone 3 — Outbox hygiene: pruning and ordering documentation (H4, M1, L6)

Scope: the outbox stops growing without bound, and the ordering contract is honest.

Add to `keiro/src/Keiro/Outbox/Schema.hs` (re-exported from `Keiro.Outbox`):

```haskell
-- | Delete @sent@ rows whose @published_at@ is older than @keepFor@ before
-- @now@. Returns the number of rows deleted. @dead@ rows are never deleted:
-- they are unresolved operator action items (see Decision Log of
-- docs/plans/70-...). The retention window bounds how long publish history
-- remains queryable for audit; it has no correctness role (dedupe lives in
-- the consumer's inbox, not here).
garbageCollectSent :: (Store :> es) => NominalDiffTime -> UTCTime -> Eff es Int
```

SQL mirrors the inbox `gcStmt`: `WITH deleted AS (DELETE FROM keiro_outbox WHERE status = 'sent' AND published_at < $1 RETURNING 1) SELECT COALESCE(COUNT(*), 0)::bigint FROM deleted` (served by the new `keiro_outbox_sent_gc_idx`).

Documentation (M1): on `enqueueIntegrationEventTx`, `enqueueOutboxTx`, and the `OrderingPolicy` haddock, add a prominent warning: per-key/per-source ordering is keyed on `created_at`, which PostgreSQL fills with *transaction-start* time; two concurrent enqueue transactions for the same key can commit in the opposite order of their `created_at`, and a publisher pass between the two commits will publish them out of order. Ordering is guaranteed only when same-key enqueues are serialized — which the canonical single-threaded `IntegrationProducer` subscription does. Callers of the escape hatch must serialize same-key enqueues themselves or accept best-effort order.

Documentation (L6): on `KafkaDeliveryIdentity` in `keiro/src/Keiro/Inbox/Types.hs`, state explicitly that a producer republish of the same logical message arrives at a new offset and is therefore *not* deduplicated by this policy; only `PreferIntegrationMessageId` / `PreferSourceEventIdentity` collapse republishes.

Tests (in `describe "Keiro.Outbox"`): "garbageCollectSent deletes only old sent rows" — create four rows and drive them to `sent`-old, `sent`-recent, `failed`, and `dead`; run `garbageCollectSent` with a window between old and recent; assert the return value is 1 and exactly the old `sent` row is gone (`lookupOutbox` for each).

### Milestone 4 — Inbox: hot-path cost and the poison-message path (H3, H5, L1, L2, L9)

Scope: consuming a message no longer pays a per-message table scan, and a poison message has a real, documented, tested lifecycle ending in a recorded dead-letter instead of an infinite redelivery loop.

H3: in `runInboxTransactionWithKey` (`keiro/src/Keiro/Inbox.hs`), only run the backlog count when metrics are on — replace the unconditional tail with `for_ mMetrics $ \metrics -> do backlog <- countInboxBacklog; recordInboxBacklog (Just metrics) (fromIntegral backlog)`. With Milestone 1's `keiro_inbox_backlog_idx`, the count is an index-only scan when it does run. (Sampling the gauge on a timer instead of per message remains a possible later optimization; note it in the haddock, do not build it.)

H5, schema half (`keiro/src/Keiro/Inbox/Schema.hs`): add `attemptCount :: !Int` to `InboxRow` (`keiro/src/Keiro/Inbox/Types.hs`), append `attempt_count` to `selectAllSql` and the `RawInbox` decoder; add a new statement-backed transaction:

```haskell
-- | Record one failed handler attempt for @(source, dedupe_key)@, creating
-- the row as @failed@ if the original insert was rolled back. Returns the
-- new attempt count. Runs in its own transaction (the handler's transaction
-- is already rolled back when this is called).
recordFailedAttemptTx ::
    Text -> Text -> IntegrationEvent -> Maybe KafkaDeliveryRef -> Text -> UTCTime ->
    Tx.Transaction Int
```

implemented as the existing insert column list with `status` forced to `'failed'`, `attempt_count` 1, plus `ON CONFLICT (source, dedupe_key) DO UPDATE SET status = 'failed', attempt_count = keiro_inbox.attempt_count + 1, last_error = EXCLUDED.last_error, failed_at = EXCLUDED.failed_at RETURNING attempt_count` (reuse `toEncodedInsert`; add the two extra parameters).

H5, wrapper half (`keiro/src/Keiro/Inbox.hs`): export `markFailedTx` (the one-line fix for the unreachable documented path), add a constructor `InboxHandlerFailed !Text !Int` (error text, attempts so far) to `InboxResult`, and add:

```haskell
runInboxTransactionWithRetries ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Int ->                                  -- ^ attempt ceiling (>= 1)
    InboxDedupePolicy ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))
```

(plus the key-level `runInboxTransactionWithRetriesKey` mirroring the existing pair). Semantics, which the haddock must spell out: a fresh message behaves like `runInboxTransaction`; an existing `failed` row with `attemptCount < ceiling` is *retried* (the handler runs again in the same transaction; success marks it `completed`); an existing `failed` row with `attemptCount >= ceiling` returns `InboxPreviouslyFailed` without running the handler (the dead-letter terminal — the consumer should commit the Kafka offset and move on); a synchronous handler exception is caught with `Effectful.Exception.trySync` *around the whole `runTransaction`* (the transaction has rolled back), then a second transaction runs `recordFailedAttemptTx`, `recordInboxFailed` is bumped, and `InboxHandlerFailed err attempts` is returned — and when this failure is the one that reaches the ceiling, the new `keiro.inbox.poisoned` counter (`inboxPoisoned :: Counter Int64`, unit `{message}`, description "Inbox messages dead-lettered after exhausting handler attempts.") is also bumped. Document that `Tx.condemn` is not treated as a handler failure by this wrapper, and that the original `runInboxTransaction` is unchanged.

Small fixes: `defaultEpoch` becomes `posixSecondsToUTCTime 0` (import `Data.Time.Clock.POSIX`), removing the partial `read` (L2); rewrite the floating comment at Schema.hs ~68–71 as part of `tryInsertProcessingTx`'s haddock, describing the real edge honestly (if the conflicting row is deleted between the insert attempt and the lookup — only concurrent GC can do that — the message is treated as new, the handler runs, and `markCompletedTx` updates zero rows, so that one delivery is not recorded; acceptable because GC only deletes rows past the dedupe retention window) (L9); `parseInboxStatus` returns `Either Text InboxStatus` and the decoder uses `D.refine` (L1).

Tests (in `describe "Keiro.Inbox"`): (1) "a throwing handler records a failed attempt instead of looping": run `runInboxTransactionWithRetries` (ceiling 3) with a handler that throws; assert the result is `InboxHandlerFailed` with attempts 1, and `lookupInbox` shows `InboxFailed` with `attemptCount = 1` and `lastError` populated; (2) "a transient poison message succeeds on retry": handler throws on the first call and succeeds afterwards (IORef flag); deliver twice; assert the second delivery returns `InboxProcessed` and the row is `InboxCompleted`; (3) "an unrecoverable message dead-letters at the ceiling": ceiling 2, always-throwing handler, deliver three times; assert results are `InboxHandlerFailed _ 1`, `InboxHandlerFailed _ 2`, `InboxPreviouslyFailed _`, and the handler ran exactly twice; (4) compile-level: import `markFailedTx` from `Keiro.Inbox` in the test module.

### Milestone 5 — Timers: automatic requeue of stranded firings (H2, M7-timer, L1-timer)

Scope: a saga timeout survives a worker crash without operator intervention, and the timer documentation finally tells the truth.

`keiro/src/Keiro/Timer/Schema.hs`: add a set-based requeue (the existing one-row `requeueStuckTimer` stays for operators):

```haskell
-- | Move every timer stranded in @firing@ for at least @olderThan@ back to
-- @scheduled@. Touches only @status@ and @updated_at@ — @fire_at@ is
-- preserved, which keeps this statement compatible with the fire_at-preserving
-- re-arm planned in docs/plans/73-... . Returns the number of rows requeued.
requeueStuckTimers :: (Store :> es) => NominalDiffTime -> UTCTime -> Eff es Int
```

SQL: `UPDATE keiro_timers SET status = 'scheduled', updated_at = now() WHERE status = 'firing' AND updated_at <= $1` with `$1 = now - olderThan` computed in Haskell; decoded via `D.rowsAffected`. The partial `keiro_timers_due_idx` (`status, fire_at, process_manager_name` `WHERE status IN ('scheduled','firing')`) serves the status equality. Also add `AND status = 'firing'` to `markTimerFiredStmt` and change `markTimerFired` to return `Bool` (`(> 0) <$> D.rowsAffected`); haddock: `False` means the timer was requeued/cancelled/dead-lettered while firing — the caller's fire effect happened, which is within the timer's at-least-once contract. Change `statusFromText` to return `Either Text TimerStatus` and decode via `D.refine` (an unrecognized status must be a loud `Store` error, never a silent `Cancelled`).

`keiro/src/Keiro/Timer.hs`: extend `TimerWorkerOptions` with `requeueStuckAfter :: !(Maybe NominalDiffTime)`; `defaultTimerWorkerOptions` sets `Just 300` (on by default — see Decision Log). In `runTimerWorkerWith`, before the gauges and claim, run `for_ (options ^. #requeueStuckAfter) $ \ttl -> do n <- requeueStuckTimers ttl now; recordTimerRequeued metrics (fromIntegral n)`. Update `for_ fired (markTimerFired ...)` for the new `Bool` (ignore the value; the haddock explains). Rewrite the false documentation: the module header (~8–10), the `Firing` haddock in Schema.hs (~54–55), and the `runTimerWorkerWith` paragraph about `fire` returning `Nothing` — all must describe the TTL-based requeue, including the duplicate-fire window (a fire that takes longer than `requeueStuckAfter` will be re-fired; `fire` actions must be idempotent, which they already must be under at-least-once).

`keiro/src/Keiro/Telemetry.hs`: add `timerRequeued :: Counter Int64`, name `keiro.timer.requeued`, unit `{timer}`, description "Timers moved from firing back to scheduled after a stale claim."

Tests (in `describe "Keiro.Timer"`, reusing `counterTimerRequest` / `dueTimerTime` helpers; note the timer claim stamps `updated_at` from the *database* clock, so these tests use the future-`now` variant of the crash-window pattern): (1) "re-fires a timer stranded by a crashed worker (crash window: claim → mark)": schedule a due timer; `claimDueTimer dueTimerTime` and do nothing (simulated crash); run `runTimerWorkerWith` with default options and `now = addUTCTime 400 realNow` and a fire that returns an event id; assert the worker returned the timer and a `lookupTimer`-equivalent (`findStuckTimers` returning empty plus the claim returning `Nothing` on a further pass) shows it `Fired` exactly once; (2) "does not requeue a fresh firing row": claim, then run a pass with `now` only seconds later and `requeueStuckAfter = Just 300`; assert the fire callback never ran; (3) "requeueStuckAfter = Nothing preserves the historical behavior": stranded row stays `Firing` after a pass; (4) "markTimerFired does not resurrect a dead timer" (M7): claim, `deadLetterTimer`, then `markTimerFired` returns `False` and the status stays `Dead`.

### Milestone 6 — Shard worker resilience (M2, M3, M4, M5, shard-count check)

Scope: a transient database error degrades to "no rebalance this tick"; a dead reader is restarted; shutdown releases leases immediately; the zombie window is documented; a misconfigured `shardCount` refuses to start.

`keiro/src/Keiro/Subscription/Shard/Worker.hs`:

- Add an error surface: `data ShardWorkerError = ShardSnapshotFailed !Text | ShardAcquireFailed !Text | ShardReaderDied !Int !Text | ShardEnsureFailed !Text` (derive `Eq, Show`), and a new field `onShardError :: !(Maybe (ShardWorkerError -> IO ()))` on `ShardedWorkerOptions` (default `Nothing` in `defaultShardedWorkerOptions`; the haddock recommends wiring it to the application logger).
- M2: in `reconcileShardsOnce`, pattern-match the two `runStoreIO` results instead of `either (const …) id`. Snapshot `Left e`: report `ShardSnapshotFailed (Text.pack (show e))` and fall back to estimating live workers from self only (the claim self-corrects next pass). Acquire `Left e`: report `ShardAcquireFailed …`, then **return the previous owned set unchanged** (`Map.keysSet current` from the readers ref) without starting or stopping anything — a failed renew is not a lost lease; ownership is only truly lost when a competitor claims after TTL expiry, and the worker discovers that on the next successful pass. To make this branch unit-testable without fault injection, extract the decision into a small pure helper, e.g. `acquireOutcome :: Set Int -> Either Text (Set Int) -> (Set Int, Maybe ShardWorkerError)`, and have `reconcileShardsOnce` use it; the pure function gets direct hspec examples.
- M3: replace the bare `forkIO` in `startReader` with supervision: give `RunningReader` an `IORef Bool` "stopping intentionally" flag; `stopReader` sets it before `cancelAction >> killThread`; fork the drain with `forkFinally`, and in the completion handler, when the flag is unset (the thread died on its own — handler exception or stream termination), remove the bucket from the readers map and report `ShardReaderDied bucket reason`. The bucket is still in the owned set, so the next reconcile pass's `toStart` computation restarts the reader; the kiroku per-member checkpoint means no event is skipped.
- M4: in `runShardedSubscriptionGroup`, replace ``loop lease readers `finally` stopAll readers`` with a cleanup that stops every reader *and then* best-effort relinquishes the buckets it was running: read the readers ref, `stopAll`, then `_ <- runStoreIO store (relinquish lease (Map.keysSet current))` (ignore the `Either`; the leases expire by TTL anyway if the database is unreachable during shutdown). Update the module and function haddocks, which currently describe killing the loop thread as "simulating a crash" — after this change a killed loop thread performs a *graceful* shutdown, and a real crash (SIGKILL) remains covered by lease expiry.
- M5 (documentation): extend the module-header at-least-once paragraph (~40–42): a zombie worker that misses renewals past `leaseTtl` may keep reading a bucket concurrently with the new owner until its next reconcile pass notices; both workers then write the same kiroku per-member checkpoint, and the laggard can *regress* it, enlarging the redelivery window. Handlers must therefore be idempotent keyed on `eventId` (already required); a `lease_generation` fencing counter that would close this window is recorded as future work, not built here.

`keiro/src/Keiro/Subscription/Shard.hs` / `Shard/Schema.hs` (shard-count guard, the shard half of L5): add a read of the existing rows' `shard_count` (e.g. `listShardCounts :: SubscriptionName -> Tx.Transaction [(Int, Int)]` returning `(shard_count, row count)` groups), and make `ensureShards` validate after `ensureShardRows`: if any existing row's `shard_count` differs from the configured `shardCount`, throw a typed exception `ShardCountMismatch { subscriptionName :: Text, configured :: Int, found :: [Int] }` (an `Exception` instance, thrown with `Effectful.Exception.throwIO`) so a misconfigured replica refuses to start instead of silently double-reading or skipping streams. Document on `ShardedWorkerOptions.shardCount` that changing `N` requires stopping all workers and truncating the subscription's shard rows (operator procedure in the haddock).

Tests: (1) in `describe "Shard lease"`: "ensureShards rejects a shardCount mismatch" — `ensureShards` with N=4, then a second `ShardLease` with N=6 must throw `ShardCountMismatch` (use `shouldThrow` with a selector); (2) pure examples for `acquireOutcome` (Left keeps the previous set and yields an error; Right adopts the new set); (3) in `describe "Sharded subscription drain and failover"`: "a killed worker relinquishes its leases immediately" — start one worker with `leaseTtl = 30` (deliberately long), wait until it owns all buckets (`waitShardsBalanced`-style polling on `listShardOwnership`), `killThread` it, then within a couple of seconds assert every `owner_worker_id` is `NULL` — impossible before this fix without waiting out the 30 s TTL; (4) "a reader killed by a handler exception is restarted and the category still drains" — handler throws on the first delivery of each event id for one marker stream (IORef set of already-thrown ids), which kills the drain thread mid-run; assert the seeded category still fully drains within the timeout (reader restart + kiroku checkpoint redelivery), reusing the `seedOrders` / `waitUntilSinkCount` helpers around line 3078.

### Milestone 7 — Construction-time config validation (L5, L4)

Scope: invalid worker configuration fails at construction with a typed error instead of misbehaving at runtime. This milestone implements EP-4's half of the config-validation convention shared with `docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md`: `mkX` validators returning `Either <Thing>ConfigError <Thing>`, raw constructors still exported but documented as unvalidated (mirroring `mkEventStream` in keiro-core).

- `keiro/src/Keiro/Outbox/Types.hs`: `data OutboxPublishConfigError` (e.g. `OutboxBatchSizeNotPositive Int`, `OutboxMaxAttemptsNotPositive Int`, `OutboxPublishingTimeoutNotPositive NominalDiffTime`, `OutboxBackoffInvalid Text`) and `mkOutboxPublishOptions :: OutboxPublishOptions -> Either OutboxPublishConfigError OutboxPublishOptions` checking `batchSize >= 1`, `maxAttempts >= 1`, `publishingTimeout > 0`, `ConstantBackoff d → d >= 0`, `ExponentialBackoff o → initial o > 0 && multiplier o >= 1 && maxDelay o >= initial o`.
- `keiro/src/Keiro/Timer.hs`: `data TimerWorkerConfigError` and `mkTimerWorkerOptions` checking `maxAttempts = Just n → n >= 0` and `requeueStuckAfter = Just t → t > 0`.
- `keiro/src/Keiro/Subscription/Shard/Worker.hs`: `data ShardedWorkerConfigError` and `mkShardedWorkerOptions` checking `shardCount >= 1`, `leaseTtl > 0`, `renewInterval > 0`, `leaseTtl > renewInterval` (a TTL at or under the renew interval guarantees spurious lease loss), `batchSize >= 1`, `bufferSize >= 1`. (The cross-replica `shardCount` change is the runtime check from Milestone 6; say so in the haddock.)
- `keiro/src/Keiro/Outbox.hs` (L4): `data IntegrationProducerConfigError = InvalidMessageIdPrefix Text Text` and `mkIntegrationProducer :: IntegrationProducer e -> Either IntegrationProducerConfigError (IntegrationProducer e)` validating `messageIdPrefix` with `Data.TypeID.checkPrefix` (from the already-depended-on `mmzk-typeid`; `Nothing` means valid). Haddock on the raw `IntegrationProducer` warns that an invalid prefix makes `mintIntegrationEvent` throw a `TypeIDError` at first use.

Tests: pure hspec examples per validator — defaults validate (`mkOutboxPublishOptions defaultPublishOptions` is `Right`), and one representative `Left` per error constructor (e.g. `batchSize = 0`, `leaseTtl = 5, renewInterval = 10`, `messageIdPrefix = "Bad-Prefix"`).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless noted. The project builds inside its nix dev shell; if `cabal` is not on PATH, enter the shell first (`nix develop`).

1. Milestone 1: generate and fill the migration, pin the seven older migrations, touch the embed comment (exact commands and SQL in the milestone). Verify:

   ```bash
   cabal test keiro-migrations-test
   cabal test keiro-test
   ```

   Both must end with `Test suite ...: PASS`. A failure mentioning a missing column/index means the embed did not recompile — touch the comment in `keiro-migrations/src/Keiro/Migrations.hs` again or `cabal clean` the package.

2. Milestones 2–7, in order (each is self-contained; 4, 5, 6 are mutually independent and may be reordered): edit the files exactly as described in Plan of Work, adding the listed tests to `keiro/test/Main.hs` inside the matching `describe` block. After each milestone:

   ```bash
   cabal build keiro
   cabal test keiro-test --test-show-details=direct
   ```

   Expected tail of a passing run (counts will grow as milestones land):

   ```text
   Finished in ...s
   N examples, 0 failures
   Test suite keiro-test: PASS
   ```

3. While iterating on a single new example, filter with hspec's match flag to avoid the full suite:

   ```bash
   cabal test keiro-test --test-show-details=direct --test-options='--match "reclaims a row stranded"'
   ```

4. After Milestone 7, run the full gate and update the living sections of this plan plus the EP-4 checkboxes in `docs/masterplans/9-keiro-production-readiness-hardening.md`:

   ```bash
   cabal build all
   cabal test keiro-test
   cabal test keiro-migrations-test
   cabal test jitsurei-test
   ```

   (`jitsurei-test` guards the example service against any unintended API ripples; this plan's API changes — `markOutboxSent`/`markTimerFired` returning `Bool`, `parseStatus`/`parseInboxStatus` returning `Either`, new option fields — may require mechanical call-site updates there; make them.)

5. Commit per milestone with conventional-commit messages, e.g.:

   ```text
   fix(outbox): reclaim rows stranded in publishing; guard markOutboxSent (#70 M2)
   ```


## Validation and Acceptance

Acceptance is behavioral, per milestone, all observable via `cabal test keiro-test`:

- Crash recovery (the headline): the Milestone 2 example "reclaims a row stranded in publishing by a crashed worker" fails on the current codebase (the stranded row is never republished; the pass publishes zero rows) and passes after — that before/after delta *is* the C1 fix. Likewise Milestone 5's "re-fires a timer stranded by a crashed worker" fails today (the worker's second pass returns `Nothing` forever, as the existing test at `keiro/test/Main.hs` ~1390 demonstrates by requiring a manual `requeueStuckTimer`) and passes after.
- Batch survival: with a publish callback that throws, a pass now reports the row as retried and continues; today the same test would propagate the exception out of `publishClaimedOutbox` and leave every claimed row in `publishing`.
- Poison inbox message: three deliveries of an always-throwing message with ceiling 2 produce `InboxHandlerFailed _ 1`, `InboxHandlerFailed _ 2`, `InboxPreviouslyFailed _`, with the handler invoked exactly twice and the row queryable as `failed` with `attemptCount = 2` — today the same sequence invokes the handler three times and leaves no row at all.
- Shard shutdown: after `killThread` on a worker whose `leaseTtl` is 30 s, every `owner_worker_id` for the subscription is `NULL` within ~2 s — today they remain owned until expiry.
- Loud parses: a hand-written `UPDATE keiro_timers SET status = 'garbage'` followed by a claim must surface a decode error from the store, not a `Cancelled` timer (covered by a unit test on the refine function or a DB example — either is acceptable; prefer the pure test).
- Config validation: each `mkX` rejects its representative bad input with the documented `Left`.
- Nothing regresses: every pre-existing example in `keiro-test`, `keiro-migrations-test`, and `jitsurei-test` still passes.


## Idempotence and Recovery

Every step is re-runnable. The migration uses `IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` throughout, so re-applying to a database that already has the objects is a no-op; codd skips applied migrations by name, and the test fixture rebuilds its template from scratch on every suite run, so a broken migration shows up as a suite-wide failure immediately — fix the SQL file and re-run (no rollback needed; nothing real depends on these schemas yet outside tests). Editing the seven older migrations is safe to repeat (the pin is the first statement; do not add it twice — check before editing). If `cabal run keiro-migrate -- new …` is run twice you get two skeleton files; delete the extra one before committing (migrations are embedded by directory, so a stray file would ship). All code edits are ordinary source changes guarded by the test suite; if a milestone goes wrong mid-way, `git checkout -- <file>` restores the previous state and the prior milestones' tests still pass because each milestone is self-contained. The new runtime behaviors are themselves idempotent by design: the reclaim sweeper, the timer requeue, GC, and `relinquish` all use guarded `UPDATE`/`DELETE` statements that affect zero rows on a second run.


## Interfaces and Dependencies

No new package dependencies: everything uses libraries `keiro` already depends on (`hasql` for `D.refine`/`D.rowsAffected`, `effectful-core` for `Effectful.Exception.trySync`/`throwIO`, `mmzk-typeid` for `checkPrefix`, `hs-opentelemetry-api` for the new counters). No new modules; every addition lands in an existing exposed module. The signatures that must exist at completion (all re-exported through the subsystem's public module where a `module ... .Types`/schema re-export pattern already exists):

```haskell
-- Keiro.Outbox.Schema (re-exported from Keiro.Outbox)
requeueStuckOutbox  :: (Store :> es) => Int -> NominalDiffTime -> UTCTime -> Eff es (Int, Int)
garbageCollectSent  :: (Store :> es) => NominalDiffTime -> UTCTime -> Eff es Int
markOutboxSent      :: (Store :> es) => OutboxId -> UTCTime -> Eff es Bool        -- was Eff es ()

-- Keiro.Outbox.Types
-- OutboxPublishOptions gains: publishingTimeout :: !NominalDiffTime  (default 300)
parseStatus :: Text -> Either Text OutboxStatus                                    -- was total fallback
mkOutboxPublishOptions :: OutboxPublishOptions -> Either OutboxPublishConfigError OutboxPublishOptions

-- Keiro.Outbox
mkIntegrationProducer :: IntegrationProducer e -> Either IntegrationProducerConfigError (IntegrationProducer e)

-- Keiro.Inbox (newly re-exported: markFailedTx)
runInboxTransactionWithRetries ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics -> Int -> InboxDedupePolicy -> IntegrationEvent ->
    Maybe KafkaDeliveryRef -> (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))
-- InboxResult gains: InboxHandlerFailed !Text !Int
-- InboxRow gains: attemptCount :: !Int
parseInboxStatus :: Text -> Either Text InboxStatus

-- Keiro.Inbox.Schema
recordFailedAttemptTx :: Text -> Text -> IntegrationEvent -> Maybe KafkaDeliveryRef -> Text -> UTCTime -> Tx.Transaction Int

-- Keiro.Timer.Schema (re-exported from Keiro.Timer)
requeueStuckTimers :: (Store :> es) => NominalDiffTime -> UTCTime -> Eff es Int
markTimerFired     :: (Store :> es) => TimerId -> EventId -> Eff es Bool           -- was Eff es ()

-- Keiro.Timer
-- TimerWorkerOptions gains: requeueStuckAfter :: !(Maybe NominalDiffTime)  (default Just 300)
mkTimerWorkerOptions :: TimerWorkerOptions -> Either TimerWorkerConfigError TimerWorkerOptions

-- Keiro.Subscription.Shard.Worker
data ShardWorkerError = ShardSnapshotFailed !Text | ShardAcquireFailed !Text
                      | ShardReaderDied !Int !Text | ShardEnsureFailed !Text
-- ShardedWorkerOptions gains: onShardError :: !(Maybe (ShardWorkerError -> IO ()))
mkShardedWorkerOptions :: ShardedWorkerOptions -> Either ShardedWorkerConfigError ShardedWorkerOptions

-- Keiro.Subscription.Shard
-- ensureShards now throws ShardCountMismatch (Exception) on configured/stored N disagreement

-- Keiro.Telemetry (KeiroMetrics gains three Counter Int64 fields)
recordOutboxReclaimed :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()        -- keiro.outbox.reclaimed
recordTimerRequeued   :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()        -- keiro.timer.requeued
recordInboxPoisoned   :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()        -- keiro.inbox.poisoned
```

Cross-plan dependencies: none hard. This plan must keep the timer statement set compatible with the `fire_at`-preserving re-arm coming in `docs/plans/73-...` (the requeue touches only `status`/`updated_at`, so it is); it shares the `<Thing>ConfigError` naming with `docs/plans/74-...` (whichever lands first sets it — if 74 has already landed, adopt its naming verbatim); it establishes the crash-window test pattern (Milestone 2) that `docs/plans/71-...`, `72-...`, and `73-...` reuse; and it leaves the `occurred-at` Kafka header strictly to `docs/plans/68-...`.
