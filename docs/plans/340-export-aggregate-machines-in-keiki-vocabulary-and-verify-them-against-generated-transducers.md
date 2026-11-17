---
id: 340
slug: export-aggregate-machines-in-keiki-vocabulary-and-verify-them-against-generated-transducers
title: "Export aggregate machines in keiki vocabulary and verify them against generated transducers"
kind: exec-plan
created_at: 2026-11-17T14:55:55Z
intention: "intention_01m7n03hbfem79q2brf07rneyq"
master_plan: "docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-17T14:55:55Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-17T15:26:59Z
      mode: "update"
      note: "Correct schema handoffs, compatibility checks and fixture acceptance after repository review"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T16:30:22Z
      mode: "implement"
      note: "EP-3 implemented: machine export, shared edge-index rule, keiki conformance suite, schema and docs"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-17T15:26:59Z
      verdict: "comments"
      note: "Reviewed and corrected local coordination and acceptance; Mori outage prevents external API and ADR verification"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-17T15:42:49Z
      verdict: "approved"
      note: "Follow-up: Mori works with corrected Codex environment; keiki APIs, sibling fixtures and ADR verified; local findings corrected"
---

# Export aggregate machines in keiki vocabulary and verify them against generated transducers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl` is the command-line tool in this repository that reads `.keiro` service
specifications and generates Haskell. A prior plan,
`docs/plans/338-emit-a-versioned-service-topology-document-from-keiro-dsl-topology.md`, added
`keiro-dsl topology`, which prints a JSON document (schema id
`keiro-dsl/service-topology/1`) of a service's parts and the relations between them. In that
document an aggregate node lists only the names of its states, commands and events.

Every Keiro aggregate is built on keiki, a sibling library (`mori://shinzui/keiki`). In keiki
an aggregate is a "transducer": a finite state machine in which each edge leaves one state,
consumes one command, emits zero or more events and enters a target state. A process manager
keeps its own progress in a "saga" aggregate, so a process manager is a keiki machine too.
Keiki gives each edge an identity (its source state and its position among that state's
edges, called the edge index) and a mode: `Live` edges serve new commands, while `ReplayOnly`
edges exist only so that old events can still be replayed.

After this plan, each aggregate node in the topology document carries a `machine` object in
that vocabulary: its states, which is initial, which are terminal, and every edge with its
source, edge index, target, mode, command and emitted events. A reader can follow a process
node's `saga` edge to the saga aggregate and read the process manager's machine there.

The export is computed from the specification alone, without compiling the service. To make
that trustworthy, this plan adds a conformance suite that compiles generated code, walks the
real keiki transducers with keiki's own accessors, and fails if the exported machine differs
in any state or edge. You can see it working by running that suite, then breaking the export
on purpose (for example by reversing the edge order in the builder) and watching it fail.

This plan is child EP-3 of
`docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md`.
The decision to verify against keiki rather than produce the machine by running service code
was made by the user on 2026-11-17 and is recorded there.


## Progress

- [x] Milestone 1 (2026-11-17): a temporary `Main.hs` in
      `keiro-dsl/test/conformance-process-full/` walked `surgeTransducer` and
      `hospitalTransducer` with `edgesOut`, `target`, `mode`, `edgeInputName` and `wcName`;
      the walk equalled the specification's transitions (Surge: Watching→Noted→Fired!,
      Hospital: Idle→Surging!), and the file was restored. The non-adjacent case was then
      read in scaffold: `transitionLayout` in `keiro-dsl/src/Keiro/Dsl/AggregateGenerationPlan.hs`
      already numbers transitions per source state and the builder emits one `B.from` block
      per source in first-occurrence order, so the rule needed no adjustment. Milestone 3
      proves it on a fixture with non-adjacent same-source transitions.
- [x] Milestone 2 (2026-11-17): every aggregate node carries `machine`; regenerating the four
      goldens changed them only by added `machine` objects (checked by decoding the old and
      new documents and removing `machine`). `behaviorEdgeIndex` now reads `outgoingIndex`
      from `transitionLayout`, the one shared rule. Three unit tests in
      `keiro-dsl/test/Keiro/Dsl/TopologySpec.hs` cover edge order, `legacy-hole` ownership
      and presence on every aggregate.
