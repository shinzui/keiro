---
id: 250
slug: report-legacy-strong-consistency-weakening-across-the-language-4-to-5-migration-in-diff
title: "Report legacy strong-consistency weakening across the language 4 to 5 migration in diff"
kind: exec-plan
created_at: 2026-08-12T23:55:43Z
intention: "intention_01kzw6dkcserms9yr61sqdntep"
master_plan: "docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md"
---

# Report legacy strong-consistency weakening across the language 4 to 5 migration in diff

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl diff` is the merge gate that classifies the evolution of a `.keiro` service
specification between two revisions. It exists to catch exactly one family of mistake:
a change that silently breaks a guarantee that persisted data or running callers depend
on. Today it misses the most consequential such mistake in the language 4 to language 5
migration path: a read model declared `consistency = Strong` in language 4 (callers wait
on a durable subscription cursor before every query) can be migrated to language 5 as
`freshness = immediate` (callers never wait), and `keiro-dsl diff` reports **zero breaking
findings** and exits 0. Worse, when the old model also declared a category scope, the diff
prints a spurious **ADDITIVE "Strong scope widened"** verdict — it actively describes the
weakening as a strengthening.

After this plan, every consistency-to-freshness policy weakening across the language 4/5
migration is reported as a breaking `QueryFreshnessChanged` finding that blocks the gate
(non-zero exit), the spurious scope-widened verdict is gone, and the equivalent or
strengthening migrations stay non-breaking exactly as before. You can see it working by
running the reproduction in this plan: before the fix the migration diff exits 0 with no
read-model finding; after the fix the same diff prints a BREAKING `query-freshness` line
naming both spellings ("wait-for-head category 'reservation' -> immediate") and exits
non-zero. Byte-identical language 4 diffs, byte-identical language 5 diffs, the compiled
conformance corpus, and the frozen released-language behavior all remain bit-for-bit
unchanged.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: add the migration fixture `keiro-dsl/test/fixtures/readmodel-migration-l4.keiro`
      and the new cross-language diff regression tests in `keiro-dsl/test/Main.hs`; run the
      focused suite and capture the red failure transcript into this plan.
- [ ] M2: restructure `policyChanges` in `readModelPairDiff`
      (`keiro-dsl/src/Keiro/Dsl/Diff.hs`) into the three-case supply-shape split; focused
      suite green; commit tests and fix together.
- [ ] M3: prove no false positives and zero corpus drift — full
      `cabal test keiro-dsl:tests`, `just corpus-regen` with clean `git status`,
      `just conformance-corpus-policy`, `bash keiro-dsl/test/diff-test.sh`, and the CLI
      transcripts for all four migration flavors recorded in this plan.
- [ ] M4: update `docs/user/read-models-and-projections.md` (migration table),
      `docs/user/api-reference.md`, `keiro-dsl/CHANGELOG.md` Unreleased; confirm no ADR
      amendment is needed; run `just verify`; update MasterPlan 40 registry status and
      finish the living sections of this plan.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Planning verification (2026-08-12): the defect was reproduced against the working tree
  with the real `keiro-dsl` binary before this plan was written; the exact fixtures and
  transcript are embedded in Context and Orientation below. Two flavors were confirmed:
  Strong-with-category-scope to immediate produces zero breaking findings plus the
  spurious `ADDITIVE ... Strong scope widened category 'reservation' -> entire-log` line,
  and Eventual to immediate correctly produces no read-model finding at all.
- Planning verification (2026-08-12): every cross-language diff of an unchanged aggregate
  also emits an advisory `AggFoldSurfaceChanged` warning ("effective runtime semantics
  changed the aggregate fold surface even though the normalized graph is unchanged") plus
  a replay-impact line. That is pre-existing, deliberate contract-change reporting from
  the language 4 to 5 runtime-semantics bump, is advisory (exit 0), and is out of scope
  here. Tests in this plan must therefore assert on breaking-ness and on the
  `query-freshness` / `read-model-scope` facets, not on "the change list is empty".

(Add implementation discoveries below as work proceeds.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Reuse the existing `QueryFreshnessChanged` diagnostic code for migration
  weakenings (and the existing `CompatibilityStrengthened` code for migration
  strengthenings) instead of appending a new `DiagnosticCode` constructor.
  Rationale: ADR-4 makes machine-readable codes the tooling contract that correlates
  `check` and `diff`. `QueryFreshnessChanged` already means "the query freshness policy
  of this read model changed" and is already wired into the compatibility-vector
  classifier (`classifyCompatibility`, persisted-identity breaking), the change-context
  table (`contextFor` identity codes), and user documentation. A CI policy that already
  denies or gates on `QueryFreshnessChanged` starts catching the migration weakening with
  no new vocabulary. Appending a new code is reserved for new hazard classes; this is the
  same hazard reaching `diff` through a second supply shape.
  Date: 2026-08-12
- Decision: Classify mixed-supply (legacy-vs-owner-derived) read-model pairs by comparing
  the normalized `rmFreshness` of both sides, in either direction, using this matrix
  (old freshness → new freshness):
  wait-for-head → immediate is Breaking `QueryFreshnessChanged`;
  immediate → wait-for-head is Additive `CompatibilityStrengthened`;
  wait-for-head s → wait-for-head s (equal) and immediate → immediate are silent;
  wait-for-head category c → wait-for-head entire-log (widening, `scopeStrengthened`) is
  Additive `CompatibilityStrengthened`;
  any other wait-for-head scope change is Breaking `QueryFreshnessChanged`.
  Rationale: the parser already lowers legacy `Eventual` to `FreshnessImmediate` and
  legacy `Strong` plus optional scope to `FreshnessWaitForHead <scope or entire-log>`
  (`keiro-dsl/src/Keiro/Dsl/Parser/ReadModel.hs`, `pLegacyPolicy`), and plan 245's
  published migration table defines exactly this correspondence, so equal normalized
  freshness means the migration preserved the caller-visible wait contract. Widening
  mirrors the frozen legacy additive treatment of `Strong scope` widening; narrowing and
  weakening lose a wait surface callers relied on.
  Date: 2026-08-12
- Decision: In the mixed-supply case a strengthening (immediate → wait-for-head) is
  Additive even though the language-5-to-language-5 branch reports every freshness change
  as Breaking.
  Rationale: for two owner-derived (catalog-bound) revisions, freshness is part of the
  persisted canonical catalog/slice identity (plan 244 M3, ADR-32), so any change alters
  persisted identity regardless of direction. A legacy-supply side has no catalog
  identity — a groupless model has no catalog binding at all — so only the caller-visible
  direction semantics apply, mirroring the frozen legacy `Eventual -> Strong` additive
  verdict. This asymmetry is deliberate and documented in the code comment and the docs.
  Date: 2026-08-12
- Decision: The spurious "Strong scope widened" additive verdict is eliminated (not
  justified) by making `legacyFeedChanges`, `legacyConsistencyChanges`, and
  `legacyScopeChanges` reachable only when **both** sides carry `LegacyReadModelSupply`.
  Rationale: those comparisons read `legacyReadModelScope`, which is `Nothing` for an
  owner-derived side; `effectiveScope Nothing = RmEntireLog` then fabricates an
  entire-log claim for a model that may not wait at all. There is no input on which the
  current mixed-shape scope verdict is truthful.
  Date: 2026-08-12
- Decision: `PositionWait` needs no read-model diff classification in this plan.
  Rationale: `PositionWait` never appears in a read-model declaration's supply.
  It exists only (a) as the deprecated runtime constructor in
  `keiro/src/Keiro/ReadModel.hs`, where plan 244 froze its semantics ("legacy
  `PositionWait Nothing` remains immediate through 0.12"; the truthful per-call form is
  `WaitForPosition` with a concrete target, and plan 245 deliberately gave language 5 no
  static wait-for-position spelling), and (b) as a free-form string on the descriptive
  `operation query` surface (`QueryOp` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, validated
  as one of Strong/Eventual/PositionWait in `keiro-dsl/src/Keiro/Dsl/Validate.hs`
  `validateOperation`), which has no diff classification and is unchanged by the
  language migration. There is no spec-level PositionWait-to-wait-for-head pair for
  `readModelPairDiff` to classify.
  Date: 2026-08-12
- Decision: No ADR is amended by this plan.
  Rationale: ADR-4's layer-2 contract ("`keiro-dsl diff` classifies hazards that require
  old and new declarations", with machine-readable codes correlating check/diff) is
  unchanged — this plan repairs a missed classification inside that boundary without
  moving any gate's ownership. The completion-time ADR distillation pass must re-confirm
  this; amend `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`
  only if implementation ends up changing which boundary owns the hazard.
  Date: 2026-08-12
- Decision: Classification is direction-agnostic: a language 5 to language 4 downgrade
  diff (owner-derived old side, legacy new side) is classified by the same normalized
  freshness comparison.
  Rationale: `diff` accepts any two parsed revisions and must be total; the caller-visible
  wait contract is symmetric in what it compares even though real migrations run 4 → 5.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/keiro`, a
