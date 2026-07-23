---
id: 17
slug: harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review
title: "Harden keiro-pgmq FIFO ordering, DLQ operator paths, and provisioning surfaced by the 2026-07 pgmq review"
kind: master-plan
created_at: 2026-07-23T03:02:15Z
---

# Harden keiro-pgmq FIFO ordering, DLQ operator paths, and provisioning surfaced by the 2026-07 pgmq review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The keiro-pgmq feature wave that MasterPlan 10 shipped on 2026-06-13 — message headers and trace propagation, partitioned/unlogged provisioning with FIFO indexes, FIFO ordered delivery via message groups, and queue metrics with archive/retention — landed two days after MasterPlan 9's June audit reviewed the package, so none of it had ever been reviewed. The July 2026 pgmq review deep-read all of `keiro-pgmq/src` plus the upstream seams it rides on (the pgmq-hs family's SQL and statements, shibuya-pgmq-adapter's FIFO ingest, shibuya-core's serial runner), and an adversarial verification pass confirmed the two ordering findings against the installed pgmq 1.11.0 SQL. Seven findings survived; the two most serious are that the documented per-group strict FIFO ordering silently degrades to best-effort whenever a consumer opts into `batchSize > 1` (nothing enforces or documents the batch-size-1 requirement, no FIFO failure branch is test-pinned, and `read_grouped`'s RETURNING order is additionally plan-dependent), and that partitioned provisioning configures pg_partman to drop whole partitions of the active queue table on a retention timer regardless of whether their messages were processed — silent bulk message loss under backlog, while the package docs claim PGMQ never expires rows on its own.

After this initiative is complete: a FIFO queue delivers strict per-group order under every supported configuration — either because unsafe batch sizes are rejected at construction time or because the consumer paths abort a group on first failure — and the ordering requirement travels with the `Job` so an ops script cannot silently void it; `read_grouped` returns batches in guaranteed msg_id order; DLQ redrive preserves the original headers so a redriven FIFO message keeps its group identity and trace context; the documented DLQ inspect-archive-purge runbook can no longer destroy un-archived rows through the 30-second visibility window; partitioned retention semantics are stated truthfully with guardrails against configuring silent message loss; and the "FIFO index" either actually serves the grouped-read query shape or stops being documented as doing so.

