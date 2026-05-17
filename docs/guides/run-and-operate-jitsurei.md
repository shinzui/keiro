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

For local demos and tests, `initializeJitsureiTables` creates the Keiro feature
tables used by the examples and the application-owned `jitsurei_order_summary`
table:

```haskell
initializeJitsureiTables :: (Store :> es) => Eff es ()
```

Production services should not depend on those compatibility initializers.
Instead, run `keiro-migrate` before the application starts, then apply your
service migrations for application tables such as `jitsurei_order_summary`.
Keiro owns framework tables like `keiro_snapshots`, `keiro_read_models`, and
`keiro_timers`; your service owns query tables, indexes, and reporting views.

For command handlers, keep these operational rules:

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
