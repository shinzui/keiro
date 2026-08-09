---
id: 217
slug: define-one-checked-semantic-impact-model-for-keiro-dsl-consumers
title: "Define one checked semantic-impact model for Keiro DSL consumers"
kind: exec-plan
created_at: 2026-08-09T19:29:29Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md"
---

# Define one checked semantic-impact model for Keiro DSL consumers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, Keiro has one checked answer to “which aggregates can semantically consume this
mapped declaration?” Aggregate harness generation, service conformance, `diff`, and scaffold
reporting can consume that answer instead of maintaining independent filters. A focused unit test
can add a mapped optional field and show Aggregate A in the closure while Aggregate B remains
absent; adding a future mapped root constructor cannot compile until the consumer mapping handles
it.

This plan changes no generated Haskell bytes. It establishes the maintainable semantic authority
required by the later generator and reporting plans, and it corrects IR-21 so implementation is
judged against evidence the current language actually represents.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-09 21:37Z) Milestone 1: revised IR-21 to distinguish declaration-owned evidence
  from aggregate-use evidence and to state the current command/event/register root boundary
  honestly.
- [x] (2026-08-09 21:43Z) Milestone 2: added the checked `Keiro.Dsl.SemanticImpact` model and
  deterministic projections.
- [x] (2026-08-09 21:43Z) Milestone 3: proved direct, nested, shared, unused, deterministic-order,
  and future-root behavior with four focused tests.
- [ ] Milestone 4: audited existing mapped-closure consumers and amended ADR 0012; remaining work
  is to pass the complete package, documentation, ADR, and corpus gates without changing generated
  output.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `Keiro.Dsl.Grammar` already exports an expression-path constructor named `RegisterRoot`, so the
  initially planned root-kind spelling made an unqualified import ambiguous. The focused build
  failed at `test/Main.hs` before any test ran. The impact API now prefixes every root-kind
  constructor with `Mapped` to keep unqualified public imports usable.
- The repository's current ADR recipe is `just adr-validate`, not the stale `just check-adr`
  command copied into this plan. Whole-project improvement-request validation also reports twelve
  pre-existing `status: implemented` values that the current profile rejects; IR-21 itself passes
  strict profile validation in isolation, and none of the twelve diagnostics names it.
- `scripts/check-conformance-corpus.sh` refuses any untracked file beneath
  `keiro-dsl/test/fixtures` before scaffolding. Its first run stopped on the new
  `semantic-impact.keiro` fixture without touching the generated corpus. The fixture must be
  committed as a working checkpoint before the byte-clean corpus gate can run.


## Decision Log

Record every decision made while working on the plan.

- Decision: Derive semantic impact only from a resolved `TypeGraph`, never directly from raw
  `Spec` fields in a generator or report renderer.
  Rationale: `TypeGraph` is the checked authority for declaration identity, transitive references,
  and complete use sites. Reconstructing closure downstream recreates the drift this initiative is
  meant to remove.
  Date: 2026-08-09

- Decision: Keep service-wide declaration inventory separate from aggregate consumer closure.
  Rationale: Every declaration needs conformance even when no aggregate currently uses it, but
  treating service conformance as an aggregate consumer would make all aggregate impacts global.
  Date: 2026-08-09

- Decision: Model only command-field, private-event-field, and register roots in this plan.
  Rationale: Those are the only mapped `TypeExpr` roots represented by the checked graph. Snapshot
  impact follows register use; queue, public contract, read-model, and projection roots require
  future language work rather than guessed edges.
  Date: 2026-08-09

- Decision: Name the public root-kind constructors `MappedCommandFieldRoot`,
  `MappedEventFieldRoot`, and `MappedRegisterRoot`.
  Rationale: `Keiro.Dsl.Grammar.RegisterRoot` already identifies an expression path root. Prefixing
  the complete new vocabulary avoids ambiguous unqualified imports and makes its mapped-type scope
  explicit.
  Date: 2026-08-09

