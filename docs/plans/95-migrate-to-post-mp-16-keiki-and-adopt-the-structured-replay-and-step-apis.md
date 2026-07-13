---
id: 95
slug: migrate-to-post-mp-16-keiki-and-adopt-the-structured-replay-and-step-apis
title: "Migrate to post-MP-16 keiki and adopt the structured replay and step APIs"
kind: exec-plan
created_at: 2026-07-12T05:07:53Z
intention: intention_01kxcz37ave9t8d6amvvxnemr6
master_plan: "docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md"
---

# Migrate to post-MP-16 keiki and adopt the structured replay and step APIs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is Phase 1 (EP-95) of the master plan at
`docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`.
Its hard dependency is external: keiki MasterPlan 16 (in the sibling keiki repository at
`/Users/shinzui/Keikaku/bokuno/keiki`, plan file
`docs/masterplans/16-harden-keiki-correctness-and-api-surfaces-surfaced-by-the-2026-07-architecture-review.md`)
must be implemented before this plan runs. On 2026-07-13 the user confirmed that
keiki 0.2.0.0 is published to Hackage. The keiki repository's MP-16 registry marks
EP-71, EP-72, and every other child Complete, and release tag `v0.2.0.0` points at
the completed implementation, so this dependency is satisfied.

**Specification caveat, read first.** This plan was written against the keiki APIs as
*specified* in two keiki ExecPlans — EP-71
(`/Users/shinzui/Keikaku/bokuno/keiki/docs/plans/71-align-build-time-validation-with-replay-head-recoverability-cross-edge-inversion-ambiguity-and-guard-implies-input-read-checks.md`)
and EP-72
(`/Users/shinzui/Keikaku/bokuno/keiki/docs/plans/72-structured-replay-diagnostics-reconstituteeither-strict-evolve-policy-and-multi-event-outputacceptor.md`)
— not against shipped code. Every keiki signature quoted here is subject to those plans'
own Decision Logs. The first concrete step of Milestone 1 is therefore to re-verify each
quoted keiki name and signature against the released keiki source, and to record
any drift in this plan's Surprises & Discoveries before editing keiro. (One keiki API
this plan adopts exists today and needs no such caution: `stepEither` and its
`StepFailure` vocabulary, at `/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs:959-1009`.)


## Purpose / Big Picture

keiro is an event-sourcing framework: an application's aggregate state is never stored
directly — only its *events* are, in PostgreSQL, and the current state is recomputed by
*replaying* those events through a pure state machine provided by the keiki library.
Because replay is the only road back to state, a replay failure is the worst thing that
can happen to a keiro service, and today keiro learns almost nothing when it does
happen: keiki's old replay API returned a bare `Nothing` for every distinct failure, and
keiro's command evaluator conflated "the aggregate rejected this command" (a normal
business outcome) with "two transitions matched at once" (a determinism bug in the
aggregate definition).

After this plan, three user-visible things are true:

1. keiro builds and runs against post-MP-16 keiki. Aggregates whose event shapes would
   *silently fail replay in production* — multi-event transitions whose first event
   cannot reconstruct the command, transition pairs replay cannot tell apart, and
   transitions that can crash instead of rejecting — are now rejected at service
   startup by `mkEventStream`, with a rendered reason such as
   `head-unrecoverable @Counting: ...`, instead of surfacing months later as a stream
   that will not hydrate.
2. When hydration of a stored stream does fail, the `CommandError` names *which stored
   event* failed (by its durable stream version) and *why*, as a typed value: no
   inverting edge, ambiguous inversion, mid-chain queue mismatch, or a truncated
   multi-event chain. An operator (or the EP-99/EP-100 plans that consume this
   taxonomy) can distinguish "someone wrote a foreign event into this stream" from
   "the log ends mid-transaction" without reading code.
3. A command that hits *runtime guard ambiguity* — two transitions matched, a
   single-valuedness violation that was always a bug — is reported as a new
   `CommandAmbiguous` error with its own `error.type` telemetry class, instead of
   masquerading as an ordinary `CommandRejected`. Process managers and routers halt on
   it (it is deterministic, retrying cannot help) exactly as they already halt on
   rejections, but the halt reason now tells the truth.

The migration deliberately changes **no delivery or persistence semantics**: it is
mechanical adoption of keiki's structured APIs plus an error-taxonomy refinement. The
observable proof is `cabal test keiro-test` passing with new tests that (a) assert the
typed hydration reasons against deliberately corrupted streams — closing the review's
finding that `HydrationReplayFailed` appeared in **no** runtime assertion — and (b)
assert `CommandAmbiguous` against an aggregate the validator provably cannot flag.


## Progress

Use this checklist to track granular steps; split partially-done items into "done" and
"remaining" parts at every stopping point.

- [x] (2026-07-13 15:09Z) M1: keiki 0.2.0.0 re-verified against shipped MP-16 code; the specified warning/replay/step APIs match the release
- [x] (2026-07-13 15:13Z) M1: Git source overrides removed; package bounds require Hackage `keiki` and `keiki-codec-json` 0.2; workspace builds
- [x] (2026-07-13 15:13Z) M1: four new render arms added to `renderWarning` in `keiro-core/src/Keiro/EventStream/Validate.hs`; haddock count fixed
- [x] (2026-07-13 15:13Z) M1: fail-fast posture for the new warnings confirmed and documented (no code change needed — see Decision Log); module haddock updated
- [x] (2026-07-13 15:13Z) M1: validation specs extended (head-unrecoverable, inversion-ambiguity, unguarded-input-read, state-changing-epsilon all rejected by `mkEventStream` with the expected rendered prefixes); existing fixture-audit spec green
- [x] (2026-07-13 15:30Z) M1 follow-up: obsolete kiroku and pg-migrate Git pins plus `cabal.project.local` removed; default Cabal resolves `kiroku-store-0.3.0.0`, `kiroku-store-migrations-0.2.0.0`, and pg-migrate 1.0 from Hackage
- [x] (2026-07-13 15:22Z) M2: `HydrationReplayReason` added; `HydrationReplayFailed` extended to carry it
- [x] (2026-07-13 15:22Z) M2: `hydrate`/`hydrateFull` collapsed into one seeded fold over keiki's `replayEvents`; duplicated fold deleted
- [x] (2026-07-13 15:22Z) M2: `commandErrorClass` refined for the four hydration reasons
- [x] (2026-07-13 15:22Z) M2: corrupted-stream tests added (no-inverting-edge, queue-mismatch, truncated-chain, ambiguous-inversion) — the first runtime assertions ever on `HydrationReplayFailed`
- [x] (2026-07-13 15:37Z) M3: `evaluateCommand` rewritten over `Keiki.stepEither`; `CommandAmbiguous` constructor added
- [x] (2026-07-13 15:37Z) M3: `commandErrorClass` and `isTransientCommandError` updated for `CommandAmbiguous`; all `CommandError` match sites audited (list in Context)
- [x] (2026-07-13 15:37Z) M3: ambiguity tests added (`CommandAmbiguous [0,1]` end-to-end with no append and `command_ambiguous` telemetry; `ackForCommandError` halts on it)
- [x] (2026-07-13 15:45Z) M4: full sweep green (`cabal build all`, `just haskell-test`, `nix fmt -- --no-cache`); in-repo `jitsurei` and `keiro-dsl` recompiled without source edits
- [x] (2026-07-13 15:45Z) M4: `CHANGELOG.md` entry written, including the behavior-visible ambiguity and telemetry changes
- [x] (2026-07-13 15:45Z) M4: master plan registry row EP-95 flipped to Complete; its three EP-95 progress boxes ticked; Outcomes & Retrospective written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation, with concise evidence.

- (from plan authoring, 2026-07-12) The fail-fast question this plan was asked to
  decide — should keiro treat keiki's four new replay-breaking warnings as validation
  *failures* rather than rendered advisories? — turns out to be already answered by
  keiro's existing structure: `mkEventStreamWith`
  (`keiro-core/src/Keiro/EventStream/Validate.hs:117-120`) returns `Left warns` for
  **any** non-empty warning list. There is no severity tiering to extend; every keiki
  warning is already a stream-construction failure at keiro's boundary. The decision
  reduces to affirming this posture (see Decision Log) rather than writing code.
- (from plan authoring, 2026-07-12; superseded below) keiki's pure determinism
  validator was expected to prove overlap only for bare `PTop` and `PInCtor` guards,
  so the authored ambiguity fixture used a `PAnd` wrapper to remain unproven.
