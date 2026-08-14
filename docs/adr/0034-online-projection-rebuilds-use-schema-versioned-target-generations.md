---
type: Architecture Decision Record
title: Online projection rebuilds use schema-versioned target generations
description: Keiro rebuilds schema-changing projections into application-provisioned physical generations and promotes a verified generation through a bounded atomic cutover.
timestamp: 2026-08-14T02:59:54Z
docId: ADR-34
status: Accepted
date: 2026-08-13
originatingPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
---

# 34. Online projection rebuilds use schema-versioned target generations

Date: 2026-08-13

Status: Accepted


## Context

Projection rebuilds are needed both to repair data produced by defective projection
logic and to populate a read model after its schema changes. The existing offline
protocol truncates the declared application table before replay. That is safe for
Keiro-aware callers because they observe the group fence, but an independent SQL
reader can observe an empty or partially reconstructed table.

A shadow-table rebuild avoids that visibility failure, but cloning the serving table
cannot implement the principal schema-evolution use case. PostgreSQL
`CREATE TABLE ... LIKE ... INCLUDING ALL` reproduces only selected attributes of the
old relation. It does not express an intended new column layout and does not preserve
all application DDL, dependencies, privileges, or canonical object names. In
particular, copied serial defaults can retain references to an old sequence, generated
index and constraint names are not stable application migration identities, and views
remain bound to the old relation object across a rename.

Keiro cannot infer a new schema from opaque Haskell SQL closures. Conversely, leaving
the entire cutover application-owned would cause every application to reimplement the
same replay, fencing, checkpoint, deduplication, crash-recovery, and atomicity protocol.
The ownership boundary must therefore distinguish the desired application schema from
the lifecycle machinery that moves between physical instances of that schema.


## Decision

A catalog physical target has a stable logical identity and one or more durable
physical target generations. A generation records a generation identifier, the target
and projection revision it implements, a schema version and canonical shape
fingerprint, its qualified physical relation, its lifecycle state, and the rebuild run
that created, promoted, retired, or dropped it. Exactly one generation is the serving
generation for a target after promotion. Staging and retired generations are never
silently treated as serving.

Application code owns the desired DDL and supplies an idempotent, transaction-local
target provisioner for every schema-changing projection revision. The provisioner
receives Keiro-allocated, safely quoted physical names and creates the complete staging
objects required by that revision. It must not commit, open a second connection, or
mutate the serving generation. Keiro owns generation-name allocation, transaction and
lock boundaries, metadata, replay orchestration, validation, promotion, retirement,
and destructive-drop previews. A built-in clone provisioner may support exact-shape
repair, but it is a restricted convenience and is never the schema-evolution
mechanism.

A projection revision binds together the schema version, provisioner identity,
physical-target-parametric live and replay handlers, verification hooks, and any
versioned external read contracts. The catalog must contain both the serving revision
and the candidate revision while an online rebuild is active. Live writers select the
persisted serving revision while holding the ordinary group lock; if the running
binary cannot supply that revision it fails closed before executing application SQL.
The rebuild runner always applies the candidate revision to staging generations.
Promotion changes the persisted serving revision and physical generations in the same
transaction, so subsequent writers can execute only the candidate handlers.

The serving table name remains a compatibility alias for existing application SQL.
Promotion may implement that alias with a transactional rename swap, but names alone
are not lifecycle identity. Keiro persists relation identities and schema
fingerprints, re-resolves them on resume, and refuses a run if a name now denotes a
different object. Before promotion Keiro acquires all serving and staging table locks
in deterministic order under one bounded deadline, revalidates the complete schema
and dependency contract, and then swaps the whole rebuild group atomically. Replay,
verification, and deduplication preparation occur before those table locks whenever
correctness permits, keeping the final reader wait short.

Schema eligibility is explicit. The built-in clone provisioner accepts only ordinary,
permanent, non-partitioned heap tables whose DDL features it can reproduce and verify.
It refuses external dependencies, foreign keys, triggers, rules, row-level security,
publication membership, non-default privileges or ownership, external `nextval`
defaults such as serial sequences, unsupported replica identity, and other unmodelled
properties. An application provisioner may create richer structures, but promotion
still requires a declared validation contract and must account for dependent objects
and canonical constraint, index, and sequence identities. An unrecognised property is
a refusal, not an implicit promise that cloning preserved it.

