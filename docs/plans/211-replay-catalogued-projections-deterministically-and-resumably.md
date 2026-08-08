---
id: 211
slug: replay-catalogued-projections-deterministically-and-resumably
title: "Replay catalogued projections deterministically and resumably"
kind: exec-plan
created_at: 2026-08-07T23:36:52Z
intention: "intention_01kzf95908e14b29bxjb4yhfe0"
master_plan: "docs/masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md"
---

# Replay catalogued projections deterministically and resumably

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, an operator can rebuild any validated projection group from Kiroku history to
an immutable captured head, including inline and async projections and groups fed by several
categories. Events are applied in global-position order through explicit replay adapters, in
bounded transactions that atomically persist target writes and replay progress. A crashed run
resumes from the last committed cursor only when its full catalog/source fingerprint still
matches.

Promotion no longer infers completeness from the presence of a dedup row. It requires every
declared source to be exhausted through the captured head, every required adapter to have
participated, and application verification to succeed. Tests make this visible for empty relevant
history, interleaved categories, decode failure, crash/resume, a changed catalog, an omitted
adapter, and early promotion.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Persist rebuild-run fingerprints, captured source heads, source/adapter progress, failures,
      and verification evidence in a new Keiro migration.
- [ ] Implement fixed-head paged `$all` and category scanning with deterministic global-position
      merge and total decode/relevance outcomes.
- [ ] Apply bounded pages with target writes and progress in one transaction; resume only an exact
      run contract and record structured failures.
- [ ] Prove source and adapter completion, run application verification, issue the opaque group
      completion token, document telemetry, and pass all replay/concurrency tests.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-08: Kiroku's internal publisher already reads the `$all` head cheaply through
  `currentGlobalPositionStmt`, but the public Store effect has no equivalent and its fan-in pages
  have no inclusive upper bound. The dependency-side request is
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1`. This plan keeps a released-API
  compatibility reader so the request remains an optional simplification, not a gate.


## Decision Log

Record every decision made while working on the plan.

- Decision: Normalize replay into either one `$all` scan or a k-way merge of distinct category
  scans, all bounded by one captured global head.
  Rationale: Kiroku guarantees `readAllForward` and `readCategory` are ordered by global position.
  Distinct categories cannot select the same source event. Combining `$all` with categories is
  redundant and is rejected by catalog validation, so the runner never has ambiguous duplicates.
  Date: 2026-08-07

- Decision: Record the captured global head as the immutable target for every source and prove
  category exhaustion even when a category has no event at that exact position.
  Rationale: A category cursor naturally stops at its last matching event, not at the global head.
  An empty page or first event beyond the captured head proves that source had no more matching
  event in the fixed range; the durable exhausted-through field records that proof.
  Date: 2026-08-07

- Decision: Commit application writes and replay progress in one transaction per bounded chunk.
  Rationale: On crash, replay may repeat only an uncommitted chunk. A committed cursor never gets
  ahead of its materialization, so resume does not require dedup presence as a completion proxy.
  Date: 2026-08-07

- Decision: Count adapter evaluation separately from successful applies.
  Rationale: An adapter may correctly classify every event as irrelevant and apply zero writes.
  Completion needs proof that the adapter participated in all of its declared sources, not a
  fabricated apply or dedup row.
  Date: 2026-08-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan hard-depends on [plan 209](209-define-and-validate-the-typed-projection-catalog-runtime-contract.md)
for replay adapters, sources, target/group declarations, and fingerprints, and on
[plan 210](210-coordinate-projection-target-groups-fencing-and-rebuild-policies.md) for atomic
preparation, the live-writer fence, group handles, and atomic promotion. The runner must not
invent alternative projection lists or bypass the plan-210 state machine.

`keiro/src/Keiro/ReadModel/Rebuild.hs` currently resets a one-table read model and accepts a
caller-supplied projection-name list; it does not scan Kiroku history, persist a fixed replay
range, or resume. [Plan 162](162-rebuild-inline-projections-deterministically-from-event-history.md)
specified a fixed target, inline fence, explicit relevance decoder, bounded progress, and resume,
but was never implemented. This plan supersedes and generalizes it to catalogued groups and both
execution modes.

Kiroku's registered source was located with Mori at implementation-planning time. Within
`mori://shinzui/kiroku/packages/kiroku-store`,
`kiroku-store/src/Kiroku/Store/Read.hs` defines `readAllForward` and `readCategory` with an
exclusive `GlobalPosition` cursor and ascending `RecordedEvent` vectors; `readAllBackward` can
read the current final global event. `readCategory` filters by the source stream's category and
retains the source event's global position. The current released API has a streaming helper only
for an individual named stream, so this plan pages the all/category reads explicitly. Re-run Mori
discovery and verify the released Kiroku version before implementation because the local corpus
may lag upstream. Kiroku request
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1` proposes a public cheap head and
bounded fan-in page primitives. Treat it as a soft dependency: adopt it only from a verified
release, behind the same internal replay-history interface used by the current compatibility loop.

A **captured head** is the greatest global position visible immediately after plan 210 fences and
prepares the group; zero represents an empty store. A source range is exclusive-start and
inclusive-target. A category can be complete at global target 100 even if its last matching event
is 71; `exhaustedThrough = 100` records that a subsequent bounded read found no category event at
or below 100. A **participation row** records that a particular adapter evaluated all events from
one of its sources through the target. It is different from an apply count.

[ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) governs the
Keiro-owned progress migration. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires the stored catalog fingerprint to guard runtime assembly rather than substitute for DSL
diff. The projection-catalog ADR created by plan 209 and amended by plan 210 is normative; this
plan adds fixed-head and completion semantics to it. The cross-repository preserve constraint is
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`.


