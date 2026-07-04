---
id: 84
slug: enforce-replay-safety-with-a-validatedeventstream-at-the-keiro-command-boundary
title: "Enforce replay-safety with a ValidatedEventStream at the keiro command boundary"
kind: exec-plan
created_at: 2026-07-03T23:11:24Z
intention: "intention_01kwn3yey2er3szetce6b552dd"
---

# Enforce replay-safety with a ValidatedEventStream at the keiro command boundary

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro runs **event-sourced aggregates**: a persistent stream of events is
replayed through a pure state machine (a keiki *transducer*) to reconstruct the
aggregate's current state before each new command is applied. An aggregate is
**replay-safe** only if every piece of the command it consumed can be recovered
from the events it emitted. When a transition changes internal state but emits
no event that carries the information it read — a so-called **hidden input** —
the state cannot be rebuilt on replay, and the aggregate silently diverges: it
returns one answer today and a different answer after a restart or a snapshot
rebuild. This is among the most damaging bugs an event-sourcing framework can
allow, because it is invisible until the log is replayed, often in production,
often long after the offending code shipped.

keiki can already *detect* this. Its `validateTransducer` runs a pure, solver-free
structural analysis that flags hidden inputs (plus nondeterministic guards and
statically-dead edges). keiro already *wraps* that analysis at the stream
boundary: `keiro-core/src/Keiro/EventStream/Validate.hs` exposes
`validateEventStream` (returns warnings) and `mkEventStream` (a fail-fast smart
constructor returning `Left warnings` or `Right stream`). **The problem is that
nothing forces anyone to use them.** Every `EventStream` in the codebase — every
test fixture, and every stream the keiro-dsl code generator emits — is built with
the bare `EventStream { … }` record literal, which skips the check entirely.
`mkEventStream` is dead code: it is referenced nowhere outside its own module and
tests. So a developer can hand-author a replay-breaking aggregate, wire it into
`runCommand`, and ship it, and no build step, test, or runtime guard will object.

After this change, **an unvalidated `EventStream` cannot be run at all — it will
not type-check.** We introduce a `ValidatedEventStream` newtype that only
`mkEventStream` can produce, make the command runners (`runCommand`,
`runCommandWithSql`, `runCommandWithSqlEvents`, and the Router / ProcessManager /
Projection layers built on them) accept *only* a `ValidatedEventStream`, and
update the keiro-dsl code generator to emit validated streams. The replay-safety
check thus moves from "available if you remember" to "unavoidable at the command
boundary." Illegal (unchecked) streams become unrepresentable at the call site.

You can see the new behavior working two ways. First, a *positive* demonstration:
after the change, a program that tries to pass a bare `EventStream` record to
`runCommand` fails to compile with a type error naming `ValidatedEventStream`;
routing it through `mkEventStream` and pattern-matching the `Right` makes it
compile. Second, a *runtime* demonstration of the guard's substance: feeding a
known replay-unsafe stream (the existing `brokenHiddenInputEventStream` fixture)
to `mkEventStream` returns `Left` with a `hidden-input @…` warning, so it can
never be wrapped into the `ValidatedEventStream` the runners demand.

This plan is the keiro-side companion to keiki ExecPlan
`../../../keiki/docs/plans/68-require-explicit-emit-noemit-intent-on-every-builder-edge.md`
(in the sibling `keiki` repository), which forces a developer to *state* emit or
noEmit intent on every edge. That plan closes *silence-by-omission*; it does
**not** close replay-unsafety, because a developer can satisfy it by writing
`noEmit` on an edge that reads the command input — exactly the hidden-input case
this plan rejects. The two are complementary: keiki 68 is authoring ergonomics;
this plan is the replay-safety guarantee. See the Decision Log for the coordination
constraint between the two repositories.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 — Introduce the `ValidatedEventStream` newtype in keiro-core.** Completed 2026-07-04.
  - [x] Add `newtype ValidatedEventStream phi rs s ci co` wrapping `EventStream`, with an `unvalidated` accessor, in `keiro-core/src/Keiro/EventStream/Validate.hs`.
  - [x] Change `mkEventStream` to return `Either [EventStreamWarning] (ValidatedEventStream …)`.
  - [x] Add `mkEventStreamWith :: ValidationOptions -> …` for the narrowed-options escape hatch.
  - [x] Add `mkEventStreamOrThrow :: HasCallStack => … -> ValidatedEventStream …` (partial; for generated/fixture code with a sibling proof).
  - [x] Export the new names from `Keiro.EventStream.Validate` and re-export from `Keiro` (`keiro/src/Keiro.hs`).
  - [x] `cabal build keiro-core` succeeds.
  - [x] `cabal build all` succeeds after M1.
- [x] **M2 — Thread `ValidatedEventStream` through the command runners.** Completed 2026-07-04.
  - [x] Change the three public runners in `keiro/src/Keiro/Command.hs` to accept `ValidatedEventStream`, unwrapping once at the top with `unvalidated`.
  - [x] Keep internal helpers (`hydrate`, `hydrateFull`, `planCommand`, append helpers) on the bare `EventStream`.
  - [x] Change the Router config field `targetEventStream` and ProcessManager config fields `eventStream` / `targetEventStream` to `ValidatedEventStream`.
  - [x] Change the Projection runner signature to `ValidatedEventStream`.
  - [x] Migrate every in-repo construction site (test fixtures) to build via `mkEventStreamOrThrow`, keeping the *validated* value under the original name so runner call sites are untouched.
  - [x] `cabal test keiro-test` is green.
- [x] **M3 — Prove the guarantee with tests.** Completed 2026-07-04.
  - [x] Positive: `mkEventStream` accepts every production-intent fixture (extends the existing clean-validation test).
  - [x] Negative: `mkEventStream brokenHiddenInputEventStream` returns `Left` with a hidden-input warning (extends the existing test).
  - [x] Add the out-of-build-graph compile probe `keiro/test/ReplaySafetyTypeProbe.hs`, a small self-contained module that passes a bare `EventStream` to `runCommand`.
  - [x] Add the GHC boot-package `process` to `keiro-test` `build-depends` for `readProcessWithExitCode`.
  - [x] Add an hspec example in `keiro/test/Main.hs` that shells out to `cabal exec ghc -- -fno-code -package keiro test/ReplaySafetyTypeProbe.hs` and asserts a non-zero exit plus `ValidatedEventStream` in stderr.
  - [x] Do **not** add `ReplaySafetyTypeProbe` to `other-modules`; it must stay outside the normal build graph or `keiro-test` will fail to compile by design.
  - [x] `cabal test keiro-test` green.
