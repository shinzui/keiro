---
id: 216
slug: generate-and-classify-missing-checkpoint-policy-in-candidate-language-5
title: "Generate and classify missing-checkpoint policy in candidate Language 5"
kind: exec-plan
created_at: 2026-08-09T17:50:24Z
intention: intention_01kzrnkgtcey6a8ar7xqn9tjxx
master_plan: "docs/masterplans/33-make-subscription-checkpoint-lifecycle-explicit-before-the-next-release.md"
---

# Generate and classify missing-checkpoint policy in candidate Language 5

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, candidate Language 5 makes missing-checkpoint intent mandatory for every
subscription feed. A service author writes exactly one of `from-beginning`, `from-current-head`, or
`fail`; parsing, formatting, workspace snapshots, generated Keiro declarations, inspection, and
diff all preserve that choice. Omitting it or attaching it to an inline projection is a precise
language error rather than an implicit runtime decision.

Generated catalogs use the runtime contract delivered by [Plan 215](215-adopt-explicit-checkpoint-lifecycle-semantics-in-the-projection-catalog.md).
The compiler rejects a current-head policy when a replayable owner clears its target, and a policy
change is reported as a specific breaking operational/catalog change without pretending that the
persisted subscription identity changed. Conformance tests prove the generated program compiles
and operator artifacts contain the policy. Candidate Language 5 remains unreleased throughout this
plan, so the correction is made in place rather than creating Language 6 or preserving an unsafe
fallback.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-11T20:07:26Z) Milestone 1: add required `checkpoint-on-missing` syntax to the
  Language 5 model, parser, formatter, inspection, mutation, workspace snapshots, and
  round-trip/golden tests.
- [x] (2026-08-11T20:07:26Z) Milestone 2: validate placement and replay-safety combinations with
  dedicated diagnostics before scaffolding or runtime startup.
- [x] (2026-08-11T20:14:23Z) Milestone 3: generate Plan 215's runtime policy in catalogs,
  conformance facades, and hole helpers, then compile every projection-catalog conformance fixture.
- [x] (2026-08-11T20:56:09Z) Milestone 4: classify policy changes in structural diff/replay
  impact, update ledgers, docs/examples/runtime patterns, and pass full source acceptance without
  releasing Language 5.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Candidate Language 5 already distinguishes subscription-feed ownership from inline projection
  feeds and carries subscription, deduplication, replay, and target-preparation facts through one
  `ProjectionOwnerNode`. Missing-checkpoint policy belongs at that same ownership boundary.
- The language is not released, so a compatibility default would create rather than solve future
  migration debt. Existing repository fixtures are migration inputs, not public syntax contracts.
- A checkpoint-policy change alters startup behavior and the catalog fingerprint but does not
  rename the persisted subscription/member key. Diff must express both facts instead of reporting
  an identity replacement.
- The corpus regeneration driver completed all three selected candidate-Language-5 scaffold
  invocations, then its repository-wide audit exposed two latent inventory gaps: the compiled
  domain-outcomes suite lacked tracked scaffold provenance, and the declarative-router component
  omitted seven live generated modules. Registering the generated ledger/fragment and compiling
  the complete router output advanced the final corpus gate to 39 of 39 clean invocations.
- The Jitsurei rebuild fixture applied an async projection directly and therefore had no exact
  durable subscription-member row for the rebuild reset to find. Provisioning that row through
  Kiroku's public `initializeSubscriptionCheckpoint` API made the test express the same lifecycle
  precondition as production instead of weakening the new condemnation rule.


## Decision Log

Record every decision made while working on the plan.

- Decision: Require `checkpoint-on-missing` on every subscription feed in candidate Language 5 and
  forbid it on inline feeds.
  Rationale: Only subscriptions own durable checkpoints. Required syntax makes the operational
  choice visible and prevents new services from inheriting an accidental default.
  Date: 2026-08-09

- Decision: Use the closed spellings `from-beginning`, `from-current-head`, and `fail` and lower
  directly to Kiroku's corresponding constructors.
  Rationale: A stable three-value vocabulary is readable in the domain language, inspectable by
  operators, and avoids a second translation model.
  Date: 2026-08-09

