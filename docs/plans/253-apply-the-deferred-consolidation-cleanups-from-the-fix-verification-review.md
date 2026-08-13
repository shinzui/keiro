---
id: 253
slug: apply-the-deferred-consolidation-cleanups-from-the-fix-verification-review
title: "Apply the deferred consolidation cleanups from the fix verification review"
kind: exec-plan
created_at: 2026-08-12T23:55:43Z
intention: "intention_01kzw6dkcserms9yr61sqdntep"
master_plan: "docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md"
---

# Apply the deferred consolidation cleanups from the fix verification review

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The 2026-08-12 follow-up verification review (an adversarially verified code review over
`39bc631c..HEAD`, the commits implementing MasterPlans 36–38) confirmed seven consolidation
cleanups that the range's own refactoring goals left unfinished: whole-spec analyses that
are recomputed per node instead of shared, a retry skeleton duplicated between two command
runners, a CLI reader duplicated five times, a parser selector set spelled twice, a frozen
compatibility policy hand-rolled in two shapes, and two exported functions with zero
callers. None of them is a defect — every one is an incomplete consolidation whose finished
form the same range already established elsewhere.

This plan applies all seven. The bar for every item is **zero observable behavior change**:
every diagnostic, generated module byte, CLI output, telemetry span, metric, deterministic
id, and error message must be identical before and after. The proof is the full existing
gates — `cabal build all`, the per-package test suites, the conformance-corpus zero-drift
check for the keiro-dsl items, the committed command-benchmark baseline guard for the
command-runner item, and finally `just verify` — plus targeted greps showing the duplicate
definitions are gone.

After this plan, a maintainer sees: one shared projection-supply analysis per check,
scaffold run, and diff side instead of one per node; the diff/replay-impact path reading
the type graph its `CheckedService` values already cache instead of re-resolving it per
event; one domain-command attempt driver instead of two verbatim skeletons; one
message-parameterized non-negative reader in `keiro-ops` instead of five copies; one
selector list driving the `outcome` contextual keyword's guard and body; one shared
dual-probe helper implementing ADR 24's compatibility policy; and two dead exports removed
from `Keiro.Dsl.ScaffoldRun` with a changelog entry.

This is the one non-gating plan of MasterPlan 40: the 0.12.0.0 release may tag without it.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-13 09:10Z) M1: Extract the shared domain-command attempt driver in `keiro/src/Keiro/Command.hs` (Item 3).
- [x] (2026-08-13 09:10Z) M1: Hoist `deterministicIdProbes` into `keiro/src/Keiro/DeterministicId.hs`; convert the process-manager probe list and the awakeable adoption cascade (Item 6).
- [x] (2026-08-13 09:10Z) M1: Add the pure probe-composition examples; run `cabal test keiro-test` green with the plan-240 golden vectors untouched (550 examples).
- [ ] M1/M5: Re-run the complete command benchmark baseline guard on a quiet host; the busy-host full samples failed unchanged control cases while targeted domain/control ratios and fan-out cases remained equivalent (evidence below).
- [x] (2026-08-13 09:10Z) M1: keiro CHANGELOG entry for the new `deterministicIdProbes` export; commit.
- [ ] M2: Add the message-parameterized reader to `keiro-ops/src/Keiro/Ops/Parse.hs`; delete the four `nonNegativeInt64Reader` copies and `generationReader` (Item 4).
- [ ] M2: Run `cabal test keiro-ops-test` green; keiro-ops CHANGELOG entry; commit.
- [ ] M3: Derive the `outcome` selector guard and body from one selector list in `keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs` (Item 5).
- [ ] M3: Delete the `pureRefusals` and `constraintPlan` exports and definitions from `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` (Item 7).
- [ ] M3: Run `cabal test keiro-dsl:tests` and `just conformance-corpus-policy` green; keiro-dsl CHANGELOG Breaking Changes entry; commit.
- [ ] M4: Confirm plan 250 (EP-1) is Complete in MasterPlan 40's registry; re-verify Diff.hs line references against HEAD.
- [ ] M4: Add the lazy `checkedProjectionSupplies` cache to `CheckedService`; thread it through Validate, Scaffold, ScaffoldRecord, and Harness; hoist per-side analyses in Diff (Item 1).
- [ ] M4: Adopt the cached `checkedTypeGraph` and a per-side symbols table on the replay-impact path (Item 2).
- [ ] M4: Run `cabal test keiro-dsl:tests`, `just conformance-corpus-policy`, and `just corpus-regen` + clean `git status --short`; keiro-dsl CHANGELOG entry; commit.
- [ ] M5: Full `just verify` green; re-run the command benchmark guard; record evidence in this plan.
- [ ] M5: ADR distillation pass (expected outcome: no ADR changes — see Decision Log); update MasterPlan 40's registry row to Complete; final Outcomes & Retrospective entry.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- M1 implementation (2026-08-13) found that `Keiro.DeterministicId` was still a
  Cabal `other-module`, despite the plan promising a new
  `Keiro.DeterministicId.deterministicIdProbes` public export. The external-style
  `keiro-test` suite proved the mismatch at compile time:

  ```text
  Could not load module ‘Keiro.DeterministicId’.
  it is a hidden module in the package ‘keiro-0.11.0.0’
  ```

  M1 therefore moves the module to `exposed-modules`; no existing symbol changes
  and the new helper becomes importable exactly as the plan and changelog state.
- M1's first full command benchmark run was invalidated by a busy host: the
  untouched `router-fanout.1000` case varied from 4.109 seconds to 1.012 seconds
  and then 2.513 seconds, against a 0.629-second baseline, while
  `domain.accepted-large` immediately reran at 5.78 milliseconds (80% faster
  than its baseline). System load was 4.56/7.30/13.81 with unrelated desktop
  processes consuming the cores. The runtime suite and smaller command cases
  are green; the complete guard remains an explicit M1/M5 item to rerun on a
  quiet sample.
- M1's post-`INLINE` full rerun made the environmental issue conclusive: the
  unchanged legacy `control.accepted-1` case failed 48% over baseline while the
  extracted domain case measured `0.97x` control; router and process-manager
  fan-outs, including both 1000-target cases, all passed. The relevant excerpt:

  ```text
  control.accepted-1: FAIL, 4.30 ms, 48% more than baseline
  domain.accepted-1:  FAIL, 4.16 ms, 0.97x, 32% more than baseline
  router-fanout.1000: OK, 662 ms, same as baseline
  process-manager-fanout.1000: OK, 632 ms, 9% more than baseline
  ```


## Decision Log

Record every decision made while working on the plan.

- Decision: Expose the existing `Keiro.DeterministicId` module in
  `keiro/keiro.cabal` when adding `deterministicIdProbes`.
  Rationale: the plan and changelog make the helper a public module-qualified API,
  while Cabal's prior `other-modules` classification made that API impossible to
  import and caused the external-style package test to fail at compilation.
  Date: 2026-08-13
- Decision: Milestones are package-scoped commits — one keiro commit (Items 3 and 6), one
  keiro-ops commit (Item 4), and two keiro-dsl commits (Items 5+7, then Items 1+2). No
  milestone spans packages. keiro-dsl is split into two commits, not one, because Item 7
  removes public exports and must carry the Conventional Commits breaking marker
  (`refactor(dsl)!:`), while Items 1+2 are a non-breaking perf refactor (`perf(dsl):`);
  mixing them would put a breaking marker on a perf commit or hide a break in a refactor.
  Rationale: the parent MasterPlan asked for one reviewable commit per milestone grouped by
  package; this split preserves that while keeping commit semantics honest.
  Date: 2026-08-12
