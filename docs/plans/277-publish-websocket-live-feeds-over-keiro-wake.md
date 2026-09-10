---
id: 277
slug: publish-websocket-live-feeds-over-keiro-wake
title: "Publish WebSocket live feeds over Keiro.Wake"
kind: exec-plan
created_at: 2026-09-10T01:54:00Z
intention: "intention_01m24gb383e91rfr2dp7f2dkdz"
---

# Publish WebSocket live feeds over Keiro.Wake

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Distill durable decisions into docs/adr/ before completion.


## Purpose / Big Picture

After this change, a browser (or any WebSocket client) can open one connection to a keiro application and watch three pieces of framework state change live: the workflow instances on the `keiro_workflows` wake ledger, the timers that are scheduled or currently firing, and the projection group status relation. Each feed sends a full `snapshot` after `subscribe` and then small `update` frames whenever the underlying state changes, so a UI showing hundreds of running workflows across many open tabs no longer has to poll every listing every second. Every feed is paired with a plain HTTP `GET` that returns the same items, because a PostgreSQL `NOTIFY` is a best-effort wake-up hint and never the truth; a client that misses frames recovers by re-reading.

This implements [IR-27](../improvement-requests/publish-websocket-live-feeds-over-keiro-wake.md), part of the keiro runtime UI initiative (`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`). The feeds live in the HTTP sister package `keiro-ops-http` that [IR-26](../improvement-requests/serve-the-keiro-ops-surface-over-http.md) requests and [plan 276](276-serve-the-keiro-ops-surface-over-http.md) builds, speak the cross-project WebSocket convention recorded in `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`, and obey the rule of `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3` (push is a hint, poll is truth).

You can see it working by running the test suite `cabal test keiro-ops-http-test`, which drives a real WebSocket client against a real PostgreSQL store, and by running the standalone `keiro-ops-http` executable against the jitsurei database and issuing `curl http://127.0.0.1:9092/wf/list` while `just jitsurei-workflow` mutates workflows in another shell.


## Progress

- [x] (2026-09-10T02:40Z) Planning: IR-27 records this plan (`## Planning` section and a bundle log entry); the request stays `proposed` until implementation evidence exists.
- [ ] Milestone 1: add `Keiro.Timer.findPendingTimers` (scheduled-or-firing timers in `fire_at` order with keyset paging) and its tests in `keiro/test/Main.hs`.
- [ ] Milestone 1: add `Keiro.Ops.Cursor`; export `workflowInstanceJson` from `Keiro.Ops.Workflow` and `timerJson` from `Keiro.Ops.Timer`; add `projectionGroupStatusJson` and the read-only `projection status` command to `Keiro.Ops.Projection`; add the read-only `timer pending list` command to `Keiro.Ops.Timer`; extend `keiro-ops/test/Main.hs`.
- [ ] Gate: plan 276 Milestones 1 through 3 are implemented (`keiro-ops-http` exists with `Keiro.Ops.Http.Application.opsApplication`, `Keiro.Ops.Http.Config`, `Keiro.Ops.Http.Cors`, and the health route). Record the commit in the Decision Log.
- [ ] Milestone 2: prove the three paired poll routes (`GET /wf/list`, `GET /timer/pending/list`, `GET /projection/status`) answer through plan 276's mechanical translation with bodies equal to the CLI's `--json` output; add `websockets` and `wai-websockets` to `keiro-ops-http`.
- [ ] Milestone 3: `Keiro.Ops.Http.Protocol` frames, `Keiro.Ops.Http.Views`, `Keiro.Ops.Http.Feed` (shared per-view driver with wake-or-fallback refresh, diffing, bounded per-connection queues with drop-oldest and in-band overflow error), `Keiro.Ops.Http.WebSocket` on `/ws`, and the `opsApplicationWithFeeds` composition.
- [ ] Milestone 3: driver unit tests with `neverWake` and injected reads (fallback refresh, diff, overflow ordering, sequence gaps).
- [ ] Milestone 3: end-to-end WebSocket tests: workflow snapshot then delta after a real completion append; timers and projection group feeds; frame-shape validator; dialect-configured generic client; feed and poll agreement after quiescence; origin and drift refusals at upgrade.
- [ ] Milestone 4: killed-LISTEN degradation test (`pg_terminate_backend` on `kiroku-listener`), proving timeout-driven refresh without wrong frames and notify-driven latency after reconnect.
- [ ] Milestone 5: mount the feeds in the standalone `keiro-ops-http` executable, user documentation with the verbatim NOTIFY caveat and example frames, CAP-16 update, changelogs, `mori.dhall` dependency entries, ADR distillation, and IR-27 implementation evidence.
- [ ] Final gates: `nix fmt`, `nix develop -c just verify`, `cabal check` in `keiro-ops-http/`, `nix flake check`, and bundle validations.


## Surprises & Discoveries

Plans 274, 275, and 276 were created by other sessions while this plan was being researched, and all three were empty skeletons when this plan was first written. Plan 276 was filled in within the hour, so this plan was revised the same day to build on its transport design instead of stating a parallel package contract. See the revision note at the end.


## Decision Log

- Decision (2026-09-10): Build the feeds as diffed re-reads of the supported poll paths, driven by one shared driver per distinct view (feed name plus its filters) rather than one query loop per connection. Rationale: IR-27's motivation is "no polling storms multiplied by open browser tabs"; sharing the driver makes the database cost independent of connection count, and re-reading the same library read the HTTP route uses guarantees the feed can never disagree with the poll path after quiescence (ADR-3 in keiro-ui, ADR-28 here).
- Decision (2026-09-10): Never decode the `NOTIFY` payload. The driver only uses `Keiro.Wake.waitForWake` with a bounded fallback interval (default one second). Rationale: IR-27 requirement 2 and the `Keiro.Wake` design; several instance-row writes (lease claim, crash record, suspend) never append to the event store and therefore never fire a notification, so the fallback is load-bearing, not a safety net.
- Decision (2026-09-10): Add a library read for pending timers (`Keiro.Timer.findPendingTimers`) before any route or feed shows timers. Rationale: `Keiro.Timer` only offers `countDueTimers`, `claimDueTimer` (a mutation), `findStuckTimers`, and `findDeadTimers`; ADR-28 forbids ad-hoc SQL in operator surfaces, so the missing primitive is added and tested in the owning library first.
- Decision (2026-09-10): The paired poll endpoints are not written by hand. keiro-ops gains two read-only commands, `projection status` and `timer pending list`, rendered with the same encoders the feeds use (`workflowInstanceJson`, `timerJson`, and a new `projectionGroupStatusJson`), and plan 276's request-to-arguments translation turns `wf list`, `timer pending list`, and `projection status` into `GET /wf/list`, `GET /timer/pending/list`, and `GET /projection/status` with bodies equal to the CLI's `jsonValue`. Rationale: plan 276 derives every route mechanically from the command tree and forbids a route table; IR-27's "paired HTTP poll endpoints where they do not already exist under IR-26" therefore means "add the missing commands", which also keeps the CLI, the route, and the feed three renderings of one handler result (ADR-28).
- Decision (2026-09-10): Milestones 2 through 5 depend on plan 276's Milestones 1 through 3 (the `keiro-ops` exports, the `keiro-ops-http` package with `opsApplication`, config, CORS, and the health route). Milestone 1 of this plan is independent and may run in parallel. If 276 has not reached Milestone 3 when this plan's Milestone 2 starts, implement 276 up to that point first rather than creating a second package skeleton. Rationale: IR-27 places the feeds in the IR-26 package; two skeletons would have to be merged later and would freeze wire shapes twice.
- Decision (2026-09-10): The feeds are a separate handle (`Keiro.Ops.Http.Feed.FeedHandle`) with its own `FeedConfig`, mounted with `websocketsOr` around plan 276's `opsApplication` by `Keiro.Ops.Http.opsApplicationWithFeeds`, and the standalone `keiro-ops-http` executable mounts them by default. Rationale: the feeds are database-only, exactly like the standalone command set, so the executable can serve them without hooks; keeping `FeedConfig` outside `OpsHttpConfig` means plan 276's configuration type does not change under it.
- Decision (2026-09-10): One WebSocket endpoint `/ws` multiplexed by a `feed` field in `subscribe`, with frame names `subscribe`, `unsubscribe`, `ping`, `snapshot`, `update`, `unsubscribed`, `pong`, `error`, `goodbye`, and a per-view `sequence` on `snapshot` and `update`. Rationale: the keiro-ui convention fixes the structure but leaves names to each domain; a single endpoint composes cleanly behind IR-31's path prefixes; the sequence number makes dropped frames detectable by the client and makes overflow tests deterministic.
- Decision (2026-09-10): Frames carry `trigger` (`subscribe`, `notify`, or `timeout`). Rationale: it is diagnostic only and additive, and it is what makes IR-27 acceptance 2 (degrade to timeout-driven refresh, resume notify-driven latency) mechanically assertable instead of a timing guess.
- Decision (2026-09-10): A WebSocket upgrade is refused with HTTP 409 `schema_drift` under plan 276's `RefuseOnDrift` policy when `verifyExpectedSchemaSession` reports drift at upgrade time, with HTTP 403 `origin_not_allowed` when the upgrade carries an `Origin` header that is neither in `allowedOrigins` nor the request's own `Host`, and with HTTP 503 `too_many_connections` at the connection cap. Rationale: browsers always send `Origin` on WebSocket upgrades and do not apply CORS to them, so an explicit check is the only way the conventions' "disabled by default" posture holds for the socket; allowing the request's own host keeps the single-origin reverse-proxy deployment working with no configuration. Drift is checked once per connection, not per re-read, because the drivers re-read continuously and the check is a full catalog scan.
- Decision (2026-09-10): This plan does not amend `docs/why-keiro.md`. Rationale: [IR-32](../improvement-requests/record-the-inspection-ui-boundary-in-an-adr.md) owns the stance ADR and the wording change; this plan records its own narrower decision (feeds are diffed re-reads over supported reads) as a new ADR and cites IR-32 as the boundary decision that should land before the package is released.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

