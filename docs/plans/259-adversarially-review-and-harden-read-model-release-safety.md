---
id: 259
slug: adversarially-review-and-harden-read-model-release-safety
title: "Adversarially review and harden read-model release safety"
kind: exec-plan
created_at: 2026-08-14T03:12:49Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
master_plan: "docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md"
---

# Adversarially review and harden read-model release safety

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, Keiro's first stable read-model lifecycle is backed by adversarial
evidence rather than only happy-path acceptance tests. Version-managed projection
groups preserve the catalog's declared inline and subscription delivery boundaries;
their cutover attempts obey a real overall deadline; large deduplication histories do
not turn a nominally brief promotion into an unbounded in-memory operation; and the
remaining status, external-read, and targeted-repair work has received a second review
against hostile concurrency, scale, privilege, upgrade, and failure conditions.

The result is observable in tests that deliberately use non-idempotent mixed-delivery
handlers, contend on more than one promotion relation, create a large subscription lag,
hold long reader and writer transactions, race registration and promotion, and fail at
each persisted lifecycle boundary. Comparative benchmarks quantify the ordinary write
cost of version management and the status/read-contract query cost. This plan is not
complete merely when findings are written down: every critical or high-severity finding
must be fixed and protected by a regression test before MasterPlan 41 and the 0.12.0.0
compatibility boundary can close.

