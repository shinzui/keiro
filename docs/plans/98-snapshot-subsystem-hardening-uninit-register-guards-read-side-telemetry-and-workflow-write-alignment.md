---
id: 98
slug: snapshot-subsystem-hardening-uninit-register-guards-read-side-telemetry-and-workflow-write-alignment
title: "Snapshot subsystem hardening: uninit-register guards, read-side telemetry, and workflow write alignment"
kind: exec-plan
created_at: 2026-07-12T05:07:53Z
intention: intention_01kxcz37ave9t8d6amvvxnemr6
master_plan: "docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md"
---

# Snapshot subsystem hardening: uninit-register guards, read-side telemetry, and workflow write alignment

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Parent: `docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md` (master plan MP-14). This is child plan EP-98, Phase 2. It has no hard dependencies and must not wait on anything; it soft-depends on EP-95 only in the sense that its telemetry reads better after the keiki migration, but every milestone here lands independently.


## Purpose / Big Picture

keiro is an event-sourcing runtime: an application's state is never stored directly — it is recomputed ("replayed") from an append-only log of events in PostgreSQL. A *snapshot* is a performance optimization: a JSON copy of the folded state saved at a known log position so the next replay can start there instead of at event zero. Snapshots are documented everywhere in this repository as *advisory* — a snapshot problem may cost performance, never correctness, and never the success of a command whose events already committed.

The 2026-07 review found four places where the snapshot subsystem breaks that promise or hides its own failures, and this plan fixes all four. After this plan:

1. A command that appends events **cannot crash** because of a snapshot of a state that cannot be JSON-encoded. Today, if a keiki register slot was never initialized, the snapshot encode explodes with a pure `error` call *after* the events committed, tearing a pooled database connection and re-crashing at every snapshot boundary forever. After this plan the problem is caught twice: at stream construction time (`mkEventStream` reports the offending slot by name before the service ever runs) and at snapshot-write time (the encode is forced *before* touching the database; a failure increments a metric and the command still succeeds).
2. A **corrupt snapshot row is visible**. Today a snapshot that fails to decode is silently discarded and every hydration silently pays a full replay, forever. After this plan the counters `keiro.snapshot.decode.failures`, `keiro.snapshot.read.hits`, and `keiro.snapshot.read.misses` make that pathology observable.
3. **Workflow snapshot writes behave like command snapshot writes**: a failed post-append workflow snapshot write is swallowed and counted instead of failing a workflow run whose journal append already committed.
4. The **documentation tells the truth** about the one deliberate exception to "a snapshot can never regress": a snapshot written under a *different* codec version or shape hash may replace a higher-version row (this enables codec rollback but causes row-thrash in mixed-version deployments), and keiro's upgrade notes warn about the benign one-time full replay that keiki EP-78's shape-hash fix will cause.

To see it working: run `cabal test keiro-test` from the repository root and observe the new tests listed under Validation and Acceptance — most notably a test in which a command whose snapshot state cannot be encoded still returns `Right`, its events are readable, and `keiro.snapshot.encode.failures` reads `1`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] M1: `deepseq` added to `keiro-core/keiro-core.cabal` build-depends
- [x] M1: `initialSnapshotEncodeWarnings` implemented in `keiro-core/src/Keiro/EventStream/Validate.hs` and wired into `validateEventStreamWith`
- [x] M1: uninit-slot fixture (two slots, one never written) added to `keiro/test/Main.hs`; `mkEventStream` rejection test passes and names the slot
- [x] M2: `deepseq` added to `keiro/keiro.cabal` (library and, if needed, test suite)
- [x] M2: `keiro.snapshot.encode.failures` counter added to `keiro/src/Keiro/Telemetry.hs` (name constant, `KeiroMetrics` field, registration, recorder)
- [x] M2: `encodeSnapshotStrict` and `writeSnapshotEncoded` added to `keiro/src/Keiro/Snapshot.hs`
- [x] M2: `writeSnapshotIfNeeded` in `keiro/src/Keiro/Command.hs` forces the encode before the store call and degrades to a counted swallow on `ErrorCall`
- [x] M2: runtime degrade integration test (partial `ToJSON` state) and direct unit test of `encodeSnapshotStrict` over an `emptyRegFile` pair pass
- [x] M3: `SnapshotLookup` / `SnapshotMissReason` types and `lookupSnapshotSeed` added to `keiro/src/Keiro/Snapshot.hs`; `hydrateWithSnapshot` kept as a compatibility wrapper
- [x] M3: `keiro.snapshot.decode.failures`, `keiro.snapshot.read.hits`, `keiro.snapshot.read.misses` counters added to `keiro/src/Keiro/Telemetry.hs`
- [x] M3: `hydrate` in `keiro/src/Keiro/Command.hs` records hit/miss/decode-failure via the new lookup
- [x] M3: workflow read side (`loadWorkflowSnapshot` callers in `keiro/src/Keiro/Workflow.hs`) records the same counters
- [x] M3: decode-failure counter asserted on the existing corrupt-snapshot fixtures; hit/miss asserted on the tail-hydration fixture
- [x] M4: `Error StoreError :> es` constraint added to `runWorkflow` / `runWorkflowWith` / `rotateGeneration` in `keiro/src/Keiro/Workflow.hs`
- [x] M4: all three `writeWorkflowSnapshot` call sites swallow-and-count (`keiro.snapshot.write.failures`)
- [x] M4: workflow snapshot write-failure test (constraint-block pattern) asserts the run succeeds with a counted failure
- [ ] M5: `keiro/src/Keiro/Snapshot/Schema.hs` and `keiro/src/Keiro/Snapshot.hs` module docs document the codec-mismatch clobber escape hatch and mixed-deploy caveat
- [ ] M5: `keiro/src/Keiro/Workflow/Snapshot.hs` "Advisory semantics" section updated for swallowed writes
- [ ] M5: `docs/guides/snapshots-and-hydration.md` gains the clobber caveat and the keiki EP-78 one-time-replay upgrade note
- [ ] M5: `CHANGELOG.md` Unreleased entry written
- [ ] Full suite green: `cabal test keiro-test` (and `cabal build keiro-core keiro` clean)
- [ ] Master plan MP-14 Progress checkboxes for EP-98 ticked and registry status updated


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Authoring, 2026-07-12) `rotateGeneration`'s unconditional seed-snapshot write is
  already documented as deliberate in `keiro/src/Keiro/Workflow.hs:795-800`: "The
  snapshot is advisory (a miss only costs a single event read), so it is written
  unconditionally on rotation regardless of the run's `snapshotPolicy` — rotation is
  exactly when a fresh snapshot earns its keep." The review's "respect the policy or
  record why not" item therefore resolves to *record why not* (see Decision Log); the
  remaining defect at that site is only that the write is not swallowed.
- (Authoring, 2026-07-12) keiki register updates can never *un*-initialize a slot: an
  edge's `USet` replaces a slot value and `UKeep` preserves it, so if
  `initialRegisters` is fully initialized every reachable register file is too. The
  validation-time guard (M1) therefore fully covers the `emptyRegFile` hazard for
  streams that go through `mkEventStream`; the runtime guard (M2) exists for
  value-level encode bottoms (e.g. a partial `ToJSON` instance on the state type,
  which the initial-state probe cannot see) and as defense in depth.
