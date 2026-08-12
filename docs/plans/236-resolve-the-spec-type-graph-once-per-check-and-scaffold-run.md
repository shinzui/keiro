---
id: 236
slug: resolve-the-spec-type-graph-once-per-check-and-scaffold-run
title: "Resolve the spec type graph once per check and scaffold run"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjznhgeyvbcpfk1znzmbnr"
master_plan: "docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md"
---

# Resolve the spec type graph once per check and scaffold run

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl` is the typed specification language and toolchain for keiro services: a user
writes a `.keiro` spec, runs `keiro-dsl check` to validate it, and runs `keiro-dsl scaffold`
to generate deterministic Haskell modules plus typed holes. keiro-dsl targets fleet adoption
on large multi-aggregate workspaces, so the latency of one `check` or `scaffold` invocation
is a product surface, not an implementation detail.

Today, one `check` or `scaffold` invocation re-resolves the spec's mapped type graph — a
whole-spec analysis whose cost includes a per-declaration reachability walk that is quadratic
in the number of mapped declarations — dozens of times over the byte-identical spec value.
Each declarative router validation resolves it again; each aggregate's scaffold resolution
resolves it at least four more times (directly, through symbol tables, and through the fold
fingerprint); the scaffold planning pipeline builds its module plan twice and pays the whole
bill twice. The 2026-08-11 pre-release review confirmed this as an efficiency defect
(masterplan EP-4): a spec with N declarative routers resolves the graph N+1 times inside one
validation pass alone, and a scaffold run repeats the full-spec resolution many more times.

After this change, the graph is resolved exactly once per checked service value — which means
once per `check` invocation and once per `scaffold` invocation — and every consumer shares
that single resolution. This is a behavior-preserving performance refactor: every observable
output must remain byte-identical, including diagnostics and their order, generated modules,
scaffold records, diff reports, and fold fingerprints. You can see it working in two ways:
a committed benchmark whose check/scaffold-scale timings drop on graph-heavy fixtures, and a
temporary trace count showing the resolution count fall from dozens to exactly one, while the
full keiro-dsl test suite and the conformance-corpus zero-drift gate prove equivalence.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Confirm plan 234 status; regenerate and reconcile the resolveTypeGraph call-site inventory against the tree at implementation time.
- [x] M1: Add the `type-graph` fixture generator and `service-check` / `service-scaffold-plan` benchmark groups to `keiro-dsl/bench/parser-scaling/Main.hs`.
- [x] M1: Record baseline benchmark timings and a baseline trace count in Surprises & Discoveries.
- [x] M2: Add the lazy `checkedTypeGraph` field to `CheckedService` with hand-written Eq/Show; update all direct construction sites.
- [x] M2: Full suite green, corpus zero drift with the field present but unconsumed.
- [ ] M3: Thread the shared graph through the check pass (Validate.hs, RouterSelection.hs, ExplainBindings.hs, Coverage path).
- [ ] M3: Trace count for `keiro-dsl check` on the declarative-router fixture is exactly 1.
- [ ] M4: Thread the shared graph through the scaffold run (Scaffold.hs, ScaffoldRun.hs, AggregateType symbols, FoldFingerprint, Harness, ServiceHarness, StructuralConformance, MappedConsumer, ReadModelQueryContract, CoordinationImpact, ProjectionMappedImpact, Goldens, Workspace hoist).
- [ ] M4: Trace count for `keiro-dsl scaffold` on the declarative-router fixture is exactly 1.
- [ ] M5: Full `cabal test keiro-dsl:tests` green; `just conformance-corpus-policy` zero drift; regenerated corpus produces no git diff.
- [ ] M5: After-timings recorded next to the baselines; resolution-count reduction documented with evidence.
- [ ] M5: ADR distillation pass done; masterplan 36 registry row for this plan updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- M1 baseline (2026-08-12, GHC 9.12.4, `-O1`): the committed `type-graph`
  benchmark measured `service-check` at m16-r2 160 us +/- 16 us, m32-r4 367 us
  +/- 33 us, m64-r8 1.19 ms +/- 108 us, and m64-r16 1.33 ms +/- 132 us.
  `service-scaffold-plan` measured m16-r2 5.03 ms +/- 415 us, m32-r4 24.2 ms
  +/- 2.1 ms, m64-r8 166 ms +/- 15 ms, and m64-r16 307 ms +/- 18 ms. The
  temporary `Debug.Trace` counter on the shipped declarative-router fixture observed 34
  resolutions for one `check` and 46 for one `scaffold`; the trace patch was removed
  immediately after measurement.
- The reconciled post-plan-234 inventory retained every expected Class A/B/C site and added
  no new `resolveTypeGraph` consumer. Plan 235 had removed only the forecast Spec-only
  planning wrappers, so it reduced entry-point surface without changing the hot call graph.
- M2 confirmed that `SemanticContract` can import `TypeGraph` without a cycle. One additional
  direct construction seam existed in `Scaffold.aggregateCheckedService` beyond the original
  inventory; routing it, workspace composition, compatibility bridges, and tests through
  `checkedServiceForContract` leaves graph initialization in one implementation. The complete
  test surface remained green (695 main examples plus every declared conformance suite), and
  the 39-entry corpus policy reported zero drift while no consumer read the new field.


## Decision Log

Record every decision made while working on the plan.

- Decision: Cache the resolved type graph as a lazy (non-strict) field on `CheckedService`
  rather than threading a `TypeGraph` parameter through every public signature.
  Rationale: `CheckedService` is already the one value that flows through the entire check
  and scaffold pipeline (`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`), so a lazy field
  gives sharing "once per service value" with no cost when unused (GHC evaluates the thunk
  at first demand and every later reader reuses the forced result). `resolveTypeGraph` is a
  pure function of the spec, so the cached value is definitionally identical to what each
  call site computed before. Spec-only compatibility wrappers keep working unchanged: each
  `legacyCheckedService` call builds a fresh service whose thunk is resolved at most once
  for that call. StrictData is not enabled in keiro-dsl (verified in `keiro-dsl.cabal`
  common stanzas), so an unbanged field is lazy.
  Date: 2026-08-11.
- Decision: Replace the derived `Eq`/`Show` instances of `CheckedService` with hand-written
  instances over only `checkedLanguageContract` and `checkedSpec`.
  Rationale: derived instances would include the new field — `Show` output would change
  (observable byte change) and `Eq` would force the thunk (performance change and needless
  work). The manual instances reproduce the derived behavior for the two semantic fields
  exactly, so no observable output changes. `CheckedService` has no ToJSON/FromJSON/NFData
  instances (verified), so no serialization or deep-forcing surface exists; the graph
  cannot leak into scaffold records, fingerprints, or ledgers.
  Date: 2026-08-11.
- Decision: `resolveTypeGraph` itself stays exported and unchanged; equivalence is proven by
  the full test suite plus conformance-corpus zero drift, not argued from purity alone.
  Rationale: purity makes the shared value identical, but the mechanical refactor (wrong
  spec/graph pairing, reordered list concatenation, a site accidentally resolving a
  different spec) is where regressions would hide; the corpus gate and suite catch those.
  Date: 2026-08-11.
- Decision: Two-spec comparison paths (Diff.hs, MappedDiff.hs, ReplayImpact.hs old-versus-new)
  are out of the single-resolution invariant; each side uses its own service's cached graph.
  A single shared graph there would be unsound — the specs differ by construction.
  Date: 2026-08-11.
- Decision: The parallel redundancy in `resolveNominalTypes` (same shape of problem, visible
  in `aggregateSymbols` and `ExplainBindings`) is out of scope except where hoisting
  `aggregateSymbols` already removes both. Widening scope would grow the review surface of
  a refactor whose whole safety story is byte-identical output. Record it as a candidate
  follow-up in Outcomes & Retrospective.
  Date: 2026-08-11.
- Decision: Implement after plan 234
  (`docs/plans/234-bind-catalog-read-models-to-one-explicit-physical-target.md`) lands, or,
  if 234 has not landed when this plan starts, re-reconcile the call-site inventory below
  against the tree first and coordinate on any sites 234 adds or moves in
  `keiro-dsl/src/Keiro/Dsl/Validate.hs` and `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`.
  This plan must not add, remove, or renumber `DiagnosticCode` values (masterplan 36
  integration constraint; plan 234 owns all code additions).
  Date: 2026-08-11.
- Decision: Benchmark methodology — every measured function must construct the
  `CheckedService` from the spec inside the benchmarked closure, so each iteration pays
  exactly one resolution. Benchmarking a pre-built service would force the cached thunk on
  iteration one and measure nothing on later iterations, making before/after numbers
  incomparable.
  Date: 2026-08-11.
- Decision: Plan 234 was Complete before implementation began, and the regenerated call-site
  inventory matched this plan's classification after accounting for shifted line numbers.
  Therefore EP-4 can follow the planned service-sharing seam without any diagnostic-code or
  catalog-binding coordination change.
  Date: 2026-08-12.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation. Expected distillation targets: if the cached
lazy field pattern proves durable, record it as an ADR note on `CheckedService` being the
sharing point for whole-spec analyses; carry the `resolveNominalTypes` follow-up here.)


## Context and Orientation

This repository is a Haskell multi-package cabal project rooted at the repository top level
(the directory containing `Justfile` and `cabal.project`). All commands in this plan run from
that repository root. The package under change is `keiro-dsl` (directory `keiro-dsl/`, cabal
file `keiro-dsl/keiro-dsl.cabal`), which contains the library under `keiro-dsl/src/`, the CLI
executable `keiro-dsl` under `keiro-dsl/app/Main.hs`, about forty test suites under
`keiro-dsl/test/`, and two benchmark suites under `keiro-dsl/bench/` (`keiro-dsl-codec-bench`
in `bench/structural-codec`, `keiro-dsl-parser-bench` in `bench/parser-scaling`; the latter
was added by `docs/plans/229-eliminate-repeated-suffix-scans-from-keiro-dsl-source-span-capture.md`
and already carries synthetic source, workspace, and outcome scaling fixtures).

Definitions used throughout this plan:

A "spec" is the parsed semantic graph of one `.keiro` source or one composed workspace: the
`Spec` type in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`.

