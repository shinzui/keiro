# Run And Operate Jitsurei

From the repository root, build the example package and executable:

```bash
cabal build jitsurei:lib:jitsurei jitsurei:exe:jitsurei-demo
```

Run the guide-backed tests:

```bash
cabal test jitsurei-test
```

The tests use `EphemeralPg` through
[`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs), so they create a
temporary PostgreSQL instance instead of mutating a developer database.

For local demos and tests, `initializeJitsureiTables` creates the
application-owned `jitsurei_order_summary` read-model table in the example's own
`jitsurei` schema (via an opt-in `CREATE SCHEMA IF NOT EXISTS "jitsurei"` and a
schema-qualified `CREATE TABLE`) and explicitly registers the model as `Live`.
That keeps the data out of both the `kiroku` event-store schema and Keiro's
`keiro` framework schema while satisfying `runQuery`'s fail-closed startup
contract:

```haskell
initializeJitsureiTables :: (Store :> es) => Eff es ()
```

The router examples follow the same rule through `initializeOncallRoster` and
`initializeAreaChapters`: each helper creates its application table and calls
`registerReadModel` before any query is served. Production startup should do
the registration after service migrations have succeeded.

Production services should not depend on those compatibility initializers.
Instead, run `keiro-migrate` before the application starts, then apply your
service migrations for application tables such as `jitsurei_order_summary`.
Keiro owns framework tables like `keiro_snapshots`, `keiro_read_models`, and
`keiro_timers` in the dedicated `keiro` schema; your service owns its query
tables, indexes, and reporting views in a schema you choose (the example uses
`jitsurei`) — see
[Read Models And Projections](../user/read-models-and-projections.md#choosing-your-projection-schema).

For command handlers, keep these operational rules:

- Validate every command-side `EventStream` before startup and pass only
  `ValidatedEventStream` values to runners.
- Generate idempotency ids before calling `runCommand` when requests can be
  retried externally.
- Keep command decisions deterministic with respect to stored event history.
- Add codec tests for every supported old payload version.
- Monitor `CommandError` counts, retry exhaustion, hydration latency, and stream
  length.

For read models, coordinate `ReadModel.version` and `shapeHash` with deployment.
A stale read model should fail closed rather than return rows from an unknown
schema. Async projections must be idempotent by source event id.

For process managers and timers, treat duplicate delivery as normal. The
fulfillment process manager demonstrates deterministic command ids. The timer
guide demonstrates v7-compatible UUID fixtures through TypeID; production timer
ids should likewise be generated or derived through a UUIDv7-capable path.

`jitsurei-demo` also demonstrates application-level OpenTelemetry ownership. At
startup it creates one SDK `MeterProvider`, attaches the handle exporter to
stdout, constructs one `KeiroMetrics` value with `newKeiroMetrics`, and threads
that same handle through command options, process-manager worker options,
read-model queries (including queries nested inside routers), timer workers,
and durable-workflow run/resume options. The provider is shut down after the
selected demo, which performs a final collection and prints the recorded
`keiro.*` instruments. For example:

```bash
cabal run jitsurei-demo -- escalation
```

Production applications should keep the same ownership and threading shape but
replace the stdout exporter with their OTLP exporter.

The timer examples use `jitsureiTimerWorkerOptions`, constructed through
`mkTimerWorkerOptions`, instead of the unbounded historical default. It caps
firing at five attempts and requeues claims stranded in `Firing` after five
minutes. Timer ids and fired event ids remain deterministic because recovery is
at-least-once: a worker can repeat the fire action after a crash.

The escalation manager demonstrates the recommended terminal-manager snapshot
shape. `Settled` is terminal, the manager event stream uses `OnTerminal`, and
`defaultStateCodec` persists its state at codec version 1. The jitsurei test
suite proves that the second reaction writes a version-2 snapshot for the
manager's `esc-<incident>` stream. Use `Every n` instead for a manager that
keeps reacting for a long time rather than reaching a terminal state.

The broad local verification path is:

```bash
cabal build all
cabal test keiro-test
cabal test jitsurei-test
just website-verify
```

Run that before changing the guide source links. The website build copies
`jitsurei/` into `site-dist/` so links from `docs/guides/` to source files are
checked with the rest of the docs.
