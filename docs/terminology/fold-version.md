---
type: Term
title: fold version
description: "An application-maintained version identifying hand-written logic that reconstructs aggregate state from events."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

The fold is the event-processing logic that builds state. Its meaning can change even when event formats and state types remain identical.

Changing the fold version, when included in the snapshot discriminator, prevents old [snapshot](snapshot.md) state from being reused under new behavior. It does not prove historical compatibility; a [replay audit](replay-audit.md) provides evidence about actual histories. Generated DSL behavior also contributes a specification-derived fold fingerprint.

See [snapshots](../user/snapshots.md) for details.
