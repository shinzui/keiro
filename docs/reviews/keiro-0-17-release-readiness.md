---
type: Review
title: Keiro 0.17.0.0 release readiness
description: The 0.16.0.0 to HEAD increment's runtime, PGMQ, and DSL changes are correct and their measured costs stay within the approved guards, but the verify gate fails three ways at HEAD, the mandatory 0.16 to 0.17 upgrade edge does not exist, the changelogs omit shipped and breaking surfaces, the user reference documents a DLQ purge the release now refuses, and fifo-heads silently widens the published languages.
generated:
  by: process:claude-code
  at: "2026-09-16T18:16:03Z"
reviewId: REV-17
subject: mori://shinzui/keiro
subjectKind: project
reviewedSha: fa6b66b26a4d647e9f34a7919292e34e764291e9
coverage: incremental
baseSha: 2da45585b901271d4ac19af4acf3de790c394540
previousReview: REV-16
reviewedAt: "2026-09-16T18:16:03Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5-1
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - performance
  - design
  - test-coverage
  - documentation
  - operability
context: >-
  Reviewed the 86 commits between the keiro-0.16.0.0 tag and HEAD for
  correctness, regressions, API-contract soundness, and performance against the
  measured evidence, and then the release surface against the repository
  release procedure. The runtime (process-manager reactions, deterministic
  producer outbox identity, delegated inbox intake, transactional timer
  cancellation), keiro-pgmq (FIFO consumption contracts, DLQ header
  preservation and guarded purge, partition validation, pgmq-hs 0.6), keiro-ops,
  keiro-core, and keiro-test-support were read in full by this reviewer; the
  keiro-dsl increment (Language 6 candidate reactions and delegated intake,
  transition-family guard diffs, fifo-heads) was reviewed by a delegated
  reviewer whose findings were re-verified where they affect the verdict. The
  reverted 0.17.0.0 attempt (250d3007) was checked to be an exact restoration.
  This record continues the chain from REV-16.
---

# Keiro 0.17.0.0 release readiness

## Release verdict

Changes requested. The shipped code is sound: every runtime, PGMQ, and DSL
surface that changed since 0.16.0.0 was read against its stated contract, the
invariants it relies on were checked in the store, the published adapter, and
the schema, and no correctness regression on a pre-existing path was found. The
measured performance costs (about 3% on deterministic producer writes, under 1%
delegated wrapper overhead) are within the guards the plans approved, no
historical benchmark baseline row was rewritten, and no unmeasured hot path
changed. What is not ready is the release gate and the release surface.
`just verify` fails three separate ways at HEAD: two unchanged `keiro-dsl`
tests select `keiki` by package name while the Cabal store holds two builds
of `keiki-0.9.1.0`; the record-migration manifests were not regenerated after
the last two commits touched `Scaffold.hs`; and five frozen Language 4 corpus
files were hand-edited with a trailing newline the generator does not emit.
On the release surface, the mandatory 0.16 to 0.17 consumer upgrade edge does
not exist, the root changelog omits several shipped surfaces, the `keiro-dsl`
changelog omits its public API breaks, the user reference still documents a
DLQ workflow that the new guarded purge refuses, two package changelogs are
wrong about their own packages, and `ordering fifo-heads` silently widens the
published Language 4 and 5 grammars. Tags and Hackage uploads are
irreversible, so all of these must land first.

## Required before tagging

