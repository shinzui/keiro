---
type: Bug Report
title: Initial hole harness requires acceptance from empty registers despite history-backed witnesses
description: Keiro DSL generates false failing acceptance and forward/replay probes for an initial-vertex implementation hole whose valid live command requires retained history.
generated:
  by: process:codex
  at: "2026-10-13T23:30:02Z"
bugId: BUG-10
status: confirmed
severity: unusable
origin: mori://shinzui/rei/plans/272-separate-rei-command-invariants-from-asynchronous-query-projections
affects: mori://shinzui/keiro/packages/keiro-dsl
affectedVersion: "0.20.0.0"
environment: Rei revision eaa401e1e9ea21c4b7fdcfb445461b2891c5cb14, Language 6 workspace with 33 members, released DSL 0.20.0.0, GHC 9.12.4 in the Nix development shell on aarch64-darwin.
observed: The generated whole-service conformance suite fails acceptClearProperty and forwardReplayClearProperty because both step from the empty initial value map, while the live clear hole correctly requires membership and its history-backed behavior witness passes.
expected: The documented consumer-compiled harness should validate a legitimate implementation hole using its typed history-backed witness, preserving exact edge attribution and persisted-codec replay equality, without requiring every live edge at the initial vertex to accept from initial registers.
reproduction:
  - Use a clean checkout of mori://shinzui/rei at eaa401e1e9ea21c4b7fdcfb445461b2891c5cb14 with its published dependency cohort and DSL 0.20.0.0 wrapper.
  - Run `nix develop -c just keiro-gate` from the Rei root; strict checking and scaffold freshness pass, then the generated conformance leg fails the two PropertyAssignment assertions quoted below.
  - Inspect acceptClearProperty and forwardReplayClearProperty in rei-core/src/Rei/Modules/PropertyAssignment/Generated/Harness.hs; both use initialPropertyAssignmentRegs directly.
  - Compare the live Map.member guard in rei-core/src/Rei/Modules/PropertyAssignment/Holes.hs with the prior PropertySet history in rei-core/src/Rei/Modules/PropertyAssignment/BehaviorHoles.hs.
  - Run `nix develop -c env REI_API_CHECK_CORE=always just api-check` for the independent consumer guard and behavior tests with their database fixtures; the retained run passed all 3372 Core tests.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-10-13T13:28:32Z"
    document_timestamp: "2026-10-13T13:28:32Z"
    scope: technical-accuracy
    outcome: commented
    provider: OpenAI
    model: gpt-6.1-sol
    effort: unspecified
    context: Reporter checked released producer Harness.hs, consumer guard and witness code, generated BehaviorContract.hs and retained gate output. No isolated producer reproduction or repair has been run; this is not independent confirmation.
---

# Initial hole harness requires acceptance from empty registers

Rei's complete workspace gate cannot pass for a valid history-dependent live
clear. This blocks release acceptance of the consumer upgrade even though its
runtime guard and history-backed behavior tests pass. Severity describes that
unusable gate; no data loss or runtime rejection defect is observed. No sanctioned
gate workaround is known. The owner has now reproduced the defect in
`keiro-dsl-conformance-history-dependent-holes`: both initial clear rows fail
while its history-backed behavior report passes. The lifecycle is `confirmed`.

## Observed reproduction

The retained run at consumer revision
`eaa401e1e9ea21c4b7fdcfb445461b2891c5cb14` exits 1:

```text
FAIL  aggregate/PropertyAssignment/accepts ClearProperty from PropertyAssignmentActive
FAIL  aggregate/PropertyAssignment/forward/replay equality: ClearProperty from PropertyAssignmentActive -- forward step accepted
```

Both symptoms come from the same command and seed in the same reproduction.
[The evidence excerpt](evidence/BUG-10-rei-workspace-gate.txt) retains those failures,
the surrounding passing assertions, gate leg outcomes and the original log's
SHA-256. The reporter also ran the complete Core suite: 3,372 tests passed in
82.08 seconds. These results certify different surfaces; Core success does not
turn the workspace gate green.

For the shortest consumer reproduction, run this in the clean Rei checkout
identified above:

```bash
nix develop -c cabal test keiro-rei-conformance --test-show-details=direct
```

The full `nix develop -c just keiro-gate` additionally verifies checked source and
regenerated-file freshness before executing the same conformance component.

## Diagnosis and published expectation

