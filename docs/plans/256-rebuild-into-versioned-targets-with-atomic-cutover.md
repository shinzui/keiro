---
id: 256
slug: rebuild-into-versioned-targets-with-atomic-cutover
title: "Rebuild schema-versioned targets with atomic cutover"
kind: exec-plan
created_at: 2026-08-12T23:56:17Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
master_plan: "docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md"
---

# Rebuild schema-versioned targets with atomic cutover

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current. If implementation changes a
durable architectural boundary, update `docs/adr/` in the same change.


## Purpose / Big Picture

After this change an application can change a projection's PostgreSQL schema without
emptying or partially refilling the table currently serving readers. The application
declares a new projection revision, supplies transaction-local DDL that provisions its
new schema under a Keiro-allocated staging name, and supplies live/replay SQL for that
revision. Keiro reconstructs the candidate generations from event history while the
old revision continues to serve and receive writes. It then takes a short group fence,
catches up the tail, verifies data and DDL, and promotes every target in the group in
one PostgreSQL transaction.

Schema evolution is the general case. Rebuilding corrupted data or changed projection
logic into an identical schema uses a restricted built-in clone provisioner, but clone
semantics do not define the architecture.

The observable acceptance scenario changes a one-table projection from schema v1 to a
genuinely incompatible schema v2. A second database connection continuously reads the
v1 serving table during the replay and never sees an empty or partial candidate. Live
events continue to update v1. At cutover, writers pause briefly; all target aliases,
object names, serving-revision metadata, deduplication evidence, and checkpoints move
atomically. After commit, v2 readers and writers succeed, v1 application code fails
closed, and the retired v1 generation remains available for explicit inspection or
later destruction.