- (Authoring, 2026-07-12) keiro has no logging seam: neither `keiro/keiro.cabal` nor
  `keiro-core/keiro-core.cabal` depends on any logging library, and no module takes a
  logger. The discarded decode-error text is therefore surfaced through the
  `SnapshotDecodeFailed Text` constructor (available to callers and tests) plus the
  counter, not through a log line (see Decision Log).
- (Implementation, 2026-07-13) The repository's ignored `cabal.project.local`
  overlays kiroku 0.3.0.0 packages on the plan's pinned kiroku 0.2.1.0 packages,
  so the default `cabal` invocation cannot solve. Milestone validation uses a
  temporary project that imports only `cabal.project`; the M1 focused run passed
  four examples after excluding the pre-existing compile-time test whose nested
  `cabal` process still observes the local overlay. The final full-suite run will
  put the same clean project selection in front of nested `cabal` calls as well.
- (Implementation, 2026-07-13) Propagating the planned `Error StoreError`
  constraint through `runWorkflowWith` also requires `runChildWorkflow` to state
  the constraint because it is the typed child-runtime wrapper. The resume worker
  already carried the error effect, so this was the only library signature beyond
  the three named in the milestone that needed the mechanical propagation.


## Decision Log

Record every decision made while working on the plan.

- Decision: keiro enforces the uninitialized-slot precondition itself, at two layers,
  even though keiki EP-78 documents the same precondition.
  Rationale: inherited verbatim from MP-14's Decision Log ("keiki EP-78 deliberately
  chose documentation + a sharpened error over a total encode; keiro is where the
  exception escapes a post-commit advisory path, tears a pooled connection, and
  recurs per snapshot boundary — an operational hazard only the runtime can
  neutralize. Enforcement is not duplication of a documentation decision."). keiki
  EP-78 Milestone 4 (keiki repo,
  `docs/plans/78-persistence-wire-format-hardening-golden-byte-fixtures-maybe-slot-coverage-and-stable-shape-hash-names.md`,
  "Milestone 4 — uninitialized-slot encoding: documented precondition") explicitly
  scopes itself to "document, sharpen, and pin — no new total encoder in this plan"
  and even asserts "keiro itself always encodes fully-populated records, so no keiro
  change is needed" — a claim that holds for keiro's own fixtures but not for
  application streams whose `initialRegisters` are seeded from `emptyRegFile`. This
  plan is the operational complement, not duplication.
  Date: 2026-07-12
- Decision: the validation-time guard is a pure function using the "spoon" idiom —
  `unsafePerformIO (try @ErrorCall (evaluate (force encodedValue)))` — rather than an
  IO-returning variant of `mkEventStream`.
  Rationale: `mkEventStream` / `validateEventStreamWith` are pure and widely called
  from pure contexts (including test fixtures via `mkEventStreamOrThrow`); changing
  their type would break every caller for no semantic gain. Deciding whether a pure
  value is bottom is referentially transparent, and this is the standard idiom for
  it. The cost is one `deepseq` dependency in keiro-core.
  Date: 2026-07-12
- Decision: both guards catch exactly `ErrorCall`, not `SomeException`.
  Rationale: keiki's documented failure mode is `error ("uninit: " ...)` — an
  `ErrorCall` — from `emptyRegFile`
  (/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Generics.hs:318-332), and user
  `toJSON` bottoms via `error` are the same type. Catching `SomeException` around
  `evaluate` risks swallowing asynchronous exceptions (timeouts, cancellation) and
  misclassifying them as encode failures. Other pure exception types (e.g. incomplete
  pattern matches raise `PatternMatchFail`) remain uncaught; this limitation is noted
  in the Haddock of `encodeSnapshotStrict` and can be widened later if it bites.
  Date: 2026-07-12
- Decision: the runtime degrade path gets its own counter,
  `keiro.snapshot.encode.failures`, instead of reusing
  `keiro.snapshot.write.failures`.
  Rationale: the two failures demand different operator responses — an encode failure
  is a deterministic code/data bug (it will recur at every snapshot boundary for that
  stream until the code or state is fixed) while a write failure is usually a
  transient store problem. Conflating them would make the existing write-failure
  alert ambiguous. MP-14 Integration Point 3 reserves the `keiro.snapshot.*` read
  names for EP-98 and gives `keiro.snapshot.apply.divergence` to EP-99; adding
  `keiro.snapshot.encode.failures` collides with nothing.
  Date: 2026-07-12
- Decision: telemetry recording for snapshot reads happens in the callers that own a
  `Maybe KeiroMetrics` (`hydrate` in `keiro/src/Keiro/Command.hs`, `loadJournal` in
  `keiro/src/Keiro/Workflow.hs`), not inside `Keiro.Snapshot`. `Keiro.Snapshot`
  instead *returns* the miss reason via a new `SnapshotLookup` sum, keeping the
  storage module metrics-free and the old `hydrateWithSnapshot` as a thin wrapper.
  Rationale: least-invasive threading — `RunCommandOptions.metrics`
  (`keiro/src/Keiro/Command.hs:158-181`) and `WorkflowRunOptions.metrics`
  (`keiro/src/Keiro/Workflow.hs:301-325`) already reach those call sites, whereas
  pushing `Maybe KeiroMetrics` into `Keiro.Snapshot` would change a public signature
  *and* add a module dependency for no benefit.
  Date: 2026-07-12
- Decision: the discarded decode-error text is surfaced as data
  (`SnapshotDecodeFailed Text`), not logged.
  Rationale: keiro has no logging seam (verified — no logging dependency in either
  cabal file, no logger parameter anywhere), and inventing one for a single string is
  out of proportion. MP-14 Integration Point 3 explicitly blesses "the counter + span
  attribute suffices — record the decision"; here even the span attribute is skipped
  because `lookupSnapshotSeed` has no span in scope and the command span already
  carries the outcome. Callers and tests can inspect the `Text`.
  Date: 2026-07-12
- Decision: workflow snapshot write failures are counted on the *existing*
  `keiro.snapshot.write.failures` counter, not a new workflow-specific one.
  Rationale: it is the same table (`keiro.keiro_snapshots`), the same advisory
  semantics, and the counter's registered description ("Post-commit snapshot writes
  that failed and were swallowed.", `keiro/src/Keiro/Telemetry.hs:665`) already
  covers it. A per-subsystem split would fragment the one dashboard that matters
  ("are snapshot writes failing?"); the `keiro.workflow.*` namespace is reserved for
  workflow-logic instruments, not storage.
  Date: 2026-07-12
- Decision: `rotateGeneration` keeps writing its seed snapshot unconditionally,
  ignoring `snapshotPolicy`; only the swallow-and-count treatment is added.
  Rationale: the behavior is deliberate and already documented at
  `keiro/src/Keiro/Workflow.hs:795-800` — the seed map is a single entry, a miss
  costs exactly one event read, and rotation is precisely the moment a snapshot is
  cheapest and most valuable. Making it policy-gated would penalize `Never`-policy
  workflows that rotate (their whole point is the tiny carried seed). Decided after
  reading the rotation design, as MP-14 directed.
  Date: 2026-07-12