This is EP-5 of
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`.
It begins with corrective work against completed plan 256, reviews plan 254, plan 255,
and plan 257 as their implementations become complete, and finishes as the mandatory
cross-plan release gate.


## Progress

- [x] (2026-08-14T08:05:14Z) M1: revision live handlers retain exact inline or
  subscription delivery authority; mixed-delivery versioned groups execute each effect
  once at the declared boundary before, during, and after promotion.
- [x] (2026-08-14T08:43:20Z) M2: writer-fence acquisition and promotion use a true overall deadline, expensive
  verification and deduplication preparation leave the exclusive-lock phase, and large
  dedup histories are staged and admitted before fencing.
- [x] (2026-08-14T09:42:24Z) M3: steady-state versioned inline/async writes, status
  reads, guarded reads, and cutover/repair scale have comparative benchmarks with
  explicit regression budgets.
- [ ] M4: the delivered implementations of plans 254, 255, and 257 have each passed a
  recorded adversarial correctness, concurrency, security, performance, and
  compatibility review; every critical/high finding is resolved.
  - [x] (2026-08-14T10:11:50Z) EP-2 status contract reviewed at `18eaf279`,
    `7b57e639`, and `1b71f0d6`, integrated through `353e8d3c` and `9f985f76`;
    checkpoint/cardinality, promotion atomicity, restricted-role, query-plan, and
    pre-0026 rolling-upgrade evidence pass with no critical or high finding.
  - [ ] EP-3 guarded external-read contract review.
  - [ ] EP-4 targeted stream-repair review.
- [ ] M5: cross-plan fault injection, bridge/rolling-upgrade evidence, ADR and contract
  reconciliation, changelogs, corpus replay, and `just verify` pass; MasterPlan 41 is
  eligible to close.


## Surprises & Discoveries

- The existing Jitsurei bridge test encoded the defect as expected behavior: its audit
  row advanced after a command without subscription delivery. Splitting the revision
  closure made the test fail until it explicitly delivered and redelivered the event.
- Revision live target requirements cannot remain group-total after delivery identity
  is restored. Replay adapters and revision verifiers still require the complete group,
  while each live handler must require exactly its supplying projection's owned targets.
- PostgreSQL `statement_timeout` cannot express one budget across several client-issued
  statements. Database-clock deadline helpers are needed both to catch the timeout into
  a typed, still-usable transaction outcome and to apply the remaining budget before
  the group-row and cumulative relation-lock statements.
- Moving dedup installation and checkpoint reconciliation before target locks requires
  a durable prepared boundary. A target-lock timeout must preserve that earlier committed
  safety evidence and keep the writer fence, rather than pretending the whole cutover
  attempt began from an unfenced state.
- A sequential benchmark over one shared event store biased later scenarios through a
  continually growing event index. Seeding 25,000 irrelevant events before measurement
  stabilized that index, while an alternating legacy/versioned sampler removed ordering
  bias from the release gate.
- PostgreSQL showed that the indexed serving-generation lookup itself was inexpensive;
  the avoidable cost was its separate round trip after group locking. Returning group,
  revision, epoch, and serving target bindings from one locked query removed that round
  trip without retaining mutable database bindings in process memory.
- Returning one result row per serving target still duplicated the group metadata and
  left the throughput gate at roughly 89.5 percent. Ordered PostgreSQL arrays reduce the
  same locked result to one row; the final alternating samples retain roughly 98 percent
  of legacy throughput without changing the epoch or lock boundary.
- A validated catalog is immutable, but live revision dispatch still searched its
  revision and handler lists for every write. Derived `Map` indexes preserve catalog
  validation and fingerprint semantics while making source, revision, delivery-handler,
  and async-registration lookup independent of non-serving revision count.
- Creating the read-model scale fixture in the benchmark executable's existing shared
  database contaminated unrelated command fan-out measurements with 25,000 extra
  events. Giving the new fixture its own fresh migrated database preserves the existing
  benchmark families' cardinalities and makes resource isolation part of the harness.
- Kiroku's frozen `subscription_checkpoints_v1` contract publishes durable member rows
  but not expected consumer-group size. The EP-2 implementation can reject a missing
  bound subscription and floor every published member, but even an adversarial review
  cannot make it detect a missing highest-numbered member within an otherwise present
  subscription without crossing Kiroku's private-schema boundary.
- The status relation needs no explicit coordination protocol for a promotion reader:
  PostgreSQL statement snapshots plus the transactional group/run metadata transition
  expose the complete old tuple until commit and the complete new tuple after commit.
  A separate-session test that holds the transition open for one second observed no
  mixed serving/candidate state.


## Decision Log

- Decision: Make this plan a fixing and verification gate, not a review-only report.
  Rationale: a documented data-integrity, security, or unbounded-availability defect is
  still a release defect. The first stable contracts must not ship with a known
  critical or high-severity finding delegated to an unspecified future plan.
  Date: 2026-08-13
- Decision: Start against completed EP-1 while treating EP-2 through EP-4 as rolling
  integration dependencies.
  Rationale: the known revision-routing and cutover problems can be corrected now; the
  other plans must be reviewed from their delivered code rather than delaying all work
  until the end or reviewing only prose.
  Date: 2026-08-13
- Decision: Preserve delivery authority inside projection-revision identity.
  Rationale: target schema revision selects which SQL may execute, but it must not
  erase whether that SQL belongs to command-time inline delivery or to one particular
  durable subscription and deduplication authority.
  Date: 2026-08-13
- Decision: Define release severity by user impact and require zero open critical or
  high findings.
  Rationale: critical means possible incorrect data, safety-boundary bypass, or
  irreversible loss; high means an unbounded outage, privilege escape, stable-contract
  violation, or ordinary workload with uncontrolled memory/lock growth. Medium and low
  findings may remain only with an explicit owner, rationale, and bounded follow-up.
  Date: 2026-08-13
- Decision: Include the inline handler name in inline revision-delivery identity in
  addition to the supplying projection ID.
  Rationale: projection definitions support several ordered inline handlers; retaining
  the name prevents them from collapsing into one ambiguous capability while keeping
  subscription identity anchored by its already-unique subscription and dedup IDs.
  Date: 2026-08-14
- Decision: Persist incremental async dedup evidence per versioned run and make the
  positive promotion limit part of start/resume identity.
  Rationale: database staging bounds process residency and makes oversized redelivery
  windows observable and rejectable before writers are fenced. The conservative
  admission reserves `cutoverThreshold` rows for every async dedup specification, then
  preparation rechecks the exact staged count.
  Date: 2026-08-14
- Decision: Split fenced preparation from relation-locked promotion.
  Rationale: application verification, set-based dedup installation, checkpoint
  reconciliation, and retention release can be proportional to data or topology and
  must not extend reader-blocking target locks. The prepared marker gives crash recovery
  an explicit authority: promotion retries preserve the fence and prepared evidence.
  Date: 2026-08-14
- Decision: Measure each writer-fence or promotion attempt from an absolute PostgreSQL
  `clock_timestamp()` deadline and lock every target in one ordered statement.
  Rationale: a per-statement timeout multiplies with the object count and omitted the
  group-row wait. A shared deadline and one relation statement bound cumulative lock
  acquisition while phase-specific typed errors preserve resumability.
  Date: 2026-08-14
- Decision: Lock a projection group and return its persisted serving revision, epoch,
  and complete serving-target binding in one statement.
  Rationale: a `FOR SHARE` group subquery plus an indexed lateral generation lookup
  observes one epoch under the same group lock and removes the version-managed write's
  extra network round trip. Four ordered target/revision/schema/relation arrays return
  that binding in one result row rather than duplicating group metadata per target.
  Only immutable validated-catalog facts are indexed in memory; persisted revision and
  generation bindings are never cached across an unobserved epoch.
  Date: 2026-08-14
- Decision: Gate ordinary write overhead with five warmed, alternating runs of 500
  complete legacy/versioned transactions and compare the median run ratios.
  Rationale: one tasty-bench mean is useful diagnostic evidence but cannot establish a
  percentile budget and is vulnerable to run-order noise. The repeated sampler enforces
  p95 at most 1.25 times legacy and throughput at least 90 percent of legacy.
  Date: 2026-08-14
- Decision: Keep lifecycle and read scale baselines separate from the paired projection
  baseline.
  Rationale: the projection file expresses like-for-like overhead and owns the hard
  relative gate, while lifecycle/read measurements have different cardinalities and
  absolute shapes. Separate CSV artifacts make both regressions reviewable through the
  existing tasty-bench baseline convention.
  Date: 2026-08-14
- Decision: Keep `keiro_read.projection_group_status_v1` unchanged after the EP-2
  adversarial review and classify missing expected member topology as a medium residual
  owned by `mori://shinzui/kiroku`.
  Rationale: v1 truthfully reports the floor of all owner-published rows and fails closed
  when a required subscription is absent, while neither Keiro nor an external reader
  can infer unpublished group size. The bounded follow-up is an owner-published Kiroku
  topology/checkpoint v2 carrying expected member cardinality, followed by a Keiro v2
  status contract if complete-member detection is required; Keiro v1 will not read the
  private `kiroku.subscriptions` table or silently change its frozen meaning.
  Date: 2026-08-14


