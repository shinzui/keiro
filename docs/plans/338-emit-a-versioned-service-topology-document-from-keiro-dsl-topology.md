---
id: 338
slug: emit-a-versioned-service-topology-document-from-keiro-dsl-topology
title: "Emit a versioned service topology document from keiro-dsl topology"
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
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-17T15:06:01Z
      mode: "update"
      note: "Add the projection catalog to the /1 topology contract"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-17T15:26:59Z
      mode: "update"
      note: "Correct schema handoffs, compatibility checks and fixture acceptance after repository review"
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

# Emit a versioned service topology document from keiro-dsl topology

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl` is the command-line tool in this repository that reads `.keiro` service
specifications. A specification declares the parts of a service: aggregates (event-sourced
state machines), processes (process managers that react to inputs and send commands),
workflows, routers, contracts, intakes (inbox consumers), emits and publishers (outbox
producers), work queues, dispatches, read models and operations. Today no output of the tool
says how those parts connect.

After this plan, running

```bash
keiro-dsl topology path/to/service.keiro --format json
```

prints one JSON document with schema id `keiro-dsl/service-topology/1`. It has one node for
every declaration of the twelve kinds above and of the five projection-catalog kinds
(projection targets, rebuild groups, projection owners, projection revisions and external
reads, which together say which aggregate events are written to which tables and which read
models are served from them), and one edge for every relation between them, plus a sha256
digest of each source file. The bytes are identical on every run and platform
for the same sources. The same command accepts a `.keiro-workspace` manifest, which composes
several `.keiro` files into one service.

This implements acceptance criteria AC-1 and AC-2 of the improvement request
`docs/improvement-requests/export-a-versioned-service-topology-from-keiro-dsl.md` (IR-62),
filed by the Mori project, which will ingest a committed copy of this document instead of
parsing `.keiro` files. You can see it working by running the command on the fixture
`keiro-dsl/test/fixtures/topology/hospital-capacity.keiro` and comparing with the checked-in
golden document beside it.

This plan is child EP-1 of
`docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md`.
Three later plans build on it and are not needed to implement it:
`docs/plans/339-keep-committed-topology-exports-fresh-and-publish-the-service-topology-contract.md`
(scaffold flag, freshness check, documentation, JSON Schema),
`docs/plans/340-export-aggregate-machines-in-keiki-vocabulary-and-verify-them-against-generated-transducers.md`
(state-machine detail on aggregate nodes), and
`docs/plans/341-declare-and-check-the-intake-that-feeds-a-process-or-router-input-and-export-it-as-a-topology-edge.md`
(a new relation under schema id `/2`).


## Progress

- [ ] Milestone 1: the library module `Keiro.Dsl.Topology` builds a topology value from a
      checked service and encodes it canonically; unit tests cover every node kind and
      relation.
- [ ] Milestone 2: `keiro-dsl topology` works for a single source and a workspace, refuses
      sources that fail `check`, and golden tests pass for the hospital-capacity and
      incident-command fixtures and a workspace fixture.
- [ ] Milestone 3: the five projection-catalog kinds and their relations are exported, and
      a golden test passes for a Language 6 projection-catalog fixture in which an aggregate
      can be traced through a projection owner and target to a read model.
- [ ] Milestone 4: byte stability is proven: two runs give equal bytes, the output does not
      depend on the working directory, and reordering declarations leaves nodes and edges
      unchanged.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: `source.path` is the file name of the source or manifest, and each member `path`
  is relative to the manifest directory (for a single source, its file name).
  Rationale: A path as typed on the command line would make the bytes depend on the working
  directory, which breaks byte stability and the later freshness check.
  Date: 2026-11-17

- Decision: A `projects` edge runs from a process or router to the aggregate whose
  `projection` table the `projections` entry names, with attribute `table`.
  Rationale: In the grammar a `projections` entry names an aggregate projection table, not a
  read-model declaration, and validation already rejects an unknown table. This answers
  IR-62's first question: the edge always resolves.
  Date: 2026-11-17

- Decision: Reorder invariance is asserted over the document with each member's `sha256` and
  each node's `line` removed.
  Rationale: Both necessarily change when a file's declarations are reordered. IR-62 asks for
  both fields and for reorder invariance; this is the only reading under which all hold.
  Date: 2026-11-17

- Decision: The command refuses to export a service that has error diagnostics, printing the
  diagnostics and exiting non-zero.
  Rationale: The builder relies on resolution guarantees that only hold for a checked service
  (every referenced contract, aggregate, read model and table exists). Every edge endpoint
  must name a node in the same document.
  Date: 2026-11-17

- Decision: No `dispatches` edge is emitted from a workflow in `/1`.
  Rationale: IR-62 lists workflow as a possible origin, but a workflow body in the grammar is
  a list of labelled steps with types and names no target aggregate or command. Inventing an
  edge would be a guess.
  Date: 2026-11-17

- Decision: The projection catalog is part of `/1`: five more node kinds
  (`projection-target`, `rebuild-group`, `projection-owner`, `projection-revision`,
  `external-read`) and ten more relations.
  Rationale: Requested by the user on 2026-11-17. IR-62 listed these under "what stays out",
  but without them the document shows that a read model exists and who queries it, not which
  aggregate events feed it. Keiro owns the contract, and `/1` has not shipped, so adding them
  now avoids a schema id bump for them later. Mori's draft decoder and fixtures must follow.
  Date: 2026-11-17

- Decision: An `external-read` node's `name` is its contract name followed by `_v` and its
  version, as `externalReadNodeIdentity` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs` computes it.
  Rationale: Several versions of one external-read contract are distinct declarations, and
  (`kind`, `name`) must be unique in a document.
  Date: 2026-11-17

