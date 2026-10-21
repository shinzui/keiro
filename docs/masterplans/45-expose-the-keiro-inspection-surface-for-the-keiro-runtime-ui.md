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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:22:22Z
      verdict: "changes-requested"
      note: "Pre-update review: hot-path allocation and provenance costs, unbounded feed work, missing workflow routes, stale upstream API, and incomplete-release closure require correction."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:38:52Z
      mode: "update"
      note: "Correct hot-path isolation, bounded inspection/feed ownership, released APIs, observation semantics, and mandatory performance acceptance; implementation remains pending."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-20T16:50:14Z
      mode: "implement"
      note: "Begin EP-1 in registry order; preserve required integration and release gates"
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
had no plan before this MasterPlan added plan 302. This MasterPlan coordinates all six requests into one cohort, settles the shared
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
IR-31. Explicitly out of scope: authentication, authorization, TLS, and per-client edge rate limiting (internal admission, feed refresh and resource limits are in scope; the
recorded posture of every inspection server in the stack is a trusted network or an
authenticating reverse proxy, restated in each child's documentation); any dashboard, metrics
endpoint, time-series retention, or trace view (ADR-40 keeps those in OpenTelemetry); the
browser application itself, which `mori://shinzui/keiro-ui` owns; any endpoint that re-serves
or reshapes a lower layer's data (raw stream and event browsing stays kiroku's); and any
implementation work in kiroku, shibuya, or pgmq-hs. Those three repositories are planning
their own halves of the initiative in parallel: kiroku's cohort is
`mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`
(its listing and composed application have since shipped in released packages; see Integration Points), while shibuya and pgmq surfaces are consumed only through their owning packages' public applications. Recheck their current published surfaces during EP-6; historical planning status is not a release gate. Keiro's plans never implement inside those repositories.




## Decomposition Strategy

The initiative decomposes by functional concern into seven child plans in three waves. Plans 274 through 278 were adopted with their request reviews and later received plan-level review/revision provenance. The 2026-10-13 review updates their active instructions together with the shared contracts here. Earlier dated decisions remain historical; the current dependency graph and Integration Points govern implementation. Two new children cover what no existing plan does: composed
mounting (IR-31) and the cohort release that completes the requests.

The seven work streams remain functional concerns, with explicit owners for shared implementation. EP-1 (276) builds the transport and request budget independently of EP-2 (275), which owns the cursor codec, workflow reads, and their bounded CLI routes. EP-3 (278) follows EP-2 and owns the source-reporting hydration implementation. EP-4 (274) follows EP-2 and EP-3 and owns pending-timer reads and opt-in legacy reaction provenance. EP-5 (277) follows EP-1, EP-2, and EP-4, consuming their code rather than creating substitute shared modules. EP-6 (302) follows EP-1; its stub routing tests can proceed independently, while its final integration proof includes EP-5. EP-7 (303) releases the completed cohort after all six children and the performance gates pass. The upstream listing API has shipped, so the aggregate and PM listings are required for completion.

The changed order is deliberate: an implementation that imports an absent shared module is not independently implementable. Research and test-fixture preparation may overlap, but consumers do not take ownership of another child's implementation. The existing seven scopes stay intact.

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
| 1 | Serve the keiro-ops surface over HTTP (IR-26) | docs/plans/276-serve-the-keiro-ops-surface-over-http.md | None | None | In Progress |
| 2 | Add cursor-paged workflow inspection reads for the HTTP surface (IR-30) | docs/plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md | None | None | In Progress |
| 3 | Expose aggregate inspection read APIs (IR-28) | docs/plans/278-expose-aggregate-inspection-read-apis.md | EP-2 M1/M3/M4 (accepted cursor, page and ops interfaces) | None | Complete |
| 4 | Expose process-manager inspection reads (IR-29) | docs/plans/274-expose-process-manager-inspection-reads.md | EP-2 accepted cursor/ops pages; EP-3 accepted hydration/aggregate interfaces | None | In Progress |
| 5 | Publish WebSocket live feeds over Keiro.Wake (IR-27) | docs/plans/277-publish-websocket-live-feeds-over-keiro-wake.md | EP-1 accepted HTTP/budget; EP-2 accepted pages; EP-4 accepted PM/timer reads | None | In Progress |
| 6 | Mount composed runtime inspection surfaces under one port (IR-31) | docs/plans/302-mount-composed-runtime-inspection-surfaces-under-one-port.md | EP-1 accepted HTTP/budget | EP-5 real-feed interface for final composition | In Progress |
| 7 | Release the keiro inspection surface cohort and complete the keiro-ui requests | docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md | Accepted functional handoffs from EP-1–EP-6 for integrated proof; all six Complete before release | None | In Progress |

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

