---
id: 257
slug: add-targeted-per-stream-reprojection-to-catalog-operations
title: "Add targeted per-stream reprojection to catalog operations"
kind: exec-plan
created_at: 2026-08-12T23:56:37Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
master_plan: "docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md"
---

# Add targeted per-stream reprojection to catalog operations

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current. Update `docs/adr/` in the same
change when implementation changes a durable architectural boundary.


## Purpose / Big Picture

After this change an operator can repair one aggregate stream in a row-per-aggregate
projection without rebuilding the complete table. Keiro guards the stream and then takes
the rebuild group's exclusive row lock in one PostgreSQL transaction, reads the complete
retained stream inside that transaction, removes only rows owned by that stream, replays the current
serving projection revision, and backfills that projection's deduplication keys before
commit.

The request carries a positive reviewed event maximum. Keiro compares the exact locked
stream version with that maximum before acquiring the group-wide repair fence, so a
bounded page size cannot disguise an arbitrarily long writer pause.

Readers never see the delete-and-refill intermediate state because the repair is one
transaction. Keiro's guarded external readers briefly wait on the exclusive group lock;
ordinary PostgreSQL readers see either the pre-repair or post-repair snapshot. Writers
for the entire rebuild group wait for the duration of the transaction. The operation
does not change group lifecycle, mark the projection unavailable, reset a subscription
checkpoint, or rebuild unrelated streams.

This repairs isolated corruption and projection-logic defects. It cannot populate a
new table schema, repair projections whose rows combine several streams, recover history
that has been truncated or soft-deleted, or replace plan 256's schema-versioned full
rebuild.