1. **Make the gate pass, then rerun it in full.** `just verify` exited 1 at the
   reviewed commit, and running the steps it skipped one by one exposed three
   independent failures. Every other step passes.
   - *Two `keiro-dsl-test` examples cannot resolve `keiki`.* `keiro-dsl-test`
     reports 743 examples, 2 failures, both `Ambiguous module name
     'Keiki.Shape' ... found in multiple packages: keiki-0.9.1.0
     keiki-0.9.1.0`, from `keiro-dsl/test/Main.hs:2996` ("keeps the raw
     constructor outside the compiled public module surface") and `:9002`
     ("fresh binding skeletons compile at the application boundary"). Both
     shell out to `cabal exec --enable-tests -- ghc ... -package keiki`, and
     the environment `cabal exec` writes exposes the whole store
     `package.db`. The store holds two `keiki-0.9.1.0` units
     (`kk-0.9.1.0-28a60311`, which the install plan uses, and
     `kk-0.9.1.0-0e5dc76b`, built against different `sbv`, `profunctors`,
     `nothunks`, and `cryptohash-sha256` hashes), so selecting by name is
     ambiguous while selecting by id is not. The tests, their invocation, and
     the store state are all outside this cycle's diff, so this is a gate
     fragility rather than a code regression. Fix the two tests to pass
     `-package-id` from the existing `activeCabalPackageId "keiki"` helper,
     which the same tests already use for `keiro-core`. Deleting the stale
     store unit would also make the gate pass today, but not the next time a
     stray solve adds one.
   - *The record migration manifests are stale.* `record-migration-policy`
     fails with `stale record migration manifest:
     keiro-dsl/record-field-migration-0.15.md`. Regenerating shows only
     source line numbers moving (`Scaffold.hs:7409` to `:7410` and so on)
     because da5e2469 edited `Scaffold.hs` after the last
     regeneration at 987f8f92; the same run also rewrites
     `keiro-dsl/generated-haskell-edition-idiomatic-v2.md` (field-label count
     14,462 to 14,464 and the hand-owned `WorkqueueJob.hs` rows that gained
     `jobOrdering`). Run `python3 scripts/generate-record-migration-manifests.py`
     and commit both files.
   - *Five frozen Language 4 corpus files drift from the generator.*
     `conformance-corpus-policy` fails after regenerating
     `QueuePolicy.hs` in `conformance-queue`, `conformance-queue-runtime`,
     `conformance-dispatch-full`, `conformance-mapped-queue`, and
     `conformance-projection-catalog`. da5e2469 edited those committed files
     by hand and left each with a trailing newline that the generator does
     not emit, so every diff is exactly `\ No newline at end of file`. Rerun
     `just corpus-regen` and commit the result; the policy refuses an
     uncommitted corpus, so this must be committed before the gate can pass.
     Note that the same commit changed the comment text the generator emits
     into these Language 4 files, which is a comment-only but real change to
     frozen generated output that the changelog's "Published Languages 1
     through 5 ... remain unchanged" does not admit.
   After all three, rerun `just verify` from a clean tree and check the exit
   status inside the log.
2. **Write the `0.16.0.0 -> 0.17.0.0` blueprint edge.**
   `blueprints/keiro-upgrade/blueprint.dhall` still ends at `0.15 -> 0.16`, and
   the edge the reverted 763a4fec had written described a different release.
   This release forces source changes on every consumer of the affected
   surfaces, which is exactly the release procedure's condition for an edge:
   `Keiro.PGMQ.Job.Job` gains the required `jobOrdering` field, explicit
   tuning must match it, and `FifoThroughput`/`FifoRoundRobin` with a batch
   size above one now throws `JobConsumptionConfigError` at processor
   construction or the first one-shot read; `enqueueProducerEventTx` takes a
   `RecordedEvent` and `Word32` emission index, is a pure transaction, returns
   `ProducerEnqueueOutcome`, and changes the message-id format from TypeID to
   `<namespace>_v1_<sha256-hex>`, so an existing producer must drain and keep
   its checkpoint per ADR-42; `purgeDlq` returns `PurgeDlqResult` and refuses
   after inspection; `DlqEntry` gains `originalHeaders`; the re-exported
   `QueueMetrics` gains `defaultPartitionLength`; `KeiroMetrics` gains
   `outboxIdentityConflict`; `mintIntegrationEvent` is deprecated; `Keiro.Outbox`
   now re-exports `Keiro.Outbox.Identity`, whose `outboxId`, `messageId`, and
   `sourceEventId` fields collide by name with `OutboxMessage` and
   `IntegrationEvent` for consumers that use bare selector functions; the
   `keiro-ops` forced purge now refuses on hidden rows; and the pgmq
   family moves to `>=0.6 && <0.7` with `shibuya-pgmq-adapter ^>=0.16.0.0`,
   while `FifoHeads` needs PGMQ 1.12 or later on the server. No `entails` is
   needed: the `kiroku-store`, `kiroku-store-migrations`, `keiki`, and
   `shibuya-core` bounds are unchanged and no migration file moved. Add the
   `S.BlueprintMigration` entry with `from = "0.16.0.0"`, bump the blueprint
   `version` and its mirror in `seihou-registry.dhall`, add the README edge row,
   and add the 0.17.0.0 row to `files/keiro-cohort-versions.md`.
3. **Reconcile the root `CHANGELOG.md` against the package changelogs.** It
   feeds the GitHub release notes and currently omits: the DLQ work entirely
   (redrive preserves wrapper headers, `purgeDlq` returns `PurgeDlqResult`
   and refuses hidden rows, `purgeDlqForce`, `archiveDlqEntries`); the
   `keiro-ops` breaking change (forced `pgmq dlq purge` refuses on hidden
   rows); the delegated inbox runtime (`runInboxDelegated`,
   `runInboxDelegatedWithRetries`, `runInboxDelegatedBatch`,
   `Keiro.Inbox.Delegated`) and the DSL `idempotence delegated` clause; the
   Language 6 candidate process reactions in `keiro-dsl`; the
   transition-family guard-diff rework with its `AggGuardRelationUnknown` and
   `AggGuardRemedyUnavailable` advisories and `diff --deny`; and
   `mkPartitionSpec`. Every one of these is recorded in the owning package
   changelog and absent from the root.
4. **Fix the two package changelogs that misdescribe their packages.**
   `keiro-test-support/CHANGELOG.md` says "No user-facing changes", but the
   library gained the exported `withFreshResourceStorePrepared` fixture, which
   the new `keiro` access-control test depends on. `keiro-dsl/CHANGELOG.md`
   carries a "No user-facing changes. The parser-scaling benchmark now uses
   ..." bullet inside an `Unreleased` section that describes a new language
   candidate; reword it as the benchmark fix it is.
5. **Record the outbox content-type fidelity change.**
   `Keiro.Outbox.Schema.assembleRow` no longer normalizes the stored
   `content_type` through `parseContentType`; only the exact text
   `application/json` maps to `ApplicationJson`, everything else is preserved
   verbatim. This is what makes the new drift comparison faithful (the
   "preserves raw MIME text" test pins it), but it also changes the
   `content-type` header the publisher writes for any retained row whose text
   was stored non-canonically (for example `Application/JSON` or
   `application/json; charset=utf-8`), which previously published as
   `application/json`. The inbox side still normalizes, so consumers decode
   either form, but the wire header changes and no changelog mentions it.
6. **Update the DLQ section of `docs/user/work-queues.md`.** "Operating the
   dead-letter queue" (lines 416 to 446) is untouched this cycle and still
   shows `readDlq` followed by `purgeDlq thumbnailJob -- delete everything,
   permanently`, and says operators "can purge alone". Under 0.17 that exact
   sequence returns `PurgeDlqBlocked` because the read hid the rows for 30
   seconds, and `purgeDlq` no longer returns `()`. The section also omits
   `purgeDlqForce`, `archiveDlqEntries`, and header preservation on redrive,
   which no user document mentions at all; only the `Keiro.PGMQ.Dlq` module
   header describes the new inspect-archive-verify-purge workflow.
7. **Gate `ordering fifo-heads` to Language 6, or document the exception
   and freeze it.** The token is accepted by the published Language 4 and 5
   grammars today (see the keiro-dsl section). Gating it is one
   `LanguageFeature` and a fixture header change; if the decision is instead
   to let published languages accept it, the changelog and the language
   stability record must say so before the tag, because the choice is
   irreversible once specs using it exist.
8. **Add the public API changes to the `keiro-dsl` Breaking Changes section,
   and the ledger and check-report changes to the edge.** The record and
   constructor changes listed in the keiro-dsl section, the one-time
   `custom-unverified` coordination drift line on first re-scaffold, the new
   `processReactions` key in the check report, and the requirement that
   hand-filled `Job {..}` values in DSL consumers add `jobOrdering` are all
   consumer-visible on upgrade and currently undocumented.
9. **At bump time, follow the procedure's traps, which are all live again.**
   `shibuya-pgmq-adapter ^>=0.16.0.0` appears three times (twice in
   `keiro-pgmq.cabal`, once in `jitsurei.cabal`) and coincides with the
   outgoing shared version, so a blind replace corrupts it exactly as at
   0.14.0.0; sixteen internal bound lines move; 504 `@generated by keiro-dsl
   0.16.0.0` provenance headers must be restamped by `just corpus-regen`, and
   the diff must be provenance-only; `keiro-migrations` needs its "No changes"
   note and `keiro-core` ships only a documentation change. Note that the
   formatter is now cabal-gild rather than cabal-fmt, so the release skill's
   description of column realignment no longer applies.

## What was examined and found sound

- **Process-manager reactions** (`Keiro.ProcessManager.Reaction`, 682 lines).
  The engine's three paths were traced against `runDomainCommandWithSqlEvents`,
  which invokes the SQL callback only for accepted appends, so the two
  `Prelude.error` branches are unreachable invariants rather than live paths.
  Accepted saga appends and timer SQL share one transaction; duplicate
  recovery validates the exact witness and skips timer SQL; target fan-out
  uses target-keyed ids (`deterministicReactionCommandId`, length-prefixed
  UUIDv5) with same-target occurrence counting, and reconciles a failed or
  zero-event dispatch against a concurrent winner. `recoverWitness` starts
  its scan at `StreamVersion 0`, which is correct because
  `Kiroku.Store.Read.readStreamForward` treats the cursor as exclusive and
  versions start at 1. The saga witness id is the legacy positional manager id
  (emit index -1), which is why switching an existing manager name to the
  reaction runner is the documented identity migration rather than a silent
  change. Legacy `Keiro.ProcessManager` changed only its Haddock. The
  `reaction-hydration-probe` Cabal flag is manual and default-off, and the
  proof script builds it in a temporary `--builddir`, so the default library
  is unaffected.
- **Producer outbox identity** (`Keiro.Outbox`, `Keiro.Outbox.Identity`,
  `Keiro.Outbox.Schema`). The version-1 byte layout matches ADR-42 field for
  field; the UUIDv8 version and variant bits are set correctly; `deriveIdentity`
  reads no clock or process state. `enqueueProducerOutboxTx` inserts with
  `ON CONFLICT DO NOTHING`, then locks matching rows through both unique
  keys; `keiro_outbox` has exactly those two unique constraints (primary key
  and `UNIQUE (source, message_id)` in migration 0002), so the retry-on-empty
  loop cannot spin on an uncovered constraint. Row locks are taken in
  `outbox_id` order, so two replays cannot deadlock each other. Timestamps are
  normalized to whole microseconds before insertion, which round-trips
  `timestamptz` exactly. No migration changed. The legacy `enqueueOutboxTx`
  keeps its `(source, message_id)` conflict target. The changed
  `mkIntegrationProducer` rejects the empty prefix that TypeID would accept.
- **Delegated inbox** (`Keiro.Inbox`, `Keiro.Inbox.Types`,
  `Keiro.Inbox.Delegated`). The wrappers reuse `dedupeKeyFor` and never touch
  the store; batch suppression remembers an identity only after
  `DelegatedFresh` or `DelegatedDuplicate`, so a failed item is retried later
  in the same chunk; the retry ceiling classifies above-ceiling attempts
  without invoking the handler and records the poisoned metric at the
  ceiling. `delegatedCommand` and `delegatedFromPMCommand` refuse to
  acknowledge failures and zero-event successes. `delegatedEventId` is
  length-prefixed and versioned. The table-backed path is untouched: the
  module diff is purely additive.
- **keiro-pgmq**. `validateJobConsumptionConfig` runs once per processor
  construction and once per one-shot drain, not per message, and the default
  wrappers now inherit `jobOrdering`, so an `Unordered` job behaves exactly as
  before. `FifoHeads` maps to the adapter's `HeadPerGroup`, which the
  published `shibuya-pgmq-adapter-0.16.0.0` source distribution implements on
  both polling paths. Redrive reads the `original_headers` key that the same
  published adapter writes into every DLQ wrapper, treats JSON null as absent,
  and never falls back to the DLQ row's own headers. `purgeDlq` reads a
  metrics snapshot before deleting and documents that the two are not atomic.
  `mkPartitionSpec` rejects mixed units, non-positive and out-of-range
  numeric spans, and retention below one span, and leaves opaque time text to
  PostgreSQL. `Config.premake = Nothing` preserves the server default under
  pgmq-config 0.6.
- **keiro-ops, keiro-core, keiro-test-support, jitsurei.** The ops purge
  surfaces `PurgeDlqBlocked` as a failure without deleting, the raw job carries
  `Unordered`, and the DLQ JSON exposes `original_headers`. `keiro-core` changed
  one Haddock. `withFreshResourceStorePrepared` closes the privileged store
  before opening the application store. The jitsurei shipment-notice example
  moves from `FifoThroughput` to `FifoHeads` with matching tuning.
- **Revert exactness.** `git diff 240e7203 250d3007` is empty: the reverted
  native query fencing, attempt-fenced outbox replay, and 0.17 release
  preparation left nothing behind.
- **Dependency surface.** Beyond cabal-gild reformatting, the only bound
  changes are the pgmq family `>=0.5 && <0.6` to `>=0.6 && <0.7` and
  `shibuya-pgmq-adapter ^>=0.14.0.0` to `^>=0.16.0.0`; `keiro` adds
  `directory` and `filepath` to its benchmark stanza; `keiro-dsl` adds
  `streamly-core` only to the new process-reactions conformance suite.
  Hackage serves every required version: pgmq 0.6.0.0 across all five
  packages and shibuya-pgmq-adapter 0.16.0.0. `cabal.project` is unchanged,
  so the only git pin remains `codd` behind the default-off
  `legacy-codd-tools` flag. `cabal check` reports no errors or warnings in any
  of the seven package directories.

## keiro-dsl

The DSL increment was reviewed by a delegated reader against the changelog's
claims, the language registry, the frozen corpora, and the runtime API it
generates against; the findings below that bear on the verdict were
re-verified by this reviewer at the cited lines.

Sound:

- **Language gating of the two Language 6 constructs.** `idempotence
  delegated` is claimed through `optionalLanguageFeature ... DelegatedInboxSyntax`
  and refused below Language 6 with a located `LanguageFeatureRequiresVersion`;
  `reactions` bodies go through `requireLanguageFeatureAt ...
  ProcessReactionSyntax`, and the parser test pins the diagnostic span to the
  keyword. Language 6 is registered as `Candidate CandidateLanguage` with
  predecessor 5, so Language 5 remains the sole stable authoring contract.
- **Guard-diff cancellation is partitioned and total.** Transition families
  are keyed by mode, source, and command, and exact cancellation compares
  `canonicalTransition`, which encodes the mode prefix, hole ownership, guard,
  writes, outcome, emits, and goto, so nothing cancels across partitions or
  across a hole/generated switch; opaque families escalate to do-not-deploy.
  `AggGuardRelationUnknown` and `AggGuardRemedyUnavailable` are built as
  advisories on the `PrivateHistoryRead` vector and fail an invocation only
  under `diff --deny`. All sixteen new diff codes are mapped to
  `DiffDiagnostic`; `remediationFor`, `contextFor`, and
  `classifyCompatibility` are total and the CLI iterates every constructor.
- **Determinism.** `TransitionFamily.hs` orders through `Map`/`Set` with an
  injective mode rank, `sortOn canonicalTransition`, and `Map.toAscList`;
  no `nub` or `HashMap` is used in the new code.
- **Generated reactions compile against the runtime.** Every name the
  `Process.hs` template emits (`ReactiveProcessManager` fields, `NoAdvance`,
  `AdvanceReaction`, `FollowDispatch`/`FollowSchedule`/`FollowCancel`,
  `Rearm`/`Once`, `runReactiveProcessManagerWorkerWith`) exists in
  `Keiro.ProcessManager.Reaction`, and three conformance suites compile it.
  The mutation script's four `sed` targets are live lines in the two fixtures,
  and it is wired into `just verify`.
- **Every changelog claim has a test**, with one precision caveat recorded
  below.

Findings:

- **`ordering fifo-heads` widens the published Language 4 and 5 grammars.**
  `Parser/Queue.hs` adds `WqFifoHeads <$ symbol "fifo-heads"` to the
  ordering alternatives with no `LanguageFeature` gate, and the fixture that
  proves it, `test/fixtures/workqueue-fifo-heads.keiro`, declares
  `language keiro-dsl 4`. Both other Language 6 constructs are gated; this
  one is accepted by every published language, so a spec that 0.16 rejected
  now checks and scaffolds. Once 0.17 is on Hackage the token can never be
  gated without breaking published specs, which is why this is in the
  required list.
- **The reaction template derives timer ids with the pre-ADR-24 seed.**
  `Scaffold.hs` emits `namedUuid value = UUID.V5.generateNamed
  UUID.V5.namespaceURL (map (fromIntegral . fromEnum) (T.unpack value))` and
  builds timer ids as `prefix <> correlationId`, which truncates each code
  point modulo 256 and has no field boundary. The runtime's own reaction ids
  in `Keiro.ProcessManager.Reaction` use UTF-8 length-prefixed fields, and
  `Keiro.DeterministicId` documents the truncated form as the collision bug
  ADR-24 fixed. Two non-ASCII correlation ids can share a `TimerId`, so `Once`
  silently no-ops, `Rearm` moves the wrong row, and cancel cancels the wrong
  timer. The legacy process template has the same code and is frozen, but the
  reaction surface is a candidate whose timer ids become frozen replay
  identity the moment Language 6 is published. Fix it while it is still
  amendable.
- **The `keiro-dsl` Breaking Changes section omits the public API changes.**
  `ProcessNode` replaces its `input`, `handle`, and `timer` fields with
  `body :: ProcessBody`; `IntakeNode` gains `idempotence`; `WqOrdering` gains
  `WqFifoHeads`; the diagnostic-code enumerations gain 34 constructors;
  `LanguageFeature` and `RuntimeCapability` gain three; `DiffEnv`,
  `ScaffoldReport`, and `ScaffoldRecord` gain fields; `checkReport` and
  `workspaceCheckReport` now take a `CheckedService`. Nothing was removed or
  renamed, but exhaustive matches and positional construction break, and the
  release procedure names exactly this pattern as major.
- **Ledger and check-report surfaces changed for existing services.** Every
  legacy process now writes a `process-reaction ... custom-unverified` ledger
  row, so the first 0.17 re-scaffold of any Language 4 or 5 process service
  prints a one-time coordination drift line, and the check-report JSON gains a
  `processReactions` key under the unchanged schema id
  `keiro-dsl/check-report/1`. Neither is in the changelog and both belong in
  the upgrade edge.
- **Existing-twin coverage is stricter than the changelog says.** `coversBody`
  accepts a pre-existing replay-only sibling only when its guard is
  byte-canonically the removed region or every old alternative implies it
  alone, so a hand-simplified twin that is logically identical to the computed
  one (the `(A||B) && C` fixture) now draws an `AggGuardTightened` advisory
  that 0.16 did not emit, and two tests pin that advisory as correct. It is
  conservative and never hides a hazard, but it is a visible change for users
  who simplified twins by hand, and "cover the exact removed region" in the
  changelog reads as semantic when it is syntactic.
- **Rollout metadata is inconsistent for the new reaction codes.** The four
  reaction advisories whose text says "drain before deploy" fall to the
  generic advisory vector with an empty `rollout` array, and the three new
  breaking codes land on the private-decode vector rather than the
  persisted-identity vector used by `ProcessTimerIdentityChanged`. Exit codes
  are right; the machine-readable report is what disagrees with the prose.
- **The reaction fingerprint covers operator text.** It hashes the rendered
  reaction surface minus the version line, and that render includes
  `timers max-attempts N dead-letter "..."`, so editing a dead-letter message
  or retry ceiling is `ProcessReactionFingerprintChangedWithoutVersionBump`
  (breaking) unless `reactions version` is bumped; the ceiling test asserts
  only the advisory. The fingerprint is also over pretty-printer output rather
  than a frozen encoding, so a renderer change would move every stored value.
- **User documentation.** `diff --deny` is documented only in the evolution
  guide, not in the CLI reference that documents `check --deny`;
  `AggGuardRelationUnknown`, `AggGuardRemedyUnavailable`, and
  `IntakeIdempotenceModeChanged` appear nowhere under `docs/user`; and
  `keiro-dsl new` skeletons now open with `language keiro-dsl 6` while the
  toolchain reference tells released services to stay on 5.
- Notes: `processReactionRowsForService` and `processReactionSnapshots` are
  exported partial functions that call `error` on a failed type graph; the
  harness fact `reactionOwnership` is hard-coded to `generated-declarative`
  even for `custom-unverified` processes; `Validate.validateProcess` returns
  no diagnostics for a reaction body when the type graph fails.

## Performance

No unmeasured hot path changed. The producer, delegated inbox, and FIFO
changes each carry retained evidence, and the historical baselines were only
appended to.

| Surface | Measured cost | Guard | Evidence |
| --- | ---: | --- | --- |
| Producer fresh enqueue, 1,000 rows, one transaction | +3.22% | 10% same-process `bcompareWithin` in `just bench-regression` | `keiro/bench/results/producer-identity-v1/precision.csv` |
| Producer fresh enqueue, 1,000 individual transactions | +2.66% | 10% same-process | same |
| Publisher hot-key / hot-key-nolatency / multi-key, 2,000 rows | +3.29% / +0.89% / -0.54% | matched medians of three runs, old binary from 20f2f378 | `publisher-before-*.csv`, `publisher-after-*.csv` |
| Pure identity derivation | 1.03 µs median | none needed | `derive-v1` |
| Identical replay of 1,000 rows | about 0.35 ms per duplicate (new work: locked read plus canonical compare) | none; deliberate cost of drift detection | README subtraction estimate |
| Delegated wrapper over a direct handler loop | +0.68% | 10% in plan 83 | `keiro/bench/results/delegated-inbox-v1/` |
| Historical inbox scenarios (`single-full`, `single-nometrics`, `batch-100`, `single-slim`) | passed the committed 25% guard before the 34 new rows were appended | 25% | same README |
| `FifoHeads` grouped-head reads at 100,000 messages / 10,000 groups | quantities 10 and 50 at ratios 0.115 and 0.036 of the batch-one baseline | 20% gate in plan 116 | plan 116 progress log |

`git diff keiro-0.16.0.0..HEAD -- keiro/bench/baseline-*.csv` shows only 34
appended rows in `baseline-inbox.csv`; `baseline-outbox.csv`,
`baseline-command.csv`, `baseline-projection.csv`, and
`baseline-read-model.csv` are byte-identical to 0.16.0.0. The producer
benchmark's legacy reference reproduces the pre-0.17 path in-process (fresh
UUIDv7 outbox id, fresh TypeID via `freshIntegrationEvent`, the unchanged
`enqueueIntegrationEventTx` statement) with matched preparation boundaries, so
the comparison is like for like. The delegated benchmark's table and delegated
downstreams perform the same indexed existence probe, one append, and one
counter update. The reviewed machine is the one the evidence names (Apple M1
Max, GHC 9.12.4, PostgreSQL 18.6).

