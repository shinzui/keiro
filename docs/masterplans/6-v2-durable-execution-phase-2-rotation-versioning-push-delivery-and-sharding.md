---
id: 6
slug: v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding
title: "v2 durable execution phase 2: rotation, versioning, push delivery, and sharding"
kind: master-plan
created_at: 2026-06-03T21:28:31Z
intention: "intention_01kt7npy22e5tb3ybycsgeqdnm"
---

# v2 durable execution phase 2: rotation, versioning, push delivery, and sharding

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

MasterPlan 5 shipped the v2 durable-execution runtime: named-step `Workflow es a`
functions with durable sleep, awakeables, child workflows, a crash-recovery resume
worker, journal snapshots, and `keiro.workflow.*` observability
(`docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md`,
Outcomes). That MasterPlan deliberately deferred the §6 "stretch" features of
`docs/research/10-workflow-roadmap.md` because none of them block the core runtime
and each adds operational surface that earns its keep only at scale. This MasterPlan
delivers the four deferred features that are *cleanly additive* to the shipped
runtime and that the research doc marks as "v2 adds it when a customer hits the
wall": **continue-as-new journal rotation (§6.4)**, the **versioning / patch API
(§6.5)**, **LISTEN/NOTIFY push delivery (§6.11)**, and **consumer-group sharding for
category subscriptions (§6.8, with the companion cluster-aware leadership of §6.9)**.

**What a user can do after this initiative that they cannot do today:**

- Run a workflow with an *unbounded* number of steps (a long-lived poller, a
  per-day-rolling process) without its journal stream growing without limit:
  `continueAsNew` snapshots the live step-result state, rotates the workflow onto a
  fresh journal generation, and resumes against it, so journal length stays bounded
  and replay/hydration stays fast (EP-48).
- Evolve a *running* workflow's logic in a way that crosses step boundaries — not
  just renaming a step — and have in-flight instances observe a stable, journaled
  branch decision via an explicit `patch :: PatchId -> Workflow Bool`, instead of
  being limited to the "rename a step to opt out" mechanic the named-step model
  gives for free (EP-49).
- Get sub-second latency from the subscription workers that drive process managers
  and the workflow resume loop, by replacing 100 ms polling with a Postgres
  `LISTEN/NOTIFY` push channel where it matters for interactive workflows (EP-50).
- Scale a single high-volume category subscription across N cooperating workers
  that partition the keyspace and elect ownership, instead of one
  advisory-lock-elected worker per subscription name (EP-51).

**In scope:** the four features above, each as an additive layer on the shipped v2
runtime and the v1 subscription/worker substrate; their schema additions (a journal
*generation* discriminator for rotation; a patch-decision journal entry; a sharded
subscription-ownership table); their tests; and the `docs/user/roadmap.md` /
`production-status.md` reconciliation flipping each from "deferred" to "available".

**Explicitly out of scope (still deferred, per `docs/research/10-workflow-roadmap.md`
§6):** multi-region / global ordering (§6.6 — contradicts the Postgres-native
thesis), server-side scripted projections (§6.7 — rejected outright), the schema
registry (§6.10), and field-level encryption / crypto-shredding (§6.12). These are
either rejected or wait on a concrete customer demand and do not belong in this
phase. This MasterPlan also assumes the two follow-up fixes
`docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md`
and `docs/plans/47-key-workflow-step-index-and-discovery-on-workflow-id-and-name.md`
have landed (or will land independently); its migrations follow plan 46's
`SET search_path` convention.


## Decomposition Strategy

The four features are **functionally orthogonal** — they touch different subsystems
and have independent acceptance — so the decomposition is one child ExecPlan per
feature, grouped into two waves by which substrate they extend.

**Wave 1 — workflow-journal features (EP-48, EP-49)** extend the v2 workflow runtime
itself (`Keiro.Workflow*`, the `wf:` journal, the journal codec, `WorkflowRunOptions`,
the snapshot machinery). Continue-as-new (EP-48) is journal *rotation*: it reuses
EP-41's snapshot codec to capture state and writes a terminal rotation marker that
points at the next generation. The patch API (EP-49) is a new journaled *decision
record* read on replay. Both are pure workflow-runtime concerns with no subscription
or upstream dependency, and can proceed in parallel.