This plan is EP-1 of
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`.
Plans 254 and 255 consume its persisted generation and availability vocabulary. The
durable ownership decision is
`docs/adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md`.


## Progress

- [x] (2026-08-13T22:35:58Z) External prerequisite: verified IR-6's renewable
  retention-lease API in released `kiroku-store` 0.7.0.0 and migration `0010` in
  released `kiroku-store-migrations` 0.3.2.0; the upstream annotated tags and Hackage
  releases agree.
- [x] (2026-08-13T22:51:59Z) M1: PostgreSQL prototype proves schema-changing provision, dependency and object
  identity behavior, deterministic all-target locks, rollback, and concurrent-reader
  semantics; the restricted clone eligibility matrix is recorded from evidence.
- [x] (2026-08-13T23:32:54Z) M2: projection revisions, target generation contracts,
  provisioners, validation, canonical fingerprints, and language-5/code-generation
  surfaces are implemented and validated across Keiro, the DSL, Jitsurei, and ops.
- [x] (2026-08-14T00:09:28Z) M3: migration persists serving revisions, epochs, target
  generations, relation identities, observed schema fingerprints, canonical
  object-name maps, run policy, and retention evidence; transactional begin/abandon,
  retry, rollback, and legacy lifecycle compatibility are database-tested.
- [x] (2026-08-14T00:41:07Z) M4: live inline and async writers dispatch through the
  persisted serving revision; replay and verification are physical-target-parametric;
  unknown revisions, incomplete generation bindings, and old runtime lifecycle states
  fail closed before event or target mutation.
- [x] (2026-08-14T01:22:41Z) M5: converging replay, retention protection, bounded
  cutover, dedup/checkpoint reconciliation, DDL revalidation, atomic promotion, and
  crash-resume pass concurrent schema-v1/schema-v2 acceptance tests.
- [x] (2026-08-14T02:22:44Z) M6: restricted same-schema cloning, dependency-aware
  retirement/drop, versioned operator commands, the incompatible Jitsurei v1/v2
  acceptance path, ADR and runtime-pattern reconciliation, runbooks, changelogs, and
  the complete `just verify` gate are implemented and passing.


## Surprises & Discoveries

- The first draft used `CREATE TABLE ... LIKE ... INCLUDING ALL`, which can only
  reproduce selected aspects of the old shape. It cannot create a changed schema and
  does not preserve every grant, dependency, trigger, policy, replica-identity choice,
  publication membership, or canonical migration object name.
- A copied serial default can continue to call the old sequence; only identity copying
  has the fresh-sequence behavior the first draft assumed. A clone must therefore
  refuse external `nextval` defaults rather than attempt a generic `setval` repair.
- Query-model `version` and `shape_hash` identify a reader contract, not a target
  generation or the SQL revision that writes it. Those identities must remain separate.
- Application DDL can race a rebuild because schema migrations do not acquire Keiro's
  group-row lock. Persisted relation identity and schema evidence must be rechecked
  after acquiring every table lock immediately before promotion.
- Retained event history is not inherently immutable: Kiroku supports hard deletion.
  Replay and cutover need an owner-provided retention/serialization primitive, not a
  comment asserting that events below the head cannot disappear.
- Retaining the retired table provides forensics and a drain window, not automatic
  rollback. Once new events have been written under the promoted revision, switching
  back requires a compatible forward operation or another rebuild.
- Kiroku IR-6 did not expose one generic “retention token.” Long fan-in rebuilds use a
  durable, renewable lease; one-stream repairs use a transaction-scoped stream guard.
  This plan needs only the lease. The lease's `protectedThrough` field is the inclusive
  frontier captured at acquisition; the active lease conservatively blocks all
  destructive Kiroku data-table work, including deletion of events appended after that
  initial frontier.
- PostgreSQL proved that a dependent view follows the serving relation's OID across a
  rename, so after a table swap that view still reads the retired generation. Identity
  columns expose an internally owned sequence that can be renamed explicitly; a serial
  default remains an external `nextval` expression and is rejected by the clone path.
- The restricted clone refusal probe detected dependent views, external `nextval`
  defaults, foreign keys in both directions, inheritance, non-default owner or ACL,
  non-default replica identity, partitioning, publication membership, row-level
  security and policies, rules, and user triggers. A publication catalog membership is
  present even when PostgreSQL warns that `wal_level` cannot publish logical changes,
  so eligibility must inspect membership rather than infer it from server settings.
- One transaction-level `statement_timeout` covering the sorted all-target lock phase
  aborted a cutover blocked by an independent `ACCESS SHARE` reader. PostgreSQL rolled
  back the complete rename set and left all serving and staging rows unchanged.
- Catalog identity needed another coordinated clean break: revision contracts change
  both the complete catalog and group-local resume authority, so the canonical prefixes
  are now `catalog-v4` and `slice-v3`. Executable closures and relation OIDs remain out
  of the preimages; their stable declared identities and ordered promotion-name maps are
  included instead.
- A total `PhysicalTargets` value cannot be represented safely by accepting a partial
  map and failing later inside application SQL. Construction now requires the exact
  expected target set and returns typed missing/unexpected-target evidence before any
  revision handler runs.
- Adding orthogonal availability columns also changes every legacy lifecycle transition:
  merely updating `status` violates the new consistency constraint. Both catalog-group
  and unmanaged single-read-model transitions now write status and availability as one
  atomic fact, preserving the old offline fence while versioned rebuilds remain live.
- The persisted `writes_allowed` bit is deliberately orthogonal to the lifecycle value.
  A revision-aware writer therefore cannot decide from a closed status list alone: its
  group-row lock must bind the persisted serving revision and the complete serving
  generation map while observing the write flag in the same transaction.
- The safe crash boundary is not merely “before or after cutover.” Persisting the writer
  fence separately from final-head capture leaves three distinguishable resumable facts:
  ordinary replay, fenced but awaiting a final head, and replaying toward that captured
  final head. A process can die between any two without reopening v1 writes or guessing
  whether the head was durable.
- A Kiroku lease renewal failure must be committed as lifecycle evidence rather than
  condemned with the replay transaction. The failed run keeps v1 readable, fences all
  writers, and requires abandonment; rolling the failure transition back would invite a
  later resume to treat an expired retention proof as active.
- The conformance-corpus driver reconstructs invocations from tracked scaffold ledgers.
  Regenerating the projection-catalog fixture from the package directory had persisted
  a package-relative source path, which the repository-root replay could not resolve.
  Restoring the repository-relative path and refreshing generated source provenance made
  all 39 corpus invocations byte-stable again.

  Evidence:

  ```text
  versioned target PostgreSQL mechanics
    provisions an incompatible candidate transactionally and rolls failed provisioning back [✔]
    keeps OID identity explicit and demonstrates that dependent views follow the retired relation [✔]
    detects every deliberately unsupported clone feature without mutating the serving table [✔]
    uses deterministic all-target order and one deadline that rolls a blocked cutover back [✔]
    detects when a paused generation name is rebound to a different relation [✔]

  5 examples, 0 failures
  ```


## Decision Log

- Decision: Application-supplied provisioners are the schema-changing path; a built-in
  clone is a restricted same-schema convenience.
  Rationale: the application owns desired DDL, while Keiro owns lifecycle correctness.
  Date: 2026-08-13
- Decision: A `ProjectionRevisionId` binds target schema contracts, provisioner and
  validator identities, live/replay handlers, and verification hooks.
  Rationale: physical promotion without executable-code promotion allows old SQL to run
  against a new schema.
  Date: 2026-08-13
- Decision: The catalog must contain both the serving and candidate revisions while a
  rebuild is active. Live writers select the persisted serving revision under the group
  lock; replay selects the candidate revision.
  Rationale: old data must remain current during a long candidate replay, and the two
  revisions can be structurally incompatible.
  Date: 2026-08-13
- Decision: Version-managed live groups use a database lifecycle value that older
  Keiro runtimes do not recognize as ordinary `live`.
  Rationale: current runtimes already fail closed on an unknown/non-live group state.
  The transition to version-managed operation therefore prevents a pre-feature binary
  from writing old SQL after a schema cutover. Revision-aware runtimes additionally
  refuse when their catalog lacks the persisted serving revision.
  Date: 2026-08-13
- Decision: Names remain compatibility aliases, while generation IDs, relation OIDs,
  and canonical schema fingerprints are persisted lifecycle identity.
  Rationale: SQL closures embed table names, but a name can be reused or rebound while a
  run is paused. Resume and cutover must prove which object the name denotes.
  Date: 2026-08-13
- Decision: Promotion locks all serving and staging relations in deterministic order
  under one overall deadline, then revalidates OIDs, DDL fingerprints, dependencies,
  and canonical object-name mappings before any rename.
  Rationale: per-statement timeouts accumulate across targets and permit a DDL race
  between validation and later locks.
  Date: 2026-08-13
- Decision: Serving availability and rebuild lifecycle are separate persisted facts.
  Rationale: the serving revision remains readable and writable during candidate
  replay. Plans 254 and 255 must not infer availability from a closed status list.
  Date: 2026-08-13
- Decision: Source retention through the final head is an enforced prerequisite of an
  active run.
  Rationale: a disappearing event can invalidate replay completeness and deduplication
  backfill after those facts were computed.
  Date: 2026-08-13
- Decision: Retired generations are dropped only through a dependency-aware,
  two-phase destructive operation.
  Rationale: supported read contracts and application objects may still reference them,
  and destruction is irreversible.
  Date: 2026-08-13
- Decision: Adopt Kiroku's IR-6 release through `kiroku-store >=0.7 && <0.8` and
  `kiroku-store-migrations ^>=0.3.2.0`, using the public lease transaction combinators.
  Rationale: those are the first released packages containing the owner-published
  retention API and migration `0010`; the current Keiro `kiroku-store <0.7` bound cannot
  compile the integration, and retaining the looser migrations minimum would not
  guarantee the required database objects.
  Date: 2026-08-13
- Decision: Persist the lease ID, owner, acquisition `protectedThrough`, and expiry;
  renew the same lease during catch-up and release it on promotion or abandonment.
  Rationale: renewal extends database-derived expiry but deliberately does not replace
  the acquisition frontier. Kiroku's conservative active-lease policy already protects
  later appends from destructive removal, so Keiro must verify active ownership rather
  than invent a moving private retention cursor.
  Date: 2026-08-13
- Decision: Introduce projection revisions as first-class catalog entries while keeping
  query-model revision references separate and minimal until plan 255 owns the complete
  external read-contract surface.
  Rationale: live/replay executable schema authority is needed now, while freezing the
  public consumer-contract model belongs to the dependent plan.
  Date: 2026-08-13
- Decision: Encode provisioner, validator, live, replay, and verification implementations
  through explicit stable identifiers and positive versions; exclude Haskell closures,
  allocated generation UUIDs, physical names, and relation OIDs from catalog preimages.
  Rationale: declarations must invalidate resume identity deterministically without
  making deployment-specific runtime values part of catalog identity.
  Date: 2026-08-13
- Decision: Make the projection write lock return a closed-world serving binding rather
  than only a permission bit, and reject absent compiled revisions or incomplete
  generation maps as typed outcomes before invoking application handlers.
  Rationale: permission and routing are one atomic fact at the live-write boundary;
  looking up either after releasing the group lock would admit a cutover race.
  Date: 2026-08-13
- Decision: Keep schema-versioned start/resume/status/abandon as a dedicated typed
  protocol instead of widening the legacy offline `RebuildOptions` and reports into a
  partial tagged union.
  Rationale: versioned runs require revision, generation, epoch, lease, replay-source,
  and cutover-phase facts that do not exist for unmanaged offline rebuilds. The M6
  operations facade can expose both workflows without making either library contract
  lie about unavailable fields.
  Date: 2026-08-13
- Decision: Persist writer fencing and final-head capture as separate cutover phases,
  and renew the original Kiroku lease before every replay or cutover mutation.
  Rationale: crash recovery must distinguish a fenced run that still needs a head from
  one replaying to a durable head, while an expired lease must fail closed before any
  candidate or promotion mutation.
  Date: 2026-08-13
- Decision: Keep restricted cloning inside a closed PostgreSQL catalog envelope and
  resolve every allowed promotion object structurally before renaming it.
  Rationale: textual name copying cannot prove ownership or dependency safety; any
  unrepresented table feature must refuse the clone transaction without a candidate.
  Date: 2026-08-13
- Decision: Make retired-generation discovery database-only, but require the compiled
  catalog plus a two-phase preview/force protocol for destruction.
  Rationale: operators must be able to inventory old generations after code retirement,
  while a drop must recheck read-contract references, PostgreSQL dependencies, relation
  OID, and retired lifecycle under lock and must never use `CASCADE`.
  Date: 2026-08-13


## Outcomes & Retrospective

Architecture validation replaced the original clone-only design before implementation.
The external replay-retention prerequisite is now released and verified. Milestone 1
completed the PostgreSQL proof suite and froze the restricted clone refusal envelope
from observed catalog behavior. Milestone 2 added the runtime and language-5 revision
contract, total physical-target maps, deterministic diagnostics, `catalog-v4` and
`slice-v3` identity, generated application holes, and a compile-checked Jitsurei v1/v2
bridge. The complete Keiro (559 examples), DSL (705 examples plus all conformance
components), Jitsurei (23 examples), and keiro-ops (43 examples) suites passed at that
boundary. Milestone 3 added native migration 0025, normalized
revision/generation/run-target and promotion-object identity, Kiroku retention evidence,
deterministic generation naming, transactional provisioning and validation, same-run
resume, and idempotent abandonment. The 29-example migration suite, five-example
versioned lifecycle suite, and 33-example legacy read-model suite pass. Milestone 4
made inline, async, replay, and verification execution revision-aware and proved
bridge deployment behavior across a persisted v1-to-v2 promotion. The complete Keiro
suite passes with 566 examples; the six-example schema-versioned lifecycle and
three-example catalog-fenced inline suites pass independently. All DSL tests and
conformance components pass, including the 705-example main DSL suite, and Jitsurei
passes 23 examples. Milestone 5 added a durable versioned replay contract and per-source
progress, renewal of the original Kiroku lease, multi-round convergence, separately
resumable fence/head phases, final deduplication and checkpoint reconciliation, and one
bounded all-target promotion transaction. The schema-v1/schema-v2 suite proves live v1
traffic during two replay rounds, hard-delete refusal, expired-lease fencing, DDL-race
rollback and repair, async redelivery safety, v1-only writer refusal, atomic two-target
promotion, a blocked-reader timeout followed by successful resume, and retained v1
generations. The complete Keiro suite passes 572 examples; the 12 versioned lifecycle
and concurrency examples pass independently. Milestone 6 completed the closed-world
restricted clone, structural promotion-object remapping, dependency-aware retired
generation inventory and two-phase destruction, application-mounted versioned rebuild
commands, and an executable Jitsurei v1/v2 bridge that changes `status` to `state`,
continues v1 writes during replay, promotes three targets atomically, and retains all
three v1 generations. The operator runbook, ADRs, changelogs, and the external runtime
patterns at `mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections`
and `mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs` now describe
the delivered protocol. Final evidence is 16 focused schema-versioned rebuild examples,
576 Keiro examples, 44 keiro-ops examples, 705 main DSL examples plus every conformance
component, 24 Jitsurei examples, 29 migration examples, 34 strict ADR concepts, a
no-drift 39-entry conformance corpus, and a passing `just verify`. EP-1 is complete.


## Context and Orientation

Keiro is a Haskell event-sourcing runtime backed by the Kiroku PostgreSQL event store.
The read side is described by `keiro/src/Keiro/Projection/Catalog.hs`. ADR-26 currently
separates query-model bindings, physical targets, rebuild groups, and projection
handlers. This plan extends, rather than collapses, those identities:

- a **projection revision** is an executable and schema contract for one rebuild group;
- a **target generation** is one physical PostgreSQL realization of a logical target
  under one projection revision;
- a **serving revision** is the revision selected by live writers for the group;
- a **candidate revision** is being replayed into staging generations;
- a **serving epoch** is an increasing number changed only by promotion and suitable for
  cache invalidation.

The current offline lifecycle is implemented in
`keiro/src/Keiro/ReadModel/Rebuild/Group.hs` and
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`. Preparation takes `FOR UPDATE` on the
group row, changes it from `live` to `rebuilding`, truncates clearable targets, resets
replayable async deduplication and subscription checkpoints, and fences writers. Replay
persists source cursors and applies chunks transactionally. Promotion requires source,
adapter, and verification completeness.