- Decision: Reject the replay-unsafe current-head/clear combination during DSL validation and keep
  the equivalent runtime validation from Plan 215.
  Rationale: Early feedback helps authors, while runtime validation still protects hand-written or
  stale generated catalogs. Defense in depth is intentional at two different trust boundaries.
  Date: 2026-08-09

- Decision: Classify a policy change as a specific breaking, stop-the-world operational/catalog
  change while preserving persisted subscription identity.
  Rationale: The next start can behave differently if a row is absent, and the fingerprint must
  change, but existing rows remain authoritative and are not renamed or rewound.
  Date: 2026-08-09

- Decision: Modify candidate Language 5 in place and do not release in this plan.
  Rationale: Language 5 is unreleased. A new version gate would institutionalize the omission, and
  package publication is intentionally deferred until all accumulated improvements are complete.
  Date: 2026-08-09

- Decision: Retain zero or more parsed `checkpoint-on-missing` occurrences until validation, then
  require exactly one for subscription owners and zero for inline owners.
  Rationale: This preserves a closed three-value policy after validation while allowing omission,
  duplication, and inline placement to receive distinct stable diagnostics instead of falling
  through to a generic parser failure or compatibility default.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Candidate Language 5 now requires exactly one `checkpoint-on-missing` clause on every subscription
owner and rejects the clause on inline owners. The parser, canonical formatter, inspection model,
workspace snapshots, scaffold ledger, and mutation/equality paths preserve the closed
`from-beginning`, `from-current-head`, and `fail` vocabulary. Dedicated diagnostics cover missing,
duplicate, unknown, misplaced, and replay-unsafe policy declarations; the complete policy by
preserve/clear matrix is tested before scaffolding.

Generated projection catalogs lower the three source values directly to Kiroku's public
`FromBeginning`, `FromCurrentHead`, and `FailIfMissing` constructors. All three repository
conformance cohorts compile the generated policy and retain it in facade and ledger facts. A
policy-only diff now emits `CatalogCheckpointPolicyChanged`, reports the old and new values,
preserves persisted subscription identity, marks the generated consumer build breaking, requires
stop-the-world coordination, and names the affected replay group, targets, source, and adapter.

The user and capability documentation, ADR 31, and
`mori://shinzui/keiro-runtime-patterns/docs/kiroku-subscriptions` now agree on absent-row policy,
existing-row precedence, and atomic initialization/reset behavior. The runtime-patterns corpus
passes all 81 concept checks. No Language 5 release, package publication, tag, or release metadata
was created.

Final acceptance passed `just verify`, including 466 Keiro, 58 PGMQ, 30 operations, 686 DSL, 23
Jitsurei, and 28 migration examples; all generated DSL conformance components; the 39-entry
conformance corpus; and ADR, research, capability, extension, and generated-name gates. `nix fmt`,
`nix flake check`, and `git diff --check` also pass. This checkout has no `just check-adr` recipe;
its actual `adr-validate` repository gate ran through `just verify` and validated all 31 ADR
concepts strictly.


## Context and Orientation

`keiro-dsl` parses a service language into a typed model, validates it, generates Haskell
projection catalogs, and compares workspace snapshots. Candidate Language 5 is the current
unreleased projection-catalog candidate. `keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines
`ProjectionOwnerNode`, which carries whether a projection is owned by a subscription feed or is
inline, plus deduplication, replay, and target facts. The parser and formatter live in
`keiro-dsl/src/Keiro/Dsl/Parser/ProjectionCatalog.hs` and
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`. Validation is centralized in
`keiro-dsl/src/Keiro/Dsl/Validate.hs` and its projection helpers.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` generates
`Keiro.Projection.Catalog.SubscriptionDeclaration` values. Projection-catalog conformance fixtures
and snapshots under `keiro-dsl/test/` compile generated modules against Keiro. Inspect, mutate,
workspace, and diff modules also serialize `ProjectionOwnerNode`; every exhaustive pattern match
must carry the new field. Use `rg` to find the exact current paths before editing because candidate
language modules are deliberately reorganized between versions.

The required syntax on a subscription feed is:

```text
checkpoint-on-missing = from-beginning
checkpoint-on-missing = from-current-head
checkpoint-on-missing = fail
```

Exactly one line is required per subscription feed. Inline feeds have no checkpoint and therefore
must reject the key. “Replayable owner” means the owner declares enough history semantics for a
target to be rebuilt. A `ClearBeforeReplay` target is emptied before historical delivery. Combining
that preparation with `from-current-head` would start after the history needed to reconstruct the
empty target.

Plan 215 defines the runtime declaration, inventory, fingerprint, and validation contract this
plan generates. [ADR 26](../adr/0026-projection-catalog-identities.md) requires a single stable
catalog identity surface. [ADR 4](../adr/0004-versioned-api-evolution-gates.md) permits editing an
unreleased candidate in place but requires a later explicit release gate. [ADR 28](../adr/0028-library-owned-operator-commands.md)
keeps generated code on public Kiroku/Keiro APIs. Mori's ownership and write-path evidence
decisions are `mori://shinzui/mori/okf/adrs/concepts/ADR-20` and
`mori://shinzui/mori/okf/adrs/concepts/ADR-21`.