- Decision: Fixture specifications are Language 6 copies of the two keiro-runtime-jitsurei
  services, vendored into this repository.
  Rationale: The originals live in another repository and are legacy-unversioned sources.
  `docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md`
  requires positive fixtures to select Language 6.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root. Run every build and test inside the Nix
development shell, from the repository root, as `AGENTS.md` requires. Entering the shell from
a package directory creates a stray database directory, so always start from the root.

The package is `keiro-dsl/`. Its command-line entry point is `keiro-dsl/app/Main.hs`, which
uses the `optparse-applicative` library. The subcommands are constructors of `data Command`
near the top of that file (`Parse`, `Pretty`, `Check`, `Inspect`, `BehaviorObligations`,
`Scaffold`, `Diff`, `New`), parsed by a `subparser` and dispatched by
`run :: Command -> IO ()`. For each command, `run` has a first clause guarded by
`isWorkspacePath fp` (true when the path ends in `.keiro-workspace`) that calls a
`runWorkspace…` function, then a single-file clause. The closest existing command is
`inspect`: read `run (Inspect fp InspectionJson)`, `sourceInspection` and
`runWorkspaceInspect` before writing anything, because the new command reuses their loading
steps and three of their output fields.

Loading works like this. A single source is read as text and parsed with
`parseSourceDocument :: FilePath -> Text -> Either ParseFailure ParsedSourceDocument`
(`keiro-dsl/src/Keiro/Dsl/Parser.hs`). `checkedSource` turns the parsed source into a
`CheckedService`. A workspace is loaded with
`loadWorkspace :: ContentSource -> FilePath -> IO (Either WorkspaceFailure WorkspaceSpec)`
(`keiro-dsl/src/Keiro/Dsl/Workspace.hs`), and `checkedWorkspace` gives the `CheckedService`.
The helper `oneMemberParsedDocumentWorkspace` in the same module adapts one file into a
`WorkspaceSpec` whose `service` is the file's base name. Use it so that one builder serves
both cases. `WorkspaceSpec` has `service`, `context`, `languageContract`, `members`,
`mergedSpec` (one `Spec` holding every member's declarations), and `ownership`. Each
`WorkspaceMember` has `path` (relative to the manifest, forward slashes), `sourceLanguage`
and `spec`, but not the file's bytes.

The parsed form of a specification is `Spec` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`. Its
`nodes :: [Node]` field holds the declarations. `Node` has seventeen constructors. The twelve
exported ones, with the record each carries, are `NAggregate Aggregate`,
`NProcess ProcessNode`, `NWorkflow WorkflowNode`, `NRouter RouterNode`,
`NContract ContractNode`, `NIntake IntakeNode`, `NEmit EmitNode`,
`NPublisher PublisherNode`, `NWorkqueue WorkqueueNode`, `NPgmqDispatch PgmqDispatchNode`,
`NReadModel ReadModelNode` and `NOperation OperationNode`. The other five form the
"projection catalog", the declarations that describe how read-side tables are filled:
`NProjectionTarget ProjectionTargetNode` (one physical table), `NRebuildGroup
RebuildGroupNode` (targets that are rebuilt together), `NProjectionOwner ProjectionOwnerNode`
(a handler that consumes events and writes targets), `NProjectionRevision
ProjectionRevisionNode` (a versioned schema contract for a group's targets) and
`NExternalRead ExternalReadNode` (a versioned read contract for readers outside the
process). All seventeen are exported. Read each record's definition in `Grammar.hs`; the
field names used below are the real ones. The catalog is described in
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`,
`docs/adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md` and
`docs/adr/0036-external-readers-use-versioned-guarded-sql-contracts.md`; read them only if a
field's meaning is unclear.

Every node record has a `loc :: Loc` field (`WorkflowNode` names it `workflowNodeLoc`), a
line number. In a workspace's `mergedSpec` these lines are relocated, so do not use them
directly. Use `nodeOwner :: OwnershipIndex -> Text -> Name -> Maybe (FilePath, Loc)`, which
returns the owning member path and the original line. Its `Text` argument is the kind string
produced by `nodeIdentity :: Node -> (Text, Name, Loc)` in
`keiro-dsl/src/Keiro/Dsl/Validate.hs`. Note that `nodeIdentity` spells the read-model kind
`readmodel`, while the topology document spells it `read-model`.

The existing JSON outputs all carry a versioned `schema` string, for example
`keiro-dsl/source-inspection/1`. They are built with the `aeson` library. A canonical JSON
writer already exists in `keiro-dsl/src/Keiro/Dsl/CodecCompare.hs`:
`canonicalJsonBytes = LazyByteString.toStrict . RFC8785.encodeCanonical`, using
`Data.Aeson.RFC8785`. RFC 8785 is the JSON Canonicalization Scheme: sorted object keys, no
insignificant whitespace, one fixed number format. Use it for the topology document.

The `effectiveSemanticContract` object comes from the existing `ToJSON` instance of
`EffectiveLanguageContract` in `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`
(`languageVersion`, `languageSupport`, `runtimeSemantics`); `checkedLanguageContract service`
supplies the value. The tool version is `showVersion Package.version` from the generated
module `Paths_keiro_dsl`, already used in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`. SHA-256 is
available from the `cryptohash-sha256` package (`Crypto.Hash.SHA256`), already a dependency
of the library and used in `keiro-dsl/src/Keiro/Dsl/ProcessReaction.hs`.

The main test suite is `keiro-dsl/test/Main.hs`, written with `hspec`. It has helpers
`runKeiroDsl :: [String] -> IO (ExitCode, String, String)`, which runs the real executable,
`assertMatchesByteGolden :: FilePath -> ByteString -> IO ()`, which compares with a golden
file and rewrites it when the environment variable `KEIRO_DSL_UPDATE_GOLDENS=1` is set, and
`resolveTestPath`, which lets a test find fixtures from either the package directory or the
repository root. Fixtures live in `keiro-dsl/test/fixtures/`.

Relevant ADRs. `docs/adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md`
defines workspaces and makes the manifest's `service` name the durable identity.
`docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md` requires
new positive fixtures to begin with `language keiro-dsl 6`.
`docs/adr/0038-keiro-dsl-records-use-concise-labels-without-product-selectors.md` requires
new records in this package to use plain field labels with `NoFieldSelectors` and record-dot
access, as the surrounding modules do. The script
`scripts/check-keiro-dsl-api-boundaries.py` (run by `just dsl-api-boundaries`) checks that
modules listed in `keiro-dsl/keiro-dsl.cabal` follow the package's export rules; a new
exposed module must satisfy it.


## Plan of Work

### The contract

The document is one JSON object with these fields.

`schema` is the string `keiro-dsl/service-topology/1`. `service` is the workspace's service
name, or the source file's base name for a single source. `source` is an object with `kind`
(`"source"` or `"workspace"`) and `path` (the file name of the source or manifest).
`effectiveSemanticContract` is the object described above. `generator` is
`{"tool": "keiro-dsl", "version": "<package version>"}`. `members` is a list, sorted by
`path`, of objects with `path`, `sha256` (the text `sha256:` followed by the lowercase hex
digest of the member file's exact bytes), `declaredLanguageVersion` (a number, or null when
the file has no `language` line) and `effectiveLanguageVersion`. `nodes` and `edges` are
lists.

Each node is an object with `kind`, `name`, `context` (the specification's `context` name),
`member` (the owning member's path), `line` (the declaration's line in that member) and
`details`. `kind` is one of `aggregate`, `process`, `workflow`, `router`, `contract`,
`intake`, `emit`, `publisher`, `workqueue`, `dispatch`, `read-model`, `operation`,
`projection-target`, `rebuild-group`, `projection-owner`, `projection-revision`,
`external-read`. `name` is
the declaration's identifier: the `name` field of most records, and the `id` field of
`ProcessNode`, `RouterNode` and `WorkflowNode`, and for an external read the result of
`externalReadNodeIdentity` (its name, `_v`, its version). The pair (`kind`, `name`) is unique in a
document; if the builder finds a duplicate it must fail with an internal error rather than
emit an ambiguous document.

The `details` object of each kind carries the following, each read straight from the grammar
record. Lists keep declaration order unless stated.

An aggregate has `states`, `commands` and `events`, each a list of names.

A process has `stableName` (the record's `name` text), `saga` (`aggregate` and `category`),
`correlate` (`field` and `via`), `inputs` (the names of its input declarations: one for a
legacy body, one or more for a reaction body), `target`, `projections`, `timers` (timer
names) and the `rejected` and `poison` policies spelled `halt`, `dead-letter` or `skip`.

A workflow has `stableName`, `input`, `output` and `steps`, an ordered list of objects with
`form` (`step`, `await`, `sleep`, `child`, `patch` or `continue-as-new`) and `label` where the
form has one. Flatten the items inside a patch in order after the patch item itself.

A router has `stableName`, `input`, `target`, `resolvesFrom` (the read-model name, or null
when the resolve source is a hand-written hole) and `projections`.

A contract has `schemaVersion`, `discriminator`, `topics` (objects with `alias` and `topic`,
the physical topic name) and `events` (names).

An intake has `contract`, `topicAlias`, `topic` (the physical name, found by looking the
alias up in the contract's `topics`), `accepts`, `dedupe` (key and policy as the grammar
spells them) and `idempotence` (`inbox-table` or `delegated`).

An emit has `contract`, `topicAlias`, `topic`, `source` (its source label), `key` and
`events` (the distinct `event` of each of its `map` rows, in order).

A publisher has `emit`, `ordering`, `maxAttempts`, `backoff` and `outboxField`.

A workqueue has `logical`, `physical`, `dlq`, `table`, `ordering`, `maxRetries` and `dlqOn`.

A dispatch has `sourceReadModel` and `enqueueTo`.

A read model has `table`, `schema`, `version`, `group` (null when absent), `observedTargets`
and `backingTarget` (null when absent).

A projection target has `schema`, `table`, `reset` (`clear` or `preserve`) and `dependsOn`.

A rebuild group has `targets` and `order`.

A projection owner has `sources` (a list of objects, each `{"kind": "aggregate", "name"}`,
`{"kind": "category", "name"}` or `{"kind": "all"}`), `delivery` (`inline` or
`subscription`), `group`, `targets`, `order`, `subscription` and `dedup` (null when absent)
and `replay` (`explicit`, or `live-only` with its recorded `reason`).

A projection revision has `group` and `targets`, a list of objects with `target` and
`schemaVersion`. The provisioner, validator, expected-shape and promotion-object fields are
not exported.

An external read has `contract` (the declared name), `version`, `queryModel`,
`resultSchema`, `resultType`, `compatibleRevisions` and `surfaceGeneration`.

An operation has `form` (`command`, `query`, `signal` or `run`), `subject` (the aggregate,
read model or workflow it addresses) and, for a signal, `label`.

Where a grammar field is an enumeration or a structured value not named above, encode it with
the spelling the specification language itself uses (the pretty printer in
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` is the reference) and say so in the module comment.

