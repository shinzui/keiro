---
id: 342
slug: serve-the-committed-service-topology-to-keiro-ui-through-keiro-ops-http
title: "Serve the committed service topology to keiro-ui through keiro-ops-http"
kind: exec-plan
created_at: 2026-11-17T17:35:09Z
intention: "intention_01m7n03hbfem79q2brf07rneyq"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-17T17:35:09Z
---

# Serve the committed service topology to keiro-ui through keiro-ops-http

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl topology` (see
`docs/plans/338-emit-a-versioned-service-topology-document-from-keiro-dsl-topology.md` and
`docs/user/keiro-dsl-service-topology.md`) produces a JSON document that describes how a
service's declarations connect: aggregates with their keiki state machines, processes,
routers, intakes, emits, read models, the projection catalog, and the edges between them.
A service commits that document next to its sources (`keiro-dsl scaffold --topology-out`)
and gates it with `keiro-dsl topology --check`. Today nothing serves it, so keiro-ui, the
browser console in `mori://shinzui/keiro-ui`, cannot show a service's structure.

After this plan, a host that mounts the keiro inspection surface can also mount its
committed topology document, and a browser can read it from the same origin as every other
inspection route:

```bash
curl -fsS http://127.0.0.1:9092/topology/summary
curl -fsS http://127.0.0.1:9092/topology/show > served.json
cmp served.json services/orders/topology.json && echo identical
```

`/topology/show` returns the committed document byte for byte. `/topology/summary` returns
a small snake_case header for a console page: schema id, service name, generator version,
member digests, and node and edge counts. Like `/aggregate/*` and `/pm/*`, the routes exist
only when the host mounts the hook. A host mounts it in code
(`AppHooks.serviceTopology`) or from the command line (`--topology FILE` on any
`Keiro.Ops.Http.mainWithHooks` host, including `jitsurei-ops-http`).

The keiro-ui page that renders the topology is not part of this plan. It belongs to
`mori://shinzui/keiro-ui`. Milestone 3 writes the handoff keiro-ui needs.


## Progress

- [ ] Milestone 1: `keiro-ops` decodes and mounts a topology document
      (`Keiro.Ops.Topology`, `AppHooks.serviceTopology`), and `keiro-ops topology show` and
      `topology summary` exist only when it is mounted. Unit tests cover decoding, refusal of
      unknown schema ids, the summary shape and the hook gating.
- [ ] Milestone 2: `keiro-ops-http` serves `GET /topology/show` with the committed bytes and
      `GET /topology/summary`, refuses other methods, and reports oversize documents with
      `inspection_result_too_large`; `--topology FILE` mounts a file on any `mainWithHooks`
      host and refuses to start on an undecodable file. Tests in
      `keiro-ops-http/test/Main.hs` pass.
- [ ] Milestone 3: `jitsurei-ops-http --topology FILE` works locally against a keiro-dsl
      golden; the HTTP guide, the operations page, both CHANGELOGs and ADR-62 are updated;
      the keiro-ui handoff is written into `docs/user/keiro-dsl-service-topology.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The topology is served by a hook-gated `keiro-ops` read command group
  (`topology show`, `topology summary`), not by a hand-written route.
  Rationale: `keiro-ops-http` has no route registry. It translates `GET /a/b?x=y` into the
  `keiro-ops` command `a b --x=y` through the same parser the CLI uses
  (`keiro-ops-http/src/Keiro/Ops/Http/Route.hs`), and admission, deadlines, byte limits,
  CORS and schema verification all apply to commands. A command keeps the CLI and HTTP in
  step, as
  [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  expects of operator surfaces.
  Date: 2026-11-17

- Decision: `keiro-ops` treats the document as an opaque, schema-id-checked JSON value and
  does not depend on `keiro-dsl`.
  Rationale: `keiro-ops` depends on `keiro`, not on the specification toolchain, and the
  document is a published JSON contract
  ([ADR-62](../adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)).
  Linking `keiro-dsl` into every inspection host would add a large dependency to serve a
  file. The decoder checks only what serving needs: the `schema` id is one keiro knows
  (`keiro-dsl/service-topology/1` or `/2`), and `service`, `generator`, `members`, `nodes`
  and `edges` have the documented shapes. An unknown schema id is refused when the hook is
  mounted, the fail-closed rule of the compatibility policy.
  Date: 2026-11-17

- Decision: `/topology/show` returns the mounted bytes exactly, and only `/topology/summary`
  uses keiro-ui's snake_case field convention.
  Rationale: keiro-ui's inspection conventions (`docs/architecture/inspection-api-conventions.md`
  in `mori://shinzui/keiro-ui`, artifact-level URI pending) require snake_case for new wire
  fields but freeze published shapes. The topology document is a published, versioned
  contract with its own JSON Schemas and camelCase fields. Re-casing it would create a
  second, unversioned dialect of the same contract. Serving the exact bytes also lets the
  console validate the body against the published schema and compare member digests with
  the repository. The summary is new keiro-ops wire, so it follows the convention.
  Date: 2026-11-17