- (2026-07-13) Keiki MP-16 is fully Complete and release tag `v0.2.0.0`
  (`755a01d`) is published on Hackage as both `keiki-0.2.0.0` and
  `keiki-codec-json-0.2.0.0`. The shipped warning constructors, default-on option
  fields, replay failures, `replayEvents`, and `stepEither` match this plan's
  specified names and fields. The migration therefore needs no API adaptation, but
  the dependency step changes from a Git commit pin to ordinary Hackage bounds per
  the user's 2026-07-13 directive.
- (2026-07-13) Keiki EP-76 strengthened `provablyOverlap` before 0.2.0.0: it now
  proves compatible conjunction spines containing constructor tests and supported
  literal comparisons. The authored `PAnd (matchInCtor addCtor) PTop` ambiguity
  fixtures would therefore fail the determinism check. The migrated fixtures use
  `PAnd (matchInCtor addCtor) (PNot PBot)` instead: the guard is true at runtime but
  intentionally outside the pure proof fragment, so a validated runtime ambiguity
  remains possible and testable.
- (2026-07-13; resolved below) The ignored, user-owned `cabal.project.local` combined local
  kiroku 0.3 packages with `cabal.project`'s kiroku 0.2.1 source pins, so default
  dependency solving failed before compilation. Initial validation used a temporary project
  file that imports only `cabal.project`; through it Cabal downloaded both keiki
  0.2.0.0 packages from Hackage, `cabal build all` passed, all four focused warning
  specs passed, and the production-stream audit remained clean. The local overlay is
  untouched.
- (2026-07-13) The shipped `replayEvents` signature and index semantics matched the
  plan exactly. The replacement fold groups the store stream with Streamly's public
  `foldMany (Fold.take n Fold.toList)`, replays each decoded prefix before surfacing a
  later decode error, and retains snapshot fallback behavior. Full `keiro-test`
  validation passed 308 examples with zero failures, including the nested compile-time
  API probe through the temporary Cabal wrapper.
- (2026-07-13) Hackage now carries the complete dependency set previously overlaid
  locally: `kiroku-store-0.3.0.0`, `kiroku-store-migrations-0.2.0.0`, and every
  pg-migrate package Keiro consumes at 1.0.0.0. After deleting their seven Git source
  stanzas and the ignored `cabal.project.local`, ordinary `cabal build all` and
  `cabal test keiro-test` succeeded; the latter passed all 308 examples, including
  the nested compile-time API probe without a wrapper.
- (2026-07-13) `stepEither` preserved every existing rejection outcome while exposing
  the previously collapsed ambiguity witness. The full suite passed 309 examples;
  the in-repo Jitsurei rejection assertions and generated DSL `CommandRejected`
  disposition matches required no edits, confirming they remain no-edge/no-match
  business outcomes rather than ambiguity paths.
- (2026-07-13) The optional `just verify` gate exposed a stale Jitsurei migration
  recipe that still invoked the pre-pg-migrate bare/Codd CLI. It now calls
  `keiro-migrate up --database-url …`. The existing developer database has legacy
  schema objects without the native ledger, so it was preserved untouched; the gate
  passed against a fresh task-scoped database, which was removed afterward.

(Add implementation-time entries here.)


## Decision Log

- Decision: consume `keiki >=0.2 && <0.3` and `keiki-codec-json >=0.2 && <0.3`
  from Hackage, removing both keiki `source-repository-package` stanzas from
  `cabal.project`, instead of replacing their old Git tags with release commit
  `755a01d`.
  Rationale: the user explicitly requested the latest Hackage release now that
  0.2.0.0 unblocks EP-95. PVP upper bounds keep later breaking releases from being
  selected silently while allowing compatible 0.2 bugfix releases.
  Date: 2026-07-13

- Decision: resolve Kiroku and pg-migrate from Hackage and remove
  `cabal.project.local`; constrain direct `kiroku-store` dependencies to
  `>=0.3 && <0.4`, retain `kiroku-store-migrations ^>=0.2.0.0`, and retain the
  pg-migrate 1.0 bounds.
  Rationale: the user confirmed pg-migrate is published and asked whether the local
  overlay can go. The Hackage index contains every consumed package, and a clean
  build plus the complete Keiro test suite prove the published graph is sufficient.
  PVP upper bounds preserve deliberate upgrade boundaries.
  Date: 2026-07-13

- Decision: use `PAnd (matchInCtor addCtor) (PNot PBot)` for the deliberately
  ambiguous validation and command fixtures.
  Rationale: keiki 0.2's strengthened pure overlap proof now recognizes the
  originally authored `PAnd ... PTop` shape. `PNot` is deliberately outside that
  sound-but-incomplete fragment while evaluating to true here, preserving the
  required validated-yet-ambiguous runtime witness without disabling determinism.
  Date: 2026-07-13

- Decision: keiro keeps its existing all-warnings-fail posture for the four new keiki
  warning constructors — `HeadUnrecoverable`, `InversionAmbiguity`,
  `UnguardedInputRead`, and `StateChangingEpsilon` cause
  `mkEventStream`/`mkEventStreamOrThrow` to reject the stream, with no keiro-side
  severity tiering.
  Rationale: keiro's entire persistence model rests on replay (events are the only
  state), and all four new warnings mark shapes that break replay, silently lose
  state, or crash the step function at runtime. keiro's boundary already fails on any
  warning (`mkEventStreamWith`, `keiro-core/src/Keiro/EventStream/Validate.hs:117-120`),
  so fail-fast comes for free; a caller who has manually proven a flagged shape safe
  (for example semantically disjoint guards behind an `InversionAmbiguity` pair) can
  narrow the non-contract checks per stream via `mkEventStreamWith` with a record
  update on `defaultValidationOptions` — the escape hatch keiki EP-71 documents.
  EP-99 subsequently force-enables the replay-contract pair
  (`checkStateChangingEpsilon`, `checkHeadRecoverability`), so narrowing remains
  possible only for `checkInversionAmbiguity` and `checkGuardImpliesInputRead`.
  Date: 2026-07-12

- Decision: `CommandError` stays monomorphic (no vertex/event type parameters, no new
  `Show` constraints on the runners). The typed hydration reason is carried as a new
  keiro-side enumeration `HydrationReplayReason` plus the failing event's
  `StreamVersion`; the ambiguity witness is carried as the matched edges' zero-based
  indices (`[Int]`, projected from keiki's `MatchedEdgeSummary` via
  `edgeIndex . matchedEdge`).
  Rationale: keiki's `ReplayFailure s co` and `MatchedEdgeSummary s` are parameterized
  over the transducer's vertex and event types, but `CommandError`
  (`keiro/src/Keiro/Command.hs:118-142`) is a plain monomorphic type that flows
  through `ProcessManager`, `Router`, `Projection`, generated `keiro-dsl` code, and
  test assertions. Parameterizing it, or rendering keiki's values to `Text` (which
  needs `Show s`/`Show co`), would change the load-bearing `runCommand*` signatures
  this plan must preserve. `StreamVersion` is keiro's durable per-event coordinate —
  strictly more useful to an operator than keiki's zero-based index, and computed from
  it — and `edgeIndex` is an `Int`, vertex-independent by construction. EP-99 owns any
  richer rendering (it can add `Show` where *it* needs it).
  Date: 2026-07-12

