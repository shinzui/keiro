---
type: Runbook
title: Compose Runtime Inspection Surfaces
description: Mount supported inspection applications under stable prefixes on one listener.
timestamp: 2026-10-21T03:21:33Z
docId: DOC-32
tags: [keiro, operations, http, inspection, composition]
generated:
  by: openai/codex
  at: 2026-10-21T03:21:33Z
---

# Compose Runtime Inspection Surfaces

Serve inspection on a trusted network or behind an authenticating proxy. The
server has no built-in authentication. Bind locally by default. Mutations stay
disabled unless explicitly enabled and confirmed through the owner API.

Allocate each application once during startup, then mount its returned WAI
`Application`. Stable prefixes are `/keiro`, `/kiroku`, `/shibuya` and `/pgmq`;
these names are frozen once released. Valid custom prefixes use lowercase ASCII
letters, digits and hyphens, starting with a letter or digit.

```haskell
withFeedHandle config defaultFeedConfig inspectionStore $ \feeds -> do
  http <- opsApplicationWithBudget config {Config.allowedOrigins = []}
    (handleBudget feeds) hooks inspectionStore
  let keiro = feedsMiddleware config feeds http
  app <- either (fail . show) pure $ composeSurfaces
    (ComposeConfig config.allowedOrigins)
    [MountedSurface keiroPrefix keiro, MountedSurface kirokuPrefix kiroku]
  withOpsHttpServer serverConfig app $ \server -> wait server.serverThread
```

Import `Keiro.Ops.Http.Config` qualified as `Config`,
`opsApplicationWithBudget` from `Keiro.Ops.Http.Application` and
`feedsMiddleware` from `Keiro.Ops.Http.WebSocket`; the other names are exported
by `Keiro.Ops.Http`. Use an inspection-owned store with reserved pool capacity
and SQL deadlines, as in [Serve Keiro Ops over HTTP](serve-keiro-ops-over-http.md).
The HTTP child and feeds share the handle's budget. Release the listener before
the handle and store.

For `kiroku`, allocate `newKirokuMetrics inspectionStore`, obtain
`storeServerProviders metricsConfig metrics inspectionStore`, then mount
`combinedAppWithProviders metricsConfig metrics [] providers` from released
`mori://shinzui/kiroku/packages/kiroku-metrics` 0.3.0.1. These providers allocate
no independent server thread; active sockets own their child work. Mount other
owners only through their public `Application` constructors. Released
`mori://shinzui/shibuya/packages/shibuya-metrics` 0.10.0.1 exposes
`combinedApp config master socketState dependencyChecks`. Allocate its
`newWebSocketState` once and call `shutdownWebSockets` when the host releases
that mount; validate the owner configuration as its public constructor requires.
`mori://shinzui/pgmq-hs/packages/pgmq-inspect` exists in the owner checkout but
is not yet on Hackage (2026-10-20); do not add it to a published default build.
Related upstream work is tracked by
`mori://shinzui/shibuya/masterplans/7-browser-ready-processor-inspection-and-control-surface`
and `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-3`.

Configure HTTP CORS once on the outer composition. A host passes the same
origin list to the outer composition and Keiro's `OpsHttpConfig` for the
WebSocket origin check. Pass it through Kiroku's `allowedOrigin` and
`corsAllowOrigins` for that owner's policy. The outer middleware adds only
absent HTTP CORS headers; an empty list adds none. When static console assets
are served on this same origin, no cross-origin policy is needed.

```json
{"surfaces":[{"prefix":"keiro","path":"/keiro"},{"prefix":"kiroku","path":"/kiroku"}]}
```

`GET /` returns that index in mount order; other methods return 405.
`GET /pgmq/queues` when absent returns 404 with error code
`surface_not_mounted` and the mounted prefixes in `error.details.mounted`.
No request is forwarded to an absent service. `/keiro` and `/keiro/` reach the
owner's root; `/keiro/x/` preserves its trailing slash. Encoded IDs, queries,
streamed responses and protocols retain their owner's meaning.

Sockets work at `/keiro/ws`, `/kiroku/ws/metrics` and `/kiroku/ws/events`.
See [Stream Keiro Inspection Views](stream-keiro-inspection-views.md) for the
Keiro subscription protocol and overflow recovery.

Run the example from the repository's Nix shell against a migrated database:

```bash
nix develop -c cabal run keiro-ops-http-compose-example -- --database-url "$DATABASE_URL" --port 9092
curl -s http://127.0.0.1:9092/
curl -s http://127.0.0.1:9092/keiro/health
curl -s http://127.0.0.1:9092/kiroku/capabilities
```

The workspace enables the `compose-example` flag. It is default-off for package
consumers so they do not acquire sibling metrics dependencies automatically.
The example mounts database-only hooks and disables mutations.
