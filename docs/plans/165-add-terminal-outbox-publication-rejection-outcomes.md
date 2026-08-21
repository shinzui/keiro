---
id: 165
slug: add-terminal-outbox-publication-rejection-outcomes
title: "Add terminal outbox publication rejection outcomes"
kind: exec-plan
created_at: 2026-07-31T14:46:36Z
intention: intention_01kzq9d8cnejpvws5pnk6nx39b
---

# Add terminal outbox publication rejection outcomes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, an outbox transport can report that a message was intentionally and permanently
refused—such as an invalid destination, authorization denial, or unsupported sink—without lying
that delivery succeeded and without sending the row through transient retries. Keiro records a
distinct terminal `rejected` status with bounded classification/reason, releases ordered successors,
emits rejection-specific telemetry, and exposes the result in summaries and operator queries.

The behavior is visible by claiming a row, returning `PublishRejected`, and observing exactly one
durable terminal transition, zero retry scheduling, a `rejected` row with audit fields, one increment
of the rejection counter in the successful pass, and a later same-key row becoming eligible. The
transport callback remains at-least-once across a crash before the database transaction commits;
the new outcome does not claim impossible exactly-once delivery across PostgreSQL and an external
transport.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-21T15:04:22Z) Milestone 1: added the opaque public `PublishRejection`, validation
  errors/smart constructor/accessors, the `PublishRejected` outcome, and boundary coverage. The
  focused test passed with 1 example and 0 failures; existing success and transient-failure code
  remains unchanged for the storage/worker integration milestones.
- [x] (2026-08-21T15:12:00Z) Milestone 2: generated native migration `0031.sql`, added the
  constrained rejection audit columns and terminal index predicates, decoded `OutboxRejected` into
  typed rows, and added the conditional `markOutboxRejectedTx`. The migration check covered all 31
  checksums, and the focused fresh-database test passed with 1 example and 0 failures.
- [ ] Milestone 3: integrate rejection with batching, ordering policies, summaries, telemetry,
  maintenance, and operator inspection.
- [ ] Milestone 4: add crash/recovery and compatibility coverage, migrations, documentation,
  changelog/release notes, and full validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-31: `PublishOutcome` currently has only `PublishSucceeded` and `PublishFailed Text`.
  Transient failure flows through attempt/backoff and eventually `dead`; success marks `sent`.
  Neither represents an intentional terminal refusal truthfully.
- 2026-07-31: IR-3 already requests this capability and records that it blocks
  `mori://shinzui/shikigami/plans/19-sink-delivery-truth-and-downstream-idempotency`. At first
  authoring, no earlier ExecPlan implemented IR-3, and MasterPlan 3's four completed children
  predated the request.
- 2026-07-31: Existing publisher logic treats failure as an ordering barrier. A terminal rejection
  must define whether it releases or blocks successors instead of accidentally inheriting retry
  behavior.
- 2026-08-10: Hackage and the upstream `keiro-0.11.0.0` tag both identify 0.11.0.0 as the latest
  released Keiro cohort, and the current source still exposes only `PublishSucceeded` and
  `PublishFailed Text`. The request's problem therefore remains live even though its 0.4.0.1
  baseline is historical.
- 2026-08-10: The originating Shikigami checkout still constrains `keiro`, `keiro-core`,
  `keiro-migrations`, and `keiro-pgmq` to exactly 0.4.0.1 in `cabal.project`. Adding constructors to
  `PublishOutcome`, `OutboxStatus`, `OutboxRow`, and `OutboxPublishSummary` is PVP-major; Keiro must
  release the next shared major cohort and Shikigami must deliberately upgrade rather than expecting
  a source-compatible 0.4 backport.
- 2026-08-10: IR-3 already names this plan as its implementation record. Reusing and refreshing Plan
  165 preserves the canonical relationship and avoids two living plans claiming the same request.
