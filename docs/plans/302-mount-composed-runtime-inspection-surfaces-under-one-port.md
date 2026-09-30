---
id: 302
slug: mount-composed-runtime-inspection-surfaces-under-one-port
title: "Mount composed runtime inspection surfaces under one port"
kind: exec-plan
created_at: 2026-09-30T23:35:20Z
intention: "intention_01m3taqnt3e6tvd4shm6sfy3a4"
master_plan: "docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T23:35:20Z
---

# Mount composed runtime inspection surfaces under one port

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A keiro application already links kiroku (the event store), shibuya (queue processing), and
pgmq-hs (the work-queue client). Each of those libraries ships, or is about to ship, its own
HTTP inspection surface as a separate package that exports one WAI `Application` value, and
keiro's own surface is being built the same way by
[plan 276](276-serve-the-keiro-ops-surface-over-http.md). Without this change an operator
who wants all of them must run four listeners on four ports, configure four bind addresses,
four CORS policies, and four reverse-proxy rules, and a browser sees four origins. With this
change an application composes whatever surfaces it has into one `Application`, serves it on
one port, and every surface answers under a stable path prefix: `/keiro/…`, `/kiroku/…`,
`/shibuya/…`, and `/pgmq/…`. The composition is routing only: no endpoint of any mounted
surface is re-implemented or reshaped, and a request that reaches a mounted surface looks
exactly as it would have looked standalone, minus the prefix.

You can see it working by building the example executable and pointing it at a migrated
database:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal run keiro-ops-http-compose-example -- --database-url "$DATABASE_URL" --port 9092 &
curl -s http://127.0.0.1:9092/
curl -s http://127.0.0.1:9092/kiroku/health/live
curl -s http://127.0.0.1:9092/keiro/health
curl -s -i http://127.0.0.1:9092/pgmq/queues
```

The first prints `{"surfaces":[{"prefix":"keiro","path":"/keiro"},{"prefix":"kiroku","path":"/kiroku"}]}`.
The second prints the same liveness body `kiroku-metrics` serves at `/health/live` when it
runs alone. The third prints `{"status":"ok","schema_drift":[],"mutations_enabled":false}`,
plan 276's health body. The fourth prints `HTTP/1.1 404 Not Found` with
`{"error":{"code":"surface_not_mounted",…}}` because the example mounts no pgmq surface.
A WebSocket client that connects to `ws://127.0.0.1:9092/kiroku/ws/metrics` receives the
same `snapshot` frame it would receive from `kiroku-metrics` alone at `/ws/metrics`.

This plan implements
[IR-31, Mount composed runtime inspection surfaces](../improvement-requests/mount-composed-runtime-inspection-surfaces.md)
(canonical handle `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`), the
composition half of the keiro runtime UI initiative, and is EP-6 of
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md).
The fifth condition of
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md),
"composition, not duplication", sanctions exactly this: keiro may mount kiroku's, shibuya's,
and pgmq's surfaces beside its own under stable prefixes because it is already the layer that
composes those libraries, and the composed application is a router that never re-serves,
reshapes, or re-implements an endpoint another library owns.


## Progress

- [ ] Milestone 1: `Keiro.Ops.Http.Compose` (prefix type, router, root index, unmounted-prefix
      refusal, and the once-only CORS middleware), exported from `Keiro.Ops.Http`, with
      database-free tests over stub applications including a WebSocket upgrade through a prefix
      over a real socket.
- [ ] Milestone 2: keiro's surface and `kiroku-metrics`'s surface composed end to end against a
      real store: byte-identical routes, WebSocket through the prefix, CORS configured once,
      absent surfaces refused, and keiro's `/keiro/ws` feed through the prefix when plan 277 has
      landed.
- [ ] Milestone 3: the `keiro-ops-http-compose-example` executable behind the `compose-example`
      flag, enabled for this workspace in `cabal.project`, and the composition guide.
- [ ] Milestone 4: capability record update, changelogs, `mori.dhall` entries, the ADR, IR-31
      implementation evidence, and the full verification gate.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The composition API lives in `keiro-ops-http` as the module
  `Keiro.Ops.Http.Compose`, not in a new package.
  Rationale: The API is generic over WAI `Application` values and needs no dependency on
  `kiroku-metrics`, `shibuya-metrics`, or any pgmq package; a new package would add one more
  lockstep release for a router, and `keiro-ops-http` already carries `wai` and `warp`.
  IR-31 offers either home; MasterPlan 45 chose this one.
  Date: 2026-09-30

- Decision: The stable prefixes are `keiro`, `kiroku`, `shibuya`, and `pgmq`, exported as
  named constants, and a host may also mount a surface under any other single-segment prefix
  matching `[a-z0-9-]+` (not starting with `-`).
  Rationale: IR-31 leaves the exact prefixes to keiro and asks that they be documented as
  stable; the keiro-ui direction document names these four; a custom prefix keeps the API
  usable for an application's own routes without inventing a second mounting mechanism.
  Date: 2026-09-30

- Decision: The router matches on the decoded `pathInfo` and forwards a request with both
  `pathInfo` and `rawPathInfo` rewritten: `pathInfo` loses its first segment, and
  `rawPathInfo` is rebuilt from the remaining segments with `encodePathSegments` (so an empty
  remainder becomes `/`). Every other field of the request is passed through untouched.
  Rationale: `wai-websockets` builds the WebSocket request head from `rawPathInfo` plus
  `rawQueryString` (verified in `Network.Wai.Handler.WebSockets.getRequestHead` of
  wai-websockets 3.0.1.3), and both `kiroku-metrics` and plan 277's endpoint dispatch on that
  raw path, so rewriting `pathInfo` alone would break every mounted WebSocket endpoint.
  Rebuilding from segments rather than trimming bytes avoids matching a percent-encoded
  prefix on raw bytes; the only observable effect is that a mounted surface sees a
  canonically percent-encoded raw path, which no surface in the stack depends on.
  Date: 2026-09-30

- Decision: A single trailing empty segment is dropped before matching, so `GET /kiroku/`
  reaches kiroku as `GET /` (`pathInfo = []`, `rawPathInfo = "/"`).
  Rationale: Warp gives `/` the empty `pathInfo`; without this rule `/kiroku/` would forward
  `[""]`, which no surface routes, and the standalone-equivalence property would fail on the
  most common typo.
  Date: 2026-09-30

- Decision: `GET /` on the composed application answers a JSON index of the mounted prefixes;
  any other method on `/` is `405`; a first segment that matches no mounted prefix is `404`
  with the conventions' error envelope and code `surface_not_mounted`, naming the mounted
  prefixes in `details`.
  Rationale: IR-31 acceptance 4 requires that mounting or omitting a surface changes only
  which prefixes answer; an index route lets a UI discover the composed set without probing,
  and it exposes no data of any mounted surface, so it stays inside ADR-40's fifth condition.
  Date: 2026-09-30

