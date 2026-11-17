---
id: 339
slug: keep-committed-topology-exports-fresh-and-publish-the-service-topology-contract
title: "Keep committed topology exports fresh and publish the service-topology contract"
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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T16:15:04Z
      mode: "implement"
      note: "EP-2 implemented: --topology-out, --check, DOC-35, JSON Schema gate and IR-62 response"
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

# Keep committed topology exports fresh and publish the service-topology contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl` is the command-line tool in this repository that reads `.keiro` service
specifications and generates Haskell from them with its `scaffold` command. A prior plan,
`docs/plans/338-emit-a-versioned-service-topology-document-from-keiro-dsl-topology.md`, added
`keiro-dsl topology <source-or-workspace> --format json`, which prints a JSON document with
schema id `keiro-dsl/service-topology/1` describing a service's parts (nodes) and the
relations between them (edges), with a sha256 digest of each source file.

That document is meant to be committed in the service's repository and read by other tools,
first of all the Mori project's registry. A committed file is only useful if it stays in step
with the sources and if its shape is written down. After this plan:

A service that already runs `keiro-dsl scaffold` on every specification change can add
`--topology-out FILE` and get the topology document written by the same run.

A service's continuous-integration gate can run `keiro-dsl topology SOURCE --check FILE`. It
exits zero when the committed file matches the sources, and non-zero, naming the stale member
file, when it does not.

A reader can open `docs/user/keiro-dsl-service-topology.md` and
`docs/user/schemas/keiro-dsl-service-topology-1.schema.json` to learn every field, node kind
and relation, and the compatibility policy. The repository's own gate validates the golden
documents against that schema.

This implements acceptance criteria AC-3, AC-4 and AC-5 of the improvement request
`docs/improvement-requests/export-a-versioned-service-topology-from-keiro-dsl.md` (IR-62).
This plan is child EP-2 of
`docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md`.


## Progress

- [x] Milestone 1 (2026-11-17): `scaffold --topology-out FILE` writes bytes equal to
      `topology` for hospital-capacity and the two-member workspace; a refused scaffold writes
      no file; aliasing the input or the ledger is refused with both files' bytes unchanged.
      Evidence: the `scaffold --topology-out …` and `refuses an export path …` examples in
      `keiro-dsl/test/Keiro/Dsl/TopologySpec.hs`.
- [x] Milestone 2 (2026-11-17): `topology --check FILE` is silent with exit 0 on fresh sources;
      exit 1 names an edited member, a new and a removed workspace member, a version-only
      difference, and an unreadable file. Evidence: four `topology --check …` examples;
      `--match "service topology"` reports 32 examples, 0 failures.
