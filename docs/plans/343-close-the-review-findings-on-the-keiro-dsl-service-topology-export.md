---
id: 343
slug: close-the-review-findings-on-the-keiro-dsl-service-topology-export
title: "Close the review findings on the keiro-dsl service topology export"
kind: exec-plan
created_at: 2026-11-17T18:06:42Z
intention: "intention_01m7nb12awezmsvq5wra3eeh2b"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-17T18:06:42Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T18:58:32Z
      mode: "implement"
      note: "Implemented milestones of the topology review-findings plan"
---

# Close the review findings on the keiro-dsl service topology export

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl topology` prints a JSON document describing how a service's declarations
connect (`docs/user/keiro-dsl-service-topology.md`). A review of that work on 2026-11-17
found no wrong output, but seven gaps. After this plan:

- An aggregate node names the stream category its live inspector is mounted under, and a
  dispatch node names its dedupe read model, so a consumer such as the keiro-ui console can
  link a node to live data without copying keiro's code-generation rules.
- `keiro-dsl scaffold --topology-out FILE` either writes everything or fails before writing
  anything. Today an unwritable FILE fails with a raw exception after the generated tree
  has been written.
- `keiro-dsl topology --check FILE` explains a stale document truthfully when the manifest
  changed, and records digests of the exact bytes it parsed.
- The schema gate cannot pass because a file is missing or malformed.
- The proof that an exported aggregate machine equals the generated keiki transducer
  covers several corpora, not one fixture.

You can see it working with:

```bash
nix develop -c cabal run -v0 keiro-dsl -- topology keiro-dsl/test/fixtures/topology/hospital-capacity.keiro \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print([(n["name"], n["details"]["category"]) for n in d["nodes"] if n["kind"]=="aggregate"])'
```

which prints each aggregate with its category, for example `('Capacity', 'capacity')`.


## Progress

- [x] Milestone 1 (2026-11-17): aggregate nodes export `category` and dispatch nodes
      export `dedupReadModel`; a test proves each aggregate category equals the generated
      inspector's name; goldens, JSON Schemas, the contract page and the CHANGELOG are
      updated. Evidence: `--match topology` 40 examples, 0 failures; a JSON comparison of
      each regenerated golden against the previous commit with the two fields removed is
      identical for all five; `just topology-schema-validate` passes with the unedited
      `aggregate-without-machine.valid.json`.
- [x] Milestone 2 (2026-11-17): `scaffold --topology-out` refuses an unwritable target
      before writing anything; `topology --check` reports a changed manifest as such;
      workspace member digests are computed from the bytes that were parsed. Tests cover
      all three. Evidence: `--match topology` 44 examples, 0 failures, with the five
      goldens (including the workspace golden) unchanged by this milestone; the
      export-error sweep reports `files=428 internal=0`.
- [ ] Milestone 3: `scripts/check-topology-schemas.sh` accepts an `*.invalid.json` example
      only on a real schema violation, shown by a deliberately broken run.
- [ ] Milestone 4: the machine proof runs against at least three more generated corpora
      and prints how many aggregates it compared; `just verify` passes.


## Surprises & Discoveries

- A saga aggregate's inspector is mounted under the aggregate's own category, not the
  process's saga category. For `hospital-capacity.keiro` the generated `Inspection` module
  mounts `Surge` with `Surge.surgeCategory`, which `Surge/Generated/EventStream.hs` defines
  as `Stream.categoryUnsafe "surge"`, while the process module defines
  `hospitalSurgeCategory = Stream.categoryUnsafe "hospitalSurge"`. The export therefore
  reports `surge`, which is what `/aggregate/list?name=` accepts for that inspector. The
  saga category is still available on the process node (`details.saga.category`) and the
  `saga` edge. Whether the inspector for a saga aggregate should list the saga streams
  under `hospitalSurge` is a question about ADR-61's catalog, outside this plan.
- The category derivation was local to `emitEventStream` in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`. It is now the exported
  `aggregateStreamCategory :: Name -> Text`, called by both the EventStream emitter and
  `Keiro.Dsl.Topology`; `Topology` importing `Scaffold` creates no cycle and passes
  `just dsl-api-boundaries`.