keiro is a Haskell event-sourcing framework and workflow engine layered on kiroku, an append-only PostgreSQL event store. The repository is a Cabal multi-package project (`cabal.project` lists the packages) built inside a Nix development shell (`nix develop`) that provides GHC 9.12.4, cabal, PostgreSQL 18, `just`, `okf`, and `jq`. Every test suite that touches PostgreSQL uses `keiro-test-support/src/Keiro/Test/Postgres.hs`, which starts a cached ephemeral PostgreSQL server, migrates one template database, and hands each test a fresh clone through `withFreshStore fixture`, giving the test a live `Kiroku.Store.Connection.KirokuStore`.

The operational surface that exists today is `keiro-ops` (`keiro-ops/src/Keiro/Ops.hs`), an embeddable command tree and a standalone CLI. Every command renders into `Keiro.Ops.Render.OpsResult { headers, rows, jsonValue }`, where `jsonValue` is what `--json` prints. `Keiro.Ops.Workflow.runList` calls the library read `Keiro.Workflow.Instance.listWorkflowInstances` and renders each `WorkflowInstanceRow` with the private encoder `workflowInstanceJson` (fields `workflow_id`, `workflow_name`, `generation`, `status`, `attempts`, `last_error`, `next_attempt_at`, `wake_after`, `leased_by`, `lease_expires_at`, `created_at`, `updated_at`, `completed_at`); `wf list --json` prints a bare JSON array of those objects. `Keiro.Ops.Timer` renders timers with the private `timerJson` (fields `timer_id`, `process_manager_name`, `correlation_id`, `fire_at`, `payload`, `status`, `attempts`, `fired_event_id`). Commands run library reads through `runStoreIO env.store action`, where `action :: Eff '[Store, Error StoreError, IOE] a` (`Keiro.Ops.Workflow.runAction`). keiro has no HTTP server or WebSocket endpoint anywhere; `docs/why-keiro.md` states that observability goes through OpenTelemetry and there is no parallel workflow-engine UI. IR-32 asks for an ADR that records an inspection surface as a bounded exception; this plan proceeds under the user's direction to build the keiro UI and leaves that ADR to IR-32.

The three reads the feeds and routes use are all public library functions. `Keiro.Workflow.Instance.listWorkflowInstances :: WorkflowInstanceFilter -> Eff es [WorkflowInstanceRow]` takes exact status filters (the stable vocabulary `running`, `suspended`, `completed`, `cancelled`, `failed` from `Keiro.Workflow.Instance.Schema.statusToText`), an optional workflow name, a keyset cursor `afterKey :: Maybe (Text, Text)` meaning "strictly after this (workflow_name, workflow_id)", and `pageSize`; results are ordered by `(workflow_name, workflow_id)`. A keyset cursor is a "start after this key" bookmark; unlike an `OFFSET`, it stays stable while rows are inserted or deleted. `Keiro.ReadModel.Rebuild.listProjectionGroupStatuses :: Eff es [ProjectionGroupStatusV1]` reads the frozen relation `keiro_read.projection_group_status_v1` (`keiro/src/Keiro/ReadModel/Rebuild/Status.hs`) whose column names, order, and value vocabulary are frozen by [ADR-35](../adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md); the row type has `groupId`, `lifecyclePhase`, `readsAllowed`, `writesAllowed`, `servingRevisionId`, `servingEpoch`, `servingPositionBasis` (`append`, `checkpoint`, or `unmanaged`), `servingAppliedPosition`, `activeRunId`, `candidateRevisionId`, `candidateRebuildPosition`, `candidateRebuildHead`, `queryModels`, `rebuildStartedAt`, `lastPromotedAt`, `failedAt`, `failureCode`, `failureDetail`. `Keiro.ReadModel.storeHeadPosition :: Eff es GlobalPosition` is the newest visible event position and is reported as `visible_store_head` per [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md). There is no library read for "timers that will fire": `keiro/src/Keiro/Timer/Schema.hs` has `countDueTimers`, `claimDueTimer` (which mutates), `findStuckTimers` (only `firing` rows), and `findDeadTimers` (only `dead` rows, with 1 to 100 row pages and an exclusive UUID cursor). The `keiro.keiro_timers` table (`keiro-migrations/migrations/0001-keiro-bootstrap.sql`) has `timer_id`, `process_manager_name`, `correlation_id`, `fire_at`, `payload`, `status`, `attempts`, `fired_event_id`, `created_at`, `updated_at`, and a partial index `keiro_timers_due_idx` on `(status, fire_at, process_manager_name) WHERE status IN ('scheduled', 'firing')` (`0004-keiro-timer-recovery.sql`), which is exactly the shape a "pending timers in fire order" read needs.

The push primitive is `keiro/src/Keiro/Wake.hs`. kiroku's store already runs one dedicated `LISTEN` connection per store (application name `kiroku-listener`, confirmed in the released kiroku-store 0.8.0.0 source) on channel `<schema>.events`, fired by a trigger on the `streams` table on every append, and fans every notification out to an in-process broadcast channel. `wakeSignalFromStore :: KirokuStore -> IO WakeSignal` duplicates that channel (an STM operation, no new database connection), and `waitForWake :: WakeSignal -> Int -> IO WakeReason` blocks until either a notification arrives (`WokenByNotify`, with any backlog collapsed into one wake) or the fallback timeout in microseconds elapses (`WokenByTimeout`). `neverWake` is a signal that only ever times out, used by existing tests to prove the poll path alone is sufficient. kiroku's listener reconnects after a failure with capped exponential backoff starting at one second; notifications sent while it is disconnected are lost permanently. This is the NOTIFY caveat and the reason `waitForWake` always carries a fallback.

