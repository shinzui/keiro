---
title: "Typed projection catalogs and coordinated rebuilds"
type: Capability
description: "Declare a typed projection inventory, adopt its persisted identity, replay groups resumably, cut schema-versioned target generations over online, and repair one bounded stream behind the same writer fence."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
capabilityId: CAP-6
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.12.0.0"
packages:
  - keiro
  - keiro-dsl
interface:
  - Keiro.Projection.Catalog
  - Keiro.Projection.Catalog.Operations
  - Keiro.Projection.Catalog.Preimage
  - Keiro.ReadModel.Rebuild
  - Keiro.Dsl.Grammar
requires:
  - CAP-5
evidence:
  - kind: test
    resource: keiro/test/CatalogSpec.hs
    proves: "Catalog validation accumulates stable multi-site diagnostics, carries explicit missing-checkpoint policy into inventory and registration, fingerprints policy changes, and rejects future-only initialization for replayable clear-before-replay targets."
  - kind: test
    resource: keiro/test/GroupRebuildSpec.hs
    proves: "'beginGroupRebuild' uses the event store's public transaction API to reset every persisted subscription member, reports exact keys, and rolls back the fence, target clear, dedup deletion, and matched resets when a declared name is missing."
  - kind: test
    resource: keiro/test/ProjectionReplaySpec.hs
    proves: "The catalog history runner captures an immutable head, k-way merges category history in global order, resumes only an exact v4 replay contract, and promotes only after complete source exhaustion and catalog verification."
  - kind: test
    resource: keiro/test/CatalogEvolutionSpec.hs
    proves: "Catalog changes are previewed and adopted transactionally by canonical group slice, including query-registration reconciliation and safe recovery from pre-canonical stored identity."
  - kind: test
    resource: keiro/test/VersionedRebuildSpec.hs
    proves: "Schema-versioned generations preserve live service during replay, hold a renewable history lease, converge and promote atomically under bounded locks, retire safely, and provide rollback-safe targeted stream reprojection."
  - kind: test
    resource: keiro/test/VersionedTargetPostgresSpec.hs
    proves: "PostgreSQL candidate provisioning, restricted cloning, relation-identity checks, deterministic lock order, and timed-out cutover all fail without exposing a partial generation."
  - kind: module
    resource: keiro/src/Keiro/Projection/Catalog.hs
    proves: "The pure catalog type projects missing-checkpoint policy into registration and inventory with stable rendering, ordering, and fingerprint input beside independent target-reset and replay policies."
  - kind: test
    resource: keiro-dsl/test/Main.hs
    proves: "Stable Language 5 separates owner delivery from query freshness, derives cursor authority from target ownership, requires checkpoint policy, generates revisions and external contracts, and classifies catalog, mapped-consumer, and cutover impact."
  - kind: test
    resource: keiro-dsl/test/conformance-projection-catalog/Main.hs
    proves: "The generated stable-Language-5 catalog compiles and exposes FromCurrentHead unchanged through runtime inventory; companion conformance catalogs compile FromBeginning and FailIfMissing."
---

# Typed projection catalogs and coordinated rebuilds

The projection catalog is a pure, typed inventory that separates identities a
single read model previously conflated: the *query model* a consumer reads, the
*physical target* table it observes, the *atomic rebuild group* promoted as one
unit, the *ordered owner* that writes it, and the schema-versioned *revision*
whose handlers are currently serving. Registration persists canonical group
slice fingerprints and query bindings. A changed live slice must be previewed
and adopted transactionally; startup never silently overwrites stored identity.

`beginGroupRebuild` fences an entire group atomically, clearing every declared
clear-before-replay table with one foreign-key-compatible `TRUNCATE`, preserving
reconcile targets, and deriving subscription dedup/checkpoint resets from the
catalog. The history runner captures one immutable head, pages and k-way merges
all declared sources in global position order, persists adapter progress, and
resumes only the exact `keiro/projection-replay/v4` contract. Verification and
complete source exhaustion are prerequisites for atomic promotion.

Each async declaration makes absent-row behavior explicit as `FromBeginning`,
`FromCurrentHead`, or `FailIfMissing`. Existing durable member rows always take
precedence. The policy is catalog identity and operator-visible inventory, and
validation refuses `FromCurrentHead` when a replayable owner clears its target
before replay. Coordinated rebuilds call
[Kiroku's](mori://shinzui/kiroku) public reset transaction,
return the exact member keys moved, and condemn the whole preparation when any
declared subscription has no persisted member.

Stable Language 5 requires the same choice as `checkpoint-on-missing =
from-beginning`, `from-current-head`, or `fail` on every subscription owner and
forbids it on inline owners. Generated catalogs lower the choice directly to
[Kiroku](mori://shinzui/kiroku). Structural diff reports a policy change as a
breaking generated-catalog change with stop-the-world coordination while
explicitly preserving the persisted subscription/member identity and every
existing checkpoint row.

The same catalog puts `delivery = inline | subscription` only on the projection
owner and `freshness = immediate | wait-for-head ...` only on each query model.
Immediate queries require no cursor and may explicitly tolerate subscription
lag. Head waits derive one compatible durable cursor from the validated owner;
inline owners, unreachable scopes, ambiguity, and mixed all-stream/category
groups fail before generated code can initialize a runtime catalog.

Schema-versioned revisions add an online path for incompatible target changes.
The runtime provisions and validates candidate generations while the old
revision remains readable and writable, protects the required history with a
renewable retention lease, replays and catches up the candidate, then promotes
every group target under one bounded lock phase. Retired generations remain
inspectable; dependency-aware cleanup refuses active runs, external-read
contracts, and ordinary PostgreSQL dependents.

For data repair rather than schema evolution, a targeted stream reprojection
locks one stream, admits it only under an explicit event bound, takes the group
writer fence for one transaction, replaces that stream's contribution against
the exact serving revision, verifies it, and backfills redelivery evidence
without moving the subscription checkpoint.

This capability shipped in 0.12.0.0, later than
[CAP-5](read-models-and-projections.md), and is proven by separate catalog and
lifecycle suites. Legacy read-model/projection values remain available only as
explicit unmanaged compatibility wrappers.

## Shape

```haskell
import Keiro.Projection.Catalog

-- declare query models, targets, and rebuild groups, then:
runCommandWithCatalogProjections catalog …
beginGroupRebuild catalog groupName …     -- stop-the-world group rebuild
startVersionedGroupRebuild catalog …      -- keep the serving revision online
reprojectCatalogStream catalog …          -- bounded one-stream repair
```

## Limits

- The [read-model and projection guide](../user/read-models-and-projections.md)
  covers hand-written adoption, catalog evolution, checkpoint policy,
  coordinated and online rebuilds, targeted repair, and staged migration. The
  required native migrations ship in the lockstep 0.12 package set.
- The catalog runner's target writes are committed by consumer-owned SQL at the
  physical-target boundary; the catalog validates structure and ordering but does
  not check the SQL a consumer supplies for a target.
- Targeted reprojection applies only to projections whose rows are scoped to one
  stream and whose locked history fits the reviewed event limit. Cross-stream
  aggregates and schema changes require a full group rebuild.
- Online cutover keeps service available but does not make replay free: the
  candidate still reads retained history, writes a second target generation,
  and must converge within the configured operational budgets.
