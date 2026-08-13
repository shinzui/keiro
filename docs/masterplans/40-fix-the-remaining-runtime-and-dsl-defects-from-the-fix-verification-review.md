---
id: 40
slug: fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review
title: "Fix the remaining runtime and DSL defects from the fix verification review"
kind: master-plan
created_at: 2026-08-12T23:55:22Z
intention: "intention_01kzw6dkcserms9yr61sqdntep"
---

# Fix the remaining runtime and DSL defects from the fix verification review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The 2026-08-12 follow-up verification review (an adversarially verified code review over
`39bc631c..HEAD`, the fifty-six commits implementing MasterPlans 36–38) confirmed three
defects outside the catalog rebuild pipeline, each a residual gap in a fix that range
shipped, plus seven consolidation cleanups the range's own refactoring goals left
unfinished.

The three defects: first, the `keiro-dsl diff` evolution gate misses the exact policy
weakening it exists to catch — migrating a language-4 groupless read model declared
`consistency = Strong` to language-5 `freshness = immediate` produces zero breaking
diagnostics, because `QueryFreshnessChanged` fires only when both sides resolve to an
owner-derived supply and every legacy fallback branch in
`keiro-dsl/src/Keiro/Dsl/Diff.hs` (near line 1234) returns empty for that shape. Second,
the workflow resume summary introduced by
`docs/plans/239-close-the-awakeable-cancel-versus-suspend-race-and-fix-the-drain-contract.md`
counts every successfully processed candidate as `advanced`, including replay-only
re-suspensions that appended nothing durable; a workflow suspended on a due sleep while no
timer worker runs is rediscovered every pass, so the documented "repeat bounded passes
while `advanced > 0`" drain loop (`keiro/src/Keiro/Workflow/Resume.hs`, near lines 372 and
619) never terminates — in exactly the standalone `keiro-ops wf resume-once` context the
feature targets. Third, the truthful-freshness compatibility work of
`docs/plans/244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md`
left the exported `waitFor` and the deprecated `runQueryWith` Strong path reading a
read model's subscription name raw, so a cursorless model carrying the internal sentinel
name polls a nonexistent subscription for the full five-second timeout (and increments a
spurious timeout metric) instead of failing fast with the typed `ReadModelMissingCursor`
that `runQueryWithFreshness` raises (`keiro/src/Keiro/ReadModel.hs`, near lines 438 and
562).

After this MasterPlan completes, the diff gate reports a breaking diagnostic for every
consistency-to-freshness weakening across the language 4-to-5 migration; a resume drain
loop terminates on every reachable blocked-candidate shape and the summary's `advanced`
field means what its documentation says; cursorless strong waits fail fast with the typed
error on every public path; and the seven deferred cleanups are applied. The three defect
plans gate the 0.12.0.0 release; the cleanup plan (EP-4) is explicitly non-gating, as its
namesake was in MasterPlan 37.

Excluded: the five rebuild-pipeline defects (MasterPlan 39,
`docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md`),
IR-22 (MasterPlan 41), and release mechanics.


## Decomposition Strategy

Each defect is one plan: they live in three different packages' concerns (DSL evolution
gating, workflow resume, read-model query paths), share no code, and each has a distinct
red-test-first proof. The seven cleanups form one non-gating plan rather than seven
micro-plans: each is a small mechanical consolidation, and their only coordination risk —
overlapping files with the defect plans — is handled by sequencing, not decomposition.

