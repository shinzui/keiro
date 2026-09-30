---
id: 274
slug: expose-process-manager-inspection-reads
title: "Expose process-manager inspection reads"
kind: exec-plan
created_at: 2026-09-10T01:35:31Z
intention: "intention_01m24f92n8e2nv1bh0pzw5h4mw"
master_plan: "docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md"
provenance:
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-30T23:46:10Z
      mode: "update"
      note: "Adopted by MasterPlan 45: settled cursor codec, pending-timer read, hydration source, kiroku listStreams 0.10 gate, migration allocation"
---

# Expose process-manager inspection reads

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change an operator of a keiro application can answer, without writing Haskell
against internals, the questions that matter when a saga stalls: which instances of a given
process manager exist, what one instance last did, what it is waiting for, which timer will
wake it, and which worker process currently owns the shard bucket that delivers its events.
Every answer comes from a supported library read in the package that owns the data, and every
read is also reachable as a read-only `keiro-ops` command that renders the same structured
result as a human table or as JSON. Those commands are the substrate that the requested HTTP
endpoints wrap; the transport itself belongs to the sibling request for an HTTP sister package
(see the Decision Log).

Concretely, after implementation the following works against a migrated database in which a
process manager named `counter-pm` has reacted to events for correlation id `order-1`:

```bash
yourapp ops pm show --name counter-pm --correlation order-1 --json
```

prints one JSON object whose `state` is the manager's journaled state as the runtime's own
rebuild computes it, whose `last_reaction` names the source event the manager reacted to and
lists each dispatched target command with whether it landed, whose `waiting_for` lists the
inputs the manager's state machine accepts next, and whose `pending_timers` lists the timers
that will wake it with their due times. Likewise `yourapp ops pm list --name counter-pm --json`
pages the manager's instances, `keiro-ops timer pending list --manager counter-pm --json` pages
its pending timers, and `keiro-ops shard list --json` and `keiro-ops shard status --subscription
NAME --json` show every sharded subscription, its buckets, each bucket's owner, and how long ago
that owner last renewed its lease.

This plan implements the improvement request
[IR-29](../improvement-requests/expose-process-manager-inspection-reads.md), whose canonical
handle is `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-29`. It is one of the
keiro-side requests of the keiro runtime UI initiative, which needs live, non-polling-storm
inspection surfaces; the Decision Log records how each read here relates to that live-update
requirement. Since 2026-09-30 it is child plan EP-4 of
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md),
whose Integration Points settle the artifacts this plan shares with its siblings; see
"Coordination under MasterPlan 45" in Context and Orientation.


## Progress

Milestone 0 is the validation gate; every later milestone starts only after its go decision is
recorded in the Decision Log.