- Decision: EP-2 will migrate aggregate harness inventory, aggregate projection selection, and
  `codecMappedDeclarations` to `SemanticImpact`; EP-5 will use the same model for scaffold and diff
  impact reporting. `MappedDiff`, `Coverage`, and `ExplainBindings` retain `usePaths` because they
  require field/arm path detail and compatibility or evidence classifications rather than only a
  consumer closure. `MappedConsumer.consumerPlan`, validation, fingerprints, and golden synthesis
  retain direct declaration lookup because they consume the service inventory or one resolved
  declaration, not aggregate impact.
  Rationale: The source audit found only `Harness.hs` and `Scaffold.hs` reconstructing aggregate or
  globally amplified generation selection. Replacing path-sensitive compatibility logic with a
  set closure would discard information, while wrapping ordinary checked lookups would add no
  semantic authority.
  Date: 2026-08-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` is the checked mapped-type boundary. `resolveTypeGraph`
validates structural and opaque declarations, produces `tgDeclarations`, computes transitive
`tgReachability`, and records complete root uses in `tgUseSites`. `UseSite` currently has exactly
three constructors: `RootCommandField aggregate command field key`, `RootEventField aggregate
event field key`, and `RootRegister aggregate register key`. `usePaths` already expands a changed
declaration back through those roots for mapped diff findings.

A **mapped declaration closure** is a root declaration plus every mapped declaration reachable
through nested record, optional, list, map, or union references. An **aggregate consumer closure**
is the union of those declaration closures for every root owned by one aggregate. The
**service inventory** is every checked declaration, including an intentionally unused declaration,
because declaration validity and conformance do not depend on current use.

The defect is downstream. `keiro-dsl/src/Keiro/Dsl/Harness.hs` implements
`mappedHarnessDeclarationsResolved` as every value in `tgDeclarations` and
`mappedProjectionSpecs` as every `projectionSpecs` row. Consequently every aggregate harness
imports and asserts the service-wide structural inventory. In contrast,
`codecMappedDeclarations` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` already selects the transitive
closure of that aggregate's event fields. `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs` already uses
`UsePath`; later plans must preserve its compatibility classifications rather than replacing them
with generated-file heuristics.

[IR-21](../improvement-requests/make-workspace-scaffolding-semantically-local-and-source-stable.md)
currently asks for queue payloads, projections, and read models that do not carry mapped roots, and
asks deletion of aggregate-specific binding evidence even though binding/fixture symbols live on
the declaration. Milestone 1 corrects those statements and records the technical review outcome
as changes requested before implementation.