## Outcomes & Retrospective

- M1 restored delivery-scoped revision dispatch and advanced catalog/slice identity;
  the focused catalog, DSL, operator, and Jitsurei suites prove inline and subscription
  effects stay on their declared boundaries across promotion.
- M2 replaced process-resident historical dedup collection with incremental run-scoped
  PostgreSQL staging and a persisted admission limit. The schema-versioned suite passes
  22 examples, including independent writer-fence and promotion-group contention, two
  target relations held by separate reader sessions under one 500 ms attempt budget,
  durable prepared-state retry, and a 20-row lag refusal before fencing. The operator
  suite passes 46 examples and the migration suite passes 32 examples with 29 embedded
  native migrations and an exact PostgreSQL 18 schema snapshot.
- M3 added paired whole-transaction benchmarks for legacy and version-managed inline
  delivery across one target, three targets, three groups, 30 non-serving revisions,
  and mixed delivery, plus paired mixed async delivery. It also added serving-binding,
  three-target promotion, 10/100/1,000-event repair, status list/lookup, bounded all-row,
  and indexed keyed-read scale scenarios. The reproducible release commands are:

      KEIRO_READ_MODEL_P95=1 cabal bench keiro:keiro-bench --benchmark-options="-p projection --time-mode wall --hide-progress --timeout 1 --csv bench/baseline-projection.csv"
      cabal bench keiro:keiro-bench --benchmark-options="-p read-model --time-mode wall --hide-progress --timeout 1 --csv bench/baseline-read-model.csv"
      KEIRO_READ_MODEL_P95=1 cabal bench keiro-bench --benchmark-options="-p projection --time-mode wall --hide-progress --timeout 1 --baseline bench/baseline-projection.csv --fail-if-slower 25"
      cabal bench keiro-bench --benchmark-options="-p read-model --time-mode wall --hide-progress --timeout 1 --baseline bench/baseline-read-model.csv --fail-if-slower 25"

  The recorded machine is an Apple M1 Max (`arm64`, Darwin 25.6.0) running GHC 9.12.4,
  cabal-install 3.16.1.0, and PostgreSQL 18.4 through the local ephemeral Unix-socket
  test harness. Raw tasty-bench results are
  `keiro/bench/baseline-projection.csv` and
  `keiro/bench/baseline-read-model.csv`.
- The final five comparable three-target sampler runs produced `(p95 ratio, throughput
  ratio)` values `(1.0153, 0.9743)`, `(1.0252, 0.9671)`, `(1.0262, 1.1283)`,
  `(1.0104, 0.9741)`, and `(1.0387, 0.9704)`. Their medians are `1.0252` and
  `0.9741`, passing the `1.25` and `0.90` release budgets. The direct projection
  regression passed all 12 comparisons; the direct lifecycle/read regression passed
  all 10 comparisons.
- The recorded lifecycle/read means are 71.0/80.2 microseconds for legacy/versioned
  three-target serving binding, 13.3 milliseconds for three-target promotion,
  4.44/11.1/102 milliseconds for 10/100/1,000-event repair, 12.0 milliseconds for
  status listing and 95.6 microseconds for lookup among 1,000 synthetic groups,
  218 microseconds for exactly 100 all-row results, and 67.8 microseconds for a keyed
  result among 10,000 rows.