- [x] Milestone 3 (2026-11-17): `docs/user/keiro-dsl-service-topology.md` (DOC-35),
      `docs/user/schemas/keiro-dsl-service-topology-1.schema.json`, the CLI page sections,
      `scripts/check-topology-schemas.sh` behind `just topology-schema-validate` (in
      `_verify`) with `check-jsonschema` 0.38.0 in the shell, and the IR-62 response. Evidence:
      `just topology-schema-validate` validates 4 goldens and fails on a golden edited to
      relation `haunts` (then restored); `just user-documentation-validate` reports 35
      concepts OK; `okf validate docs/improvement-requests` reports 63 concepts OK.
      Owed by EP-3 and EP-4 when they land: `machine` and the `/2` schema (each plan extends
      these files itself, as the MasterPlan's Integration Points describe).


## Surprises & Discoveries

- `.keiro` comments start with `#`. The plan's hand example appended `-- edited`, which is a
  parse error, so the check then fails with a parse diagnostic instead of the stale-member
  message. The tests append `# edited`.

- `okf validate docs/user --strict` accepts a `schemas/` subdirectory holding a JSON file;
  `okf index --write` adds a `schemas/index.md` and a "Subdirectories" section to
  `docs/user/index.md`. The fallback location under `keiro-dsl/schemas/` was not needed.

- `check-jsonschema` is available in the pinned nixpkgs (0.38.0); adding it changed no lock
  file.


## Decision Log

- Decision: The freshness check is a flag on the `topology` command
  (`--check FILE`), not a new subcommand and not a mode of `scaffold`.
  Rationale: The check regenerates exactly what `topology` prints and compares, so it shares
  that command's inputs. `scaffold` has no check mode today and IR-62 asks that the scaffold
  ledger not change.
  Date: 2026-11-17

- Decision: The check reports two distinct causes: a member whose sha256 differs from the one
  recorded in the committed file, and a regenerated document that differs although all
  digests match (for example after upgrading `keiro-dsl`, because `generator.version` is part
  of the document).
  Rationale: IR-62 AC-4 names both. Telling them apart tells the author whether they forgot
  to regenerate after an edit or after a tool upgrade.
  Date: 2026-11-17

- Decision: `--topology-out` writes the file only after scaffold succeeds, and the document
  is computed before scaffold writes anything.
  Rationale: A refused scaffold must not leave a fresh topology beside stale generated code,
  and an export failure must not leave generated code written with no export.
  Date: 2026-11-17

- Decision: `renderTopology` returns `IO (Either [Text] ByteString)` rather than `[String]`.
  Rationale: every diagnostic renderer it calls already returns `Text`.
  Date: 2026-11-17

- Decision: The scaffold alias check refuses an export path equal (after `canonicalizePath`)
  to the source or manifest, any workspace member, or any planned module under `--out`, and
  any file directly under `--out` whose name begins `keiro-dsl-` (ledgers, Cabal fragments,
  build manifests, migration reports).
  Rationale: Scaffold writes all its records with that prefix directly under `--out`, so one
  rule covers present and future record files without listing them.
  Date: 2026-11-17

- Decision: The EP-2 tests live in `keiro-dsl/test/Keiro/Dsl/TopologySpec.hs` beside EP-1's,
  not in the `describe "scaffold"` area of `keiro-dsl/test/Main.hs`.
  Rationale: They exercise the topology flags through the executable and share that module's
  helpers; `--match "service topology"` runs them all.
  Date: 2026-11-17

- Decision: The schema validator script is `scripts/check-topology-schemas.sh`; it first checks
  every topology schema against the JSON Schema metaschema, then validates each golden (found
  recursively) against `docs/user/schemas/keiro-dsl-service-topology-N.schema.json` for its own
  schema id `keiro-dsl/service-topology/N`, failing on an unknown id or a missing schema file.
  Rationale: EP-4 adds `/2` without editing the recipe.
  Date: 2026-11-17

- Decision: JSON Schema validation runs as a `just` recipe using a validator from the Nix
  development shell, not as a Haskell test.
  Rationale: The repository has no JSON Schema library and no validator in its shell. A
  command-line validator avoids a new Haskell dependency for one check, and `just verify` is
  where the repository's document gates already live.
  Date: 2026-11-17


## Outcomes & Retrospective

Completed 2026-11-17. A service can now refresh its committed topology from its scaffold run
and gate it with `topology --check`. The contract is documented and schema-checked in the
repository gate, and IR-62 is completed with keiro's answers and the list of differences from
Mori's draft. Because `topology`, `--topology-out` and `--check` all call `renderTopology`,
they cannot disagree on the bytes; EP-1's goldens passed unchanged after the refactor. The full
`just verify` gate runs once on the final tree (MasterPlan decision).


## Context and Orientation

All paths are relative to the repository root. Run every build and test inside the Nix
development shell from the repository root, as `AGENTS.md` requires.

This plan requires the prior plan to be complete. Confirm it before starting:

```bash
nix develop -c cabal run -v0 keiro-dsl -- topology keiro-dsl/test/fixtures/topology/hospital-capacity.keiro --format json | head -c 80
```

must print the start of a JSON document. The prior plan provides the module
`keiro-dsl/src/Keiro/Dsl/Topology.hs` with `buildServiceTopology` (builds the document value
from a loaded workspace and a list of member digests), `encodeServiceTopology` (canonical
bytes ending in one newline), `memberDigest` (the text `sha256:<hex>` of a file's bytes) and
`topologySchemaId`. It also provides fixtures and golden documents under
`keiro-dsl/test/fixtures/topology/`, and the `Topology` constructor of `data Command` in
`keiro-dsl/app/Main.hs` with its `run` clauses. Read those `run` clauses first; this plan
factors their load-check-build-encode steps into one function that the scaffold path and the
check path also call.

`keiro-dsl/app/Main.hs` uses `optparse-applicative`. The `scaffold` command is the
`Scaffold` constructor of `data Command`, which today carries positional fields for
`--out`, `--module-root`, `--runtime-package`, `--collocate`, `--force-generated-overwrite`,
`--apply-name-migrations`, `--apply-generated-haskell-edition`, `--goldens`, and
`--codec-comparison` with `--comparison-out`. It is dispatched in `run (Scaffold …)` for a
single source and in `runWorkspaceScaffold` for a workspace. Both call an `execute…` function
from `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` or
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` that runs every preflight check before writing
any file and returns `Either [Refusal] report`. The function `writeCheckReportFile` in
`Main.hs` shows the local pattern for writing an output file: create the parent directory,
then write.

Scaffold records what it generated in a text file called the ledger
(`keiro-dsl-ledger.context.<context>.txt` or `keiro-dsl-ledger.workspace.<service>.txt`).
This plan must not add anything to the ledger.

User documentation lives in `docs/user/` as an OKF bundle: Markdown files with YAML
frontmatter, each with a stable `docId` such as `DOC-33`, validated against the profile
`mori/user-documentation-profile.dhall`. OKF is the documentation tooling used across these
repositories; its command is `okf`. The page `docs/user/keiro-dsl-cli.md` documents each
command in a `### \`command\`` section and is where `topology` and the new flags must be
described. The gate is the recipe `user-documentation-validate` in `Justfile`. Before
creating a page, copy the frontmatter of an existing page such as
`docs/user/keiro-dsl-cli.md`, and allocate the next `docId` with
`okf id next docs/user --profile mori/user-documentation-profile.dhall DOC` rather than
counting files. `docs/user/index.md` and `docs/user/log.md` are reserved files; add the new
page to the index and add a log entry with `okf log add`, following the latest entries
already in `log.md`.

The repository gate is `just verify`, whose recipe `_verify` in `Justfile` lists many
prerequisite recipes. Tools for the shell are declared in `flake.module.nix` under
`haskellProject.extraDevPackages`, which is where the `z3` solver is already added.

Improvement requests live in `docs/improvement-requests/`, also an OKF bundle, with a
`status` frontmatter field whose values in use are `proposed`, `accepted`, `in-progress`,
`completed` and `superseded`, a `timestamp` field, and a `log.md`.

Relevant ADRs: `docs/adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md`
(what a workspace and its members are) and
`docs/adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md`
(why the ledger is a guarded format that this plan leaves alone). The cross-repository
decision `mori://shinzui/mori/okf/adrs/concepts/ADR-33` establishes the public-interface
boundary for sibling invocation. IR-62 in
`docs/improvement-requests/export-a-versioned-service-topology-from-keiro-dsl.md` supplies
the specific requirement that this consumer read a committed export.

Two later plans extend the files this plan creates and are not needed to implement it:
`docs/plans/340-export-aggregate-machines-in-keiki-vocabulary-and-verify-them-against-generated-transducers.md`
adds a `machine` object to aggregate node details, and
`docs/plans/341-declare-and-check-the-intake-that-feeds-a-process-or-router-input-and-export-it-as-a-topology-edge.md`
adds a `feeds` relation under schema id `keiro-dsl/service-topology/2`. If either has already
been implemented when Milestone 3 of this plan is done, its Progress section will say that
documentation of its addition is owed; in that case document and schematize what the code
emits, including those additions. Validate each golden recursively, including the workspace
subdirectory, against the schema named by its `schema` field. If EP-3 is already present,
both `/1` and `/2` must describe `machine` as optional for older documents and validate all
its fields when present. Keep an example without `machine` as a compatibility test.


## Plan of Work

### Milestone 1: scaffold writes the topology

In `keiro-dsl/app/Main.hs`, extract from the existing `topology` clauses one function that,
given the source or manifest path, returns either the diagnostics that refuse the export or
the encoded bytes. Name it `renderTopology` and give it the signature in Interfaces and
Dependencies. The `topology` command, the scaffold flag and the check all call it, which is
what guarantees AC-3's "same document".

Add an optional `--topology-out FILE` to the `scaffold` parser and a `Maybe FilePath` field
to the `Scaffold` constructor. Only when `--topology-out` is present, in both scaffold paths call `renderTopology` before the
`execute…` call; if it fails, print its diagnostics and exit non-zero without scaffolding.
After `execute…` returns success, create the file's parent directory and write the bytes.
Write nothing when scaffold is refused. Without the flag, preserve the existing scaffold
path and avoid the extra load/check/export. Before any scaffold write, reject an export path
that aliases an input file, workspace manifest/member, generated module, create-once hole,
ledger or Cabal fragment; compare normalized paths and resolve existing symlinks. Test these
collisions and assert all existing bytes remain unchanged. A writable unrelated export file
may be replaced as documented. Filesystem write failure must return non-zero; this does not
promise a transaction across all scaffold output files.

Add tests to the `describe "scaffold"` area of `keiro-dsl/test/Main.hs`: scaffold a topology
fixture into a temporary directory with `--topology-out`, run `topology` on the same input,
and assert the file's bytes equal the command's standard output; repeat for the workspace
fixture; and assert that a refused scaffold leaves no topology file.

### Milestone 2: the freshness check

Add an optional `--check FILE` to the `topology` parser. When present, the command prints no
document. It reads the committed file, calls `renderTopology`, and compares bytes. If they
are equal it exits zero and prints nothing. Otherwise it decodes the committed file's
`members` list and compares each recorded `sha256` with the digest of the current member
file. For every member that differs, is missing from the sources, or is new, it prints one
line to standard error; if no member differs it prints one line saying the document differs
although the sources are unchanged, and shows the committed and current `generator.version`.
It then exits with status 1. A committed file that does not exist or is not a topology
document is also a failure, with its own message. Use these message forms, which the tests
match:

```text
topology stale: member 'domain/orders.keiro' changed (recorded sha256:ab12…, current sha256:cd34…)
topology stale: member 'domain/returns.keiro' is not recorded in services/orders/topology.json
topology stale: recorded member 'domain/legacy.keiro' is no longer a source member
topology stale: document differs with unchanged sources (generated by keiro-dsl 0.25.1.0, current keiro-dsl 0.26.0.0); regenerate it
topology check: cannot read 'services/orders/topology.json' as a keiro-dsl service-topology document
```

Add tests: write the document for a copy of a fixture in a temporary directory, check it
(exit zero, no output), append a comment line to one member, check again (exit 1, the message
names that member), and check a file containing `{}` (exit 1, the cannot-read message).

### Milestone 3: documentation, JSON Schema and the gate

Create `docs/user/schemas/keiro-dsl-service-topology-1.schema.json`, a JSON Schema (draft
2020-12) for the document as the code emits it. Derive it from
`keiro-dsl/src/Keiro/Dsl/Topology.hs` and the golden documents, not from memory. Make the
closed sets closed: `kind` and `relation` are enumerations, `schema` is the constant
`keiro-dsl/service-topology/1`, and each node kind's `details` lists its required fields.
Make everything else open, with `additionalProperties` left permitted on every object,
because the compatibility policy lets keiro add fields within a schema id. If the `docs/user`
OKF validation rejects a non-Markdown file or a subdirectory inside the bundle, move the
schema to `keiro-dsl/schemas/keiro-dsl-service-topology-1.schema.json`, list it under
`extra-source-files` in `keiro-dsl/keiro-dsl.cabal`, and record the move in the Decision Log
and in the master plan's Integration Points.

Add a validator to the development shell by adding the `check-jsonschema` package to
`haskellProject.extraDevPackages` in `flake.module.nix`, next to `z3`. Confirm the attribute
name against the pinned nixpkgs before relying on it (`nix develop -c check-jsonschema
--version`); if it is unavailable, use another command-line JSON Schema validator from
nixpkgs and name it in the Decision Log. Add a recipe `topology-schema-validate` to
`Justfile` that validates every `*.topology.golden.json` under
`keiro-dsl/test/fixtures/topology/` against the schema, and add it to the prerequisite list
of `_verify`. If the golden files store a `<version>` placeholder for `generator.version`,
the schema's `version` field must accept any string so the placeholder validates.

Create the page `docs/user/keiro-dsl-service-topology.md` with the bundle's frontmatter and a
newly allocated `docId`. It states what the document is for; every top-level field; each of
the seventeen node kinds with its `details` fields, the five projection-catalog kinds
included; each relation with its endpoints and
attributes; the ordering and canonical encoding rules that make the bytes stable; and the
compatibility policy in these terms: within one schema id keiro may add object fields and
consumers must ignore fields they do not know, while a new node kind, a new relation or a
changed meaning requires a new schema id, so a consumer must reject a schema id, node kind or
relation it does not know. It also states what is deliberately not exported (wire, codec and
guard detail; a projection revision's provisioner, validator and promotion-object fields;
broker and runtime configuration), that workflows have no `dispatches` edges,
and that a `projects` edge points at the aggregate owning the projection table. Add
`### \`topology\`` to `docs/user/keiro-dsl-cli.md` covering `--format` and `--check`, add
`--topology-out` to its `scaffold` section, and show the two-line recipe a service adds to
its generated-code gate. Add the page to `docs/user/index.md` and record the change in
`docs/user/log.md`.

Update `docs/improvement-requests/export-a-versioned-service-topology-from-keiro-dsl.md`: set
`status` to `completed` if every criterion is met, advance `timestamp`, and add a section
"Keiro's response" that links the documentation page and states the answers and the points
where the shipped contract differs from Mori's draft: the projection catalog is included,
as five node kinds and ten relations that the request had listed as out of scope; `projects`
edges end at the owning aggregate; `source.path` and member paths are location-independent; reorder invariance
excludes `line` and `sha256`; workflows have no `dispatches` edges; and the process detail
field is `inputs`. Add the matching entry to `docs/improvement-requests/log.md` as its
existing entries do. Add a `keiro-dsl/CHANGELOG.md` entry under `## [Unreleased]`.


## Concrete Steps

Work from the repository root.

```bash
nix develop -c cabal build keiro-dsl
nix develop -c cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct --test-options='--match "topology"'
```

Try the check by hand in a scratch directory:

```bash
tmp=$(mktemp -d)
cp keiro-dsl/test/fixtures/topology/hospital-capacity.keiro "$tmp/"
nix develop -c cabal run -v0 keiro-dsl -- topology "$tmp/hospital-capacity.keiro" > "$tmp/topology.json"
nix develop -c cabal run -v0 keiro-dsl -- topology "$tmp/hospital-capacity.keiro" --check "$tmp/topology.json"; echo "exit $?"
echo "-- edited" >> "$tmp/hospital-capacity.keiro"
nix develop -c cabal run -v0 keiro-dsl -- topology "$tmp/hospital-capacity.keiro" --check "$tmp/topology.json"; echo "exit $?"
```

Expected output:

```text
exit 0
topology stale: member 'hospital-capacity.keiro' changed (recorded sha256:…, current sha256:…)
exit 1
```

Documentation and schema gates:

```bash
nix develop -c just topology-schema-validate
nix develop -c just user-documentation-validate
```

Commit at each milestone with a Conventional Commits message and these trailers:

```text
feat(keiro-dsl): write and check committed topology exports

MasterPlan: docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md
ExecPlan: docs/plans/339-keep-committed-topology-exports-fresh-and-publish-the-service-topology-contract.md
Intention: intention_01m7n03hbfem79q2brf07rneyq
```


## Validation and Acceptance

The file written by `scaffold --topology-out FILE` is byte-equal to the standard output of
`topology` for the same input, for a single source and for a workspace (AC-3), and a refused
scaffold writes no topology file.

`topology --check FILE` exits zero with no output on unchanged sources, and exits 1 with a
line naming the member after that member is edited (AC-4).

`just topology-schema-validate` passes over every golden document, and fails when a golden
document is edited to contain an unknown `relation` value; try that by hand once and restore
the file. `just user-documentation-validate` passes (AC-5).

Guarantees that must not weaken, with the check that measures each: the scaffold ledger and
generated modules are unchanged by the new flag, measured by the existing scaffold and
conformance-corpus tests (`nix develop -c bash scripts/check-conformance-corpus.sh` must
report no drift); and the `topology` command's output is unchanged by the refactor into
`renderTopology`, measured by the prior plan's golden tests passing without regenerating
them.

Finally the full gate passes:

```bash
nix develop -c just verify
```


## Idempotence and Recovery

All steps are additive and repeatable. `--topology-out` overwrites its target file each run,
which is the intended behavior for a regenerated artifact. The check never writes. If adding
the validator to `flake.module.nix` changes `flake.lock` unexpectedly, revert the lock file
change and add only the package reference. Documentation changes can be re-validated at any
time with the two `just` recipes above.


## Interfaces and Dependencies

One new development-shell tool, `check-jsonschema` (or the substitute recorded in the
Decision Log). No new Haskell package.

In `keiro-dsl/app/Main.hs`, at the end of Milestone 1:

```haskell
-- | Load, check and export the source or workspace at the given path.
-- Left carries the rendered diagnostics that refuse the export.
renderTopology :: FilePath -> IO (Either [String] ByteString)
```

The `Scaffold` constructor gains a trailing `Maybe FilePath` for `--topology-out`, and the
`Topology` constructor gains a `Maybe FilePath` for `--check`.

Files created: `docs/user/keiro-dsl-service-topology.md`,
`docs/user/schemas/keiro-dsl-service-topology-1.schema.json`. Recipe created:
`topology-schema-validate` in `Justfile`, listed in `_verify`.


Revision note, 2026-11-17: the `/1` contract now includes the projection catalog, so the
documentation page, JSON Schema and IR-62 response in Milestone 3 cover seventeen node kinds
and twenty-two relations instead of twelve and twelve.


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
