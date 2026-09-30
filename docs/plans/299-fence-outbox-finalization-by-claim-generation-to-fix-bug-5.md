---
id: 299
slug: fence-outbox-finalization-by-claim-generation-to-fix-bug-5
title: "Fence outbox finalization by claim generation to fix BUG-5"
kind: exec-plan
created_at: 2026-09-30T19:52:52Z
intention: "intention_01m3sy10ckeb192fr2m3d8s7hx"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T19:52:52Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-30T20:16:46Z
      mode: "update"
      note: "Added just bench-regression to Milestone 2 to measure the batch sent statement's unnest join"
---

# Fence outbox finalization by claim generation to fix BUG-5

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro's durable outbox is the table `keiro.keiro_outbox`, where a service records "I have
decided to publish this integration event" and a separate publisher process later drains
each row to Kafka and records the result. A publisher takes a row by *claiming* it (moving
its status to `publishing`), calls the transport, and then *finalizes* the row (moving it to
`sent`, `rejected`, `failed`, or `dead`). If a publisher dies or stalls while holding a
claim, a slower *maintenance pass* returns the row to `failed` after `publishingTimeout` so
another publisher can claim it again.

Bug report [BUG-5](../bug-reports/5-stale-outbox-publisher-finalizes-reclaimed-claim.md),
filed from the external verification harness Kenshou on 2026-09-24, shows that the
finalization step does not check *which* claim it is finalizing. Every finalization
statement in `keiro/src/Keiro/Outbox/Schema.hs` matches only `outbox_id = $1 AND status =
'publishing'`. When publisher P1 stalls inside its callback, maintenance requeues its row,
and publisher P2 claims and successfully publishes it, P1's late finalization matches P2's
live claim because that claim is also `publishing`. P1's stale "failed" flips the row to
`failed`; P1's stale "failed" at the attempt ceiling flips it to `dead`; and even P1's stale
"succeeded" marks P2's claim `sent` before P2 reports. In the first two cases P2's real
success can no longer mark the row `sent`, so a row whose event *was* delivered to the broker
sits in `failed` or `dead` and is retried or dead-lettered.

After this plan, a claim carries a monotone *claim generation*, a per-row counter that every
claim increments and every finalization must present. A finalization that presents an old
generation changes nothing. Concretely: after implementation, running

```bash
cabal test keiro-test --test-show-details=direct --test-options='--match "stale publisher"'
```

