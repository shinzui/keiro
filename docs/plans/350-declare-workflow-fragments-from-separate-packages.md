---
id: 350
slug: declare-workflow-fragments-from-separate-packages
title: "Declare workflow fragments from separate packages"
kind: exec-plan
created_at: 2026-11-21T13:20:05Z
intention: "intention_01m7z470rse23bcq287t5xzvg7"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-21T13:20:05Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-21T14:17:20Z
      mode: "update"
      note: "Add topology export under schema id /3 and a workflow benchmark guard as the first milestone; renumber milestones"
---

# Declare workflow fragments from separate packages

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A Keiro durable workflow journals each step under a label, and replay finds a step's
recorded result by that label. `keiro-dsl` protects those labels: a workflow's body is
declared in a `.keiro` file, `keiro-dsl check` rejects a duplicate label, and
`keiro-dsl diff` reports a renamed, removed, reordered or retyped label as a breaking
change. That protection stops at the file that declares the workflow. When a separately
built package runs code inside someone else's workflow and journals its own steps there,
its labels are declared nowhere, and renaming one is a breaking change the gate reports as
no change.

This plan implements
[IR-61](../improvement-requests/declare-workflow-fragments-from-separate-packages.md),
filed by `mori://shinzui/shikigami`. After it:

1. A workflow can declare an *extension point*, a named place in its body where other
   packages' steps run.
2. Another package can declare a *fragment*: the steps, awaits, sleeps, children and patch
   gates its code journals at one extension point of a named workflow. The fragment lives in
   a `.keiro` file in the package that owns the code, and nobody edits the host's files.
3. `keiro-dsl diff` classifies a change to a fragment's body exactly as it classifies the
   same change to a workflow body, and names the fragment.
4. A *composition* file lists one host and the fragment sources one executable links.
   `keiro-dsl check` on it rejects a label declared twice across the host and the fragments.
5. `Keiro.Workflow.Recording.recordWorkflow` runs a workflow body with no database and
   returns the labels it journaled, in order, so a package's unit test can assert that its
   code journals exactly what its fragment declares.
6. `keiro-dsl topology` exports extension points and fragments under a new schema id,
   `keiro-dsl/service-topology/3`, and `keiro-ops` can mount such a document.
7. A seventh benchmark guard, `workflow`, measures the durable workflow interpreter. It is
   added before any runtime edit, so this plan's own change to the runtime is measured
   against the code as it was.

To see it working after the last milestone, from the repository root:

```bash
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workflow-fragments/agent.keiro-composition
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workflow-fragments/agent-collision.keiro-composition
nix develop -c cabal test keiro-test --test-options='--match "Workflow recording"'
nix develop -c cabal run -v0 keiro-dsl -- topology keiro-dsl/test/fixtures/topology/workflow-fragments.keiro
nix develop -c just bench-regression workflow
```

The first prints `OK`. The second exits non-zero and names `FragmentLabelCollision` with
both files. The third passes without the test body touching PostgreSQL. The fourth prints a
document whose `schema` is `keiro-dsl/service-topology/3`. The fifth ends with
`GUARD(workflow)=0` and `BENCH_REGRESSION=PASSED`.


## Progress

- [ ] Milestone 1: a `workflow` benchmark family exists in `keiro-bench`, and
  `just bench-regression workflow` passes against the commit that introduced it.
- [ ] Milestone 2: `recordWorkflow` runs a body of two steps and one await with no store and
  returns the three labels in order (IR-61 AC-3); the `workflow` guard still passes.
- [ ] Milestone 3: candidate Language 6 parses, pretty-prints and validates `extension` body
  items and `fragment` nodes, and refuses both in Language 5.
- [ ] Milestone 4: `keiro-dsl diff` gives a fragment body the same findings as a workflow
  body, attributed to the fragment, and treats a new extension point as additive (IR-61
  AC-2).
- [ ] Milestone 5: `keiro-dsl check` and `keiro-dsl diff --since` accept a
  `.keiro-composition` file and report cross-package label collisions (IR-61 AC-1).
- [ ] Milestone 6: `keiro-dsl scaffold` emits a `FragmentFacts` module, and a committed
  conformance suite proves a hand-written body journals what its fragment declares.
- [ ] Milestone 7: `keiro-dsl topology` emits extension points and fragments under
  `keiro-dsl/service-topology/3`, existing documents stay byte-identical, and `keiro-ops`
  mounts a `/3` document.
- [ ] Milestone 8: user documentation, changelogs, ADRs, and IR-61 marked completed;
  `just verify` passes.


## Surprises & Discoveries

Findings from validating IR-61 against the working tree before this plan was written. Each
one shaped the design.

- The IR says the unseen labels are invisible to "check, diff and replay-impact". The
  replay-impact report never covered workflow labels at all:
  `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` contains no reference to workflows and its
  module header scopes it to stored aggregate logs. The acceptance criteria do not mention
  replay-impact, so this plan leaves it alone.

- `diff` treats a workflow body as an ordered list and has one conservative rule. In
  `classifyWorkflowBody` (`keiro-dsl/src/Keiro/Dsl/Diff.hs`), any difference that is not a
  removed patch, a changed `continueAsNew` seed, or a change wholly contained in a new
  `patch` is one `WorkflowBodyChanged` breaking finding. So "added, removed, reordered or
  retyped" in AC-2 all map to that one code, and *adding* an unguarded step is breaking too.
  Under that rule, adding an `extension` item to a host body would itself be breaking unless
  the differ learns that an extension point journals nothing.

- The recording interpreter can't make the store-backed helpers store-free. `step`,
  `awaitStep`, `patch`, `freshOrdinal` and `continueAsNew` need only the `Workflow` effect.
  `Keiro.Workflow.Sleep.sleep`, `Keiro.Workflow.Awakeable.awakeableNamed` and
  `Keiro.Workflow.Child.spawnChild`/`awaitChild` carry a `Store :> es` constraint in their
  types, and `awakeableNamed` writes a row inside a `step`. A body that calls them still
  needs a `Store` handler in scope to type-check. AC-3's test uses `step` and `awaitStep`
  only, which is also all the Shikigami pack journals.

- Journal keys are not always the declared labels. `step L` and a raw `awaitStep L` journal
  under `L`. A declared `await L` allocated through the generated `allocateDeclaredAwait`
  journals `awkid:L` and then `awk:<uuid>`. `sleep L` journals `sleep:L`, `patch P` journals
  `patch:P`, and `child L` journals `child:<child workflow id>`, which does not contain `L`.
  The recorder therefore reports raw journal keys, and the generated facts list each kind
  separately so a test compares what is comparable.

- Workspace member paths must stay inside the manifest's directory tree, because
  `diff --since` rebuilds the old side with `git show <ref>:<path>`
  ([ADR-14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)).
  A fragment in another package, possibly another repository, can't be a workspace member.

- No benchmark measures the workflow interpreter, and the guard driver can't simply be
  pointed at one. `scripts/bench_guard.py` compares every family with one pinned source,
  `REFERENCE = b8695a0d…`, whose `keiro/bench/Main.hs` has no workflow benchmark. A new
  family needs its own reference source: the commit that adds the benchmark.

- A topology schema id is enforced in three places inside this repository: the id selector
  `topologySchemaId` in `keiro-dsl/src/Keiro/Dsl/Topology.hs`, the JSON Schemas under
  `docs/user/schemas/`, and the vocabulary table in `keiro-ops/src/Keiro/Ops/Topology.hs`,
  which is a hand copy of the schemas' enums. The step `form` enum is closed in the schema
  too, so a new step form needs a new id just as a new node kind does.

- The IR's evidence still holds at 0.26.0.0. `Keiro.Workflow` exports `Workflow` without
  constructors and its only runners need `Store`. In Shikigami, `packs/flow-pack-examples`
  ships `test/golden/labels.txt`, and `domain/shikigami/agent-run.keiro` declares
  `shikigami.agent-run` in Language 6. Shikigami pins keiro 0.22.0.0, so it must upgrade to
  use this.


## Decision Log