- 2026-08-10: The migration system is now the native pg-migrate component. A new migration requires
  an immutable SQL file, a manifest append, a `migrations.native.lock` checksum, and a regenerated
  PostgreSQL 18 text snapshot. The timestamped Codd files, legacy `migrations.lock`, and legacy
  expected-schema directory are frozen cutover evidence and must not be changed.
- 2026-08-10: [ADR 25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md)
  requires summaries to count completed work rather than attempted work. The rejected count must
  therefore come from conditional database updates that actually committed, not merely from
  outcomes reported by the callback.
- 2026-08-21: The working tree has advanced from the plan's 0.11.0.0/23-migration baseline to a
  0.13.0.0 package cohort whose native manifest ends at migration 30. The provisional next major
  cohort is therefore 0.14.0.0 and the next generated migration should be 31; both remain subject
  to the release and migration tools rather than being allocated by hand.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add `PublishRejected PublishRejection` and a distinct durable `OutboxRejected` status;
  do not encode rejection as `PublishFailed`, `OutboxDead`, or success.
  Rationale: Dead means retry exhaustion and sent means transport acknowledgement. Audit, metrics,
  and downstream state machines need the terminal cause to remain truthful.
  Date: 2026-07-31

- Decision: `PublishRejection` contains a validated stable code plus a bounded human detail; both
  are stored, while the initial rejection counter is unlabelled and never includes detail.
  Rationale: Free-form errors are useful for audit but dangerous as metric labels and can grow
  without limit. A stable code supports policy and dashboards without requiring this change to add
  a cardinality-bearing metric dimension.
  Date: 2026-07-31

- Decision: Rejection finalizes the row immediately, consumes no further retry budget, and releases
  later ordered rows. `StopTheLine` halts only on transient `PublishFailed`, not on an explicitly
  handled terminal rejection.
  Rationale: A permanent refusal cannot be repaired by retry and is no longer pending work. Keeping
  it at the head would turn a terminal disposition into a permanent queue outage.
  Date: 2026-07-31

- Decision: Guarantee idempotent durable finalization, not impossible transport exactly-once across
  a crash between an external call and the database transaction.
  Rationale: The publisher callback and PostgreSQL status update are not one atomic resource. Keiro
  can ensure a rejected row is never claimed again after commit and repeated finalization is a
  no-op, while transports must keep rejection handling idempotent across the pre-commit crash window.
  Date: 2026-07-31

- Decision: Keep this IR-3 implementation as a standalone ExecPlan rather than reopening the
  completed inbox/outbox MasterPlan.
  Rationale: Terminal rejection is a focused follow-on requested after the subsystem shipped and
  needs its own truthful implementation state.
  Date: 2026-07-31

- Decision: Accept IR-3 and update the public API with a third `PublishRejected` outcome.
  Rationale: The current two-way result forces a permanent refusal to be represented either as a
  delivery acknowledgement or as retryable failure. Both choices are observably false, and the
  downstream use case exists in
  `mori://shinzui/shikigami/plans/19-sink-delivery-truth-and-downstream-idempotency`.
  Date: 2026-08-10

- Decision: Keep `PublishRejection` and its code opaque and construct it through validation. A code
  is 1–64 lowercase ASCII characters matching `[a-z][a-z0-9._-]*`; optional detail is non-empty and
  at most 1024 UTF-8 bytes. Invalid input is rejected, never truncated or normalized silently.
  Rationale: The code is stable audit and policy data and can safely become a bounded telemetry
  dimension later. The detail remains useful operator context without allowing unbounded storage or
  log/metric cardinality.
  Date: 2026-08-10

- Decision: Keep `rejected` distinct from `dead`, and retain rejected rows for audit.
  Rationale: `dead` means retry exhaustion or stale-publisher exhaustion; `rejected` means a
  publisher deliberately made a successful terminal decision on the current attempt. Reusing
  `dead` would preserve the ambiguity the request is meant to remove.
  Date: 2026-08-10

