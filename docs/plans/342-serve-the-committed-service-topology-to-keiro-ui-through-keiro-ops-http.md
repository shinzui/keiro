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
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-17T20:20:19Z
      mode: "update"
      note: "Reconciled Plan 343, aligned mount validation with ADR-62, specified constructor migration and byte limits, and corrected fixture, CLI and demo acceptance."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T20:46:50Z
      mode: "implement"
      note: "Implemented milestones 2-4: Keiro.Ops.Topology, hook-gated topology commands, --topology host mounting, docs and the keiro-ui handoff"
  reviews:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-17T20:08:37Z
      verdict: "changes-requested"
      note: "As submitted, the decoder accepts invalid vocabulary, the hook migration misses direct constructors, and the producer milestone and demo do not match the checkout."
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-17T20:20:55Z
      verdict: "approved"
      note: "Reviewed the revised milestones against the producer tests, schema gate, HTTP command path, direct constructors and Jitsurei recipe. The example summary matches the committed fixture."
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
The catalog names the `Capacity` aggregate inspector `capacity`. Plan 343 has shipped
that key as `details.category` alongside the declared node name. Milestone 4 writes the handoff, including a table of
which node kind joins to which inspection route and by which field.


## Progress

- [x] Milestone 1 (2026-11-17). Plan 343 delivered the inspector category in commit
      `4ee99457`. The scaffold comparison in `keiro-dsl/test/Keiro/Dsl/TopologySpec.hs`
      checks all five hospital aggregates, including `Surge` → `surge`. The focused
      producer suite passed all 44 examples and the schema gate verified five goldens
      and three compatibility examples during this review.
- [x] Milestone 2 (2026-11-17): `keiro-ops` decodes and mounts a topology document
      (`Keiro.Ops.Topology`, `AppHooks.serviceTopology`), and the CLI subcommands `topology show` and
      `topology summary` exist only when it is mounted. `keiro-ops/test/TopologySpec.hs`
      covers decoding, refusals, the summary, hook gating and CLI JSON through
      `runOpsInvocation`. With `KEIRO_TOPOLOGY_FIXTURES` set, all five goldens decode and
      the hospital summary matches direct counts, size and digest. The full
      `keiro-ops-test` suite passed 71 examples.
- [x] Milestone 3 (2026-11-17): `keiro-ops-http` serves `GET /topology/show` with the committed bytes and
      `GET /topology/summary`, refuses other methods, and reports oversize documents with
      `inspection_result_too_large`; `--topology FILE` mounts a file on any `mainWithHooks`
      host and refuses to start on a file that is undecodable or larger than the response
      limit. The tests live in `keiro-ops-http/test/Test/TopologySpec.hs`, registered from
      `keiro-ops-http/test/Main.hs`. `keiro-ops-http-test` passed 70 examples and
      `jitsurei-ops-http-test` passed 5.
- [x] Milestone 4 (2026-11-17): `jitsurei-ops-http --topology FILE` works locally against a keiro-dsl
      golden; the HTTP guide, the operations page, the CHANGELOGs and ADR-62 are updated;
      the keiro-ui handoff, with its verified join table, is written into
      `docs/user/keiro-dsl-service-topology.md`. The demo transcript is under Outcomes.
      `just user-documentation-validate` and `just adr-validate` passed.


## Surprises & Discoveries

The hospital fixture has two live lookup keys for the saga. Its aggregate inspector
is mounted under `surge`. Its process node carries `details.saga.category = "hospitalSurge"`.
Use the former for aggregate reads and resolve the latter through the process-manager catalog.

