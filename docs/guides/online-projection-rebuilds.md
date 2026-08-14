# Online Schema-Versioned Projection Rebuilds

Use an online rebuild when a projection group must change schema without exposing an
empty or partially replayed table. Keiro provisions a candidate generation beside the
serving generation, keeps V1 readable and writable during replay, catches up behind a
short writer fence, and promotes every target in one bounded PostgreSQL transaction.

This is distinct from an [offline projection rebuild](offline-projection-rebuilds.md),
which deliberately takes the group out of service and prepares the serving tables in
place.

## Deploy A Revision Bridge

Deploy one validated catalog containing both revisions before starting the rebuild.
Each `ProjectionRevision` binds all of the facts that must move together:

- a stable revision identity;
- one `TargetProvisioner` per target, including schema version, expected shape,
  validator, and canonical index/constraint/owned-sequence names;
- physical-target-parametric live handlers;
- physical-target-parametric replay adapters; and
- candidate verification.

The serving revision remains the write authority until promotion. Candidate replay uses
the candidate revision. A runtime that does not contain the revision persisted as
serving fails closed before it runs application SQL.

Application provisioners own the desired DDL. Keiro supplies a quoted staging table
name and owns the surrounding transaction. A provisioner must create its complete
target under `TargetProvisioningContext.stagingTable`; it must not commit, open another
connection, alter the serving table, or use an unbounded external side effect. The
validator returns relation identity, a stable observed-shape fingerprint, the exact
declared promotion-object map, and an application-owned catalog snapshot. Keiro records
that evidence and revalidates it under the final table locks.

The restricted clone mode is only for an exact-shape repair. It refuses serial-style
external `nextval` defaults, foreign keys, triggers, rules, row-level security and
policies, partitioning or inheritance, publications, non-default owner/ACL or replica
identity, dependent views/functions, and any other unsupported feature. Identity-owned
sequences, primary-key constraints, and indexes are accepted only when their structural
objects can be resolved and renamed through declared `PromotionObjectName` mappings.
Use application provisioning for schema evolution.

## Compatible And Breaking Readers

A physical generation is not a consumer contract. A compatible reader contract can be
repointed to V2 during promotion. A breaking result shape needs a new versioned read
contract or an application compatibility implementation over V2. Keeping V1 does not
keep it current: after promotion it receives no ordinary writes and is retained only
for inspection, drain, or forensics.

Do not treat a retained generation as automatic rollback. Once V2 has accepted writes,
switching names back can lose or reinterpret those writes. Recover with a compatible
forward operation or another rebuild unless the application has separately proved a
rollback protocol.

## Start And Advance The Run

Construct `ProjectionCatalogOperations` from the exact embedded validated catalog. The
typed start surface derives serving physical targets and the Kiroku retention lease; a
caller cannot substitute a target fleet.

```haskell
CatalogVersionedStartOptions
  { rebuildRunId = runId
  , rebuildGroupId = reportingGroup
  , servingRevisionId = revisionV1
  , candidateRevisionId = revisionV2
  , targetMode = ApplicationProvisioned
  , replayPageSize = 500
  , cutoverThreshold = 1000
  , cutoverLockTimeoutMs = 5000
  , promotionDedupLimit = 1000000
  , retentionDuration = 600
  , requestedBy = "release-operator"
  , requestReason = "reporting schema V2"
  }
```

`startVersionedGroupRebuild` transactionally registers V1 as serving, creates and
validates every V2 staging generation, acquires history retention, and returns durable
progress. Repeated start with the same run identity resumes the same objects; a failed
begin leaves no run, lease, or partial candidate.

Call `resumeVersionedGroupRebuild` until the phase is `VersionedPromoted`. Each call
advances one durable boundary. Replay can require several rounds while live V1 traffic
continues. Every replay chunk stages its async redelivery keys in PostgreSQL rather than
retaining the historical set in process memory. Before fencing, Keiro removes evidence
already below durable checkpoint floors and checks the staged count plus the largest
permitted tail against `promotionDedupLimit`. An oversized run returns
`VersionedPromotionDedupLimitExceeded` while V1 remains writable. Reduce subscription
lag, or abandon and begin a deliberately reviewed run with a larger persisted limit;
changing the limit while resuming the same run is an identity conflict.

Near convergence, Keiro fences writers, captures a final head, and replays the bounded
tail. The next resume is a durable preparation step: it validates the candidate, runs
application verification, installs staged dedup evidence, advances checkpoints, and
releases retention without taking target relation locks. The status report then shows
`promotionPrepared = true`. A following resume performs only the short atomic promotion.

`cutoverLockTimeoutMs` is an absolute database-clock budget for one writer-fence or
promotion attempt, not for the complete run. The promotion budget starts before the
group-row lock and is reused for one deterministically ordered statement that locks all
serving and candidate relations. Several blocked tables therefore cannot each consume
the full timeout. A timeout returns `VersionedCutoverDeadlineExceeded` with phase
`writer-fence`, `promotion-group`, or `target-relations`; no partial rename or metadata
swap commits.

Recovery depends on the durable boundary. A `writer-fence` timeout leaves the run in
ordinary replay with V1 readable and writable. Once the fence succeeds, any preparation
failure leaves the group fenced. A `promotion-group` or `target-relations` timeout after
`promotionPrepared = true` preserves the already prepared dedup/checkpoint evidence and
keeps the group fenced; inspect it, then resume after contention clears or abandon it.

