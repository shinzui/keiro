---
type: Improvement Request
title: Let declared transitions construct mapped register values
description: >-
  Give a declared transition target-typed initial and mapped-lift register expressions without
  taking the whole edge into an implementation hole, so that a mapped-value construction can be
  one side of a guarded pair without weakening guard, replay, or ownership guarantees.
timestamp: 2026-09-11T14:30:01Z
requestId: IR-34
status: accepted
origin: mori://shinzui/rei
plan: docs/plans/267-add-safe-mapped-register-construction-to-declared-transitions.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-22T04:09:38Z
    document_timestamp: 2026-08-21T00:00:00Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against Keiro's published Language 5 grammar, aggregate expression resolver,
      generated/Hole ownership validation, scaffolder, fold fingerprint, diff/replay surfaces,
      and compiled structural conformance; ADRs 3, 4, 12, and 17; the released Keiki 0.9.1.0
      Term, Update, and EdgeBuilder APIs; and Rei's pre- and post-conversion Intention root,
      event-stream construction, legacy state fold, projection feed, and application reader.
---

# Improvement Request: Let Declared Transitions Construct Mapped Register Values

## Status

**Validated, justified, and accepted; planned as
[Plan 267](../plans/267-add-safe-mapped-register-construction-to-declared-transitions.md), not
yet implemented.** Raised from
`mori://shinzui/rei/plans/206-author-the-rei-service-workspace-at-keiro-dsl-language-5`,
Milestone 7, after reproducing the problem with the published `keiro-dsl` 0.13.0.0 binary while
declaring Rei's Intention root aggregate.

The review reproduced the same failures with the current published `keiro-dsl` 0.14.0.0 binary
and traced the generated path through the checker and scaffolder. This is not a runtime or Keiki
defect, and it is not an operator error in Rei. It is a missing expression capability in
`mori://shinzui/keiro/packages/keiro-dsl`.

The original wording was too broad. Keiro already lets a generated transition copy a whole mapped
value from a same-typed command field into a mapped register. The unsupported operation is
*constructing* such a value -- specifically, selecting the target declaration's initial value or
applying a declared lift such as `UTCTime -> Maybe UTCTime`. The accepted scope below is that
narrower capability.

Rei worked around it, so this is not blocking: the register the workaround dropped turned out to
be write-only, and dropping it changed no event, guard, output, or stored byte. The request is
filed because the next aggregate to hit this may have a register something actually reads, and
then there is no workaround at all.

## Context

Three rules compose into a gap that has no escape hatch.

1. **A generated write can copy but cannot construct a mapped value.** Existing conformance
   already lowers `write currentArtifact := cmd.artifact` and other same-mapped-type copies. For a
   `Maybe UTCTime` register, however, the two writes an aggregate needs are `Nothing` and
   `Just cmd.markedAt`, and both are constructions rather than whole-value copies.
   `write since := initial` is not accepted either: `initial` resolves as a guard atom and fails
   with `GuardAtomOutOfScope`, then again as a scalar root with
   `AggregateExpressionRootUnknown`.

2. **A hole may not declare a guard.** Adding `guard reg.isDormant == true` to a transition that
   selects `implementation hole` fails with:

   ```text
   error[AggregateTransitionOwnershipConflict]: transition 'Active -- ApplyActionRecorded'
     selects implementation hole and therefore cannot also declare guard or write clauses
   ```

3. **Two edges out of one vertex for one command must both be guarded.** Leaving the hole
   unguarded beside a guarded sibling fails with `TransitionUnguardedSibling`; making both sides
   holes fails with `TransitionDuplicateUnguarded`.

Together these say: **an edge that must construct a mapped register value can never be one side of
a guarded pair, in either direction.** A hole cannot carry the guard the pair needs, and a
declared edge cannot express the constructed write.

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

## Package Fit

This belongs in `mori://shinzui/keiro/packages/keiro-dsl`. The package already owns the aggregate
grammar, target-typed expression resolution, generated/Hole ownership, Keiki term rendering,
consumer import planning, fold fingerprints, semantic diff and replay impact, and generated
behavior conformance. Neither `keiro-core` nor `keiro` should learn source-language mapped
constructors.

No new primitive is required from `mori://shinzui/keiki/packages/keiki`. Published Keiki 0.9.1.0
already has constant terms for mapped values, opaque unary `TApp1` terms, typed single-slot
`Update`s, and forward/replay evaluation of update right-hand sides. The current Keiro dependency
range already admits that release. The work is to expose a checked Keiro DSL surface and preserve
its provenance, not to weaken or bypass Keiki validation.

Language 5 is now a stable published source contract in keiro-dsl 0.14.0.0. This capability must
therefore be registered under a successor language version; it must not silently change the
meaning of `initial` or another atom in Languages 1-5.

## Safe Implementation Boundary

The smallest safe implementation keeps the transition generated-owned and extends only the
generated write expression language.

1. **Add a target-contextual initial expression.** In a write right-hand side only,
   `write dormantSince := initial` resolves through the target register's already checked
   `RegInitial`. For a mapped target it must use the declaration's qualified `initial` symbol and
   lower to a generated constant term; it must not parse or evaluate a source string at runtime.

2. **Add a declared, versioned mapped lift.** A form such as
   `write dormantSince := mapped(cmd.markedAt)` may resolve only when the target mapped declaration
   provides one unambiguous, typed, pure `Time -> MaybeTime` lift. Exact surface syntax is a design
   choice, but the declaration must carry the qualified symbol, a behavior version, and finite
   conformance cases. The generated update may lower the lift through Keiki's `TApp1`; update
   terms do not participate in guard disjointness, and replay recomputes them from the recovered
   command.