- [x] **M4 — Update the keiro-dsl code generator and conformance goldens.** Completed 2026-07-04.
  - [x] Change `emitEventStream` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` to emit a `ValidatedEventStream` binding (via `mkEventStreamOrThrow`) alongside the bare record.
  - [x] Update generated process-manager wiring by keeping the public `fooEventStream` binding name as the validated value; generated callers that pass it to `ProcessManager` fields continue to compile unchanged.
  - [x] Regenerate the checked-in EventStream conformance fixtures under the aggregate-bearing `keiro-dsl/test/conformance*/Generated/**` trees.
  - [x] `cabal test keiro-dsl-test` is green.
  - [x] `cabal test keiro-dsl-conformance keiro-dsl-conformance-v2 keiro-dsl-conformance-coldstart keiro-dsl-conformance-process keiro-dsl-conformance-process-runtime keiro-dsl-conformance-process-full` is green.
- [x] **M5 — Documentation and changelog.** Completed 2026-07-04.
  - [x] Update the `Keiro.EventStream.Validate` module haddock and the `EventStream` haddock note about `mkEventStream`.
  - [x] Add a `### Changed` entry to `keiro/CHANGELOG.md` (the package changelog; there is no root changelog file).
  - [x] Record the keiki-plan-68 coordination constraint (version bump ordering) in the Decision Log and changelog.
  - [x] Cross-reference the consumer migration guide `docs/guides/migrating-to-validated-event-stream.md` from the changelog entry; confirm it matches the final API and names the registered downstream projects from `mori registry dependents shinzui/keiro --packages`.
- [x] **M6 — Migrate the in-workspace `jitsurei` worked examples.** Completed 2026-07-04.
  - [x] Rename each bare worked-example stream record to `...EventStreamDef` and keep the public `...EventStream` binding as a `ValidatedEventStream` built with `mkEventStreamOrThrow`.
  - [x] Keep existing raw `...EventStream` type aliases for `Stream` handles and `ProcessManagerResult` phantom tags; add internal `Validated...EventStream` aliases for value signatures.
  - [x] Add missing `Ord` derivations to the worked-example state enums required by validation.
  - [x] `cabal build all` is green.
  - [x] `cabal test jitsurei-test` and `cabal run jitsurei:exe:jitsurei-diagrams -- --check` are green.
  - [x] `cabal test keiro-test keiro-pgmq-test` is green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Discovery (research, 2026-07-03): `mkEventStream` is dead code.** A repo-wide
  search for `mkEventStream` outside its defining module and the test suite
  returns nothing; every real and test `EventStream` is a bare record literal.
  Evidence:

  ```text
  $ grep -rn "mkEventStream" --include="*.hs" . | grep -v "/test/\|Validate.hs"
  keiro-core/src/Keiro/EventStream.hs:47:  … 'Keiro.EventStream.Validate.mkEventStream' rejects
  (only a doc comment; no call site)
  ```

- **Discovery (research, 2026-07-03): the keiro-dsl generator emits a bare
  record too.** `emitEventStream` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:1062`)
  produces `fooEventStream = EventStream { … }`. The DSL path is currently
  replay-safe *only* because the separately-generated harness asserts
  `validateTransducer defaultValidationOptions … == []`; the generated stream
  *value* itself is unvalidated. So the DSL must be updated (M4) or its generated
  streams will not type-check against the M2 runners.

- **Discovery (research, 2026-07-03): the `Stream`/`CommandResult` phantom tag can
  stay `EventStream`, shrinking the blast radius.** The runners tag the target
  handle as `Stream (EventStream phi rs s ci co)` and the result as
  `CommandResult (EventStream phi rs s ci co)`. Only the *value* argument needs to
  become `ValidatedEventStream`; the phantom type tags can remain the bare
  `EventStream …`, so `Stream` handles (`stream "x" :: Stream CounterEventStream`)
  and `CommandResult` types are untouched. See Decision Log.

- **Discovery (research, 2026-07-03): keiro-core has no test suite of its own.**
  `keiro-core/keiro-core.cabal` declares no `test-suite`; the `EventStream.Validate`
  tests live in `keiro/test/Main.hs` (`describe "mkEventStream"`,
  `describe "EventStream replay-safety (validateEventStream)"`). New unit coverage
  (M3) is added there.

- **Discovery (review, 2026-07-03): the originally proposed
  `should-not-typecheck` module could not import the fixtures it named.**
  `keiro/test/Main.hs` declares `module Main (main) where`, so helper modules in
  the same test suite cannot import `counterEventStreamDef`, commands, or stream
  handles from it. The `should-not-typecheck` package also exposes only
  `shouldNotTypecheck`; it does not expose a message-inspecting assertion, and it
  requires an `NFData` instance for the expression under test. Evidence:

  ```text
  $ sed -n '1,4p' keiro/test/Main.hs
  module Main (
      main,
  )

  $ sed -n '1,60p' /tmp/should-not-typecheck-2.1.0/src/Test/ShouldNotTypecheck.hs
  module Test.ShouldNotTypecheck (shouldNotTypecheck) where
  shouldNotTypecheck :: NFData a => (() ~ () => a) -> Assertion
  ```

- **Discovery (review, 2026-07-03): the registered downstream migration surface
  is broad but source-compatible at the storage layer.** `mori registry dependents
  shinzui/keiro --packages` lists `danwa`, `kanmon`, `kawa`,
  `keiro-runtime-docs`, `keiro-runtime-jitsurei`, `keiro-runtime-patterns`,
  `kikan`, `kioku`, `kizashi`, `kotei`, `mori-app`, and `shikigami`.
  `mori-app` also has a package-level dependency. Because `ValidatedEventStream`
  is a `newtype`, those projects need source migrations but no event-store,
  snapshot, or wire-format migration.

- **Discovery (implementation, 2026-07-04): the compile probe needs `-package
  keiro`, but not explicit transitive package flags.** Running `cabal exec ghc --
  -fno-code test/ReplaySafetyTypeProbe.hs` from the test executable left `Keiro`
  hidden, while adding all imported packages with `-package` duplicated package
  entries in Cabal's generated environment. The stable invocation is:

  ```text
  cabal exec ghc -- -fno-code -package keiro test/ReplaySafetyTypeProbe.hs
  ```

  It fails for the intended reason: GHC reports that the actual bare
  `EventStream ...` does not match the expected `ValidatedEventStream ...`.

- **Discovery (implementation, 2026-07-04): the DSL generated stream alias needs
  a raw companion alias.** Generated modules now expose `FooEventStreamDef` for
  the bare `EventStream …` record and `FooEventStream` for the
  `ValidatedEventStream …` value. This preserves a name for stream phantom tags or
  low-level validation tests while keeping the original `fooEventStream` binding
  suitable for command-boundary APIs. A repo search showed the current generated
  process wiring imports and passes the value binding, not `Stream FooEventStream`,
  and the conformance suites confirmed the split compiles.

- **Discovery (implementation, 2026-07-04): checked-in DSL fixtures are
  formatter-normalized while `scaffold` writes raw text.** Regenerating the
  conformance directories rewrote unrelated generated Codec/Harness/Domain files
  with raw formatting. Those formatter-only changes were restored; the committed
  M4 diff is intentionally limited to `emitEventStream` and generated
  `EventStream.hs` files.

- **Discovery (implementation, 2026-07-04): the changelog is package-local.**
  The repository has no root `CHANGELOG.md`; the release note for this API change
  belongs in `keiro/CHANGELOG.md`.

- **Discovery (implementation, 2026-07-04): the full workspace gate required
  migrating `jitsurei`.** Although external downstream repositories remain
  follow-up work, `jitsurei` is in this Cabal workspace and `just haskell-build`
  runs `cabal build all`. The validated runner API therefore required migrating
  its worked-example streams in this plan. The migration also surfaced missing
  `Ord` derivations on several state enums.


## Decision Log

Record every decision made while working on the plan.

- Decision: Enforce replay-safety with a **compile-time `ValidatedEventStream`
  newtype**, not a runtime check inside the runners.
  Rationale: The user chose the newtype approach over runtime fail-fast. It makes
  an unchecked stream *unrepresentable* at the runner call site (a type error,
  caught at build time) rather than a runtime rejection, and it concentrates the
  `(Bounded s, Enum s, Ord s, Show s)` constraints `validateTransducer` needs at
  the single construction point (`mkEventStream`) instead of threading them
  through every runner. The cost — accepted deliberately — is a larger API blast
  radius: every runner signature and every stream-construction site changes.
  Date: 2026-07-03

- Decision: Enforce the **full `defaultValidationOptions`** (hidden-input +
  determinism + dead-edge), not hidden-input alone.
  Rationale: The user chose all default checks. `validateEventStream` already
  uses `defaultValidationOptions`, so no options change is required — the work is
  purely plumbing. The known risk is that default validation can block streams for
  reasons beyond hidden-input: the determinism check can surface real overlapping
  guards that existing code tolerated, and the dead-edge check is conservative
  enough to produce known-benign reachability warnings. The escape hatch is
  `mkEventStreamWith`, which lets a caller narrow non-hidden-input options for a
  stream with a documented benign warning. Note this is consistent with the DSL
  harness, which already asserts `validateTransducer defaultValidationOptions … ==
  []`, so any warning from the default checks would already be failing the harness
  today.
  Date: 2026-07-03

- Decision: Keep the phantom type tag of `Stream` and `CommandResult` as the bare
  `EventStream …`; wrap only the value argument.
  Rationale: Minimizes churn — `Stream` handles and `CommandResult` result types
  across the codebase and tests do not change; only the value passed as the first
  argument to the runners becomes `ValidatedEventStream`. See Surprises.
  Date: 2026-07-03

- Decision: Migrate in-repo construction sites by giving the **validated** value
  the original binding name and renaming the bare record to `…Def`.
  Rationale: There are dozens of `runCommand … counterEventStream …` call sites in
  the tests. If `counterEventStream` keeps its name but becomes the validated
  value (built by `mkEventStreamOrThrow "counter" counterEventStreamDef`), those
  call sites are untouched; only the definition changes. The validation tests that
  need the bare record refer to `counterEventStreamDef`.
  Date: 2026-07-03

- Decision: Provide `mkEventStreamOrThrow` (a partial, `error`-on-`Left`
  constructor) for generated and fixture code.
  Rationale: Generated DSL code and test fixtures need a *value*, not an `Either`,
  at the top level, and each has a sibling proof that the stream is safe (the DSL
  harness test; the M3 clean-validation test). `mkEventStreamOrThrow` makes the
  `error` branch statically dead under that proof, while still failing loudly if a
  spec edit later introduces a hidden input. Hand-authored application code should
  prefer the total `mkEventStream` and handle `Left` explicitly.
  Date: 2026-07-03

- Decision: Coordinate the keiki-plan-68 version bump with this change.
  Rationale: keiro pins keiki. keiki plan 68 is a behavioral (`!`) tightening of
  the builder. This plan does not *depend* on 68 (it enforces replay-safety
  independently, at the stream boundary), but both touch the same authoring story.
  Land order: this plan can land against the current keiki; when keiki 68 ships,
  bump keiro's keiki pin in a separate commit. Neither plan should force a
  same-PR cross-repo change.
  Date: 2026-07-03

- Decision: Make M3's type-level guard an **external compile probe**, not a
  `should-not-typecheck` deferred-error test.
  Rationale: A commented "uncomment to see the error" check rots — nothing runs it,
  so a future regression that loosens a runner back to a bare `EventStream` would
  pass CI silently. The first automated design used `should-not-typecheck`, but
  review found two concrete problems: the proposed module could not import
  `counterEventStreamDef` from `Main` because `keiro/test/Main.hs` exports only
  `main`, and `should-not-typecheck` 2.1.0 exports only `shouldNotTypecheck`
  without message inspection while requiring `NFData` for the expression under
  test. The compile probe is a tiny self-contained Haskell file outside the test
  suite's `other-modules`; an hspec example runs `cabal exec ghc -- -fno-code` on
  that file and asserts both non-zero exit and `ValidatedEventStream` in stderr.
  Cost/risks accepted: the test starts GHC once and the probe file is not checked
  by the normal build graph, so the guard is live only when `keiro-test` runs.
  Benefit: no new third-party test dependency, no deferred type errors under
  `-Werror`, no fixture extraction from `Main`, and an exact diagnostic assertion.
  Date: 2026-07-03

- Decision: Keep downstream consumer migrations out of this keiro ExecPlan.
  Rationale: This plan must land the keiro API, update keiro-dsl generation, and
  publish the migration guide first. The registered dependents (`danwa`, `kanmon`,
  `kawa`, `keiro-runtime-docs`, `keiro-runtime-jitsurei`,
  `keiro-runtime-patterns`, `kikan`, `kioku`, `kizashi`, `kotei`, `mori-app`, and
  `shikigami`) should migrate in follow-up repo-specific changes after they bump
  to the keiro/keiro-dsl revisions produced here. This avoids a cross-repo
  same-PR coupling and lets real replay-safety failures be fixed one project at a
  time.
  Date: 2026-07-03

- Decision: In generated DSL modules, keep `FooEventStream` as the validated
  public binding/type and introduce `FooEventStreamDef` for the bare record.
  Rationale: This mirrors the in-repo fixture migration from M2: existing runner
  wiring keeps passing `fooEventStream`, now validated, while code that needs the
  raw event-stream shape can opt into `fooEventStreamDef` / `FooEventStreamDef`.
  It also avoids changing `Stream`/`CommandResult` phantom tags to the validated
  wrapper.
  Date: 2026-07-04


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)

- M4 completed 2026-07-04. `keiro-dsl` now emits `...EventStreamDef` as the bare
  record and `...EventStream` as a `ValidatedEventStream` built with
  `mkEventStreamOrThrow`. The generated process-manager conformance fixture
  compiles against the validated `ProcessManager` fields without changing its
  hand-owned manager code.

- M5 completed 2026-07-04. Public haddocks describe the validated command
  boundary, `keiro/CHANGELOG.md` records the breaking source migration and
  keiki-plan-68 coordination, and the downstream migration guide names the
  current `mori` dependents and final DSL alias split.

- M6 completed 2026-07-04. The in-workspace `jitsurei` examples now use
  validated stream values while preserving raw stream aliases for handles and
  result phantom types. The full Haskell gate passed: `cabal build all`,
  `cabal test keiro-test keiro-pgmq-test`, `cabal test jitsurei-test`, and
  `cabal run jitsurei:exe:jitsurei-diagrams -- --check`.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before editing.

**What this project is.** keiro is a Haskell event-sourcing framework. The
repository is a multi-package Cabal project; the packages that matter here are
`keiro-core` (`keiro-core/keiro-core.cabal`, sources under `keiro-core/src/`),
`keiro` (`keiro/keiro.cabal`, sources under `keiro/src/`, tests in
`keiro/test/Main.hs`), and `keiro-dsl` (`keiro-dsl/`, a code generator with
checked-in conformance fixtures under `keiro-dsl/test/`). It depends on a sibling
library, **keiki** (registered separately; sources at
`/Users/shinzui/Keikaku/bokuno/keiki`), which provides the pure state machines.

**Key term — transducer.** A keiki `SymTransducer` is a pure state machine: it
reads a command, updates an internal *register file* (`RegFile rs`, a typed record
of mutable slots), emits zero or more events, and moves between control states.
keiro persists the emitted events and, to handle the next command, *replays* them
through the transducer to rebuild the current `(state, registers)`.

**Key term — replay-safe / hidden input.** A transducer is *replay-safe* when
every command field an edge reads is recoverable from the events that edge emits.
A **hidden input** is the violation: an edge whose register update reads the
command input but whose output does not carry that information onto the wire (the
extreme case is an *ε-edge* — an edge that emits no event at all but still writes
registers from the command). On replay there is no event to carry the lost
information, so the rebuilt state diverges from the live state. keiki's
`validateTransducer` (in the keiki package, module `Keiki.Core`) detects this
structurally, with no SMT solver, and returns a list of warnings; an empty list
means safe. Its `defaultValidationOptions` enables three checks: hidden-input
(`failOnEpsilonReadsInput`), guard determinism (`checkDeterminism`), and dead-edge
reachability (`checkReachability`).

**The file that owns validation at the keiro boundary:**
`keiro-core/src/Keiro/EventStream/Validate.hs`. Today it exports:

- `EventStreamWarning` — a stream-labelled warning record.
- `validateEventStream label es` / `validateEventStreamWith opts label es` — run
  the pure check over a stream's transducer; return `[EventStreamWarning]` (empty
  when safe). Also flags an incoherent snapshot policy (a `snapshotPolicy` set with
  `stateCodec = Nothing`).
- `mkEventStream label es` — the fail-fast smart constructor. **Today** it returns
  `Either [EventStreamWarning] (EventStream …)` — `Left` warnings for an unsafe
  stream, `Right es` for a safe one. This is the function that is currently dead
  and that this plan makes load-bearing.

**The type being guarded:** `EventStream phi rs s ci co`, defined in
`keiro-core/src/Keiro/EventStream.hs`. It is a record marrying the `transducer`
with the durable plumbing (`initialState`, `initialRegisters`, `eventCodec`,
`resolveStreamName`, `snapshotPolicy`, `stateCodec`). It derives `Generic`, and
keiro code reads its fields with `OverloadedRecordDot`/optic labels, e.g.
`eventStream ^. #transducer`.

**The command boundary — the choke point:** `keiro/src/Keiro/Command.hs`. Every
command flows through one of three public runners:

- `runCommand` (line ~383) — hydrate, transduce, append.
- `runCommandWithSql` (line ~430) — same, plus an `afterAppend` action in the same
  transaction.
- `runCommandWithSqlEvents` (line ~453) — same, callback also gets the emitted
  events.

All three take `EventStream phi rs s ci co` and a `Stream (EventStream phi rs s ci
co)` target handle, and internally call the private `hydrate` (line ~220), which
replays stored events through `eventStream ^. #transducer`. `hydrate`,
`hydrateFull`, `planCommand`, and the append helpers are module-private and take
the bare `EventStream`.

**The higher-level runners that embed an `EventStream`:**

- `keiro/src/Keiro/Router.hs` — the `Router` config record has a field
  `targetEventStream :: EventStream targetPhi …` (line ~92); it calls a runner
  with it (line ~163).
- `keiro/src/Keiro/ProcessManager.hs` — the config record has `eventStream ::
  EventStream …` (line ~103) and `targetEventStream :: EventStream …` (line ~105).
- `keiro/src/Keiro/Projection.hs` — a runner takes `EventStream …` (line ~93).

**The construction sites to migrate (all in `keiro/test/Main.hs`):** fixtures like
`counterEventStream :: CounterEventStream` (line ~7473) are bare record literals:

```haskell
counterEventStream :: CounterEventStream
counterEventStream =
    EventStream
        { transducer = counterTransducer
        , initialState = Counting
        , initialRegisters = RNil
        , eventCodec = counterCodec
        , resolveStreamName = Stream.streamName
        , snapshotPolicy = Never
        , stateCodec = Nothing
        }
```

These feed both the runners (which will demand `ValidatedEventStream`) and the
validation tests (which need the bare record). The Router/ProcessManager config
fixtures (`keiro/test/Main.hs` lines ~1775, ~2131, ~7746, ~7787, ~7838) set
`targetEventStream = counterEventStream` etc.

**The code generator to update:** `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, function
`emitEventStream` (line ~1062), which renders the `.EventStream` module for each
aggregate as a bare `EventStream { … }` record. Its output is checked in under
`keiro-dsl/test/conformance*/Generated/**/EventStream.hs` and must be regenerated.

**Build and test toolchain.** From the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`: `cabal build all` builds everything; the
`justfile` records the test targets — `cabal test keiro-test`, `cabal test
keiro-pgmq-test`, `cabal test jitsurei-test`, plus the keiro-dsl conformance
suites (run via `cabal test` on their targets; enumerate with
`cabal run 2>/dev/null; cabal test --enable-tests all` or inspect the `.cabal`
files). There is no custom runner beyond Cabal.


