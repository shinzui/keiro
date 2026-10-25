---
type: Runbook
title: Serve Keiro Ops Over HTTP
description: Mount bounded HTTP inspection and explicitly confirmed operator actions using the supported Keiro command tree.
timestamp: 2026-10-25T04:48:05Z
docId: DOC-30
tags: [keiro, operations, http, inspection]
generated:
  by: openai/codex
  at: 2026-10-20T17:05:00Z
---

# Serve Keiro Ops Over HTTP

`keiro-ops-http` serves the supported operator command tree as JSON. It assumes
a trusted network or an authenticating reverse proxy: it adds no authentication,
authorization, or TLS. It binds loopback by default. The package is currently
unreleased; build it from this checkout in `nix develop`.

```bash
nix develop -c cabal run exe:keiro-ops-http -- --database-url "$DATABASE_URL" --port 9092
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