multi-package Haskell cabal project. The package under change is `keiro-dsl`, the typed
specification language and toolchain for keiro services. Its CLI (`cabal run keiro-dsl`)
has two commands relevant here: `check` validates a single `.keiro` file, and
`diff --since <rev> <file>` compares the committed revision of a spec against the working
tree and classifies every change as ADDITIVE, WARNING (advisory), or BREAKING; any
breaking finding on a gated surface makes the process exit non-zero, which is how CI
blocks unsafe merges.

### The two read-model policy vocabularies

A "read model" is a registered SQL query surface declared with a `readmodel` block. In
the published languages 1–4 its query policy is spelled with four clauses:
`consistency = Strong | Eventual` (Strong means every query first waits until the model's
subscription worker has caught up to the event-log head — the "cursor-wait guarantee";
Eventual means queries read whatever is there), an optional `scope = entire-log |
category "name"` (which log head a Strong wait targets), `feed = inline | subscription`
(whether a command transaction or an async worker applies events), and an optional
explicit `subscription = "name"`.

Candidate language 5 (plans 244/245, MasterPlan 38) split that into two axes: projection
owners declare `delivery = inline | subscription`, and read models declare only
`freshness = immediate | wait-for-head entire-log | wait-for-head category "name"`. The
language 5 parser rejects the legacy spellings with a migration diagnostic. The published
correspondence (the migration table in `docs/user/read-models-and-projections.md`,
written by plan 245 M4) is: `Eventual` ≙ `immediate`, and `Strong` plus scope ≙
`wait-for-head <scope>` (Strong with no scope defaults to entire-log).

In the semantic graph (`keiro-dsl/src/Keiro/Dsl/Grammar.hs`) both vocabularies normalize
into the same two fields of `ReadModelNode`:

- `rmFreshness :: QueryFreshnessNode` — `FreshnessImmediate` or
  `FreshnessWaitForHead RmScope`. **Both** parsers populate this faithfully: the legacy
  parser (`keiro-dsl/src/Keiro/Dsl/Parser/ReadModel.hs`, `pLegacyPolicy`, near lines
  93–95) lowers `Eventual` to `FreshnessImmediate` and `Strong` to
  `FreshnessWaitForHead (scope or RmEntireLog)`; the language 5 parser
  (`pSeparatedPolicy`) reads the `freshness` clause directly.
- `rmSupply :: ReadModelSupply` — `LegacyReadModelSupply {legacyConsistency, legacyScope,
  legacyFeed, legacySubscription}` for languages 1–4 (source provenance retained so
  released rendering stays byte-identical, per plan 245 and ADR-16), or
  `OwnerDerivedSupply` for language 5. The accessors `legacyReadModelConsistency`,
  `legacyReadModelScope`, `legacyReadModelFeed`, `legacyReadModelSubscription`
  (Grammar.hs near lines 1245–1263) all return `Nothing`/nothing for
  `OwnerDerivedSupply`.

Because `rmSupply` is determined entirely by the parsing language, a "mixed" pair — one
side `LegacyReadModelSupply`, the other `OwnerDerivedSupply` — occurs exactly when a diff
crosses the language 4/5 migration (in either direction).

### The defect mechanism

`readModelPairDiff` in `keiro-dsl/src/Keiro/Dsl/Diff.hs` (near line 1194) classifies one
matched old/new read-model pair. Its `policyChanges` component (near line 1233) reads:

```haskell
    policyChanges
      | rmSupply oldReadModel == OwnerDerivedSupply && rmSupply newReadModel == OwnerDerivedSupply =
          [ breaking nodeName "query-freshness" nodeName QueryFreshnessChanged (...)
          | rmFreshness oldReadModel /= rmFreshness newReadModel
          ]
      | otherwise = legacyFeedChanges <> legacyConsistencyChanges <> legacyScopeChanges
```

