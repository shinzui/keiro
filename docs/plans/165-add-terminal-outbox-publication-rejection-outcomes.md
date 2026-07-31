---
id: 165
slug: add-terminal-outbox-publication-rejection-outcomes
title: "Add terminal outbox publication rejection outcomes"
kind: exec-plan
created_at: 2026-07-31T14:46:36Z
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
terminal transition, zero retry scheduling, a `rejected` row with audit fields, one rejection metric,
and a later same-key row becoming eligible.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: add public typed rejection data and validation without changing existing success
  or transient-failure semantics.
- [ ] Milestone 2: add the durable rejected state and an idempotent conditional finalization path.
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
  `mori://shinzui/shikigami`. No existing ExecPlan implements IR-3, and MasterPlan 3's four
  completed children predate the request.
- 2026-07-31: Existing publisher logic treats failure as an ordering barrier. A terminal rejection
  must define whether it releases or blocks successors instead of accidentally inheriting retry
  behavior.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add `PublishRejected PublishRejection` and a distinct durable `OutboxRejected` status;
  do not encode rejection as `PublishFailed`, `OutboxDead`, or success.
  Rationale: Dead means retry exhaustion and sent means transport acknowledgement. Audit, metrics,
  and downstream state machines need the terminal cause to remain truthful.
  Date: 2026-07-31

- Decision: `PublishRejection` contains a validated stable code plus a bounded human detail; both
  are stored, while telemetry labels use only the bounded code.
  Rationale: Free-form errors are useful for audit but dangerous as metric labels and can grow
  without limit. A stable code supports policy and dashboards.
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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The originating request is
`docs/improvement-requests/add-an-explicit-terminal-outbox-rejection-outcome.md` (IR-3; use the
actual checked-in filename if it differs). `keiro/src/Keiro/Outbox.hs` defines `PublishOutcome`,
`publishClaimedOutbox`, ordering-policy batching, fallback behavior when a publisher omits an
outcome, and `OutboxPublishSummary`. It currently routes every non-success through
`markOutboxFailedTx` and counts the result as retried or dead.

`keiro/src/Keiro/Outbox/Schema.hs` defines statuses, claim eligibility, failure/backoff,
retry-exhaustion dead-lettering, maintenance, and row queries. Terminal statuses are currently
`sent` and `dead`; ordering SQL excludes those from head-of-line blockers. Migrations live in
`keiro-migrations/migrations/` with legacy/native representations, manifests/locks, and expected
schema. `Telemetry.hs` already has published/retried/deadlettered counters but no rejection metric.

Completed MasterPlan 3 is historical context for the inbox/outbox subsystem; this standalone plan
owns terminal publication rejection. The originating downstream project must always be referenced
canonically as `mori://shinzui/shikigami`. [ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md)
requires all schema artifacts to stay in sync. No existing ADR defines terminal publication
semantics; add one or amend the messaging ADR discovered during implementation.

“Rejected” means the publisher made a successful, intentional terminal decision that the message
will not be delivered. “Dead” means Keiro exhausted retries or recovered an unrecoverable stuck row.
“Finalization” is the conditional transition from the claimed `publishing` generation to a terminal
status.


## Plan of Work

Milestone 1 adds a smart constructor and public rejection type in `Outbox.hs`. Codes use a small
documented character set and length; details are normalized and truncated/rejected at a documented
byte limit before reaching SQL. Extend `PublishOutcome` and exhaustive tests. Existing source that
pattern-matches the two-constructor type gets the expected compile-time compatibility signal; add a
changelog migration example.

Milestone 2 adds a forward migration for `rejected` status plus `rejected_at`, `rejection_code`, and
`rejection_detail` (or a normalized terminal-outcome table if schema review proves preferable).
Update constraints so those fields are present exactly for rejected rows and absent elsewhere.
Add `markOutboxRejectedTx` as a conditional `publishing -> rejected` update tied to the current
claim/attempt generation. A repeated update returns `AlreadyFinalized`; it cannot overwrite `sent`,
`dead`, or a different rejection. Update claim, backlog, ordered-head, cleanup, row decoders, and
inspection queries to treat rejected as terminal but retain it for audit.