This is EP-4 of
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`.


## Progress

- [x] (2026-08-13T22:35:58Z) External prerequisite: verified
  `lockStreamHistoryForReplayTx` and `readStreamForwardTx` in released
  `kiroku-store` 0.7.0.0 and the companion retention schema in released
  `kiroku-store-migrations` 0.3.2.0.
- [x] (2026-08-14T06:53:09Z) M1: stream-scoped catalog policy, clearing/replay contracts, validation,
  fingerprints, DSL/combinator surfaces, and serving-revision integration are complete.
- [x] (2026-08-14T06:53:09Z) M2: one-transaction runner, explicit stream-retention checks, deduplication
  backfill, revision-aware group lock, concurrency tests, and typed refusals pass.
- [x] (2026-08-14T06:53:09Z) M3: `ProjectionCatalogOperations` preview and mutation wrappers expose structured
  database-backed results without duplicating the runner.
- [x] (2026-08-14T06:53:09Z) M4: `keiro-ops rebuild reproject-stream` implements read-only preview and
  `--force` execution with human and JSON output.
- [x] (2026-08-14T07:45:54Z) M5: documentation, ADR reconciliation, changelogs,
  Jitsurei transcript, a clean committed-corpus `just verify`, and MasterPlan status
  updates are complete.
- [x] (2026-08-14T11:06:35Z) EP-5 adversarial follow-up: locked stream event-count
  admission refuses oversized work before the group fence; preview/CLI v2 expose the
  count, expected dedup claims, and reviewed maximum; clearer, decode, hard-delete, and
  backend-interruption regressions pass.


## Surprises & Discoveries

- An unguarded stream read before taking the group lock is unsound. A concurrent
  projection write could commit between the read and the repair transaction and then be
  erased by the clear step. The Kiroku stream guard, group fence, read, and target changes
  must share the transaction.
- Kiroku's current `StreamInfo` exposes `truncateBefore` directly. A count-based guess
  about completeness is both unnecessary and unable to distinguish retained suffixes
  from complete history.
- The first draft relied on handler idempotence and allowed async redelivery to execute
  the repaired events again. That contradicts ADR-31 and completed plan 258, where
  deduplication rows are correctness evidence and handler idempotence is only
  defense-in-depth.
- The operation does avoid an offline lifecycle fence, but it does not avoid a
  group-wide writer pause: `FOR UPDATE` waits for existing shared writer locks and makes
  new writers wait until the repair commits.
- Kiroku's released transaction-scoped guard returns locked `StreamInfo`, while its
  `readStreamForwardTx` returns production-ordered `RecordedEvent` values without
  running Kiroku's IO-only `decodeHook`. Keiro must perform its own catalog codec decode
  before target mutation and must not assume the connection hook ran.
- Bounded deduplication backfill is most naturally performed page-by-page during replay,
  before final stream verification. Because every later refusal condemns the enclosing
  transaction, a verifier failure still rolls back clear, replay, and dedup together;
  retaining every event ID until verification would add unbounded memory without a
  stronger atomicity guarantee.
- Candidate Language 5 cannot represent an application-owned row clearer and verifier.
  Generating a declaration would falsely imply that the DSL can infer row ownership
  from opaque SQL, so the initial stream-scoped surface remains hand-written Haskell.
- Catalog command writers append to Kiroku before their projection continuation takes
  the group's shared lock. Taking the group exclusively before the stream guard creates
  the inverse order and can deadlock an already-appended writer. Targeted repair must
  take the stream guard first, then the group fence; the guard blocks new target-stream
  appends while unrelated-stream writers are ordered by the later group fence.
- Page-bounded replay controlled heap residency but not the total time under the
  group-wide writer fence. The original request admitted an arbitrary stream, even
  though locked `StreamInfo.version` already supplies its exact event count at the only
  race-free pre-fence boundary.


## Decision Log

- Decision: Only explicitly declared row-per-stream projections are eligible.
  Rationale: Keiro cannot infer row ownership from opaque SQL, and clearing one stream
  is unsafe when rows combine several streams.
  Date: 2026-08-12
- Decision: Stream read, target clear, replay, validation, and deduplication backfill run
  in one transaction under the group's `FOR UPDATE` lock.
  Rationale: this is the smallest boundary that prevents concurrent writers and readers
  from observing or creating a lost-update window.
  Date: 2026-08-13
- Decision: Execute the persisted serving projection revision against its serving
  physical generations.
  Rationale: a bridge catalog may contain old and candidate revisions; targeted repair
  must repair what currently serves, not whichever revision appears first in memory.
  Date: 2026-08-13
- Decision: Backfill deduplication keys for every replayed event and affected async
  projection in the repair transaction, using `ON CONFLICT DO NOTHING`.
  Rationale: missing keys are repaired, existing keys remain idempotent, and later
  redelivery becomes a no-op rather than executing handlers again.
  Date: 2026-08-13
- Decision: Do not advance or reset the durable subscription checkpoint.
  Rationale: the subscription may cover unrelated streams. Advancing it to the repaired
  stream's events could skip other work; existing delivery will checkpoint normally
  after deduplicated no-ops.
  Date: 2026-08-13
- Decision: Refuse soft-deleted streams and any stream with `truncateBefore > 0`.
  Rationale: per-stream replay cannot prove complete reconstruction when retained history
  begins after the stream origin or is hidden by deletion semantics.
  Date: 2026-08-13
- Decision: The operator command follows ADR-28's preview/`--force` pattern and uses the
  embedded application catalog.
  Rationale: the operation is destructive before commit and requires compiled clearing
  and replay functions unavailable to the standalone database-only binary.
  Date: 2026-08-12
- Decision: Adopt Kiroku's stream-history guard through
  `kiroku-store >=0.7 && <0.8` and `kiroku-store-migrations ^>=0.3.2.0`.
  Rationale: 0.7.0.0 is the first release exporting the guarded transaction read and
  hard-delete lock ordering; 0.3.2.0 supplies the database objects required by the same
  store release. The current Keiro 0.6/0.3.0 minima do not guarantee this contract.
  Date: 2026-08-13
- Decision: Targeted repair uses only the transaction-scoped stream guard, not a durable
  history-retention lease.
  Rationale: the complete stream read and all target mutation commit in one transaction,
  so `lockStreamHistoryForReplayTx` supplies the exact lifetime and lock ordering. The
  renewable lease is for plan 256's long fan-in replay and would add durable lifecycle
  state without strengthening this one-transaction protocol.
  Date: 2026-08-13
- Decision: Keep stream-scoped repair out of candidate Language 5 for this iteration.
  Rationale: the checked language has no truthful representation for application-owned
  row selection and verification closures; empty generated holes would present an
  unsafe ownership claim as ordinary scaffold authority.
  Date: 2026-08-14
- Decision: Insert affected dedup keys in bounded replay pages before final verification.
  Rationale: final verification and every subsequent error condemn the same transaction,
  so the persisted outcome is identical while memory remains bounded by page size.
  Date: 2026-08-14
- Decision: Acquire the Kiroku stream-history guard before the group-exclusive repair
  fence.
  Rationale: catalog command transactions append first and take the group shared lock in
  their continuation. Matching that order prevents a stream-row/group-row cycle, while
  holding the stream guard until commit prevents a selected-stream append from entering
  between history capture and target replacement.
  Date: 2026-08-14
- Decision: Require a positive `maxEvents` on every targeted-reprojection request and
  enforce it against locked `StreamInfo.version` before the group-exclusive fence.
  Rationale: page size bounds memory per replay statement, not total application work or
  writer outage. The stream guard prevents the count from changing between admission
  and repair, while preview v2 makes the event count, expected dedup claims, maximum,
  and exact force invocation reviewable.
  Date: 2026-08-14


## Outcomes & Retrospective

The implementation now delivers the catalog policy, one-transaction runner,
database-backed operation preview/outcome, embedded CLI command, stable JSON and refusal
codes, Jitsurei repair transcript, documentation, changelogs, and reconciled ADRs.
Architecture review corrected both deduplication and lock-order semantics: repair inserts
ordinary async redelivery evidence, and the stream guard precedes the group fence to
match command writers' append-first order.

The EP-5 adversarial review then closed one high availability finding: an arbitrary
stream could previously enter the group-wide transaction because `pageSize` bounded
only each page. `maxEvents` now refuses an oversized locked stream before the group
fence. Preview v2 reports the exact event count, expected dedup claims, and reviewed
maximum; outcome v2 records the admitted maximum. Separate regressions prove a 101-event
stream with a maximum of 100 refuses without waiting behind a held group lock, supported
hard delete serializes behind the stream guard, clearer/decode/verifier failures roll
back target and dedup work, and terminating the repair backend after clear also restores
the pre-transaction state.

Focused catalog, runtime, operations, DSL projection-catalog, and Jitsurei tests pass.
The final committed-corpus acceptance command,
`JITSUREI_DATABASE=keiro_verify_mp41_ep4c_20260814 just verify`, passed 595 core,
58 PGMQ with two documented pending environment cases, 46 operations, 706 main DSL,
24 Jitsurei, and 32 migration examples; every DSL conformance executable, diagram
check, strict ADR/research/capability validation, repository policy, and the 39-entry
no-drift conformance-corpus replay also passed.


## Context and Orientation

The projection catalog lives in `keiro/src/Keiro/Projection/Catalog.hs`. ADR-26 defines
query models, physical targets, rebuild groups, and projection handlers as separate
identities. Plan 256 extends a group with projection revisions and physical target
generations. This operation always loads the group's persisted serving revision while
holding its lock and resolves the serving physical target map for that revision.

Ordinary inline and async writers take `FOR SHARE` on every affected rebuild-group row
inside the transaction that performs event append, deduplication, checkpoint, and target
SQL. The repair takes `FOR UPDATE` on one group row. PostgreSQL therefore orders the
repair against all group writers:

- writers that already hold `FOR SHARE` finish before the repair begins;
- new writers wait while the repair holds `FOR UPDATE`;
- after commit they read the same serving revision and deduplication evidence installed
  by the repair.

Plan 255's external guard also takes `FOR SHARE`, so sanctioned readers wait rather than
execute during the repair. Unguarded readers do not take the group lock, but PostgreSQL
MVCC still exposes only a transactionally complete before or after snapshot. They remain
unsupported because other rebuild paths can make raw target reads unsafe.

Kiroku's exported transaction statements must be used for stream inspection and reads.
Locate current source through `mori registry show shinzui/kiroku --full`; do not query a
private Kiroku relation. The transaction-scoped stream-history guard requested by
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-6` is available to Keiro in
released `kiroku-store` 0.7.0.0 and serializes supported lifecycle mutation with the repair.
Call `lockStreamHistoryForReplayTx` first; its locked `StreamInfo` includes the explicit
truncation boundary used by the refusal. Then page from the stream origin with
`readStreamForwardTx` inside the same Hasql transaction as target mutation. That read
deliberately bypasses Kiroku's IO-only `decodeHook`, so the catalog codec remains
responsible for application decoding.

