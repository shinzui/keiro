---
type: Review
title: Keiro umbrella version API follow-up
description: The public version now renders Cabal-generated package metadata, and tests compare it with the same authoritative package version without a duplicate literal.
generated:
  by: process:codex
  at: "2026-08-14T17:14:24Z"
reviewId: REV-11
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro
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
  Read the complete umbrella module and package metadata, searched all current
  version authorities and public uses, inspected both version regressions, ran
  the focused metadata test group, and confirmed the full Keiro suite at the
  reviewed commit.
---

# Keiro umbrella version API follow-up

## Release verdict

Approved. `Keiro.version` is derived by rendering `Paths_keiro.version`, which
Cabal generates from the package's `version` field. There is no independent
library literal to drift. The public text value, package metadata, provenance
banner consumers, and compile-time safety probe therefore select the same
version authority.

The focused regressions verify both the rendered public value and the absence
of a hand-maintained version literal in the umbrella module. The nested GHC
type-error probe also selects `keiro-<Paths_keiro.version>` explicitly, so a
second locally installed Keiro version cannot make the test observe an
ambiguous package.

No correctness, design, or coverage blocker remains in the umbrella version
API for the release candidate.

## Evidence

- `cabal test keiro-test --test-options=--match=metadata` passed seven focused
  examples, including the two Keiro version-authority regressions.
- `Keiro.version` renders Cabal's generated `Paths_keiro.version`; current
  searches found no duplicate public version literal.
- The complete Keiro suite passed 611 examples with zero failures in the
  fresh-database repository gate.
- The compile-time `ValidatedEventStream` refusal remained green in a package
  environment containing more than one installed Keiro version.