- Decision: The document reaches the host as bytes the host supplies: read from a file at
  startup (`loadServiceTopology`, `--topology FILE`) or embedded by the application. Scaffold
  does not generate a Haskell module that embeds it.
  Rationale: The committed file is already kept fresh by `scaffold --topology-out` and
  gated by `topology --check`. A generated embedding module would change generated output
  for every service, against ADR-62's rule that scaffold without `--topology-out` is
  unchanged. It would also make the topology part of the code-generation contract instead
  of a published file.
  Date: 2026-11-17

- Decision: The server does not check at runtime whether the mounted document is fresh.
  Rationale: A running host has no specification sources to digest. Freshness is enforced
  where the sources are, by `topology --check` in the service's gate. The summary exposes
  `generator_version` and member digests, so a reader can compare them with a checkout.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root. Run builds and tests in the Nix development
shell from the root (`nix develop -c …`), as `AGENTS.md` requires. Entering the shell from a
package directory creates a stray database directory under it.

**The topology document.** `keiro-dsl topology <source-or-workspace>` prints RFC 8785
canonical JSON ending in one newline. Its top-level fields are `schema`
(`keiro-dsl/service-topology/1`, or `/2` when it contains a `feeds` edge), `service`,
`source` (`kind`, `path`), `effectiveSemanticContract`, `generator` (`tool`, `version`),
`members` (each `path`, `sha256`, `declaredLanguageVersion`, `effectiveLanguageVersion`),
`nodes` (each `kind`, `name`, `context`, `member`, `line`, `details`) and `edges` (each
`from`, `to`, `relation`, `attributes`). The full contract is
`docs/user/keiro-dsl-service-topology.md` (DOC-35). The JSON Schemas are
`docs/user/schemas/keiro-dsl-service-topology-1.schema.json` and `-2.schema.json`.
Representative documents are the goldens under `keiro-dsl/test/fixtures/topology/`, for
example `hospital-capacity.topology.golden.json` (`/1`, about 19 KB) and
`incident-command-sourced.topology.golden.json` (`/2`). Their `generator.version` holds the
placeholder `<version>`; any string is valid there.

**keiro-ops.** `keiro-ops/` is the operator command library and CLI. `Keiro.Ops`
(`keiro-ops/src/Keiro/Ops.hs`) defines `data Command`, `commandParser :: AppHooks -> Parser
Command`, `isMutation`, `validateCommand`, `runCommand` and `runCommandWithReadEncoding`.
`AppHooks` and `emptyAppHooks` are in `keiro-ops/src/Keiro/Ops/Embed.hs`. Each field is a
`Maybe` that an application fills: `aggregates`, `processManagers`, `projectionCatalog` and
others. Hook-gated command groups are added to the parser only when their field is `Just`;
see `aggregateCommand` and `processManagerCommand` in `commandParser`.
`keiro-ops/src/Keiro/Ops/Aggregate.hs` is the model for a read-only group: its own `Command`
type, `commandParser`, `isMutation = const False`, `validateCommand` and `runCommand`
returning `OpsOutcome`. A result is `OpsResult headers rows jsonValue`
(`keiro-ops/src/Keiro/Ops/Render.hs`). The CLI renders the headers and rows as a table and
`--json` renders `jsonValue`.

