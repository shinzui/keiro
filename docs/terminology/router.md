---
type: Term
title: router
description: A stateless dispatcher that reacts to an event by looking up recipients and sending commands to their streams.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

A router can query a [read model](read-model.md) to find recipients. For example, when an
incident is reported, it might find all teams responsible for that region and send a
command to each team's stream.

Unlike a [process manager](process-manager.md), a router does not maintain its own
event-sourced process state. Dispatch is idempotent for a recipient resolved again on
redelivery, but a repeated lookup can find different recipients. See
[Routers and Effectful Fan-Out](../guides/routers-and-effectful-fan-out.md) for the
recipient and retry guarantees.