- Decision: Item 1 shares the projection-supply analysis via a second lazy, derived,
  instance-invisible field on the opaque `CheckedService` (accessor
  `checkedProjectionSupplies`), exactly mirroring the `checkedTypeGraph` cache that plan
  236 introduced, rather than threading a parameter through every public signature.
  Rationale: `CheckedService` is already the one value flowing through check and scaffold
  runs, and ADR 18 records it as "the sharing point for pure whole-spec analyses"; a lazy
  field costs nothing when unused and shares across the double module-planning pass in
  `ScaffoldRun`. Validate's internal per-node functions still take a threaded parameter
  because they receive `Spec`, not the service.
  Date: 2026-08-12
- Decision: In `Diff.hs`, do not extend the exported `DiffEnv` record (its derived `Show`
  and `Eq` are public surface); instead hoist one `analyzeProjectionSupplies` call per diff
  side inside `readModelDiff` and pass both analyses to the internal `readModelPairDiff`.
  That is exactly "one analysis per diff side" and touches no exported type.
  Date: 2026-08-12
- Decision: Item 2 computes the per-side type-graph result (from the existing
  `checkedTypeGraph` cache) and one per-side `AggregateSymbols` table at the top of
  `replayImpactServices` and threads them through the internal surface helpers. The
  similar Spec-only recomputation inside `Diff.hs` (`mappedProjectionFindingChanges`'s
  local `projectionImpactFor` near line 925 and `mappedSemanticImpactForServices` near
  line 981) stays untouched: the review scoped Item 2 to `ReplayImpact.hs`, and those
  Diff sites are Spec-driven paths plan 236 classified as out of the sharing invariant.
  Date: 2026-08-12
- Decision: Item 4 deliberately excludes `positiveInt32Reader` in
  `keiro-ops/src/Keiro/Ops/Rebuild.hs` (near line 161). It has a different predicate
  (`> 0`) and is not among the five copies the review named; widening scope grows the
  review surface of a change whose whole safety story is byte-identical output.
  Date: 2026-08-12
- Decision: Item 6's shared helper is `deterministicIdProbes :: Text -> NonEmpty UUID` in
  `Keiro.DeterministicId`, beside the frozen seed primitives. `deterministicCommandId`,
  `legacyDeterministicCommandId`, `deterministicAwakeableId`, and
  `legacyDeterministicAwakeableId` keep their exported signatures and derivations — the
  plan-240 golden vectors pin them and are never edited. Only the two policy call sites
  (the probe-list construction and the adoption cascade) change to consume the helper.
  Date: 2026-08-12
- Decision: No ADR is created or amended by this plan. ADR 18's operative rule
  ("`CheckedService` is the sharing point for pure whole-spec analyses") already covers a
  second derived analysis, and ADR 24's probe policy is implemented, not changed, by the
  shared helper — the helper's Haddock takes over the "single source of truth" claim that
  currently sits on `deterministicCommandIdProbes`. If the distillation pass at completion
  finds this judgment wrong, record why here and make the minimal wording amendment then.
  Date: 2026-08-12
- Decision: Changelog entries: keiro gains an Added entry for the new
  `deterministicIdProbes` export; keiro-ops gains an Added entry for the new Parse reader;
  keiro-dsl gains a Breaking Changes entry for the two removed exports plus a Changed
  entry for the analysis-sharing perf work. Item 3 (internal attempt driver) gets no
  changelog entry: nothing user-visible changed and the functions involved are not
  exported.
  Date: 2026-08-12
- Decision: Milestone 4 (the keiro-dsl perf commit) starts only after plan 250
  (`docs/plans/250-report-legacy-strong-consistency-weakening-across-the-language-4-to-5-migration-in-diff.md`)
  is Complete in MasterPlan 40's registry, because plan 250 edits the read-model policy
  classification in the same `readModelPairDiff` function Item 1 threads through. If plan
  250 is cancelled or stalled, note it here and plan against current HEAD; the threading
  is orthogonal to the classification logic (it changes where the supply analysis comes
  from, never what `policyChanges` emits), so the rebase is mechanical either way.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a Haskell multi-package cabal project rooted at the directory that
contains `Justfile` and `cabal.project`. All commands in this plan run from that root.
Three packages are touched: `keiro` (the runtime library, `keiro/src/`), `keiro-ops` (the
operator CLI library, `keiro-ops/src/`), and `keiro-dsl` (the typed specification language
and toolchain, `keiro-dsl/src/`). Each package has a `CHANGELOG.md` with an `Unreleased`
section following Keep a Changelog. Line numbers below were verified against `HEAD`
(`3513cf1e`) on 2026-08-12; they will drift — regenerate each with the grep commands in
Concrete Steps before editing.

Definitions used throughout:

