---
id: 244
slug: introduce-truthful-query-freshness-runtime-apis-with-compatibility
title: "Introduce truthful query-freshness runtime APIs with compatibility"
kind: exec-plan
created_at: 2026-08-12T12:12:50Z
intention: "intention_01kzty1w82ey5vg2b86nkw83sk"
master_plan: "docs/masterplans/38-finalize-projection-ownership-and-query-freshness-before-stable-language-5.md"
---

# Introduce truthful query-freshness runtime APIs with compatibility

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Applications can describe read behavior with names that say what Keiro actually does:
run immediately, wait for a captured visible head, or wait for a caller-supplied position.
The cursor used for a wait is an explicit capability derived from the validated projection
owner/query relationship, not an always-present `subscriptionName` attached even to inline
models. Immediate reads remain valid for inline and subscription-maintained targets; a
head or position wait without one unambiguous durable cursor fails before it can poll
forever.

This is a staged public-API migration, not a silent constructor rename. Existing Haskell
source using `ConsistencyMode`, `Strong`, `Eventual`, `PositionWait`, `StrongScope`,
`defaultStrongWaitOptions`, `runQueryWith`, and direct `ReadModel` record construction
continues to compile and keeps its 0.11 semantics during the 0.12 deprecation window.
New code and all Language 5 generated code use `QueryFreshness`, `Immediate`,
`WaitForHead`, `WaitForPosition`, an explicit cursor authority, and truthfully named
builders/execution functions. Documentation states the removal window rather than
pretending the old vocabulary never existed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: pin an old/new API compatibility matrix; add honest freshness, head-scope, cursor-authority, and builder types without breaking old call sites. (2026-08-12 14:28Z)
- [x] M2a: implement truthful query execution and deterministic missing-cursor/missing-target errors; preserve old semantics through shared helpers and old/new equivalence tests. (2026-08-12 14:35Z)
- [ ] M2b: after Plan 238 completes, run the visible-tail-GC, genuinely-behind, and category-bounded `WaitForHead` integration proof without changing the preserved `storeHeadPosition` seam.
- [x] M3: add normalized freshness/cursor facts to catalog inventory, bump canonical catalog/slice/replay formats, and prove preview/adoption behavior. (2026-08-12 14:49Z)
- [ ] M4: compile-audit registered Keiro dependents through Mori, update API/reference/migration docs and changelogs, run full verification, and update MasterPlan 38.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Planning audit (2026-08-12): `ReadModel` exposes three legacy record fields whose
  cardinality is dishonest for inline/immediate models: mandatory `subscriptionName`,
  `defaultConsistency`, and always-present `strongScope`. Renaming those fields would make
  direct record construction source-incompatible. A new builder façade over the unchanged
  representation provides an honest adoption path while deferring physical record removal
  to the announced major-version boundary.
- Planning audit (2026-08-12): completed Plan 237's `InventoryQueryModel` omits current
  `defaultConsistency` and `strongScope`. Making freshness a catalog policy therefore
  changes the canonical identity contract. ADR 0032 requires explicit new prefixes; the
  change cannot reuse `catalog-v2:`/`slice-v1:` while assigning them new meaning.
- M1 (2026-08-12): preserving the positional `ReadModel` constructor means cursor
  absence cannot gain a physical field during the 0.12 window. The honest builders encode
  `NoQueryCursor` with a private NUL-prefixed sentinel, which cannot be persisted as a
  PostgreSQL text subscription name, and `readModelCursorAuthority` is the sole public
  decoder. The compile-only 0.11 fixture proves positional patterns, direct records, all
  legacy constructors, and `runQueryWith` remain source-compatible.
- M2a (2026-08-12): the truthful and legacy entry points can share schema/liveness,
  cursor polling, timeout telemetry, and SQL execution without translating new missing-
  capability states into legacy values. A 27-example `Keiro.ReadModel` run passed immediate,
  whole-head, category-head, caught-up position, behind timeout, missing cursor, and missing
  target cases. Plan 238 remains Not Started in MasterPlan 37, so the tail-GC proof remains
  an explicit M2b gate rather than being simulated here.
- M3 (2026-08-12): cursor authority must be resolved from the validated owner handlers,
  not copied from the legacy mandatory read-model field. Immediate queries therefore
  retain no cursor when ownership is absent or ambiguous, while waits produce stable
  zero-candidate or multiple-candidate catalog diagnostics before runtime. Normalizing
  set-valued owned targets at the same format boundary also removes the known declaration-
  order sensitivity.


