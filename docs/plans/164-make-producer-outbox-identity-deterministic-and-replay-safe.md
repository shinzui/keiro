---
id: 164
slug: make-producer-outbox-identity-deterministic-and-replay-safe
title: "Make producer outbox identity deterministic and replay-safe"
kind: exec-plan
intention: intention_01m2k2qqk4etts8x4aek5zz488
created_at: 2026-07-31T14:46:36Z
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-15T17:40:35Z
      mode: "update"
      note: "Reconcile outstanding producer replay identity work with current implementation and related completed plans"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-15T17:46:56Z
      mode: "implement"
      note: "Implement versioned producer identity and locked replay content comparison"
---

# Make producer outbox identity deterministic and replay-safe


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Completed 2026-09-15 from baseline commit `20f2f378`, with all four milestones,
full regression/build checks, and the added performance acceptance validated.
The existing outbox keeps a persisted message ID stable across publication retries; this plan
adds stable identity when the producer maps and enqueues the source event again. Those are
different retry boundaries.

After this change, replaying the same private source event through an `IntegrationProducer` derives
the same outbox ID and integration message ID every time. A transaction rollback, subscription
redelivery, process restart, or deliberate replay inserts at most one semantically identical row.
If the producer mapping changes while the original row is retained, and the same deterministic
identity would now carry different content, enqueue returns a typed conflict instead of silently accepting, dropping, or overwriting
the drift.

The behavior is visible in a database test that enqueues the same recorded event before and after a
rollback/restart: both attempts report one identity and the table contains one row. Mutating the
draft under that same event reports `ProducerIdentityConflict` and leaves the original row intact.


## Progress


- [x] (2026-09-15) Reconcile the plan with current source, tests, documentation, ADRs, and git
  history. This was the pre-implementation audit; related shipped work is recorded below.

- [x] (2026-09-15) Milestone 1: define and freeze a versioned pure producer identity derivation contract.
- [x] (2026-09-15) Milestone 2: replace fresh per-attempt IDs in the canonical producer helper and return typed
  inserted/duplicate/conflict outcomes from enqueue.
- [x] (2026-09-15) Milestone 3: make the database statement distinguish identical replay from identity drift and
  preserve ordering/source provenance.
- [x] (2026-09-15) Performance acceptance added at user request: matched publisher medians
  +3.29%, +0.89%, and -0.54%; fresh bulk +3.22% and per-event +2.66% in the final guard run.
  Both 10% fresh-write guards passed. Raw samples, preliminary failures, workload corrections,
  and limits are retained in `keiro/bench/results/producer-identity-v1/README.md`.
- [x] (2026-09-15) Expanded focused tests: 18 examples, 0 failures (2.9789 seconds);
  outbox/Kafka regression selection: 62 examples, 0 failures (12.9049 seconds).
- [x] (2026-09-15) Migration parity/history/schema regression: 36 examples, 0 failures
  (15.6999 seconds). No migration or dependency-bound changes were necessary.
- [x] (2026-09-15) Full Keiro suite: 676 examples, 0 failures (159.1468 seconds).
- [x] (2026-09-15) Milestone 4: add rollback, concurrency, replay, compatibility, documentation, and full
  validation coverage. `cabal build all` passed; `nix flake check` passed both native
  aarch64-darwin checks (pre-commit and treefmt). Other architectures were not executed.
- [x] (2026-09-15) ADR distillation complete in ADR-42; strict validation passes for all 42 ADRs
  and 25 user-documentation concepts. Updated API reference and inbox/outbox guidance.


## Surprises & Discoveries


- 2026-09-15 implementation: The original 15 focused producer tests pass against PostgreSQL,
  including restart (close/reopen store), rollback/redelivery, concurrent identical and changed
  attempts, all content classes, and rejected-row preservation. Fresh insertion remains one
  statement and does not compute a content digest. The explicit escape hatch retains its original
  SQL statement and result type. The expanded 18-test producer group and 44 existing outbox/Kafka tests now pass
  together: 62 examples, 0 failures in 12.3877 seconds.
