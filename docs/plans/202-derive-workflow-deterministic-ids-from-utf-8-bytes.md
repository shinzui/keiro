---
id: 202
slug: derive-workflow-deterministic-ids-from-utf-8-bytes
title: "Derive workflow deterministic ids from UTF-8 bytes"
kind: exec-plan
created_at: 2026-08-06T00:12:21Z
intention: "intention_01kza6gjs5eg79n2hyrah7wnnn"
master_plan: "docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md"
---

# Derive workflow deterministic ids from UTF-8 bytes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro derives several *deterministic ids* — stable UUIDs computed from text so that
retried or concurrent writes of the same logical thing collapse to one row. Four
derivations share the same seed-construction bug: they turn the seed text into bytes
with `fmap (fromIntegral . fromEnum) . Text.unpack`, which truncates every character
to its Unicode codepoint modulo 256. Any two texts whose characters agree modulo 256
produce the same bytes — `"ā"` (U+0101) and `"\SOH"` (U+0001) collide, as do
distinct CJK step names — so two *different* workflow steps, sleep timers,
awakeables, or process-manager commands can be assigned the same UUID. For workflow
journal events the collision does not corrupt replay (the step index is keyed by the
full step-name text), but it wedges the append path: the event store rejects the
second append as a duplicate event id, every retry hits the same rejection, and the
workflow rides its crash-backoff ladder into terminal failure. For process-manager
command ids the deterministic id *is* the idempotency mechanism, so a collision
suppresses a legitimate command.

After this plan, all four derivations hash the text's UTF-8 bytes. For pure-ASCII
input — every deployment we know of — the bytes are identical, so every existing id
is unchanged and no migration is needed. Non-ASCII inputs get collision-free ids.
The derivation rule becomes a recorded, frozen contract (an ADR), because these ids
are replay identity: they must never change for a given input across deploys.


## Progress

- [ ] All four derivations hash UTF-8 bytes via a shared helper.
- [ ] Byte-compatibility (ASCII) and collision-regression (non-ASCII) tests green.
- [ ] ADR recorded and `just adr-validate` green; CHANGELOG note added.
- [ ] Full suite green: `cabal test keiro-test`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fix by switching to UTF-8 bytes rather than versioning the derivation
  or namespacing new ids.
  Rationale: UTF-8 agrees byte-for-byte with the current derivation on ASCII, so
  ASCII deployments see no identity change at all; a versioned scheme would burden
  every deployment with a cutover for a defect that only affects non-ASCII inputs.
  Date: 2026-08-06

- Decision: Include `Keiro.ProcessManager.deterministicCommandId` even though it is
  outside the workflow engine.
  Rationale: Same defect, same fix, and the ADR should freeze the whole
  identity-derivation family in one place so the process-manager path cannot
  silently diverge (MasterPlan 30 Decision Log, 2026-08-06).
  Date: 2026-08-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

A *deterministic id* here is a version-5 UUID: `Data.UUID.V5.generateNamed
namespace bytes` hashes a namespace UUID plus a byte list into a stable UUID.
Version-5 UUIDs are pure functions of their input bytes, which is the point — the
same seed text must always yield the same id so that at-least-once writers collapse
to exactly-once rows. The four call sites, all following the same pattern of
building a `:`-joined seed string and converting it with
`fmap (fromIntegral . fromEnum) . Text.unpack`:

- `deterministicJournalId` in `keiro/src/Keiro/Workflow.hs` (seed
  `keiro:workflow:<name>:<id>:<generation>:<stepName>`) — the event id for every
  workflow journal append. Idempotence of journal appends does **not** rest on it
  alone (the append transaction re-checks the `keiro.keiro_workflow_steps` index by
  full text first, per
  `docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md`),
  but the event store enforces global event-id uniqueness, so a cross-step
  collision turns every append of the second step into a rejected duplicate:
  `JournalAppendConflict`, surfaced as `WorkflowJournalAppendError`, retried into
  terminal failure by the resume worker.
- `sleepTimerId` in `keiro/src/Keiro/Workflow/Sleep.hs` (seed
  `keiro:workflow-sleep:<name>:<id>[:<generation>]:<sleepStep>`) — the
  `keiro.keiro_timers` primary key that makes sleep arming first-insert-wins. A
  collision merges two different sleeps into one timer row.