A "spec" is the parsed semantic graph of one `.keiro` source or composed workspace: the
`Spec` type in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`.

A "checked service" (`CheckedService` in `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`,
lines ~159–174) pairs a spec with the effective language contract it was checked under. It
is opaque: since plan 236
(`docs/plans/236-resolve-the-spec-type-graph-once-per-check-and-scaffold-run.md`) it also
carries a lazy, derived, never-serialized `serviceTypeGraph` field, read through the
accessor `checkedTypeGraph`, so every consumer in one check or scaffold run shares a single
type-graph resolution. Its hand-written `Eq`/`Show` instances cover only the language
contract and the spec, deliberately excluding derived caches. `checkedServiceForContract`
(line ~210) is the single construction seam that populates derived fields;
`checkedServiceWithSpec` is the only spec-replacement operation. This plan adds a second
derived field following the identical pattern.

The "projection-supply analysis" (`ProjectionSupplyAnalysis` in
`keiro-dsl/src/Keiro/Dsl/ProjectionSupply.hs`) is a whole-spec analysis produced by
`analyzeProjectionSupplies :: Spec -> ProjectionSupplyAnalysis` (line 51). It resolves
every catalog-bound read model (a read model with a rebuild `group`) to the single
projection owner that supplies its complete observed-target set, and collects structural
issues. It walks every spec node and sorts/nubs per read model — cheap per call, but the
range under review calls it once per projection-owner node, once per read model, once per
scaffolded read model, once per generated harness, and once per read-model pair per side
in diff. It is a pure function: equal specs give equal analyses.

A "scaffold run" is one CLI `scaffold` invocation: `keiro-dsl/app/Main.hs` builds one
`CheckedService`, validates, plans modules (twice — a base plan and a complete plan, to
preserve refusal precedence), then executes writes. A "check pass" is one evaluation of
`validateService :: CheckedService -> [Diagnostic]` (`keiro-dsl/src/Keiro/Dsl/Validate.hs`
line ~755), which delegates to the internal
`validateCheckedSpec :: EffectiveLanguageContract -> Either (NonEmpty TypeGraphError) TypeGraph -> Spec -> [Diagnostic]`
(line ~768) — note it already threads the shared type-graph result, which is the pattern
Item 1 extends to the supply analysis.

The "conformance corpus" is committed generated output compiled and asserted by the
`keiro-dsl-conformance-*` test suites. `just conformance-corpus-policy` runs
`scripts/check-conformance-corpus.sh`, failing if regeneration would change any committed
byte; `just corpus-regen` regenerates in place. Zero drift is the primary byte-equivalence
proof for every keiro-dsl item.

A "deterministic id" is a version-5 UUID over a seed text, used so an at-least-once writer
collapses to exactly one row. `keiro/src/Keiro/DeterministicId.hs` owns the frozen seed
encodings: `identitySeedBytes` (UTF-8, the only encoding for new writes),
`legacySeedBytes` (the frozen pre-0.12 codepoint truncation, a reader for old identity),
and `seedMovedAcrossEncodings` (True iff the seed contains non-ASCII text, i.e. the two
encodings can differ).

### The seven items

**Item 1 (keiro-dsl, perf) — thread one projection-supply analysis.** Call sites that each
recompute `analyzeProjectionSupplies` today:
`keiro-dsl/src/Keiro/Dsl/Validate.hs` line 2396 (once per pass, in
`validateProjectionCatalogFleet`), line 2560 (per projection-owner node, in
`validateProjectionOwner`'s `asyncQueryBinding`), line 2683 (per read-model node, in
`validateReadModel`'s `freshnessCapability`); `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` line
4102 (per read model, in `ownerDerivedCursor`), lines 4140 and 4148 (per catalog scaffold,
in `scaffoldProjectionCatalog`/`scaffoldProjectionCatalogForService`);
`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` lines 282 and 286
(`projectionCatalogFacts`/`projectionCatalogFactsForService`, feeding scaffold records at
`ScaffoldRun.hs` line 1281 and `WorkspaceScaffold.hs` line 655);
`keiro-dsl/src/Keiro/Dsl/Harness.hs` line 340 (per generated read-model harness, in
`emitReadModelHarness`); and `keiro-dsl/src/Keiro/Dsl/Diff.hs` line 1271 (per read-model
pair per side, in `readModelPairDiff`'s `resolvedSupplier`). The consolidation target is
one analysis per check/scaffold run (via the service cache) and one per diff side (hoisted
in `readModelDiff`). The direct calls in `keiro-dsl/test/Main.hs` (lines ~2226, ~2249)
deliberately exercise the analyzer and stay.

**Item 2 (keiro-dsl, perf) — adopt the cached type graph on the replay-impact path.** In
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`: the local `projectionImpactFor` (line 159) calls
`resolveTypeGraph (checkedSpec service)` although both `CheckedService` values carry the
cached result; `mappedFieldSurface` (lines 268–284) calls `resolveTypeGraph spec` (line
271) and `aggregateSymbols spec` (line 279) once per event (it is reached per event via
`eventSurface` from `decodeSurfaceAffected`); `mappedRegisterSurface` (lines 286–302) does
the same per aggregate side (lines 289, 297). `aggregateSymbols spec` itself re-resolves
the graph (`keiro-dsl/src/Keiro/Dsl/AggregateType.hs` line 90:
`aggregateSymbols spec = aggregateSymbolsFromGraphResult (resolveTypeGraph spec) spec`);
plan 236 already added `aggregateSymbolsFromGraphResult :: Either (NonEmpty TypeGraphError) TypeGraph -> Spec -> AggregateSymbols`
for exactly this conversion. All affected functions are internal to `ReplayImpact.hs` (the
module exports only the impact types, `replayImpactServices`,
`catalogReplayImpactServices`, and `renderReplayImpact`). Plan 236's Decision Log
explicitly left the two-spec comparison paths per-side; Item 2 finishes that per-side
adoption for replay impact: each side uses *its own* service's cached graph — never one
shared graph across sides, which would be unsound because the specs differ.

**Item 3 (keiro) — one shared command attempt driver.** In `keiro/src/Keiro/Command.hs`,
`domainCommandAttempts` (line 791) and `domainSqlCommandAttempts` (line 1002) duplicate
the attempt/hydrate/conflict-fixpoint/plan/silent-branch/retry skeleton verbatim: both
define `attempt` (hydrate then dispatch), `runPlan` (check `conflictFixpoint`, run
`prepareDomainCommandPlan`, return the silent outcome, or hand an accepted batch to the
append action), differing only in (a) the append action (`appendOnce` versus
`appendWithSqlOnce`, whose bodies are genuinely different — plain append versus
transactional append with the SQL callback and rollback path) and (b) how a
`DomainCommandOutcome` is wrapped into the caller's outcome type (bare, versus
`DomainSqlCommandSilent`/`DomainSqlCommandCommitted`/`DomainSqlCommandRolledBack`).
Neither function is exported. This is the unfinished half of plan 242
(`docs/plans/242-deduplicate-dispatch-and-retry-skeletons-and-fix-rebuild-read-amplification.md`,
commit `fe2f62f7`), which collapsed four loops to these two and recorded that each public
runner keeps its own span/metric recording (tests at `keiro/test/Main.hs` lines ~1360 and
~2241 pin span and metric behavior). Telemetry must remain byte-identical: the driver
contains no telemetry of its own — spans and metrics live in `hydrate`, `retryOrFail`
(line 1295: conflict/retry/duplicate counters), and the public runners' outcome
recorders, all of which stay where they are and are called in the same order.