- PostgreSQL round trips truncate sub-microsecond occurrence precision. Normalization before
  insertion avoids a false conflict on identical replay. The existing broad MIME parser also
  normalized raw stored content types; outbox row decoding now preserves exact MIME text so
  comparison and publication do not lose parameters. Empty and JSON-null attributes are distinct.
- A first publisher benchmark invocation used Tasty's one-second test timeout, which aborted
  all three workloads without valid samples. It is discarded; completed before/after runs use
  a larger timeout and sequential benchmark execution.


The following observations describe the pre-implementation audits in July and September.
They are superseded by the implemented source above. The downstream observation remains
historical evidence and was not re-audited.

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


- Decision (2026-09-15 performance acceptance): Add a same-process 10% fresh-write comparison
  guard for bulk and per-event transactions to `just bench-regression`, tighter than the existing
  25% cross-run benchmark guards. Investigate crossings with matched preparation boundaries and
  tighter sampling, and retain failed exploratory samples. The final measured overhead is about
  3%, not literally zero; shared-machine variation and large-table/payload limits are explicit.
  Identity encoding now uses one builder and exact envelope equality avoids unnecessary canonical
  encoding on identical replay. Both optimizations preserve every frozen identity/content vector.

- Decision (2026-09-15 implementation): Compare canonical content reconstructed from locked
  existing envelope columns; do not persist a redundant digest column. No schema migration is
  needed. Use a conflict-agnostic insert followed by a separate locking read so READ COMMITTED
  sees a concurrently committed winner. Retry if sent-row GC removed the winner between statements.
  Producer timestamps are truncated to PostgreSQL microsecond precision before insertion/digesting.
  Replay suppression lasts while the row is retained; after sent-row GC the deterministic wire ID
  still supports downstream deduplication, but outbox re-publication is possible.


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


All four milestones and the user-added performance acceptance are complete. Canonical producer
enqueue now derives frozen source-event identities, defaults provenance, and returns typed
inserted/duplicate/conflict outcomes. Retained content and publication audit state are preserved;
no schema migration or dependency-bound change was needed. Explicit envelope enqueue remains
compatible. The canonical helper is source-incompatible, and historical random IDs require the
cutover described in the user guide and ADR-42.

Validation passed 18 focused examples, 62 outbox/Kafka examples, 676 examples in the full Keiro
suite, and 36 migration examples. The focused/outbox examples are subsets of the full suite and
must not be added to its count. `cabal build all` succeeded. `nix flake check` passed its two
native aarch64-darwin checks; other architectures were not run. Strict ADR and user-documentation
validation also passed. Existing unrelated working-tree documentation edits were preserved.

The performance investigation found avoidable encoding allocations and an exploratory benchmark
preparation mismatch. One-buffer tuple encoding and an exact-envelope-equality shortcut preserve
the frozen vectors while reducing unnecessary work. Corrected, tighter fresh-write comparisons
passed the 10% guards at +3.22% bulk and +2.66% per-event overhead; matched publisher medians were
within 3.4%. These are small measured local costs, not proof of zero overhead or a production SLA.
All valid preliminary samples, including guard failures, remain in the committed benchmark evidence.

ADR-42 holds the durable contract: exact version-1 derivation, retained-content comparison,
post-transaction conflict telemetry, schema-free storage, historical-ID cutover, and bounded
retention guarantees. Transient benchmark setup and timing evidence stay with this plan and its
benchmark artifacts. Implementation and performance work were committed in `3cdbe90a` and
`844d3062`; this final revision records validation and closes the plan.

## Context and Orientation