Which writes fire a notification matters for the design. A journal append through `Keiro.Workflow.appendJournalEntry` (`keiro/src/Keiro/Workflow/Journal.hs`) appends to a kiroku stream and upserts the `keiro_workflows` row in the same transaction, so completion, cancellation, failure, continue-as-new, and every recorded step fire a notification. The lease claim and release in `Keiro.Workflow.Resume`, the crash record (`recordCrashTx`), the suspend write (`markInstanceSuspendedAwaiting`), and awakeable cancellation write the row without appending, so those status and attempt changes are only ever observed by the fallback re-read. Timer scheduling (`scheduleTimerTx`) normally runs inside a process manager's append transaction and therefore fires a notification; a timer scheduled on its own does not. Projection group lifecycle changes write keiro tables only. The feeds therefore always run "wake or fallback, then re-read, then diff"; the notification only shortens latency.

The package the feeds live in is designed by [plan 276](276-serve-the-keiro-ops-surface-over-http.md), whose decisions this plan relies on and does not restate in full. In brief: `keiro-ops-http/` is a sister package depending on `keiro-ops`; there is no route table, because every HTTP request is translated into a keiro-ops argument vector (path segments are command words and positional arguments, `snake_case` query keys become `--kebab-case` long options) and parsed by the CLI's own `optparse-applicative` parser, then classified per request with `isMutation`; reads answer `GET` with the command's `jsonValue` verbatim as the body; every request first runs `Keiro.Migrations.SchemaCheck.verifyExpectedSchemaSession` on the store pool and refuses with HTTP 409 `schema_drift` under the default `RefuseOnDrift` policy; CORS is `Keiro.Ops.Http.Cors.corsMiddleware :: [Text] -> Middleware` with an allowed-origins list that is off when empty; errors use `Keiro.Ops.Http.Application.errorResponse` producing `{"error": {"code", "message", "details"}}`; the application is `Keiro.Ops.Http.Application.opsApplication :: OpsHttpConfig -> AppHooks -> KirokuStore -> Application` with `OpsHttpConfig { mutations, schemaDrift, allowedOrigins }`; the runner is `Keiro.Ops.Http.Server.withOpsHttpServer :: OpsHttpServerConfig -> Application -> (OpsHttpServer -> IO a) -> IO a` binding `127.0.0.1:9092` by default (port 0 in tests yields `serverPort`); and a standalone `keiro-ops-http` executable serves the database-only command set. Consequently the commands this plan adds to keiro-ops in Milestone 1 become routes with no transport work, and the only HTTP-layer code this plan writes is the WebSocket endpoint and the feed engine. [Plan 275](275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md) (IR-30) will add richer workflow reads and a canonical workflow JSON rendering; this plan uses the existing `listWorkflowInstances` and `workflowInstanceJson`, and if 275 lands first the workflow view adopts its rendering so the feed and `wf list` stay identical. [Plan 274](274-expose-process-manager-inspection-reads.md) (IR-29) is independent.

The keiro-ui initiative's contract for this work is `mori://shinzui/keiro-ui` at `docs/architecture/inspection-api-conventions.md` (artifact-level URI pending), whose rules are summarized here so the plan is self-contained. Surfaces are HTTP plus JSON served by an embeddable WAI `Application` from a sister package that also exports a Warp runner (WAI is the standard Haskell interface between a web server and an application; Warp is the server). New fields are `snake_case`. Listings page with an exclusive `from` cursor and `limit`, returning `items` and `next_cursor`, and `next_cursor` is omitted on the last page; cursors are opaque to clients. Errors are `{"error": {"code", "message", "details"?}}` with stable snake_case codes. WebSocket frames are JSON objects with a required `type`; clients send explicit subscribe and unsubscribe frames and `ping`; servers send `snapshot` after subscribe, then incremental frames, `pong`, in-band `error` frames (including queue overflow), and `goodbye` before a server-initiated close; per-connection queues are bounded with drop-oldest overflow signaled in-band; servers ping idle connections (30-second precedent). CORS (the browser rule that blocks a page on one origin from calling an API on another unless the API opts in through response headers) must be configurable with an explicit allowed-origins list and disabled by default. Authentication is out of scope; servers assume a trusted network or an authenticating reverse proxy, and documentation must say so. keiro surfaces use ADR-28's reporting vocabulary: `store_position`, `visible_store_head`, and "global position distance", never "lag" or "backlog". The relevant cross-repository ADRs are `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2` (protocol convention), `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3` (push is a hint, poll is truth), and `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4` (sister packages). The two shipped dialects the convention generalizes are kiroku-metrics (`kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` in `mori://shinzui/kiroku`, endpoint `/ws/events`, frames `ping`, `subscribe_metrics`, `subscribe_events`, `unsubscribe_events`, `pong`, `snapshot`, `event`, `event_stream_started`, `goodbye`, `error`) and shibuya-metrics (`shibuya-metrics/src/Shibuya/Metrics/Types.hs` in `mori://shinzui/shibuya`, endpoint `/ws`, frames `subscribe_all`, `subscribe`, `unsubscribe`, `ping`, `snapshot`, `update`, `pong`, `goodbye`). kiroku-metrics is the implementation model for this plan: it mounts a `websockets` `ServerApp` into WAI with `Network.Wai.Handler.WebSockets.websocketsOr`, uses `WS.withPingThread conn 30`, bounds connections with a `TVar Int`, rejects over-capacity upgrades with `WS.rejectRequest`, swallows `WS.ConnectionException` on send, sends `Goodbye` in a `finally`, and its test (`kiroku-metrics/test/Test/WebSocketSpec.hs`) binds Warp on an OS-assigned port and drives the endpoint with `Network.WebSockets.runClient`. `Network.WebSockets.rejectRequestWith` with `defaultRejectRequest { rejectCode, rejectBody, rejectHeaders }` (verified in websockets 0.13.0.0) lets an upgrade be refused with a chosen status and JSON body.

Local ADRs consulted: [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md) (operator surfaces wrap supported library APIs, never ad-hoc SQL; missing primitives are added to the owning library first; the reporting vocabulary; a future web console reuses the handlers and receives no permission to bypass the boundary), [ADR-35](../adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md) (the frozen status relation and its vocabulary), [ADR-23](../adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md) (the `keiro_workflows` row is the complete wake ledger, which is why the workflow feed reads that row and nothing else), [ADR-25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md) (a background loop never lets one transient error end it; the feed driver follows the same rule), and [ADR-36](../adr/0036-external-readers-use-versioned-guarded-sql-contracts.md) (consulted; it governs projection data reads, which this plan does not expose). No local ADR covers HTTP or WebSocket surfaces; plan 276 writes one for the transport at its completion, this plan writes one for the feed decision, and the boundary stance belongs to IR-32.

Dependency versions verified against the local Hackage index on 2026-09-10 (run `cabal update` and recheck with `cabal info <pkg>` before pinning): `wai` 3.2.5, `warp` 3.4.15, `wai-websockets` 3.0.1.3, `websockets` 0.13.0.0, `http-types` 0.12.x, `async` 2.2.6, `stm` 2.5.3.1. Source trees for `wai`, `warp`, and `wai-websockets` are in the mori corpus (`mori registry show yesodweb/wai --full`); kiroku-metrics pins `wai-websockets >=3.0 && <3.1` and `websockets >=0.13 && <0.14`, and this plan uses the same bounds.


## Plan of Work

### Milestone 1: Add the missing library read, the cursor codec, and the paired keiro-ops commands

