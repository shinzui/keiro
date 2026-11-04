---
id: 327
slug: name-the-feeding-subscriptions-on-projection-status-pages-without-runtime-performance-regressions
title: "Name the feeding subscriptions on projection status pages without runtime performance regressions"
kind: exec-plan
created_at: 2026-11-04T05:44:19Z
intention: "intention_01m6jhc50pe16vyf19m52r91nc"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T05:44:19Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-04T15:47:07Z
      verdict: "changes-requested"
      note: "Reviewed current reader, fixtures and ADRs; SQL-only timing does not establish runtime isolation, and paired writer-interference acceptance remains unspecified."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-04T15:47:07Z
      mode: "update"
      note: "Refresh baseline, correct look-ahead and join assumptions, repair compatibility check and reproducible evidence protocol, record remaining runtime acceptance gap."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-04T18:01:55Z
      mode: "implement"
      note: "Implement bounded status subscription metadata and retain paired SQL and writer-interference evidence."
---

# Name the feeding subscriptions on projection status pages without runtime performance regressions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Creating this plan implements nothing and establishes no performance acceptance.


## Purpose / Big Picture


After this change, an operator can run `keiro-ops projection status --json`, or a client
such as the keiro runtime console can request `GET /projection/status`, and every item
carries a `feeding_subscriptions` field: the sorted names of the durable Kiroku
subscriptions whose checkpoints feed the projection group's asynchronous projections, or an
empty array when Keiro has recorded none. The `projection_groups` WebSocket feed items carry
the same field because they reuse the same encoder. A client can therefore take a group row
and immediately call `projection position --subscription NAME` for each feeding subscription
to show member checkpoints and global position distance, instead of asking the operator to
choose a subscription by hand.

This implements [IR-57](../improvement-requests/name-the-feeding-subscription-on-projection-status-rows.md)
with two corrections that validation of the request against the working tree made necessary
(see Decision Log and Surprises & Discoveries): the field is a list named
`feeding_subscriptions`, not a single nullable text named `feeding_subscription`, because
Keiro stores a set of subscription names per group; and the jitsurei acceptance value is
`jitsurei-order-audit-subscription`, not `jitsurei-order-reporting`, because a group's name
is not its subscription's name.

The frozen SQL relation `keiro_read.projection_group_status_v1` does not change at all. The
complete-list and single-group Haskell APIs keep byte-identical SQL. No migration, index,
writer statement, or catalog registration path changes. The user's constraint for this plan
is that the change introduces no runtime performance regression; acceptance therefore requires
paired evidence on the one read path that changes (the bounded status page), proof that the
unchanged paths are unchanged, and the existing read-model benchmark guard.


## Progress


- [x] Milestone 1 (2026-11-04; focused core 9 examples, ops inline authority assertions, byte comparison of preserved definitions, strict IR bundle validation): The library page read returns each frozen v1 row together with its registered feeding subscriptions, proven by focused core tests for a two-subscription checkpoint group, an inline-only append group, and an unmanaged group, with the complete-list and lookup SQL byte-identical to the comparison baseline. IR-57 is linked to this plan as `accepted` with its request text corrected.
- [x] Milestone 2 (2026-11-04; ops 56, jitsurei 28, HTTP 55 examples, all passing; real executable CLI/HTTP items agree): `projection status --json`, `GET /projection/status`, and `projection_groups` feed items carry `feeding_subscriptions` with every existing key and value unchanged; the jitsurei group reports `["jitsurei-order-audit-subscription"]` and its legacy group reports `[]`, over the library, the embedded CLI, and the real HTTP server.
- [ ] Milestone 3: Retained paired evidence shows the candidate page statement keeps its per-key plan with at most one primary-key probe per checkpoint row, skipping proven-empty append/unmanaged arrays and a paired median server execution time within 1.10x of the pre-change binary at 10k and 100k groups for first and deep pages, the matched writer-interference intervals pass, the read-model guard passes without baseline movement, and the writer and schema paths are shown untouched.
- [ ] Milestone 4: User documentation, guides, changelogs, and ADR-35 describe the field; IR-57 is `completed` with a resolution; the strict OKF bundles validate; and `just verify` passes in the Nix shell on the final candidate.


Implementation checkpoint (2026-11-04): Runtime implementation is committed as
`3e9fbacd`; the fixed writer protocol is committed as `04fe3e68`. Before the guarded-query optimization, full
`nix develop -c just verify` passed, including all runtime/DSL suites, mutation and
policy checks, strict governed bundles, and 41 migration examples. The retained
`verify.log` records that run. Milestones 3 and 4 remain open: no paired timings or
read-model guard have been accepted yet; other repositories are running builds/tests
and the quiet-machine requirement must be satisfied before measurement. The user
has been asked about a quiet window; do not stop their other processes.

