---
id: 260
slug: make-fresh-awakeables-opaque-across-the-runtime-and-generated-workflows
title: "Make fresh awakeables opaque across the runtime and generated workflows"
kind: exec-plan
created_at: 2026-08-14T13:33:19Z
intention: "intention_01m0075g1kecjb2959gy704yhc"
master_plan: "docs/masterplans/42-fix-the-final-keiro-release-blockers-and-publish-stable-language-5.md"
---

# Make fresh awakeables opaque across the runtime and generated workflows

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, an application cannot mistake a coordinate-derived compatibility id for
the id of a newly allocated awakeable. The ordinary `Keiro.Workflow.Awakeable` authoring
module exposes only opaque allocation and signalling; historical generation-0 derivation is
isolated under an explicitly named compatibility module. A generated workflow exposes an
opaque binding for each declared `await` and an allocation function that returns the real
`AwakeableId` from `awakeableNamed`.

The behavior is visible in a database-backed `keiro-dsl-conformance-workflow-runtime` test.
Its first workflow run must suspend after publishing the returned id, signalling that exact id
must return `True`, and its second run must return `Completed` with the delivered payload. The
test must fail if generated code derives an id from workflow name, workflow id, and label.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-14T14:09:29Z) M1: isolate frozen generation-0 derivations in `Keiro.Workflow.Awakeable.Compatibility` and remove the misleading exports from the ordinary authoring module
- [x] (2026-08-14T14:09:29Z) M1: update runtime compatibility/golden tests while retaining the fresh forged-id refusal proof
- [x] (2026-08-14T14:23:53Z) M2: generate an opaque `AwaitBinding`, one binding value per declared await, and `allocateDeclaredAwait` over `awakeableNamed`
- [x] (2026-08-14T14:23:53Z) M2: add collision and generated-surface tests for binding names and remove `awaitAwakeableId`
- [x] (2026-08-14T14:23:53Z) M3: replace the tautological workflow-runtime executable with a PostgreSQL allocate/signal/resume/completion proof
- [x] (2026-08-14T14:23:53Z) M3: regenerate every committed `WorkflowRuntime` output and reconcile the conformance corpus
- [ ] M4: update the Keiro and keiro-dsl unreleased changelogs and amend ADR 24
- [ ] M4: pass focused runtime, DSL, compiled conformance, corpus, and full repository gates


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Review evidence at `7ddeaabf1850449241aaf0bd114c41a25455de9d` shows that the runtime
  algorithm is already correct: a fresh allocation is a journaled UUIDv4, and the live test
  rejects a forged coordinate-derived id. The break is entirely at the public/generated seam.
- The generated test currently computes both `signalSide` and `awaitSide` with
  `deterministicAwakeableId`, so compilation and a green boolean prove no interaction with
  `awakeableNamed`, `keiro_awakeables`, `signalAwakeable`, or workflow resumption.
- `WfAwait` carries a label and result type, but `WorkflowRuntime` is a runtime-support module,
  not the hand-owned workflow body. An opaque binding plus a polymorphic allocation wrapper
  preserves result-type inference without generating application behavior or a second payload
  type authority.
- The repository-wide build includes Jitsurei before EP-2 can replace its broken signalling
  path. EP-1 therefore moved its transitional coordinate probe to the explicitly named
  compatibility module and documented that it is not a fresh signalling target; EP-2 remains
  responsible for deleting the helper and publishing the allocated id.
- The Language 4 skeleton corpus is intentionally frozen and `just corpus-regen` does not rewrite
  it, but its `WorkflowRuntime` module is compiled by `keiro-dsl-conformance-skeletons`. Removing
  the ordinary deterministic export therefore required one explicit, reviewed runtime-support
  update to that generated file. EP-4 must preserve this evidence as an acknowledged blocker fix,
  not misclassify it as a silent Language 5 migration.
- The generated allocation signature makes `aeson`, `effectful-core`, and `kiroku-store` direct
  dependencies of every component that compiles `WorkflowRuntime`. The affected conformance
  components already had those workspace libraries available; their Cabal stanzas now declare
  the direct uses instead of relying on transitive exposure.


