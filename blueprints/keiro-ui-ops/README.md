# Connect a Keiro service to keiro-ui

Run `keiro-ui-ops` in the consumer checkout. It edits the service's scaffold
recipe, application ops host, and console routing so the selected application's
Topology and Aggregates pages use the same ops URL. Subsequent DSL changes flow
through the project's ordinary regeneration and verification commands.

The target needs an authoritative `.keiro` source or `.keiro-workspace` and a
Keiro toolchain supporting generated inspection catalogs and service topology
(both are present in Keiro 0.26.0.0). The blueprint can extend an embedded host
or add an application-specific ops executable. A shared console may live
outside the service checkout. In that case the run provides the exact target
entry and route for its owner.

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
