---
id: 209
slug: define-and-validate-the-typed-projection-catalog-runtime-contract
title: "Define and validate the typed projection catalog runtime contract"
kind: exec-plan
created_at: 2026-08-07T23:36:51Z
intention: "intention_01kzf95908e14b29bxjb4yhfe0"
master_plan: "docs/masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md"
---

# Define and validate the typed projection catalog runtime contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, an application can describe a projection fleet once, validate it without
performing database effects, select a typed list of live handlers for one event source, and
render a heterogeneous inventory for registration, replay, and operations. The declaration
distinguishes a logical query model, a physical PostgreSQL target, an atomic rebuild group,
and a projection. It also distinguishes how a target is prepared from whether a handler is
safe to replay.

A developer can see the change working in `keiro-test`: a valid normalized projection
catalog yields a stable inventory and `[InlineProjection event]` without a second hand-kept
list, while mutation tests for missing owners, duplicate owners, unknown references,
cross-group writes, dependency cycles, and unsafe replay combinations return deterministic
multi-site diagnostics before an effectful callback is invoked. Existing projection and
read-model constructors continue to compile through an explicitly unmanaged compatibility
bridge.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-08T13:31:09Z) Define the public catalog vocabulary, typed per-source views,
      existential fleet view, and compatibility constructors.
- [x] (2026-08-08T13:31:09Z) Implement deterministic closed-world validation, dependency
      ordering, fingerprints, inventories, and an optional previous-baseline comparison.
- [x] (2026-08-08T13:31:09Z) Derive normal live-selection and registration inputs from only a
      `ValidatedProjectionCatalog`; add positive and mutation-tested negative cases.
- [x] (2026-08-08T13:50:33Z) Expose and document the API, create the projection-catalog ADR,
      and pass the focused and full repository checks.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-08: Mori resolved the selected event-store API to
  `mori://shinzui/kiroku/packages/kiroku-store` at local package version 0.3.1.0.
  Its source confirms that `CategoryName` is the canonical category identity and
  `RecordedEvent.globalPosition` is the only total-order cursor; the catalog
  therefore stores those facts rather than inventing stream or ordering types.
- 2026-08-08: Existing async dedup rows are physically keyed by
  `AsyncProjection.name`, while subscription and query-model registry names are
  separate runtime strings. The catalog keeps stable logical IDs for all three
  and validates their physical bridge instead of assuming the IDs are
  interchangeable.


## Decision Log

Record every decision made while working on the plan.

- Decision: Model query models, physical targets, rebuild groups, and projections as four
  separately keyed declarations.
  Rationale: Their cardinalities differ. A query can span several targets, one projection can
  own several targets, and several foreign-key-related targets must share one lifecycle fence.
  Extending `ReadModel q r` with more table fields would preserve the existing conflation.
  Date: 2026-08-07

- Decision: Provide typed source views and an existential fleet view from the same validated
  value.
  Rationale: Live inline application needs `[InlineProjection event]` and must keep the event
  type. Registration, inventory, and replay need a heterogeneous collection. This avoids both
  `Dynamic` in the live path and a second application-maintained adapter list.
  Date: 2026-08-07

- Decision: Validate only the declared closed world and compare an optional prior baseline for
  total removal.
  Rationale: Runtime code cannot discover undeclared application tables or infer writes made by
  arbitrary SQL. It can prove all relationships within a supplied catalog, and a persisted
  inventory or DSL diff can separately reveal removal of a declaration.
  Date: 2026-08-07

- Decision: Treat reset policy and replay policy as independent dimensions.
  Rationale: Clear versus preserve describes target preparation. Replayable versus live-only
  describes handler behavior. A live handler with external effects may still expose a safe
  replay adapter for its read-model writes.
  Date: 2026-08-07

- Decision: Fingerprint a dedicated canonical text inventory and exclude all
  handler closures.
  Rationale: The repository already depends on SHA-256 and base16 rendering, but
  the runtime catalog needs a stable semantic encoding rather than `Show` output
  or process-local function identity. Sorting declarations by stable ID while
  retaining explicit group and handler order makes input-list reordering neutral.
  Date: 2026-08-08

- Decision: Validate physical table, registry, subscription, and dedup names in
  addition to their typed logical IDs.
  Rationale: Distinct typed IDs prevent accidental interchange in Haskell, while
  database rows and current compatibility types still use textual names. Both
  layers must be unique and their bridge must be checked until later plans move
  lifecycle state fully onto catalog identities.
  Date: 2026-08-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The runtime now has one additive `Keiro.Projection.Catalog` facade whose validated value is