An independent run of the three relevant `just bench-regression` guards at the
reviewed commit (17:58Z to 18:08Z, on a machine the user reports as heavily
loaded at the time) agrees with the retained evidence where the measurement is
stable and disagrees only where the measurement is not:

| Guard | Result |
| --- | --- |
| `producer-identity` (10% same-process) | all six pass: `derive-v1` 1.06 µs; `deterministic-fresh-1000` 81.6 ms vs legacy 79.8 ms (1.02x); `deterministic-single-tx-per-event-1000` 118 ms vs legacy 126 ms (0.94x); fresh-and-replay 428 ms |
| `outbox` (25% vs `baseline-outbox.csv`) | `hot-key`, `hot-key-nolatency`, `multi-key` all "same as baseline" |
| `inbox`, historical rows (25% vs `baseline-inbox.csv`) | `single-full` 18% faster, `single-nometrics` 10% faster, `batch-100` 12% faster, `single-slim` 18% faster |
| `inbox`, new downstream rows | 33 of 34 pass; `table-downstream-single.fresh.metrics-off` fails at 5.465 s ± 2.97 s against a 1.844 s baseline |

The one failure is not attributable to the change. Its code path is the
unchanged table inbox plus a benchmark-owned downstream append, its four
historical siblings on the same path got faster, and it is the first fresh
scenario `tasty-bench` executes. Rerun alone it measured 6.689 s ± 2.84 s and
7.128 s ± 6.29 s; run second in the same process its `metrics-on` twin
measured 0.76 s to 1.07 s; and when either `metrics-on` or the unchanged
`delegated-single.fresh.metrics-off` was made the first scenario instead, each
measured about 7.0 s with a standard deviation of 5.9 s and 7.4 s. The
committed baseline row itself carries a standard deviation (1.68 s) almost
equal to its mean, so the position effect existed when the evidence was
recorded. Treat the fresh downstream guard as unreliable until the first-run
cost is moved out of the timed action or the machine is quiet, and rerun
`just bench-regression` on a quiet machine before tagging; nothing in the
independent run indicates a regression beyond what plans 83, 116, and 164
measured and accepted.