For a mixed pair the `otherwise` branch runs, and each of its three comparisons is inert
or wrong:

- `legacyFeedChanges` (near line 1239) requires `Just` feeds on **both** sides;
  `legacyReadModelFeed` of the owner-derived side is `Nothing`, so nothing fires.
- `legacyConsistencyChanges` (near line 1245) pattern-matches
  `(Just Strong, Just Eventual)` and `(Just Eventual, Just Strong)`; the migration pair
  is `(Just Strong, Nothing)`, which hits the `_ -> []` catch-all. The breaking
  `ReadModelConsistencyWeakened` ("callers lose the cursor-wait guarantee") that guards
  the same weakening inside language 4 never fires.
- `legacyScopeChanges` (near lines 1251–1258) runs `effectiveScope` over both sides;
  `effectiveScope Nothing = RmEntireLog` (near line 1430), so an owner-derived new side is
  treated as an entire-log Strong scope. When the old side declared
  `scope = category "x"`, `scopeStrengthened (RmCategory _) RmEntireLog = True` (near
  line 1434) emits the **spurious additive** "Strong scope widened category 'x' ->
  entire-log" — for a new side that may not wait at all.

Every other component of `readModelPairDiff` legitimately compares equal for the
minimal migration: version/shape/columns unchanged; the derived registry and
subscription identities (`registryNameFor`/`subscriptionNameFor` in
`keiro-dsl/src/Keiro/Dsl/ReadModelShape.hs` — the subscription default is
`<context>-<model>-sub`, so an explicit legacy `subscription` equal to that default
migrates silently); and `bindingChanges` compares `(rmGroup, observed targets, resolved
supplier, backing)` where both sides are groupless — `analyzeProjectionSupplies`
(`keiro-dsl/src/Keiro/Dsl/ProjectionSupply.hs`, near line 62) only analyzes read models
with `rmGroup /= Nothing`, so both suppliers resolve to `Nothing`.

Meanwhile both endpoints of the migration are fully `check`-valid, so no earlier
boundary catches it either. On the language 4 side, `consistency = Strong` requires
`feed = subscription` (`RmStrongInlineOnly`, `keiro-dsl/src/Keiro/Dsl/Validate.hs` near
line 2607), which is the classic aggregate-projection-plus-subscription-worker pattern.
On the language 5 side, a groupless read model is valid when one legacy inner aggregate
`projection` clause references it (`CatalogReadModelBindingMissing` check, Validate.hs
near lines 2778–2788), and `FreshnessImmediate` is unconditionally valid
(`freshnessCapability`, near line 2645). The trap is sharpened by the validator itself:
a groupless language 5 model that tries the honest `freshness = wait-for-head ...` with
only an implicit aggregate-projection owner is **rejected** with
`CatalogQueryWaitWithoutCompatibleCursor` whose remedy text says "move the projection
into a subscription projection-owner **or use freshness = immediate**" (near lines
2648–2657) — so the path of least resistance during migration is exactly the silent
weakening.

### Verified reproduction (working tree, 2026-08-12)

The following language 4 spec checks OK. (The aggregate is the standard test-fixture
Reservation aggregate; the `projection` clause plus `feed = subscription` is the
released async-projection pattern.)

```text
language keiro-dsl 4
context hospital-capacity

id  TransferReservationId  prefix=rsv
id  HospitalId             prefix=hosp
id  CommandId              prefix=cmd

enum PatientAcuity { RedTag=red YellowTag=yellow GreenTag=green }
enum DivertStatus  { Open=open PartialDivert=partial-divert TotalDivert=total-divert }

aggregate Reservation
  regs
    reservationId    TransferReservationId = placeholder
    hospitalId       HospitalId            = placeholder
    patientAcuity    PatientAcuity         = GreenTag
  states Unrequested Held Confirmed

  command RequestTransferReservation { reservationId hospitalId commandId patientAcuity divertStatus }
  command ConfirmReservation         { reservationId hospitalId commandId }

  event TransferReservationCreated   = fields(RequestTransferReservation)
  event TransferReservationConfirmed { reservationId hospitalId commandId }

  Unrequested -- RequestTransferReservation -->
    guard cmd.divertStatus != DivertStatus.TotalDivert
    emit  TransferReservationCreated
    goto  Held
  Held -- ConfirmReservation --> emit TransferReservationConfirmed ; goto Confirmed

  wire kind=ctorName fields=camelCase schemaVersion=1
  projection transfer_decisions key=reservationId
    status-map { TransferReservationCreated=>held TransferReservationConfirmed=>done }

readmodel transfer_decisions {
  table = "transfer_decisions"
  schema = "hospital_capacity"
  columns {
    reservation_id text required
    hospital_id text required
    status text required
    decided_at timestamptz
  }
  version = 1
  shape = "fnv1a:3717f6d9e3c44bd6"
  consistency = Strong
  scope = category "reservation"
  feed = subscription
  subscription = "hospital-capacity-transfer-decisions-sub"
}
```

The language 5 migration replaces `language keiro-dsl 4` with `language keiro-dsl 5` and
the four policy lines (`consistency`/`scope`/`feed`/`subscription`) with
`freshness = immediate`. It also checks OK. Committing the old spec to a scratch git
repository and diffing the migrated working tree produced, at the current HEAD:

```text
ADDITIVE: hospital-capacity source-language declaration: source form changed declared v4 -> declared v5; effective runtime semantics changed keiro-dsl/runtime-semantics/3 -> keiro-dsl/runtime-semantics/4; see the accompanying semantic-contract findings
ADDITIVE: transfer_decisions read-model-scope transfer_decisions: Strong scope widened category 'reservation' -> entire-log
WARNING: Reservation semantic-contract Reservation: effective runtime semantics changed the aggregate fold surface even though the normalized graph is unchanged; re-scaffold, redeploy, and audit replay under the candidate contract [AggFoldSurfaceChanged]
    vector: private-history-read=advisory old-binary-read-new-events=compatible snapshot-hydration=advisory
replay-affected: run the candidate binary's targeted replay audit for Reservation events=[TransferReservationConfirmed,TransferReservationCreated] snapshots=yes
exit=0
```

Zero breaking findings, exit 0, and the misleading scope-widened additive. The same
experiment with an `Eventual` baseline (drop the `scope` line, `consistency = Eventual`)
produced no read-model finding at all — correctly, since that migration is equivalent.

