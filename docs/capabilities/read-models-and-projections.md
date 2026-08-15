---
title: "Registered read models and fenced projections"
type: Capability
description: "Register read models, fold events into them with inline or subscription delivery, choose explicit immediate or reachable-head/position freshness, and rebuild behind an atomic writer fence."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
capabilityId: CAP-5
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro
interface:
  - Keiro.ReadModel
  - Keiro.ReadModel.Schema
  - Keiro.ReadModel.Rebuild
  - Keiro.Projection
  - Keiro.Connection
requires:
  - CAP-3
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.ReadModel', 'Keiro.Connection projection schema', and projection blocks exercise registration, inline and subscription folds, visible-head/position waits, timeouts, schema refusal, and atomically fenced rebuilds."
  - kind: test
    resource: keiro/test/ReadModelSpec.hs
    proves: "Truthful constructors separate owner delivery from query freshness and fail immediately when a waiting policy has no compatible durable cursor or concrete position."
  - kind: guide
    resource: docs/user/read-models-and-projections.md
    proves: "How to register a read model, choose inline versus async projection, and rebuild safely."
  - kind: example
    resource: jitsurei/src/Jitsurei/ReadModels.hs
    proves: "A runnable service registering read models and projecting the order domain into them."
---

# Registered read models and fenced projections

A read model is an explicitly registered query surface backed by a Postgres
table. A projection folds source events into it — *inline*, committed in
the same transaction as the command ([CAP-3](transactional-command-cycle.md)) so
the target is updated before the command returns, or *subscription-delivered*,
applied by a worker with its own durable checkpoint. Query freshness is
independent:
`Immediate` runs without polling, `WaitForHead` waits for a compatible durable
cursor to reach one captured visible head, and caller-selected `WaitForPosition`
can target the command's returned position. A rebuild replays history
into the read model behind an atomic writer fence: readers keep seeing the old
contents until the rebuild is promoted, and concurrent writers cannot interleave
into a half-rebuilt table.

## Shape

```haskell
import Keiro.ReadModel

orderSummary =
  immediateReadModel $
    ReadModelBlueprint
      { cursorAuthority = NoQueryCursor
      , ...
      }

registerReadModel
  (orderSummary ^. #name)
  (orderSummary ^. #version)
  (orderSummary ^. #shapeHash)
```

An asynchronously delivered model uses `DurableQueryCursor subscription`. It may still choose
`immediateReadModel` and explicitly tolerate lag, or use `headWaitingReadModel`
when the cursor's event source can reach the requested whole-store/category
head. Per-call read-your-write uses `runQueryWithFreshness` and
`WaitForPosition` with a concrete position.

## Limits

- Subscription projection checkpoints are at-least-once: a projection fold must be
  idempotent, because a crash between applying an event and advancing the
  checkpoint re-applies it. Exactly-once async checkpointing is explicitly *not*
  provided — see `docs/user/production-status.md`.
- The single-read-model rebuild here fences one read model at a time. Rebuilding
  a set of read models that must be promoted together as one unit is the concern
  of the [projection catalog (CAP-6)](typed-projection-catalogs.md); do not use
  the single-read-model rebuild to coordinate a multi-target cutover.
