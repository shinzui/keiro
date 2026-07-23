---
id: 118
slug: correct-partitioned-retention-semantics-and-the-fifo-index
title: "Correct partitioned retention semantics and the FIFO index"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
master_plan: "docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md"
---

# Correct partitioned retention semantics and the FIFO index

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


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
`read_grouped_rr` actually execute. Every grouped read is a full table scan regardless of
the index; at fleet polling cadence (100 ms - 1 s per consumer) against a large backlog
that is an O(N)-per-poll tax that the docs claim is already paid.

After this plan: the partitioned-provisioning API tells the truth (retention DROPS
unprocessed messages), refuses the configurations it can prove are wrong, and is explicitly
labeled not-production-validated until the still-pending live pg_partman test can run; the
DLQ haddock's expiry claim is scoped to what is actually true; and `create_fifo_index`
builds a btree expression index that the grouped-read predicates can use — proven with
`EXPLAIN` evidence against a seeded 100,000-row queue, captured in this plan. You can see
it working by running `cabal test keiro-pgmq-test` from the repository root: the new
index-usage example prints/asserts an index scan where today the same probe seq-scans.


## Progress

- [ ] M1: `PartitionSpec`/`partitionedProvision`/`QueueKind` haddocks state the drop-unprocessed semantics; partitioned provisioning labeled experimental; `Keiro.PGMQ.Dlq` haddock expiry claim scoped; `mkPartitionSpec` validating constructor added with pure tests.
- [ ] M2: pgmq-hs migration re-creates `pgmq._create_fifo_index_if_not_exists` as a btree expression index (new name, drops the old GIN); upstream index-definition test added; pgmq-hs family released; version recorded here.
- [ ] M3: keiro-pgmq test-suite bound raised to the released pgmq-migration; 100k-row `EXPLAIN` example added and green; before/after plan transcripts pasted into Validation; keiro haddocks stop saying "GIN".
- [ ] CHANGELOG entries (keiro-pgmq additive API + docs; pgmq-hs migration); ADR distillation pass done (provisioning half of the master plan's FIFO-contract ADR candidate).


## Surprises & Discoveries

(None yet.)


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
  interval, because a retention smaller than one partition's id-span authorizes dropping
  the partition currently being filled. Time-based strings ("daily", "7 days") are not
  compared — Haskell-side interval parsing would drift from PostgreSQL's — that case
  remains documentation. The raw `PartitionSpec` constructor stays exported as the escape
  hatch, consistent with `JobTuning`/`RetryPolicy` precedent.
  Rationale: enforce exactly what can be proven, document the rest loudly.
  Date: 2026-07-23

- Decision: PGQ-5 is fixed upstream by re-creating
  `pgmq._create_fifo_index_if_not_exists` to build
  `btree ((COALESCE(headers->>'x-pgmq-group', '_default_fifo_group')), msg_id)` under the
  new name `<qtable>_fifo_group_idx`, dropping the old `<qtable>_fifo_idx` GIN in the same
  function body. Whether `vt` belongs in the index is decided by the M3 `EXPLAIN` evidence,
  not up front.
  Rationale: A jsonb GIN index supports the `@>`/`?`/`?|`/`?&` operator classes; it cannot
  serve `->>` extraction equality, ordering, or GROUP BY — this is definitional, no
  benchmark needed. The grouped reads compare
  `COALESCE(headers->>'x-pgmq-group', '_default_fifo_group')` (SQL lines 305-357), and
  PostgreSQL only matches an expression index whose expression is verbatim-identical, so
  the COALESCE must be in the index definition. The new *name* matters: the function uses
  `CREATE INDEX IF NOT EXISTS`, so reusing the old name on queues that already have the GIN
  index would silently no-op and leave the useless index in place; a new name plus
  `DROP INDEX IF EXISTS` on the old one converts existing queues on their next provisioning
  call. Dropping the GIN is safe: no pgmq read path uses `@>` against `headers`
  (`pgmq.read`'s conditional filter targets the `message` column, SQL lines 267-270).
  Starting column order `(group, msg_id)` serves the hottest shapes — the per-group lateral
  `ORDER BY msg_id LIMIT qty` and the `NOT EXISTS` earlier-member probe — with `vt`
  filtered from the heap; a leading or middle `vt` column would break the index-order
  `ORDER BY msg_id` after a range predicate.
  Date: 2026-07-23

- Decision: The `EXPLAIN` evidence lives in the keiro-pgmq test suite (the suite already
  owns an ephemeral PostgreSQL per example and a raw-SQL escape hatch), seeded with 100,000
  rows across 50 groups via `generate_series` plus `ANALYZE`, asserting the new index name
  appears in the plan of the representative per-group probe. Not a standalone script.
  Rationale: a script rots; a suite example re-proves the index-query fit on every run and
  fails if a future pgmq migration changes either side. Seeding 100k rows by a single
  `INSERT ... SELECT` is sub-second.
  Date: 2026-07-23

- Decision: The review's documented-accepted queue-kind drift caveat (re-provisioning an
  existing queue with a different `QueueKind` is silently skipped by the reconciler, which
  only creates what is missing) stays accepted; this plan does not add drift detection.
  Rationale: master plan scope; recorded so the omission is legible.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`) contains `keiro-pgmq`, typed
background jobs over PGMQ (queues as PostgreSQL tables `pgmq.q_<name>`, installed by the
`pgmq-migration` package's SQL, not as an extension). The upstream SQL lives in the pgmq-hs
repository at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`; its
install ledger is `pgmq-migration/migrations/` (`0001-install-v1.11.0.sql`,
`0002-schema-management-comment.sql`, listed in `manifest`, embedded at compile time by
`pgmq-migration/src/Pgmq/Migration/Internal/Definition.hs`). Changed SQL functions ship as
a *new* numbered migration file with `CREATE OR REPLACE`, never as an edit to an applied
file.

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
re-apply the FIFO index step on every call (the reconciler applies the index
unconditionally when requested; idempotent because the SQL is `CREATE INDEX IF NOT
EXISTS`). "pg_partman" is a PostgreSQL extension that manages time- or id-range table
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
1396-1409), so archived audit rows expire on the same clock. keiro's surface hides this:
the `PartitionSpec` haddock (lines 581-584) says only "e.g. \"7 days\"", and the
`Keiro.PGMQ.Dlq` module haddock states "PGMQ does not expire DLQ rows by itself"
(`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` line 15). One nuance found on re-reading: that DLQ
sentence is literally true for every keiro-provisioned DLQ *today*, because the DLQ is
always created as a standard queue (`queueProvisionConfigs`, lines 642-644) — the
correction is to scope the claim (true for standard queues, hence for keiro DLQs; false
for partitioned queues) rather than delete it. The only live test is permanently pending:
`keiro-pgmq/test/Main.hs` lines 1095-1099 (`pendingWith` — the suite's PostgreSQL installs
only the PGMQ schema, no pg_partman). Failure scenario to keep in mind while writing docs:
retention "7 days", consumer outage 8 days — pg_partman drops the oldest active partitions
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
on the meta insert); FIFO index re-application harmless at every startup; the pure
partitioned lowering test (`test/Main.hs` lines 1080-1094) and index idempotence test
(lines 1101-1113) stay green.