- Decision: the two hydration folds collapse into a single seeded function
  (`hydrateSeeded`) that pages the stored stream, decodes each page, and hands the
  decoded prefix to keiki EP-72's `replayEvents`; decode/replay error precedence is
  preserved by decoding each page only up to its first decode failure (see Milestone 2
  for the exact discipline). The end-of-stream `Settled` check (today's
  `finishReplay`) stays on the keiro side, per EP-72's design: `replayEvents`
  deliberately does *not* fail on a log that ends mid-chain, because a page boundary
  may fall mid-chain.
  Rationale: this is the deletion keiki EP-72 designed for ("keiro DELETES its
  hand-rolled folds rather than improving them" — master plan integration point 5):
  `hydrate` (`keiro/src/Keiro/Command.hs:221-306`) and `hydrateFull` (`:308-378`) are
  ~150 lines of near-identical per-event inversion bookkeeping whose only real keiro
  content is the snapshot-vs-initial seed, the per-event decode, and the
  version/global-position accounting. Alternative considered and rejected: calling the
  single-step `applyEventStreamingEither` per event inside the existing streamly fold
  — it preserves per-event decode interleaving trivially but re-implements exactly the
  index accounting `replayEvents` owns. If the shipped `replayEvents` signature
  differs from the specification quoted in Interfaces and Dependencies, keep a thin
  keiro adapter with the same seeded shape rather than reverting to duplicated folds,
  and record the divergence here.
  Date: 2026-07-12

- Decision: `commandErrorClass` maps the extended `HydrationReplayFailed` to four
  reason-specific classes (`hydration_replay_no_inverting_edge`,
  `hydration_replay_ambiguous_inversion`, `hydration_replay_queue_mismatch`,
  `hydration_replay_truncated_chain`), retiring the single `hydration_replay_failed`
  class; `CommandAmbiguous` gets the new class `command_ambiguous`.
  Rationale: master plan integration point 1 requires one new low-cardinality class
  per new constructor and forbids reusing an existing class for a new meaning. The
  reason *is* the diagnosis — a truncated chain and a foreign event are different
  operator questions — and the split stays statically bounded (ten classes total). The
  retirement of `hydration_replay_failed` is a dashboards-visible rename and goes in
  the changelog. Never reuse `command_rejected` for ambiguity.
  Date: 2026-07-12

- Decision: `AmbiguousEdges` from `stepEither` becomes the new non-transient
  `CommandAmbiguous`; `NoOutgoingEdges` and `NoMatchingEdge` keep mapping to
  `CommandRejected`. `isTransientCommandError` returns `False` for
  `CommandAmbiguous`, so process-manager and router workers `AckHalt` on it, and
  `keiro-dsl` generated timer dispositions route it through their existing `Left{}`
  (on-error) arm rather than the benign on-reject arm.
  Rationale: ambiguity is a deterministic single-valuedness violation — a bug in the
  aggregate definition — so retrying is useless (halt is right) and treating it as a
  benign business rejection (which dsl specs may map to "success") was actively
  wrong. This is a behavior-visible change for a state that was always a bug; it is
  called out in the changelog (Milestone 4).
  Date: 2026-07-12

- Decision: no keiro change for keiki EP-71's four new `ValidationOptions` fields.
  Rationale: verified during authoring (and independently by keiki EP-71's own
  Milestone 6 audit): no code in this repository constructs `ValidationOptions`
  literally. `keiro-core/src/Keiro/EventStream/Validate.hs` imports the type
  abstractly and threads `defaultValidationOptions` or a caller-supplied value
  (lines 37-38, 76, 104); `keiro-dsl`'s generated harnesses pass
  `defaultValidationOptions` (`keiro-dsl/src/Keiro/Dsl/Harness.hs:202,211`). Since the
  four new flags default to `True`, keiro's validation automatically becomes
  stricter, which is the point. (EP-99 later adds the force-enable normalizer for
  the replay-contract pair; that is deliberately its scope, not this migration's.)
  Date: 2026-07-12

- Decision: the in-repo `jitsurei` package is recompiled and its tests re-run but not
  otherwise modified; the external jitsurei example repositories are neither cited as
  evidence nor migrated.
  Rationale: user directive 2026-07-12 (master plan scope). The in-repo package is
  unavoidable — it is in `cabal.project`'s `packages` list and `just haskell-test`
  runs `jitsurei-test` — but it never matches `CommandError` exhaustively (verified:
  `jitsurei/test/Main.hs:104,379` assert `CommandRejected` for genuine guard
  rejections, which keep their meaning; `jitsurei/src/Jitsurei/*.hs` use the type
  opaquely), so compilation and tests should pass unmodified. If a jitsurei aggregate
  trips one of the new keiki validation checks at test time, that is a genuine latent
  replay bug: fix the fixture minimally to keep the suite green and record it in
  Surprises & Discoveries.
  Date: 2026-07-12


## Outcomes & Retrospective

EP-95 is complete. Keiro consumes Keiki 0.2 from Hackage, renders and rejects all four
new replay-safety warnings, and replaces its duplicated hydration folds with one
seedable `replayEvents` path. Corrupted-stream coverage now pins the failing stream
version and each typed `HydrationReplayReason`.

Command evaluation now uses `stepEither`: genuine no-edge/no-match outcomes remain
`CommandRejected`, while a validated runtime-overlap witness returns
`CommandAmbiguous [0,1]`, appends nothing, records `error.type=command_ambiguous`, and
halts process-manager/router delivery as a deterministic definition error. Existing
Jitsurei business-rejection assertions and generated DSL dispositions stayed green
without source changes.

The final default-Hackage matrix passed `cabal build all`, 309 Keiro examples, 50
PGMQ examples (2 expected pending), 16 Jitsurei examples, diagram freshness, and
formatting. A fresh-database `just verify` additionally passed process-compose
validation, the Jitsurei demo, a 122-page site link check, and 10 migration examples.
The Kiroku/pg-migrate Git pins and `cabal.project.local` are no longer needed.


## Context and Orientation

Nothing in this section assumes prior knowledge; every claim names its file and line as
of 2026-07-12.

### The two repositories

This plan edits the **keiro** repository (`/Users/shinzui/Keikaku/bokuno/keiro`; all
bare relative paths below are relative to it). keiro consumes **keiki** 0.2 from
Hackage: `keiro`, `keiro-core`, `keiro-dsl`, and `jitsurei` constrain `keiki` to
`>=0.2 && <0.3`, while `keiro` and `jitsurei` constrain `keiki-codec-json` to the
same range. `cabal.project` deliberately has no keiki source override. The sibling
repository `/Users/shinzui/Keikaku/bokuno/keiki`, located through `mori registry show
shinzui/keiki --full`, is the release-tagged source used to inspect APIs; release tag
`v0.2.0.0` and Hackage's package index both identify version 0.2.0.0. Keiro also
resolves `kiroku-store >=0.3 && <0.4`, `kiroku-store-migrations ^>=0.2.0.0`, and the
pg-migrate 1.0 package family from Hackage; `cabal.project` contains no source
overrides for those projects and the workspace needs no `cabal.project.local`.

### What a keiki transducer is, and what replay means

keiki models an aggregate as a *symbolic-register transducer*: a finite graph of
control vertices where each outgoing `Edge` carries a `guard` (a predicate over the
typed register file and the incoming command), an `update` (register writes), an
`output` (a list of zero or more event templates — zero is an "ε-edge", two-plus is a
"multi-event edge"), and a `target` vertex. Running a command forward is `step`; since
keiki EP-55/56 there is also `stepEither`
(`/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs:969-1009`), which returns
`Either (StepFailure s)` distinguishing `NoOutgoingEdges` (terminal vertex),
`NoMatchingEdge` (rejection, with one `RejectedEdgeSummary` per edge), and
`AmbiguousEdges` (two or more guards matched — carries one `MatchedEdgeSummary` per
match, each holding an `EdgeRef` whose `edgeIndex :: Int` is the edge's zero-based
position). Replay is the inverse direction: given a stored event, find the unique edge
whose *first* output template could have produced it, recover the command, re-run the
update, and — for multi-event edges — hold the remaining expected events in an
`InFlight` queue that subsequent stored events must match one-for-one. The wrapper
state for this is `Keiki.InFlight s co` (`Settled s` between chains, `InFlight s queue`
mid-chain).

Post-MP-16, keiki's replay surface is structured (keiki EP-72): `ReplayStepFailure`
explains one event's failure (`ReplayNoInvertingEdge`, `ReplayAmbiguousInversions`,
`ReplayQueueMismatch`), `ReplayFailure` wraps a reason with the zero-based failing
index and the wrapper state, and the seedable fold `replayEvents` starts from an
arbitrary `(InFlight s co, RegFile rs)` seed, applies a list of events with strict
index accounting, fails with `ReplayFailure` on the first bad event, and — crucially —
returns the final wrapper on the `Right` *without* failing when the list ends
mid-chain, so a page boundary can fall inside a multi-event chain. The strict facades
(`applyEventsEither`, `reconstituteEither`) convert a final `InFlight` into
`ReplayLogTruncated`; a streaming caller like keiro performs that check itself at true
end-of-stream. The old `Maybe` surface (`step`, `applyEventStreaming`, `applyEvents`)
survives unchanged as thin wrappers — keiro code that keeps using it still compiles.

Post-MP-16, keiki's validator (keiki EP-71) also gains four warning constructors on
`TransducerValidationWarning` — `HeadUnrecoverable` (a multi-event edge whose first
event cannot alone reconstruct the command: such an edge produces logs the transducer
*cannot replay*), `InversionAmbiguity` (two same-vertex edges whose first emitted
events share a wire constructor, so replay may not attribute an observed event to a
unique edge), `UnguardedInputRead` (an edge that reads a command field without a
guard establishing the command's constructor first, so evaluation crashes via `error`
instead of rejecting), and `StateChangingEpsilon` (an edge that emits no events but
changes the vertex or writes a register — a transition an event log cannot
reconstruct, so it silently un-happens at the next hydration) — and four matching
`ValidationOptions` flags, all default-on.

### keiro's command path, and the five defects this plan fixes

`keiro/src/Keiro/Command.hs` implements the pipeline hydrate → transduce → append:

- **Hydration folds (defect: duplicated, and failures are untyped).** `hydrate`
  (`keiro/src/Keiro/Command.hs:221-306`) seeds replay from a persisted snapshot when
  one exists (`hydrateWithSnapshot` returns a `SnapshotSeed` with `state`,
  `registers`, `streamVersion` — `keiro/src/Keiro/Snapshot.hs:43-48`) and falls back
  to `hydrateFull` (`:308-378`), which seeds from the transducer's initial state. The
  two folds are near-identical: each streams `RecordedEvent`s via
  `readStreamForwardStream` in pages of `pageSize` (default 256), decodes each with
  `decodeRecorded` (failure → `HydrationDecodeFailed`, lines 278 and 350), applies
  `Keiki.applyEventStreaming` (a bare `Nothing` → `HydrationReplayFailed
  (recorded ^. #streamVersion)`, lines 287 and 359), threads a `Replay` accumulator
  carrying the keiki wrapper, registers, the last *settled* version/global-position
  (`updateHydrated`, lines 296-306 and 368-378), and finally converts an
  end-of-stream `InFlight` wrapper into `HydrationReplayFailed
  (lastObservedStreamVersion …)` (`finishReplay`, lines 259-264 and 336-341).
  `HydrationReplayFailed` itself carries only a `StreamVersion`
  (`keiro/src/Keiro/Command.hs:121-124`) — the *why* is discarded.
- **Command evaluation (defect: ambiguity conflated with rejection).**
  `evaluateCommand` (`keiro/src/Keiro/Command.hs:650-659`) calls `Keiki.step` and maps
  `Nothing` to `CommandRejected` — but `step`'s `Nothing` covers both "no guard
  matched" (business rejection) and "several guards matched" (`AmbiguousEdges`, a
  determinism bug the validator's pure carrier provably cannot always catch; see
  Surprises & Discoveries).
