---
id: 30
slug: harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit
title: "Harden and scale the durable-execution engine surfaced by the 2026-08 re-audit"
kind: master-plan
created_at: 2026-08-06T00:10:36Z
intention: "intention_01kza6gjs5eg79n2hyrah7wnnn"
---

# Harden and scale the durable-execution engine surfaced by the 2026-08 re-audit

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The durable-execution engine (`Keiro.Workflow` and its satellite modules under
`keiro/src/Keiro/Workflow/`, plus `Keiro.Wake`) was deep-reviewed in July 2026;
MasterPlan 16 closed all ten of that review's findings and recorded ADRs 5 through 8.
The August 2026 re-audit re-read the post-fix engine end to end with a performance
focus and confirmed the correctness core holds: the atomic journal-append transaction,
the generation-scoped step-index fallback, arm-side repair from durable wake-source
rows, generation-pinned sleep firing, terminal-status freeze, and transactional
resurrection all behave as ADRs 5–8 specify. What the re-audit surfaced instead is
that the engine's *idle* cost scales with the number of suspended workflows, plus a
short tail of low-severity correctness and robustness edges, mostly in code written
after the July review passes.

The headline problem: `findUnfinishedWorkflowIds` returns every non-terminal workflow
whose `wake_after` is null or due, and only sleeps ever set `wake_after`
(`Keiro.Workflow.Sleep`). Every workflow suspended on an awakeable or a child is
therefore claimed, journal-replayed, re-armed, and re-suspended on every resume pass —
each second by default, and on *every store append* under the push-aware worker. Each
such no-progress re-run costs roughly a dozen database round-trips plus a full journal
replay under the default `snapshotPolicy = Never`. A deployment with a thousand parked
approval flows pays tens of thousands of idle queries per second. Compounding it, the
discovery query's `status NOT IN ('completed','cancelled','failed')` predicate cannot
use the partial index `keiro_workflows_active_idx` (whose predicate is
`status IN ('running','suspended')` — Postgres does not consult the table's CHECK
constraint when proving partial-index implication), so every pass also sequentially
scans `keiro_workflows`.

After this initiative is complete: a workflow suspended on an awakeable, a child, or a
future-dated sleep costs the resume worker nothing until something actually happens to
it — every wake and cancel path flips the instance row so discovery is exact, and the
discovery query is index-aligned; a direct run overlapping a terminal failure marker
stops at the next step boundary exactly as it already does for cancellation, with the
terminal checks folded into the append transaction so the hot path gets *cheaper* while
getting stricter; the deterministic identity scheme hashes UTF-8 bytes so non-ASCII
workflow names, ids, step names, or patch ids can no longer collide into a wedged
append path; a stale sleep re-fire can no longer erase the live sleep's discovery hint;
the resume pass can advance many instances concurrently and the timer worker can drain
in batches; the crash-recording and GC workers survive races and transient errors
instead of aborting a pass or dying; and the wake-source authoring contract plus the
engine's scale posture are documented for adopters.

In scope: the eight re-audit findings (suspended-workflow hot-polling; the discovery
index mismatch; the missing `failed` re-check at step boundaries; the unconditional
`wake_after` clear on stale sleep re-fires; codepoint-truncated deterministic ids; the
`recordCrashTx` zero-row decoder abort; the GC worker's missing per-pass error
isolation and always-equal summary; stale haddocks), the throughput improvements the
audit recommended (intra-pass resume concurrency, batched timer claim), and the
documentation the audit found missing (the wake-source durable-row contract, rotation
semantics for outstanding awakeables, and an honest scale-posture note in the user
roadmap and production-status docs).

Out of scope: any change to kiroku or keiki (the substrate was re-verified sound and
untouched); prefix subscriptions and exactly-once async projections (upstream-dependent,
already tracked in `docs/user/roadmap.md` Phase 3); the accepted-known items MasterPlan
16 recorded (the kiroku `$all` advisory-lock-order inversion, shard cold-start spread,
rebalance-by-stealing) which remain accepted; the orphan pending awakeable row left by
a crash inside the allocation window, which ADR 6 already accepts and workflow GC
already collects; and `PositionWait` push wiring, which stays a Phase 3 roadmap item.


## Decomposition Strategy

