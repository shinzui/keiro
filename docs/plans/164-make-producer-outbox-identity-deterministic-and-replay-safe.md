---
id: 164
slug: make-producer-outbox-identity-deterministic-and-replay-safe
title: "Make producer outbox identity deterministic and replay-safe"
kind: exec-plan
created_at: 2026-07-31T14:46:36Z
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-15T17:40:35Z
      mode: "update"
      note: "Reconcile outstanding producer replay identity work with current implementation and related completed plans"
---

# Make producer outbox identity deterministic and replay-safe


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Status refreshed 2026-09-15 against commit `edd142c1`: implementation remains outstanding.
The existing outbox keeps a persisted message ID stable across publication retries; this plan
adds stable identity when the producer maps and enqueues the source event again. Those are
different retry boundaries.

After this change, replaying the same private source event through an `IntegrationProducer` derives
the same outbox ID and integration message ID every time. A transaction rollback, subscription
redelivery, process restart, or deliberate replay inserts at most one semantically identical row.
If the producer mapping changes and the same deterministic identity would now carry different
content, enqueue returns a typed conflict instead of silently accepting, dropping, or overwriting
the drift.

The behavior is visible in a database test that enqueues the same recorded event before and after a
rollback/restart: both attempts report one identity and the table contains one row. Mutating the
draft under that same event reports `ProducerIdentityConflict` and leaves the original row intact.


## Progress


- [x] (2026-09-15) Reconcile the plan with current source, tests, documentation, ADRs, and git
  history. All four implementation milestones remain open; related shipped work is recorded below.

- [ ] Milestone 1: define and freeze a versioned pure producer identity derivation contract.
- [ ] Milestone 2: replace fresh per-attempt IDs in the canonical producer helper and return typed
  inserted/duplicate/conflict outcomes from enqueue.
- [ ] Milestone 3: make the database statement distinguish identical replay from identity drift and
  preserve ordering/source provenance.
- [ ] Milestone 4: add rollback, concurrency, replay, compatibility, documentation, and full
  validation coverage.


## Surprises & Discoveries


The July observations about Keiro remain reproducible by source inspection on 2026-09-15.
The downstream observation is retained as historical evidence and was not re-audited.

- 2026-07-31: `enqueueProducerEventTx` receives a caller-supplied `OutboxId` but calls
  `mintIntegrationEvent`, which generates a fresh TypeID message ID on every attempt. The table's
  idempotency constraint is `(source, message_id)`, while `outbox_id` is also the primary key. A
  retry with stable outbox ID and fresh message ID can therefore hit the primary key instead of
  coalescing on the documented constraint.
- 2026-07-31: The insert uses `ON CONFLICT (source, message_id) DO NOTHING` and returns no outcome,
  so even a stable identity would currently hide a changed payload under the same key.
- 2026-07-31: `mori://shinzui/kotei/plans/32-publish-configurable-kotei-v1-integration-events`
  explicitly bypasses the canonical helper to construct deterministic message IDs. This is audit
  evidence that the missing capability already forces downstream workarounds.

- 2026-09-15: `keiro/src/Keiro/Outbox.hs` still calls `mintIntegrationEvent` from
  `enqueueProducerEventTx`; the latter accepts a caller-owned `OutboxId` and returns
  `Eff es (Tx.Transaction ())`. It has no recorded-event or emission-index argument.
  `keiro/src/Keiro/Outbox/Schema.hs` still uses `ON CONFLICT (source, message_id) DO NOTHING`
  with `D.noResult`. No `Keiro.Outbox.Identity` module or `ProducerIdentityConflict` result exists.
- 2026-09-15: `keiro/test/Main.hs` tests configured TypeID prefixes, explicit `draftToEvent`
  identity, and distinct fresh UUIDv7 outbox IDs. It does not call `enqueueProducerEventTx`.
  These tests do not establish producer rollback/replay identity or drift detection.
  `docs/user/outbox.md` explicitly says the canonical producer mints a fresh ID per attempt.
- 2026-09-15: Related implementations have different scope. Plan 202 and ADR-24 freeze
  workflow/process-manager deterministic IDs; plan 165 and ADR-37 implement terminal publication
  rejection (completed in `a2c93027`). Neither changes producer enqueue identity. This plan's
  file history contains only its original planning commit `ce0c3028` before this refresh.