- **Telemetry classifier.** `commandErrorClass` (`keiro/src/Keiro/Command.hs:570-578`)
  maps each `CommandError` constructor to a low-cardinality `error.type` span
  attribute value; today `HydrationReplayFailed{} -> "hydration_replay_failed"` and
  `CommandRejected -> "command_rejected"`.
- **Snapshot write (untouched here).** `writeSnapshotIfNeeded`
  (`keiro/src/Keiro/Command.hs:580-606`) folds `Keiki.applyEvents` over the
  just-appended events (line 593) and swallows failures. keiki MP-16 keeps
  `applyEvents` with its exact signature, so this compiles unchanged; the discarded
  divergence witness there is EP-99's job
  (`docs/plans/99-silent-edge-validation-and-divergence-witnesses-on-the-command-path.md`),
  not this plan's. Do not touch it beyond confirming compilation.

The only four keiki evaluator/replay call sites in the runtime packages are the ones
just named — verified by grep: `keiro/src/Keiro/Command.hs:282`, `:354` (the two
`applyEventStreaming` calls), `:593` (`applyEvents`), `:657` (`step`).

- **Warning rendering (defect: compile-breaking exhaustive match).** `renderWarning`
  in `keiro-core/src/Keiro/EventStream/Validate.hs:147-155` pattern-matches keiki's
  `TransducerValidationWarning` exhaustively over all four current constructors
  (`HiddenInput`, `NondeterministicPair`, `PossiblyDeadEdge`, `OpaqueGuard`). Against
  post-EP-71 keiki this stops compiling — which is this plan's forcing function.
  `mkEventStreamWith` (same file, lines 117-120) already fails a stream on *any*
  warning, so the new constructors are automatically fail-fast once rendered.

### Every CommandError pattern-match site (the audit for Milestone 3)

Enumerated by grep across all in-repo packages; re-run the grep during implementation
(`grep -rn "CommandError\|CommandRejected\|HydrationReplayFailed" --include="*.hs"
keiro keiro-core keiro-dsl jitsurei keiro-pgmq keiro-test-support`):

- `keiro/src/Keiro/ProcessManager.hs:206-214` — `isTransientCommandError`, an
  exhaustive lambda-case over all current constructors. Needs a new
  `CommandAmbiguous{} -> False` arm. The existing `HydrationReplayFailed{} -> False`
  arm uses record-wildcard syntax, so the constructor's new field does not break it.
- `keiro/src/Keiro/ProcessManager.hs:216-219` — `ackForCommandError` classifies via
  `isTransientCommandError` only; no direct constructor match; unchanged.
- `keiro/src/Keiro/ProcessManager.hs:448-454` and `keiro/src/Keiro/Router.hs:274-280`
  — `headDeterministic` filters via `isTransientCommandError` and constructs
  `CommandRejected` only as an unreachable empty-list fallback; unchanged.
- `keiro/src/Keiro/Router.hs:247` and `keiro/src/Keiro/ProcessManager.hs:407,414` —
  construct `StoreFailed` only; unchanged.
- `keiro/src/Keiro/Projection.hs:42,98` — imports and returns `CommandError` opaquely;
  no match sites; recompile only.
- `keiro-dsl/src/Keiro/Dsl/Scaffold.hs:709-713` — the generated `…FireOutcome`
  function matches `Right{}`, `Left CommandRejected`, then a wildcard `Left{}`. The
  wildcard keeps generated code (and the checked-in conformance copies under
  `keiro-dsl/test/conformance-*/Generated/…/Process.hs`) compiling; a
  `CommandAmbiguous` now routes to the on-error disposition instead of the benign
  on-reject one, which is the correct posture (Decision Log). No scaffold change
  required; note the semantics in the changelog.
- `jitsurei/test/Main.hs:104,379` — assert `Right (Left CommandRejected)` for
  commands rejected by guards (states with no matching edge). Under `stepEither`
  these are `NoMatchingEdge`/`NoOutgoingEdges`, still mapped to `CommandRejected`;
  assertions hold unmodified.
- `keiro/test/Main.hs:709` (`RetryExhausted`), `:813` (`ConflictFixpoint`), `:840`
  (`HydrationDecodeFailed`), `:1904` (`ackForCommandError … CommandRejected`
  halts), plus the `rejectingEventStream` worker tests (the fixture at `:8636-8651`
  has a vertex with **no outgoing edges**, i.e. `NoOutgoingEdges` → still
  `CommandRejected`; the comment at `:8632-8635` stays accurate). None of these
  assertions change meaning; Milestone 3 *adds* sibling assertions for ambiguity.

Notably absent from that list: any test that asserts `HydrationReplayFailed` at
runtime. The 2026-07 review found the constructor never appears in an assertion;
Milestone 2 closes that gap.

### Build, test, and formatting — how a novice runs this repository

