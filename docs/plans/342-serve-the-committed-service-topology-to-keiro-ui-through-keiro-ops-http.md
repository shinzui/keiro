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
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-17T17:49:16Z
      mode: "update"
      note: "Reviewed for keiro-ui DX: aggregate category join key, summary digest and size, startup size check, zod-oriented handoff with verified join table"
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
member digests, node and edge counts, and the document's own size and SHA-256 digest, which
the console uses as a cache key and to notice a redeployed document. Like `/aggregate/*` and `/pm/*`, the routes exist
only when the host mounts the hook. A host mounts it in code
(`AppHooks.serviceTopology`) or from the command line (`--topology FILE` on any
`Keiro.Ops.Http.mainWithHooks` host, including `jitsurei-ops-http`).

The keiro-ui page that renders the topology is not part of this plan. It belongs to
`mori://shinzui/keiro-ui`. What this plan owes keiro-ui is a document the console can use
without guessing. A structure page is only useful if a node links to the live data keiro-ui
already shows, so an aggregate node must name the same key `/aggregate/list?name=…` takes.
Today it does not: the inspector catalog names each aggregate by its stream category
(`capacity`), and the topology node carries only the declared name (`Capacity`). Milestone 1
adds the category to the document. Milestone 4 writes the handoff, including a table of
which node kind joins to which inspection route and by which field.


## Progress

- [ ] Milestone 1: `keiro-dsl topology` exports each aggregate's stream `category`, equal
      to the name its generated inspector is mounted under. Delivered by Milestone 1 of
      `docs/plans/343-close-the-review-findings-on-the-keiro-dsl-service-topology-export.md`.
- [ ] Milestone 2: `keiro-ops` decodes and mounts a topology document
      (`Keiro.Ops.Topology`, `AppHooks.serviceTopology`), and `keiro-ops topology show` and
      `topology summary` exist only when it is mounted. Unit tests cover decoding, refusal of
      unknown schema ids, the summary shape and the hook gating.
- [ ] Milestone 3: `keiro-ops-http` serves `GET /topology/show` with the committed bytes and
      `GET /topology/summary`, refuses other methods, and reports oversize documents with
      `inspection_result_too_large`; `--topology FILE` mounts a file on any `mainWithHooks`
      host and refuses to start on a file that is undecodable or larger than the response
      limit. Tests in `keiro-ops-http/test/Main.hs` pass.
- [ ] Milestone 4: `jitsurei-ops-http --topology FILE` works locally against a keiro-dsl
      golden; the HTTP guide, the operations page, the CHANGELOGs and ADR-62 are updated;
      the keiro-ui handoff, with its verified join table, is written into
      `docs/user/keiro-dsl-service-topology.md`.


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


