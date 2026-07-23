---
id: 16
slug: harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review
title: "Harden the durable-execution engine surfaced by the 2026-07 durable-execution review"
kind: master-plan
created_at: 2026-07-23T03:02:15Z
intention: intention_01ky88vm7tew7akz5pgfq0fbqg
---

# Harden the durable-execution engine surfaced by the 2026-07 durable-execution review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Keiro's durable-execution engine (the `Keiro.Workflow` effect and its satellite modules under `keiro/src/Keiro/Workflow/`) was built by MasterPlans 5 and 6 (June 2026) and hardened for crash-recovery by MasterPlan 9's EP-72/EP-73. It was the last major runtime subsystem without a dedicated deep review: the July 2026 keiki-path review (MasterPlan 14) stopped at the command/coordination/snapshot paths, and MasterPlan 14's changes (keiki 0.2 structured replay migration, workflow snapshot write alignment) landed underneath the engine without its replay semantics being re-examined. The July 2026 durable-execution review closed that gap: two reviewer passes over every line of `Keiro/Workflow.hs`, `Workflow/{Types,Schema,Instance,Resume,Snapshot,Awakeable,Child,Sleep,Gc}.hs`, `Keiro/Wake.hs`, and the workflow SQL migrations, followed by an adversarial verification pass that attempted to refute each finding against both the keiro and kiroku sources. Every finding below survived verification; the verification reports' file:line evidence is embedded in the child plans.

The review confirmed the engine's foundations are sound — the atomic journal-append transaction (advisory lock, in-transaction index re-check, instance upsert), terminal-status freeze, rotation ordering, wake-source transactional atomicity, resume-worker failure isolation, and LISTEN/NOTIFY push delivery all hold. The confirmed defects cluster in the interactions between features that were designed in separate plans and never exercised together: journal snapshots versus concurrent wake appends, sleep timers versus generation rotation, GC versus still-scheduled timers, rotation versus the patch API, and child failure versus cross-generation await.

After this initiative is complete: a workflow using journal snapshots can never be permanently stalled by a wake completion that landed while its run was mid-flight; a parent awaiting a failed child is woken with a typed failure on any generation instead of suspending forever; an awakeable id can be signalled the moment it escapes the workflow, and a signal racing a cancel can no longer produce both compensation and completion; a fired sleep wakes its workflow promptly instead of being postponed by a full extra sleep duration; a stale sleep re-fire can no longer resolve a later generation's sleep early; garbage collection can no longer leave orphan timers that resurrect and re-execute a cancelled workflow; the patch API records its decision set reliably on every generation; operators get a supported way to resurrect a terminally failed workflow instead of undocumented manual SQL; and slow workflows no longer silently lose their instance lease mid-advance.

