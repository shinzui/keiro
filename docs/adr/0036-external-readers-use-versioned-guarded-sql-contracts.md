---
type: Architecture Decision Record
title: External readers use versioned guarded SQL contracts
description: Out-of-process readers receive execute-only access to versioned security-definer functions that lock and validate serving compatibility before reading projection data.
timestamp: 2026-08-14T05:30:59Z
docId: ADR-36
status: Accepted
date: 2026-08-13
originatingPlan: docs/plans/255-fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface.md
---

# 36. External readers use versioned guarded SQL contracts

Date: 2026-08-13

Status: Accepted


## Context

Keiro's Haskell query path and projection writers participate in the rebuild-group
fence, but an independent PostgreSQL client does not. Granting that client direct
`SELECT` on an application projection table lets it observe an offline rebuild after
truncate, a partially replayed target, or a retained generation that stopped receiving
writes. Polling `keiro_read.projection_group_status_v1` before a separate raw-table
query does not close the race between authorization and cutover.

Schema-versioned online rebuilds preserve the old serving generation during candidate
replay, but promotion may replace its physical relation and row shape. PostgreSQL views
and SQL functions bind relation objects and result types, so a mutable name does not by
itself provide a stable consumer ABI. A retained old table is also not a compatibility
surface: it becomes stale as soon as the new revision accepts writes.

External reads must be narrow enough for least-privilege grants, stable enough for
rolling deployments, and transactionally coupled to the lifecycle authority used by
promotion. Keiro cannot become a general query language or infer efficient predicates
from opaque application SQL.


## Decision

Every sanctioned external projection read is a versioned catalog contract. Its stable
contract identity and positive version produce one public function name in
`keiro_read`. The declaration owns a query-model binding, a stable schema-qualified
composite result type, the result-shape fingerprint, compatible projection revisions,
and a monotonic surface generation. A keyed contract additionally owns typed arguments
and the identity and version of an application-provided private implementation.

Keiro creates an execute-only, security-definer outer function. It uses a fixed
`pg_catalog` search path, calls the shared guard, and only then reads its private
binding or invokes the private keyed implementation. The guard locks the rebuild-group
row `FOR SHARE`, checks persisted `reads_allowed`, contract state, serving revision, and
serving/result shape while holding that lock, and returns data in the same transaction.
Versioned promotion takes the conflicting lifecycle lock before swapping objects and
metadata. A reader therefore completes entirely against the old serving generation or
waits for promotion. Because PostgreSQL fixes the calling statement snapshot before the
function takes its lock, the guard compares the pre-lock and locked serving epochs. If
promotion committed while the statement waited, the guard returns retryable `KR001`;
the caller's next statement validates and reads the new generation. It never authorizes
against one epoch and reads another half-promoted or stale-snapshot generation.

The guard reports stable SQLSTATE `KR001` for temporary unavailability or a statement
snapshot that crossed promotion, `KR002` for an unknown or retired contract, and `KR003`
for a serving revision or result-shape incompatibility. An all-row wrapper reports
`KR004` when the private binding contains more than 100 rows. Messages and detail remain
diagnostic rather than machine contracts.
Because PostgreSQL prohibits `FOR SHARE` in a read-only transaction, external calls use
an ordinary read-write transaction even though the wrapper returns rows only. The lock
is not weakened to accommodate a read-only connection mode.

The result composite type is the public row ABI and is application-owned. Keiro verifies
that it exists and is composite. An all-row private binding projects exactly the
composite type's ordered attribute names rather than `SELECT *`, so additive physical
columns do not widen an existing contract. An incompatible public shape creates a new
result type and contract version.

The built-in all-row wrapper is limited to at most 100 rows. It selects at most 101 rows
and raises `KR004` before returning any result when that boundary is exceeded. Its
procedural set-returning boundary prevents an outer predicate from being pushed into
the table. High-cardinality reads use an
application-owned keyed function whose declared argument signature Keiro verifies.
Keiro also verifies that the function returns a set of the declared composite result
type, wraps it with the same guard and typed forwarding, revokes `PUBLIC` from the
private implementation, and never grants consumers access to it.

