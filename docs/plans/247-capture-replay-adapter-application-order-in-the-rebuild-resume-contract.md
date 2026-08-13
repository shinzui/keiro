---
id: 247
slug: capture-replay-adapter-application-order-in-the-rebuild-resume-contract
title: "Capture replay adapter application order in the rebuild resume contract"
kind: exec-plan
created_at: 2026-08-12T23:55:34Z
intention: "intention_01kzw6dk7qe1qayx2qdz6vcqfd"
master_plan: "docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md"
---

# Capture replay adapter application order in the rebuild resume contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro can rebuild a group of read models by replaying recorded events through "replay
adapters" — one per replayable projection — and it can resume an interrupted rebuild
later. Resuming is only sound when the code that resumes applies adapters in the same
order as the code that started: adapter effects run inside one SQL transaction per event,
and when two projections in the same group observe the same source, swapping their
application order can produce a different final database state whenever their effects
interact (shared tables, triggers, ordering-sensitive inserts).

Today that protection is silently broken. The persisted "resume contract" fingerprint —
the value `resumeCatalogRebuild` compares before continuing an interrupted run — is
derived only from the group's *slice fingerprint*, and the slice fingerprint sorts
projection metadata, so it is deliberately order-free. A deploy that merely swaps the
declaration order of two replayable projections produces a byte-identical contract. An
interrupted run then resumes and applies the remaining events in the *new* order while
the already-applied prefix used the *old* order. The promoted read model can differ from
every from-scratch rebuild, and nothing ever reports it. The retired v1 contract encoding
hashed each adapter's order explicitly and refused exactly this scenario.

After this plan, resuming (a) an interrupted rebuild under a changed adapter application
order fails fast with the existing typed error `CatalogRebuildContractMismatch`, (b) the
same order under an unrelated additive catalog change still resumes, and (c) a
declaration-order swap remains fully compatible with registration and with starting a
fresh rebuild — order is in-flight replay identity, not group identity. You can see it
working by running the new tests in `keiro/test/ProjectionReplaySpec.hs`: the milestone-1
test fails on current `master` (the resume wrongly promotes) and passes after the fix.

This is one of five defects tracked by the parent MasterPlan
(`docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md`,
EP-2 in its registry). It gates the 0.12.0.0 release because the persisted contract
format becomes a compatibility surface at that tag.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-13T03:07:55Z) M1: Add the two-adapter fixture catalog (`pairCatalog`, SQL
      fixture, statements, identifiers) to `keiro/test/ProjectionReplaySpec.hs`.
- [x] (2026-08-13T03:07:55Z) M1: Add the red test "refuses to resume after replay-adapter
      declaration order changes" and record its failing output (resume wrongly returns
      `RebuildRunPromoted`) in this plan.
- [x] (2026-08-13T03:14:22Z) M2: Bump `runnerFormat` to
      `keiro/projection-replay/v4` and extend
      `rebuildContract` to hash the ordered adapter identity sequence under the
      `contract-v4` prefix in `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`.
- [x] (2026-08-13T03:14:22Z) M2: Add `CatalogRebuildSliceMismatch` to
      `CatalogRebuildError` and make
      `abandonCatalogRebuild` compare group slices instead of resume contracts.
- [x] (2026-08-13T03:14:22Z) M2: Update the existing stale-contract test (prefix
      assertion `contract-v3:` →
      `contract-v4:`, description mentions the v4 runner).
- [x] (2026-08-13T03:14:22Z) M2: `cabal build all` and `cabal test keiro-test` pass;
      M1 test is green; commit test + fix.
- [x] (2026-08-13T03:14:22Z) M3: Add the same-order resume-success test for the
      two-adapter fixture.
- [x] (2026-08-13T03:14:22Z) M3: Add the abandon-semantics test (drift refused with
      `CatalogRebuildSliceMismatch`; swapped-order registration and abandon succeed).
- [x] (2026-08-13T03:14:22Z) M3: Add the from-scratch declaration-order
      demonstration test.
- [ ] M4: Amend `docs/adr/0032-...md` (contract-v4, order is contract identity, abandon
      is slice-scoped), advance its timestamp, `okf log add`, strict `okf validate`.
- [ ] M4: Update `docs/user/read-models-and-projections.md` (two v3 mentions) and
      `keiro/CHANGELOG.md` Unreleased.
- [ ] M4: Update the MasterPlan registry row for EP-2 to Complete; run `just verify`;
      write Outcomes & Retrospective; final ADR distillation pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The red order-swap test failed through the intended defect path: both
  catalogs produced the same `slice-v2:8fe434...` slice, the persisted
  `contract-v3:8ce575...` check accepted the swapped declaration order, and resume
  returned `Right RebuildRunReport { runStatus = RebuildRunPromoted }`.
  Evidence: `cabal test keiro-test --test-show-details=direct --test-options='--match
  "refuses to resume after replay-adapter declaration order changes"'` ran one example
  and reported one failure at `ProjectionReplaySpec.hs:198`, with the promoted report
  carrying `keiro/projection-replay/v3`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Encode adapter application order in the resume contract as a `PList` of
  `PRecord "adapter" [PText sourceId, PText projectionId]` nodes in application order,
  with no explicit integer index.
  Rationale: The canonical preimage rendering (ADR-32; `keiro/src/Keiro/Projection/Catalog/Preimage.hs`)
  is a prefix code over trees, so list position is already injectively encoded; adding
  `catalogReplayAdapterOrder` would serialize the same fact twice and create a second
  place for it to disagree. Source id and projection id together are the adapter's
  persisted identity (they key `keiro_projection_rebuild_adapters` rows).
  Date: 2026-08-12
