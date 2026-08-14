---
type: Review
title: Jitsurei durable workflow follow-up
description: The runnable workflow now publishes and signals its allocated awakeable id, asserts completion, and proves journal durability across restart with focused regression coverage.
generated:
  by: process:codex
  at: "2026-08-14T17:14:24Z"
reviewId: REV-9
subject: mori://shinzui/keiro
subjectKind: component
component: Jitsurei.DurableWorkflow
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
  - test-coverage
  - documentation
context: >-
  Read the complete durable-workflow module, demo driver, focused database
  regression, and compile-owned guide contract; ran the focused durable test;
  and exercised the complete demo on a freshly migrated database followed by a
  store restart at the reviewed commit.
---

# Jitsurei durable workflow follow-up

## Release verdict

Approved. The example workflow keeps the `AwakeableId` returned by
`awakeableNamed`, journals publication of that id as its own named step, and
hands it to the driver. The driver requires `signalAwakeable` to return `True`,
requires the resumed workflow and child to complete, prints both journals, then
reopens the store and verifies that terminal history survives without
rediscovering unfinished work.

The focused regression covers the critical crash boundary between external id
publication and its step-journal append. Re-invocation republishes the same
journaled allocation without allocating a different promise, the publication
action is idempotent, the exact id signals once, and later passes replay the
journal rather than repeating completed side effects. The example and its
compiled guide contract describe step actions as at-least-once across the
action-to-journal crash window.

No correctness, coverage, or documentation blocker remains in the runnable
durable-workflow proof for the release candidate.

## Evidence

- `cabal test jitsurei-test --test-options=--match=durable` passed the focused
  live-database regression.
- Fresh-database `jitsurei-demo -- all` printed a successful signal, completed
  parent and child journals, `Completed` final outcome, and an empty unfinished
  discovery result after reopening the store.
- The full Jitsurei suite passed 25 examples with zero failures at the reviewed
  SHA.
- First-party searches found no remaining coordinate-derived awakeable helper
  in the example, generated runtime, current guides, or capability page.
