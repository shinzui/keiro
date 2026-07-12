---
id: 99
slug: silent-edge-validation-and-divergence-witnesses-on-the-command-path
title: "Silent-edge validation and divergence witnesses on the command path"
kind: exec-plan
created_at: 2026-07-12T05:07:53Z
master_plan: "docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md"
---

# Silent-edge validation and divergence witnesses on the command path

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is Phase 3 of the master plan at
`docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`
(EP-99 in its registry). HARD DEPENDENCY: EP-95
(`docs/plans/95-migrate-to-post-mp-16-keiki-and-adopt-the-structured-replay-and-step-apis.md`)
must be complete before Milestone 2 of this plan starts — this plan consumes the
`applyEventsEither` API that the post-MP-16 keiki pin brings in and rebases on the
`renderWarning` arms and hydration shape EP-95 leaves behind. Because EP-95 is a
skeleton at the time of this writing, every interface this plan relies on is restated
here in full (see "What EP-95 and keiki MP-16 deliver" in Context and Orientation),
so this document remains self-contained even if EP-95's file has not yet been fleshed
out when you read this.


## Purpose / Big Picture

keiro is an event-sourcing framework: an application's state machine (a keiki
"transducer", explained below) emits events, keiro appends those events to a
PostgreSQL log, and the *only* durable record of anything is that event log. This
plan closes three holes where keiro's command path quietly contradicts that model.

First, a transition that changes state but emits no events — legal in keiki's pure
model — is a lie under keiro: the state change is never persisted, the command
reports success, and the change silently un-happens the next time the aggregate is
loaded. Today nothing rejects such a transducer. After this plan,
`Keiro.EventStream.Validate.mkEventStream` refuses to construct a stream containing a
state-changing silent edge, with a warning message that names the vertex and edge and
explains why keiro cannot honor it. A deliberate no-op self-loop (same vertex, no
register writes) still validates, because it is genuinely harmless.

Second, after every append keiro (when snapshotting) replays the just-emitted events
through the transducer — and when that replay fails, which proves the just-committed
events can never be rehydrated (the stream is poisoned), keiro today throws the proof
away (`keiro/src/Keiro/Command.hs` line 594: `Nothing -> pure ()`). After this plan
the replay check runs after *every* append (not only snapshot-enabled streams), and a
failure increments the `keiro.snapshot.apply.divergence` counter and stamps a
`keiro.replay.divergence` attribute on the command span, so an operator learns about
the poisoned stream at the moment it is created instead of via a mysterious
`HydrationReplayFailed` minutes or days later.

Third, a no-op command on a stream with prior events reports
`globalPosition = Just (GlobalPosition 0)` — a fabricated position copied from
kiroku's per-stream-read sentinel — while the same no-op on a snapshot-seeded
hydration reports `Nothing`. A caller checkpointing on that value would rewind its
subscription to the beginning of the log. After this plan a no-op command always
reports `globalPosition = Nothing`.

To see it working: from the repository root, `cabal test keiro-test` runs new specs
that (a) show `mkEventStream` rejecting a silent-move fixture and a silent
register-write fixture while the existing benign no-op fixture still validates,
(b) show the divergence counter incrementing through a real SDK meter when a
split-coverage transducer appends events that cannot replay, followed by the
predicted `HydrationReplayFailed` on the next command, and (c) show a no-op command
reporting `globalPosition = Nothing` where it previously fabricated `Just 0`.


## Progress

- [ ] M1: `edgeWritesRegisters` helper and `silentEdgeWarnings` added to `keiro-core/src/Keiro/EventStream/Validate.hs`
- [ ] M1: `StreamValidationOptions` record (keiki options + `checkSilentStateChange`) threaded through `validateEventStreamWith` / `mkEventStreamWith`
- [ ] M1: silent-move fixture, silent register-write fixture, opt-out spec, and keiki-does-not-flag-it spec added to `keiro/test/Main.hs`; existing no-op fixture still validates clean
- [ ] M2: `verifyReplayOnAppend` flag added to `RunCommandOptions` (default `True`)
- [ ] M2: post-append replay check extracted, runs on both append paths, witnesses divergence via counter + span attribute; snapshot write consumes the same fold
- [ ] M2: `keiro.snapshot.apply.divergence` counter and `keiro_replay_divergence` attribute key added to `keiro/src/Keiro/Telemetry.hs`
- [ ] M2: split-coverage divergence spec (counter increments, command still succeeds, next command fails with `HydrationReplayFailed`)
- [ ] M3: `noOpResult` reports `globalPosition = Nothing`; dead `Hydrated.globalPosition` bookkeeping removed
- [ ] M3: no-op globalPosition normalization spec (fails before the fix)
- [ ] M4: CHANGELOG entries, semconv audit doc row, module haddock updates, master plan registry/progress update, `nix fmt`, full sweep


## Surprises & Discoveries

Entries below were verified during plan authoring (2026-07-11); add
implementation-time discoveries as they occur.

- The feared "register-only silent edge gap" does not exist. The review assumed keiki
  exports no way to ask "does this edge write any register", because `Edge`'s update
  is existentially quantified (`Edge` GADT, keiki `src/Keiki/Core.hs:627-634`) and
  keiki's only edge-level accessor is `edgeReadsInput` (keiki
  `src/Keiki/Core.hs:664-665`). But keiki exports the `Update` type *with all three
  constructors* (`Update (..)`, keiki `src/Keiki/Core.hs:72` in the export list;
  definition at 430-442: `UKeep`, `USet`, `UCombine`), so keiro can write its own
  five-line `edgeWritesRegisters` by pattern matching — the existential `w` never
  escapes. The full rule (vertex change OR register write) is therefore
  implementable keiro-side with no keiki change and no scoped-down fallback.
- `noOpCounterEventStream` (the benign silent self-loop fixture at
  `keiro/test/Main.hs:7600-7615`) is load-bearing beyond validation specs: it is the
  `eventStream` of `timerOnlyProcessManager` (`keiro/test/Main.hs:7893`), whose
  "schedules timers when the manager command emits no events" spec
  (`keiro/test/Main.hs:1732-1750`) runs real no-op commands through the
  process-manager path. The new validation rule must keep accepting it, and its PM
  spec doubles as an end-to-end regression for benign silent edges.
- kiroku's per-stream forward read fabricates `global_position = 0` by design: the
  SQL literally selects `0::bigint AS global_position` because the true position is
  unavailable without a `$all` join (kiroku `kiroku-store/src/Kiroku/Store/SQL.hs`,
  doc line 496, SQL at 502, in the pinned kiroku checkout named in `cabal.project`).
  keiro's hydration copies that sentinel into `Hydrated.globalPosition`
  (`keiro/src/Keiro/Command.hs:303` and `:375`) and `noOpResult` republishes it as if
  it were real (`keiro/src/Keiro/Command.hs:675-685`). A keiro test comment at
  `keiro/test/Main.hs:979` already acknowledges the sentinel — the bug is only that
  the command path launders it into a `CommandResult`.