### Where the diagnostic machinery lives

`DiagnosticCode` is one shared enum in `keiro-dsl/src/Keiro/Dsl/Validate.hs` (near line
260 for `ProjectionDeliveryChanged`/`QueryFreshnessChanged`, near line 267 for the legacy
`ReadModelConsistencyWeakened`); codes are append-only and correlate `check` and `diff`
per ADR-4. `QueryFreshnessChanged` is already fully wired on the diff side: in
`classifyCompatibility` (Diff.hs near line 339 and in `catalogIdentityCodes` near line
421) it carries the persisted-identity breaking compatibility vector — persisted-identity
is in the default gate, so a breaking finding with this code makes `diff` exit non-zero —
and in `contextFor` (Diff.hs near line 2914) it maps to the persisted-identity change
context. `CompatibilityStrengthened` is in `additiveCodes` (compatible vector). Reusing
both codes means no change to `classifyCompatibility`, `contextFor`, `diagnosticOrigin`,
or `remediationFor` is needed.

### Where the tests live

`keiro-dsl/test/Main.hs` is the main hspec suite (cabal component `keiro-dsl-test`). The
diff classification tests live under `describe "diff (evolution classification)"` (near
line 6970). The legacy read-model policy tests are near lines 7675–7688 ("classifies
read-model feed flips and consistency/scope weakening as breaking", "classifies Eventual
to Strong read-model consistency as additive") and manipulate a parsed language 4 spec
(`specOf "test/fixtures/readmodel-runtime.keiro"`) with AST helpers
(`modifyReadModel`, `setLegacyConsistency`, ...) then call `diffSpecs`. **Important**:
`diffSpecs` (near line 128) wraps both specs in `stableCheckedService`, which pins the
stable language (4) — it cannot express a cross-language diff. Cross-language tests must
parse two sources with their own `language keiro-dsl N` preambles via
`checkedServiceFromText` (near line 12344) and call `diffServices` directly. The language
5 freshness diff test ("isolates freshness evolution from delivery, table shape, sources,
and aggregate folds", near line 2188, under `describe "language-5 projection catalogs"`)
shows the established fixture-text-plus-`T.replace` mutation style this plan follows.

Two repository gates constrain new fixtures and generated output. First, the
conformance-baseline check (`keiro-dsl/test/Keiro/Dsl/ConformanceBaseline.hs`) scans
every `.keiro` under `keiro-dsl/test/fixtures/` and requires each to be a declared
language 4 or 5 source unless listed in `keiro-dsl/test/conformance-baseline.json` — the
new fixture in this plan declares language 4, so no baseline edit is needed. Second, the
compiled conformance corpus is regenerated by `just corpus-regen` and its zero-drift
policy is enforced by `just conformance-corpus-policy`
(`scripts/check-conformance-corpus.sh`); this plan changes only diff classification, not
generation, so the corpus must not move. The released-frontend oracle
(`keiro-dsl/test/Keiro/Dsl/FrontendCompatibility.hs` over
`keiro-dsl/test/frontend-0.7/`) and the languages 1–4 byte-compatibility bar from plan
245 M4 are exercised by the full `keiro-dsl-test` run and `just verify`.

### Relevant ADRs and prior plans

- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR-4):
  each evolution hazard is checked at the earliest boundary with enough evidence;
  `keiro-dsl diff` is layer 2 (hazards requiring old and new declarations); machine-
  readable `DiagnosticCode` values are append-only and correlate check/diff; findings
  carry a six-surface compatibility vector and the default gate includes
  persisted-identity. This plan repairs a missed layer-2 classification without changing
  the boundary contract, so ADR-4 is not amended (see Decision Log).
- `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
  (ADR-16): released languages 1–4 behavior is immutable; candidate language 5 is
  amendable. The legacy-to-legacy diff wording and severity are frozen by this rule —
  the fix must leave that branch byte-identical.
- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
  (ADR-26) and
  `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
  (ADR-32): language 5 owner/query separation and the canonical catalog identity that
  includes normalized freshness — the reason any freshness change between two
  owner-derived revisions is breaking regardless of direction.
- Prior plans (checked in): `docs/plans/244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md`
  (the runtime freshness vocabulary and the semantic mapping of legacy consistency, incl.
  the PositionWait ruling) and
  `docs/plans/245-separate-language-5-projection-delivery-from-query-freshness.md`
  (the delivery/freshness split, the `ReadModelSupply` legacy/owner-derived design, the
  M4 migration documentation, and the languages 1–4 byte-compatibility proof).
- Parent MasterPlan:
  `docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md`
  (this plan is EP-1; it gates the 0.12.0.0 release).

No cross-repository ADR bears on this work.

### Integration constraint with plan 253

`docs/plans/253-apply-the-deferred-consolidation-cleanups-from-the-fix-verification-review.md`
(EP-4 of the same MasterPlan) later threads a single precomputed projection-supply
analysis through `Diff.hs` and `Validate.hs` call sites, replacing the per-node
`analyzeProjectionSupplies` recomputation. This plan lands first and must keep its edits
local to the `policyChanges` classification logic inside `readModelPairDiff` — do not
refactor how `resolvedSupplier`/`analyzeProjectionSupplies` are computed or passed, and
do not restructure `readModelPairDiff`'s other components, so EP-4 can rebase
mechanically.

### The full migration semantics matrix (the contract this plan implements)

"Old" and "new" below are the normalized `rmFreshness` values of a mixed-supply pair
(one side legacy, one side owner-derived, either direction). Legacy spellings normalize
as: `Eventual` = immediate; `Strong` = wait-for-head with its declared scope, defaulting
to entire-log.

| Old normalized freshness | New normalized freshness | Verdict | Code |
|---|---|---|---|
| wait-for-head (any scope) | immediate | Breaking | `QueryFreshnessChanged` |
| immediate | wait-for-head (any scope) | Additive | `CompatibilityStrengthened` |
| immediate | immediate | none | — |
| wait-for-head s | wait-for-head s (same scope) | none | — |
| wait-for-head category c | wait-for-head entire-log | Additive (widened) | `CompatibilityStrengthened` |
| wait-for-head entire-log | wait-for-head category c | Breaking (narrowed) | `QueryFreshnessChanged` |
| wait-for-head category c | wait-for-head category c' (c ≠ c') | Breaking | `QueryFreshnessChanged` |

