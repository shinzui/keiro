# Keiro Guides

These guides teach Keiro through `jitsurei`, a sibling Cabal package in this
repository. The package is not pseudocode: it builds as part of this workspace,
and `cabal test jitsurei-test` exercises the behavior described here.

Start with the overview, then follow the path that matches the part of Keiro you
are adopting:

- [Order Fulfillment Overview](order-fulfillment-overview.md) explains the
  example domain and where each source file lives.
- [Build The Command Side](build-the-command-side.md) walks through commands,
  events, the Keiki transducer, the Keiro `EventStream`, and `runCommand`.
- [Evolve Events Safely](evolve-events-safely.md) shows the event codec and the
  version-1-to-version-2 upcaster.
- [Project Read Models](project-read-models.md) builds the inline order summary
  read model and query path.
- [Process Managers And Timers](process-managers-and-timers.md) shows
  replay-safe fulfillment coordination and a due timer worker.
- [Routers And Effectful Fan-Out](routers-and-effectful-fan-out.md) routes one
  event to a read-model-resolved set of target streams, idempotently.
- [Snapshots And Hydration](snapshots-and-hydration.md) enables advisory
  snapshots for the order stream.
- [Run And Operate Jitsurei](run-and-operate-jitsurei.md) collects build,
  migration, and production-readiness commands.
- [Integration Events With Kafka](integration-events-with-kafka.md) describes
  the canonical two-context Kafka topology, the operational guarantees,
  and when to deviate from the default ordering and retention policies.

The full source is under [`../../jitsurei/`](../../jitsurei/). The executable
tests are in [`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs).
