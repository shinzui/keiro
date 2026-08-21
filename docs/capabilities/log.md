# Bundle Update Log

## 2026-08-21
* **Update**: Extend the transactional outbox with bounded terminal rejection, ordered-successor release, committed summaries, and explicit at-least-once pre-finalization recovery (plan 165).

## 2026-08-15
* **Audit**: Reconcile the catalog with the published 0.12.0.0 package set,
exported modules, release notes, user guides, focused runtime tests, DSL
conformance corpus, and commits since the initial bundle.
* **Add**: Record the independently adopted `keiro-ops` console (CAP-16),
guarded external read-model SQL contracts (CAP-17), and typed domain command
outcomes (CAP-18).
* **Add**: Split the independently versioned canonical integration-event
envelope (CAP-19) from CAP-1, with its own public module, guide, and test
evidence.
* **Update**: Mark typed projection catalogs as shipped in 0.12.0.0 and extend
CAP-6 through canonical catalog adoption, truthful freshness, resumable ordered
replay, online schema-versioned cutover, retired-generation cleanup, and bounded
targeted stream reprojection.
* **Update**: Bring the command, read-model, coordinator, workflow, DSL, and
telemetry records up to the 0.12 public APIs; add a published-package coverage
table and remove the obsolete sharding documentation-gap note.
* **Fix**: Replace stale or inaccurate examples and guarantees for codec
versions, snapshot compatibility, command arguments, inbox/outbox transactions,
dead-letter replay, work-queue runners, and legacy migration tooling.

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
