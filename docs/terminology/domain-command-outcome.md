---
type: Term
title: domain command outcome
description: "A domain command outcome is the typed business result of a selected decision: acceptance, rejection, or an intentional no-op."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-47
status: current
tags:
  - modeling
anchors:
  - kind: doc
    resource: docs/user/command-cycle.md
---

# domain command outcome

A domain command outcome is the typed business result of a selected decision: acceptance, rejection, or an intentional no-op.

A reservation command can accept work, reject insufficient capacity, or make no change to an already satisfied request. Accepted decisions emit events. Rejections and no-ops carry typed reasons without durable state changes.

Business rejection differs from execution failure. A command without a matching transition remains a command error. Keiro does not automatically assign it a typed business reason.

See [command cycle](../user/command-cycle.md).