Completed MasterPlan 39 work is a hard prerequisite. Plan 246 corrected ordered source
paging; plan 247 made adapter order part of resume identity; plan 258 made deduplication
backfill and checkpoint advance atomic with promotion. This plan reuses those primitives.
ADR-31 makes deduplication a correctness mechanism rather than relying on idempotent
application handlers.

Application SQL is opaque. Current `ReadModel`, inline handler, async handler, replay
adapter, and generated DSL holes embed qualified table names. Schema-changing online
rebuild therefore requires both revision selection and explicit physical-target
parameters. Keiro never rewrites SQL text.

Relevant local decisions are ADR-9, ADR-26, ADR-28, ADR-31, ADR-32, and ADR-34. Kiroku
source and API documentation must be located through `mori://shinzui/kiroku`; do not
query its private schema to invent a missing retention or checkpoint primitive.

The concrete upstream retention contract is implemented by
`mori://shinzui/kiroku/plans/73-protect-replay-history-with-retention-leases-and-stream-guards`
and governed by `mori://shinzui/kiroku/okf/adrs/concepts/ADR-7`. Released
`kiroku-store` 0.7.0.0 exports `Kiroku.Store.HistoryRetention`, including
`acquireHistoryRetentionLeaseTx`, `renewHistoryRetentionLeaseTx`, and
`releaseHistoryRetentionLeaseTx`. Released `kiroku-store-migrations` 0.3.2.0 installs
the durable lease tables, schema-local coordinator, active-lease index, and SQLSTATE
`KR001` destructive-statement guards through migration `0010`.


