---
id: 41
slug: make-read-models-safely-readable-by-out-of-process-consumers
title: "Make read models safely readable by out-of-process consumers"
kind: master-plan
created_at: 2026-08-12T23:55:22Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
---

# Make read models safely readable by out-of-process consumers

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept current as work proceeds. If
durable project context changes, update or create ADRs in `docs/adr/` in the same
change.


## Vision & Scope

This MasterPlan implements
`docs/improvement-requests/make-read-models-safely-readable-by-out-of-process-consumers.md`
(IR-22) before the 0.12.0.0 release. Its primary availability use case is a projection
schema change: create the desired new schema beside the serving projection, reconstruct
it from retained event history, catch it up while the old generation remains live, and
promote it atomically. The same machinery also repairs data corruption or changed
projection logic when the physical schema is unchanged.

Today Keiro's group fence exists only at Haskell call boundaries. A process with an
independent PostgreSQL connection can issue `SELECT` directly against a target while an
offline rebuild has truncated it and is progressively replaying history. The result is
not an error; it is a coherent but obsolete picture that can cause successful downstream
actions with incorrect data. The requesting consumer,
`mori://tan/notification-render-service`, found this during design review while
separating an event-sourced service from a stateless TypeScript renderer.

After this MasterPlan completes:

- a catalog represents application-defined projection revisions and durable physical
  target generations, including their schema versions and verified shape;
- a schema-changing rebuild provisions candidate generations from application-supplied
  DDL, replays and validates them without disturbing the serving generation, then uses
  a short bounded fence for final catch-up and atomic promotion;
- live writers dispatch through the persisted serving projection revision and fail
  closed if the running binary cannot supply it;
- an external SQL reader calls a versioned, guarded contract rather than selecting a
  physical target directly, and receives documented, distinguishable failures for
  unavailable or incompatible contracts;
- a versioned status relation reports serving availability and serving position
  separately from candidate-rebuild lifecycle and progress;
- an operator can transactionally reproject one stream into a row-per-aggregate model,
  including the deduplication evidence that prevents later async redelivery from
  reapplying the repair;
- a mandatory adversarial release gate proves delivery routing, lock deadlines,
  bounded-memory promotion, privileges, scale, rolling compatibility, and failure
  recovery across the complete status/read/rebuild/repair surface.

The architecture is fixed by
`docs/adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md`.
Applications continue to own desired table DDL, column semantics, indexes, constraints,
dependent objects, projection SQL, and compatibility functions. Keiro owns generation
name allocation, lifecycle metadata, fencing, replay, validation orchestration,
checkpoint and deduplication coordination, atomic promotion, retirement, and safe
destructive operations. A restricted clone provisioner supports same-schema repair;
it is not the schema-evolution mechanism.

This lands before 0.12.0.0 because the generation model, public SQL contracts,
SQLSTATEs, and catalog fingerprint fields become compatibility promises at the first
stable release. Any `.keiro` additions must land while language 5 is still a candidate.

Excluded: declarative payload mappings from IR-25; automatic schema inference or a
general schema-diff engine; replay of external side effects; perpetual dual-write to
retired schemas; and release mechanics. A breaking consumer schema requires a new
read-contract version or an application-provided compatibility implementation. Merely
retaining the retired table does not make it current.


## Decomposition Strategy

The work now has five child ExecPlans. The first four deliver the requested
capabilities, while the fifth is a fixing and adversarial verification gate added after
review of the first completed implementation. The generation and cutover protocol must
define the durable lifecycle, serving-revision, schema-provisioning, and position
vocabulary before either public SQL contract freezes it.

EP-1, plan 256, establishes schema-versioned projection revisions, target generations,
application provisioning, revision-aware writers, replay, validation, bounded cutover,
and retirement. It includes a PostgreSQL proof milestone before public API or schema
contracts are frozen. Kiroku has now delivered the protected replay-history contract
requested by `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-6` in
`kiroku-store` 0.7.0.0 and `kiroku-store-migrations` 0.3.2.0. EP-1 is now complete.