`keiro/src/Keiro/Outbox.hs` owns the producer configuration, draft, pure
`deriveProducerIdentity` adapter, and `enqueueProducerEventTx`. The helper now receives the
recorded event and a `Word32` emission index, fills missing provenance, normalizes time to
microseconds, and returns a `Tx.Transaction ProducerEnqueueOutcome`. `freshIntegrationEvent`
is the explicitly fresh TypeID escape hatch; the former `mintIntegrationEvent` name is deprecated.
`enqueueIntegrationEventTx` preserves caller-owned envelopes and its original SQL behavior.

`keiro/src/Keiro/Outbox/Identity.hs` defines the frozen version-1 encoding, SHA-256/UUIDv8
identity, canonical content digest, and conflict field classes. Each tuple field is prefixed by
an unsigned 64-bit big-endian byte length. Fields are ASCII `keiro.producer.outbox`, the
version as two big-endian bytes, UTF-8 source, UTF-8 producer name, the recorded event UUID as
16 network-order bytes, and emission index as four big-endian bytes. SHA-256 hashes the tuple.
The first 16 digest bytes become a UUID with version 8 and RFC variant bits; the full lowercase
hex digest becomes `<namespace>_v1_<digest>`. Namespace is outside the hash, so changing it
conflicts with the same retained outbox UUID. The namespace must be non-empty and satisfy
TypeID prefix syntax. These bytes and the fixed vectors may not be changed in place.

For source `ordering`, name `ordering-integration-producer`, source event UUID
`00000000-0000-0000-0000-000000000001`, index zero, and namespace `msg`, the outbox UUID is
`61dd62b4-bbfe-81ce-9634-6ce6afd48517` and message ID is
`msg_v1_61dd62b4bbfef1ce56346ce6afd485172774bc060102e5cf455e39bd0edfa84b`.
The test suite also pins a canonical content digest independently of storage state.

`keiro/src/Keiro/Outbox/Schema.hs` owns both SQL paths. Producer insertion uses
`ON CONFLICT DO NOTHING` across either unique index and returns whether it inserted. On a
collision, a separate `FOR UPDATE` statement reads rows matching either identity in UUID order.
This sees a concurrent winner at READ COMMITTED, which the Kiroku runner uses. If GC removed
that row between statements, insertion retries. Canonical comparison includes identity, routing,
event schema/reference and raw MIME text, exact payload bytes, microsecond occurrence time,
causal/trace metadata, structured attributes, and source provenance. Exact envelope equality
short-circuits encoding; otherwise comparisons use RFC 8785 canonical bytes per field class.
The digest is diagnostic, not a substitute for equality. No redundant column or migration is needed.

`keiro/test/Main.hs` contains the `Keiro.Outbox producer-identity` group and existing outbox/Kafka
regression groups. Tests include actual checkpoint-row rollback, close/reopen store replay,
concurrent duplicates and drift, all content classes, explicit envelopes, null attributes, MIME
preservation, terminal rejection preservation, and post-GC re-publication with the same wire ID.
`keiro/bench/ProducerIdentityBench.hs` compares legacy and deterministic fresh writes, both in
one transaction per 1,000 messages and one transaction per event; it measures prepared replay and
pure identity derivation separately. `keiro/bench/Main.hs` retains publisher benchmarks.
`keiro/src/Keiro/Telemetry.hs` adds the unlabelled conflict counter. Call
`recordProducerEnqueueOutcome` once after the transaction runner returns, including deliberate
checkpoint rollback; no metric is emitted from inside SQL retries.

All dependency bounds remain unchanged. Mori located the existing SHA-256, UUID, TypeID, and
transaction implementations before use. No new dependency or compatibility workaround was
chosen. The pure digest stack reuses `Keiro.ReplayDigest` and existing package primitives.

