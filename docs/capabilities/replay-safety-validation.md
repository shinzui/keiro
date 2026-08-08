---
title: "Replay-safety validation boundary (ValidatedEventStream)"
type: Capability
description: "Reject unrecoverable, ambiguous, or state-losing transducers at a typed boundary before they are ever allowed to run commands."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-2
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro-core
  - keiro
interface:
  - Keiro.EventStream
  - Keiro.EventStream.Validate
  - Keiro.ReplayAudit
requires:
  - CAP-1
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'EventStream replay-safety (validateEventStream)', 'mkEventStream', and 'Keiro.ReplayAudit' describe blocks assert that inversion-ambiguous, state-losing, and unrecoverable transducers are rejected or warned before construction succeeds."
  - kind: test
    resource: keiro/test/ReplaySafetyTypeProbe.hs
    proves: "A type-level probe that the replay-safety boundary is enforced at compile time for the categories it can prove statically."
  - kind: guide
    resource: docs/user/replay-safety.md
    proves: "What replay-safety means, which transducer shapes are rejected, and why the boundary exists."
---

# Replay-safety validation boundary (ValidatedEventStream)

Before a keiki `SymTransducer` may drive commands, it must pass through
`mkEventStream` / `validateEventStream` to become a `ValidatedEventStream`. The
validator rejects transducers whose folds are not total, whose event inversion
is ambiguous (two events could have produced the same state transition), or
whose replay would lose state — the failure modes that make an event log
un-replayable after the fact. `Keiro.ReplayAudit` extends this to hand-written
services: it takes a conservative affected-event set and reports which stored
history a change puts at replay risk.

This is a distinct adoption decision from the codec layer it builds on
([CAP-1](typed-event-model.md)): a consumer chooses to wrap a transducer in the
validated boundary, and the migration path has its own guide.

## Shape

```haskell
import Keiro.EventStream

case mkEventStream orderTransducer of
  Left warnings -> …  -- refuse to run: the transducer is not replay-safe
  Right ves     -> runCommand ves …
```

## Limits

- Validation is conservative: it can return an inversion-ambiguity warning for a
  transducer that is in fact safe, and the exact warning set depends on the
  bundled keiki version (it changed at `keiro-core` 0.11.0.0 when keiki 0.9
  proved more candidates disjoint — see the changelog). Treat warnings as a
  prompt to review, not a proof of a bug.
- `Keiro.ReplayAudit` for hand-written services requires the author to supply a
  correct conservative `AffectedSet`; unlike the `.keiro` toolchain it cannot
  derive the affected set from a spec diff (see
  CAP-14). An understated affected set understates
  replay risk.
