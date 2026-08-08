---
id: 162
slug: rebuild-inline-projections-deterministically-from-event-history
title: "Rebuild inline projections deterministically from event history"
kind: exec-plan
created_at: 2026-07-31T14:46:36Z
---

# Rebuild inline projections deterministically from event history

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

**Status: Superseded before implementation.** The requirements and uncompleted work in this plan
are absorbed by [plan 211](211-replay-catalogued-projections-deterministically-and-resumably.md)
under [MasterPlan 32](../masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md).
This document remains as the historical design record; do not implement its one-read-model API.


## Purpose / Big Picture

After this change, an inline read model can be rebuilt from Kiroku event history through a supported
Keiro API instead of an application-specific script. The rebuild takes the model offline, fences
normal inline writers, truncates the model, scans a fixed global-position range in order, decodes
and applies only relevant events through the registered projection logic, verifies that non-empty
relevant history produced applications, and promotes the model atomically. Failure leaves the model
unavailable and resumable/restartable rather than exposing partial rows.

An application can observe the feature by rebuilding a populated inline model, comparing its rows
and digest with the pre-rebuild model, and seeing a concurrent command receive a typed rebuild fence
instead of interleaving with replay.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-08-07: Transferred the managed inline fence and typed fenced outcome to plan 210; no
  implementation was performed under this plan.
- [x] 2026-08-07: Transferred total relevance/decode, fixed-head ordered scanning, progress, and
  resume to plan 211; no implementation was performed under this plan.
- [x] 2026-08-07: Replaced the one-`ReadModel` lifecycle with catalogued atomic groups in plans
  209–211 and transferred DSL generation to plan 212.
- [x] 2026-08-07: Transferred concurrency, crash/restart, parity, telemetry, documentation, and
  full validation acceptance to MasterPlan 32.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-31: `Keiro.ReadModel.Rebuild.startRebuild` accepts an empty async-projection list for an
  inline-only model, but `finishRebuild` then skips the non-empty rebuild guard. Keiro supplies no
  history scanner or apply path for inline projections.
- 2026-07-31: `InlineProjection` has only a name and typed `apply`; normal inline writes do not
  consult `keiro_read_models`. Calling the existing lifecycle while commands are live can therefore
  truncate, replay, and interleave new inline updates.
- 2026-07-31: Completed plan 101 hardened async rebuild fencing and explicitly documents the empty
  inline list exception. It does not cover a managed inline replay runner, so this is new work in
  the same command/read-model hardening group.
- 2026-08-07: A one-read-model replay unit cannot represent normalized multi-table ownership,
  preserve-and-reconcile brownfield targets, or async and inline projections in one atomic group.
  The broader IR-20 review therefore superseded this plan before implementation.


## Decision Log

Record every decision made while working on the plan.

- Decision: A replayable inline projection must name its read model and expose a decoder from a
  `RecordedEvent` to `Irrelevant`, `Relevant event`, or a typed decode failure.
  Rationale: History is heterogeneous. Silently swallowing a relevant event decode failure would
  produce a clean-looking but incomplete model, while treating unrelated events as failures would
  make global scanning unusable.
  Date: 2026-07-31

- Decision: Managed normal inline writes acquire the same registry fence as async projections;
  rebuild replay uses a narrowly named unfenced apply entry point.
  Rationale: Taking the registry row offline is not a fence unless every writer consults it inside
  the write transaction. A separate replay path keeps the exception auditable.
  Date: 2026-07-31

- Decision: Capture a replay target global position after acquiring the rebuild fence and replay
  `(replayFrom, target]` in ascending global order. Normal inline commands for that model remain
  fenced until promotion.
  Rationale: A fixed target gives deterministic completion and prevents an ever-moving head. New
  model-affecting writes cannot be allowed past the fence during an offline rebuild.
  Date: 2026-07-31

- Decision: Persist rebuild run metadata and the last successfully committed global position;
  restart resumes only when model version, shape hash, source range, and projection-set fingerprint
  still match.
  Rationale: Large histories cannot rely on one transaction, but blindly resuming after code or
  schema changes would mix semantics in one materialization.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening the completed
  command/coordination hardening MasterPlan.
  Rationale: Inline rebuild parity is a separately schedulable capability; attaching it to a closed
  review initiative makes that initiative and this plan harder to track accurately.
  Date: 2026-07-31

