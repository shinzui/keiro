---
id: 212
slug: generate-projection-catalogs-from-keiro-dsl-and-classify-their-evolution
title: "Generate projection catalogs from keiro-dsl and classify their evolution"
kind: exec-plan
created_at: 2026-08-07T23:36:52Z
intention: "intention_01kzf95908e14b29bxjb4yhfe0"
master_plan: "docs/masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md"
---

# Generate projection catalogs from keiro-dsl and classify their evolution

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, a checked `language keiro-dsl 5` service can declare physical projection
targets, rebuild groups, projection ownership, typed or heterogeneous event sources, reset and
replay policies, and query-model bindings. `keiro-dsl` generates the same runtime
`ValidatedProjectionCatalog` contract proven by plans 209–211, plus typed source views and
create-once handler holes. It does not generate application migrations or SQL bodies.

The compiler also treats the catalog as an evolution surface. `keiro-dsl diff`, replay-impact,
workspace records, and scaffold-ledger facts report target removal or relocation, ownership,
group, order, source, reset-policy, and replay-policy changes with conservative compatibility
vectors. A conformance service compiles the generated catalog and executes a fixed-head rebuild;
language versions 1–4 retain their released parse and runtime meaning.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Register the candidate language-5 projection-catalog syntax and semantic graph while preserving the
      immutable language-1–4 registry entries and parser behavior.
- [x] Validate catalog declarations and lower them into the runtime facade, typed source views,
      deterministic generated modules, and create-once behavior holes.
- [x] Extend diff, replay-impact, workspace records, and scaffold-ledger facts with every catalog
      evolution dimension and mutation-test their gates.
- [x] Add compiled/runtime conformance, upgrade documentation and corpus evidence, then pass all
      DSL and repository verification.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-08: Implementation started after plans 209–211 completed and the final runtime
  constructors, replay contract, and full repository gate were verified.
- 2026-08-08: The released-frontend corpus used unreleased version 5 as an unsupported-version
  sentinel. Treating that sentinel as an immutable contract and renumbering it to 6 was incorrect:
  version 5 has not shipped. The sentinel is being retired, candidate 5 is corrected in place, and
  the language ADR now distinguishes registration from external release.
- 2026-08-08: A workspace parity test exposed a second form of the same churn: rebuilding a
  language-4 merged graph through the active-authoring helper changed only generated banners.
  Workspace scaffolding and its parity test now retain the workspace's checked language contract.
- 2026-08-08: The existing runtime `ProjectionSet event` is intentionally typed to one source.
  Accepting several DSL `source` clauses under one owner would erase that type or require an
  application-maintained union, so validation requires one typed source and tells authors to
  split independent sources into separately ordered owners.
- 2026-08-08: Marking candidate 5 as `Stable` demoted published language 4 and caused the corpus
  driver to rewrite every language-4 ledger. The registry now represents v4 as published stable,
  v5 as candidate, and exposes separate stable and development-authoring selectors.
- 2026-08-08: Historical skeleton fixtures were replayed through the current `new` default, so an
  authoring-version change rewrote their sources and generated banners. The corpus manifest now
  declares that published-language-4 suite as frozen: it remains compiled and checked against
  disk, ledger, and Cabal inventory, but is never regenerated through a newer default.


## Decision Log

Record every decision made while working on the plan.

- Decision: Introduce catalog declarations only in `language keiro-dsl 5`.
  Rationale: Adding syntax and generated runtime meaning to released language 4 would make the
  same preamble mean different things across compiler versions. The language registry is
  append-only, so a new syntax profile is the honest compatibility boundary.
  Date: 2026-08-07

- Decision: Keep version 5 as the sole pre-release candidate and do not invent version 6.
  Rationale: No package has released language 5 and no external consumer has used it. Unsupported
  version fixtures are parser-boundary test data, not compatibility contracts; when their number
  becomes active they are retired or repurposed. Existing language-4 generated corpora remain
  version-4 evidence, while a focused version-5 lane proves the new catalog surface.
  Date: 2026-08-08

- Decision: Separate the published stable selector from the development authoring selector.
  Rationale: Release status and the version emitted by development skeletons are different facts.
  `currentStableLanguageVersion` remains 4; `currentAuthoringLanguageVersion` selects candidate 5
  while it is active. This prevents candidate work from demoting or rewriting the published v4
  contract.
  Date: 2026-08-08