[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires one resolved graph, exhaustive folds, and declaration-wide total binding/fixture laws.
[ADR 0013](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
requires unsupported surfaces to remain explicitly unsupported rather than entering a misleading
coverage denominator. [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires checked, append-only diagnostics at the earliest boundary. No cross-repository ADR
governs this internal model; the Mori reproducer is acceptance evidence only.


## Plan of Work

Milestone 1 aligns the request with the architecture. Amend IR-21's requested-change, acceptance,
and deliverables sections so declaration-wide binding, canonical identity, fixture-label, and
branch-coverage laws run once at service scope. Aggregate harness acceptance instead requires only
use-specific evidence for each aggregate closure. State that the current root set is command
fields, private-event fields, and registers, with snapshots following registers. Add a dated
technical review recording the earlier acceptance defects; do not erase the originating Mori
evidence. Keep the request proposed until EP-6 supplies final evidence.

Milestone 2 adds `keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs` and exposes it from
`keiro-dsl/keiro-dsl.cabal`. Define typed `MappedConsumer`, `MappedRootKind`, `MappedRoot`, and
`SemanticImpact` values. `semanticImpact :: TypeGraph -> SemanticImpact` must group each `UseSite`
by aggregate, include each root plus its `tgReachability` set, invert that map into declaration
consumers, and retain all `tgDeclarations` keys as the service inventory. Public query functions
return sorted lists or ordered maps/sets; traversal order must never affect output. Put
`{-# OPTIONS_GHC -Werror=incomplete-patterns #-}` on the module and pattern-match every `UseSite`
constructor explicitly.

Milestone 3 adds focused Hspec coverage in `keiro-dsl/test/Main.hs` or a new test module listed by
the Cabal component. Use a two-aggregate spec with one direct structural root, a nested structural
reference, one shared root, and one unused declaration. Assert exact closures in both directions,
service inventory inclusion of the unused declaration, deterministic ordering after declaration
reordering, and the absence of Aggregate B from an Aggregate A-only declaration. Add a source-level
policy test or documented compile probe showing that a new `UseSite` constructor leaves an
incomplete pattern in `SemanticImpact`; do not make the production API partial merely for the
probe.

Milestone 4 replaces no generator behavior yet. Audit every use of `tgReachability`, `tgUseSites`,
`Map.elems (tgDeclarations graph)`, `usePaths`, and `projectionSpecs`. Record which later plan owns
each migration and add Haddocks explaining that `SemanticImpact` is consumer dependency, not wire
compatibility or proof coverage. Amend ADR 0012 or create a focused successor ADR for the single
impact authority and current root boundary. Update `keiro-dsl/CHANGELOG.md` only if exposing the
module is a public API change. Run the package tests and prove the committed conformance corpus is
byte-clean.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Refresh local project evidence and inventory the existing closure calculations:

```bash
mori registry show shinzui/keiro --full
rg -n 'tgReachability|tgUseSites|usePaths|projectionSpecs|mappedHarnessDeclarationsResolved|codecMappedDeclarations' \
  keiro-dsl/src keiro-dsl/test
```

During implementation, run the focused model tests and package build:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='semantic impact'
cabal build keiro-dsl
```

Validate the revised request and the non-output-changing foundation:

```bash
mori improvement-requests validate --path /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-dsl:keiro-dsl-test
scripts/check-conformance-corpus.sh
just check-adr
git diff --check
git status --short
```

The focused transcript must report all semantic-impact examples passing. The corpus checker must
report no generated-file drift because this plan changes no emitter.


## Validation and Acceptance

A checked graph with `SharedPayload -> NestedPayload`, used only by Aggregate A's command, must
produce A's closure `{SharedPayload, NestedPayload}`, no Aggregate B consumer, and both
declarations in the service inventory. If both aggregates gain roots, the inverted consumer map
must name both. An unused declaration remains in service inventory but has no aggregate consumer.

Event, command, and register roots must all contribute through one `UseSite` fold. Snapshot impact
is documented as register-derived. The model must not manufacture queue, public-contract,
read-model, or projection consumers. Declaration and aggregate order permutations produce equal
model values and identical rendered test projections.

IR-21 must no longer require per-aggregate deletion of declaration-owned evidence or simultaneous
duplicate/exact-once coverage. The request remains linked to the canonical Mori plan and clearly
states which future root additions require a successor language design.

The complete `keiro-dsl-test`, package build, ADR validation, request validation, corpus policy,
and diff hygiene pass. No file under `keiro-dsl/test/conformance-*/Generated` changes.


## Idempotence and Recovery

Model derivation is pure and safe to repeat. The IR edit is ordinary documentation and preserves
the original origin and review history. If the proposed public types prove awkward before any
downstream plan lands, change them here together with tests and ADR text; do not add a second
adapter model in `Harness` or `Diff`.

No scaffold or corpus regeneration is authorized by this plan. If a test command unexpectedly
changes generated files, stop, inspect the corpus driver invocation, and restore only files that
the command created after verifying they are generated artifacts. Never discard unrelated
worktree changes.


## Interfaces and Dependencies

No external dependency or bound changes. Use `containers` already declared by `keiro-dsl`.
`Keiro.Dsl.SemanticImpact` must expose an equivalent interface to:

```haskell
newtype MappedConsumer = AggregateConsumer Name
  deriving stock (Eq, Ord, Show)

data MappedRootKind
  = MappedCommandFieldRoot
  | MappedEventFieldRoot
  | MappedRegisterRoot
  deriving stock (Eq, Ord, Show)

data MappedRoot = MappedRoot
  { mappedRootConsumer :: !MappedConsumer
  , mappedRootKind :: !MappedRootKind
  , mappedRootUseSite :: !UseSite
  , mappedRootDeclaration :: !MappedKey
  }

data SemanticImpact = SemanticImpact
  { impactRoots :: ![MappedRoot]
  , impactAggregateDeclarations :: !(Map MappedConsumer (Set MappedKey))
  , impactDeclarationConsumers :: !(Map MappedKey (Set MappedConsumer))
  , impactServiceDeclarations :: !(Set MappedKey)
  }

semanticImpact :: TypeGraph -> SemanticImpact
aggregateMappedClosure :: SemanticImpact -> Name -> [MappedKey]
mappedDeclarationConsumers :: SemanticImpact -> MappedKey -> [MappedConsumer]
serviceMappedInventory :: SemanticImpact -> [MappedKey]
```

Names may be refined to match repository conventions, but the information boundary may not: one
checked model, deterministic projections, all service declarations, only real aggregate roots,
and exhaustive `UseSite` handling. EP-2 and EP-5 are hard downstream consumers and must import
this module rather than reconstructing the maps.