Each edge is an object with `from` and `to` (each `{"kind", "name"}` naming a node in this
document), `relation` and `attributes` (an object, possibly empty). The relation set is
closed:

`dispatches` runs from a process or router to an aggregate with attribute `command`. For a
process, collect every dispatch in the body: for a legacy body, the handle's `dispatch` list
and the timer's `fire`; for a reaction body, every `FollowDispatch` in every reaction arm and
the `fire` of every reaction timer. The edge's target is the dispatch's own `target` field.
For a router, the target is the router's `target` and the command is its dispatch's
`command`.

`saga` runs from a process to its saga aggregate, with attribute `category`.

`reads` runs from a router to the read model it resolves from (when the resolve source is a
read model or a declarative selection, whose `query` names one) with attribute
`role: "resolve"`, and from a dispatch to its `sourceReadModel` (`role: "source"`) and, when
present, its dedupe read model (`role: "dedupe"`).

`projects` runs from a process or router to the aggregate whose `projection` table equals
each `projections` entry, with attribute `table`.

`publishes` runs from an emit to its contract with attributes `topicAlias`, `topic` and
`events`. `subscribes` runs from an intake to its contract with attributes `topicAlias`,
`topic` and `events` (its accept list).

`delivers` runs from a publisher to its emit. `enqueues` runs from a dispatch to the
workqueue named by `enqueueTo`.