- `deterministicAwakeableId` in `keiro/src/Keiro/Workflow/Awakeable.hs` (seed
  `keiro:awakeable:<name>:<id>:<label>`) — legacy generation-0 adoption lookups
  only; new allocations are random v4 UUIDs. A collision adopts the wrong row.
- `deterministicCommandId` in `keiro/src/Keiro/ProcessManager.hs` (seed built from
  the process-manager name, correlation id, source event id, and emit index) — the
  *only* idempotency mechanism for process-manager command emission: the command id
  becomes the kiroku `event_id`, and a retried emission is deduplicated by the
  store's `DuplicateEvent`. A collision between two *different* commands suppresses
  the second one entirely. (Read the actual seed shape from the source before
  editing; the file also documents the contract in its haddocks.)

Why `fromEnum` truncation matters: `Text.unpack` yields `[Char]`, `fromEnum`
yields the full codepoint as `Int`, and `fromIntegral` to the `Word8` the UUID
library expects keeps only the low 8 bits. All codepoints ≥ 256 alias into the
0–255 range. None of the identity constructors restrict inputs to ASCII:
`mkWorkflowName`/`mkWorkflowId` (`keiro/src/Keiro/Workflow/Types.hs`) reject only
structural separators, and step names, sleep names, awakeable labels, and patch ids
are arbitrary `Text`.

The fix target is `Data.Text.Encoding.encodeUtf8` followed by
`Data.ByteString.unpack`, which yields the UTF-8 `[Word8]`. For ASCII text, UTF-8
bytes equal codepoint values, so the derivation is unchanged — this is the
compatibility argument that makes the fix deployable without migration. For
non-ASCII text the ids change; the consequences are bounded and documented in the
ADR (see Plan of Work): in-flight non-ASCII workflow journals still replay
correctly (replay is keyed by step-name text, and the in-transaction index check
fires before the event id matters), an in-flight non-ASCII sleep may arm one
duplicate timer whose fire collapses in the idempotent append, a generation-0
non-ASCII awakeable registered under the old derived id is no longer adopted, and
an in-flight non-ASCII process-manager emission retried across the deploy boundary
can emit a duplicate command (at-least-once, exactly the guarantee the rest of the
system already tolerates).

Relevant ADRs, per `agents/skills/exec-plan/ADR.md`: ADR 5 (the step index is
authoritative for journal idempotence — quoted above); no existing ADR records the
id-derivation contract, which is the gap this plan closes with a new record. The
`docs/adr/` bundle is profile-governed OKF: allocate the id with `okf id next
docs/adr --profile docs/adr/profile.dhall ADR`, maintain `log.md` with `okf log
add`, and validate with `just adr-validate`. Do not guess the number (MasterPlan 30
expects this plan's record and plan 200's record to be allocated in whatever order
the plans actually land).

Tests are in `keiro/test/Main.hs` (`cabal test keiro-test` provisions ephemeral
Postgres via `keiro-test-support`), though most of this plan's tests are pure and
need no database.


## Plan of Work

One milestone; the change is small and must land atomically.

Add a shared helper — the natural home is `keiro/src/Keiro/Prelude.hs` if it
already aggregates such utilities, otherwise a small internal module or a
per-module copy is acceptable; prefer one definition imported by all four sites:

```haskell
-- | The UTF-8 bytes of a deterministic-id seed. Deterministic ids are replay
-- identity: this derivation is frozen by the identity-derivation ADR and must
-- never change for a given input.
identitySeedBytes :: Text -> [Word8]
identitySeedBytes = ByteString.unpack . Text.Encoding.encodeUtf8
```

Replace `fmap (fromIntegral . fromEnum) $ Text.unpack $ ...` with
`identitySeedBytes $ ...` in `deterministicJournalId`
(`keiro/src/Keiro/Workflow.hs`), `sleepTimerId`
(`keiro/src/Keiro/Workflow/Sleep.hs`), `deterministicAwakeableId`
(`keiro/src/Keiro/Workflow/Awakeable.hs`), and `deterministicCommandId`
(`keiro/src/Keiro/ProcessManager.hs`). Search the repository for any further
`fromIntegral . fromEnum` feeding `UUID.V5.generateNamed` (`grep -rn
'generateNamed' keiro/src keiro-pgmq/src`) and convert any stragglers the audit
did not list, noting them in Surprises & Discoveries.