EP-1 and EP-2 can start independently. EP-2 precedes EP-3; EP-2 and EP-3 precede EP-4; EP-1, EP-2, and EP-4 precede EP-5. EP-1 precedes EP-6, with EP-5 an integration prerequisite for EP-6's final real-feed proof. All six precede EP-7. There is no cycle. The registry names accepted functional interfaces as code prerequisites. Final publication still requires every child Complete and the integrated runtime-isolation proof; milestone-level research may proceed before code dependencies are available.

Execution clarification (2026-10-20, following the user’s core-path priority):
implement consumers after their exact shared interfaces pass functional checks,
while producer children retain unfinished runtime-cost and release acceptance.
EP-3 consumes EP-2 M1/M3/M4; EP-4 consumes those interfaces and EP-3's accepted
source-reporting hydration and descriptor reads. EP-5 starts only after the HTTP
budget, bounded pages and PM/timer feed inputs are accepted. EP-6 starts from
the HTTP/budget handoff and finishes against the real feed. The integrated
experiment can then exercise the implemented cohort under EP-7 before final
child closure and publication. This explicitly replaces whole-child code
prerequisites, which otherwise put the integrated experiment ahead of the
features it must measure. No performance, correctness or release gate is
considered passed by a functional handoff. Current accepted handoffs are the
HTTP/budget interface (29 HTTP examples), cursor/workflow/ops pages, and
source-reporting hydration/aggregate reads (777 core and 25 example cases).


Shared files include `keiro/keiro.cabal`, `keiro-ops/keiro-ops.cabal`, `keiro-ops/src/Keiro/Ops.hs`, `keiro-ops/src/Keiro/Ops/Embed.hs`, their test suites, `jitsurei/app/Main.hs`, migration manifests/locks/schema snapshots, changelogs, and OKF logs. Later plans extend the prior owner's artifacts and retain unrelated additions. EP-4 completes its timer-read milestone before wiring its instance view, which consumes that read.

EP-7 requires complete listing and real composition evidence. An interim release is possible only as an explicitly rescoped task; it cannot mark a child, request, or this MasterPlan complete while required work is deferred.

## Integration Points

**Performance and correctness boundary (2026-10-13 review).** EP-1 owns request admission and execution limits in `Keiro.Ops.Http.Budget`; EP-5 uses the same budget for feed reads. EP-2 owns cursor decoding and workflow query-cost proofs. EP-3 owns hydration specialization and its command-path benchmark. EP-4 owns opt-in reaction provenance and timer-index read/write evidence. EP-6 must preserve these limits through composition. EP-7 owns the integrated interference experiment below and cannot close the initiative without it. [ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md) records the durable isolation requirement.

Inspection is accepted only with measured interference bounds, not from the fact that an API is read-only. Capture a baseline at the pre-implementation commit with the same GHC optimization, RTS capabilities, database size, connection limits, PostgreSQL settings, and workload seed as the candidate. Run inside `nix develop`, with normal autovacuum and durable settings (`fsync`, `synchronous_commit`, and `full_page_writes` on); record settings and raw samples. Compare at least five alternating baseline/candidate runs after warm-up. At a fixed offered load below baseline saturation, a reproducible median throughput loss over 5%, p95 command/worker latency increase over 5%, or core-path allocated bytes per completed runtime operation increase over 5% blocks the milestone. These thresholds protect ordinary commands and workers, including contention caused by active inspection; they are not blanket targets for inspection request latency, inspection allocations, total-process allocation divided by writer completions, or WAL volume. Combined process allocation and WAL remain attribution diagnostics. Unmounted/default-off paths must add no inspection work, and inspection-only code stays outside those paths. Use focused behavior checks and measurements that resolve an actual core-path risk, rather than expanding the test matrix for its own sake. No extra database statements, event reads, metadata serialization, or background tasks are allowed on ordinary commands or provenance-disabled reactions. An inconclusive/noisy comparison is not a pass: extend matched runs and report uncertainty. Keep the existing 25% historical benchmark check as a coarse smoke test only.

