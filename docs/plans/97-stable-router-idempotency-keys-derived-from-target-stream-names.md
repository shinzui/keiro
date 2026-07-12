---
id: 97
slug: stable-router-idempotency-keys-derived-from-target-stream-names
title: "Stable router idempotency keys derived from target stream names"
kind: exec-plan
created_at: 2026-07-12T05:07:53Z
master_plan: "docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md"
---

# Stable router idempotency keys derived from target stream names

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro's `Router` (in `keiro/src/Keiro/Router.hs`) fans one incoming event out to a
data-dependent set of target streams, and its module documentation promises that dispatch
is "exactly-once-per-target by construction … so replaying a source event writes nothing
new" (Router.hs lines 7–10). That promise is broken today. The deterministic id that makes
each dispatch idempotent is derived from the *position* of the target in the list the
router's `resolve` function returns — and `resolve` is effectful, typically a read-model
query. When the same source event is delivered twice (a routine occurrence under
at-least-once delivery: a crash before the acknowledgement, an `AckRetry`, a rebalance
where an old worker overlaps a new one), `resolve` re-runs against a read model that may
have moved in the meantime. If the list's order or membership differs between attempts,
the positional ids point at the wrong targets. The observable consequences, verified
against the actual store schema during the research for this plan, are severe: a target
can be dispatched *twice* (its aggregate transitions twice — for a counter, it is
incremented twice for one source event), and a target that `resolve` legitimately returned
can be *silently never dispatched at all*, with the router reporting a benign
"duplicate" for it.

