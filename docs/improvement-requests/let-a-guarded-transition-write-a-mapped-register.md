---
type: Improvement Request
title: Let a guarded transition write a mapped register
description: >-
  Give a declared transition a way to set a mapped register without taking the whole edge into an
  implementation hole, so that an edge writing a mapped register can be one side of a guarded pair
  instead of being undeclarable.
timestamp: 2026-08-21T00:00:00Z
requestId: IR-34
status: proposed
origin: mori://shinzui/rei
---

# Improvement Request: Let a Guarded Transition Write a Mapped Register

## Status

Proposed from
`mori://shinzui/rei/plans/206-author-the-rei-service-workspace-at-keiro-dsl-language-5`,
Milestone 7, after reproducing the problem with the published `keiro-dsl` 0.13.0.0 binary while
declaring Rei's Intention root aggregate.

Rei worked around it, so this is not blocking: the register the workaround dropped turned out to
be write-only, and dropping it changed no event, guard, output, or stored byte. The request is
filed because the next aggregate to hit this may have a register something actually reads, and
then there is no workaround at all.

## Context

Three rules compose into a gap that has no escape hatch.

1. **Only a hole can write a mapped register.** A `write` clause admits a copy from a command
   field or a literal of one of the six direct scalars. A mapped register's value is neither: for
   a `Maybe UTCTime` the two writes an aggregate needs are `Nothing` and `Just cmd.markedAt`, and
   both are lifts rather than field copies. `write since := initial` is not accepted either --
   `initial` resolves as a guard atom and fails with `GuardAtomOutOfScope`, then again as a
   scalar root with `AggregateExpressionRootUnknown`.

2. **A hole may not declare a guard.** Adding `guard reg.isDormant == true` to a transition that
   selects `implementation hole` fails with:

   ```text
   error[AggregateTransitionOwnershipConflict]: transition 'Active -- ApplyActionRecorded'
     selects implementation hole and therefore cannot also declare guard or write clauses
   ```

3. **Two edges out of one vertex for one command must both be guarded.** Leaving the hole
   unguarded beside a guarded sibling fails with `TransitionUnguardedSibling`; making both sides
   holes fails with `TransitionDuplicateUnguarded`.

Together these say: **an edge that writes a mapped register can never be one side of a guarded
pair, in either direction.** A hole cannot carry the guard the pair needs, and a declared edge
cannot carry the write.

## The shape that hits it

Rei's Intention root has an atomic dormancy auto-wake. Recording an action or an outcome on a
dormant intention must emit the activity event *and* `IntentionAwakened` in the same step, and
clear the dormancy registers; on an awake intention it emits the activity event alone. That is
three pairs of edges out of one vertex, guarded on complementary equalities over a `Bool`
register -- exactly the shape `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-9` taught
keiki to prove disjoint.

The `Bool` register declares fine. The companion `dormantSince :: Maybe UTCTime` register does
not, and it is what made the aggregate undeclarable:

```text
Active -- ApplyActionRecorded -->
  guard reg.isDormant == true
  write isDormant := false
  write dormantSince := <no clause can say Nothing>
  emit ActionRecorded
  emit IntentionAwakened
  goto Active

Active -- ApplyActionRecorded -->
  guard reg.isDormant == false
  emit ActionRecorded
  goto Active
```

## What would close it

Any one of these would be enough; they are listed cheapest first.

1. **Let a hole declare a guard.** Relax `AggregateTransitionOwnershipConflict` so a transition
   may carry `guard` clauses *and* `implementation hole`, with the hole owning only the register
   updates. The guard would still lower through `renderKeikiPredicate`, so the disjointness proof
   and the sibling-coverage checks keep working on a declared predicate rather than an opaque one
   -- which is strictly better than today's alternative of pushing the guard into the hole where
   `TransitionUnguardedSibling` cannot see it.

2. **Give mapped registers a write form.** A `write since := initial` that resolves to the
   declaration's own `initial` symbol would cover every "clear it" case, which is the common one.
   A `write since := mapped(cmd.markedAt)` naming a consumer-owned lift would cover the rest.

3. **Introduce a register-only hook.** The same shape as the existing output hook (S27 in Rei's
   plan): the edge stays generated and declared, and one hand-owned function supplies the update
   for the fields the scalar language cannot express.

Option 1 looks smallest and would also relax a rule that costs elsewhere: today a transition
whose *only* unexpressible part is one register update loses its guard, its declared writes, and
its place in the sibling-coverage analysis all at once.

## What Rei did instead

Dropped the register. `dormantSince` was written six times by the transducer and read nowhere --
no guard, no output, no snapshot (`stateCodec = Nothing` on every Rei stream, and no snapshot
table exists), and no consumer. Three other copies of the same fact survive and are all fed from
the stored event, so the aggregate now declares with zero `implementation hole`s and the generated
diagram differs from the hand-written transducer only by the removed `dormantSince := ...` update.

That worked because the register happened to be unobservable. A register that something folds
would have left the aggregate undeclarable.
