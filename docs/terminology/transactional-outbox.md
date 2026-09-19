---
type: Term
title: transactional outbox
description: A durable record of messages waiting to be published, saved transactionally so a crash cannot lose the handoff to a separate publisher.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-18
status: current
tags:
  - integration
aliases:
  - outbox
related:
  - TERM-17
  - TERM-19
anchors:
  - kind: module
    resource: Keiro.Outbox
  - kind: doc
    resource: docs/user/outbox.md
---

# transactional outbox

The outbox separates deciding to send an [integration event](integration-event.md) from
actually publishing it. A worker sends the saved message and records the outcome, allowing
publication to resume after a crash.

In Keiro's standard pipeline, a subscription reads committed domain events and maps them
to outgoing messages. Saving those messages and advancing the subscription's checkpoint
happen in one transaction, so the subscription cannot move past a message it failed to
save. This transaction follows the original domain-event commit.

Publication is at least once: a crash after sending but before recording success can cause
redelivery. The receiving [inbox](inbox.md) deduplicates. See
[Durable Outbox](../user/outbox.md) for the pipeline and direct transactional enqueue option.
