---
type: Improvement Request
title: Export a versioned service topology from keiro-dsl
description: >-
  Add a keiro-dsl command that emits one service's topology as a versioned JSON document: its
  aggregates, processes, workflows, routers, contracts, intakes, emits, publishers, work queues,
  dispatches, read models and operations, and the node-to-node edges between them. Mori would
  then ingest a committed export instead of reading .keiro sources.
timestamp: 2026-11-16T21:41:12Z
requestId: IR-62
status: proposed
origin: mori://shinzui/mori
relatedPlans:
  - mori://shinzui/mori/masterplans/45-expose-keiro-service-topology-through-a-mori-extension-and-the-http-api
  - mori://shinzui/mori/plans/330-define-the-keiro-service-topology-contract-and-request-its-export-from-keiro-dsl
acceptanceCriteria:
  - id: AC-1
    statement: "`keiro-dsl topology <workspace-or-source> --format json` prints a `keiro-dsl/service-topology/1` document for a single source and for a workspace. It contains one node per aggregate, process, workflow, router, contract, intake, emit, publisher, workqueue, dispatch, read-model and operation declaration, and one edge per relation listed under Request."
    verification: Golden tests over the two keiro-runtime-jitsurei services (hospital-capacity and incident-command) and over a workspace fixture, comparing the output with checked-in expected documents.
  - id: AC-2
    statement: The output is byte-stable. Nodes are sorted by (kind, name), edges by (from, relation, to, attributes), and object keys are sorted, so the same sources give the same bytes on every run and platform.
    verification: A test that runs the command twice on each fixture and compares the bytes, plus a test that reordering declarations inside a source does not change the output.
  - id: AC-3
    statement: "`keiro-dsl scaffold` accepts `--topology-out FILE` and writes the same document as `topology`, so a service that already regenerates on every spec change keeps its committed export fresh with no extra step."
    verification: A scaffold test asserting that the written file equals the `topology` output for the same input.
  - id: AC-4
    statement: A freshness check fails when a committed topology document no longer matches its sources, because a member's sha256 differs or the regenerated document differs. It is usable from a service's existing generated-code gate.
    verification: A test that edits one member after writing the document and asserts a non-zero exit naming the stale member, and a zero exit on the unchanged sources.
  - id: AC-5
    statement: The schema id, every node kind, details field and relation, and the compatibility policy (what may be added within `/1` and what needs a new id) are documented in keiro's user docs, with a JSON Schema checked in beside them.
    verification: The user-documentation gate passes, and the golden documents from AC-1 validate against the checked-in JSON Schema in a test.
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-11-16T21:41:12Z
    document_timestamp: 2026-11-16T21:41:12Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      The authoring model's own verification, not an independent review. It ran
      `keiro-dsl inspect domain/mori.keiro-workspace --format json` with keiro-dsl 0.22.0.0 in
      mori://shinzui/mori, read the `Node`, `ProcessNode` and `RouterNode` declarations in
      keiro-dsl/src/Keiro/Dsl/Grammar.hs at keiro commit 0b756a65, and read the contract, intake,
      emit, publisher, process, router, workflow and operation declarations of both
      keiro-runtime-jitsurei services at commit e3c800e. It did not read the check-report,
      coverage-report or diff-report encoders beyond their schema ids and top-level fields.
---

# Improvement Request: Export a Versioned Service Topology from keiro-dsl

## Status

Proposed. Mori is not blocked:
`mori://shinzui/mori/masterplans/45-expose-keiro-service-topology-through-a-mori-extension-and-the-http-api`
builds its loader, registry read models, cross-service queries and HTTP routes against
hand-derived fixtures in this document's shape. Real services appear in Mori's registry only
once this export exists.

## Context and evidence

Mori is building a `keiro` extension so that an engineer can see a service's structure without
reading its `.keiro` sources, and can ask questions that no single repository can answer, such as
"which services consume contract `emergency` on `emergency.hospital.events`?". The registry
would hold one topology per keiro service: its aggregates, process managers, durable workflows,
routers, inbox intakes, outbox emits and publishers, work queues, dispatches, read models and
operations, and how they connect.

Mori should not parse `.keiro` sources itself. Its decision record
`mori://shinzui/mori/okf/adrs/concepts/ADR-33` binds Mori to a sibling's published contract
instead of its internals. Linking keiro-dsl would tie every registered service to the keiro-dsl
version Mori builds with, and a project pushed to a shared registry has no working tree to parse.
Mori's plan is therefore to ingest a committed document that the service's own pinned keiro-dsl
generated. It would detect staleness from per-member digests, as it already does for other
registration inputs.

No current keiro-dsl output describes a topology:

- `inspect --format json` emits `keiro-dsl/source-inspection/1`: the service name, member paths
  and language versions only. For Mori's seventeen-member workspace it is about 2 KB.
- `check --report-out` (`keiro-dsl/check-report/1`) holds diagnostics and process reactions.
- `--coverage-report` (`keiro-dsl/coverage-report/1`) lists typed field paths, such as
  "AccessGrant command GrantAccess .grantId". These name some nodes but say nothing about how
  they connect.
- `behavior-obligations --format json` (`keiro-dsl/behavior-obligations/1`) lists aggregate
  commands, events and transitions, but no other node kind.
- `diff --report-out` (`keiro-dsl/diff-report/1`) is relative to a git ref.

All of these use a versioned `schema` id, which this request follows.