Relevant ADR: `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (the only
ADR in `docs/adr/`). It constrains the drain and worker execution paths' span contract.
This plan touches neither path — provisioning and DDL only — so the constraint reduces to:
the seven captured-span examples in `keiro-pgmq/test/Main.hs` (lines 901-1060) must pass
unmodified, which they will unless this plan strays from its scope.

Sibling plans: `docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md`
owns the delivery-path fixes and any change to the tuning types (`JobTuning`,
`JobOrdering`, `Job`) — this plan must not touch those types (master plan Integration
Points). It also shares the pgmq-hs release train with this plan's M2: whichever plan
releases first creates `migrations/0003-*.sql` and version 0.4.1.0; the second appends
`0004-*.sql` (or extends the unreleased 0.4.1.0) — record the actual filename and version
in Progress when known. The DLQ operator path is
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

### Milestone 2 — an index the grouped reads can actually use (upstream)

Scope: the pgmq-hs repository. At the end, `pgmq.create_fifo_index` (and the reconciler
path through it) builds a btree expression index matching the grouped-read predicates, the
old GIN is dropped on conversion, an upstream test pins the index definition, and a
release exists for keiro to consume.

1. Determine the migration filename and version with
   `docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md`
   (M4 there): first plan to release creates
   `pgmq-migration/migrations/0003-<slug>.sql` at family version 0.4.1.0 (current: all
   five packages 0.4.0.1); the second appends `0004-<slug>.sql` at 0.4.2.0, or both
   changes ride one 0.4.1.0 if released together. Use slug
   `fifo-group-btree-index` for this plan's file. Record the outcome in Progress and the
   Decision Log.

2. The migration file contains one statement:

   ```sql
   CREATE OR REPLACE FUNCTION pgmq._create_fifo_index_if_not_exists(queue_name TEXT)
   RETURNS void AS $$
   DECLARE
       qtable TEXT := pgmq.format_table_name(queue_name, 'q');
       old_index_name TEXT := qtable || '_fifo_idx';
       index_name TEXT := qtable || '_fifo_group_idx';
   BEGIN
       -- The pre-1.11.0-hs GIN index cannot serve the grouped reads'
       -- ->> extraction predicates; drop it on conversion.
       EXECUTE FORMAT('DROP INDEX IF EXISTS pgmq.%I;', old_index_name);
       -- Btree over the exact grouping expression used by read_grouped /
       -- read_grouped_rr, then msg_id for the per-group ORDER BY ... LIMIT
       -- and the earlier-member probes.
       EXECUTE FORMAT(
           $QUERY$
           CREATE INDEX IF NOT EXISTS %I ON pgmq.%I (
               (COALESCE(headers->>'x-pgmq-group', '_default_fifo_group')),
               msg_id
           );
           $QUERY$,
           index_name, qtable
       );
   END;
   $$ LANGUAGE plpgsql;
   ```

   Add the filename to `pgmq-migration/migrations/manifest`. No change to
   `pgmq.create_fifo_index` or `pgmq.create_fifo_indexes_all` (they delegate, SQL lines
   1446-1460+), and none to `pgmq-migration/src/Pgmq/Migration/SchemaContract.hs` (the
   function signature is unchanged and the contract does not enumerate indexes — verify by
   reading `requiredContractObjects`). The expression must be byte-identical to the
   grouped-read SQL's `COALESCE(headers->>'x-pgmq-group', '_default_fifo_group')`;
   PostgreSQL matches expression indexes syntactically.

3. Upstream tests in `pgmq-hasql/test/AdvancedOpsSpec.hs`: rewrite `testCreateFifoIndex`
   (lines 271-289) to assert the *definition* — query
   `SELECT indexdef FROM pg_indexes WHERE schemaname = 'pgmq' AND tablename = <qtable>`
   and assert one row contains `_fifo_group_idx`, `btree`, and the COALESCE expression,
   and that no `_fifo_idx` GIN row remains. Add a conversion case: create the queue,
   manually `CREATE INDEX <qtable>_fifo_idx ... USING GIN (headers)`, call
   `createFifoIndex`, assert the GIN is gone and the btree exists (pins the drop-and-adopt
   path for fleets provisioned before this release).

4. Run the pgmq-hs suite, then release the family and write its CHANGELOG entry (breaking
   note for anyone who queried the old index by name):

   ```bash
   cd /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs
   just process-up
   cabal test all
   ```

   Release through the same internal index the previous family upgrade used (keiro commit
   `ef0b246` consumed it); verify the served version before pinning bounds.

Acceptance: pgmq-hs `cabal test all` green including the new definition and conversion
tests; the release exists at the recorded version.

### Milestone 3 — consume the release, prove the index with EXPLAIN, fix keiro's words

Scope: back in this repository. At the end the keiro suite runs on the new migration, an
example proves the grouped-read probe uses the new index on a 100k-row queue, and no keiro
haddock claims "GIN" anymore.

1. In `keiro-pgmq/keiro-pgmq.cabal`, raise the test-suite bound `pgmq-migration` (line 95)
   to `>= <released version> && <0.5`. Run `cabal update` (or the dev shell's reindex) and
   the suite; the existing FIFO and index-idempotence examples (`test/Main.hs` lines
   1101-1113, 1125-1191) must pass unchanged — they assert behavior, not index kind.

2. Add the evidence example (live, in the FIFO section of `test/Main.hs`), using the
   suite's raw-SQL technique (`archiveCount`, lines 106-120, shows the pattern; the
   physical name is sanitized by `queueRef`, so interpolation is safe):

   - Provision an ordered job queue (`ensureOrderedJobQueue`).
   - Seed and analyze:

     ```sql
     INSERT INTO pgmq.q_<physical> (vt, message, headers)
     SELECT clock_timestamp(), '{}'::jsonb,
            jsonb_build_object('x-pgmq-group', 'g' || (i % 50))
     FROM generate_series(1, 100000) AS i;
     ANALYZE pgmq.q_<physical>;
     ```

   - Collect the plan rows of the representative per-group probe (the shape of
     `read_grouped`'s lateral, SQL lines 350-357):

     ```sql
     EXPLAIN
     SELECT msg_id FROM pgmq.q_<physical> t
     WHERE COALESCE(t.headers->>'x-pgmq-group', '_default_fifo_group') = 'g7'
       AND t.vt <= clock_timestamp()
     ORDER BY msg_id
     LIMIT 5;
     ```

   - Assert the concatenated plan text contains `_fifo_group_idx` and does not contain
     `Seq Scan` on the queue table. Name the example "the FIFO group index serves the
     grouped-read probe on a 100k-row queue".

   During implementation, also capture the *before* evidence once (run the same probe
   against a queue provisioned with the old migration, i.e. before step 1's bound bump)
   and paste both transcripts into the Validation section below as `text` blocks — that
   before/after pair is the master plan's required "EXPLAIN-backed evidence". If the
   after-plan does not use the index (planner surprise), that is an M2 design signal:
   evaluate adding `vt` to the index (as a trailing column or a second index) per the
   Decision Log, change the migration *before* it is released — or as the next numbered
   file if already consumed — and record what the evidence showed in Surprises &
   Discoveries.

3. Fix keiro's wording in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`: `ensureFifoIndex` (lines
   663-676 — also drop or update the stale reference to plan 77's promise), the
   `QueueProvision` haddock (lines 591-598), `withFifoIndexProvision` (lines 614-616),
   `ensureOrderedJobQueue` (lines 678-686), and the `provisionFifoIndex` field comment:
   the index is now "the btree expression index over the FIFO group key that PGMQ's
   grouped reads (`read_grouped`/`read_grouped_rr`) match against"; conversion note that
   re-provisioning an existing queue swaps the legacy GIN for the btree automatically
   (that is why re-application at startup is desirable, not merely harmless). Mention the
   minimum pgmq-migration version the deployment must have applied.

Acceptance: `cabal test keiro-pgmq-test` green including the evidence example; grep
`rg -n "GIN" keiro-pgmq/src` returns nothing (or only deliberate historical notes).


## Concrete Steps

keiro commands run from `/Users/shinzui/Keikaku/bokuno/keiro`; pgmq-hs commands from
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`.

Baseline before any edit (the suite boots its own PostgreSQL; no setup needed):

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-pgmq-test
```

Expected tail:

```text
58 examples, 0 failures, 2 pending
Test suite keiro-pgmq-test: PASS
```

The two pending examples are pre-existing (`test/Main.hs` lines 645 and 1096); the second
one — partitioned live provisioning — remains pending after this plan by design (see the
Decision Log). If sibling plans landed first the baseline count is higher; only `0
failures` is load-bearing. If plan 116 landed first, new `Job` constructions here need its
`jobOrdering` field — follow the compiler.

M1: edit, then re-run the suite. Commit:

```text
feat(keiro-pgmq): validate PartitionSpec and document partitioned retention drop semantics
```

M2: in pgmq-hs — add migration + manifest line, rewrite the index tests, then:

```bash
cd /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs
just process-up
cabal test all
```

Release, record the version here, commit upstream with a conventional message noting the
index rename.

M3: bump the bound, then:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal update
cabal test keiro-pgmq-test
```

Commit:

```text
feat(keiro-pgmq)!: consume the FIFO group btree index migration and prove it with EXPLAIN
```

(the `!` reflects the raised minimum migration for FIFO deployments; if the version
resolution makes it non-breaking for library consumers, downgrade to `feat` and say so in
the body).


## Validation and Acceptance

The plan is done when all of the following are observable:

1. From the keiro repo root, `cabal test keiro-pgmq-test` prints `0 failures, 2 pending`
   with the new examples counted (record the final number in Progress).
2. `mkPartitionSpec "10000" "5000"` evaluates to
   `Left (RetentionBelowPartitionInterval 10000 5000)` and
   `mkPartitionSpec "daily" "100000"` to a `MixedPartitionUnits` error (pinned by pure
   examples).
3. Reading `PartitionSpec`'s haddock answers, without leaving the page: "what happens to
   messages my consumers have not processed when a partition ages out?" (dropped,
   permanently, silently) and "is this production-validated?" (no — experimental until the
   pending live example runs).
4. Upstream, `pg_indexes` shows `<qtable>_fifo_group_idx` as a btree over the COALESCE
   expression and no `<qtable>_fifo_idx` after `create_fifo_index` runs on a queue that
   previously had the GIN (pinned by the pgmq-hasql conversion test).
5. The keiro evidence example passes; the before/after transcripts are pasted here. Before
   (expected shape, captured during implementation):

   ```text
   Limit  (cost=... )
     ->  Sort / Seq Scan on q_<physical> t  (filter: COALESCE(...) = 'g7' ...)
   ```

   After (expected shape):

   ```text
   Limit  (cost=... )
     ->  Index Scan using q_<physical>_fifo_group_idx on q_<physical> t
   ```

   (Replace both with the real transcripts; the assertion in the suite is index name
   present, seq scan absent.)
6. The ADR-0001 captured-span examples (`test/Main.hs` lines 901-1060) pass unmodified.
7. `keiro-pgmq/src` no longer describes the FIFO index as GIN anywhere.


## Idempotence and Recovery

M1 is documentation plus an additive pure constructor: freely re-runnable, no rollback
concerns; the raw `PartitionSpec` constructor keeps every existing caller compiling.

M2's migration is append-only and its function body is itself idempotent and convergent:
`DROP INDEX IF EXISTS` + `CREATE INDEX IF NOT EXISTS` means re-running provisioning any
number of times, from any mix of old-GIN/new-btree starting states, converges on exactly
the btree index. A mistake discovered before the release is consumed anywhere: amend the
migration file and re-run the pgmq-hs suite (it installs the ledger from scratch). After
consumption: ship the fix as the next numbered migration; never edit the applied file.

Index conversion on live fleets is safe to interleave with running consumers: dropping the
GIN momentarily removes an index no read uses (that is the finding), and grouped reads are
merely slow, not wrong, until the btree exists. If the conversion must be rolled back for
an unforeseen reason, re-creating the GIN by hand restores the exact prior state.

M3's bound bump is a one-line cabal change; reverting it restores the previous migration
set for the test suite. The evidence example is self-contained per fresh database and can
be re-run indefinitely.


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

Upstream: pgmq-hs family (currently all 0.4.0.1) gains one migration re-creating
`pgmq._create_fifo_index_if_not_exists`; no Haskell API in `pgmq-hasql`/`pgmq-effectful`/
`pgmq-config` changes (`createFifoIndex` keeps its type; the reconciler in
`pgmq-config/src/Pgmq/Config/Effectful.hs` lines 96-101 re-applies it unconditionally,
which is what converts existing queues). keiro-pgmq's test-suite bound on
`pgmq-migration` rises to the released version (`>=0.4.1 && <0.5` or `>=0.4.2 && <0.5`
depending on the release-train outcome with plan 116 — record the final bound here).
Deployments must apply the new migration before the index claim in the docs is true for
them; the keiro haddock states that minimum version.
