---
type: Term
title: continue-as-new
description: "A workflow operation that starts a fresh journal generation while carrying forward explicitly chosen state."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-59
status: current
tags:
  - durable-workflows
aliases:
  - workflow rotation
related:
  - TERM-14
  - TERM-15
anchors:
  - kind: doc
    resource: docs/user/durable-workflows.md
---

# continue-as-new

A recurring workflow can otherwise accumulate an unbounded [journal](journal.md). Continue-as-new closes the current generation and carries a seed into the next, allowing the same workflow instance to continue with bounded history per generation.

The new generation restores that seed rather than replaying every prior step. An [awakeable](awakeable.md) allocated in the new generation has a fresh identifier that must be passed to its external participant.

See [durable workflows](../user/durable-workflows.md) for details.
