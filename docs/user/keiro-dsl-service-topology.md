---
type: Reference
title: Keiro DSL Service Topology
description: Read and keep fresh the versioned keiro-dsl service topology document, its node kinds, relations, encoding and compatibility policy.
docId: DOC-35
tags: [keiro, dsl, topology, reference]
generated:
  by: anthropic-claude-code/claude-opus-5-5
  at: 2026-11-17T00:00:00Z
timestamp: 2026-11-17T21:10:00Z
---

# Keiro DSL Service Topology

`keiro-dsl topology` prints one JSON document that describes how the parts of a
service connect. It lists the service's declarations and every relation between
them, plus a sha256 digest of each source file. Tools that need the service's
shape read a committed copy of this document instead of parsing `.keiro` files.
The document is a public contract owned by keiro. Its schema id is
`keiro-dsl/service-topology/1`, or `keiro-dsl/service-topology/2` for a service
that declares an input source (see Schema id /2). The JSON Schemas are
[`schemas/keiro-dsl-service-topology-1.schema.json`](schemas/keiro-dsl-service-topology-1.schema.json)
and
[`schemas/keiro-dsl-service-topology-2.schema.json`](schemas/keiro-dsl-service-topology-2.schema.json).

The command is described in the [Keiro DSL Command Reference](keiro-dsl-cli.md).
This page defines the document.

## Producing and checking the document

```bash
keiro-dsl topology service.keiro --format json > topology.json
keiro-dsl topology service.keiro-workspace --check topology.json
keiro-dsl scaffold service.keiro --out src --topology-out topology.json
```

The export is computed from the checked specification alone. It does not
compile or run the service. A service with any error diagnostic is refused: the
command prints the diagnostics on standard error, prints nothing on standard
output and exits non-zero.

A service that already runs `scaffold` on every specification change adds
`--topology-out FILE` to that run and commits the file. Its generated-code gate
then also runs the check:

```bash
keiro-dsl scaffold service.keiro --out src --topology-out topology.json
keiro-dsl topology service.keiro --check topology.json
```

`--check FILE` regenerates the document and compares it byte for byte with
`FILE`. It prints nothing and exits zero when they are equal. Otherwise it exits
1 and names the cause on standard error: each member whose digest changed, each
member that is new or no longer a member, or, when every digest still matches,
the first other difference. That is a `keiro-dsl` upgrade (the generator version
is part of the document), then a changed service name or manifest file name,
which are not members and carry no digest. Otherwise it says the document
differs with unchanged sources and the same `keiro-dsl` version, for example
after a change to the manifest's member order or a different build of one
version. For a workspace, each member's digest is of the exact bytes the loader
parsed.

## Top-level fields

| Field | Meaning |
| --- | --- |
| `schema` | The schema id: `keiro-dsl/service-topology/1`, or `/2` when the document has a `feeds` edge. |
| `service` | The workspace manifest's `service` name, or the source file's base name. |
| `source` | `kind` (`source` or `workspace`) and `path`, the file name of the source or manifest. |
| `effectiveSemanticContract` | `languageVersion`, `languageSupport` and `runtimeSemantics`, as `keiro-dsl inspect` reports them. |
| `generator` | `tool` (`keiro-dsl`) and `version`, the `keiro-dsl` package version. |
| `members` | Source files, sorted by `path`. |
| `nodes` | One object per declaration, sorted by `kind` then `name`. |
| `edges` | One object per relation, sorted as described under Encoding. |

Paths never depend on where the command ran. `source.path` is a file name, and
each member `path` is relative to the manifest directory with forward slashes
(for a single source, its file name).

A member has `path`, `sha256` (the text `sha256:` and the lowercase hex digest of
the file's exact bytes), `declaredLanguageVersion` (a number, or `null` when the
file has no `language` line) and `effectiveLanguageVersion`.

