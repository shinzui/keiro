---
id: 20
slug: harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review
title: "Harden the kiroku event store and subscription machinery surfaced by the 2026-07 kiroku review"
kind: master-plan
created_at: 2026-07-23T04:18:29Z
---

# Harden the kiroku event store and subscription machinery surfaced by the 2026-07 kiroku review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

kiroku (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`) is the PostgreSQL event store every keiro service persists into. It had only indirect review coverage — May 2026 design surveys, the June 2026 fix wave (`DuplicateEvent` mapping, `eventExistsInStream`), MasterPlan-13-era migration hardening, and MasterPlan 14's verification of keiro's usage "down to kiroku's actual SQL" — but never a dedicated full review. The July 2026 kiroku review deep-read the write path (SQL.hs, Transaction.hs, Effect.hs, Error.hs), the read/subscription machinery (worker FSM, event publisher, consumer groups, notifications), and the shibuya-kiroku-adapter, followed by adversarial verification of every serious finding against PostgreSQL semantics and keiro's consumers. The write path's core is certified sound — single-statement append atomicity, OCC under ReadCommitted, structurally-forced lock ordering, gap-free global positions, the DuplicateEvent contract robust even against unspecified CTE execution order — as are the subscription catch-up→live seams, NOTIFY loss tolerance, checkpoint monotonicity, and backpressure paths.

Six confirmed defects remain, two severe. `hardDeleteStream` never locks the stream row before its multi-statement delete, so an append committing inside a specific snapshot window leaves acknowledged events as permanent, unpurgeable orphans — invisible to per-stream and category readers, still visible in `$all` — and keiro's workflow GC calls `hardDeleteStream` in a loop, exercising this race continuously (KRW-1, verified interleaving-by-interleaving). The documented consumer-group resize procedure permanently skips events, because checkpoints are single global cursors per member and nothing equalizes them when streams re-bucket; the schema's `consumer_group_size` column is never written or read (KRS-1 — keiro's shard workers fail loudly on a `shardCount` change rather than losing data, but no safe resize path exists at all, and a grow attempt leaves mixed rows blocking both configurations). Further: a second consecutive transient conflict (40001/40P01) maps to `UnexpectedServerError`, which keiro's process-manager and router workers classify as fatal and halt on — inverting the documented retry contract (KRW-2); a live subscription that hits one transient fetch error rewinds to its live-entry cursor and re-delivers everything since (KRS-2); `batchSize` is unvalidated, and zero silently stalls group subscriptions or permanently loses the catch-up gap on the AllStreams path (KRS-6); checkpoints are not bound to their subscription target (KRS-4); a throwing `decodeHook` silently wedges the event publisher (KRS-5); and the bare `kirokuAdapter` path lets an unfinalized ack block a subscription forever while it reports `Live` (KRS-3).

After this initiative: hard delete is safe under concurrency; consumer groups can be resized without loss via a supported procedure, and misconfigurations are refused loudly; a transient conflict is always classified retryable; a live reconnect resumes from real progress; subscription misconfiguration fails at subscribe time; and the adapter cannot be wedged by a throwing handler. In scope: all confirmed findings, in the kiroku repo (plus the small keiro-side shard-resize seam), each with tests including the resize and reconnect-after-progress cases the suites lack. Out of scope: the `$all` append serialization ceiling (accepted); prefix subscriptions and other backlog features; `HandlerInTransaction` (its at-least-once consequence is documented and unchanged — only the adapter's ack guard and retry-policy exposure are in scope).


## Decomposition Strategy

Four child plans by subsystem seam. EP-1 (plan 125) owns the write-path fixes: the `FOR UPDATE` lock opening the hard-delete transaction plus a concurrent-append test, and the transient-conflict classification (new retryable constructor or 40001/40P01 mapping) with the `runTransactionNoRetry` haddock correction — one plan because both change Effect.hs/Error.hs and their tests overlap. EP-2 (plan 126) owns consumer-group resize: persist and validate `consumer_group_size`, a supported resize operation (resume from the minimum checkpoint across members, or an explicit equalization command), the documentation rewrite, and the keiro-side seam (a safe `shardCount` change path; fixing the grow-commits-mixed-rows wart). EP-3 (plan 127) owns subscription-worker robustness: carry the live cursor on the error exit, validate `batchSize >= 1` at subscribe, bind checkpoints to their target via the existing `stream_name` column, and contain `decodeHook` failures. EP-4 (plan 128) owns the adapter: default `guardKirokuHandler` wrapping (or a pending-reply watchdog) and exposing `retryPolicy` on the adapter configs.

Alternatives considered. Splitting KRW-1 and KRW-2 was rejected: both are small, adjacent, and share test scaffolding. Folding EP-4 into EP-3 was rejected: the adapter is a separate package with its own release. A keiro-side-only fix for KRW-2 (classifying `UnexpectedServerError "40001"/"40P01"` as transient in keiro) was rejected as treating the symptom; the store must classify its own errors truthfully, though EP-1 records the keiro classifier interaction.

ADR context: keiro's `docs/adr/` contains only 0001 (pgmq telemetry — not relevant); the kiroku repo has `docs/adr/0002-static-hash-partitioned-consumer-groups.md`, which EP-2 must update (its resize claims are wrong). Candidate ADRs: the resize contract, and the hard-delete concurrency contract.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Lock hard-delete against concurrent appends and classify transient conflicts as retryable | docs/plans/125-lock-hard-delete-against-concurrent-appends-and-classify-transient-conflicts-as-retryable.md | None | None | Not Started |
| 2 | Make consumer-group resize safe and persist the group size | docs/plans/126-make-consumer-group-resize-safe-and-persist-the-group-size.md | None | None | Not Started |
| 3 | Fix the live-reconnect rewind and validate subscription configuration | docs/plans/127-fix-the-live-reconnect-rewind-and-validate-subscription-configuration.md | None | None | Not Started |
| 4 | Guard the kiroku adapter ack path and expose the retry policy | docs/plans/128-guard-the-kiroku-adapter-ack-path-and-expose-the-retry-policy.md | None | None | Not Started |


## Dependency Graph

No hard dependencies; all four can proceed in parallel. EP-2, EP-3 both touch `Subscription/Worker.hs` and its tests — coordinate merge order only (disjoint functions: checkpoint load/resize logic vs live-loop exit mapping and subscribe validation). All kiroku-repo plans share one release train: whichever lands last cuts the version keiro re-pins (kiroku commits use that repo's conventions; keiro consumes via Hackage/pin bump recorded in whichever keiro-side plan lands the EP-2 seam).


## Integration Points

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`: EP-2 (checkpoint load/resize) and EP-3 (exit mapping, validation) — disjoint functions, shared file and test module; EP-2 owns any schema change to the `subscriptions` table (writing `consumer_group_size` and, for EP-3's KRS-4 fix, the `stream_name` binding column write lands in EP-3 but the migration file, if one is needed beyond backfilled writes, is owned by whichever lands first — record the number claimed in this section when known).

`kiroku-store/src/Kiroku/Store/Error.hs`: EP-1 owns all taxonomy changes; EP-4 consumes (the adapter maps store errors) but must not modify.

keiro-side: EP-2's shard-resize seam touches `keiro/src/Keiro/Subscription/Shard.hs` — no other wave-2 plan touches keiro's runtime; coordinate with any in-flight MasterPlan 16-19 implementation on merge order only.

Cross-plan decision for ADR promotion: the store's error taxonomy contract (which SQLSTATEs are retryable and on which constructor they surface) — EP-1 defines it; keiro's classifiers and the adapter consume it.


## Progress

- [ ] EP-1: Hard-delete opens with `FOR UPDATE`; concurrent-append orphan test passes (window 2 now aborts or purges cleanly).
- [ ] EP-1: 40001/40P01 classified retryable on every surface; haddocks corrected; keiro PM/router halt inversion regression-tested.
- [ ] EP-2: `consumer_group_size` persisted and validated; supported resize procedure implemented and documented; kiroku ADR 0002 corrected.
- [ ] EP-2: keiro shard-count change path safe; mixed-rows grow wart fixed.
- [ ] EP-3: Live-reconnect resumes from `posRef`; reconnect-after-progress test passes.
- [ ] EP-3: `batchSize >= 1` validated; checkpoint bound to target; `decodeHook` failures contained loudly.
- [ ] EP-4: Adapter ack path guarded by default; `retryPolicy` exposed on both adapter configs.


## Surprises & Discoveries

- Verification (2026-07-23): keiro's workflow GC (`keiro/src/Keiro/Workflow/Gc.hs:56-73`) calls `hardDeleteStream` in a loop, so KRW-1's race is exercised continuously by the runtime, not only by operator deletes.
- Verification (2026-07-23): KRW-2 is amplified, not neutralized, by keiro — `isTransientStoreError` maps `UnexpectedServerError` to non-transient, so a doubled deadlock halts PM/router workers with `HaltFatal`; only the workflow resume worker (all StoreErrors transient) is immune.
- Verification (2026-07-23): keiro shard deployments are guarded against accidental resize by `ShardCountMismatch` (loud startup crash), but there is no safe resize path at all, and a grow attempt commits mixed `shard_count` rows that block workers of both configurations until manual cleanup.
- Plan authoring (2026-07-23), affects EP-4: the adapter doc's claim that a handler exception leaves the ack unfinalized contradicts shibuya-core 0.8.0.1's always-finalize guarantee (`processOne` substitutes `AckRetry (RetryDelay 0)` and always runs `finalizeWithRetry`; the skip-finalization behavior was real on 0.7.1.0 per that module's own comment). EP-4 (docs/plans/128) therefore opens with a reproduce-or-refute milestone; its deliverables stand either way.
- Plan authoring (2026-07-23): release facts pinned — kiroku-store 0.3.1.0 → 0.4.0.0 (new `StoreError` constructor is PVP-major; keiro bounds bump to `>=0.4 && <0.5`), adapter 0.4.0.0 → 0.5.0.0; kiroku migration 0009 claimed by EP-3 (EP-2 needs none — both columns already exist).


## Decision Log

- Decision: Fix KRW-2 in kiroku (truthful classification), not in keiro's classifiers.
  Rationale: The store must not report transient conditions on a constructor documented as non-retryable; patching every consumer's classifier treats the symptom and misses future consumers.
  Date: 2026-07-23

- Decision: The resize fix persists and validates `consumer_group_size` and ships a supported resize operation rather than making re-bucketing transparently safe.
  Rationale: Transparent safety requires per-stream checkpoints (a redesign the accepted ADR 0002 explicitly traded away); refusing unsafe configurations plus a documented equalization procedure closes the loss without the redesign.
  Date: 2026-07-23

- Decision: `HandlerInTransaction` remains out of scope.
  Rationale: Verified unchanged since May 2026 — its absence yields at-least-once (duplicates, never loss), which is the documented contract; closing it is a feature, not a defect fix.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)
