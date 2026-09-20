---
type: Review
title: Checked mapping legacy retirement follow-up
description: Immutable Rei replay and effect-isolated process continuation approve replacing exactly the consumer's obsolete ActionId mapped-opaque declaration while retaining generic opaque support and all historical readers.
generated:
  by: process:codex-cli
  at: "2026-09-20T20:52:19Z"
reviewId: REV-19
subject: mori://shinzui/keiro
subjectKind: project
reviewedSha: ac6b187d8a73d227c323fcd52a0c68a282c088fb
coverage: incremental
baseSha: 37188564b0876ac54f5c5de650db66facf206084
previousReview: REV-18
reviewedAt: "2026-09-20T20:52:19Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-5.6-sol
effort: xhigh
outcome: approved
dimensions:
  - correctness
  - design
  - test-coverage
  - operability
  - documentation
context: >-
  Followed REV-18 with an immutable retained-history rehearsal for
  mori://shinzui/rei. Restored one source archive into separate baseline and
  candidate databases, compiled independent capture binaries, converted the
  five consumer declarations in an isolated checkout, compared selected stream
  reports and retained value inventories, redelivered the applicable process
  manager with outbound effects disabled, recorded the empty workflow
  inventory, and reran consumer conformance plus the required-reader negative
  mutation. No consumer checkout, production data, package, or generic Keiro
  compatibility implementation was changed by this review.
---

# Checked mapping legacy retirement follow-up

## Verdict

Approved for one bounded authoring-path retirement. In an isolated candidate
for `mori://shinzui/rei`, replace exactly
`ActionId mapped opaque rei.disruption.ActionId.json@1` and its 40 obsolete
mapped-surface expectations with the checked nominal declaration
`id ActionId prefix=action domain=typeid-v5-or-v7 using`. Every retained ActionId
is admitted, baseline and candidate stream observations are identical, and the
applicable process continuation is unchanged.

This approval does not reverse REV-18's broader finding. Keiro's generic
mapped-opaque syntax and implementation remain supported. Historical event,
job, snapshot, workflow, process-identity, deterministic-ID, and replay-only
readers remain reachable. The consumer source change and deployment are
separate authorized actions; this review performed neither.

## Immutable consumer evidence

The source archive is bound to revision
`825117f620ba2d474e00b0546960caa7c8d73794` and SHA-256
`4d63da93222516dba418ffbc251a24f738fb5d0e9d0a759a693eaec711c94c9a`.
Identical restores fed a baseline binary with SHA-256
`ae9664e50f066dd6813cf952dad7465d9e3a1de75dc54c03cc28f4a9885ff6a2`
and a candidate binary with SHA-256
`6c777caed8953d28783da4c22d72e82810f3d9aaf58f5c9a07ee4e4eb55e15a0`.
The isolated consumer patch has SHA-256
`38a8ec9e1227e55bf2ef7ebe94cf6b668ae6f6d2b7027a70506e9eb816f4be2f`.

Both captures observed 10,318 stored streams, selected 10,061, excluded 257
outside the registered categories, and applied the same 13 declared
`journal_entry` exclusions covering 89 events. Their raw JSON reports have the
same SHA-256,
`863d98c9624e9ecca5226de6de57f4c801189cc5018f3a1908158cb1d4e72a8c`,
with zero unexpected failures. No private payload is committed to this
repository.

The retained-value inventory covered every adopted declaration:

- 3,958 ActionIds: 1,594 UUIDv5 and 2,364 UUIDv7 values;
- 1,214 base16 hashes and 3,521 calendar days, with no rejected retained
  spelling;
- 666 text sets, including 12 accepted non-canonical order or duplicate cases;
- 67 `TaskCompleted.actor` optional values: 28 omitted keys and 39 explicit
  nulls.

The last item exposed a real compatibility defect at the reviewed Keiro
increment. A direct mapped event field whose checked root is `Optional` had
become key-strict, unlike its old Aeson `Maybe` reader. Commit
`ac6b187d8a73d227c323fcd52a0c68a282c088fb` restores omitted-key-as-null
decoding only for that root shape and adds the 791st DSL regression example;
non-optional mapped event fields remain strict.

## Continuation evidence

Rei has no retained workflow history in this archive: zero registered
workflows, instances, steps, and children. The result is therefore the explicit
successful verdict `not-applicable-empty-history`, not a claim that a workflow
ran and not missing evidence.

Process history is applicable. In the candidate scratch database, the
`rei-note-task-propagation` subscription was deliberately rewound from
checkpoint 33237 to 28879. A process-only harness—zero async projections, one
TaskPropagation process manager, zero timer workers, and outbound effects
disabled—restored the checkpoint to 33237. Before and after, the database held
33,717 events, 67,434 stream links, 506 TaskPropagation streams with 2,323
versions, 53 target task streams with 281 versions, 3,917 timers, and zero dead
letters. The event, link, and timer digests were unchanged. The temporary
process harness binary has SHA-256
`073c6c6ae14a9b291bded7798ba77729a87294523a2d8674ab7a9e53a83b85bb`;
its process-only source changes were removed before hashing the candidate
consumer patch.

## Bounded disposition

The isolated candidate converts all five example declarations and its
`keiro-rei-conformance` suite passes. For retirement, only the ActionId
authoring path qualifies: the checked v5-or-v7 nominal contract replaces the
consumer's opaque declaration, its old-history and process evidence pass, and
the 40 expectations tied specifically to that mapped-opaque surface become
obsolete.

The required-reader negative mutation remains mandatory and passes by making
the release gate fail when a retained implementation anchor is removed. This
prevents the bounded consumer authoring consolidation from being generalized
into deletion of a needed historical implementation. Any later proposal to
remove generic mapped-opaque support or a runtime compatibility path requires a
new named review and its own complete dependent and retained-history evidence.
