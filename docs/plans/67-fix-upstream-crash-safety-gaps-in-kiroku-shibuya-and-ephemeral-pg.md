---
id: 67
slug: fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg
title: "Fix upstream crash-safety gaps in kiroku, shibuya, and ephemeral-pg"
kind: exec-plan
created_at: 2026-06-11T04:45:56Z
intention: intention_01kv40hzwaenftzem0gxypz4mj
master_plan: "docs/masterplans/9-keiro-production-readiness-hardening.md"
---

# Fix upstream crash-safety gaps in kiroku, shibuya, and ephemeral-pg

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro (this repository, `/Users/shinzui/Keikaku/bokuno/keiro`) is an event-sourcing framework built on three upstream libraries owned by the same author. A June 2026 production-readiness audit found four crash-safety gaps in those upstreams that keiro cannot work around cleanly, so this plan fixes them at the source. It is EP-1 of the MasterPlan `docs/masterplans/9-keiro-production-readiness-hardening.md` and has no dependencies on sibling plans; the sibling plan `docs/plans/71-fix-process-manager-and-router-delivery-correctness.md` (EP-5) hard-depends on the kiroku artifacts this plan produces.

After this plan is implemented:

1. **kiroku** (the PostgreSQL event store): an event appended through the *transactional* API with a caller-supplied event id that already exists surfaces as the typed error `DuplicateEvent` instead of being smeared into `ConnectionError`. This makes keiro's process-manager idempotency fold (which pattern-matches `DuplicateEvent`) live code on the transactional path, so a concurrently re-delivered command degrades to a benign no-op instead of halting a worker.
2. **kiroku** gains a point lookup, `eventExistsInStream :: StreamName -> EventId -> Eff es Bool`, answering "does this event id already exist in this stream" with one indexed `SELECT EXISTS` query. Today keiro's `eventAlreadyIn` (`keiro/src/Keiro/ProcessManager.hs`) must page through the whole stream from version 0 on every dispatch — O(stream length) per event.
3. **shibuya** (the queue-processing runtime): a transient database error during queue polling no longer silently and permanently kills a worker. The ingester's failure becomes observable (processor state `Failed`, real exception propagation to the supervisor) instead of masquerading as a normal end-of-stream, and the PGMQ polling path retries transient errors with bounded exponential backoff.
4. **ephemeral-pg** (test Postgres fixtures): the initdb cache is created via copy-to-temp-then-atomic-rename, so two test suites starting concurrently with a cold cache can no longer observe a half-written cache directory and fail with a torn data directory.

The final milestone bumps keiro's dependency pins and proves keiro's own test suites still pass against the updated upstreams. You can see the whole thing working by running the test commands listed per milestone (each adds a test that fails before its fix and passes after) and finally `cabal build all && cabal test all` in `/Users/shinzui/Keikaku/bokuno/keiro`.


## Progress

