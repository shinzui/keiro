---
type: Term
title: replay audit
description: "A check that runs candidate application behavior against stored event histories to detect replay failures or changes in reconstructed state."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-56
status: current
tags:
  - replay
related:
  - TERM-28
anchors:
  - kind: doc
    resource: docs/user/replay-safety.md
---

# replay audit

Structural [replay-safety](replay-safety.md) validation checks the model being constructed. A replay audit checks actual histories, including events produced by older models.

Keiro can target affected streams and report replay errors, snapshot-seed divergence, and state digests for comparison. The result is evidence about the histories checked, not proof of every future behavior or business invariant.

See [replay safety](../user/replay-safety.md) for details.
