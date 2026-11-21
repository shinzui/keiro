# Connect this service to keiro-ui

Implement the integration in the consumer checkout. An operator should be
able to select this service in keiro-ui, view its committed service topology,
and browse live instances of its DSL aggregates through the same Keiro ops
base URL. Use the project's existing regeneration, hosting, and deployment
conventions. On reruns, verify existing wiring and fill only the gaps.

## Check the Keiro version before editing

Require **Keiro 0.26 or newer** on every run. Resolve the selected service in
its normal build environment. For Cabal, run `cabal build --dry-run` for its
actual component with its usual project file and flags. Run this check on the
resulting plan (adjust the path for a custom build directory):

```sh
jq -e '
  [."install-plan"[] | select(."pkg-name" == "keiro") | ."pkg-version"] | unique
  | if length == 0 then error("keiro is missing from the build plan")
    elif all(.[]; test("^[0-9]+([.][0-9]+)*$") and
                  (split(".") | map(tonumber) | . >= [0,26])) then .
    else error("Keiro 0.26+ required, resolved " + join(", ")) end
' dist-newstyle/cache/plan.json
```

For another build system, apply the same numeric version check to the actual
resolved package for the target. Record the version and its source. A Cabal
bound such as `>= 0.24` cannot establish which release the service builds.
If the version is older, missing, or unverifiable, stop before changing
consumer files and report the prerequisite. Once the runtime passes, verify
that the actual scaffold tool and ops libraries support the APIs below.

## Find the service and its host

Identify the service's authoritative DSL entry point, scaffold invocation,
generated Haskell package, ops hooks, database configuration, and the URL that
the browser uses for the selected application/environment. Use the workspace
manifest for a multi-file service. Keep independent services paired with their
own hooks, topology, database and target. Check the project's resolved
generator and libraries for the APIs below. If a necessary feature is absent,
identify the required Keiro upgrade. If there is no DSL for the domain, report
the modeling prerequisite with the affected aggregates. A hand-authored
topology or a second inspection-only domain model would drift from the runtime.

## Generate and mount the two artifacts

1. Add `--topology-out <file>` to the existing `keiro-dsl scaffold` recipe,
   preserving its source, output, layout, and ownership options. Regenerate
   and track the topology beside the spec or in the project's generated data
   directory. Include scaffold's generated Inspection module(s) in the
   appropriate Cabal stanzas, using the emitted fragment and actual module
   prefix. Preserve create-once implementation files.
2. Add `keiro-dsl topology <same-entry-point> --check <file>` to the normal
   verification or CI gate. Run it against the committed artifact **before**
   any in-place regeneration in that gate, or regenerate in a temporary tree
   and compare. A check against a file just overwritten by scaffold hides
   stale commits.
3. For one generated catalog, the host wiring is a record update on the
   application's existing hooks:

   ```haskell
   -- Inspection is a qualified import of this service's generated module.
   hooks = existingHooks { aggregates = Just Inspection.aggregateInspectors }
   ```

   For several generated catalogs in one service, concatenate their
   `aggregateInspectorCatalog` lists and validate once with
   `Keiro.Inspection.Aggregate.aggregateInspectors`. Fail startup on duplicate
   names. Remove redundant hand-written registrations and per-aggregate import
   lists. Preserve other hooks and intentional legacy aliases, membership
   filters or redacted displays. Compare existing responses before replacing
   custom inspectors: a generated snapshot inspector exposes codec registers,
   while a non-snapshot inspector shows the vertex. Where an override is needed,
   replace only its generated descriptor, validate the result, and test the
   existing display or access contract. Document any non-DSL entries.
4. Use the application's existing ops HTTP mount when available. For a new
   standalone process, add a small executable calling
   `Keiro.Ops.Http.mainWithHooks hooks`, and wire it into the project's launch
   and packaging commands with `--topology <installed-file>`. Include that
   file in the installed package or image at the path the process actually
   reads. The generic database-only executable lacks the application's
   aggregate hooks. For an embedded WAI app, load the file once at startup
   with `loadHostTopology` and the configured response limit, or decode embedded
   bytes with `decodeServiceTopology` and check the size against that limit.
   Set `serviceTopology = Just document` on the same hooks and surface a failed
   mount at startup. Keep inspection on its bounded pool and use the feed-enabled
   application for HTTP and WebSocket reads. Use the existing trusted network
   or authenticated gateway and retain the host's mutation policy.

## Connect the console

Reuse the deployed console when present. If this project owns a new console
mount, serve the keiro-ui static bundle built for that base path through the
project's static server or ingress. Route the exact `console-config.json` path
and inspection requests ahead of the SPA fallback. For a managed catalog,
set the chosen `targets[].surfaces.keiro` in the version 1 catalog to the
browser-visible ops base, for example `/inspection/dev/orders/keiro`.
Preserve other targets, surfaces and workers. For a single-target console
using its default same-origin routes, point `/keiro` at this host.

Forward both HTTP requests and the `/ws` upgrade. A standalone host receives
`/topology/show` after the proxy strips the entire external prefix. A composed
host mounted at `/keiro` receives `/keiro/topology/show` after the proxy strips
only the outer prefix. Preserve encoded IDs, queries, and browser Origin. If
an allowed origin is needed, use the actual console origin. When another repo
owns the console or ingress, provide the concrete catalog change and upstream
mapping in the handoff and identify what remains to be tested there.

## Prove the adoption through the consumer entry points

Run the project's scaffold and build the actual deployment target. Check that a
second scaffold produces identical generated files. Exercise the freshness gate
against both the real artifact and a deliberately stale temporary copy.
Start the packaged or embedded host with a migrated test database. Verify the
following through the configured browser-visible ops base, including its prefix:

- `GET /health` returns Keiro JSON. The console loads its assets and selects
  the intended target. Check the live `/ws` upgrade through the same route.
- `GET /topology/show` is byte-identical to the tracked file.
  `GET /topology/summary` reports its service, schema ID, and
  `document_sha256` (the `sha256:` prefix plus the digest of those exact bytes).
- From the served document, select every aggregate node's `details.category`.
  Compare that set against `items[].name` in `GET /aggregate/types`, including
  saga aggregates. Account for any intentional aliases or legacy extras.
  Keep this comparison in the consumer's integration checks so adding a DSL
  aggregate exercises discovery without updating a second list.
- For a generated category, request `GET /aggregate/list?name=…&limit=10`.
  With a seeded instance use its returned `aggregate_id` as the URL-encoded
  `id` in `GET /aggregate/show?name=…&id=…` and verify the folded state.
  An empty service can verify discovery and an empty page. Record instance
  hydration as unexercised until a fixture supplies a row.

Report the DSL entry point, regeneration and freshness commands, topology
artifact, host startup command, console URL, ops base, and checks actually run.
Distinguish local host evidence from checks through a deployed console.

Consult the [generated catalog](mori://shinzui/keiro/okf/user-documentation/concepts/DOC-32),
[topology contract](mori://shinzui/keiro/okf/user-documentation/concepts/DOC-35),
[ops reference](mori://shinzui/keiro/okf/user-documentation/concepts/DOC-15),
and [console deployment guide](mori://shinzui/keiro-ui/okf/user-documentation/concepts/DOC-3)
for the source contracts.
