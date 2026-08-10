---
id: 228
slug: qualify-the-complete-mapped-consumer-surface-before-fleet-adoption
title: "Qualify the complete mapped consumer surface before fleet adoption"
kind: exec-plan
created_at: 2026-08-09T20:45:31Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/35-make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption.md"
---

# Qualify the complete mapped consumer surface before fleet adoption

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, Keiro has one executable adoption gate proving that mapped types behave
correctly and locally across aggregate events, workqueue payloads, read-model query contracts, and
aggregate-owned projections. A representative candidate-language-5 service compiles all supported
surfaces, roundtrips persisted values, reports exact compatibility consequences, and regenerates
only the semantic consumers of a changed declaration. Adding unrelated consumers does not increase
the changed-file set for an existing mapped edit.

This is the final gate for MasterPlan 35 and the second half of the fleet-adoption gate begun by
MasterPlan 34. It performs the single reviewed candidate corpus refresh after all emitters have
settled, pins published-language stability, and publishes migration guidance for early adopters.
It does not publish packages, drain queues, rewrite downstream services, or claim SQL/category
projection coverage that the DSL cannot prove.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: extend the projection-catalog candidate fixture and its one-member workspace
  form to exercise every supported
  explicit root, derived projection consumer, legacy path, and unsupported boundary.
- [x] Milestone 2: pin exact-tree locality, wire/API/fingerprint neutrality, and constant-churn
  behavior under unrelated consumer growth.
- [x] Milestone 3: add restoring mutations for queue, query, projection, declaration, report, and
  ledger authorities and run the complete compatibility matrix.
- [x] Milestone 4: regenerate the candidate corpus once, verify published-language stability,
  publish adoption guidance, and close MP-35's fleet-adoption gate.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Exact generated locality was narrower and more role-specific than the initial reviewed guess. A
  structural queue-payload edit changes the queue, private shape, and service conformance modules,
  but not `StructuralProjections`; an opaque register mapping edit changes the aggregate transducer
  plus service conformance. The executable allowlists now pin those exact sets.
- Adding the unrelated language-5 workspace member correctly required adding its source to the
  explicit non-language-4 fixture inventory. The full suite also exposed a latent QuickCheck edge:
  `genReadModel` could create a non-catalog read model with both table and schema empty, which has no
  legal rendered grammar. Requiring non-empty generated physical names made the round-trip
  property total over its intended syntax domain.
- The restoring matrix caught all ten corruptions at their named boundaries and restored the six
  authority files byte-for-byte before its final green run.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use one integrated fixture plus focused existing suites, not a second broad example
  corpus.
  Rationale: The integrated fixture proves cross-surface composition and exact locality. Focused
  suites retain smaller failure domains for codecs, queries, projection catalogs, and legacy
  language behavior.
  Date: 2026-08-09

- Decision: Measure locality by semantic allowlists and by invariance under unrelated consumer
  growth.
  Rationale: A small diff in one fixture is insufficient. The adoption risk is amplification as
  services grow, so the same mapped edit must keep a constant affected set after adding unrelated
  aggregates, queues, read models, and projections.
  Date: 2026-08-09

- Decision: Refresh generated candidate artifacts exactly once after all restoring mutations pass.
  Rationale: Golden updates before semantic authorities settle obscure regressions and spend the
  churn this initiative is meant to prevent.
  Date: 2026-08-09

- Decision: Treat the final gate as necessary for adoption but separate from release and service
  migration.
  Rationale: Repository evidence can establish DSL stability; package publication, queue drains,
  and twenty downstream migrations require independent operational authorization.
  Date: 2026-08-09

- Decision: Extend the existing projection-catalog conformance service with queue, query,
  register, unused, and structural/opaque mappings instead of creating another corpus entry.
  Rationale: One compiled service now proves cross-surface composition, while the existing focused
  queue/read-model suites continue to isolate codec and API failures. The unrelated-growth member
  remains outside that runtime component and exists only to falsify locality amplification.
  Date: 2026-08-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Complete. The candidate projection-catalog fixture now covers an A-only event mapping, a shared
