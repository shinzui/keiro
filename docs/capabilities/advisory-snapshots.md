---
title: "Advisory aggregate and process-manager snapshots"
type: Capability
description: "Speed up aggregate and process-manager stream hydration with periodic snapshots that stay strictly advisory — a corrupt or stale snapshot falls back to replay from events."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
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
    proves: "The 'Keiro.Snapshot' and 'Keiro.ProcessManager snapshots' blocks assert that compatible aggregate and manager snapshots accelerate hydration, while decode or compatibility failure falls back to full replay."
  - kind: guide
    resource: docs/user/snapshots.md
    proves: "When to enable snapshots, how the policy controls cadence, and why they never become load-bearing."
  - kind: example
    resource: jitsurei/src/Jitsurei/Snapshots.hs
    proves: "A runnable service configuring a snapshot policy over an aggregate."
---

# Advisory aggregate and process-manager snapshots

Snapshots are an optimization for aggregate and process-manager state streams
with long histories: the runtime
periodically records the folded state so a later load can resume from the
snapshot and replay only the tail. The guarantee is that snapshots are
*advisory* — a snapshot that fails to decode or does not match the current state
codec version, register-file shape hash, and control-state/fold hash is discarded
and the stream is rehydrated by replaying its events
([CAP-3](transactional-command-cycle.md)).
A snapshot can never be the reason a load produces wrong state.

A process manager configures the same `snapshotPolicy` and `stateCodec` on its
own event stream; no separate snapshot mechanism or table is involved.

## Shape

```haskell
import Keiro.Snapshot
import Keiro.EventStream (SnapshotPolicy (..))

eventStreamDef =
  baseEventStream
    { snapshotPolicy = Every 100
    , stateCodec = Just stateCodec
    }
```

## Limits

- Snapshots are a latency optimization only; they change no result and can be
  disabled with no correctness effect. Do not use them to store state that is
  not derivable from the event history.
- Changing any compatibility discriminator invalidates existing snapshots, so
  the next load of each stream pays a full replay before a new snapshot is
  written. A policy change by itself changes cadence, not compatibility.
