# Changelog

## [Unreleased]

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

### Bug Fixes

- Fail oversized workflow continuations explicitly instead of returning a cursor
  that the next request cannot decode.

### Performance

- Reuse at most 32 header presentations / 1 MiB charged data after exact current-row checks, retaining live schema verification and host response caps.

- Reuse bounded pure read parsing and the RTS deadline manager. Retain a fresh
  live schema check for every admitted operation and hold admission through
  response delivery.

### New Features

- Bounded workflow routes and typed cursor/size/generation failures; pure validation precedes schema scans.

### Added

- Bounded HTTP transport for the supported operational command tree.