## Decision Log

Record every decision made while working on the plan.

- Decision: Preserve the existing `ReadModel` record and legacy types for the 0.12
  deprecation window; add an honest builder/execution façade rather than renaming record
  labels in place.
  Rationale: record-label compatibility cannot be supplied by type aliases or pattern
  synonyms without materially changing construction/import behavior. The façade lets new
  code avoid every misleading term while old source remains source-compatible and
  semantically unchanged.
  Date: 2026-08-12
- Decision: Model cursor authority independently from freshness.
  Rationale: an immediate async query may still use per-call position waits, while an
  immediate inline query needs no cursor at all. Putting a cursor inside only
  `WaitForHead` would lose the first use case; making it mandatory repeats the current
  inline fiction.
  Date: 2026-08-12
- Decision: Retain `PositionWait`'s historical `target = Nothing` behavior only on the
  deprecated API; `WaitForPosition` requires a concrete target.
  Rationale: “wait for no position” is operationally immediate and adds an invalid state
  to the honest API. Old semantics cannot change silently, so the compatibility layer
  preserves them until removal.
  Date: 2026-08-12
- Decision: Add freshness and resolved cursor identity to catalog and group-slice identity,
  advancing to `catalog-v3:`, `slice-v2:`, `contract-v3:`, and
  `keiro/projection-replay/v3`.
  Rationale: freshness changes live query behavior and cursor selection. ADR 0032 mandates
  a prefix change when the canonical identity contract changes; group adoption must expose
  that drift rather than silently reinterpret old fingerprints.
  Date: 2026-08-12
- Decision: Announce 0.13 as the removal release for the legacy consistency vocabulary and
  physical waiting fields.
  Rationale: 0.12 is the first stable release but must provide a complete mechanical
  migration window. Naming the next minor release makes the deprecation finite without
  breaking direct 0.11 record and positional construction before users can adopt the
  truthful façade.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestone 1 established the compatibility boundary. `cabal build keiro-test` compiled the
old API fixture, and the focused truthful-construction run passed 6 examples covering
cursorless immediate models, cursor-retaining immediate models, missing-cursor and
missing-target rejection, honest default round-trips, and legacy no-target normalization.

Milestone 2's in-scope runtime implementation is complete: `runQueryWithFreshness` and the
legacy entry point use one validated execution path and one polling implementation, while
truthful waits reject absent cursor capability and absent position targets before polling.
The focused `Keiro.ReadModel` group passed 27 examples. The visible-tail-GC integration
proof remains pending on Plan 238, which belongs to MasterPlan 37 and is still Not Started.

Milestone 3 advanced whole-catalog, group-slice, replay-contract, and runner identities to
`catalog-v3:`, `slice-v2:`, `contract-v3:`, and `keiro/projection-replay/v3` respectively.
Canonical query facts now include normalized freshness and resolved cursor identity;
owned-target order is canonicalized. Focused catalog, preimage, operations, adoption, and
replay suites prove slice isolation, reviewed `slice-v1:` adoption, and refusal to resume
an active v2 replay under the v3 runner.


## Context and Orientation

Repository root is the `keiro` multi-package repository. `Keiro.ReadModel` in
`keiro/src/Keiro/ReadModel.hs` defines `ReadModel q r`. Besides table/query identity, the
record contains a mandatory `subscriptionName`, `defaultConsistency :: ConsistencyMode`,
and `strongScope :: StrongScope`. `runQuery` checks registry liveness/schema and delegates
to `runQueryWith`. `Eventual` executes immediately. `Strong` captures either the entire-log
or category head and polls the record's subscription cursor with fixed five-second options.
`PositionWait options` polls the same cursor when `options.target` is present and otherwise
executes immediately. `ReadModelWaitTimeout` is the existing typed timeout result.

Those operations are coherent but the names are not guarantees: `Strong` is a bounded
captured-head wait, not linearizability; `Eventual` is “do not wait,” not a claim that an
inline write is delayed. A *cursor authority* means exactly one durable subscription name
whose checkpoint represents the owner supplying every observed target. Plan 243,
`docs/plans/243-make-projection-owners-authoritative-for-catalog-bound-query-models.md`,
provides the normalized owner/query relationship and handler capabilities from which this
plan derives that authority.