- Decision: The topology document gains an optional `category` on aggregate nodes, under
  the existing schema ids. keiro-ui does not re-derive it.
  Rationale: The generated inspector catalog names each aggregate by its category text
  ([ADR-61](../adr/0061-generated-aggregate-inspector-catalogs-cover-every-dsl-aggregate.md)),
  so `/aggregate/types` reports `capacity` where the topology node is named `Capacity`. The
  derivation (`staticCategory … (lowerFirst name)` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`)
  is a code-generation detail. A console that copies it breaks silently when it changes.
  ADR-62's compatibility policy allows added object fields within a schema id, so this needs
  no `/3`. The field is optional in the JSON Schemas because documents emitted before it
  stay valid; a console shows no live link for a node without it.
  Date: 2026-11-17

- Decision: The summary carries `document_sha256` and `document_bytes`.
  Rationale: The document is static for the life of a host process, but every HTTP read
  takes one of four admission slots and a schema verification, and keiro-ui keeps only
  three reads in flight. With the digest the console fetches `show` once per digest and
  detects a redeployed document from the cheap summary. The size lets it explain a 413
  instead of offering to narrow a read that has no parameters. `cryptohash-sha256` is
  already a dependency of `keiro`, so `keiro-ops` adds it directly without a new
  transitive package.
  Date: 2026-11-17

- Decision: A standalone host refuses to start when the `--topology` file is larger than
  `maxResponseBytes`.
  Rationale: `/topology/show` has no way to return part of the document. Mounting a
  document that can never be served would give the console a page that always fails with
  413. Failing at startup puts the error in front of the person who can raise the limit.
  Date: 2026-11-17

- Decision: The handoff tells keiro-ui which joins to live inspection routes are guaranteed,
  and lists only joins this plan has verified in code or by test.
  Rationale: The value of the page is the link from structure to state. Each join key is a
  different field (`details.category`, `details.saga.category`, `details.stableName`,
  `details.subscription`, `details.physical`), and a wrong one is a dead link. An unverified
  join is recorded as not guaranteed, not guessed.
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

Four facts about keiro-ui shape what this plan must deliver. First, its client validates
every response with a zod schema (`packages/client-keiro/src/schemas.ts`, zod 4). It has no
JSON Schema validator, so the handoff describes the document for a zod schema and does not
ask the console to run the published JSON Schema. Second, the client keeps three reads in
flight (`KEIRO_MAX_CONCURRENT = 3` in `client.ts`) because the host admits four, so a
static document should be read once and cached. Third, keiro-ui's documented integration
(`docs/user/application-integration.md` there) is an application that embeds
`opsApplicationWithBudget` and `feedsMiddleware` under `/keiro` in a composed host. For it
the mount is `AppHooks.serviceTopology` in code, and `--topology` matters only for
standalone hosts. Fourth, keiro-ui's local stack and recorded fixtures use `jitsurei`,
which is hand-written and has no keiro-dsl specification. keiro-ui can therefore develop
the page against a keiro-dsl golden, but it cannot see topology nodes joined to live
jitsurei data. This plan does not change that; see Milestone 4.

**How topology names relate to inspection names.** The live inspection routes do not all
key on a node's `name`. `/aggregate/types` and `/aggregate/list?name=` use the name the
generated catalog mounts each inspector under, which is the aggregate's category text
(`inspectorLine` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, ADR-61). For a plain aggregate
the category is the declared name with its first letter lowered (`Capacity` → `capacity`).
`/pm/types` reports a host-chosen lookup `name` and the saga `category`
(`listProcessManagerTypes` in `keiro/src/Keiro/ProcessManager/Inspect.hs`); the topology
`process` node already exports `details.saga.category`. A `projection-owner` node exports
`details.subscription`, and a `workqueue` node exports `details.physical`. The aggregate
node (`nodeSummary` in `keiro-dsl/src/Keiro/Dsl/Topology.hs`) exports `states`,
`commands`, `events` and `machine`, and no category.

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

### Milestone 1: export the aggregate category from keiro-dsl

This milestone is delivered by Milestone 1 of
`docs/plans/343-close-the-review-findings-on-the-keiro-dsl-service-topology-export.md`,
which adds `category` to aggregate nodes together with another added field, so that
services regenerate their committed topology once. Do not implement it here. Mark it
complete when that milestone is accepted, and record the saga-aggregate category it
found, because the join table in Milestone 4 depends on it.

### Milestone 2: mount and read the document in keiro-ops

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
  "source": {"kind": "source", "path": "hospital-capacity.keiro"},
  "members": [{"path": "hospital-capacity.keiro", "sha256": "sha256:…"}],
  "node_counts": {"aggregate": 5, "read-model": 4},
  "edge_counts": {"dispatches": 3, "projects": 3},
  "document_bytes": 19412,
  "document_sha256": "sha256:…"
}
```

Count keys are the document's own `kind` and `relation` strings, sorted. `document_bytes`
is the length of the mounted bytes and `document_sha256` is the text `sha256:` followed by
the lowercase hex SHA-256 of those bytes, the same spelling the document uses for member
digests. Compute both once in `decodeServiceTopology` and keep them in
`ServiceTopologyDocument`, not on every request. `source` is copied from the document when
it has the documented shape and omitted otherwise; the decoder does not require it. In
`runCommandWithReadEncoding`, add a case for `Topology Show` that returns the mounted
bytes as the prepared body, as the process-manager `types` case does. The HTTP body is then
byte-identical to the mounted file. Two paths re-encode the decoded value instead and are
not byte-identical: `keiro-ops topology show --json`, and an application built with the
test seam `opsApplicationWithOperations`. Say so in the Haddock of `serviceTopologyBytes`.

Tests in `keiro-ops/test/Main.hs` (or a new `TopologySpec.hs` listed in the test stanza):
decode every golden in `keiro-dsl/test/fixtures/topology/` (resolve the path from the
package or repository root, as other keiro-ops tests do for repository files); refuse `{}`,
`[]`, invalid JSON and a document whose `schema` is `keiro-dsl/service-topology/9`;
accept a document with an extra unknown top-level field; `document_sha256` of a golden
equals `sha256sum` of the file and `document_bytes` equals its length; `summary` of
`hospital-capacity.topology.golden.json` gives the counts that a direct count of its `nodes`
and `edges` gives; `commandParser emptyAppHooks` rejects `["topology","show"]` and
`commandParser` with the hook accepts it; `isMutation` is false for both commands.

### Milestone 3: serve it over HTTP and mount it from the command line

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
6. With an allowed origin configured, `GET /topology/show` carrying that `Origin` returns
   `Access-Control-Allow-Origin`, as every other read does. The console is usually served
   from another origin, so this is the request it actually makes.

Extend the host options in `keiro-ops-http/src/Keiro/Ops/Http/Host.hs` with an optional
`--topology FILE`. In `withHost`, when it is given, call `loadServiceTopology` before
starting the listener. On `Left message`, print `--topology FILE: <message>` to standard
error and exit non-zero without listening. Do the same when the document is larger than
`config.inspectionLimits.maxResponseBytes`, with a message that gives both numbers, because
`/topology/show` could then only ever answer 413. On success, set `serviceTopology` in the
hooks the host was given. If the application already mounted a document in code, the flag
replaces it and the startup line says so. Add a test using `withHost` with port 0 that
mounts a golden from the flag and reads `/topology/summary`, a test that a file whose
`schema` is unknown makes `withHost` fail before serving, and a test that a file larger
than the response limit does the same.

`HostOptions` is exported with its constructor and its fields are strict, so the new field
breaks every record construction of it. Update `options` in
`jitsurei/ops-http/test/Main.hs` (`HostOptions {databaseUrl = …, http = …, server = …}`)
and state in the `keiro-ops-http` CHANGELOG that code constructing `HostOptions` must set
the new field.

### Milestone 4: local demo, documentation and the keiro-ui handoff

`jitsurei-ops-http` gets `--topology` for free through `mainWithHooks`. Check it by hand
with a keiro-dsl golden (jitsurei has no DSL specification, so this is a demo of the route,
not of jitsurei's structure) and record the transcript in this plan.

In `docs/guides/serve-keiro-ops-over-http.md`, add a "Service topology" section. It says how
to mount the document. Lead with the embedded form, because that is how an application
that composes `opsApplicationWithBudget` into its own server mounts it: read the file at
startup with `loadServiceTopology` and fail startup on `Left`, or compile the bytes in and
call `decodeServiceTopology`. Give a complete snippet for each, and say that with
`loadServiceTopology` the file must be shipped in the deployment image. Then give
`--topology FILE` for standalone hosts. The section shows the two routes with `curl`, states that
`show` is the committed bytes under their own published contract and casing, that
`summary` is snake_case, that schema ids other than `/1` and `/2` are refused at mount, and
that freshness is enforced by `keiro-dsl topology --check` in the service's gate, not at
runtime. Add a short "Service topology" section to `docs/user/operations.md` beside
"Inspecting aggregates", covering the CLI form `keiro-ops topology summary --json`. Add the
library functions to `docs/user/api-reference.md`. Advance each page's `timestamp`, add a
`docs/user/log.md` entry with `okf log add` (and the equivalent for `docs/guides/`), and run
`nix develop -c just user-documentation-validate`.

Add a "Serving the document" subsection to `docs/user/keiro-dsl-service-topology.md` for
consumers. It gives the two routes and the handoff for keiro-ui, written so that keiro-ui's
own plan can be drafted from it alone:

- Client: a read for each route in `packages/client-keiro/src/client.ts`, a key for each in
  `query-keys.ts`, and `topology` added to `HOOK_GATED_WORDS` in `errors.ts`, so an
  unmounted host gives `RouteUnavailable` and the page can say the host mounts no topology.
- Read order and caching: read `/topology/summary` first. It is the mount probe, it carries
  `schema_id` so the console can say "this console does not understand schema X" before
  fetching anything large, and it carries `document_sha256`. Key the `show` query on that
  digest and give it a long stale time; the document cannot change while the host process
  runs.
- Validation: a zod schema in `schemas.ts` that is loose on object fields (keiro may add
  fields within a schema id) and strict on `schema`, node `kind` and edge `relation`, which
  ADR-62 requires a consumer to reject when unknown. List the kinds and relations of each
  schema id, so the enums can be copied.
- Errors: 413 `inspection_result_too_large` means the host's response limit is below
  `document_bytes`; it is fixed by the host, not by narrowing the read. 409 `schema_drift`
  and 503 `inspection_busy` mean what they mean for every keiro read.
- Fixtures: the goldens under `keiro-dsl/test/fixtures/topology/` in `mori://shinzui/keiro`
  (artifact-level URI pending), including the `/2` document, and a recorded
  `/topology/summary` response from this milestone's transcript.
- The join table below.

The join table has one row per node kind that has live state: the inspection route, the
query parameter, and the topology field that supplies its value. Start from these
candidates and keep only rows you have verified against the code or a running host. For
each kept row, name the code location that makes the two values equal.

| Node kind | Live route | Join |
| --- | --- | --- |
| `aggregate` | `/aggregate/list?name=`, `/aggregate/show?name=&id=` | `details.category` (Milestone 1) equals `name` in `/aggregate/types` |
| `process` | `/pm/list?name=` | `details.saga.category` equals `category` in `/pm/types`; the route takes that entry's `name` |
| `workflow` | `/wf/inspect/list?workflow_name=` | `details.stableName` (verify) |
| `projection-owner` | `/projection/position?subscription=` | `details.subscription`, when not `null` (verify) |
| `workqueue` | the pgmq surface's queue | `details.physical` (verify) |
| `intake`, `emit` | `/inbox/list?source=`, `/outbox/list?source=` | verify whether any exported field is the `source` |

A row that cannot be verified is moved to a short "Not guaranteed" list with the reason.
Do not leave a guessed join in the table. State also that a node has no link when its join
field is absent (a document emitted before the field existed) or when the matching route's
hook is not mounted.

The subsection says plainly that the document describes the committed specification, not
the running binary. The console can detect disagreement by comparing aggregate `category`
values with `/aggregate/types`; it should show a mismatch, not hide it. It also says that
keiro's demo host `jitsurei` has no specification, so `jitsurei-ops-http --topology` serves
a document about another service and none of its nodes join to jitsurei's live data.
Finally it mentions that the edges `consumes`/`writes`/`observes` trace aggregate events to
read models, that `machine` gives each aggregate's keiki state machine, and that `member`
and `line` locate each node in the specification source.

keiro-ui's `docs/user/application-integration.md` and its capability pages are keiro-ui's
to update; name them in the handoff as the pages that need the new hook.

Add entries under `## [Unreleased]` to `keiro-ops/CHANGELOG.md` (new hook, commands and
library functions) and `keiro-ops-http/CHANGELOG.md` (the routes, `--topology` and the new
`HostOptions` field). Update
ADR-62's Consequences with one bullet: keiro-ops serves the document opaquely and checks
only its schema id and envelope, so adding a schema id requires adding it to
`Keiro.Ops.Topology`. Advance its `timestamp` and add an `okf log add` entry to
`docs/adr/log.md`.


## Concrete Steps

From the repository root:

```bash
nix develop -c z3 --version
nix develop -c cabal test keiro-dsl:tests --test-show-details=direct
nix develop -c cabal build keiro-ops keiro-ops-http
nix develop -c cabal test keiro-ops:keiro-ops-test --test-show-details=direct
nix develop -c cabal test keiro-ops-http:keiro-ops-http-test --test-show-details=direct
```

Local demo for Milestone 4, in two terminals inside `nix develop`:

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
{"document_bytes":…,"document_sha256":"sha256:…","edge_counts":{…},"generator_version":"<version>","members":[{"path":"hospital-capacity.keiro","sha256":"sha256:…"}],"node_counts":{…},"schema_id":"keiro-dsl/service-topology/1","service":"hospital-capacity","source":{"kind":"source","path":"hospital-capacity.keiro"}}
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

Every aggregate node of a document emitted by `keiro-dsl topology` has a
`details.category`, and for a scaffolded fixture those categories equal the names of the
generated aggregate inspectors. The topology goldens differ from their previous versions
only by those added fields.

A host mounted with a topology document answers `GET /topology/show` with 200 and a body
byte-identical to the mounted file, and `GET /topology/summary` with the summary object
whose counts equal a direct count of the document and whose `document_sha256` equals the
SHA-256 of the mounted file. Both run under the same admission,
deadline, schema-verification and byte limits as every other read: a too-small
`maxResponseBytes` gives 413 `inspection_result_too_large`, and `POST` gives 405.

A host without the hook does not expose the routes (400 `invalid_request`, as for
`/aggregate/*`), and `keiro-ops --help` lists no `topology` group.

`decodeServiceTopology` accepts every golden under `keiro-dsl/test/fixtures/topology/`,
including the `/2` document, and refuses an unknown schema id. A host given `--topology` with
such a file, or with a file larger than its response limit, exits non-zero before
listening.

The handoff in `docs/user/keiro-dsl-service-topology.md` has a join table in which every
row names the code that makes the join hold, and a "Not guaranteed" list for the rest.

Guarantees that must not weaken, and the check that measures each. Existing hosts are
unchanged: `emptyAppHooks` gains a `Nothing` field and no existing route changes, measured
by the unchanged existing `keiro-ops` and `keiro-ops-http` test suites. The inspection
budget still bounds the new reads, measured by the 413 test. Read-only stays read-only:
`isMutation` is false for both commands, measured by a unit test and the 405 test.
`keiro-ops` gains no dependency on `keiro-dsl`, measured by its Cabal stanza and
`just dsl-api-boundaries`. The topology contract stays backward compatible: the schema ids
are unchanged and `category` is optional in both JSON Schemas, measured by
`scripts/check-topology-schemas.sh`, which validates the goldens and the examples under
`keiro-dsl/test/fixtures/topology/schema-examples/`, still passing with
`aggregate-without-machine.valid.json` unedited.

Finally the documentation gates and the repository gate pass:

```bash
nix develop -c just user-documentation-validate
nix develop -c just adr-validate
nix develop -c just verify
```

`just verify` ends with `record-migration-policy`, which needs
`python3 scripts/generate-record-migration-manifests.py` after new records are added.


## Idempotence and Recovery

All changes are additive, with two exceptions that are compile-time or gate-time and
have a one-line fix: code that constructs `HostOptions` must set the new field, and a
service's committed topology must be regenerated after upgrading keiro-dsl, or
`topology --check` reports it stale. The new `AppHooks` field defaults to `Nothing`, so reverting a
host's mount is removing one field or one flag. Tests read goldens from
`keiro-dsl/test/fixtures/topology/` and never write them. If a later keiro-dsl schema id is
added, `decodeServiceTopology` refuses documents under it until `Keiro.Ops.Topology` lists
it. That refusal is deliberate and is fixed by adding the id, not by relaxing the check.


## Interfaces and Dependencies

`keiro-ops` gains a direct dependency on `cryptohash-sha256`, with the bounds `keiro`
already uses (`>=0.11.102 && <0.12` in `keiro/keiro.cabal`), for `document_sha256`. It is
already in the build plan through `keiro`. `keiro-ops` already depends on `aeson`,
`bytestring` and `text`. It must not depend on `keiro-dsl`.

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
-- | @sha256:@ and the lowercase hex digest of the mounted bytes.
serviceTopologyDigest :: ServiceTopologyDocument -> Text

data Command = Show | Summary
commandParser :: Parser Command
isMutation :: Command -> Bool
runCommand :: ServiceTopologyDocument -> Command -> OpsOutcome
```

In `keiro-ops/src/Keiro/Ops/Embed.hs`, `AppHooks` gains
`serviceTopology :: !(Maybe ServiceTopologyDocument)`. In
`keiro-ops-http/src/Keiro/Ops/Http/Host.hs`, `HostOptions` gains
`topology :: !(Maybe FilePath)` and the host options gain `--topology FILE`.

In `keiro-dsl/src/Keiro/Dsl/Topology.hs`, an `aggregate` node's `details` gain
`category`, a string.

Consumers outside this repository: keiro-ui reads `/topology/show` and `/topology/summary`.
Its client and page are its own follow-up work in `mori://shinzui/keiro-ui`.

Revision note (2026-11-17): reviewed against the keiro-ui checkout for console developer
experience. Added Milestone 1 (aggregate `category` in the document) because aggregate
nodes could not be joined to `/aggregate/*`; added `document_sha256`, `document_bytes` and
`source` to the summary for caching and error explanation; made an oversize `--topology`
file a startup failure; recorded the `HostOptions` construction break; and replaced the
handoff's JSON Schema validation with a zod-oriented description, a read order, fixtures
and a verified join table.

Revision note (2026-11-17, second): Milestone 1 now defers to plan 343, which exports the
aggregate category together with the dispatch dedupe read model.