- `CommandResult.globalPosition` has no consumer that a `Nothing`-for-no-op breaks:
  every in-repo read of it (`keiro/test/Main.hs:602, 902, 1328, 1368, 1393, 1442`)
  is on an *appended* result, which keeps reporting `Just`. `Keiro.ReadModel` and
  `Keiro.Integration.Event` read `globalPosition` from other types
  (`RecordedEvent` / integration events), not from `CommandResult`.


## Decision Log

- Decision: the silent-edge rule is a keiro-side stream-validation failure in
  `keiro-core/src/Keiro/EventStream/Validate.hs`, NOT an extension of keiki's
  `TransducerValidationWarning`.
  Rationale: restated from the master plan's Decision Log (2026-07-12): ε-edges are
  legal in keiki's pure model — keiki plan 68 makes silent edges an explicit
  authoring choice (`noEmit`) and keiki EP-73 documents the ε-replay boundary, but
  neither can reject them, because only keiro knows events are the sole persistence.
  The keiro-owned `snapshotWarnings` check (`keiro-core/src/Keiro/EventStream/Validate.hs:159-169`)
  is the precedent: a keiro-semantics rule expressed as an `EventStreamWarning`,
  composed alongside (never inside) keiki's validator output.
  Date: 2026-07-11

- Decision: the rule covers the full predicate — flag every edge with `output == []`
  whose `target` differs from its source vertex OR whose update is not syntactically
  `UKeep` (recursively: a `UCombine` tree containing any `USet`). Detection is
  syntactic: a `USet` that happens to write the value already present is still
  flagged.
  Rationale: `Update (..)` is exported by keiki so the write check is a local
  pattern match (see Surprises & Discoveries); no scoped-down "vertex-change-only"
  rule is needed. Syntactic conservatism is correct here: a register write on an
  edge that emits nothing is at best pointless and at worst a durable no-op, and an
  author who genuinely wants it can opt out (below) or restructure. Semantic
  identity ("writes the same value") is undecidable without evaluating terms against
  runtime state.
  Date: 2026-07-11

- Decision: the rule is a `mkEventStream` *failure* (any warning makes
  `mkEventStream` return `Left`), with an explicit opt-out flag
  `checkSilentStateChange :: Bool` in a new keiro-side `StreamValidationOptions`
  record, default `True`. `validateEventStreamWith` and `mkEventStreamWith` change
  their first parameter from keiki's `ValidationOptions` to
  `StreamValidationOptions` (which embeds it); the no-options entry points
  `validateEventStream` / `mkEventStream` / `mkEventStreamOrThrow` keep their exact
  signatures.
  Rationale: under keiro's runtime model a state-changing silent edge is never
  right — it validates, reports success, and un-happens — so fail-fast at stream
  construction is the honest default, matching `mkEventStream`'s existing
  fail-on-any-warning posture (`keiro-core/src/Keiro/EventStream/Validate.hs:117-120`).
  The opt-out exists for parity with keiki's narrowing posture and to unblock an
  emergency, not as an endorsement. Signature impact is nil outside the module: no
  caller of the `*With` variants exists anywhere in the repository (verified by
  grep, 2026-07-11).
  Date: 2026-07-11

- Decision: the post-append replay check runs on every append, not only when
  `stateCodec` is `Just`, gated by a new `RunCommandOptions` field
  `verifyReplayOnAppend :: Bool` defaulting to `True`. When the flag is `False` the
  fold still runs whenever a snapshot needs it (snapshot behavior is unchanged), and
  a `Left` from a fold that ran for snapshotting is still witnessed — the flag only
  controls whether snapshot-less streams pay for the fold, never whether an observed
  divergence is reported.
  Rationale: the cost is one `applyEventsEither` fold over the just-emitted batch
  (typically 1-2 events — the same fold snapshot-enabled streams already pay), and
  the value is detecting a poisoned stream at creation time. "Observed but
  unreported" would violate the master plan's "never discarded" requirement.
  Date: 2026-07-11

