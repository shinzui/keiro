---
type: Architecture Decision Record
title: PGMQ provisioning preserves upstream SQL and bounds local retention validation
description: Keiro preserves PGMQ-owned provisioning and validates only the partition-retention mistakes it can identify without duplicating PostgreSQL or pg_partman semantics.
timestamp: 2026-09-16T16:54:58Z
docId: ADR-45
status: Accepted
date: 2026-09-16
originatingPlan: docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md
---

# PGMQ provisioning preserves upstream SQL and bounds local retention validation

## Context

PGMQ partitioned queues delegate partition creation and retention maintenance to
`pg_partman`. The released PGMQ 1.13 contract configures both active and archive
parents with automatic maintenance and `retention_keep_table = false`. Retention
therefore drops whole eligible partitions; it is not a per-row expiry check and
does not preserve an unprocessed active message merely because no consumer has
acknowledged it. A sufficiently long outage or backlog can delete work before it
ever reaches Keiro's dead-letter path.

PGMQ classifies a partition interval as message-id based by casting its text to a
PostgreSQL signed 32-bit `INTEGER`; values that do not cast select time-based
partitioning. Reimplementing PostgreSQL's interval parser in Keiro would create a
second, drifting authority, but accepting every string makes common numeric
configuration mistakes invisible until provisioning reaches the database.

PGMQ's conventional FIFO helper creates a GIN index on `headers` and reports it
by its conventional name. The grouped reads instead group and compare a
coalesced header expression and order by `msg_id`. That mismatch alone does not
prove that another index improves the complete read, polling, leasing, or write
workload. The measurement and optional operator-procedure boundary belongs to
`mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`.

## Decision

Keiro keeps `PartitionSpec`'s raw constructor for advanced server-specific
values and adds `mkPartitionSpec` as the preferred bounded preflight. The smart
constructor trims and rejects empty values. Fully numeric values use message-id
units: the partition span must be positive and fit PostgreSQL's positive signed
32-bit integer range, retention must be positive, and retention must cover at
least one configured partition span. Exactly one numeric value is rejected as a
unit mismatch. Two nonnumeric values remain opaque for PostgreSQL and
`pg_partman` to validate.

This constructor is a configuration guardrail, not a retention proof. Operators
must size retention above their worst-case consumer outage and backlog age with
an explicit safety margin. Public documentation must state that maintenance can
drop unprocessed active rows and archived audit rows by whole partition.

Keiro continues to request PGMQ's conventional GIN through supported
`pgmq-config` APIs. Name-based presence means only that the conventional object
exists; it does not prove query-plan use or acceleration. Keiro does not replace
the GIN, override PGMQ functions, install a supplemental expression index during
startup, or expose private-schema DDL through `keiro-ops`.

No supplemental FIFO index is recommended until the owning pgmq-hs work records
reproducible full-workload evidence, including all grouped-read strategies,
visible and invisible polling states, insert and lease churn, storage, locks,
and partition lifecycle. If such an index is later accepted, it remains
separately named operator-owned state with an owning-project procedure.

## Consequences

Most applications can reject obvious partition mistakes before database access,
while unusual time syntax can still use the raw constructor or pass through the
smart constructor as an opaque nonnumeric pair. Keiro deliberately does not
claim that syntactic acceptance means a server will accept the values or that a
retention horizon prevents data loss.

Ordered queue reconciliation remains compatible with upstream PGMQ and retains
its existing presence-reporting behavior. Applications receive no unmeasured
performance promise, and later pgmq-hs evidence can add narrowly scoped operator
guidance without changing Keiro startup or historical migration bytes.

## References

- [ExecPlan 118](../plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md)
  — implementation, validation, and upstream-evidence audit.
- [ADR 28](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  — supported library APIs and private-schema ownership.
- `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`
  — measurement and optional supplemental-index procedure ownership.
