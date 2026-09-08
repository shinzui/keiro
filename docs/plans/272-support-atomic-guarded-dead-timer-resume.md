---
id: 272
slug: support-atomic-guarded-dead-timer-resume
title: "Support atomic guarded dead timer resume"
kind: exec-plan
created_at: 2026-09-08T03:44:36Z
intention: "intention_01m1zht8rce25snryjmw85rj10"
---

# Support atomic guarded dead timer resume

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A foreground consumer will be able to resume one deliberately parked timer without replacing its identity or exposing it to the ordinary due-work poller. It will inspect the timer, authorize its original payload, establish session availability, and atomically claim only the expected owner and exact stored reason. Two competing consumers will receive one successful claim and one no-claim result. Expired or superseded claims will be unable to finalize later work.

This addresses the valid request [IR-36](docs/improvement-requests/support-atomic-guarded-dead-timer-resume.md). The companion public inspection API from [plan 270](docs/plans/270-expose-reason-bearing-dead-timer-inspection-and-bounded-reads.md) is already implemented locally. Demonstrate the new behavior through PostgreSQL races and a consumer fixture before coordinating their release. This document plans implementation; no runtime changes or release have been performed by creating it.


## Progress


- [x] (2026-09-08T04:06Z) Implemented guarded claims and all five legacy mutation exclusions. Public-API tests first failed to compile against the missing API; corrected same-database race and guard/preservation tests pass. Generated migration 0032 and native snapshot (only two columns and ownership constraint).
- [x] (2026-09-08T04:08Z) Migration authoring check and all 36 migration examples passed, including fresh install, preceding-version timer upgrade, ownership constraints, immutable checksums, and native schema verification.
- [x] (2026-09-08T04:06Z) Implemented token lifecycle, expiry recovery, and worker integration; 25 focused timer examples passed with zero failures. Added the expired-completion race for the final focused/full rerun.
- [x] (2026-09-08T04:08Z) Implemented public consumer fixture and lifecycle/rollout documentation; allocated ADR-39 with OKF and passed strict profile/log enforcement. IR-36 records implementation with publication/adoption pending.
- [x] (2026-09-08T04:10Z) Expanded focused rerun passed: 36 migration examples and 25 timer examples, including expired completion/recovery. Migration authoring check, final formatting, and aarch64-darwin flake checks passed.
- [ ] Milestone 3 remaining: full workspace verification and source distributions.
- [ ] Milestone 4: Coordinate publication with plan 270 and verify released downstream adoption.


## Surprises & Discoveries


Discovery (2026-09-08 UTC): `withFreshStores2` opens two separate cloned databases, contrary to the original plan. The first test run returned zero recovered rows from the second store. The corrected race fixture uses `withFreshDatabase` once and opens two independent `Store.withStore` pools with that same connection string. Existing cross-context tests retain their separate-database helper.


The enlarged migration suite exhausted GHC's simplifier budget while repeatedly specializing the cold polymorphic `failure` helper (`SPEC failure @DefinitionError @_`). Marking that assertion-only helper NOINLINE allowed the normal optimized build and native snapshot generation to pass; no compiler flag or dependency workaround was introduced.

## Decision Log


Decision (2026-09-08 UTC): Accept IR-36 as actionable. Inspection of `keiro/src/Keiro/Timer/Schema.hs` confirms that `claimDueTimerStmt` selects only scheduled rows and both requeue statements select firing rows. No public dead-to-firing operation exists. `markTimerFiredStmt` checks only ID and firing status, which cannot distinguish an old worker from a newer claim after recovery.

Decision (2026-09-08 UTC): Add a separate token-bearing claim wrapper and expiring foreground ownership, leaving `TimerRow` and existing function signatures source-compatible. A token is an opaque random UUID identifying one claim, not an authorization credential. All existing ID-only timer mutation paths must exclude token-bearing claims. This prevents stale ordinary workers from mutating a foreground claim without requiring an unrelated redesign of every ordinary timer worker.