- With `KEIRO_READ_MODEL_EXPLAIN=1`, the benchmark captured
  `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for serving binding, status list/lookup,
  public all-row/keyed wrappers, and the private keyed implementation. The status list
  returned 1,017 total rows (1,000 synthetic plus 17 catalog groups) in 2.363 ms of
  database execution; the public all-row wrapper returned its enforced 100-row fixture
  in 0.566 ms; and the public keyed wrapper returned one row in 0.763 ms. The private
  keyed statement used `Index Scan` on `bench_versioned_keyed_g1_t1_pkey` and executed
  in 0.008 ms. The benchmark asserts the all-row result is exactly 100 so its sequential
  scan cannot be reported as a selective-query result; whether the stable contract also
  needs a runtime cardinality admission limit remains an explicit EP-3 adversarial
  review question in M4.
- `cabal test keiro:keiro-test` passes all 598 examples after the performance changes.
  An initial `just bench-regression` run exposed and led to correction of benchmark
  database contamination: the read-model fixture now uses a separate fresh migrated
  store from the older outbox, inbox, command, and rebuild fixtures. The older command
  recipe still exhausts tasty-bench's 100-second adaptive sampler for
  `domain.accepted-large` on this machine; its baseline and timeout policy are unchanged.
  Both new baseline commands pass from the isolated final tree.

### M4 EP-2 adversarial review — projection-group status

The reviewed delivery commits are `18eaf279` (migration and owner-rights view),
`7b57e639` (typed library lookup/list surface), and `1b71f0d6` (frozen contract and
documentation). The review used the current integrated tree through `353e8d3c` and
`9f985f76`, because cutover timing and scale work can change the facts observed by the
view.

The review attacked four hypotheses. First, malformed or partial checkpoint inventory
might publish an optimistic serving floor or multiply group rows. Second, a promotion
transaction might expose a mixed serving/candidate tuple. Third, a view grant might
leak private Keiro/Kiroku objects or depend on invoker privileges. Fourth, migration
0026 might silently assign append authority to pre-existing groups. The focused
reproduction commands and results were:

    cabal test keiro:keiro-test --test-options='--match "adversarial checkpoint inventory"'
    # 1 example, 0 failures
    cabal test keiro:keiro-test --test-options='--match "old or new status tuple"'
    # 1 example, 0 failures
    cabal test keiro-migrations:keiro-migrations-test --test-options='--match "0026 gives pre-existing groups"'
    # 1 example, 0 failures
    cabal test keiro:keiro-test --test-options='--match "catalog rebuild groups"'
    # 9 examples, 0 failures
    cabal test keiro:keiro-test --test-options='--match "schema-versioned cutover concurrency"'
    # 4 examples, 0 failures
    cabal test keiro-migrations:keiro-migrations-test
    # 33 examples, 0 failures

The checkpoint regression creates three required subscriptions with several members,
proves the published floor is 7, proves Kiroku rejects an exact duplicate member row,
removes one required subscription, injects duplicate cursor authority, and removes the
cursor row. Each malformed case remains one row per group and reports unknown progress;
missing authority reports `unmanaged`. Listing 251 groups remains unique and sorted.
The rolling-upgrade regression applies migrations only through 0025, inserts a live
group, then applies 0026 through 0029 and proves migration 0026 creates explicit
`unmanaged` authority with a null serving position rather than guessing append or
checkpoint semantics.

The concurrent regression holds a promotion-shaped group update open in another
transaction. A status statement during the transaction returns the complete committed
`rebuilding-versioned`/v1/epoch-0 tuple; after commit it returns the complete
`serving-versioned`/v2/epoch-1 tuple with no active run or candidate. Existing real-role
migration coverage grants only `USAGE` on `keiro_read` and `SELECT` on the view, proves
the role lacks private-schema access, and exercises the owner-rights result. Migration
snapshot evidence freezes all 18 columns in order and type, plus public revocations and
the security-barrier/owner-rights definition.

The M3 query-plan fixture supplies the performance review: 1,017 status rows return in
2.363 ms, the group/cursor/read-model joins use their keyed relations, and the plan has
no subscription/member cross product across unrelated groups. Lifecycle coverage also
includes live, offline, failed, rebuilding-versioned, serving-versioned, unknown cursor
authority, and reads-disabled states.

There are no critical or high EP-2 findings. The one medium residual is Kiroku v1's
absence of expected consumer-group cardinality: if a required subscription has at
least one published row but its highest member is missing, Keiro cannot distinguish
that partial topology from a smaller complete group. Owner: `mori://shinzui/kiroku`.
Bounded follow-up: publish expected member topology in a Kiroku v2 public relation and
consume it only through a future Keiro v2 status contract. Until then, Keiro continues
to require every bound subscription, floor every published member, fail closed for
missing whole subscriptions or cursor authority, and avoid private Kiroku storage.


## Context and Orientation