- Decision: Supersede this plan with plans 209–212 rather than layer a catalog on top of its
  proposed one-read-model API.
  Rationale: The fence, fixed range, total decoder, transactional progress, and resume decisions
  remain correct, but the lifecycle unit must be a rebuild group and the completion proof must
  account for every source and adapter. Implementing this plan first would create a public API and
  migration that the catalog initiative would immediately replace.
  Date: 2026-08-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Superseded before implementation. MasterPlan 32 retained the useful safety requirements and
expanded them to typed catalogs, multi-target groups, async projections, preserve/reconcile
policy, global ordering across sources, and per-adapter completion. No code, migrations, or ADRs
were produced by this plan.


## Context and Orientation

`keiro/src/Keiro/Projection.hs` defines `InlineProjection co` with `name` and
`apply :: co -> RecordedEvent -> Transaction ()`. `runCommandWithProjections` supplies emitted
events and their stored envelopes in the same append transaction. It has no registry fence and no
way to apply a heterogeneous stored `RecordedEvent` during offline replay.

`keiro/src/Keiro/ReadModel/Rebuild.hs` implements the supported async lifecycle: registration,
`startRebuild`, `applyAsyncProjectionUnfenced`, `finishRebuild`, and `abandonRebuild`. It truncates
the data table, clears async dedup rows, and resets subscription checkpoints. With no async
projection names it permits promotion without proving any inline application. `ReadModel.hs` and
`ReadModel/Schema.hs` own registry state and queries.

`keiro/src/Keiro/Command.hs` already reads event history in pages and decodes aggregate events for
hydration, but that private loop is stream-oriented and must not be copied wholesale. Kiroku store
source and API documentation must be located with Mori before selecting the public global scan
primitive. The dependency is `mori://shinzui/kiroku/packages/kiroku-store`.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits inline `Projection.hs` modules and read-model rebuild
helpers. Generated read-model modules currently call `startRebuild` with `[]`; this plan replaces
that incomplete affordance with the managed replay contract.

[Plan 101](101-read-model-rebuild-correctness-dedup-reset-writer-fencing-and-strong-cursor-semantics.md)
and its completed parent MasterPlan document the existing offline lifecycle.
[ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md)
requires migration and expected-schema artifacts to be updated together if durable rebuild state
is added. No current ADR defines inline replay fencing; the implementation should record it as a
durable decision because it changes the writer contract.

“Managed inline projection” means an inline projection associated with a registered read model and
therefore subject to lifecycle fencing. “Relevant history” means records recognized by the
projection's decoder. “Replay target” is the store head captured for one rebuild run.


## Plan of Work

Milestone 1 extends `Projection.hs` with a managed read-model identity and a typed
`InlineApplyOutcome`/error. Before applying emitted events, `runCommandWithProjections` locks each
distinct managed read-model registry row and requires `Live`. The lock and projection writes remain
inside the append transaction; a fence rolls the append back. Preserve an explicitly named
unmanaged constructor for existing application projections and document that unmanaged projections
cannot use the rebuild runner. Add concurrency tests proving `startRebuild` and normal command
writes serialize and never interleave.

Milestone 2 adds `Keiro.Projection.InlineReplay`. Define a replay projection that contains its
managed `InlineProjection`, a total relevance/decoder function, and a stable semantic fingerprint.
Use Mori to locate Kiroku's released global forward-read API, then implement a paged scan from an
exclusive starting global position through an inclusive captured target. Each page applies
relevant events in global order in bounded transactions and advances durable progress in the same
transaction. Record scanned, relevant, applied, and failed counts and the first failure identity.

Milestone 3 extends Keiro migrations and `ReadModel.Rebuild` with rebuild-run metadata, then adds
`rebuildInlineReadModel`. Beginning a fresh run transitions/truncates/fences, captures the target,
and writes metadata atomically. Resume validates the model version, shape hash, source range, and
projection fingerprint. Completion refuses promotion when relevant history is non-empty but no
event was applied, and optionally calls an application verification hook inside the final fenced
phase. `abandonRebuild` records failure without deleting evidence. Update generated DSL projection
and read-model modules to expose the correct replay decoder and one application entry point.