The owning upstream implementation and durable lock-order decision are
`mori://shinzui/kiroku/plans/73-protect-replay-history-with-retention-leases-and-stream-guards`
and `mori://shinzui/kiroku/okf/adrs/concepts/ADR-7`. The companion
`kiroku-store-migrations` 0.3.2.0 release installs migration `0010`; the MasterPlan's
coordinated dependency adoption raises both direct package minima before this plan's
runtime tests run.

ADR-31 defines async deduplication as correctness state. The affected projection's
deduplication identity and event-ID extraction come from the validated catalog. Backfill
is per projection, not per subscription checkpoint. If an event is irrelevant to an
adapter but ordinary delivery would still claim its projection dedup key, targeted
repair must do the same; the implementation reuses the exact plan-258 helper/selection
semantics rather than inventing a narrower interpretation.

Relevant decisions are ADR-26, ADR-28, ADR-31, ADR-32, and ADR-34.


### Catalog contract

A projection revision opts into targeted repair only through an explicit policy whose
application functions receive the serving physical target map:

```haskell
data StreamScopedReplay = StreamScopedReplay
  { streamProjectionId :: ProjectionId
  , streamOwnedTargets :: NonEmpty TargetId
  , clearerId :: Text
  , clearerVersion :: Int
  , clearStreamRows ::
      PhysicalTargets -> StreamName -> Tx.Transaction (Either Text [StreamClearCount])
  , streamReplayId :: Text
  , streamReplayVersion :: Int
  , replayStreamEvent ::
      PhysicalTargets -> RecordedEvent -> Tx.Transaction (Either ReplayDecodeError Bool)
  , streamVerificationId :: Text
  , streamVerificationVersion :: Int
  , verifyStreamRows ::
      PhysicalTargets -> StreamName -> Tx.Transaction (Either Text ())
  , affectedAsyncDedup :: [DedupKeyId]
  , claimSite :: ClaimSite
  }
```