event/queue mapping, structural and opaque queue-only mappings, non-unit query input/result,
mapped snapshot state, unused declarations, aggregate-inline and catalog owners, an unsupported
category owner, and legacy scalar paths. Its single source and workspace forms produce equal
semantic snapshots; an added unrelated workspace member leaves every original mapped edit's exact
generated delta unchanged.

`MappedSurfaceQualification` selects only production `SemanticImpact`, coverage, diff, and
scaffold authority. The locality script runs the exact semantic/tree assertions, integrated
runtime conformance, and grown workspace check. The mutation script corrupts structural binding,
queue encoder/decoder/null policy, query signature, projection fingerprint, consumer attribution,
consequence rendering, service-law uniqueness, and a known ledger tag, requiring each named gate
to fail and restoring exact bytes.

The reviewed 37-entry candidate corpus was regenerated and is record/disk/Cabal consistent. The
full Cabal build and test matrix (including the 664-example DSL driver), diff and restoring suites,
ADR and improvement-request validation, formatter, Nix flake checks, and diff hygiene pass.
Languages 1–4 remain feature-gated and their generated meaning is unchanged. Adoption guidance
requires both MP-34 and MP-35 and assigns event upcasting, queue drain/transitional codec, query
caller build, projection review/rebuild, snapshot replay, and SQL migration ownership separately.

The existing ADR set already owns every durable boundary exercised here; this plan adds
qualification and operating guidance rather than a new architecture decision. The repository gate
permits a separately authorized fleet-adoption effort. It does not publish a package, migrate a
downstream service, drain a queue, rebuild a projection, or apply DDL.


## Context and Orientation

This plan hard-depends on
[Plan 227](227-extend-semantic-impact-conformance-and-evolution-reporting-to-every-mapped-surface.md),
which in turn integrates the queue, query, and projection work from Plans 224–226. It must start
only after [MasterPlan 34](../masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md)
is complete. MP-34 owns source-stable semantic locality, service-level structural conformance,
semantic-impact ledgers, and the baseline mutation machinery; this plan tests the extended model
instead of creating another one.

`keiro-dsl/test/fixtures/` holds parser/check/diff inputs. `keiro-dsl/test/conformance-*` holds
compiled generated fixtures and hand-owned consumer modules. `keiro-dsl/test/diff-test.sh` checks
old/new compatibility, while `keiro-dsl/test/structural-mutation-test.sh` demonstrates the
restoring-mutation convention: deliberately corrupt an authority, require a red gate, restore it,
and verify exact bytes. `scripts/check-conformance-corpus.sh` and the
`keiro-dsl-corpus-regen` executable own the committed generated corpus.

An **exact-tree locality allowlist** is the sorted set of paths permitted to change for one
semantic mutation. It includes the changed declaration artifact, actual consumer artifacts, one
service structural-conformance artifact, and additive report/ledger evidence. A **neutrality
oracle** is a byte or identity that must not change, such as an unrelated aggregate module, an
existing event golden, a fold fingerprint, a snapshot discriminator, a queue envelope version,
read-model SQL shape, or projection catalog fact unrelated to the mutated source.