The findings cluster by which contract they change, not by module, and each cluster is
independently verifiable with its own tests, so the decomposition follows contracts.
Five child plans.

EP-1 (plan 200) owns the discovery contract: when is a workflow returned by
`findUnfinishedWorkflowIds`? It ships the index-alignment fix first (a one-line
predicate rewrite that is safe and useful on its own), then makes suspension quiescent:
every wake path already flips the instance row to `running` inside
`prepareJournalAppend`'s transaction, so the plan's substance is closing the two paths
that do not touch the instance row (`cancelAwakeable`, which writes no journal entry,
and the stale-sleep-re-fire `wake_after` clear in `workflowSleepFireAction`), then
narrowing discovery so a `suspended` instance with an undue or absent wake hint is not
returned. This changes the engine's liveness argument — today the hot poll is what
notices a cancelled awakeable — so it carries the initiative's most careful
crash-window tests and a new ADR.

EP-2 (plan 201) owns the append-boundary contract: what does the engine check before
and while committing a step? It folds the cancellation *and* failure existence checks
into the journal-append transaction (under the advisory lock that already serializes
same-step writers), closing the asymmetry where `checkCancellationPending` re-checks
`cancelledStepName` at every boundary but nothing re-checks `failedStepName` after run
entry, and simultaneously removing two round-trips per fresh step. It also collapses
the two entry `stepExists` calls into one query and threads the once-resolved
generation through claim, run, and suspend instead of recomputing `MAX(generation)`
three to four times per re-invocation.

EP-3 (plan 202) owns the identity contract: how deterministic ids are derived from
text. `deterministicJournalId`, `sleepTimerId`, `deterministicAwakeableId`, and
`Keiro.ProcessManager.deterministicCommandId` all feed
`fmap (fromIntegral . fromEnum) . Text.unpack` into UUIDv5, truncating each character
to its codepoint modulo 256; distinct non-ASCII inputs can collide and wedge the append
path with duplicate-event-id conflicts. The fix hashes UTF-8 bytes, which is
byte-identical for ASCII inputs — so every id in any existing deployment that used
ASCII identities is unchanged — and it is recorded as an ADR because the derivation is
replay identity that every future deploy must preserve.

EP-4 (plan 203) owns worker throughput and pass robustness: bounded concurrent
advancement inside `resumeWorkflowsOnce` (the leases already make concurrent
advancement safe across processes; this exploits the same safety within one pass),
batched claim for the timer worker (today one due timer per invocation), tolerance for
the `recordCrashTx` zero-row race (a workflow that went terminal between crash and
recording currently errors the decoder and aborts the rest of the pass), and per-pass
error isolation plus an honest scanned/deleted summary for the GC worker.