Everything runs from the repo root `/Users/shinzui/Keikaku/bokuno/keiro` inside the
Nix dev shell, which provides GHC 9.12.4, cabal, just, and PostgreSQL 18 binaries
(`nix/haskell.nix:35,59`):

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop
cabal build all
cabal test keiro-test        # the suite this plan mainly touches
just haskell-test            # keiro-test + keiro-pgmq-test + jitsurei-test + diagram check
nix fmt -- --no-cache        # canonical fourmolu formatting; run before every commit
```

The `keiro-test` suite needs **no manually provisioned database**: its `main`
(`keiro/test/Main.hs:316-317`) wraps everything in
`Keiro.Test.Postgres.withMigratedSuite`
(`keiro-test-support/src/Keiro/Test/Postgres.hs:71-99`), which starts one cached
ephemeral PostgreSQL server, creates a template database, applies the kiroku and keiro
migrations to it once, and clones a fresh database per example via
`CREATE DATABASE … TEMPLATE …` (`withFreshStore`, same file). The `postgres`/`initdb`
binaries come from the dev shell. (The `just postgres-start`/`process-compose` recipes
in the `Justfile` serve the long-running jitsurei demos, not the test suite.)

Commit per milestone with Conventional Commits, each including the trailer
`ExecPlan: docs/plans/95-migrate-to-post-mp-16-keiki-and-adopt-the-structured-replay-and-step-apis.md`.


## Plan of Work

Four milestones. M1 restores compilation against post-MP-16 keiki and lands the
warning-rendering migration (nothing else can even build before it). M2 replaces the
hydration folds and introduces the typed hydration taxonomy. M3 adopts `stepEither`
and introduces `CommandAmbiguous`. M4 is the sweep, changelog, and master-plan
bookkeeping. Each milestone leaves `cabal build all` and `cabal test keiro-test`
green.

### Milestone 1 — bump keiki and migrate the warning match

Scope: after this milestone, the workspace compiles against post-MP-16 keiki, and
`mkEventStream` rejects (with readable reasons) every transducer shape the four new
keiki checks flag. This is the compile-breaking part of the migration, so it is one
commit.

First, re-verify the specification (see the caveat at the top): open the released keiki
checkout and confirm the names and shapes quoted in Interfaces and Dependencies —
the four new warning constructors and their fields (`tvwEdge`, `tvwSource`,
`tvwChangesVertex`, `tvwWritesRegisters`, `tvwDetail`), the four
`ValidationOptions` flags, `ReplayStepFailure`/
`ReplayFailure`/`replayEvents`, and `stepEither`/`StepFailure` (the last pair exists
today and cannot drift). Check keiki's `CHANGELOG.md` and the two keiki plans'
Decision Logs for recorded deviations. Record any drift in Surprises & Discoveries and
adapt the affected edits below before making them.

Switch to the Hackage release: remove both keiki `source-repository-package` stanzas
from `cabal.project`, and require `keiki >=0.2 && <0.3` plus
`keiki-codec-json >=0.2 && <0.3` in every component that directly depends on them.
Run `cabal update` if the local package index predates the 0.2.0.0 upload. The
committed state must resolve the ordinary Hackage packages without a local or Git
keiki override.

Then `cabal build all` and let the compiler drive: the only expected keiro breakage is
the exhaustive match in `renderWarning`
(`keiro-core/src/Keiro/EventStream/Validate.hs:147-155`). Add the four arms exactly as
keiki EP-71's migration section prescribes (matching the existing kebab-case-tag
rendering style), and change the haddock sentence above the function from "All four
constructors carry @tvwDetail@" to "All eight constructors carry @tvwDetail@":

```haskell
    HeadUnrecoverable{tvwEdge = e, tvwDetail = d} ->
        "head-unrecoverable @" <> showT (edgeSource e) <> ": " <> Text.pack d
    InversionAmbiguity{tvwSource = s, tvwDetail = d} ->
        "inversion-ambiguity @" <> showT s <> ": " <> Text.pack d
    UnguardedInputRead{tvwEdge = e, tvwDetail = d} ->
        "unguarded-input-read @" <> showT (edgeSource e) <> ": " <> Text.pack d
    StateChangingEpsilon{tvwEdge = e, tvwDetail = d} ->
        "state-changing-epsilon @" <> showT (edgeSource e) <> ": " <> Text.pack d
```

Update the module haddock (`keiro-core/src/Keiro/EventStream/Validate.hs:1-18`), which
currently describes the umbrella as "hidden-input + determinism + dead-edge": name the
four new checks and state the posture plainly — a stream flagged by any of them fails
`mkEventStream` at startup because keiro's persistence model makes an unreplayable
shape unacceptable, and per-stream narrowing goes through `mkEventStreamWith` with a
record update on `defaultValidationOptions` (EP-99 subsequently restricts narrowing
to the non-contract checks). State explicitly (it is this plan's required record):
keiro constructs `ValidationOptions` nowhere — it only threads
`defaultValidationOptions` or a caller's value — so keiki's four new default-on flags
required no keiro change and simply made `mkEventStream` stricter.

Tests, in `keiro/test/Main.hs`. The existing replay-safety block at lines 536-566 is
the audit gate: the "every production-intent stream validates clean" spec (lines
537-549) now runs the four new checks over every fixture. If any fixture fails, that
fixture has a latent replay bug — fix the fixture (never the assertion), following
keiki EP-71's Milestone 5 classification, and record it in Surprises & Discoveries.
(Expected: all pass. Every fixture's guards are `matchInCtor`-conjoined, the
multi-event fixtures' head events carry the single command slot — e.g.
`multiCounterTransducer` at `keiro/test/Main.hs:7624-7639` — and no vertex has two
edges sharing a head wire constructor.) Then add four rejection specs alongside the
existing `brokenHiddenInputEventStream` spec (lines 551-560), one per new check, each
asserting `mkEventStream` returns `Left` and the rendered reason contains the new
kebab-case prefix:

- *head-unrecoverable*: a variant of `counterTransducer` whose single edge emits two
  events where the **first** carries a literal (keiki's `TLit`, via the `lit`
  builder if exported — check keiki's export list; the `SplitCoverage` fixture in
  keiki's own test suite is the template) and the **second** carries
  `inpCtor addCtor #amount`. Head coverage misses `amount`, union covers it →
  `HeadUnrecoverable`, rendered `head-unrecoverable @Counting: …`.
- *inversion-ambiguity*: two edges out of `Counting`, both guarded
  `PAnd (matchInCtor addCtor) (PNot PBot)` (the `PNot` keeps the runtime-true guard
  outside keiki 0.2's strengthened pure overlap fragment — see Surprises &
  Discoveries), both emitting `CounterAdded` as their head event. Rendered
  `inversion-ambiguity @Counting: …`. Keep this transducer as a named top-level
  fixture — Milestone 2's ambiguous-inversion hydration test reuses it.
- *unguarded-input-read*: one edge guarded `PTop` whose output reads
  `inpCtor addCtor #amount`. Rendered `unguarded-input-read @Counting: …`.
- *state-changing-epsilon*: a variant of `counterTransducer` whose single edge has
  `output = []` and targets a second vertex (add a two-constructor state type, or
  keep the self-loop and give the update a `USet` with a `lit 0` right-hand side —
  the literal avoids also tripping keiki's ε-reads-input check). Rendered
  `state-changing-epsilon @Counting: …`. Keep it top-level — EP-99's Milestone 1
  reuses the shape for its force-enable specs.

Acceptance for M1: `cabal build all` succeeds against Hackage keiki 0.2; `cabal test
keiro-test` is green including the four new rejection specs; the fixture-audit spec
still returns `[]`.

### Milestone 2 — one seeded hydration fold over keiki's structured replay

Scope: after this milestone, `keiro/src/Keiro/Command.hs` contains a single seeded
hydration fold instead of two duplicated ones, `HydrationReplayFailed` carries a typed
reason, and — for the first time — tests assert hydration replay failures at runtime
against deliberately corrupted streams.

Types first. In `keiro/src/Keiro/Command.hs`, next to `CommandError`, add:

```haskell
-- | Why replay of the stored events stalled, projected from keiki's
-- 'Keiki.ReplayStepFailure' / final-wrapper check onto a monomorphic
-- vocabulary (CommandError carries no vertex/event type parameters).
data HydrationReplayReason
    = -- | No edge's first output template could have produced the stored
      -- event (foreign or out-of-place event).
      HydrationNoInvertingEdge
    | -- | Two or more edges could have produced it (replay-side
      -- single-valuedness violation).
      HydrationAmbiguousInversion
    | -- | Mid multi-event chain, the stored event did not match the next
      -- expected event of the chain.
      HydrationQueueMismatch
    | -- | The stream ended in the middle of a multi-event chain.
      HydrationTruncatedChain
    deriving stock (Generic, Eq, Show)
```

and extend the existing constructor (`keiro/src/Keiro/Command.hs:121-124`) to
`HydrationReplayFailed !StreamVersion !HydrationReplayReason`, updating its haddock:
the `StreamVersion` is the failing stored event's version (for
`HydrationTruncatedChain`, the version of the last stored event, after which the chain
was left pending). Export `HydrationReplayReason (..)` from the module's export list
(it is part of `CommandError`'s public shape; EP-99 and EP-100 consume it). Check
whether the root `Keiro` module re-exports `Keiro.Command` types and mirror the export
there if so.

Update `commandErrorClass` (`keiro/src/Keiro/Command.hs:570-578`) per the Decision
Log:

```haskell
    HydrationReplayFailed _ HydrationNoInvertingEdge -> "hydration_replay_no_inverting_edge"
    HydrationReplayFailed _ HydrationAmbiguousInversion -> "hydration_replay_ambiguous_inversion"
    HydrationReplayFailed _ HydrationQueueMismatch -> "hydration_replay_queue_mismatch"
    HydrationReplayFailed _ HydrationTruncatedChain -> "hydration_replay_truncated_chain"
```

Now the fold. Delete the bodies of `hydrate` and `hydrateFull` (lines 221-378) in
favor of one seeded worker; keep the two names as thin entry points because their
callers (`runCommand`/`runCommandWithSqlEvents` call `hydrate`; `hydrate` falls back
to `hydrateFull` on a failed snapshot-seeded replay, preserving the existing
semantics at lines 228-235):

```haskell
hydrate options eventStream targetStream =
    snapshotSeed >>= \case
        Nothing -> hydrateFull options eventStream targetStream
        Just seed -> do
            replayed <-
                hydrateSeeded options eventStream targetStream
                    (seed ^. #state) (seed ^. #registers) (seed ^. #streamVersion)
            case replayed of
                Left _ -> hydrateFull options eventStream targetStream
                Right hydrated -> pure (Right hydrated)

hydrateFull options eventStream targetStream =
    hydrateSeeded options eventStream targetStream
        (eventStream ^. #initialState) (eventStream ^. #initialRegisters) (StreamVersion 0)
```

`hydrateSeeded` streams `RecordedEvent`s exactly as today
(`readStreamForwardStream name cursor pageSize`), but groups them into pages (streamly:
`Streamly.foldMany (Fold.take pageSize' Fold.toList)` over the recorded stream, where
`pageSize'` is `options ^. #pageSize` as an `Int`) and folds pages with an accumulator
of `(Keiki.InFlight s co, RegFile rs, lastRecorded :: Maybe RecordedEvent)`, seeded
with `(Keiki.Settled seedState, seedRegisters, Nothing)`. Per page:

1. **Decode a prefix.** Walk the page in order, decoding each `RecordedEvent` with
   `decodeRecorded (eventStream ^. #eventCodec)` (exactly as today, lines 277 and
   349), stopping at the first decode failure. This yields the decoded prefix (paired
   with its `RecordedEvent`s) and `Maybe CodecError`. Stopping at the first failure is
   what preserves today's error precedence: a replay failure *earlier* in the page
   must win over a decode failure *later* in it, and a decode failure must win over
   anything after it (today's fold short-circuits per event; see `applyRecorded` at
   lines 275-279).
2. **Replay the prefix.** Call keiki's seedable fold:
   `Keiki.replayEvents (eventStream ^. #transducer) (wrapper, regs) decodedPrefix`.
   On `Left replayFailure`, index the page's recorded list with
   `Keiki.replayFailedIndex replayFailure` to get the failing `RecordedEvent`, and
   return `Left (HydrationReplayFailed (failingRecorded ^. #streamVersion) reason)`
   where `reason` projects `Keiki.replayFailureReason`:
   `ReplayEventFailed (ReplayNoInvertingEdge …) -> HydrationNoInvertingEdge`,
   `ReplayEventFailed (ReplayAmbiguousInversions …) -> HydrationAmbiguousInversion`,
   `ReplayEventFailed (ReplayQueueMismatch …) -> HydrationQueueMismatch`. (A
   `ReplayLogTruncated` cannot arise from `replayEvents` — only the strict keiki
   facades produce it — but write the arm total anyway, mapping it to
   `HydrationTruncatedChain`, so the projection is future-proof.) Indexing the
   in-memory page list is deliberate: it makes no arithmetic assumption about version
   contiguity.
3. **Surface the pending decode failure.** If replay of the prefix succeeded but step
   1 stopped early, return `Left (HydrationDecodeFailed err)` — the decode failure was
   the earliest problem in the page.
4. **Advance.** Otherwise carry `(wrapper', regs', Just (last of page))` into the next
   page.

At end of stream (this is today's `finishReplay`, kept on the keiro side because
`replayEvents` deliberately does not fail mid-chain — Decision Log):

- final wrapper `Keiki.Settled finalState` → `Right Hydrated{ state = finalState,
  registers = finalRegs, streamVersion = maybe seedVersion (^. #streamVersion)
  lastRecorded, globalPosition = fmap (^. #globalPosition) lastRecorded }`. This
  reproduces today's success bookkeeping: on success the last stored event always
  yields a `Settled` wrapper, so today's "version/position at the last settled event"
  (`updateHydrated`, lines 296-306) equals "version/position of the last event";
  and an empty stream reproduces today's seed-shaped result (`initialHydrated`,
  lines 321-327, and the snapshot seed at lines 246-256, both with
  `globalPosition = Nothing`).