**Wave 2 — subscription/worker-substrate features (EP-50, EP-51)** extend the
polling subscription layer that drives process managers and the workflow resume
worker (the shibuya-kiroku-adapter and the claim-process-commit-poll worker shape).
LISTEN/NOTIFY push (EP-50) replaces the poll with a Postgres notification channel;
consumer-group sharding (EP-51) partitions a category across workers with
cooperative ownership and leadership. Both likely require *upstream* changes in
kiroku/shibuya (a notification channel; a sharded subscription claim), so each child
plan must scope the upstream surface explicitly and record it in
`docs/research/11-upstream-roadmap.md`. They are independent of Wave 1 and of each
other, though EP-51's leadership story and EP-50's long-lived connection both touch
worker lifecycle, noted as an integration point.

**Why one plan per feature rather than fewer:** each feature is independently
verifiable with its own acceptance (a bounded journal after N rotations; a stable
patch branch across replays; a sub-second wakeup; throughput across N workers) and
its own storage/upstream surface. Merging any two would couple unrelated
operational concerns and acceptance, the same reasoning that kept MasterPlan 5's
features in dedicated plans. **Why not defer further:** these four are the §6 items
the research doc explicitly marks as mechanical-to-add-post-v1 and demand-driven;
grouping them into one phase-2 MasterPlan lets them be scheduled against real
customer pull without re-litigating the decomposition each time.

Alternatives considered and rejected: (a) folding continue-as-new into a "workflow
hardening" plan with the patch API — rejected, different storage (a generation
discriminator vs a decision record) and different acceptance; (b) a single
"subscription scaling" plan covering both push and sharding — rejected, push is a
latency feature and sharding is a throughput feature with separate upstream asks; (c)
including multi-region — rejected as out of scope per §6.6.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 48 | Continue-as-new journal rotation for durable workflows | docs/plans/48-continue-as-new-journal-rotation-for-durable-workflows.md | None | None | Not Started |
| 49 | Workflow versioning and patch API | docs/plans/49-workflow-versioning-and-patch-api.md | None | EP-48 | Not Started |
| 50 | LISTEN/NOTIFY push delivery for subscriptions and workflow resume | docs/plans/50-listen-notify-push-delivery-for-subscriptions-and-workflow-resume.md | None | None | Not Started |
| 51 | Consumer-group sharding for category subscriptions | docs/plans/51-consumer-group-sharding-for-category-subscriptions.md | None | EP-50 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-48, EP-50).

Implementation waves:

- **Wave 1 (parallel):** EP-48, EP-49 — workflow-journal features on the shipped v2 runtime.
- **Wave 2 (parallel):** EP-50, EP-51 — subscription/worker-substrate features (each with an upstream sub-scope).

All four hard-depend only on the *already-shipped* MasterPlan 5 runtime, not on each
other, so the whole MasterPlan can in principle proceed in parallel; the soft deps
record the preferred ordering (EP-49 reuses EP-48's generation/rotation journal
plumbing if it lands first; EP-51 builds on EP-50's notification channel for
ownership-change signalling if it lands first).


## Dependency Graph

None of the four plans hard-depends on another; every hard dependency is on the
shipped MasterPlan 5 surface (the `Keiro.Workflow` effect and `wf:` journal for
EP-48/EP-49; the shibuya-kiroku-adapter subscription worker for EP-50/EP-51). The
soft dependencies record preferred ordering only:

- **EP-49 soft-depends on EP-48.** The patch API journals a decision record; if
  EP-48's continue-as-new lands first, EP-49 reuses the same "additive journal
  entry within `schemaVersion = 1`, read on replay" plumbing and the generation-aware
  replay loop rather than reinventing it. EP-49 can also ship before EP-48 by adding
  its own journal-entry constructor; the soft dep is the cheaper ordering.
