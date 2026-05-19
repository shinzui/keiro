---
id: 23
slug: add-a-shibuya-inbox-adapter-for-two-stage-integration-event-processing
title: "Add a Shibuya inbox adapter for two-stage integration-event processing"
kind: exec-plan
created_at: 2026-05-19T14:11:52Z
intention: "intention_01ks08ez50edkrn5atc177emr0"
master_plan: "docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md"
status: reverted
---

# Add a Shibuya inbox adapter for two-stage integration-event processing

> **Status: implemented, then reverted (2026-05-19).** The full
> implementation was built and tested across five commits, then
> reverted as a deliberate design decision. The original commits
> remain in `git log` for future reference — see Outcomes &
> Retrospective for hashes and the rationale for backing out. This
> file preserves the design intent and the lessons learned so a
> future driver can decide whether to revive, redesign, or drop
> the idea.


## Purpose / Big Picture

Today, the keiro inbox is a **dedup ledger embedded in a single
Postgres transaction**. A consumer calls
`Keiro.Inbox.runInboxTransaction`, which inserts a `keiro_inbox` row,
runs the caller's handler as a `Hasql.Transaction.Transaction`, and
marks the row `completed` — all atomically. The inbox is not a queue
you can poll; it is an inline guard.

This plan proposed adding a second, *optional* mode: a **Shibuya
`Adapter` that drains the inbox as a durable queue**. A service would
run two adapters under one `Shibuya.App.runApp`:

1. A **write side** built on `shibuya-kafka-adapter` whose handler
   persists incoming Kafka records as `pending` inbox rows and acks
   the Kafka offset.
2. A **work side** built on `Keiro.Inbox.Adapter` (new) that polls
   `keiro_inbox` for claimable rows under `FOR UPDATE SKIP LOCKED`,
   wraps each as a Shibuya `Ingested es IntegrationEvent`, and
   translates the returned `AckDecision` into inbox state
   transitions.

The motivation:

* Decouple handler latency from the Kafka consumer's critical path.
* Let multiple producers (sagas, HTTP shims, backfills) write
  `pending` rows into one inbox.
* Compose receive and work stages under one Shibuya supervisor.


## Progress

All milestones were implemented and tested, then reverted in a single
revert commit on 2026-05-19. The originals are kept in `git log` for
future archeology.

- [x] Milestone 1: schema (new columns + partial claim index) and
  types (`InboxPending`/`InboxDead`/`InboxClaimOptions`/etc.).
  *Implemented in `35422b6`, reverted.*
- [x] Milestone 2: storage primitives —
  `enqueueInbox`/`enqueueInboxTx`, `claimInboxBatchTx` with fused
  visibility-timeout reclaim, `markInboxFailedTx`/`markInboxDeadTx`/
  `releaseInboxClaimTx`. *Implemented in `0f69e4c`, reverted.*
- [x] Milestone 3: `Keiro.Inbox.Adapter` (Shibuya adapter +
  `mkTransactionalInboxHandler`). *Implemented in `8345140`,
  reverted.*
- [x] Milestone 4: 13 new tests (6 storage + 7 adapter) plus a
  dual-adapter coexistence test. *Implemented in `277c6ca`,
  reverted.*
- [x] Milestone 5: guide updates documenting inline vs drained paths
  with a same-process topology diagram. *Implemented in `5219561`,
  reverted.*

Total at peak: 79/79 keiro-test + 2/2 keiro-migrations-test green.
After revert: 65 + 1, matching the pre-EP-23 baseline.


## Surprises & Discoveries

- 2026-05-19: `codd`'s `embedDir`-based migration loader does not
  invalidate the Template Haskell splice when a new SQL file is
  added under `sql-migrations/`. Cabal sees no `.hs` file change,
  reuses the cached `Keiro.Migrations.o`, and
  `runAllKeiroMigrations` quietly reports "N found" instead of
  "N+1". Workaround: delete the cached `.o` (or `touch` the module).
  Worth surfacing in the migrations README regardless of whether
  EP-23 ever lands.

