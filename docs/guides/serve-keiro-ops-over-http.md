---
type: Runbook
title: Serve Keiro Ops Over HTTP
description: Mount bounded HTTP inspection and explicitly confirmed operator actions using the supported Keiro command tree.
timestamp: 2026-11-05T15:15:59Z
docId: DOC-30
tags: [keiro, operations, http, inspection]
generated:
  by: openai/codex
  at: 2026-10-20T17:05:00Z
---

# Serve Keiro Ops Over HTTP

`keiro-ops-http` serves the supported operator command tree as JSON. It assumes
a trusted network or an authenticating reverse proxy: it adds no authentication,
authorization, or TLS. It binds loopback by default. The package is published with the
0.22.0.0 cohort; use `nix develop` for the commands in this checkout.

```bash
nix develop -c cabal run keiro-ops-http:exe:keiro-ops-http -- --database-url "$DATABASE_URL" --port 9092
curl -s http://127.0.0.1:9092/health
curl -s http://127.0.0.1:9092/wf/list
```

The health body on a migrated database is
`{"status":"ok","schema_drift":[],"mutations_enabled":false}`. The workflow
body equals `keiro-ops wf list --json` against the same state. The executable
accepts `--bind`, `--port` (0 chooses a free port), repeated `--allow-origin`,
`--enable-mutations`, `--allow-schema-drift`, and `--request-timeout`. Database
selection follows `--database-url`, `KEIRO_OPS_DATABASE_URL`, `DATABASE_URL`,
then libpq environment settings. The network idle timeout defaults to 300
seconds; operation deadlines are separate.

## Embed and bound the work

Use the application's existing `AppHooks` to expose code-dependent commands.
Construct the application once and keep its inspection pool alive as long as
the server. For example, inside the lifecycle of `runtimeStore`:

```haskell
let config = defaultOpsHttpConfig
withOpsInspectionPool config.inspectionLimits connectionSettings $ \pool -> do
  let inspectionStore = runtimeStore {pool = pool}
  app <- opsApplication config applicationHooks inspectionStore
  withOpsHttpServer defaultOpsHttpServerConfig app $ \server ->
    wait server.serverThread
```

The pool helper preserves the host's connection string, schema, and extra
search path while installing a SQL timeout on every inspection connection.
The runtime store continues to own its notifier and publisher. The application
constructor performs no SQL or recurring refresh. A host supplying its own pool
must configure **every** connection with the SQL timeout; a setting on one
borrow cannot constrain another handler's borrow. Do not change a writer pool's
connection settings when mounting inspection. Shared-pool embedding requires
reserved writer capacity, a uniform host timeout policy, and the initiative's
interference tests.

Defaults are four concurrent jobs, no waiting queue, a five-second read deadline,
a two-second SQL statement timeout, a 30-second mutation deadline, a separate
30-second delivery deadline, a 16 KiB
path/query cap, a 1 KiB confirmation-body cap, and a 1 MiB encoded-result cap.
Limits include schema verification and encoding. Work is cancelled and joined
before its permit is released. A cancelled mutation has an unknown commit outcome;
inspect state before deciding whether to retry it. A result that exceeds the cap
returns an explicit error; it is never silently truncated. Large compatibility
reads such as replay audit still consume a slot and obey the deadline. Resource
limits do not imply that a SQL LIMIT bounds database scan work.

Repeated header reads may reuse their JSON presentation after checking every
current header field in PostgreSQL. The mount keeps at most 32 presentations
and 1 MiB of charged retained data, with no background refresh. Edits, deletion,
oversized results and live schema changes are still checked on the next request.
Other reads retain their own observation clocks and normal execution paths.

## Request mapping and confirmation

Mount aggregate and process-manager catalogs in `AppHooks.aggregates` and
`AppHooks.processManagers` to expose their discovery commands. For Jitsurei,
use `jitsureiAggregateInspectors` and `jitsureiProcessManagerInspectors` from
`Jitsurei.Inspection`. The embedded CLI commands `aggregate types --json` and
`pm types --json` return the same objects as these HTTP reads:

