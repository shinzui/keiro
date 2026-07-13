---
id: 99
slug: silent-edge-validation-and-divergence-witnesses-on-the-command-path
title: "Silent-edge validation and divergence witnesses on the command path"
kind: exec-plan
created_at: 2026-07-12T05:07:53Z
intention: intention_01kxcz37ave9t8d6amvvxnemr6
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
loaded. Post-MP-16 keiki detects this shape (EP-71's default-on
`StateChangingEpsilon` warning), but detection alone leaves two holes at keiro's
boundary: a caller-supplied `ValidationOptions` could switch the check off, and
nothing in keiro's own suite pins the rejection. After this plan,
`Keiro.EventStream.Validate.mkEventStream` can never admit a state-changing silent
edge: the replay-contract checks (`checkStateChangingEpsilon`,
`checkHeadRecoverability`) are force-enabled regardless of caller options, the sole
bypass is a new, loudly named unchecked constructor, and keiro fixtures pin the
rejection end to end. A deliberate no-op self-loop (same vertex, no register writes)
still validates, because it is genuinely harmless and keiki's check deliberately
admits it.

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
register-write fixture even when the caller's options disable the check, while the
existing benign no-op fixture still validates,
(b) show the divergence counter incrementing through a real SDK meter when a
split-coverage transducer appends events that cannot replay, followed by the
predicted `HydrationReplayFailed` on the next command, and (c) show a no-op command
reporting `globalPosition = Nothing` where it previously fabricated `Just 0`.


## Progress

- [x] (2026-07-13T15:52:56Z) M1: replay-contract checks force-enabled in `validateEventStreamWith` / `mkEventStreamWith` (caller options may only strengthen); `mkEventStreamUnchecked` escape hatch added with a loud haddock
- [x] (2026-07-13T15:52:56Z) M1: silent-move fixture, silent register-write fixture, weakened-options-still-rejected specs, and keiki-flags-it spec added to `keiro/test/Main.hs`; existing no-op fixture still validates clean
- [x] (2026-07-13T16:04:07Z) M2: `verifyReplayOnAppend` flag added to `RunCommandOptions` (default `True`)
- [x] (2026-07-13T16:04:07Z) M2: post-append replay check extracted, runs on both append paths, witnesses divergence via counter + span attribute; snapshot write consumes the same fold
- [x] (2026-07-13T16:04:07Z) M2: `keiro.snapshot.apply.divergence` counter and `keiro_replay_divergence` attribute key added to `keiro/src/Keiro/Telemetry.hs`
- [x] (2026-07-13T16:04:07Z) M2: split-coverage divergence spec (counter increments, command still succeeds, next command fails with `HydrationReplayFailed`)
- [x] (2026-07-13T16:12:22Z) M3: `noOpResult` reports `globalPosition = Nothing`; dead `Hydrated.globalPosition` bookkeeping removed
- [x] (2026-07-13T16:12:22Z) M3: no-op globalPosition normalization spec (fails before the fix)
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
  (Superseded 2026-07-12: keiki MP-16's revision moved detection into keiki EP-71's
  `StateChangingEpsilon` check, so keiro implements no scan; the finding stands as
  evidence the rule was implementable and as the shared predicate's provenance —
  see the Decision Log.)
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
- Milestone 1 confirmed the published Keiki API matches the authored contract:
  `ValidationOptions` exposes `checkStateChangingEpsilon` and
  `checkHeadRecoverability`, and `StateChangingEpsilon` is directly matchable in
  the Keiro test suite. The focused `mkEventStream` run reported 12 examples and
  zero failures, including both forced-on checks and the unchecked escape hatch.
  Evidence: `cabal test keiro-test --test-options='--match "mkEventStream"'`;
  the milestone gate also passed `cabal build all` and the full 312-example
  `cabal test keiro-test` suite.
- Milestone 2 did not need the authored two-field `PairCommand` fixture. EP-95
  had already added `headUnrecoverableEventStreamDef`, whose head uses a literal
  and whose tail alone carries `CounterCommand.amount`; it is the same
  split-coverage failure shape. Mounting that existing fixture through
  `mkEventStreamUnchecked` produced `event_index=0;reason=no_inverting_edge`,
  incremented the divergence counter, and caused the next hydration to fail as
  predicted. Focused plain-runner, opt-out, and transactional-SQL-path specs all
  passed; the milestone gate then passed `cabal build all` and all 315
  `keiro-test` examples.