Decision (2026-09-08 UTC): Expired foreground claims return directly to Dead, preserving the original deferred reason. They do not pass through Scheduled. This is a stronger recovery contract than relying on a background worker to reclaim and park the work, and avoids background attempt consumption. Foreground consumers run public recovery before discovery/resume; ordinary worker passes also perform it. Existing recovery behavior remains unchanged for ordinary token-free claims.

Decision (2026-09-08 UTC): Every successful foreground claim increments the existing attempts count once. Require an explicit maximum total attempts, checked atomically before increment. Refused claims and preflights consume zero. Never silently reset history; an operator-approved higher ceiling is an explicit caller policy choice. After a transient failure, park the claim again with the original reason and its increment retained.

Decision (2026-09-08 UTC): Keep application permissions, reason classification, external execution cancellation, and idempotent result writes in the consumer. Storage ownership prevents stale database transitions; it cannot stop an external action already running when a lease expires. Do not describe this as exactly-once AI execution.


Decision (2026-09-08 UTC): Use two statements in each ReadCommitted ownership transaction: row locking first, then guarded mutation and database time. Recovery locks candidate IDs in UUID order and rechecks only those locked IDs. Validate lease seconds in the positive Int32 range (1–2147483647), which PostgreSQL can safely convert to seconds without overflow.

## Outcomes & Retrospective


The guarded storage API, forward migration, public consumer fixture, lifecycle documentation, and ADR-39 are implemented. The focused timer suite passed 25 examples; final expanded focused and full repository checks are in progress. Publication and actual downstream adoption remain incomplete. The downstream plan still describes the foreground core/CLI fixture as unimplemented; local synthetic evidence cannot replace that gate.


## Context and Orientation


Keiro is a Haskell multi-package repository built with Cabal, with PostgreSQL integration tests and a Nix development environment. `keiro/src/Keiro/Timer.hs` is the public facade and implements `runTimerWorkerWith`, `timerPassPreamble`, and `claimAndFireOne`. `keiro/src/Keiro/Timer/Schema.hs` defines the persisted row, inspection types, Hasql statements, and storage operations. `keiro/src/Keiro/Timer/Types.hs` defines timer IDs and scheduling requests.

A timer is one row in `keiro.keiro_timers`. Scheduled means eligible for the due poller; Firing means claimed; Fired means completed; Cancelled means withdrawn; Dead means parked or abandoned with nullable `last_error`. The existing due claim increments attempts and refreshes `updated_at`. The ordinary worker checks its optional retry ceiling after claiming. Its default recovery moves firing rows older than 300 seconds back to scheduled. These are at-least-once semantics: crashes or long-running callbacks can produce duplicate external effects.

`TimerRow` contains ID, process-manager name (the consumer ownership label), correlation ID, original due time, payload, status, attempts, and optional fired event ID. `TimerInspection` wraps this row and its nullable stored reason. Plan 270 preserves the distinction between NULL and empty text, and matches exact owner/reason using deterministic C collation. Reuse those semantics, but require a non-null exact reason and a mandatory owner for resume. Prefix or wildcard matching is unsuitable for a mutation.

`keiro/test/Main.hs` has the `Keiro.Timer` examples, `counterTimerRequest`, and `dueTimerTime`. `keiro-test-support/src/Keiro/Test/Postgres.hs` provides migrated ephemeral PostgreSQL databases and `withFreshDatabase`. Open two independent `Store.withStore` pools against its single connection string for real concurrent claims. `withFreshStores2` instead creates separate databases and must not be used for these races. Test-only SQL may create an expired lease or compare private columns; consumer-facing fixtures must use the public facade.

Native SQL migrations live in `keiro-migrations/migrations/`, whose `manifest` currently ends at `0031.sql`. `keiro-migrations/migrations.native.lock` records ordered SHA-256 hashes. `keiro-migrations/test/Main.hs` verifies membership, hashes, and the PostgreSQL 18 expected schema. `docs/user/migrations.md` explains the authoring command and snapshot regeneration. Never change an applied migration or the frozen legacy Codd history.

