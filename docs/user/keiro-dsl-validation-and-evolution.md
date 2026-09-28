---
type: Reference
title: Keiro DSL Validation and Evolution
description: Understand Keiro DSL validation layers and language gates, evolve deployed specifications safely, and review the authoring checklist.
docId: DOC-34
tags: [keiro, dsl, validation, evolution, reference]
generated:
  by: anthropic-claude-code/claude-opus-5
  at: 2026-09-28T00:00:00Z
---

# Keiro DSL Validation and Evolution

This page describes what the checker validates, how language versions gate
syntax, the workflow for evolving a deployed specification, and the authoring
checklist. It is part of the [Keiro DSL Reference](keiro-dsl-reference.md), which
introduces the language, its versions, and source file structure.

## Validation model

The tool separates three failure classes:

1. A parse failure means the source does not match its selected language grammar.
2. An `error[Code]` means the graph parses but cannot safely or faithfully
   lower. `check` exits non-zero, and scaffold writes nothing.
3. A `warning[Code]` calls out a risky but explicit policy, incomplete
   operational proof, or adoption state. Warnings do not make `check` fail by
   default. `--deny-warnings` and `--deny CODE` escalate only this invocation's
   exit result; the diagnostic still renders and reports as `warning`.

A green `check` also means the default scaffold plan has no refusal that is
decidable from the checked graph. Empty aggregates and contracts are
`AggregateEmpty` and `ContractEmpty` errors under every language version. Module
path collisions, generated/consumer import cycles, unsound behavior derivation,
duplicate conformance fact keys, and unexpected internal planning failures use
`GeneratedPathCollision`, `GeneratedImportCycle`, `BehaviorDerivationInvalid`,
`ConformanceFactKeyCollision`, and `GeneratedPlanningInvariantViolation`.
Diagnostics retain source locations where planner evidence exposes them.

Scaffold still owns evidence that exists only after an output tree and invocation
options are known: exact generated-banner protection, golden-root divergence,
explicit name-migration authorization, and stale generated evidence. It also
re-runs the shared gates after applying `--module-root`, `--collocate`,
`--runtime-package`, and golden inputs, so an override-induced refusal is detected
before a write set exists. These checks are defense in depth, not a second
semantic vocabulary.

Every source declares `language keiro-dsl 5`, the published stable contract
and current authoring default, or `language keiro-dsl 6`, the candidate.
Languages 1 through 4, and sources without a preamble, are deprecated and
scheduled for removal; `check` and `scaffold` print a `language contract:`
notice for such a source, and it should be migrated to Language 5. Gate CI with
`--min-language 5` so that no deprecated source is accepted.

A source that declares `language keiro-dsl 6` selects the candidate contract.
`check` and `scaffold` accept it, and the `--report-out` JSON records
`"languageSupport": "candidate"` with runtime semantics
`keiro-dsl/runtime-semantics/5`, because it has not yet been published. A service that adopts candidate features may gate CI with
`--min-language 6`, but should expect to track in-place corrections to the
candidate until it is published.

The warning policy follows the evidence boundary. Three warnings depend on
operational history and therefore remain warnings: `DeprecatedEventReplayHazard`,
`EventRetirementInProgress`, and `ReplayOnlyCommandStillLive`. Deny them in CI
until the database-backed audit establishes the relevant fleet fact. Five
warnings describe deliberate or currently accepted policy:
`WqUnloggedDurability`, `ProcessBenignInversion`, `RouterBenignInversion`,
`AmbiguousFollowsRejectedPolicy`, and `PolicyDeadLetterUnused`. One more makes
an accepted but currently inert declaration explicit:
`IntakeBindFlagUnenforced`. Teams may deny
any of these warnings without changing the shared language contract. Two internally decidable
warnings, `WireSchemaVersionMismatch` and `RmProjectionWithoutNode`, are
candidates for an error in a future language version rather than retroactive
tightening of a published one. They can be selected with `--deny` today.

The checker validates local syntax and whole-service coupling. Important closed
surfaces include:

- unique declarations, fields, states, registers, map cases, topic aliases,
  columns, and durable identities;
- valid TypeID prefixes and declared ID admission domains;
- typed aggregate expressions, initial values, transition ownership,
  event-sourced state changes, reachability, terminal states, upcaster chains,
  wire policy, projection maps, and snapshot fixtures;
