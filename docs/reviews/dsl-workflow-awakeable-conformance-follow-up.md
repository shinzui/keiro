---
type: Review
title: DSL workflow awakeable signalling follow-up
description: Generated workflow support now returns the live allocation id, and its PostgreSQL conformance lane proves that signalling that exact id resumes with the delivered payload.
generated:
  by: process:codex
  at: "2026-08-14T17:14:24Z"
reviewId: REV-8
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro.Dsl.Harness.emitWorkflowRuntime
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
  - test-coverage
context: >-
  Read the complete workflow-runtime emitter, the committed generated runtime,
  the live PostgreSQL conformance executable, its fixture and generator tests;
  ran the workflow operation test group and runtime lane; and confirmed every
  DSL suite in the fresh-database repository gate at the reviewed commit.
---

# DSL workflow awakeable signalling follow-up

## Release verdict

Approved. `emitWorkflowRuntime` no longer derives or predicts an awakeable id.
It emits an opaque `AwaitBinding` plus `allocateDeclaredAwait`, which delegates
to `awakeableNamed` and returns `(AwakeableId, Eff es a)`. Generated application
code must therefore carry or publish the exact id allocated by the live
runtime.

The dedicated conformance executable is now operational rather than
tautological. Its first run allocates through the generated wrapper, records the
returned id outside the workflow, and suspends. It signals that exact id through
PostgreSQL, requires the row transition to succeed, runs the same workflow
again, and requires `Completed "confirmed"`. The generated source, committed
conformance artifact, fixture, and generator assertions agree on this contract.

No correctness, design, or coverage blocker remains in the generated workflow
awakeable integration for the release candidate.

## Evidence

- The live workflow-runtime lane passed all four assertions: opaque allocation,
  suspended first run, successful signal transition, and resumed payload.
- `cabal test keiro-dsl-test --test-options=--match=workflow/operation` passed
  14 examples covering generation and the workflow/operation surface.
- The generated module imports only `AwakeableId` and `awakeableNamed`; it has
  no dependency on the compatibility derivation probes.
- The complete `cabal test keiro-dsl:tests` repository gate passed every
  compiled conformance target and the 707-example main suite at the reviewed
  SHA.