[Choosing Keiro DSL](../guides/choosing-keiro-dsl.md) documents consumer-owned
transition holes and typed behavior witnesses, including exact runtime edge
attribution and codec/replay register equality. It requires missing, stale,
duplicate, pending and false witnesses to fail completeness.

In `keiro-dsl/src/Keiro/Dsl/Harness.hs`, `initialLiveTransitionEntries` selects
every live edge whose source is the initial vertex. `emitHarness` emits
`acceptDecl` and `forwardReplayDecl` for those entries, including implementation
holes. Both helpers unconditionally step from initial registers using synthetic
command samples. Being at the initial control vertex does not imply that the
registers still have their initial values: a self-loop may already have replayed
earlier events.

Rei's PropertyAssignment aggregate has one vertex and an initially empty value
map. Its live `ClearProperty` hole requires `Map.member propertyId values` before
deleting. The matching `LiveWitness` seeds `PropertySet` history, then clears that
same property. Its replay-only clear witness instead starts from empty history
and retains historical empty clears. The generated behavior contract correctly
settles the supplied history, checks the precise edge and emitted events,
decodes through the persisted codec, and compares forward/replayed registers.
The generic initial probes ignore this witness and fail before their own replay
comparison can run.

The generated consumer harness is unchanged from its pre-upgrade baseline except
for the 0.19.0.0-to-0.20.0.0 generator banner. This is a pre-existing limitation
exposed by the complete gate, not an established regression introduced in 0.20.
No `lastWorkingVersion` is claimed.

The completed
[IR-18](../improvement-requests/handle-initial-state-replay-only-transitions-in-generated-harnesses.md)
addresses mode filtering and shared transition layout. It does not address a
live initial-vertex hole that requires nonempty register history. This report
does not reopen or duplicate that repair.

All consumer source paths in this report belong to `mori://shinzui/rei`:
`rei-core/src/Rei/Modules/PropertyAssignment/{Holes.hs,BehaviorHoles.hs,Generated/Harness.hs,Generated/BehaviorContract.hs}`
and `domain/rei.keiro-workspace`. Source-file artifact URIs are pending. The
consumer diagnosis is in that project at
`docs/reviews/2026-10-13-keiro-initial-hole-harness-gap.md` (review artifact URI
pending).

## Investigation and repair acceptance

A candidate repair could use the existing history-backed behavior contract for
hole-owned initial edges instead of inventing unconditional empty-state
acceptance. The implementation choice is open to the owner. It must retain
meaningful ordinary generated-edge probes and must not silently omit a hole's
acceptance or replay obligations.

1. Add a compiled producer fixture with an initial-state self-loop, empty map,
   set and guarded clear holes, and a replay-only historical empty-clear edge.
   Before repair, the generic clear probes fail despite a valid live witness.
2. After repair, set-history followed by clear passes both aggregate and generated
   whole-service conformance, with exact live edge attribution, emitted event
   decoding, forward/replay final vertex and every register compared.
3. Live clear from empty state still refuses. A replay-only empty clear still
   replays and cannot be selected by forward stepping.
4. Removing, duplicating, leaving pending, using a stale key, using a wrong edge,
   supplying inadequate history or lying about emissions must produce named
   conformance failures. A live obligation cannot be satisfied by its replay-only
   sibling.
5. Single-spec and workspace generation compile, and a second scaffold is byte
   stable. After adopting a released repair in Rei, its full workspace gate passes.

Do not seed production initial registers, remove the membership guard, change
replay semantics or event wire shapes, hand-edit generated consumer files, or
suppress these failures as acceptance. This report authorizes investigation only;
no producer implementation, version bump or release was performed.

## Tracking

Tracked by [plan 309](../plans/309-prove-hole-owned-initial-edges-through-history-backed-witnesses-in-generated-harnesses-to-fix-bug-10.md). On 2026-10-13 the owning repository validated the
diagnosis from `keiro-dsl/src/Keiro/Dsl/Harness.hs` (`initialLiveTransitionEntries`
filters on mode only; `acceptDecl` and `forwardReplayDecl` step from initial registers
with a synthetic command regardless of `HoleImplementation`) and reproduced the
generated probe shape by scaffolding a minimal hole-owned initial self-loop with the
0.20.0.0 generator. The generated whole-service conformance package composes only
`harnessAssertions`, so the consumer's behavior witnesses never run in that gate. The
lifecycle remains `reported` until the plan's compiled fixture executes the failing rows
in this repository; the plan then records `confirmed`, and `fixed` after the full gate.
