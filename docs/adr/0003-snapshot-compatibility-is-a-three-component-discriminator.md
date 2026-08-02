---
type: Architecture Decision Record
title: Snapshot compatibility is a three-component discriminator
description: Snapshot compatibility is gated on state codec version, register-layout hash, and control-state/replay-fold hash together.
timestamp: 2026-08-01T19:21:22Z
docId: ADR-3
status: Accepted
date: 2026-07-23
---

# 3. Snapshot compatibility is a three-component discriminator

Date: 2026-07-23

Status: Accepted


## Context

Keiro snapshots are advisory cached seeds: hydration may use one only when it
was encoded under assumptions compatible with the current event-stream fold.
Before this decision, compatibility checked `stateCodecVersion` and
`shapeHash`. `defaultStateCodec` derived the latter from the register file, so
register-layout changes missed safely, but control-state changes and fold-logic
changes could still accept a stale seed.

That gap is correctness-relevant. Keiki uses one transducer for forward
execution and replay, and Keiro replays only the log tail after a snapshot.
When an update or guard changes, a seed produced by the old fold can cause the
new runtime to derive a state that a full replay would never reach.


## Decision

Snapshot compatibility has three independently meaningful components:

1. `stateCodecVersion`, manually owned by the service;
2. `shapeHash`, the register-layout identity;
3. `stateShapeHash`, the control-state and replay-fold identity.

All three participate in lookup and write compatibility. Migration
`0019-keiro-snapshots-state-shape-hash.sql` adds the third database column with
an empty default. No real derived hash is empty, so every pre-migration row
misses once, full-replays, and may then be replaced with a current seed.

Keiki's `CanonicalStateShape` derives the control-state portion from datatype
and constructor structure. `defaultStateCodec` uses it automatically. The DSL
also derives a thirty-two-lowercase-hex-digit FNV-1a-128 fingerprint from the
spec-visible replay surface: state order and terminality, register types and
initials, transition mode/guards/writes/emits/targets, and transitively
referenced rule bodies. The FNV constants and UTF-8 octet fold follow
[RFC 9923](https://www.rfc-editor.org/rfc/rfc9923.html), with multiplication
reduced modulo 2^128.

The exact pre-hash bytes belong to a dedicated frozen canonical encoder, not
the presentation pretty printer. Changing those bytes or the digest algorithm
is an explicit snapshot-identity migration that must update the complete fold
surface goldens, generated fingerprints, and compatibility documentation
together. The 2026-08-02 FNV-1a-64 to FNV-1a-128 migration intentionally made
all earlier aggregate snapshots miss once before the coordinated `0.9.0.0`
release; no production snapshots existed at that boundary. Read-model shape,
mapped-wire, and behavior-key identities remain on their separately frozen
64-bit contracts.

Generated codecs compose it with `withFoldFingerprint` in the human-readable
form:

```text
<state-hash>;fold=<fingerprint>
```

The manual clause remains load-bearing. Language-version-2 Hole-owned
transitions expose a required, hand-owned `FoldVersion` beside each stable Hole
function. Generated transducer assembly length-prefixes those tokens into the
aggregate fold fingerprint, so changing a Hole predicate or update requires a
token bump and invalidates old snapshots. Changing the Hole while retaining the
token is a contract violation.

Behavior outside that version-2 boundary remains manual. A version-1
whole-transducer Hole or another hand-written update/guard must bump
`stateCodecVersion`. Hand-written services should instead use
`defaultStateCodecWithFold` with an explicit `FoldVersion`; that first-class
helper composes the token through `withFoldFingerprint` while making ownership
and the bump obligation visible at the codec call site.

`verifyAndSnapshot` keeps its existing behavior. After append, it applies the
new events to the state hydration accepted and may persist that result. This is
sound once loading is gated by the complete discriminator: an accepted seed is
already compatible with the current codec and visible fold. A separate
seed-provenance flag would not detect the residual manual-contract violation,
because an unbumped invisible fold change presents equal discriminators by
construction.

Language version 3's enforced ID admission is also part of the visible runtime
fold/codec contract. Moving from legacy/version-2 unchecked generated IDs to
`keiro-dsl/id-domain/typeid-v7/1` changes the runtime-semantics discriminator,
so old snapshots miss rather than decoding legacy-invalid ID text through the
new public instance. Full replay remains possible because generated historical
event codecs alone retain the explicit internal legacy constructor. A replayed
state that still contains legacy-invalid text is not promoted into an accepted
current snapshot: a cache containing it will miss again until later history
overwrites the value or an explicit domain migration changes the state.


## Consequences

- Register-layout and control-state shape changes invalidate snapshots
  automatically under `defaultStateCodec`.
- DSL-visible fold evolution invalidates snapshots automatically and also
  produces an `AggFoldSurfaceChanged` advisory at diff time.
- Version-2 Hole behavior contributes its explicit per-transition
  `FoldVersion`; bumping it invalidates snapshots even though arbitrary
  hand-written terms are not inspectable by `diff`.
- Upgrading a migrated database incurs a one-time full replay per stream whose
  old snapshot is encountered; persisted events remain the source of truth.
- Adopting the language-3 ID domain invalidates old snapshots automatically.
  Streams whose reconstructed state is currently admissible repopulate the
  cache; streams still carrying legacy-invalid IDs intentionally remain
  uncacheable and pay full replay without losing event readability.
- Invisible hand-written fold changes remain an explicit operational contract:
  bump the stream's `FoldVersion` through `defaultStateCodecWithFold`, or
  manually bump `stateCodecVersion` when using the lower-level codec API.
- Fingerprint collisions retain the old stale-seed failure mode, but the
  fold-only FNV-1a-128 value is acceptable here as a deterministic change
  detector rather than a security boundary. It is not used for authentication
  or adversarial-input integrity.

## Related decisions

- [ADR 0018](0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
  defines the capability metadata and canonical encoder that supply this
  discriminator.