- Decision: Freeze historical starter corpora explicitly instead of replaying them through `new`.
  Rationale: `new` intentionally follows the active authoring candidate, whereas a committed v4
  starter corpus is compatibility evidence. Verification still compiles and inventories the
  frozen files and checks their tracked history without mechanically upgrading them.
  Date: 2026-08-08

- Decision: Generate one context-level projection-catalog facade.
  Rationale: Group validation and fleet inventory require the whole checked service, and
  repository ADR 20 requires conformance packages to import one runtime-owned facade instead of
  reconstructing inventories from per-node modules.
  Date: 2026-08-07

- Decision: Keep SQL, query bodies, and live/replay handler bodies in create-once hole modules.
  Rationale: The DSL owns structural declarations and generated wiring but cannot safely infer
  application behavior or migrations. Regeneration must never overwrite a reviewed handler.
  Date: 2026-08-07

- Decision: Use runtime validation as a generated fail-closed assertion, not as a substitute for
  DSL validation.
  Rationale: Source locations and cross-version facts are richest in the DSL graph, so invalid
  checked specs must fail there. Calling the runtime validator in generated assembly guards
  compiler/runtime drift and proves both layers agree.
  Date: 2026-08-07

- Decision: Put target dependencies on physical target declarations and sort generated owners by
  their checked numeric handler order.
  Rationale: A dependency constrains preparation of that physical target, while the group owns the
  closed membership and total preparation order. Sorting at generation time makes typed live views,
  fleet inventory, and replay-adapter order agree even when source declarations are rearranged.
  Date: 2026-08-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Candidate language 5 now owns the typed projection-catalog grammar, validation, generated runtime
facade, create-once application boundaries, catalog evolution findings, replay-impact facts, and
workspace/scaffold history. The compiled conformance service proves inline multi-target, async,
clear, preserve, aggregate-codec, category-decoder, and group-scoped rebuild paths against the
runtime delivered by plans 209–211.

Language 5 was amended in place and remains explicitly unreleased. Language 4 remains the
published stable contract, while a separate authoring selector lets new development skeletons use
candidate 5 without mislabelling it stable. Full corpus regeneration changed only the dedicated
v5 ledger from `stable` to `candidate`; all active language-4 suites were byte-stable, and the
historical v4 starter corpus is now explicitly frozen against future authoring-default churn.

Verification completed with 615 `keiro-dsl-test` examples, the compiled
`keiro-dsl-conformance-projection-catalog` suite, full corpus record/disk/Cabal consistency, ADR
validation, formatter, and `git diff --check` green. Application DDL and SQL/query/handler bodies
remain deliberately consumer-owned.


## Context and Orientation

This plan hard-depends on [plan 209](209-define-and-validate-the-typed-projection-catalog-runtime-contract.md)
and [plan 211](211-replay-catalogued-projections-deterministically-and-resumably.md). Generated
types and constructors must consume those final public APIs. Do not create DSL-only catalog or
replay records that applications must translate by hand.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` currently defines `ReadModelNode` with one schema/table,
columns, version/shape, consistency/scope, feed, and optional subscription. It also defines an
aggregate-local `ProjectionSpec`, which describes a structural projection table/status map but is
not a fleet ownership declaration. Preserve that distinct aggregate feature; use unambiguous new
top-level node names in the grammar and AST.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` currently generates a `ReadModel`, registration function,
one-table start/finish/abandon helpers, an optional `AsyncProjection`, and a hand-owned query/apply
hole module. The start helper emits `[]` for inline read models or a manually assembled singleton
projection-name list for subscriptions. This is exactly the list drift the generated catalog must
remove.

Before this plan, `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` had an append-only registry whose
published authoring default was 4. Versions 1–4 use immutable syntax/runtime profiles.
`Keiro.Dsl.Validate`, `PrettyPrint`,
`Diff`, `ReplayImpact`, `WorkspaceRecord`, `ScaffoldLedger`, and conformance packages form the
compiler pipeline that must all learn the new nodes. A syntax-only parser change is incomplete.