- Decision: `runWorkflow` / `runWorkflowWith` gain an `Error StoreError :> es`
  constraint (a source-breaking signature change).
  Rationale: swallowing the snapshot write requires `tryError @StoreError`, which
  needs the constraint. Every real interpreter already satisfies it — kiroku's
  `runStorePool` / `runStoreIO` interpret `Store` in a stack that contains
  `Error StoreError` (kiroku repo,
  `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Effect.hs:348-352`)
  — so no call site changes beyond the constraint. keiro is pre-1.0 (`0.1.0.0`);
  the alternative (a parallel `runWorkflowWith'`) would fork the API permanently to
  avoid a one-line caller fix.
  Date: 2026-07-12
- Decision: hit/miss counters are included (not just decode failures), named
  `keiro.snapshot.read.hits` / `keiro.snapshot.read.misses`, and a "miss" is any
  lookup on a stream whose `stateCodec` is set that does not yield a usable seed —
  including "stream has no id yet" and "no compatible row". The first command on a
  fresh stream therefore counts one miss.
  Rationale: the review's headline pathology — "a persistently corrupt snapshot row
  means every hydration silently pays full replay" — is diagnosed by a stream whose
  miss count grows without hits; decode failures alone cannot show the
  shape-hash-mismatch variant of the same pathology (that is a *lookup* miss, not a
  decode failure). Counting fresh-stream misses is honest (they *are* full replays)
  and keeps the definition simple. Names follow the dotted style of
  `keiro.snapshot.write.failures` (`keiro/src/Keiro/Telemetry.hs:563`).
  Date: 2026-07-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Everything below was verified against the working tree on 2026-07-12. All paths are relative to this repository's root (`/Users/shinzui/Keikaku/bokuno/keiro`) unless they name a sibling repository, in which case they are absolute and are **read-only context** — this plan changes nothing outside this repository.

**The cast.** keiro is a Haskell event-sourcing framework built from three packages relevant here: `keiro-core` (pure types: `Keiro.EventStream`, `Keiro.EventStream.Validate`), `keiro` (the runtime: commands, workflows, snapshots, telemetry), and the test suite `keiro-test` (`keiro/test/Main.hs`, declared in `keiro/keiro.cabal:128`). keiro sits on two libraries developed in sibling repositories: **keiki** (`/Users/shinzui/Keikaku/bokuno/keiki`), a pure state-machine ("transducer") library whose machines carry a typed *register file* — a heterogeneous record of named slots, e.g. `'[ '("lastAmount", Int) ]` — alongside a control state; and **kiroku** (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`), the PostgreSQL event store, whose `Store` effect keiro uses for every database operation. Effects are handled with the `effectful` library: `Error StoreError` is a typed error channel, `tryError @StoreError` catches errors thrown *in that channel* — and, crucially, **only** in that channel; a plain Haskell exception (like `ErrorCall`, which the `error` function throws) sails straight past it.

**An `EventStream`** (`keiro-core/src/Keiro/EventStream.hs:55-63`) bundles a keiki transducer with its durable plumbing: `initialState`, `initialRegisters`, an event codec, a `snapshotPolicy` (when to snapshot: `Never`, `Every n`, `OnTerminal`, ...), and `stateCodec :: Maybe (StateCodec (s, RegFile rs))` — how to serialize the `(state, registers)` pair to a JSON `Value` for snapshots. `mkEventStream` (`keiro-core/src/Keiro/EventStream/Validate.hs:98-104`) is the smart constructor every application should use: it runs keiki's pure validation plus keiro's own stream-level checks and returns `Left [EventStreamWarning]` or `Right ValidatedEventStream`. keiro's own checks currently consist of exactly one function, `snapshotWarnings` (`Validate.hs:159-169`), composed into `validateEventStreamWith` at `Validate.hs:89-93` — this plan's M1 adds a second following that precedent.

**The crash chain (finding 1, HIGH), verified link by link.** keiki's `emptyRegFile` (keiki repo, `src/Keiki/Generics.hs:318-332`) seeds every register slot with the thunk `error ("uninit: " ++ slotName)` (the `error` call is at `Generics.hs:331`); the slot-value field of the register file is deliberately lazy (keiki repo, `src/Keiki/Core.hs:194`), so the bomb sits unexploded until something reads the slot. keiro's `defaultStateCodec` (`keiro/src/Keiro/Snapshot/Codec.hs:38-48`) builds the snapshot JSON with `object ["state" .= state, "registers" .= regFileToJSON registers]` — an Aeson `Value` whose register fields are still **lazy**; nothing forces them at encode-construction time. That `Value` is finally forced when hasql serializes it as the `jsonb` statement parameter of `writeSnapshotStmt` (`keiro/src/Keiro/Snapshot/Schema.hs:112-137`; the `E.jsonb` param at `:133`), which runs inside `Pool.use` on a pooled connection in kiroku's `usePool` (kiroku repo, `kiroku-store/src/Kiroku/Store/Effect.hs:368-380`). `usePool` maps only hasql's `UsageError` to the typed channel (`Left usageErr -> throwError (ConnectionError ...)`, `Effect.hs:376-377`); the pure `ErrorCall` erupting mid-serialization is an ordinary IO exception, so it bypasses the advisory `tryError @StoreError` at `keiro/src/Keiro/Command.hs:603` and escapes `writeSnapshotIfNeeded` (`Command.hs:580-606`) entirely. Both call sites run **after** the event append has committed: `Command.hs:424` (in `runCommand`'s `appendOnce`) and `Command.hs:503` (in `runCommandWithSql`). Consequences: the caller sees an exception for a command that *succeeded* (inviting a non-idempotent retry), the pooled connection is torn mid-protocol, and because the same state re-encodes at every snapshot boundary, the crash recurs deterministically for that stream. No test covers it: every snapshot fixture initializes its registers (`keiro/test/Main.hs:7651`, `:7676`, `:7711` — all `RCons (Proxy @"lastAmount") 0 RNil`). Note the process-manager snapshot path (`keiro/test/Main.hs:2015` block) funnels through `runCommand`, so the M2 fix covers it automatically.

**The invisible read side (finding 2, MEDIUM).** `hydrateWithSnapshot` (`keiro/src/Keiro/Snapshot.hs:60-77`) discards the decode error at `Snapshot.hs:71` (`either (const Nothing) Just`), and the workflow twin `loadWorkflowSnapshot` does the same at `keiro/src/Keiro/Workflow/Snapshot.hs:113`. `keiro/src/Keiro/Telemetry.hs` has exactly one snapshot instrument, `keiro.snapshot.write.failures` (name at `:563`, field at `:621`, registration at `:665`, recorder `recordSnapshotWriteFailures` at `:784`). So a persistently corrupt row is indistinguishable from no row: every hydration silently pays a full replay — *forever* for a quiescent or terminal stream, because the row is only ever repaired when the snapshot policy next fires on a **new** append. The command-side entry point is `hydrate` (`keiro/src/Keiro/Command.hs:221`), which calls `hydrateWithSnapshot` under `case eventStream ^. #stateCodec of Just codec -> ...`; `hydrate` receives `RunCommandOptions`, whose `metrics :: Maybe KeiroMetrics` field (`Command.hs:164`) is the plumbing this plan uses.

**Workflow writes are not advisory (finding 3, MEDIUM-LOW).** A durable workflow journals step results as events and snapshots the accumulated step map. `writeWorkflowSnapshot` is called at `keiro/src/Keiro/Workflow.hs:502` (on completion) and `:567` (after a step append), plus the rotation seed write at `:814-819` inside `rotateGeneration` (`:801-828`). None is wrapped: a `StoreError` thrown by the write propagates and fails a workflow run whose journal append already committed — inconsistent with the command path's swallow-and-count and with the module's own "Advisory semantics" framing (`keiro/src/Keiro/Workflow/Snapshot.hs`, the "Advisory semantics" section, which today only describes the *read* side). `runWorkflowWith` (`Workflow.hs:432-439`) currently has constraints `(IOE :> es, Store :> es)` — no `Error StoreError`, which the fix must add to use `tryError`.

**The documented lie (finding 4, DOC).** `writeSnapshotStmt`'s upsert (`keiro/src/Keiro/Snapshot/Schema.hs:112-137`) guards the update with `WHERE stream_version <= EXCLUDED.stream_version OR state_codec_version <> ... OR regfile_shape_hash <> ...` (`Schema.hs:126-128`): a write under a **different** codec version or shape hash replaces the existing row even when the existing row has a *higher* stream version. This is intentional — it lets a rolled-back deployment (older codec) reclaim the snapshot slot instead of being locked out forever, and it is pinned by the test at `keiro/test/Main.hs:1227-1265` ("allows an incompatible snapshot codec to replace a higher-version row"). But the module docs claim unconditionally that "a late or out-of-order write cannot regress the snapshot" (`Schema.hs:7-8`) and "an out-of-order or stale write is ignored" (`keiro/src/Keiro/Snapshot.hs:79-83`), omitting both the escape hatch and its operational cost: in a mixed-version deployment (two service versions with different codec versions/hashes writing the same stream) the row thrashes back and forth and each side misses the other's writes. Separately (documentation only — keiki owns the fix): keiki EP-78's Milestone 1 will change how the register-file shape hash is computed; when a keiro consumer upgrades to that keiki, **every existing snapshot row's hash mismatches once**, which keiro treats as a benign lookup miss — a one-time full replay per stream, after which snapshots repopulate on the next policy-firing append. keiro's upgrade notes must say this; keiro must **not** touch the hash itself.

**The keiki boundary (MP-14 Integration Point 5 and Decision Log).** keiki EP-78 Milestone 4 (keiki repo, `docs/plans/78-persistence-wire-format-hardening-golden-byte-fixtures-maybe-slot-coverage-and-stable-shape-hash-names.md`, section "Milestone 4 — uninitialized-slot encoding: documented precondition") deliberately chose "document, sharpen, and pin — no new total encoder": it sharpens the `uninit:` message, documents the fully-initialized precondition on the codec, and pins the throw with a `shouldThrow` test. keiro's two guard layers here are the *operational enforcement* of that documented precondition — MP-14's Decision Log records why this is complementary, not duplicative. This plan must not change keiki, must not "fix" the shape hash, and must not cite the jitsurei example repos (user directive in MP-14).

**Telemetry naming (MP-14 Integration Point 3).** New counters follow the dotted style of `keiro.snapshot.write.failures`. EP-98 owns `keiro.snapshot.decode.failures` (reserved by the master plan) plus the hit/miss and encode-failure names it introduces; `keiro.snapshot.apply.divergence` belongs to EP-99 and must not be taken here.

**How tests run.** `keiro-test` provisions its own PostgreSQL: `keiro-test-support/src/Keiro/Test/Postgres.hs` uses `ephemeral-pg`'s cached-server + template-database pattern (`withMigratedSuite` starts one server, migrates a template once, and `withFreshStore` clones an isolated database per example). No external database, `just postgres-start`, or `process-compose` is needed — only the repository dev environment (enter it with `direnv` or `nix develop` so `cabal`, GHC, and the PostgreSQL binaries `initdb`/`postgres` are on `PATH`). The suite is hspec, so `--match` filters by describe-block path. Metric assertions use the in-memory OTel exporter pattern from the existing write-failure test (`keiro/test/Main.hs:1041-1093`): `inMemoryMetricExporter` (imported at `Main.hs:267`), `flattenScalarPoints` (defined at `Main.hs:8672`), and the SQL probe statements `snapshotVersionForStreamStmt` / `corruptSnapshotStateStmt` / `corruptSnapshotShapeStmt` (`Main.hs:8141`, `:8153`, `:8169`).


## Plan of Work

Five milestones. M1 lives in `keiro-core`; M2–M4 in `keiro`; M5 is documentation. They are ordered by dependency of narrative, not of code — M1/M2, M3, and M4 are mutually independent and each leaves the tree green.


### Milestone 1 — validation-time guard: `mkEventStream` rejects an unencodable initial state

Scope: `keiro-core/keiro-core.cabal`, `keiro-core/src/Keiro/EventStream/Validate.hs`, tests in `keiro/test/Main.hs`. At the end, constructing a snapshot-enabled stream whose `(initialState, initialRegisters)` cannot be JSON-encoded returns `Left` from `mkEventStream` with a warning naming the uninitialized slot, instead of arming a runtime bomb.

Add `deepseq` to the `build-depends` of the `library` stanza in `keiro-core/keiro-core.cabal` (the stanza starts at line 39; the existing depends list at lines 52-64 already carries `aeson`, whose `Value` has an `NFData` instance — that is what we force).

In `keiro-core/src/Keiro/EventStream/Validate.hs`, add a function `initialSnapshotEncodeWarnings` directly below `snapshotWarnings` (`Validate.hs:159-169`), and compose it into `validateEventStreamWith` (`Validate.hs:89-93`) the same way `snapshotWarnings` is (`snapshotWarnings label es <> initialSnapshotEncodeWarnings label es <> [ ... keiki warnings ... ]`). The function: when `stateCodec es` is `Just codec`, encode the pair `(initialState es, initialRegisters es)` with the codec's `encode` field and deep-force the resulting `Value`; if forcing throws `ErrorCall`, return one `EventStreamWarning` embedding the error message (which contains keiki's `uninit: <slot>` text). Because the function must stay pure (see Decision Log), use the spoon idiom:

