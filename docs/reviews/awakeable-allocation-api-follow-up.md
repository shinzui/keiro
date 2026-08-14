---
type: Review
title: Awakeable allocation API follow-up
description: The authoring API now exposes only opaque journaled allocation, while generation-0 derivation is isolated behind an explicitly named compatibility surface.
generated:
  by: process:codex
  at: "2026-08-14T17:14:24Z"
reviewId: REV-7
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro.Workflow.Awakeable
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
  - documentation
context: >-
  Read the complete authoring, compatibility, schema, and internal identity
  modules; traced every first-party awakeable-id use; ran the complete focused
  awakeable, registration, cancellation-race, allocation, legacy-adoption, and
  continue-as-new test groups; and confirmed the full repository gate on a
  fresh database at the reviewed commit.
---

# Awakeable allocation API follow-up

## Release verdict

Approved. The current authoring surface no longer exports a helper whose name
suggests that a fresh awakeable id can be predicted. `awakeableNamed` allocates
or adopts the row, journals its opaque id, and returns that exact id with the
await action. Its documentation requires callers to publish the returned value
and describes the action-to-journal crash boundary honestly.

Generation-0 reproduction remains available for migration inspection and
tests, but only as `generation0AwakeableId` and
`preUtf8Generation0AwakeableId` in the explicitly named
`Keiro.Workflow.Awakeable.Compatibility` module. The fresh-allocation path uses
the internal identity probes only to adopt existing legacy rows; it does not
offer them as a signalling contract. A forged coordinate-derived id is still
rejected, while existing generation-0 and pre-UTF-8 rows remain adoptable.

No correctness, design, coverage, or documentation blocker remains in this
component for the release candidate.

## Evidence

- `cabal test keiro-test --test-options=--match=awakeable` passed 15 examples,
  including allocation, opaque hand-off, forged-id refusal, legacy adoption,
  registration ordering, cancellation races, and continued generations.
- `Keiro.Workflow.Awakeable` exports `awakeableNamed`, not a coordinate-derived
  id helper, and documents the returned id as the only fresh signalling token.
- `Keiro.Workflow.Awakeable.Compatibility` names both historical probes by
  generation and explicitly says neither predicts a fresh allocation.
- The fresh-database `just verify` gate passed all 611 Keiro examples at
  `fb4de1e782ee01a18bf6337a89bea5b877de733a`.