`commands`, `queries`, `signals` (with attribute `label`) and `runs` run from an operation to
its aggregate, read model or workflow.

The projection catalog adds ten relations. `depends-on` runs from a projection target to
each target in its `dependsOn`. `groups` runs from a rebuild group to each of its `targets`.
`consumes` runs from a projection owner to each aggregate named by a `CatalogAggregate`
source; a category or `all` source produces no edge and appears only in the owner's
`sources` detail. `writes` runs from a projection owner to each of its `targets`. `member-of`
runs from a projection owner, and from a read model that declares a `group`, to that rebuild
group. `revises` runs from a projection revision to its rebuild group, and to each of its
targets with attribute `schemaVersion`. `observes` runs from a read model to each of its
`observedTargets`, and `backed-by` from a read model to its `backingTarget`. `exposes` runs
from an external read to the read model named by `queryModel`, and `compatible-with` from an
external read to each revision in `compatibleRevisions`.

Identical edges are emitted once. Nodes are sorted by (`kind`, `name`). Edges are sorted by
(`from.kind`, `from.name`, `relation`, `to.kind`, `to.name`, the canonical bytes of
`attributes`). The document is encoded with the RFC 8785 writer and followed by exactly one
newline.

The compatibility policy, which later plans rely on, is: within one schema id keiro may add
object fields, and consumers must ignore fields they do not know; a new node kind, a new
relation, or a change in the meaning of an existing field requires a new schema id.

