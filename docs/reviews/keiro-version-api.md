---
type: Review
title: Keiro umbrella version API
description: The exported version and its passing test report 0.4.0.0 while the reviewed package metadata reports 0.11.0.0.
generated:
  by: process:codex
  at: "2026-08-14T12:59:14Z"
reviewId: REV-5
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro
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
  Read the complete Keiro umbrella module, compared its public version value
  with keiro/keiro.cabal, and ran the focused version test at the reviewed
  commit.
---

# Keiro umbrella version API

## Release blocker

`Keiro.version` is a public value documented for display and telemetry, but it
returns `0.4.0.0` while `keiro/keiro.cabal` identifies the reviewed package as
`0.11.0.0`. The same literal is encoded in the test, so the focused test passes
while preserving the defect. The repository changelog already says this value
must remain in lockstep with the package version.

Publishing another release with a false library identity would make telemetry,
diagnostics, and user-visible version reporting unreliable. Release should
remain blocked until the value is derived from package metadata or otherwise
made mechanically impossible to drift, and the test compares against that
authoritative source rather than another hand-maintained literal.

## Evidence

- `keiro/keiro.cabal`: `version: 0.11.0.0`.
- `Keiro.version`: `"0.4.0.0"`.
- `cabal test keiro-test --test-options='--match "exposes the scaffold
  version"'` passed because the test expects the same stale `"0.4.0.0"` literal.
