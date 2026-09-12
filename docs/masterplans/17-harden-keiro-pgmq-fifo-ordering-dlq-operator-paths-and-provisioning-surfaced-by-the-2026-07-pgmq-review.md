---
id: 17
slug: harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review
title: "Harden keiro-pgmq FIFO ordering, DLQ operator paths, and provisioning surfaced by the 2026-07 pgmq review"
kind: master-plan
created_at: 2026-07-23T03:02:15Z
intention: "intention_01m2b1p3vhe179jtr5qz6ghqks"
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
---

# Harden keiro-pgmq FIFO ordering, DLQ operator paths, and provisioning surfaced by the 2026-07 pgmq review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

**Upstream scope relocated (2026-09-12).** The three findings whose fix lives in pgmq-hs SQL and
documentation — PGQ-2 (grouped reads' undefined return order), PGQ-5 (the FIFO index that cannot
serve the grouped-read predicates), and PGQ-4's upstream half (partitioned retention dropping
unprocessed partitions) — now belong to

`mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`

with child plans `mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order`,
`mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`, and
`mori://shinzui/pgmq-hs/plans/21-state-the-fifo-ordering-and-partitioned-retention-contracts-truthfully`.
That repository owns their implementation, migration numbering, and release. This MasterPlan is
**not** superseded: PGQ-1, PGQ-3, PGQ-6, PGQ-7, and PGQ-4's keiro half are defects in
`keiro-pgmq/src` and stay here. Plans 116 and 118 consume the upstream release instead of producing
it.


## Vision & Scope

The keiro-pgmq feature wave that MasterPlan 10 shipped on 2026-06-13 — message headers and trace propagation, partitioned/unlogged provisioning with FIFO indexes, FIFO ordered delivery via message groups, and queue metrics with archive/retention — landed two days after MasterPlan 9's June audit reviewed the package, so none of it had ever been reviewed. The July 2026 pgmq review deep-read all of `keiro-pgmq/src` plus the upstream seams it rides on (the pgmq-hs family's SQL and statements, shibuya-pgmq-adapter's FIFO ingest, shibuya-core's serial runner), and an adversarial verification pass confirmed the two ordering findings against the installed pgmq 1.11.0 SQL. Seven findings survived; the two most serious are that the documented per-group strict FIFO ordering silently degrades to best-effort whenever a consumer opts into `batchSize > 1` (nothing enforces or documents the batch-size-1 requirement, no FIFO failure branch is test-pinned, and `read_grouped`'s RETURNING order is additionally plan-dependent), and that partitioned provisioning configures pg_partman to drop whole partitions of the active queue table on a retention timer regardless of whether their messages were processed — silent bulk message loss under backlog, while the package docs claim PGMQ never expires rows on its own.

After this initiative is complete: a FIFO queue delivers strict per-group order under every supported configuration — either because unsafe batch sizes are rejected at construction time or because the consumer paths abort a group on first failure — and the ordering requirement travels with the `Job` so an ops script cannot silently void it; `read_grouped` returns batches in guaranteed msg_id order; DLQ redrive preserves the original headers so a redriven FIFO message keeps its group identity and trace context; the documented DLQ inspect-archive-purge runbook can no longer destroy un-archived rows through the 30-second visibility window; partitioned retention semantics are stated truthfully with guardrails against configuring silent message loss; and the "FIFO index" either actually serves the grouped-read query shape or stops being documented as doing so.

In scope: the keiro-side findings — PGQ-1 (batched-consumption ordering), PGQ-3 (redrive headers), PGQ-6 (archive/purge visibility), PGQ-7 (ordering-tuning mismatch), and PGQ-4's keiro half (truthful provisioning haddocks plus a construction-time guardrail) — their regression tests (including the currently absent FIFO failure-branch and `FifoRoundRobin` coverage), keiro's documentation corrections, and consuming the upstream release that carries the relocated SQL fixes. Relocated out of scope on 2026-09-12 and owned by `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`: PGQ-2's ORDER BY on the grouped reads' RETURNING, PGQ-5's btree expression index, and PGQ-4's upstream half (documenting that partitioned retention drops unprocessed partitions of both the queue and the archive table). Plans 116 and 118 keep the keiro-visible halves of PGQ-2 and PGQ-5 — the tests and haddocks that observe the upstream behavior — but no longer write pgmq-hs SQL. Out of scope: the accepted design decisions re-verified by the review (pgmq-effectful's no-retry interpreter, the drain path's send-then-delete DLQ duplicate window, provision-kind drift detection); conditional reads on the worker path and PGMQ-as-integration-transport (both remain roadmap items); and any change to shibuya-core's runner (the serial worker's behavior is by design; keiro-pgmq must stop handing it unsafe batches).