- **EP-51 soft-depends on EP-50.** Cooperative ownership re-balancing benefits from a
  push channel to signal ownership changes promptly; if EP-50 lands first, EP-51
  signals re-balance over the same `LISTEN/NOTIFY` channel instead of polling an
  ownership table. EP-51 can ship before EP-50 using a polled ownership table.

Within each wave the two plans are independent and parallelizable. Across waves the
two waves are independent. Each Wave-2 plan additionally carries an *upstream*
sub-dependency on kiroku/shibuya changes that the plan itself scopes and forwards to
`docs/research/11-upstream-roadmap.md`; that upstream work, if not already present,
is a prerequisite the plan must call out rather than silently assume.


## Integration Points

**The workflow journal codec and `WorkflowRunOptions` (EP-48, EP-49).** Both extend
the shipped `Keiro.Workflow.Types.WorkflowJournalEvent` codec (schema version 1,
additive — old journals never carry the new tag, so no upcaster) and/or
`WorkflowRunOptions`. EP-48 adds a terminal **rotation marker** (e.g.
`WorkflowContinuedAsNew { generation, snapshotRef, recordedAt }`) that closes one
journal generation and names the next; the resume worker and `findUnfinishedWorkflowIds`
must treat it as terminal-for-this-generation-but-continued (distinct from
`WorkflowCompleted`). EP-49 adds a **patch-decision** entry (e.g.
`WorkflowPatched { patchId, applied, recordedAt }` or a reserved `patch:` step-name
prefix, mirroring the `sleep:`/`awk:`/`child:` convention EP-38 established) read on
replay so a branch decision is stable. Whichever plan lands first owns the additive
edit to the codec's `eventTypes`/`encode`/`decode`; the second appends its
constructor and records it in this MasterPlan's Surprises, exactly as MasterPlan 5's
EP-43 added `WorkflowCancelled`/`WorkflowFailed`.

**Journal generation naming and discovery (EP-48).** Continue-as-new must keep the
`wf:<name>-<id>` identity stable for the user while rotating physical storage. EP-48
owns the generation scheme (e.g. a `wf:<name>-<id>#<generation>` physical stream with
the logical id unchanged, or a generation column on `keiro_workflow_steps`) and must
keep `findUnfinishedWorkflowIds` / the resume worker pointed at the *current*
generation. This interacts with plan 47's `(workflow_id, workflow_name)` index key
(if a generation column is added, it joins the key); EP-48 records the chosen scheme
here.

**The subscription worker and ownership (EP-50, EP-51).** Both extend the polling
subscription worker the shibuya-kiroku-adapter provides and that
`Keiro.Workflow.Resume.runWorkflowResumeWorker` and the process-manager workers run
on. EP-50 owns the notification-channel contract (the Postgres `NOTIFY` payload
shape and the `LISTEN` wait/fallback-to-poll loop); EP-51 owns the
sharded-ownership table and the leadership/claim protocol. If both land, EP-51's
ownership-change signalling rides EP-50's channel. Each plan must state precisely
which part of the contract is *keiro-side* and which requires an *upstream*
kiroku/shibuya change, and forward the upstream part to
`docs/research/11-upstream-roadmap.md`.