EP-2, plan 254, publishes `keiro_read.projection_group_status_v1` after EP-1 has defined
the stored generation model. Its external prerequisite,
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-5`, is complete in
`kiroku-store-migrations` 0.3.1.0 as the stable
`kiroku.subscription_checkpoints_v1` relation. Keiro will not create a durable view
dependency on Kiroku's private `kiroku.subscriptions` table.

EP-3, plan 255, builds the sanctioned external read surface on EP-1's generation
binding and EP-2's availability vocabulary. It grants external roles only execution of
guarded, versioned functions. Keiro may generate a safe all-row function with a fixed
100-row limit for small models, while applications provide efficient keyed functions
that invoke the same guard
inside the same statement. Raw generated target views receive no external `SELECT`
grant.

EP-4, plan 257, adds targeted per-stream repair. It can proceed largely independently,
but it uses the same group lock and read-availability semantics and must backfill the
affected projection's deduplication keys in the repair transaction.

EP-5, plan 259, begins immediately against EP-1's delivered code. It restores exact
inline versus subscription delivery authority, makes the cutover deadline genuinely
overall, stages and admits deduplication work before fencing, and establishes
comparative performance budgets. As EP-2 through EP-4 complete, EP-5 adversarially
reviews their actual implementations for concurrency, security, privilege, scale,
upgrade, and failure-recovery defects. It is the final release gate: findings are fixed
rather than merely reported, and no critical or high-severity issue may remain when the
MasterPlan closes.

Durable cross-plan choices belong in ADR-26, ADR-31, ADR-34, and the downstream
status/read/repair ADRs. Task-local PostgreSQL evidence and operational transcripts stay
in the child plans.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft / Integration Deps | Status |
|---|-------|------|-----------|-------------------------|--------|
| 1 | Rebuild schema-versioned targets with atomic cutover | docs/plans/256-rebuild-into-versioned-targets-with-atomic-cutover.md | Satisfied external: MP-39 plans 246, 247, 258; Kiroku IR-6 releases | None | Complete |
| 2 | Publish a versioned serving and rebuild status relation | docs/plans/254-publish-a-documented-projection-status-relation-for-external-readers.md | EP-1; satisfied external: Kiroku IR-5 release | None | Complete |
| 3 | Fence external reads behind versioned sanctioned SQL contracts | docs/plans/255-fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface.md | EP-1, EP-2 | None | Complete |
| 4 | Add targeted per-stream reprojection to catalog operations | docs/plans/257-add-targeted-per-stream-reprojection-to-catalog-operations.md | Satisfied external: Kiroku IR-6 releases | EP-1, EP-3 | Complete |
| 5 | Adversarially review and harden read-model release safety | docs/plans/259-adversarially-review-and-harden-read-model-release-safety.md | EP-1 | Rolling integration with EP-2, EP-3, and EP-4; final gate waits for all three | Complete |

Status values are Not Started, In Progress, Complete, and Cancelled. Registry numbers
define the EP labels used in this MasterPlan; filenames keep their existing stable plan
IDs.


## Dependency Graph

EP-1 is the architectural root. Its replay-correction prerequisites in MasterPlan 39
are complete: plan 246 fixes ordered paging, plan 247 fixes replay adapter order in the
resume contract, and plan 258 makes deduplication backfill plus checkpoint advance part
of promotion. Schema-changing replay must reuse those correctness primitives rather
than fork them. Its source-retention prerequisite is also satisfied: the release for
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-6` publishes renewable
history-retention leases in `kiroku-store` 0.7.0.0 and their migration in
`kiroku-store-migrations` 0.3.2.0.

EP-2 begins after EP-1 because it reports facts owned by the generation protocol:
serving revision and epoch, serving applied position, active candidate generation,
candidate progress, and orthogonal read/write availability. Its former external blocker
is resolved: `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-5` publishes the
frozen `kiroku.subscription_checkpoints_v1` relation in
`kiroku-store-migrations` 0.3.1.0. A Haskell API remains insufficient for a PostgreSQL
view, and another library's private table is not a supported cross-schema contract.

EP-3 begins after EP-1 and EP-2. Its guard reads stable persisted availability rather
than embedding a closed list of lifecycle states, and its managed read contracts bind
to serving generations. Cutover invokes its object-level reconciliation in the same
promotion transaction.

EP-4's Kiroku prerequisite is satisfied by `kiroku-store` 0.7.0.0 and
`kiroku-store-migrations` 0.3.2.0. It uses `lockStreamHistoryForReplayTx` followed by
`readStreamForwardTx` in the same transaction; it does not acquire the long-rebuild
retention lease used by EP-1. EP-4 can otherwise proceed in parallel once its
implementation is reconciled with the final group-lock type. It pauses writers for the
selected group for the duration of one transaction but does not change lifecycle or
take readers out of service.