Two costs are new rather than regressions and are worth knowing about: duplicate
recovery for a reaction reads the saga stream forward in 256-event pages until
it finds the witness, because the store has no read-by-id operation (plan 279
records this deviation, and the tests cover 256, 1,024, and 4,096 events), so
the cost of a redelivered accepted input grows with saga length; and a
`NoAdvance` or silent reaction always opens a timer transaction, even when its
follow-ups contain no timer operation, which is one empty `BEGIN`/`COMMIT`
round trip per such delivery.

## Follow-ups that do not block the tag

- `mori.dhall` declares `shibuya-pgmq-adapter` at `^>=0.15.0.0`; the Cabal
  files require `^>=0.16.0.0` since da5e2469. The pgmq-hs entries were
  reconciled at 9b595352 and this one was missed.
- The two REV-15 follow-ups are still open: `keiro-dsl-runtime-vocabulary-test`
  depends on `keiro` and `shibuya-core` unbounded and `keiro-dsl-codec-bench`
  on `keiro` unbounded outside the conformance suites, and
  `keiro/src/Keiro/ReadModel.hs` still ships ten `DEPRECATED` pragmas that
  promise removal "in 0.13" at 0.17.
- The gate's new `process-reaction-proof` builds `keiro` with the probe flag in
  a fresh temporary `--builddir`, which rebuilds every local package on each
  `just verify`, and the mutation script rewrites two committed conformance
  directories in place and restores them by re-scaffolding on exit. Both are
  correct, but the first is a standing gate cost and the second leaves a dirty
  tree if the exit trap is skipped.