- The reproduction in Concrete Steps (`--out /tmp/gen --topology-out /tmp/gen` with
  `/tmp/gen` absent) is not caught by an "is a directory" check, because the target
  does not exist yet when the preflight runs; the scaffold creates it later. The
  preflight therefore also refuses a target that is `--out` or a directory above any
  planned module, with the reason `it is a directory the scaffold creates`. The observed
  transcript, with paths shortened:

  ```text
  scaffold: --topology-out …/m2/gen cannot be written: it is a directory the scaffold creates; nothing was written
  exit=1
  $ ls …/m2
  svc.keiro
  ```

  An existing directory reports `it is a directory`, and an unwritable parent reports the
  `createDirectory: permission denied` error, each with `nothing was written` and no
  `--out` tree.
- The preflight creates the target's missing parent directories to hold the temporary
  file. A scaffold that is refused afterwards removes the temporary file and those
  directories (innermost first, only while empty), so a refused run still leaves no
  trace; a test covers it with a hand-written file at a generated module path.


## Decision Log

- Decision: `topology --check` keeps today's version message whenever the recorded and
  current generator versions differ, even if the service also changed, and reports a
  changed manifest file name together with the service in the service-or-manifest line.
  Rationale: the plan orders the checks generator first; a version difference alone
  explains a document difference, and the manifest file name is the other non-member
  fact the document records (`source.path`). The version-upgrade test therefore needed
  no change.
  Date: 2026-11-17

- Decision: This plan owns the aggregate `category` field. Plan
  `docs/plans/342-serve-the-committed-service-topology-to-keiro-ui-through-keiro-ops-http.md`
  planned it as its Milestone 1; that milestone now defers to Milestone 1 here.
  Rationale: `category` and `dedupReadModel` both add a field to the document. Each such
  change makes every committed topology stale until it is regenerated. Doing both in one
  change means services regenerate once, and keeps all keiro-dsl work in one plan.
  Date: 2026-11-17

- Decision: Both new fields are added under the existing schema ids and are optional in
  the JSON Schemas.
  Rationale:
  [ADR-62](../adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)
  allows added object fields within a schema id and requires a new id only for a new node
  kind, a new relation or a changed meaning. Documents emitted before this change must
  stay valid, so the fields cannot be `required`.
  Date: 2026-11-17

- Decision: `--topology-out` proves the target is writable by creating a temporary file
  beside it before the scaffold writes anything, and renames it into place after the
  scaffold succeeds.
  Rationale: A check of permissions or file type can pass and the write still fail. A
  temporary file in the target's directory proves the directory exists or can be created
  and is writable, and the rename makes the final write atomic. The document is still
  published only after a successful scaffold, as the current code promises.
  Date: 2026-11-17

- Decision: Workspace digests come from a recording content source in the command-line
  program, not from a second read of each member.
  Rationale: `loadWorkspace` reads through a `ContentSource`
  (`keiro-dsl/src/Keiro/Dsl/Workspace.hs`). Wrapping it lets `renderTopology` digest the
  bytes the loader was given without changing the loader's types or the other commands
  that use it.
  Date: 2026-11-17

- Decision: The machine proof is widened by reusing existing generated corpora, not by
  generating a proof into every service.
  Rationale: The exporter and the transducer generator already share one layout rule
  (`transitionLayout` in `keiro-dsl/src/Keiro/Dsl/AggregateGenerationPlan.hs`). The risk
  left is a specification shape the one fixture does not contain. Corpora that already
  compile generated transducers supply more shapes at no cost to consumers.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root. Run builds and tests in the Nix development
shell from the root (`nix develop -c …`), as `AGENTS.md` requires. Entering the shell from
a package directory creates a stray database directory under it.

**The document and its emitter.** `keiro-dsl/src/Keiro/Dsl/Topology.hs` builds the
document. `nodeSummary` returns each node's kind, name and `details` object, and
`nodeEdges` returns its edges. `buildServiceTopology` assembles them with a SHA-256 digest
per source member, and `encodeServiceTopology` writes RFC 8785 canonical JSON and one
newline. The contract is `docs/user/keiro-dsl-service-topology.md`; the JSON Schemas are
`docs/user/schemas/keiro-dsl-service-topology-1.schema.json` and `-2.schema.json`. Golden
documents are `keiro-dsl/test/fixtures/topology/*.topology.golden.json` and
`keiro-dsl/test/fixtures/topology/workspace/service.topology.golden.json`. Tests are in
`keiro-dsl/test/Keiro/Dsl/TopologySpec.hs`.