### Generation and provisioning contract

The exact Haskell names may be refined during implementation, but the semantic boundary
must remain equivalent to this shape:

```haskell
newtype ProjectionRevisionId = ProjectionRevisionId Text
newtype TargetGenerationId = TargetGenerationId UUID
newtype TargetSchemaVersion = TargetSchemaVersion Text

data PhysicalTargets = PhysicalTargets (Map TargetId QualifiedTable)

data TargetProvisioningContext = TargetProvisioningContext
  { targetId :: TargetId
  , generationId :: TargetGenerationId
  , servingTable :: QualifiedTable
  , stagingTable :: QualifiedTable
  }

data TargetProvisioner = TargetProvisioner
  { provisionerId :: Text
  , provisionerVersion :: Int
  , schemaVersion :: TargetSchemaVersion
  , expectedShapeId :: Text
  , provisionTarget :: TargetProvisioningContext -> Tx.Transaction ()
  , validateTarget :: TargetProvisioningContext
      -> Tx.Transaction (Either [TargetSchemaViolation] TargetSchemaEvidence)
  , promotionObjectNames :: [PromotionObjectName]
  }

data ProjectionRevision = ProjectionRevision
  { revisionId :: ProjectionRevisionId
  , targetProvisioners :: Map TargetId TargetProvisioner
  , liveHandlers :: NonEmpty RevisionLiveHandler
  , replayAdapters :: NonEmpty RevisionReplayAdapter
  , verifications :: [RevisionVerification]
  }
```