- Milestone 3's red test reproduced the fabricated sentinel exactly before the
  fix:

  ```text
  expected: Nothing
   but got: Just (GlobalPosition 0)
  ```

  After `noOpResult` was normalized and the dead `Hydrated.globalPosition`
  field removed, the focused spec passed; the milestone gate then passed
  `cabal build all` and all 316 `keiro-test` examples. EP-95's replay
  accumulator still retains its last `RecordedEvent`, but that is not dead
  global-position bookkeeping: it supplies the real stream version and precise
  hydration failure location.


## Decision Log

- Decision: keiro implements no silent-edge scan of its own. Detection is keiki
  EP-71's default-on `StateChangingEpsilon` warning; this plan's Milestone 1
  force-enables the replay-contract checks (`checkStateChangingEpsilon`,
  `checkHeadRecoverability`) in `validateEventStreamWith`/`mkEventStreamWith`
  regardless of caller-supplied `ValidationOptions`, pins the rejection with
  keiro-side fixtures, and adds `mkEventStreamUnchecked` as the only bypass.
  Rationale: supersedes (2026-07-12) the original keiro-side-scan decision, per the
  agreed division with keiki MP-16. The scan is a structural traversal of keiki's
  edge/update AST, and a keiro copy would drift when keiki EP-74/EP-75 reshape that
  AST. keiki's opt-out exists for pure non-persisted transducers and must be
  unreachable from keiro's durable boundary, because under keiro's model a
  state-changing silent edge is never right (zero-silent-divergence principle, user
  directive 2026-07-12). The keiro-owned `snapshotWarnings` precedent
  (`keiro-core/src/Keiro/EventStream/Validate.hs:159-169`) still governs genuinely
  keiro-only rules.
  Date: 2026-07-12 (supersedes the 2026-07-11 keiro-side-rule decision)

- Decision: the rule's predicate — flag every edge with `output == []` whose
  `target` differs from its source vertex OR whose update is not syntactically
  `UKeep` (recursively: a `UCombine` tree containing any `USet`), with deliberate
  syntactic conservatism — is specified in keiki EP-71 Milestone 5, not here. This
  plan's fixtures assert keiro observes exactly that predicate through the rendered
  warning, including the no-op `UKeep` self-loop staying clean.
  Rationale: one definition, owned next to the AST it walks; keiro's job is to
  verify the boundary behavior it depends on. The predicate itself is unchanged
  from this plan's original design — it was adopted upstream.
  Date: 2026-07-12 (supersedes the 2026-07-11 keiro-side predicate decision)

- Decision: no keiro-side `StreamValidationOptions` record and no
  `checkSilentStateChange` opt-out. `validateEventStreamWith` and
  `mkEventStreamWith` keep taking keiki's `ValidationOptions` but force the
  replay-contract flags back on (`checkStateChangingEpsilon = True`,
  `checkHeadRecoverability = True`) on whatever the caller passes, before invoking
  `validateTransducer`; the haddock states that caller options may only strengthen
  validation at this boundary. The only bypass is `mkEventStreamUnchecked` — a
  separate, loudly named constructor function whose haddock restricts it to tests
  and emergency forensics, never production streams. The no-options entry points
  `validateEventStream` / `mkEventStream` / `mkEventStreamOrThrow` keep their exact
  signatures.
  Rationale: under keiro's runtime model a state-changing silent edge is never
  right — it validates, reports success, and un-happens — and an opt-out field
  reachable from the durable boundary is itself a bug vector
  (zero-silent-divergence principle, user directive 2026-07-12). Fail-fast matches
  `mkEventStream`'s existing fail-on-any-warning posture
  (`keiro-core/src/Keiro/EventStream/Validate.hs:117-120`). The non-contract checks
  (`checkInversionAmbiguity`, `checkGuardImpliesInputRead`) stay caller-narrowable:
  they have a documented legitimate-override story (manually proven semantic
  disjointness), and Milestone 2's runtime divergence witness is the net for a
  wrong override. Signature impact is nil outside the module: no caller of the
  `*With` variants exists anywhere in the repository (verified by grep,
  2026-07-11).
  Date: 2026-07-12 (supersedes the 2026-07-11 `StreamValidationOptions` decision)

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

