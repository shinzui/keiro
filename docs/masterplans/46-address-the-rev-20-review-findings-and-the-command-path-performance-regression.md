---
id: 46
slug: address-the-rev-20-review-findings-and-the-command-path-performance-regression
title: "Address the REV-20 review findings and the command-path performance regression"
kind: master-plan
created_at: 2026-10-21T12:21:07Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T12:21:07Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-21T13:02:16Z
      mode: "implement"
      note: "Record EP-1 attribution outcome and EP-2 gate wiring in progress"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:49:50Z
      mode: "update"
      note: "Apply review findings: explicit release prerequisites, milestone dependencies, shared ownership, evidence limits and ADR-58 policy."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T04:25:33Z
      mode: "implement"
      note: "Begin EP-7 before dependent baseline recording; preserve release prerequisites."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:24:48Z
      verdict: "changes-requested"
      note: "Release prerequisites omit EP-3/EP-4 completion; EP-1/EP-7 ownership and stale acceptance need reconciliation; child feasibility findings block readiness."
---

# Address the REV-20 review findings and the command-path performance regression

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The review record `docs/reviews/keiro-0-20-0-21-unreleased-review.md` (REV-20, recorded at
commit `a62850d3` against the `keiro-0.19.0.1` tag) examined the 0.20.0.0 and 0.21.0.0
releases and the unreleased inspection cohort with hot-path performance as its first question.
It found the Keiro code on every runtime hot path unchanged or measured at zero cost, and it
found five things that must change before the next tag. The committed command benchmark guard
(`just bench-regression`, the `command` guard against `keiro/bench/baseline-command.csv`) is
red: every scenario that appends events is 25% to 239% slower than its August 2026 baseline,
the guard was already red at 0.19.0.1, and no release procedure ever ran it. The default
`wf inspect list` page scans the whole `keiro.keiro_workflows` table twice for a wide-key
population that no index distinguishes any more, and its chosen key order cannot use the
primary key. The HTTP operational surface accepts a confirmed mutation from any origin and lets
a handful of slow readers hold every inspection permit. Process-manager inspection and its
provenance ship only for the legacy positional API that the pre-1.0 retirement plan
(`docs/plans/304-retire-legacy-language-and-runtime-compatibility-before-keiro-1-0.md`)
removes, while the reaction API that survives has none. And the 0.21.0.0 release regenerated
`BehaviorContract.hs` for every published language while its upgrade edge says only hole-owned
initial transitions regenerate, so consumers are told less than they will see.

When this initiative is complete, a maintainer can run `just release-gate` on a quiet machine
and watch both halves pass: the correctness gate and all six benchmark regression guards, with
the log committed beside the release. The owner can distinguish benchmark fixture interference from runtime cost using retained,
reproducible measurements. Unfiltered default workflow browsing follows the primary-key range;
filtered and creation-order reads have measured, deadline-bound operating envelopes. A browser on a foreign origin cannot execute a confirmed
mutation, and stalled deliveries release their permits within a configured deadline; `/health` recovers
after those permits return. Shared admission may still refuse it while all slots are occupied. Reaction process managers can be
inspected through the same `pm show` and `pm list` commands as legacy ones, and the legacy-only
surfaces say so where a consumer reads. The changelogs, the release skill, the `mori.dhall`
registry, and the 0.20.0.0 to 0.21.0.0 edge say exactly what shipped.

Included: everything listed under "Required before tagging the next release" and the
findings in REV-20, plus the follow-ups it recorded that touch the same files (feed schema
verification cadence, snapshot re-encoding, the retiring-view code, the TLS origin caveat,
the `effectful` bounds in `mori.dhall`). Excluded: the release cut itself (version bump, eight
tags, Hackage uploads, GitHub release), which `docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`
owns and runs through `agents/skills/release/SKILL.md` after this initiative's Phase 1 lands;
publishing Language 6; retiring Languages 1 to 5 (plan 304); any change to a Kiroku package,
which lives in `mori://shinzui/kiroku` and is reached through an improvement request there if
the attribution in EP-1 points at it.


## Decomposition Strategy

