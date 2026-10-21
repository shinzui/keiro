---
type: Architecture Decision Record
title: Aggregate inspection reuses hydration without diagnostics on the command path
description: Explicit aggregate catalogs render shared hydration and bounded public stream pages while ordinary commands keep a specialized result path.
timestamp: 2026-10-21T00:49:10Z
docId: ADR-54
status: Accepted
date: 2026-10-20
originatingPlan: docs/plans/278-expose-aggregate-inspection-read-apis.md
---

# Aggregate inspection reuses hydration without diagnostics on the command path

## Context

[ADR-40](0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
requires isolation from the core runtime. Aggregate state must agree with the
command runner's replay, including snapshot fallback. Independently implementing
inspection replay would let those algorithms drift; attaching a diagnostic pair
to every ordinary hydration would impose inspection cost on ordinary commands.

## Decision

`hydrate` and `hydrateWithSource` use one private continuation worker. The
ordinary continuation ignores its lazy diagnostic argument and returns only the
existing result. The worker inlines at the two entry points; optimized ordinary
Core contains no source/reason constructors. Allocation comparisons cover
snapshot hit, miss, corruption, no codec and long full replay. Existing metrics,
seed verification, fallback and the compile-time reaction probe retain their
ordinary behavior. Inspection options disable seed verification and telemetry.

An application explicitly supplies aggregate descriptors and display encoders.
A descriptor’s membership mapping must resolve back to the selected physical
stream, so metadata, listing and hydration cannot describe different streams;
custom audit-target handles retain their mapping.
Snapshot encodings are not implicitly a display contract. The library owns JSON,
ops mounts the catalog through an optional hook, and HTTP derives its routes from
ops. State reports the exact folded version; separately observed stream heads
and snapshot clocks are observational metadata rather than an atomic view.
Deleted streams return metadata without hydration. Raw history remains Kiroku's.

Listings consume one public `listStreams` raw page from
`mori://shinzui/kiroku/packages/kiroku-store`, with category/prefix selection.
Filtering never drains more pages to fill the display. Continuation uses the last
raw row examined, including a page whose display is empty, and is bound to the
inspector/category identity and shared cursor byte limit.

## Consequences

Ordinary applications gain no inspection catalog, recurring task, store read or
metadata serialization. Hosts decide which state they expose. Shared database
contention still requires runtime interference checks; total inspection
allocation has no blanket percentage target. Large replay remains bounded by the
HTTP host's admission and execution policy when served over that surface.