The policy belongs to one projection revision. Validation requires its projection to
own every target it can clear/write, requires the rebuild group and event source to
resolve one stream unambiguously, and refuses external side effects. The stable policy,
clearer, verifier, and dedup identities participate in the group slice. Function
closures do not.

The clearing function returns structured counts per target for preview/result evidence.
It must delete only rows derived solely from the named stream. Keiro cannot prove this
from arbitrary SQL; the declaration and tests are application-owned evidence. Generated
DSL helpers should make the common aggregate-ID key pattern easy without claiming it is
the only possible row key.


### Transaction protocol

The mutation executes these steps in one `runTxOnPool` transaction:

1. Call `lockStreamHistoryForReplayTx`. Refuse its typed missing/reserved result or a
   returned `StreamInfo` that is soft-deleted or has `truncateBefore > 0`. Keep this
   guard through commit.
2. Require a positive request maximum and refuse when the locked stream version exceeds
   it. This is the admission boundary and occurs before the group-wide fence.
3. Lock the group row `FOR UPDATE` and require a readable/writable serving state, no
   active rebuild, matching registered slice, and a serving revision present in the
   compiled catalog.
4. Resolve the requested projection under that revision and require
   `ReplayableStreamScoped`.
5. Execute `clearStreamRows` against serving physical targets and validate its exact
   per-target count evidence.
6. Page through the locked stream with `readStreamForwardTx` from `StreamVersion 0`
   through the locked current version, decode through the application replay closure,
   and apply every event in order. The Kiroku transaction read does not run `decodeHook`;
   any decode failure condemns the complete repair transaction.
7. Insert, page by page, the same deduplication keys ordinary async delivery would own
   for every replayed event, using `ON CONFLICT DO NOTHING`.
8. Run the stream verification hook. Failure condemns the transaction, including all
   preceding clear, replay, and dedup work.
9. Return the admitted maximum, counts, versions, target IDs, and dedup
   inserted/existing counts; commit.

The subscription checkpoint is neither reset nor advanced. The group lifecycle phase,
serving revision, serving epoch, and read/write availability columns are unchanged.


### Typed refusals