**Item 4 (keiro-ops) — one message-parameterized non-negative reader.** Four verbatim
copies of `nonNegativeInt64Reader :: ReadM Int64` exist, differing only in the error
message: `keiro-ops/src/Keiro/Ops/ReplayAudit.hs` line 68 and
`keiro-ops/src/Keiro/Ops/Rebuild.hs` line 155 ("expected a non-negative global
position"), `keiro-ops/src/Keiro/Ops/Snapshot.hs` line 87 and
`keiro-ops/src/Keiro/Ops/Stream.hs` line 113 ("expected a non-negative stream version").
`keiro-ops/src/Keiro/Ops/Workflow.hs` line 237 has `generationReader :: ReadM Int` with
the same shape ("expected a non-negative generation"), duplicating the logic of
`Keiro.Ops.Parse.nonNegativeIntReader` (`keiro-ops/src/Keiro/Ops/Parse.hs` line 70) with a
different message. All five sit on `readBoundedIntegral`, which Parse already exports and
all five modules already import (`Workflow.hs` imports `Keiro.Ops.Parse` at line 39). The
consolidation: one polymorphic, message-parameterized reader in `Keiro.Ops.Parse`; delete
the five local definitions; every error message string moves verbatim.

**Item 5 (keiro-dsl parser) — one selector list for the `outcome` contextual keyword.** In
`keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs`, `pClause` (line 367) claims `outcome` as a
contextual keyword only when one of three selectors follows: the `lookAhead` guard at line
381 spells `keyword "accepted" <|> keyword "rejected" <|> keyword "no-op"`, and the choice
body at lines 386–394 repeats the same three `keyword` spellings with their handlers. The
two spellings can drift silently (a fourth selector added to the body but not the guard
would parse `outcome` as an identifier before it). Derive both from a single selector
list local to `pClause` (a `[(Text, P …)]` of selector name and handler), or a
`contextualKeyword` combinator in `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`; this plan
specifies the local list as the lowest-risk form. `keyword` (Core.hs line 144) is already
`lexeme . try`-wrapped, so a `choice` over the same keywords in the same order backtracks
identically to the hand-written alternatives.

**Item 6 (keiro) — one shared dual-probe helper.** ADR 24's compatibility policy — probe
the current UTF-8-derived id first, and the frozen legacy id second *only when*
`seedMovedAcrossEncodings` — is hand-rolled twice with structurally different code:
`keiro/src/Keiro/ProcessManager.hs` lines 501–506 (`deterministicCommandIdProbes`) builds
a `NonEmpty EventId` as `current :| [legacy | seedMovedAcrossEncodings seed]`, while
`keiro/src/Keiro/Workflow/Awakeable.hs` lines 240–254 (`allocateAwakeableId`, generation-0
branch) is an inline lookup cascade: look up the current id, else if the seed moved look
up the legacy id, else allocate fresh. Hoist one helper into `Keiro.DeterministicId`
beside the seed primitives; both sites consume it. The probe SEMANTICS must not change —
`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`
governs, and the golden vectors from plan 240
(`docs/plans/240-bridge-deterministic-id-deduplication-across-the-utf-8-encoding-upgrade.md`),
committed in `keiro/test/Main.hs` under `describe "Keiro deterministic id legacy-encoding
bridge"` (lines ~9918–9996, UUID literals captured from the genuine pre-change
implementation) plus the DB adoption examples at lines ~11089 and ~11105, must keep
passing untouched. Plan 242's Decision Log explicitly deferred this consolidation until
plan 240 landed; it has.

**Item 7 (keiro-dsl) — delete two dead exported shims.** Commit `8f599b31`
(`refactor(dsl)!: retire Spec-only scaffold planning APIs`, plan 235) retired the
Spec-only planning entry points but left two exported compatibility shims that now have
zero callers repo-wide: `pureRefusals` (`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` lines
527–528, export at line 47) and `constraintPlan` (lines 1103–1104, export at line 56).
Both are one-line wrappers over the `ForService` variants that all live callers already
use (`pureRefusalsForService` at `ScaffoldRun.hs` line 373; `constraintPlanForService` at
`ScaffoldRun.hs` line 917 and `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` line 585).
Delete both exports and definitions; keiro-dsl 0.11.0.0 exported them, so the removal
needs a Breaking Changes entry in `keiro-dsl/CHANGELOG.md`'s Unreleased section. After
deletion, check whether `legacyCheckedService` in ScaffoldRun's import (line 107) is still
used (line 307 `scaffoldModulesWithGoldens` still uses it — keep the import).

### Relevant ADRs

`docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md`
(ADR-18): records opaque `CheckedService` as "the sharing point for pure whole-spec
analyses" — it retains a lazy resolved type graph excluded from equality, display, and
serialization, and `checkedServiceWithSpec` is the only cache-safe spec replacement.
Item 1's supply-analysis cache is a second application of that recorded pattern; Item 2
consumes the existing cache. Consequence: the new field must never enter any serialized
record, fingerprint, or ledger, and the hand-written `Eq`/`Show` must not change.

`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`
(ADR-24): deterministic-id seeds hash as UTF-8 bytes via the frozen `identitySeedBytes`;
`legacySeedBytes` is a frozen reader for pre-0.12 identity; the compatibility bridge
probes UTF-8 first, legacy only for moved seeds; the bridge is removable no earlier than
0.13.0.0 under operator attestation. Item 6 implements this policy in one place without
changing it. The freeze is enforced by captured UUID literals in `keiro/test/Main.hs`
that are never regenerated from the implementation.

`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR-4):
the diff gate Item 1 threads through is layer 2 of the evolution contract; this plan must
not change any diagnostic or diff classification (plan 250 owns the one classification
fix in this area, which is why Milestone 4 lands after it).

No other local ADR bears on this work, and no cross-repository ADR applies (the changes
are internal to this repository's three packages).

### Prior plans incorporated by reference (all checked in)

`docs/plans/236-resolve-the-spec-type-graph-once-per-check-and-scaffold-run.md` — the
threading pattern and equivalence bar Items 1 and 2 follow: lazy derived field on the
opaque service, mechanical call-site conversion, proof by full suite plus corpus zero
drift, per-side caches for two-spec comparisons.
`docs/plans/240-bridge-deterministic-id-deduplication-across-the-utf-8-encoding-upgrade.md`
— the probe policy and golden vectors Item 6 must preserve.
`docs/plans/242-deduplicate-dispatch-and-retry-skeletons-and-fix-rebuild-read-amplification.md`
— the four-to-two loop collapse Item 3 finishes, and the telemetry-preservation decision
that constrains the extraction point.

This is a consolidation plan, not a fix plan: there is no defect to reproduce, so the
red-test-first rule for fixes does not apply. The equivalence bar takes its place — every
milestone's acceptance is "all existing gates green with byte-identical outputs", plus a
small number of additive unit examples where a new helper deserves direct pinning.


## Plan of Work

The work is five milestones. Milestones 1–3 are mutually independent and may proceed in
any order; Milestone 4 waits for plan 250; Milestone 5 is the final gate. Each of
Milestones 1–4 ends in exactly one commit containing its code, tests, and changelog edits.

### Milestone 1 — keiro: shared attempt driver and shared dual-probe helper (Items 3, 6)

Scope: `keiro/src/Keiro/Command.hs`, `keiro/src/Keiro/DeterministicId.hs`,
`keiro/src/Keiro/ProcessManager.hs`, `keiro/src/Keiro/Workflow/Awakeable.hs`,
`keiro/test/Main.hs` (additive examples only), `keiro/CHANGELOG.md`. At the end of this
milestone the module `Keiro.Command` contains exactly one attempt/plan skeleton, and the
dual-probe policy has exactly one implementation.

For Item 3, add an internal driver above `domainCommandAttempts` — the name
`domainCommandAttemptLoop` is suggested; it is not exported. Its shape:

```haskell
-- | The optimistic-concurrency attempt loop shared by the plain and
-- transactional domain command runners: hydrate, detect a conflict fixpoint,
-- prepare the plan, classify a silent decision, or hand an accepted batch to
-- the caller's append action. The append action receives the retry
-- continuation so 'retryOrFail' can re-enter the loop.
domainCommandAttemptLoop ::
  forall phi rs s ci co rejection noOp outcome es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  (DomainCommandOutcome (EventStream phi rs s ci co) co rejection noOp -> outcome) ->
  ( (Int -> Maybe (StoreError, StreamVersion) -> Eff es (Either CommandError outcome, Int)) ->
    Int ->
    Hydrated rs s ->
    NonEmpty co ->
    [EventData] ->
    Eff es (Either CommandError outcome, Int)
  ) ->
  Eff es (Either CommandError outcome, Int)
```

Its body is the existing `attempt`/`runPlan` pair moved verbatim from
`domainCommandAttempts`: `attempt attemptNo lastConflict` hydrates and dispatches;
`runPlan` checks `conflictFixpoint`, runs `prepareDomainCommandPlan`, and on
`DomainCommandSilent silentDecision result` returns
`(Right (wrapSilent DomainCommandOutcome {decision = domainDecisionFromSilent silentDecision, result}), attemptNo)`;
on `DomainCommandAppend current' events encoded` it calls
`appendAction attempt attemptNo current' events encoded`. Then `domainCommandAttempts`
becomes `domainCommandAttemptLoop options handler targetStream command id appendOnce`
where `appendOnce` is today's body with one new leading parameter (the retry
continuation, used in place of the closed-over `attempt` at the existing
`retryOrFail options attempt attemptNo …` call), and `domainSqlCommandAttempts` becomes
the same call with `DomainSqlCommandSilent` composed into the silent wrapper — note the
silent constructor wraps the whole `DomainCommandOutcome`, so the wrapper is simply
`DomainSqlCommandSilent` — and `appendWithSqlOnce` (also gaining the retry-continuation
parameter; its `KirokuStoreResource :> es` constraint stays on the enclosing function,
which is fine because the driver is polymorphic in `es`). Both public signatures, all
exported functions, and every call to `hydrate`, `conflictFixpoint`,
`prepareDomainCommandPlan`, `verifyAndSnapshot`, and `retryOrFail` keep their exact order
and arguments — telemetry (spans from `withCommandSpan` in the callers, conflict/retry/
duplicate metrics inside `retryOrFail`, decision recording in the public runners) is
byte-identical by construction.