Contract reconciliation is transactional with catalog registration, reviewed adoption,
versioned-rebuild start, and promotion. A contract whose compatible revision is not
serving is persisted as candidate metadata without creating or replacing its managed
surface. Versioned-rebuild start activates the old serving contract while candidate
replay begins. Promotion atomically rebinds compatible contracts and installs a new
breaking version. An incompatible old wrapper remains present but fails `KR003`; it can
remain current only through an explicit implementation-backed compatibility contract
that reads the new serving data. A zero-argument private implementation is permitted
specifically to retain an existing all-row public signature across such a bridge.

Keiro reconciles managed objects individually. Immutable signature and definition
hashes prevent one contract version from changing identity, and a lower surface
generation cannot overwrite a higher generation in a rolling deployment. Keiro does
not drop and recreate the public schema. Explicit retirement first reports PostgreSQL
dependents and execute grants, then marks the selected contract and managed objects
retired; retirement does not implicitly drop a physical generation or use `CASCADE`.

Deployments own roles and grants. The external role receives only `USAGE` on
`keiro_read` and the application contract-type schema, `USAGE` on its result composite
type, and `EXECUTE` on the selected public wrapper. It receives no access to `keiro`,
`kiroku`, the projection schema, the private implementation schema, the shared guard,
or generated private bindings.


## Consequences

- An external reader cannot bypass lifecycle and compatibility checks with its granted
  projection-data privilege.
- Offline fences fail reads with `KR001`; online candidate replay keeps the old serving
  contract usable without exposing staging progress.
- Promotion and external-surface rebinding share one transaction and lock order.
- A reader whose statement snapshot crosses a committed serving epoch receives
  retryable `KR001`; it never returns stale or empty data under the new authority.
- All-row calls return at most 100 rows or fail atomically with `KR004`.
- Additive physical columns can preserve an old row ABI, while breaking changes require
  a new contract version or an explicit compatibility implementation.
- External client pools must permit read-write transactions for sanctioned reads.
- All-row functions are intentionally unsuitable for unbounded filtered access; keyed
  application SQL owns query planning and indexes.
- Rolling processes cannot silently downgrade or redefine a published surface.
- Retirement and retained-generation destruction remain separate, previewed operations.


## Alternatives considered

Grant direct `SELECT` on the projection table and require clients to poll status first.
Rejected because the two statements race and a retained relation can be stale while
still readable.

Publish a guarded view. Rejected because ordinary view selection cannot take and retain
the lifecycle row lock across authorization and target access in the required way, and
granting its underlying binding would bypass the guard.

Expose one unversioned function and permit additive result columns. Rejected because
SQL decoders, composite types, and positional consumers do not share a universally safe
additive rule, and one signature cannot represent mutually incompatible rows.

Keep the retired physical table serving v1 after promotion. Rejected because it no
longer receives ordinary writes and would silently return historical data.

Generate arbitrary keyed SQL from the catalog. Rejected because Keiro does not own an
application query DSL. The application owns the efficient inner query; Keiro owns the
guarded privilege boundary.

Drop and recreate `keiro_read` on every registration. Rejected because it destroys
grants and consumer-owned dependents and lets rolling processes replace one another's
objects.


## References

- [ADR 0026](0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
  defines the catalog ownership relation extended with external read contracts.
- [ADR 0028](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  defines the supported inspection, preview, and force boundary used for retirement.
- [ADR 0032](0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md)
  defines the canonical catalog and group-slice identity that includes the complete
  external contract declaration.
- [ADR 0034](0034-online-projection-rebuilds-use-schema-versioned-target-generations.md)
  defines the serving/candidate promotion transaction and retained-generation meaning.
- [ADR 0035](0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md)
  defines the observability relation that is not itself an authorization protocol.
- [ExecPlan 255](../plans/255-fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface.md)
  records implementation evidence and the Jitsurei cutover proof.
