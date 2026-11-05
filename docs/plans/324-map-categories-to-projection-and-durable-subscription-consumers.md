---
id: 324
slug: map-categories-to-projection-and-durable-subscription-consumers
title: "Map categories to projection and durable subscription consumers"
kind: exec-plan
created_at: 2026-10-26T19:29:29Z
intention: "intention_01m5wtye89ecpt2thwa4fj739h"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-26T19:29:29Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-05T01:09:54Z
      mode: "update"
      note: "Revalidate against 9da47eb7 after plans 323/327/328/329; adopt direct encoding, fix benchmark modes and command, correct doc targets and Jitsurei coverage"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-05T04:50:49Z
      mode: "update"
      note: "Performance review: additive library scope, provisional limit ceiling set by an allocation profile, stricter Milestone 4 rule and comparisons, three code-fact corrections"
---

# Map categories to projection and durable subscription consumers

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. Creating this plan does not implement the feature.


## Purpose / Big Picture


Implement [IR-59](../improvement-requests/map-categories-to-the-projections-that-consume-them.md).
An operator can run `projection consumers --category order`, or request
`GET /projection/consumers?category=order` from an application-embedded ops server such as
the runnable `jitsurei-ops-http` example host, and see `jitsurei-order-reporting`. A category
with no declared consumer returns a successful empty `items` array. A stream category
identifies a family of event streams; a projection consumes
those events to maintain queryable data. A projection group is the unit whose targets share
one rebuild lifecycle. Return group identities that clients can join to existing projection
status to display availability and global position distance.

The mapping describes declared input coverage in the mounted application configuration.
It does not prove a worker is running or that its decoder or handler accepts every event.
Include inline projection handlers, clearly distinguished from durable subscriptions, because
both feed read models. Support process managers and other durable subscribers when the host
supplies their actual input subscription metadata. A process manager's own journal category
is not its input category.

Use a new read command over compiled metadata. Preserve the frozen SQL status relation and
existing status JSON, including the `feeding_subscriptions` array that status page items
have carried since plan 327. No database migration, dependency upgrade, event-path
instrumentation, UI change, or publication is required. The database-only executables
`keiro-ops` and `keiro-ops-http` cannot discover compiled catalogs; the new command is
available only when an appropriate application hook is mounted, as in `jitsurei-demo ops`
and `jitsurei-ops-http`.


## Progress


- [ ] Milestone 1: A pure library lookup derives accurate projection-group consumers from the validated catalog, including Jitsurei's order group and empty results.
- [ ] Milestone 2: Explicit durable subscriber descriptions support process-manager and other subscriber inputs without inferring journal categories or changing worker execution.
- [ ] Milestone 3: Embedded CLI and HTTP expose the same bounded lookup, with Jitsurei, coverage, cursor, and missing-hook behavior verified.
- [ ] Milestone 4: Document the interface, verify runtime isolation and repository checks, and distill the durable architecture decision.

No implementation has started. The plan was revalidated on 2026-11-04 against
`9da47eb7b4bcfcc1a98fc25a6b2b14aabb797a77`; the Revision Notes at the end list what changed.
A performance review the same day, against the same commit, tightened the design
constraints and Milestone 4's measurement; the second Revision Note lists those changes.


## Surprises & Discoveries


2026-11-04 (revalidation): Plan 323 showed that a metadata-only read is not free once it is
polled over HTTP. With the ordinary `Value`-based runner, four clients each polling a
1,000-descriptor `/pm/types` response once per second raised writer p99 latency by a paired
median 5.195% (95% interval +1.019% to +8.993%). Attribution found about 1.07 MB of JSON-tree
construction and 3.5 MB of generic encoding per response. Encoding the response directly
removed the supported p99 regression; a supported writer-allocation increase of about 0.009%
remained, which the user accepted for that feature only. Evidence is retained under
`keiro/bench/results/pm-types/`. A 500-item consumers page with nested bindings is in the
same size class, so this plan now starts from the direct-encoding path (see Decision Log).

2026-11-04 (revalidation): The benchmark command in the original Concrete Steps could not
run. `keiro-ops-http/bench/InspectionInterference.hs` refuses to start without RTS statistics
(`run with +RTS -T`), and plans 323 and 327 both measured with `+RTS -N2 -T -RTS`. The harness
also seeds 10,000 projection groups for every mode whose name begins with `projection-`, so a
consumers mode must not use that prefix.

2026-11-04 (revalidation): `keiro-ops/README.md`, which the original Milestone 4 named as a
documentation target, does not exist and has no git history. The operator CLI is documented
in `docs/user/operations.md`.

2026-11-04 (revalidation): Jitsurei has no durable subscriber other than its projection
subscription. The demo drives the fulfillment process manager through an in-memory adapter
(`processManagerAdapter` in `jitsurei/app/Main.hs`, adapter name `jitsurei-fulfillment-demo`)
built from one recorded event. There is no truthful durable-subscriber description for
Jitsurei to mount.

2026-11-04 (performance review): The size of the response, not the number of items, sets
the cost of a polled read. Plan 323's retained profiles
(`keiro/bench/results/pm-types/allocation-profile.log` and `allocation-profile-v2.log`)
record 125,904 encoded bytes for 1,000 descriptors and 2,642,768 bytes allocated to encode
them directly, about 21 allocated bytes per encoded byte. With 136,016 bytes of summaries
that is about 2.78 MB per response, which four requests per second polled without a
supported regression. The generic path cost about 4.72 MB per response and produced the
supported p99 regression. Estimated from this plan's JSON shape, a consumer with one
binding encodes to about 270 bytes and Jitsurei's two-binding group to about 590. A default
100-item page is therefore about 27 to 59 KB, well under the measured point. A 500-item
page is about 134 to 294 KB, an estimated 2.8 to 6.2 MB per response, which reaches past
the cost that regressed. `--limit` bounds items, not bindings, so only the host's
1,048,576-byte response cap bounds a page, and a response at the cap would allocate an
estimated 22 MB. These are estimates; the profile in Milestone 4 replaces them.

2026-11-04 (performance review): The benchmark's writer cannot see a change to projection
code. `operation` in `keiro-ops-http/bench/InspectionInterference.hs` upserts, claims, runs,
and releases a workflow, then schedules, claims, and fires a timer. It never applies a
projection or reads a catalog. Its baseline and candidate comparisons measure interference
from the mounted HTTP surface (garbage collection, CPU, and the PostgreSQL server shared
with the writer), not the cost of an edit under `keiro/src/Keiro/Projection`.

2026-11-04 (performance review): The bootstrap that plans 323 and 327 use has little power
at five pairs. A 95% percentile interval over the median of five paired ratios lies wholly
above one only when all five ratios are adverse, and wholly below 1.01 only when all five
are. Both earlier plans ended with latency intervals that could not exclude a 1% loss. The
previous revision of this plan let such an interval pass by reporting it; plan 327, whose
rule was fixed the same day, treats it as incomplete.

2026-11-04 (performance review): Three statements in the plan did not match the code. The
catalog inventory stores sources, subscriptions, and projections as sorted lists
(`buildInventory` in `keiro/src/Keiro/Projection/Catalog.hs`), so the lookup is a join, not
a traversal that builds nothing. Only the HTTP front end calls `Ops.validateCommand` before
admission and schema verification; the CLI's `runInvocation` in `keiro-ops/src/Keiro/Ops.hs`
never calls it and relies on each runner. And `OpsResult` in
`keiro-ops/src/Keiro/Ops/Render.hs` has strict fields, so the canonical JSON value is
evaluated to its outermost constructor when the result is built; `prepareTypes` avoids
allocating the item array on the HTTP path only because it builds that object lazily.


## Decision Log


2026-10-26: Choose the request's reverse-lookup alternative, backed by the mounted catalog.
ADR-35 freezes `keiro_read.projection_group_status_v1`, including its columns; its wording
does not authorize adding a category column. The existing catalog operations hook already
carries the source information and avoids introducing a second persistent registry.

2026-10-26: Report declared consumers with explicit coverage. Missing subscription metadata
means unavailable coverage, not proof of no consumers. A successful empty result is meaningful
only within the mounted metadata sources. Do not interpret a process-manager inspector's
journal category, a checkpoint name, or a projection name as an input declaration.