- [x] (2026-09-10T02:35Z) Plan created; IR-29 gained a "Planning (2026-09-10)" section linking this plan, its timestamp advanced, and the bundle log records the update. Status remains proposed.
- [ ] M0: confirm on the current tree that manager-state appends carry no link to their source event (grep evidence in Surprises), and prove with a red test that the provenance read in Milestone 2 cannot be satisfied from existing history.
- [ ] M0: confirm that `Keiro.ReplayAudit` and the post-append replay witness compare payloads and folded state only, never event metadata, so adding metadata cannot create replay divergence.
- [ ] M0: confirm through Mori that the installed `kiroku-store` (0.9.0.1, the released bound) exposes no stream listing, record the exact `Store` constructor list, and record the Progress state of kiroku plan 88 (which adds `listStreams`) and the newest `kiroku-store` release on Hackage.
- [ ] M0: capture `EXPLAIN (ANALYZE, BUFFERS)` evidence for the per-type and per-instance pending-timer queries against a seeded table, with and without the candidate partial index, and record the go/no-go for the pending-timer index migration (the next migration, 0033 at planning time; its number is allocated by `keiro-migrate new` at implementation).
- [ ] M1: add reaction provenance metadata to the manager-state append in `runProcessManagerOnce` and `advanceDomainProcessManager`, preserving caller metadata.
- [ ] M1: tests prove the stored metadata shape, caller-metadata preservation, unchanged deterministic ids, and duplicate-replay behavior.
- [ ] M2: add `Keiro.ProcessManager.Inspect` with the inspector descriptor, the smart constructors, and `inspectProcessManagerInstance` built on `Keiro.Command.hydrateWithSource` (creating `hydrateWithSource` to plan 278's interface if plan 278 has not landed).
- [ ] M2: rebuild-equivalence test against `hydrateFull`, provenance rendering test, pre-provenance history test, missing-instance test, and dispatched-command status test.
- [ ] M2: add `AppHooks.processManagers` (additive beside plan 278's `aggregates`) and the embedded-only `pm show` command in `keiro-ops` with tests.
- [ ] M3: add `findPendingTimers` to `Keiro.Timer` over the shared `Keiro.Inspection.Cursor` codec (creating that module to plan 275's interface if absent); add the pending-timer index as the next migration only if Milestone 0 recorded a go.
- [ ] M3: tests for ordering, cursor stability, page bounds, fired-timer exclusion, and read-only behavior; `timer pending list` command and `pendingTimerItemJson` with tests.
- [ ] M4: add `shardOwnershipView` and `listShardedSubscriptions` to `Keiro.Subscription.Shard` with heartbeat, lease age, and database-observed time.
- [ ] M4: failover test (owner stops renewing, lease passes, new owner appears without restarting the read); `shard list` command and additive `shard status` fields with tests.
- [ ] M5 (gated on `kiroku-store` 0.10.0.0 on Hackage): bump the `kiroku-store` bound in every package and `mori.dhall` unless plan 278's Milestone 4 already did; add `listProcessManagerInstances` and `pm list` wrapping kiroku's released `listStreams` with the `<category>-` prefix and an opaque `pm-list` cursor.
- [ ] M6: user documentation, capability records, changelogs, IR-29 evidence, ADR distillation, and the full `just verify` gate.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Deliver the library reads in `keiro` (plus one primitive in kiroku-store) and the
  read-only `keiro-ops` commands that render them; do not build HTTP endpoints in this plan.
  Rationale: IR-29 asks for endpoints "in the IR-26 sister package". That package does not
  exist, and IR-26 (`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`) specifies
  that the package serves the read-only subset of the `keiro-ops` command tree mechanically,
  reusing each command's `jsonValue`. Adding the commands here therefore is the endpoint
  substrate; the JSON shapes follow the initiative's conventions (snake_case, `items` plus
  `next_cursor`) so the eventual wrapping changes nothing. Building the HTTP package here would
  be IR-26's scope and would also pre-empt IR-32's boundary decision.
  Date: 2026-09-10

- Decision: Record reaction provenance as metadata on the manager-state event that a process
  manager appends, and build the "what did it last do" part of the instance view on it.
  Rationale: the journal today cannot answer that question. The manager's event id is a
  version-5 UUID derived from the source event id and cannot be inverted; keiro sets no
  causation id (`keiro-core/src/Keiro/Codec.hs` always writes `causationId = Nothing`); and
  the target stream names of dispatched commands come from the pure `handle` function, which
  cannot be re-run without the original input. Metadata is additive: it does not change event
  ids, payloads, the fold, or the frozen replay identity of ADR 24. Pre-existing history has no
  provenance and the view reports that explicitly instead of guessing. Milestone 0 verifies the
  replay audit ignores metadata before this lands.
  Date: 2026-09-10

- Decision: Reconstruct instance state through `Keiro.Command.hydrate`, the exact
  snapshot-seeded-or-full path the command runner uses, with sampled seed verification and
  metrics disabled for the read.
  Rationale: IR-29 requires "the same supported machinery the runtime itself uses to rebuild PM
  state, never a parallel decoder". `hydrate` is already exported for the replay audit. The
  equivalence test compares against `hydrateFull`, the independent full-replay path. Disabling
  the sampled seed witness keeps an inspection read free of background work.
  Date: 2026-09-10

- Decision: Listing instances by type requires a new kiroku-store primitive,
  `listStreamsInCategory`, added and released in kiroku first; keiro's list read wraps it.
  Rationale: kiroku-store 0.8.0.0 has no stream listing (`Kiroku.Store.Effect` has no such
  constructor), and ADR 28 forbids keiro from querying kiroku's private `streams` table. Kiroku's
  own request `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8` already asks for
  exactly this primitive as item 1a. Reading category events to discover instances would cost
  one event scan per page and is rejected. Milestones 1 through 4 do not depend on this.
  Date: 2026-09-10

- Decision: The "waiting condition" is the manager's current control state, the live edges out
  of that state in its keiki transducer (input constructor name and target state, excluding
  replay-only edges), and the instance's pending timers.
  Rationale: a process manager's state machine is the authority on what it accepts next;
  `Keiki.Core.SymTransducer.edgesOut` enumerates that directly and `Keiki.Render.Mermaid.edgeInputName`
  names the input constructor for the guard carrier every keiro stream uses today. Replay-only
  edges cannot fire forward (ADR 2) so they are not something the instance waits for.
  Date: 2026-09-10

- Decision: Pending timers are rows in `keiro_timers` with status `scheduled` or `firing`,
  ordered by `(fire_at, timer_id)`, paged with an exclusive keyset cursor, page size 1 to 100.
  A supporting partial index (migration 0033) is added only if Milestone 0's EXPLAIN evidence
  shows the existing partial index cannot bound per-page cost for a per-type or per-instance
  read.
  Rationale: the operator question is "which timer wakes it next", which is due-time order.
  The bounds and cursor discipline mirror `findDeadTimers`. The repository's rule (plan 270)
  is not to add indexes speculatively, so the index is evidence-gated; the expected finding is
  that the existing `(status, fire_at, process_manager_name)` partial index forces a scan of
  every pending timer of every manager for each page, which a polling UI would multiply.
  Date: 2026-09-10

- Decision: Shard reads are additive. `listShardOwnership` keeps its tuple signature; a new
  detailed read returns heartbeat, expiry, update time, shard count, and a database-observed
  timestamp taken in the same transaction, and a new summary read lists every sharded
  subscription.
  Rationale: lease age must be computed against one clock. Mixing the caller's clock with
  database timestamps written by other hosts misreports liveness; ADR 39 already established
  that no caller clock governs ownership. Existing callers of the tuple read stay compatible.
  Date: 2026-09-10

- Decision: No new NOTIFY channel or feed is added here. The instance view is refreshed by the
  kiroku append notification that `Keiro.Wake` already surfaces; shard and timer state change
  through UPDATEs on keiro tables that fire no notification, so a UI re-reads them on a timeout.
  Every read is sized for that: bounded pages, index-range or primary-key reads, no fan-in
  reads, and cheap change witnesses (stream version in listings, `observed_at` and `updated_at`
  on shard rows) so a client can skip unchanged renders.
  Rationale: IR-27 (`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-27`) owns feeds
  and follows the push-is-a-hint rule; this plan supplies the poll-path reads those feeds
  re-read. Designing the reads to be cheap is what prevents a polling storm.
  Date: 2026-09-10

- Decision: The `pm` command domain is embedded-only, mounted through a new
  `AppHooks.processManagers` hook; `timer pending`, `shard list`, and the extended `shard status`
  are database-only and appear in the standalone binary.
  Rationale: the instance view and listing need the compiled manager definition (event stream,
  codec, transducer, category), which the database cannot supply. This is the capability
  boundary ADR 28 already draws for `timer drain-once` and `wf resume`.
  Date: 2026-09-10

- Decision: Creating this plan does not change IR-29's status. The request stays `proposed`
  until implementation evidence and the release that carries it exist.
  Rationale: repository convention (plans 270 and 272): completion is recorded from evidence.
  Date: 2026-09-10

- Decision: Timer and instance cursors are opaque tokens minted and parsed by
  `Keiro.Inspection.Cursor` (`InspectionCursor`, `CursorError`, `encodeCursor`, `decodeCursor`;
  unpadded base64url over the compact JSON object `{"k":<kind>,"v":<payload>}`), with kind
  `timer-pending` and payload `[fire_at, timer_id]` for pending timers and kind `pm-list` with
  the last returned stream name for instance listing. The textual `<fire_at>/<uuid>` cursor
  and `renderPendingTimerCursor`/`parsePendingTimerCursor` from the 2026-09-10 pending-timer
  decision are withdrawn, and the numeric `afterStreamId` instance cursor is replaced.
  Rationale: [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md)
  makes plan 275's codec the only cursor codec so every keiro inspection read, the CLI, and
  the HTTP layer carry interchangeable tokens; three token formats for one convention is the
  drift the keiro-ui conventions forbid. Whichever plan lands first creates the module to the
  fixed interface.
  Date: 2026-09-30

- Decision: `findPendingTimers` takes `PendingTimerFilter { processManagerName :: Maybe Text,
  correlationId :: Maybe Text }` (both optional), validates page sizes to 1 through 500, and
  returns `TimerInspection` rows with `observedAt` and an opaque `next` cursor. The one
  `keiro-ops` command over it is `timer pending list [--manager NAME] [--correlation ID]
  [--after CURSOR] [--limit N]` rendering `observed_at`, the optional filters, `items` built
  by the exported `pendingTimerItemJson`, and an omitted-on-last-page `next_cursor`. This
  supersedes the 2026-09-10 decision's required manager, 1-to-100 bound, and `timer pending
  --manager` command shape.
  Rationale: MasterPlan 45 assigns this read to this plan and makes plan 277's `timers` feed
  its consumer; the feed needs the unfiltered listing and the instance view needs the narrowed
  one, so one read with optional filters serves both, and one command keeps the CLI, the HTTP
  route (`GET /timer/pending/list`), and the feed three renderings of one handler result
  (ADR 40, condition 2). The 500 bound matches `maxInspectionPageSize` and the feeds'
  `maxItems`. Whichever of plans 274 and 277 lands first creates the read and command to this
  interface.
  Date: 2026-09-30

- Decision: The instance view reconstructs state through `Keiro.Command.hydrateWithSource`
  and reports its `HydrationSource` (`FromSnapshot version` or `FullReplay reason`), rendered
  through plan 278's `hydrationSourceJson` shape, instead of calling `hydrate` and then
  `lookupSnapshotSeed` a second time with a private two-constructor source type.
  Rationale: MasterPlan 45 makes plan 278's source-reporting hydration the one primitive that
  answers "did this state come from a snapshot"; two answers that could disagree is exactly the
  drift an inspection surface must not produce. If plan 278 has not landed, this plan adds
  `hydrateWithSource` to `Keiro.Command` to plan 278's interface.
  Date: 2026-09-30

- Decision: Listing instances wraps kiroku's released `Kiroku.Store.Read.listStreams` with
  the prefix `<category>-`, exactly as plan 278 lists aggregates, and ships only against
  `kiroku-store` 0.10.0.0 or later. This plan implements nothing in the kiroku repository;
  the `listStreamsInCategory` constructor proposed on 2026-09-10 is withdrawn.
  Rationale: kiroku builds the primitive itself under kiroku plan 88 of
  `mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`
  and releases it through kiroku plan 96; a keiro plan editing kiroku would collide with that
  work and a local checkout is not consumer-reachable. MasterPlan 45 records that the release
  child may ship without listing if the kiroku release is late.
  Date: 2026-09-30

- Decision: The pending-timer index migration, if Milestone 0 says go, takes whatever number
  `keiro-migrate new` allocates at implementation (0033 at planning time); this plan reserves
  no number.
  Rationale: plans 275 and 299 also add migrations and both named 0033; MasterPlan 45 makes
  the tool the allocator, and a plan that lands after another rebases its manifest line, lock
  line, expected schema, and test counts on what exists.
  Date: 2026-09-30

- Decision: `AppHooks.processManagers` is an additive `Maybe` field beside plan 278's
  `aggregates`; the domain word `pm` is reserved for this plan and `aggregate` for plan 278.
  Rationale: both plans extend `AppHooks`, `emptyAppHooks`, the standalone-tree and
  embedded-tree tests, `embeddedHooks`, and `jitsureiOpsHooks`; MasterPlan 45 rules that
  whichever lands second extends what exists rather than replacing it.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository is a Cabal multi-package project. The packages that matter here are `keiro`
(the runtime library, `keiro/src/Keiro/…`), `keiro-core` (shared types such as
`Keiro.Stream` and `Keiro.EventStream`, `keiro-core/src/Keiro/…`), `keiro-migrations` (the
embedded SQL migrations under `keiro-migrations/migrations/` with an ordered `manifest`),
`keiro-ops` (the operator command tree, `keiro-ops/src/Keiro/Ops/…`), `keiro-test-support`
(the PostgreSQL test fixture), and `jitsurei` (the example application). Every published
package is at version 0.19.0.0 in the working tree, and 0.19.0.0 is also the newest release
on Hackage (checked 2026-09-30 through
`https://hackage.haskell.org/package/keiro/preferred.json`; when this plan was written on
2026-09-10 both were 0.16.0.0). Recheck both before choosing any bound or version.

A process manager is keiro's stateful coordinator: it reacts to an event from one stream by
appending an event to its own private stream (the "manager stream", also called the journal
here) and, in the same reaction, dispatching commands to target aggregates and scheduling
durable timers. The definition lives in `keiro/src/Keiro/ProcessManager.hs`. The record
`ProcessManager` carries a `name`, a `correlate` function that maps an input event to a
correlation id (the text that identifies one instance), the manager's own `eventStream`, a
`streamFor` function that maps a correlation id to the manager stream handle, the target
aggregate's stream, and the pure `handle` function that decides the reaction. The
`DomainProcessManager` variant differs only in how target commands are handled. One instance
of a process manager is therefore one manager stream, named by convention
`<category>-<correlation id>` when the application builds it with `Keiro.Stream.entityStream`.
The test suite's `counterProcessManager` (in `keiro/test/Main.hs`, search for
`counterProcessManager ::`) instead uses the name `pm:counter-<correlation>`; the inspector
descriptor introduced by this plan makes the mapping between stream name and correlation id
explicit rather than assuming a convention.

Every write a process manager makes carries a deterministic event id derived from
`(manager name, correlation id, source event id, emit index)` by `deterministicCommandId`; the
manager-state append uses emit index `-1` and dispatched commands use `0, 1, …`. Replaying the
same source event therefore produces the same ids, and the store's uniqueness constraint turns
the replay into a benign duplicate. The exported helpers `deterministicCommandIdProbes`,
`firstExistingEventId`, and `eventAlreadyIn` implement the pre-dispatch check; this plan reuses
`firstExistingEventId` to report whether each dispatched command landed. The seed cannot be
inverted, which is why the journal alone cannot say which source event a manager event answers.

Hydration is how keiro rebuilds an aggregate's state: `Keiro.Command.hydrate`
(`keiro/src/Keiro/Command.hs`, exported under "Hydration primitives") looks for a compatible
snapshot in `keiro_snapshots` through `Keiro.Snapshot.lookupSnapshotSeed`, then replays the
manager stream forward from the snapshot version (or from the beginning through `hydrateFull`)
through the keiki transducer, returning `Hydrated { state, registers, streamVersion }`. It
takes a `RunCommandOptions` record whose `seedVerifySampleRate` field schedules a background
verification of one in N snapshot seeds and whose `metrics` and `tracer` fields emit
telemetry; an inspection read passes a copy of `defaultRunCommandOptions` with the sample rate
set to zero and no metrics or tracer. A process manager's `eventStream` may declare
`stateCodec = Nothing` (the example `jitsurei/src/Jitsurei/FulfillmentProcess.hs` does), so
the state has no built-in JSON encoding; the inspector descriptor therefore takes a display
encoder from the application.