## Plan of Work

### Milestone 1: Persist the immutable replay contract

Extend `Keiro.ReadModel.Rebuild` with a subordinate internal progress module if needed for
readability. Add a new forward-only Keiro migration; do not edit plan 210's released migration.
Persist one rebuild-run row with run ID, group ID, catalog fingerprint, source/projection/target
fingerprint, captured global head, page-size configuration, status, timestamps, and structured
failure/verification evidence. Persist one source-progress row per normalized source and one
adapter-participation row per required adapter/source pair. Keys and foreign keys must make an
omitted or unexpected source/adapter detectable.

Capture the head only after `beginGroupRebuild` has fenced live application. Against the released
API, use Kiroku's `readAllBackward (GlobalPosition 0) 1`; an empty result captures zero. If a
released implementation of Kiroku IR-1 is available, use its cheap public head operation through
the same internal reader interface. Store the same immutable global target with each normalized
source row. The starting cursor is zero for a fresh rebuild or the exact persisted cursor for a
resume. Never extend the range when new events arrive.

Serialize all source descriptors, codec/event versions, adapter identities and order, replay
policy, query/group/target identities, reset policy, schema/version/shape facts, and runner format
version into the fingerprint. Exclude page size if changing it cannot affect semantics; include
every configuration knob that can. A resume reconstructs the plan from the current validated
catalog and refuses any mismatch before applying a handler.

Milestone 1 passes when migration tests verify constraints and a restart test accepts an identical
catalog but rejects a changed source, adapter order, group, target, reset/replay policy, model
version, shape hash, or runner format.

### Milestone 2: Produce one ordered bounded event stream

Implement a pure scan planner plus an effectful paged reader. Normalize repeated uses of the same
source so it is read once and routed to all declared adapters. Permit either exactly one `$all`
source or one or more distinct category sources. Reject `$all` combined with category sources in
plan-209 validation because the selections overlap and the categories add no events.

Define one internal replay-history reader whose page contract is exclusive-lower,
inclusive-target, globally ordered, and explicitly exhausted-through. Its released-Kiroku
implementation repeatedly calls `readAllForward cursor pageSize` for `$all` or `readCategory
category cursor pageSize` for a category. Both cursors are exclusive. Discard or retain as a
lookahead the first event whose global position exceeds the captured head; never apply it. A short
or empty page with no event at or below the head proves the source exhausted through the target.
When a released Kiroku IR-1 API exists, replace this adapter with the SQL-bounded page operations;
do not keep both algorithms as independent public paths.