### Milestone 1: the library module

Create `keiro-dsl/src/Keiro/Dsl/Topology.hs` and add it to the library's module list in
`keiro-dsl/keiro-dsl.cabal`. Define plain data types for the document, its nodes and edges,
with a sum type for node kinds and one for relations so that the closed sets are enforced by
the compiler. Write the builder as a pure function from the workspace value and the member
digests to the document, and the encoder as a pure function to bytes. Keep the digest
computation as a separate pure function over bytes. The exact signatures are in Interfaces
and Dependencies.

Add a `describe "service topology"` block to `keiro-dsl/test/Main.hs` with unit tests that
parse small inline Language 6 sources and assert the nodes and edges for each kind and
relation, the sort order, the removal of duplicate edges, and that every edge endpoint names
a node. At the end of this milestone the tests pass and no command exists yet.

### Milestone 2: the command and golden documents

In `keiro-dsl/app/Main.hs` add `Topology FilePath TopologyFormat` to `data Command`, a
`data TopologyFormat = TopologyJson`, a `--format json` option that defaults to `json`
modelled on `inspectionFormatOpt`, and a `command "topology"` entry in the `subparser`. In
`run`, load the source or workspace exactly as `inspect` does, run the same validation
`check` runs, and if any diagnostic is an error, print the diagnostics as `check` does and
exit with failure. Read each member's bytes with `Data.ByteString.readFile` relative to the
manifest's directory to compute its digest. For a single source, read the bytes once and
decode them as UTF-8 for parsing, so that the digest and the parse see the same content and
`/dev/stdin` keeps working. Write the encoded bytes to standard output with no extra newline.
The executable stanza in `keiro-dsl.cabal` may need `bytestring` added to its dependencies.

