---
type: Review
title: DSL workflow awakeable signalling conformance
description: The generated helper and its conformance test compare the legacy derivation with itself rather than with the id allocated by the runtime.
generated:
  by: process:codex
  at: "2026-08-14T12:59:14Z"
reviewId: REV-2
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro.Dsl.Harness.emitWorkflowRuntime
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
context: >-
  Read the complete workflow-runtime emitter, its committed generated output,
  and the dedicated conformance executable; compared them with the live
  Keiro.Workflow.Awakeable allocation path and its forged-id regression test.
---

# DSL workflow awakeable signalling conformance

## Release blocker

`emitWorkflowRuntime` generates `awaitAwakeableId wid label =
deterministicAwakeableId workflowName wid label` and tells consumers that this is
the id an await allocates. That statement is false for every fresh awakeable:
the live runtime allocates a random journaled UUID and reserves the deterministic
function for legacy generation-0 adoption.

The dedicated conformance executable does not exercise `awakeableNamed`. It
computes both `signalSide` and `awaitSide` with `deterministicAwakeableId`, so its
headline await-to-signal assertion is a tautology. At the reviewed commit:

```text
await<->signal awakeable id match (real deterministicAwakeableId): True
```

passes at the same time as the runtime's forged-id regression proves that a
fresh awakeable rejects that derived id. The test suite therefore certifies an
integration that cannot complete in production.

Release should remain blocked until generated code carries or publishes the
actual `AwakeableId` returned by `awakeableNamed`, and the conformance target
runs a real allocation plus signal path. A coordinate-derived equality test is
not sufficient evidence.

## Evidence

- `Keiro.Dsl.Harness.emitWorkflowRuntime` emits the false helper and contract.
- Committed `Generated.HospitalCapacity.HospitalTransferReservation.WorkflowRuntime`
  output contains the same helper.
- `keiro-dsl-conformance-workflow-runtime` passed by comparing the helper with
  the same deterministic function on the signal side.
- The focused live-runtime forged-id test passed with the opposite operational
  result: signalling the coordinate-derived id returned `False`.
