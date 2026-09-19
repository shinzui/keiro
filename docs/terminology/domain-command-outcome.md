---
type: Term
title: domain command outcome
description: "The business result of a selected command decision, distinguishing acceptance, rejection, and an intentional no-op."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-47
status: current
tags:
  - modeling
anchors:
  - kind: doc
    resource: docs/user/command-cycle.md
---

# domain command outcome

A reservation command can accept new work, reject it because capacity is unavailable, or do nothing because the request is already satisfied. In Keiro's outcome-aware API, accepted decisions emit events; rejected and no-op decisions carry typed reasons without changing durable state.

A business rejection is distinct from an execution failure. A command with no matching transition also remains a command error rather than gaining a typed business reason automatically.

See [command cycle](../user/command-cycle.md) for details.