EP-5 started from EP-1 rather than waiting for the rest of the initiative. Its first
three milestones corrected and benchmarked the delivered revision/cutover protocol.
Its rolling audit consumed each of EP-2, EP-3, and EP-4 after that child's implementation
completed, and its final integration milestone passed after all three reviews closed.

The feature-delivery path EP-1 → EP-2 → EP-3, parallel EP-4 path, and final EP-5 release
path are all complete. All external prerequisites are satisfied and no child plan or
integration dependency remains open.


## Integration Points

The shared catalog types live in `keiro/src/Keiro/Projection/Catalog.hs`. EP-1 owns
`ProjectionRevisionId`, target schema/provisioner identity, physical-target-parametric
handlers, and the relation between serving and candidate revisions. EP-3 attaches
versioned external read contracts to those revisions. Both plans must use one canonical
fingerprint representation and apply ADR-32's prefix-bump rules.

The private lifecycle schema is owned by `keiro-migrations`. EP-1 owns generation,
revision, run-target, and serving-binding tables. EP-2 owns the public
`keiro_read.projection_group_status_v1` relation and its supported column semantics.
EP-3 owns managed read-contract metadata and generated functions in `keiro_read`.
Public relations are versioned; incompatible evolution creates `v2`, never silently
repurposes `v1`.

The runtime writer boundary is shared by EP-1, EP-4, and EP-5.
`lockProjectionGroupsTx` must
return the persisted serving revision as well as availability. Inline and async paths
select only the exact delivery-scoped handlers for that revision while holding the
group lock and refuse an unknown revision before application SQL. EP-5 owns the
correction that keeps command-time inline effects separate from one subscription's
deduplicated effects. EP-4 uses the exclusive group lock and executes the same serving
revision's stream-scoped handler.

The promotion transaction is shared by all first three plans. EP-1 owns its order:
lock group and run; finish tail replay; verify source retention, replay completion,
candidate schema and application invariants; install deduplication and checkpoint
evidence; acquire all serving/staging relation locks in deterministic order under one
bounded deadline; revalidate relation identities, schema fingerprints, and dependencies;
swap the complete group; update the serving revision and epoch; reconcile managed
read-contract bindings; and commit. EP-2 observes the committed metadata. EP-3 may add
object reconciliation steps but may not create an independent cutover transaction.
EP-5 verifies that the implementation follows this ordering under one overall lock
deadline, moves arbitrary application work out of the exclusive-relation phase, and
adds bounded admission for promotion evidence.

The schema-provisioning boundary is application-owned. A provisioner receives allocated
physical names and creates a complete candidate schema transactionally. The built-in
clone provisioner is gated to a small, enumerated PostgreSQL subset. Application
provisioners may support richer DDL, but both paths must provide an expected shape and
dependency contract that Keiro can recheck immediately before promotion. External event
hard deletion is refused or serialized while a rebuild depends on that history.

The Kiroku integration now has two concrete owner-published boundaries. EP-2 reads the
frozen `kiroku.subscription_checkpoints_v1` relation shipped by
`kiroku-store-migrations` 0.3.1.0. EP-1 acquires, renews, and releases a durable
history-retention lease through `acquireHistoryRetentionLeaseTx`,
`renewHistoryRetentionLeaseTx`, and `releaseHistoryRetentionLeaseTx`; EP-4 instead uses
`lockStreamHistoryForReplayTx` and `readStreamForwardTx` for one transaction. Keiro must
raise its direct bounds to `kiroku-store >=0.7 && <0.8` and
`kiroku-store-migrations ^>=0.3.2.0` when implementation begins. The release contracts
are recorded by `mori://shinzui/kiroku/plans/72-publish-a-stable-sql-subscription-checkpoint-relation`
and `mori://shinzui/kiroku/plans/73-protect-replay-history-with-retention-leases-and-stream-guards`.

Cross-repository documentation is an integration deliverable, not a vague repository
name. Update
`mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections` and
`mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs` after EP-1 and
EP-3 land. The first URI resolves now; the second is the intended canonical handle for
`runtime-patterns/keiro/projection-catalogs.md` and awaits a registry refresh. Notify
`mori://tan/notification-render-service` when the versioned read contract is available.

EP-5 owns no competing public surface. It owns the release evidence and may correct an
artifact delivered by EP-1 through EP-4 only while also updating that artifact's child
plan, tests, changelog, and owning ADR. Its review matrix covers the status view's query
plan and owner-rights privileges, external functions' security-definer and index
behavior, targeted repair's group-wide pause and history admission, cross-plan lock
ordering, bridge deployments, and relative steady-state performance.

