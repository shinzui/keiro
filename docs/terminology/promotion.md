---
type: Term
title: promotion
description: "The controlled step that makes verified rebuilt projection data available for normal service."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

For an online rebuild, promotion switches the group from the serving [generation](projection-generation.md) to the verified candidate after catch-up and final checks. Offline rebuilding returns the verified group to service in place.

Promotion coordinates the group's targets and compatible read bindings. It must not expose a partially rebuilt view. Retained old data is useful for inspection, but does not by itself provide a safe rollback.

See [read models and projections](../user/read-models-and-projections.md) for details.