```haskell
import Control.DeepSeq (force)
import Control.Exception (ErrorCall (..), evaluate, try)
import System.IO.Unsafe (unsafePerformIO)

-- Warn when the configured stateCodec cannot encode the initial
-- (state, registers) pair. Catches keiki's @error "uninit: <slot>"@ thunks
-- (seeded by 'Keiki.Generics.emptyRegFile' into never-written slots) before
-- they can escape a post-commit snapshot write at runtime. Limitation: this
-- probes the INITIAL state only; value-level bottoms introduced by later
-- states (e.g. a partial ToJSON on the state type) are caught by the
-- runtime guard in keiro's writeSnapshotIfNeeded.
initialSnapshotEncodeWarnings :: Text -> EventStream phi rs s ci co -> [EventStreamWarning]
initialSnapshotEncodeWarnings label es =
    case stateCodec es of
        Nothing -> []
        Just codec ->
            case tryForce ((encode codec) (initialState es, initialRegisters es)) of
                Right _ -> []
                Left (ErrorCall msg) ->
                    [ EventStreamWarning
                        { eswStreamLabel = label
                        , eswReason =
                            "stateCodec cannot encode the initial (state, registers): "
                                <> Text.pack msg
                                <> "; a snapshot write would crash after the append commits. "
                                <> "Initialize every register slot in initialRegisters."
                        }
                    ]
  where
    tryForce v = unsafePerformIO (try @ErrorCall (evaluate (force v)))
```

