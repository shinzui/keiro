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


EP-1 (116) owns batching/ordering validation and failure-path tests, plus optional consumption
of the client-ordering fix. EP-2 (117) owns header-preserving DLQ redrive and visibility-safe
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
| 1 | Enforce FIFO group ordering under failure and batched consumption | docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md | None | None | Not Started |
| 2 | Preserve headers on DLQ redrive and make archive and purge visibility-safe | docs/plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md | None | None | Not Started |
| 3 | Correct partitioned retention semantics and the FIFO index | docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md | None | EP-1 shared Job.hs coordination | Not Started |

## Dependency Graph


All three consumer workstreams can proceed independently. EP-1's M4 waits only for a verified
client release/candidate when observing that new client behavior; M1-M3 do not wait. EP-3's
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

**Client dependency.** `mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order`
owns four client SELECT wrappers. If consumed, require the actual released pgmq-hasql client
version through the library dependency, not merely a test-suite pgmq-migration bound. Verify
Hackage and repository tags before selecting a bound; isolated candidates are not releases.
Do not infer a promised 0.6.1.0 release from earlier plan drafts.

**Supplemental index.** `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`
owns measurements and optional operator DDL. Keep q_<queue>_fifo_idx GIN and helpers intact.
The distinct group_lookup index is not installed by ensureFifoIndex, normal reconciliation,
or startup. Presence reports still describe the conventional index. EP-3 may validate the
measured procedure in a disposable queue without maintaining a duplicate benchmark subsystem.

**Adapter boundary.** `mori://shinzui/shibuya-pgmq-adapter` is not changed by these plans.
If EP-1 elects grouped heads on both consumer paths, verify available strategies through Mori
and explicitly revise the adapter scope first. Do not silently claim a new head strategy or
change the shared runner. Batch-size enforcement remains the existing bounded implementation
proposal until that decision is resolved in EP-1.

## Progress


- [ ] EP-1: Consumer batching/order-tuning decision implemented on drain and worker paths, with failure and round-robin regressions.
- [ ] EP-1: Consume client result-order behavior when verified available; no SQL migration dependency.
- [ ] EP-2: Header-preserving redrive and visibility-safe archive/purge plus operator tests.
- [ ] EP-3: Accurate retention policy/Haddocks and scoped constructor guardrail.
- [ ] EP-3: Accurate conventional GIN description and measured optional supplemental-index guidance, or explicit negative/pending result.
- [x] 2026-09-12: Reconciled shared pgmq-hs guidance with the user's no-overrides/additive-index constraint.
- [ ] Final integration: tests, changelogs and consumer ADR distillation complete.

## Surprises & Discoveries


The cross-repository audit found a clean worktree at 14dd9036. The relocation commit 9b93112b
still contained obsolete SQL-migration and automatic GIN-replacement expectations. The later
14dd9036 commit concerns a reaction-API blocker; affected package changes since 503475fa were
Cabal formatting only. No new FIFO/index source implementation was found. This is a local
checkout audit, not a claim about unobserved remote branches or private agent state.

The prior plan also treated head reads/batch clamping too broadly as a processing guarantee.
They constrain selection; lease expiry, acknowledgement discipline and other consumers still
matter. Supplemental indexing can improve a workload without fixing FIFO processing semantics.

## Decision Log


2026-09-12: Preserve the three consumer workstreams and their telemetry/ownership boundaries.
Shared concerns remain owned by `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`, with canonical references for all handoffs.

2026-09-12: Supersede all previous server-body, migration-number, replacement-index and shared
release assumptions. No extension SQL overrides. Consume client result order and optional
additive index evidence only. Existing GIN and name-based presence reports remain unchanged.

2026-09-12: Keep EP-1's clamp-versus-head decision local and explicit. Adopting an adapter head
strategy expands scope and must be coordinated before implementation. Either route must retain
consumer lease/failure/telemetry responsibilities, not claim unconditional processing success.

## Outcomes & Retrospective


Cross-repository plan consistency corrected. No Keiro source was changed or runtime suite run
by this audit; consumer implementation remains pending.

Revision note (2026-09-12): Replaced obsolete downstream expectations of pgmq SQL migrations,
automatic GIN conversion and shared bounds with the accepted client-only/additive-index contract.
