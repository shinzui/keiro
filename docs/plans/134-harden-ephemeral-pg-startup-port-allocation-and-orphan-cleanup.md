---
id: 134
slug: harden-ephemeral-pg-startup-port-allocation-and-orphan-cleanup
title: "Harden ephemeral-pg startup port allocation and orphan cleanup"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics.md"
---

# Harden ephemeral-pg startup port allocation and orphan cleanup

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

ephemeral-pg — the library that starts a throwaway PostgreSQL server for every keiro test suite — has three robustness gaps that surface at fleet-CI scale. First, its free-port picker binds port 0, closes the socket, and hands the port number out; if another process grabs the port before postgres binds it, the suite dies with a 60-second `ConnectionTimeout` — loud, but at scale it trains people to retry until green. Second, when the `pg_isready` executable is missing from `PATH`, readiness checking silently degrades to "sleep one second and declare success", so startup can be declared ready with no probe at all. Third, because postgres is started in its own process group, a `SIGKILL` of the test runner orphans the postmaster: nothing ever cleans it up, and long-lived CI machines accrete orphaned servers and data directories.

After this plan: a port collision is detected immediately (postgres exiting during startup fails fast instead of timing out) and startup retries with a fresh port a bounded number of times; readiness is always probed (a direct socket connect when `pg_isready` is absent) or fails loudly; every instance writes a pidfile under the cache root and `startCached` conservatively sweeps instances whose owning runner is gone; and the initdb cache key's guarantees and limits are documented where the code lives. You can see it working from the ephemeral-pg repo: `cabal test ephemeral-pg-test` passes with new regression examples, and a `kill -9` of a test process demonstrably no longer leaves a postgres running after the next suite start.

Everything here lands in the ephemeral-pg repository (`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`) and ships on the shared release train MasterPlan 22 defines (one release with ExecPlans 132/133's changes, or a follow-up 0.3.x; the last-landing plan bumps keiro-test-support's bound in the keiro repo).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: readiness is always probed — socket-connect fallback replaces sleep-and-hope; postgres exiting during the wait fails fast with its captured exit; regression tests added.
- [ ] M2: bounded fresh-port retry on startup bind failure (auto-selected ports only); regression test with a deliberately occupied port passes.
- [ ] M3: per-instance pidfiles under the cache root; conservative sweep at `startCached`; documented touch/no-touch contract; kill -9 orphan scenario verified cleaned.
- [ ] M4: cache-key guarantees and limits documented in `EphemeralPg/Internal/Cache.hs` haddock (no behavior change); release shipped and keiro-test-support bound updated if this plan lands last.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The no-`pg_isready` fallback becomes a direct TCP connect probe to `127.0.0.1:<port>` (the server always listens there — `buildPostgresArgs` passes `-h 127.0.0.1` unconditionally), looping like the `pg_isready` path; it does not become a hard error.
  Rationale: A hard error would break environments that genuinely lack `pg_isready` but work fine today by luck; a socket probe gives them correctness instead of failure. A TCP connect proves the postmaster is accepting connections on the advertised port — strictly stronger than the current unconditional sleep, and cheaper than shipping a libpq handshake. The probe is also what detects port collisions (M2): if another process owns the port, postgres exits and the exit is what we detect, not the connect.
  Date: 2026-07-23

- Decision: Port-collision recovery retries the whole postgres-start step (fresh port, same data directory) at most 3 times, and only when the port was auto-selected (`Config.port = Last Nothing`). An explicitly configured port never retries — it fails loudly.
  Rationale: An explicit port is a user statement of intent; silently moving off it would break the caller's connection expectations. Auto-selected ports carry no intent. Three attempts bounds worst-case startup at a few seconds while making the TOCTOU window practically irrelevant (three independent collisions in one startup is negligible at observed fleet rates). The data directory is reused across attempts because initdb/cache-restore already succeeded and is port-independent.
  Date: 2026-07-23