- The release skill still describes `nix fmt` as running cabal-fmt and
  realigning the `build-depends` column; the repository formats with
  cabal-gild since c337e183.
- Consider guarding the reaction timer phase so that follow-ups with no
  `FollowSchedule`/`FollowCancel` skip the empty transaction.
- The first fresh downstream inbox scenario in a `tasty-bench` process pays a
  multi-second, high-variance first-run cost that the committed baseline row
  also shows (standard deviation about equal to the mean). Move that cost out
  of the timed action or add a warm-up scenario so the 25% guard can fail for
  a real reason.
- The delegated reader's remaining notes on the keiro-dsl candidate surfaces
  (rollout vectors for the new reaction codes, the fingerprint covering
  operator text and pretty-printer output, twin-coverage strictness, partial
  exported helpers, the hard-coded harness ownership fact, and skeletons
  defaulting to the candidate language) should be resolved before Language 6
  is published rather than before this tag.

## Evidence

- `git log --oneline keiro-0.16.0.0..HEAD` lists 86 commits touching 476 files
  (42,409 insertions, 5,632 deletions); `git rev-list -n1 keiro-0.16.0.0` is
  `2da45585`. `origin/master` equals HEAD after `git fetch`.
- `git diff 240e7203 250d3007 --stat` printed nothing.
- `git diff --stat keiro-0.16.0.0..HEAD -- keiro-migrations/migrations` printed
  nothing.