- Decision: Count and instrument only durable finalizations that actually changed a row still in
  `publishing`, while keeping `claimed` as the selected count.
  Rationale: A stale-row reclaimer can win while an external publish is in flight. Conditional
  updates protect the newer claim, and the difference between claimed and completed work must remain
  visible under ADR 25 instead of being restated as success.
  Date: 2026-08-10

- Decision: Release this as the next shared PVP-major Keiro package cohort; as of 2026-08-10 that is
  0.12.0.0, but the release workflow must recompute the number if another cohort ships first.
  Rationale: Adding constructors and record fields breaks exhaustive matches and record
  construction. All published Keiro packages share one version, so a patch/minor release or 0.4
  backport would violate the repository's release contract.
  Date: 2026-08-10

- Decision: Refresh existing Plan 165 and attach intention
  `intention_01kzq9d8cnejpvws5pnk6nx39b` instead of initializing a duplicate plan.
  Rationale: IR-3 and the improvement-request log already identify Plan 165 as the execution unit;
  the ExecPlan is a living document and is the correct place for current validation and scope.
  Date: 2026-08-10

- Decision: Implement against the current 0.13.0.0 working tree and let the native migration and
  release workflows allocate the next identifiers instead of preserving the stale numeric examples.
  Rationale: Released identifiers are immutable and the plan explicitly requires rechecking them at
  execution time. Current source and manifests are authoritative for implementation.
  Date: 2026-08-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The originating request is [IR-3](../improvement-requests/add-an-explicit-terminal-outbox-rejection-outcome.md).
Its downstream blocker is
`mori://shinzui/shikigami/plans/19-sink-delivery-truth-and-downstream-idempotency`; the current Mori
registry does not yet resolve that plan artifact, but this is the intended canonical URI and the
Shikigami checkout located through `mori registry show shinzui/shikigami --full` contains that plan.
The downstream project is still pinned to the 0.4.0.1 Keiro cohort, so adopting the released API is
downstream work and is not performed from this repository.

`keiro/src/Keiro/Outbox.hs` defines the public `PublishOutcome` callback result and the
`publishClaimedOutbox` single-pass worker. The worker claims rows, normalizes missing outcomes and
synchronous callback exceptions to `PublishFailed`, groups outcomes according to `OrderingPolicy`,
persists success/failure/skips, and records pass metrics. `PublishOutcome` currently has only
`PublishSucceeded` and `PublishFailed Text`. `StopTheLine` invokes the callback with singleton rows
and halts on `PublishFailed`; other policies invoke it with the claimed batch.

`keiro/src/Keiro/Outbox/Types.hs` owns `OutboxStatus`, `OutboxRow`, `OutboxPublishSummary`, ordering
policies, and status text encoding. `keiro/src/Keiro/Outbox/Schema.hs` owns claim eligibility and SQL
transitions. Terminal statuses are currently `sent` and `dead`; the per-key and per-source claim SQL
uses `status NOT IN ('sent', 'dead')` to identify head-of-line blockers. The backlog query includes
only `pending` and `failed`, sent garbage collection deletes only `sent`, and dead rows are retained.

`keiro/src/Keiro/Telemetry.hs` owns `KeiroMetrics` and the existing
`keiro.outbox.published`, `keiro.outbox.retried`, `keiro.outbox.deadlettered`, and
`keiro.outbox.reclaimed` counters. `keiro-ops/src/Keiro/Ops/Outbox.hs` parses status filters and
renders outbox rows as tables and JSON. Both must learn the new terminal truth; free-form rejection
detail must never become a metric attribute.

The native schema component lives in `keiro-migrations/migrations/manifest`. At implementation start
it contains 30 migrations, so the normal `keiro-migrate new` command will allocate the next manifest
entry. [ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) requires the new
SQL payload, manifest, `keiro-migrations/migrations.native.lock`, and
`keiro-migrations/expected-schema/native/keiro-v18.txt` to agree. Do not edit
`keiro-migrations/sql-migrations/`, `keiro-migrations/migrations.lock`, or the legacy
`keiro-migrations/expected-schema/v18/` tree.