- Decision: A fragment is a new top-level node in the `.keiro` grammar, not a new file
  format.
  Rationale: An ordinary `.keiro` file already gets the language preamble, feature gating,
  `check`, `pretty`, `inspect`, single-file `diff --since`, workspace membership and source
  citations. A pack with its own workspace can keep the fragment in a member. The cost is a
  new `Node` constructor that every total match must handle, which the compiler enumerates.
  Date: 2026-11-21

- Decision: A fragment names its host by the workflow's stable name string
  (`of "shikigami.agent-run"`), not by the workflow's block identifier.
  Rationale: The stable name is the journal stream name and the only identity two
  repositories share. A block identifier is local to one spec.
  Date: 2026-11-21

- Decision: A fragment carries a block identifier and a stable `name "…"`, as a workflow
  does. The stable name is the label prefix when the extension point says `prefixed`.
  Rationale: Generated module names need a Haskell identifier, and the prefix needs a
  wire-word. Shikigami's packs already prefix labels with the pack name.
  Date: 2026-11-21

- Decision: Fragment-local rules run on the fragment's own file with no host present. Rules
  that need the host run when the host is in the same spec or when a composition is checked.
  Rationale: A pack in another repository must be able to run `check` and `diff` in its own
  gate. Collision, extension-point existence, the prefix rule and `sleep` delay fields need
  the host, which is only readable where an executable composes them.
  Date: 2026-11-21

- Decision: Composition is a separate `.keiro-composition` file naming one host and any
  number of fragment sources. Its paths may contain `..`. The host's workspace manifest is
  not extended.
  Rationale: The host repository must not list packs, which is the boundary the IR exists to
  protect, and ADR-14 forbids member paths that leave the manifest's tree. `check` works on
  any readable path. `diff --since` on a composition requires every unit to be inside the
  composition file's git repository and refuses otherwise with the advice to diff each unit
  in its own repository.
  Date: 2026-11-21

- Decision: A new extension point in a host body is additive, a removed one is breaking, and
  a changed `prefixed` flag is advisory. A new fragment declaration is additive. A deleted
  fragment declaration is breaking. A fragment source dropped from or added to a composition
  is advisory.
  Rationale: An extension point journals nothing itself. A new fragment's labels are in no
  existing journal. A deleted fragment may still have labels in flight, like a deleted
  workflow. Membership of a composition is the executable's choice, and the IR states that a
  fragment absent from a composition is not a removal from the host.
  Date: 2026-11-21

- Decision: Fragment body changes reuse the existing codes `WorkflowBodyChanged`,
  `WorkflowPatchRemoved` and `WorkflowEvolutionGuardAdded`, produced by the same function
  that classifies a workflow body.
  Rationale: AC-2 requires the same finding. One function makes that true by construction,
  and existing `--gate` and `--deny-codes` settings apply unchanged.
  Date: 2026-11-21

- Decision: A fragment may not contain `continueAsNew` or `extension`, and an `extension`
  item may appear only at the top level of a host body, not inside a `patch`.
  Rationale: Rotation belongs to the host. Nested extension and patch-scoped extension have
  no requester, and both can be admitted later without breaking a valid source.
  Date: 2026-11-21

- Decision: The recorder lives in the `keiro` package as `Keiro.Workflow.Recording`, and the
  `Workflow` effect's constructors stay unexported.
  Rationale: The IR accepts either a recording interpreter or exported constructors. An
  interpreter keeps the effect abstract, so the runtime can add operations without breaking
  consumers. The effect declaration moves to a hidden module so both interpreters can see
  it. The durable interpreter's code doesn't change.
  Date: 2026-11-21

- Decision: The recorder takes a preloaded journal. A step or await whose key is preloaded
  returns that value without running its action, as a replay would.
  Rationale: `awaitStep` can return a value only if one was recorded. Preloading lets a test
  walk past an await and lets it stub a step whose action needs a real dependency. An await
  with no preloaded value ends the recording as suspended without running the arming action,
  because arming actions write to the store.
  Date: 2026-11-21

- Decision: The service topology exports extension points and fragments under a new schema
  id, `keiro-dsl/service-topology/3`. It adds the node kind `workflow-fragment`, the
  relation `extends`, and the step form `extension`. It is emitted only for a document that
  contains one of them; every other document keeps its `/1` or `/2` bytes. This replaces an
  earlier decision to omit them.
  Rationale: The user asked for topology support on 2026-11-21.
  [ADR-62](../adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)
  requires a new id for a new node kind, relation or closed-set member, and the lowest
  sufficient id for each document. `/3` is `/2` plus the three additions, so a document
  with both a `feeds` edge and a fragment is representable.
  Date: 2026-11-21

- Decision: An `extends` edge is emitted only when the host workflow is declared in the same
  document. A fragment node always carries the host's stable name in its `host` field.
  `keiro-dsl topology` refuses a composition file.
  Rationale: A topology document describes one service, and an edge must name two nodes of
  that document. A fragment in another package has no host node to point at, so a consumer
  joins documents on `host` equal to a workflow's `stableName`. A cross-service document
  would be a new contract nobody has asked for.
  Date: 2026-11-21

- Decision: keiro-ui is not changed by this plan. `mori://shinzui/keiro-ui` rejects a `/3`
  document until it learns the id, which is the fail-closed behavior ADR-62 specifies.
  Rationale: It is another repository. No service it displays today declares a fragment.
  The console's side is planned in
  `mori://shinzui/keiro-ui/plans/31-show-workflow-fragments-and-extension-points-from-service-topology-schema-3`,
  which starts once Milestone 7 here is implemented and copies this plan's two `/3` golden
  documents. Milestone 8 records the handoff.
  Date: 2026-11-21