- Hackage `preferred` reports 0.16.0.0 as the newest version of all seven
  packages, 0.6.0.0 for `pgmq-config`, `pgmq-core`, `pgmq-effectful`,
  `pgmq-hasql`, and `pgmq-migration`, and 0.16.0.0 for `shibuya-pgmq-adapter`.
  The `shibuya-pgmq-adapter-0.16.0.0` source distribution contains
  `"original_headers" .= msg.headers` in `Shibuya/Adapter/Pgmq/Convert.hs` and
  `HeadPerGroup -> readGroupedHead` in `Shibuya/Adapter/Pgmq/Internal.hs`.
- `cabal check` in all seven package directories: "No errors or warnings could
  be found in the package."
- `just verify` at the reviewed commit (started 2026-09-16T17:32:36Z, exited 1
  at 17:42:23Z): `keiro-test` 694 examples, 0 failures; `keiro-pgmq-test` 79
  examples, 0 failures, 2 pending; `keiro-ops-test` 50 examples, 0 failures;
  `keiro-dsl-test` 743 examples, 2 failures, both `Ambiguous module name
  'Keiki.Shape'`; the recipe stopped at `haskell-test`. The two examples fail
  identically when rerun alone. `ghc-pkg` on the store `package.db` lists
  `keiki-0.9.1.0` twice with ids `kk-0.9.1.0-0e5dc76b` and
  `kk-0.9.1.0-28a60311`; `dist-newstyle/cache/plan.json` contains only the
  latter. A one-line module importing `Keiki.Shape` fails under
  `cabal exec --enable-tests -- ghc -package keiki` with the same ambiguity
  and resolves under `-package-id kk-0.9.1.0-28a60311`.
