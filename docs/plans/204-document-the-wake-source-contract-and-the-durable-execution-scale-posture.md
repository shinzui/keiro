---
id: 204
slug: document-the-wake-source-contract-and-the-durable-execution-scale-posture
title: "Document the wake-source contract and the durable-execution scale posture"
kind: exec-plan
created_at: 2026-08-06T00:12:21Z
intention: "intention_01kza6gjs5eg79n2hyrah7wnnn"
master_plan: "docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md"
---

# Document the wake-source contract and the durable-execution scale posture

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The 2026-08 durable-execution re-audit found that the engine's *written* contracts
lag its actual ones in four places, and that the gap is exactly where a third-party
author or an adopting team would get hurt. First, the module documentation in
`keiro/src/Keiro/Workflow.hs` invites wake-source authors to build on
`appendJournalEntry` without stating the property that makes the engine's own wake
sources safe: each keeps a durable row that the await's arming action re-checks on
every resume, which is what survives the race between a wake append and a
`continueAsNew` generation rotation. A naive wake source built on the append helper
alone can strand its completion on a closed generation. Second, nothing tells a
workflow author that rotating with `continueAsNew` while an awakeable is
outstanding *abandons* the handed-out id (the next generation re-runs the
allocation step and hands out a fresh id). Third, the user docs advertise
awakeable/human-in-the-loop workflows without stating what a parked workflow costs
(today: a full re-run per resume pass) or that `snapshotPolicy` should not be left
at `Never` for suspend-heavy or long-journal workflows. Fourth, small haddock drift:
`recordStepTx`'s comment still describes the pre-generation conflict key, and the
GC module does not state that collecting a terminal parent detaches its still-running
children's link rows on purpose.

After this plan, an author can write a correct custom wake source from the docs
alone, an adopter can predict the engine's idle cost and configure snapshots
accordingly, and the drifted comments match the code. Docs-only: no behavior
changes.


## Progress

- [ ] Wake-source authoring contract written into `Keiro.Workflow`'s module haddock and the durable-workflows guide.
- [ ] `continueAsNew` awakeable-abandonment semantics documented (haddock + guide).
- [ ] Scale posture and snapshot-policy guidance in `docs/user/roadmap.md`, `docs/user/production-status.md`, and both durable-workflows docs.
- [ ] Haddock drift fixed (`recordStepTx`, GC parent/child detachment note).
- [ ] `cabal haddock keiro` clean; ADR citations verified; full suite green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Keep this plan docs-only; behavioral gaps discovered while writing are
  filed against the sibling plans (or the MasterPlan) rather than fixed here.
  Rationale: Documentation that quietly changes behavior is the worst of both;
  the MasterPlan's decomposition gives every behavioral fix a tested home.
  Date: 2026-08-06

- Decision: Write the scale-posture text to match whatever has actually landed at
  implementation time, checking the status of plans 200 and 203 in the MasterPlan
  registry first.
  Rationale: The posture differs materially before and after exact discovery
  (plan 200) and concurrency/batching (plan 203); the soft dependency is
  documented in the MasterPlan, and honest-now beats aspirational.
  Date: 2026-08-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The engine is `keiro/src/Keiro/Workflow.hs` plus the modules under
`keiro/src/Keiro/Workflow/`. Vocabulary this plan documents (all defined in those
modules today): a *wake source* is anything that resolves a suspended `awaitStep`
by appending a `StepRecorded` journal event under the awaited step name — the
built-ins are sleep timers (`Keiro.Workflow.Sleep`), awakeables
(`Keiro.Workflow.Awakeable`), and child workflows (`Keiro.Workflow.Child`). The
*arm* is the idempotent action `awaitStep` runs on a miss, re-run on every resume
until the result is journaled. A *generation* is one physical journal stream of a
logical workflow; `continueAsNew` closes the current generation and seeds the next
(`workflowGenerationStreamName` in `keiro/src/Keiro/Workflow/Types.hs`).