The two keiro-runtime-jitsurei services are a natural acceptance pair. `hospital-capacity`
declares contract `emergency` (schemaVersion 1, topics `incidentEvents` →
`emergency.incident.events` and `hospitalEvents` → `emergency.hospital.events`). It also
declares intake `incidentInbox` on `incidentEvents`, emit `hospitalIntegrationOutbox` on
`hospitalEvents`, publisher `hospitalPublisher`, workqueue `reservation_work` and dispatch
`reservation_work_dispatch`. `incident-command` declares its own copy of `emergency`, intake
`hospitalInbox` on `hospitalEvents`, emit `incidentTransferNeed` on `incidentEvents` and
publisher `incidentPublisher`. Each publishes what the other consumes.

## Request

Add `keiro-dsl topology <workspace-or-source> --format json`, emitting a document with schema id
`keiro-dsl/service-topology/1`. Mori offers the following shape as a starting draft. Keiro owns
the final contract, and Mori will follow it.

```json
{
  "schema": "keiro-dsl/service-topology/1",
  "service": "hospital-capacity",
  "source": { "kind": "source", "path": "services/hospital-capacity/spec/hospital-capacity.keiro" },
  "effectiveSemanticContract": { "languageVersion": 6, "languageSupport": "candidate", "runtimeSemantics": "keiro-dsl/runtime-semantics/5" },
  "generator": { "tool": "keiro-dsl", "version": "<keiro-dsl version>" },
  "members": [ { "path": "hospital-capacity.keiro", "sha256": "sha256:<hex>", "declaredLanguageVersion": null, "effectiveLanguageVersion": 6 } ],
  "nodes": [
    { "kind": "process", "name": "HospitalSurge", "context": "hospital-capacity",
      "member": "hospital-capacity.keiro", "line": 420, "details": { } }
  ],
  "edges": [
    { "from": { "kind": "process", "name": "HospitalSurge" },
      "to": { "kind": "aggregate", "name": "Hospital" },
      "relation": "dispatches", "attributes": { "command": "ActivateSurge" } }
  ]
}
```

`effectiveSemanticContract` reuses the shape `inspect` already emits. Each member's `sha256` is
the digest of its exact bytes, which lets a consumer tell when a committed document is older than
its sources. The pair (`kind`, `name`) is unique within a document, and `name` is the block
identifier.

The node kinds are `aggregate`, `process`, `workflow`, `router`, `contract`, `intake`, `emit`,
`publisher`, `workqueue`, `dispatch`, `read-model` and `operation`. Their `details`, as Mori
drafts them:

- **aggregate**: `states`, `commands` and `events`.
- **process**: `stableName`, `saga` (aggregate and category), `correlate`, input type names,
  `target`, `projections`, `timers`, and the `rejected` and `poison` policies.
- **workflow**: `stableName`, `input`, `output`, and ordered `steps`, each with its form and
  label.
- **router**: `stableName`, `input`, `target`, the read model it resolves from, and
  `projections`.
- **contract**: `schemaVersion`, `discriminator`, `topics` (each an alias with its physical
  topic) and `events`.
- **intake**: `contract`, topic alias, the resolved physical `topic`, `accepts`, `dedupe` and
  `idempotence`.
- **emit**: `contract`, topic alias, the resolved physical `topic`, its source label, `key`, and
  the contract events it can produce.
- **publisher**: `emit`, `ordering`, `maxAttempts`, `backoff` and `outboxField`.
- **workqueue**: `logical`, `physical`, `dlq`, `table`, `ordering`, `maxRetries` and `dlqOn`.
- **dispatch**: `sourceReadModel` and `enqueueTo`.
- **read-model**: `table`, `schema`, `version` and `group`.
- **operation**: its form (command, query, signal or run), its subject, and a signal's label.

Every edge runs from one node to another node in the same document. The relation set is closed:

- `dispatches`: from a process, router or workflow to an aggregate, carrying `command`. It
  covers process `dispatch` statements, timer `fire dispatch`, and router `dispatch-each`.
- `saga`: from a process to its saga aggregate.
- `reads`: from a router or dispatch to the read model it resolves from or deduplicates
  against.
- `projects`: from a process or router to each read model in its `projections`.
- `publishes`: from an emit to its contract, carrying `topicAlias`, the physical `topic` and
  `events`.
- `subscribes`: from an intake to its contract, carrying `topicAlias`, the physical `topic` and
  the `accept` list as `events`.
- `delivers`: from a publisher to its emit.
- `enqueues`: from a dispatch to its workqueue.
- `commands`, `queries`, `signals` (carrying `label`) and `runs`: from an operation to its
  aggregate, read model or workflow.

Physical topic names and contract `schemaVersion` are the fields that let a consumer relate two
services. Each service declares its own copy of a contract, so there is no shared contract
identity to point at.

Mori would also like three things around the command:

- The document should be byte-stable (AC-2), so that it diffs cleanly in review.
- `scaffold --topology-out FILE` (AC-3), so the export follows the generation a service already
  runs.
- A freshness check that a service's generated-code gate can call (AC-4).

The compatibility policy Mori assumes is the following. Keiro may add fields within `/1`, and
consumers ignore fields they do not know. A new node kind or relation, or a change in a field's
meaning, needs a new schema id, because a `/1` consumer must fail closed rather than silently drop
a component.

## Questions for keiro

1. A `projections` entry can name something other than a read-model declaration in the same
   document. Should the export drop such entries from `projects` edges, keep them as
   unresolved, or reject them?
2. Process and router inputs are typed, but the DSL does not say which intake feeds them. That
   gap is requested separately in IR-63. This export should not invent such an edge.

## What stays out

The following are out of scope: projection-catalog nodes (projection targets, rebuild groups,
projection owners, revisions and external reads); wire, codec and transition-body detail; broker
and consumer-group settings; runtime configuration; and anything specific to Mori. No change to
`check`, `diff`, `inspect` or the scaffold ledger is requested.
