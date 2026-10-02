---
type: Term
title: promotion
description: "Promotion is the controlled action that makes verified rebuilt projection data available for service."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-52
status: current
tags:
  - read-side
related:
  - TERM-51
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# promotion

Promotion is the controlled action that makes verified rebuilt projection data available for service.

Online promotion switches a group to the candidate after catch-up and final checks. Offline promotion returns the verified group to service in place.

Promotion coordinates targets and compatible read bindings. It must not expose a partially rebuilt view. Retained old data alone does not guarantee safe rollback.

See [read models and projections](../user/read-models-and-projections.md).
