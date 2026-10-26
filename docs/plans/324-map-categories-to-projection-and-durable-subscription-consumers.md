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
---

# Map categories to projection and durable subscription consumers

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. Creating this plan does not implement the feature.


## Purpose / Big Picture


Implement [IR-59](../improvement-requests/map-categories-to-the-projections-that-consume-them.md).
An operator can run `projection consumers --category order`, or request
`GET /projection/consumers?category=order` from an application-embedded ops server, and see
`jitsurei-order-reporting`. A category with no declared consumer returns a successful empty
`items` array. A stream category identifies a family of event streams; a projection consumes
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
existing status JSON. No database migration, dependency upgrade, event-path instrumentation,
UI change, or publication is required. Database-only executables cannot discover compiled
catalogs; the new command is available only when an appropriate application hook is mounted.


## Progress


- [ ] Milestone 1: A pure library lookup derives accurate projection-group consumers from the validated catalog, including Jitsurei's order group and empty results.
- [ ] Milestone 2: Explicit durable subscriber descriptions support process-manager and other subscriber inputs without inferring journal categories or changing worker execution.
- [ ] Milestone 3: Embedded CLI and HTTP expose the same bounded lookup, with Jitsurei, coverage, cursor, and missing-hook behavior verified.
- [ ] Milestone 4: Document the interface, verify runtime isolation and repository checks, and distill the durable architecture decision.


## Surprises & Discoveries



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


## Outcomes & Retrospective



## Context and Orientation


The creation baseline is `c3c73edf2c4b246b18d6daebb856a4ddcc3745d1`. Existing edits to
`docs/plans/304-retire-legacy-language-and-runtime-compatibility-before-keiro-1-0.md`,
`docs/plans/323-list-mounted-process-managers-without-runtime-performance-regressions.md`,
`scripts/analyze-pm-types.py`, and `scripts/measure-pm-types.sh` belong to other work.
Recheck the working tree before implementation and preserve unrelated changes. This is a
standalone follow-up to IR-59, not a new child of an existing MasterPlan.

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
`keiro/src/Keiro/ReadModel/Rebuild.hs`. Its `ProjectionGroupStatusV1` and the existing
`projectionGroupStatusJson` in `keiro-ops/src/Keiro/Ops/Projection.hs` remain unchanged.

`keiro-ops/src/Keiro/Ops/Embed.hs` defines `AppHooks.projectionCatalog` and optional manager
inspectors. `keiro-ops/src/Keiro/Ops.hs` owns hook-dependent grammar and dispatch;
`keiro-ops/src/Keiro/Ops/Projection.hs` currently exposes `status`, `position`, and
`prune-dedup`. `keiro-ops-http/src/Keiro/Ops/Http/Route.hs` derives routes from that grammar,
and `keiro-ops-http/src/Keiro/Ops/Http/Application.hs` applies admission, schema verification,
deadlines, and response-byte limits. A pure handler still incurs HTTP's schema check.
`keiro/src/Keiro/Inspection/Cursor.hs` supplies bounded, kind-tagged continuation tokens.
A continuation token is an opaque value that tells the same read where to resume.

`keiro/src/Keiro/ProcessManager/Inspect.hs` describes how to read manager journal streams.
`keiro/src/Keiro/ProcessManager.hs` receives an abstract adapter in `runProcessManagerWorker`;
that adapter need not reveal its source filter. Thus current manager inspection metadata
cannot automatically supply input consumption. Preserve the existing inspector constructors.
[Plan 323](323-list-mounted-process-managers-without-runtime-performance-regressions.md)
adds manager discovery in this area; it is concurrent work, not a prerequisite or a source of
input categories. Avoid copying or changing its performance scripts incidentally.