2026-10-26: Keep consumer discovery pure and separate from status reads. Return stable group
and subscription identities so the console can join existing supported status/position APIs.
The lookup must not enumerate checkpoints, hydrate instances, invoke decoders, or fetch status
once per result. This preserves existing progress semantics and avoids fleet-wide SQL work.

2026-11-04: Reaffirm the reverse lookup after plan 327. That plan showed that a field can
travel beside the frozen v1 row on status page items, which is the other alternative IR-59
offers. It does not fit here: `keiro.keiro_projection_group_cursors` stores subscription
names, not source categories, so a category field on `/projection/status` would force a
database-only command to consult compiled catalog metadata that `keiro-ops` and
`keiro-ops-http` do not have. The two reads stay separate and joinable.
`feeding_subscriptions` reports the registered cursor authority from the database; this
lookup reports the declared catalog subscription from compiled configuration. They normally
agree after registration, and a client must not treat either as proof of the other.

2026-11-04: Serve the lookup through the existing direct-encoding path from the first
implementation. `Keiro.Ops.Projection` prepares the canonical `OpsResult` and an equivalent
Aeson `Encoding` from one filtered page, as `Keiro.Ops.ProcessManager.prepareTypes` does, and
`runCommandWithReadEncoding` in `keiro-ops/src/Keiro/Ops.hs` gains one case for it. Plan 323
measured the alternative as a writer regression (see Surprises & Discoveries), and ADR-53
records this path as the sanctioned cost reduction. It needs no edit in `keiro-ops-http`,
caches no response or bytes, and leaves schema verification, admission, deadlines, and the
byte cap unchanged. This changes the implementation approach, not the acceptance.

2026-11-04: Jitsurei mounts `durableConsumers = Nothing`. An explicitly empty registry would
assert that the application has no process-manager or other durable input, while its
fulfillment manager does react to order events through a demo adapter that cannot honestly
be described as a durable subscription. `Nothing` reports `durable_subscribers: false`, the
accurate statement that this source is not described. Library and ops fixtures exercise the
registry instead.

2026-11-04: Name the benchmark modes `consumers-idle`, `consumers`, `consumers-many-idle`,
and `consumers-many`, replacing the single `active-consumers` mode, to match the idle/active
pairing that plans 323 and 327 established in the harness. Fix the workload, refusal rules,
and statistical rule before sampling. No earlier acceptance is inherited: the tolerances the
user granted in plan 323 were scoped to that feature, and plan 327's performance milestone
is still open.

2026-11-04 (performance review): Keep the library changes additive. Milestones 1 and 2 add
definitions and one module. They do not edit `keiro/src/Keiro/Projection/Catalog.hs`, add
no field and no work to `ValidatedProjectionCatalog` or `validateProjectionCatalog`, and
change no existing definition in `Operations.hs`. An application that never runs the lookup
pays nothing for it, at startup or at run time. The guarantee is structural because the
HTTP harness cannot measure projection paths (see Surprises & Discoveries). If an existing
definition must change after all, the `projection` and `read-model` guards become a
required gate for this plan.

2026-11-04 (performance review): Order and deduplicate once, filter per request. Ordering,
deduplication, and the digest do not depend on the requested category. The durable registry
holds its descriptions in final order from construction, and the catalog side yields groups
in group-ID order, so a request filters and merges ordered sequences and never sorts the
combined result. A request renders and encodes only its page. A precomputed catalog index
stays optional: deriving the relation per request over a realistic catalog costs kilobytes
against a response that costs megabytes, and Milestone 4's profile reports the lookup's
share so the choice rests on a number. If an index is added, it is a lazily evaluated value
held by `ProjectionCatalogOperations` or the ops layer, never part of catalog validation.

2026-11-04 (performance review): Treat the `--limit` ceiling of 500 as provisional. The
ceiling exists to bound a page's cost, and the estimate in Surprises & Discoveries puts a
500-item page with nested bindings past the per-response cost that plan 323 measured as a
writer regression. Milestone 4's profile decides the ceiling before any paired sampling:
the largest page the large fixture can return must allocate no more per response than the
2.78 MB that plan 323's second cohort polled at the same cadence without a supported
regression. Lower the ceiling until that holds, and never raise it above 500. Plan 323's
figure is used to choose a design parameter, not as acceptance; this plan's own cohort
decides acceptance. No client depends on the ceiling yet, so it is this plan's to choose.
The default of 100 does not change.

2026-11-04 (performance review): An inconclusive interval does not complete Milestone 4.
This replaces the previous revision's rule, which reported such an interval and moved on.
A supported regression still blocks, however small. An interval whose upper endpoint is at
or above 1.01 cannot exclude a 1% loss, so it is neither a pass nor a regression: run a
ten-pair cohort, and if precision is still short, record the resolution achieved and ask
the user whether to accept at that resolution. This matches plan 327's rule and keeps the
user's plan 323 decision scoped to plan 323. The cost is that p95 and p99 will probably
need that user decision, as they did in both earlier plans. The alternative lets a
regression of several percent pass without anyone deciding to accept it.

2026-11-04 (performance review): Compare the mounted-but-idle modes with the pre-change
idle mode, not only with their own active mode. Pairing `consumers-many-idle` with
`consumers-many` cancels out whatever the mounted registry itself costs: retained heap
that every major collection copies, and a larger command parser. Milestone 4's comparison
list adds mount-only and total-effect comparisons, computed from the same trials.


## Outcomes & Retrospective



## Context and Orientation


The creation baseline is `c3c73edf2c4b246b18d6daebb856a4ddcc3745d1` (2026-10-26). The plan
was revalidated on 2026-11-04 against `9da47eb7b4bcfcc1a98fc25a6b2b14aabb797a77` with a clean
working tree. Fifty-one commits landed in between, including the 0.22.0.0 and 0.23.0.0
releases: every package is now at 0.23.0.0, and unreleased work accumulates under each
changelog's `[Unreleased]` heading. Recheck `git status --short` and `git log` before
implementation, record the implementation baseline actually used, and preserve unrelated
changes. This is a standalone follow-up to IR-59, not a new child of an existing MasterPlan.

Five sibling plans touch the files this plan edits.
[Plan 323](323-list-mounted-process-managers-without-runtime-performance-regressions.md) is
complete: `pm types` and `GET /pm/types` list mounted process managers, and it added the
direct-encoding path described below.
[Plan 327](327-name-the-feeding-subscriptions-on-projection-status-pages-without-runtime-performance-regressions.md)
added `feeding_subscriptions` to projection status page items; its code is merged, while its
performance and documentation milestones remain open.
[Plan 328](328-serve-the-jitsurei-aggregate-and-process-manager-hooks-from-a-runnable-keiro-ops-http-host.md)
is complete: it moved Jitsurei's hook record into the library and added the runnable
`jitsurei-ops-http` host.
[Plan 329](329-expose-keiki-register-values-through-the-existing-inspection-apis.md) is
complete: it mounted a `credit-limit` aggregate whose stream category is `creditLimit`.
[Plan 325](325-count-workflow-instances-by-status-class-without-runtime-performance-regressions.md)
is planned and unimplemented; it will measure with the same benchmark harness.

`keiro/src/Keiro/Projection/Catalog.hs` owns the validated, typed configuration. Its
`CatalogInventory` contains `InventoryProjection` records with a group ID, source ID, and
handlers; `InventorySource` associates a source ID with `AllStreams` or `CategorySource`;
`InventorySubscription` associates a subscription ID with its actual subscription name and
source ID. `InventoryInlineHandler` and `InventoryAsyncHandler` distinguish execution during
the command transaction from later durable delivery. A durable subscription retains its
progress across process restarts. Unreferenced catalog sources and subscriptions are not
consumers: derive the relation through the handlers of each projection.

`keiro/src/Keiro/Projection/Catalog/Operations.hs` wraps a validated catalog in
`ProjectionCatalogOperations` and provides pure reports such as `catalogInventoryReport`.
It is the appropriate exported boundary for the projection lookup. The inventory and its
fingerprints already encode source and handler identity; a derived read must not change
catalog fingerprints, group slices, replay identities, or existing inventory JSON contracts.