Milestone 4 adds PostgreSQL integration tests for populated parity, irrelevant events, a corrupt
relevant event, paging order, concurrent commands, crash after a committed page, safe resume,
fingerprint mismatch, empty history, verification failure, and repeated rebuild. Add metrics for
rebuild scanned/applied/failure/progress and structured run IDs. Update expected schema, migration
locks, API docs, user read-model docs, generated-code fixtures, changelogs, and the new ADR.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. First discover the Kiroku API rather than guessing:

```bash
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
```

Then execute focused and full checks:

```bash
cabal test keiro-test --test-options='--match=inline.*rebuild'
cabal test keiro-dsl-test --test-options='--match=inline.*rebuild'
cabal test keiro-migrations-test
cabal test keiro-test
cabal test keiro-dsl-test
cabal build all
nix flake check
```

The focused database suite must show the captured target, at least two committed pages, exact row
parity, a fenced concurrent command, and successful resume. The migration test must show zero
expected-schema drift and lock parity. Record actual test counts and the selected Kiroku API in
Progress/Surprises during implementation.


## Validation and Acceptance

1. A managed inline model rebuilt from a mixed global event history contains exactly the rows and
   deterministic digest produced by the original live inline applications.
2. Once rebuild fencing begins, a normal command touching that model cannot append its events
   without the inline projection. It returns a typed fence outcome/error and succeeds after
   promotion; no event/read-model split is possible.
3. Relevant decode or apply failure records the event ID/global position, leaves the model
   unavailable, and does not advance progress past the failed event. Irrelevant events advance scan
   progress without being counted as applications.
4. Crash after a committed page resumes from the exact persisted position without double-applying
   rows. Resume refuses changed model version, shape hash, range, or projection fingerprint.
5. Promotion requires reaching the captured target and, when relevant history exists, at least one
   application. An application verification failure prevents promotion.
6. Empty history completes successfully. Repeating a complete rebuild produces the same rows and
   digest. Paging does not change results.
7. Generated DSL modules expose the managed/replayable projection without application authors
   duplicating event filtering or reaching for `applyAsyncProjectionUnfenced`.
8. Migration source, manifest, lock, native/legacy parity, and expected schema all agree, and new
   telemetry distinguishes scanned, applied, resumed, failed, and completed rebuilds.


## Idempotence and Recovery

Fresh rebuild intentionally truncates the target table and is destructive to its materialized
contents, but the event log remains authoritative and the operation is explicitly requested by an
application/operator. Resolve the exact registered model/table before truncation and keep the
registry fence in the same transaction. Resume is idempotent only for matching run metadata; a
fresh restart truncates again and begins from the configured source position.

On failure, leave status and run metadata available for diagnosis. `abandonRebuild` must not
promote partial rows. The operator can correct code/data and resume if fingerprints match, restore
the read-model table from a backup, or explicitly start a new run. Migration changes follow the
existing lock/expected-schema recovery workflow; never edit an already released migration.


## Interfaces and Dependencies

`Keiro.Projection` and `Keiro.Projection.InlineReplay` must expose equivalents of:

```haskell
data InlineProjection event = InlineProjection
  { name :: Text
  , readModelName :: Maybe Text
  , apply :: event -> RecordedEvent -> Tx.Transaction ()
  }

data ReplayDecode event
  = ReplayIrrelevant
  | ReplayRelevant event
  | ReplayDecodeFailed Text

data InlineReplayProjection = forall event. InlineReplayProjection
  { projection :: InlineProjection event
  , decodeRecorded :: RecordedEvent -> ReplayDecode event
  , fingerprint :: Text
  }

rebuildInlineReadModel
  :: (IOE :> es, Store :> es)
  => InlineRebuildOptions
  -> ReadModel q r
  -> NonEmpty InlineReplayProjection
  -> Eff es (Either InlineRebuildError InlineRebuildSummary)
```

The exact existential packaging may differ, but normal/replay apply paths, relevance, typed decode
failure, fingerprint, fixed range, and progress must remain explicit. Use the released public API
of `mori://shinzui/kiroku/packages/kiroku-store` selected after Mori/source inspection; do not read
Kiroku tables through copied private SQL unless the dependency exposes no safe primitive and that
decision is recorded in an ADR.


Revision note: Detached this plan from the completed command/coordination hardening MasterPlan so
it is an independent implementation unit, 2026-07-31.

Revision note: Marked superseded before implementation and transferred all work to MasterPlan 32,
2026-08-07.
