---
type: Review
title: Checked mapping legacy retirement
description: Clean checked-mapping adoption passes at the reviewed commit, but no legacy authoring or historical implementation path is yet demonstrably removable.
generated:
  by: process:codex-cli
  at: "2026-09-20T17:24:09Z"
reviewId: REV-18
subject: mori://shinzui/keiro
subjectKind: project
reviewedSha: 37188564b0876ac54f5c5de650db66facf206084
coverage: incremental
baseSha: 4bf274ca5be3585cdd53c470258fa1b0e65b7902
previousReview: REV-17
reviewedAt: "2026-09-20T17:24:09Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-5.6-sol
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - design
  - test-coverage
  - documentation
context: >-
  Reviewed the checked-mapping clean adoption and regeneration proof at the
  exact subject commit, inventoried language dispatch, public compatibility
  wrappers, historical codecs, replay-only behavior, deterministic identity
  probes, process identity families, and workflow stored-result decoding;
  queried Mori's package-grained reverse-dependency registry; and tested the
  repository release manifest's required-reader removal mutation. The review
  distinguishes additive publication evidence from consumer adoption and
  named-path retirement evidence.
---

# Checked mapping legacy retirement

## Verdict

Changes requested for implementation retirement. The additive adoption path is
ready on repository evidence: a clean public check/scaffold run, a second run
over completed consumer bindings, byte-preservation of every create-once file,
generated-tree equality, the compiled process reaction, and the integrated
replay harness all pass at the reviewed commit. Package and Language 6
publication remain separately authorized actions, and this review performs
neither.

No legacy implementation path is yet demonstrably removable. The plausible
authoring candidate, `scaffoldAggregate`, is not obsolete: [Plan
235](../plans/235-retire-or-repair-the-legacy-spec-only-scaffold-entry-points.md)
explicitly retained the spec-only non-planning bridges as supported version-1
compatibility. The published language branches, retained readers, replay-only
edges, workflow result branches, and old identity probes each still implement a
declared compatibility obligation. Removing one merely because this repository
has few direct callers would contradict that contract.

The retirement gate therefore remains pending. No deletion from the main
implementation is approved by this review.

## Reproduced adoption evidence

At `37188564b0876ac54f5c5de650db66facf206084`:

- `nix develop -c just checked-mapping-adoption` passed. It invoked the public
  `check` and `scaffold` commands in an empty directory and over an existing
  scaffold, confirmed creation of the binding skeleton, preserved seven
  create-once domain/binding/behavior files byte-for-byte, compared the complete
  39-module generated tree, and ran the compiled replay harness.
- `nix develop -c cabal test -v0 keiro-dsl:test:keiro-dsl-test
  --test-show-details=direct` passed 790 examples with no failures.
- `nix develop -c just replay-compatibility` passed the three-case Plan 289
  report comparison, ten comparator tests, the four independent checked-mapping
  release results, and seven release-manifest tests.
- The removal-negative test changes the recorded calendar-day reader anchor to
  a nonexistent symbol. The release checker then fails with `retained
  implementation anchor missing`; deleting a required reader or probe cannot
  leave the gate green unnoticed.

The process-reaction rehearsal found and repaired a generation gap during this
review interval: a mapped input type was previously rendered through the
generated nominal module. Service-aware process scaffolding now imports the
consumer mapped type from the checked graph, while the create-once decoder
continues to own interpretation of the source event contract.

## Inventory and disposition

