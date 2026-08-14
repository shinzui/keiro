---
type: Review
title: Durable workflow user contract
description: The user guide promises deterministic awakeable ids and at-most-once step effects that the runtime explicitly does not provide.
generated:
  by: process:codex
  at: "2026-08-14T12:59:14Z"
reviewId: REV-4
subject: mori://shinzui/keiro
subjectKind: component
component: docs/user/durable-workflows.md
reviewedSha: 7ddeaabf1850449241aaf0bd114c41a25455de9d
coverage: full
reviewedAt: "2026-08-14T12:59:14Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-5
effort: unspecified
outcome: changes-requested
dimensions:
  - correctness
  - design
  - documentation
context: >-
  Read the complete user-facing durable-workflow reference and compared every
  displayed primitive signature and delivery guarantee with the current public
  Haskell modules. Traced duplicate claims into the linked worked guide.
---

# Durable workflow user contract

## Release blocker

The user reference states that `step name action` runs the action once and that
`awakeableNamed` returns a deterministic id which can be recomputed externally.
Both are unsafe promises contradicted by the runtime:

- A step action is at-least-once across a crash after the action runs but before
  its journal append commits. External effects must use an idempotency key.
- A fresh awakeable id is random, opaque, and journaled. The external system
  must receive the id returned by `awakeableNamed`; coordinate derivation is a
  legacy adoption mechanism and does not target the fresh row.

The displayed signatures also omit the current `IOE :> es` constraint from
`awakeableNamed` and `awaitChild`. The linked worked guide repeats the
at-most-once and deterministic-id claims and presents the broken Jitsurei flow as
the runnable proof.

These are release blockers because a consumer following the documented public
contract can both duplicate irreversible external effects after a crash and
build an externally signalled workflow that suspends forever. Release should
remain blocked until both workflow guides match the live signatures and
at-least-once/opaque-id semantics, with snippets checked against the public API.

## Evidence

- `Keiro.Workflow` explicitly documents the action-to-journal crash window and
  requires idempotent step bodies.
- `Keiro.Workflow.Awakeable` documents journaled UUIDv4 allocation and says new
  code must not hand-derive ids.
- `Keiro.Workflow.Child.awaitChild` and `awakeableNamed` both require `IOE`.
- The live forged-id test and the fresh Jitsurei run demonstrate the practical
  failure of the documented derivation.
