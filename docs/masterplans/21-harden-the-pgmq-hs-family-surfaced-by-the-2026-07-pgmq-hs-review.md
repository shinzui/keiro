---
id: 21
slug: harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review
title: "Harden the pgmq-hs family surfaced by the 2026-07 pgmq-hs review"
kind: master-plan
created_at: 2026-07-23T04:18:29Z
---

# Harden the pgmq-hs family surfaced by the 2026-07 pgmq-hs review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The pgmq-hs family (`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`: pgmq-core, pgmq-hasql, pgmq-effectful, pgmq-config, pgmq-migration) is the queue library stack under keiro-pgmq and shibuya-pgmq-adapter. The July 2026 keiro-pgmq review covered only the seams keiro exercises; the July 2026 pgmq-hs review deep-read the rest — the full 2,075-line install SQL, every statement/encoder/decoder, both effectful interpreters, and the config reconciler — and its serious findings were verified with live reproductions on a PostgreSQL 18.4 cluster running the repo's actual migration. The library's core is certified sound: full bind parameterization (no injection path), single-statement atomicity of read/pop/archive, decoder fidelity pinned by property tests, byte-identical SQL parity with the upstream pgmq extension, and a faithful traced interpreter.

The confirmed defects are a family of NULL-parameter traps plus notify-machinery fragility, all currently latent (no registered consumer hits them today) but armed for the 10-15-service adoption where teams will call these APIs directly. Live-verified: `pop` with `qty = Nothing` — documented "default 1" — passes SQL NULL to `LIMIT`, which PostgreSQL reads as `LIMIT ALL`, deleting and returning the entire queue in one statement with no visibility-timeout safety net (PGH-1); `read` with `batchSize = Nothing` leases the whole queue the same way, and `readWithPoll` shares the hazard (PGH-3); `ReadMessage.conditional` is silently dead — never encoded, and the `readMessageConditional` its docs point to does not exist, while the comment justifying the 3-arg form was refuted live (PGH-2); `enable_notify_insert` with `throttleMs = Nothing` — documented "pgmq default 250ms" — deterministically fails with a NOT NULL violation (the destroys-existing-trigger half was refuted: statement atomicity rolls the drop back) (PGH-4); and the notify throttle table is UNLOGGED, so a crash/immediate-shutdown recovery truncates it and the insert trigger silently never notifies again until an application-side re-enable — demonstrated with a full live crash cycle (PGH-6). Also confirmed by review: `setVisibilityTimeoutAt` throws on a raced-away row instead of returning `Nothing` (PGH-5); uppercase queue names silently alias two logical queues onto one physical table and break notify, and `FromJSON QueueName` bypasses validation entirely (PGH-7); the reconciler races concurrent replica startups on notify-trigger creation and partitioned re-entry (PGH-8); the documented NOTIFY channel name is wrong on every component (PGH-9); `isTransient` classifies deadlock/serialization SQLSTATEs as permanent (PGH-10); and a NULL message body inserted by any non-Haskell producer poisons every read batch at decode (PGH-11).

After this initiative: no `Maybe` parameter can silently mean "unbounded" or "always fails" — each either defaults as documented via `COALESCE` or becomes non-optional; notify survives crash recovery or is documented as requiring a poll fallback, with the channel contract exported as code; queue names are normalized or rejected consistently across every entry path; transient SQLSTATEs classify as transient; and the new behaviors are pinned by tests including the previously-untested `Nothing` cases. In scope: PGH-1 through PGH-11 in the pgmq-hs repo, one coordinated family release, and the version-bound bumps in keiro-pgmq/shibuya-pgmq-adapter consumers. Out of scope: the previously-filed grouped-read findings (MasterPlan 17 owns them — coordinate the release train); pg_partman retention semantics (MasterPlan 17 EP-3); new queue features.


## Decomposition Strategy

Three child plans by defect family. EP-1 (plan 129) owns the NULL-parameter semantics family (PGH-1, 2, 3, 4, 5): one plan because the fix pattern is uniform (`COALESCE($n, default)` in the statement or a non-`Maybe` field — decide per parameter and record), the false doc comments fall together, and one test module covers all the `Nothing` cases. EP-2 (plan 130) owns notify reliability (PGH-6, 9, 8): make the throttle row survive crashes (logged table, or an upsert/fallback in the trigger), export the channel-name helper and fix the haddock, and serialize the reconciler's notify/partitioned mutations. EP-3 (plan 131) owns input validation and classification (PGH-7, 10, 11): queue-name normalization with a validating `FromJSON`, the `isTransient` SQLSTATE whitelist, and the nullable-body decode decision.

Alternatives considered. One mega-plan was rejected — the three families have disjoint test surfaces (statement semantics vs crash/notify cycles vs pure validation). Folding PGH-8 into EP-3 (it is also "validation") was rejected: its fix is SQL/advisory-lock work in the same functions EP-2 touches.

ADR context: keiro's `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` is tangentially relevant (the family release must not change the traced interpreter's span semantics keiro's ADR pins); no pgmq-hs-repo ADR exists. Candidate ADR: the NULL-parameter contract ("no optional parameter may widen scope") as a library-wide rule.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Fix NULL parameter semantics across pop read and notify statements | docs/plans/129-fix-null-parameter-semantics-across-pop-read-and-notify-statements.md | None | None | Not Started |
| 2 | Make insert notifications survive crashes and document the channel contract | docs/plans/130-make-insert-notifications-survive-crashes-and-document-the-channel-contract.md | None | None | Not Started |
| 3 | Validate queue names and classify transient errors across the pgmq layers | docs/plans/131-validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers.md | None | None | Not Started |