```bash
curl -fsS http://127.0.0.1:9092/aggregate/types
curl -fsS http://127.0.0.1:9092/pm/types
```

The aggregate discovery envelope contains rows such as:

```json
{"items":[{"name":"incident","category":"incident","snapshots_configured":false,"snapshot_policy":"never"}]}
```

Jitsurei also mounts the `credit-limit` and `order` aggregates. Its process-manager catalog returns
exactly this object, including before any journal instance exists:

```json
{"items":[{"name":"jitsurei-fulfillment","category":"fulfillment","snapshots_configured":false,"snapshot_policy":"never","timers_configured":null}]}
```

Process-manager rows are sorted by catalog lookup name, including aliases; use
that name with `pm show --name` or `pm list --name`. `pm types` takes no `--name`
option. `snapshots_configured` reports state-codec presence, regardless of whether
a snapshot is stored or the snapshot policy is `never`. Policies are `never`,
`every:N`, `on_terminal`, or `custom`; custom predicates are never evaluated for
discovery. `timers_configured: null` means unknown, rendered as `unknown` in the
human CLI table. It does not mean false or report pending timer counts.

An explicitly mounted empty catalog (`Just Map.empty`) returns `{"items":[]}`.
An absent hook (`Nothing`) omits the command and returns 400 `invalid_request`.
The standalone database-only server has no application catalogs; use the
[jitsurei host below](#see-the-hook-gated-routes-locally) to explore them. Discovery
enumerates in-memory descriptors without journal, state, snapshot, or timer
reads. HTTP still performs its normal fresh schema verification and applies
admission, deadlines and response-byte limits on every admitted read.
Discovery computes and encodes each response on demand inside those limits;
the mount retains no catalog response cache.

Path segments are command words followed by positional arguments. Query keys
use `snake_case` and become `--kebab-case=value` options. Repeated options retain
their order. Boolean flags accept exactly `true` (emit the flag) or `false`
(omit it), using the selected command's parser grammar. Percent-encode slashes
inside arguments. Empty or option-like path segments are refused. The legacy
`wf list --after NAME ID` maps to `/wf/list/ID?after=NAME`.

The keys `json`, `force`, `database_url`, `allow_schema_drift`, and `help` are
reserved. Invalid UTF-8 is refused. The parser and `isMutation` determine every
command route and method. Reads use GET and return the handler's JSON value.
Mutations use POST and are disabled by default, including previews.

With `--enable-mutations`, these requests exercise a preview and confirmation
against a stream that already exists:

```bash
curl -s -X POST http://127.0.0.1:9092/stream/soft-delete/order-1
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"confirm":"execute"}' http://127.0.0.1:9092/stream/soft-delete/order-1
```

The first body has `outcome: "preview"`, the handler's `result`, and the exact
`cli_reinvocation`; it changes no state. The second has `outcome: "executed"`
and the handler's `result`. Only an empty body or exactly
`{"confirm":"execute"}` is accepted. An extra key or another confirmation value
is refused. JSON mode skips the CLI's typed-name prompts for permanent stream
deletion and DLQ purge; browser hosts must provide any additional interaction
they require before sending confirmation.

`pgmq dlq read` reserves messages for 30 seconds and increments their read counts.
It is a mutation despite its name: use POST and confirmation, or CLI `--force`.
Without confirmation its preview only reports the supported depth observation.
It cannot be used as an authoritative non-consuming poll. Raw queue browsing
belongs to the owning PGMQ inspection surface.

## See the hook-gated routes locally

`jitsurei-ops-http` mounts the worked example's complete application hooks,
including its aggregate and process-manager catalogs. From a Nix shell, seed
its database, then start the host:

```bash
just jitsurei-all
just jitsurei-ops-http
```

In a second terminal, request the catalogs and fulfillment instances:

```bash
curl -fsS http://127.0.0.1:9092/aggregate/types
curl -fsS 'http://127.0.0.1:9092/pm/list?name=jitsurei-fulfillment&limit=5'
curl -fsS 'http://127.0.0.1:9092/projection/consumers?category=order'
curl -fsS 'http://127.0.0.1:9092/projection/consumers?category=creditLimit'
```

The category lookup reports `jitsurei-order-reporting` for `order` and an empty array
for `creditLimit`, even before checkpoints exist. It reports mounted configuration,
with projection coverage available and durable-input coverage unavailable. The default
page size is 100 (1..500); echo `next_cursor` as `after` for the same category and inventory.
Each request retains ordinary admission, schema verification, deadline, and byte limits.
The standalone server has no catalog/input hooks and omits this route. See
[Category consumers](../user/operations.md#category-consumers) for source scopes,
coverage, explicit durable declarations, status joining, and measurement limits.

The aggregate `items` are named `credit-limit`, `incident`, and `order`. The process-manager
`items` include a `correlation_id` beginning with `demo-`. Run `read -r ID`,
paste one complete correlation id from that response, and press Enter:

```bash
read -r ID
curl -fsS "http://127.0.0.1:9092/aggregate/show?name=order&id=$ID"
curl -fsS "http://127.0.0.1:9092/pm/show?name=jitsurei-fulfillment&correlation=$ID"
```

The aggregate response has `name: "order"`, `aggregate_id`, `stream_name`,
`stream_version`, hydrated `state`, `state_version`, and `hydration`. The
process-manager response has `name: "jitsurei-fulfillment"`, `correlation_id`,
folded `state`, `last_reaction`, and a `pending_timers` page. The host uses the
database selected by `JITSUREI_DATABASE` (default `jitsurei`) and remains
read-only unless explicitly started with `--enable-mutations`.

To inspect real named registers, run `just jitsurei-registers` from the Nix
shell. Each invocation creates a fresh credit-limit id and runs `AdjustCredit
25` once; it preserves existing data. The `all` scenario also seeds this example.
The demo prints its id, physical stream name, and three complete read URLs.
With the host running, paste that id after `read`:

```bash
read -r REGISTER_ID
curl -fsS "http://127.0.0.1:9092/aggregate/show?name=credit-limit&id=$REGISTER_ID"
curl -fsS "http://127.0.0.1:9092/aggregate/snapshot?name=credit-limit&id=$REGISTER_ID"
curl -fsS "http://127.0.0.1:9092/snapshot/show?stream=creditLimit-$REGISTER_ID"
```

The first response includes this stable subset (timestamps and hashes omitted):

```json
{"name":"credit-limit","state_version":1,"stream_version":1,"state_label":"credit_reviewed","state":{"state":"credit_reviewed","registers":{"active":false,"balance":25}}}
```

The health response has `status: "present"`, `stream_version: 1`, and
`stored.stream_version: 1` with `stored.compatibility: "compatible"`. The raw
snapshot response includes:

```json
{"stream_version":1,"state":{"state":"credit_reviewed","registers":{"active":false,"balance":25}}}
```

For a consumer, use the aggregate response's `stream_name`, URL-encoded, as
the `stream` parameter of `/snapshot/show`; the category prefix in the example
above is known only for this demo. Its inspector name is `credit-limit` and
its physical category is `creditLimit`; categories cannot contain hyphens. Apply the host's mount prefix to all routes
when composing servers. The embedded CLI uses the same handlers:

```bash
cabal run jitsurei-demo -- ops aggregate show --name credit-limit --id "$REGISTER_ID" --json
cabal run jitsurei-demo -- ops aggregate snapshot --name credit-limit --id "$REGISTER_ID" --json
cabal run jitsurei-demo -- ops snapshot show --stream "creditLimit-$REGISTER_ID" --json
```

Point the CLI at the same database as the host, for example with
`PGHOST="$PWD/db" PGDATABASE=jitsurei` and your normal `PGUSER`.

`aggregate show` reports current folded values at `state_version`. The raw
snapshot's `stream_version` belongs to the cached fold and may be older. For
example, a current head of 3 can show `lastAmount: 4` while a snapshot at 2
still contains `lastAmount: 3`. The health view's top-level `stream_version`
is the separately observed stream head; `stored.stream_version` and
`stored.events_since` describe the cached row against that observation. Reads
do not refresh snapshots. A missing stream or missing raw snapshot returns
HTTP 200 with JSON `null`. Incompatible snapshots remain visible as stored JSON;
only the application-aware health route evaluates codec compatibility. Each
request has its own observation time; these responses are not an atomic bundle.

`state.registers` is the contract of this example's display encoder and Keiro's
default snapshot codec. A custom display encoder or persistence codec can use
another shape. UIs can render arbitrary returned JSON; typed register tables
need an application-owned field contract. The order and incident displays retain
their state strings and now include `registers: {}`. Application display callbacks
may omit or redact fields, while `/snapshot/show` returns the raw persistence
JSON independently and can expose those omitted fields.

The example explicitly calls `regFileToJSON` from
`mori://shinzui/keiki/packages/keiki-codec-json`; every register slot must already
be initialized. Copying that pattern with an unwritten slot throws `uninit:`
and results in HTTP 500 `internal_error`. The demo initializes both slots. Its
`Every 1` snapshot policy is chosen so one command yields a stored snapshot;
choose a production policy for your workload.

For a browser console on another origin or a different backend port, run:

```bash
just jitsurei-ops-http --port 9093 --allow-origin http://localhost:5173
```

The executable in `jitsurei/ops-http/app/Main.hs` calls
`mainWithHooks (jitsureiOpsHooks Nothing)` using `Jitsurei.Ops`. An application
binary can likewise call `Keiro.Ops.Http.mainWithHooks` with its own `AppHooks`
to get the standalone host's flags, schema verification, origin policy,
mutation gate, and WebSocket feeds. `Keiro.Ops.Http.Host.withHost` exposes the
same lifecycle with explicit options and a continuation receiving the bound
port; it releases the listener, feeds, and inspection connections on return.

## Workflow counts

```bash
curl -fsS http://127.0.0.1:9092/wf/inspect/counts
curl -fsS --get --data-urlencode workflow_name=order-fulfillment http://127.0.0.1:9092/wf/inspect/counts
```

This read wraps `countWorkflowInstancesByStatus` and shares `keiro-ops wf inspect
counts` grammar and JSON. Its only domain option is `workflow_name`, matched by
exact equality. Pagination and status filters are rejected. Every response has
`observed_at` and all seven integer fields under `counts`, including zeroes for
empty selections. Counts describe retained current instance headers in one
statement snapshot; the database transaction clock does not make later pages
share that snapshot. Comparing with full list paging requires a quiescent database.

The count read shares live schema verification and the four-slot inspection
budget, two-second statement timeout, five-second read deadline and response cap.
Admission refusal is HTTP 503 `inspection_busy`; handler deadline expiry is HTTP
504 `inspection_timeout`. SQL cancellation follows the ordinary failed-command
path (HTTP 422 `command_failed`), releases resources and returns no partial totals.
A later request can retry. Direct CLI/library callers supply their own statement
deadline policy.

The dedicated inspection-pool helper disables PostgreSQL parallel query workers
(`max_parallel_workers_per_gather=0`) so admitted count reads do not fan out into
parallel worker groups. This changes no ordinary writer connection. Admission
remains four and SQL/handler deadlines remain two/five seconds. Direct callers
manage their own connection, parallelism and deadline policy.

The normal planner may use a sequential scan; exact counting has population-sized
work even for an absent name. No schema or runtime-write changes support this
read. Consult [the retained query and runtime evidence](../../keiro/bench/results/workflow-counts/README.md)
for the measured population and polling envelope before enabling automatic polling.


The measured HTTP envelope is one million balanced-class instance headers with
210 concurrent writer operations/sec: one unfiltered poll/sec, plus a tested
eight-client aligned overload mixture of unfiltered, common, rare and absent
names. All 500 measured successful reads completed without timeout; overload
returned admission refusals and recovered. Five matched capacity pairs and five
polling blocks passed the runtime guards. See the retained evidence for the
hardware, raw ranges and exact limits; larger datasets or other cadences require
their own measurements.

## Schema agreement and errors

Each admitted operation verifies the current PostgreSQL 18 schema. Drift that
appears after startup is refused: command routes return 409 `schema_drift` with
`details.drift`; `/health` returns 503 with `status: "schema_drift"`. No cache
weakens this check. With explicit `AllowDrift`, successful responses carry
`Keiro-Ops-Schema-Drift` and health is 200. Disabled mutations return 403
`mutations_disabled` before schema work, even when confirmed. Invalid requests
and excess admission also do no schema work.

Errors have `{"error":{"code":"...","message":"...","details":...}}`;
`details` is omitted when absent.

| HTTP | Code | Meaning |
|---|---|---|
| 400 | `invalid_request` | Invalid path, option, UTF-8, or command grammar |
| 400 | `invalid_confirmation` | Invalid confirmation object |
| 400 | `invalid_aggregate_id`, `invalid_correlation_id` | Blank inspector identity |
| 403 | `origin_not_allowed` | Mutation Origin is malformed, repeated, or outside the allowed/request origin |
| 403 | `mutations_disabled` | Host has not enabled mutation routes |
| 404 | `not_found` | No command at the root path |
| 405 | `method_not_allowed` | Method disagrees with classification; see `Allow` |
| 400 | `invalid_page_size` | Inspection page size is outside its supported range |
| 400 | `invalid_cursor` | Invalid or obsolete inspection cursor |
| 409 | `cursor_generation_mismatch` | Workflow rotated since the cursor was issued |
| 409 | `schema_drift` | Live schema differs from the binary |
| 413 | `inspection_request_too_large` | Path, query, or confirmation exceeds its cap |
| 413 | `inspection_result_too_large` | Encoded result or required continuation exceeds its byte cap |
| 415 | `unsupported_media_type` | A nonempty confirmation body requires application/json |
| 422 | `command_failed` | Supported handler returned a failure |
| 500 | `schema_verification_failed` | Verification could not run |
| 500 | `internal_error` | Handler raised a synchronous exception |
| 503 | `inspection_busy` | All admission slots are occupied |
| 504 | `inspection_timeout` | Read deadline expired |
| 504 | `mutation_outcome_unknown` | Mutation deadline expired; inspect before retrying |

Reads with a nonzero supported exit code retain their JSON value and carry
`Keiro-Ops-Exit-Code`. Responses retain the owning command's vocabulary:
`store_position`, `visible_store_head`, and global position distance; do not
interpret those as event lag or backlog.

CORS is disabled when `allowedOrigins` is empty. Allowed origins are compared by normalized scheme, host and effective port, then
echoed with `Vary: Origin`; preflight returns 204. Credentials and wildcards
are never enabled. A composition wrapper preserves existing CORS headers.

## Verification

The PostgreSQL integration suite compares executable JSON for seeded workflows,
timers, and streams, and the remaining database-only reads. It separately proves
DLQ reservation, previews that leave state unchanged, confirmation, drift after
construction, queue-free admission, joined cancellation, SQL timeouts, bounded
encoding, and socket shutdown:

```bash
nix develop -c cabal test keiro-ops-http-test --test-show-details=direct
```

[ADR-53](../adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md)
records the transport contract beneath
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md).
The integrated runtime interference and retention measurements remain release
gates in [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md).

Mutation origins are checked before reading the body, verification or command
execution. No-Origin clients remain supported. A present Origin must be one
serialized HTTP/HTTPS origin matching the configured allow-list or the request's
own scheme/Host, with case-insensitive scheme/host and normalized default ports.
Null, malformed and multiple origins are refused. Behind TLS termination, explicitly
allow-list the public HTTPS origin; arbitrary forwarded headers are not trusted.
CORS response headers do not themselves authorize a mutation.

An empty confirmation body is a preview and needs no content type. Every nonempty
body, including chunked transfer, must be application/json (parameters such as
charset are accepted), within 1 KiB, and exactly the supported confirmation object.

`deliveryDeadlineSeconds` defaults to 30 and must be positive and representable
in microseconds. It bounds the response callback separately from verification,
execution and encoding. On expiry the callback is cancelled, admission is returned,
and the connection terminates; the application never attempts a second response.
Health shares admission and may return `inspection_busy` while all slots are held.
It recovers after delivery cancellation returns those permits. This is bounded
recovery, not a reserved health slot or a promise that a 30-second delivery expires
within the five-second computation deadline.