**The command-line program.** `keiro-dsl/app/Main.hs` has `renderTopology` (load, check
and encode a source or workspace), `checkTopology` (`topology --check FILE`),
`topologySummary` (reads members and generator version from a document),
`prepareTopologyOut` and `writeTopologyOut` (`scaffold --topology-out FILE`).

**The seven findings.** Each was checked on 2026-11-17 against commit `b71fcfe6`.

1. *No inspector category on aggregate nodes.* The generated inspector catalog mounts each
   aggregate under its stream category text (`inspectorLine` in
   `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`;
   [ADR-61](../adr/0061-generated-aggregate-inspector-catalogs-cover-every-dsl-aggregate.md)).
   For a plain aggregate the category is the declared name with its first letter lowered:
   `categoryName = staticCategory ("aggregate " <> name) (lowerFirst name)`. The live route
   `/aggregate/list?name=` takes that text. The topology aggregate node carries `states`,
   `commands`, `events` and `machine` only, so a consumer cannot join `Capacity` to
   `capacity` without copying the rule.
2. *The machine proof covers two aggregates.*
   `keiro-dsl/test/conformance-topology-machine/Main.hs` walks the generated keiki
   transducers `orderTransducer` and `orderSagaTransducer` of
   `keiro-dsl/test/fixtures/topology-machine.keiro` and requires the result to equal the
   exported `machine`. keiki is the state-machine library keiro aggregates compile to; a
   transducer is its machine value. The suite guards its own coverage (a replay-only edge,
   a two-event edge, a state with two edges, a process saga) but sees no other corpus.
3. *An unwritable `--topology-out` fails late.* `prepareTopologyOut` refuses a path that is
   a scaffold input, a planned module, or a `keiro-dsl-` record under `--out`. It does not
   check that the path can be written. `scaffold svc.keiro --out gen --topology-out gen`
   wrote the generated tree, then exited 1 with
   `keiro-dsl: Uncaught exception … gen: withBinaryFile: inappropriate type (Is a directory)`.
4. *The schema gate counts any failure as a rejection.* For `*.invalid.json` examples
   `scripts/check-topology-schemas.sh` treats a non-zero exit of `check-jsonschema` as
   "rejected as expected". `check-jsonschema` exits 1 for a schema violation, for a missing
   schema file and for an instance that is not JSON, so the exit code cannot tell them
   apart.
5. *`--check` blames the keiro-dsl version for a manifest change.* When no member digest
   differs, `checkTopology` prints "document differs with unchanged sources (generated by
   keiro-dsl X, current keiro-dsl Y); regenerate it". Renaming `service` in
   `keiro-dsl/test/fixtures/topology/workspace/service.keiro-workspace` produced that
   message with X and Y both `0.25.1.0`. The manifest is not a member and has no digest.
6. *Workspace digests are read separately.* For a workspace, `renderTopology` calls
   `loadWorkspace`, then reads each member file again with `BS.readFile` for its digest.
   If a file changes in between, the document records a digest of bytes that were not
   parsed. The single-source branch already reads once.
7. *The dispatch node omits its dedupe read model.* `nodeEdges` emits a `reads` edge with
   `role: dedupe` to `dispatch.dedupReadModel`, but the node's `details` have only
   `sourceReadModel` and `enqueueTo`.

**Relevant ADRs.** ADR-62 (linked above) defines the document contract and its
compatibility policy.
[ADR-63](../adr/0063-topology-machines-are-derived-from-the-specification-and-proven-against-keiki-transducers.md)
records that exported machines are derived from the specification and proven against
keiki transducers; Milestone 4 widens that proof. ADR-61 (linked above) defines the
inspector naming Milestone 1 exports.

**Gates.** `just topology-schema-validate` runs `scripts/check-topology-schemas.sh`.
`just verify` runs every gate, including `conformance-corpus-policy`
(`scripts/check-conformance-corpus.sh`, with `keiro-dsl/test/conformance-corpus-manifest.txt`
and `keiro-dsl/test/conformance-baseline.json`), which Milestone 4 must keep passing.


## Plan of Work

### Milestone 1: export the aggregate category and the dispatch dedupe read model