EP-5 (plan 204) owns the written contracts: the wake-source authoring contract (a
third-party wake source must keep a durable row its await's arm can re-check, because
`appendJournalEntry`'s generation resolution races rotation and the engine's own
sources survive only via arm-side repair), the documented semantics that
`continueAsNew` abandons outstanding awakeable ids, the scale-posture paragraphs in
`docs/user/roadmap.md` and `docs/user/production-status.md`, and the stale haddocks the
audit found (`recordStepTx`'s conflict-key comment predates migration 0008).

Alternatives considered. A single "fix everything" plan was rejected: EP-1 changes the
liveness argument and needs its own design and ADR, while EP-3 changes replay identity
and needs its own compatibility argument — coupling either to mechanical round-trip
fixes would make the risky changes harder to review. Splitting EP-1's index fix into
its own micro-plan was rejected because both changes rewrite the same statement
(`findUnfinishedWorkflowIdsStmt`); the index fix is instead EP-1's first, independently
shippable milestone. Folding EP-4's `wake_after` concerns into EP-1 was considered and
adopted only for the stale-re-fire clear (it is part of the discovery-hint contract);
the throughput work stays in EP-4 because it changes no contract, only cost.

ADR context at authoring, per `agents/skills/exec-plan/ADR.md`: the relevant local
records are `docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md`
(the step index is the authoritative replay-visibility fallback — EP-1's narrowed
discovery must not weaken it), `docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md`
(wake-source rows are the durable authority; EP-1 extends this rule to "and every
row-lifecycle transition must be discoverable", EP-5 documents it for third-party
sources), `docs/adr/0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md`
(the first-arm insert owns `wake_after` and "a successful fire clears it" — EP-1's
re-fire guard aligns the implementation with the word "successful"), and
`docs/adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md`
(terminal freeze and resurrection — EP-2's failure re-check must respect revivability).
ADRs 1–4 and 9–22 concern pgmq telemetry, evolution gating, migrations, and the DSL;
none constrain this initiative. The `docs/adr` bundle is profile-governed (OKF
`profile.dhall`); new records must allocate ids with `okf id next` and pass
`just adr-validate`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Make suspended workflows quiescent and discovery index-aligned | docs/plans/200-make-suspended-workflows-quiescent-and-discovery-index-aligned.md | None | None | Complete |
| 2 | Fold terminal checks into the workflow append transaction and thin the step hot path | docs/plans/201-fold-terminal-checks-into-the-workflow-append-transaction-and-thin-the-step-hot-path.md | None | None | Complete |
| 3 | Derive workflow deterministic ids from UTF-8 bytes | docs/plans/202-derive-workflow-deterministic-ids-from-utf-8-bytes.md | None | None | Complete |
| 4 | Concurrent resume passes, batched timer drain, and worker pass robustness | docs/plans/203-concurrent-resume-passes-batched-timer-drain-and-worker-pass-robustness.md | None | EP-1 | Complete |
| 5 | Document the wake-source contract and the durable-execution scale posture | docs/plans/204-document-the-wake-source-contract-and-the-durable-execution-scale-posture.md | None | EP-1, EP-4 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

There are no hard dependencies: each plan changes a distinct contract with its own
tests, and each is implementable against the current tree.

EP-4 has a soft dependency on EP-1: concurrent advancement multiplies whatever each
advancement costs, so it lands best after EP-1 has removed the no-progress re-runs;
and EP-1's narrowed discovery shrinks the candidate set EP-4's concurrency fans out
over. EP-4 can proceed first if scheduling demands it — the leases already make
concurrent advancement safe — but the combined load profile should be re-measured if
the order is reversed.

EP-5 has soft dependencies on EP-1 and EP-4 because the scale-posture documentation
should describe the engine as it ships after those plans (quiescent suspension,
concurrent passes); if EP-5 runs first, it must describe the current O(suspended ×
poll) posture and be revised when they land. The wake-source contract and haddock
portions of EP-5 are order-independent.

EP-2 and EP-3 are fully independent of everything, including each other. EP-1 and
EP-2 both edit `Keiro.Workflow`/`Keiro.Workflow.Schema` in different functions; merge
order is coordination, not dependency (see Integration Points).


## Integration Points

`keiro/src/Keiro/Workflow/Schema.hs` — EP-1 rewrites `findUnfinishedWorkflowIdsStmt`
(predicate and wake filtering) and EP-2 touches the entry-check statement surface
(single combined terminal lookup) and `prepareJournalAppend`'s in-transaction checks
in `keiro/src/Keiro/Workflow.hs`. Different statements, same modules; whichever lands
second rebases mechanically. Neither changes `WorkflowStepRow` or any exported type.

The `keiro_workflows` instance row — EP-1 makes it the *complete* wake ledger (every
wake or cancel transition must leave the row discoverable) and is responsible for
stating that rule in its new ADR; EP-2's in-transaction terminal checks and EP-4's
concurrent claims consume the row but must not add new writers. Any future wake
source inherits the rule from EP-1's ADR, and EP-5 documents it for authors.

`Keiro.Workflow.Sleep.workflowSleepFireAction` — EP-1 owns the guarded
`clearWorkflowWakeAfterTx` (only a fresh append for the generation that owns the
awaited sleep clears the hint); EP-4's batched timer drain calls the same fire action
unchanged. EP-1 updates ADR 7's consequence wording if needed; EP-4 must not.

`keiro/src/Keiro/Workflow/Resume.hs` — EP-1 removes the redundant
`findRunningChildIds` union from `resumeWorkflowsOnce`; EP-4 restructures the same
function's drive loop for bounded concurrency. Whichever lands second rebases over
the other; the discovery inputs (EP-1) and the advancement mechanics (EP-4) are
otherwise disjoint. EP-1's suspend arbitration also changes the `runWorkflowWith`
outcome handler in `keiro/src/Keiro/Workflow.hs`, while EP-2 changes that
function's entry probe and `Step`/`Patch` handler arms — different regions of one
function, coordinate on merge order only.

Deterministic id derivation (`deterministicJournalId`, `sleepTimerId`,
`deterministicAwakeableId`, `Keiro.ProcessManager.deterministicCommandId`) — owned
exclusively by EP-3, including the ADR that freezes the UTF-8 derivation. No other
plan may touch id derivation; EP-1/EP-2/EP-4 reuse the existing functions.

Migration numbering in `keiro-migrations/migrations/` — the next free number at
authoring time is `0021`. EP-1 is the only plan expected to need a migration (index
adjustment for discovery); if EP-2 or EP-4 discovers it needs one, it claims the next
number after EP-1's and reconciles the migration manifest/count tests in
`keiro-migrations`.

`keiro/test/Main.hs` — all five plans add or extend test groups. Additive appends;
keep group names distinct.

Cross-plan decisions that deserve ADRs: EP-1's "the instance row is the complete wake
ledger and discovery is exact" (recorded 2026-08-06 as
`docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`,
ADR-23, extending ADR 6/7; EP-1 also amended ADR 7 so that only a fresh append counts
as a successful sleep fire); EP-3's "deterministic ids hash UTF-8 bytes; ASCII
derivations are frozen byte-for-byte" (recorded 2026-08-06 as
`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`,
ADR-24, which also names the length-prefixed router encoding as the pattern for any
*new* derivation and records the `keiro-dsl`/`jitsurei` copies as a deliberate
exclusion). EP-2 and EP-4 are expected to update ADR wording only if implementation
contradicts it. EP-4 in particular must not add a writer of the `keiro_workflows` row
that skips ADR 23's obligation.