- Decision: The orphan sweeper is opt-out conservative: it only ever kills a process when (a) the instance's pidfile under the cache root names both the runner PID and the postmaster PID, (b) the runner PID is dead, (c) the postmaster PID is alive AND the `postmaster.pid` file inside the recorded data directory still names that same PID, and (d) the recorded data directory path is under the recorded temporary root. Anything else — missing file, unreadable record, PID mismatch, live runner — is left untouched (stale record files themselves are removed only when their data directory is already gone).
  Rationale: A sweeper that can ever kill an unrelated process (PID reuse!) is worse than the accretion it fixes. Requiring the datadir's own `postmaster.pid` to agree with the record makes PID-reuse kills effectively impossible: a recycled PID will not be a postmaster holding that exact data directory. TIN-8 is accretion, not cross-run interference (socket/data directories are per-instance temp dirs — `EphemeralPg/Internal/Directory.hs` `createTempDataDirectory`/`createTempSocketDirectory`), so a sweeper that occasionally declines to clean is acceptable; one that overreaches is not.
  Date: 2026-07-23

- Decision: TIN-9 (cache key omits minor version / binary identity) is resolved as documentation only, in the `EphemeralPg.Internal.Cache` module haddock.
  Rationale: Reviewed and accepted by MasterPlan 22: PostgreSQL's on-disk format is compatible within a major version, and `postgresql.conf` is rewritten from the live `Config` on every cache restore (`EphemeralPg.hs` lines 384–386), so a minor-version bump reusing a cached cluster is safe. Invalidating on minor version would only slow suites for no correctness gain. What is missing is that these guarantees are stated nowhere near the code that embodies them.
  Date: 2026-07-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

All source paths in this section are inside the ephemeral-pg repository at `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg` unless prefixed otherwise. ephemeral-pg is a Haskell library that runs `initdb`, writes `postgresql.conf`, starts a `postgres` server process on a Unix socket plus a localhost TCP port, waits for readiness, and hands back a `Database` handle; `startCached` (in `src/EphemeralPg.hs`) additionally caches the `initdb` output under `~/.cache/ephemeral-pg/cache/<pg-major>-<config-hash>/data` and restores it with copy-on-write when possible. The keiro repository (`/Users/shinzui/Keikaku/bokuno/keiro`) consumes it from Hackage (currently 0.2.2.0) through `keiro-test-support`, whose `withMigratedSuite` starts one cached server per test suite. This ExecPlan lives in keiro's `docs/plans/` because MasterPlan 22 (keiro's `docs/masterplans/22-…md`) coordinates it, but every code change is in the ephemeral-pg repo.

ADR context: keiro's `docs/adr/` contains only `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq telemetry) — irrelevant to this work; no relevant ADR exists. The ephemeral-pg repo has no `docs/adr/` directory.

Terms in plain language. *TOCTOU* (time-of-check to time-of-use): checking a resource is free, then using it later, with a window where someone else can take it. The *postmaster* is the postgres parent process. A *process group* is a set of processes signalled together; ephemeral-pg starts postgres with `setCreateGroup True` (`src/EphemeralPg/Process/Postgres.hs` line 79) so it can signal the whole group — which also detaches it from the runner's group, so killing the runner does not kill postgres. `pg_isready` is a PostgreSQL client binary that checks whether a server accepts connections. A *pidfile* here is a small record file this plan introduces, naming the runner and postmaster PIDs and the instance's directories.

### TIN-7: the port TOCTOU and the check-free readiness fallback (loud flakes)

