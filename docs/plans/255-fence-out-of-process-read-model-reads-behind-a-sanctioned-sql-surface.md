---
id: 255
slug: fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface
title: "Fence external reads behind versioned sanctioned SQL contracts"
kind: exec-plan
created_at: 2026-08-12T23:56:02Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
master_plan: "docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md"
---

# Fence external reads behind versioned sanctioned SQL contracts

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current. If implementation changes a
durable contract, update `docs/adr/` in the same change.


## Purpose / Big Picture

After this change an out-of-process consumer never needs direct `SELECT` privileges on
a projection table. It calls a versioned function in `keiro_read`. The function locks
and validates a Keiro-managed read contract, proves that the group is readable and that
the contract is compatible with the serving projection revision and result shape, and
only then executes the query. A rebuild, failure, retired contract, or incompatible
schema produces a documented SQLSTATE instead of zero rows or historical data.

Online schema changes remain readable because the old serving generation stays active
during candidate replay. Compatible read contracts follow promotion atomically.
Breaking reader schemas receive a new function version. The old contract is retained
only when the application supplies a compatibility implementation over the new serving
revision; a retired physical table is not presented as current merely because it still
exists.

The built-in all-row contract is intentionally limited to small projections. Its guard
is enforceable, but an outer caller predicate cannot be pushed through a procedural
set-returning wrapper. Efficient keyed access uses an application-supplied inner SQL
implementation and a Keiro-generated outer function that performs the same guard and
forwards typed arguments. External roles receive `EXECUTE` only on the outer function.

