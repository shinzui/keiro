---
title: HTTP operational surface
type: Capability
description: Mount the supported operational command tree over bounded HTTP reads and explicitly confirmed mutations.
timestamp: 2026-10-20T17:05:00Z
generated:
  by: openai/codex
  at: 2026-10-20T17:05:00Z
capabilityId: CAP-20
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: unreleased
packages: [keiro-ops-http]
interface: [Keiro.Ops.Http]
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
default branch; publication and integrated interference measurements remain
pending under [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md).

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
