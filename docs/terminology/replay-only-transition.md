---
type: Term
title: replay-only transition
description: "A replay-only transition reconstructs historical events without letting new commands select the retained behavior."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-54
status: current
tags:
  - replay
related:
  - TERM-63
anchors:
  - kind: doc
    resource: docs/user/keiro-dsl-aggregates.md
---

# replay-only transition

A replay-only transition reconstructs historical events without letting new commands select the retained behavior.

Removing an old rule can make stored streams unreadable. A replay-only transition retains its historical interpretation while retiring live behavior.

The transition must emit the evidence needed for replay. An [upcaster](upcaster.md) converts payload formats. It does not replace the behavior that interprets events.

See [Keiro DSL Aggregates](../user/keiro-dsl-aggregates.md).
