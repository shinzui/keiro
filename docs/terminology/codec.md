---
type: Term
title: codec
description: The finite registry of legal stored event type tags for one event type, with the encoder, decoder, schema version, and upcasters that carry events across the storage boundary.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-3
status: current
related:
  - TERM-2
anchors:
  - kind: module
    resource: Keiro.Codec
  - kind: type
    resource: Keiro.Codec.Codec
  - kind: doc
    resource: docs/user/codecs-and-event-evolution.md
---

# codec

A codec (`Codec e`) owns event identity on disk. An unknown event type tag is fatal during
hydration, and so is a decode failure on the command path, because keiro cannot decide safely
from a partial history. Older payloads reach the current shape through upcasters.