- [x] Milestone 3 (2026-11-17): `keiro-dsl-conformance-topology-machine` prints
      `machine Order: 4 states, 6 edges match keiki`, `machine OrderSaga: 2 states, 3 edges
      match keiki` and the coverage line, and fails with both machines printed when the
      builder reverses each state's edges (transcript under Surprises). The corpus
      `keiro-dsl/test/conformance-topology-machine/` regenerates through
      `keiro-dsl-corpus-regen` with no drift.
- [x] Milestone 4 (2026-11-17): DOC-35 has an "Aggregate machines" section; the `/1` schema
      has an optional `machine` whose fields are all required when present;
      `keiro-dsl/test/fixtures/topology/schema-examples/` holds an older document without
      `machine` (must validate) and a malformed machine (must be rejected), both checked by
      `just topology-schema-validate`. The `/2` schema does not exist yet; EP-4 creates it
      from this `/1` schema, so it inherits `machine`.


## Surprises & Discoveries

- The edge-index rule already existed twice: `transitionLayout`
  (`keiro-dsl/src/Keiro/Dsl/AggregateGenerationPlan.hs`, used to emit the `B.from` blocks)
  and a separate count in `behaviorEdgeIndex`. Both now use `transitionLayout`, which the
  topology export also calls, so the builder layout and the exported index cannot diverge.

- A Language 6 fixture whose state names concatenate with the aggregate name into an event
  name is rejected (`VertexCtorCollision`: state `Placed` of `Order` generates `OrderPlaced`).
  The fixture uses states `Draft Open InTransit Done!`.

- Scaffold ledgers match the global `.gitignore` pattern `keiro-dsl-ledger.*.txt`; corpus
  ledgers must be added with `git add -f`, or `keiro-dsl-corpus-regen` reports
  "--only path is not in the corpus plan" because it discovers corpora from tracked ledgers.

- Evidence that the proof can fail, with `entry <- reverse layout` in `aggregateMachine`
  (reverted afterwards):

  ```text
  machine Order: exported machine differs from keiki
  exported:
  {"edges":[{"command":"NoteOrder","edgeIndex":1,…,"source":"Draft","target":"Draft"},{"command":"PlaceOrder","edgeIndex":0,…},…
  keiki:
  {"edges":[{"command":"PlaceOrder","edgeIndex":0,…,"source":"Draft","target":"Open"},{"command":"NoteOrder","edgeIndex":1,…},…
  Test suite keiro-dsl-conformance-topology-machine: FAIL
  ```


## Decision Log

- Decision: `machine` is an added field of the aggregate node's `details` within schema id
  `keiro-dsl/service-topology/1`.
  Rationale: The contract's compatibility policy allows keiro to add object fields within a
  schema id and requires consumers to ignore unknown fields.
  Date: 2026-11-17

- Decision: The machine is exported on the aggregate node only. A process node does not
  repeat it; its existing `saga` edge leads to the aggregate that carries it.
  Rationale: The saga is an ordinary aggregate declaration. Repeating the machine would
  create two copies that must agree.
  Date: 2026-11-17

- Decision: Guards, register writes and output field terms are not exported.
  Rationale: IR-62 excludes transition-body detail, and keiki's readable rendering of guards
  is a presentation contract, not a stable data contract.
  Date: 2026-11-17

- Decision: Each machine states its `ownership`: `generated` when keiro generates the
  transducer from the specification, `legacy-hole` when the aggregate uses the frozen
  Language 1 form whose whole transducer is hand-written. Only `generated` machines are
  covered by the keiki proof.
  Rationale: `docs/adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md`
  allows a legacy aggregate's machine to be written by hand, so its declared transitions
  cannot be proven to match. Saying so is more honest than omitting the machine.
  Date: 2026-11-17

- Decision: `keikiMachine` returns `Either Text MachineTopology` instead of a bare
  `MachineTopology`, and the suite compares JSON values: `machineValue` of the keiki walk
  against the `machine` object in the aggregate node's `details` from
  `buildServiceTopology`.
  Rationale: An edge whose guard names no command constructor must fail with its source and
  index rather than be given a made-up name, and comparing the exported object covers the
  encoder as well as `aggregateMachine`.
  Date: 2026-11-17

- Decision: The conformance suite compiles every module of the scaffolded corpus (the full
  Cabal fragment, adding `containers` and `kiroku-store` dependencies for the generated
  behavior contracts and process holes), so no `uncompiled-generated` exemption is needed.
  Rationale: It keeps the corpus registration to the ledger alone.
  Date: 2026-11-17