The transducer is a keiki `SymTransducer` (`/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs`,
located through `mori registry show shinzui/keiki --full`; the installed keiki is 0.9.1.0 and
keiro's bound is `>=0.9 && <0.10`). Its field `edgesOut :: s -> [Edge phi rs ci co s]` lists the
transitions out of a control state; each `Edge` has a `guard`, a `target` state, and a `mode`
that is `Live` or `ReplayOnly`. For the guard carrier `HsPred rs ci` that every keiro stream
uses today, `Keiki.Render.Mermaid.edgeInputName` (exported; used by `Keiki.Render.Inspector`)
returns the input constructor name a guard matches. Verify both signatures in the keiki
checkout before use; do not rely on this summary alone.

Durable timers are rows of `keiro.keiro_timers` (created in
`keiro-migrations/migrations/0001-keiro-bootstrap.sql`, extended by `0004-keiro-timer-recovery.sql`
and `0032.sql`). A row has `timer_id`, `process_manager_name`, `correlation_id`, `fire_at`,
`payload`, `status` (`scheduled`, `firing`, `fired`, `cancelled`, `dead`), `attempts`,
`fired_event_id`, `last_error`, `created_at`, `updated_at`, and the guarded-resume columns
`resume_claim_token` and `resume_lease_until`. The only index is the partial
`keiro_timers_due_idx ON (status, fire_at, process_manager_name) WHERE status IN ('scheduled','firing')`.
`keiro/src/Keiro/Timer.hs` is the public facade re-exporting `keiro/src/Keiro/Timer/Schema.hs`,
which already provides `TimerRow`, `TimerInspection` (row plus nullable reason),
`lookupTimerInspection`, and the bounded, UUID-paged `findDeadTimers` added by plan 270; the new
pending read mirrors that design. Workflow sleeps also live in this table with
`process_manager_name` equal to the workflow name and `correlation_id` equal to the workflow
id (`keiro/src/Keiro/Workflow/Sleep.hs`), so the pending read serves both.

Shard ownership is the table `keiro.keiro_subscription_shards`
(`keiro-migrations/migrations/0009-keiro-subscription-shards.sql`): one row per
`(subscription_name, bucket)` with `shard_count`, `owner_worker_id`, `lease_expires_at`,
`heartbeat_at`, and `updated_at`. A bucket is a kiroku consumer-group member index; a worker
process owns a bucket by holding a renewable lease. `keiro/src/Keiro/Subscription/Shard/Schema.hs`
holds the SQL statements and `keiro/src/Keiro/Subscription/Shard.hs` the typed reads
`ownershipSnapshotFor` (bucket, owner, expiry) and `shardCountSnapshot`; neither returns
`heartbeat_at`, and nothing lists which subscriptions are sharded. The table is small by
construction (N rows per sharded subscription).

`keiro-ops` renders every command into `OpsResult { headers, rows, jsonValue }`
(`keiro-ops/src/Keiro/Ops/Render.hs`); `Keiro.Ops.isMutation` classifies commands, and
`Keiro.Ops.Embed.AppHooks` mounts commands that need compiled application code
(`workflowResume`, `timerFire`, `replayAudit`, `projectionCatalog`). `keiro-ops/src/Keiro/Ops/Shard.hs`
and `keiro-ops/src/Keiro/Ops/Timer.hs` are the domains this plan extends;
`keiro-ops/src/Keiro/Ops/Workflow.hs` shows the existing keyset-cursor listing pattern
(`--after` cursor, exact filters, bounded limit) and `keiro/src/Keiro/Workflow/Instance.hs`
its library side (`listWorkflowInstances` with a `(workflow_name, workflow_id)` keyset).

Tests: `keiro/test/Main.hs` is one large Hspec suite run through `withMigratedSuite`
(`keiro-test-support/src/Keiro/Test/Postgres.hs`), which starts one ephemeral PostgreSQL,
migrates a template database once, and clones it per example. `withFreshStore` gives a
`KirokuStore`; `withFreshResourceStore` additionally gives a `StoreRunner` that interprets the
`Store`, `Error StoreError`, and `KirokuStoreResource` effects, which process-manager runs need.
The `describe "Keiro.ProcessManager"`, `describe "Keiro.Timer"`, and `describe "Shard lease"`
groups are where new cases belong. `keiro-ops/test/Main.hs` builds a parser from
`Ops.opsCommandTree`, defines `embeddedHooks`, and runs command handlers directly against a
fresh store. `jitsurei/test/Main.hs` has a `describe "Jitsurei process manager"` group that
exercises the example's fulfillment manager end to end.

Documentation bundles are OKF bundles with profiles: `docs/user/` and `docs/guides/`
(profile `mori/user-documentation-profile.dhall`), `docs/capabilities/`
(`docs/capabilities/profile.dhall`; CAP-7 is `process-managers-routers-timers.md`, CAP-16 is
`operational-console.md`), `docs/improvement-requests/` (`mori/improvement-requests-profile.dhall`),
and `docs/adr/` (`docs/adr/profile.dhall`, stable `ADR-N` handles). Each keeps a `log.md`
appended with `okf log add`. Changelogs are the root `CHANGELOG.md` and per-package
`CHANGELOG.md` files under an `[Unreleased]` heading.

The keiro-ui conventions this plan's JSON follows are in the keiro-ui checkout at
`/Users/shinzui/Keikaku/bokuno/keiro-ui/docs/architecture/inspection-api-conventions.md`
(canonical project `mori://shinzui/keiro-ui`, artifact-level URI pending): snake_case field
names, cursor pagination as `items` plus `next_cursor` omitted on the last page, cursors opaque
to clients, and ADR 28's reporting vocabulary.

Relevant local ADRs, summarized:

- [ADR 28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  (`mori://shinzui/keiro/okf/adrs/concepts/ADR-28`): every operator command is a thin adapter
  over an exported operation of the library that owns the state; a missing primitive is added
  to the owning library first; commands needing compiled application values are mounted through
  hooks; timer reads are observations that reserve nothing. This plan's kiroku primitive, hook,
  and read semantics follow it directly.
- [ADR 24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md):
  deterministic ids are frozen replay identity. The provenance metadata leaves ids untouched.
- [ADR 7](../adr/0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md): workflow
  sleeps are `keiro_timers` rows owned by a workflow generation; the pending read lists them
  under the workflow name and must not interpret them.
- [ADR 39](../adr/0039-foreground-timer-resume-uses-expiring-token-ownership.md): timer
  ownership is decided by database time and tokens; reads never claim. The shard read adopts
  the same single-clock discipline.
- [ADR 2](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md):
  replay-only edges never fire forward, so they are excluded from "waiting for".

Cross-repository ADRs, by canonical handle from `mori registry concepts`:
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-1` (events from fan-in reads carry surrogate
stream ids; resolve names on demand, which is why provenance stores the source stream's
surrogate id and the view resolves it with one lookup) and
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-2` (consumer groups are static hash partitions,
which is what a shard bucket is). No ADR records process-manager provenance or inspection
semantics; Milestone 6 distills one.

### Coordination under MasterPlan 45 (2026-09-30)

This plan is child plan EP-4 of
[MasterPlan 45, Expose the keiro inspection surface for the keiro runtime UI](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md),
which coordinates the six keiro-side requests of the keiro runtime UI initiative (IR-26
through IR-31). The MasterPlan's Integration Points section settles every artifact this plan
shares with a sibling; the Decision Log entries dated 2026-09-30 above restate the settled
shape for this plan, and the milestones below are written against it. The facts a novice must
know before starting, as of 2026-09-30:

- The working tree is at 0.19.0.0 and keiro 0.19.0.0 is the newest Hackage release. Recheck
  both through `https://hackage.haskell.org/package/keiro/preferred.json` and
  `git ls-remote --tags origin` before choosing any bound.
- [ADR 40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
  (`mori://shinzui/keiro/okf/adrs/concepts/ADR-40`) now exists. It sanctions the inspection
  surface as a bounded exception to the no-UI stance under five conditions (sister-package
  packaging, ADR 28 discipline on the wire, preview then confirm, push is a hint and poll is
  truth, composition without duplication) and disposes of IR-29 explicitly. The ADR this plan
  distills in Milestone 6 cites ADR 40 as the boundary decision and records only this plan's
  narrower decisions; this plan does not amend `docs/why-keiro.md`. The next free ADR handle
  at MasterPlan time was ADR-49; allocate with `okf id next`, never copy a number.
- Kiroku's listing primitive is `Kiroku.Store.Read.listStreams :: (HasCallStack, Store :> es)
  => Maybe Text -> Maybe StreamName -> Int32 -> Eff es (Vector StreamInfo)`: an exact
  `starts_with` prefix filter, an exclusive stream-name cursor, and stream-name order. It is
  built by kiroku plan 88 under
  `mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`
  and released as `kiroku-store` 0.10.0.0 by kiroku plan 96. The current release is 0.9.0.1,
  which has no listing, and every keiro package pins `kiroku-store >=0.9.0.1 && <0.10`.
  Milestone 5 wraps the released primitive and never edits kiroku.
- The sibling plans are [275](275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md)
  (EP-2, workflow reads; owns `Keiro.Inspection.Cursor`, which this plan's cursors use),
  [276](276-serve-the-keiro-ops-surface-over-http.md) (EP-1, the `keiro-ops-http` transport
  that turns this plan's read-only commands into `GET` routes),
  [277](277-publish-websocket-live-feeds-over-keiro-wake.md) (EP-5, live feeds; its `timers`
  feed consumes this plan's `findPendingTimers` and `pendingTimerItemJson`),
  [278](278-expose-aggregate-inspection-read-apis.md) (EP-3, aggregate reads; owns
  `Keiro.Command.hydrateWithSource`, which Milestone 2 uses, and the `aggregates` hook beside
  this plan's `processManagers` hook),
  [302](302-mount-composed-runtime-inspection-surfaces-under-one-port.md) (EP-6, composed
  mounting), and
  [303](303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md)
  (EP-7, the cohort release that completes IR-29). None is a hard prerequisite of Milestones
  0 through 4; the "whoever lands first creates it to the fixed interface" rule applies to
  the cursor module, `hydrateWithSource`, the pending-timer read, and `cursorReader`.

`docs/why-keiro.md` states keiro has no workflow-engine UI; this plan adds no listener and
does not engage that stance beyond citing ADR 40.


## Plan of Work

### Milestone 0: validation gate

This milestone produces evidence, not features. It ends with a recorded go/no-go for the three
design bets this plan rests on: provenance metadata is the only way to answer "what did it last
do" and is replay-safe; kiroku genuinely lacks a listing primitive; and the pending-timer index
is or is not needed.

Provenance: read `runProcessManagerOnce` and `advanceDomainProcessManager` in
`keiro/src/Keiro/ProcessManager.hs` and confirm the manager append passes
`options & #eventIds .~ [managerEventId]` and nothing else; read
`encodeForAppendWithMetadata` in `keiro-core/src/Keiro/Codec.hs` and confirm
`causationId = Nothing`. Write a temporary test in the `describe "Keiro.ProcessManager"` group
that runs `counterProcessManager` once, reads the manager stream, and asserts the recorded
metadata contains a key `keiro.pm`; it must fail. Keep it: Milestone 1 turns it green. Then
read `keiro/src/Keiro/ReplayAudit.hs` and the `verifyAndSnapshot` witness in
`keiro/src/Keiro/Command.hs` and record in Surprises & Discoveries exactly what each compares;
the expected finding is payloads, folded state, and canonical digests of decoded events, never
`RecordedEvent.metadata`. If either compares metadata, stop and revise the provenance decision
before Milestone 1.

Kiroku: run `mori registry show shinzui/kiroku --full`, open
`kiroku-store/src/Kiroku/Store/Effect.hs` in that checkout, and record the `Store` constructor
list in Surprises & Discoveries. Confirm there is no listing constructor visible to the
released `<0.10` bound, record the Progress state of kiroku's
`docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md` (the
plan that adds `listStreams`) and the `listStreams` signature it specifies, and record the
newest `kiroku-store` release from
`curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json`. Confirm that
`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql` defines the generated `category`
column and `ix_streams_category`. Also record whether `keiro/src/Keiro/Inspection/Cursor.hs`
(plan 275) and `hydrateWithSource` in `keiro/src/Keiro/Command.hs` (plan 278) exist on the
current tree; Milestones 2 and 3 create whichever is absent to the interfaces in Interfaces
and Dependencies.

Timers: add a temporary test that schedules, through `scheduleTimerTx`, ten thousand timers
spread over one hundred manager names and one hundred correlation ids, marks a quarter of them
fired through `markTimerFired`, then runs `EXPLAIN (ANALYZE, BUFFERS)` through a Hasql statement
whose decoder is `D.rowList (D.column (D.nonNullable D.text))` for both query shapes below, once
without and once after creating the candidate index inside the test transaction. Paste the two
plan pairs into Surprises & Discoveries and record the decision. The candidate index is
`CREATE INDEX keiro_timers_pending_owner_idx ON keiro.keiro_timers (process_manager_name, fire_at, timer_id) WHERE status IN ('scheduled', 'firing')`.

```sql
SELECT timer_id FROM keiro.keiro_timers
WHERE process_manager_name = 'pm-07' AND status IN ('scheduled', 'firing')
ORDER BY fire_at, timer_id LIMIT 100;

SELECT timer_id FROM keiro.keiro_timers
WHERE process_manager_name = 'pm-07' AND correlation_id = 'corr-42'
  AND status IN ('scheduled', 'firing')
ORDER BY fire_at, timer_id LIMIT 100;
```

Go criterion for the index: without it, the plan reads buffers proportional to all pending
rows rather than to the manager's rows. Delete the seeding test afterwards; keep nothing that
takes seconds in the suite.

### Milestone 1: reaction provenance on the manager-state append

Scope: the manager-state event appended by a process manager reaction records which source
event it answers, which target commands were dispatched for it (emit index and target stream
name), and which timers it scheduled. Nothing else about the write path changes.

In `keiro/src/Keiro/ProcessManager.hs` add a private function
`reactionProvenance :: Text -> RecordedEvent -> ProcessManagerAction ci targetCi -> (Stream targetCi -> StreamName) -> Value`
that builds the object below, and a private `withProvenanceMetadata :: Value -> RunCommandOptions -> RunCommandOptions`
that merges it into the caller's `metadata` field: when the caller passed an object, insert the
`keiro.pm` key into it (the provenance key wins only for itself; every other caller key is kept);
when the caller passed `Nothing`, use a fresh object. `Keiro.Codec.metadataFor` then stamps
`schemaVersion` as it does today. Apply it to `managerOptions` in both `runProcessManagerOnce`
and `advanceDomainProcessManager`; dispatched target commands and timers are unchanged.

```json
{
  "schemaVersion": 1,
  "keiro.pm": {
    "v": 1,
    "source": { "eventId": "…uuid…", "globalPosition": 4211, "streamId": 17 },
    "dispatched": [ { "i": 0, "target": "counter-target-order-1" } ],
    "timers": [ "…timer uuid…" ]
  }
}
```

The stored key names are camelCase to match keiro's existing stored-metadata key
`schemaVersion`; the read-side JSON that `keiro-ops` renders is snake_case per the conventions.
`streamId` is the source event's surrogate `originalStreamId`, kept as a number so the view can
resolve it with one `lookupStreamName` call (kiroku ADR-1). The target stream name is the
resolved `StreamName` produced by the target event stream's `resolveStreamName`, exactly what the
dispatch uses. Export a public `ReactionProvenance` record and `decodeReactionProvenance :: Value -> Maybe ReactionProvenance`
from the new module of Milestone 2 (the decoder tolerates absence and unknown versions by
returning `Nothing`), and keep the encoder and decoder in the same module so the shape has one
owner; the write side in `Keiro.ProcessManager` imports the encoder from there. If that creates
an import cycle, place both encoder and decoder in a small internal module
`Keiro.ProcessManager.Provenance` (listed under `other-modules`) that both public modules import.

Tests, in the `describe "Keiro.ProcessManager"` group: the Milestone 0 red test turns green and
additionally asserts the decoded provenance equals the expected source id, global position,
surrogate stream id, dispatched list, and timer ids; a caller passing
`metadata = Just (object ["actor" .= "ops"])` sees both `actor` and `keiro.pm` on the stored
manager event; the manager event id and every dispatched id are unchanged (compare with
`deterministicCommandId` directly); replaying the same source event still yields
`PMStateDuplicate` and `PMCommandDuplicate`; and the domain variant records the same shape. Run
the focused suite and the replay-audit group.

### Milestone 2: the instance view

Scope: a new exposed module `Keiro.ProcessManager.Inspect` (add it to `exposed-modules` in
`keiro/keiro.cabal`; if `keiro/src/Keiro.hs` re-exports sibling modules, re-export it there)
that reconstructs one instance's inspection view, plus the embedded-only `pm show` command.

Define the inspector descriptor and its smart constructors exactly as given in Interfaces and
Dependencies. The descriptor carries what the `ProcessManager` record does not: the manager
stream category, the inverse mapping from a stream name to a correlation id, a display encoder
for the state and registers, a label for the control state, and the enabled-input enumeration.
`processManagerInspector` fills the last two from the transducer for `HsPred`-guarded managers
by walking `edgesOut` from the current state, keeping only `mode == Live` edges, and naming each
with `edgeInputName` and `show target`; the default `correlationOf` strips
`categoryText category <> "-"` and returns `Nothing` for any other name.

Implement `inspectProcessManagerInstance` as this sequence, each step through an exported
kiroku or keiro operation: resolve the manager stream name through the descriptor's
`streamFor` and the event stream's `resolveStreamName`; call `Kiroku.Store.Read.getStream` and
return `Right Nothing` when it is absent; call `Keiro.Command.hydrateWithSource` with
`inspectionRunCommandOptions` (a `Left CommandError` propagates, since an unreplayable journal
is exactly what an operator must see), which returns the `Hydrated` value together with a
`HydrationSource` saying whether the state came from a snapshot at a given version or from
full replay and why; read the single event at the hydrated `streamVersion` with
`readStreamForward name (streamVersion - 1) 1` so the reported last reaction is the event that
produced the shown state even if a concurrent append lands mid-read; decode its provenance;
for each dispatched entry compute `deterministicCommandIdProbes name correlationId sourceEventId i`
and call `firstExistingEventId` against the recorded target stream, reporting `applied = True`
when a probe exists; resolve the source stream name with `lookupStreamName`; take the first page
of pending timers through Milestone 3's `findPendingTimers` (filter on this manager and this
correlation id, page size from the request, default 20); and assemble the view with
`hydration` set to the reported `HydrationSource`. Do not call `lookupSnapshotSeed` a second
time and do not define a private source type: `hydrateWithSource` is the one primitive that
answers "did this state come from a snapshot" for every keiro inspection read (plan 278 owns
it; MasterPlan 45, Integration Points). If `hydrateWithSource` does not exist on the tree when
this milestone starts, add it to `keiro/src/Keiro/Command.hs` to the interface in Interfaces
and Dependencies: move the body of `hydrate` into `hydrateWithSource`, returning
`FromSnapshot (seed ^. #streamVersion)` on a seed hit that replays, `FullReplay
(SeededReplayFailed err)` when a seeded replay fails and the full replay is used instead,
`FullReplay (SnapshotMissed reason)` on a miss, and `FullReplay NoStateCodec` when the stream
has no `stateCodec`; redefine `hydrate` as `fmap (fmap fst) . hydrateWithSource` so no existing
signature changes; and add `inspectionRunCommandOptions` as `defaultRunCommandOptions` with
`seedVerifySampleRate = 0`, `metrics = Nothing`, `tracer = Nothing`, and
`verifyReplayOnAppend = False`. Render `hydration` through plan 278's `hydrationSourceJson`
shape, `{"source": "snapshot", "snapshot_version": n}` or `{"source": "full_replay",
"reason": ...}` (creating that encoder beside the type if plan 278 has not landed). The view's
`waitingFor` is `enabledInputs` applied to the hydrated state. When the last event carries no
provenance (history recorded before this change, or a no-op reaction that appended nothing
since), `lastReaction.provenance` is `Nothing` and the JSON says `"provenance": null` with
`"provenance_status": "unavailable"`.

The view exposes only what the manager stream and keiro's own tables hold. It serves no page
of raw journal events: `journal_stream_name`, the last event's id and global position are the
references kiroku's browsing surface (its IR-8 endpoints) takes, which is the delegation IR-29
item 3 asks for.

Tests, in the `describe "Keiro.ProcessManager"` group with `withFreshResourceStore`: run
`counterProcessManager` three times for one correlation id with a snapshot policy of `Every 2`
on a test manager stream so that a snapshot exists, then assert the view's `state` equals the
display encoding of `hydrateFull`'s state and registers and its `streamVersion` equals
`hydrateFull`'s version (the rebuild-equivalence assertion IR-29 acceptance 1 demands), and
that `hydration` is `FromSnapshot` with the snapshot version; repeat without snapshots and
assert `FullReplay (SnapshotMissed SnapshotNotFound)` on a stream with a state codec and
`FullReplay NoStateCodec` on one without.
Assert `lastReaction` names the third source event and lists the dispatched command as applied;
delete the target stream's event with the test's own SQL and assert `applied = False`; append
a manager event without provenance through `runCommand` directly and assert `provenance =
Nothing`; assert an unknown correlation id yields `Nothing`; assert `waitingFor` lists the
live edges out of the current state and excludes a replay-only edge on a test transducer that
has one. Add a jitsurei test in `describe "Jitsurei process manager"` that builds an inspector
for `fulfillmentProcessManager` with category `fulfillment` and inspects an order after
`PaymentApproved`, asserting the dispatched `MarkPacked` command is applied.

`keiro-ops`: add `processManagers :: !(Maybe ProcessManagerInspectors)` to `AppHooks` in
`keiro-ops/src/Keiro/Ops/Embed.hs` (`emptyAppHooks` sets `Nothing`), where
`ProcessManagerInspectors` is a `Map Text SomeProcessManagerInspector` keyed by manager name
and the existential wrapper is defined in `Keiro.ProcessManager.Inspect` so applications do not
need `keiro-ops` to build it. The field is additive and sits beside plan 278's `aggregates ::
!(Maybe AggregateInspectors)` field: if plan 278 has already landed, add this field to the
existing record and extend `emptyAppHooks`, the two tree tests named below, `embeddedHooks`,
and `jitsureiOpsHooks` in `jitsurei/app/Main.hs` rather than replacing anything; if this plan
lands first, plan 278 does the same. The domain word `pm` is reserved for this plan and
`aggregate` for plan 278 (MasterPlan 45, Integration Points). Add
`keiro-ops/src/Keiro/Ops/ProcessManager.hs` with
`Command = Show ShowOptions | List ListOptions` (List is completed in Milestone 5; until then it
is absent from the parser), `pm show --name NAME --correlation ID [--timer-limit N]`, `isMutation`
returning `False`, and a renderer whose `jsonValue` is the view in snake_case. Mount `pm` in
`Keiro.Ops.commandParser` only when the hook is present, exactly like `rebuild`. Update the
"omits code-dependent commands from the standalone tree" and "mounts every code-dependent
command" tests, add a small counter-style manager to `keiro-ops/test/Main.hs` for
`embeddedHooks`, and add a test that runs the manager once, invokes `Show`, and checks
`state`, `last_reaction.source_event.event_id`, `waiting_for`, and `pending_timers` keys.

### Milestone 3: pending timer reads

Scope: `Keiro.Timer` gains a bounded, cursor-paged read of pending timers, optionally
narrowed to one manager and one instance; `keiro-ops timer pending list` renders it; the
pending-timer index lands as the next migration if Milestone 0 said go. This read and this
command are shared with plan 277, whose `timers` feed re-reads them: whichever of the two
plans lands first creates them to exactly the interface in Interfaces and Dependencies, and
the other imports them (MasterPlan 45, Integration Points).

Cursors are opaque tokens from `keiro/src/Keiro/Inspection/Cursor.hs`, the module plan 275
owns: `InspectionCursor` (a newtype over `Text` whose constructor is exported), `CursorError`
(`MalformedCursor` or `CursorKindMismatch expected actual`), `encodeCursor :: (ToJSON payload)
=> Text -> payload -> InspectionCursor`, and `decodeCursor :: (FromJSON payload) => Text ->
InspectionCursor -> Either CursorError payload`; a token is unpadded base64url
(`Data.ByteString.Base64.URL.encodeUnpadded`) over the compact JSON object
`{"k":<kind>,"v":<payload>}`, and `decodeCursor` rejects any other kind. If the module does not
exist on the tree when this milestone starts, create it to exactly that interface (it is
exposed from `keiro`) and add `base64-bytestring >=1.2 && <1.3` to the library
`build-depends` in `keiro/keiro.cabal`; plan 275 finds it already there. The pending-timer
kind is `timer-pending` and the payload is the two-element array `[fire_at, timer_id]`
(aeson's `UTCTime` instance round-trips microseconds exactly and the comparison happens in SQL
at `timestamptz` precision). Do not add a textual cursor format of this plan's own.

In `keiro/src/Keiro/Timer/Schema.hs` add the types and `findPendingTimers` from Interfaces and
Dependencies and re-export them from `keiro/src/Keiro/Timer.hs`. Validate the page size before
any SQL: 1 to 500 succeeds, anything else returns `Left (InvalidPendingTimerPageSize n)`;
decode the cursor with `decodeCursor "timer-pending"` before any SQL and return `Left
(InvalidPendingTimerCursor err)` on failure. One SELECT filters `($1::text IS NULL OR
process_manager_name = $1)`, `($2::text IS NULL OR correlation_id = $2)`, `status IN
('scheduled', 'firing')`, and the exclusive keyset `($3::timestamptz IS NULL OR (fire_at,
timer_id) > ($3, $4))` when a cursor is present, ordered by `fire_at, timer_id`, fetching page
size plus one; the extra row only decides whether `next` is set to a token minted from the
last returned row's `(fireAt, timerId)`. Both filters are optional so that plan 277's feed can
watch every pending timer and the instance view can narrow to one correlation id. Select the
nine columns of `lookupTimerInspection` so the existing inspection decoder is reused, and
select `now()` once in the same transaction as `observedAt`.

If Milestone 0 recorded a go for the index: from the repository root run
`cabal run keiro-migrate -- new --manifest keiro-migrations/migrations/manifest --description "index pending timers by owner"`,
which allocates the next migration number (0033 at planning time; plans 275 and 299 also add
migrations, so take whatever the tool produces and never rename it), write the `CREATE INDEX`
statement from Milestone 0 into the generated `NNNN.sql`, run
`cabal run keiro-migrate -- check keiro-migrations/migrations/manifest`, append the file's
SHA-256 line to `keiro-migrations/migrations.native.lock` in the same format as the `0032.sql`
line, regenerate `keiro-migrations/expected-schema/native/keiro-v18.txt` with
`cabal run keiro-write-expected-schema`, update whatever counts and inventories
`keiro-migrations/test/Main.hs` asserts (commit `c351fceb`, which added `0032.sql`, is the
precedent: inspect it with `git show --stat c351fceb` and `git show c351fceb -- keiro-migrations/test/Main.hs`),
and add a `keiro-migrations/CHANGELOG.md` entry. If another plan's migration has landed since
this plan was written, rebase the manifest line, the lock line, the expected schema, and the
test counts on what exists rather than on the numbers in this text.
The index is additive and reversible (`DROP INDEX`), touches no data, and is maintained on
timer inserts and status changes only; state that cost in the changelog.

Tests, in the `describe "Keiro.Timer"` group: schedule timers for two managers and two
correlation ids with interleaved due times; assert an unfiltered page (`anyPendingTimer`) lists
every pending timer in `(fire_at, timer_id)` order, a per-manager page contains only that
manager's timers in the same order, and a per-instance page contains only that instance; page
with size one across the whole set and assert no duplicates or gaps while quiescent, with
`next` absent on the final page; assert size 0, 501, and negative values return
`InvalidPendingTimerPageSize`, and that the text `not-a-cursor` and a token minted with
`encodeCursor "wf-key" ...` return `InvalidPendingTimerCursor` with `MalformedCursor` and
`CursorKindMismatch` respectively; fire one timer through `claimDueTimer` and
`markTimerFired`, then assert a fresh read excludes it (IR-29 acceptance 3); dead-letter
another and assert it is excluded as well; compare every stored column before and after reads
(reuse the `timerReadSnapshotStmt` approach already in the suite) to prove reads mutate
nothing; and round-trip the cursor codec on the boundary values. Add a case asserting a
workflow sleep armed through `Keiro.Workflow.Sleep` appears under the workflow name.

`keiro-ops`: add `PendingList !PendingListOptions` to `Keiro.Ops.Timer.Command` with the
subcommand `timer pending list [--manager NAME] [--correlation ID] [--after CURSOR] [--limit N]`
(limit defaults to 100 and is at most 500, parsed with `positiveIntReader`; `--after` is parsed
with `cursorReader :: ReadM InspectionCursor` from `keiro-ops/src/Keiro/Ops/Parse.hs`, a reader
that only wraps the option text in `InspectionCursor` and leaves kind validation to the library
read; create `cursorReader` there if no sibling plan has yet), `isMutation` `False`, and a JSON
rendering `{"observed_at": …, "manager": …, "correlation_id": …, "items": […], "next_cursor": "…"}`
where `manager` and `correlation_id` appear only when the filter was given, `next_cursor` is
omitted on the last page, and each item is `pendingTimerItemJson observedAt inspection`, a new
exported function of `Keiro.Ops.Timer` that renders the existing `timerJson` keys extended with
`last_error` and `due_in_seconds` (`fire_at - observed_at`, negative when overdue). Plan 277's
`timers` feed renders its items with the same function so the feed, the CLI, and the
`GET /timer/pending/list` route of plan 276 are three renderings of one handler result. Test it
in the "timer handlers" group, including an unfiltered listing, a manager-filtered listing, and
a two-page traversal through the rendered cursor.

### Milestone 4: shard ownership views

Scope: `Keiro.Subscription.Shard` gains a detailed ownership read with lease age and a list of
every sharded subscription; `keiro-ops shard list` is new and `shard status` gains additive
fields.

In `keiro/src/Keiro/Subscription/Shard/Schema.hs` add `listShardOwnershipDetail` returning
`(bucket, shard_count, owner, lease_expires_at, heartbeat_at, updated_at)` ordered by bucket,
`listShardedSubscriptionSummaries` returning one row per `subscription_name` with the total,
owned-and-unexpired, owned-and-expired, and unowned bucket counts plus the count of distinct
unexpired owners (all computed in SQL against `now()` so one clock decides), and a
`currentDatabaseTime` statement selecting `now()`. In `keiro/src/Keiro/Subscription/Shard.hs`
add `shardOwnershipView` and `listShardedSubscriptions` per Interfaces and Dependencies; each
runs its statements and the time read inside one `runTransaction` so `observedAt` and the rows
are consistent. Add the pure helpers `leaseStateAt` and `leaseAgeAt`. Leave every existing
export untouched.

Tests, in the `describe "Shard lease"` group using explicit timestamps: after
`ensureShardRows` and a claim by worker A, the view reports four buckets owned by A with
`heartbeatAt` equal to the claim time, state `live`, and a lease age equal to
`observedAt - heartbeatAt`; after worker B claims with a `now` past A's expiry (the
"killing an owner" of IR-29 acceptance 2: A simply stops renewing), the same read, without any
reconstruction, shows B as owner; a released bucket shows `unowned` with no age; the summary
lists both a sharded subscription and a second one created in the same test with correct
counts. Add one worker-level case that runs `reconcileShardsOnce` for two workers and reads the
summary between passes.

`keiro-ops`: add `List` to `Keiro.Ops.Shard.Command` rendering
`{"observed_at": …, "items": [{"subscription": …, "shard_counts": [...], "buckets_total": n, "buckets_live": n, "buckets_expired": n, "buckets_unowned": n, "live_owners": n}]}`,
and extend `statusResult` to take the view: `observed_at` at the top level and, per bucket,
`heartbeat_at`, `updated_at`, and `lease_age_seconds` (null when unowned), with `lease_state`
now computed from `observed_at` rather than the process clock. Existing keys keep their names
and meaning. Test both in a new "shard handlers" group.

### Milestone 5: instance listing through a kiroku primitive

Scope: keiro's `listProcessManagerInstances` and `pm list` wrap kiroku's released
stream-listing primitive. This milestone is keiro-only: kiroku builds and releases the
primitive itself (kiroku plan 88 under
`mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`,
released as `kiroku-store` 0.10.0.0 by kiroku plan 96), and this plan edits nothing in the
kiroku repository. The milestone starts only when
`curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json` lists a 0.10
release and that release's `Kiroku.Store.Read` export list contains `listStreams`; record the
released version and the exact signature in Surprises & Discoveries before writing code. The
primitive is `listStreams :: (HasCallStack, Store :> es) => Maybe Text -> Maybe StreamName ->
Int32 -> Eff es (Vector StreamInfo)`: an exact `starts_with` prefix filter on the stream name,
an exclusive stream-name cursor, stream-name order, soft-deleted streams included with
`deletedAt` set. Because kiroku defines a stream's category as the text before its first `-`,
the prefix `<category>-` selects exactly one category (`pm:counter-` does not match
`pm:counters-`). Plan 278 lists aggregates through the same call with the same prefix rule.

Keiro side, only after that release is on Hackage: bump the `kiroku-store` bound to
`>=0.10 && <0.11` in every package that names it (`keiro-core`, `keiro`, `keiro-migrations`,
`keiro-test-support`, `keiro-dsl`, `keiro-ops`, and `keiro-ops-http` if plan 276 has created
it; check with `grep -rn "kiroku-store" --include='*.cabal' .`), update the matching
dependency entries in `mori.dhall`, and rebuild everything; skip the bump if plan 278's
Milestone 4 has already done it. If the release changed `Store` constructors in a way that
breaks a mock interpreter in this repository, fix that first and record it. During development
a local overlay in `cabal.project.local` is acceptable for compiling, but nothing that depends
on it may be committed as released behavior (a local checkout is not consumer-reachable). Add
`listProcessManagerInstances` to `Keiro.ProcessManager.Inspect`: validate `pageSize` (1
through 500, else `Left (InvalidInstancePageSize n)`), decode the cursor with
`decodeCursor "pm-list"` (else `Left (InvalidInstanceCursor err)`), call
`listStreams (Just (categoryText category <> "-")) after (fromIntegral (pageSize + 1))` where
`after` is the stream name carried by the cursor, map each `StreamInfo` through
`correlationOf`, skip names the mapping rejects (a category can host streams the manager does
not own; count and report them as `skipped`), return at most `pageSize` items, and set `next`
to `encodeCursor "pm-list" lastStreamName` only when the extra row existed. Add
`pm list --name NAME [--after CURSOR] [--limit N]` (`--after` through `cursorReader`, limit
default 50 and at most 500) rendering
`{"name": …, "items": [{"correlation_id", "stream_name", "stream_version", "created_at", "deleted_at"}], "skipped": n, "next_cursor": "…"}`
with `next_cursor` omitted on the last page. The list read does no hydration; a client detects
change from `stream_version`. Ordering is stream-name order, which is kiroku's order for this
primitive.

Tests: create five manager instances and one unrelated stream in the same category, list with
page size two, assert complete and stable traversal in name order with `next` absent at the
end and the unrelated stream counted as skipped; assert sizes 0 and 501 fail and a cursor
minted for kind `timer-pending` fails with `InvalidInstanceCursor (CursorKindMismatch _ _)`;
assert `pm list` renders the same page as the library read and a two-page traversal through
the rendered `next_cursor` works. In `keiro-ops/test/Main.hs` extend the standalone-tree test
to confirm `pm list` is embedded-only.

### Milestone 6: documentation, evidence, and distillation

Scope: make the feature findable and record what was proven.

Documentation: add an "Inspecting process managers" section to
`docs/user/process-managers-and-timers.md` (the inspector descriptor, the view's fields and
their meaning, pending timers and cursors, the provenance caveat for old history, and the
cost statement per read); add `pm show`, `pm list`, `timer pending list`, `shard list`, and the
extended `shard status` with copyable JSON transcripts to `docs/user/operations.md`; add a
short "Inspecting an instance" subsection to `docs/guides/process-managers-and-timers.md`
that builds the jitsurei fulfillment inspector and shows one `pm show` transcript; append log
entries with `okf log add docs/user -m "…"` and validate with
`just user-documentation-validate`. Update CAP-7 and CAP-16 in `docs/capabilities/` with the
new interface modules and test evidence and log the change. Add `[Unreleased]` entries to the
root `CHANGELOG.md`, `keiro/CHANGELOG.md`, `keiro-ops/CHANGELOG.md`, and, if the pending-timer index migration landed,
`keiro-migrations/CHANGELOG.md`; the keiro entry states the additive metadata on manager-state
events and its size bound. Update IR-29 with an implementation section that cites this plan and
the passing test names, keep `status: proposed`, and add a log entry with
`okf log add docs/improvement-requests -m "…"`.

ADR distillation: create a new ADR (allocate with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`)
recording that process-manager reactions stamp provenance metadata on the manager-state event,
that inspection reads rebuild state only through `Keiro.Command.hydrate`, that reads are
observations that neither claim nor authorize, and that instance listing is delegated to a
kiroku-owned primitive; add a paragraph to ADR 28 naming the `processManagers` hook and the
new database-only commands; run `okf log add docs/adr …` and the strict validation. Then run the
full gate in Concrete Steps and fill Outcomes & Retrospective.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro` inside the Nix development shell
(`nix develop -c …`) unless stated otherwise. PostgreSQL for tests is ephemeral and started by
the fixture; never point a test at a shared database.

Focused test runs while working (each prints Hspec output ending in a summary line such as
`N examples, 0 failures`):

```bash
nix develop -c cabal test keiro-test --test-options='--match Keiro.ProcessManager' --test-show-details=direct
nix develop -c cabal test keiro-test --test-options='--match Keiro.Timer' --test-show-details=direct
nix develop -c cabal test keiro-test --test-options='--match "Shard lease"' --test-show-details=direct
nix develop -c cabal test keiro-test --test-options='--match Keiro.ReplayAudit' --test-show-details=direct
nix develop -c cabal test keiro-ops-test --test-show-details=direct
nix develop -c cabal test jitsurei-test --test-show-details=direct
```

Migration bookkeeping (Milestone 3, only on a recorded go):

```bash
nix develop -c cabal run keiro-migrate -- new --manifest keiro-migrations/migrations/manifest --description "index pending timers by owner"
nix develop -c cabal run keiro-migrate -- check keiro-migrations/migrations/manifest
shasum -a 256 keiro-migrations/migrations/NNNN.sql   # the file keiro-migrate new created (0033 at planning time)
nix develop -c cabal run keiro-write-expected-schema
nix develop -c cabal test keiro-migrations-test --test-show-details=direct
git diff --stat keiro-migrations
```

The `check` command must report the manifest as valid; the diff must show only the new SQL
file, one manifest line, one lock line, the expected-schema file, the test, and the changelog.

Dependency lookups (before touching any kiroku, keiki, or hasql API):

```bash
mori registry show shinzui/kiroku --full
mori registry show shinzui/keiki --full
mori registry search hasql
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
curl -fsSL https://hackage.haskell.org/package/keiro/preferred.json
git ls-remote --tags origin 'keiro-0.1[6-9]*'
```

Documentation and bundle validation (Milestone 6 and whenever a bundle changes):

```bash
nix develop -c just user-documentation-validate
nix develop -c just capabilities-validate
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
okf id next docs/adr --profile docs/adr/profile.dhall ADR
nix develop -c just adr-validate
git diff --check
```

The full gate before declaring any milestone complete (each must exit zero; `just verify`
builds every package, runs every test suite including the 43 DSL suites, checks generated
corpora, policies, and finally the migration suite):

```bash
nix fmt
nix develop -c just corpus-regen
nix develop -c just verify
nix flake check
```

Commits follow Conventional Commits and carry both trailers:

```text
ExecPlan: docs/plans/274-expose-process-manager-inspection-reads.md
Intention: intention_01m24f92n8e2nv1bh0pzw5h4mw
```

Update the Progress checklist with a timestamp at every stopping point and add discoveries with
evidence as they occur.


## Validation and Acceptance

Acceptance 1 (IR-29): with `counterProcessManager` run three times for `order-1` and a
snapshot present, `inspectProcessManagerInstance` returns a view whose `state` equals the
display encoding of the state `hydrateFull` computes and whose `streamVersion` is 3; the test
named "instance view equals the runtime's own rebuild" passes in both the snapshot and
full-replay variants. The view's `lastReaction.provenance.sourceEventId` equals the third source
event's id and `dispatched` has one entry with `applied = True`. `waitingFor` lists the live
inputs of the current state. Through `keiro-ops`, `pm show --name counter-pm --correlation order-1 --json`
prints an object of this shape:

```json
{
  "name": "counter-pm",
  "correlation_id": "order-1",
  "journal_stream_name": "pm:counter-order-1",
  "stream_version": 3,
  "hydration": { "source": "snapshot", "snapshot_version": 2 },
  "state_label": "Counting",
  "state": { "...": "display encoding" },
  "last_reaction": {
    "event_id": "…", "event_type": "Added", "stream_version": 3, "global_position": 91, "recorded_at": "…",
    "provenance_status": "available",
    "provenance": {
      "source_event_id": "…", "source_global_position": 88, "source_stream_name": "counter-order-1",
      "dispatched_commands": [ { "emit_index": 0, "target_stream_name": "counter-target-order-1", "event_id": "…", "applied": true } ],
      "timer_ids": [ "…" ]
    }
  },
  "waiting_for": [ { "input": "CounterAdded", "target_state": "Counting" } ],
  "pending_timers": { "observed_at": "…", "items": [ { "timer_id": "…", "fire_at": "…", "status": "scheduled", "attempts": 0, "due_in_seconds": 42.0 } ] }
}
```

Acceptance 2: after worker A claims four buckets and worker B claims them once A's lease has
expired, the same `shardOwnershipView` call shows B as owner of every bucket with a fresh
heartbeat; `keiro-ops shard status --subscription orders-shard --json` shows `lease_state`
`live` for B and `keiro-ops shard list --json` shows `buckets_live: 4, live_owners: 1`. No
process restart or cache reset is involved because the read is a plain query.

Acceptance 3: `findPendingTimers` for `counter-pm` lists the scheduled timer with its
`fireAt`; after `claimDueTimer` and `markTimerFired`, a fresh call returns an empty page with
no cursor. `keiro-ops timer pending list --manager counter-pm --json` shows the same before
and after, and the unfiltered `keiro-ops timer pending list --json` lists it among every
pending timer before firing.

Acceptance 4: every new read is implemented with exported operations of the owning library:
`hydrateWithSource`, `getStream`, `readStreamForward`, `lookupStreamName`,
`firstExistingEventId`, `listStreams` (kiroku, Milestone 5), `encodeCursor` and
`decodeCursor` (`Keiro.Inspection.Cursor`), and keiro's own timer and shard statements in the
modules that own those tables. A reviewer confirms by inspection that `keiro-ops` contains no
SQL, `Keiro.ProcessManager.Inspect` contains no Hasql statement, and nothing in keiro imports
`Kiroku.Store.SQL`.

Acceptance 5: for each of `pm show`, `pm list`, `timer pending list`, `shard list`, and `shard status`,
the `keiro-ops` test invokes the handler and compares its `jsonValue` field by field against
the library read's result for the same database state.

Performance evidence to record: the Milestone 0 EXPLAIN pairs; a statement in Surprises that
`inspectProcessManagerInstance` performs one hydration (the same cost as a command against
the instance), one stream lookup, one snapshot-seed lookup, one single-event read, `k`
existence probes where `k` is the dispatched-command count, one stream-name lookup, and one
pending-timer page, and no category or `$all` read; that the listing
read performs one index-range page and no hydration; that the shard reads are one primary-key
range read and one aggregate over a table of `N` rows per sharded subscription; and that the
manager-state append grows by the provenance object only (measure one recorded event's
`metadata` byte length in a test and assert it is below one kilobyte for a reaction with ten
dispatched commands). Run `cabal bench keiro-bench --benchmark-options="-p command --time-mode wall --baseline bench/baseline-command.csv --fail-if-slower 25"`
once after Milestone 1 to confirm the plain command path, which shares `runCommandWithSql`, is
unchanged.


## Idempotence and Recovery

Every read is a query and may be repeated freely; tests clone a fresh database per example. The
provenance metadata is written only by new reactions; existing events are never rewritten, and
the view treats missing provenance as a first-class state, so rolling the library back leaves
no inconsistency. The pending-timer index migration (the next number at implementation, 0033
at planning time) is a single additive index; if it must be withdrawn, add a new forward
migration that drops it rather than editing the shipped file, per
`keiro-migrations/README.md`.

Cursor pagination is observational: a page reflects rows eligible at the time of that query,
a cursor means "strictly after this key under the same filters", and a client that changes
filters restarts without a cursor. Concurrent timer firing or shard failover between pages is
expected and never causes a duplicate key within one traversal.

If the kiroku release for Milestone 5 is delayed, Milestones 1 through 4 and 6 complete and
ship on their own; `pm list` stays absent from the parser and IR-29 records item 1a as pending
with the kiroku plan reference. Never commit a `cabal.project.local` overlay or a
`source-repository-package` pointing at a local checkout.

If `just verify` fails because of concurrent Cabal builds sharing a workspace (recorded in
plan 270), rerun the failing step serially or with a private `--builddir` before treating the
failure as evidence.


## Interfaces and Dependencies

All new keiro definitions use the repository's strict records with `Generic`, `Eq`, and `Show`
deriving, `OverloadedLabels` access, and the existing `Store` effect. `Eff es` computations
propagate store failures exactly as the surrounding module does.

`Keiro.ProcessManager.Inspect` (new, exposed):

```haskell
data ProcessManagerInspector phi rs s ci co = ProcessManagerInspector
  { name :: !Text,
    eventStream :: !(ValidatedEventStream phi rs s ci co),
    streamFor :: !(Text -> Stream (EventStream phi rs s ci co)),
    category :: !(StreamCategory (EventStream phi rs s ci co)),
    correlationOf :: !(StreamName -> Maybe Text),
    displayState :: !(s -> RegFile rs -> Value),
    stateLabel :: !(s -> Text),
    enabledInputs :: !(s -> [EnabledInput])
  }

data EnabledInput = EnabledInput
  { input :: !(Maybe Text),   -- input constructor the guard matches, when derivable
    targetState :: !Text
  }

processManagerInspector ::
  (Show s) =>
  ProcessManager input (HsPred rs ci) rs s ci co tPhi tRs tS tCi tCo ->
  StreamCategory (EventStream (HsPred rs ci) rs s ci co) ->
  (s -> RegFile rs -> Value) ->
  ProcessManagerInspector (HsPred rs ci) rs s ci co

domainProcessManagerInspector ::
  (Show s) =>
  DomainProcessManager input (HsPred rs ci) rs s ci co tPhi tRs tS tCi tCo rej noOp ->
  StreamCategory (EventStream (HsPred rs ci) rs s ci co) ->
  (s -> RegFile rs -> Value) ->
  ProcessManagerInspector (HsPred rs ci) rs s ci co

data SomeProcessManagerInspector
  = forall phi rs s ci co.
    (BoolAlg phi (RegFile rs, ci), Eq co) =>
    SomeProcessManagerInspector (ProcessManagerInspector phi rs s ci co)

type ProcessManagerInspectors = Map Text SomeProcessManagerInspector

data ReactionProvenance = ReactionProvenance
  { sourceEventId :: !EventId,
    sourceGlobalPosition :: !GlobalPosition,
    sourceStreamId :: !StreamId,
    dispatched :: ![(Int, StreamName)],   -- emit index, resolved target stream
    timerIds :: ![TimerId]
  }

encodeReactionProvenance :: ReactionProvenance -> Value
decodeReactionProvenance :: Value -> Maybe ReactionProvenance   -- Nothing when absent or unknown version

-- HydrationSource is imported from Keiro.Command (plan 278's interface, reproduced below);
-- this module defines no source type of its own.

data DispatchedCommandStatus = DispatchedCommandStatus
  { emitIndex :: !Int, targetStreamName :: !StreamName, eventId :: !EventId, applied :: !Bool }

data LastReaction = LastReaction
  { eventId :: !EventId, eventType :: !EventType, streamVersion :: !StreamVersion,
    globalPosition :: !GlobalPosition, recordedAt :: !UTCTime,
    provenance :: !(Maybe ReactionProvenance),
    sourceStreamName :: !(Maybe StreamName),
    dispatchedCommands :: ![DispatchedCommandStatus] }

data ProcessManagerInstanceView = ProcessManagerInstanceView
  { name :: !Text, correlationId :: !Text, journalStreamName :: !StreamName,
    streamVersion :: !StreamVersion, hydration :: !HydrationSource,
    stateLabel :: !Text, state :: !Value,
    lastReaction :: !(Maybe LastReaction),
    waitingFor :: ![EnabledInput],
    pendingTimers :: !PendingTimerPage }

data InstanceViewRequest = InstanceViewRequest { timerPageSize :: !Int }   -- default 20

inspectProcessManagerInstance ::
  (IOE :> es, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  ProcessManagerInspector phi rs s ci co -> InstanceViewRequest -> Text ->
  Eff es (Either CommandError (Maybe ProcessManagerInstanceView))

data InstanceListRequest = InstanceListRequest { pageSize :: !Int, after :: !(Maybe InspectionCursor) }
data InstanceSummary = InstanceSummary
  { correlationId :: !Text, streamName :: !StreamName, streamVersion :: !StreamVersion,
    createdAt :: !UTCTime, deletedAt :: !(Maybe UTCTime) }
data InstancePage = InstancePage { items :: ![InstanceSummary], skipped :: !Int, next :: !(Maybe InspectionCursor) }
data InstanceListError = InvalidInstancePageSize !Int | InvalidInstanceCursor !CursorError
instanceListCursorKind :: Text   -- "pm-list"; payload is the last returned stream name

listProcessManagerInstances ::
  (Store :> es) =>
  ProcessManagerInspector phi rs s ci co -> InstanceListRequest ->
  Eff es (Either InstanceListError InstancePage)
```

Confirm the exact constraint set `Keiro.Command.hydrate` demands and copy it onto
`inspectProcessManagerInstance` and the existential; the list above is the expected minimum.

`Keiro.Command` (owned by plan 278; created here to this exact interface if absent):

```haskell
data HydrationSource
  = FromSnapshot !StreamVersion
  | FullReplay !FullReplayReason

data FullReplayReason
  = NoStateCodec
  | SnapshotMissed !SnapshotMissReason
  | SeededReplayFailed !CommandError

hydrateWithSource ::
  (HasCallStack, IOE :> es, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  Eff es (Either CommandError (Hydrated rs s, HydrationSource))

-- defaultRunCommandOptions with seedVerifySampleRate = 0, metrics = Nothing,
-- tracer = Nothing, verifyReplayOnAppend = False
inspectionRunCommandOptions :: RunCommandOptions
```

`Keiro.Inspection.Cursor` (owned by plan 275; created here to this exact interface if
absent, together with `base64-bytestring >=1.2 && <1.3` in `keiro/keiro.cabal`):

```haskell
newtype InspectionCursor = InspectionCursor { cursorText :: Text }
  deriving stock (Eq, Show, Generic)

data CursorError
  = MalformedCursor !Text            -- not base64url JSON of the expected shape
  | CursorKindMismatch !Text !Text   -- expected kind, actual kind
  deriving stock (Eq, Show, Generic)

encodeCursor :: (ToJSON payload) => Text -> payload -> InspectionCursor
decodeCursor :: (FromJSON payload) => Text -> InspectionCursor -> Either CursorError payload
```

`Keiro.Timer` (re-exported from `Keiro.Timer.Schema`; shared with plan 277, whichever lands
first creates it to this interface):

```haskell
data PendingTimerFilter = PendingTimerFilter
  { processManagerName :: !(Maybe Text), correlationId :: !(Maybe Text) }

anyPendingTimer :: PendingTimerFilter   -- both Nothing

data PendingTimerPageRequest = PendingTimerPageRequest
  { pageSize :: !Int, after :: !(Maybe InspectionCursor) }

data PendingTimerReadError
  = InvalidPendingTimerPageSize !Int
  | InvalidPendingTimerCursor !CursorError

data PendingTimerPage = PendingTimerPage
  { observedAt :: !UTCTime, timers :: ![TimerInspection], next :: !(Maybe InspectionCursor) }

pendingTimerStatuses :: NonEmpty TimerStatus   -- Scheduled :| [Firing]
pendingTimerCursorKind :: Text                 -- "timer-pending"; payload [fire_at, timer_id]

findPendingTimers ::
  (Store :> es) =>
  PendingTimerFilter -> PendingTimerPageRequest ->
  Eff es (Either PendingTimerReadError PendingTimerPage)
```

`Keiro.Subscription.Shard`:

```haskell
data LeaseState = LeaseLive | LeaseExpired | LeaseUnowned | LeaseInvalid

data ShardOwnershipRow = ShardOwnershipRow
  { bucket :: !Int, shardCount :: !Int, owner :: !(Maybe WorkerId),
    leaseExpiresAt :: !(Maybe UTCTime), heartbeatAt :: !(Maybe UTCTime), updatedAt :: !UTCTime }

data ShardOwnershipView = ShardOwnershipView
  { subscriptionName :: !SubscriptionName, observedAt :: !UTCTime, buckets :: ![ShardOwnershipRow] }

data ShardedSubscriptionSummary = ShardedSubscriptionSummary
  { subscriptionName :: !SubscriptionName, shardCounts :: ![(Int, Int)],
    bucketsTotal :: !Int, bucketsLive :: !Int, bucketsExpired :: !Int, bucketsUnowned :: !Int,
    liveOwners :: !Int }

data ShardedSubscriptionList = ShardedSubscriptionList
  { observedAt :: !UTCTime, subscriptions :: ![ShardedSubscriptionSummary] }

leaseStateAt :: UTCTime -> ShardOwnershipRow -> LeaseState
leaseAgeAt :: UTCTime -> ShardOwnershipRow -> Maybe NominalDiffTime   -- observedAt minus heartbeatAt

shardOwnershipView :: (Store :> es) => SubscriptionName -> Eff es ShardOwnershipView
listShardedSubscriptions :: (Store :> es) => Eff es ShardedSubscriptionList
```

kiroku-store (Milestone 5; consumed from the release kiroku plan 88 produces, never written
here; verify the exact export against the released package before use):

```haskell
-- Kiroku.Store.Read, kiroku-store 0.10.0.0 or later
listStreams ::
  (HasCallStack, Store :> es) =>
  Maybe Text ->        -- exact starts_with prefix filter; keiro passes Just (categoryText category <> "-")
  Maybe StreamName ->  -- exclusive cursor: streams whose name sorts after this one
  Int32 ->             -- limit; keiro passes pageSize + 1
  Eff es (Vector StreamInfo)
-- StreamInfo { id, name, version, createdAt, deletedAt, truncateBefore } unchanged from 0.9
```

`keiro-ops`:

```haskell
-- Keiro.Ops.Embed (additive; plan 278 adds `aggregates :: !(Maybe AggregateInspectors)` beside it)
data AppHooks = AppHooks
  { workflowResume :: !(Maybe ResumeHook),
    timerFire :: !(Maybe TimerFire),
    replayAudit :: !(Maybe OpsAuditConfig),
    projectionCatalog :: !(Maybe ProjectionCatalogOperations),
    processManagers :: !(Maybe ProcessManagerInspectors)
  }

-- Keiro.Ops.Parse (shared; created by whichever sibling plan first needs it)
cursorReader :: ReadM InspectionCursor      -- wraps the option text; the library read validates the kind

-- Keiro.Ops.ProcessManager (new)
data Command = Show !ShowOptions | List !ListOptions
data ShowOptions = ShowOptions { name :: !Text, correlationId :: !Text, timerLimit :: !Int }
data ListOptions = ListOptions { name :: !Text, after :: !(Maybe InspectionCursor), limit :: !Int }
commandParser :: Parser Command             -- List is added to the parser in Milestone 5
isMutation :: Command -> Bool                -- always False
runCommand :: ProcessManagerInspectors -> OpsEnv -> Command -> IO OpsOutcome

-- Keiro.Ops.Timer (the pending listing is shared with plan 277)
data Command = StuckList !StuckListOptions | PendingList !PendingListOptions | Requeue !TimerId | Cancel !TimerId | DeadLetter !TimerId !Text | DrainOnce !DrainOptions
data PendingListOptions = PendingListOptions { manager :: !(Maybe Text), correlation :: !(Maybe Text), after :: !(Maybe InspectionCursor), limit :: !Int }
pendingTimerItemJson :: UTCTime -> TimerInspection -> Value   -- timerJson keys plus last_error and due_in_seconds

-- Keiro.Ops.Shard
data Command = List | Status !Text | Relinquish !Text !WorkerId
```

Dependencies: no new library enters any package except `base64-bytestring >=1.2 && <1.3` in
`keiro`, added by whichever plan creates `Keiro.Inspection.Cursor` (it is already in the
build closure at 1.2.1.0). `keiro` already depends on `keiki`, `aeson`, `hasql`, `uuid`, and
`time`; `keiro-ops` already depends on `containers`, `optparse-applicative`, and `aeson`. The
`kiroku-store` bound changes only in Milestone 5, from `>=0.9.0.1 && <0.10` to
`>=0.10 && <0.11`, once the release that carries `listStreams` is on Hackage. Read every
dependency API from its Mori-located source before use, and verify released versions against
Hackage and upstream tags before choosing bounds.


## Revision notes

2026-09-30: Adopted as child plan EP-4 of
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md),
which coordinates the six keiro-side requests of the keiro runtime UI initiative and settles
the artifacts this plan shared, inconsistently, with plans 275, 277, and 278 written the same
day by parallel sessions. Changes, each recorded as a dated Decision Log entry: the
`master_plan` frontmatter field; a "Coordination under MasterPlan 45" subsection replacing the
sibling-orientation paragraph; timer and instance cursors are opaque `Keiro.Inspection.Cursor`
tokens (kinds `timer-pending` and `pm-list`) instead of a textual timer cursor and a numeric
stream-id cursor; `findPendingTimers` takes two optional filters, pages 1 through 500, and is
shared with plan 277's feed through the single `timer pending list` command and the exported
`pendingTimerItemJson`; the instance view uses plan 278's `hydrateWithSource` and its
`HydrationSource` instead of a private source type and a second snapshot lookup; Milestone 5
no longer implements anything in kiroku and instead wraps kiroku's released `listStreams`
(kiroku plan 88, `kiroku-store` 0.10.0.0) with the `<category>-` prefix, gated on the Hackage
release, with the bound bump shared with plan 278; the pending-timer index migration takes
whatever number `keiro-migrate new` allocates (0033 was true on 2026-09-10 and is not a
reservation); `AppHooks.processManagers` coexists additively with plan 278's `aggregates`; the
version facts (0.19.0.0 in the tree and on Hackage) and the existence of ADR 40 are
recorded. Nothing has been implemented; the Progress checklist reflects the revised
milestones.
