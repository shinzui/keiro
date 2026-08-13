---
id: 246
slug: preserve-cross-source-global-position-order-in-buffered-replay-paging
title: "Preserve cross-source global position order in buffered replay paging"
kind: exec-plan
created_at: 2026-08-12T23:55:34Z
intention: "intention_01kzw6dk7qe1qayx2qdz6vcqfd"
master_plan: "docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md"
---

# Preserve cross-source global position order in buffered replay paging

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A keiro catalog rebuild replays stored events through replay adapters to reconstruct
read-model tables. When a rebuild group has more than one event source (for example three
category sources feeding one group), the runner must apply events in ascending global
position across all sources — that is the documented contract ("multiple categories are
merged by global position", `docs/user/read-models-and-projections.md`), and replay
adapters are allowed to depend on it: an adapter runs arbitrary SQL in the replay
transaction and may read a sibling target that an earlier-positioned event was supposed to
have written already.

Today that contract is broken. The buffered replay pager introduced by
`docs/plans/242-deduplicate-dispatch-and-retry-skeletons-and-fix-rebuild-read-amplification.md`
(commit `d195296f`, "perf(rebuild): buffer replay source pages") refills a source's buffer
only when the buffer is empty. A merged chunk can therefore consume another source's events
*beyond* a partially-consumed source's buffered horizon, committing a high global position
while lower unfetched positions still exist in a sibling source. The run then applies those
lower positions in a *later* transaction — out of order — and still promotes as successful.
No existing guard fires: this is silent read-model corruption in every multi-source rebuild
group whose event interleaving straddles a page boundary the wrong way.

After this plan, the same rebuild provably applies events in strictly ascending global
position across all sources under every paging boundary; a regression of that invariant can
no longer promote silently (the runner fails loudly with a typed invariant error instead);
and the read-amplification win that plan 242 bought (each stored event read exactly once
per rebuild) is retained. You can see it working by running one new integration test that
fails on today's code with the exact out-of-order application sequence `[1,2,3,8,4,7,9]`
and passes with the ascending sequence `[1,2,3,4,7,8,9]` after the fix, plus a seeded
random-interleaving sweep, the existing read-count proof, and the replay paging benchmark.


## Progress

- [x] (2026-08-13T02:22:54Z) Baseline: re-verified the referenced runner and replay-spec
      locations against the current working tree; `cabal build all` succeeded;
      `cabal test keiro-test` passed 508 examples with 0 failures in 106.0253 seconds;
      `cabal bench keiro-bench --benchmark-options="-p rebuild --time-mode wall"` measured
      `rebuild/three-categories-200` at 52.8 ms +/- 5.2 ms before the fix.
- [x] (2026-08-13T02:29:52Z) Milestone 1: added "applies merged multi-source chunks in
      ascending global order across buffer boundaries" to
      `keiro/test/ProjectionReplaySpec.hs`; against the unmodified runner the rebuild
      promoted and the assertion failed exactly with expected `[1,2,3,4,7,8,9]` but got
      `[1,2,3,8,4,7,9]` (1 example, 1 failure in 0.2057 seconds).
- [x] (2026-08-13T02:29:52Z) Milestone 2: implemented the merge-horizon clamp and monotonic
      applied floor in `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`; the focused example
      passed, `cabal build keiro` succeeded, and `cabal test keiro-test` passed all 509
      examples with 0 failures in 101.9082 seconds without edits to pre-existing examples.
- [ ] Milestone 3: deterministic seeded interleaving sweep added and green (all sweep
      cases apply strictly ascending order and promote).
- [ ] Milestone 4: read-count proof re-run and actual call/row counts recorded here;
      rebuild benchmark re-run post-fix and number recorded here next to the pre-fix
      number.
- [ ] Milestone 5: `keiro/CHANGELOG.md` Unreleased entry added;
      `docs/user/read-models-and-projections.md` ordering guarantee sentence added; ADR
      distillation pass done (expected outcome: no ADR change — confirm and record);
      `just verify` green; parent MasterPlan registry row updated to Complete; Outcomes &
      Retrospective written.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Restore ordering with a merge-horizon clamp — a merged chunk never includes
  an event whose global position exceeds the smallest buffered horizon among sources that
  have not proven exhaustion — rather than the alternative of refilling any source whose
  buffer no longer covers the tentative chunk.
  Rationale: refilling a non-empty buffer would require reading from a position *ahead of*
  the persisted source cursor (the buffer holds fetched-but-unapplied events), which
  complicates `readSourcePage` and the expected-cursor compare-and-swap bookkeeping in
  `applyChunkTx`. The clamp is a pure prefix restriction of the already-sorted candidate
  list: it provably preserves the ordering invariant, changes no read (refill policy is
  untouched, so plan 242's read counts are identical), and at worst splits some chunks into
  smaller transactions near horizon boundaries. Soundness and progress arguments are in
  Context and Orientation.
  Date: 2026-08-12
- Decision: Add a monotonic applied-position floor threaded through the paging loop, and
  fail the run with `CatalogRebuildInvariantFailed` (failure code
  `replay.global-position-regression`) if a merged chunk would ever start at or below the
  floor. Also fail loudly (`replay.buffer-horizon-stalled`) if candidates exist but the
  clamp yields an empty chunk, which is impossible unless a refill invariant breaks.
  Rationale: the parent MasterPlan's vision requires that ordering violations never promote
  silently. The floor makes the invariant self-enforcing at runtime — including when
  resuming a run whose persisted cursors were already corrupted by the pre-fix pager, which
  now surfaces as a typed failure instead of compounding corruption.
  Date: 2026-08-12
- Decision: Implement the property-style ordering test as a deterministic seeded
  pseudo-random interleaving sweep at the public-API level (DB-backed hspec examples
  generated from fixed seeds), not as a QuickCheck property over runner internals.
  Rationale: `Keiro.ReadModel.Rebuild.Runner` is an `other-modules` entry in
  `keiro/keiro.cabal` — tests cannot import its internals — and the keiro-test suite has no
  QuickCheck dependency. Fixed seeds keep CI deterministic and reproducible, avoid a new
  dependency, and bound database cost while still covering many adversarial interleavings
  and page sizes.
  Date: 2026-08-12
- Decision: No persisted-format change and no ADR amendment from this plan. The chunking
  policy is runtime control flow; it is not part of the `contract-v3:` preimage
  (`rebuildContract` hashes only the runner format tag and the group slice), so ADR-32's
  mandatory prefix-bump rule is not triggered. The parent MasterPlan assigns ADR-32
  amendments to its EP-2 and EP-3; this plan (EP-1) must not race them.
  Rationale: keep the behavior fix decoupled from persisted-identity changes, exactly why
  the MasterPlan split EP-1 from EP-2. Confirm at the distillation pass; if implementation
  is forced to change anything durable, stop and update ADR-32 in the same change.
  Date: 2026-08-12
- Decision: Commit the red test together with the fix (evidence of the red run is captured
  in this plan), so every commit on the branch keeps CI green.
  Date: 2026-08-12


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository is a multi-package Haskell cabal project. The package that matters here is
`keiro` (the runtime library). All paths below are repository-relative; all line numbers
were verified at commit `3513cf1e` — re-verify before editing, and trust the code over the
numbers if they have drifted.

### How a catalog rebuild works today

An application declares a *projection catalog*: event **sources** (either the whole `$all`
stream or one *category* — the prefix of a stream name before the first `-`, so stream
`orders-1` belongs to category `orders`), physical **targets** (application-owned tables),
**rebuild groups** (sets of targets that move through one rebuild lifecycle atomically),
and projection definitions whose **replay adapters** know how to decode a stored event and
apply it inside a database transaction. Every stored event has a **global position** — a
store-wide, strictly increasing `Int64` assigned at append time (`GlobalPosition` in
`kiroku-store`; positions start at 1).

`startCatalogRebuild` / `resumeCatalogRebuild` in
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` drive a rebuild: they capture a fixed head
position, persist one row per run plus one row per source (cursor, target position,
exhaustion marker) in `keiro.keiro_projection_rebuild_sources`, and then loop in
`driveCatalogRebuild` (Runner.hs lines 356–435). Each loop iteration:

1. **Refills buffers** (`refillSourcePage`, lines 433–435): for each incomplete source
   whose in-memory buffer is *empty*, reads one page of up to `pageSize` events from that
   source's cursor (`readSourcePage`, lines 485–508; the cursor is exclusive — the read
   returns events with position strictly greater than the cursor). The returned
   `SourcePage` records `pageProvesExhaustion :: Bool` — true when the page was short, when
   the read saw an event beyond the run's target position, or when the last eligible event
   *is* the target — meaning the source has no unread events left at or below the target.
2. **Merges** all buffered events from all sources into one ascending list
   (`orderedCandidates`, lines 510–518), and rejects duplicate adjacent positions
   (`duplicatePosition`, lines 520–526).
3. **Takes a chunk**: the first `pageSize` events of the merged list (line 395).
4. **Applies the chunk** in one transaction (`applyChunkTx`, lines 542–651): locks the
   active run, runs every matching replay adapter per event
   (`runCatalogReplayAdapter`, `keiro/src/Keiro/Projection/Catalog.hs` lines 802–812 —
   note the adapter's `applyForReplay` runs arbitrary `Tx.Transaction` SQL), then advances
   each consumed source's persisted cursor with a compare-and-swap
   (`advanceSourceStmt`, lines 1117–1135: `WHERE ... cursor_position = $3` against the
   cursor the page was read at) and marks sources complete when their buffer is fully
   consumed and proves exhaustion.
5. **Advances in-memory buffers** (`advanceSourcePages`, lines 445–480): drops the
   consumed prefix from each buffer, keeps the remainder, and recurses with the incomplete
   sources.

Before commit `d195296f`, step 1 re-read a *full page for every incomplete source on every
iteration*. That was reads-amplified (each event read up to k times for k sources — the
defect plan 242 fixed) but order-safe, for a subtle reason worth spelling out: a fresh full
page from source S contains S's next `pageSize` events. If the merged chunk (also capped at
`pageSize`) were about to include a position `p` beyond S's page, S's page alone would
supply `pageSize` events all smaller than `p`, so the chunk fills up before ever reaching
`p`. And a short page proves exhaustion, so there is nothing unread behind it. A chunk
could therefore never cross an unexhausted source's fetched horizon.

The buffered version broke exactly that property: a *partially consumed* buffer holds fewer
than `pageSize` events without proving exhaustion, so the merged prefix can run past the
buffer's last event while unfetched lower positions still exist behind it.

### The defect, concretely

Take `pageSize = 2`, source A (category `orders`) with events at global positions
`[1,8,9]`, source B (category `customers`) at `[2,3,4,7]` (positions 5 and 6 belong to a
category no source declares, so nobody ever reads them):

- Iteration 1: both buffers empty → refill. A buffers `[1,8]`, B buffers `[2,3]` (both
  full pages, neither proves exhaustion). Merge `[1,2,3,8]`, chunk `[1,2]` commits.
  Buffers now A=`[8]`, B=`[3]`.
- Iteration 2: **neither buffer is empty, so neither refills.** Merge `[3,8]`, chunk
  `[3,8]` commits. Position 8 is now applied while B's unread 4 and 7 — both below 8 —
  are still sitting unfetched in the store.
- Iteration 3: both buffers empty → refill. A buffers `[9]` (short page, proves
  exhaustion), B buffers `[4,7]`. Chunk `[4,7]` commits — positions 4 and 7 are applied
  *after* 8.
- Iteration 4: B refills to `[]` proving exhaustion; chunk `[9]` commits; everything
  completes and the run **promotes as successful**.

Applied order: `1,2,3,8,4,7,9`. Nothing notices:

- `duplicatePosition` only compares adjacent pairs *within the current merge* — there is
  no duplicate, and it never sees positions across iterations.
- `advanceSourceStmt`'s compare-and-swap only detects *external* interference with the
  persisted cursor (another process moving it), not a self-inflicted ordering violation.
- Promotion's completion proof (`completionProofStmt`) counts sources, adapters, and
  verifications; it says nothing about order.

Why it corrupts: replay adapters run arbitrary transactional SQL (`applyForReplay` via
`runCatalogReplayAdapter`). An adapter that reads a sibling target — for example a
denormalizer that joins the current `customers_projection` row while applying an `orders`
event — sees state as of position 8 having been applied before positions 4 and 7, and
persists a wrong derived row. `PreserveAndReconcile` targets and any last-writer-wins or
fold-style projection state have the same exposure. The rebuild reports success.

### The fix: invariant and mechanism

**Chosen invariant (the merge horizon rule).** Define, for each buffered `SourcePage`:

- if `pageProvesExhaustion` is true, the page's *horizon* is the source's
  `targetPosition` (nothing unread remains at or below the target);
- otherwise the horizon is the global position of the **last event in the buffer** (the
  page was read contiguously from the cursor, so every unfetched event of that source is
  strictly above this position). After a refill, a non-exhausted page always has a
  non-empty buffer (a short or empty read proves exhaustion by construction), so this is
  well defined.

The **merge horizon** of an iteration is the minimum horizon over all pages in the loop
(the loop only carries incomplete sources, so the list is non-empty). The rule: *a merged
chunk never includes an event whose global position exceeds the merge horizon.* The chunk
becomes `take pageSize (takeWhile (position ≤ horizon) orderedCandidates)`.

*Soundness:* every event the chunk applies has position ≤ horizon ≤ the last-buffered
position of every non-exhausted source S, and every unfetched event of S is strictly above
S's last-buffered position. So no unfetched event can be below anything the chunk applies —
cross-transaction application order is strictly ascending.

*Progress:* the source attaining the minimum horizon either proves exhaustion (and if all
pages do, all buffered candidates are ≤ their own targets ≥ horizon... in that case the
horizon is the minimum target and the only candidates possibly excluded belong to sources
that have already proven exhaustion — they simply wait for the next iteration after the
minimum-target source completes) or has a non-empty buffer whose events are all ≤ its own
last event = horizon, so the clamped candidate list is non-empty whenever that source has
buffered events. The one legitimately-empty-chunk case that exists today is preserved:
when *all* buffers are empty and prove exhaustion (e.g., a source with zero events), the
merge is empty and the empty-chunk transaction still marks those sources complete. The
impossible case — candidates exist but the clamp empties the chunk — is turned into a loud
`CatalogRebuildInvariantFailed` instead of an infinite loop.

*Read amplification:* the refill policy ("read only when the buffer is empty") is
untouched, so every stored event is still read exactly once per rebuild — plan 242's win is
fully retained. The only possible cost is more, smaller apply transactions where chunks get
clamped. On the exact 3-categories × 6-events / page-size-2 fixture that plan 242 used for
its 11-reads/18-rows proof, hand simulation of the clamped loop gives *identical* read and
row counts (11 calls, 18 rows) and 12 apply transactions instead of 10. On the
`rebuild/three-categories-200` benchmark the three categories occupy disjoint contiguous
position blocks (each stream is seeded with one bulk append), the minimum horizon is always
the active block's frontier, chunks never clamp, and the transaction count is unchanged —
so the 45.9 ms figure plan 242 recorded should hold within noise. Milestone 4 verifies
both instead of trusting this analysis.

**Defense in depth (the applied floor).** Thread a monotonic floor — the greatest global
position applied so far — through the paging loop. On (re)entry from a persisted report
the floor is the maximum `cursorPosition` across *all* the run's sources (each source's
cursor is its own last applied position, so the maximum is the run's last applied position;
on a fresh run all cursors equal `replayFrom`, and the first applied event is strictly
above it because reads are cursor-exclusive). If a chunk's first (smallest) position is ≤
the floor, the runner records failure code `replay.global-position-regression` and returns
`CatalogRebuildInvariantFailed` instead of applying. Combined with in-chunk ascending order
(sorted merge) and the duplicate guard, this makes the whole run's application order
strictly ascending *by construction and by runtime check*. One deliberate behavior change
falls out: resuming a run whose persisted cursors already embody a pre-fix ordering
violation (cursor spread where a lagging source still has unapplied events below another
source's cursor) now fails loudly instead of promoting corrupted state; the recovery is
`abandonCatalogRebuild` plus a fresh rebuild. Since 0.12 is unreleased and the buggy pager
is days old, no released user is affected.

### What this plan must NOT touch

`rebuildContract` and its preimage (Runner.hs lines 826–833, hashing `"contract-v3"` over
the runner format and group slice) are owned by the sibling plan
`docs/plans/247-capture-replay-adapter-application-order-in-the-rebuild-resume-contract.md`,
which soft-depends on this plan. Do not modify `rebuildContract`, the `runnerFormat`
constant, any persisted SQL schema, or the adoption surface in
`keiro/src/Keiro/ReadModel/Rebuild/Group.hs`. Both plans extend
`keiro/test/ProjectionReplaySpec.hs`; add this plan's new examples and helpers at the *end*
of the existing `describe "catalog replay runner"` block and after the existing helper
definitions, to minimize merge friction if plan 247 lands around the same time.

### Relevant ADRs

- `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
  (ADR-32): canonical preimages, slice-scoped rebuild lifecycle identity, and the rule that
  *prefix changes are mandatory when the canonical identity contract changes*. This plan
  changes no preimage and no persisted value, so no prefix bump and no amendment — but if
  implementation drifts into contract territory, stop and follow ADR-32 (that work belongs
  to plan 247).
- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
  (ADR-26): a rebuild group owns the deterministic set of targets that move through one
  lifecycle; the merged multi-source replay this plan fixes is the mechanism that rebuilds
  such a group atomically.
- `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
  (ADR-28) and
  `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
  (ADR-31) were scanned and are not implicated: this plan adds no operator command and does
  not touch checkpoint policy. No cross-repository ADR bears on this plan.

### Provenance of the defect

Introduced by commit `d195296f` ("perf(rebuild): buffer replay source pages") with its
benchmark added by `bbc8a483` ("perf(rebuild): add replay paging benchmark"), both under
plan 242 Milestone 3, which recorded the 3×6/page-2 proof improving from 26 reads/48 rows
to 11 reads/18 rows and the 3×200 benchmark from 61.7 ms ± 2.0 ms to 45.9 ms ± 2.7 ms.
Confirmed by the 2026-08-12 adversarial fix-verification review over `39bc631c..HEAD`; this
plan is EP-1 of the parent MasterPlan
`docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md`.


## Plan of Work

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. The
keiro-test suite provisions its own ephemeral PostgreSQL cluster through
`keiro-test-support` (`withMigratedSuite` builds one migrated template database for the
whole suite; `withFreshStore` clones it per example). Never add per-example migrations —
extend the existing fixture pattern in `keiro/test/ProjectionReplaySpec.hs`.

### Milestone 0 — Baseline evidence

Scope: prove the starting state so post-fix numbers are comparable. Run
`cabal build all`, then `cabal test keiro-test` on unmodified HEAD (expect green), then the
rebuild benchmark on unmodified HEAD and record its mean ± stddev in Progress:

```bash
cabal bench keiro-bench --benchmark-options="-p rebuild --time-mode wall"
```

Benchmark numbers are machine-relative; what matters is the before/after pair measured in
the same session on the same machine, not agreement with plan 242's absolute 45.9 ms.

### Milestone 1 — Red test reproducing the mis-ordering

Scope: one new integration example in `keiro/test/ProjectionReplaySpec.hs` that encodes the
walkthrough from Context and Orientation and fails on today's code. At the end of this
milestone a test exists whose failure output *is* the defect.

The existing fixture already has everything needed: `replayCatalog` declares three category
sources (`orders`, `customers`, `billing`), every applied event inserts its global position
into `app.replay_trace` whose `sequence` identity column records *application order*, and
`tracePositionsStmt` selects positions ordered by that sequence. Reuse them. The `billing`
source gets zero events in this fixture — that is fine and deliberately also exercises the
empty-source completion path. Positions 5 and 6 are occupied by a `padding` category that
no source declares, so the runner never reads them; give those events a payload of
`Aeson.Null` and an event type the decoder ignores.

Add a staggered append helper near the existing `appendInterleaved` (positions in
comments; the store assigns global positions 1..9 in append order):

```haskell
appendStaggered :: Store.KirokuStore -> IO ()
appendStaggered store =
  traverse_
    (appendRaw store)
    [ (StreamName "orders-1", NoStream, EventType "ReplayEvent", Aeson.toJSON (11 :: Int64)), -- pos 1
      (StreamName "customers-1", NoStream, EventType "ReplayEvent", Aeson.toJSON (21 :: Int64)), -- pos 2
      (StreamName "customers-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (22 :: Int64)), -- pos 3
      (StreamName "customers-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (23 :: Int64)), -- pos 4
      (StreamName "padding-1", NoStream, EventType "PaddingEvent", Aeson.Null), -- pos 5 (never read)
      (StreamName "padding-1", AnyVersion, EventType "PaddingEvent", Aeson.Null), -- pos 6 (never read)
      (StreamName "customers-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (24 :: Int64)), -- pos 7
      (StreamName "orders-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (12 :: Int64)), -- pos 8
      (StreamName "orders-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (13 :: Int64)) -- pos 9
    ]
```

And the example, appended at the end of the `describe "catalog replay runner"` block:

```haskell
it "applies merged multi-source chunks in ascending global order across buffer boundaries" $ \store -> do
  expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
  appendStaggered store
  validated <- expectValid (replayCatalog goodDecoder passingVerification)
  _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
  report <-
    expectStore store (startCatalogRebuild validated replayGroupId (options "staggered-run" 2))
      >>= shouldBeRight
  report ^. #runStatus `shouldBe` RebuildRunPromoted
  expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
    `shouldReturn` [1, 2, 3, 4, 7, 8, 9]
```

Acceptance: on unmodified runner code the example fails with the trace assertion — the run
*promotes* (that assertion passes, documenting the silence of the corruption) but the
applied order is wrong:

```text
expected: [1,2,3,4,7,8,9]
 but got: [1,2,3,8,4,7,9]
```

Capture that transcript into Progress. Do not commit yet (the commit pairs with
Milestone 2 so CI stays green).

### Milestone 2 — Merge-horizon clamp and applied floor in the runner

Scope: fix `driveCatalogRebuild` in `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`. At the
end of this milestone the Milestone 1 test is green and the whole suite passes untouched.

Edits, all inside Runner.hs (no export changes, no signature changes to exported
functions):

First, two pure helpers next to `orderedCandidates` (top level, module-private). A page's
horizon and the merge horizon (`GlobalPosition` derives `Ord`, so `Prelude.min`/`max` and
`minimum` work; remember this module imports `Prelude` restrictively and uses
`Prelude.`-qualified names for anything not re-exported by `Keiro.Prelude` — follow the
existing style):

```haskell
pageHorizon :: SourcePage -> GlobalPosition
pageHorizon page
  | page ^. #pageProvesExhaustion = page ^. #pageSource . #targetPosition
  | otherwise =
      case page ^. #pageEvents of
        [] -> page ^. #pageSource . #cursorPosition -- unreachable after refill; keeps the function total
        events -> Prelude.last events ^. #globalPosition

mergeHorizon :: [SourcePage] -> GlobalPosition
mergeHorizon = Prelude.minimum . Prelude.map pageHorizon -- precondition: non-empty (loop carries >=1 incomplete source)
```

Second, change the loop. `go` gains the applied floor as its first argument; the chunk is
clamped; two new failure branches precede the apply; the recursion advances the floor to
the chunk's last (greatest) position:

```haskell
    continueFromReport = \case
      ... -- unchanged cases
        | otherwise ->
            go
              (appliedFloor report)
              [ emptySourcePage source
              | source <- report ^. #sources,
                not (sourceComplete source)
              ]

    appliedFloor report =
      List.foldl'
        Prelude.max
        (GlobalPosition 0)
        [source ^. #cursorPosition | source <- report ^. #sources]

    go appliedThrough buffers = do
      pages <- traverse refillSourcePage buffers
      let ordered = orderedCandidates pages
          horizon = mergeHorizon pages
          eligible = Prelude.takeWhile (\routed -> routed ^. #routedEvent . #globalPosition <= horizon) ordered
          chunk = Prelude.take (Prelude.fromIntegral pageSize) eligible
      case duplicatePosition ordered of
        Just duplicate -> ... -- unchanged
        Nothing
          | Just regressed <- chunkRegression appliedThrough chunk -> do
              let detail =
                    "merged chunk regressed to global position "
                      <> renderPosition regressed
                      <> " at or below applied floor "
                      <> renderPosition appliedThrough
              recordFailure runId "replay.global-position-regression" detail Nothing Nothing (Just regressed)
              Telemetry.recordProjectionRebuildFailures metrics 1
              pure (Left (CatalogRebuildInvariantFailed runId detail))
          | null chunk, not (null ordered) -> do
              let detail = "buffered merge stalled: candidates exist above the merge horizon " <> renderPosition horizon
              recordFailure runId "replay.buffer-horizon-stalled" detail Nothing Nothing Nothing
              Telemetry.recordProjectionRebuildFailures metrics 1
              pure (Left (CatalogRebuildInvariantFailed runId detail))
          | otherwise -> do
              ... -- existing apply path, unchanged except the recursive call:
              -- go (chunkCeiling appliedThrough chunk) incomplete
```

with two more small pure helpers (the chunk is ascending, so its first element is its
minimum and its last its maximum):

```haskell
chunkRegression :: GlobalPosition -> [RoutedEvent] -> Maybe GlobalPosition
chunkRegression appliedThrough = \case
  routed : _
    | routed ^. #routedEvent . #globalPosition <= appliedThrough ->
        Just (routed ^. #routedEvent . #globalPosition)
  _ -> Nothing

chunkCeiling :: GlobalPosition -> [RoutedEvent] -> GlobalPosition
chunkCeiling appliedThrough = \case
  [] -> appliedThrough
  chunk -> Prelude.last chunk ^. #routedEvent . #globalPosition
```

Leave `duplicatePosition` checking the full `ordered` list exactly as it is today (it
catches same-position duplicates across overlapping sources within one merge; cross-chunk
duplicates are now caught by the floor as regressions). Leave `applyChunkTx`,
`advanceSourcePages`, `readSourcePage`, `refillSourcePage`, and every SQL statement
unchanged. The `ChunkInterfered` path already re-reads the report through
`continueFromReport`, which re-derives the floor from persisted cursors — correct as-is.

Acceptance: the Milestone 1 example passes with trace `[1,2,3,4,7,8,9]`;
`cabal test keiro-test` is green with zero edits to any pre-existing example (behavior
preservation for single-source groups and for the existing interleaved fixtures is part of
the proof). Commit test + fix together.

### Milestone 3 — Property-style ordering sweep

Scope: a deterministic seeded sweep of random interleavings and page sizes, asserting the
full ordering contract through the public API. At the end of this milestone, adversarial
interleavings beyond the single walkthrough are pinned in CI forever.

Design (see Decision Log for why not QuickCheck): a nested
`describe "cross-source ordering sweep"` at the end of the spec generates one `it` example
per `(seed, pageSize)` pair — seeds `[1..6]`, page sizes `[1, 2, 3]`, 18 examples, each
with 14 events, each in its own fresh store (the surrounding `around (withFreshStore
fixture)` applies to nested examples). Events are distributed over four categories —
`orders`, `customers`, `billing` (declared sources) and `padding` (never read) — by a
64-bit linear congruential generator written inline (no new dependency; `Data.Word` comes
from `base`):

```haskell
sweepStep :: Word64 -> Word64
sweepStep s = s Prelude.* 6364136223846793005 Prelude.+ 1442695040888963407

sweepCategories :: Word64 -> Int -> [Text]
sweepCategories seed count =
  Prelude.take count
    [ ["orders", "customers", "billing", "padding"] Prelude.!! Prelude.fromIntegral ((s `Prelude.div` 7) `Prelude.mod` 4)
    | s <- Prelude.iterate sweepStep (sweepStep seed)
    ]
```

Each example appends event i (1-based) to stream `<category>-sweep` — the category of a
stream name is its prefix before the first `-`, so `orders-sweep` is category `orders` —
using `NoStream` for the first append to each stream and `AnyVersion` afterwards (track
first-use in a small fold or `Data.Map`), payload `Aeson.toJSON (fromIntegral i :: Int64)`,
event type `ReplayEvent` for the three declared categories and `PaddingEvent` for padding.
Then it registers `replayCatalog goodDecoder passingVerification`, runs
`startCatalogRebuild` with the case's page size, and asserts three things: the run
promoted; the trace equals exactly the ascending list of positions whose generated category
is not `padding` (this asserts both strict ascending application order and completeness —
nothing skipped, nothing duplicated); and every source in the report shows
`exhaustedThrough == Just (GlobalPosition 14)`.

Acceptance: all 18 examples green post-fix. As a sanity check during development, run the
sweep against the pre-fix runner (stash the Milestone 2 change) and record in Surprises &
Discoveries which cases fail — at least some interleavings at page size 2 should reproduce
the defect, demonstrating the sweep has teeth. If suite runtime grows noticeably (the
existing suite runs many similar DB examples; 18 more small ones should cost single-digit
seconds), trim seeds to `[1..4]` and note it in the Decision Log.

### Milestone 4 — Perf evidence: read counts and benchmark

Scope: prove the read-amplification win survived and measure the transaction-count cost.

The existing example "reads each source event once while draining a multi-source rebuild"
(`keiro/test/ProjectionReplaySpec.hs` lines 73–94) already asserts the plan-242 bounds
(3 categories tracked; total rows ≤ 24 for 18 distinct events; per-category read calls
≤ 4). It must still pass **unmodified**. To *record* the actual numbers, temporarily insert
`liftIO (Prelude.print counts)` after the `readIORef reads` line, run the focused example,
copy the printed `StoreReadCounts` into Progress, and remove the print again. Expected from
hand simulation: 11 total category read calls and exactly 18 rows (billing 3 calls/6 rows,
customers 4/6, orders 4/6) — identical to plan 242's recorded post-buffering numbers,
because the clamp changes chunk boundaries, never reads.

Then re-run the benchmark added by commit `bbc8a483`:

```bash
cabal bench keiro-bench --benchmark-options="-p rebuild --time-mode wall"
```

Record mean ± stddev next to the Milestone 0 pre-fix number. Expectation: parity within
noise, because the benchmark seeds each of the three categories as one contiguous
global-position block, so the minimum horizon always sits at the active block's frontier
and no chunk ever clamps. Acceptance: a regression up to ~15% is acceptable and must be
recorded with a short explanation in Surprises & Discoveries; anything larger means the
implementation is clamping where the analysis says it should not — investigate before
proceeding (soundness still wins over speed, but a large regression signals a bug in the
horizon computation, not an inherent cost).

### Milestone 5 — Documentation, changelog, gate, and bookkeeping

Scope: make the guarantee visible to users and close out the plan.

1. `keiro/CHANGELOG.md`, `## Unreleased` → `### Fixed` (top of that subsection): add an
   entry in the file's existing voice, e.g.:

   ```markdown
   - Multi-source catalog rebuilds again apply events in strictly ascending global
     position across sources. The buffered replay pager introduced for 0.12 could let a
     merged chunk overrun a partially-consumed source's buffered horizon and silently
     apply a later position before earlier unfetched ones; chunks are now clamped to the
     smallest buffered horizon among non-exhausted sources, and the runner fails with
     `replay.global-position-regression` / `replay.buffer-horizon-stalled` invariant
     evidence instead of promoting if application order would ever regress. Per-event
     read counts are unchanged.
   ```

2. `docs/user/read-models-and-projections.md`: in the paragraph containing "multiple
   categories are merged by global position" (near line 357), add one or two sentences
   stating the guarantee explicitly — application order is strictly ascending in global
   position across all of a group's sources, replay adapters may rely on it when reading
   sibling targets, and an ordering violation fails the run with recorded invariant
   evidence rather than promoting.
3. ADR distillation pass per the skill's ADR workflow: review this plan's Decision Log and
   Surprises & Discoveries. Expected outcome, already reasoned in the Decision Log: no ADR
   amendment (runtime control flow, no persisted-identity change; ADR-32 amendments belong
   to plans 247/248). Confirm, and record the confirmation in Outcomes & Retrospective. If
   anything durable did change, update the relevant ADR in the same change and run
   `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.
4. Full gate: `just verify` (builds everything, runs every suite including
   `cabal test keiro-migrations-test`, validates ADR/research/capabilities bundles and
   repository policies) must exit 0.
5. Update the parent MasterPlan
   (`docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md`):
   set this plan's registry row Status to Complete and add milestone entries to its
   Progress section. Write this plan's Outcomes & Retrospective.

### Commit and trailer convention

Use Conventional Commits (e.g., `fix(rebuild): preserve cross-source global position order
in buffered replay paging`, `test(rebuild): sweep random interleavings for replay
ordering`, `docs(rebuild): state the cross-source replay ordering guarantee`). Every commit
for this plan carries the trailers:

```text
MasterPlan: docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md
ExecPlan: docs/plans/246-preserve-cross-source-global-position-order-in-buffered-replay-paging.md
Intention: intention_01kzw6dk7qe1qayx2qdz6vcqfd
```

Commit directly to the current branch (no feature branch unless asked). Commit at every
milestone boundary at minimum, updating this plan's Progress in the same commit.


## Concrete Steps

Working directory for everything: `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
# Milestone 0 — baseline
cabal build all
cabal test keiro-test
cabal bench keiro-bench --benchmark-options="-p rebuild --time-mode wall"
```

Expected: build succeeds; suite green; benchmark prints something like

```text
All
  rebuild
    three-categories-200: OK
      46.1 ms ± 2.5 ms
```

Record the exact number in Progress as the pre-fix figure.

```bash
# Milestone 1 — red test (after editing keiro/test/ProjectionReplaySpec.hs)
cabal test keiro-test --test-options='--match "ascending global order"'
```

Expected: 1 example, 1 failure, with

```text
expected: [1,2,3,4,7,8,9]
 but got: [1,2,3,8,4,7,9]
```

If the observed "but got" list differs from `[1,2,3,8,4,7,9]` but is still non-ascending,
the defect is reproduced (record the actual list); if it comes back ascending, stop — the
fixture does not straddle the buffer boundary as designed; re-check the append order
against the walkthrough before proceeding.

```bash
# Milestone 2 — fix (after editing keiro/src/Keiro/ReadModel/Rebuild/Runner.hs)
cabal build keiro
cabal test keiro-test --test-options='--match "ascending global order"'   # now green
cabal test keiro-test                                                     # full suite green
```

```bash
# Milestone 3 — sweep (after adding the sweep block to ProjectionReplaySpec.hs)
cabal test keiro-test --test-options='--match "cross-source ordering sweep"'
cabal test keiro-test
```

Expected: all sweep examples pass; full suite green.

```bash
# Milestone 4 — perf evidence
cabal test keiro-test --test-options='--match "reads each source event once"'
# (temporarily print StoreReadCounts as described in the milestone, record, remove print)
cabal bench keiro-bench --benchmark-options="-p rebuild --time-mode wall"
```

Expected: counting example green with 11 total category read calls / 18 rows recorded;
benchmark within ~15% of the Milestone 0 figure (parity expected).

```bash
# Milestone 5 — gate
just verify
```

Expected: exit 0. Then commit remaining docs/changelog/plan updates with the trailers
above.


## Validation and Acceptance

The change is accepted when all of the following hold, in order:

1. **Defect reproduced then fixed.** The Milestone 1 example fails on unmodified HEAD with
   applied-order trace `[1,2,3,8,4,7,9]` (or another recorded non-ascending order) while
   the run reports `RebuildRunPromoted` — proving silent corruption — and passes after
   Milestone 2 with trace `[1,2,3,4,7,8,9]`. The trace is read from `app.replay_trace`
   ordered by its insertion-order `sequence` column, so it is application order, not
   position order.
2. **No behavioral regression elsewhere.** Every pre-existing example in
   `cabal test keiro-test` passes with zero edits, including the six-event interleaved
   fixtures, decode-failure rollback/resume, verification-failure retention, v2-contract
   refusal, and adapter-row promotion refusal.
3. **Ordering holds under adversarial interleavings.** All sweep examples pass: for every
   `(seed, pageSize)` case the applied trace equals exactly the ascending list of that
   case's non-padding positions and the run promotes with all sources exhausted through
   position 14.
4. **Read-amplification win retained.** The unmodified counting example passes; recorded
   actuals are 11 category read calls and 18 rows (or better) for 3×6 events at page
   size 2 — matching plan 242's post-buffering numbers.
5. **Benchmark recorded.** `rebuild/three-categories-200` pre-fix and post-fix numbers are
   both recorded in Progress; post-fix is within ~15% of pre-fix (expected: parity), or a
   larger delta is investigated and explained.
6. **Loud failure surface exists.** Code inspection confirms the two new failure paths
   record `replay.global-position-regression` / `replay.buffer-horizon-stalled` through the
   existing `recordFailure` machinery (persisted to the run's failure evidence and visible
   in `RebuildRunReport ^. #failureEvidence` and `keiro-ops rebuild inspect`) and return
   the existing `CatalogRebuildInvariantFailed` constructor — no API shape change. (These
   paths are unreachable by construction after the fix; the sweep plus the clamp proof
   stand in for a direct trigger. Do not contort the code to force one.)
7. **Docs and gate.** The changelog entry and user-doc sentence exist; `just verify`
   exits 0.


## Idempotence and Recovery

Every step is safe to repeat. Tests run against per-example fresh databases cloned from the
suite template, so re-running them cannot accumulate state. The benchmark hard-deletes and
re-seeds its streams per invocation and allocates a fresh run id from a counter, so it can
be re-run freely; only same-session comparisons are meaningful. The code change is confined
to one module's internal loop: if a partial edit leaves the build or suite red, `git diff
keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` against the milestone's described end state
shows exactly what is missing, and `git checkout -- keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`
restores the baseline (the red test then fails again, which is the expected recovery
point). No migration, schema, or persisted-format change exists to roll back. If the
Milestone 1 commit pairing is missed and a red test lands alone, either revert it or land
the fix immediately — the repository convention is that every commit keeps `just verify`
green.


## Interfaces and Dependencies

No new package dependencies. No public API change: every exported symbol of
`Keiro.ReadModel.Rebuild` keeps its name, type, and observable success behavior; the only
observable additions are two new `failureCode` string values recorded on runs that hit the
(unreachable-by-construction) invariant paths, reported through the existing
`RebuildFailureEvidence` and `CatalogRebuildInvariantFailed` shapes. No persisted format,
SQL statement, or migration changes. `Keiro.ReadModel.Rebuild.Runner` stays in
`other-modules`.

At the end of Milestone 2 the following module-private, top-level functions exist in
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` with exactly these signatures (they are pure
so their correctness argument is auditable in isolation):

```haskell
pageHorizon :: SourcePage -> GlobalPosition
mergeHorizon :: [SourcePage] -> GlobalPosition   -- precondition: non-empty page list
chunkRegression :: GlobalPosition -> [RoutedEvent] -> Maybe GlobalPosition
chunkCeiling :: GlobalPosition -> [RoutedEvent] -> GlobalPosition
```

and `go` inside `driveCatalogRebuild` has type
`GlobalPosition -> [SourcePage] -> Eff es (Either CatalogRebuildError RebuildRunReport)`
(floor first). Modules touched: `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` (fix),
`keiro/test/ProjectionReplaySpec.hs` (Milestones 1 and 3; new examples and helpers appended
after existing ones), `keiro/CHANGELOG.md` and `docs/user/read-models-and-projections.md`
(Milestone 5). Explicitly out of bounds: `rebuildContract` / `runnerFormat` in Runner.hs
(owned by `docs/plans/247-capture-replay-adapter-application-order-in-the-rebuild-resume-contract.md`),
`keiro/src/Keiro/ReadModel/Rebuild/Group.hs`, `keiro-ops`, and all migrations. Store-read
semantics relied upon (from `kiroku-store`, `Kiroku.Store.Read`): `readCategory` and
`readAllForward` page in ascending global position with an exclusive cursor, and
`readAllBackward (GlobalPosition 0) 1` returns the visible head — all already in use by the
runner today.