Use focused evidence for each actual core-path change, following the user's
2026-10-20 instruction to avoid overengineering tests. Compare the pre-change
runtime with unmounted/default-off, mounted-idle and active inspection, including
1/32 views, 1/256 clients, repeated polls, large values, slow readers and churn.
The matched writer covers workflow scheduling/claim/resume/release and timer
schedule/claim/fire over identical ledgers and durable settings. Reuse the
ordinary-hydration hit/miss/corrupt/no-codec/long-history comparison for that
changed implementation. For default-off manager provenance, retain the existing
accepted/no-op/rejected/duplicate/fan-out behavior and retention checks and verify
the disabled pure options branch is the original update, before target traversal
or metadata construction; it cannot issue database work. Existing projection
application and worker retention checks cover their unchanged paths. These are
separate, relevant proofs; a cross-product of every domain outcome with every UI
load mode is not required. Retain raw writer latency/allocation, process CPU,
WAL and table-update counters, plus the existing query-plan/row/buffer evidence.
Idle mounting must perform no recurring SQL or own a wake cursor. Measure
post-major live heap at equal operation blocks after warm-up for idle notification
load and active/churning subscribers, repeating a persistent positive steady-state
trend before acceptance. Assert views, connections and the wake pump return to
zero after clients leave. The coarse existing retention threshold alone does not
establish leak freedom.

**Bounded workflow routes** (owner EP-2, consumed by EP-1 and EP-5). Add the read-only command subtree `wf inspect`: `list`, `header NAME ID`, `journal NAME ID`, `steps NAME ID`, `children NAME ID`, and `awakeables NAME ID`. It exposes the new page APIs directly, without draining them. List options are repeatable `--status-class`, `--workflow-name`, `--created-since`, `--created-before`, `--updated-since`, `--updated-before`, `--ordering key|created_desc`, `--limit`, and `--after`; detail reads use `--limit`, `--after`, and, for journal/steps, `--generation`. These mechanically become `/wf/inspect/...` routes; EP-1 does not write a second route table. EP-2 adds structured `InspectionFailed code message` outcomes and updates an existing transport match; if the transport lands later, EP-1 consumes that variant. Whichever integrates second proves HTTP codes without introducing a reverse package dependency. Old CLI commands keep their shapes and are explicitly expensive compatibility routes when they drain whole histories. EP-5's workflow feed consumes this bounded listing and the seven status classes; `/wf/inspect/list` is its authoritative poll route.

Workflow automatic refresh is restricted to key ordering with class/name filters.
Superseded prototype: EP-2's generic-plan evidence with guarded migrations 0033/0034 bounds those paths;
manual update windows and creation-order status filtering can still scan broadly
and remain outside feed inputs. The listing merges at most 64 exceptionally wide keys / 256 KiB raw key bytes
before time/cursor filtering and otherwise returns an explicit size failure.
Hash keys only locate candidates; exact text and database ordering remain
canonical. Owner compound indexes fail write/key-domain checks; child and
awakeable pages remain manual under host SQL/read deadlines, outside feeds.
The child is not complete merely from list results.

