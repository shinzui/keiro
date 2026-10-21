---
type: Architecture Decision Record
title: Legacy reaction provenance is bounded explicit opt-in metadata
description: Legacy manager writes may record bounded intended-dispatch evidence while default-off writes retain existing metadata, identities and database work.
timestamp: 2026-10-21T01:32:02Z
docId: ADR-55
status: Accepted
date: 2026-10-20
originatingPlan: docs/plans/274-expose-process-manager-inspection-reads.md
---

# Legacy reaction provenance is bounded explicit opt-in metadata

## Context

A persisted manager event previously identifies neither its source event nor the
intended target streams. These cannot be recovered from a one-way deterministic
UUID. Inspection needs honest evidence without introducing diagnostic work on
ordinary reactions. [ADR-24](0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
freezes those identities; [ADR-40](0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
requires isolation from the core path.

## Decision

`RunCommandOptions.inspectionProvenance` defaults to `NoInspectionProvenance`.
Hosts explicitly select `CaptureInspectionProvenance` independently of mounting
inspection. The disabled branch retains the original event-id options update;
it does not construct metadata, traverse follow-ups, resolve extra targets or
perform extra database work. The two legacy manager runners share this policy.
The modern reaction runner is unchanged and has no last-reaction provenance in
this cohort.

Capture adds one `keiro.pm` value to manager-event metadata, preserving caller
fields and the codec's rejection of non-object metadata. Encoding remains lazy
until a command actually encodes events. Deterministic event ids, payloads,
target commands and timer writes retain their existing paths. The value records
intended dispatches; it does not report transaction outcomes. Eventless,
rejected and partially dispatched reactions cannot be inferred from the last
persisted event alone.

The inner frame is version 1 and explicitly names `legacy-positional-v1`.
It retains at most 64 targets, 64 timer ids and 16 KiB encoded bytes. Counts use
bounded prefixes and one look-ahead element. Oversized values keep source-only
provenance with `truncated=true`. The reader rejects unsupported versions,
families and resource bounds; absence is unavailable evidence. Inspection uses
the configured manager name for legacy identity probes and reports only event
presence or lack of an observed witness. Modern target identities must never be
synthesized from this family.

## Consequences

Applications constructing RunCommandOptions records directly must add the new
field; record updates from defaultRunCommandOptions inherit the disabled policy.
No metadata is backfilled, no notification is added and no provenance relation
or index is introduced. Capture has explicit write/encoding cost and a bounded
stored footprint. Its metadata is outside replay comparison except for the
unchanged schemaVersion stamp used by decoding. Publication still requires the
initiative's integrated core-path isolation evidence.