The race the contract must state: `appendJournalEntry` /
`appendJournalEntryReturningId` (`keiro/src/Keiro/Workflow.hs`) resolve the
*current* generation with a `MAX(generation)` query and then append in a separate
transaction. A rotation committing between the two strands the completion on the
closed generation, and the generation-scoped step-index fallback of
`docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md`
deliberately does not let an old generation resolve a new one. The engine's own
sources are immune because each keeps a durable row that outlives generations —
the timer row, the `keiro_awakeables` row, the `keiro_workflow_children` row — and
each arm re-checks that row and re-delivers onto the *current* generation
(`docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md`
is the governing record: "wake-source rows govern exposure and terminal races").
That obligation — durable row plus arm-side re-check/repair — is the contract a
third-party wake source must satisfy, and it is currently implicit. If plan 200
(`docs/plans/200-make-suspended-workflows-quiescent-and-discovery-index-aligned.md`)
has landed, the contract gains a second clause recorded in that plan's ADR: every
row-lifecycle transition must also flip the owner's `keiro_workflows` instance row
so exact discovery notices; cite that ADR by whatever number plan 200 allocated.

Awakeable abandonment on rotation: `awakeableNamed` journals a *random* id under
an `awkid:<label>` allocation step, then awaits `awk:<uuid>`. After
`continueAsNew`, the next generation's journal has no allocation step, so the
body re-runs it, allocates a fresh id, and hands *that* out; a signal against the
old id still settles its row but resolves nothing the new generation awaits. This
is coherent attach-vs-abandon semantics (the old promise is simply orphaned until
GC), but only the code knows it today. The parallel child-side semantics *are*
documented on `spawnChild` ("to run a fresh child after continueAsNew, derive a
fresh child id from the carried seed") — the awakeable side should point the same
direction: derive re-notification from the re-run allocation step.

Scale posture, as established by the re-audit (numbers belong in the docs, not
just this plan): discovery returns every non-terminal workflow whose `wake_after`
is null or due; only sleeps set `wake_after`; so each workflow suspended on an
awakeable or child is claimed, fully journal-replayed (`snapshotPolicy` defaults
to `Never` — `WorkflowRunOptions` in `keiro/src/Keiro/Workflow.hs`), re-armed,
and re-suspended on every pass (default 1 s; every store append under
`runWorkflowResumeWorkerPush`). Roughly a dozen round-trips per parked workflow
per pass. Plan 200 replaces this with exact discovery; plan 203 adds bounded
concurrency and batched timer drains. The user-facing docs to update:
`docs/user/durable-workflows.md` (reference), `docs/guides/durable-workflows.md`
(guide), `docs/user/roadmap.md` (the Phase-5 / capability-matrix rows), and
`docs/user/production-status.md` (adoption posture). The snapshots reference
`docs/user/snapshots.md` already carries workflow snapshot mechanics; link, do not
duplicate.

Haddock drift: `recordStepTx` in `keiro/src/Keiro/Workflow/Schema.hs` says the
upsert conflicts on `(workflow_id, step_name)` — the key has been
`(workflow_id, workflow_name, generation, step_name)` since migration
`keiro-migrations/migrations/0008-keiro-workflow-generation.sql`. The GC module
header (`keiro/src/Keiro/Workflow/Gc.hs`) protects completed children of live
parents but does not say the converse: collecting an eligible terminal *parent*
deletes link rows of its still-running children (they finish as ordinary
workflows; nothing awaits them) — intended, per the re-audit's verification, and
worth one sentence so the next reviewer does not re-litigate it.

ADR handling per `agents/skills/exec-plan/ADR.md`: this plan creates no ADR — the
contracts it documents live in ADRs 5–7 and (if landed) plan 200's record; the
plan's job is citing them from author-facing surfaces. If writing reveals a
contract no ADR records, stop and add it to the MasterPlan's Surprises &
Discoveries rather than minting an ADR from a docs plan.


## Plan of Work

One milestone per surface; all independent, so order is free. Since prose is the
deliverable, every section below states what the text must *cover*, not exact
wording.

Module haddocks. In `keiro/src/Keiro/Workflow.hs`: extend the "Contract recap for
downstream plans" block with a "custom wake sources" paragraph covering the three
obligations — (1) keep a durable row keyed by the logical workflow (not the
generation) that records the pending/resolved/abandoned lifecycle; (2) deliver
results by appending under the awaited step name via
`appendJournalEntry`, understanding that the append targets the current
generation *at append time* and can lose a rotation race; (3) make the await's
arm re-check the row and re-deliver (that is what makes (2)'s race harmless), and
— if plan 200 has landed — flip the instance row on every lifecycle transition so
exact discovery notices, citing the ADRs by relative path. On
`appendJournalEntryReturningId`, add the one-sentence rotation caveat directly.
On `continueAsNew`, add the awakeable-abandonment paragraph and point at the
allocation-step re-run as the re-notification mechanism, mirroring `spawnChild`'s
fresh-child-id guidance. In `keiro/src/Keiro/Workflow/Awakeable.hs`, say the same
from the awakeable's perspective (a rotated-past awakeable is orphaned until GC;
`signalAwakeable` against it returns `True`/`False` per its row but wakes
nothing).

Guides and reference. In `docs/guides/durable-workflows.md` and
`docs/user/durable-workflows.md`: add a "writing your own wake source" section
(guide: worked shape with the three obligations; reference: the contract stated
tersely with ADR links), and a "what suspension costs" section giving the honest
posture for the tree's current state (check MasterPlan 30's registry: before
plan 200, the O(parked × pass-rate) re-run cost and the advice to prefer
`sleepNamed` hints and `Every n` snapshot policies for suspend-heavy workflows;
after plan 200, the exact-discovery behavior and what still costs passes —
due sleeps whose timer worker is behind, crash backoff retries). State plainly
that `defaultWorkflowRunOptions`' `snapshotPolicy = Never` means full journal
replay per resume and when to change it.