## Plan of Work

The work is one additive type in keiro-core, a signature change rippling through
the runners and their construction sites, a code-generator update with golden
regeneration, and documentation — split into five independently verifiable
milestones. The type-level change is small; most of the diff is mechanical
propagation and fixture migration.

### Milestone M1 — Introduce the `ValidatedEventStream` newtype in keiro-core

Scope: add the newtype and the constructors that produce it, without yet changing
any runner. At the end keiro-core compiles and exposes the new API; nothing
consumes it yet.

Edits in `keiro-core/src/Keiro/EventStream/Validate.hs`:

1. **Add the newtype and accessor.** A newtype wrapping `EventStream`, whose data
   constructor is *not* exported (only `mkEventStream` / `mkEventStreamWith` /
   `mkEventStreamOrThrow` may construct it), plus an exported `unvalidated`
   projection the runners use internally:

   ```haskell
   -- | An 'EventStream' that has passed 'validateTransducer' (replay-safety,
   -- determinism, dead-edge). Only 'mkEventStream' and friends can build one,
   -- so a value of this type is a proof the stream is sound. Runners accept
   -- only this type; the bare 'EventStream' record cannot reach a runner.
   newtype ValidatedEventStream phi rs s ci co
       = ValidatedEventStream (EventStream phi rs s ci co)

   -- | Recover the underlying stream. Used by the runners to read fields;
   -- does not re-expose a way to *construct* a validated stream.
   unvalidated :: ValidatedEventStream phi rs s ci co -> EventStream phi rs s ci co
   unvalidated (ValidatedEventStream es) = es
   ```