## Dependency Graph

No hard dependencies. All three ship in one pgmq-hs family release; MasterPlan 17's plans 116/118 share the same release train (they add a grouped-read migration and FIFO index). Whichever plan lands first establishes the new pgmq-migration file and version number; the others append. EP-2's trigger change and EP-1's `enable_notify_insert` COALESCE touch the same SQL function — land EP-1's parameter fix first or combine the function's new definition in one migration (record the choice in both Decision Logs).


## Integration Points

`pgmq-migration/migrations/`: EP-1 and EP-2 both re-create SQL functions (new versioned migration files, never edits to `0001-install-v1.11.0.sql`); shared with MasterPlan 17 plans 116/118 — one release train, sequential migration numbers, each plan records the file it claims.

`pgmq-hasql/src/Pgmq/Hasql/Encoders.hs` and `Statements/`: EP-1 owns all encoder/statement changes; EP-3's `FromJSON` change lives in pgmq-core's `Types.hs` — no overlap.

`pgmq-config/src/Pgmq/Config.hs`: EP-1 (throttle passthrough docs), EP-2 (reconciler locking) — EP-2 owns the module; EP-1 only corrects the `Config/Types.hs` doc string.

Consumer version bounds: the final release bumps land in `keiro-pgmq.cabal` and shibuya-pgmq-adapter — the last-landing plan carries them and runs both consumer suites.

Cross-plan decision for ADR promotion: the NULL-parameter contract and the notify-channel contract (exported helper as the single source of truth).


## Progress

- [ ] EP-1: `pop`/`read`/`readWithPoll`/`set_vt`/`enable_notify_insert` NULL semantics fixed (COALESCE or non-Maybe); false doc comments corrected; `Nothing`-case tests pass (live-verified behaviors now impossible).
- [ ] EP-1: `setVisibilityTimeoutAt` returns `Maybe` instead of throwing on a raced row.
- [ ] EP-2: Throttle state survives crash recovery (logged or trigger fallback); live crash-cycle test or documented poll-fallback requirement.
- [ ] EP-2: `notifyChannelName` helper exported; haddock corrected; reconciler mutations advisory-locked; concurrent-startup test passes.
- [ ] EP-3: Queue names normalized/rejected consistently; `FromJSON` validates; uppercase-aliasing test passes.
- [ ] EP-3: `isTransient` whitelists 40001/40P01/55P03/57P01/53xxx; nullable-body decode decision implemented and documented.


## Surprises & Discoveries

- Verification (2026-07-23): all serious findings reproduced live on PostgreSQL 18.4 with the repo's own migration — including the full PGH-6 crash cycle (immediate shutdown truncates the throttle table; clean restart preserves it; notify demonstrably stalls; re-enable heals).
- Verification (2026-07-23): PGH-4's "destroys the existing trigger" half is refuted — the function call is one statement, so the 23502 rolls back the internal trigger drop atomically; both trigger and throttle row verified intact after the failure.
- Verification (2026-07-23): exposure of every finding is currently latent — no registered consumer calls `pop`, passes `Nothing` for the affected parameters, or uses notify. The hardening is for direct-API use by the incoming service fleet.
- Plan authoring (2026-07-23): the shared family release must be 0.5.0.0, not 0.4.x — EP-1's `Maybe Message` result-type change is PVP-major and consumer bounds (`<0.5`, `^>=0.4`) would otherwise silently break solves; MasterPlan 17's plans 116/118 claimed 0.4.1.0/0.4.2.0 for SQL-only changes and are superseded if they land on this train (noted there too).
- Plan authoring (2026-07-23): EP-1 needs no migration — all its fixes are client-side statement text (the `$n` binds exist only client-side; SQL functions use named args), preserving certified upstream SQL parity; the sole server-side NULL guard (`enable_notify_insert` COALESCE-250) folds into EP-2's migration, which re-creates that function anyway (the sanctioned combine option).
- Plan authoring (2026-07-23): PGH-10's exposure is sharper than believed — shibuya-pgmq-adapter calls `isTransient` on every ack/poll retry gate (`Internal.hs:62,515`) and consumes `setVisibilityTimeoutAt`'s result (`Internal.hs:199-206`), so EP-3's classification fix and EP-1's type change both need the adapter-side follow-through EP-3's final milestone carries. Also: `acquire_queue_lock` hashes the raw (non-lowercased) name — a fourth aliasing artifact for EP-3's uppercase rejection.


## Decision Log

- Decision: Fix NULL semantics in the SQL statements (COALESCE) and/or Haskell types per parameter, not by documenting the current behavior.
  Rationale: "Nothing = unbounded destructive operation" is indefensible as a contract regardless of documentation; the live repros show the blast radius.
  Date: 2026-07-23

- Decision: Single coordinated family release shared with MasterPlan 17's pgmq-hs changes.
  Rationale: Four consumer repos re-pin on every family bump; batching avoids serial upgrade churn.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)