The findings were grouped by the artifact they change and by who must verify the result, not
by the review item that surfaced them. Two streams are about measurement: EP-1 attributes the
command-path slowdown and makes the three red guards trustworthy, and EP-2 makes the guards
part of the release gate so this cannot recur. They are separate plans because the gate wiring
is small, mechanical, and useful even while EP-1 is still bisecting, and because a plan that
gates releases should not wait on an investigation whose length nobody can promise. Three
streams change behaviour on the unreleased inspection cohort before it becomes public contract:
EP-3 (the workflow listing cost model), EP-4 (HTTP mutation origin and delivery bounds), and
EP-5 (reaction process-manager inspection and the legacy labelling the 1.0 direction demands).
They are separate because each is verified by different tests and evidence (query plans,
HTTP tests, inspection tests) and touches different owner modules. The last stream, EP-6,
reconciles every document a consumer reads at release time: changelogs, the release skill's
dependency scan, `mori.dhall`, and the 0.20.0.0 to 0.21.0.0 edge. It is separate from plan 303
because plan 303 owns the irreversible actions (tags and uploads) and should consume a finished
release surface rather than produce one.

Phase 1 holds the plans the next tag waits on: EP-1, EP-2, EP-3, EP-4, EP-6, and EP-7. EP-5 is also
Phase 1 for its labelling outcome; if its inspector extension is not ready when plan 303 wants
to tag, EP-6 carries the legacy-only wording and EP-5's extension ships in the following
release. Two alternatives were rejected. Folding EP-2 into EP-1 would have left the release
gate unprotected until the attribution finished. Folding EP-3 and EP-4 into one "inspection
cohort fixes" plan would have mixed a query-plan decision that changes a cursor contract with
a security fix that changes request admission; they share a package but not reviewers,
evidence, or risk.

EP-7 owns harness isolation and fixed-workload preparation; EP-1 owns attribution, thresholds,
and baseline recording after that harness is accepted. EP-2 owns ADR-58 and its implementation evidence.

Relevant local ADRs, read for this decomposition: ADR-40
(`docs/adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md`) fixes
that no inspection surface may add writer cost and that endpoints render supported library
reads; EP-3 and EP-4 work inside it. ADR-48
(`docs/adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md`)
records the precedent EP-2 follows: a measured workload that runs in the regular repository
gate. ADR-53 (`docs/adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md`)
defines the mutation protocol, the admission budget, and the deadline scope that EP-4 amends,
so EP-4 revises it. ADR-55
(`docs/adr/0055-legacy-reaction-provenance-is-bounded-explicit-opt-in-metadata.md`) states
that the modern reaction runner has no provenance "in this cohort"; EP-5 adds state inspection while keeping reaction provenance explicitly unavailable.
Deterministic witness IDs cannot recover source input, source identity, or dispatch targets.
ADR-56 (`docs/adr/0056-inspection-feeds-own-bounded-shared-drivers-and-an-active-only-wake-cursor.md`)
requires schema verification within every refresh deadline and fresh snapshot presentation;
EP-4 preserves these properties and rejects a TTL cache or semantic-equality-only frame reuse. ADR-49
(`docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md`) is the
frame for EP-5 and for EP-6's wording. ADR-42
(`docs/adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md`) explains
that fresh deterministic inserts use one statement and only conflicts need a locked read.
EP-1 must measure the fresh path before changing its ratio guard. ADR-58 (`docs/adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md`) now records that policy; EP-2 owns its
implementation evidence, with contributions from EP-1 and EP-7.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Attribute the command-path append slowdown and restore trustworthy benchmark guards | docs/plans/315-attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards.md | M3–M6: EP-7 Complete | None | In Progress |
| 2 | Run the benchmark regression guards in the release gate | docs/plans/316-run-the-benchmark-regression-guards-in-the-release-gate.md | M2 passing run: EP-1 Complete | EP-1 during investigation | In Progress |
| 3 | Bound the workflow listing cost without the withdrawn inspection indexes | docs/plans/317-bound-the-workflow-listing-cost-without-the-withdrawn-inspection-indexes.md | None | None | Complete |
| 4 | Harden the HTTP operational surface against cross-site mutations and permit exhaustion | docs/plans/318-harden-the-http-operational-surface-against-cross-site-mutations-and-permit-exhaustion.md | None | None | Complete |
| 5 | Inspect reaction process managers and label legacy inspection before 1.0 | docs/plans/319-inspect-reaction-process-managers-and-label-legacy-inspection-before-1-0.md | None | None | Not Started |
| 6 | Reconcile the 0.22.0.0 release surface and the 0.21.0.0 edge with the REV-20 findings | docs/plans/320-reconcile-the-0-22-0-0-release-surface-and-the-0-21-0-0-edge-with-the-rev-20-findings.md | M1/M4 final acceptance: EP-3 Complete, EP-4 Complete, EP-5 M3 | EP-5 M1/M2 | Not Started |
| 7 | Isolate the keiro-bench harness so each guard measures only its own fixture | docs/plans/321-isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture.md | None | None | In Progress |