Relevant local decisions are:

- `docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md`;
- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`;
- `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`;
- `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`;
- `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`;
- `docs/adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md`;
- `docs/adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md`.


## Progress

- [x] (2026-08-13T22:35:58Z) External Kiroku IR-6 prerequisite: verified the exported
  retention-lease and stream-guard APIs in released `kiroku-store` 0.7.0.0 and migration
  `0010` in released `kiroku-store-migrations` 0.3.2.0. Other cohort uploads do not block
  Keiro's direct dependencies.
- [x] (2026-08-13T22:51:59Z) EP-1 (256) M1: PostgreSQL proof covers explicit new-schema provisioning, object
  identity, dependency behavior, deterministic locking, rollback, and reader blocking.
- [x] (2026-08-13T23:32:54Z) EP-1 (256) M2: projection-revision and target-generation
  catalog contract, `catalog-v4`/`slice-v3` fingerprints, validation,
  DSL/code-generation changes, and bridge-deployment fixtures.
- [x] (2026-08-14T00:09:28Z) EP-1 (256) M3: private generation/revision lifecycle
  schema, OID and shape evidence, persisted cutover options, Kiroku IR-6 retention
  lease, idempotent provisioning/abandonment, and legacy availability transitions.
- [x] (2026-08-14T00:41:07Z) EP-1 (256) M4: revision-aware inline and async live writers,
  physical-target-parametric replay and verification, closed-world serving bindings,
  and unknown-revision fail-closed bridge-deployment tests.
- [x] (2026-08-14T01:22:41Z) EP-1 (256) M5: converging replay, bounded final fence,
  deterministic all-target locks, schema/dependency revalidation, atomic cutover,
  crash-resume, retention failure fencing, and concurrent reader/writer acceptance.
- [x] (2026-08-14T02:22:44Z) EP-1 (256) M6: restricted clone, explicit
  retirement/drop, versioned operator commands, incompatible Jitsurei v1/v2 evidence,
  ADR and runtime-pattern reconciliation, runbooks, changelogs, and `just verify`.
- [x] (2026-08-13T22:35:58Z) EP-2 (254) M1: Kiroku IR-5's frozen
  `kiroku.subscription_checkpoints_v1` contract verified in released
  `kiroku-store-migrations` 0.3.1.0; no dependency on a private Kiroku table.
- [x] (2026-08-14T03:10:27Z) EP-2 (254) M2: versioned public status relation reports serving and candidate facts
  independently, with schema-gate coverage and grants documentation.
- [x] (2026-08-14T03:22:00Z) EP-2 (254) M3-M4: typed accessor, lifecycle proofs,
  docs, ADR, changelogs, out-of-process transcript, and full verification.
- [x] (2026-08-14T03:56:13Z) EP-3 (255) M1: versioned external-read declarations, registry validation,
  fingerprints, and rolling-version compatibility diagnostics.
- [x] (2026-08-14T04:30:59Z) EP-3 (255) M2: stable guard plus managed per-contract functions, no raw external
  view grants, application keyed-function integration, security and concurrency tests.
- [x] (2026-08-14T06:11:25Z) EP-3 (255) M3-M4: candidate language-5 surface, dependency-aware object
  reconciliation, documentation, ADR, adoption evidence, and full verification.
- [x] (2026-08-14T06:53:09Z) EP-4 (257) M1-M2: stream-scoped policy and one-transaction
  repair with explicit truncation refusal, group writer pause, and transactional
  deduplication backfill.
- [x] (2026-08-14T07:45:54Z) EP-4 (257) M3-M5: operations wrappers, two-phase CLI,
  concurrency tests, documentation, ADR reconciliation, changelogs, and full
  committed-corpus verification.
- [x] (2026-08-14T08:43:20Z) EP-5 (259) M1-M2: restore delivery-scoped revision dispatch and implement a true
  overall promotion deadline with staged, bounded deduplication preparation and a
  minimal exclusive-lock phase.
- [x] (2026-08-14T11:06:35Z) EP-5 (259) M3-M4: establish comparative performance budgets and adversarially
  review the delivered EP-2, EP-3, and EP-4 implementations, fixing every critical or
  high-severity finding.
- [x] (2026-08-14T11:37:38Z) EP-5 (259) M5: cross-plan fault injection, rolling-upgrade evidence, ADR/contract
  reconciliation, benchmark gates, corpus replay, and full verification make the
  MasterPlan eligible to close.


## Surprises & Discoveries

- The original versioned plan cloned the live table, so it could not implement the
  principal schema-change use case. PostgreSQL cloning also leaves material DDL,
  dependency, privilege, and object-name gaps; serial defaults may keep their old
  sequence dependency.
- Query-model `version` and `shape_hash` identify a query contract, not a physical
  target generation. A separate target-level generation and projection-revision model
  is required.
- The original status design conflated a candidate replay cursor with the serving
  generation's applied position and treated `rebuilding-versioned` as non-live even
  though the old generation remains available. Lifecycle, read availability, write
  availability, serving progress, and candidate progress are orthogonal.
- Plan 254's checkpoint-regression acceptance became stale when MasterPlan 39 plan 258
  made deduplication backfill and checkpoint advance atomic at promotion. Generation
  epochs, not position regression, identify replacement data.
- A Keiro-owned view over private `kiroku.subscriptions` would make a future Kiroku DDL
  migration fail through PostgreSQL dependency tracking. This required an
  owner-published SQL contract from `mori://shinzui/kiroku`; IR-5's released relation
  now supplies it.