- Decision: a post-commit divergence does NOT change the command's return value (the
  command still returns `Right (CommandResult ...)`), does not gain a `CommandResult`
  field, and gets no stderr/log fallback. It is witnessed by (a) the
  `keiro.snapshot.apply.divergence` counter when metrics are wired, and (b) a
  `keiro.replay.divergence` span attribute carrying the rendered `ReplayFailure`
  when a tracer is wired.
  Rationale: the events are already durably committed — returning `Left` would tell
  callers (and retry loops) that a succeeded append failed, which is worse than the
  defect. Widening `CommandResult` would push a post-commit advisory into every
  consumer of the command runners (`Keiro.Projection`, `Keiro.ProcessManager`,
  `Keiro.Router`, and the in-repo example package). keiro has no logging
  dependency anywhere in `keiro/src` (verified 2026-07-11) and a library writing to
  stderr is not acceptable; adding a logging seam is out of scope. The residual gap
  — a caller with neither metrics nor tracer sees nothing at append time — is
  accepted because the divergence is not lost: the very next hydration of the
  stream fails with the typed `HydrationReplayFailed` error (post-EP-95, carrying
  keiki's structured reason), so the counter/attribute is an *early warning*, not
  the only witness. The divergence spec in Milestone 2 asserts exactly this
  next-command failure.
  Date: 2026-07-11

- Decision: the counter keeps the master-plan-reserved name
  `keiro.snapshot.apply.divergence` even though after this plan the check is not
  snapshot-specific.
  Rationale: master plan Integration Point 3 reserves this exact name for EP-99 and
  forbids renaming across plans; the fold it counts is the same snapshot-apply fold;
  and EP-98 separately owns `keiro.snapshot.decode.failures`, which this plan must
  not take or touch.
  Date: 2026-07-11

- Decision: no ambiguity counter. Master plan Integration Point 3 lets EP-99 claim
  "any ambiguity counter"; this plan claims none.
  Rationale: EP-95 makes command-time ambiguity a typed `CommandError` constructor
  with its own `commandErrorClass` value (master plan Integration Point 1), so it is
  already surfaced as a typed error plus a low-cardinality `error.type` span
  attribute — the master plan's "typed error OR counted" requirement is satisfied by
  the first arm, and a counter would double-report. Replay-time ambiguity
  (`ReplayAmbiguousInversions`) arriving through the divergence fold is counted by
  the divergence counter like any other replay failure.
  Date: 2026-07-11

- Decision: `noOpResult` hardcodes `globalPosition = Nothing`, and the
  `Hydrated.globalPosition` field (whose only consumer is `noOpResult`) is deleted
  along with the per-event bookkeeping that fills it.
  Rationale: the value is unknowable — kiroku's per-stream read returns a documented
  `0` sentinel, so the choice is between fabricating a position and honestly
  reporting `Nothing`; the snapshot-seeded hydration path already reports `Nothing`
  for the same situation (`keiro/src/Keiro/Command.hs:252`), so this also removes an
  inconsistency between the two hydration paths. No consumer breaks (see Surprises &
  Discoveries). If EP-95's migration to keiki's `replayEvents` has already deleted
  the bookkeeping, only the `noOpResult` edit and its haddock remain.
  Date: 2026-07-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Everything below can be re-verified by reading the cited files. Line numbers are
against the tree at plan-authoring time (2026-07-11); after EP-95 lands they may
shift — search for the named functions.

### The repository and the model

This repository contains the keiro framework packages. The two that matter here:

- `keiro-core` — pure types: the `EventStream` record
  (`keiro-core/src/Keiro/EventStream.hs`) and its validation module
  (`keiro-core/src/Keiro/EventStream/Validate.hs`).
- `keiro` — the runtime: command runners (`keiro/src/Keiro/Command.hs`), snapshots
  (`keiro/src/Keiro/Snapshot.hs`), telemetry (`keiro/src/Keiro/Telemetry.hs`), and
  the coordination layers built on them. Its test suite is the single file
  `keiro/test/Main.hs` (Hspec, cabal target `keiro-test`), which boots its own
  cached PostgreSQL via `keiro-test-support` (`withMigratedSuite` /
  `withFreshStore`) — no manually started database is needed.

keiro builds on two pinned git dependencies (see `cabal.project`): **keiki**, the
pure event-sourcing core, and **kiroku**, the PostgreSQL event store.

A keiki aggregate is a `SymTransducer` (keiki `src/Keiki/Core.hs:638-643`): a finite
graph of control vertices `s`, where each outgoing `Edge` (keiki
`src/Keiki/Core.hs:627-634`) carries a `guard` over the command, an `update` to a
typed register file, a `target` vertex, and an `output :: [OutTerm rs ci co]` — the
list of events the edge emits. An edge whose `output` is the empty list is an
**ε-edge** (epsilon edge), also called a **silent edge** in this plan: taking it
changes the machine's state (vertex and/or registers) but emits nothing observable.
The `update` language is a GADT (keiki `src/Keiki/Core.hs:430-442`) with three
constructors: `UKeep` (write nothing), `USet ix term` (write one slot), and
`UCombine u1 u2` (both). The `Edge` record hides the update's write-set type
parameter existentially, so `update e` cannot be used as a field selector — but
keiki exports `Update (..)` and `Edge (..)`, so a function that pattern-matches the
edge and recurses over the update compiles fine (keiki's own `applyEdgeUpdate` at
`src/Keiki/Core.hs:658-660` uses exactly this trick).

Forward execution is `Keiki.step` (keiki `src/Keiki/Core.hs:906-918`): given
`(state, registers)` and a command, it returns `Just (state', registers', events)`
for the unique matching edge, or `Nothing`. Replay (rebuilding state from stored
events) *inverts* events back through edges; crucially, **replay structurally skips
ε-edges** — an edge that emitted nothing left nothing in the log to invert, so its
state change is invisible to every hydration.

An `EventStream` (keiro-core) packages a transducer with its durable plumbing:
initial state/registers, an event `Codec`, a stream-name resolver, a
`snapshotPolicy`, and an optional `stateCodec` for snapshots. Command runners accept
only a `ValidatedEventStream`, produced by `mkEventStream`
(`keiro-core/src/Keiro/EventStream/Validate.hs:98-104`), which runs keiki's
umbrella validator plus keiro's own stream-level checks and fails on any warning.

### Defect 1 — state-changing silent edges validate, succeed, and un-happen

The command pipeline is hydrate → transduce → append. `evaluateCommand`
(`keiro/src/Keiro/Command.hs:650-659`) steps the transducer and **discards the
post-step state**:

```haskell
case Keiki.step (eventStream ^. #transducer) (state current, registers current) command of
    Nothing -> Left CommandRejected
    Just (_, _, events) -> Right events
```

If `events` is `[]`, `prepareCommandPlan` returns `CommandNoOp`
(`keiro/src/Keiro/Command.hs:523-524`): success, zero appends. keiki's step
semantics say the machine DID transition — but since events are keiro's only
persistence and replay skips ε-edges, a silent edge that changes vertex or writes
registers reports success and un-happens at the next hydration. Nothing rejects
such a transducer today: keiki's own validator flags only ε-edges whose update
*reads the command* (`HirEpsilonReadsInput`, keiki `src/Keiki/Core.hs:1371-1374` —
a replay-safety concern, not a durability one), and keiro's `Validate.hs` adds only
the snapshot-policy check. The division of labor is fixed by the master plan's
Decision Log: keiki plan 68 makes silent edges an explicit authoring choice
(builder authors must write `noEmit`) and keiki EP-73 documents the ε-replay
boundary, but the *rejection* rule is keiro's because only keiro knows events are
the sole persistence.

Note the deliberate carve-out: a silent edge whose target equals its source and
whose update is `UKeep` is a true no-op — nothing to persist, nothing lost. The
test fixture `noOpCounterTransducer` (`keiro/test/Main.hs:7600-7615`) is exactly
this shape (self-loop on `Counting`, `update = UKeep`, `output = []`), it is
asserted clean at `keiro/test/Main.hs:540` and `:568`, and it backs a live
process-manager fixture (`timerOnlyProcessManager`, `keiro/test/Main.hs:7893`).
The new rule must not flag it.

### Defect 2 — the divergence witness is discarded, and only sometimes computed

After a successful append, `writeSnapshotIfNeeded`
(`keiro/src/Keiro/Command.hs:580-606`) replays the just-emitted events from the
pre-command state to compute the post-command snapshot state:

```haskell
case eventStream ^. #stateCodec of
    Nothing -> pure ()
    Just codec ->
        case Keiki.applyEvents (eventStream ^. #transducer) (state current, registers current) events of
            Nothing -> pure ()
            Just finalState -> do ...
```

That `Nothing -> pure ()` (line 594) discards a proof of catastrophe: the events
are already committed, and this replay failing means the *next hydration of this
stream cannot succeed* — the stream is poisoned, and the operator will meet a
`HydrationReplayFailed` with no hint of when or how the poison entered. Two
independent holes: the witness is discarded, and the check only runs at all when
`stateCodec` is `Just` (lines 590-591) — snapshot-less streams get no detection.
There is also an observability-default trap: `defaultRunCommandOptions` ships
`metrics = Nothing` (`keiro/src/Keiro/Command.hs:196`), so any counter-only fix is
silent by default; the Decision Log entry above records how this plan handles that
honestly (span attribute + the guaranteed next-hydration typed error).

Both append paths call this function: `appendOnce` inside `runCommand`
(`keiro/src/Keiro/Command.hs:414-427`) and `appendWithSqlOnce` inside
`runCommandWithSqlEvents` (`keiro/src/Keiro/Command.hs:485-508`). The command span
(`withCommandSpan`) wraps both runners; its `Maybe Span` is currently visible only
in the outer lambda (`keiro/src/Keiro/Command.hs:393` and `:464`) and must be
threaded down to the post-append site.

### Defect 3 — the fabricated no-op global position

kiroku's per-stream forward read cannot know an event's global position without a
`$all` join, so it returns a documented sentinel: `0::bigint AS global_position`
(kiroku `kiroku-store/src/Kiroku/Store/SQL.hs`, doc at line 496, SQL at 502, in the
checkout pinned by `cabal.project`). keiro's hydration folds copy that sentinel
into `Hydrated.globalPosition` (`keiro/src/Keiro/Command.hs:303` and `:375`), and
`noOpResult` (`keiro/src/Keiro/Command.hs:675-685`) publishes it as
`Just (GlobalPosition 0)` — while the snapshot-seeded path seeds
`globalPosition = Nothing` (`keiro/src/Keiro/Command.hs:252`) and so reports
`Nothing` for the identical situation. A caller checkpointing a subscription on the
reported position would rewind to the origin of the log. Appended results are
unaffected: `appendedResult` (`keiro/src/Keiro/Command.hs:687-698`) uses the
`AppendResult`'s real position.

### What EP-95 and keiki MP-16 deliver (restated, since EP-95 is a skeleton)

The standing assumption (master plan, user directive 2026-07-12) is that keiki
MasterPlan 16 is implemented first and EP-95 has migrated keiro onto it. Concretely,
by the time Milestone 2 here starts:

- The keiki pin in `cabal.project` points at a post-MP-16 keiki whose
  `Keiki.Core` exports `applyEventsEither`:

  ```haskell
  applyEventsEither ::
    (BoolAlg phi (RegFile rs, ci), Eq co) =>
    SymTransducer phi rs s ci co ->
    (s, RegFile rs) ->
    [co] ->
    Either (ReplayFailure s co) (s, RegFile rs)
  ```

  where `ReplayFailure` is a record (`replayFailedIndex :: Int`,
  `replayFailedState :: InFlight s co`,
  `replayFailureReason :: ReplayFailureReason s co`) deriving `Eq` and `Show`,
  with reasons `ReplayEventFailed (ReplayStepFailure s co)` (constructors
  `ReplayNoInvertingEdge`, `ReplayAmbiguousInversions`, `ReplayQueueMismatch`) and
  `ReplayLogTruncated [co]`. This is keiki EP-72's surface (keiki repository,
  `docs/plans/72-structured-replay-diagnostics-reconstituteeither-strict-evolve-policy-and-multi-event-outputacceptor.md`,
  Interfaces and Dependencies). The `Maybe`-returning `applyEvents` keeps its exact
  signature as a thin wrapper.