| Path or symbol family | Supported replacement | Why it remains |
|---|---|---|
| `scaffoldAggregate`, `scaffoldStructural`, `validateSpec`, and other spec-only wrappers | The corresponding `*ForService` checked-service entry point | Plan 235 deliberately retained these non-planning bridges as version-1 compatibility. A local caller count cannot reverse that public decision. |
| `languageRegistry`, semantic contracts, parser gates, and generator branches for Languages 1–5 | Language 6 for new candidate authoring | Released inputs and generated baselines remain supported. A newer authoring language does not retire their readers or byte contracts. |
| Calendar-day, text-set, base16, mapped-event, job, snapshot, and upcaster readers | Versioned successor policies where semantics change | Retained events, queued jobs, and snapshots still require their original interpretation. Old writers may retire before readers do. |
| Generated nominal internal legacy constructors and replay-only transducer edges | Safe public constructors for new input; live transitions for new commands | The internal decoder and replay-only edge admit historical IDs/events that current writers do not produce. |
| `deterministicIdProbes`, `legacySeedBytes`, and `legacyDeterministicCommandId` | UTF-8 current identities and target-keyed reaction identities | ADR-24 and ADR-41 require old probes and positional process identities while retained deliveries can reference them. Switching identity families is not a refactor. |
| `decodeStored`, workflow patch branches, step names, generations, and await/index fallback | New stable keys or generations only for new work | Stored-result decode must fail closed. Removing or renaming a branch can rerun an effect or orphan a recorded result. |
| `obsoleteGeneratedOutputHooks` reporting | Current generated-owned output mapping | The reporter is active compatibility diagnostics. Its output may identify old consumer hooks, but the reporter itself is not dead code. |

The exact required-reader anchors are machine checked in the
[`keiro.checked-mapping-release/v1` manifest](../../keiro-dsl/test/fixtures/checked-mapping-replay-workspace/release-manifest.json).
That list is an omission detector, not proof that unlisted history does not
exist.

## Reverse-dependency snapshot

`mori registry dependents shinzui/keiro --packages` was captured on 2026-09-20.
It reported project-level or package-level dependents in
`mori://shinzui/danwa`, `mori://shinzui/kanmon`, `mori://shinzui/kawa`,
`mori://shinzui/keiei`, `mori://shinzui/keiro-runtime-docs`,
`mori://shinzui/keiro-runtime-jitsurei`,
`mori://shinzui/keiro-runtime-kenshou`,
`mori://shinzui/keiro-runtime-patterns`, `mori://shinzui/keiro-syntax`,
`mori://shinzui/kikan`, `mori://shinzui/kioku`, `mori://shinzui/kizashi`,
`mori://shinzui/kotei`, `mori://shinzui/meibo`, `mori://shinzui/mori`,
`mori://shinzui/mori-app`, `mori://shinzui/rei`, and
`mori://shinzui/shikigami`.

The registry is a lower bound, not a universal source-usage index. Project-level
declarations do not identify symbols, package entries may omit dependency
scope, local unregistered consumers are invisible, and historical stored data
can require a reader after source imports disappear. In particular, the Rei
entry establishes three current dependent packages; it does not supply the
authorized immutable retained-history capture required for adoption.

## Why no bounded removal patch exists yet

The review evaluated `scaffoldAggregate` as the smallest apparent candidate
because its only direct in-repository caller is test code and its implementation
delegates to `scaffoldAggregateForService`. The candidate failed the
precondition before an isolated deletion was justified: Plan 235 names that
wrapper family as supported compatibility, and the registry cannot prove
external symbol non-use. Deleting it in a scratch checkout would only prove
that current internal callers can be edited, not that the public contract is
retired.

The remaining candidates fail more strongly because their safety depends on
retained history. This session has no authorized Rei export or isolated restored
source/scratch database pair, so it cannot produce baseline/candidate stream,
process, timer, and workflow continuation observations. Synthetic repository
history cannot substitute for that missing evidence.

To unblock retirement, make a separately reviewed public API decision that
names one authoring wrapper or generator branch as deprecated and its exact
replacement, capture all registry-known source callers, obtain the authorized
consumer-history evidence for any runtime path it reaches, and then remove that
one candidate in an isolated checkout. The same corpus, clean adoption,
baseline/candidate replay, continuation captures, and removal-negative mutation
must remain green before a main-tree deletion is proposed.
