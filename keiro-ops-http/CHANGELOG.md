# Changelog

## [Unreleased]

### Bug Fixes

- Fail oversized workflow continuations explicitly instead of returning a cursor
  that the next request cannot decode.

### Performance

- Reuse bounded pure read parsing and the RTS deadline manager. Retain a fresh
  live schema check for every admitted operation and hold admission through
  response delivery.

### New Features

- Bounded workflow routes and typed cursor/size/generation failures; pure validation precedes schema scans.

### Added

- Bounded HTTP transport for the supported operational command tree.