**Resource limits** (EP-1 and EP-5). Application construction becomes `IO Application`, allocating one admission budget once per mount. Defaults: at most 4 concurrent inspection jobs including schema checks and feed reads, no unbounded waiting queue (HTTP excess returns 503 `inspection_busy`), 5-second overall read deadline, 2-second database statement timeout, 1 MiB encoded response/frame limit, 2 MiB queued bytes per socket, and 16 KiB request/cursor input limits (cursor maximum 4096 encoded bytes). EP-5 additionally caps distinct active views at 32, refreshes a view at most once per second, caps connections at 256 and subscriptions at three per socket, and accounts for in-flight construction as well as established resources. Oversized results fail explicitly, never truncate silently. Configure longer deadlines only through host policy. A Warp idle timeout is not a handler deadline. Use an inspection-owned pool in standalone/composed examples and recommend it for embedding; a shared pool remains supported only within these budgets and must pass interference tests. PostgreSQL CPU, IO, WAL and index-write costs are shared even with separate pools.

Per-request schema verification remains fail-closed and runs inside the budget; pool reuse does not make its catalog scans cheap. Rejected admission, invalid input and disabled mutations do no schema work. No TTL cache may silently weaken drift refusal. Measure the scan at expected poll load; if it exceeds the interference gate, stop and revise the drift protocol explicitly rather than ship a cache. Existing feeds stop publishing when their next budgeted refresh discovers drift or verification failure; verification is shared once for an admitted refresh batch, not repeated per subscriber. No refresh is published under an unverified schema.

**Released substrate (verified 2026-10-13).** Keiro's tree is 0.20.0.0 and already uses `kiroku-store ^>=0.11.0.0`. Hackage's `preferred.json`, released source, and upstream tags `kiroku-store-v0.11.0.0` and `kiroku-metrics-v0.3.0.0` agree (peeled commit `7394055de458bef8f6ec2e68231f3ca7932bb9be`). Canonical owners are `mori://shinzui/kiroku/packages/kiroku-store` and `mori://shinzui/kiroku/packages/kiroku-metrics`. The listing primitive has shipped; no 0.10 gate or downgrade remains. Its signature is `listStreams :: (HasCallStack, Store :> es) => Maybe CategoryName -> Maybe Text -> Maybe StreamName -> BrowsePageSize -> Eff es (Vector StreamInfo)`. Build the limit with `mkBrowsePageSize (pageSize + 1)` (upstream accepts 1..1001), pass the exact category plus the `<category>-` prefix, and preserve upstream UTF-8 byte order. Consumer filtering processes at most the first `pageSize` raw rows; the extra raw row is look-ahead only. Continue from the last raw row examined even when all display items are rejected. Empty display pages can therefore carry a cursor. Never drain upstream pages to fill a display page. EP-6 uses released `kiroku-metrics ^>=0.3.0.0`, `storeServerProviders`, and `combinedAppWithProviders`, subject to rechecking newer releases at implementation.


