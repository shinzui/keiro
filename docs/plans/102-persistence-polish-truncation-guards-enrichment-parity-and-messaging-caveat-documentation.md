---
id: 102
slug: persistence-polish-truncation-guards-enrichment-parity-and-messaging-caveat-documentation
title: "Persistence polish: truncation guards, enrichment parity, and messaging caveat documentation"
kind: exec-plan
created_at: 2026-07-12T05:07:53Z
intention: intention_01kxcz37ave9t8d6amvvxnemr6
master_plan: "docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md"
---

# Persistence polish: truncation guards, enrichment parity, and messaging caveat documentation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan closes out the "persistence polish" findings from the July 2026 correctness review of keiro's storage paths (the parent MasterPlan is `docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`). Three things change, each observable by a user of the library.

First, an operator who truncates an event stream in the database without having written a covering snapshot can today make keiro silently reconstruct a **wrong aggregate state** — the command runner replays whatever suffix of events the store returns and never checks that the suffix starts where its seed ended. After this plan, that situation is caught deterministically: hydration fails with a new, typed `HydrationGapDetected` error naming the stream version it expected and the version it actually saw, and the operational precondition ("truncation requires a covering snapshot") is documented where operators will find it.

Second, kiroku (the PostgreSQL event store keiro builds on) supports an `enrichEvent` hook that stamps every appended event with, for example, trace context or PII-handling metadata. Today the hook fires only on keiro's *plain* command path; the transactional path that projections, process managers, and routers are built on bypasses it, so half of an application's events silently lack the enrichment. After this plan both append paths enrich identically, proven by a test that runs both paths under a marker-stamping hook and asserts the persisted metadata matches.

Third, a bundle of sharp-edged behaviors that the review verified but that are documented incompletely or not at all — the inbox garbage collector reopening the deduplication window, the outbox's best-effort per-key ordering under concurrent inline enqueues, and the fact that SQL run in a `runCommandWithSqlEvents` callback extends the store-wide append serialization window — get accurate Haddock and user-guide text at the exact functions and pages a consumer reads.

To see it working after implementation: run `cabal test keiro-test` from the repository root and observe the new truncation-gap, covering-snapshot, and enrichment-parity examples pass; truncate a stream by hand without a snapshot and watch the next command fail loudly with `HydrationGapDetected` instead of committing an event computed from a wrong state.


## Progress

- [x] (2026-07-13 12:14 PDT) Milestone 1: `HydrationGapDetected` constructor added to `CommandError` with a `commandErrorClass` arm.
- [x] (2026-07-13 12:14 PDT) Milestone 1: contiguity guard implemented in EP-95's shared page-oriented hydration input pipeline in `keiro/src/Keiro/Command.hs`.
- [x] (2026-07-13 12:14 PDT) Milestone 1: red-then-green test — truncation without covering snapshot yields `HydrationGapDetected` (full-hydration path).
- [x] (2026-07-13 12:14 PDT) Milestone 1: red-then-green test — mid-batch truncation (multi-event command) yields `HydrationGapDetected`.
- [x] (2026-07-13 12:14 PDT) Milestone 1: positive test — truncation with a covering snapshot hydrates and appends normally.
- [x] (2026-07-13 12:14 PDT) Milestone 2: `KirokuStoreResource` constraint added to `runCommandWithSqlEvents` / `runCommandWithSql` and propagated through projections, process managers, routers, and their workers.
- [x] (2026-07-13 12:14 PDT) Milestone 2: `enrichEventsIO` wired before `prepareEventsIO` in `appendWithSqlOnce`.
- [x] (2026-07-13 12:14 PDT) Milestone 2: `withFreshResourceStore` fixture added to `keiro-test-support` and affected existing tests migrated.
- [x] (2026-07-13 12:14 PDT) Milestone 2: red-then-green enrichment-parity test proves both runner paths and callback records carry the hook's marker.
- [x] (2026-07-13 12:14 PDT) Milestone 2: in-repo `jitsurei` worked example compiles again (mechanical wiring only).
- [x] (2026-07-13 12:14 PDT) Milestone 2: CHANGELOG "Breaking Changes" entry written.
- [x] (2026-07-13 12:24 PDT) Milestone 3: truncation precondition documented (Command.hs module Haddock, `docs/user/operations.md`, `docs/user/snapshots.md`).
- [x] (2026-07-13 12:24 PDT) Milestone 3: inbox GC / dedup-window caveats on `Keiro.Inbox` module header and GC/insert Haddocks.
- [x] (2026-07-13 12:24 PDT) Milestone 3: outbox ordering caveat surfaced on `enqueueOutboxTx` and `enqueueProducerEventTx`.
- [x] (2026-07-13 12:24 PDT) Milestone 3: `$all` lock-window operational note on `runCommandWithSqlEvents` / `runCommandWithSql` Haddock.
- [x] (2026-07-13 12:24 PDT) Milestone 3: stale-docstring sweep in scope-owned modules (Command.hs detached comment removed).
- [x] (2026-07-13 12:24 PDT) Full required suite green: `cabal build all` and `cabal test keiro-test` pass (335 examples, 0 failures).


## Surprises & Discoveries

- EP-95 already replaced the authored duplicate hydration folds with one
  page-oriented `hydrateSeeded` function around `Keiki.replayEvents`. The
  contiguity guard therefore belongs in that shared input pipeline, with a
  pending error after the valid prefix so an earlier replay failure still wins.
  This is the integration outcome anticipated by the original EP-95 merge note.
- The red truncation run on 2026-07-13 proved both error shapes. An uncovered
  counter suffix silently appended version 4, while truncating inside the
  two-event command batch returned
  `HydrationReplayFailed (StreamVersion 2) HydrationNoInvertingEdge` instead of
  identifying the storage gap. The covering-snapshot control passed.
- Kiroku 0.3 already exports `runTransactionAppendingResource`, but that
  wrapper supplies only `AppendResult` to its continuation. Keiro must retain
  its lower-level `appendToStreamTx` path because
  `runCommandWithSqlEvents` reconstructs the exact persisted
  `RecordedEvent`s for projections and routers; explicit `enrichEventsIO`
  before `prepareEventsIO` preserves both requirements.
- The resource constraint propagates beyond the four public runners named in
  the authored plan: live process-manager/router workers and the two in-repo
  Jitsurei process-manager wrappers also transit those runners. The compiler
  enumerated these mechanical additions; the library, demo executable, Keiro
  test suite, and Jitsurei test suite all compile with the resource stack.