- [x] M1: kiroku — add `mapTransactionUsageError` to `Kiroku/Store/Error.hs` and export it. Completed before this pass in upstream commit `fa43ec2` and revalidated on 2026-06-15.
- [x] M1: kiroku — route `runTxOnPool` failures through `mapTransactionUsageError` in `Kiroku/Store/Effect.hs`. Completed before this pass in upstream commit `fa43ec2` and revalidated on 2026-06-15.
- [x] M1: kiroku — regression test in `kiroku-store/test/Test/Transaction.hs`: duplicate caller-supplied event id through `runTransaction`+`appendToStreamTx` and through `runTransactionAppending` yields `DuplicateEvent`. Completed before this pass in upstream commit `fa43ec2` and revalidated on 2026-06-15.
- [x] M1: kiroku — `cabal test kiroku-store-test` green. Revalidated on 2026-06-15 with 226 examples, 0 failures.
- [x] M2: kiroku — add `eventExistsInStreamStmt` to `Kiroku/Store/SQL.hs`. Completed on 2026-06-15 in upstream commit `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`.
- [x] M2: kiroku — add `EventExistsInStream` constructor to the `Store` effect and its interpreter branch in `Kiroku/Store/Effect.hs`. Completed on 2026-06-15 in upstream commit `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`.
- [x] M2: kiroku — add `eventExistsInStream` wrapper to `Kiroku/Store/Read.hs` (re-exported via `Kiroku.Store`). Completed on 2026-06-15 in upstream commit `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`.
- [x] M2: kiroku — tests in `kiroku-store/test/Test/ReadStream.hs` (present id, absent id, wrong stream, soft-deleted stream). Completed on 2026-06-15; `cabal test kiroku-store-test` passed with 226 examples, 0 failures.
- [x] M2: kiroku — bump `kiroku-store` to 0.2.1.0, update `kiroku-store/CHANGELOG.md`, commit, push, record new SHA here. Version was already 0.2.1.0 from M1; changelog updated and pushed on 2026-06-15. New kiroku HEAD: `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`.
- [x] M3: shibuya — `runIngesterAndProcessor` observes the ingester async (poll after drain, mark `Failed`, set done, rethrow). Completed on 2026-06-15 in upstream commit `f0c9ce3`.
- [x] M3: shibuya — tests in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`: failing source marks processor `Failed` and propagates; healthy path unchanged. Completed on 2026-06-15 in upstream commit `f0c9ce3`.
- [x] M3: shibuya — `cabal test shibuya-core-test` green; bump to 0.7.1.0 + CHANGELOG; commit, push. Completed and pushed on 2026-06-15; `cabal test shibuya-core-test` passed with 118 examples, 0 failures.
- [x] M4: shibuya-pgmq-adapter — add `PollRetryConfig` (+ default) to `Shibuya/Adapter/Pgmq/Config.hs` and a `pollRetry` field on `PgmqAdapterConfig`. Completed on 2026-06-15 in upstream commit `319b3b717c0284d8c207375151b388639039a1e1`.
- [x] M4: shibuya-pgmq-adapter — wrap the poll in `pgmqChunks` with transient-aware bounded-backoff retry (`Error PgmqRuntimeError` constraint added). Completed on 2026-06-15 in upstream commit `319b3b717c0284d8c207375151b388639039a1e1`.
- [x] M4: shibuya-pgmq-adapter — new `RetrySpec` with stub Pgmq interpreter (transient-then-success, permanent, exhaustion). Implemented in `Shibuya.Adapter.Pgmq.InternalSpec` on 2026-06-15.
- [x] M4: shibuya-pgmq-adapter — `cabal test shibuya-pgmq-adapter-test` green; bump to 0.8.0.0 + CHANGELOG; commit, push. Completed and pushed on 2026-06-15; `cabal test shibuya-pgmq-adapter:shibuya-pgmq-adapter-test --enable-tests` passed with 134 examples, 0 failures.
- [ ] M5: ephemeral-pg — `createCache` copies to a unique temp dir and atomically renames; concurrent-winner rename failure treated as success
- [ ] M5: ephemeral-pg — concurrent `createCache` test in `test/Main.hs`; `cabal test` green; bump to 0.2.2.0 + CHANGELOG; commit, push
- [ ] M6: publish ephemeral-pg 0.2.2.0, shibuya-core 0.7.1.0, shibuya-pgmq-adapter 0.8.0.0 to Hackage
- [ ] M6: keiro — bump kiroku `tag:` in `cabal.project` (both stanzas), relax `shibuya-pgmq-adapter` bound in `keiro-pgmq/keiro-pgmq.cabal`, fix the one `PgmqAdapterConfig` construction site if needed
- [ ] M6: keiro — `cabal build all` and all test suites (`keiro-test`, `keiro-pgmq-test`, `keiro-migrations-test`, `jitsurei-test`) green; commit


## Surprises & Discoveries

- 2026-06-15: The kiroku M1 code and tests were already present in upstream commit `fa43ec2` when this implementation pass began, although this plan's checklist had not been updated. Running `cabal test kiroku-store-test` after the M2 change revalidated those M1 tests together with the new point-lookup tests.
- 2026-06-15: `kiroku-store` was already at version `0.2.1.0` before M2, so M2 did not bump the version again. The M2 public API was recorded in `kiroku-store/CHANGELOG.md` under `Unreleased`, and the pushed SHA for keiro's later `cabal.project` pin is `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`.
- 2026-06-15: shibuya-core's `runSupervised` links child failures back to the caller thread, so tests that assert ingester failure propagation must run the supervised app in a separate async and inspect `waitCatch`. Plain `try` around the effectful action does not reliably catch the linked async exception in Hspec.
- 2026-06-15: shibuya-pgmq-adapter's Cabal default test selector did not include `shibuya-pgmq-adapter-test`; the reliable command is `cabal test shibuya-pgmq-adapter:shibuya-pgmq-adapter-test --enable-tests`. The codebase's `NoFieldSelectors` setup also means nested record-dot access like `config.pollRetry.initialBackoff` is not available for `PollRetryConfig`; pattern matching the retry config kept the implementation and tests compiling.


## Decision Log

- Decision: Leave `pgmq-effectful` (in `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`) unchanged; implement the transient-error retry in shibuya-pgmq-adapter's polling loop instead of inside the pgmq interpreter.
  Rationale: Research showed `isTransient :: PgmqRuntimeError -> Bool` is already exported from `Pgmq.Effectful` (re-exported from `pgmq-effectful/src/Pgmq/Effectful/Interpreter.hs`), so the classifier is available downstream. Retrying inside the interpreter's `runSession` would silently re-execute *every* operation, including non-idempotent ones (`sendMessage`, `deleteMessage`, `archiveMessage`); the queue *read* (`readMessage`/`readWithPoll`) is the only operation where blanket retry is safe, and that call site lives in `pgmqChunks` in shibuya-pgmq-adapter.
  Date: 2026-06-10

- Decision: The kiroku point lookup is named `eventExistsInStream` with signature `eventExistsInStream :: (HasCallStack, Store :> es) => StreamName -> EventId -> Eff es Bool`, exposed from `Kiroku.Store.Read` (and via the `Kiroku.Store` umbrella). Soft-deleted streams report `False`.
  Rationale: The name states the scoping (existence *within a named stream*, not globally). It is a `Store` effect constructor like every other read, so keiro reaches it through the exact effect surface it already uses (`Kiroku.Store.Read` imports in `keiro/src/Keiro/ProcessManager.hs`). Returning `False` for soft-deleted streams mirrors `readStreamForward`'s SQL (`deleted_at IS NULL` filter), so replacing keiro's scan with the point lookup is behavior-preserving. EP-5 consumes this from the Interfaces and Dependencies section below.
  Date: 2026-06-10

- Decision: The transactional runner maps usage errors via a new `mapTransactionUsageError :: UsageError -> StoreError` defined as `mapUsageError "<transaction>" AnyVersion`, rather than threading real stream context into `RunTransaction`.
  Rationale: `RunTransaction` carries an opaque `Hasql.Transaction.Transaction` — there is no stream name or expected version to attribute. The mapping that matters (`23505` + constraint `events_pkey` → `DuplicateEvent`) does not use the stream context at all; the other branches (`StreamAlreadyExists`, `WrongExpectedVersion`, `StreamNotFound`) gain a sentinel name `"<transaction>"`, which is still strictly more informative than today's blanket `ConnectionError`. Changing the `RunTransaction` constructor's type to carry context would break every caller for no benefit.
  Date: 2026-06-10

- Decision: Ingester failure propagation uses poll-after-drain (capture the async handle, let the processor drain the inbox, then `poll` the handle and rethrow a stored exception), marking the processor `Failed` in metrics and setting its done flag before rethrowing — not `link`.
  Rationale: `link` would deliver the ingester's exception asynchronously into the processor thread, killing in-flight handler work and re-processing those messages later. Poll-after-drain lets already-ingested messages finish (they were read from the queue; finishing them is strictly better), then converts "ingester died" from an invisible event into a real child failure the NQE supervisor and the `link` in `runSupervised` observe. Setting `done` plus `Failed` state means `waitApp` does not hang under the `IgnoreFailures` strategy and callers can distinguish "completed" from "failed" via `getProcessorState`.
  Date: 2026-06-10

- Decision: shibuya-pgmq-adapter is released as 0.8.0.0 (PVP major); shibuya-core as 0.7.1.0; ephemeral-pg as 0.2.2.0; kiroku-store as 0.2.1.0.
  Rationale: Adding the `pollRetry` field to the exported `PgmqAdapterConfig` record and adding an `Error PgmqRuntimeError :> es` constraint to `pgmqAdapter`/`pgmqSource` are breaking per the PVP, hence 0.8.0.0; keiro-pgmq's bound (`shibuya-pgmq-adapter >=0.7 && <0.8`) is bumped in M6. shibuya-core's change is behavioral only (no exported signature changes), ephemeral-pg's is internal, and kiroku-store only adds exports — minor bumps. keiro consumes kiroku by git pin so its version number is informational, but the bump keeps the changelog honest.
  Date: 2026-06-10

- Decision: `createCache` treats a rename failure where the final cache directory already exists as success (a concurrent winner), and re-checks for an existing cache before copying.
  Rationale: With N suites racing on a cold cache, exactly one rename wins; the losers' caches are byte-equivalent (same initdb inputs — the cache key hashes them), so "someone else won" is success. Failing the losers would cascade into `startAndCache` fallbacks for no reason.
  Date: 2026-06-10

- Decision: keiro picks up shibuya-core, shibuya-pgmq-adapter, and ephemeral-pg via Hackage releases (the channel it uses today — verified against `~/.cabal/packages/hackage.haskell.org`, which carries shibuya-core 0.7.0.0, shibuya-pgmq-adapter 0.7.0.0, ephemeral-pg 0.2.1.0), and kiroku via the `source-repository-package` git tag in `cabal.project`. Temporary `source-repository-package` pins may be used to validate keiro against the fixes *before* publishing, but must be removed once the Hackage releases exist.
  Rationale: keiro's `cabal.project` pins only keiki, kiroku, codd, and hasql-migration from git; everything else resolves from Hackage. Keeping that split avoids a permanent pin sprawl. All four packages are owned by the author (`maintainer: nadeem@gmail.com`), so publishing is a `cabal upload --publish` away (ephemeral-pg even has a `just release` recipe).
  Date: 2026-06-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The four repositories and how keiro consumes them

All paths are absolute because this plan edits four separate git repositories.

- **keiro** — `/Users/shinzui/Keikaku/bokuno/keiro` (this repo). Packages: `keiro-core`, `keiro`, `keiro-pgmq`, `keiro-test-support`, `keiro-migrations`, `jitsurei` (example service), `keiro-dsl`. Its `cabal.project` pins **kiroku** as a git `source-repository-package` (`location: https://github.com/shinzui/kiroku.git`, `tag: ffcf3a143ee58c09f17dc8d5746bad7d8ed4525a`, subdirs `kiroku-store` and `kiroku-store-migrations`). That tag is currently kiroku's `master` HEAD, so bumping it after this plan's kiroku commits is a clean fast-forward. Everything else upstream (shibuya-core, shibuya-pgmq-adapter, pgmq-effectful, ephemeral-pg) resolves from **Hackage** — there are no pins for them in `cabal.project` and no `cabal.project.local`.
- **kiroku** — `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (remote `git@github.com:shinzui/kiroku.git`). The package this plan touches is `kiroku-store` (version 0.2.0.0), a PostgreSQL **event store**: an append-only log where each *stream* (named sequence of events, e.g. `order-42`) holds immutable events identified by a UUID *event id*. Schema (from `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`): table `streams` (`stream_id BIGSERIAL PRIMARY KEY`, `stream_name TEXT` with `UNIQUE` constraint named `ix_streams_stream_name`, `deleted_at TIMESTAMPTZ` for soft deletes), table `events` (`event_id UUID PRIMARY KEY` — the primary-key constraint Postgres auto-names `events_pkey`), and junction table `stream_events` (`PRIMARY KEY (event_id, stream_id)`, plus `stream_version`). The composite primary key on `stream_events` has `event_id` as its leading column, so a probe by `(event_id, stream_id)` is an index point lookup.
- **shibuya** — `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` (remote `git@github.com:shinzui/shibuya.git`), package `shibuya-core` 0.7.0.0. A queue-processing runtime: an *adapter* exposes a Streamly stream of messages (the *source*), an *ingester* thread pulls from that stream into a bounded in-memory *inbox*, and a *processor* loop pulls from the inbox and runs the user's handler, acknowledging each message (`AckOk`, `AckRetry`, `AckDeadLetter`, `AckHalt`). Workers run under a supervisor from the `nqe` library (`Control.Concurrent.NQE.Supervisor`), wired up in `shibuya-core/src/Shibuya/Runner/Master.hs` and `Shibuya/App.hs` (`runApp` / `waitApp` / `stopApp`).
- **shibuya-pgmq-adapter** — `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` (remote `https://github.com/shinzui/shibuya-pgmq-adapter.git`), package `shibuya-pgmq-adapter` 0.7.0.0. Implements the shibuya adapter on top of **PGMQ** (a PostgreSQL extension providing durable message queues), via the `Pgmq` *effect* — a dynamically dispatched effect from the `effectful` library, interpreted by `pgmq-effectful` (in `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful`, version 0.3.0.0, **not modified by this plan**). In `effectful`, errors travel through the `Error e` effect: interpreters call `throwError`, callers `catchError`, and a `runError`-style handler at the top of the stack converts to `Either`.
- **ephemeral-pg** — `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg` (remote `git@github.com:shinzui/ephemeral-pg.git`), version 0.2.1.0. Starts throwaway PostgreSQL servers for tests. *initdb* is the PostgreSQL tool that creates a fresh data directory (slow, ~seconds); ephemeral-pg caches one initdb result per (PostgreSQL major version, config hash) under `~/.cache/ephemeral-pg/cache/<version>-<hash>/data` and clones it (copy-on-write `cp -c`/`--reflink` when the filesystem supports it) for each test server. keiro's `keiro-test-support` package and the kiroku, shibuya-pgmq-adapter, and keiro-pgmq test suites all sit on top of it.