`mori registry dependents shinzui/keiro --packages` identified consumers at
`mori://shinzui/danwa`, `mori://shinzui/kanmon`, `mori://shinzui/kawa`,
`mori://shinzui/keiei`, `mori://shinzui/keiro-runtime-docs`,
`mori://shinzui/keiro-runtime-jitsurei`, `mori://shinzui/keiro-runtime-patterns`,
`mori://shinzui/keiro-syntax`, `mori://shinzui/kikan`, `mori://shinzui/kioku`,
`mori://shinzui/kizashi`, `mori://shinzui/kotei`, `mori://shinzui/meibo`,
`mori://shinzui/mori`, `mori://shinzui/mori-app`, `mori://shinzui/rei`, and
`mori://shinzui/shikigami`. This is dependency discovery, not a claim that each calls this helper.
Their repositories are outside this change. Callers must replace the old supplied-outbox-ID/outer
`Eff` preparation with recorded event and emission index, and handle the typed result. Historical
random IDs need a drained checkpoint cutover or an application-owned mapping before old events
are replayed under the new policy; there is no automatic identity bridge.

[MasterPlan 3](../masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md)
introduced persisted-message retry identity. This plan adds source-event re-enqueue identity.
[ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) motivates
enqueue-time drift detection. [ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
requires UTF-8 and frozen persisted derivation; existing workflow/process-manager IDs are unchanged.
[ADR-37](../adr/0037-outbox-publication-rejection-is-terminal-audit-truth.md) preserves terminal
publication truth. [ADR-42](../adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md)
records the new producer contract, including cutover and retention limits.

“Emission index” is zero for today's single-draft mapper and reserves stable identity for future
ordered multi-emission mappings. “Identical replay” means the same identity and canonical content.
Outbox suppression lasts while its row remains retained; after sent-row GC, stable wire identity
supports downstream deduplication but cannot prevent re-publication by the outbox.


## Plan of Work


Milestone 1 defines pure identity and content representation in `Keiro.Outbox.Identity`, exposes
the module, validates namespaces, and pins independent identity/content vectors. Its observable
acceptance is exact vector stability plus separation of source/name/event/index, tuple boundaries,
and non-ASCII UTF-8 inputs in the `producer-identity` group.

Milestone 2 replaces the canonical helper signature, supplies recorded-event provenance defaults,
and returns inserted/duplicate/conflict outcomes directly in the transaction. It renames the fresh
helper and preserves the explicit envelope API. Acceptance is an inserted row followed by an
identical typed duplicate, with the stored IDs and defaulted source fields unchanged.

Milestone 3 separates fresh insertion from locked conflict comparison through both unique indexes.
No schema addition is needed because stored envelope columns are authoritative. Concurrent
identical writers converge; different content returns field classes without overwriting the row.
Acceptance includes both unique-key collision routes, concurrency, and unchanged ordering,
publication status, attempt counts, timestamps, and rejection audit data.

Milestone 4 completes checkpoint rollback/redelivery, restart, retention, compatibility, metadata,
and telemetry coverage; updates public docs, changelog, and ADR-42; and runs full regression,
migration, build, and flake checks. The user added performance acceptance during implementation:
retain reproducible old/new publisher samples, compare fresh enqueue under matching transaction
and preparation boundaries, measure replay overhead, and investigate sustained regressions. The
producer benchmark enforces a 10 percent fresh-write guard against its same-process legacy
reference for both batching styles. Measurements are local evidence, not a production latency SLA.


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
cabal bench keiro-bench --benchmark-options='-p producer-identity -j1 --time-mode wall --hide-progress --stdev 1 --timeout 120s +RTS -N2 -RTS'
```

For the new focused command, group new tests under a description containing the literal
`producer-identity`. Its expanded group contains 18 examples; a zero-example pass is not
acceptance. The broader `Keiro.Outbox` match covers the existing outbox regression group.

Performance commands, machine/compiler details, all raw CSV cohorts, and a before/after table
are retained in [the benchmark evidence](../../keiro/bench/results/producer-identity-v1/README.md).
Publisher tests use 2,000 one-KiB messages; producer tests use 1,000. A detached old executable
from `20f2f378` supplies the publisher baseline. The same-process producer reference retains the
old fresh-ID recipe and explicit insert SQL. On the Apple M1 Max with GHC 9.12.4 at `-O1`, the
final guarded fresh batches measured 84.33 versus 87.05 ms; individual transactions measured
126.70 versus 130.07 ms. Pure derivation measured a 1.03-microsecond median, and a fresh batch
plus one prepared replay measured a 436.95-ms median. These are local evidence, not an SLA or
proof of behavior for large retained tables or much larger payloads.

The focused test transcript must show one deterministic vector, one inserted row, identical retry,
rollback retry, concurrent duplicate, and content conflict. In each replay case the derived
`OutboxId` and `messageId` are byte-for-byte equal and the table count is one. Record the final
algorithm/version and test vectors in the ADR and replace example counts in Progress.


## Validation and Acceptance


Performance acceptance also requires local before/after publisher measurements and same-process
legacy/new producer enqueue benchmarks with the same payloads and transaction batching. Benchmark
identity derivation separately and report duplicate replay overhead honestly: its locked content
read adds correctness work absent from the old silent suppression. Use repeated wall-time samples,
consider run-to-run noise, and investigate any sustained slowdown above 10 percent on comparable
fresh-write/publisher paths. Do not trade away drift detection to improve a benchmark.


These acceptance criteria drive implementation validation; measured results are in Progress
and Outcomes & Retrospective.
The current TypeID-prefix and fresh-ID tests do not satisfy deterministic replay acceptance.

1. The same producer source/name, source event ID, and emission index always produce the exact same
   outbox and message IDs across processes and platforms. Fixed vectors pin the encoding and
   algorithm version.
2. Different producer names, sources, source events, or indices produce different identities.
   Tuple component boundaries cannot collide through concatenation.
3. Rollback leaves no row or checkpoint advancement; its transaction-local result may be
   `ProducerInserted`. The committed retry returns `ProducerInserted`, and later redelivery returns
   `ProducerDuplicateIdentical`. Concurrent identical attempts leave one row, one inserted result,
   and one identical duplicate; no primary-key exception leaks.
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


The implemented producer helper provides these guarantees while rows remain retained. Pure derivation and identical enqueue are safe to repeat. Database
comparison happens in the same transaction as insert/conflict handling, so a caller can retry the full subscription transaction.
The implementation must never update an existing row to match a changed draft; resolving an
identity conflict requires restoring the original deterministic mapper or deliberately versioning
the producer name/identity policy after reviewing downstream idempotency impact.

Migration additions are forward-only and must not rewrite released files. If algorithm test vectors
change during implementation, increment the derivation version before any release and update this
living plan/ADR. After release, an algorithm change requires an explicit new version and migration
strategy; never alter version 1 in place.


## Interfaces and Dependencies


The pre-implementation public helper took `IntegrationProducer e`, `OutboxId`, and
`IntegrationEventDraft`, returning `Eff es (Tx.Transaction ())`. The following describes the implemented replacement. `Keiro.Outbox.Identity`, `Keiro.Outbox`, and
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

The implemented helper returns `Tx.Transaction` directly. Identity generation is pure and does
not call a clock, random UUID/TypeID generator, or global sequence. Reuse
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


Revision note (2026-09-15 implementation): Added intention tracking, implemented milestones 1–3,
recorded initial PostgreSQL evidence, and added performance acceptance at the user's request.
Content comparison uses existing authoritative columns, so no redundant digest migration is needed.


Revision note (2026-09-15 validation): Completed replay/checkpoint and migration acceptance,
added allocation-preserving performance optimizations, recorded matched benchmark evidence and
a repeatable 10% guard, and reconciled the plan's context and work sections with implemented APIs.


Revision note (2026-09-15 completion): All milestones and performance acceptance passed. Recorded
full test/build/native-flake evidence, completed ADR distillation, updated public API/inbox guidance,
and documented measured overhead and compatibility/retention limits without claiming zero cost.