[ADR-7](docs/adr/0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md) makes sleep timers belong to the workflow generation that armed them. Preserve their payloads, insert-only scheduling, journal append behavior, and garbage collection. [ADR-9](docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) requires migration ledger, native manifest/hash, and live-schema gates independently. [ADR-28](docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md) requires consumers to use schema-owner APIs and leaves application authorization in the consumer. No existing ADR supplies foreground timer claim fencing, meaning rejection of writes from an obsolete owner. Record that durable decision during implementation. Before editing ADRs run `mori show --full`, inspect the declared `docs/adr/profile.dhall`, and follow its metadata and log contract.

Dependency discovery through Mori located `mori://shinzui/kiroku/packages/kiroku-store`. Its public `Kiroku.Store.Transaction.runTransaction` executes pure Hasql transactions at ReadCommitted isolation with retry on serialization conflicts. Use the existing statement/encoder/decoder patterns; never perform an external AI action inside a retried transaction. No dependency bound change is proposed. If additional APIs are needed, locate their sources with `mori registry search`, `mori registry show --full`, and `mori registry docs` before using them.

On 2026-09-08 UTC, Hackage preferred metadata reported 0.15.0.0 as the latest normal Keiro version, and upstream tag `keiro-0.15.0.0` peeled to `de574cdcb0add3fefbb0fdd96d820258d15f8997`. This is a verified baseline, not the future release number. The originating consumer work is `mori://shinzui/kioku/plans/41-configure-all-kioku-ai-features-through-baikai-and-honor-host-execution-policy`. Mori did not resolve that plan during creation; retain its intended canonical URI. A local synthetic consumer test is not evidence of released downstream adoption.


## Plan of Work


### Milestone 1: Add guarded claims and protect them from ordinary mutations


Add one forward migration with nullable `resume_claim_token UUID` and `resume_lease_until TIMESTAMPTZ` columns on `keiro.keiro_timers`. Add a constraint requiring both to be NULL together or both non-NULL with status firing. Existing rows receive NULLs, without changes to identity, due time, payload, reason, or attempts. Register the generated migration, append its SHA-256 entry using the existing lockfile format, and regenerate only the native expected schema. Do not hand-select a migration number.

Implement the public types and claim operation specified below in Schema, re-exported by Timer. Generate a fresh UUID outside the transaction using the repository's existing UUID generation pattern. Validate positive lease seconds and nonnegative maximum attempts before database access. Acquire the target row lock before deciding eligibility and computing database time; compare ID, Dead status, mandatory owner and exact non-null reason, and attempts strictly below the requested maximum. Perform the guarded UPDATE and RETURNING in the same transaction. Use database `clock_timestamp()` after lock acquisition for the lease start and `updated_at`; client-supplied clocks must not govern ownership. Under ReadCommitted the loser must recheck eligibility after waiting and return no claim, not replay a stale read.

On success set Firing, increment attempts once, store token and lease deadline, and return the row and opaque claim handle. Preserve `last_error` as the reason to restore on parking/recovery. No-match leaves every persisted column unchanged. Missing ID, wrong state, wrong owner/reason, and exhausted ceiling all produce `Right Nothing`; configuration errors are distinct. Do not leak existence through differentiated refusal reasons.

In the same milestone, exclude non-NULL resume tokens from `markTimerFiredStmt`, `cancelTimerStmt`, `deadLetterTimerStmt`, `requeueStuckTimerStmt`, and `requeueStuckTimersStmt`. Audit all timer SQL writers with `rg -n 'UPDATE .*keiro_timers|DELETE FROM .*keiro_timers' keiro`; scheduled-only operations already exclude Firing, while workflow garbage collection remains deliberate lifecycle deletion under ADR-7. Document that ID-only administrative operations return False on guarded claims. These guards are required even when callers should use the new API: an ordinary worker may still hold this ID from before it became Dead.

At this milestone the schema checks, claim refusal/preservation tests, two-store race, and legacy-mutation exclusion tests must pass. Lease lifecycle operations follow immediately in milestone 2; do not release the partial API.


### Milestone 2: Complete ownership, expiry, and recovery


Implement completion, renewal, parking, and cancellation requiring an opaque claim handle. Each operation locks the row and then verifies matching ID/token, firing state, and an unexpired deadline using database time. Completion sets Fired and the event ID. Cancellation sets Cancelled. Parking sets Dead and leaves `last_error` unchanged. Terminal and parking transitions clear both ownership columns and refresh `updated_at`. Renewal extends the deadline from database time using a validated positive interval; it must never revive an expired token. Each refused operation returns False without changing attempts or timestamps.

