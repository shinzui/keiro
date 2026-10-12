---
type: Improvement Request
title: Support atomic relational preconditions for catalog domain commands
description: >-
  Provide a supported way to enforce a consumer-owned relational precondition
  atomically with a domain command and its synchronous catalog projections, returning a typed
  refusal without committing events or bypassing rebuild and serving-revision guarantees.
timestamp: 2026-10-12T03:53:45Z
requestId: IR-53
status: accepted
origin: mori://shinzui/rei
plan: docs/plans/306-support-atomic-relational-preconditions-for-synchronous-catalog-commands.md
reviews:
  - kind: model
    reviewer: codex-author
    reviewed_at: 2026-10-11T21:01:11Z
    document_timestamp: 2026-10-11T21:01:11Z
    scope: technical-accuracy
    outcome: commented
    provider: openai
    model: gpt-6-astra
    effort: unspecified
    context: >-
      Author self-review against Keiro 2a38ee169d165c571a142cb47d08bab1e7ad7652,
      the local Kiroku transaction contract and append SQL, and exploratory
      prototype 3f9aba4e. Confirmed the public composition gap, shared catalog
      fences, and store-wide append lock cost; the selected design moves the
      guard after fence and binding validation. No new runtime tests or
      benchmarks were run, and no independent review or release approval is claimed.
---

# Improvement Request: Support Atomic Relational Preconditions for Catalog Domain Commands

## Status

Accepted for planning on 2026-10-11 following owner discussion. The selected
direction is an opt-in guarded synchronous catalog command runner, implemented
under [ExecPlan 306](../plans/306-support-atomic-relational-preconditions-for-synchronous-catalog-commands.md).
The additive runner and compiled consumer example are implemented locally.
The expanded focused PostgreSQL selection passes 36 examples, including
same-database races, fresh OCC/driver retry results, transactional rollback,
both catalog owner rebuilds, and versioned promotion in both lock orders.
The final affected full suite passes 753 examples; the fixed performance
acceptance remains tracked in the plan. These correctness results
do not establish performance readiness. Package release, publication, and
downstream adoption remain separate work. The earlier exploratory prototype
is not the accepted implementation.

## Consumer requirement

Rei needs an idempotent "ensure state note" operation under
`mori://shinzui/rei/plans/249-expose-categories-and-custom-properties-with-shared-typed-assignment-semantics`,
part of `mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`.

A note's shared identity is `(anchor type, anchor ID, property definition ID,
state ID)`. Each note nevertheless has its own note ID and aggregate stream.
Two concurrent callers can supply different candidate note IDs for the same
shared identity. The required result is one durable creation fact, one note,
and the same winning note ID returned to both callers. The winner reports a
change; the other caller reports reuse. Repeats preserve the original content,
tags, and creation metadata, including when the existing note is archived.

Reading the note index before issuing a command leaves a check/write race.
Per-stream optimistic concurrency does not exclude these two different note
streams. A unique index can prevent duplicate rows, but an ordinary constraint
exception does not provide the supported typed reuse result. The losing
creation event must roll back together with every projection effect.

Rei should continue to write one note aggregate per command. Keep only the
minimum identity-to-winning-note index synchronous; project content, tags,
display joins, search, and reporting asynchronously through a separate catalog
owner. Use separate rebuild groups where dependencies allow, without a foreign
key from the identity index to an async row that may not exist yet. The index is
command authority and must fail closed while unavailable, even though events
can reconstruct it. Archive retains its mapping; define deletion, re-anchoring,
and legacy migration policies explicitly. An immediate reader can use a bounded
post-commit position wait; timeout means committed with view pending. The
guarded runner remains planned and must not be emulated with private catalog SQL. Authorization, definition/scope validation, editor interaction,
and other external IO remain consumer preflight work.

## Existing framework behavior and gap

The original request inspected Keiro's main checkout at
`2c3a5389353d290b532cafff14122bf9ab1af79a` on 2026-10-11. Hackage's
[preferred versions](https://hackage.haskell.org/package/keiro/preferred.json)
were recorded as listing 0.19.0.1 as the latest normal release; the upstream `keiro-0.19.0.1` tag
was recorded as resolving to `9b215c1121a694e49d582d9bb4e8600a3b9b446f`. Recheck the released
baseline when evaluating any implementation or adoption.

Owner evaluation also inspected current Keiro
`2a38ee169d165c571a142cb47d08bab1e7ad7652` and the local source of
`mori://shinzui/kiroku/packages/kiroku-store`. Kiroku's documented
`appendToStreamTx` contract updates the store's global `$all` row, holding its
lock until the surrounding transaction commits or rolls back. Its transaction
runner uses `ReadCommitted`. A subsequent guard statement can therefore see
the committed winning append after waiting for that lock, provided every live
writer affecting the invariant participates in the same store protocol and the
checked state is maintained synchronously. This is an explicit dependency
contract to verify and test, not a guarantee supplied by an arbitrary SQL
callback. Catalog group `FOR SHARE` locks protect rebuild lifecycle; they do
not themselves serialize competing ordinary writers.