[ADR 25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md)
requires worker summaries to distinguish selected from completed work. No existing ADR defines
terminal outbox rejection semantics. During implementation, create a focused ADR for the durable
`rejected` meaning, ordering behavior, and at-least-once crash boundary, then validate the profiled
ADR bundle.

“Rejected” means the publisher intentionally and permanently decided not to deliver the message.
“Dead” means retries or stale-publisher recovery exhausted the configured attempt ceiling.
“Finalization” is a conditional update from `publishing` to a terminal status. It is exactly-once as
a committed row transition, while the callback that precedes it is at-least-once if the process
crashes before commit.


## Plan of Work

Milestone 1 adds the bounded public result without changing storage. Create the package-internal
module `keiro/src/Keiro/Outbox/Rejection.hs`, register it under `other-modules` in
`keiro/keiro.cabal`, and let it own the data constructor and validation. Re-export only the opaque
`PublishRejection` type, `PublishRejectionError`, smart constructor, and accessors from
`keiro/src/Keiro/Outbox/Types.hs`; `Keiro.Outbox` already re-exports that module. Keeping the
constructor in an unexposed internal module lets the SQL decoder reconstruct schema-validated values
without giving applications a way around the smart constructor.

In `keiro/src/Keiro/Outbox.hs`, add `PublishRejected !PublishRejection` to `PublishOutcome`.
`mkPublishRejection` accepts a stable code and optional detail. The code must be 1–64 lowercase ASCII
characters matching `[a-z][a-z0-9._-]*`; a present detail must be non-empty and at most 1024 bytes
after UTF-8 encoding. Do not trim, lowercase, or truncate caller data. Add pure tests for every
boundary and invalid class. Document that exhaustive matches over `PublishOutcome` must add the
constructor.

Milestone 2 adds durable truth. Use `keiro-migrate new` to create the next native migration and add
nullable `rejected_at`, `rejection_code`, and `rejection_detail` columns. Add constraints that require
timestamp and code exactly when `status = 'rejected'`, forbid rejection audit fields for every other
status, enforce the code grammar/length, and enforce the 1024-byte detail limit. Keep
`next_attempt_at` non-null and unchanged on rejection, clear stale `last_error`, leave
`published_at` null, and retain the claim's existing `attempt_count`.

In `keiro/src/Keiro/Outbox/Types.hs`, add `OutboxRejected`, add `rejectedAt :: Maybe UTCTime` and
`rejection :: Maybe PublishRejection` to `OutboxRow`, and extend `statusText`/`parseStatus`. In
`keiro/src/Keiro/Outbox/Schema.hs`, decode the new columns and add
`markOutboxRejectedTx :: OutboxId -> PublishRejection -> UTCTime -> Tx.Transaction Bool`. The update
must match only a row still in `publishing`; a repeat, a late worker, or a competing terminal update
returns `False` without overwriting the winner. Treat `rejected` as terminal in both ordered claim
predicates, exclude it from claims/backlog/stuck recovery, retain it from sent-row garbage
collection, and expose its audit values through lookup/list.

Milestone 3 integrates the worker, metrics, and operator surface. Extend outcome grouping so a
rejection finalizes the current row and processing continues with later rows in the same key/source
group; only `PublishFailed` creates a skipped suffix. `StopTheLine` likewise continues after
`PublishRejected` and halts only on `PublishFailed`. Persist sent, failed/dead, skipped, and rejected
marks in one database transaction per claimed batch so a persistence error leaves the whole batch
eligible for crash recovery. Make the schema updates return affected-row facts and derive
`published`, `rejected`, `retried`, and `dead` from committed changes. `claimed` remains the selected
count, so a stale-worker race is visible when completed counts sum to less than claimed, as required
by ADR 25.