In `nodeSummary` in `keiro-dsl/src/Keiro/Dsl/Topology.hs`, add `category` to an aggregate
node's `details`. Its value must be the text the generated inspector catalog mounts that
aggregate under. Take it from the derivation the scaffold uses (`categoryName` beside
`lowerFirst ((.name) a) <> "Category"` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`). If that
derivation is local to the scaffold, move it to a function both modules call. Do not write
a second copy.

A process's saga aggregate needs care. A process declares a saga category
(`saga.category`, for example `hospitalSurge` for the aggregate `Surge`), and ADR-61 says
the inspector catalog covers saga aggregates. Find out which category the generated
catalog uses for a saga aggregate, export that one, and record the answer in Surprises &
Discoveries.

In the same function add `dedupReadModel` to a dispatch node's `details`, from
`dispatch.dedupReadModel`.

Add a test to `keiro-dsl/test/Keiro/Dsl/TopologySpec.hs`: for
`keiro-dsl/test/fixtures/topology/hospital-capacity.keiro` (five aggregates, one a saga
aggregate), the set of `details.category` values of the aggregate nodes equals the set of
inspector names in the scaffolded `Inspection` module. Derive the expected names from the
scaffold's output, not from a list typed into the test. Add a second test that each
dispatch node's `details.dedupReadModel` equals the target of its `reads` edge with
`role: dedupe`.

Regenerate the golden documents by running `keiro-dsl topology` on each fixture source
and replacing the recorded generator version with `<version>`, as the existing goldens
have it. Read the diff: it must add one `category` per aggregate node and one
`dedupReadModel` per dispatch node, and change nothing else.

In both JSON Schemas add `category` as an optional string of the aggregate details and
`dedupReadModel` as an optional string of `dispatchDetails`. Neither may be `required`.
Update the `aggregate` and `dispatch` rows of the node-kind table in
`docs/user/keiro-dsl-service-topology.md`, and say under the table that a document
emitted by an older keiro-dsl lacks both fields. Advance the page's `timestamp` and add a
`docs/user/log.md` entry with `okf log add`. Add a `keiro-dsl/CHANGELOG.md` entry under
`## [Unreleased]` saying committed topology documents must be regenerated with
`scaffold --topology-out`, because `topology --check` reports them stale after the
upgrade. Add one bullet to ADR-62's Consequences: aggregate nodes carry the inspector
category so consumers join to live inspection without deriving it. Advance the ADR's
`timestamp` and add an `okf log add` entry to `docs/adr/log.md`.

### Milestone 2: make the command-line paths fail early and report truthfully

*Unwritable `--topology-out`.* In `prepareTopologyOut`, after the existing protected-path
check and after rendering, create the target's parent directory and write the document to
a temporary file in that directory. If the target is an existing directory, or the
temporary file cannot be created, print
`scaffold: --topology-out FILE cannot be written: <reason>; nothing was written` and exit 1
before the scaffold writes anything. `writeTopologyOut` then renames the temporary file
onto the target. On every path that exits without a successful scaffold, remove the
temporary file. The temporary name must not collide with a protected path; use the
target's file name with a `.keiro-dsl-tmp` suffix, and refuse if that path already exists.

*Manifest changes in `--check`.* When the bytes differ and no member digest differs,
compare the remaining facts before blaming the generator. Extend `topologySummary` to
return the document's `service`, `source` and `schema` as well. If the generator versions
differ, keep today's message. Otherwise, if `service` or `source` differ, print
`topology stale: the service or manifest changed (recorded service 'A', current 'B');
regenerate it`. Otherwise print `topology stale: document differs with unchanged sources
and the same keiro-dsl version; regenerate it`, which is the honest fallback for a changed
manifest member order or a different build of the same version.

*Digest the parsed bytes.* In `renderTopology`'s workspace branch, replace
`fileContentSource` with a local content source that reads each file with `BS.readFile`,
records `memberDigest` of the bytes in an `IORef (Map FilePath Text)` keyed by the relative
path it was asked for, decodes them as UTF-8 and returns the text or a read-failure reason
for invalid UTF-8. Build the digest list from that map after `loadWorkspace` returns, and
delete the second read. A member path missing from the map is an internal error reported
through the existing `TopologyMissingDigest`. The loader today reads with `TIO.readFile`,
which decodes with the process locale; under a UTF-8 locale the text is identical. Confirm
the five golden documents are byte-identical before and after this change.

Tests go in `keiro-dsl/test/Keiro/Dsl/TopologySpec.hs` beside the existing command-line
tests ("refuses an export path that names an input or a scaffold record", "topology
--check names new and removed workspace members"). The existing test "topology --check
reports a difference with unchanged sources, such as a tool upgrade" asserts today's
message and must be updated to the new wording for its case. Add:
`--topology-out` naming an existing directory exits 1 and leaves `--out` without any
generated file; a successful `--topology-out` leaves no `.keiro-dsl-tmp` file; `--check`
after renaming the workspace `service` prints the service-changed message and names both
services; `--check` after editing a member still names that member.

Update the `--check` and `--topology-out` descriptions in `docs/user/keiro-dsl-cli.md` if
they describe the messages or the failure behaviour, and the CHANGELOG.

### Milestone 3: make the schema gate reject only real violations

In `scripts/check-topology-schemas.sh`, change `schema_for` to fail when the example is not
JSON, has no `schema` field, or names a schema file that does not exist. For
`*.invalid.json`, run `check-jsonschema` with `--output-format json` and accept the example
only when the report says validation failed with at least one schema error and no parse
error. Read `check-jsonschema --help` in the dev shell for the exact report fields before
writing the test, and record the fields you relied on in a comment in the script.

Prove the gate by breaking it. Temporarily rename one `*.invalid.json` example's `schema`
to a schema id with no file, run `just topology-schema-validate`, and confirm it now exits
non-zero naming the missing schema. Do the same with an example truncated to `{`. Restore
both. Record the two transcripts in this plan.

### Milestone 4: widen the machine proof

Move `keikiMachine` out of `keiro-dsl/test/conformance-topology-machine/Main.hs` into a
module in a new directory `keiro-dsl/test/topology-machine-proof/`, with a function that
takes a fixture path and a list of aggregate names paired with their walked machines,
exports the topology of that fixture, compares every listed aggregate and returns the
number compared. Add the directory to `hs-source-dirs` and the module to `other-modules`
of each suite that uses it in `keiro-dsl/keiro-dsl.cabal`.

Use it from the existing suite and from at least three more conformance suites under
`keiro-dsl/test/` whose `Generated/` tree already compiles transducers. Choose them for
shapes the current fixture lacks, and say which shape each adds. Candidates:
`conformance-history-dependent-holes` (hole-bodied transitions), `conformance-process-full`
or `conformance-process-reactions` (a reaction-process saga), and
`conformance-structural` or `conformance-behavior-complete` (larger aggregates). For each,
the proof must cover every aggregate of the corpus whose machine ownership is `generated`;
an aggregate left out must be named with its reason in the suite. Each suite prints
`topology machine proof: N aggregates match keiki`.

A walked machine and an exported machine that differ is a finding about the exporter or
the generator, not a reason to drop the corpus. Record it in Surprises & Discoveries and
fix the cause.

Update the suites' entries in `keiro-dsl/test/conformance-baseline.json` if the baseline
records their output, and run `just conformance-corpus-policy`. Add one sentence to
ADR-63's Consequences naming the corpora the proof now covers.


## Concrete Steps

From the repository root:

```bash
nix develop -c z3 --version
nix develop -c cabal build exe:keiro-dsl
nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-show-details=direct --test-options="--match topology"
nix develop -c just topology-schema-validate
nix develop -c cabal test keiro-dsl:keiro-dsl-conformance-topology-machine --test-show-details=direct
```

Pass `--test-options` only to `keiro-dsl:test:keiro-dsl-test`. The target `keiro-dsl:tests`
runs every suite, and the conformance suites fail on an option they do not know.

Regenerate one golden (repeat for each fixture source and for the workspace manifest):

```bash
nix develop -c bash -c 'cabal run -v0 keiro-dsl -- topology keiro-dsl/test/fixtures/topology/hospital-capacity.keiro \
  | sed "s/\"version\":\"[0-9.]*\"/\"version\":\"<version>\"/" \
  > keiro-dsl/test/fixtures/topology/hospital-capacity.topology.golden.json'
git diff --stat keiro-dsl/test/fixtures/topology/
```

Check first how `TopologySpec.hs` compares goldens; if it has its own way to write them,
use that instead of `sed`.

Reproduce finding 3 before fixing it, and confirm the fix, in a scratch directory:

```bash
cp keiro-dsl/test/fixtures/topology/hospital-capacity.keiro /tmp/svc.keiro
nix develop -c cabal run -v0 keiro-dsl -- scaffold /tmp/svc.keiro --out /tmp/gen --topology-out /tmp/gen
ls /tmp/gen
```

Before the fix `ls` lists generated files and the command ends with an uncaught exception.
After it:

```text
scaffold: --topology-out /tmp/gen cannot be written: it is a directory; nothing was written
ls: /tmp/gen: No such file or directory
```

Expected proof output after Milestone 4, one line per suite:

```text
topology machine proof: 2 aggregates match keiki
```

Commit at each milestone with a Conventional Commits message and these trailers:

```text
feat(keiro-dsl): export the aggregate category and dispatch dedupe read model in the topology

ExecPlan: docs/plans/343-close-the-review-findings-on-the-keiro-dsl-service-topology-export.md
Intention: intention_01m7nb12awezmsvq5wra3eeh2b
```


## Validation and Acceptance

Accepted when all of the following hold.

Every aggregate node of an exported document has `details.category`, and for
`hospital-capacity.keiro` those values equal the inspector names in the scaffolded
`Inspection` module. Every dispatch node has `details.dedupReadModel` equal to the target
of its `reads` edge with `role: dedupe`. The golden documents differ from their previous
versions only by those added fields.

`scaffold --topology-out` naming an existing directory exits 1 with a message ending
`nothing was written`, and `--out` contains no generated file. A successful run writes the
document and leaves no temporary file.

`topology --check` after a workspace `service` rename names the recorded and current
service, and does not mention the keiro-dsl version. After a member edit it still names
the member and both digests.

`just topology-schema-validate` passes on the committed tree and fails on each of the two
deliberately broken examples.

Each suite using the proof prints its aggregate count, and at least four suites run it.

Guarantees that must not weaken, and the check that measures each:

- *The document contract stays backward compatible.* The schema ids are unchanged and both
  new fields are optional. Measured by `just topology-schema-validate`, which validates
  `keiro-dsl/test/fixtures/topology/schema-examples/aggregate-without-machine.valid.json`
  unedited.
- *The three ways of producing the document agree on its bytes.* `topology`,
  `scaffold --topology-out` and `topology --check` all call `renderTopology`. Measured by
  the existing tests in `TopologySpec.hs` that compare them, which must pass unedited.
- *Workspace output is unchanged by the digest change.* Measured by the workspace golden
  `keiro-dsl/test/fixtures/topology/workspace/service.topology.golden.json` being
  byte-identical before and after Milestone 2.
- *Scaffold output is unchanged.* Nothing here touches generated Haskell. Measured by
  `just conformance-corpus-policy`.
- *No export fails on a specification `check` accepts.* Run the sweep below before and
  after; both runs must report `internal=0`.

```bash
nix develop -c bash -c 'BIN=$(cabal list-bin exe:keiro-dsl); i=0; for f in $(git ls-files "*.keiro" "*.keiro-workspace"); do "$BIN" topology "$f" 2>&1 >/dev/null | grep -q "internal error\|cannot index" && i=$((i+1)); done; echo internal=$i'
```

Finally:

```bash
nix develop -c just user-documentation-validate
nix develop -c just adr-validate
nix develop -c just verify
```

`just verify` ends with `record-migration-policy`, which needs
`python3 scripts/generate-record-migration-manifests.py` after records are added or
changed.


## Idempotence and Recovery

Every step can be repeated. Regenerating a golden twice gives the same bytes. The scratch
directories under `/tmp` can be deleted at any time. The two deliberate breakages in
Milestone 3 are made to committed example files; restore them with
`git checkout -- keiro-dsl/test/fixtures/topology/schema-examples/` and confirm
`git status` is clean before committing.

One change is not backward compatible for users and is intended: after upgrading, a
service's committed topology is stale until regenerated. The CHANGELOG entry says so.

If a widened proof finds a real difference in Milestone 4 that cannot be fixed within this
plan, leave that corpus out, name it and the difference in Surprises & Discoveries, and do
not mark the milestone complete.


## Interfaces and Dependencies

No new package dependency.

In `keiro-dsl/src/Keiro/Dsl/Topology.hs`, an aggregate node's `details` gain `category`
(string) and a dispatch node's `details` gain `dedupReadModel` (string). No exported
Haskell type changes unless the category derivation is moved out of
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` into a shared function; if so, name it for what it
returns and keep the scaffold's generated output byte-identical.

In `keiro-dsl/app/Main.hs`, `topologySummary` returns the service, source and schema in
addition to members and generator version. `prepareTopologyOut` returns the temporary path
with the target, and `writeTopologyOut` renames it.

Plan `docs/plans/342-serve-the-committed-service-topology-to-keiro-ui-through-keiro-ops-http.md`
depends on Milestone 1 here: its keiro-ui join table uses `details.category`.
