---
type: Architecture Decision Record
title: Legacy reaction provenance is bounded explicit opt-in metadata
description: Legacy manager writes may record bounded intended-dispatch evidence while default-off writes retain existing metadata, identities and database work.
timestamp: 2026-10-25T05:14:38Z
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

Inspection descriptors keep display encoders and membership mappings in the
application. Views use `hydrateWithSource` and the returned folded version,
then read the persisted event at exactly that version. Header, source, target
and timer observations are not a cross-stream atomic snapshot. Soft-deleted
journals expose lifecycle metadata and null state. Live input shapes describe
candidates rather than guard satisfaction. Listing uses one released Kiroku
category/prefix page; rejected membership rows advance the raw cursor without
hydration or draining more pages.

Pending timer pages bind manager and correlation filters and read database time
in the same transaction. Shard observations use database time for lease state
and heartbeat age, preserving the runtime's strict expiry comparison. Neither
read performs a claim, cleanup, heartbeat or other mutation. No timer index is
introduced: candidate indexes that narrow valid writer keys are rejected, and
response cardinality is not a query-cost guarantee. Automatic consumers must
respect measured workloads and inspection budgets.

Reaction state inspection does not imply reaction provenance. The accepted witness is a
one-way deterministic identity; it does not recover the original source UUID, decoded input,
input-selected target list or occurrence within a target. Only the first event of an accepted
batch gets that witness ID, and silent reactions create no new saga receipt. A descriptor
must not infer those missing inputs from current state or reuse legacy-family metadata as
modern dispatch evidence.

[Plan 319](../plans/319-inspect-reaction-process-managers-and-label-legacy-inspection-before-1-0.md)
therefore selects an explicit inspector provenance mode: legacy descriptors read bounded
legacy capture, while `reactiveProcessManagerInspector` reports unavailable provenance and
performs no target witness probes. It may expose state, live input candidates, timers and the
last persisted saga event. That event is not proof of the latest source delivery. Any future
modern provenance design needs an explicit persisted-evidence or source-resolution contract
with its own bounds and disabled-path cost evidence. The constructor adapts `sagaHandler.eventStream`, name and stream mapping without
changing reaction writes or identities. Library and embedded ops tests cover
state/list/timer inspection, multi-event acceptance, repeated input-selected
targets, silent deliveries and misleading legacy-looking metadata.

## Consequences

Applications constructing RunCommandOptions records directly must add the new
field; record updates from defaultRunCommandOptions inherit the disabled policy.
No metadata is backfilled, no notification is added and no provenance relation
or index is introduced. Capture has explicit write/encoding cost and a bounded
stored footprint. Its metadata is outside replay comparison except for the
unchanged schemaVersion stamp used by decoding. Publication still requires the
initiative's integrated core-path isolation evidence.