EP-1's M3 to M6 (re-recording the baselines and proving the gate green) require EP-7 to be
Complete; EP-1's M1/M2 observations are already recorded and had no prerequisite.

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
A whole-child hard dependency requires that child to be Complete. If only a milestone's
accepted output is needed, name it explicitly (e.g., EP-1 M1) and explain it below.


## Dependency Graph


EP-7 must be Complete before EP-1 M3–M6 begin. EP-1 M1/M2 record the existing
sweep and preparation-sensitivity experiment; they do not prove absence of every runtime
regression. EP-7 is the next implementation plan. EP-3, EP-4, and EP-5 may proceed
independently, subject to the shared-file ownership below. EP-5 executes M3 (labelling)
first, then M1/M2 (state inspection with explicitly unavailable reaction provenance).

EP-2 wiring and its failing-gate demonstration can proceed immediately. Its M2 passing-run
acceptance requires EP-1 Complete, and EP-2 remains In Progress until both demonstrations
and its other milestones are accepted. EP-1 consumes the already committed runner; it does
not wait for EP-2 Complete. There is no dependency cycle.

EP-6 can draft changelogs and complete M2/M3 now. Its M1/M4 final acceptance requires
EP-3 Complete, EP-4 Complete, and EP-5 M3 accepted. EP-5's state-inspector extension is
optional for this release; EP-6 records whether it landed, while legacy provenance remains
labelled in either case. This permits early documentation work without waiving release fixes.

Plan `docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`
must not tag until EP-1, EP-2, EP-3, EP-4, EP-6, and EP-7 are Complete and EP-5 M3 is
accepted. The final release candidate must also pass `just release-gate`; an earlier green
run does not cover subsequent code changes. Plan 303 retains the independent MasterPlan 45
integration/interference gates. Its preflight is updated in this revision so the obligation
exists at the release entry point, rather than waiting for EP-2 implementation.


## Integration Points

The five CSV benchmark baselines `keiro/bench/baseline-*.csv` and the retained evidence under
`keiro/bench/results/` are owned by EP-1. EP-2 reads them through `scripts/bench-regression.sh`
and never edits them. A baseline moves only with an evidence directory and a README that EP-1
defines; EP-2's release skill text points at that rule.

The benchmark harness structure (`keiro/bench/Main.hs`, `InboxDelegatedBench.hs`,
`ProducerIdentityBench.hs`, `ReadModelBench.hs`: which store each group uses, where
preparations run, what the timed actions reset, selection-aware setup and warm-up) is owned by EP-7. EP-1
records baselines only on EP-7's harness and must keep every existing scenario name, because
`scripts/bench-regression.sh`'s `-p` patterns and the baseline CSVs match on names.
EP-7 keeps a static benchmark tree and performs representative warm-up in selected setup,
not in an adaptively repeated throwaway benchmark.