In scope: the seven review findings (PGQ-1 through PGQ-7), their regression tests (including the currently absent FIFO failure-branch and `FifoRoundRobin` coverage), the upstream pgmq-hs SQL changes the fixes need (an ORDER BY on `read_grouped`'s RETURNING; a btree expression index that the grouped-read predicates can use), and the documentation corrections. Out of scope: the accepted design decisions re-verified by the review (pgmq-effectful's no-retry interpreter, the drain path's send-then-delete DLQ duplicate window, provision-kind drift detection); conditional reads on the worker path and PGMQ-as-integration-transport (both remain roadmap items); and any change to shibuya-core's runner (the serial worker's behavior is by design; keiro-pgmq must stop handing it unsafe batches).


## Decomposition Strategy

Three child plans, split by the operational surface a deployment team interacts with: the delivery path, the operator/DLQ path, and provisioning.

EP-1 (plan 116) owns FIFO delivery correctness: the batch-size ordering hole on both consumer paths (PGQ-1), the unordered RETURNING and the staggered-visibility hole it amplifies (PGQ-2), and the unenforced ordering-tuning mismatch (PGQ-7). One plan because the fix decision is shared: whether FIFO clamps batch size to 1 or implements group-abort determines what the RETURNING order fix must guarantee and what `runJobOnce` must validate.

EP-2 (plan 117) owns the DLQ operator path: header-preserving redrive (PGQ-3) and the archive/purge visibility trap (PGQ-6). These share `Keiro/PGMQ/Dlq.hs` and its tests, and both are operator-runbook facing.

EP-3 (plan 118) owns provisioning truth: partitioned retention semantics and guardrails (PGQ-4) and the FIFO index that cannot serve the grouped-read query shape (PGQ-5). These share the provisioning surface in `Keiro/PGMQ/Job.hs` and the upstream `pgmq-hs` DDL.

Alternatives considered. Folding EP-3 into EP-1 because both touch pgmq-hs was rejected: EP-1's upstream change is one ORDER BY in a hot read function, EP-3's is index DDL plus documentation policy — different risk profiles, and coupling them would serialize the ordering fix behind a pg_partman investigation. A single monolithic plan was rejected because the three surfaces have disjoint acceptance tests and can proceed in parallel.

ADR context: `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` is directly relevant — it fixes the one-process-span-per-delivery contract on both the worker and one-shot paths. EP-1 touches `runJobOnce` (ordering validation) and the drain fold (group handling) and must preserve that contract; the plan carries the constraint. Candidate ADR at completion: the FIFO delivery contract (what ordering is guaranteed, under which tuning, and how violations are surfaced).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Enforce FIFO group ordering under failure and batched consumption | docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md | None | None | Not Started |
| 2 | Preserve headers on DLQ redrive and make archive and purge visibility-safe | docs/plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md | None | None | Not Started |
| 3 | Correct partitioned retention semantics and the FIFO index | docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md | None | EP-1 | Not Started |


## Dependency Graph

No hard dependencies; all three plans can proceed in parallel.

EP-3 has a soft dependency on EP-1 only through the shared upstream release: both plans change `pgmq-hs` (EP-1 adds the RETURNING ORDER BY, EP-3 replaces the GIN index DDL), and shipping them in one pgmq-hs version bump avoids two consecutive dependency upgrades across the keiro consumers. If EP-1's decision is to clamp FIFO batch size to 1, its upstream ORDER BY becomes defense-in-depth rather than load-bearing, and EP-3 may carry both SQL changes in its own upstream release instead.


## Integration Points

`pgmq-hs` release (repository `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`): EP-1 and EP-3 both modify the pgmq SQL migration surface. EP-1 defines the version bump and the migration-versioning approach for changed SQL functions (pgmq installs are versioned migrations — a changed `read_grouped` needs a new migration, not an edit to `0001-install-v1.11.0.sql`); EP-3 extends the same release with the index change. Whichever lands first establishes the new migration file; the other appends to it or adds the next one. Both plans must state the resulting pgmq-hs version bound for `keiro-pgmq.cabal`.

`Keiro/PGMQ/Job.hs` tuning surface: EP-1 owns any new validation or type changes to `JobTuning`/`JobOrdering`/`Job` (PGQ-1, PGQ-7). EP-3 consumes the same module's provisioning section (`PartitionSpec`, `ensureFifoIndex`) but must not touch the tuning types.

ADR 0001 (one-shot telemetry contract): EP-1's changes to the drain fold and `runJobOnce` must keep one process span per delivery with ack disposition recorded after settle; the acceptance suite's captured-span examples must stay green.

Cross-plan decision for ADR promotion at completion: the FIFO contract — strict per-group order is guaranteed only for configurations the API accepts, and the API must reject or degrade loudly (never silently) any configuration that cannot honor it. EP-1 implements it for tuning, EP-3 for provisioning claims.


## Progress

- [ ] EP-1: FIFO ordering decision (clamp batch size vs group-abort) recorded and implemented on the drain path.
- [ ] EP-1: Worker path made safe under the same decision; FIFO failure-branch tests (retry at head, throw at head, dead-letter at head) pass on both paths.
- [ ] EP-1: `read_grouped` RETURNING ordered upstream; `FifoRoundRobin` gains first tests; ordering carried/validated on `Job` so `runJobOnce` cannot void FIFO silently.
- [ ] EP-2: `redriveDlq` preserves original headers (group key, traceparent, app metadata); header-preservation test passes.
- [ ] EP-2: Archive/purge visibility trap closed (archive by id regardless of visibility or purge refuses with invisible rows); runbook sequence test passes.
- [ ] EP-3: Partitioned retention semantics documented truthfully with a guardrail against retention shorter than processing backlog; Dlq haddock corrected.
- [ ] EP-3: FIFO index replaced with one the grouped-read predicates can use (or the index claim removed from docs); EXPLAIN-backed evidence captured.


## Surprises & Discoveries

- Plan authoring (2026-07-23), affects EP-2: pgmq 1.11.0 exposes no list-message-ids function and pgmq-hasql cannot parameterize table names, so "archive by id via a plain SELECT" is not implementable as imagined; EP-2 (docs/plans/117) archives via `pgmq.archive(queue, msg_ids[])` (which ignores visibility) fed by `readDlq`'s inspected ids, and guards purge via `pgmq.metrics` visible-vs-total counts.
- Plan authoring (2026-07-23), affects EP-2: worker-path DLQ rows' row-level headers are not verbatim originals — the adapter merges the failing consumer's trace headers over them; the wrapper's `original_headers` is the only correct redrive source.
- Plan authoring (2026-07-23), affects EP-3: `pgmq.create_partitioned` applies the same drop-retention to the archive table as to the active queue table, so archived rows also expire under pg_partman; EP-3 (docs/plans/118) documents both.
- Cross-initiative (2026-07-23): MasterPlan 21's EP-1 forces the shared pgmq-hs release to 0.5.0.0 (PVP-major type change), superseding the 0.4.1.0/0.4.2.0 numbers plans 116/118 assumed for their SQL-only changes if they land on the same train — reconcile version references at implementation time (see docs/masterplans/21, Surprises & Discoveries).


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


## Outcomes & Retrospective

(To be filled during and after implementation.)