from the repository root passes examples that fail on today's tree with `expected: Nothing
but got: Just OutboxFailed`, a new migration `0033.sql` adds the column, `keiro-ops outbox
show --json` prints each row's `claim_generation`, the user documentation explains the fence,
and BUG-5 moves to `fixed` with `fixedVersion: unreleased` until the next lockstep release.


## Progress

- [ ] Milestone 0: link this plan from the BUG-5 report body, set the report to `confirmed`, and log the change.
- [ ] Milestone 0: add the two red examples (unit-level late mark, end-to-end `publishClaimedOutbox` arms) against the current ID-only API and record their failing output in Surprises & Discoveries.
- [ ] Milestone 0: commit the red examples with the report update.
- [ ] Milestone 1: create migration `keiro-migrations/migrations/0033.sql` through `keiro-migrate new`, write the `ALTER TABLE` body, and confirm the manifest append.
- [ ] Milestone 1: append the checksum line to `keiro-migrations/migrations.native.lock`.
- [ ] Milestone 1: regenerate `keiro-migrations/expected-schema/native/keiro-v18.txt` and review the two added lines.
- [ ] Milestone 1: bump every native-count (32 → 33) and composed-plan-count (44 → 45) assertion in `keiro-migrations/test/Main.hs`, add the `0033` upgrade example, and update the README count.
- [ ] Milestone 1: `cabal test keiro-migrations-test` passes; commit.
- [ ] Milestone 2: add `ClaimGeneration`, `OutboxClaim`, `outboxClaim`, and the `OutboxRow.claimGeneration` field in `keiro/src/Keiro/Outbox/Types.hs`.
- [ ] Milestone 2: read and increment `claim_generation` in the claim statement, decoder, and every row-select statement in `keiro/src/Keiro/Outbox/Schema.hs`.
- [ ] Milestone 2: fence the five finalization statements and change their entry points to take `OutboxClaim`.
- [ ] Milestone 2: thread claims through `markProcessedOutcomes` in `keiro/src/Keiro/Outbox.hs` and update the haddocks.
- [ ] Milestone 2: port the Milestone 0 examples and every existing caller in `keiro/test/Main.hs` to the claim API; add the generation-survives-requeue example.
- [ ] Milestone 2: `cabal build all` and `cabal test keiro-test` pass.
- [ ] Milestone 2: `just bench-regression` exits 0; record the outbox scenario deltas against `keiro/bench/baseline-outbox.csv` in Surprises & Discoveries; commit.
- [ ] Milestone 3: expose `claim_generation` in `keiro-ops` JSON output with a test; `cabal test keiro-ops-test` passes.
- [ ] Milestone 3: update `docs/user/outbox.md`, `docs/user/api-reference.md`, `docs/guides/integration-events-with-kafka.md`, and `docs/capabilities/transactional-outbox.md`, log each bundle, and validate.
- [ ] Milestone 3: write the four changelog entries (root, `keiro`, `keiro-migrations`, `keiro-ops`).
- [ ] Milestone 3: move BUG-5 to `fixed` with `fixedVersion: unreleased` and a resolution; log and validate.
- [ ] Milestone 3: distill the fence into a new ADR, log it, and validate; commit.
- [ ] Milestone 4: run `just verify` to completion, reading the exit code from inside the log, and record the result.
- [ ] Milestone 4: fill in Outcomes & Retrospective and record the Kenshou follow-up.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fence finalization with a per-row monotone counter column
  `claim_generation BIGINT NOT NULL DEFAULT 0`, incremented by the claim statement, rather
  than with a per-claim UUID token or with the existing `attempt_count`.
  Rationale: A counter needs no client-side randomness and no extra claim parameter, is
  deterministic in tests (the first claim is generation 1, the re-claim is generation 2),
  and reads naturally for operators as "how many times this row was claimed".
  `attempt_count` cannot serve as the fence: `markSkippedStmt` decrements it, operators may
  edit it, and it conflates retry budget with ownership. The timer subsystem's UUID lease
  token ([ADR-39](../adr/0039-foreground-timer-resume-uses-expiring-token-ownership.md))
  solves a different problem, foreground ownership with expiry; the outbox already has an
  expiry mechanism in `publishingTimeout` and only needs identity.
  Date: 2026-09-30

- Decision: The public finalization functions take an `OutboxClaim` (the row id plus the
  generation the publisher received) instead of a bare `OutboxId`, and the ID-only form of
  `markOutboxSent` is removed rather than kept as an "unfenced" alternative.
  Rationale: The bug is precisely that finalization by id alone is unsound once a row can be
  reclaimed. Leaving an id-only public entry point would let any caller reintroduce BUG-5.
  `OutboxRow` already carries everything a caller needs, and `outboxClaim :: OutboxRow ->
  OutboxClaim` makes the change a one-token edit at each call site. The change is a
  PVP-major API change and ships with the next lockstep major release.
  Date: 2026-09-30

- Decision: The maintenance requeue (`requeueStuckStmt`) and dead-letter
  (`deadLetterStuckStmt`) statements do not touch `claim_generation`; only a claim increments
  it.
  Rationale: After a requeue the row is `failed`, so the existing `status = 'publishing'`
  guard already blocks a late finalization until someone re-claims, and the re-claim
  increments the generation. Bumping on requeue would add a second writer of the counter
  for no additional safety.
  Date: 2026-09-30

- Decision: Do not revive the attempt-count fence from the reverted commit `3ce69d58`
  (`replayDeadOutbox`).
  Rationale: That commit fenced an *operator replay of a dead row* on `attempt_count` and was
  reverted in `250d3007` together with unrelated read-model work because of a lock-order
  deadlock in that other work, not because of the fence. It never fenced publisher
  finalization, and the reasons above make `attempt_count` the wrong column for this plan.
  Date: 2026-09-30

- Decision: Acceptance is a deterministic in-repository reproduction in `keiro/test/Main.hs`
  that realises Kenshou's schedule in one process (claim, backdate, maintenance, re-claim,
  late mark, real mark). Re-running the Kenshou scenario is a post-release follow-up, not
  part of this plan's acceptance.
  Rationale: Kenshou's cohorts pin `keiro ==0.17.0.0` and `kiroku-store 0.8.0.1` from
  Hackage, while this repository's master requires `kiroku-store >=0.9.0.1` with its own
  schema migration. Running Kenshou against an unreleased keiro means authoring a new cohort
  in that repository, which is its own work. The in-repository test exercises the same SQL
  statements and the same publisher code path.
  Date: 2026-09-30

- Decision: Also expose `claim_generation` in `keiro-ops outbox` JSON output.
  Rationale: The ops JSON already mirrors every persisted row field; an operator diagnosing
  a reclaimed row needs to see which generation is live. The human table is unchanged.
  Date: 2026-09-30

- Decision: Mark BUG-5 `confirmed` once the red examples reproduce it in Milestone 0, and
  `fixed` with `fixedVersion: unreleased` at the end of Milestone 3; the release process
  replaces `unreleased` with the shipped version.
  Rationale: The bug-report profile reserves `confirmed` for the owning repository after
  reproduction and requires `fixedVersion` on `fixed`; `unreleased` is the bundle's
  convention for fixes on master.
  Date: 2026-09-30

- Decision: Measure the batch sent statement's plan-shape change with the standing benchmark
  guard, `just bench-regression`, as part of Milestone 2 rather than reasoning about it.
  Rationale: The single-row marks only add an equality on a tuple the primary-key probe
  already fetched, and the claim update already rewrites the row, so neither can change a
  plan. The batch sent statement is different: it moves from `outbox_id = ANY($1)` to a join
  against `unnest` of two arrays, and the planner's choice for that join is worth observing.
  [Plan 81](81-outbox-publisher-throughput-run-claiming-batch-publish-off-hot-path-maintenance.md)
  created the outbox tasty-bench scenarios and `keiro/bench/baseline-outbox.csv` with a
  `--fail-if-slower 25` threshold for exactly this kind of change. Added at the user's request
  after the plan review on 2026-09-30.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a multi-package Haskell repository. The packages that matter here are `keiro/` (the
runtime library, cabal package `keiro`, test suite `keiro-test` in `keiro/test/Main.hs`),
`keiro-migrations/` (the embedded PostgreSQL migrations and their runner, test suite
`keiro-migrations-test`), `keiro-ops/` (an operator command-line tool, test suite
`keiro-ops-test`), and `keiro-test-support/` (shared test fixtures that start a throwaway
PostgreSQL through the `ephemeral-pg` library). Documentation lives under `docs/`, and
several `docs/` directories are OKF bundles: directories of Markdown records with YAML
frontmatter that a validator checks and that carry a `log.md` you append to with the `okf`
command. All commands in this plan run from the repository root unless stated otherwise.
Tests that touch the database need `initdb` and `postgres` on the `PATH`; the schema
snapshot test expects PostgreSQL 18.

### The outbox, in the words this plan uses

An *outbox row* is one row of `keiro.keiro_outbox`, created by `enqueueOutboxTx` or
`enqueueProducerOutboxTx` in `keiro/src/Keiro/Outbox/Schema.hs`. Its `status` column is one
of `pending`, `publishing`, `sent`, `rejected`, `failed`, or `dead`; the Haskell type is
`OutboxStatus` in `keiro/src/Keiro/Outbox/Types.hs`.

A *publisher* is a process that runs `publishClaimedOutbox` from `keiro/src/Keiro/Outbox.hs`
on a timer. Each pass *claims* a batch with `claimOutboxBatch`, whose SQL (`claimSql` in
`Schema.hs`) selects `pending`/`failed` rows whose `next_attempt_at` has passed under the
configured ordering policy, locks them with `FOR UPDATE SKIP LOCKED`, and updates them:

```sql
UPDATE keiro.keiro_outbox kt
SET status = 'publishing', attempt_count = kt.attempt_count + 1, updated_at = $2
FROM ready
WHERE kt.outbox_id = ready.outbox_id
RETURNING ...
```

The pass then hands the claimed rows to a caller-supplied *publish callback* (the transport,
Kafka in production) and *finalizes* every row in one transaction inside
`markProcessedOutcomes`: `markOutboxSentBatchTx` for successes, `markOutboxRejectedTx` for
permanent refusals, `markOutboxFailedTx` for retryable failures (which reads the current
`attempt_count` and chooses `failed` or `dead` against `maxAttempts`), and
`markOutboxSkippedTx` for rows skipped because an earlier row in the same ordered group
failed. `markOutboxSent` is the public single-row form of the sent mark.

A *maintenance pass* is `outboxMaintenancePass`, scheduled separately and more slowly. It
calls `requeueStuckOutbox`, whose two statements move rows that have been `publishing` for
longer than `publishingTimeout` (measured from `updated_at`) back to `failed`
(`requeueStuckStmt`) or, if `attempt_count` already reached `maxAttempts`, to `dead`
(`deadLetterStuckStmt`). This is *reclamation*; the metric `keiro.outbox.reclaimed` counts
it. A *stale publisher* is a publisher whose claim has been reclaimed while it was still
running its callback: the process is alive, so it will eventually try to finalize.

### The defect, exactly

Every finalization statement guards on the row id and the `publishing` status only. Read
`keiro/src/Keiro/Outbox/Schema.hs` and find these `WHERE` clauses: `markSentStmt` and
`markSentBatchStmt` (`WHERE outbox_id = $1 AND status = 'publishing'` and the `ANY($1)`
variant), `markRejectedStmt`, `markFailedStmt`, `markSkippedStmt`, and the read that precedes
the failed mark, `readAttemptCountStmt`:

```sql
SELECT attempt_count FROM keiro.keiro_outbox WHERE outbox_id = $1 AND status = 'publishing'
```

Reclamation returns the row to `failed`, and the next claim returns it to `publishing`. From
the stale publisher's point of view the row looks exactly as it did when it claimed it, so
its late statement matches and commits. The haddock on `markOutboxFailedTx` in `Schema.hs`
claims the opposite ("a late failure mark from the original worker must not flip the
re-claimed row mid-publish"); that promise was made when the guard was added by
[plan 70](70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md) and only holds
while nobody re-claims. The existing example "counts only a rejection finalization that wins
the publishing-state race" in `keiro/test/Main.hs` covers the requeue-but-not-yet-re-claimed
window; nothing covers the re-claimed window.

The consequence depends on what the stale publisher reports. A stale `PublishFailed` runs
`markOutboxFailedTx`, which reads the *live* claim's `attempt_count` (already incremented by
the re-claim), so with `maxAttempts = 2` the row becomes `dead` and otherwise `failed`. A
stale `PublishSucceeded` marks the live claim `sent` before its real publisher reports. In
every case the real publisher's finalization then matches zero rows and its pass summary
under-reports, which is the visible gap ADR-37 describes but for the wrong reason.

### The evidence

Kenshou (registry name `shinzui/keiro-runtime-kenshou`, canonical project URI
`mori://shinzui/keiro-runtime-kenshou`) reproduced this on PostgreSQL 18 with two publisher
processes. Its scenario `keiro/outbox/concurrency/zombie-publisher-finalization` lives at the
project-relative path `kenshou-keiro/src/Kenshou/Suite/Keiro/Outbox/Concurrency.hs`
(function `runZombiePublisherFinalization`); an artifact-level Mori URI for that file is
pending. The schedule is: enqueue one keyed row; start P1 with a callback that parks after
the broker append; `SIGSTOP` P1; wait past a one-second `publishingTimeout`; run one
maintenance pass (requeued = 1); start P2, which claims (attempt 2) and parks after its
broker append; `SIGCONT` P1 and let it finalize with the knob-selected outcome; then let P2
finalize. Its verdicts are `schedule-realised` (blocking), `stale-finalization-no-effect`
(row still `publishing` at attempt 2 after P1 finishes), and
`terminal-consistent-with-success` (row `sent` at the end, one broker record for the failed
and dead arms, two for the succeeded control). The failed arm (run
`01a0d4d0-d80e-73df-a678-185c7d8bd738`) left the row `failed`; the dead arm
(`01a0d4d2-4640-7008-9a09-e46104d73de9`) left it `dead`; the succeeded control
(`01a0d4d1-e880-7794-b394-58223cac3e34`) reached `sent` but P1, not P2, produced that
transition. Kenshou's write-up is at project-relative path
`docs/findings/36-keiro-stale-outbox-publisher-finalizes-new-claim.md` under the same
project URI (artifact URI pending). Kenshou currently scopes the two non-blocking verdicts to
BUG-5 with a `KnownDefect` value in the scenario definition.

