---
type: Term
title: router
description: "A router is a stateless dispatcher that looks up command recipients in response to an event."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-11
status: current
tags:
  - coordination
related:
  - TERM-10
anchors:
  - kind: module
    resource: Keiro.Router
  - kind: doc
    resource: docs/guides/routers-and-effectful-fan-out.md
---

# router

A router is a stateless dispatcher that looks up command recipients in response to an event.

A router can query a [read model](read-model.md) for teams responsible for an incident region. It then sends a command to each team stream.

The router has no event-sourced process state. Dispatch is idempotent for a recipient found again after redelivery. A repeated lookup can find different recipients.

See [Routers and Effectful Fan-Out](../guides/routers-and-effectful-fan-out.md).
