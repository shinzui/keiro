# Changelog

All notable changes to `keiro-core` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

_No unreleased changes._

## 0.1.0.0 — 2026-07-05

Initial Hackage release.

### Breaking Changes

- Finalized the pre-release stream naming, codec, and event-stream contracts,
  including safer stream category construction and validated event-stream
  boundaries.

### New Features

- Added shared `Keiro.Codec`, `Keiro.Stream`, `Keiro.EventStream`,
  `Keiro.EventStream.Validate`, `Keiro.Integration.Event`,
  `Keiro.Snapshot.Policy`, and `Keiro.Prelude` modules.
- Added replay-safety validation helpers built on keiki's transducer validator.

### Other Changes

- Added Haddock coverage and migration documentation for validated event streams.