Two candidate joins in the plan's starting table did not hold. The pgmq operator surface
takes the logical queue name (`details.logical`, mapped by `queueRef` in
`keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`), not `details.physical`. All four `pgmq dlq`
commands are mutations, including `read`, which reserves entries, so a read-only
console has no queue route to link. An emit's `details.source` is declared, but the
scaffold generates no code from it (`NEmit _ -> []` in
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`). The application supplies the outbox source.
Both went to the handoff's "Not guaranteed" list with `intake`.

keiro-dsl generates the aggregate inspector catalog but not the process-manager catalog,
and the generated workflow and projection bindings must be used by the application. The
handoff therefore states the condition under which each kept row holds. Only the aggregate
row comes entirely from generated wiring.

Port 9092 was already held by an unrelated local process during the demo, so the
transcript below used `--port 9095`. The recipe itself is unchanged.


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

- Decision: `keiro-ops` reads the document's envelope and schema-specific vocabulary
  while retaining its original bytes. Its dependency boundary excludes `keiro-dsl`.
  Rationale: `keiro-ops` depends on `keiro`, not on the specification toolchain, and the
  document is a published JSON contract
  ([ADR-62](../adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)).
  Linking `keiro-dsl` into every inspection host would add a large dependency to serve a
  file. The decoder checks only what serving needs: the `schema` id is one keiro knows
  (`keiro-dsl/service-topology/1` or `/2`), and `service`, `generator`, `members`, `nodes`
  and `edges` supply the summary fields. Counts interpret node kinds and edge relations, so
  mounting also checks that vocabulary for the declared id under ADR-62. Kind-specific
  details stay opaque.
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
  startup (the library loader or the host's size-limited `--topology FILE` reader) or embedded by the application. Scaffold
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

- Decision: `withHost` reports a bad `--topology` file by throwing a new exported
  exception, `HostStartupError`, before resolving the database. `mainWithHooks` catches it, prints
  `<program>: --topology PATH: <cause>` to stderr and exits 1. The bounded reader is
  exported as `loadHostTopology`.
  Rationale: Tests and embedding hosts need a typed failure they can match without
  parsing `userError` text. Existing schema-verification failures keep their current
  behavior. Exporting the reader lets a composed host apply the same size rule.
  Date: 2026-11-17

- Decision: The keiro-ops changelog records the new hook field and `Command`
  constructor under Breaking Changes, and the changelog entries ship in the Milestone 2
  and 3 commits rather than waiting for Milestone 4.
  Rationale: Each commit should describe its own public change.
  Date: 2026-11-17

- Decision: The handoff tells keiro-ui which joins to live inspection routes are guaranteed,
  and lists only joins this plan has verified in code or by test.
  Rationale: The value of the page is the link from structure to state. Each join key is a
  different field (`details.category`, `details.saga.category`, `details.stableName`,
  `details.subscription`, `details.physical`), and a wrong one is a dead link. An unverified
  join is recorded as not guaranteed, not guessed.
  Date: 2026-11-17


## Outcomes & Retrospective

Completed 2026-11-17. A host can mount a committed topology document in code
(`AppHooks.serviceTopology` with `loadServiceTopology` or `decodeServiceTopology`) or with
`--topology FILE` on any `mainWithHooks` host. `GET /topology/show` returns the exact bytes
and `GET /topology/summary` the snake_case header. keiro-ops still does not depend on
`keiro-dsl`; its new library dependency is `cryptohash-sha256`.

Demo transcript (Milestone 4), against the hospital golden:

```bash
just jitsurei-ops-http --port 9095 --topology keiro-dsl/test/fixtures/topology/hospital-capacity.topology.golden.json
curl -fsS http://127.0.0.1:9095/topology/summary
set -o pipefail
curl -fsS http://127.0.0.1:9095/topology/show | cmp - keiro-dsl/test/fixtures/topology/hospital-capacity.topology.golden.json && echo identical
curl -sS -X POST -i http://127.0.0.1:9095/topology/show | head -1
```

```text
jitsurei-ops-http: listening on 127.0.0.1:9095 (mutations disabled)
{"document_bytes":18760,"document_sha256":"sha256:d34a4e1580e7af6e4a9dab8984419048b737230c88b47536925d75bb6ed914d0","edge_counts":{"consumes":1,"delivers":1,"dispatches":3,"enqueues":1,"groups":2,"member-of":4,"observes":2,"projects":3,"publishes":1,"reads":3,"runs":1,"saga":1,"signals":1,"subscribes":1,"writes":2},"generator_version":"<version>","members":[{"path":"hospital-capacity.keiro","sha256":"sha256:0c849100a91719ea9e034eb042187f3f4ab41f85689a90b85dedf651dfb3ae5e"}],"node_counts":{"aggregate":5,"contract":1,"dispatch":1,"emit":1,"intake":1,"operation":2,"process":1,"projection-owner":2,"projection-target":2,"publisher":1,"read-model":4,"rebuild-group":1,"router":1,"workflow":1,"workqueue":1},"schema_id":"keiro-dsl/service-topology/1","service":"hospital-capacity","source":{"kind":"source","path":"hospital-capacity.keiro"}}
identical
HTTP/1.1 405 Method Not Allowed
```

The served summary equals the value specified in Milestone 2.

Evidence for each guarantee:

- Gating: without the hook, both commands fail to parse (`keiro-ops/test/TopologySpec.hs`).
  Over HTTP, `/topology/*` returns `400 invalid_request`, as `/aggregate/types` does
  (`keiro-ops-http/test/Test/TopologySpec.hs`).
- Byte exactness: the HTTP test mounts a document with non-canonical whitespace, key
  order and a final newline, then compares the response body byte for byte. The demo
  `cmp` checks the committed golden.
- Limits: a body exactly at `maxResponseBytes` is served, one byte less gives `413`,
  `POST` gives `405` with `Allow: GET`, and an allowed `Origin` receives
  `Access-Control-Allow-Origin`.
- Startup refusal: `withHost` raises `HostStartupError` before its continuation for a
  missing file, invalid JSON, schema `/9` and a file one byte over the limit. The
  `keiro-ops-http` executable exits 1 with the path on stderr.
- Performance: existing reads take the same path. The new reads use the existing
  admission and encoding path, and the summary is computed once at mount.
  No benchmark measures this path. Nothing on a pre-existing route changed.

Retrospective: Routing through the existing command tree meant no HTTP route code was
needed. The `runCommandWithReadEncoding` seam provided byte identity directly. Most of
the effort went to verifying the join table. Two of six candidate rows fell to "Not
guaranteed" once their keys were traced to code.


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
parse and returns `400 invalid_request`. `mainWithHooks` in `keiro-ops-http/src/Keiro/Ops/Http/Host.hs` parses flags
with `hostOptionsParser` and hands the parsed `HostOptions` to `withHost`, which starts Warp. `jitsurei/ops-http/app/Main.hs` is a host: `main =
mainWithHooks (jitsureiOpsHooks Nothing)`. `docs/guides/serve-keiro-ops-over-http.md`
documents the surface; its section "See the hook-gated routes locally" shows `curl` against
`jitsurei-ops-http` on port 9092. `docs/user/operations.md` documents each inspection
domain (for example "Inspecting aggregates").

**keiro-ui.** keiro-ui (`mori://shinzui/keiro-ui`) is a browser console that talks to each
project's inspection routes directly. Its keiro client is
`packages/client-keiro/src/client.ts` in that repository. All keiro-ui TypeScript
paths below are relative to `mori://shinzui/keiro-ui` (source-file artifact URIs pending). The client treats command words whose
routes exist only when a hook is mounted as "hook-gated" (`HOOK_GATED_WORDS = ["aggregate",
"pm"]` in `packages/client-keiro/src/errors.ts`). A topology page needs a `topology` entry
there. That work is in keiro-ui, not here.

Four facts about keiro-ui shape what this plan must deliver. First, its client validates
every response with a zod schema (`packages/client-keiro/src/schemas.ts`, zod 4). It has no
JSON Schema validator, so the handoff describes the document for a zod schema and does not
ask the console to run the published JSON Schema. Second, the client keeps three reads in
flight (`KEIRO_MAX_CONCURRENT = 3` in `client.ts`) because the host admits four, so a
static document should be read once and cached. Third, keiro-ui's documented integration
(`mori://shinzui/keiro-ui/okf/user-documentation/concepts/DOC-5`) is an application that embeds
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
node in `keiro-dsl/src/Keiro/Dsl/Topology.hs` calls the same `aggregateStreamCategory`
function as the generated EventStream module.

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
are the precedent for hook-mounted inspection data.
[ADR-57](../adr/0057-compose-allocated-inspection-applications-without-changing-their-routes.md)
explains why the same routes appear under `/keiro/topology/` on a composed host. The keiro-ui decisions ADR-40 cites
also apply: every endpoint lives in the project that owns the concept
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`), surfaces ship as embeddable
applications (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`), and the console is
read-only first (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`).


## Plan of Work

### Milestone 1: export the aggregate category from keiro-dsl

Milestone 1 of
[Plan 343](343-close-the-review-findings-on-the-keiro-dsl-service-topology-export.md)
shipped the aggregate `category` and dispatch `dedupReadModel` together. The committed
goldens and both schema ids already cover these fields. Start implementation at Milestone 2.
The producer proof can be repeated with the topology test command under Concrete Steps.

### Milestone 2: mount and read the document in keiro-ops

Create `keiro-ops/src/Keiro/Ops/Topology.hs` and list it in `keiro-ops/keiro-ops.cabal`. It
defines an opaque `ServiceTopologyDocument` that holds the exact bytes and the decoded
`Data.Aeson.Value`. It also defines `decodeServiceTopology :: ByteString -> Either Text
ServiceTopologyDocument` and `loadServiceTopology :: FilePath -> IO (Either Text
ServiceTopologyDocument)`. The decoder requires: a JSON object; `schema` equal to
`keiro-dsl/service-topology/1` or `keiro-dsl/service-topology/2`, with any other value
refused with a message naming it; `service` a string; `generator.version` a string;
`members` an array of objects with string `path` and `sha256`; and `nodes` and `edges`
arrays. Validate each node's `kind`, each edge's `from.kind` and `to.kind`, and its
`relation` against `$defs.nodeKind.enum` and `$defs.relation.enum` in the JSON Schema
selected by the document. Both ids have the same 17 kinds. Schema `/1` has 22
relations and `/2` adds `feeds`. Keep the supported sets in the reader so deployment
needs only the document. Return a diagnostic naming the offending field and value.
Ignore additional object fields and preserve the original bytes, including their final
newline. Export the type abstractly. `loadServiceTopology` returns `Left` for file I/O
errors and decode errors so callers can report the failing path.

Add `serviceTopology :: !(Maybe ServiceTopologyDocument)` to `AppHooks` in
`keiro-ops/src/Keiro/Ops/Embed.hs`, set to `Nothing` in `emptyAppHooks`. This is an additive
field for callers that update `emptyAppHooks`. Direct construction of the exported strict
record requires a value. Set it to `Nothing` in `embeddedHooks` in `keiro-ops/test/Main.hs`
and `jitsureiOpsHooks` in `jitsurei/src/Jitsurei/Ops.hs`, preserving their other hooks.
Document that migration and the new top-level `Command` constructor in the `keiro-ops`
changelog. Export the document type, loader, decoder and accessors from `Keiro.Ops`.

In `Keiro.Ops.Topology`, define the read-only group `data Command = Show | Summary`, its
`commandParser` (`topology show`, `topology summary`), `isMutation = const False`, and
`runCommand`. Add a `Topology` constructor to `Keiro.Ops.Command`, a hook-gated
`topologyCommand` in `commandParser` beside `aggregateCommand`, and the cases in
`isMutation`, `validateCommand` and `runCommand` (`Failed "service topology hook is not
mounted"` when absent).

`show` returns `jsonValue` equal to the decoded document. The table form has one row with
the schema id, service and counts, because a table cannot show the graph. `summary`
returns a snake_case object. For the committed hospital golden its value is

```json
{
  "schema_id": "keiro-dsl/service-topology/1",
  "service": "hospital-capacity",
  "generator_version": "<version>",
  "source": {"kind": "source", "path": "hospital-capacity.keiro"},
  "members": [{"path": "hospital-capacity.keiro", "sha256": "sha256:0c849100a91719ea9e034eb042187f3f4ab41f85689a90b85dedf651dfb3ae5e"}],
  "node_counts": {"aggregate": 5, "contract": 1, "dispatch": 1, "emit": 1, "intake": 1, "operation": 2, "process": 1, "projection-owner": 2, "projection-target": 2, "publisher": 1, "read-model": 4, "rebuild-group": 1, "router": 1, "workflow": 1, "workqueue": 1},
  "edge_counts": {"consumes": 1, "delivers": 1, "dispatches": 3, "enqueues": 1, "groups": 2, "member-of": 4, "observes": 2, "projects": 3, "publishes": 1, "reads": 3, "runs": 1, "saga": 1, "signals": 1, "subscribes": 1, "writes": 2},
  "document_bytes": 18760,
  "document_sha256": "sha256:d34a4e1580e7af6e4a9dab8984419048b737230c88b47536925d75bb6ed914d0"
}
```

Compute the summary once when the document is decoded. Project each member to
`path` and `sha256`, preserving array order. Count each observed kind and relation.
Compare decoded summary objects in tests, since JSON object key order carries no
meaning. `document_bytes` is the length of the mounted bytes and `document_sha256` is the text `sha256:` followed by
the lowercase hex SHA-256 of those bytes, the same spelling the document uses for member
digests. For a `source` object with `kind` equal to `source` or `workspace` and a
string `path`, project those two fields into the summary. Otherwise omit `source`. In
`runCommandWithReadEncoding`, add a case for `Topology Show` that returns the mounted
strict bytes as `Just body` alongside the successful outcome. The existing
`renderOutcome` in `keiro-ops-http/src/Keiro/Ops/Http/Application.hs` checks their length
before writing them. The normal HTTP host guarantees byte identity. A hook-enabled CLI
running `--json topology show` re-encodes the decoded value. The test seam
`opsApplicationWithOperations` serializes the injected runner's own result. Use the
normal application for byte-identity tests and document the CLI's JSON behavior.

Tests in `keiro-ops/test/Main.hs` (or a new `TopologySpec.hs` listed in the test stanza):
exercise both ids with package-local input, including an older aggregate without
`category`. Refuse `{}`, `[]`, invalid JSON, malformed summary fields, schema `/9`,
an unknown node or endpoint kind, an unknown relation, and a `feeds` edge under `/1`.
Accept `feeds` under `/2` and additional object fields. Exercise the real producer goldens
in the repository run by passing the absolute fixture directory as
`KEIRO_TOPOLOGY_FIXTURES` (Concrete Steps). When supplied, require all five golden files,
including `workspace/service.topology.golden.json`, and fail if any are missing or fail
decoding. Keep the ordinary package tests runnable from their source distributions.

For the hospital golden, compare the digest against an independent SHA-256 of the file,
the size with its byte length, and both counts with direct counts of `nodes` and `edges`.
Check both commands through the parser with and without the hook. The mounted commands
are reads. The CLI's JSON output must decode to the complete document or summary,
respectively, when invoked through `opsCommandTree` and the normal command runner.

### Milestone 3: serve it over HTTP and mount it from the command line

`keiro-ops-http` needs no routing change, because `/topology/show` and
`/topology/summary` follow from the command tree. Add tests to `keiro-ops-http/test/Main.hs`
following the existing ones that build `opsApplication defaultOpsHttpConfig
Ops.emptyAppHooks {…} store`:

1. With the hook mounted from a package-local document with a trailing newline, `GET
   /topology/show` returns 200, `Content-Type: application/json; charset=utf-8`, and a body
   byte-identical to the file.
2. `GET /topology/summary` returns the corresponding summary, including the digest of
   the exact response bytes. Assert the cap accepts a body exactly at the limit.
3. `POST /topology/show` returns 405 with `Allow: GET`.
4. Without the hook, `GET /topology/show` returns 400 `invalid_request`, the same response
   an unmounted `/aggregate/types` gets.
5. With `maxResponseBytes` set below the document size, `/topology/show` returns 413
   `inspection_result_too_large`.
6. With an allowed origin configured, `GET /topology/show` carrying that `Origin` returns
   `Access-Control-Allow-Origin`, as every other read does. The console is usually served
   from another origin, so this is the request it actually makes.

Extend the host options in `keiro-ops-http/src/Keiro/Ops/Http/Host.hs` with an optional
`--topology FILE`. In `withHost`, resolve this option before opening the database
or listener. Check the size against `opts.http.inspectionLimits.maxResponseBytes` and
bound the actual read even if the file changes. Pass the bytes to `decodeServiceTopology`
only after the size check. Report the path and cause on failure, including the file size
and configured limit for an oversized file. Propagate the failure from `withHost` before
its continuation runs. The executable must print the diagnostic to stderr and exit
non-zero. On success, set only `serviceTopology` in the supplied hooks. If the flag
overrides a document mounted in code, report the override at startup.

Test `hostOptionsParser` with the flag present and absent. Using temporary files and
`withHost` on port zero, verify that a flag-supplied document wins over a different
in-code mount, its summary is served, and an existing hook still responds. With the flag
absent, the in-code mount remains available. Check failure before the continuation for
a missing file, invalid JSON, an unknown schema and a file one byte over the limit.

`HostOptions` is exported with its constructor and its fields are strict, so the new field
breaks every record construction of it. Update `options` in
`jitsurei/ops-http/test/Main.hs` (`HostOptions {databaseUrl = …, http = …, server = …}`)
and state in the `keiro-ops-http` CHANGELOG that code constructing `HostOptions` must set
the new field to `Nothing` or `Just path`.

### Milestone 4: local demo, documentation and the keiro-ui handoff

`jitsurei-ops-http` gets `--topology` for free through `mainWithHooks`. Check it by hand
with a keiro-dsl golden (jitsurei has no DSL specification, so this is a demo of the route,
not of jitsurei's structure) and record the transcript in this plan.

In `docs/guides/serve-keiro-ops-over-http.md`, add a "Service topology" section. Lead with the embedded form, because that is how an application
that composes `opsApplicationWithBudget` into its own server mounts it: read the file at
startup with `loadServiceTopology` and fail startup on `Left`, or compile the bytes in and
call `decodeServiceTopology`. Give a complete snippet for each, and say that with
`loadServiceTopology` the file must be shipped in the deployment image. Then give
`--topology FILE` for standalone hosts. The section shows the two routes with `curl`, states that
`show` is the committed bytes under their own published contract and casing, that
`summary` is snake_case, that schema ids other than `/1` and `/2` are refused at mount, and
that unknown kinds and relations also prevent mounting, and that freshness is enforced
by `keiro-dsl topology --check` in the service's gate, not at
runtime. Add a short "Service topology" section to `docs/user/operations.md` beside
"Inspecting aggregates". Show `<app-ops> --json topology summary` in a CLI built with
`Keiro.Ops.mainWithHooks` and a mounted document. The shipped `keiro-ops` binary uses
`emptyAppHooks`. The file flag belongs to the HTTP host. Add the
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
  digest within the selected host. A deployment can change between these two GETs.
  Hash the raw `show` response bytes before caching under the summary digest. On a
  mismatch, discard the pair and refresh the summary once. Report a changing deployment
  if the second pair disagrees.
- Validation: a zod schema in `schemas.ts` that is loose on object fields (keiro may add
  fields within a schema id) and strict on `schema`, node `kind` and edge `relation`, which
  ADR-62 requires a consumer to reject when unknown. List the kinds and relations of each
  schema id, so the enums can be copied.
- Errors: a 413 `inspection_result_too_large` on `show` means the mounted bytes exceed
  the host's response limit. A 413 on `summary` applies to the encoded summary itself,
  which also includes every member. The host operator can adjust its configuration. 409 `schema_drift`
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
| `aggregate` | `/aggregate/list?name=`, `/aggregate/show?name=&id=` | match `details.category` to a mounted `name` in `/aggregate/types`; obtain the instance `id` for `show` from a list row |
| `process` | `/pm/list?name=` | match `details.saga.category` to `category` in `/pm/types` items and use the entry's `name` only on an unambiguous match |
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

Name the integration guide (`mori://shinzui/keiro-ui/okf/user-documentation/concepts/DOC-5`)
and the relevant keiro-ui capability pages in the handoff as the consumer's documentation
follow-up.

Add entries under `## [Unreleased]` to `keiro-ops/CHANGELOG.md` (new hook, commands and
library functions) and `keiro-ops-http/CHANGELOG.md` (the routes, `--topology` and the new
`HostOptions` field). Update
ADR-62's Consequences with one bullet: keiro-ops serves the document opaquely and checks
its envelope and each schema id's node kinds and edge relations, so a new id or
vocabulary requires a corresponding change in `Keiro.Ops.Topology`. Advance its `timestamp` and add an `okf log add` entry to
`docs/adr/log.md`.


## Concrete Steps

From the repository root:

```bash
nix develop -c z3 --version
nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-options='--match topology' --test-show-details=direct
nix develop -c just topology-schema-validate
nix develop -c cabal build keiro-ops keiro-ops-http
nix develop -c env KEIRO_TOPOLOGY_FIXTURES="$PWD/keiro-dsl/test/fixtures/topology" cabal test keiro-ops:keiro-ops-test --test-show-details=direct
nix develop -c cabal test keiro-ops-http:keiro-ops-http-test jitsurei-ops-http:jitsurei-ops-http-test --test-show-details=direct
```

Local demo for Milestone 4, in two terminals inside `nix develop`:

```bash
just jitsurei-ops-http --topology keiro-dsl/test/fixtures/topology/hospital-capacity.topology.golden.json
```

```bash
curl -fsS http://127.0.0.1:9092/topology/summary
set -o pipefail
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
generated aggregate inspectors. Plan 343 shipped the companion `dedupReadModel` field in the same golden update.
Use the checked-in goldens as inputs for the serving work.

A host mounted with a topology document answers `GET /topology/show` with 200 and a body
byte-identical to the mounted file, and `GET /topology/summary` with the summary object
whose counts equal a direct count of the document and whose `document_sha256` equals the
SHA-256 of the mounted file. Both run under the same admission,
deadline, schema-verification and byte limits as every other read: a too-small
`maxResponseBytes` gives 413 `inspection_result_too_large`, and `POST` gives 405.

A host without the hook does not expose the routes (400 `invalid_request`, as for
`/aggregate/*`), and `keiro-ops --help` lists no `topology` group.

`decodeServiceTopology` accepts every golden under `keiro-dsl/test/fixtures/topology/`,
including the `/2` document. It refuses unknown ids, kinds and relations, including
`feeds` under `/1`. A host given `--topology` with such a file, or with a file larger than its
response limit, exits non-zero before listening.

The handoff in `docs/user/keiro-dsl-service-topology.md` has a join table in which every
row names the code that makes the join hold, and a "Not guaranteed" list for the rest.

The existing `keiro-ops`, `keiro-ops-http` and Jitsurei host tests must pass with
the new optional fields defaulted to `Nothing` at direct construction sites. The 413
and 405 tests demonstrate the response cap and read-only classification. Check the
library's `build-depends` in `keiro-ops/keiro-ops.cabal` to verify the DSL stays outside
its dependencies. Both published schema ids accept earlier documents with no aggregate
`category`, as checked by
`scripts/check-topology-schemas.sh`, which validates the goldens and the examples under
`keiro-dsl/test/fixtures/topology/schema-examples/`, still passing with
`aggregate-without-machine.valid.json` unedited.

Finally the documentation gates and the repository gate pass:

```bash
nix develop -c just user-documentation-validate
nix develop -c just adr-validate
nix develop -c just verify
```

`just verify` includes `record-migration-policy`. If the record changes make its checked
inventories stale, regenerate them inside the Nix shell with
`python3 scripts/generate-record-migration-manifests.py` and rerun the gate.


## Idempotence and Recovery

Direct constructors must set `AppHooks.serviceTopology` or `HostOptions.topology`
to `Nothing` to keep the previous behavior. A host can remove the flag or clear the
hook to unmount the routes. If a file fails startup validation, correct or regenerate
the file and restart. The HTTP CLI uses the default 1 MiB response limit. A host that
needs a larger budget can supply `HostOptions.http.inspectionLimits` in code. The DSL
already shipped its new fields in Plan 343. Tests here only read the producer goldens.
A future schema id requires an explicit decoder and vocabulary update.


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

The producer interface already supplies `details.category` on aggregate nodes in
`keiro-dsl/src/Keiro/Dsl/Topology.hs`. Earlier documents may omit it.

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

Revision note (2026-11-17, third). Reconciled the completed producer milestone with
Plan 343, aligned mount validation with ADR-62, and corrected the hook migration,
package-test fixtures, digest handoff and demo database selection.
