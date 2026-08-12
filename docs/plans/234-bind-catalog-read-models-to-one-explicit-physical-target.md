---
id: 234
slug: bind-catalog-read-models-to-one-explicit-physical-target
title: "Bind catalog read models to one explicit physical target"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjznhgeyvbcpfk1znzmbnr"
master_plan: "docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md"
---

# Bind catalog read models to one explicit physical target

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl` is the typed specification language in this repository: an author writes a
`.keiro` source file describing a service (aggregates, read models, projection catalogs,
queues), runs `keiro-dsl check` to validate it, and `keiro-dsl scaffold` to generate
deterministic Haskell modules from it. The next release (0.12.0.0) publishes language
version 5 — today the amendable `Candidate` entry in
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` — as the first stable language contract.
Once published, the language's accepted forms and generated output layout are frozen;
any fix to what it accepts or generates becomes a breaking language change. This plan
fixes two confirmed defects from the 2026-08-11 pre-release review, both about whether a
catalog-bound read model's declared and generated identity tell the truth. Both fixes
change what language 5 accepts and generates, so both are legal only now, inside the
candidate window, and must land before the registry entry flips to `Stable`.

Defect A (silent physical binding): a language-5 read model that declares
`table = "x" schema = "y"` together with `group = g` and `targets = [ a b ]` today
scaffolds its generated `ReadModelTable` module bound to target `a`'s schema and table —
not `x.y` — with zero diagnostics. The declared table/schema are parsed, stored, and then
silently overwritten by the coordinates of the first listed target. Worse, because the
binding comes from list position, innocently reordering `targets = [ a b ]` to
`targets = [ b a ]` rebinds every generated SQL identity to a different physical table,
again silently. After this plan: declaring `table =`/`schema =` on a catalog-bound read
model is rejected with a specific named diagnostic; a read model observing more than one
target must name its physical backing target explicitly with a new `backing =` clause;
and reordering the `targets` list changes no generated identity at all.

Defect B (vacuous harness fact): for catalog-managed read models the generated
`ReadModelHarness` module currently emits the fact row
`("asyncProjectionName", "catalog-managed", "catalog-managed")` — a constant compared to
itself, which can never fail. A codegen regression that mis-wires the async registration
identity in the generated `ProjectionCatalog` module would sail through the harness while
the deployed service registers under the wrong subscription and silently receives no
events. After this plan the grouped harness compares identities derived from the spec at
generation time against the values the generated `ProjectionCatalog` module actually
exports, and a mutation-style test proves the comparison fails when those generated
values are perturbed.

How to see it working after implementation: `cabal run -v0 keiro-dsl -- check` on the new
override fixture prints `error[CatalogReadModelPhysicalOverride]` and exits 1; scaffolding
the two reorder fixtures produces byte-identical output directories; and the
`keiro-dsl-conformance-projection-catalog` test suite passes with harness fact rows that
demonstrably fail when fed a perturbed registration list.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] (2026-08-11 19:02 PDT) M1: Add `CatalogReadModelPhysicalOverride` to `DiagnosticCode` in `keiro-dsl/src/Keiro/Dsl/Validate.hs`.
- [x] (2026-08-11 19:02 PDT) M1: Emit the diagnostic from `validateReadModel`'s `catalogBinding` block when `rmGroup` is set and `rmTable` or `rmSchema` is non-empty.
- [x] (2026-08-11 19:02 PDT) M1: Create fixture `keiro-dsl/test/fixtures/catalog-readmodel-physical-override.keiro` and a spec test asserting the code.
- [x] (2026-08-11 19:02 PDT) M1: Confirm the diagnostic-code round-trip test (`test/Main.hs`, "round-trips every stable diagnostic code spelling") passes with the new constructor.
- [x] (2026-08-11 19:15 PDT) M2: Add `rmBackingTarget :: !(Maybe Name)` to `ReadModelNode` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs` and fix all record construction sites compiler-first.
- [x] (2026-08-11 19:15 PDT) M2: Parse optional `backing = <ident>` after `targets` in `keiro-dsl/src/Keiro/Dsl/Parser/ReadModel.hs` (inside the `group` branch only).
- [x] (2026-08-11 19:15 PDT) M2: Render `backing` in `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` so `parse . render` round-trips.
- [x] (2026-08-11 19:15 PDT) M2: Add `CatalogReadModelBackingRequired` and `CatalogReadModelBackingUnobserved` codes and their `validateReadModel` rules.
- [x] (2026-08-11 19:15 PDT) M2: Move `resolveCatalogReadModel` into `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, resolve by backing-target name, and delete the duplicate copies in `ScaffoldRun.hs` and `WorkspaceScaffold.hs`.
- [x] (2026-08-11 19:15 PDT) M2: Sort the observed-target list rendered into the generated `ProjectionCatalog` query binding (`queryExpr` in `Scaffold.hs`).
- [x] (2026-08-11 19:15 PDT) M2: Make `readModelPairDiff` in `keiro-dsl/src/Keiro/Dsl/Diff.hs` compare `(group, target set, effective backing)` instead of `(group, target list)`.
- [x] (2026-08-11 19:15 PDT) M2: Create fixtures `catalog-readmodel-backing-required.keiro`, `catalog-readmodel-backing-unobserved.keiro`, and the reorder pair `catalog-readmodel-reorder-a.keiro` / `catalog-readmodel-reorder-b.keiro`, with tests.
- [x] (2026-08-11 19:15 PDT) M2: Test that scaffolding the reorder pair yields identical module sets, and that a real target-set change still reports `CatalogQueryBindingChanged`.
- [x] (2026-08-11 19:29 PDT) M3: Extend `harnessReadModel` / `emitReadModelHarness` in `keiro-dsl/src/Keiro/Dsl/Harness.hs` to take the `Spec` and emit real grouped facts (`catalogRegistration` row plus per-feeding-owner `asyncRegistration` rows via a `catalogFactsAgainst` helper).
- [x] (2026-08-11 19:29 PDT) M3: Update the three `harnessReadModel` call sites (`ScaffoldRun.hs`, `WorkspaceScaffold.hs`, `test/Main.hs`).
- [x] (2026-08-11 19:29 PDT) M3: Add textual emitter tests: grouped harness imports the generated `ProjectionCatalog` module, pins the spec-derived expected identities, and no longer contains the constant `"catalog-managed", "catalog-managed"` row.
- [x] (2026-08-11 19:29 PDT) M3: Add the runtime mutation test to `keiro-dsl/test/conformance-projection-catalog/Main.hs` (hand-owned): `catalogFactsAgainst` fails on a perturbed registration list and passes as generated.
- [ ] M4: Run `just corpus-regen`; commit regenerated `conformance-projection-catalog`, `conformance-mapped-readmodel`, and `conformance-declarative-router` modules; run `just conformance-corpus-policy`.
- [ ] M4: Run `just verify` clean.
- [ ] M4: Update `CHANGELOG.md` (Unreleased, keiro-dsl entries: new codes, new clause, forbidden form, harness change).
- [ ] M4: Extend `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md` with the binding rule (see Decision Log) and update the MasterPlan-36 registry row and progress checkboxes.
- [ ] Final: ADR distillation pass and Outcomes & Retrospective entry.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The first full `keiro-dsl-test` run passed all 691 semantic examples and failed only
  the explicit non-stable-fixture inventory after the new language-5 fixture appeared.
  Adding `catalog-readmodel-physical-override.keiro` to that inventory made the focused
  policy test pass. This is the same corpus bookkeeping constraint EP-1 surfaced, and
  M2 must register its four additional candidate-language fixtures at creation time.

  ```text
  Finished in 227.4155 seconds
  692 examples, 1 failure
  ...
  keeps only the named source-version compatibility fixtures outside stable v4
  ```