- PostgreSQL views bind relation identity, not a textual table name. Promotion must
  explicitly reconcile every managed dependent object, and unsupported external
  dependencies must block promotion or be declared to an application provisioner.
- An all-row PL/pgSQL wrapper is fail-safe but prevents predicate pushdown. Efficient
  readers need application-supplied keyed functions that call the Keiro guard; granting
  `SELECT` on an unguarded target view would recreate the original hazard.
- Dropping and recreating the whole `keiro_read` schema is incompatible with
  consumer-owned wrappers and rolling deployments. Managed objects require individual
  versioned reconciliation and explicit retirement.
- Plan 257's original acceptance of async duplicate reapplication contradicts ADR-31
  and completed plan 258. Targeted repair must write deduplication evidence in the same
  transaction, while leaving the shared subscription checkpoint unchanged.
- Source history at or below a rebuild head is not inherently immutable because Kiroku
  supports hard deletion. Online rebuilds require an enforced retention or serialization
  contract rather than an assumption.
- Kiroku implemented IR-6 as two deliberately different tools. Renewable leases protect
  long fan-in rebuilds and conservatively refuse destructive SQL while active;
  transaction-scoped stream guards protect one stream repair by row-lock ordering. EP-1
  and EP-4 must not collapse these protocols into one abstraction.
- At 2026-08-13T22:35:58Z, Hackage already resolved the two packages Keiro needs from
  Kiroku's in-progress release cohort: `kiroku-store` 0.7.0.0 and
  `kiroku-store-migrations` 0.3.2.0. Uploads of unrelated adapter/observability packages
  can finish independently of this MasterPlan.
- The existing `writes_allowed` fact is independent of lifecycle status, so a safe
  live-writer lock must return the persisted serving revision and its complete physical
  generation binding along with permission. Status-only dispatch would still permit a
  routing race at promotion.
- Versioned crash recovery needs two persisted cutover boundaries: a durable writer
  fence before final-head capture, and a durable final head before the last replay.
  Treating both as one status would force recovery to guess whether it may recapture a
  head or has already promised a specific frontier.
- Retention renewal failure is itself durable availability state. Committing a failed
  run while leaving v1 readable and fencing writes is safer than rolling the failure
  back with candidate work and accidentally presenting an expired lease as resumable.
- Kiroku's v1 checkpoint relation exposes durable member rows but not expected member
  topology. EP-2 therefore proves presence for every catalog-bound subscription and
  floors all published members; it documents that a future topology contract would be
  required to detect an absent member within an otherwise present subscription.
- Upgrade safety requires an explicit `unmanaged` cursor basis. A missing private row
  cannot be interpreted as inline append authority, so migration 0026 seeds every
  existing group and catalog registration/adoption reconciles the derived basis.
- EP-1's revision-wide live handler erased the catalog's delivery boundary. The command
  path executes every serving-revision handler, and the async path later executes that
  same list after claiming only one async dedup key. Jitsurei's async audit is therefore
  updated by a post-promotion command without subscription delivery; idempotent upserts
  hide the duplicate that a non-idempotent handler would expose.
