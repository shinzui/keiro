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

- [x] (2026-08-06) Wake-source authoring contract in `Keiro.Workflow`'s module
  haddock, the guide (worked sketch), and the reference (terse, ADR-linked) —
  four obligations, including ADR 23's instance-row clause.
- [x] (2026-08-06) `continueAsNew` awakeable-abandonment documented on
  `continueAsNew`, on `awakeableNamed`, in the guide, and in the
  production-status limits section.
- [x] (2026-08-06) Scale posture and snapshot guidance in `docs/user/roadmap.md`
  (Phase-5 prose, resume-worker and capability-matrix rows),
  `docs/user/production-status.md`, and both durable-workflows documents.
- [x] (2026-08-06) Haddock drift fixed: `recordStepTx`'s four-column conflict
  key, the GC parent-collection note, and the stale "unioned with running
  children" discovery description in both user documents.
- [x] (2026-08-06) `cabal haddock keiro` adds no new warnings (diffed against a
  pre-edit baseline); every cited ADR resolves as a repository-relative path.
- [x] (2026-08-06) Full suite green and untouched: `cabal test keiro-test` — 407
  examples, 0 failures, no test edits. `just adr-validate`, `just
  research-validate`, and the extension / generated-name / conformance-corpus
  policy scripts all pass.


## Surprises & Discoveries

- The wake-source contract is four obligations, not the three this plan
  anticipated. ADR 23 did not exist when the plan was written; plan 200 added it,
  and its clause — every lifecycle transition of a wake source's durable row must
  leave the owning `keiro_workflows` row discoverable, in the same transaction —
  is the one with the worst failure mode. Missing obligations 1–3 strands a
  delivery until the next repair; missing this one strands the workflow
  permanently, because exact discovery never re-examines it. The documentation
  states it separately and says so.

- Both user-facing documents described discovery as it worked before plan 200
  ("via the `keiro_workflow_steps` index, unioned with running children"), which
  the plan's inventory of drift did not include — it only listed `recordStepTx`
  and the GC module. Correcting user-facing prose that a sibling plan
  invalidated turned out to be as much of this plan's value as the new sections.
  A behavioural plan that changes a documented mechanism should either fix the
  prose itself or file it, and MasterPlan 30 had only the latter.

- `cabal haddock` warnings cannot be diffed naively across a `git stash`. Haddock
  re-emits warnings only for the modules it rebuilds, so the stashed baseline run
  reused fresh interfaces and emitted 165 warnings against the edited tree's 188.
  Every one of the 23 extra warnings came from `keiro-core` re-exported modules
  (`Keiro.Codec`, `Keiro.EventStream`, `Keiro.Prelude`, `Keiro.Stream`,
  `Keiro.Integration.Event`) and cross-package name ambiguity — none from the four
  modules this plan touched, which is the actual finding. Compare the *identifiers*
  in the warning set, not the count.

- MasterPlan 30 asked this plan to write its author-facing documentation against
  EP-4's worker-loop convention. It landed in the guide's operational notes
  rather than the wake-source section: "isolate per pass and per item, and report
  partial progress honestly" applies to anyone writing a loop around
  `resumeWorkflowsOnce` or `gcWorkflowsOnce`, not specifically to wake-source
  authors.


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

- Decision: Both plans 200 and 203 were Complete at implementation time, so the
  posture is written as shipped — parked workflows are free, and the remaining
  costs are named individually (due sleeps awaiting a timer worker, crash
  retries, journal replay under the default `snapshotPolicy = Never`).
  Rationale: The registry, not this plan's prose, is the source of truth for
  which state to describe; describing the pre-200 O(parked × poll) posture would
  have been wrong the day it was written.
  Date: 2026-08-06

- Decision: Fix the stale discovery descriptions in
  `docs/user/durable-workflows.md` and `docs/guides/durable-workflows.md` here,
  rather than filing them back against plan 200.
  Rationale: They are documentation drift, which is exactly this plan's scope,
  and plan 200 is Complete — reopening a finished plan to correct prose this one
  is already editing would cost more than it clarifies.
  Date: 2026-08-06

- Decision: Put EP-4's worker-loop convention in the guide's operational notes
  rather than the wake-source section, and still leave the ADR to the
  MasterPlan's completion distillation.
  Rationale: The convention governs anyone writing a loop around
  `resumeWorkflowsOnce` or `gcWorkflowsOnce`, which is a different audience from
  wake-source authors; and this plan mints no ADR by its own rule (Context and
  Orientation), so the durable record stays a MasterPlan-close-out decision.
  Date: 2026-08-06


## Outcomes & Retrospective

Complete, 2026-08-06. Docs-only, as scoped: four haddock surfaces
(`Keiro.Workflow`, `Keiro.Workflow.Awakeable`, `Keiro.Workflow.Schema`,
`Keiro.Workflow.Gc`) and four documents (`docs/guides/durable-workflows.md`,
`docs/user/durable-workflows.md`, `docs/user/roadmap.md`,
`docs/user/production-status.md`), plus a CHANGELOG section. No behaviour
changed, and the suite is untouched-green.

Against the acceptance criteria, which are reading tests rather than assertions:

- *What must my custom wake source persist, and why does the arm re-check it?*
  Answerable from `Keiro.Workflow`'s overview alone — the four obligations, the
  rotation race that motivates the third, and the exact-discovery clause that
  motivates the fourth, each citing its ADR by relative path.
- *What does a workflow parked on an awakeable cost me, and which snapshot policy
  should I set?* Answerable from either durable-workflows document: nothing until
  something happens to it, and `Every n` for suspend-heavy or long-journal
  workflows because the default is `Never`.
- *What is the posture, without reading source?* In the roadmap's Phase-5 prose
  and capability matrix, and in the production-status page's adoption bullets.

The lesson worth carrying: the most valuable edits were not the new sections the
plan scoped, but the sentences that had quietly become false. Both user documents
still described discovery as "the `keiro_workflow_steps` index, unioned with
running children" — the mechanism plan 200 replaced. A reader would have believed
it, because it was written with the same confidence as the parts that were still
true. Behavioural plans in this initiative each updated the CHANGELOG and the
ADRs; none of them swept the guides. Worth a habit: when a plan changes a
mechanism, grep the user docs for the old mechanism's name before closing it.

Deliberately not done here: no ADR was minted (this plan's own rule), and EP-4's
worker-loop convention was written into the guide's operational notes while the
durable record remains a MasterPlan close-out item.


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