`scripts/bench-regression.sh` and the `bench-regression` and `release-gate` recipes in
`justfile` are owned by EP-2. EP-1 runs them for its acceptance and owns measured threshold changes inside `keiro/bench/ProducerIdentityBench.hs`
after EP-7 acceptance; warm-up and fixture changes remain EP-7 work, but the runner's
per-guard summary format (`GUARD(name)=status`, `BENCH_REGRESSION=PASSED|FAILED`) is EP-2's
contract and the release skill depends on it.

`agents/skills/release/SKILL.md` is edited by EP-2 (step 4, the gate) and by EP-6 (step 3,
the internal-dependency scan regex). The sections do not overlap; each plan edits only its
section.

The inspection cursor contract in `keiro/src/Keiro/Workflow/Inspection/Query.hs` and
`keiro/src/Keiro/Workflow/Inspection.hs` (the transition from `wf-key` to `wf-key2`, the unchanged `wf-created` kind, the
`InspectionWorkLimitExceeded` error, and the constants `maxIndexedWorkflowKeyBytes`,
`maxWideWorkflowCandidates`, `maxWideWorkflowKeyBytes`) is owned by EP-3. EP-6 describes
whatever EP-3 ships in the changelogs. EP-3 owns the workflow envelope text in
`docs/user/durable-workflows.md`, the pending-timer envelope in
`docs/user/process-managers-and-timers.md`, and `scripts/inspection-query-evidence.hs`.
EP-3 owns removal of the workflow error mapping in `Application.hs`; EP-4 owns request
admission/delivery in that same file and consumes the final mapping in shared HTTP tests.
The HTTP routes in `keiro-ops-http/src/Keiro/Ops/Http/Route.hs` consume the cursor as an opaque
string and need no change.

The HTTP admission and mutation policy in `keiro-ops-http/src/Keiro/Ops/Http/Application.hs`,
`Budget.hs`, `Cors.hs`, and `WebSocket.hs` is owned by EP-4, together with the three guides
`docs/guides/serve-keiro-ops-over-http.md`, `docs/guides/stream-keiro-inspection-views.md`,
and `docs/guides/compose-runtime-inspection-surfaces.md`. EP-6 does not edit those guides; it
edits `docs/user/operations.md` and the changelogs, and audits the owner-authored guides.

The process-manager inspector constructors in `keiro/src/Keiro/ProcessManager/Inspect.hs` and
the `pm` command family in `keiro-ops/src/Keiro/Ops/ProcessManager.hs` are owned by EP-5. EP-5 owns API/legacy wording in `docs/user/api-reference.md` and the manager section of
`docs/user/process-managers-and-timers.md`; EP-3 owns only that page's timer-cost section.
EP-6 copies the accepted wording into changelogs and audits the shipped command coverage.
The reaction constructor selects an explicit descriptor provenance mode and reports
unavailable evidence; it must not reinterpret legacy metadata or invent a dispatch list. Legacy-only provenance
wording remains even if reaction state inspection lands before the tag.

Cross-plan ADR ownership: how benchmark baselines are recorded, when they may
move, and that the guards are a release gate (EP-2 owns ADR-58, consuming EP-1 recording rules and EP-7 fixture evidence); the
mutation origin policy and the delivery bound (EP-4, a revision of ADR-53); the reaction
provenance decision (EP-5, a revision of ADR-55); and the listing cost model without inspection
indexes (EP-3, ADR-40 and the corresponding owner-read wording in ADR-28).
This revision records the selected policy in ADR-40/53/55/56/58. Children update the
implementation/evidence wording when their behavior is accepted, rather than claiming the
planned changes already ship.


## Progress


Phase 1 remains open. EP-3 is Complete with cursor/class/wide-key tests, strict
documentation validation and 136 retained v2 query plans. EP-4 is Complete: 49 HTTP examples pass, including wire origin/media refusals,
actual stalled-socket termination, fresh-feed and retirement recovery. Strict
ADR and documentation validation passes for both children. EP-7 is In Progress with static selected
fixtures, fixed 600-event rebuilds and a growth probe through 1.2 million events;
paired full/filtered measurements and reset/durable-fixture evidence remain open.
EP-1 M3–M6 wait for EP-7 Complete. EP-2's passing release demonstration still waits
for EP-1 Complete. EP-5 and EP-6 are Not Started; EP-6 final acceptance requires
EP-4 Complete and EP-5 M3 in addition to accepted EP-3. No release is authorized by
this initiative, and all final-candidate/integration gates remain mandatory.