Every handler and verification receives `PhysicalTargets`. The serving path supplies
the serving generation map; the rebuild path supplies staging. Provision and validation
run inside Keiro transactions and may not commit, connect elsewhere, or mutate serving
objects. `TargetSchemaEvidence` includes the canonical PostgreSQL catalog snapshot Keiro
will persist and compare again at cutover. `promotionObjectNames` maps generation-local
indexes, constraints, and owned sequences to the canonical names application migrations
will address after promotion.

The built-in clone provisioner is accepted only for permanent ordinary heap tables with
the default access method and supported storage settings. It refuses partitioning,
inheritance, foreign keys in either direction, triggers, rewrite rules, RLS and policies,
publication membership, external dependent views/functions, non-default owner or ACL,
unsupported replica identity, external or serial `nextval` defaults, and any catalog
property not represented in its fingerprint. Identity columns are allowed only when the
prototype proves owned-sequence promotion and canonical renaming. Refusal findings are
typed and name the target and unsupported object.


### Version-managed rollout

A bridge deployment includes both revisions. Initial adoption records v1 as the serving
revision and changes the group's internal state from legacy `live` to a version-managed
serving state. Existing writers that know only the legacy state fail closed. A
revision-aware v1/v2 binary takes the group lock, reads `serving_revision_id`, and runs
only that revision's handlers.

Candidate replay uses v2 while live traffic continues through v1. Promotion updates
`serving_revision_id` to v2 in the same transaction as the physical swap. A v1-only
revision-aware binary then returns a typed `ProjectionServingRevisionUnavailable`
outcome without executing SQL. Operators remove v1 code only after no active rebuild or
supported read contract requires it.

This plan does not promise that an arbitrary pre-feature binary can coexist with a
version-management migration. Applying the migration and adopting a group require the
ordinary controlled runtime upgrade. The version-managed state supplies the fail-closed
boundary from that point forward.


### Rebuild protocol

Begin allocates one staging generation per target, persists the candidate revision and
all policy values (`cutoverThreshold`, lock deadline, retention request identity),
provisions the new schema, validates it, captures relation OIDs and fingerprints,
acquires a Kiroku history-retention lease in the same transaction, and changes lifecycle
to `rebuilding-versioned`. Persist the returned lease ID, owner, acquisition
`protectedThrough`, and database-derived expiry. It does not change the serving revision,
truncate serving data, reset checkpoints, or remove live dedup rows.

Replay applies candidate adapters to staging, renews the same lease with a safe margin,
and repeatedly extends its captured head while the lease remains active. Renewal extends
expiry but does not change `protectedThrough`; Kiroku's conservative lease guard prevents
all hard deletion while active, including for events appended after acquisition. When
the remaining distance is below the persisted threshold, Keiro enters `cutover`.
The group write flag becomes false; readers continue to target the serving generation,
although a plan-255 guard holding a shared group lock may wait for the short cutover
transaction.

Tail replay captures a final reachable head and completes through it. Before acquiring
table locks, Keiro runs application verification against staging and prepares async
deduplication/checkpoint evidence under the active retention guarantee. Promotion then
uses one transaction and one overall deadline:

1. Lock the group and run and prove the expected serving and candidate revisions.
2. Acquire `ACCESS EXCLUSIVE` locks for all serving and staging relations in sorted
   target/generation order.
3. Re-resolve every qualified name and compare OID, relkind, schema fingerprint,
   dependencies, privileges, and promotion-name map with persisted evidence.
4. Re-run any validation that can change under the acquired locks.
5. Install deduplication rows and advance only the catalog-owned subscription
   checkpoints covered by the completed candidate.
6. Rename serving objects to retired generation-local names, rename staging objects to
   canonical serving names, and rename canonical indexes, constraints, and owned
   sequences according to the provisioner contract.
7. Mark the old generations retired, the candidate generations serving, set the
   serving revision to the candidate, increment the serving epoch, and mark the run
   promoted.
8. Reconcile any managed external read objects supplied by plan 255, then commit.

Any failure rolls the transaction back. A timeout leaves the durable lifecycle in
`cutover`, with writers fenced and the old serving revision still bound. Resume repeats
validation and promotion. Before cutover, abandon drops only staging generations,
releases retention, and restores ordinary serving lifecycle. After promotion, dropping
retired generations is separate and never automatic.


## Plan of Work

### Milestone 1 — Prove PostgreSQL mechanics and freeze the supported DDL envelope

Create `keiro/test/VersionedTargetPostgresSpec.hs` using the suite-level migrated
PostgreSQL fixture. Use an application provisioner to create schema v2 with a real shape
change: for example v1 stores one `total bigint`, while v2 stores
`subtotal bigint`, `tax bigint`, and a generated or checked total. Prove transactional
provisioning and rollback, rename-swap behavior, relation OID tracking, view dependency
behavior, canonical index/constraint/owned-sequence renames, ACL/owner inspection, and
deterministic multi-table lock acquisition.

Include negative fixtures for serial defaults, foreign keys, triggers, RLS, rules,
partitions, publications, non-default grants, dependent views, and a name rebound to a
new relation while a run is paused. Hold an `ACCESS SHARE` lock from a second connection
to prove the overall cutover deadline aborts the whole transaction. The tests must show
that the serving table remains unchanged after every failed prototype.

Record the observed eligibility matrix in Surprises & Discoveries before implementing
the generic clone helper. Do not broaden support based on memory of PostgreSQL behavior.

### Milestone 2 — Add revision and schema-generation catalog authority

Extend `keiro/src/Keiro/Projection/Catalog.hs` with the semantic types above. Validation
must accumulate stable diagnostics for duplicate revisions, missing serving/candidate
handlers, target-set drift across a group, unknown target provisioners, missing schema
validation, non-total physical target mappings, and read-contract references to absent
revisions.

Extend canonical catalog and group-slice preimages with revision IDs, schema version,
provisioner identity/version, expected-shape identity, ordered promotion object maps,
and handler/verification identities. Apply ADR-32's prefix-bump rules in one clean
pre-0.12 break and add collision/order tests in `keiro/test/PreimageSpec.hs`.

Add candidate language-5 declarations and generated holes in `keiro-dsl`. The language
must express revision, target schema version, provisioner identity, expected-shape
identity, and promotion object names without embedding raw DDL in the `.keiro` file.
Scaffolding emits application-owned provision/validate/live/replay holes whose table
parameters come from `PhysicalTargets`. Update parser, pretty-printer, validation,
lowering, diff, golden corpus, and Jitsurei bridge fixtures. Diff diagnostics distinguish
query-contract, projection-revision, and target-schema changes.

Acceptance: `cabal test keiro-test`, `cabal test keiro-dsl:tests`, and
`cabal test jitsurei-test` pass; a bridge catalog containing v1 and v2 validates and has
stable reviewed fingerprints.

### Milestone 3 — Persist revision and generation lifecycle

Add the next free native migration under `keiro-migrations/migrations/` and update its
manifest, native lock, schema snapshot, fixture counts, and migration tests. Persist:

- serving revision, serving epoch, lifecycle phase, `reads_allowed`, and
  `writes_allowed` on each rebuild group;
- one row per projection revision registered for a group;
- one row per physical target generation with target/revision identity, qualified name,
  relation OID, schema version, expected and observed fingerprints, lifecycle, and
  provenance timestamps/run IDs;
- one run-target row linking the candidate generation and canonical promotion-name map;
- persisted target mode, candidate revision, threshold, overall cutover deadline, and
  Kiroku lease ID, owner, acquisition frontier, expiry, renewal, and release evidence on
  the run.

Use normalized tables for lifecycle identity; JSON may hold diagnostic catalog snapshots
but must not be the only source of state transitions. CHECK constraints encode valid
staging → serving → retired → dropped transitions and exact group/run relationships.

Implement idempotent begin and abandon operations in a new
`keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs`, exposed through the existing facade.
Provision all targets in one transaction after allocating collision-safe names. Persist
their OIDs and evidence only after validation succeeds. A retry with the same run ID
must either resume the same persisted objects or return a typed identity conflict; it
must never create an untracked sibling.

