---
type: Architecture Decision Record
title: The service topology is a versioned keiro-owned contract emitted under the lowest sufficient schema id
description: keiro-dsl topology publishes a canonical, digest-stamped document of a service's declarations and relations whose compatibility policy keiro owns, and each document carries the lowest schema id able to represent it.
timestamp: 2026-11-17T17:00:00Z
docId: ADR-62
status: Accepted
date: 2026-11-17
originatingPlan: docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md
---

# The service topology is a versioned keiro-owned contract emitted under the lowest sufficient schema id

## Context

Tools outside keiro, first Mori's registry, need to know how a service's declarations
connect without parsing `.keiro` sources or linking `keiro-dsl`. Mori asked for this in
`docs/improvement-requests/export-a-versioned-service-topology-from-keiro-dsl.md` (IR-62),
under its own boundary rule `mori://shinzui/mori/okf/adrs/concepts/ADR-33`. A committed
export only helps if its bytes are stable, it can be checked for staleness, and its meaning
can change without silently misleading older readers.

## Decision

`keiro-dsl topology <source-or-workspace>` emits one document whose shape keiro owns and
documents in `docs/user/keiro-dsl-service-topology.md` (DOC-35), with JSON Schemas under
`docs/user/schemas/`. The repository gate validates every golden document against the schema
its own `schema` field names. The document is computed from the checked specification alone,
and a service with error diagnostics is refused.

The bytes are canonical: RFC 8785 JSON, nodes and edges sorted by their spelled identity,
duplicate edges removed, one trailing newline. Paths are location-independent: the file
name of the source or manifest, and member paths relative to the manifest. Each member
records the sha256 of its exact bytes. That is what lets `topology --check FILE` and
`scaffold --topology-out FILE` keep a committed copy fresh. Both share one rendering function
with the command, so they cannot disagree on the bytes.

Compatibility policy: within one schema id keiro may add object fields, and consumers must
ignore fields they do not know. A new node kind, a new relation or a changed meaning requires
a new schema id, and a consumer must reject an id, kind or relation it does not know.

A document is emitted under the lowest schema id able to represent it.
`keiro-dsl/service-topology/1` covers the seventeen node kinds (including the projection
catalog) and twenty-two relations. `keiro-dsl/service-topology/2` adds only the `feeds`
relation (ADR-64) and is emitted only when a document contains one. Every other service keeps
a byte-identical `/1` document, so existing consumers keep working and fail closed only on
documents they could not represent.

## Consequences

- Adding an optional field, such as the aggregate `machine` object (ADR-63), stays within
  `/1`. Schemas and documentation must mark such a field optional for older documents.
- Any change to a golden topology document is a contract change and needs review. A
  regenerated golden that differs in more than the intended addition is a defect.
- `generator.version` is part of the document, so upgrading `keiro-dsl` makes a committed
  export stale. `--check` names that cause separately from a changed member.
- Reorder invariance holds over the document without member `sha256` and node `line`.
  Moving a declaration necessarily changes both.
- The scaffold ledger does not record the export, and scaffold without `--topology-out` is
  unchanged.
