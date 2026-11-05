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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-05T15:06:36Z
      mode: "implement"
      note: "Implement category consumers with focused performance verification and no DSL conformance, per user scope"
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


- [x] (2026-11-05) Milestone 1: Pure catalog lookup returns Jitsurei's reporting group and empty unmatched results; core tests cover exact/all sources, mixed delivery, fan-in, unused declarations and deterministic ordering.
- [x] (2026-11-05) Milestone 2: Validated immutable durable-input registry and optional hook support exact/all/namespace scopes, conflicts, duplicates and shared subscriptions; all four pure registry examples pass.
- [x] (2026-11-05) Milestone 3: Embedded CLI and HTTP share the bounded lookup and direct encoding. Full ops (61), HTTP (64), Jitsurei (29), and listening-host (5) suites pass, including coverage, continuation, schema-only SQL, oversized items and real-catalog parity.
- [x] (2026-11-05) Milestone 4: Documented the interface and explicit-input configuration; 956 relevant examples and four executable builds pass in Nix. Focused allocation/parity evidence, additive library diff, strict ADR/docs validation and repository policies pass. ADR-28 and ADR-53 retain the architecture; DSL conformance and statistical interference testing were excluded by user scope.

Implementation baseline: `5897f222` (2026-11-05), clean working tree. The plan was revalidated on 2026-11-04 against
`9da47eb7b4bcfcc1a98fc25a6b2b14aabb797a77`; the Revision Notes at the end list what changed.
A performance review the same day, against the same commit, tightened the design
constraints and Milestone 4's measurement; the second Revision Note lists those changes.


## Surprises & Discoveries

2026-11-05: The focused store-free maximum page contains 500 items and 1,000
bindings: 222,221 encoded bytes, 6,515,320 direct-path allocated bytes. Forcing the
unused canonical JSON and generic encoding afterward allocates another 8,996,336
bytes. The canonical envelope remains deferred on the direct path. These measurements
confirm that item count alone does not describe response cost; the HTTP byte cap remains
necessary for an item with many bindings. This is allocation evidence, not a writer
interference result. Source, command and raw output are retained in
`keiro/bench/results/category-consumers/`.


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

2026-11-05: Retain the standard 1..500 item range. The focused maximum-page probe
encodes 500 consumers with 1,000 bindings to 222,221 bytes and allocates 6,515,320
bytes on the direct path. The HTTP byte cap remains authoritative for large bindings;
no polling-rate or writer-isolation claim follows from this store-free measurement.
This supersedes the historical 2.78 MB tuning/cohort decision under the user's scope.

2026-11-05: The user explicitly requested focused performance testing and no DSL
conformance. Milestone 4 and its commands/acceptance now use a store-free probe and
relevant functional/policy checks, without claiming statistical writer isolation.


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


Completed 2026-11-05 under the user's revised verification scope. The real Jitsurei
catalog reports `jitsurei-order-reporting` for `order` through the pure library,
embedded CLI runner, actual WAI application and listening HTTP host. `creditLimit`
and unmatched categories return successful empty arrays within declared coverage.
Explicit durable descriptions support exact categories, all categories and literal
namespace scopes without changing workers or inferring journal inputs. Continuations
bind category and inventory; missing hooks and explicitly empty sources remain distinct.

The final Nix-shell command passed every relevant suite:

```bash
nix develop -c cabal test keiro-test keiro-ops-test keiro-ops-http-test jitsurei-test jitsurei-ops-http-test --test-show-details=direct
```

Results: core 797, ops 61, HTTP 64, Jitsurei 29 and listening host 5 examples; 956
examples total, zero failures. The four affected executables also build:

```bash
nix develop -c cabal build keiro-ops:exe:keiro-ops keiro-ops-http:exe:keiro-ops-http jitsurei:exe:jitsurei-demo jitsurei-ops-http:exe:jitsurei-ops-http
```

Strict ADR, user documentation, guide and improvement-request validation pass.
Terminology, record migration, extension and Keiro re-export policies pass, as do
formatting and whitespace checks. No DSL conformance or combined `just verify`
was run, as requested. Test fixtures prove no handler store access and one ordinary
HTTP schema-verification session, direct/canonical JSON parity, fresh encoding without
header-cache use, and HTTP refusal of an oversized single item.

[Focused performance evidence](../../keiro/bench/results/category-consumers/README.md)
retains the reproducible store-free probe and output. The 500-item ceiling is retained;
no statistical writer-isolation or polling-rate guarantee is claimed. The library diff
adds only new declarations in Operations.hs and the new Consumers.hs, with no changed
existing definitions. Catalog validation, fingerprints, event paths, the frozen SQL
status relation, existing status encoders and production HTTP transport source remain
unchanged. ADR-28 and ADR-53 now record the compiled-input and transport boundaries,
completing the durable-context distillation. IR-59 is completed with this resolution.


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
has since completed at implementation baseline `5897f222`, including exact workflow counts and dedicated inspection-pool parallelism limits. That work does not change this lookup's metadata boundary.

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
The shipped ceiling is 500, consistent in parser validation, tests and documentation. The user-scoped focused profile checks the maximum page without a paired measurement campaign.
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