MasterPlan 41 makes application-owned PostgreSQL projections safe to rebuild and read
from another process. Its completed plan 256 introduced a projection revision, which
selects schema-specific live/replay SQL, and a target generation, which is one physical
instance of a logical projection table. A schema-versioned rebuild keeps the serving
generation live while a candidate generation replays, then fences writers and swaps all
targets in one transaction. Plan 254 is currently delivering the public status view,
plan 255 will deliver guarded external SQL functions, and plan 257 will deliver
one-stream repair.

The first adversarial review of completed plan 256 found four concrete gaps that this
plan must treat as failing baseline tests.

First, delivery identity is lost when a group becomes version-managed.
`keiro/src/Keiro/Projection.hs` function `applyCatalogProjectionsTx` selects the serving
revision and executes every `RevisionLiveHandler` during command append. The same file's
`applyAsyncProjectionFromCatalog` later executes the same complete handler list after
inserting one async projection's deduplication key. `RevisionLiveHandler` in
`keiro/src/Keiro/Projection/Catalog.hs` has a handler ID, version, target list, and
closure, but no projection owner or inline/subscription delivery identity. The
Jitsurei catalog in `jitsurei/src/Jitsurei/ReadModels.hs` declares the audit projection
as async, yet its revision-wide live closure writes summary, line, and audit targets.
The post-promotion Jitsurei test issues only a command and observes the audit row count
advance. An idempotent upsert hides the later duplicate; a non-idempotent projection is
not protected because command-time execution did not claim the async dedup key.

Second, `promoteVersionedRebuildTx` in
`keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs` acquires the promotion group/run row
lock before setting `statement_timeout`. It then acquires each serving and staging
relation lock in a separate SQL statement. PostgreSQL applies `statement_timeout` per
statement, so several blocked relations can each consume the configured duration. The
earlier `enterVersionedCutoverTx` update that acquires the writer fence has no local
deadline. The current concurrency test blocks only one relation and therefore does not
prove an overall deadline.

