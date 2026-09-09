---
type: Improvement Request
title: Preserve read-model query consistency across rebuild lifecycle transitions
description: >-
  Define and verify the consistency of native read-model queries when schema/liveness
  validation, freshness waits and SQL execution overlap projection rebuilds or promotion.
timestamp: 2026-09-09T02:57:38Z
requestId: IR-37
status: proposed
origin: mori://shinzui/koyomi
---

# Improvement Request: Preserve Read-Model Query Consistency Across Rebuild Lifecycle Transitions

## Status

Proposed for library-owner investigation. The requested contract is at the
`Keiro.ReadModel` query and projection-rebuild boundary. Whether existing APIs
already satisfy it must be established before changing the implementation.

## Existing library behavior

Source inspected at commit `250d30079a7f4a40ff86610008b08f69f91f7bb6`:

- `runQuery` selects the model's default `QueryFreshness`;
  `runQueryWithFreshness` delegates to `runValidatedQuery`.
- `runValidatedQuery` calls `ensureReadModel`, performs the freshness wait, then
  executes the model's query with `runTransaction`.
- `ensureReadModel` reads the registered model and checks version, shape hash and
  `Live` status. A non-live model yields `ReadModelNotLive`.
- `beginGroupRebuild` locks the rebuild-group row, changes the group's state,
  marks its query registrations rebuilding and clears declared targets within
  its transaction, before replay proceeds.

See `keiro/src/Keiro/ReadModel.hs` and
`keiro/src/Keiro/ReadModel/Rebuild/Group.hs`.

## Contract to establish

Schema/liveness validation must remain meaningful for the SQL operation whose
result is returned. A query overlapping an in-place rebuild must not successfully
return cleared or partially replayed target contents as an ordinary live result.
For versioned rebuilds, define which serving generation a query observes across
promotion and how long that binding remains valid.

This is distinct from freshness: `Immediate` omits polling, while
`WaitForHead`/`WaitForPosition` wait for a cursor. Neither should implicitly promise
linearizability, and this request does not ask them to. An explicit unavailable
result during an offline rebuild is acceptable; continuous availability is not
required. A compound query needs the same contract only for models that the
library supports reading together, not arbitrary application-wide snapshots.

The concrete interleaving to investigate is: validate a live registration;
complete a freshness wait if requested; let another connection begin a rebuild
or promote a generation; then execute the original query. No independent minimal
failing reproducer is attached yet. The ordering of these calls alone is not proof
of a defect; store isolation, target binding and supported rebuild usage matter.

## Requested change and acceptance

1. Document the supported query/rebuild concurrency contract and demonstrate the
   intended public-API usage. If existing APIs already satisfy it, provide that
   guidance and regression evidence instead of adding another API.
2. Add a deterministic PostgreSQL fixture with independent reader/rebuilder
   connections and controlled interleavings around validation, freshness waiting,
   target reset/replay and promotion. Assert either a coherent permitted result
   or an explicit unavailable/stale result. Successful empty results must reflect
   actual empty data, not a partially rebuilt target.
3. If a gap is confirmed, propose the smallest library-level correction, preserving
   cursorless-model and freshness-mode semantics. Do not prescribe broad locks,
   per-read catalog scans or a new transaction API before evaluating alternatives.
4. Compare ordinary-query and concurrent-rebuild performance before and after any
   correction: query count, latency distribution, throughput and lock waits, with
   stated model/catalog sizes and concurrency. Agree an acceptable budget with
   the owner. Check scaling and the no-rebuild hot path, not only correctness.

An earlier unauthorized implementation was reverted by the owner for serious
performance problems. It is not the proposed solution; its tests establish
neither necessity nor acceptable performance. There is no quantified benchmark
claim in this request.

## Related requests and origin

[IR-22](make-read-models-safely-readable-by-out-of-process-consumers.md) addresses
external SQL readers. This request concerns the native `runQuery` execution
contract; reuse that work where applicable without conflating the two surfaces.

The motivating consumer is
`mori://shinzui/koyomi/plans/5-expose-authorized-calendar-http-apis-and-typed-clients`.
Consumer-specific identity, membership and authorization policy are outside
Keiro's responsibility. Terminal outbox recovery is tracked separately in
[IR-38](support-guarded-recovery-of-dead-outbox-deliveries.md).
