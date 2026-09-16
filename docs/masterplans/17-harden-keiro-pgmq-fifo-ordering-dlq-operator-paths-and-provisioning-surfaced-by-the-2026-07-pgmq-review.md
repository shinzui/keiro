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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-12T17:28:45Z
      mode: "update"
      note: "Audited local downstream changes and aligned handoffs with client-only ordering, optional additive indexes, and no SQL overrides."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T12:51:21Z
      mode: "implement"
      note: "Started EP-1 and registered the grouped-head adapter release dependency"
---

# Harden keiro-pgmq FIFO ordering, DLQ operator paths, and provisioning surfaced by the 2026-07 pgmq review

This MasterPlan remains active and Keiro-owned. Keep its living sections current.

## Vision & Scope


Fix Keiro consumer batching/order-tuning safety, preserve DLQ redrive headers, make archive/purge
operations visibility-safe, and document retention/provisioning accurately. The package's job
and DLQ work remains here; shared client/index/documentation work belongs to `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`.

The user prohibits overriding extension-owned SQL, including native installations, and permits
adding a separately owned index. pgmq-hs plans 19/20 now mean client outer ORDER BY msg_id
and optional measured q_<queue>_group_lookup_idx, respectively. Neither supplies a new FIFO
migration, replaces upstream GIN/helpers nor promises raw-SQL function result order. Client
sorting preserves ascending IDs within each group but not group-contiguous output. Round-robin
layering remains upstream-owned. Consumer lease renewal, acknowledgement and side effects
remain necessary; neither batching constraints nor head reads guarantee processing success alone.

Keiro owns PGQ-1/PGQ-7 consumer validation, PGQ-3 redrive, PGQ-6 archive/purge, and PGQ-4
consumer retention policy. Shared PGQ-2/PGQ-5 evidence can be consumed without duplicating
SQL. No extension override, native migration numbering, automatic index replacement or
Hackage publication belongs to this plan. Historical migration bytes remain immutable.

## Decomposition Strategy


EP-1 (116) owns batching/ordering validation and failure-path tests plus consumption of the
grouped-head adapter release produced by
`mori://shinzui/shibuya-pgmq-adapter/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter`.
EP-2 (117) owns header-preserving DLQ redrive and visibility-safe
operator actions. EP-3 (118) owns retention policy/Haddocks and truthful supplemental-index
guidance. Preserve each child's existing consumer milestones; upstream constraints do not
remove the need for those fixes.

The local telemetry decision in docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md
requires one process span per delivery and settlement-aware acknowledgement; consumer changes
must retain its tests. The no-override/additive-index boundary is recorded by the owning
pgmq-hs MasterPlan cited above and its ADR (mori://shinzui/pgmq-hs plus project-relative
`docs/adr/fifo-native-overrides-and-index-upgrade-boundary.md`; artifact-level URI pending).
Promote actual consumer FIFO decisions into the local ADR corpus at implementation completion.

## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Enforce FIFO group ordering under failure and batched consumption | docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md | Adapter plan 7 release for Keiro M2-M4 | None | Complete |
| 2 | Preserve headers on DLQ redrive and make archive and purge visibility-safe | docs/plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md | None | None | Not Started |
| 3 | Correct partitioned retention semantics and the FIFO index | docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md | None | EP-1 shared Job.hs coordination | Not Started |

## Dependency Graph


All three consumer workstreams can proceed independently. EP-1 now contains a cross-repository
M1: the adapter plan can proceed immediately, while Keiro M2-M4 require its verified Hackage
release and upstream tag. EP-3's
index recommendation depends on measured supplemental-index evidence, not a pgmq-migration
release. Its retention and inaccurate-GIN-claim corrections can proceed immediately. There
is no shared 0007/0008 allocation or joint index/order package-bound bump.

## Integration Points


**Job.hs.** EP-1 owns Job/JobOrdering/JobTuning validation and the drain/worker paths.
EP-3 owns PartitionSpec, provisioning policy and provisioning Haddocks. Coordinate edits
without weakening telemetry or consumer failure tests.

**Dlq.hs.** EP-2 owns redrive/archive/purge behavior and runbook prose. EP-3 owns the narrowly
scoped expiry statement, documenting standard DLQs separately from partitioned queue/archive
retention. Time and numeric retention differ; no exact per-row expiry timer is promised.

**Client dependency.** Released pgmq-hs 0.6.0.0 already exposes grouped-head reads and remains
the required client family. The pending deterministic-result-order plan
`mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order` is not a
dependency: grouped heads return at most one member per group and Keiro promises no order
between groups.

**Supplemental index.** `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`
owns measurements and optional operator DDL. Keep q_<queue>_fifo_idx GIN and helpers intact.
The distinct group_lookup index is not installed by ensureFifoIndex, normal reconciliation,
or startup. Presence reports still describe the conventional index. EP-3 may validate the
measured procedure in a disposable queue without maintaining a duplicate benchmark subsystem.