In scope: all ten confirmed findings (WFC-1 through WFC-4 from the core pass, WFX-1 through WFX-7 from the extensions pass; WFC-2 and WFX-5 are the same defect found independently), their regression tests, and the documentation corrections they force (the `loadJournal` haddock states an invariant the code does not deliver). Out of scope: any change to kiroku (the engine's append/read substrate was verified sound; the exclusive tail cursor is correct behavior the fix must respect, not change); any change to keiki (the engine consumes no keiki API — verified during the review); the accepted known items (kiroku `$all` append serialization ceiling, shard cold-start spread, rebalance-by-stealing, timer/outbox push workers); and new workflow features.


## Decomposition Strategy

The findings cluster by the module seams where two features interact, and each cluster is independently verifiable with its own crash-window tests, so the decomposition follows those seams rather than finding severity. Four child plans.

EP-1 (plan 112) owns the single critical finding: journal snapshots omitting concurrently journaled wake completions (WFC-1). Its fix — consulting the authoritative `keiro_workflow_steps` index on the `Await` miss path before arming — is deliberately chosen over snapshot invalidation because it closes the whole visibility class regardless of how the snapshot became stale, and it also masks the same-generation variant of the child-failure gap. It is its own plan because it touches the engine's hottest path (the `Await` handler and `loadJournal`) and needs the most careful concurrency tests.

EP-2 (plan 113) owns wake-source delivery correctness at the row level: the missing `ChildFailed` arm case including the schema change for a failure-reason column (WFC-2/WFX-5), awakeable registration moved into the id-allocation transaction (WFX-2), and the cancelled-then-signalled race (WFX-7). These share `Workflow/Awakeable.hs`, `Workflow/Child.hs`, and their schema modules.

EP-3 (plan 114) owns the sleep-timer lifecycle: generation-pinned fire payloads (WFX-3), the `wake_after` overwrite on re-arm (WFX-1), and GC cancelling scheduled sleep timers plus an instance guard in the fire action (WFX-6). These share `Workflow/Sleep.hs`, `Workflow/Gc.hs`, and the timer schema.

EP-4 (plan 115) owns lifecycle policy: recording the patch set atomically inside `rotateGeneration` (WFX-4), a supported resurrect-failed-workflow operator API plus retry-ceiling documentation (WFC-3), and lease renewal during long advances (WFC-4). These are policy-level changes to `Workflow.hs` rotation and `Workflow/{Instance,Resume}.hs`.

Alternatives considered. A severity-ordered decomposition was rejected for the same reason MasterPlan 9 rejected it: it couples unrelated modules in every plan. Folding EP-2 into EP-1 (both touch await/arm paths) was rejected because EP-1 must stay small and reviewable — it changes replay semantics on the hot path — while EP-2 carries a migration. Merging EP-3 and EP-4 (both touch rotation-adjacent code) was rejected because EP-3's fixes are mechanical correctness repairs with crash-window tests, while EP-4 makes policy decisions (resurrection semantics, lease-renewal cadence) that deserve their own Decision Log.

ADR context at authoring: `docs/adr/` contained only `0001-keiro-pgmq-job-processing-telemetry-contract.md`, which does not touch the workflow engine. Since authoring, `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md` established the complementary rule that snapshots are advisory cached seeds whose compatibility is checked separately from completeness. EP-1 produced `docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md` for the invariant that a workflow snapshot seed plus exclusive tail read must remain recoverable from the step index. EP-2 produced `docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md` for the durable row-lifecycle and terminal-race contract. EP-3 produced `docs/adr/0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md` for generation-pinned firing, first-arm ownership of `wake_after`, and terminal/GC timer arbitration. EP-4 produced `docs/adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md` for the resurrection and terminal-status contract.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Make workflow journal snapshots wake-safe with a step-index fallback on await | docs/plans/112-make-workflow-journal-snapshots-wake-safe-with-a-step-index-fallback-on-await.md | None | None | Complete |
| 2 | Deliver child failure and awakeable signals across generations and races | docs/plans/113-deliver-child-failure-and-awakeable-signals-across-generations-and-races.md | None | None | Complete |
| 3 | Pin sleep firing to its generation and make GC cancel scheduled sleep timers | docs/plans/114-pin-sleep-firing-to-its-generation-and-make-gc-cancel-scheduled-sleep-timers.md | None | None | Complete |
| 4 | Record patch sets at rotation and add workflow failure recovery and lease renewal | docs/plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md | None | EP-2 | Complete |


## Dependency Graph

No hard dependencies: the four plans touch disjoint fix sites and each carries its own tests. All four can proceed in parallel subject to the integration points below.

EP-4 has a soft dependency on EP-2: EP-2's `ChildFailed` arm fix changes how child failure reaches a parent, and EP-4's resurrection API must decide what happens to a resurrected child's parent sentinel; implementing EP-4 after EP-2 avoids designing against a moving target, but EP-4 can proceed independently if it treats the pre-EP-2 arm behavior as given.

EP-3's generation-pinned sleep fire (WFX-3) removes one of the three async writers that trigger EP-4's patch-recording defect (WFX-4), and EP-4's fix removes the fragility that makes EP-3's stale writer harmful to patching. They are complementary, not ordered: each fix stands alone, and both must land for the combined property (a rotated generation always records its patch set, and a stale fire can never touch a later generation) to hold.


## Integration Points

Migration numbering in `keiro-migrations/migrations/`: the authoring-time next-free number was stale by implementation. The branch already contained `0019-keiro-snapshots-state-shape-hash.sql`, so EP-2 claims `0020-keiro-workflow-children-failure-reason.sql`. If EP-3 or EP-4 also needs a migration (EP-3 is expected to be code-only; EP-4's resurrection API may need none), it must start at 0021 and reconcile the package's exact manifest/count tests.

`keiro/src/Keiro/Workflow.hs`: EP-1 edits the `Await` handler and `loadJournal` documentation; EP-4 edits `rotateGeneration` and `recordPatchSetIfFresh`. Different functions, same module — coordinate only on merge order, no shared types change.

`keiro/test/Main.hs`: all four plans add test groups. Additive appends; no coordination needed beyond keeping group names distinct.

Cross-plan decision recorded in `docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md`: the fix philosophy chosen for the whole initiative is "the step index (`keiro_workflow_steps`) is the authoritative record of journaled steps; every replay-visibility mechanism (in-memory map, snapshot seed, tail read) must fall back to it rather than assume completeness." EP-1 implements the fallback; EP-2/EP-3 rely on it as the safety net for their narrower fixes.


## Progress

- [x] (2026-07-23 20:11Z) EP-1: Step-index fallback on the `Await` miss path implemented and unit-covered.
- [x] (2026-07-23 20:11Z) EP-1: Snapshot-with-concurrent-wake crash-window tests (child completion and awakeable signal variants) pass; `loadJournal` haddock corrected.
- [x] (2026-07-23 20:34Z) EP-2: `ChildFailed` arm case with failure-reason column and migration; cross-generation failed-child await test passes.
- [x] (2026-07-23 20:34Z) EP-2: Awakeable registration moved into id-allocation transaction; signal-in-gap test passes.
- [x] (2026-07-23 20:34Z) EP-2: Cancelled-then-signalled race closed with in-transaction re-read; race test passes.
- [x] (2026-07-23 20:57Z) EP-3: Sleep fire payload carries its generation; stale re-fire across rotation test passes.
- [x] (2026-07-23 20:57Z) EP-3: `wake_after` no longer postponed by re-arm at wake time; prompt-wake test passes.
- [x] (2026-07-23 20:57Z) EP-3: GC cancels/deletes all sleep timers for terminal instances; orphan-fire resurrection test passes.
- [x] (2026-07-23 21:04Z) EP-4: Patch set recorded atomically in `rotateGeneration`; pre-first-run-append test passes.
- [x] (2026-07-23 21:15Z) EP-4: `resurrectFailedWorkflow` operator API shipped and documented.
- [x] (2026-07-23 21:25Z) EP-4: Lease renewal during advance implemented; slow-advance duplicate-execution test passes.


## Surprises & Discoveries

- Plan authoring (2026-07-23), affects EP-4: the `WorkflowFailed` marker's journal event id is deterministic per `(name, wid, generation, failedStepName)` (`keiro/src/Keiro/Workflow.hs:942-948`), so after resurrection deletes the failed index row, a second failure at the same generation would collide with kiroku's duplicate-event-id detection and crash the marking path. EP-4 (docs/plans/115) switches failure markers to store-generated ids and records why dedupe does not regress.
- Plan authoring (2026-07-23), affects EP-3: an unconditional "refuse to fire when the instance row is missing" guard would break a legitimate recovery path — a workflow whose first operation is a sleep journals nothing and has no instance row if the process dies before `markInstanceSuspended`; the timer fire's append-and-upsert is what makes it discoverable again. EP-3 (docs/plans/114) refuses only on existing terminal rows.
- Plan authoring (2026-07-23), affects EP-1: no Eff-level step-index point query exists — the finding's `lookupStepResult` is transaction-level only (`lookupStepResultTx`, with a production call site inside `prepareJournalAppend`); EP-1 (docs/plans/112) adds the Eff wrapper it needs.
- EP-1 implementation (2026-07-23), confirms EP-2's WFX-2 setup constraint: `awakeableNamed` currently registers its pending row only when the returned await action arms, so signalling immediately after allocation returns `False`. EP-1 pre-arms awakeables through an ordinary unresolved run before constructing its stale-map windows; EP-2 remains responsible for closing the allocation-to-registration gap.
- EP-2 implementation (2026-07-23): migration 0019 was already occupied by `0019-keiro-snapshots-state-shape-hash.sql`, so the child failure-reason migration is 0020. The native migration suite now pins 20 Keiro migrations and 28 composed migrations.
- EP-3 implementation (2026-07-23): the terminal-instance fire guard must not
  reject a missing instance row. A first-operation sleep can be armed before
  the suspended instance write; the focused recovery test proves its timer
  append recreates a running instance, while an existing terminal row cancels
  the timer without appending.
- EP-4 milestone 2 (2026-07-23): the existing append lock and step-index check
  are sufficient to deduplicate concurrent terminal failure writers, so only
  `WorkflowFailed` can safely use store-generated event ids. Two failures on
  the same resurrected generation produced distinct journal ids while all 370
  tests remained green.
- EP-4 milestone 3 (2026-07-23): a boundary heartbeat must renew for longer
  than the action that follows it; it cannot make an arbitrarily long action
  exclusive. The focused test proves renewal prevents takeover when
  `leaseTtl` exceeds that action, and the guide now makes this sizing rule
  explicit. Lost ownership is detected before the next fresh boundary and
  consumes no crash attempt.


## Decision Log

- Decision: Decompose by module seam (snapshot/await, wake-source rows, sleep/GC, lifecycle policy) into four plans with no hard dependencies.
  Rationale: Each seam is independently verifiable with its own crash-window tests; severity-ordered or single-plan alternatives couple unrelated modules (same rationale MasterPlan 9 recorded).
  Date: 2026-07-23

- Decision: Fix WFC-1 with a step-index fallback on the `Await` miss path rather than snapshot invalidation or index-derived snapshots.
  Rationale: The fallback closes the entire stale-visibility class regardless of cause, reuses an existing indexed point query, and needs no write-path changes; invalidation repairs only the specific writer that noticed the staleness.
  Date: 2026-07-23

- Decision: Keep kiroku and keiki out of scope.
  Rationale: The review verified the kiroku append/read substrate and confirmed the engine consumes no keiki API; every confirmed defect is fixable keiro-side.
  Date: 2026-07-23

- Decision: The review's accepted-known items (kiroku `$all` ceiling, shard cold-start spread, push workers for timers/outbox) stay accepted; the narrow advisory-vs-`$all` lock-order inversion found in the core pass (childCompletionHook racing appendFailedChildAndWakeParent) is documented, not fixed.
  Rationale: Verified consequence is a transient-classified deadlock abort and retry (~1 s hiccup), not a stall; fixing lock order would complicate every composed append for no behavioral gain.
  Date: 2026-07-23

- Decision: Record the EP-1 replay-visibility rule in `docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md`.
  Rationale: The step-index fallback constrains all future workflow append paths and is distinct from snapshot codec compatibility in ADR 0003, so it must survive beyond the implementation plan.
  Date: 2026-07-23

- Decision: Record the EP-2 wake-source lifecycle rule in `docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md`.
  Rationale: Register-before-exposure, cross-generation child failure delivery, and in-transaction terminal arbitration constrain future wake-source implementations beyond the local fixes in plan 113.
  Date: 2026-07-23

- Decision: Record the EP-3 sleep-timer ownership and lifecycle rule in
  `docs/adr/0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md`.
  Rationale: Generation ownership, first-arm wake-hint ownership, and
  terminal/GC arbitration are shared constraints on future sleep scheduling,
  firing, rotation, and collection.
  Date: 2026-07-23

- Decision: Record the EP-4 resurrection and terminal-status rule in
  `docs/adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md`.
  Rationale: Preserving append-only failure history while transactionally
  reviving its derived instance, step-index, and child-link state constrains
  every future workflow recovery tool.
  Date: 2026-07-23


## Outcomes & Retrospective

- EP-1 closed snapshot-shadowed wake delivery with a generation-scoped
  step-index fallback and established ADR 5.
- EP-2 closed all three row-level wake-source findings. Child failure reasons
  are durable through migration 0020 and deliver on later parent generations;
  awakeable ids cannot escape before their rows exist; and signal/cancel
  arbitration now decides journal delivery from transactional state. ADR 6
  records the shared lifecycle rule.
- EP-2 validation finished with 10 migration examples and 360 workflow examples,
  all passing. EP-3 and EP-4 were still outstanding at that milestone.
- EP-3 closed stale cross-generation sleep firing, wake-hint postponement, and
  post-GC resurrection without a migration. Focused crash-window tests and all
  366 workflow examples pass; ADR 7 records the durable timer lifecycle.
  EP-4 was still outstanding at that milestone.
- EP-4 makes patch recording immune to pre-first-run wake appends, provides
  transactional terminal-failure resurrection (including failed-child revival
  and safe repeated failure on one generation), and renews workflow leases at
  fresh side-effect boundaries. Lost leases stop cleanly without a crash
  attempt. ADR 8 records the failure-history contract.
- The initiative closes all ten verified durable-execution findings across its
  four child plans. The final `cabal test keiro-test` run passes 372 examples
  with 0 failures; no work remains in the Exec-Plan registry.