Add `rejected :: Int` to `OutboxPublishSummary` and add the no-attribute counter
`keiro.outbox.rejected` to `KeiroMetrics`. Increment it from the committed rejected count; do not use
the rejection detail or code as a metric label. A reported rejection is an intentional terminal
outcome, so it must not set the producer span to `Error`; existing `PublishFailed` behavior remains.
Update `keiro-ops/src/Keiro/Ops/Outbox.hs` and `keiro-ops/test/Main.hs` so `--status rejected` parses,
table/JSON output shows rejection timestamp/code/detail, and sent garbage collection and stale-row
maintenance continue to ignore rejected rows.

Milestone 4 proves compatibility and ships the cohort. Extend `keiro/test/Main.hs` with public API,
database, ordering, crash/recovery, summary, and telemetry tests. Extend migration tests and counts,
append the native checksum, regenerate the PostgreSQL 18 text snapshot, and update
`docs/user/outbox.md`, `keiro/CHANGELOG.md`, the root `CHANGELOG.md`, and operator help. Create or
update the terminal-outbox ADR and validate it. Keep IR-3 proposed until the release is live; after
release, set it to `completed`, advance its timestamp, add its OKF log entry, and run strict profile
validation. Run Mori dependents to record compatibility exposure without editing those repositories.

Because `PublishOutcome`, `OutboxStatus`, `OutboxRow`, and `OutboxPublishSummary` are public and gain
constructors/fields, run the repository release workflow as a shared PVP-major release. Hackage and
upstream tags showed 0.11.0.0 as current on 2026-08-10, making 0.12.0.0 the current candidate; recheck
the registry and tags immediately before release. Shikigami's exact 0.4.0.1 pin must be upgraded in
its own plan after this release and is not a reason to backport or weaken Keiro's versioning.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
mori registry dependents shinzui/keiro --packages
cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "add terminal outbox rejection outcome"
cabal run keiro-migrate -- check \
  --manifest keiro-migrations/migrations/manifest
cabal test keiro:keiro-test --test-options='--match Keiro.Outbox'
cabal test keiro-ops:keiro-ops-test --test-options='--match outbox'
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations:keiro-migrations-test
cabal test keiro-migrations:keiro-migrations-test
cabal build all
just verify
nix flake check
```

After `keiro-migrate new`, append the SHA-256 of the new SQL file to
`keiro-migrations/migrations.native.lock` in manifest order before running the migration suite. The
focused suites must report zero failures for validation, durable finalization, no retry, ordering
release, operator rendering, metrics, and crash/reclaim behavior. The first regeneration run is
expected to rewrite `keiro-migrations/expected-schema/native/keiro-v18.txt`; the second migration
test must pass without the regeneration variable and prove the checked-in snapshot is current.

A SQL assertion after rejection must show `status = 'rejected'`, unchanged non-null
`next_attempt_at`, unchanged claim attempt count, `last_error IS NULL`, `published_at IS NULL`, and
populated rejection timestamp/code. Record the allocated migration identifier, final test counts,
release version, Hackage URLs, and tag evidence in this plan during implementation.


## Validation and Acceptance

1. A public publisher constructs `PublishRejected` through the public smart constructor with a
   valid bounded code/detail. It imports no internal module and throws no exception to express the
   outcome. Boundary tests reject empty/uppercase/invalid/overlong codes and empty/overlong detail.
2. A claimed row rejected once transitions to distinct `rejected` status, stores classification and
   time, preserves its claim attempt count and next-attempt timestamp, clears stale error state,
   increments the committed rejection summary/metric once, and is never scheduled or claimed again.
3. Repeating or racing finalization returns `False` and cannot overwrite `sent`, `dead`, another
   rejection, or a row reclaimed into a newer attempt. The pre-commit crash window is documented and
   tested as at-least-once callback invocation followed by one committed rejection transition.
4. A rejection releases later per-key and per-source work. A mid-group rejection does not skip the
   suffix, and `StopTheLine` continues after rejection. A transient failure still backs off and
   halts/skips according to the policy, retry exhaustion still becomes `dead`, and success still
   becomes `sent`.
5. Missing callback outcomes and synchronous callback exceptions remain `PublishFailed`, never
   rejected. Invalid rejection data fails before a database statement is available.
6. `OutboxPublishSummary`, `keiro.outbox.rejected`, `keiro-ops outbox list/show`, and status filters
   distinguish published, retrying, dead, and rejected. Summary counts come from affected rows;
   free-form detail is not a metric label and payloads are not logged.
7. The new native migration, manifest, native lock, PostgreSQL 18 expected-schema text, migration
   count assertions, fresh install, and upgrade from the 0.11.0.0 cohort pass. Frozen Codd artifacts
   are byte-identical. Changelogs describe all exhaustive-match and record-construction impact.
8. The full repository gate passes, the next shared PVP-major cohort is tagged and live on Hackage,
   and only then is IR-3 changed from `proposed` to `completed` with a strict-valid OKF log update.


## Idempotence and Recovery

The conditional finalization statement is safe to repeat and never reopens or overwrites a terminal
row. Publisher workers may retry the whole claim cycle after crashes; before the outcome transaction
commits, the transport callback can run again and must return the same terminal decision. After
commit, the row is excluded from claims. A stale reclaimer that wins before the original worker
commits causes that worker's conditional update to return `False`; it must not mutate the newer
claim, and the summary's completed total remains below `claimed` so the race is observable.

Migrations are forward-only. Generate a new native migration; never edit released SQL or frozen
Codd evidence. Migration DDL should be idempotent where that does not weaken constraints, and a
failed development migration can be retried on a fresh ephemeral database. If an adapter cannot
supply a stable bounded rejection code, map its finite error taxonomy explicitly or return
`PublishFailed`; never derive a code or metric label from arbitrary exception text.


## Interfaces and Dependencies

`Keiro.Outbox` and `Keiro.Outbox.Schema` must expose equivalents of the following. The constructor
for `PublishRejection` lives only in the unexposed `Keiro.Outbox.Rejection` module; public access
through the `Keiro.Outbox.Types` re-export is abstract, and the accessors return the validated stored
values.

```haskell
data PublishRejection