At the end of this milestone `Keiro.Timer` can list scheduled-or-firing timers in fire order with keyset paging, keiro-ops exposes the row encoders the feeds will reuse, and the CLI gains two read-only commands so that every view the feeds will show already has a CLI rendering, which plan 276 turns into the paired HTTP routes. Nothing depends on web libraries, so `cabal test keiro-test --test-options='--match Keiro.Timer'` and `cabal test keiro-ops-test` are the proofs. This milestone does not depend on plan 276 and may be implemented in parallel with it.

In `keiro/src/Keiro/Timer/Schema.hs`, add `PendingTimerFilter { processManagerName :: Maybe Text }` with `anyPendingTimer`, `PendingTimerPageRequest { pageSize :: Int, after :: Maybe (UTCTime, TimerId) }`, `PendingTimerReadError = InvalidPendingTimerPageSize Int`, `PendingTimerPage { timers :: [TimerRow], nextAfter :: Maybe (UTCTime, TimerId) }`, and `findPendingTimers`. Validate `pageSize` in 1 through 500 before touching the database, returning `Left` with the requested size otherwise, exactly as `findDeadTimers` does. The statement selects the same eight columns in the same order as `lookupTimerStmt` and decodes with the existing `timerRowDecoder`; its predicate is `status IN ('scheduled', 'firing')`, an optional exact `process_manager_name` match, and an exclusive keyset comparison `(fire_at, timer_id) > ($2, $3)` when a cursor is supplied, ordered by `fire_at, timer_id` with `LIMIT pageSize + 1`; return at most `pageSize` rows and set `nextAfter` to the last returned row's `(fireAt, timerId)` only when the extra row existed. Document that the page is an observation of current eligibility rather than a snapshot, and that fired, cancelled, and dead rows leave the listing. Re-export everything from `keiro/src/Keiro/Timer.hs` in the "Timer types" group beside the dead-timer reads. In `keiro/test/Main.hs`, inside the `describe "Keiro.Timer"` group, add cases that schedule timers with `runTransaction (scheduleTimerTx request)` at distinct `fireAt` values, then prove ordering, the process-manager filter, boundaries 1 and 500, invalid sizes 0 and 501, multi-page traversal without skips or repeats, that a fired timer (via `claimDueTimer` then `markTimerFired`) disappears, and that the read changes no persisted column (compare every column before and after with test-only SQL as the dead-timer tests do).