2. **Change `mkEventStream` to return the newtype.** Only the `Right` arm changes:

   ```haskell
   mkEventStream ::
       (Bounded s, Enum s, Ord s, Show s) =>
       Text ->
       EventStream (HsPred rs ci) rs s ci co ->
       Either [EventStreamWarning] (ValidatedEventStream (HsPred rs ci) rs s ci co)
   mkEventStream = mkEventStreamWith defaultValidationOptions
   ```

3. **Add `mkEventStreamWith`** (the narrowed-options escape hatch for a stream
   with a known-benign determinism/dead-edge warning). This is for narrowing
   non-hidden-input checks only; do not use it to disable
   `failOnEpsilonReadsInput`, because that is the replay-safety guarantee this
   plan exists to enforce:

   ```haskell
   mkEventStreamWith ::
       (Bounded s, Enum s, Ord s, Show s) =>
       ValidationOptions ->
       Text ->
       EventStream (HsPred rs ci) rs s ci co ->
       Either [EventStreamWarning] (ValidatedEventStream (HsPred rs ci) rs s ci co)
   mkEventStreamWith opts label es =
       case validateEventStreamWith opts label es of
           [] -> Right (ValidatedEventStream es)
           warns -> Left warns
   ```

4. **Add `mkEventStreamOrThrow`** (partial constructor for generated / fixture
   code that has a sibling proof of safety):

   ```haskell
   mkEventStreamOrThrow ::
       (HasCallStack, Bounded s, Enum s, Ord s, Show s) =>
       Text ->
       EventStream (HsPred rs ci) rs s ci co ->
       ValidatedEventStream (HsPred rs ci) rs s ci co
   mkEventStreamOrThrow label es =
       case mkEventStream label es of
           Right v -> v
           Left warns ->
               error $
                   "Keiro.EventStream.Validate.mkEventStreamOrThrow: "
                       <> Text.unpack label
                       <> " is not replay-safe: "
                       <> show warns
   ```