After this change, each dispatched command's id is derived from the *identity* of its
target — the resolved target stream name — plus an occurrence index, so a redelivered
source event dedups every re-resolved target against that target's own prior dispatch,
regardless of what order or position `resolve` returned it in. A second, related fix
tightens how the router and the process manager interpret the store's "duplicate event"
rejection, so a collision with a *different* stream's event can never again be misread as
"this dispatch already happened". You can see the fix working by running the new tests in
`keiro/test/Main.hs`: two of them fail on the current code with a double-dispatched stream
and a never-dispatched stream, and pass after the change.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: red tests added to `keiro/test/Main.hs` (reorder-after-partial-dispatch, set-growth) and observed failing for the documented reasons.
- [ ] Milestone 1: passing characterization tests added (full-completion order swap, dropped target, same-target-twice) and observed passing.
- [ ] Milestone 2: `deterministicRouterCommandId`, occurrence annotation, and the transition legacy-id pre-check implemented in `keiro/src/Keiro/Router.hs`.
- [ ] Milestone 2: existing "folds a concurrent duplicate router dispatch" test updated to the new id scheme; upgrade-transition test added; all `Keiro.Router` tests green (including Milestone 1's red tests).
- [ ] Milestone 3: `confirmBenignDuplicate` added to `keiro/src/Keiro/ProcessManager.hs`, exported, and used at all three duplicate-fold sites (router dispatch, PM dispatch, PM manager-state); helper tests green.
- [ ] Milestone 4: module haddocks, `docs/guides/routers-and-effectful-fan-out.md`, and `CHANGELOG.md` updated; `nix fmt` run; full `keiro-test` suite green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (From plan authoring, 2026-07-12.) The review that spawned this plan sketched the
  failure as "a pure order swap double-dispatches every target". Mechanically that is not
  quite what happens, because kiroku's `events` table has a **global** primary key on
  `event_id` (`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`, line 68:
  `event_id UUID PRIMARY KEY`). When a shifted positional id is appended to the *wrong*
  stream, the global key rejects it, and the loose fold at Router.hs:170–171 (which
  accepts any `DuplicateEvent` whose id matches, or any id-less `DuplicateEvent`, as
  benign) masks the rejection as "already processed". The real failure modes are
  therefore: (1) after a *partial* dispatch (crash mid-fan-out) plus reorder, one target
  is double-dispatched and another is silently never dispatched; (2) after a *complete*
  dispatch plus membership drift, a newly resolved target whose position collides with an
  old id is silently never dispatched; (3) a pure order swap after complete dispatch is
  coincidentally harmless — but only via the misfold, which is itself the smaller defect
  this plan fixes. Milestone 1's red tests target (1) and (2).
- The router supplies exactly **one** deterministic id per target command, not one per
  emitted event: Router.hs:153 sets `eventIds .~ [commandId]`, and
  `keiro/src/Keiro/Command.hs` `assignEventIds` (lines 665–669) assigns supplied ids to
  emitted events in order, leaving any further events to receive store-generated ids.
  Because the batch append is one transaction, deduping on the first event's id covers the
  whole batch. So the name-keyed scheme also needs exactly one id per target command —
  there is no per-event index to migrate.
- keiro already has a precedent for name-keyed deterministic ids:
  `keiro/src/Keiro/Workflow.hs` `deterministicJournalId` (lines 894–911) keys journal ids
  by workflow name, id, generation, and *step name* precisely so ids do not depend on
  position.


## Decision Log

Record every decision made while working on the plan.

- Decision: the target identity used in the new id is the *resolved physical stream name*
  — the `StreamName` produced by `resolveStreamName` (applied at Router.hs:156) — not the
  typed `Stream` handle or the command payload.
  Rationale: it is the only stable, total, textual identity every dispatch already
  computes; it is exactly what "per-target" means operationally (one aggregate stream);
  and it is available before the append. The typed `Stream targetCi` value
  (`keiro/src/Keiro/ProcessManager.hs`, `PMCommand` at lines 128–132) has no `Show`/text
  identity of its own.
  Date: 2026-07-12

- Decision: one deterministic id per target *command*, keyed by
  `(router name, key, source event id, target stream name, occurrence)`, where
  `occurrence` counts earlier commands in the same resolve batch addressed to the same
  stream name (0 for the first).
  Rationale: investigation showed the positional `emitIndex` never indexed events within
  one command — each command gets exactly one id (see Surprises). The occurrence index is
  required because `resolve` may legally return two commands for the same target stream in
  one batch; without it the second command's id would equal the first's and the second
  dispatch would self-dedup into silence within a single attempt. The occurrence index is
  stable under reordering of *distinct* targets (the defect being fixed); the relative
  order of same-stream duplicates remains positional, which is documented as a residual
  contract.
  Date: 2026-07-12

- Decision: dropped-target semantics — if a target was dispatched on attempt 1 and
  `resolve` no longer returns it on attempt 2, it is simply not dispatched again and
  keeps its attempt-1 dispatch. Nothing is compensated or deleted.
  Rationale: `resolve` is the authority at dispatch time, and events already appended to
  a target aggregate are immutable facts. Name-keyed dedup makes the retained dispatch
  harmless (a later redelivery that resolves it again dedups against it). The residual
  contract is documented in the module haddock and the guide: across redeliveries the
  dispatched *set* is the union of per-attempt resolve outputs, so where the exact set
  matters, `resolve` must be a stable (effectively pure) function of the source event
  between redeliveries.
  Date: 2026-07-12

- Decision: the process manager keeps its positional id scheme
  (`deterministicCommandId`, `keiro/src/Keiro/ProcessManager.hs:229–243`); only the
  router changes scheme.
  Rationale: the PM's command list comes from `handle :: input -> ProcessManagerAction`
  (ProcessManager.hs:111), a pure function — replaying the same input always yields the
  same list in the same order, so positional ids are genuinely deterministic there. Only
  the router's `resolve` runs in `Eff es` (Router.hs:89–91). Changing the PM scheme would
  buy nothing and would invalidate every deployed PM id.
  Date: 2026-07-12

- Decision: the new id uses a distinct `"router"` namespace tag (the old code reused the
  PM's `"process-manager"` tag by calling `deterministicCommandId`), and the derivation
  lives in `Keiro.Router` as `deterministicRouterCommandId`.
  Rationale: routers and PMs with the same `name` should never be able to collide; the
  scheme is router-specific so it belongs in the router module; and the migration cost is
  already being paid (any change to the inputs changes every id).
  Date: 2026-07-12

- Decision: migration — implement an unconditional transition pre-check: before running a
  command, the dispatcher checks the target stream for the *new* name-keyed id and, if
  absent, also for the *legacy* positional id (computed with the old
  `deterministicCommandId` and the command's position in the current resolve output). A
  hit on either folds to `PMCommandDuplicate`. The legacy check is documented in
  `CHANGELOG.md` as removable in a later release.
  Rationale: a redelivery spanning the upgrade would otherwise double-dispatch once per
  target (the old id is invisible to the new pre-check, and the store cannot reject the
  new id because it differs). The check costs one extra indexed point-read per dispatch
  only when the new id is absent, and it fully covers the common case (stable resolve
  across the upgrade). It cannot cover an upgrade-spanning redelivery whose resolve
  output *also* drifted — that residual one-time risk is accepted and documented, since
  it is exactly the window the old scheme made unsafe on every redelivery. The
  alternative (accept the whole risk, ship only a changelog note) was rejected because a
  double-dispatch mutates target aggregates, which is user-visible corruption, and the
  mitigation is three lines.
  Date: 2026-07-12

- Decision: tighten the duplicate fold at all three sites (Router.hs:168–172,
  ProcessManager.hs:292–297 manager-state, ProcessManager.hs:337–341 dispatch) via one
  shared helper, `confirmBenignDuplicate`, which treats a `DuplicateEvent` as benign only
  after verifying the attempted id is actually present *in the target stream*
  (`eventExistsInStream`). `DuplicateEvent` with a mismatched id stays a failure without
  any read.
  Rationale: kiroku's `DuplicateEvent` carries `Maybe EventId`
  (`kiroku-store/src/Kiroku/Store/Error.hs`, constructor at lines 93–101): `Just` the
  colliding id when PostgreSQL's detail string parses, `Nothing` otherwise (rare;
  locale-dependent — see `mapUniqueViolation`, Error.hs:268–281). Because the `events`
  primary key is global, even `Just ourId` does not prove the event is in *our* stream —
  the id may live in a different stream (the exact mechanism behind the silent-drop
  failure above), and `Nothing` proves nothing at all. Comparing ids alone is therefore
  insufficient; the only honest confirmation keiro can make is the per-stream point
  lookup it already uses for the pre-check. The extra read runs only on the rare
  duplicate-rejection path. Behavior change: an unconfirmed collision now surfaces as
  `PMCommandFailed` (worker: `AckHalt`, since `DuplicateEvent` is non-transient per
  ProcessManager.hs:201) instead of being silently swallowed — halting on evidence of an
  id collision is the safe posture.
  Date: 2026-07-12

- Decision: the fold tightening (Milestone 3) lands *after* the id scheme change
  (Milestone 2), never before.
  Rationale: under the positional scheme, cross-stream self-collisions occur on routine
  reordered redeliveries; tightening the fold first would convert those from silent
  no-ops into worker halts. Under the name-keyed scheme a router can no longer collide
  with itself across streams, so the tightened fold only fires on genuine anomalies.
  Date: 2026-07-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section is self-contained; read it even if you know the repo.

The repository (working directory for every command in this plan) is
`/Users/shinzui/Keikaku/bokuno/keiro`. It is a Haskell cabal multi-package project; the
package relevant here is `keiro` (directory `keiro/`), and everything this plan edits
lives in three files: `keiro/src/Keiro/Router.hs`, `keiro/src/Keiro/ProcessManager.hs`,
and `keiro/test/Main.hs`, plus documentation. Development happens inside the Nix dev
shell (`nix develop`, or automatically via direnv), which provides GHC, cabal, and the
PostgreSQL binaries the test suite needs.

Some vocabulary, in plain language:

- An *event store* (provided by the separate `kiroku` library) is a PostgreSQL-backed
  append-only log. Events live in named *streams* (a `StreamName` is a newtype over
  `Text`). Every event has a globally unique `EventId` (a UUID) — the `events` table's
  primary key is `event_id` alone, across all streams.
- A *command* here is a request to a target aggregate that, if accepted, appends one or
  more events to that aggregate's stream in one transaction.
- *At-least-once delivery* means the messaging layer may hand the same source event to a
  worker more than once (crash before acknowledgement, retry, rebalance overlap).
  Correctness therefore depends on *idempotency*: doing the work twice must change
  nothing the second time.
- A *deterministic id* is how keiro gets idempotency: derive the appended event's id
  purely from stable inputs (a *v5 UUID* is a UUID computed as a hash of a name string,
  so equal inputs give equal UUIDs), pre-check whether that id is already in the target
  stream, and let the store's uniqueness constraint reject a concurrent double-write.
- A *router* (`Keiro.Router`) reacts to one source event by *resolving* a set of target
  streams — `resolve :: input -> Eff es [PMCommand targetCi]`, an effectful function,
  typically a read-model (SQL table) query — and dispatching one command per resolved
  target. A `PMCommand` (defined in `Keiro.ProcessManager`, lines 128–132) pairs a typed
  target stream handle with the command value. A *process manager* is the stateful
  sibling whose command list comes from a *pure* function of the input.

The defect, precisely. In `runRouterOnce` (Router.hs:142–152), the resolved commands are
numbered `zip [0 ..]` and each dispatch derives its id as
`deterministicCommandId (router ^. #name) correlationId sourceEventId emitIndex`
(Router.hs:152), i.e. a v5 UUID over
`"keiro:process-manager:<name>:<key>:<source-uuid>:<position>"`
(ProcessManager.hs:229–243). The id is then used three ways: it is the single supplied
event id for the append (`targetOptions = options & #eventIds .~ [commandId]`,
Router.hs:153), it is pre-checked with `eventAlreadyIn` against the resolved target
stream name (Router.hs:156–157; `eventAlreadyIn` is a per-stream point lookup,
ProcessManager.hs:481–488), and the store's `DuplicateEvent` rejection is folded to a
benign `PMCommandDuplicate` (Router.hs:168–172). Because the id encodes the *position*,
a redelivery whose `resolve` output is ordered or composed differently assigns targets
ids that belong to other targets. The per-stream pre-check misses (the id lives in a
different stream), the append proceeds, and then one of two things happens: the global
`events` primary key rejects the append and the loose fold (which accepts
`DuplicateEvent (Just id)` when `id` equals the attempted id — which it does, the id
merely lives elsewhere — and accepts `DuplicateEvent Nothing` unconditionally,
Router.hs:170–171) reports a lying "duplicate", so the target is never dispatched; or
the id is genuinely fresh and the target receives a second event. The existing replay
test ("reports every dispatch as a duplicate on replay", `keiro/test/Main.hs:2102`)
seeds the read-model table once and never changes it, so resolve is frozen and none of
this is exercised.

The same loose `DuplicateEvent Nothing` fold appears twice in the process manager: for
the manager-state append (ProcessManager.hs:295–296) and for target dispatch
(ProcessManager.hs:339–340). There, positional ids are sound (pure `handle`), but the
fold shares the router's dishonesty: an id-less duplicate report, or a matching-id
collision from a different stream, is folded to "already processed" without checking the
stream. kiroku cannot always supply the id: `DuplicateEvent !(Maybe EventId)` carries
`Nothing` when the PostgreSQL detail string is unparseable (see the kiroku source,
discoverable via `mori registry show kiroku --full`; file
`kiroku-store/src/Kiroku/Store/Error.hs`, constructor at lines 93–101 and the parser at
lines 268–281 and 370–381). What keiro *can* always compare against is its own attempted
id plus the target stream, via `eventExistsInStream` (imported from `Kiroku.Store.Read`
at ProcessManager.hs:71).

Test infrastructure you will use. `keiro/test/Main.hs` is one hspec suite
(`main = withMigratedSuite $ \fixture -> hspec $ ...`, line 317). The fixture
(`keiro-test-support/src/Keiro/Test/Postgres.hs`) starts one cached ephemeral PostgreSQL
server per suite and clones a fresh migrated database per example, so tests need no
external database — but the dev shell must provide `initdb`/`postgres`. The router
examples live under `describe "Keiro.Router"` (Main.hs:2066). Reusable fixtures:
`demoRouter` (Main.hs:8525–8549) resolves targets from a `router_targets` SQL table;
`RouteGroup` (8506) is the router input; `recordedFromEventId` (8088) builds a source
`RecordedEvent`; `appendCounterEventWithId` (8094) appends a counter event with a chosen
id; `sampleUuid`/`sampleUuid2`/`sampleUuid3` (8104–8121) are fixed UUIDs; `isAppended`/
`isDuplicate` (8551–8559) classify results. The "finalizes AckRetry" example
(Main.hs:2196–2224) shows the pattern this plan's new tests copy: an inline `Router`
record whose `resolve` closure reads an `IORef` attempt counter via `liftIO`.


## Plan of Work

The work is four milestones. Milestones 1 and 2 fix the id scheme (red tests first, then
the fix); Milestone 3 tightens the duplicate fold (deliberately after Milestone 2 — see
the Decision Log); Milestone 4 aligns every piece of documentation that states the old
contract. Each milestone leaves the tree compiling and the full suite in a known state.


### Milestone 1 — Characterize the defect with tests (two red, three green)

Scope: add five examples to the `describe "Keiro.Router"` block in `keiro/test/Main.hs`
(after the existing replay test at line 2102). At the end of this milestone, two tests
fail against current code — proving the double-dispatch and the silent drop — and three
pass, pinning behavior that must not change. No production code changes.

Each test builds an inline router whose `resolve` returns a different list per attempt,
using an `IORef` counter exactly like `flakyRouter` (Main.hs:2196–2224). No SQL table is
needed — returning a hard-coded list per attempt *is* the unstable read model. The
"redelivery" is simply calling `runRouterOnce` twice with the same `RecordedEvent`, the
same harness the frozen replay test at Main.hs:2102 uses. A shared local helper keeps
them terse:

```haskell
-- Local to the Keiro.Router describe block (or a top-level fixture near demoRouter):
-- a router that returns the attempt-indexed target list and counts attempts.
unstableRouter ::
    (IOE :> es, Store :> es) =>
    IORef Int ->
    (Int -> [Text]) ->
    Router RouteGroup (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent es
unstableRouter attemptsRef targetsFor =
    Router
        { name = "unstable-router"
        , key = \(RouteGroup g) -> g
        , resolve = \_ -> do
            attempt <- liftIO (atomicModifyIORef' attemptsRef (\n -> (n + 1, n)))
            pure [PMCommand{target = stream t, command = Add 1} | t <- targetsFor attempt]
        , targetEventStream = counterEventStream
        , targetProjections = const []
        }
```

Test 1 (RED — the crash-window reorder): attempt 0 resolves `["swap-a"]` (this simulates
attempt 1 having resolved `[A, B]` and crashed after dispatching only A — identical store
state, since A held position 0); attempt 1 resolves `["swap-b", "swap-a"]`. Dispatch the
same source event twice through `runRouterOnce`. Assert: the second result has exactly
two elements, the `swap-b` result `isAppended` and the `swap-a` result `isDuplicate`; and
`Store.readStreamForward` shows exactly 1 event in `swap-a` and 1 in `swap-b`. Current
code fails with `swap-a` holding 2 events (double dispatch: position 1's id is fresh) and
`swap-b` holding 0 (silent drop: position 0's id collides globally with `swap-a`'s event
and the loose fold reports "duplicate").

Test 2 (RED — set growth): attempt 0 resolves `["growth-a", "growth-b"]` and completes;
attempt 1 resolves `["growth-a", "growth-c"]`. Assert: second result is
`[duplicate, appended]`; streams `growth-a`, `growth-b`, `growth-c` hold 1 event each.
Current code fails with `growth-c` at 0 events (its position-1 id already exists in
`growth-b`; the misfold reports "duplicate").

Test 3 (GREEN — full-completion order swap): attempt 0 `["order-a", "order-b"]`
completes; attempt 1 `["order-b", "order-a"]`. Assert both second-attempt results
`isDuplicate` and both streams hold 1 event. This passes today *coincidentally* (via the
global key plus the misfold — see Surprises) and must pass genuinely after the fix; it
is the plan's headline "order swap changes nothing" acceptance.

Test 4 (GREEN — dropped target): attempt 0 `["drop-a", "drop-b"]` completes; attempt 1
`["drop-b"]` only. Assert: second result is one `PMCommandDuplicate`; `drop-a` still
holds exactly 1 event (its attempt-1 dispatch is kept, per the Decision Log) and
`drop-b` holds 1. Give the test a comment stating this is the *decided* dropped-target
semantics: resolve is the authority per attempt, the dispatched set across attempts is
the union.

Test 5 (GREEN — same target twice in one resolve): a single attempt resolves
`["twin", "twin"]` (two commands to the same stream). Assert both results `isAppended`
and the `twin` stream holds 2 events; a second delivery of the same source event yields
two `PMCommandDuplicate`s and the stream still holds 2. This pins the behavior the
occurrence index must preserve — a naive name-only id would silently drop the second
command within the *first* attempt.

Acceptance: `cabal run keiro:test:keiro-test -- --match "Keiro.Router"` reports exactly
2 failures (tests 1 and 2), each failing on the stream-count assertions described above.


### Milestone 2 — Name-keyed ids with a transition legacy check

Scope: change the id derivation in `keiro/src/Keiro/Router.hs` and nothing else. At the
end, all `Keiro.Router` tests pass, including Milestone 1's red ones, plus a new
upgrade-transition test.

First, add the new derivation function to `Keiro.Router` and export it from the module's
export list (under a new `-- * Idempotency` section) so tests can compute expected ids:

```haskell
{- | Derive a stable, collision-resistant 'EventId' for a router dispatch from
@(router name, key input, source event id, resolved target stream name,
occurrence)@ via a v5 UUID.

Unlike 'Keiro.ProcessManager.deterministicCommandId' (which the process manager
still uses, soundly, because its command list is a pure function of the input),
the router keys the id by the /target's identity/ rather than its position in
the resolved list: 'resolve' is effectful, so a redelivery may see the same
targets in a different order or a drifted set, and a positional id would then
point at the wrong target. The @occurrence@ is the index among commands in the
/same resolve batch/ that address the same target stream (0 for the first), so
resolving the same target twice in one batch still yields distinct ids. The
occurrence is the final field and never contains a colon, so the encoding is
unambiguous even for stream names containing colons.
-}
deterministicRouterCommandId :: Text -> Text -> EventId -> StreamName -> Int -> EventId
deterministicRouterCommandId routerName correlationId sourceEventId targetStreamName occurrence =
    EventId
        $ UUID.V5.generateNamed UUID.V5.namespaceURL
        $ fmap (fromIntegral . fromEnum)
        $ Text.unpack
        $ Text.intercalate
            ":"
            [ "keiro"
            , "router"
            , routerName
            , correlationId
            , UUID.toText (coerce sourceEventId)
            , coerce targetStreamName
            , Text.pack (show occurrence)
            ]
```

This needs new imports in Router.hs: `Data.UUID qualified as UUID`,
`Data.UUID.V5 qualified as UUID.V5` (mirror the import style at the top of
`ProcessManager.hs`), and `StreamName` added to the existing
`Kiroku.Store.Types (RecordedEvent)` import. `EventId` and `StreamName` are newtypes
over `UUID` and `Text` respectively, so `coerce` (already imported) unwraps them; if the
newtypes' constructors are directly importable, pattern-matching them is equally fine.
Note the deliberate `"router"` tag replacing the old reuse of `"process-manager"` (see
the Decision Log).

Second, rework `runRouterOnce` (currently Router.hs:142–175). Replace the
`zip [0 ..]`-driven traversal with one that annotates each command with three things:
its legacy position (still needed for the transition check), its resolved target stream
name (hoisted out of `dispatchCommand`, where lines 155–156 already compute it), and its
per-stream-name occurrence. The shape:

```haskell
runRouterOnce options router sourceEvent input = do
    let correlationId = (router ^. #key) input
    commands <- (router ^. #resolve) input
    let named =
            [ (streamNameOf command, command)
            | command <- commands
            ]
        annotated = snd (mapAccumL occurrenceStep Map.empty (zip [0 ..] named))
        occurrenceStep seen (legacyIndex, (targetStreamName, command)) =
            let occurrence = Map.findWithDefault 0 targetStreamName seen
             in ( Map.insert targetStreamName (occurrence + 1) seen
                , (legacyIndex, occurrence, targetStreamName, command)
                )
    results <-
        traverse
            (dispatchCommand correlationId (sourceEvent ^. #eventId))
            annotated
    pure (RouterResult results)
  where
    streamNameOf command =
        ((unvalidated (router ^. #targetEventStream)) ^. #resolveStreamName)
            (retarget (command ^. #target))
```

`mapAccumL` comes from `Data.Traversable`; `Map` is `Data.Map.Strict qualified as Map`
(the `containers` dependency and this import style are already used by
`keiro/src/Keiro/Inbox.hs`). Inside `dispatchCommand`, which now receives
`(legacyIndex, occurrence, targetStreamName, command)`:

```haskell
    dispatchCommand correlationId sourceEventId (legacyIndex, occurrence, targetStreamName, command) = do
        let commandId =
                deterministicRouterCommandId
                    (router ^. #name)
                    correlationId
                    sourceEventId
                    targetStreamName
                    occurrence
            -- Transition (see CHANGELOG): dispatches written by keiro versions that
            -- derived positional ids must still dedup across the upgrade. Remove in a
            -- later release.
            legacyCommandId =
                deterministicCommandId (router ^. #name) correlationId sourceEventId legacyIndex
            targetOptions = options & #eventIds .~ [commandId]
            targetStream = retarget (command ^. #target)
        commandAlreadyProcessed <- eventAlreadyIn options targetStreamName commandId
        legacyAlreadyProcessed <-
            if commandAlreadyProcessed
                then pure False
                else eventAlreadyIn options targetStreamName legacyCommandId
        if
            | commandAlreadyProcessed -> pure (PMCommandDuplicate commandId)
            | legacyAlreadyProcessed -> pure (PMCommandDuplicate legacyCommandId)
            | otherwise -> ... -- unchanged runCommandWithProjections + fold, for now
```

(Use whatever conditional style the file's fourmolu setup prefers — nested `if`/`else`
is fine if `MultiWayIf` is not enabled.) The `Left`-fold arms stay exactly as they are
in this milestone; Milestone 3 replaces them.

Third, update the one existing test that hardcodes the old derivation: "folds a
concurrent duplicate router dispatch to PMCommandDuplicate" (Main.hs:2250–2281) computes
`commandId = deterministicCommandId "demo-router" "g1" (sourceEvent ^. #eventId) 0` at
line 2259. Change it to
`deterministicRouterCommandId "demo-router" "g1" (sourceEvent ^. #eventId) (StreamName "router-duplicate-target") 0`
and import `deterministicRouterCommandId` from `Keiro.Router` in the test's import list.

Fourth, add the transition test (GREEN once this milestone is done): seed
`router_targets` with `("g1", "transition-target")`; compute the *legacy* id
`deterministicCommandId "demo-router" "g1" (sourceEvent ^. #eventId) 0` and append it
directly with `appendCounterEventWithId storeHandle (StreamName "transition-target") legacyId (CounterAdded 1)`
— this simulates a dispatch performed by the pre-upgrade code; then run `runRouterOnce`
with `demoRouter` and assert the single result `isDuplicate` and the stream still holds
exactly 1 event.

Acceptance: `cabal run keiro:test:keiro-test -- --match "Keiro.Router"` is fully green;
in particular Milestone 1's tests 1 and 2 now pass, and the frozen replay test at
Main.hs:2102 still passes (stable resolve keeps working through the scheme change
because the new ids are used on both attempts).


### Milestone 3 — Honest duplicate folding, shared by router and process manager

Scope: add one helper to `keiro/src/Keiro/ProcessManager.hs`, use it at the three fold
sites, and test it. At the end, an id-less or cross-stream `DuplicateEvent` can no longer
be misread as "already processed" anywhere in keiro.

Add next to `eventAlreadyIn` (ProcessManager.hs:481–488) and export from the module's
export list right after it:

```haskell
{- | Decide whether a failed append is a benign duplicate of /the write we just
attempted/, i.e. whether @ourId@ is genuinely present in @streamName@.

kiroku's @DuplicateEvent@ carries 'Just' the colliding id only when PostgreSQL's
detail string parses ('Nothing' otherwise), and because the store's event-id
uniqueness is /global/, even a matching id does not prove the event landed in
our stream — it may exist in a different stream entirely. So: a mismatched id
is never ours; a matching or missing id is confirmed against the target stream
with a point lookup. Callers fold 'True' into their duplicate result and
surface 'False' as the original failure.
-}
confirmBenignDuplicate ::
    (Store :> es) =>
    StoreTypes.StreamName ->
    EventId ->
    CommandError ->
    Eff es Bool
confirmBenignDuplicate streamName ourId = \case
    StoreFailed (DuplicateEvent (Just duplicateId))
        | duplicateId == ourId -> eventExistsInStream streamName ourId
    StoreFailed (DuplicateEvent Nothing) -> eventExistsInStream streamName ourId
    _ -> pure False
```

Then replace the three folds. In `Keiro.Router.dispatchCommand` (the arms written in
Milestone 2, originally Router.hs:168–172):

```haskell
                outcome <- runCommandWithProjections targetOptions targetEventStream targetStream (command ^. #command) ((router ^. #targetProjections) (command ^. #target))
                case outcome of
                    Right result -> pure (PMCommandAppended result)
                    Left err -> do
                        benign <- confirmBenignDuplicate targetStreamName commandId err
                        pure $ if benign then PMCommandDuplicate commandId else PMCommandFailed err
```

In `runProcessManagerOnce`'s target dispatch (ProcessManager.hs:337–341), the identical
transformation with its own `targetStreamName`/`commandId`. In the manager-state append
(ProcessManager.hs:291–297):

```haskell
            case managerOutcome of
                Left err -> do
                    benign <- confirmBenignDuplicate managerStreamName managerEventId err
                    if benign
                        then finish correlationId (PMStateDuplicate managerEventId) action
                        else pure (Left err)
                Right (managerResult, scheduledInAppend) -> ...
```

Add `Keiro.Router`'s import of `confirmBenignDuplicate` to its existing
`Keiro.ProcessManager` import list.

Tests (a new `describe "Keiro.ProcessManager duplicate confirmation"` block in
`keiro/test/Main.hs`, `around (withFreshStore fixture)`, running the helper through
`Store.runStoreIO storeHandle`): first append one unrelated event to a scratch stream so
the stream exists; then assert (1) `DuplicateEvent (Just otherId)` (any id other than
`ourId`) confirms `False` — the mismatch case the review flagged; (2)
`DuplicateEvent (Just ourId)` with `ourId` *absent* from the stream confirms `False` —
the cross-stream collision case; (3) after `appendCounterEventWithId` writes `ourId`
into the stream, both `DuplicateEvent (Just ourId)` and `DuplicateEvent Nothing` confirm
`True`; (4) a non-duplicate error such as `StoreFailed (Store.ConnectionLost "boom")`
confirms `False`. The existing integration tests exercising the true-duplicate race —
"folds a concurrent duplicate router dispatch" (Main.hs:2250), "folds a concurrent
duplicate target dispatch" (Main.hs:1960), "folds a concurrent duplicate manager-state
append" (Main.hs:1988) — must still pass unchanged, because in each the concurrent
insert put the id into the *correct* stream, which the verification lookup confirms.

Acceptance: full `cabal test keiro-test` green.


### Milestone 4 — Documentation states the real contract

Scope: prose only; no behavior change. The module haddock in
`keiro/src/Keiro/Router.hs` (lines 1–14) currently claims "exactly-once-per-target by
construction … so replaying a source event writes nothing new". Replace the claim with
the precise contract, in substance:

  Dispatch is idempotent per target: each command is appended under a deterministic id
  derived from (router name, key input, source event id, resolved target stream name,
  occurrence), pre-checked against the target stream, with store-level duplicate
  rejections confirmed against the target stream before being folded to
  `PMCommandDuplicate`. Redelivering a source event therefore dedups every re-resolved
  target against its own prior dispatch, regardless of the order or composition of the
  resolved list. What is not guaranteed: `resolve` is effectful, so a redelivery may
  resolve a different set; the dispatched set across attempts is the union — a target
  resolved only on the first attempt keeps its dispatch, and a target resolved only on a
  later attempt is dispatched then. Where the exact set matters, `resolve` must be a
  stable function of the source event across redeliveries.

Also update: the `Router` record haddock (Router.hs:63–83), whose lines 73–77 describe
the `(name, key input, source event id, emit index)` derivation — swap in the new tuple
and point at `deterministicRouterCommandId`; the `runRouterOnce` haddock
(Router.hs:114–127), which says the per-target logic is "identical to
runProcessManagerOnce's dispatchCommand" — no longer true, describe the difference in
one sentence; the `deterministicCommandId` haddock in ProcessManager.hs (lines 221–228)
— add a sentence that the process manager's positional index is sound because `handle`
is pure, and that the router uses `deterministicRouterCommandId` instead (retaining the
legacy positional id only as a transition dedup check); and the "Idempotency" section of
`docs/guides/routers-and-effectful-fan-out.md` (lines 172–181), which documents the
`(router name, key input, source event id, target index)` tuple — restate the new tuple,
the dropped-target/union semantics, and the residual stable-resolve requirement.

Finally, record the change in the root `CHANGELOG.md` under `## [Unreleased]`: a
Breaking Changes entry (router deterministic command ids changed derivation; an
upgrade-spanning redelivery is covered by a transition pre-check of the legacy
positional id, which a later release will remove; redeliveries whose resolve output also
drifted across the upgrade may dispatch a target at most one extra time) and an Other
Changes entry (duplicate-event rejections in router and process-manager dispatch are now
confirmed against the target stream before being treated as benign; unconfirmed
collisions surface as failures and halt the worker).

Acceptance: `nix fmt` produces no diff churn beyond the touched files;
`cabal build keiro` succeeds with no new warnings (the package builds with warnings on;
haddock edits can break the build via malformed markup, so compile after editing);
full test suite green.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`, inside
the Nix dev shell (`nix develop` if direnv has not already activated it). The test suite
starts its own ephemeral PostgreSQL; no database setup is required.

Build the package and run the full suite once before touching anything, to confirm a
green baseline:

```bash
cabal build keiro
cabal test keiro-test --test-show-details=direct
```

Run only the router examples (the tight loop for Milestones 1–2; hspec's `--match`
selects by describe/it path):

```bash
cabal run keiro:test:keiro-test -- --match "Keiro.Router"
```

After Milestone 1, expect exactly two failures, shaped like:

```text
Keiro.Router
  dedups by target identity when a redelivered resolve reorders targets after a partial dispatch FAILED [1]
  dispatches a target added by resolve drift instead of misreading it as a duplicate FAILED [2]
  ...

  1) expected: 1
     but got: 2          -- swap-a was dispatched twice
  ...
  2) expected: 1
     but got: 0          -- growth-c was never dispatched
```

(The literal failure text depends on which assertion fires first; what matters is the
double-dispatch count on the reordered stream and the zero count on the added stream.)

After each of Milestones 2 and 3, re-run the match command and expect zero failures;
after Milestone 3 and 4, run the full suite and the formatter:

```bash
cabal run keiro:test:keiro-test -- --match "Keiro.Router"
cabal run keiro:test:keiro-test -- --match "duplicate confirmation"
cabal test keiro-test --test-show-details=direct
nix fmt
```

Commit at each milestone boundary with conventional-commit messages, for example:

```text
test(router): characterize positional-id drift on redelivery (2 red)
fix(router): derive dispatch ids from target stream names, not positions
fix(dispatch): confirm duplicate-event rejections against the target stream
docs(router): state the precise per-target idempotency contract
```


## Validation and Acceptance

The change is accepted when all of the following hold, in order:

1. On the unmodified tree, the two Milestone 1 tests fail exactly as described (one
   stream with 2 events where 1 is expected; one stream with 0 events where 1 is
   expected). This proves the tests actually witness the defect rather than passing
   vacuously.
2. After Milestone 2, `cabal run keiro:test:keiro-test -- --match "Keiro.Router"` is
   green: reordered redelivery yields all-duplicates with every stream at exactly one
   event; set growth dispatches the added target exactly once; the dropped target keeps
   its attempt-1 event; same-target-twice appends two events once and none on replay;
   the pre-upgrade legacy-id seeding test reports a duplicate and appends nothing; and
   the pre-existing frozen replay test (Main.hs:2102) still passes.
3. After Milestone 3, the `confirmBenignDuplicate` examples pass: mismatched-id and
   absent-id duplicate reports confirm `False`; present-id reports (with and without the
   id in the error) confirm `True`; and the three pre-existing concurrent-duplicate
   integration tests still pass.
4. `cabal test keiro-test --test-show-details=direct` reports 0 failures for the whole
   suite (the process-manager, snapshot, timer, and worker examples guard against
   regressions from the shared fold change).
5. Reading `keiro/src/Keiro/Router.hs`'s module haddock and
   `docs/guides/routers-and-effectful-fan-out.md`'s Idempotency section, a reviewer
   finds no remaining claim of unconditional exactly-once; both state the per-target
   union contract and the stable-resolve requirement.


## Idempotence and Recovery

Every step is safe to repeat. Tests run against per-example database clones, so re-runs
cannot interfere with one another; `cabal build`/`cabal test` are incremental and
re-runnable; `nix fmt` is idempotent. If a milestone is interrupted midway, the tree
either fails to compile (finish the edit) or fails specific named tests (the Progress
section records which milestone was in flight — split its checklist entry into done and
remaining before stopping). No step touches production data or performs a migration; the
id-scheme change affects only ids computed at runtime by new code, and its
upgrade-window behavior for *deployments* is handled by the transition check and the
CHANGELOG note, not by any action in this plan. If Milestone 3 must be reverted
independently, the three fold sites can be restored to id-equality folds without
touching Milestone 2 — the milestones are additive in that direction (the reverse is not
safe: do not ship Milestone 3 without Milestone 2, per the Decision Log).


## Interfaces and Dependencies

No new package dependencies: `containers` (`Data.Map.Strict`), `uuid`
(`Data.UUID.V5`), `effectful`, and kiroku's store API are already dependencies of the
`keiro` package (see `keiro/keiro.cabal`, `build-depends` around line 95). kiroku is
consumed as-is; the relevant facts are that `Kiroku.Store.Error.StoreError` has
`DuplicateEvent !(Maybe EventId)`, that `Kiroku.Store.Read.eventExistsInStream ::
StreamName -> EventId -> Eff es Bool` (already imported by
`keiro/src/Keiro/ProcessManager.hs:71`) is a per-stream point lookup, and that the
store's event-id uniqueness is global across streams.

At the end of Milestone 2, `keiro/src/Keiro/Router.hs` exports:

```haskell
deterministicRouterCommandId :: Text -> Text -> EventId -> StreamName -> Int -> EventId
```

with the semantics in the Decision Log (v5 UUID over
`"keiro:router:<name>:<key>:<source-uuid>:<target-stream-name>:<occurrence>"`).

At the end of Milestone 3, `keiro/src/Keiro/ProcessManager.hs` exports:

```haskell
confirmBenignDuplicate ::
    (Store :> es) => StreamName -> EventId -> CommandError -> Eff es Bool
```

used by `Keiro.Router.runRouterOnce` (one site) and `Keiro.ProcessManager.
runProcessManagerOnce` (two sites: manager-state append and target dispatch).
`deterministicCommandId` keeps its exact current signature and derivation — the process
manager and the router's transition check both still call it, and the workflow journal's
`deterministicJournalId` (`keiro/src/Keiro/Workflow.hs`) is untouched.

---

Revision note (2026-07-12): initial authoring. The plan sharpens the parent review's
defect description after source verification: because kiroku's `events` primary key is
global, positional-id drift manifests as silent permanently-dropped dispatches (masked
by the loose `DuplicateEvent` fold) plus crash-window double dispatches, rather than as
unconditional double dispatch on any order swap; the milestones, tests, and the
Milestone 2→3 ordering constraint follow from that mechanism.
