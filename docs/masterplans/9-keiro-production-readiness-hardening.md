---
id: 9
slug: keiro-production-readiness-hardening
title: "Keiro production-readiness hardening"
kind: master-plan
created_at: 2026-06-11T04:45:44Z
intention: intention_01kv40hzwaenftzem0gxypz4mj
---

# Keiro production-readiness hardening

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Keiro is an event-sourcing framework and workflow engine (Haskell, effectful + hasql + PostgreSQL + Kafka) spread across four library packages in this repository: `keiro-core` (contracts: codecs, stream naming, snapshot policy, integration-event envelope), `keiro` (event store runtime: commands, snapshots, projections, read models, outbox/inbox, timers, sharded subscriptions, process managers, durable workflows), `keiro-pgmq` (PostgreSQL job queues over the PGMQ extension), and `keiro-test-support` (PostgreSQL test fixtures). A June 2026 production-readiness audit (five deep-read passes over all ~11k lines, cross-checked against the SQL migrations in `keiro-migrations/`, the dependency sources, and the test suites) found that the happy paths are solid — atomic append, typed errors, transactional inbox, crash-consistent workflow journaling — but the crash-recovery paths and worker failure handling are incomplete. Seven findings cause message loss, permanent stalls, or silent work loss under normal operation (worker crashes, deploys, slow handlers), and in several places the documentation promises recovery behavior the SQL does not deliver.

After this initiative is complete, keiro can be run in production with multiple replicas: no message is lost when a worker crashes between claiming and publishing; a poison workflow or poison message never halts a whole subsystem; workflow sleeps fire on time and `continueAsNew` works across generations; jobs longer than 30 seconds are safe; a transient database blip never silently kills a worker; processed data is pruned instead of growing without bound; configuration mistakes fail loudly at construction time; and every documented recovery guarantee is backed by a crash-window test that kills the process between the two statements the guarantee spans.

In scope: every audit finding of severity critical, high, and medium, plus the low-severity findings that are cheap to fix while touching the same code. Fixes to the three upstream repositories this initiative depends on — kiroku (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`), shibuya (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` and `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`), and ephemeral-pg (`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`) — are explicitly in scope (user decision, 2026-06-10).

Out of scope: new features; the kiroku `$all`-row append serialization ceiling (a known architectural throughput limit — document it, do not redesign it); online (shadow-table) read-model rebuild — the offline rebuild gets a documented operator procedure only; the keiro-dsl toolchain, except the mechanical compile fixes (codegen templates and checked-in generated fixtures) that EP-2's codec signature change forces so the repository keeps building; the jitsurei example service beyond whatever compile fixes the same change forces.


## Decomposition Strategy

The audit findings cluster naturally by runtime subsystem, and each subsystem's fixes are independently verifiable with its own test suite, so the decomposition follows functional concerns rather than severity. Eight child plans, grouped into three phases because more than seven plans need waves.

Phase 1 lays foundations that other plans consume. EP-1 fixes the upstream repositories: kiroku's transaction runner swallows the unique-violation that signals a duplicate deterministic event id (mapping it to `ConnectionError` instead of `DuplicateEvent`), kiroku lacks an event-id point lookup (forcing O(stream) idempotency scans downstream), shibuya's ingester async is unobserved so a transient poll error silently kills a worker, and ephemeral-pg's initdb cache is written non-atomically. EP-2 hardens the `keiro-core` contracts, including the one breaking API change in the initiative (threading the event-type tag into `Codec.decode`); doing this first means every later plan builds against the final contract shapes.

Phase 2 hardens the four runtime subsystems in parallel: the event-store command/read path (EP-3), the outbox/inbox/timer/shard workers (EP-4), the process manager and router (EP-5), and the workflow engine's failure handling and leasing (EP-6). These touch disjoint modules except for the integration points documented below.