Both-legacy pairs keep the frozen released classification (`ReadModelFeedChanged`,
`ReadModelConsistencyWeakened`, `CompatibilityStrengthened` on the `read-model-*`
facets) byte-for-byte. Both-owner-derived pairs keep the current rule (any freshness
inequality is Breaking `QueryFreshnessChanged`, catalog-identity wording). `PositionWait`
has no spec-level representation to classify (see Decision Log). Related findings that
correctly remain owned elsewhere: adopting a catalog binding during migration (group,
targets, supplier) is `CatalogQueryBindingChanged`; registry/table/subscription identity
changes are `DerivedIdentityChanged`; the language declaration change itself is the
additive `SourceLanguageDeclarationChanged`.


## Plan of Work

### Milestone 1 — Red reproduction: fixture and failing regression tests

Scope: commit-ready test code that encodes the corrected classification and demonstrably
fails at the current HEAD for exactly the defect's reason. At the end of this milestone
the new fixture file and test cases exist, the focused suite run is red with the expected
failures, and the red transcript is recorded in this plan. Do not push a red gate: the
test edits are committed together with the Milestone 2 fix (one commit or a
test-then-fix pair created back to back locally).

Create `keiro-dsl/test/fixtures/readmodel-migration-l4.keiro` with byte-for-byte the
language 4 reproduction spec shown in Context and Orientation (from `language keiro-dsl 4`
through the closing `}` of the readmodel). Both this fixture and every in-test mutation
of it were verified `check`-clean during planning. Because the file declares language 4,
the conformance-baseline fixture scan accepts it without touching
`keiro-dsl/test/conformance-baseline.json`.

In `keiro-dsl/test/Main.hs`, inside `describe "diff (evolution classification)"`,
immediately after the existing `it "classifies Eventual to Strong read-model consistency
as additive"` block (near line 7688), add three test cases. All descriptions contain the
phrase "freshness migration" so one hspec `--match` selects exactly this group. Use the
established text-mutation style: read the fixture once with `readTestText`, derive each
variant with `T.replace`, parse each side with `checkedServiceFromText` (which respects
the `language keiro-dsl N` preamble), and diff with `diffServices` — not `diffSpecs`,
which pins both sides to the stable language and cannot express a cross-language pair.

Define these local helpers in the test bodies (exact replacement strings matter — they
must match the fixture bytes):

```haskell
let legacyStrongPolicy =
      "  consistency = Strong\n  scope = category \"reservation\"\n  feed = subscription\n  subscription = \"hospital-capacity-transfer-decisions-sub\"\n"
    legacyEventualPolicy =
      "  consistency = Eventual\n  feed = subscription\n  subscription = \"hospital-capacity-transfer-decisions-sub\"\n"
    toLanguage5 policy =
      T.replace "language keiro-dsl 4" "language keiro-dsl 5"
        . T.replace legacyStrongPolicy policy
```

Test 1 — `it "classifies the legacy Strong to language-5 immediate freshness migration as
breaking"`: diff the unmodified fixture (old) against
`toLanguage5 "  freshness = immediate\n"` (new). Assert, on the change list:

```haskell
[ckCode k | Breaking k <- changes] `shouldContain` [QueryFreshnessChanged]
[ckFacet k | Breaking k <- changes] `shouldContain` ["query-freshness"]
[ckFacet k | Additive k <- changes] `shouldNotContain` ["read-model-scope"]
```

At HEAD this fails on all three assertions (empty breaking list for the pair; the
spurious `read-model-scope` additive present) — that is the red proof. Additionally
assert the finding's detail text names both spellings, pinning the message the docs will
cite (adjust to the exact string chosen in M2):

```haskell
[ckDetail k | Breaking k <- changes, ckCode k == QueryFreshnessChanged]
  `shouldSatisfy` any (T.isInfixOf "wait-for-head category 'reservation' -> immediate")
```

Test 2 — `it "keeps equivalent and strengthened freshness migrations non-breaking"`:
three sub-cases in one test body. (a) Equivalent Strong: old fixture vs
`toLanguage5 "  freshness = wait-for-head category \"reservation\"\n"` — assert
`any isBreaking changes == False` and no `"query-freshness"` or `"read-model-scope"`
facet appears at any severity. (This language 5 variant is deliberately only parsed, not
validated: a groupless wait with an implicit owner fails `check`, but `diff` must still
classify any parseable pair, and the equal-normalized-freshness cell is exercised here.)
(b) Equivalent Eventual: `T.replace legacyStrongPolicy legacyEventualPolicy` applied to
the fixture as old, vs `toLanguage5 "  freshness = immediate\n"` as new — same
assertions. (c) Strengthened: the Eventual old side vs
`toLanguage5 "  freshness = wait-for-head entire-log\n"` — assert no breaking, and
`[ckCode k | Additive k <- changes] shouldContain [CompatibilityStrengthened]` with
facet `"query-freshness"`.

Test 3 — `it "classifies scope changes and reverse downgrades in the freshness migration
by the normalized pair"`: (a) widening — old fixture (Strong category) vs
`toLanguage5 "  freshness = wait-for-head entire-log\n"`: additive
`CompatibilityStrengthened` on facet `"query-freshness"`, no breaking. (b) category
change — old fixture vs
`toLanguage5 "  freshness = wait-for-head category \"other\"\n"`: breaking
`QueryFreshnessChanged`. (c) reverse downgrade — swap the argument order of case (a) of
test 2's immediate pair: language 5 immediate as old, legacy Strong as new must be
additive `CompatibilityStrengthened`; and language 5
`wait-for-head category "reservation"` as old vs legacy Eventual as new must be breaking
`QueryFreshnessChanged`.

Also extend the guard tests around the frozen branches: add one assertion to the existing
legacy tests' neighborhood (or as a fourth `it`) that a byte-identical language 4 pair
and a byte-identical language 5 pair produce no `"query-freshness"` or `read-model-*`
facet findings at all (diff a parsed source against itself with `diffServices`).

Commands and acceptance: from the repository root, run the focused group and record the
failure transcript in this plan's Surprises & Discoveries:

```bash
cabal test keiro-dsl-test --test-option=--match --test-option="freshness migration"
```

Expected at HEAD: test 1 fails (missing breaking `QueryFreshnessChanged`; spurious
`read-model-scope` additive present); test 3 fails on cases (b) and (c) similarly; test
2's sub-case (a) may also fail if the current code emits any legacy facet for the pair.
Every failure message must be about the migration pair classification — any other failure
means the fixture or helpers drifted from this plan and must be fixed before proceeding.