**The `keiro-ops-http` package** (owner: EP-1, plan 276; extended by EP-5 and EP-6;
released by EP-7). Shared artifact: `keiro-ops-http/` with modules `Keiro.Ops.Http`,
`Keiro.Ops.Http.Application`, `Keiro.Ops.Http.Config`, `Keiro.Ops.Http.Cors`,
`Keiro.Ops.Http.Route`, and `Keiro.Ops.Http.Server`, the standalone `keiro-ops-http`
executable, and the test suite `keiro-ops-http-test`. EP-1 fixes the contract every later
child consumes without change: `opsApplication :: OpsHttpConfig -> AppHooks -> KirokuStore ->
IO Application`; `OpsHttpConfig { mutations, schemaDrift, allowedOrigins, inspectionLimits }` with
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
KirokuStore -> IO Application`. EP-6 adds `Keiro.Ops.Http.Compose`. Every route matches
`pathInfo` relative to the mount and no response carries an absolute URL, so the exported
application is a prefix-agnostic value (the same constraint kiroku's MasterPlan 13 records for
its own application). The package version equals the shared version when created (0.20.0.0 in this review), with sibling bounds following that version and the supported `kiroku-store ^>=0.11.0.0` bound retained. Plan 276 owns the `cabal.project`, `README.md`, `justfile`,
release-skill, and `mori.dhall` entries for the package; EP-5 and EP-6 add only their own
dependencies and modules to those entries.

**The opaque cursor codec** (owner: EP-2, plan 275; consumers: EP-3, EP-4, EP-5). Shared
artifact: `keiro/src/Keiro/Inspection/Cursor.hs`, exposed from `keiro`, with exactly this
interface:

```haskell
newtype InspectionCursor = InspectionCursor { cursorText :: Text }
data CursorError = MalformedCursor !Text | CursorKindMismatch !Text !Text
maxCursorBytes :: Int -- 4096
encodeCursor :: (ToJSON payload) => Text -> payload -> InspectionCursor
encodeCursorBounded :: (ToJSON payload) => Text -> payload -> Maybe InspectionCursor
decodeCursor :: (FromJSON payload) => Text -> InspectionCursor -> Either CursorError payload
```

Reject tokens longer than 4096 encoded bytes before decoding. Page producers use
`encodeCursorBounded`; if a stored continuation key cannot fit, return an explicit
result-size failure (HTTP 413 `inspection_result_too_large`) rather than an unusable
next cursor. The unchecked encoder remains available for codec fixtures. A token is unpadded base64url over the compact JSON object `{"k":<kind>,"v":<payload>}`;
`decodeCursor` rejects a kind other than the one requested. `base64-bytestring >=1.2 && <1.3`
is added to `keiro/keiro.cabal` by EP-2. Kind tags are plain text
constants owned by the module that owns each read: `wf-key`, `wf-created`, `wf-steps`,
`wf-journal`, `wf-children`, `wf-awakeables` (EP-2), `aggregate-list` (EP-3),
`timer-pending` and `pm-list` (EP-4). Plan 277's proposed `Keiro.Ops.Cursor` in `keiro-ops`
and plan 274's proposed textual `<fire_at>/<uuid>` timer cursor are withdrawn; every keiro
inspection read mints interchangeable tokens from this one codec, and a client never does
arithmetic on them. The one `optparse-applicative` reader that turns a `--after CURSOR`
option into an `InspectionCursor` lives in `keiro-ops/src/Keiro/Ops/Parse.hs` as
`cursorReader :: ReadM InspectionCursor` (it only wraps the text; the library read validates
the kind), created by EP-2 before its consumers start; the others import it. This decision becomes part
of EP-2's ADR-28 paragraph.

**The pending-timer read** (owner: EP-4, plan 274, Milestone 3; consumer: EP-5, plan 277,
Milestone 1; EP-4 supplies this prerequisite interface). Shared artifact:
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
EP-4's M0 measures unfiltered, manager-only, correlation-only and combined filters, first and deep pages, using realistic skew and both prepared-plan modes. LIMIT bounds returned rows, not rows examined. Index selection must include timer write/WAL costs; the feed cannot bypass this gate. The single `keiro-ops` command over this read is
`timer pending list [--manager NAME] [--correlation ID] [--after CURSOR] [--limit N]` in
`Keiro.Ops.Timer` (limit defaults to 100, at most 500), read-only, rendering
`{"observed_at", "manager"?, "correlation_id"?, "items": [...], "next_cursor"?}` where each
item is `pendingTimerItemJson :: UTCTime -> TimerInspection -> Value`, exported from
`Keiro.Ops.Timer`: the existing `timerJson` keys plus `last_error` and `due_in_seconds`
(`fire_at` minus `observed_at`, negative when overdue; this volatile display value is excluded from feed change detection). Plan 274's `timer pending --manager`
(manager required) and plan 277's `timer pending list --process-manager` (`read_at` key) are
both replaced by this one command, which EP-1's transport serves as
`GET /timer/pending/list`. EP-5's `timers` feed parses subscribe fields `manager`,
`correlation_id`, and `limit`, and its items are `pendingTimerItemJson` values.

**Workflow instance rendering** (owner: EP-2, plan 275, Milestone 4; consumer: EP-5). Shared
artifact: `Keiro.Workflow.Inspection.instanceToJson :: WorkflowInstanceRow -> Value`, which
renders the keys `keiro-ops` publishes today plus the additive `status_class`. Plan 275
deletes `keiro-ops`'s private `workflowInstanceJson` and renders `wf list` items through the
library function. EP-5's `workflows` feed uses this encoder after EP-2 has landed. The seven-value status vocabulary (`running`, `retrying`, `sleeping`, `awaiting`, `completed`, `cancelled`, `failed`) and filter belong to EP-2. EP-5 uses the bounded `wf inspect list` path with `status_class`, not the legacy stored-status listing.

**Projection group status rendering** (owner: EP-5, plan 277, Milestone 1). Shared
artifact: the bounded projection-status page with a `projection-groups` cursor and `Keiro.Ops.Projection.projectionGroupStatusJson :: ProjectionGroupStatusV1 -> Value`
using the frozen v1 column names of ADR-35 as keys, and the read-only `projection status`
command with `--limit` and `--after`, rendering `{"observed_at", "items", "visible_store_head", "next_cursor"?}`. The key is `observed_at`
(plan 277 said `read_at`) so every inspection page reports its clock under one name.

**Source-reporting hydration** (owner: EP-3, plan 278, Milestone 1; consumer: EP-4, plan
274, Milestone 2; EP-3 supplies this prerequisite interface). Shared artifact, in
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

`hydrate` keeps its signature and its ordinary result path. Extract one private hydration worker with a specialized result continuation: the command continuation ignores source diagnostics without constructing a pair, reason object, or error text; the inspection continuation returns the pair. Verify optimized allocation and query counts instead of assuming GHC removes a `fst` wrapper. Preserve the current probe wrapper, telemetry and seed-verification behavior. Plan 274's
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

**The kiroku listing primitive and the `kiroku-store` bound** (upstream owner `mori://shinzui/kiroku/packages/kiroku-store`; consumers EP-3 M4 and EP-4 M5). Use the verified released substrate and raw-row continuation contract above. The workspace already carries the necessary 0.11 bound; do not lower it. EP-3 owns the first consumer integration proof; EP-4 reuses the verified API. Keiro issues no SQL against kiroku's private schema and scans no event history to discover streams.

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
and why EP-5 matches WAI `pathInfo == ["ws"]` after stripping the mount, preserving query strings and raw suffix bytes.