3. **Keep command recovery mandatory.** A lift may read only command fields that remain
   structurally recoverable from the emitted history. Keiki's hidden-input and replay checks stay
   enabled. Moving a value into an update does not make an otherwise hidden command input safe.

4. **Make behavior provenance complete.** The canonical expression, mapped declaration, lift
   symbol and version, and target register must enter fold identity, diff, replay impact, scaffold
   history, import/package planning, and behavior ownership. Changing a lift implementation
   without changing its version is a contract violation. A changed version is replay-affecting,
   invalidates snapshots, and requires the ordinary targeted replay audit before deployment.

5. **Retain generated guard and write authority.** The generated transducer must still emit the
   declared guard and the `B.slot` assignment itself. Sibling coverage, Keiki predicate
   verification, event kinds, target, and live/replay mode continue to describe the machine that
   executes.

A narrowly hand-owned fallback is acceptable only if the declarative mapped-lift inventory is not
worth the permanent syntax. Such a hook must return the right-hand-side `Term` for one named,
declared write. Generated code must own the `B.slot` assignment, and the hook's type must make it
impossible to add a guard, write another register, emit an event, or choose a target. It also needs
an explicit `FoldVersion` and honest hand-owned-write reporting, like the existing event-value
hook boundary.

**Do not implement this by letting a normal Hole declare a guard.** A Hole currently receives an
`EdgeBuilder`, so it can conjoin another predicate and perform arbitrary updates. Generating the
source guard before that action would not make the source guard authoritative: the Hole could
silently narrow it, invalidate claimed sibling coverage, or change writes outside automatic diff
and fold identity. Relaxing `AggregateTransitionOwnershipConflict` that way would contradict
`mori://shinzui/keiro/okf/adrs/concepts/ADR-17`, which deliberately makes generated and Hole
guard/write ownership exclusive.

## Rei Usage Audit

Rei used Keiro correctly.

- The pre-conversion Intention transducer contains six syntactic `dormantSince` update sites and
  no `B.reg @"dormantSince"` read. Expanded helpers apply those updates to the expected lifecycle
  edges, but no predicate or event output consumes the register.
- The Intention `EventStream` used `stateCodec = Nothing` and `snapshotPolicy = Never`; Rei has no
  snapshot table. The register was not serialized as a cache seed.
- The legacy application state sets and clears `IntentionExistsData.dormantSince` from
  `IntentionMarkedDormant` and awakening/reopen events. The recent-activity check reads that
  application state, not the Keiki register.
- The `intentions.dormant_since` projection is likewise populated from
  `IntentionMarkedDormant.markedAt` and cleared by the stored awakening/reopen events.
- The historical event exposes `markedAt :: Time`, not a whole `MaybeTime`. Changing the stream
  command to carry an extra `MaybeTime` merely to satisfy a whole-value copy would either create a
  hidden command input or require a wire-shape change. Rei did not overlook a safe existing write
  form.

The generated diagram comparison therefore has the right evidentiary meaning: command matching,
guards, event vectors, outputs, and targets remain the same, while only the unobserved
`dormantSince` update disappears. A product-state rewrite could encode dormancy without the
register, but forcing every orthogonal mapped value into the control vertex is not an operator fix
for a missing register-expression capability.

## Acceptance

1. Languages 1-5 retain their exact parse, validation, pretty-print, canonical, and generated
   bytes; a successor language owns the new expression surface.
2. Existing same-typed whole mapped-value copies remain generated-owned and unchanged.
3. A guarded sibling fixture can set a mapped register to its declaration's initial value, passes
   `check`, scaffolds, compiles, and constructs an event stream under default validation.
4. A second fixture applies a declared `Time -> MaybeTime` lift to a recoverable command field and
   writes the exact expected `Just timestamp` value.
5. The generated transducer, not a Hole, emits the declared guard and named slot assignment; a
   mutation that adds mixed `implementation hole` ownership still fails with
   `AggregateTransitionOwnershipConflict`.
6. Keiki continues to prove the complementary `Bool` sibling guards disjoint. The mapped update
   neither enters nor obscures predicate verification.
7. Forward execution, encoded-event replay, and full replay agree on the vertex and every
   register for initial, set, dormant auto-wake, awake, reopen, and standalone-awaken paths.
8. A lift from an input field that is not recoverable from emitted history fails the existing
   hidden-input/replay gate; the new form cannot launder hidden command state into a register.
9. Initial-symbol, lift-symbol, lift-version, source-type, or target-type changes are visible in
   canonical encoding, fold identity, semantic diff, replay impact, scaffold history, dependency
   planning, and generated conformance.
10. If a term-valued hook is chosen instead of a declared lift, compile-time negative fixtures
    prove that it cannot change a guard, another register, an event vector, or a target. Its
    declared `FoldVersion` must enter the generated fold identity, and changing that version must
    change the identity; changing the hook body without changing its version remains an explicit
    contract violation.

## What Rei did instead

Dropped the register. `dormantSince` was written six times by the transducer and read nowhere --
no guard, no output, no snapshot (`stateCodec = Nothing` on every Rei stream, and no snapshot
table exists), and no consumer. Three other copies of the same fact survive and are all fed from
the stored event, so the aggregate now declares with zero `implementation hole`s and the generated
diagram differs from the hand-written transducer only by the removed `dormantSince := ...` update.

That worked because the register happened to be unobservable. A register that something folds
would have left the aggregate undeclarable.