This is EP-3 of
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`.
It hard-depends on plan 256's revision/generation model and plan 254's stable
`reads_allowed` vocabulary.


## Progress

- [x] (2026-08-14T03:56:13Z) M1: runtime read-contract declarations, version/shape/revision validation,
  canonical fingerprints, managed-object identity, and rolling-definition diagnostics
  are implemented and tested.
- [x] (2026-08-14T04:30:59Z) M2: migration and registration reconciliation install the stable guard,
  per-contract private bindings, generated all-row/keyed wrappers, explicit SQLSTATEs,
  secure privileges, and race-proof database tests without schema-wide drop/recreate.
- [ ] M3: candidate language-5 all-row contract syntax, parser/pretty/lowering/diff,
  generated runtime declarations, scaffolding for keyed inner functions, and corpus
  fixtures pass.
- [ ] M4: schema-changing cutover integration, docs, ADR, Jitsurei/external-client
  transcript, changelogs, security review, and `just verify` are complete.


## Surprises & Discoveries

- Granting `SELECT` on a generated target view lets a consumer bypass the guard and
  recreates the original hazard. Guarded functions are the only externally granted
  projection data surface.
- A generated all-row PL/pgSQL function is fail-safe but materializes the complete
  result before an outer filter. It cannot be advertised as the normal high-volume
  keyed query mechanism.
- `DROP SCHEMA ... CASCADE` followed by recreation breaks consumer-owned wrappers,
  destroys grants, and lets rolling processes repeatedly replace one another's objects.
  Managed objects require identity, definition hashes, and explicit retirement.
- PostgreSQL views and parsed SQL functions bind relation objects. Renaming the old
  serving table does not make an existing view follow the new object at the reused name.
  Cutover must reconcile managed dependencies in its transaction.
- Adding `rebuilding-versioned` to a generated guard's allow-list is unsafe in a rolling
  deployment: an older process can regenerate the previous definition. The guard must
  consume persisted `reads_allowed` and contract compatibility, not lifecycle names.
- A single unversioned function cannot serve mutually incompatible row shapes. Physical
  atomicity does not remove the need for consumer-contract migration.
- EP-1's placeholder catalog edge retained only contract ID and compatible revisions.
  Replacing it with the complete declaration necessarily advances canonical catalog
  identity from `catalog-v4`/`slice-v3` to `catalog-v5`/`slice-v4`; the existing
  preview-and-adopt workflow is the supported pre-0.12 transition for stored slices.
- An all-row wrapper cannot safely declare `RETURNS SETOF` using the serving table's row
  type because PostgreSQL binds that signature to the table OID that promotion retires.
  Both all-row and keyed contracts therefore name a stable result composite type; the
  physical binding remains private and replaceable.
- PostgreSQL rejects `SELECT ... FOR SHARE` inside a read-only transaction. Because the
  guard's shared row lock is what closes the authorization/cutover race, callers must
  use an ordinary read-write transaction even though the public function only returns
  rows.


## Decision Log

- Decision: External roles receive only `EXECUTE` on guarded outer functions and
  `USAGE` on `keiro_read`; no raw target or target-view `SELECT` grant is sanctioned.
  Rationale: safety must be enforced by privileges rather than documentation discipline.
  Date: 2026-08-13
- Decision: Every external read contract has a stable contract ID, explicit contract
  version, result-shape fingerprint, and compatible projection revision set.
  Rationale: query-model names and table names do not prove schema compatibility.
  Date: 2026-08-13
- Decision: The guard checks persisted `reads_allowed`, contract state, serving
  revision, and shape compatibility while holding the group row `FOR SHARE`.
  Rationale: availability is orthogonal to lifecycle names, and the shared lock prevents
  promotion from racing between authorization and query execution.
  Date: 2026-08-13
- Decision: Use SQLSTATE `KR001` for temporarily unavailable, `KR002` for unknown or
  retired contract, and `KR003` for serving revision/shape incompatibility.
  Rationale: callers need stable distinctions between retryable service state,
  deployment/configuration absence, and required consumer migration.
  Date: 2026-08-13
- Decision: Generate a small-model all-row function and a typed guarded outer wrapper
  for application-owned keyed implementations.
  Rationale: Keiro can enforce the guard and privileges without becoming a query DSL or
  preventing predicate pushdown in the inner implementation.
  Date: 2026-08-13
- Decision: Reconcile managed objects individually from durable metadata; never drop
  and recreate the whole public schema.
  Rationale: consumer-owned objects, grants, dependencies, and rolling deployments must
  survive unrelated catalog registration.
  Date: 2026-08-13
- Decision: The same contract version with a different definition hash is drift and a
  lower surface generation cannot overwrite a higher registered generation.
  Rationale: last-writer-wins registration would allow an older pod to roll back a
  security or compatibility fix.
  Date: 2026-08-13
- Decision: Breaking schema changes create a new external read-contract version.
  Rationale: the old and new result row types cannot both inhabit one PostgreSQL function
  signature. Old contracts remain active only with an explicit compatibility
  implementation that reads current data.
  Date: 2026-08-13
- Decision: Deployment owns database roles and grants.
  Rationale: Keiro documents exact least-privilege grants but does not create roles or
  assume role-management authority in migrations.
  Date: 2026-08-13
- Decision: Both all-row and keyed public wrappers declare an application-visible,
  schema-qualified result composite type, while Keiro owns the guarded wrapper and
  private generation binding.
  Rationale: a named contract type makes the public function signature independent of
  the physical serving table OID and gives registration an immutable result signature
  to fingerprint and verify.
  Date: 2026-08-14
- Decision: Advance canonical identity to `catalog-v5:` and `slice-v4:` when the full
  external read declaration replaces EP-1's compatibility placeholder.
  Rationale: contract version, query/result shape, SQL signature, implementation
  identity/version, compatibility set, and surface generation are durable owning-slice
  facts under ADR-32 and cannot be added under the old prefix.
  Date: 2026-08-14
- Decision: Require external reads to run in a read-write PostgreSQL transaction.
  Rationale: PostgreSQL forbids the guard's `FOR SHARE` lifecycle lock in a read-only
  transaction, and removing the lock would reintroduce the authorization/cutover race.
  Date: 2026-08-14


## Outcomes & Retrospective

Architecture review changed the plan from a guard-plus-public-view convention into a
privilege-enforced, versioned function contract. Milestone 1 is complete: the validated
catalog now owns full all-row/keyed declarations, stable SQL result signatures,
deterministic diagnostics, evolution inventory, and `catalog-v5`/`slice-v4` identity.
Milestone 1 evidence was 24 catalog examples, 7 canonical-preimage examples, a complete
workspace build, and strict validation of 35 ADR concepts. Milestone 2 now adds native
migration 0027, transactionally reconciled all-row and keyed wrappers, monotonic managed
object metadata, explicit dependency-previewed retirement, and the fixed shared-lock
guard. The migration suite passes 32 examples and the focused PostgreSQL suite passes
three end-to-end scenarios covering lifecycle SQLSTATEs, cutover locking, least
privilege, injection resistance, rolling downgrade refusal, dependency survival, and a
selective keyed index plan. Language-5 syntax, final cutover fixtures, documentation,
ADR reconciliation, and release evidence remain.


## Context and Orientation

The projection catalog in `keiro/src/Keiro/Projection/Catalog.hs` binds logical query
models to target identities and rebuild groups. Plan 256 adds projection revisions and
physical target generations. Plan 254 publishes one status row per group with
`reads_allowed`, serving revision, serving epoch, and separate candidate progress.

An external read contract is a public database API for one query-model binding. It is
not the physical target and is not the Haskell `ReadModel` closure. Its stable identity
survives physical generation promotion only while its declared result shape remains
compatible.

The guard and outer function execute in one caller transaction. The guard takes
`FOR SHARE` on the rebuild-group row. Plan 256's promotion takes `FOR UPDATE` on that
same row before table locks and metadata changes. Therefore either the read locks first
and completes against the old serving generation before promotion proceeds, or cutover
locks first and the read waits until the new metadata and managed object bindings commit.
The reader cannot authorize against one generation and execute against another
half-promoted generation.

The `keiro_read` schema is created by plan 254. Private lifecycle and managed-object
metadata remain in `keiro`; external roles need no `USAGE` there. Security-definer
functions use fully qualified object names, a fixed safe `search_path`, an owner without
superuser or bypass-RLS power beyond what the declared surface requires, and have
`PUBLIC` execute revoked.

IR-25's full declarative payload mapping remains excluded. Runtime Haskell declarations
can describe typed keyed function arguments and a private implementation function now;
candidate language 5 exposes the safe all-row contract and scaffolds an application
hook for keyed definitions without attempting to derive arbitrary query payloads.

Relevant local decisions are ADR-16, ADR-26, ADR-28, ADR-32, and ADR-34. The external
read contract introduced here receives its own ADR during implementation.


### Contract model

The exact constructors may be refined, but the runtime contract must retain these facts:

```haskell
newtype ExternalReadContractId = ExternalReadContractId Text
newtype ExternalReadContractVersion = ExternalReadContractVersion Int