Third, `collectAsyncDedupBackfill` in
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` scans events from the slowest durable
subscription floor through the captured head and returns every deduplication pair in a
Haskell list. `resumeVersionedRebuild` calls it only after the group has entered the
writer-fenced cutover lifecycle. Promotion then batches that already-materialized list
while holding exclusive locks on every serving and candidate target. History size and
checkpoint lag can therefore control process memory and write outage length.

Fourth, after relation locks are acquired, promotion invokes application-owned schema
validators and revision verifications, inserts all dedup batches, reconciles
checkpoints, and releases the history lease. Those operations can issue many statements
or perform arbitrary application computation. They make the exclusive-reader lock
duration much larger than the rename and locked identity-revalidation phase promised by
the architecture.

The steady-state versioned writer also performs an additional
`servingTargetBindingsStmt` query per group and event transaction. Migration 0025
provides an index for it, but no comparative write benchmark currently establishes the
cost. `keiro/bench/Main.hs` and the `just bench-regression` recipe provide the existing
benchmark harness and baseline convention.

The relevant durable decisions are
[ADR 0026](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md),
which says delivery belongs to the supplying projection owner;
[ADR 0028](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md),
which keeps application SQL behind supported library/operator boundaries;
[ADR 0031](../adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md),
which makes async deduplication correctness evidence rather than optional idempotence;
[ADR 0034](../adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md),
which promises a bounded lock phase and preparation before relation locks; and
[ADR 0035](../adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md),
which freezes the public status vocabulary. Correcting delivery and cutover semantics
must amend ADR-26, ADR-31, and ADR-34. ADR-35 changes only if the adversarial EP-2
review changes a frozen status meaning.

Kiroku owns the subscription checkpoint and history-retention boundaries consumed by
this work. Locate its source through `mori registry show shinzui/kiroku --full`.
The public checkpoint decision is
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-6`; long rebuild retention is delivered by
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-6`. Keiro must continue to
use released owner APIs and the public `kiroku.subscription_checkpoints_v1` relation,
never a private dependency table.


## Plan of Work

### Milestone 1 — Restore exact delivery-scoped revision dispatch

Extend the projection-revision contract in
`keiro/src/Keiro/Projection/Catalog.hs` so each revision live handler names the exact
catalog delivery capability it implements. The normalized identity must distinguish an
inline handler owned by a `ProjectionId` from a subscription handler owned by a
`ProjectionId`, `SubscriptionId`, and `DedupKeyId`. Handler-required targets must equal
the targets owned by that supplying projection rather than the entire rebuild group.
Validation must prove that every declared live delivery capability in the group has
exactly one matching handler in every revision, that no revision invents an extra
capability, and that the handler cannot claim another projection's targets.

Change `applyCatalogProjectionsTx` to run only revision handlers matched to the inline
capabilities selected by the typed `ProjectionSet`. Change
`applyAsyncProjectionFromCatalog` to select exactly the handler matched to its validated
async registration before claiming and applying that handler's dedup key. It must never
traverse unrelated revision handlers. Preserve sorted group locking and the guarantee
that an absent compiled serving revision or incomplete physical binding fails before
event append, deduplication, or application SQL.

Update candidate language 5, lowering, generated Haskell, scaffolding, inventories,
diffs, and Jitsurei so revision holes are delivery-scoped rather than one opaque
group-wide live closure. Because delivery identity affects resume authority and catalog
meaning, include it in canonical catalog/group-slice preimages and apply ADR-32's
prefix-bump rule using the next prefixes visible at implementation time. Regenerate all
affected corpus fixtures through their recorded invocations.

The core regression fixture is a version-managed group containing one inline counter
and one async audit whose effects increment rather than upsert. After a command, only
the inline counter changes and no async dedup key exists. The first async delivery
changes only the audit and claims its key; redelivery changes nothing. The same
assertions must hold while a candidate revision is rebuilding and after promotion.

### Milestone 2 — Bound cutover work and stage redelivery evidence

Replace the current per-statement approximation with one explicit promotion-attempt
deadline. Capture an absolute database-clock deadline before attempting the writer-fence
or promotion group row lock and set `statement_timeout` to the remaining duration before
every potentially blocking statement. Acquire all serving and candidate relations in
one deterministically ordered `LOCK TABLE` statement, so that statement's timeout is
one cumulative relation-lock budget. Refuse before the next statement when no duration
remains; several blocked relations must not multiply the budget. Convert timeout/lock
failures into a typed lifecycle outcome that leaves serving names, generation metadata,
checkpoints, and deduplication unchanged.
The status and runbook must say clearly that the deadline bounds an individual attempt
and whether a failed attempt remains fenced pending resume or abandonment.

Add run-scoped, database-backed staging for promotion deduplication evidence. Build it
incrementally during ordinary candidate replay through a provisional head, then admit
cutover only when the staged pair count plus the maximum bounded tail fits a persisted
promotion limit. After fencing, collect only the tail between that provisional head and
the final captured head into the same staging relation. Do not retain the complete pair
set in a Haskell list. Promotion installs the bounded evidence with a set-based
operation before target relation locks, while the group/run lock still prevents a
writer or competing promotion from observing a partial lifecycle transition. Any
choice of limit becomes persisted request/resume identity and is exposed in preview and
operator output.

Run data verification against the stable staging generation before acquiring target
relation locks. Under relation locks, retain only checks that must exclude a concurrent
DDL change: relation OID/relkind, schema fingerprint, dependency/privilege evidence,
promotion-object mapping, and any deliberately separate lightweight locked validator.
Application code that can scan an entire target or execute unbounded computation must
not run under the exclusive target locks. Update ADR-34 with the resulting exact lock
order and recovery behavior.

Tests must contend on the writer-fence row, the promotion group row, and at least two
different target relations. Wall-clock evidence must show total lock wait stays within
the configured deadline plus a small scheduler allowance rather than multiplying by
the number of blocked objects. A large-lag fixture must prove cutover refuses before
fencing when its staged evidence exceeds the limit, process residency remains bounded,
and retry succeeds after the operator reduces lag or chooses a reviewed larger limit.

### Milestone 3 — Establish performance budgets

Extend `keiro/bench/Main.hs` with paired legacy and version-managed inline and async
scenarios. Cover one and several groups, one and several targets, a catalog with many
non-serving revisions, and a mixed-delivery group. Measure the complete database
transaction, not a pure lookup. Use `bcompareWithin` and the existing local benchmark
baseline convention, and add an explicit repeated latency sampler for percentile
evidence. For the representative three-target workload, version-managed throughput
must remain at least 90 percent of its legacy peer and p95 wall time must remain within
1.25 times the legacy peer. If the extra generation-binding round trip misses that
budget, combine the locked group availability/revision and serving-target binding read
or otherwise remove the round trip without caching across an unobserved epoch.

Add scale scenarios for status-view reads, guarded keyed reads, all-row wrappers,
promotion, and targeted stream repair as the owning plans land. Use PostgreSQL
`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for query plans and record fixture cardinality
with every result. An all-row external function is accepted only at a documented and
enforced small-model boundary; a selective keyed function must use the target index.
Benchmarks are manual release evidence and may remain outside ordinary CI, but their
commands, machine description, raw result artifact, and accepted comparison must be
recorded in this plan before completion.

### Milestone 4 — Adversarially review EP-2, EP-3, and EP-4

