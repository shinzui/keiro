---
title: "Typed projection catalogs and coordinated rebuilds"
type: Capability
description: "Declare a pure typed inventory of query models, physical targets, atomic rebuild groups, projection owners, and missing-checkpoint policy, then rebuild a whole group atomically behind one writer fence."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-11T20:10:15Z"
capabilityId: CAP-6
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: unreleased
packages:
  - keiro
  - keiro-dsl
interface:
  - Keiro.Projection.Catalog
  - Keiro.Dsl.Grammar
requires:
  - CAP-5
evidence:
  - kind: test
    resource: keiro/test/CatalogSpec.hs
    proves: "Catalog validation accumulates stable multi-site diagnostics, carries explicit missing-checkpoint policy into inventory and registration, fingerprints policy changes, and rejects future-only initialization for replayable clear-before-replay targets."
  - kind: test
    resource: keiro/test/GroupRebuildSpec.hs
    proves: "'beginGroupRebuild' uses Kiroku's public transaction API to reset every persisted subscription member, reports exact keys, and rolls back the fence, target clear, dedup deletion, and matched resets when a declared name is missing."
  - kind: test
    resource: keiro/test/ProjectionReplaySpec.hs
    proves: "The catalog history runner captures an immutable Kiroku head, k-way merges category history in global order, resumes only an exact replay contract, and promotes only after complete source exhaustion and catalog verification."
  - kind: module
    resource: keiro/src/Keiro/Projection/Catalog.hs
    proves: "The pure catalog type projects missing-checkpoint policy into registration and inventory with stable rendering, ordering, and fingerprint input beside independent target-reset and replay policies."
  - kind: test
    resource: keiro-dsl/test/Main.hs
    proves: "Candidate Language 5 separates owner delivery from query freshness, derives cursor authority from target ownership, requires one closed checkpoint-on-missing policy per subscription owner, rejects invalid waits or replay-unsafe placement, and classifies delivery and freshness changes independently."
  - kind: test
    resource: keiro-dsl/test/conformance-projection-catalog/Main.hs
    proves: "The generated candidate-Language-5 catalog compiles and exposes FromCurrentHead unchanged through runtime inventory; companion conformance catalogs compile FromBeginning and FailIfMissing."
---

# Typed projection catalogs and coordinated rebuilds

The projection catalog is a pure, typed inventory that separates four identities
a single read model previously conflated: the *query model* a consumer reads,
the *physical target* table it lives in, the *atomic rebuild group* that must be
promoted as one unit, and the *ordered owner* that writes it. Registration
persists group fingerprints and query bindings. `beginGroupRebuild` fences an
entire group atomically — clearing every declared clear-before-replay table with
one foreign-key-compatible `TRUNCATE`, preserving reconcile targets, and deriving
async dedup/checkpoint resets from the catalog — and the catalog history runner
rebuilds by k-way merging category history in global order, resuming an exact
`keiro/projection-replay/v3` contract and promoting only after complete source
exhaustion and verification.

Each async declaration makes absent-row behavior explicit as `FromBeginning`,
`FromCurrentHead`, or `FailIfMissing`. Existing durable member rows always take
precedence. The policy is catalog identity and operator-visible inventory, and
validation refuses `FromCurrentHead` when a replayable owner clears its target
before replay. Coordinated rebuilds call Kiroku's public reset transaction,
return the exact member keys moved, and condemn the whole preparation when any
declared subscription has no persisted member.

Candidate Language 5 requires the same choice as `checkpoint-on-missing =
from-beginning`, `from-current-head`, or `fail` on every subscription owner and
forbids it on inline owners. Generated catalogs lower the choice directly to
Kiroku. Structural diff reports a policy change as a breaking generated-catalog
change with stop-the-world coordination while explicitly preserving the
persisted subscription/member identity and every existing checkpoint row.

The same source puts `delivery = inline | subscription` only on the projection
owner and `freshness = immediate | wait-for-head ...` only on each query model.
Immediate queries require no cursor and may explicitly tolerate subscription
lag. Head waits derive one compatible durable cursor from the validated owner;
inline owners, unreachable scopes, ambiguity, and mixed all-stream/category
groups fail before generated code can initialize a runtime catalog.

This is recorded as its own capability rather than an advance of
[CAP-5](read-models-and-projections.md)'s `since`, because it arrived in a later
development cycle and is proven by different evidence. A consumer pinning a
released keiro does not have it; the single-read-model rebuild remains the only
released rebuild path, and legacy read-model/projection values are carried into
the catalog only through explicit unmanaged compatibility wrappers.

## Shape

```haskell
import Keiro.Projection.Catalog

-- declare query models, targets, and rebuild groups, then:
runCommandWithCatalogProjections catalog …
beginGroupRebuild catalog groupName …   -- fence and rebuild the whole group
```

## Limits

- **This capability is unreleased** — it exists only on the default branch and
  is in no published release. Its `since` is `unreleased` for exactly that
  reason; do not depend on it from a Hackage pin.
- The [read-model and projection guide](../user/read-models-and-projections.md)
  covers hand-written adoption, missing-checkpoint policy, coordinated rebuild,
  and staged migration. The durable migration it needs (native migration 0023)
  ships with it.
- The catalog runner's target writes are committed by consumer-owned SQL at the
  physical-target boundary; the catalog validates structure and ordering but does
  not check the SQL a consumer supplies for a target.
