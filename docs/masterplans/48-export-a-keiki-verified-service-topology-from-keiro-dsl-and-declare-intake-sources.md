---
id: 48
slug: export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources
title: "Export a keiki-verified service topology from keiro-dsl and declare intake sources"
kind: master-plan
created_at: 2026-11-17T14:55:55Z
intention: "intention_01m7n03hbfem79q2brf07rneyq"
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

# Export a keiki-verified service topology from keiro-dsl and declare intake sources

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

`keiro-dsl` is the compiler and command-line tool in this repository (package directory
`keiro-dsl/`) that reads `.keiro` service specifications and generates Haskell. Today none of
its outputs describe how the parts of a service connect. This initiative implements two
improvement requests filed by the Mori project, recorded in this repository as
`docs/improvement-requests/export-a-versioned-service-topology-from-keiro-dsl.md` (IR-62) and
`docs/improvement-requests/declare-which-intake-feeds-a-process-or-router-input.md` (IR-63).

When the initiative is complete, a service author can do the following.

Run `keiro-dsl topology <source-or-workspace> --format json` and receive one byte-stable JSON
document, with schema id `keiro-dsl/service-topology/1`, that lists every aggregate, process,
workflow, router, contract, intake, emit, publisher, workqueue, dispatch, read model and
operation the service declares, together with its projection catalog (projection targets,
rebuild groups, projection owners, projection revisions and external reads), and every
relation between them. A reader can trace an aggregate through the projection owner that
consumes its events and the target table that owner writes to the read model served from it. The document carries a
sha256 digest of each source member, so a reader can tell when a committed copy is older than
its sources.

Keep that document committed and fresh with no extra step, by passing `--topology-out FILE`
to the `keiro-dsl scaffold` run the service already performs, and gate it with
`keiro-dsl topology --check FILE`, which exits non-zero and names the stale member.

See each aggregate's state machine inside the document, in the vocabulary of keiki. Keiki is
the sibling library (`mori://shinzui/keiki`) on which every Keiro aggregate is built: an
aggregate is a keiki "transducer", a finite state machine whose edges each consume one command
and emit events. A process manager's own state is a "saga" aggregate, so it is a keiki machine
too. The exported machine lists states, the initial and terminal states, and every edge with
its keiki edge index, its `Live` or `ReplayOnly` mode, its command and its emitted events. A
conformance suite compiles generated code, walks the real keiki transducers with keiki's own
accessors, and fails if the exported machine differs from them.

Declare, in the spec, which intake feeds a process or router input
(`input AcceptedHospitalCapacitySnapshot from intake hospitalInbox event HospitalCapacitySnapshotPublished { ... }`),
have `keiro-dsl check` reject a source that names no such intake or an event the intake does
not accept, and see the connection in the topology as a `feeds` edge under schema id
`keiro-dsl/service-topology/2`.

Read a user-documentation page and a checked-in JSON Schema that define both schema ids and
the compatibility policy.

Out of scope: wire, codec, guard and register-update detail; a projection revision's
provisioner, validator and promotion-object detail; broker, consumer-group and runtime configuration; changes to existing `check`, `diff`,
`inspect` output for unsourced specifications or to the scaffold ledger file; moving the hand-written inbox-to-input
conversion into generated code; input sources other than intakes; and anything specific to
Mori. Adopting the export in the sibling example repository
`mori://shinzui/keiro-runtime-jitsurei` is also out of scope. That repository pins an older
keiro commit and its two specs are legacy-unversioned (Language 1) sources, so its adoption
follows a keiro release and is tracked there, not here. Rendering diagrams (keiki's Mermaid
and SCXML renderers) from the topology is not part of this initiative.


## Decomposition Strategy

The work splits into four child plans along four separately verifiable behaviors.

EP-1 defines the `keiro-dsl/service-topology/1` contract as Haskell types and a canonical
encoder, and ships the `topology` command with golden tests. The projection catalog is a
milestone of EP-1 rather than a plan of its own, because it is more nodes and edges built by
the same module, encoder and golden mechanism, and because it must land before `/1` is
documented and consumed. Everything else consumes this.