- Decision: Bump both the contract prefix (`contract-v3` → `contract-v4`) and the runner
  format (`keiro/projection-replay/v3` → `keiro/projection-replay/v4`).
  Rationale: ADR-32 makes prefix bumps mandatory when the canonical identity contract
  changes. The runner-format bump follows the precedent set by plans 237 and 244: the
  contract preimage layout is part of the persisted run-evidence format, and the runner
  format string is also the contract preimage's record tag, so both change together.
  Since 0.12 formats are unreleased, this is a clean break with no persisted-value
  migration (same policy plan 237 established for migration 0024).
  Date: 2026-08-12
- Decision: A declaration-order swap refuses *resume only*. The group slice fingerprint
  (`slice-v2`) is not touched, so registration, `beginGroupRebuild`, and adoption all
  continue to treat a reordered catalog as the same group.
  Rationale: Application order only matters to a run that has already applied part of
  history under the old order; a from-scratch rebuild under the new order is
  self-consistent. Making order part of the slice would break the reorder-is-nothing
  guarantee that plan 234 (`docs/plans/234-bind-catalog-read-models-to-one-explicit-physical-target.md`)
  established and ADR-32 codifies ("Reordering owned targets is therefore
  identity-neutral") — an innocuous reorder of a live group must never strand
  registration. The milestone-1 test pins this by asserting the swapped and unswapped
  catalogs produce byte-identical slice fingerprints.
  Date: 2026-08-12
- Decision: `abandonCatalogRebuild` compares group slices (new typed error
  `CatalogRebuildSliceMismatch !RebuildRunId !Text !Text`) instead of resume contracts.
  Rationale: Abandoning applies no adapter effects, so application order is irrelevant to
  its safety; its real precondition is acting on the same group identity, which the slice
  captures and which the underlying `abandonGroupStmt` already fences on. Under the
  current code the contract is a pure function of slice and runner format, so within one
  runtime version contract-equality and slice-equality are the same predicate — meaning
  today an order-swapped catalog *can* abandon its interrupted run. Keeping the abandon
  gate contract-strict after making the contract order-sensitive would silently regress
  that: the refusal to resume would leave a run that can neither resume nor be abandoned
  without redeploying the retired declaration order. Slice-scoped abandon preserves
  today's reachability exactly, still refuses genuine slice drift, and still refuses
  `'$pre-canonical'` sentinel slices (whose supported recovery is plan 248's scope).
  Date: 2026-08-12
- Decision: Restoring an abandoned (`failed`) group to live service is out of scope.
  Rationale: Today no supported API transitions a group out of `failed`
  (`beginGroupRebuild` and `adoptCatalogGroups` both require `live`;
  `abandonGroupRebuild` "deliberately keeps the group fenced" per
  `docs/user/read-models-and-projections.md`). That gap is owned by the MasterPlan's
  EP-3/EP-4 (plans 248/249), which reshape recovery and adoption preconditions. This plan
  only guarantees the abandon itself succeeds and records truthful evidence.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Everything in this section is verifiable against the working tree at commit `3513cf1e`
(current `master` at planning time). Line numbers are anchors, not promises; re-locate by
symbol name if the file has moved.

### The subsystem in plain language

A *projection catalog* is an application's complete declaration of its read-model world:
event sources, physical target tables, projections (the code that turns events into
rows), rebuild groups, and query models. It is validated at startup into a
`ValidatedProjectionCatalog` (`keiro/src/Keiro/Projection/Catalog.hs`).

A *rebuild group* is the unit of coordinated rebuild: a named set of target tables that
are cleared/preserved, replayed, verified, and promoted together. A *replay adapter* is
the replay-capable half of one projection: a decode function plus an apply function that
writes rows inside the replay transaction. `catalogReplayAdapters`
(`keiro/src/Keiro/Projection/Catalog.hs`, near line 1096) collects the group's adapters
**preserving projection-set and definition declaration order** — its Haddock says so
explicitly — and stamps each with `catalogReplayAdapterOrder` 0..n by `List.zipWith
assignOrder [0 ..]` over that declaration order.

The *rebuild runner* (`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`) drives a rebuild: it
captures the store head, pages events per source, merges them in ascending global
position, and applies each event through every adapter registered for that event's
source, **in fleet order** (`applyChunkTx`'s `applyEvents`/`adaptersFor`/`applyAdapters`,
near lines 565–604 — `adaptersFor` filters the fleet list without re-sorting, so fleet
order is declaration order). Progress is persisted in `keiro.keiro_projection_rebuild_runs`
/ `_sources` / `_adapters` / `_verifications`, so a failed or interrupted run can be
resumed later with `resumeCatalogRebuild`.

Three fingerprints protect this lifecycle (all produced by `hashPreimage` over the typed
`Preimage` tree in `keiro/src/Keiro/Projection/Catalog/Preimage.hs`, whose rendering is
an injective prefix code — every text node carries its byte length, every list/record its
child count):

- the *catalog fingerprint* (`catalog-v3:` prefix) — whole-catalog provenance;
- the *group slice fingerprint* (`slice-v2:` prefix) — `groupSliceFingerprint`
  (`Catalog.hs`, near line 984) hashes only the facts that can affect one group;
  registration, begin/finish/abandon fences, and adoption compare this value;
- the *rebuild contract* (`contract-v3:` prefix) — `rebuildContract` (`Runner.hs`, near
  line 826) hashes the runner format plus the slice fingerprint; `resumeCatalogRebuild`
  and `abandonCatalogRebuild` compare the stored `contract_fingerprint` against the
  current catalog's value and refuse with `CatalogRebuildContractMismatch` on any
  difference.

### The defect

`rebuildContract` today is exactly:

```haskell
rebuildContract :: ValidatedProjectionCatalog -> RebuildGroupId -> Maybe Text
rebuildContract catalog groupId = do
  slice <- Catalog.groupSliceFingerprint catalog groupId
  pure
    ( hashPreimage
        "contract-v3"
        (PRecord runnerFormat [PText (groupSliceFingerprintText slice)])
    )
```

The slice covers adapter *identities* but not their *order*: `buildInventory`
(`Catalog.hs`, near line 1850) builds `inventoryProjections = List.sort (map
inventoryProjection facts)`, and the slice preimage consumes that sorted list. So two
catalogs that differ only in the declaration order of two replayable projections have
byte-identical slices — and therefore byte-identical contracts — while
`catalogReplayAdapters` gives them different application orders.

Failure scenario: a group has two replayable projections P1, P2 on one source, declared
`[P1, P2]`. A rebuild applies the first half of history (each event through P1 then P2)
and is interrupted. A redeploy swaps the declaration to `[P2, P1]`.
`resumeCatalogRebuild`'s expected/actual contract check passes, the remaining events are
applied P2-then-P1, and the promoted read model mixes two orders. Whenever the adapters'
effects are order-sensitive, that state differs from any from-scratch rebuild, silently.

### How it regressed

The original runner (commit `8d1b9fe9`, "feat(projections): replay catalog groups
resumably") hashed a per-adapter line `"adapter" | order | sourceId | projectionId` into
the v1 contract, so an order swap refused resume. Plan 237
(`docs/plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md`,
commit `8343bc11`) replaced that ad-hoc encoding with the slice-derived `contract-v2`; its
decision log claims the slice "already canonically covers every replay-relevant fact
(sources with codec fingerprints, adapter identities and order via projections, ...)" —
mistaken for order, because of the `List.sort` above. Plan 244 (commit `99621b90`) bumped
`contract-v2`/`keiro/projection-replay/v2` to v3 without changing the layout. The
2026-08-12 fix-verification review confirmed the regression; this plan is its fix.

### What must NOT change

- The slice preimage (`groupSliceFingerprint`, `buildInventory`, `slice-v2`) — untouched,
  by decision above. Registration comparisons (`registerProjectionCatalogTx`,
  `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`, near line 262) and begin/finish/abandon
  SQL fences already compare slices and stay as they are.
- The paging/merge loop in `Runner.hs` (`go`, `refillSourcePage`, `orderedCandidates`,
  `duplicatePosition`, chunk assembly, `applyChunkTx`'s merge behavior). That code is
  owned by the sibling plan
  `docs/plans/246-preserve-cross-source-global-position-order-in-buffered-replay-paging.md`
  (EP-1). If EP-1 has landed when you implement, rebase and re-run this plan's tests on
  its merged loop; the contract functions this plan owns are disjoint from it.
- The persisted schema. `keiro_projection_rebuild_runs.contract_fingerprint` and
  `runner_format` are plain `text` columns; only the values change. No migration: 0.12
  formats are unreleased and have zero supported persisted rows.

### Relevant ADRs

- `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
  (ADR-32) — canonical preimages, slice-scoped lifecycle identity, the mandatory
  prefix-bump rule, and the current sentence "The persisted runner format is
  `keiro/projection-replay/v3`; its `contract-v3:` value is derived from the group slice
  plus normalized runner facts." **This plan amends it** (Milestone 4) in the same change
  that alters the contract.
- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
  (ADR-26) — the four catalog identities; rebuild groups own the deterministic order of
  their targets. Adapter application order is the analogous deterministic runtime fact
  this plan makes part of in-flight replay identity.
- `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
  (ADR-31) — precedent that replay-safety facts belong in the identities the resume
  contract protects.
- `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
  (ADR-28) — keiro-ops wraps library APIs; this plan changes no operator command surface
  (`keiro-ops rebuild resume|abandon` pass the new errors through transparently).

No cross-repository ADR bears on this plan.

### Sibling-plan interactions (from the MasterPlan)

- EP-1 (plan 246) owns the paging/merge loop; this plan owns `rebuildContract`,
  `runnerFormat`, and the abandon gate. Both extend `keiro/test/ProjectionReplaySpec.hs`;
  whoever lands second rebases tests.
- EP-3 (plan 248) soft-depends on this plan: its recovery semantics for
  `'$pre-canonical'` in-flight runs must be written against the final `contract-v4`
  encoding and the slice-scoped abandon gate defined here. Note for its author: after
  this plan, a `'$pre-canonical'` run is refused by abandon with
  `CatalogRebuildSliceMismatch` (stored slice sentinel never equals a computed
  `slice-v2:` value); this plan deliberately does not invent any sentinel handling.
- MasterPlan 41's plan 256 hard-depends on this plan's pinned adapter order.


## Plan of Work

The work is four milestones: reproduce (red test), fix (contract-v4 + abandon gate),
prove the surrounding guarantees, document (ADR amendment, user docs, changelog, full
gate). All code changes live in two files —
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` and `keiro/test/ProjectionReplaySpec.hs` —
plus documentation files.

### Milestone 1 — reproduce the defect with a failing resume-refusal test

Scope: extend `keiro/test/ProjectionReplaySpec.hs` with a fixture catalog that has two
replayable projections on one source in one group, and a test that interrupts a rebuild
halfway, swaps the declaration order, resumes, and expects
`CatalogRebuildContractMismatch`. On current `master` the resume proceeds to
`RebuildRunPromoted`, so the test fails — that failure, recorded in this plan, is the
reproduction. The test also asserts the swapped and unswapped catalogs have equal slice
fingerprints, which pins the defect mechanism (same slice, so same contract-v3) and later
pins the registration-compatibility decision.

The existing spec (`spec fixture = describe "catalog replay runner" $ around
(withFreshStore fixture) $ ...`) uses the suite-level template-database fixture from
`keiro-test-support` (`Keiro.Test.Postgres`): every example receives a fresh clone of the
migrated template database, and creates its application tables by running a fixture SQL
block at the top of the example. Follow that pattern exactly — do not add per-example
migrations.

Add these definitions after the existing fixture code (identifier style mirrors the
existing `replayCatalog` helpers; all names below are new and must not collide):

```haskell
pairSourceId :: SourceId
pairSourceId = identity mkSourceId "pair-source"

pairTraceTargetId, pairSecondTargetId :: TargetId
pairTraceTargetId = identity mkTargetId "pair-trace"
pairSecondTargetId = identity mkTargetId "pair-second"

pairGroupId :: RebuildGroupId
pairGroupId = identity mkRebuildGroupId "pair-group"

-- | Two replayable projections on one source in one group. @swapped@ flips the
-- declaration order of the two definitions and nothing else.
pairCatalog :: Bool -> ReplayDecoder -> ProjectionCatalog
pairCatalog swapped decoder =
  ProjectionCatalog
    { sources =
        [ SourceDeclaration
            { sourceId = pairSourceId,
              sourceScope = CategorySource (CategoryName "pair"),
              codecFingerprint = "pair-v1",
              claimSite = site "test:source:pair"
            }
        ],
      targets =
        [ TargetDeclaration
            { targetId = pairTraceTargetId,
              qualifiedTable = QualifiedTable "app" "pair_trace",
              resetPolicy = ClearBeforeReplay,
              dependsOn = [],
              claimSite = site "test:target:pair-trace"
            },
          TargetDeclaration
            { targetId = pairSecondTargetId,
              qualifiedTable = QualifiedTable "app" "pair_second",
              resetPolicy = ClearBeforeReplay,
              dependsOn = [],
              claimSite = site "test:target:pair-second"
            }
        ],
      rebuildGroups =
        [ RebuildGroupDeclaration
            { rebuildGroupId = pairGroupId,
              orderedTargets = [pairTraceTargetId, pairSecondTargetId],
              verificationHooks = [],
              claimSite = site "test:pair-group"
            }
        ],
      subscriptions = [],
      dedupKeys = [],
      queryModels = [],
      projectionSets =
        [ SomeProjectionSet
            ProjectionSet
              { projectionSource = pairSourceId,
                projectionDefinitions =
                  if swapped
                    then secondDefinition :| [firstDefinition]
                    else firstDefinition :| [secondDefinition],
                claimSite = site "test:set:pair"
              }
        ]
    }
  where
    firstDefinition = pairDefinition "pair-first" pairTraceTargetId "first"
    secondDefinition = pairDefinition "pair-second" pairSecondTargetId "second"
    pairDefinition projectionName targetId label =
      ProjectionDefinition
        { projectionId = identity mkProjectionId projectionName,
          rebuildGroup = pairGroupId,
          ownedTargets = targetId :| [],
          replayPolicy =
            Replayable
              ReplayAdapter
                { decodeForReplay = decoder,
                  applyForReplay = applyPair label
                },
          handlers =
            InlineHandler
              InlineProjection {name = "live-" <> label, apply = \_ _ -> pure ()}
              (site ("test:handler:" <> label))
              :| [],
          claimSite = site ("test:projection:" <> label)
        }

applyPair :: Text -> ReplayEvent -> RecordedEvent -> Tx.Transaction ()
applyPair label (ReplayEvent value) recorded = do
  let GlobalPosition position = recorded ^. #globalPosition
  Tx.statement (position, label, value) insertPairTraceStmt

appendPairEvents :: Store.KirokuStore -> IO ()
appendPairEvents store =
  traverse_
    (appendRaw store)
    [ (StreamName "pair-1", NoStream, EventType "ReplayEvent", Aeson.toJSON (10 :: Int64)),
      (StreamName "pair-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (20 :: Int64)),
      (StreamName "pair-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (30 :: Int64)),
      (StreamName "pair-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (40 :: Int64))
    ]

pairFixtureSql :: ByteString
pairFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.pair_trace (
    sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    global_position bigint NOT NULL,
    projection text NOT NULL,
    value bigint NOT NULL
  );
  CREATE TABLE app.pair_second (global_position bigint PRIMARY KEY, value bigint NOT NULL);
  """

insertPairTraceStmt :: Statement (Int64, Text, Int64) ()
insertPairTraceStmt =
  preparable
    "INSERT INTO app.pair_trace (global_position, projection, value) VALUES ($1, $2, $3)"
    (contrazip3 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
    D.noResult

pairTraceStmt :: Statement () [(Int64, Text)]
pairTraceStmt =
  preparable
    "SELECT global_position, projection FROM app.pair_trace ORDER BY sequence"
    E.noParams
    (D.rowList ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.text)))
```

Notes for the implementer: `ReplayDecoder`, `goodDecoder`, `failAtThirdPosition`,
`appendRaw`, `options`, `runId`, `site`, `identity`, `expectValid`, `expectStore`, and
`shouldBeRight` already exist in this spec file; reuse them. The shared trace table
records `(global_position, projection)` in an identity-sequence column, so the row order
is the exact application order. A fresh example database means the four appended events
land at global positions 1–4. Both definitions share one decoder value; that is fine —
adapter *functions* are not part of any fingerprint, only identities are (the existing
"rolls a failed chunk back and resumes the exact contract" test already relies on this).
One category source with two projections does not trip the `AmbiguousSourceOrdering`
validation (that rule only forbids mixing an all-stream source with category sources).

Then add the red test inside the `describe` block:

```haskell
it "refuses to resume after replay-adapter declaration order changes" $ \store -> do
  expectStore store (Store.runTransaction (Tx.sql pairFixtureSql))
  appendPairEvents store
  interrupted <- expectValid (pairCatalog False failAtThirdPosition)
  _ <- expectStore store (registerProjectionCatalog interrupted) >>= shouldBeRight
  first <- expectStore store (startCatalogRebuild interrupted pairGroupId (options "order-swap-run" 2))
  first `shouldSatisfy` \case
    Left CatalogRebuildDecodeFailed {} -> True
    _ -> False
  expectStore store (Store.runTransaction (Tx.statement () pairTraceStmt))
    `shouldReturn` [(1, "first"), (1, "second"), (2, "first"), (2, "second")]

  swapped <- expectValid (pairCatalog True goodDecoder)
  CatalogApi.groupSliceFingerprint swapped pairGroupId
    `shouldBe` CatalogApi.groupSliceFingerprint interrupted pairGroupId
  resumeResult <-
    expectStore store (resumeCatalogRebuild swapped (runId "order-swap-run") (options "ignored" 2))
  resumeResult `shouldSatisfy` \case
    Left (CatalogRebuildContractMismatch mismatchedRun expected actual) ->
      mismatchedRun
        == runId "order-swap-run"
        && Text.isPrefixOf "contract-v4:" expected
        && Text.isPrefixOf "contract-v4:" actual
        && expected /= actual
    _ -> False
```

Mechanics of the interruption: page size 2 means chunk one is positions 1–2 (committed:
each event applied first-then-second, hence the four trace rows), and chunk two hits the
injected decode failure at position 3, rolling back and marking the run failed with the
cursor at position 2. The swap then flips application order for the remaining history.

Acceptance for this milestone is the test *failing* with the resume wrongly succeeding.
Expected shape of the failure (`predicate failed on: Right ...` with
`runStatus = RebuildRunPromoted`):

```text
  1) catalog replay runner refuses to resume after replay-adapter declaration order changes
       predicate failed on: Right (RebuildRunReport {rebuildRunId = ..., runStatus = RebuildRunPromoted, ...})
```

Record the actual output in this plan (Surprises & Discoveries if it deviates). Commit
the red test together with Milestone 2's fix so no commit leaves the suite red; the red
transcript in this plan is the reproduction evidence.

### Milestone 2 — fix: contract-v4 with the ordered adapter identity sequence, slice-scoped abandon

Scope: all edits in `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`, plus one existing-test
update. At the end, the Milestone 1 test passes, every other test still passes, and an
interrupted run can still be abandoned under the swapped catalog.

Edit 1 — bump the runner format (near line 88):

```haskell
runnerFormat :: Text
runnerFormat = "keiro/projection-replay/v4"
```

Edit 2 — extend `rebuildContract` (near line 826) to hash the ordered adapter identity
sequence and bump the prefix:

```haskell
rebuildContract :: ValidatedProjectionCatalog -> RebuildGroupId -> Maybe Text
rebuildContract catalog groupId = do
  slice <- Catalog.groupSliceFingerprint catalog groupId
  pure
    ( hashPreimage
        "contract-v4"
        ( PRecord
            runnerFormat
            [ PText (groupSliceFingerprintText slice),
              PList
                [ PRecord
                    "adapter"
                    [ PText (sourceIdText (catalogReplayAdapterSourceId adapter)),
                      PText (projectionIdText (catalogReplayAdapterProjectionId adapter))
                    ]
                | adapter <- catalogReplayAdapters catalog groupId
                ]
            ]
        )
    )
```

Every symbol used here is already imported in `Runner.hs` (`Preimage (..)` brings
`PList`/`PRecord`/`PText`; `catalogReplayAdapters`, `catalogReplayAdapterSourceId`,
`catalogReplayAdapterProjectionId`, `sourceIdText`, `projectionIdText` are in the
existing import list). Do not re-encode sources or verifications — they are already
inside the slice; the adapter list adds only the one missing fact, order. The `PList`
position is the application order (see Decision Log for why no integer index). An empty
adapter list (a group with no replayable projections) renders as `l0:` and stays
injective.

Edit 3 — add the slice-mismatch error and make abandon slice-scoped. In
`CatalogRebuildError` (near line 106), add a constructor directly after
`CatalogRebuildContractMismatch`:

```haskell
  | CatalogRebuildSliceMismatch !RebuildRunId !Text !Text
```

(first `Text` = the stored run slice, second = the current catalog's slice — same
stored-then-current convention as `CatalogRebuildContractMismatch`). The constructor is
exported automatically through `CatalogRebuildError (..)`, which
`keiro/src/Keiro/ReadModel/Rebuild.hs` and `keiro/src/Keiro/Projection/Catalog/Operations.hs`
re-export; no other module pattern-matches this type exhaustively (verified by grep), so
nothing else breaks.

Then rewrite the guard inside `abandonCatalogRebuild` (near line 318): instead of
computing `rebuildContract` and comparing against `report ^. #contractFingerprint`,
compare slices:

```haskell
abandonCatalogRebuild catalog runId failure =
  inspectCatalogRebuildMaybe runId >>= \case
    Nothing -> pure (Left (CatalogRebuildRunNotFound runId))
    Just report -> do
      let groupId = report ^. #rebuildGroupId
          stored = report ^. #groupSliceFingerprint
      case groupSliceFingerprintText <$> Catalog.groupSliceFingerprint catalog groupId of
        Nothing -> pure (Left (CatalogRebuildGroupMissing groupId))
        Just current ->
          if stored /= current
            then pure (Left (CatalogRebuildSliceMismatch runId stored current))
            else case groupRebuildHandleFor catalog groupId runId of
              ...unchanged from here on...
```

`groupSliceFingerprintText` is already imported; `Catalog.groupSliceFingerprint` is
reachable through the existing `Keiro.Projection.Catalog qualified as Catalog` import.
`resumeCatalogRebuild` keeps its contract comparison unchanged — the new preimage flows
through it automatically.

Edit 4 — update the existing stale-contract test in
`keiro/test/ProjectionReplaySpec.hs`: the test currently named "refuses to resume an
active v2 replay contract under the v3 runner" (near line 209) asserts
`Text.isPrefixOf "contract-v3:" actual`; change that to `"contract-v4:"` and rename the
test to "refuses to resume a stale replay contract under the v4 runner". The manually
planted `contract-v2:` fingerprint and `keiro/projection-replay/v2` runner format in that
test stay as they are — they exercise exactly the stale-format refusal ADR-32 documents.

Nothing else needs touching: `initializeRunTx` inserts `runnerFormat` and the contract
text through existing parameters; `resumeRunStmt`, `lockActiveRunStmt`, and
`completionProofStmt` compare the contract as an opaque string. Check for any other
`contract-v3` literal before committing:

```bash
grep -rn "contract-v3" --include='*.hs' keiro keiro-ops keiro-dsl jitsurei | grep -v dist-newstyle
```

Expected: no hits in source after this milestone (documentation hits are Milestone 4).

Acceptance: `cabal build all` succeeds; `cabal test keiro-test` is green including the
Milestone 1 test; the existing tests "rolls a failed chunk back and resumes the exact
contract without duplicate writes" (same order resumes fine) and "retains committed
pages across verification failure and rejects catalog drift on resume" (unrelated
additive source still resumes; codec drift still refuses — slice drift implies contract
drift because the slice is inside the preimage) pass unchanged.

### Milestone 3 — prove the surrounding guarantees

Scope: three more tests in `keiro/test/ProjectionReplaySpec.hs`, all green from the
start, pinning the decisions a future reader must be able to trust.

Test A — same order still resumes (the fix does not over-refuse, and adapter functions
stay outside the contract):

```haskell
it "resumes an interrupted two-adapter rebuild when declaration order is unchanged" $ \store -> do
  expectStore store (Store.runTransaction (Tx.sql pairFixtureSql))
  appendPairEvents store
  interrupted <- expectValid (pairCatalog False failAtThirdPosition)
  _ <- expectStore store (registerProjectionCatalog interrupted) >>= shouldBeRight
  _ <- expectStore store (startCatalogRebuild interrupted pairGroupId (options "order-keep-run" 2))
  repaired <- expectValid (pairCatalog False goodDecoder)
  resumed <-
    expectStore store (resumeCatalogRebuild repaired (runId "order-keep-run") (options "ignored" 2))
      >>= shouldBeRight
  resumed ^. #runStatus `shouldBe` RebuildRunPromoted
  expectStore store (Store.runTransaction (Tx.statement () pairTraceStmt))
    `shouldReturn` [ (position, label)
                   | position <- [1 .. 4],
                     label <- ["first", "second"]
                   ]
```

Test B — a declaration-order swap stays registration-compatible and abandonable, while
genuine slice drift refuses abandon with the new typed error:

```haskell
it "keeps an order swap registration-compatible and abandonable but refuses drifted abandon" $ \store -> do
  expectStore store (Store.runTransaction (Tx.sql pairFixtureSql))
  appendPairEvents store
  interrupted <- expectValid (pairCatalog False failAtThirdPosition)
  _ <- expectStore store (registerProjectionCatalog interrupted) >>= shouldBeRight
  _ <- expectStore store (startCatalogRebuild interrupted pairGroupId (options "order-abandon-run" 2))

  drifted <-
    expectValid
      ((pairCatalog True goodDecoder) & #sources . ix 0 . #codecFingerprint .~ "pair-v2")
  driftedAbandon <-
    expectStore
      store
      (abandonCatalogRebuild drifted (runId "order-abandon-run") (RebuildFailure "operator.abandoned" "drift probe"))
  driftedAbandon `shouldSatisfy` \case
    Left CatalogRebuildSliceMismatch {} -> True
    _ -> False

  swapped <- expectValid (pairCatalog True goodDecoder)
  _ <- expectStore store (registerProjectionCatalog swapped) >>= shouldBeRight
  abandoned <-
    expectStore
      store
      (abandonCatalogRebuild swapped (runId "order-abandon-run") (RebuildFailure "operator.abandoned" "declaration order changed"))
      >>= shouldBeRight
  abandoned ^. #runStatus `shouldBe` RebuildRunFailed
  group <- expectStore store (lookupProjectionRebuildGroup pairGroupId)
  group ^? _Just . #status `shouldBe` Just GroupFailed
```

(Re-registering the swapped catalog while the group is `rebuilding` succeeds because
registration only compares slice fingerprints — that is the reorder-is-nothing guarantee
at the registration boundary. The abandon leaves the group fenced in `failed`; restoring
it to service is plan 248/249 territory, per the Decision Log.)

Test C — the from-scratch demonstration of *why* resume must refuse: application order is
an observable effect order.

```haskell
it "applies replay-adapter effects in declaration order" $ \store -> do
  expectStore store (Store.runTransaction (Tx.sql pairFixtureSql))
  appendPairEvents store
  swapped <- expectValid (pairCatalog True goodDecoder)
  _ <- expectStore store (registerProjectionCatalog swapped) >>= shouldBeRight
  report <-
    expectStore store (startCatalogRebuild swapped pairGroupId (options "order-scratch-run" 2))
      >>= shouldBeRight
  report ^. #runStatus `shouldBe` RebuildRunPromoted
  expectStore store (Store.runTransaction (Tx.statement () pairTraceStmt))
    `shouldReturn` [ (position, label)
                   | position <- [1 .. 4],
                     label <- ["second", "first"]
                   ]
```

Together with Test A's `first`-before-`second` trace this proves the two orders produce
observably different row sequences — the exact class of divergence the resume refusal
prevents from being mixed inside one promoted run.

Acceptance: `cabal test keiro-test` green with all four new tests listed in the output.

### Milestone 4 — documentation, ADR amendment, changelog, full gate

Scope: make the durable record match the new contract, then run the repository gate.

ADR amendment. Edit
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`:

- In the Decision section, replace the sentence "The persisted runner format is
  `keiro/projection-replay/v3`; its `contract-v3:` value is derived from the group slice
  plus normalized runner facts." with prose stating: the persisted runner format is
  `keiro/projection-replay/v4`; its `contract-v4:` value is derived from the group slice,
  the runner format, and the ordered replay-adapter identity sequence (source id and
  projection id in application order). State explicitly that application order is
  deliberately excluded from the group slice — reordering projection declarations keeps
  registration and group identity — but refuses resume of an interrupted run, because
  the already-applied prefix used the retired order; and that abandoning a run requires
  only group-slice identity, because abandonment applies no adapter effects.
- Extend the identity-cutover paragraph (the one describing the v3/v2 cutover) with the
  v4 revision: stored `contract-v3:` values and `keiro/projection-replay/v3` runs are
  refused on resume by the v4 runner; since the 0.12 formats are unreleased there is no
  migration, and a run that somehow persists across the break is completed with the old
  runtime or abandoned (abandon compares slices, so it survives the contract break when
  the catalog itself is unchanged).
- Add a Consequences bullet: replay-adapter application order is in-flight replay
  identity, not group identity; order swaps never strand registration but always refuse
  resume.
- Advance the frontmatter `timestamp` to the implementation date and keep `docId: ADR-32`
  and all other producer-owned frontmatter stable.

The ADR bundle is profile-governed (`docs/adr/profile.dhall`, reserved `log.md`), so
after editing run, from the repository root:

```bash
okf log add docs/adr
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

(If `okf log add` requires an entry message in this repository's convention, follow the
existing entries in `docs/adr/log.md`.)

User documentation. In `docs/user/read-models-and-projections.md`:

- Near line 276 ("Before crossing an identity or runner format boundary..."): update the
  runner-format example to cover v4 (an active `keiro/projection-replay/v3` run cannot
  resume under the v4 runner) and add one sentence that changing only the declaration
  order of a group's replayable projections refuses resume of an interrupted run but
  never refuses registration or a fresh rebuild, and that such a run can still be
  abandoned under the reordered catalog.
- Near line 380 ("The default page size is 500 and the persisted format is..."): change
  `keiro/projection-replay/v3` / `contract-v3:` to v4 forms and state that the contract
  covers the group slice plus the ordered adapter identity sequence.

Changelog. In `keiro/CHANGELOG.md` under `## Unreleased`:

- Under `### Breaking Changes` (the section that already documents "Canonical identity
  advances to `catalog-v3:` ..."), add: the rebuild resume contract advances to
  `contract-v4:` and the persisted runner format to `keiro/projection-replay/v4`; the
  contract now pins replay-adapter application order; `CatalogRebuildError` gains
  `CatalogRebuildSliceMismatch`; `abandonCatalogRebuild` compares group slices rather
  than resume contracts.
- Under `### Fixed`, add: resuming an interrupted catalog rebuild after a deploy that
  reorders a group's replayable projection declarations now refuses with
  `CatalogRebuildContractMismatch` instead of silently applying the remaining history in
  the new order.

Finally: update the parent MasterPlan's Exec-Plan Registry row for EP-2 to Complete,
bring this plan's Progress/Decision Log/Outcomes up to date, perform the ADR
distillation pass (the durable judgment — order is contract identity, abandon is
slice-scoped — lands in ADR-32 as above; execution details stay here), and run the full
gate:

```bash
just verify
```


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. The
DB-backed suite provisions its own ephemeral PostgreSQL through `keiro-test-support`; no
external database setup is needed.

Milestone 1 (red):

```bash
cabal build all
cabal test keiro-test --test-show-details=direct \
  --test-options='--match "refuses to resume after replay-adapter declaration order changes"'
```

Expected now (the reproduction — the resume wrongly promotes):

```text
Failures:

  test/ProjectionReplaySpec.hs:NNN:
  1) catalog replay runner refuses to resume after replay-adapter declaration order changes
       predicate failed on: Right (RebuildRunReport {..., runStatus = RebuildRunPromoted, ...})

1 example, 1 failure
```

Milestone 2 (green):

```bash
cabal build all
cabal test keiro-test --test-show-details=direct
grep -rn "contract-v3" --include='*.hs' keiro keiro-ops keiro-dsl jitsurei | grep -v dist-newstyle
```

Expected: all examples pass (including the renamed "refuses to resume a stale replay
contract under the v4 runner"); the grep prints nothing.

Milestone 3:

```bash
cabal test keiro-test --test-show-details=direct --test-options='--match "catalog replay runner"'
```

Expected: the whole replay-runner group passes, including the three new tests.

Milestone 4:

```bash
okf log add docs/adr
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

Expected: `okf validate` reports success; `just verify` (build, all test suites, ADR and
policy checks) completes without failure.

Commit and trailer convention: use Conventional Commits (`test(rebuild): ...`,
`fix(rebuild)!: ...`, `docs(adr): ...` as appropriate — the contract change is a breaking
format change, so the fix commit carries `!`), and include on every commit the trailers:

```text
MasterPlan: docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md
ExecPlan: docs/plans/247-capture-replay-adapter-application-order-in-the-rebuild-resume-contract.md
Intention: intention_01kzw6dk7qe1qayx2qdz6vcqfd
```


## Validation and Acceptance

Acceptance is behavioral, verified through the test suite and documents:

1. Resume refusal (the defect, fixed): with a two-projection group interrupted at
   position 2 of 4, validating a catalog identical except for swapped declaration order
   and calling `resumeCatalogRebuild` returns
   `Left (CatalogRebuildContractMismatch runId expected actual)` where both texts carry
   the `contract-v4:` prefix and differ. Before Milestone 2 the same call returns
   `Right` with `runStatus = RebuildRunPromoted` — the recorded red run proves the test
   detects the defect.
2. Order-free facts stay order-free: the same swapped catalog produces a byte-identical
   `groupSliceFingerprint` (asserted in the red test), re-registers without drift, and —
   from scratch — rebuilds to promotion with the trace showing `second` before `first`
   at every position, while the unswapped catalog shows `first` before `second`.
3. No over-refusal: resuming the interrupted run with the *same* declaration order (and a
   repaired decoder) promotes, and the trace holds exactly the eight rows
   (1,first),(1,second),...,(4,first),(4,second) with no duplicates.
4. Abandon semantics: abandoning the interrupted run under the swapped catalog succeeds
   (run `RebuildRunFailed`, group `GroupFailed` with the operator's failure evidence);
   abandoning under a catalog whose source codec fingerprint changed returns
   `Left (CatalogRebuildSliceMismatch ...)`.
5. Stale formats stay refused: the pre-existing test plants a `contract-v2:` fingerprint
   and asserts the v4 runner refuses it with a `contract-v4:` actual value.
6. Documents: ADR-32 describes contract-v4 and the order/slice split; the user guide's
   two runner-format passages say v4; `keiro/CHANGELOG.md` Unreleased carries the
   Breaking Changes and Fixed entries; `okf validate ... --strict` passes; `just verify`
   passes.


## Idempotence and Recovery

Every step is safe to repeat. Test runs are hermetic (fresh template-clone database per
example; the ephemeral server is torn down with the suite). The code edits are plain text
changes; re-running `cabal build all`/`cabal test` after a partial edit simply reports
compile errors to finish fixing. If Milestone 2 is interrupted midway, the tree may have
a `contract-v4` prefix without the adapter list (or vice versa) — the Milestone 1 test
and the grep in Concrete Steps pinpoint the remaining half; there is no persisted state
anywhere to clean up because only test databases ever hold these fingerprints. If the
sibling plan 246 lands mid-implementation, rebase; conflicts can only appear in
`ProjectionReplaySpec.hs` (test additions are append-only, keep both) — the production
functions each plan touches are disjoint. The ADR edit is recoverable by re-running the
strict `okf validate` command until it passes; `okf log add` appends, so run it once per
meaningful ADR revision, not per attempt.


## Interfaces and Dependencies

No new packages and no schema changes. All production edits are in
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`; all test edits in
`keiro/test/ProjectionReplaySpec.hs` (suite `keiro-test` in `keiro/keiro.cabal`,
database-backed through `keiro-test-support`'s `Keiro.Test.Postgres` template fixture).

At the end of Milestone 2 the following must hold in
`Keiro.ReadModel.Rebuild.Runner` (module is `OPTIONS_HADDOCK hide`; its public surface is
re-exported via `Keiro.ReadModel.Rebuild` and `Keiro.Projection.Catalog.Operations`):

```haskell
runnerFormat :: Text                -- "keiro/projection-replay/v4"

rebuildContract :: ValidatedProjectionCatalog -> RebuildGroupId -> Maybe Text
-- Just ("contract-v4:" <> hex) hashing:
--   PRecord runnerFormat
--     [ PText sliceFingerprintText
--     , PList [ PRecord "adapter" [PText sourceId, PText projectionId]
--             | adapter in application order (catalogReplayAdapters) ] ]

data CatalogRebuildError
  = ...
  | CatalogRebuildContractMismatch !RebuildRunId !Text !Text  -- unchanged; resume path
  | CatalogRebuildSliceMismatch !RebuildRunId !Text !Text     -- new; abandon path
  | ...
```

`resumeCatalogRebuild` keeps comparing `contractFingerprint` (stored) against
`rebuildContract` (current). `abandonCatalogRebuild` compares
`report ^. #groupSliceFingerprint` (stored) against
`groupSliceFingerprintText <$> Catalog.groupSliceFingerprint catalog groupId` (current).

Depended-on functions that must not change under this plan (owned elsewhere or
deliberately frozen): `Keiro.Projection.Catalog.catalogReplayAdapters` (declaration-order
fleet, orders 0..n), `Keiro.Projection.Catalog.groupSliceFingerprint` (`slice-v2`,
order-free projections), `Keiro.Projection.Catalog.Preimage.hashPreimage`/`Preimage`
(injective rendering), the paging/merge loop in `Runner.hs` (plan 246), and the group
lifecycle SQL in `Keiro.ReadModel.Rebuild.Group` (slice-fenced begin/finish/abandon).