data ExternalReadContract
  = AllRowsExternalRead
      { contractId :: ExternalReadContractId
      , contractVersion :: ExternalReadContractVersion
      , queryModelName :: Text
      , resultContractType :: QualifiedType
      , resultShapeHash :: Text
      , compatibleRevisions :: NonEmpty ProjectionRevisionId
      , surfaceGeneration :: Int
      }
  | KeyedExternalRead
      { contractId :: ExternalReadContractId
      , contractVersion :: ExternalReadContractVersion
      , queryModelName :: Text
      , arguments :: [SqlFunctionArgument]
      , resultContractType :: QualifiedType
      , privateImplementation :: QualifiedFunction
      , resultShapeHash :: Text
      , compatibleRevisions :: NonEmpty ProjectionRevisionId
      , surfaceGeneration :: Int
      }
```

Contract identity, version, shape, compatible revisions, argument types, result type,
private implementation identity, and surface generation participate in the owning group
slice and catalog fingerprint. Function bodies remain opaque but their stable declared
identity/version does not.

The application owns the keyed inner implementation. It is provisioned with the
projection revision and accepts the declared arguments. Keiro owns the externally named
outer wrapper. The wrapper performs the guard, then forwards arguments positionally to
the fully qualified inner implementation and returns its contract type. The external
role cannot execute the inner implementation or read its underlying relation.

For all-row mode Keiro owns both guard and query wrapper, returning the complete rows of
a private managed binding view. Documentation limits this mode to bounded/small models
and explains that caller-side `WHERE` does not reduce work inside the function.


### Managed object metadata and reconciliation

A private `keiro.keiro_external_read_contracts` table records contract identity/version,
query binding, group, result shape, compatible revisions, externally visible function
name/signature, definition hash, surface generation, state (`candidate`, `active`,
`retired`), and timestamps. A separate managed-object table records each guard, binding
view, wrapper, and contract type with its owner and definition hash.

Registration performs object-level reconciliation in a transaction:

- create a missing object;
- use `CREATE OR REPLACE` only where PostgreSQL permits an identical public signature;
- refuse same identity/version with a different immutable signature or lower surface
  generation;
- update a definition only when the declaration's generation is greater and dependency
  checks prove replacement safe;
- mark absent contracts pending retirement rather than dropping them;
- never mutate consumer-owned objects.

Explicit retirement previews dependencies and grants, then retires or drops only the
named managed contract. A rolling pod that declares an older surface cannot reactivate,
replace, or drop a newer definition.

Plan 256 promotion calls the same reconciliation library inside its transaction. For a
compatible contract, its private binding and implementation are repointed to the new
serving generation and its compatible revision remains active. For a new breaking
contract, v2 becomes active at promotion. A v1 contract becomes `KR003` incompatible
unless the catalog declares and provisions a v1 compatibility implementation over the
new revision. It never continues reading the frozen retired table as if current.


### Error contract

The stable guard uses these SQLSTATEs and includes group, contract, requested version,
and serving revision in structured message/detail fields without data payloads:

```text
KR001  projection temporarily unavailable; retry according to service policy
KR002  external read contract unknown, inactive, or retired; deployment/configuration error
KR003  external read contract incompatible with serving revision or shape; consumer migration required
```

Unknown lifecycle values do not need special handling: `reads_allowed = false` is the
fail-safe persisted default for an unsupported transition. Missing group/contract rows
produce `KR002`, never an empty result.


## Plan of Work

### Milestone 1 — Declare and validate versioned external contracts

Extend `keiro/src/Keiro/Projection/Catalog.hs` with the contract model and validation.
Diagnostics must cover duplicate IDs/versions/function names, query binding absence,
shape mismatch, unknown compatible revision, a revision not owning the observed target,
unsafe SQL identifiers/types, keyed implementation collision, decreasing surface
generation, and the same version with different immutable signature.

Extend canonical preimages and apply ADR-32 prefix rules. Reordering a set of compatible
revisions is identity-neutral; changing membership, result shape, signature, or
implementation version changes only the owning group slice and catalog.

Tests prove that external contract names do not become database roles, that query-model
version is not silently reused as projection revision, and that breaking shape changes
require a new contract version.

### Milestone 2 — Install the guard and managed function surface

Add the next free native migration for private contract/object metadata and any fixed
guard-support function that belongs in migration-owned schema. Update manifest, native
lock, schema snapshot, fixture counts, and changelog. Generated application-specific
objects remain registration-reconciled because their declarations vary per catalog.

Implement a stable security-definer guard in `keiro_read` that locks the group row
`FOR SHARE`, loads the exact contract version, and raises `KR001`, `KR002`, or `KR003`.
It consumes persisted `reads_allowed` and compatible serving-revision/shape metadata;
it does not contain lifecycle-state allow-lists.

Implement individual managed-object reconciliation and explicit retirement. Revoke
`PUBLIC` execution from every function. Do not issue `GRANT SELECT` on binding views or
target generations. Document deployment-owned `GRANT EXECUTE` statements per public
wrapper.

Database tests on a second connection must prove:

- offline rebuild returns `KR001`, never empty/partial rows;
- online candidate replay continues returning the complete old serving result;
- a reader holding the group shared lock completes before cutover; a reader arriving
  after cutover waits and then sees only the promoted result;
- unknown/retired contracts return `KR002`;
- incompatible revision/shape returns `KR003`;
- a role with only documented grants cannot select the target or private binding view;
- an injection-shaped identifier cannot alter generated SQL;
- security-definer `search_path`, owner, and `PUBLIC` revoke are correct;
- registering an older surface cannot overwrite or drop a newer definition;
- consumer-owned dependent functions survive unrelated reconciliation.

### Milestone 3 — Add the candidate language-5 and scaffold surface

Add a language-5 `external-read` clause for the bounded all-row form. It includes a
stable contract name/version and the compatible projection revision; result shape comes
from the checked query binding. Extend parser, pretty-printer, checker, lowering,
generated catalog output, diff, fixtures, and golden corpus. Diff reports distinguish
contract retirement, version addition, compatibility-set change, and result-shape
change.

For keyed access, generate a clearly named application-owned hole or helper module that
constructs the runtime `KeyedExternalRead` declaration and private implementation. Do
not add incomplete payload mapping syntax under language 5. Document that a future
IR-25 language can generate these declarations without changing the runtime contract.

Update ADR-16 for the new source-provenance facts and prove pretty-print round trips plus
fingerprint determinism.

### Milestone 4 — Integrate cutover, document, and verify

Wire plan 256's promote transaction to the object-level reconciliation operation. Test
both an additive compatible schema change, where v1 continues against the new
generation, and a breaking schema change, where v2 activates and v1 returns `KR003`
unless an explicit compatibility inner function is present.

Document the raw-table hazard, least-privilege grants, error handling, all-row
performance limit, keyed wrapper pattern, rolling surface generations, contract
versioning, and retirement. Update
`mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections` and
`mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs` through their
repository workflow and notify `mori://tan/notification-render-service`. The latter is
the intended handle for `runtime-patterns/keiro/projection-catalogs.md`; the file exists
in the registered project, but that document handle currently awaits a registry refresh.