The user's 2026-11-05 implementation instruction supersedes the earlier performance
campaign: do not overengineer performance testing and skip DSL conformance. Keep direct
encoding, one lookup per request, page-before-rendering, and additive runtime library changes.
Use a small store-free allocation check with a deterministic 1,000-consumer registry,
including two bindings per consumer, to check the maximum page and direct/canonical parity.
Retain its command and results, and document its limits without claiming writer-isolation
statistics. No detached baseline, harness modes, pairing scripts, bootstrap analysis, or
retention campaign is required. Keep the 500-item ceiling unless this focused check shows
an actionable problem. Existing HTTP admission, schema, deadline, and byte-cap tests remain
required; include an oversized single binding response.

Run the focused core, ops, HTTP, Jitsurei, and listening-host suites in Nix, build their
components, and run relevant repository policy and documentation checks. Do not run
`just verify` or all-component builds that pull in DSL conformance. The library diff must
remain additive in Operations.hs plus the new Consumers.hs; existing event paths gain no
work. This focused verification completes this milestone under the user's revised scope.

At completion, follow `agents/skills/exec-plan/ADR.md`: inspect `mori show --full` and the
profile-governed ADR bundle before writing. Update ADR-28 with the `durableConsumers` hook
and the compiled consumer-metadata boundary (its closing section records the
`processManagers` hook the same way), extend ADR-53's metadata-read paragraph to name this
read beside `pm types`, and reference the preserved ADR-35 contract. If a separate decision
record is needed, allocate its ID through OKF, never filename counting. Update bundle logs
and run strict ADR validation.

IR-59 began as `proposed` and already linked this plan. Following the bundle's current practice
(IR-57 under plan 327 and IR-55 under plan 328), mark it `accepted` with a bundle-log entry
when implementation begins. Mark it `completed`, with a resolution, only after every
acceptance in this plan has passed, including the user-scoped verification above.


## Concrete Steps


Run all verification from `/Users/shinzui/Keikaku/bokuno/keiro` through the Nix development
shell. Always enter the shell from the repository root: its hook places the PostgreSQL data
directory under the current directory, so entering from a package directory initializes a
stray cluster there. The focused PostgreSQL suites use repository test-support fixtures, not
a production database. Establish the baseline and run focused verification:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git status --short
git rev-parse HEAD
nix develop -c cabal test keiro-test keiro-ops-test keiro-ops-http-test jitsurei-test jitsurei-ops-http-test --test-show-details=direct
```

After implementation, run the focused suites above and relevant repository checks in
Nix. DSL conformance and `just verify` are excluded by the user's scope.

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

Run the focused store-free profile recorded in Outcomes & Retrospective; it measures
metadata lookup and bounded encoding only, without a database or writer workload.

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
need no store queries; HTTP still performs its established schema verification. Milestone 4 records the focused performance verification requested by the user.

Performance verification follows the user-scoped Milestone 4: additive library diff,
page-before-rendering, direct/canonical parity, and one focused store-free allocation check.
This is not a statistical writer-isolation guarantee. Earlier paired-cohort requirements
and DSL checks are superseded by the 2026-11-05 instruction.


## Idempotence and Recovery


The new read is repeatable and has no mutation or migration. Catalog/registry construction
is pure and deterministic. A stale cursor is recovered by restarting at the first page with
the current configuration. Querying a nonexistent category does not create data. Removing
the new hook configuration disables discovery without changing workers or stored state.

Do not reset or clean the shared working tree. Tests use disposable fixtures; manual example
setup uses only a local development database. The focused profile is store-free and retained
beside its source and reproduction command. Source changes affecting its result require a
new run; keep the scope of its claims limited to allocation and encoding parity. If a
required check fails, investigate it within the relevant milestone. Do not change schema
drift policy, weaken resource limits, or alter dependency bounds to pass these tests.
DSL conformance is excluded by the user's instruction. Commit cohesive implementation
changes on the current branch with both `ExecPlan:` and `Intention:` trailers.


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
`Operations.hs` are untouched, and `keiro-ops-http/src` needs no edit. Focused measurement uses a small store-free probe rather than extending the HTTP
interference harness or adding cohort orchestration scripts.

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

2026-11-05: User-directed implementation scope replaces the statistical performance campaign with a focused store-free probe and additive diff review, and excludes DSL conformance and aggregate verification commands that invoke it. Historical performance-review decisions above remain as context and are superseded where inconsistent.