## Decision Log

Record every decision made while working on the plan.

- Decision: Remove `deterministicAwakeableId` and `legacyDeterministicAwakeableId` from
  `Keiro.Workflow.Awakeable` and expose renamed generation-0 functions only from
  `Keiro.Workflow.Awakeable.Compatibility`.
  Rationale: The current names sit beside fresh authoring primitives and have already been
  misused by first-party code. A compatibility-qualified import makes the exceptional purpose
  unavoidable while preserving operator and golden-test access during the 0.12 compatibility
  window required by ADR 24.
  Date: 2026-08-14
- Decision: Generate opaque declared-await bindings instead of an id-derivation helper.
  Rationale: A source declaration owns a stable label, not an allocation id. Calling
  `awakeableNamed` through the binding returns the only id that can be handed to a signaller.
  Date: 2026-08-14
- Decision: Make the workflow-runtime conformance target database-backed.
  Rationale: Equality between pure functions cannot prove allocation, durable row registration,
  signalling, journal delivery, or completion; the release blocker exists at exactly that live
  boundary.
  Date: 2026-08-14
- Decision: Derive await binding occurrences through one suffix-aware Haskell-name planner used
  by both validation and emission.
  Rationale: Registering a collision under any spelling other than the emitted spelling would
  recreate the class of planner/generator disagreement this repository already guards against.
  Date: 2026-08-14
- Decision: Update only the compiled workflow runtime inside the otherwise frozen Language 4
  skeleton corpus.
  Rationale: Leaving it byte-frozen makes the repository uncompilable after the ordinary helper
  removal; regenerating the whole corpus would silently migrate unrelated predecessor evidence.
  Date: 2026-08-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

An awakeable is a durable promise stored in `keiro.keiro_awakeables`. Workflow code calls
`awakeableNamed (StepName label)` and receives `(AwakeableId, awaitAction)`. The allocation
step registers the durable row, journals the chosen id under `awkid:<label>`, and returns it.
On a fresh generation-0 workflow with no historical row, the chosen id is random UUIDv4.
External code must receive that exact opaque value and later call `signalAwakeable` with it.

`keiro/src/Keiro/Workflow/Awakeable.hs` implements this correct path in
`allocateAwakeableId` and `awakeableNamed`. The same module also exports
`deterministicAwakeableId` and `legacyDeterministicAwakeableId`. Those functions reproduce
historical generation-0 identities so an in-flight row written by an older Keiro version can
be adopted. They do not predict a fresh allocation. The focused test named `refuses a forged
coordinate-derived id for a fresh awakeable` in `keiro/test/Main.hs` proves the distinction.
[REV-1](../reviews/awakeable-allocation-api.md) records the API blocker.

`keiro-dsl/src/Keiro/Dsl/Harness.hs`, in `emitWorkflowRuntime`, emits a generated
`awaitAwakeableId` that calls the legacy derivation. Committed copies exist under
`keiro-dsl/test/conformance-workflow*`, `keiro-dsl/test/conformance-skeletons`, and the
service-package corpus. `keiro-dsl/test/conformance-workflow-runtime/Main.hs` compares that
helper with the same derivation function. [REV-2](../reviews/dsl-workflow-awakeable-conformance.md)
records why the green test is a tautology. `keiro-dsl/keiro-dsl.cabal` defines the target and
its dependencies.

The generated replacement uses an `AwaitBinding`: an opaque generated value containing the
declared `StepName`. One value is emitted per `WfAwait`, including awaits nested under a patch.
`allocateDeclaredAwait` consumes a binding and delegates directly to `awakeableNamed`. Binding
value names must go through the repository's existing generated Haskell naming and collision
planning; do not concatenate or sanitize labels locally in `emitWorkflowRuntime`.

