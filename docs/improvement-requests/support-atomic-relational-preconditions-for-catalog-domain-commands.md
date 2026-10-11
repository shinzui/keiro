---
type: Improvement Request
title: Support atomic relational preconditions for catalog domain commands
description: >-
  Provide a supported way to enforce a consumer-owned relational precondition
  atomically with a domain command and its catalog projections, returning a typed
  refusal without committing events or bypassing rebuild and serving-revision guarantees.
timestamp: 2026-10-11T20:40:58Z
requestId: IR-53
status: proposed
origin: mori://shinzui/rei
reviews: []
---

# Improvement Request: Support Atomic Relational Preconditions for Catalog Domain Commands

## Status

Proposed for owner evaluation and discussion before implementation. The required
behavior below is the request; the suggested API is one option for review.
Acceptance of this document must not be inferred from the existence of an
exploratory prototype. Package changes, release versions, publication, and
downstream adoption require a separate agreed decision.

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

Rei should continue to write one note aggregate per command and use its existing
catalog owner. Authorization, definition/scope validation, editor interaction,
and other external IO remain consumer preflight work.

## Existing framework behavior and gap

Inspected Keiro's main checkout at
`2c3a5389353d290b532cafff14122bf9ab1af79a` on 2026-10-11. Hackage's
[preferred versions](https://hackage.haskell.org/package/keiro/preferred.json)
list 0.19.0.1 as the latest normal release; the upstream `keiro-0.19.0.1` tag
resolves to `9b215c1121a694e49d582d9bb4e8600a3b9b446f`. Recheck the released
baseline when evaluating any implementation or adoption.

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

Evaluate a supported composition that lets a consumer check a bounded
relational invariant inside the command's PostgreSQL transaction and refuse
the prospective append before catalog projection handlers execute.

One possible interface is a domain-aware catalog runner with an additional
`Transaction (Either refusal ())` precondition and a distinct typed refusal
result. The owner should determine the API shape, the correct ordering relative
to catalog fences, and the concurrency mechanism. An equivalent existing public
recipe or a better aggregate boundary is acceptable if it satisfies the same
observable requirements and avoids private framework SQL.

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

## Acceptance

1. A PostgreSQL fixture races two independent stores/connections using different
   aggregate IDs for one consumer identity. Exactly one creation event and one
   projected note commit. Both callers obtain the same winner, with exactly one
   changed result. Repeat and archived-note reuse append no facts and preserve
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

## Alternatives to evaluate

- A public guarded catalog runner or supported controlled-transaction composer.
- A documented recipe using existing public APIs that preserves the complete
  catalog contract and provides a typed duplicate result.
- A shared-identity aggregate or deterministic note-stream identity in Rei.
  Evaluate historical note IDs, legacy qualifiers, editor drafts, and ownership
  consequences before requiring this consumer redesign.

This request is narrower than [IR-8](support-atomic-multi-stream-command-coordination.md):
it proposes one aggregate append guarded by consumer-owned relational state,
without deciding or appending across several aggregates. It complements
[IR-7](return-typed-domain-command-outcomes-and-rejection-details.md), whose typed
domain outcomes already exist; the missing piece is safe catalog composition.

## Evaluation deliverables

An owner decision on whether a library extension is needed, a supported public
contract or recipe, and concurrency/rollback/fence evidence. If a change is
approved, agree its implementation scope and release/adoption path separately.

An earlier unapproved exploratory prototype exists in an isolated checkout at
commit `3f9aba4e`. It has not been merged, pushed, tagged, or published and is
not an accepted implementation. Its existence and local test results do not
settle the design or authorize its release.