Roadmap and production status. In `docs/user/roadmap.md`: amend the Phase-5
durable-execution rows and the capability matrix's "Durable execution runtime"
row with the scale-posture sentence and, if plans 200/203 are still pending,
list them as the expected next hardening wave (mirroring how the document already
tracks phase-2 items); if landed, flip the wording to available, as the document
did for MasterPlan 6 features. In `docs/user/production-status.md`: one
adoption-posture bullet stating the suspension cost model and the snapshot-policy
recommendation, in the document's existing voice.

Drift fixes. Correct `recordStepTx`'s conflict-key haddock in
`keiro/src/Keiro/Workflow/Schema.hs` to the four-column key. Add the
parent-collection sentence to `keiro/src/Keiro/Workflow/Gc.hs`'s module header.
While in `Keiro.Workflow.Types`, verify `workflowStreamName`'s haddock still
matches `mkWorkflowName`/`mkWorkflowId` guidance (the audit found it accurate —
touch only if drifted).


## Concrete Steps

All commands run from the repository root.

```bash
cabal haddock keiro        # haddock must build clean after the edits
cabal test keiro-test      # docs-only change; suite must stay green untouched
just verify                # repository-wide gate (includes adr-validate; no ADR edits expected)
```

Commit (docs scope):

```text
docs(workflow): state the wake-source contract and suspension cost posture

MasterPlan: docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md
ExecPlan: docs/plans/204-document-the-wake-source-contract-and-the-durable-execution-scale-posture.md
Intention: intention_01kza6gjs5eg79n2hyrah7wnnn
```


## Validation and Acceptance

Acceptance is a review reading, not a test run: a reader of only the updated
`Keiro.Workflow` haddock can answer "what must my custom wake source persist, and
why does the arm re-check it?"; a reader of only
`docs/guides/durable-workflows.md` can answer "what does a workflow parked on an
awakeable cost me, and which snapshot policy should I set?"; and a reader of
`docs/user/roadmap.md` learns the posture without reading source. Mechanical
gates: `cabal haddock keiro` builds without new warnings; every ADR cited resolves
as a repository-relative path; `cabal test keiro-test` is untouched-green.


## Idempotence and Recovery

Docs-only; re-running edits or reverting is trivially safe. The one hazard is
posture text drifting from reality if plans 200/203 land after this plan — the
Decision Log entry above binds the text to the registry state at writing time,
and those plans' own doc touches (each updates user docs it invalidates) are the
correction mechanism; verify at MasterPlan close-out.


## Interfaces and Dependencies

No code interfaces change. Files touched: `keiro/src/Keiro/Workflow.hs`,
`keiro/src/Keiro/Workflow/Awakeable.hs`, `keiro/src/Keiro/Workflow/Schema.hs`,
`keiro/src/Keiro/Workflow/Gc.hs` (haddocks only);
`docs/guides/durable-workflows.md`, `docs/user/durable-workflows.md`,
`docs/user/roadmap.md`, `docs/user/production-status.md`;
`keiro/CHANGELOG.md` (docs note). Soft dependencies on
`docs/plans/200-make-suspended-workflows-quiescent-and-discovery-index-aligned.md`
and
`docs/plans/203-concurrent-resume-passes-batched-timer-drain-and-worker-pass-robustness.md`
as recorded in MasterPlan 30's Dependency Graph.