For Item 6, add to `keiro/src/Keiro/DeterministicId.hs` (new imports: `Data.UUID (UUID)`,
`Data.UUID.V5 qualified as UUID.V5`; `NonEmpty (..)` re-exports from `Keiro.Prelude`):

```haskell
-- | Ordered candidate ids for one deterministic-id seed under the ADR 24
-- compatibility bridge: the current UTF-8-derived id first, the frozen
-- pre-UTF-8 id second only when the seed's bytes differ across encodings.
-- This is the single source of truth for the dual-probe policy; call sites
-- must not restate the ordering or the moved-seed condition.
deterministicIdProbes :: Text -> NonEmpty UUID
deterministicIdProbes seed =
  UUID.V5.generateNamed UUID.V5.namespaceURL (identitySeedBytes seed)
    :| [ UUID.V5.generateNamed UUID.V5.namespaceURL (legacySeedBytes seed)
       | seedMovedAcrossEncodings seed
       ]
```

Export it. In `keiro/src/Keiro/ProcessManager.hs`, `deterministicCommandIdProbes` (lines
501–506) becomes `fmap EventId (deterministicIdProbes (commandIdSeed managerName
correlationId sourceEventId emitIndex))`, and its Haddock's "single source of truth"
sentence moves to point at the new helper (this function remains the process-manager
probe surface ADR 24 names). `deterministicCommandId` (head of the probes) and
`legacyDeterministicCommandId` are untouched. In
`keiro/src/Keiro/Workflow/Awakeable.hs`, rewrite `allocateAwakeableId`'s `gen <= 0` branch
as a first-existing-row walk over
`fmap AwakeableId (deterministicIdProbes (awakeableSeed name wid label))`:

```haskell
allocateAwakeableId name wid gen label
  | gen <= 0 = adopt (NonEmpty.toList probes)
  | otherwise = freshAwakeableId
  where
    probes = fmap AwakeableId (deterministicIdProbes (awakeableSeed name wid label))
    freshAwakeableId = AwakeableId <$> liftIO UUID.V4.nextRandom
    adopt [] = freshAwakeableId
    adopt (candidate : rest) = do
      row <- lookupAwakeable (awakeableIdToUuid candidate)
      case row of
        Just _ -> pure candidate
        Nothing -> adopt rest
```

This is semantically identical to the current cascade: for an ASCII seed the probe list is
exactly `[current]` (one lookup, else fresh); for a moved seed it is `[current, legacy]`
(current lookup, then legacy lookup, else fresh) — the same lookups in the same order.
`deterministicAwakeableId` and `legacyDeterministicAwakeableId` are untouched. Add a
`Data.List.NonEmpty qualified as NonEmpty` import to Awakeable.hs if absent.

Add two pure examples to `keiro/test/Main.hs` next to the existing "adds a legacy command
probe only when the seed moved" example (line ~9990): one asserting
`deterministicIdProbes` over an ASCII seed is a single element equal to the UTF-8
derivation, and one asserting a non-ASCII seed yields exactly the UTF-8 id followed by the
legacy id (build the expectations from `identitySeedBytes`/`legacySeedBytes` directly, not
from the helper). Do not touch any existing example in the legacy-encoding-bridge
describe block or the two DB adoption examples.

Update `keiro/CHANGELOG.md` Unreleased → Added with one entry for the new
`Keiro.DeterministicId.deterministicIdProbes` export (state that probe order and
conditions are unchanged and shared by process-manager preflights and generation-0
awakeable adoption).

Commands and acceptance: `cabal build keiro` clean; `cabal test keiro-test` fully green
with `git diff --stat keiro/test/Main.hs` showing only the two added examples; the
command benchmark guard passes on a quiet machine (see Concrete Steps). Commit.

### Milestone 2 — keiro-ops: one non-negative reader (Item 4)

Scope: `keiro-ops/src/Keiro/Ops/Parse.hs`, `ReplayAudit.hs`, `Rebuild.hs`, `Snapshot.hs`,
`Stream.hs`, `Workflow.hs`, `keiro-ops/test/Main.hs` (additive examples),
`keiro-ops/CHANGELOG.md`. At the end of this milestone `grep -rn "nonNegativeInt64Reader\|generationReader" keiro-ops/src`
returns nothing.

Add to `keiro-ops/src/Keiro/Ops/Parse.hs` and its export list:

```haskell
-- | A bounded, non-negative integral reader whose failure message names the
-- domain concept being parsed (global position, stream version, generation).
nonNegativeReader :: forall a. (Integral a, Bounded a) => String -> ReadM a
nonNegativeReader message = eitherReader $ \raw ->
  case readBoundedIntegral raw of
    Just value | value >= 0 -> Right value
    _ -> Left message
```

Redefine the existing `nonNegativeIntReader` as
`nonNegativeReader "expected a non-negative integer"` (message unchanged). Then delete
the five local definitions and replace their uses, keeping each message byte-identical:
in `ReplayAudit.hs` (line ~55) and `Rebuild.hs` (line ~112) use
`nonNegativeReader "expected a non-negative global position"`; in `Snapshot.hs` (line
~73) and `Stream.hs` (lines ~79, ~92) use
`nonNegativeReader "expected a non-negative stream version"`; in `Workflow.hs` (line
~181) use `nonNegativeReader "expected a non-negative generation"`. The result types
(`Int64` under `GlobalPosition`/`StreamVersion` constructors, `Int` for the generation)
are inferred at each use site, so no type annotations are needed; add one only if GHC
asks. Extend each module's `Keiro.Ops.Parse` import (Rebuild currently imports only
`readBoundedIntegral`; ReplayAudit lacks `nonNegativeReader`; add it everywhere used).
`positiveInt32Reader` in Rebuild.hs stays (see Decision Log).

Add focused examples to `keiro-ops/test/Main.hs` using the existing `parseOps`/
`execParserPure` pattern (line ~97): for one command per touched module, assert that a
negative value fails to parse (`isParseFailure`) and a zero value succeeds — for example
`stream events --from -1` fails while `--from 0` succeeds, `wf … --generation -1` fails.
These pin the predicate; the byte-identical messages are visible in the diff as moved
string literals and covered by any existing message-asserting examples.

Update `keiro-ops/CHANGELOG.md` Unreleased → Added: `Keiro.Ops.Parse.nonNegativeReader`,
a message-parameterized bounded reader now backing the global-position, stream-version,
and generation options (messages and admission unchanged).

Commands and acceptance: `cabal build keiro-ops` clean; `cabal test keiro-ops-test` fully
green. Commit.

### Milestone 3 — keiro-dsl surface: selector list and shim deletion (Items 5, 7)

Scope: `keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs`,
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, `keiro-dsl/CHANGELOG.md`. At the end of this
milestone the `outcome` selector set has one spelling and the two dead exports are gone.