Implement `recoverExpiredTimerResumes` to atomically return expired guarded Firing rows to Dead, clear ownership fields, preserve all original metadata and reason, and leave attempts unchanged. Recovery and renewal must lock/recheck the same row predicates so a renewal that wins prevents premature recovery and recovery that wins prevents renewal. An old handle cannot complete, park, cancel, or renew after the row is claimed again, even with the same reason. A new token is issued for every claim.

Call this dedicated recovery in `timerPassPreamble` independently of the ordinary `requeueStuckAfter` option, and document that difference. The option still controls only ordinary stale claims. Keep its existing requeued metric specific to rows made Scheduled; do not report a foreground re-park as a due requeue. Foreground-only hosts must also call recovery periodically and before listing/resuming, so they do not depend on a background worker to release expired claims.

Document the complete consumer lifecycle: preflight authorization and availability before claim; execute only after successful claim; renew during long work; complete with the resulting event ID; park on transient failure or session loss after stopping local work; cancel on explicit abandonment; allow expiry recovery after process crash. A post-claim failure has already consumed one attempt, even if session availability disappears immediately. At the ceiling, leave the row parked; no retry resets history. If renewal or completion returns False, treat ownership as lost, cancel local work where possible, and do not report successful timer completion. External effects still require a stable idempotency key derived from the original work identity and caller-owned result deduplication.

Run lease/recovery and old-token races plus existing timer, sleep, and worker regression tests. The observable result is one currently valid storage owner, eventual re-parking after expiry, and no stale handle able to alter a replacement claim.


### Milestone 3: Prove the public consumer contract and document compatibility


Add a consumer fixture to `keiro/test/Main.hs` importing the new surface only from `Keiro.Timer`. Use a synthetic memory-space payload and application-owned authorization/session checks. Inspect the stored reason, decode original work, recheck authorization, establish session availability, then claim using that exact reason and owner. Refuse malformed work and ordinary dead letters. Revocation between listing and preflight must cause no mutation; repeated unavailable-session preflights must consume zero attempts. Race two authorized resumes and count callback executions: one for the contested claim. Simulate crash, recover, deny background interactive availability, and demonstrate that the same ID stays parked until an authorized foreground resume.

Update `docs/user/process-managers-and-timers.md`, the module Haddocks, `docs/capabilities/process-managers-routers-timers.md`, and root `CHANGELOG.md`. Explain retry ceilings, original reason retention, NULL refusal, lease renewal, recovery scheduling, stale-owner rejection, and the at-least-once external execution limit. Existing `TimerRow`, `TimerInspection`, worker callback, and ID-only function signatures remain unchanged, but the exclusion of guarded rows and independent expired-resume recovery are intentional behavioral changes. Preserve existing ordinary claim accounting and dead-letter regressions. Compile all packages and generated timer consumers to prove source compatibility.

Create an ADR for foreground claim ownership, lease expiry, recovery-to-Dead, and the consumer boundary. Allocate its stable ID with OKF after inspecting the profile; do not guess an ADR number. Update bundle timestamps and logs through their established tooling. Record implementation evidence and this plan link in IR-36, leaving release/adoption incomplete. Run the full verification gate once the focused checks pass.


### Milestone 4: Release with IR-35 and record downstream adoption


Recheck Hackage and upstream tags before choosing a shared PVP release version. Follow `agents/skills/release/SKILL.md` at release time for package order, source distributions, documentation, and publication checks. Coordinate with the open release steps in plan 270 so one adopted release supplies both reads and claims. This plan's creation does not publish packages.

Deploy the migration and upgrade all timer-mutating processes before enabling foreground resume. Old binaries do not contain the token exclusion predicates, so mixed-version timer writers would invalidate the new guarantee. State this rollout requirement in release notes; do not advertise the additive database columns as safe mixed-writer compatibility. Drain or stop old workers, apply migrations, deploy upgraded workers, then enable the consumer feature. A rollback must first disable resume and drain or recover all guarded claims before an older writer can run.