`jitsurei/src/Jitsurei/ReadModels.hs` declares the exact source category `order`, a mixed
inline/async group `jitsurei-order-reporting`, and the existing `orderCatalogOperations`.
`jitsurei/app/Main.hs` mounts that hook for `jitsurei-demo ops`.
`jitsurei/src/Jitsurei/Inspection.hs` mounts the fulfillment manager with journal category
`fulfillment`; that declaration alone does not prove a subscription to `fulfillment` or `order`.

Relevant ADRs were discovered by scanning local filenames and headings.
[ADR-26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
makes the validated catalog the single authority for projection sources and handlers.
[ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
requires thin ops adapters over owner APIs, explicit compiled-code hooks, and the term
“global position distance,” never event lag, for cursor subtraction.
[ADR-35](../adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md)
freezes the SQL status contract and distinguishes serving from candidate progress.
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
requires bounded inspection and measured runtime isolation.
[ADR-53](../adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md)
requires shared CLI/HTTP grammar and unchanged transport resource/schema policies.

Mori located the upstream package at `mori://shinzui/kiroku/packages/kiroku-store`; its local
source describes subscription targets and checkpoints. The registry currently has no curated
docs for that project. No new upstream API is required here. In particular, do not adopt an
API seen only in the local corpus without checking the package registry and upstream release
tags against the project's resolved dependency. Keep cross-repository references canonical.


## Plan of Work


### Milestone 1: Derive the projection relation in the library


Add a pure `projectionConsumers` operation and exported result types in
`keiro/src/Keiro/Projection/Catalog/Operations.hs`. Start with one actual
`jitsureiProjectionCatalog` -> library lookup -> group ID test in `jitsurei/test/Main.hs`.
This is the early proof that the real catalog produces the required consumer. Then expand
`keiro/test/CatalogOperationsSpec.hs` with multi-source, mixed-delivery, and all-stream cases.

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
category, and invariant results under catalog declaration reordering. Include a source and
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

Add `durableConsumers :: Maybe DurableConsumerRegistry` to `AppHooks`, defaulting to `Nothing`.
Update all complete `AppHooks` record constructions found with `rg`, including the Jitsurei
example and test fixtures. `Just` an empty validated registry means the host explicitly
provided an empty set; `Nothing` means this source is unavailable. The registry is immutable
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
Validate nonempty category text without trimming/case folding, and reject surrounding
whitespace. Classify it read-only. Preserve the current exported parser and runner as
no-hook wrappers if adding hook-aware variants is needed, so existing direct callers of
`Projection.commandParser` and `Projection.runCommand` remain valid. The hook-aware variants
receive only the optional catalog and durable registry they need, avoiding an import cycle
with `Keiro.Ops.Embed`.

Update `keiro-ops/src/Keiro/Ops.hs` to use those variants. Mount `consumers` when either
`projectionCatalog` or `durableConsumers` is `Just`; retain all database-only projection
commands regardless of those hooks. With neither hook, normal parser/HTTP unsupported-command
behavior is expected, not a successful assertion that the whole database has no consumers.
With an explicitly empty mounted source, return success and `items: []`.

Combine the library results in a deterministic sequence ordered by `(kind, name)`, using
group ID as the name/key of a `projection_group` item. Page after filtering, with one lookahead
item and exclusive continuation. Bind cursors to version `keiro/category-consumers/v1`, the
exact category, the immutable metadata inventory identity, and the last item key. Reject
wrong-kind, changed-category, changed-inventory, malformed, and oversized tokens before any
handler work. Reuse `encodeCursorBounded`/`decodeCursor`; never return a token that the next
read would reject. This is pagination over finite in-memory metadata, not a claim that a
page limit bounds catalog traversal cost. Avoid constructing or encoding full inventory JSON
on each request merely to filter it or compute its identity; prepare reusable pure metadata
with the hook and measure its bounded mount cost.

Return a versioned JSON envelope with `schema`, `category`, `scope: "mounted_configuration"`,
`coverage: {"projection_catalog": true|false, "durable_subscribers": true|false}`, and `items`;
include `next_cursor` only when another result exists. Each item has `kind`, `name`, nullable
`group_id`, and `bindings`. Projection bindings contain `projection_id`, `handler_name`,
`delivery` (`inline` or `subscription`), nullable `subscription_id`, nullable
`subscription_name`, and `source`. Other bindings use null projection/catalog-subscription
IDs, `delivery: "subscription"`, and their actual subscription name. `source` is one of
`{"kind":"all"}`, `{"kind":"category","category":"order"}`, or
`{"kind":"namespace","namespace":"pm"}`. Nulls describe inapplicable identities, not an
unknown source. Human output shows kind, consumer name, group, subscription, and source.

Do not add progress values to this response. Clients join `group_id` to `/projection/status`
and subscription names to `/projection/position`; missing checkpoints remain unknown there.
Mapping remains visible before any event or checkpoint exists. An unregistered catalog group
can appear as declared even if it has no status row; the client must not infer liveness.

Add parser, rendering, hook-availability, pagination, and no-store-access coverage in
`keiro-ops/test/Main.hs`. In `keiro-ops-http/test/Main.hs`, mount the real Jitsurei catalog
(add a test-only dependency on the local Jitsurei library if needed) and exercise the actual
WAI application for `/projection/consumers?category=order`. Compare its decoded response to
the ops runner, allowing only transport-owned metadata differences. Confirm schema drift,
invalid input, admission, and response-byte handling retain their policies. No route registry
or production HTTP transport fork is needed. Test an oversized single item explicitly;
return the existing result-too-large behavior rather than silently truncating bindings.


### Milestone 4: Document and verify the completed behavior


Document the new CLI/HTTP query, embedded-only availability, coverage flags, all-stream and
namespace semantics, and status joining in `keiro-ops/README.md`,
`docs/guides/serve-keiro-ops-over-http.md`, and `docs/user/read-models-and-projections.md`.
Include an example constructing durable descriptions from actual worker configuration and
explain why `pm types` or a manager's journal category cannot substitute for that description.
Use existing documentation bundle metadata/log conventions when changing those files.

Measure the new route with the existing
`keiro-ops-http/bench/InspectionInterference.hs` harness. Add a named `active-consumers` mode
that mounts a fixed catalog plus durable registry and polls matching, absent, and paginated
category queries through the real HTTP application. Preserve all existing mode meanings.
Record the fixture cardinality, response sizes, polling cadence, exact source revision,
compiler/options, writer rate, and raw results under
`keiro/bench/results/category-consumers/`. Use same-source repeated controls to characterize
noise and matched pre-change/candidate disabled and mounted-idle controls. Compare active
inspection to the candidate's idle control at the same fixed offered writer rate. Measure
writer-attributed allocations, throughput, p95/p99 latency, and retained heap after clients
stop; do not divide combined-process allocation by writer completions and call it writer cost.
Use representative and large metadata inventories, including absent-category scans.

Acceptance requires no new ordinary-path work with inspection absent, no retained growth
across repeated polling/churn after cleanup, and no reproducible writer regression beyond
the measured control variability at the recorded supported cadence. Preserve every trial;
failed requests or missed offered load invalidate a comparison. Investigate failures rather
than declaring a read-only implementation isolated. Run benchmarks serially after compilation,
not beside other tests or performance work, and coordinate with any ongoing Plan 323 runs.

Run the focused suites, build all components, and pass `just verify` in the Nix shell.
At completion, follow `agents/skills/exec-plan/ADR.md`: inspect `mori show --full` and the
profile-governed ADR bundle before writing; update ADR-28 with the compiled consumer-metadata
boundary and reference the preserved ADR-35 contract. If a separate decision record is needed,
allocate its ID through OKF, never filename counting. Update bundle logs and run strict ADR
validation. Leave IR-59 proposed until acceptance is actually achieved; then update its status
and bundle log according to the repository's improvement-request conventions.


## Concrete Steps


Run all verification from `/Users/shinzui/Keikaku/bokuno/keiro` through the Nix development
shell. The focused PostgreSQL suites use repository test-support fixtures, not a production
database. Establish the baseline and check solver availability before broad DSL verification:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git status --short
nix develop -c z3 --version
nix develop -c cabal test keiro-test keiro-ops-test keiro-ops-http-test jitsurei-test --test-show-details=direct
```

After each corresponding milestone, run the focused suites above. Expect all examples to
pass, including the newly named `category consumers` groups in the core, ops, HTTP, and
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
nix develop -c cabal run -v0 jitsurei-demo -- ops --database-url 'host=db dbname=jitsurei' --json projection consumers --category ir59-unused-category
```

The commands use the recipe's default socket `db`, database `jitsurei`, and local user.
If the recipe is configured differently, pass that same connection with `--database-url`.
The first JSON response contains exactly one projection-group item named
`jitsurei-order-reporting`, with both matching inline and async bindings. The second has
`items: []` and no continuation. Both exit successfully. No event needs to be appended to
make the mapping appear. The automated HTTP test supplies the application hooks; the stock
database-only HTTP executable intentionally cannot run this lookup without them.

The added benchmark mode must accept the harness's existing named arguments:

```bash
nix develop -c cabal bench inspection-interference --benchmark-options='--output /Users/shinzui/Keikaku/bokuno/keiro/keiro/bench/results/category-consumers/active --rate 100 --trials 5 --mode active-consumers'
```

The rate `100` is an initial calibration value, not an acceptance claim. Establish a sustainable
fixed rate with controls, record the chosen replacement, and use it consistently. The absolute
artifact path avoids Cabal's package-directory working-directory difference; adjust it when
using another checkout. Record exact baseline/candidate commands and evidence in
this plan once measured. The output must contain successful polls and complete writer samples
for all trials; timing evidence is absent at plan creation.


## Validation and Acceptance


The required end-to-end result is that the real Jitsurei catalog yields
`jitsurei-order-reporting` for `order` through the library, CLI runner, and real HTTP
application. A declared input match works before a checkpoint exists. An unmatched valid
category returns success with an empty array; missing hooks instead retain unsupported-command
behavior, and partially mounted metadata is explicitly described by coverage flags.

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
the category or mounted inventory invalidates a cursor. Verify limits 0 and 501, malformed
and oversized cursors, and an oversized response. Existing projection status SQL schema,
status JSON, catalog fingerprint, and mutation classification tests must continue to pass.
The new library and ops lookup need no store queries; HTTP still performs its established
schema verification. Functional tests alone do not satisfy Milestone 4's measured isolation.


## Idempotence and Recovery


The new read is repeatable and has no mutation or migration. Catalog/registry construction
is pure and deterministic. A stale cursor is recovered by restarting at the first page with
the current configuration. Querying a nonexistent category does not create data. Removing
the new hook configuration disables discovery without changing workers or stored state.

Do not reset or clean the shared working tree. Tests use disposable fixtures; manual example
setup uses only a local development database. If a required check fails, record the failure
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
these sources without an HTTP-specific implementation. Keep the module dependency direction
from ops to runtime, never runtime to ops or HTTP.

The existing local `keiro`, `keiro-ops`, `keiro-ops-http`, and `jitsurei` packages provide the
necessary boundaries. Existing Aeson, text, and containers support data representation; use
Mori before relying on any unfamiliar dependency API. No dependency bounds, pins, or registry
schema changes are selected by this plan. If implementation discovers an upstream requirement,
verify authoritative released versions and release tags before proposing such a change.

The external consumer is the runtime console described by
`mori://shinzui/keiro-ui/plans/16-build-the-aggregates-process-managers-and-timers-screens`.
This plan provides its supported metadata read; adopting it in that application is separate
work. No cross-repository edit is needed for this plan's acceptance.