Create the external-read-contract ADR with the next allocated ID; reconcile ADR-16,
ADR-26, ADR-32, and ADR-34. Update all relevant changelogs. Capture a real TypeScript or
`psql` transcript showing success during candidate replay, atomic v2 cutover, and the
documented incompatible-v1 failure. Run strict ADR validation and `just verify`.


## Concrete Steps

All local commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
cabal test keiro-test --test-option=--match --test-option="external read contracts"
cabal test keiro-migrations-test
cabal test keiro-dsl:tests
cabal test jitsurei-test
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

Use explicit role setup in the database-backed security test. Record the role's grants
and the denied raw-table/view queries alongside the successful wrapper execution.


## Validation and Acceptance

The IR-22 fence is accepted only when a separate connection with no target-table
privilege observes:

1. `KR001` during an offline rebuild instead of empty or historical rows.
2. Complete old-generation results throughout online candidate replay.
3. A wait, never mixed data, during the bounded promotion transaction.
4. Complete new-generation results after compatible promotion.
5. `KR003` for a breaking old contract and success through the new contract version.
6. `KR002` after explicit contract retirement.

The keyed acceptance query must use a selective argument and prove the inner query plan
uses the target's index; an outer predicate over the all-row wrapper is not accepted as
an efficient substitute. Security tests prove the caller cannot bypass the wrapper.


