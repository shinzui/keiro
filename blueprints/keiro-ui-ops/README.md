# Connect a Keiro service to keiro-ui

Run `keiro-ui-ops` in the consumer checkout. It edits the service's scaffold
recipe, application operator host, worker inspection and console routing for
the selected application. Subsequent DSL changes flow through the project's
ordinary regeneration and verification commands.

Before editing, the blueprint agent checks that the target resolves **Keiro
0.26 or newer**. It stops if the version is older or cannot be established.
The target also needs an authoritative `.keiro` source or `.keiro-workspace` and
a toolchain supporting generated inspection catalogs and service topology.
The blueprint can extend an embedded host
or add an application-specific ops executable. A shared console may live
outside the service checkout. In that case the run provides the exact target
entry and route for its owner.

The acceptance check exercises a generated writer. When the service has a
historical or overridden inspector, also seed a representative historical
stream and compare its list membership and folded state through the topology
selector. A generated-only service uses one seeded family.

Check the deployed browser's map, aggregate and process-manager drill-downs.
For each runtime in use, connect the application's Kiroku stream browser,
PGMQ queue inspector and Shibuya worker inspector. The browser proof reads
raw events, queue rows and live processors through the configured gateway
and exercises the applicable WebSocket upgrades.

From the consumer root, run against this checkout before publication:

```sh
seihou agent run /absolute/path/to/keiro/blueprints/keiro-ui-ops
```

Substitute the absolute path to your Keiro checkout. After publication, install
and run by name:

```sh
seihou install https://github.com/shinzui/keiro.git --module keiro-ui-ops
seihou agent run keiro-ui-ops
```

To inspect the rendered prompt, run `seihou agent --debug run` with the same
name or path in a disposable target directory. Seihou versions that record
preview receipts can write `.seihou/manifest.json` there.

The [HTTP host guide](../../docs/guides/serve-keiro-ops-over-http.md),
[generated inspection reference](../../docs/user/keiro-dsl-workspaces-and-generated-code.md#generated-inspection-catalog)
and [topology contract](../../docs/user/keiro-dsl-service-topology.md) describe
the interfaces the blueprint uses.
