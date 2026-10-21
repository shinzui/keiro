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
the log committed beside the release. The owner knows which release and which substrate change
made append-heavy commands slower and has either fixed it or accepted it with evidence that a
later reader can audit. The default workflow listing is an index range scan whose cost grows
with the page, not the ledger. A browser on a foreign origin cannot execute a confirmed
mutation, and a slow client cannot take `/health` down. Reaction process managers can be
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

Phase 1 holds the plans the next tag waits on: EP-1, EP-2, EP-3, EP-4, and EP-6. EP-5 is also
Phase 1 for its labelling outcome; if its inspector extension is not ready when plan 303 wants
to tag, EP-6 carries the legacy-only wording and EP-5's extension ships in the following
release. Two alternatives were rejected. Folding EP-2 into EP-1 would have left the release
gate unprotected until the attribution finished. Folding EP-3 and EP-4 into one "inspection
cohort fixes" plan would have mixed a query-plan decision that changes a cursor contract with
a security fix that changes request admission; they share a package but not reviewers,
evidence, or risk.

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
that the modern reaction runner has no provenance "in this cohort"; EP-5 either ends that
exclusion or makes it a labelled, consumer-visible fact, and revises the ADR either way.
ADR-56 (`docs/adr/0056-inspection-feeds-own-bounded-shared-drivers-and-an-active-only-wake-cursor.md`)
requires that schema verification runs inside the feed admission deadline; EP-4's change to
verify once per handle tick must keep that property. ADR-49
(`docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md`) is the
frame for EP-5 and for EP-6's wording. ADR-42
(`docs/adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md`) explains
why the deterministic producer path issues two statements per row, which is the ratio EP-1's
producer guard compares. No ADR records how benchmark baselines are recorded or when they may
move; EP-1 and EP-2 should produce one.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Attribute the command-path append slowdown and restore trustworthy benchmark guards | docs/plans/315-attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards.md | None | None | In Progress |
| 2 | Run the benchmark regression guards in the release gate | docs/plans/316-run-the-benchmark-regression-guards-in-the-release-gate.md | None | EP-1 | In Progress |
| 3 | Bound the workflow listing cost without the withdrawn inspection indexes | docs/plans/317-bound-the-workflow-listing-cost-without-the-withdrawn-inspection-indexes.md | None | None | Not Started |
| 4 | Harden the HTTP operational surface against cross-site mutations and permit exhaustion | docs/plans/318-harden-the-http-operational-surface-against-cross-site-mutations-and-permit-exhaustion.md | None | None | Not Started |
| 5 | Inspect reaction process managers and label legacy inspection before 1.0 | docs/plans/319-inspect-reaction-process-managers-and-label-legacy-inspection-before-1-0.md | None | None | Not Started |
| 6 | Reconcile the 0.22.0.0 release surface and the 0.21.0.0 edge with the REV-20 findings | docs/plans/320-reconcile-the-0-22-0-0-release-surface-and-the-0-21-0-0-edge-with-the-rev-20-findings.md | None | EP-3, EP-4, EP-5 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
A whole-child hard dependency requires that child to be Complete. If only a milestone's
accepted output is needed, name it explicitly (e.g., EP-1 M1) and explain it below.


## Dependency Graph

No plan hard-depends on another. EP-1, EP-3, EP-4, and EP-5 can proceed in parallel from the
start; they touch different modules (`keiro/bench`, `keiro/src/Keiro/Workflow`,
`keiro-ops-http/src`, and `keiro/src/Keiro/ProcessManager`) and are verified by different
evidence. EP-2 can also start immediately and has in fact started: the `release-gate` recipe,
the `scripts/bench-regression.sh` runner, and the release skill wording were committed with
this MasterPlan. EP-2 soft-depends on EP-1 only in the sense that the gate stays red until
EP-1 makes the guards green; the wiring itself is complete and verifiable regardless.

EP-6 soft-depends on EP-3, EP-4, and EP-5 because its changelog, user-documentation, and
edge text describe what those plans ship. It should be the last Phase 1 plan to close, and it
must describe the shipped state rather than the planned one: if EP-5's inspector extension
has not landed when plan 303 tags, EP-6 writes the legacy-only labelling instead. Plan 303
(outside this initiative) hard-depends on EP-2 and EP-6 being Complete and on EP-1's guards
being green at the release commit.


## Integration Points

The six benchmark baselines `keiro/bench/baseline-*.csv` and the retained evidence under
`keiro/bench/results/` are owned by EP-1. EP-2 reads them through `scripts/bench-regression.sh`
and never edits them. A baseline moves only with an evidence directory and a README that EP-1
defines; EP-2's release skill text points at that rule.

`scripts/bench-regression.sh` and the `bench-regression` and `release-gate` recipes in
`justfile` are owned by EP-2. EP-1 runs them for its acceptance and may add guard-level
robustness (a warm-up scenario, a changed ceiling) inside `keiro/bench/*.hs`, but the runner's
per-guard summary format (`GUARD(name)=status`, `BENCH_REGRESSION=PASSED|FAILED`) is EP-2's
contract and the release skill depends on it.