**Adapter boundary.**
`mori://shinzui/shibuya-pgmq-adapter/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter`
owns the exported `HeadPerGroup` strategy, standard/long-poll dispatch, adapter integration
tests, safe-drain performance evidence, and adapter release. EP-1 consumes the actual release;
it does not duplicate the polling runner or use a local source override. Keiro still validates
its job/tuning contract before constructing the adapter.

## Progress


- [x] 2026-09-16: Started EP-1 and created the upstream grouped-head adapter plan with the shared intention.
- [x] 2026-09-16: EP-1 adapter 0.16.0.0 released to Hackage and GitHub with annotated tag
  `v0.16.0.0`; grouped-head dispatch, integration tests, and the three-fixture performance
  matrix passed.
- [x] 2026-09-16: EP-1 consumer batching/order-tuning contract implemented on drain and worker
  paths, with retry, throw, delay, dead-letter, worker, batch, mismatch, default-entry-point, and
  legacy-mode regressions plus DSL, documentation, and ADR coverage.
- [ ] EP-2: Header-preserving redrive and visibility-safe archive/purge plus operator tests.
- [ ] EP-3: Accurate retention policy/Haddocks and scoped constructor guardrail.
- [ ] EP-3: Accurate conventional GIN description and measured optional supplemental-index guidance, or explicit negative/pending result.
- [x] 2026-09-12: Reconciled shared pgmq-hs guidance with the user's no-overrides/additive-index constraint.
- [x] 2026-09-16: EP-1 final integration selected the Hackage 0.16.0.0 tarball without a local
  package path. The full build, PGMQ (78/0/2 pending), DSL (743/0), focused conformance/ops/example,
  strict ADR, formatting, and flake validations passed.

## Surprises & Discoveries


The cross-repository audit found a clean worktree at 14dd9036. The relocation commit 9b93112b
still contained obsolete SQL-migration and automatic GIN-replacement expectations. The later
14dd9036 commit concerns a reaction-API blocker; affected package changes since 503475fa were
Cabal formatting only. No new FIFO/index source implementation was found. This is a local
checkout audit, not a claim about unobserved remote branches or private agent state.

The prior plan also treated head reads/batch clamping too broadly as a processing guarantee.
They constrain selection; lease expiry, acknowledgement discipline and other consumers still
matter. Supplemental indexing can improve a workload without fixing FIFO processing semantics.

The adapter audit found released pgmq-hs 0.6.0.0 already provides grouped-head standard and
long-poll effects, but released adapter 0.15.0.0 has no strategy that dispatches them. The
missing boundary is now explicit in upstream plan 7 rather than hidden inside Keiro.

EP-1's Keiro implementation proves that grouped-head selection, rather than result sorting,
closes the batching failure hole. Mutating the drain back to legacy grouped reads exposed a
same-group successor after a thrown head; forcing quantity one changed the sixteen-group trace
from one receive to sixteen. Both mutations were restored before final validation.

## Decision Log


2026-09-12: Preserve the three consumer workstreams and their telemetry/ownership boundaries.
Shared concerns remain owned by `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`, with canonical references for all handoffs.

2026-09-12: Supersede all previous server-body, migration-number, replacement-index and shared
release assumptions. No extension SQL overrides. Consume client result order and optional
additive index evidence only. Existing GIN and name-based presence reports remain unchanged.

2026-09-12: Keep EP-1's clamp-versus-head decision local and explicit. Adopting an adapter head
strategy expands scope and must be coordinated before implementation. Either route must retain
consumer lease/failure/telemetry responsibilities, not claim unconditional processing success.

2026-09-16: Resolve EP-1 in favor of a distinct grouped-head mode. The adapter owns
`HeadPerGroup` and its release; Keiro owns `FifoHeads`, configuration rejection, drain dispatch,
and failure-path proofs. Deterministic cross-group result order is explicitly not a dependency.

## Outcomes & Retrospective


Cross-repository plan consistency is corrected and EP-1 is complete. Jobs now declare ordering,
invalid or contradictory tuning fails before reads, grouped heads safely preserve multi-group
batches, the DSL owns the `fifo-heads` contract, and ADR-44 records the consumer decision. The
adapter 0.16.0.0 release is published and tagged, its benchmark met the release gate, and Keiro's
final build and tests consumed the Hackage tarball without a local source path. The MasterPlan
remains active for EP-2 and EP-3.

Revision note (2026-09-12): Replaced obsolete downstream expectations of pgmq SQL migrations,
automatic GIN conversion and shared bounds with the accepted client-only/additive-index contract.

Revision note (2026-09-16): Started EP-1, registered the upstream grouped-head adapter plan,
and replaced the prior unchanged-adapter/client-ordering assumptions with the released-head API
and explicit adapter-release dependency.

Revision note (2026-09-16): Implemented EP-1's Keiro runtime, DSL, adversarial tests,
documentation, changelogs, and ADR; retained adapter publication as the final hard gate.

Revision note (2026-09-16): Published the adapter release, completed Hackage-only integration
and the final validation matrix, and marked EP-1 complete.