- final wrapper `Keiki.InFlight{}` → `Left (HydrationReplayFailed (maybe seedVersion
  (^. #streamVersion) lastRecorded) HydrationTruncatedChain)` — today's lines 259-264
  and 336-341, now with the typed reason.

Constraints already in scope suffice (`hydrate` has `BoolAlg phi (RegFile rs, ci)` and
`Eq co`, `keiro/src/Keiro/Command.hs:223`, matching `replayEvents`' constraint row).
The `Replay` record and both old `applyRecorded`/`applyEvent`/`updateHydrated`/
`finishReplay` copies are deleted outright. Net effect: about 150 lines of duplicated
inversion bookkeeping become one page fold whose only jobs are decode, seed, version
accounting, and reason projection — the division of labor keiki EP-72 designed.

Tests, in `keiro/test/Main.hs`, in the command describe-block near the existing decode
test. The template is the "surfaces decode failure during hydration" spec at lines
819-840: append raw events to a stream with `Store.appendToStream`, then run a command
and assert on the hydration error. Add four specs (verify the concrete `StreamVersion`
values once against the store — kiroku numbers stream events from 1):

- *no-inverting-edge*: append `encodeForAppend counterCodec (CounterAudited 7)` (the
  codec encodes it, but `counterTransducer`'s only edge emits `CounterAdded` heads —
  `keiro/test/Main.hs:7583-7598`) to a fresh stream; `runCommand … counterEventStream
  … (Add 1)` must return
  `Right (Left (HydrationReplayFailed (StreamVersion 1) HydrationNoInvertingEdge))`.
- *queue-mismatch*: append `CounterAdded 5` then `CounterAudited 6` to a fresh
  stream; run against `multiCounterEventStream` (its one edge emits
  `[CounterAdded amount, CounterAudited amount]`, so replay of event 1 leaves an
  `InFlight` queue expecting `CounterAudited 5`); expect
  `HydrationReplayFailed (StreamVersion 2) HydrationQueueMismatch`.
- *truncated-chain*: append only `CounterAdded 5`; run against
  `multiCounterEventStream`; expect
  `HydrationReplayFailed (StreamVersion 1) HydrationTruncatedChain`.
- *ambiguous-inversion*: build a validated stream from Milestone 1's
  same-head-constructor two-edge transducer using `mkEventStreamWith
  defaultValidationOptions{checkInversionAmbiguity = False} …` (this also exercises
  the record-update construction pattern keiki EP-71 documents); append
  `CounterAdded 3`; expect
  `HydrationReplayFailed (StreamVersion 1) HydrationAmbiguousInversion`.

These are the first runtime assertions on `HydrationReplayFailed` in the suite (the
review found none), and they pin both the reason and the failing version.

Acceptance for M2: `cabal test keiro-test` green, including all pre-existing command,
snapshot, and process-manager tests (the fold replacement must be observationally
identical on every success path — those suites are the regression evidence) and the
four new corrupted-stream specs.

### Milestone 3 — `stepEither` and `CommandAmbiguous`

Scope: after this milestone, runtime guard ambiguity is a first-class, non-transient
`CommandError` with its own telemetry class, and business rejection keeps its exact
current meaning.

In `keiro/src/Keiro/Command.hs`, add the constructor to `CommandError`
(`:118-142`):

```haskell
    | {- | Two or more transitions matched the command in the hydrated state —
      a runtime single-valuedness violation ('Keiki.AmbiguousEdges'). Always a
      bug in the aggregate definition, never a business outcome; carries the
      zero-based indices of the matched edges (in match order) at the vertex
      the aggregate occupied. Deterministic: retrying cannot succeed.
      -}
      CommandAmbiguous ![Int]
```

Rewrite `evaluateCommand` (`:650-659`) over the already-shipping `stepEither`
(`/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs:969-1009`):

```haskell
evaluateCommand eventStream current command =
    case Keiki.stepEither (eventStream ^. #transducer) (state current, registers current) command of
        Left Keiki.NoOutgoingEdges{} -> Left CommandRejected
        Left Keiki.NoMatchingEdge{} -> Left CommandRejected
        Left (Keiki.AmbiguousEdges _ matches) ->
            Left (CommandAmbiguous [Keiki.edgeIndex (Keiki.matchedEdge m) | m <- matches])
        Right (_, _, events) -> Right events
```

`NoOutgoingEdges`/`NoMatchingEdge` → `CommandRejected` preserves today's rejection
semantics exactly (on the `Right`, `stepEither` returns the identical triple `step`
returns). Only the ambiguous case — previously a `Nothing` indistinguishable from
rejection — changes destination. Update `commandErrorClass` with
`CommandAmbiguous{} -> "command_ambiguous"` (a new class; `command_rejected` is not
reused — master plan integration point 1), the module haddock's pipeline description
(`keiro/src/Keiro/Command.hs:1-30`, whose step 2 currently says only "A rejected
transition yields 'CommandRejected'"), and `CommandRejected`'s own haddock to note
that ambiguity is no longer folded into it.

In `keiro/src/Keiro/ProcessManager.hs`, add the classification arm to the exhaustive
`isTransientCommandError` (`:206-214`): `CommandAmbiguous{} -> False`. That single arm
propagates everywhere it must: `ackForCommandError` (`:216-219`) then answers
`AckHalt` for it, the worker halt branches at `keiro/src/Keiro/ProcessManager.hs:430`
and `keiro/src/Keiro/Router.hs:261` treat it as deterministic, and
`headDeterministic` surfaces it preferentially. No other production edit is required
(the site audit in Context and Orientation is the checklist — walk it).

Tests, in `keiro/test/Main.hs`:

- *End-to-end ambiguity*: a top-level `ambiguousCounterTransducer` — two edges out of
  `Counting`, guards `PAnd (matchInCtor addCtor) (PNot PBot)` (see Surprises & Discoveries
  for why this passes the pure determinism check), edge 0 emitting a `CounterAdded`
  head and edge 1 a `CounterAudited` head (distinct head wire constructors, so keiki's
  new `InversionAmbiguity` check stays quiet and `mkEventStreamOrThrow
  "counter-ambiguous"` succeeds — this fixture is *validated yet ambiguous*, the exact
  gap the taxonomy exists for). Then `runCommand defaultRunCommandOptions
  ambiguousCounterEventStream target (Add 1)` must return
  `Right (Left (CommandAmbiguous [0, 1]))`, and nothing may have been appended (read
  the stream back or run a second command asserting version 0 behavior). Also add the
  fixture to the validate-clean audit list at `keiro/test/Main.hs:537-549` — it is a
  production-intent shape precisely because the validator accepts it.
- *Worker classification*: alongside the existing spec at `keiro/test/Main.hs:1901-1906`,
  assert `ackForCommandError (RetryDelay 5) (CommandAmbiguous [0, 1])` yields
  `AckHalt (HaltFatal _)`.
- *Audit, not assumption*: re-run the grep from Context and Orientation and confirm no
  other test asserted `CommandRejected` for a state that is ambiguity-reachable (the
  authoring-time audit found none: every `CommandRejected` assertion sits on
  no-edge/no-match fixtures).

Acceptance for M3: `cabal test keiro-test` green including the two new specs; the
existing rejection-path specs (`:1904`, the `rejectingEventStream` worker specs,
`jitsurei/test/Main.hs:104,379`) pass **unmodified**, proving rejection semantics did
not move.

### Milestone 4 — sweep, changelog, and master-plan bookkeeping

Scope: prove the whole workspace holds, write the migration story down, and close the
loop with the master plan.

Run the full matrix from the repo root inside `nix develop`: `cabal build all` (this
compiles `keiro-dsl`, `jitsurei`, `keiro-pgmq`, `keiro-migrations` against the new
keiki and the new `CommandError` — per the audit they need no source edits, but
verify, do not assume), then `just haskell-test`, then `nix fmt -- --no-cache`
(canonical fourmolu; a missing run causes silent style drift — project memory), then
`just verify` if time permits (adds process-compose config check and the website
build; not keiki-related but the repo's definition of done).

Add a `CHANGELOG.md` entry under `## [Unreleased]` following the existing
Keep-a-Changelog structure (see the current file for the format):

```text
### Breaking Changes

- keiro now requires post-MP-16 keiki. Stream validation runs keiki's four new
  replay-alignment checks (head-recoverability, inversion ambiguity, unguarded
  input reads, state-changing silent edges); a stream flagged by any of them now
  fails mkEventStream at startup instead of failing hydration (or silently losing
  state) in production.
- CommandError: HydrationReplayFailed now carries a typed HydrationReplayReason
  (no-inverting-edge / ambiguous-inversion / queue-mismatch / truncated-chain)
  alongside the failing stream version; new constructor CommandAmbiguous carries
  the matched edge indices.
- Behavior-visible: a command that matches two or more transitions (runtime
  guard ambiguity, a single-valuedness violation) is now reported as
  CommandAmbiguous instead of CommandRejected. This state was always a bug in
  the aggregate definition, previously misreported as a business rejection;
  process managers and routers halt on it, and keiro-dsl timer dispositions
  route it to their on-error arm rather than the benign on-reject arm.
- Telemetry: the error.type class hydration_replay_failed is replaced by four
  reason-specific classes; command_ambiguous is new. Dashboards keying on
  hydration_replay_failed must be updated.
```

Finally, update the master plan
(`docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`):
tick the three EP-95 progress boxes, flip the registry row to Complete, and note in
its Surprises & Discoveries anything this plan's implementation surfaced (especially
any keiki specification drift, which EP-98/EP-99/EP-102 consume). Write this plan's
Outcomes & Retrospective.

Acceptance for M4: all commands above green; changelog present; registry updated.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro` inside `nix develop`.

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop

# M1 — after editing the cabal.project keiki tags and Validate.hs:
cabal build all
cabal test keiro-test

# M2/M3 — iterate on the command suite while editing Command.hs and Main.hs.
# hspec filters by description substring; pick the describe/it text you added:
cabal test keiro-test --test-options='--match "hydration"'
cabal test keiro-test --test-options='--match "ambiguous"'

# M4 — full sweep:
cabal build all
just haskell-test
nix fmt -- --no-cache
```

Expected shape of the interesting transcript slices (counts will differ; the point is
the new specs listed and zero failures):

```text
  surfaces a typed no-inverting-edge hydration failure [✔]
  surfaces a typed queue-mismatch hydration failure with the failing version [✔]
  surfaces a truncated multi-event chain as HydrationTruncatedChain [✔]
  surfaces ambiguous inversion during hydration [✔]
  reports CommandAmbiguous with the matched edge indexes [✔]
  classifies CommandAmbiguous as a deterministic halt [✔]
```

Commit per milestone (Conventional Commits, plan trailer on every commit), e.g.:

```text
feat(keiro-core)!: render keiki EP-71's replay-alignment warnings (EP-95 M1)

Bump keiki to post-MP-16; head-unrecoverable / inversion-ambiguity /
unguarded-input-read streams now fail mkEventStream at startup.

BREAKING CHANGE: streams flagged by the new keiki checks no longer construct.

ExecPlan: docs/plans/95-migrate-to-post-mp-16-keiki-and-adopt-the-structured-replay-and-step-apis.md
```

```text
feat(keiro)!: typed hydration failures via keiki's seedable replay fold (EP-95 M2)

ExecPlan: docs/plans/95-migrate-to-post-mp-16-keiki-and-adopt-the-structured-replay-and-step-apis.md
```

```text
feat(keiro)!: distinguish CommandAmbiguous from CommandRejected via stepEither (EP-95 M3)

ExecPlan: docs/plans/95-migrate-to-post-mp-16-keiki-and-adopt-the-structured-replay-and-step-apis.md
```


## Validation and Acceptance

Acceptance is behavior, verified in this order with no knowledge beyond this document:

1. **Startup rejection of replay-breaking shapes.** In `cabal test keiro-test`, the
   three Milestone 1 specs show `mkEventStream` returning `Left` with reasons whose
   text contains `head-unrecoverable`, `inversion-ambiguity`, and
   `unguarded-input-read` respectively — where pre-migration keiro would have
   constructed those streams and (for the first shape) failed to hydrate its own
   appended events later. The fixture-audit spec proves every production-intent
   fixture still validates clean under the stricter checks.
2. **Typed hydration failures against corrupted streams.** The four Milestone 2 specs
   append raw events with `Store.appendToStream` and assert exact values, e.g.
   `Right (Left (HydrationReplayFailed (StreamVersion 2) HydrationQueueMismatch))`
   for a `[CounterAdded 5, CounterAudited 6]` stream hydrated by the multi-event
   counter aggregate. Before this plan the same scenarios produced
   `HydrationReplayFailed <version>` with no reason — and, per the 2026-07 review, no
   test exercised even that.
3. **Ambiguity is not rejection.** The Milestone 3 end-to-end spec drives a
   *validated* aggregate (accepted by `mkEventStreamOrThrow`) into runtime ambiguity
   and observes `Right (Left (CommandAmbiguous [0, 1]))` with nothing appended;
   `ackForCommandError` answers `AckHalt` for it. Every pre-existing
   `CommandRejected` assertion in `keiro/test/Main.hs` and `jitsurei/test/Main.hs`
   passes unmodified, demonstrating rejection semantics were preserved.
4. **Telemetry classes.** `commandErrorClass` (unit-testable directly if a spec seems
   warranted; at minimum inspect the code) yields the four
   `hydration_replay_*` classes and `command_ambiguous`, and no constructor shares a
   class with another.
5. **No semantic drift elsewhere.** `just haskell-test` is fully green:
   `keiro-pgmq-test` and `jitsurei-test` pass without source changes, and the
   `keiro-dsl` conformance trees still compile, proving the `CommandError` extension
   stayed within the wildcard arms of generated code. `nix fmt -- --no-cache`
   produces no diff on the final tree.


## Idempotence and Recovery

Every step is an ordinary source edit plus a build/test run, safe to repeat; re-running
`cabal build`, `cabal test`, and `nix fmt -- --no-cache` is idempotent, and the test
suite provisions and drops its own ephemeral databases per run (nothing persists
between runs). The keiki dependency change is trivially reversible by restoring
`cabal.project` and the package bounds, which rolls the whole workspace back to the pre-migration world —
that is the recovery path if the shipped keiki API diverges so far from the
specification that Milestone 1's re-verification fails: stop, record the divergence in
Surprises & Discoveries and in the master plan, and coordinate with the keiki plans'
Decision Logs rather than improvising signatures. Within the migration, milestones are
committed separately and each leaves the suite green, so `git revert` of the latest
milestone commit is always a safe fallback. The one ordering hazard: Milestone 1's
`renderWarning` arms and the Hackage dependency change must land in the same commit (the workspace does
not compile with one but not the other). No database migrations, no persisted-data
changes, and no destructive operations are involved anywhere in this plan.


## Interfaces and Dependencies

No new package names: keiro already depends on keiki, streamly, and hspec. This plan
raises the direct keiki and keiki-codec-json bounds from 0.1 to `>=0.2 && <0.3` and
removes their Git source overrides so Cabal resolves release 0.2.0.0 from Hackage.
The implementation-time dependency cleanup also raises direct `kiroku-store` bounds
to `>=0.3 && <0.4`, leaves `kiroku-store-migrations` on the compatible 0.2 line and
pg-migrate on 1.0, and removes their superseded Git overrides and local package file.
GHC 9.12.4 comes from `nix develop`.

The keiki surface this plan consumes is shipped by `Keiki.Core` in Hackage release
0.2.0.0 and was re-verified against release tag `v0.2.0.0` during Milestone 1:

```haskell
-- Shipped today (src/Keiki/Core.hs:923-1009): adopted in Milestone 3.
data EdgeRef s = EdgeRef { edgeSource :: s, edgeIndex :: Int }
data MatchedEdgeSummary s = MatchedEdgeSummary { matchedEdge :: EdgeRef s, matchedTarget :: s }
data StepFailure s
  = NoOutgoingEdges s
  | NoMatchingEdge s [RejectedEdgeSummary s]
  | AmbiguousEdges s [MatchedEdgeSummary s]
stepEither ::
  (BoolAlg phi (RegFile rs, ci)) =>
  SymTransducer phi rs s ci co -> (s, RegFile rs) -> ci ->
  Either (StepFailure s) (s, RegFile rs, [co])

-- Specified by keiki EP-72: consumed in Milestone 2.
data ReplayStepFailure s co
  = ReplayNoInvertingEdge s [RejectedEdgeSummary s]
  | ReplayAmbiguousInversions s [MatchedEdgeSummary s]
  | ReplayQueueMismatch s co [co]
data ReplayFailureReason s co
  = ReplayEventFailed (ReplayStepFailure s co)
  | ReplayLogTruncated [co]
data ReplayFailure s co = ReplayFailure
  { replayFailedIndex :: Int
  , replayFailedState :: InFlight s co
  , replayFailureReason :: ReplayFailureReason s co
  }
replayEvents ::
  (BoolAlg phi (RegFile rs, ci), Eq co) =>
  SymTransducer phi rs s ci co ->
  (InFlight s co, RegFile rs) -> [co] ->
  Either (ReplayFailure s co) (InFlight s co, RegFile rs)

-- Specified by keiki EP-71: consumed in Milestone 1.
-- TransducerValidationWarning gains HeadUnrecoverable{tvwEdge, tvwInCtor,
-- tvwTailOnlySlots, tvwDetail}, InversionAmbiguity{tvwSource, tvwEdgeA,
-- tvwEdgeB, tvwWireCtor, tvwDetail}, UnguardedInputRead{tvwEdge, tvwInCtor,
-- tvwDetail}, StateChangingEpsilon{tvwEdge, tvwChangesVertex,
-- tvwWritesRegisters, tvwDetail}; ValidationOptions gains
-- checkHeadRecoverability, checkInversionAmbiguity,
-- checkGuardImpliesInputRead, checkStateChangingEpsilon (all default True).
```

Unchanged keiki surfaces this plan relies on keiki MP-16 preserving (its EP-72
Decision Log commits to this): `step`, `applyEventStreaming`, `applyEvents`,
`InFlight` — which keeps `writeSnapshotIfNeeded` (`keiro/src/Keiro/Command.hs:593`,
untouched here, revisited by EP-99) and all non-migrated call sites compiling.

The keiro surface that must exist at the end (module `Keiro.Command`,
`keiro/src/Keiro/Command.hs`):

```haskell
data HydrationReplayReason
    = HydrationNoInvertingEdge
    | HydrationAmbiguousInversion
    | HydrationQueueMismatch
    | HydrationTruncatedChain
    deriving stock (Generic, Eq, Show)

data CommandError
    = HydrationDecodeFailed !CodecError
    | HydrationReplayFailed !StreamVersion !HydrationReplayReason   -- extended
    | CommandRejected
    | CommandAmbiguous ![Int]                                       -- new
    | EncodeFailed !CodecError
    | StoreFailed !StoreError
    | RetryExhausted !Int !StoreError
    | ConflictFixpoint !StreamVersion !StoreError
    deriving stock (Generic, Eq, Show)
```

`runCommand`, `runCommandWithSql`, and `runCommandWithSqlEvents` keep their exact
signatures and constraint rows (`keiro/src/Keiro/Command.hs:384-391, 434-442,
454-462`); the only observable interface change is `CommandError`'s shape above and
the refined `commandErrorClass` values. Downstream within the master plan: EP-99
consumes `HydrationReplayReason` and the ambiguity/rejection split; EP-100 serializes
these constructors into dead-letter records; EP-102's truncation guard reports through
`HydrationTruncatedChain`. The `Keiro.EventStream.Validate` warning vocabulary edited
in Milestone 1 is shared ground with EP-99 (integration point 2): EP-99 force-enables
keiki's `StateChangingEpsilon` and `HeadUnrecoverable` checks at the durable boundary
and rebases on this plan's render arms; it does not add a duplicate silent-edge scan.

---

Revision note (2026-07-13): completed EP-95. Adopted structured replay and step
failures, added typed hydration and ambiguity outcomes with end-to-end coverage,
updated the changelog, repaired the optional Jitsurei verification recipe for the
native pg-migrate CLI, and closed the MasterPlan registry/progress entries.

Revision note (2026-07-13): followed the user's dependency-cleanup directive after
pg-migrate and the latest Kiroku packages reached Hackage. Removed the Kiroku and
pg-migrate Git source stanzas plus `cabal.project.local`, tightened direct Kiroku
bounds, and verified the default `cabal build all` and 308-example `keiro-test` path.

Revision note (2026-07-13): unblocked implementation after keiki MP-16 completed and
keiki 0.2.0.0 reached Hackage. Replaced the authored Git-pin migration with ordinary
Hackage package resolution and PVP 0.2 bounds, recorded the shipped API verification,
and associated EP-95 with its MasterPlan's existing Intention.

Revision note (2026-07-12, later): aligned with keiki MP-16's revised EP-71 scope —
the warning migration is four constructors, not three (`StateChangingEpsilon`
joins), so the render arms, haddock count ("All eight constructors"), rejection
specs, changelog text, and quoted keiki interfaces were updated, and a fourth
rejection-spec fixture added. The fail-fast Decision now also records that EP-99
force-enables the replay-contract pair, leaving only the non-contract checks
caller-narrowable.

Revision note (2026-07-12): replaced the generated skeleton with the full plan.
Authored from a fresh read of keiro's `Command.hs`, `EventStream/Validate.hs`,
`ProcessManager.hs`, `Router.hs`, `Projection.hs`, `Snapshot.hs`, `test/Main.hs`
(fixtures, validation block, decode-failure template, ack-classification specs),
`keiro-dsl`'s scaffold and conformance trees, the in-repo `jitsurei` call sites,
`cabal.project`/`cabal.project.local`/`Justfile`/`nix/haskell.nix`/
`keiro-test-support/src/Keiro/Test/Postgres.hs` for the build/test story, and the
keiki side: `src/Keiki/Core.hs` (shipped `stepEither`, validator internals including
`provablyOverlap`) plus the EP-71/EP-72 specification documents in the keiki
repository. All file:line citations were verified against the working trees on this
date.