- Running the skipped gate steps individually (17:45:45Z to 17:56:34Z):
  `cabal sdist` of all seven packages exited 0; the 37 other `keiro-dsl`
  test suites exited 0; `keiro-dsl-test` with the two examples skipped
  reports 741 examples, 0 failures; `jitsurei-test` 36 examples, 0 failures;
  `jitsurei-diagrams --check` exited 0; `adr-validate` (45 concepts),
  `research-validate` (17), `capabilities-validate` (19), `reviews-validate`
  (16), `user-documentation-validate` (25 user, 27 guides),
  `extension-policy`, and `dsl-api-boundaries` all passed;
  `record-migration-policy` exited 1 as quoted above; `generated-name-policy`
  passed; `conformance-corpus-policy` exited 1 and left the five
  `QueuePolicy.hs` files modified with only `\ No newline at end of file`
  hunks, which were restored with `git checkout`; `process-reaction-proof`
  exited 0 (four mutations reddened, probe counts explicit, default build
  silent); `keiro-migrations-test` 25 and 22 examples, 0 failures.
- `python3 scripts/generate-record-migration-manifests.py` rewrote
  `record-field-migration-0.15.md` (11 line-number rows) and
  `generated-haskell-edition-idiomatic-v2.md` (4 rows); both were restored
  after inspection. The tree was clean before and after every check.
- `git diff keiro-0.16.0.0..HEAD -- keiro/bench/baseline-*.csv` shows 34
  added lines and no removed or changed lines.
- `grep -rl '@generated by keiro-dsl 0.16.0.0' keiro-dsl/test | wc -l` is 504;
  sixteen `^>=0.16.0.0` internal bound lines and three
  `shibuya-pgmq-adapter ^>=0.16.0.0` lines exist across the Cabal files.
- Changelog cross-check: the root `Unreleased` section contains zero mentions
  of redrive, purge, `archiveDlqEntries`, delegated, `mkPartitionSpec`,
  `AggGuardRelationUnknown`, or `--deny`; the owning package sections mention
  each. No changelog mentions `withFreshResourceStorePrepared` or the
  content-type change.
- `docs/user/work-queues.md` lines 416 to 446 are absent from
  `git diff keiro-0.16.0.0..HEAD -- docs/user/work-queues.md`, and
  `purgeDlqForce` and `archiveDlqEntries` appear in no file under `docs/user`
  or `docs/guides`.
