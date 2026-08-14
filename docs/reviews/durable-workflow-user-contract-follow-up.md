---
type: Review
title: Durable workflow user contract follow-up
description: The user reference and worked guide now match the live effect constraints, opaque awakeable hand-off, and at-least-once step crash semantics.
generated:
  by: process:codex
  at: "2026-08-14T17:14:24Z"
reviewId: REV-10
subject: mori://shinzui/keiro
subjectKind: component
component: docs/user/durable-workflows.md
reviewedSha: fb4de1e782ee01a18bf6337a89bea5b877de733a
coverage: full
reviewedAt: "2026-08-14T17:14:24Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-5
effort: unspecified
outcome: approved
dimensions:
  - correctness
  - design
  - documentation
context: >-
  Read the complete user reference and worked guide, compared every displayed
  workflow primitive and runner signature with the public Haskell modules,
  traced their runnable Jitsurei example, checked the capability summary, and
  ran the compile-owned guide contract and repository documentation gates.
---

# Durable workflow user contract follow-up

## Release verdict

Approved. Both current workflow documents now state that a step action may run
again after a crash between the action and journal commit, so externally visible
effects require a stable idempotency key. They describe a fresh awakeable id as
opaque and journaled, require the workflow to publish the exact value returned
by `awakeableNamed`, and reserve generation-derived identities for historical
compatibility only.

The displayed constraints agree with the public API: awakeable and child waits
carry `IOE`, workflow runners carry `Error StoreError`, and the worked sequence
allocates, publishes, awaits, spawns with an explicit workflow identity, and
awaits the child. The linked Jitsurei path now actually reaches completion and
survives restart. The shorter durable-execution capability sketch uses the same
current call shapes.

No correctness, design, or documentation blocker remains in the durable
workflow user contract for the release candidate.

## Evidence

- The user reference and worked guide both document at-least-once step actions,
  idempotency, opaque awakeable ids, one successful signal transition, and
  terminal restart verification.
- The worked guide's `runWorkflowWith` signature includes `IOE`, `Store`, and
  `Error StoreError`; its `awakeableNamed` and `awaitChild` snippets include
  `IOE`.
- The compile-owned `WorkflowGuideContract` builds against the public API and
  the focused Jitsurei durability regression passes.
- Capability, ADR, generated-name, review, and current-document acceptance
  checks all passed in `just verify` at the reviewed SHA.