5. **Update the export list** of `Keiro.EventStream.Validate` to add
   `ValidatedEventStream` (the *type*, not the constructor), `unvalidated`,
   `mkEventStreamWith`, and `mkEventStreamOrThrow`.

6. **Re-export from the umbrella module** `keiro/src/Keiro.hs` so application code
   and the DSL import the new names from `Keiro` as they already do for
   `EventStream`.

Acceptance for M1: `cabal build keiro-core` succeeds; `cabal build all` still
succeeds (nothing consumes the newtype yet). The existing `mkEventStream` tests in
`keiro/test/Main.hs` still compile because they pattern-match `Right _` / `Left ws`
and never inspect the `Right` payload's structure — verify by building the test
target (it need not pass yet if other milestones are mid-flight, but M1 alone
should not break it).

### Milestone M2 — Thread `ValidatedEventStream` through the command runners

Scope: make the runners and the higher-level config records demand
`ValidatedEventStream`, unwrap once at the boundary, and migrate every in-repo
construction site. At the end, an unchecked `EventStream` cannot reach a runner,
and `cabal test keiro-test` is green.

Edits:

1. **`keiro/src/Keiro/Command.hs` — the three public runners.** For `runCommand`,
   `runCommandWithSql`, and `runCommandWithSqlEvents`, change the first value
   argument's type from `EventStream phi rs s ci co` to `ValidatedEventStream phi
   rs s ci co`. Leave the `Stream (EventStream phi rs s ci co)` target parameter
   and the `CommandResult (EventStream phi rs s ci co)` result type **unchanged**
   (the phantom tag stays the bare type — see Decision Log). At the top of each
   runner body, unwrap once:

   ```haskell
   runCommand options ves target command =
       let eventStream = unvalidated ves
        in …  -- rest of the body is unchanged; it already binds `eventStream`
   ```

   The private helpers `hydrate`, `hydrateFull`, `planCommand`, and the append
   helpers keep taking the bare `EventStream` and are called with `eventStream`
   (the unwrapped value). No constraint changes are needed on the runners: the
   `(Bounded s, Enum s, Ord s, Show s)` constraints live on `mkEventStream`, at
   construction time, not here.

2. **`keiro/src/Keiro/Router.hs`.** Change the config field to
   `targetEventStream :: !(ValidatedEventStream targetPhi targetRs targetState
   targetCi targetCo)`. Where the router reads it to call the runner (line ~163),
   pass it straight through (the runner now expects the validated type). If the
   router also needs `resolveStreamName` off the stream (line ~155), read it via
   `unvalidated (router ^. #targetEventStream) ^. #resolveStreamName`.

3. **`keiro/src/Keiro/ProcessManager.hs`.** Change both config fields
   `eventStream` and `targetEventStream` to `ValidatedEventStream …`. Update any
   internal use that reads stream fields to go through `unvalidated`. The
   `streamFor :: Text -> Stream (EventStream …)` field is a `Stream` handle, not an
   `EventStream` value, so it is **unchanged**.

4. **`keiro/src/Keiro/Projection.hs`.** Change the runner's `EventStream …`
   parameter (line ~93) to `ValidatedEventStream …`; unwrap at the boundary as in
   step 1.

5. **Migrate the fixtures in `keiro/test/Main.hs`.** For each stream fixture
   (`counterEventStream`, `snapshotCounterEventStream`, `noOpCounterEventStream`,
   `pmSnapshotCounterEventStream`, `rejectingEventStream`, and any others the build
   flags), rename the bare record to `…Def` and bind the original name to the
   validated value. Extend the existing `Keiro.EventStream.Validate` import to
   include `ValidatedEventStream`, `mkEventStreamOrThrow`, and later
   `mkEventStreamWith` only if a test fixture needs narrowed validation options:

   ```haskell
   counterEventStreamDef :: CounterEventStream
   counterEventStreamDef =
       EventStream { … }  -- the former body, unchanged

   counterEventStream :: ValidatedEventStream (HsPred CounterRegs CounterCommand) CounterRegs CounterState CounterCommand CounterEvent
   counterEventStream = mkEventStreamOrThrow "counter" counterEventStreamDef
   ```

   Derived bare fixtures must update the bare `…Def` value, not the validated
   binding. For example, `noOpCounterEventStreamDef =
   counterEventStreamDef & #transducer .~ noOpCounterTransducer`, and
   `rejectingEventStreamDef = counterEventStreamDef & #transducer .~
   rejectingTransducer`. Then expose `noOpCounterEventStream` and
   `rejectingEventStream` as validated values with the original names.

   Every `runCommand … counterEventStream …` and every
   `targetEventStream = counterEventStream` / `eventStream = counterEventStream`
   call site is then unchanged. The Router/ProcessManager fixtures at lines ~1775,
   ~2131, ~7746, ~7787, ~7838 compile as-is because they now assign a
   `ValidatedEventStream` to a `ValidatedEventStream` field.

   The `brokenHiddenInputEventStream` fixture (line ~7644) stays a **bare**
   `EventStream` (it is deliberately unsafe and must never be validated); the
   validation tests refer to it directly. Any place that currently passes it to a
   runner (if any) must be removed or converted to a `mkEventStream … `-returns-
   `Left` assertion — grep confirms it is only used in validation tests today.

Acceptance for M2: `cabal test keiro-test` is green. As a live demonstration that
the guard bites, temporarily editing one fixture's runner call to pass
`counterEventStreamDef` (the bare record) instead of `counterEventStream` must
fail to compile with a type error mentioning `ValidatedEventStream`; revert the
edit after observing it.

### Milestone M3 — Prove the guarantee with tests

Scope: lock the behavior with explicit tests, both runtime and type-level. At the
end the suite asserts (a) safe streams validate and wrap, (b) the known-unsafe
stream is rejected, and (c) a bare stream cannot reach a runner.

Edits in `keiro/test/Main.hs`:

1. **Extend the existing clean-validation test** (`describe "EventStream
   replay-safety (validateEventStream)"`, line ~532) to assert every production-
   intent fixture wraps: `isRight (mkEventStream "counter" counterEventStreamDef)`,
   and likewise for the others, is `True`.

2. **Extend the existing rejection test** (`describe "mkEventStream"`, line ~540)
   to assert `mkEventStream "broken" brokenHiddenInputEventStream` is `Left` with a
   `hidden-input` warning (the test already checks the label; add a check that at
   least one `eswReason` contains `"hidden-input"`).

3. **Add an automated type-level rejection test** using an external compile probe.
   This avoids `-fdefer-type-errors` entirely. The failure mode this guards against
   is a future regression that loosens a runner back to accepting a bare
   `EventStream`; the manual-comment alternative would silently rot because
   nothing runs it.

   a. **Create the out-of-build-graph probe** at
      `keiro/test/ReplaySafetyTypeProbe.hs`. Do **not** add this module to
      `keiro-test` `other-modules`; it is intentionally ill-typed after M2 and is
      compiled only by the hspec shell-out.

      ```haskell
      {-# LANGUAGE DataKinds #-}
      {-# LANGUAGE GHC2024 #-}
      {-# LANGUAGE OverloadedStrings #-}

      module ReplaySafetyTypeProbe where

      import Effectful (Eff, IOE, (:>))
      import Effectful.Error.Static (Error)
      import Keiki.Core (HsPred)
      import Keiro
      import Kiroku.Store.Effect (Store)
      import Kiroku.Store.Error (StoreError)

      data ProbeCommand = ProbeAdd Int
          deriving stock (Eq, Show)

      data ProbeEvent = ProbeAdded Int
          deriving stock (Eq, Show)

      data ProbeState = ProbeCounting
          deriving stock (Eq, Ord, Show, Enum, Bounded)

      type ProbeEventStream =
          EventStream (HsPred '[] ProbeCommand) '[] ProbeState ProbeCommand ProbeEvent

      bareProbeEventStream :: ProbeEventStream
      bareProbeEventStream = error "type-only fixture; never evaluated"

      badRunCommand ::
          (IOE :> es, Store :> es, Error StoreError :> es) =>
          Eff es (Either CommandError (CommandResult ProbeEventStream))
      badRunCommand =
          runCommand
              defaultRunCommandOptions
              bareProbeEventStream
              (stream "type-guard-probe" :: Stream ProbeEventStream)
              (ProbeAdd 1)
      ```

      Keep the probe self-contained and valid in every respect *except* the stream
      argument type. The bare stream is `error` because the file is compiled with
      `-fno-code`; no runtime value is needed. If the probe fails for an unrelated
      missing import or ambiguous type, fix the probe before trusting the test.

   b. **Add the hspec example** in `keiro/test/Main.hs`, near the
      `describe "mkEventStream"` block. Import `System.Exit (ExitCode (..))`,
      `System.Process (readProcessWithExitCode)`, and `Data.List (isInfixOf)` if
      they are not already imported.

      ```haskell
      it "rejects a bare EventStream at runCommand (compile-time)" $ do
          (exitCode, _stdout, stderr) <-
              readProcessWithExitCode
                  "cabal"
                  [ "exec"
                  , "ghc"
                  , "--"
                  , "-fno-code"
                  , "-package"
                  , "keiro"
                  , "test/ReplaySafetyTypeProbe.hs"
                  ]
                  ""
          exitCode `shouldSatisfy` (/= ExitSuccess)
          stderr `shouldSatisfy` ("ValidatedEventStream" `isInfixOf`)
      ```

      Cabal normally runs the suite with `keiro/` as the working directory, so the
      path is `test/ReplaySafetyTypeProbe.hs`. If local execution proves the suite
      runs from the repository root instead, use `keiro/test/ReplaySafetyTypeProbe.hs`
      and record that discovery in this section and in Surprises.

Acceptance for M3: `cabal test keiro-test` is green, including the two extended
runtime tests and the compile-probe spec. As a sanity check that the guard is live,
temporarily change the probe to pass a validated stream (or temporarily loosen
`runCommand` back to a bare `EventStream` locally): the probe should compile, so the
hspec example should fail because it expected a non-zero exit. Revert after
observing.

### Milestone M4 — Update the keiro-dsl code generator and conformance goldens

Scope: make generated aggregates emit a `ValidatedEventStream` so DSL-authored
services type-check against the M2 runners, and regenerate the checked-in fixtures.

Edits:

1. **`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, `emitEventStream` (line ~1062).** Keep
   emitting the bare record under a `…Def` name and add a validated binding under
   the primary name, plus the import. The generated module gains:

   ```haskell
   import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
   ```

   and its body becomes (schematically, for aggregate `Foo`):

   ```haskell
   fooEventStreamDef :: FooEventStreamDef   -- the former bare-record alias/body
   fooEventStreamDef = EventStream { … }

   fooEventStream :: FooEventStream          -- now a ValidatedEventStream alias
   fooEventStream = mkEventStreamOrThrow "Foo" fooEventStreamDef
   ```

   where the `type FooEventStream` alias is changed to wrap in
   `ValidatedEventStream`, and a new `type FooEventStreamDef = EventStream (HsPred
   …) …` names the bare record. Export both names. Because `mkEventStreamOrThrow`
   requires `(Bounded s, Enum s, Ord s, Show s)` on the vertex type, confirm the
   generated `…Vertex` type derives all four (the harness already relies on
   `validateTransducer`, which needs them, so this should already hold; if not, add
   the deriving to the domain emitter).

2. **Update generated wiring that feeds a runner.** Wherever generated harness or
   runtime code passes the stream to `runCommand`/Router/ProcessManager/Projection,
   pass `fooEventStream` (now validated). The generated *harness* that calls
   `validateTransducer` directly (see
   `keiro-dsl/src/Keiro/Dsl/Harness.hs`) can keep using the transducer or switch to
   asserting `isRight (mkEventStream …)`; either is acceptable, but prefer keeping
   the existing assertion to minimize golden churn, and note the redundancy.

3. **Regenerate the conformance goldens.** The generator's output is checked in
   under `keiro-dsl/test/conformance*/Generated/**`. Regenerate them with the DSL's
   scaffold command (inspect `keiro-dsl/app/Main.hs` for the exact subcommand and
   flags) and commit the diff. Do not hand-edit generated files.

Acceptance for M4: the keiro-dsl conformance test suites pass (`cabal test` on the
`conformance*` targets), and a spot-check of one regenerated
`Generated/**/EventStream.hs` shows the `…Def` + validated-binding shape.

### Milestone M5 — Documentation and changelog

Scope: bring prose in line with the new guarantee.

1. **`keiro-core/src/Keiro/EventStream/Validate.hs` module haddock** and the
   `mkEventStream` note in `keiro-core/src/Keiro/EventStream.hs` (line ~47):
   state that runners accept only `ValidatedEventStream`, that `mkEventStream` is
   the sole total way to obtain one, and that `mkEventStreamOrThrow` is the partial
   escape hatch for generated/fixture code.

2. **`CHANGELOG.md`** — add under `## [Unreleased]`:

   ```markdown
   ### Changed

   - Command runners (`runCommand`, `runCommandWithSql`,
     `runCommandWithSqlEvents`) and the Router / ProcessManager / Projection
     layers now accept a `ValidatedEventStream` instead of a bare `EventStream`.
     A `ValidatedEventStream` can only be produced by `mkEventStream` (or the
     partial `mkEventStreamOrThrow`), which runs keiki's replay-safety,
     determinism, and dead-edge checks. A replay-unsafe aggregate can no longer
     reach a runner: it fails to type-check. keiro-dsl generates validated
     streams accordingly.
   ```

3. **Record the keiki-plan-68 coordination** (version-bump ordering) in the
   changelog note and confirm the Decision Log entry.

4. **Link the consumer migration guide.** A migration guide for downstream
   consumers was authored alongside this plan at
   `docs/guides/migrating-to-validated-event-stream.md` (with a worked DSL-generated
   example in danwa's repo at `docs/migrate-to-validated-event-stream.md`).
   Cross-reference it from the changelog entry and, once the API is final, verify
   the guide's signatures and the `…Def` recipe match the shipped code (the guide
   was written against the planned API and must be reconciled if M1–M2 diverged).
   Re-run `mori registry dependents shinzui/keiro --packages` and confirm the
   guide still names the registered downstream projects that will need source
   migrations after they bump keiro.

Acceptance for M5: the module haddocks and changelog read consistently with the
code; a reader learns that unvalidated streams cannot be run, and a consumer can
follow the linked guide to migrate.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

**Before starting — confirm `mkEventStream` is dead and locate all construction
sites** (establishes the migration surface):

```bash
grep -rn "mkEventStream" --include="*.hs" . | grep -v "/test/\|Validate.hs"
grep -rn "= *$" --include="*.hs" keiro/test/Main.hs >/dev/null; \
  grep -rn "EventStream$\|:: CounterEventStream\|EventStream$" --include="*.hs" keiro/test/Main.hs | head
```

Expected: the first command prints only the doc-comment reference in
`keiro-core/src/Keiro/EventStream.hs` (no call site). The second lists the fixture
type signatures to migrate.

**M1 — build keiro-core after adding the newtype:**

```bash
cabal build keiro-core
```

Expected: compiles with no errors.

**M2 — build and test keiro after threading the runners and migrating fixtures:**

```bash
cabal build all 2>&1 | tail -20
cabal test keiro-test 2>&1 | tail -40
```

Expected: `cabal build all` compiles; `keiro-test` passes. If the build fails with
`Couldn't match type 'EventStream …' with 'ValidatedEventStream …'` at a runner
call site, that site is still passing a bare record — migrate it (rename to `…Def`,
bind the validated value to the original name).

**M2 — demonstrate the guard bites (manual, revert after):** temporarily change one
test call from `counterEventStream` to `counterEventStreamDef` and rebuild:

```bash
cabal build keiro-test 2>&1 | grep -A3 "ValidatedEventStream"
```

Expected: a type error mentioning `ValidatedEventStream`. Revert the edit.

**M3 — run the extended validation tests and the type-level guard:**

```bash
cabal exec ghc -- -fno-code -package keiro test/ReplaySafetyTypeProbe.hs
cabal test keiro-test 2>&1 | grep -iE "replay-safety|mkEventStream|hidden-input|compile-time"
```

Expected: the direct `ghc -fno-code` probe exits non-zero and stderr mentions
`ValidatedEventStream`; the hspec example in `keiro-test` checks the same thing.
The replay-safety, mkEventStream, and "rejects a bare EventStream at runCommand
(compile-time)" examples pass. If the probe fails for an unrelated import or
constraint error, fix the self-contained probe before trusting the test.

**M4 — regenerate and test the DSL conformance suites** (discover the exact
subcommand first):

```bash
sed -n '1,80p' keiro-dsl/app/Main.hs        # find the scaffold subcommand + flags
# …run the scaffold regeneration per that CLI…
git status keiro-dsl/test/conformance*/Generated   # review the golden diff
cabal test 2>&1 | tail -40                  # or the specific conformance* targets
```

Expected: regenerated `EventStream.hs` files show the `…Def` + validated binding;
conformance suites pass.

**Full gate before finishing:**

```bash
just haskell-build
just haskell-test
```

Expected: both succeed (per the `justfile`: `cabal build all`, then `cabal test
keiro-test`, `keiro-pgmq-test`, `jitsurei-test`).

**Commits.** Commit once per milestone. Every commit message must carry both
trailers:

```text
ExecPlan: docs/plans/84-enforce-replay-safety-with-a-validatedeventstream-at-the-keiro-command-boundary.md
Intention: intention_01kwn3yey2er3szetce6b552dd
```

Suggested Conventional-Commit subjects:

- M1: `feat(eventstream): add ValidatedEventStream newtype and validating constructors`
- M2: `feat(command)!: runners accept only ValidatedEventStream`
- M3: `test(eventstream): prove unvalidated streams are rejected`
- M4: `feat(dsl): generate validated event streams; regenerate conformance goldens`
- M5: `docs(eventstream): document the replay-safety guarantee`

The `!` on M2 marks the breaking signature change.


## Validation and Acceptance

The change is validated by behavior, not just compilation:

1. **An unvalidated stream cannot be run.** Passing a bare `EventStream` record to
   `runCommand` is a compile error naming `ValidatedEventStream`. Demonstrated by
   the manual revert-after check in M2 and enforced by the M3 compile-probe spec.

2. **A replay-unsafe stream cannot be validated.** `mkEventStream "broken"
   brokenHiddenInputEventStream` returns `Left` with a `hidden-input @…` warning,
   so it can never produce the `ValidatedEventStream` the runners require. Asserted
   by the extended `describe "mkEventStream"` test.

3. **Safe streams still work end-to-end.** The existing `Keiro.Command` tests
   (create-and-append, snapshotting, retries) pass unchanged, now driven through
   the validated fixtures — proving the newtype is transparent to the command
   pipeline.

4. **DSL-authored aggregates type-check against the runners.** The regenerated
   conformance fixtures build and their suites pass, proving the generator emits a
   stream the runners accept.

5. **Whole-suite green.** `just haskell-test` passes (`keiro-test`,
   `keiro-pgmq-test`, `jitsurei-test`) and the keiro-dsl conformance suites pass.

Acceptance is the conjunction of all five.


## Idempotence and Recovery

Every step is additive and safe to repeat; re-running `cabal build` / `cabal test`
is idempotent, and the DSL golden regeneration is deterministic (re-running
produces the same files).

If M2's build fails only at scattered call sites with `EventStream` vs
`ValidatedEventStream` type errors, those are un-migrated construction sites; GHC
names each — apply the `…Def` rename there. This can be done incrementally; the
build converges as each site is migrated.

If the DSL regeneration (M4) produces a large or surprising golden diff, inspect it
before committing: the only intended changes are the added import, the `…Def`
alias, the validated binding, and the `type …EventStream` alias now wrapping
`ValidatedEventStream`. Anything else indicates the generator edit was too broad.

To roll back entirely, revert the commits for M1–M5 in reverse order; there are no
database migrations, no persisted-format changes (the newtype is compile-time
only, erased at runtime), and no external state involved. Note in particular that
`ValidatedEventStream` is a `newtype` with no runtime representation, so no stored
snapshot or event payload is affected.


## Interfaces and Dependencies

No new runtime or library dependency is required. M3 adds one test-only dependency
on the GHC boot package `process` so `keiro-test` can call
`readProcessWithExitCode`; it does not add a third-party test library. The
automated compile-time rejection test shells out to the already-available
Cabal/GHC toolchain. All other work is inside the existing `keiro-core`, `keiro`,
and `keiro-dsl` packages plus documentation. keiki is used only through its
existing `validateTransducer` / `defaultValidationOptions` API (already
re-exported through `Keiro.EventStream.Validate`); no keiki change is required by
this plan.

Signatures and shapes that must exist at the end of each milestone:

- **After M1** (`keiro-core/src/Keiro/EventStream/Validate.hs`):
  - `newtype ValidatedEventStream phi rs s ci co` — constructor **not** exported.
  - `unvalidated :: ValidatedEventStream phi rs s ci co -> EventStream phi rs s ci co`.
  - `mkEventStream :: (Bounded s, Enum s, Ord s, Show s) => Text -> EventStream
    (HsPred rs ci) rs s ci co -> Either [EventStreamWarning] (ValidatedEventStream
    (HsPred rs ci) rs s ci co)`.
  - `mkEventStreamWith :: (Bounded s, Enum s, Ord s, Show s) => ValidationOptions ->
    Text -> EventStream (HsPred rs ci) rs s ci co -> Either [EventStreamWarning]
    (ValidatedEventStream (HsPred rs ci) rs s ci co)`.
  - `mkEventStreamOrThrow :: (HasCallStack, Bounded s, Enum s, Ord s, Show s) => Text
    -> EventStream (HsPred rs ci) rs s ci co -> ValidatedEventStream (HsPred rs ci)
    rs s ci co`.
  - New names re-exported from `Keiro` (`keiro/src/Keiro.hs`).

- **After M2:**
  - `runCommand`, `runCommandWithSql`, `runCommandWithSqlEvents`
    (`keiro/src/Keiro/Command.hs`) take `ValidatedEventStream phi rs s ci co` as
    their stream argument; `Stream (EventStream …)` and `CommandResult
    (EventStream …)` unchanged.
  - `Router` config `targetEventStream :: ValidatedEventStream …`
    (`keiro/src/Keiro/Router.hs`).
  - `ProcessManager` config `eventStream`, `targetEventStream :: ValidatedEventStream
    …` (`keiro/src/Keiro/ProcessManager.hs`).
  - Projection runner takes `ValidatedEventStream …` (`keiro/src/Keiro/Projection.hs`).
  - `keiro/test/Main.hs` fixtures: bare records renamed `…Def`; validated values
    bound to the original names via `mkEventStreamOrThrow`.

- **After M3:** `keiro/test/Main.hs` contains extended replay-safety / mkEventStream
  assertions plus a compile-probe spec that runs `cabal exec ghc -- -fno-code
  -package keiro test/ReplaySafetyTypeProbe.hs` and asserts non-zero exit with
  `ValidatedEventStream` in stderr. The probe module exists at
  `keiro/test/ReplaySafetyTypeProbe.hs`, is self-contained, passes a bare
  `EventStream` to `runCommand`, and is **not** listed in `keiro-test`
  `other-modules`. The `keiro-test` suite depends on `process` for the shell-out.

- **After M4:** `keiro-dsl` generator `emitEventStream` renders a `…Def` bare record
  plus a validated `…EventStream` binding; conformance goldens regenerated and
  passing.

- **After M5:** module haddocks and `CHANGELOG.md` describe the new guarantee.


## Revision Notes

- **2026-07-03 — Fold Option A into M3 (superseded below).** Replaced M3's manual
  "uncomment to see the type error" comment with an automated `should-not-typecheck` test: a
  test-only dependency, an isolated `keiro/test/ReplaySafetyTypeGuard.hs` module
  compiled with `-fdefer-type-errors -Wno-deferred-type-errors`, an `other-modules`
  registration, and a `shouldNotTypecheck badRunCommand` spec. Reason: the manual
  check would rot (nothing ran it), so a future regression loosening a runner back
  to a bare `EventStream` would pass CI silently; the automated test recompiles
  with the runner API and fails loudly. Updated Progress (M3), the M3 milestone
  narrative, Concrete Steps (M3), Interfaces (test-only dependency + After-M3
  shapes), and added a Decision Log entry recording the choice, its risks
  (`-Werror`/deferred-errors collision, dependency `base` bound, false-negative
  risk), and the external compile-probe fallback.

- **2026-07-03 — Replace the deferred-error test with an external compile probe.**
  Review found that `ReplaySafetyTypeGuard` could not import the fixtures it named
  because `keiro/test/Main.hs` exports only `main`, and `should-not-typecheck`
  2.1.0 offers no message-inspecting assertion while requiring `NFData` for the
  expression under test. M3 now creates a self-contained
  `keiro/test/ReplaySafetyTypeProbe.hs` outside `other-modules` and an hspec
  example that runs `cabal exec ghc -- -fno-code` on it, expecting a
  `ValidatedEventStream` type error. Updated Progress, Surprises, Decision Log,
  the M3 milestone narrative, Concrete Steps, and Interfaces.

- **2026-07-03 — Record the downstream migration boundary.** Ran `mori registry
  dependents shinzui/keiro --packages` and recorded the registered dependent
  projects. The plan now states that downstream repo migrations are follow-up
  changes after this API and generator work lands, while this plan owns the keiro
  API, keiro-dsl generation, changelog, and migration guide. Updated Progress,
  Surprises, Decision Log, and M5 documentation guidance.
