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

The manual clause remains load-bearing. A change outside those derived
surfaces — notably a hand-written update or guard, or logic changed only in a
generated service's hand-owned Holes module — must bump `stateCodecVersion`.
Hand-written services may instead supply and maintain their own explicit fold
token through `withFoldFingerprint`.

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
- Upgrading a migrated database incurs a one-time full replay per stream whose
  old snapshot is encountered; persisted events remain the source of truth.
- Invisible hand-written fold changes remain an explicit operational contract:
  bump `stateCodecVersion`, or supply a maintained fold fingerprint.
- Fingerprint collisions retain the old stale-seed failure mode, but FNV-1a-64
  is acceptable here as a deterministic change detector rather than a security
  boundary.