- 2026-09-15: Draft comments claim source provenance defaults from `RecordedEvent`, but
  `draftToEvent` only copies draft fields and the helper cannot receive the recorded event.
  Milestone 2 must implement that defaulting, not merely preserve the comment.


## Decision Log


- Decision: Keep all four implementation milestones open after the status audit. Reuse existing
  deterministic-ID guidance and preserve shipped terminal rejection behavior during implementation.
  Rationale: Current source directly demonstrates fresh producer IDs and untyped conflict handling;
  completion of adjacent replay or publication features is not evidence for this enqueue contract.
  Date: 2026-09-15

- Decision: Derive identity from a domain-separated, length-prefixed tuple of algorithm version,
  producer source, producer name, source event ID, and emission index.
  Rationale: Source event ID alone collides when more than one producer or future multi-emission
  mapping observes the same event. Explicit version/domain separation makes the contract evolvable
  and resistant to tuple-concatenation ambiguity.
  Date: 2026-07-31

- Decision: Produce both a UUID `OutboxId` and an opaque Text message ID from the same canonical
  key using documented deterministic algorithms; stop describing producer message IDs as freshly
  minted TypeIDs.
  Rationale: TypeID's UUIDv7 generation is intentionally fresh and time ordered. Pretending a hash
  is a valid TypeID or depending on a global generator cannot provide replay identity. Integration
  message IDs are already opaque Text at the envelope boundary.
  Date: 2026-07-31

- Decision: Enqueue returns `Inserted`, `DuplicateIdentical`, or `IdentityConflict` and compares a
  canonical content digest on conflict.
  Rationale: Idempotency should suppress only the same logical message. A changed mapper, schema,
  destination, or payload under a stable identity is operationally significant and must not be
  silently discarded.
  Date: 2026-07-31

- Decision: Keep `enqueueIntegrationEventTx` as the explicit caller-owned identity escape hatch;
  change the canonical producer helper even though its public signature is source-incompatible.
  Rationale: Existing callers that truly own an external message ID remain supported. The helper's
  current contract is unsafe, and a deprecation shim that keeps fresh IDs would preserve the bug.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening the completed
  inbox/outbox MasterPlan.
  Rationale: Replay-safe identity is a focused correction to the shipped subsystem and should have
  an independent implementation state.
  Date: 2026-07-31


## Outcomes & Retrospective


The 2026-09-15 refresh confirms this plan is still unimplemented in the current checkout.
Existing durability, persisted-message retry, explicit caller-owned envelope IDs, deterministic
workflow/router IDs, and terminal publication rejection remain useful foundations. The missing
work is pure producer identity, typed enqueue outcomes, database content comparison, and their
replay/concurrency tests and rollout documentation. Start implementation at Milestone 1.

This update changed documentation only. Validation consisted of source/test-definition inspection
and git history checks; no Haskell or database tests were run, and no new runtime acceptance is
claimed. ADR-24 and ADR-37 already hold the relevant shipped decisions; this refresh introduces
no new implemented architecture requiring an ADR edit. The producer identity ADR remains part
of Milestone 4.

## Context and Orientation


`keiro/src/Keiro/Outbox.hs` defines `IntegrationProducer`, `IntegrationEventDraft`,
`mintIntegrationEvent`, `enqueueProducerEventTx`, and the explicit `enqueueIntegrationEventTx`
escape hatch. The producer mapper receives both `RecordedEvent` and decoded private event, but the
current enqueue helper does not receive the `RecordedEvent`; callers separately generate an
`OutboxId`, and the helper mints a fresh message ID.

`keiro/src/Keiro/Outbox/Schema.hs` encodes the row. `enqueueOutboxStmt` inserts and applies
`ON CONFLICT (source, message_id) DO NOTHING`; it returns `()` and cannot distinguish insertion,
identical replay, or conflicting content. The schema has primary key `outbox_id` and unique
`(source, message_id)`. Existing source event ID/global position columns provide provenance but are
not the idempotency key.

The producer subscription/checkpoint integration and tests live in `keiro/test/Main.hs`. Telemetry
already distinguishes publish/retry/dead behavior but has no enqueue identity conflict counter.
Keiro already depends on cryptographic digest support for `ReplayDigest`; use the existing
authoritative primitives where their byte contract is suitable. If a UUID namespace function is
needed, verify its dependency source and released version through Mori before adding a bound.

