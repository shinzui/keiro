---
title: Aggregate inspection reads
type: Capability
description: Inspect application-described aggregate state and snapshot health and page stream metadata through supported read-only APIs.
timestamp: 2026-10-27T16:27:49Z
generated:
  by: openai/codex
  at: 2026-10-21T00:26:46Z
capabilityId: CAP-21
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.22.0.0"
packages: [keiro, keiro-ops]
interface: [Keiro.Inspection.Aggregate, Keiro.Ops.Aggregate]
requires: [CAP-3, CAP-4, CAP-16]
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: Folded-state parity, snapshot source, deleted-stream metadata and continuation through rejected raw rows.
  - kind: test
    resource: jitsurei/test/Main.hs
    proves: Real order and incident catalog descriptors expose state and snapshot health.
  - kind: module
    resource: keiro-ops/src/Keiro/Ops/Aggregate.hs
    proves: Read-only commands render owning library results without transport SQL.
---

# Aggregate inspection reads

Applications opt in through an explicit descriptor catalog. Display encoders
belong to the application, while hydration, snapshot health, JSON and cursor
paging belong to the library. Ops mounts four read-only commands from that same
catalog. See [the API reference](../user/api-reference.md#keiroinspectionaggregate)
and [ADR-54](../adr/0054-aggregate-inspection-reuses-hydration-without-diagnostics-on-the-command-path.md).

Introduced in the 0.22.0.0 cohort. Integrated isolation acceptance is recorded under [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md).