## Decomposition Strategy

Three child plans, split by the operational surface a deployment team interacts with: the delivery path, the operator/DLQ path, and provisioning.

EP-1 (plan 116) owns FIFO delivery correctness in keiro: the batch-size ordering hole on both consumer paths (PGQ-1), the unenforced ordering-tuning mismatch (PGQ-7), and the keiro-visible half of PGQ-2 — the tests that observe a deterministic batch order once upstream delivers it. One plan because the fix decision is shared: whether FIFO clamps batch size to 1, implements group-abort, or adopts PGMQ's `read_grouped_head` determines what `runJobOnce` must validate. The SQL half of PGQ-2 relocated to `mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order` on 2026-09-12.

EP-2 (plan 117) owns the DLQ operator path: header-preserving redrive (PGQ-3) and the archive/purge visibility trap (PGQ-6). These share `Keiro/PGMQ/Dlq.hs` and its tests, and both are operator-runbook facing.

EP-3 (plan 118) owns provisioning truth in keiro: keiro's partitioned-retention haddocks and the `mkPartitionSpec` guardrail (PGQ-4's keiro half), and the keiro-visible half of PGQ-5 — removing the "GIN index that grouped reads match against" claim from `Keiro/PGMQ/Job.hs` and pinning the improvement with an `EXPLAIN`-backed example once the upstream index ships. These share the provisioning surface in `Keiro/PGMQ/Job.hs`. The upstream DDL and the upstream documentation half relocated to `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use` and `mori://shinzui/pgmq-hs/plans/21-state-the-fifo-ordering-and-partitioned-retention-contracts-truthfully` on 2026-09-12.

Alternatives considered. Folding EP-3 into EP-1 because both touch pgmq-hs was rejected: EP-1's upstream change is one ORDER BY in a hot read function, EP-3's is index DDL plus documentation policy — different risk profiles, and coupling them would serialize the ordering fix behind a pg_partman investigation. A single monolithic plan was rejected because the three surfaces have disjoint acceptance tests and can proceed in parallel.

ADR context: `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` is directly relevant — it fixes the one-process-span-per-delivery contract on both the worker and one-shot paths. EP-1 touches `runJobOnce` (ordering validation) and the drain fold (group handling) and must preserve that contract; the plan carries the constraint. Candidate ADR at completion: the FIFO delivery contract (what ordering is guaranteed, under which tuning, and how violations are surfaced).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Enforce FIFO group ordering under failure and batched consumption | docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md | None | None | Not Started |
| 2 | Preserve headers on DLQ redrive and make archive and purge visibility-safe | docs/plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md | None | None | Not Started |
| 3 | Correct partitioned retention semantics and the FIFO index | docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md | None | EP-1 | Not Started |

External dependencies, not rows in this table because this MasterPlan does not implement them:
EP-1's deterministic-batch-order test and EP-3's `EXPLAIN` example both need the pgmq-hs release that
carries the relocated SQL, owned by `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`.
Each plan can complete its keiro-side milestones before that release exists; only the observing tests
wait on it.


## Dependency Graph

No hard dependencies; all three plans can proceed in parallel.

EP-3's soft dependency on EP-1 is now only about the version bump keiro adopts. Neither plan writes pgmq-hs SQL any more — that relocated on 2026-09-12 — so their remaining coupling is that both want to observe the upstream fixes and keiro should raise its `pgmq-*` bounds once rather than twice. If the upstream release carries both fixes together (its own plans 19 and 20 share a migration), keiro moves its bounds in whichever of EP-1 or EP-3 lands first and the other inherits them.


## Integration Points

`pgmq-hs` release (`mori://shinzui/pgmq-hs`): consumed, not produced. EP-1 and EP-3 no longer modify the pgmq SQL migration surface; that work is owned by `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts` as of 2026-09-12, including the migration numbering (next free is `0007`) and the release. keiro's obligation is to raise its `pgmq-*` bounds in `keiro-pgmq.cabal` when the fixes ship and to re-run the observing tests against them. The family is at 0.6.0.0 and keiro already declares `>=0.6 && <0.7`, which admits an additive 0.6.1.0; if the upstream index work turns out to need a breaking bump, the bounds change lands in whichever of EP-1 or EP-3 runs first.