Completed MasterPlan 3 introduced the inbox/outbox and chose message identity at enqueue time, but
its persisted-message identity remains stable only after enqueue. This standalone plan owns
source-event re-enqueue identity. See
[MasterPlan 3](../masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md).
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
supports surfacing identity drift at enqueue rather than later publish. A new ADR is required for
the derivation tuple/algorithm because downstream producers will persist and depend on it.
[ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
already requires length-prefixed UTF-8 fields for new deterministic derivations and forbids
renaming persisted IDs without an explicit compatibility strategy. Its existing workflow and
process-manager derivations must remain frozen.
[ADR-37](../adr/0037-outbox-publication-rejection-is-terminal-audit-truth.md) makes publication
rejection a retained terminal state with at-least-once transport callbacks. Enqueue identity
comparison must preserve that state and its audit data on replay; rejection is not an enqueue
identity conflict.

“Emission index” is zero for today's `Maybe IntegrationEventDraft` mapper and reserves stable
identity if a future mapper emits an ordered list. “Content digest” covers every delivery-relevant
envelope field except storage status/timestamps. “Identical replay” means both deterministic
identity and content digest match.


## Plan of Work


All four milestones below describe remaining work. Existing prefix validation, `draftToEvent`,
and explicit-envelope tests can be extended; they do not complete a milestone by themselves.
Retain the current rejected-publication lifecycle and its tests while changing enqueue behavior.

Milestone 1 adds a pure `Keiro.Outbox.Identity` module. Define a canonical binary encoding for the
versioned tuple using length prefixes, publish fixed test vectors, and derive a UUID outbox ID plus
an opaque lowercase message ID carrying the configured human-readable namespace. Reject empty or
invalid namespaces in `mkIntegrationProducer`. Add a content digest over source, destination, key,
event type/schema/reference, payload bytes, occurred-at, causal/correlation/trace data, attributes,
and source event provenance using canonical encodings for structured values.

Milestone 2 changes `enqueueProducerEventTx` to receive the source `RecordedEvent` and emission
index (or a `ProducerEmission` containing both), fill default source event ID/global position,
derive both IDs without `IO`, construct the envelope, enqueue it, and return a typed outcome. Remove
`freshOutboxId` from the canonical producer call path and rename/deprecate `mintIntegrationEvent`
so documentation cannot claim fresh IDs are replay-stable. Keep explicit external-envelope callers
on `enqueueIntegrationEventTx`.

Milestone 3 updates `Outbox.Schema`. The insert path must return `OutboxInserted` when it writes.
On either unique identity conflict, lock/read the existing row and compare deterministic identity
and content digest. Return `OutboxDuplicateIdentical` only when they match; otherwise return a typed
conflict containing IDs and differing field classes, never payload bytes. Add any digest/identity
schema columns through a forward migration, update both migration representations, lockfiles, and
expected schema. Concurrent identical enqueues must converge without a uniqueness exception;
concurrent different content must select one row and report conflict to the other.

Milestone 4 adds pure test vectors and PostgreSQL tests for rollback/retry, redelivery after
checkpoint failure, process restart, concurrent identical attempts, changed mapper content,
different producer names, and different source events. Add a compatibility test for
`enqueueIntegrationEventTx`, telemetry for identity conflict, public API docs, producer guide,
changelog, migration artifacts, and the identity ADR. Use Mori dependents to list consumers of
Keiro and document the source migration; this plan does not edit their repositories.


## Concrete Steps


Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
mori registry dependents shinzui/keiro --packages
cabal test keiro-test --test-options='--match=Keiro.Outbox'
cabal test keiro-test --test-options='--match=producer-identity'
cabal test keiro-migrations-test
cabal test keiro-test
cabal build all
nix flake check
```

For the new focused command, group new tests under a description containing the literal
`producer-identity`. That group does not exist at refresh time: a zero-example pass is not
acceptance. The broader `Keiro.Outbox` match covers the existing outbox regression group.

The focused test transcript must show one deterministic vector, one inserted row, identical retry,
rollback retry, concurrent duplicate, and content conflict. In each replay case the derived
`OutboxId` and `messageId` are byte-for-byte equal and the table count is one. Record the final
algorithm/version and test vectors in the ADR and replace example counts in Progress.


## Validation and Acceptance


These are pending implementation acceptance criteria, not results from the status refresh.
The current TypeID-prefix and fresh-ID tests do not satisfy deterministic replay acceptance.

1. The same producer source/name, source event ID, and emission index always produce the exact same
   outbox and message IDs across processes and platforms. Fixed vectors pin the encoding and
   algorithm version.
2. Different producer names, sources, source events, or indices produce different identities.
   Tuple component boundaries cannot collide through concatenation.
3. A rollback followed by retry, subscription redelivery, and concurrent identical attempt each
   leave one row and return `Inserted` once plus `DuplicateIdentical` thereafter; no primary-key
   exception leaks.
4. Changing destination, schema reference/version, payload, metadata, occurred time, or provenance
   under the same identity returns `IdentityConflict`, preserves the original row, emits a distinct
   metric, and does not expose payload content in errors/logs.
5. Source event ID/global position default from the supplied `RecordedEvent` before digesting.
   Caller overrides, if retained, are explicit and participate in conflict comparison.
6. `enqueueIntegrationEventTx` continues to accept caller-owned envelopes and is tested separately.
   Public docs no longer call a freshly generated per-attempt message ID stable.
7. Any schema change passes native/legacy migration parity, lock, and expected-schema checks. The
   new ADR and changelog describe the public signature/identity compatibility impact.


## Idempotence and Recovery


The following describes the target implementation; the current producer helper does not yet
provide these guarantees. Pure derivation and identical enqueue are safe to repeat. Database
comparison happens in the same transaction as insert/conflict handling, so a caller can retry the full subscription transaction.
The implementation must never update an existing row to match a changed draft; resolving an
identity conflict requires restoring the original deterministic mapper or deliberately versioning
the producer name/identity policy after reviewing downstream idempotency impact.

Migration additions are forward-only and must not rewrite released files. If algorithm test vectors
change during implementation, increment the derivation version before any release and update this
living plan/ADR. After release, an algorithm change requires an explicit new version and migration
strategy; never alter version 1 in place.


## Interfaces and Dependencies


The current public helper takes `IntegrationProducer e`, `OutboxId`, and
`IntegrationEventDraft`, returning `Eff es (Tx.Transaction ())`. The following is the proposed
replacement, not an existing API. `Keiro.Outbox.Identity`, `Keiro.Outbox`, and
`Keiro.Outbox.Schema` must expose equivalents of:

```haskell
data ProducerEventKey = ProducerEventKey
  { sourceEventId :: EventId
  , emissionIndex :: Word32
  }

data ProducerIdentity = ProducerIdentity
  { outboxId :: OutboxId
  , messageId :: Text
  , derivationVersion :: Word16
  }

data ProducerEnqueueOutcome
  = ProducerInserted ProducerIdentity
  | ProducerDuplicateIdentical ProducerIdentity
  | ProducerIdentityConflict ProducerIdentity (NonEmpty ConflictField)

deriveProducerIdentity :: IntegrationProducer e -> ProducerEventKey -> ProducerIdentity

enqueueProducerEventTx
  :: IntegrationProducer e
  -> RecordedEvent
  -> Word32
  -> IntegrationEventDraft
  -> Tx.Transaction ProducerEnqueueOutcome
```

The exact effect wrapper may remain `Eff` if canonical digesting needs it, but identity generation
must be pure and must not call a clock, random UUID/TypeID generator, or global sequence. Reuse
Keiro's canonical JSON/digest stack only after specifying exact bytes. Any new UUID/hash dependency
must be located through Mori and verified against its authoritative released version and tag before
bounds are selected.


Revision note: Detached this plan from the completed inbox/outbox MasterPlan so it is an independent
implementation unit, 2026-07-31.


Revision note (2026-09-15): Refreshed status against current source, test definitions, documentation,
ADRs, and git history after a request to check whether this was already implemented. Kept all four
implementation milestones open, distinguished related completed work, documented the missing
provenance defaulting, and corrected focused-test instructions so an empty selection cannot be
mistaken for acceptance. No implementation or runtime validation was performed in this refresh.