Relevant ADRs, read during planning:
`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (the diff
boundary EP-1 repairs is layer 2 of that contract; the fix must keep the check/diff
DiagnosticCode correlation),
`docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`
and
`docs/adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md`
(the discovery predicate and partial-progress reporting contract EP-2 must keep truthful;
both were amended by plan 239 and EP-2 amends them again),
`docs/adr/0033-consistency-waits-target-reachable-visible-heads.md` (the honest-wait
contract EP-3 extends to the cursorless case), and
`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`
(EP-4's shared dual-probe helper must not alter the frozen probe policy it consolidates).
No cross-repository ADR bears on this MasterPlan.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Report legacy strong-consistency weakening across the language 4 to 5 migration in diff | docs/plans/250-report-legacy-strong-consistency-weakening-across-the-language-4-to-5-migration-in-diff.md | None | None | Complete |
| 2 | Count only durable progress in workflow resume summaries | docs/plans/251-count-only-durable-progress-in-workflow-resume-summaries.md | None | None | Complete |
| 3 | Fail fast on cursorless strong waits in the legacy read-model API | docs/plans/252-fail-fast-on-cursorless-strong-waits-in-the-legacy-read-model-api.md | None | None | Complete |
| 4 | Apply the deferred consolidation cleanups from the fix verification review | docs/plans/253-apply-the-deferred-consolidation-cleanups-from-the-fix-verification-review.md | None | EP-1 | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1, EP-2, and EP-3 are mutually independent — different packages, different test
suites — and can proceed in parallel or in any order. EP-4 soft-depends on EP-1 because
one cleanup (threading a single projection-supply analysis instead of recomputing it per
node) rewrites call sites in `keiro-dsl/src/Keiro/Dsl/Diff.hs` and
`keiro-dsl/src/Keiro/Dsl/Validate.hs` that EP-1 also edits; landing the defect fix first
keeps the gating change unblocked and lets the cleanup rebase mechanically. EP-4 is
non-gating: 0.12.0.0 may tag with EP-4 incomplete.


## Integration Points

`keiro-dsl/src/Keiro/Dsl/Diff.hs` is shared by EP-1 (the read-model policy-change
classification it fixes) and EP-4 (the supply-analysis threading cleanup). EP-1 defines
the corrected classification logic; EP-4 must preserve its behavior exactly while changing
only how the supply analysis is computed and passed (the same equivalence bar the
type-graph threading work of plan 236 used).

The resume summary types (`ClaimOutcome`, `ResumeSummary` in
`keiro/src/Keiro/Workflow/Resume.hs`) are consumed by `keiro-ops` (`wf resume-once`
rendering in `keiro-ops/src/Keiro/Ops/Workflow.hs`) and documented as an operator drain
contract. EP-2 owns any reshaping; if it adds a new summary category for
"rediscovered but not durably advanced" candidates, the keiro-ops rendering and the
Haddock drain recipe change in the same plan — no other plan touches these types.

No other file, type, or table is shared between plans in this MasterPlan. The seven EP-4
cleanups touch `keiro-dsl/src/Keiro/Dsl/Validate.hs`, `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`,
`keiro/src/Keiro/Command.hs`, `keiro-ops/src/Keiro/Ops/ReplayAudit.hs` (and sibling ops
modules), `keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs`,
`keiro/src/Keiro/Workflow/Awakeable.hs` with `keiro/src/Keiro/ProcessManager.hs`, and
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` — none overlapping EP-2 or EP-3.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 (250) M1: red L4→L5 fixture + three freshness-migration diff cases (zero breaking findings today, plus the spurious additive scope-widened verdict)
- [x] EP-1 (250) M2: `policyChanges` supply-shape split (owner/owner, legacy/legacy, mixed → `migrationFreshnessChanges` on normalized freshness)
- [x] EP-1 (250) M3: no-false-positive proofs, corpus zero-drift, CLI gate transcripts (weakening blocks, equivalent/strengthened stay green)
- [x] EP-1 (250) M4: migration-table docs, changelog, `just verify`
- [x] EP-2 (251) M1: red bounded-drain test over a due sleep with no timer worker (every pass reported `advanced=1` before the fix)
- [x] EP-2 (251) M2: append-witness through `WorkflowRunOptions`, `classifyOutcome` replacing `bumpForOutcome`, new `sleepDue` blocked category, Haddock drain recipe rewrite
- [x] EP-2 (251) M3: keiro-ops `sleep_due` column + two-pass resume-once CLI test (`advanced=0, sleep_due=1` both passes)
- [x] EP-2 (251) M4: docs, ADR-23/ADR-25 amendments, changelogs (supersede plan 239's unreleased bullet), `just verify`
- [x] EP-3 (252) M1: three cursorless tests (two red wait proofs with timing/metric assertions; pre-fix rebuild lifecycle green through Hasql, correcting the direct-SQL planning inference)
- [x] EP-3 (252) M2: waitFor through the cursor-authority predicate; `runQueryWith` reimplemented as a translation onto `runQueryWithFreshness`
- [x] EP-3 (252) M3: cursorless `startRebuild` skips the checkpoint reset (typed, documented); scaffold audit confirming no keiro-dsl change
- [x] EP-3 (252) M4: docs, changelog, ADR distillation, standalone 548-example runtime suite, and full `just verify`
- [ ] EP-4 (253) M1: keiro consolidation (shared command-attempt driver; shared deterministic-id probe helper) with golden vectors untouched + command benchmark guard
- [x] EP-4 (253) M2: keiro-ops reader consolidation into `Keiro.Ops.Parse`
- [x] EP-4 (253) M3: keiro-dsl surface (single `outcomeSelectors` source; delete dead `pureRefusals`/`constraintPlan` exports)
- [x] EP-4 (253) M4 (after EP-1): `checkedProjectionSupplies` derived field threaded through Validate/Scaffold/Harness/Diff; ReplayImpact adopts `checkedTypeGraph`
- [ ] EP-4 (253) M5: `just verify`, benchmark guard, registry update


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- EP-3 drafting (2026-08-12) inferred from a direct PostgreSQL `convert_from` probe
  that the `startRebuild` sentinel checkpoint reset would abort with SQLSTATE 22021,
  and expanded the plan to the generated cursorless lifecycle. Implementation later
  corrected that inference as recorded below. The deprecated
  `PositionWait`-with-target override shares the raw wait path and was also added to
  EP-3's scope.
- EP-3 implementation (2026-08-13) corrected that planning-time rebuild claim: the
  database-backed pre-fix regression passed through the actual Hasql `text[]` parameter
  path, despite the direct `convert_from` probe raising SQLSTATE 22021. EP-3 retains the
  typed `NoQueryCursor` branch because a cursorless model has no checkpoint to reset,
  but user-facing text now describes the verified boundary leak rather than an
  unreproduced transaction abort. The two wait defects reproduced exactly.
- EP-1 drafting corrected two brief details: the Validate.hs lines cited for the L4
  side are actually the language-5 groupless-binding check (the L4 side needs no such
  rule), and `PositionWait` has no read-model-supply representation, so it carries no
  diff obligation (ruled and recorded in plan 250's Decision Log). Every cross-language
  diff also emits a pre-existing advisory `AggFoldSurfaceChanged` from the
  runtime-semantics bump — tests must assert on breaking-ness, not empty change lists.
- EP-4 drafting found plan 242's decision log had already pinned the telemetry
  constraint and deferred the awakeable-probe consolidation "until plan 240 lands";
  two additional recomputation sites (`ScaffoldRecord.hs`, `Validate.hs` fleet pass)
  were folded into the threading item.
- EP-1 completed on 2026-08-13 without changing its shared projection-supply analysis
  seam or any durable architecture boundary. Its normalized migration classifier, user
  documentation, zero-drift corpus proof, and full `just verify` gate are green. EP-4's
  soft dependency is satisfied, so its later `Diff.hs` threading cleanup is unblocked.
- EP-2 completed on 2026-08-13 without changing workflow discovery, storage schema,
  or another child plan's files. Its red proof exhausted five drain passes over one
  unchanged due sleep; the corrected pass reports `advanced = 0, sleepDue = 1`, and
  the full `just verify` gate (including all generated workflow/DSL conformance
  packages) remained green.
- EP-3 completed on 2026-08-13 without changing cursor-bearing waits, Kiroku reset
  semantics, or generated DSL bytes. All wait entry points now share the typed
  cursor-authority boundary, cursorless rebuild skips its nonexistent checkpoint reset,
  and the standalone 548-example runtime suite plus full `just verify` gate passed.


## Decision Log

- Decision: One plan per defect, one combined non-gating plan for all seven cleanups.
  Rationale: the defects are disjoint in code and proof style; the cleanups are small
  mechanical consolidations whose only risk is file overlap with EP-1, handled by a soft
  dependency rather than finer decomposition.
  Date: 2026-08-12
- Decision: EP-4 does not gate the 0.12.0.0 release; EP-1 through EP-3 do.
  Rationale: matches the treatment of plan 242 under MasterPlan 37 — quality
  consolidations must not delay a release whose bar is "no known bugs ship", and none of
  the seven cleanups changes observable behavior.
  Date: 2026-08-12
- Decision: EP-2 fixes the meaning of `advanced` (count only durable movement) rather
  than only documenting the current counting.
  Rationale: the field's documented contract ("durable journal or terminal state moved
  this pass") is the useful one for operators; weakening the documentation would leave
  the drain recipe without a terminating signal, which is the actual defect.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

- 2026-08-13: EP-1 completed. The language migration diff now blocks query-freshness
  weakenings, keeps equivalent/strengthened migrations non-breaking, preserves both
  same-language contracts, and documents the gate. EP-2, EP-3, and EP-4 remain.
- 2026-08-13: EP-2 completed. Resume summaries now count only durable movement,
  classify replay-only due sleeps as `sleepDue`, expose the timer-worker remedy in
  `keiro-ops` and user documentation, and terminate the bounded drain truthfully.
  ADR 0023 and ADR 0025 contain the durable contract. EP-3 and EP-4 remain.
- 2026-08-13: EP-3 completed. Cursorless waits now fail fast through the same typed
  boundary across truthful, direct, and deprecated APIs without recording false timeout
  metrics; cursorless rebuilds explicitly skip a checkpoint reset they cannot own. The
  scaffold audit required no generated-code change, ADR distillation required no durable
  decision update, and the full repository gate passed. EP-4 remains.
