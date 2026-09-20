---
type: Navigation
title: Keiro Guides
description: Route readers through Keiro tutorials, adoption guides, design explanations, and operational runbooks.
docId: DOC-1
tags: [keiro, guides, navigation]
generated:
  by: human:nadeem
  at: 2026-09-18T04:08:09Z
---

# Keiro Guides

These guides teach Keiro through `jitsurei`, a sibling Cabal package in this
repository. The package is not pseudocode: it builds as part of this workspace,
and `cabal test jitsurei-test` exercises the behavior described here.

Start with the overview, then follow the path that matches the part of Keiro you
are adopting:

- [Order Fulfillment Overview](order-fulfillment-overview.md) explains the
  example domain and where each source file lives.
- [Choosing A Primitive](choosing-a-primitive.md) is the routing map: given a
  shape ("make these cooperate"), it points you to the right primitive
  (`EventStream`, Keiki composition, projection, process manager, or router).
- [Choosing A Projection](choosing-a-projection.md) separates projection
  delivery, query freshness, catalog ownership, and hand-written versus
  generated wiring.
- [Inline Projections](inline-projections.md) shows same-transaction application
  from command paths and reactor dispatch, including replay adapters and catalog
  fence boundaries.
- [Asynchronous Projections](asynchronous-projections.md) shows subscription
  delivery, transactional deduplication, checkpoint outcomes, query freshness,
  and rebuild behavior.
- [Offline Projection Rebuilds](offline-projection-rebuilds.md) covers catalog
  preview, group fencing, target preparation, fixed-head replay, verification,
  repair/resume, atomic promotion, and the legacy single-model lifecycle.
- [Online Schema-Versioned Projection Rebuilds](online-projection-rebuilds.md)
  covers revision bridges, application-provisioned staging schemas, live catch-up,
  bounded atomic cutover, retention, failure recovery, and retired generations.
- [Build The Command Side](build-the-command-side.md) walks through commands,
  events, the Keiki transducer, the Keiro `EventStream` /
  `ValidatedEventStream` boundary, and `runCommand`.
- [Replayability Safety](../user/replay-safety.md) explains the validation
  guarantee that keeps unchecked streams out of command runners.
- [Keiro DSL Language 5 Reference](../user/typed-spec-toolchain.md) covers the
  complete stable language, the spec/check/scaffold loop, generated ownership,
  compatibility vectors, coverage reports, and historical comparison tooling.
- [Choosing `keiro-dsl`](choosing-keiro-dsl.md) compares the benefits, costs,
  escape hatches, and best-fit service shapes after the language, nominal,
  workspace, behavioral-conformance, and ID-domain repairs in MasterPlan 27,
  and what opting into candidate Language 6 means.
- [The Guarantee Ledger](dsl-guarantees-and-hand-written-services.md) explains
  which guarantees every validated service gets below the DSL, which exist only
  with a spec, and what a hand-written service must supply for itself.
- [Migrating To `ValidatedEventStream`](migrating-to-validated-event-stream.md)
  is the compiler-driven source migration for services that still build bare
  `EventStream` values at runner boundaries.
- [Brownfield Migration And Transducer Modeling](brownfield-migration-and-transducer-modeling.md)
  is for migrating an existing service onto keiro: modeling decisions as
  solver-visible scalars, lifecycle vertices, one stream per entity, authoring
  structural bindings from create-once skeletons or exact nominal derivation,
  and the goldens-first shadow-compared versioned migration path.
- [Adopting Keiro From tan-event-source](adopting-keiro-from-tan-event-source.md)
  migrates a tan-event-source service to Keiro in controlled compatibility stages.
- [Adopting keiro-dsl idiomatic-v2](adopting-keiro-dsl-idiomatic-v2.md) adopts
  the idiomatic-v2 generated Haskell surface and its compatibility gates.
- [Checked Mapping Adoption](checked-mapping-adoption.md) runs the candidate
  Language 6 checked-value example from a clean scaffold, fills total bindings,
  preserves create-once code, and stages replay-safe reader-first rollout.
- [Migrating to the keiro-dsl 0.15 record API](migrating-keiro-dsl-record-api-0.15.md)
  updates generated consumers and services for the 0.15 record API.
- [Evolve Events Safely](evolve-events-safely.md) shows the event codec and the
  version-1-to-version-2 upcaster.
- [Evolution And Replayability](evolution-and-replayability.md) walks every
  change class on a deployed service with its safe procedure and gate
  coverage, including producer message-ID, reaction-identity, delegated-intake,
  and workqueue-ordering changes.
- [Project Read Models](project-read-models.md) builds the order read side from
  one validated catalog, including managed inline/async application, a
  brownfield-safe mixed-policy rebuild, fencing, repair, and resume.
- [Process Managers And Timers](process-managers-and-timers.md) shows
  replay-safe fulfillment coordination, a due timer worker, and the candidate
  Language 6 reaction form with its identity-migration cutover.
- [Durable Workflows](durable-workflows.md) walks a named-step durable workflow
  end to end — steps, a durable sleep, an awakeable, a child workflow, the resume
  worker, and the kill-and-restart durability proof.
- [Routers And Effectful Fan-Out](routers-and-effectful-fan-out.md) routes one
  event to a read-model-resolved set of target streams, idempotently.
- [Coordinating Incident Response: Routers And Process Managers
  Together](coordinating-incident-response-with-routers-and-process-managers.md)
  pairs a router (page the on-call roster) with a process manager (escalation
  saga + timer) reacting to the same event, and explains when to reach for each.
- [Work Queues](work-queues.md) walks the shipment-notice queue: a versioned job
  payload, per-order `FifoHeads` delivery, an idempotent handler, the retry-versus-poison
  decision, and why a queue is not an outbox.
- [Snapshots And Hydration](snapshots-and-hydration.md) enables advisory
  snapshots for the order stream.
- [Run And Operate Jitsurei](run-and-operate-jitsurei.md) collects build,
  migration, catalog rebuild rehearsal, embedded operator, and
  production-readiness commands.
- [Dead Letters And Replay](../user/dead-letters.md) is the operator reference
  for rejected dispatches and subscription replay.
- [Integration Events With Kafka](integration-events-with-kafka.md) describes
  the canonical two-context Kafka topology, deterministic producer message IDs,
  the delegated inbox, the operational guarantees, and when to deviate from the
  default ordering and retention policies.

The full source is under [`../../jitsurei/`](../../jitsurei/). The executable
tests are in [`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs).