`keiro/src/Keiro/ReadModel/Rebuild/Group.hs` registers lifecycle and cursor-authority rows.
Its `cursorAuthorityParams` retains subscription names, not source categories. A database
checkpoint inventory therefore cannot reconstruct the desired relation. The frozen status
reader lives in `keiro/src/Keiro/ReadModel/Rebuild/Status.hs`, exported through
`keiro/src/Keiro/ReadModel/Rebuild.hs`. `ProjectionGroupStatusV1` is still the exact mirror
of the frozen relation, and `projectionGroupStatusJson` in
`keiro-ops/src/Keiro/Ops/Projection.hs` still renders it. Since plan 327,
`listProjectionGroupStatusesPage` returns `ProjectionGroupStatusRow` items: the v1 record
under `status` plus `feedingSubscriptions`, rendered by `projectionGroupStatusRowJson`. Those
names are the registered cursor authority read from `keiro.keiro_projection_group_cursors`:
sorted checkpoint names for a checkpoint group, an empty list for an inline-only group, and
an empty list meaning unknown for an unmanaged group. Jitsurei's reporting group reports
`["jitsurei-order-audit-subscription"]`. This plan changes none of these.

`keiro-ops/src/Keiro/Ops/Embed.hs` defines `AppHooks` with six optional fields
(`workflowResume`, `timerFire`, `replayAudit`, `projectionCatalog`, `aggregates`, and
`processManagers`); `emptyAppHooks` sets them all to `Nothing`.
`keiro-ops/src/Keiro/Ops.hs` owns hook-dependent grammar and dispatch;
`keiro-ops/src/Keiro/Ops/Projection.hs` currently exposes `status`, `position`, and
`prune-dedup`, and its parser and runner take no hooks.
`keiro-ops-http/src/Keiro/Ops/Http/Route.hs` derives routes from that grammar,
and `keiro-ops-http/src/Keiro/Ops/Http/Application.hs` applies admission, schema verification,
deadlines, and response-byte limits. A pure handler still incurs HTTP's schema check.
`keiro/src/Keiro/Inspection/Cursor.hs` supplies bounded, kind-tagged continuation tokens.
A continuation token is an opaque value that tells the same read where to resume.

`Application.hs` runs every command through `runCommandWithReadEncoding` from
`keiro-ops/src/Keiro/Ops.hs`, passing a byte-bounded encoder (`encodeBoundedEncoding` in
`keiro-ops-http/src/Keiro/Ops/Http/Budget.hs`). An Aeson `Encoding` describes JSON bytes
directly, without first building a JSON `Value` tree. Today only `pm types` uses it: the ops
layer prepares a canonical `OpsResult` and an equivalent `Encoding` (`prepareTypes` in
`keiro-ops/src/Keiro/Ops/ProcessManager.hs`) and HTTP serves the direct bytes. Every other
command falls through to the ordinary runner. `keiro-ops-http/src/Keiro/Ops/Http/Host.hs`
exports `mainWithHooks` and `withHost`, the lifecycle shared by the standalone executable and
application hosts.

One HTTP read pays its costs in a fixed order, which decides where this plan may put work.
`opsApplicationPrepared` in `Application.hs` translates and parses the request first,
reusing a parsed command from a 64-entry first-in-first-out cache keyed by the complete
argument list, so each distinct category, limit, and cursor is its own entry. It then calls
`Ops.validateCommand` on every request, and twice on a cache miss, before admission. That
work has no slot and no deadline, so it must stay small and need no hook. Only then does
the request take one of `maxConcurrentReads` slots (four by default, with no queue), verify
the schema on a pooled inspection connection, run the command under `readDeadlineSeconds`
(five by default), and bound the body at `maxResponseBytes` (1,048,576 by default). The CLI
is different: `runInvocation` in `keiro-ops/src/Keiro/Ops.hs` verifies the schema and runs
the command without calling `Ops.validateCommand`, so a runner must validate its own
arguments, as `ProcessManager.runCommand` does. The writer and the inspection handlers
share one garbage-collected heap, so what a handler allocates can appear as writer latency;
that is the interference plan 323 measured.

`keiro/src/Keiro/ProcessManager/Inspect.hs` describes how to read manager journal streams.
`keiro/src/Keiro/ProcessManager.hs` receives an abstract adapter in `runProcessManagerWorker`;
that adapter need not reveal its source filter. Thus current manager inspection metadata
cannot automatically supply input consumption. Preserve the existing inspector constructors.
Plan 323 added manager discovery in this module (`listProcessManagerTypes` and
`ProcessManagerTypeSummary`). The `category` it reports is the manager's journal category, so
it is neither a prerequisite nor a source of input categories. Its measurement scripts
(`scripts/measure-pm-types.sh` and `scripts/analyze-pm-types.py`) and plan 327's
(`scripts/measure-projection-feeding-subscriptions.sh` and
`scripts/analyze-projection-feeding-subscriptions.py`) are precedents to read, not files to
modify.

`jitsurei/src/Jitsurei/ReadModels.hs` declares the exact source category `order` (source ID
`jitsurei-order-events`), a mixed inline/async group `jitsurei-order-reporting`, and the
existing `orderCatalogOperations`. The group has two projections: `jitsurei-order-summary`
with the inline handler `jitsurei-order-summary-inline`, and `jitsurei-order-audit` with the
async handler `jitsurei-order-audit-async` on a subscription whose catalog ID and actual name
are both `jitsurei-order-audit-subscription`. `jitsurei/src/Jitsurei/Ops.hs` defines
`jitsureiOpsHooks`, the one complete hook record shared by `jitsurei-demo ops`
(`jitsurei/app/Main.hs`) and the `jitsurei-ops-http` executable in the internal package
`jitsurei/ops-http`. `jitsurei/src/Jitsurei/Inspection.hs` mounts the fulfillment manager
with journal category `fulfillment`; that declaration alone does not prove a subscription to
`fulfillment` or `order`. The same module mounts the aggregates `order`, `incident`, and
`credit-limit`. The last one has the stream category `creditLimit` and no projection, which
makes it a realistic empty-result case; note that the lookup takes the category, not the
aggregate's mounted name.

Package dependencies constrain where tests live. `keiro` and `keiro-ops` do not depend on
Jitsurei, so their suites use their own fixtures. `jitsurei-test` depends on `keiro-ops`, and
the `keiro-ops-http` test suite and benchmark already depend on `jitsurei`. The reverse
dependency is impossible because Cabal rejects the package cycle, which is why the host and
its suite `jitsurei-ops-http-test` live in `jitsurei/ops-http`. `just verify` runs all of
these suites.

