---
id: 240
slug: bridge-deterministic-id-deduplication-across-the-utf-8-encoding-upgrade
title: "Bridge deterministic-id deduplication across the UTF-8 encoding upgrade"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjzp13e28vvrz7jfdve3dt"
master_plan: "docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md"
---

# Bridge deterministic-id deduplication across the UTF-8 encoding upgrade

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro's process managers and routers dispatch commands under *deterministic ids*: a
version-5 UUID computed from public coordinates (manager name, correlation key, source
event id, emit index), so that when the same source event is delivered twice — which
at-least-once messaging guarantees will happen routinely, on every Kafka rebalance or
worker restart — the second delivery computes the same id, a pre-dispatch probe finds the
id already in the target stream, and the command is not applied twice.

During the 0.12 window, commit `f8ca7a16` changed how the id's seed text is turned into
hash input: from a byte-per-character encoding that truncated every character to its
Unicode codepoint modulo 256, to proper UTF-8 bytes (recorded in
`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`).
For pure-ASCII seeds the two encodings produce identical bytes, so identical ids. For any
seed containing a non-ASCII character — a customer name like `José`, a CJK identifier —
the ids *move*. The consequence the ADR did not spell out, confirmed as a defect by the
2026-08-11 pre-release review: a command dispatched under 0.11 with a non-ASCII
correlation key was persisted under the *old* id; after the upgrade, a redelivery of the
same source event computes the *new* id, every dedup probe misses, and the command is
appended a second time to the target aggregate. Double reservation, double payment — with
no error anywhere, because from the store's point of view a second append under a fresh id
is a perfectly ordinary write. The same root cause silently breaks legacy awakeable
adoption for non-ASCII labels.

After this plan, the runtime's idempotency probes check the legacy-encoding-derived id in
addition to the current one, for router commands, process-manager commands, and awakeable
adoption. You can see it working: a DB-backed test inserts a command row under the exact
id the pre-upgrade code would have written (validated against golden ids captured from the
real pre-upgrade code), redelivers the source event through the current runtime, and
observes a duplicate verdict with exactly one event in the target stream — where today's
code appends a second event. ASCII deployments are byte-for-byte unaffected.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] Implementation started; read the complete ExecPlan and marked EP-4 in progress in
      the parent MasterPlan before changing deterministic-id code (2026-08-12T19:09:47Z).