The "type graph" is the checked, resolved view of a spec's consumer-owned mapped type
declarations: the `TypeGraph` record in `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` (line ~294).
It holds resolved declarations (`tgDeclarations`), per-declaration transitive reachability
(`tgReachability`), the spec-wide list of places mapped types are consumed (`tgUseSites`,
`tgRootSegments`), and derived projection-consumer inventories. It is produced by
`resolveTypeGraph :: Spec -> Either (NonEmpty TypeGraphError) TypeGraph` (same module, line
~306). Resolution walks every mapped declaration, checks ambiguity against ids/enums/builtins,
resolves every reference, rejects cycles via strongly connected components, computes
`tgReachability` with `Map.mapWithKey (reachableFrom declarations) declarations` — a
depth-first walk per declaration, so quadratic in mapped declarations in the worst case — and
walks every aggregate command/event/register, workqueue payload, and read-model query in the
spec to collect use sites. It is a pure function: for equal specs it returns equal results.

A "checked service" is the value pairing a spec with the effective language contract it was
checked under: `CheckedService` in `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` (line ~152),
currently two strict fields (`checkedLanguageContract`, `checkedSpec`) with derived `Eq` and
`Show`, no JSON or NFData instances. Constructed by `checkedSource` (from a parsed source),
`checkedService` (from a source language plus spec), `legacyCheckedService` (Spec-only
compatibility, selects legacy semantics), by direct record construction in
`checkedWorkspace` (`keiro-dsl/src/Keiro/Dsl/Workspace.hs` line ~766), and by direct
constructor application in `keiro-dsl/src/Keiro/Dsl/ExplainBindings.hs` (lines ~141 and ~157).