Cross-plan decisions that should become ADRs: the composition boundary (EP-6 writes it:
prefix routing only, one CORS policy, no re-serving), the transport decision (EP-1 writes it),
the feed decision (EP-5 writes it), the inspection-read decisions (EP-2 extends ADR-28; EP-3
and EP-4 each write one), and, at EP-7's distillation pass, whether ADR-40 needs a
consequences paragraph naming the shipped package and the release that carried it.


## Progress

2026-10-20: EP-5's functional feed handoff is implemented and locally validated
by 37 HTTP-package examples. Shared initialization/read drivers, active-only
wake ownership, strict queue/in-flight budgets and scoped socket shutdown stay
in the sister package. Core library dependency closures remain web-free.
EP-6 can now exercise the real feeds under composed path prefixes; integrated
writer interference and cohort release remain open.

2026-10-20: EP-4 now provides the PM/timer/shard functional handoff: explicit
bounded legacy provenance, runtime-equivalent instance views, one-page public
stream listing, filter-bound timer pages and database-clock lease observations.
The real fulfillment catalog is mounted alongside aggregate hooks. Full
`just verify` and native flake checks pass for this functional handoff. No timer
migration or recurring runtime work is introduced. Its actual prepared plans
show broad reads scanning/sorting the pending ledger, so EP-5 timer consumers
must stay within the measured 100k-row envelope and refresh each shared view no
more than once per five seconds. Core-path interference remains an integrated
gate; inspection query latency has no blanket percentage target.

EP-3 now implements the aggregate catalog, shared source-reporting hydration,
snapshot clocks and raw-page continuation. The focused core/ops/HTTP/example
suites pass 777/51/29/25 examples, with the ordinary-worker comparison retained.
EP-3 is Complete after full Nix verification, strict documentation/policy
checks, final resolver regression checks and Nix flake checks. Publication and
the integrated core-interference gate remain open under EP-7.

EP-1 (276) and EP-2 (275) are In Progress; EP-3 (278) is Complete; the other
four children remain Not Started. HTTP transport, bounded workflow reads, canonical rendering and typed
failures are implemented. Focused workflow/ops/HTTP/migration checks pass
16/51/29/43 examples. The bounded header candidate passes Nix `just verify`, including
772 Keiro examples, all DSL proofs, coarse retention, strict documentation/
terminology checks and 43 migration examples. EP-3 uses the explicit accepted-interface handoff above; final release prerequisites remain open.

