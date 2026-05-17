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
- [Snapshots And Hydration](snapshots-and-hydration.md) enables advisory
  snapshots for the order stream.
- [Run And Operate Jitsurei](run-and-operate-jitsurei.md) collects build,
  migration, and production-readiness commands.

The full source is under [`../../jitsurei/`](../../jitsurei/). The executable
tests are in [`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs).
