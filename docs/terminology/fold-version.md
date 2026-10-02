---
type: Term
title: fold version
description: "A fold version is an application-maintained identifier for handwritten logic that reconstructs aggregate state from events."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-55
status: current
tags:
  - replay
related:
  - TERM-5
  - TERM-56
anchors:
  - kind: doc
    resource: docs/user/snapshots.md
---

# fold version

A fold version is an application-maintained identifier for handwritten logic that reconstructs aggregate state from events.

Folding behavior can change without event-format or state-type changes. A fold version in the snapshot discriminator prevents reuse of old snapshot state under new behavior.

The version does not prove compatibility with stored history. Use a [replay audit](replay-audit.md) for that evidence. Generated DSL behavior also contributes a specification-derived fold fingerprint.

See [snapshots](../user/snapshots.md).