## Idempotence and Recovery

Catalog registration is repeatable for identical definition hashes. A failed
reconciliation transaction leaves the previous functions, views, metadata, and grants
intact. Same-version drift and lower-generation registration are refusals, not automatic
replacement. Stale contracts remain pending retirement until an explicit dependency
preview succeeds.

If promotion fails, all managed-object changes roll back with generation metadata and
table swaps. Resume invokes the same reconciliation deterministically. Never recover by
dropping `keiro_read` or granting direct target access.


## Interfaces and Dependencies

Primary modules and objects are:

- `keiro/src/Keiro/Projection/Catalog.hs` for external contract declarations,
  validation, and fingerprints;
- a new `keiro/src/Keiro/ReadModel/External.hs` for guard/object reconciliation and
  retirement operations;
- private migration-owned contract and managed-object metadata in `keiro`;
- stable guard and public wrapper functions plus private binding objects in
  `keiro_read`;
- plan 254's `reads_allowed`, serving revision, and epoch fields;
- plan 256's projection revisions, physical generations, and promotion transaction;
- `keiro-dsl` parser/checker/lowering/diff/scaffold modules for candidate language 5;
- `ProjectionCatalogOperations` and `keiro-ops` for previewed contract retirement and
  inspection.

The stable SQLSTATE and public function signatures are compatibility contracts. Internal
view names, private metadata layout, and generated function bodies are not, except that
their replacement must preserve transaction and privilege safety.


## Commit and Trailer Convention

Use Conventional Commits and include:

```text
MasterPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
ExecPlan: docs/plans/255-fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface.md
Intention: intention_01kzw6dkhje7qvw6w321pwyv12
```


## Revision Note

Revised 2026-08-13 after architecture validation. The plan now enforces function-only
external access, versions reader contracts independently from physical generations,
checks revision and shape compatibility, supports efficient keyed inner implementations,
reconciles managed objects individually, and prevents rolling registrations from
downgrading the surface.

Revised 2026-08-14 after Milestone 1 implementation. The runtime contract now gives
both access modes a stable qualified result type, replaces EP-1's placeholder revision
edge with the complete validated declaration, and records the required
`catalog-v5`/`slice-v4` canonical identity cutover.

Revised 2026-08-14 after Milestone 2 implementation. Native migration 0027 now owns the
fixed guard and private registries; registration, adoption, and promotion reconcile
execute-only wrappers transactionally, and focused database evidence covers lifecycle,
security, rolling-generation, dependency, locking, and keyed-query behavior. The guard's
shared lock also makes a read-write caller transaction an explicit operational
requirement.