[ADR 5](../adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md)
defines how a signalled result becomes replay-visible.
[ADR 6](../adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md)
requires the pending row to exist before the id is exposed.
[ADR 20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md)
requires conformance to avoid generated expected/actual tautologies.
[ADR 24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
freezes the current and pre-UTF-8 generation-0 derivations and says fresh allocations remain
random. Amend ADR 24 during implementation to record that those derivations are available only
through the compatibility module; do not alter their seed bytes or UUID golden values. No
cross-repository ADR applies.


## Plan of Work

Milestone 1 makes historical identity visibly exceptional without changing any stored
identity. Add `keiro/src/Keiro/Workflow/Awakeable/Compatibility.hs` as an exposed module with
the public functions `generation0AwakeableId` and `preUtf8Generation0AwakeableId`. Move or
share the frozen seed construction so these functions and `allocateAwakeableId` cannot drift.
Remove the two old derivation exports and definitions from the ordinary
`Keiro.Workflow.Awakeable` surface, update `keiro/keiro.cabal`, and migrate runtime tests to
the compatibility-qualified names. Keep a golden pure derivation test, generation-0 adoption,
pre-UTF-8 adoption, and the fresh forged-id refusal. This milestone is complete when old code
importing `deterministicAwakeableId` from the authoring module no longer compiles, all golden
UUIDs remain unchanged, and both historical adoption paths still pass.

Milestone 2 changes generated workflow support. In
`keiro-dsl/src/Keiro/Dsl/Harness.hs`, replace `awaitAwakeableId` with an opaque generated
`AwaitBinding`, one exported lower-camel binding per declared await, and
`allocateDeclaredAwait`. For a label `reservation-confirmation`, the generated binding should
have a planned name such as `reservationConfirmationAwait`; exact spelling is determined by
the established Haskell naming planner, which must reject collisions before scaffold writes.
Retain `awaitLabels`, patch constants, and `withDeclaredPatches`. Extend generator unit tests
to pin the new exports/imports, nested-patch inventory, name planning, and absence of any
generation-0 derivation import. This milestone is complete when generated consumers can only
obtain an id by running the allocation effect.

Milestone 3 replaces the false proof with live conformance. Rewrite
`keiro-dsl/test/conformance-workflow-runtime/Main.hs` to use the generated binding inside a
small workflow. Use `Keiro.Test.Postgres.withMigratedSuite` and `withFreshResourceStore`, as
the declarative-router conformance target already does. On the first run, capture the id
returned by `allocateDeclaredAwait` and assert `Suspended`. Signal that id and assert `True`.
Run the same workflow again and assert `Completed` with the sent `Text` payload. Continue to
assert the declared label and patch behavior. Add the necessary existing workspace dependencies
to this one Cabal test stanza, regenerate all affected committed output using the repository's
normal corpus commands, and ensure the generated source contains neither old function name.

Milestone 4 records and validates the contract. Add user-visible breaking/fix entries under
`Unreleased` in `keiro/CHANGELOG.md` and `keiro-dsl/CHANGELOG.md`. Amend ADR 24, advance its
OKF timestamp/log entry, and run strict ADR validation. Run the focused suites, complete DSL
suite, compiled conformance target, corpus policy, and `just verify`. Record the exact test
counts and commit SHA in this plan's living sections for EP-4's closure review.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`.

Before editing, preserve the reviewed red/green contradiction:

```bash
cabal test keiro-test --test-options='--match "refuses a forged coordinate-derived id for a fresh awakeable"'
cabal test keiro-dsl-conformance-workflow-runtime
```

The pre-fix output includes a passing forged-id refusal and the misleading line:

```text
await<->signal awakeable id match (real deterministicAwakeableId): True
```

After Milestone 1, run the derivation and allocation group, adjusting the Hspec match only if
the implementation gives the group a clearer compatibility name:

```bash
cabal test keiro-test --test-options='--match "Keiro.Workflow.Awakeable"'
```

After Milestones 2 and 3, regenerate and test the generated surface:

```bash
just corpus-regen
cabal test keiro-dsl-test
cabal test keiro-dsl-conformance-workflow-runtime
just conformance-corpus-policy
```

The new runtime target should end with a concise success transcript equivalent to:

```text
generated await allocated an opaque id: PASS
signal of allocated id transitioned the row: PASS
workflow resumed with the payload: PASS
workflow runtime conformance: PASS
```

Check that live generated/runtime source no longer uses the removed names. Historical review,
plan, changelog, and ADR prose may still mention them:

```bash
rg -n "deterministicAwakeableId|legacyDeterministicAwakeableId" keiro/src keiro-dsl/src keiro-dsl/test jitsurei/src jitsurei/app
```

The remaining matches must be limited to intentionally migrated compatibility tests if those
tests retain the old text in descriptions; no generated Haskell or first-party application
source may import or call either function.

Validate the ADR bundle and the full repository:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```


## Validation and Acceptance

Acceptance requires all of the following observable behavior.

The ordinary `Keiro.Workflow.Awakeable` module no longer exports either old deterministic
function. The compatibility module reproduces the existing ASCII and non-ASCII golden UUIDs,
and the runtime still adopts both current-encoding and pre-UTF-8 generation-0 rows. A fresh
allocation differs from the generation-0 candidate, signalling the candidate returns `False`,
signalling the returned id returns `True`, and the workflow completes.

Generated `WorkflowRuntime` modules expose opaque declared await bindings and
`allocateDeclaredAwait`; they do not expose a `WorkflowId -> Text -> AwakeableId` function and
do not import the compatibility module. A generated-name collision is detected during planning
before any file is written. Existing patch and await-label facts remain unchanged apart from
the deliberate API replacement.

`keiro-dsl-conformance-workflow-runtime` uses a migrated fresh PostgreSQL resource and proves
the full allocate-to-complete lifecycle. `cabal test keiro-dsl-test`, the regenerated corpus
policy, strict ADR validation, and `just verify` all pass. No UUID golden, journal step prefix,
row schema, or generation-0 adoption behavior changes.


## Idempotence and Recovery

The source edits and tests are ordinary, repeatable repository operations. Corpus regeneration
is deterministic; rerun `just corpus-regen` after every generator adjustment and review the
resulting diff. PostgreSQL conformance uses fresh test resources, so a failed run can be retried
without manual cleanup.

Do not change the bytes fed into UUIDv5 or update a failing golden to make the test green. If a
golden moves, revert the derivation change and share the existing implementation instead. If
generated naming collides, fix the planning/refusal logic rather than picking an untracked
one-off spelling. No migration or destructive data operation belongs in this plan.


## Interfaces and Dependencies

The compatibility surface at the end of Milestone 1 is:

```haskell
module Keiro.Workflow.Awakeable.Compatibility
  ( generation0AwakeableId
  , preUtf8Generation0AwakeableId
  ) where

generation0AwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId
preUtf8Generation0AwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId
```

Both functions are compatibility probes only. `Keiro.Workflow.Awakeable.awakeableNamed` keeps
its current public signature and remains the only fresh named allocation primitive:

```haskell
awakeableNamed
  :: (Workflow :> es, Store :> es, IOE :> es, FromJSON a)
  => StepName
  -> Eff es (AwakeableId, Eff es a)
```

Each generated `WorkflowRuntime` module exposes this shape; the `AwaitBinding` constructor is
not exported:

```haskell
data AwaitBinding

reservationConfirmationAwait :: AwaitBinding

allocateDeclaredAwait
  :: (Workflow :> es, Store :> es, IOE :> es, FromJSON a)
  => AwaitBinding
  -> Eff es (AwakeableId, Eff es a)
```

Use the existing `effectful`, `aeson`, `keiro`, `keiro-test-support`, `kiroku-store`, and
PostgreSQL test-fixture dependencies already present in the workspace. Do not add a new external
library. `docs/plans/261-make-the-durable-workflow-example-and-guides-prove-the-live-contract.md`
hard-depends on these interfaces and must be revised if implementation discovers a better name
or shape; record that change in both plans and the parent MasterPlan before proceeding.