Resolve the consumer repository through Mori, inspect its current instructions, and run its actual foreground policy fixture using released package bounds and no local source override. Record the exact release/tag, Hackage availability, build bounds, fixture command/results, and canonical downstream artifact reference. Host acceptance in the downstream plan remains an explicit gate. If publication or downstream validation cannot yet happen, retain unchecked completion work and do not mark IR-36 or this plan fully delivered.


## Concrete Steps


Run commands from the Keiro repository root. Prefix Cabal commands with `nix develop -c` if the Haskell/PostgreSQL environment is not already active. Do not inspect or traverse `/nix/store`. First add unchecked implementation steps to Progress, then record timestamps and results as they finish. Use the initializer only for new plans, not to recreate this file.

```bash
pwd
git status --short
rg -n 'keiro_timers|claimDueTimer|markTimerFired' keiro/src/Keiro/Timer.hs keiro/src/Keiro/Timer/Schema.hs
cabal test keiro-test --test-show-details=direct --test-options='--match "Keiro.Timer"'
cabal run keiro-migrate -- new --manifest keiro-migrations/migrations/manifest --description "add guarded timer resume leases"
```

Read the generated SQL path from the authoring command. Edit it, append its hash to `keiro-migrations/migrations.native.lock` in that file's existing format, then run:

```bash
cabal run keiro-migrate -- check --manifest keiro-migrations/migrations/manifest
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test --test-options='--match "checked-in snapshot"'
cabal test keiro-migrations-test --test-show-details=direct
cabal test keiro-test --test-show-details=direct --test-options='--match "Keiro.Timer"'
cabal test keiro-test --test-show-details=direct
cabal build all
```

Expected results are successful migration checks, reviewed additions only in the expected-schema diff, and Hspec summaries with zero failures. Add the new public-API tests first so the missing API is demonstrable before implementation. Use synchronization barriers and separate stores for races, not arbitrary sleeps. Test-only lease expiry updates should make recovery tests deterministic.

Before ADR edits inspect the manifest and profile, then allocate and validate:

```bash
mori show --full
dhall --file docs/adr/profile.dhall
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add --help
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix fmt
nix flake check
nix develop -c just verify
git diff --check
```

Use the installed `okf log add` syntax to record meaningful ADR revisions before strict validation. Run workspace builds and checks serially: plan 270 recorded Cabal configuration interference when they shared a build directory concurrently. At release preparation, verify the moving baseline:

```bash
curl -fsSL https://hackage.haskell.org/package/keiro/preferred.json
git ls-remote --tags origin 'keiro-*'
```

Commits during implementation use Conventional Commits and both trailers:

```text
feat(timer): add guarded foreground resume ownership

ExecPlan: docs/plans/272-support-atomic-guarded-dead-timer-resume.md
Intention: intention_01m1zht8rce25snryjmw85rj10
```


## Validation and Acceptance


Against one eligible Dead row, race two independent connections using a start barrier. Exactly one returns a claim and one returns no claim. The due poller returns Nothing for that row both during the claim and after foreground expiry recovery returns it to Dead. Repeat after recovery to prove a fresh token is issued, without claiming exactly-once execution across different claims.

For missing ID, wrong owner, wrong reason, NULL reason, every non-Dead status, exhausted ceiling, and a repeated claim, compare complete persisted state before and after and require no change. Include empty reason, Unicode, case differences, and literal percent/underscore/backslash values. Reject invalid lease/ceiling options before any mutation. On success assert all identity/work fields, original due time and reason survive, attempts equals previous attempts plus one, and recovery timestamps are refreshed. At attempts equal to the ceiling, refuse; at ceiling minus one, allow exactly one claim.

Prove completion, cancellation, and parking require a current unexpired token. Capture handle A, expire/recover/reclaim as B, then try every A operation and every legacy ID-only mutation: all must fail without modifying B. Race renewal versus recovery and completion versus recovery; assert only a valid ordered outcome and no two valid owners. Expired claims cannot be renewed even before a recovery sweep. Ordinary worker recovery must never move guarded work to Scheduled. Existing ordinary retry-ceiling, stale-firing, cancellation, dead-letter, workflow sleep generation, and batched drain examples must continue passing.