- Regenerating the grouped harnesses changed five modules across three suites, not only
  the two suites named in the original milestone: `conformance-declarative-router` also
  contains the grouped `hospitalLoad` read model. All three affected suites compiled and
  passed. The mutation test also showed that GHC 9.12 cannot disambiguate a qualified
  `subscriptionName` record update because the catalog module exports three records with
  that field; reconstructing `AsyncProjectionRegistration` makes the negative control
  explicit and portable.


## Decision Log

- Decision: Forbid explicit `table =`/`schema =` on catalog-bound read models with a new
  error diagnostic `CatalogReadModelPhysicalOverride`, rather than honoring the declared
  values over the target's coordinates.
  Rationale: `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
  separates the query-model identity from the physical target identity; the target
  declaration is the single owner of schema/table coordinates. Honoring a read-model-local
  table/schema would create two competing physical authorities for one table and reintroduce
  the drift ADR 0026 exists to prevent. Under language 5 every read model must bind to a
  group (`CatalogReadModelBindingMissing` fires otherwise), so a read-model-local
  table/schema can never be anything but dead or conflicting text. Rejection is legal now
  only because candidate 5 is amendable in place; after publication the same rejection
  would be a breaking language change — this is exactly why the fix gates the release.
  Date: 2026-08-11

- Decision: Keep multi-target read models legal and require an explicit
  `backing = <target>` clause whenever a read model observes more than one target; a
  single observed target is its own backing implicitly. Do not reject multi-target
  observation outright, and do not require groups to be single-target.
  Rationale: ADR 0026 states the cardinality explicitly — "One query can observe several
  tables." Observation (`targets = [...]`) is the lifecycle relation: the query model is
  fenced and rebuilt with every target it reads. The generated `ReadModel` value and
  `ReadModelTable` module, however, carry exactly one qualified table
  (`Keiro.ReadModel.ReadModel` has one `tableName`/`schema` pair), so the physical binding
  needs exactly one designated target. The current corpus only exercises single-target
  read models, but the grammar and ADR intent make multi-target observation meaningful,
  so the honest rule is "observation is a set; the physical binding names one member",
  not "multi-target is illegal". Missing `backing` with two or more targets is
  `CatalogReadModelBackingRequired`; a `backing` naming a target outside the observed list
  is `CatalogReadModelBackingUnobserved`. `backing` on a single-target read model is
  permitted (explicit is never wrong) and must equal that target.
  Date: 2026-08-11

- Decision: Resolve the physical binding by target name, never by list position, and
  render the observed-target list inside the generated `ProjectionCatalog` module in
  sorted order.
  Rationale: order-insensitivity is the point of the fix. The runtime already sorts
  observed targets before fingerprinting (`inventoryQueryModels` applies `List.sort` in
  `keiro/src/Keiro/Projection/Catalog.hs`, line 1470), so declared order carries no
  runtime meaning — unlike a rebuild group's `order =` clause, which stays ordered.
  Sorting the rendered list makes the generated module byte-stable under reordering.
  The scaffold-record sidecar row (`ScaffoldRecord.hs` line 302) keeps declared order:
  it is source provenance, not generated identity, and changing its format would touch
  record parsing for no behavioral gain.
  Date: 2026-08-11

- Decision: Diff classification — compare `(rmGroup, Set.fromList rmObservedTargets,
  effective backing)` in `readModelPairDiff` and keep reporting binding changes under the
  existing `CatalogQueryBindingChanged` code (already classified as
  persisted-identity-breaking). Do not add a new evolution code.
  Rationale: after the fix a pure reorder changes nothing generated, so diff reporting a
  breaking change for it would be a false alarm; set comparison removes it. A change of
  backing target genuinely rebinds the generated qualified table, which is precisely the
  persisted-lifecycle hazard `CatalogQueryBindingChanged` already names, so reusing it
  keeps the code inventory small and the classification table
  (`classifyCompatibility` in `Diff.hs`) untouched.
  Date: 2026-08-11

- Decision: Diagnose the forbidden `table/schema + group` form in validation, not in the
  parser.
  Rationale: the parser must keep the mandatory table/schema branch for published
  languages 1–4 (their grammar requires the clauses), and a validation diagnostic carries
  a stable `DiagnosticCode` that tests, `--deny`, and check reports can name, whereas a
  megaparsec parse error cannot. The parser's `option ("", "")` acceptance under
  `ProjectionCatalogSyntax` stays; empty text remains the "absent" sentinel.
  Date: 2026-08-11

- Decision: Restore the grouped harness fact as two kinds of real rows, generated from a
  parameterized helper. Every grouped read model gets a `catalogRegistration` row
  (expected registry name, version, shape hash, and rebuild group derived from the spec
  at emit time, versus the entry the generated `ProjectionCatalog` module exports in
  `projectionCatalogRegistrations`). Additionally, one `asyncRegistration:<owner>` row per
  subscription-fed projection owner in the same group observing an overlapping target
  (expected subscription and dedup names from the spec, versus the matching entry in
  `projectionCatalogAsyncRegistrations`). The rows are produced by an exported
  `catalogFactsAgainst` function taking the two registration lists as arguments, applied
  to the generated module's exports in `readModelFacts` — which lets the corpus driver
  demonstrate failure on a perturbed list without editing generated code.
  Rationale: the defect narrative is "mis-wired async registration identity passes the
  harness"; the fix must compare spec-derived expectations against values that actually
  flow out of the generated `ProjectionCatalog` module. The `catalogRegistration` row is
  real for every grouped model, including a subscription-fed read model whose group has
  no async owner (the corpus's `shipmentLookup` is exactly this shape), so no model gets
  a vacuous or absent identity check. Parameterization is what makes the mutation test
  honest rather than textual.
  Date: 2026-08-11

- Decision: Unify the two identical copies of `resolveCatalogReadModel` (module-level in
  `ScaffoldRun.hs` lines 307–315, local in `WorkspaceScaffold.hs` lines 296–303) into one
  exported function in `Keiro.Dsl.Scaffold`.
  Rationale: both call sites already import `Keiro.Dsl.Scaffold`; a second silently
  diverging copy of binding logic is how Defect A survived review. Plan 236 will later
  refactor `resolveTypeGraph` call sites in these same files — keeping this plan's edits
  to one new exported helper plus two call-site substitutions minimizes that rebase.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Everything in this section was verified against the working tree at commit `5db45a42`.
Line numbers are anchors, not promises; re-locate by symbol name if they have drifted.

### The moving parts, in plain language

A `.keiro` source file parses into a `Spec` — a list of declaration nodes defined in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs`. The nodes relevant here form a "projection
catalog", the language-5 feature that describes a service's read side as one validated
inventory (see `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`):

