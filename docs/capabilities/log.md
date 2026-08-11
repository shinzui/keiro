# Bundle Update Log

## 2026-08-11
* **Update**: Extend CAP-6 evidence through required candidate-Language-5 checkpoint policy, direct generation, replay-safe validation, and identity-preserving stop-the-world diff classification

## 2026-08-08
* **Add**: Adopt the shared OKF capability profile (okf-profiles
`coordination/capabilities` v0.9.0) and author the initial keiro capability
catalog: 15 capabilities (CAP-1 … CAP-15) derived from packages, exported
modules, the `keiro/test/Main.hs` suite, the `keiro-dsl` conformance suites,
the `jitsurei` worked examples, the user guides, and release history. All
records are `shipped`/`experimental` reflecting keiro's uniform pre-1.0
compatibility policy; `since` is `0.1.0.0` for every capability present in the
initial Hackage release (2026-07-05) and `unreleased` for CAP-6 (typed
projection catalogs), which exists only on the default branch.
* **Note**: The evidence requirement surfaced sharded subscription workers
(`Keiro.Subscription.Shard*`) as public and well-tested but without a
conceptual adoption guide, and `keiro-test-support` as consumer-facing test
infrastructure rather than a runtime capability; both are recorded under
"Deliberately excluded" in `index.md` rather than as capability records.