### Finding A — kiroku's transaction runner hides `DuplicateEvent` (verified)

`kiroku-store/src/Kiroku/Store/Error.hs` has a careful hasql-error translation: `mapUsageError :: Text -> ExpectedVersion -> UsageError -> StoreError` walks the hasql error hierarchy down to the PostgreSQL server error and maps code `23505` (unique violation) via `mapUniqueViolation` — constraint `events_pkey` becomes `DuplicateEvent (Maybe EventId)` (the duplicate id parsed from the server's detail string), constraint `ix_streams_stream_name` becomes `StreamAlreadyExists`, code `23503` becomes `StreamNotFound`, anything else `UnexpectedServerError`. The non-transactional `AppendToStream` interpreter branch uses it (`Kiroku/Store/Effect.hs`, `throwError (mapUsageError name expected usageErr)`), and `AppendMultiStream` uses the sibling `attributeMultiStreamError`.

But the transactional escape hatch — the `RunTransaction` / `RunTransactionNoRetry` constructors of the `Store` effect, surfaced as `runTransaction`, `runTransactionNoRetry`, `appendToStreamTx`, and `runTransactionAppending` in `kiroku-store/src/Kiroku/Store/Transaction.hs` — is interpreted by `runTxOnPool` in `kiroku-store/src/Kiroku/Store/Effect.hs`, which flattens **every** failure:

```haskell
    case result of
        Left usageErr -> throwError (ConnectionError (T.pack (show usageErr)))
        Right a -> pure a
```

(The private `usePool` helper a few lines above does the same, but it only serves plain reads, where a unique violation cannot occur; this plan leaves `usePool` alone.) `appendToStreamTx` returns version-conflict outcomes as `Either AppendConflict` by inspecting the append CTE's result, but a duplicate caller-supplied event id raises `23505` on `events_pkey` *from the server*, escapes the transaction body as a `UsageError`, and lands in the branch above as `ConnectionError "...23505...events_pkey..."`.

Downstream effect in keiro: `keiro/src/Keiro/ProcessManager.hs` (lines ~229–277) and `keiro/src/Keiro/Router.hs` (lines ~157–158) fold `Left (StoreFailed (DuplicateEvent ...))` into the benign `PMCommandDuplicate` outcome, and `keiro/src/Keiro/Workflow/Awakeable.hs` documents treating `DuplicateEvent` as success. All of keiro's appends that go through projections/workflows use the transactional path (`runTransaction` / `runTransactionAppending` imports in `Keiro/Command.hs`, `Keiro/Workflow.hs`, etc.), so those folds are dead code today: a concurrent duplicate delivery becomes `ConnectionError` → `AckHalt` → worker halt.

### Finding B — no event-id point lookup (verified)

`keiro/src/Keiro/ProcessManager.hs`, `eventAlreadyIn` (lines ~329–338), answers "was this command already applied" by streaming the whole target stream from `StreamVersion 0` through `readStreamForwardStream` and folding `Fold.any` over event ids — one full page-by-page scan per dispatched event. The `events` primary key and the `stream_events` composite key make a point probe trivial, but kiroku exposes no API for it. `Kiroku.Store.Read` (in `kiroku-store/src/Kiroku/Store/Read.hs`) is where keiro gets `readStreamForwardStream`; the new lookup goes in the same module so keiro changes one import. The read-path SQL convention to mirror (from `readStreamForwardSQL` in `kiroku-store/src/Kiroku/Store/SQL.hs`): resolve the stream with `(SELECT stream_id FROM streams WHERE stream_name = $1 AND deleted_at IS NULL)` so soft-deleted streams behave as nonexistent.

### Finding C — shibuya silently loses workers on transient poll errors (verified)

`shibuya-core/src/Shibuya/Runner/Supervised.hs`, `runIngesterAndProcessor` (lines ~227–256):

```haskell
    let ingesterWithSignal =
          runInIO (runIngesterWithMetrics metricsVar adapter.source inbox)
            `finally` atomically (writeTVar streamDoneVar True)

    UIO.withAsync ingesterWithSignal $ \_ ->
      runInIO $ processUntilDrained metricsVar procId concurrency handler inbox streamDoneVar
```

The async handle is discarded (`\_`): no `link`, no `wait`, no `poll`. If the ingester dies — e.g. the adapter source rethrows a database error — its `finally` sets `streamDoneVar`, the processor drains the inbox, exits normally, `doneVar` is set, `waitApp` (in `Shibuya/App.hs`) reports completion, the supervised child returns cleanly, and the NQE supervisor sees nothing to restart. The queue backs up silently.

The error that triggers this is real and unretried: `pgmq-effectful/src/Pgmq/Effectful/Interpreter.hs`'s `runSession` turns every `Pool.use` failure into `throwError (fromUsageError err)` (a `PgmqRuntimeError`), even though the same module defines and exports `isTransient :: PgmqRuntimeError -> Bool` (acquisition timeouts, networking errors, connection drops → `True`). The polling call site is `pgmqChunks` in `shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` (`Stream.repeatM poll`, where `poll` dispatches `readMessage` / `readWithPoll` / the grouped FIFO variants). One connection blip → `throwError` → stream dies → ingester dies → silence.

Two notes for the implementer. First, `processUntilDrained` exits when `streamDoneVar` is set *and* the inbox is empty, so after it returns the ingester async has either finished or failed — except when the processor halts early via the halt flag, in which case the ingester may still be running; `UIO.poll` (returns `Nothing` if still running) handles both cases correctly where `UIO.wait` would deadlock the halt path. Second, `Error PgmqRuntimeError` is implemented by `effectful` with internal exceptions, so an uncaught `throwError` inside the unlifted async surfaces to `UIO.poll` as `Just (Left someException)`; rethrowing it in the parent thread re-enters the same `Eff` stack and unwinds to the caller's `runErrorNoCallStack` (in keiro that is `runJobEff` in `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`) — exactly the visibility we want.

### Finding D — ephemeral-pg cold-cache race (verified)

`ephemeral-pg/src/EphemeralPg/Internal/Cache.hs`, `createCache` (lines 172–182), copies the initdb output **directly into the final cache path**:

```haskell
createCache key srcDataDir mRoot = do
  dir <- getCacheDirectory key mRoot
  createDirectoryIfMissing True dir
  let dstDataDir = dir </> "data"
  cowCapability <- detectCowCapability dir
  copyDirectory cowCapability srcDataDir dstDataDir
```

and `isCached` (lines 165–169) is just `doesDirectoryExist (dir </> "data")`. The copy takes long enough (tens of MB) that a second process can see the directory mid-copy: `isCached` returns `True`, `restoreFromCache` clones a torn data directory, and postgres fails to start (or worse, starts and behaves oddly). The call path is `startCached` → `startAndCache` in `ephemeral-pg/src/EphemeralPg.hs` (lines ~343–410). `copyDirectory` (in `EphemeralPg/Internal/CopyOnWrite.hs`) shells out to `cp -cR` / `cp --reflink` / `cp -R` and requires the destination not to exist, which suits a fresh temp path. The library already depends on `unix` (for a pid) and `directory` ≥1.3 (which has `renamePath`); `Data.Unique` from `base` supplies a per-process unique counter. A rename within the same parent directory is on one filesystem, so POSIX guarantees atomicity.

### Test infrastructure you will touch

- kiroku: `kiroku-store/test/Test/Helpers.hs` provides `withTestStore :: (KirokuStore -> IO ()) -> IO ()` (ephemeral Postgres + migrated schema via `kiroku-test-support`); `Test/Transaction.hs` and `test/Main.hs` show the patterns to mirror (the existing non-transactional duplicate test is `test/Main.hs` "rejects duplicate event IDs", which constructs `EventData { eventId = Just eid, ... }`).
- shibuya-core: `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` builds in-memory `Adapter`s from `Stream.fromList` of hand-rolled `Ingested` values — no database needed; a failing source is just a stream whose effect throws.
- shibuya-pgmq-adapter: `Pgmq` is a dynamically dispatched effect, so a retry unit test interprets it with a stub (`interpret` from `Effectful.Dispatch.Dynamic`) that fails N times from an `IORef` counter, no database needed. Integration tests use `test/TmpPostgres.hs` (ephemeral-pg + pgmq extension).
- ephemeral-pg: `test/Main.hs` (suite `ephemeral-pg-test`, hspec) already has an "EphemeralPg caching" describe block; `createCache`, `isCached`, `restoreFromCache`, `getCacheKey`, `clearCache`, `CacheConfig(..)`, `defaultConfig` are all exported from the public `EphemeralPg` module (`CacheKey` is abstract — obtain one via `getCacheKey`).

All four repos build with the same toolchain keiro's dev shell provides (GHC 9.12.4, cabal 3.16, PostgreSQL 18 on PATH). Each repo also has its own `flake.nix` dev shell; either works. Commands below assume a shell where `cabal`, `ghc`, `postgres`, and `initdb` resolve (e.g. start from `/Users/shinzui/Keikaku/bokuno/keiro` with direnv active, then `cd` to the other repos).


## Plan of Work

### Milestone 1 — kiroku: transactional appends surface `DuplicateEvent`

Scope: `kiroku-store` only. At the end, a duplicate caller-supplied event id appended inside `runTransaction`/`runTransactionAppending` produces `Left (DuplicateEvent (Just eid))` from `runStoreIO`, proven by new tests that fail on the current code.

Work. In `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Error.hs`, add and export (in the module export list next to `mapUsageError`):

```haskell
{- | Map a hasql 'UsageError' raised inside an opaque 'RunTransaction' /
'RunTransactionNoRetry' body to a 'StoreError'.

The transaction body is opaque, so no stream name or expected version is
available for attribution; the sentinel stream name @\"\<transaction\>\"@ and
'AnyVersion' stand in. The mapping that matters — PostgreSQL error 23505 on
constraint @events_pkey@ becoming 'DuplicateEvent' — carries the duplicate
event id parsed from the server detail and needs no stream context.
-}
mapTransactionUsageError :: UsageError -> StoreError
mapTransactionUsageError = mapUsageError "<transaction>" AnyVersion
```

In `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Effect.hs`, import it (extend the existing `Kiroku.Store.Error` import) and change `runTxOnPool`'s failure branch from `throwError (ConnectionError (T.pack (show usageErr)))` to `throwError (mapTransactionUsageError usageErr)`. `runTxOnPool` is the single interpreter for both `RunTransaction` and `RunTransactionNoRetry`, so one edit covers `runTransaction`, `runTransactionNoRetry`, `runTransactionAppending`, and `runTransactionAppendingNoRetry`. Also update the "Errors:" paragraph in `runTransaction`'s haddock in `kiroku-store/src/Kiroku/Store/Transaction.hs`, which currently promises the `ConnectionError` translation.

In `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/test/Test/Transaction.hs`, add two cases to the existing `around withTestStore` spec, mirroring the construction in the existing tests (use `prepareEventsIO` on an `EventData` whose `eventId` is `Just`, append once successfully via `runTransaction` + `appendToStreamTx`, then append the same id again — to a *different* stream name, to prove this is the id-uniqueness signal rather than a version conflict — and assert the result is `Left (DuplicateEvent (Just eid))`). Add the second case through `runTransactionAppending` (the wrapper keiro's workflow path uses). Before the fix these tests fail with `Left (ConnectionError "...23505...events_pkey...")`; that failure output is the proof the test bites.

Result/proof: `cabal test kiroku-store-test` in the kiroku repo passes, including the two new examples; reverting the `runTxOnPool` edit makes exactly those two fail.

### Milestone 2 — kiroku: `eventExistsInStream` point lookup

Scope: `kiroku-store` only. At the end, kiroku exposes the API recorded in Interfaces and Dependencies, and the kiroku commits are pushed so M6 (and EP-5) can pin them.

Work, in three layers mirroring how every other read is wired:

1. `kiroku-store/src/Kiroku/Store/SQL.hs` — add to the "Read statements" export group and define (style modeled on `findStreamIdStmt`; the two-parameter encoder uses `contrazip2` from `contravariant-extras`, already a dependency):

```haskell
-- | Point probe: does an event with this id exist in this (live) stream?
-- Backed by the stream_events composite primary key (event_id, stream_id);
-- soft-deleted streams behave as nonexistent, mirroring readStreamForwardSQL.
eventExistsInStreamStmt :: Statement (Text, UUID) Bool
eventExistsInStreamStmt =
    preparable
        """
        SELECT EXISTS (
          SELECT 1
          FROM stream_events se
          WHERE se.event_id = $2
            AND se.stream_id = (SELECT stream_id FROM streams
                                WHERE stream_name = $1 AND deleted_at IS NULL)
        )
        """
        (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.uuid)))
        (D.singleRow (D.column (D.nonNullable D.bool)))
```

2. `kiroku-store/src/Kiroku/Store/Effect.hs` — add a constructor to the `Store` effect GADT, placed with the other reads and documented like `LookupStreamId`:

```haskell
    EventExistsInStream :: StreamName -> EventId -> Store m Bool
```

and an interpreter branch in `runStorePool`:

```haskell
    EventExistsInStream (StreamName name) (EventId eid) ->
        usePool (store ^. #pool) $
            Session.statement (name, eid) SQL.eventExistsInStreamStmt
```

Research note: the only exhaustive matches on `Store` constructors in any repo this initiative touches are `runStorePool` itself and the append helpers in `Kiroku/Store/Append.hs` (which match values, not the effect), so adding a constructor breaks no other interpreter. Mock `Store` interpreters do not exist in keiro.

3. `kiroku-store/src/Kiroku/Store/Read.hs` — export and define the wrapper exactly as recorded in Interfaces and Dependencies (`Kiroku.Store` re-exports the whole module, so no umbrella edit is needed).

Tests in `kiroku-store/test/Test/ReadStream.hs` (or a sibling `it` group in `test/Main.hs` if `ReadStream.hs` is organized incompatibly — implementer's choice, recorded in Progress): append an event with a caller-supplied id to stream A; assert `eventExistsInStream A eid ≡ True`, `eventExistsInStream B eid ≡ False` (other live stream), `eventExistsInStream A otherEid ≡ False`, and after `softDeleteStream A` (see `Kiroku.Store.Lifecycle`) `eventExistsInStream A eid ≡ False`.

Then bump `version:` in `kiroku-store/kiroku-store.cabal` to `0.2.1.0`, add a `kiroku-store/CHANGELOG.md` entry covering M1+M2 (new export `mapTransactionUsageError`, new API `eventExistsInStream`, behavior change: transactional usage errors now mapped like append errors), commit both milestones (conventional commits, e.g. `fix(kiroku-store): surface DuplicateEvent from transactional appends` and `feat(kiroku-store): add eventExistsInStream point lookup`), push to `origin master`, and record the new HEAD SHA in this plan's Progress notes — M6 pastes it into keiro's `cabal.project`.

Result/proof: `cabal test kiroku-store-test` green; `git -C /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku log --oneline -3` shows the two commits on top of `ffcf3a1`.

### Milestone 3 — shibuya-core: a dead ingester is a dead worker, visibly

Scope: `shibuya-core` only. At the end, an adapter source that throws makes the supervised worker *fail* (processor metrics state `Failed`, exception propagated to the supervisor/linked parent) instead of completing silently.

Work. In `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/Runner/Supervised.hs`, rewrite the `withAsync` block of `runIngesterAndProcessor` to keep the handle and poll it after the processor drains:

```haskell
    UIO.withAsync ingesterWithSignal $ \ingesterAsync -> do
      runInIO $ processUntilDrained metricsVar procId concurrency handler inbox streamDoneVar
      -- The processor has drained (or halted). If the ingester died with an
      -- exception rather than finishing its stream, surface it: a worker
      -- whose ingester is dead must not look like a worker that completed.
      UIO.poll ingesterAsync >>= \case
        Just (Left ingesterErr) -> do
          now <- getCurrentTime
          atomically $ modifyTVar' metricsVar $ \m ->
            m { state = Failed (Text.pack (displayException ingesterErr)) now }
          atomically $ writeTVar doneVar True
          UIO.throwIO ingesterErr
        _ -> pure ()
```

(`poll` returns `Nothing` while the ingester still runs — only possible on the early-halt path, where `withAsync`'s exit cancels it as today; `Just (Right ())` is normal stream completion. Field-update syntax must match the module's existing style; `ProcessorMetrics`/`Failed` come from `Shibuya.Runner.Metrics`, already imported. `doneVar` is set here *before* rethrowing because the normal set at the function's end is skipped by the throw; this keeps `waitApp` from hanging under `IgnoreFailures` while `getProcessorState` reports `Failed`.) Keep the existing `doneVar` set at the end for the normal path. Note the rethrown exception then flows through `runSupervised`'s existing plumbing unchanged: the `ProcessorHalt` catch does not match it, `finally unregisterProcessor` runs, the NQE child fails, and the `UIO.link supervisedChild` propagates it — that is the "supervisor observes a real failure" requirement, with no changes needed in `Master.hs` or `App.hs`.

Tests in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`, following the spec's existing in-memory adapter pattern: (1) an adapter whose source yields two good messages and then throws (e.g. `Stream.fromList [pure i1, pure i2] <> Stream.fromEffect (liftIO (throwIO ...))` composed with `Stream.mapM id`, or the simpler existing trick of `Stream.fromEffect` raising mid-stream) — assert both messages were handled (drain preserved), `getProcessorState` is `Failed _ _`, `isDone` is `True`, and the failure escaped (wrap the `runSupervised`-driven run in `try @SomeException`, or with `runApp StopAllOnFailure` observe the app stop). (2) A regression guard: the existing happy-path specs still pass (stream completes → state not `Failed`). Before the fix, test (1) fails because the state stays non-`Failed` and nothing escapes.

Then bump `shibuya-core.cabal` to `0.7.1.0`, update the repo `CHANGELOG.md`, commit (`fix(shibuya-core): propagate ingester failure instead of silent completion`), push.

Result/proof: `cabal test shibuya-core-test` green in `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; reverting the `Supervised.hs` hunk fails the new spec.

### Milestone 4 — shibuya-pgmq-adapter: transient poll errors retry with bounded backoff

Scope: `shibuya-pgmq-adapter` only (pgmq-effectful is untouched — see Decision Log). At the end, a transient `PgmqRuntimeError` during a poll is retried up to a configurable bound with exponential backoff; a permanent error or exhausted budget rethrows (which, after M3, fails the worker visibly instead of silently).

Work. In `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs`, add:

```haskell
-- | Retry policy for transient database errors during queue polling.
-- Classification uses 'Pgmq.Effectful.isTransient'; permanent errors are
-- never retried. Backoff doubles from 'initialBackoff' up to 'maxBackoff'.
data PollRetryConfig = PollRetryConfig
  { -- | Total attempts per poll, including the first (>= 1; 1 = no retry)
    maxAttempts :: !Int,
    -- | Delay before the first retry
    initialBackoff :: !NominalDiffTime,
    -- | Cap on the doubling backoff
    maxBackoff :: !NominalDiffTime
  }
  deriving stock (Show, Eq, Generic)

-- | 5 attempts, 100 ms doubling to a 5 s cap (~3 s worst-case total wait).
defaultPollRetryConfig :: PollRetryConfig
defaultPollRetryConfig = PollRetryConfig 5 0.1 5
```

add a field `pollRetry :: !PollRetryConfig` to `PgmqAdapterConfig`, set it to `defaultPollRetryConfig` in `defaultConfig`, and export the new names (also from the public `Shibuya.Adapter.Pgmq` module, which re-exports config types).

In `src/Shibuya/Adapter/Pgmq/Internal.hs`, give `pgmqChunks` (and transitively `pgmqMessages`, `pgmqSource`, the prefetch variants, and `pgmqAdapter` in `Shibuya/Adapter/Pgmq.hs`) the extra constraint `Error PgmqRuntimeError :> es` (import `Effectful.Error.Static (Error, catchError, throwError)` and `Pgmq.Effectful (PgmqRuntimeError, isTransient)`), and wrap the existing `poll`:

```haskell
    pollRetrying :: Int -> NominalDiffTime -> Eff es (Vector Pgmq.Message)
    pollRetrying attempt backoff =
      poll `catchError` \_callStack err ->
        if isTransient err && attempt < config.pollRetry.maxAttempts
          then do
            liftIO $ threadDelay (nominalToMicros backoff)
            pollRetrying (attempt + 1) (min (backoff * 2) config.pollRetry.maxBackoff)
          else throwError err
```

with the stream becoming `Stream.repeatM (pollRetrying 1 config.pollRetry.initialBackoff)`. keiro-pgmq's effect stack already carries `Error PgmqRuntimeError` (see `runJobEff` in `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`), so the constraint addition is source-compatible there; it is still a PVP-major change (Decision Log).

Tests: new `test/Shibuya/Adapter/Pgmq/RetrySpec.hs` (register in the cabal test-suite's `other-modules` and the hspec `Main.hs`), interpreting `Pgmq` with a stub: an `IORef Int` counts calls; the `ReadWithPoll`/`ReadMessage` branch throws a transient error (`PgmqAcquisitionTimeout`) while the counter is below N, then returns a one-message batch; all other constructors `error "unused"`. Drive `Stream.take 1 (pgmqChunks cfg)` under `runEff . runErrorNoCallStack . runStub`. Assert: (1) N=2 failures with `maxAttempts = 5` still yields the batch and the counter shows 3 calls; (2) a permanent error (`PgmqSessionError (HasqlErrors.DriverSessionError ...)` or any constructor `isTransient` rejects) surfaces as `Left` after exactly 1 call; (3) `maxAttempts = 2` with 5 pending failures surfaces `Left` after exactly 2 calls. Use tiny backoffs (e.g. `0.001`) so the suite stays fast. Run the existing integration suite too (needs `postgres` with the pgmq extension via the repo's test fixture — `cabal test shibuya-pgmq-adapter-test` handles it through ephemeral-pg).

Then bump `shibuya-pgmq-adapter.cabal` to `0.8.0.0`, CHANGELOG, commit (`feat(shibuya-pgmq-adapter)!: retry transient poll errors with bounded backoff`), push.

Result/proof: `cabal test shibuya-pgmq-adapter-test` green in `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`.

### Milestone 5 — ephemeral-pg: atomic initdb-cache creation

Scope: ephemeral-pg only. At the end, `createCache` never exposes a partially written `data` directory, and N concurrent cold-cache creations all succeed with a valid cache.

Work. Rewrite `createCache` in `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg/src/EphemeralPg/Internal/Cache.hs`:

```haskell
createCache :: CacheKey -> FilePath -> Maybe FilePath -> IO (Either Text ())
createCache key srcDataDir mRoot = do
  dir <- getCacheDirectory key mRoot
  createDirectoryIfMissing True dir
  let dstDataDir = dir </> "data"
  alreadyCached <- doesDirectoryExist dstDataDir
  if alreadyCached
    then pure (Right ())
    else do
      -- Stage into a unique sibling, then atomically rename into place, so a
      -- concurrent reader can never observe a half-written cache: isCached
      -- only sees "data" after the rename commits it.
      pid <- getProcessID
      uniq <- hashUnique <$> newUnique
      let tmpDataDir = dir </> ("data.tmp-" <> show pid <> "-" <> show uniq)
      cowCapability <- detectCowCapability dir
      copyResult <- copyDirectory cowCapability srcDataDir tmpDataDir
      case copyResult of
        Left err -> do
          removeDirectoryIfPresent tmpDataDir
          pure (Left err)
        Right () -> do
          renameResult <- try @SomeException (renamePath tmpDataDir dstDataDir)
          case renameResult of
            Right () -> pure (Right ())
            Left renameErr -> do
              -- A concurrent createCache may have renamed its copy first; its
              -- cache is byte-equivalent (same CacheKey hashes the same initdb
              -- inputs), so losing the race is success.
              removeDirectoryIfPresent tmpDataDir
              winnerExists <- doesDirectoryExist dstDataDir
              if winnerExists
                then pure (Right ())
                else pure (Left ("Failed to move cache into place: " <> T.pack (show renameErr)))
```

with a small local helper `removeDirectoryIfPresent fp = doesDirectoryExist fp >>= \e -> when e (void (try @SomeException (removeDirectoryRecursive fp)))`. New imports: `renamePath` from `System.Directory` (directory ≥1.3, already in bounds), `getProcessID` from `System.Posix.Process` (the package already depends on `unix`), `newUnique`/`hashUnique` from `Data.Unique`, `void` from `Control.Monad`. The pid+unique suffix makes the temp path collision-free across processes *and* across threads in one process; staging beside the target keeps the rename on one filesystem, which is what makes it atomic. `isCached` needs no change: it now only ever sees a fully renamed `data` directory (temp dirs are named `data.tmp-*`, never `data`).

Test in `ephemeral-pg/test/Main.hs`, inside the existing caching describe block, using only public `EphemeralPg` exports: create a temp cache root and a fake source "data dir" (a directory tree with a handful of files — `createCache` only copies, it does not validate initdb output); obtain a `CacheKey` via `getCacheKey Pg.defaultConfig` (requires `postgres` on PATH, as the existing cache tests already do); run 8 concurrent `createCache key srcDir (Just root)` from plain `forkIO` threads coordinated with `MVar`s (no new deps); assert every result is `Right ()`, `isCached` is `True`, no `data.tmp-*` litter remains in the cache directory (`listDirectory`), and `restoreFromCache` into a fresh destination reproduces the source file listing. Before the fix this test is flaky-to-failing (concurrent `cp` into the same destination interleaves or errors); after, it is deterministic.

Then bump `ephemeral-pg.cabal` to `0.2.2.0`, CHANGELOG, commit (`fix: make initdb cache creation atomic under concurrency`), push.

Result/proof: `cabal test` green in `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`.

### Milestone 6 — releases, keiro pickup, end-to-end verification

Scope: Hackage releases for the three Hackage-consumed packages, the keiro-side pin/bound bumps, and a full keiro build/test pass. This is the milestone that makes the upstream work *real for keiro*.

Work, in order:

1. Publish to Hackage (author-owned packages; `cabal upload` uses the credentials in `~/.cabal/config`). ephemeral-pg has a guided recipe: `just release` in its repo (runs `sdist-check`, `test`, `cabal upload --publish`, `upload-docs`). shibuya-core and shibuya-pgmq-adapter have no recipe; from each package directory run `cabal sdist` then `cabal upload --publish <path-to-sdist.tar.gz>` (optionally `cabal upload <sdist>` first for a revocable candidate). Publishing is permanent — see Idempotence and Recovery.
2. In keiro, update `cabal.project`: change the `tag:` of **both** kiroku stanzas (`subdir: kiroku-store` and `subdir: kiroku-store-migrations`) from `ffcf3a143ee58c09f17dc8d5746bad7d8ed4525a` to the SHA recorded in M2.
3. In `keiro-pgmq/keiro-pgmq.cabal`, change `shibuya-pgmq-adapter  >=0.7  && <0.8` to `>=0.8 && <0.9` (the `shibuya-core >=0.7 && <0.8`, `pgmq-effectful >=0.3 && <0.4`, and `ephemeral-pg >=0.2` bounds already admit the new releases). keiro's only `PgmqAdapterConfig` construction is `adapterConfigFor` in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, which uses `defaultConfig` + record update, so the new `pollRetry` field needs no keiro change; if compilation says otherwise, set the field explicitly there.
4. `cabal update` (pulls the new Hackage index entries), then build and run every suite (commands in Concrete Steps). The keiro-pgmq suite is the one that exercises shibuya 0.7.1.0/0.8.0.0 and pgmq polling end to end; `keiro-test` exercises kiroku transactional appends and ephemeral-pg fixtures.
5. Commit the keiro changes (`build(deps): pick up kiroku duplicate-event fix, shibuya supervision/retry, atomic ephemeral-pg cache`).

If you need to validate keiro against the fixes *before* publishing (recommended), temporarily add `source-repository-package` stanzas for `shibuya-core`, `shibuya-pgmq-adapter` (subdir `shibuya-pgmq-adapter`), and `ephemeral-pg` pointing at the pushed commits, run the suites, then delete the stanzas once the Hackage releases are visible and re-run. Record which mode was used in Progress.

Result/proof: in `/Users/shinzui/Keikaku/bokuno/keiro`, `cabal build all` succeeds and `cabal test keiro-test keiro-pgmq-test keiro-migrations-test jitsurei-test` all report `0 failures`.


## Concrete Steps

Each block names its working directory. Expected outputs are abbreviated; any hspec run ending in `N examples, 0 failures` (N grows as tests are added) is a pass.

Milestone 1 and 2 (kiroku):

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
git status --short   # expect: only untracked docs/ files (pre-existing); keep it that way apart from our edits
cabal build kiroku-store
cabal test kiroku-store-test
```

Expected tail of the test run:

```text
Finished in ... seconds
... examples, 0 failures
Test suite kiroku-store-test: PASS
```

To watch the M1 test bite first, add the tests before the `runTxOnPool` edit and observe:

```text
expected: Left (DuplicateEvent (Just (EventId ...)))
 but got: Left (ConnectionError "SessionUsageError ... 23505 ... events_pkey ...")
```

Then commit and push:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
git add kiroku-store
git commit -m "fix(kiroku-store): surface DuplicateEvent from transactional appends"
# ... M2 edits ...
git add kiroku-store
git commit -m "feat(kiroku-store): add eventExistsInStream point lookup"
git push origin master
git rev-parse HEAD   # record this SHA in the Progress section — M6 and EP-5 use it
```

Milestone 3 (shibuya-core):

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
cabal build shibuya-core
cabal test shibuya-core-test
git add shibuya-core CHANGELOG.md
git commit -m "fix(shibuya-core): propagate ingester failure instead of silent completion"
git push origin master
```

Milestone 4 (shibuya-pgmq-adapter; the integration specs start their own ephemeral Postgres — no external service needed):

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
cabal build shibuya-pgmq-adapter
cabal test shibuya-pgmq-adapter-test
git add shibuya-pgmq-adapter CHANGELOG.md
git commit -m "feat(shibuya-pgmq-adapter)!: retry transient poll errors with bounded backoff"
git push origin master
```

Milestone 5 (ephemeral-pg):

```bash
cd /Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg
cabal test
git add src test ephemeral-pg.cabal CHANGELOG.md
git commit -m "fix: make initdb cache creation atomic under concurrency"
git push origin master
```

Milestone 6 (releases, then keiro):

```bash
cd /Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg
just release            # sdist-check, test, cabal upload --publish, docs; confirms interactively

cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
cabal sdist shibuya-core   # prints the sdist path on the last line
cabal upload --publish dist-newstyle/sdist/shibuya-core-0.7.1.0.tar.gz

cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
cabal sdist shibuya-pgmq-adapter
cabal upload --publish dist-newstyle/sdist/shibuya-pgmq-adapter-0.8.0.0.tar.gz
```

Then in keiro (edit `cabal.project` kiroku tags and the `keiro-pgmq.cabal` bound first, per Plan of Work M6):

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal update
cabal build all
cabal test keiro-test
cabal test keiro-pgmq-test
cabal test keiro-migrations-test
cabal test jitsurei-test
git add cabal.project keiro-pgmq/keiro-pgmq.cabal
git commit -m "build(deps): pick up kiroku duplicate-event fix, shibuya supervision/retry, atomic ephemeral-pg cache"
```

(`just haskell-verify` additionally runs the website build; the four `cabal test` lines above are the acceptance gate for this plan. Hackage index propagation can lag a few minutes after upload; re-run `cabal update` if the solver does not yet see a new version.)


## Validation and Acceptance

Each milestone is accepted by behavior, not by code shape:

- M1: in the kiroku repo, the new Transaction specs prove that re-appending a caller-supplied event id through `runTransaction`/`runTransactionAppending` yields `Left (DuplicateEvent (Just eid))`. Reverting only the `runTxOnPool` hunk flips exactly those examples to failures showing `ConnectionError "...23505..."` — demonstrating the fix is load-bearing.
- M2: the new ReadStream specs prove `eventExistsInStream` answers `True`/`False` for (present, absent, wrong-stream, soft-deleted) without reading the stream; `EXPLAIN` is not asserted in tests, but you can eyeball the plan from `psql` against any kiroku database: `EXPLAIN SELECT EXISTS (SELECT 1 FROM stream_events se WHERE se.event_id = '...' AND se.stream_id = (SELECT stream_id FROM streams WHERE stream_name = '...' AND deleted_at IS NULL));` shows an Index Only/Index Scan on `stream_events_pkey`, not a Seq Scan.
- M3: the new SupervisedSpec example proves a mid-stream source exception ends with `getProcessorState ≡ Failed _ _`, `isDone ≡ True`, both already-ingested messages handled, and the exception escaping the supervised computation. On current code the same example observes a clean completion with no `Failed` state — the silent-death bug, reproduced then fixed.
- M4: RetrySpec proves transient errors are retried (call counter > 1, eventual batch delivered), permanent errors are not (counter ≡ 1), and the budget is respected (counter ≡ maxAttempts). The pre-existing integration suite (ChaosSpec etc.) still passes, proving the constraint/threading changes didn't disturb ack/DLQ behavior.
- M5: the concurrency example runs 8 simultaneous `createCache` calls against one cold cache root and requires all `Right ()`, a restorable cache, and zero temp-dir litter. On current code this test interleaves two `cp -R`s into the same path and fails (or leaves a corrupt union of both copies that the listing assertion catches).
- M6 (plan-level acceptance): `cabal build all` plus the four keiro suites green in `/Users/shinzui/Keikaku/bokuno/keiro` against kiroku@<new SHA>, shibuya-core 0.7.1.0, shibuya-pgmq-adapter 0.8.0.0, ephemeral-pg 0.2.2.0. Every suite ends `0 failures`; `cabal build all` ends `Build completed` with no errors. This demonstrates keiro consumes the new behavior without source breakage beyond the one cabal bound.

Note what this plan deliberately does **not** validate: keiro-side behavioral exploitation of the new kiroku APIs (switching `eventAlreadyIn` to the point lookup, the live duplicate fold under concurrent delivery) is EP-5's scope (`docs/plans/71-fix-process-manager-and-router-delivery-correctness.md`), and the keiro-pgmq worker-resilience acceptance test rides in EP-8 (`docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md`).


## Idempotence and Recovery

All code edits are ordinary git work in clean repos (verify with `git status --short` before starting in each repo; kiroku has pre-existing untracked `docs/` files — leave them). Any milestone can be redone by `git checkout -- <paths>` and re-applying. Test suites are self-contained: kiroku, shibuya-pgmq-adapter, and ephemeral-pg suites boot their own throwaway Postgres via ephemeral-pg (they need `postgres`/`initdb` on PATH, which the dev shells provide); shibuya-core's suite is pure in-memory. Suites can be re-run any number of times; the ephemeral-pg concurrency test must create its cache root under a fresh temp directory each run (use `withSystemTempDirectory`) so reruns never see a warm cache.

The one irreversible step is `cabal upload --publish` (Hackage releases cannot be deleted, only revised/deprecated). Mitigations: run each repo's full test suite immediately before publishing; for the two packages without a release recipe, optionally upload a *candidate* first (`cabal upload <sdist>` without `--publish`, inspect at the printed URL, then publish). If a published release turns out broken, publish a patch version — do not attempt to mutate the release. The keiro pickup commit is trivially revertible (`git revert`), and the kiroku `tag:` bump can be pointed back at `ffcf3a143ee58c09f17dc8d5746bad7d8ed4525a` at any time since git pins are immutable.

If Hackage publishing must be deferred (e.g. the author wants to batch releases), M6's fallback keeps the plan completable: pin `shibuya-core`, `shibuya-pgmq-adapter`, and `ephemeral-pg` as `source-repository-package` stanzas in keiro's `cabal.project` at the pushed SHAs, run the verification, and leave a Progress note that the stanzas must be replaced by Hackage versions when published. The plan is not "Complete" until the steady-state (Hackage) configuration is in place.


## Interfaces and Dependencies

**The contract EP-5 consumes** (`docs/plans/71-fix-process-manager-and-router-delivery-correctness.md` reads this section; do not rename without updating it there):

```haskell
-- kiroku-store >= 0.2.1.0, module Kiroku.Store.Read (re-exported by Kiroku.Store)

-- | Point probe: does an event with this id already exist in this stream?
-- One indexed SELECT EXISTS against the stream_events composite primary key
-- (event_id, stream_id). Returns False for nonexistent and for soft-deleted
-- streams, mirroring readStreamForward's visibility rules. Intended for
-- pre-dispatch idempotency guards (keiro's eventAlreadyIn), replacing
-- O(stream-length) forward scans.
eventExistsInStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    EventId ->
    Eff es Bool
```

Backing pieces inside kiroku-store (internal to this plan but named for the implementer): effect constructor `EventExistsInStream :: StreamName -> EventId -> Store m Bool` in `Kiroku.Store.Effect`; statement `eventExistsInStreamStmt :: Statement (Text, UUID) Bool` in `Kiroku.Store.SQL`. Also new in 0.2.1.0 and relevant to EP-5: `Kiroku.Store.Error.mapTransactionUsageError :: UsageError -> StoreError`, and the behavioral guarantee that `runTransaction` / `runTransactionNoRetry` / `runTransactionAppending` surface `DuplicateEvent (Just eid)` for a duplicated caller-supplied event id (sentinel stream name `"<transaction>"` appears in the stream-bearing error constructors from this path).

**shibuya-pgmq-adapter 0.8.0.0 surface changes** (EP-8, `docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md`, soft-depends on these): new `Shibuya.Adapter.Pgmq.PollRetryConfig { maxAttempts :: Int, initialBackoff :: NominalDiffTime, maxBackoff :: NominalDiffTime }`, `defaultPollRetryConfig` (5 attempts, 0.1 s doubling to 5 s), new `PgmqAdapterConfig.pollRetry` field (populated by `defaultConfig`), and the added `Error PgmqRuntimeError :> es` constraint on `pgmqAdapter`/`pgmqSource`/`pgmqSourceWithPrefetch` and the `Internal` stream builders. shibuya-core 0.7.1.0 changes are behavioral only (ingester failure → `ProcessorState` `Failed` + propagated exception; `done` flag set on failure so `waitApp` terminates).

**Version/pickup matrix.** kiroku-store 0.2.0.0 → 0.2.1.0, consumed by keiro via `cabal.project` git tag (both kiroku stanzas must move together; `kiroku-store-migrations` has no code changes but shares the repo SHA). shibuya-core 0.7.0.0 → 0.7.1.0 (Hackage; keiro-pgmq bound `>=0.7 && <0.8` already admits it). shibuya-pgmq-adapter 0.7.0.0 → 0.8.0.0 (Hackage; keiro-pgmq bound must become `>=0.8 && <0.9`). ephemeral-pg 0.2.1.0 → 0.2.2.0 (Hackage; `keiro-test-support`'s `>=0.2`, kiroku's `>=0.2 && <0.3`, and keiro-pgmq-test's `>=0.2` all admit it). pgmq-effectful stays 0.3.0.0 — unchanged; its already-exported `Pgmq.Effectful.isTransient :: PgmqRuntimeError -> Bool` is the classification dependency of M4. shibuya-pgmq-adapter 0.8.0.0 keeps `shibuya-core ^>=0.7.0.0`, satisfied by 0.7.1.0.

Libraries relied on and why: `hasql`/`hasql-pool`/`hasql-transaction` (kiroku's SQL layer; the error types being mapped), `contravariant-extras` (`contrazip2` for the two-param statement encoder), `effectful-core` (`Error` static effect; `catchError` powers the poll retry), `nqe` (shibuya's supervisor — observed, not modified), `unliftio` (`withAsync`/`poll`/`throwIO` in shibuya), `streamly-core` (the adapter source streams), `directory`'s `renamePath` + `unix`'s `getProcessID` + `base`'s `Data.Unique` (atomic cache staging), and `ephemeral-pg` itself as the test substrate for every database-touching suite in this plan.
