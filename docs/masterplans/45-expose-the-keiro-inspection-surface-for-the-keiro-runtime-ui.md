---
id: 45
slug: expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui
title: "Expose the keiro inspection surface for the keiro runtime UI"
kind: master-plan
created_at: 2026-09-30T23:35:10Z
intention: "intention_01m3taqnt3e6tvd4shm6sfy3a4"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T23:35:10Z
---

# Expose the keiro inspection surface for the keiro runtime UI

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Keiro is a Haskell event-sourcing framework and workflow engine layered on kiroku (an
append-only PostgreSQL event store), shibuya (supervised queue processing), and pgmq-hs (a
PostgreSQL work-queue client). Its operator surface today is `keiro-ops`
(`keiro-ops/src/Keiro/Ops.hs`): an embeddable command tree and a standalone command-line
console whose every command wraps a supported library operation, renders into one typed
envelope, previews a mutation before performing it, and refuses to act when the live database
schema disagrees with the binary. A browser cannot invoke a command line, and several of the
things an operator most needs to see, such as an aggregate's current state, a process
manager's last reaction and pending timers, or a workflow ledger paged by status, have no
supported read at all.

The keiro runtime UI initiative (`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`)
audited keiro in September 2026 and filed seven improvement requests in
`docs/improvement-requests/`, IR-26 through IR-32. IR-32 asked keiro to decide, in an ADR,
whether an inspection surface is compatible with its published no-UI stance; it is complete
([ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
sanctions the surface under five conditions). The other six are accepted and unimplemented.
Five of them were planned on 2026-09-10 by five parallel sessions as ExecPlans 274 through
278, none of which has started, and each of which contains its own guess about the shared
pieces: the cursor codec, the pending-timer read, the migration number, the kiroku listing
primitive and its release, the package version, and the OKF handles. IR-31, composed mounting,
has no plan. This MasterPlan coordinates all six requests into one cohort, settles the shared
decisions, adds the two children no existing plan covers, and carries the cohort to a release
that lets the requests be marked complete.

After the initiative is complete, an application built on keiro can mount one WAI
`Application` from the new sister package `keiro-ops-http` next to its other routes, or run
the standalone `keiro-ops-http` executable against a database, and a browser can then: call
every read-only `keiro-ops` command as a `GET` whose body equals the CLI's `--json` output;
page workflow instances by a documented status vocabulary with opaque cursors and open one
instance's journal, steps, children, and awakeables page by page; list the aggregates of a
category, see one aggregate's folded state exactly as the command path would fold it, and see
whether its snapshot is present, current, or stale; list a process manager's instances, see
what one instance last did and what it is waiting for, and see its pending timers and the shard
that delivers its events; subscribe over one WebSocket connection to live feeds of workflow
instances, pending timers, and projection group status, each paired with an authoritative poll
route; and reach all of that, together with kiroku's, shibuya's, and pgmq's inspection
surfaces, on one process and one port under stable path prefixes. Mutations stay disabled
unless the host enables them and every mutation that is enabled previews before it executes.
No existing keiro package gains a web dependency.

In scope: the library reads beneath every requested view (in `keiro`), the read-only
`keiro-ops` commands that render them, the `keiro-ops-http` package with its transport,
feeds, and composition, the documentation, capability records, and ADRs that record the
decisions, and the lockstep release that publishes the package set and completes IR-26 through
IR-31. Explicitly out of scope: authentication, authorization, TLS, and rate limiting (the
recorded posture of every inspection server in the stack is a trusted network or an
authenticating reverse proxy, restated in each child's documentation); any dashboard, metrics
endpoint, time-series retention, or trace view (ADR-40 keeps those in OpenTelemetry); the
browser application itself, which `mori://shinzui/keiro-ui` owns; any endpoint that re-serves
or reshapes a lower layer's data (raw stream and event browsing stays kiroku's); and any
implementation work in kiroku, shibuya, or pgmq-hs. Those three repositories are planning
their own halves of the initiative in parallel: kiroku's cohort is
`mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`
(it releases the `listStreams` primitive keiro's two listing milestones wait for as
`kiroku-store` 0.10.0.0), shibuya's is
`mori://shinzui/shibuya/masterplans/7-browser-ready-processor-inspection-and-control-surface`
(a skeleton at the time of writing), and pgmq-hs's requests IR-1 through IR-3 in that
repository are proposed and unplanned. Keiro's plans consume released artifacts from those
repositories and never implement inside them.


## Decomposition Strategy

The initiative decomposes by functional concern into seven child plans in three waves. Five
of the children already exist as plans 274, 275, 276, 277, and 278 and are adopted rather
than rewritten: each is a complete, self-contained, reviewed specification of one request
(their `reviews` are recorded on the requests, not on the plans, which carry no provenance
block because they predate it), and rewriting three hundred kilobytes of plan text to change
a dozen shared decisions would destroy more than it adds. Instead this MasterPlan settles the
shared decisions in Integration Points, and each adopted plan carries a `master_plan`
frontmatter field, a dated coordination note, and the targeted edits that make its text agree
with the settled decisions. Two new children cover what no existing plan does: composed
mounting (IR-31) and the cohort release that completes the requests.

Wave one is the four independent foundations, which touch disjoint modules and can be
implemented in parallel by different sessions. EP-1 (plan 276) builds the transport package;
it depends on nothing because its endpoints are derived from the `keiro-ops` parser rather
than from a route list, so commands the other children add become routes the moment they
merge. EP-2 (plan 275) adds the workflow reads and owns the two artifacts every other read
plan needs, the opaque cursor codec `Keiro.Inspection.Cursor` and the `Keiro.Inspection`
namespace, because it is the plan with the most readers and the smallest hook surface. EP-3
(plan 278) adds the aggregate reads and owns the source-reporting hydration primitive in
`Keiro.Command`, which EP-4 also needs. EP-4 (plan 274) adds the process-manager reads and
owns the pending-timer read in `Keiro.Timer`, which EP-5 also needs. Each of EP-2, EP-3, and
EP-4 produces a demonstrable behavior through `keiro-ops` commands without any of the others
and without the transport.

Wave two is the two children that build on the transport. EP-5 (plan 277) mounts WebSocket
feeds onto the application EP-1 builds and hard-depends on EP-1's first three milestones; its
own first milestone (the paired `keiro-ops` commands) is independent. EP-6 (plan 302)
composes keiro's surface with kiroku's, shibuya's, and pgmq's under path prefixes and
hard-depends on EP-1 because the thing it mounts must exist; it soft-depends on EP-5 so the
composition test can prove keiro's own WebSocket endpoint works behind a prefix.

Wave three is EP-7 (plan 303), the release: it dates the changelogs, verifies the two
kiroku-gated listing milestones or records them as pending, publishes the eight-package set
in dependency order with `keiro-ops-http` last, proves the release from a clean consumer, and
moves IR-26 through IR-31 to `completed`. It hard-depends on everything because versions,
bounds, and completion evidence can be chosen truthfully only from integrated code.

Alternatives considered. Merging plans 274 and 277 because both add the pending-timer read
was rejected: the read is one function, and the two plans' remaining scopes (provenance
metadata, instance views, and shard reads versus a feed engine and a WebSocket protocol) share
nothing else; a single owner with a fixed interface is enough. Putting the composition API in
a new package (`keiro-inspect` or similar) was rejected because the API is generic over WAI
`Application` values and needs no dependency on any sibling metrics package, so a new package
would add one more lockstep release for thirty lines of routing; it lives in `keiro-ops-http`.
Folding the composition into plan 276 was rejected because it is a distinct functional concern
with its own acceptance criteria and its own cross-repository constraints, and because plan
276 is already the largest child. Writing fresh plans for IR-26 through IR-30 was rejected for
the reason given above. Releasing each child separately was rejected because five of the seven
change `keiro-ops` and the same `[Unreleased]` changelog headings, and the requests complete
only against a published release; one cohort release is cheaper for consumers than five.
Implementing kiroku's `listStreams` from a keiro plan, as plan 274 originally proposed, was
rejected because kiroku now plans and releases it itself under its MasterPlan 13; a keiro plan
that edits kiroku would collide with that work and could not ship anything consumer-reachable.

