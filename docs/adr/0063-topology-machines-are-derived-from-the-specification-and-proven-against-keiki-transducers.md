---
type: Architecture Decision Record
title: Topology machines are derived from the specification and proven against keiki transducers
description: The aggregate state machine in the service topology is computed by keiro-dsl from the checked specification, using the same edge-index rule as the transducer builder, and a conformance suite proves it equal to the compiled keiki transducers.
timestamp: 2026-11-17T19:30:00Z
docId: ADR-63
status: Accepted
date: 2026-11-17
originatingPlan: docs/plans/340-export-aggregate-machines-in-keiki-vocabulary-and-verify-them-against-generated-transducers.md
---

# Topology machines are derived from the specification and proven against keiki transducers

## Context

Every Keiro aggregate, including a process manager's saga, is a keiki transducer. The service
topology (ADR-62) should show each aggregate's machine in keiki's vocabulary: states, the
initial and terminal states, and every edge with its index, `Live` or `ReplayOnly` mode
([ADR-2](0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)), command
and events. keiki 0.9 has no structured graph export, and its machines exist only in the
generated Haskell a service compiles. Producing the machine by compiling and running service
code would make a committed export need a service build. That conflicts with an export whose
freshness follows from source digests. The user chose the alternative on 2026-11-17.

## Decision

`keiro-dsl` computes `details.machine` for every aggregate node from the checked
specification alone. The keiki edge index of a transition is its position among the
transitions with the same source state, in declaration order. That rule lives in one function,
`transitionLayout` in `keiro-dsl/src/Keiro/Dsl/AggregateGenerationPlan.hs`. The generated
transducer builder, `behaviorEdgeIndex` and the topology export all call it, so the exported
index and the generated `edgesOut` order cannot drift apart.

The conformance suite `keiro-dsl-conformance-topology-machine` compiles a scaffolded corpus.
It walks the real transducers with keiki's own accessors (`edgesOut`, `target`, `mode`,
`initial`, `isFinal`, `edgeInputName` and each output's wire-constructor name) and fails
unless the result equals the exported `machine` object. It also asserts that its fixture
still covers several edges per state, non-adjacent same-source transitions, a replay-only
edge, a two-event edge, a hole-owned body and a process saga. The suite compares against
keiki's accessors, not its Mermaid or inspector text, which are readability contracts.

Each machine states its `ownership`. `generated` machines, including transitions with a
hand-written `implementation hole` body (whose edges are still generated), are covered by
the proof. A `legacy-hole` machine from the frozen Language 1 form
([ADR-17](0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md))
lists the declared transitions, and the export says it is not proven.

## Consequences

- A change to how scaffold orders or groups transitions must keep `transitionLayout` as the
  single source of the edge index, or the conformance suite fails.
- The edge index is local to a source state and changes when transitions are reordered.
  Documentation tells consumers not to store it as a durable identifier.
- Guards, register writes and output field terms are not exported. The machine is structure,
  not behavior.
- New generated corpora used as proofs must be registered in
  `keiro-dsl/test/conformance-baseline.json`, and their git-ignored scaffold ledgers must be
  force-added so the corpus driver can discover them.
- The proof lives in one shared test module, `keiro-dsl/test/topology-machine-proof`, and
  runs against `topology-machine.keiro` (conformance-topology-machine) and the existing
  corpora conformance-history-dependent-holes, conformance-process-full,
  conformance-process-reactions and conformance-structural. Each run must account for
  every aggregate whose exported ownership is `generated`, either by comparing it or by
  naming it as excluded with a reason.