A "check pass" is one evaluation of `validateService :: CheckedService -> [Diagnostic]`
(`keiro-dsl/src/Keiro/Dsl/Validate.hs` line ~743). The CLI `check` command
(`keiro-dsl/app/Main.hs`, `run (Check ...)` at line ~508) builds one service with
`checkedSource`, then calls `checkIndexedServiceDiagnostics`
(`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` line ~458), which runs `validateService` and, when
validation does not block, also runs the pure scaffold planner over the same service — so one
`check` invocation exercises both the validation and planning surfaces on one service value.

A "scaffold run" is one CLI `scaffold` invocation (`app/Main.hs` line ~545): it builds one
service with `checkedSource`, runs `validateService` as a gate, plans modules with
`planIndexedServiceScaffoldWithRuntimePackageAndGoldens` (ScaffoldRun.hs line ~355 — note it
builds the full module plan twice, `baseModulePlan` and `completeModulePlan`, to preserve
refusal precedence, doubling any per-plan cost), then executes writes and drift reporting in
`executeServiceScaffoldWithRuntimePackageAndNameMigrations` (ScaffoldRun.hs line ~864), whose
`where` block binds `spec = checkedSpec service` — every Spec-only helper it calls receives
the identical spec value carried by the service.

The "conformance corpus" is the committed generated output compiled and asserted by the
`keiro-dsl-conformance-*` test suites. `scripts/check-conformance-corpus.sh` (invoked by
`just conformance-corpus-policy`) runs `cabal run -v0 keiro-dsl-corpus-regen -- check`, which
fails if regenerating the corpus would change any committed byte. `just corpus-regen`
regenerates in place. Zero drift after this refactor is the primary byte-equivalence proof.

A "declarative router" is the language-5 candidate `resolve declarative { ... }` router form:
its validation (`RouterSelection.checkRouterSelection`, called from `validateRouter` in
Validate.hs) and its generation (`scaffoldRouterForService` in Scaffold.hs) both need the type
graph. A valid example lives at `keiro-dsl/test/fixtures/declarative-router/valid.keiro`.

Relevant ADRs (local, repository-relative paths; read them before editing):

`docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md` (ADR-18)
freezes aggregate replay-fold identity: persisted pre-hash bytes come only from the frozen
canonical encoder, and fold-surface construction is total, with type-graph resolution failures
surfacing as `FoldSurfaceError`. Consequence for this plan: the fold fingerprint
(`keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`) consumes the graph, so the shared graph value
must be identical to what per-site resolution produced (it is, by purity), and the cached
graph must never itself enter any serialized record, fingerprint, or ledger — it is derived
state, not identity. `CheckedService` has no serialization instances, and the scaffold record
(`renderRecord`/`currentRecord` in ScaffoldRun.hs) writes only explicit derived fields, so the
field addition cannot leak; the hand-written `Show` keeps even debug output unchanged.

`docs/adr/0030-declarative-router-selection-is-bounded-target-normalized-and-coordination-versioned.md`
(ADR-30) defines the declarative router selection contract whose checker and generator are the
heaviest per-node graph consumers this plan de-duplicates. Selection checking, selection
fingerprints, and coordination snapshots must produce identical results — this plan only
changes how many times the identical graph value is computed, never what it contains.