A node has `kind`, `name`, `context` (the specification's `context`), `member`
(the path of the file that declares it), `line` (the declaration's line in that
file) and `details`. The pair (`kind`, `name`) is unique in a document.

An edge has `from` and `to`, each `{"kind", "name"}` naming a node of the same
document, `relation`, and `attributes`, an object that may be empty.

## Node kinds

Lists in `details` keep declaration order. Enumerations use the specification
language's own spelling.

| `kind` | Declaration | `details` |
| --- | --- | --- |
| `aggregate` | `aggregate` | `states`, `commands`, `events` (names), `machine` (see Aggregate machines), and `category`: the stream category the generated inspector catalog mounts the aggregate under, which the live route `/aggregate/list?name=` takes. A saga aggregate reports its own category, not the process's saga category. |
| `process` | `process` | `stableName`, `saga` (`aggregate`, `category`), `correlate` (`field`, `via`), `inputs` (input names), `target`, `projections`, `timers`, `rejected` and `poison` (`halt`, `deadLetter` or `skip`). |
| `workflow` | `workflow` | `stableName`, `input`, `output`, `steps`: objects with `form` (`step`, `await`, `sleep`, `child`, `patch`, `continue-as-new`) and `label` when the form has one. A patch's items follow the patch item. |
| `router` | `router` | `stableName`, `input`, `target`, `resolvesFrom` (the read model, or `null` for a hand-written resolver), `projections`. |
| `contract` | `contract` | `schemaVersion`, `discriminator`, `topics` (`alias`, physical `topic`), `events`. |
| `intake` | `intake` | `contract`, `topicAlias`, `topic` (physical), `accepts`, `dedupe` (`key`, `policy`), `idempotence` (`inbox-table` or `delegated`). |
| `emit` | `emit` | `contract`, `topicAlias`, `topic` (physical), `source`, `key`, `events` (the distinct mapped events). |
| `publisher` | `publisher` | `emit`, `ordering`, `maxAttempts`, `backoff` (`kind`, `window`, `max`, `multiplier`), `outboxField`. |
| `workqueue` | `workqueue` | `logical`, `physical`, `dlq`, `table`, `ordering` (`unordered`, `fifo-throughput`, `fifo-roundrobin`, `fifo-heads`), `maxRetries`, `dlqOn`. |
| `dispatch` | `dispatch` (pgmq) | `sourceReadModel`, `dedupReadModel` (the target of its `reads` edge with `role` `dedupe`), `enqueueTo`. |
| `read-model` | `readmodel` | `table` and `schema` (`null` for a catalog-bound model), `version`, `group`, `observedTargets`, `backingTarget`. |
| `operation` | `operation` | `form` (`command`, `query`, `signal`, `run`), `subject`, and `label` for a signal. |
| `projection-target` | `target` | `schema`, `table`, `reset` (`clear` or `preserve`), `dependsOn`. |
| `rebuild-group` | `rebuild-group` | `targets`, `order`. |
| `projection-owner` | `projection-owner` | `sources` (`{"kind":"aggregate","name"}`, `{"kind":"category","name"}` or `{"kind":"all"}`), `delivery` (`inline` or `subscription`), `group`, `targets`, `order`, `subscription`, `dedup`, `replay` (`mode` `explicit` or `live-only`, and its `reason`). |
| `projection-revision` | `projection-revision` | `group`, `targets` (`target`, `schemaVersion`). |
| `external-read` | `external-read` | `contract` (the declared name), `version`, `queryModel`, `resultSchema`, `resultType`, `compatibleRevisions`, `surfaceGeneration`. |

A document emitted by an older keiro-dsl lacks the aggregate `category` and the
dispatch `dedupReadModel`; both are optional in the JSON Schemas. Regenerate a
committed document to get them.

The `name` of most nodes is the declared name. A process, router or workflow uses
its block identifier and reports the quoted `name` as `stableName`. An external
read's `name` is its contract name, `_v` and its version (`order_totals_reader_v1`),
because several versions of one contract may coexist.

## Aggregate machines

Every Keiro aggregate is a keiki transducer: a finite state machine whose edges
each leave one state, consume one command, emit zero or more events and enter a
target state. A process manager keeps its progress in a saga aggregate, so its
machine is on the aggregate its `saga` edge points at. An aggregate node's
`details.machine` describes the machine in keiki's vocabulary:

```json
{
  "ownership": "generated",
  "initial": "Draft",
  "states": [{"name": "Draft", "terminal": false}, {"name": "Done", "terminal": true}],
  "edges": [
    {"source": "Draft", "edgeIndex": 0, "target": "Done", "mode": "Live",
     "command": "PlaceOrder", "events": ["OrderPlaced"]}
  ]
}
```

| Field | Meaning |
| --- | --- |
| `ownership` | `generated` when keiro generates the transducer from the specification (including transitions with a hand-written `implementation hole` body, whose edges are still generated), `legacy-hole` for the frozen Language 1 form whose whole transducer is hand-written. |
| `initial` | The first declared state. |
| `states` | Every state in declaration order (the generated vertex type's constructor order), with `terminal` for a state declared with `!`. |
| `edges` | Ordered by the source state's position in `states`, then by `edgeIndex`. |

Each edge has `source`, `edgeIndex`, `target`, `mode`, `command` and `events`.
`edgeIndex` is keiki's edge identity within one source state: the edge's position
in keiki's `edgesOut source`, which is the number of earlier transitions with the
same source in declaration order. It is local to the source state and changes
when transitions are reordered, so do not store it as a durable identifier.
`mode` is spelled as keiki's `EdgeMode`: `Live` edges serve new commands, and
`ReplayOnly` edges exist only so old events still replay. `events` are in
emission order and may be empty. Guards, register writes and output field terms
are not exported.

The machine is computed from the specification alone. The conformance suite
`keiro-dsl-conformance-topology-machine` compiles generated code, walks the real
keiki transducers with keiki's accessors (`edgesOut`, `target`, `mode`,
`initial`, `isFinal`, `edgeInputName` and each output's wire-constructor name),
and fails unless the result equals the exported machine. Its fixture covers
several edges per state, non-adjacent same-source transitions, a replay-only
edge, a two-event edge, a terminal state, a hole-owned transition body and a
process saga. A `legacy-hole` machine lists the declared transitions, but its
hand-written transducer is not proven to match them.

`machine` is an added field within `keiro-dsl/service-topology/1`. Documents
emitted before it existed omit it, so a consumer must treat it as optional; when
it is present, all of its fields are present.

## Relations

| `relation` | From | To | `attributes` |
| --- | --- | --- | --- |
| `dispatches` | process, router | aggregate | `command`. Every dispatch of a process body and the command its timers fire. |
| `saga` | process | aggregate | `category`. |
| `reads` | router, dispatch | read-model | `role`: `resolve` (router), `source` or `dedupe` (dispatch). |
| `projects` | process, router | aggregate | `table`. The aggregate whose `projection` clause owns that table. |
| `publishes` | emit | contract | `topicAlias`, `topic`, `events`. |
| `subscribes` | intake | contract | `topicAlias`, `topic`, `events` (the accept list). |
| `delivers` | publisher | emit | none. |
| `enqueues` | dispatch | workqueue | none. |
| `commands` | operation | aggregate | none. |
| `queries` | operation | read-model | none. |
| `signals` | operation | workflow | `label`. |
| `runs` | operation | workflow | none. |
| `depends-on` | projection-target | projection-target | none. |
| `groups` | rebuild-group | projection-target | none. |
| `consumes` | projection-owner | aggregate | none. A category or `all` source has no edge and appears only in `sources`. |
| `writes` | projection-owner | projection-target | none. |
| `member-of` | projection-owner, read-model | rebuild-group | none. |
| `revises` | projection-revision | rebuild-group, projection-target | `schemaVersion` on the target edges. |
| `observes` | read-model | projection-target | none. |
| `backed-by` | read-model | projection-target | none. |
| `exposes` | external-read | read-model | none. |
| `compatible-with` | external-read | projection-revision | none. |

To find which aggregate events feed a read model, follow `consumes` back from a
projection owner to the aggregate, `writes` to its targets, and `observes` or
`backed-by` from the read model to the same targets. A read model supplied by an
aggregate `projection` clause instead has the same name as that clause's table.

A `projections` entry of a process or router names an aggregate projection
table, not a read-model declaration, so its `projects` edge ends at the
aggregate that owns the table. Two aggregates may project into one table; each
gets an edge.

Workflows have no `dispatches` edges: a workflow body lists labelled steps and
names no target aggregate or command.

## Schema id /2

A process or router input may declare the intake that feeds it
(`input X from intake <Intake> event <Event>… { … }`, candidate Language 6; see
[Declared input sources](keiro-dsl-processes-and-routers.md#declared-input-sources)).
Each declared source is exported as an edge:

| `relation` | From | To | `attributes` |
| --- | --- | --- | --- |
| `feeds` | intake | process, router | `input` (the input's name), `events` (the named events, in declared order). |

`feeds` is a new relation, so it needs a new schema id. A document is emitted
under the lowest schema id able to represent it. A document with at least one
`feeds` edge is `keiro-dsl/service-topology/2`, which is `/1` plus that relation
and is otherwise identical in shape, including `machine`. Every other document
stays `keiro-dsl/service-topology/1`, byte for byte what it was before `/2`
existed. A `/1` consumer that receives `/2` must reject it rather than drop the
edges.

## What is not exported

Wire, codec, guard, register-write and output-field detail; a projection revision's
provisioner, validator, expected-shape and promotion-object fields; broker,
consumer-group and other runtime configuration.

## Encoding

The document is encoded with the JSON Canonicalization Scheme (RFC 8785):
object keys sorted, no insignificant whitespace, one number format. It is
followed by exactly one newline. Nodes are sorted by `kind` then `name`, and
edges by `from.kind`, `from.name`, `relation`, `to.kind`, `to.name` and the
canonical bytes of `attributes`, all compared as plain strings. Identical edges
appear once. For the same sources and `keiro-dsl` version the bytes are
identical on every run and platform.

Reordering top-level declarations changes only each moved node's `line` and the
member's `sha256`. Reordering inside a declaration (states, transitions, steps)
is a meaningful change and may change the document; reordering an aggregate's
transitions changes its machine's edge indexes.

## Compatibility policy

Within one schema id keiro may add object fields, and consumers must ignore
fields they do not know. A new node kind, a new relation or a change in the
meaning of an existing field requires a new schema id. A consumer must therefore
reject a document whose schema id, node kind or relation it does not know,
rather than drop what it cannot read.

## Serving the document

A keiro inspection host can serve the committed document. The host mounts it with
`AppHooks.serviceTopology` in code or with `--topology FILE` on a standalone
`mainWithHooks` host (see
[Serve Keiro Ops Over HTTP](../guides/serve-keiro-ops-over-http.md#service-topology)).
It then answers two `GET` routes, under `/keiro/topology/` on a composed host:

- `/topology/show` returns the mounted bytes unchanged, in this page's contract and
  camelCase fields.
- `/topology/summary` returns a snake_case header computed when the document was
  mounted.

Mounting refuses any schema id other than `/1` and `/2`, and any node kind or
relation unknown to the declared id. The document describes the committed
specification, not the running binary. The host never checks freshness;
`keiro-dsl topology --check` does that in the service's gate.

Summary served for `hospital-capacity.topology.golden.json` by
`jitsurei-ops-http --topology` (recorded 2026-11-17):

```json
{"document_bytes":18760,"document_sha256":"sha256:d34a4e1580e7af6e4a9dab8984419048b737230c88b47536925d75bb6ed914d0","edge_counts":{"consumes":1,"delivers":1,"dispatches":3,"enqueues":1,"groups":2,"member-of":4,"observes":2,"projects":3,"publishes":1,"reads":3,"runs":1,"saga":1,"signals":1,"subscribes":1,"writes":2},"generator_version":"<version>","members":[{"path":"hospital-capacity.keiro","sha256":"sha256:0c849100a91719ea9e034eb042187f3f4ab41f85689a90b85dedf651dfb3ae5e"}],"node_counts":{"aggregate":5,"contract":1,"dispatch":1,"emit":1,"intake":1,"operation":2,"process":1,"projection-owner":2,"projection-target":2,"publisher":1,"read-model":4,"rebuild-group":1,"router":1,"workflow":1,"workqueue":1},"schema_id":"keiro-dsl/service-topology/1","service":"hospital-capacity","source":{"kind":"source","path":"hospital-capacity.keiro"}}
```

`source` is present only when the document's `source` has `kind` `source` or
`workspace` and a string `path`. `node_counts` and `edge_counts` list only the kinds
and relations that occur.

### Handoff for keiro-ui

This section is the input for the console page in `mori://shinzui/keiro-ui`. The
client paths below are relative to that repository (artifact-level URIs pending).

**Client.** Add a read for each route in `packages/client-keiro/src/client.ts` and a
query key for each in `packages/client-keiro/src/query-keys.ts`. Add `topology` to
`HOOK_GATED_WORDS` in `packages/client-keiro/src/errors.ts`. An unmounted host then
yields `RouteUnavailable`, and the page can say that the host mounts no topology.

**Read order and caching.** Read `/topology/summary` first. It is the mount probe.
Its `schema_id` lets the console say "this console does not understand schema X"
before fetching anything large, and `document_sha256` is the cache key. Key the
`show` query on that digest within the selected host. Hash the raw `show` response
bytes before caching them under the summary's digest, because a deployment can
change between the two requests. On a mismatch, discard the pair and refresh the
summary once. If the second pair also disagrees, report that the deployment is
changing. The document is fixed for the life of a host process. Each read takes one
of the host's four admission slots and the client keeps three in flight
(`KEIRO_MAX_CONCURRENT`), so fetch `show` once per digest.

**Validation.** The client validates with zod (`packages/client-keiro/src/schemas.ts`)
and has no JSON Schema validator. Make the schema loose on object fields, because
keiro may add fields within a schema id. Make it strict on `schema`, node `kind`,
edge endpoint `kind` and edge `relation`, which this page's compatibility policy
requires a consumer to reject when unknown. Both ids use the same 17 node kinds:

```text
aggregate process workflow router contract intake emit publisher workqueue dispatch
read-model operation projection-target rebuild-group projection-owner
projection-revision external-read
```

`keiro-dsl/service-topology/1` has 22 relations, and `/2` adds `feeds`:

```text
dispatches saga reads projects publishes subscribes delivers enqueues commands
queries signals runs depends-on groups consumes writes member-of revises observes
backed-by exposes compatible-with
```

**Errors.** A `413 inspection_result_too_large` on `show` means the mounted bytes
exceed the host's response limit. Standalone hosts refuse such a file at startup, so
in practice this comes from a composed host. A 413 on `summary` applies to the
encoded summary, which grows with the member list. In both cases the host operator
can raise `inspectionLimits.maxResponseBytes`; the read has no parameters to narrow.
`409 schema_drift` and `503 inspection_busy` mean what they mean for every keiro
read.

**Fixtures.** Use the goldens under `keiro-dsl/test/fixtures/topology/` in
`mori://shinzui/keiro` (artifact-level URI pending):
`hospital-capacity.topology.golden.json`, `incident-command.topology.golden.json`,
`projection-catalog.topology.golden.json`, `workspace/service.topology.golden.json`
and the `/2` document `incident-command-sourced.topology.golden.json`. The recorded
summary above matches the hospital golden.

**Joins to live inspection routes.** A node links to live state only through the
field in this table. Every row names the code that makes the two values equal.

| Node kind | Live route | Join | Holds because |
| --- | --- | --- | --- |
| `aggregate` | `/aggregate/list?name=`, `/aggregate/show?name=&id=` | `details.category` equals a mounted `name` in `/aggregate/types`; take the instance `id` for `show` from a list row | The generated inspector catalog mounts each aggregate under `categoryText` of its generated `<agg>Category` (`inspectorLine` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`), which is built from `aggregateStreamCategory`. The topology node calls the same function (`keiro-dsl/src/Keiro/Dsl/Topology.hs`). `keiro-dsl/test/Keiro/Dsl/TopologySpec.hs` checks every hospital aggregate against the scaffolded catalog. Holds when the host mounts the generated `aggregateInspectorCatalog`. |
| `process` | `/pm/list?name=`, `/pm/show?name=&correlation=` | `details.saga.category` equals the `category` of an item in `/pm/types`; use that item's `name` only when exactly one item matches | `/pm/types` reports `categoryText` of the category the inspector was built with (`listProcessManagerTypes` in `keiro/src/Keiro/ProcessManager/Inspect.hs`). The generated `<process>Category` is `Stream.categoryUnsafe` of the declared saga category (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`), the value the topology exports. keiro-dsl does not generate the process-manager catalog, so this holds when the host builds the inspector from that generated category. The lookup `name` is host-chosen. |
| `workflow` | `/wf/inspect/list?workflow_name=`, `/wf/inspect/counts?workflow_name=` | `details.stableName` | The generated workflow module defines `workflowName = WorkflowName "<stable name>"` (`keiro-dsl/src/Keiro/Dsl/Harness.hs`), and the topology exports the same declared stable name. Holds when the application runs the workflow under that binding. |
| `projection-owner` | `/projection/position?subscription=` | `details.subscription`, when it is not `null` | The generated projection catalog declares `SubscriptionDeclaration` with the owner's subscription text as its durable subscription name (`subscriptionExpr` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`). `/projection/position` takes that durable Kiroku subscription name. `null` means inline delivery, which has no subscription. Holds when the host runs the generated catalog. |

Not guaranteed:

- `workqueue`: the only keiro surface for a job queue is `pgmq dlq read|redrive|archive|purge`.
  It takes the *logical* queue name (`details.logical`, mapped to the physical name
  by `queueRef` in `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`), not `details.physical`.
  Every one of those commands is a mutation reached by `POST`, including `read`,
  which reserves entries. A read-only console has no live queue route to link.
- `intake`: `/inbox/list?source=` filters by the producing bounded context's source.
  No exported intake field is that source, so a link would be a guess.
- `emit`: `details.source` is the declared outbox source, but the scaffold generates
  no code from it, and the application supplies `source` when it writes an
  integration event. A link from `details.source` to `/outbox/list?source=` is
  plausible but not enforced by generated code.

A node has no link when its join field is absent (`details.category` is missing
from documents emitted before it existed) or when the matching route's hook is not
mounted. The console can detect a document that disagrees with the running binary
by comparing aggregate `category` values with `/aggregate/types`. It should show
the mismatch rather than hide it.

keiro's demo host Jitsurei is hand-written and has no specification, so
`jitsurei-ops-http --topology` serves a document about another service. None of its
nodes join to Jitsurei's live data. The goldens support page development; live joins
need a keiro-dsl service.

Beyond links, the edges `consumes`, `writes` and `observes` trace aggregate events
to read models, `details.machine` gives each aggregate's keiki state machine (see
Aggregate machines), and `member` and `line` locate each node in the specification
source.

Consumer documentation follow-up belongs to keiro-ui: the integration guide
(`mori://shinzui/keiro-ui/okf/user-documentation/concepts/DOC-5`) and the
capability pages for aggregate inspection
(`mori://shinzui/keiro-ui/okf/capabilities/concepts/CAP-6`), process-manager
inspection (`mori://shinzui/keiro-ui/okf/capabilities/concepts/CAP-7`), workflow
inspection (`mori://shinzui/keiro-ui/okf/capabilities/concepts/CAP-5`) and
projection monitoring (`mori://shinzui/keiro-ui/okf/capabilities/concepts/CAP-9`).