- Decision: Add a `workflow` benchmark family and make it the seventh release guard, with
  its own pinned reference source: the commit that adds the benchmark, made before any
  runtime edit. The five existing families keep their reference and the 1.25 ceiling is
  unchanged.
  Rationale: The user asked for benchmarks on 2026-11-21, after this plan had to say that
  nothing measured the workflow path. The existing reference source has no workflow
  benchmark, so the family can't share it. Pinning the pre-change commit makes the guard
  measure exactly this plan's runtime change, and every later one.
  [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
  names six guards and one reference, so it is updated in the same milestone.
  Date: 2026-11-21

- Decision: The `workflow` family measures the durable interpreter only. The recorder gets
  no benchmark cell, and the `keiro-dsl` parser is measured before and after the grammar
  change with the existing `keiro-dsl-parser-bench`, without a new gate.
  Rationale: A guarded cell must exist in the reference source, and the recorder does not
  exist there. The parser benchmark has no gate today; one before-and-after reading is
  enough to show the new alternatives cost nothing measurable.
  Date: 2026-11-21

- Decision: Milestone 6 (generated `FragmentFacts`) is in scope although no acceptance
  criterion names it.
  Rationale: The IR's Acceptance section says a pack would replace its golden label file
  with a fragment declaration and one unit test. That test needs the declared labels as
  Haskell values, and Shikigami does not link `keiro-dsl`. The user may drop this milestone;
  the three criteria are met without it.
  Date: 2026-11-21

- Decision: A `signal` operation still resolves only against awaits in the workflow's own
  body. A fragment's await is signalled by hand-written code.
  Rationale: An operation in the host spec can't name a label owned by a package the host
  doesn't know. Not requested by IR-61.
  Date: 2026-11-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`. Run
every build and test inside the Nix development shell, from the root: `nix develop -c
<command>`. Entering the shell from a package directory creates a stray PostgreSQL cluster
there.

### Vocabulary

*keiro* (`keiro/`) is the runtime library. *keiro-dsl* (`keiro-dsl/`) is a build-time tool
that parses `.keiro` specification files, validates them (`check`), compares two versions
(`diff`), and generates Haskell (`scaffold`).

A *durable workflow* is an `effectful` computation over the `Workflow` effect, run by
`runWorkflow` in `keiro/src/Keiro/Workflow.hs`. `step name action` runs `action` and appends
its JSON result to the workflow's journal under `name`; on a later run it returns the
recorded result instead. `awaitStep name arm` returns the recorded result if present, and
otherwise runs `arm` and suspends the run. `patch id` journals a Boolean branch decision
under `patch:<id>`. The *journal* is an event stream in PostgreSQL, reached through the
`Store` effect. A *journal key* is the text a result is recorded under.

A *workflow body* in a `.keiro` file is the ordered list after the `body` keyword:

```text
workflow AgentRun
  name "shikigami.agent-run"
  in RunJob
  out AgentRunResult
  id from input via runJobWorkflowId
  body
    step ingest-job -> RunJob
    await approval -> ApprovalResult
    patch adaptive-delivery-v1 {
      step adaptive-admission -> AdaptiveAdmissionResolution
    }
```

`AgentRun` is the *block identifier*. `"shikigami.agent-run"` is the *stable name*, which
names the journal stream. Each line under `body` is a *body item*, a constructor of
`WfBodyItem` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`: `WfStep`, `WfAwait`, `WfSleep`,
`WfChild`, `WfPatch`, `WfContinueAsNew`. Result type names after `->` are compared as text
and are not resolved against declarations.

A *language version* is the number in a source's first line, `language keiro-dsl N`.
Versions 1 to 5 are frozen. Version 6 is the *candidate* that new syntax lands in. Each
grammar addition is a constructor of `LanguageFeature` in
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, and `profileV5` is the feature set of
Language 6. Using a feature in an older language fails with
`LanguageFeatureRequiresVersion`.

A *workspace* is a `.keiro-workspace` manifest listing `.keiro` *member* files that are
validated and diffed as one service (`keiro-dsl/src/Keiro/Dsl/Workspace.hs`).

The *conformance corpus* is the set of directories `keiro-dsl/test/conformance-*`. Each
holds committed scaffold output and a `Main.hs`, compiled and run as a Cabal test suite.
`keiro-dsl/test/README.md` explains how to add one.

This plan adds four terms. An *extension point* is a body item `extension <point>` in a
host workflow. A *fragment* is a top-level node listing the body items one package journals
at one extension point. A *unit* is one `.keiro` file or one workspace. A *composition* is a
`.keiro-composition` file naming one host unit and the fragment units an executable links.

### Where workflows are handled today

- `keiro/src/Keiro/Workflow.hs` declares `data Workflow :: Effect` with constructors `Step`,
  `Await`, `CurrentWorkflow`, `CurrentRunGeneration`, `CurrentWorkflowTracer`,
  `FreshOrdinal`, `ContinueAsNew`, `Patch`. The export list names `Workflow` without
  constructors. `runWorkflowWith` holds the only interpreter, `handler`, which reads and
  appends through `Store`.
- `keiro/src/Keiro/Workflow/Types.hs` defines `StepName`, `PatchId`, `WorkflowName`,
  `WorkflowId`, `patchStepName`, and the reserved prefixes `sleep:`, `awk:`, `awkid:`,
  `child:`, `patch:`.
- `keiro-dsl/src/Keiro/Dsl/Parser/Workflow.hs` has `pWorkflow` and its local `pWfBodyItem`.
  `pWorkflow` takes no `FrontendContext` today; feature-gated parsers such as
  `pOptionalInputSource` in `keiro-dsl/src/Keiro/Dsl/Parser/Coordination.hs` take one and
  call `optionalLanguageFeature`. `keiro-dsl/src/Keiro/Dsl/Parser/Document.hs` dispatches
  top-level nodes.
- `keiro-dsl/src/Keiro/Dsl/Validate.hs` has `validateWorkflow`, the helpers
  `workflowLabelledItems`, `workflowPatchItems` and `workflowContinueItems`, the
  `DiagnosticCode` type, and a table that classifies every code.
- `keiro-dsl/src/Keiro/Dsl/Diff.hs` has `workflowDiff`, `workflowPairDiff`,
  `classifyWorkflowBody`, `normaliseWorkflowBody`, the family table (`familyOf`,
  `FamWorkflow`), and the helpers `breaking`, `additive`, `advisoryAt`.
- `keiro-dsl/src/Keiro/Dsl/WorkspaceDiff.hs` adds `declared:` file citations to findings
  through the workspace's `OwnershipIndex`.
- `keiro-dsl/src/Keiro/Dsl/Harness.hs` has `harnessWorkflow`, `emitWorkflowFacts` and
  `emitWorkflowRuntime`, which generate `WorkflowFacts.hs` and `WorkflowRuntime.hs`.
- `keiro-dsl/app/Main.hs` holds the CLI. `runWorkspaceDiff` and `gitContentSource` show how
  `diff --since` reads the old side from git. `isWorkspacePath` dispatches on the file
  extension.
- `keiro-dsl/src/Keiro/Dsl/Topology.hs` builds the topology document. `NodeKind` and
  `Relation` are closed enumerations, `workflowSteps` renders body items as objects with a
  `form` and a `label`, and `topologySchemaId` picks `/2` when the document has a `feeds`
  edge and `/1` otherwise. Schemas are
  `docs/user/schemas/keiro-dsl-service-topology-{1,2}.schema.json`; golden documents are
  `keiro-dsl/test/fixtures/topology/*.topology.golden.json` with compatibility examples in
  `keiro-dsl/test/fixtures/topology/schema-examples/`; `scripts/check-topology-schemas.sh`
  (`just topology-schema-validate`) validates each golden against the schema its `schema`
  field names. `keiro-ops/src/Keiro/Ops/Topology.hs` holds a per-id vocabulary table and
  refuses to mount a document with an id, kind or relation it does not list; its tests are
  `keiro-ops/test/TopologySpec.hs` and `keiro-ops-http/test/Test/TopologySpec.hs`.
- `keiro/bench/Main.hs` is the `keiro-bench` benchmark (tasty-bench), grouped by family:
  `outbox`, `inbox`, `command`, `rebuild`, and more in sibling modules such as
  `keiro/bench/ReadModelBench.hs`. `scripts/bench-regression.sh` runs the six guards
  (`producer-identity`, `outbox`, `inbox`, `command`, `projection`, `read-model`).
  `scripts/bench_guard.py` runs one CSV family: it builds the pinned `REFERENCE` commit in
  `dist-newstyle/benchmark-reference`, measures reference and candidate on this machine with
  `-p <family>`, and fails a case whose mean ratio exceeds 1.25. `keiro/bench/baseline-<family>.csv`
  is the required list of case names. `scripts/release_workflow.py` lists the guards in
  `GUARDS` and requires a receipt for each. `keiro/bench/REGRESSION.md` documents the rules.
- Other total matches on `Node` or `WfBodyItem` that a new constructor must satisfy are in
  `PrettyPrint.hs`, `Topology.hs`, `Manifest.hs`, `NominalType.hs`, `ScaffoldRun.hs`,
  `WorkspaceScaffold.hs`, `ServiceHarness.hs`, `Frontend/Internal.hs` and `Workspace.hs`
  (`HasLocs`), all under `keiro-dsl/src/Keiro/Dsl/`.

Existing tests to model new ones on: `keiro-dsl/test/Keiro/Dsl/InputSourceSpec.hs` (a spec
module registered in `keiro-dsl/test/Main.hs` and in the `keiro-dsl-test` stanza of
`keiro-dsl/keiro-dsl.cabal`), the workflow diff cases near "classifies workflow relabeling
and appends as WorkflowBodyChanged" in `keiro-dsl/test/Main.hs`,
`keiro-dsl/test/diff-test.sh`, and the suite `keiro-dsl/test/conformance-workflow-full/`.
`keiro/test/WorkflowInspectionSpec.hs` shows how a spec module is registered in
`keiro/test/Main.hs` and `keiro/keiro.cabal`.

### The consumer

Shikigami runs every agent as the workflow `shikigami.agent-run`. Its plan
`mori://shinzui/shikigami/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check`
moves flows into *flow packs*, separate Cabal packages whose code runs inside that workflow.
The first pack journals `examples-classify` and seven capability labels. Until this plan
ships, each pack keeps a sorted golden file of its labels and a test that starts PostgreSQL
to derive them. The rule is recorded in ADR 0129 of `mori://shinzui/shikigami`, at
`docs/adr/0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md`
(its artifact-level URI is pending).

### Architecture decision records consulted

- [ADR-14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
  makes a workspace a file whose members stay inside its directory tree so git can rebuild
  them. This plan keeps that rule and adds a separate composition file.
- [ADR-16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
  keeps each source's language beside its `Spec`. Units in a composition keep their own.
- [ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md)
  makes Language 6 the candidate that new syntax lands in.
- [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) gates
  evolution at the earliest sound boundary. Fragment-local diff in the owning repository is
  that boundary for a fragment.
- [ADR-62](../adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)
  owns the topology document: a new node kind, relation or closed-set member needs a new
  schema id, each document carries the lowest id that can represent it, and `keiro-ops`
  must learn an id before a host can mount it. Milestone 7 adds `/3` under those rules and
  amends the ADR.
- [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
  requires release benchmarks to be fixed workloads compared with an attributed, immutable
  reference source measured on the current machine. Milestone 1 adds a seventh guard under
  those rules and amends the ADR.
- [ADR-20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) and
  [ADR-22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
  govern generated module names and the conformance facade. `FragmentFacts` follows the
  `WorkflowFacts` naming and stays out of the facade.
- [ADR-5](../adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md)
  describes the durable await path the recorder deliberately does not reproduce.

No existing ADR covers workflow extension, fragments, or a store-free interpreter.
Milestone 8 writes one.


## Plan of Work

### Milestone 1: measure the durable workflow interpreter

This milestone adds benchmarks and no runtime change. It comes first because its first
commit becomes the fixed point every later runtime change is compared with. At the end
`just bench-regression workflow` passes.

Add `keiro/bench/WorkflowBench.hs`, listed in the `keiro-bench` stanza of
`keiro/keiro.cabal`, and add its group to the list `defaultMain` receives in
`keiro/bench/Main.hs`. The group is named `workflow`, uses a store acquired the way the
neighbouring groups acquire theirs, and runs with default `WorkflowRunOptions` (no tracer,
no metrics, no snapshots). Its cases are fixed workloads, each asserting its own result
inside the benchmark action so a broken run fails instead of timing nonsense:

- `workflow.fresh.steps-16`: a new workflow id each iteration runs sixteen trivial steps to
  `Completed`. This measures the miss path: sixteen journal appends and the completion
  marker.
- `workflow.replay.steps-16`: one workflow completed during setup is run again each
  iteration. This measures journal load and the hit path, with no append.
- `workflow.suspend.await-1`: a new workflow id each iteration runs one step and one
  `awaitStep` with a no-op arming action and ends `Suspended`.
- `workflow.patch.steps-4`: a new workflow id each iteration runs with one active patch,
  one `patch` decision and four steps.

Use raw `step`, `awaitStep` and `patch` from `Keiro.Workflow`, not the sleep, awakeable or
child helpers, so the cases measure the interpreter and not the wake-source tables.

Record `keiro/bench/baseline-workflow.csv` on a quiet machine with the options
`scripts/bench_guard.py` passes in `measure`, in the three-column format of
`keiro/bench/baseline-command.csv`. Commit the benchmark and the CSV together and note the
commit's full hash. This is the *workflow reference commit*. It must contain no change
under `keiro/src/`.

In a second commit, wire the guard:

- `scripts/bench_guard.py`: replace the single `REFERENCE` with a reference per family. The
  five existing families keep `b8695a0d050c5b0db2f251887d43182da2b47eed`; `workflow` uses
  the workflow reference commit. Add `workflow` to `GROUPS`. `reference_binary` takes the
  source as an argument, and the cache key, metadata and `reference_source` in the result
  already carry it. Change no ceiling, timeout or confirmation rule.
- `scripts/bench-regression.sh`: add `workflow` to the default list, the `case`, and the
  usage comment.
- `scripts/release_workflow.py`: add `workflow` to `GUARDS`.
- `scripts/tests/test_bench_guard.py` and the `scripts/tests/test_release*.py` suites: add
  a case proving a family is built from its own reference, and update any expectation of
  six guards.
- `keiro/bench/REGRESSION.md` and the `bench-regression` comment in `justfile`: seven
  groups, and the per-family reference.
- [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md):
  amend the decision to seven guards and a reference per family, advance its `timestamp`,
  and add an `okf log add` entry.

`scripts/bench_guard.py` fetches a reference commit from `origin` when it is missing
locally. The workflow reference commit therefore has to be pushed before a release gate
runs in another clone. Do not push as part of this plan; say so in the handoff.

### Milestone 2: record a workflow body's labels without a store

This milestone changes only the `keiro` package and satisfies AC-3. At the end, a test runs
a body in `runPureEff` and reads back its labels, and the `workflow` guard from Milestone 1
still passes.

Move the declaration of `data Workflow :: Effect` and its `type instance DispatchOf` from
`keiro/src/Keiro/Workflow.hs` into a new module `keiro/src/Keiro/Workflow/Effect.hs`, listed
under `other-modules` in `keiro/keiro.cabal`. `Keiro.Workflow` imports it and keeps
exporting `Workflow` without constructors. Do not edit `runWorkflowWith` or `handler`.

Add the exposed module `keiro/src/Keiro/Workflow/Recording.hs` with the interface given in
Interfaces and Dependencies. Its interpreter keeps a map from journal key to JSON value,
seeded from the options, and a list of labels in encounter order:

- `Step`: if the key is in the map, decode and return the stored value without running the
  action. Otherwise run the action, store its `toJSON`, and return the decoded stored value,
  matching the durable interpreter's round trip.
- `Await`: if the key is in the map, decode and return it. Otherwise end the recording as
  suspended on that key. Never run the arming action.
- `Patch`: the key is `patchStepName pid`. If absent, the decision is membership of the
  options' active patch set; store it.
- `FreshOrdinal`: a per-namespace counter from zero, as in the durable interpreter.
- `CurrentWorkflow` and `CurrentRunGeneration`: from the options. `CurrentWorkflowTracer`:
  `Nothing`.
- `ContinueAsNew`: end the recording as continued, carrying the encoded seed.

Record a label for every `Step`, `Await` and `Patch` encountered, marked `replayed` when the
key was already in the map. A decode failure throws the same `WorkflowStepDecodeError` the
durable interpreter throws. The function needs no `Store`, no `Error StoreError` and no
`IOE` constraint.

Add `keiro/test/WorkflowRecordingSpec.hs` under a top-level `describe "Workflow recording"`,
registered in `keiro/test/Main.hs` and `keiro/keiro.cabal`. Run every body with
`runPureEff` so the type proves no store is involved. Cases: two steps and one preloaded
await return three labels in order and complete; the same body with no preloaded value
returns two labels and suspends on the await; a repeated step key runs its action once; an
active and an inactive patch record `patch:<id>` and return `True` and `False`; a preloaded
step does not run its action; `continueAsNew` ends as continued.

Add a `keiro/CHANGELOG.md` entry under `[Unreleased]`, and a short section in
`docs/user/durable-workflows.md` stating what the recorder does not model: arming actions,
the step-index fallback, leases, cancellation, and helpers that need `Store`.

Then run `just bench-regression workflow` on a quiet machine. It compares this tree with
the workflow reference commit, which predates the move of the effect declaration.

### Milestone 3: the `extension` item and the `fragment` node

At the end, a Language 6 source may declare both, `check` and `pretty` handle them, and a
Language 5 source that uses either is refused.

Before editing the parser, run `cabal bench keiro-dsl-parser-bench` and keep its output;
run it again when the milestone's tests pass. Record both sets of means in Surprises &
Discoveries. If any case is more than 1.25 times slower on two adjacent runs, find the
cause before continuing; the usual one is a `try` that makes an existing alternative
backtrack.

In `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` add `WorkflowFragmentSyntax` to
`LanguageFeature` and to `profileV5`. It covers both spellings.

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs` add a body item
`WfExtension !Name !ExtensionRule !Loc`, where `ExtensionRule` is `ExtensionOpen` or
`ExtensionPrefixed`, and a node `NFragment FragmentNode`:

```haskell
data FragmentNode = FragmentNode
  { id :: !Name,      -- block identifier, e.g. ExamplesFlows
    stable :: !Text,  -- name "examples"
    host :: !Text,    -- of "shikigami.agent-run"
    point :: !Name,   -- at flows
    body :: ![WfBodyItem],
    loc :: !Loc
  }
```

In `keiro-dsl/src/Keiro/Dsl/Parser/Workflow.hs`, lift `pWfBodyItem` to the top level so
both parsers share it, pass the `FrontendContext` in, and gate the new spellings with the
helper `pOptionalInputSource` uses. The surface syntax is:

```text
workflow AgentRun
  name "fixture.agent-run"
  in RunJob { runId:Id }
  out RunResult
  id from input.runId via idText
  body
    step open-session -> SessionId
    extension flows prefixed
    step record-finish -> RecordedFinish

fragment ExamplesFlows
  name "examples"
  of "fixture.agent-run" at flows
  body
    step examples-classify -> Classification
    await examples-review -> ReviewDecision
    patch examples-audit-v1 {
      step examples-audit -> AuditRecord
    }
```

`extension <point>` takes an optional `prefixed`. The fragment's `name` uses the wire-word
spelling of a step label. Register `pFragment` in
`keiro-dsl/src/Keiro/Dsl/Parser/Document.hs`. Add both to
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` so `pretty` output parses back to the same `Spec`.

In `keiro-dsl/src/Keiro/Dsl/Validate.hs` add these codes to `DiagnosticCode` and to its
classification table, and wherever the repository lists codes (search for an existing code
such as `WorkflowPatchDuplicate` under `docs/`, `keiro-dsl/test/` and `scripts/`):

- `WorkflowExtensionDuplicate`: two extension points of one workflow share a name.
- `WorkflowExtensionNotTopLevel`: an `extension` item inside a `patch`.
- `FragmentItemNotAllowed`: `continueAsNew` or `extension` inside a fragment.
- `FragmentDuplicateName`: two fragments in one spec share a stable name and host.
- `FragmentHostUnresolved`: used by composition check in Milestone 5.
- `FragmentExtensionPointUnresolved`: the host has no extension point of that name.
- `FragmentLabelCollision`: a fragment label is declared by the host body or by another
  fragment of the same host.
- `FragmentPatchCollision`: the same for patch ids.
- `FragmentLabelPrefixRequired`: the point is `prefixed` and a label or patch id does not
  start with `<fragment stable name>-`.

Reuse `WorkflowDuplicateLabel`, `WorkflowPatchDuplicate`, `WorkflowPatchIdInvalid` and
`WorkflowSleepDelayUnresolved` for the same faults inside one fragment.

Split validation into two functions so Milestone 5 can reuse the second. `validateFragment
:: FragmentNode -> [Diagnostic]` holds the rules that need no host. `validateFragmentsAgainstHost
:: WorkflowNode -> [FragmentNode] -> [Diagnostic]` holds point existence, collisions across
the host body and every fragment of that host, the prefix rule, and `sleep` delay fields
against the host's input fields. Labels are unique per workflow, across all its extension
points, because they share one journal. `validateService` runs the second function for each
workflow whose stable name some fragment in the same spec names. A fragment whose host is
not in the spec passes on local rules alone.

Satisfy every other total match the compiler reports. Until Milestone 6, scaffolding emits
no module for a fragment and declares no dependency for it. `WorkflowFacts.body` renders an
extension item as `extension:<point>`. Until Milestone 7, in
`keiro-dsl/src/Keiro/Dsl/Topology.hs`, an extension item yields no step entry and a
fragment yields no node and no edge, so no existing golden changes. In
`keiro-dsl/src/Keiro/Dsl/Diff.hs`, give `NFragment` a family marked out of scope with the
reason "classified in the next milestone", so this milestone compiles on its own.

Add fixtures under `keiro-dsl/test/fixtures/workflow-fragments/`: `host/agent-run.keiro`
(the workflow above, with field types copied from `keiro-dsl/test/fixtures/workflow.keiro`),
`pack-a/examples.keiro` (the fragment above under `context examples-pack`),
`pack-b/reports.keiro` (a second fragment named `reports`), `in-spec.keiro` (host and
fragment in one file), and one negative file per new code that a single spec can trigger.
Add `keiro-dsl/test/Keiro/Dsl/WorkflowFragmentSpec.hs` and register it as
`InputSourceSpec.hs` is registered. Assert that each positive fixture checks clean, each
negative fixture yields exactly its code on the expected line, `pretty` round-trips, and a
Language 5 copy fails with `LanguageFeatureRequiresVersion`.

### Milestone 4: classify fragment changes in `diff`

At the end AC-2 holds for two specs compared in memory and for single-file `diff --since`.

In `keiro-dsl/src/Keiro/Dsl/Diff.hs`, extract the body of `classifyWorkflowBody` into a
function over a node name, a facet prefix and two item lists. `classifyWorkflowBody` calls
it with facet prefix `workflow`. Before comparing, handle extension items on the workflow
side: one present only in the new body is removed from the comparison and reported as
additive `WorkflowExtensionPointAdded`; one present only in the old body is breaking
`WorkflowExtensionPointRemoved`; one whose rule changed is compared as equal and reported as
advisory `WorkflowExtensionRuleChanged`. A moved extension point is a reorder and stays
`WorkflowBodyChanged`. Add the three codes.

Replace the out-of-scope family with a real one that pairs fragments by block identifier:

- Added: additive `DeclarationAdded`, "new fragment".
- Removed: breaking `WorkflowBodyChanged` with facet `fragment`, saying in-flight journals
  of the host may still replay its labels.
- Matched, body differs: the shared function with the fragment's block identifier as the
  node and facet prefix `fragment`. The detail names the fragment's stable name and host.
- Matched, `host` differs: breaking `WorkflowBodyChanged`, the labels now journal in
  another workflow.
- Matched, `point` differs: breaking `WorkflowBodyChanged`, the same as a reorder.
- Matched, stable name differs: advisory.

Because the node of each finding is the fragment's block identifier,
`keiro-dsl/src/Keiro/Dsl/WorkspaceDiff.hs` already cites the fragment's file on the
`declared:` line. Confirm that with a test rather than changing it.

Extend `WorkflowFragmentSpec.hs` with old and new sources built from the fixtures. For each
of rename, remove, reorder, retype and add of one step in `ExamplesFlows`: the findings
contain a breaking `WorkflowBodyChanged` whose node is `ExamplesFlows`, the same code the
same edit yields when applied to the host body, and no finding whose node is `AgentRun` or
the second fragment. Also assert: a change wrapped in a new `patch` is additive
`WorkflowEvolutionGuardAdded`; a removed patch is `WorkflowPatchRemoved`; adding
`extension flows` to a host is additive and nothing else; removing it is breaking; a new
fragment node is additive; a deleted one is breaking. Extend `keiro-dsl/test/diff-test.sh`
with one case that renames a fragment step in a temporary git repository and expects a
non-zero exit.

### Milestone 5: compose a host with fragments from other directories

At the end AC-1 holds through the CLI.

Add `keiro-dsl/src/Keiro/Dsl/Composition.hs`, exposed. It owns the file format, loading,
validation and diff. The format is line-oriented like the workspace manifest, with `#`
comments:

```text
# The agent executable's composition.
composition fixture-agent
host host/agent-run.keiro
fragments pack-a/examples.keiro
fragments pack-b/reports.keiro
```

`composition <name>` comes first and appears once. `host <path>` appears exactly once.
`fragments <path>` appears any number of times and is a set, sorted canonically. Each path
is relative to the composition file's directory, may contain `..`, may not be absolute, and
names a `.keiro` file or a `.keiro-workspace` manifest. The extension is
`.keiro-composition`, tested case-insensitively as `isWorkspacePath` does.

Loading reads each unit through the existing single-file and workspace loaders with a
`ContentSource`, so the same code serves the working tree and a git ref. A unit that fails
its own check is reported with its own diagnostics and paths, and composition validation
does not run.

Validation gathers every workflow of the host unit and every fragment of every unit,
including the host unit. A fragment whose host stable name is not a workflow of the host
unit is `FragmentHostUnresolved`. For each host workflow it runs
`validateFragmentsAgainstHost` from Milestone 3. Each diagnostic carries the file and line
of the offending item and, for a collision, a second location for the other declaration,
rendered in the shape workspace diagnostics use:

```text
keiro-dsl/test/fixtures/workflow-fragments/pack-b/reports-collision.keiro:7: error[FragmentLabelCollision]: ...
  keiro-dsl/test/fixtures/workflow-fragments/pack-a/examples.keiro:6: note: also declared here
```

Diff compares two loaded compositions. A unit present on both sides is diffed with
`diffWorkspaces`, treating a single file as a one-member workspace. A fragment unit present
on one side only yields one advisory `CompositionMembershipChanged` and no finding about
its contents. A changed `host` path is an advisory of the same code and the two hosts are
still diffed.

In `keiro-dsl/app/Main.hs`, dispatch `check` and `diff` on the new extension. `check` prints
diagnostics and `OK`, with the usual exit status. `diff --since <ref>` resolves every unit
path against the git repository of the composition file. If any unit is outside it, exit
non-zero with a message that names the unit and says to run `diff` on each unit in its own
repository and `check` on the composition. If the composition file does not exist at the
ref, build the old side from the current unit list at the ref, and treat a unit missing
there as absent. Output uses `renderWorkspaceFinding`, and the exit status follows the
existing gate rules, including `--gate`, `--explain` and `--deny-codes`. Options that are
defined per service (`--report-out`, `--replay-impact-out`, `--emit-goldens`, the coverage
options, and `check`'s report options) are refused on a composition with a message saying
to run them on each unit. Other subcommands, including `topology`, refuse a composition
file by name.

Add fixtures `agent.keiro-composition` (host plus both packs),
`agent-collision.keiro-composition` (uses `pack-b/reports-collision.keiro`, which declares
a label of pack A), `agent-host-collision.keiro-composition` (a fragment declaring
`open-session`), `agent-unprefixed.keiro-composition`, `agent-missing-point.keiro-composition`
and `agent-unresolved-host.keiro-composition`. Test the parser, loading, each diagnostic
with both locations, and the diff rules in `WorkflowFragmentSpec.hs` with in-memory content
sources. Extend `keiro-dsl/test/diff-test.sh` with a composition whose units live in one
temporary repository: renaming a step in pack A fails and cites `pack-a/examples.keiro`;
deleting the `fragments pack-b/…` line passes with one advisory.

### Milestone 6: generated fragment facts and an end-to-end proof

At the end a package can compare what its code journals with what its fragment declares,
using only generated code and `keiro`.

In `keiro-dsl/src/Keiro/Dsl/Harness.hs` add `harnessFragment` and `emitFragmentFacts`,
modelled on `harnessWorkflow` and `emitWorkflowFacts`. The module is
`<generated prefix for the fragment's block identifier>.FragmentFacts`, depends on `base`
only, and exports a record with `name`, `host`, `point`, `body` (rendered as
`WorkflowFacts.body` renders), and the lists `steps`, `awaits`, `sleeps`, `children` and
`patches`, each in declaration order and including items inside patches. Wire it into
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` where `harnessWorkflow` is called, and treat
the `.FragmentFacts` suffix wherever `.WorkflowFacts` is listed by suffix. Keep fragments
out of the service conformance facade in `keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs`.

Add the suite `keiro-dsl/test/conformance-workflow-fragment/` following
`keiro-dsl/test/README.md`: scaffold `pack-a/examples.keiro` into it, and write a `Main.hs`
with a hand-written body for the fragment that runs under
`Keiro.Workflow.Recording.recordWorkflow`. It asserts that the recorded step keys equal
`steps`, that the recorded `patch:` keys equal `patches` with the prefix added, and that a
deliberately misnamed step makes the comparison fail. Add its Cabal stanza and its entry in
`keiro-dsl/test/conformance-baseline.json`.

### Milestone 7: export extension points and fragments in the service topology

At the end `keiro-dsl topology` describes both, under a new schema id, and every document
that has neither is byte-identical to what it was.

In `keiro-dsl/src/Keiro/Dsl/Topology.hs`:

- Add `WorkflowFragmentKind` to `NodeKind`, spelled `workflow-fragment`. A fragment's node
  is named by its block identifier and carries `stableName`, `host` (the host's stable
  name), `point`, and `steps` rendered by `workflowSteps`.
- Add `Extends` to `Relation`, spelled `extends`. Emit one edge from a fragment to a
  workflow, with the attribute `point`, when a workflow in the same document has the stable
  name the fragment names. Emit no edge otherwise.
- `workflowSteps` renders an extension item as a step object with `form` `extension`,
  `label` the point name, and `rule` `open` or `prefixed`.
- `topologySchemaId` returns `keiro-dsl/service-topology/3` when the document has a
  `workflow-fragment` node or an `extension` step, and otherwise decides as it does today.
  `allNodeKinds` and `allRelations` are derived from the enumerations; check every place
  that uses them to describe `/1` or `/2`, so the older vocabularies do not silently grow.

Add `docs/user/schemas/keiro-dsl-service-topology-3.schema.json` as a copy of the `/2`
schema with the id constant, the node kind, the relation, the node's field definitions and
the step form added, and list it in `docs/user/schemas/index.md`. Leave the `/1` and `/2`
schema files unchanged.

Add golden sources and documents under `keiro-dsl/test/fixtures/topology/`:
`workflow-fragments.keiro` (a host with an extension point and a fragment of it, so the
document has an `extends` edge) and `workflow-fragment-only.keiro` (a fragment whose host is
elsewhere, so it has none), each with its `.topology.golden.json`. Add to
`keiro-dsl/test/fixtures/topology/schema-examples/` a `/3` example that must validate and
two that must not: a `/2` document containing a `workflow-fragment` node, and a `/2`
document containing an `extension` step. Follow the naming the existing examples use.

Extend `keiro-dsl/test/Keiro/Dsl/TopologySpec.hs`: the two new goldens match; a host with
an extension point and no fragment is `/3`; a document with a `feeds` edge and a fragment
is `/3` and keeps the edge; every pre-existing golden is unchanged and keeps its id; and
the document is invariant under reordering declarations, as the existing invariance test
states it.

In `keiro-ops/src/Keiro/Ops/Topology.hs` add the `/3` entry to the vocabulary table: the
`/2` kinds plus `workflow-fragment`, and the `/2` relations plus `extends`. Extend
`keiro-ops/test/TopologySpec.hs` and `keiro-ops-http/test/Test/TopologySpec.hs` so a `/3`
golden mounts and is served with its exact bytes, and a `/2` document carrying a
`workflow-fragment` node is refused.

Amend
[ADR-62](../adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)
with a paragraph for `/3` beside the ones for `/1` and `/2`, advance its `timestamp`, and
add an `okf log add` entry.

### Milestone 8: documentation, records and handoff

Update `docs/user/keiro-dsl-workflows-and-operations.md` (extension points, fragments, the
prefix rule, the three things a composing executable must do: check the composition, add
each fragment's `patches` to `WorkflowRunOptions.activePatches`, and signal fragment awaits
itself), `docs/user/keiro-dsl-cli.md` (the composition file and which options it refuses),
`docs/user/keiro-dsl-validation-and-evolution.md` (the new codes and verdicts),
`docs/user/keiro-dsl-reference.md` (grammar), and `docs/user/keiro-dsl-service-topology.md`
(schema id `/3`, the new kind, relation and step form, when an `extends` edge is present,
and how to join a fragment to a host in another document). Add `keiro-dsl/CHANGELOG.md`
entries, listing the new `Node`, `WfBodyItem`, `DiagnosticCode`, `LanguageFeature`,
`NodeKind` and `Relation` constructors as breaking for exhaustive matches, and a
`keiro-ops/CHANGELOG.md` entry for mounting `/3`.

Write a new ADR under `docs/adr/` with the handle `okf id next` returns. It records: a
fragment is a node and a composition is a separate file; host-free rules run locally and
host rules run at composition; the verdict table from the Decision Log; and the recorder
keeps the effect abstract and does not model the store. It links to ADR-62 for the
topology vocabulary and to ADR-58 for the workflow guard.

State the keiro-ui handoff in Outcomes & Retrospective and in the IR log entry:
`mori://shinzui/keiro-ui` must accept `keiro-dsl/service-topology/3` before it can show a
service that declares an extension point or a fragment. Do not edit that repository. Its
plan is
`mori://shinzui/keiro-ui/plans/31-show-workflow-fragments-and-extension-points-from-service-topology-schema-3`.
That plan assumes the vocabulary and golden file names of Milestone 7; if either changed
during implementation, say so in the handoff.

Set `status: completed` and `plan:` in
`docs/improvement-requests/declare-workflow-fragments-from-separate-packages.md`, advance
its `timestamp`, and add a `docs/improvement-requests/log.md` entry that states the
deviations from the request: replay-impact is unchanged, store-backed helpers still need a
`Store`, and cross-repository `diff --since` runs per unit. When work starts in Milestone
1, set `status: in-progress`, add the `plan:` field, and log that.

Run `just verify`. Fill in Outcomes & Retrospective.


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/keiro`. Confirm the shell first:

```bash
nix develop -c z3 --version
git status --short
```

Build after each milestone's edits:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
```

Milestone 1. Run benchmarks on a quiet machine, with no compiler or test suite alongside:

```bash
nix develop -c cabal bench keiro-bench --benchmark-options="-p workflow -j1 --time-mode wall --hide-progress +RTS -N2 -RTS"
# Record keiro/bench/baseline-workflow.csv, commit benchmark and CSV, then:
git rev-parse HEAD
git diff --stat HEAD~1 -- keiro/src
# Wire the guard with that hash, then:
nix develop -c python3 -m unittest discover -s scripts/tests -p test_bench_guard.py
nix develop -c python3 -m unittest discover -s scripts/tests -p 'test_release*.py'
nix develop -c just bench-regression workflow
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Expected: the benchmark lists four `workflow.` cases; `git diff --stat` prints nothing; the
unit tests pass; the guard ends with:

```text
GUARD(workflow)=0
BENCH_REGRESSION=PASSED
```

Exit status 2 and `BENCH_REGRESSION=INCONCLUSIVE` mean the machine was too noisy. Rerun on
a quiet machine; do not loosen a threshold.

Milestone 2:

```bash
nix develop -c cabal test keiro-test --test-options='--match "Workflow recording"' --test-show-details=direct
git diff --stat -- keiro/src/Keiro/Workflow.hs
nix develop -c just bench-regression workflow
```

Expected: every `Workflow recording` example passes. The diff of `Keiro/Workflow.hs` shows
only the removed effect declaration and the added import. The guard passes as in
Milestone 1.

Milestones 3 and 4:

```bash
nix develop -c cabal bench keiro-dsl-parser-bench   # once before the parser edits, once after
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workflow-fragments/in-spec.keiro
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workflow-fragments/pack-a/examples.keiro
nix develop -c cabal run -v0 keiro-dsl -- pretty keiro-dsl/test/fixtures/workflow-fragments/in-spec.keiro
nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-show-details=direct
nix develop -c bash keiro-dsl/test/diff-test.sh
nix develop -c just topology-schema-validate
```

Expected: both checks print `OK`; `pretty` prints the `extension flows prefixed` line and
the `fragment ExamplesFlows` block; the suite, the script and the schema gate exit zero.
`diff-test.sh` is not part of `just verify`; run it by hand as shown.

Milestone 5:

```bash
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workflow-fragments/agent.keiro-composition
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workflow-fragments/agent-collision.keiro-composition
```

Expected: the first prints `OK`. The second exits 1 with a `FragmentLabelCollision` line
for `pack-b/reports-collision.keiro` and a note line for `pack-a/examples.keiro`.

Milestone 6:

```bash
nix develop -c cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/workflow-fragments/pack-a/examples.keiro --out keiro-dsl/test/conformance-workflow-fragment
# Write Main.hs, add the Cabal stanza and the baseline entry, commit, then:
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- regenerate
git status --short -- keiro-dsl/test
nix develop -c cabal test keiro-dsl:test:keiro-dsl-conformance-workflow-fragment --test-show-details=direct
nix develop -c scripts/check-conformance-corpus.sh
```

Expected: regeneration changes no committed file anywhere in the corpus, and the suite
prints only passing lines. The scaffold ledger and Cabal-fragment text files may need
`git add -f`, as `keiro-dsl/test/README.md` describes.

Milestone 7:

```bash
nix develop -c cabal run -v0 keiro-dsl -- topology keiro-dsl/test/fixtures/topology/workflow-fragments.keiro
nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-show-details=direct
nix develop -c just topology-schema-validate
nix develop -c cabal test keiro-ops-test keiro-ops-http-test
git status --short -- keiro-dsl/test/fixtures/topology docs/user/schemas
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Expected: the document's `schema` is `keiro-dsl/service-topology/3` and it contains a
`workflow-fragment` node, an `extends` edge and a step with `form` `extension`. The suites
and the schema gate exit zero. `git status` lists only new files: the `/3` schema, the two
new sources with their goldens, and the new examples. A modified existing golden or schema
is a defect.

Milestone 8:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
nix develop -c just user-documentation-validate
nix develop -c just dsl-api-boundaries
nix develop -c just verify
```

`just verify` stops at the first failure, so read its exit status, not only its last lines.

Commit at each milestone with Conventional Commits and both trailers:

```text
feat(workflow): record a workflow body's labels without a store

Move the Workflow effect declaration to a hidden module and add
Keiro.Workflow.Recording.recordWorkflow, an interpreter that keeps the
journal in memory and returns the labels a body journals in order.

ExecPlan: docs/plans/350-declare-workflow-fragments-from-separate-packages.md
Intention: intention_01m7z470rse23bcq287t5xzvg7
```


## Validation and Acceptance

IR-61's criteria map to observable checks.

AC-1, declare and compose without editing the host. `agent.keiro-composition` names a host
in `host/` and fragments in `pack-a/` and `pack-b/`; no file under `host/` mentions either
pack. `check` on it prints `OK`. `check` on `agent-collision.keiro-composition` and on
`agent-host-collision.keiro-composition` exits non-zero with `FragmentLabelCollision`,
naming both declarations.

AC-2, same findings, attributed. The Milestone 4 tests apply one edit to a fragment and the
same edit to a host body and assert equal code and severity, with the fragment's block
identifier as the node and no finding for the host or the other fragment. The Milestone 5
script shows the `declared:` line citing the fragment's file.

AC-3, labels without PostgreSQL. `WorkflowRecordingSpec` runs a body with two steps and one
await in `runPureEff` and asserts the three keys in order.

Topology. `keiro-dsl topology` on `workflow-fragments.keiro` prints a `/3` document with the
fragment node, the `extends` edge and the extension step, the document validates against
the `/3` schema, and `keiro-ops` mounts it. Every pre-existing golden keeps its bytes.

Benchmarks. `just bench-regression workflow` passes after Milestone 1, where candidate and
reference are the same runtime, and again after Milestone 2, where they differ by the
effect move.

The early producer and consumer check is Milestone 6's suite: generated `FragmentFacts`
from the DSL on one side, `recordWorkflow` from the runtime on the other, and a hand-written
body between them. If the two disagree about what a label is, that suite fails first.

### Guarantees that must not weaken

- Durable workflow behavior and replay. The interpreter in `runWorkflowWith` is not edited;
  only the effect's declaration site moves. Evidence: the `git diff --stat` in Milestone 2,
  the existing workflow examples in `keiro-test` including `WorkflowReplayCompatibilitySpec`
  and `WorkflowInspectionSpec`, and `just replay-compatibility`.
- Workflow performance. The gate that measures this path is the `workflow` guard added in
  Milestone 1: `just bench-regression workflow`, and from then on `just release-gate`. It
  compares the fresh, replay, suspend and patch paths of `runWorkflow` with the workflow
  reference commit at the 1.25 mean-ratio ceiling. It does not measure sleep, awakeable or
  child wake sources, snapshots, tracing or metrics; this plan does not edit those. If the
  implementation has to touch `handler`, record that in the Decision Log; the guard still
  measures it.
- Existing benchmark guards. The five CSV families keep their reference source, cases and
  ceiling, and `producer-identity` is untouched. Evidence: `scripts/tests/test_bench_guard.py`
  and a full `just bench-regression` before the plan is closed.
- Journal wire bytes. Journal keys, the journal codec and `Keiro.Workflow.Types` are
  untouched. Evidence: `keiro-test` and `just replay-compatibility`.
- Existing diff verdicts and gating. A spec with no extension item and no fragment must
  produce the same findings as before. Evidence: the existing diff examples in
  `keiro-dsl-test`, the existing cases in `keiro-dsl/test/diff-test.sh`, and unchanged
  mutation scripts such as `keiro-dsl/test/workflow-mutation-test.sh`.
- Exactness of fragment classification. A fragment body and a workflow body go through one
  function. Evidence: the paired assertions in Milestone 4.
- Generated bytes. Corpus regeneration in Milestone 6 changes no existing committed file.
  `WorkflowFacts.body` changes only for a workflow that declares an extension point.
- Fold identity and snapshots. Aggregate fold fingerprints and snapshot discriminators are
  not touched. Evidence: unchanged fold and snapshot suites in `keiro-dsl:tests`, and the
  no-change corpus regeneration.
- Topology bytes. Every existing golden keeps its bytes and its schema id, and the `/1` and
  `/2` schema files are not edited. Only a document with a fragment or an extension point
  is `/3`. Evidence: `just topology-schema-validate`, `Keiro.Dsl.TopologySpec`, the
  `git status` check in Milestone 7, and the `/2` examples that must fail validation.
- Topology mounting. `keiro-ops` still refuses an id, kind or relation outside the id's
  vocabulary. Evidence: `keiro-ops/test/TopologySpec.hs`, including the refused `/2`
  document carrying a `workflow-fragment` node.
- Frozen languages. Languages 1 to 5 accept and reject the same sources as before.
  Evidence: the Language 5 negative fixtures.

Milestones 1, 6 and 7 go beyond the IR's three criteria. Milestone 6 was the author's
addition; Milestones 1 and 7 were requested by the user. See the Decision Log.


## Idempotence and Recovery

Every step is an edit to tracked files or a read-only command, so all can be repeated.
Milestones are ordered so the tree builds after each: Milestone 3 gives the new node an
out-of-scope diff family, no scaffold output and no topology output, and later milestones
replace those.

The workflow reference commit is immutable once the guard names it. If the benchmark needs
a correction after that, do not amend or rebase the commit: make the correction in a new
commit, point the `workflow` reference at a commit that contains the corrected benchmark
and still predates every `keiro/src/` change of this plan, and re-record the CSV. If no
such commit exists any more, record in the Decision Log that the reference now includes
Milestone 2, and what was measured instead.

A reference build lives under `dist-newstyle/benchmark-reference` and is checksum-verified.
If the guard reports a cache integrity failure, delete that one cache directory and rerun.

Scaffolding into `keiro-dsl/test/conformance-workflow-fragment` is safe to rerun. If corpus
regeneration changes files outside that directory, a shared emitter changed by accident:
revert with `git checkout -- keiro-dsl/test` and find the cause before continuing.

`keiro-dsl/test/diff-test.sh` builds its repositories under a temporary directory; follow
its existing cleanup. Do not run `git` commands that rewrite this repository's history.

If moving the effect declaration causes an import cycle, keep
`keiro/src/Keiro/Workflow/Effect.hs` free of any import from `Keiro.Workflow` and have it
import only `Keiro.Workflow.Types`, `Keiro.Telemetry` (for `Tracer`), `Effectful` and
`aeson`.


## Interfaces and Dependencies

No new package dependency is needed. `keiro` already depends on `effectful-core`, `aeson`
and `containers`.

`keiro/src/Keiro/Workflow/Recording.hs` exports this interface. Field names may follow the
package's record conventions, but the shapes are fixed:

```haskell
module Keiro.Workflow.Recording
  ( RecordingOptions (..),
    defaultRecordingOptions,
    RecordedKind (..),
    RecordedLabel (..),
    RecordingEnd (..),
    Recording (..),
    recordWorkflow,
    recordedKeys,
  )
where

data RecordingOptions = RecordingOptions
  { workflowName :: !WorkflowName,
    workflowId :: !WorkflowId,
    generation :: !Int,
    activePatches :: !(Set PatchId),
    -- | Journal keys already recorded, as a replay would find them.
    journal :: !(Map Text Aeson.Value)
  }

-- | Generation 0, no active patches, an empty journal.
defaultRecordingOptions :: WorkflowName -> WorkflowId -> RecordingOptions

data RecordedKind = RecordedStep | RecordedAwait | RecordedPatch

data RecordedLabel = RecordedLabel
  { kind :: !RecordedKind,
    -- | The raw journal key, e.g. "examples-classify" or "patch:examples-audit-v1".
    key :: !Text,
    -- | True when the key was already journaled when this operation ran.
    replayed :: !Bool
  }

data RecordingEnd a
  = RecordingCompleted a
  | RecordingSuspended !StepName
  | RecordingContinuedAsNew !Aeson.Value

data Recording a = Recording
  { end :: !(RecordingEnd a),
    -- | Every step, await and patch the body reached, in order.
    labels :: ![RecordedLabel]
  }

recordWorkflow :: RecordingOptions -> Eff (Workflow : es) a -> Eff es (Recording a)

-- | Distinct keys in first-encounter order.
recordedKeys :: Recording a -> [Text]
```

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` gains `WfExtension`, `ExtensionRule`, `FragmentNode`
and `NFragment` as shown in Milestone 3. `keiro-dsl/src/Keiro/Dsl/Validate.hs` exports
`validateFragment` and `validateFragmentsAgainstHost`. `keiro-dsl/src/Keiro/Dsl/Diff.hs`
keeps exporting `classifyWorkflowBody` with its current type.

`keiro-dsl/src/Keiro/Dsl/Composition.hs` exports at least:

```haskell
data CompositionManifest = CompositionManifest
  { name :: !Text,
    host :: !FilePath,
    fragments :: ![FilePath]   -- canonical order
  }

parseCompositionManifest :: FilePath -> Text -> Either ParseError CompositionManifest
isCompositionPath :: FilePath -> Bool
loadComposition :: ContentSource -> FilePath -> IO (Either CompositionFailure Composition)
checkComposition :: Composition -> [CompositionDiagnostic]
diffCompositions :: Composition -> Composition -> Either FoldSurfaceError [WorkspaceChange]
```

A `Composition` holds the manifest and each unit as a `WorkspaceSpec` keyed by its path.
`ContentSource`, `WorkspaceSpec` and `oneMemberWorkspace` come from
`Keiro.Dsl.Workspace`; `WorkspaceChange` comes from `Keiro.Dsl.DiffReport`.

The generated `FragmentFacts` module exports a record `FragmentFacts` with fields `name`,
`host`, `point`, `body`, `steps`, `awaits`, `sleeps`, `children`, `patches`, all `String` or
`[String]`, and a value `fragmentFacts`.

`scripts/check-keiro-dsl-api-boundaries.py` and the frontend surface tests under
`keiro-dsl/test/Keiro/Dsl/` keep inventories of exposed modules and constructors. Update
whichever inventory they report as stale rather than narrowing the new exports.

The topology document gains, under `keiro-dsl/service-topology/3` only: the node kind
`workflow-fragment` with fields `stableName`, `host`, `point` and `steps`; the relation
`extends` from a `workflow-fragment` to a `workflow`, with the attribute `point`; and the
step form `extension` with `label` and `rule` (`open` or `prefixed`). `/3` contains
everything `/2` does. `Keiro.Ops.Topology` in `keiro-ops` lists the same vocabulary for
`/3`.

`scripts/bench_guard.py` maps each family to its reference source, and
`scripts/bench-regression.sh` and `scripts/release_workflow.py` name seven guards:
`producer-identity`, `outbox`, `inbox`, `command`, `projection`, `read-model`, `workflow`.
The `workflow` family's case names are `All.workflow.fresh.steps-16`,
`All.workflow.replay.steps-16`, `All.workflow.suspend.await-1` and
`All.workflow.patch.steps-4`, following the `All.<family>.…` naming in the existing CSVs.


## Revision Notes

- 2026-11-21: At the user's request, topology export moved into scope and benchmarks were
  added. Topology was previously omitted; it is now Milestone 7 under a new schema id
  `/3`, with the `keiro-ops` vocabulary and ADR-62 amended. A `workflow` benchmark family
  and seventh release guard are the new Milestone 1, placed first so its commit is the
  reference the runtime change is measured against, with ADR-58 amended. The earlier
  milestones were renumbered 2 to 6 and documentation became Milestone 8. The performance
  guarantee now names a measuring gate instead of relying on unchanged code.