`shibuya-pgmq-adapter` (`mori://shinzui/shibuya-pgmq-adapter`, released 0.14.0.0): not an integration point under the current scope. It becomes one only if EP-1 answers PGQ-1 with PGMQ's `read_grouped_head` instead of the batch-size clamp: the drain path calls `readGrouped`/`readGroupedRoundRobin` directly and could adopt head reads on its own, but the worker path reads through the adapter, whose `FifoReadStrategy` offers only `ThroughputOptimized` and `RoundRobin`. Adopting head reads on both paths therefore requires a new adapter strategy and widens this MasterPlan's scope; see the 2026-09-12 Decision Log entry.

`Keiro/PGMQ/Job.hs` tuning surface: EP-1 owns any new validation or type changes to `JobTuning`/`JobOrdering`/`Job` (PGQ-1, PGQ-7). EP-3 consumes the same module's provisioning section (`PartitionSpec`, `ensureFifoIndex`) but must not touch the tuning types.

ADR 0001 (one-shot telemetry contract): EP-1's changes to the drain fold and `runJobOnce` must keep one process span per delivery with ack disposition recorded after settle; the acceptance suite's captured-span examples must stay green.

Cross-plan decision for ADR promotion at completion: the FIFO contract — strict per-group order is guaranteed only for configurations the API accepts, and the API must reject or degrade loudly (never silently) any configuration that cannot honor it. EP-1 implements it for tuning, EP-3 for provisioning claims.


## Progress

- [ ] EP-1: FIFO ordering decision (clamp batch size vs group-abort) recorded and implemented on the drain path.
- [ ] EP-1: Worker path made safe under the same decision; FIFO failure-branch tests (retry at head, throw at head, dead-letter at head) pass on both paths.
- [ ] EP-1: `FifoRoundRobin` gains first tests; ordering carried/validated on `Job` so `runJobOnce` cannot void FIFO silently; the deterministic batch order is observed against the released upstream fix (the SQL itself is upstream's, relocated 2026-09-12).
- [ ] EP-2: `redriveDlq` preserves original headers (group key, traceparent, app metadata); header-preservation test passes.
- [ ] EP-2: Archive/purge visibility trap closed (archive by id regardless of visibility or purge refuses with invisible rows); runbook sequence test passes.
- [ ] EP-3: keiro's partitioned-retention haddocks state the drop-unprocessed semantics, `mkPartitionSpec` guards the configurations keiro can prove wrong, and the `Dlq` haddock's expiry claim is scoped (the matching upstream documentation is relocated).
- [ ] EP-3: keiro's "GIN index that grouped reads match against" claim removed from `Keiro/PGMQ/Job.hs`; the released upstream index consumed and its effect pinned with an EXPLAIN-backed example (the index DDL itself is upstream's, relocated 2026-09-12).
- [x] (2026-09-12) Upstream scope relocated to `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts` with three child plans created there; keiro's plans 116 and 118 rewritten to consume the release rather than produce it.


## Surprises & Discoveries