## Plan of Work

Milestone 1 extends the candidate model and lossless language surfaces. Add a closed
`CheckpointOnMissingNode` (or equivalently named candidate-language type) to the subscription-feed
branch of `ProjectionOwnerNode`. Parse exactly one required `checkpoint-on-missing` assignment with
the three spellings above, render it canonically, and carry it through inspect, mutate, workspace
snapshot, decode/encode, and equality/hash instances. Migrate all checked-in Language 5 examples
and goldens by choosing intent explicitly: replayable read models normally use `from-beginning`;
future-only effects use `from-current-head`; operationally provisioned workers may use `fail`.
Round-trip tests must distinguish missing, duplicate, unknown, and misplaced fields.

Milestone 2 enforces semantic validity before code generation. Extend `Keiro.Dsl.Validate` with a
diagnostic for `from-current-head` on a replayable subscription owner whose target uses
`ClearBeforeReplay`. The diagnostic includes source span, subscription name, owner/target name, and
an actionable suggestion. All three policies remain explicit and valid for the other supported
target modes; inline feeds reject the key regardless of target. Table-driven tests enumerate every
policy, ownership kind, and preparation mode. Invalid input must fail validation before scaffold
files are written.

Milestone 3 lowers directly to Plan 215's catalog. Update the projection catalog scaffolder to emit
`checkpointOnMissing = FromBeginning`, `FromCurrentHead`, or `FailIfMissing` and add only the public
imports needed from Kiroku/Keiro. Update generated facades, typed hole helpers, source maps, and
conformance expected output. Regenerate repository-owned snapshots with the normal scaffold
command rather than hand-editing generated bodies. Compile the projection-catalog conformance
suite against the sibling-source runtime contract and prove each of the three spellings reaches
operator inventory unchanged.

Milestone 4 teaches evolution tooling what the change means. Add a dedicated structural diff code,
for example `CatalogCheckpointPolicyChanged`, containing subscription identity and old/new policy.
Classify it as breaking and requiring stop-the-world operational review because future missing-row
startup changes; state separately that persisted subscription identity is compatible and existing
rows do not move. Include the field in baseline snapshots, diff text/JSON, replay-impact output,
compatibility fixtures, and the Language 5 capability ledger. Update DSL reference docs and
examples. Once the runtime and DSL contracts pass, update
`mori://shinzui/keiro-runtime-patterns/docs/kiroku-subscriptions` to replace its provisional
“Kiroku does not expose this yet” guidance with the released-later explicit policy vocabulary.
Do not publish packages or declare Language 5 released.


## Concrete Steps

Work from the Keiro repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Locate the current candidate-language surfaces before editing:

```bash
rg -n 'ProjectionOwnerNode|subscription-feed|dedup|ClearBeforeReplay' keiro-dsl
rg -n 'SubscriptionDeclaration|Catalog.*Changed|replay.impact|Language 5' keiro-dsl docs
```

After milestone 1 and after every grammar/golden update, run:

```bash
cabal build keiro-dsl
cabal test keiro-dsl:keiro-dsl-test
```

After scaffolding changes, run the repository's candidate projection-catalog generator command
discovered in the adjacent test README or Cabal test definition, then run:

```bash
cabal test keiro-dsl:keiro-dsl-conformance-projection-catalog
cabal test keiro-dsl:keiro-dsl-test
```

At final acceptance run:

```bash
just verify
just check-adr
nix fmt
nix flake check
git diff --check
git status --short
```

Expected output contains no parse, golden, generated-source, diff, format, or flake failures. The
working tree may contain the implementation and regenerated fixtures, but no release metadata,
tag, package upload, or tracked sibling-source override.


## Validation and Acceptance

A valid Language 5 subscription feed containing each spelling must parse, format, parse again, and
produce the same typed value. Inspection and workspace snapshot JSON expose the chosen policy.
Omitting the field, repeating it, using an unknown value, or placing it on an inline feed produces
a dedicated diagnostic at the field or owning feed, not a generic parse failure or default.

Validation rejects this combination before scaffolding: subscription ownership, replayable target,
`ClearBeforeReplay`, and `from-current-head`. It accepts `from-beginning` and `fail` for the same
target and proves the documented matrix for every other mode. The runtime validation from Plan 215
also rejects an equivalent hand-written declaration, showing the DSL check is not the only guard.

Generated Haskell for all three values compiles and constructs Plan 215's exact
`SubscriptionDeclaration` field. Its catalog fingerprint and operator JSON change when only the
policy changes. Conformance snapshots contain no compatibility default or placeholder, and
generated imports remain public and minimal.

Diffing two otherwise identical workspaces with different policies yields exactly the dedicated
policy-change code. Text and JSON show old/new values, compatibility is breaking for the generated
catalog/consumer build, operational coordination is stop-the-world, and persisted subscription
identity is reported unchanged. Diffing identical policies yields no change. All package, DSL,
conformance, ADR, formatting, and flake checks pass without publishing Language 5.


## Idempotence and Recovery

Parser, validator, and generator edits are repeatable. Repository-owned generated fixtures must be
regenerated with the same checked-in command; a second run should produce no diff. Do not hide a
non-idempotent generator by hand-editing its output.

Migration of existing candidate fixtures is intentionally source-breaking but recoverable through
version control. Choose policy from the fixture's declared replay/target intent and record any
ambiguous fixture in the Decision Log; do not apply `from-beginning` mechanically to future-only
effects. Invalid input must leave the scaffold destination unchanged, or use the existing atomic
output-staging behavior if generation already created a temporary tree.

If sibling runtime work is unavailable, finish model/parser tests but do not bless generated
goldens or mark milestone 3 complete. Remove only untracked local dependency overrides after
testing. Never create Language 6, publish an intermediate candidate, or rewrite unrelated user
changes to recover.


## Interfaces and Dependencies

The candidate model needs a closed, serializable vocabulary equivalent to:

```haskell
data CheckpointOnMissingNode
    = CheckpointFromBeginning
    | CheckpointFromCurrentHead
    | CheckpointFail
    deriving stock (Eq, Ord, Show, Generic)
```

Only the subscription-feed owner branch carries that value. Lowering is total and explicit:

```text
from-beginning    -> Kiroku.Store.FromBeginning
from-current-head -> Kiroku.Store.FromCurrentHead
fail              -> Kiroku.Store.FailIfMissing
```

Plan 215 supplies `checkpointOnMissing :: MissingCheckpointPolicy` on
`Keiro.Projection.Catalog.SubscriptionDeclaration`, its inventory representation, fingerprint,
and the runtime replay-safety validator. This plan must import those public definitions instead of
duplicating runtime types.

The structural diff must expose a dedicated constructor equivalent to:

```haskell
data CatalogChange
    = CatalogCheckpointPolicyChanged
        SubscriptionId
        MissingCheckpointPolicy
        MissingCheckpointPolicy
    | -- existing changes
```

Use the actual DSL snapshot vocabulary at implementation time if it cannot depend on the runtime
type, but keep a total mapping and identical stable spellings. The change classifier must carry
three independent facts: generated-catalog compatibility is breaking, operational coordination is
stop-the-world, and persisted subscription identity remains compatible. This plan is EP-2 of
[MasterPlan 33](../masterplans/33-make-subscription-checkpoint-lifecycle-explicit-before-the-next-release.md)
and cannot complete before EP-1.


Revision note (2026-08-11): Completed implementation, recorded the full acceptance evidence, and
captured the exact-checkpoint fixture and conformance-inventory discoveries from the clean-tree
verification run.