Rebuild lifecycle and serving availability are orthogonal facts. A group may be
`rebuilding-versioned` while its previous generation remains readable and writable.
Public status reports the serving generation's applied position separately from the
candidate rebuild position and head. It never represents staging replay progress as
the serving position and never uses checkpoint regression as a generation-change
signal. Consumers use a monotonically changing serving-generation epoch for cache
invalidation. ADR 0035 freezes those facts in
`keiro_read.projection_group_status_v1`; `reads_allowed`, rather than lifecycle phase,
is its read-safety authority.

External SQL contracts are versioned independently from physical generations. A
compatible contract can be repointed to a promoted generation atomically. A breaking
schema change receives a new read-contract version; retaining the old physical table
does not imply that it remains current after promotion. Applications either provide a
compatibility implementation over the new generation or migrate consumers before
retiring the old contract. Keiro does not claim that one unversioned table name can
serve mutually incompatible consumer schemas.

The source history required by an active rebuild is protected for the run. Hard
deletion or truncation of events at or below the captured head must be refused or
serialized against active rebuilds. Deduplication evidence used at cutover is derived
under that retention guarantee or persisted as replay proceeds; the protocol never
assumes without enforcement that old history is immutable.


## Consequences

- Schema-changing rebuilds are the primary online-rebuild path. Same-schema repair is
  the clone provisioner's smaller special case.
- Catalog and rebuild fingerprints include projection-revision, provisioner,
  schema-version, and expected-shape identities. Changing any of them requires an
  explicit candidate generation rather than silent catalog adoption.
- A schema-changing deployment carries both serving and candidate projection
  revisions until promotion and drain are complete. Old application instances fail
  closed if they cannot execute the persisted serving revision.
- PostgreSQL object identity, DDL dependencies, and application migration names are
  validated explicitly. A successful replay alone is insufficient promotion evidence.
- Readers continue to observe the old serving generation during catch-up and may wait
  only during the bounded final cutover. They never observe a partially replayed
  staging generation through a sanctioned contract.
- Retired generations remain explicit forensic and drain artifacts, not automatic
  rollback targets. Dropping them is a separate previewed destructive operation and is
  refused while an active run, supported read contract, or database dependency still
  references them. The final drop rechecks relation identity and blockers under an
  exclusive lock and never uses `CASCADE`.
- Breaking external-reader migrations require contract versioning or an
  application-provided compatibility layer; physical retention by itself is not a
  dual-write guarantee.
- Online rebuild status retains serving revision, epoch, and progress beside the
  separate active candidate fields; promotion clears the candidate fields atomically.


## Alternatives considered

Automatically clone every live table with `LIKE INCLUDING ALL`. Rejected as the
general mechanism because it cannot create a new schema and does not preserve all DDL
semantics or migration identities.

Make every application own the complete online-rebuild protocol. Rejected because it
duplicates the correctness-critical replay, fencing, checkpoint, deduplication, and
crash-recovery machinery that Keiro already owns.

Resolve a mutable table pointer before every existing SQL statement. Rejected because
application and generated SQL currently embed qualified names and Keiro cannot rewrite
opaque closures. A stable serving alias plus physical-target-parametric revision SQL
keeps the boundary explicit.

Treat a retained retired generation as a live compatibility version indefinitely.
Rejected because it stops receiving events after promotion unless an explicit
dual-write protocol exists; presenting it as current would silently serve stale data.


## References

- [ADR 0026](0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
  defines the catalog identities extended here with projection revisions and physical
  target generations.
- [ADR 0028](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  requires provisioning and cutover commands to wrap supported library operations and
  preserve application schema ownership.
- [ADR 0031](0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md)
  defines the checkpoint and deduplication invariants promotion must preserve.
- [ADR 0032](0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md)
  defines the catalog, group-slice, and in-flight replay identity boundaries extended
  by revision and generation identity.
- [MasterPlan 41](../masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md)
  coordinates the status, external read, online rebuild, and targeted-repair work.
- [ADR 0035](0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md)
  freezes the owner-rights SQL status vocabulary built on this lifecycle.
- [ADR 0036](0036-external-readers-use-versioned-guarded-sql-contracts.md)
  defines the guarded reader lock and promotion-time contract reconciliation.
