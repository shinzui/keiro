---
id: 16
slug: harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review
title: "Harden the durable-execution engine surfaced by the 2026-07 durable-execution review"
kind: master-plan
created_at: 2026-07-23T03:02:15Z
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

ADR context: `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md`, which does not touch the workflow engine — no relevant ADR exists for this initiative. Candidate ADRs to produce at completion: the invariant that the workflow snapshot seed plus exclusive tail read must always be recoverable from the step index (EP-1), and the resurrection/terminal-status contract (EP-4).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Make workflow journal snapshots wake-safe with a step-index fallback on await | docs/plans/112-make-workflow-journal-snapshots-wake-safe-with-a-step-index-fallback-on-await.md | None | None | Not Started |
| 2 | Deliver child failure and awakeable signals across generations and races | docs/plans/113-deliver-child-failure-and-awakeable-signals-across-generations-and-races.md | None | None | Not Started |
| 3 | Pin sleep firing to its generation and make GC cancel scheduled sleep timers | docs/plans/114-pin-sleep-firing-to-its-generation-and-make-gc-cancel-scheduled-sleep-timers.md | None | None | Not Started |
| 4 | Record patch sets at rotation and add workflow failure recovery and lease renewal | docs/plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md | None | EP-2 | Not Started |


## Dependency Graph

No hard dependencies: the four plans touch disjoint fix sites and each carries its own tests. All four can proceed in parallel subject to the integration points below.

EP-4 has a soft dependency on EP-2: EP-2's `ChildFailed` arm fix changes how child failure reaches a parent, and EP-4's resurrection API must decide what happens to a resurrected child's parent sentinel; implementing EP-4 after EP-2 avoids designing against a moving target, but EP-4 can proceed independently if it treats the pre-EP-2 arm behavior as given.

EP-3's generation-pinned sleep fire (WFX-3) removes one of the three async writers that trigger EP-4's patch-recording defect (WFX-4), and EP-4's fix removes the fragility that makes EP-3's stale writer harmful to patching. They are complementary, not ordered: each fix stands alone, and both must land for the combined property (a rotated generation always records its patch set, and a stale fire can never touch a later generation) to hold.


## Integration Points

Migration numbering in `keiro-migrations/migrations/`: EP-2 adds a migration (failure-reason column on `keiro_workflow_children`); if EP-3 or EP-4 also needs one (EP-3 is expected to be code-only; EP-4's resurrection API may need none), the plans must claim consecutive numbers starting at the next free number (0019 at authoring time) in the order the plans land, and update `keiro-migrations/migrations.lock`-adjacent test expectations per the package's embed-parity rules. Whichever plan lands first claims 0019; later plans renumber to the next free slot at landing time and must not hard-code a number claimed by an unlanded sibling.

`keiro/src/Keiro/Workflow.hs`: EP-1 edits the `Await` handler and `loadJournal` documentation; EP-4 edits `rotateGeneration` and `recordPatchSetIfFresh`. Different functions, same module — coordinate only on merge order, no shared types change.

`keiro/test/Main.hs`: all four plans add test groups. Additive appends; no coordination needed beyond keeping group names distinct.

Cross-plan decision recorded for ADR promotion at completion: the fix philosophy chosen for the whole initiative is "the step index (`keiro_workflow_steps`) is the authoritative record of journaled steps; every replay-visibility mechanism (in-memory map, snapshot seed, tail read) must fall back to it rather than assume completeness." EP-1 implements the fallback; EP-2/EP-3 rely on it as the safety net for their narrower fixes.


## Progress

- [ ] EP-1: Step-index fallback on the `Await` miss path implemented and unit-covered.
- [ ] EP-1: Snapshot-with-concurrent-wake crash-window tests (child completion and awakeable signal variants) pass; `loadJournal` haddock corrected.
- [ ] EP-2: `ChildFailed` arm case with failure-reason column and migration; cross-generation failed-child await test passes.
- [ ] EP-2: Awakeable registration moved into id-allocation transaction; signal-in-gap test passes.
- [ ] EP-2: Cancelled-then-signalled race closed with in-transaction re-read; race test passes.
- [ ] EP-3: Sleep fire payload carries its generation; stale re-fire across rotation test passes.
- [ ] EP-3: `wake_after` no longer postponed by re-arm at wake time; prompt-wake test passes.
- [ ] EP-3: GC cancels/deletes all sleep timers for terminal instances; orphan-fire resurrection test passes.
- [ ] EP-4: Patch set recorded atomically in `rotateGeneration`; pre-first-run-append test passes.
- [ ] EP-4: `resurrectFailedWorkflow` operator API shipped and documented.
- [ ] EP-4: Lease renewal during advance implemented; slow-advance duplicate-execution test passes.


## Surprises & Discoveries

- Plan authoring (2026-07-23), affects EP-4: the `WorkflowFailed` marker's journal event id is deterministic per `(name, wid, generation, failedStepName)` (`keiro/src/Keiro/Workflow.hs:942-948`), so after resurrection deletes the failed index row, a second failure at the same generation would collide with kiroku's duplicate-event-id detection and crash the marking path. EP-4 (docs/plans/115) switches failure markers to store-generated ids and records why dedupe does not regress.
- Plan authoring (2026-07-23), affects EP-3: an unconditional "refuse to fire when the instance row is missing" guard would break a legitimate recovery path — a workflow whose first operation is a sleep journals nothing and has no instance row if the process dies before `markInstanceSuspended`; the timer fire's append-and-upsert is what makes it discoverable again. EP-3 (docs/plans/114) refuses only on existing terminal rows.
- Plan authoring (2026-07-23), affects EP-1: no Eff-level step-index point query exists — the finding's `lookupStepResult` is transaction-level only (`lookupStepResultTx`, with a production call site inside `prepareJournalAppend`); EP-1 (docs/plans/112) adds the Eff wrapper it needs.


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


## Outcomes & Retrospective

(To be filled during and after implementation.)