In `keiro/src/Keiro/Command.hs`,
`runDomainCommandWithSqlEventsControlled` already supports a typed transaction
rollback through `SqlTransactionDecision`. An accepted prospective append can
be rolled back without returning a fabricated successful domain outcome.

In `keiro/src/Keiro/Projection.hs`,
`runDomainCommandWithCatalogProjections` combines that mechanism with rebuild
group fencing and catalog delivery. Its `applyCatalogProjectionsTx` helper is
private and selects either ordinary handlers or the active serving revision's
physical targets and delivery handlers. The public catalog runner does not
accept a consumer-owned transactional precondition.

Consequently, a consumer can use the controlled SQL runner or the catalog
runner, but has no supported public composition of the relational check with
the catalog's existing delivery semantics. Copying private catalog SQL or
reassembling projection delivery in Rei would make the consumer responsible
for framework behavior that belongs in Keiro.

## Requested change

Add an opt-in sibling of `runDomainCommandWithCatalogProjections` for one
aggregate's synchronous (inline) catalog projections. It accepts a bounded
consumer-owned transactional precondition and returns a distinct typed refusal.
Asynchronous projection workers, multi-stream commands, and a general relational
constraint engine are outside this change.

The selected transaction order is: evaluate the domain command; tentatively
append its accepted event batch; acquire and validate the existing catalog
fences and resolve serving bindings; run the precondition; apply the ordinary
catalog inline handlers only on success; then commit. A refusal condemns the
transaction and returns no committed command result. Catalog mismatch retains
its current early check. Selected domain rejection and no-op open no append
transaction and run neither the guard nor catalog handlers.

Factor the private catalog helper into fence/binding resolution and application
of those same resolved bindings. Share delivery internals with existing runners
without adding SQL statements or lock acquisitions to callers that do not opt
in. Do not export a bypass around catalog fencing or duplicate revision dispatch.

The callback is conceptually `context -> Transaction (Either refusal ())`.
The framework-owned context exposes the locked groups' serving revision and
physical targets through public typed bindings, so a guard reading a versioned
target can query the same serving generation that receives the accepted batch.
A guard that does not need bindings can ignore the context. Consumer SQL stays
consumer-owned and must be indexed, bounded, and compatible with the selected
revision. It must not inspect private framework tables, read a lagging async
projection as its authority, or fall back to a retired generation.

Use Kiroku's existing append serialization initially, with no additional global
lock or isolation-level change. Rei's identity lookup includes archived notes
and returns the committed winner's ID as its typed refusal payload. Rei maps
that specific payload to reuse and retains its unique index as additional
protection. Other faults must never be translated into duplicate reuse.

The supported contract should specify:

1. How the invariant is serialized across commands targeting different streams.
   Merely running an ordinary SELECT in a transaction is insufficient; identify
   the supported lock, isolation, or conditional-write mechanism and prove it
   with independent database connections.
2. Which accepted command attempts execute the precondition, how optimistic
   retries re-evaluate it, and how it interacts with rebuild fences and serving
   revisions. Domain rejection and no-op must retain their current side-effect
   behavior. External IO must remain outside the transaction callback.
3. That a refused precondition rolls back the entire prospective event batch
   and its transactional effects, applies no catalog handlers, and returns a
   typed result separate from command failures and committed acceptance.
4. How the consumer obtains an authoritative winning identity after a duplicate
   refusal and reports reuse without claiming that the losing event committed.
5. That operational faults, codec failures, unmatched commands, catalog mismatch,
   and rebuild fences retain their existing distinctions. Refusal details must
   not become telemetry labels or expose note identity/content unintentionally.
6. That guard evaluation happens after all required catalog fences and serving
   bindings are validated. An unavailable catalog wins over a potential duplicate
   refusal; no guard queries a target while an offline rebuild can clear it.
7. That the command guard is not re-executed during projection replay. Committed
   creation events carry the winning identity needed to rebuild the note index.
   All live writers changing that identity participate in the documented
   serialization protocol; arbitrary external SQL is not covered.

## Performance contract