For several category sources, keep a bounded page buffer and cursor per category and perform a
k-way merge by `RecordedEvent.globalPosition`. Global positions are unique in Kiroku, so ties are
an invariant violation with a structured failure. Do not concatenate categories or process one
category completely before the next. Produce chunks in global order while advancing a source
cursor for irrelevant as well as relevant events. Tests interleave events from three categories
and assert exact positions; another test appends new events after head capture and proves none are
included.

Each adapter supplies a total result for each selected event: irrelevant, relevant with a decoded
value, or decode failure. A malformed event that claims a supported type is a failure, not
irrelevant. Adapters for one event execute in the explicit catalog order. A live-only adapter is
not present in the replay plan; plan-209 validation has already rejected it if a clear target needs
its historical writes.

### Milestone 3: Apply chunks transactionally and resume

For each ordered chunk, open one target-database transaction under a narrowly scoped replay
authorization tied to the active `RebuildRunId`. Recheck the group state and run fingerprint,
execute replay adapters, record per-adapter evaluation/apply counters, advance every consumed
source cursor, and commit progress in the same transaction as all application target writes. The
authorization bypasses the live fence only for that group/run and has no public constructor.

If decode or handler application fails, roll back the entire chunk, record the failure in a
separate failure transaction, keep the group fenced, and return a typed failed result. On process
death before commit, neither target writes nor cursors survive. On death after commit, both do.
Resume reads the durable cursors and may choose a different non-semantic page size, but must match
the immutable fingerprint. Existing async dedup may still provide idempotency evidence; it is not
the source of the replay cursor or completion result.

Add fault injection immediately before page commit and immediately after commit. Verify that
resume produces exactly the uninterrupted materialization and counters, including a page with
only irrelevant events. Use a page size small enough to force category buffers and group progress
across several commits.

### Milestone 4: Verify completeness and promote

When every source reader has proved exhaustion through its captured target, transactionally mark
each source complete and close all adapter/source participation rows. Assert the required set
equals the set derived from the persisted run contract; counts may be zero, but no row may be
missing or incomplete. Do not query arbitrary dedup-row existence to fill a missing row.

Run catalog-supplied, application-owned verification hooks after replay and before promotion.
Hooks may query the rebuilt models and return structured pass/fail evidence, but they may not
silently change targets. If mutating reconciliation verification is required, it must be an
explicit replay adapter and complete before this phase. Persist the hook identity/version and
result.

Only the completion verifier can construct plan 210's opaque `GroupCompletionToken`. It locks the
run, rechecks group/run/fingerprint, source exhaustion, adapter participation, and verification,
then passes the token to atomic group promotion. Any missing adapter, early source, failed hook, or
failed run keeps the group fenced.

Add structured log/tracing events and counters for run start/resume/fail/promote, captured head,
source cursor/target, page latency and event count, adapter evaluations/applies, and verification.
Avoid raw event payloads and secrets. Amend the catalog ADR, update the rebuild runbook and API
reference, mark plan 162 superseded, and run the full suite.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Refresh dependency evidence before coding:

```console
mori registry search kiroku
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori improvement-requests show --project shinzui/kiroku --id IR-1 --json
```

Use the qualified name returned by search if it differs. Read the current registered
`Kiroku.Store.Read` and `RecordedEvent` definitions on disk, then verify the current Kiroku release
against Hackage and upstream tags before changing bounds or adopting a newer helper. Do not search
`/nix/store`.

After each milestone:

```console
nix fmt
cabal test keiro-migrations-test
cabal test keiro-test
```

Expected successful tail:

```text
Test suite keiro-migrations-test: PASS
Test suite keiro-test: PASS
```

Validate the amended ADR and all repository gates:

```console
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

During implementation, record the migration identifier, default page size, canonical fingerprint
format version, and actual fault-injection points in this plan. If a Kiroku API gap requires a
dependency change, document the verified release and its canonical Mori project reference before
editing bounds.


## Validation and Acceptance

Acceptance is demonstrated by end-to-end PostgreSQL tests:

1. Append events in alternating global order to categories `orders`, `customers`, and `billing`.
   Rebuild a group fed by all three with a page size of two. Handlers observe strictly increasing
   global positions identical to an `$all` reference read, not three concatenated category runs.
2. Capture head H, append matching events at positions greater than H, and rebuild. The result and
   progress include only positions at or below H. A source whose last matching event is below H is
   marked `exhaustedThrough = H` only after the reader proves no further bounded match.
3. Run a catalog whose sources contain no relevant event. Every adapter is evaluated across its
   source, apply counts remain zero, source and participation rows complete, verification passes,
   and promotion succeeds.
4. Inject a supported event with malformed payload. The chunk rolls back target writes and cursor,
   a decode failure names run/source/adapter/event position without logging payload, and the group
   remains fenced. An unrelated event is classified irrelevant and advances progress.
5. Kill the runner immediately before a chunk commit and resume; the chunk replays once. Kill it
   immediately after commit and resume; committed positions are not reapplied. Both final
   materializations and ordered position traces equal an uninterrupted run.
6. Change each fingerprinted component in isolation. Resume refuses the changed catalog before
   handler execution and retains the old failed/incomplete evidence.
7. Delete or leave incomplete one required adapter/source participation row, stop one source
   early, insert an arbitrary dedup row, or fail application verification. Promotion rejects every
   case. The exact complete row set plus successful verification produces the only valid
   completion token and promotes the whole group.
8. Rebuild a preserve-and-reconcile brownfield target. Recorded updates are applied, but roots
   absent from event history remain. This test does not pretend to police a deliberately
   destructive application handler; the documented arbitrary-SQL boundary remains explicit.
9. Migration, focused runtime, strict ADR, and `just verify` commands all pass.


## Idempotence and Recovery

Fresh start, resume, abandon, and start-over are distinct operations. Resume is idempotent for the
same active run and fingerprint: it continues after the last transactionally committed source
cursors. Page reads and pre-commit handler execution may repeat after a crash, but committed
application changes and progress never diverge. The runner must document that replay handlers are
transactional and must not perform external side effects; live behavior that does so needs a safe
replay-specific adapter.

A decode, SQL, or verification failure records evidence and leaves the group fenced. Correct code
or data, then resume the same fingerprint if the failure is transient and no semantic declaration
changed. If a declaration changed, explicitly abandon and start a fresh run so new targets are
prepared under the new fingerprint. Start-over may destructively clear `ClearBeforeReplay`
targets again, so dry-run and explicit operator confirmation belong to plan 213. Preserved targets
are never truncated by recovery.

Migrations are forward-only and repeatable through pg-migrate. Add a later migration to correct a
released schema error. Never forge progress rows, delete a fingerprint, or mark source exhaustion
manually to force promotion.


## Interfaces and Dependencies

`Keiro.Projection.Catalog` supplies `ValidatedProjectionCatalog`, replay sources/adapters, and the
canonical fingerprint. `Keiro.ReadModel.Rebuild` owns the public runner; internal modules may own
scan merging and persistence. The semantic interface is:

```haskell
data RebuildRunId
data RebuildRun
data RebuildRunStatus = Running | Failed | Verified | Promoted | Abandoned
data ReplayResult = ReplayIrrelevant | ReplayApplied | ReplayDecodeFailed DecodeFailure
data RebuildVerification

startCatalogRebuild
  :: ValidatedProjectionCatalog
  -> RebuildGroupId
  -> RebuildOptions
  -> Eff es (Either RebuildError RebuildRun)

resumeCatalogRebuild
  :: ValidatedProjectionCatalog
  -> RebuildRunId
  -> RebuildOptions
  -> Eff es (Either RebuildError RebuildRun)

inspectCatalogRebuild
  :: RebuildRunId
  -> Eff es RebuildRunReport
```

`RebuildOptions` contains operational choices such as page size and dry telemetry controls, not
projection/target/source lists. `startCatalogRebuild` calls plan 210's preparation, captures the
head, persists the contract, runs pages, verifies, and promotes; internal phases remain separately
testable.

Use Kiroku's released `readAllForward`, `readAllBackward`, and `readCategory` APIs after Mori and
release verification. Isolate them behind the internal bounded reader described above. If
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1` is implemented and released before
this plan lands, substitute its head/range primitives and record the verified version; do not
raise the lower bound merely for an unreleased API. Use Hasql transactions for application writes
plus progress, existing Keiro migration infrastructure for progress tables, and the repository's
telemetry conventions. Do not add an event-store snapshot, unbounded in-memory sort, external
queue, or second replay adapter registry.