- Decision: The proof compares against keiki accessors on the real transducer
  (`edgesOut`, `target`, `mode`, `initial`, `isFinal`, the command constructor name and the
  output constructor names), not against keiki's Mermaid or inspector text.
  Rationale: The text renderers join event names for display and are documented by keiki as
  a readability contract. The accessors are the structure itself.
  Date: 2026-11-17


## Outcomes & Retrospective

Completed 2026-11-17. The topology document shows each aggregate's machine in keiki's own
terms, and a dedicated conformance suite proves the export against the compiled keiki
transducers, including a process saga. The proof compares the exported JSON object itself
(`machineValue` of the keiki walk against `details.machine` from `buildServiceTopology`), so
it covers the encoding as well as the derivation. The full `just verify` gate runs once on the
final tree (MasterPlan decision).


## Context and Orientation

All paths are relative to the repository root. Run every build and test inside the Nix
development shell from the repository root, as `AGENTS.md` requires. The Z3 solver must be
present for some `keiro-dsl` suites; confirm with `nix develop -c z3 --version`.

This plan requires the prior plan to be complete. It provides
`keiro-dsl/src/Keiro/Dsl/Topology.hs`, with `buildServiceTopology` (builds the document from
a loaded workspace), `encodeServiceTopology` (canonical bytes) and the node and edge types;
the `topology` command in `keiro-dsl/app/Main.hs`; and golden documents under
`keiro-dsl/test/fixtures/topology/`, compared by tests in `keiro-dsl/test/Main.hs` and
rewritten when the environment variable `KEIRO_DSL_UPDATE_GOLDENS=1` is set.