Phase 3 builds on phase 2 artifacts: EP-7 fixes workflow sleep/generation/patch semantics and journal scale (it consumes the `keiro_workflows` instance table EP-6 introduces and the timer-schema changes EP-4 makes), and EP-8 exposes the keiro-pgmq tuning surface (it rides on EP-1's shibuya supervision fix for its worker-resilience acceptance test).

Alternatives considered. A severity-ordered decomposition ("blockers plan, highs plan, mediums plan") was rejected because it would put unrelated modules in one plan and force every plan to touch every subsystem — maximal coupling. Folding the process manager/router work into the messaging plan (EP-4) was rejected because EP-5 has a hard dependency on EP-1's kiroku artifacts while EP-4 has none; merging would needlessly serialize the messaging work behind the upstream work. A single workflow plan was rejected as far too large (three criticals, four highs, eight mediums across ten modules); the split puts "the engine must not die or duplicate effects" (EP-6) before "suspended workflows must wake correctly and cheaply" (EP-7), which matches the dependency on the instance table. A separate crash-window test-suite plan was rejected: tests that prove a fix must land with the fix, so each plan carries its own.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Fix upstream crash-safety gaps in kiroku, shibuya, and ephemeral-pg | docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md | None | None | Complete |
| 2 | Harden keiro-core codec and stream contracts | docs/plans/68-harden-keiro-core-codec-and-stream-contracts.md | None | None | Complete |
| 3 | Fix event-store command path, snapshot, and read-model correctness | docs/plans/69-fix-event-store-command-path-snapshot-and-read-model-correctness.md | None | EP-2 | Complete |
| 4 | Make outbox, inbox, timer, and shard workers crash-recoverable | docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md | None | None | Complete |
| 5 | Fix process manager and router delivery correctness | docs/plans/71-fix-process-manager-and-router-delivery-correctness.md | EP-1 | None | Complete |
| 6 | Workflow engine failure handling, instance leasing, and crash-window atomicity | docs/plans/72-workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity.md | None | None | In Progress |
| 7 | Workflow sleep, generation, and patch semantics plus journal scale hygiene | docs/plans/73-workflow-sleep-generation-and-patch-semantics-plus-journal-scale-hygiene.md | EP-6 | EP-4 | Not Started |
| 8 | Expose keiro-pgmq tuning surface and make job workers resilient | docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md | None | EP-1, EP-2 | Not Started |


## Dependency Graph

EP-1 and EP-2 have no dependencies and start immediately, in parallel (they touch different repositories).

EP-5 hard-depends on EP-1 because its core fix is impossible without kiroku artifacts: the process manager's benign-duplicate fold (`Left (StoreFailed (DuplicateEvent ...))` in `keiro/src/Keiro/Router.hs` and `keiro/src/Keiro/ProcessManager.hs`) is dead code until kiroku's transaction runner routes usage errors through `mapUsageError` so the `events_pkey` unique violation surfaces as `DuplicateEvent` rather than `ConnectionError`; and replacing the O(stream-length) `eventAlreadyIn` scan requires the event-id point-lookup statement EP-1 adds to kiroku's store API.

EP-7 hard-depends on EP-6 because EP-6 introduces the `keiro_workflows` instance table (one row per workflow instance carrying status and lease columns) and EP-7's discovery-query and pruning work replaces the current full-history `GROUP BY` scan with reads of that table. The hard dependency binds only EP-7's milestones 5 and 6 (discovery switch, pruning, wake-after skip); its milestones 1 through 4 (sleep livelock, generation-correct wake-source identity, patch classification, replay fidelity) touch none of EP-6's artifacts and can start immediately. EP-7 also soft-depends on EP-4: both edit the timer schema statements in `keiro/src/Keiro/Timer/Schema.hs` (EP-4 adds stuck-`firing` requeue and status-guarded terminal transitions; EP-7 adds an insert-only arming statement, `scheduleTimerOnceTx`, that leaves the existing upsert untouched). EP-7 should rebase on EP-4's statements if EP-4 has landed; otherwise coordinate via the integration point below.

EP-3 soft-depends on EP-2: EP-2's breaking change to `Keiro.Codec.decode` (threading the event-type tag) updates call sites in `keiro/src/Keiro/Command.hs`, the same module EP-3 edits. EP-3 can proceed independently but should land after EP-2 to avoid conflicting edits to `decodeRecorded` call sites.

EP-8 soft-depends on EP-1: the silent-worker-death fix lives upstream in shibuya, and EP-8's acceptance test for worker resilience (a transient poll error must not stop polling) only passes once EP-1's shibuya change is in (EP-8 ships the test as pending until then). EP-8 also soft-depends on EP-2: both touch `keiro-pgmq/src/Keiro/PGMQ/Codec.hs` — EP-2's codec change makes the job envelope carry an event-type tag, and EP-8 restructures `decodeJob`'s error type around the same envelope (see the integration point below). All of EP-8's remaining keiro-pgmq API-surface work proceeds independently.

EP-4 and EP-6 have no dependencies. Maximum parallelism: EP-1, EP-2, EP-4, and EP-6 can all run concurrently from day one; EP-3 joins once EP-2 lands; EP-5 once EP-1 lands; EP-7 once EP-6 lands; EP-8 any time, with its resilience test gated on EP-1.


## Integration Points

**kiroku store error mapping and event-id lookup** — plans EP-1 (defines), EP-5 (consumes). EP-1 changes kiroku so transactional appends surface `DuplicateEvent` (today `runTxOnPool` in `kiroku-store/src/Kiroku/Store/Effect.hs` maps every usage error to `ConnectionError`) and adds an event-existence point lookup (`SELECT` against the events primary key, exposed through kiroku's store effect). EP-5 consumes both: the duplicate fold in router/process-manager becomes live, and `eventAlreadyIn` in `keiro/src/Keiro/ProcessManager.hs` becomes a point query. EP-5 must not start until EP-1 publishes the new kiroku API (function name and signature recorded in EP-1's Interfaces section; EP-5 reads it from there).

**`Keiro.Codec` decode signature** — plans EP-2 (defines), EP-3 (orders after it), EP-8 (consumes the envelope consequence). EP-2 changes `decode :: Value -> Either Text e` to `decode :: EventType -> Value -> Either Text e` (and threads the tag through `Upcaster`, `decodeRaw`, and `migrateToCurrent`) in `keiro-core/src/Keiro/Codec.hs`. EP-2's research corrected the blast radius: `decodeRecorded`'s own signature is unchanged, so `keiro/src/Keiro/Command.hs` and `keiro/src/Keiro/Workflow.hs` are NOT affected; the break lands at the fourteen in-repo codec literals, `decodeRaw`/`migrateToCurrent` callers, keiro-dsl codegen templates plus its checked-in generated fixtures, and `keiro-pgmq`'s `keiroJobCodec` (whose envelope gains a `"t"` event-type tag field with a single-event-codec fallback for legacy rows, since PGMQ has no tag column). EP-3's soft dependency remains as an ordering preference (both plans touch the command-path test sections), not a signature conflict.

**Timer schema statements** (`keiro/src/Keiro/Timer/Schema.hs`) — plans EP-4 (defines), EP-7 (extends). EP-4 owns the claim/requeue/mark statements: it adds reclaim of stale `firing` rows and a status guard on `markTimerFired`. EP-7 changes the arm path (`scheduleTimerTx` upsert) so re-arming an existing `scheduled` timer preserves its original `fire_at`. Both plans must keep the statement set compatible: EP-7's insert-only (or fire_at-preserving) upsert must not reintroduce rows EP-4's requeue logic cannot see.

**`KeiroMetrics` / `keiro/src/Keiro/Telemetry.hs`** — plans EP-3, EP-4, EP-5, EP-6 (all extend additively). EP-3 adds command-path conflict/retry/duplicate counters, EP-4 adds worker-recovery and poison counters, EP-5 adds dispatch failure/duplicate/poison counters, EP-6 adds workflow-failure counters. All additions are new optional fields on the existing `KeiroMetrics` record. Naming follows the convention already shipped in the code — dot-separated names prefixed `keiro.` (e.g. `keiro.outbox.reclaimed`), matching the twenty existing instruments — not the snake_case form an earlier draft of this document suggested. No ordering constraint.

**`keiro_workflows` instance table** — plans EP-6 (defines), EP-7 (consumes). EP-6 adds a migration creating one row per workflow instance (workflow name, id, current generation, status including a terminal `failed`, lease owner/expiry), written in the same transaction as the journal markers it summarizes. EP-7 switches discovery (`findUnfinishedWorkflowIds` in `keiro/src/Keiro/Workflow/Schema.hs`) to read it and adds pruning of terminal data. The table's columns and status values are recorded in EP-6's Interfaces section; EP-7 reads them from there.

**keiro-pgmq job envelope** (`keiro-pgmq/src/Keiro/PGMQ/Codec.hs`) — plans EP-2 (defines), EP-8 (extends). EP-2 owns the envelope shape change (the `"t"` event-type tag with legacy fallback, forced by the codec signature change). EP-8 restructures the decode path around the same envelope: `decodeJob :: Value -> Either JobDecodeError p` with a distinct version-ahead case that maps to a retry outcome instead of dead-lettering. If EP-8 starts before EP-2 lands, it must write its decode-error work against the pre-EP-2 envelope and reconcile when EP-2 merges; landing EP-2 first avoids the double touch.

**Config-validation convention** — plans EP-4, EP-8 (integration, no ordering). Both introduce smart constructors for worker/retry configs (rejecting non-positive batch sizes, `maxRetries < 1`, `leaseTtl <= renewInterval`, negative delays). Convention to agree on: `mkX :: ... -> Either XConfigError X` with the raw constructor still exported but documented as unvalidated, mirroring how `keiro-core` exposes `mkEventStream`. Whichever lands first establishes the error-type naming (`<Thing>ConfigError`).

**Crash-window test pattern** — plans EP-4, EP-5, EP-6, EP-7 (integration, no ordering). Each plan adds tests that simulate a crash between two statements of a claimed guarantee (e.g. claim-then-mark, signal-row-then-journal) by running the first statement directly via the schema module and then exercising recovery. All use the suite-level template-database fixture from `keiro-test-support` (`withMigratedSuite` in `keiro-test-support/src/Keiro/Test/Postgres.hs`), never per-example migrations. The first plan to land one establishes the helper shape; later plans reuse or generalize it rather than inventing a parallel one.


## Progress

Milestone-level rollup across child plans; the authoritative per-step state lives in each child's Progress section.

- [x] EP-1: kiroku — transactional appends surface `DuplicateEvent`; event-id point lookup added
- [x] EP-1: shibuya — ingester async supervised; transient poll errors retried
- [x] EP-1: ephemeral-pg — initdb cache written atomically
- [x] EP-2: codec decode receives event-type tag; all call sites updated
- [x] EP-2: `mkCodec` validation; version-ahead guard; malformed-stamp error
- [x] EP-2: stream/category constructor hygiene and integration-event wire fixes
- [x] EP-3: snapshot-write failures no longer fail committed commands
- [x] EP-3: sharded subscription position reads; `Strong` consistency implemented or removed
- [x] EP-3: read-model registry churn eliminated; async-projection contract honest
- [x] EP-4: outbox — stale `publishing` reclaim, publish exception guard, GC
- [x] EP-4: inbox — poison-message path public, backlog count off hot path, index
- [x] EP-4: timers — stuck `firing` auto-requeue, status-guarded transitions
- [x] EP-4: shard worker — error visibility, reader supervision, lease relinquish
- [x] EP-5: PM/router ack contract fixed (no ack on failed dispatch; thrown errors finalize acks)
- [x] EP-5: `eventAlreadyIn` point lookup; concurrent-duplicate test green
- [x] EP-6: resume worker survives poison workflows; `WorkflowFailed` path live
- [x] EP-6: per-instance lease; concurrent workers cannot double-run effects
- [x] EP-6: signal/child-completion/cancel crash windows closed
- [ ] EP-7: sleeps fire under an active resume worker; generation-namespaced wake sources
- [ ] EP-7: patch classification journaled at first run; discovery via instance table; pruning
- [x] EP-8: vt/batch/polling exposed; lease-extension handle; `runJobOnce` is a real drain
- [x] EP-8: retry-policy validation; future-version payloads retry instead of dead-letter; codec tests


## Surprises & Discoveries

Findings from the plan-authoring research passes (2026-06-10), recorded here because they changed cross-plan coordination; per-plan detail lives in each child's own Surprises and Decision Log sections.

- EP-6 needs no dependency on EP-1 after all. The audit suggested the duplicate-append crash in the workflow `Step` miss path (`recordStep`) might need kiroku's `DuplicateEvent` mapping from EP-1. EP-6's research found the cleaner fix is local: a `pg_advisory_xact_lock` plus in-transaction index re-check inside a new `prepareJournalAppend` builder makes the 23505 unique violation unreachable and lets the losing worker return the journaled value. The registry's "EP-6: no hard deps" row stands; EP-1's `DuplicateEvent` mapping remains required by EP-5 only.
- EP-2's breaking change does not touch `keiro/src/Keiro/Command.hs` — `decodeRecorded`'s signature is unchanged; the break lands at codec literals, `decodeRaw`/`migrateToCurrent` callers, keiro-dsl codegen plus generated fixtures, and the keiro-pgmq job envelope. The EP-2↔EP-3 integration point was corrected accordingly, and a new EP-2↔EP-8 integration point (job envelope) was added with EP-8 gaining a soft dependency on EP-2.
- The EP-5 ack bug is worse than the audit framed it: the process-manager worker never invokes the shibuya `AckHandle` at all (the decision is computed and then discarded by `Fold.drain`), and the audit's C2 framing partially conflated the PM worker with the router worker, which already finalizes acks and already halts on `PMCommandFailed`. Plan 71 reflects the corrected split: ack wiring + result inspection in the PM worker, thrown-error guards in both workers.
- codd tracks applied migrations by filename only (no content checksum), so EP-4 can pin `search_path` in the already-applied migrations in place — and the defect turned out to cover seven migration files, not four (the three 2026-06-03 workflow migrations share it).
- The shipped metric-naming convention is dot-separated `keiro.*` (twenty existing instruments); three plan authors independently flagged that this document's original "snake_case `keiro_`" phrasing contradicted the code. The integration point now follows the code.
- EP-1 deliberately does not add retry to pgmq-effectful's interpreter: `sendMessage`/`deleteMessage` are not idempotent, so interpreter-level retry would be unsafe. The transient-retry fix lives at the only safe call site, the shibuya-pgmq-adapter polling loop.
- keiro-pgmq's test suite was not wired into the Justfile's `haskell-test` recipe at all — its tests have not been running in the standard gate. EP-8 milestone 8 fixes the wiring.
- EP-1 kiroku work is complete as of 2026-06-15. M1 had already landed in upstream commit `fa43ec2`; M2 added and pushed `eventExistsInStream` in commit `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`. `cabal test kiroku-store-test` passed with 226 examples, 0 failures.
- EP-1 shibuya work is complete as of 2026-06-15. shibuya-core now propagates ingester failures in commit `f0c9ce3`; shibuya-pgmq-adapter now retries transient poll errors in commit `319b3b717c0284d8c207375151b388639039a1e1`. `cabal test shibuya-core-test` passed with 118 examples, 0 failures, and `cabal test shibuya-pgmq-adapter:shibuya-pgmq-adapter-test --enable-tests` passed with 134 examples, 0 failures.
- EP-1 ephemeral-pg cache hardening is complete as of 2026-06-15. Atomic cache publication and the concurrent `createCache` regression landed in commit `215e4ae5fc844d322e2c715369bf5ec4ff285294`; `cabal test` passed with 11 examples, 0 failures.
- EP-1 is complete as of 2026-06-15. The Hackage releases are visible to `cabal update`, keiro consumes kiroku at `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`, and published-package validation passed: `cabal build all`; `keiro-test` 158 examples, 0 failures; `keiro-pgmq-test` 50 examples, 0 failures, 2 pending; `keiro-migrations-test` 2 examples, 0 failures; `jitsurei-test` 16 examples, 0 failures.
- EP-2 is complete as of 2026-06-15. The final shape re-exports `EventType(..)` from `Keiro.Codec` so pgmq and generated DSL fixtures can construct tags without direct kiroku-store dependencies, and generated harnesses now round-trip through the tag-aware parser using `eventType <codec> e`. Validation passed with `cabal test keiro-test` (166 examples, 0 failures), `cabal build all --enable-tests`, the jitsurei/keiro-dsl/keiro-pgmq suite battery, and `just haskell-test`.
- EP-3 is complete as of 2026-06-15. Command retries/snapshot failures are observable,
  snapshot boundaries and codec rollbacks are handled, sharded read-model positions and
  real `Strong` consistency are implemented, registry hot-path churn is removed, async
  projection deduplication is transactional with a prune function, and the rebuild/`$all`
  operator notes are documented. Validation passed with `cabal build all`,
  `keiro-test` 182 examples, `keiro-migrations-test` 2 examples, and `jitsurei-test` 16
  examples, all with 0 failures.
- EP-5 is complete as of 2026-06-15. EP-1's actual kiroku lookup is stream-scoped
  `eventExistsInStream`, which let `eventAlreadyIn` preserve its old semantics while
  becoming a point lookup. The process-manager and router workers now share additive
  worker options, finalize every ack exactly once, retry transient store failures,
  halt deterministic failures, expose explicit poison-message policy, and record
  `keiro.dispatch.*` counters. `just haskell-verify` also exposed website verification
  assumptions unrelated to EP-5: the builder expected an untracked optional `spikes/`
  directory and linkcheck treated Markdown source-file references in generated plan pages
  as navigable site links; both were corrected so verification passes in a clean checkout.
- EP-6 Milestone 2 is complete as of 2026-06-15. The resume worker isolates poison workflows,
  writes `WorkflowFailed`, preserves healthy workflow progress in the same pass, classifies
  thrown `StoreError`s as transient, and both fixed-poll and push loop drivers now have
  focused survival tests. Validation passed with focused `keiro-test` runs for
  `Keiro.Workflow.Resume` (8 examples) and `Keiro.Workflow push latency` (2 examples), plus
  full `cabal test keiro-test` (225 examples), all with 0 failures.
- EP-6 Milestone 3 is complete as of 2026-06-15. Resume workers now claim per-instance
  leases and skip live foreign owners, and same-step journal append races serialize through
  `prepareJournalAppend` so the loser returns the journaled value. Validation passed with
  focused `Keiro.Workflow` coverage (60 examples) and full `cabal test keiro-test`
  (229 examples), both with 0 failures.
- EP-6 Milestone 4 is complete as of 2026-06-15. Awakeable signal and child completion
  now compose their row transition with the parent/workflow journal append, and both await
  arms repair completed rows that predate the journal entry. The EP-6 crash-window rollup
  remains open until M5 closes child cancellation. Full `cabal test keiro-test` passed with
  231 examples, 0 failures.


## Decision Log

- Decision: Include fixes to the upstream repositories (kiroku, shibuya, ephemeral-pg) as a child plan rather than working around them inside keiro.
  Rationale: User decision (2026-06-10) after being offered both options. The workarounds (text-matching `ConnectionError` payloads, documenting silent worker death) would be permanent liabilities; all three repos are owned by the same author, so the proper fixes are available.
  Date: 2026-06-10

- Decision: Decompose by runtime subsystem (eight plans, three phases), not by finding severity.
  Rationale: Subsystem plans touch disjoint modules, are independently verifiable against their own test suites, and let four plans start in parallel. Severity-ordered plans would each touch every subsystem and serialize everything.
  Date: 2026-06-10

- Decision: Split the workflow engine into two plans (EP-6 safety/leasing, EP-7 semantics/scale) with EP-7 hard-depending on EP-6.
  Rationale: The workflow findings alone (3 critical, 4 high, 8 medium) exceed a healthy single-plan scope, and the natural seam is the `keiro_workflows` instance table: EP-6 needs it for leases and terminal status, EP-7 builds discovery and pruning on it.
  Date: 2026-06-10

- Decision: Keep the process-manager/router plan (EP-5) separate from the messaging plan (EP-4).
  Rationale: EP-5 hard-depends on EP-1's kiroku artifacts; EP-4 has no upstream dependency. Merging would serialize the messaging hardening behind the kiroku release for no benefit.
  Date: 2026-06-10

- Decision: No standalone test-suite plan; each plan carries the crash-window tests proving its own fixes.
  Rationale: A test that proves a fix must land with the fix or the plan's acceptance is unverifiable. The shared test-helper shape is coordinated as an integration point instead.
  Date: 2026-06-10

- Decision: One breaking API change is accepted in EP-2 (`Codec.decode` gains the event-type argument); everything else in the initiative is additive or behavioral.
  Rationale: The audit showed shape-compatible multi-event payloads can silently decode as the wrong constructor without the tag; fixing it later, after more downstream codecs exist, only gets more expensive. Doing it in phase 1 means all later plans build against the final contract.
  Date: 2026-06-10

- Decision: The kiroku `$all`-row append serialization ceiling and online read-model rebuild are documented as known limits, not fixed in this initiative.
  Rationale: Both are architectural changes with system-wide blast radius, not hardening; neither blocks correct production operation at moderate write rates.
  Date: 2026-06-10


- Decision: Metric names follow the shipped dot-separated `keiro.*` convention, not the snake_case form this document originally suggested.
  Rationale: Twenty existing instruments in `keiro/src/Keiro/Telemetry.hs` already use dots; consistency with shipped code beats consistency with a draft note. Flagged independently by the EP-3, EP-4, and EP-5 authoring passes.
  Date: 2026-06-10

- Decision: EP-8 gains a soft dependency on EP-2 (job-envelope integration point added).
  Rationale: EP-2's codec change forces a `"t"` event-type tag into the keiro-pgmq job envelope; EP-8 restructures `decodeJob` around the same envelope. Landing EP-2 first avoids touching the envelope twice.
  Date: 2026-06-10

- Decision: keiro-dsl mechanical compile fixes (codegen templates, checked-in generated fixtures) are pulled into EP-2's scope despite the toolchain being out of initiative scope.
  Rationale: The repository must build after EP-2's breaking change; the fixes are mechanical and tiny compared to spinning up a separate plan.
  Date: 2026-06-10


## Outcomes & Retrospective

EP-1, EP-2, and EP-3 are complete as of 2026-06-15. EP-2 delivered the planned core-contract hardening: tag-aware codec decode and upcasting, codec configuration validation, explicit migration/metadata errors, stream/category invariant guards, terminality-aware snapshot policy, and Kafka header fidelity for integration-event `occurredAt` and `attributes`. EP-3 delivered the command/read-side correctness work: honest command outcomes after committed appends, observable OCC retry behavior, snapshot policy and overwrite fixes, sharded read-model positions, real `Strong` consistency, no registry write churn, transactional async projection deduplication, and the promised operator documentation.

EP-4 is complete as of 2026-06-15. Outbox rows stranded in `publishing` are reclaimed, publisher exceptions become per-row failures, sent outbox rows can be pruned, inbox poison messages are accounted and dead-lettered through an opt-in retry wrapper, stale `firing` timers requeue by default, shard workers survive transient lease errors and restart dead readers, graceful shutdown relinquishes shard leases, and the worker/producer configs now have typed construction-time validation. Validation passed with `cabal build all`, `keiro-test` 205 examples, `keiro-migrations-test` 2 examples, and `jitsurei-test` 16 examples, all with 0 failures.

EP-5 is complete as of 2026-06-15. Process-manager and router delivery now has the promised production behavior: no failed dispatch is silently acked, thrown store errors finalize the in-flight message, duplicate races fold through kiroku's `DuplicateEvent`, and operators can see dispatch failures/duplicates/poison counts. Validation passed with `just haskell-verify`: `cabal build all`; `keiro-test` 215 examples, 0 failures; `keiro-pgmq-test` 50 examples, 0 failures, 2 pending; `jitsurei-test` 16 examples, 0 failures; jitsurei diagrams check; website build; and linkcheck across 99 HTML pages.

EP-6 Milestone 2 is complete as of 2026-06-15. Poison workflow handling and `WorkflowFailed` are live, and the remaining loop-driver survival tests have landed; M3 leasing and race-proof journal appends remain next.

EP-6 Milestone 3 is complete as of 2026-06-15. Per-instance leases are live in the resume worker, lease skips are observable, and journal appends are transaction-composable and same-step race-proof; M4 crash-window atomicity for awakeable signals and child completion remains next.

EP-6 Milestone 4 is complete as of 2026-06-15. Awakeable and child-completion crash windows are closed for new writes and repaired on await-arm re-entry for historical wedges; M5 cancellation atomicity and child-result envelope work remains next.

EP-6 Milestone 5 is complete as of 2026-06-15. Child cancellation now writes the child marker and parent sentinel atomically with the row transition, cancelled-but-unmarked children self-heal when driven, child results use tagged envelopes with legacy fallback, failed children wake parents through `WorkflowChildFailed`, and mid-run cancellation stops at the next workflow step boundary.

EP-6 is complete as of 2026-06-15. The workflow engine now has poison-workflow isolation and terminal failure marking, per-instance leases, transaction-composable journal appends, atomic awakeable and child wake paths, cancel repair, child result envelopes, failed-child propagation, and documentation that matches those semantics. Final validation passed with `cabal build all`, `cabal test keiro-test` (237 examples, 0 failures), `cabal test keiro-migrations-test` (2 examples, 0 failures), and `cabal test jitsurei-test` (16 examples, 0 failures).


---

Revision note (2026-06-10): After the eight child plans were authored, this document was reconciled against their research findings: corrected the EP-2 blast-radius description in the Codec integration point (Command.hs unaffected), added the EP-2↔EP-8 job-envelope integration point and EP-8's soft dependency on EP-2, added EP-5 to the KeiroMetrics integration point and switched its naming convention to the shipped dot-separated form, refined the EP-7 dependency note (hard dependency binds milestones 5–6 only) and the EP-7↔EP-4 timer coordination (insert-only `scheduleTimerOnceTx`), amended the keiro-dsl scope exclusion, and populated Surprises & Discoveries with the cross-plan findings (EP-6 needs no EP-1 dependency; the PM worker never finalizes acks at all; codd permits in-place `search_path` pins; seven migrations affected, not four; pgmq-effectful retry intentionally out; keiro-pgmq tests missing from the Justfile gate).

Revision note (2026-06-15): EP-5 was implemented and marked Complete. The registry, progress rollup, Surprises & Discoveries, and Outcomes & Retrospective now record the worker ack fix, stream-scoped kiroku point lookup, duplicate-race coverage, dispatch metrics, and final validation evidence.

Revision note (2026-06-15): EP-6 Milestone 2 was completed. The Progress rollup now checks the poison-workflow/`WorkflowFailed` item, and Surprises & Discoveries plus Outcomes & Retrospective record the focused resume and push-loop validation evidence.

Revision note (2026-06-15): EP-6 Milestone 3 was completed. The Progress rollup now checks the per-instance lease/concurrent-worker item, and Surprises & Discoveries plus Outcomes & Retrospective record the lease and race-proof journal append validation evidence.

Revision note (2026-06-15): EP-6 Milestone 4 was completed. Surprises & Discoveries plus Outcomes & Retrospective record the awakeable and child-completion atomicity work and validation evidence; the third EP-6 Progress rollup item remains unchecked until M5 cancellation crash windows are closed.

Revision note (2026-06-15): EP-6 Milestone 5 was completed. The third EP-6 Progress rollup item is now checked, and Outcomes & Retrospective records the cancel atomicity, child-result envelope, failed-child wake, and mid-run cancellation work. Validation passed with `cabal test keiro-test --test-options='--match "Keiro.Workflow.Child"'` (14 examples, 0 failures), `cabal test keiro-test --test-options='--match "Keiro.Workflow"'` (68 examples, 0 failures), and full `cabal test keiro-test` (237 examples, 0 failures).

Revision note (2026-06-15): EP-6 Milestone 6 completed the haddock truth pass and final validation. EP-6 is now fully implemented; final validation passed with `cabal build all`, `cabal test keiro-test` (237 examples, 0 failures), `cabal test keiro-migrations-test` (2 examples, 0 failures), and `cabal test jitsurei-test` (16 examples, 0 failures).