[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires each
defect to fail at its earliest sound boundary. [ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
governs mapping authority and total bindings. [ADR 0013](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
forbids false global coverage. [ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
freezes published languages while allowing candidate correction. [ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md)
governs the compiled service gate. [ADR 0022](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
governs additive historical evidence. [ADR 0026](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
keeps projection ownership dimensions separate; its cross-repository authority is
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`.


## Plan of Work

Milestone 1 adds one candidate-language-5 fixture in `keiro-dsl/test/fixtures/` and a corresponding
compiled single/workspace conformance tree. It includes two aggregates, an A-only mapped event,
a mapped declaration shared by event and queue uses, a queue-only opaque mapping, read-model input
and result mappings, an inline projection, two catalog aggregate owners, observing read models,
and one category owner. It also includes unused declarations and legacy scalar queue/read-model
forms. The fixture must prove candidate source composition without conflating explicit roots,
derived consumers, SQL storage, or heterogeneous sources.

Register the fixture once in the corpus manifest and conformance Cabal wiring. Capture a typed
`MappedSurfaceQualification` expectation from `SemanticImpact`, `Coverage`, `DiffReport`, and
scaffold records rather than reconstructing consumer paths in the test. The single source and
workspace form must lower to equal semantic expectations and differ only in source attribution.

Milestone 2 adds an exact-tree harness, preferably a new
`keiro-dsl/test/mapped-surface-locality-test.sh` with a small checked helper rather than fragile
shell text parsing. Establish clean baselines for changes to: an A-only event mapping, a shared
event/queue mapping, a queue-only mapping, a query-input mapping, a query-result mapping, and an
unrelated declaration. For each mutation, compare the actual sorted changed path set to a reviewed
allowlist and compare neutrality oracles byte-for-byte.

Repeat those mutations after adding an unrelated aggregate, workqueue, read model, projection
owner, and workspace member. Existing allowlists may gain only the new service-level inventory
row if the new declaration itself is introduced in the same comparison; the affected artifacts
for the original mapping edit remain constant. Run the tests in both standalone and workspace
modes. Published-language-1–4 fixtures must reject the new syntax at the feature boundary and
retain all existing generated bytes.

Milestone 3 adds `keiro-dsl/test/mapped-surface-mutation-test.sh` following the repository's
restoring-mutation protocol. Mutations transpose a structural binding, remove a queue encoder and
decoder arm, alter queue required/null handling, stale a query contract import/signature, delete a
projection source/fingerprint fact, misattribute one semantic consumer, duplicate one service law,
and corrupt one known ledger tag. Each mutation must fail the named gate and restore exact bytes.
Also run legacy/no-snapshot/unknown-future-field cases and verify no mutation passes solely because
the corpus golden was updated.

Milestone 4 runs the one authorized `keiro-dsl-corpus-regen -- regenerate`, reviews the resulting
candidate-only tree, then runs the full build/test/format/check matrix. Update `docs/user/` language,
queue, read-model, projection, evolution, and adoption guidance; update the changelog if the project
uses one for candidate work. The guidance must separate event upcasting, queue draining or
transitional codecs, query caller recompilation, projection handler/rebuild review, and SQL
migration ownership. Record MP-35 complete only when this plan is green; MP-34 remains a distinct
prerequisite rather than being retrospectively widened.


## Concrete Steps

Work from the repository root and refresh the registered project/downstream inventory:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori registry show shinzui/keiro --full
mori registry dependents shinzui/keiro --packages --json
rg -n 'MappedSurface|SemanticImpact|CoverageSurface|QueryContract|ProjectionMappedConsumer' \
  keiro-dsl/src keiro-dsl/test docs/user
```

Run the focused integrated and restoring gates before changing goldens:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='mapped surface qualification'
cabal test keiro-dsl:keiro-dsl-conformance-mapped-surfaces
bash keiro-dsl/test/diff-test.sh
bash keiro-dsl/test/structural-mutation-test.sh
bash keiro-dsl/test/mapped-surface-locality-test.sh
bash keiro-dsl/test/mapped-surface-mutation-test.sh
cabal run -v0 keiro-dsl-corpus-regen -- check
```

Expected output names distinct event-history, queued-job, query-API, projection-rebuild, and
snapshot consequences. Every mutation script reports its intended failure and a clean restoration;
the pre-refresh corpus check reports only the reviewed candidate drift.

After reviewing that drift, perform the single corpus refresh and final gate:

```bash
cabal run -v0 keiro-dsl-corpus-regen -- regenerate
cabal run -v0 keiro-dsl-corpus-regen -- check
scripts/check-conformance-corpus.sh
cabal build all
cabal test all
just adr-validate
mori improvement-requests validate --path /Users/shinzui/Keikaku/bokuno/keiro
nix fmt
nix flake check
git diff --check
git status --short
```

Expected final output has a clean corpus check, passing repository tests and mutations, valid ADRs
and improvement requests, and a diff limited to intentional implementation, candidate fixtures,
generated candidate outputs, and documentation.


## Validation and Acceptance

A mapped declaration used by Aggregate A's event names A, A's inline/catalog projections, their
actual groups/targets/read-model observers, and service structural conformance. It does not name
Aggregate B. A queue-only declaration names exactly that queue and queued-job history; a
query-only declaration names exact input/result positions and caller/build impact. A shared
declaration returns the union once, and an unused declaration returns only declaration-wide
service evidence.

Changing each surface produces the correct compatibility dimension. Event mappings retain event
history/replay rules. Queue mappings retain queue schema version 1 and require drain or a declared
transitional codec for incompatible queued jobs. Query mappings require caller/consumer builds but
do not alter SQL shape, catalog fingerprint, or replay. Derived projections add handler review and
only replayable aggregate owners add rebuild-source impact. Category/all owners remain visibly
unsupported and never receive fake structural evidence.

The single/workspace fixture compiles and exercises structural and opaque queue roundtrips, missing
versus null payload behavior, non-`()` query values, aggregate replay, projection owner source
agreement, and exact service conformance evidence. Languages 1–4 reject the candidate syntax and
their committed generated trees remain byte-identical. Existing aggregate event bytes remain
identical after shared codec-plan extraction.

For every mapped edit, the exact-tree allowlist is unchanged after unrelated consumer growth.
Unrelated Haskell modules, wire goldens, fold fingerprints, snapshot discriminators, behavior keys,
queue envelopes, SQL shape hashes, and projection facts remain identical. Every restoring mutation
goes red for the intended reason and restores the tree exactly.

The final corpus check, full Cabal build/tests, restoring scripts, ADR/improvement-request
validation, formatter, Nix flake check, and diff hygiene pass. Adoption documentation states that
both MP-34 and MP-35 must be complete before fleet rollout; no release or downstream mutation is
performed by this plan.


## Idempotence and Recovery

All semantic expectations, locality comparisons, and conformance projections are deterministic.
Mutation scripts install restoration traps and verify the restored digest before exit. Run them
before corpus regeneration so a faulty generator cannot be legitimized by changed goldens.

`keiro-dsl-corpus-regen -- regenerate` is intentional but repeatable: review its diff, and rerun it
only from a clean, validated implementation state. If it fails partway, rerun the generator and
compare against the manifest; do not hand-edit generated output to make the check green. Preserve
application-owned holes and bindings. No command in this plan publishes a package, modifies a
downstream repository, drains a queue, or applies a database migration.


## Interfaces and Dependencies

No new package dependency or version bound is expected. Reuse the completed MP-34/MP-35 semantic
types, existing Aeson/containers support, corpus driver, and service conformance package. The test
expectation should consume production identities and be equivalent to:

```haskell
data MappedSurfaceQualification = MappedSurfaceQualification
  { declaration :: !MappedKey
  , explicitRoots :: !(Set MappedRoot)
  , derivedConsumers :: !(Set ProjectionMappedConsumer)
  , consequences :: !(Set MappedConsequence)
  , generatedPaths :: !(Set FilePath)
  , neutralityOracles :: !(Map NeutralityKey Digest)
  }

qualifyMappedSurface
  :: CheckedService
  -> SemanticImpact
  -> MappedKey
  -> Either QualificationError MappedSurfaceQualification
```

This is a test-facing projection, not a second dependency calculator. `qualifyMappedSurface` must
select from `SemanticImpact`, checked generation plans, and typed consequence records; it may not
walk raw `Spec`, parse reports, or infer meaning from filenames. New records use unprefixed semantic
fields. If a label is duplicated, use type-directed patterns/record-dot access; the field labels do
not enter DSL syntax, wire identities, fingerprints, reports, or ledgers.