Review each child only after its implementation milestone is complete, using its actual
commits and current database objects rather than accepting the ExecPlan narrative as
evidence. Record the reviewed commit IDs, hypotheses, reproduction commands, findings,
severity, fixes, and regression tests in this plan's living sections.

For plan 254, attack the status view with missing and duplicate checkpoint members,
many groups/subscriptions/members, unknown cursor authority, failed/offline/versioned
lifecycle states, promotion in a concurrent transaction, a role lacking private-schema
privileges, and a rolling migration from pre-0026 data. Verify one row per group, frozen
column order/types/null meanings, truthful checkpoint floors, atomic serving/candidate
facts, owner-rights behavior, and an indexed plan without an accidental whole-corpus
cross product.

For plan 255, review every generated identifier and dynamic SQL boundary, fixed
`search_path`, function owner, `SECURITY DEFINER` behavior, `PUBLIC` revocation, schema
and function grants, overload/signature replacement, rolling surface generations,
dependency retirement, and revision/shape compatibility. Race authorization with
promotion and retirement from separate connections. A keyed read must preserve index
selection. A deliberately slow reader must demonstrate the documented interaction
between its group `FOR SHARE` lock and the bounded promotion attempt. No external role
may bypass the outer guard through a target, private binding, inner implementation, or
unsafe function privilege.

For plan 257, use a long stream, a stream truncated after version zero, soft deletion,
concurrent hard deletion, an existing writer, a new writer, a guarded reader, async
redelivery, clearer failure, verifier failure, and a process interruption. Preview must
report enough history size and expected work to enforce a reviewed maximum before the
exclusive group transaction begins. The repair must update only the selected stream,
leave the shared checkpoint exactly unchanged, create the exact delivery-scoped dedup
evidence, and roll back target plus dedup changes together. Its writer pause must be
bounded by admission policy rather than merely documented as potentially proportional
to an arbitrary stream.

Also perform a cross-plan deadlock and ownership review. Enumerate the lock order across
group rows, Kiroku retention/stream guards, dedup tables, checkpoint rows, managed read
objects, and application target relations. Exercise sanctioned reads during promotion
and targeted repair, old binaries during bridge deployment, object reconciliation
during rolling registration, and status reads at every committed failure state. Any
critical or high finding extends this plan with a fixing milestone and blocks release.

### Milestone 5 — Run the final release-safety gate

Create a focused fault-injection acceptance scenario that uses a mixed inline/async,
multi-target group and a real incompatible v1/v2 schema. Kill or fail execution after
writer fencing, final-head capture, staged dedup preparation, relation locking, object
renaming, managed read-object reconciliation, and metadata transition. Every retry must
either resume the same authority or return a typed refusal; no observation may combine
old and new serving facts.

Reconcile the final public Haskell and SQL APIs, migration snapshots, operator JSON,
user documentation, runbooks, changelogs, generated language-5 surfaces, and runtime
patterns. Distill durable delivery, lock-order, deadline, and admission decisions into
ADR-26, ADR-31, ADR-34, and any later ADR owned by EP-3 or EP-4. Run strict ADR
validation, the complete test suites, corpus replay, benchmark gates, and `just verify`.
Only after all five milestones pass and no critical/high finding remains may plan 259
and MasterPlan 41 be marked Complete.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
cabal test keiro-test --test-option=--match --test-option="revision delivery routing"
cabal test keiro-test --test-option=--match --test-option="schema-versioned cutover concurrency"
cabal test keiro-test --test-option=--match --test-option="projection group status v1"
cabal test keiro-test --test-option=--match --test-option="external read contracts"
cabal test keiro-test --test-option=--match --test-option="targeted stream reprojection"
cabal test keiro-migrations-test
cabal test keiro-dsl:tests
cabal test keiro-ops-test
cabal test jitsurei-test
just bench-regression
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

Add the focused test names above when their milestones are implemented. A successful
cutover deadline test should report several individually contended objects but one
elapsed budget, for example:

```text
configured promotion deadline: 200 ms
contended relations: 2
typed outcome: cutover-deadline-exceeded
elapsed: less than 300 ms
serving revision: v1
serving names changed: false
```

Do not accept a benchmark result from one warm-up or one timing sample. Record at least
five comparable runs on the same machine and include the median ratios and raw result
path in Outcomes & Retrospective.


## Validation and Acceptance

Acceptance requires behavior, not only compilation or a completed review checklist.

A mixed-delivery group proves that a command transaction mutates only inline-owned
targets, the corresponding subscription delivery mutates only its declared async
targets, and redelivery is a no-op even when the application handlers increment values.
The result must hold before, during, and after a schema-versioned rebuild.