EP-2 now preserves the existing large-key writer domain with guarded indexes
and an exceptional-key budget. 136 actual custom/generic plans cover normal
key/class/name pages and 100,000 wide keys; an excessive exceptional population
fails explicitly before cursor/time filtering. Five paired schema-only write
runs per profile retain normal/crash medians within 5%, noisy latency and higher
large-row WAL costs. Owner detail reads stay manual under deadlines after their
compound indexes fail write-cost and key-domain checks.

The pre-implementation baseline is
`3bf3ac229f21d6c95179ce49b5e8f6323322f99b`. A five-run narrow HTTP comparison has
medians within 5% but inconclusive latency; its warmed repeat aborts when the
fifth baseline lacks headroom, preserving every leg. The expanded smoke completes all polls and measures about +11.5% total-process allocation
with 256 HTTP clients. This includes inspection work and is diagnostic, not proof of a core-path allocation regression. Timed pool attribution
shows temporary timer roots plus a shared 32 KiB buffer step; it is not strict
retention acceptance. A bounded exact current-row presentation candidate passes
16 owning-query / 29 HTTP examples without a TTL or skipped schema check;
its allocation/interference evidence remains pending. The 180-second pooled/
direct follow-up has slightly negative fits over seconds 60..180, supporting
finite timer/buffer warm-up without establishing domain retention acceptance.
The first bounded N2 matrix aborts at a missing final offered poll; it is retained,
and the client now joins its finite schedule. A separate N8/A16m profile will
qualify fresh capacity and use adjacent old/new controls for every mode. Strict matched
interference and persistent-retention acceptance remain open. Publication,
consumer proofs and later child implementations remain required. The user
confirmed that benchmarking should continue on this machine while other work
runs; matched controls and measured uncertainty remain the acceptance basis.

## Surprises & Discoveries

- (2026-10-20) The user clarified the target: preserve the core runtime path;
  inspection latency/allocation and total-process allocation are not blanket
  percentage gates. ADR-40 and the shared child acceptance text now make the
  attribution boundary explicit. Extra uncommitted HTTP resource-test machinery
  was removed. EP-3 ordinary hydration has five matched pairs per source mode:
  essentially unchanged allocation, no diagnostic constructors in ordinary Core,
  and p95 medians -0.63%..+2.38%. This is local worker evidence, not cohort release
  acceptance. The broader N8 HTTP run aborts in trial 4 on inspection request
  failures; raw samples and concurrent-build overlap are retained explicitly.

- (2026-10-20) EP-1's five alternating same-binary header-poll legs reject the
  first implementation on aggregate allocation: about 640.6 MiB per 1,000
  workflow operations idle versus 2,246.4 MiB with 32 views. The point header
  avoids EP-2's unindexed list sort. Attribution identifies schema comparison;
  moving the comparison into PostgreSQL retains a fresh live check on every
  request and reduces verifier allocation from about 2.31 MB to 10 KB per call.
  No live result/privilege TTL cache was introduced. Raw evidence and manifests
  live under `keiro/bench/results/inspection/`. Full matched deployment and
  retention acceptance is still open; no whole-child dependency is waived.

- (2026-10-20) EP-2's normal-planner evidence rejects the current default key
  and rare-status access paths: both examine all 100,000 fixture rows. The
  physical workflow primary key is id/name, opposite the inspection name/id
  ordering. Creation-order pages use the new index and scan 21 rows. The
  [retained plans](../../keiro/bench/results/inspection/query-before-key-index/README.md)
  do not establish write-cost or interference acceptance. EP-2 remains
  In Progress and its whole-child dependents remain ineligible.


- (2026-10-20) The PGMQ DLQ `read` command reserved rows despite its read-only
  classifier. EP-1 fixes the owner classifier and preview behavior; subsequent
  command-tree consumers must treat it as a POST mutation. Non-consuming queue
  browsing remains upstream-owned. Released `mori://shinzui/pgmq-hs/packages/pgmq-effectful` 0.6.1.1 lacks the
  newer local checkout's peek primitive.