Return structured errors for at least: unknown group; slice drift; group not in an
eligible serving state; active rebuild; serving revision absent from the catalog;
unknown projection; projection outside the group; projection not stream-scoped; target
generation mismatch; missing stream; soft-deleted stream; truncated history; source or
stream mismatch; invalid or exceeded event limit; decode failure; clearer failure;
verification failure; dedup identity
absence; and transaction/lock failure. Rendering may group these, but tests pin their
constructors and stable operator codes.


## Plan of Work

### Milestone 1 — Declare stream-scoped repairability

Add the runtime policy to `keiro/src/Keiro/Projection/Catalog.hs`, including helper
constructors such as `declareStreamScopedRows`. Thread `PhysicalTargets` and
`ProjectionRevisionId` from plan 256. Extend validation, canonical preimages, inventory
rendering, and tests.

Add candidate language-5 syntax only if the declaration can be represented without
pretending to infer SQL ownership. Generated scaffolding creates clear/replay/verify
holes and wires stable identities. Otherwise keep the first surface in Haskell and
document the deliberate language omission. Apply ADR-32 prefix rules either way.

Use a fixture with two streams and two rows to prove that reordering declarations is
identity-neutral while changing clearer/verifier/dedup identity changes only the owning
group slice.

### Milestone 2 — Implement the one-transaction runner

Create `keiro/src/Keiro/ReadModel/Rebuild/Stream.hs` and re-export the supported API
through `Keiro.ReadModel.Rebuild`. Reuse group locking, serving-revision lookup,
physical-target resolution, Kiroku's `lockStreamHistoryForReplayTx` and
`readStreamForwardTx`, catalog codecs, and plan-258 dedup helpers. Do not acquire a
history-retention lease for this one-transaction operation.

Database-backed tests must prove:

- only the requested stream's row changes;
- a second stream and unrelated target remain byte-for-byte unchanged;
- a writer already in flight commits before repair and is included correctly;
- a new group writer waits and applies after repair;
- a sanctioned external reader waits, while an ordinary snapshot sees only before or
  after state;
- a forced failure after clear rolls back clear, replay, verification, and dedup;
- a request over its event maximum refuses before waiting for the group fence;
- existing dedup rows are idempotent and missing rows are backfilled;
- redelivery after commit executes no affected handler body;
- subscription checkpoints are unchanged;
- `truncateBefore > 0` and soft deletion refuse before target mutation;
- an active schema-versioned rebuild and an unavailable serving revision refuse;
- the persisted serving revision, not a candidate revision, supplies the handler.

### Milestone 3 — Add operation wrappers

Extend `keiro/src/Keiro/Projection/Catalog/Operations.hs` with structured preview and
mutation requests/results. Preview validates catalog/group/projection/stream identity and
reports targets, serving revision, current stream version, event count, expected dedup
claims, reviewed maximum, truncation/deletion state, and the exact force operation, but
performs no clear/replay/dedup mutation.

The forced path calls the runner once. Do not duplicate transaction SQL in the operations
module. Bump the operation envelope schema and add golden JSON/human rendering tests.

### Milestone 4 — Add the embedded operator command

Add `keiro-ops rebuild reproject-stream GROUP PROJECTION STREAM`. Without `--force`,
render the preview and exit without mutation. With `--force`, invoke the supported
operation and render cleared row counts, replayed event count, dedup inserted/existing
counts, serving revision, and verification result. Mount only through an application
hook carrying the validated catalog and codecs.

Tests prove argument validation occurs before database mutation, standalone mode reports
the missing application capability, JSON is stable, and all typed refusals preserve
their distinct codes.

### Milestone 5 — Document and close out

Document eligibility, the group-wide writer wait, reader transaction visibility,
deduplication behavior, unchanged checkpoint, truncation/deletion refusal, and the
difference between targeted corruption repair and schema-changing full rebuild.