the only input to its live, registration, inventory, and replay-metadata selectors. The
focused catalog suite covers the intended valid mixed-policy fleet and deterministic
diagnostics for identity, ownership, reference, grouping, ordering, and replay-policy
mutations. It also proves that invalid validation does not invoke an effectful callback and
that baseline removals remain a separate evolution gate.

ADR 26 records the durable four-identity model, independent reset/replay policies,
typed/existential views, closed-world proof boundary, and consumer ownership of SQL and
schema. Existing `InlineProjection`, `AsyncProjection`, and `ReadModel` values remain usable
unchanged and have explicitly unmanaged wrappers for incremental adoption. No database
migration or dependency-bound change was required.

Validation evidence on 2026-08-08: nine focused catalog examples passed; public Haddock built
without exposing the `ValidatedProjectionCatalog` constructor; strict OKF validation passed
all 26 ADR concepts; and `just verify` passed, including 416 `keiro` examples, 610 DSL
examples, Jitsurei integration tests, conformance regeneration, and all migration tests.


## Context and Orientation

`keiro/src/Keiro/Projection.hs` currently defines `InlineProjection command` and
`AsyncProjection`. An inline projection has a logical name and a Hasql transaction handler;
an async projection adds a read-model name, subscription name, recorded-event handler, and
deduplication key. `runCommandWithProjections` consumes a typed list of inline projections,
which is the type-safety property this plan must retain.

`keiro/src/Keiro/ReadModel.hs` defines `ReadModel q r`. That value currently combines a typed
query, logical registry identity, one qualified table, schema/version metadata, consistency,
and a subscription name. `keiro/src/Keiro/ReadModel/Rebuild.hs` accepts one `ReadModel` and a
caller-supplied list of projection names. This plan does not change rebuild behavior; it
creates the vocabulary later plans will consume.

In this plan, a **physical target** is a stable `TargetId` and an application-owned qualified
PostgreSQL table. A **rebuild group** is a stable `RebuildGroupId` and the non-empty set of
targets that later transition under one fence. A **projection definition** owns one or more
targets and binds live and replay behavior to typed sources. A **query-model binding** connects
an existing `ReadModel q r` to one group without pretending each table is independently
queryable. A **claim site** is a stable label included in diagnostics so two conflicting
declarations can both be found. A catalog **fingerprint** is a canonical digest of identities,
versions, policies, sources, targets, and declared order; it excludes function closures and
process-local values.

The application still owns its DDL, migrations, row codecs, and SQL handler bodies. A declared
target is evidence about intent, not a static proof that an unrestricted
`Hasql.Transaction.Transaction` writes only that table. Validation rejects structural
inconsistency inside the catalog but cannot find an undeclared table or hidden SQL write.