`runCommandWithReadEncoding` lets a read return prepared response bytes together with its
outcome. The process-manager `types` read and the projection `consumers` read use it
(`ProcessManager.prepareTypes`). This is how `/topology/show` can return the mounted bytes
without re-encoding them.

**keiro-ops-http.** `keiro-ops-http/` turns the command tree into a WAI application.
`opsApplication` (`keiro-ops-http/src/Keiro/Ops/Http/Application.hs`) maps the path segments
and query of a request to command arguments (`translateRequest` in `Route.hs`), parses them
with `commandParser hooks`, requires `GET` for reads and `POST` with a confirmation for
mutations, verifies the database schema, and runs the command under the inspection budget
(`maxResponseBytes` defaults to 1 MiB in `Config.hs`). An unmounted hook's path fails to
parse and returns `400 invalid_request`. `Keiro.Ops.Http.Host` (`Host.hs`) provides
`mainWithHooks :: AppHooks -> IO ()` and `withHost`, which parse the host options
(`hostOptionsParser`) and start Warp. `jitsurei/ops-http/app/Main.hs` is a host: `main =
mainWithHooks (jitsureiOpsHooks Nothing)`. `docs/guides/serve-keiro-ops-over-http.md`
documents the surface; its section "See the hook-gated routes locally" shows `curl` against
`jitsurei-ops-http` on port 9092. `docs/user/operations.md` documents each inspection
domain (for example "Inspecting aggregates").

**keiro-ui.** keiro-ui (`mori://shinzui/keiro-ui`) is a browser console that talks to each
project's inspection routes directly. Its keiro client is
`packages/client-keiro/src/client.ts` in that repository. It treats command words whose
routes exist only when a hook is mounted as "hook-gated" (`HOOK_GATED_WORDS = ["aggregate",
"pm"]` in `packages/client-keiro/src/errors.ts`). A topology page needs a `topology` entry
there. That work is in keiro-ui, not here.

