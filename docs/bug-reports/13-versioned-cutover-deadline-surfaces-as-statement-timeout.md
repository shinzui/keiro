---
type: Bug Report
title: A versioned-rebuild cutover deadline can surface as an untyped statement timeout
description: "Under load, resuming a versioned rebuild whose target relations are held past the cutover lock deadline returned UnexpectedServerError 57014 instead of VersionedCutoverDeadlineExceeded, failing a keiro-test fault-injection example."
generated:
  by: process:claude-code
  at: "2026-11-18T23:05:35Z"
bugId: BUG-13
status: confirmed
severity: degraded
origin: mori://shinzui/keiro
affects: mori://shinzui/keiro
affectedVersion: "0.25.1.0"
environment: "keiro master at c27a51a8 (0.25.1.0 sources) in the project Nix shell on macOS, aarch64, GHC 9.12.4, with the local PostgreSQL cluster the dev shell starts. The failure appeared during a full `nix develop -c just verify`, while the machine was also building and running the rest of the repository's test suites."
observed: "keiro-test example \"schema-versioned release fault injection rolls every cutover boundary back to one v1 authority and resumes the same incompatible v2 promotion\" (keiro/test/VersionedRebuildSpec.hs:1109) expected Right (Left (VersionedCutoverDeadlineExceeded (RebuildRunId \"versioned-release-faults\") \"target-relations\")) but got Left (UnexpectedServerError \"57014\" \"canceling statement due to statement timeout\")."
expected: "When the cutover deadline passes while a promotion lock is unavailable, resumeVersionedRebuild should return the typed VersionedCutoverDeadlineExceeded outcome, whatever the machine load, so the run is condemned and rolled back through its documented path rather than reported as an unexpected server error."
reproduction:
  - In the Nix development shell at the repository root, run `nix develop -c just verify`, or otherwise load the machine with concurrent builds and PostgreSQL-backed test suites.
  - Observe keiro-test fail the example above with SQLSTATE 57014. The failure is intermittent; with seed 173243439 it appeared once in three full verify runs.
  - Run the example alone with `nix develop -c cabal test keiro:test:keiro-test --test-options='--match "/schema-versioned release fault injection/rolls every cutover boundary back"'`; on an idle machine it passes (three of three reruns passed).
workaround: "Re-run the failing suite. The example is a fault-injection test with a 100 ms cutover lock deadline; production deadlines are larger, which narrows but does not remove the window."
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-18T23:05:35Z"
    document_timestamp: "2026-11-18T23:05:35Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: "Reporter's evidence check: the failure text is copied from the gate log; the three isolated reruns were run in the same shell; the lock helpers were read in keiro-migrations/migrations/0029.sql and the call sites in keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs. The mechanism is a hypothesis; the failing statement was not captured. This is not independent owner confirmation."
---

# A versioned-rebuild cutover deadline can surface as an untyped statement timeout

This was found while running the repository gate for
[ExecPlan 345](../plans/345-let-integration-contracts-declare-optional-fields-and-an-envelope-discriminator.md),
whose changes do not touch `keiro`, `keiro-core` or `keiro-migrations`. The same example
passed in the full gate runs before and after the failing one.

## Observed behaviour

The fault-injection example sets `cutoverLockTimeoutMs` to 100. It holds ACCESS SHARE
on a target relation for one second from another connection (`SELECT pg_sleep(1)` in a
read transaction), then resumes the rebuild and expects the relation-lock step to give
up with `VersionedCutoverDeadlineExceeded … "target-relations"`. In the failing run, the
resume returned instead:

```text
expected: Right (Left (VersionedCutoverDeadlineExceeded (RebuildRunId "versioned-release-faults") "target-relations"))
 but got: Left (UnexpectedServerError "57014" "canceling statement due to statement timeout")
```

## Suspected mechanism (confirmed in part, see Owner validation)

The three lock helpers in `keiro-migrations/migrations/0029.sql`
(`keiro_try_projection_cutover_fence_v1`, `keiro_try_projection_promotion_lock_v1`,
`keiro_try_projection_relation_locks_v1`) each set both `lock_timeout` and
`statement_timeout` to the time remaining before the deadline with
`set_config(…, true)`. They catch `lock_not_available` and `query_canceled` only
around their own `LOCK` statement.

A transaction-local `statement_timeout` outlives the function that set it. Every later
top-level statement in the same promotion transaction therefore runs under a timeout of
at most the time that remained when the previous helper ran. This includes the reads
between the promotion lock and the relation lock in `Keiro.ReadModel.Rebuild.Versioned`
(for example `loadServingGenerationsStmt` and `loadCandidateGenerations`), and the
top-level `SELECT keiro.keiro_try_projection_relation_locks_v1(…)` itself. If one of
those statements is slowed past that remaining time, PostgreSQL cancels it outside any
handler. The 57014 then reaches the caller as `UnexpectedServerError` instead of being
mapped to the typed deadline outcome. On an idle machine those statements finish in a
few milliseconds, so the lock wait reaches `lock_timeout` first and the test passes.

To confirm, reproduce under load with `log_min_error_statement = error` and record
which statement raised 57014.

## Possible fixes

- Map a `query_canceled` raised while the cutover deadline has passed to
  `VersionedCutoverDeadlineExceeded` for the step in progress.
- Or restore `statement_timeout` after each helper's `LOCK` statement, so that only the
  lock wait is bounded by the deadline and later statements check the deadline
  explicitly.

## Owner validation

Confirmed on 2026-11-19 by the owning repository. The three helpers from migration
`0029` were loaded verbatim into a scratch database on PostgreSQL 18.6 and exercised
with `psql`; the script and transcript are in
[evidence/BUG-13-leaked-cutover-timeouts.txt](evidence/BUG-13-leaked-cutover-timeouts.txt).

- Each helper leaves `statement_timeout` and `lock_timeout` set for the rest of the
  transaction. A later top-level statement that outlasts the leaked value is cancelled
  with 57014 outside any handler.
- The relation-lock statement runs under the timeout leaked by the promotion-lock
  helper. That timer expires later than the lock wait by the time spent between the two
  helpers. If the statement is still running then, it is cancelled after its handler
  has returned.
- The same leak applies after the locks are won, so the renames and metadata updates of
  a successful promotion can be cancelled too. This is the defect already recorded as
  IR-47 (`../improvement-requests/bound-the-versioned-cutover-budget-to-its-guarded-statements.md`).

The gate failure was not re-run under load, and the statement that raised 57014 in that
run was not captured, so which of the first two paths occurred there is not known. The
second "possible fix" above is not sufficient as written: restoring `statement_timeout`
alone lets two contended relations overshoot the budget, because `lock_timeout` restarts
for each lock wait. [ExecPlan 348](../plans/348-bound-versioned-cutover-lock-waits-without-leaking-transaction-timeouts-to-fix-bug-13-and-ir-47.md)
plans the repair.