[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires
single-catalog validation, cross-version comparison, and runtime assembly to remain distinct
gates. [ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) keeps
Keiro-owned registry migrations separate from consumer schema ownership. [ADR 20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) requires generated
conformance code to consume one runtime-owned facade. The cross-repository motivating decision
is `mori://shinzui/mori/okf/adrs/concepts/ADR-20`, which requires explicit ownership for every
live read-model table and preserve-in-place handling for incomplete brownfield history. No
local ADR currently defines these four identities, the policy split, or the arbitrary-SQL
boundary. This plan creates one through the repository's profiled ADR workflow.


## Plan of Work

### Milestone 1: Define one public declaration vocabulary

Add `keiro/src/Keiro/Projection/Catalog.hs` and expose it from `keiro/keiro.cabal`. Define
opaque, validated textual identities for projections, targets, groups, query-model bindings,
sources, subscriptions, and dedup keys. Reuse existing Keiro/Kiroku identity types where their
semantics and serialization are already exact; otherwise use distinct newtypes so identities
cannot be interchanged accidentally.

Represent physical targets independently of `ReadModel q r`. A target carries a `TargetId`,
`QualifiedTable`, `TargetResetPolicy`, and a `ClaimSite`. A non-empty rebuild-group
declaration carries its `RebuildGroupId`, target identities, explicit target dependency/order
metadata, and its claim site. A query-model binding existentially retains a `ReadModel q r`
with the group it observes, but a target does not require a fabricated `ReadModel () ()`.

Represent live and replay policies independently. `Replayable` contains an explicit recorded
event decoder/relevance function and replay apply function; `LiveOnly` contains a reason.
The decoder result is total over an input `RecordedEvent`: irrelevant, relevant decoded value,
or a structured decode failure. Prefer constructors that derive this function from an
authoritative `ValidatedEventStream` codec. Permit an explicit decoder only for a genuinely
heterogeneous source. Do not copy a codec into the catalog.

A typed `ProjectionSet event` binds a source description to typed live inline projections and
the corresponding existential definitions. Async definitions may be constructed directly from
existing `AsyncProjection` values. `SomeProjectionSet` erases only the source event type for
fleet operations. A `ProjectionCatalog` combines all declaration lists; its constructor may be
public for useful diagnostics, but effectful operations in later plans accept only
`ValidatedProjectionCatalog`.

Add a compatibility module only if it keeps the main API small. Its constructors wrap current
`InlineProjection`, `AsyncProjection`, and `ReadModel` values as explicitly unmanaged or
single-target declarations. They must not claim that legacy arbitrary lists are validated.
Milestone 1 is complete when a unit test constructs a multi-table inline projection and an
async projection, obtains a typed inline list for the former source, and renders an
existential inventory from the same declaration.

### Milestone 2: Validate the closed catalog deterministically

Put pure validation in the catalog module or
`keiro/src/Keiro/Projection/Catalog/Validate.hs`. Accumulate all independent diagnostics,
sort them by diagnostic code and stable identity, and include every conflicting claim site.
Do not fail on the first map insertion. Validation must reject:

- duplicate projection, target, group, query-model registry, subscription, and dedup identities;
- an unknown source, target, group, dependency, subscription, or query-model reference;
- a declared target with no owner, or two independent owners for one target;
- a transactional projection whose targets cross rebuild groups;
- a target/group dependency cycle or non-deterministic composed-owner order;
- a live-only projection needed to reconstruct a clear-before-replay target;
- a source/order combination for which the later runner cannot establish global order; and
- an empty group or a query-model binding whose group does not cover its declared targets.

Explicit composed ownership is one `ProjectionId` with a non-empty ordered list of handlers,
not multiple independent owners. A mixed group containing clear-before-replay and
preserve-and-reconcile targets is valid when every clear target has complete replay coverage
and preserve handlers use explicit replay adapters.

Canonicalize a valid catalog by stable identity and declared order. Produce both a machine
inventory and a fingerprint from this canonical form. A separate pure
`compareCatalogBaseline` reports a target, owner, group, or other durable identity present in a
previous inventory but absent now; it is not part of single-catalog validity. Mutation tests
must alter each otherwise-valid declaration one field at a time and assert the named diagnostic.
No test may call a database to validate this milestone.

### Milestone 3: Derive live and registration views

Add selectors whose input is `ValidatedProjectionCatalog`. A typed selector returns the
`[InlineProjection event]` for a known `ProjectionSet event`; existential selectors return
registration rows, async subscription/dedup facts, replay adapter metadata, group/target
inventory, and deterministic dry-run rendering. Keep the typed source handle returned during
catalog construction so a caller does not recover types from text or `Typeable` casts.

Add a test-only effect recorder and prove that a failed catalog validation invokes no
registration, live-assembly, or rebuild callback. Add equivalence tests showing that the
derived typed live view applies the same handlers in the same explicit order as direct legacy
construction. Later plans may extend the derived values, but they must not introduce parallel
application-owned lists.

### Milestone 4: Stabilize the public boundary and decision record

Expose the catalog module from the `keiro` package, re-export only the intended facade from
`keiro/src/Keiro.hs`, and update `docs/user/api-reference.md` or the current API reference,
`docs/user/read-models.md` or its current equivalent, and `CHANGELOG.md`. Search current docs
before choosing exact guide paths; update existing documents rather than creating aliases.

Allocate a local ADR ID with the OKF command, initialize the ADR through the repository's ADR
workflow, record the four-identity model, two-policy split, typed/existential views,
closed-world limit, and consumer-owned SQL boundary, then update the ADR log and validate it
strictly. Cite `mori://shinzui/mori/okf/adrs/concepts/ADR-20` in that ADR. The milestone is
complete when focused tests and `just verify` pass and the public Haddock does not expose a way
to fabricate a `ValidatedProjectionCatalog`.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`.

Before choosing any Kiroku codec or source constructor, refresh the registered dependency
location and read the selected version's source rather than relying on this plan's snapshot:

```console
mori registry search kiroku
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
```

The exact qualified project name returned by `mori registry search` is authoritative. Verify
the current released version against Hackage and upstream tags before changing a dependency
bound; this milestone should need no new package dependency because `keiro` already depends on
the relevant Kiroku libraries.

After each runtime milestone, format and run focused tests:

```console
nix fmt
cabal test keiro-test
```

Expected successful tail:

```text
Test suite keiro-test: PASS
```

Create and validate the ADR with the repository's current OKF profile:

```console
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Run the whole repository gate before marking the plan complete:

```console
just verify
```

Record actual diagnostic codes, migration-free test evidence, and any command deviation in
Progress and Surprises & Discoveries as implementation proceeds.


## Validation and Acceptance

Acceptance requires behavior, not only successful compilation:

1. Construct one valid catalog containing a typed source, a two-target inline projection, an
   async projection, two query-model bindings, and a mixed clear/preserve group. Validation
   returns one canonical catalog. Its typed source view yields the expected
   `[InlineProjection event]`; its inventory contains the same projection, targets, group,
   source, and policies in stable order.
2. Remove the owner but retain its target. Validation returns a missing-owner diagnostic with
   the target and declaration site. Give that target a second independent owner and observe a
   duplicate-owner diagnostic containing both claim sites.
3. Mutate each referenced identity and each uniqueness-constrained identity. Validation returns
   stable codes and all relevant sites, independent of input-list order.
4. Put two targets of one transaction in different groups, introduce a dependency cycle, or
   make a clear target depend on a live-only projection. Each invalid catalog is rejected.
   A mixed clear/preserve group with explicit safe replay adapters remains valid.
5. Compare the valid inventory to a new catalog in which the complete target declaration is
   absent. Single-catalog validation succeeds if the remaining catalog is closed, but
   `compareCatalogBaseline` reports the removal. This proves the boundary is stated honestly.
6. Supply a failing catalog to a harness whose effect callback increments a counter. The counter
   remains zero. Supply the valid catalog and observe registration and application inputs derived
   without any caller-supplied projection-name, target, subscription, or dedup list.
7. Compile an existing legacy `InlineProjection`, `AsyncProjection`, `ReadModel`, and rebuild
   caller unchanged, plus one migrated caller through the documented compatibility bridge.
8. `cabal test keiro-test`, strict ADR validation, and `just verify` pass.


## Idempotence and Recovery

This plan is additive and performs no database migration. Formatting, code generation for
documentation, tests, and catalog validation are repeatable. The canonical inventory must be
byte-stable for the same semantic declarations, regardless of input order, so re-running a
baseline export produces no diff.

If the public vocabulary proves insufficient before EP-2 begins, change it and its ADR while
only source compatibility is at risk. Once EP-2 persists group identities or EP-3 persists
fingerprints, do not rename serialized identities in place; add a versioned compatibility
decoder and migration. If a compatibility constructor makes an unsafe promise, deprecate it
and fall back to the existing unmanaged APIs rather than weakening `ValidatedProjectionCatalog`.


## Interfaces and Dependencies

`Keiro.Projection.Catalog` owns the public vocabulary. Names may be adjusted for established
Keiro conventions, but the following semantic interfaces must exist:

```haskell
data TargetResetPolicy = ClearBeforeReplay | PreserveAndReconcile
data ProjectionReplayPolicy event
  = Replayable (ReplayAdapter event)
  | LiveOnly LiveOnlyReason

data ProjectionSet event
data SomeProjectionSet = forall event. SomeProjectionSet (ProjectionSet event)
data ProjectionCatalog
data ValidatedProjectionCatalog
data CatalogDiagnostic
data CatalogInventory
data CatalogFingerprint

validateProjectionCatalog
  :: ProjectionCatalog
  -> Validation (NonEmpty CatalogDiagnostic) ValidatedProjectionCatalog

typedInlineProjections
  :: ValidatedProjectionCatalog
  -> ProjectionSet event
  -> [InlineProjection event]

catalogInventory :: ValidatedProjectionCatalog -> CatalogInventory
catalogFingerprint :: ValidatedProjectionCatalog -> CatalogFingerprint
compareCatalogBaseline :: CatalogInventory -> CatalogInventory -> [CatalogEvolution]
```

`ReplayAdapter event` must expose a total relevance/decode result and a replay-only
transaction handler. It must not imply that the live handler is replay-safe. A source
description represents Kiroku's `AllStreams` or a `Category` and stable codec/version facts;
the exact constructors must be checked against the current registered source for
`mori://shinzui/kiroku/packages/kiroku-store` with Mori.

Use existing dependencies already present in `keiro/keiro.cabal`: `containers` for stable maps
and sets, the existing hashing/encoding dependency used elsewhere in the package for canonical
fingerprints, Hasql for handler types, and `mori://shinzui/kiroku/packages/kiroku-store` for
recorded events and stream metadata. Do not add `Dynamic`, application schema migration libraries,
or reflection-based SQL inspection.

Plan 210 is the first consumer of group and target policy; plan 211 consumes replay adapters and
fingerprints; plan 212 generates these constructors; and plan 213 presents their inventory.