In this plan, a **language-5 catalog declaration** is a checked graph composed of top-level
physical-target, rebuild-group, and projection-owner nodes plus group bindings on read models.
The exact source spelling established in Milestone 1 is normative and must round-trip. The shape
must support this representative intent without embedding Haskell bodies:

```text
target order_summary {
  schema = "sales"
  table = "order_summary"
  reset = clear
}

rebuild-group order_reporting {
  targets = [order_summary]
  order = [order_summary]
}

projection order_summary_writer {
  source = aggregate Order
  feed = inline
  group = order_reporting
  targets = [order_summary]
  replay = explicit
}
```

`replay = explicit` creates a replay-only hole distinct from the live apply hole. A live-only
form includes a required reason. A heterogeneous category source generates a total
relevant/decoded/failed hole; an aggregate source reuses the generated `ValidatedEventStream`
codec. The concrete keywords may change once parser ambiguity tests are written, but the four
separate node identities and no-body rule may not.

[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires
single-spec validation, cross-version diff, and runtime assembly as independent gates.
[ADR 20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) requires one
runtime-owned facade. [ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md)
forbids generated application DDL. The catalog ADR from plan 209 governs the generated runtime
meaning. The motivating cross-repository record is
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`.


## Plan of Work

### Milestone 1: Register and check the candidate language-5 graph

Append version 5 to `Keiro.Dsl.LanguageVersion`; never edit the definitions for versions 1–4.
Add a named syntax feature such as `ProjectionCatalogSyntax`, a monotone syntax profile derived
from language 4, and only the runtime capability needed to fingerprint catalog semantics. Make 5
the candidate authoring default for new skeletons while retaining language 4 as the published
stable contract and versions 1–3 as compatibility-only.
Extend language registry JSON/round-trip and unsupported-version tests.

Add separate AST nodes in `Keiro.Dsl.Grammar` for physical targets, rebuild groups, and projection
owners, and evolve `ReadModelNode` through a version-aware representation that can preserve the
legacy one-table form. The language-5 read-model form binds to a group and may declare which of
the group's targets its query observes; it does not repeat schema/table authority. A physical
target owns stable ID, qualified location, and reset policy. A group owns non-empty targets and
their deterministic preparation/dependency order. A projection owner declares stable ID, one or
more source references, feed mode, group, non-empty targets, explicit handler/component order,
subscription/dedup facts for async feed, and replay policy.

Extend both body parser and pretty printer so every new declaration round-trips with locations.
The parser must reject new keywords under language 1–4 with a feature-gate diagnostic, not parse
them and fail later. Legacy sources retain byte-for-byte semantic records. Decide and document
defaults narrowly: language 5 requires `reset`, `group`, `targets`, `feed`, and `replay`; do not
guess destructive clear or replay safety.

Extend `Keiro.Dsl.Validate` to perform local reference/type checks and the same closed-world rules
as runtime validation while retaining DSL source spans. Reuse or map stable runtime diagnostic
codes where practical. Check ownership, duplicate IDs, non-empty groups, group membership,
composed handler order, source resolution, all/category overlap, feed/subscription/dedup coherence,
cycles, cross-group writes, and clear-target/live-only incompatibility. A checked service must be
capable of runtime catalog validation by construction.

Milestone 1 passes when language-5 positive/negative fixtures round-trip and mutation tests prove
every new diagnostic live, while the entire language-1–4 frontend compatibility suite remains
unchanged.

### Milestone 2: Generate the runtime facade and behavior holes

Extend `Keiro.Dsl.Scaffold` to generate deterministic target, group, projection, and source
declarations using the plan-209 API. Generate one context/service-level module, for example
`Generated.<Context>.ProjectionCatalog`, that imports per-node modules, constructs
`ProjectionCatalog`, validates it once, exports `ValidatedProjectionCatalog`, typed source handles,
and catalog-derived registration/rebuild/inventory functions. If runtime validation somehow
fails, initialization must return or raise a structured compiler/runtime invariant error before
any registration effect.

Replace generated one-table `start...Rebuild`/`finish...Rebuild` helpers and projection-name lists
with group-scoped calls from plan 211. A read-model module continues to expose its typed query
contract and qualified targets it legitimately needs, but registration derives from the service
catalog. Typed inline source views feed current command harness assembly; async workers use their
catalog entry rather than a second `AsyncProjection` list.

Generate only declarations and adapters. For an aggregate source, reuse its generated
`ValidatedEventStream` codec and typed event union. For a heterogeneous category source, create a
hand-owned hole with a total decoder/relevance signature. Generate distinct live and replay apply
holes whenever replay is explicit, so external effects can be suppressed during rebuild. For
live-only, generate only live behavior and preserve the checked reason in inventory. Query and
verification hooks remain hand-owned. Extend the scaffold ledger so these holes are create-once,
renames/moves are surfaced, and regeneration never overwrites them.

Add a new language-5 conformance package with an inline multi-target projection, an async
projection, a preserved target, and at least two sources. Compile the generated facade against
`keiro` and run a small catalog validation/rebuild assertion. Regenerate checked corpus files only
through the repository command, review all diffs, and keep language-4 golden output stable unless
the existing generator contract intentionally changes for all versions.

### Milestone 3: Classify catalog evolution

Extend `Keiro.Dsl.Diff` with explicit diagnostic codes and renderers for target added/removed,
qualified-location change, reset-policy change, owner change/removal, group membership/identity,
dependency/handler order, source selection/codec identity, feed/subscription/dedup identity, replay
policy, and query-model group binding. Do not collapse them into the current generic
`ProjectionChanged` advisory.

Assign compatibility vectors by affected surface. Removing or re-keying a durable target, group,
subscription, or dedup identity breaks persisted identity. Source/codec or replay-policy changes
can break private history read and require a fresh rebuild. Owner/order changes are at least
consumer-build advisory and rebuild-impacting; a clear-to-preserve change is operationally safer
but still requires review, while preserve-to-clear is breaking for retained data unless migration
evidence authorizes it. Adding a target is structurally additive but cannot transfer migration
ownership; the report must state that consumer DDL is required.

Extend `Keiro.Dsl.ReplayImpact` so affected groups, targets, sources, adapters, and whether a
running fingerprint becomes invalid are machine-readable. Extend `WorkspaceRecord` and
scaffold-ledger facts with the stable catalog identities and source locations so a whole target
declaration removed from the new graph is still compared to the prior record. Update JSON schemas,
goldens, CLI text/JSON output, and the existing compatibility gate mapping.

Mutation tests must delete each emitted change, reverse a handler order, change one source, and
remove an entire target declaration; the relevant diff/replay-impact finding must disappear so the
test proves the guard is live. Milestone 3 passes when diff results are invariant to unrelated
declaration ordering and workspace diff agrees with single-context diff.

### Milestone 4: Document and prove the candidate surface

Update the language reference, authoring guide, evolution/replayability guide, API reference,
scaffold ownership guide, and changelog. Add an upgrade example from a language-4 singleton
readmodel to explicit language-5 target/group/projection declarations. State that changing only
the preamble does not invent ownership: the upgrade tool or author must add the required nodes.

Document generated versus hand-owned files and show how a replay-specific adapter suppresses a
live side effect. State that target declarations do not create tables or prove arbitrary SQL
writes. Amend the catalog ADR only if language implementation changes the durable runtime
contract. Run every DSL suite, compiled conformance suite, corpus policy, and `just verify`.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Inspect the final runtime constructors before
editing the grammar:

```console
sed -n '1,320p' keiro/src/Keiro/Projection/Catalog.hs
sed -n '1,320p' keiro/src/Keiro/ReadModel/Rebuild.hs
sed -n '1,280p' keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs
```

After parser/validator/diff edits, format and run focused DSL tests plus all DSL suites:

```console
nix fmt
cabal test keiro-dsl-test
cabal test keiro-dsl:tests
```

Expected successful tail includes:

```text
Test suite keiro-dsl-test: PASS
Test suite keiro-dsl-conformance-projection-catalog: PASS
```

Add the new conformance suite to `keiro-dsl/keiro-dsl.cabal` under a stable component name; use
that final name in this plan and in `Justfile`. Regenerate the corpus through the supported command
only:

```console
just corpus-regen
scripts/check-conformance-corpus.sh
```

Review the generated diff and run full verification:

```console
git diff --check
just verify
```

If implementation needs a runtime or dependency API not yet understood, use `mori registry
search`, `mori registry show --full`, and on-disk source before changing code. Verify release tags
and registry versions before changing bounds.


## Validation and Acceptance

Acceptance requires all of these observations:

1. A representative language-5 service declares two physical targets in one group, one inline
   multi-target owner, one async owner, clear and preserve policies, aggregate and category
   sources, and explicit replay behavior. Parse/pretty/parse is semantically identical and keeps
   diagnostic locations.
2. The same new syntax under language 4 returns a version-feature diagnostic. Existing language
   1–4 fixtures retain their parsed semantics and conformance output; candidate version 5 is the
   only authoring default for newly generated skeletons.
3. Missing/duplicate owner, unknown target/group/source, cycle, cross-group transaction,
   `$all`/category overlap, async identity mismatch, unordered composition, and
   clear-target/live-only combinations fail DSL validation at the claim sites. No Haskell is
   generated for an invalid checked service.
4. Generated code imports the public plan-209/211 facade, validates one catalog, exposes typed
   inline views, registers async/query facts, and starts a group rebuild without generated
   projection-name or table lists. The conformance package compiles and executes that path.
5. Regeneration leaves hand-owned query, live apply, replay apply, heterogeneous decoder, and
   verification holes unchanged. Deleting a hole produces the documented create-once scaffold;
   changing its body and regenerating preserves the edit.
6. Diff independently reports every catalog dimension. Removing the whole target declaration is
   found from the prior record; moving a table is not described as DDL performed by Keiro;
   changing a source or replay policy marks the affected group in replay-impact and invalidates
   resume fingerprints.
7. JSON/text output, workspace output, and scaffold-ledger facts agree on stable IDs and source
   spans. Mutation tests prove the new diagnostic and change codes are executed.
8. `cabal test keiro-dsl:tests`, conformance corpus policy, strict ADR validation if amended, and
   `just verify` pass.


## Idempotence and Recovery

Parser, validation, diff, and code generation are deterministic and safe to rerun. Generated files
may be replaced only through the scaffold/corpus workflow. Hole files are create-once and must be
preserved byte-for-byte after creation. If generation fails, fix the checked graph and rerun; do
not hand-edit generated catalog modules.

Language registry entries are immutable after release. Before release, a flawed language-5
profile may be corrected with its fixtures and decision log. After release, preserve version 5
and add a later language version for incompatible syntax or runtime meaning. A failed corpus
regeneration can be retried; review and retain unrelated hand-owned user changes.

An unsupported-version sentinel is not a released registry entry. If its number becomes the
active candidate, remove or repurpose that sentinel; never advance it to the next consecutive
number merely to keep the same test green.

If generated runtime validation exposes a compiler bug, initialization must stop before effects.
Correct the DSL validator/generator and regenerate. Do not catch the invariant failure and proceed
with a partial catalog.


## Interfaces and Dependencies

`Keiro.Dsl.LanguageVersion` adds version 5 and `ProjectionCatalogSyntax` while retaining immutable
versions 1–4. `Keiro.Dsl.Grammar` adds semantically separate nodes equivalent to:

```haskell
data ProjectionTargetNode
data RebuildGroupNode
data ProjectionOwnerNode
data ProjectionSourceNode
data ResetPolicyNode = ResetClear | ResetPreserve
data ReplayPolicyNode = ReplayExplicit | ReplayLiveOnly Text
```

`ReadModelNode` must represent a language-5 group binding without requiring a physical table to be
the query-model identity. If separate legacy/new constructors avoid partial fields, prefer them to
a record full of `Maybe` values. `Keiro.Dsl.Validate` owns source-located graph validation;
`Keiro.Dsl.Scaffold` lowers only a checked graph.

The generated facade imports `Keiro.Projection.Catalog` and
`Keiro.ReadModel.Rebuild`. It exports one `ValidatedProjectionCatalog`, typed `ProjectionSet`
handles, and catalog-backed runtime assembly. Generated conformance code imports this facade in
accordance with repository ADR 20.

`Keiro.Dsl.Diff`, `Keiro.Dsl.ReplayImpact`, `Keiro.Dsl.WorkspaceRecord`, and the scaffold ledger
share stable diagnostic/change codes rather than recomputing string heuristics. Keep the existing
six compatibility surfaces—private history read, old-binary/new-event read, snapshot hydration,
public consumer, persisted identity, and consumer build—and assign each new code explicitly.
No application migration generator or SQL parser is added.
