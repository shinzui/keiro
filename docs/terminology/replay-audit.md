---
type: Term
title: replay audit
description: "A replay audit checks candidate behavior against stored event histories for replay failures and reconstructed-state changes."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A replay audit checks candidate behavior against stored event histories for replay failures and reconstructed-state changes.

Structural replay-safety validation checks the current model. A replay audit checks actual histories, including events from older models.

Keiro can report replay errors, snapshot-seed divergence, and state digests for selected streams. Results provide evidence for the checked histories. They do not prove every future behavior or business invariant.

See [replay safety](../user/replay-safety.md).
