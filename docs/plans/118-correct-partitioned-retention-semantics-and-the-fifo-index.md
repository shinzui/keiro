---
id: 118
slug: correct-partitioned-retention-semantics-and-the-fifo-index
title: "Correct partitioned retention semantics and the FIFO index"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
intention: "intention_01m2b1p3vhe179jtr5qz6ghqks"
master_plan: "docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md"
provenance:
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T13:26:48Z
      mode: "update"
      note: "Validated that MasterPlan 17 was not migrated to the pgmq project; refreshed pgmq 0.6/migration-0007 premises and recorded read_grouped_head"
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T14:36:53Z
      mode: "update"
      note: "Relocated the upstream SQL/doc scope to pgmq-hs MasterPlan 5; rewrote upstream milestones as consumption"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-12T17:28:45Z
      mode: "update"
      note: "Audited local downstream changes and aligned handoffs with client-only ordering, optional additive indexes, and no SQL overrides."
---

# Correct partitioned retention semantics and the FIFO index

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.



**Current cross-repository contract (2026-09-12).** `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts` prohibits overriding extension-owned SQL on both native and extension installs. The ordering work is four outer Haskell-client ORDER BY msg_id clauses, not changed PGMQ function bodies. The index work measures an optional, separately named `q_<queue>_group_lookup_idx`; upstream GIN, helpers and presence reporting remain unchanged. No new FIFO migration or automatic GIN replacement is planned. This supersedes earlier SQL-migration/release assumptions. Existing historical migration bytes remain immutable. Keiro consumer safety and retention policy remain local responsibilities; a sorted result, batch-size clamp or head read does not guarantee successful processing without valid leases and disciplined acknowledgement/side effects.

## Purpose / Big Picture

`keiro-pgmq`'s provisioning surface makes two claims the 2026-07 pgmq review (master plan:
`docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md`)
proved false. First (PGQ-4, HIGH): a partitioned queue's `retentionInterval` reads like a
harmless cleanup knob ("e.g. \"7 days\""), but upstream it configures pg_partman to
permanently *drop whole partitions of the active queue table* once they age past the
interval — processed or not. A consumer outage or backlog longer than the retention
interval silently bulk-deletes unprocessed work, while the package's DLQ documentation
tells operators PGMQ never expires rows on its own. Second (PGQ-5): the "FIFO index" that
`ensureFifoIndex` creates and documents as "the index PGMQ's grouped/ordered reads match
against" is a jsonb GIN index, which by definition serves the `@>`/`?` operator classes —
not the `headers->>'x-pgmq-group'` extraction-equality and GROUP BY that `read_grouped` and
`read_grouped_rr` actually execute. This does not prove every query node is a sequential scan; existing message-ID/visibility
indexes may participate. A useful supplement must be demonstrated by full-query measurement.

After this plan, Keiro documents retention accurately, offers its explicitly scoped
construction-time guardrail, and explains that ordinary FIFO provisioning still creates upstream
GIN. Any measured group-expression index is an optional, independently owned supplement,
installed explicitly by an operator. No upstream function or existing index is replaced.
A sorted client result or an index is not a guarantee of successful FIFO processing.


## Progress