`agents/skills/release/SKILL.md` is edited by EP-2 (step 4, the gate) and by EP-6 (step 3,
the internal-dependency scan regex). The sections do not overlap; each plan edits only its
section.

The inspection cursor contract in `keiro/src/Keiro/Workflow/Inspection/Query.hs` and
`keiro/src/Keiro/Workflow/Inspection.hs` (the `wf-key` and `wf-created` cursor kinds, the
`InspectionWorkLimitExceeded` error, and the constants `maxIndexedWorkflowKeyBytes`,
`maxWideWorkflowCandidates`, `maxWideWorkflowKeyBytes`) is owned by EP-3. EP-6 describes
whatever EP-3 ships in the changelogs and the `docs/user/durable-workflows.md` envelope text.
The HTTP routes in `keiro-ops-http/src/Keiro/Ops/Http/Route.hs` consume the cursor as an opaque
string and need no change.

The HTTP admission and mutation policy in `keiro-ops-http/src/Keiro/Ops/Http/Application.hs`,
`Budget.hs`, `Cors.hs`, and `WebSocket.hs` is owned by EP-4, together with the three guides
`docs/guides/serve-keiro-ops-over-http.md`, `docs/guides/stream-keiro-inspection-views.md`,
and `docs/guides/compose-runtime-inspection-surfaces.md`. EP-6 does not edit those guides; it
edits `docs/user/operations.md`, `docs/user/durable-workflows.md`, and the changelogs.

The process-manager inspector constructors in `keiro/src/Keiro/ProcessManager/Inspect.hs` and
the `pm` command family in `keiro-ops/src/Keiro/Ops/ProcessManager.hs` are owned by EP-5. The
legacy-only wording for `inspectionProvenance`, `pm show`, and `pm list` is produced by EP-5
and placed by EP-6; if EP-5 extends the inspector before the tag, EP-6 drops the wording.

Cross-plan decisions that deserve ADRs: how benchmark baselines are recorded, when they may
move, and that the guards are a release gate (EP-1 and EP-2 together, a new ADR); the
mutation origin policy and the delivery bound (EP-4, a revision of ADR-53); the reaction
provenance decision (EP-5, a revision of ADR-55); and the listing cost model without inspection
indexes (EP-3, a revision of ADR-40's rationale or a new ADR if the default order changes).


## Progress

Phase 1 is open. EP-1 is In Progress with M1 and M2 complete: the command-guard slowdown is
attributed to the benchmark harness, and M3 (isolate the command group's store, re-record)
through M6 remain. EP-2 is In Progress: the runner, the recipes, and the release skill text are
committed; its acceptance run waits for a quiet machine. EP-3, EP-4, EP-5, and
EP-6 are Not Started. The only cross-plan gate is plan 303's tag, which needs EP-2 and EP-6
Complete and EP-1's guards green at the release commit.


## Surprises & Discoveries

EP-1's control point failed on 2026-10-21: the command guard, built at the baseline commit
`2477a5aa` itself, measures the single-command scenarios at about twice the committed August
rows on this machine, while HEAD measures them faster than that commit. The committed
`baseline-command.csv` therefore cannot be reproduced in the current environment, and the
"25% to 239%" headline in REV-20 splits into two facts: the single-command rows are an
environment drift that a re-recorded baseline resolves, and the fan-out rows are a real
five-fold slowdown per dispatched target that entered between `2477a5aa` and `keiro-0.19.0.1`.
This affects EP-2 as well: the release gate's ADR must say that a baseline is tied to a
recorded environment and must be re-recorded, with the control rerun, when that environment
changes. Details and the numbers are in EP-1's Surprises & Discoveries.

Later the same day the sweep and a controlled experiment attributed the fan-out slowdown to
the benchmark harness, not to Keiro or Kiroku: since 0.17.0.0 the benchmark main seeds the
delegated-inbox fixture (a 100,000-event history and warm-up traffic) into the store the
command group uses, before `defaultMain` and regardless of the `-p` filter; HEAD with that
preparation skipped measures the fan-out rows at the 0.16.0.0 level and the single-command
rows eight to nine times faster. No serving path got slower, so EP-1 files no Kiroku
improvement request and its remaining work is harness isolation and re-recording. For EP-2
the lesson is durable: a guard's baseline is only meaningful for an isolated fixture, and the
ADR must say that each benchmark group owns its store.


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
- Decision: EP-5's minimum outcome before the tag is labelling, not the inspector extension.
  Rationale: ADR-49 and plan 304 retire the positional API; shipping its inspection unlabelled
  in 0.22 would announce a contract the retirement release removes. The extension is the better
  outcome and EP-5 should attempt it, but the tag must not wait on it.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)