- EP-1's configured cutover timeout is installed after the promotion row lock and is a
  PostgreSQL per-statement timeout. Because serving and staging relations are locked in
  separate statements, several contended objects can multiply the promised deadline;
  writer-fence acquisition is not locally bounded either.
- Promotion-time async deduplication is collected after writers are fenced by scanning
  from the slowest checkpoint through the captured head into one Haskell list. The
  already-materialized list is then inserted in batches while all target relations are
  exclusively locked, so checkpoint lag controls both memory and outage duration.
- Application schema validation and revision verification currently run after target
  relation locks, along with deduplication, checkpoint, and lease work. The architecture
  requires expensive preparation before those locks whenever correctness permits; the
  locked phase needs a smaller explicit contract.


## Decision Log

- Decision: Implement all four IR-22 capabilities before 0.12.0.0.
  Rationale: they define the first stable external-reader and rebuild contracts, and
  schema-changing online rebuild is the primary availability use case.
  Date: 2026-08-12
- Decision: Treat schema-changing rebuild as the general case and same-schema repair as
  the restricted clone special case.
  Rationale: projection rebuilds principally populate changed schemas; cloning the old
  shape cannot deliver that outcome.
  Date: 2026-08-13
- Decision: Applications own desired generation DDL through versioned provisioners;
  Keiro owns generation lifecycle and atomic promotion.
  Rationale: Keiro cannot infer application schema from opaque SQL, while applications
  should not reimplement replay and cutover correctness. ADR-34 records the boundary.
  Date: 2026-08-13
- Decision: Reorder the plans to generation protocol, status relation, sanctioned read
  contracts, with targeted repair parallel.
  Rationale: public status and read surfaces must consume the final serving/candidate
  vocabulary rather than freeze the offline lifecycle first.
  Date: 2026-08-13
- Decision: A stable status contract is versioned and separates serving facts from
  candidate rebuild facts.
  Rationale: online rebuild keeps the old generation live; reporting staging progress as
  applied serving progress is false, and an unversioned additive contract still breaks
  consumers that decode complete rows.
  Date: 2026-08-13
- Decision: Do not reference Kiroku private relations from a persisted Keiro object.
  Rationale: schema ownership applies to reads as well as writes; the owner must publish
  the stable SQL checkpoint relation needed by an external status view.
  Date: 2026-08-13
- Decision: External roles receive guarded function execution, not raw target-view
  selection, and breaking consumer schemas use explicit read-contract versions.
  Rationale: guard-plus-view discipline is bypassable, and retaining a retired target
  cannot keep an incompatible contract current without an explicit compatibility or
  dual-write implementation.
  Date: 2026-08-13
- Decision: Promotion uses one bounded all-target lock phase with OID, schema,
  dependency, and revision revalidation.
  Rationale: application migrations do not participate in the group-row lock; replay
  evidence alone cannot prove that the objects being swapped are still the objects that
  were provisioned and validated.
  Date: 2026-08-13
- Decision: Targeted reprojection backfills projection deduplication keys but does not
  advance the group subscription checkpoint.
  Rationale: deduplication prevents the repaired events from being applied again;
  advancing a shared checkpoint could skip unrelated streams.
  Date: 2026-08-13