`keiro/src/Keiro/Projection/Catalog.hs` defines `InventoryQueryModel`, canonical
`inventoryPreimage`, and `groupSliceFingerprint`. Completed Plan 237,
`docs/plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md`,
implemented injective preimages, slice-scoped lifecycle identity, and
`previewCatalogAdoption`/`adoptCatalogGroups`. The current formats are `catalog-v2:`,
`slice-v1:`, `contract-v2:`, and `keiro/projection-replay/v2`. No schema column needs a
new type to store later prefixed text, but existing registered groups must be previewed and
adopted, and active old-format runs cannot resume under a new contract.

Plan 238,
`docs/plans/238-target-strong-consistency-waits-at-the-visible-store-head.md`, is not yet
implemented. It changes `storeHeadPosition` from an unreachable append counter after hard
deletion to the newest visible event and aligns telemetry/ops. This plan preserves that
function seam and considers its behavior a final integration gate for `WaitForHead`.

Relevant ADRs are
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
(catalog identities and source-compatible legacy runtime values),
`docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
(cursor identity and missing-row semantics), and
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
(format prefix and adoption rules). ADR 0016 governs the later generated Language 5 use,
but this plan changes the runtime package rather than grammar. There is no relevant
cross-repository ADR.


## Plan of Work

### Milestone 1 — Honest façade and compatibility matrix

Before editing, add compile fixtures to `keiro/test/Compatibility/` (or the existing public
API compile-test location) covering old imports, positional/pattern use, direct record
construction, all legacy constructors, `defaultStrongWaitOptions`, `runQuery`, and
`runQueryWith`. Record a matrix in this plan with columns “0.11 spelling,” “0.12 behavior,”
“new spelling,” “deprecated,” and “removal release.” The old column must compile without
CPP or source edits.

In `keiro/src/Keiro/ReadModel.hs`, add:

- `QueryFreshness = Immediate | WaitForHead HeadScope | WaitForPosition PositionWaitOptions`
  for execution overrides, with the invariant that `WaitForPosition` has a concrete target;
- `HeadScope = EntireVisibleLog | CategoryVisibleHead Text`;
- `QueryCursorAuthority = NoQueryCursor | DurableQueryCursor Text`;
- `ReadModelBlueprint q r`, containing the non-waiting identity/table/query fields and
  cursor authority; and
- truthfully named builders `immediateReadModel`, `headWaitingReadModel`, and
  `positionWaitingReadModel` that return the existing `ReadModel q r` representation.

The builder functions encode valid states: head/position waiting requires
`DurableQueryCursor`; immediate construction accepts either cursor state so an async model
can later perform a caller-targeted wait. Use a private reserved cursor sentinel only as an
implementation detail for `NoQueryCursor`; reject it at the new wait boundary and never
export or render it. Generated code will use these builders, so it contains no legacy
consistency names even though the 0.12 representation remains compatible.

The compatibility contract pinned for this migration is:

| 0.11 spelling | 0.12 behavior | New spelling | Deprecated | Removal release |
|---|---|---|---|---|
| `Eventual` | Execute immediately after schema and liveness checks. | `Immediate` | Yes | 0.13 |
| `Strong` plus `EntireLog` | Capture the visible whole-store head once and wait for the model cursor. | `WaitForHead EntireVisibleLog` | Yes | 0.13 |
| `Strong` plus `CategoryHead category` | Capture that category's visible head once and wait for the model cursor. | `WaitForHead (CategoryVisibleHead category)` | Yes | 0.13 |
| `PositionWait options` with `target = Just position` | Wait for the model cursor to reach the supplied position. | `WaitForPosition options` | Yes | 0.13 |
| `PositionWait options` with `target = Nothing` | Execute immediately; this historical invalid state is retained only for compatibility. | `Immediate` | Yes | 0.13 |
| Direct `ReadModel` construction and legacy record fields | Compile and retain their 0.11 meanings. | `ReadModelBlueprint` with truthful builders and `QueryCursorAuthority` | Yes | 0.13 |
| `defaultStrongWaitOptions` | Five-second timeout and 10ms polling; the target is captured or supplied separately. | `defaultHeadWaitOptions` | Yes | 0.13 |
| `runQueryWith` | Override with the legacy mode and retain every 0.11 edge case. | `runQueryWithFreshness` | Yes | 0.13 |

Keep and deprecate, but do not alter, `ConsistencyMode(..)`, `StrongScope(..)`,
`defaultStrongWaitOptions`, the three legacy record fields, and `runQueryWith`. Haddocks
must map each old spelling to its exact operation and announced removal boundary.

### Milestone 2 — Execution and capability semantics

Add `runQueryWithFreshness` and a small internal wait interpreter. `Immediate` performs
only the existing schema/liveness checks before SQL. `WaitForHead scope` captures exactly
one head, then polls the derived cursor with the existing timeout/counter behavior.
`WaitForPosition options` requires `options.target = Just position` at construction or
conversion time and polls the same cursor. Add `ReadModelMissingCursor` (model name and
requested operation) for a new-API wait attempted on `NoQueryCursor`.

Legacy `runQuery` and `runQueryWith` retain byte-for-byte behavior: `Eventual` is immediate,
`Strong` uses the record's `strongScope` and fixed defaults, and `PositionWait` with
`Nothing` remains immediate. Implement both APIs through shared private helpers so timeout,
telemetry, schema, and liveness behavior cannot diverge. New builders translate their
default freshness into the legacy representation used by `runQuery`; equivalence tests
run each old/new pair over empty, caught-up, genuinely behind, and timeout cases.

After Plan 238 lands, rerun head-wait tests after hard-deleting the visible tail. Prove a
caught-up wait returns promptly, a genuinely behind cursor still times out, and category
scope remains category-bounded. Do not copy Plan 238's SQL into a new function.

### Milestone 3 — Catalog identity and adoption

Preserve the public `QueryModelBinding` record during the compatibility window. Normalize
its existing `ReadModel.defaultConsistency`/`strongScope` through one compatibility
conversion, then combine that freshness with Plan 243's `ResolvedQuerySupply`. New
Language 5 generated bindings use the truthful `ReadModel` builders, so the same conversion
receives the intended new policy without adding a required record field. Apply this matrix:

- `Immediate` requires no cursor and accepts inline, async, or composed owners;
- `WaitForHead` requires exactly one async subscription capability whose source can reach
  the requested entire-log/category scope;
- a per-call position wait is available only when the resolved model has exactly one
  durable cursor authority; and
- zero or several cursor candidates produce stable, fully attributed diagnostics rather
  than first-match selection.

Add freshness, head scope, and optional resolved subscription identity to
`InventoryQueryModel`, operator JSON/text, `queryPreimage`, and owning-group slice reports.
Advance canonical tags and prefixes together to `keiro/catalog-inventory/v3` /
`catalog-v3:`, `keiro/catalog-group-slice/v2` / `slice-v2:`, and replay
`contract-v3:` / `keiro/projection-replay/v3`. The canonical encoder itself remains the
Plan 237 implementation. Add pure tests for order independence and slice isolation plus DB
tests showing old `slice-v1:` rows preview as stale-format, adoption reconciles a live
group, unrelated groups remain unchanged, and old-format active runs are refused with a
documented complete-or-abandon recovery. No direct SQL remediation is exposed.

Amend ADR 0032 rather than Plan 237's completed execution record. If the new cursor/freshness
identity boundary warrants a separate durable decision, create an ADR and link both.

### Milestone 4 — Downstream adoption and closeout

Use `mori registry dependents shinzui/keiro --packages --json` to enumerate registered
downstreams. Locate each selected project with `mori registry show <qualified-project>
--full`; do not hard-code checkout paths. Compile or statically audit every use of
`ReadModel`, `ConsistencyMode`, and related constructors, recording whether it exercises
legacy compatibility or migrates to the new façade. Durable cross-repository notes use
canonical `mori://` package/project URIs.