- `target <name> { schema = "..." table = "..." reset = ... }` — a `ProjectionTargetNode`
  (`ptName`, `ptSchema`, `ptTable`): one application-owned PostgreSQL table. This is the
  single authority for physical coordinates.
- `rebuild-group <name> { targets = [...] order = [...] }` — a `RebuildGroupNode`: the
  set of targets that move through offline rebuild as one atomic lifecycle. The `order`
  list is meaningful (rebuild sequencing).
- `projection-owner <name> { source = ... feed = inline|subscription group = ...
  targets = [...] ... }` — a `ProjectionOwnerNode`: the single writer of one or more
  targets. A subscription-fed owner also declares `subscription = "..."`,
  `dedup = "..."`, and `checkpoint-on-missing` (ADR 0031 made the checkpoint policy part
  of catalog identity).
- `readmodel <name> { ... group = <g> targets = [ ... ] }` — a `ReadModelNode` with
  `rmGroup :: Maybe Name` and `rmObservedTargets :: [Name]`. A "catalog-bound" (or
  "grouped") read model is one with `rmGroup = Just _`. It is the query surface: it
  observes targets so the runtime can fence and rebuild it with them.

`keiro-dsl scaffold` generates, per read model, a three-module vertical
(`scaffoldReadModelForService` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, around line
4046): `ReadModelTable.hs` (one `qualifyTable "<schema>" "<table>"` constant),
`ReadModel.hs` (a `Keiro.ReadModel.ReadModel` value with one `tableName`/`schema` pair),
and `ReadModelHarness.hs` (emitted by `keiro-dsl/src/Keiro/Dsl/Harness.hs`). Per
service, `scaffoldProjectionCatalog` (Scaffold.hs line 4083) generates one
`ProjectionCatalog.hs` module that assembles the runtime
`Keiro.Projection.Catalog.ProjectionCatalog` value, validates it at load, and exports
pure inventory projections — notably `projectionCatalogRegistrations ::
[Catalog.CatalogRegistration]` (fields `queryModelId`, `registryName`, `version`,
`shapeHash`, `rebuildGroupId`) and `projectionCatalogAsyncRegistrations ::
[Catalog.AsyncProjectionRegistration]` (fields `projectionId`, `projectionName`,
`subscriptionId`, `subscriptionName`, `checkpointOnMissing`, `dedupKeyId`, `dedupName`;
both types in `keiro/src/Keiro/Projection/Catalog.hs`, lines 646–685).

A "harness" is a generated, runtime-free module of fact rows
`(fact, expected-from-notation, actual-generated-value)` whose driver fails when any
pair disagrees — the spec-to-generated-code pin described in
`docs/adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md`. A
"conformance corpus" is a committed scaffold output compiled and executed as a cabal
test suite; `just corpus-regen` re-runs the recorded scaffold invocations and rewrites
only `@generated` modules (hand-owned files such as each corpus `Main.hs` and the
`*Holes.hs` modules are preserved), and `just conformance-corpus-policy` fails if the
committed corpus differs from a fresh regeneration.

### Defect A, precisely

`keiro-dsl/src/Keiro/Dsl/Parser/ReadModel.hs` (lines 20–33): when the language supports
`ProjectionCatalogSyntax` (only candidate 5 does — see the registry in
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, lines 240–247 and `profileV4` at 273), the
`table =`/`schema =` pair is parsed with `option ("", "")`, so it may appear alongside
`group`/`targets`. For languages 1–4 the pair is mandatory and `group` does not parse at
all, so the conflicting combination is expressible only in language 5.

`keiro-dsl/src/Keiro/Dsl/Validate.hs`, `validateReadModel` (line 2481): the
`identifiers` check (line 2542) validates schema/table only when `rmGroup readModel ==
Nothing`, and the `catalogBinding` block (line 2573) checks group membership but never
looks at `rmTable`/`rmSchema`. Declared values on a grouped read model are therefore
dead and undiagnosed.

`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` (lines 307–315):

```haskell
resolveCatalogReadModel :: Spec -> ReadModelNode -> ReadModelNode
resolveCatalogReadModel spec readModel =
  case rmGroup readModel of
    Nothing -> readModel
    Just _ -> case rmObservedTargets readModel of
      targetName : _ -> case [target | NProjectionTarget target <- specNodes spec, ptName target == targetName] of
        target : _ -> readModel {rmSchema = ptSchema target, rmTable = ptTable target}
        [] -> readModel
      [] -> readModel
```

