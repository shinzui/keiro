---
title: "Schema-aware operational console"
type: Capability
description: "Inspect and repair a Keiro deployment through a standalone or application-embedded command tree with schema checks, stable JSON, and preview-before-force mutations."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
capabilityId: CAP-16
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.12.0.0"
packages:
  - keiro-ops
interface:
  - Keiro.Ops
  - Keiro.Ops.Embed
  - Keiro.Ops.Env
requires:
  - CAP-13
evidence:
  - kind: test
    resource: keiro-ops/test/Main.hs
    proves: "The complete command tree, standalone-versus-embedded boundary, schema-drift refusal, stable human/JSON rendering, preview/force discipline, and every operational command domain are exercised against migrated PostgreSQL stores."
  - kind: guide
    resource: docs/user/operations.md
    proves: "How to install the console, select a database, mount application-owned hooks, inspect state, and execute each repair workflow safely."
  - kind: module
    resource: keiro-ops/src/Keiro/Ops.hs
    proves: "The public command tree and AppHooks boundary shared by the standalone executable and application-embedded consoles."
---

# Schema-aware operational console

`keiro-ops` is the supported operator surface for a Keiro deployment. The
standalone executable exposes operations whose complete contract is available
from the database. An application can embed the same command tree and mount
typed hooks for code-dependent work: workflow resume, timer dispatch, replay
audit, and projection-catalog operations.

The console uses the schema installed by
[CAP-13](database-migrations.md) as its compatibility handshake. Every
invocation checks that live schema before opening its command environment.
Read-only commands warn on drift; mutations fail closed unless the
operator explicitly allows drift. Destructive or state-changing commands return
an exact preview and a reproducible `--force` invocation, while `--json` exposes
the same typed result as a stable automation envelope.

The command domains cover streams and causation, durable subscription
positions, snapshots and truncation preflight, inbox/outbox recovery, PGMQ dead
letters, projection deduplication and rebuilds, shard ownership, timers,
workflow lifecycle and garbage collection, and candidate-code replay audits.
This is independently adoptable from the runtime APIs: an operator can install
the package as a deploy/runbook tool, and an application can reuse its parser
and dispatcher without shelling out.

## Shape

```bash
keiro-ops --database-url "$DATABASE_URL" stream show order-42 --json
keiro-ops --database-url "$DATABASE_URL" timer stuck list --min-age 5m
```

```haskell
import Keiro.Ops qualified as Ops

main = Ops.mainWithHooks applicationHooks
```

## Limits

- The standalone executable deliberately omits commands that require the
  candidate application's workflow registry, timer handler, replay codecs, or
  validated projection catalog. Those commands exist only when the application
  mounts the corresponding `AppHooks` value.
- `--force` confirms an already-rendered operation; it does not bypass typed
  lifecycle checks, ownership checks, admission limits, or database locks.
- The console performs bounded administrative actions. It does not supervise
  continuous projection, timer, outbox, workflow, or queue workers.
