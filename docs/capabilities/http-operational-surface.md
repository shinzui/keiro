---
title: HTTP operational surface
type: Capability
description: Mount the supported operational command tree over bounded HTTP reads and explicitly confirmed mutations.
timestamp: 2026-10-27T16:27:49Z
generated:
  by: openai/codex
  at: 2026-10-20T17:05:00Z
capabilityId: CAP-20
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.22.0.0"
packages: [keiro-ops-http]
interface: [Keiro.Ops.Http, Keiro.Ops.Http.Feed, Keiro.Ops.Http.WebSocket, Keiro.Ops.Http.Protocol, Keiro.Ops.Http.Views, Keiro.Ops.Http.Compose]
requires: [CAP-16]
evidence:
  - kind: test
    resource: keiro-ops-http/test/Main.hs
    proves: Parser mapping, CLI agreement, schema refusal, preview and confirmation, admission and SQL deadlines, cancellation, bounded encoding, and socket lifecycle.
  - kind: guide
    resource: docs/guides/serve-keiro-ops-over-http.md
    proves: Dedicated inspection pool, embedding hooks, standalone serving, wire errors, and host policies.
  - kind: module
    resource: keiro-ops-http/src/Keiro/Ops/Http/Application.hs
    proves: The bare WAI application parses and executes the supported command tree without a duplicate route registry.
---

# HTTP operational surface

This extends the [schema-aware operational console](operational-console.md)
(CAP-16) with an optional browser-reachable transport. It is available from the
0.22.0.0 cohort; integrated interference acceptance is recorded under [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md).

`opsApplication` allocates one admission budget and returns a bare WAI
application. Reads return the supported command's JSON value. Mutations are
disabled unless the host enables them, then preview until the caller supplies
explicit confirmation. Every admitted operation verifies current schema
agreement. The [runbook](../guides/serve-keiro-ops-over-http.md) documents exact
limits, dedicated connection configuration, wire errors, and embedding.

The host supplies authentication and TLS. No existing Keiro package depends
on a web framework. DLQ reads reserve messages and therefore use the mutation
flow. This surface supplies operational state and actions; it adds no metrics
or trace backend.

## Shared observational feeds

The 0.22.0.0 surface includes `/ws` for workflow, timer and projection
status first pages. Drivers share canonical views across clients, use the HTTP
inspection budget, keep last-known state on read failure and bound queues by
encoded bytes and frame count including in-flight delivery. The last view
release joins its driver and wake pump; an idle handle owns no wake cursor or
recurring reads. Socket origin/schema/capacity checks precede acceptance.

`keiro-ops-http/test/Test/FeedSpec.hs` checks fallback truth, diffs, extra-only changes,
coalesced failures, strict overflow/recovery, initialization cancellation and
resource retirement. `keiro-ops-http/test/Test/WebSocketSpec.hs` checks real shared reads,
notify/fallback delivery, common poll encoders, replacement refusal, repeated
in-flight release, upgrade policies and active close. See
[Stream Keiro Inspection Views](../guides/stream-keiro-inspection-views.md).
Retained composed writer-interference evidence and the final candidate release
gate establish the cohort acceptance.

`Keiro.Ops.Http.Compose` mounts allocated owner applications with exact raw-path
stripping and one duplicate-safe CORS policy. The example mounts released
Kiroku metrics beside Keiro; no sibling web dependency enters the library.