## Progress

- [x] EP-1 (2026-08-06): Discovery predicate rewritten to positive active-status arms with index-aligned wake filtering; EXPLAIN-verified test.
- [x] EP-1 (2026-08-06): `cancelAwakeable` flips the owner instance row; stale sleep re-fires no longer clear a live wake hint (ADR 7 amended).
- [x] EP-1 (2026-08-06): Discovery narrowed to exact wakes; both race orderings and the crash-retry window are covered by tests; ADR 23 recorded.
- [x] EP-2 (2026-08-06): Terminal checks (cancelled and failed) folded into the append transaction via the new `JournalRefusedTerminal` outcome; boundary-asymmetry test passes and is pinned to the in-transaction check; ADR 6 amended with the refusal contract.
- [x] EP-2 (2026-08-06): Single entry-status query (`terminalMarkers`) and redundant claim-time generation query removed; a fresh step now costs one fewer round-trip than before while checking strictly more.
- [x] EP-3 (2026-08-06): All four derivations hash UTF-8 seed bytes through the internal `Keiro.DeterministicId.identitySeedBytes`; sixteen pre-change ASCII fixtures still match, five previously-colliding pairs now differ, and a DB-backed workflow with colliding step names completes (proven to fail against the old encoding); ADR 24 recorded.
- [x] EP-4 (2026-08-06): `maxConcurrentAdvances` (default 1) advances candidates through a bounded worker pool; overlap is asserted on recorded step-body windows and a mixed pass reports identically at concurrency 1 and 3.
- [x] EP-4 (2026-08-06): `drainDueTimersWith` / `drainWorkflowSleepTimers` clear a whole backlog in one pass with one preamble; `recordCrashTx` returns `Maybe Int32` so the terminal race skips one candidate instead of the pass; GC isolates per workflow and per pass and reports a truthful `deleted`.
- [x] EP-5 (2026-08-06): Wake-source authoring contract (four obligations, ADR-cited) in `Keiro.Workflow`'s overview, the guide, and the reference; `continueAsNew` awakeable abandonment documented; `recordStepTx`'s conflict key, the GC parent-collection note, and the stale discovery prose in both user documents corrected.
- [x] EP-5 (2026-08-06): Scale posture recorded in `docs/user/roadmap.md`, `docs/user/production-status.md`, and both durable-workflows documents, including the `snapshotPolicy = Never` default and batched sleep draining.


## Surprises & Discoveries