Behavioral evidence: `keiro/bench/results/inspection/projection-status-feeding-subscriptions/jitsurei-cli.json`
and `jitsurei-http.json` retain the complete responses. The embedded CLI used an explicit
`--database-url` (its ops parser does not consume the demo's `PG_CONNECTION_STRING`).
The database-only HTTP server used port 19327 because 9092 was already occupied.
Both returned these fields, with all item keys/values equal across transports:

```json
{"group_id":"$legacy-read-model:jitsurei-area-chapters","serving_position_basis":"unmanaged","feeding_subscriptions":[]}
{"group_id":"jitsurei-order-reporting","serving_position_basis":"checkpoint","feeding_subscriptions":["jitsurei-order-audit-subscription"]}
```

Implementation protocol (2026-11-04): The review's runtime evidence gap is addressed
by a matched projection cohort, fixed before sampling. Compile identical extended
`InspectionInterference.hs` and `InspectionClients.hs` sources against baseline and candidate.
Seed 10,000 groups with three models each, every tenth group checkpoint-backed with one
non-empty subscription name. Use the existing durable workflow schedule/claim/resume/timer
writer at 100 offered operations per second, 20 seconds per trial, `+RTS -N2 -T`.
Run five alternating baseline/candidate pairs for mounted idle, four staggered status
pollers (four requests per second, limit 100), and four shared `projection_groups` feed
subscribers with limit 100. Retain every operation timing and client success/failure count.
Compare each candidate mode with its matched baseline mode, and the candidate active/idle
ratio with the baseline active/idle ratio. Metrics are achieved throughput, writer p95/p99
including scheduling delay, and writer-thread allocated bytes per operation. A trial refuses
lost offered load (<99%), any failed client, lost polling requests, missing snapshots,
non-durable settings, incomplete samples, or abandoned feed resources. Report each metric's paired median ratio and a fixed-seed 95% percentile bootstrap
interval (20,000 resamples of the five independent trial pairs). An interval wholly above
1 rejects degradation; an upper endpoint >=1.01 remains inconclusive. Completion requires
passing intervals, including separately paired same-source idle controls that characterize
noise. Report all ratios and absolute medians without removing outliers. The SQL-only 1.10
ceiling does not authorize a 10% writer regression. This measures the specified workload; it is not a universal performance
claim. Retain source, binaries' hashes, dependencies, raw records and summary alongside the SQL
evidence. No earlier manager-discovery waiver supplies projection acceptance.


## Surprises & Discoveries

- 2026-11-04 (implementation): The first 40-trial writer cohort fulfilled all loads but
  failed acceptance: feed p95 ratio 1.037748 (CI95 1.015959..1.289418), same-source p99
  control CI95 0.430751..1.434925, and 416/458 process observations showed other builds/tests.
  It is retained under `loaded-interference-v1/`, not accepted as a causal comparison.
  Inspection row encoding appended one field to an 18-element pair list; prepend that
  new pair instead to avoid an unnecessary list traversal/copy. JSON key order is not a
  contract, and the old keys/values and v1 encoder remain unchanged. Repeat the fixed
  cohort on the resulting candidate; no gate or baseline is relaxed.
- 2026-11-04 (implementation): A loaded diagnostic of candidate `3e9fbacd`
  exceeded the 1.10 SQL ceiling for 10k custom deep pages (1.139823) and 100k
  generic deep pages (1.104096). Other repositories were compiling, so the cohort
  is not quiet-machine acceptance evidence; all samples and process observations
  are retained under the evidence folder's `loaded-diagnostic-v1/`. The extra
  per-row cursor lookup remains a likely source of work. Query prototypes are
  investigating cheaper bounded reads before rerunning the unchanged numeric gate.
- 2026-11-04 (implementation): The ordinary added left join uses a merge join under
  forced generic plans for both 10k and 100k first pages: the added `cursors` index scan
  has no index condition and runs once. The fenced lateral alternative is required
  to retain 101 parameterized primary-key probes. Prototype is local at
  `.dev/plan327/prototype.json`; accepted measurements are retained separately.

- 2026-11-04 (planning): IR-57 states that the frozen contract "means the field would be
  additive" on `projection_group_status_v1`. ADR-35 says the opposite: the v1 relation is
  frozen in column order and "is not extended under an open-ended additive rule"; an
  incompatible column creates `projection_group_status_v2`. The request's own alternative,
  "or alongside it", is the only design the ADR permits. Evidence:
  `docs/adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md`, Decision
  section, and `docs/user/read-models-and-projections.md`, which tells external readers that
  "v1 is not extended in place".
- 2026-11-04 (planning): The data the request wants already exists as a set, not a scalar.
  `keiro.keiro_projection_group_cursors.subscription_names` is `text[] NOT NULL`, written by
  `cursorAuthorityParams` in `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` as the sorted set of
  the subscription names of every asynchronous handler in the group. The core test fixture
  `catalogWithMissingSubscription` in `keiro/test/CatalogSpec.hs` registers one group with two
  subscriptions (`catalog-async-subscription` and `catalog-missing-subscription`), so a single
  nullable text field could not represent a group Keiro already supports.
- 2026-11-04 (planning): The request's jitsurei acceptance value is wrong. The group
  `jitsurei-order-reporting` in `jitsurei/src/Jitsurei/ReadModels.hs` has one asynchronous
  projection, `orderAuditAsyncProjection`, whose `subscriptionName` is
  `jitsurei-order-audit-subscription`; the catalog's single `SubscriptionDeclaration` reuses
  that name. Nothing in jitsurei names a subscription `jitsurei-order-reporting`. The request
  itself says a console must never assume a group and a subscription share a name.


## Decision Log


- Decision: Do not add a column to `keiro_read.projection_group_status_v1`. Carry the feeding
  subscriptions beside the frozen row in Keiro's own page reader by joining the private
  cursor-authority table `keiro.keiro_projection_group_cursors` on the page's group key.
  Rationale: ADR-35 freezes the v1 relation's columns and forbids additive extension; the
  reader in `keiro/src/Keiro/ReadModel/Rebuild/Status.hs` already runs with Keiro's owner
  rights and already selects page keys from the private `keiro.keiro_projection_rebuild_groups`
  table, so reading one more private table on the same key adds no new privilege or contract.
  A separate `keiro_read` view or a `v2` relation would require a migration, an expected-schema
  change, grants, and a second frozen contract for a field only the ops surface needs today.
  Date: 2026-11-04
- Decision: The JSON field is `feeding_subscriptions`, a sorted array of strings that is empty
  rather than null when Keiro records no durable subscription for the group. The request's
  `feeding_subscription` (single nullable text) is not implemented.
  Rationale: The stored authority is a set (see Surprises & Discoveries) and a group with two
  asynchronous projections has two feeding subscriptions. Empty-not-null mirrors the v1
  `query_models` convention recorded in ADR-35 ("sorted and empty rather than null"). The
  existing `serving_position_basis` field distinguishes the two empty cases: `append` means an
  inline-only group that has no durable subscription, and `unmanaged` means Keiro has not
  reconciled cursor authority for the group, so its subscriptions are unknown rather than
  absent. The console must keep its manual subscription chooser for `unmanaged` rows.
  Date: 2026-11-04
- Decision: Introduce a new page item type, `ProjectionGroupStatusRow`, holding the unchanged
  `ProjectionGroupStatusV1` under `status` and the new `feedingSubscriptions` list, and change
  only `listProjectionGroupStatusesPage` to return it. Leave `ProjectionGroupStatusV1`,
  `listProjectionGroupStatuses`, and `lookupProjectionGroupStatus` untouched, including their
  SQL text.
  Rationale: `ProjectionGroupStatusV1` is documented to users as the exact 18-field mirror of
  the frozen relation and must stay a pure decoding of it. The two compatibility APIs are the
  paths the release gate's read-model guard measures
  (`All.read-model-reads.status.*` in `keiro/bench/baseline-read-model.csv`); keeping their
  SQL byte-identical means their baseline rows stay valid with no re-recording. The page API is
  what the CLI, HTTP route, and feed use, so it is the only path that needs the field. This is
  a breaking Haskell change for direct users of `ProjectionStatusPage.items`, recorded in the
  changelogs; Keiro is pre-1.0 and records such changes at every release.
  Date: 2026-11-04
- Decision: Performance acceptance is (a) paired pre-change versus candidate evidence on the
  actual page statement at 10k and 100k groups, requiring the plan shape described in Milestone
  3 and a paired median server execution time within 1.10x of the pre-change binary; (b) a
  passing `just bench-regression read-model` run with no baseline change; and (c) structural
  evidence that no writer, schema, registration, or migration path changed. A matched
  writer-interference cohort was initially deferred unless (a) failed; the review below
  rejects that deferral as sufficient evidence for the broader runtime guarantee.
  Rationale: The release gate's six benchmark guards do not observe the page read, so (a) is
  the only measurement of the changed path, exactly as plan 325 concluded for its new read. The
  change adds at most one primary-key probe per checkpoint page row (at most 501 rows) to a read that already
  performs a correlated lookup per row; no new route, polling cadence, or writer work is
  introduced, but the extra array changes database result transfer, decoding, JSON encoding, and
  feed comparisons. Unchanged writer SQL does not establish unchanged shared-resource cost. If (a)
  exceeds its ceiling, the cause must be attributed and the matched interference protocol of
  plan 323 becomes required before acceptance; ADR-58 forbids moving a baseline to absorb it.
  Date: 2026-11-04
- Decision: Guard the added subscription-name probe with the frozen row's
  `serving_position_basis = 'checkpoint'`. The existing private-table constraint proves
  append/unmanaged arrays are empty; no migration or new assumption is needed. Retain
  the correlated OFFSET 0 boundary and existing public-view fence. Refine the structural gate from one extra probe per SQL
  row to at most one per checkpoint row (10 probes in these 101-row fixtures), while
  retaining the 1.10 timing ceiling and all runtime gates.
  Rationale: The all-row lookup exceeded the SQL ceiling in a loaded diagnostic. Local
  prototypes showed that a scalar form, changed fence placement, and a batched range
  read did not consistently reduce cost. Skipping provably unnecessary work reduced
  the added index scans from 101 to 10 while preserving exact field semantics. A second
  loaded cohort with the guarded lateral form narrowly exceeded the deep-page ceiling
  (1.1046); a CASE-controlled scalar probe also removes its per-row join overhead.
  Date: 2026-11-04
- Decision: Require a projection-specific matched idle/poll/feed writer cohort in addition
  to the SQL ceiling, using the fixed protocol in Progress. Runtime acceptance rejects
  statistically supported degradation and intervals that cannot exclude a 1% loss;
  same-source controls must resolve noise within 1%. The earlier manager-types waiver
  is not inherited, and the 1.10 SQL allowance is not a writer allowance.
  Rationale: Returned arrays affect transfer, decoding, response encoding and feed comparison
  even though writer SQL is unchanged. Fixing the workload and refusal rules before
  sampling addresses the review without narrowing the user's runtime constraint.
  Date: 2026-11-04
- Decision: Correct IR-57's request text and acceptance in the same change that links it to
  this plan, rather than implementing a request whose acceptance cannot be met by a correct
  implementation.
  Rationale: The request's acceptance names a value jitsurei never produces and a column the
  frozen contract forbids. Leaving it would make the request unverifiable. The bundle precedent
  (IR-56, IR-58) edits request documents from Keiro when their status or links change.
  Date: 2026-11-04


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


Keiro is a Haskell library backed by PostgreSQL. A **projection** consumes events to maintain
queryable tables. A **projection group** (also called a rebuild group) is the set of
projection targets that share one rebuild lifecycle and one stable `group_id`. An
**asynchronous projection** is delivered later by a worker that reads events through a
**durable Kiroku subscription**, a named cursor whose **checkpoint** (last applied global
position) is persisted per subscription member and survives restarts. An **inline
projection** runs inside the command transaction and has no durable subscription. A **feeding
subscription** of a group is a durable subscription that delivers events to one of the group's
asynchronous projections.

The implementation comparison baseline is commit `d64849f1` (full hash
`d64849f19d2d922a5373b121d13d0fac5bc9132f`) on `master`. The original planning
baseline was `610da7ec`; subsequent commits changed the HTTP host and test support.
Use the newer pre-implementation baseline to avoid mixing those changes into this comparison. Recheck
`git status` before implementing and preserve any unrelated work. This is a standalone
follow-up to IR-57, not a child of a MasterPlan. The consumer request originates from
`mori://shinzui/keiro-ui/plans/17-build-the-projections-and-overview-screens`; changing that
console is outside this plan.

### Where the data lives


Migration `keiro-migrations/migrations/0026.sql` creates two things. First, the private table
`keiro.keiro_projection_group_cursors` with columns `group_id` (primary key, foreign key to
`keiro.keiro_projection_rebuild_groups` with cascade delete), `position_basis` (`append`,
`checkpoint`, or `unmanaged`), `subscription_names` (`text[] NOT NULL DEFAULT '{}'`), and
`updated_at`. A check constraint requires a non-empty array exactly when the basis is
`checkpoint`. Second, the frozen owner-rights view `keiro_read.projection_group_status_v1`,
which left-joins that table to compute `serving_position_basis` and the conservative
`serving_applied_position` floor, but deliberately does not publish `subscription_names`.

`cursorAuthorityParams` in `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` derives the row at
catalog registration and reviewed adoption: it collects the subscription identity of every
`InventoryAsyncHandler` whose projection belongs to the group, maps each to its declared
subscription name, sorts them, and writes `checkpoint` with that list or `append` with an empty
list through `upsertGroupCursorAuthorityStmt`. Groups created by the legacy
`registerReadModel` path in `keiro/src/Keiro/ReadModel/Schema.hs` (ids of the form
`$legacy-read-model:<name>`) get no cursor row, and the view reports them as `unmanaged`.
This plan reads that table and never writes it.

### The reader that changes


`keiro/src/Keiro/ReadModel/Rebuild/Status.hs` owns the typed reader, re-exported through
`keiro/src/Keiro/ReadModel/Rebuild.hs`. `ProjectionGroupStatusV1` is the 18-field record
decoded from the view by `projectionGroupStatusDecoder`. `statusSelect` is the shared
`SELECT ... FROM keiro_read.projection_group_status_v1` text. Three statements use it:
`listProjectionGroupStatusesStmt` (complete list, ordered by group id),
`lookupProjectionGroupStatusStmt` (one group), and `pageProjectionGroupStatusesStmt`, which
selects a bounded page of group keys from `keiro.keiro_projection_rebuild_groups` in a
materialized CTE and then performs one correlated lookup through the view per key inside a
`CROSS JOIN LATERAL (... OFFSET 0)`. The `OFFSET 0` is an optimization fence that keeps each
lookup parameterized by key instead of letting PostgreSQL flatten the view into fleet-wide
joins. `listProjectionGroupStatusesPage` wraps the page statement, validates the request
(page size 1..500, cursor of kind `projection-groups` bound to contract
`projection_group_status_v1`), reads `now()` as `observedAt` in the same transaction, and
returns `ProjectionStatusPage {observedAt, items, next}`. The continuation cursor encodes the
last item's group id.

### The surfaces that render it


`keiro-ops/src/Keiro/Ops/Projection.hs` defines the `projection status` command. Its handler
calls `listProjectionGroupStatusesPage`, reads `storeHeadPosition`, and renders a four-column
human table plus a JSON object `{observed_at, visible_store_head, items, next_cursor?}` whose
items come from `projectionGroupStatusJson :: ProjectionGroupStatusV1 -> Value`, an object
keyed by the v1 column names. `keiro-ops-http` derives `GET /projection/status` from that same
command grammar (ADR-53), so no route code changes. `keiro-ops-http/src/Keiro/Ops/Http/Views.hs`
defines `projectionGroupsView`, the canonical first-page view behind the `projection_groups`
WebSocket feed (ADR-56): each `Item` has the group id as key and `projectionGroupStatusJson row`
as body, and the view attaches `visible_store_head` as an extra field. Feed deltas are computed
by comparing item bodies, so a field that is constant per group produces no extra deltas.

Aeson's `object` builds a key map, so JSON key order in these responses is not insertion order
and has never been part of the contract. "Existing fields unchanged" in this plan means the
existing key set and their values are unchanged.

### Tests and fixtures that already cover the surface


`keiro/test/GroupRebuildSpec.hs` registers catalogs from `keiro/test/CatalogSpec.hs` and
asserts status rows: "publishes conservative checkpoint status without reading private Kiroku
storage" registers `catalogWithMissingSubscription`, whose group `counter-group` (`mainGroupId`)
has two asynchronous handlers on `catalog-async-subscription` and
`catalog-missing-subscription`; "keeps adversarial checkpoint inventory and large status
listings fail-safe" registers `validCatalog`, seeds 250 synthetic groups, mutates and finally
deletes the cursor row, and checks that three pages of 100 concatenate to the complete list.
`keiro-ops/test/Main.hs` ("renders bounded projection status through the owning public
relation") registers `opsCatalog`, an inline-only catalog with `subscriptions = []`, and checks
that the command's `items` equal the encoder applied to the page.
`keiro-ops-http/test/Test/WebSocketSpec.hs` checks a `projection_groups` update's `changed`
array against the encoder and a head-only update with an empty `changed` array.
`keiro-ops-http/test/Main.hs` lists `/projection/status?limit=1` in `cliReads`, which asserts
CLI and HTTP JSON agreement. `jitsurei/test/Main.hs` queries the view directly in
`externalProjectionStatusStmt` and must keep passing unchanged. `keiro-migrations/test/Main.hs`
pins the view's column signature, grants, and semantics and must keep passing unchanged; the
expected-schema snapshot is `keiro-migrations/expected-schema/native/keiro-v18.txt`.

jitsurei registers its catalog in `initializeJitsureiTables`
(`jitsurei/src/Jitsurei/Database.hs`), creating group `jitsurei-order-reporting` with basis
`checkpoint` and `subscription_names = {jitsurei-order-audit-subscription}`. Its
`initializeAreaChapters` (`jitsurei/src/Jitsurei/AgentQualRouter.hs`) registers the legacy read
model `jitsurei-area-chapters`, creating group `$legacy-read-model:jitsurei-area-chapters`
with no cursor row. `jitsurei/app/Main.hs` mounts the ops command tree as `jitsurei-demo ops`.

### Performance instruments


`keiro/bench/ReadModelBench.hs` benchmarks `listProjectionGroupStatuses` and
`lookupProjectionGroupStatus` over 1,000 synthetic groups under `read-model-reads/status`.
`keiro/bench/baseline-read-model.csv` holds their baseline rows
(`All.read-model-reads.status.list-1000-synthetic-groups` about 7.55 ms and
`lookup-among-1000-synthetic-groups` about 60 µs). `scripts/bench-regression.sh` runs the
read-model guard with `--fail-if-slower 25`; `just bench-regression read-model` runs only that
guard. The page read is not benchmarked there and is not among the release gate's six guards.

`scripts/inspection-projection-status-evidence.hs` is the retained evidence driver for the page
read: on disposable durable databases it seeds 10k and 100k groups with three models each plus a
10,000-model hot group, calls the real `listProjectionGroupStatusesPage` for a first page and a
deep page under forced custom and generic plans, finds the prepared statement in
`pg_prepared_statements`, and records `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)`.
Its results live in `keiro/bench/results/inspection/projection-status-read/` with a README,
manifest, and checksums: generic first/deep pages took 2.779/0.562 ms at 100k and
2.736/0.495 ms at 10k. Plan 325 ran such a driver with
`cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support <script> <out>`.

### Documentation and governed bundles


`docs/user/operations.md` (`DOC-15`, section "Projection status pages") and
`docs/user/read-models-and-projections.md` (`DOC-19`, "Observe Projection Group Status From
PostgreSQL" and the Haskell callers paragraph) are governed by
`mori/user-documentation-profile.dhall`; `docs/guides/stream-keiro-inspection-views.md`
(`DOC-31`) is governed by the same profile under `docs/guides`. ADRs live under
`docs/adr/profile.dhall`, and improvement requests under
`mori/improvement-requests-profile.dhall`. Editing any governed document requires advancing its
`timestamp` and appending a matching `okf log add` entry, or strict validation fails
(`just user-documentation-validate`, `just adr-validate`, and the direct `okf validate` command
for improvement requests in Concrete Steps). Changelogs are `CHANGELOG.md`,
`keiro/CHANGELOG.md`, `keiro-ops/CHANGELOG.md`, and `keiro-ops-http/CHANGELOG.md`, each with an
`[Unreleased]` section. IR-57's bundle precedent (IR-56, IR-58 in
`docs/improvement-requests/log.md`) links an accepted request with `status: accepted` and a
`plan:` path plus an `Update` log entry, and closes it with `status: completed`,
`completedAt`, `resolution`, and a `Completion` log entry.

### Relevant ADRs


Discovered by scanning `docs/adr/` filenames and headings.
[ADR-35](../adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md) freezes
the v1 relation, defines the private cursor-authority row ("`append` or a sorted set of
checkpoint subscription names"), and already records the additive page API; this plan amends
it. [ADR-26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
makes the validated catalog the authority for handlers and subscriptions, which is why the
cursor row is derived rather than declared.
[ADR-31](../adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md)
treats subscription checkpoint policy as catalog identity.
[ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
requires commands to wrap owner APIs and share representations across CLI and HTTP; the field
comes from Keiro's own table through Keiro's own reader.
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md),
[ADR-53](../adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md),
and [ADR-56](../adr/0056-inspection-feeds-own-bounded-shared-drivers-and-an-active-only-wake-cursor.md)
govern the HTTP transport and feeds that reuse the encoder.
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
sets the evidence rules: isolated fixtures, retained raw records, attributed baselines, and no
baseline movement to absorb a failing guard. The upstream checkpoint relation that the view
reads is owned by `mori://shinzui/kiroku/okf/adrs/concepts/ADR-6`; this plan does not touch it.


## Plan of Work


### Milestone 1: Library row type, page join, and request correction


Scope: make the bounded page read return the feeding subscriptions beside each frozen row,
leave every other reader byte-identical, and bring IR-57 into a verifiable state. At the end,
`listProjectionGroupStatusesPage` returns `ProjectionStatusPage` whose `items` are
`ProjectionGroupStatusRow` values, core tests prove the three cases, and IR-57 is `accepted`
with corrected text.

Before editing runtime code, record the baseline for Milestone 3: create a detached worktree
of the comparison baseline at `../keiro-feeding-subscriptions-baseline` (outside the tracked
tree, following the plan 323 precedent of `../keiro-pm-types-baseline`). Then link IR-57 to
this plan as the bundle precedent does: set `status: accepted`, add
`plan: docs/plans/327-name-the-feeding-subscriptions-on-projection-status-pages-without-runtime-performance-regressions.md`,
advance `timestamp`, and rewrite its "Requested Change" and "Acceptance" sections to the
corrected contract: a `feeding_subscriptions` array (sorted, empty when none) on each
`projection status` item and `projection_groups` feed item; the v1 relation unchanged; for
jitsurei, `["jitsurei-order-audit-subscription"]` on `jitsurei-order-reporting` and `[]` on
`$legacy-read-model:*` groups. Replace the sentence claiming ADR-35 makes the field additive
with the correct statement that ADR-35 forbids extending v1, so the field travels beside it.
Append an `Update` log entry and validate the bundle.

In `keiro/src/Keiro/ReadModel/Rebuild/Status.hs`, add the type and change the page path only:

```haskell
-- | One bounded-page item: the frozen v1 row plus Keiro-owned registration
-- metadata that the v1 relation deliberately does not publish. The list is the
-- registered cursor authority as stored: sorted subscription names for a
-- 'ServingPositionCheckpoint' group, empty for 'ServingPositionAppend' and
-- 'ServingPositionUnmanaged' groups and for groups without an authority row.
data ProjectionGroupStatusRow = ProjectionGroupStatusRow
  { status :: !ProjectionGroupStatusV1,
    feedingSubscriptions :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

data ProjectionStatusPage = ProjectionStatusPage
  {observedAt :: !UTCTime, items :: ![ProjectionGroupStatusRow], next :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show, Generic)
```

Change `pageProjectionGroupStatusesStmt` to return `[ProjectionGroupStatusRow]` by appending
one primary-key join on the materialized page key, so the view lookup stays exactly as it is:

```haskell
pageProjectionGroupStatusesStmt :: Bool -> Statement (Maybe Text, Int64) [ProjectionGroupStatusRow]
pageProjectionGroupStatusesStmt after =
  preparable
    ( "WITH inspection_groups AS MATERIALIZED (SELECT group_id FROM keiro.keiro_projection_rebuild_groups"
        <> (if after then " WHERE group_id > $1" else " WHERE $1::text IS NULL")
        <> " ORDER BY group_id LIMIT $2) SELECT status.*, CASE WHEN status.serving_position_basis = 'checkpoint'"
        <> " THEN coalesce((SELECT subscription_names FROM keiro.keiro_projection_group_cursors feeding_authority WHERE group_id = page.group_id OFFSET 0), ARRAY[]::text[])"
        <> " ELSE ARRAY[]::text[] END AS feeding_subscriptions FROM inspection_groups page CROSS JOIN LATERAL ("
        <> statusSelect
        <> " WHERE group_id = page.group_id OFFSET 0) status ORDER BY status.group_id"
    )
    (contrazip2 (E.param (E.nullable E.text)) (E.param (E.nonNullable E.int8)))
    (D.rowList projectionGroupStatusRowDecoder)

projectionGroupStatusRowDecoder :: D.Row ProjectionGroupStatusRow
projectionGroupStatusRowDecoder =
  ProjectionGroupStatusRow
    <$> projectionGroupStatusDecoder
    <*> D.column (D.nonNullable (D.listArray (D.nonNullable D.text)))
```

The probe key is `page.group_id`, the materialized page key. The implementation
prototype rejected an ordinary left join because generic first-page plans used an
unparameterized merge join. An unconditional fenced lookup exceeded the timing ceiling;
a guarded lateral lookup skipped empty arrays but retained an extra join per SQL row.
The final CASE expression invokes a correlated scalar subquery only for checkpoint rows,
with an OFFSET 0 boundary and a primary-key condition on the page key. Migration 0026's
existing check constraint requires empty arrays for append/unmanaged authority, so skipping
those probes preserves the stored value exactly. Keep the existing public status lookup
fence. Retained plans and timings, rather than the SQL spelling, establish acceptance.
Do not add
`coalesce`, sorting, or de-duplication beyond the `coalesce` to an empty array: the field
reports the authority row as stored. Update the continuation to read the last item's
`status.groupId`. Export `ProjectionGroupStatusRow (..)` from the module and from
`keiro/src/Keiro/ReadModel/Rebuild.hs` next to `ProjectionStatusPage (..)`. `statusSelect`,
`listProjectionGroupStatusesStmt`, `lookupProjectionGroupStatusStmt`,
`projectionGroupStatusDecoder`, and `ProjectionGroupStatusV1` must not change by a single byte;
the retained evidence driver still finds the page statement by its unchanged
`WITH inspection_groups AS MATERIALIZED` prefix.

Extend `keiro/test/GroupRebuildSpec.hs`. In the conservative-checkpoint example, after
registration assert that the first page's single item has
`feedingSubscriptions == ["catalog-async-subscription", "catalog-missing-subscription"]` and
`status.servingPositionBasis == ServingPositionCheckpoint`. In the adversarial example, after
the cursor row is deleted assert that the `counter-group` page item has `feedingSubscriptions
== []` with basis `ServingPositionUnmanaged`, and change the three-page concatenation check to
compare `map (^. #status)` of the items with the complete list. Add one assertion for an
inline-only group with basis `ServingPositionAppend` and an empty list; `smallerCatalog` in
`keiro/test/CatalogSpec.hs` (no subscriptions) or the `opsCatalog` case in Milestone 2 may
supply it. Acceptance for this milestone is those focused tests passing and a diff of the
unchanged statements against the baseline worktree being empty.


### Milestone 2: CLI, HTTP, and feed encoders with the jitsurei proof


Scope: expose the field everywhere the page is rendered, with the existing key set and values
untouched. At the end, `projection status --json`, `GET /projection/status`, and
`projection_groups` feed items each carry `feeding_subscriptions`, and jitsurei demonstrates the
real values.

In `keiro-ops/src/Keiro/Ops/Projection.hs`, split the existing encoder into a pair list and add
a row encoder, keeping `projectionGroupStatusJson` exported with its current meaning:

```haskell
projectionGroupStatusPairs :: ProjectionGroupStatusV1 -> [Pair]
projectionGroupStatusPairs row = [ "group_id" .= rebuildGroupIdText row.groupId, {- ... the existing 18 pairs ... -} ]

-- | The frozen v1 row using ADR-28 position vocabulary; its key set is unchanged.
projectionGroupStatusJson :: ProjectionGroupStatusV1 -> Value
projectionGroupStatusJson = object . projectionGroupStatusPairs

-- | A page item: the v1 keys plus Keiro's registered feeding subscriptions.
projectionGroupStatusRowJson :: ProjectionGroupStatusRow -> Value
projectionGroupStatusRowJson row =
  object (("feeding_subscriptions" .= row.feedingSubscriptions) : projectionGroupStatusPairs row.status)
```

Switch the `Status` handler's `items` to `projectionGroupStatusRowJson` and read the human
table's cells through `row.status`; the human table keeps its four columns. Export
`projectionGroupStatusRowJson`. In `keiro-ops-http/src/Keiro/Ops/Http/Views.hs`, change
`projectionGroupsView` to key items by `row.status.groupId` and encode bodies with
`projectionGroupStatusRowJson`. No route, protocol, limit, deadline, or schema-check code
changes; `GET /projection/status` is derived from the unchanged grammar.

Update tests to the new shapes and add the new assertions. In `keiro-ops/test/Main.hs`, the
projection status example compares `items` with `map projectionGroupStatusRowJson page.items`
and additionally asserts that each item object contains `feeding_subscriptions` equal to `[]`
(the `opsCatalog` group is inline-only, basis `append`) and that removing that key yields
exactly `projectionGroupStatusJson item.status`, which proves the existing key set and values
are unchanged. In `keiro-ops-http/test/Test/WebSocketSpec.hs`, compare `changed` with the row
encoder; the existing head-only update must still report an empty `changed` array, which shows
the constant field creates no extra deltas. The `cliReads` parity entry for
`/projection/status?limit=1` needs no edit and must keep passing.

In `jitsurei/test/Main.hs`, add to the "Jitsurei read model" group an example that, after
`initializeJitsureiTables`, pages the status API and asserts the `jitsurei-order-reporting`
item has `feedingSubscriptions == ["jitsurei-order-audit-subscription"]` with basis
`ServingPositionCheckpoint`; and to the "Jitsurei agent-qualification router" group an assertion
that, after `initializeAreaChapters`, the `$legacy-read-model:jitsurei-area-chapters` item has
`feedingSubscriptions == []` with basis `ServingPositionUnmanaged`. Then demonstrate the same
over the executables against the disposable jitsurei database as described in Concrete Steps:
`jitsurei-demo ops projection status --json` and `GET /projection/status` from the
database-only `keiro-ops-http` server both show those values. Acceptance for this milestone is
the keiro-ops, keiro-ops-http, and jitsurei suites passing plus the two transcripts.


### Milestone 3: Performance evidence for the changed read and proof of unchanged paths


Scope: show, with retained artifacts, that the page read keeps its plan shape and cost, that the
compatibility APIs are unchanged, and that no writer or schema path moved. At the end, a new
evidence folder `keiro/bench/results/inspection/projection-status-feeding-subscriptions/`
holds the paired results, and the read-model guard has passed on the candidate.

Write `scripts/inspection-projection-feeding-subscriptions-evidence.hs` by copying
`scripts/inspection-projection-status-evidence.hs` and making three changes. Give every tenth
group a `checkpoint` basis with `subscription_names = ARRAY[group_id || '-sub']` so the join
returns non-empty arrays for a realistic stripe (the check constraint requires non-empty
arrays exactly for `checkpoint`); keep every other group `append` so the view's own cost
stays comparable with the retained 2026-10-20 evidence. Take five `EXPLAIN (ANALYZE, BUFFERS,
SETTINGS, FORMAT JSON) EXECUTE` samples per shape instead of one, recording each plan and
its `Execution Time`. Assert on the returned page that `length page.items` is 100 for both
shapes; the driver must not touch `feedingSubscriptions`, so the same source compiles against
the baseline worktree, which lacks the field. Compile the identical driver source separately against both checkouts before sampling,
using the same compiler flags and dependency versions. Run the two compiled executables in
three pairs, baseline/candidate, candidate/baseline, baseline/candidate, on a quiet
machine with no builds or tests running, and write each run's JSON to the evidence folder. A
small Python summary (kept beside the results as `summarize.py`) computes, per shape and plan
mode, pair number, and sample ordinal, the fifteen candidate/baseline `Execution Time`
ratios. Report their median, minimum and maximum, plus each side's absolute median. Reject
missing samples, duplicate identities, wrong row counts, nonpositive timings, or settings
mismatches; exit nonzero if any plan or ratio gate fails. Do not discard outliers. The
historical all-append fixture timings are context, not a numeric gate for this changed
fixture; the same-fixture paired ratio is the quantitative acceptance criterion.

Acceptance has four parts. First, plan shape: in every candidate plan the cursors relation
appears as an `Index Scan` or `Index Only Scan` using `keiro_projection_group_cursors_pkey`
under a `Nested Loop`, with its index condition bound to the page key. An explicit CASE condition on the
frozen status basis skips append/unmanaged rows: their arrays are empty by the existing
private table constraint. Actual added index-scan loops equal the checkpoint keys selected,
including look-ahead (10 in these 101-row SQL windows with a ten-percent checkpoint stripe);
the CASE projection handles the 101 SQL rows and invokes the scalar subquery only for those 10 checkpoint keys. The view's own cursor probes remain
unchanged. There must be no extra private-table probe for proven-empty arrays;
identify the newly added lookup by its SQL alias, since the frozen view also reads this
relation. The materialized page must feed the outer subtree, not necessarily its immediate
child. A correctly empty or final page may have fewer probes; a `Seq Scan` or `Hash Join` over `keiro_projection_group_cursors` at the fleet level
fails. Second, cost: the paired median ratio is at most 1.10 for first and deep pages at 10k
and 100k groups under both forced plan modes, and report absolute medians alongside the historical evidence (about 2.8 ms first page
and 0.6 ms deep page at 100k), attributing large changes without treating that different
fixture as a calibrated threshold. Third, unchanged paths: `just bench-regression read-model` on the candidate prints
`GUARD(read-model)=PASSED` with the committed `keiro/bench/baseline-read-model.csv` untouched;
`git diff d64849f1 -- keiro-migrations/ keiro/src/Keiro/ReadModel/Rebuild/Group.hs
keiro/src/Keiro/ReadModel/Schema.hs` is empty; and `cabal test keiro-migrations-test` passes
with `keiro-migrations/expected-schema/native/keiro-v18.txt` unchanged. Retain the driver
source as `driver.hs.txt`, a `README.md` stating machine, PostgreSQL version and durable
settings, both commits, both binary paths and hashes, the acceptance figures, and a
`manifest.json` with sha256 of every artifact, following the layout of
`keiro/bench/results/inspection/projection-status-read/`. If the ratio ceiling is exceeded,
stop, attribute the cause in Surprises & Discoveries, and either remove it or obtain a scope
decision; do not record a new baseline or relax the ceiling (ADR-58).


The fourth acceptance part is the matched writer cohort specified in Progress. Extend
`keiro-ops-http/bench/InspectionInterference.hs` with `projection-idle`, `projection-poll`
and `projection-feed` modes, seed the same checkpoint stripe, and extend
`keiro-ops-http/bench/InspectionClients.hs` with real polling/feed clients that validate
non-empty arrays. Use `scripts/measure-projection-feeding-subscriptions.sh` for five
alternating pairs plus same-source idle controls and
`scripts/analyze-projection-feeding-subscriptions.py` for the fixed trial-level bootstrap.
Retain every trial under the evidence folder's `interference/` directory. The analyzer
must exit nonzero for invalid load, a supported regression, or inconclusive precision;
none can complete this milestone. Preserve all samples and report uncertainty.
Compile the same harness sources separately against both package sets, exposing the
`keiro`, `keiro-ops`, `keiro-ops-http`, `jitsurei`, and `keiro-test-support` packages with
GHC flags `-O1 -threaded -rtsopts -XGHC2024 -XBlockArguments -XLambdaCase -XOverloadedStrings`
and the harness directory on `-i`; use separate object/output paths. Build the baseline
`keiro-ops-http:bench:inspection-interference --enable-benchmarks` first to make its
transport dependencies available. Retain both exact harness sources, flags, binary hashes,
package plans, the analyzer and controller with the evidence.


### Milestone 4: Documentation, ADR amendment, request completion, and verification


Scope: make the field discoverable and close the request. At the end, every governed document
validates and `just verify` passes.

In `docs/user/operations.md` ("Projection status pages"), state that each item also carries
`feeding_subscriptions`, what it means for `checkpoint`, `append`, and `unmanaged` rows, that it
comes from Keiro's registration metadata and not from the v1 relation, and show one example
item. In `docs/user/read-models-and-projections.md`, after the Haskell callers paragraph, state
that `listProjectionGroupStatusesPage` returns `ProjectionGroupStatusRow` values whose `status`
is the unchanged 18-field v1 row and whose `feedingSubscriptions` is the registered authority,
and that the SQL relation does not publish it. In `docs/guides/stream-keiro-inspection-views.md`,
add one sentence that `projection_groups` item bodies equal `projection status` items,
including `feeding_subscriptions`. Advance each document's `timestamp` and append log entries
with `okf log add docs/user` and `okf log add docs/guides`.

Amend `docs/adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md` by
extending its closing paragraph about the additive page API: the page API carries the
registered subscription set beside the frozen row from Keiro's private cursor-authority table,
the v1 relation remains unextended, and `unmanaged` rows report an empty set because their
authority is unknown. Advance the ADR `timestamp`, append `okf log add docs/adr`, and run
`just adr-validate`. Add changelog entries under `[Unreleased]`: in `keiro/CHANGELOG.md` a
Breaking Changes entry that `ProjectionStatusPage.items` now holds `ProjectionGroupStatusRow`
(reach the frozen row through `status`), and a New Features entry for the field; in
`keiro-ops/CHANGELOG.md` and `keiro-ops-http/CHANGELOG.md` New Features entries for
`projection status` items and `projection_groups` feed items; and the same in `CHANGELOG.md`.

Close IR-57 as the bundle precedent does: `status: completed`, `completedAt`, a `resolution`
naming this plan, the corrected contract, and the retained evidence folder, a rewritten Status
section, an advanced `timestamp`, and a `Completion` log entry. Record this plan's Outcomes &
Retrospective, then run the full `just verify` in the Nix shell on the final candidate.


## Concrete Steps


All commands run from the repository root inside the Nix shell. Enter it from the root, not a
package directory, because `nix develop` initializes a PostgreSQL cluster relative to the
current directory. Confirm the toolchain once:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop -c ghc --version
nix develop -c z3 --version
```

Expected: `version 9.12.4` and `Z3 version 4.16.0`. Prefix every later command with
`nix develop -c`, or run them after `nix develop`.

Record the baseline and link the request before the first implementation commit:

```bash
git status --short
git rev-parse HEAD
git worktree add --detach ../keiro-feeding-subscriptions-baseline d64849f1
```

Expected: a new detached worktree at `d64849f19d2d922a5373b121d13d0fac5bc9132f`.
Record the current HEAD separately; documentation commits may have advanced it. Preserve
unrelated working-tree edits. If relevant runtime or fixture code has advanced beyond this
baseline before implementation, refresh the comparison baseline and record why first.
Then edit `docs/improvement-requests/name-the-feeding-subscription-on-projection-status-rows.md`
as Milestone 1 describes and run:

```bash
okf log add docs/improvement-requests --kind Update -m "IR-57 accepted under ExecPlan 327: corrected to a feeding_subscriptions array beside the unchanged v1 relation, with jitsurei-order-audit-subscription as the jitsurei value."
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
```

Expected: the validation ends with `OK: 60 concepts`.

Implement Milestone 1 in `keiro/src/Keiro/ReadModel/Rebuild/Status.hs`,
`keiro/src/Keiro/ReadModel/Rebuild.hs`, and `keiro/test/GroupRebuildSpec.hs`, then prove the
unchanged statements and run the focused suite:

```bash
python3 - <<'PYCODE'
from pathlib import Path
import subprocess
path = 'keiro/src/Keiro/ReadModel/Rebuild/Status.hs'
before = subprocess.check_output(['git', 'show', 'd64849f1:' + path], text=True)
after = Path(path).read_text()
# Compare whole preserved regions, including types, decoder, and SQL bodies.
regions = [
    ('data ProjectionGroupStatusV1 =', '-- | A bounded observation'),
    ('listProjectionGroupStatuses ::', 'decodeGroupId ::'),
]
for start, end in regions:
    def region(source):
        return source[source.index(start):source.index(end, source.index(start))]
    assert region(before) == region(after), f'compatibility region changed: {start}'
print('compatibility definitions unchanged')
PYCODE
cabal build keiro --enable-tests
cabal test keiro-test --test-options='-m "catalog rebuild groups"' --test-show-details=direct
```

Expected: the first command exits 0 and prints `compatibility definitions unchanged`.
Place new row definitions and the new decoder outside the preserved regions; this check
compares entire definitions rather than matching selected diff lines. Then and the spec reports the extended examples passing with zero failures.

Implement Milestone 2 in `keiro-ops/src/Keiro/Ops/Projection.hs`,
`keiro-ops-http/src/Keiro/Ops/Http/Views.hs`, and the three test suites, then run:

```bash
cabal build all --enable-tests --enable-benchmarks
cabal test keiro-ops-test --test-show-details=direct
cabal test keiro-ops-http-test --test-show-details=direct
cabal test jitsurei-test --test-show-details=direct
```

Expected: every suite passes with zero failures. Then demonstrate the real values against a
disposable repository-local jitsurei database. The `jitsurei-*` recipes in the `justfile`
create and migrate the database named by `JITSUREI_DATABASE` (default `jitsurei`) in the
shell's cluster under `db/`, and the demo reads its connection from `PG_CONNECTION_STRING`.
The fulfillment demo registers the catalog and the agent-qualification demo registers the
legacy read model:

```bash
export JITSUREI_DATABASE=jitsurei_plan327
just jitsurei-fulfillment
just jitsurei-agent-qual
export PG_CONNECTION_STRING="host=$PWD/db dbname=$JITSUREI_DATABASE user=$(whoami)"
cabal run jitsurei-demo -- ops --database-url "$PG_CONNECTION_STRING" projection status --json | jq '.items[] | {group_id, serving_position_basis, feeding_subscriptions}'
```

Expected output includes these two objects (other legacy groups may also appear with empty
arrays):

```json
{"group_id":"$legacy-read-model:jitsurei-area-chapters","serving_position_basis":"unmanaged","feeding_subscriptions":[]}
{"group_id":"jitsurei-order-reporting","serving_position_basis":"checkpoint","feeding_subscriptions":["jitsurei-order-audit-subscription"]}
```

If a recipe or connection form differs, follow `docs/guides/run-and-operate-jitsurei.md`; the
acceptance is the two objects above, not the exact invocation. Then serve the same database
over HTTP with the database-only executable and query the route:

```bash
cabal run exe:keiro-ops-http -- --database-url "$PG_CONNECTION_STRING" --port 9092 &
curl -s 'http://127.0.0.1:9092/projection/status?limit=100' | jq '.items[] | {group_id, serving_position_basis, feeding_subscriptions}'
kill %1
```

Expected: the same two objects, and the `jitsurei-order-reporting` item's other keys equal to
the CLI's. Record both transcripts in the plan's Progress entry for Milestone 2.

For Milestone 3, build the candidate, then compile and run the driver from both checkouts on a
quiet machine. The driver reads `DATABASE_URL`-independent disposable databases through
`Keiro.Test.Postgres`, which uses the Nix shell's cluster:

```bash
cabal build all --enable-tests --enable-benchmarks
mkdir -p keiro/bench/results/inspection/projection-status-feeding-subscriptions
# From the repository root in the Nix shell, build both before sampling.
projection_evidence="$PWD/keiro/bench/results/inspection/projection-status-feeding-subscriptions"
projection_driver="$PWD/scripts/inspection-projection-feeding-subscriptions-evidence.hs"
mkdir -p "$projection_evidence/build-baseline" "$projection_evidence/build-candidate"
(cd ../keiro-feeding-subscriptions-baseline && cabal build keiro keiro-test-support && cabal exec -- ghc -O2 -threaded -XGHC2024 -package keiro -package keiro-test-support -outputdir "$projection_evidence/build-baseline" "$projection_driver" -o "$projection_evidence/baseline-driver")
cabal exec -- ghc -O2 -threaded -XGHC2024 -package keiro -package keiro-test-support -outputdir "$projection_evidence/build-candidate" "$projection_driver" -o "$projection_evidence/candidate-driver"
for run in 1 2 3; do
  if [ "$run" = 2 ]; then
    "$projection_evidence/candidate-driver" "$projection_evidence/candidate-$run.json"
    "$projection_evidence/baseline-driver" "$projection_evidence/baseline-$run.json"
  else
    "$projection_evidence/baseline-driver" "$projection_evidence/baseline-$run.json"
    "$projection_evidence/candidate-driver" "$projection_evidence/candidate-$run.json"
  fi
done
python3 keiro/bench/results/inspection/projection-status-feeding-subscriptions/summarize.py keiro/bench/results/inspection/projection-status-feeding-subscriptions > keiro/bench/results/inspection/projection-status-feeding-subscriptions/summary.json
just bench-regression read-model
cabal test keiro-migrations-test
git diff d64849f1 --stat -- keiro-migrations/ keiro/src/Keiro/ReadModel/Rebuild/Group.hs keiro/src/Keiro/ReadModel/Schema.hs
```

Expected: six JSON files each containing samples for 10k and 100k groups, custom and generic
plans, first and deep pages; a `summary.json` whose every `paired_median_ratio` is at most
`1.10` and whose candidate plans all show the cursors primary-key probe; the guard output
ending with `GUARD(read-model)=PASSED` and `BENCH_REGRESSION=PASSED`; the migrations suite
passing; and an empty diff listing. Write `README.md`, copy the driver to
`driver.hs.txt`, and create `manifest.json` with sha256 of each retained artifact except
`manifest.json` itself. Keep compiled executables and object directories local; record their
paths and hashes plus compiler flags and both Cabal dependency plans in the README, and retain
the source, plans, raw samples, summary script and results for reproduction.

For Milestone 4, after the documentation edits:

```bash
okf log add docs/user --kind Update -m "Operations and Read Models And Projections: document feeding_subscriptions on projection status items beside the unchanged v1 relation (plan 327)."
okf log add docs/guides --kind Update -m "Stream Keiro Inspection Views: projection_groups item bodies carry feeding_subscriptions like projection status items (plan 327)."
okf log add docs/adr --kind Update -m "ADR-35: the page API carries the registered subscription set beside the frozen v1 row; the relation stays unextended (plan 327)."
okf log add docs/improvement-requests --kind Completion -m "IR-57 completed under ExecPlan 327: feeding_subscriptions on projection status items and projection_groups feed items with retained paired page-read evidence."
just adr-validate
just user-documentation-validate
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
just verify
```

Expected: each validation reports success and `just verify` exits 0. Every commit carries the
trailers below; use Conventional Commits types (`feat(read-model):`, `feat(ops):`,
`test(jitsurei):`, `docs(adr):`, `docs(improvement-requests):`, `perf(bench):` for evidence).

```text
ExecPlan: docs/plans/327-name-the-feeding-subscriptions-on-projection-status-pages-without-runtime-performance-regressions.md
Intention: intention_01m6jhc50pe16vyf19m52r91nc
```

Remove the baseline worktree only after the evidence is committed:

```bash
git worktree remove ../keiro-feeding-subscriptions-baseline
```


## Validation and Acceptance


The plan is complete when all of the following hold on the final candidate, including
the matched writer-interference protocol specified in Progress and Milestone 3. A
query-only pass cannot establish runtime acceptance.

Behavior. `keiro-ops projection status --json` (and `jitsurei-demo ops projection status
--json`) returns items that each contain `feeding_subscriptions`. For jitsurei after catalog
registration, the `jitsurei-order-reporting` item has
`"feeding_subscriptions":["jitsurei-order-audit-subscription"]` and
`"serving_position_basis":"checkpoint"`; every `$legacy-read-model:*` item has
`"feeding_subscriptions":[]` and `"serving_position_basis":"unmanaged"`. `GET
/projection/status?limit=100` from `keiro-ops-http` returns the same items as the CLI. A
`projection_groups` feed snapshot's items equal the poll's items, and a head-only refresh still
publishes an empty `changed` array. Removing `feeding_subscriptions` from any item yields
exactly the previous v1 encoding, so no existing key or value changed.

Library. `listProjectionGroupStatusesPage` returns `ProjectionGroupStatusRow` items; for the
`catalogWithMissingSubscription` group the list is
`["catalog-async-subscription", "catalog-missing-subscription"]`; for an inline-only group it is
`[]` with basis `append`; after the authority row is deleted it is `[]` with basis `unmanaged`.
Three pages of 100 over 251 groups, projected through `status`, equal
`listProjectionGroupStatuses`. `ProjectionGroupStatusV1`, `listProjectionGroupStatuses`,
`lookupProjectionGroupStatus`, and the SQL text they use are byte-identical to `d64849f1`.

Contract. `keiro_read.projection_group_status_v1` is unchanged: `cabal test
keiro-migrations-test` passes with no edit to the migration or to
`keiro-migrations/expected-schema/native/keiro-v18.txt`, and the jitsurei external-reader
examples that select from the view pass unchanged.

Performance, per guarantee and the gate that measures it. Writer and registration paths:
structural, by the empty diff over `keiro-migrations/`, `Group.hs`, and `Schema.hs`, and by the
unchanged schema snapshot. Complete-list and lookup APIs: the read-model benchmark guard
(`just bench-regression read-model`) passes against the committed baseline with byte-identical
SQL. Bounded page read: the retained paired cohort in
`keiro/bench/results/inspection/projection-status-feeding-subscriptions/` shows the
primary-key probe plan shape and paired median ratios at most 1.10 for all eight shapes
(two sizes, two plan modes, two page positions), with absolute medians reported and contextualized against the retained 2026-10-20 evidence. HTTP and feeds: no limit, deadline,
or schema-check code changed, the suites pass, and the matched idle/poll/feed cohort
satisfies the fixed runtime interval and load criteria in Progress and Milestone 3. The release gate's six guards cannot observe
the page read; the paired cohort is its sole measurement and is required.

Tests. `cabal test keiro-test keiro-ops-test keiro-ops-http-test jitsurei-test
keiro-migrations-test` pass, and `just verify` exits 0 in the Nix shell.

Documentation and governance. `DOC-15`, `DOC-19`, `DOC-31`, ADR-35, and IR-57 carry advanced
timestamps with matching log entries; the four changelogs have `[Unreleased]` entries; IR-57 is
`completed` with `completedAt`, `resolution`, and `plan`; and the three strict validations
succeed.

Not required by this plan, and a scope decision if wanted later: adding the field to
`lookupProjectionGroupStatus`; a `feeding_subscriptions` column in the human table; a
`projection_group_status_v2` SQL relation for out-of-process SQL readers; and any change to the
keiro runtime console.


## Idempotence and Recovery


Every step is additive and repeatable. The IR, documentation, ADR, and changelog edits are plain
text; re-running `okf log add` appends a duplicate entry, so check `log.md` before repeating it
and remove an accidental duplicate by hand. The evidence driver creates and drops disposable
databases and can be rerun freely; delete a partial `*-N.json` and rerun that iteration. The
baseline worktree is detached and read-only in intent; if it is dirty or missing, recreate it
from `d64849f1`. If the paired ratio fails, keep the failing artifacts in the evidence folder
with a README stating they are not accepted, attribute the cause, and do not edit
`keiro/bench/baseline-read-model.csv`. If a focused test fails after the type change, the most
likely cause is a remaining `row.groupId` or `row ^. #groupId` that must become
`row.status.groupId`; the compiler reports each site. The production reader introduces no writes or migration. Tests, demos and benchmark fixture
setup do write to disposable databases; their cleanup must remain bracketed. Thus no
production data migration needs rollback;
reverting the commits restores the previous API exactly.


## Interfaces and Dependencies


`keiro/src/Keiro/ReadModel/Rebuild/Status.hs` gains `ProjectionGroupStatusRow` with fields
`status :: ProjectionGroupStatusV1` and `feedingSubscriptions :: [Text]`;
`ProjectionStatusPage.items` becomes `[ProjectionGroupStatusRow]`; the type is re-exported
from `keiro/src/Keiro/ReadModel/Rebuild.hs`. `ProjectionGroupStatusV1`, `ServingPositionBasis`,
`listProjectionGroupStatuses`, `lookupProjectionGroupStatus`, `ProjectionStatusPageRequest`,
`ProjectionStatusReadError`, `projectionGroupsCursorKind`, and
`validateProjectionStatusRequest` are unchanged.

`keiro-ops/src/Keiro/Ops/Projection.hs` exports `projectionGroupStatusJson ::
ProjectionGroupStatusV1 -> Value` (unchanged meaning) and the new
`projectionGroupStatusRowJson :: ProjectionGroupStatusRow -> Value`, which adds exactly one
key, `feeding_subscriptions`, holding a JSON array of strings.
`keiro-ops-http/src/Keiro/Ops/Http/Views.hs` consumes the row encoder; the feed protocol in
`keiro-ops-http/src/Keiro/Ops/Http/Protocol.hs` and the route derivation are unchanged.

Dependencies are the existing ones: `hasql` decoders (`D.listArray` for `text[]`), `aeson`,
and the `kiroku-store` cohort already pinned at `^>=0.13.0.1`. No new package, flag, migration,
or Kiroku API is introduced. The evidence driver depends on `keiro` and `keiro-test-support`
(`Keiro.Test.Postgres`) exactly like `scripts/inspection-projection-status-evidence.hs`.


Revision note (2026-11-04): Reviewed against the current reader, fixtures, transports and
ADRs. Refreshed the pre-change baseline after intervening host/test-support changes, removed
the assumed join-plan guarantee, corrected look-ahead probe counts, replaced the ineffective
compatibility grep, and made the paired benchmark use compiled, attributable executables
with explicit ordering, aggregation and manifest rules. Recorded the unresolved gap between
SQL-only timing and the requested runtime guarantee. Implementation and performance
acceptance remain outstanding.


Implementation revision (2026-11-04): Implemented the enriched bounded row and shared
encoders without changing the frozen relation or compatibility SQL, selected the fenced
lateral lookup after observing a generic-plan merge join, and added the projection-specific
writer cohort, same-source controls and explicit confidence-interval refusal rules before
sampling. Corrected the embedded CLI proof to pass its database URL explicitly. Behavioral,
contract and full repository verification pass; timing acceptance remains open.


Optimization revision (2026-11-04): The rejected loaded diagnostic motivated a guarded
metadata lookup. Use the existing basis/array constraint to skip append and unmanaged
rows, retain the per-key lateral fence, and validate 10 added probes for the fixture's
10 checkpoint keys rather than performing 101 unnecessary probes. Numeric performance
ceilings, source/schema compatibility and runtime acceptance are unchanged. The earlier
full verification log is evidence for the pre-optimization candidate; validate the final
query before completion.


Scalar-probe revision (2026-11-04): The guarded lateral cohort is retained under
`loaded-diagnostic-v2/` and remains unaccepted (background overlap and 1.1046 in one
shape). The final CASE-controlled scalar subquery keeps 10 keyed probes on this fixture
and removes the added join for all 101 SQL rows. The existing public-view fence, the
frozen definitions, and every numeric and runtime gate remain unchanged.