Milestone 3 handles `PublishRejected` separately in `publishClaimedOutbox`. Count it as processed
and rejected, not published/retried/dead; do not call the backoff path. For ordered policies, finish
the current terminal row and allow successors on later claims. For `StopTheLine`, continue after a
rejection but retain current halt-on-transient-failure behavior. Add a bounded-code counter and span
attributes, extend `OutboxPublishSummary`, maintenance summaries, and any public hooks. Publisher
exceptions and missing outcomes remain transient failures.

Milestone 4 adds PostgreSQL tests for one rejection, repeated finalization, concurrent recovery,
claim exclusion, successor release under every ordering policy, StopTheLine behavior, transient
failure regression, dead regression, and audit retention. Simulate crash before status commit and
prove the row may be reclaimed/re-rejected, then commit and prove it never publishes again. Update
migrations, expected schema, locks, public API/operator docs, IR-3 status/linkage, ADR, changelogs,
and release notes. Run Mori dependents to document downstream pattern-match migration without
editing their repositories.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
mori registry dependents shinzui/keiro --packages
cabal test keiro-test --test-options='--match=outbox.*reject'
cabal test keiro-migrations-test
cabal test keiro-test
cabal build all
nix flake check
```

The focused suite must report zero failures for validation, durable finalization, no retry,
ordering release, metrics, and crash/reclaim behavior. A SQL assertion after rejection must show
`status = 'rejected'`, `next_attempt_at` unchanged or null according to the final schema, populated
rejection audit fields, and no later claim. Record final limits, schema version, and test counts in
this plan during implementation.


## Validation and Acceptance

1. A public publisher can construct `PublishRejected` only with a valid bounded code/detail. It
   needs no internal import and throws no exception to express the outcome.
2. A claimed row rejected once transitions to distinct `rejected` status, stores classification and
   time, increments the rejection summary/metric once, and is never scheduled or claimed again.
3. Repeating or racing finalization cannot overwrite another terminal state or increment durable
   finalization twice. The pre-commit crash window is documented and tested as at-least-once
   callback invocation with idempotent rejection handling.
4. Rejection releases later per-key/per-source ordered work and does not halt StopTheLine. A
   transient failure still backs off/halts exactly as before; retry exhaustion still becomes dead;
   success still becomes sent.
5. Missing publisher outcomes and thrown exceptions remain `PublishFailed`, never rejected. Invalid
   rejection data fails before invoking the database statement.
6. Operator queries, summaries, and telemetry distinguish published, retrying, dead, and rejected.
   Free-form detail is not a metric label and payloads are not logged.
7. Migration source/native parity, lock, expected schema, and upgrade-from-previous-version tests
   pass. Changelog/release notes describe the new constructor and status compatibility impact.
8. IR-3 links to this implementation plan and is marked implemented only after the behavior and
   release requested by the IR actually exist.


## Idempotence and Recovery

The conditional finalization statement is safe to repeat and never reopens terminal rows. Publisher
workers may retry the whole claim cycle after crashes; before the rejection transaction commits,
the transport callback can run again and must return the same terminal decision. After commit, the
row is excluded from claims.

Migrations are forward-only. Do not edit released status constraints in place; add a new migration
and regenerate/verify all artifacts. If an adapter cannot supply a stable bounded rejection code,
map its finite error taxonomy explicitly or return transient failure—never derive an unbounded
metric label from arbitrary exception text.


## Interfaces and Dependencies

`Keiro.Outbox` and `Keiro.Outbox.Schema` must expose equivalents of:

```haskell
data PublishRejection = PublishRejection
  { code :: RejectionCode
  , detail :: Text
  }

mkPublishRejection :: Text -> Text -> Either RejectionValidationError PublishRejection

data PublishOutcome
  = PublishSucceeded
  | PublishFailed Text
  | PublishRejected PublishRejection

data RejectionFinalizeOutcome
  = RejectionFinalized
  | RejectionAlreadyFinalized OutboxStatus

markOutboxRejectedTx
  :: OutboxId
  -> PublishRejection
  -> UTCTime
  -> Tx.Transaction RejectionFinalizeOutcome
```

`OutboxStatus` gains `OutboxRejected`, `OutboxPublishSummary` gains a `rejected` count, and row
decoders expose nullable rejection audit fields with schema-enforced consistency. No new external
library is expected. The work implements local IR-3 and unblocks the downstream origin
`mori://shinzui/shikigami`; downstream release consumption remains outside this plan.


Revision note: Detached this plan from the completed inbox/outbox MasterPlan so it is an independent
implementation unit, 2026-07-31.
