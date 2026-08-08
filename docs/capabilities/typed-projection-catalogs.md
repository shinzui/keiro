---
title: "Typed projection catalogs and coordinated rebuilds"
type: Capability
description: "Declare a pure typed inventory of query models, physical targets, atomic rebuild groups, and projection owners, then rebuild a whole group atomically behind one writer fence."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-6
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: unreleased
packages:
  - keiro
interface:
  - Keiro.Projection.Catalog
requires:
  - CAP-5
evidence:
  - kind: test
    resource: keiro/test/CatalogSpec.hs
    proves: "Catalog validation accumulates stable multi-site diagnostics, separates query models / physical targets / rebuild groups / owners, and produces deterministic inventory rendering and SHA-256 fingerprints."
  - kind: test
    resource: keiro/test/GroupRebuildSpec.hs
    proves: "'beginGroupRebuild' atomically fences a rebuild group, TRUNCATEs its declared clear-before-replay tables together, preserves reconcile targets, and returns typed fenced outcomes without committing append/dedup/target writes on failure."
  - kind: test
    resource: keiro/test/ProjectionReplaySpec.hs
    proves: "The catalog history runner captures an immutable Kiroku head, k-way merges category history in global order, resumes only an exact replay contract, and promotes only after complete source exhaustion and catalog verification."
  - kind: module
    resource: keiro/src/Keiro/Projection/Catalog.hs
    proves: "The pure catalog type: query models, physical targets, atomic rebuild groups, ordered owners, reset-policy-independent-from-replay-policy, and unmanaged compatibility wrappers for legacy read-model/projection values."
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
`keiro/projection-replay/v1` contract and promoting only after complete source
exhaustion and verification.

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
- Its evidence is the test suite and the module itself; there is no user guide
  for the catalog yet, so its adoption story is weaker than the released
  capabilities in this catalog. The durable migration it needs (native migration
  0023) ships with it.
- The catalog runner's target writes are committed by consumer-owned SQL at the
  physical-target boundary; the catalog validates structure and ordering but does
  not check the SQL a consumer supplies for a target.