- [x] M1: Create the capture worktree at `f8ca7a16^` and record the old-encoding golden
      UUIDs for every vector in the capture table (the three ASCII cross-checks must
      reproduce the known literals (2026-08-12T19:17:05Z).
- [x] M1: Add `legacySeedBytes` and `seedMovedAcrossEncodings` to
      `keiro/src/Keiro/DeterministicId.hs` with freeze haddocks (2026-08-12T19:17:05Z).
- [x] M1: Add `legacyDeterministicCommandId` (sharing a private `commandIdSeed` with
      `deterministicCommandId`) to `keiro/src/Keiro/ProcessManager.hs`; export it
      (2026-08-12T19:17:05Z).
- [x] M1: Add `legacyDeterministicAwakeableId` (sharing a private `awakeableSeed`) to
      `keiro/src/Keiro/Workflow/Awakeable.hs`; export it (2026-08-12T19:17:05Z).
- [x] M1: Add the pure golden-vector tests under a new
      `describe "Keiro deterministic id legacy-encoding bridge"` block in
      `keiro/test/Main.hs`; `cabal test keiro-test` green with 501 examples and
      zero failures (2026-08-12T19:20:42Z).
- [x] M2: Add `firstExistingEventId` and `deterministicCommandIdProbes` to
      `keiro/src/Keiro/ProcessManager.hs`; export both (2026-08-12T19:25:25Z).
- [x] M2: Add the five redelivery checks (four DB-backed scenarios for PM
      state+command, router, domain PM, and domain router, plus the pure ASCII probe
      cardinality check) and record their failure transcripts against the unbridged code
      (2026-08-12T19:25:25Z).
- [x] M2: Wire the four process-manager probe sites and the two router probe sites;
      scenarios turn green; the full suite, including existing ASCII and concurrent
      dedup tests, passes with 506 examples and zero failures
      (2026-08-12T19:29:46Z).
- [x] M3: Bridge `allocateAwakeableId` adoption; the new non-ASCII-label scenario and
      existing ASCII adoption scenario both pass (2026-08-12T19:32:44Z).
- [ ] M4: Update ADR 0024 (bridge, unified window, removal criteria, residual collision
      ambiguity) and `docs/adr/log.md`; `just adr-validate` green.
- [ ] M4: Add the `keiro/CHANGELOG.md` Unreleased upgrade note.
- [ ] M4: Point the `Router.hs` transition comment and the `ProcessManager.hs` haddocks
      at the unified window criteria in ADR 0024.
- [ ] M4: Update MasterPlan 37 (registry row EP-4, progress checklist); run
      `just haskell-test`; remove the capture worktree.
- [ ] Completion: ADR distillation pass and Outcomes & Retrospective entry.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Drafting research (2026-08-11): the review's suggested collision example — `é` (U+00E9)
  versus `i` (U+0069) — is *not* a truncation collision: `0xE9 /= 0x69`. Two codepoints
  collide under the old encoding exactly when they are equal modulo 256. Verified pairs
  used by this plan instead: `ā` (U+0101) with `\SOH` (U+0001); `ũ` (U+0169) with ASCII
  `i` (U+0069); `ǩ` (U+01E9) with `é` (U+00E9); `中` (U+4E2D) with ASCII `-` (U+002D);
  `😀` (U+1F600, codepoint 128512 = 502 × 256) with `\NUL` (U+0000). The existing frozen
  tests at `keiro/test/Main.hs` line ~9554 already use the U+0101/U+0001 and
  U+4E2D/U+2E2D pairs.
- Drafting research (2026-08-11): every persisted *positional* router id predates
  `keiro-0.2.0.0`. `git tag --contains 58388270` (the commit that switched routers to
  target-identity ids) shows the switch shipped in 0.2.0.0, and the UTF-8 encoding switch
  (`f8ca7a16`) is in the unreleased 0.12 window. So no release ever wrote positional
  router ids with UTF-8 seed bytes, and the router's legacy probe can simply be derived
  with the legacy encoder instead of gaining a third probe (Decision Log).
- Implementation (2026-08-12): the isolated capture worktree at pre-change commit
  `7d7a200b` reproduced the three known ASCII ids and supplied all non-ASCII fixtures.
  The collision rows were exact: command correlations U+0101/U+0001 both yielded
  `cfa5de78-8cc7-5eb2-8edd-da847221541d`, U+0169/ASCII `i` prefixes both yielded
  `4fb869b4-d5b7-5c99-8c5d-c4552c5d4115`, and awakeable labels U+4E2D/ASCII `-`
  both yielded `7b252ef4-c7c0-579e-8f15-8f26c73196de`. A deliberately corrupted
  `José` golden failed with the genuine captured id, proving the fixture block is
  behavior-sensitive rather than self-derived.
- Implementation (2026-08-12): all four database reproductions failed together against
  the deliberately unbridged runtime. Both process-manager cases reported
  `PMStateAppended` plus an appended/handled command with manager and target stream
  lengths `(2,2)`; both router cases reported an appended/handled command with target
  length `2`. The expected historical IDs were respectively `4d474ccc...`/`b19708e7...`
  (PM), `50b226dc...`/`8837a38c...` (domain PM), `1b99b504...` (router), and
  `f2aad3de...` (domain router). This is the planned before-fix evidence that one
  pre-upgrade event becomes two post-upgrade writes.
- Implementation (2026-08-12): the non-ASCII awakeable adoption scenario failed before
  the bridge at the identity assertion: expected captured legacy id
  `c4eb4dfa-4108-577d-8e92-84edb337a48b`, but generation 0 allocated fresh v4 id
  `ce33caed-8f8a-4afc-a6ab-3853efb271eb`. This directly reproduces the orphaned
  pre-upgrade row; the particular v4 value is intentionally not a golden.

(Implementation entries to be added as work proceeds.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Bridge with a frozen legacy encoder plus an additional dedup probe; do not
  migrate or rewrite persisted ids, and do not revert the UTF-8 encoding.
  Rationale: ADR 0024 froze `identitySeedBytes` because deterministic ids are replay
  identity — rewriting history is not recoverable, and reverting would reopen the
  collision-wedge defect the UTF-8 switch fixed. The only sound bridge is to keep the old
  derivation available as an immutable artifact and *ask about both ids* at every
  idempotency decision point. The legacy encoder is additive, pure, and pinned by golden
  tests captured from the genuine pre-change code.
  Date: 2026-08-11
- Decision: The extra probe is guarded, not unconditional: the legacy candidate id is
  computed and probed only when the seed text contains a non-ASCII character
  (`seedMovedAcrossEncodings`, i.e. `not . Text.all isAscii`).
  Rationale: for ASCII seeds the two encodings are byte-identical, so the legacy probe
  would repeat the current-id probe exactly — one wasted `eventExistsInStream` round trip
  per dispatched command and per manager-state advance, on the hottest dispatch path, for
  every ASCII deployment (which is every deployment we know of). The guard is a pure
  `Text.all isAscii` scan of a seed string that is already being built, costs nanoseconds,
  and cannot be wrong in either direction: ASCII seeds provably have identical ids
  (skipping loses nothing), non-ASCII seeds get the probe. The unconditional form's only
  advantage is fewer branches to read, which the `NonEmpty` probe-list shape already
  keeps tidy.
  Date: 2026-08-11
- Decision: The router's existing legacy positional probe switches its derivation to the
  legacy encoder (`legacyDeterministicCommandId`), unconditionally, rather than adding a
  third probe per dispatch.
  Rationale: positional router ids exist in stores only from pre-0.2.0.0 releases (see
  Surprises & Discoveries), all of which encoded seeds with the truncating encoder. A
  UTF-8-encoded positional router id has never been written by any release. For ASCII
  seeds the legacy-encoded positional id is byte-identical to what the probe computes
  today, so coverage for ASCII deployments is unchanged; for non-ASCII seeds the probe
  starts matching what is actually persisted, which today it cannot. Router dispatch
  therefore keeps exactly two probes.
  Date: 2026-08-11
- Decision: The bridged probe is defined in exactly one place —
  `firstExistingEventId` plus the derivation helpers `deterministicCommandIdProbes` and
  `legacyDeterministicCommandId`, all exported from `Keiro.ProcessManager` — and every
  probe site calls it. Plan 242
  (`docs/plans/242-deduplicate-dispatch-and-retry-skeletons-and-fix-rebuild-read-amplification.md`),
  which consolidates the router/process-manager dispatch copies, must route its
  consolidated dispatch helper through these same functions.
  Rationale: MasterPlan 37's integration-points section makes EP-6 (plan 242) soft-depend
  on this plan precisely so the bridged probe is written once and adopted by the
  consolidation, not re-fixed in four copies. Defining derivation and probe as small
  exported functions (rather than inlining the pair-check at each site) makes the
  consolidation a call-site move, with these functions' semantics — and their golden
  tests — the single source of truth. Whichever plan lands second preserves the other's
  semantics.
  Date: 2026-08-11
- Decision: One unified compatibility window covers both the encoding bridge introduced
  here and the 0.2.0.0 positional-id probe it subsumes on the router path; both are
  removed together. The window closes only when an operator attests that no pre-upgrade
  dispatch remains within the dedup horizon (defined precisely in the ADR-0024 text this
  plan adds, and summarized in Context and Orientation), and no earlier than one minor
  release after 0.12.0.0. Removal is a Breaking Changes entry.
  Rationale: the existing positional probe's window was documented only as "may be removed
  in a later release" (CHANGELOG 0.2.0.0 entry), which is not a checkable criterion. The
  two bridges guard the same probe sites, the same redelivery channels, and after this
  plan the positional probe is computed by the same frozen encoder, so separate windows
  would be fiction: removing either alone re-exposes the other's population. Aligning
  them in ADR 0024 gives operators one attestation to make and future contributors one
  place to check.
  Date: 2026-08-11
- Decision: The bridge accepts the legacy encoding's collision ambiguity for the duration
  of the window.
  Rationale: a legacy id is inherently ambiguous — `ũser` and `iser` derive the *same*
  legacy id (U+0169 truncates to `i`), so during the window a pre-existing row for one
  can cause the bridged probe to report a duplicate for the other, suppressing one
  dispatch. This is exactly the behavior every pre-upgrade version already had (it is the
  defect ADR 0024 fixed), it can only be triggered by rows that predate the upgrade, and
  it disappears with the bridge. The alternative — trying to disambiguate by payload —
  would require reading and interpreting target-stream history in the dispatch hot path
  for a vanishing population. Documented in the ADR update.
  Date: 2026-08-11
- Decision: Workflow journal ids and sleep-timer ids get no bridge; scope is router
  commands, process-manager commands (state and dispatch), and awakeable adoption.
  Rationale: for those two families the deterministic id is *not* the idempotency
  mechanism. Journal replay and append-visibility fall back to the step index keyed by the
  full step-name *text* (ADR
  `docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md`), so a
  moved journal id cannot double-apply a step; a moved sleep-timer id can arm one
  duplicate timer row whose fire collapses in the idempotent, step-index-checked journal
  append. Both are bounded and were accepted in ADR 0024. The review confirmed defects
  only where the id *is* the sole dedup mechanism: command dispatch and awakeable
  adoption.
  Date: 2026-08-11
- Decision: Golden expectations for the legacy encoder are captured by running the actual
  pre-change code (a `git worktree` at `f8ca7a16^`, `cabal repl keiro`), never recomputed
  from a reimplementation, and the capture session must reproduce the three already-frozen
  ASCII literals before any new value is trusted.
  Rationale: plan 202 established the principle that a fixture is only trustworthy if
  captured before (here: outside) the change — a test comparing a reimplementation
  against itself proves nothing. The known ASCII literals (`ff20892c-…`, `4f3aa6bc-…`,
  `f677231c-…`) act as a checksum that the capture procedure itself is sound.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/ (this plan's distillation target is ADR 0024, updated in
Milestone 4). Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This is a Haskell multi-package repository; the library at issue is the `keiro` package
under `keiro/`, and all commands below run from the repository root
(`/Users/shinzui/Keikaku/bokuno/keiro` — use your own checkout path; paths in this plan
are repository-relative). Tests live in one hspec suite, `keiro/test/Main.hs`, run with
`cabal test keiro-test`.

### What a deterministic id is, and the two encoders

A *deterministic id* is a version-5 UUID — `Data.UUID.V5.generateNamed
UUID.V5.namespaceURL :: [Word8] -> UUID` from the `uuid` package, a SHA-1-based hash of a
byte list under a namespace — computed over a *seed*: a `Text` built from public
coordinates. Because the id is a pure function of the seed, an at-least-once writer that
retries collapses to exactly one row. The seed-to-bytes step is the *encoder*, and it is
replay identity: change it and every deployed id renames.

The old encoder, in force in every release up to and including 0.11.0.0, was:

```haskell
fmap (fromIntegral . fromEnum) . Text.unpack
```

One byte per character: `fromEnum` yields the character's Unicode codepoint as an `Int`,
and `fromIntegral` to `Word8` keeps only the low eight bits — the codepoint modulo 256.
`é` (U+00E9) becomes `0xE9`; `中` (U+4E2D) becomes `0x2D`, the same byte as ASCII `-`;
`😀` (U+1F600, codepoint 128512 = 502 × 256) becomes `0x00`. Any two codepoints equal
modulo 256 produce identical bytes, hence identical ids.

The current encoder, since commit `f8ca7a16` (unreleased, in the 0.12 window), is
`Keiro.DeterministicId.identitySeedBytes` in `keiro/src/Keiro/DeterministicId.hs`:

```haskell
identitySeedBytes :: Text -> [Word8]
identitySeedBytes = ByteString.unpack . Text.Encoding.encodeUtf8
```

For pure-ASCII text the UTF-8 bytes *are* the codepoint values, so ASCII ids are identical
under both encoders. Non-ASCII seeds produce different bytes — multi-byte sequences
instead of one truncated byte — so their ids moved. `Keiro.DeterministicId` is an
*internal* module (listed under `other-modules` in `keiro/keiro.cabal`, line ~95), so the
test suite and applications reach these derivations only through the public modules named
below.

### The id family and every probe site

`Keiro.ProcessManager.deterministicCommandId` (`keiro/src/Keiro/ProcessManager.hs`,
~line 474) hashes the `:`-joined seed

```text
keiro:process-manager:<managerName>:<correlationId>:<sourceEventUuid>:<emitIndex>
```

through `identitySeedBytes`. It keys four probe sites, each an
`eventAlreadyIn options streamName eventId` call (`eventAlreadyIn`, ~line 1093, wraps
Kiroku's `eventExistsInStream` point lookup):

1. `runProcessManagerOnce` manager-state advance, emit index `-1` (~line 521/524);
2. `runProcessManagerOnce`'s `dispatchCommand`, emit index `0..` (~line 565/569);
3. `advanceDomainProcessManager` manager-state advance (~line 661/665);
4. `dispatchDomainProcessManagerCommand` (~line 753/759).

`Keiro.Router` (`keiro/src/Keiro/Router.hs`) derives its *current* dispatch ids with
`deterministicRouterCommandId` (~line 215), which encodes every seed field as
length-prefixed UTF-8 and is therefore untouched by the encoding switch. But both router
dispatch paths carry a second, *transition* probe, `legacyCommandId`, kept expressly to
recognize dispatches persisted by pre-0.2.0.0 releases, which derived router ids
*positionally* via `deterministicCommandId`:

5. `dispatchRouterCommands`'s `dispatchCommand` (~lines 318–346) — probes `commandId`
   then `legacyCommandId = deterministicCommandId routerName correlationId sourceEventId
   legacyIndex`;
6. `dispatchDomainRouterCommand` (~lines 470–496) — the same pair.

Here is how the layering broke: `legacyCommandId` exists to reproduce *what an older
release wrote*, but it is computed by calling today's `deterministicCommandId` — and since
`f8ca7a16` that function encodes UTF-8 underneath it. Every pre-0.2.0.0 positional id in
every store was written with the truncating encoder, so for non-ASCII correlation keys the
"legacy" probe now computes an id that has never existed in any store. The probe silently
stopped covering the very population it was kept for.

Finally, `Keiro.Workflow.Awakeable.allocateAwakeableId`
(`keiro/src/Keiro/Workflow/Awakeable.hs`, ~lines 218–232, feeding `awakeableNamed` at
~line 157's derivation): for generation-0 workflows it computes
`deterministicAwakeableId name wid label` — a v5 UUID over
`keiro:awakeable:<name>:<wid>:<label>` through `identitySeedBytes` (~line 153) — and, if a
row with that id exists in `keiro_awakeables`, *adopts* it so an in-flight promise handed
out before the random-id scheme keeps working. A pre-upgrade row with a non-ASCII label
was registered under the truncating-encoder id; the adoption lookup now derives the UTF-8
id, misses, allocates a fresh random id, and the external system holding the old id
signals a promise the workflow will never await. ADR 0024 listed this as an accepted
consequence; the review reclassified it, together with the dispatch-dedup miss, as the
defect this plan fixes.

### Why the failure is silent, and why only the probe can catch it

The store enforces *global event-id uniqueness*: an append under an id that already exists
anywhere fails with `DuplicateEvent`, and `confirmBenignDuplicate`
(`keiro/src/Keiro/ProcessManager.hs`, ~line 1112) folds that into a duplicate verdict. But
the redelivered command is appended under the *new* id, which collides with nothing — the
append *succeeds*. The append-failure backstop is structurally incapable of catching a
moved id; only the pre-dispatch probe can, by asking about the old id explicitly. This
also means the bridge needs no change to `confirmBenignDuplicate`. One more useful
property: rows under legacy ids are immutable history — no code writes legacy-encoded ids
anymore — so the added probe has no read-then-write race; the current-id probe keeps its
existing append-time backstop.

### The compatibility window, in plain terms

"Dedup horizon" means: the set of source events that can still be *redelivered* to a
dispatch path. Kafka redelivers on rebalance/restart until a consumer group's committed
offsets pass an event and retention expires its segment; pgmq redelivers until a message
is archived/deleted and the archive drained; a timer delivers when it fires; an operator
replay re-delivers anything it replays. The bridge must live until no source event first
delivered before the upgrade can reach a probe site again. The window text this plan adds
to ADR 0024 (Milestone 4) makes that an operator-checkable attestation.

### Relevant ADRs and plans

- `docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`
  — the encoding switch, the freeze, and the consequences list this plan corrects and
  extends. This plan updates it.
- `docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md` — why
  journal ids need no bridge (replay and append-visibility key on step-name text).
- `docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md`
  — this is EP-4; its integration-points section binds this plan to plan 242 (EP-6), the
  dispatch-consolidation plan, which soft-depends on this one.
- `docs/plans/202-derive-workflow-deterministic-ids-from-utf-8-bytes.md` — the plan that
  made the encoding switch; source of the capture-before-change fixture discipline and of
  the frozen ASCII literals reused here as cross-checks.
- The freeze tests live in `keiro/test/Main.hs` under
  `describe "Keiro deterministic id derivation"` (~line 9504): frozen ASCII UUID literals,
  collision-separation checks, and a DB example. The router transition probe has a
  DB test at ~line 4966 (`"dedups a pre-upgrade positional router dispatch during the
  transition"`); awakeable adoption at ~line 10588 (`"adopts a generation-0 legacy
  deterministic row"`).

No cross-repository ADR applies to this work.

### Test infrastructure

DB-backed examples use the suite-level template-database fixture from
`keiro-test-support` (`keiro-test-support/src/Keiro/Test/Postgres.hs`): `withMigratedSuite`
starts one cached ephemeral PostgreSQL server, migrates a template database once, and each
example clones a fresh database (`withFreshStore` / `withFreshResourceStore fixture`).
Useful existing helpers in `keiro/test/Main.hs`: `appendCounterEventWithId` (~line 13954)
appends a `CounterEvent` under an explicit `EventId` — exactly how these tests simulate a
pre-upgrade dispatch; `recordedFromEventId`, `sampleUuid`, `uuidLiteral` (~line 11702);
fixtures `counterProcessManager` (~line 13576), `demoRouter` (~line 14533),
`domainProcessManager` (~line 13517), `domainRouter` (~line 13548),
`approvalFlowWithId` (~line 11611).


## Plan of Work

### Milestone 1 — the frozen legacy encoder, pinned by golden ids captured from the pre-upgrade code

Scope: pure code and pure tests only; no behavior change to any dispatch path yet. At the
end of this milestone the repository contains an immutable reproduction of the old
encoder, exported legacy derivations for command ids and awakeable ids, and golden tests
proving — against UUIDs captured from the genuine pre-`f8ca7a16` code — that the
reproduction is exact.

First capture the goldens (exact commands in Concrete Steps): add a worktree at
`f8ca7a16^`, open `cabal repl keiro`, and evaluate the old `deterministicCommandId` and
`deterministicAwakeableId` on the vector table below, recording each printed UUID. The
session must first reproduce the three known ASCII literals; if any differs, stop — the
capture environment is wrong.

The capture vector table. Command vectors all use manager/router name and source event id
fixed as noted; write non-ASCII text with escape sequences to keep the plan and the test
file encoding-proof:

| # | Function (old code) | Inputs | Expectation |
|---|---------------------|--------|-------------|
| C1 | `deterministicCommandId` | `"counter-pm" "order-1" src 0` | must print `ff20892c-6665-5e92-8c99-d1569d2ce629` (cross-check) |
| C2 | `deterministicCommandId` | `"counter-pm" "order-1" src (-1)` | must print `4f3aa6bc-b12c-5dae-8eb5-81f6364f41ef` (cross-check) |
| C3 | `deterministicCommandId` | `"counter-pm" "Jos\x00E9" src 0` | capture (Latin-1) |
| C4 | `deterministicCommandId` | `"counter-pm" "\x4E2D\x6587" src 0` | capture (CJK) |
| C5 | `deterministicCommandId` | `"counter-pm" "\x4E2D\x6587" src (-1)` | capture (CJK manager-state) |
| C6 | `deterministicCommandId` | `"counter-pm" "\x1F600" src 0` | capture (emoji) |
| C7 | `deterministicCommandId` | `"counter-pm" "\x0101" src 0` | capture; must equal C8 |
| C8 | `deterministicCommandId` | `"counter-pm" "\SOH" src 0` | capture; must equal C7 (collision) |
| C9 | `deterministicCommandId` | `"counter-pm" "\x0169ser" src 0` | capture; must equal C10 |
| C10 | `deterministicCommandId` | `"counter-pm" "iser" src 0` | capture; must equal C9 (collision with a pure-ASCII seed) |
| R1 | `deterministicCommandId` | `"demo-router" "g-\x4E2D\x6587" src 0` | capture (router positional, used by the M2 router scenario) |
| A1 | `deterministicAwakeableId` | `(WorkflowName "orderFulfillment") (WorkflowId "wf-1") "approval"` | must print `f677231c-8a27-51b6-9a5e-69015262b26f` (cross-check) |
| A2 | `deterministicAwakeableId` | `(WorkflowName "legacy-awake") (WorkflowId "la-1") "\x627F\x8A8D"` | capture (CJK label, used by the M3 scenario) |
| A3 | `deterministicAwakeableId` | `(WorkflowName "legacy-awake") (WorkflowId "la-1") "caf\x00E9"` | capture (Latin-1 label) |
| A4 | `deterministicAwakeableId` | `(WorkflowName "legacy-awake") (WorkflowId "la-1") "\x4E2D"` | capture; must equal A5 |
| A5 | `deterministicAwakeableId` | `(WorkflowName "legacy-awake") (WorkflowId "la-1") "-"` | capture; must equal A4 (CJK/ASCII collision) |

`src` is `EventId` over UUID `3f2504e0-4f89-51d3-9a0c-0305e82c3301`, the same source id
the existing frozen tests use.

Then the code. In `keiro/src/Keiro/DeterministicId.hs` add (with `import Data.Char
(isAscii)` and `import Data.Text qualified as Text`), alongside `identitySeedBytes`:

```haskell
-- | The frozen pre-0.12 seed encoding: one byte per character, the codepoint
-- modulo 256. This is NOT a general-purpose encoder — it exists only so dedup
-- probes can recompute ids persisted before 'identitySeedBytes' switched the
-- live derivations to UTF-8. It is an immutable artifact pinned by golden
-- tests captured from the pre-change implementation; never edit it, and never
-- use it to derive an id for a new write.
legacySeedBytes :: Text -> [Word8]
legacySeedBytes = fmap (fromIntegral . fromEnum) . Text.unpack

-- | True when the UTF-8 switch moved this seed's ids: the seed contains a
-- character outside ASCII. For ASCII seeds both encoders produce identical
-- bytes, so a legacy probe would repeat the current-id probe exactly.
seedMovedAcrossEncodings :: Text -> Bool
seedMovedAcrossEncodings = not . Text.all isAscii
```

Export both from the module's export list (the module itself stays internal). Update the
module haddock to name both encoders and their roles.

In `keiro/src/Keiro/ProcessManager.hs`, extract the seed construction of
`deterministicCommandId` into a private `commandIdSeed :: Text -> Text -> EventId -> Int
-> Text` (the existing `Text.intercalate ":" [...]` expression, moved verbatim) so the
current and legacy derivations cannot drift, then add and export:

```haskell
-- | The id 'deterministicCommandId' produced before the UTF-8 seed-byte
-- switch (ADR 0024): the same seed, hashed through the frozen truncating
-- 'legacySeedBytes'. Identical to 'deterministicCommandId' for ASCII seeds.
-- Exists only for dedup probes and operator forensics; never an append id.
legacyDeterministicCommandId :: Text -> Text -> EventId -> Int -> EventId
legacyDeterministicCommandId managerName correlationId sourceEventId emitIndex =
  EventId
    $ UUID.V5.generateNamed UUID.V5.namespaceURL
    $ legacySeedBytes
    $ commandIdSeed managerName correlationId sourceEventId emitIndex
```

In `keiro/src/Keiro/Workflow/Awakeable.hs`, likewise extract a private `awakeableSeed ::
WorkflowName -> WorkflowId -> Text -> Text` and add and export
`legacyDeterministicAwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId`
hashing that seed through `legacySeedBytes`, with a haddock mirroring the one above.

Tests, in `keiro/test/Main.hs`, in a new
`describe "Keiro deterministic id legacy-encoding bridge"` block placed directly after
the existing `describe "Keiro deterministic id derivation"` block (~line 9504). Embed the
captured UUIDs as constants, for example:

```haskell
-- Captured from the pre-UTF-8 implementation at f8ca7a16^ via cabal repl
-- (see docs/plans/240-...md, Concrete Steps). Never regenerate from current
-- code; a mismatch means the frozen legacy encoder drifted.
legacyCommandGoldens :: [(Text, Int, UUID)]
legacyCommandGoldens =
  [ ("order-1", 0, uuidLiteral "ff20892c-6665-5e92-8c99-d1569d2ce629"),
    ("order-1", -1, uuidLiteral "4f3aa6bc-b12c-5dae-8eb5-81f6364f41ef"),
    ("Jos\x00E9", 0, uuidLiteral "<C3-captured>")
    -- ... C4-C10 likewise
  ]
```

and assert, in plain `it` examples: every golden row satisfies
`legacyDeterministicCommandId "counter-pm" key src emit == EventId golden`; for the ASCII
rows `legacyDeterministicCommandId` equals `deterministicCommandId`; for every non-ASCII
row the two differ; C7 equals C8, C9 equals C10 under the legacy derivation while the
current derivation separates both pairs; and the same four kinds of assertion for the
awakeable vectors via `legacyDeterministicAwakeableId`. Also pin R1 as a constant
(`legacyRouterPositionalGolden`) with its own equality assertion — Milestone 2's router
scenario uses the *function*, and this pin is what makes that non-circular.

Acceptance: `cabal build keiro` compiles; `cabal test keiro-test` passes with the new
examples listed in its output; deliberately corrupting one byte of a golden makes the
suite fail (spot-check one, then restore).

### Milestone 2 — bridge the six dispatch probe sites, tests first

Scope: the shared probe helper, five DB-backed redelivery scenarios written *before* the
wiring (so their failure against the unbridged runtime is observed and recorded), then
the wiring that turns them green. At the end, every dispatch probe site consults the
legacy id when — and only when — the seed moved.

Add to `keiro/src/Keiro/ProcessManager.hs` (exporting both; `import Data.List.NonEmpty
(NonEmpty (..))` plus a qualified import for `NonEmpty.head`):

```haskell
-- | The probe list for one process-manager write: the current id first (always
-- the append id), then the legacy-encoding id when the seed contains non-ASCII
-- text and the ids therefore differ (ADR 0024's bridge). The single source of
-- truth for bridged dedup; plan 242's consolidated dispatch helper must derive
-- its probes here.
deterministicCommandIdProbes :: Text -> Text -> EventId -> Int -> NonEmpty EventId
deterministicCommandIdProbes managerName correlationId sourceEventId emitIndex =
  let seed = commandIdSeed managerName correlationId sourceEventId emitIndex
      current = EventId (UUID.V5.generateNamed UUID.V5.namespaceURL (identitySeedBytes seed))
      legacy = EventId (UUID.V5.generateNamed UUID.V5.namespaceURL (legacySeedBytes seed))
   in current :| [legacy | seedMovedAcrossEncodings seed]

-- | Probe the target stream for each candidate id in order; return the first
-- match. The bridged replacement for a lone 'eventAlreadyIn' call at dispatch
-- probe sites. Legacy candidates are immutable history (nothing writes
-- legacy-encoded ids), so ordering and non-transactionality are safe.
firstExistingEventId ::
  (Store :> es) =>
  RunCommandOptions ->
  StoreTypes.StreamName ->
  NonEmpty EventId ->
  Eff es (Maybe EventId)
```

(`firstExistingEventId` folds `eventAlreadyIn` over the list with short-circuiting.)
Refactor `deterministicCommandId` to be `NonEmpty.head . deterministicCommandIdProbes`
— or keep its body and add an equality test; either way the golden freeze tests hold it
fixed.

Now the scenarios, all in `keiro/test/Main.hs`, all following the shape of the existing
transition test at ~line 4966: derive the pre-upgrade id, plant it with
`appendCounterEventWithId`, redeliver, assert a duplicate verdict and an unchanged
stream. Add a test-only process manager `unicodeCounterProcessManager` — a record update
of `counterProcessManager` with `name = "unicode-pm"`, `correlate = const
"\x4E2D\x6587-42"`, `streamFor = const (stream "pm:counter-unicode")`, and a handle whose
single `PMCommand` targets `stream "counter-target-unicode"` — so the correlation key is
non-ASCII while stream names stay simple.

Scenario 1, PM state and command redelivery: plant
`legacyDeterministicCommandId "unicode-pm" "\x4E2D\x6587-42" (EventId sampleUuid) (-1)`
in `pm:counter-unicode` and the emit-0 id in `counter-target-unicode`; run
`runProcessManagerOnce defaultRunCommandOptions unicodeCounterProcessManager sourceEvent
(CounterAdded 9)`; expect `managerResult` to be `PMStateDuplicate legacyManagerId`,
`commandResults` to be `[PMCommandDuplicate legacyCommandId]`, and both streams to still
hold exactly one event. Scenario 2, router redelivery: mirror the ~4966 test with
`RouteGroup "g-\x4E2D\x6587"`, a router-target row mapping that group to
`"transition-unicode-target"`, and the planted id
`legacyDeterministicCommandId "demo-router" "g-\x4E2D\x6587" (sourceEvent ^. #eventId) 0`
(pinned as R1); expect `PMCommandDuplicate` of that id and one event. Scenario 3, domain
PM redelivery: same as Scenario 1 through `runDomainProcessManagerOnce` with
`domainProcessManager` and a `DomainDispatchInput "\x4E2D\x6587-9" [...]` input (its
correlate/streamFor derive names from the key; the planted target stream is
`domain-pm-target:\x4E2D\x6587-9:0`), expecting `DomainPMCommandDuplicate`. Scenario 4,
domain router redelivery: same through `runDomainRouterOnce` with `domainRouter`.
Scenario 5, ASCII behavior byte-identical: no new test needed — the acceptance is that
every existing dedup and freeze test passes untouched, plus one new pure assertion that
`deterministicCommandIdProbes` returns a singleton for an ASCII seed and a two-element
list (legacy second) for a non-ASCII seed.

Run the four DB scenarios now, before wiring, and record the transcript in Surprises &
Discoveries: each must fail with a `PMCommandAppended`/`DomainPMCommandHandled` where a
duplicate was expected, and a stream length of 2 — the defect, demonstrated.

The wiring. In `runProcessManagerOnce` and `advanceDomainProcessManager`: build
`managerProbes = deterministicCommandIdProbes (manager ^. #name) correlationId
(sourceEvent ^. #eventId) (-1)`; keep `managerEventId = NonEmpty.head managerProbes` as
the append id; replace the `eventAlreadyIn` call with `firstExistingEventId options
managerStreamName managerProbes`, and on `Just matchedId` finish with `PMStateDuplicate
matchedId`. In `dispatchCommand` (legacy PM) and `dispatchDomainProcessManagerCommand`:
the same pattern for the emit-index probes, reporting `PMCommandDuplicate matchedId` /
`DomainPMCommandDuplicate matchedId`. In `Keiro.Router`'s `dispatchRouterCommands` and
`dispatchDomainRouterCommand`: change `legacyCommandId` to be derived with
`legacyDeterministicCommandId` (import it beside the existing `deterministicCommandId`
import from `Keiro.ProcessManager`), and replace the two-step
`commandAlreadyProcessed`/`legacyAlreadyProcessed` sequence with one
`firstExistingEventId options targetStreamName (commandId :| [legacyCommandId])` call
whose `Just matchedId` produces the duplicate result — preserving today's semantics of
reporting whichever id matched. The append id everywhere remains the current id;
`confirmBenignDuplicate` call sites are untouched.

Acceptance: the four scenarios pass; `cabal test keiro-test` fully green, including the
frozen ASCII literals, the ~4966 positional transition test (its ASCII legacy id is
byte-identical under the new derivation), and the concurrent-duplicate tests at ~4252.

### Milestone 3 — bridge awakeable adoption

Scope: the generation-0 adoption path in `keiro/src/Keiro/Workflow/Awakeable.hs`. In
`allocateAwakeableId`, for `gen <= 0`: look up `deterministicAwakeableId name wid label`
first (rows written by current code and by all-ASCII history); on a miss, and only when
`seedMovedAcrossEncodings` holds for the awakeable seed, look up
`legacyDeterministicAwakeableId name wid label` and adopt that row; otherwise allocate a
fresh v4 id as today. Update the `deterministicAwakeableId` haddock paragraph that
currently says a pre-change non-ASCII row "is no longer adopted" to describe the bridge.

Test, mirroring `"adopts a generation-0 legacy deterministic row"` (~line 10588): a
workflow body cloned from `approvalFlowWithId` with label `StepName "\x627F\x8A8D"`;
register a row under the A2 golden id (use the captured literal); run the workflow to
`Suspended`; assert the allocated id *equals* the legacy id (adoption, not fresh
allocation); `signalAwakeable` under the legacy id returns `True`; the next run
completes. The existing ASCII adoption test must stay green unchanged.

Acceptance: both adoption tests pass; before the wiring, the new test fails at the
id-equality assertion (fresh v4 id instead of the legacy id) — observe and record it.

### Milestone 4 — documentation, the unified window, and release notes

Scope: make the bridge and its end-of-life operator-checkable. Update
`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`:
amend the Consequences bullets that called the duplicate-command emission and the lost
awakeable adoption "bounded and accepted" (the 2026-08-11 review reclassified them as a
defect), and add a section recording: the frozen `legacySeedBytes` artifact and its
golden pinning; the bridged probe (`deterministicCommandIdProbes` /
`firstExistingEventId` / `legacyDeterministicAwakeableId`) and the guarded form; the
router positional probe now deriving through the legacy encoder and why that is complete
(no release ever wrote UTF-8 positional ids); the residual legacy-collision ambiguity
accepted for the window; and the unified removal criteria — the bridge and the positional
probe are removed together, no earlier than one minor release after 0.12.0.0, and only
when an operator attests that no pre-upgrade dispatch remains within the dedup horizon:
every at-least-once channel (Kafka consumer groups, pgmq queues and archives, timers,
planned operator replays) can no longer redeliver any source event first delivered before
the upgrade. Append the matching `Update` line to `docs/adr/log.md` (mirror the existing
entries' format, citing plan 240) and run `just adr-validate`.

In `keiro/CHANGELOG.md` under `## Unreleased`, add a `### Fixed` entry (create the
subsection if absent) telling upgraders what is bridged, in substance: deployments with
non-ASCII correlation keys, router keys, or awakeable labels no longer double-apply
commands (or orphan in-flight awakeables) when a source event delivered before the UTF-8
id-encoding switch is redelivered after it; the runtime probes the pre-switch id
alongside the current one, at no extra cost for ASCII seeds; see ADR 0024 for the
bridge's removal criteria. Update the `Router.hs` transition comment (~line 326) and the
`deterministicCommandId`/`legacyDeterministicCommandId` haddocks to point at ADR 0024's
criteria instead of "remove in a later release". Update MasterPlan 37: EP-4 registry row
status and the EP-4 progress checkbox. Run `just haskell-test` for the full gate, remove
the capture worktree, then perform the ADR distillation pass and write the Outcomes &
Retrospective entry.

Acceptance: `just adr-validate` and `just haskell-test` green; the ADR names checkable
removal criteria; the CHANGELOG entry exists under Unreleased.


## Concrete Steps

All commands run from the repository root. The DB-backed suite needs the same environment
the existing suite already uses (the repo dev shell provides PostgreSQL for
`ephemeral-pg`); nothing new is required.

Capture the goldens (Milestone 1):

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git worktree add ../keiro-pre-utf8 f8ca7a16^
cd ../keiro-pre-utf8
cabal repl keiro
```

In the repl (escape sequences keep this terminal-encoding-proof):

```haskell
:set -XOverloadedStrings
import Keiro.ProcessManager (deterministicCommandId)
import Keiro.Workflow.Awakeable (deterministicAwakeableId, awakeableIdToUuid)
import Keiro.Workflow (WorkflowName (..), WorkflowId (..))
import Kiroku.Store.Types (EventId (..))
import Data.Maybe (fromJust)
import qualified Data.UUID as UUID
let src = EventId (fromJust (UUID.fromString "3f2504e0-4f89-51d3-9a0c-0305e82c3301"))
let showCmd n c i = UUID.toString ((\(EventId u) -> u) (deterministicCommandId n c src i))
let showAwk n w l = UUID.toString (awakeableIdToUuid (deterministicAwakeableId (WorkflowName n) (WorkflowId w) l))
showCmd "counter-pm" "order-1" 0
```

Expected first outputs (the cross-checks; stop if these differ):

```text
"ff20892c-6665-5e92-8c99-d1569d2ce629"
```

then `showCmd "counter-pm" "order-1" (-1)` must print
`"4f3aa6bc-b12c-5dae-8eb5-81f6364f41ef"` and
`showAwk "orderFulfillment" "wf-1" "approval"` must print
`"f677231c-8a27-51b6-9a5e-69015262b26f"`. Evaluate every remaining row of the capture
table (C3–C10, R1, A2–A5) with `showCmd`/`showAwk`, record each UUID, and confirm the
in-session collision equalities (C7=C8, C9=C10, A4=A5). Transfer the values into the test
constants; the worktree stays until Milestone 4's final verification, then:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git worktree remove ../keiro-pre-utf8
```

Build and test loop (every milestone):

```bash
cabal build keiro
cabal test keiro-test
```

To iterate on just the new pure block or the redelivery scenarios (hspec `--match`
selects by describe/it text; the suite fixture still starts once):

```bash
cabal test keiro-test --test-option=--match --test-option="legacy-encoding bridge"
```

A passing suite ends with a summary of the form (counts will differ):

```text
N examples, 0 failures
Test suite keiro-test: PASS
```

Milestone 4 gates:

```bash
just adr-validate
just haskell-test
```

Commit per milestone with Conventional Commits messages, e.g.
`feat(process-manager): pin the frozen legacy seed encoder with captured goldens` (M1),
`fix(dispatch): bridge dedup probes across the UTF-8 id-encoding switch` (M2),
`fix(workflow): bridge legacy awakeable adoption across the encoding switch` (M3),
`docs(adr): record the deterministic-id dedup bridge and its removal window` (M4).


## Validation and Acceptance

The change is effective when the following behaviors hold, each observable from the test
suite output.

First, the defect is demonstrated before it is fixed: with Milestone 1 landed but
Milestone 2's wiring not yet applied, the four redelivery scenarios fail, each reporting
an appended/handled result where a duplicate was expected and a target-stream read of two
events. A representative expected failure line:

```text
expected transition duplicate, got Right (RouterResult [PMCommandAppended ...])
```

Record these transcripts in Surprises & Discoveries — they are the evidence that the
scenarios genuinely exercise the defect rather than vacuously passing.

Second, after Milestone 2: redelivering a source event whose command was persisted under
the pre-upgrade encoding yields `PMCommandDuplicate`/`DomainPMCommandDuplicate`/
`PMStateDuplicate` carrying the *legacy* id, and the target stream holds exactly one
event — for the legacy PM runner, the domain PM runner, the router, and the domain
router. After Milestone 3: a generation-0 awakeable row registered under the
old-encoding id for a CJK label is adopted (allocated id equals the planted legacy id),
its signal returns `True`, and the workflow completes.

Third, ASCII identity is untouched: the frozen literals under
`describe "Keiro deterministic id derivation"` pass unmodified (they were captured before
the encoding switch and double as the bridge's no-op proof), the pre-existing positional
router transition test at ~line 4966 passes unmodified, and
`deterministicCommandIdProbes` returns a singleton for ASCII seeds.

Fourth, the frozen legacy encoder is pinned: every golden equality in the
`legacy-encoding bridge` block passes, the collision pairs are equal under the legacy
derivation and distinct under the current one, and (spot-check during M1) corrupting a
golden byte fails the suite.

Final gate: `just haskell-test` (all suites) and `just adr-validate` succeed, ending in
`PASS` lines for `keiro-test`, `keiro-pgmq-test`, `keiro-ops-test`, `keiro-dsl` tests,
and `jitsurei-test`.


## Idempotence and Recovery

Every step is safe to repeat. The capture worktree is additive (`git worktree add` fails
harmlessly if the path exists; `git worktree remove` then re-add recovers a broken one)
and read-only with respect to the main tree; captured goldens are outputs of pure
functions at a fixed commit, so a re-capture always yields the same values — if it does
not, the environment (not the plan) is wrong. Code changes are additive (new functions,
widened probes) and land milestone by milestone with a green suite at each boundary, so
`git revert` of any milestone commit is a clean rollback. DB tests clone fresh databases
per example from the suite template, so reruns cannot interfere with one another; there
are no schema migrations in this plan. If Milestone 2 is interrupted mid-wiring, the
probes helper and scenarios are inert additions — the suite simply shows the scenarios
still failing, which the Progress checklist records as the resume point. The only
mutation with cross-session effect is documentation (ADR/CHANGELOG/MasterPlan edits),
which is ordinary reviewable text.


## Interfaces and Dependencies

No new package dependencies: `uuid` (`Data.UUID.V5`), `text`, `bytestring`, `base`
(`Data.List.NonEmpty`, `Data.Char.isAscii`) and `kiroku-store`
(`Kiroku.Store.Read.eventExistsInStream`, `Kiroku.Store.Types.EventId`) are all already
in `keiro/keiro.cabal`. Test infrastructure is the existing `keiro-test-support` fixture
(`Keiro.Test.Postgres`) — the suite-level ephemeral-pg template-database pattern; no new
fixture kinds.

At the end of Milestone 1 these exist:

```haskell
-- keiro/src/Keiro/DeterministicId.hs (internal module; stays in other-modules)
legacySeedBytes :: Text -> [Word8]
seedMovedAcrossEncodings :: Text -> Bool

-- keiro/src/Keiro/ProcessManager.hs (added to the export list)
legacyDeterministicCommandId :: Text -> Text -> EventId -> Int -> EventId

-- keiro/src/Keiro/Workflow/Awakeable.hs (added to the export list)
legacyDeterministicAwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId
```

At the end of Milestone 2, additionally (both exported from `Keiro.ProcessManager`; the
one place plan 242's consolidated dispatch helper must call — see Decision Log):

```haskell
deterministicCommandIdProbes :: Text -> Text -> EventId -> Int -> NonEmpty EventId

firstExistingEventId ::
  (Store :> es) =>
  RunCommandOptions ->
  StoreTypes.StreamName ->
  NonEmpty EventId ->
  Eff es (Maybe EventId)
```

with all six probe sites (`runProcessManagerOnce` state and dispatch,
`advanceDomainProcessManager`, `dispatchDomainProcessManagerCommand`,
`dispatchRouterCommands`, `dispatchDomainRouterCommand`) routed through
`firstExistingEventId`, and `Keiro.Router` importing `legacyDeterministicCommandId`.
Milestone 3 changes only the internal `allocateAwakeableId`. Existing public signatures,
result types (`PMCommandResult`, `DomainPMCommandResult`, `PMStateResult`), append-id
choices, and `confirmBenignDuplicate` are unchanged throughout.

---

Revision note (2026-08-11): fleshed out from the init-script skeleton into the full plan:
researched the defect across `DeterministicId.hs`, `ProcessManager.hs`, `Router.hs`, and
`Awakeable.hs` (including the pre-`f8ca7a16` encoder and the 0.2.0.0 router-id history),
resolved the design (frozen legacy encoder; guarded dual probe; router probe re-derived
through the legacy encoder; single-place definition for plan 242; unified removal
window), defined the capture-based golden-vector protocol, and seeded the living
sections. Reason: bring the plan to the fully self-contained state PLANS.md requires
before implementation starts.