- The enrichment regression test was made red by temporarily preparing the
  original un-enriched batch. It failed on transactional metadata containing
  only `schemaVersion`; restoring the enriched batch made the same focused run
  pass, including the callback `RecordedEvent` assertion.
- The documentation sweep confirmed that the outbox module header and
  `enqueueIntegrationEventTx` already had the ordering warning. The missing
  public entry points were exactly the authored pair: `enqueueOutboxTx` and
  `enqueueProducerEventTx`. The inbox race text likewise needed consequence and
  discoverability edits rather than a new behavioral fix.
- An optional `cabal test jitsurei-test` run compiled the resource-migrated test
  suite but reported four existing example-level failures: its three read models
  are not explicitly registered after EP-101 removed query-time registration.
  The two direct query failures report `ReadModelUnregistered`; both routers
  intentionally discard those resolver errors and therefore resolve zero
  targets. MasterPlan 14 explicitly limits the in-repo Jitsurei work to
  compile-only mechanical wiring, so this plan records the result without
  semantically migrating the outdated example.


## Decision Log

- Decision: implement the truncation guard as a per-event contiguity check inside each hydration fold's `applyRecorded` step, using the `Replay` accumulator's existing `lastObservedStreamVersion` field, rather than a first-event-only check.
  Rationale: the accumulator already tracks the last version seen (initialized to 0 for full hydration and to the snapshot seed's version for seeded hydration), so "next event must be exactly last + 1" subsumes the first-event check, works unchanged across read pages, and also catches any future mid-stream gap source at negligible cost (one `Int64` comparison per event).
  Date: 2026-07-11

- Decision: define `HydrationGapDetected` standalone in this plan and give it its own low-cardinality `commandErrorClass` value (`"hydration_gap_detected"`), with an explicit merge note for EP-95.
  Rationale: the sibling plan `docs/plans/95-migrate-to-post-mp-16-keiki-and-adopt-the-structured-replay-and-step-apis.md` (which will restructure the hydration folds around keiki's structured replay API) is still an unwritten skeleton, so there is no taxonomy to coordinate with yet. MasterPlan 14, Integration Point 1, requires one new `error.type` class per constructor and no reuse of existing classes; this plan honors that. Whichever plan lands second rebases: the gap check is a *store-level* contiguity property (kiroku hid a prefix), not a keiki replay failure, so it must survive EP-95's fold replacement as a keiro-side wrapper around whatever fold keiki provides.
  Date: 2026-07-11

- Decision: fix enrichment parity by adding a `KirokuStoreResource :> es` constraint to the transactional command runners and calling `enrichEventsIO` before `prepareEventsIO`, accepting the breaking API change, rather than adding an optional enrichment field to `RunCommandOptions`.
  Rationale: investigation showed this is the only non-optional route kiroku's exported API allows. The `Store` effect exposes no way to reach `StoreSettings` from inside `Eff es` (the interpreter closes over the `KirokuStore` handle), and the `KirokuStoreResource` static-effect representation constructor is not exported, so `Kiroku.Store.Effect.Resource.withKirokuStore` is the sole public installer. An optional `RunCommandOptions` field would keep the bypass as the default, which is exactly the bug. kiroku's own Haddock (`kiroku-store/src/Kiroku/Store/Transaction.hs:286-291`) names "the keiro projection layer" as the intended consumer of the resource-flavored, hook-aware path.
  Date: 2026-07-11

- Decision: the fully-truncated-stream edge (truncate-before above the stream head, no events visible at all) is documented, not guarded.
  Rationale: with zero observed events the contiguity check has nothing to compare; hydration legitimately returns the initial state at version 0, and the subsequent append then fails loudly through the existing `StreamAlreadyExists` → `ConflictFixpoint` machinery (`keiro/src/Keiro/Command.hs:645-648`). Detecting it eagerly would cost an extra existence probe on every fresh-stream command — the most common command shape — to catch an operator action that is already loud, already documented as a misuse, and reversible via `clearStreamTruncateBefore`.
  Date: 2026-07-11

- Decision: scope reductions in the documentation bundle, verified against the working tree. The outbox ordering caveat already exists on `enqueueIntegrationEventTx` (`keiro/src/Keiro/Outbox.hs:114-118`) and the module header (`keiro/src/Keiro/Outbox.hs:27-31`); remaining gaps are `enqueueOutboxTx` (`keiro/src/Keiro/Outbox/Schema.hs:47-56`) and `enqueueProducerEventTx` (`keiro/src/Keiro/Outbox.hs:236-247`). The inbox GC-race text already exists on `tryInsertCompletedTx` (`keiro/src/Keiro/Inbox/Schema.hs:56-59`) and retention guidance on `garbageCollectCompleted` (`keiro/src/Keiro/Inbox/Schema.hs:128-135`); the remaining gap is the `Keiro.Inbox` module header, which mentions neither.
  Rationale: the plan must not re-add prose that is already present; it must close the specific gaps.
  Date: 2026-07-11

- Decision: the stale-docstring sweep touches only artifacts in modules this plan already owns, and explicitly excludes the sharded-worker zombie-regression note (owned by `docs/plans/96-ack-coupled-sharded-subscription-delivery-with-rebalance-under-load-coverage.md`) and the snapshot upsert documentation (owned by `docs/plans/98-snapshot-subsystem-hardening-uninit-register-guards-read-side-telemetry-and-workflow-write-alignment.md`).
  Rationale: MasterPlan 14 assigns those docstrings to EP-96 and EP-98; duplicating the fixes would create merge conflicts and divergent wording.
  Date: 2026-07-11

- Decision: the in-repo `jitsurei` package receives mechanical build fixes only (rewiring its effect stacks for the new constraint) and is never cited as design evidence.
  Rationale: user directive recorded in MasterPlan 14 — the jitsurei examples are outdated and out of scope — but they live in this repository and `cabal build all` (the `just haskell-build` recipe) must keep succeeding.
  Date: 2026-07-11

- Decision: re-host the truncation guard in EP-95's shared `hydrateSeeded`
  page pipeline. Scan each recorded event for contiguity before decoding it,
  but carry the first gap as a pending input error until the already-decoded
  prefix has replayed.
  Rationale: EP-95 removed the two authored folds. Treating a gap like the
  existing pending decode failure preserves event-order semantics: a replay
  failure in an earlier visible event wins over a later gap, while a gap at
  the head is reported before attempting to decode or replay the suffix.
  Date: 2026-07-13

- Decision: keep Keiro's existing low-level transactional append shape and
  call `enrichEventsIO` explicitly instead of switching to Kiroku's
  `runTransactionAppendingResource` convenience wrapper.
  Rationale: Keiro needs the enriched prepared events to reconstruct the
  callback's `RecordedEvent`s exactly. The convenience wrapper exposes only
  `AppendResult`, so using it would either discard callback fidelity or require
  duplicating Kiroku's private preparation details.
  Date: 2026-07-13


## Outcomes & Retrospective

Hydration now rejects every visible stream-version discontinuity before it can
seed a command decision from a truncated suffix. The guard works in EP-95's
shared page-oriented replay pipeline, preserves earlier replay-error precedence,
and is covered by uncovered-prefix, mid-command-batch, and covering-snapshot
tests. Operators get expected and observed versions through
`HydrationGapDetected`, while the zero-visible-event edge remains the documented
`ConflictFixpoint` path.

Transactional appends now run Kiroku's configured `enrichEvent` hook before
event preparation. The persisted events and the reconstructed `RecordedEvent`s
handed to inline SQL carry identical enriched metadata. The required
`KirokuStoreResource` constraint is propagated through projections, process
managers, routers, workers, test support, and the in-repo Jitsurei build; the
CHANGELOG contains the breaking migration recipe.

The operator documentation now makes the snapshot-first truncation workflow,
inbox retention/dedup trade-off, concurrent inbox-GC race, outbox transaction-
start ordering limitation, and transactional `$all` lock window discoverable at
the relevant APIs and user-guide pages. Formatting and `cabal build all` pass,
and the complete required Keiro suite finishes with 335 examples and zero
failures. This completes EP-102.


## Context and Orientation

Read this section even if you know the repository; every claim below was verified against the working tree on 2026-07-11 and the line numbers are load-bearing.

### The two repositories

This plan is implemented entirely inside the **keiro** repository (the directory containing this file). Keiro is an event-sourcing framework: application state is never stored directly; instead every state change is recorded as an immutable *event* appended to a per-aggregate *stream*, and current state is recomputed by replaying those events. Keiro delegates actual PostgreSQL storage to **kiroku**, a separate library consumed as a `source-repository-package` (see `cabal.project` lines 24-33; a local checkout is typically wired via `cabal.project.local` at `../kiroku-project/kiroku` relative to this repository — if yours is elsewhere, run `mori registry show kiroku --full` to locate it). You will read kiroku source to understand its API but **must not modify kiroku**: MasterPlan 14 scopes this initiative to consuming APIs kiroku already exports. All kiroku paths below are relative to the kiroku checkout.

### Hydration and the truncation hole

A *stream version* is a 1-based, contiguous, per-stream counter: the first event in stream `s` has version 1, the next 2, and so on. kiroku's append SQL assigns versions contiguously, so a gap can never be written — but one can be *hidden*. kiroku migration `kiroku-store-migrations/migrations/0007-stream-truncate-before.sql` adds a `truncate_before` column to the `streams` table, and every per-stream read filters on it: `kiroku-store/src/Kiroku/Store/SQL.hs:511-512` shows the forward-read predicate `se.stream_version > $2 AND se.stream_version >= s.truncate_before` (the cursor `$2` is exclusive; the truncate marker is inclusive-keep). An operator sets the marker with `setStreamTruncateBefore` (`kiroku-store/src/Kiroku/Store/Lifecycle.hs:114-140`), a reversible "close the book" primitive: events below the marker stay in the `$all` global log and category reads but vanish from ordered per-stream reads — exactly the reads hydration uses. keiro itself never calls this function; truncation is purely an operator action.

*Hydration* is how keiro recovers aggregate state before running a command. `keiro/src/Keiro/Command.hs` has two folds:

- `hydrateFull` (lines 308-378) reads the stream from cursor `StreamVersion 0` (line 319) and folds every returned `RecordedEvent` through the keiki transducer via `applyRecorded`/`applyEvent` (lines 343-366). The fold accumulator is the `Replay` record (lines 209-214), whose `lastObservedStreamVersion` field is updated on every applied event (line 365) and initialized to `StreamVersion 0` (line 333).
- `hydrate` (lines 221-306) first tries a snapshot seed. keiro snapshots are *table rows* (state serialized into a snapshot table by `keiro/src/Keiro/Snapshot.hs`'s `writeSnapshot`), not events. When a seed exists, `replayFrom` (lines 243-257) starts the same fold from cursor = the seed's stream version, with `lastObservedStreamVersion` initialized to the seed version (line 255). Any seeded-replay failure falls back to `hydrateFull` (line 234).

Neither fold checks that the first event the store returns is contiguous with its starting point. If an operator truncates a stream at version `V` **without** a snapshot at version ≥ `V - 1`, `hydrateFull` folds the suffix starting at `V` from the transducer's *initial* state. Usually the transducer rejects the out-of-context event and hydration fails with `HydrationReplayFailed` (line 359 — the `Nothing` branch of `applyEventStreaming`). But when the first surviving event *happens to be applicable* from the initial state — a counter increment, any self-loop edge, or a batch whose tail parses from scratch — hydration **silently succeeds with a wrong state**, and because `lastObservedStreamVersion` ends at the true head version, the subsequent optimistic-concurrency append *succeeds*, committing an event computed from corrupt state. That is the replay-contract violation this plan closes.

Two adjacent behaviors matter for the fix. `CommandError` (lines 118-142) is the typed failure vocabulary; `commandErrorClass` (lines 570-578) maps each constructor to a low-cardinality `error.type` span attribute — MasterPlan 14 Integration Point 1 requires every new constructor to get its own class string. And the fully-truncated edge (marker above the head, zero events visible) cannot be caught by a contiguity check over observed events; it surfaces today as `ConflictFixpoint` (lines 645-648) after the fresh-looking append collides with the still-existing stream — loud, but worth documenting.

### The two append paths and the enrichment hook

kiroku's `StoreSettings.enrichEvent` (`kiroku-store/src/Kiroku/Store/Settings.hs:68`) is an optional `EventData -> IO EventData` hook applied to every event before append — the intended home for trace-context injection and PII stamping. It is configured once, at store-open time, inside `ConnectionSettings.storeSettings` (`kiroku-store/src/Kiroku/Store/Connection.hs:112,138`).

- **Path 1 (hook fires).** `runCommand` appends through the `Store` effect's `AppendToStream` operation; the PostgreSQL interpreter `runStorePool` applies `enrichEvents` there (`kiroku-store/src/Kiroku/Store/Effect.hs:157`).
- **Path 2 (hook bypassed).** `runCommandWithSqlEvents` (`keiro/src/Keiro/Command.hs:454-508`) needs the append and the caller's SQL in one transaction, so `appendWithSqlOnce` calls `prepareEventsIO` directly (line 487) and sends the prepared batch through the opaque `RunTransaction` operation via `appendToStreamTx`. The interpreter never sees the `EventData`, so the hook never fires. kiroku's own Haddock warns about exactly this bypass (`kiroku-store/src/Kiroku/Store/Transaction.hs:240-247`) and prescribes the remedy: call `enrichEventsIO` (defined at `Transaction.hs:333-334`, a no-op traversal when the hook is `Nothing`) before preparing.

Everything transactional is built on Path 2: `runCommandWithSql` delegates to it (`Command.hs:443-444`), `runCommandWithProjections` wraps it (`keiro/src/Keiro/Projection.hs:90-115`), `runProcessManagerOnce` uses `runCommandWithSql` (`keiro/src/Keiro/ProcessManager.hs:257-299`), and `runRouterOnce` dispatches through `runCommandWithProjections` (`keiro/src/Keiro/Router.hs:128-160`). So every projection-coupled command, process-manager state append, and router dispatch currently persists **unenriched** events while plain commands are enriched — a split-brain metadata store.

Calling `enrichEventsIO` requires the `KirokuStore` handle. keiro's runners only carry `Store :> es`, and the handle is unreachable from that effect. kiroku's answer is the `KirokuStoreResource` static effect (`kiroku-store/src/Kiroku/Store/Effect/Resource.hs`): `getKirokuStore` (lines 41-44) reads the handle, and — critically — the *only* exported installer is the bracket-style `withKirokuStore :: ConnectionSettings -> Eff (KirokuStoreResource : es) a -> Eff es a` (lines 47-54), which opens the store itself; the `StaticRep` constructor is not exported, so you cannot install the effect around a handle you already hold. This shapes the test-fixture work in Milestone 2. kiroku also exports `runStoreResource` (`Effect.hs:355-361`), which interprets `Store` by reading the handle from the resource effect, and the convenience `runStoreIO store = runEff . runErrorNoCallStack . runStorePool store` (`Effect.hs:348-352`) that today's keiro tests use everywhere (e.g. `keiro/test/Main.hs:596`).

### The messaging caveats (documentation only)

The *outbox* (`keiro/src/Keiro/Outbox.hs`) stores integration events to publish later; the *inbox* (`keiro/src/Keiro/Inbox.hs`, storage in `keiro/src/Keiro/Inbox/Schema.hs`) deduplicates incoming integration events by `(source, dedupe_key)`. Verified current state:

- Outbox ordering: per-key/per-source publishing sorts by `created_at`, which PostgreSQL fills at *transaction start*, so two concurrent inline enqueues for the same key can commit in the opposite order. Already documented on the module header (`Outbox.hs:27-31`) and on `enqueueIntegrationEventTx` (`Outbox.hs:114-118`). **Not** documented on the storage primitive `enqueueOutboxTx` (`keiro/src/Keiro/Outbox/Schema.hs:47-56`) or on `enqueueProducerEventTx` (`Outbox.hs:236-247`), both of which a consumer can reach without reading the module header.
- Inbox GC: `garbageCollectCompleted` (`Inbox/Schema.hs:128-146`) deletes completed rows older than a retention window; its Haddock already states that the retention window *is* the dedup window and recommends 30 days. `tryInsertCompletedTx` (`Inbox/Schema.hs:45-78`) already documents (lines 56-59) the narrow race where a concurrent GC delete between the failed insert and the fallback lookup returns `Right ()`: the handler runs, **no dedup row commits in that transaction**, and a later redelivery reprocesses — at-least-once still holds. The `Keiro.Inbox` module header (`Inbox.hs:1-14`) mentions neither the window nor the race; that is the gap.
- `$all` lock window: every kiroku append updates the global `$all` stream row, and PostgreSQL holds that row lock until the transaction commits, so *every statement an `afterAppend` callback runs extends the interval during which all other appends in the entire store are blocked*. kiroku documents this on its own wrappers (`kiroku-store/src/Kiroku/Store/Transaction.hs:217-231`); keiro's `runCommandWithSqlEvents` Haddock says nothing about it.

### Sibling-plan boundaries

`docs/plans/95-…`, `96-…`, and `98-…` are skeletons as of this writing. EP-95 will eventually replace both hydration folds with keiki's structured replay API — the Decision Log entry above records how `HydrationGapDetected` merges into that. EP-96 owns the sharded-worker docstrings, EP-98 owns snapshot-subsystem docs; touch neither. EP-102 (this plan) has no hard dependencies and can be implemented immediately.

### Build, test, and formatting

Work from the repository root. `cabal build all` builds every package including the in-repo `jitsurei` worked example. `cabal test keiro-test` runs `keiro/test/Main.hs`, an hspec suite whose `main` (line 316) wraps everything in `withMigratedSuite` from `keiro-test-support/src/Keiro/Test/Postgres.hs`: it starts one cached ephemeral PostgreSQL server (via the `ephemeral-pg` library — no external database or `just postgres-start` needed), migrates a template database once, and clones a fresh database per example (`withFreshStore fixture` provides a `KirokuStore` per example, used with hspec's `around` at e.g. `test/Main.hs:592`). PostgreSQL and toolchain binaries come from the Nix dev shell — run inside `nix develop` if `initdb`/`cabal` are missing. Format with `nix fmt` (treefmt, configured in `nix/treefmt.nix`). Commit messages follow Conventional Commits and every commit gets the trailer `ExecPlan: docs/plans/102-persistence-polish-truncation-guards-enrichment-parity-and-messaging-caveat-documentation.md`.

Useful test fixtures that already exist in `keiro/test/Main.hs`: `counterEventStream` (plain counter, no snapshots — its `Add n` events apply from any state, making it the perfect silent-corruption vector), `multiCounterEventStream` (one command emits multiple events, for the mid-batch case), and `snapshotCounterEventStream` (definition at line 7645: `snapshotPolicy = Every 2`, so a snapshot row exists after the second appended event).


## Plan of Work

### Milestone 1 — Truncation contiguity guard

Scope: `keiro/src/Keiro/Command.hs` plus new tests in `keiro/test/Main.hs`. At the end of this milestone, hydrating a stream whose visible prefix does not start exactly one version above the fold's starting point fails with a new typed error instead of silently replaying a suffix, and three new tests prove it (two red-before, one positive). Nothing about the public runner signatures changes yet, so this milestone is independently shippable.

Add the constructor to `CommandError` (after `HydrationReplayFailed`, `keiro/src/Keiro/Command.hs:118-142`):

```haskell
    | {- | Hydration observed a non-contiguous stream version: the store
      returned an event at the second version where the first was expected
      (carries expected, then observed). The store never writes gaps, so
      this means an operator set the stream's truncate-before marker
      without a covering snapshot — replaying the surviving suffix from
      the initial state (or from a too-old snapshot) would produce a
      wrong aggregate state, so hydration refuses. Recover by restoring
      visibility ('Kiroku.Store.Lifecycle.clearStreamTruncateBefore') or
      by writing a snapshot at or above the marker minus one.
      -}
      HydrationGapDetected !StreamVersion !StreamVersion
```

Add the `commandErrorClass` arm (`Command.hs:570-578`): `HydrationGapDetected{} -> "hydration_gap_detected"`. Per MasterPlan 14 Integration Point 1 this class string is reserved for this constructor; do not reuse an existing class.

Implement the guard in **both** `applyRecorded` copies — the seeded fold's (lines 271-279) and `hydrateFull`'s (lines 343-351). The two folds are duplicates that EP-95 will delete wholesale, so keep the edit mechanical and identical rather than refactoring them together. The shape (adapted to the file's qualified-`Prelude` style):

```haskell
    applyRecorded (Left err) _ = pure (Left err)
    applyRecorded (Right current) recorded
        | observed /= expectedNext =
            pure (Left (HydrationGapDetected expectedNext observed))
        | otherwise =
            case decodeRecorded (eventStream ^. #eventCodec) recorded of
                Left err -> pure (Left (HydrationDecodeFailed err))
                Right event -> pure (applyEvent current recorded event)
      where
        observed = recorded ^. #streamVersion
        StreamVersion lastSeen = lastObservedStreamVersion current
        expectedNext = StreamVersion (lastSeen Prelude.+ 1)
```

Why this placement works: `lastObservedStreamVersion` starts at `StreamVersion 0` in `hydrateFull` (line 333) and at the seed's version in `replayFrom` (line 255), and is advanced on every applied event (lines 293, 365) — so `lastSeen + 1` is exactly "the version the next event must have", for the first event and every later one, across read-page boundaries. Note the interplay with the snapshot fallback at line 234: a gap detected during *seeded* replay makes `hydrate` fall back to `hydrateFull`, which re-detects the gap against expected version 1 and surfaces `HydrationGapDetected (StreamVersion 1) …`. That is correct (the error that escapes is the full-hydration one) — mention it in the constructor Haddock only if you find it confusing in practice.

Tests go in the existing `describe "Keiro.Command" $ around (withFreshStore fixture)` block (`keiro/test/Main.hs:592`). kiroku's `setStreamTruncateBefore` is reachable as `Store.setStreamTruncateBefore` because `Kiroku.Store` re-exports its `Lifecycle` module, and the tests already import `Kiroku.Store qualified as Store`. Write each test, run it, and confirm it is red before making the source change (the two negative tests currently *succeed silently* — the strongest proof of the bug).

Test 1, gap without snapshot (red first). Use `counterEventStream`; append three commands (versions 1-3); set the marker; run a fourth command; expect the typed failure:

```haskell
        it "rejects hydration with HydrationGapDetected after truncation without a covering snapshot" $ \storeHandle -> do
            let target = stream "counter-truncated-uncovered" :: Stream CounterEventStream
                name = StreamName "counter-truncated-uncovered"
            Right (Right _) <- Store.runStoreIO storeHandle $ runCommand defaultRunCommandOptions counterEventStream target (Add 1)
            Right (Right _) <- Store.runStoreIO storeHandle $ runCommand defaultRunCommandOptions counterEventStream target (Add 2)
            Right (Right _) <- Store.runStoreIO storeHandle $ runCommand defaultRunCommandOptions counterEventStream target (Add 3)
            Right (Just _) <- Store.runStoreIO storeHandle $ Store.setStreamTruncateBefore name (StreamVersion 3)
            result <- Store.runStoreIO storeHandle $ runCommand defaultRunCommandOptions counterEventStream target (Add 4)
            case result of
                Right (Left (HydrationGapDetected expected observed)) -> do
                    expected `shouldBe` StreamVersion 1
                    observed `shouldBe` StreamVersion 3
                other -> expectationFailure ("expected HydrationGapDetected, got " <> show other)
```

Test 2, mid-batch truncation (red first). Same shape but drive `multiCounterEventStream` so one command appends several events, then set the marker to land *inside* that batch (e.g. events at versions 1-3 from one command, marker at 2, expect `HydrationGapDetected (StreamVersion 1) (StreamVersion 2)`). Consult the `multiCounterEventStreamDef` fixture for how many events its command emits and adjust versions accordingly.

Test 3, covering snapshot (positive). Use `snapshotCounterEventStream` (`Every 2` policy): two commands produce versions 1-2 and a snapshot at version 2; set the marker to `StreamVersion 2` (hides version 1; the snapshot covers it); run a third command and assert it succeeds with `streamVersion` = `StreamVersion 3`. This proves the guard does not fire on the sanctioned snapshot-then-truncate workflow, including the boundary case where the seeded read returns zero events.

Acceptance: `cabal test keiro-test --test-options='--match "Keiro.Command"'` passes with the three new examples; before the source edit, tests 1 and 2 fail by observing a successful (wrong) command instead of the typed error.

### Milestone 2 — Enrichment parity between the append paths

Scope: `keiro/src/Keiro/Command.hs`, constraint propagation through `keiro/src/Keiro/Projection.hs`, `keiro/src/Keiro/ProcessManager.hs`, `keiro/src/Keiro/Router.hs`; a new fixture in `keiro-test-support/src/Keiro/Test/Postgres.hs`; test migration in `keiro/test/Main.hs`; mechanical build fixes in `jitsurei/`; a CHANGELOG entry. At the end, an `enrichEvent` hook configured at store open fires identically on `runCommand` and `runCommandWithSqlEvents`, proven by a parity test that is red for the transactional path before the fix. This is a **breaking change** to keiro's public API (a new effect constraint on the transactional runners), which is acceptable pre-1.0 and must be called out in `CHANGELOG.md` under "Breaking Changes" with the one-line migration recipe (wrap your stack's store acquisition in `withKirokuStore` and interpret `Store` with `runStoreResource`).

In `keiro/src/Keiro/Command.hs`:

1. Import `KirokuStoreResource` and `getKirokuStore` from `Kiroku.Store.Effect.Resource`, and add `enrichEventsIO` to the existing `Kiroku.Store.Transaction` import list (lines 78-84).
2. Add `KirokuStoreResource :> es` to the constraint tuples of `runCommandWithSqlEvents` (line 456) and `runCommandWithSql` (line 436). Leave `runCommand` untouched — its interpreter path already enriches.
3. In `appendWithSqlOnce` (lines 485-508), enrich before preparing:

```haskell
    appendWithSqlOnce attemptNo current events encoded = do
        liftIO (options ^. #beforeAppend)
        store <- getKirokuStore
        enriched <- liftIO (enrichEventsIO store encoded)
        prepared <- prepareEventsIO enriched
        ...
```

Enrichment runs once per optimistic-concurrency attempt (each retry re-encodes from a fresh hydration), matching the plain path where the interpreter enriches each `AppendToStream` call. A pleasant side effect: `reconstructRecorded` (lines 715-738) builds the callback's `RecordedEvent`s from `prepared`, so the `afterAppend` callback now also observes enriched metadata — assert this in the parity test. Note `Prelude.length encoded` at line 504 stays correct since enrichment is length-preserving.

4. Update the module Haddock (lines 1-30) to state the parity guarantee and the new resource requirement, and delete the stale detached comment at lines 446-447 ("The ignored first argument now carries…" — a leftover migration note that refers to no surrounding code) while you are in the file (this is the Milestone 3 sweep item; doing it here avoids touching the file twice).

Propagate the constraint upward — each of these only relays it, no body changes: `runCommandWithProjections` (`keiro/src/Keiro/Projection.hs:90-102`), `runProcessManagerOnce` (`keiro/src/Keiro/ProcessManager.hs:257-271` — its internal dispatch loop also calls `runCommandWithProjections`, so the one constraint covers both call sites), and `runRouterOnce` (`keiro/src/Keiro/Router.hs:128-137`). Then run `cabal build all` and follow the type errors: any further keiro-internal or `jitsurei` function that transits these runners gains the same constraint mechanically. For `jitsurei`, also rewire its store acquisition (`Store.withStore …` becomes `runEff $ withKirokuStore settings $ …` with `runStoreResource` interpreting `Store`) — mechanical only, per the Decision Log.

Test-support fixture. Existing tests hold a `KirokuStore` from `withFreshStore`, but `withKirokuStore` is the only public installer of the resource effect and it *opens the store itself* — so a new fixture must own both acquisition and interpretation. Add to `keiro-test-support/src/Keiro/Test/Postgres.hs` (adding `effectful-core`/`effectful` and the needed kiroku modules to `keiro-test-support/keiro-test-support.cabal` if absent):

```haskell
-- | A runner for the resource-flavored effect stack, usable many times
-- within one example (rank-2 field, hence the newtype).
newtype StoreRunner = StoreRunner
    (forall a. Eff '[Store, Error StoreError, KirokuStoreResource, IOE] a -> IO (Either StoreError a))

withFreshResourceStoreWith ::
    Fixture ->
    (Store.ConnectionSettings -> Store.ConnectionSettings) ->
    ((Store.KirokuStore, StoreRunner) -> IO ()) ->
    IO ()
withFreshResourceStoreWith fixture modify action =
    withFreshDatabase fixture \connStr ->
        runEff $
            withKirokuStore (modify (Store.defaultConnectionSettings connStr)) $ do
                store <- getKirokuStore
                withEffToIO SeqUnlift \unlift ->
                    action (store, StoreRunner (unlift . runErrorNoCallStack . runStoreResource))
```

plus a `withFreshResourceStore fixture = withFreshResourceStoreWith fixture id` convenience, both exported. The raw handle stays available in the tuple because several tests need it directly (e.g. wake-signal helpers). `SeqUnlift` is sufficient: hspec runs the example body in one thread and the runner is invoked sequentially. Adjust the sketch to whatever the type checker demands — the *shape* (one store per example, one reusable runner, resource effect installed once) is the requirement, not the exact spelling.

Migrate affected tests: grep `keiro/test/Main.hs` for `runCommandWithSql`, `runCommandWithSqlEvents`, `runCommandWithProjections`, `runProcessManagerOnce`, and `runRouterOnce`; every `describe` block containing them switches from `around (withFreshStore fixture)` to `around (withFreshResourceStore fixture)` and from `Store.runStoreIO storeHandle $ …` to `runner $ …` (pattern-matching the `StoreRunner`). Blocks that only use `runCommand` and raw store operations stay on `withFreshStore`. Expect moderate churn concentrated in the command/projection/process-manager/router suites; keep each block's assertions byte-identical.

Parity test (red first for the transactional path), in a new block using `withFreshResourceStoreWith` with a hook-configuring `modify` (the pattern mirrors kiroku's own hook test at `kiroku-store/test/Test/InterpreterHooks.hs:40-61`, but *merge* the marker instead of replacing metadata, because keiro's codec already stores a `schemaVersion` key there):

```haskell
    describe "Keiro.Command enrichment parity" $ do
        let addMarker ed = pure (ed & #metadata %~ injectMarker)
            injectMarker = \case
                Just (Aeson.Object o) -> Just (Aeson.Object (KeyMap.insert "enriched" (Aeson.Bool True) o))
                _ -> Just (Aeson.object [("enriched", Aeson.Bool True)])
            withHook = #storeSettings .~ Store.defaultStoreSettings{Store.enrichEvent = Just addMarker}
        around (withFreshResourceStoreWith fixture withHook) $
            it "stamps the enrichEvent marker on both append paths" $ \(_store, StoreRunner runner) -> do
                let plainTarget = stream "enrich-plain" :: Stream CounterEventStream
                    txTarget = stream "enrich-tx" :: Stream CounterEventStream
                Right (Right _) <- runner $ runCommand defaultRunCommandOptions counterEventStream plainTarget (Add 1)
                Right (Right (_, Just recordeds)) <-
                    runner $ runCommandWithSqlEvents defaultRunCommandOptions counterEventStream txTarget (Add 1) (\pairs _ -> pure (fmap snd pairs))
                Right plainEvents <- runner $ Store.readStreamForward (StreamName "enrich-plain") (StreamVersion 0) 10
                Right txEvents <- runner $ Store.readStreamForward (StreamName "enrich-tx") (StreamVersion 0) 10
                let hasMarker md = maybe False (\v -> …check "enriched" key… ) md
                for_ (Vector.toList plainEvents <> Vector.toList txEvents) $ \re ->
                    (re ^. #metadata) `shouldSatisfy` hasMarker
                for_ recordeds $ \re -> (re ^. #metadata) `shouldSatisfy` hasMarker
```

(Fill in `hasMarker` with a small Aeson key probe; the test file already imports `Data.Aeson.KeyMap qualified as KeyMap`.) Before the source fix, the `txEvents` assertion fails — that is the red state proving the bypass.

Acceptance: parity test red before / green after; `cabal build all` succeeds (including `jitsurei`); the full `cabal test keiro-test` suite passes; `CHANGELOG.md` gains the Breaking Changes entry.

### Milestone 3 — Documentation bundle and stale-docstring sweep

Scope: Haddock and Markdown only (plus the Command.hs comment deletion already folded into Milestone 2). No behavior change; acceptance is that `cabal build all` still succeeds (Haddock syntax is parsed) and a reviewer can find each caveat at the named location.

(a) Truncation precondition. Three homes. In the `Keiro.Command` module Haddock (`keiro/src/Keiro/Command.hs:1-30`), extend the hydration paragraph: per-stream reads hide events below kiroku's `truncate_before` marker, so **truncating a stream requires a covering snapshot at version ≥ marker − 1**; without one, hydration fails with `HydrationGapDetected` (and a marker set above the stream head surfaces as `ConflictFixpoint`, because zero events are visible and the fresh-stream append collides). In `docs/user/operations.md`, add a `## Stream Truncation` section stating: keiro never truncates on its own; the operator workflow is *snapshot first, then truncate* (write or wait for a keiro snapshot at version `V`, then `setStreamTruncateBefore` with marker ≤ `V + 1`); what each failure mode looks like (`HydrationGapDetected` with expected/observed versions; `ConflictFixpoint` for full truncation); that truncation is reversible via `clearStreamTruncateBefore`; and that the `$all` log, categories, and subscriptions are unaffected (kiroku hides, never deletes). Note explicitly that keiro snapshots are table rows, not the snapshot-*event* pattern kiroku's own `setStreamTruncateBefore` Haddock describes — the covering rule is about the snapshot's recorded stream version, not an event at the marker. In `docs/user/snapshots.md` under `## Operational Guidance` (line 128), add a short cross-reference paragraph to the new operations section.

(b) Inbox. Extend the `Keiro.Inbox` module header (`keiro/src/Keiro/Inbox.hs:1-14`) with a retention paragraph: the GC retention window *is* the dedup window (a redelivery arriving after `garbageCollectCompleted` pruned its row is reprocessed — an inherent trade-off, size retention above the maximum tolerated redelivery delay; 30 days is the guide default), and the narrow concurrent-GC race in `tryInsertCompletedTx` (insert conflicts with a row GC deletes before the fallback lookup → handler runs but no dedup row commits → one extra reprocess on redelivery; at-least-once semantics hold throughout — handlers must be idempotent regardless). On `garbageCollectCompleted` (`keiro/src/Keiro/Inbox/Schema.hs:128-135`), add one sentence pointing at the `tryInsertCompletedTx` race so both hazards are discoverable from the GC entry point. On `tryInsertCompletedTx` (lines 45-59), sharpen the existing race paragraph to state the *consequence* explicitly ("the handler's effects commit without a dedup row, so a later redelivery reprocesses; at-least-once is preserved").

(c) Outbox. Copy the ordering-caveat paragraph already on `enqueueIntegrationEventTx` (`keiro/src/Keiro/Outbox.hs:114-118`) onto `enqueueOutboxTx` (`keiro/src/Keiro/Outbox/Schema.hs:47-56`) and `enqueueProducerEventTx` (`keiro/src/Keiro/Outbox.hs:236-247`), adapted to each function's voice: `created_at` is transaction-start time, concurrent same-key/same-source enqueues can commit in the opposite order, so per-key ordering is best-effort unless the caller serializes enqueues (the canonical `IntegrationProducer` subscription already does).

(d) `$all` lock window. On `runCommandWithSqlEvents` (`keiro/src/Keiro/Command.hs:449-453`) — and a pointer from `runCommandWithSql` (lines 429-433) — add an operational note in keiro's own words (embed the knowledge; do not merely cite kiroku): the append updates kiroku's global `$all` row and PostgreSQL holds that row lock until commit; the `afterAppend` callback runs after the append inside the same transaction, so *every* statement it executes extends the window during which **all** appends in the store are blocked. Keep callbacks small: precompute values before the command, batch per-row work, never round-trip more than needed (a `Tx.Transaction` cannot do arbitrary `IO`, but it can still issue many statements).

(e) Sweep boundary. The only stale artifact this plan owns is the Command.hs:446-447 detached comment (handled in Milestone 2). Do **not** touch the sharded-worker zombie-regression docstring (EP-96) or snapshot upsert docs (EP-98). If you notice other stale prose in Outbox/Inbox modules while editing them, fix it in place and record it in Surprises & Discoveries.

Finally, add the non-breaking CHANGELOG entries (Added: `HydrationGapDetected` guard; Fixed: enrichment parity; the Breaking entry was written in Milestone 2).


## Concrete Steps

All commands run from the repository root. Prefix with `nix develop --command` (or run inside `nix develop`) if the toolchain is not on your PATH.

```bash
cabal build all
```

Establish a green baseline first; expected tail: `Build completed` with no errors (first run may take a while compiling dependencies).

For each milestone, the loop is: write the failing tests, watch them fail, make the edit, watch them pass, then run the focused suite and finally the full suite:

```bash
cabal test keiro-test --test-options='--match "Keiro.Command"' --test-show-details=direct
cabal test keiro-test --test-show-details=direct
```

Expected output shape for the focused run after Milestone 1 (counts will differ):

```text
Keiro.Command
  rejects hydration with HydrationGapDetected after truncation without a covering snapshot [✔]
  ...
Finished in 12.34 seconds
NN examples, 0 failures
```

Formatting and hygiene before each commit:

```bash
nix fmt
git add -A
git commit
```

Commit per milestone (or smaller, whenever green), Conventional Commits style, always with the trailer. Example message:

```text
feat(command): detect truncation gaps during hydration

Add HydrationGapDetected to CommandError and a per-event contiguity
guard to both hydration folds; a stream truncated without a covering
snapshot now fails loudly instead of silently replaying a suffix.

ExecPlan: docs/plans/102-persistence-polish-truncation-guards-enrichment-parity-and-messaging-caveat-documentation.md
```

Update this plan's Progress, Decision Log, and Surprises & Discoveries sections at every stopping point.


## Validation and Acceptance

Milestone 1: before the guard lands, the two negative tests demonstrate the defect by *passing a command that should fail* (run them against unmodified source and record the observation in Surprises & Discoveries — e.g. the truncated counter accepts `Add 4` at stream version 4 with state computed from one event instead of three). After the guard: `HydrationGapDetected (StreamVersion 1) (StreamVersion 3)` for the plain case, `(StreamVersion 1) (StreamVersion 2)` for the mid-batch case, and the covering-snapshot test appends normally at version 3. The `error.type` span attribute for the new failure is `hydration_gap_detected` (verify by inspection of `commandErrorClass`; the existing telemetry tests cover the mechanism).

Milestone 2: the parity test is red against unmodified `appendWithSqlOnce` (transactional stream's events lack the `"enriched"` metadata key) and green after; the callback's `RecordedEvent`s also carry the marker. `cabal build all` compiles every package including `jitsurei`. The entire pre-existing suite passes after the fixture migration — any behavioral diff in migrated tests is a bug in the migration, not an acceptable casualty.

Milestone 3: each caveat is present at its named location (grep is sufficient: `HydrationGapDetected` in `docs/user/operations.md`; "transaction start" in `keiro/src/Keiro/Outbox/Schema.hs`; "dedup" in `keiro/src/Keiro/Inbox.hs`; "$all" in the `runCommandWithSqlEvents` Haddock), Haddock still parses (`cabal build all`), and neither the EP-96 nor EP-98 owned files were modified (check with `git status`).

Final acceptance: `cabal build all` and `cabal test keiro-test` green; `CHANGELOG.md` documents the breaking constraint, the guard, and the parity fix; this plan's living sections reflect reality.


## Idempotence and Recovery

Every step is safe to repeat. Tests run against per-example database clones that are created from a template and dropped afterwards (`keiro-test-support/src/Keiro/Test/Postgres.hs`), so a crashed or interrupted test run leaves at worst orphaned `keiro_test_N` databases inside a cached ephemeral server that the next `startCached` reuses or discards — no manual cleanup is ever required, and no developer or production database is touched. Source edits are ordinary git-tracked changes: if a milestone goes sideways, `git checkout -- <file>` (or reset to the last green commit) restores the baseline, which is why each milestone ends in its own commit. The Milestone 2 constraint propagation is the only step with a wide blast radius; it is fully compiler-guided (add the constraint at the four named functions, then let `cabal build all` enumerate every remaining site), so a partial application is loudly incomplete rather than silently wrong. If the test-fixture migration stalls mid-way, note the split point in Progress ("blocks A-D migrated, E-G remaining") and commit the compiling subset — `withFreshStore` and `withFreshResourceStore` coexist indefinitely.


## Interfaces and Dependencies

No new external dependencies. kiroku is consumed strictly through APIs it already exports (MasterPlan 14 scope rule): `setStreamTruncateBefore` / `clearStreamTruncateBefore` from `Kiroku.Store.Lifecycle` (re-exported by `Kiroku.Store`), `enrichEventsIO` from `Kiroku.Store.Transaction`, `KirokuStoreResource` / `getKirokuStore` / `withKirokuStore` from `Kiroku.Store.Effect.Resource`, `runStoreResource` from `Kiroku.Store.Effect`, and `StoreSettings` / `defaultStoreSettings` / the `enrichEvent` field from `Kiroku.Store.Settings`. `keiro-test-support` gains `effectful` (if not already a direct dependency) for `runEff` / `withEffToIO` / `runErrorNoCallStack`.

At the end of the plan these signatures exist (module paths in full):

```haskell
-- keiro/src/Keiro/Command.hs
data CommandError
    = …
    | HydrationGapDetected !StreamVersion !StreamVersion  -- expected, observed
    | …

runCommandWithSqlEvents ::
    ( HasCallStack, IOE :> es, Store :> es, Error StoreError :> es
    , KirokuStoreResource :> es
    , BoolAlg phi (RegFile rs, ci), Eq co ) =>
    RunCommandOptions ->
    ValidatedEventStream phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    ci ->
    ([(co, RecordedEvent)] -> AppendResult -> Tx.Transaction a) ->
    Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co), Maybe a))

-- runCommandWithSql: same constraint addition, same shape as today otherwise.
-- Keiro.Projection.runCommandWithProjections, Keiro.ProcessManager.runProcessManagerOnce,
-- Keiro.Router.runRouterOnce: each gains KirokuStoreResource :> es, nothing else.

-- keiro-test-support/src/Keiro/Test/Postgres.hs
newtype StoreRunner = StoreRunner
    (forall a. Eff '[Store, Error StoreError, KirokuStoreResource, IOE] a -> IO (Either StoreError a))
withFreshResourceStore ::
    Fixture -> ((Store.KirokuStore, StoreRunner) -> IO ()) -> IO ()
withFreshResourceStoreWith ::
    Fixture -> (Store.ConnectionSettings -> Store.ConnectionSettings)
            -> ((Store.KirokuStore, StoreRunner) -> IO ()) -> IO ()
```

Coordination contracts with sibling plans: `commandErrorClass` maps `HydrationGapDetected` to the reserved class `"hydration_gap_detected"` (MasterPlan 14, Integration Point 1); when EP-95 (`docs/plans/95-migrate-to-post-mp-16-keiki-and-adopt-the-structured-replay-and-step-apis.md`) replaces the hydration folds with keiki's structured replay API, the contiguity guard must be re-hosted as a keiro-side check on the event feed into that fold — it is a store-visibility property, not a keiki replay failure — and this constructor survives the migration unchanged. EP-96 and EP-98 own the sharded-worker and snapshot-subsystem docstrings respectively; this plan does not touch them.


## Revision Notes

- 2026-07-13: Completed EP-102. Added typed truncation-gap detection and
  red/green coverage, restored enrichment parity with resource-aware
  transactional runners and fixtures, documented persistence and messaging
  caveats, and passed the whole workspace build plus all 335 Keiro examples.