- Decision: render the `keiro.replay.divergence` span attribute as a bounded,
  structured summary (`event_index=<n>;reason=<class>`) rather than `show`ing
  the entire `ReplayFailure` value.
  Rationale: `ReplayFailure`'s derived `Show` instance requires `Show s` and
  `Show co`, but Keiro's public command runners deliberately require neither.
  Adding those constraints would be an unrelated source-breaking API change.
  The index and typed reason class preserve the operational witness without
  widening the runner contracts or leaking event payloads into telemetry.
  Date: 2026-07-13

- Decision: reuse EP-95's existing `headUnrecoverableEventStreamDef` as the
  Milestone 2 split-coverage fixture instead of adding the authored
  `PairCommand`/`PairEvent` duplicate.
  Rationale: the existing edge has the identical replay defect — the first
  output cannot recover the command field and the tail alone carries it — and
  the test proves the same counter, span, successful-append, and poisoned-next-
  hydration behavior with less fixture surface.
  Date: 2026-07-13


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
such a transducer in the pre-MP-16 world: keiki's validator flagged only ε-edges
whose update *reads the command* (`HirEpsilonReadsInput`, keiki
`src/Keiki/Core.hs:1371-1374` — a replay-safety concern, not a durability one), and
keiro's `Validate.hs` adds only the snapshot-policy check. Post-MP-16 keiki EP-71
adds the default-on `StateChangingEpsilon` check that flags exactly this shape. The
division of labor is fixed by the master plan's revised Decision Log (2026-07-12):
keiki *detects* (plan 68 makes silent edges an explicit authoring choice via
`noEmit`; EP-71 warns on the state-changing ones); keiro *enforces* —
force-enabling the check so no caller-supplied options can weaken the durable
boundary — because only keiro knows events are the sole persistence.

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
- keiki's `validateTransducer` has four new checks ON by default (keiki EP-71):
  head-recoverability, inversion ambiguity, guard-implies-input-read, and
  state-changing epsilon, gated by new `ValidationOptions` fields
  (`checkHeadRecoverability`, `checkInversionAmbiguity`, the guard-read flag, and
  `checkStateChangingEpsilon`). EP-95 has added the exhaustive `renderWarning` arms
  for the new constructors (including `state-changing-epsilon`) in
  `keiro-core/src/Keiro/EventStream/Validate.hs` — Milestone 1 here edits the same
  module and must rebase on those arms (master plan Integration Point 2).
- EP-95 has replaced the duplicated `hydrate`/`hydrateFull` folds
  (`keiro/src/Keiro/Command.hs:221-378`) with keiki's seedable `replayEvents` fold
  and made `HydrationReplayFailed` carry structured detail, and `evaluateCommand`
  distinguishes ambiguous guards from rejection via `stepEither` (master plan
  Integration Point 1). Milestone 3's bookkeeping deletion adapts to whatever
  accumulator shape EP-95 left.

Milestone 1 requires the post-MP-16 keiki pin (the `checkStateChangingEpsilon` and
`checkHeadRecoverability` fields must exist) and rebases on EP-95's rendered arms;
Milestones 2 and 3 additionally assume the post-EP-95 hydration shape. Only
Milestone 3 is pin-independent and may land first if scheduling demands it.

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

Four milestones. M1 is the boundary hardening (keiro-core: force-enable +
unchecked escape hatch + pinning specs), M2 the divergence witness (keiro runtime +
telemetry), M3 the no-op position fix (small, independent), M4 the
documentation/changelog sweep. Each leaves `cabal build all && cabal test keiro-test`
green.

### Milestone 1 — force-enable the replay-contract checks and pin keiki's rejection

Scope: `keiro-core/src/Keiro/EventStream/Validate.hs` plus specs in
`keiro/test/Main.hs`. At the end, no public construction path can admit a
transducer containing a silent edge that changes the vertex or writes a register —
not even with caller-weakened options; the benign no-op self-loop still validates;
the only bypass is a new, loudly named unchecked constructor. Detection itself is
keiki EP-71's (`StateChangingEpsilon`, rendered by EP-95's `renderWarning` arm);
this milestone adds no scan of its own.

In `keiro-core/src/Keiro/EventStream/Validate.hs`:

Add a module-private normalizer and apply it in `validateEventStreamWith`
(lines 88-92) before calling `validateTransducer`:

```haskell
-- | keiro's durable boundary: events are the only persistence, so the
-- replay-contract checks are not negotiable. Caller-supplied options may
-- only strengthen validation; these flags are forced back on (EP-99).
forceReplayContract :: ValidationOptions -> ValidationOptions
forceReplayContract opts =
    opts
        { checkStateChangingEpsilon = True
        , checkHeadRecoverability = True
        }
```

(Field names per keiki EP-71; re-verify against the shipped pin.) The non-contract
checks (`checkInversionAmbiguity`, `checkGuardImpliesInputRead`) remain
caller-narrowable: they have a documented legitimate-override story, and
Milestone 2's divergence witness is the runtime net for a wrong override.
`validateEventStreamWith` and `mkEventStreamWith` keep their signatures (keiki's
`ValidationOptions` first parameter); update the `mkEventStreamWith` haddock so its
"narrow options" sentence states that narrowing cannot reach the replay-contract
checks and why, and update the module haddock's bullet list to name the
force-enabled pair.

Add the escape hatch, exported and loud:

```haskell
-- | Wrap an 'EventStream' WITHOUT validation. This skips every keiki and
-- keiro check, including the replay-contract checks that 'mkEventStream'
-- force-enables. A stream admitted through this function can silently lose
-- state changes and fail hydration. Tests and emergency forensics only —
-- never production streams. Prefer 'mkEventStream'.
mkEventStreamUnchecked ::
    EventStream phi rs s ci co -> ValidatedEventStream phi rs s ci co
mkEventStreamUnchecked = ValidatedEventStream
```

Export it in its own export-list section with a comment matching the haddock's
severity. (Milestone 2's divergence spec is its first consumer — the public path
now rejects the divergent fixture, which is the point.)

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
  `stateCodec = Nothing`. Spec: the keiki-flags-it proof —
  `Keiki.validateTransducer defaultValidationOptions silentMoveTransducer` is
  non-empty and contains a `StateChangingEpsilon` (detection is upstream);
  `validateEventStream "silent-move" ...` yields a warning whose rendered reason
  contains `"state-changing-epsilon"`; `mkEventStream` returns `Left`.
- A silent register-write self-loop fixture over `SnapshotCounterRegs` (the
  existing one-slot register schema, `keiro/test/Main.hs:7541`): copy
  `snapshotCounterTransducer` (`keiro/test/Main.hs:7659-7677`) but set
  `output = []` and change the `USet`'s right-hand side from
  `inpCtor addCtor #amount` to `lit 0` — the literal matters, so the spec shows
  `StateChangingEpsilon` firing alone rather than keiki's `HirEpsilonReadsInput`.
  Spec: rejected with a reason containing `"state-changing-epsilon"`.