- Decision: Track the owner-published SQL checkpoint relation as
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-5` and replay-history
  protection as `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-6`.
  Rationale: both contracts change Kiroku-owned schema or lifecycle behavior and must be
  implemented, released, and adopted through explicit cross-repository artifacts rather
  than private SQL in Keiro.
  Date: 2026-08-13
- Decision: Resume with EP-1 and adopt Kiroku's released IR-5/IR-6 contracts at
  `kiroku-store >=0.7 && <0.8` and `kiroku-store-migrations ^>=0.3.2.0`.
  Rationale: authoritative Hackage metadata and upstream annotated tags agree on the
  required releases. The remaining uploads in Kiroku's wider package cohort are not
  dependencies of Keiro's status, rebuild, or targeted-repair implementations.
  Date: 2026-08-13
- Decision: Treat revision selection and write permission as one closed-world locked
  binding, with a typed refusal when the running catalog lacks the persisted revision
  or any serving target generation.
  Rationale: bridge deployments must fail before appending events, inserting async
  deduplication, or executing SQL whenever they cannot prove the serving code/schema
  pair under the group lock.
  Date: 2026-08-13
- Decision: Represent schema-versioned rebuilds with their own total request and report
  types, then expose them beside legacy offline rebuilds through the operator facade.
  Rationale: revision, generation, epoch, lease, source-progress, and cutover-phase facts
  are mandatory for versioned safety but undefined for unmanaged offline runs; a widened
  legacy record would be a partial protocol.
  Date: 2026-08-13
- Decision: Persist the cutover writer fence before separately capturing the final head,
  and renew the original Kiroku lease before every replay/cutover mutation.
  Rationale: either crash boundary resumes deterministically, and an expired retention
  proof becomes a durable failed/fenced run before any further candidate mutation.
  Date: 2026-08-13
- Decision: Retired-generation inventory remains available from durable database facts,
  while destruction requires the compiled catalog and a two-phase preview/force check.
  Rationale: old code may already be gone when operators inspect retained data, but
  irreversible removal must still revalidate read-contract references, PostgreSQL
  dependencies, relation identity, and retired lifecycle without `CASCADE`.
  Date: 2026-08-13
- Decision: Freeze status v1 as an owner-rights view over transactional authorities,
  with ordered signature verification and separate behavioral tests.
  Rationale: external roles need one grantable contract without private-schema access;
  signature drift and semantic drift require complementary evidence.
  Date: 2026-08-13
- Decision: Add EP-5 as a mandatory fixing and adversarial release gate.
  Rationale: review of completed EP-1 found a delivery-integrity bug, a non-global
  timeout, unbounded promotion evidence, and excessive work under exclusive locks.
  EP-2 through EP-4 are still being built, so their delivered code must receive the same
  hostile concurrency, scale, privilege, upgrade, and recovery review before 0.12.0.0.
  Date: 2026-08-13
- Decision: EP-5 may start from EP-1 now, reviews EP-2 through EP-4 as rolling
  integration dependencies, and blocks MasterPlan completion until no critical or
  high-severity finding remains.
  Rationale: immediate correction avoids building later contracts on a known-invalid
  writer boundary, while commit-specific reviews avoid mistaking plan prose for
  implementation evidence.
  Date: 2026-08-13


## Outcomes & Retrospective

The architecture-validation phase replaced a same-schema clone-and-swap design with
first-class application-provisioned schema generations, corrected the status and
targeted-repair semantics, and made upstream SQL ownership and source retention
explicit. EP-1 is complete: it delivers durable revision/generation identity,
revision-aware live and replay dispatch, renewable retention, multi-round convergence,
separately resumable fence/head phases, bounded all-target promotion, structural object
renaming, a closed restricted-clone envelope, and dependency-aware retired-generation
destruction. Jitsurei proves a genuinely incompatible three-target v1/v2 rebuild while
v1 remains readable and writable, then atomically serves v2 and retains the three v1
generations. The operator runbook and external runtime patterns are reconciled with the
implementation. A subsequent adversarial review found that EP-1's delivery routing and
bounded-cutover implementation did not yet satisfy those intended contracts under mixed
inline/async delivery, multi-object contention, or large checkpoint lag. EP-5 corrected
those defects and closed the final review gate. Historical EP-1 evidence is 16 focused
schema-versioned examples, 576 Keiro examples, 44 keiro-ops examples, 705 main DSL
examples plus every conformance component, 24 Jitsurei examples, 29 migration examples,
34 strict ADR concepts, a no-drift 39-entry corpus replay, and a passing `just verify`;
those green suites did not cover the adversarial cases now required by plan 259. EP-2
is also complete: it publishes the frozen 18-column owner-rights status relation,
transactionally reconciled cursor authority, a typed accessor, and external-client
lifecycle evidence without private Kiroku access. Its final gate adds 577 Keiro
examples, 24 Jitsurei examples, 31 migration examples, 35 strict ADR concepts, and a
passing `just verify`.

EP-3 is complete: versioned all-row and keyed contracts expose execute-only guarded SQL
functions, atomically follow compatible promotion, fail explicitly across breaking or
retired versions, and survive rolling registrations without schema-wide replacement.
The EP-5 adversarial pass subsequently added a 100-row all-row limit (`KR004`), exact
keyed set-result validation, post-lock contract revalidation, and retryable `KR001` when
a statement snapshot crosses promotion.
Candidate Language 5, operations, ADR-36, Jitsurei, user guidance, runtime patterns, and
the requesting consumer's plan all consume the shipped ABI. Its repeated isolated gate
passed 586 core, 58 PGMQ, 44 operations, 706 main DSL, 24 Jitsurei, and 32 migration
examples plus every repository policy check.

EP-4 is complete: explicit stream-owned catalog contracts drive a single-transaction
repair under stream-then-group locking, refuse incomplete history and unavailable
serving code, backfill async deduplication evidence, and expose database-backed preview
and forced execution through the embedded CLI. Its clean acceptance gate passed 595
core, 58 PGMQ with two documented pending cases, 46 operations, 706 main DSL, 24
Jitsurei, and 32 migration examples plus every conformance executable, strict OKF and
repository policy, and the 39-entry no-drift corpus replay. The EP-5 review subsequently
closed an unbounded writer-pause
finding: every targeted repair now admits the exact locked stream count against a
positive reviewed maximum before taking the group-wide fence, with v2 preview/outcome
evidence and hard-delete/interruption rollback tests.

EP-5 is complete. It restored delivery-scoped revision dispatch, made promotion
timeouts one overall database-clock deadline, staged and bounded deduplication before
the exclusive fence, and established calibrated lifecycle/read performance budgets.
Its rolling reviews fixed bounded all-row reads, crossed-promotion snapshot refusal,
exact keyed-result and overload handling, and pre-fence targeted-repair admission.
Commit `a68b2204` adds the final incompatible-v1/v2 fault scenario: relation contention,
post-rename failure, post-metadata failure, and post-managed-wrapper failure all retain
one v1 authority and the complete candidate before the same run succeeds on retry.

The final isolated `just verify` gate passed 610 core examples, 58 PGMQ examples with
two documented environment pendings, 47 operations examples, 706 main DSL examples
plus every conformance suite, 24 Jitsurei examples, and 34 migration examples. It also
passed 36 strict ADR concepts, 17 research concepts, 15 capability concepts, diagram
drift, every repository policy, and the 39-of-39 no-drift corpus replay. M3's direct
projection/read-model baselines and five-run sampler passed the published 1.25
p95-latency and 0.90 throughput budgets. No critical or high finding remains; all five
ExecPlans and MasterPlan 41 are complete.


## Revision Note

Revised 2026-08-13 after pre-implementation architecture review and user discussion.
The revision makes schema-changing rebuilds the primary use case, introduces
projection revisions and durable target generations, reorders the dependency graph,
removes private Kiroku-table coupling, versions the status and read contracts, hardens
PostgreSQL DDL and cutover validation, and corrects targeted reprojection deduplication.

Revised again on 2026-08-13 after creating the owning Kiroku improvement requests.
External checkpoint and replay-retention prerequisites now use the exact canonical IR-5
and IR-6 references throughout the MasterPlan and affected child ExecPlans.

Revised again on 2026-08-13 after Kiroku implemented the requested contracts and began
the release-cohort upload. The required Keiro packages are already published and tagged:
IR-5 is available through `kiroku-store-migrations` 0.3.1.0, and IR-6 through
`kiroku-store` 0.7.0.0 plus `kiroku-store-migrations` 0.3.2.0. The external blockers are
marked satisfied, the concrete lease/guard ownership split is recorded, and EP-1 is the
next implementable child plan.

Revised on 2026-08-14 after EP-1 completed. The registry and dependency graph now mark
plan 256 complete and select EP-2 as the next critical-path child; the retrospective
records the delivered rebuild/retirement protocol, external runtime-pattern updates,
and final validation evidence.

Revised on 2026-08-14 after an adversarial review of EP-1 and while EP-2 was in active
implementation. Added plan 259 as EP-5, recorded the delivery-routing, deadline,
deduplication-memory, and exclusive-lock findings, made corrective work immediately
parallel with feature delivery, and made a commit-specific adversarial review of EP-2
through EP-4 plus zero open critical/high findings mandatory before MasterPlan closure.

Revised on 2026-08-14 after EP-3 completed. The registry now selects EP-4, the progress
ledger records the guarded SQL-contract milestones, and the retrospective captures the
isolated release gate plus durable runtime-pattern and consumer-plan updates.

Revised on 2026-08-14 after EP-4 completed. The registry now selects EP-5, the progress
ledger records targeted-repair delivery and the committed-corpus acceptance run, and
the retrospective captures the stream-first lock order, deduplication backfill, and
operator surface now subject to the final adversarial gate.

Revised on 2026-08-14 after EP-5 and the final release gate completed. The registry and
progress ledger now mark every child complete; the retrospective records the integrated
promotion fault injection, calibrated benchmark evidence, strict documentation checks,
complete test suites, and 39-entry no-drift corpus replay that close MasterPlan 41.