### What must not change

The claim query's ordering predicates, the `FOR UPDATE SKIP LOCKED` locking, the attempt
accounting (`attempt_count` still increments on claim and decrements on skip), the
`publishingTimeout` reclamation mechanism, the terminal audit semantics of rejection, and
the at-least-once callback contract all stay as they are. The fence only adds a second
condition to finalization: the presented generation must equal the row's current generation.
The transport callback can still run more than once for the same message; consumers still
deduplicate through the inbox.

### Relevant ADRs

[ADR-37](../adr/0037-outbox-publication-rejection-is-terminal-audit-truth.md) states that
every finalization transition is conditional on the row still being `publishing`, that pass
summaries count committed row changes rather than callback outcomes, and that a
stale-publisher reclaimer may win the race and produce a visible gap between claimed and
completed counts. This plan keeps all three statements true and tightens the first: a
transition is conditional on the row still being `publishing` *under the same claim*.

[ADR-25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md)
requires worker summaries to report finished work, not attempted work. After the fence a
stale publisher's summary reports zero finalized rows for the reclaimed row, which is the
truthful count.

[ADR-39](../adr/0039-foreground-timer-resume-uses-expiring-token-ownership.md) records the
timer subsystem's ownership fence (`resume_claim_token` plus `resume_lease_until`) and its
deployment consequence: additive nullable columns do not make mixed old and new writers safe,
because old binaries lack the ownership predicate. The same consequence applies here and is
documented in Milestone 3.

[ADR-9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) makes the
checked-in schema snapshot `keiro-migrations/expected-schema/native/keiro-v18.txt` a
separate gate from the migration ledger; Milestone 1 regenerates it.

[ADR-42](../adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md)
defines the row's identity columns and unique constraints; this plan does not touch them.

No cross-repository ADR is relevant. Kenshou records its finding as a finding document, not
an ADR.

### Prior plans that shaped this code

[Plan 70](70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md) added
reclamation and the `status = 'publishing'` guard on `markOutboxSent`.
[Plan 81](81-outbox-publisher-throughput-run-claiming-batch-publish-off-hot-path-maintenance.md)
moved reclamation off the publish path into `outboxMaintenancePass` and introduced batch
finalization. [Plan 165](165-add-terminal-outbox-publication-rejection-outcomes.md) added
rejection and made all four marks commit in one transaction with affected-row results. This
plan is the missing fourth step: making the guard claim-specific.

### Migration conventions

Native migrations are the files listed, in order, in `keiro-migrations/migrations/manifest`;
the newest is `0032.sql`, so the next is `0033.sql`. Each file starts with a one-line
`-- description` comment. `keiro-migrations/migrations.native.lock` holds one line per file,
`<sha256>  <name>`, and the test "matches the manifest, directory membership, and every
payload byte" fails on any mismatch. The embedded expected schema
`keiro-migrations/expected-schema/native/keiro-v18.txt` is a sorted text snapshot that the
test "checked-in snapshot matches what the migrations build" compares against a freshly
migrated database; setting `KEIRO_REGENERATE_EXPECTED_SCHEMA=1` makes that test rewrite the
file instead. Several assertions in `keiro-migrations/test/Main.hs` count native files (32)
and composed plan entries (44, Kiroku's twelve plus Keiro's thirty-two); a new migration
moves each by one. The last migration commit, `c351fceb` (timer resume leases), is the
worked example of every file a new migration touches. A migration body must qualify every
object with `keiro.` and must not set `search_path`; a lint test enforces this.