Create the fixtures. Copy the two specifications from the sibling checkout of
`mori://shinzui/keiro-runtime-jitsurei` (resolve its path with `mori registry show
shinzui/keiro-runtime-jitsurei`; the files are
`services/hospital-capacity/spec/hospital-capacity.keiro` and
`services/incident-command/spec/incident-command.keiro`) to
`keiro-dsl/test/fixtures/topology/hospital-capacity.keiro` and
`keiro-dsl/test/fixtures/topology/incident-command.keiro`. Add `language keiro-dsl 6` as the
first line of each and change whatever Language 6 requires until
`keiro-dsl check` reports no errors, keeping every declaration and every name. Language 6
turns some legacy warnings into errors and requires explicit transition ownership; the
existing Language 6 fixtures in `keiro-dsl/test/fixtures/` and the notation reference
`agents/skills/keiro-dsl-authoring/NOTATION.md` show the current forms. The first fixture
declares all twelve non-catalog node kinds. If a declaration cannot be expressed in Language 6 without
changing its meaning, record what changed in Surprises & Discoveries; the fixture's purpose
is topology coverage, not parity with the other repository. Add a workspace fixture under
`keiro-dsl/test/fixtures/topology/workspace/` with a `service.keiro-workspace` manifest and
at least two members, splitting declarations so that an edge crosses members.

Add golden tests that run the real executable with `runKeiroDsl` and compare standard output
with `assertMatchesByteGolden` against
`keiro-dsl/test/fixtures/topology/hospital-capacity.topology.golden.json`,
`incident-command.topology.golden.json` and `workspace/service.topology.golden.json`.
Generate them once with `KEIRO_DSL_UPDATE_GOLDENS=1` and read each one in full before
committing: confirm that hospital-capacity has a node of every non-catalog kind, that the emit and intake
edges carry the physical topics `emergency.hospital.events` and `emergency.incident.events`,
and that what one service publishes the other subscribes to. Add a test that a source with a
validation error makes the command exit non-zero and print nothing on standard output.

Because the golden bytes contain `generator.version`, they change whenever the package
version changes. Follow how existing byte goldens that embed the version are handled in this
suite (search `keiro-dsl/test/Main.hs` for `Package.version` or `showVersion`); if none
exists, have the golden tests replace the version with the placeholder `<version>` in the
actual output before comparing, and store the placeholder in the golden files.