- EP-1 (2026-08-06) found a third class of stranding the plan had not
  anticipated, and it changes what any future wake source must assume. Two
  arming actions resolve their own await and then fall through to the suspend
  write: `awaitCancellable` re-appends a completed awakeable's stored payload
  (the crash-repair path), and `awaitChild` re-delivers a completed child's
  result onto the parent's current generation. Under broad discovery, writing
  `suspended` over the `running` those appends had just set was harmless; under
  exact discovery it would strand the workflow. The arbitration's index re-check
  covers them, but the general rule for EP-5's author-facing documentation is
  stronger than "a wake source must flip the instance row": an *arm* that
  appends its own result must also not assume its run will be re-examined.

- EP-1 (2026-08-06): migration numbering is now at `0021`
  (`0021-keiro-workflows-exact-discovery.sql`); the next free number for EP-2 or
  EP-4 is `0022`. Adding a native migration touches five places beyond the SQL
  file — `keiro-migrations/migrations/manifest`,
  `keiro-migrations/migrations.native.lock` (sha256 line),
  `keiro-migrations/expected-schema/native/keiro-v18.txt` (regenerate with
  `KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test`), the
  `nativeMigrationFiles` list in `keiro-migrations/test/Main.hs`, and that
  suite's pinned counts (which include `postCoddImportPendingIssues`, the
  post-import pending list — easy to miss, since it fails only in the codd-import
  examples).

- EP-2 (2026-08-06): `JournalAppendOutcome` gained `JournalRefusedTerminal
  !Text`, so any later plan that pattern-matches it must handle the arm. The
  house rule established at those call sites, and now written into ADR 6, is
  "settle your own durable row, deliver nothing, do not condemn and do not
  throw" — EP-4's worker-robustness work should follow it rather than treating a
  refusal as a transient error. Note also that the three wake-source modules'
  `condemnOnAppendConflict`/`throwOnAppendConflict` helpers are near-duplicates
  in `Keiro.Workflow.Awakeable`, `Keiro.Workflow.Child`, and
  `Keiro.Workflow.Resume`; they were updated in lockstep here, and a future plan
  that touches them should consider sharing one definition.

- EP-2 (2026-08-06): `keiro/CHANGELOG.md` now carries an `Unreleased` section
  covering EP-1's and EP-2's user-visible changes, and
  `keiro-migrations/CHANGELOG.md` one for migration 0021. Later plans in this
  initiative should extend those sections rather than starting new ones — the
  whole initiative ships as one release.

- EP-5 (2026-08-06) found the initiative's own documentation debt, and it is a
  process finding rather than a technical one. Both user-facing durable-workflow
  documents still described discovery as "the `keiro_workflow_steps` index,
  unioned with running children" — the mechanism EP-1 replaced. EP-1 updated the
  CHANGELOG and wrote ADR 23 but swept no guides, and EP-5's inventory of
  documentation drift (written before EP-1 ran) listed only `recordStepTx` and
  the GC module. Nothing in the decomposition made anyone responsible for prose a
  sibling plan invalidated. The habit worth adopting: when a plan changes a
  documented mechanism, grep `docs/` for the old mechanism's name before closing
  it, rather than relying on a later documentation plan to notice.

- EP-4 (2026-08-06) surfaced a convention that no ADR states and whose absence
  is exactly how its bug survived: every keiro worker loop is expected to
  isolate failures per pass *and* per item, and to report partial progress
  honestly. The resume worker did; the GC worker was a bare `forever` whose
  summary restated `scanned` as `deleted`, so a pass that collected nothing
  would have reported full success. This is a candidate for the MasterPlan's
  completion ADR distillation — EP-5's author-facing documentation should be
  written against it, since a third-party wake source or worker inherits the
  same obligation.

- EP-4 (2026-08-06) recorded two interface additions later work will see:
  `WorkflowResumeOptions` gains `maxConcurrentAdvances :: !Int` (default 1, so
  behaviour is unchanged unless raised), and `ResumeSummary` now has
  `Semigroup`/`Monoid` instances that add fields. `logEvent` may be invoked from
  several threads once concurrency is raised, which EP-5 should state in the
  operator-facing documentation alongside the scale posture.

