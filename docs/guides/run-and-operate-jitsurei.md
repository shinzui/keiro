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
application-owned order read-side tables in the example's own `jitsurei`
schema (via an opt-in `CREATE SCHEMA IF NOT EXISTS "jitsurei"` and
schema-qualified `CREATE TABLE` statements). It then registers
`jitsureiProjectionCatalog`, which creates the catalog's rebuild-group metadata
and binds `orderSummaryReadModel` to that group. Repeating startup with the same
catalog fingerprint is idempotent; drift fails before the application serves
queries. This keeps application data out of both the `kiroku` event-store
schema and Keiro's `keiro` framework schema while satisfying `runQuery`'s
fail-closed startup contract:

```haskell
initializeJitsureiTables :: (Store :> es) => Eff es ()
```

The router examples follow the same rule through `initializeOncallRoster` and
`initializeAreaChapters`: each helper creates its application table and calls
`registerReadModel` before any query is served. Production startup should do
the registration after service migrations have succeeded.

Production services should not depend on those runtime DDL initializers.
Instead, run `keiro-migrate` before the application starts, then apply your
service migrations for application tables such as `jitsurei_order_summary`.
Keiro owns framework tables like `keiro_snapshots`, `keiro_read_models`, and
`keiro_timers` in the dedicated `keiro` schema; your service owns its query
tables, indexes, and reporting views in a schema you choose (the example uses
`jitsurei`) — see
[Read Models And Projections](../user/read-models-and-projections.md#choosing-your-projection-schema).

## Rehearse A Catalog Rebuild

The standalone `keiro-ops` binary cannot discover application handlers and
therefore omits catalog rebuild commands. `jitsurei-demo ops` is the candidate
application binary: it mounts the exact `orderCatalogOperations` value derived
from `jitsureiProjectionCatalog` through `AppHooks.projectionCatalog`.

Create or refresh the disposable repository-local database, then point the
embedded command at it:

```bash
just jitsurei-all
export PGHOST="$PWD/db"
export PGDATABASE=jitsurei
export PGUSER="$(whoami)"
```

List the mounted groups and inspect the complete registered preview. Both
commands are read-only; `--json` changes only the renderer:

```bash
cabal run jitsurei-demo -- ops rebuild list
cabal run jitsurei-demo -- ops rebuild preview jitsurei-order-reporting --json
```

The preview names the three qualified targets, their clear-versus-preserve
policies, dependency order, category source, projection owners, query binding,
subscription and dedup resets, verification hook, catalog fingerprint, and
current lifecycle state. It does not fence writers, create a run, truncate a
target, or reset framework state.

A `start`, `resume`, or `abandon` invocation without `--force` is also a
non-mutating preview and exits unsuccessfully so automation cannot mistake it
for execution:

```bash
cabal run jitsurei-demo -- ops rebuild start jitsurei-order-reporting \
  --run-id guide-rebuild-1 \
  --requested-by guide \
  --reason "local rebuild rehearsal"
```

Only against the disposable local database, review that output and repeat the
same embedded invocation with `--force`. Keep the
`cabal run jitsurei-demo -- ops` application prefix when following a rendered
force hint; the standalone `keiro-ops` binary has no application catalog to
mount. The start call fences the whole group,
captures one fixed event-store head, prepares the declared targets, replays and
verifies them, and promotes only complete evidence:

```bash
cabal run jitsurei-demo -- ops rebuild start jitsurei-order-reporting \
  --run-id guide-rebuild-1 \
  --requested-by guide \
  --reason "local rebuild rehearsal" \
  --force
cabal run jitsurei-demo -- ops rebuild status guide-rebuild-1 --json
```

If application verification or replay fails, the run remains inspectable and
the group remains fenced. Repair the application-owned cause, then preview and
force `rebuild resume guide-rebuild-1`; use `rebuild abandon` only when the run
must become terminal, knowing abandonment preserves the fence rather than
restoring cleared data. The `Jitsurei read model` acceptance test in
`jitsurei/test/Main.hs` is the safe automated proof of verification failure,
repair, exact-run resume, brownfield preservation, and live-writer fencing.

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
schema. Async delivery is at least once, while the projection's `idempotencyKey`
and Keiro's retained dedup rows provide exactly-once application, including
across offline catalog rebuilds. Keep handler SQL idempotent when practical as
defense in depth for events whose dedup rows have been pruned beyond the
redelivery window.

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
`defaultStateCodecWithFold` persists its state at codec version 1 with the
hand-owned token `FoldVersion "escalation-fold-v1"`. The jitsurei test suite
proves that the second reaction writes a version-2 snapshot for the manager's
`esc-<incident>` stream. Use `Every n` instead for a manager that keeps reacting
for a long time rather than reaching a terminal state.

The broad local verification path is:

```bash
cabal build all
cabal test keiro-test
cabal test jitsurei-test
```

Or `just haskell-verify`, which runs the same set plus the diagram check. The
links from this guide into `jitsurei/` source files are plain repository-relative
paths; check them by hand when you move or rename a module. They used to be
verified by the generated docs website, which was removed on 2026-07-23.