How the specification describes a machine. In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, the
`Aggregate` record has `states :: [StateDecl]`, where each `StateDecl` has `name` and
`terminal`, and `transitions :: [Transition]`. A `Transition` has `source`, `command`,
`emits` (event names in order), `goto` (the target state), `mode` (`TmLive` or
`TmReplayOnly`) and `implementation` (`GeneratedImplementation`, `HoleImplementation` for a
single hand-written transition body, or `LegacyHoleImplementation` for the frozen Language 1
form). The initial state is the first declared state; see `initialVertex` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`.

How generated code builds the keiki machine. For an aggregate `Surge` in a context whose
module prefix is `Generated.SurgeDemo`, scaffold emits
`Generated/SurgeDemo/Surge/Transducer.hs` exporting
`surgeTransducer :: SymTransducer (HsPred SurgeRegs SurgeCommand) SurgeRegs SurgeVertex SurgeCommand SurgeEvent`,
and `Generated/SurgeDemo/Surge/Domain.hs` defining
`data SurgeVertex = SurgeWatching | SurgeNoted | SurgeFired`, deriving `Show`, `Enum` and
`Bounded`. A vertex constructor is the aggregate name followed by the state name
(`vertexCtor` in `Scaffold.hs`), so the state name is recovered by removing the aggregate
name prefix from `show vertex`. Read
`keiro-dsl/test/conformance-process-full/Generated/SurgeDemo/Surge/Transducer.hs` as the
example. It already indexes real edges by position, in
`drop edgeIndex (K.edgesOut surgeTransducer source)`.

How keiro-dsl already predicts the edge index. `behaviorEdgeIndex` in `Scaffold.hs` computes
a transition's index as the number of earlier transitions, in declaration order, that have
the same source state. The exported machine must use the same rule; move the counting into
one shared function rather than writing it twice.

What keiki offers, in module `Keiki.Core` unless stated. `SymTransducer` has fields
`edgesOut :: s -> [Edge …]`, `initial :: s` and `isFinal :: s -> Bool`. `Edge` has `guard`,
`output :: [OutTerm …]`, `target :: s` and `mode :: EdgeMode`, with
`data EdgeMode = Live | ReplayOnly`. `Keiki.Render.Mermaid` exports
`edgeInputName :: Edge (HsPred rs ci) rs ci co s -> Maybe Text`, the name of the command
constructor the edge's guard matches. Each `OutTerm` is `OPack inCtor wireCtor fields`, and a
wire constructor's name is read with its `wcName` pattern field. Do not use
`edgeOutputName` for the comparison: it joins several event names into one display string.
Treat `edgeInputName == Nothing` as a conformance failure with the source and edge index;
do not manufacture a command name or silently omit the edge. Convert `wcName` from `String`
to `Text` without Mermaid escaping. The existing use of these accessors in this repository is
`keiro/src/Keiro/ProcessManager/Inspect.hs`, which lists `Live` edges with `edgeInputName`.
To read keiki's source, locate it with `mori registry show shinzui/keiki --full`; never
search `/nix/store`. This repository builds against `keiki >=0.9 && <0.10`.

How conformance suites work. Each is a `test-suite` stanza in `keiro-dsl/keiro-dsl.cabal`
whose source directory, for example `keiro-dsl/test/conformance-process-full/`, holds
generated modules committed to the repository, a ledger file written by scaffold, and a
hand-written `Main.hs`. The set of committed generated corpora is reproduced by a driver;
`keiro-dsl/test/README.md` explains how a corpus is registered and regenerated, and
`scripts/check-conformance-corpus.sh` (also `just conformance-corpus-policy`) fails if
regeneration changes any committed byte. Read that README before adding a corpus.

Relevant ADRs. `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`
explains replay-only edges. `docs/adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md`
explains generated and hole ownership: with `HoleImplementation` the edge itself is still
generated and only its body is hand-written, so its structure remains provable.
`docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md` requires
the new fixture to begin with `language keiro-dsl 6`.

The documentation page `docs/user/keiro-dsl-service-topology.md` and the schema
`docs/user/schemas/keiro-dsl-service-topology-1.schema.json` are created by a different
plan, `docs/plans/339-keep-committed-topology-exports-fresh-and-publish-the-service-topology-contract.md`.
They may or may not exist when this plan is implemented; Milestone 4 handles both cases.


## Plan of Work

### The `machine` object

It is added to the `details` of every aggregate node:

```json
{
  "ownership": "generated",
  "initial": "Watching",
  "states": [
    { "name": "Watching", "terminal": false },
    { "name": "Noted", "terminal": false },
    { "name": "Fired", "terminal": true }
  ],
  "edges": [
    { "source": "Watching", "edgeIndex": 0, "target": "Noted", "mode": "Live",
      "command": "NoteSurgeThreshold", "events": ["SurgeThresholdNoted"] }
  ]
}
```

`states` are in declaration order, which is the order of the generated vertex type's
constructors. `edges` are ordered by the position of their source state in `states`, then by
`edgeIndex`. `mode` is spelled exactly as keiki's `EdgeMode` constructors, `Live` or
`ReplayOnly`. `events` are in emission order and may be empty. `ownership` is `legacy-hole`
when any transition of the aggregate has `LegacyHoleImplementation`, and `generated`
otherwise.

### Milestone 1: prototype the comparison

This milestone removes the main uncertainty before any contract work: whether the edge order
predicted from the specification really equals keiki's order in generated code, including
when transitions with the same source are not adjacent in the specification. In a scratch
`Main.hs` added temporarily to the existing suite directory
`keiro-dsl/test/conformance-process-full/` (or run with `cabal repl` on that suite), walk
`surgeTransducer` and `hospitalTransducer`: for every vertex in `[minBound .. maxBound]`,
list each edge of `edgesOut` with its position, `target`, `mode`, `edgeInputName` and output
constructor names. Print the result beside the transitions of that corpus's specification
grouped by source state. Accept the approach if they agree. If they do not, record the
difference with the printed evidence in Surprises & Discoveries and adjust the ordering rule
in this plan before continuing. Remove the scratch code; nothing from this milestone is
committed except the plan update.

### Milestone 2: export the machine

In `keiro-dsl/src/Keiro/Dsl/Topology.hs`, add a `MachineTopology` type and a pure function
`aggregateMachine :: Aggregate -> MachineTopology`, and include its encoding as `machine` in
the aggregate node's details. Factor the edge-index rule shared with `behaviorEdgeIndex` into
one function used by both, placed where both modules can import it without a cycle. Add unit
tests in the `describe "service topology"` block of `keiro-dsl/test/Main.hs` for the cases in
the conformance list below, using small inline Language 6 sources.

Regenerate the golden documents with `KEIRO_DSL_UPDATE_GOLDENS=1` and read the diff. It must
consist only of `machine` objects appearing inside aggregate node details. Any other change
is a defect in this plan's edit, not an acceptable regeneration.

### Milestone 3: prove it against keiki

Create the fixture `keiro-dsl/test/fixtures/topology-machine.keiro`, a Language 6
specification with: an aggregate that has at least three states, two transitions leaving the
same state that are separated in the source by a transition leaving another state, one
`replay-only` transition, one transition that emits two events, one terminal state, and one
transition with an explicit hole implementation; a second aggregate used as a saga; and a
process whose `saga` names it and which dispatches to the first aggregate. Existing fixtures
show each form: `keiro-dsl/test/fixtures/reservation-deprecated-replay-only.keiro` for
`replay-only`, `keiro-dsl/test/fixtures/history-dependent-holes.keiro` for holes, and the
specification behind `keiro-dsl/test/conformance-process-reactions/` for a Language 6
process.

Scaffold it into a new corpus directory `keiro-dsl/test/conformance-topology-machine/` and
register the corpus as `keiro-dsl/test/README.md` describes, so that
`scripts/check-conformance-corpus.sh` reproduces it. Fill any create-once hole files the
scaffold produces with the smallest bodies that compile.

Add a `test-suite keiro-dsl-conformance-topology-machine` stanza to
`keiro-dsl/keiro-dsl.cabal`, modelled on `keiro-dsl-conformance-process-full`, with the
generated modules listed and `keiro-dsl` and `keiki` among its dependencies. Its hand-written
`Main.hs` does the following for each aggregate in the corpus. It loads and checks the
fixture with the library, builds the topology with `buildServiceTopology`, and takes that
aggregate's `MachineTopology`. It walks the generated transducer into the same shape using a
single generic function, whose signature is in Interfaces and Dependencies, that strips the
aggregate name from `show` of each vertex. It then asserts equality of the initial state, the
ordered state list with terminal flags (using `isFinal`), and the full ordered edge list. On
a mismatch it prints both machines and exits with failure. It also asserts that the corpus
really contains what it is meant to cover: at least one `ReplayOnly` edge, one edge with two
events, one state with two or more edges, and a process whose saga aggregate was compared.
That guards against the suite passing vacuously after a fixture edit.

Demonstrate that the suite can fail: temporarily change `aggregateMachine` to reverse the
edges of each state, run the suite, record the failure output in this plan's Surprises &
Discoveries or Outcomes section as evidence, and revert.

### Milestone 4: documentation and schema

If `docs/user/keiro-dsl-service-topology.md` and
`docs/user/schemas/keiro-dsl-service-topology-1.schema.json` exist, add `machine` to the page and every existing topology schema (including `/2` if the input-source
plan has landed). Keep `machine` optional so previously valid documents remain valid, but
require its fields when the object is present. Add schema tests for an older document without
`machine`, a malformed machine, and a sourced `/2` document with a machine when `/2` exists;
describe each field, state that the vocabulary and the edge index are keiki's, state that an
edge index is local to one source state and changes when transitions are reordered so it must
not be stored as a durable identifier, and state which machines the conformance suite proves.
Then run `nix develop -c just topology-schema-validate` and
`nix develop -c just user-documentation-validate`. If those files do not exist yet, write in
this plan's Progress section that documentation of `machine` is owed to
`docs/plans/339-keep-committed-topology-exports-fresh-and-publish-the-service-topology-contract.md`,
and add the same note to that plan's Progress section. Add a `keiro-dsl/CHANGELOG.md` entry
under `## [Unreleased]`.