EP-2 makes the export adoptable: the scaffold flag, the freshness check, the user
documentation, the JSON Schema and the gate that validates golden documents against it. These
belong together because each is about a service or a consumer relying on the document over
time, and none changes the document's content.

EP-3 adds the aggregate machine detail and the proof that it equals the real keiki
transducer. It is separate from EP-1 because its acceptance needs a compiled generated corpus
and keiki at test time, while EP-1's acceptance is pure golden comparison. Keeping it separate
also keeps the user's keiki requirement visible as its own deliverable with its own evidence.

EP-4 implements IR-63: grammar, checker, and the `feeds` edge under a new schema id. Its
grammar and checker milestones are independent of the export, which is why IR-63 was filed
separately.

Two alternatives were rejected. A single ExecPlan would hide that the grammar change (EP-4)
and the keiki proof (EP-3) can proceed in parallel with adoption work (EP-2) once EP-1 lands.
Splitting documentation and the JSON Schema into a fifth plan would create a plan with no
behavior of its own. Instead EP-2 owns those files and EP-3 and EP-4 extend them.

The user chose, on 2026-11-17, how keiki is used: the export is computed by the `keiro-dsl`
command from the checked specification alone, and a conformance suite verifies it against real
generated keiki transducers. The alternative of generating a module that each service compiles
and runs to produce the machine section was rejected because a committed export would then
need a service build, which conflicts with IR-62's model of a command-line export whose
freshness follows from source digests. Research supporting this: keiki 0.9.1.0 has no JSON or
structured graph export (its structure outputs are Mermaid text, a Markdown edge inventory,
and an unreleased SCXML renderer); keiki machines exist only in generated Haskell that a
service compiles; and `keiro-dsl` lists keiki as a dependency but imports nothing from it.
`keiro-dsl` already predicts keiki edge identity from the specification
(`behaviorEdgeIndex` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`), and generated code already
indexes real edges with `K.edgesOut transducer source`.

Relevant local ADRs, each read for this plan:

`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md` governs new
syntax. New forms are registered as a language feature in the active candidate language's
syntax profile; a candidate that is registered but not yet finalized is corrected in place;
predecessors must keep rejecting the new form, proven by fixtures; new keywords are
contextual, never globally reserved. This binds EP-4.

`docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md` requires
positive DSL fixtures, including source embedded in tests, to select Language 6. This binds
every fixture added by EP-1, EP-3 and EP-4.

`docs/adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md`
defines a workspace: several `.keiro` member files composed under one manifest whose `service`
name is the durable identity and whose members each own their declarations. The topology's
`service`, `members` and per-node `member` fields follow it.

`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md` explains
keiki's `ReplayOnly` edge mode, which EP-3 exports.

`docs/adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md`
explains why a legacy aggregate's machine may be hand-written and therefore cannot be
verified by EP-3.

`docs/adr/0061-generated-aggregate-inspector-catalogs-cover-every-dsl-aggregate.md` and
`docs/adr/0054-aggregate-inspection-reuses-hydration-without-diagnostics-on-the-command-path.md`
are the precedent for context-level structure derived from the specification; this initiative
does not change them.

`docs/adr/0038-keiro-dsl-records-use-concise-labels-without-product-selectors.md` governs
record style in new `keiro-dsl` modules (`NoFieldSelectors`, record dot).

The cross-repository decision `mori://shinzui/mori/okf/adrs/concepts/ADR-33` establishes
Mori's public-interface boundary for outbound sibling invocation. Applying that principle
here supports a keiro-owned contract; the specific requirement to ingest a committed export
rather than parse `.keiro` files comes from IR-62 in
`docs/improvement-requests/export-a-versioned-service-topology-from-keiro-dsl.md`.

Decisions in this initiative that deserve a new ADR at completion: that the service topology
is a versioned public contract owned by keiro, with its compatibility policy and
minimum-version emission rule; that machine structure is exported from the specification and
proven against keiki rather than produced by running service code; and that a declared input
source is checked documentation with no runtime or identity effect.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Emit a versioned service topology document from keiro-dsl topology | docs/plans/338-emit-a-versioned-service-topology-document-from-keiro-dsl-topology.md | None | None | Not Started |
| 2 | Keep committed topology exports fresh and publish the service-topology contract | docs/plans/339-keep-committed-topology-exports-fresh-and-publish-the-service-topology-contract.md | EP-1 | None | Not Started |
| 3 | Export aggregate machines in keiki vocabulary and verify them against generated transducers | docs/plans/340-export-aggregate-machines-in-keiki-vocabulary-and-verify-them-against-generated-transducers.md | EP-1 | EP-2 M3 | Not Started |
| 4 | Declare and check the intake that feeds a process or router input and export it as a topology edge | docs/plans/341-declare-and-check-the-intake-that-feeds-a-process-or-router-input-and-export-it-as-a-topology-edge.md | EP-1 (for its M3 only) | EP-2 M3 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
A whole-child hard dependency requires that child to be Complete. If only a milestone's
accepted output is needed, name it explicitly (e.g., EP-1 M1) and explain it below.


## Dependency Graph

EP-1 has no dependencies and goes first. It produces the library module
`Keiro.Dsl.Topology`, the `topology` command, and the golden documents.

EP-2 hard-depends on the whole of EP-1 because its scaffold flag and freshness check call
EP-1's encoder, and its JSON Schema describes EP-1's final document.

EP-3 hard-depends on the whole of EP-1 because it adds a field to EP-1's aggregate node and
regenerates EP-1's golden documents.

EP-4's Milestones 1 and 2 (grammar and checker) have no dependency and may start at any time,
in parallel with EP-1. Its Milestone 3 (the `feeds` edge and schema id `/2`) hard-depends on
the whole of EP-1.

EP-3 and EP-4 M3 each soft-depend on EP-2 Milestone 3, whose output is the documentation page
`docs/user/keiro-dsl-service-topology.md` and the schema file
`docs/user/schemas/keiro-dsl-service-topology-1.schema.json`. If those files exist when EP-3
or EP-4 M3 is implemented, that plan extends them. If they do not exist yet, the plan records
in its Progress section that the documentation of its addition is owed, and EP-2 M3 must
include it. Each child plan states this rule itself.

The simple order is EP-1, EP-2, EP-3, EP-4. After EP-1 is Complete, EP-2, EP-3 and EP-4 M3
may proceed in parallel, subject to the shared-file rules under Integration Points.


## Integration Points

The module `keiro-dsl/src/Keiro/Dsl/Topology.hs` is defined by EP-1. It owns the document
types, the builder from a checked service, and the canonical encoder. EP-2 calls it without
changing the document. EP-3 adds the `machine` field to the aggregate node details. EP-4 adds
the `feeds` relation and the schema id selection. The single entry points later plans rely on
are named in EP-1's Interfaces and Dependencies section: `buildServiceTopology`,
`encodeServiceTopology` and `topologySchemaId`.

The golden documents under `keiro-dsl/test/fixtures/topology/` are created by EP-1 (two
service fixtures, a workspace fixture and a projection-catalog fixture). EP-3 and
EP-4 regenerate them with `KEIRO_DSL_UPDATE_GOLDENS=1` and must review the diff: EP-3's
regeneration may only add `machine` objects to aggregate nodes, and EP-4's may only change the
document for the fixture that declares a source. Any other difference is a defect.

The fixture specifications `keiro-dsl/test/fixtures/topology/hospital-capacity.keiro` and
`keiro-dsl/test/fixtures/topology/incident-command.keiro` are created by EP-1 as Language 6
copies of the two keiro-runtime-jitsurei services. EP-4 does not edit them; it adds a separate
fixture `incident-command-sourced.keiro` so that EP-1's goldens keep proving that a spec
without a source is unchanged.

The user documentation page `docs/user/keiro-dsl-service-topology.md`, the JSON Schema files
under `docs/user/schemas/`, and the `topology-schema-validate` recipe in `Justfile` are
defined by EP-2. EP-3 extends every existing topology schema and the page with `machine`; the field remains
optional for documents emitted before EP-3, with its complete shape checked when present. EP-4 adds
`keiro-dsl-service-topology-2.schema.json` and a section for `/2`. Whichever of EP-3 and
EP-4 finishes second reconciles both schemas and validates all goldens, including a sourced
service with a machine. EP-2 owns reconciliation if both additions precede its M3. Deferred
documentation is not initiative completion: EP-2 must discharge every recorded debt.

The compatibility policy is a shared rule, owned by EP-1 and published by EP-2: within one
schema id keiro may add object fields and consumers ignore fields they do not know; a new node
kind, a new relation, or a changed meaning requires a new schema id. EP-3's `machine` is an
added field and stays in `/1`. EP-4's `feeds` is a new relation and requires `/2`.

The schema id selection rule is owned by EP-4 and builds on EP-1: a document is emitted under
the lowest schema id able to represent it. A service that declares no input source produces a
`/1` document, byte-for-byte what the same generator emits without EP-4 (including EP-3 machine
fields if EP-3 has landed). A service that declares at least one produces
a `/2` document, which is `/1` plus the `feeds` relation.

The representative producer and consumer check for the uncertain interface, the equality of
exported machines and real keiki transducers, is owned by EP-3 Milestone 1, a prototyping
milestone that walks one existing generated corpus before any encoder work is done.

`keiro-dsl/app/Main.hs` (the command type and its parsers) is edited by EP-1 (new `Topology`
command), EP-2 (`--topology-out`, `--check`) and not by EP-3 or EP-4. `keiro-dsl/CHANGELOG.md`
receives one entry per child plan under `## [Unreleased]`.

The improvement-request records are updated at the end: EP-2 marks IR-62 and answers its two
questions in the record; EP-4 marks IR-63. Both follow the status vocabulary already used in
`docs/improvement-requests/` (`proposed`, `accepted`, `in-progress`, `completed`).


## Progress

No child plan has started. All four were reviewed on 2026-11-17 and corrected in this update. No implementation
acceptance has run. Dependency source, sibling fixtures and the cross-repository ADR have
now been verified through Mori; no review blocker remains. EP-1 is ready to start.

Cross-plan gates not owned by a single child:

- [ ] After all four children are Complete, `nix develop -c just verify` passes on the final
      tree, and the ADR distillation pass has recorded the three decisions named under
      Decomposition Strategy.
- [ ] The contract divergences from Mori's draft, listed in the Decision Log, are communicated
      to `mori://shinzui/mori/masterplans/45-expose-keiro-service-topology-through-a-mori-extension-and-the-http-api`
      by updating the IR-62 and IR-63 records in this repository.


## Surprises & Discoveries

- The two keiro-runtime-jitsurei specifications that IR-62 names as its acceptance pair are
  not in this repository and are legacy-unversioned (Language 1) sources, although Mori's
  draft document shows `languageVersion: 6`. They do pass `keiro-dsl check` at this
  repository's HEAD. EP-1 therefore vendors Language 6 copies as fixtures, as ADR-49 requires.
  Evidence: `head -3` of `services/incident-command/spec/incident-command.keiro` in
  `mori://shinzui/keiro-runtime-jitsurei` shows `context incident-command` with no `language`
  line.

- The projection catalog is declared only by fixtures unrelated to the two example services:
  neither keiro-runtime-jitsurei specification has a catalog declaration, and the one
  in-repository fixture that declares all five catalog kinds,
  `keiro-dsl/test/fixtures/projection-catalog.keiro`, is a Language 5 source. EP-1 adds a
  Language 6 copy as a third golden fixture.

- A `projections` entry on a process or router does not name a read-model declaration. It
  names the `table` of an aggregate's `projection` clause, and validation already rejects a
  name that matches none (`projectionTables` in `keiro-dsl/src/Keiro/Dsl/Validate.hs`). This
  answers IR-62's first question: a `projects` edge always resolves, and its endpoint is the
  aggregate that owns the table.

- IR-62's byte-stability criterion asks that reordering declarations not change the output,
  but the draft document also carries each node's `line` and each member's `sha256`, both of
  which necessarily change when a file is reordered. See the Decision Log.

- No JSON Schema file and no JSON Schema validator exist in this repository or its Nix
  development shell. EP-2 adds one to the shell.


## Decision Log

- Decision: The export is computed by the `keiro-dsl` command from the checked specification,
  and its aggregate machine detail is verified against real generated keiki transducers by a
  conformance suite (EP-3), rather than produced by running service code.
  Rationale: Chosen by the user on 2026-11-17 from four options. It keeps IR-62's
  command-line, source-digest freshness model while still binding the export to keiki.
  Date: 2026-11-17

- Decision: The projection catalog is exported in `/1`: five node kinds
  (`projection-target`, `rebuild-group`, `projection-owner`, `projection-revision`,
  `external-read`) and ten relations (`depends-on`, `groups`, `consumes`, `writes`,
  `member-of`, `revises`, `observes`, `backed-by`, `exposes`, `compatible-with`), as EP-1
  Milestone 3.
  Rationale: Requested by the user on 2026-11-17, reversing IR-62's exclusion. Without the
  catalog the document cannot say which aggregate events feed a read model. `/1` has not
  shipped, so including the catalog now avoids a later schema id bump. The cost is that the
  first contract is larger than the closed set Mori's draft decoder and fixtures were built
  to, so Mori must extend them; the IR-62 response written by EP-2 says so.
  Date: 2026-11-17

- Decision: The `machine` detail on aggregate nodes is an added field within
  `keiro-dsl/service-topology/1`, not a new schema id.
  Rationale: Mori's assumed compatibility policy, which keiro adopts, lets keiro add fields
  within `/1` and requires consumers to ignore unknown fields.
  Date: 2026-11-17

- Decision: A `projects` edge runs from a process or router to the aggregate whose
  `projection` table the entry names, carrying the table as attribute `table`.
  Rationale: That is what the grammar and checker mean by `projections`. Mori's draft assumed
  a read-model endpoint. Keiro owns the contract and the edge always resolves.
  Date: 2026-11-17

- Decision: `source.path` and each member `path` are location-independent: the file name of
  the source or manifest, and member paths relative to the manifest directory. Node `line`
  and member `sha256` are kept. Reorder invariance is defined and tested over the document
  with member `sha256` and node `line` removed.
  Rationale: A path as typed on the command line would make the bytes depend on the working
  directory and break the freshness check. Lines and digests cannot be invariant under
  reordering, and both are valuable to consumers.
  Date: 2026-11-17

- Decision: The intake-to-component edge is the relation `feeds`, carried only by schema id
  `keiro-dsl/service-topology/2`, and a document is emitted under the lowest schema id able to
  represent it.
  Rationale: IR-63 requires a schema id that `/1` consumers will not misread, and the policy
  requires a new id for a new relation. Minimum-version emission keeps every service that
  declares no source on `/1`, so existing consumers keep working and fail closed only on
  documents they cannot represent.
  Date: 2026-11-17

- Decision: The input source syntax is `from intake <Intake> event <Event>+`, placed between
  the input name and its body, registered as a Language 6 candidate feature.
  Rationale: The checker cannot know which contract events an input is built from unless the
  specification names them, because the conversion is hand-written Haskell. Naming them lets
  `check` reject a source whose intake stops accepting the event the component depends on.
  Language 5 is published and frozen, so ADR-16 places new syntax in the candidate.
  Date: 2026-11-17

- Decision: Adoption in `mori://shinzui/keiro-runtime-jitsurei` is excluded. IR-63's fourth
  criterion (its incident-command suite passing unchanged) is replaced in this repository by
  a proof that scaffolding a sourced specification produces byte-identical generated code,
  identical fingerprints and an identical ledger to the same specification without a source.
  Rationale: That repository pins an older keiro and Language 1 sources. The in-repository
  proof measures the affected path, generated output and identity, directly.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled during and after implementation.)


Revision note, 2026-11-17: at the user's request the projection catalog moved from out of
scope into the `/1` contract, as a new Milestone 3 of EP-1. EP-2's documentation and schema
scope grew accordingly. No dependency or child plan was added.


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
