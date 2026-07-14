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
- [Build The Command Side](build-the-command-side.md) walks through commands,
  events, the Keiki transducer, the Keiro `EventStream` /
  `ValidatedEventStream` boundary, and `runCommand`.
- [Replayability Safety](../user/replay-safety.md) explains the validation
  guarantee that keeps unchecked streams out of command runners.
- [Typed Specifications With `keiro-dsl`](../user/typed-spec-toolchain.md)
  covers the spec/check/scaffold/diff loop for generated service surfaces.
- [Migrating To `ValidatedEventStream`](migrating-to-validated-event-stream.md)
  is the compiler-driven source migration for services that still build bare
  `EventStream` values at runner boundaries.
- [Evolve Events Safely](evolve-events-safely.md) shows the event codec and the
  version-1-to-version-2 upcaster.
- [Project Read Models](project-read-models.md) builds the inline order summary
  read model and query path.
- [Process Managers And Timers](process-managers-and-timers.md) shows
  replay-safe fulfillment coordination and a due timer worker.
- [Durable Workflows](durable-workflows.md) walks a named-step durable workflow
  end to end — steps, a durable sleep, an awakeable, a child workflow, the resume
  worker, and the kill-and-restart durability proof.
- [Routers And Effectful Fan-Out](routers-and-effectful-fan-out.md) routes one
  event to a read-model-resolved set of target streams, idempotently.
- [Coordinating Incident Response: Routers And Process Managers
  Together](coordinating-incident-response-with-routers-and-process-managers.md)
  pairs a router (page the on-call roster) with a process manager (escalation
  saga + timer) reacting to the same event, and explains when to reach for each.
- [Snapshots And Hydration](snapshots-and-hydration.md) enables advisory
  snapshots for the order stream.
- [Run And Operate Jitsurei](run-and-operate-jitsurei.md) collects build,
  migration, and production-readiness commands.
- [Dead Letters And Replay](../user/dead-letters.md) is the operator reference
  for rejected dispatches and subscription replay.
- [Integration Events With Kafka](integration-events-with-kafka.md) describes
  the canonical two-context Kafka topology, the operational guarantees,
  and when to deviate from the default ordering and retention policies.

The full source is under [`../../jitsurei/`](../../jitsurei/). The executable
tests are in [`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs).