## Concrete Steps

Work from the repository root.

```bash
nix develop -c z3 --version
nix develop -c cabal build keiro-dsl
nix develop -c cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct --test-options='--match "service topology"'
```

Regenerate and review golden documents (Milestone 2):

```bash
KEIRO_DSL_UPDATE_GOLDENS=1 nix develop -c cabal test keiro-dsl:keiro-dsl-test --test-options='--match "service topology"'
git diff --stat keiro-dsl/test/fixtures/topology
```

Run the proof and the corpus reproduction check (Milestone 3):

```bash
nix develop -c cabal test keiro-dsl:keiro-dsl-conformance-topology-machine --test-show-details=direct
nix develop -c bash scripts/check-conformance-corpus.sh
```

The suite prints one line per compared aggregate and exits zero, in this form:

```text
machine Order: 4 states, 6 edges match keiki
machine OrderSaga: 3 states, 2 edges match keiki
coverage: replay-only edge, two-event edge, multi-edge state, process saga present
```

Commit at each milestone with a Conventional Commits message and these trailers:

```text
feat(keiro-dsl): export keiki-verified aggregate machines in the topology

MasterPlan: docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md
ExecPlan: docs/plans/340-export-aggregate-machines-in-keiki-vocabulary-and-verify-them-against-generated-transducers.md
Intention: intention_01m7n03hbfem79q2brf07rneyq
```


