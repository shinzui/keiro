# Changelog

All notable changes to `keiro-dsl` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

_No unreleased changes._

## 0.1.0.0 — 2026-07-05

Initial Hackage release.

### Breaking Changes

- Renamed the typed-spec file extension from `.kdsl` to `.keiro` before the first
  public release.

### New Features

- Added grammar, parser, pretty-printer, validator, diff engine, scaffold
  generator, harness emitter, and CLI for typed `.keiro` service specs.
- Added aggregate, process manager, durable timer, integration contract, inbox,
  publisher, PGMQ workqueue, workflow, and operation nodes.
- Added configurable module placement, build-wiring manifests, self-firewall
  checks, post-scaffold reports, per-iteration ergonomics, and `new <kind>`
  starter skeletons.
- Generated validated event streams compatible with Keiro's command boundaries.

### Bug Fixes

- Tolerated formatter comma style in scaffold conformance tests.