The post-append guard extends the time Kiroku's global `$all` row is locked.
Its cost can delay unrelated event appends in the same store, even when the
guard only reads one row. Refused attempts also perform tentative append work
before rollback. This design must not be described as zero-cost or as imposing
contention only on callers sharing the same note identity.

Existing unguarded callers must acquire no additional locks and execute no
additional SQL. Guarded examples use a bounded indexed identity lookup, perform
no external IO, and do not scan or loop over unbounded data. Preserve existing
timeout/error behavior. Distinguish Keiro's bounded optimistic-concurrency
retry loop from database-driver transaction retries; do not claim that the
former bounds the latter.

Require warmed, repeated comparisons of ordinary commands, successful guards,
duplicate-heavy guards, and mixed ordinary/guarded traffic in the same store.
Record attempt throughput, committed event throughput, ordinary-command p95
and p99 latency, and global append lock wait/hold evidence. ExecPlan 306 defines
the initial workload and regression budgets before measurements are collected.
A failed budget requires an explicit design revision or owner-reviewed budget
change; correctness tests alone do not establish release readiness.

## Acceptance

1. A PostgreSQL fixture races two independent stores/connections using different
   aggregate IDs for one consumer identity. Exactly one creation event and one
   minimal identity-index row commit atomically while the rich-view worker is
   paused. Both callers obtain the same winner, with exactly one changed result.
   After catch-up, exactly one rich note contains the winner's original payload. Repeat and archived-note reuse append no facts and preserve
   first-write content, tags, and provenance.
2. Successful checks apply the full event batch and all catalog effects
   atomically. Refused checks commit no event, link, snapshot advancement,
   outbox/reactor work, or projection mutation attributable to the losing batch.
3. Selected domain rejection/no-op does not execute the precondition or catalog
   handlers. Bounded optimistic retries recheck transactional state; neither a
   stale check nor a rolled-back result is reported as committed acceptance.
4. Missing, rebuilding, failed, and mismatched catalog groups retain their
   existing outcomes. Active serving-revision delivery uses the framework's
   declared handlers and physical targets, including during revision promotion.
5. A downstream Rei example demonstrates the operation through public APIs,
   without copying private framework table/lock SQL or catalog delivery.
   Tests distinguish a duplicate identity from an infrastructure failure.
   Rich-view fencing leaves ensure available; identity-group fencing fails it
   closed. Post-commit read-your-write can return pending and later succeed
   with the same accepted receipt without reissuing the command. A refused
   attempt never supplies its rolled-back position as a freshness target.
6. A guard that would refuse is not executed when the catalog is missing,
   offline rebuilding, failed, or has an unavailable/invalid serving binding.
   A two-connection promotion fixture proves guard lookup and inline delivery
   use one protected serving revision, with no stale-generation reuse.
7. A mixed-workload benchmark meets the recorded regression budgets, including
   unrelated ordinary writers and duplicate-heavy traffic. The unguarded path
   performs no added SQL or lock acquisition. Publish measured limitations with
   the supported recipe; do not infer performance from the prototype's tests.

## Alternatives to evaluate

- The selected public guarded catalog runner reuses existing append serialization
  and catalog delivery. Its global lock duration is an explicit measured cost.
- A pre-append guard with an identity-level lock or conditional reservation is
  deferred unless measurements require it. Merely moving the SELECT before the
  append is unsafe; the alternative requires a proven common protocol for every
  relevant writer and consistent lock ordering with catalog operations.
- A documented existing-public-API recipe remains acceptable only if it can
  preserve the complete catalog contract without copying private delivery SQL.
- A shared-identity aggregate or deterministic note-stream identity in Rei.
  Evaluate historical note IDs, legacy qualifiers, editor drafts, and ownership
  consequences before requiring this consumer redesign.

This request is narrower than [IR-8](support-atomic-multi-stream-command-coordination.md):
it proposes one aggregate append guarded by consumer-owned relational state,
without deciding or appending across several aggregates. It complements
[IR-7](return-typed-domain-command-outcomes-and-rejection-details.md), whose typed
domain outcomes already exist; the missing piece is safe catalog composition.

## Evaluation deliverables

The owner decision is to plan the guarded synchronous catalog extension.
Deliver its supported public contract and Rei-shaped example, independent-
connection concurrency/rollback/fence/revision evidence, and performance
measurements under ExecPlan 306. Agree release versions, publication, and
downstream adoption separately after the evidence is reviewed.

An earlier unapproved exploratory prototype exists in an isolated checkout at
commit `3f9aba4e`. It has not been merged, pushed, tagged, or published and is
not an accepted implementation. Its existence and local test results do not
settle the design or authorize its release.