Two mechanical notes for the implementer: `Validate.hs` currently imports `EventStream (..)` and `SnapshotPolicy (..)` from `Keiro.EventStream` — extend that import with `StateCodec (..)` so the `encode` selector is in scope (if the bare selector is ambiguous under the module's extensions, pattern-match instead: `Just StateCodec{encode = enc} -> ... enc (initialState es, initialRegisters es) ...`). And keep the honesty comment: the guard probes only the initial state. Note also why initial-state coverage is stronger than it sounds: keiki register updates (`USet`/`UKeep`) never remove a slot's value, so a fully-initialized `initialRegisters` stays fully initialized in every reachable state — the initial probe catches the entire `emptyRegFile` class of bugs for validated streams (see Surprises & Discoveries).

Tests go next to the existing `mkEventStream` block (`keiro/test/Main.hs:550-566`; the warning-equality style to copy is at `:533-534`). Build the review's fixture — a two-slot register file with one slot never written — by reusing the counter command/event/codec types already in the file and importing keiki's `EmptyRegFile (..)` from `Keiki.Generics` (exported at keiki `src/Keiki/Generics.hs:26`):

```haskell
type UninitRegs = '[ '("initialized", Int), '("neverWritten", Int)]

-- initialRegisters with slot "neverWritten" seeded by emptyRegFile's
-- error thunk — exactly what an application gets when it forgets a slot.
uninitRegisters :: RegFile UninitRegs
uninitRegisters = RCons (Proxy @"initialized") 0 (emptyRegFile @'[ '("neverWritten", Int)])
```

Give the fixture a transducer whose single edge `USet`s only `#initialized`, `snapshotPolicy = Every 1`, and `stateCodec = Just (defaultStateCodec @UninitRegs @CounterState 1)`. Assert: `mkEventStream "uninit-slot" fixture` is `Left [w]` where `eswReason w` contains both `"uninit: neverWritten"` and `"cannot encode the initial"`; and a sibling assertion that the same stream with a fully-initialized register file is `Right`. These tests are pure (no PostgreSQL touched, though they run inside the same suite binary).

Acceptance: `cabal build keiro-core` clean; `cabal test keiro-test --test-options='--match "mkEventStream"'` passes with the two new examples, and the uninit example fails if the guard is commented out (it returns `Right` and the test's `Left` pattern mismatch reports the failure).


### Milestone 2 — runtime guard: force the encode before the store call, degrade to a counted swallow

Scope: `keiro/keiro.cabal`, `keiro/src/Keiro/Telemetry.hs`, `keiro/src/Keiro/Snapshot.hs`, `keiro/src/Keiro/Command.hs`, tests in `keiro/test/Main.hs`. At the end, no snapshot encode bottom — whatever its origin — can escape `writeSnapshotIfNeeded`: it is caught in keiro's own code before any database work, counted, and the committed command returns success. This is the layer that catches what M1 cannot: value-level bottoms reachable only in later states, and any stream that somehow bypassed validation.

First, telemetry. In `keiro/src/Keiro/Telemetry.hs`, add the counter `keiro.snapshot.encode.failures` following the four-part pattern of `keiro.snapshot.write.failures` exactly: a name constant next to `keiroSnapshotWriteFailuresName` (`:563`), a `snapshotEncodeFailures :: Counter Int64` field in `KeiroMetrics` next to `:621`, registration in `newKeiroMetrics` next to `:665` with unit `"{failure}"` and description `"Snapshot states that failed to encode before the write; the write was skipped and the command succeeded."`, and a recorder `recordSnapshotEncodeFailures = recordCounter snapshotEncodeFailures` next to `:784` (export it alongside `recordSnapshotWriteFailures`, exported at `:71`).

Second, the strict-encode seam. Add `deepseq` to `keiro/keiro.cabal`'s library `build-depends` and two functions to `keiro/src/Keiro/Snapshot.hs`:

```haskell
-- | Encode a snapshot state to a fully-forced JSON 'Value', converting any
-- pure 'ErrorCall' bottom inside the encoding (e.g. keiki's
-- @error "uninit: <slot>"@ register thunks) into a 'Left'. Runs in 'IO'
-- because observing a pure bottom requires 'evaluate'. Only 'ErrorCall' is
-- caught; other pure exception types propagate.
encodeSnapshotStrict :: StateCodec state -> state -> IO (Either ErrorCall Value)
encodeSnapshotStrict codec state = try (evaluate (force ((codec ^. #encode) state)))

-- | 'writeSnapshot' for a value the caller has already encoded (and, on the
-- command path, already forced). Keeps version/hash tagging identical.
writeSnapshotEncoded ::
    (Store :> es) => StreamId -> StreamVersion -> StateCodec state -> Value -> Eff es ()
writeSnapshotEncoded streamId streamVersion codec value =
    writeSnapshotRow
        SnapshotWrite
            { streamId = streamId
            , streamVersion = streamVersion
            , state = value
            , stateCodecVersion = codec ^. #stateCodecVersion
            , regfileShapeHash = codec ^. #shapeHash
            }
```

Re-implement `writeSnapshot` (`Snapshot.hs:84-105`) as `writeSnapshotEncoded streamId streamVersion codec ((codec ^. #encode) state)` so there is one write path. Export both new names from the module header.

Third, the guard itself. In `writeSnapshotIfNeeded` (`keiro/src/Keiro/Command.hs:580-606`), replace the body under the `when (shouldSnapshotSpan ...)` with a two-stage sequence — force first, store second:

```haskell
encoded <- liftIO (encodeSnapshotStrict codec finalState)
case encoded of
    Left _uninit ->
        -- Deterministic code/data bug (recurs every boundary for this
        -- stream); the append already committed, so degrade, count, and
        -- let the command succeed. M1 catches the initial-state variant
        -- at stream construction.
        recordSnapshotEncodeFailures (options ^. #metrics) 1
    Right value -> do
        outcome <- tryError @StoreError (writeSnapshotEncoded (appendResult ^. #streamId) finalVersion codec value)
        case outcome of
            Right () -> pure ()
            Left _ -> recordSnapshotWriteFailures (options ^. #metrics) 1
```

Update `Command.hs`'s import at `:61` (`import Keiro.Snapshot (hydrateWithSnapshot, writeSnapshot)`) to the new names, and add `recordSnapshotEncodeFailures` to the `Keiro.Telemetry` import at `:64`. Because the `Value` is now forced to normal form *before* `Pool.use`, the hasql `jsonb` serialization in `writeSnapshotStmt` can no longer detonate a thunk mid-connection.

Tests, in the `Keiro.Snapshot` describe block (`keiro/test/Main.hs:1026` onward). The review asked for a later-reachable uninit state "if constructible, else unit-test the wrapper" — do both, because each covers a different arm. (a) Integration test of the degrade path via a *value-level* bottom, which IS constructible (a genuinely later-reachable uninit *register* is not, for a validated stream — see Surprises & Discoveries): define a state type whose `ToJSON` is partial, e.g. `data BombState = Armed | Detonated` with `toJSON Detonated = error "detonated state is not serializable"`, a transducer `Armed --Add--> Detonated` emitting one counter event, `snapshotPolicy = Every 1`, `stateCodec = Just (defaultStateCodec ... )`. Validation passes (the initial `Armed` encodes), so `mkEventStreamOrThrow` works. Then, following the write-failure test's shape (`Main.hs:1041-1093`): wire `inMemoryMetricExporter` metrics into `RunCommandOptions`, run one command, and assert the command returns `Right` with `eventsAppended` of 1, `Store.readStreamForward` shows the appended event, `snapshotVersionForStreamStmt` returns `Nothing` (no row was written), and `flattenScalarPoints` shows `keiro.snapshot.encode.failures` at `1` and no `keiro.snapshot.write.failures`. Before the fix this test crashes with an `ErrorCall` escaping `runCommand`; after, it passes — that is the observable behavior change. (b) Direct unit test of the wrapper on the exact review chain: `encodeSnapshotStrict (defaultStateCodec @UninitRegs @CounterState 1) (Counting, uninitRegisters)` (reusing M1's fixture) returns `Left (ErrorCall msg)` with `"uninit: neverWritten"` in `msg`, and the fully-initialized pair returns `Right`.

Acceptance: `cabal test keiro-test --test-options='--match "Keiro.Snapshot"'` green, including the two new examples; the existing write-failure test at `Main.hs:1041` still passes (proving the counted-swallow store path is unchanged).


### Milestone 3 — read-side telemetry: decode failures, hits, and misses

Scope: `keiro/src/Keiro/Snapshot.hs`, `keiro/src/Keiro/Telemetry.hs`, `keiro/src/Keiro/Command.hs`, `keiro/src/Keiro/Workflow/Snapshot.hs`, `keiro/src/Keiro/Workflow.hs`, tests. At the end, a corrupt snapshot row is no longer silent: hydration outcomes are counted, and the decode error text is available as data.

In `keiro/src/Keiro/Snapshot.hs`, introduce a lookup result that keeps the reason (replacing the information-destroying `either (const Nothing) Just` at `Snapshot.hs:71`):

```haskell
-- | Why a snapshot lookup produced no usable seed.
data SnapshotMissReason
    = SnapshotNoStream        -- ^ the stream has no id yet (first ever command)
    | SnapshotNotFound        -- ^ no row at this codec version + shape hash
    | SnapshotDecodeFailed !Text -- ^ a row matched but its bytes failed to decode
    deriving stock (Eq, Show, Generic)

data SnapshotLookup rs s
    = SnapshotUnavailable !SnapshotMissReason
    | SnapshotHit !(SnapshotSeed rs s)
    deriving stock (Generic)

lookupSnapshotSeed ::
    (Store :> es) => StreamName -> StateCodec (s, RegFile rs) -> Eff es (SnapshotLookup rs s)
```

`lookupSnapshotSeed` is the old `hydrateWithSnapshot` body with each `Nothing` mapped to its reason and the decode `Left message` mapped to `SnapshotDecodeFailed message`. Keep `hydrateWithSnapshot` exported, reimplemented as the erasing wrapper (`SnapshotHit seed -> Just seed; _ -> Nothing`) so existing callers and any downstream code compile unchanged. Export the new names.

In `keiro/src/Keiro/Telemetry.hs`, add three counters by the same four-part pattern as M2: `keiro.snapshot.decode.failures` (unit `"{failure}"`, description `"Snapshot rows whose bytes failed to decode; hydration fell back to full replay."`) — this exact name is reserved for EP-98 by MP-14 Integration Point 3, and `keiro.snapshot.apply.divergence` is EP-99's and must not be added here — plus `keiro.snapshot.read.hits` and `keiro.snapshot.read.misses` (unit `"{read}"`; a "miss" is defined in the Decision Log: any codec-configured lookup that yields no usable seed, fresh streams included). Recorders: `recordSnapshotDecodeFailures`, `recordSnapshotReadHits`, `recordSnapshotReadMisses`.

In `keiro/src/Keiro/Command.hs`, `hydrate` (`:221`): its `snapshotSeed` helper currently returns `Maybe (SnapshotSeed rs s)` from `hydrateWithSnapshot`. Switch it to `lookupSnapshotSeed`, record `recordSnapshotReadHits (options ^. #metrics) 1` on `SnapshotHit`, and on `SnapshotUnavailable reason` record a miss and — when the reason is `SnapshotDecodeFailed _` — a decode failure, then proceed exactly as today (hit continues to the tail replay; anything else falls through to `hydrateFull`). No span attribute is added (Decision Log: the decode text lives in the constructor; there is no logging seam).

The workflow read side gets the same treatment: in `keiro/src/Keiro/Workflow/Snapshot.hs`, split `loadWorkflowSnapshot` (`:104-114`) into a reason-carrying `lookupWorkflowSnapshot :: (Store :> es) => StreamName -> Eff es (Either SnapshotMissReason (WorkflowState, StreamVersion))` and keep `loadWorkflowSnapshot` as the erasing wrapper (it is asserted directly by existing tests at `keiro/test/Main.hs:4695` and `:4740`). In `keiro/src/Keiro/Workflow.hs`, the journal loader that consumes it (`loadJournal`, called at `:476` with `options` in hand) records hits/misses/decode-failures through `options ^. #metrics` the same way.

Tests. Extend the three existing fallback fixtures — "falls back when snapshot JSON is corrupt" (`keiro/test/Main.hs:1120`), "falls back when shape hash mismatches" (`:1140`), and "falls back after operator truncation" (`:1161`) — with the in-memory-exporter wiring from `:1041-1093` and assert after the final command: corrupt-JSON shows `keiro.snapshot.decode.failures` of `1` and at least one `keiro.snapshot.read.misses`; shape-mismatch shows misses but **zero** decode failures (it is a lookup miss — the row is filtered by the `WHERE` clause of `lookupSnapshotStmt`, never decoded — and this distinction is exactly what the two counters buy); truncation likewise decode-failure-free. Add a hit assertion to the tail-hydration path ("hydrates from snapshot and replays only the tail", `:1096` block): the second run records `keiro.snapshot.read.hits` of `1`. Optionally mirror one workflow decode-failure example by corrupting a `wf:` stream's row with `corruptSnapshotStateStmt` (`:8153`) and asserting the run still completes with the counter bumped.

Acceptance: `cabal test keiro-test --test-options='--match "Keiro.Snapshot"'` and `--match "Keiro.Workflow snapshots"` green; the corrupt-JSON test fails if the decode-failure recording is removed (counter reads `Nothing` instead of `Just (IntNumber 1)`).


### Milestone 4 — workflow snapshot writes: swallow and count, like the command path

Scope: `keiro/src/Keiro/Workflow.hs`, tests. At the end, a workflow run whose journal append committed can no longer be failed by a snapshot write, and each swallowed failure increments `keiro.snapshot.write.failures` (Decision Log records why the counter is shared).

Add `Error StoreError :> es` to the constraints of `runWorkflow` (`Workflow.hs:408-414`), `runWorkflowWith` (`:432-439`), and `rotateGeneration` (`:801-828`), importing `Error` and `tryError` from `Effectful.Error.Static` and `StoreError` from kiroku as `Keiro/Command.hs:52` does. This is source-breaking but interpreter-satisfied everywhere (Decision Log); `cabal build all` will surface any call site needing the constraint propagated — in this repository the callers are the test suite's `Store.runStoreIO` stacks, which already provide it. `rotateGeneration` also gains a `Maybe KeiroMetrics` parameter (pass `mMetrics`, in scope at the `:484` call site).

Wrap all three `writeWorkflowSnapshot` call sites in the same swallow used by `writeSnapshotIfNeeded` (`Command.hs:603-606`):

```haskell
outcome <- tryError @StoreError (writeWorkflowSnapshot (appendResult ^. #streamId) (appendResult ^. #streamVersion) newMap)
case outcome of
    Right () -> pure ()
    Left _ -> recordSnapshotWriteFailures mMetrics 1
```

at `:567` (step append; `mMetrics` in scope), `:502` (completion; same), and the rotation seed write at `:814-819` (via the new parameter). Do **not** gate the rotation write on `snapshotPolicy` — that unconditional write is deliberate and documented at `Workflow.hs:795-800` (Decision Log). Note the workflow codec cannot hit M2's encode bomb: `WorkflowState` is `Map Text Value`, already-encoded JSON, so its encode is total — no `encodeSnapshotStrict` needed on this path (say so in a code comment).

Test, in the `Keiro.Workflow snapshots` block (`keiro/test/Main.hs:4672` onward), using the constraint-block pattern from `:1041-1093`: wire in-memory metrics into `WorkflowRunOptions` (`#metrics ?~ keiroMetrics`, `#snapshotPolicy .~ Every 2`), block writes with `ALTER TABLE keiro.keiro_snapshots ADD CONSTRAINT keiro_snapshots_no_writes CHECK (false) NOT VALID`, run the existing `countingSixSteps` workflow, and assert: the run returns `Right (Completed [1,2,3,4,5,6])` (before this milestone it returns `Left` a `StoreError` — the behavior change), the journal stream contains all seven events, `snapshotVersionForStreamStmt` for the `wf:` stream is `Nothing`, and `keiro.snapshot.write.failures` counted every fired boundary (Every 2 over six steps plus the terminal append fires at versions 2, 4, and 6 — expect `3`; verify the count empirically and pin what is observed, documenting it). Then drop the constraint and re-run a second workflow id to show recovery (snapshot row appears).

Acceptance: `cabal test keiro-test --test-options='--match "Keiro.Workflow"'` green including the new example; `cabal build all` clean (no missed constraint propagation).


### Milestone 5 — documentation: the clobber escape hatch, mixed-deploy caveat, and the keiki EP-78 upgrade note

Scope: `keiro/src/Keiro/Snapshot/Schema.hs`, `keiro/src/Keiro/Snapshot.hs`, `keiro/src/Keiro/Workflow/Snapshot.hs`, `docs/guides/snapshots-and-hydration.md`, `CHANGELOG.md`. No behavior changes; the deliverable is that every claim the docs make is true.

In `Schema.hs`'s module header (`:1-13`), qualify the "a late or out-of-order write cannot regress the snapshot" sentence (`:7-8`): the version guard applies **within** a codec version and shape hash; a write under a *different* codec version or shape hash replaces the row even at a lower stream version (`WHERE` clause, `:126-128`). State why (codec rollback would otherwise be locked out forever — pinned by the test at `keiro/test/Main.hs:1227-1265`) and the cost: in a mixed-version deployment two writers thrash the single row per stream and each side's lookups miss the other's writes — a performance caveat, never a correctness one, since replay remains the source of truth. Make the same qualification in `writeSnapshot`'s Haddock in `Snapshot.hs` (`:79-83`, "an out-of-order or stale write is ignored").

In `Workflow/Snapshot.hs`, extend the "Advisory semantics" section: writes are now advisory too — a failed snapshot write is swallowed and counted on `keiro.snapshot.write.failures`, and can never fail a run whose append committed (M4).

In `docs/guides/snapshots-and-hydration.md` (the operator-facing guide), add two short subsections: "The one write that can replace a newer snapshot" (the clobber semantics and mixed-deploy caveat, in guide prose) and "Upgrading keiki: expect a one-time full replay" — when keiki EP-78's shape-hash stability fix lands, every existing snapshot row's `regfile_shape_hash` mismatches the recomputed hash exactly once; keiro treats this as a benign lookup miss (`keiro.snapshot.read.misses` will spike, M3 makes it visible), each stream pays one full replay, and rows repopulate on the next policy-firing append. State plainly that keiro must not and does not compensate — keiki owns the hash (MP-14 Integration Point 5).

Finally, record everything user-visible from M1–M4 in `CHANGELOG.md` under `## [Unreleased]`: the new `mkEventStream` warning (Breaking-ish for streams that were silently broken), the `Error StoreError` constraint on `runWorkflow`/`runWorkflowWith` (Breaking Changes section), the four new metrics, and the doc corrections.

Acceptance: `cabal haddock keiro` renders the updated modules without warnings; a reviewer reading `Schema.hs:1-13` and the guide can predict the `:1227-1265` test's outcome without reading the SQL.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`, inside the dev environment (`direnv allow` once, or prefix a shell with `nix develop`) so GHC, cabal, and PostgreSQL's `initdb`/`postgres` are on `PATH`. The test suite provisions its own throwaway PostgreSQL via `ephemeral-pg` (`keiro-test-support/src/Keiro/Test/Postgres.hs`); do not start the repo's `just postgres-start` database for these tests, and do not run the jitsurei targets.

```bash
# after each milestone's edits: compile the touched packages
cabal build keiro-core keiro

# milestone-scoped test runs (hspec --match filters by describe path)
cabal test keiro-test --test-options='--match "mkEventStream"'          # M1
cabal test keiro-test --test-options='--match "Keiro.Snapshot"'         # M2, M3
cabal test keiro-test --test-options='--match "Keiro.Workflow"'         # M3 (workflow read), M4

# before committing each milestone: the full suite and the whole workspace
cabal build all
cabal test keiro-test
```

A passing filtered run ends like:

```text
Finished in 12.3456 seconds
87 examples, 0 failures
Test suite keiro-test: PASS
```

If `keiro-test` fails at startup with an `ephemeral-pg` / `initdb` error, you are outside the dev shell — re-enter it; nothing in this plan touches provisioning. Commit per milestone with conventional-commit messages, for example:

```text
feat(snapshot): reject unencodable initial snapshot state at mkEventStream
feat(snapshot): force snapshot encode before the store write; count and degrade
feat(telemetry): snapshot read-side counters (decode failures, hits, misses)
fix(workflow): swallow-and-count post-append snapshot write failures
docs(snapshot): document the codec-mismatch clobber and keiki EP-78 upgrade replay
```


## Validation and Acceptance

Beyond compilation, the plan is done when the following behaviors are observable, each phrased as input → output:

1. Constructing a snapshot-enabled `EventStream` whose `initialRegisters` came from `emptyRegFile` with a never-written slot returns `Left [EventStreamWarning ..]` from `mkEventStream`, and the warning text contains `uninit: neverWritten`. (M1 test; delete the guard and the test fails by receiving `Right`.)
2. Running a command whose post-append snapshot state cannot be encoded (partial `ToJSON` on the state) returns `Right` with the events readable from the store, writes no snapshot row, and `keiro.snapshot.encode.failures` reads `1`. On the pre-plan tree the same scenario throws an `ErrorCall` out of `runCommand` after the append committed — run the new test before applying M2 to witness the crash, after to witness the degrade. (M2.)
3. With a snapshot row corrupted to non-decodable JSON, the next command still succeeds by full replay and `keiro.snapshot.decode.failures` reads `1`; with a shape-hash mismatch instead, decode failures stay `0` while `keiro.snapshot.read.misses` counts — the two pathologies are distinguishable. A snapshot-assisted hydration counts `keiro.snapshot.read.hits`. (M3, on the existing fixtures at `keiro/test/Main.hs:1120`, `:1140`, `:1161`, `:1096`.)
4. With writes to `keiro.keiro_snapshots` blocked by a `CHECK (false)` constraint, a six-step workflow under `Every 2` returns `Right (Completed [1..6])` with all journal events present, no snapshot row, and `keiro.snapshot.write.failures` counting each fired boundary; before M4 the identical scenario returns a `Left StoreError` despite the committed journal.
5. `keiro/src/Keiro/Snapshot/Schema.hs`'s header no longer claims unconditional non-regression; it names the codec-mismatch replacement, points at the rollback rationale, and the mixed-deploy caveat appears in `docs/guides/snapshots-and-hydration.md` along with the keiki EP-78 one-time-replay upgrade note. (M5, reviewed by reading.)

The full-suite gate is `cabal test keiro-test` with `0 failures`, plus `cabal build all` clean. Every pre-existing snapshot test — including the codec-rollback clobber test at `keiro/test/Main.hs:1227-1265` and the write-failure swallow at `:1041` — must still pass unmodified in behavior (M3 only *adds* assertions to some of them).


## Idempotence and Recovery

Every step is an ordinary source edit plus a test run; re-running any build or test command is safe (the ephemeral-pg fixture clones a fresh database per example, so no state leaks between runs or reruns). The milestones are independently revertible: each is a self-contained commit, and no milestone's code depends on a later one. If M4's constraint change surfaces an unexpected downstream call site (some consumer of `runWorkflowWith` outside this repository), the mechanical fix is to add `Error StoreError :> es` at that caller — the interpreters already satisfy it; do not work around it by catching in IO. If a metric assertion is flaky under `forceFlushMeterProvider`, follow the existing tests' exact flush-then-read ordering (`keiro/test/Main.hs:1076-1078`) rather than adding sleeps. No migrations, no destructive operations, and no changes to keiki or kiroku are involved anywhere in this plan.


## Interfaces and Dependencies

New dependency: `deepseq` (for `Control.DeepSeq.force` over Aeson `Value`, which has an `NFData` instance) added to the library stanzas of `keiro-core/keiro-core.cabal` and `keiro/keiro.cabal`. No other new packages; kiroku and keiki are consumed as-is.

At the end of the plan these signatures exist:

```haskell
-- keiro-core/src/Keiro/EventStream/Validate.hs (internal, composed into
-- validateEventStreamWith; not necessarily exported)
initialSnapshotEncodeWarnings :: Text -> EventStream phi rs s ci co -> [EventStreamWarning]

-- keiro/src/Keiro/Snapshot.hs (all exported)
data SnapshotMissReason = SnapshotNoStream | SnapshotNotFound | SnapshotDecodeFailed !Text
data SnapshotLookup rs s = SnapshotUnavailable !SnapshotMissReason | SnapshotHit !(SnapshotSeed rs s)
lookupSnapshotSeed    :: (Store :> es) => StreamName -> StateCodec (s, RegFile rs) -> Eff es (SnapshotLookup rs s)
hydrateWithSnapshot   :: (Store :> es) => StreamName -> StateCodec (s, RegFile rs) -> Eff es (Maybe (SnapshotSeed rs s))  -- unchanged wrapper
encodeSnapshotStrict  :: StateCodec state -> state -> IO (Either ErrorCall Value)
writeSnapshotEncoded  :: (Store :> es) => StreamId -> StreamVersion -> StateCodec state -> Value -> Eff es ()
writeSnapshot         :: (Store :> es) => StreamId -> StreamVersion -> StateCodec state -> state -> Eff es ()            -- unchanged wrapper

-- keiro/src/Keiro/Workflow/Snapshot.hs
lookupWorkflowSnapshot :: (Store :> es) => StreamName -> Eff es (Either SnapshotMissReason (WorkflowState, StreamVersion))
loadWorkflowSnapshot   :: (Store :> es) => StreamName -> Eff es (Maybe (WorkflowState, StreamVersion))                   -- unchanged wrapper

-- keiro/src/Keiro/Telemetry.hs (four new counters + recorders; names are
-- contract per MP-14 Integration Point 3 — do not rename, do not add
-- keiro.snapshot.apply.divergence, which belongs to EP-99)
--   keiro.snapshot.encode.failures   recordSnapshotEncodeFailures
--   keiro.snapshot.decode.failures   recordSnapshotDecodeFailures
--   keiro.snapshot.read.hits         recordSnapshotReadHits
--   keiro.snapshot.read.misses       recordSnapshotReadMisses

-- keiro/src/Keiro/Workflow.hs (constraint change; otherwise same shapes)
runWorkflow     :: (IOE :> es, Store :> es, Error StoreError :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
runWorkflowWith :: (IOE :> es, Store :> es, Error StoreError :> es) => WorkflowRunOptions -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
```

Boundaries this plan must respect: keiki owns the shape hash, the `uninit:` message text, and the codec precondition documentation (keiki EP-78 — read-only here); kiroku's `Store` effect and error mapping are consumed unchanged; `keiro.snapshot.apply.divergence` and all step/replay divergence work belong to EP-99; the jitsurei directories are not evidence and not in scope.

---

Revision note (2026-07-12): initial authoring. Fleshed out the skeleton after verifying every link of the four review findings against the working tree (file:line citations throughout), reading MP-14's Integration Points 3 and 5 and its Decision Log entry on uninit-slot enforcement, and reading keiki EP-78's Milestone 4 to pin the non-duplication boundary. Key resolutions recorded in the Decision Log: spoon-idiom purity for the validation guard, `ErrorCall`-only catching, a distinct encode-failure counter, caller-side metric recording via a reason-carrying `SnapshotLookup`, no logging seam (decision: data + counter), shared write-failure counter for workflows, keeping `rotateGeneration`'s unconditional seed snapshot (already documented as deliberate), and the `Error StoreError` constraint addition.

Revision note (2026-07-13): completed M1. Added the strict initial snapshot encode probe, a two-register `emptyRegFile` regression fixture, and focused acceptance coverage that proves the warning names `uninit: neverWritten`. Recorded the user-local Cabal overlay and clean-project validation procedure under Surprises & Discoveries.

Revision note (2026-07-13): completed M2. Split strict encoding from the store upsert, routed command snapshots through the pre-store encode guard, registered the dedicated encode-failure counter, and added direct plus PostgreSQL-backed regressions. The focused `Keiro.Snapshot` run passed 11 examples, including proof that an event remains committed while the snapshot row is absent and encode failures count separately from write failures.

Revision note (2026-07-13): completed M3. Added reason-preserving aggregate and workflow snapshot lookups while retaining the erasing compatibility wrappers, registered hit/miss/decode-failure counters, and recorded them at the command/workflow option-owning call sites. Focused validation passed 11 aggregate snapshot examples and 6 workflow snapshot examples; corrupt JSON counts decode failures, mismatches/truncation count only misses, and tail hydration counts a hit.

Revision note (2026-07-13): completed M4. Routed step-boundary, terminal, and rotation-seed writes through one `StoreError`-catching advisory helper, propagated the required error constraint through the public workflow and child-runtime signatures, and added a constraint-block integration regression. The focused workflow snapshot run passed 7 examples; the new case commits all seven journal events, writes no snapshot, counts exactly three failed Every-2 boundaries, then proves snapshot recovery after the constraint is removed.