- process/router aggregate, command, key, binding, field, projection, resolver,
  verified resolve-row, timer, and worker-policy references;
- contract topic syntax and topology; intake binding, schema, dedupe, decode,
  persistence, and complete disposition policy; emit topic affinity; publisher
  ordering/backoff/attempt policy;
- queue payload vocabulary, bounded durations, identity fixtures,
  FIFO/group/provisioning rules, complete disposition, and dispatch
  read-model/queue references;
- PostgreSQL read-model names, types, shape fixtures, freshness, catalog
  targets and rebuild groups, and projection ownership; and
- workflow label, input, patch, rotation, signal, operation, and stable identity
  rules.

Diagnostics include a source line. Fix the specification first. If a generated
harness later fails, fix the create-once behavior or evidence named by that
harness; do not weaken the generated runtime boundary.

Projection catalog query-supply diagnostics are:

- `CatalogReadModelBindingMissing` when no observed target is declared;
- `CatalogTargetUnknown` or `CatalogReadModelTargetOutsideGroup` for an invalid
  target prerequisite;
- `CatalogReadModelSupplierMissing` when the complete valid target set has no
  supplier;
- `CatalogReadModelMultipleSuppliers` when valid observed targets span owners,
  with every owner claim site attached; and
- `CatalogReadModelLegacyProjectionConflict` when a catalog-bound query is also
  named by an aggregate-local legacy projection clause.

Existing missing/multiple target-owner diagnostics remain authoritative at target
claims rather than producing duplicate query noise.

## Evolution workflow

For any persisted or public change:

1. Edit the source.
2. Run `check` and resolve every error.
3. Run `diff --since <deployed-ref> --explain`.
4. For private event changes, bump event versions, preserve contiguous
   upcasters, and capture goldens as directed.
5. For read-model shape changes, bump the model version and update the reported
   shape fixture together.
6. For snapshot or hand-owned fold changes, bump the corresponding codec,
   shape, or `FoldVersion` identity.
7. Scaffold into a clean tree, reconcile the generated manifest and stale
   report, then compile all hand-owned modules.
8. Run generated codec, binding, behavior, snapshot, forward/replay, and
   service integration conformance tests.
9. Follow the rollout constraints from `diff`; run the real-log replay gate
   when replay impact is reported.

Do not treat a green parse as semantic validation, a green check as proof of
hand-owned behavior, or finite fixtures as proof of every possible consumer
value. The toolchain makes each remaining obligation explicit so CI and rollout
policy can own it at the correct boundary.

## Authoring checklist

Before committing a new or changed service specification:

- The first non-comment line is exactly `language keiro-dsl 5` for a new or migrated service,
  or `language keiro-dsl 6` only when the service intentionally adopts candidate features.
- `check` exits zero for the whole source or workspace.
- Every public/persisted field has an intentional type and wire spelling.
- Aggregate time comes from command/input data, never a sampled clock.
- Every state change emits an event; guarded siblings are mutually exclusive.
- Event changes have a version, contiguous upcaster chain, and payload goldens.
- Mapped structural and refined bindings are total; opaque boundaries are
  intentional and visible in coverage.
- A changed ID admission domain, date, set, or base16 policy is treated as a
  semantic change with a retained reader, never as a refactor.
- Intake and queue disposition tables contain every required outcome and keep
  transient failures separate from poison or terminal failures.
- Stable process, router, workflow, queue, read-model, topic, patch, and outbox
  identities will not change accidentally.
- `diff` is green under the service's chosen compatibility gates and its
  rollout constraints are recorded.
- Scaffold output, the Cabal manifest, create-once holes, behavior evidence,
  and generated conformance harnesses are all reconciled and green.

For deciding whether a service should use the DSL at all, see
[Choosing `keiro-dsl`](../guides/choosing-keiro-dsl.md). For runtime concepts
behind the declarations, see [Core Concepts](core-concepts.md),
[Codecs And Event Evolution](codecs-and-event-evolution.md),
[Process Managers And Timers](process-managers-and-timers.md),
[Durable Workflows](durable-workflows.md), and [Work Queues](work-queues.md).