The public consumer fixture must show revoked permissions and unavailable sessions leave parked state and attempts unchanged, one contested claim invokes one callback, transient failure preserves incremented history, and crash recovery restores the original parked reason and ID. This proves a local integration contract; full acceptance additionally requires tagged Hackage publication with IR-35 and the downstream released-bound fixture and host evidence described in milestone 4.


## Idempotence and Recovery


Repeated refused claims or stale-handle operations are no-ops. Recovery is repeatable because only expired token-bearing Firing rows match. Renewals change the deadline only for the current unexpired owner. A successful claim is not repeatable with the same result: retry after an ambiguous connection failure must inspect/recover rather than assume ownership, because the first transaction may have committed without delivering its token.

Do not undo migrations by editing applied SQL or deleting ledger records. Use isolated ephemeral databases for race and upgrade tests, and add a forward repair migration for a published schema defect. Existing rows migrate with NULL ownership columns. Validate both fresh install and upgrade from the preceding migration with representative scheduled/firing/dead rows. Production activation and rollback must respect the no-old-writers boundary in milestone 4.

A database lease is time-limited permission to mutate the timer, not a mechanism that forcibly terminates external processes. Consumers must cancel work when ownership is lost and deduplicate durable external results. Recovery can make another claim valid while an old external call is still returning; tests and docs must distinguish this from overlapping valid database owners.


## Interfaces and Dependencies


Add the following conceptual public surface in `keiro/src/Keiro/Timer/Schema.hs` and re-export it from `keiro/src/Keiro/Timer.hs`. Keep claim-handle constructors private; provide the row and deadline accessors. The internal handle contains TimerId and UUID token. Use existing `Store`, Hasql, UUID, Text, and time dependencies; add no dependency or dependency-bound workaround without Mori discovery and registry/tag verification.

```haskell
data DeadTimerClaimRequest = DeadTimerClaimRequest
  { timerId :: !TimerId,
    processManagerName :: !Text,
    expectedReason :: !Text,
    maxAttempts :: !Int,
    leaseSeconds :: !Int
  }

data TimerResumeError
  = InvalidTimerResumeMaxAttempts !Int
  | InvalidTimerResumeLeaseSeconds !Int

data TimerResumeClaim -- opaque; contains row, token, and returned deadline

resumeClaimTimer :: TimerResumeClaim -> TimerRow
resumeClaimLeaseUntil :: TimerResumeClaim -> UTCTime

claimDeadTimer ::
  (IOE :> es, Store :> es) =>
  DeadTimerClaimRequest -> Eff es (Either TimerResumeError (Maybe TimerResumeClaim))

renewTimerResume ::
  (Store :> es) =>
  TimerResumeClaim -> Int -> Eff es (Either TimerResumeError Bool)

completeTimerResume ::
  (Store :> es) => TimerResumeClaim -> EventId -> Eff es Bool

parkTimerResume ::
  (Store :> es) => TimerResumeClaim -> Eff es Bool

cancelTimerResume ::
  (Store :> es) => TimerResumeClaim -> Eff es Bool

recoverExpiredTimerResumes :: (Store :> es) => Eff es Int
```

The returned lease deadline is the claim-time snapshot; renewal success preserves the same token and the database holds the updated deadline. Document that callers schedule renewals by their requested interval and must not use the snapshot as current lease truth. Configuration errors remain values; database failures use the existing Store error channel. `maxAttempts = 0` is valid and always refuses a claim; negative values are invalid. Lease seconds must be positive and encoded with a checked representation that cannot overflow during conversion to a PostgreSQL interval.

Ordinary timer APIs keep their signatures and token-free behavior. Their mutable operations explicitly exclude active guarded claims. No Kioku-specific reason parsing, permission schema, UI, or AI execution engine belongs in these interfaces.

Revision (2026-09-08 UTC): Started implementation and corrected the shared-database race fixture after inspecting its implementation and observing the initial recovery failures. Lease seconds are checked against positive Int32 seconds to avoid interval overflow.
