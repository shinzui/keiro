---
title: "Advisory aggregate snapshots"
type: Capability
description: "Speed up stream hydration with periodic snapshots that stay strictly advisory — a corrupt or stale snapshot is discarded and replay from events remains the source of truth."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-4
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro
  - keiro-core
interface:
  - Keiro.Snapshot
  - Keiro.Snapshot.Codec
  - Keiro.Snapshot.Policy
requires:
  - CAP-3
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Snapshot' describe block asserts that a snapshot accelerates hydration when valid and is discarded — falling back to full replay — when its codec, policy discriminator, or version does not match."
  - kind: guide
    resource: docs/user/snapshots.md
    proves: "When to enable snapshots, how the policy controls cadence, and why they never become load-bearing."
  - kind: example
    resource: jitsurei/src/Jitsurei/Snapshots.hs
    proves: "A runnable service configuring a snapshot policy over an aggregate."
---

# Advisory aggregate snapshots

Snapshots are an optimization for streams with long histories: the runtime
periodically records the folded state so a later load can resume from the
snapshot and replay only the tail. The guarantee is that snapshots are
*advisory* — a snapshot that fails to decode, carries a mismatched policy
discriminator, or predates the current version is silently discarded and the
stream is rehydrated by replaying its events ([CAP-3](transactional-command-cycle.md)).
A snapshot can never be the reason a load produces wrong state.

## Shape

```haskell
import Keiro.Snapshot
import Keiro.Snapshot.Policy

snapshotEvery 100  -- take a snapshot every 100 events; correctness never depends on it
```

## Limits

- Snapshots are a latency optimization only; they change no result and can be
  disabled with no correctness effect. Do not use them to store state that is
  not derivable from the event history.
- A snapshot codec change invalidates existing snapshots (they are discarded and
  rebuilt from events), so a deploy that changes snapshot shape pays a one-time
  full-replay cost on first load of each stream.