Amend ADR-26 with stream-scoped projection ownership, ADR-31 with targeted dedup
backfill, ADR-32 with the new fingerprint fact, and ADR-34 with the relationship to
serving revisions if implementation refines it. Update changelogs and record a Jitsurei
transcript repairing one aggregate while another remains unchanged and a concurrent
writer waits. Run strict ADR validation and `just verify`.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
mori registry show shinzui/kiroku --full
cabal test keiro-test --test-option=--match --test-option="targeted stream reprojection"
cabal test keiro-ops-test --test-option=--match --test-option="reproject-stream"
cabal test keiro-dsl:tests
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```


## Validation and Acceptance

The feature is accepted when a real database test and Jitsurei transcript start with two
aggregate streams, deliberately corrupt one stream's projected row, and repair it while:

1. the other stream's rows do not change;
2. an oversized stream is refused before the group-wide writer fence;
3. a concurrent group writer waits and commits after the repair;
4. a concurrent sanctioned reader returns a complete before or after result;
5. the repair transaction restores the selected row from complete event history;
6. affected deduplication keys exist at commit;
7. simulated async redelivery performs no projection effect;
8. the durable subscription checkpoint is exactly unchanged;
9. group lifecycle, serving revision, and serving epoch are unchanged;
10. a truncated or deleted stream is refused without mutation.

Handler idempotence alone is not acceptance evidence.


## Idempotence and Recovery

Running the repair twice produces the same projection state when the declared handler is
deterministic. Dedup insertion is idempotent. The complete mutation is one transaction,
so a process crash or SQL exception before commit leaves target rows and deduplication
unchanged. The group row lock is released automatically on rollback.

Preview is always read-only. Never recover a failed repair with manual checkpoint
advance or dedup deletion. Correct the cause and repeat the supported operation. If
history is truncated or deleted, use an application-specific recovery or a full rebuild
from an authoritative replacement source; the command does not invent missing events.
If the stream exceeds `maxEvents`, review its projected work and choose an explicit
larger limit or use a full rebuild; reducing page size does not change admission.


## Interfaces and Dependencies

Primary modules are:

- `keiro/src/Keiro/Projection/Catalog.hs` for stream-scoped revision policy and
  validation;
- `keiro/src/Keiro/ReadModel/Rebuild/Stream.hs` for the transaction protocol and typed
  result/refusals;
- `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` for exclusive lock and serving-revision
  resolution;
- `keiro/src/Keiro/Projection/Catalog/Operations.hs` for preview/mutation wrappers;
- `keiro-ops/src/Keiro/Ops/Rebuild.hs` for the embedded command;
- Kiroku's exported `StreamInfo`, forward stream-read transaction statements, and the
  stream-history guard requested by
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-6`, concretely
  `lockStreamHistoryForReplayTx` and `readStreamForwardTx` from
  `Kiroku.Store.HistoryRetention` in `kiroku-store` 0.7.0.0;
- `kiroku-store-migrations` 0.3.2.0, which is the companion database release required
  by the coordinated Kiroku 0.7 adoption;
- plan 258's deduplication selection/insertion helpers and ADR-31 semantics;
- plan 256's `PhysicalTargets` and serving revision; plan 255's group shared-lock guard.

No migration is expected unless the validated catalog needs additional persisted policy
identity. If a migration becomes necessary, record why in the Decision Log and use the
next free native migration at implementation time.


## Commit and Trailer Convention

Use Conventional Commits and include:

```text
MasterPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
ExecPlan: docs/plans/257-add-targeted-per-stream-reprojection-to-catalog-operations.md
Intention: intention_01kzw6dkhje7qvw6w321pwyv12
```


## Revision Note

Revised 2026-08-13 after architecture validation. The plan now uses the persisted
serving revision, reads explicit `StreamInfo.truncateBefore`, states the group-wide
writer pause, backfills deduplication keys transactionally, leaves shared checkpoints
unchanged, and tests that async redelivery cannot reapply the repair.

Revised again on 2026-08-13 after Kiroku implemented IR-6 and published the packages
Keiro requires. The exact 0.7.0.0 stream-guard APIs and 0.3.2.0 companion migration are
recorded, the Kiroku `decodeHook` boundary is explicit, and the external prerequisite is
marked complete.

Revised on 2026-08-14 after implementation and acceptance. The delivered protocol
orders the stream guard before the group fence to match append-first writers, keeps
deduplication preparation page-bounded inside the repair transaction, and passes the
complete committed-corpus repository verification gate.

Revised on 2026-08-14 after the EP-5 adversarial review. Requests now admit the exact
locked event count against `maxEvents` before the group fence; preview/outcome v2 expose
that authority; and fault injection covers application failures, hard deletion, and
backend interruption.
