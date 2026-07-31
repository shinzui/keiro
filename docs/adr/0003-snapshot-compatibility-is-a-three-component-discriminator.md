---
type: Architecture Decision Record
title: Snapshot compatibility is a three-component discriminator
description: Snapshot compatibility is gated on state codec version, register-layout hash, and control-state/replay-fold hash together.
timestamp: 2026-07-28T17:26:13Z
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
also derives a sixteen-hex-digit FNV-1a fingerprint from the spec-visible replay
surface: state order and terminality, register types and initials, transition
mode/guards/writes/emits/targets, and transitively referenced rule bodies.
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
- Invisible hand-written fold changes remain an explicit operational contract:
  bump the stream's `FoldVersion` through `defaultStateCodecWithFold`, or
  manually bump `stateCodecVersion` when using the lower-level codec API.
- Fingerprint collisions retain the old stale-seed failure mode, but FNV-1a-64
  is acceptable here as a deterministic change detector rather than a security
  boundary.