- 2026-05-19: Hasql's `runTransaction` does not surface
  `Tx.condemn` status to the caller — a condemned transaction
  returns the body's value just like a committed one. This bit
  `mkTransactionalInboxHandler`: without an explicit
  `Tx.Transaction (Either Text a)` shape the wrapper could not
  detect "user rolled back" and would let the framework's ack-side
  `markCompletedTx` flip a rolled-back row to `completed`. Real
  design smell — it surfaces because the drained-path runs
  `markCompletedTx` in a separate transaction from the user's work.

- 2026-05-19: `shibuya-kafka-adapter`'s `consumerRecordToEnvelope`
  only preserves `traceparent`/`tracestate` headers and drops the
  rest. The keiro inbox needs the full keiro-* header set to
  reconstruct an `IntegrationEvent`. Both the inline path and any
  future drained path are equally blocked by this — using
  `shibuya-kafka-adapter` for a keiro inbox consumer is not turn-
  key today regardless of which inbox shape we ship. Documented in
  `docs/guides/integration-events-with-kafka.md` as part of the
  revert work.


## Decision Log

- Decision: ship **both** the inline EP-21 path and the drained
  EP-23 path as supported alternatives (per the original scoping
  conversation).
  Rationale: each addresses a regime the other cannot — inline for
  one-tx atomicity, drained for handler latency / multi-writer
  inbox / shared supervision. Was implemented; later reverted on
  the YAGNI grounds in Outcomes & Retrospective.
  Date: 2026-05-19.

- Decision: schema additions go through a new codd migration
  (`2026-05-19-00-00-00-keiro-inbox-worker.sql`) rather than
  rewriting `2026-05-17-02-00-00-keiro-inbox.sql`.
  Rationale: codd migrations are append-only. Production
  deployments must be able to upgrade in place. Reverted with the
  rest; if revived, the same shape applies.
  Date: 2026-05-19.

- Decision: `mkTransactionalInboxHandler` takes
  `Tx.Transaction (Either Text a)` instead of `Tx.Transaction a`.
  Rationale: `runTransaction` does not surface `Tx.condemn` status
  to the caller, so the wrapper cannot distinguish user-committed
  from user-condemned via the return value alone. The `Either`
  contract makes the rollback signal explicit. This was a real
  design smell — see Outcomes for why it factored into the revert.
  Date: 2026-05-19.

- Decision: Revert the entire EP-23 implementation rather than
  carry it as additive-but-unused capability.
  Rationale: see Outcomes & Retrospective below. The short
  version: no concrete consumer needed the drained path; the
  inline path is correct; the schema additions are a one-way door;
  and the `Either Text a` workaround revealed that the abstraction
  was leaky.
  Date: 2026-05-19.


## Outcomes & Retrospective

The implementation worked. All 14 new tests passed alongside the
existing 65, the migration was forward-only and reversible (additive
columns + partial index), and the guide documented when to pick each
path. So why revert?