`src/EphemeralPg/Internal/Port.hs` lines 26–45 (`findFreePort`): bind `127.0.0.1:0`, read the assigned port, close the socket, return the number. Nothing holds the port from that moment until postgres binds it; the window spans initdb (non-cached path: `start` gets the port at `EphemeralPg.hs` lines 191–193, before `runInitDb` at 199–201) or the postgres startup itself (cached path: `continueStartup` gets the port at lines 428–430 after cache restore). On collision, postgres exits immediately with "address already in use" — but `startPostgres` (`src/EphemeralPg/Process/Postgres.hs`) never checks the child's exit; it enters `waitForPostgres` (lines 143–187), which loops `pg_isready` until the configured 60-second timeout and then fails with `ConnectionTimeout`. So a collision costs a full minute and reports the wrong cause. Worse, if `pg_isready` is not on `PATH`, `waitForPostgres`'s fallback (lines 162–167) is `threadDelay 1s; pure ()` — success with *no probe of any kind*. And `runCreateDb` skips entirely when `databaseName == "postgres"` (`src/EphemeralPg/Process/CreateDb.hs` lines 29–30 — the default config's database), so in that common case no later step implicitly verifies the server either: startup can be declared ready unverified.

### TIN-8: orphaned postmasters (accretion)

Cleanup is exclusively in-process: the `cleanup` closure built at `EphemeralPg.hs` lines 216–223 (and its twin in `continueStartup` at 449–454) removes the temp directories, and `stop` signals the tracked process — none of which runs if the runner is `SIGKILL`ed (CI job timeout, OOM kill). Because of `setCreateGroup True`, the postmaster survives its parent's death. Removal failures are discarded (`_ <- retryRemoveDirectory …`). There is no reaper anywhere. Verified scope: this is accretion, not cross-run interference — each instance gets unique temporary data and socket directories (`src/EphemeralPg/Internal/Directory.hs`), so leaked servers do not collide with new runs; they just consume memory, disk, and ports forever on long-lived machines.

### TIN-9: the cache key (documentation)

`src/EphemeralPg/Internal/Cache.hs` `getCacheKey` (lines 143–158): the key is the PostgreSQL *major* version (parsed from `postgres --version`) plus a `Data.Hashable.hash` of `initDbArgs`, `postgresSettings`, and `user`. Minor upgrades do not invalidate — safe because on-disk format is stable within a major and `postgresql.conf` is rewritten from the live config on every restore (`EphemeralPg.hs` lines 384–386, `cleanupRuntimeFiles` + `writePostgresConf`). The June 2026 atomic-write fix is intact (commit `215e4ae`, "fix(ephemeral-pg): publish initdb cache atomically"): `createCache` copies into a same-parent `data.tmp-<pid>-<unique>` directory and publishes with an atomic `renamePath`, and a losing concurrent writer removes its temp copy and treats the winner as success (lines 181–206). None of this is written down for users; the module haddock still only shows the directory layout. Also worth documenting: `Hashable.hash` is salted per GHC version/platform in some configurations, so hash-differing-across-toolchains means at worst a redundant cache entry, never a wrong hit — same-input-same-process-equals-same-key is the only property relied on.

### What must not regress

Template freshness (keiro's suites re-run migrations per suite against a fresh template — the cache stores only clean `initdb` output, guaranteed by caching *before* postgres ever starts, `EphemeralPg.hs` lines 389–409), clone isolation (per-instance temp dirs), and cache-write atomicity (above) are verified sound. Every change in this plan must keep the existing `ephemeral-pg-test` examples green, in particular the caching describe block in `test/Main.hs`.


## Plan of Work

### Milestone 1 — always-probed readiness and fail-fast on child exit

Scope: `src/EphemeralPg/Process/Postgres.hs` and tests. At the end, "ready" always means a probe succeeded, and a postgres that dies during startup fails the start within milliseconds, carrying its real diagnostics.

Rework `waitForPostgres`. It currently takes `socketDir`, `port`, and the timeout; give it access to the started process as well (pass the `PostgresProcess` — the caller `startPostgres` has it at line 120). The wait loop becomes: (1) check whether the child has exited (`System.Process.Typed.getExitCode`); if it has, return a new failure `PostgresExitedDuringStartup` carrying the exit code — add this constructor to the appropriate error type in `src/EphemeralPg/Error.hs` (extend `StartError`'s postgres-side error, mirroring `PostgresStartFailed`'s fields; stderr is currently discarded via `nullStream` at lines 76–78, so either capture stderr to a bounded buffer while starting or report "stderr discarded; re-run with Config.stderr set" — choose capture if it stays simple, and record the choice); (2) probe: if `pg_isready` exists on `PATH`, use it exactly as today; otherwise attempt a plain TCP connect to `127.0.0.1:<port>` (`Network.Socket`: `socket`, `connect`, `close`; a completed connect is readiness — postgres accepts and then handshakes, and a refused connect means not ready); (3) on probe failure, delay 100ms and loop until the deadline as today. Delete the `threadDelay 1s; pure ()` branch — with this change there is no code path that declares readiness without either a `pg_isready` success or a completed TCP connect.

Tests (in `test/Main.hs`): an example that starts a config whose `postgresArgs` force immediate exit (e.g. `["-c", "bogus_parameter=1"]` — postgres refuses to start on an unknown parameter) and asserts the failure is `PostgresExitedDuringStartup` (not `ConnectionTimeout`) and arrives in well under 5 seconds. A probe-fallback example is environment-dependent (hiding `pg_isready` from `PATH` requires manipulating the environment); implement it by running the wait function directly against a started server with a stubbed `findExecutable` result if the module structure allows injecting it cheaply — otherwise cover the TCP probe with a unit test against a real started server (connect must succeed) and a closed port (connect must fail), and note the gap.

Acceptance: `cabal test ephemeral-pg-test` passes; the bogus-parameter example fails in seconds, not 60.

### Milestone 2 — bounded fresh-port retry

Scope: `src/EphemeralPg.hs` (both `start` and `continueStartup`) plus tests. At the end, an auto-selected-port collision is invisible to the user: startup transparently retries with a new port.

Structure: extract the "get port, start postgres, create database" tail of `continueStartup` (lines 427–470) into a helper that returns `Either StartError Database` and wrap it: when the config's port is auto-selected (`getLast config.port == Nothing`) and the failure is the new `PostgresExitedDuringStartup` (the signature a bind collision produces, since M1 makes child exit the detection path), release nothing (the port picker holds nothing), pick a fresh port, and try again, at most 3 total attempts; then give up with the last error. Apply the same wrapper in the non-cached `start` path (which currently picks the port before `runInitDb` — move the port acquisition *after* initdb while restructuring, shrinking the TOCTOU window for free; initdb does not need the port). An explicitly configured port (`Last (Just p)`) never retries.

Tests: bind a socket to a port in the test, build a config with `port = Last (Just boundPort)` — assert loud failure (no retry for explicit ports); then simulate the auto-select collision by injecting the occupied port. Direct injection needs a seam: give the retry wrapper its port-picking action as a parameter (default `findFreePort`), so the test passes an action returning the occupied port once and a real free port afterwards, and asserts startup succeeds on attempt 2. That seam (an internal function parameter, not `Config` surface) is the test's whole cost — keep it internal to `EphemeralPg` (unexported or exported from an `Internal` module).

Acceptance: both examples pass; existing suite untouched. The user-visible claim — "collision costs one extra postgres spawn, not 60 seconds" — is demonstrated by the attempt-2 example's runtime (assert < 10s).

### Milestone 3 — pidfiles and a conservative sweep

Scope: new module `src/EphemeralPg/Internal/Instances.hs`, wiring in `EphemeralPg.hs`, tests. At the end, a `kill -9`ed runner's postmaster is reaped by the next `startCached` on the same machine, and the sweeper provably cannot kill anything else.

Record: after a successful start (both cached and non-cached paths — write it where the `Database` is assembled), write `<cacheRoot>/instances/<runnerPid>-<postmasterPid>.json` containing: runner PID (`getProcessID`), postmaster PID, data directory, socket directory, whether each is temporary, and a monotonic-ish start timestamp. Remove the file in `stop` (best-effort, after cleanup). The instances directory lives under the same root as the cache (`getCacheRoot`), so it exists on every machine that uses `startCached` and is user-scoped.

Sweep: at the top of `startCached`, list `<cacheRoot>/instances/`; for each record apply the Decision-Log conditions exactly — runner PID dead (signal 0 via `signalProcess nullSignal` throwing "no such process"), postmaster PID alive, `postmaster.pid` file inside the recorded data directory exists and its first line equals the recorded postmaster PID. Only then: `SIGQUIT` the postmaster (immediate shutdown), wait briefly, `SIGKILL` if still alive, then remove the recorded temporary directories and the record file. If the data directory is already gone, just remove the record. In every other combination, leave everything alone. Never look at, list, or touch any path other than those named inside the record, and refuse records whose data directory is not under the system temp root or the recorded `temporaryRoot`. All sweep failures are non-fatal to the caller's startup (log-free best effort — this library has no logger; swallow and continue). Document the touch/no-touch contract in the module haddock verbatim from the Decision Log.

Tests: end-to-end orphan simulation without actually SIGKILLing the test runner — start an instance with `start` (get a real postmaster), write an instances record for it naming a *fake dead* runner PID (pick a PID that does not exist), call the sweep function directly, assert the postmaster is dead and the directories and record are gone. Conservatism tests: a record naming a live runner (the test's own PID) must be untouched; a record whose datadir `postmaster.pid` mismatches must be untouched; a record pointing at a non-temp path must be untouched. These four examples are the sweeper's specification.

Acceptance: `cabal test ephemeral-pg-test` passes with the four sweep examples. Manual proof (once, recorded in Outcomes): run a toy program that `start`s a database and `exitImmediately`s; observe the orphan postgres with `ps`; run any `startCached`-using program; observe the orphan gone.

### Milestone 4 — cache-key documentation and release

Scope: `src/EphemeralPg/Internal/Cache.hs` haddock; CHANGELOG; release. Write the module-level haddock stating: the key (PG major + hash of `initDbArgs`, `postgresSettings`, `user`); what a hit guarantees (a clean post-`initdb` data directory produced by an equivalent configuration; `postgresql.conf` is regenerated from the live config on restore, so `postgresSettings` differences can never leak through a stale conf even though they are also in the key); the accepted limits (minor-version upgrades reuse the cache — safe within a major; binary identity/compile options are not keyed — accepted; `Hashable` output may differ across toolchains — worst case a redundant entry, never a wrong hit); and the concurrency story (atomic tmp-then-rename publish; concurrent losers defer to the winner — commit `215e4ae`). No behavior change; `cabal haddock` must build it cleanly.

Release: per MasterPlan 22's Integration Points this ships on the shared train with ExecPlans 132/133. If 132's 0.3.0.0 has not shipped yet, land everything as 0.3.0.0 together; if it has, ship this as 0.3.1.0 (M1's new error constructor extends `StartError` — a major bump per PVP if the type's constructors are exported, so check: if `StartError(..)` is exported, this is 0.4.0.0; record what was chosen). Whichever plan lands last bumps `keiro-test-support/keiro-test-support.cabal`'s `ephemeral-pg` lower bound in the keiro repo and runs keiro's `just verify`.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg` for all build/test/release steps:

```bash
cabal build
cabal test ephemeral-pg-test
cabal haddock
just release   # cabal check + test + upload --publish + docs (interactive confirm)
```

A passing test run ends like:

```text
Finished in 25.10 seconds
40 examples, 0 failures
Test suite ephemeral-pg-test: PASS
```

Manual orphan-reap verification (once, macOS syntax):

```bash
# in ghci or a scratch Main: EphemeralPg.start defaultConfig >> exitImmediately ExitSuccess
ps ax | grep '[p]ostgres -D'          # orphan visible
cabal test ephemeral-pg-test          # any startCached call sweeps
ps ax | grep '[p]ostgres -D'          # orphan gone
```

If this plan lands last on the release train, then in `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
# edit keiro-test-support/keiro-test-support.cabal: ephemeral-pg >= <released version>
cabal update && cabal build all && just verify
```

Commits: Conventional Commits with the trailer `ExecPlan: docs/plans/134-harden-ephemeral-pg-startup-port-allocation-and-orphan-cleanup.md`; one commit per milestone is a natural slicing (`fix(startup): …`, `fix(port): …`, `feat(reaper): …`, `docs(cache): …`).


## Validation and Acceptance

All observable from the ephemeral-pg repo. `cabal test ephemeral-pg-test` passes with the new examples: bogus-parameter start fails as `PostgresExitedDuringStartup` in under 5 seconds (was: 60s `ConnectionTimeout`); explicit occupied port fails loudly without retry; auto-select occupied port succeeds on attempt 2 in under 10 seconds; the four sweeper-specification examples (reaps the dead-runner orphan; declines on live runner, on `postmaster.pid` mismatch, on non-temp path). `cabal haddock` renders the new `EphemeralPg.Internal.Cache` documentation. The pre-existing caching, config, and socket-path examples are all still green — that is the no-regression gate for template freshness, clone isolation, and cache atomicity. After the release train lands, keiro's `just verify` (from `/Users/shinzui/Keikaku/bokuno/keiro`) passes against the new version with no keiro code change beyond the version bound.


## Idempotence and Recovery

Every milestone is additive and re-runnable. The sweep is idempotent by construction (a reaped record is gone; a declined record is declined again). Pidfile writes are best-effort — a crash between server start and record write merely reproduces today's behavior (an unswept orphan), never a false kill. The port-retry loop holds no resources between attempts. If a release goes out with a defect, keiro is insulated by its lower bound: do not bump keiro-test-support until the ephemeral-pg suite and the manual orphan check pass. Reverting any milestone is a clean `git revert` in the ephemeral-pg repo since no milestone rewrites existing behavior except the readiness fallback — whose old behavior (sleep-and-hope) must not be restored; if M1 must be reverted, revert M2 with it (M2's collision detection depends on M1's fail-fast).


## Interfaces and Dependencies

All in the ephemeral-pg repo. Changed: `EphemeralPg.Process.Postgres.waitForPostgres` gains the started `PostgresProcess` parameter (internal API); `EphemeralPg.Error.StartError` gains a `PostgresExitedDuringStartup`-carrying constructor (check PVP impact — see M4); `EphemeralPg.start`/`startCached` internally gain the port-retry wrapper with an injectable port source (internal seam, default `EphemeralPg.Internal.Port.findFreePort`). New: `EphemeralPg.Internal.Instances` with roughly:

```haskell
data InstanceRecord = InstanceRecord
  { runnerPid :: CPid, postmasterPid :: CPid
  , dataDirectory :: FilePath, socketDirectory :: FilePath
  , dataDirIsTemp :: Bool, socketDirIsTemp :: Bool
  , startedAt :: UTCTime
  }
writeInstanceRecord  :: Maybe FilePath -> InstanceRecord -> IO ()
removeInstanceRecord :: Maybe FilePath -> InstanceRecord -> IO ()
sweepStaleInstances  :: Maybe FilePath -> IO ()   -- the Maybe FilePath is the cache root override, as elsewhere
```

Dependencies already in the build: `network` (TCP probe — already a dependency via `EphemeralPg.Internal.Port`), `unix` (`signalProcess`, `getProcessID` — already used), `aeson` or hand-rolled encoding for the record file (prefer whatever `ephemeral-pg.cabal` already depends on; add nothing heavyweight). Consumers: keiro's `keiro-test-support` (bound bump only, no code change); the sibling ExecPlans 132/133 share the release train per MasterPlan 22's Integration Points and Dependency Graph (disjoint files: this plan touches `Port.hs`, `Process/Postgres.hs`, `EphemeralPg.hs` startup tail, new `Instances.hs`; 132 touches `Snapshot.hs`/`Database.hs`/`EphemeralPg.hs` restart; 133 touches nothing in ephemeral-pg).
