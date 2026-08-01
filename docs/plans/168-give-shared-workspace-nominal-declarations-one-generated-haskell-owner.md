---
id: 168
slug: give-shared-workspace-nominal-declarations-one-generated-haskell-owner
title: "Give shared workspace nominal declarations one generated Haskell owner"
kind: exec-plan
created_at: 2026-08-01T00:15:25Z
intention: "intention_01kyxarnbbet3ajn0995gt65w9"
master_plan: "docs/masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md"
---

# Give shared workspace nominal declarations one generated Haskell owner

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, one logical ID or enum declaration in a service workspace produces one Haskell
nominal type. Every aggregate that uses `ProjectId` imports the same generated declaration instead
of receiving an incompatible aggregate-local `newtype ProjectId`. Unused shared declarations are
not copied into unrelated aggregate modules.

The result is visible by scaffolding the existing two-aggregate workspace fixture and compiling the
complete generated tree. Both aggregates exchange the same `ProjectId` and `ProjectPhase` types,
there is exactly one declaration and instance owner, and reversing manifest member order produces
byte-identical output.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-01T15:37:09Z) Milestone 1: defined checked nominal declaration ownership and stable
  context-level module placement for single-file and workspace inputs.
- [x] (2026-08-01T15:37:09Z) Milestone 2: emit each generated ID/enum once, import only used nominals
  into aggregate domains and their generated consumers, and preserve consumer-bound ownership.
- [x] (2026-08-01T15:37:09Z) Milestone 3: compiled and executed a two-aggregate workspace conformance
  target with cross-ring nominal values and generated instances.
- [ ] Milestone 4: add adoption/diff/freshness coverage, update ADR 14 and workspace documentation,
  and run full validation. Freshness and member-order coverage are complete; durable documentation
  and full validation remain.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-01: `Keiro.Dsl.Scaffold.resolveAgg` assigns every `specIds` and `specEnums` entry from the
  merged workspace `Spec` to every aggregate. `emitDomain` then declares each unbound ID and enum
  inside that aggregate's generated domain module. The existing workspace fixture consequently
  produces two incompatible `ProjectId` and `ProjectPhase` Haskell types while all 0.6 workspace
  tests remain green because they inspect ownership metadata and paths but never compile the whole
  generated workspace.

- 2026-08-01: Moving constructors out of an aggregate `Domain` module means hand-owned modules that
  previously obtained generated enum/ID constructors from that module need an explicit import from
  the new `Nominals` module. The adoption remains non-destructive: scaffold writes only generated
  modules, while checked-in hand-owned conformance modules demonstrate the one-line import change.

- 2026-08-01: The established `demo-project` workspace fixture contains an intentionally external
  consumer-owned `ProjectSummary`, so it is suitable for ownership and deterministic-plan tests but
  not a self-contained compile target. The fixture was extended with an unused enum, while a minimal
  companion workspace supplies the executable cross-ring type-identity proof.


## Decision Log

Record every decision made while working on the plan.

- Decision: Generated service-level IDs and enums have one context-level module owner; aggregate
  domain modules import the exact used declarations.
  Rationale: source-file ownership is diagnostic provenance, not Haskell type ownership. A
  context-level generated owner is stable across member moves and satisfies the single-authority
  rule without requiring consumer bindings.
  Date: 2026-08-01

- Decision: Preserve existing single-file aggregate bytes only where doing so does not duplicate a
  service-level declaration; report the unavoidable module move as generated-layout adoption, not
  wire evolution.
  Rationale: type identity is a correctness boundary. Byte compatibility cannot justify retaining
  two incompatible nominal authorities, while event wire bytes and canonical nominal identities
  can remain unchanged.
  Date: 2026-08-01

- Decision: Compute nominal use closure from resolved aggregate fields, registers, expressions,
  event mappings, snapshots, codecs, and harnesses rather than importing all declarations.
  Rationale: the reopened IR-2 explicitly reports unused enum emission, and future equality/prefix
  instances must not appear in aggregates that do not use their owner type.
  Date: 2026-08-01

- Decision: Emit the complete service declaration set in the context `Nominals` module, but import
  only each aggregate ring's transitive generated uses.
  Rationale: one service-level declaration must remain available even before an aggregate uses it;
  keeping it out of unrelated aggregate imports closes the unused-emission regression without
  making declaration existence depend on current consumers.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(Implementation not started.)


## Context and Orientation

The owning request is reopened
[IR-2](../improvement-requests/support-composable-multi-file-service-specifications-in-keiro-dsl.md).
Completed MasterPlan 26 introduced the manifest, composed `WorkspaceSpec`, atomic workspace
scaffold, diff, and acceptance fixture. This plan does not duplicate those delivered capabilities;
it repairs the generated type-identity acceptance failure discovered afterward.