Acceptance: migration and runtime database suites pass, including provisioner failure,
schema validation failure, name collision, abandon, and retry after process interruption.

### Milestone 4 — Make live and replay execution revision-aware

Change `lockProjectionGroupsTx` to return the serving revision and physical target map
for every locked group. `runCommandWithCatalogProjections` and
`applyAsyncProjectionFromCatalog` select the matching compiled revision while retaining
their current transactional group locks. An absent revision returns a typed,
retryable/fatal-by-configuration outcome before append, dedup insert, checkpoint, or
application SQL.

Make live handlers, replay adapters, and verification hooks accept `PhysicalTargets`.
The offline path passes declared serving targets; candidate replay passes staging. The
DSL generator emits resolver helpers and updates every created-once Jitsurei hole. No
handler may reach staging through a global mutable pointer.

Tests must run live v1 traffic while v2 replay is active, prove only v1 changes, promote
the metadata in a fixture transaction, then prove only v2 handlers run. A catalog that
lacks the persisted revision must perform no event append or projection write. An old
runtime interpretation of the version-managed group state must be fenced.

### Milestone 5 — Implement convergence and atomic schema cutover

Extend `RebuildOptions`, run reports, start/resume/abandon, and operations envelopes with
versioned mode, candidate revision, persisted threshold/deadline, generation rows, and
serving epoch. Resume compares the full revised replay contract and re-resolves every
persisted relation before applying another chunk.