**Relevant ADRs.**
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
sanctions keiro's inspection surface as a bounded exception to the no-UI stance. It may
render the present value a supported read returns, never retained or aggregated
telemetry. Serving a static, committed structural document is inside that bound.
[ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
makes operator commands wrap supported library APIs.
[ADR-62](../adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)
defines the topology contract, its compatibility policy (consumers ignore unknown fields
and reject unknown schema ids, kinds and relations) and the minimum-schema-id rule.
[ADR-63](../adr/0063-topology-machines-are-derived-from-the-specification-and-proven-against-keiki-transducers.md)
and
[ADR-64](../adr/0064-declared-input-sources-are-checked-documentation-with-no-runtime-or-identity-effect.md)
describe the `machine` and `feeds` content.
[ADR-54](../adr/0054-aggregate-inspection-reuses-hydration-without-diagnostics-on-the-command-path.md)
and
[ADR-61](../adr/0061-generated-aggregate-inspector-catalogs-cover-every-dsl-aggregate.md)
are the precedent for hook-mounted inspection data. The keiro-ui decisions ADR-40 cites
also apply: every endpoint lives in the project that owns the concept
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`), surfaces ship as embeddable
applications (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`), and the console is
read-only first (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`).


## Plan of Work

### Milestone 1: mount and read the document in keiro-ops

Create `keiro-ops/src/Keiro/Ops/Topology.hs` and list it in `keiro-ops/keiro-ops.cabal`. It
defines an opaque `ServiceTopologyDocument` that holds the exact bytes and the decoded
`Data.Aeson.Value`. It also defines `decodeServiceTopology :: ByteString -> Either Text
ServiceTopologyDocument` and `loadServiceTopology :: FilePath -> IO (Either Text
ServiceTopologyDocument)`. The decoder requires: a JSON object; `schema` equal to
`keiro-dsl/service-topology/1` or `keiro-dsl/service-topology/2`, with any other value
refused with a message naming it; `service` a string; `generator.version` a string;
`members` an array of objects with string `path` and `sha256`; and `nodes` and `edges`
arrays of objects with string `kind` and `relation` respectively. Everything else is
ignored, so a document with added fields still mounts. The constructor is not exported, so
every mounted document has passed the decoder.

Add `serviceTopology :: !(Maybe ServiceTopologyDocument)` to `AppHooks` in
`keiro-ops/src/Keiro/Ops/Embed.hs`, set to `Nothing` in `emptyAppHooks`. This is an additive
field, so existing record updates of `emptyAppHooks` keep compiling. Export the new type and
functions from `Keiro.Ops`.

In `Keiro.Ops.Topology`, define the read-only group `data Command = Show | Summary`, its
`commandParser` (`topology show`, `topology summary`), `isMutation = const False`, and
`runCommand`. Add a `Topology` constructor to `Keiro.Ops.Command`, a hook-gated
`topologyCommand` in `commandParser` beside `aggregateCommand`, and the cases in
`isMutation`, `validateCommand` and `runCommand` (`Failed "service topology hook is not
mounted"` when absent).

`show` returns `jsonValue` equal to the decoded document. The table form has one row with
the schema id, service and counts, because a table cannot show the graph. `summary`
returns this snake_case object (field values computed from the document):

```json
{
  "schema_id": "keiro-dsl/service-topology/1",
  "service": "hospital-capacity",
  "generator_version": "0.25.1.0",
  "members": [{"path": "hospital-capacity.keiro", "sha256": "sha256:…"}],
  "node_counts": {"aggregate": 5, "read-model": 4},
  "edge_counts": {"dispatches": 3, "projects": 3}
}
```

Count keys are the document's own `kind` and `relation` strings, sorted. In
`runCommandWithReadEncoding`, add a case for `Topology Show` that returns the mounted
bytes as the prepared body, as the process-manager `types` case does. The HTTP body is then
byte-identical to the mounted file.

Tests in `keiro-ops/test/Main.hs` (or a new `TopologySpec.hs` listed in the test stanza):
decode every golden in `keiro-dsl/test/fixtures/topology/` (resolve the path from the
package or repository root, as other keiro-ops tests do for repository files); refuse `{}`,
`[]`, invalid JSON and a document whose `schema` is `keiro-dsl/service-topology/9`;
accept a document with an extra unknown top-level field; `summary` of
`hospital-capacity.topology.golden.json` gives the counts that a direct count of its `nodes`
and `edges` gives; `commandParser emptyAppHooks` rejects `["topology","show"]` and
`commandParser` with the hook accepts it; `isMutation` is false for both commands.

### Milestone 2: serve it over HTTP and mount it from the command line

`keiro-ops-http` needs no routing change, because `/topology/show` and
`/topology/summary` follow from the command tree. Add tests to `keiro-ops-http/test/Main.hs`
following the existing ones that build `opsApplication defaultOpsHttpConfig
Ops.emptyAppHooks {…} store`:

1. With the hook mounted from `hospital-capacity.topology.golden.json`, `GET
   /topology/show` returns 200, `Content-Type: application/json; charset=utf-8`, and a body
   byte-identical to the file.
2. `GET /topology/summary` returns the summary object above.
3. `POST /topology/show` returns 405 with `Allow: GET`.
4. Without the hook, `GET /topology/show` returns 400 `invalid_request`, the same response
   an unmounted `/aggregate/types` gets.
5. With `maxResponseBytes` set below the document size, `/topology/show` returns 413
   `inspection_result_too_large`.

Extend the host options in `keiro-ops-http/src/Keiro/Ops/Http/Host.hs` with an optional
`--topology FILE`. In `withHost`, when it is given, call `loadServiceTopology` before
starting the listener. On `Left message`, print `--topology FILE: <message>` to standard
error and exit non-zero without listening. On success, set `serviceTopology` in the hooks
the host was given. If the application already mounted a document in code, the flag
replaces it and the startup line says so. Add a test using `withHost` with port 0 that
mounts a golden from the flag and reads `/topology/summary`, and a test that a file whose
`schema` is unknown makes `withHost` fail before serving.

### Milestone 3: local demo, documentation and the keiro-ui handoff

`jitsurei-ops-http` gets `--topology` for free through `mainWithHooks`. Check it by hand
with a keiro-dsl golden (jitsurei has no DSL specification, so this is a demo of the route,
not of jitsurei's structure) and record the transcript in this plan.

In `docs/guides/serve-keiro-ops-over-http.md`, add a "Service topology" section. It says how
to mount the document (`--topology FILE`, or `AppHooks.serviceTopology` with
`loadServiceTopology` or embedded bytes), shows the two routes with `curl`, states that
`show` is the committed bytes under their own published contract and casing, that
`summary` is snake_case, that schema ids other than `/1` and `/2` are refused at mount, and
that freshness is enforced by `keiro-dsl topology --check` in the service's gate, not at
runtime. Add a short "Service topology" section to `docs/user/operations.md` beside
"Inspecting aggregates", covering the CLI form `keiro-ops topology summary --json`. Add the
library functions to `docs/user/api-reference.md`. Advance each page's `timestamp`, add a
`docs/user/log.md` entry with `okf log add` (and the equivalent for `docs/guides/`), and run
`nix develop -c just user-documentation-validate`.

Add a "Serving the document" subsection to `docs/user/keiro-dsl-service-topology.md` for
consumers. It gives the two routes and, for keiro-ui, the handoff: a client read for each
route in `packages/client-keiro/src/client.ts`, `topology` added to `HOOK_GATED_WORDS`,
validation of `show` against the JSON Schema its `schema` field names, and rejection of an
unknown schema id, node kind or relation (ADR-62). Mention that the edges
`consumes`/`writes`/`observes` trace aggregate events to read models, and that `machine`
gives each aggregate's keiki state machine.

Add entries under `## [Unreleased]` to `keiro-ops/CHANGELOG.md` (new hook, commands and
library functions) and `keiro-ops-http/CHANGELOG.md` (the routes and `--topology`). Update
ADR-62's Consequences with one bullet: keiro-ops serves the document opaquely and checks
only its schema id and envelope, so adding a schema id requires adding it to
`Keiro.Ops.Topology`. Advance its `timestamp` and add an `okf log add` entry to
`docs/adr/log.md`.


## Concrete Steps

From the repository root:

```bash
nix develop -c cabal build keiro-ops keiro-ops-http
nix develop -c cabal test keiro-ops:keiro-ops-test --test-show-details=direct
nix develop -c cabal test keiro-ops-http:keiro-ops-http-test --test-show-details=direct
```

Local demo for Milestone 3, in two terminals inside `nix develop`:

```bash
just jitsurei-all
cabal run -v0 jitsurei-ops-http -- --topology keiro-dsl/test/fixtures/topology/hospital-capacity.topology.golden.json
```

```bash
curl -fsS http://127.0.0.1:9092/topology/summary
curl -fsS http://127.0.0.1:9092/topology/show | cmp - keiro-dsl/test/fixtures/topology/hospital-capacity.topology.golden.json && echo identical
```

Expected:

```text
{"edge_counts":{…},"generator_version":"<version>","members":[{"path":"hospital-capacity.keiro","sha256":"sha256:…"}],"node_counts":{…},"schema_id":"keiro-dsl/service-topology/1","service":"hospital-capacity"}
identical
```

Commit at each milestone with a Conventional Commits message and these trailers:

```text
feat(keiro-ops): serve the committed service topology to inspection hosts

ExecPlan: docs/plans/342-serve-the-committed-service-topology-to-keiro-ui-through-keiro-ops-http.md
Intention: intention_01m7n03hbfem79q2brf07rneyq
```


## Validation and Acceptance

Accepted when all of the following hold.

A host mounted with a topology document answers `GET /topology/show` with 200 and a body
byte-identical to the mounted file, and `GET /topology/summary` with the summary object
whose counts equal a direct count of the document. Both run under the same admission,
deadline, schema-verification and byte limits as every other read: a too-small
`maxResponseBytes` gives 413 `inspection_result_too_large`, and `POST` gives 405.

A host without the hook does not expose the routes (400 `invalid_request`, as for
`/aggregate/*`), and `keiro-ops --help` lists no `topology` group.

`decodeServiceTopology` accepts every golden under `keiro-dsl/test/fixtures/topology/`,
including the `/2` document, and refuses an unknown schema id. A host given `--topology` with
such a file exits non-zero before listening.

Guarantees that must not weaken, and the check that measures each. Existing hosts are
unchanged: `emptyAppHooks` gains a `Nothing` field and no existing route changes, measured
by the unchanged existing `keiro-ops` and `keiro-ops-http` test suites. The inspection
budget still bounds the new reads, measured by the 413 test. Read-only stays read-only:
`isMutation` is false for both commands, measured by a unit test and the 405 test.
`keiro-ops` gains no dependency on `keiro-dsl`, measured by its Cabal stanza and
`just dsl-api-boundaries`.

Finally the documentation gates and the repository gate pass:

```bash
nix develop -c just user-documentation-validate
nix develop -c just adr-validate
nix develop -c just verify
```

`just verify` ends with `record-migration-policy`, which needs
`python3 scripts/generate-record-migration-manifests.py` after new records are added.


## Idempotence and Recovery

All changes are additive. The new `AppHooks` field defaults to `Nothing`, so reverting a
host's mount is removing one field or one flag. Tests read goldens from
`keiro-dsl/test/fixtures/topology/` and never write them. If a later keiro-dsl schema id is
added, `decodeServiceTopology` refuses documents under it until `Keiro.Ops.Topology` lists
it. That refusal is deliberate and is fixed by adding the id, not by relaxing the check.


## Interfaces and Dependencies

No new package dependency. `keiro-ops` already depends on `aeson`, `bytestring` and `text`.
It must not depend on `keiro-dsl`.

In `keiro-ops/src/Keiro/Ops/Topology.hs`:

```haskell
-- | A mounted keiro-dsl service-topology document: the exact bytes and their
-- decoded value. Construct only with 'decodeServiceTopology'.
data ServiceTopologyDocument

decodeServiceTopology :: ByteString -> Either Text ServiceTopologyDocument
loadServiceTopology :: FilePath -> IO (Either Text ServiceTopologyDocument)
serviceTopologySchemaId :: ServiceTopologyDocument -> Text
serviceTopologyBytes :: ServiceTopologyDocument -> ByteString
serviceTopologyValue :: ServiceTopologyDocument -> Value

data Command = Show | Summary
commandParser :: Parser Command
isMutation :: Command -> Bool
runCommand :: ServiceTopologyDocument -> Command -> OpsOutcome
```

In `keiro-ops/src/Keiro/Ops/Embed.hs`, `AppHooks` gains
`serviceTopology :: !(Maybe ServiceTopologyDocument)`. In
`keiro-ops-http/src/Keiro/Ops/Http/Host.hs`, the host options gain `--topology FILE`.

Consumers outside this repository: keiro-ui reads `/topology/show` and `/topology/summary`.
Its client and page are its own follow-up work in `mori://shinzui/keiro-ui`.