Add `keiro-ops/src/Keiro/Ops/Cursor.hs` with `encodeCursor :: [Text] -> Text` (unpadded base64url of the JSON array; add `base64-bytestring` to keiro-ops's dependencies) and `decodeCursor :: Text -> Either Text [Text]`, plus `cursorReader :: Int -> ReadM [Text]` that checks the element count; cursors are opaque to clients, and putting the codec in keiro-ops means the CLI option and the HTTP query value (which plan 276 passes through as the same option) are the same text. In `keiro-ops/src/Keiro/Ops/Workflow.hs`, add `workflowInstanceJson` to the export list. In `keiro-ops/src/Keiro/Ops/Timer.hs`, export `timerJson`, add `PendingList !PendingListOptions` to `Command` with `PendingListOptions { processManagerName :: Maybe Text, limit :: Int, after :: Maybe (UTCTime, TimerId) }`, a `pending list` subcommand (`--process-manager NAME`, `--limit N` default 100 and at most 500, `--after CURSOR` decoded with `cursorReader 2` into an ISO-8601 instant and a UUID), mark it read-only in `isMutation`, and render with headers `timer_id, process_manager, correlation_id, fire_at, status, attempts, payload` and `jsonValue = object ["read_at" .= now, "items" .= map timerJson rows, "next_cursor" .= ...]`, omitting `next_cursor` when absent. In `keiro-ops/src/Keiro/Ops/Projection.hs`, add `projectionGroupStatusJson :: ProjectionGroupStatusV1 -> Value` using the frozen v1 column names as keys (`group_id`, `lifecycle_phase`, `reads_allowed`, `writes_allowed`, `serving_revision_id`, `serving_epoch`, `serving_position_basis` rendered as `append`, `checkpoint`, or `unmanaged`, `serving_applied_position`, `active_run_id`, `candidate_revision_id`, `candidate_rebuild_position`, `candidate_rebuild_head`, `query_models`, `rebuild_started_at`, `last_promoted_at`, `failed_at`, `failure_code`, `failure_detail`), a read-only `Status` command (`keiro-ops projection status`) that calls `listProjectionGroupStatuses` and `storeHeadPosition` and renders `jsonValue = object ["read_at" .= now, "items" .= ..., "visible_store_head" .= ...]`, and export the encoder. Extend `keiro-ops/test/Main.hs`: the projection status test registers a catalog the way the existing "catalog rebuild adoption" test does (`Rebuild.registerProjectionCatalog` with the `opsCatalog` helper) and asserts one item whose `group_id` is `opsGroupId` and whose `serving_position_basis` is `append`; the timer pending test schedules three timers, asserts order, walks `next_cursor` through `--after`, and asserts the omission on the last page; a parser test asserts `timer pending list --after not-a-cursor` fails to parse.

### Milestone 2: The paired poll routes through plan 276's transport

At the end of this milestone the `keiro-ops-http` package built by plan 276 answers `GET /wf/list`, `GET /timer/pending/list`, and `GET /projection/status` with bodies equal to the CLI's `--json` output, the package depends on `websockets` and `wai-websockets`, and no existing library package has gained a web dependency. Before starting, confirm the gate: `ls keiro-ops-http/src/Keiro/Ops/Http` must show `Application.hs`, `Config.hs`, `Cors.hs`, `Route.hs`, and `Server.hs`, and plan 276's Progress must show Milestones 1 through 3 checked; if not, implement plan 276 up to Milestone 3 first and record that in this plan's Decision Log.

Add `websockets >=0.13 && <0.14` and `wai-websockets >=3.0 && <3.1` (plus `async`, `stm`, `containers`, and `time` if plan 276 did not already list them) to the `keiro-ops-http` library's `build-depends`, and `websockets` to its test suite. Add matching `Schema.Dependency` entries to the package's block in `mori.dhall`. In `keiro-ops-http/test/`, add `Test/PollRoutesSpec.hs` that starts the application with `withOpsHttpServer` on port 0 and, with `http-client`, proves: after seeding two workflows with `appendJournalEntry` (the `seedStep` helper in `keiro-ops/test/Main.hs` shows how), `GET /wf/list` returns a JSON array equal to the `jsonValue` of `Keiro.Ops.Workflow.runCommand (opsEnv False store) (List defaults)`; `GET /wf/list?status=running&limit=1` returns one item; after scheduling three timers, `GET /timer/pending/list?limit=2` returns two items and a `next_cursor`, and `GET /timer/pending/list?limit=2&after=<that cursor>` returns the third with no `next_cursor` key, both equal to the CLI command's `jsonValue`; after `registerProjectionCatalog`, `GET /projection/status` returns one item and a numeric `visible_store_head`, equal to the CLI's `jsonValue`. Add a check that `cabal build all --dry-run` (or the build-plan query plan 276 defines for its acceptance criterion 5) shows `websockets` only in `keiro-ops-http`'s closure.

### Milestone 3: The feed engine, the protocol, and the WebSocket endpoint

At the end of this milestone a client can connect to `/ws`, subscribe to any of the three feeds, receive a snapshot, and receive an update after a real workflow completion driven by a real append and wake. Driver unit tests prove diffing, fallback refresh, and overflow ordering without PostgreSQL; end-to-end tests prove the acceptance criteria against a live store.

Write `Keiro.Ops.Http.Protocol` with `ClientFrame = Subscribe FeedName Value | Unsubscribe FeedName | Ping` (the `Value` carries the feed's filter fields for later parsing by the view) and `ServerFrame = Snapshot { feed, sequence, trigger, readAt, items, extra } | Update { feed, sequence, trigger, readAt, changed, removed, extra } | Unsubscribed feed | Pong | ErrorFrame { code, message, feed :: Maybe FeedName } | Goodbye`, with hand-written `FromJSON`/`ToJSON` instances that read and write the `type` tag and the snake_case field names below, and a `FeedName` type with exactly `workflows`, `timers`, and `projection_groups`. The wire shapes are:

```json
{"type": "subscribe", "feed": "workflows", "statuses": ["running", "suspended"], "workflow_name": "approval", "limit": 100}
{"type": "subscribe", "feed": "timers", "process_manager_name": "escalation", "limit": 100}
{"type": "subscribe", "feed": "projection_groups"}
{"type": "unsubscribe", "feed": "workflows"}
{"type": "ping"}
```

```json
{"type": "snapshot", "feed": "workflows", "sequence": 12, "trigger": "subscribe", "read_at": "2026-09-10T02:00:00Z", "items": [{"workflow_name": "approval", "workflow_id": "wf-1", "status": "running", "...": "..."}]}
{"type": "update", "feed": "workflows", "sequence": 13, "trigger": "notify", "read_at": "2026-09-10T02:00:01Z", "changed": [{"workflow_name": "approval", "workflow_id": "wf-1", "status": "completed", "...": "..."}], "removed": [{"workflow_name": "approval", "workflow_id": "wf-9"}]}
{"type": "update", "feed": "projection_groups", "sequence": 3, "trigger": "timeout", "read_at": "...", "changed": [], "removed": [], "visible_store_head": 4211}
{"type": "unsubscribed", "feed": "workflows"}
{"type": "pong"}
{"type": "error", "code": "queue_overflow", "message": "frames were dropped for this feed; re-subscribe or re-read", "feed": "workflows"}
{"type": "goodbye"}
```

Error codes on the socket are `invalid_frame` (undecodable JSON or unknown `type`), `unknown_feed`, `invalid_subscription` (bad filter values, with `message` naming the field), `queue_overflow`, and `read_failed` (the driver's read failed; the driver keeps running and the next successful read publishes normally). `sequence` is per driver and increases by exactly one per published `update`; a `snapshot` carries the sequence of the state it reflects, so a client that sees a gap knows frames were dropped, and the server guarantees an `error` with code `queue_overflow` is delivered before any frame that follows a drop. `trigger` is `subscribe` on snapshots and `notify` or `timeout` on updates, naming the `WakeReason` that caused the re-read. `changed` lists items whose body is new or differs from the previous read, in read order; `removed` lists the key objects of items that were present before and are absent now; an update with both empty is never sent. Items are the same JSON objects the poll routes return: a workflow item is `workflowInstanceJson`, a timer item is `timerJson`, and a projection group item is `projectionGroupStatusJson`, so a client may treat feed items and route items interchangeably.

Write `Keiro.Ops.Http.Views`, the single place that defines what each view reads. Define `Item { key :: Text, keyJson :: Value, body :: Value }` and `View { viewId :: Text, readItems :: Eff '[Store, Error StoreError, IOE] (UTCTime, [Item], Maybe Value) }` where the third component is extra top-level data (`visible_store_head` for projection groups, `Nothing` otherwise). `workflowsView :: Int -> Value -> Either Text View` (the `Int` is the configured `maxItems` bound) parses `statuses` through `statusFromText` (an unknown status is a subscription error naming the field), `workflow_name`, and `limit` (1 through `maxItems`, default 100), reads `listWorkflowInstances` with that page size, and builds items with `key = name <> "\NUL" <> id`, `keyJson = object ["workflow_name" .= name, "workflow_id" .= id]`, `body = workflowInstanceJson row`; `viewId` is the canonical rendering of the parsed parameters so two subscribers with the same filters share one driver. `timersView` parses `process_manager_name` and `limit` and uses `findPendingTimers` with `key = timer id text`, `keyJson = object ["timer_id" .= ...]`, `body = timerJson row`. `projectionGroupsView` takes no parameters and uses `listProjectionGroupStatuses` and `storeHeadPosition` with `key = group id`, `keyJson = object ["group_id" .= ...]`, `body = projectionGroupStatusJson row`, extra `visible_store_head`. Views take no cursor: a feed watches the first page of its listing under its filters, and the paired route pages the rest; the documentation says so.

Write `Keiro.Ops.Http.Feed`. `FeedConfig { fallbackInterval :: NominalDiffTime, minRefreshInterval :: NominalDiffTime, queueCapacity :: Int, idlePingSeconds :: Int, maxConnections :: Int, maxItems :: Int }` with `defaultFeedConfig` (fallback 1 second, minimum refresh 0.1 seconds, capacity 256, ping 30, connections 256, `maxItems` 500). A `Driver` owns one view: a `TVar DriverState { items :: [Item], byKey :: Map Text Value, sequence :: Int64, readAt :: UTCTime, extra :: Maybe Value }`, a `TVar [Subscriber]`, and an `Async ()` loop. A `Subscriber` is `{ queue :: TBQueue ServerFrame, overflowed :: TVar Bool }`. The loop is `runPollLoopWith`-shaped but explicit: read the view; on `Left` publish `ErrorFrame read_failed` to every subscriber; on `Right` compute `changed` and `removed` against `byKey`, and if either is non-empty atomically bump `sequence`, replace the state, and enqueue one `Update` (with the trigger of the wake that caused this pass) into every subscriber's queue; then `waitForWake wake fallbackMicros`, and, if the wake returned before `minRefreshInterval` elapsed since the last read, sleep the remainder so bursts coalesce. Enqueueing into a full `TBQueue` drops the oldest frame and sets `overflowed`. `newDriver :: FeedConfig -> WakeSignal -> IO (Either Text (UTCTime, [Item], Maybe Value)) -> IO Driver` takes the read as a plain `IO` function so tests can inject reads and `neverWake`; the production registry wraps `runStoreIO store view.readItems`. `subscribe :: Driver -> IO Subscriber` atomically registers the subscriber and enqueues a `Snapshot` built from the current state with trigger `subscribe`, so no update published after the snapshot can be missed; `unsubscribe` removes it; `nextFrame :: Subscriber -> STM ServerFrame` returns `ErrorFrame queue_overflow` and clears the flag when it is set, otherwise dequeues; `stopDriver` cancels the loop. `FeedHandle` holds the config, the store, a `WakeSignal` from `wakeSignalFromStore`, a connection counter, and a `TVar (Map Text (Driver, Int))` keyed by `viewId`; `newFeedHandle :: FeedConfig -> KirokuStore -> IO FeedHandle`, `closeFeedHandle` (stops every driver), `withFeedHandle`, `acquireDriver :: FeedHandle -> View -> IO Driver` (create on first use after performing one read so the first snapshot is never empty by accident, then increment), and `releaseDriver` (decrement, stop and remove at zero).

Write `Keiro.Ops.Http.WebSocket` with `feedServerApp :: OpsHttpConfig -> FeedHandle -> WS.ServerApp` and `feedsMiddleware :: OpsHttpConfig -> FeedHandle -> Network.Wai.Middleware` defined as `websocketsOr WS.defaultConnectionOptions (feedServerApp config handle)`. On upgrade: if the request path is not `/ws`, `WS.rejectRequest` with a message naming `/ws`; if the `Origin` header is present and is neither in `config.allowedOrigins` nor equal to the scheme-and-host of the request's own `Host` header, reject with `rejectRequestWith` status 403 and the JSON error body `origin_not_allowed`; if the connection counter is at `maxConnections`, reject with 503 `too_many_connections`; then run `verifyExpectedSchemaSession` on the store pool and, when it reports drift and `config.schemaDrift` is `RefuseOnDrift`, reject with 409 `schema_drift` and `details.drift` (reuse plan 276's rendering); otherwise accept, run under `WS.withPingThread conn idlePingSeconds`, and keep a `TVar (Map FeedName (View, Driver, Subscriber, Async ()))` of active subscriptions. The receive loop decodes each text frame into a `ClientFrame`: `Ping` answers `Pong`; `Subscribe feed params` parses the params with the feed's view parser (an error yields `invalid_subscription`), tears down any existing subscription for that feed, acquires the driver, subscribes, and starts a sender thread that loops `atomically (nextFrame sub) >>= sendFrame conn`; `Unsubscribe feed` cancels the sender, unsubscribes, releases the driver, and sends `Unsubscribed`; an undecodable frame yields `invalid_frame`. A `finally` block cancels every sender, releases every driver, sends `Goodbye`, and decrements the connection counter; a `WS.ConnectionException` from the client closing is treated as a clean end, and `sendFrame` swallows `WS.ConnectionException` so cleanup never rethrows. In `Keiro.Ops.Http`, add `opsApplicationWithFeeds :: OpsHttpConfig -> FeedHandle -> AppHooks -> KirokuStore -> Application` defined as `feedsMiddleware config handle (opsApplication config hooks store)`, and re-export `FeedConfig`, `defaultFeedConfig`, `FeedHandle`, `newFeedHandle`, `closeFeedHandle`, and `withFeedHandle`.

Tests. `test/Test/FeedSpec.hs` (no database): with `neverWake` and an injected read backed by an `IORef [Item]`, a fallback of 50 milliseconds, and capacity 8, subscribing yields a `Snapshot` with the initial items; changing the `IORef` yields exactly one `Update` with trigger `timeout`, the changed item, and `removed` for a deleted key, with `sequence` one higher than the snapshot's; an unchanged read yields no frame within three fallback intervals; with capacity 2 and the sender not draining, publishing five distinct updates then draining yields `ErrorFrame queue_overflow` first, then updates whose sequences are the last two, proving the gap is signaled before any post-drop frame; two subscribers to the same view see the same sequence numbers; a read returning `Left` yields `ErrorFrame read_failed` and the next successful read publishes normally. `test/Test/WebSocketSpec.hs` (real store, `withFreshStore fixture`, `withOpsHttpServer` on port 0 serving `opsApplicationWithFeeds` with `fallbackInterval = 0.2`, every client action wrapped in `System.Timeout.timeout` of 15 seconds): after seeding workflow `approval/wf-1` with `appendJournalEntry ... StepRecorded`, a client sends `subscribe` for `workflows`, receives a `snapshot` whose single item has `status` `running`, then the test appends `WorkflowCompleted` for that workflow (the real append that upserts the row to `completed` in the same transaction and fires the notification), and the client receives an `update` with trigger `notify` whose `changed` item has `status` `completed` within two seconds (IR-27 acceptance 1); a `timers` subscription receives an empty snapshot, then after `scheduleTimerTx` an update containing the timer, then after claiming and marking it fired an update listing its key in `removed`; a `projection_groups` subscription receives an empty snapshot and, after `registerProjectionCatalog`, an update whose changed item has `serving_position_basis` `append` and a numeric `visible_store_head`; `ping` yields `pong`; `subscribe` for `nope` yields `error unknown_feed`; malformed text yields `error invalid_frame`; `unsubscribe` yields `unsubscribed` and no further frames arrive after another append; after quiescence the state a client reconstructs from snapshot plus updates equals, element for element, the array returned by `GET /wf/list` with the same filters (IR-27 acceptance 4); an upgrade with `Origin: http://evil.test` and no configured origins is refused with 403, an upgrade with `Origin` equal to the server's own host is accepted, and with `allowedOrigins = ["http://ui.test"]` that origin is accepted; with `ALTER TABLE keiro.keiro_timers ADD COLUMN feed_test_drift text` executed first, the upgrade is refused with 409 under `RefuseOnDrift` and accepted under `AllowDrift`; closing the client returns the driver registry to empty, proving cleanup. `test/Test/Dialect.hs` defines `Dialect { subscribeFrame :: Value, snapshotType, deltaType, errorType, goodbyeType, pongType :: Text }` and a generic client core that dispatches on `type`, applies `snapshot` then deltas to a key-indexed map, and treats `error` as a signal to re-subscribe; `WebSocketSpec` drives the workflow feed through it configured only with these names (IR-27 acceptance 5), and a structural validator in the same module asserts every received frame is an object with a string `type` in the documented set and the documented required fields per type.

### Milestone 4: Prove degradation when the LISTEN connection dies

At the end of this milestone a test kills kiroku's listener connection mid-feed and proves the feed keeps delivering correct frames on the fallback interval and returns to notification-driven latency after reconnect (IR-27 acceptance 2). Run `cabal test keiro-ops-http-test --test-options='--match degrades'`.

Add to `test/Test/WebSocketSpec.hs` a case with `fallbackInterval = 5` seconds and `minRefreshInterval = 0`. Seed and subscribe as before, receive the snapshot, then run test-only SQL through the store pool, `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'kiroku-listener' AND datname = current_database()`, and assert one row was terminated. Append `WorkflowCompleted` for the seeded workflow. Because the notification for that append is lost, the update must arrive with trigger `timeout` and the correct `completed` status within seven seconds, and no other frame may arrive in between (this is "delayed but never wrong"). Then poll `SELECT count(*) FROM pg_stat_activity WHERE application_name = 'kiroku-listener' AND datname = current_database()` every 100 milliseconds for up to 15 seconds until it is 1 again (kiroku's first reconnect attempt is after one second). Seed a second workflow and append its completion; the corresponding update must arrive with trigger `notify` within one second, which under a five-second fallback can only be the notification path. Finally assert that `GET /wf/list` agrees with the reconstructed client state. Record the observed delays in Surprises & Discoveries.

### Milestone 5: Executable mounting, documentation, bookkeeping, and the ADR

At the end of this milestone the standalone `keiro-ops-http` executable serves the feeds, the protocol is documented with the verbatim caveat, and every bundle and registry the repository maintains reflects the change.

In plan 276's `keiro-ops-http/app/Main.hs`, wrap the application construction in `withFeedHandle defaultFeedConfig store` and serve `opsApplicationWithFeeds` instead of `opsApplication`, so `keiro-ops-http --database-url "$DATABASE_URL" --port 9092` exposes `/ws` beside the command routes; add `--feed-fallback-seconds N` (default 1) as the one feed flag operators are likely to tune. If the executable's `--help` is asserted anywhere in plan 276's tests, update the golden text.

Write `docs/user/live-inspection-feeds.md` as a `Runbook`-typed document with the next handle from `okf id next docs/user --profile mori/user-documentation-profile.dhall DOC`, `tags: [keiro, operations, http, websocket, inspection]`, and a `generated` block. It must contain, verbatim, this caveat: "Push is a best-effort hint. Every feed pairs with a polling fallback. The feed is never the source of truth. A client that misses frames recovers by re-reading, not by trusting the stream was complete." It then documents how to mount the feeds (`opsApplicationWithFeeds` and the executable), the trusted-network authentication posture in the conventions' words, the three paired routes with request and response transcripts copied from test output (pointing at plan 276's runbook for the general route mapping), the WebSocket protocol with the example frames above, the `sequence` and `trigger` semantics, the overflow and reconnect recovery rules (re-subscribe or re-read), the origin check, the `FeedConfig` fields and defaults, which state changes are notification-driven and which are fallback-only (leases, crash records, suspends, lone timer schedules, projection lifecycle changes), the ADR-28 vocabulary (`visible_store_head`, "global position distance" as `visible_store_head` minus `serving_applied_position`), and the `/ws` path as stable for composed mounting. Add a short pointer under "Operating Keiro" in `docs/user/operations.md`. Regenerate `docs/user/index.md` with `okf index docs/user --write` and add a `docs/user/log.md` entry under today's date. Update `docs/capabilities/operational-console.md` (CAP-16): add `Keiro.Ops.Http.Feed` and `Keiro.Ops.Http.WebSocket` to `interface` (plan 276 adds the package and `Keiro.Ops.Http`), evidence entries for the feed tests and the new guide, a sentence stating the feeds are locally validated and unreleased until the next cohort release, and a `docs/capabilities/log.md` entry. Add `[Unreleased]` entries to `CHANGELOG.md`, `keiro/CHANGELOG.md` (`findPendingTimers`), `keiro-ops/CHANGELOG.md` (`Keiro.Ops.Cursor`, exported encoders, `projection status`, `timer pending list`), and `keiro-ops-http/CHANGELOG.md` (the feeds). Plan 276 owns the `cabal.project`, `Justfile`, `README.md`, and release-skill entries for the package; verify they exist and add nothing new.

Create the ADR with the handle from `okf id next docs/adr --profile docs/adr/profile.dhall ADR` (ADR-40 at planning time; plan 276 may take it first, in which case use the next one), file name `00NN-live-inspection-feeds-are-diffed-re-reads-over-supported-poll-paths.md`, frontmatter matching `docs/adr/0039-foreground-timer-resume-uses-expiring-token-ownership.md` (`type`, `title`, `description`, `timestamp`, `docId`, `status: Accepted`, `date`, `originatingPlan: docs/plans/277-publish-websocket-live-feeds-over-keiro-wake.md`). Its Context restates the NOTIFY caveat and the row writes that do not append; its Decision records that every live feed is a shared per-view driver that re-reads a supported library read on `Keiro.Wake` wake or bounded fallback, diffs against its previous read, and publishes items byte-identical to the paired route and CLI rendering; that per-connection queues are bounded with drop-oldest overflow signaled in-band before any later frame and made detectable by per-view sequence numbers; that feeds never decode notification payloads and never issue ad-hoc SQL; that upgrades are gated by the same drift policy and an explicit origin check; that the protocol conforms to `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2` and the packaging to `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`; and that the inspection-surface boundary itself is IR-32's decision. Its Consequences name the fallback interval as the worst-case staleness for non-appending transitions and the shared driver as the reason connection count does not multiply database load. Regenerate the index with `okf index docs/adr --write`, add the `docs/adr/log.md` entry, and run the strict validation. Finally update `docs/improvement-requests/publish-websocket-live-feeds-over-keiro-wake.md`: add an "Implementation evidence" section naming this plan, the test commands, and the observed results, advance `timestamp`, set `status: completed` only when every acceptance criterion has passing evidence, add the `docs/improvement-requests/log.md` entry, and validate the bundle.


## Concrete Steps

All commands run from the repository root inside `nix develop` (or prefix each with `nix develop -c`). PostgreSQL test fixtures are ephemeral; nothing here needs `just postgres-start`.

Milestone 1, after editing `keiro/src/Keiro/Timer/Schema.hs`, `keiro/src/Keiro/Timer.hs`, and `keiro/test/Main.hs`:

```bash
cabal build keiro
cabal test keiro-test --test-options='--match Keiro.Timer' --test-show-details=direct
```

Expected: the new examples (ordering, filter, boundaries, invalid sizes, paging, fired rows leave, read-only) appear and the summary ends with `0 failures`. Then, after the keiro-ops edits:

```bash
cabal test keiro-ops-test --test-show-details=direct
cabal run keiro-ops -- projection --help
cabal run keiro-ops -- timer pending --help
```

Expected: the suite passes, and the two help screens list `status` and `list` respectively.

Gate check before Milestone 2:

```bash
ls keiro-ops-http/src/Keiro/Ops/Http
grep -n "^- \[x\] Milestone [123]" docs/plans/276-serve-the-keiro-ops-surface-over-http.md
```

Expected: `Application.hs Config.hs Cors.hs Route.hs Server.hs` and three checked milestones. Milestone 2:

```bash
cabal build keiro-ops-http
cabal test keiro-ops-http-test --test-options='--match PollRoutes' --test-show-details=direct
grep -l -E 'websockets' */*.cabal
```

Expected: the grep prints only `keiro-ops-http/keiro-ops-http.cabal`. A manual check against a local database:

```bash
just db-create
cabal run keiro-migrate -- up --database-url "host=$PGHOST dbname=keiro"
cabal run keiro-ops-http -- --database-url "host=$PGHOST dbname=keiro" --port 9092 &
curl -s http://127.0.0.1:9092/wf/list | jq
curl -s http://127.0.0.1:9092/projection/status | jq
```

Expected: `[]` and `{"read_at": "...", "items": [], "visible_store_head": 0}` on an empty database.

Milestones 3 and 4:

```bash
cabal test keiro-ops-http-test --test-show-details=direct
cabal test keiro-ops-http-test --test-options='--match degrades' --test-show-details=direct
```

Expected transcript fragment (the exact timestamps differ):

```text
Keiro.Ops.Http.WebSocket
  workflows feed
    sends a snapshot then a notify-driven update after a real completion append [✔]
  degrades to timeout-driven refresh when the LISTEN connection is killed and recovers notify latency after reconnect [✔]
```

Milestone 5, manual observation with the jitsurei database:

```bash
just jitsurei-migrate
cabal run keiro-ops-http -- --database-url "host=$PGHOST dbname=jitsurei" --port 9092 &
cabal repl keiro-ops-http
```

```haskell
import Network.WebSockets
import Data.ByteString.Lazy.Char8 qualified as L
runClient "127.0.0.1" 9092 "/ws" $ \c -> do
  sendTextData c (L.pack "{\"type\":\"subscribe\",\"feed\":\"workflows\"}")
  sequence_ (replicate 3 (receiveData c >>= L.putStrLn))
```

Run `just jitsurei-workflow` in a third shell; the repl prints a `snapshot` frame and then `update` frames as the demo's workflows change. Then the bundle work:

```bash
okf index docs/user --write
okf index docs/adr --write
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce && okf graph docs/user
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce && okf graph docs/capabilities
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
```

Final gates, in this order, each must exit 0:

```bash
nix fmt
nix develop -c just verify
(cd keiro-ops-http && cabal check)
nix flake check
```

Commit after each milestone with a Conventional Commits subject, a body explaining why, and the trailers:

```text
ExecPlan: docs/plans/277-publish-websocket-live-feeds-over-keiro-wake.md
Intention: intention_01m24gb383e91rfr2dp7f2dkdz
```


## Validation and Acceptance

IR-27 acceptance 1 is met when the `keiro-ops-http-test` case "sends a snapshot then a notify-driven update after a real completion append" passes: the client's first frame after `subscribe` is a `snapshot` containing the seeded workflow with `status` `running`, and the next frame, arriving after the test appends `WorkflowCompleted` through `appendJournalEntry`, is an `update` with `trigger` `notify` whose only changed item has `status` `completed`.

Acceptance 2 is met when the "degrades" case passes: after `pg_terminate_backend` on the `kiroku-listener` backend, the completion still surfaces as an `update` with `trigger` `timeout` and the correct status, no frame with a wrong status or a skipped sequence appears, and after the listener backend is visible again in `pg_stat_activity` a fresh completion surfaces as an `update` with `trigger` `notify` within one second under a five-second fallback.

Acceptance 3 is met when the `FeedSpec` overflow case passes: with a capacity of two and five published updates before the subscriber drains, the first frame the subscriber dequeues is `error` with code `queue_overflow`, followed only by the two newest updates, whose `sequence` values show the gap.

Acceptance 4 is met when, in the end-to-end suite, the map a client builds from `snapshot` plus every `update` equals, key for key and value for value, the array returned by `GET /wf/list` for the same filters after the store has been quiet for one fallback interval, and when the Milestone 2 cases prove that array equals the `jsonValue` of `keiro-ops wf list --json` for the same filters. The same agreement holds for the timers feed against `GET /timer/pending/list` and `keiro-ops timer pending list --json`, and for the projection groups feed against `GET /projection/status` and `keiro-ops projection status --json`.

Acceptance 5 is met when the structural validator in `Test/Dialect.hs` accepts every frame received across the suite and the dialect-configured generic client, parameterized only by frame names, reconstructs the workflow state correctly.

Beyond the tests, the Milestone 5 manual observation must show `curl -s http://127.0.0.1:9092/wf/list | jq '.[].status'` changing while `just jitsurei-workflow` runs, and the `cabal repl` snippet must print a `snapshot` frame followed by `update` frames.

The documentation is accepted when `docs/user/live-inspection-feeds.md` contains the verbatim caveat sentence group, at least one copied request and response transcript per route, one example of every frame type, and passes the strict user-documentation validation; the ADR is accepted when strict ADR validation passes and `mori registry concepts --id ADR-NN --json` (after `mori registry reregister` if needed) resolves it in `shinzui/keiro`.


## Idempotence and Recovery

Every step is additive and re-runnable. The library read, the keiro-ops exports and commands, and the feed modules add no migration; if a step fails halfway, fix the code and rerun the same command. Re-running `okf index --write` regenerates the index deterministically; a duplicated `log.md` line must be removed by hand before validation passes. If plan 276 changes `OpsHttpConfig`, `opsApplication`, or the runner after this plan's Milestone 3 starts, rebase `opsApplicationWithFeeds` and the tests onto the new names rather than keeping two entry points, and record the merge in the Decision Log. If a WebSocket test hangs, every client action in the suite must already be wrapped in `System.Timeout.timeout` (15 seconds is the kiroku-metrics precedent) so a failure reports instead of blocking `just verify`; add the wrapper wherever it is missing. The degradation test depends on `pg_terminate_backend` privileges, which the ephemeral server grants to its superuser; if it ever runs against a restricted role it must fail with a clear message from the terminate query rather than silently passing, so assert the terminated row count is one. The executable binds 127.0.0.1 only (plan 276's default); nothing in this plan exposes a listener beyond the host unless the operator changes the bind deliberately, and the documentation says so.


## Interfaces and Dependencies

At the end of Milestone 1, `keiro/src/Keiro/Timer.hs` exports:

```haskell
data PendingTimerFilter = PendingTimerFilter { processManagerName :: !(Maybe Text) }
anyPendingTimer :: PendingTimerFilter
data PendingTimerPageRequest = PendingTimerPageRequest { pageSize :: !Int, after :: !(Maybe (UTCTime, TimerId)) }
data PendingTimerReadError = InvalidPendingTimerPageSize !Int
data PendingTimerPage = PendingTimerPage { timers :: ![TimerRow], nextAfter :: !(Maybe (UTCTime, TimerId)) }
findPendingTimers :: (Store :> es) => PendingTimerFilter -> PendingTimerPageRequest -> Eff es (Either PendingTimerReadError PendingTimerPage)
```

and keiro-ops exports `Keiro.Ops.Cursor.encodeCursor :: [Text] -> Text`, `decodeCursor :: Text -> Either Text [Text]`, `cursorReader :: Int -> ReadM [Text]`, `Keiro.Ops.Workflow.workflowInstanceJson :: WorkflowInstanceRow -> Value`, `Keiro.Ops.Timer.timerJson :: TimerRow -> Value`, `Keiro.Ops.Timer.Command` extended with `PendingList !PendingListOptions`, and `Keiro.Ops.Projection.projectionGroupStatusJson :: ProjectionGroupStatusV1 -> Value` with `Command` extended with `Status`.

Plan 276 supplies, and this plan consumes without change, `Keiro.Ops.Http.Config.OpsHttpConfig { mutations, schemaDrift, allowedOrigins }`, `Keiro.Ops.Http.Application.opsApplication :: OpsHttpConfig -> AppHooks -> KirokuStore -> Application`, `Keiro.Ops.Http.Application.errorResponse`, `Keiro.Ops.Http.Cors.corsMiddleware`, `Keiro.Ops.Http.Server.withOpsHttpServer :: OpsHttpServerConfig -> Application -> (OpsHttpServer -> IO a) -> IO a`, and `Keiro.Migrations.SchemaCheck.verifyExpectedSchemaSession`.

At the end of Milestone 3, `Keiro.Ops.Http.Protocol` exports `FeedName`, `ClientFrame`, `ServerFrame`, `Trigger`, and `SocketErrorCode` with JSON instances; `Keiro.Ops.Http.Views` exports `Item`, `View`, `workflowsView`, `timersView`, `projectionGroupsView`; `Keiro.Ops.Http.Feed` exports:

```haskell
data FeedConfig = FeedConfig { fallbackInterval :: !NominalDiffTime, minRefreshInterval :: !NominalDiffTime, queueCapacity :: !Int, idlePingSeconds :: !Int, maxConnections :: !Int, maxItems :: !Int }
defaultFeedConfig :: FeedConfig
data Driver
data Subscriber
newDriver :: FeedConfig -> WakeSignal -> IO (Either Text (UTCTime, [Item], Maybe Value)) -> IO Driver
stopDriver :: Driver -> IO ()
subscribe :: Driver -> IO Subscriber
unsubscribe :: Driver -> Subscriber -> IO ()
nextFrame :: Subscriber -> STM ServerFrame
data FeedHandle
newFeedHandle :: FeedConfig -> KirokuStore -> IO FeedHandle
closeFeedHandle :: FeedHandle -> IO ()
withFeedHandle :: FeedConfig -> KirokuStore -> (FeedHandle -> IO a) -> IO a
acquireDriver :: FeedHandle -> View -> IO Driver
releaseDriver :: FeedHandle -> View -> IO ()
```

`Keiro.Ops.Http.WebSocket` exports `feedServerApp :: OpsHttpConfig -> FeedHandle -> Network.WebSockets.ServerApp` and `feedsMiddleware :: OpsHttpConfig -> FeedHandle -> Network.Wai.Middleware`; `Keiro.Ops.Http` re-exports the feed types and adds `opsApplicationWithFeeds :: OpsHttpConfig -> FeedHandle -> AppHooks -> KirokuStore -> Network.Wai.Application`.

Libraries: `wai-websockets` for `websocketsOr`, `websockets` for the socket protocol and the test client, `async` and `stm` for drivers and queues, `base64-bytestring` (in keiro-ops) for opaque cursors, `keiro` for the reads and `Keiro.Wake`, `keiro-ops` for the encoders and cursor codec, `keiro-migrations` for the session verifier, `kiroku-store` for `KirokuStore` and `runStoreIO`, `keiro-test-support` for the PostgreSQL fixture, and plan 276's `wai`, `warp`, `http-types`, and `http-client` which are already in the package.


## Revision notes

2026-09-10: Revised on the day of creation after plan 276 (IR-26) was filled in by a concurrent session. The original draft stated a package contract of its own (a `Config`/`Handle` API, hand-written `/workflows`, `/timers`, and `/projection-groups` routes, a construction-time drift check, and a jitsurei `serve` mode) with a fallback of creating the package skeleton itself. Plan 276 derives every route mechanically from the keiro-ops command tree, verifies the schema per request, and ships a standalone executable, so this plan now adds the paired reads as keiro-ops commands (which become routes for free), mounts the feeds onto `opsApplication` through a separate `FeedHandle`, gates upgrades with plan 276's drift policy plus an explicit origin check, serves the feeds from plan 276's executable instead of a jitsurei mode, and makes Milestones 2 through 5 depend on plan 276's Milestones 1 through 3. IR-27 was updated with a `## Planning` section pointing here.