### Milestone 2 — Fix: three-case supply-shape split in `policyChanges`

Scope: the classification fix itself, local to `readModelPairDiff` in
`keiro-dsl/src/Keiro/Dsl/Diff.hs`. At the end of this milestone the Milestone 1 tests
pass, the previously green read-model diff tests still pass, and the test-plus-fix work
is committed.

Replace the two-branch `policyChanges` guard (near line 1233) with an explicit case
split over both supply shapes, and add the mixed-shape classifier beside the existing
`legacy*Changes` definitions:

```haskell
    policyChanges = case (rmSupply oldReadModel, rmSupply newReadModel) of
      (OwnerDerivedSupply, OwnerDerivedSupply) ->
        [ breaking nodeName "query-freshness" nodeName QueryFreshnessChanged ("query freshness changed " <> renderFreshness (rmFreshness oldReadModel) <> " -> " <> renderFreshness (rmFreshness newReadModel) <> "; catalog and owning-group query policy identity changed")
        | rmFreshness oldReadModel /= rmFreshness newReadModel
        ]
      (LegacyReadModelSupply {}, LegacyReadModelSupply {}) ->
        legacyFeedChanges <> legacyConsistencyChanges <> legacyScopeChanges
      _ -> migrationFreshnessChanges
    migrationFreshnessChanges = case (rmFreshness oldReadModel, rmFreshness newReadModel) of
      (oldFreshness, newFreshness)
        | oldFreshness == newFreshness -> []
      (FreshnessWaitForHead _, FreshnessImmediate) ->
        [ breaking nodeName "query-freshness" nodeName QueryFreshnessChanged ("query freshness weakened " <> renderFreshness (rmFreshness oldReadModel) <> " -> immediate across the legacy consistency migration; callers lose the cursor-wait guarantee")
        ]
      (FreshnessImmediate, FreshnessWaitForHead _) ->
        [ additive nodeName "query-freshness" nodeName CompatibilityStrengthened ("query freshness strengthened immediate -> " <> renderFreshness (rmFreshness newReadModel) <> " across the legacy consistency migration; callers gain a cursor-wait guarantee")
        ]
      (FreshnessWaitForHead oldWaitScope, FreshnessWaitForHead newWaitScope)
        | scopeStrengthened oldWaitScope newWaitScope ->
            [ additive nodeName "query-freshness" nodeName CompatibilityStrengthened ("query freshness head scope widened " <> renderScope oldWaitScope <> " -> " <> renderScope newWaitScope <> " across the legacy consistency migration")
            ]
        | otherwise ->
            [ breaking nodeName "query-freshness" nodeName QueryFreshnessChanged ("query freshness head scope changed " <> renderScope oldWaitScope <> " -> " <> renderScope newWaitScope <> " across the legacy consistency migration; callers no longer wait on the same event surface")
            ]
      (FreshnessImmediate, FreshnessImmediate) -> []
```

Notes for the implementer:

- The first (owner-derived) arm's list comprehension and message must remain
  byte-identical to the current code — copy, do not retype. The legacy arm must keep
  calling the three existing `legacy*Changes` definitions unchanged, preserving the
  frozen languages 1–4 output (ADR-16). Only the *reachability* of those definitions
  changes: they now run solely for both-legacy pairs, which is what removes the spurious
  scope-widened verdict.
- The final `(FreshnessImmediate, FreshnessImmediate)` arm is unreachable (the equality
  guard catches it) but keeps the match total for GHC's exhaustiveness checker without a
  wildcard that could silently swallow future constructors.
- All helpers used (`breaking`, `additive`, `renderFreshness`, `renderScope`,
  `scopeStrengthened`) already exist in Diff.hs with the right signatures
  (`breaking :: Name -> Text -> Text -> DiagnosticCode -> Text -> Change`, near line
  2841). No import, export, `DiagnosticCode`, `classifyCompatibility`, `contextFor`,
  `diagnosticOrigin`, or `remediationFor` change is needed. If you find yourself editing
  any of those, stop and re-read the Decision Log — the design reuses existing codes
  precisely to avoid touching them.
- The exact message strings may be refined for clarity, but the pinned substring in
  Milestone 1's test 1 and the docs written in Milestone 4 must be updated to match; the
  DiagnosticCode, facet (`"query-freshness"`), and severity are the contract.
- Add a short comment above `policyChanges` explaining the three shapes and pointing at
  the matrix in this plan by path, and noting the deliberate additive-strengthening
  asymmetry against the owner-derived branch.

Commands and acceptance:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test --test-option=--match --test-option="freshness migration"
cabal test keiro-dsl-test --test-option=--match --test-option="read-model"
```

All matched examples pass. Commit the fixture, tests, and fix now (see the commit
convention at the end of this plan), e.g. `fix(dsl): report legacy strong-consistency
weakening across the language migration in diff`.

### Milestone 3 — Prove no false positives, zero drift, and the end-to-end gate

Scope: demonstrate that the fix changes exactly the intended classifications and nothing
else, at every proof layer this repository has. At the end of this milestone the full
keiro-dsl suite, corpus policy, and CLI-level gate behavior are all recorded green.

Run, from the repository root:

```bash
cabal build all
cabal test keiro-dsl:tests
just corpus-regen
git status --short
just conformance-corpus-policy
bash keiro-dsl/test/diff-test.sh
```

Acceptance: `cabal test keiro-dsl:tests` (every test suite of the keiro-dsl package,
including `keiro-dsl-test` with the frontend-0.7 compatibility oracle and the
conformance-baseline scan, plus all compiled conformance suites) passes.
`just corpus-regen` followed by `git status --short` shows **no modified files** — the
fix touches classification only, so regeneration must be a no-op; any drift is a defect
in the change. `just conformance-corpus-policy` exits 0. `diff-test.sh` ends with its
`PASS:` line.

Then reproduce the CLI transcripts with the built binary (`EXE="$(cabal list-bin
keiro-dsl)"`), using a scratch git repository exactly as in Context and Orientation:
commit the language 4 fixture as `svc.keiro`, overwrite with each migrated variant, and
run `"$EXE" diff --since HEAD svc.keiro`; record all four transcripts in this plan:

1. Strong → immediate: output contains a `BREAKING: transfer_decisions query-freshness
   transfer_decisions: query freshness weakened wait-for-head category 'reservation' ->
   immediate ...; callers lose the cursor-wait guarantee` line with
   `[QueryFreshnessChanged]` in its explanation/code rendering, does **not** contain
   `Strong scope widened`, and the exit status is non-zero (the merge gate blocks).
2. Eventual → immediate: no `query-freshness` and no `read-model-*` finding; exit 0.
3. Strong → wait-for-head entire-log (widened): an `ADDITIVE ... query-freshness ...`
   line and exit 0.
4. Byte-identical language 4 → language 4 (recommit the same file): no findings at all;
   exit 0.

The additive `SourceLanguageDeclarationChanged` line and the advisory
`AggFoldSurfaceChanged` warning remain present in transcripts 1–3; both are pre-existing
cross-language reporting and are expected (see Surprises & Discoveries).

### Milestone 4 — Documentation, changelog, and closeout

Scope: make the documented migration recipe state the diagnostic, record the change for
release, and close the plan's living sections. At the end of this milestone `just
verify` passes and MasterPlan 40 reflects EP-1 complete.

Edit `docs/user/read-models-and-projections.md`: in the "Migrate candidate sources
mechanically" section (the table near lines 201–212), add a sentence directly after the
table stating the gate behavior, in this spirit (adjust wording to the final message
strings): "`keiro-dsl diff` enforces this table: migrating a `consistency = Strong` model
to `freshness = immediate` is reported as a breaking `QueryFreshnessChanged` finding
(callers lose the cursor-wait guarantee), the scope-preserving `wait-for-head <scope>`
rewrite is reported as no policy change, and `Eventual` to `immediate` is silent.
Strengthenings and head-scope widenings across the migration are additive
`CompatibilityStrengthened` findings."

Edit `docs/user/api-reference.md`: extend the sentence near line 893
("`ProjectionDeliveryChanged` and `QueryFreshnessChanged` report the two evolution axes
independently.") with: "`QueryFreshnessChanged` also fires across the language 4-to-5
migration whenever the normalized freshness weakens or its head scope narrows; legacy
`consistency`/`scope` pairs and language 5 `freshness` values are compared on one
normalized axis."

Optionally add the same one-line note to the freshness discussion in
`docs/user/typed-spec-toolchain.md` (near lines 1589–1600) if reviewing it shows readers
would otherwise miss the gate; do not restate the whole matrix there.

Edit `keiro-dsl/CHANGELOG.md`: under `## Unreleased`, add a `### Fixed` section (create
it if absent — the section currently starts with `### Added`) with an entry such as:

```text
- `keiro-dsl diff` now classifies read-model query-policy changes across the
  language 4-to-5 migration. Weakening legacy `consistency = Strong` to
  `freshness = immediate` (or narrowing the waited head scope) is a breaking
  `QueryFreshnessChanged` finding; scope-preserving rewrites are recognized as
  equivalent; strengthenings are additive `CompatibilityStrengthened`. The
  spurious additive "Strong scope widened" verdict previously emitted for such
  migrations is gone. Same-language diffs are byte-identical to before.
```

ADR check: per the Decision Log, no ADR is amended — re-confirm during the distillation
pass that the fix stayed inside ADR-4's existing layer-2 ownership. If the migration
semantics matrix is judged durable project memory beyond this plan and the user docs,
prefer citing this plan from the docs over amending ADR-4, since the boundary contract
did not change.

Finish with the full repository gate and bookkeeping:

```bash
just verify
```

Acceptance: `just verify` passes end to end (Haskell build and all test suites, ADR/
research/capabilities validation, extension and generated-name policies, conformance
corpus policy, migrations tests). Update the Exec-Plan Registry row for EP-1 in
`docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md`
to Complete and add a milestone summary to its Progress section (EP-4 / plan 253 is
soft-blocked on this plan landing — note the unblock). Complete this plan's Progress,
Surprises & Discoveries, and Outcomes & Retrospective sections.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Milestone 1:

```bash
# 1. Create the fixture (content: the language 4 spec in Context and Orientation).
$EDITOR keiro-dsl/test/fixtures/readmodel-migration-l4.keiro
# 2. Add the three "freshness migration" tests to keiro-dsl/test/Main.hs
#    (after the "classifies Eventual to Strong read-model consistency as additive" test).
# 3. Prove both fixture endpoints are check-valid, then run the focused suite red:
EXE="$(cabal list-bin keiro-dsl)"
"$EXE" check keiro-dsl/test/fixtures/readmodel-migration-l4.keiro   # expect: OK
cabal test keiro-dsl-test --test-option=--match --test-option="freshness migration"
```

Expected red output shape (abridged):

```text
Failures:
  1) diff (evolution classification) classifies the legacy Strong to language-5 immediate freshness migration as breaking
     expected: [QueryFreshnessChanged]
     ... [] does not contain ...
```

Milestone 2:

```bash
# Apply the policyChanges split in keiro-dsl/src/Keiro/Dsl/Diff.hs, then:
cabal build keiro-dsl
cabal test keiro-dsl-test --test-option=--match --test-option="freshness migration"   # green
cabal test keiro-dsl-test --test-option=--match --test-option="read-model"            # green
git add keiro-dsl/src/Keiro/Dsl/Diff.hs keiro-dsl/test/Main.hs keiro-dsl/test/fixtures/readmodel-migration-l4.keiro
git commit   # conventional commit + trailers, see below
```

Milestone 3:

```bash
cabal build all
cabal test keiro-dsl:tests
just corpus-regen && git status --short          # must print nothing
just conformance-corpus-policy
bash keiro-dsl/test/diff-test.sh                 # must end with "PASS:"

# CLI gate transcripts:
EXE="$(cabal list-bin keiro-dsl)"
DEMO="$(mktemp -d)"; git -C "$DEMO" init -q
cp keiro-dsl/test/fixtures/readmodel-migration-l4.keiro "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "language 4 baseline"
# 1) weakening must block:
sed -e 's/^language keiro-dsl 4$/language keiro-dsl 5/' \
    -e 's/^  consistency = Strong$/  freshness = immediate/' \
    -e '/^  scope = category "reservation"$/d' \
    -e '/^  feed = subscription$/d' \
    -e '/^  subscription = "hospital-capacity-transfer-decisions-sub"$/d' \
    keiro-dsl/test/fixtures/readmodel-migration-l4.keiro > "$DEMO/svc.keiro"
"$EXE" check "$DEMO/svc.keiro"                    # OK: the weakened endpoint is check-valid
"$EXE" diff --since HEAD "$DEMO/svc.keiro"; echo "exit=$?"   # BREAKING + exit!=0
```