- Plan authoring (2026-07-23), affects EP-2: pgmq 1.11.0 exposes no list-message-ids function and pgmq-hasql cannot parameterize table names, so "archive by id via a plain SELECT" is not implementable as imagined; EP-2 (docs/plans/117) archives via `pgmq.archive(queue, msg_ids[])` (which ignores visibility) fed by `readDlq`'s inspected ids, and guards purge via `pgmq.metrics` visible-vs-total counts.
- Plan authoring (2026-07-23), affects EP-2: worker-path DLQ rows' row-level headers are not verbatim originals — the adapter merges the failing consumer's trace headers over them; the wrapper's `original_headers` is the only correct redrive source.
- Plan authoring (2026-07-23), affects EP-3: `pgmq.create_partitioned` applies the same drop-retention to the archive table as to the active queue table, so archived rows also expire under pg_partman; EP-3 (docs/plans/118) documents both.
- Cross-initiative (2026-07-23): MasterPlan 21's EP-1 forces the shared pgmq-hs release to 0.5.0.0 (PVP-major type change), superseding the 0.4.1.0/0.4.2.0 numbers plans 116/118 assumed for their SQL-only changes if they land on the same train — reconcile version references at implementation time (see docs/masterplans/21, Surprises & Discoveries).
- Migration-status validation (2026-09-12), affects the whole initiative: this MasterPlan was **not** migrated to the pgmq project and is not superseded. The contrasting precedent is `docs/masterplans/21-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review.md`, which *was* relocated upstream and reduced to a supersession record pointing at `mori://shinzui/pgmq-hs/masterplans/3-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-review`. That upstream MasterPlan names this initiative's findings in its own out-of-scope list — "the FIFO ordering, index, and partition-retention findings owned by keiro MasterPlan 17 plans 116 and 118" — and its EP-13/EP-14/EP-15 notes repeatedly reserve the next free migration number for plans 116/118. Ownership of PGQ-1 through PGQ-7 is still keiro's.
- Migration-status validation (2026-09-12): all seven findings still reproduce at keiro `503475fa`. `withOrdering` is still a plain setter with no batch-size clamp and `Job` still carries no ordering field (`keiro-pgmq/src/Keiro/PGMQ/Job.hs:351`); `redriveDlq` still re-sends through a bare `Pgmq.sendMessage` with no headers (`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs:177`); `purgeDlq` is still the unconditional `Eff es ()` truncation (`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs:198`); the FIFO-index haddock still claims a GIN index is what grouped reads match against (`keiro-pgmq/src/Keiro/PGMQ/Job.hs:643`); and `PartitionSpec`'s retention haddock is still the harmless-cleanup-knob wording (`keiro-pgmq/src/Keiro/PGMQ/Job.hs:565`). Upstream, in pgmq-hs's vendored PGMQ 1.13.0 (`vendor/pgmq/pgmq-extension/sql/pgmq.sql`): `read_grouped`'s final `UPDATE ... RETURNING` still has no `ORDER BY` (function at line 381), `pgmq._create_fifo_index_if_not_exists` still builds `USING GIN (headers)` (line 1556), and `create_partitioned` still writes `retention_keep_table = false` into `part_config` for both the queue and the archive table (lines 1449 and 1519) — so retention still drops whole partitions of unprocessed work.
- Migration-status validation (2026-09-12), affects EP-1 and EP-3: PGMQ 1.12.0 added `pgmq.read_grouped_head` and `read_grouped_head_with_poll`, and pgmq-hs 0.6.0.0 exposes them as `readGroupedHead`/`readGroupedHeadWithPoll` on both `Pgmq` and `Pgmq.Effectful`. They return at most one message per group and compute each group's head as `MIN(msg_id)` *regardless of visibility*, so an in-flight or failed head blocks its group inside the server. That is a structural answer to PGQ-1 — `batchSize > 1` becomes safe for FIFO by construction — and it makes PGQ-2's RETURNING-order concern moot for head reads, since a batch holds at most one row per group. The primitive was not reachable from Haskell when this MasterPlan was written, so neither EP-1's clamp decision nor its upstream `ORDER BY` decision accounts for it. PGMQ 1.13.0 additionally added `premake` to `create_partitioned` (vendored SQL line 1380) and a nullable `default_partition_length` to `metrics_result` (line 867), growing the partitioned surface EP-3 documents.
- Migration-status validation (2026-09-12), affects EP-1 and EP-3: the release premises in plans 116/118 are dead. The pgmq-hs family shipped 0.6.0.0 on 2026-09-10 and keiro-pgmq already declares `>=0.6 && <0.7` (keiro commit `e4ec781b`), superseding both the 0.4.1.0/0.4.2.0 targets in the plans and the 0.5.0.0 correction recorded above. Plan 116's proposed migration filename `0003-order-read-grouped-returning.sql` is taken by `0003-notify-crash-safety-and-locking.sql`; the next free number is `0007`. In exchange, `pgmq-migration/test/Main.hs` now derives its ledger expectations from `nativeMigrationNames`, so appending a migration is a one-line change there rather than five edited expectations (recorded upstream in pgmq-hs MasterPlan 3's EP-14 notes).


## Decision Log

- Decision: Decompose into delivery path, DLQ operator path, and provisioning.
  Rationale: Matches the surfaces deployment teams interact with; disjoint acceptance tests; parallelizable.
  Date: 2026-07-23