data PublishRejectionError
  = InvalidPublishRejectionCode Text
  | PublishRejectionDetailEmpty
  | PublishRejectionDetailTooLong Int

mkPublishRejection
  :: Text
  -> Maybe Text
  -> Either PublishRejectionError PublishRejection

publishRejectionCode :: PublishRejection -> Text

publishRejectionDetail :: PublishRejection -> Maybe Text

data PublishOutcome
  = PublishSucceeded
  | PublishFailed Text
  | PublishRejected PublishRejection

markOutboxRejectedTx
  :: OutboxId
  -> PublishRejection
  -> UTCTime
  -> Tx.Transaction Bool
```

`OutboxStatus` gains `OutboxRejected`; `OutboxRow` gains `rejectedAt` and typed `rejection` fields;
`OutboxPublishSummary` gains a `rejected` count. Row decoders reconstruct the opaque value only from
schema-enforced data. The worker finalization transaction also needs affected-row results for sent,
failed/dead, and skipped updates so all summary fields represent completed work under ADR 25. No new
external library is expected.

The work implements local IR-3 and unblocks
`mori://shinzui/shikigami/plans/19-sink-delivery-truth-and-downstream-idempotency`. Downstream pin and
source migrations remain outside this plan. Release work follows the repository's shared PVP
package-cohort workflow and must include the active ExecPlan and Intention trailers on its commits.


Revision note: Detached this plan from the completed inbox/outbox MasterPlan so it is an independent
implementation unit, 2026-07-31.

Revision note: Revalidated IR-3 against Keiro 0.11.0.0, current native migration/telemetry/operator
surfaces, ADRs 9 and 25, Hackage/upstream tags, and the exact Shikigami 0.4.0.1 pin; accepted the API
change, made validation/state/PVP/crash semantics explicit, attached the active intention, and reused
the already-linked Plan 165 instead of creating a duplicate, 2026-08-10.