### Milestone 3: the projection catalog

Extend the builder with the five catalog node kinds and the ten relations above, and add
unit tests for each to the `describe "service topology"` block. Every catalog reference is
already resolved by validation in `keiro-dsl/src/Keiro/Dsl/Validate.hs`, so on a checked
service every edge endpoint exists; if the builder finds one that does not, that is the
internal error described above, not something to drop silently.

Neither of the two service fixtures declares catalog nodes. Create
`keiro-dsl/test/fixtures/topology/projection-catalog.keiro` as a Language 6 copy of
`keiro-dsl/test/fixtures/projection-catalog.keiro`, the one existing fixture that declares
all five kinds (it is a Language 5 source; change its first line to `language keiro-dsl 6`
and adjust until `keiro-dsl check` reports no errors). Add a golden test against
`projection-catalog.topology.golden.json`. Read the golden in full and confirm that it
contains at least one node of each of the five kinds and at least one edge of each of the ten
relations, and that following `consumes`, `writes` and `observes` or `backed-by` leads from
an aggregate to a read model. If the copied fixture lacks a case (for example an owner with
an aggregate source, or a target with `dependsOn`), add it to the copy.

### Milestone 4: byte stability

Add three tests. The first runs the command twice on each fixture and compares the bytes. The
second runs it on the same fixture from two different working directories, giving a relative
path in one and an absolute path in the other, and compares the bytes. The third writes a
copy of a fixture with its top-level declarations in a different order to a temporary
directory using the same basename, exports both, removes `sha256` from every member and `line` from every node, and
asserts the two documents are equal. Only top-level declarations move: state order,
transition order, emitted-event order and other ordered lists retain their meaning. Keep this
test after machine export lands; reordering transitions is explicitly outside this guarantee.

Add an entry to `keiro-dsl/CHANGELOG.md` under `## [Unreleased]` describing the new command
and schema id, in the style of the entries below it.


## Concrete Steps

Work from the repository root.

```bash
nix develop -c cabal build keiro-dsl
nix develop -c cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct --test-options='--match "service topology"'
```

To create or refresh golden files, then inspect what changed:

```bash
KEIRO_DSL_UPDATE_GOLDENS=1 nix develop -c cabal test keiro-dsl:keiro-dsl-test --test-options='--match "service topology"'
git status --short keiro-dsl/test/fixtures/topology
```

To see the command by hand:

```bash
nix develop -c cabal run -v0 keiro-dsl -- topology keiro-dsl/test/fixtures/topology/hospital-capacity.keiro --format json | head -c 400
```

The output begins like this (one line, shown wrapped):

```text
{"edges":[{"attributes":{"command":"...
```

and contains `"schema":"keiro-dsl/service-topology/1"` and
`"service":"hospital-capacity"`.

Commit at each milestone with a Conventional Commits message and these trailers:

```text
feat(keiro-dsl): export a versioned service topology

MasterPlan: docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md
ExecPlan: docs/plans/338-emit-a-versioned-service-topology-document-from-keiro-dsl-topology.md
Intention: intention_01m7n03hbfem79q2brf07rneyq
```


## Validation and Acceptance

The plan is accepted when all of the following hold.

Running `keiro-dsl topology` on each of the two fixtures and on the workspace manifest exits
zero and prints bytes equal to the checked-in golden documents (AC-1). The hospital-capacity
document contains at least one node of each of the twelve non-catalog kinds and at least one edge of each
relation its declarations support.

Every edge endpoint in every golden document names a node in the same document, and no two
nodes share (`kind`, `name`). A test asserts both over the decoded golden documents.

The projection-catalog golden test passes, and its document contains every catalog node kind
and relation.

The three byte-stability tests of Milestone 4 pass (AC-2).

Running the command on a source with a validation error exits non-zero with the diagnostic on
standard error and empty standard output.