The first observed target wins, unconditionally overwriting whatever the author wrote.
An identical local copy lives in `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` (lines
296–303) for the workspace scaffold path — both must change.

Consequences confirmed against the corpus: the fixture
`keiro-dsl/test/fixtures/projection-catalog.keiro` declares `readmodel catalogAudit`
with `targets = [ audit_log ]` and no table/schema; the committed
`keiro-dsl/test/conformance-projection-catalog/Generated/CatalogDemo/CatalogAudit/ReadModelTable.hs`
contains `qualifyTable "sales" "audit_log"` — resolution works, but only by position.
Add a second target first in that list and every generated SQL identity moves, silently.

### Defect B, precisely

`keiro-dsl/src/Keiro/Dsl/Harness.hs`, `emitReadModelHarness` (line 238), `asyncFactRow`
(lines 288–293):

```haskell
    asyncFactRow
      | rmGroup readModel /= Nothing = "  , (\"asyncProjectionName\", \"catalog-managed\", \"catalog-managed\")"
      | otherwise = case rmFeed readModel of
          RmInline -> "  , (\"asyncProjectionName\", \"none\", \"none\") -- Definitionally inert: ..."
          RmSubscription -> "  , (\"asyncProjectionName\", " <> tshow expectedAsync <> ", T.unpack " <> asyncProjectionName <> ".name)"
```

The non-grouped subscription branch is the pre-catalog behavior worth restoring in
spirit: it compares the spec-derived expectation (`<registry>-async`) against the `name`
field of the generated `AsyncProjection` value — a real generated artifact. The grouped
branch compares a constant to itself. For grouped read models the async identity now
lives in the generated `ProjectionCatalog` module: each subscription-fed owner lowers to
`Catalog.AsyncHandler (AsyncProjection "<dedup>" "<registry-of-first-matching-read-model>"
"<subscription>" ...)` plus a `SubscriptionDeclaration` (see `handlerExpr` and
`subscriptionExpr` in `Scaffold.hs`, lines 4245–4346), and the validated catalog projects
these into `projectionCatalogAsyncRegistrations`. Nothing generated asserts those values
against the spec today; the corpus `Main.hs` checks counts and fingerprints but not the
per-read-model identity chain.

The corpus population for grouped read models is exactly two suites:
`keiro-dsl/test/conformance-projection-catalog` (read models `order_inline` — inline
feed; `shipmentLookup` — subscription feed, group `shipping`, whose only owner is
inline-fed, so no async registration corresponds to it; `catalogAudit` — subscription
feed, fed by owner `audit_writer` with subscription `catalog-demo-audit` and dedup
`catalog-demo-audit-v1`) and `keiro-dsl/test/conformance-mapped-readmodel`
(`account_summary`, fed by `account_summary_writer`). `jitsurei/` contains no `.keiro`
sources and no catalog read-model declarations; the corpus fixtures are the entire
current population, which is why the silent rebinding never bit in practice.

### Why the fix cannot disturb frozen replay identity

`docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md`
freezes aggregate fold identity: pre-hash bytes come only from
`Keiro.Dsl.CanonicalEncoding` over aggregate expressions and transitions. Read-model
physical bindings never enter that encoder. The read-model shape hash is separately
frozen but deliberately excludes physical identity for grouped models:
`keiro-dsl/src/Keiro/Dsl/ReadModelShape.hs` (lines 24–37) roots `canonicalShape` at the
literal `"query-model"` when `rmGroup` is set ("catalog-bound query models deliberately
do not duplicate physical authority owned by their target declarations"). The runtime
catalog fingerprint sorts observed targets before hashing (`Catalog.hs` line 1470), so
neither the sorted rendering nor name-based backing resolution changes any fingerprint
for existing single-target specs. The new `backing` clause and diagnostics touch no
canonical encoding. Conclusion: this plan changes generated text and acceptance rules
only; no fold, shape, wire, or catalog fingerprint of any existing valid spec changes.

### Diagnostic codes are public API

`DiagnosticCode` in `Validate.hs` (line 75) is a public `Enum`/`Bounded` enumeration.
`diagnosticCodeText = T.pack . show` (line 65) and `parseDiagnosticCode` scans
`[minBound .. maxBound]` (line 70), so a new constructor is automatically rendered,
parseable by `--deny <Code>`, and covered by the round-trip test at `test/Main.hs` line
988 ("round-trips every stable diagnostic code spelling"). No separate registration
table exists. External exhaustive consumers are the reason the CHANGELOG "Unreleased"
section must note the additions (it already carries a precedent entry for the catalog
codes). This plan owns all `DiagnosticCode` additions in MasterPlan 36; plan 236 must
not add codes.

### ADRs read for this plan

- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md` —
  the identity separation this plan enforces: targets own physical coordinates; query
  models observe targets ("One query can observe several tables"); one owner per table.
  The new binding rule (explicit backing, table/schema forbidden on grouped read models)
  belongs in this ADR as an update when implemented — add it to the Decision section in
  the same change that completes M4.
- `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md` —
  precedent for this plan's posture: candidate language 5 may require a new clause
  ("requires exactly one checkpoint-on-missing clause … there is no compatibility
  default because Language 5 remains unreleased"). The `backing` requirement follows the
  same rule.
- `docs/adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md` — how
  generated harnesses are assembled and compiled; harness facts stay in the runtime
  package beside generated modules, which is why the grouped harness may import the
  generated `ProjectionCatalog` module directly.
- `docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md` —
  what frozen replay identity is; see the safety analysis above.

No relevant cross-repository ADR was found for this work (the catalog decisions are
local; `mori registry` lookups were not required beyond what ADR 0026 already cites).

### Coordination constraints from MasterPlan 36

Parent: `docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md`.
Plan 233 (outcome keyword gating) also regenerates the conformance corpus — whichever
plan lands second runs `just corpus-regen` on top of the first, so corpus churn stays
attributable. Plan 235 edits the legacy `Spec`-only entry points at the top of
`ScaffoldRun.hs`; this plan's `ScaffoldRun.hs` edit is confined to the
`resolveCatalogReadModel` call site inside `scaffoldServiceModulesWithBehaviorSource`.
Plan 236 will refactor `resolveTypeGraph` call sites in `Validate.hs`, `ScaffoldRun.hs`,
and `Harness.hs` afterward — keep this plan's changes localized to the functions named
here and do not restructure surrounding plumbing.


## Plan of Work

The work is four milestones. M1 and M2 are the language-acceptance fix (Defect A,
validation first, then binding semantics); M3 is the harness fix (Defect B); M4 is
regeneration, documentation, and the full gate. Each milestone leaves the tree
compiling and its tests passing.

### Milestone 1 — reject explicit table/schema on catalog-bound read models

Scope: one new diagnostic, one validation rule, one fixture, tests. At the end, the
silent-override form from Defect A is a named check error, and nothing else changes.

In `keiro-dsl/src/Keiro/Dsl/Validate.hs`, add `CatalogReadModelPhysicalOverride` to the
`DiagnosticCode` enumeration immediately after `CatalogReadModelTargetOutsideGroup`
(line 236) — grouping with its family; insertion position only affects derived `Ord`,
which is not persisted. In `validateReadModel`'s `catalogBinding` block (line 2573), add
a `physicalOverride` list alongside `missingGroup`/`unknownGroup`/`missingTargets`/
`targetOutsideGroup`:

```haskell
        physicalOverride =
          [ mkErr readModelLine CatalogReadModelPhysicalOverride $
              "readmodel '" <> rmName readModel <> "' binds to group '" <> groupName
                <> "' but declares explicit table/schema; physical coordinates belong to the target declaration — remove table/schema and name the intended target in 'targets' (and 'backing' when observing several)"
          | Just groupName <- [rmGroup readModel],
            rmTable readModel /= "" || rmSchema readModel /= ""
          ]
```

Empty text is the parser's "absent" sentinel (`option ("", "")` in
`Parser/ReadModel.hs`), so this fires exactly when the author wrote the clauses. Create
the fixture `keiro-dsl/test/fixtures/catalog-readmodel-physical-override.keiro` (full
text in Validation and Acceptance below) and add a spec test beside the existing catalog
validation tests in `keiro-dsl/test/Main.hs` using the `errorCodesOf` helper, asserting
the codes contain `CatalogReadModelPhysicalOverride`. Acceptance: the new test passes;
`cabal run -v0 keiro-dsl -- check` on the fixture exits 1 with
`error[CatalogReadModelPhysicalOverride]` on stderr; the full `keiro-dsl-test` suite
passes (the code round-trip test picks up the constructor automatically).

### Milestone 2 — explicit, order-insensitive backing target

Scope: grammar, parser, pretty-printer, two more diagnostics, name-based resolution,
sorted rendering, diff classification, fixtures and tests. At the end, reordering
`targets` changes nothing generated, and a multi-target read model must name its
backing target.

Grammar: add `rmBackingTarget :: !(Maybe Name)` to `ReadModelNode` in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs` (record at line 1196). Compile and fix every
construction site the compiler reports (at minimum `Parser/ReadModel.hs`; any test
constructing the record literally).

Parser: in `pReadModel` (`keiro-dsl/src/Keiro/Dsl/Parser/ReadModel.hs`), after the
`targets` parse inside the `Just group` branch, add:

```haskell
  backing <- case group of
    Nothing -> pure Nothing
    Just _ -> optional (symbol "backing" *> symbol "=" *> ident)
```

and thread it into the record. Because `group` only parses under
`ProjectionCatalogSyntax`, the clause is implicitly language-5-gated; languages 1–4
cannot reach it.

Pretty-printer: in `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` (read-model rendering at
lines 389–409), render `backing = <name>` after the `targets` line when present, so the
`parse . render` round-trip tests keep passing.

Validation: in `validateReadModel`'s `catalogBinding` block add
`CatalogReadModelBackingRequired` (error when `rmGroup` is set, `length
(rmObservedTargets readModel) > 1`, and `rmBackingTarget == Nothing`; message should say
"observes N targets; name the physical backing target with 'backing = <target>'") and
`CatalogReadModelBackingUnobserved` (error when `rmBackingTarget = Just t` and `t
`notElem` rmObservedTargets readModel`). Add both constructors after
`CatalogReadModelPhysicalOverride`. Membership of the backing target in the group is
already implied: every observed target must be in the group
(`CatalogReadModelTargetOutsideGroup`), and backing must be observed.

Resolution: define in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (exported):

```haskell
-- | Resolve a catalog-bound read model's physical binding to its backing
-- target's coordinates, by name. Total: an unbound or unresolvable model is
-- returned unchanged (validation rejects those forms before scaffolding).
resolveCatalogReadModel :: Spec -> ReadModelNode -> ReadModelNode
resolveCatalogReadModel spec readModel = case rmGroup readModel of
  Nothing -> readModel
  Just _ ->
    let backingName = case rmBackingTarget readModel of
          Just name -> Just name
          Nothing -> case rmObservedTargets readModel of
            [single] -> Just single
            _ -> Nothing
     in case [target | NProjectionTarget target <- specNodes spec, Just (ptName target) == backingName] of
          target : _ -> readModel {rmSchema = ptSchema target, rmTable = ptTable target}
          [] -> readModel
```

Replace the body at `ScaffoldRun.hs` lines 307–315 with a re-export or direct use of
this function, and delete the local copy in `WorkspaceScaffold.hs` lines 296–303,
importing the shared one. Note the deliberate behavior change: with several observed
targets and no backing the function no longer picks `targets[0]` — validation has
already refused that spec, and the total fallback returns the node unchanged.

Sorted rendering: in `Scaffold.hs` `queryExpr` (line 4273) render
`renderList (smart "mkTargetId") (sort (rmObservedTargets readModel))` (import
`Data.List (sort)` if absent). The runtime sorts before fingerprinting anyway, so this
is normalization, not a semantic change; all current corpora observe single targets, so
no committed generated byte changes from this line.

Diff: in `readModelPairDiff` (`keiro-dsl/src/Keiro/Dsl/Diff.hs` lines 1249–1252),
change `bindingChanges` to compare
`(rmGroup m, Set.fromList (rmObservedTargets m), effectiveBacking m)` for old and new,
where `effectiveBacking` is `rmBackingTarget` or the single observed target. Keep the
code `CatalogQueryBindingChanged` and extend the message to mention the backing target
when that component changed. The existing diff test (`test/Main.hs` around line 2194)
mutates `targets = [ audit_log ]` to `targets = [ order_summary ]` — a real set change —
and must keep passing.

Fixtures and tests: create the four fixtures shown in Validation and Acceptance
(`backing-required`, `backing-unobserved`, `reorder-a`, `reorder-b`) and tests that (a)
`errorCodesOf` yields the two new codes for the two invalid fixtures, (b) both reorder
fixtures check clean, and (c) scaffolding both reorder fixtures through
`planServiceScaffold`-level test helpers (or the CLI, as the existing scaffold tests do)
yields equal module lists — compare `[(modulePath m, moduleText m)]` for the two runs
after sorting. Acceptance: all listed tests pass; `keiro-dsl-test` overall passes.

### Milestone 3 — real grouped harness facts

Scope: the harness emitter, its call sites, textual emitter tests, and the runtime
mutation test in the corpus driver. At the end, the grouped `ReadModelHarness` asserts
spec-derived identities against the generated `ProjectionCatalog` exports.

Change `harnessReadModel :: Context -> ReadModelNode -> [ScaffoldModule]` in
`keiro-dsl/src/Keiro/Dsl/Harness.hs` (line 226) to
`harnessReadModel :: Context -> Spec -> ReadModelNode -> [ScaffoldModule]` and thread
the spec into `emitReadModelHarness`. Update call sites: `ScaffoldRun.hs` line 288
(`harnessReadModel ctx resolved` becomes `harnessReadModel ctx spec resolved`),
`WorkspaceScaffold.hs` line 283 (pass `merged`), and the emitter test in
`test/Main.hs` line 6390.

In `emitReadModelHarness`, leave every non-grouped path byte-identical (this confines
corpus churn to the two grouped suites). For `rmGroup readModel = Just groupName`,
derive at emit time:

- `feedingOwners` — `[owner | NProjectionOwner owner <- specNodes spec, poFeed owner ==
  RmSubscription, poGroup owner == groupName, any (`elem` poTargets owner)
  (rmObservedTargets readModel)]`, sorted by `poOrder` for deterministic output.
- expected registration facts — registry name via
  `registryNameFor (contextName ctx) readModel`, `rmVersion`, `rmShape`, `groupName`.
- per-owner expected async facts — `fromMaybe "" (poSubscription owner)` and
  `fromMaybe "" (poDedup owner)`.

Then emit, replacing the constant `asyncFactRow`:

- an import of the generated catalog module,
  `import <contextGeneratedPrefix ctx>.ProjectionCatalog qualified as ProjectionCatalog`,
  and `import Keiro.Projection.Catalog qualified as Catalog`;
- an exported pure helper, applied inside `readModelFacts` to the generated exports:

```haskell
catalogFactsAgainst :: [Catalog.CatalogRegistration] -> [Catalog.AsyncProjectionRegistration] -> [(String, String, String)]
catalogFactsAgainst registrations asyncRegistrations =
  [ ( "catalogRegistration"
    , "catalog-demo-catalogAudit|1|fnv1a:9682af3ada04bf50|reporting"
    , renderRegistration [entry | entry <- registrations, Catalog.queryModelIdText entry.queryModelId == "catalogAudit"]
    )
  , ( "asyncRegistration:audit_writer"
    , "catalog-demo-audit|catalog-demo-audit-v1"
    , renderAsync [entry | entry <- asyncRegistrations, Catalog.projectionIdText entry.projectionId == "audit_writer"]
    )
  ]
```

(the literals shown are what the emitter produces for the corpus's `catalogAudit`;
`renderRegistration` renders the singleton as `registryName|version|shapeHash|groupId`
using `Catalog.rebuildGroupIdText`, and `renderAsync` as `subscriptionName|dedupName`;
both render an empty or multiple match as `"missing"` so a mis-keyed generated module
fails loudly). `readModelFacts` then ends with
`<> catalogFactsAgainst ProjectionCatalog.projectionCatalogRegistrations ProjectionCatalog.projectionCatalogAsyncRegistrations`.
Export `catalogFactsAgainst` from the harness module (extend the module export list;
grouped only). Read models with no feeding subscription owner (corpus
`shipmentLookup`, and every inline-fed grouped model such as `order_inline`) emit only
the `catalogRegistration` row — a real assertion in every grouped harness, never a
constant. The `OverloadedRecordDot` pragma the emitter already writes covers the field
access; verify `queryModelIdText`, `projectionIdText`, and `rebuildGroupIdText` are
exported from `Keiro.Projection.Catalog` (they are, per its export list) and use them
rather than constructing ids.

Textual tests in `test/Main.hs`: for the `projection-catalog.keiro` fixture, the
emitted `CatalogAudit/ReadModelHarness.hs` text contains
`ProjectionCatalog.projectionCatalogAsyncRegistrations`, contains the expected literal
`"catalog-demo-audit|catalog-demo-audit-v1"`, and does not contain
`"catalog-managed", "catalog-managed"`; the `ShipmentLookup` harness contains a
`catalogRegistration` row and no `asyncRegistration` row; non-grouped emission for
`test/fixtures/readmodel.keiro` is unchanged (existing assertions at lines 6386–6400
keep passing).

Runtime mutation test in the hand-owned
`keiro-dsl/test/conformance-projection-catalog/Main.hs`: after the existing
`runReadModelFacts` assertions (which prove the pass-as-generated direction), add a
negative control:

```haskell
  let perturbed =
        [ entry {Catalog.subscriptionName = "catalog-demo-audit-WRONG"}
        | entry <- projectionCatalogAsyncRegistrations
        ]
      mutated = CatalogAudit.catalogFactsAgainst projectionCatalogRegistrations perturbed
  assert
    "perturbed async registration identity is detected"
    (any (\(fact, expected, actual) -> fact == "asyncRegistration:audit_writer" && expected /= actual) mutated)
```

(adjust the record-update syntax to the module's field-access conventions; the point is
that the same comparison the harness runs fails when the registration list carries a
wrong subscription name — the exact regression Defect B describes). Acceptance:
`cabal test keiro-dsl-conformance-projection-catalog` passes with both directions.

### Milestone 4 — regenerate, gate, document

Scope: corpus regeneration, the full verify gate, changelog, ADR 0026 update,
masterplan bookkeeping.

Run `just corpus-regen` (repository root). Expect regenerated `ReadModelHarness.hs`
files in `keiro-dsl/test/conformance-projection-catalog/Generated/CatalogDemo/{OrderInline,ShipmentLookup,CatalogAudit}/`
and `keiro-dsl/test/conformance-mapped-readmodel/Generated/MappedReadmodel/AccountSummary/`;
no other corpus should change (their read models are non-grouped and the non-grouped
emitter path is byte-identical). If plan 233 landed first, regenerate on top of its
corpus; if this plan lands first, note in MasterPlan 36 that 233 regenerates on top.
Run `just conformance-corpus-policy`, then `just verify`. Add CHANGELOG "Unreleased"
entries under keiro-dsl: three new `DiagnosticCode` constructors (exhaustive consumers
must extend), the new `backing` clause, the newly rejected `table/schema + group` form
(candidate-language amendment, not a published-language break), the sorted observed-
target rendering, and the grouped-harness fact change. Extend ADR 0026's Decision
section with the binding rule: a catalog-bound read model never declares physical
coordinates; it observes a set of targets and names exactly one backing target
(implicitly when the set is a singleton), and the generated single-table surface binds
to that target by name. Update MasterPlan 36's registry row for EP-2 to Complete and
tick its two EP-2 progress boxes. Acceptance: `just verify` exits 0; `git status` shows
only intended files.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless
stated otherwise. Build and unit-test loop while editing:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test
```

Check a fixture through the real CLI (the tests use the same invocation shape):

```bash
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/catalog-readmodel-physical-override.keiro
```

Expected after M1 (stderr; exact message wording may differ, the code must not):

```text
keiro-dsl/test/fixtures/catalog-readmodel-physical-override.keiro:<line>: error[CatalogReadModelPhysicalOverride]: readmodel 'ledger_view' binds to group 'billing' but declares explicit table/schema; ...
```

with exit code 1 and empty stdout. Before M1 the same command prints `OK` and exits 0 —
run it once before starting to confirm the baseline defect.

Shape-hash workflow for new fixtures: write the fixture with `shape = "fnv1a:0"`, run
`check`, and copy the expected hash from the `RmShapeHashDrift` message ("expected
\"fnv1a:...\"") into the fixture. This is the sanctioned fixture-capture loop; the
grouped canonical shape roots at `"query-model"` so the hash is independent of targets
and backing.

Scaffold-equality check for the reorder pair (M2):

```bash
SCRATCH=$(mktemp -d)
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/catalog-readmodel-reorder-a.keiro --out "$SCRATCH/a"
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/catalog-readmodel-reorder-b.keiro --out "$SCRATCH/b"
diff -r "$SCRATCH/a" "$SCRATCH/b" && echo IDENTICAL
```

Expected output after M2: `IDENTICAL` (before M2 the two `ReadModelTable.hs` files
differ, showing the defect). The scaffold ledger embeds the source file name; if the
ledger sidecar makes `diff -r` noisy, compare the `Generated/` subtrees. Also encode
this as a spec test so it runs in CI, not only by hand.

Targeted suites (M3):

```bash
cabal test keiro-dsl-conformance-projection-catalog
cabal test keiro-dsl-conformance-mapped-readmodel
```

Regeneration and gates (M4):

```bash
just corpus-regen
git status --short   # only the grouped corpora and intended sources
just conformance-corpus-policy
just verify
```

`just verify` runs process-compose checks, jitsurei, `cabal build all`, every declared
test suite via `cabal test keiro-dsl:tests` (never bare `keiro-dsl` — that silently
runs one suite), ADR/OKF validation, and the corpus policy. It requires the dev
Postgres (`just postgres-init` / the process-compose environment) for the non-DSL
suites; the keiro-dsl suites themselves are database-free.


## Validation and Acceptance

Acceptance is behavioral. Each item names the input, the command, and the observation.

First, the fixtures. `catalog-readmodel-physical-override.keiro` (M1) — the Defect A
form verbatim; before this plan it checks `OK`, after it fails with the named code:

```text
language keiro-dsl 5
context binding-demo

target ledger_entries {
  schema = "billing"
  table = "ledger_entries"
  reset = preserve
}

rebuild-group billing {
  targets = [ ledger_entries ]
  order = [ ledger_entries ]
}

projection-owner ledger_writer {
  source = category "ledger"
  feed = subscription
  group = billing
  targets = [ ledger_entries ]
  order = 10
  subscription = "binding-demo-ledger"
  dedup = "binding-demo-ledger-v1"
  checkpoint-on-missing = from-beginning
  replay = explicit
}

readmodel ledger_view {
  table = "somewhere_else"
  schema = "elsewhere"
  columns {
    entry_id text required
  }
  version = 1
  shape = "fnv1a:0"
  consistency = Eventual
  feed = subscription
  subscription = "binding-demo-ledger-view"
  group = billing
  targets = [ ledger_entries ]
}
```

(capture the real shape hash via the workflow above; the parser takes `table`/`schema`
first in the block, before `columns`). `catalog-readmodel-backing-required.keiro` is the
reorder-a fixture below with its `backing` line deleted;
`catalog-readmodel-backing-unobserved.keiro` is reorder-a with
`backing = ledger_archive` where `ledger_archive` is a declared third target in the
group that the read model does not observe.

The reorder pair (M2). `catalog-readmodel-reorder-a.keiro`:

```text
language keiro-dsl 5
context binding-demo

target ledger_entries {
  schema = "billing"
  table = "ledger_entries"
  reset = preserve
}

target ledger_totals {
  schema = "billing"
  table = "ledger_totals"
  reset = preserve
}

rebuild-group billing {
  targets = [ ledger_entries ledger_totals ]
  order = [ ledger_entries ledger_totals ]
}

projection-owner ledger_writer {
  source = category "ledger"
  feed = subscription
  group = billing
  targets = [ ledger_entries ledger_totals ]
  order = 10
  subscription = "binding-demo-ledger"
  dedup = "binding-demo-ledger-v1"
  checkpoint-on-missing = from-beginning
  replay = explicit
}

readmodel ledger_view {
  columns {
    entry_id text required
  }
  version = 1
  shape = "fnv1a:0"
  consistency = Eventual
  feed = subscription
  subscription = "binding-demo-ledger-view"
  group = billing
  targets = [ ledger_entries ledger_totals ]
  backing = ledger_entries
}
```

`catalog-readmodel-reorder-b.keiro` is identical except the read model line reads
`targets = [ ledger_totals ledger_entries ]` — same set, opposite order, same
`backing`. (The group and owner target lists stay in the same order in both files; only
the read model's observation order flips, which is exactly the surface Defect A made
load-bearing.)

Acceptance criteria:

1. Physical override is diagnosed. `cabal run -v0 keiro-dsl -- check
   keiro-dsl/test/fixtures/catalog-readmodel-physical-override.keiro` exits 1, stdout
   empty, stderr contains `error[CatalogReadModelPhysicalOverride]`. The spec test
   asserting the code via `errorCodesOf` passes.
2. Missing backing on a multi-target model is diagnosed:
   `error[CatalogReadModelBackingRequired]` for `catalog-readmodel-backing-required.keiro`;
   a backing outside the observed set yields
   `error[CatalogReadModelBackingUnobserved]`.
3. Reordering targets changes nothing. Both reorder fixtures check `OK`; scaffolding
   both produces identical generated trees (`diff -r` transcript in Concrete Steps
   prints `IDENTICAL`); in particular both `ReadModelTable.hs` files contain
   `qualifyTable "billing" "ledger_entries"` — the named backing target, not the first
   listed one. `keiro-dsl diff` between the two fixture specs reports no
   `CatalogQueryBindingChanged`; the existing diff mutation test where the target set
   genuinely changes (`test/Main.hs` around line 2194) still reports it.
4. Grouped harness facts are real. The regenerated
   `Generated/CatalogDemo/CatalogAudit/ReadModelHarness.hs` contains a
   `catalogRegistration` row pinning
   `catalog-demo-catalogAudit|1|fnv1a:9682af3ada04bf50|reporting` and an
   `asyncRegistration:audit_writer` row pinning
   `catalog-demo-audit|catalog-demo-audit-v1`, both computed on the actual side from
   `ProjectionCatalog.projectionCatalogRegistrations` /
   `projectionCatalogAsyncRegistrations`; the string `"catalog-managed"` appears nowhere
   in any regenerated harness. `cabal test keiro-dsl-conformance-projection-catalog`
   passes, which now includes the mutation assertion: `catalogFactsAgainst` applied to a
   registration list whose subscription name was perturbed reports a failing row, while
   `runReadModelFacts` against the as-generated module reports none. The
   `ShipmentLookup` harness (no feeding async owner) carries the real
   `catalogRegistration` row and no async row.
5. Nothing else moved. `cabal test keiro-dsl:tests` passes in full;
   `just corpus-regen` followed by `git status --short` shows changes only under the two
   grouped corpora; `just conformance-corpus-policy` and then `just verify` exit 0.
6. Frozen identities are untouched. The regenerated corpora show unchanged
   `shape = "fnv1a:..."` fixtures, unchanged `Codec.hs`/`Transducer.hs`/fold surfaces,
   and the projection-catalog corpus `Main.hs` fingerprint assertions
   (`aggregate:Orders/generated-codec/v1/mapped-...` etc.) pass unmodified.


## Idempotence and Recovery

Every step is safe to repeat. Validation and scaffolding are pure functions of the
source tree; `just corpus-regen` is idempotent (running it twice produces no further
diff — that is exactly what `just conformance-corpus-policy` asserts). If a
regeneration goes wrong, `git checkout -- keiro-dsl/test/conformance-projection-catalog
keiro-dsl/test/conformance-mapped-readmodel` restores the committed corpus and the
regeneration can be rerun after fixing the emitter. The hand-owned corpus files
(`Main.hs`, `*Holes.hs`) are never overwritten by regen, but keep the M3 edit to
`conformance-projection-catalog/Main.hs` in its own commit so it can be reverted
independently of generated churn. No database, migration, or destructive operation is
involved; the scratch scaffold comparisons use `mktemp -d` directories. If plan 233 or
236 lands mid-implementation, rebase, rerun `just corpus-regen`, and re-verify — the
corpus policy gate makes a stale regeneration impossible to merge silently. Commit at
each milestone boundary with conventional-commit messages (for example
`feat(dsl): forbid explicit table/schema on catalog-bound read models`).


## Interfaces and Dependencies

All changes are inside the `keiro-dsl` package; the `keiro` runtime package is consumed,
never modified. No dependency bounds change.

End state of each touched interface:

- `Keiro.Dsl.Grammar.ReadModelNode` gains `rmBackingTarget :: !(Maybe Name)`.
- `Keiro.Dsl.Validate.DiagnosticCode` gains `CatalogReadModelPhysicalOverride`,
  `CatalogReadModelBackingRequired`, `CatalogReadModelBackingUnobserved` (this plan owns
  all MasterPlan-36 code additions; the derived `show` spelling is the stable public
  text).
- `Keiro.Dsl.Scaffold` exports
  `resolveCatalogReadModel :: Spec -> ReadModelNode -> ReadModelNode` (name-based
  backing resolution); `Keiro.Dsl.ScaffoldRun` and `Keiro.Dsl.WorkspaceScaffold` call
  it and hold no private copies.
- `Keiro.Dsl.Harness.harnessReadModel :: Context -> Spec -> ReadModelNode ->
  [ScaffoldModule]` (was `Context -> ReadModelNode -> ...`; a breaking keiro-dsl API
  change, in scope for the 0.12 major release and noted in the changelog).
- Generated grouped `ReadModelHarness` modules export `readModelFacts`,
  `readModelFactResults`, `runReadModelFacts`, and `catalogFactsAgainst ::
  [Catalog.CatalogRegistration] -> [Catalog.AsyncProjectionRegistration] ->
  [(String, String, String)]`, and import the service's generated `ProjectionCatalog`
  module plus `Keiro.Projection.Catalog` qualified. Runtime symbols relied on (all
  already exported by `keiro/src/Keiro/Projection/Catalog.hs`):
  `CatalogRegistration(..)`, `AsyncProjectionRegistration(..)`, `queryModelIdText`,
  `projectionIdText`, `rebuildGroupIdText`.
- `Keiro.Dsl.Diff.readModelPairDiff` compares the binding as
  `(group, target set, effective backing)` under the existing
  `CatalogQueryBindingChanged` code; `classifyCompatibility` is unchanged.
- `docs/adr/0026-...md` carries the binding rule after M4; `CHANGELOG.md` documents the
  language-surface amendments as candidate-window changes.