`keiro-dsl/src/Keiro/Dsl/Workspace.hs` owns `wsMergedSpec` and declaration/source ownership.
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` calls `scaffoldAggregate ctx merged aggregate` for
each aggregate. `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` builds `Agg` with all merged IDs/enums and
`emitDomain` emits unbound declarations locally. `nominalProjectionOwners` already demonstrates a
context-level generated nominal-related module, but it currently covers only consumer-owned scalar
projections.

The fixture under `keiro-dsl/test/fixtures/workspace/` has `shared.keiro`, `project.keiro`, and
`project-artifact.keiro`. Extend it rather than creating another workspace fixture. Add a compiled
conformance package or temporary-Cabal project that imports both aggregate rings at once; path-only
assertions cannot prove Haskell type identity.

[ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires one owner for a shared declaration. [ADR 15](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
governs context-level module history and member moves. [ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires generated and consumer-owned mappings to retain one schema authority. ADR 14 must be
amended to state the generated Haskell owner explicitly because the completed implementation did
not satisfy that consequence.


## Plan of Work

Milestone 1 introduces a pure nominal-generation plan derived from the resolved service graph. It
assigns every `GeneratedNominal` ID or enum one module path under the context generated namespace,
retains declaring member and `Loc` as provenance, and computes aggregate use sites. Consumer-owned
nominals keep their declared application module and binding. Plan collisions before writes and
record context-level modules with no member owner, following existing workspace conventions.

Milestone 2 changes `Keiro.Dsl.Scaffold` so `emitDomain` emits only aggregate-local records,
commands, events, registers, and vertices. A new context nominal module emits generated IDs, enums,
wire renderers/parsers, canonical type instances, and later extension points exactly once.
Aggregate domain, codec, snapshot, expression, transducer, and harness modules import only the
nominals in their resolved use closure. Single-file inputs route through the same service-level
plan so one file containing two aggregates also receives one nominal authority.

Milestone 3 adds compile-level proof. Scaffold the existing workspace fixture, build both generated
rings in one package, pass a `ProjectId` value through functions from both aggregate modules, encode
and decode events on both sides, and exercise `ProjectPhase` values. Add negative source-level
tests for duplicate declarations and generated-path collisions, but do not rely on a deliberately
uncompilable Haskell fixture as the only regression test.

Milestone 4 covers migration and evolution. A first scaffold over prior 0.6 history reports old
aggregate-local generated nominal modules as stale generated artifacts and the new context module
as added; it never deletes or claims hand-owned files. Wire/fold reports remain compatible when
only authority moves. Repeated scaffolds and member reordering are byte-identical. Update
workspace authoring documentation, `keiro-dsl/CHANGELOG.md`, ADR 14, and ADR bundle log.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal run keiro-dsl -- scaffold \
  keiro-dsl/test/fixtures/workspace/service.keiro-workspace \
  --out /tmp/keiro-workspace-nominal-proof
cabal test keiro-dsl-conformance-workspace-nominals
cabal test keiro-dsl-test --test-option=--match --test-option='workspace scaffold'
cabal test keiro-dsl-test
cabal build all
nix flake check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

The generated tree contains one `ProjectId` and one `ProjectPhase` declaration, the compiled
conformance target exits zero, and the full validation commands succeed.


## Validation and Acceptance

Acceptance requires one generated type and instance owner per shared declaration across a
two-aggregate workspace and a two-aggregate single file. Both rings must compile together and
exchange those values without conversion. Unused nominals are absent from aggregate imports.
Consumer-bound declarations remain consumer-owned. Reordering or moving the declaring member does
not change the nominal module, canonical identity, wire bytes, or generated output. Adoption from
0.6 history is explicit and non-destructive.


## Idempotence and Recovery

All generation planning is pure and deterministic. Use temporary output for the first compile
proof. Workspace preflight must detect collisions before writes. If adoption reporting is wrong,
leave the old record and generated tree untouched, correct the pure plan, and rerun; never delete
the old aggregate-local modules manually inside the implementation path.


## Interfaces and Dependencies

Add a checked value in `Keiro.Dsl.Scaffold` or a focused new module equivalent to:

```haskell
data NominalGenerationOwner = NominalGenerationOwner
  { nominalDeclaration :: ResolvedNominalType
  , nominalModule :: Text
  , nominalSourceOwner :: Maybe WorkspaceMemberRef
  , nominalUseSites :: Set NominalUseSite
  }

planNominalGeneration :: Context -> Spec -> Either [ScaffoldRefusal] [NominalGenerationOwner]
```

The module name is context/service-derived and independent of aggregate or member order. Plan 170
must add equality projection tags and Plan 171 must add validated ID constructors to this one owner
rather than reintroducing aggregate-local instances.