- [ ] M1: `PartitionSpec`/`partitionedProvision`/`QueueKind` haddocks state the drop-unprocessed semantics; partitioned provisioning labeled experimental; `Keiro.PGMQ.Dlq` haddock expiry claim scoped; `mkPartitionSpec` validating constructor added with pure tests.
- [ ] M2: Review supplemental-index measurements and operator lifecycle; record useful or negative results without a migration/version dependency.
- [ ] M3: Correct Keiro provisioning Haddocks and validate supplemental-index coexistence in a disposable fixture, without automatic provisioning or GIN replacement.
- [ ] CHANGELOG entry (keiro-pgmq additive API + docs; the pgmq-hs entry belongs to the upstream plan); ADR distillation pass done (provisioning half of the master plan's FIFO-contract ADR candidate).


## Surprises & Discoveries

The cross-repository audit found clean Keiro state at 14dd9036 and no new FIFO/index source
implementation since 503475fa (only package formatting). `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use` now measures an optional
supplemental index and forbids helper overrides/Gin replacement. Earlier migration names,
release targets and automatic-conversion expectations are superseded. No benchmark or live
partition test was run in this planning audit.


## Decision Log

- Decision: PGQ-4 is fixed by truthful documentation plus a construction-time guardrail
  (`mkPartitionSpec`), and partitioned provisioning is documented as experimental — not
  production-validated — until the pending live test can run. No behavioral change to what
  `create_partitioned` configures upstream.
  Rationale: The dangerous behavior is pg_partman's, configured by pgmq's own
  `create_partitioned` (it sets `retention`, `retention_keep_table = false`,
  `automatic_maintenance = 'on'` on the active queue table — migration SQL lines 1329-1342
  — and the same on the archive table, lines 1396-1409, so even archived audit rows
  expire). Changing those semantics upstream would fork pgmq's documented behavior for all
  consumers; what keiro owes its users is an API that cannot be configured into silent
  message loss *by accident*. The only integration test is permanently pending
  (`keiro-pgmq/test/Main.hs` lines 1095-1099: the suite's PostgreSQL has no pg_partman), so
  "supported for production" cannot honestly be claimed either way — hence the experimental
  label, revisited when a pg_partman-enabled CI database exists.
  Date: 2026-07-23

- Decision: `mkPartitionSpec` validates only what is classifiable from the two opaque
  pg_partman strings: non-empty; both-numeric or both-non-numeric (pgmq derives the
  partition column from whether `partition_interval` casts to an integer — SQL lines
  1223-1236 — so a numeric/non-numeric mix configures an id-partitioned table with an
  interval-typed retention, or vice versa, which pg_partman only rejects later at
  maintenance time); and for the numeric (msg_id-range) kind, retention >= partition
  interval as a conservative Keiro configuration policy, subject to validation against
  pg_partman's actual boundary rules. This does not establish that a smaller retention
  drops a currently filling partition or that the guard prevents message loss. Time-based strings ("daily", "7 days") are not
  compared — Haskell-side interval parsing would drift from PostgreSQL's — that case
  remains documentation. The raw `PartitionSpec` constructor stays exported as the escape
  hatch, consistent with `JobTuning`/`RetryPolicy` precedent.
  Rationale: distinguish local validation policy from database retention guarantees.
  Date: 2026-07-23



- Decision: The review's documented-accepted queue-kind drift caveat (re-provisioning an
  existing queue with a different `QueueKind` is silently skipped by the reconciler, which
  only creates what is missing) stays accepted; this plan does not add drift detection.
  Rationale: master plan scope; recorded so the omission is legible.
  Date: 2026-07-23


- Decision: Follow `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`: only additive, separately named indexes are permitted; no upstream helper/Gin replacement or automatic conversion.
  Rationale: Explicit user guidance and preservation of upstream compatibility/presence reporting.
  Date: 2026-09-12

## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`) contains `keiro-pgmq`, typed
background jobs over PGMQ (queues as PostgreSQL tables `pgmq.q_<name>`, installed by the
`pgmq-migration` package's SQL, not as an extension). The upstream SQL lives in
`mori://shinzui/pgmq-hs` (resolve the checkout with `mori path mori://shinzui/pgmq-hs`); its
install ledger is `pgmq-migration/migrations/` (`0001-install-v1.11.0.sql`,
`0002-schema-management-comment.sql`, listed in `manifest`, embedded at compile time by
`pgmq-migration/src/Pgmq/Migration/Internal/Definition.hs`). Historical migration bytes are immutable. This initiative adds no function override or FIFO migration.

The keiro provisioning surface is the queue-lifecycle section of
`keiro-pgmq/src/Keiro/PGMQ/Job.hs`: `QueueKind` (lines 565-579) selects standard, unlogged,
or partitioned storage; `PartitionSpec` (lines 581-589) carries the two pg_partman strings
`partitionInterval` and `retentionInterval`; `partitionedProvision` (lines 609-612) wraps
it into a `QueueProvision`; `queueProvisionConfigs` (lines 618-644) lowers a provision to
`pgmq-config` `QueueConfig`s (pure, so partitioned lowering is testable without
pg_partman); `ensureJobQueueWith` (lines 646-654) runs pgmq-config's additive reconciler
(list existing queues, create only what is missing — the create path takes an advisory
lock and inserts queue metadata with `ON CONFLICT DO NOTHING`, so concurrent startups are
safe); `ensureFifoIndex` (lines 663-676) and `ensureOrderedJobQueue` (lines 678-686)
request the conventional FIFO index; the current reconciler observes its name and skips
creation when present. This existence report does not validate index performance. "pg_partman" is a PostgreSQL extension that manages time- or id-range table
partitions and, when configured with a retention, drops partitions older than it during
its scheduled maintenance.

The defects, re-verified on 2026-07-23:

PGQ-4 (HIGH; confirmed from SQL — live behavior untestable in this repo's CI).
`pgmq.create_partitioned` (SQL lines 1264-1419 of
`pgmq-migration/migrations/0001-install-v1.11.0.sql`) updates pg_partman's `part_config`
for the ACTIVE queue table with `retention = <retentionInterval>`,
`retention_keep_table = false`, `automatic_maintenance = 'on'` (lines 1329-1342): during
maintenance pg_partman permanently drops (not detaches — `retention_keep_table = false`)
every partition older than the interval, with no regard to whether its messages were ever
read. The same configuration is applied to the archive table `pgmq.a_<name>` (lines
1396-1409), so archive rows can also be removed. Time queues use enqueued_at and archives use archived_at; numeric parents use msg_id, so they do not share a single expiry clock. keiro's surface hides this:
the `PartitionSpec` haddock (lines 581-584) says only "e.g. \"7 days\"", and the
`Keiro.PGMQ.Dlq` module haddock states "PGMQ does not expire DLQ rows by itself"
(`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` line 15). One nuance found on re-reading: that DLQ
sentence is literally true for every keiro-provisioned DLQ *today*, because the DLQ is
always created as a standard queue (`queueProvisionConfigs`, lines 642-644) — the
correction is to scope the claim (true for standard queues, hence for keiro DLQs; false
for partitioned queues) rather than delete it. The only live test is permanently pending:
`keiro-pgmq/test/Main.hs` lines 1095-1099 (`pendingWith` — the suite's PostgreSQL installs
only the PGMQ schema, no pg_partman). Failure scenario to keep in mind while writing docs:
retention "7 days", consumer outage 8 days — successful maintenance can drop eligible old active partitions
wholesale; no DLQ entry, no metric, no log line from keiro.

PGQ-5 (confirmed, definitional). `pgmq._create_fifo_index_if_not_exists` (SQL lines
1428-1444) executes `CREATE INDEX IF NOT EXISTS <qtable>_fifo_idx ON pgmq.<qtable> USING
GIN (headers)`. The grouped reads filter and group on
`COALESCE(headers->>'x-pgmq-group', '_default_fifo_group')` — `read_grouped`'s
`fifo_groups` aggregate (lines 305-313), its `NOT EXISTS` member probe (lines 335-345),
its per-group lateral (lines 346-357), and `read_grouped_rr`'s equivalents (lines
117-200). A jsonb GIN index accelerates containment/existence operators only; it cannot
serve `->>` equality, GROUP BY, or ordering, so every poll aggregates the whole visible
table. keiro documents the opposite: `ensureFifoIndex`'s haddock calls it "the index
PGMQ's grouped/ordered reads (…) match against" (Job.hs lines 663-676), `QueueProvision`
and `ensureOrderedJobQueue` say "FIFO GIN index" (lines 591-598, 678-686), and the
promise dates to `docs/plans/76-add-partitioned-and-unlogged-queue-provisioning-with-fifo-indexes-to-keiro-pgmq.md`.
Upstream, `pgmq-hasql/test/AdvancedOpsSpec.hs` `testCreateFifoIndex` (lines 271-289) only
proves the function runs, not that any query uses the index.

Verified-sound behavior this plan must not regress: provisioning idempotency and
concurrent-startup safety (reconciler lists first; `pgmq.create*` take
`pgmq.acquire_queue_lock`'s advisory lock, SQL lines 107-115, and `ON CONFLICT DO NOTHING`
on the meta insert); conventional FIFO-index presence reporting remains stable; the pure
partitioned lowering test (`test/Main.hs` lines 1080-1094) and index idempotence test
(lines 1101-1113) stay green.

Relevant ADR: `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md`. It constrains the drain and worker execution paths' span contract.
This plan touches neither path — provisioning and DDL only — so the constraint reduces to:
the seven captured-span examples in `keiro-pgmq/test/Main.hs` (lines 901-1060) must pass
unmodified, which they will unless this plan strays from its scope.

Sibling plans: `docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md`
owns the delivery-path fixes and any change to the tuning types (`JobTuning`,
`JobOrdering`, `Job`) — this plan must not touch those types (master plan Integration
Points). Neither plan writes pgmq SQL. Plan 116 may consume a client-ordering release; this index
work is separately measured operator DDL and does not share a package-bound change. The DLQ operator path is
`docs/plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md`;
it rewrites *other* paragraphs of the same `Dlq.hs` module haddock (the visibility-window
runbook), while this plan owns only the expiry-claim sentence — keep the edits
sentence-scoped to avoid conflicts.


## Plan of Work

### Milestone 1 — tell the truth about partitioned retention, and guard construction

Scope: keiro-side only; no upstream change, no behavior change to provisioning itself. At
the end, nobody can read the partitioned API top-to-bottom and come away believing
retention is a cleanup knob, and the two provably-wrong spec shapes are rejected at
construction.

In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`:

1. Rewrite the `PartitionSpec` haddock (lines 581-589). It must state, in this order: what
   the two strings mean (pg_partman partition sizing and retention); that retention DROPS
   whole partitions of the ACTIVE queue table on a timer — unprocessed messages included —
   because `pgmq.create_partitioned` sets `retention_keep_table = false` with automatic
   maintenance; that the archive table gets the same retention, so archived rows expire
   too; the concrete failure mode (backlog or outage longer than `retentionInterval` means
   permanent loss of unprocessed work, with no error anywhere); and the sizing rule that
   follows (retention must comfortably exceed worst-case processing lag, not storage
   preference). Prefer `mkPartitionSpec`.

2. Add the validating constructor and its error type next to `PartitionSpec`, exported
   from the module's queue-lifecycle section and re-exported by `Keiro.PGMQ`:

   ```haskell
   data PartitionSpecConfigError
       = EmptyPartitionInterval
       | EmptyRetentionInterval
       | -- | One string is numeric (msg_id-range partitioning) and the other
         -- is not; pg_partman would only fail at maintenance time, long after
         -- provisioning appeared to succeed.
         MixedPartitionUnits !Text !Text
       | -- | Numeric kind: retention smaller than one partition's id-span
         -- authorizes dropping the partition currently being filled.
         RetentionBelowPartitionInterval !Int64 !Int64
       deriving stock (Eq, Show)

   mkPartitionSpec :: Text -> Text -> Either PartitionSpecConfigError PartitionSpec
   ```

   Implementation: trim both inputs; empty → the respective error; classify each with a
   `Data.Text.Read.decimal`-style full parse to `Int64`; one numeric and one not →
   `MixedPartitionUnits`; both numeric with retention < partition →
   `RetentionBelowPartitionInterval`; otherwise `Right (PartitionSpec ...)`. Keep the raw
   constructor exported (documented as the unvalidated escape hatch, mirroring
   `JobTuning`).

3. Update the `QueueKind` haddock's `PartitionedKind` arm (lines 571-573) and
   `partitionedProvision` (lines 609-612): one-sentence version of the drop semantics plus
   a pointer to `PartitionSpec`, and the experimental label — partitioned provisioning has
   never run against a live pg_partman in this repo's CI (the pending example at
   `test/Main.hs` lines 1095-1099); treat it as experimental until that example runs.

4. In `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`, replace the sentence "PGMQ does not expire DLQ
   rows by itself." (line 15) with a scoped version: standard queues — which every
   keiro-provisioned DLQ is — never expire rows on their own; partitioned queues DO (see
   `PartitionSpec`), so the archive-then-purge retention model described here applies to
   the DLQ precisely because it is standard. Touch nothing else in that haddock (sibling
   plan 117 owns the runbook paragraphs).

New pure tests in `keiro-pgmq/test/Main.hs` (no database; place near the "validates job
tuning" example at line 380): `mkPartitionSpec "daily" "7 days"` is `Right`;
`mkPartitionSpec "10000" "100000"` is `Right`; `mkPartitionSpec "10000" "5000"` is
`Left (RetentionBelowPartitionInterval 10000 5000)`; `mkPartitionSpec "daily" "100000"` is
`Left (MixedPartitionUnits ...)`; empty cases. Also extend the existing pure lowering
example (line 1080) to build its spec via `mkPartitionSpec` so the constructor is on the
provisioning path of record.

Acceptance: `cabal test keiro-pgmq-test` green with the new examples; `git diff` shows no
change to any tuning type and no behavioral change outside `mkPartitionSpec`.

### Milestone 2 — evaluate the optional supplemental index

Read `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use` for the measured candidate, exact definition, supported queue types, lock
cost and explicit create/inspect/remove procedure. If it is not yet measured, keep the
recommendation pending; documentation correcting the GIN claim can proceed. No pgmq-migration
release or Keiro dependency bump is required for independent operator DDL.

The intended supplemental name is q_<queue>_group_lookup_idx. Keep upstream q_<queue>_fifo_idx
GIN and all pgmq functions unchanged. Do not route the supplement through ensureFifoIndex,
withFifoIndexProvision or normal startup. Record a negative experiment honestly rather than
promising a scan node or universal speedup.

### Milestone 3 — accurate provisioning prose and coexistence evidence

Correct ensureFifoIndex, QueueProvision, withFifoIndexProvision, ensureOrderedJobQueue and
provisionFifoIndex Haddocks: they request upstream's conventional GIN index. Its presence does
not prove it accelerates grouped reads. If measured useful, link the separately owned operator
index procedure and state that no automatic conversion takes place.

Use a disposable queue to validate the supplied procedure on a representative Keiro workload.
Provision normally, then explicitly add the supplement; compare GIN-only versus GIN-plus-index
measurements with stable data/statistics. Use full-query timing/buffers and current query shapes;
a particular scan node is diagnostic, not a brittle permanent CI assertion. Do not override
functions or edit another repository's migration to make a benchmark pass.

Verify upstream GIN and function definitions remain intact, repeated reconciliation still
reports conventional index presence, and removing only the supplement restores the baseline.
Use the owning experiment rather than maintaining a duplicate 100k-row benchmark in every
ordinary Keiro test run. Record actual supported partition/lock limits. Acceptance is truthful
Haddocks, existing provisioning tests passing, and reproducible coexistence evidence or an
explicit negative/pending recommendation.

## Concrete Steps

Run from the Keiro root. M1's pure constructor and documentation changes use:

```bash
cabal build all
cabal test keiro-pgmq-test
```

For M2/M3, locate `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use` with Mori and read its current evidence and operator procedure.
Run that procedure only on a disposable queue using the existing test fixture. Record actual
commands, server/queue type, measurements and outputs. A local index experiment requires no
cabal update, migration-bound bump or extension function replacement. Preserve existing pending
cases as reported by the current suite rather than inventing an exact example count.

Use Conventional Commits and the parent/child trailers when implementation is committed.


## Validation and Acceptance

The retention constructor cases from M1 pass and Haddocks cover time/numeric retention,
queue/archive controls and maintenance-time loss of unprocessed rows. Treat any minimum
retention-versus-partition interval guard as Keiro policy, not proof of no loss; verify its
server-semantics rationale before presenting it as a server restriction. Existing telemetry
and provisioning tests remain green.

Ordinary provisioning is accurately documented as upstream GIN, with name-based presence
reporting. Any supplemental index is separately named and explicitly installed/removed;
coexistence evidence preserves GIN and function definitions. No new migration, helper override,
automatic conversion or version bump is required. Measurements support any performance claim;
negative or pending results are explicit.


## Idempotence and Recovery

M1 is an additive constructor/documentation change with a retained raw constructor. The
supplemental index is explicit operator state: inspect its definition and ownership before
creation/removal, handle conflicting/invalid objects using the owning tested procedure, and
never drop upstream GIN or replace a function. Build locks and partition constraints must be
reported, not assumed harmless. Reverting Cabal bounds is not database rollback; this work
introduces no migration or dependency bump.


## Interfaces and Dependencies

At the end of the plan, `keiro-pgmq/src/Keiro/PGMQ/Job.hs` additionally exports (module
`Keiro.PGMQ.Job`, re-exported through `Keiro.PGMQ`):

```haskell
data PartitionSpecConfigError
    = EmptyPartitionInterval
    | EmptyRetentionInterval
    | MixedPartitionUnits !Text !Text
    | RetentionBelowPartitionInterval !Int64 !Int64

mkPartitionSpec :: Text -> Text -> Either PartitionSpecConfigError PartitionSpec
```

`PartitionSpec`, `QueueKind`, `QueueProvision`, `partitionedProvision`,
`withFifoIndexProvision`, `queueProvisionConfigs`, `ensureFifoIndex`, and
`ensureOrderedJobQueue` keep their signatures (docs-only changes). This plan must not
touch `JobTuning`, `JobOrdering`, or `Job` — those belong to
`docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md`.

Index evidence and operator guidance are owned by `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`. Upstream SQL and conventional
FIFO provisioning remain unchanged; no migration package minimum is introduced. Plan 116's
client-ordering release is independent. Retain existing pgmq family compatibility bounds unless
an actual API change elsewhere requires a separately verified update.

Revision note (2026-09-12): Removed replacement-index migration/release assumptions and brittle scan assertions; aligned M2/M3, interfaces and recovery with explicit supplemental-index ownership.