Update `docs/user/api-reference.md`, `docs/user/read-models-and-projections.md`, package
Haddocks, examples, and `keiro/CHANGELOG.md`. Include the compatibility matrix, semantics
of immediate/head/position waits, cursor capability errors, fingerprint prefix cutover,
catalog adoption command, active-run restriction, and removal window. Run focused tests,
registered dependent compilation where supported, ADR checks, and `just verify`; record
actual results in this plan and MasterPlan 38.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
mori registry dependents shinzui/keiro --packages --json
cabal test keiro-test --test-option=--match --test-option="ReadModel"
cabal test keiro-test --test-option=--match --test-option="projection catalog"
cabal test keiro-test --test-option=--match --test-option="catalog adoption"
cabal test keiro-ops-test --test-option=--match --test-option="rebuild adopt"
just adr-validate
just verify
```

For each dependent chosen from the Mori output, run its repository-supported build command
from the path returned by `mori registry show`; record command and result here during
implementation. Expected local output is zero failed examples, old and new compatibility
fixtures both compiling, stale-format preview before adoption, successful explicit
adoption, and a final successful repository verification.


## Validation and Acceptance

Acceptance requires:

1. A new immediate inline `ReadModel` is built without a meaningful subscription cursor
   and executes without polling.
2. A new immediate async model may execute immediately and may also accept a per-call
   `WaitForPosition` using the one cursor derived from its catalog owner.
3. `WaitForHead` over an async owner captures the selected visible head, waits on exactly
   one cursor, and returns the existing typed timeout when genuinely behind.
4. A wait on an inline-only owner, or on an owner with zero/multiple compatible cursors,
   fails with a deterministic capability diagnostic/error naming query, owner, delivery
   capabilities, scope, and remedy.
5. Old `Eventual`, `Strong`, and `PositionWait` tests and compile fixtures are unchanged in
   result. In particular, legacy `PositionWait` with `target = Nothing` still runs
   immediately and old direct record construction compiles.
6. New code examples and generated-code fixtures contain none of `Eventual`, `Strong`,
   `defaultConsistency`, or `strongScope`.
7. With Plan 238 present, a caught-up head wait after tail GC returns promptly; a truly
   behind cursor still times out at the visible target.
8. Changing freshness or resolved cursor changes the whole catalog and owning group slice,
   but not unrelated group slices. Values carry the v3/v2/v3 prefixes and no old prefix is
   silently reinterpreted.
9. A live `slice-v1` group is previewed and explicitly adopted through the supported API;
   an old-format active run is refused with the documented recovery.
10. Every registered dependent use is accounted for, and the API guide gives mechanical
    migrations for constructor, override, scope, and direct-record users.


## Idempotence and Recovery

Pure/API work and test commands are repeatable. Fingerprint adoption changes only Keiro's
registration metadata and uses Plan 237's preview-then-adopt transaction; preview is
read-only, adoption is idempotent for an already-current live group, and it never mutates
application tables. Do not adopt a rebuilding or failed group. Complete or explicitly
abandon an active v2 replay before upgrading to replay format v3, then preview and adopt
the live group. A rebuild of application rows remains a separate operator decision.

During implementation, retain the legacy façade until all new tests pass. If downstream
compilation exposes an unanticipated old construction form, extend the compatibility
fixture and adapter rather than changing old constructor meaning.


## Interfaces and Dependencies

The new public surface in `Keiro.ReadModel` is equivalent to:

```haskell
data HeadScope
  = EntireVisibleLog
  | CategoryVisibleHead Text