- keiki's `validateTransducer` has three new checks ON by default (keiki EP-71):
  head-recoverability, inversion ambiguity, and guard-implies-input-read, gated by
  new `ValidationOptions` fields (`checkHeadRecoverability`,
  `checkInversionAmbiguity`, and the guard-read flag). EP-95 has added the
  exhaustive `renderWarning` arms for the new constructors in
  `keiro-core/src/Keiro/EventStream/Validate.hs` — Milestone 1 here edits the same
  module and must rebase on those arms (master plan Integration Point 2).
- EP-95 has replaced the duplicated `hydrate`/`hydrateFull` folds
  (`keiro/src/Keiro/Command.hs:221-378`) with keiki's seedable `replayEvents` fold
  and made `HydrationReplayFailed` carry structured detail, and `evaluateCommand`
  distinguishes ambiguous guards from rejection via `stepEither` (master plan
  Integration Point 1). Milestone 3's bookkeeping deletion adapts to whatever
  accumulator shape EP-95 left.

Milestone 1 does not need any of this and may be implemented before EP-95 if
scheduling demands it (its only interaction is a textual rebase in
`renderWarning`'s vicinity); Milestones 2 and 3 assume the post-EP-95 tree.

### Telemetry conventions

Counter names are dotted strings following `keiro.snapshot.write.failures`
(`keiro/src/Keiro/Telemetry.hs:562-563`). Instruments live in the `KeiroMetrics`
record (`keiro/src/Keiro/Telemetry.hs:600-634`), are constructed in
`newKeiroMetrics` (one `counterI64 name unit description` line each, around
`keiro/src/Keiro/Telemetry.hs:643-700`), and are recorded through per-instrument
helpers taking `Maybe KeiroMetrics` (`recordSnapshotWriteFailures` at
`keiro/src/Keiro/Telemetry.hs:783-784` is the model — a one-liner over
`recordCounter`). Bespoke span attribute keys live in the "Bespoke keiro
AttributeKeys" section (`keiro/src/Keiro/Telemetry.hs:213-244`), e.g.
`keiro_events_appended :: AttributeKey Int64`. The catalogue doc is
`docs/research/opentelemetry-semconv-audit.md`. Reserved names per master plan
Integration Point 3: this plan owns `keiro.snapshot.apply.divergence`; EP-98 owns
`keiro.snapshot.decode.failures` — do not create, rename, or record the latter.

The test suite has a ready-made harness for asserting counters through a real SDK
meter with an in-memory exporter: `keiro/test/Main.hs:322-368`
(`inMemoryMetricExporter`, `createMeterProvider`, `forceFlushMeterProvider`,
`flattenScalarPoints`). Command tests run against a per-example fresh database via
`describe "Keiro.Command" $ around (withFreshStore fixture)` and
`Store.runStoreIO storeHandle` (`keiro/test/Main.hs:592-609` is the template).

### Build environment

GHC via the flake; run everything from the repository root inside `nix develop`.
Build: `cabal build all`. Tests: `cabal test keiro-test` (the suite boots its own
PostgreSQL; the nix shell provides the postgres binaries). Formatting:
`nix fmt` (treefmt: fourmolu + cabal-fmt + nixpkgs-fmt; see `nix/treefmt.nix`).
Commit style: Conventional Commits.


## Plan of Work

Four milestones. M1 is the validation rule (keiro-core), M2 the divergence witness
(keiro runtime + telemetry), M3 the no-op position fix (small, independent), M4 the
documentation/changelog sweep. Each leaves `cabal build all && cabal test keiro-test`
green.

### Milestone 1 — reject state-changing silent edges at stream validation

Scope: `keiro-core/src/Keiro/EventStream/Validate.hs` plus specs in
`keiro/test/Main.hs`. At the end, `mkEventStream` refuses a transducer containing a
silent edge that changes the vertex or writes a register, with an opt-out; the
benign no-op self-loop still validates; keiki's validator is untouched.

In `keiro-core/src/Keiro/EventStream/Validate.hs`:

First, extend the `Keiki.Core` import list (currently lines 33-40) with
`Edge (..)`, `Update (..)`, and `SymTransducer (..)` (the last for the `edgesOut`
field; if EP-95's arms already import more, merge).

Add a module-private helper that answers "does this edge write any register",
hiding the `Edge`'s existential write-set exactly the way keiki's own
`applyEdgeUpdate` does:

```haskell
-- | Does this edge's update write any register slot? Syntactic: a 'USet'
-- counts even if it happens to write the value already present. Companion
-- to keiki's 'edgeReadsInput'; lives here because keiki has no reason to
-- ask the question (see EP-99's Decision Log).
edgeWritesRegisters :: Edge phi rs ci co s -> Bool
edgeWritesRegisters Edge{update = u} = updateWrites u
  where
    updateWrites :: Update rs w ci -> Bool
    updateWrites UKeep = False
    updateWrites USet{} = True
    updateWrites (UCombine a b) = updateWrites a || updateWrites b
```

Add `silentEdgeWarnings`, mirroring the shape of `snapshotWarnings`
(lines 159-169) and the vertex-enumeration idiom of keiki's `checkHiddenInputs`
(keiki `src/Keiki/Core.hs:1337-1345`: `s <- [minBound .. maxBound]`, edges indexed
with `zip [0 ..]`):

```haskell
silentEdgeWarnings ::
    (Bounded s, Enum s, Eq s, Show s) =>
    Text ->
    EventStream phi rs s ci co ->
    [EventStreamWarning]
silentEdgeWarnings label es =
    [ EventStreamWarning{eswStreamLabel = label, eswReason = reason}
    | s <- [minBound .. maxBound]
    , (n, e@Edge{output = [], target = tgt}) <-
        zip [(0 :: Int) ..] (edgesOut (transducer es) s)
    , reason <- silentEdgeReasons s n tgt (edgeWritesRegisters e)
    ]
```

with `silentEdgeReasons` producing at most one reason per defect so a doubly-bad
edge names both problems. Suggested rendered text (keep the `@vertex` prefix style
of `renderWarning`, lines 146-157):

- vertex change: `silent-state-change @Draining: edge #0 emits no events but
  targets Drained; keiro persists only events, so this transition cannot be
  rehydrated and un-happens at the next load. Emit an event or make the edge a
  pure no-op (same target, no register writes).`
- register write: `silent-state-change @Counting: edge #1 emits no events but
  writes registers; keiro persists only events, so the written registers
  un-happen at the next load.`

Note the comprehension only *binds* the edge and passes it whole to
`edgeWritesRegisters` — do not try to project the `update` field directly (the
existential forbids it). Non-silent edges (`output` non-empty) fall through the
pattern and are never examined. The `Eq s` needed for `tgt /= s` is implied by the
module's existing `Ord s` constraints, so no signature gains a constraint.

Introduce the options record and thread it:

```haskell
-- | keiro-side validation options: keiki's transducer options plus the
-- keiro-only silent-state-change check (EP-99). 'checkSilentStateChange'
-- defaults to True; disable it only for a documented, deliberate exception —
-- under keiro's model a state-changing silent edge is never replayable.
data StreamValidationOptions = StreamValidationOptions
    { transducerOptions :: !ValidationOptions
    , checkSilentStateChange :: !Bool
    }

defaultStreamValidationOptions :: StreamValidationOptions
defaultStreamValidationOptions =
    StreamValidationOptions
        { transducerOptions = defaultValidationOptions
        , checkSilentStateChange = True
        }
```

Change `validateEventStreamWith` and `mkEventStreamWith` to take
`StreamValidationOptions` instead of keiki's `ValidationOptions` (their only
callers are the module's own default entry points — verified). In
`validateEventStreamWith` (lines 88-92), pass `transducerOptions opts` to
`validateTransducer` and prepend the new check:

```haskell
validateEventStreamWith opts label es =
    snapshotWarnings label es
        <> (if checkSilentStateChange opts then silentEdgeWarnings label es else [])
        <> [ EventStreamWarning{eswStreamLabel = label, eswReason = renderWarning w}
           | w <- validateTransducer (transducerOptions opts) (transducer es)
           ]
```

`validateEventStream`, `mkEventStream`, and `mkEventStreamOrThrow` keep their
signatures, now delegating with `defaultStreamValidationOptions`. Export
`StreamValidationOptions (..)` and `defaultStreamValidationOptions`; update the
module haddock's bullet list and the `mkEventStreamWith` haddock (its "narrow
options" warning now also covers the silent-edge opt-out).

Tests, in `keiro/test/Main.hs` next to the existing validation fixtures
(around lines 7576-7615) and specs (lines 536-574):

- A silent-move fixture. New two-vertex state type and transducer (the existing
  `CounterState` has a single constructor, so a vertex-change fixture needs its
  own):

  ```haskell
  data DrainState
      = Draining
      | Drained
      deriving stock (Generic, Eq, Show, Enum, Bounded, Ord)

  silentMoveTransducer :: SymTransducer (HsPred '[] CounterCommand) '[] DrainState CounterCommand CounterEvent
  silentMoveTransducer =
      SymTransducer
          { edgesOut = \case
              Draining ->
                  [ Edge
                      { guard = matchInCtor addCtor
                      , update = UKeep
                      , output = []
                      , target = Drained
                      }
                  ]
              Drained -> []
          , initial = Draining
          , initialRegs = RNil
          , isFinal = \case Drained -> True; _ -> False
          }
  ```

  wrapped in an `EventStream` reusing `counterCodec`, `snapshotPolicy = Never`,
  `stateCodec = Nothing`. Spec: `validateEventStream "silent-move" ...` yields
  exactly one warning whose reason contains `"silent-state-change"` and
  `"Drained"`; `mkEventStream` returns `Left`; and — the keiki-boundary proof —
  `Keiki.validateTransducer defaultValidationOptions silentMoveTransducer` is `[]`
  (keiki legitimately accepts what keiro must reject).
- A silent register-write self-loop fixture over `SnapshotCounterRegs` (the
  existing one-slot register schema, `keiro/test/Main.hs:7541`): copy
  `snapshotCounterTransducer` (`keiro/test/Main.hs:7659-7677`) but set
  `output = []` and change the `USet`'s right-hand side from
  `inpCtor addCtor #amount` to `lit 0` — the literal matters, because an
  input-reading silent update would also trip keiki's own `HirEpsilonReadsInput`
  and the spec must show *keiro's* rule firing alone. Spec: one warning containing
  `"writes registers"`; `Keiki.validateTransducer` clean on the same transducer.
- Opt-out: `mkEventStreamWith defaultStreamValidationOptions{checkSilentStateChange = False} "silent-move" ...`
  returns `Right`.
- Regression by existing assertion: the specs at `keiro/test/Main.hs:540` and
  `:568` already pin `noOpCounterEventStreamDef` (identity self-loop) as clean and
  accepted — they must keep passing untouched, and the
  `timerOnlyProcessManager` spec (line 1732) keeps exercising it end to end.

Acceptance: `cabal test keiro-test` green; the two new fixtures are rejected with
the exact reason substrings, the opt-out accepts, keiki's validator is shown clean
on both, and every pre-existing validation spec is unchanged.

### Milestone 2 — witness append/replay divergence on every append

Scope: `keiro/src/Keiro/Command.hs` and `keiro/src/Keiro/Telemetry.hs`, plus a
divergence spec. At the end, a batch that cannot replay increments a counter and
stamps the command span on both append paths, snapshot-enabled or not, and the
plan's poisoned-stream story is proven by a test. Requires the post-EP-95 tree.

Telemetry first (`keiro/src/Keiro/Telemetry.hs`):

- Name constant, next to `keiroSnapshotWriteFailuresName` (line 562):
  `keiroSnapshotApplyDivergenceName = "keiro.snapshot.apply.divergence"`.
- `KeiroMetrics` field `snapshotApplyDivergence :: Counter Int64`, constructed in
  `newKeiroMetrics` following the `snapshotWriteFailures'` line:
  `counterI64 keiroSnapshotApplyDivergenceName "{failure}" "Just-appended event
  batches that failed to replay from the pre-command state (stream poisoned; the
  next hydration will fail)."`.
- Recording helper, following `recordSnapshotWriteFailures` (lines 783-784):
  `recordSnapshotApplyDivergence = recordCounter snapshotApplyDivergence`.
- Bespoke attribute key in the section at lines 213-244:
  `keiro_replay_divergence :: AttributeKey Text` with value
  `"keiro.replay.divergence"`.
- Export the helper, the name constant, and the key from the module export list
  (mirroring how the snapshot-write trio is exported).

Command path (`keiro/src/Keiro/Command.hs`):

- Add `verifyReplayOnAppend :: !Bool` to `RunCommandOptions` (after `metrics`),
  haddock: runs the post-append replay check on every append, not only when a
  snapshot might be written; a failed check is counted as
  `keiro.snapshot.apply.divergence` and attached to the command span, and the
  command still succeeds (the events are already committed). Default `True` in
  `defaultRunCommandOptions` (lines 188-199); extend that function's haddock list.
- Replace `writeSnapshotIfNeeded` with a function that owns the whole post-append
  epilogue — replay-check first, snapshot second, sharing one fold:

  ```haskell
  verifyAndSnapshot ::
      forall phi rs s ci co es.
      (BoolAlg phi (RegFile rs, ci), IOE :> es, Store :> es, Error StoreError :> es, Eq co) =>
      RunCommandOptions ->
      Maybe Span ->
      EventStream phi rs s ci co ->
      Hydrated rs s ->
      [co] ->
      AppendResult ->
      Eff es ()
  ```

  Semantics: if `verifyReplayOnAppend options` is `False` AND
  `eventStream ^. #stateCodec` is `Nothing`, do nothing (the pre-plan cost
  profile). Otherwise run
  `Keiki.applyEventsEither (eventStream ^. #transducer) (state current, registers current) events`.
  On `Left failure`: `recordSnapshotApplyDivergence (options ^. #metrics) 1`, and
  when a span is present,
  `addAttribute sp (unkey keiro_replay_divergence) (Text.take 256 (Text.pack (show failure)))`
  (the 256-cap mirrors `recordCommandOutcome`'s error description at line 565); no
  snapshot is attempted (there is no trustworthy final state) and the function
  returns normally. On `Right finalState`: proceed with the existing snapshot body
  verbatim (terminality computation, `shouldSnapshotSpan`, `writeSnapshot`,
  swallow-and-count via `recordSnapshotWriteFailures` — lines 595-606 today).
- Thread the span: both runners already receive `mSpan` in their `withCommandSpan`
  lambda (lines 393 and 464); pass it as a new parameter through
  `attempt`/`runPlan`/`appendOnce` (and the `WithSqlEvents` equivalents) to the
  `verifyAndSnapshot` call sites that replace `writeSnapshotIfNeeded` at lines 424
  and 503. This is mechanical parameter plumbing; no behavior change.
- Update the module haddock's snapshot paragraph (lines 26-29) to describe the
  replay check and its advisory posture.

The divergence spec, in `keiro/test/Main.hs` under the `describe "Keiro.Command"`
block. First the fixture — a "split coverage" transducer, the shape keiki EP-71
uses to demonstrate a validator-blessed transducer whose emitted batch cannot
replay (keiki repository,
`docs/plans/71-align-build-time-validation-with-replay-head-recoverability-cross-edge-inversion-ambiguity-and-guard-implies-input-read-checks.md`,
Milestone 1): a two-field command emitting a two-event chain where the head event
carries only the first field and the tail only the second. Forward `step`
evaluates both events fine; replay must invert the *head* alone, cannot recover
the second field, and fails. Concretely, following the `addCtor` /
`counterAddedCtor` fixture idioms (`keiro/test/Main.hs:7775-7795`):

- `data PairCommand = AddPair !Int !Int`; `data PairEvent = PairFirst !Int | PairSecond !Int`;
  single-vertex `data PairState = Pairing deriving (..., Enum, Bounded, Ord)`;
  an `InCtor PairCommand` over slots `first`/`second`; two `WireCtor`s; a `Codec
  PairEvent` with both event types (copy `counterCodec`'s shape).
- `splitPairTransducer`: one self-loop edge, `guard = matchInCtor pairCtor`,
  `update = UKeep`, `output = [pack pairCtor pairFirstCtor (inpCtor pairCtor #first *: oNil),
  pack pairCtor pairSecondCtor (inpCtor pairCtor #second *: oNil)]`,
  `target = Pairing`. Note it passes Milestone 1's rule (it emits) and passes
  today's hidden-input check (the union across the chain covers both fields), but
  post-MP-16 keiki's head-recoverability check rightly flags it — so build the
  stream with
  `mkEventStreamWith defaultStreamValidationOptions{transducerOptions = defaultValidationOptions{checkHeadRecoverability = False}} ...`
  (field name per keiki EP-71; adjust to the shipped name). That narrowed-options
  construction is not a cheat: it is precisely the realistic path by which a
  divergent transducer reaches production post-MP-16, and the spec should say so
  in a comment. `stateCodec = Nothing`, `snapshotPolicy = Never` — proving the
  coverage-hole fix (pre-plan code would never have run the check on this stream).

Then the spec, combining the metrics harness (`keiro/test/Main.hs:322-350`) with
the command harness (`:592-609`):

1. Build a real SDK meter with `inMemoryMetricExporter`, `newKeiroMetrics`, and
   `options = defaultRunCommandOptions & #metrics .~ Just metrics`.
2. `runCommand options splitPairStream target (AddPair 1 2)` succeeds:
   `eventsAppended` is 2, `streamVersion` is 2 — the command result is `Right`
   even though divergence was detected (Decision Log).
3. `forceFlushMeterProvider`; `lookup "keiro.snapshot.apply.divergence"
   (flattenScalarPoints exported)` is `Just (IntNumber 1)`.
4. The poisoning is real: a second `runCommand` on the same stream returns
   `Left (HydrationReplayFailed ...)` (match the constructor, not the payload —
   EP-95 owns its detail shape). This is the "divergence witness predicts the next
   hydration failure" acceptance in one test.
5. A sibling spec with `options & #verifyReplayOnAppend .~ False` (fresh stream,
   fresh meter): the command succeeds and the counter exports no point — the
   opt-out really skips the fold for snapshot-less streams.

Optionally (cheap, since `inMemoryListExporter` is already imported at
`keiro/test/Main.hs:268`): assert the span carries a `keiro.replay.divergence`
attribute by running step 2 with a tracer from an in-memory span processor. If the
existing span-test plumbing makes this more than ~20 lines, record it in Progress
as skipped and rely on the counter assertion.

Acceptance: `cabal test keiro-test` green; the new specs pass; the pre-existing
snapshot specs (which exercise `writeSnapshotIfNeeded`'s replaced body through
`snapshotCounterEventStream`) still pass, proving the snapshot path rides the new
shared fold unchanged.

### Milestone 3 — honest no-op global position

Scope: `keiro/src/Keiro/Command.hs`, one spec. Independent of M1/M2.

Change `noOpResult` (lines 675-685) to `globalPosition = Nothing`, with a haddock
sentence on `CommandResult`'s `globalPosition` field (line 112): `Just` only when
this command appended (the store assigned a real position); `Nothing` for a no-op —
the store's per-stream read cannot report a true global position (kiroku returns a
`0` sentinel), so keiro refuses to fabricate one. Then delete the now-dead
bookkeeping that existed only to feed it: the `globalPosition` field of `Hydrated`
(line 205) and its writes (`Just (recorded ^. #globalPosition)` at line 303 and 375
today; if EP-95's fold migration already reshaped these, delete the equivalent in
the migrated accumulator). GHC's `-Wall` (unused fields / incomplete-record-updates
are on, `keiro/keiro.cabal:25-29`) will point at every remaining reference.

The spec needs a stream that has prior events AND accepts a no-op command — the
existing no-op fixture can't rehydrate its own history (its only edge is silent, and
replay skips silent edges), so add a two-command fixture reusing `CounterEvent` /
`counterCodec` (events carry the codec; commands are never serialized, so a new
command type costs nothing):

```haskell
data SkipCommand
    = SAdd !Int
    | SSkip
    deriving stock (Generic, Eq, Show)
```

with `InCtor`s `sAddCtor` (one `Int` slot, mirroring `addCtor` at
`keiro/test/Main.hs:7775-7783`) and `sSkipCtor` (empty slot list; `icMatch` returns
`Just RNil` for `SSkip`), and a single-vertex transducer over `CounterState` with
two edges out of `Counting`: the emitting edge (guard `matchInCtor sAddCtor`,
`UKeep`, output packs `counterAddedCtor` from the command field, target `Counting`)
and the benign silent edge (guard `matchInCtor sSkipCtor`, `UKeep`, `output = []`,
target `Counting`). Build it with plain `mkEventStreamOrThrow` — it must pass
Milestone 1's rule, which doubles as an integration proof that the rule admits
deliberate no-op edges on a mixed transducer.

Spec: on a fresh store, `runCommand ... (SAdd 2)` succeeds (`streamVersion` 1,
`eventsAppended` 1, `globalPosition` `isJust`); then `runCommand ... SSkip` on the
same stream succeeds with `eventsAppended = 0`, `streamVersion = StreamVersion 1`,
and `globalPosition = Nothing`. Before the fix the last assertion fails with
`Just (GlobalPosition 0)` — run the spec once against the unfixed tree to capture
that failing-before evidence in this plan, then land the fix.

Acceptance: the new spec passes; the appended-result specs asserting
`globalPosition isJust` (`keiro/test/Main.hs:602, 902, 1328`) and the
checkpoint-consuming specs (`:1368-1453`) pass untouched.

### Milestone 4 — documentation, changelog, sweep

Scope: close the loop. Add to the root `CHANGELOG.md` under `[Unreleased]`:
breaking — `mkEventStream`/`validateEventStream` now reject state-changing silent
edges (opt-out via `StreamValidationOptions.checkSilentStateChange`);
`validateEventStreamWith`/`mkEventStreamWith` take `StreamValidationOptions`
instead of keiki's `ValidationOptions`; changed — no-op `CommandResult` reports
`globalPosition = Nothing` instead of a fabricated position 0; added —
`RunCommandOptions.verifyReplayOnAppend` (default on) and the
`keiro.snapshot.apply.divergence` counter / `keiro.replay.divergence` span
attribute. Add the counter and attribute rows to
`docs/research/opentelemetry-semconv-audit.md` following its existing per-instrument
format. Update the master plan
(`docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`):
tick EP-99's two Progress lines, set the registry Status to Complete, and note in
its Surprises section that the "register-only silent edge gap" feared by the review
did not materialize (keiki exports `Update (..)`). Run the full sweep and `nix fmt`;
fill this plan's living sections and write the Outcomes & Retrospective entry.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`
inside the dev shell. The test suite provisions its own PostgreSQL (via
`keiro-test-support`'s suite-level template database); no services need starting.

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop                 # toolchain shell; all commands below assume it
cabal build all             # after each milestone's edits
cabal test keiro-test       # the full runtime suite (validation + command + metrics specs)
nix fmt                     # treefmt (fourmolu/cabal-fmt/nixpkgs-fmt) before every commit
```

To iterate on just the new specs while developing, use Hspec's matcher, e.g.:

```bash
cabal test keiro-test --test-options='--match "silent"'
cabal test keiro-test --test-options='--match "divergence"'
```

Expected transcript shape for a full green run (counts will differ; the point is
zero failures and the new groups appearing):

```text
Keiro.EventStream.Validate silent edges
  rejects a silent edge that changes vertex [✔]
  rejects a silent edge that writes registers (keiki accepts it) [✔]
  checkSilentStateChange = False opts out [✔]
Keiro.Command
  counts keiro.snapshot.apply.divergence when an appended batch cannot replay [✔]
  a divergent append still succeeds and poisons the next hydration [✔]
  verifyReplayOnAppend = False skips the fold on snapshot-less streams [✔]
  a no-op command reports globalPosition Nothing [✔]
...
N examples, 0 failures
```

Commit per milestone with conventional-commit messages, for example:

```text
feat(keiro-core)!: reject state-changing silent edges at stream validation (EP-99 M1)
feat(keiro): count and trace append/replay divergence on every append (EP-99 M2)
fix(keiro): no-op commands report globalPosition Nothing, not the kiroku 0 sentinel (EP-99 M3)
docs(keiro): changelog, semconv audit rows, master plan bookkeeping (EP-99 M4)
```


## Validation and Acceptance

Acceptance is behavior, each encoded as a spec named in the milestones:

1. Silent-edge rejection. `mkEventStream "silent-move" silentMoveEventStreamDef`
   returns `Left [w]` where `eswReason w` contains `silent-state-change` and
   `Drained`; the register-write fixture likewise with `writes registers`; for both
   fixtures `Keiki.validateTransducer defaultValidationOptions` returns `[]`,
   demonstrating the rule is keiro's and not duplicated keiki behavior. The
   documented opt-out accepts, and the pre-existing assertions that
   `noOpCounterEventStreamDef` validates clean (`keiro/test/Main.hs:540`, `:568`)
   pass unmodified — the identity self-loop is deliberately not flagged.
2. Divergence witnessed, command unharmed, prophecy fulfilled. On the split-pair
   stream, `runCommand` returns `Right` with `eventsAppended = 2`; the flushed
   in-memory meter shows `keiro.snapshot.apply.divergence` at `IntNumber 1`; a
   second command on the same stream returns `Left (HydrationReplayFailed ...)`.
   With `verifyReplayOnAppend = False` on a snapshot-less stream the counter
   exports no point. Existing snapshot specs (the `snapshotCounterEventStream`
   family) pass unchanged, proving the snapshot write now rides the shared
   `applyEventsEither` fold with identical behavior.
3. No-op position honesty. After one real append, a `SSkip` no-op returns
   `CommandResult` with `streamVersion = StreamVersion 1`, `eventsAppended = 0`,
   `globalPosition = Nothing`. This exact assertion fails before Milestone 3 with
   `Just (GlobalPosition 0)` — capture that output once against the unfixed tree
   (paste it into Surprises & Discoveries) as the failing-before evidence.
4. Nothing else moved: the full `cabal test keiro-test` suite passes, including
   the process-manager no-op spec (`keiro/test/Main.hs:1732`) that runs the benign
   silent edge end to end, and the appended-result `globalPosition isJust` specs.

Final gate: `cabal build all`, `cabal test keiro-test` (zero failures), `nix fmt`
(no diff on a clean tree).


## Idempotence and Recovery

Every step is a source edit plus a test run; all are safe to repeat. The changes
are additive or narrowly breaking with zero external callers (the `*With` signature
change and the `Hydrated` field deletion are compiler-enforced: GHC lists every
site to fix). No migrations, no persisted data formats, no destructive operations.
Milestones are committed separately, each leaving the suite green, so `git revert`
of a single milestone restores a releasable tree. If Milestone 2 must land before
EP-95 for scheduling reasons, it cannot: it consumes `applyEventsEither` from the
post-MP-16 keiki pin — implement M1/M3 first (both are pin-independent) and record
the reordering in Progress. The divergence spec intentionally poisons a stream;
each spec runs against a fresh per-example database clone (`withFreshStore`), so
poisoned fixtures never leak between examples or runs.


## Interfaces and Dependencies

No new package dependencies. keiki and kiroku stay at whatever pins EP-95
establishes (`cabal.project` `source-repository-package` stanzas); this plan
requires the post-MP-16 keiki exports `applyEventsEither`, `ReplayFailure` (with
`Eq`/`Show`), and the keiki EP-71 `ValidationOptions` fields, plus the existing
exports `Edge (..)`, `Update (..)`, `SymTransducer (..)`, and
`defaultValidationOptions` from `Keiki.Core`.

At the end of the plan these exist exactly as written:

```haskell
-- keiro-core/src/Keiro/EventStream/Validate.hs (module Keiro.EventStream.Validate)

data StreamValidationOptions = StreamValidationOptions
    { transducerOptions :: !ValidationOptions -- keiki's, from Keiki.Core
    , checkSilentStateChange :: !Bool         -- default True
    }

defaultStreamValidationOptions :: StreamValidationOptions

validateEventStreamWith ::
    (Bounded s, Enum s, Ord s, Show s) =>
    StreamValidationOptions ->
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    [EventStreamWarning]

mkEventStreamWith ::
    (Bounded s, Enum s, Ord s, Show s) =>
    StreamValidationOptions ->
    Text ->
    EventStream (HsPred rs ci) rs s ci co ->
    Either [EventStreamWarning] (ValidatedEventStream (HsPred rs ci) rs s ci co)

-- module-private:
edgeWritesRegisters :: Edge phi rs ci co s -> Bool
silentEdgeWarnings ::
    (Bounded s, Enum s, Eq s, Show s) =>
    Text -> EventStream phi rs s ci co -> [EventStreamWarning]
```

`validateEventStream`, `mkEventStream`, and `mkEventStreamOrThrow` keep their
current signatures verbatim.

```haskell
-- keiro/src/Keiro/Command.hs (module Keiro.Command)

data RunCommandOptions = RunCommandOptions
    { -- ... existing fields unchanged ...
      verifyReplayOnAppend :: !Bool -- default True
      -- ...
    }

-- CommandResult unchanged in shape; globalPosition is Nothing for no-ops.
-- internal: verifyAndSnapshot replaces writeSnapshotIfNeeded (signature in M2).
```

```haskell
-- keiro/src/Keiro/Telemetry.hs (module Keiro.Telemetry)

keiroSnapshotApplyDivergenceName :: Text -- "keiro.snapshot.apply.divergence"

-- new KeiroMetrics field:
--   snapshotApplyDivergence :: Counter Int64

recordSnapshotApplyDivergence :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()

keiro_replay_divergence :: AttributeKey Text -- "keiro.replay.divergence"
```

Downstream coordination (master plan Integration Points): EP-98 owns
`keiro.snapshot.decode.failures` and any hit/miss counters — untouched here; EP-100
may serialize `CommandError` values (including EP-95's ambiguity constructor) into
dead-letter records — this plan adds no `CommandError` constructors, so EP-100 is
unaffected; keiki owns `TransducerValidationWarning` — this plan adds nothing to
it. One follow-up noted for keiki (not done here — out of scope per the master
plan): exporting an official `edgeWritesRegisters`-style accessor would let keiro
delete its module-private copy; until then the private helper is three total
patterns over an exported GADT and cannot drift silently (a new `Update`
constructor breaks the compile).

---

Revision note (2026-07-11): initial authoring — replaced the generated skeleton
with the full plan. Sources: the master plan's Phase 3 scope, Integration Points
1/2/3/5, and its Decision Log entry on the keiro-side ε-edge rule; direct
verification of `keiro/src/Keiro/Command.hs`,
`keiro-core/src/Keiro/EventStream/Validate.hs`, `keiro/src/Keiro/Telemetry.hs`,
`keiro/test/Main.hs`, the pinned kiroku `Kiroku/Store/SQL.hs` sentinel, and the
keiki sources (`src/Keiki/Core.hs` exports, `Edge`/`Update` GADTs,
`checkHiddenInputs`) plus keiki plans 68, 71, and 72 in the keiki repository. Key
authoring finding: keiki's exported `Update (..)` makes the full silent-edge rule
(vertex change OR register write) implementable keiro-side, eliminating the
review's anticipated register-only gap.