**1. YAGNI.** The plan reasons about gaps that are hypothetical
("handlers that need HTTP / S3 / cross-DB writes", "sagas writing
inbox receipts", "shared Shibuya supervision") without a specific
near-term consumer that needs them. The system prompt is explicit:
don't design for hypothetical future requirements. The inline path
covers every consumer we have today. When a concrete driver shows
up, we'll have better signal on what the right abstraction is — and
it may not look like this adapter at all.

**2. The `Either Text a` workaround is a design smell.** Hasql's
`runTransaction` does not surface `Tx.condemn`, so
`mkTransactionalInboxHandler` had to invent an explicit rollback
channel via `Tx.Transaction (Either Text a)`. The inline path
doesn't have this problem because it genuinely *is* one transaction.
The wrapper's existence is essentially admitting "the drained path
can't match the inline path's atomicity, so here's a workaround."
That's a sign the layering is wrong, not that the workaround is
clever.

**3. "Atomicity restored" was overstated.** Even with the wrapper,
the framework's ack-side `markCompletedTx` still runs in a separate
transaction; the wrapper only makes it idempotent. The strict EP-21
guarantee (one tx, no observable intermediate state) doesn't survive
the round-trip. A user reading the doc would believe the drained
path with the wrapper was atomically equivalent to the inline path.
It isn't.

**4. The throughput cost is real for callers who opt in.** Two
transactions per message instead of one, plus a polling loop with
sleeps, plus an extra row write on the Kafka side (`pending` →
`completed` instead of straight to `completed`). The inline path is
strictly faster for the cases it covers.

**5. One-way doors deserve a real driver.** The schema additions
(three columns + a partial index) are forward-only. Once shipped,
they sit in `keiro_inbox` whether anyone uses them or not. Better
to wait for a concrete driver than to leave the cruft behind.

### What we keep from this attempt

* The `Tx.condemn` non-observability discovery is recorded in
  `MasterPlan 3`'s Surprises & Discoveries.
* The `shibuya-kafka-adapter` header-preservation gap is now
  documented in `docs/guides/integration-events-with-kafka.md`
  honestly — that was a real find independent of the inbox-adapter
  question.
* The codd `embedDir` Template Haskell recompile surprise is also
  worth surfacing in the migrations package README.
* This file. If a future driver appears (a saga that needs to
  write integration receipts, a handler that must call HTTP), this
  retrospective tells them what to reconsider before reaching for
  the same design.

### How to revive (if a future driver justifies it)

The five original commits are preserved in `git log`:

* `35422b6` — schema and types
* `0f69e4c` — enqueue/claim/ack APIs
* `8345140` — Shibuya adapter and transactional wrapper
* `277c6ca` — adapter tests and dual-adapter coexistence test
* `5219561` — guide and masterplan documentation

To re-apply: `git revert <revert-commit>` (i.e., revert the revert).
Then revisit the four problems above with the concrete driver in
hand — in particular, decide whether the right shape is still a
Shibuya `Adapter` over `keiro_inbox`, or whether the driver wants
something else entirely (a saga primitive that owns its own
durability, a dedicated worker pool with different ack semantics,
etc.).


## Interfaces and Dependencies

Documented for archaeology. None of these are present in the
working tree after the revert.

**New module that was added and removed**: `Keiro.Inbox.Adapter`
exporting `InboxAdapterConfig`, `defaultInboxAdapterConfig`,
`inboxAdapter`, `mkTransactionalInboxHandler`, `InboxAckOutcome`.

**Public functions added to `Keiro.Inbox` and removed**:
`enqueueInbox`, `enqueueInboxTx`, `listInboxByStatus`.

**Types added to `Keiro.Inbox.Types` and removed**:
`InboxEnqueueOutcome`, `InboxAckOutcome`, `InboxClaimOptions`,
`defaultInboxClaimOptions`, plus two new `InboxStatus`
constructors (`InboxPending`, `InboxDead`). `BackoffSchedule` was
re-exported from `Keiro.Inbox.Types`.

**Storage primitives added to `Keiro.Inbox.Schema` and removed**:
`enqueuePendingTx`, `claimInboxBatchTx`, `markInboxFailedTx`,
`markInboxDeadTx`, `releaseInboxClaimTx`.

**Schema additions in `keiro_inbox` and removed**: `attempt_count
INTEGER NOT NULL DEFAULT 0`, `next_attempt_at TIMESTAMPTZ NOT NULL
DEFAULT now()`, `claimed_at TIMESTAMPTZ`, plus a partial index on
`(next_attempt_at, source, dedupe_key)` filtered to non-terminal
statuses. The migration file
`keiro-migrations/sql-migrations/2026-05-19-00-00-00-keiro-inbox-worker.sql`
held the forward-only `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`
statements; it was reverted too.

**Library dependencies added and removed** in `keiro.cabal`:
`stm >= 2.5`, `unordered-containers >= 0.2`. The test suite also
gained `shibuya-core`, `streamly`, and `streamly-core` build-deps
which were removed.