### Bug-report bundle conventions

`docs/bug-reports/` is an OKF bundle validated by `just bug-reports-validate` under the
shared `coordination.bugReports` profile. It has no plan field, so a plan is linked by a
paragraph in the report body. `generated.by` and `generated.at` name the agent and time of
the last edit (`process:claude-code` for this session). Status moves `reported` →
`confirmed` (after the owning repository reproduces it) → `in-progress` → `fixed`, and
`fixed` requires `fixedVersion` (`unreleased` while on master) and a `resolution` paragraph.
Every edit gets a line in `docs/bug-reports/log.md` through `okf log add`.

### Test infrastructure you will use

`keiro/test/Main.hs` is one large hspec file. The outbox examples are under
`describe "Keiro.Outbox" $ around (withFreshStore fixture)`, which gives each example a
fresh database handle `storeHandle` and runs actions with `Store.runStoreIO storeHandle`.
Helpers near the bottom of the file: `backdateOutboxUpdatedAt oid time` rewrites a row's
`updated_at` so maintenance sees it as stale; `perRow` lifts a per-row callback into the
batch callback shape `publishClaimedOutbox` wants; `outboxIdFromOrdinal n` and the constants
`outboxUuid1`/`outboxUuid2` mint ids; `sampleIntegrationEnvelope` is a ready-made event;
`sampleOutboxRow` builds an `OutboxRow` by record syntax and must gain the new field. The
module imports `markOutboxFailedTx` and `markOutboxRejectedTx` from `Keiro.Outbox.Schema`
directly; you will add `markOutboxSkippedTx` and `markOutboxSentBatchTx` to that import.

### Other code that touches these types

`keiro-ops/src/Keiro/Ops/Outbox.hs` renders `OutboxRow` values (`outboxJson`,
`outboxRow`, `outboxPreviewResult`) and calls `requeueStuckOutbox`, `listStuckOutbox`, and
`outboxMaintenancePass`; it never finalizes rows. `keiro/bench/Main.hs` calls
`publishClaimedOutbox` only. `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` generates code that
imports only `BackoffSchedule` and `OrderingPolicy` from `Keiro.Outbox.Types`. Kenshou's
roles call `publishClaimedOutbox` and read `OutboxRow` fields through `OutboxRow (..)`
imports; an added field does not break field access. Nothing outside `keiro/test/Main.hs`
constructs an `OutboxRow` by record syntax.


## Plan of Work

The work runs in five milestones. Milestone 0 proves the defect with failing tests written
against today's API and updates the bug report. Milestone 1 adds the schema column, which is
independent of the library change and can ship on its own. Milestone 2 changes the library
so that claims carry their generation and finalization presents it. Milestone 3 covers the
operator tool, documentation, changelogs, the bug report's terminal status, and the ADR.
Milestone 4 runs the whole release gate.

### Milestone 0: reproduce the defect and confirm the report

At the end of this milestone the repository contains two hspec examples that fail on the
current code for the reason BUG-5 describes, and the bug report says `confirmed` and links
this plan. Nothing else changes.

