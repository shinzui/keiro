---
type: Review
title: Keiro DSL Language 5 stability follow-up
description: Language 5 is now the sole stable authoring contract, Language 4 remains explicit published compatibility, and every exclusive and inherited release surface passes commit-pinned conformance.
generated:
  by: process:codex
  at: "2026-08-14T17:14:24Z"
reviewId: REV-12
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro.Dsl.LanguageVersion.version5
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
  Traced the complete version registry, frontend profiles, parser diagnostics,
  conformance baseline and every Language 5-owned lane; checked published
  Language 4 parse, round-trip, and diagnostic compatibility; reviewed current
  guides, ADR, corpus inventory, and changelogs; ran focused version/profile and
  conformance groups plus the clean fresh-database repository gate.
---

# Keiro DSL Language 5 stability follow-up

## Release verdict

Approved. Language 5 is the only registry entry with both `Stable` and
`PublishedLanguage`; it is also the active authoring and conformance baseline.
Language 4 remains `CompatibilityOnly` and `PublishedLanguage`, preserving its
explicit parser, renderer, fixtures, diagnostics, and compiled predecessor
proofs without presenting it as the moving authoring target.

All Language 5-exclusive surfaces remain covered: typed domain outcomes, mapped
queue payloads, mapped read-model query contracts, projection catalogs and
external reads, separated projection delivery/query freshness, declarative
router selection, and workflow evolution. The inherited workflow runtime now
allocates and signals the opaque id returned by the live API, so the blocker
formerly shared with REV-2 is resolved operationally. Current ADR, guides,
corpus inventory, capability text, and changelogs describe Language 5 as
published stable; historical records retain their original candidate wording.

No correctness, design, or coverage blocker remains in the Language 5 release
contract at the reviewed commit.

## Evidence

- Frontend-profile tests passed nine examples, selecting Language 5 for stable
  and default authoring while retaining explicit Language 4 compatibility.
- The focused conformance group passed 29 examples, including the ownership
  baseline and compiled language-transition proofs.
- Every `keiro-dsl:tests` target passed; the main suite reported 707 examples
  and zero failures.
- Clean corpus regeneration selected 39 of 39 invocations, reported every
  generated artifact unchanged, and passed inventory/currentness policy.
- The complete fresh-database `just verify` gate exited zero at
  `fb4de1e782ee01a18bf6337a89bea5b877de733a`.
