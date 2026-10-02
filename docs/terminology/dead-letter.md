---
type: Term
title: dead letter
description: "A dead letter is a retained delivery failure that requires investigation before explicit replay."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-20
status: current
tags:
  - integration
related:
  - TERM-10
  - TERM-11
anchors:
  - kind: module
    resource: Keiro.DeadLetter
  - kind: doc
    resource: docs/user/dead-letters.md
---

# dead letter

A dead letter is a retained delivery failure that requires investigation before explicit replay.

Inspect the failed delivery and correct its cause before replay. Replay must tolerate effects that an earlier attempt already produced.

Keiro distinguishes retained command rejections from terminal subscription failures. Command rejection retention applies to configured [process managers](process-manager.md) and [routers](router.md).

See [Dead Letters](../user/dead-letters.md).