No cross-repository ADR applies to this work (searched the mori registry context; the change
is entirely internal to keiro-dsl's resolution plumbing).

Parent masterplan: `docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md`,
EP-4. Constraints inherited from it: EP-4 is soft-dependent on EP-2 (plan 234, which changes
catalog read-model resolution in Validate.hs/ScaffoldRun.hs — see Decision Log); EP-4 must
not add, remove, or renumber `DiagnosticCode` values in Validate.hs; and the adjacent plan
235 (EP-3) may retire the legacy Spec-only scaffold entry points at the top of ScaffoldRun.hs
— if 235 has landed first, some Spec-only compatibility wrappers named below may no longer
exist, which only shrinks this plan's surface.

The call-site inventory. The following is every `resolveTypeGraph` call site in
`keiro-dsl/src` as of 2026-08-11 (line numbers will drift; regenerate before editing with
the grep command in Concrete Steps and reconcile). Classification: (A) sites inside one check
pass or scaffold run that resolve the identical spec carried by the one in-flight
`CheckedService` — all must converge on the single cached resolution; (B) two-spec comparison
sites — each side uses its own service's cached graph; (C) opt-in or per-invocation sites
outside the hot loop — convert where a service is in hand, otherwise leave and note.

Class A, check pass: `Validate.hs:1047` (`validateMapped`, once per pass);
`Validate.hs:3569` (`validateRouter` selection checks, once per declarative router — this is
the N+1 multiplier); `RouterSelection.hs:323` amplifies further by calling
`aggregateSymbols spec` (which itself resolves the graph at `AggregateType.hs:97`) once per
dispatched command field inside `checkRouterSelection`; `ExplainBindings.hs:144` and `:160`
(`bindingObligationsForService`/`bindingHolesForService`, reached from `check
--explain-bindings` and from the scaffold record); `Coverage.hs:186` (check coverage).

Class A, scaffold plan and execute: `Scaffold.hs:587` (`resolveAggForService`, once per
aggregate, plus `aggregateSymbols` at `Scaffold.hs:595` resolving again via
`AggregateType.hs:97`); `Scaffold.hs:743` (`scaffoldStructuralOwnersForService`);
`Scaffold.hs:3489` (`scaffoldWorkqueueForService`, per typed workqueue); `Scaffold.hs:4068`
(`scaffoldReadModelForService`, per typed-query read model); `Scaffold.hs:4782`
(`scaffoldRouterForService`, per declarative router, which then calls
`checkRouterSelection` re-triggering the RouterSelection amplification);
`FoldFingerprint.hs:72` (`aggregateFoldSurfaceForService`, per aggregate, plus its
`aggregateSymbols` at line ~92); `Harness.hs:208` and the `resolveAggForService` call at
`Harness.hs:95`; `ServiceHarness.hs:220` (`serviceHarnessModule`);
`StructuralConformance.hs:49` and `:57` (conformance planning); `ScaffoldRun.hs:1155`
(`constraintPlan`); `ScaffoldRun.hs:1189` (`checkedSemanticImpactSnapshot`);
`MappedConsumer.hs:144` (`consumerPlan`, called from ScaffoldRun lines ~786, ~924, ~1326);
`ReadModelQueryContract.hs:91-93` (`queryContractIdentities`, ScaffoldRun line ~926);
`CoordinationImpact.hs:212` (`routerSelectionStates`, behind `routerSelectionSnapshots`,
ScaffoldRun line ~938); `ProjectionMappedImpact.hs:121` and `:141`
(`projectionMappedImpactForService`, ScaffoldRun line ~975); `Goldens.hs:151`
(`loadGoldenPayloads`, once per scaffold CLI invocation); `Expression.hs:56`
(`environmentTypeGraph` in the typed-expression environment); `AggregateType.hs:97`
(`aggregateSymbols` — the shared amplifier, also reached from `Validate.hs:813` and `:1741`,
`EventOutput.hs:90`, `Manifest.hs:212`, `ReplayImpact.hs:279`/`:297`).

Class B, two-spec comparisons (each side keeps its own resolution): `Diff.hs:921` and
`Diff.hs:977` (`mappedSemanticImpactForServices` resolves old and new specs);
`MappedDiff.hs:41` (`diffMapped oldSpec newSpec`); `ReplayImpact.hs:159`, `:271`, `:289`
(replay impact over old/new services).

Class C, opt-in or leaf: `Scaffold.hs:777` (`codecComparisonModule`, only on an explicit
`--compare-codec`-style request; the CLI has the service in scope at `app/Main.hs:563`, so
converting is cheap but optional). Test-only call sites in `keiro-dsl/test/Main.hs` (lines
~210, ~4033, ~4040, ~11335, ~11978, ~12132) stay as they are — they deliberately exercise
`resolveTypeGraph` directly.

Spec-identity analysis (the soundness precondition for sharing). Within one check pass, every
Class A site receives the spec threaded down from `validateCheckedSpec` (Validate.hs line
~754), which receives `checkedSpec service` from `validateService` — one value. Within one
scaffold run, `scaffoldServiceModulesWithBehaviorSource` (ScaffoldRun.hs line ~270) and
`executeServiceScaffoldWithRuntimePackageAndNameMigrations` (line ~864) both bind
`spec = checkedSpec service` and pass exactly that value to every helper — one value. The
workspace path validates only the merged spec (`checkWorkspace` in Workspace.hs line ~777
runs `validateService (checkedWorkspace workspace)` over `wsMergedSpec`); per-member specs
are parsed but never independently graph-resolved on this path. The only sites that resolve
a different spec are the Class B old/new comparisons, which this plan keeps per-side.
`resolveCatalogReadModel` (ScaffoldRun.hs line ~307) rewrites a read-model *node* before
scaffolding but never re-enters `resolveTypeGraph` with a modified spec; plan 234 changes
this area, which is why the inventory must be reconciled at implementation time.

Public-API note: keiro-dsl 0.11.0.0 is published; the next release (0.12.0.0) is a major
release, so signature changes are permitted, but this plan deliberately minimizes exported
churn: exported Spec-only functions (`validateSpec`, `constraintPlan`, `consumerPlan`,
`bindingObligations`, `codecComparisonModule`, ...) keep their signatures; only internal
helpers change shape, and new `...ForService`/graph-threaded internals carry the sharing.


## Plan of Work

The work is five milestones. The design in one sentence: add a lazy, non-serialized,
instance-invisible field `checkedTypeGraph :: Either (NonEmpty TypeGraphError) TypeGraph` to
`CheckedService`, built by every constructor from `checkedSpec`, and convert every Class A
call site to read that field (directly where a service is in scope, or via a threaded
parameter where only a `Spec` was passed), so that Haskell's lazy evaluation makes the first
reader pay for resolution once and every later reader reuse the forced result.

Milestone 1 — baseline evidence and benchmark scaffolding. Scope: no library behavior
changes; add measurement so before/after is demonstrable. Reconcile the call-site inventory
against the current tree (plan 234 may have landed). Extend
`keiro-dsl/bench/parser-scaling/Main.hs` with a `type-graph` fixture generator and two new
benchmark groups. The generator emits a valid candidate-language-5 source (crib the concrete
syntax from `keiro-dsl/test/fixtures/declarative-router/valid.keiro`, which shows mapped
structural records, a typed read model with `query input`/`query result`, a projection
target/owner, an aggregate, and a `resolve declarative` router) parameterized by the number
of mapped declarations M (chained by reference so reachability has depth) and the number of
declarative routers R (each router re-uses the one typed read model and target aggregate).
Register shapes such as (M, R) in {(16, 2), (32, 4), (64, 8), (64, 16)}. The
`service-check` group benchmarks one full check pass; the `service-scaffold-plan` group
benchmarks one full pure scaffold plan. Critically, each measured closure must build the
service from the parsed spec inside the closure (see Decision Log) — for example:

    -- inside benchmarks, given a pre-parsed, pre-forced ParsedSource fixture:
    bench (typeGraphLabel fixture) $
      nf (\parsed -> map line (validateService (checkedSource parsed))) fixtureParsed

and for the plan group force the produced module text, for example
`nf (\parsed -> map moduleText (scaffoldServiceModules ctx (checkedSource parsed))) fixtureParsed`
(imports for `scaffoldServiceModules` come from `Keiro.Dsl.ScaffoldRun`; `line` is the
`Diagnostic` field in `Keiro.Dsl.Validate`; adapt to what the module exports — the bench file
already imports `validateService` and `checkedSource`). Preflight each fixture the way the
existing fixtures do (parse must succeed, check must be diagnostic-clean) so the benchmark
never measures an error path. Run the new groups and record baseline timings in Surprises &
Discoveries. Then take the baseline resolution count: apply the temporary (uncommitted) trace
patch from Concrete Steps and record the counts for one `check` and one `scaffold` of the
declarative-router fixture. Acceptance: `cabal bench keiro-dsl-parser-bench
--benchmark-options="-p type-graph"` runs green; baselines are written into this plan; the
working tree contains only the bench change (the trace patch is reverted).

Milestone 2 — the cached graph on CheckedService. Scope: introduce the sharing point without
consuming it anywhere, so this milestone is trivially behavior-preserving and independently
verifiable. In `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`: import `Keiro.Dsl.TypeGraph`
(TypeGraph imports only Grammar, so no cycle — verify with the module's import list) and
`Data.List.NonEmpty (NonEmpty)`; extend the record:

    data CheckedService = CheckedService
      { checkedLanguageContract :: !EffectiveLanguageContract,
        checkedSpec :: !Spec,
        -- \| Shared, lazily forced resolution of 'checkedSpec'. Never serialized,
        -- never part of Eq/Show; every whole-spec consumer in one check pass or
        -- scaffold run reads this thunk instead of re-resolving.
        checkedTypeGraph :: Either (NonEmpty TypeGraphError) TypeGraph
      }

(the field is deliberately unbanged — StrictData is off, so it stays a thunk until first
demand). Drop the `deriving stock (Eq, Show)` and write instances over the two semantic
fields only, byte-compatible with the derived output:

    instance Eq CheckedService where
      a == b =
        checkedLanguageContract a == checkedLanguageContract b
          && checkedSpec a == checkedSpec b

    instance Show CheckedService where
      showsPrec d service =
        showParen (d >= 11) $
          showString "CheckedService {checkedLanguageContract = "
            . shows (checkedLanguageContract service)
            . showString ", checkedSpec = "
            . shows (checkedSpec service)
            . showString "}"

In `checkedService` set `checkedTypeGraph = resolveTypeGraph spec` (this is the single
construction seam; `checkedSource` and `legacyCheckedService` already delegate to it). Fix
every direct constructor use the compiler now flags: `checkedWorkspace` in
`keiro-dsl/src/Keiro/Dsl/Workspace.hs` (~line 766) — set the field from `wsMergedSpec`, or
better, route through a new exported
`checkedServiceForContract :: EffectiveLanguageContract -> Spec -> CheckedService` so the
thunk logic lives in one place — and the two direct constructions in
`keiro-dsl/src/Keiro/Dsl/ExplainBindings.hs` (~lines 141, 157), which should switch to
`legacyCheckedService`. Export the field accessor from SemanticContract's export list.
Acceptance: `cabal build keiro-dsl` clean; `cabal test keiro-dsl:tests` green;
`just conformance-corpus-policy` reports no drift. Nothing consumes the field yet.

Milestone 3 — one resolution per check pass. Scope: every Class A check-path site reads the
shared graph. In `keiro-dsl/src/Keiro/Dsl/Validate.hs`: `validateService` passes
`checkedTypeGraph service` into `validateCheckedSpec` (internal — not in the export list, so
its signature is free to change to accept the graph result); `validateCheckedSpec` threads it
into `validateMapped` (replacing the `resolveTypeGraph spec` at ~1047) and into
`validateNode` → `validateRouter` (replacing ~3569); keep the exact concatenation order in
`validateCheckedSpec` (line ~754) — `sortOn line` is stable, so reordering the concatenated
sub-lists would reorder equal-line diagnostics and break byte-identity. The exported
`validateSpec` continues to wrap via `legacyCheckedService` and inherits sharing. In
`keiro-dsl/src/Keiro/Dsl/RouterSelection.hs`: `checkRouterSelection` already receives the
graph and spec; hoist one symbols table to a single binding built from the graph it was
given — add to `keiro-dsl/src/Keiro/Dsl/AggregateType.hs` a constructor

    aggregateSymbolsFromGraph :: TypeGraph -> Spec -> AggregateSymbols

that fills `symbolMapped` from `tgDeclarations graph` instead of re-resolving (nominals and
vertices unchanged), and replace the per-field `aggregateSymbols spec` at ~line 323 with the
hoisted binding. In `keiro-dsl/src/Keiro/Dsl/ExplainBindings.hs`: both `...ForService`
functions replace `resolveTypeGraph spec` with `checkedTypeGraph service`. In
`keiro-dsl/src/Keiro/Dsl/Coverage.hs`: the check CLI calls coverage with a spec
(`app/Main.hs` ~line 527); either add a service-taking entry the CLI uses or leave it (it is
once per invocation) — decide, and record the decision in the Decision Log. Acceptance: full
suite green, corpus zero drift, and with the temporary trace patch a `check` of the
declarative-router fixture shows the count drop for the validation portion (final count of 1
arrives only after Milestone 4, because check also runs the scaffold planner).

Milestone 4 — one resolution per scaffold run. Scope: every Class A scaffold-path site reads
the shared graph. In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`: replace the resolutions at ~587
(`aTypeGraph`), ~743, ~3489, ~4068, ~4782 with `checkedTypeGraph service` (all five already
have the service in scope); switch `aggregateSymbols spec` in `resolveAggForService` (~595)
and any other service-having `aggregateSymbols` caller to `aggregateSymbolsFromGraph` fed
from the cached graph (when the cached result is `Left`, fall back to the same empty-map
behavior `aggregateSymbols` has today — `either (const Map.empty) tgDeclarations`). In
`keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs` (~72 and the symbols at ~92), in
`keiro-dsl/src/Keiro/Dsl/StructuralConformance.hs` (~49, ~57), in
`keiro-dsl/src/Keiro/Dsl/Harness.hs` (~208), in `keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs`
(~220), in `keiro-dsl/src/Keiro/Dsl/CoordinationImpact.hs` (~212), and in
`keiro-dsl/src/Keiro/Dsl/ProjectionMappedImpact.hs` (~121, ~141): same mechanical
replacement — each already takes `CheckedService`. In `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`:
`checkedSemanticImpactSnapshot` (~1189) reads the field; `constraintPlan` keeps its exported
Spec signature but the execute path calls a new internal graph-threaded variant; the
`consumerPlan spec` calls (~786, ~924, ~1326) route through a new
`consumerPlanForService`/graph-threaded variant in
`keiro-dsl/src/Keiro/Dsl/MappedConsumer.hs` (keep the exported `consumerPlan :: Spec -> ...`
as a wrapper); `queryContractIdentities` (~926) gains a service/graph-threaded sibling in
`keiro-dsl/src/Keiro/Dsl/ReadModelQueryContract.hs`. In `keiro-dsl/src/Keiro/Dsl/Goldens.hs`
(~151) and `keiro-dsl/src/Keiro/Dsl/Expression.hs` (~56): thread the graph from callers that
hold the service; where a caller genuinely has only a Spec (public wrappers), leave the
wrapper resolving once. In `keiro-dsl/src/Keiro/Dsl/Workspace.hs` (~1139-1140): hoist the two
`checkedWorkspace composed` calls into one `let` binding so the workspace planning path
shares one service value. Class B and Class C sites: leave per the Decision Log (convert
`codecComparisonModule` only if trivial via the service already in scope at
`app/Main.hs:563`). Acceptance: full suite green, corpus zero drift, and the temporary trace
patch shows exactly one `resolveTypeGraph:begin` line for a full `check` and exactly one for
a full `scaffold` of the declarative-router fixture.

Milestone 5 — equivalence and performance proof, then distillation. Scope: prove and record.
Run the complete keiro-dsl suite, the corpus policy gate, and a full regenerate-then-diff
cycle (all commands in Concrete Steps). Re-run the two new benchmark groups and record
after-timings beside the baselines in Surprises & Discoveries; the check-pass timings on the
router-heavy shapes must drop measurably (the R-multiplier is gone), and no shape may
regress. Remove any leftover instrumentation. Do the ADR distillation pass (see Outcomes &
Retrospective), append a Revision Note, and update this plan's row in masterplan 36's
Exec-Plan Registry to Complete.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` (shown here
as `.`; use the absolute path if your shell starts elsewhere).

Regenerate the call-site inventory (M1, and again before M3/M4 edits):

```bash
grep -rn "resolveTypeGraph" keiro-dsl/src keiro-dsl/app keiro-dsl/bench keiro-dsl/test/Main.hs
```

Compare the hits against the Class A/B/C inventory in Context and Orientation; add any new
site (plan 234 may have introduced some) to the correct class before editing, and note the
reconciliation in the Decision Log.

Build and test (after every milestone):

```bash
cabal build keiro-dsl
cabal test keiro-dsl:tests
```

The `:tests` suffix is mandatory — a bare `cabal test keiro-dsl` runs only `keiro-dsl-test`
and silently skips the ~37 conformance suites (this trap is documented in the Justfile).
Expect every suite to end with lines like:

```text
Test suite keiro-dsl-conformance-declarative-router: PASS
```

Conformance-corpus zero drift (after M2, M3, M4, M5):

```bash
just conformance-corpus-policy
```

which runs `scripts/check-conformance-corpus.sh` → `cabal run -v0 keiro-dsl-corpus-regen -- check`
and exits nonzero on any would-be byte change. For the stronger M5 proof, regenerate and
show the tree is untouched:

```bash
just corpus-regen
git status --short
```

Expected output of `git status --short`: nothing except this plan file (and the bench file
while M1 is in flight).

Temporary resolution counter (M1 baseline, M3/M4 acceptance; never commit this patch). Edit
`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`, add `import Debug.Trace (trace)` and change the first
line of `resolveTypeGraph`'s body to emit one stderr line per evaluation:

```haskell
resolveTypeGraph :: Spec -> Either (NonEmpty TypeGraphError) TypeGraph
resolveTypeGraph spec = trace "resolveTypeGraph:begin" $ do
  ...
```

Then count evaluations for one check and one scaffold of the shipped declarative-router
fixture (scaffold writes into a scratch directory; delete it afterwards):

```bash
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/declarative-router/valid.keiro 2>&1 \
  | grep -c "resolveTypeGraph:begin"
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/declarative-router/valid.keiro /tmp/keiro-236-scaffold 2>&1 \
  | grep -c "resolveTypeGraph:begin"
rm -rf /tmp/keiro-236-scaffold
```

(If the scaffold subcommand's argument shape differs, run `cabal run -v0 keiro-dsl -- --help`
and adapt; the count, not the command spelling, is the evidence.) Record the M1 numbers in
Surprises & Discoveries. Acceptance after M4: both counts print exactly `1`. Revert the trace
patch immediately after each measurement:

```bash
git checkout -- keiro-dsl/src/Keiro/Dsl/TypeGraph.hs
```

Benchmarks (M1 baseline, M5 comparison):

```bash
cabal bench keiro-dsl-parser-bench --benchmark-options="-p type-graph"
```

Expected output shape (numbers are illustrative; record your real ones in this plan):

```text
  type-graph
    service-check
      m16-r2:  OK — 4.1 ms ± ...
      m64-r16: OK — 210 ms ± ...
    service-scaffold-plan
      m16-r2:  OK — 12 ms ± ...
```

After M4/M5, re-run identically and record the drop; the router-heavy shapes (`r8`, `r16`)
must improve the most because the per-router re-resolution disappears.


## Validation and Acceptance

The change is accepted when all of the following hold, in this order of authority:

First, behavior equivalence. `cabal test keiro-dsl:tests` passes every suite, and
`just conformance-corpus-policy` reports zero drift, and `just corpus-regen` followed by
`git status --short` shows no modified corpus file. This proves generated modules, harness
facts, records, and codecs are byte-identical. Diagnostics equivalence is covered by the
validation suites in `keiro-dsl/test/Main.hs` (which assert exact diagnostic lists and
ordering); if any diagnostic-order test fails, the concatenation order in
`validateCheckedSpec` was disturbed — restore it rather than re-sorting.

Second, the resolution count. With the temporary trace patch applied, one
`keiro-dsl check` of `keiro-dsl/test/fixtures/declarative-router/valid.keiro` prints exactly
one `resolveTypeGraph:begin` line, and one `keiro-dsl scaffold` of the same fixture prints
exactly one. Before the refactor these counts are large (record the actual baselines in
Surprises & Discoveries at M1); a final count above 1 means some Class A site still resolves
independently — find it with the inventory grep and convert it.

Third, the latency demonstration. The `type-graph` benchmark groups added in M1 run green
before and after, each iteration constructing its `CheckedService` inside the measured
closure, and the after-timings for the check group on router-heavy shapes are measurably
lower than the recorded baselines, with no shape regressing. Both timing tables live in
Surprises & Discoveries as the permanent evidence.

Fourth, the frozen-identity guard. The fold-fingerprint and replay suites inside
`keiro-dsl:tests` pass unchanged, confirming ADR-18's frozen fold identity was not disturbed,
and no new serialization of the graph exists (nothing outside `Keiro.Dsl.SemanticContract`
mentions the new field except through the accessor; `grep -rn "checkedTypeGraph"
keiro-dsl/src` should show only the definition and accessor reads).


## Idempotence and Recovery

Every step is safe to repeat. Builds, tests, benchmarks, and the corpus `check` mode are
read-only with respect to the source tree; `just corpus-regen` is idempotent (regenerating an
unchanged generator yields unchanged bytes — that is the very property this plan relies on).
The trace patch is a two-line local edit reverted with `git checkout --
keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`; never commit it. The scaffold-count measurement writes
only to a scratch directory you delete afterwards.

Work commits milestone by milestone on the current branch (conventional commits, e.g.
`perf(dsl): cache the resolved type graph on CheckedService`), so any milestone can be
reverted independently: M2 is inert without M3/M4 (the field exists, nothing reads it), and
M3/M4 are mechanical substitutions whose revert restores per-site resolution without
touching behavior. If a corpus or suite failure appears mid-milestone, bisect the mechanical
edits: each site conversion is independent, so reverting one file at a time isolates the bad
substitution. Do not proceed to the next milestone with a red suite or a drifting corpus.


## Interfaces and Dependencies

No new external dependencies. `tasty-bench` (already a `keiro-dsl-parser-bench` dependency)
covers the new benchmark groups; `Debug.Trace` is temporary and never committed.

At the end of M2, `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` exports, in addition to its
current surface:

```haskell
checkedTypeGraph :: CheckedService -> Either (NonEmpty TypeGraphError) TypeGraph
-- (the record accessor; lazy field, excluded from Eq and Show)
checkedServiceForContract :: EffectiveLanguageContract -> Spec -> CheckedService
-- (only if Workspace.hs routes through it; otherwise Workspace sets the field directly)
```

with `CheckedService` carrying hand-written `Eq`/`Show` instances over
`checkedLanguageContract` and `checkedSpec` only. `Keiro.Dsl.SemanticContract` newly imports
`Keiro.Dsl.TypeGraph` (no cycle: TypeGraph depends only on `Keiro.Dsl.Grammar`).

At the end of M3, `keiro-dsl/src/Keiro/Dsl/AggregateType.hs` exports:

```haskell
aggregateSymbolsFromGraph :: TypeGraph -> Spec -> AggregateSymbols
```

while keeping `aggregateSymbols :: Spec -> AggregateSymbols` for Spec-only callers, and
Validate.hs internals (`validateCheckedSpec`, `validateMapped`, `validateRouter`) accept the
shared `Either (NonEmpty TypeGraphError) TypeGraph` — none of these are exported, so their
shapes are free; the exported `validateService`/`validateSpec` signatures are unchanged.

At the end of M4, `keiro-dsl/src/Keiro/Dsl/MappedConsumer.hs` and
`keiro-dsl/src/Keiro/Dsl/ReadModelQueryContract.hs` gain service- or graph-threaded siblings
of `consumerPlan` and `queryContractIdentities` (exact names at implementer's discretion,
recorded in the Decision Log), with existing exported Spec-only signatures preserved as
wrappers. Every `...ForService` function in Scaffold.hs, ScaffoldRun.hs, FoldFingerprint.hs,
Harness.hs, ServiceHarness.hs, StructuralConformance.hs, CoordinationImpact.hs, and
ProjectionMappedImpact.hs keeps its signature and merely reads `checkedTypeGraph` instead of
calling `resolveTypeGraph`.

`resolveTypeGraph` and the `TypeGraph` type in `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` are
unchanged throughout.

Sequencing dependencies: implement after plan 234 lands (soft dependency; see Decision Log
for the coordination rule if it has not), stay clear of plan 235's entry-point removals in
ScaffoldRun.hs by rebasing the inventory if both are in flight, and do not touch the
`DiagnosticCode` enumeration in Validate.hs.