data QueryCursorAuthority
  = NoQueryCursor
  | DurableQueryCursor Text

data QueryFreshness
  = Immediate
  | WaitForHead HeadScope
  | WaitForPosition PositionWaitOptions

data ReadModelBlueprint q r = ReadModelBlueprint
  { name :: Text
  , tableName :: Text
  , schema :: Text
  , version :: Int
  , shapeHash :: Text
  , cursorAuthority :: QueryCursorAuthority
  , query :: q -> Tx.Transaction r
  }

immediateReadModel :: ReadModelBlueprint q r -> ReadModel q r
headWaitingReadModel :: HeadScope -> ReadModelBlueprint q r -> Either ReadModelDefinitionError (ReadModel q r)
positionWaitingReadModel :: PositionWaitOptions -> ReadModelBlueprint q r -> Either ReadModelDefinitionError (ReadModel q r)
runQueryWithFreshness :: ... => Maybe KeiroMetrics -> QueryFreshness -> ReadModel q r -> q -> Eff es (Either ReadModelError r)
```

Exact builder names may be improved during implementation, but these properties are
normative: new construction uses no legacy terminology; cursor absence is representable;
wait builders reject cursor absence; a position wait has a concrete target; and the result
remains the existing `ReadModel` so registration/query consumers stay compatible.

`Keiro.Projection.Catalog` gains a normalized query freshness inventory and cursor
authority derived from Plan 243. It continues to use
`Keiro.Projection.Catalog.Preimage`; do not add another serializer. Plan 238 owns the SQL
meaning of `storeHeadPosition`. Kiroku cursor APIs must be checked through Mori if their
released signatures change; do not infer them from memory.
