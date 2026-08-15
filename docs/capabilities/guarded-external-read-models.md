---
title: "Guarded external read-model contracts"
type: Capability
description: "Publish versioned, execute-only PostgreSQL read contracts in keiro_read so out-of-process consumers stay off private projection tables and fail safely across schema-versioned cutovers."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
capabilityId: CAP-17
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.12.0.0"
packages:
  - keiro
  - keiro-migrations
  - keiro-dsl
interface:
  - Keiro.ReadModel.External
  - Keiro.ReadModel.Rebuild
  - Keiro.Projection.Catalog
requires:
  - CAP-6
  - CAP-13
evidence:
  - kind: test
    resource: keiro/test/ExternalReadSpec.hs
    proves: "Managed execute-only wrappers enforce immutable signatures, typed result shapes, object ownership, revision compatibility, bounded retry across promotion, and dependency-aware retirement without granting readers private-table access."
  - kind: test
    resource: keiro/test/VersionedRebuildSpec.hs
    proves: "External read versions remain bound to compatible serving generations during replay and switch atomically, or fail with the stable guard error, when a breaking revision is promoted."
  - kind: test
    resource: keiro-dsl/test/Main.hs
    proves: "Language 5 checks, generates, fingerprints, and classifies evolution of external-read declarations and their mapped input/result contracts."
  - kind: guide
    resource: docs/user/read-models-and-projections.md
    proves: "How owners declare, grant, deploy, observe, version, and retire external read contracts without exposing physical projection coordinates."
---

# Guarded external read-model contracts

An application can publish a read model to a separate process as a versioned
PostgreSQL function under `keiro_read`. An external role can be granted only
schema usage, result-type usage, and function execution: Keiro's private binding
views, metadata, and the application's physical target tables remain
inaccessible. The catalog pins the logical query model, argument and result
types, compatible projection revisions, result shape, and monotone surface
generation.

The typed catalog and revision lifecycle come from
[CAP-6](typed-projection-catalogs.md), and the managed SQL metadata and status
view are installed by [CAP-13](database-migrations.md).

Reconciliation validates the complete contract transactionally and refuses
unmanaged object collisions, signature reuse, surface downgrades, missing
composite result types, and incompatible private implementations. The public
wrapper guards every statement against the current serving revision and schema
shape. A promotion either leaves a compatible version readable, activates a new
version atomically, or returns a stable retryable/refusal SQL state; it never
silently serves a mismatched table.

The native migrations also publish the frozen
`keiro_read.projection_group_status_v1` owner-rights view. A separately granted
reader can use it to inspect the serving revision and epoch, read/write
availability, checkpoints, and active candidate progress without access to
Keiro's private schema. Contract retirement is explicit and dependency-aware so
an in-use function is not dropped accidentally.

## Shape

```text
external-read order_totals_reader {
  version = 1
  query = order_totals_lookup
  result-schema = "app_contract"
  result-type = "order_totals_row_v1"
  compatible-revisions = [ reporting_v1 reporting_v2 ]
  surface-generation = 1
}
```

```sql
SELECT * FROM keiro_read.order_totals_reader_v1();
```

## Limits

- The contract exposes PostgreSQL functions, not an HTTP or RPC service. The
  owning application manages database roles, connection distribution, and any
  network-facing API built on top.
- Result types and function signatures are immutable within one contract
  version. Breaking input or result changes require a new version and a
  coordinated caller migration.
- Keiro guards revision and shape identity but cannot prove the semantics of
  application-owned SQL. Private implementations and revision-aware projection
  handlers remain application code covered by its own tests.