**Migrations.** Any new table or column follows plan 46's convention (each migration
begins with `SET search_path TO kiroku, pg_catalog;`) and is timestamped after the
latest existing migration. EP-48 may add a generation discriminator; EP-51 adds a
sharded-ownership table. EP-49 and EP-50 are not expected to need a migration (a
patch decision is journaled, not tabled; push delivery is a connection concern), but
each plan confirms this in its own text. Repeat MasterPlan 5's `embedDir`
recompilation gotcha (a new `.sql` file may not retrigger `Keiro.Migrations`
compilation; touch the module or `cabal clean`).


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-48: design + implement the generation/rotation journal scheme and `continueAsNew`.
- [ ] EP-48: prove a long-running workflow rotates and stays bounded across N rotations.
- [ ] EP-49: add the `patch :: PatchId -> Workflow Bool` primitive and its journaled decision record.
- [ ] EP-49: prove an in-flight workflow observes a stable patch branch across replays.
- [ ] EP-50: add the LISTEN/NOTIFY push channel with poll fallback; scope the upstream surface.
- [ ] EP-50: prove sub-second wakeup latency for a process manager / resume worker.
- [ ] EP-51: add the sharded-ownership table and the cooperative claim/leadership protocol.
- [ ] EP-51: prove a high-volume category drains across N cooperating workers without duplication.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-06-03 (planning): **The journal-codec integration point is resolved without a
  collision.** EP-48 (continue-as-new) owns the only additive `WorkflowJournalEvent`
  constructor — `WorkflowContinuedAsNew { generation, recordedAt }` (plus a
  `ContinuedAsNew` `WorkflowOutcome`) — within `schemaVersion = 1`, no upcaster. EP-49
  (patch API) deliberately needs **no** codec change: it journals each patch decision as
  an ordinary `StepRecorded` under a new reserved step-name prefix `patch:<patchId>`
  (mirroring `sleep:`/`awk:`/`child:`), carrying the `Bool` decision as the JSON result.
  So the two Wave-1 plans do not contend for the codec, and EP-49 rides the existing
  replay fold / step index / snapshot / rotation plumbing unchanged. EP-48 also adds a
  `generation` column that composes with plan 47's `(workflow_id, workflow_name)` re-key,
  becoming `(workflow_id, workflow_name, generation, step_name)`; generation 0 keeps the
  legacy `wf:<name>-<id>` stream name so existing journals need no migration.
- 2026-06-03 (planning): **The Wave-2 upstream surface is far smaller than assumed —
  kiroku already ships both substrates.** (1) For EP-50, kiroku already fires
  `pg_notify('kiroku.events', '<stream_name>,<stream_id>,<stream_version>')` on append via
  a `notify_events()` trigger and runs one dedicated listener connection per store with an
  in-process broadcast `TChan`; so the §6.11 "introduce a channel / expose a LISTEN
  connection" ask is essentially already satisfied, the feature is almost entirely
  keiro-side (a push-aware worker loop with poll fallback), and push adds **zero** new
  connections (resolving the pool-sizing concern). (2) For EP-51, kiroku already ships
  consumer-group partitioning (hashed buckets + per-member checkpoints), so EP-51 builds
  only the keiro-side cooperative-ownership/lease/rebalance layer on top, with the
  partition mechanism reused rather than reinvented. Each plan still forwards a small,
  non-blocking upstream ergonomics ask to `docs/research/11-upstream-roadmap.md`. Net:
  neither Wave-2 plan is upstream-blocked, contrary to the cautious framing in
  Decomposition Strategy.


## Decision Log

- Decision: Scope phase 2 to exactly the four cleanly-additive, demand-driven §6
  features (continue-as-new, patch API, LISTEN/NOTIFY push, consumer-group sharding),
  excluding multi-region, scripted projections, the schema registry, and field-level
  encryption.
  Rationale: The four included features are marked in
  `docs/research/10-workflow-roadmap.md` §6 as mechanical-to-add-post-v1 and
  customer-demand-driven; the excluded ones are either rejected outright (scripted
  projections), contradict the Postgres-native thesis (multi-region), or earn their
  keep only at organizational scale beyond keiro's current target (schema registry,
  field-level crypto). Bundling the four lets them be scheduled against real demand
  without re-deciding the decomposition.
  Date: 2026-06-03.

- Decision: One child ExecPlan per feature, in two waves (workflow-journal features;
  subscription-substrate features), with only soft inter-plan dependencies.
  Rationale: The features are functionally orthogonal with independent acceptance and
  separate storage/upstream surfaces; per-feature plans keep each independently
  verifiable and parallelizable, mirroring MasterPlan 5's decomposition. The two
  Wave-2 plans carry explicit upstream sub-scopes because push delivery and sharding
  both likely need kiroku/shibuya changes that must be surfaced, not assumed.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