## Validation and Acceptance

Running `keiro-dsl topology` on `keiro-dsl/test/fixtures/topology/hospital-capacity.keiro`
prints a document in which every aggregate node's `details` has a `machine` with the fields
above, and the golden tests pass.

The suite `keiro-dsl-conformance-topology-machine` passes, printing a match line for each
aggregate including the saga aggregate, and the coverage line. With the edge order
deliberately reversed in the builder it fails and prints the two differing machines; that
transcript is recorded in this plan.

Guarantees that must not weaken, with the check that measures each. The schema id of each fixture stays unchanged (`/1` for unsourced services, `/2` if
the input-source plan has already added a sourced fixture), and no existing field changes, measured by the golden diff containing only added
`machine` objects. Generated code is unchanged by sharing the edge-index function, measured
by `scripts/check-conformance-corpus.sh` reporting no drift in any existing corpus and by the
existing behavior-contract suites passing. The command path is not affected at all: no
runtime package (`keiro`, `keiro-core`) is edited by this plan.

Finally:

```bash
nix develop -c just verify
```


## Idempotence and Recovery

All steps are additive. The prototype in Milestone 1 leaves no committed code. Golden
regeneration overwrites files in place; restore with
`git checkout -- keiro-dsl/test/fixtures/topology` if the diff is not what Milestone 2
allows. The corpus check refuses to run when corpus paths have uncommitted changes, so commit
the new corpus before running it. If registering the new corpus proves incompatible with the
driver, the fallback is to point the new suite's `hs-source-dirs` at an existing Language 6
corpus that has a process saga and add the missing cases to that corpus's specification;
record the choice in the Decision Log.


## Interfaces and Dependencies

No new package. The new test suite depends on `keiro-dsl`, `keiki` (`>=0.9 && <0.10`),
`base` and `text`, plus whatever the generated modules require, copied from the stanza of
`keiro-dsl-conformance-process-full`.

In `keiro-dsl/src/Keiro/Dsl/Topology.hs`, at the end of Milestone 2:

```haskell
data MachineOwnership = MachineGenerated | MachineLegacyHole

data MachineState = MachineState { name :: Text, terminal :: Bool }

data MachineEdgeMode = MachineLive | MachineReplayOnly

data MachineEdge = MachineEdge
  { source :: Text, edgeIndex :: Int, target :: Text
  , mode :: MachineEdgeMode, command :: Text, events :: [Text] }

data MachineTopology = MachineTopology
  { ownership :: MachineOwnership, initial :: Text
  , states :: [MachineState], edges :: [MachineEdge] }

aggregateMachine :: Aggregate -> MachineTopology
```

These types need `Eq` and `Show` so the suite can compare and print them.

In `keiro-dsl/test/conformance-topology-machine/Main.hs`, at the end of Milestone 3:

```haskell
-- | Walk a real generated keiki transducer into the exported shape. The Text
-- argument is the aggregate name, removed from the front of each shown vertex.
keikiMachine ::
  (Bounded s, Enum s, Show s) =>
  Text ->
  SymTransducer (HsPred rs ci) rs s ci co ->
  MachineTopology
```

It sets `ownership` to `MachineGenerated`, since only generated machines are compared.


Review update, 2026-11-17: reconciled schema handoffs, optional-field compatibility and
acceptance comparisons without changing the four work streams. Repository APIs and local
ADR references were inspected. Follow-up Mori lookup resolved the sibling fixtures,
keiki source and `mori://shinzui/mori/okf/adrs/concepts/ADR-33`; the earlier failures came
from Codex inheriting a stale development database address, not a Mori outage. The earlier
review entry is retained as history and corrected by the follow-up review. Keiki's
`edgesOut`, `initial`, `isFinal`, `target`, `mode`, `edgeInputName` and `OPack`/`wcName`
interfaces support the planned comparison; its builder preserves declaration order within
each source state, including repeated source blocks. The two sibling specifications exist
and are legacy-unversioned, as the fixture-migration instructions expect.