- (2026-10-20) `withOpsInspectionPool` owns per-connection SQL timeouts and search
  paths. EP-5/EP-6 examples must use it rather than setting a timeout on a single
  schema-verification borrow.


- (2026-10-13) `Keiro.Wake.wakeSignalFromStore` duplicates an unbounded `TChan` once per call. Sharing that returned signal makes drivers consume each other's ticks; keeping it idle can retain a notification backlog. EP-5 now owns a continuously drained broadcast epoch while views exist, and drops the cursor at zero views.
- (2026-10-13) Plan 275 added library pages but left CLI commands draining whole histories. Plan 276 cannot derive missing routes from those APIs. The `wf inspect` subtree closes the hand-off.
- (2026-10-13) Existing `runTransaction` uses ReadCommitted in `mori://shinzui/kiroku/packages/kiroku-store`; two statements in a transaction do not establish one row snapshot. Database clock consistency and snapshot consistency are separate claims.
- (2026-10-13) Existing command benchmarks use `snapshotPolicy = Never`; the 25% historical threshold cannot prove diagnostic hydration is allocation-neutral on snapshot hits. ADR-41 also defines a newer reaction identity family absent from plan 274's original design.


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

- Decision (2026-10-20, core-path priority): withdraw the unpublished workflow
  writer DDL (0033/0034). Five alternating saturation comparisons measured
  -9.22% median writer capacity and +12.91% p95 with inspection unmounted.
  Paced throughput at 100/s was insufficient to expose this headroom loss.
  Use read-side classification, existing status/key indexes, and bounded,
  deadline-controlled inspection scans. Require restored writer capacity and
  fresh actual-query evidence. Earlier DDL/query matrices are superseded.


- Decision (2026-10-20, user-directed): use the focused core-path evidence
  mapping in Integration Points and EP-7. Preserve default-off work invariants,
  core throughput/latency/allocation gates and lifecycle bounds; avoid a redundant
  cross-product of unchanged domain outcomes with every inspection load mode.


- (2026-10-20) Coordinate code dependencies through explicitly accepted shared
  interfaces, then run integrated runtime-isolation evidence before child closure
  and publication. This follows the user's request to focus on preserving core
  paths and avoids treating inspection throughput/allocation as blanket targets.
  Existing child release requirements remain open until their evidence exists.

- Decision (2026-10-13): replace create-first shared ownership with explicit code prerequisites; expose bounded workflow commands; keep inspection work within explicit budgets and measured writer-interference limits. Reaction provenance is opt-in and bounded; hydration diagnostics are absent from ordinary command results. Rationale: these are concrete hot-path and correctness risks in the reviewed plans, not measured regressions in shipped code.
- Decision (2026-10-13): require all listing milestones and real composition tests before cohort closure. Rationale: released kiroku 0.11 already provides listing, and a partial delivery cannot satisfy the advertised initiative.


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

Review validation (2026-10-13 local date): the ADR profile type-check and `just adr-validate` passed in `nix develop` (50 concepts); all eight plans passed tagged-fence, required-section and newly added local-link checks; `git diff --check` passed. ADR-40 now carries the durable isolation requirements. Only planning documents changed; no runtime benchmark, build, or implementation acceptance is claimed.


2026-10-13 review/update: the coordination and acceptance contracts have been corrected. All implementation plans remain Not Started. The pre-update review was changes-requested; the changes below address that design review, while runtime performance remains unproven until the specified gates run. MasterPlan 45 and plans 302/303 were authored by `claude-fable-5-1`; adopted plans 274–278 have unknown original authorship and a recorded revision by that model. None had a plan-level review before this pass.


Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)


## Revision notes


2026-10-13: Applied the correctness and hot-path review. Added explicit performance acceptance and ownership, refreshed released dependency facts, and corrected the affected implementation and wire contracts. Earlier dated decisions remain historical; the current milestones and review constraints govern implementation. No runtime changes or benchmark results are claimed.