Expected transcript 1 (after the fix; abridged — the source-language ADDITIVE and the
AggFoldSurfaceChanged WARNING lines also appear):

```text
BREAKING: transfer_decisions query-freshness transfer_decisions: query freshness weakened wait-for-head category 'reservation' -> immediate across the legacy consistency migration; callers lose the cursor-wait guarantee
exit=1
```

Repeat with the Eventual baseline (equivalent, exit 0), the
`freshness = wait-for-head entire-log` variant (additive, exit 0), and a recommit of the
unchanged language 4 file (silent, exit 0), as specified in Milestone 3. Record all
transcripts in this plan.

Milestone 4:

```bash
$EDITOR docs/user/read-models-and-projections.md docs/user/api-reference.md keiro-dsl/CHANGELOG.md
just verify
$EDITOR docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md
$EDITOR docs/plans/250-report-legacy-strong-consistency-weakening-across-the-language-4-to-5-migration-in-diff.md
git add -A && git commit   # docs(dsl): document the migration freshness gate  + trailers
```


## Validation and Acceptance

The change is accepted when all of the following observable behaviors hold:

1. Failing-before/passing-after: the three "freshness migration" tests in
   `keiro-dsl/test/Main.hs` fail at the pre-fix HEAD with the transcript recorded in
   Milestone 1 (empty breaking list; spurious `read-model-scope` additive) and pass after
   Milestone 2.
2. Gate behavior: `keiro-dsl diff --since <rev>` over the Strong-to-immediate migration
   prints a BREAKING `query-freshness` finding carrying `QueryFreshnessChanged`, does not
   print `Strong scope widened`, and exits non-zero. The Eventual-to-immediate and
   scope-preserving migrations exit 0 with no breaking read-model finding. A recommit of
   an unchanged language 4 spec diffs silently.
3. No false positives: the full `cabal test keiro-dsl:tests` run passes, including the
   frozen legacy read-model diff tests ("classifies read-model feed flips and
   consistency/scope weakening as breaking", "classifies Eventual to Strong read-model
   consistency as additive"), the language 5 freshness isolation test, the frontend-0.7
   compatibility oracle, and the conformance-baseline scan — none of their expectations
   change.
4. Zero drift: `just corpus-regen` leaves the working tree clean and
   `just conformance-corpus-policy` passes, proving the languages 1–4 byte-compatibility
   bar from plan 245 M4 still holds and no generated artifact moved.
5. End-to-end: `bash keiro-dsl/test/diff-test.sh` and `just verify` pass.
6. Documentation: the migration table in `docs/user/read-models-and-projections.md`
   states the diagnostic for the weakening, `docs/user/api-reference.md` mentions the
   migration coverage of `QueryFreshnessChanged`, and `keiro-dsl/CHANGELOG.md` Unreleased
   carries the Fixed entry.


## Idempotence and Recovery

Every step is repeatable. Tests and classification code have no database or network side
effects; the CLI transcripts use throwaway `mktemp -d` git repositories. `just
corpus-regen` is deterministic — if it ever dirties the tree during this plan, `git
checkout -- .` restores the corpus and the classification change must be inspected for an
unintended generation dependency before retrying. If the Milestone 2 pattern split
produces GHC warnings (incomplete or overlapping patterns), keep the explicit final
`(FreshnessImmediate, FreshnessImmediate)` arm and the leading equality guard as written;
do not replace arms with a wildcard. If a message-string refinement breaks the pinned
substring assertion, update the test, the docs sentence, and the changelog entry in the
same commit. The work lands as ordinary commits on the current branch; reverting the
single fix commit restores the previous behavior exactly.


## Interfaces and Dependencies

No public API, module export, type, or `DiagnosticCode` constructor is added or changed.
The complete edit surface is:

- `keiro-dsl/src/Keiro/Dsl/Diff.hs` — `readModelPairDiff`'s `policyChanges` local
  definition becomes a three-case split over `(rmSupply oldReadModel, rmSupply
  newReadModel)`, plus the new local `migrationFreshnessChanges ::
  [Change]` (a `where`-bound list, not an exported function). It uses only existing
  helpers: `breaking, additive :: Name -> Text -> Text -> DiagnosticCode -> Text ->
  Change`; `renderFreshness :: QueryFreshnessNode -> Text`; `renderScope :: RmScope ->
  Text`; `scopeStrengthened :: RmScope -> RmScope -> Bool`; and the existing codes
  `QueryFreshnessChanged` and `CompatibilityStrengthened` from
  `Keiro.Dsl.Validate`'s `DiagnosticCode`.
- `keiro-dsl/test/Main.hs` — three new `it` blocks under
  `describe "diff (evolution classification)"`, using existing helpers `readTestText`,
  `checkedServiceFromText`, `diffServices`, `kindOfChange`, `ckCode`, `ckFacet`,
  `ckDetail`, `isBreaking`, and the `Breaking`/`Additive`/`Advisory` constructors.
- `keiro-dsl/test/fixtures/readmodel-migration-l4.keiro` — new declared-language-4
  fixture (accepted by the conformance-baseline scan without manifest changes).
- `docs/user/read-models-and-projections.md`, `docs/user/api-reference.md`,
  `keiro-dsl/CHANGELOG.md`, MasterPlan 40, and this plan — documentation and bookkeeping.

Semantics this plan depends on but must not modify: the parser's legacy-to-freshness
normalization (`keiro-dsl/src/Keiro/Dsl/Parser/ReadModel.hs`), the `ReadModelSupply`
provenance split (`keiro-dsl/src/Keiro/Dsl/Grammar.hs`), the compatibility-vector and
context wiring for `QueryFreshnessChanged`/`CompatibilityStrengthened`
(`classifyCompatibility`, `contextFor` in Diff.hs), and the projection-supply analysis
call sites that plan 253 will consolidate.

### Commit and trailer convention

Use Conventional Commits (`fix(dsl): ...` for the test+fix commit, `docs(dsl): ...` for
the documentation commit) and include these trailers on every commit of this plan:

```text
MasterPlan: docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md
ExecPlan: docs/plans/250-report-legacy-strong-consistency-weakening-across-the-language-4-to-5-migration-in-diff.md
Intention: intention_01kzw6dkcserms9yr61sqdntep
```