- Decision: Upstream pgmq-hs SQL changes are in scope; shibuya-core runner changes are not.
  Rationale: The ordering and index defects live in the SQL keiro-pgmq depends on (following MasterPlan 9's precedent that upstream fixes belong to the initiative that needs them); the serial runner's continue-past-failure behavior is documented design that keiro-pgmq must stop misusing, not a defect.
  Date: 2026-07-23

- Decision: The verified-sound review results (batch-size-1 FIFO blocking, retry accounting, DLQ move atomicity, batch enqueue, header propagation, provisioning idempotency, ADR-0001 trace contract) are recorded as regression-protected ground truth; no plan may weaken them.
  Rationale: The review's value is as much what holds as what fails; child plans carry the relevant verified-sound notes so fixes do not regress them.
  Date: 2026-07-23

- Decision: The initiative stays in keiro; it is not superseded by a pgmq-project MasterPlan.
  Rationale: Validated 2026-09-12 (see Surprises & Discoveries). Unlike MasterPlan 21, which was relocated upstream and reduced to a supersession record, pgmq-hs MasterPlan 3 explicitly excludes the FIFO ordering, index, and partition-retention findings and names plans 116/118 as their owner. All seven findings still reproduce, including the three that live in upstream SQL.
  Date: 2026-09-12

- Decision: EP-1's answer to PGQ-1 is reopened. Whether to keep the `batchSize = 1` clamp or adopt PGMQ's `read_grouped_head` is decided at EP-1 implementation time; this MasterPlan records the option and its cost rather than choosing.
  Rationale: `read_grouped_head` was not reachable from Haskell when EP-1 chose the clamp, and it enforces per-group ordering in the server where an ops script cannot bypass it — the property this initiative's vision asks for. It is not a free swap: the drain path can adopt it directly, but the worker path needs a `FifoReadStrategy` constructor that `shibuya-pgmq-adapter` does not have at 0.14.0.0, which widens scope beyond the "no shibuya changes" boundary set on 2026-07-23. Choosing between a no-new-dependency clamp and a wider structurally-correct fix belongs to the plan that implements it.
  Date: 2026-09-12


- Decision: Relocate PGQ-2, PGQ-5, and PGQ-4's upstream half to pgmq-hs as
  `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`;
  keep PGQ-1, PGQ-3, PGQ-6, PGQ-7, and PGQ-4's keiro half here. This MasterPlan is narrowed, not
  superseded.
  Rationale: Those three findings are defects in pgmq-hs's SQL and documentation, reachable by every
  FIFO consumer of that library rather than by keiro alone, and the 2026-09-12 validation confirmed
  they still reproduce there. The remaining four live in `keiro-pgmq/src/Keiro/PGMQ/Job.hs` and
  `.../Dlq.hs`, code that does not exist upstream, so relocating them would have made them
  unimplementable — which is why the wholesale supersession used for
  `docs/masterplans/21-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review.md` is not
  the right shape here. Upstream's own MasterPlan 3 had already declined these findings by naming
  plans 116/118 as their owner; the relocation reverses that by giving them a home with an owner.
  Date: 2026-09-12

## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Note

2026-09-12: Validated whether this initiative had already been migrated to the pgmq project. It has
not — `mori://shinzui/pgmq-hs/masterplans/3-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-review`
places these findings out of its own scope and names plans 116/118 as their owner, and all seven
findings still reproduce in both repositories. Recorded the reproduction evidence with current file
and SQL locations; refreshed the stale pgmq-hs release and migration-number premises (family now
0.6.0.0, keiro-pgmq bounded `>=0.6 && <0.7`, next free migration `0007`); recorded the
`read_grouped_head` primitive that PGMQ 1.12.0 added and pgmq-hs 0.6.0.0 exposes, which reopens
EP-1's fix decision and makes `shibuya-pgmq-adapter` a conditional integration point; and replaced
the absolute cross-repository path in Integration Points with its canonical `mori://` URI. No child
plan status changed — all three remain Not Started.

2026-09-12 (second): Relocated the upstream half of the initiative to pgmq-hs as
`mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`
with child plans 19, 20, and 21 created there, and narrowed this MasterPlan to the five keiro-side
findings. Added the relocation banner, rewrote the scope boundary, EP-1's and EP-3's decomposition
paragraphs, the dependency graph, the pgmq-hs integration point (now consumed, not produced), and the
affected Progress bullets; recorded the relocation decision. Plans 116 and 118 had their upstream
milestones replaced with consumption milestones; plan 117 was untouched because PGQ-3 and PGQ-6 were
always keiro-only.