Two separate sessions blocking different promotion relations cannot make one attempt
wait twice its configured deadline. Row-lock contention before target locking is also
bounded. Every timeout preserves the complete v1 serving generation and returns a
typed outcome. Successful promotion holds exclusive target locks only for locked
relation identity and promotion-object revalidation, renames, managed-object
reconciliation, and metadata transition. Application schema verification, dedup
installation, checkpoint reconciliation, and retention release occur in the preceding
durable preparation.

A subscription lag larger than the admission limit refuses cutover while ordinary v1
writes remain allowed. A lag within the limit uses database staging and bounded tail
collection; heap growth is not proportional to the complete historical pair set. A
large targeted stream similarly refuses before taking the group-wide repair lock unless
the request is within its reviewed work limit.

EP-2, EP-3, and EP-4 each have a recorded adversarial review tied to exact commits. All
critical and high findings have fixes and regression tests. Medium/low residual risks
name an owner and bounded follow-up and do not contradict a stable public contract.

The relative performance budgets in Milestone 3 pass on the recorded machine. The
status and keyed-read query plans use their intended indexes at the recorded scale, and
the all-row path cannot be mistaken for an efficient selective query.

Finally, `just verify`, strict ADR validation, the conformance corpus replay, migration
schema checks, Jitsurei, and the benchmark commands all pass from the final tree. The
MasterPlan registry identifies EP-5 as Complete only after EP-2, EP-3, and EP-4 are also
Complete.


## Idempotence and Recovery

The review and benchmark commands are read-only apart from isolated test databases and
regenerated benchmark output. Focused concurrency tests create fresh ephemeral
databases, so interruption is recovered by rerunning the test.

Catalog fingerprint and candidate-language changes are a deliberate pre-0.12 clean
break. Regenerate fixtures through repository tooling; never hand-edit generated
outputs or reuse an old prefix. A failed migration or plan implementation is corrected
with a new forward migration once committed; never edit a shipped migration.

Promotion and targeted-repair fault injection must occur inside disposable test
databases. Never reproduce destructive cases against an application database. A failed
promotion remains governed by the persisted lifecycle: use the supported resume or
abandon operation, never manual table renames, checkpoint edits, dedup deletion, or
`CASCADE`.

The plan is safe to resume incrementally. Record each reviewed EP commit and every
finding in the living sections before changing code. If another child changes after its
review, invalidate that review for the affected surface and repeat the relevant cases.


## Interfaces and Dependencies

The plan's hard starting dependency is completed plan 256. Plans 254, 255, and 257 are
rolling integration dependencies: their review can occur only after the corresponding
implementation is complete, and this plan cannot finish before all three do.

`keiro/src/Keiro/Projection/Catalog.hs` owns the corrected delivery-scoped
`RevisionLiveHandler` contract, catalog validation, inventory, and fingerprints.
`keiro/src/Keiro/Projection.hs` owns inline and async selection at their transaction
boundaries. `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` owns replay-time staged dedup
collection. `keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs` owns writer fencing,
promotion deadline enforcement, locked revalidation, generation swaps, and retirement.
`keiro/src/Keiro/ReadModel/Rebuild/Group.hs` owns shared/exclusive group lock ordering
and the serving revision/target binding.

Plan 254 contributes `keiro/src/Keiro/ReadModel/Rebuild/Status.hs`, migration 0026, and
`keiro_read.projection_group_status_v1`. Plan 255 contributes the external-contract
catalog types, private managed-object metadata, and guarded functions in `keiro_read`.
Plan 257 contributes `keiro/src/Keiro/ReadModel/Rebuild/Stream.hs` and its operations
and CLI surfaces. EP-5 may change these delivered artifacts to resolve review findings,
but it must update the owning child plan and ADR when a frozen assumption changes.

`keiro-dsl` owns candidate language 5 parsing, checking, lowering, diffing, scaffolding,
and conformance fixtures for delivery-scoped revision handlers.
`keiro/bench/Main.hs` owns comparative database benchmarks; the `just bench-regression`
recipe owns the local baseline guard. `jitsurei/src/Jitsurei/ReadModels.hs` and
`jitsurei/test/Main.hs` own the executable incompatible-schema and mixed-delivery
transcript.

Kiroku integration uses the released `kiroku-store` retention and stream-guard APIs and
the `kiroku-store-migrations` public checkpoint relation located through
`mori://shinzui/kiroku`. PostgreSQL lock, timeout, dependency, privilege, and query-plan
behavior must be demonstrated against the real test server rather than inferred from a
mock.


## Commit and Trailer Convention

Use Conventional Commits and include:

```text
MasterPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
ExecPlan: docs/plans/259-adversarially-review-and-harden-read-model-release-safety.md
Intention: intention_01kzw6dkhje7qvw6w321pwyv12
```