The existing behavior is unchanged: the full `keiro-dsl` test suites and the repository gate
pass.

```bash
nix develop -c cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct
nix develop -c just verify
```

`just verify` includes `dsl-api-boundaries`, which must accept the new module, and takes a
long time; run the focused suite while developing and the full gate once before declaring the
plan complete.


## Idempotence and Recovery

Every step is additive and can be repeated. Regenerating golden files with
`KEIRO_DSL_UPDATE_GOLDENS=1` overwrites them in place; review `git diff` afterwards and
restore with `git checkout -- keiro-dsl/test/fixtures/topology` if the change was not
intended. No database, generated corpus or scaffold ledger is touched by this plan. If the
Language 6 migration of a fixture stalls, the fixture can temporarily be reduced to the
declarations that already check, as long as hospital-capacity still covers all twelve non-catalog kinds;
record the reduction in Surprises & Discoveries.


## Interfaces and Dependencies

No new package dependency is needed for the library: `aeson` (with `Data.Aeson.RFC8785`),
`bytestring`, `text`, `containers` and `cryptohash-sha256` are already dependencies.

At the end of Milestone 1, `keiro-dsl/src/Keiro/Dsl/Topology.hs` exports at least the
following. Later plans call these names, so keep them stable; field and constructor details
beyond what is shown are the implementer's choice.

```haskell
module Keiro.Dsl.Topology where

-- | The schema id a document is emitted under.
topologySchemaId :: ServiceTopology -> Text

-- | "sha256:<lowercase hex>" of a member file's exact bytes.
memberDigest :: ByteString -> Text

-- | Whether the document came from one source file or a workspace manifest.
data TopologySourceKind = TopologySingleSource | TopologyWorkspace

-- | Build the document. The FilePath is the source or manifest path as given;
-- only its file name is recorded. The list pairs each member path with its
-- digest. Fails only on an internal inconsistency (duplicate node identity or
-- a dangling edge endpoint), which a checked service never produces.
buildServiceTopology ::
  TopologySourceKind ->
  FilePath ->
  WorkspaceSpec ->
  [(FilePath, Text)] ->
  Either TopologyError ServiceTopology

-- | Canonical bytes: RFC 8785 JSON followed by one newline.
encodeServiceTopology :: ServiceTopology -> ByteString

data NodeKind
  = AggregateKind | ProcessKind | WorkflowKind | RouterKind | ContractKind
  | IntakeKind | EmitKind | PublisherKind | WorkqueueKind | DispatchKind
  | ReadModelKind | OperationKind
  | ProjectionTargetKind | RebuildGroupKind | ProjectionOwnerKind
  | ProjectionRevisionKind | ExternalReadKind

data Relation
  = Dispatches | Saga | Reads | Projects | Publishes | Subscribes
  | Delivers | Enqueues | Commands | Queries | Signals | Runs
  | DependsOn | Groups | Consumes | Writes | MemberOf | Revises
  | Observes | BackedBy | Exposes | CompatibleWith
```

`ServiceTopology` must also have a `FromJSON`-style decoder or the tests must decode golden
documents as generic `aeson` values; either is acceptable for the endpoint and uniqueness
assertions.


Revision note, 2026-11-17: the projection catalog (five node kinds, ten relations) was added
to the `/1` contract as Milestone 3 at the user's request, and byte stability became
Milestone 4. IR-62 had excluded the catalog; the Decision Log records why it is included.


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


Validation evidence, 2026-11-17: both source specifications in
`mori://shinzui/keiro-runtime-jitsurei` (project-relative paths
`services/hospital-capacity/spec/hospital-capacity.keiro` and
`services/incident-command/spec/incident-command.keiro`; artifact-level URIs pending)
passed the current `keiro-dsl check` through `nix develop -c cabal run -v0 keiro-dsl`,
returning `OK` and exit zero with legacy-language and existing warning diagnostics. This
confirms the source baseline; migrating the copied fixtures to Language 6 remains EP-1 work.
