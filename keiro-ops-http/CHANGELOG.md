# Changelog

## [Unreleased]

### Breaking Changes

- Direct `InspectionLimits` records must supply `deliveryDeadlineSeconds`; the default is 30 seconds. Nonempty confirmation bodies must be application/json, with media-type parameters permitted.

### New Features

- Expose mounted process-manager discovery as `GET /pm/types` through the shared
  command tree, preserving schema verification and transport resource limits.
  Encode discovery on demand with the same byte/deadline bounds and no response cache.

- Compose allocated inspection applications under stable `/keiro`, `/kiroku`,
  `/shibuya` and `/pgmq` prefixes with preserved raw paths, shared CORS policy
  and a flag-guarded example using released Kiroku metrics.

- Add shared `/ws` first-page feeds for workflow, timer and projection status,
  backed by the same bounded reads and encoders as polls. Drivers share the
  HTTP budget; idle handles own no wake cursor. Count/byte-bounded queues,
  in-flight accounting, overflow recovery, upgrade policy checks and scoped
  cleanup protect runtime resources. The standalone HTTP server mounts feeds.

- Add bounded projection-status pages and `projection status`, preserving the
  frozen v1 relation and complete-list compatibility API. Page keys precede
  correlated status reads; no writer index is added. HTTP feed protocol and
  canonical view definitions are available as foundations for live feeds.


- Bounded workflow routes and typed cursor/size/generation failures; pure validation precedes schema scans.


- Bounded HTTP transport for the supported operational command tree.

### Bug Fixes

- Fail oversized workflow continuations explicitly instead of returning a cursor
  that the next request cannot decode.


- Refuse malformed, null, multiple and foreign mutation origins before body, schema or command effects with `origin_not_allowed` (403). HTTP, CORS and WebSocket comparisons normalize scheme/host/effective port. No-Origin clients and empty previews remain supported; TLS proxies explicitly allow-list HTTPS.
- Nonempty unsupported confirmation media types, including chunked bodies, return `unsupported_media_type` (415).
- Bound delivery independently of computation; expire stalled response callbacks, return permits and terminate incomplete connections without a second response. Shared health admission may refuse during saturation and recovers after cancellation.
- Retain per-refresh schema verification and fresh snapshot presentation without clock-only deltas. Return `view_retiring` while zero-reference cleanup joins. Composition preserves the complete child origin authorization policy and one CORS header.
- Follow primary-key workflow pages with `wf-key2`, preserving continuation byte caps and honest filtered-query deadlines.

### Other Changes

- Reuse at most 32 header presentations / 1 MiB charged data after exact current-row checks, retaining live schema verification and host response caps.

- Reuse bounded pure read parsing and the RTS deadline manager. Retain a fresh
  live schema check for every admitted operation and hold admission through
  response delivery.