## Surprises & Discoveries


The historical control `2477a5aa` did not reproduce its own August baseline on this machine.
EP-1 retains the measured rows, tag window, and the HEAD experiment replacing delegated
preparation with `pure []`. That experiment demonstrates sensitivity to shared preparation;
it does not identify every statement cost or prove a universal absence of serving regressions.

Review found two incorrect mechanisms in the original narrative. `prepareHistoryRun store
100000` is already scoped to the selected history benchmark's `env` (or the explicit explain
hook). The unconditional work is business-table setup, duplicate seeding, and fresh-scenario
warm-up. Filtered-run isolation must be proved with preparation counters, not inferred from
absence of a history build that was already skipped. Also, `enqueueProducerOutboxTx` returns
after a successful fresh insert; the second locked statement is conflict-only. EP-1 now
measures the actual fresh path before any threshold decision.

The query primary key bounds unfiltered range traversal, not sparse-filter search. Reaction
accepted witnesses identify acceptance, not their source event or dynamic follow-ups. Feed
semantic equality excludes clock presentation fields. These constraints drive the corrected
acceptance in EP-3, EP-4, and EP-5.


The command growth probe identifies a stale empty-fixture generic sequential plan:
5,001 stream rows are scanned until ANALYZE selects the existing name index. The
indexed probe remains stable through roughly 1.2 million events. The ordinary
benchmark entry point also used the fast correctness fixture; EP-7 now selects the
existing durable benchmark fixture so final evidence records fsync, synchronous
commit and full-page writes enabled. EP-1 must audit/re-record every affected CSV,
rather than preserving incomparable old rows that happen to pass.

## Decision Log

- Decision: Keep the gate wiring (EP-2) separate from the attribution and guard repair (EP-1),
  and land the wiring first even though it makes `just release-gate` red today.
  Rationale: A red gate that says why it is red is the point. The guards were red for several
  releases because nothing ran them; waiting for the investigation before wiring the gate would
  reproduce the gap.
  Date: 2026-10-21
- Decision: EP-6 reconciles the release surface but plan 303 cuts the release.
  Rationale: Plan 303 already holds the drafted 0.21.0.0 to 0.22.0.0 edge and the release
  rehearsal; the irreversible steps should stay in one plan with one owner, consuming a
  reconciled surface rather than producing one.
  Date: 2026-10-21
- Decision: Add EP-7 for the harness isolation and make EP-1's re-recording depend on it.
  Rationale: The attribution showed that the command guard has measured another group's
  fixture since 0.17.0.0 and that timed actions pay deletes no serving path pays; fixing that
  is harness work with its own isolation test, separate from recording baselines, and
  recording on an unfixed harness would freeze the distortion.
  Date: 2026-10-21
- Decision: EP-5's minimum outcome before the tag is labelling, not the inspector extension.
  Rationale: ADR-49 and plan 304 retire the positional API; shipping its inspection unlabelled
  in 0.22 would announce a contract the retirement release removes. The extension is the better
  outcome and EP-5 should attempt it, but the tag must not wait on it.
  Date: 2026-10-21


- Decision: Make mandatory inspection fixes explicit release prerequisites, preserve fresh
  schema/presentation observations, and expose reaction state without inferred provenance.
  Rationale: The review found missing release edges and evidence that cannot be reconstructed
  from current storage. EP-3 limits its scan guarantee to unfiltered ranges; EP-7 fixes replay
  workload size before EP-1 records new baselines. ADR-40/53/55/56 carry the durable boundaries.
  Date: 2026-10-21

Revision note (2026-10-21): Applied the review across the graph, shared-file ownership,
release preflight, benchmark attribution/acceptance, query envelope, and HTTP/reaction
contracts. Earlier review entries remain historical records; no implementation is marked done.


## Outcomes & Retrospective

(To be filled during and after implementation.)