- Decision: CORS is applied once at the composed layer by `composedCorsMiddleware`, which
  mirrors plan 276's `corsMiddleware` (explicit allowed-origins list, off when empty, exact
  origin echoed with `Vary: Origin`, preflight answered with `204`, credentials never emitted)
  with one difference: it adds `Access-Control-Allow-Origin` and `Vary` only to responses
  that do not already carry `Access-Control-Allow-Origin`, and it answers preflights for
  allowed origins before any surface sees them.
  Rationale: IR-31 item 3 asks for one place to configure CORS for the composed server while
  each surface keeps its own behavior. A surface mounted with its own CORS enabled must not
  produce duplicated headers, and a surface mounted with CORS off must still be reachable
  cross-origin. WebSocket upgrades are unaffected, because browsers do not apply CORS to
  them; each surface's own upgrade origin check (plan 277's for keiro) still applies, so a
  host that needs cross-origin WebSocket clients passes the same origin list to that
  surface's configuration.
  Date: 2026-09-30

- Decision: The example executable `keiro-ops-http-compose-example` and the composition tests
  depend on `kiroku-metrics ^>=0.1.0.10`; the executable is behind a manual, default-off
  cabal flag `compose-example`, switched on for this workspace in `cabal.project`, and the
  test suite depends on it unconditionally.
  Rationale: The released `keiro-ops-http` must not pull sibling metrics packages into a
  consumer's install plan; a manual default-off flag guarantees that, exactly as
  `kiroku-metrics` guards its own example. Test-suite dependencies do not reach consumers.
  Turning the flag on in `cabal.project` keeps the example compiling under `just verify` so
  it cannot rot. `kiroku-metrics` 0.1.0.10 pins `kiroku-store ^>=0.9.0.1`, which is the bound
  keiro carries today; the listing milestones of plans 274 and 278 move keiro to
  `kiroku-store` 0.10, at which point `kiroku-metrics` 0.2.0.0 (kiroku MasterPlan 13's cohort
  release) is the matching version and its exported `combinedAppWithProviders` replaces the
  hand-composed `websocketsOr` expression below.
  Date: 2026-09-30

- Decision: The example mounts keiro's database-only surface and `kiroku-metrics` only.
  shibuya and pgmq are mounted by the same API as soon as their packages export a bare
  `Application`, which neither does on 2026-09-30.
  Rationale: `Shibuya.Metrics` exports `startMetricsServer` and friends but no `Application`
  (shibuya MasterPlan 7, `mori://shinzui/shibuya/masterplans/7-browser-ready-processor-inspection-and-control-surface`,
  is where that export is being planned), and pgmq-hs has no HTTP package yet
  (`mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-3` requests one). IR-31
  itself says the mounting story composes whatever subset exists, starting with the two
  surfaces that ship today.
  Date: 2026-09-30

- Decision: Bind address, port, and request timeout come from plan 276's
  `Keiro.Ops.Http.Server.withOpsHttpServer` and `OpsHttpServerConfig`; this plan adds no
  second runner.
  Rationale: IR-31 item 3 asks for one place to configure the bind for the composed server;
  the runner already exists and takes any `Application`.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The repository and the package this plan extends

This repository is a Cabal multi-package project built inside a Nix development shell
(`nix develop`, activated automatically by direnv in this checkout; otherwise prefix
commands with `nix develop -c`). `cabal.project` at the root lists the packages; `just
verify` is the full gate and `just haskell-test` (recipe in `justfile`) lists the test
suites it runs. Formatting is `nix fmt`.

The package this plan extends is `keiro-ops-http/`, created by
[plan 276](276-serve-the-keiro-ops-surface-over-http.md), which must be complete through its
Milestone 4 before Milestone 2 of this plan starts (Milestone 1 needs only that the package
exists with `Keiro.Ops.Http.Application.errorResponse`, `Keiro.Ops.Http.Config`, and
`Keiro.Ops.Http.Server.withOpsHttpServer`). Its shape, restated so this plan is
self-contained: the library exposes `Keiro.Ops.Http` (an umbrella re-export),
`Keiro.Ops.Http.Application` (`opsApplication :: OpsHttpConfig -> AppHooks -> KirokuStore ->
Application`, the error type `OpsHttpError { status, code, message, details }`, and
`errorResponse :: OpsHttpError -> Response`, which renders
`{"error":{"code":…,"message":…,"details":…}}` with `Content-Type: application/json;
charset=utf-8`), `Keiro.Ops.Http.Config` (`OpsHttpConfig { mutations, schemaDrift,
allowedOrigins }`, `defaultOpsHttpConfig`, `OpsHttpServerConfig { bindHost, port,
requestTimeoutSeconds }`, `defaultOpsHttpServerConfig` binding `127.0.0.1:9092`, port `0`
meaning an OS-assigned port), `Keiro.Ops.Http.Cors` (`corsMiddleware :: [Text] ->
Middleware`), `Keiro.Ops.Http.Route`, and `Keiro.Ops.Http.Server` (`OpsHttpServer
{ serverThread, serverPort }`, `startOpsHttpServer`, `stopOpsHttpServer`, and
`withOpsHttpServer :: OpsHttpServerConfig -> Application -> (OpsHttpServer -> IO a) -> IO a`).
Every route of keiro's surface is derived from the `keiro-ops` command tree and matches
`pathInfo` relative to wherever the application is mounted; `GET /health` is its health
route. The standalone executable `keiro-ops-http` serves `opsApplication` with
`emptyAppHooks`. The test suite is `keiro-ops-http-test` in `keiro-ops-http/test/Main.hs`,
built on hspec and on `keiro-test-support` (`withMigratedSuiteWith`, `withFreshStore`,
`withFreshDatabase` in `keiro-test-support/src/Keiro/Test/Postgres.hs`), with in-process
requests through `Network.Wai.Test` (`runSession`, `srequest`, `SRequest`, `setPath`,
`defaultRequest`) and socket-level requests through `http-client`. When
[plan 277](277-publish-websocket-live-feeds-over-keiro-wake.md) has landed, the package also
exposes `Keiro.Ops.Http.opsApplicationWithFeeds :: OpsHttpConfig -> FeedHandle -> AppHooks ->
KirokuStore -> Application`, `Keiro.Ops.Http.Feed.withFeedHandle`, and
`defaultFeedConfig`, and the `/ws` endpoint that dispatches on the raw request path.

### WAI facts this plan relies on