For Item 5, inside `pClause`'s first alternative (after `loc <- getLoc`), bind one list
and derive both the guard and the body from it:

```haskell
let outcomeSelectors :: [(Text, P (Clause, [Located SurfaceElement]))]
    outcomeSelectors =
      [ ("accepted", pure (COutcome (OutcomeAccepted loc), [])),
        ( "rejected",
          do
            expression <- withOwnedSpan (pExpr context)
            pure (COutcome (OutcomeRejected (locatedValue expression) loc), [mapLocated SurfaceExpression expression])
        ),
        ( "no-op",
          do
            expression <- withOwnedSpan (pExpr context)
            pure (COutcome (OutcomeNoOp (locatedValue expression) loc), [mapLocated SurfaceExpression expression])
        )
      ]
marker <-
  withOwnedSpan
    (try (keyword "outcome" <* lookAhead (choice [keyword name | (name, _) <- outcomeSelectors])))
requireLanguageFeatureAt context DomainCommandOutcomeSyntax (spanOf marker)
choice [keyword name *> handler | (name, handler) <- outcomeSelectors]
```

Order in the list must stay accepted, rejected, no-op — the same order as today's guard
and body, so backtracking behavior is unchanged (`keyword` is `lexeme . try`-wrapped, and
`a <|> b <|> c` is `choice [a, b, c]`). Keep the existing comment explaining the
contextual-keyword rule (plans 232/233), adjusting its wording only if line references in
it drift. If the implementer prefers hoisting a general `contextualKeyword` combinator
into `Parser/Core.hs`, that is acceptable — record the signature in the Decision Log —
but the local list is the planned form.

For Item 7, in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`: remove `pureRefusals,` (export
list line ~47) and `constraintPlan,` (line ~56), and delete the two definitions (lines
~527–528 and ~1103–1104). `pureRefusalsForService` and `constraintPlanForService` keep
their exports and Haddocks (move `pureRefusals`'s doc comment onto
`pureRefusalsForService` if it only lives on the deleted wrapper). Verify with the greps
in Concrete Steps that no caller exists anywhere in the repository (already confirmed at
planning time: the only occurrences are the definitions themselves; live callers use the
`ForService` variants at `ScaffoldRun.hs:373`, `ScaffoldRun.hs:917`, and
`WorkspaceScaffold.hs:585`). Keep the `legacyCheckedService` import: line ~307
(`scaffoldModulesWithGoldens`) still uses it.

Update `keiro-dsl/CHANGELOG.md` Unreleased → Breaking Changes with one entry: removes
`pureRefusals` and `constraintPlan` from `Keiro.Dsl.ScaffoldRun`; they were zero-caller
Spec-only shims left by the 0.12 retirement of Spec-only planning APIs; migrate by
calling `pureRefusalsForService`/`constraintPlanForService`, wrapping a bare `Spec` with
`legacyCheckedService` where a caller genuinely has no service.

Commands and acceptance: `cabal build keiro-dsl` clean; `cabal test keiro-dsl:tests`
fully green (the `:tests` suffix is mandatory — a bare `cabal test keiro-dsl` silently
skips the ~37 conformance suites); `just conformance-corpus-policy` reports zero drift.
Commit.

### Milestone 4 — keiro-dsl perf: shared supply analysis and cached graphs (Items 1, 2)

Scope: `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`, `Validate.hs`, `Scaffold.hs`,
`ScaffoldRecord.hs`, `Harness.hs`, `Diff.hs`, `ReplayImpact.hs`,
`keiro-dsl/CHANGELOG.md`. Pre-flight: confirm plan 250 is Complete in MasterPlan 40's
registry (see Decision Log), then regenerate the call-site inventory with the greps in
Concrete Steps and reconcile drifted line numbers before editing.

First, the cache (Item 1's sharing point). In
`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`: import `Keiro.Dsl.ProjectionSupply`
(`ProjectionSupplyAnalysis`, `analyzeProjectionSupplies`; ProjectionSupply imports only
Grammar and containers, so no cycle); add to the record an unbanged (lazy) field

```haskell
data CheckedService = CheckedService
  { serviceLanguageContract :: !EffectiveLanguageContract,
    serviceSpec :: !Spec,
    serviceTypeGraph :: Either (NonEmpty TypeGraphError) TypeGraph,
    serviceProjectionSupplies :: ProjectionSupplyAnalysis
  }
```

set `serviceProjectionSupplies = analyzeProjectionSupplies spec` inside
`checkedServiceForContract` (the single construction seam — every constructor and
`checkedServiceWithSpec` already route through it), and export a new accessor
`checkedProjectionSupplies :: CheckedService -> ProjectionSupplyAnalysis` with a Haddock
mirroring `checkedTypeGraph`'s ("shared, lazily forced … never serialized, excluded from
Eq and Show"). The hand-written `Eq`/`Show` instances need no edit — they already
enumerate only the two semantic fields.

Then convert Item 1's call sites. In `Validate.hs`: `validateService` passes
`checkedProjectionSupplies service` into `validateCheckedSpec`, whose (internal)
signature gains a `ProjectionSupplyAnalysis` parameter alongside the type-graph result;
thread it into `specLevelRules` → `validateProjectionCatalogFleet` (replacing the call at
line ~2396) and into `validateNode` → `validateProjectionOwner` (line ~2560) and
`validateReadModel` (line ~2683), each of which replaces
`resolvedProjectionSupplies (analyzeProjectionSupplies spec)` with
`resolvedProjectionSupplies supplyAnalysis`. Preserve the exact concatenation order in
`validateCheckedSpec` (line ~770): `sortOn line` is stable, so reordering the appended
sub-lists would reorder equal-line diagnostics and break byte-identity. The exported
`validateService`/`validateSpec` signatures are unchanged. In `Scaffold.hs`:
`ownerDerivedCursor` (line ~4102) and `scaffoldProjectionCatalogForService` (line ~4148)
read `checkedProjectionSupplies service`; the Spec-only `scaffoldProjectionCatalog` (line
~4140) keeps its direct call (one per invocation; it is a compatibility wrapper with test
callers). In `ScaffoldRecord.hs`: `projectionCatalogFactsForService` (line ~286) reads
the accessor; the Spec-only `projectionCatalogFacts` (line ~282) is unchanged. In
`Harness.hs`: `harnessReadModelForService` passes
`checkedProjectionSupplies service` into `emitReadModelHarness`, whose internal signature
gains a `ProjectionSupplyAnalysis` parameter used at line ~340 (it still needs the spec
for owner lookups). In `Diff.hs`: in `readModelDiff` (line ~1186) bind
`oldSupplies = analyzeProjectionSupplies (deOld env)` and
`newSupplies = analyzeProjectionSupplies (deNew env)` once, pass both into the internal
`readModelPairDiff`, and change `bindingIdentity`/`resolvedSupplier` (lines ~1263–1275)
to take the per-side analysis instead of the spec (the `deOld` side pairs with
`oldSupplies`, `deNew` with `newSupplies`). Do not modify the exported `DiffEnv` (see
Decision Log). Update the import lists of the four consumer modules to add
`checkedProjectionSupplies`.

Then Item 2, in `ReplayImpact.hs`. In `catalogReplayImpactServices`, change the local
`projectionImpactFor` (line ~159) to

```haskell
projectionImpactFor service = case checkedTypeGraph service of
  Left _ -> Nothing
  Right graph -> Just (ProjectionImpact.projectionMappedImpact service (semanticImpact graph))