Relevant durable context, read for this initiative (the rest of `docs/adr/` was scanned by
filename and heading and is not relevant):

- [ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
  is the stance decision every child ships under. It sanctions an inspection-and-operations
  surface under five conditions: sister-package packaging (no existing package gains a web
  dependency), ADR-28 discipline on the wire (every endpoint renders a supported operation and
  the read/write split is derived mechanically from `isMutation`), preview then confirm with
  mutations off by default, push is a hint and poll is truth, and composition without
  duplication. It disposes of IR-26 through IR-31 explicitly and names plans 274 through 278
  as their implementations. Every child's own ADR cites it as the boundary decision; none
  amends `docs/why-keiro.md`.
- [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  is the discipline the surface extends: operator commands are thin adapters over exported
  operations of the owning library, a missing primitive is added and tested in the owning
  library first, commands that need compiled application values mount through `AppHooks`,
  reads are observations that reserve nothing, and positions are reported as
  `store_position`, `visible_store_head`, and "global position distance", never "lag" or
  "backlog". EP-2, EP-3, and EP-4 each append a paragraph to it.
- [ADR-35](../adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md)
  freezes the `keiro_read.projection_group_status_v1` relation EP-5's projection feed
  re-reads; [ADR-36](../adr/0036-external-readers-use-versioned-guarded-sql-contracts.md) is
  the out-of-process precedent EP-3 cites for the discipline but does not reuse.
- [ADR-23](../adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md)
  makes `keiro_workflows` the authority EP-2 pages and EP-5 watches;
  [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md) names the
  three discriminators EP-3's snapshot-health read reports individually;
  [ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
  is why EP-4's provenance metadata may not touch event ids;
  [ADR-39](../adr/0039-foreground-timer-resume-uses-expiring-token-ownership.md) is the
  single-clock rule EP-3 and EP-4 adopt for ages and lease states;
  [ADR-9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) owns the
  verification EP-1 lifts into a session.

Cross-repository decisions, cited by the canonical handles their bundles publish:
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1` (every inspection endpoint lives in the
project that owns the concept; keiro owns framework-level views and the composition of mounted
surfaces), `ADR-2` (the WebSocket protocol convention), `ADR-3` (push is a hint, poll is
truth), `ADR-4` (surfaces live in sister packages exporting a bare WAI `Application`),
`ADR-5` (no backend-for-frontend: the composed mount is routing, never aggregation), and
`ADR-7` (read-only first; mutations ride owning-repository gates). The shared wire conventions
are project `mori://shinzui/keiro-ui`, path `docs/architecture/inspection-api-conventions.md`
(artifact-level URI pending). Kiroku's `mori://shinzui/kiroku/okf/adrs/concepts/ADR-1`
(surrogate stream ids are resolved by lookup) constrains EP-4's provenance view, and its
MasterPlan 13 records that the application kiroku exports is a prefix-agnostic value that
keiro's composed mount embeds, which is the constraint EP-6 relies on.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Serve the keiro-ops surface over HTTP (IR-26) | docs/plans/276-serve-the-keiro-ops-surface-over-http.md | None | None | Not Started |
| 2 | Add cursor-paged workflow inspection reads for the HTTP surface (IR-30) | docs/plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md | None | None | Not Started |
| 3 | Expose aggregate inspection read APIs (IR-28) | docs/plans/278-expose-aggregate-inspection-read-apis.md | None | EP-2 | Not Started |
| 4 | Expose process-manager inspection reads (IR-29) | docs/plans/274-expose-process-manager-inspection-reads.md | None | EP-2, EP-3 | Not Started |
| 5 | Publish WebSocket live feeds over Keiro.Wake (IR-27) | docs/plans/277-publish-websocket-live-feeds-over-keiro-wake.md | EP-1 | EP-2, EP-4 | Not Started |
| 6 | Mount composed runtime inspection surfaces under one port (IR-31) | docs/plans/302-mount-composed-runtime-inspection-surfaces-under-one-port.md | EP-1 | EP-5 | Not Started |
| 7 | Release the keiro inspection surface cohort and complete the keiro-ui requests | docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md | EP-1, EP-2, EP-3, EP-4, EP-5, EP-6 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Plans 274 through 278 were created on 2026-09-10 as standalone plans under their own
Intentions (`intention_01m24f92n8e2nv1bh0pzw5h4mw`, `intention_01m24f03zreg59e5twbm7mpmga`,
`intention_01m24fzbdrevnasj0zm1y199vw`, `intention_01m24gb383e91rfr2dp7f2dkdz`, and
`intention_01m24m6m00ev59wa81shymsktd`) and were adopted by this MasterPlan on 2026-09-30.
Commits under those five plans carry their own `Intention:` trailer together with the
`MasterPlan:` trailer for this file; commits under plans 302 and 303 carry this MasterPlan's
Intention.


## Dependency Graph

EP-1, EP-2, EP-3, and EP-4 have no hard dependencies and may be implemented in parallel by
different sessions. EP-1 touches `keiro-ops/src/Keiro/Ops.hs` (exports only),
`keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` (a lifted session), and the new
`keiro-ops-http/` tree. EP-2 touches `keiro/src/Keiro/Workflow/`, creates
`keiro/src/Keiro/Inspection/Cursor.hs` and `keiro/src/Keiro/Workflow/Inspection.hs`, adds a
migration, and rewrites the rendering in `keiro-ops/src/Keiro/Ops/Workflow.hs`. EP-3 touches
`keiro/src/Keiro/Command.hs` and `keiro/src/Keiro/Snapshot/Schema.hs` additively, creates
`keiro/src/Keiro/Inspection/Aggregate.hs` and `keiro-ops/src/Keiro/Ops/Aggregate.hs`, and
mounts a hook. EP-4 touches `keiro/src/Keiro/ProcessManager.hs`, `keiro/src/Keiro/Timer/`, and
`keiro/src/Keiro/Subscription/Shard/`, creates `keiro/src/Keiro/ProcessManager/Inspect.hs` and
`keiro-ops/src/Keiro/Ops/ProcessManager.hs`, extends `keiro-ops/src/Keiro/Ops/Timer.hs` and
`Shard.hs`, and mounts a hook. The only files two of them edit are `keiro-ops/src/Keiro/Ops.hs`
and `keiro-ops/src/Keiro/Ops/Embed.hs` (both additive: new exports, new `Command`
constructors, new `AppHooks` fields), `keiro-ops/test/Main.hs` (new groups and the
`embeddedHooks` value), the `[Unreleased]` sections of the changelogs, and the bundle
`log.md` files; whichever lands second appends after what exists.

The soft dependencies in wave one are shared artifacts with a "whoever lands first creates
it to the fixed interface" rule, recorded in Integration Points: EP-3 and EP-4 consume EP-2's
cursor codec; EP-4 consumes EP-3's source-reporting hydration. None of these blocks work,
because the interfaces are fixed here and are small enough to create from the other plan's
text. The two kiroku-gated milestones (plan 274 Milestone 5, plan 278 Milestone 4) depend on
a `kiroku-store` release that exports `listStreams`; they are the last milestones of their
plans and may complete after the rest of each plan, and after EP-7 has shipped the cohort if
the kiroku release is late.

EP-5 hard-depends on EP-1's Milestones 1 through 3 because the feeds mount onto
`Keiro.Ops.Http.Application.opsApplication` through `websocketsOr` and reuse plan 276's
configuration, CORS, error envelope, and drift policy; plan 277's Decision Log already says
that if EP-1 has not reached Milestone 3 when EP-5's Milestone 2 starts, the implementer
finishes EP-1 to that point rather than creating a second package skeleton. EP-5's Milestone 1
(the pending-timer read's consumer side and the two paired `keiro-ops` commands) is
independent and may run in wave one; it soft-depends on EP-4 for the pending-timer read and
on EP-2 for the workflow rendering, both under the first-lands-creates rule.

EP-6 hard-depends on EP-1 because the composed router mounts `opsApplication` (or
`opsApplicationWithFeeds` once EP-5 exists) at the `keiro` prefix and reuses
`Keiro.Ops.Http.Server.withOpsHttpServer` as the single bind point; its unit tests over stub
applications need nothing from EP-1, but its acceptance tests mount the real surface. It
soft-depends on EP-5: when EP-5 has landed, EP-6's tests also drive keiro's `/keiro/ws` feed
through the prefix; when it has not, they drive only kiroku's `/kiroku/ws/events`, which is
what IR-31's acceptance names.

EP-7 hard-depends on all six because it dates changelogs, chooses the shared version, adds
`keiro-ops-http` to the release order, runs the full gate, publishes, proves the release from
a clean consumer, and completes the requests, none of which can be done truthfully before the
code is integrated. EP-7 does not wait for the kiroku-gated listing milestones: if
`kiroku-store` 0.10.0.0 is not on Hackage when EP-7 starts, it ships without listing, records
IR-28 and IR-29 item 1a as pending, and the listing milestones ship in the next lockstep
release under a short follow-up entry in this MasterPlan's Progress.

The recommended landing order is therefore EP-1, EP-2, EP-3, and EP-4 in parallel (with
EP-5's Milestone 1 alongside), then EP-5 and EP-6 in parallel, then EP-7. The longest serial
chain is three plans deep (EP-1, EP-5, EP-7).


## Integration Points

**The `keiro-ops-http` package** (owner: EP-1, plan 276; extended by EP-5 and EP-6;
released by EP-7). Shared artifact: `keiro-ops-http/` with modules `Keiro.Ops.Http`,
`Keiro.Ops.Http.Application`, `Keiro.Ops.Http.Config`, `Keiro.Ops.Http.Cors`,
`Keiro.Ops.Http.Route`, and `Keiro.Ops.Http.Server`, the standalone `keiro-ops-http`
executable, and the test suite `keiro-ops-http-test`. EP-1 fixes the contract every later
child consumes without change: `opsApplication :: OpsHttpConfig -> AppHooks -> KirokuStore ->
Application`; `OpsHttpConfig { mutations, schemaDrift, allowedOrigins }` with
`defaultOpsHttpConfig` (mutations disabled, refuse on drift, no origins);
`withOpsHttpServer :: OpsHttpServerConfig -> Application -> (OpsHttpServer -> IO a) -> IO a`
binding `127.0.0.1:9092` by default with port 0 meaning an OS-assigned port;
`corsMiddleware :: [Text] -> Middleware`; `errorResponse` producing
`{"error":{"code","message","details"}}`; routes derived by translating path segments into
command words and `snake_case` query keys into `--kebab-case` options, parsed by
`Keiro.Ops.commandParser` and classified by `Keiro.Ops.isMutation`; reads answer `GET` with
the command's `jsonValue` verbatim; every request runs
`Keiro.Migrations.SchemaCheck.verifyExpectedSchemaSession` first. EP-5 adds
`Keiro.Ops.Http.Protocol`, `Views`, `Feed`, and `WebSocket`, the `/ws` endpoint, and
`Keiro.Ops.Http.opsApplicationWithFeeds :: OpsHttpConfig -> FeedHandle -> AppHooks ->
KirokuStore -> Application`. EP-6 adds `Keiro.Ops.Http.Compose`. Every route matches
`pathInfo` relative to the mount and no response carries an absolute URL, so the exported
application is a prefix-agnostic value (the same constraint kiroku's MasterPlan 13 records for
its own application). The package version equals the working tree's shared version at the
moment the package is created (0.19.0.0 on 2026-09-30; plan 276's text said 0.16.0.0, which
was the version when it was written), with `^>=` bounds on the sibling packages and the
`kiroku-store` bound copied from `keiro-ops/keiro-ops.cabal` (`>=0.9.0.1 && <0.10` today,
moved by the listing milestones). Plan 276 owns the `cabal.project`, `README.md`, `justfile`,
release-skill, and `mori.dhall` entries for the package; EP-5 and EP-6 add only their own
dependencies and modules to those entries.

**The opaque cursor codec** (owner: EP-2, plan 275; consumers: EP-3, EP-4, EP-5). Shared
artifact: `keiro/src/Keiro/Inspection/Cursor.hs`, exposed from `keiro`, with exactly this
interface:

```haskell
newtype InspectionCursor = InspectionCursor { cursorText :: Text }
data CursorError = MalformedCursor !Text | CursorKindMismatch !Text !Text
encodeCursor :: (ToJSON payload) => Text -> payload -> InspectionCursor
decodeCursor :: (FromJSON payload) => Text -> InspectionCursor -> Either CursorError payload
```

A token is unpadded base64url over the compact JSON object `{"k":<kind>,"v":<payload>}`;
`decodeCursor` rejects a kind other than the one requested. `base64-bytestring >=1.2 && <1.3`
is added to `keiro/keiro.cabal` by whichever plan creates the module. Kind tags are plain text
constants owned by the module that owns each read: `wf-key`, `wf-created`, `wf-steps`,
`wf-journal`, `wf-children`, `wf-awakeables` (EP-2), `aggregate-list` (EP-3),
`timer-pending` and `pm-list` (EP-4). Plan 277's proposed `Keiro.Ops.Cursor` in `keiro-ops`
and plan 274's proposed textual `<fire_at>/<uuid>` timer cursor are withdrawn; every keiro
inspection read mints interchangeable tokens from this one codec, and a client never does
arithmetic on them. The one `optparse-applicative` reader that turns a `--after CURSOR`
option into an `InspectionCursor` lives in `keiro-ops/src/Keiro/Ops/Parse.hs` as
`cursorReader :: ReadM InspectionCursor` (it only wraps the text; the library read validates
the kind), created by whichever of EP-2, EP-3, EP-4, or EP-5 first needs it. Whoever lands
first creates the module to this interface; the others import it. This decision becomes part
of EP-2's ADR-28 paragraph.

**The pending-timer read** (owner: EP-4, plan 274, Milestone 3; consumer: EP-5, plan 277,
Milestone 1; created by whichever lands first, to this interface). Shared artifact:
`keiro/src/Keiro/Timer/Schema.hs`, re-exported from `keiro/src/Keiro/Timer.hs`:

```haskell
data PendingTimerFilter = PendingTimerFilter
  { processManagerName :: !(Maybe Text), correlationId :: !(Maybe Text) }
anyPendingTimer :: PendingTimerFilter
data PendingTimerPageRequest = PendingTimerPageRequest
  { pageSize :: !Int, after :: !(Maybe InspectionCursor) }
data PendingTimerReadError = InvalidPendingTimerPageSize !Int | InvalidPendingTimerCursor !CursorError
data PendingTimerPage = PendingTimerPage
  { observedAt :: !UTCTime, timers :: ![TimerInspection], next :: !(Maybe InspectionCursor) }
pendingTimerStatuses :: NonEmpty TimerStatus            -- Scheduled :| [Firing]
findPendingTimers ::
  (Store :> es) => PendingTimerFilter -> PendingTimerPageRequest ->
  Eff es (Either PendingTimerReadError PendingTimerPage)
```

Both filters are optional so that the feed can watch every pending timer and the
process-manager view can narrow to one instance. Page sizes are validated to 1 through 500
(plan 274 said 100; 500 matches `maxInspectionPageSize` and the feeds' `maxItems`). The
statement selects the `lookupTimerInspection` columns plus `now()` in one transaction, filters
`status IN ('scheduled', 'firing')` with the optional exact matches, orders by
`(fire_at, timer_id)`, applies the exclusive keyset `(fire_at, timer_id) > cursor` decoded
from kind `timer-pending` with payload `[fire_at, timer_id]`, and fetches `pageSize + 1` rows.
The decision whether a supporting partial index is needed stays with plan 274's Milestone 0
evidence. The single `keiro-ops` command over this read is
`timer pending list [--manager NAME] [--correlation ID] [--after CURSOR] [--limit N]` in
`Keiro.Ops.Timer` (limit defaults to 100, at most 500), read-only, rendering
`{"observed_at", "manager"?, "correlation_id"?, "items": [...], "next_cursor"?}` where each
item is `pendingTimerItemJson :: UTCTime -> TimerInspection -> Value`, exported from
`Keiro.Ops.Timer`: the existing `timerJson` keys plus `last_error` and `due_in_seconds`
(`fire_at` minus `observed_at`, negative when overdue). Plan 274's `timer pending --manager`
(manager required) and plan 277's `timer pending list --process-manager` (`read_at` key) are
both replaced by this one command, which EP-1's transport serves as
`GET /timer/pending/list`. EP-5's `timers` feed parses subscribe fields `manager`,
`correlation_id`, and `limit`, and its items are `pendingTimerItemJson` values.

**Workflow instance rendering** (owner: EP-2, plan 275, Milestone 4; consumer: EP-5). Shared
artifact: `Keiro.Workflow.Inspection.instanceToJson :: WorkflowInstanceRow -> Value`, which
renders the keys `keiro-ops` publishes today plus the additive `status_class`. Plan 275
deletes `keiro-ops`'s private `workflowInstanceJson` and renders `wf list` items through the
library function. EP-5's `workflows` feed items must equal `wf list` items, so the feed uses
`instanceToJson` when EP-2 has landed; if EP-5 lands first it exports the existing
`workflowInstanceJson` from `Keiro.Ops.Workflow` temporarily and EP-2's Milestone 4 replaces
that import. The seven-value status vocabulary (`running`, `retrying`, `sleeping`,
`awaiting`, `completed`, `cancelled`, `failed`) and the `status_class` filter belong to EP-2;
EP-5's subscribe `statuses` field keeps carrying the five stored statuses that
`listWorkflowInstances` accepts, because the feed watches the legacy listing's first page.

**Projection group status rendering** (owner: EP-5, plan 277, Milestone 1). Shared
artifact: `Keiro.Ops.Projection.projectionGroupStatusJson :: ProjectionGroupStatusV1 -> Value`
using the frozen v1 column names of ADR-35 as keys, and the read-only `projection status`
command rendering `{"observed_at", "items", "visible_store_head"}`. The key is `observed_at`
(plan 277 said `read_at`) so every inspection page reports its clock under one name.

**Source-reporting hydration** (owner: EP-3, plan 278, Milestone 1; consumer: EP-4, plan
274, Milestone 2; created by whichever lands first, to this interface). Shared artifact, in
`keiro/src/Keiro/Command.hs`:

```haskell
data HydrationSource = FromSnapshot !StreamVersion | FullReplay !FullReplayReason
data FullReplayReason = NoStateCodec | SnapshotMissed !SnapshotMissReason | SeededReplayFailed !CommandError
hydrateWithSource ::
  (HasCallStack, IOE :> es, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions -> EventStream phi rs s ci co -> Stream (EventStream phi rs s ci co) ->
  Eff es (Either CommandError (Hydrated rs s, HydrationSource))
inspectionRunCommandOptions :: RunCommandOptions   -- sample rate 0, no metrics, no tracer
```

`hydrate` keeps its signature and becomes a projection over `hydrateWithSource`. Plan 274's
Milestone 2 uses `hydrateWithSource` and this `HydrationSource` type instead of its own
two-constructor `HydrationSource` and its second `lookupSnapshotSeed` call, and both views
render `hydration` through EP-3's `hydrationSourceJson` (`{"source":"snapshot","snapshot_version":n}`
or `{"source":"full_replay","reason":...}`).

**`AppHooks` and the command tree** (owner: `keiro-ops`; EP-3 adds `aggregates`, EP-4 adds
`processManagers`, EP-1 adds exports). Shared artifacts:
`keiro-ops/src/Keiro/Ops/Embed.hs` (`AppHooks`, `emptyAppHooks`), `keiro-ops/src/Keiro/Ops.hs`
(`Command`, `commandParser`, `isMutation`, `runCommand`, and the exports EP-1 adds), the
"omits code-dependent commands from the standalone tree" and "mounts every code-dependent
command" tests and the `embeddedHooks` value in `keiro-ops/test/Main.hs`, and
`jitsureiOpsHooks` in `jitsurei/app/Main.hs`. Both hook fields are additive `Maybe` fields
defaulting to `Nothing`; the domain words `aggregate` (EP-3) and `pm` (EP-4) are reserved;
whichever lands second extends the record, the two tests, and `embeddedHooks` rather than
replacing them. EP-1's transport serves hook-dependent commands only when the host mounts the
hook, exactly like the CLI, so no child writes endpoint code.

**The kiroku listing primitive and the `kiroku-store` bound** (external owner: kiroku
MasterPlan 13, plan 88, released by kiroku plan 96 as `kiroku-store` 0.10.0.0; consumers:
EP-3 Milestone 4 and EP-4 Milestone 5). Shared artifact:
`Kiroku.Store.Read.listStreams :: (HasCallStack, Store :> es) => Maybe Text -> Maybe StreamName
-> Int32 -> Eff es (Vector StreamInfo)`, an exact `starts_with` prefix filter with an
exclusive stream-name cursor, ordered by name. Both keiro listings wrap it with the prefix
`<category>-`; plan 274's `listStreamsInCategory` (a constructor keiro would have added to
kiroku itself) is withdrawn, and its `pm list` cursor becomes an opaque `pm-list` token over
the last stream name instead of a numeric stream id. Neither milestone starts until
`curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json` lists a 0.10
release whose `Kiroku.Store.Read` exports `listStreams` (the 2026-09-30 state is 0.9.0.1 with
no listing, and every keiro package pins `>=0.9.0.1 && <0.10`). The bound bump to
`>=0.10 && <0.11` in `keiro-core`, `keiro`, `keiro-migrations`, `keiro-test-support`,
`keiro-dsl`, `keiro-ops`, `keiro-ops-http`, and the `mori.dhall` dependency entries is done
once by whichever of the two milestones executes first; a local `cabal.project.local` overlay
may be used to compile against the kiroku checkout but is never committed. Keiro issues no SQL
against kiroku's schema and performs no event scan to discover streams.

**Migration numbers** (EP-2 adds `keiro_workflows_created_idx`; EP-4 may add a pending-timer
index if its Milestone 0 says go; plan 299 outside this MasterPlan also adds one). Shared
artifacts: `keiro-migrations/migrations/manifest`, `keiro-migrations/migrations.native.lock`,
`keiro-migrations/expected-schema/native/keiro-v18.txt`, and the counts hard-coded in
`keiro-migrations/test/Main.hs`. Numbers are allocated at implementation time by
`cabal run keiro-migrate -- new --manifest keiro-migrations/migrations/manifest --description "..."`,
which takes the next free number; plans say "the next migration" and never hard-code one
(plans 274 and 275 both said `0033`, which was true on 2026-09-10 and is not a reservation).
A plan that adds a migration after another has landed rebases its manifest line, lock line,
snapshot, and test counts on what exists.

**OKF handles and documentation bundles** (all children). Handles are allocated with
`okf id next` at creation, never copied from a plan: on 2026-09-30 the next free handles are
`CAP-20`, `ADR-49`, `DOC-29` in `docs/guides`, and `DOC-35` in `docs/user` (plans 276 and 278
both expected `CAP-20`, plans 276 and 277 expected `ADR-40`, which ADR-40 has since taken).
Each child appends its own entry to the relevant `log.md` with `okf log add` and runs the
bundle's strict validation; a plan that finds another child's entry already present appends
after it. Capability records: EP-1 creates the HTTP-surface record; EP-3 creates the
aggregate-inspection record and updates CAP-3, CAP-4, and CAP-16; EP-4 updates CAP-7 and
CAP-16; EP-5 updates CAP-16 and the HTTP-surface record; EP-6 updates the HTTP-surface record.
User documentation: EP-1 writes the transport runbook in `docs/guides`, EP-5 the feeds guide
in `docs/user`, EP-6 the composition guide in `docs/guides`; EP-2, EP-3, and EP-4 extend
`docs/user/operations.md` and their domain pages. Every child's ADR cites ADR-40 as the
boundary decision and records only its own narrower decision.

**Changelogs and the release** (owner: EP-7). Every child adds entries under `## [Unreleased]`
in the root `CHANGELOG.md` and the affected package changelogs (`keiro`, `keiro-ops`,
`keiro-migrations`, `keiro-ops-http`) and never dates them; EP-7 dates them, chooses the
shared version per the release skill's PVP rule (`agents/skills/release/SKILL.md`), and
publishes `keiro-ops-http` eighth. EP-1's Milestone 5 adds the package to the release skill,
`justfile`, and `README.md`; EP-7 verifies those edits exist rather than redoing them.
Request completion follows the bundle's precedent: a request stays `accepted` while its plan
is unstarted, moves to `in-progress` when implementation starts, and moves to `completed` with
`completedAt` and `resolution` only when the release that carries it is on Hackage.

**The composition contract** (owner: EP-6, plan 302; constraint on EP-1 and EP-5). Shared
artifact: `keiro-ops-http/src/Keiro/Ops/Http/Compose.hs`, exposing
`composeSurfaces :: ComposeConfig -> [MountedSurface] -> Either ComposeError Application` with
the stable prefixes `keiro`, `kiroku`, `shibuya`, and `pgmq`. The router forwards a request
whose first path segment matches a mounted prefix with both `pathInfo` and `rawPathInfo`
stripped of the prefix (wai-websockets derives the WebSocket request path from `rawPathInfo`,
so rewriting `pathInfo` alone would break every mounted `/ws` endpoint), answers `GET /` with
the list of mounted prefixes, answers an unmounted prefix with the conventions' error envelope,
and applies one CORS policy to every mounted surface, adding headers only to responses that do
not already carry them. Keiro's own surface is mounted at `/keiro` as `opsApplicationWithFeeds`
(or `opsApplication` before EP-5 lands), so `/keiro/health` and `/keiro/ws` are its composed
paths. This is why EP-1's and EP-5's routes match relative paths and carry no absolute URLs,
and why EP-5's WebSocket endpoint checks `requestPath == "/ws"` on the rewritten request rather
than on any configured mount path.

Cross-plan decisions that should become ADRs: the composition boundary (EP-6 writes it:
prefix routing only, one CORS policy, no re-serving), the transport decision (EP-1 writes it),
the feed decision (EP-5 writes it), the inspection-read decisions (EP-2 extends ADR-28; EP-3
and EP-4 each write one), and, at EP-7's distillation pass, whether ADR-40 needs a
consequences paragraph naming the shipped package and the release that carried it.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] (2026-09-30) Coordination: MasterPlan 45 created; plans 274 through 278 adopted with `master_plan` frontmatter and coordination notes; plans 302 and 303 created; IR-26 through IR-31 link the MasterPlan and IR-31 links plan 302.
- [ ] EP-1 (276) M1: `keiro-ops` exports the command tree and `keiro-migrations` exports the verifier session.
- [ ] EP-1 (276) M2: `keiro-ops-http` package with request translation and parser introspection.
- [ ] EP-1 (276) M3: the WAI application with schema handshake, read/write split, preview/confirm, CORS, health.
- [ ] EP-1 (276) M4: the Warp runner, the standalone executable, and the CLI-agreement proof.
- [ ] EP-1 (276) M5: runbook, capability record, changelogs, release-skill entry, IR-26 evidence, ADR.
- [ ] EP-2 (275) M1: `Keiro.Inspection.Cursor`, the status vocabulary, and the bounded instance listing.
- [ ] EP-2 (275) M2: the creation-order index migration and its index-usage proof.
- [ ] EP-2 (275) M3: paged journal, step, child, and awakeable reads.
- [ ] EP-2 (275) M4: library-owned JSON rendering and `keiro-ops` adoption.
- [ ] EP-2 (275) M5: documentation, changelogs, ADR-28 paragraph, IR-30 evidence.
- [ ] EP-3 (278) M0 and M1: preflight; `hydrateWithSource` and `observeSnapshotRow`.
- [ ] EP-3 (278) M2: `Keiro.Inspection.Aggregate` with fold-equivalence tests.
- [ ] EP-3 (278) M3: `AppHooks.aggregates`, the `aggregate` domain, and the jitsurei inspectors.
- [ ] EP-3 (278) M4 (gated on `kiroku-store` 0.10.0.0): `listAggregates` and `aggregate list`.
- [ ] EP-3 (278) M5: documentation, capability records, changelogs, IR-28 evidence, ADR.
- [ ] EP-4 (274) M0 and M1: validation gate; reaction provenance on the manager-state append.
- [ ] EP-4 (274) M2: `Keiro.ProcessManager.Inspect`, the instance view, `AppHooks.processManagers`, `pm show`.
- [ ] EP-4 (274) M3: `findPendingTimers` and `timer pending list`.
- [ ] EP-4 (274) M4: shard ownership views, `shard list`, and the extended `shard status`.
- [ ] EP-4 (274) M5 (gated on `kiroku-store` 0.10.0.0): `listProcessManagerInstances` and `pm list`.
- [ ] EP-4 (274) M6: documentation, capability records, changelogs, IR-29 evidence, ADR.
- [ ] EP-5 (277) M1: the paired `keiro-ops` commands and encoders.
- [ ] EP-5 (277) M2: the paired poll routes through the transport; WebSocket dependencies added.
- [ ] EP-5 (277) M3: protocol, views, feed engine, `/ws` endpoint, driver and end-to-end tests.
- [ ] EP-5 (277) M4: killed-LISTEN degradation proof.
- [ ] EP-5 (277) M5: executable mounting, feeds guide, CAP-16, changelogs, ADR, IR-27 evidence.
- [ ] EP-6 (302) M1: `Keiro.Ops.Http.Compose` router, CORS-once, and unit tests over stub surfaces.
- [ ] EP-6 (302) M2: keiro plus kiroku-metrics composed end to end, including WebSocket through a prefix.
- [ ] EP-6 (302) M3: the example executable and the composition guide.
- [ ] EP-6 (302) M4: capability record, changelogs, ADR, IR-31 evidence.
- [ ] EP-7 (303) M1: preflight: gates, gated milestones, versions, and bounds.
- [ ] EP-7 (303) M2: the lockstep release of eight packages.
- [ ] EP-7 (303) M3: clean-consumer proof and request completion.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- (2026-09-30) The five adopted plans were written the same day by parallel sessions and
  disagree on shared artifacts. Plan 277 adds `Keiro.Ops.Cursor` while plan 275 adds
  `Keiro.Inspection.Cursor` and plan 278 follows 275; plans 274 and 277 both add
  `Keiro.Timer.findPendingTimers` with different filter records, page bounds, and cursor
  encodings and each add a different `timer pending` command; plans 274 and 275 both name
  migration `0033`; plans 276 and 278 both expect `CAP-20`; plan 274's Milestone 5 implements
  a kiroku primitive named `listStreamsInCategory` that kiroku is not building. Integration
  Points settle each of these.
- (2026-09-30) The kiroku side moved under the plans: `kiroku-store` 0.9.0.1 is the current
  release and keiro's bound is `>=0.9.0.1 && <0.10`, but 0.9 does not export `listStreams`;
  kiroku's MasterPlan 13 (created 2026-09-30) releases the primitive as 0.10.0.0. Plans 274
  and 278 said the primitive would arrive in 0.9.0.0. Both gated milestones now wait for
  0.10.0.0.
- (2026-09-30) The working tree is at 0.19.0.0 and ADR-40 exists; plan 276's package version,
  its `kiroku-store` bound snippet, and plans 276 and 277's "ADR-40 at planning time" are
  stale and are corrected by the coordination notes.


## Decision Log

- Decision: Adopt plans 274 through 278 as children instead of rewriting them, and settle
  the shared decisions here with targeted cascade edits and a dated coordination note in each.
  Rationale: each plan is a complete, reviewed specification of one request; the
  disagreements are confined to a dozen shared artifacts that a MasterPlan exists to settle.
  Date: 2026-09-30

- Decision: Add two new children, plan 302 (composed mounting, IR-31) and plan 303 (the
  cohort release and request completion), for a total of seven in three waves.
  Rationale: IR-31 had no plan and its acceptance is a distinct functional concern with
  cross-repository constraints; the requests complete only against a published release, and
  five children share the same `[Unreleased]` headings, so one release child is the honest
  place to date them, add the eighth package, and record completion evidence.
  Date: 2026-09-30

- Decision: `Keiro.Inspection.Cursor` (plan 275) is the only cursor codec; plan 277's
  `Keiro.Ops.Cursor` and plan 274's textual timer cursor are withdrawn; kind tags are
  registered in Integration Points.
  Rationale: three codecs would produce three token formats for one convention; the library
  owns the reads, so it owns the tokens, and the HTTP layer and CLI carry them unchanged.
  Date: 2026-09-30

- Decision: One `findPendingTimers` with both filters optional, pages of 1 through 500,
  `TimerInspection` rows, `observed_at`, and a `timer-pending` cursor, owned by plan 274 and
  consumed by plan 277; one `timer pending list` command with `--manager` optional.
  Rationale: the feed needs the unfiltered read and the instance view needs the narrowed one;
  one read with optional filters serves both, and one command keeps the route, the CLI, and
  the feed three renderings of one handler result, which is ADR-40's condition 2.
  Date: 2026-09-30

- Decision: `hydrateWithSource` (plan 278) is the one source-reporting hydration; plan 274's
  instance view uses it instead of a second `lookupSnapshotSeed`.
  Rationale: two views of "did this state come from a snapshot" that could disagree is the
  kind of drift an inspection surface must not produce; one primitive in `Keiro.Command`
  serves both.
  Date: 2026-09-30

- Decision: Both listing milestones wrap kiroku's `listStreams` with a category prefix and
  wait for `kiroku-store` 0.10.0.0 from kiroku's MasterPlan 13; plan 274's cross-repository
  `listStreamsInCategory` work is withdrawn; EP-7 ships without listing if the kiroku release
  is late.
  Rationale: kiroku plans and releases its own primitive, and a keiro plan editing kiroku
  would collide with that work and could not ship anything consumer-reachable (a local
  checkout is not a release). The rest of each plan is valuable without listing and the
  requests record item 1a as pending honestly.
  Date: 2026-09-30

- Decision: The composition API lives in `keiro-ops-http` as `Keiro.Ops.Http.Compose`, not
  in a new package; the example executable and the composition tests take `kiroku-metrics` as
  a dependency of the example (behind a manual, default-off cabal flag) and of the test suite
  only.
  Rationale: the API is generic over WAI `Application` values, so the library needs no
  sibling metrics package; a new package would add a lockstep release for routing code; a
  default build of the released package must not require sibling metrics packages, which the
  flag guarantees, while the test suite may depend on them because Hackage consumers do not
  build tests.
  Date: 2026-09-30

- Decision: Migration numbers and OKF handles are allocated at implementation time, never
  reserved by a plan.
  Rationale: three plans claimed `0033` and two claimed `CAP-20`; the tools (`keiro-migrate
  new`, `okf id next`) exist to allocate, and a plan that names a number is stating an
  expectation, not a reservation.
  Date: 2026-09-30

- Decision: No keiro child implements anything in kiroku, shibuya, or pgmq-hs.
  Rationale: the user is planning the corresponding API work in those repositories
  (kiroku MasterPlan 13 exists, shibuya MasterPlan 7 is being written, pgmq-hs IR-1 through
  IR-3 are proposed); keiro's children consume released artifacts and cite the owning plans.
  Date: 2026-09-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