Relevant ADRs were discovered by scanning local filenames and headings.
[ADR-26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
makes the validated catalog the single authority for projection sources and handlers.
[ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
requires thin ops adapters over owner APIs, explicit compiled-code hooks, and the term
“global position distance,” never event lag, for cursor subtraction.
[ADR-35](../adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md)
freezes the SQL status contract and distinguishes serving from candidate progress. Its
2026-11-04 amendment records that status page items carry `feeding_subscriptions` beside the
unextended v1 row.
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
requires bounded inspection and measured runtime isolation.
[ADR-53](../adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md)
requires shared CLI/HTTP grammar and unchanged transport resource/schema policies. Its
amendments record the shared application host, the rule that a metadata-only handler still
pays HTTP schema verification on every request, and the direct-encoding path as a cost
reduction that is not an exemption from measured isolation.
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
states that a failed or inconclusive benchmark comparison is not acceptance.

Mori located the upstream package at `mori://shinzui/kiroku/packages/kiroku-store` (it
resolved again on 2026-11-04, and the project now requires `kiroku-store ^>=0.13.0.1`); its
local source describes subscription targets and checkpoints. The registry still has no
curated docs for that project. No new upstream API is required here. In particular, do not adopt an
API seen only in the local corpus without checking the package registry and upstream release
tags against the project's resolved dependency. Keep cross-repository references canonical.


## Plan of Work


### Milestone 1: Derive the projection relation in the library


Add a pure `projectionConsumers` operation and exported result types in
`keiro/src/Keiro/Projection/Catalog/Operations.hs`. Start with one actual
`jitsureiProjectionCatalog` -> library lookup -> group ID test in `jitsurei/test/Main.hs`,
in the `Jitsurei read model` group beside the existing feeding-subscription example.
This is the early proof that the real catalog produces the required consumer. Then expand
`keiro/test/CatalogOperationsSpec.hs` with multi-source, mixed-delivery, and all-stream cases.
The validated catalog already retains its inventory (`catalogInventory` is a field read) and
its fingerprint, so the lookup rebuilds no catalog. The inventory keeps sources,
subscriptions, and projections as sorted lists rather than maps, so resolving each
projection's source and each async handler's subscription is a join the lookup must
perform. Do it through maps or one ordered merge, so the cost stays near-linear in the
inventory. Never search a list once per projection, and never build inventory JSON to
answer the question.

This milestone only adds definitions to `Operations.hs`. It does not edit
`keiro/src/Keiro/Projection/Catalog.hs`, adds no field and no work to
`ValidatedProjectionCatalog` or `validateProjectionCatalog`, and changes no existing
definition, so an application that never runs the lookup pays nothing for it. Milestone 4
checks this by diff, because no benchmark in this plan exercises projection code.

Join projections to their sources and their declared handlers. For async handlers, retain
both the catalog subscription ID and actual subscription name, resolving the subscription's
source. Group results once per rebuild-group ID, retaining nested matching projection/handler
bindings so a client can explain why the group matched. Include inline bindings with no
fabricated subscription. Match exact category text case-sensitively; all-stream bindings
match every valid category. Deduplicate bindings, order groups by ID and bindings by stable
projection/handler/subscription identity, and never use declaration order as authority.

Only include bindings that match the requested category. If a group contains consumers of
both `order` and `invoice`, an `order` lookup must not claim its invoice-only handler consumes
orders. Expose each matching binding's actual scope, including an explicit all-categories
variant rather than an empty category list with ambiguous meaning. State that the relation
is based on source selection, not an analysis of opaque decoder/handler code.

Acceptance is the required Jitsurei result, a successful empty result for an unmatched
category, and invariant results under catalog declaration reordering. For Jitsurei, `order`
returns the single group `jitsurei-order-reporting` with two bindings in this order:
projection `jitsurei-order-audit` with the async handler `jitsurei-order-audit-async` and
subscription ID and name `jitsurei-order-audit-subscription`, then projection
`jitsurei-order-summary` with the inline handler `jitsurei-order-summary-inline` and no
subscription. `creditLimit` returns no group. Include a source and
subscription that no handler references to prove they do not create false consumers. Existing
catalog fingerprint and inventory serialization tests must retain their values.


### Milestone 2: Describe other durable inputs explicitly


Create `keiro/src/Keiro/Inspection/Consumers.hs` and expose it in `keiro/keiro.cabal`.
Provide an opaque validated `DurableConsumerRegistry` built from data-only descriptions.
A description carries consumer kind (`process_manager` or `durable_subscriber`), consumer
name, actual subscription name, and input scope. Support exact categories, all categories,
and a literal namespace scope: namespace `pm` matches `pm` and `pm:orders`, never `pmm`.
This is Keiro-owned descriptive metadata; it must not depend on an unreleased upstream target
constructor. Preserve exact text without wildcard expansion or case folding. Reject empty
identities and empty or surrounding-whitespace category/namespace declarations at construction.
The descriptor does not contain a callback, decoder, event stream, or running-worker handle.

Validate conflicting scopes for one subscription name rather than silently selecting one.
Coalesce exact duplicates deterministically. Allow one declared consumer to have several
subscriptions and one shared subscription to name several consumers, with stable binding
identity. The host must derive descriptions from the same configuration values it uses to
construct the worker; document that metadata cannot prove an opaque adapter's behavior.
An unavailable or custom opaque scope must be omitted from the known registry, with the
coverage limitation documented; do not approximate it by a journal category.

Construction is where the registry does its work. It already validates, coalesces, and
orders, so keep the descriptions inside the registry in their final
`(kind, name, subscription name)` order and compute the inventory digest there. A lookup
is then one pass that filters by category and neither sorts nor deduplicates. The registry
retains only the descriptions and that digest; it caches no lookup result.

Add `durableConsumers :: Maybe DurableConsumerRegistry` to `AppHooks` in
`keiro-ops/src/Keiro/Ops/Embed.hs`, defaulting to `Nothing` in `emptyAppHooks`. Three places
construct the complete record and must name the new field: `emptyAppHooks` itself,
`jitsureiOpsHooks` in `jitsurei/src/Jitsurei/Ops.hs`, and `embeddedHooks` in
`keiro-ops/test/Main.hs`. Every other site updates `emptyAppHooks` and needs no edit; confirm
with `rg AppHooks` in case another construction has appeared. `Just` an empty validated
registry means the host explicitly provided an empty set; `Nothing` means this source is
unavailable. Jitsurei sets `Nothing` (see Decision Log), which `jitsurei-demo ops` and
`jitsurei-ops-http` both inherit from the shared record. The registry is immutable
mount configuration. No runtime registration writes, background tasks, per-event changes,
new inspector fields, or event/snapshot scans are involved.

Test this boundary in a new `keiro/test/ConsumerInspectionSpec.hs`, wired into
`keiro/test/Main.hs` and the Cabal test modules. Use a manager whose journal category is
`fulfillment` but whose declared input is `order`: the order lookup returns it and the
fulfillment lookup does not. Add an ordinary durable subscriber, namespace boundary cases,
all-stream coverage, conflicts, and duplicates. Exercise pure functions with no store effect.
Do not add a fictional durable worker to Jitsurei just to populate its example.


### Milestone 3: Expose one bounded CLI and HTTP contract


In `keiro-ops/src/Keiro/Ops/Projection.hs`, add a `Consumers` command accepting required
`--category`, optional `--limit` (default 100, range 1 through 500), and optional `--after`.
The ceiling of 500 is provisional: Milestone 4's profile may lower it before the paired
measurement, and whatever value ships is the one the parser, the validation, the tests, and
the documentation all state.
Validate nonempty category text without trimming/case folding, and reject surrounding
whitespace. Classify it read-only. Preserve the current exported parser and runner as
no-hook wrappers if adding hook-aware variants is needed, so existing direct callers of
`Projection.commandParser` and `Projection.runCommand` remain valid, and leave the exported
`projectionGroupStatusJson` and `projectionGroupStatusRowJson` encoders untouched. The
hook-aware variants receive only the optional catalog and durable registry they need,
avoiding an import cycle with `Keiro.Ops.Embed`. Checks that need no hook (category text,
limit range, and the cursor's shape, kind, size, and category binding) belong in
`Projection.validateCommand`. The HTTP front end runs it on every request before admission
and schema work, outside any slot or deadline, so it must stay bounded by the 4,096-byte
cursor limit and touch no mounted metadata. The CLI does not call it, so the `Consumers`
runner applies the same validation first, as `ProcessManager.runCommand` does; without
that, `--limit 0` and a malformed cursor would reach the lookup from the CLI.
The inventory-identity check needs the mounted metadata and runs first in the runner,
inside the admitted, deadline-bounded part of an HTTP request.

Update `keiro-ops/src/Keiro/Ops.hs` to use those variants. Mount `consumers` when either
`projectionCatalog` or `durableConsumers` is `Just`; retain all database-only projection
commands regardless of those hooks. With neither hook, normal parser/HTTP unsupported-command
behavior is expected, not a successful assertion that the whole database has no consumers.
With an explicitly empty mounted source, return success and `items: []`.

Serve HTTP through the direct-encoding path. Export from `Keiro.Ops.Projection` a function
that turns one filtered page into both the canonical `OpsResult` and an equivalent Aeson
`Encoding`, in the manner of `prepareTypes` in `keiro-ops/src/Keiro/Ops/ProcessManager.hs`.
Add one case to `runCommandWithReadEncoding` in `keiro-ops/src/Keiro/Ops.hs` that hands the
encoding to the supplied bounded encoder and reports `inspection_result_too_large` when the
encoder refuses. `keiro-ops-http/src/Keiro/Ops/Http/Application.hs` already routes every
command through that function, so the transport needs no edit. The CLI and `runCommand` keep
using the canonical result. Cache neither pages nor bytes between requests.

Three details keep the direct path as cheap as the `pm types` one. First, one request runs
the lookup once: the new case in `runCommandWithReadEncoding` calls the prepare function
and does not also call `runCommand`. Second, take the page (at most `limit` items plus the
lookahead item) before rendering anything, so the human rows, the canonical value, and the
encoding are all built from the page and never from the full filtered sequence. Third,
leave the canonical value unevaluated on the HTTP path. `OpsResult` has strict fields, and
Aeson's `object` builds its key map strictly, so writing the envelope with `object` would
allocate the whole item array for a value HTTP never reads. `prepareTypes` avoids this by
building the object with `KeyMap.fromMap` over a lazy `Data.Map.Lazy` map; build the
consumers envelope the same way, so that only the CLI and tests that read `jsonValue` pay
for it.

Combine the library results in a deterministic sequence ordered by `(kind, name)`, using
group ID as the name/key of a `projection_group` item. The kinds order as
`durable_subscriber`, `process_manager`, `projection_group`, and each source already yields
its items in order, so combining them is a merge of ordered sequences, not a sort of the
combined result. Page after filtering, with one lookahead
item and exclusive continuation. Bind cursors to version `keiro/category-consumers/v1`, the
exact category, the immutable metadata inventory identity, and the last item key. Reject
wrong-kind, changed-category, changed-inventory, malformed, and oversized tokens before any
handler work. Reuse `encodeCursorBounded`/`decodeCursor`; never return a token that the next
read would reject. This is pagination over finite in-memory metadata, not a claim that a
page limit bounds catalog traversal cost. Avoid constructing or encoding full inventory JSON
on each request merely to filter it or compute its identity. The catalog's identity is the
fingerprint the validated catalog already stores (`catalogFingerprintText` over
`catalogFingerprint`); the durable registry computes its own digest once at construction.
Any further derived index is immutable mount configuration computed once, never a
per-request or per-response cache, and Milestone 4 measures its mount cost.

Return a versioned JSON envelope with `schema: "keiro/category-consumers/v1"` (the version
string the cursor also binds), `category`, `scope: "mounted_configuration"`,
`coverage: {"projection_catalog": true|false, "durable_subscribers": true|false}`, and `items`;
include `next_cursor` only when another result exists. Each item has `kind`, `name`, nullable
`group_id`, and `bindings`. Projection bindings contain `projection_id`, `handler_name`,
`delivery` (`inline` or `subscription`), nullable `subscription_id`, nullable
`subscription_name`, and `source`. Other bindings use null projection/catalog-subscription
IDs, `delivery: "subscription"`, and their actual subscription name. `source` is one of
`{"kind":"all"}`, `{"kind":"category","category":"order"}`, or
`{"kind":"namespace","namespace":"pm"}`. Nulls describe inapplicable identities, not an
unknown source. Human output shows kind, consumer name, group, subscription, and source.

Do not add progress values to this response. Clients join `group_id` to `/projection/status`,
whose items also list the group's registered `feeding_subscriptions`, and pass subscription
names to `/projection/position`; missing checkpoints remain unknown there. A binding's
`subscription_name` is the catalog's declaration, while `feeding_subscriptions` is what
registration recorded in the database. Do not read the cursor-authority table here to
reconcile them.
Mapping remains visible before any event or checkpoint exists. An unregistered catalog group
can appear as declared even if it has no status row; the client must not infer liveness.

Add parser, rendering, hook-availability, pagination, and no-store-access coverage in
`keiro-ops/test/Main.hs`, using that suite's own fixtures because `keiro-ops` does not depend
on Jitsurei. For the no-store-access proof, follow the `pm types` example in
`keiro-ops/test/ReactionInspectionSpec.hs`: build the environment around its `unusable`
store, show that a real read through that store throws, then run and fully render the
lookup. A released pool is not a valid sentinel, because the pool reconnects. As that
example also does, call `Ops.runCommandWithReadEncoding` twice with an encoder that counts
its calls and a header cache whose encoder fails: each request must encode afresh, the
bytes must decode to the canonical value, and nothing may enter the header cache. Add the
real-catalog runner example to `jitsurei/test/Main.hs`, which already drives `Ops.runCommand`
with Jitsurei hooks.

In `keiro-ops-http/test/Main.hs`, whose suite already depends on the local Jitsurei library,
mount the real Jitsurei catalog and exercise the actual WAI application for
`/projection/consumers?category=order`. Compare its decoded response to the ops runner,
allowing only transport-owned metadata differences, and assert that the direct encoding
decodes to the same JSON as the canonical value; key order is not a contract. Model the
connection-use assertions on that file's `process-manager discovery database boundary`
group: an invalid request borrows no connection, and a valid one costs exactly the schema
verification that any metadata route costs. Confirm schema drift, invalid input, admission,
and response-byte handling retain their policies. Add one example to
`jitsurei/ops-http/test/Main.hs` that requests the route from the listening host started by
`withHost` with the shared `jitsureiOpsHooks`. No route registry or production HTTP transport
fork is needed. Test an oversized single item explicitly; return the existing
result-too-large behavior (HTTP 413 with `inspection_result_too_large`) rather than silently
truncating bindings.


### Milestone 4: Document and verify the completed behavior


Document the new CLI/HTTP query, embedded-only availability, coverage flags, all-stream and
namespace semantics, and status joining in `docs/user/operations.md` (beside its
`Projection status pages` section and its `pm types` example),
`docs/guides/serve-keiro-ops-over-http.md` (its `See the hook-gated routes locally` section
already drives `jitsurei-ops-http`), and `docs/user/read-models-and-projections.md` (its
`Inspect And Operate A Catalog` section). Include an example constructing durable
descriptions from actual worker configuration and explain why `pm types` or a manager's
journal category cannot substitute for that description. State the measured operating
envelope beside the query: the largest response size and the polling rate that this
milestone measured; that the lookup answers one category per request, so a screen listing
many categories issues one request each; that every request takes one of the host's
admission slots and one schema verification, like any other read; and that a response
larger than the measured size is permitted up to the response-byte cap but was not
measured. Use existing documentation bundle
metadata/log conventions when changing those files. Add `[Unreleased]` entries to
`keiro/CHANGELOG.md`, `keiro-ops/CHANGELOG.md`, and `keiro-ops-http/CHANGELOG.md`. The new
`AppHooks` field breaks applications that construct the record directly instead of updating
`emptyAppHooks`; record it under Breaking Changes in the `keiro-ops` changelog.

Measure the new route with the existing harness
`keiro-ops-http/bench/InspectionInterference.hs` and its client module
`keiro-ops-http/bench/InspectionClients.hs`. The harness now has thirteen modes: `disabled`,
`idle`, `active-shared`, `active-distinct`, `slow-reader`, `churn`, `pm-types-idle`,
`pm-types`, `pm-types-many-idle`, `pm-types-many`, `projection-idle`, `projection-poll`, and
`projection-feed`. Preserve every existing meaning, and do not change the writer loop or its
clocks. Add four modes. `consumers-idle` and `consumers` mount the Jitsurei catalog plus a
small durable registry; `consumers-many-idle` and `consumers-many` mount the Jitsurei
catalog plus a deterministic large registry. The large registry has at least 1,000
consumers that all declare one shared category, each through two subscriptions so that
every item carries two bindings, plus consumers in distinct categories, one namespace
scope, and one all-categories scope. A request for the shared category at the limit ceiling
therefore returns a full page, and so does its continuation. Each idle mode mounts
the same hooks with no polling, so each active mode has a matched control. Never begin a
mode name with `projection-`, because the harness seeds 10,000 projection groups for that
prefix. Extend `withMount`, `inspectionModes`, and `pollingShape` in the harness, and add an
HTTP-only client branch, with no WebSocket startup, that warms the route and then polls
from four staggered clients at one request per second each. The client validates item
counts and fields, counts successes separately from refusals, and fails if the intended
load disappears.

Fix the request mix before sampling. In `consumers`, the clients rotate through a matching
category, an absent category, and a `limit=1` first page followed by its continuation. In
`consumers-many`, every request returns a full page at the ceiling: the clients alternate
between the shared category's first page and its continuation. That puts the heaviest
response the fixture can produce on every poll, as plan 323 polled its whole list. Both
mixes use fewer than 64 distinct request targets, so parsing is served from the parse cache
after warm-up. Say so in the evidence: a client that cycles through more targets than that
pays one command parse per request, which this cohort does not measure.

Measure in two steps. A store-free allocation profile comes first, because it is cheap and
decides the limit ceiling. The paired writer cohort comes second and decides acceptance.
The profile matters because response size sets the cost of a polled read (see Surprises &
Discoveries): plan 323 polled 2.78 MB of allocation per response without a supported
regression and 4.72 MB with one, and the lookup and paging are small beside the encoding.

Add the profile to the harness executable as a leading `--profile-consumers` argument,
dispatched in `main` beside `--clients` and inside the same
`#ifndef KEIRO_INSPECTION_BASELINE` guard. Implement it in a new module
`keiro-ops-http/bench/ConsumersProfile.hs`, listed under the benchmark's `other-modules` in
`keiro-ops-http/keiro-ops-http.cabal`. It opens no database and reuses the hooks the four
modes mount, so it measures the same fixture the cohort polls. For each request the clients
send, it prints the encoded byte count and the bytes allocated (read from
`getAllocationCounter` after `performMajorGC`, as
`keiro/bench/results/pm-types/ProfileAllocation.hs` does) by four pieces of work: the
lookup and paging alone; the direct encoding; the complete direct path, which is the
prepare function from Milestone 3 followed by `encodeBoundedEncoding` at the default
1,048,576-byte cap; and, for contrast, the fully forced canonical value with generic
encoding. It also prints what constructing the large registry allocates and the
post-major-collection live bytes the registry retains, which together are the mount cost.
It exits nonzero if the direct bytes do not decode to the canonical value. If a generated
multi-group catalog is practical, add it here, where it needs no database; the cohort does
not require one.

Read three things from the profile, and record its output under
`keiro/bench/results/category-consumers/`. The complete direct path should allocate about
what the lookup and the direct encoding allocate together; a visible excess means the
canonical value is being built on the HTTP path, which Milestone 3 forbids. The lookup and
paging should be a small share of the complete path; if they are not, hoist the
category-independent work to construction as the Decision Log allows. And the heaviest
request, the full page at the ceiling in `consumers-many`, must allocate no more than
2.78 MB on the complete direct path. If it allocates more, lower the `--limit` ceiling
until it does not, record the chosen ceiling and the profile in the Decision Log, and only
then start the cohort. This chooses a design parameter; it is not acceptance.

Before editing runtime code, preserve the implementation baseline in its own detached
worktree and build its harness binary. The baseline has no successful
`/projection/consumers` route, so never compare its error responses with candidate
successes as equivalent work. Choose one fixed offered writer rate from a measured
saturation control and keep it for every comparison. Run at least five alternating pairs,
twenty seconds per trial, with `+RTS -N2 -T -RTS`. Drive the pairs with a new script
`scripts/measure-category-consumers.sh`, modeled on `scripts/measure-pm-types.sh`, and
analyze them with a new `scripts/analyze-category-consumers.py`, modeled on
`scripts/analyze-pm-types.py` with its own fixed seed. The analyzer reports each metric's
paired median ratio and a fixed-seed 95% percentile bootstrap interval over whole trial
pairs, never over individual writer operations.

Each pair runs twelve trials and yields ten comparisons. `disabled` and `capacity` compare
the baseline with the candidate with nothing mounted, paced and at saturation, and `idle`
compares them with empty hooks mounted; these three isolate the code change. `same-source`
runs the baseline's idle mode twice and characterizes noise. `mount` and `mount-many`
compare the baseline's idle mode with `consumers-idle` and `consumers-many-idle`; they
isolate what mounting the catalog and the registry costs when nothing is requested.
`polling` and `polling-many` compare each idle mode with its active mode and isolate
successful polling. `versus-prechange` and `many-versus-prechange` compare the baseline's
idle mode with each active mode and give the total effect. Record the fixture cardinality,
response sizes, request mix, polling cadence, exact source revisions, binary hashes,
compiler/options, writer rate, and raw results under
`keiro/bench/results/category-consumers/`. Measure writer-thread allocation per operation,
throughput, p95/p99 latency, and retained heap after clients stop; do not divide
combined-process allocation by writer completions and call it writer cost.

The acceptance rule is fixed here, before sampling. For every comparison and each of the
four writer metrics, a ratio above one means worse (throughput is inverted). An interval
wholly above one is a supported regression and blocks completion, however small. An
interval whose upper endpoint is at or above 1.01 cannot exclude a 1% loss: it is
inconclusive, and it does not complete this milestone either. Only an interval that
includes or lies below one and ends below 1.01 passes, and the same-source control must
itself resolve 1% or the cohort resolves nothing. The 1% is a resolution requirement,
never an allowance. Five pairs is a minimum: at five pairs the bootstrap supports a
regression only when all five ratios are adverse. When any comparison is inconclusive, run
a fresh ten-pair cohort on the same binaries at the same rate, keep the first cohort as
evidence, and decide on the ten-pair cohort alone. If that is still inconclusive, record
the resolution it achieved beside the same-source spread, stop, and ask the user whether to
accept at that resolution. If a supported regression survives investigation, remove its
cause (for a page-size effect, lower the `--limit` ceiling, then repeat the profile and the
cohort) or stop and ask the user. Do not waive it, and do not complete the milestone on an
inconclusive interval without the user's decision.

Add a retention run of at least 60 seconds for each active mode. Post-major-collection
live bytes must level off instead of growing with completed operations, and active threads
and feed resources must return to their mounted-idle values after the clients leave. The
parse cache holds at most 64 argument lists, so the expected shape is a plateau reached
within the run, not zero growth from the first request.

Preserve every trial; failed requests or missed offered load invalidate a comparison. A
cohort sampled while other builds, tests, or benchmarks were running is diagnostic only:
plan 327 had to set aside cohorts for that reason, so record what else was running and
repeat on a quiet machine. Investigate failures instead of declaring a read-only
implementation isolated. Run benchmarks serially after compilation, and coordinate with
plan 327's pending quiet-machine repeat and any plan 325 measurements.

The harness cannot observe library paths, because its writer runs workflow and timer
operations and no projection code. Those paths are protected by scope and checked by diff.
At completion, `git diff --stat` from the implementation baseline over `keiro/src` must
list only `keiro/src/Keiro/Projection/Catalog/Operations.hs` and the new
`keiro/src/Keiro/Inspection/Consumers.hs`, and the `Operations.hs` diff must remove nothing
outside its import and export lists. If an existing definition had to change, run
`just bench-regression projection read-model` on a quiet machine in the baseline worktree
and on the candidate, and record both logs. Those two guards exercise projection
application and read-model paths against committed baselines with a 25% ceiling, which is
coarse, so also record why the changed definition is not on a per-event path. The other
four guards (`producer-identity`, `outbox`, `inbox`, `command`) and `just release-gate`
measure paths this plan does not touch. A passing gate is never isolation evidence for
this route.

Acceptance for this milestone is therefore five things, all on the final candidate: the
profile's three readings hold; no comparison is a supported regression; every comparison
passes or the user has accepted its recorded resolution; both retention runs level off and
clean up; and the diff-scope check passes or the two guards were run and recorded.

Run the focused suites, build all components, and pass `just verify` in the Nix shell.
At completion, follow `agents/skills/exec-plan/ADR.md`: inspect `mori show --full` and the
profile-governed ADR bundle before writing. Update ADR-28 with the `durableConsumers` hook
and the compiled consumer-metadata boundary (its closing section records the
`processManagers` hook the same way), extend ADR-53's metadata-read paragraph to name this
read beside `pm types`, and reference the preserved ADR-35 contract. If a separate decision
record is needed, allocate its ID through OKF, never filename counting. Update bundle logs
and run strict ADR validation.

IR-59 is `proposed` and already links this plan. Following the bundle's current practice
(IR-57 under plan 327 and IR-55 under plan 328), mark it `accepted` with a bundle-log entry
when implementation begins. Mark it `completed`, with a resolution, only after every
acceptance in this plan has passed, including measured isolation; functional tests alone do
not complete it.


## Concrete Steps


Run all verification from `/Users/shinzui/Keikaku/bokuno/keiro` through the Nix development
shell. Always enter the shell from the repository root: its hook places the PostgreSQL data
directory under the current directory, so entering from a package directory initializes a
stray cluster there. The focused PostgreSQL suites use repository test-support fixtures, not
a production database. Establish the baseline and check solver availability before broad DSL
verification:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git status --short
git rev-parse HEAD
nix develop -c z3 --version
nix develop -c cabal test keiro-test keiro-ops-test keiro-ops-http-test jitsurei-test jitsurei-ops-http-test --test-show-details=direct
```

Before editing any runtime source, preserve that commit for Milestone 4's controls in a
detached worktree of its own, and build its harness binary:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git worktree add --detach ../keiro-category-consumers-baseline "$(git rev-parse HEAD)"
cd ../keiro-category-consumers-baseline
nix develop -c cabal build bench:inspection-interference --enable-benchmarks
nix develop -c cabal list-bin bench:inspection-interference
cd ../keiro
```

Save the printed path. If the worktree already exists, verify its commit and reuse it; never
reset it. The sibling worktrees `../keiro-pm-types-baseline` and
`../keiro-feeding-subscriptions-baseline` belong to plans 323 and 327; do not reuse, reset, or
remove them.

After each corresponding milestone, run the focused suites above. Expect all examples to
pass, including the newly named `category consumers` groups in the core, ops, HTTP, host, and
Jitsurei suites. Before final acceptance run:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c just verify
nix develop -c git diff --check
```

For a manual check against a disposable local Jitsurei database, initialize the example
schema with the existing recipe and invoke its already-mounted catalog:

```bash
nix develop -c just jitsurei-migrate
nix develop -c cabal run -v0 jitsurei-demo -- ops --database-url 'host=db dbname=jitsurei' --json projection consumers --category order
nix develop -c cabal run -v0 jitsurei-demo -- ops --database-url 'host=db dbname=jitsurei' --json projection consumers --category creditLimit
nix develop -c cabal run -v0 jitsurei-demo -- ops --database-url 'host=db dbname=jitsurei' --json projection consumers --category ir59-unused-category
```

The commands use the recipe's default socket `db`, database `jitsurei`, and local user.
If the recipe is configured differently, pass that same connection with `--database-url`;
the embedded `ops` parser does not read the demo's `PG_CONNECTION_STRING`. The first response
decodes to this object (key order is not a contract):

```json
{
  "schema": "keiro/category-consumers/v1",
  "category": "order",
  "scope": "mounted_configuration",
  "coverage": {"projection_catalog": true, "durable_subscribers": false},
  "items": [
    {
      "kind": "projection_group",
      "name": "jitsurei-order-reporting",
      "group_id": "jitsurei-order-reporting",
      "bindings": [
        {
          "projection_id": "jitsurei-order-audit",
          "handler_name": "jitsurei-order-audit-async",
          "delivery": "subscription",
          "subscription_id": "jitsurei-order-audit-subscription",
          "subscription_name": "jitsurei-order-audit-subscription",
          "source": {"kind": "category", "category": "order"}
        },
        {
          "projection_id": "jitsurei-order-summary",
          "handler_name": "jitsurei-order-summary-inline",
          "delivery": "inline",
          "subscription_id": null,
          "subscription_name": null,
          "source": {"kind": "category", "category": "order"}
        }
      ]
    }
  ]
}
```

The second and third have the same `schema`, `scope`, and `coverage`, their own `category`,
`items: []`, and no `next_cursor`. `creditLimit` is the stream category of the mounted
`credit-limit` aggregate, which no projection reads. All three exit successfully. No event
needs to be appended to make the mapping appear.

The same hooks serve HTTP. Start the example host in one terminal and query it from another;
if port 9092 is occupied, append `--port N` to the recipe and use that port:

```bash
nix develop -c just jitsurei-ops-http
curl -fsS 'http://127.0.0.1:9092/projection/consumers?category=order'
curl -fsS 'http://127.0.0.1:9092/projection/consumers?category=creditLimit'
```

Both return HTTP 200 with the objects above. The stock database-only `keiro-ops-http`
executable intentionally cannot run this lookup: it mounts no application hooks, so the
route does not exist there.

Run the store-free profile first. It needs no database, and its result fixes the `--limit`
ceiling before any paired sampling:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mkdir -p keiro/bench/results/category-consumers
nix develop -c cabal build bench:inspection-interference --enable-benchmarks
candidate_binary="$(nix develop -c cabal list-bin bench:inspection-interference)"
"$candidate_binary" --profile-consumers +RTS -N2 -T -RTS | tee keiro/bench/results/category-consumers/allocation-profile.log
```

Expect one line per request shape and piece of work, giving encoded bytes and allocated
bytes, then the registry's construction allocation and retained live bytes, and a final
line stating that the direct encoding matches the canonical value. Apply Milestone 4's
three readings to it. If the full page at the ceiling allocates more than 2.78 MB on the
complete direct path, lower the ceiling, rebuild, and rerun into a new log file, keeping
the earlier one.

The added benchmark modes accept the harness's existing named arguments. The harness exits
with `run with +RTS -T` unless RTS statistics are enabled. These are individual diagnostic
invocations; final acceptance uses the alternating-pair script, not sequential cohorts:

```bash
nix develop -c cabal bench inspection-interference --benchmark-options='--output /Users/shinzui/Keikaku/bokuno/keiro/keiro/bench/results/category-consumers/capacity --rate saturation --trials 5 --mode disabled +RTS -N2 -T -RTS'
nix develop -c cabal bench inspection-interference --benchmark-options='--output /Users/shinzui/Keikaku/bokuno/keiro/keiro/bench/results/category-consumers/idle --rate 100 --trials 1 --mode consumers-idle +RTS -N2 -T -RTS'
nix develop -c cabal bench inspection-interference --benchmark-options='--output /Users/shinzui/Keikaku/bokuno/keiro/keiro/bench/results/category-consumers/active --rate 100 --trials 1 --mode consumers +RTS -N2 -T -RTS'
nix develop -c cabal bench inspection-interference --benchmark-options='--output /Users/shinzui/Keikaku/bokuno/keiro/keiro/bench/results/category-consumers/many --rate 100 --trials 1 --mode consumers-many +RTS -N2 -T -RTS'
nix develop -c env KEIRO_INSPECTION_RETENTION_SECONDS=60 cabal bench inspection-interference --benchmark-options='--output /Users/shinzui/Keikaku/bokuno/keiro/keiro/bench/results/category-consumers/retention --rate 100 --trials 1 --mode consumers +RTS -N2 -T -RTS'
nix develop -c cabal list-bin bench:inspection-interference
```

The rate `100` is an initial calibration value, not an acceptance claim; plan 323 fixed 50
and plan 327 fixed 100 operations per second. Establish a sustainable fixed
rate from the saturation control, record the chosen value, and use it consistently. The
absolute artifact path avoids Cabal's package-directory working-directory difference; adjust
it when using another checkout. Repeat the retention run for `consumers-many`. Then pass the
baseline and candidate binary paths, a fresh output directory, and the fixed rate to the new
pairing script, and record its exact invocation and evidence in this plan. Substitute the
two paths printed by `cabal list-bin` in each checkout and the rate chosen above:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop -c scripts/measure-category-consumers.sh BASELINE_BINARY CANDIDATE_BINARY keiro/bench/results/category-consumers/matched-v1 RATE
```

The script prints one line per comparison and metric with the median ratio, the interval,
and `passed`, `inconclusive`, or `regression`, and exits nonzero unless every line passed.
If any line is inconclusive, run the ten-pair cohort into a fresh directory and decide on
it alone:

```bash
nix develop -c env CATEGORY_CONSUMERS_PAIRS=10 scripts/measure-category-consumers.sh BASELINE_BINARY CANDIDATE_BINARY keiro/bench/results/category-consumers/matched-v2 RATE
```

The output must contain successful polls and complete writer samples for all trials; timing
evidence is absent at this revision.

Finally, check that the library change is additive. Use the implementation baseline commit
recorded at the start:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git diff --stat BASELINE_COMMIT -- keiro/src
git diff BASELINE_COMMIT -- keiro/src/Keiro/Projection/Catalog/Operations.hs | grep '^-[^-]'
```

The first command must list only `keiro/src/Keiro/Projection/Catalog/Operations.hs` and
`keiro/src/Keiro/Inspection/Consumers.hs`. The second must print nothing, or only lines
from the module's import and export lists. If either shows more, run the two guards in
both checkouts on a quiet machine and keep both logs:

```bash
nix develop -c just bench-regression projection read-model
```


## Validation and Acceptance


The required end-to-end result is that the real Jitsurei catalog yields
`jitsurei-order-reporting` for `order` through the library, CLI runner, and real HTTP
application. A declared input match works before a checkpoint exists. An unmatched valid
category returns success with an empty array; missing hooks instead retain unsupported-command
behavior, and partially mounted metadata is explicitly described by coverage flags. Jitsurei
mounts the catalog and no durable registry, so its responses report `projection_catalog: true`
and `durable_subscribers: false`. The exact Jitsurei response is shown in Concrete Steps.

Test exact case-sensitive categories, an all-stream consumer matching an otherwise unknown
category, namespace boundaries, several groups, several sources in one group, inline-only
handlers, shared async subscriptions, duplicate bindings, and unused source declarations.
“All-stream matches” takes precedence over the empty-category example: an empty result is
expected only when neither an exact nor a broader declared scope matches. A group appears
once with only its matching bindings. Declaration reordering does not affect results.

A process-manager fixture with input `order` and journal `fulfillment` must appear only for
its declared input. An inspector with no input declaration must not manufacture a consumer.
An ordinary durable subscriber uses the same source semantics. Conflicting declarations fail
registry construction, and explicitly empty registries are distinguishable from missing ones.
The command does not prove runtime liveness or exact event-handler relevance.

Page through more than one page and verify every matching item appears exactly once. Changing
the category or mounted inventory invalidates a cursor. Verify limit 0 and one above the
ceiling (501, unless Milestone 4 lowered the ceiling), malformed and oversized cursors, and
an oversized response, through both the HTTP application and the CLI runner. Existing
projection status SQL schema, status JSON including `feeding_subscriptions`, catalog
fingerprint, and mutation classification tests must continue to pass. The HTTP body, produced by direct encoding, must
decode to the same JSON as the runner's canonical result. The new library and ops lookup
need no store queries; HTTP still performs its established schema verification. Functional
tests alone do not satisfy Milestone 4's measured isolation, and neither does a passing
`just verify` or release gate: Milestone 4 states the measurement rule that does.

Performance acceptance has one check per path the change could affect. For applications
that never run the lookup, the diff shows the library change is additive, so no existing
code path gained work. For the HTTP route, the store-free profile shows what one response
allocates and fixes the limit ceiling, and the paired cohort shows no supported writer
regression in throughput, p95, p99, or writer-thread allocation for mounting alone, for
polling, and for both together. An inconclusive interval is not a pass; it needs the
ten-pair cohort and, failing that, the user's decision. For retained memory, both retention
runs level off and release their resources. The documented operating envelope is exactly
what was measured: the response size and polling rate of the heaviest mode.


## Idempotence and Recovery


The new read is repeatable and has no mutation or migration. Catalog/registry construction
is pure and deterministic. A stale cursor is recovered by restarting at the first page with
the current configuration. Querying a nonexistent category does not create data. Removing
the new hook configuration disables discovery without changing workers or stored state.

Do not reset or clean the shared working tree. Tests use disposable fixtures; manual example
setup uses only a local development database. The detached baseline worktree and its build
outputs are measurement artifacts: reuse the worktree if it already exists at the recorded
commit, and remove it only after the evidence is committed. Use a fresh output directory for
every benchmark run and keep failing evidence beside successful reruns. A source change
after measurement invalidates the affected evidence and requires a rerun on the final
candidate. Lowering the `--limit` ceiling is such a change: repeat the profile and the
cohort afterward, and keep the earlier logs. If a required check fails, record the failure
and investigate it within the relevant milestone. Do not change schema-drift policy, weaken
resource limits, or select dependency bounds merely to make the lookup tests pass. Check Z3
inside Nix before diagnosing symbolic tests. Commit cohesive implementation changes on the
current branch with both `ExecPlan:` and `Intention:` trailers from this document.


## Interfaces and Dependencies


The new pure projection interface belongs to
`Keiro.Projection.Catalog.Operations` in `keiro/src/Keiro/Projection/Catalog/Operations.hs`.
Its intended shape is:

```haskell
projectionConsumers
  :: ProjectionCatalogOperations
  -> CategoryName
  -> [ProjectionConsumerGroup]
```

`ProjectionConsumerGroup` retains a `RebuildGroupId` and matching bindings as defined above.
`Keiro.Inspection.Consumers` owns the data-only `ConsumerSource`,
`DurableConsumerDescription`, opaque `DurableConsumerRegistry`, constructor validation, and
pure category matching. The ops package owns JSON presentation and command options; the
runtime library owns derivation and source matching. The hook-aware parser/runner combines
these sources without an HTTP-specific implementation. `Keiro.Ops.Projection` also exports
the function that prepares the canonical `OpsResult` together with its equivalent Aeson
`Encoding`, and `Keiro.Ops.runCommandWithReadEncoding` gains the one case that uses it; its
existing signature and its `pm types` case do not change. Keep the module dependency
direction from ops to runtime, never runtime to ops or HTTP.

Some things stay exactly as they are. `keiro/src/Keiro/Projection/Catalog.hs`,
`ValidatedProjectionCatalog`, `validateProjectionCatalog`, and every existing definition in
`Operations.hs` are untouched, and `keiro-ops-http/src` needs no edit. The measurement adds
one benchmark module, `keiro-ops-http/bench/ConsumersProfile.hs`, and two scripts,
`scripts/measure-category-consumers.sh` and `scripts/analyze-category-consumers.py`; the
existing harness modules gain modes and a client branch but keep their writer loop.

The existing local `keiro`, `keiro-ops`, `keiro-ops-http`, and `jitsurei` packages provide the
necessary boundaries. Existing Aeson, text, and containers support data representation; use
Mori before relying on any unfamiliar dependency API. No dependency bounds, pins, or registry
schema changes are selected by this plan. If implementation discovers an upstream requirement,
verify authoritative released versions and release tags before proposing such a change.

The external consumer is the runtime console described by
`mori://shinzui/keiro-ui/plans/16-build-the-aggregates-process-managers-and-timers-screens`.
This plan provides its supported metadata read; adopting it in that application is separate
work. No cross-repository edit is needed for this plan's acceptance. On 2026-11-04
`mori path` did not resolve that plan URI in the local registry; the URI is kept as the
canonical reference.


## Revision Notes


2026-11-04: Revalidated the plan against `9da47eb7` after fifty-one commits, including plans
323, 327, 328, and 329 and the 0.22.0.0 and 0.23.0.0 releases. Context and Orientation now
describes the completed `pm types` discovery, the `feeding_subscriptions` status field, the
shared `Jitsurei.Ops` hook record, the `jitsurei-ops-http` host, and the package-graph
constraint on test placement. Four decisions were added: the reverse lookup is reaffirmed
against the now-possible status-row alternative; the read uses the direct-encoding path
because plan 323 measured the generic path as a writer regression; Jitsurei mounts no
durable registry; and the benchmark uses four `consumers*` modes with a rule fixed before
sampling. The benchmark command, which could not run without `+RTS -T`, was replaced; the
nonexistent `keiro-ops/README.md` target became `docs/user/operations.md`; changelog entries
and an ADR-53 amendment were added to Milestone 4; and IR-59 now follows the bundle's
accepted-then-completed practice. The exact Jitsurei response is written out. Milestone
scope and user-visible acceptance are unchanged.

2026-11-04 (performance review): Reviewed the plan against `9da47eb7` for ways it could
introduce a performance regression, reading the ops runner, the HTTP application, the
catalog inventory, the benchmark harness, and plan 323's retained evidence. Five decisions
were added. The library changes are additive and checked by diff, because the HTTP harness
runs no projection code. Ordering and deduplication happen once at construction, and a
request renders only its page. The `--limit` ceiling of 500 is provisional, decided by a
new store-free allocation profile before sampling, because the estimated cost of a 500-item
page with nested bindings exceeds what plan 323 measured as a writer regression. An
inconclusive interval no longer completes Milestone 4, which aligns the rule with plan 327
and adds a ten-pair rerun and a user decision. And the comparison list gains mount-only and
total-effect comparisons. Milestone 4 now fixes the large fixture and the request mix,
names the two scripts and the profile module, and states which gate covers which path.
Three inaccurate statements were corrected: the lookup is a join over sorted lists, the CLI
does not call `Ops.validateCommand`, and the canonical value must be built lazily to stay
off the HTTP path. Milestone scope is unchanged; the acceptance for Milestone 4 is stricter.