WAI (package `wai`) is the Haskell interface between web servers and applications. An
`Application` is `Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived`; a
`Middleware` is `Application -> Application`. A `Request` (record in
`Network.Wai.Internal`, fields exported from `Network.Wai`) carries, among others,
`requestMethod :: Method`, `pathInfo :: [Text]` (the path split on `/` and percent-decoded
by Warp; `/` gives `[]`; `/kiroku/` gives `["kiroku", ""]`), `rawPathInfo :: ByteString`
(the raw, still-encoded path starting with `/`), `rawQueryString`, `queryString`, and
`requestHeaders`. `Network.Wai.mapResponseHeaders :: (ResponseHeaders -> ResponseHeaders) ->
Response -> Response` edits a response's headers and `responseHeaders :: Response ->
ResponseHeaders` reads them. `Network.HTTP.Types.URI.encodePathSegments :: [Text] -> Builder`
(package `http-types`) percent-encodes segments and joins them with `/`, escaping a `/`
inside a segment as `%2F`; for `[]` it produces the empty builder. `wai-websockets`'s
`Network.Wai.Handler.WebSockets.websocketsOr :: ConnectionOptions -> ServerApp -> Application
-> Application` hands upgrade requests to the `ServerApp` and everything else to the inner
application; it builds the `RequestHead` the `ServerApp` sees from `rawPathInfo <>
rawQueryString` (function `getRequestHead`, verified in the wai-websockets 3.0.1.3 source at
`mori://yesodweb/wai`), which is why the router must rewrite `rawPathInfo`. The `websockets`
package's `Network.WebSockets.runClient host port path` drives a client in tests and
`requestPath (pendingRequest pending)` is what a `ServerApp` reads.

### The kiroku surface that is mounted

`kiroku-metrics` (canonical project `mori://shinzui/kiroku`, package
`mori://shinzui/kiroku/packages/kiroku-metrics`, checkout
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-metrics`, Hackage 0.1.0.10,
pinning `kiroku-store ^>=0.9.0.1` and `kiroku-cli ^>=0.2.0.8`) exposes, through
`Kiroku.Metrics` and its submodules: `Kiroku.Metrics.Server.httpApp :: MetricsServerConfig ->
KirokuMetrics -> [DependencyCheck] -> Maybe SubscriptionStatusProvider -> Application`, which
routes by matching `pathInfo` (`["metrics"]`, `["metrics","prometheus"]`, `["health"]`,
`["health","live"]`, `["health","ready"]`, `["subscriptions"]`, and answers anything else
with `404` and the frozen body `{"error":"Not found"}`);
`Kiroku.Metrics.WebSocket.websocketApp :: MetricsServerConfig -> KirokuMetrics -> KirokuStore
-> WebSocketState -> WS.ServerApp`, which dispatches on `requestPath` (`/ws/metrics` sends a
`snapshot` frame on connect and answers `{"type":"ping"}` with `{"type":"pong"}`;
`/ws/events` is the replayable event tail; any other path is rejected);
`Kiroku.Metrics.WebSocket.newWebSocketState :: Int -> IO WebSocketState`;
`Kiroku.Metrics.Collector.newKirokuMetrics :: KirokuStore -> IO KirokuMetrics`; and
`Kiroku.Metrics.Config.defaultConfig :: MetricsServerConfig` with fields `port`
(`9091`), `enableJSON`, `enablePrometheus`, `enableWebSocket`, `wsMaxConnections`, and more.
Its own server composes `websocketsOr WS.defaultConnectionOptions wsApp (httpApp cfg m deps
mProvider)` inside a private `combinedApp`, so a host today builds the same expression
itself; kiroku MasterPlan 13
(`mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`)
exports that value as `combinedAppWithProviders` in `kiroku-metrics` 0.2.0.0 and records
that it must stay a prefix-agnostic value for exactly this plan. Verify every signature above
in the checkout before use (`grep -n "^httpApp\|^websocketApp\|^newWebSocketState\|^newKirokuMetrics" -A6`
over the files named); the checkout can run ahead of the released 0.1.0.10.

### What exists elsewhere in the stack

`shibuya-metrics` (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-metrics`,
`mori://shinzui/shibuya`) routes by `pathInfo` and mounts its WebSocket with `websocketsOr`,
but its `Shibuya.Metrics` module exports only `startMetricsServer`,
`startMetricsServerWithDeps`, `stopMetricsServer`, `withMetricsServer`, the config, and the
protocol types, not the bare `Application`. Mounting it waits for the export shibuya's
MasterPlan 7 plans. pgmq-hs has no HTTP package. Neither is a dependency of this plan; the
composition API takes any `Application`.

### The wire conventions this plan follows

The keiro-ui conventions (project `mori://shinzui/keiro-ui`, path
`docs/architecture/inspection-api-conventions.md`, artifact-level URI pending) require: every
sister package exports both a convenience runner and the bare `Application` so a host can
mount several surfaces in one process behind one origin (area 1); new fields are
`snake_case` (area 2); errors use `{"error":{"code","message","details"}}` with stable
snake_case codes (area 4); CORS is configurable with an explicit allowed-origins list,
disabled by default, never wildcard with credentials (area 7); there is no authentication,
and the documentation restates the trusted-network or authenticating-proxy posture (area 8);
published wire shapes are frozen (area 9), which makes the prefixes stable once released. The
keiro-ui direction document (same project, `docs/architecture/ui-direction.md`) names the
primary deployment as "one process, one port, path prefixes per surface (`/kiroku/…`,
`/shibuya/…`, `/pgmq/…`, `/keiro/…`)".

### ADRs consulted

Local, in `docs/adr/`:

- [ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md):
  the stance decision. Its fifth condition sanctions this plan and bounds it: the composed
  application is a router; it never re-serves, reshapes, or re-implements an endpoint another
  library owns; raw stream and event browsing stays kiroku's. Its first condition (no
  existing keiro package gains a web dependency) is why the example lives behind a flag in
  `keiro-ops-http` rather than in `jitsurei`.
- [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md):
  keiro surfaces never reach into another library's private schema; the composed router
  touches no data at all.