Use the released source-retention contract specified by
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-6`. Acquire through
`acquireHistoryRetentionLeaseTx` during begin, renew through
`renewHistoryRetentionLeaseTx` before the database-derived expiry loses its safety
margin, and release through `releaseHistoryRetentionLeaseTx` on promotion or
abandonment. A renewal error fences further replay and returns a typed failure. Resume
may continue only when the persisted lease is still active and can be
renewed. Once it has expired, destructive work may have changed the retained set; a new
lease cannot make the old candidate trustworthy, so the run must be abandoned and
restarted from newly captured history. Do not use `lockStreamHistoryForReplayTx` here;
that transaction-scoped one-stream guard belongs to plan 257. Never implement retention
by querying or locking a private Kiroku table from Keiro.

Implement the rebuild protocol described above. Deduplication and checkpoint work must
reuse the primitives delivered by completed plan 258. Compute or persist its input under
the retention token. Set a transaction-level statement timeout or deadline for the
complete lock-and-swap phase; a separate five-second timeout per rename is insufficient.

Add a database-backed schema-v1/schema-v2 acceptance suite with:

- concurrent live events during at least two replay rounds;
- a second connection continuously reading v1 and never observing staging;
- a cutover lock timeout followed by successful resume;
- an application DDL race detected by OID/fingerprint revalidation;
- async redelivery after promotion producing no duplicate v2 effect;
- a v1-only revision-aware writer refusing after promotion;
- all targets in a multi-target group switching atomically;
- source hard deletion refused while retention is held;
- final status showing v2 serving, a larger epoch, and v1 retired.

### Milestone 6 — Retire safely and deliver operator/documentation surfaces

Extend `ProjectionCatalogOperations` and `keiro-ops rebuild` with versioned
start/resume/status/abandon and `drop-retired`. Mutations require the embedded validated
catalog when application provisioners or revision handlers are needed. Listing retired
generations is database-only. Dropping uses ADR-28's preview/`--force` pattern and
refuses any generation referenced by an active run, supported read contract, or
PostgreSQL dependency not explicitly owned by its provisioner.

Document bridge deployment, schema provisioning, compatible versus breaking consumer
contracts, cutover waits, retention, failure recovery, and the fact that retired data is
not automatically current or rollback-ready. Update
`mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections` and
`mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs` through their
own repository workflow; record the resulting canonical artifact references here. The
projection-catalogs file exists at `runtime-patterns/keiro/projection-catalogs.md`, but
its intended document handle currently awaits a registry refresh.

Reconcile ADR-26, ADR-28, ADR-31, and ADR-32 with ADR-34, update all affected
changelogs, capture a Jitsurei schema-changing transcript, run ADR validation, and run
`just verify`.


## Concrete Steps

All local commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
cabal test keiro-test --test-option=--match --test-option="versioned target PostgreSQL"
cabal test keiro-test --test-option=--match --test-option="projection revisions"
cabal test keiro-migrations-test
cabal test keiro-test --test-option=--match --test-option="schema-versioned rebuild"
cabal test keiro-dsl:tests
cabal test jitsurei-test
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

When adding the migration, use the next free number visible at implementation time,
append it to `keiro-migrations/migrations/manifest`, calculate its SHA-256 entry in
`migrations.native.lock`, and regenerate the native expected-schema snapshot with the
existing test-supported environment flag. Review the snapshot diff before accepting it.


## Validation and Acceptance

Acceptance requires a real schema change, not two identically shaped tables. The test
and Jitsurei transcript must show all of the following:

1. v1 remains readable and receives live events while v2 is provisioned and replayed.
2. No reader ever observes v2 before it is verified, and no query sees a partially
   replayed target through the declared serving name.
3. The final write fence and reader wait are bounded and observable.
4. A lock timeout or detected DDL race changes no serving name, revision, generation,
   dedup row, or checkpoint.
5. Promotion changes the whole group's tables, canonical object identities, serving
   revision, and epoch atomically.
6. Post-promotion live writes use v2 SQL; v1-only code fails before executing SQL.
7. Async redelivery across cutover is a deduplicated no-op and checkpoints do not skip
   events.
8. Retired v1 cannot be dropped while a declared contract or dependency needs it.
9. Hard deletion cannot invalidate an active replay's captured history.

Compile success without these concurrent database proofs is not acceptance.


## Idempotence and Recovery

Provisioners must be idempotent for the supplied generation ID and transaction-local.
A failed begin transaction leaves neither metadata nor staging objects. Resume loads
persisted names and OIDs and refuses replacement objects; it never re-derives names from
mutable catalog order. Catch-up chunks retain the existing atomic cursor/application
semantics.

Before cutover, abandonment drops candidate objects only after dependency inspection,
releases the persisted Kiroku lease with its exact owner handle, records failure, and
leaves the serving revision untouched. During
cutover, any promotion failure rolls back completely and leaves writers fenced for
resume or explicit abandonment. After promotion, ordinary writes may have advanced v2;
returning to v1 is not a rename-only rollback. Operators retain v1 for evidence and use
a forward repair or a new rebuild unless an application-specific rollback protocol
proves equivalence.

Never edit a shipped migration. Correct it with a new forward migration. Never drop a
retired generation with ad hoc SQL in documented recovery; use the dependency-aware
operation.


## Interfaces and Dependencies

Primary runtime modules are:

- `keiro/src/Keiro/Projection/Catalog.hs` for revision, provisioner, schema contract,
  physical target, validation, and fingerprint types;
- `keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs` for generation DDL inspection,
  provisioning, lifecycle, promotion, and retirement;
- `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` for group locking, availability, and
  serving-revision selection;
- `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` for convergence, source retention,
  replay, resume, and cutover;
- `keiro/src/Keiro/Projection/Catalog/Operations.hs` and
  `keiro-ops/src/Keiro/Ops/Rebuild.hs` for supported operator surfaces;
- `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` plus the parser/checker/diff modules for the
  candidate language-5 revision declarations and generated application holes;
- `keiro-migrations/migrations/`, its manifest/native lock, and expected-schema fixture
  for private lifecycle storage.

Kiroku dependencies must use exported owner APIs. Locate current sources and docs with
`mori registry show shinzui/kiroku --full` and `mori registry docs shinzui/kiroku`.
Required behavior includes bounded ordered history reads, transactional checkpoint
reset, checkpoint inventory, and the replay-history protection requested by
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-6`. The contracts Keiro
needs are released in `kiroku-store` 0.7.0.0 and
`kiroku-store-migrations` 0.3.2.0. Update every direct Keiro
bound to `kiroku-store >=0.7 && <0.8` and every direct migration bound to
`kiroku-store-migrations ^>=0.3.2.0`; update migration-count and schema-comment fixtures
from Kiroku migration `0008` to `0010`. The public lease functions are
`acquireHistoryRetentionLeaseTx`, `renewHistoryRetentionLeaseTx`, and
`releaseHistoryRetentionLeaseTx` from `Kiroku.Store.HistoryRetention`.

Plan 254 consumes serving/candidate status fields after this plan lands. Plan 255
attaches managed, versioned read contracts and contributes a promotion reconciliation
hook; this plan's core cutover must remain valid when no external contracts are declared.
Plan 257 shares group locks and serving revision dispatch but not target-generation
lifecycle.


## Commit and Trailer Convention

Use Conventional Commits and include:

```text
MasterPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
ExecPlan: docs/plans/256-rebuild-into-versioned-targets-with-atomic-cutover.md
Intention: intention_01kzw6dkhje7qvw6w321pwyv12
```


## Revision Note

Revised 2026-08-13 after architecture validation. The previous clone-only protocol was
replaced with application-provisioned schema generations, projection-revision-aware
writers, persisted object identity and DDL evidence, enforced source retention, one
bounded deterministic lock phase, and explicit consumer-contract compatibility limits.

Revised again on 2026-08-13 after Kiroku implemented IR-6 and published the packages
Keiro requires. The upstream blocker is complete, the exact 0.7.0.0/0.3.2.0 package
adoption and lease APIs are now specified, the long-rebuild lease is separated from
plan 257's one-stream guard, and Milestone 1 is ready to begin.

Revised on 2026-08-14 after implementation completed all six milestones. The final
revision records the restricted-clone envelope, retirement/drop protocol, operator and
Jitsurei evidence, external runtime-pattern updates, full validation counts, and EP-1's
completed status.