- EP-3 (2026-08-06) found the truncating id derivation in two places outside
  the workflow engine, and left both alone on purpose. `keiro-dsl` scaffolds it
  into every generated process manager as `namedUuid`
  (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:3948`, plus four checked-in conformance
  trees that the scaffold-conformance test pins byte-for-byte), and `jitsurei`
  hand-copies it twice. Neither can reuse EP-3's helper —
  `Keiro.DeterministicId` is internal to the `keiro` library — and generated
  identity is governed by ADR 18, so a fix there needs its own compatibility
  argument and fixture regeneration. ADR 24 records the exclusion. This is a
  candidate for a follow-up plan, not for EP-4 or EP-5 to absorb; EP-5's
  author-facing documentation should point at ADR 24's "new derivations use the
  router's length-prefixed encoding" rule so the next copy is the right one.

- EP-3 (2026-08-06) corrected an assumption the re-audit and this MasterPlan
  both carried: a deterministic-id collision does *not* surface as
  `WorkflowJournalAppendError`. `runWorkflow` returns the store error directly —
  `Left (DuplicateEvent Nothing)`. This was measured by running the new
  end-to-end example against a temporarily restored truncating encoding, not
  inferred. Any later plan describing the wedge (EP-5's documentation in
  particular) should use the real value.

- EP-1 (2026-08-06) changed one internal interface EP-4 will rebase over:
  `resumeWorkflowsOnce` no longer unions `findRunningChildIds` into discovery and
  no longer needs its `dedupeFirstSeen` helper, so the drive loop now folds
  directly over `findUnfinishedWorkflowIds`' result. `Keiro.Workflow.Instance`
  exports `markInstanceSuspendedAwaiting` in place of `markInstanceSuspended`.
  EP-4's bounded-concurrency work should also re-baseline its motivation: the
  candidate set a pass fans out over is now exact, so concurrency buys latency on
  real work rather than parallelising no-progress re-runs.


## Decision Log

- Decision: Decompose by contract (discovery, append boundary, identity, worker cost,
  written contracts) into five plans with no hard dependencies.
  Rationale: Each contract is independently verifiable; the two risky changes (EP-1
  liveness, EP-3 replay identity) must not be coupled to mechanical fixes, and the
  index fix belongs with the discovery rewrite because both edit the same statement.
  Date: 2026-08-06

- Decision: Ship EP-1's index-predicate fix as that plan's first milestone rather than
  a separate micro-plan.
  Rationale: Both changes rewrite `findUnfinishedWorkflowIdsStmt`; two plans editing
  one statement in the same way should be one plan (MASTERPLAN.md decomposition
  principle). The milestone is independently shippable if quiescence slips.
  Date: 2026-08-06

- Decision: Include `Keiro.ProcessManager.deterministicCommandId` in EP-3's scope even
  though it is outside the workflow engine.
  Rationale: Identical defect, identical ASCII-compatible fix, and one ADR should
  freeze the whole identity-derivation family rather than leaving the PM path to
  diverge.
  Date: 2026-08-06

- Decision: Keep MasterPlan 16's accepted-known items accepted, and treat ADR 6's
  orphan-pending-awakeable crash window as documented-not-fixed.
  Rationale: The re-audit re-confirmed the consequences are transient or GC-bounded;
  reopening them buys no behavior.
  Date: 2026-08-06

- Decision: Keep EP-3's fix inside the `keiro` library; leave the identical
  truncating derivation in the `keiro-dsl` scaffold's generated `namedUuid` and
  in `jitsurei` for a separate plan.
  Rationale: EP-3's whole compatibility argument is that ASCII ids do not move,
  which is reviewable precisely because the diff is four functions and one
  helper. Generated identity carries a different contract (ADR 18, plus a
  scaffold-conformance test that pins four trees byte-for-byte), so folding it
  in would have coupled a frozen-identity change to fixture regeneration — the
  coupling this MasterPlan's decomposition exists to avoid. Recorded as a
  deliberate exclusion in ADR 24.
  Date: 2026-08-06

- Decision: Do not add wake-time push filtering (using the NOTIFY payload to resume
  only the woken workflow) in this initiative.
  Rationale: EP-1's exact discovery makes a pass cheap even when triggered broadly;
  payload-directed resumption couples keiro to kiroku's notification payload format,
  which ADR-less today and best raised as an upstream roadmap item after EP-1's
  numbers are in.
  Date: 2026-08-06


## Outcomes & Retrospective

Complete, 2026-08-06. All five child plans landed in registry order, each in one
or a few commits, with one migration (`0021`) and three new ADRs (23, 24, 25).
The suite finished at 407 examples, 0 failures, and was green at every
milestone; EP-3 added 5 examples and EP-4 added 9. Every pre-existing example
passed unmodified at every step — the strongest evidence that the behavioural
changes were as scoped as they claimed, since EP-3's whole compatibility
argument rests on ASCII identities not moving.

Against the Vision's promises, all delivered:

- A workflow suspended on an awakeable, a child, or a future-dated sleep costs
  the resume worker nothing. Discovery is exact and index-aligned; every wake and
  cancel path writes the instance row in its own transaction (EP-1, ADR 23).
- A direct run overlapping a terminal failure stops at the next step boundary,
  with the terminal checks folded into the append transaction — so a fresh step
  costs one fewer round-trip than before while checking strictly more (EP-2).
- Deterministic ids hash UTF-8 bytes. ASCII derivations are byte-identical, so no
  deployment moved; the non-ASCII collision that wedged the append path is closed
  and the derivation is frozen by fixtures and ADR 24 (EP-3).
- A stale sleep re-fire cannot erase a live wake hint (EP-1, amending ADR 7).
- A resume pass advances many instances concurrently and the timer worker drains
  in batches (EP-4).
- The crash-recording and GC workers survive races and transient errors, and
  report finished work rather than attempted work (EP-4, ADR 25).
- The wake-source authoring contract and the engine's scale posture are written
  down for adopters (EP-5).

Three things this initiative taught that were not in its plan.

**Verify a regression test by restoring the regression.** EP-3 and EP-4 each
temporarily put the old behaviour back and watched the new example fail before
keeping it. Both times this paid: EP-3 learned that a deterministic-id collision
surfaces as `Left (DuplicateEvent Nothing)` rather than the
`WorkflowJournalAppendError` the re-audit assumed, and EP-4 learned that the
crash-record race aborts the *entire* pass rather than the candidates behind it.
Both plans had documented the wrong failure mode with complete confidence.

**A decomposition that isolates risk also isolates responsibility for prose.**
The decomposition worked exactly as intended for code — EP-1's liveness change
and EP-3's identity change each got their own review surface, uncoupled from
mechanical fixes. But it left nobody responsible for user documentation that a
sibling plan invalidated: EP-1 replaced the discovery mechanism, wrote ADR 23,
updated the CHANGELOG, and left both user-facing guides describing the old
mechanism, which EP-5 found months of reading-time later (had anyone read them).
When a plan changes a documented mechanism, grep `docs/` for the old mechanism's
name before closing it.

**Conventions that live only in code do not survive a new author.** ADR 25 exists
because workflow GC was written after the resume worker and did not inherit its
per-pass isolation — not because anyone disagreed, but because the rule was
nowhere to disagree with. The re-audit found the same class twice in the same
plan. A convention held by every existing instance of a pattern is exactly the
convention most likely to be assumed self-evident and therefore never written.

ADR distillation performed at close-out. Promoted: EP-4's worker-loop convention
into ADR 25 (new). Already recorded during implementation: ADR 23 (exact
discovery, EP-1), ADR 24 (frozen UTF-8 identity derivation, EP-3), amendments to
ADR 6 (the terminal-refusal contract, EP-2) and ADR 7 (only a fresh append is a
successful sleep fire, EP-1). Left in the plans: execution notes, fixture
capture, and the per-milestone verification transcripts. Left unrecorded as
ADR-shaped but retained in this retrospective: the two process lessons above, and
EP-5's documentation-drift finding — habits for how work is done here rather than
decisions about what the system is.

Carried forward as known and accepted: the `keiro-dsl` scaffold's generated
`namedUuid` and `jitsurei`'s two hand-written copies still use the truncating
derivation (ADR 24's Consequences records the exclusion and the reason — generated
identity is governed by ADR 18 and pinned byte-for-byte by the
scaffold-conformance test, so it needs its own compatibility argument). MasterPlan
16's accepted-known items remain accepted, and `PositionWait` push wiring plus
prefix subscriptions remain Phase-3 roadmap items.