Cross-repository, by the canonical handles the keiro-ui bundle publishes:
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1` (keiro owns the composition of mounted
surfaces; each endpoint lives in the project that owns the concept),
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4` (sister packages export a runner and the
bare `Application`, which is what makes composition possible),
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-5` (no backend-for-frontend: the composed
mount is routing, never aggregation or reshaping). No ADR records the composition contract
itself; Milestone 4 writes it. The `docs/adr/` bundle is profile-governed
(`docs/adr/profile.dhall`); the next free handle on 2026-09-30 was ADR-49, allocated only at
creation with `okf id next`.

### Coordination under MasterPlan 45

This plan hard-depends on plan 276 (EP-1) and soft-depends on plan 277 (EP-5): Milestone 2's
keiro WebSocket case runs only when `Keiro.Ops.Http.opsApplicationWithFeeds` exists. Plan 303
(EP-7) releases the package that carries this module. The MasterPlan's Integration Points
record the composition contract this plan owns: prefixes `keiro`, `kiroku`, `shibuya`, `pgmq`;
both `pathInfo` and `rawPathInfo` rewritten; `GET /` index; `surface_not_mounted` refusal;
CORS once with add-if-absent; keiro mounted at `/keiro` so `/keiro/health` and `/keiro/ws`
are its composed paths; every mounted route mount-relative with no absolute URLs. Plans 276
and 277 carry that constraint in their own coordination notes.


## Plan of Work

### Milestone 1: the composition module and its database-free tests

Scope: `keiro-ops-http/src/Keiro/Ops/Http/Compose.hs`, its re-export from `Keiro.Ops.Http`,
and a test module that proves the routing contract with stub applications, including a
WebSocket upgrade through a prefix over a real loopback socket. At the end, `cabal test
keiro-ops-http-test --test-options='--match Compose'` passes without PostgreSQL.

Create `keiro-ops-http/src/Keiro/Ops/Http/Compose.hs` with the interface in Interfaces and
Dependencies and this behavior. `mkSurfacePrefix` accepts exactly one path segment matching
`[a-z0-9-]+` that does not start with `-`, returning `Left (InvalidPrefix text)` otherwise;
`keiroPrefix`, `kirokuPrefix`, `shibuyaPrefix`, and `pgmqPrefix` are the four constants.
`composeSurfaces config surfaces` returns `Left NoSurfaces` for an empty list and
`Left (DuplicatePrefix p)` when two surfaces share a prefix (compare `surfacePrefixText`);
otherwise it returns `composedCorsMiddleware config.allowedOrigins router` where `router` is
the application that, per request, computes `segments = dropTrailingEmpty (pathInfo req)`
(remove one trailing `""` if present, so `["kiroku", ""]` becomes `["kiroku"]` and `[""]`
becomes `[]`), then: for `segments == []`, answers `GET` with `200` and the JSON body
`{"surfaces":[{"prefix":p,"path":"/" <> p} …]}` in mount order and any other method with
`405` through `errorResponse (OpsHttpError status405 "method_not_allowed" "the composed root
answers GET only" Nothing)` plus an `Allow: GET` header; for `segments == (p : rest)` with a
mounted prefix `p`, calls that surface's application with `req { pathInfo = rest,
rawPathInfo = rebuilt }` where `rebuilt` is `toStrict (toLazyByteString (encodePathSegments
rest))` when `rest` is non-empty and `"/"` otherwise; for any other first segment, answers
`404` through `errorResponse (OpsHttpError status404 "surface_not_mounted" ("no surface is
mounted at /" <> p) (Just (object ["mounted" .= mountedPrefixes])))`. Export
`stripSurfacePrefix :: SurfacePrefix -> Request -> Maybe Request` as the pure piece the router
uses (returning `Nothing` when the first segment does not match) so tests can check it
directly.

`composedCorsMiddleware origins` is `id` for an empty list. Otherwise, for a request whose
`Origin` header equals one of the origins byte for byte: a preflight (`OPTIONS` with an
`Access-Control-Request-Method` header) is answered directly with `204`,
`Access-Control-Allow-Origin: <origin>`, `Vary: Origin`, `Access-Control-Allow-Methods: GET,
POST, OPTIONS`, `Access-Control-Allow-Headers: <the request's Access-Control-Request-Headers
value, or Content-Type when absent>`, and `Access-Control-Max-Age: 600`; any other request
passes through and, if the inner response has no `Access-Control-Allow-Origin` header, gains
`Access-Control-Allow-Origin: <origin>` and `Vary: Origin` through `mapResponseHeaders`. A
request whose origin is absent or not allowed passes through untouched.
`Access-Control-Allow-Credentials` is never emitted. Copy the header-matching helpers from
`Keiro.Ops.Http.Cors` rather than importing its middleware, and add a Haddock note on each
module cross-referencing the other so a future change keeps them aligned.

Add `Keiro.Ops.Http.Compose` to `exposed-modules` in `keiro-ops-http/keiro-ops-http.cabal`
and re-export its public names from `keiro-ops-http/src/Keiro/Ops/Http.hs`. The module needs
`blaze-builder` or `bytestring`'s `Data.ByteString.Builder` (`toLazyByteString`) and
`http-types`; add nothing that is not already in the package's `build-depends` except
`bytestring` if absent.

Create `keiro-ops-http/test/Test/ComposeSpec.hs` (register it under `other-modules` in the
test stanza and call its `spec` from `keiro-ops-http/test/Main.hs` outside the database
fixture). Define `echoApp :: Text -> Application`, which answers every request with `200`
and the JSON body `{"surface": name, "method": …, "path_info": pathInfo, "raw_path_info":
rawPathInfo, "raw_query_string": rawQueryString}`, and `corsEchoApp`, which additionally sets
`Access-Control-Allow-Origin: http://already.test` on its response. Cases, each through
`Network.Wai.Test`:

- "strips the prefix from path_info and raw_path_info": on `composeSurfaces defaultComposeConfig
  [keiro ↦ echoApp "keiro", kiroku ↦ echoApp "kiroku"]`, `GET /kiroku/health/live?x=1`
  answers `surface` `kiroku`, `path_info` `["health","live"]`, `raw_path_info`
  `/health/live`, `raw_query_string` `?x=1`; `GET /keiro/wf/list` answers `surface` `keiro`
  and `raw_path_info` `/wf/list`; `GET /kiroku` and `GET /kiroku/` both answer `path_info`
  `[]` and `raw_path_info` `/`; `GET /keiro/stream/show/order%2F1` answers `path_info`
  `["stream","show","order/1"]` and `raw_path_info` `/stream/show/order%2F1`.
- "answers the root index and refuses other methods": `GET /` is `200` with
  `{"surfaces":[{"prefix":"keiro","path":"/keiro"},{"prefix":"kiroku","path":"/kiroku"}]}`;
  `POST /` is `405` with `Allow: GET` and `error.code` `method_not_allowed`.
- "refuses an unmounted prefix with the error envelope": `GET /pgmq/queues` is `404` with
  `error.code` `surface_not_mounted` and `error.details.mounted` `["keiro","kiroku"]`; with
  only `keiro` mounted, `GET /kiroku/health` is `404` and `GET /keiro/health` still reaches
  the stub (IR-31 acceptance 4).
- "rejects duplicate and invalid prefixes": composing two surfaces under `kirokuPrefix` is
  `Left (DuplicatePrefix "kiroku")`; `mkSurfacePrefix "Kiroku"`, `"-x"`, `"a/b"`, and `""`
  are `Left (InvalidPrefix _)`; `composeSurfaces _ []` is `Left NoSurfaces`.
- "applies CORS once": with `allowedOrigins = ["http://ui.test"]`, `GET /keiro/x` with
  `Origin: http://ui.test` carries exactly one `Access-Control-Allow-Origin` header equal to
  `http://ui.test` and `Vary: Origin`; the same request to a `corsEchoApp` surface carries
  exactly one `Access-Control-Allow-Origin`, equal to `http://already.test`; `OPTIONS
  /kiroku/x` with that origin and `Access-Control-Request-Method: GET` is `204` with the
  allow headers and never reaches the stub (assert by a stub that records calls); with
  `Origin: http://other.test` no CORS header appears; with `allowedOrigins = []` no CORS
  header appears for any origin; no response ever carries
  `Access-Control-Allow-Credentials`.
- "forwards a WebSocket upgrade through the prefix" (real socket, no database): mount
  `websocketsOr WS.defaultConnectionOptions recordingServerApp (echoApp "stub")` under
  `mkSurfacePrefix "stub"`, where `recordingServerApp` accepts the connection and sends one
  text frame containing `requestPath (pendingRequest pending)`; serve the composed application
  with `withOpsHttpServer defaultOpsHttpServerConfig { port = 0 }`; `WS.runClient "127.0.0.1"
  port "/stub/ws/events?from=3"` receives the frame `/ws/events?from=3`; connecting to
  `/nope/ws/events` fails the handshake with a `404` (catch `WS.MalformedResponse` or the
  handshake exception and assert the status). Wrap every client action in
  `System.Timeout.timeout` of 15 seconds.

Commit as `feat(ops-http): compose inspection surfaces under path prefixes` with the
trailers in Concrete Steps.

### Milestone 2: keiro and kiroku composed end to end

Scope: prove IR-31's acceptance criteria against the real surfaces. At the end,
`cabal test keiro-ops-http-test --test-options='--match "composed surfaces"'` passes against
a fresh migrated store.

Add `kiroku-metrics ^>=0.1.0.10`, `wai-websockets >=3.0 && <3.1`, and `websockets >=0.13 &&
<0.14` (the latter two if plan 277 has not already added them) to the `keiro-ops-http-test`
stanza's `build-depends`. Because `kiroku-metrics` depends on `kiroku-cli`, run `cabal build
keiro-ops-http:test:keiro-ops-http-test --dry-run` first and record in Surprises & Discoveries
what the addition pulls into the plan; if the solver cannot reconcile `kiroku-cli` with the
workspace, stop and record it before changing any bound.

Create `keiro-ops-http/test/Test/ComposedSurfacesSpec.hs` with `spec :: Fixture -> Spec`,
called from `Main.hs` inside `withMigratedSuiteWith [pgmq]`, using `around (withFreshStore
fixture)`. Define `kirokuSurface :: KirokuStore -> IO Application` as `do km <-
newKirokuMetrics store; ws <- newWebSocketState (wsMaxConnections cfg); pure (websocketsOr
WS.defaultConnectionOptions (websocketApp cfg km store ws) (httpApp cfg km [] Nothing))`
with `cfg = defaultConfig` (when `kiroku-metrics` 0.2.0.0 is the pinned version, replace the
expression with its exported `combinedAppWithProviders` and record the swap in the Decision
Log). Define `keiroSurface store = opsApplication defaultOpsHttpConfig emptyAppHooks store`
(or `opsApplicationWithFeeds defaultOpsHttpConfig handle emptyAppHooks store` under
`withFeedHandle defaultFeedConfig store` when plan 277 has landed). Cases:

- "serves kiroku routes byte-identical to standalone": for each of `/health/live`,
  `/health/ready`, `/metrics`, and `/nope`, run the request once against `kirokuSurface`
  alone and once against the composed application under `/kiroku`, and assert equal status
  codes and equal bodies (`/nope` proves kiroku's own frozen `{"error":"Not found"}` is what
  answers, not the composed envelope). For `/health`, whose body carries a metrics snapshot
  that may move between two reads, assert equal status codes and equal decoded `status`
  members. (IR-31 acceptance 1, kiroku half.)
- "serves keiro routes byte-identical to standalone": `/health` and `/wf/list` (after seeding
  one workflow instance the way `keiro-ops/test/Main.hs`'s `seedStep` does) answer the same
  status and body through `/keiro/…` as standalone. (IR-31 acceptance 1, keiro half.)
- "connects a WebSocket client through the kiroku prefix" (real socket via
  `withOpsHttpServer` on port `0`): `WS.runClient "127.0.0.1" port "/kiroku/ws/metrics"`
  receives a first frame whose `type` is `snapshot`, then after sending `{"type":"ping"}`
  receives `{"type":"pong"}`; `WS.runClient … "/kiroku/ws/events"` completes the handshake
  (kiroku accepts the path; send nothing and close). (IR-31 acceptance 2.)
- "connects a WebSocket client through the keiro prefix" (only when
  `opsApplicationWithFeeds` exists; otherwise `pendingWith` naming plan 277): `WS.runClient …
  "/keiro/ws"` then `{"type":"subscribe","feed":"workflows"}` receives a `snapshot` frame.
- "configures CORS once for every surface": with `allowedOrigins = ["http://ui.test"]` on
  the composed configuration and both surfaces mounted with their own CORS off, `GET
  /kiroku/health/live` and `GET /keiro/health` with `Origin: http://ui.test` each carry
  exactly one `Access-Control-Allow-Origin`; an `OPTIONS` preflight to each is `204`; with
  the composed list empty, no response on either surface carries a CORS header. (IR-31
  acceptance 3.)
- "changes only which prefixes answer when a surface is absent": compose keiro alone; assert
  `GET /keiro/health` is `200` and `GET /kiroku/health/live` is `404` `surface_not_mounted`;
  compose both; assert both are `200`. (IR-31 acceptance 4.)
- "reshapes nothing": a reviewer-facing test that reads
  `keiro-ops-http/src/Keiro/Ops/Http/Compose.hs` from disk (path relative to the package
  directory, as plan 276's tests locate files) and asserts it contains none of the strings
  `"health"`, `"metrics"`, `"ws"`, `"streams"`, `"wf"`, or `"subscriptions"`, so no route of
  any mounted surface is named in the composition code. (IR-31 acceptance 5, mechanically.)

Commit as `test(ops-http): prove keiro and kiroku compose under one port`.

### Milestone 3: the example executable and the guide

Scope: a runnable, documented example and the runbook that tells an operator how to compose
their own application. At the end, `cabal run keiro-ops-http-compose-example -- --help`
prints its options and the transcript in Purpose / Big Picture can be reproduced.

In `keiro-ops-http/keiro-ops-http.cabal` add:

```cabal
flag compose-example
  description:
    Build the composed-surface example executable. Off by default because it
    depends on kiroku-metrics, which a consumer of the released package must
    not be forced to install. cabal.project turns it on for this workspace.
  default:     False
  manual:      True

executable keiro-ops-http-compose-example
  import:         warnings, shared
  hs-source-dirs: example
  main-is:        Compose.hs
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N

  if !flag(compose-example)
    buildable: False

  build-depends:
    , base                  >=4.21 && <5
    , keiro-migrations
    , keiro-ops
    , keiro-ops-http
    , kiroku-metrics        ^>=0.1.0.10
    , kiroku-store
    , optparse-applicative  >=0.19 && <0.20
    , text                  >=2.1  && <2.2
    , wai                   >=3.2  && <3.3
    , wai-websockets        >=3.0  && <3.1
    , websockets            >=0.13 && <0.14
```

(Copy the internal-package bounds from the library stanza so they stay `^>=` at the shared
version.) In `cabal.project`, after the existing `package keiro-dsl` stanza, add:

```text
package keiro-ops-http
  flags: +compose-example
```

Create `keiro-ops-http/example/Compose.hs`. It parses `--database-url URL` (optional,
resolved through `Keiro.Ops.Env.resolveConnectionString` exactly as plan 276's executable
does), `--bind HOST` (default `127.0.0.1`), `--port N` (default `9092`), and
`--allow-origin ORIGIN` (repeatable); opens the store with `withStore
(defaultConnectionSettings connectionString)`; builds the kiroku surface with the expression
from Milestone 2 (`newKirokuMetrics`, `newWebSocketState`, `websocketsOr`, `httpApp`); builds
the keiro surface as `opsApplication defaultOpsHttpConfig emptyAppHooks store` (or
`opsApplicationWithFeeds` under `withFeedHandle` when it exists); composes them with
`composeSurfaces defaultComposeConfig { allowedOrigins } [MountedSurface keiroPrefix keiro,
MountedSurface kirokuPrefix kiroku]`, exiting with the rendered `ComposeError` on `Left`;
prints `keiro-ops-http-compose-example: listening on <host>:<port>; surfaces /keiro /kiroku`
to stderr; and runs `withOpsHttpServer` until interrupted. It mounts `emptyAppHooks`, so
keiro's surface is the database-only command set, exactly like the standalone
`keiro-ops-http` executable.

Write `docs/guides/compose-runtime-inspection-surfaces.md` in the `docs/guides` OKF bundle
(profile `mori/user-documentation-profile.dhall`; allocate the handle with `okf id next
docs/guides --profile mori/user-documentation-profile.dhall DOC`; copy the frontmatter shape of
`docs/guides/run-and-operate-jitsurei.md`, `type: Runbook`, `tags: [keiro, operations, http,
inspection, composition]`). It must contain: the one-paragraph trusted-network or
authenticating-proxy posture in the conventions' words; the four stable prefixes and the
statement that they are frozen once released; how to build each surface's `Application`
(keiro's from plan 276's runbook, kiroku's from the expression above with a pointer to
`combinedAppWithProviders` for `kiroku-metrics` 0.2.0.0 and later, shibuya's and pgmq's "once
their packages export an `Application`", naming shibuya MasterPlan 7 and pgmq-hs IR-3 by
canonical handle); the composition call and the `withOpsHttpServer` runner; the root index and
the `surface_not_mounted` refusal with copied transcripts; the CORS-once rule, including the
sentence that a host passes its origin list to keiro's `OpsHttpConfig` only for the WebSocket
upgrade origin check and may leave its HTTP CORS off; the note that WebSocket endpoints work
unchanged behind a prefix (`/kiroku/ws/metrics`, `/kiroku/ws/events`, `/keiro/ws`); the
single-origin deployment story for the keiro-ui console (static assets served beside the
composed mount, no CORS needed); and how to run the example. Add the guide to
`docs/guides/index.md` under the Runbook heading in alphabetical order, append a dated entry
to `docs/guides/log.md`, and run `just user-documentation-validate`. In
`docs/user/operations.md`, section "Operating Keiro", add one sentence after the paragraph
plan 276 added, pointing at the guide by relative link; append to `docs/user/log.md`.

Commit as `feat(ops-http): add the composed-surface example and guide`.

### Milestone 4: bookkeeping, evidence, and the ADR

Scope: everything that makes the change discoverable, releasable, and recorded. At the end,
`just verify` passes, IR-31 carries implementation evidence, and the composition contract is
in `docs/adr/`.

Update the capability record plan 276 created for the HTTP surface
(`docs/capabilities/http-operational-surface.md` or whatever name plan 276 chose; find it
with `grep -l "keiro-ops-http" docs/capabilities/*.md`): add `Keiro.Ops.Http.Compose` to
`interface`, add evidence entries for `keiro-ops-http/test/Test/ComposedSurfacesSpec.hs` and
the guide, and add a sentence in the body that the surface composes with sibling surfaces
under stable prefixes. Append to `docs/capabilities/log.md` and run `just
capabilities-validate`. Add `## [Unreleased]` entries to the root `CHANGELOG.md` and
`keiro-ops-http/CHANGELOG.md` (New Features: the composition module, the four prefixes, the
root index, CORS once; Other: the flag-guarded example). In `mori.dhall`, in the
`keiro-ops-http` package block plan 276 added, add a `Schema.Dependency` entry for
`shinzui/kiroku:kiroku-metrics` with a test or example scope (copy the shape of an existing
entry whose `scope` is not `Regular`, or use `Regular` with an `extraDocs` note if the schema
offers no other scope, and say which in the Decision Log). In `README.md`'s package list,
extend the `keiro-ops-http/` bullet with "and composes sibling inspection surfaces under one
port".

Create the ADR with the handle from `okf id next docs/adr --profile docs/adr/profile.dhall
ADR` (ADR-49 on 2026-09-30; sibling plans may take it first), file name
`00NN-composed-inspection-mounting-is-prefix-routing-only.md`, frontmatter matching
`docs/adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md` plus
`originatingPlan: docs/plans/302-mount-composed-runtime-inspection-surfaces-under-one-port.md`.
Its Context restates ADR-40's fifth condition and the four-listener problem. Its Decision
records: the composed application is a router over bare WAI `Application` values under the
stable prefixes `keiro`, `kiroku`, `shibuya`, and `pgmq`; a mounted surface receives the
request with both `pathInfo` and `rawPathInfo` stripped of the prefix and nothing else
changed, so its routes and WebSocket endpoints stay mount-relative; keiro never re-serves,
rewrites, or re-implements a mounted surface's endpoint; the only cross-cutting behavior the
composed layer adds is one CORS policy applied to responses that lack their own, one bind
address and port, a root index, and a `surface_not_mounted` refusal; the example and tests
depend on sibling metrics packages only behind a flag and in the test suite, so the released
package's install plan stays free of them; and every keiro surface must therefore keep its
routes mount-relative and its responses free of absolute URLs. Its Consequences name the cost
(a consumer composes surfaces by hand until sibling packages export their applications) and
cite `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`, `ADR-4`, and `ADR-5`. Regenerate the
index with `okf index docs/adr --write` if the bundle keeps one (check how ADR-40 was added
with `git log --stat -1 -- docs/adr/0040-*`), append to `docs/adr/log.md` with `okf log add`,
and run `just adr-validate`.

Update `docs/improvement-requests/mount-composed-runtime-inspection-surfaces.md`: append an
`## Implementation evidence (<date>)` section naming this plan, the module, the test groups
that prove each of the five acceptance criteria, the guide, and the pending release; set
`status: in-progress` if it is still `accepted`; advance `timestamp`; add a dated
`Implementation` entry to `docs/improvement-requests/log.md`; and run the bundle validation.
The request moves to `completed` only in plan 303, when the release that carries the module
is on Hackage.

Run the full gate in Concrete Steps and fill Outcomes & Retrospective. Commit as
`docs(ops-http): record the composed-surface contract`.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`, inside the
Nix development shell (`nix develop -c <command>` is the explicit form). Every commit carries
these trailers after a blank line:

```text
MasterPlan: docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md
ExecPlan: docs/plans/302-mount-composed-runtime-inspection-surfaces-under-one-port.md
Intention: intention_01m3taqnt3e6tvd4shm6sfy3a4
```

Before Milestone 1, confirm the gate:

```bash
ls keiro-ops-http/src/Keiro/Ops/Http
grep -n "^- \[x\] Milestone [1-4]" docs/plans/276-serve-the-keiro-ops-surface-over-http.md
grep -n "opsApplicationWithFeeds" keiro-ops-http/src/Keiro/Ops/Http.hs
```

Expected: `Application.hs Config.hs Cors.hs Route.hs Server.hs` (plus plan 277's modules if it
landed), four checked milestones in plan 276, and either a hit or no hit for the feeds
function; record which in Surprises & Discoveries because it decides the keiro WebSocket case
in Milestone 2 and the example's keiro surface.

Milestone 1:

```bash
cabal build keiro-ops-http
cabal test keiro-ops-http-test --test-options='--match Compose' --test-show-details=direct
```

Expected transcript fragment:

```text
Keiro.Ops.Http.Compose
  strips the prefix from path_info and raw_path_info [✔]
  answers the root index and refuses other methods [✔]
  refuses an unmounted prefix with the error envelope [✔]
  rejects duplicate and invalid prefixes [✔]
  applies CORS once [✔]
  forwards a WebSocket upgrade through the prefix [✔]
```

Milestone 2:

```bash
cabal build keiro-ops-http:test:keiro-ops-http-test --dry-run 2>&1 | grep -i "kiroku-metrics\|kiroku-cli"
cabal test keiro-ops-http-test --test-options='--match "composed surfaces"' --test-show-details=direct
```

Expected: the dry run lists `kiroku-metrics-0.1.0.10` (and `kiroku-cli`) as new components of
the test suite's plan and nothing under any other package; the suite passes with every case
above, the keiro WebSocket case either passing or reported as pending with plan 277's name.

Milestone 3, the manual transcript (uses the repository's PostgreSQL recipes):

```bash
just postgres-start
just db-create keiro_compose_demo
cabal run keiro-migrate -- up --database-url "host=$PGHOST dbname=keiro_compose_demo user=$USER"
cabal run keiro-ops-http-compose-example -- --database-url "host=$PGHOST dbname=keiro_compose_demo user=$USER" --port 9092 &
curl -s http://127.0.0.1:9092/ | jq
curl -s http://127.0.0.1:9092/kiroku/health/live
curl -s http://127.0.0.1:9092/keiro/health
curl -s -i http://127.0.0.1:9092/pgmq/queues | head -1
curl -s -i -H 'Origin: http://ui.test' http://127.0.0.1:9092/keiro/health | grep -i access-control
kill %1
dropdb keiro_compose_demo
```

Expected, in order: the two-surface index; kiroku's liveness body with `alive` true;
`{"status":"ok","schema_drift":[],"mutations_enabled":false}`; `HTTP/1.1 404 Not Found`; no
output for the CORS grep (the example was started without `--allow-origin`); re-run with
`--allow-origin http://ui.test` and the grep prints exactly one
`access-control-allow-origin: http://ui.test` line. Paste the transcript into the guide.

Milestone 4, validation gates:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf id next docs/guides --profile mori/user-documentation-profile.dhall DOC
just adr-validate
just capabilities-validate
just user-documentation-validate
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
nix fmt
just verify
(cd keiro-ops-http && cabal check)
nix flake check
```

Expected: every `okf validate` prints `OK: <n> concepts`; `just verify` ends without a failing
recipe (it now builds the example because `cabal.project` enables the flag); `cabal check`
reports no packaging warning that blocks upload (a manual flag whose executable is
unbuildable by default is accepted).


## Validation and Acceptance

IR-31 lists five acceptance criteria; each maps to a named test and to a transcript:

1. Keiro's surface and kiroku-metrics' surface mounted in one process on one port, with
   `GET /kiroku/health` and `GET /keiro/...` answering byte-identically to standalone. Proven
   by "serves kiroku routes byte-identical to standalone" and "serves keiro routes
   byte-identical to standalone", and by the Milestone 3 transcript.
2. A WebSocket client connects through a prefix and the protocol works unchanged. Proven by
   "forwards a WebSocket upgrade through the prefix" (the raw path the server sees is the
   unprefixed one) and "connects a WebSocket client through the kiroku prefix" (a `snapshot`
   then a `pong`), plus the keiro case when plan 277 has landed.
3. CORS configured once serves every mounted surface, and unconfigured CORS emits no header
   anywhere. Proven by "applies CORS once" and "configures CORS once for every surface", and
   by the two CORS greps in the transcript.
4. Adding or omitting a surface changes only which prefixes answer. Proven by "refuses an
   unmounted prefix with the error envelope" and "changes only which prefixes answer when a
   surface is absent".
5. The composition code is routing only. Proven by "reshapes nothing" (no mounted route name
   appears in the module) and by a reviewer reading `Keiro.Ops.Http.Compose`, which contains
   no `KirokuStore`, no `Hasql`, and no import from any sibling metrics package.

The conventions are checked as follows: the index body and the error envelope use
`snake_case` keys (reviewed); the error code `surface_not_mounted` is documented in the guide;
CORS is list-based and off by default (asserted); the guide restates the no-authentication
posture (grep for "trusted network" in the guide).


## Idempotence and Recovery

Every step is additive and repeatable. The module, the test modules, the example, and the
guide can be deleted and recreated; nothing else references them until Milestone 4's
bookkeeping. If the `kiroku-metrics` test dependency cannot be solved against the workspace
(for example because `kiroku-cli` conflicts with another bound), record the solver output in
Surprises & Discoveries and fall back to a stub kiroku surface for Milestone 2's HTTP cases
while keeping the real-package cases marked `pendingWith` the conflict; do not loosen any
bound to make it solve. If `just verify` fails on the example because the flag stanza in
`cabal.project` was not picked up, run `cabal build all --dry-run` and confirm
`keiro-ops-http-compose-example` appears in the plan. OKF handles are allocated at creation;
if validation reports a duplicate, another plan took it: re-run `okf id next` and rename. If
plan 277 lands after this plan, add the keiro WebSocket case then (it is written as
`pendingWith` until `opsApplicationWithFeeds` exists) and switch the example to
`opsApplicationWithFeeds`; record the change in the Decision Log. When `kiroku-metrics`
0.2.0.0 becomes the pinned version, replace the hand-composed kiroku expression in the test
and the example with its exported application and record that in the Decision Log.


## Interfaces and Dependencies

`keiro-ops-http/src/Keiro/Ops/Http/Compose.hs` (new, exposed; re-exported from
`Keiro.Ops.Http`):

```haskell
module Keiro.Ops.Http.Compose
  ( SurfacePrefix,
    mkSurfacePrefix,
    surfacePrefixText,
    keiroPrefix,
    kirokuPrefix,
    shibuyaPrefix,
    pgmqPrefix,
    MountedSurface (..),
    ComposeConfig (..),
    defaultComposeConfig,
    ComposeError (..),
    renderComposeError,
    composeSurfaces,
    stripSurfacePrefix,
    composedCorsMiddleware,
  )
where

-- | One path segment, [a-z0-9-]+ and not starting with '-'. Constructor hidden.
newtype SurfacePrefix = SurfacePrefix Text
  deriving stock (Eq, Ord, Show)

mkSurfacePrefix :: Text -> Either ComposeError SurfacePrefix
surfacePrefixText :: SurfacePrefix -> Text

keiroPrefix, kirokuPrefix, shibuyaPrefix, pgmqPrefix :: SurfacePrefix   -- "keiro", "kiroku", "shibuya", "pgmq"

data MountedSurface = MountedSurface
  { prefix :: !SurfacePrefix,
    application :: !Application
  }

data ComposeConfig = ComposeConfig
  { -- | Exact origins that receive CORS headers on every mounted surface.
    -- Empty means the composed layer adds no CORS header.
    allowedOrigins :: ![Text]
  }
  deriving stock (Eq, Show)

defaultComposeConfig :: ComposeConfig   -- []

data ComposeError
  = InvalidPrefix !Text
  | DuplicatePrefix !Text
  | NoSurfaces
  deriving stock (Eq, Show)

renderComposeError :: ComposeError -> Text

-- | The composed application: root index, prefix routing, unmounted-prefix
-- refusal, and the once-only CORS middleware.
composeSurfaces :: ComposeConfig -> [MountedSurface] -> Either ComposeError Application

-- | Nothing when the request's first segment is not this prefix; otherwise the
-- request with pathInfo and rawPathInfo stripped of the prefix and every other
-- field unchanged. A single trailing empty segment is dropped before matching.
stripSurfacePrefix :: SurfacePrefix -> Request -> Maybe Request

-- | Like Keiro.Ops.Http.Cors.corsMiddleware, but adds Access-Control-Allow-Origin
-- and Vary only to responses that do not already carry the former.
composedCorsMiddleware :: [Text] -> Middleware
```

Wire contract (frozen once released, per the conventions' area 9):

```text
GET  /                      -> 200, {"surfaces":[{"prefix":<p>,"path":"/<p>"},…]} in mount order
any other method on /       -> 405 method_not_allowed, Allow: GET
<method> /<p>/<rest…>       -> forwarded to the surface mounted at <p> as <method> /<rest…>
<method> /<p>               -> forwarded as <method> /
<method> /<unmounted>/…     -> 404 {"error":{"code":"surface_not_mounted","message":…,"details":{"mounted":[…]}}}
OPTIONS preflight, allowed  -> 204 with the CORS allow headers, never forwarded
stable prefixes             -> keiro, kiroku, shibuya, pgmq
```

Consumed from plan 276 without change: `Keiro.Ops.Http.Application.opsApplication`,
`OpsHttpError`, `errorResponse`; `Keiro.Ops.Http.Config.OpsHttpConfig`,
`defaultOpsHttpConfig`, `OpsHttpServerConfig`, `defaultOpsHttpServerConfig`;
`Keiro.Ops.Http.Server.withOpsHttpServer`. Consumed from plan 277 when present:
`Keiro.Ops.Http.opsApplicationWithFeeds`, `Keiro.Ops.Http.Feed.withFeedHandle`,
`defaultFeedConfig`.

Consumed from `kiroku-metrics` 0.1.0.10 (test suite and flag-guarded example only):
`Kiroku.Metrics.Server.httpApp`, `Kiroku.Metrics.WebSocket.websocketApp`,
`Kiroku.Metrics.WebSocket.newWebSocketState`, `Kiroku.Metrics.Collector.newKirokuMetrics`,
`Kiroku.Metrics.Config.defaultConfig` and `MetricsServerConfig (..)`; from 0.2.0.0,
`combinedAppWithProviders` and `storeServerProviders` replace the hand-composed expression.

External libraries: `wai` (`Request` fields, `mapResponseHeaders`, `responseHeaders`,
`Middleware`), `http-types` (`encodePathSegments`, statuses, `methodOptions`),
`bytestring` (`Data.ByteString.Builder.toLazyByteString`), `wai-websockets`
(`websocketsOr`, tests and example), `websockets` (`runClient`, `pendingRequest`,
`requestPath`, `acceptRequest`, tests and example), `wai-extra` (`Network.Wai.Test`, tests),
`http-client` (socket-level requests, tests), all already in `keiro-ops-http`'s closure after
plans 276 and 277 except `kiroku-metrics`, which enters only the test suite and the
flag-guarded executable. Sources were read from `mori://yesodweb/wai` (wai, wai-websockets)
and `mori://shinzui/kiroku` (kiroku-metrics).
