---
type: Review
title: Keiro DSL Language 5 stability gate
description: The Language 5-exclusive surfaces passed the final adversarial review, but the inherited workflow generator still certifies an awakeable id that the live runtime rejects.
generated:
  by: process:codex
  at: "2026-08-14T13:21:03Z"
reviewId: REV-6
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro.Dsl.LanguageVersion.version5
reviewedSha: 7ddeaabf1850449241aaf0bd114c41a25455de9d
coverage: full
reviewedAt: "2026-08-14T13:21:03Z"
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
  Traced every Language 5 feature through its version gate, public AST,
  canonical rendering, semantic validation, evolution classification, and
  generated/runtime boundary; checked predecessor compatibility; ran the
  706-example core suite, all five Language 5 compiled conformance targets,
  adversarial generated-name collision probes, and the conflicting workflow
  DSL/runtime awakeable tests at the reviewed commit.
---

# Keiro DSL Language 5 stability gate

## Release verdict

Changes requested. No new release blocker was found in the Language 5-exclusive
surfaces: typed domain outcomes, mapped workqueue payloads, mapped read-model
query contracts, projection catalogs and external reads, separated projection
delivery/query freshness, and declarative router selection all passed their
parser, validator, canonical-rendering, diff, generation, and compiled
conformance checks.

Language 5 still must not be marked stable because it inherits the workflow and
operation surface from its predecessors. The release blocker recorded in
[REV-2](dsl-workflow-awakeable-conformance.md) remains reproducible at this exact
SHA: generated workflow code presents `deterministicAwakeableId` as the id of a
fresh await, and its dedicated conformance test proves only that the same legacy
derivation equals itself. The live runtime test simultaneously proves that a
fresh allocation uses another id and refuses the derived one. A stable Language
5 contract would therefore certify generated signalling code that can leave a
workflow suspended forever.

Release should remain blocked until REV-2 is resolved by carrying or publishing
the actual `AwakeableId` returned by `awakeableNamed`, and the DSL conformance
target exercises a real allocation and successful signal rather than a
coordinate-derived equality. The Language 5 registry promotion can be reviewed
again after that regression is green.

## Evidence

- `cabal test keiro-dsl-test` passed 706 examples, including the complete
  Language 5 parser, validation, round-trip, compatibility, and diff groups.
- The domain-outcome, mapped-queue, mapped-readmodel, projection-catalog, and
  declarative-router compiled conformance targets all passed.
- An adversarial catalog-name concatenation collision was rejected by `check`
  as `GeneratedPlanningInvariantViolation` before any scaffold write.
- `keiro-dsl-conformance-workflow-runtime` passed while printing
  `await<->signal awakeable id match (real deterministicAwakeableId): True`.
- The focused live runtime test `refuses a forged coordinate-derived id for a
  fresh awakeable` also passed, proving that the generated derived id is not the
  fresh allocation id and cannot signal it.