```

(import `checkedTypeGraph` from `Keiro.Dsl.SemanticContract`; drop the now-unused
`resolveTypeGraph` import if nothing else in the module uses it after all edits). In
`replayImpactServices`, bind once per side

```haskell
oldGraphResult = checkedTypeGraph oldService
newGraphResult = checkedTypeGraph newService
oldSymbols = aggregateSymbolsFromGraphResult oldGraphResult oldSpec
newSymbols = aggregateSymbolsFromGraphResult newGraphResult newSpec
```

and thread the per-side `(graph result, symbols, spec)` — a small internal record or a
triple, implementer's choice — through `matchedAggregateImpact` into
`decodeSurfaceAffected`, `eventSurface`, `mappedFieldSurface`, and
`mappedRegisterSurface`, replacing their `Spec` parameters. `mappedFieldSurface`'s
`mapped` arm cases on the passed graph result instead of `resolveTypeGraph spec` (line
~271) and its `nominal` arm uses the passed symbols instead of `aggregateSymbols spec`
(line ~279); `mappedRegisterSurface` likewise (lines ~289, ~297). By definition
`aggregateSymbols spec = aggregateSymbolsFromGraphResult (resolveTypeGraph spec) spec`
and `checkedTypeGraph` caches exactly `resolveTypeGraph (checkedSpec service)`, so every
replacement is the identical value — the risk is only a wrong spec/side pairing, which
the suite and corpus catch. Every changed function is internal to the module; the export
list is untouched. Each side keeps its own graph and symbols — never share one across
old/new.

Update `keiro-dsl/CHANGELOG.md` Unreleased → Changed with one entry (following the
source-span-capture precedent): check, scaffold, harness, and diff now share one
projection-supply analysis per run and per diff side, and replay impact reads the cached
type graph; diagnostics, generated bytes, records, and diff reports are unchanged. Also
add an Added line for the new `checkedProjectionSupplies` accessor.

Commands and acceptance: `cabal build keiro-dsl` clean; `cabal test keiro-dsl:tests`
fully green; `just conformance-corpus-policy` zero drift; `just corpus-regen` followed by
`git status --short` shows no modified corpus file. Optional supporting evidence (record
in Surprises & Discoveries if gathered): the temporary trace-count technique from plan
236 applied to `analyzeProjectionSupplies` (one line of `Debug.Trace` at the top of the
function, never committed) showing one evaluation per `check`, one per `scaffold`, and
two per `diff` on a catalog-bearing fixture; and the committed
`type-graph` benchmark groups (`service-check`, `service-scaffold-plan` in
`keiro-dsl/bench/parser-scaling/Main.hs`) not regressing. Commit.

### Milestone 5 — full gate, evidence, and closure

Scope: no code. Run the complete repository gate `just verify` and re-run the command
benchmark guard; both must pass. Update this plan's Progress, Surprises & Discoveries,
and Outcomes & Retrospective; perform the ADR distillation pass (expected result: no ADR
edits — the Decision Log records why; revisit that judgment against the final diff);
update MasterPlan 40's Exec-Plan Registry row for this plan to Complete and its Progress
section. Append a Revision Note to this plan if any section changed during
implementation.

### Commit and trailer convention

Use Conventional Commits. Suggested subjects: M1
`refactor(keiro): consolidate command attempts and id probe policy`; M2
`refactor(ops): hoist the shared non-negative reader`; M3
`refactor(dsl)!: derive outcome selectors once and drop dead shims`; M4
`perf(dsl): share supply analysis and cached graphs on diff paths`. Every commit must
include the trailers:

```text
MasterPlan: docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md
ExecPlan: docs/plans/253-apply-the-deferred-consolidation-cleanups-from-the-fix-verification-review.md
Intention: intention_01kzw6dkcserms9yr61sqdntep
```


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Regenerate the call-site inventories before editing (and again if rebasing over plan
250). Expected hits are listed in Context and Orientation; reconcile any drift before
proceeding:

```bash
grep -rn "analyzeProjectionSupplies" keiro-dsl/src keiro-dsl/test
grep -rn "resolveTypeGraph\|aggregateSymbols spec" keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs
grep -n "attempt 1 Nothing\|runPlan\|appendOnce\|appendWithSqlOnce\|retryOrFail" keiro/src/Keiro/Command.hs
grep -rn "nonNegativeInt64Reader\|generationReader" keiro-ops/src
grep -n "outcome\"\|accepted\|rejected\|no-op" keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs | head -20
grep -rn "\bpureRefusals\b\|\bconstraintPlan\b" --include='*.hs' keiro-dsl keiro keiro-ops jitsurei
```

The last grep must show only the ScaffoldRun definitions/exports before Milestone 3 and
nothing after it.

Build and targeted suites, per milestone:

```bash
cabal build all
cabal test keiro-test        # Milestone 1
cabal test keiro-ops-test    # Milestone 2
cabal test keiro-dsl:tests   # Milestones 3 and 4 (the :tests suffix is mandatory)
```

Every suite must end `PASS`/`All … examples … passed`. Run cabal invocations serially —
plan 242 recorded that concurrent `cabal test` runs race on the shared `dist-newstyle`
cache.

Command benchmark baseline guard (Milestone 1 and again at Milestone 5, on a quiet
machine — plan 242 recorded that a busy host produces invalid samples). This is the
`command` pattern line of `just bench-regression`:

```bash
cabal bench keiro-bench --benchmark-options="-p command --time-mode wall --hide-progress --baseline bench/baseline-command.csv --fail-if-slower 25"
```

Expected output: every `command` case reports `OK` against the committed
`keiro/bench/baseline-command.csv` with no case exceeding the 25% slowdown gate (the run
fails loudly otherwise). Running all three lines via `just bench-regression` is also
fine.

Conformance-corpus gates (Milestones 3 and 4):

```bash
just conformance-corpus-policy
just corpus-regen
git status --short
```

Expected: the policy check exits zero; after regeneration `git status --short` lists no
corpus file — only this plan file and any in-flight source edits you have not yet
committed.

Golden-vector and adoption checks stay untouched (Milestone 1). After the keiro edits:

```bash
git diff --stat keiro/test/Main.hs
```

must show only the two added probe-composition examples; the describe blocks
"Keiro deterministic id legacy-encoding bridge" and the generation-0 adoption examples
("adopts a generation-0 legacy deterministic row", "adopts a pre-UTF-8 generation-0 row
for a non-ASCII label") pass without any edit. The keiro-test suite is DB-backed through
the suite-level template-database fixture from `keiro-test-support` (ephemeral-pg); the
new examples here are pure and need no database work, and any DB-backed example you do
add must follow the existing suite fixture pattern, never per-example migrations.

Optional Milestone 4 trace evidence (never commit the patch): add
`import Debug.Trace (trace)` to `keiro-dsl/src/Keiro/Dsl/ProjectionSupply.hs` and prefix
`analyzeProjectionSupplies`'s body with `trace "analyzeProjectionSupplies:begin" $ …`,
then:

```bash
cabal run -v0 keiro-dsl -- check <catalog-bearing .keiro fixture> 2>&1 | grep -c "analyzeProjectionSupplies:begin"
git checkout -- keiro-dsl/src/Keiro/Dsl/ProjectionSupply.hs
```

Expected count: 1 (and 1 for `scaffold`, 2 for `diff` old→new). Any catalog fixture under
`keiro-dsl/test/fixtures/` with `projection` targets and a grouped read model works.

Full gate (Milestone 5):

```bash
just verify
```

which runs process-compose checks, the jitsurei demo build, `cabal build all`, all
package suites, ADR/research/capabilities validation, extension and generated-name
policies, the conformance-corpus policy, and `cabal test keiro-migrations-test`. It must
exit zero.

Commit at the end of each of Milestones 1–4 with the subjects and trailers given in Plan
of Work, including the package CHANGELOG edit and this plan's Progress update in the same
commit.


## Validation and Acceptance

Acceptance is behavioral equivalence plus visible consolidation, per milestone:

Milestone 1: `cabal test keiro-test` passes with zero edits to the plan-240 golden
vectors and adoption examples; the command benchmark guard passes against the committed
baseline; `keiro/src/Keiro/Command.hs` contains exactly one occurrence of
`conflictFixpoint lastConflict` (the shared driver) where today there are two; the
dual-probe ordering (`identitySeedBytes` first, `legacySeedBytes` guarded by
`seedMovedAcrossEncodings`) appears exactly once in `keiro/src`, inside
`Keiro.DeterministicId`.

Milestone 2: `cabal test keiro-ops-test` passes; `grep -rn "nonNegativeInt64Reader\|generationReader" keiro-ops/src`
returns nothing; the three error message strings ("…global position", "…stream version",
"…generation") each still appear exactly where their options are declared, verbatim; a
negative `--from`, `--before`, `VERSION` argument, or `--generation` still fails to parse
and zero still succeeds (the new examples prove this through `execParserPure`).

Milestone 3: `cabal test keiro-dsl:tests` passes — in particular the parser suites
covering `outcome` as a contextual keyword versus an identifier (the language-1–4
identifier acceptance and the language-5 outcome clauses) — and
`just conformance-corpus-policy` reports zero drift; the selector words `accepted`,
`rejected`, `no-op` appear exactly once in `pClause`; `pureRefusals` and `constraintPlan`
resolve nowhere in the repository; the keiro-dsl CHANGELOG Breaking Changes entry exists.

Milestone 4: `cabal test keiro-dsl:tests` passes (this includes the diff, replay-impact,
validation-diagnostic, harness, and scaffold-record suites that pin exact outputs);
`just conformance-corpus-policy` and a `just corpus-regen` + clean `git status --short`
prove generated bytes unchanged; `grep -rn "analyzeProjectionSupplies" keiro-dsl/src`
shows only: the definition (ProjectionSupply.hs), the construction seam
(SemanticContract.hs), the two Spec-only wrappers (Scaffold.hs
`scaffoldProjectionCatalog`, ScaffoldRecord.hs `projectionCatalogFacts`), and the two
per-side hoists in Diff.hs `readModelDiff`; `grep -n "resolveTypeGraph" keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`
returns at most the import line (none if the import is dropped).

Plan-level: `just verify` passes at the end. The change is internal, so its effect beyond
compilation is demonstrated by (a) the consolidation greps above, (b) the benchmark guard
holding the command path inside its committed baseline, and (c) optionally the
trace-count transcript showing the supply analysis running once per check/scaffold and
twice per diff (recorded in Surprises & Discoveries).


## Idempotence and Recovery

Every step is a source edit plus a build/test run; all are safely repeatable. Builds,
tests, benchmarks, and the corpus policy check are read-only with respect to committed
state; `just corpus-regen` is idempotent (an unchanged generator yields unchanged bytes —
the property this plan relies on). The optional trace patch is a two-line local edit
reverted with `git checkout -- keiro-dsl/src/Keiro/Dsl/ProjectionSupply.hs`; never commit
it.

Milestones are independent commits in independent packages (Milestones 3 and 4 touch
keiro-dsl but disjoint files), so any milestone can be reverted alone without breaking
the others. Within Milestone 4, the field addition (SemanticContract.hs) is inert until a
consumer reads it, so if a suite or the corpus fails mid-milestone, bisect by reverting
one consumer file at a time (Validate, Scaffold, ScaffoldRecord, Harness, Diff,
ReplayImpact are each independently revertible to the direct-call form). Do not proceed
to the next milestone with a red suite, a drifting corpus, or a failing benchmark guard.
If plan 250 lands mid-flight after Milestone 4 started, rebase and re-run the Milestone 4
gates; the overlap is confined to `readModelPairDiff` in Diff.hs and reconciles
mechanically (250 changes what `policyChanges` emits; this plan changes only where the
supply analysis comes from).


## Interfaces and Dependencies

No new external dependencies. `uuid` (for `Data.UUID.V5`) is already a keiro dependency;
`Keiro.Prelude` (keiro-core) already re-exports `NonEmpty (..)`; `optparse-applicative`
already backs `Keiro.Ops.Parse`; `tasty-bench` already backs both benchmark suites.

At the end of Milestone 1, `keiro/src/Keiro/DeterministicId.hs` additionally exports:

```haskell
deterministicIdProbes :: Text -> NonEmpty UUID
```

`Keiro.Command`'s export list is unchanged (the driver, suggested name
`domainCommandAttemptLoop`, is internal); `Keiro.ProcessManager.deterministicCommandIdProbes`
and the four frozen derivation functions keep their exact signatures and semantics.

At the end of Milestone 2, `keiro-ops/src/Keiro/Ops/Parse.hs` additionally exports:

```haskell
nonNegativeReader :: forall a. (Integral a, Bounded a) => String -> ReadM a
```

with `nonNegativeIntReader` redefined through it (same type, same message).

At the end of Milestone 3, `Keiro.Dsl.ScaffoldRun` no longer exports `pureRefusals` or
`constraintPlan`; `pureRefusalsForService :: Context -> CheckedService -> [ScaffoldModule] -> [Refusal]`
and `constraintPlanForService :: CheckedService -> ConsumerPlan -> [Text]` are unchanged.
`Keiro.Dsl.Parser.Aggregate` exports nothing new.

At the end of Milestone 4, `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` additionally
exports:

```haskell
checkedProjectionSupplies :: CheckedService -> ProjectionSupplyAnalysis
```

over a private lazy field excluded from `Eq`/`Show` and never serialized; `Keiro.Dsl.SemanticContract`
newly imports `Keiro.Dsl.ProjectionSupply` (no cycle). Internal signatures in Validate.hs
(`validateCheckedSpec`, `specLevelRules`, `validateNode`, `validateProjectionCatalogFleet`,
`validateProjectionOwner`, `validateReadModel`), Harness.hs (`emitReadModelHarness`),
Diff.hs (`readModelPairDiff` and its `bindingIdentity`/`resolvedSupplier` locals), and
ReplayImpact.hs (`matchedAggregateImpact`, `decodeSurfaceAffected`, `eventSurface`,
`mappedFieldSurface`, `mappedRegisterSurface`) gain threaded analysis/graph/symbols
parameters; none of these is exported. All public signatures across the three packages
other than the listed additions and the two listed removals are byte-identical.

Sequencing dependencies: Milestone 4 starts after plan 250
(`docs/plans/250-report-legacy-strong-consistency-weakening-across-the-language-4-to-5-migration-in-diff.md`)
is Complete (soft dependency, per MasterPlan 40's dependency graph); Milestones 1–3 have
no dependencies and may start immediately, in any order. This plan is non-gating for
0.12.0.0. No ADR is expected to change (Decision Log); the ADR distillation pass at
completion re-checks that judgment.