Update each function's haddock: the derivation hashes UTF-8 bytes; cite the new
ADR by relative path.

Write the ADR (allocated number from `okf id next`; title along the lines of
"Deterministic ids hash UTF-8 seed bytes and are frozen replay identity"):
context (the truncation defect and its wedge/suppression consequences), decision
(UTF-8 bytes; the four derivations named by module path; the derivation is frozen
— any future change requires an explicit versioned migration story), and
consequences (ASCII ids are byte-identical so existing deployments are
unaffected; the bounded non-ASCII in-flight consequences listed in Context and
Orientation, recorded as accepted). Run `okf log add` and `just adr-validate`.

Add a `docs`/`fix` note to `keiro/CHANGELOG.md`: non-ASCII deterministic ids
change derivation; ASCII unchanged.

Tests, in `keiro/test/Main.hs` (pure group, no DB):

- ASCII freeze: for a representative set of ASCII seeds (typical name/id/step
  combinations, including every reserved step name in
  `Keiro.Workflow.Types`), assert the new `deterministicJournalId` (and
  `sleepTimerId`, `deterministicCommandId`) equals a *hard-coded expected UUID*
  captured from the current implementation before the change (generate the
  fixtures by evaluating the old code in `cabal repl keiro` and paste them into
  the test). Hard-coding, rather than comparing against a reimplementation of the
  old formula, is what actually freezes the contract.
- Collision regression: assert `deterministicJournalId name wid gen "ā"` differs
  from `deterministicJournalId name wid gen "\SOH"`, and one analogous pair for a
  multi-character CJK step name; assert the equivalent for `sleepTimerId` and
  `deterministicCommandId`.
- Property (if the suite already depends on a property-testing library — check
  `keiro/keiro.cabal` before adding a dependency; skip the property rather than
  adding one): for arbitrary `Text` inputs, equal inputs give equal ids and the
  documented seed components are order-sensitive.

Acceptance: fixtures prove ASCII ids did not move; collision pairs prove
non-ASCII ids now differ; the full suite stays green (every existing test uses
ASCII identities, so any failure indicates an accidental derivation change —
treat it as a stop-the-line signal, not a fixture to update).


## Concrete Steps

All commands run from the repository root.

```bash
# capture ASCII fixtures BEFORE editing:
cabal repl keiro
-- ghci> deterministicJournalId (WorkflowName "orderFulfillment") (WorkflowId "wf-1") 0 "charge-card"
# ... paste outputs into the new test group ...

cabal build keiro
cabal test keiro-test
okf id next docs/adr --profile docs/adr/profile.dhall ADR   # allocate the ADR number
just adr-validate
```

Commit once, conventional-commit style:

```text
fix(workflow): derive deterministic ids from UTF-8 seed bytes

MasterPlan: docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md
ExecPlan: docs/plans/202-derive-workflow-deterministic-ids-from-utf-8-bytes.md
Intention: intention_01kza6gjs5eg79n2hyrah7wnnn
```


## Validation and Acceptance

Acceptance is behavioral on both sides of the compatibility line: the hard-coded
ASCII fixtures (captured from the pre-change implementation) still match, proving
no deployed identity moved; and the collision pairs that used to produce equal
UUIDs now produce distinct ones, proving the wedge class is closed. A quick
end-to-end demonstration: run a workflow whose two step names are `"ā"` and
`"\SOH"` against the test store — before this change the second step's append
fails with `WorkflowJournalAppendError` (duplicate event id); after, the workflow
completes. Include that scenario as one of the DB-backed examples if cheap.


## Idempotence and Recovery

Code-only; no migration. Reverting restores the old derivation exactly (ASCII ids
never moved either way). The frozen-fixture test is the guard against accidental
future drift; the ADR is the guard against deliberate drift without a migration
story.


## Interfaces and Dependencies

No new libraries (`bytestring` and `text` are existing dependencies). End state:
`identitySeedBytes :: Text -> [Word8]` shared by `Keiro.Workflow`,
`Keiro.Workflow.Sleep`, `Keiro.Workflow.Awakeable`, and `Keiro.ProcessManager`;
all four public derivation functions keep their exact signatures. No other plan in
MasterPlan 30 may touch id derivation (see the MasterPlan's Integration Points).