- The force-enable proof:
  `mkEventStreamWith defaultValidationOptions{checkStateChangingEpsilon = False} "silent-move" ...`
  STILL returns `Left` — the weakened options are overridden at the boundary. A
  sibling assertion does the same for `checkHeadRecoverability = False` against a
  head-unrecoverable fixture (reuse EP-95's M1 fixture).
- The bypass is loud and works: `mkEventStreamUnchecked` on the silent-move stream
  produces a `ValidatedEventStream` (compile-level proof suffices here —
  Milestone 2 exercises it for real).
- Regression by existing assertion: the specs at `keiro/test/Main.hs:540` and
  `:568` already pin `noOpCounterEventStreamDef` (identity self-loop) as clean and
  accepted — they must keep passing untouched (keiki's `UKeep` self-loop
  carve-out), and the `timerOnlyProcessManager` spec (line 1732) keeps exercising
  it end to end.

Acceptance: `cabal test keiro-test` green; both fixtures are rejected with the
`state-changing-epsilon` reason through the default AND the weakened-options
paths; keiki's validator is shown non-clean on both (detection is upstream); every
pre-existing validation spec is unchanged.

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
  `addAttribute sp (unkey keiro_replay_divergence) (Text.take 256 (renderReplayFailure failure))`.
  `renderReplayFailure` records the zero-based failed event index and one of the
  structured reason classes `no_inverting_edge`, `ambiguous_inversions`,
  `queue_mismatch`, or `log_truncated`; this avoids adding `Show` constraints to
  the public runners. No snapshot is attempted (there is no trustworthy final
  state) and the function returns normally. On `Right finalState`: proceed with
  the existing snapshot body verbatim (terminality computation,
  `shouldSnapshotSpan`, `writeSnapshot`, swallow-and-count via
  `recordSnapshotWriteFailures`).
- Thread the span: both runners already receive `mSpan` in their `withCommandSpan`
  lambda (lines 393 and 464); pass it as a new parameter through
  `attempt`/`runPlan`/`appendOnce` (and the `WithSqlEvents` equivalents) to the
  `verifyAndSnapshot` call sites that replace `writeSnapshotIfNeeded` at lines 424
  and 503. This is mechanical parameter plumbing; no behavior change.
- Update the module haddock's snapshot paragraph (lines 26-29) to describe the
  replay check and its advisory posture.

The divergence specs live in `keiro/test/Main.hs` under `describe
"Keiro.Command"`. They reuse EP-95's `headUnrecoverableEventStreamDef`: its
two-event edge emits a literal-valued head and carries `CounterCommand.amount`
only in the tail, so forward execution succeeds but replay cannot recover the
command from the head. The public boundary rejects this transducer; the fixture
is deliberately mounted with `mkEventStreamUnchecked` to stand in for a legacy
stream or a future validator blind spot. It has `stateCodec = Nothing` and
`snapshotPolicy = Never`, proving the pre-plan snapshot-only coverage hole is
closed. A sibling transactional-SQL spec proves both append paths use the same
epilogue.

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
(line 205) and its write in the migrated replay result. Keep the accumulator's
last `RecordedEvent`: EP-95 made it responsible for the real stream version and
precise replay-failure location, not just the discarded global position. GHC's
`-Wall` (unused fields / incomplete-record-updates are on,
`keiro/keiro.cabal:25-29`) will point at every remaining reference.

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
breaking — `validateEventStreamWith`/`mkEventStreamWith` force-enable the
replay-contract checks (`checkStateChangingEpsilon`, `checkHeadRecoverability`);
caller options may only strengthen validation, so state-changing silent edges are
rejected on every public construction path; added — `mkEventStreamUnchecked`
(loud, tests/forensics only); changed — no-op `CommandResult` reports
`globalPosition = Nothing` instead of a fabricated position 0; added —
`RunCommandOptions.verifyReplayOnAppend` (default on) and the
`keiro.snapshot.apply.divergence` counter / `keiro.replay.divergence` span
attribute. Add the counter and attribute rows to
`docs/research/opentelemetry-semconv-audit.md` following its existing per-instrument
format. Update the master plan
(`docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`):
tick EP-99's two Progress lines, set the registry Status to Complete, and confirm
its Surprises entry about the silent-edge division (detection in keiki EP-71,
enforcement here) matches what shipped. Run the full sweep and `nix fmt`; fill
this plan's living sections and write the Outcomes & Retrospective entry.


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
  rejects a silent edge that changes vertex (keiki StateChangingEpsilon) [✔]
  rejects a silent edge that writes registers [✔]
  weakened caller options are overridden at the boundary [✔]
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
feat(keiro-core)!: force-enable replay-contract validation; add mkEventStreamUnchecked (EP-99 M1)
feat(keiro): count and trace append/replay divergence on every append (EP-99 M2)
fix(keiro): no-op commands report globalPosition Nothing, not the kiroku 0 sentinel (EP-99 M3)
docs(keiro): changelog, semconv audit rows, master plan bookkeeping (EP-99 M4)
```


## Validation and Acceptance

Acceptance is behavior, each encoded as a spec named in the milestones:

1. Silent-edge rejection. `mkEventStream "silent-move" silentMoveEventStreamDef`
   returns `Left [w]` where `eswReason w` contains `state-changing-epsilon`; the
   register-write fixture is likewise rejected; for both fixtures
   `Keiki.validateTransducer defaultValidationOptions` is non-empty with a
   `StateChangingEpsilon`, demonstrating detection is keiki's and keiro adds no
   second scan. Weakened caller options (`checkStateChangingEpsilon = False`,
   `checkHeadRecoverability = False`) are overridden and still reject; only
   `mkEventStreamUnchecked` admits the fixture; and the pre-existing assertions
   that `noOpCounterEventStreamDef` validates clean (`keiro/test/Main.hs:540`,
   `:568`) pass unmodified — the identity self-loop is deliberately not flagged.
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
are additive or narrowly breaking with zero external callers (the force-enable
behavior change has no `*With` callers in the repository, and the `Hydrated` field
deletion is compiler-enforced: GHC lists every site to fix). No migrations, no
persisted data formats, no destructive operations. Milestones are committed
separately, each leaving the suite green, so `git revert` of a single milestone
restores a releasable tree. If Milestone 2 must land before EP-95 for scheduling
reasons, it cannot: it consumes `applyEventsEither` from the post-MP-16 keiki pin —
and Milestone 1 needs the pin's `ValidationOptions` fields; implement M3 first
(the only pin-independent milestone) and record the reordering in Progress. The divergence spec intentionally poisons a stream;
each spec runs against a fresh per-example database clone (`withFreshStore`), so
poisoned fixtures never leak between examples or runs.


## Interfaces and Dependencies

No new package dependencies. keiki and kiroku stay at whatever pins EP-95
establishes (`cabal.project` `source-repository-package` stanzas); this plan
requires the post-MP-16 keiki exports `applyEventsEither`, `ReplayFailure` (with
`Eq`/`Show`), and the keiki EP-71 `ValidationOptions` fields
(`checkStateChangingEpsilon` and `checkHeadRecoverability` among them), plus the
existing export `defaultValidationOptions` from `Keiki.Core`.

At the end of the plan these exist exactly as written:

```haskell
-- keiro-core/src/Keiro/EventStream/Validate.hs (module Keiro.EventStream.Validate)

-- validateEventStreamWith / mkEventStreamWith keep their existing signatures
-- (keiki's ValidationOptions first parameter) but force the replay-contract
-- flags back on before validating. Module-private:
forceReplayContract :: ValidationOptions -> ValidationOptions

-- Exported, loud haddock, tests and emergency forensics only:
mkEventStreamUnchecked ::
    EventStream phi rs s ci co -> ValidatedEventStream phi rs s ci co
```

`validateEventStream`, `validateEventStreamWith`, `mkEventStream`,
`mkEventStreamWith`, and `mkEventStreamOrThrow` keep their current signatures
verbatim; only `*With` behavior changes (weakened replay-contract flags are
overridden).

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
unaffected; keiki owns `TransducerValidationWarning` and the silent-edge detection
itself (EP-71's `StateChangingEpsilon`) — this plan adds nothing to either; keiro's
contribution is the force-enable boundary, the pinning fixtures, and the unchecked
escape hatch.

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

Revision note (2026-07-12): rescoped Milestone 1 per the revised division of labor
with keiki MP-16 — detection moved into keiki EP-71's default-on
`StateChangingEpsilon` check, so this plan no longer implements
`silentEdgeWarnings`/`edgeWritesRegisters` or a `StreamValidationOptions` record.
Milestone 1 now force-enables the replay-contract checks
(`checkStateChangingEpsilon`, `checkHeadRecoverability`) against caller-supplied
options, adds the loudly named `mkEventStreamUnchecked` escape hatch (which
Milestone 2's divergence spec uses to mount its deliberately divergent fixture,
since the public path now rejects it), and pins the rejection with the original
fixture set. Milestones 2–4 are otherwise unchanged; the runtime divergence
witness is retained as defense in depth behind the static checks.

Revision note (2026-07-13): implemented Milestone 1 and associated this child plan
with the MasterPlan's existing intention. Keiro now force-enables both durable
replay-contract checks, exposes only a loudly named wholly unchecked bypass, and
pins the boundary behavior with silent vertex-change and caller-weakening specs.

Revision note (2026-07-13): implemented Milestone 2. Every append path now shares
one structured `applyEventsEither` epilogue with snapshotting, divergence is
counted and traced without changing the committed command result, the default-on
flag has a tested snapshot-less opt-out, and both plain and transactional SQL
append paths have focused regression coverage.

Revision note (2026-07-13): implemented Milestone 3 after capturing the planned
red test showing `Just (GlobalPosition 0)`. No-op results now report `Nothing`,
appended results still expose the store-assigned position, and the obsolete
`Hydrated.globalPosition` field is gone while EP-95's version/failure-location
accumulator remains intact.
