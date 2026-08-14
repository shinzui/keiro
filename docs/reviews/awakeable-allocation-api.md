---
type: Review
title: Awakeable allocation and legacy derivation API
description: The runtime correctly allocates opaque journaled ids, but its legacy derivation remains easy to mistake for the allocation contract and first-party consumers do exactly that.
generated:
  by: process:codex
  at: "2026-08-14T12:59:14Z"
reviewId: REV-1
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro.Workflow.Awakeable
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
  - test-coverage
  - documentation
context: >-
  Read the complete module and its focused database tests, then traced every
  first-party use of deterministicAwakeableId outside historical plans. The
  focused forged-id test passed at the reviewed commit.
---

# Awakeable allocation and legacy derivation API

## Release blocker

The runtime contract is internally coherent: a fresh `awakeableNamed` allocation
uses a random UUIDv4, registers it, and journals it under `awkid:<label>`. The
caller must hand the returned `AwakeableId` to the external system. The exported
`deterministicAwakeableId` is only a generation-0 adoption identity for promises
created by older Keiro versions; its Haddock explicitly says new code must not
derive ids with it.

The public surface does not make that distinction hard to misuse. The legacy
helper retains the unqualified name `deterministicAwakeableId` beside the current
authoring primitives, and first-party generated code, documentation, and the
runnable example all treat it as the id a fresh allocation returns. This is not
hypothetical: the runtime test `refuses a forged coordinate-derived id for a
fresh awakeable` passes and proves the derived id is different from the real id
and cannot be signalled.

Release should remain blocked until the 0.12 API makes the legacy-only status
unambiguous and every first-party caller uses the actual id returned by
`awakeableNamed`. Acceptable designs include removing the helper from the
ordinary authoring surface, renaming it to an explicitly legacy/operator name,
or otherwise making it impossible for generated application code to present it
as the current allocation identity. Compatibility adoption inside the runtime
must remain intact.

## Evidence

- `Keiro.Workflow.Awakeable.allocateAwakeableId` falls back to a fresh UUIDv4
  when no generation-0 legacy row exists.
- `Keiro.Workflow.Awakeable.deterministicAwakeableId` computes a UUIDv5 from
  public workflow coordinates and is documented as legacy-only.
- `cabal test keiro-test --test-options='--match "refuses a forged
  coordinate-derived id for a fresh awakeable"'` passed: the real id differed,
  signalling the derived id returned `False`, and only the real id completed the
  workflow.