Add the two examples to the `describe "Keiro.Outbox"` block in `keiro/test/Main.hs`, next
to "counts only a rejection finalization that wins the publishing-state race". Both realise
Kenshou's schedule in one process. The first, named "a stale publisher's late failure mark
cannot change a claim reclaimed by maintenance", enqueues one keyed row, claims it (this is
P1's claim; keep the returned row), backdates `updated_at` by an hour, runs
`outboxMaintenancePass` with `publishingTimeout` 1 and asserts `requeued` is 1, claims again
(this is P2's claim; keep that row too and assert `attemptCount` is 2), then performs P1's
late mark with today's ID-only API, `markOutboxFailedTx oid "stale failure" 10 0 now` inside
`Store.runTransaction`, and asserts the result is `Nothing` and the row is still
`OutboxPublishing` with `attemptCount` 2. It then performs P2's mark, `markOutboxSent oid
now`, and asserts `True` and `OutboxSent`. On today's code the first assertion fails with
`Just OutboxFailed`.

The second, named "publishClaimedOutbox finalizes nothing for a claim that maintenance
reclaimed and another publisher took over", drives the same schedule through the real
publisher. Its publish callback, given P1's claimed row, backdates that row, runs the
maintenance pass, claims the row again with `claimOutboxBatch PerKeyHeadOfLine 10 now`
(P2's claim, stored in an `IORef`), and returns `PublishFailed "stale failure"`. After
`publishClaimedOutbox (perRow callback) (defaultPublishOptions & #backoff .~ ConstantBackoff
0) Nothing` returns, assert `claimed` is 1 and `published`, `retried`, `rejected`, and `dead`
are all 0, and the row is `OutboxPublishing` with `attemptCount` 2. Repeat the arm with
`maxAttempts` 2 (Kenshou's dead arm) and assert `dead` is 0, and with `PublishSucceeded`
(the control) and assert `published` is 0. On today's code the first arm reports `retried`
1 and leaves the row `OutboxFailed`, the second reports `dead` 1 and `OutboxDead`, and the
control reports `published` 1.

Run the two examples, paste the failure output into Surprises & Discoveries, then edit
`docs/bug-reports/5-stale-outbox-publisher-finalizes-reclaimed-claim.md`: set `status:
confirmed`, set `generated.by: process:claude-code` and `generated.at` to the current UTC
time, and append a paragraph "Tracked by [plan 299](../plans/299-fence-outbox-finalization-by-claim-generation-to-fix-bug-5.md),
which reproduces the schedule in `keiro-test` and fences finalization with a per-claim
generation." Log the change and validate the bundle. Commit the examples and the report
together; the commit message says the examples are expected to fail.

### Milestone 1: migration 0033 adds the claim generation column

At the end of this milestone the migration plan has thirty-three Keiro migrations, a fresh
database has a `claim_generation` column on `keiro.keiro_outbox` with default 0, the schema
snapshot and checksum lock agree, and `cabal test keiro-migrations-test` passes. The library
does not yet read the column, so this milestone is independently shippable.

Create the file with the migration tool, which appends the manifest for you:

```bash
cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "fence outbox finalization with a claim generation"
```

Confirm the printed path is `keiro-migrations/migrations/0033.sql` and that
`keiro-migrations/migrations/manifest` ends with `0033.sql`. Replace the file's body below
the description comment with:

```sql
-- fence outbox finalization with a claim generation

-- Every claim increments the generation; every finalization must present the
-- generation it received. A publisher whose claim was reclaimed by maintenance
-- and re-claimed by another publisher can no longer change the newer claim
-- (BUG-5). PostgreSQL stores the constant default without rewriting the table.
ALTER TABLE keiro.keiro_outbox
  ADD COLUMN claim_generation BIGINT NOT NULL DEFAULT 0;
```

Run `cabal run keiro-migrate -- check --manifest keiro-migrations/migrations/manifest` and expect it to
report the manifest as consistent. Append the checksum line to
`keiro-migrations/migrations.native.lock` in the same two-space format as the existing
lines:

```bash
shasum -a 256 keiro-migrations/migrations/0033.sql | sed 's#keiro-migrations/migrations/##' >> keiro-migrations/migrations.native.lock
tail -2 keiro-migrations/migrations.native.lock
```

Regenerate the snapshot and inspect the diff, which must add exactly two lines, a column
line and a not-null constraint line for `keiro_outbox.claim_generation`:

```bash
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test \
  --test-show-details=direct --test-options='--match "checked-in snapshot"'
git diff --stat keiro-migrations/expected-schema/native/keiro-v18.txt
git diff keiro-migrations/expected-schema/native/keiro-v18.txt
```

Then update `keiro-migrations/test/Main.hs`. Every assertion that names the native count
(the two example titles saying "thirty-two", `length keiroEntries shouldBe 32`, and
`length (Keiro.pendingMigrations handshake) shouldBe 32`) becomes thirty-three, and every
assertion that names the composed count (`44` in the handshake, rerun, verification, and
concurrent-run examples) becomes 45. The partial-fixture upgrade examples apply the full
plan after a fixture and assert `Prelude.drop N (reportOutcomes report) shouldBe replicate K
AppliedNow`; each `K` grows by one. Do not change `take 31` in the `0032` example; it
describes the plan before `0032`. Add a new example after it:

"0033 adds claim_generation zero to existing outbox rows" builds a prior plan from the first
thirty-two embedded entries (`take 32`), migrates a fresh database with it, inserts five
outbox rows (one per status `pending`, `publishing`, `failed`, `sent`, `dead`, using the
minimal column set the `0002` table requires: `outbox_id`, `message_id`, `source`,
`destination`, `event_type`, `schema_version`, `content_type`, `payload_bytes`,
`occurred_at`, `status`), applies the full plan, and asserts `SELECT count(*) FROM
keiro.keiro_outbox WHERE claim_generation = 0` is 5 and that `UPDATE keiro.keiro_outbox SET
claim_generation = NULL` fails. Model it on the `0032` example directly above it.

Finally correct `keiro-migrations/README.md`: "owns thirty embedded SQL migrations" is
already stale (make it "thirty-three"), and its `check` example passes the manifest as a
positional argument while the installed `pg-migrate-cli` 1.2 takes `--manifest PATH`, as
the commands in this plan do. Run the suite, then commit.

### Milestone 2: claims carry a generation and finalization presents it

At the end of this milestone `claimOutboxBatch` returns rows whose `claimGeneration` field
equals the row's new generation, every finalization entry point takes an `OutboxClaim`, the
SQL refuses a stale generation, the Milestone 0 examples pass, `cabal test keiro-test` is
green, and the outbox benchmark shows the batch sent statement's new `unnest` join inside the
standing regression threshold.

In `keiro/src/Keiro/Outbox/Types.hs`, add two types and one function, export them, and add
the field. `ClaimGeneration` is a newtype over `Int64` deriving `Generic`, `Eq`, `Ord`, and
`Show`, with haddock explaining that it is the row's monotone claim counter and that a value
of 0 means the row was never claimed. `OutboxClaim` is a record of `outboxId :: !OutboxId`
and `claimGeneration :: !ClaimGeneration` deriving `Generic`, `Eq`, and `Show`, with
haddock explaining that it names one specific claim and that finalization functions accept
only the claim that `claimOutboxBatch` handed out. `outboxClaim :: OutboxRow -> OutboxClaim`
projects the two fields. `OutboxRow` gains `claimGeneration :: !ClaimGeneration` directly
after `attemptCount`. Extend the `OutboxPublishSummary` haddock so the sentence about a pass
finalizing fewer rows than it claimed also names the re-claim case.

In `keiro/src/Keiro/Outbox/Schema.hs`, make the column flow through every read. Add
`claim_generation` after `attempt_count` in `rowColumns` (as `kt.claim_generation`),
`unqualifiedRowColumns`, and `selectAllSql`; add a `claimGeneration :: !ClaimGeneration`
field to `RawRow` after `attemptCount`, decode it with `ClaimGeneration <$> D.column
(D.nonNullable D.int8)` at the same position in `rawRowDecoder`, and copy it in
`assembleRow`. In `claimSql`, change the update to

```sql
SET status = 'publishing', attempt_count = kt.attempt_count + 1,
    claim_generation = kt.claim_generation + 1, updated_at = $2
```

Then fence the six statements. Each gains a `claim_generation = <generation>` conjunct next
to its `status = 'publishing'` conjunct and a matching `E.int8` parameter, so the parameter
tuples grow by one and the `contrazipN` helpers move up one arity (`contrazip6` is already
used in `keiro/src/Keiro/Timer/Schema.hs` and comes from the same `Contravariant.Extras`
import). The batch sent statement matches id and generation pairs by unnesting two arrays:

```sql
UPDATE keiro.keiro_outbox kt
SET status = 'sent',
    published_at = $3,
    last_error = NULL,
    updated_at = $3
FROM unnest($1::uuid[], $2::bigint[]) AS claim(outbox_id, claim_generation)
WHERE kt.outbox_id = claim.outbox_id
  AND kt.claim_generation = claim.claim_generation
  AND kt.status = 'publishing'
```

with parameters `([UUID], [Int64], UTCTime)` encoded by `contrazip3` of two
`E.foldableArray` params and one `timestamptz`. `readAttemptCountStmt` becomes a statement
over `(UUID, Int64)` with `AND claim_generation = $2`, so a stale publisher cannot even read
the live claim's attempt count. Change the entry points to take claims:

```haskell
markOutboxSent :: (Store :> es) => OutboxClaim -> UTCTime -> Eff es Bool
markOutboxSentBatch :: (Store :> es) => [OutboxClaim] -> UTCTime -> Eff es Int
markOutboxSentBatchTx :: [OutboxClaim] -> UTCTime -> Tx.Transaction Int
markOutboxRejectedTx :: OutboxClaim -> PublishRejection -> UTCTime -> Tx.Transaction Bool
markOutboxFailedTx :: OutboxClaim -> Text -> Int -> NominalDiffTime -> UTCTime -> Tx.Transaction (Maybe OutboxStatus)
markOutboxSkippedTx :: OutboxClaim -> Text -> UTCTime -> Tx.Transaction Bool
```

Rewrite the haddocks of `markOutboxSent` and `markOutboxFailedTx` so they describe the
fence truthfully: a mark changes the row only while it is still `publishing` under the
presented generation; a reclaimed and re-claimed row has a newer generation and the mark
returns `False` or `Nothing` without touching it. `requeueStuckOutbox`, `deadLetterStuckStmt`,
`requeueStuckStmt`, `listStuckOutboxStmt`, and the claim predicates are unchanged apart from
the column lists above.

In `keiro/src/Keiro/Outbox.hs`, `OutcomeMarks` currently collects `sentIds :: [OutboxId]`
and `rejectedRows :: [(OutboxId, PublishRejection)]`; change them to `sentClaims ::
[OutboxClaim]` and `rejectedRows :: [(OutboxClaim, PublishRejection)]`, build them with
`outboxClaim row` in `groupMarks`, and pass `outboxClaim row` in `markFailed` and
`markSkipped`. Update the module haddock's paragraph about marking rows and the
`publishClaimedOutbox` haddock to say that finalization is fenced by the claim generation.
The export list needs no change because `module Keiro.Outbox.Types` re-exports the new
types; confirm `markOutboxSent` is still exported.

In `keiro/test/Main.hs`, port the Milestone 0 examples so P1's late marks present
`outboxClaim p1Row` and P2's mark presents `outboxClaim p2Row`, and extend the unit-level
example so P1 also tries `markOutboxRejectedTx`, `markOutboxSkippedTx`, and
`markOutboxSentBatchTx [outboxClaim p1Row]` and each returns `False` or 0 while the row
stays `OutboxPublishing`. Add one more example, "claim generation increments on every claim
and survives requeue": claim (generation 1), backdate, maintenance, look the row up
(generation still 1, status `OutboxFailed`), claim again (generation 2). Then fix every
existing call site: "marks a claimed row as sent with published_at set" and "a late failure
mark does not clobber a row that already reached a terminal state" use the claimed row;
"finalizes rejection exactly once with durable typed audit data" passes the claim it holds
for both the first and the repeated rejection (the repeat must still return `False` because
the status is no longer `publishing`); "markOutboxSent does not resurrect a dead row"
constructs `OutboxClaim oid (ClaimGeneration 1)` by hand and must still get `False`; and
`sampleOutboxRow` sets `claimGeneration = ClaimGeneration 0`. Add `markOutboxSkippedTx` and
`markOutboxSentBatchTx` to the `Keiro.Outbox.Schema` import. Build everything and run the suite.

Then measure. `just bench-regression` runs four tasty-bench groups from `keiro/bench/Main.hs`;
the `outbox` group drives `publishClaimedOutbox` over a simulated broker in three scenarios,
`hot-key`, `hot-key-nolatency`, and `multi-key`, and compares each against
`keiro/bench/baseline-outbox.csv`, failing the run when a scenario is more than 25% slower.
The `producer-identity`, `inbox`, and `command` groups are untouched by this plan and act as
controls: if they move too, the machine is noisy, not the change. The benchmark needs the same
throwaway PostgreSQL as the tests and takes several minutes. Record the three outbox deltas in
Surprises & Discoveries whatever they are. If an outbox scenario trips the threshold, first run
`EXPLAIN (ANALYZE)` on the batch sent statement against a migrated development database with a
32-element pair and confirm the plan is a nested loop probing the primary key once per pair; if
the planner chose anything else, replace the `unnest` join with a loop of single-row fenced
`markSentStmt` calls inside the same finalization transaction (identical correctness, one
statement per row) and record that in the Decision Log. Then commit.

### Milestone 3: operators, documentation, changelogs, report status, ADR

At the end of this milestone every place that describes finalization describes the fence,
operators can see the generation, the changelogs carry the unreleased entries, BUG-5 is
`fixed`, and a new ADR records the decision.

In `keiro-ops/src/Keiro/Ops/Outbox.hs`, add `"claim_generation" .= unClaimGeneration
row.claimGeneration` to `outboxJson` (define `unClaimGeneration` as the newtype's field
accessor in `Types.hs` if you did not already). Leave the human-readable columns as they are.
In `keiro-ops/test/Main.hs`, extend "filters and renders rejected rows with bounded audit
fields" to assert `KeyMap.lookup "claim_generation" row` is `Just (Aeson.Number 1)`, since
the row was claimed exactly once. Run `cabal test keiro-ops-test`.

In `docs/user/outbox.md`, add a subsection `## Claim fencing` after `## Maintenance` that
explains, in plain words, that a claim carries a generation, that every finalization must
present it, and that a publisher whose row was reclaimed and re-claimed changes nothing when
it finally reports; state the deployment consequence, that the fence protects only publishers
running this version, so during a rolling upgrade a still-running older publisher can still
overwrite a newer claim, exactly as before the fix, until every publisher is upgraded; and
state that migration `0033` must be applied before starting upgraded publishers, which the
startup handshake enforces. Add one sentence to the paragraph beginning "The callback still
has at-least-once semantics" saying that a callback that outlives its claim is finalized by
nobody and its row is owned by the newer claim. In `docs/user/api-reference.md`, update the
`Keiro.Outbox` paragraph: `markOutboxSent` and the transactional marks take an `OutboxClaim`,
and list `ClaimGeneration`, `OutboxClaim`, and `outboxClaim`. In
`docs/guides/integration-events-with-kafka.md`, extend step 3's sentence about
`outboxMaintenancePass` with a clause saying a publisher that resumes after reclamation
cannot finalize the newer claim. Log the user bundle once and the guides bundle once with
`okf log add`, then run `just user-documentation-validate`. In
`docs/capabilities/transactional-outbox.md`, add to the Limits list a bullet stating that
finalization is fenced by claim generation and a stale publisher's report is discarded; log
the capabilities bundle and run `just capabilities-validate`.

Write the changelog entries under `## [Unreleased]`. Root `CHANGELOG.md`: a Bug Fixes entry
for BUG-5 naming the migration and the API change, and a Breaking Changes entry that
`OutboxRow` gains `claimGeneration` and the finalization functions take `OutboxClaim`, with
the same mixed-version note as the docs and the composed plan growing from 44 to 45 entries.
`keiro/CHANGELOG.md`: the same two entries scoped to the package. `keiro-migrations/CHANGELOG.md`:
a New Features entry for `0033.sql`, in the style of the `0032.sql` entry under 0.16.0.0.
`keiro-ops/CHANGELOG.md`: an Other Changes entry for the JSON field.

Move BUG-5 to its terminal state: `status: fixed`, `fixedVersion: unreleased`, a
`resolution` block summarising the fence in two sentences, `generated.at` advanced, and a
log line. Run `just bug-reports-validate`.

Distill the decision into an ADR. Allocate the handle with `okf id next docs/adr --profile
docs/adr/profile.dhall ADR` (it returned `ADR-49` on 2026-09-30; use whatever it returns when
you run it) and create `docs/adr/00NN-outbox-finalization-is-fenced-by-claim-generation.md`
with the same frontmatter fields as ADR-39 (`type`, `title`, `description`, `timestamp`,
`docId`, `status: Accepted`, `date`, `originatingPlan` pointing at this plan). Its Context
summarises BUG-5; its Decision states the generation column, the claim-presenting
finalization contract, the no-bump-on-requeue rule, and the mixed-version consequence; its
References cite ADR-37, ADR-39, and this plan. Add one line to `docs/adr/log.md` with
`okf log add docs/adr --kind Added -m "..."` and run `just adr-validate`. Commit.

### Milestone 4: release gate and follow-ups

Run `just verify` from the repository root. It stops at the first failing recipe, so read
the exit code from the end of the captured log rather than from the terminal scrollback, fix
anything it surfaces, and rerun until it completes. Record the final run in Outcomes &
Retrospective, then record the one follow-up this plan does not own: after the next lockstep
release reaches Hackage, Kenshou needs a cohort that pins it, a rerun of
`keiro/outbox/concurrency/zombie-publisher-finalization` in all three `outbox.zombie-outcome`
arms, and removal of the `knownDefect` field from `zombiePublisherFinalization` in
`kenshou-keiro/src/Kenshou/Suite/Keiro/Outbox/Concurrency.hs` under
`mori://shinzui/keiro-runtime-kenshou` once `stale-finalization-no-effect` and
`terminal-consistent-with-success` pass. That work belongs to Kenshou and is not part of
this plan's acceptance.


## Concrete Steps

Every command runs from `/Users/shinzui/Keikaku/bokuno/keiro` (the repository root). Every
commit carries the trailers below; add `Intention:` on every commit because this plan has an
intention.

```text
ExecPlan: docs/plans/299-fence-outbox-finalization-by-claim-generation-to-fix-bug-5.md
Intention: intention_01m3sy10ckeb192fr2m3d8s7hx
```

Milestone 0. Edit `keiro/test/Main.hs` as described, then run only the new examples:

```bash
cabal test keiro-test --test-show-details=direct --test-options='--match "stale publisher"'
```

Expect two failures on the current tree, shaped like:

```text
  1) Keiro.Outbox a stale publisher's late failure mark cannot change a claim reclaimed by maintenance
       expected: Nothing
        but got: Just OutboxFailed
```

Edit the report, log, validate, and commit:

```bash
okf log add docs/bug-reports --kind Update -m "BUG-5 is confirmed by an in-repository reproduction and tracked by ExecPlan 299."
just bug-reports-validate
git add keiro/test/Main.hs docs/bug-reports
git commit -m "test(outbox): reproduce stale publisher finalization of a reclaimed claim" -m "Two examples realise the BUG-5 schedule in one process and fail on the current tree." -m "ExecPlan: docs/plans/299-fence-outbox-finalization-by-claim-generation-to-fix-bug-5.md" -m "Intention: intention_01m3sy10ckeb192fr2m3d8s7hx"
```

Milestone 1. Create and check the migration, lock it, regenerate the snapshot, update the
tests and README, run the suite, and commit:

```bash
cabal run keiro-migrate -- new --manifest keiro-migrations/migrations/manifest --description "fence outbox finalization with a claim generation"
# edit keiro-migrations/migrations/0033.sql
cabal run keiro-migrate -- check --manifest keiro-migrations/migrations/manifest
shasum -a 256 keiro-migrations/migrations/0033.sql | sed 's#keiro-migrations/migrations/##' >> keiro-migrations/migrations.native.lock
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test --test-show-details=direct --test-options='--match "checked-in snapshot"'
git diff keiro-migrations/expected-schema/native/keiro-v18.txt
# edit keiro-migrations/test/Main.hs and keiro-migrations/README.md
cabal test keiro-migrations-test --test-show-details=direct
git add keiro-migrations
git commit -m "feat(migrations): add outbox claim_generation column (0033)" -m "ExecPlan: docs/plans/299-fence-outbox-finalization-by-claim-generation-to-fix-bug-5.md" -m "Intention: intention_01m3sy10ckeb192fr2m3d8s7hx"
```

The snapshot diff must be exactly:

```diff
+column	keiro_outbox.claim_generation	bigint not null default 0
+constraint	keiro_outbox.keiro_outbox_claim_generation_not_null	NOT NULL claim_generation
```

Milestone 2. Edit the three library modules and the test file, then:

```bash
cabal build all
cabal test keiro-test --test-show-details=direct --test-options='--match "Keiro.Outbox"'
cabal test keiro-test
just bench-regression
git add keiro
git commit -m "fix(outbox): fence finalization by claim generation" -m "A publisher whose claim was reclaimed by maintenance and re-claimed can no longer change the newer claim. Finalization functions take an OutboxClaim and match the row's current generation." -m "ExecPlan: docs/plans/299-fence-outbox-finalization-by-claim-generation-to-fix-bug-5.md" -m "Intention: intention_01m3sy10ckeb192fr2m3d8s7hx"
```

The benchmark step prints one line per scenario. The three outbox lines must end with
`same as baseline` or a `faster than baseline` note; a line ending in `slower than baseline`
beyond the threshold makes the recipe exit nonzero, and the plan's Milestone 2 text says what
to do then. The expected shape is:

```text
  outbox
    hot-key:           OK
      ... (same as baseline)
    hot-key-nolatency: OK
      ... (same as baseline)
    multi-key:         OK
      ... (same as baseline)
```

Milestone 3. Edit, log, validate, and commit in one or two commits:

```bash
cabal test keiro-ops-test
okf log add docs/user --kind Update -m "Document outbox claim fencing, the OutboxClaim finalization API, and the mixed-version rollout window."
okf log add docs/guides --kind Update -m "Note that a publisher resumed after reclamation cannot finalize the newer outbox claim."
okf log add docs/capabilities --kind Update -m "CAP-9 records claim-generation fencing of outbox finalization."
just user-documentation-validate
just capabilities-validate
okf log add docs/bug-reports --kind Update -m "BUG-5 is fixed on master by ExecPlan 299; fixedVersion is unreleased until the next lockstep release."
just bug-reports-validate
okf id next docs/adr --profile docs/adr/profile.dhall ADR
# create the ADR file
okf log add docs/adr --kind Added -m "Record that outbox finalization is fenced by claim generation (BUG-5)."
just adr-validate
git add -A
git commit -m "docs(outbox): document claim fencing, close BUG-5, and record the ADR" -m "ExecPlan: docs/plans/299-fence-outbox-finalization-by-claim-generation-to-fix-bug-5.md" -m "Intention: intention_01m3sy10ckeb192fr2m3d8s7hx"
```

Milestone 4:

```bash
just verify 2>&1 | tee /tmp/keiro-verify-299.log; echo "exit=${pipestatus[1]}" >> /tmp/keiro-verify-299.log
tail -3 /tmp/keiro-verify-299.log
```

The last line must read `exit=0`.


## Validation and Acceptance

The defect is proven and fixed when the following hold, in order.

Before Milestone 2, the two Milestone 0 examples fail with the outputs shown above, which
demonstrates that the current code lets a stale publisher change a re-claimed row. After
Milestone 2 they pass, and the extended unit-level example shows that each of the five marks
presenting P1's claim returns `False`, `0`, or `Nothing` while the row stays `OutboxPublishing`
with `attemptCount` 2 and `claimGeneration` `ClaimGeneration 2`, and that P2's `markOutboxSent`
returns `True` and the row reaches `OutboxSent`. The three end-to-end arms show P1's pass
summary with `claimed = 1` and every other counter 0, which is the truthful count ADR-25 and
ADR-37 require.

`cabal test keiro-migrations-test` passes with thirty-three native migrations and forty-five
composed entries, the checksum lock example passes, the snapshot example passes without the
regenerate flag, and the `0033` example shows five pre-existing rows at generation 0 and a
refused `NULL`.

`cabal test keiro-test`, `cabal test keiro-ops-test`, and `cabal build all` pass. The ops
JSON example shows `claim_generation` of 1 for a once-claimed row. `just bench-regression`
exits 0, with every outbox scenario within 25% of `keiro/bench/baseline-outbox.csv`, and the
three outbox deltas are recorded in Surprises & Discoveries.

`just user-documentation-validate`, `just capabilities-validate`, `just bug-reports-validate`,
and `just adr-validate` pass after the documentation and record edits. BUG-5 reads
`status: fixed` with `fixedVersion: unreleased`.

`just verify` completes with exit code 0.

To see the fence in a live database rather than a test, migrate any development database
with `cabal run keiro-migrate -- up`, enqueue a row through your service, run one publisher
pass, and inspect it:

```bash
keiro-ops --database-url "$DATABASE_URL" outbox show <OUTBOX_ID> --json
```

The JSON contains `"claim_generation": 1` after the first claim; a maintenance reclaim leaves
it at 1; the next claim shows 2.


## Idempotence and Recovery

All test additions and edits can be repeated; rerunning any `cabal test` command is safe.
The migration is additive and stores a constant default, so PostgreSQL neither rewrites nor
locks the table beyond the brief `ALTER TABLE` lock; applying it twice is prevented by the
migration ledger, which records it once. If the snapshot regeneration produces more than the
two expected lines, your development PostgreSQL differs from the baseline (the snapshot
targets PostgreSQL 18); do not commit the extra lines, fix the environment, and regenerate.
If the checksum lock example fails after an edit to `0033.sql`, delete the last line of
`keiro-migrations/migrations.native.lock` and append the recomputed checksum; before the
migration is released, editing the file is acceptable, but once it ships in a release it must
never change and any correction is a new forward migration.

Rolling back the binary after the migration is safe: 0.19 publishers ignore the column.
Rolling back the migration is unnecessary; if a database must return to the `0032` schema,
`ALTER TABLE keiro.keiro_outbox DROP COLUMN claim_generation` is the inverse, after stopping
publishers built from this plan.

If a Milestone 0 or Milestone 3 bundle edit fails validation, the validator names the
offending field; fix it and rerun `just <bundle>-validate`. `okf log add` appends a line each
time it runs, so do not rerun it after a successful append.

If `just verify` fails midway, read the log for the first failing recipe, fix it, and rerun
the whole recipe; each sub-recipe is itself rerunnable.


## Interfaces and Dependencies

No new package dependencies. Hasql's `E.foldableArray` (already used by `markSentBatchStmt`)
encodes the unnest arrays; `contrazip6` comes from `contravariant-extras`, already a
dependency of `keiro` and already used in `Keiro.Timer.Schema`.

`keiro/src/Keiro/Outbox/Types.hs` exports, in addition to what it exports today:

```haskell
newtype ClaimGeneration = ClaimGeneration {unClaimGeneration :: Int64}
  deriving stock (Generic, Eq, Ord, Show)

data OutboxClaim = OutboxClaim
  { outboxId :: !OutboxId,
    claimGeneration :: !ClaimGeneration
  }
  deriving stock (Generic, Eq, Show)

outboxClaim :: OutboxRow -> OutboxClaim
```

and `OutboxRow` carries `claimGeneration :: !ClaimGeneration`.

`keiro/src/Keiro/Outbox/Schema.hs` exports the same names as today with these signatures
changed:

```haskell
markOutboxSent :: (Store :> es) => OutboxClaim -> UTCTime -> Eff es Bool
markOutboxSentBatch :: (Store :> es) => [OutboxClaim] -> UTCTime -> Eff es Int
markOutboxSentBatchTx :: [OutboxClaim] -> UTCTime -> Tx.Transaction Int
markOutboxRejectedTx :: OutboxClaim -> PublishRejection -> UTCTime -> Tx.Transaction Bool
markOutboxFailedTx :: OutboxClaim -> Text -> Int -> NominalDiffTime -> UTCTime -> Tx.Transaction (Maybe OutboxStatus)
markOutboxSkippedTx :: OutboxClaim -> Text -> UTCTime -> Tx.Transaction Bool
```

`claimOutboxBatch`, `requeueStuckOutbox`, `lookupOutbox`, `listOutbox`, `listStuckOutbox`,
`listSentOutboxGcCandidates`, `countOutboxBacklog`, and `garbageCollectSent` keep their
signatures; rows they return include the generation.

`keiro/src/Keiro/Outbox.hs` keeps its export list; `publishClaimedOutbox`,
`outboxMaintenancePass`, and `OutboxPublishSummary` are unchanged in type.

The schema, after migration `0033`, has on `keiro.keiro_outbox` the column
`claim_generation BIGINT NOT NULL DEFAULT 0`, no new index, and no new constraint other
than the implicit not-null.

`keiro-ops` JSON for an outbox row gains the key `claim_generation` with an integer value.


## Revision Notes

2026-09-30: Added `just bench-regression` to Milestone 2 (Progress, Plan of Work, Concrete
Steps, Validation and Acceptance, Decision Log). The batch sent statement is the only
finalization statement whose plan shape changes (`= ANY` to an `unnest` join), and the
repository already has a baseline-guarded outbox benchmark, so the plan now measures that
change instead of asserting it. Requested by the user after reviewing regression and
performance risk.