Kiroku's renewable history-retention lease protects the replay interval from hard
deletion. Keiro renews the original lease before replay and cutover mutation. An expired
or unrenewable lease fails the run closed and fences writers; abandon it and start a new
run because a new lease cannot prove that the old candidate saw unchanged history.

## Operate Through The Embedded CLI

Versioned mutations need compiled provisioners and revision handlers, so they are
available only when the application embeds `AppHooks.projectionCatalog`. Every mutation
uses the normal preview/`--force` boundary:

```bash
my-service ops rebuild versioned start reporting \
  --run-id reporting-v2-20260814 \
  --serving-revision reporting-v1 \
  --candidate-revision reporting-v2 \
  --target-mode application \
  --promotion-dedup-limit 1000000 \
  --requested-by release-operator \
  --reason "reporting schema V2"

my-service ops rebuild versioned start reporting \
  --run-id reporting-v2-20260814 \
  --serving-revision reporting-v1 \
  --candidate-revision reporting-v2 \
  --target-mode application \
  --requested-by release-operator \
  --reason "reporting schema V2" \
  --force

my-service ops rebuild versioned status reporting-v2-20260814 --json
my-service ops rebuild versioned resume reporting-v2-20260814
my-service ops rebuild versioned resume reporting-v2-20260814 --force
```

Inspect before every retry. Human and JSON status expose the persisted dedup limit,
current staged count, provisional head, and preparation state. A replay or validation
failure is repairable when its
application-owned cause can be corrected without changing the stored contract. A DDL
race, relation-OID mismatch, changed revision contract, or expired retention proof is a
refusal to guess. `versioned abandon` drops staging generations, releases active
retention, records terminal evidence, and leaves the serving revision intact. A run
already inside the final fence remains write-fenced until resumed or abandoned.

## Retire Explicitly

After promotion, list retained V1 generations with:

```bash
my-service ops rebuild retired --json
my-service ops rebuild drop-retired GENERATION_UUID
```

The first `drop-retired` invocation is read-only. Its preview refuses a generation used
by an active group run, a compatible catalog read-contract reference, or a normal
PostgreSQL dependency such as a view. After consumers and dependencies are deliberately
migrated, repeat the exact command with `--force`. Keiro takes an exclusive lock,
revalidates relation identity and blockers, executes `DROP TABLE` without `CASCADE`, and
marks the generation dropped in the same transaction. Repeating a successful drop is an
idempotent no-op.

## Executable Jitsurei Transcript

`Jitsurei.ReadModels` declares a real V1/V2 bridge. V2 renames the summary's `status`
column to `state`, adds `source_revision`, provisions three staging tables, and supplies
revision-aware live/replay SQL. The database-backed test writes before and during
replay, promotes all three targets, writes through V2 afterward, observes three retired
V1 generations, and verifies that the serving summary has `state` but no `status`.
It also publishes `jitsurei_order_summary_reader_v1()` and v2 contracts. The test
executes the v1 function while V2 is replaying, then proves that promotion activates v2
and makes the incompatible v1 fail with `KR003` rather than read the retained table.

```text
Jitsurei read model
  rebuilds an incompatible schema beside live V1 and atomically serves V2 [✔]

Finished in 0.2175 seconds
1 example, 0 failures
```

Run the proof with:

```bash
cabal test jitsurei-test
```

### External client cutover transcript

The database-backed test executes the same statements as this `psql` session. These
calls deliberately use ordinary read-write transactions because the guard takes a
shared lifecycle lock:

```text
-- V2 is replaying; V1 is still the serving revision.
keiro=> BEGIN;
BEGIN
keiro=*> SELECT order_id, status
         FROM keiro_read.jitsurei_order_summary_reader_v1()
         ORDER BY order_id;
      order_id       | status
---------------------+--------
 versioned-before    | placed
(1 row)
keiro=*> COMMIT;
COMMIT

-- The atomic promotion has committed.
keiro=> \set VERBOSITY verbose
keiro=> BEGIN;
BEGIN
keiro=*> SELECT order_id, status
         FROM keiro_read.jitsurei_order_summary_reader_v1();
ERROR:  KR003: external read contract is incompatible with the serving revision
keiro=!> ROLLBACK;
ROLLBACK

keiro=> BEGIN;
BEGIN
keiro=*> SELECT order_id, state, source_revision
         FROM keiro_read.jitsurei_order_summary_reader_v2()
         ORDER BY order_id;
      order_id       | state  | source_revision
---------------------+--------+-----------------
 versioned-after     | placed |               2
 versioned-before    | placed |               2
 versioned-during    | placed |               2
(3 rows)
keiro=*> COMMIT;
COMMIT
```

The corresponding assertions live in `jitsurei/test/Main.hs`; they use the real
catalog bridge, migration-owned guard, candidate replay, promotion transaction, and
generated public functions rather than a mocked client surface.

For the full protocol, ownership, and recovery rationale, see
[ADR 0034](../adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md)
and [ADR 0036](../adr/0036-external-readers-use-versioned-guarded-sql-contracts.md).
